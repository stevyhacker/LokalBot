//! Screen search by meaning: text and picture vectors of saved screens, and their
//! ranking with keyword hits (`ScreenSearch`, `ScreenSearchRanking`,
//! `EmbeddingIndex.screenMeanings`).
//!
//! Ranked the way DigUp ranks files: meaning is how far a capture stands out for
//! this query among all stored vectors of its kind, and the query's words add a
//! bonus that grows with how many of them the capture holds. A capture qualifies
//! by standing out in meaning or by holding at least half of the query's words, so
//! one common word can't outrank a clear meaning match, while all the words of an
//! exact lookup ("INV-2041") usually win.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use anyhow::{Result, bail};
use chrono::{DateTime, Utc};
use regex::Regex;
use rusqlite::{OptionalExtension as _, params};
use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;

use crate::embeddings::MODEL_ID;
use crate::files::search::{self as file_search};
use crate::files::text as search_text;
use crate::library::Library;
use crate::model::ScreenMoment;
use crate::search::{MatchMode, ScreenHit};
use crate::time::{from_epoch, to_epoch};
use crate::timeline::table_exists;

/// How far above this query's average a capture must score to count by meaning.
pub const Z_GATE: f64 = 2.0;
pub const WORD_WEIGHT: f64 = 2.0;
const MINIMUM_DEVIATION: f64 = 0.02;
/// Fewer vectors of a kind than this take the average of all kinds.
const MODALITY_MINIMUM_COUNT: usize = 20;
/// How many OR-fallback hits get their full text read to count the query's words;
/// the rest are counted from their snippet and title.
const FULL_TEXT_LIMIT: usize = 100;
/// The text embedded per capture.
const DOCUMENT_CHARS: usize = 1_500;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Modality {
    /// The capture's text, embedded as a document.
    Text,
    /// The captured picture itself.
    Image,
}

/// One stored vector's similarity to the query vector.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Score {
    pub snapshot_id: i64,
    pub modality: Modality,
    pub cosine: f32,
}

/// A capture's best meaning match, on this query's scale.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Meaning {
    pub z: f64,
    pub cosine: f32,
    pub modality: Modality,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ranked {
    pub snapshot_id: i64,
    pub score: f64,
    pub meaning: Option<Meaning>,
    /// Share of the query's words the capture holds, 0…1.
    pub coverage: f64,
    /// 1-based place in the keyword results, if the words found it.
    pub keyword_rank: Option<usize>,
}

impl Ranked {
    /// Found by meaning alone: the list says so.
    pub fn is_semantic(&self) -> bool {
        self.keyword_rank.is_none() || self.coverage < 0.5
    }
}

/// Each capture's best vector on this query's scale. Scores are centred per kind
/// first, because text scores higher than pictures for the same topic, then put on
/// one z scale. Pass every stored vector, not only those in the date or app scope:
/// the scale must not depend on the filter.
pub fn meaning(scores: &[Score]) -> HashMap<i64, Meaning> {
    if scores.is_empty() {
        return HashMap::new();
    }
    let mut sum: HashMap<Modality, f64> = HashMap::new();
    let mut count: HashMap<Modality, usize> = HashMap::new();
    for score in scores {
        *sum.entry(score.modality).or_default() += score.cosine as f64;
        *count.entry(score.modality).or_default() += 1;
    }
    let total: usize = count.values().sum();
    let overall = sum.values().sum::<f64>() / total.max(1) as f64;
    let mean_of = |modality: Modality| match (sum.get(&modality), count.get(&modality)) {
        (Some(sum), Some(n)) if *n >= MODALITY_MINIMUM_COUNT => sum / *n as f64,
        _ => overall,
    };
    let centered: Vec<f64> = scores
        .iter()
        .map(|score| score.cosine as f64 - mean_of(score.modality))
        .collect();
    let mean = centered.iter().sum::<f64>() / centered.len() as f64;
    let variance = centered
        .iter()
        .map(|v| (v - mean) * (v - mean))
        .sum::<f64>()
        / centered.len() as f64;
    let deviation = variance.sqrt().max(MINIMUM_DEVIATION);
    let mut best: HashMap<i64, Meaning> = HashMap::new();
    for (score, value) in scores.iter().zip(&centered) {
        let z = (value - mean) / deviation;
        if best.get(&score.snapshot_id).is_none_or(|known| z > known.z) {
            best.insert(
                score.snapshot_id,
                Meaning {
                    z,
                    cosine: score.cosine,
                    modality: score.modality,
                },
            );
        }
    }
    best
}

/// The query's content words, as keyword search over files sees them.
pub fn terms(query: &str) -> Vec<String> {
    file_search::terms(query)
}

/// An exact lookup: every word carries digits. Words then count for more than
/// meaning.
pub fn is_lookup(terms: &[String]) -> bool {
    file_search::is_lookup(terms)
}

fn folded(text: &str) -> String {
    search_text::normalized(text)
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}

