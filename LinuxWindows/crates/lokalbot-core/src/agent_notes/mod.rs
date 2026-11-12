//! Coding-agent notes as a search source (`AgentMemoryNote.swift`,
//! `AgentMemoryStore.swift`, `AgentNotesAccess.swift`): the notes Claude Code
//! and Codex keep for their own later sessions, saved in `agent-notes.sqlite`
//! in the library while the person has **Read coding agent notes** on.
//!
//! The readers live in `lokalbot-engine`. This is the saved copy every other
//! feature reads: [`store`] writes it, [`index`] searches it read-only, and
//! [`access`] is the external-agent grant. The notes are a search source only;
//! nothing here feeds the day digest, the overnight review or Personal Context.

pub mod access;
mod cjk;
pub mod index;
pub mod store;

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use sha2::{Digest as _, Sha256};

use crate::coding_agents::CodingAgentKind;

pub use index::{NoteHit, NotesIndex};

/// The saved notes, in the library root. The Mac writes the same file.
pub const FILE_NAME: &str = "agent-notes.sqlite";

pub fn database_path(root: &Path) -> PathBuf {
    root.join(FILE_NAME)
}

/// A note a coding agent wrote for its own later sessions, as LokalBot keeps it
/// for search. The agent's file stays the source and is never changed.
#[derive(Clone, Debug, PartialEq)]
pub struct AgentNote {
    /// Stable across scans: the agent, the file, and the section inside it.
    pub id: String,
    pub agent: CodingAgentKind,
    pub title: String,
    /// The agent's own one-line description of the note, when it wrote one.
    pub summary: Option<String>,
    /// Claude Code's label for the note: user, feedback, project, or reference.
    pub category: Option<String>,
    /// The folder the note is about, when the agent recorded it.
    pub working_directory: Option<String>,
    /// The agent's file, for opening the note.
    pub path: String,
    pub modified_at: DateTime<Utc>,
    /// The note's text with detected credentials redacted.
    pub text: String,
}

impl AgentNote {
    /// Twelve hex characters from the agent, the file's path under the agent's
    /// folder (always with `/`), and the section's anchor.
    pub fn identifier(agent: CodingAgentKind, relative_path: &str, anchor: &str) -> String {
        let material = [agent.raw_value(), relative_path, anchor].join("\u{1f}");
        hex::encode(&Sha256::digest(material.as_bytes())[..6])
    }

    /// The last folder name of `working_directory`, for a short label.
    pub fn project_name(&self) -> Option<String> {
        project_name(self.working_directory.as_deref())
    }
}

/// The last folder name of a path written on any platform.
pub fn project_name(working_directory: Option<&str>) -> Option<String> {
    let name = working_directory?
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()?;
    // `C:` alone names a drive, not a project.
    (!name.is_empty() && !name.ends_with(':')).then(|| name.to_string())
}

/// What one scan of the agents' memory files found.
#[derive(Clone, Debug, Default)]
pub struct NoteScan {
    pub notes: Vec<AgentNote>,
    pub files_read: usize,
    /// Files that exist but could not be read. While any are listed, notes
    /// missing from the scan are not taken as deleted.
    pub unreadable_files: Vec<String>,
    /// Notes left out by "Never read sessions in these folders".
    pub excluded_notes: usize,
}

impl NoteScan {
    pub fn merge(&mut self, other: NoteScan) {
        self.notes.extend(other.notes);
        self.files_read += other.files_read;
        self.unreadable_files.extend(other.unreadable_files);
        self.excluded_notes += other.excluded_notes;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_are_twelve_hex_characters_and_differ_by_anchor() {
        let plain = AgentNote::identifier(CodingAgentKind::Codex, "MEMORY.md", "");
        let anchored = AgentNote::identifier(CodingAgentKind::Codex, "MEMORY.md", "Release");
        assert_eq!(plain.len(), 12);
        assert!(plain.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(plain, anchored);
        assert_ne!(
            plain,
            AgentNote::identifier(CodingAgentKind::ClaudeCode, "MEMORY.md", "")
        );
        // SHA-256 of "codex\u{1f}MEMORY.md\u{1f}", as the Mac computes it.
        assert_eq!(plain, {
            let digest = Sha256::digest("codex\u{1f}MEMORY.md\u{1f}".as_bytes());
            hex::encode(&digest[..6])
        });
    }

    #[test]
    fn project_names_come_from_paths_of_either_platform() {
        assert_eq!(
            project_name(Some("/Users/me/GitHub/app")).as_deref(),
            Some("app")
        );
        assert_eq!(
            project_name(Some("/home/me/code/app/")).as_deref(),
            Some("app")
        );
        assert_eq!(
            project_name(Some(r"C:\Users\me\Code\app")).as_deref(),
            Some("app")
        );
        assert_eq!(project_name(Some("/")), None);
        assert_eq!(project_name(Some(r"C:\")), None);
        assert_eq!(project_name(None), None);
    }
}
