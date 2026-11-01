//! Full-text search over the phone's copy: SQLite FTS5 with the unicode61
//! tokenizer, like the Mac's `SearchIndex`, plus the Mac's substring
//! fallback for Chinese, Japanese and Korean text (`CJKSearch.swift`).

use std::collections::HashMap;

use rusqlite::{Connection, Transaction, params, params_from_iter};
use serde_json::Value;

use super::store::is_indexed;
use crate::error::Result;
use crate::records::{DAY, MEETING, TRANSCRIPT, str_field};

/// One search result.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct SearchHit {
    /// The record kind: `meeting`, `transcript` or `day`.
    pub kind: String,
    /// The record key: the meeting id, or the day for digests.
    pub key: String,
    pub meeting_id: Option<String>,
    /// The meeting title; the date for a day digest.
    pub title: String,
    /// Words around the match, matched terms in « ».
    pub snippet: String,
    /// Segment start in seconds, for transcript hits.
    pub at: Option<f64>,
    /// The meeting's day, or the digest's date.
    pub date: Option<String>,
}

/// Function words dropped from natural-language queries in OR mode
/// (`lokalbot-core::search::STOP_WORDS`).
const STOP_WORDS: &[&str] = &[
    "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "for", "with",
    "about", "as", "by", "from", "into", "is", "are", "was", "were", "be", "been", "being", "do",
    "does", "did", "doing", "have", "has", "had", "what", "when", "where", "who", "whom", "which",
    "why", "how", "we", "i", "you", "he", "she", "it", "they", "me", "us", "them", "my", "our",
    "your", "this", "that", "these", "those", "can", "could", "would", "should", "will", "shall",
    "may", "might", "must", "any", "some", "there",
];

/// Search documents for one record. Merged meetings are not indexed.
struct Document {
    field: &'static str,
    text: String,
    meeting_id: Option<String>,
    at: Option<f64>,
    date: Option<String>,
}

fn documents(kind: &str, key: &str, body: &Value) -> Vec<Document> {
    let mut docs = Vec::new();
    match kind {
        MEETING => {
            if body.get("mergedInto").is_some_and(|v| !v.is_null()) {
                return docs;
            }
            let date = str_field(body, "day").map(str::to_owned);
            let mut push = |field: &'static str, text: Option<&str>| {
                if let Some(text) = text.filter(|t| !t.trim().is_empty()) {
                    docs.push(Document {
                        field,
                        text: text.to_owned(),
                        meeting_id: Some(key.to_owned()),
                        at: None,
                        date: date.clone(),
                    });
                }
            };
            push("title", str_field(body, "title"));
            push("summary", str_field(body, "summaryMarkdown"));
            push("notes", str_field(body, "notesMarkdown"));
            for (list, field) in [
                ("actions", "action"),
                ("decisions", "decision"),
                ("openQuestions", "openQuestion"),
            ] {
                for item in body
                    .get(list)
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    push(field, str_field(item, "text"));
                }
            }
        }
        TRANSCRIPT => {
            let meeting_id = str_field(body, "meetingId").unwrap_or(key).to_owned();
            for segment in body
                .get("segments")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let Some(text) = str_field(segment, "text").filter(|t| !t.trim().is_empty()) {
                    docs.push(Document {
                        field: "segment",
                        text: text.to_owned(),
                        meeting_id: Some(meeting_id.clone()),
                        at: segment.get("start").and_then(Value::as_f64),
                        date: None,
                    });
                }
            }
        }
        DAY => {
            if let Some(markdown) = body.pointer("/digest/markdown").and_then(Value::as_str) {
                docs.push(Document {
                    field: "digest",
                    text: markdown.to_owned(),
                    meeting_id: None,
                    at: None,
                    date: Some(str_field(body, "date").unwrap_or(key).to_owned()),
                });
            }
        }
        _ => {}
    }
    docs
}

