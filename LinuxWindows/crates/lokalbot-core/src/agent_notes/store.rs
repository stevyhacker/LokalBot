//! Write side of the saved coding-agent notes (`AgentMemoryStore`). The file
//! holds only what the readers kept of the agents' own files, so it is rebuilt
//! from them at any time and deleted outright when the person turns the
//! feature off.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::time::Duration;

use anyhow::{Context as _, Result};
use rusqlite::{Connection, params};
use sha2::{Digest as _, Sha256};

use super::{AgentNote, NoteScan, database_path};
use crate::coding_agents::CodingAgentKind;
use crate::time::to_epoch;

/// The Mac's schema, so either app reads a file the other wrote.
const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS notes (
        rowid INTEGER PRIMARY KEY,
        id TEXT NOT NULL UNIQUE,
        agent TEXT NOT NULL,
        title TEXT NOT NULL,
        summary TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT '',
        working_directory TEXT NOT NULL DEFAULT '',
        path TEXT NOT NULL,
        modified REAL NOT NULL,
        text TEXT NOT NULL,
        digest TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_notes_agent ON notes(agent);
    CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
        title, summary, text, tokenize='unicode61 remove_diacritics 2');
";

/// What one [`apply`] changed.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Change {
    pub added: usize,
    pub updated: usize,
    pub removed: usize,
}

impl Change {
    pub fn is_empty(&self) -> bool {
        self.added == 0 && self.updated == 0 && self.removed == 0
    }
}

fn digest(note: &AgentNote) -> String {
    let modified = format!("{:?}", to_epoch(note.modified_at));
    let material = [
        note.agent.raw_value(),
        &note.title,
        note.summary.as_deref().unwrap_or(""),
        note.category.as_deref().unwrap_or(""),
        note.working_directory.as_deref().unwrap_or(""),
        &note.path,
        &modified,
        &note.text,
    ]
    .join("\u{1f}");
    hex::encode(Sha256::digest(material.as_bytes()))
}

/// Makes the saved notes of `agents` match `scan`, and drops notes of any
/// other agent. While a file could not be read, a note missing from the scan
/// stays: an unreadable file is not a deleted one.
pub fn apply(root: &Path, scan: &NoteScan, agents: &[CodingAgentKind]) -> Result<Change> {
    let path = database_path(root);
    let mut db = Connection::open(&path)
        .with_context(|| format!("Could not open the agent notes at {}.", path.display()))?;
    db.busy_timeout(Duration::from_secs(5))?;
    // As the Mac opens it: readers proceed while notes are replaced.
    db.pragma_update(None, "journal_mode", "WAL")?;
    db.pragma_update(None, "synchronous", "NORMAL")?;
    db.execute_batch(SCHEMA)?;
    crate::access::restrict_file(&path);

    let enabled: HashSet<&str> = agents.iter().map(|agent| agent.raw_value()).collect();
    let mut fresh: HashMap<&str, &AgentNote> = HashMap::new();
    for note in &scan.notes {
        if agents.contains(&note.agent) {
            fresh.insert(&note.id, note);
        }
    }
    let stored: Vec<(i64, String, String, String)> = {
        let mut statement = db.prepare("SELECT rowid, id, agent, digest FROM notes")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    let stored_by_id: HashMap<&str, (i64, &str)> = stored
        .iter()
        .map(|(row_id, id, _, digest)| (id.as_str(), (*row_id, digest.as_str())))
        .collect();
    let keeps_missing = !scan.unreadable_files.is_empty();

    let mut change = Change::default();
    let transaction = db.transaction()?;
    {
        let remove = |row_id: i64| -> rusqlite::Result<()> {
            transaction.execute("DELETE FROM notes_fts WHERE rowid = ?1", params![row_id])?;
            transaction.execute("DELETE FROM notes WHERE rowid = ?1", params![row_id])?;
            Ok(())
        };
        for (row_id, id, agent, _) in &stored {
            if fresh.contains_key(id.as_str()) {
                continue;
            }
            if enabled.contains(agent.as_str()) && keeps_missing {
                continue;
            }
            remove(*row_id)?;
            change.removed += 1;
        }
        let mut ordered: Vec<&AgentNote> = fresh.values().copied().collect();
        ordered.sort_by(|a, b| a.id.cmp(&b.id));
        for note in ordered {
            let digest = digest(note);
            match stored_by_id.get(note.id.as_str()) {
                Some((_, existing)) if *existing == digest => continue,
                Some((row_id, _)) => {
                    remove(*row_id)?;
                    change.updated += 1;
                }
                None => change.added += 1,
            }
            let summary = note.summary.as_deref().unwrap_or("");
            transaction.execute(
                "INSERT INTO notes (id, agent, title, summary, category, working_directory, path,
                                    modified, text, digest)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    note.id,
                    note.agent.raw_value(),
                    note.title,
                    summary,
                    note.category.as_deref().unwrap_or(""),
                    note.working_directory.as_deref().unwrap_or(""),
                    note.path,
                    to_epoch(note.modified_at),
                    note.text,
                    digest,
                ],
            )?;
            transaction.execute(
                "INSERT INTO notes_fts (rowid, title, summary, text) VALUES (?1, ?2, ?3, ?4)",
                params![
                    transaction.last_insert_rowid(),
                    note.title,
                    summary,
                    note.text
                ],
            )?;
        }
    }
    transaction.commit()?;
    Ok(change)
}

