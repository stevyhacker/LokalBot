//! Hybrid search over the file index (`Searcher`): meaning (EmbeddingGemma's
//! vectors) and words (FTS5).
//!
//! Meaning is the model's cosine similarity put on one scale per query, and only
//! segments that stand out count, which also gives an honest "nothing found".
//! Words rescue what a vector can't hold exactly: codes, IDs and names.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use std::time::Instant;

use anyhow::Result;
use chrono::{DateTime, Utc};
use parking_lot::Mutex;
use rusqlite::{OptionalExtension as _, params};

use super::index::{FileIndex, MAIN_FILE};
use super::text::{self, is_word_character};
use super::{
    DIMENSION, FileHit, FileKind, IndexOptions, Modality, exif_date, f32_from_half, is_inside,
    real_path,
};

/// Every float16 as float32, so scoring stays a plain product.
static HALVES: LazyLock<Box<[f32]>> = LazyLock::new(|| (0..=u16::MAX).map(f32_from_half).collect());

const Z_GATE: f64 = 2.0;
const WORD_WEIGHT: f64 = 2.0;
const MINIMUM_DEVIATION: f64 = 0.02;

/// A file that matched, before it becomes a `FileHit` (`SearchHit`).
#[derive(Clone, Debug, PartialEq)]
pub struct SearchHit {
    pub path: String,
    pub kind: FileKind,
    pub score: f64,
    pub z: Option<f64>,
    pub cosine: Option<f64>,
    /// 1-based rank among keyword matches.
    pub keyword_rank: Option<usize>,
    pub segment_id: i64,
    pub loc: Option<f64>,
    pub excerpt: Option<String>,
    pub modified: f64,
    pub size: i64,
    pub info: BTreeMap<String, String>,
}

impl SearchHit {
    pub fn into_file_hit(self) -> FileHit {
        let taken = self.info.get("taken").and_then(|t| exif_date(t));
        FileHit {
            id: self.segment_id,
            page: (self.kind == FileKind::Pdf)
                .then_some(self.loc.map(|l| l as i64))
                .flatten(),
            seconds: matches!(self.kind, FileKind::Audio | FileKind::Video)
                .then_some(self.loc)
                .flatten(),
            excerpt: self.excerpt,
            modified: crate::time::from_epoch(self.modified),
            taken,
            size: self.size,
            is_semantic: self.keyword_rank.is_none(),
            kind: self.kind,
            path: self.path,
        }
    }
}

#[derive(Default)]
struct Vectors {
    /// Rows × 768 float16s, row-major, as stored.
    halves: Vec<u16>,
    row_file: Vec<i64>,
    row_segment: Vec<i64>,
    row_modality: Vec<Modality>,
    /// False for the later pages of long files: scored, but they don't set the
    /// scale.
    row_sets_scale: Vec<bool>,
}

/// Search over one index. With `load_vectors` off only keyword search is ready;
/// vectors load on the first meaning search, about 1.5 KB each.
pub struct Searcher {
    index: FileIndex,
    vectors: Option<Vectors>,
    file_kind: HashMap<i64, FileKind>,
}

impl Searcher {
    pub fn new(index: FileIndex) -> Result<Self> {
        let mut searcher = Self {
            index,
            vectors: None,
            file_kind: HashMap::new(),
        };
        searcher.reload_files()?;
        Ok(searcher)
    }

    pub fn index(&self) -> &FileIndex {
        &self.index
    }

    pub fn vectors_loaded(&self) -> bool {
        self.vectors.is_some()
    }

    pub fn release_vectors(&mut self) {
        self.vectors = None;
    }

    /// Reads the files again (after indexing added some), and the vectors when
    /// they were loaded.
    pub fn refresh(&mut self) -> Result<()> {
        self.reload_files()?;
        if self.vectors.is_some() {
            self.load_vectors()?;
        }
        Ok(())
    }

