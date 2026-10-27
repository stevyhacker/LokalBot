//! "Search by meaning" for meetings (`Services/EmbeddingIndex.swift`).
//!
//! Chunking, storage and brute-force scoring live in `lokalbot_core::embeddings`;
//! this layer computes the vectors on the local embedder server and fuses
//! semantic with keyword hits.

use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Result;
use uuid::Uuid;

use lokalbot_core::embeddings::{MEETING_SIMILARITY_FLOOR, MODEL_ID, RRF_K, rrf_fuse};
use lokalbot_core::search::{MatchMode, SearchHit, SearchQuery};
use lokalbot_core::{Library, Meeting};

use crate::error::AiError;
use crate::runtime::RuntimeManager;
use crate::think::EmbeddingClient;

/// Embeds one meeting's transcript, summary and notes chunks and stores them.
pub fn index_meeting(runtime: &RuntimeManager, library: &Library, meeting: &Meeting) -> Result<()> {
    index_with(&EmbeddingClient::new(runtime), library, meeting).map(|_| ())
}

/// Like [`index_meeting`] with a given client; returns the chunk count.
pub fn index_with(
    embedder: &EmbeddingClient,
    library: &Library,
    meeting: &Meeting,
) -> Result<usize> {
    let source_mtime = library.embedding_source_mtime(meeting);
    let chunks = library.meeting_embedding_chunks(meeting)?;
    let texts: Vec<String> = chunks.iter().map(|(_, text)| text.clone()).collect();
    let vectors = embedder.embed_documents(&texts)?;
    let rows: Vec<(f64, String, Vec<f32>)> = chunks
        .into_iter()
        .zip(vectors)
        .map(|((start, text), vector)| (start, text, vector))
        .collect();
    library.store_meeting_embeddings(meeting.id, source_mtime, MODEL_ID, &rows)?;
    Ok(rows.len())
}

/// Indexes every meeting whose embeddings are missing or stale, oldest
/// vectors from another model first purged. Returns how many were indexed.
pub fn index_pending(
    runtime: &RuntimeManager,
    library: &Library,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(usize, usize),
) -> Result<usize> {
    library.purge_embeddings_except(MODEL_ID)?;
    let pending = library.meetings_needing_embeddings(MODEL_ID)?;
    if pending.is_empty() {
        return Ok(0);
    }
    let embedder = EmbeddingClient::new(runtime);
    let mut done = 0;
    for (index, meeting) in pending.iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            return Err(AiError::Cancelled.into());
        }
        progress(index, pending.len());
        match index_with(&embedder, library, meeting) {
            Ok(_) => done += 1,
            Err(err) if crate::error::is_cancelled(&err) => return Err(err),
            Err(err) => log::warn!("embedding meeting {} failed: {err:#}", meeting.short_id()),
        }
    }
    progress(pending.len(), pending.len());
    Ok(done)
}

/// One meeting passage related by meaning.
#[derive(Clone, Debug, PartialEq)]
pub struct SemanticHit {
    pub meeting_id: Uuid,
    /// Seconds into the recording (0 for summary and notes chunks).
    pub start: f64,
    pub text: String,
    pub score: f32,
}

/// The best meeting passages for `query` above the meeting similarity floor.
pub fn semantic_meeting_hits(
    embedder: &EmbeddingClient,
    library: &Library,
    query: &str,
    limit: usize,
) -> Result<Vec<SemanticHit>> {
    let query = query.trim();
    if query.is_empty() || limit == 0 {
        return Ok(Vec::new());
    }
    let vector = embedder.embed_query(query)?;
    Ok(library
        .semantic_search(&vector, limit, MEETING_SIMILARITY_FLOOR)?
        .into_iter()
        .map(|(meeting_id, start, text, score)| SemanticHit {
            meeting_id,
            start,
            text,
            score,
        })
        .collect())
}

/// A meeting ranked by keyword and meaning together.
#[derive(Clone, Debug, PartialEq)]
pub struct HybridMeeting {
    pub meeting_id: Uuid,
    /// Reciprocal-rank-fusion score (k = 60).
    pub score: f64,
    pub keyword: Vec<SearchHit>,
    pub semantic: Vec<SemanticHit>,
}

