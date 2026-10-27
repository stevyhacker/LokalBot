//! Keyword search over meetings (`SearchIndex.swift`) and screen text
//! (`ActivityStore.searchOCR`), both SQLite FTS5 in `lokalbotv3.sqlite`.

use std::path::Path;

use anyhow::{Result, bail};
use chrono::{DateTime, NaiveDate, Utc};
use rusqlite::{Connection, OptionalExtension as _, params, params_from_iter};
use uuid::Uuid;

use crate::library::Library;
use crate::model::*;
use crate::time::to_epoch;
use crate::timeline::table_exists;

/// Files whose contents become documents; any newer write reindexes.
pub const SOURCE_FILES: &[&str] = &[
    "meta.json",
    "transcript.json",
    "summary.md",
    "notes.md",
    "outcomes.json",
    "outcome-state.json",
];

/// Source file behind each removable document kind: deleting one cannot
/// raise the newest modification time, so its rows are checked separately.
const DOCUMENT_SOURCES: &[(DocKind, &str)] = &[
    (DocKind::Segment, "transcript.json"),
    (DocKind::Summary, "summary.md"),
    (DocKind::Notes, "notes.md"),
    (DocKind::Outcome, "outcomes.json"),
];

const DOCUMENT_ROWS_MIGRATION: &str = "search-document-rows-v1";
const NOTES_OUTCOMES_MIGRATION: &str = "search-notes-outcomes-v1";

/// Function words dropped from natural-language queries in OR mode.
pub const STOP_WORDS: &[&str] = &[
    "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "for", "with",
    "about", "as", "by", "from", "into", "is", "are", "was", "were", "be", "been", "being", "do",
    "does", "did", "doing", "have", "has", "had", "what", "when", "where", "who", "whom", "which",
    "why", "how", "we", "i", "you", "he", "she", "it", "they", "me", "us", "them", "my", "our",
    "your", "this", "that", "these", "those", "can", "could", "would", "should", "will", "shall",
    "may", "might", "must", "any", "some", "there",
];

/// The kind of an indexed document (`docs.kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum DocKind {
    Title,
    Segment,
    Summary,
    Notes,
    Outcome,
}

impl DocKind {
    pub const ALL: [DocKind; 5] = [
        Self::Title,
        Self::Segment,
        Self::Summary,
        Self::Notes,
        Self::Outcome,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            DocKind::Title => "title",
            DocKind::Segment => "segment",
            DocKind::Summary => "summary",
            DocKind::Notes => "notes",
            DocKind::Outcome => "outcome",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.as_str() == raw)
    }
}

/// A keyword search. `kinds`/`meeting_ids` restrict the documents;
/// `since`/`until` restrict meetings by start time (`until` exclusive).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SearchQuery {
    pub text: String,
    pub kinds: Option<Vec<DocKind>>,
    pub meeting_ids: Option<Vec<Uuid>>,
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
    pub limit: usize,
}

impl SearchQuery {
    pub fn new(text: impl Into<String>, limit: usize) -> Self {
        Self {
            text: text.into(),
            limit,
            ..Default::default()
        }
    }
}

/// One matching document.
#[derive(Clone, Debug, PartialEq)]
pub struct SearchHit {
    pub meeting_id: Uuid,
    pub kind: DocKind,
    /// Segment start in seconds (transcript hits only).
    pub start: Option<f64>,
    /// Display name of the segment's speaker.
    pub speaker: Option<String>,
    /// A few words around the match, matched terms wrapped in « ».
    pub snippet: String,
    /// The whole document row.
    pub text: String,
    /// FTS5 bm25 rank; lower is better.
    pub rank: f64,
}

/// How query terms combine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatchMode {
    /// Every term, the last one as a prefix (search as you type).
    All,
    /// Any term, stop words dropped unless every term is one.
    Any,
}