    fn reload_files(&mut self) -> Result<()> {
        self.file_kind.clear();
        let mut statement = self.index.db.prepare("SELECT id, kind FROM files")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (id, kind) = row?;
            if let Some(kind) = FileKind::parse(&kind) {
                self.file_kind.insert(id, kind);
            }
        }
        Ok(())
    }

    fn load_vectors(&mut self) -> Result<()> {
        let steps = IndexOptions::default();
        let mut vectors = Vectors::default();
        let mut statement = self.index.db.prepare(
            "SELECT s.id, s.file, s.modality, s.vec, s.kind, s.loc, f.kind, \
             CAST(json_extract(f.info, '$.pages') AS INTEGER) \
             FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL ORDER BY s.id",
        )?;
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let blob = row.get_ref(3)?.as_blob()?;
            if blob.len() != DIMENSION * 2 {
                continue;
            }
            vectors.halves.extend(
                blob.as_chunks::<2>()
                    .0
                    .iter()
                    .map(|bytes| u16::from_le_bytes(*bytes)),
            );
            vectors.row_segment.push(row.get(0)?);
            vectors.row_file.push(row.get(1)?);
            vectors
                .row_modality
                .push(Modality::parse(&row.get::<_, String>(2)?));
            let kind: String = row.get(4)?;
            let place = row.get::<_, Option<f64>>(5)?.unwrap_or(0.0) as usize;
            let file_kind: String = row.get(6)?;
            let pages = row.get::<_, Option<i64>>(7)?.unwrap_or(0) as usize;
            let later = if file_kind == "pdf" {
                kind != "chunk" && pages > steps.big_pdf_pages && place > steps.pdf_step
            } else {
                kind == "chunk" && place > steps.doc_step
            };
            vectors.row_sets_scale.push(!later);
        }
        self.vectors = Some(vectors);
        Ok(())
    }

    /// The hits for `text`, best first. Kinds narrow the result, not the scale.
    pub fn search(
        &mut self,
        text_query: &str,
        query_vector: Option<&[f32]>,
        kinds: Option<&HashSet<FileKind>>,
        limit: usize,
    ) -> Result<Vec<SearchHit>> {
        if query_vector.is_some() && self.vectors.is_none() {
            self.load_vectors()?;
        }
        let file_kind = &self.file_kind;
        let allowed = |file: i64| {
            kinds.is_none_or(|kinds| file_kind.get(&file).is_some_and(|k| kinds.contains(k)))
        };

        // Meaning: every vector on this query's scale; each file's best segment.
        let mut best: HashMap<i64, (f64, f64, usize)> = HashMap::new();
        if let (Some(query), Some(vectors)) = (query_vector, self.vectors.as_ref())
            && query.len() == DIMENSION
            && !vectors.row_file.is_empty()
        {
            let scores = score(&vectors.halves, query);
            let meaning = meaning(&scores, &vectors.row_modality, &vectors.row_sets_scale);
            for (row, z) in meaning.iter().enumerate() {
                let file = vectors.row_file[row];
                if allowed(file) && best.get(&file).is_none_or(|(known, _, _)| z > known) {
                    best.insert(file, (*z, scores[row] as f64, row));
                }
            }
        }

        // Words: FTS5 with stemming over names, folders, screenshots' text,
        // pages and documents.
        let query_terms = terms(text_query);
        let mut patterns = patterns(&query_terms);
        // A word in no file as typed matches as the start of longer words. One
        // that is in the index stays whole, and so does a word of two letters.
        for (index, term) in query_terms.iter().enumerate() {
            if term.chars().count() >= 3
                && !patterns[index].ends_with('*')
                && !self.is_indexed(&patterns[index])?
            {
                patterns[index].push('*');
            }
        }
        let mut words: Vec<(i64, i64, Option<String>)> = Vec::new();
        let mut coverage: HashMap<i64, f64> = HashMap::new();
        if !patterns.is_empty() {
            let mut seen = HashSet::new();
            let mut statement = self.index.db.prepare_cached(
                "SELECT s.file, s.id, snippet(fts, 1, '«', '»', '…', 12), fts.original FROM fts \
                 JOIN segments s ON s.id = fts.rowid \
                 WHERE fts MATCH ?1 ORDER BY bm25(fts, 3.0, 1.0) LIMIT 1000",
            )?;
            let mut rows = statement.query([patterns.join(" OR ")])?;
            while let Some(row) = rows.next()? {
                let file: i64 = row.get(0)?;
                if words.len() >= 100 || !allowed(file) || !seen.insert(file) {
                    continue;
                }
                // Text normalizing changed is quoted as it's written.
                let original: Option<String> = row.get(3)?;
                let snippet = original
                    .and_then(|o| text::snippet(&o, &query_terms, 12))
                    .or(row.get(2)?);
                words.push((file, row.get(1)?, snippet));
            }
            drop(rows);
            drop(statement);
            if !words.is_empty() {
                let files: Vec<String> = words.iter().map(|(file, ..)| file.to_string()).collect();
                let files = files.join(",");
                let mut statement = self.index.db.prepare(&format!(
                    "SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid \
                     WHERE fts MATCH ?1 AND s.file IN ({files})"
                ))?;
                for pattern in &patterns {
                    let rows = statement.query_map([pattern], |row| row.get::<_, i64>(0))?;
                    for file in rows {
                        *coverage.entry(file?).or_default() += 1.0 / patterns.len() as f64;
                    }
                }
            }
        }

        // A file qualifies by standing out in meaning, or by holding at least
        // half of the query's words. Score: meaning z + a bonus that grows with
        // word coverage, + 1 for the kind the query asks for.
        let lookup = is_lookup(&query_terms);
        let (meaning_weight, words_weight) = if lookup {
            (0.5, WORD_WEIGHT * 2.0)
        } else {
            (1.0, WORD_WEIGHT)
        };
        let hinted = kind_hints(text_query);
        let mut candidates: HashSet<i64> = best
            .iter()
            .filter(|(_, (z, _, _))| *z >= Z_GATE)
            .map(|(file, _)| *file)
            .collect();
        candidates.extend(
            coverage
                .iter()
                .filter(|(_, share)| **share >= 0.5)
                .map(|(file, _)| *file),
        );
        let mut scored: Vec<(i64, f64)> = candidates
            .into_iter()
            .map(|file| {
                let z = best.get(&file).map_or(0.0, |(z, _, _)| *z);
                let share = coverage.get(&file).copied().unwrap_or(0.0);
                let mut score = meaning_weight * z.max(0.0) + words_weight * share.powf(1.5);
                if file_kind.get(&file).is_some_and(|k| hinted.contains(k)) {
                    score += 1.0;
                }
                (file, score)
            })
            .collect();
        scored.sort_by(|a, b| {
            b.1.partial_cmp(&a.1)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.0.cmp(&b.0))
        });

        let word_rank: HashMap<i64, (usize, i64, Option<String>)> = words
            .into_iter()
            .enumerate()
            .rev()
            .map(|(offset, (file, segment, snippet))| (file, (offset + 1, segment, snippet)))
            .collect();
        let mut hits = Vec::new();
        for (file, score) in scored.into_iter().take(limit) {
            let semantic = best.get(&file);
            let keyword = word_rank.get(&file);
            // Point at the best meaning segment if it stands out; else at the
            // segment the words matched.
            let use_meaning = semantic.is_some_and(|(z, _, _)| *z >= Z_GATE || keyword.is_none());
            let segment_id = if use_meaning {
                self.vectors
                    .as_ref()
                    .and_then(|vectors| semantic.map(|(_, _, row)| vectors.row_segment[*row]))
            } else {
                keyword.map(|(_, segment, _)| *segment)
            };
            let Some(segment_id) = segment_id else {
                continue;
            };
            let (path, kind, modified, size, info): (String, String, f64, i64, Option<String>) =
                self.index.db.query_row(
                    "SELECT path, kind, mtime, size, info FROM files WHERE id = ?1",
                    [file],
                    |row| {
                        Ok((
                            row.get(0)?,
                            row.get(1)?,
                            row.get(2)?,
                            row.get(3)?,
                            row.get(4)?,
                        ))
                    },
                )?;
            let (loc, stored_excerpt): (Option<f64>, Option<String>) = self.index.db.query_row(
                "SELECT loc, excerpt FROM segments WHERE id = ?1",
                [segment_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )?;
            // Quote the matched words only when they come from the segment we
            // point at, so a PDF hit on page 5 never shows page 2's words. A
            // segment with no place and no text of its own (a screenshot's image
            // vector) can borrow them from its file's text, unless they matched
            // only the name.
            let mut snippet = keyword
                .filter(|(_, segment, _)| *segment == segment_id)
                .and_then(|(_, _, snippet)| snippet.as_deref())
                .filter(|s| s.contains('«'))
                .map(|s| text::excerpt(s, 400));
            if snippet.is_none()
                && stored_excerpt.is_none()
                && loc.is_none()
                && let Some((_, segment, Some(words))) = keyword
                && words.contains('«')
            {
                let kind: Option<String> = self
                    .index
                    .db
                    .query_row(
                        "SELECT kind FROM segments WHERE id = ?1",
                        [segment],
                        |row| row.get(0),
                    )
                    .optional()?;
                if kind.as_deref() != Some("name") {
                    snippet = Some(text::excerpt(words, 400));
                }
            }
            hits.push(SearchHit {
                path,
                kind: FileKind::parse(&kind).unwrap_or(FileKind::Doc),
                score,
                z: semantic.map(|(z, _, _)| *z),
                cosine: semantic.map(|(_, cosine, _)| *cosine),
                keyword_rank: keyword.map(|(rank, _, _)| *rank),
                segment_id,
                loc,
                excerpt: snippet.or(stored_excerpt),
                modified,
                size,
                info: info
                    .and_then(|json| serde_json::from_str(&json).ok())
                    .unwrap_or_default(),
            });
        }
        Ok(hits)
    }

    /// The text of a page, a passage or a screenshot's words, as written.
    pub fn text_of_segment(&self, id: i64) -> Result<Option<String>> {
        Ok(self
            .index
            .db
            .query_row(
                "SELECT coalesce(original, body) FROM fts WHERE rowid = ?1",
                [id],
                |row| row.get(0),
            )
            .optional()?
            .flatten())
    }

    /// A passage cited by an earlier answer, by its id; `None` once its file left
    /// the index.
    pub fn hit(&self, segment: i64) -> Result<Option<FileHit>> {
        Ok(self
            .index
            .db
            .query_row(
                "SELECT f.path, f.kind, f.mtime, f.size, s.loc, s.excerpt \
                 FROM segments s JOIN files f ON f.id = s.file WHERE s.id = ?1",
                params![segment],
                |row| {
                    let kind = FileKind::parse(&row.get::<_, String>(1)?).unwrap_or(FileKind::Doc);
                    let loc: Option<f64> = row.get(4)?;
                    Ok(FileHit {
                        id: segment,
                        path: row.get(0)?,
                        kind,
                        page: (kind == FileKind::Pdf)
                            .then_some(loc.map(|l| l as i64))
                            .flatten(),
                        seconds: matches!(kind, FileKind::Audio | FileKind::Video)
                            .then_some(loc)
                            .flatten(),
                        excerpt: row.get(5)?,
                        modified: crate::time::from_epoch(row.get(2)?),
                        taken: None,
                        size: row.get(3)?,
                        is_semantic: false,
                    })
                },
            )
            .optional()?)
    }

    fn is_indexed(&self, pattern: &str) -> Result<bool> {
        Ok(self
            .index
            .db
            .query_row(
                "SELECT 1 FROM fts WHERE fts MATCH ?1 LIMIT 1",
                [pattern],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }
}

/// Cosine similarity with every stored vector (all are L2-normalized).
fn score(halves: &[u16], query: &[f32]) -> Vec<f32> {
    let table: &[f32] = &HALVES;
    halves
        .as_chunks::<DIMENSION>()
        .0
        .iter()
        .map(|row| {
            row.iter()
                .zip(query)
                .map(|(half, q)| table[*half as usize] * q)
                .sum()
        })
        .collect()
}

/// Each vector's cosine minus the average of its modality, in standard
/// deviations of all of them together. The scale comes from `sets_scale`, so a
/// book's hundreds of later pages don't move it (`Searcher.meaning`).
pub fn meaning(scores: &[f32], modality: &[Modality], sets_scale: &[bool]) -> Vec<f64> {
    let means = modality_means(scores, modality, sets_scale);
    let centered: Vec<f64> = scores
        .iter()
        .zip(modality)
        .map(|(score, modality)| *score as f64 - means.get(modality).copied().unwrap_or(0.0))
        .collect();
    let (mut count, mut sum) = (0.0, 0.0);
    for (value, counts) in centered.iter().zip(sets_scale) {
        if *counts {
            count += 1.0;
            sum += value;
        }
    }
    let mean = sum / f64::max(count, 1.0);
    let mut squares = 0.0;
    for (value, counts) in centered.iter().zip(sets_scale) {
        if *counts {
            squares += (value - mean) * (value - mean);
        }
    }
    let deviation = (squares / f64::max(count, 1.0))
        .sqrt()
        .max(MINIMUM_DEVIATION);
    centered
        .iter()
        .map(|value| (value - mean) / deviation)
        .collect()
}

/// The average score of each modality for this query. Fewer than 20 vectors take
/// the average of all.
fn modality_means(
    scores: &[f32],
    modality: &[Modality],
    sets_scale: &[bool],
) -> HashMap<Modality, f64> {
    let mut sum: HashMap<Modality, f64> = HashMap::new();
    let mut count: HashMap<Modality, usize> = HashMap::new();
    for ((score, modality), counts) in scores.iter().zip(modality).zip(sets_scale) {
        if *counts {
            *sum.entry(*modality).or_default() += *score as f64;
            *count.entry(*modality).or_default() += 1;
        }
    }
    let total: usize = count.values().sum();
    let all = sum.values().sum::<f64>() / f64::max(total as f64, 1.0);
    [
        Modality::None,
        Modality::Text,
        Modality::Image,
        Modality::Audio,
    ]
    .into_iter()
    .map(|m| {
        let mean = match (sum.get(&m), count.get(&m)) {
            (Some(sum), Some(n)) if *n >= 20 => sum / *n as f64,
            _ => all,
        };
        (m, mean)
    })
    .collect()
}

const STOPWORDS: &[&str] = &[
    "a",
    "an",
    "the",
    "of",
    "in",
    "on",
    "at",
    "to",
    "for",
    "with",
    "and",
    "or",
    "my",
    "me",
    "that",
    "this",
    "these",
    "those",
    "from",
    "about",
    "where",
    "what",
    "which",
    "who",
    "when",
    "is",
    "was",
    "are",
    "were",
    "be",
    "it",
    "its",
    "some",
    "any",
    "find",
    "show",
    "file",
    "files",
    "photo",
    "photos",
    "picture",
    "image",
    "images",
    "screenshot",
    "screenshots",
    "video",
    "videos",
    "pdf",
    "document",
    "documents",
    "recording",
    // Bengali and Arabic (normalized, as `terms` sees them)
    "এবং",
    "ও",
    "এই",
    "সেই",
    "একটি",
    "আমার",
    "থেকে",
    "জন্য",
    "সাথে",
    "মধ্যে",
    "কোথায়",
    "কোন",
    "কী",
    "কি",
    "যে",
    "ছবি",
    "স্ক্রিনশট",
    "ভিডিও",
    "ফাইল",
    "পিডিএফ",
    "في",
    "من",
    "على",
    "الى",
    "عن",
    "مع",
    "هذا",
    "هذه",
    "ذلك",
    "التي",
    "الذي",
    "اين",
    "ما",
    "صورة",
    "صور",
    "لقطة",
    "شاشة",
    "فيديو",
    "ملف",
    "مستند",
];

/// The content words of a query, normalized as keyword search keeps its text.
/// Kind words and stopwords describe what to look for, not what's in it.
pub fn terms(query: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    text::normalized(query)
        .to_lowercase()
        .split(|c: char| !is_word_character(c))
        .filter(|word| word.chars().count() >= 2 && !STOPWORDS.contains(word))
        .filter(|word| seen.insert(word.to_string()))
        .map(str::to_string)
        .collect()
}

/// FTS5 patterns for the query's words: quoted, and as prefixes for words of
/// languages that attach endings.
fn patterns(terms: &[String]) -> Vec<String> {
    terms
        .iter()
        .map(|term| {
            let star = if text::inflects(term) { "*" } else { "" };
            format!("\"{term}\"{star}")
        })
        .collect()
}

/// Codes and IDs ("K7Q2LM") and long numbers mean nothing to an embedding but
/// everything to keyword search: such a query weighs words double and meaning
/// half.
pub fn is_lookup(terms: &[String]) -> bool {
    !terms.is_empty()
        && terms.iter().all(|term| {
            term.chars().any(char::is_numeric)
                && (term.chars().any(char::is_alphabetic) || term.chars().count() >= 4)
        })
}

const KIND_WORDS: &[(&str, FileKind)] = &[
    ("screenshot", FileKind::Screenshot),
    ("screenshots", FileKind::Screenshot),
    ("photo", FileKind::Image),
    ("photos", FileKind::Image),
    ("picture", FileKind::Image),
    ("pictures", FileKind::Image),
    ("image", FileKind::Image),
    ("images", FileKind::Image),
    ("pdf", FileKind::Pdf),
    ("pdfs", FileKind::Pdf),
    ("paper", FileKind::Pdf),
    ("papers", FileKind::Pdf),
    ("document", FileKind::Doc),
    ("documents", FileKind::Doc),
    ("note", FileKind::Doc),
    ("notes", FileKind::Doc),
    ("video", FileKind::Video),
    ("videos", FileKind::Video),
    ("clip", FileKind::Video),
    ("movie", FileKind::Video),
    ("audio", FileKind::Audio),
    ("song", FileKind::Audio),
    ("podcast", FileKind::Audio),
    ("voice", FileKind::Audio),
    ("sound", FileKind::Audio),
    ("স্ক্রিনশট", FileKind::Screenshot),
    ("ছবি", FileKind::Image),
    ("পিডিএফ", FileKind::Pdf),
    ("নোট", FileKind::Doc),
    ("ভিডিও", FileKind::Video),
    ("অডিও", FileKind::Audio),
    ("গান", FileKind::Audio),
    ("রেকর্ডিং", FileKind::Audio),
    ("لقطة", FileKind::Screenshot),
    ("صورة", FileKind::Image),
    ("صور", FileKind::Image),
    ("مستند", FileKind::Doc),
    ("ملاحظات", FileKind::Doc),
    ("فيديو", FileKind::Video),
    ("مقطع", FileKind::Video),
    ("صوت", FileKind::Audio),
    ("تسجيل", FileKind::Audio),
    ("اغنية", FileKind::Audio),
];

/// Kinds the query asks for: a soft boost, not a filter.
fn kind_hints(query: &str) -> HashSet<FileKind> {
    let normalized = text::normalized(query).to_lowercase();
    normalized
        .split(|c: char| !is_word_character(c))
        .filter(|word| !word.is_empty())
        .filter_map(|word| {
            KIND_WORDS
                .iter()
                .find(|(key, _)| *key == word)
                .or_else(|| {
                    KIND_WORDS.iter().find(|(key, _)| {
                        text::inflects(key) && key.chars().count() >= 3 && word.starts_with(key)
                    })
                })
                .map(|(_, kind)| *kind)
        })
        .collect()
}

// ---------------------------------------------------------------- the reader

/// How long vectors stay in memory after a search by meaning.
const VECTOR_IDLE_SECONDS: u64 = 600;

struct ReaderState {
    searcher: Option<Searcher>,
    stale: bool,
    last_search: Option<Instant>,
}

/// Owns the searcher: its own connection, so a search never waits for indexing
/// (`FileSearchReader`). Shared between the app's search, Ask and the engine.
pub struct FileReader {
    directory: PathBuf,
    state: Mutex<ReaderState>,
}

/// One reader per library.
static READERS: LazyLock<Mutex<HashMap<PathBuf, Arc<FileReader>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// The folders a search may return, and when (`FileSearchService.search`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FileInterval {
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
}

