//! Reads Claude Code's notes from `~/.claude/projects/<cwd-slug>/memory/*.md`
//! (`ClaudeCodeMemoryReader`).
//!
//! Each note is one Markdown file with a short header (name, description,
//! type). `MEMORY.md` is the folder's index of those files: it supplies titles
//! and is not a note itself. Nothing else in a project folder is read except
//! the opening of one session file, for the folder's real path.

use std::collections::HashMap;
use std::io::Read as _;
use std::path::{Path, PathBuf};

use lokalbot_core::agent_notes::{AgentNote, NoteScan};
use lokalbot_core::coding_agents::CodingAgentKind;

use super::exclusions::{Exclusions, claude_project_slug};
use super::text::{self, ReadFailure};

pub const INDEX_FILE_NAME: &str = "MEMORY.md";
/// How much of a session file is read to find its working directory.
const SESSION_PEEK_BYTES: u64 = 256 * 1_024;
const CATEGORIES: [&str; 4] = ["user", "feedback", "project", "reference"];

pub struct ClaudeNotesReader {
    /// `~/.claude/projects`.
    pub root: PathBuf,
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// A folder's visible entries, sorted by name, with whether each is a regular
/// file (a link is not).
fn listed(directory: &Path) -> Vec<(PathBuf, bool)> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut found: Vec<(PathBuf, bool)> = entries
        .flatten()
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .map(|entry| {
            let is_file = entry.file_type().is_ok_and(|kind| kind.is_file());
            (entry.path(), is_file)
        })
        .collect();
    found.sort_by_key(|(path, _)| name_of(path));
    found
}

fn has_extension(path: &Path, extension: &str) -> bool {
    path.extension()
        .is_some_and(|found| found.eq_ignore_ascii_case(extension))
}

impl ClaudeNotesReader {
    pub fn scan(&self, exclusions: &Exclusions) -> NoteScan {
        let mut scan = NoteScan::default();
        for (project, _) in listed(&self.root) {
            let folder = project.join("memory");
            let files: Vec<PathBuf> = listed(&folder)
                .into_iter()
                .filter(|(path, is_file)| {
                    *is_file && has_extension(path, "md") && name_of(path) != INDEX_FILE_NAME
                })
                .map(|(path, _)| path)
                .collect();
            if files.is_empty() {
                continue;
            }
            let slug = name_of(&project);
            let working_directory = working_directory(&project);
            if exclusions.excludes_claude_project(&slug)
                || exclusions.excludes_working_directory(working_directory.as_deref())
            {
                scan.excluded_notes += files.len();
                continue;
            }
            let titles = index_titles(&folder.join(INDEX_FILE_NAME));
            for file in files {
                if scan.notes.len() >= text::MAX_NOTES_PER_AGENT {
                    return scan;
                }
                match text::contents(&file) {
                    Err(ReadFailure::TooLarge) => {}
                    Err(ReadFailure::Unreadable) => {
                        scan.unreadable_files.push(file.display().to_string());
                    }
                    Ok(contents) => {
                        scan.files_read += 1;
                        let file_name = name_of(&file);
                        let relative = format!("{slug}/memory/{file_name}");
                        scan.notes.extend(note(
                            &contents,
                            &file,
                            &relative,
                            titles.get(&file_name).map(String::as_str),
                            working_directory.clone(),
                        ));
                    }
                }
            }
        }
        scan
    }
}

fn note(
    contents: &str,
    file: &Path,
    relative_path: &str,
    index_title: Option<&str>,
    working_directory: Option<String>,
) -> Option<AgentNote> {
    let (fields, body) = front_matter(contents);
    let note_text = text::body(&body);
    if note_text.is_empty() {
        return None;
    }
    let heading = text::sections(&body, &[1])
        .into_iter()
        .find(|section| section.level == 1)
        .map(|section| section.heading);
    let name = fields.get("name").map(|name| name.replace('-', " "));
    let fallback = file
        .file_stem()
        .map(|stem| stem.to_string_lossy().replace('-', " "))
        .unwrap_or_default();
    let title = [index_title, heading.as_deref(), name.as_deref()]
        .into_iter()
        .find_map(|candidate| text::line(candidate, text::MAX_TITLE_CHARACTERS))
        .unwrap_or(fallback);
    let category = fields
        .get("type")
        .or_else(|| fields.get("metadata.type"))
        .map(|kind| kind.to_lowercase())
        .filter(|kind| CATEGORIES.contains(&kind.as_str()));
    Some(AgentNote {
        id: AgentNote::identifier(CodingAgentKind::ClaudeCode, relative_path, ""),
        agent: CodingAgentKind::ClaudeCode,
        title,
        summary: text::line(
            fields.get("description").map(String::as_str),
            text::MAX_SUMMARY_CHARACTERS,
        ),
        category,
        working_directory,
        path: file.display().to_string(),
        modified_at: text::modification_date(file),
        text: note_text,
    })
}

