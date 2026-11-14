//! `search_agent_notes` for MCP and `lokalbot-cli search-notes`
//! (`AgentNotesSearchTool`): word search over the notes the user's coding
//! agents saved for themselves, as LokalBot keeps them while **Read coding
//! agent notes** is on. Works while the app is closed.

use chrono::{DateTime, SecondsFormat, Utc};
use lokalbot_core::LibraryPaths;
use lokalbot_core::agent_notes::{NotesIndex, access};
use serde::Serialize;

use crate::search::MAXIMUM_QUERY_CHARACTERS;

pub const NAME: &str = "search_agent_notes";
pub const DEFAULT_LIMIT: i64 = 8;
pub const MAXIMUM_LIMIT: i64 = 30;
/// A note longer than this is cut, with an ellipsis.
const NOTE_CHARACTERS: usize = 4_000;

pub const AGENTS: [&str; 2] = ["claude-code", "codex"];

pub const DISABLED_MESSAGE: &str = "Agent-notes access is off. The user can turn it on in LokalBot → Settings → AI agents → \"Allow external agents to search agent notes\".";
pub const UNAVAILABLE_MESSAGE: &str = "Agent-notes access is on, but \"Read coding agent notes\" is off in LokalBot or nothing has been read yet. The user can turn it on in LokalBot → Settings → Screen & activity.";
pub const NOTE: &str = "Notes the user's coding agents (Claude Code, Codex) wrote for their own later sessions, found by their words. A note is what an agent recorded at the time, not a verified fact: check it against the current code or files before relying on it. Paths point at the agents' own files; LokalBot never changes them.";

#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
    Disabled,
    Unavailable,
    Invalid(String),
}

impl Failure {
    pub fn message(&self) -> String {
        match self {
            Failure::Disabled => DISABLED_MESSAGE.into(),
            Failure::Unavailable => UNAVAILABLE_MESSAGE.into(),
            Failure::Invalid(message) => message.clone(),
        }
    }
}

/// Keys sort the way the Mac writes them.
#[derive(Debug, Serialize)]
pub struct Item {
    pub agent: String,
    pub excerpt: String,
    pub id: String,
    pub modified: String,
    pub path: String,
    /// The folder the note is about, when the agent recorded it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    pub title: String,
    /// Claude Code's own label: user, feedback, project, or reference.
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub matched_by: &'static str,
    pub note: &'static str,
    pub query: String,
    pub results: Vec<Item>,
}

fn stamp(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn clipped(text: &str) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= NOTE_CHARACTERS {
        return trimmed.to_string();
    }
    let mut out: String = trimmed.chars().take(NOTE_CHARACTERS).collect();
    out.push('…');
    out
}

/// Arguments first, so a bad call says so with or without the grant; then the
/// grant, then the saved notes.
pub fn report(
    paths: &LibraryPaths,
    query: &str,
    agent: Option<&str>,
    limit: Option<i64>,
) -> Result<Report, Failure> {
    let query = query.trim();
    if query.is_empty() || query.chars().count() > MAXIMUM_QUERY_CHARACTERS {
        return Err(Failure::Invalid(format!(
            "\"query\" must be a non-empty string of at most {MAXIMUM_QUERY_CHARACTERS} characters."
        )));
    }
    let count = limit.unwrap_or(DEFAULT_LIMIT);
    if !(1..=MAXIMUM_LIMIT).contains(&count) {
        return Err(Failure::Invalid(format!(
            "\"limit\" must be an integer between 1 and {MAXIMUM_LIMIT}."
        )));
    }
    let agent = agent.map(str::to_lowercase);
    if let Some(agent) = &agent
        && !AGENTS.contains(&agent.as_str())
    {
        return Err(Failure::Invalid(format!(
            "\"agent\" must be one of {}.",
            AGENTS.join(", ")
        )));
    }
    if !access::is_enabled(paths) {
        return Err(Failure::Disabled);
    }
    let index = NotesIndex::new(paths.root());
    if !index.exists() {
        return Err(Failure::Unavailable);
    }
    let hits = index
        .search(query, agent.as_deref(), count as usize)
        .map_err(|_| Failure::Unavailable)?;
    let results = hits
        .into_iter()
        .map(|hit| Item {
            text: index
                .text_of(&hit.id)
                .ok()
                .flatten()
                .as_deref()
                .map(clipped),
            agent: hit.agent,
            excerpt: hit.snippet,
            modified: stamp(hit.modified),
            path: hit.path,
            project: hit.working_directory,
            summary: hit.summary,
            title: hit.title,
            kind: hit.category,
            id: hit.id,
        })
        .collect();
    Ok(Report {
        matched_by: "words",
        note: NOTE,
        query: query.to_string(),
        results,
    })
}