impl FileInterval {
    fn contains(&self, at: DateTime<Utc>) -> bool {
        self.since.is_none_or(|s| at >= s) && self.until.is_none_or(|u| at < u)
    }

    fn is_open(&self) -> bool {
        self.since.is_none() && self.until.is_none()
    }
}

impl FileReader {
    pub fn shared(root: &Path) -> Arc<FileReader> {
        let directory = super::index_dir(root);
        READERS
            .lock()
            .entry(directory.clone())
            .or_insert_with(|| {
                Arc::new(FileReader {
                    directory,
                    state: Mutex::new(ReaderState {
                        searcher: None,
                        stale: false,
                        last_search: None,
                    }),
                })
            })
            .clone()
    }

    fn with_searcher<T>(
        &self,
        is_search: bool,
        body: impl FnOnce(&mut Searcher) -> Result<T>,
    ) -> Option<T> {
        if !self.directory.join(MAIN_FILE).is_file() {
            return None;
        }
        let mut state = self.state.lock();
        if is_search {
            state.last_search = Some(Instant::now());
        }
        if state.searcher.is_none() {
            match FileIndex::open(&self.directory).and_then(Searcher::new) {
                Ok(searcher) => {
                    state.searcher = Some(searcher);
                    state.stale = false;
                }
                Err(err) => {
                    log::warn!("file search: cannot open the index: {err:#}");
                    return None;
                }
            }
        }
        if state.stale {
            state.stale = false;
            if let Some(searcher) = state.searcher.as_mut()
                && let Err(err) = searcher.refresh()
            {
                log::warn!("file search: cannot reread the index: {err:#}");
            }
        }
        let searcher = state.searcher.as_mut()?;
        match body(searcher) {
            Ok(value) => Some(value),
            Err(err) => {
                log::warn!("file search failed: {err:#}");
                None
            }
        }
    }