/// Removes every saved note. The agents' own files are untouched. Returns
/// whether the file is gone: on Windows a search that has it open for a moment
/// keeps it until the next try.
pub fn delete_all(root: &Path) -> bool {
    let path = database_path(root);
    for suffix in ["-wal", "-shm", "-journal", ""] {
        let mut name = path.clone().into_os_string();
        name.push(suffix);
        match std::fs::remove_file(&name) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                log::warn!("could not delete saved agent notes: {err}");
            }
            _ => {}
        }
    }
    !path.exists()
}

#[cfg(test)]
pub(crate) mod tests {
    use chrono::DateTime;

    use super::*;
    use crate::agent_notes::NotesIndex;
    use crate::coding_agents::CodingAgentKind::{ClaudeCode, Codex};

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

    pub(crate) fn scan(notes: &[AgentNote]) -> NoteScan {
        NoteScan {
            notes: notes.to_vec(),
            ..Default::default()
        }
    }

    fn ids(hits: Vec<crate::agent_notes::NoteHit>) -> Vec<String> {
        hits.into_iter().map(|hit| hit.id).collect()
    }

    #[test]
    fn apply_adds_updates_and_removes_notes_to_match_the_scan() {
        let dir = tempfile::tempdir().unwrap();
        let index = NotesIndex::new(dir.path());
        let both = [ClaudeCode, Codex];

        let first = apply(dir.path(), &scan(&[release(), build()]), &both).unwrap();
        assert_eq!(
            first,
            Change {
                added: 2,
                ..Default::default()
            }
        );
        let counts = index.counts().unwrap();
        assert_eq!(counts.get("claude-code"), Some(&1));
        assert_eq!(counts.get("codex"), Some(&1));

        assert!(
            apply(dir.path(), &scan(&[release(), build()]), &both)
                .unwrap()
                .is_empty(),
            "an unchanged scan writes nothing"
        );

        let edited = AgentNote {
            text: "Tag the release by SHA, then wait for the notarization email.".into(),
            ..release()
        };
        let second = apply(dir.path(), &scan(&[edited]), &both).unwrap();
        assert_eq!(
            second,
            Change {
                added: 0,
                updated: 1,
                removed: 1
            }
        );
        assert_eq!(
            ids(index.search("notarization", None, 5).unwrap()),
            [release().id]
        );
        assert!(
            index.search("xcodebuild", None, 5).unwrap().is_empty(),
            "a removed note leaves the word index too"
        );
    }

    #[test]
    fn an_unreadable_file_is_not_a_deletion() {
        let dir = tempfile::tempdir().unwrap();
        let both = [ClaudeCode, Codex];
        apply(dir.path(), &scan(&[release(), build()]), &both).unwrap();
        let partial = NoteScan {
            unreadable_files: vec!["/Users/me/.codex/memories/MEMORY.md".into()],
            ..scan(&[release()])
        };

        assert!(apply(dir.path(), &partial, &both).unwrap().is_empty());
        assert_eq!(
            NotesIndex::new(dir.path()).counts().unwrap().get("codex"),
            Some(&1)
        );
    }

    #[test]
    fn an_agent_turned_off_loses_its_notes_even_when_a_file_was_unreadable() {
        let dir = tempfile::tempdir().unwrap();
        apply(
            dir.path(),
            &scan(&[release(), build()]),
            &[ClaudeCode, Codex],
        )
        .unwrap();
        let only_claude = NoteScan {
            unreadable_files: vec!["/somewhere".into()],
            ..scan(&[release(), build()])
        };

        let change = apply(dir.path(), &only_claude, &[ClaudeCode]).unwrap();

        assert_eq!(
            change,
            Change {
                removed: 1,
                ..Default::default()
            }
        );
        let counts = NotesIndex::new(dir.path()).counts().unwrap();
        assert_eq!(counts.len(), 1);
        assert_eq!(counts.get("claude-code"), Some(&1));
    }

    #[test]
    fn delete_all_removes_the_saved_copy() {
        let dir = tempfile::tempdir().unwrap();
        let index = NotesIndex::new(dir.path());
        apply(dir.path(), &scan(&[release()]), &[ClaudeCode]).unwrap();
        assert!(index.exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(database_path(dir.path()))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        // A search leaves SQLite's side files; they go too.
        assert_eq!(index.search("release", None, 5).unwrap().len(), 1);

        assert!(delete_all(dir.path()));

        assert!(!index.exists());
        assert!(
            index.search("release", None, 5).unwrap().is_empty(),
            "searching never recreates it"
        );
        assert!(!index.exists());
        let left: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name())
            .collect();
        assert!(left.is_empty(), "{left:?}");
    }
}