/// A plain-text table for `search-notes --table`.
pub fn table(report: &Report) -> String {
    if report.results.is_empty() {
        return format!("No agent notes matched \"{}\".", report.query);
    }
    report
        .results
        .iter()
        .map(|item| {
            let project = item
                .project
                .as_deref()
                .map(|project| format!(" · {project}"))
                .unwrap_or_default();
            format!(
                "{}\t{}\t{}{project}\n\t{}\n\t{}",
                item.agent,
                &item.modified[..item.modified.len().min(10)],
                item.title,
                item.excerpt.replace('\n', " "),
                item.path
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use lokalbot_core::agent_notes::{AgentNote, NoteScan, store};
    use lokalbot_core::coding_agents::CodingAgentKind::{ClaudeCode, Codex};

    pub(crate) fn release() -> AgentNote {
        AgentNote {
            id: "c0ffee000001".into(),
            agent: ClaudeCode,
            title: "Release runbook".into(),
            summary: Some("Per-release lessons".into()),
            category: Some("project".into()),
            working_directory: Some("/Users/me/GitHub/app".into()),
            path: "/Users/me/.claude/projects/-Users-me-GitHub-app/memory/release.md".into(),
            modified_at: DateTime::from_timestamp(1_800_000_000, 0).unwrap(),
            text: "Tag the release by SHA, never by branch name.".into(),
        }
    }

    pub(crate) fn build() -> AgentNote {
        AgentNote {
            id: "c0ffee000002".into(),
            agent: Codex,
            title: "Build recipe".into(),
            summary: None,
            category: None,
            working_directory: None,
            path: "/Users/me/.codex/memories/MEMORY.md".into(),
            modified_at: DateTime::from_timestamp(1_800_000_100, 0).unwrap(),
            text: "Run xcodebuild with a derived data path outside Documents.".into(),
        }
    }

    pub(crate) fn save(paths: &LibraryPaths, notes: &[AgentNote]) {
        let scan = NoteScan {
            notes: notes.to_vec(),
            ..Default::default()
        };
        store::apply(paths.root(), &scan, &[ClaudeCode, Codex]).unwrap();
    }

    fn paths() -> (tempfile::TempDir, LibraryPaths) {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        (dir, paths)
    }

    #[test]
    fn search_for_agents_needs_its_own_grant_then_saved_notes() {
        let (_dir, paths) = paths();
        // No other grant opens the notes.
        lokalbot_core::access::set_meetings_access(&paths, true).unwrap();
        lokalbot_core::files::access::set_enabled(&paths, true).unwrap();
        assert_eq!(
            report(&paths, "release", None, None).unwrap_err(),
            Failure::Disabled
        );

        access::set_enabled(&paths, true).unwrap();
        assert_eq!(
            report(&paths, "release", None, None).unwrap_err(),
            Failure::Unavailable,
            "nothing saved: the feature is off"
        );
        assert!(
            !NotesIndex::new(paths.root()).exists(),
            "searching never creates the saved copy"
        );

        save(&paths, &[release(), build()]);
        let found = report(&paths, "release", None, None).unwrap();
        assert_eq!(found.results.len(), 1);
        let first = &found.results[0];
        assert_eq!(first.id, release().id);
        assert_eq!(first.agent, "claude-code");
        assert_eq!(first.project.as_deref(), Some("/Users/me/GitHub/app"));
        assert_eq!(first.kind.as_deref(), Some("project"));
        assert_eq!(first.text.as_deref(), Some(release().text.as_str()));
        assert_eq!(first.modified, "2027-01-15T08:00:00Z");
        let json = crate::json::pretty(&found, false);
        assert!(json.contains("\"matched_by\" : \"words\""), "{json}");
        assert!(json.contains("\"type\" : \"project\""), "{json}");
        assert!(
            json.contains("\"path\" : \"/Users/me/.claude/projects/"),
            "{json}"
        );
        assert!(table(&found).contains("Release runbook · /Users/me/GitHub/app"));
        let codex = report(&paths, "xcodebuild", Some("Codex"), Some(30)).unwrap();
        assert_eq!(codex.results[0].agent, "codex");
        assert!(!crate::json::pretty(&codex, false).contains("\"project\""));
        assert_eq!(
            table(&report(&paths, "gardening", None, None).unwrap()),
            "No agent notes matched \"gardening\"."
        );

        access::set_enabled(&paths, false).unwrap();
        assert_eq!(
            report(&paths, "release", None, None).unwrap_err(),
            Failure::Disabled
        );
    }

    #[test]
    fn bad_arguments_say_so_with_or_without_the_grant() {
        let (_dir, paths) = paths();
        let invalid = |agent: Option<&str>, limit: Option<i64>, query: &str| match report(
            &paths, query, agent, limit,
        )
        .unwrap_err()
        {
            Failure::Invalid(message) => message,
            other => panic!("{other:?}"),
        };
        assert_eq!(
            invalid(Some("cursor"), None, "release"),
            "\"agent\" must be one of claude-code, codex."
        );
        assert_eq!(
            invalid(None, Some(0), "release"),
            "\"limit\" must be an integer between 1 and 30."
        );
        assert_eq!(
            invalid(None, Some(31), "release"),
            "\"limit\" must be an integer between 1 and 30."
        );
        assert!(invalid(None, None, " ").starts_with("\"query\" must be a non-empty string"));
    }

    #[test]
    fn a_long_note_is_cut_with_an_ellipsis() {
        let (_dir, paths) = paths();
        access::set_enabled(&paths, true).unwrap();
        let long = AgentNote {
            text: format!("release {}", "word ".repeat(2_000)),
            ..release()
        };
        save(&paths, &[long]);
        let found = report(&paths, "release", None, Some(1)).unwrap();
        let text = found.results[0].text.as_deref().unwrap();
        assert_eq!(text.chars().count(), NOTE_CHARACTERS + 1);
        assert!(text.ends_with('…'));
    }
}
