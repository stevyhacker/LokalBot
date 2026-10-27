//! Semantic search storage (`EmbeddingIndex.swift`). Vectors are computed
//! by the AI layer; this module chunks text, stores vectors and ranks them.

use std::collections::HashMap;
use std::hash::Hash;

use anyhow::{Result, bail};
use rusqlite::{OptionalExtension as _, params};
use uuid::Uuid;

use crate::library::Library;
use crate::model::*;
use crate::timeline::table_exists;

/// The macOS index version; vectors from another model are not comparable.
pub const MODEL_ID: &str = "embeddinggemma-2-q8-mean-768-v1";
/// Prompt prefix for documents and for queries.
pub const DOCUMENT_PREFIX: &str = "title: none | text: ";
pub const QUERY_PREFIX: &str = "task: search result | query: ";
pub const MEETING_SIMILARITY_FLOOR: f32 = 0.61;
pub const SCREEN_SIMILARITY_FLOOR: f32 = 0.58;
/// Marks chunks taken from the user's own notes.
pub const NOTES_CHUNK_MARKER: &str = "My meeting notes: ";
const TRANSCRIPT_TARGET_CHARS: usize = 500;
const TRANSCRIPT_HARD_LIMIT_CHARS: usize = 1800;
/// Reciprocal rank fusion constant.
pub const RRF_K: f64 = 60.0;

/// Pieces of at most `maximum` characters, cut at whitespace in the second
/// half when possible; concatenating them reproduces the input.
fn split_text(text: &str, maximum: usize) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut pieces = Vec::new();
    let mut start = 0;
    while chars.len() - start > maximum {
        let hard_end = start + maximum;
        let soft_start = start + maximum / 2;
        let end = (soft_start..hard_end)
            .rev()
            .find(|&i| chars[i].is_whitespace())
            .map_or(hard_end, |i| i + 1);
        pieces.push(chars[start..end].iter().collect());
        start = end;
    }
    if start < chars.len() {
        pieces.push(chars[start..].iter().collect());
    }
    pieces
}

/// `(start seconds, text)` chunks to embed for one meeting
/// (`EmbeddingIndex.transcriptChunks`, summary sections, `notesChunks`).
pub fn embedding_chunks(
    transcript: &Transcript,
    summary: Option<&str>,
    notes: &str,
) -> Vec<(f64, String)> {
    let mut chunks: Vec<(f64, String)> = Vec::new();
    let mut current = String::new();
    let mut current_len = 0;
    let mut start = 0.0;
    let flush = |chunks: &mut Vec<(f64, String)>,
                 current: &mut String,
                 current_len: &mut usize,
                 start: f64| {
        if !current.is_empty() {
            chunks.push((start, std::mem::take(current)));
            *current_len = 0;
        }
    };
    let roster = transcript.speaker_roster();
    for segment in &transcript.segments {
        let speaker = roster
            .get(&Transcript::canonical_speaker_key(&segment.speaker))
            .cloned()
            .unwrap_or_else(|| Transcript::default_speaker_name(&segment.speaker));
        let line = format!("{speaker}: {}\n", segment.text);
        let line_len = line.chars().count();
        if line_len > TRANSCRIPT_HARD_LIMIT_CHARS {
            flush(&mut chunks, &mut current, &mut current_len, start);
            chunks.extend(
                split_text(&line, TRANSCRIPT_TARGET_CHARS)
                    .into_iter()
                    .map(|p| (segment.start, p)),
            );
            continue;
        }
        if !current.is_empty() && current_len + line_len > TRANSCRIPT_HARD_LIMIT_CHARS {
            flush(&mut chunks, &mut current, &mut current_len, start);
        }
        if current.is_empty() {
            start = segment.start;
        }
        current.push_str(&line);
        current_len += line_len;
        if current_len > TRANSCRIPT_TARGET_CHARS {
            flush(&mut chunks, &mut current, &mut current_len, start);
        }
    }
    flush(&mut chunks, &mut current, &mut current_len, start);
    if let Some(summary) = summary {
        for section in summary.split("\n## ") {
            if section.chars().count() > 40 {
                chunks.push((0.0, section.chars().take(700).collect()));
            }
        }
    }
    if !notes.trim().is_empty() {
        chunks.extend(
            split_text(notes, 700)
                .into_iter()
                .map(|p| (0.0, format!("{NOTES_CHUNK_MARKER}{p}"))),
        );
    }
    chunks
}