/// Keyword hits (all words, then any word) fused with semantic hits by
/// meeting. Without an embedder this is keyword search alone. Scope filters
/// in `query` apply to both.
pub fn hybrid_search(
    library: &Library,
    embedder: Option<&EmbeddingClient>,
    query: &SearchQuery,
) -> Result<Vec<HybridMeeting>> {
    let mut keyword = library.search(query)?;
    if keyword.is_empty() {
        keyword = library.search_with_mode(query, MatchMode::Any)?;
    }
    let semantic = match embedder {
        Some(embedder) => {
            match semantic_meeting_hits(embedder, library, &query.text, query.limit.max(1) * 3) {
                Ok(hits) => hits,
                Err(err) => {
                    log::warn!("semantic search unavailable: {err:#}");
                    Vec::new()
                }
            }
        }
        None => Vec::new(),
    };
    let allowed = |id: &Uuid| -> bool {
        if let Some(ids) = &query.meeting_ids
            && !ids.contains(id)
        {
            return false;
        }
        true
    };
    let starts: HashMap<Uuid, chrono::DateTime<chrono::Utc>> =
        if query.since.is_some() || query.until.is_some() {
            library
                .list_meetings()?
                .into_iter()
                .map(|m| (m.id, m.started_at))
                .collect()
        } else {
            HashMap::new()
        };
    let in_range = |id: &Uuid| -> bool {
        let Some(start) = starts.get(id) else {
            return query.since.is_none() && query.until.is_none();
        };
        query.since.is_none_or(|s| *start >= s) && query.until.is_none_or(|u| *start < u)
    };
    let semantic: Vec<SemanticHit> = semantic
        .into_iter()
        .filter(|h| allowed(&h.meeting_id) && in_range(&h.meeting_id))
        .collect();
    let mut lexical_order: Vec<Uuid> = Vec::new();
    let mut by_meeting: BTreeMap<Uuid, (Vec<SearchHit>, Vec<SemanticHit>)> = BTreeMap::new();
    for hit in keyword {
        if !lexical_order.contains(&hit.meeting_id) {
            lexical_order.push(hit.meeting_id);
        }
        by_meeting.entry(hit.meeting_id).or_default().0.push(hit);
    }
    let mut semantic_order: Vec<Uuid> = Vec::new();
    for hit in semantic {
        if !semantic_order.contains(&hit.meeting_id) {
            semantic_order.push(hit.meeting_id);
        }
        by_meeting.entry(hit.meeting_id).or_default().1.push(hit);
    }
    let fused = rrf_fuse(&lexical_order, &semantic_order, RRF_K);
    Ok(fused
        .into_iter()
        .take(query.limit.max(1))
        .filter_map(|(meeting_id, score)| {
            let (keyword, semantic) = by_meeting.remove(&meeting_id)?;
            Some(HybridMeeting {
                meeting_id,
                score,
                keyword,
                semantic,
            })
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};
    use serde_json::{Value, json};

    /// A deterministic embedder: one dimension per keyword.
    fn embedder() -> (StubServer, EmbeddingClient) {
        let server = StubServer::start(|request| {
            let inputs = request.json()["input"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let data: Vec<Value> = inputs
                .iter()
                .enumerate()
                .map(|(index, input)| {
                    let text = input.as_str().unwrap_or_default().to_lowercase();
                    let vector: Vec<f64> = ["redis", "cache", "pricing", "sso", "hiring"]
                        .iter()
                        .map(|w| if text.contains(w) { 1.0 } else { 0.0 })
                        .chain([0.05])
                        .collect();
                    json!({"index": index, "embedding": vector})
                })
                .collect();
            Reply::Json(200, json!({"data": data}))
        });
        let client = EmbeddingClient::for_server(&server.url("/v1"), None);
        (server, client)
    }

    #[test]
    fn indexes_meetings_and_finds_them_by_meaning() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let (_server, client) = embedder();
        let meetings = library.list_meetings().unwrap();
        for meeting in &meetings {
            index_with(&client, &library, meeting).unwrap();
        }
        assert!(
            library
                .meetings_needing_embeddings(MODEL_ID)
                .unwrap()
                .is_empty()
        );
        let hits = semantic_meeting_hits(&client, &library, "redis caching", 5).unwrap();
        assert!(!hits.is_empty());
        let title = |id: Uuid| {
            meetings
                .iter()
                .find(|m| m.id == id)
                .map(|m| m.title.clone())
                .unwrap_or_default()
        };
        assert!(
            hits.iter().all(|h| h.text.to_lowercase().contains("redis")
                || h.text.to_lowercase().contains("cache")),
            "{:?}",
            hits.iter().map(|h| title(h.meeting_id)).collect::<Vec<_>>()
        );
        let fused =
            hybrid_search(&library, Some(&client), &SearchQuery::new("Redis cache", 5)).unwrap();
        assert!(!fused.is_empty());
        assert!(fused.windows(2).all(|w| w[0].score >= w[1].score));
        let keyword_only =
            hybrid_search(&library, None, &SearchQuery::new("Northwind SSO", 5)).unwrap();
        assert_eq!(
            title(keyword_only[0].meeting_id),
            "Customer call - Northwind"
        );
    }
}