    /// Files that match `query`, best first, only under `folders` and only ones
    /// that still exist. With a query vector it searches by meaning and by words;
    /// without one, by words only.
    pub fn search(
        &self,
        query: &str,
        query_vector: Option<&[f32]>,
        folders: &[String],
        interval: FileInterval,
        limit: usize,
    ) -> Vec<FileHit> {
        if folders.is_empty() || query.trim().is_empty() {
            return Vec::new();
        }
        // A walk reports a folder as its real path, so a file matches either.
        let roots: Vec<String> = folders
            .iter()
            .flat_map(|folder| [folder.clone(), real_path(folder)])
            .collect();
        // Ask enough to fill the list after the date filter drops some.
        let wanted = if interval.is_open() { limit } else { limit * 4 };
        let found = self
            .with_searcher(true, |searcher| {
                searcher.search(query, query_vector, None, wanted)
            })
            .unwrap_or_default();
        found
            .into_iter()
            .filter(|hit| roots.iter().any(|root| is_inside(&hit.path, root)))
            .filter(|hit| Path::new(&hit.path).exists())
            .map(SearchHit::into_file_hit)
            .filter(|hit| interval.contains(hit.date()))
            .take(limit)
            .collect()
    }

    /// The stored text of a matched passage, for the assistant to read.
    pub fn passage(&self, segment: i64) -> Option<String> {
        self.with_searcher(false, |searcher| searcher.text_of_segment(segment))
            .flatten()
    }

