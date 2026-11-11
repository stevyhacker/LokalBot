//! Read side of the saved coding-agent notes (`AgentNotesIndex`):
//! `agent-notes.sqlite` in the library, written only by the app
//! ([`super::store`]). Every call opens the file read-only and closes it, so
//! the CLI and the app can both search while the app replaces notes.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context as _, Result};
use chrono::{DateTime, Utc};
use rusqlite::types::Value;
use rusqlite::{Connection, OpenFlags, OptionalExtension as _, Row, params, params_from_iter};

use super::cjk;
use crate::time::from_epoch;

/// Column weights for title, summary and text.
const RANK: &str = "bm25(notes_fts, 10.0, 4.0, 1.0)";
const SNIPPET: &str = "snippet(notes_fts, 2, '«', '»', '…', 18)";
const COLUMNS: &str =
    "n.id, n.agent, n.title, n.summary, n.category, n.working_directory, n.path, n.modified";

/// One saved coding-agent note as a search returns it.
#[derive(Clone, Debug, PartialEq)]
pub struct NoteHit {
    /// Stable id of the note, cited as `[note:id]`.
    pub id: String,
    /// `claude-code` or `codex`.
    pub agent: String,
    pub title: String,
    pub summary: Option<String>,
    /// Claude Code's own label: user, feedback, project, or reference.
    pub category: Option<String>,
    pub working_directory: Option<String>,
    /// The agent's file the note was read from.
    pub path: String,
    pub modified: DateTime<Utc>,
    /// A passage around the match, the matched words between « and ».
    pub snippet: String,
}

impl NoteHit {
    pub fn agent_name(&self) -> String {
        agent_name(&self.agent)
    }

    pub fn project_name(&self) -> Option<String> {
        super::project_name(self.working_directory.as_deref())
    }

    /// "Claude Code · LokalBot", for a row's second line.
    pub fn source_label(&self) -> String {
        match self.project_name() {
            Some(project) => format!("{} · {project}", self.agent_name()),
            None => self.agent_name(),
        }
    }
}

pub fn agent_name(agent: &str) -> String {
    match agent {
        "claude-code" => "Claude Code".into(),
        "codex" => "Codex".into(),
        other => other.into(),
    }
}

/// `CharacterSet.alphanumerics`: letters, marks and numbers.
fn is_word_character(c: char) -> bool {
    c.is_alphanumeric() || unicode_normalization::char::is_combining_mark(c)
}

fn optional(value: String) -> Option<String> {
    (!value.is_empty()).then_some(value)
}

fn hit(row: &Row) -> rusqlite::Result<NoteHit> {
    Ok(NoteHit {
        id: row.get(0)?,
        agent: row.get(1)?,
        title: row.get(2)?,
        summary: optional(row.get(3)?),
        category: optional(row.get(4)?),
        working_directory: optional(row.get(5)?),
        path: row.get(6)?,
        modified: from_epoch(row.get(7)?),
        snippet: row.get(8)?,
    })
}

#[derive(Clone, Debug)]
pub struct NotesIndex {
    database: PathBuf,
}

impl NotesIndex {
    pub fn new(root: &Path) -> Self {
        Self {
            database: super::database_path(root),
        }
    }

    pub fn exists(&self) -> bool {
        self.database.is_file()
    }