/// Reciprocal rank fusion of a lexical and a semantic ranking (`k` = 60):
/// score = Σ 1/(k + rank). Ties: lexical evidence first, then the best single
/// rank, then the key.
pub fn rrf_fuse<K: Clone + Eq + Hash + Ord>(
    lexical: &[K],
    semantic: &[K],
    k: f64,
) -> Vec<(K, f64)> {
    let mut lexical_ranks: HashMap<&K, usize> = HashMap::new();
    for (index, key) in lexical.iter().enumerate() {
        lexical_ranks.entry(key).or_insert(index + 1);
    }
    let mut semantic_ranks: HashMap<&K, usize> = HashMap::new();
    for (index, key) in semantic.iter().enumerate() {
        semantic_ranks.entry(key).or_insert(index + 1);
    }
    let constant = k.max(1.0);
    let mut keys: Vec<&K> = lexical_ranks
        .keys()
        .chain(semantic_ranks.keys())
        .copied()
        .collect();
    keys.sort();
    keys.dedup();
    let mut scored: Vec<(K, f64, bool, usize)> = keys
        .into_iter()
        .map(|key| {
            let l = lexical_ranks.get(key).copied();
            let s = semantic_ranks.get(key).copied();
            let score = [l, s]
                .into_iter()
                .flatten()
                .map(|r| 1.0 / (constant + r as f64))
                .sum();
            let best = l.unwrap_or(usize::MAX).min(s.unwrap_or(usize::MAX));
            (key.clone(), score, l.is_some(), best)
        })
        .collect();
    scored.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.2.cmp(&a.2))
            .then(a.3.cmp(&b.3))
            .then(a.0.cmp(&b.0))
    });
    scored
        .into_iter()
        .map(|(key, score, _, _)| (key, score))
        .collect()
}

fn vector_bytes(vector: &[f32]) -> Vec<u8> {
    vector.iter().flat_map(|v| v.to_le_bytes()).collect()
}

fn dot(blob: &[u8], query: &[f32]) -> Option<f32> {
    if blob.len() != query.len() * 4 {
        return None;
    }
    Some(
        blob.as_chunks::<4>()
            .0
            .iter()
            .zip(query)
            .map(|(bytes, q)| f32::from_le_bytes(*bytes) * q)
            .sum(),
    )
}

impl Library {
    /// Newest modification time of the files embeddings come from.
    pub fn embedding_source_mtime(&self, meeting: &Meeting) -> f64 {
        let dir = self.meeting_dir(meeting);
        ["transcript.json", "summary.md", "notes.md"]
            .iter()
            .filter_map(|f| std::fs::metadata(dir.join(f)).ok()?.modified().ok())
            .map(|m| crate::time::to_epoch(chrono::DateTime::<chrono::Utc>::from(m)))
            .fold(0.0, f64::max)
    }

    /// The chunks to embed for one meeting.
    pub fn meeting_embedding_chunks(&self, meeting: &Meeting) -> Result<Vec<(f64, String)>> {
        let transcript = self.transcript(meeting)?.unwrap_or_default();
        let summary = self.summary(meeting)?;
        let notes = self.notes(meeting)?;
        Ok(embedding_chunks(&transcript, summary.as_deref(), &notes))
    }