    /// A passage cited by an earlier answer; `None` once its file left the index.
    pub fn hit(&self, segment: i64) -> Option<FileHit> {
        self.with_searcher(false, |searcher| searcher.hit(segment))
            .flatten()
    }

    /// New files were indexed: the next search reads them.
    pub fn mark_stale(&self) {
        self.state.lock().stale = true;
    }

    /// Frees the vectors when nothing searched for a while.
    pub fn release_if_idle(&self) {
        let mut state = self.state.lock();
        let idle = state
            .last_search
            .is_none_or(|at| at.elapsed().as_secs() > VECTOR_IDLE_SECONDS);
        if idle
            && let Some(searcher) = state.searcher.as_mut()
            && searcher.vectors_loaded()
        {
            searcher.release_vectors();
        }
    }

    /// Lets go of the connection, before the index is deleted.
    pub fn close(&self) {
        let mut state = self.state.lock();
        state.searcher = None;
        state.last_search = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::index::tests::candidate;
    use crate::files::{SegmentKind, half_from_f32};

    fn unit(axis: usize) -> Vec<f32> {
        let mut vector = vec![0.0; DIMENSION];
        vector[axis] = 1.0;
        vector
    }

    fn add_doc(
        index: &FileIndex,
        path: &str,
        inode: u64,
        body: Option<&str>,
        vector: Option<&[f32]>,
    ) -> i64 {
        let mut file = candidate(path, FileKind::Doc);
        file.inode = inode;
        let id = index.insert(&file).unwrap();
        index
            .add_segment(
                id,
                SegmentKind::Chunk,
                Modality::Text,
                Some(1.0),
                None,
                body.map(|b| text::excerpt(b, 240)).as_deref(),
                body,
                vector,
            )
            .unwrap();
        index.finish(id, "done", None, &BTreeMap::new()).unwrap();
        id
    }

    #[test]
    fn terms_drop_stopwords_and_kind_words() {
        assert_eq!(terms("find the Invoice photo 2041"), ["invoice", "2041"]);
        assert!(terms("the a of").is_empty());
        assert!(is_lookup(&terms("K7Q2LM")));
        assert!(is_lookup(&terms("4815162342")));
        assert!(!is_lookup(&terms("invoice 2041")));
        assert!(!is_lookup(&[]));
    }

    #[test]
    fn hints_boost_the_kind_asked_for() {
        let hints = kind_hints("that screenshot of the invoice");
        assert!(hints.contains(&FileKind::Screenshot));
        assert!(kind_hints("ভিডিওতে কুকুর").contains(&FileKind::Video));
    }

    #[test]
    fn words_find_passages_and_quote_them() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(dir.path()).unwrap();
        add_doc(
            &index,
            "/x/plan.md",
            1,
            Some("The quarterly roadmap is due Friday."),
            None,
        );
        add_doc(
            &index,
            "/x/other.md",
            2,
            Some("Nothing to see here at all."),
            None,
        );
        add_doc(&index, "/x/roadmap.md", 3, None, None);
        let mut searcher = Searcher::new(index).unwrap();
        let hits = searcher.search("roadmap", None, None, 10).unwrap();
        assert_eq!(hits.len(), 2);
        // The name counts three times the body in the keyword order; equal scores
        // then go by file.
        let named = hits.iter().find(|h| h.path == "/x/roadmap.md").unwrap();
        assert_eq!(named.keyword_rank, Some(1));
        let body = hits.iter().find(|h| h.path == "/x/plan.md").unwrap();
        assert!(body.excerpt.as_deref().unwrap().contains("«roadmap»"));
        assert_eq!(body.keyword_rank, Some(2));
        assert!(
            searcher.search("zebra", None, None, 10).unwrap().is_empty(),
            "nothing found stays nothing"
        );
        // A word in no file as typed matches as a prefix.
        assert_eq!(searcher.search("roadma", None, None, 10).unwrap().len(), 2);
    }