/// The share of `terms` in any of `texts`, ignoring case and diacritics. A word
/// matches as the start of a longer word ("deploy" in "deployment").
pub fn coverage(terms: &[String], texts: &[&str]) -> f64 {
    if terms.is_empty() {
        return 0.0;
    }
    let words: HashSet<String> = texts
        .iter()
        .flat_map(|text| {
            folded(text)
                .split(|c: char| !c.is_alphanumeric())
                .filter(|w| !w.is_empty())
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .collect();
    let found = terms
        .iter()
        .filter(|term| {
            let term = folded(term);
            words.iter().any(|word| word.starts_with(&term))
        })
        .count();
    found as f64 / terms.len() as f64
}

/// Captures that stand out in meaning or hold at least half of the query's words,
/// best first. Score: meaning z plus a word bonus that grows with coverage; for a
/// lookup, words weigh double and meaning half. Ties go to word matches, then to
/// keyword order, then to the newer capture.
pub fn rank(
    meanings: &HashMap<i64, Meaning>,
    keyword: &[(i64, f64)],
    lookup: bool,
    limit: usize,
) -> Vec<Ranked> {
    if limit == 0 {
        return Vec::new();
    }
    let (meaning_weight, words_weight) = if lookup {
        (0.5, WORD_WEIGHT * 2.0)
    } else {
        (1.0, WORD_WEIGHT)
    };
    let mut keyword_rank: HashMap<i64, usize> = HashMap::new();
    let mut shares: HashMap<i64, f64> = HashMap::new();
    for (offset, (id, share)) in keyword.iter().enumerate() {
        if !keyword_rank.contains_key(id) {
            keyword_rank.insert(*id, offset + 1);
            shares.insert(*id, *share);
        }
    }
    let mut candidates: HashSet<i64> = meanings
        .iter()
        .filter(|(_, meaning)| meaning.z >= Z_GATE)
        .map(|(id, _)| *id)
        .collect();
    candidates.extend(
        shares
            .iter()
            .filter(|(_, share)| **share >= 0.5)
            .map(|(id, _)| *id),
    );
    let mut ranked: Vec<Ranked> = candidates
        .into_iter()
        .map(|id| {
            let meaning = meanings.get(&id).copied();
            let share = shares.get(&id).copied().unwrap_or(0.0);
            Ranked {
                snapshot_id: id,
                score: meaning_weight * meaning.map_or(0.0, |m| m.z).max(0.0)
                    + words_weight * share.powf(1.5),
                meaning,
                coverage: share,
                keyword_rank: keyword_rank.get(&id).copied(),
            }
        })
        .collect();
    ranked.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then((b.coverage >= 0.5).cmp(&(a.coverage >= 0.5)))
            .then(
                a.keyword_rank
                    .unwrap_or(usize::MAX)
                    .cmp(&b.keyword_rank.unwrap_or(usize::MAX)),
            )
            .then(b.snapshot_id.cmp(&a.snapshot_id))
    });
    ranked.truncate(limit);
    ranked
}

// --------------------------------------------------------------- the excerpt

static MARKUP_START: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\s*(?:#{1,6}\s+|[-*•]\s+(?:\[[ xX]\]\s*)?|\d+\.\s+)").expect("a valid pattern")
});
static MARKDOWN_LINK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[([^\]]+)\]\([^\)]+\)").expect("a valid pattern"));
static EMPHASIS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[*`]+").expect("a valid pattern"));
static HEADING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^#{1,6}\s").expect("a valid pattern"));

fn tokens(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

fn is_useful(text: &str) -> bool {
    const FILLERS: [&str; 10] = [
        "uh", "um", "hmm", "hm", "ah", "oh", "okay", "ok", "yes", "yeah",
    ];
    let words = tokens(text);
    if !words
        .iter()
        .any(|w| !FILLERS.contains(&w.as_str()) && w.chars().count() > 1)
    {
        return false;
    }
    if words.len() >= 6 {
        let mut counts: HashMap<&str, usize> = HashMap::new();
        for word in &words {
            *counts.entry(word).or_default() += 1;
        }
        let most = counts.values().copied().max().unwrap_or(0);
        if most as f64 / words.len() as f64 > 0.55 {
            return false;
        }
        if words.len() >= 12 && counts.len() <= 3 {
            return false;
        }
    }
    true
}

/// How many of the query's words `text` holds; a marked «match» counts for more
/// (`RecallPassage.queryMatchCount`).
pub fn query_match_count(text: &str, query: &str) -> usize {
    let lower = folded(text);
    usize::from(text.contains('«')) * 100
        + terms(query)
            .iter()
            .filter(|term| lower.contains(&folded(term)))
            .count()
}

/// A reading excerpt from captured text: the line with the query's words, or the
/// first useful one (`RecallPassage.excerpt`).
pub fn excerpt(source: &str, query: &str, limit: usize) -> Option<String> {
    let lines: Vec<String> = source
        .split('\n')
        .filter_map(|line| {
            let line = line.trim();
            if HEADING.is_match(line) || line.starts_with("```") {
                return None;
            }
            let cleaned = MARKUP_START.replace(line, "");
            let cleaned = MARKDOWN_LINK.replace_all(&cleaned, "$1");
            let cleaned = EMPHASIS.replace_all(&cleaned, "");
            let cleaned = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
            is_useful(&cleaned).then_some(cleaned)
        })
        .collect();
    let wanted = terms(query);
    let score = |line: &str| {
        let lower = folded(line);
        usize::from(line.contains('«')) * 100
            + wanted
                .iter()
                .filter(|term| lower.contains(&folded(term)))
                .count()
    };
    // Ties go to the earlier line.
    let selected = lines
        .iter()
        .rev()
        .max_by_key(|line| score(line.as_str()))?
        .clone();
    let chars: Vec<char> = selected.chars().collect();
    let lower = folded(&selected);
    let center = selected
        .find('«')
        .map(|at| selected[..at].chars().count())
        .or_else(|| {
            wanted
                .iter()
                .find_map(|term| lower.find(&folded(term)))
                .map(|at| lower[..at].chars().count())
        })
        .unwrap_or(0);
    let mut start = center.saturating_sub(90);
    if start > 0 {
        while start < chars.len() && !chars[start].is_whitespace() {
            start += 1;
        }
    }
    let end = (start + limit).min(chars.len());
    let body: String = chars[start..end].iter().collect();
    let mut out = String::new();
    if start > 0 {
        out.push('…');
    }
    out.push_str(body.trim());
    if end < chars.len() {
        out.push('…');
    }
    Some(out)
}