    /// Replaces a meeting's vectors (`chunks`: start, text, vector) unless the
    /// meeting was deleted meanwhile or a newer snapshot is already stored.
    pub fn store_meeting_embeddings(
        &self,
        meeting_id: Uuid,
        source_mtime: f64,
        model_id: &str,
        chunks: &[(f64, String, Vec<f32>)],
    ) -> Result<()> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        let id = crate::ids::uuid_upper(&meeting_id);
        let has_notes = chunks
            .iter()
            .any(|(_, text, _)| text.starts_with(NOTES_CHUNK_MARKER));
        self.with_db(|db| {
            let tx = rusqlite::Transaction::new_unchecked(db, rusqlite::TransactionBehavior::Immediate)?;
            let deleted = tx
                .query_row("SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1", [&id], |_| Ok(()))
                .optional()?
                .is_some();
            if deleted {
                return Ok(());
            }
            let indexed: Option<f64> = tx
                .query_row(
                    "SELECT source_mtime FROM embedded_meetings WHERE meeting_id = ?1 AND model_id = ?2",
                    params![id, model_id],
                    |row| row.get(0),
                )
                .optional()?;
            let stored_notes = has_notes_vectors(&tx, &id)?;
            if indexed.is_some_and(|i| i >= source_mtime) && stored_notes == has_notes {
                return Ok(());
            }
            tx.execute("DELETE FROM embeddings WHERE meeting_id = ?1", [&id])?;
            if chunks.is_empty() {
                tx.execute("DELETE FROM embedded_meetings WHERE meeting_id = ?1", [&id])?;
            } else {
                let mut insert =
                    tx.prepare("INSERT INTO embeddings (meeting_id, start, text, vec) VALUES (?1, ?2, ?3, ?4)")?;
                for (start, text, vector) in chunks {
                    insert.execute(params![id, start, text, vector_bytes(vector)])?;
                }
                drop(insert);
                tx.execute(
                    "INSERT OR REPLACE INTO embedded_meetings (meeting_id, source_mtime, model_id) VALUES (?1, ?2, ?3)",
                    params![id, source_mtime, model_id],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// Visible meetings whose vectors for `model_id` are missing or stale
    /// (newer sources, or notes present on only one side).
    pub fn meetings_needing_embeddings(&self, model_id: &str) -> Result<Vec<Meeting>> {
        let mut out = Vec::new();
        for meeting in self.list_meetings()? {
            if !self.meeting_dir(&meeting).is_dir() || meeting.is_live() {
                continue;
            }
            let id = crate::ids::uuid_upper(&meeting.id);
            let mtime = self.embedding_source_mtime(&meeting);
            let has_notes = !self.notes(&meeting)?.trim().is_empty();
            let (deleted, indexed, notes_vectors) = self.with_db(|db| {
                let deleted = db
                    .query_row("SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1", [&id], |_| Ok(()))
                    .optional()?
                    .is_some();
                let indexed: Option<f64> = db
                    .query_row(
                        "SELECT source_mtime FROM embedded_meetings WHERE meeting_id = ?1 AND model_id = ?2",
                        params![id, model_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                Ok((deleted, indexed, has_notes_vectors(db, &id)?))
            })?;
            if deleted {
                continue;
            }
            let notes_changed = has_notes != notes_vectors;
            if (mtime > 0.0 || notes_vectors) && (indexed.unwrap_or(-1.0) < mtime || notes_changed)
            {
                out.push(meeting);
            }
        }
        Ok(out)
    }

    /// Deletes vectors written by any other model (run at startup).
    pub fn purge_embeddings_except(&self, model_id: &str) -> Result<()> {
        if self.is_read_only() {
            bail!("the library is open read-only");
        }
        self.with_db(|db| {
            let tx = db.unchecked_transaction()?;
            tx.execute(
                "DELETE FROM embeddings WHERE meeting_id IN \
                 (SELECT meeting_id FROM embedded_meetings WHERE model_id != ?1)",
                [model_id],
            )?;
            tx.execute(
                "DELETE FROM embedded_meetings WHERE model_id != ?1",
                [model_id],
            )?;
            tx.execute(
                "DELETE FROM screen_embeddings WHERE model_id != ?1",
                [model_id],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    /// Brute-force dot-product search over meeting chunks (vectors are
    /// L2-normalized): `(meeting, start, text, score)` strictly above `floor`,
    /// best first.
    pub fn semantic_search(
        &self,
        query_vec: &[f32],
        limit: usize,
        floor: f32,
    ) -> Result<Vec<(Uuid, f64, String, f32)>> {
        if limit == 0 || query_vec.is_empty() {
            return Ok(Vec::new());
        }
        self.with_db(|db| {
            if !table_exists(db, "embeddings")? {
                return Ok(Vec::new());
            }
            let mut statement = db.prepare(
                "SELECT embedded.meeting_id, embedded.start, embedded.text, embedded.vec FROM embeddings AS embedded \
                 WHERE EXISTS (SELECT 1 FROM embedded_meetings AS indexed WHERE indexed.meeting_id = embedded.meeting_id) \
                 AND NOT EXISTS (SELECT 1 FROM deleted_meetings AS deleted WHERE deleted.meeting_id = embedded.meeting_id)",
            )?;
            let mut rows = statement.query([])?;
            let mut best: Vec<(Uuid, f64, String, f32)> = Vec::new();
            while let Some(row) = rows.next()? {
                let blob: Vec<u8> = row.get(3)?;
                let Some(score) = dot(&blob, query_vec) else { continue };
                if score <= floor {
                    continue;
                }
                let id: String = row.get(0)?;
                let Ok(meeting_id) = Uuid::parse_str(&id) else { continue };
                let hit = (meeting_id, row.get(1)?, row.get(2)?, score);
                if best.len() < limit {
                    best.push(hit);
                } else if let Some((weakest, _)) = best
                    .iter()
                    .enumerate()
                    .min_by(|a, b| a.1.3.partial_cmp(&b.1.3).unwrap_or(std::cmp::Ordering::Equal))
                    && score > best[weakest].3
                {
                    best[weakest] = hit;
                }
            }
            best.sort_by(|a, b| b.3.partial_cmp(&a.3).unwrap_or(std::cmp::Ordering::Equal));
            Ok(best)
        })
    }
}

fn has_notes_vectors(db: &rusqlite::Connection, id: &str) -> Result<bool> {
    Ok(db
        .query_row(
            "SELECT 1 FROM embeddings WHERE meeting_id = ?1 AND substr(text, 1, ?2) = ?3 LIMIT 1",
            params![
                id,
                NOTES_CHUNK_MARKER.chars().count() as i64,
                NOTES_CHUNK_MARKER
            ],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn transcript(lines: &[(&str, &str)]) -> Transcript {
        Transcript {
            segments: lines
                .iter()
                .enumerate()
                .map(|(i, (speaker, text))| Segment {
                    start: i as f64 * 10.0,
                    end: i as f64 * 10.0 + 9.0,
                    speaker: speaker.to_string(),
                    text: text.to_string(),
                    confidence: None,
                    timing_precision: None,
                    attribution: None,
                })
                .collect(),
            ..Default::default()
        }
    }

    #[test]
    fn transcript_chunks_flush_past_the_target() {
        let long = "word ".repeat(60);
        let t = transcript(&[("me", &long), ("them", &long), ("me", "short")]);
        let chunks = embedding_chunks(&t, None, "");
        assert_eq!(chunks.len(), 2);
        assert!(chunks[0].1.starts_with("Me: word"));
        assert_eq!(chunks[1].0, 20.0);
        assert!(
            chunks
                .iter()
                .all(|c| c.1.chars().count() <= TRANSCRIPT_HARD_LIMIT_CHARS)
        );
    }

    #[test]
    fn huge_segments_split_at_whitespace_and_keep_every_character() {
        let huge = "abcdefghij ".repeat(400);
        let t = transcript(&[("them", &huge)]);
        let chunks = embedding_chunks(&t, None, "");
        assert!(chunks.len() > 1);
        assert_eq!(
            chunks.iter().map(|c| c.1.as_str()).collect::<String>(),
            format!("Them: {huge}\n")
        );
        assert!(
            chunks
                .iter()
                .all(|c| c.1.chars().count() <= TRANSCRIPT_TARGET_CHARS)
        );
    }

    #[test]
    fn summary_sections_and_notes() {
        let summary = "# Title\n\n## TL;DR\n- A decision that is long enough to embed here.\n## Key points\nNone";
        let chunks = embedding_chunks(
            &Transcript::default(),
            Some(summary),
            "Remember the softbox",
        );
        assert_eq!(chunks.len(), 2, "{chunks:?}");
        assert!(chunks[0].1.starts_with("TL;DR"));
        assert_eq!(chunks[1].1, "My meeting notes: Remember the softbox");
    }

    #[test]
    fn rrf_prefers_lexical_on_ties() {
        let fused = rrf_fuse(&["a", "b"], &["b", "c"], RRF_K);
        assert_eq!(fused[0].0, "b");
        assert_eq!(fused[1].0, "a");
        assert_eq!(fused[2].0, "c");
    }

    #[test]
    fn stores_and_ranks_vectors() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let meeting = library
            .create_meeting("Sync", "Zoom", crate::time::now_seconds())
            .unwrap();
        let mut ended = meeting.clone();
        ended.ended_at = Some(meeting.started_at + chrono::Duration::minutes(5));
        library.save_meeting(&ended).unwrap();
        library
            .save_summary(
                &ended,
                "## TL;DR\n- Something long enough to be embedded as a section.",
            )
            .unwrap();
        assert_eq!(
            library.meetings_needing_embeddings(MODEL_ID).unwrap().len(),
            1
        );
        let mtime = library.embedding_source_mtime(&ended);
        library
            .store_meeting_embeddings(
                ended.id,
                mtime,
                MODEL_ID,
                &[
                    (0.0, "close".into(), vec![1.0, 0.0]),
                    (5.0, "far".into(), vec![0.0, 1.0]),
                ],
            )
            .unwrap();
        assert!(
            library
                .meetings_needing_embeddings(MODEL_ID)
                .unwrap()
                .is_empty()
        );
        let hits = library
            .semantic_search(&[0.9, 0.1], 5, MEETING_SIMILARITY_FLOOR)
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].2, "close");
        library.save_notes(&ended, "New notes").unwrap();
        assert_eq!(
            library.meetings_needing_embeddings(MODEL_ID).unwrap().len(),
            1
        );
    }
}
