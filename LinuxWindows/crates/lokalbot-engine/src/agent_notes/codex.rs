//! Reads Codex's memories from `~/.codex/memories` (`CodexMemoryReader`).
//!
//! - `MEMORY.md`: one note per top-level heading (a task group).
//! - `memory_summary.md`: one note per section.
//! - `rollout_summaries/*.md`: one note per session summary.
//!
//! `raw_memories.md` repeats the session summaries and is not read. The
//! `skills` and `extensions` folders hold procedures and tools, not notes.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use lokalbot_core::agent_notes::{AgentNote, NoteScan};
use lokalbot_core::coding_agents::CodingAgentKind;

use super::exclusions::Exclusions;
use super::text::{self, ReadFailure};
use crate::coding_agents::text as agent_text;

pub struct CodexNotesReader {
    /// `~/.codex/memories`.
    pub root: PathBuf,
}

/// Notes parsed from one file, and how many sections exclusions left out.
type Parsed = (Vec<AgentNote>, usize);

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// A second section with the same heading gets `#2`, so ids stay distinct.
fn anchor(seen: &mut HashMap<String, usize>, base: &str) -> String {
    let count = seen.entry(base.to_string()).or_insert(0);
    *count += 1;
    if *count == 1 {
        base.to_string()
    } else {
        format!("{base}#{count}")
    }
}

impl CodexNotesReader {
    pub fn scan(&self, exclusions: &Exclusions) -> NoteScan {
        let mut scan = NoteScan::default();
        read(&self.root.join("MEMORY.md"), &mut scan, |contents, file| {
            task_groups(contents, file, exclusions)
        });
        read(
            &self.root.join("memory_summary.md"),
            &mut scan,
            |contents, file| summary_sections(contents, file, exclusions),
        );
        let mut summaries: Vec<PathBuf> = std::fs::read_dir(self.root.join("rollout_summaries"))
            .map(|entries| entries.flatten().map(|entry| entry.path()).collect())
            .unwrap_or_default();
        summaries.retain(|path| {
            !name_of(path).starts_with('.')
                && path
                    .extension()
                    .is_some_and(|found| found.eq_ignore_ascii_case("md"))
        });
        summaries.sort_by_key(|path| name_of(path));
        for file in summaries {
            if scan.notes.len() >= text::MAX_NOTES_PER_AGENT {
                break;
            }
            read(&file, &mut scan, |contents, file| {
                rollout_summary(contents, file, exclusions)
            });
        }
        scan
    }
}

fn read(file: &Path, scan: &mut NoteScan, parse: impl FnOnce(&str, &Path) -> Parsed) {
    if !file.is_file() {
        return;
    }
    match text::contents(file) {
        Err(ReadFailure::TooLarge) => {}
        Err(ReadFailure::Unreadable) => scan.unreadable_files.push(file.display().to_string()),
        Ok(contents) => {
            scan.files_read += 1;
            let (notes, excluded) = parse(&contents, file);
            scan.notes.extend(notes);
            scan.excluded_notes += excluded;
        }
    }
}

/// `MEMORY.md`: each `# Task Group: …` with its `scope:` line as the summary
/// and the folder from `applies_to: cwd=…`.
fn task_groups(contents: &str, file: &Path, exclusions: &Exclusions) -> Parsed {
    let modified = text::modification_date(file);
    let mut notes = Vec::new();
    let mut excluded = 0;
    let mut seen = HashMap::new();
    for section in text::sections(contents, &[1]) {
        if section.level != 1 {
            continue;
        }
        let mut scope: Option<String> = None;
        let mut working_directory: Option<String> = None;
        let header = section.body.split('\n').filter(|line| !line.is_empty());
        for line in header.take(12) {
            if scope.is_none() {
                scope = text::value("scope", line);
            }
            if working_directory.is_none()
                && let Some(applies) = text::value("applies_to", line)
            {
                working_directory = cwd(&applies);
            }
        }
        if exclusions.excludes_working_directory(working_directory.as_deref())
            || exclusions.mentions_excluded_folder(&section.heading)
        {
            excluded += 1;
            continue;
        }
        let note_text = text::body(&section.body);
        if note_text.is_empty() {
            continue;
        }
        let heading = section.heading.replace("Task Group: ", "");
        let section_id = anchor(&mut seen, &section.heading);
        notes.push(AgentNote {
            id: AgentNote::identifier(CodingAgentKind::Codex, &name_of(file), &section_id),
            agent: CodingAgentKind::Codex,
            title: text::line(Some(&heading), text::MAX_TITLE_CHARACTERS)
                .unwrap_or_else(|| "Codex memory".into()),
            summary: text::line(scope.as_deref(), text::MAX_SUMMARY_CHARACTERS),
            category: None,
            working_directory,
            path: file.display().to_string(),
            modified_at: modified,
            text: note_text,
        });
    }
    (notes, excluded)
}