// ------------------------------------------------------------------- storage

/// A capture's text waiting for its vector.
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenDocument {
    pub snapshot_id: i64,
    pub ts: DateTime<Utc>,
    pub app: String,
    pub text: String,
}

/// A capture's best meaning match for a query, and what search shows for it.
#[derive(Clone, Debug, PartialEq)]
pub struct ScreenMeaningMatch {
    pub meaning: Meaning,
    pub ts: DateTime<Utc>,
    pub app: String,
    /// The capture's text, when it has a text vector.
    pub text: Option<String>,
}

/// What a screen search may reach.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScreenFilter {
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
    /// Case-insensitive.
    pub app: Option<String>,
    pub snapshot_ids: Option<HashSet<i64>>,
}

impl ScreenFilter {
    pub fn contains(&self, id: i64, ts: DateTime<Utc>, app: &str) -> bool {
        self.snapshot_ids
            .as_ref()
            .is_none_or(|ids| ids.contains(&id))
            && self.since.is_none_or(|since| ts >= since)
            && self.until.is_none_or(|until| ts < until)
            && self
                .app
                .as_deref()
                .is_none_or(|wanted| wanted.eq_ignore_ascii_case(app))
    }
}

fn vector_bytes(vector: &[f32]) -> Vec<u8> {
    vector.iter().flat_map(|v| v.to_le_bytes()).collect()
}

fn cosine(blob: &[u8], query: &[f32]) -> Option<f32> {
    (blob.len() == query.len() * 4).then(|| {
        blob.as_chunks::<4>()
            .0
            .iter()
            .zip(query)
            .map(|(bytes, q)| f32::from_le_bytes(*bytes) * q)
            .sum()
    })
}