/// The FTS5 expression for `raw` (`SearchIndex.ftsQuery`): terms quoted so
/// punctuation cannot cause syntax errors.
pub fn fts_query(raw: &str, mode: MatchMode) -> Option<String> {
    let mut terms: Vec<String> = raw
        .split_whitespace()
        .map(|t| t.replace('"', ""))
        .filter(|t| !t.is_empty())
        .collect();
    if mode == MatchMode::Any {
        let content: Vec<String> = terms
            .iter()
            .filter(|t| !STOP_WORDS.contains(&t.to_lowercase().as_str()))
            .cloned()
            .collect();
        if !content.is_empty() {
            terms = content;
        }
    }
    if terms.is_empty() {
        return None;
    }
    Some(match mode {
        MatchMode::Any => terms
            .iter()
            .map(|t| format!("\"{t}\""))
            .collect::<Vec<_>>()
            .join(" OR "),
        MatchMode::All => {
            let last = terms.len() - 1;
            terms
                .iter()
                .enumerate()
                .map(|(i, t)| {
                    if i == last {
                        format!("\"{t}\" *")
                    } else {
                        format!("\"{t}\"")
                    }
                })
                .collect::<Vec<_>>()
                .join(" ")
        }
    })
}

struct Document {
    text: String,
    kind: DocKind,
    start: f64,
    speaker: String,
}

fn mtime(path: &Path) -> Option<f64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(to_epoch(DateTime::<Utc>::from(modified)))
}

/// Newest modification time among the meeting's source files, epoch seconds.
pub fn source_mtime(folder: &Path) -> f64 {
    SOURCE_FILES
        .iter()
        .filter_map(|name| mtime(&folder.join(name)))
        .fold(0.0, f64::max)
}