/// The leading `---` block as flat fields (`name`, `metadata.type`), and the
/// text after it. A file without the block is all body.
pub(super) fn front_matter(contents: &str) -> (HashMap<String, String>, String) {
    let lines: Vec<&str> = contents.split('\n').collect();
    let end = (lines.first().map(|line| line.trim()) == Some("---"))
        .then(|| lines.iter().skip(1).position(|line| line.trim() == "---"))
        .flatten();
    let Some(end) = end.map(|offset| offset + 1) else {
        return (HashMap::new(), contents.to_string());
    };
    let mut fields = HashMap::new();
    let mut parent: Option<String> = None;
    for line in &lines[1..end] {
        let indented = line.starts_with([' ', '\t']);
        let trimmed = line.trim();
        let Some((key, value)) = trimmed.split_once(':') else {
            continue;
        };
        let value = text::unquoted(value.trim());
        if !indented {
            parent = value.is_empty().then(|| key.to_string());
        }
        if value.is_empty() {
            continue;
        }
        let key = if indented {
            format!("{}.{key}", parent.as_deref().unwrap_or(""))
        } else {
            key.to_string()
        };
        fields.insert(key, value);
    }
    (fields, lines[end + 1..].join("\n"))
}

/// File name to title, from index lines such as
/// `- [Release gotchas](release-gotchas.md) — per-release lessons`.
fn index_titles(index: &Path) -> HashMap<String, String> {
    let Ok(contents) = text::contents(index) else {
        return HashMap::new();
    };
    let mut titles = HashMap::new();
    for line in contents.split('\n') {
        let Some(open) = line.find('[') else { continue };
        let Some(close) = line[open..].find("](").map(|found| open + found) else {
            continue;
        };
        let target = close + 2;
        let Some(end) = line[target..].find(')').map(|found| target + found) else {
            continue;
        };
        let title = line[open + 1..close].trim();
        if !title.is_empty() {
            titles
                .entry(line[target..end].to_string())
                .or_insert_with(|| title.to_string());
        }
    }
    titles
}

/// The folder a project's sessions ran in. The project folder's name is that
/// path with its separators lost, so the path is read from the newest session
/// files and kept only if it produces the same name.
pub(super) fn working_directory(project: &Path) -> Option<String> {
    let slug = name_of(project);
    let mut sessions: Vec<PathBuf> = listed(project)
        .into_iter()
        .map(|(path, _)| path)
        .filter(|path| path.extension().is_some_and(|found| found == "jsonl"))
        .collect();
    sessions.sort_by_key(|path| std::cmp::Reverse(text::modification_date(path)));
    for session in sessions.iter().take(3) {
        let Ok(file) = std::fs::File::open(session) else {
            continue;
        };
        let mut bytes = Vec::new();
        if file
            .take(SESSION_PEEK_BYTES)
            .read_to_end(&mut bytes)
            .is_err()
        {
            continue;
        }
        let opening = String::from_utf8_lossy(&bytes);
        const KEY: &str = "\"cwd\":\"";
        let mut from = 0;
        while let Some(found) = opening[from..].find(KEY) {
            from += found + KEY.len();
            if let Some(path) = json_string(&opening[from..])
                && claude_project_slug(&path) == slug
            {
                return Some(path);
            }
        }
    }
    None
}

/// Decodes the JSON string whose first character opens `text`.
fn json_string(text: &str) -> Option<String> {
    let mut escaped = false;
    for (index, c) in text.char_indices() {
        match c {
            _ if escaped => escaped = false,
            '\\' => escaped = true,
            '"' => return serde_json::from_str(&format!("\"{}\"", &text[..index])).ok(),
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn front_matter_reads_flat_and_nested_fields() {
        let (fields, body) = front_matter(
            "---\nname: release-gotchas\ndescription: \"Lessons: tag by SHA\"\nmetadata:\n  node_type: memory\n  type: project\n---\n\nTag by SHA.\n",
        );
        assert_eq!(fields["name"], "release-gotchas");
        assert_eq!(fields["description"], "Lessons: tag by SHA");
        assert_eq!(fields["metadata.type"], "project");
        assert_eq!(body, "\nTag by SHA.\n");

        let (none, all) = front_matter("# Title\n---\nnot a header\n");
        assert!(none.is_empty());
        assert_eq!(all, "# Title\n---\nnot a header\n");
        let (unclosed, kept) = front_matter("---\nname: x\n");
        assert!(unclosed.is_empty());
        assert_eq!(kept, "---\nname: x\n");
    }

    #[test]
    fn json_strings_decode_escapes() {
        assert_eq!(
            json_string(r#"C:\\Users\\me\\app","next":1"#).as_deref(),
            Some(r"C:\Users\me\app")
        );
        assert_eq!(
            json_string(r#"/a \"b\"/c""#).as_deref(),
            Some(r#"/a "b"/c"#)
        );
        assert_eq!(json_string("/unterminated"), None);
    }
}