impl Library {
    /// Captures with text and no vector, oldest first.
    pub fn screen_documents_without_vectors(&self, limit: usize) -> Result<Vec<ScreenDocument>> {
        self.with_db(|db| {
            if !table_exists(db, "ocr_fts")? || !table_exists(db, "screenshots")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT CAST(ocr.snapshot_id AS INTEGER), CAST(ocr.ts AS REAL), ocr.app, ocr.text \
                 FROM ocr_fts AS ocr \
                 JOIN screenshots AS shot ON shot.id = CAST(ocr.snapshot_id AS INTEGER) \
                 WHERE CAST(ocr.snapshot_id AS INTEGER) > 0 \
                   AND NOT EXISTS (SELECT 1 FROM screen_embeddings AS embedded \
                       WHERE embedded.snapshot_id = CAST(ocr.snapshot_id AS INTEGER) \
                         AND embedded.model_id = ?1) \
                 ORDER BY CAST(ocr.ts AS REAL), CAST(ocr.snapshot_id AS INTEGER) \
                 LIMIT ?2",
            )?;
            let rows = statement.query_map(params![MODEL_ID, limit as i64], |row| {
                let text: String = row.get(3)?;
                Ok(ScreenDocument {
                    snapshot_id: row.get(0)?,
                    ts: from_epoch(row.get(1)?),
                    app: row.get(2)?,
                    text: text.chars().take(DOCUMENT_CHARS).collect(),
                })
            })?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    /// Stores text vectors. Retention or deletion may remove text while embedding
    /// runs, so the exact live text is checked again under the write transaction;
    /// a late pass can't bring expired text back into this table.
    pub fn store_screen_vectors(&self, rows: &[(ScreenDocument, Vec<f32>)]) -> Result<()> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            let tx = rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Immediate)?;
            for (document, vector) in rows {
                let live: Option<String> = tx
                    .query_row(
                        "SELECT ocr.text FROM ocr_fts AS ocr \
                         JOIN screenshots AS shot ON shot.id = CAST(ocr.snapshot_id AS INTEGER) \
                         WHERE CAST(ocr.snapshot_id AS INTEGER) = ?1 LIMIT 1",
                        [document.snapshot_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                let same = live.is_some_and(|text| {
                    text.chars().take(DOCUMENT_CHARS).eq(document.text.chars())
                });
                if !same {
                    continue;
                }
                tx.execute(
                    "INSERT OR REPLACE INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id) \
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        document.snapshot_id,
                        to_epoch(document.ts),
                        document.app,
                        document.text,
                        vector_bytes(vector),
                        MODEL_ID
                    ],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// Screens have been searched by meaning on this library.
    pub fn has_screen_vectors(&self) -> Result<bool> {
        self.with_db(|db| {
            Ok(db
                .query_row(
                    "SELECT 1 FROM screen_embeddings AS embedded \
                     JOIN screenshots AS shot ON shot.id = embedded.snapshot_id \
                     WHERE embedded.model_id = ?1 LIMIT 1",
                    [MODEL_ID],
                    |_| Ok(()),
                )
                .optional()?
                .is_some())
        })
    }

    /// Text vectors another model made: this library searched by meaning before,
    /// so they are rebuilt.
    pub fn has_stale_screen_vectors(&self) -> Result<bool> {
        self.with_db(|db| {
            Ok(db
                .query_row(
                    "SELECT 1 FROM screen_embeddings WHERE model_id != ?1 LIMIT 1",
                    [MODEL_ID],
                    |_| Ok(()),
                )
                .optional()?
                .is_some())
        })
    }

    /// Picture vectors a changed model, sizing or request shape made are dropped.
    pub fn purge_picture_vectors_except(&self, model_id: &str) -> Result<()> {
        if self.is_read_only() {
            return Ok(());
        }
        self.with_db(|db| {
            db.execute(
                "DELETE FROM screen_image_embeddings WHERE model_id != ?1",
                [model_id],
            )?;
            Ok(())
        })
    }

    /// Retained captures without a picture vector, newest first: `(id, path)`.
    pub fn screens_without_picture_vectors(
        &self,
        model_id: &str,
        limit: usize,
    ) -> Result<Vec<(i64, String)>> {
        self.with_db(|db| {
            let mut statement = db.prepare(
                "SELECT shot.id, shot.path FROM screenshots AS shot \
                 WHERE shot.id > 0 AND shot.path != '' \
                   AND NOT EXISTS (SELECT 1 FROM screen_image_embeddings AS embedded \
                       WHERE embedded.snapshot_id = shot.id AND embedded.model_id = ?1) \
                 ORDER BY shot.ts DESC, shot.id DESC LIMIT ?2",
            )?;
            let rows = statement.query_map(params![model_id, limit as i64], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    /// Stores a capture's picture vector, or an empty one for pixels that can't be
    /// read, so a broken capture isn't tried on every pass. The pixels may have
    /// been deleted or replaced while this was embedded: a vector is never stored
    /// for pixels that are gone.
    pub fn store_picture_vector(
        &self,
        model_id: &str,
        snapshot_id: i64,
        path: &str,
        vector: Option<&[f32]>,
    ) -> Result<bool> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            let tx = rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Immediate)?;
            let live = tx
                .query_row(
                    "SELECT 1 FROM screenshots WHERE id = ?1 AND path = ?2 AND path != ''",
                    params![snapshot_id, path],
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            if live {
                tx.execute(
                    "INSERT OR REPLACE INTO screen_image_embeddings (snapshot_id, vec, model_id) VALUES (?1, ?2, ?3)",
                    params![
                        snapshot_id,
                        vector.map(vector_bytes).unwrap_or_default(),
                        model_id
                    ],
                )?;
            }
            tx.commit()?;
            Ok(live)
        })
    }

    /// Captures with a picture vector.
    pub fn picture_vector_count(&self, model_id: &str) -> Result<usize> {
        self.with_db(|db| {
            Ok(db.query_row(
                "SELECT COUNT(*) FROM screen_image_embeddings WHERE model_id = ?1 AND length(vec) = ?2",
                params![model_id, (768 * 4) as i64],
                |row| row.get::<_, i64>(0).map(|n| n as usize),
            )?)
        })
    }

    /// Every screen vector, text and picture, scored against the query on one
    /// scale, then limited to `filter`. The scale comes from all vectors, so a date
    /// or app filter never changes how far a capture stands out.
    pub fn screen_meanings(
        &self,
        query_vector: &[f32],
        picture_model_id: &str,
        filter: &ScreenFilter,
    ) -> Result<HashMap<i64, ScreenMeaningMatch>> {
        if filter.snapshot_ids.as_ref().is_some_and(HashSet::is_empty) {
            return Ok(HashMap::new());
        }
        struct Row {
            snapshot_id: i64,
            ts: f64,
            app: String,
            text: Option<String>,
            modality: Modality,
            cosine: f32,
        }
        let rows = self.with_db(|db| {
            let mut rows: Vec<Row> = Vec::new();
            let mut read = |sql: &str, model: &str, modality: Modality| -> Result<()> {
                let mut statement = db.prepare(sql)?;
                let mut cursor = statement.query([model])?;
                while let Some(row) = cursor.next()? {
                    let Some(value) = cosine(row.get_ref(4)?.as_blob()?, query_vector) else {
                        continue;
                    };
                    rows.push(Row {
                        snapshot_id: row.get(0)?,
                        ts: row.get(1)?,
                        app: row.get(2)?,
                        text: row.get(3)?,
                        modality,
                        cosine: value,
                    });
                }
                Ok(())
            };
            read(
                "SELECT embedded.snapshot_id, shot.ts, shot.app, embedded.text, embedded.vec \
                 FROM screen_embeddings AS embedded \
                 JOIN screenshots AS shot ON shot.id = embedded.snapshot_id \
                 WHERE embedded.model_id = ?1 \
                   AND EXISTS (SELECT 1 FROM ocr_metadata AS ocr WHERE ocr.snapshot_id = embedded.snapshot_id)",
                MODEL_ID,
                Modality::Text,
            )?;
            if table_exists(db, "screen_image_embeddings")? {
                read(
                    "SELECT embedded.snapshot_id, shot.ts, shot.app, NULL, embedded.vec \
                     FROM screen_image_embeddings AS embedded \
                     JOIN screenshots AS shot ON shot.id = embedded.snapshot_id \
                     WHERE embedded.model_id = ?1 AND shot.path != ''",
                    picture_model_id,
                    Modality::Image,
                )?;
            }
            Ok(rows)
        })?;
        let scores: Vec<Score> = rows
            .iter()
            .map(|row| Score {
                snapshot_id: row.snapshot_id,
                modality: row.modality,
                cosine: row.cosine,
            })
            .collect();
        let meanings = meaning(&scores);
        let mut texts: HashMap<i64, String> = HashMap::new();
        let mut places: HashMap<i64, (f64, String)> = HashMap::new();
        for row in rows {
            if let Some(text) = row.text {
                texts.insert(row.snapshot_id, text);
            }
            places.insert(row.snapshot_id, (row.ts, row.app));
        }
        let mut matches = HashMap::new();
        for (id, meaning) in meanings {
            let Some((ts, app)) = places.get(&id) else {
                continue;
            };
            let ts = from_epoch(*ts);
            if filter.contains(id, ts, app) {
                matches.insert(
                    id,
                    ScreenMeaningMatch {
                        meaning,
                        ts,
                        app: app.clone(),
                        text: texts.remove(&id),
                    },
                );
            }
        }
        Ok(matches)
    }

    /// Keyword hits under `filter`: all the words, or any of them when that finds
    /// nothing. `true` when they hold every word.
    pub fn keyword_screen_hits(
        &self,
        query: &str,
        filter: &ScreenFilter,
        limit: usize,
    ) -> Result<(Vec<ScreenHit>, bool)> {
        let interval = filter.since.zip(filter.until).or_else(|| {
            filter
                .since
                .map(|since| (since, crate::time::from_epoch(4_102_444_800.0)))
                .or_else(|| filter.until.map(|until| (from_epoch(0.0), until)))
        });
        let app = filter.app.as_deref();
        let keep = |hit: &ScreenHit| {
            filter
                .snapshot_ids
                .as_ref()
                .is_none_or(|ids| ids.contains(&hit.moment.id))
        };
        let all: Vec<ScreenHit> = self
            .search_ocr(query, MatchMode::All, interval, app, limit)?
            .into_iter()
            .filter(keep)
            .collect();
        if !all.is_empty() {
            return Ok((all, true));
        }
        let any: Vec<ScreenHit> = self
            .search_ocr(query, MatchMode::Any, interval, app, limit)?
            .into_iter()
            .filter(keep)
            .collect();
        Ok((any, false))
    }

    /// The share of the query's words each keyword hit holds. Hits found by the
    /// all-words search hold them all; for the OR fallback the capture's text is
    /// read. A query of only stopwords counts every hit it found.
    pub fn screen_coverage(
        &self,
        query: &str,
        hits: &[ScreenHit],
        matched_all: bool,
    ) -> HashMap<i64, f64> {
        let wanted = terms(query);
        let mut shares = HashMap::new();
        for (index, hit) in hits.iter().enumerate() {
            let id = hit.moment.id;
            if shares.contains_key(&id) {
                continue;
            }
            if matched_all || wanted.is_empty() {
                shares.insert(id, if matched_all { 1.0 } else { 0.5 });
                continue;
            }
            let full = (index < FULL_TEXT_LIMIT)
                .then(|| self.screen_text(id, usize::MAX))
                .flatten();
            shares.insert(
                id,
                coverage(
                    &wanted,
                    &[
                        full.as_deref().unwrap_or(&hit.snippet),
                        &hit.moment.window_title,
                    ],
                ),
            );
        }
        shares
    }

    /// Keyword hits and meaning matches as one ranked list. A capture found only by
    /// meaning gets its text's best passage as the snippet, or its window title
    /// when it has no text (a picture-only match). Returns `(hit, is_semantic)`.
    pub fn ranked_screen_hits(
        &self,
        query: &str,
        keyword: Vec<ScreenHit>,
        shares: &HashMap<i64, f64>,
        meanings: &HashMap<i64, ScreenMeaningMatch>,
        limit: usize,
    ) -> Vec<(ScreenHit, bool)> {
        let wanted = terms(query);
        let by_id: HashMap<i64, ScreenHit> = keyword
            .iter()
            .rev()
            .map(|hit| (hit.moment.id, hit.clone()))
            .collect();
        let list: Vec<(i64, f64)> = keyword
            .iter()
            .map(|hit| {
                (
                    hit.moment.id,
                    shares.get(&hit.moment.id).copied().unwrap_or(0.0),
                )
            })
            .collect();
        let meaning_only: HashMap<i64, Meaning> =
            meanings.iter().map(|(id, m)| (*id, m.meaning)).collect();
        rank(&meaning_only, &list, is_lookup(&wanted), limit)
            .into_iter()
            .filter_map(|item| {
                if let Some(hit) = by_id.get(&item.snapshot_id) {
                    return Some((hit.clone(), item.is_semantic()));
                }
                let found = meanings.get(&item.snapshot_id)?;
                let moment: ScreenMoment = self.screen_moment(item.snapshot_id).ok().flatten()?;
                let title = if moment.window_title.is_empty() {
                    moment.app.clone()
                } else {
                    moment.window_title.clone()
                };
                let snippet = found
                    .text
                    .as_deref()
                    .and_then(|text| excerpt(text, query, 320))
                    .unwrap_or(title);
                Some((
                    ScreenHit {
                        moment,
                        snippet,
                        rank: 0.0,
                        capture_count: 1,
                    },
                    true,
                ))
            })
            .collect()
    }
}

// ----------------------------------------------------- "search by meaning" use

type Observer = Box<dyn Fn(&Path) + Send + Sync>;

static OBSERVER: Mutex<Option<Observer>> = Mutex::new(None);
/// Libraries searched by meaning in this run, for an observer that starts late.
static SEARCHED: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

/// Someone searched screens by meaning: vectors for what's waiting start now.
/// Nobody downloads the image model for a search they never make.
pub fn note_searched_by_meaning(root: &Path) {
    if let Ok(mut searched) = SEARCHED.lock()
        && !searched.iter().any(|known| known == root)
    {
        searched.push(root.to_path_buf());
    }
    if let Ok(observer) = OBSERVER.lock()
        && let Some(observer) = observer.as_ref()
    {
        observer(root);
    }
}

/// `note_searched_by_meaning` was called for this library in this run.
pub fn was_searched_by_meaning(root: &Path) -> bool {
    SEARCHED
        .lock()
        .is_ok_and(|searched| searched.iter().any(|known| known == root))
}

/// Hears `note_searched_by_meaning`.
pub fn observe_searches(observer: impl Fn(&Path) + Send + Sync + 'static) {
    if let Ok(mut slot) = OBSERVER.lock() {
        *slot = Some(Box::new(observer));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn score(id: i64, cosine: f32) -> Score {
        Score {
            snapshot_id: id,
            modality: Modality::Text,
            cosine,
        }
    }

    #[test]
    fn meaning_is_how_far_a_capture_stands_out() {
        let mut scores: Vec<Score> = (0..30).map(|i| score(i, 0.5)).collect();
        scores.push(score(99, 0.9));
        let meanings = meaning(&scores);
        assert!(meanings[&99].z >= Z_GATE, "{:?}", meanings[&99]);
        assert!(meanings[&1].z < 1.0);
    }

    #[test]
    fn each_kind_is_centred_on_its_own_average() {
        // Text scores higher than pictures across the board.
        let mut scores = Vec::new();
        for i in 0..25 {
            scores.push(score(i, 0.8));
            scores.push(Score {
                snapshot_id: i + 100,
                modality: Modality::Image,
                cosine: 0.4,
            });
        }
        scores.push(Score {
            snapshot_id: 500,
            modality: Modality::Image,
            cosine: 0.7,
        });
        let meanings = meaning(&scores);
        assert!(
            meanings[&500].z >= Z_GATE,
            "the picture stands out among pictures"
        );
        assert!(meanings[&1].z < Z_GATE);
    }

    #[test]
    fn a_capture_takes_its_best_vector() {
        let scores = [
            score(1, 0.2),
            Score {
                snapshot_id: 1,
                modality: Modality::Image,
                cosine: 0.8,
            },
            score(2, 0.3),
        ];
        assert_eq!(meaning(&scores)[&1].modality, Modality::Image);
    }

    #[test]
    fn words_cover_prefixes_ignoring_case_and_diacritics() {
        let wanted = vec!["deploy".to_string(), "cafe".to_string()];
        assert_eq!(coverage(&wanted, &["Deployment notes", "Café menu"]), 1.0);
        assert_eq!(coverage(&wanted, &["the deployment"]), 0.5);
        assert_eq!(coverage(&wanted, &["unrelated"]), 0.0);
        assert_eq!(coverage(&[], &["anything"]), 0.0);
    }

    fn meaning_of(z: f64) -> Meaning {
        Meaning {
            z,
            cosine: 0.5,
            modality: Modality::Text,
        }
    }

    #[test]
    fn half_the_words_or_a_clear_meaning_qualify() {
        let meanings = HashMap::from([
            (1, meaning_of(3.0)),
            (2, meaning_of(1.0)),
            (3, meaning_of(1.0)),
        ]);
        let keyword = [(2, 0.5), (3, 0.25)];
        let ranked = rank(&meanings, &keyword, false, 10);
        let ids: Vec<i64> = ranked.iter().map(|r| r.snapshot_id).collect();
        assert_eq!(ids, [1, 2], "one word of four doesn't qualify");
        assert!(ranked[0].is_semantic());
        assert!(!ranked[1].is_semantic());
        // z 3.0 against 1.0 + 2 × 0.5^1.5.
        assert!((ranked[1].score - (1.0 + 2.0 * 0.5f64.powf(1.5))).abs() < 1e-9);
    }

    #[test]
    fn a_lookup_weighs_words_double_and_meaning_half() {
        let meanings = HashMap::from([(1, meaning_of(4.0))]);
        let keyword = [(2, 1.0)];
        let plain = rank(&meanings, &keyword, false, 10);
        assert_eq!(plain[0].snapshot_id, 1);
        let lookup = rank(&meanings, &keyword, true, 10);
        assert_eq!(lookup[0].snapshot_id, 2);
        assert_eq!(lookup[0].score, 4.0);
        assert_eq!(lookup[1].score, 2.0);
    }

    #[test]
    fn ties_go_to_words_then_keyword_order_then_the_newer() {
        let meanings = HashMap::from([(7, meaning_of(2.0)), (8, meaning_of(2.0))]);
        let ranked = rank(&meanings, &[(9, 1.0)], false, 10);
        assert_eq!(ranked[0].snapshot_id, 9, "words win a tie");
        assert_eq!(ranked[1].snapshot_id, 8, "the newer capture");
        assert_eq!(ranked[2].snapshot_id, 7);
        let by_order = rank(&HashMap::new(), &[(1, 1.0), (2, 1.0)], false, 10);
        assert_eq!(by_order[0].snapshot_id, 1);
        assert!(rank(&meanings, &[], false, 0).is_empty());
    }

    #[test]
    fn excerpts_prefer_the_line_with_the_words() {
        let text = "# Heading\nJust some opening line here\nThe invoice number is due Friday\nClosing line of the note";
        assert_eq!(
            excerpt(text, "invoice", 320).as_deref(),
            Some("The invoice number is due Friday")
        );
        assert_eq!(
            excerpt(text, "nothing matches", 320).as_deref(),
            Some("Just some opening line here")
        );
        assert_eq!(excerpt("# only a heading", "x", 320), None);
        assert_eq!(excerpt("ok ok ok", "x", 320), None);
        let words = |stem: &str| {
            (0..100)
                .map(|i| format!("{stem}{i}"))
                .collect::<Vec<_>>()
                .join(" ")
        };
        let long = format!("{} needle {}", words("word"), words("tail"));
        let cut = excerpt(&long, "needle", 50).unwrap();
        assert!(cut.starts_with('…') && cut.ends_with('…'), "{cut}");
    }

    fn library_with_capture(dir: &Path) -> (Library, i64) {
        let library = Library::open(crate::LibraryPaths::new(dir)).unwrap();
        let id = library
            .record_screen_moment(&crate::timeline::NewScreenMoment {
                ts: crate::time::from_epoch(1_000.0),
                app: "Figma".into(),
                window_title: "Design".into(),
                trigger: "manual".into(),
                path: "captures/a.jpg.enc".into(),
                text: "Quarterly roadmap review".into(),
                text_source: "ocr".into(),
                ..Default::default()
            })
            .unwrap();
        (library, id)
    }

    #[test]
    fn stores_and_ranks_text_and_picture_vectors() {
        let dir = tempfile::tempdir().unwrap();
        let (library, id) = library_with_capture(dir.path());
        let pending = library.screen_documents_without_vectors(10).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].text, "Quarterly roadmap review");
        assert!(!library.has_screen_vectors().unwrap());
        library
            .store_screen_vectors(&[(pending[0].clone(), vec![1.0, 0.0])])
            .unwrap();
        assert!(library.has_screen_vectors().unwrap());
        assert!(
            library
                .screen_documents_without_vectors(10)
                .unwrap()
                .is_empty()
        );

        let model = "embeddinggemma-2-q8-mmproj-q8-image280-v1";
        let waiting = library.screens_without_picture_vectors(model, 10).unwrap();
        assert_eq!(waiting, [(id, "captures/a.jpg.enc".to_string())]);
        assert!(
            library
                .store_picture_vector(model, id, "captures/a.jpg.enc", Some(&[0.0, 1.0]))
                .unwrap()
        );
        assert!(
            library
                .screens_without_picture_vectors(model, 10)
                .unwrap()
                .is_empty()
        );

        let filter = ScreenFilter::default();
        let matches = library
            .screen_meanings(&[0.0, 1.0], model, &filter)
            .unwrap();
        assert_eq!(matches[&id].meaning.modality, Modality::Image);
        assert_eq!(
            matches[&id].text.as_deref(),
            Some("Quarterly roadmap review")
        );

        // The date and app filters limit the result, not the scale.
        let other_app = ScreenFilter {
            app: Some("Zed".into()),
            ..ScreenFilter::default()
        };
        assert!(
            library
                .screen_meanings(&[0.0, 1.0], model, &other_app)
                .unwrap()
                .is_empty()
        );
        let none = ScreenFilter {
            snapshot_ids: Some(HashSet::new()),
            ..ScreenFilter::default()
        };
        assert!(
            library
                .screen_meanings(&[0.0, 1.0], model, &none)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_late_vector_never_brings_back_deleted_text_or_pixels() {
        let dir = tempfile::tempdir().unwrap();
        let (library, id) = library_with_capture(dir.path());
        let pending = library.screen_documents_without_vectors(10).unwrap();
        let model = "m";
        library.delete_screen_moments(&[id]).unwrap();
        library
            .store_screen_vectors(&[(pending[0].clone(), vec![1.0])])
            .unwrap();
        assert!(!library.has_screen_vectors().unwrap());
        assert!(
            !library
                .store_picture_vector(model, id, "captures/a.jpg.enc", Some(&[1.0]))
                .unwrap()
        );
        assert_eq!(library.picture_vector_count(model).unwrap(), 0);
    }

    #[test]
    fn broken_pixels_are_marked_and_old_vectors_purged() {
        let dir = tempfile::tempdir().unwrap();
        let (library, id) = library_with_capture(dir.path());
        library
            .store_picture_vector("m", id, "captures/a.jpg.enc", None)
            .unwrap();
        assert!(
            library
                .screens_without_picture_vectors("m", 10)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            library.picture_vector_count("m").unwrap(),
            0,
            "marked, not counted"
        );
        library.purge_picture_vectors_except("n").unwrap();
        assert_eq!(
            library
                .screens_without_picture_vectors("m", 10)
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn meaning_only_hits_get_a_passage_and_keyword_hits_keep_theirs() {
        let dir = tempfile::tempdir().unwrap();
        let (library, id) = library_with_capture(dir.path());
        let (keyword, all) = library
            .keyword_screen_hits("roadmap", &ScreenFilter::default(), 40)
            .unwrap();
        assert!(all);
        let shares = library.screen_coverage("roadmap", &keyword, all);
        assert_eq!(shares[&id], 1.0);
        let ranked = library.ranked_screen_hits("roadmap", keyword, &shares, &HashMap::new(), 12);
        assert_eq!(ranked.len(), 1);
        assert!(!ranked[0].1);

        let (any, all) = library
            .keyword_screen_hits("roadmap zebra", &ScreenFilter::default(), 40)
            .unwrap();
        assert!(!all, "falls back to any word");
        assert_eq!(
            library.screen_coverage("roadmap zebra", &any, false)[&id],
            0.5
        );

        let found = HashMap::from([(
            id,
            ScreenMeaningMatch {
                meaning: Meaning {
                    z: 3.0,
                    cosine: 0.9,
                    modality: Modality::Image,
                },
                ts: crate::time::from_epoch(1_000.0),
                app: "Figma".into(),
                text: None,
            },
        )]);
        let ranked =
            library.ranked_screen_hits("a picture", Vec::new(), &HashMap::new(), &found, 12);
        assert_eq!(
            ranked[0].0.snippet, "Design",
            "a picture-only match shows its title"
        );
        assert!(ranked[0].1);
    }
}