/// Replaces a record's documents; `None` removes them.
pub(crate) fn reindex(
    tx: &Transaction<'_>,
    kind: &str,
    key: &str,
    body: Option<&Value>,
) -> Result<()> {
    if !is_indexed(kind) {
        return Ok(());
    }
    tx.execute(
        "DELETE FROM docs WHERE rowid IN (SELECT id FROM doc_meta WHERE record_kind = ?1 AND record_key = ?2)",
        params![kind, key],
    )?;
    tx.execute(
        "DELETE FROM doc_meta WHERE record_kind = ?1 AND record_key = ?2",
        params![kind, key],
    )?;
    let Some(body) = body else {
        return Ok(());
    };
    let mut insert_meta = tx.prepare(
        "INSERT INTO doc_meta (record_kind, record_key, field, meeting_id, at, date) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
    )?;
    let mut insert_doc = tx.prepare("INSERT INTO docs (rowid, text) VALUES (?1, ?2)")?;
    for doc in documents(kind, key, body) {
        insert_meta.execute(params![
            kind,
            key,
            doc.field,
            doc.meeting_id,
            doc.at,
            doc.date
        ])?;
        insert_doc.execute(params![tx.last_insert_rowid(), doc.text])?;
    }
    Ok(())
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum MatchMode {
    /// Every term, the last as a prefix (search as you type).
    All,
    /// Any term, stop words dropped unless every term is one.
    Any,
}

/// The FTS5 expression for `raw`, terms quoted so punctuation cannot cause
/// syntax errors (`lokalbot-core::search::fts_query`).
fn fts_query(raw: &str, mode: MatchMode) -> Option<String> {
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

/// Documents of meetings merged into another are hidden like the meetings.
const NOT_MERGED: &str = "(m.meeting_id IS NULL OR m.meeting_id NOT IN \
    (SELECT key FROM records WHERE kind = 'meeting' AND deleted = 0 AND json_extract(body, '$.mergedInto') IS NOT NULL))";

struct Row {
    kind: String,
    key: String,
    meeting_id: Option<String>,
    at: Option<f64>,
    date: Option<String>,
    snippet: String,
}

/// Keyword search: all terms first, then any term, then (for CJK text) a
/// substring match, as on the Mac.
pub(crate) fn search(db: &Connection, query: &str, limit: usize) -> Result<Vec<SearchHit>> {
    let rows = if cjk::contains_cjk(query) {
        let mut rows = substring_search(db, query, limit, true, false)?;
        if rows.is_empty() {
            rows = substring_search(db, query, limit, false, false)?;
        }
        rows
    } else {
        let mut rows = fts_search(db, query, MatchMode::All, limit)?;
        if rows.is_empty() {
            rows = fts_search(db, query, MatchMode::Any, limit)?;
        }
        if rows.is_empty() {
            // A Latin word glued to CJK text ("比如logo再大") is part of that
            // run's token, so FTS cannot see it.
            rows = substring_search(db, query, limit, true, true)?;
        }
        rows
    };
    let mut titles: HashMap<String, Option<(String, Option<String>)>> = HashMap::new();
    let mut hits = Vec::with_capacity(rows.len());
    for row in rows {
        let (title, date) = match &row.meeting_id {
            Some(meeting_id) => {
                let meeting = match titles.get(meeting_id) {
                    Some(found) => found.clone(),
                    None => {
                        let found = meeting_title(db, meeting_id)?;
                        titles.insert(meeting_id.clone(), found.clone());
                        found
                    }
                };
                let (title, day) = meeting.unwrap_or_default();
                (title, row.date.clone().or(day))
            }
            None => (
                row.date.clone().unwrap_or_else(|| row.key.clone()),
                row.date.clone(),
            ),
        };
        hits.push(SearchHit {
            kind: row.kind,
            key: row.key,
            meeting_id: row.meeting_id,
            title,
            snippet: row.snippet,
            at: row.at,
            date,
        });
    }
    Ok(hits)
}

fn meeting_title(db: &Connection, meeting_id: &str) -> Result<Option<(String, Option<String>)>> {
    let mut statement = db.prepare(
        "SELECT json_extract(body, '$.title'), json_extract(body, '$.day') FROM records \
         WHERE kind = 'meeting' AND key = ?1 AND deleted = 0",
    )?;
    let mut rows = statement.query([meeting_id])?;
    Ok(match rows.next()? {
        Some(row) => Some((
            row.get::<_, Option<String>>(0)?.unwrap_or_default(),
            row.get(1)?,
        )),
        None => None,
    })
}

fn fts_search(db: &Connection, query: &str, mode: MatchMode, limit: usize) -> Result<Vec<Row>> {
    let Some(expression) = fts_query(query, mode) else {
        return Ok(Vec::new());
    };
    let sql = format!(
        "SELECT m.record_kind, m.record_key, m.meeting_id, m.at, m.date, snippet(docs, 0, '«', '»', '…', 14) \
         FROM docs JOIN doc_meta AS m ON m.id = docs.rowid \
         WHERE docs MATCH ?1 AND {NOT_MERGED} ORDER BY docs.rank LIMIT {limit}"
    );
    let mut statement = db.prepare(&sql)?;
    let rows = statement
        .query_map([expression], |row| {
            Ok(Row {
                kind: row.get(0)?,
                key: row.get(1)?,
                meeting_id: row.get(2)?,
                at: row.get(3)?,
                date: row.get(4)?,
                snippet: row.get(5)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows)
}

/// Substring counterpart of `fts_search` (`SearchIndex.substringSearch`).
/// Shorter documents first, as bm25 favours them; relaxed (OR) results rank
/// by how many pieces matched.
fn substring_search(
    db: &Connection,
    query: &str,
    limit: usize,
    match_all: bool,
    cjk_rows_only: bool,
) -> Result<Vec<Row>> {
    let terms = if match_all {
        cjk::terms(query)
    } else {
        cjk::relaxed_terms(query)
    };
    if terms.is_empty() {
        return Ok(Vec::new());
    }
    let mut values: Vec<String> = Vec::new();
    let clauses: Vec<String> = terms
        .iter()
        .map(|term| {
            values.push(cjk::like_pattern(term));
            format!("docs.text LIKE ?{} ESCAPE '\\'", values.len())
        })
        .collect();
    let mut conditions = vec![format!(
        "({})",
        clauses.join(if match_all { " AND " } else { " OR " })
    )];
    if cjk_rows_only {
        values.push(cjk::ROW_GLOB.to_owned());
        conditions.push(format!("docs.text GLOB ?{}", values.len()));
    }
    conditions.push(NOT_MERGED.to_owned());
    let sql = format!(
        "SELECT m.record_kind, m.record_key, m.meeting_id, m.at, m.date, docs.text \
         FROM docs JOIN doc_meta AS m ON m.id = docs.rowid WHERE {} ORDER BY length(docs.text), m.id LIMIT {}",
        conditions.join(" AND "),
        if match_all {
            limit
        } else {
            limit.saturating_mul(4)
        }
    );
    let mut statement = db.prepare(&sql)?;
    let found = statement
        .query_map(params_from_iter(values.iter()), |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<f64>>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, String>(5)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut rows: Vec<(usize, Row)> = found
        .into_iter()
        .filter_map(|(kind, key, meeting_id, at, date, text)| {
            let snippet = cjk::snippet(&text, &terms)?;
            let matched = cjk::matched_term_count(&text, &terms);
            Some((
                matched,
                Row {
                    kind,
                    key,
                    meeting_id,
                    at,
                    date,
                    snippet,
                },
            ))
        })
        .collect();
    if !match_all {
        rows.sort_by_key(|row| std::cmp::Reverse(row.0));
    }
    rows.truncate(limit);
    Ok(rows.into_iter().map(|(_, row)| row).collect())
}

/// Chinese, Japanese and Korean text has no spaces between words, so
/// unicode61 indexes a whole run as one token. Queries with CJK text match
/// by substring instead (`CJKSearch.swift`).
pub(crate) mod cjk {
    pub const ROW_GLOB: &str = "*[\u{1100}-\u{11FF}\u{3040}-\u{30FF}\u{3100}-\u{318F}\u{31A0}-\u{31FF}\u{3400}-\u{4DBF}\u{4E00}-\u{9FFF}\u{AC00}-\u{D7AF}\u{F900}-\u{FAFF}\u{FF66}-\u{FF9F}]*";

    const MAXIMUM_RELAXED_TERMS: usize = 8;
    const SEPARATORS: &str =
        ",;:!?()[]{}<>\"“”‘’「」『』（）《》〈〉【】〔〕［］｛｝，。、；：！？…—～·";

    pub fn is_cjk(c: char) -> bool {
        matches!(u32::from(c),
            0x1100..=0x11FF
            | 0x3040..=0x309F
            | 0x30A0..=0x30FF
            | 0x3100..=0x312F
            | 0x3130..=0x318F
            | 0x31A0..=0x31BF
            | 0x31F0..=0x31FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xAC00..=0xD7AF
            | 0xF900..=0xFAFF
            | 0xFF66..=0xFF9F
            | 0x20000..=0x3134F)
    }

    pub fn contains_cjk(text: &str) -> bool {
        text.chars().any(is_cjk)
    }

    /// Distinct terms in order; every one must occur.
    pub fn terms(query: &str) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        query
            .split(|c: char| c.is_whitespace() || SEPARATORS.contains(c))
            .filter(|t| !t.is_empty() && seen.insert(t.to_lowercase()))
            .map(str::to_owned)
            .collect()
    }

    /// Terms for OR matching of a spaceless question: CJK runs of three or
    /// more characters become overlapping two-character pieces; single
    /// characters are dropped unless nothing else is left.
    pub fn relaxed_terms(query: &str) -> Vec<String> {
        let mut seen = std::collections::HashSet::new();
        let mut pieces: Vec<String> = Vec::new();
        for term in terms(query) {
            for piece in pieces_of(&term) {
                if seen.insert(piece.to_lowercase()) {
                    pieces.push(piece);
                }
            }
        }
        let distinctive: Vec<String> = pieces
            .iter()
            .filter(|p| p.chars().count() > 1)
            .cloned()
            .collect();
        let chosen = if distinctive.is_empty() {
            pieces
        } else {
            distinctive
        };
        chosen.into_iter().take(MAXIMUM_RELAXED_TERMS).collect()
    }

    fn pieces_of(term: &str) -> Vec<String> {
        let mut runs: Vec<(bool, Vec<char>)> = Vec::new();
        for c in term.chars() {
            let cjk = is_cjk(c);
            match runs.last_mut() {
                Some((last, chars)) if *last == cjk => chars.push(c),
                _ => runs.push((cjk, vec![c])),
            }
        }
        runs.into_iter()
            .flat_map(|(cjk, chars)| {
                if !cjk || chars.len() <= 2 {
                    vec![chars.into_iter().collect::<String>()]
                } else {
                    chars.windows(2).map(|pair| pair.iter().collect()).collect()
                }
            })
            .collect()
    }

    /// A `LIKE` pattern matching `term` anywhere, with `%`, `_` and `\`
    /// escaped for `ESCAPE '\'`.
    pub fn like_pattern(term: &str) -> String {
        let mut escaped = String::with_capacity(term.len() + 2);
        escaped.push('%');
        for c in term.chars() {
            if matches!(c, '\\' | '%' | '_') {
                escaped.push('\\');
            }
            escaped.push(c);
        }
        escaped.push('%');
        escaped
    }

    pub fn matched_term_count(text: &str, terms: &[String]) -> usize {
        let text: Vec<char> = text.chars().collect();
        terms
            .iter()
            .filter(|term| !find_all(&text, term).is_empty())
            .count()
    }

    /// An excerpt around the first match with « » around every match in it
    /// and … where text was cut; `None` when no term occurs.
    pub fn snippet(text: &str, terms: &[String]) -> Option<String> {
        const BEFORE: usize = 18;
        const AFTER: usize = 54;
        let chars: Vec<char> = text.chars().collect();
        let ranges = match_ranges(&chars, terms);
        let first = *ranges.first()?;
        let start = first.0.saturating_sub(BEFORE);
        let end = (first.1 + AFTER).min(chars.len());
        let mut excerpt = String::new();
        if start > 0 {
            excerpt.push('…');
        }
        let mut cursor = start;
        for &(lower, upper) in &ranges {
            if lower >= cursor && upper <= end {
                excerpt.extend(&chars[cursor..lower]);
                excerpt.push('«');
                excerpt.extend(&chars[lower..upper]);
                excerpt.push('»');
                cursor = upper;
            }
        }
        excerpt.extend(&chars[cursor..end]);
        if end < chars.len() {
            excerpt.push('…');
        }
        Some(excerpt)
    }

    /// Every occurrence of every term (case-insensitive), sorted, with
    /// overlapping and touching matches merged.
    fn match_ranges(text: &[char], terms: &[String]) -> Vec<(usize, usize)> {
        let mut found: Vec<(usize, usize)> =
            terms.iter().flat_map(|term| find_all(text, term)).collect();
        found.sort_unstable();
        let mut merged: Vec<(usize, usize)> = Vec::new();
        for (lower, upper) in found {
            match merged.last_mut() {
                Some(last) if lower <= last.1 => last.1 = last.1.max(upper),
                _ => merged.push((lower, upper)),
            }
        }
        merged
    }

    fn find_all(text: &[char], term: &str) -> Vec<(usize, usize)> {
        let term: Vec<char> = term.chars().collect();
        if term.is_empty() || term.len() > text.len() {
            return Vec::new();
        }
        let same = |a: char, b: char| a == b || a.to_lowercase().eq(b.to_lowercase());
        let mut found = Vec::new();
        let mut i = 0;
        while i + term.len() <= text.len() {
            if text[i..i + term.len()]
                .iter()
                .zip(&term)
                .all(|(&a, &b)| same(a, b))
            {
                found.push((i, i + term.len()));
                i += term.len();
            } else {
                i += 1;
            }
        }
        found
    }
}