/// Creates the search tables' migrations for libraries indexed by older
/// app versions (`backfillDocumentRowsIfNeeded`, notes/outcomes backfill).
pub(crate) fn migrate(db: &Connection) -> Result<()> {
    let done = |name: &str| -> Result<bool> {
        Ok(db
            .query_row(
                "SELECT 1 FROM search_index_migrations WHERE name = ?1",
                [name],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    };
    if !done(DOCUMENT_ROWS_MIGRATION)? {
        let tx = db.unchecked_transaction()?;
        tx.execute("DELETE FROM search_document_rows", [])?;
        tx.execute(
            "INSERT INTO search_document_rows (doc_rowid, meeting_id) SELECT rowid, meeting_id FROM docs \
             WHERE meeting_id IS NOT NULL AND meeting_id != ''",
            [],
        )?;
        tx.execute(
            "INSERT INTO search_index_migrations (name) VALUES (?1)",
            [DOCUMENT_ROWS_MIGRATION],
        )?;
        tx.commit()?;
    }
    if !done(NOTES_OUTCOMES_MIGRATION)? {
        let tx = db.unchecked_transaction()?;
        tx.execute("UPDATE indexed_meetings SET source_mtime = 0", [])?;
        tx.execute(
            "INSERT INTO search_index_migrations (name) VALUES (?1)",
            [NOTES_OUTCOMES_MIGRATION],
        )?;
        tx.commit()?;
    }
    reconcile_deleted(db)?;
    Ok(())
}

/// Finishes cleanup for tombstoned meetings (`reconcileDeletedMeetings`).
fn reconcile_deleted(db: &Connection) -> Result<()> {
    let tx = db.unchecked_transaction()?;
    tx.execute(
        "DELETE FROM docs WHERE rowid IN (SELECT doc_rowid FROM search_document_rows \
         WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings))",
        [],
    )?;
    tx.execute(
        "DELETE FROM search_document_rows WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)",
        [],
    )?;
    tx.execute(
        "DELETE FROM indexed_meetings WHERE meeting_id IN (SELECT meeting_id FROM deleted_meetings)",
        [],
    )?;
    tx.commit()?;
    Ok(())
}

pub(crate) fn delete_documents(db: &Connection, meeting_id: &str) -> Result<()> {
    db.execute(
        "DELETE FROM docs WHERE rowid IN (SELECT doc_rowid FROM search_document_rows WHERE meeting_id = ?1)",
        [meeting_id],
    )?;
    db.execute(
        "DELETE FROM search_document_rows WHERE meeting_id = ?1",
        [meeting_id],
    )?;
    Ok(())
}

fn has_removed_source(db: &Connection, meeting_id: &str, folder: &Path) -> Result<bool> {
    let mut statement = db.prepare(
        "SELECT DISTINCT docs.kind FROM search_document_rows AS source \
         JOIN docs ON docs.rowid = source.doc_rowid WHERE source.meeting_id = ?1",
    )?;
    let kinds: Vec<String> = statement
        .query_map([meeting_id], |row| row.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    Ok(DOCUMENT_SOURCES.iter().any(|(kind, file)| {
        kinds.iter().any(|k| k == kind.as_str()) && !folder.join(file).exists()
    }))
}

fn indexed_mtime(db: &Connection, meeting_id: &str) -> Result<Option<f64>> {
    Ok(db
        .query_row(
            "SELECT source_mtime FROM indexed_meetings WHERE meeting_id = ?1",
            [meeting_id],
            |row| row.get(0),
        )
        .optional()?)
}

fn is_tombstoned(db: &Connection, meeting_id: &str) -> Result<bool> {
    Ok(db
        .query_row(
            "SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
            [meeting_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

impl Library {
    /// One searchable row per decision, action (with the user's corrections)
    /// and open question (`SearchIndex.outcomeTexts`).
    pub fn outcome_search_texts(&self, meeting: &Meeting) -> Result<Vec<String>> {
        let Some(projection) = self.outcome_projection(meeting)? else {
            return Ok(Vec::new());
        };
        let mut out: Vec<String> = projection
            .outcomes
            .decision_records
            .iter()
            .map(|d| format!("Decision: {}", d.text))
            .collect();
        for reference in projection.action_references() {
            let mut details = Vec::new();
            if let Some(owner) = reference
                .owner
                .as_deref()
                .map(str::trim)
                .filter(|o| !o.is_empty())
            {
                details.push(format!("owner {owner}"));
            }
            if let Some(due) = reference
                .due
                .as_deref()
                .map(str::trim)
                .filter(|d| !d.is_empty())
            {
                details.push(format!("due {due}"));
            }
            let suffix = if details.is_empty() {
                String::new()
            } else {
                format!(" ({})", details.join(", "))
            };
            out.push(format!("Action: {}{suffix}", reference.text));
        }
        out.extend(
            projection
                .outcomes
                .open_questions
                .iter()
                .map(|q| format!("Open question: {q}")),
        );
        Ok(out)
    }

    /// Re-indexes one meeting when its files changed since the last pass.
    pub fn reindex_meeting(&self, meeting: &Meeting) -> Result<()> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        let folder = self.meeting_dir(meeting);
        if !folder.is_dir() {
            return Ok(());
        }
        let id = crate::ids::uuid_upper(&meeting.id);
        let mtime = source_mtime(&folder);
        let fresh = self.with_db(|db| {
            Ok(
                indexed_mtime(db, &id)?.is_some_and(|indexed| indexed >= mtime)
                    && !has_removed_source(db, &id, &folder)?,
            )
        })?;
        if fresh {
            return Ok(());
        }

        let mut documents = vec![Document {
            text: format!("{} {}", meeting.title, meeting.app_name),
            kind: DocKind::Title,
            start: 0.0,
            speaker: String::new(),
        }];
        if let Ok(Some(transcript)) = self.transcript(meeting) {
            let roster = transcript.speaker_roster();
            for segment in &transcript.segments {
                documents.push(Document {
                    text: segment.text.clone(),
                    kind: DocKind::Segment,
                    start: segment.start,
                    speaker: roster
                        .get(&Transcript::canonical_speaker_key(&segment.speaker))
                        .cloned()
                        .unwrap_or_else(|| Transcript::default_speaker_name(&segment.speaker)),
                });
            }
        }
        if let Ok(Some(summary)) = self.summary(meeting) {
            documents.push(Document {
                text: summary,
                kind: DocKind::Summary,
                start: 0.0,
                speaker: String::new(),
            });
        }
        let notes = self.notes(meeting).unwrap_or_default();
        if !notes.trim().is_empty() {
            documents.push(Document {
                text: notes,
                kind: DocKind::Notes,
                start: 0.0,
                speaker: String::new(),
            });
        }
        for text in self.outcome_search_texts(meeting).unwrap_or_default() {
            documents.push(Document {
                text,
                kind: DocKind::Outcome,
                start: 0.0,
                speaker: String::new(),
            });
        }
        documents.retain_mut(|d| {
            d.text = d.text.trim().to_string();
            !d.text.is_empty()
        });

        self.with_db(|db| {
            let tx = rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Immediate)?;
            // A deletion that committed first wins; an older snapshot never
            // overwrites a newer one.
            if is_tombstoned(&tx, &id)? || !folder.exists() {
                return Ok(());
            }
            if indexed_mtime(&tx, &id)?.is_some_and(|indexed| indexed >= mtime)
                && !has_removed_source(&tx, &id, &folder)?
            {
                return Ok(());
            }
            delete_documents(&tx, &id)?;
            {
                let mut insert_doc =
                    tx.prepare("INSERT INTO docs (text, meeting_id, kind, start, speaker) VALUES (?1, ?2, ?3, ?4, ?5)")?;
                let mut insert_row =
                    tx.prepare("INSERT INTO search_document_rows (doc_rowid, meeting_id) VALUES (?1, ?2)")?;
                for document in &documents {
                    insert_doc.execute(params![document.text, id, document.kind.as_str(), document.start, document.speaker])?;
                    insert_row.execute(params![tx.last_insert_rowid(), id])?;
                }
            }
            tx.execute(
                "INSERT OR REPLACE INTO indexed_meetings (meeting_id, source_mtime) VALUES (?1, ?2)",
                params![id, mtime],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    /// Re-indexes every changed meeting and drops rows of meetings that no
    /// longer exist on disk. Returns how many meetings were (re)indexed.
    pub fn reindex_stale(&self) -> Result<usize> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        let all = self.list_all_meetings()?;
        let visible = self.list_meetings()?;
        let mut count = 0;
        for meeting in &visible {
            let id = crate::ids::uuid_upper(&meeting.id);
            let before = self.with_db(|db| indexed_mtime(db, &id))?;
            if let Err(err) = self.reindex_meeting(meeting) {
                log::warn!("indexing {} failed: {err:#}", meeting.short_id());
                continue;
            }
            if self.with_db(|db| indexed_mtime(db, &id))? != before {
                count += 1;
            }
        }
        let live: std::collections::HashSet<String> =
            all.iter().map(|m| crate::ids::uuid_upper(&m.id)).collect();
        self.with_db(|db| {
            let mut statement = db.prepare("SELECT meeting_id FROM indexed_meetings")?;
            let indexed: Vec<String> = statement
                .query_map([], |row| row.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            for id in indexed.iter().filter(|id| !live.contains(*id)) {
                let tx = db.unchecked_transaction()?;
                delete_documents(&tx, id)?;
                tx.execute("DELETE FROM indexed_meetings WHERE meeting_id = ?1", [id])?;
                tx.commit()?;
            }
            Ok(())
        })?;
        Ok(count)
    }

    /// Keyword search: every term (the last as a prefix), falling back to
    /// any term with stop words dropped when nothing matches.
    pub fn search(&self, query: &SearchQuery) -> Result<Vec<SearchHit>> {
        let hits = self.search_with_mode(query, MatchMode::All)?;
        if !hits.is_empty() {
            return Ok(hits);
        }
        self.search_with_mode(query, MatchMode::Any)
    }

    /// Keyword search in one explicit mode, ordered by bm25 rank.
    pub fn search_with_mode(&self, query: &SearchQuery, mode: MatchMode) -> Result<Vec<SearchHit>> {
        if query.limit == 0 {
            return Ok(Vec::new());
        }
        let Some(expression) = fts_query(&query.text, mode) else {
            return Ok(Vec::new());
        };
        let mut scope: Option<Vec<String>> = query
            .meeting_ids
            .as_ref()
            .map(|ids| ids.iter().map(crate::ids::uuid_upper).collect());
        if query.since.is_some() || query.until.is_some() {
            let in_range: Vec<String> = self
                .list_meetings()?
                .into_iter()
                .filter(|m| {
                    query.since.is_none_or(|s| m.started_at >= s)
                        && query.until.is_none_or(|u| m.started_at < u)
                })
                .map(|m| crate::ids::uuid_upper(&m.id))
                .collect();
            scope = Some(match scope {
                Some(ids) => ids.into_iter().filter(|id| in_range.contains(id)).collect(),
                None => in_range,
            });
        }
        if scope.as_ref().is_some_and(Vec::is_empty)
            || query.kinds.as_ref().is_some_and(Vec::is_empty)
        {
            return Ok(Vec::new());
        }
        self.with_db(|db| {
            if !table_exists(db, "docs")? {
                return Ok(Vec::new());
            }
            let mut sql = String::from(
                "SELECT meeting_id, kind, start, speaker, snippet(docs, 0, '«', '»', '…', 14), text, rank \
                 FROM docs WHERE docs MATCH ?1 AND NOT EXISTS (SELECT 1 FROM deleted_meetings AS deleted \
                 WHERE deleted.meeting_id = docs.meeting_id)",
            );
            let mut values: Vec<String> = vec![expression];
            if let Some(kinds) = &query.kinds {
                let placeholders: Vec<String> = kinds
                    .iter()
                    .map(|kind| {
                        values.push(kind.as_str().to_string());
                        format!("?{}", values.len())
                    })
                    .collect();
                sql.push_str(&format!(" AND kind IN ({})", placeholders.join(", ")));
            }
            if let Some(ids) = &scope {
                let mut sorted = ids.clone();
                sorted.sort();
                let placeholders: Vec<String> = sorted
                    .into_iter()
                    .map(|id| {
                        values.push(id);
                        format!("?{}", values.len())
                    })
                    .collect();
                sql.push_str(&format!(" AND meeting_id IN ({})", placeholders.join(", ")));
            }
            sql.push_str(&format!(" ORDER BY rank LIMIT {}", query.limit));
            let mut statement = db.prepare(&sql)?;
            let rows = statement.query_map(params_from_iter(values.iter()), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<f64>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, f64>(6)?,
                ))
            })?;
            let mut hits = Vec::new();
            for row in rows {
                let (id, kind, start, speaker, snippet, text, rank) = row?;
                let (Ok(meeting_id), Some(kind)) = (Uuid::parse_str(&id), DocKind::parse(&kind)) else { continue };
                hits.push(SearchHit {
                    meeting_id,
                    kind,
                    start: (kind == DocKind::Segment).then_some(start.unwrap_or(0.0)),
                    speaker: speaker.filter(|s| !s.is_empty()),
                    snippet,
                    text,
                    rank,
                });
            }
            Ok(hits)
        })
    }

    /// Every meeting with a document matching all terms (Meetings list filter).
    pub fn matching_meeting_ids(&self, text: &str) -> Result<Vec<Uuid>> {
        let Some(expression) = fts_query(text, MatchMode::All) else {
            return Ok(Vec::new());
        };
        self.with_db(|db| {
            if !table_exists(db, "docs")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT DISTINCT meeting_id FROM docs WHERE docs MATCH ?1 AND NOT EXISTS \
                 (SELECT 1 FROM deleted_meetings AS deleted WHERE deleted.meeting_id = docs.meeting_id)",
            )?;
            let ids: Vec<String> = statement.query_map([expression], |row| row.get(0))?.collect::<rusqlite::Result<_>>()?;
            Ok(ids.iter().filter_map(|id| Uuid::parse_str(id).ok()).collect())
        })
    }

    /// Screen text search, one result per window and day (or similarity
    /// group), best match first. All terms first, then any term.
    pub fn search_screen(
        &self,
        text: &str,
        day: Option<NaiveDate>,
        app: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ScreenMoment>> {
        Ok(self
            .search_screen_hits(text, day, app, limit)?
            .into_iter()
            .map(|h| h.moment)
            .collect())
    }

    /// `search_screen` with snippets, ranks and duplicate counts.
    pub fn search_screen_hits(
        &self,
        text: &str,
        day: Option<NaiveDate>,
        app: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ScreenHit>> {
        let interval = day.map(crate::time::local_day_bounds);
        let hits = self.search_ocr(text, MatchMode::All, interval, app, limit)?;
        if !hits.is_empty() {
            return Ok(hits);
        }
        self.search_ocr(text, MatchMode::Any, interval, app, limit)
    }

    /// `ActivityStore.searchOCR` in grouped mode; `interval` is half-open and
    /// `app` matches the stored name case-insensitively.
    pub fn search_ocr(
        &self,
        text: &str,
        mode: MatchMode,
        interval: Option<(DateTime<Utc>, DateTime<Utc>)>,
        app: Option<&str>,
        limit: usize,
    ) -> Result<Vec<ScreenHit>> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let Some(expression) = fts_query(text, mode) else {
            return Ok(Vec::new());
        };
        self.with_db(|db| {
            if !table_exists(db, "ocr_fts")? || !table_exists(db, "screenshots")? {
                return Ok(Vec::new());
            }
            let mut conditions = vec!["ocr_fts MATCH ?1".to_string(), "CAST(ocr_fts.snapshot_id AS INTEGER) > 0".to_string()];
            let mut values: Vec<rusqlite::types::Value> = vec![expression.into()];
            if let Some((start, end)) = interval {
                values.push(to_epoch(start).into());
                conditions.push(format!("CAST(ocr_fts.ts AS REAL) >= ?{}", values.len()));
                values.push(to_epoch(end).into());
                conditions.push(format!("CAST(ocr_fts.ts AS REAL) < ?{}", values.len()));
            }
            if let Some(app) = app.map(str::trim).filter(|a| !a.is_empty()) {
                values.push(app.to_string().into());
                conditions.push(format!("ocr_fts.app = ?{} COLLATE NOCASE", values.len()));
            }
            let sql = format!(
                "WITH candidates AS (
                    SELECT CAST(ocr_fts.snapshot_id AS INTEGER) AS snapshot_id,
                           CAST(ocr_fts.ts AS REAL) AS captured_at,
                           snippet(ocr_fts, 0, '«', '»', '…', 14) AS snippet_text,
                           ocr_fts.rank AS match_rank,
                           CASE WHEN shot.similarity_group > 0
                                THEN 'group:' || CAST(shot.similarity_group AS TEXT)
                                ELSE 'fallback:' || lower(CAST(ocr_fts.app AS TEXT)) || char(31)
                                     || lower(CAST(ocr_fts.window_title AS TEXT)) || char(31)
                                     || strftime('%Y-%m-%d', CAST(ocr_fts.ts AS REAL), 'unixepoch', 'localtime')
                           END AS deduplication_key
                    FROM ocr_fts JOIN screenshots AS shot ON shot.id = CAST(ocr_fts.snapshot_id AS INTEGER)
                    WHERE {}
                ), grouped AS (
                    SELECT *, ROW_NUMBER() OVER (PARTITION BY deduplication_key
                                                 ORDER BY match_rank, captured_at DESC, snapshot_id) AS evidence_rank,
                              COUNT(*) OVER (PARTITION BY deduplication_key) AS capture_count
                    FROM candidates
                )
                SELECT snapshot_id, snippet_text, match_rank, capture_count FROM grouped
                WHERE evidence_rank = 1 ORDER BY match_rank, captured_at DESC, snapshot_id LIMIT {limit}",
                conditions.join(" AND ")
            );
            let mut statement = db.prepare(&sql)?;
            let rows: Vec<(i64, String, f64, i64)> = statement
                .query_map(params_from_iter(values.iter()), |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)))?
                .collect::<rusqlite::Result<_>>()?;
            let columns = crate::timeline::screen_columns(db)?;
            let mut moment_statement = db.prepare(&format!(
                "SELECT {columns} FROM screenshots AS shot \
                 LEFT JOIN screen_bookmarks AS bookmark ON bookmark.snapshot_id = shot.id WHERE shot.id = ?1"
            ))?;
            let mut hits = Vec::new();
            for (id, snippet, rank, count) in rows {
                if let Some(moment) = moment_statement.query_row([id], crate::timeline::screen_moment_from_row).optional()? {
                    hits.push(ScreenHit { moment, snippet, rank, capture_count: count.max(1) as usize });
                }
            }
            Ok(hits)
        })
    }

    /// Saved moments, newest first.
    pub fn saved_moments(&self) -> Result<Vec<ScreenMoment>> {
        self.with_db(|db| {
            if !table_exists(db, "screen_bookmarks")? {
                return Ok(Vec::new());
            }
            let columns = crate::timeline::screen_columns(db)?;
            let mut statement = db.prepare(&format!(
                "SELECT {columns} FROM screenshots AS shot JOIN screen_bookmarks AS bookmark \
                 ON bookmark.snapshot_id = shot.id ORDER BY bookmark.created_at DESC"
            ))?;
            let rows = statement.query_map([], crate::timeline::screen_moment_from_row)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }
}

/// A screen search result.
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenHit {
    pub moment: ScreenMoment,
    /// Matched words wrapped in « ».
    pub snippet: String,
    pub rank: f64,
    /// Captures of the same window and text folded into this one.
    pub capture_count: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_builder_matches_swift() {
        assert_eq!(
            fts_query("redis cluster", MatchMode::All).as_deref(),
            Some("\"redis\" \"cluster\" *")
        );
        assert_eq!(
            fts_query("  \"quoted\"  ", MatchMode::All).as_deref(),
            Some("\"quoted\" *")
        );
        assert_eq!(
            fts_query("what did we decide about caching", MatchMode::Any).as_deref(),
            Some("\"decide\" OR \"caching\"")
        );
        assert_eq!(
            fts_query("what is it", MatchMode::Any).as_deref(),
            Some("\"what\" OR \"is\" OR \"it\"")
        );
        assert_eq!(fts_query("   ", MatchMode::All), None);
    }

    #[test]
    fn indexes_searches_and_tombstones() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let meeting = library
            .create_meeting("Design review", "Zoom", crate::time::now_seconds())
            .unwrap();
        library
            .save_transcript(
                &meeting,
                &Transcript {
                    segments: vec![Segment {
                        start: 12.0,
                        end: 20.0,
                        speaker: "them".into(),
                        text: "Let's lock the caching layer with Redis.".into(),
                        confidence: None,
                        timing_precision: None,
                        attribution: None,
                    }],
                    speaker_aliases: [("them".to_string(), "Maya Chen".to_string())]
                        .into_iter()
                        .collect(),
                    ..Default::default()
                },
            )
            .unwrap();
        library.save_notes(&meeting, "Café décor budget").unwrap();
        assert_eq!(library.reindex_stale().unwrap(), 1);
        assert_eq!(library.reindex_stale().unwrap(), 0);

        let hits = library.search(&SearchQuery::new("redis cach", 10)).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].kind, DocKind::Segment);
        assert_eq!(hits[0].start, Some(12.0));
        assert_eq!(hits[0].speaker.as_deref(), Some("Maya Chen"));
        assert!(hits[0].snippet.contains("«Redis»"), "{}", hits[0].snippet);

        // Diacritics fold, kinds filter, OR fallback.
        assert_eq!(
            library.search(&SearchQuery::new("cafe decor", 10)).unwrap()[0].kind,
            DocKind::Notes
        );
        let titles = SearchQuery {
            kinds: Some(vec![DocKind::Title]),
            ..SearchQuery::new("design", 10)
        };
        assert_eq!(library.search(&titles).unwrap().len(), 1);
        assert_eq!(
            library
                .search(&SearchQuery::new("what about redis", 10))
                .unwrap()
                .len(),
            1
        );

        // Clearing notes removes their row even though no mtime advanced.
        library.save_notes(&meeting, "").unwrap();
        library.reindex_meeting(&meeting).unwrap();
        assert!(
            library
                .search(&SearchQuery::new("decor", 10))
                .unwrap()
                .is_empty()
        );

        library.delete_meeting(&meeting).unwrap();
        assert!(
            library
                .search(&SearchQuery::new("redis", 10))
                .unwrap()
                .is_empty()
        );
    }
}
