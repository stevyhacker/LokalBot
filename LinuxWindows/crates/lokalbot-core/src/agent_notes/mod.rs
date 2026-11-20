pub mod access;
mod cjk;
pub mod index;
pub mod store;

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use sha2::{Digest as _, Sha256};

use crate::coding_agents::CodingAgentKind;

pub use index::{NoteHit, NotesIndex};

pub const FILE_NAME: &str = "agent-notes.sqlite";

pub fn database_path(root: &Path) -> PathBuf {
    root.join(FILE_NAME)
}

#[derive(Clone, Debug, PartialEq)]
pub struct AgentNote {
    pub id: String,
    pub agent: CodingAgentKind,
    pub title: String,
    pub summary: Option<String>,
    pub category: Option<String>,
    pub working_directory: Option<String>,
    pub path: String,
    pub modified_at: DateTime<Utc>,
    pub text: String,
}

impl AgentNote {
    pub fn identifier(agent: CodingAgentKind, relative_path: &str, anchor: &str) -> String {
        let material = [agent.raw_value(), relative_path, anchor].join("\u{1f}");
        hex::encode(&Sha256::digest(material.as_bytes())[..6])
    }

    pub fn project_name(&self) -> Option<String> {
        project_name(self.working_directory.as_deref())
    }
}

pub fn project_name(working_directory: Option<&str>) -> Option<String> {
    let name = working_directory?
        .trim_end_matches(['/', '\\'])
        .rsplit(['/', '\\'])
        .next()?;
    (!name.is_empty() && !name.ends_with(':')).then(|| name.to_string())
}

#[derive(Clone, Debug, Default)]
pub struct NoteScan {
    pub notes: Vec<AgentNote>,
    pub files_read: usize,
    pub unreadable_files: Vec<String>,
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