/// `memory_summary.md`: one note per `##` or `###` section. A section headed
/// by a folder path is about that folder.
fn summary_sections(contents: &str, file: &Path, exclusions: &Exclusions) -> Parsed {
    let modified = text::modification_date(file);
    let mut notes = Vec::new();
    let mut excluded = 0;
    let mut parent = String::new();
    let mut seen = HashMap::new();
    for section in text::sections(contents, &[2, 3]) {
        if section.level == 0 {
            continue;
        }
        if section.level == 2 {
            parent = section.heading.clone();
        }
        let working_directory = text::is_folder_path(&section.heading)
            .then(|| section.heading.split(" / ").next().map(str::to_string))
            .flatten();
        if exclusions.excludes_working_directory(working_directory.as_deref())
            || exclusions.mentions_excluded_folder(&section.heading)
        {
            excluded += 1;
            continue;
        }
        let note_text = text::body(&section.body);
        if note_text.is_empty() {
            continue;
        }
        let anchor_base = if section.level == 3 {
            format!("{parent}/{}", section.heading)
        } else {
            section.heading.clone()
        };
        let section_id = anchor(&mut seen, &anchor_base);
        notes.push(AgentNote {
            id: AgentNote::identifier(CodingAgentKind::Codex, &name_of(file), &section_id),
            agent: CodingAgentKind::Codex,
            title: text::line(Some(&section.heading), text::MAX_TITLE_CHARACTERS)
                .unwrap_or_else(|| "Codex memory summary".into()),
            summary: (section.level == 3)
                .then(|| text::line(Some(&parent), text::MAX_SUMMARY_CHARACTERS))
                .flatten(),
            category: None,
            working_directory,
            path: file.display().to_string(),
            modified_at: modified,
            text: note_text,
        });
    }
    (notes, excluded)
}

/// A session summary: `key: value` header lines (`cwd`, `updated_at`), a blank
/// line, then the summary under its `#` title.
fn rollout_summary(contents: &str, file: &Path, exclusions: &Exclusions) -> Parsed {
    let lines: Vec<&str> = contents.split('\n').collect();
    let mut working_directory: Option<String> = None;
    let mut updated = None;
    let mut body_start = 0;
    for (index, line) in lines.iter().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            body_start = index;
            break;
        }
        if let Some(value) = text::value("cwd", line) {
            working_directory = Some(value);
        }
        if let Some(value) = text::value("updated_at", line) {
            updated = agent_text::timestamp(&value);
        }
        body_start = index + 1;
    }
    if exclusions.excludes_working_directory(working_directory.as_deref()) {
        return (Vec::new(), 1);
    }
    let body = lines[body_start..].join("\n");
    let note_text = text::body(&body);
    if note_text.is_empty() {
        return (Vec::new(), 0);
    }
    let heading = text::sections(&body, &[1])
        .into_iter()
        .find(|section| section.level == 1)
        .map(|section| section.heading);
    let fallback = file
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default();
    let note = AgentNote {
        id: AgentNote::identifier(
            CodingAgentKind::Codex,
            &format!("rollout_summaries/{}", name_of(file)),
            "",
        ),
        agent: CodingAgentKind::Codex,
        title: text::line(heading.as_deref(), text::MAX_TITLE_CHARACTERS).unwrap_or(fallback),
        summary: None,
        category: None,
        working_directory,
        path: file.display().to_string(),
        modified_at: updated.unwrap_or_else(|| text::modification_date(file)),
        text: note_text,
    };
    (vec![note], 0)
}

/// The folder in `cwd=/path; reuse_rule=…`.
fn cwd(applies_to: &str) -> Option<String> {
    let (_, rest) = applies_to.split_once("cwd=")?;
    let path = rest.split(';').next().unwrap_or("").trim();
    (text::is_folder_path(path) || path.starts_with('~')).then(|| path.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_folder_comes_from_the_applies_to_line() {
        assert_eq!(
            cwd("cwd=/Users/me/GitHub/app; reuse_rule=check the tag").as_deref(),
            Some("/Users/me/GitHub/app")
        );
        assert_eq!(
            cwd(r"cwd=C:\Users\me\Code\app; reuse_rule=none").as_deref(),
            Some(r"C:\Users\me\Code\app")
        );
        assert_eq!(cwd("cwd=~/Code/app").as_deref(), Some("~/Code/app"));
        assert_eq!(cwd("cwd=any; reuse_rule=none"), None);
        assert_eq!(cwd("reuse_rule=none"), None);
    }

    #[test]
    fn repeated_headings_get_distinct_anchors() {
        let mut seen = HashMap::new();
        assert_eq!(anchor(&mut seen, "Release"), "Release");
        assert_eq!(anchor(&mut seen, "Release"), "Release#2");
        assert_eq!(anchor(&mut seen, "Build"), "Build");
    }
}