    #[test]
    fn kinds_filter_the_results() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(dir.path()).unwrap();
        add_doc(&index, "/x/a.md", 1, Some("zebra crossing"), None);
        let mut searcher = Searcher::new(index).unwrap();
        let only_pdf = HashSet::from([FileKind::Pdf]);
        assert!(
            searcher
                .search("zebra", None, Some(&only_pdf), 10)
                .unwrap()
                .is_empty()
        );
        let only_doc = HashSet::from([FileKind::Doc]);
        assert_eq!(
            searcher
                .search("zebra", None, Some(&only_doc), 10)
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn meaning_needs_to_stand_out() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(dir.path()).unwrap();
        // Many files far from the query, one close to it.
        for i in 0..30 {
            add_doc(
                &index,
                &format!("/x/far{i}.md"),
                100 + i,
                Some("background text"),
                Some(&unit(1 + (i as usize % 5))),
            );
        }
        add_doc(
            &index,
            "/x/near.md",
            1,
            Some("something else"),
            Some(&unit(0)),
        );
        let mut searcher = Searcher::new(index).unwrap();
        assert!(!searcher.vectors_loaded());
        let hits = searcher
            .search("query words", Some(&unit(0)), None, 10)
            .unwrap();
        assert!(searcher.vectors_loaded());
        assert_eq!(hits.len(), 1, "{hits:?}");
        assert_eq!(hits[0].path, "/x/near.md");
        assert!(hits[0].z.unwrap() >= Z_GATE);
        assert!((hits[0].cosine.unwrap() - 1.0).abs() < 1e-3);
        assert_eq!(hits[0].keyword_rank, None);
        assert!(hits[0].clone().into_file_hit().is_semantic);
        searcher.release_vectors();
        assert!(!searcher.vectors_loaded());
    }