    /// Query-only, so nothing here can grow a write path to the notes.
    fn connection(&self) -> Result<Connection> {
        let db = Connection::open_with_flags(
            &self.database,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .context("Agent notes are unavailable")?;
        db.busy_timeout(Duration::from_secs(5))?;
        Ok(db)
    }

    /// Notes matching every word of `query`, best first; when none has every
    /// word, notes matching any. The last word also matches as a prefix, so
    /// results appear while it is typed.
    pub fn search(&self, query: &str, agent: Option<&str>, limit: usize) -> Result<Vec<NoteHit>> {
        if limit == 0 || !self.exists() {
            return Ok(Vec::new());
        }
        // FTS5 cannot see words inside a run of CJK text.
        if cjk::contains_cjk(query) {
            return self.substring_search(query, agent, limit);
        }
        let terms: Vec<&str> = query
            .split(|c: char| !is_word_character(c))
            .filter(|term| !term.is_empty())
            .collect();
        if terms.is_empty() {
            return Ok(Vec::new());
        }
        let quoted: Vec<String> = terms
            .iter()
            .enumerate()
            .map(|(index, term)| {
                let phrase = format!("\"{}\"", term.replace('"', "\"\""));
                if index == terms.len() - 1 && term.chars().count() >= 3 {
                    format!("{phrase}*")
                } else {
                    phrase
                }
            })
            .collect();
        let every = self.fts_search(&quoted.join(" AND "), agent, limit)?;
        if !every.is_empty() || quoted.len() < 2 {
            return Ok(every);
        }
        self.fts_search(&quoted.join(" OR "), agent, limit)
    }

    /// The note with this id, its snippet the opening of its text.
    pub fn hit(&self, id: &str) -> Result<Option<NoteHit>> {
        if !self.exists() {
            return Ok(None);
        }
        let sql = format!(
            "SELECT {COLUMNS}, substr(n.text, 1, 240) FROM notes n WHERE n.id = ?1 LIMIT 1"
        );
        Ok(self
            .connection()?
            .query_row(&sql, params![id], hit)
            .optional()?)
    }

    pub fn text_of(&self, id: &str) -> Result<Option<String>> {
        if !self.exists() {
            return Ok(None);
        }
        Ok(self
            .connection()?
            .query_row(
                "SELECT text FROM notes WHERE id = ?1 LIMIT 1",
                params![id],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// How many notes are saved per agent.
    pub fn counts(&self) -> Result<BTreeMap<String, usize>> {
        if !self.exists() {
            return Ok(BTreeMap::new());
        }
        let db = self.connection()?;
        let mut statement = db.prepare("SELECT agent, COUNT(*) FROM notes GROUP BY agent")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        let mut counts = BTreeMap::new();
        for row in rows {
            let (agent, count) = row?;
            *counts.entry(agent).or_insert(0) += usize::try_from(count).unwrap_or(0);
        }
        Ok(counts)
    }

    /// Every saved note, counted.
    pub fn total(&self) -> usize {
        self.counts()
            .map(|counts| counts.values().sum())
            .unwrap_or(0)
    }

    fn fts_search(
        &self,
        expression: &str,
        agent: Option<&str>,
        limit: usize,
    ) -> Result<Vec<NoteHit>> {
        let mut sql = format!(
            "SELECT {COLUMNS}, {SNIPPET}
             FROM notes_fts JOIN notes n ON n.rowid = notes_fts.rowid
             WHERE notes_fts MATCH ?1"
        );
        let mut bindings: Vec<Value> = vec![Value::Text(expression.to_string())];
        if let Some(agent) = agent {
            bindings.push(Value::Text(agent.to_string()));
            sql.push_str(&format!(" AND n.agent = ?{}", bindings.len()));
        }
        bindings.push(Value::Integer(i64::try_from(limit).unwrap_or(i64::MAX)));
        sql.push_str(&format!(
            " ORDER BY {RANK}, n.modified DESC LIMIT ?{}",
            bindings.len()
        ));
        let db = self.connection()?;
        let mut statement = db.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(bindings), hit)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn substring_search(
        &self,
        query: &str,
        agent: Option<&str>,
        limit: usize,
    ) -> Result<Vec<NoteHit>> {
        let terms = cjk::terms(query);
        if terms.is_empty() {
            return Ok(Vec::new());
        }
        let mut bindings: Vec<Value> = Vec::new();
        let conditions: Vec<String> = terms
            .iter()
            .map(|term| {
                bindings.push(Value::Text(cjk::like_pattern(term)));
                let pattern = format!("?{}", bindings.len());
                format!("(n.text LIKE {pattern} ESCAPE '\\' OR n.title LIKE {pattern} ESCAPE '\\')")
            })
            .collect();
        let mut sql = format!(
            "SELECT {COLUMNS}, n.text FROM notes n WHERE {}",
            conditions.join(" AND ")
        );
        if let Some(agent) = agent {
            bindings.push(Value::Text(agent.to_string()));
            sql.push_str(&format!(" AND n.agent = ?{}", bindings.len()));
        }
        bindings.push(Value::Integer(i64::try_from(limit).unwrap_or(i64::MAX)));
        sql.push_str(&format!(
            " ORDER BY n.modified DESC LIMIT ?{}",
            bindings.len()
        ));
        let db = self.connection()?;
        let mut statement = db.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(bindings), hit)?;
        let mut hits: Vec<NoteHit> = rows.collect::<rusqlite::Result<_>>()?;
        for hit in &mut hits {
            hit.snippet = cjk::snippet(&hit.snippet, &terms)
                .unwrap_or_else(|| hit.snippet.chars().take(72).collect());
        }
        Ok(hits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agent_notes::AgentNote;
    use crate::agent_notes::store::tests::{build, release, scan};
    use crate::agent_notes::store::{apply, delete_all};
    use crate::coding_agents::CodingAgentKind::{ClaudeCode, Codex};

    fn ids(hits: &[NoteHit]) -> Vec<&str> {
        hits.iter().map(|hit| hit.id.as_str()).collect()
    }

    #[test]
    fn search_prefers_every_word_then_falls_back_to_any_and_ranks_titles_first() {
        let dir = tempfile::tempdir().unwrap();
        let index = NotesIndex::new(dir.path());
        let mention = AgentNote {
            id: "c0ffee000003".into(),
            title: "Unrelated chores".into(),
            text: "Remember the release checklist lives in the wiki.".into(),
            ..build()
        };
        apply(
            dir.path(),
            &scan(&[release(), build(), mention.clone()]),
            &[ClaudeCode, Codex],
        )
        .unwrap();

        let hits = index.search("release", None, 5).unwrap();
        assert_eq!(
            ids(&hits),
            [release().id.as_str(), mention.id.as_str()],
            "a title match outranks a mention in the text"
        );
        assert_eq!(hits[0].agent_name(), "Claude Code");
        assert_eq!(hits[0].source_label(), "Claude Code · app");
        assert_eq!(hits[1].source_label(), "Codex");
        assert!(hits[1].snippet.contains("«release»"), "{}", hits[1].snippet);

        assert_eq!(
            ids(&index.search("release SHA", None, 5).unwrap()),
            [release().id.as_str()]
        );
        assert_eq!(
            ids(&index.search("xcodebuild gardening", None, 5).unwrap()),
            [build().id.as_str()],
            "no note has both words, so any word matches"
        );
        assert!(index.search("notar", None, 5).unwrap().is_empty());
        assert_eq!(
            index.search("rele", None, 5).unwrap().len(),
            2,
            "the word being typed matches as a prefix"
        );
        assert_eq!(
            ids(&index.search("release", Some("codex"), 5).unwrap()),
            [mention.id.as_str()]
        );
        assert!(index.search("  ", None, 5).unwrap().is_empty());
        assert!(
            index
                .search("\"); DROP TABLE notes; --", None, 5)
                .unwrap()
                .is_empty()
        );
        assert!(index.search("release", None, 0).unwrap().is_empty());
        assert_eq!(index.total(), 3);
    }

    #[test]
    fn search_finds_words_inside_chinese_text() {
        let dir = tempfile::tempdir().unwrap();
        let chinese = AgentNote {
            id: "c0ffee000004".into(),
            title: "发布流程".into(),
            text: "发布前先运行全部单元测试，然后打标签。".into(),
            ..release()
        };
        apply(
            dir.path(),
            &scan(&[chinese.clone(), build()]),
            &[ClaudeCode, Codex],
        )
        .unwrap();

        let hits = NotesIndex::new(dir.path())
            .search("单元测试", None, 5)
            .unwrap();
        assert_eq!(ids(&hits), [chinese.id.as_str()]);
        assert!(
            hits[0].snippet.contains("«单元测试»"),
            "{}",
            hits[0].snippet
        );
        assert!(
            NotesIndex::new(dir.path())
                .search("单元测试", Some("codex"), 5)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn hit_and_text_look_up_one_note() {
        let dir = tempfile::tempdir().unwrap();
        let index = NotesIndex::new(dir.path());
        assert_eq!(index.hit(&release().id).unwrap(), None, "nothing saved yet");
        assert!(index.counts().unwrap().is_empty());
        apply(dir.path(), &scan(&[release()]), &[ClaudeCode]).unwrap();

        let found = index.hit(&release().id).unwrap().unwrap();
        assert_eq!(found.title, "Release runbook");
        assert_eq!(found.modified, release().modified_at);
        assert_eq!(found.category.as_deref(), Some("project"));
        assert_eq!(found.snippet, release().text);
        assert_eq!(
            index.text_of(&release().id).unwrap().as_deref(),
            Some(release().text.as_str())
        );
        assert_eq!(index.hit("000000000000").unwrap(), None);

        assert!(delete_all(dir.path()));
        assert_eq!(index.text_of(&release().id).unwrap(), None);
    }
}