    #[test]
    fn a_small_group_takes_the_average_of_all() {
        let scores = [0.9f32, 0.1, 0.1];
        let modality = [Modality::Image, Modality::Text, Modality::Text];
        let means = modality_means(&scores, &modality, &[true; 3]);
        let all = (0.9f32 as f64 + 0.1f32 as f64 + 0.1f32 as f64) / 3.0;
        assert!((means[&Modality::Image] - all).abs() < 1e-9);
        assert!((means[&Modality::Text] - all).abs() < 1e-9);
        // The later pages don't move the scale.
        let scaled = meaning(&[0.5, 0.5, 0.9], &[Modality::Text; 3], &[true, true, false]);
        assert!(scaled[2] > 2.0, "{scaled:?}");
    }

    /// A row the way the Mac's DigUpKit writes it: raw SQL and hand-made blobs.
    #[test]
    fn reads_the_macs_format() {
        let dir = tempfile::tempdir().unwrap();
        let index = FileIndex::open(dir.path()).unwrap();
        let vector: Vec<u8> = (0..DIMENSION)
            .flat_map(|i| half_from_f32(if i == 3 { 1.0 } else { 0.0 }).to_le_bytes())
            .collect();
        index
            .db
            .execute_batch(
                "INSERT INTO files(id, path, kind, size, mtime, inode, device, state, info, indexed_at)
                 VALUES (1, '/Users/m/Documents/Report.pdf', 'pdf', 99, 1730000000.5, 5, 6, 'done',
                         '{\"pages\":\"2\",\"scanned_pages\":\"0\",\"taken\":\"2026:05:14 18:02:11\"}', 1730000001.0);
                 INSERT INTO segments(id, file, kind, modality) VALUES (10, 1, 'name', 'none');
                 INSERT INTO fts(rowid, name, body) VALUES (10, 'Report.pdf', 'Documents');
                 INSERT INTO segments(id, file, kind, modality, loc, excerpt) VALUES (11, 1, 'page', 'none', 2.0, 'The budget');
                 INSERT INTO fts(rowid, name, body, original) VALUES (11, '', 'The budget is 40', 'The bu\u{00AD}dget is 40');",
            )
            .unwrap();
        index
            .db
            .execute(
                "INSERT INTO segments(id, file, kind, modality, loc, vec) VALUES (12, 1, 'page', 'text', 1.0, ?1)",
                [vector],
            )
            .unwrap();
        let mut searcher = Searcher::new(index).unwrap();
        let hit = searcher
            .search("budget", None, None, 5)
            .unwrap()
            .remove(0)
            .into_file_hit();
        assert_eq!(hit.id, 11);
        assert_eq!(hit.kind, FileKind::Pdf);
        assert_eq!(hit.page, Some(2));
        assert_eq!(hit.size, 99);
        assert_eq!(hit.name(), "Report.pdf");
        assert!(hit.taken.is_some());
        assert_eq!(hit.date(), hit.taken.unwrap());
        assert_eq!(hit.kind_label(), "PDF · page 2");
        assert_eq!(
            searcher.text_of_segment(11).unwrap().as_deref(),
            Some("The bu\u{00AD}dget is 40")
        );
        let by_meaning = searcher
            .search("nothing shared", Some(&unit(3)), None, 5)
            .unwrap();
        assert_eq!(
            by_meaning.len(),
            0,
            "one row can't stand out by 2 deviations"
        );
        assert_eq!(searcher.hit(11).unwrap().unwrap().page, Some(2));
        assert_eq!(searcher.hit(99).unwrap(), None);
    }

    #[test]
    fn the_reader_limits_results_to_the_chosen_folders() {
        let root = tempfile::tempdir().unwrap();
        let docs = root.path().join("docs");
        std::fs::create_dir_all(&docs).unwrap();
        let inside = docs.join("in.md");
        std::fs::write(&inside, "x").unwrap();
        let index = FileIndex::open(&super::super::index_dir(root.path())).unwrap();
        add_doc(&index, &inside.to_string_lossy(), 1, Some("zebra"), None);
        add_doc(&index, "/elsewhere/out.md", 2, Some("zebra"), None);
        add_doc(
            &index,
            &docs.join("gone.md").to_string_lossy(),
            3,
            Some("zebra"),
            None,
        );
        drop(index);
        let reader = FileReader::shared(root.path());
        let folders = [docs.to_string_lossy().into_owned()];
        let hits = reader.search("zebra", None, &folders, FileInterval::default(), 10);
        assert_eq!(hits.len(), 1, "{hits:?}");
        assert_eq!(hits[0].path, inside.to_string_lossy());
        assert!(
            reader
                .search("zebra", None, &[], FileInterval::default(), 10)
                .is_empty()
        );
        // The date filter uses the file's date.
        let later = crate::time::from_epoch(1000.0);
        let window = FileInterval {
            since: Some(later),
            until: None,
        };
        assert!(
            reader
                .search("zebra", None, &folders, window, 10)
                .is_empty()
        );
        reader.close();
    }
}
