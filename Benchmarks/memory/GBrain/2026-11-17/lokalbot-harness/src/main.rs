//! LokalBot side of the GBrain comparison. Drives `lokalbot-core` and
//! `lokalbot-ai` exactly as the Ask pipeline does (`lokalbot-ai/src/ask.rs`,
//! `gather`): keyword search (every word, then any word), meaning search over
//! EmbeddingGemma vectors, reciprocal rank fusion, then the four meetings and
//! six moments per meeting that Ask puts in front of the model.
//!
//!   ingest  <corpus.jsonl> <library>
//!   embed   <library> <embedder base url, e.g. http://127.0.0.1:17873/v1>
//!   query   <library> <queries.jsonl> <out.jsonl> [embedder base url]
//!   delete  <library> <QMSum or pair id>
//!   facts   <facts.json> <out.json>   (Personal Context corrections)

use std::collections::{BTreeSet, HashMap};
use std::io::{BufRead, BufReader, Write};
use std::time::Instant;

use anyhow::{Context, Result, bail};
use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

use lokalbot_ai::embeddings::{index_with, semantic_meeting_hits};
use lokalbot_ai::think::EmbeddingClient;
use lokalbot_core::embeddings::{RRF_K, rrf_fuse};
use lokalbot_core::paths::LibraryPaths;
use lokalbot_core::search::{DocKind, MatchMode, SearchQuery};
use lokalbot_core::{Library, Meeting, Segment, Transcript};

// Ask's limits (`lokalbot-ai/src/ask.rs`).
const KEYWORD_LIMIT: usize = 30;
const SEMANTIC_LIMIT: usize = 15;
const MAX_MEETINGS: usize = 4;
const MAX_MOMENTS_PER_MEETING: usize = 6;
const MOMENT_CHARACTERS: usize = 400;
const TURN_SECONDS: f64 = 10.0;

#[derive(Deserialize)]
struct Turn {
    speaker: String,
    text: String,
}

#[derive(Deserialize)]
struct CorpusMeeting {
    id: String,
    title: String,
    started_at: DateTime<Utc>,
    turns: Vec<Turn>,
}

#[derive(Deserialize)]
struct Query {
    id: String,
    question: String,
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("ingest") if args.len() == 4 => ingest(&args[2], &args[3]),
        Some("embed") if args.len() == 4 => embed(&args[2], &args[3]),
        Some("query") if args.len() >= 5 => query(&args[2], &args[3], &args[4], args.get(5)),
        Some("delete") if args.len() == 4 => delete(&args[2], &args[3]),
        Some("facts") if args.len() == 4 => facts(&args[2], &args[3]),
        _ => bail!("usage: ingest <corpus> <library> | embed <library> <url> | query <library> <queries> <out> [url]"),
    }
}

fn open(root: &str) -> Result<Library> {
    Library::open(LibraryPaths::new(root))
}

fn ingest(corpus: &str, root: &str) -> Result<()> {
    let library = open(root)?;
    let started = Instant::now();
    let mut count = 0;
    for line in BufReader::new(std::fs::File::open(corpus)?).lines() {
        let m: CorpusMeeting = serde_json::from_str(&line?)?;
        let mut meeting = library.create_meeting(&m.title, "Imported file", m.started_at)?;
        let segments: Vec<Segment> = m
            .turns
            .iter()
            .enumerate()
            .map(|(i, t)| Segment {
                start: i as f64 * TURN_SECONDS,
                end: i as f64 * TURN_SECONDS + TURN_SECONDS - 1.0,
                speaker: t.speaker.clone(),
                text: t.text.clone(),
                confidence: None,
                timing_precision: None,
                attribution: None,
            })
            .collect();
        meeting.ended_at = Some(m.started_at + Duration::seconds((segments.len() as f64 * TURN_SECONDS) as i64));
        library.save_meeting(&meeting)?;
        library.save_transcript(&meeting, &Transcript { segments, ..Default::default() })?;
        count += 1;
        let _ = m.id;
    }
    let written = started.elapsed().as_secs_f64();
    let indexed = library.reindex_stale()?;
    eprintln!("{count} meetings written in {written:.1}s; {indexed} indexed in {:.1}s total", started.elapsed().as_secs_f64());
    Ok(())
}

fn embed(root: &str, url: &str) -> Result<()> {
    let library = open(root)?;
    let client = EmbeddingClient::for_server(url, None);
    let started = Instant::now();
    let meetings = library.list_meetings()?;
    let mut chunks = 0;
    for (n, meeting) in meetings.iter().enumerate() {
        chunks += index_with(&client, &library, meeting).with_context(|| meeting.title.clone())?;
        if n % 20 == 0 {
            eprintln!("{n}/{} meetings, {chunks} chunks, {:.0}s", meetings.len(), started.elapsed().as_secs_f64());
        }
    }
    eprintln!("embedded {chunks} chunks from {} meetings in {:.1}s", meetings.len(), started.elapsed().as_secs_f64());
    Ok(())
}

fn qmsum_id(meeting: &Meeting) -> String {
    meeting.title.trim_start_matches("Meeting ").to_string()
}

fn turn(start: f64) -> usize {
    (start / TURN_SECONDS).round().max(0.0) as usize
}

fn query(root: &str, queries: &str, out: &str, url: Option<&String>) -> Result<()> {
    let library = open(root)?;
    let embedder = url.map(|u| EmbeddingClient::for_server(u, None));
    let meetings = library.list_meetings()?;
    let by_id: HashMap<Uuid, &Meeting> = meetings.iter().map(|m| (m.id, m)).collect();
    let mut transcripts: HashMap<Uuid, Transcript> = HashMap::new();
    for m in &meetings {
        if let Some(t) = library.transcript(m)? {
            transcripts.insert(m.id, t);
        }
    }
    let mut writer = std::io::BufWriter::new(std::fs::File::create(out)?);
    for line in BufReader::new(std::fs::File::open(queries)?).lines() {
        let q: Query = serde_json::from_str(&line?)?;
        let started = Instant::now();
        // --- Ask's gather(), meeting part, with an unscoped question.
        let search = SearchQuery { text: q.question.clone(), kinds: None, meeting_ids: None, since: None, until: None, limit: KEYWORD_LIMIT };
        let mut keyword = library.search(&search)?;
        if keyword.is_empty() {
            keyword = library.search_with_mode(&search, MatchMode::Any)?;
        }
        let keyword_ms = started.elapsed().as_secs_f64() * 1000.0;
        let semantic = match &embedder {
            Some(e) => semantic_meeting_hits(e, &library, &q.question, SEMANTIC_LIMIT)?,
            None => Vec::new(),
        };
        let lowered = q.question.to_lowercase();
        let first: Vec<Uuid> = meetings
            .iter()
            .filter(|m| m.title.trim().chars().count() >= 4 && lowered.contains(&m.title.trim().to_lowercase()))
            .map(|m| m.id)
            .collect();
        let mut lexical: Vec<Uuid> = Vec::new();
        for hit in &keyword {
            if !lexical.contains(&hit.meeting_id) {
                lexical.push(hit.meeting_id);
            }
        }
        let mut meaning: Vec<Uuid> = Vec::new();
        for hit in &semantic {
            if !meaning.contains(&hit.meeting_id) {
                meaning.push(hit.meeting_id);
            }
        }
        let mut ranked: Vec<Uuid> = Vec::new();
        for id in first.into_iter().chain(rrf_fuse(&lexical, &meaning, RRF_K).into_iter().map(|(id, _)| id)) {
            if !ranked.contains(&id) {
                ranked.push(id);
            }
        }
        let mut evidence = Vec::new();
        for id in ranked.iter().take(MAX_MEETINGS) {
            let Some(transcript) = transcripts.get(id) else { continue };
            let mut starts: Vec<f64> = keyword
                .iter()
                .filter(|h| h.meeting_id == *id && h.kind == DocKind::Segment)
                .filter_map(|h| h.start)
                .chain(semantic.iter().filter(|h| h.meeting_id == *id && h.start > 0.0).map(|h| h.start))
                .collect();
            starts.dedup();
            let mut rows: BTreeSet<usize> = BTreeSet::new();
            for start in starts {
                let index = turn(start).min(transcript.segments.len().saturating_sub(1));
                rows.insert(index);
                if index + 1 < transcript.segments.len() {
                    rows.insert(index + 1);
                }
                if rows.len() >= MAX_MOMENTS_PER_MEETING {
                    break;
                }
            }
            for index in rows.into_iter().take(MAX_MOMENTS_PER_MEETING) {
                let text = &transcript.segments[index].text;
                let chars = text.chars().count().min(MOMENT_CHARACTERS);
                evidence.push(json!({"meeting": qmsum_id(by_id[id]), "turns": [index], "chars": chars}));
            }
        }
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        // Passage pointers in the order retrieval ranked them: keyword rows, then meaning chunks.
        let pointers: Vec<_> = keyword
            .iter()
            .filter(|h| h.kind == DocKind::Segment)
            .filter_map(|h| h.start.map(|s| json!({"meeting": qmsum_id(by_id[&h.meeting_id]), "turn": turn(s)})))
            .chain(semantic.iter().map(|h| json!({"meeting": qmsum_id(by_id[&h.meeting_id]), "turn": turn(h.start), "chars": h.text.chars().count()})))
            .collect();
        let row = json!({
            "id": q.id,
            "ms": ms,
            "keyword_ms": keyword_ms,
            "meetings": ranked.iter().take(20).map(|id| qmsum_id(by_id[id])).collect::<Vec<_>>(),
            "evidence": evidence,
            "pointers": pointers,
        });
        writeln!(writer, "{row}")?;
    }
    writer.flush()?;
    Ok(())
}

fn delete(root: &str, id: &str) -> Result<()> {
    let library = open(root)?;
    let meeting = library
        .list_meetings()?
        .into_iter()
        .find(|m| qmsum_id(m) == id)
        .with_context(|| format!("no meeting {id}"))?;
    let started = Instant::now();
    library.delete_meeting(&meeting)?;
    library.reindex_stale()?;
    eprintln!("deleted {id} in {:.1} ms", started.elapsed().as_secs_f64() * 1000.0);
    Ok(())
}

#[derive(Deserialize)]
struct FactCase {
    entity: String,
    original: String,
    correction: String,
    question: String,
    current: String,
    stale: String,
}

#[derive(Deserialize)]
struct FactSuite {
    facts: Vec<FactCase>,
    distractors: Vec<String>,
}

/// Each correction mode on a fresh personal model: the facts and distractors
/// are stated a day apart from their corrections, then every question gets
/// Ask's Personal Context block (`select_context`, 2,000 characters).
fn facts(input: &str, out: &str) -> Result<()> {
    use lokalbot_core::personal::{CONTEXT_BUDGET, ClaimEdit, ClaimKind, Origin, PersonalModel, select_context};
    let suite: FactSuite = serde_json::from_str(&std::fs::read_to_string(input)?)?;
    let base: DateTime<Utc> = "2026-11-01T09:00:00Z".parse()?;
    let mut results = Vec::new();
    for mode in ["edit", "restate", "forget"] {
        let mut model = PersonalModel::default();
        let mut clock = base;
        let mut tick = || {
            clock += Duration::minutes(1);
            clock
        };
        for text in &suite.distractors {
            model.add(text, ClaimKind::Fact, Origin::Added {}, tick()).map_err(|e| anyhow::anyhow!(e.message()))?;
        }
        let mut originals = Vec::new();
        for case in &suite.facts {
            let claim = model.add(&case.original, ClaimKind::suggested(&case.original), Origin::Added {}, tick())
                .map_err(|e| anyhow::anyhow!(e.message()))?;
            originals.push(claim.id);
        }
        let mut clock2 = base + Duration::days(1);
        let started = Instant::now();
        for (case, id) in suite.facts.iter().zip(&originals) {
            clock2 += Duration::minutes(1);
            match mode {
                "edit" => {
                    let edit = ClaimEdit { text: Some(case.correction.clone()), kind: None, always_use: None, sharing: None };
                    model.update(*id, edit, clock2).map_err(|e| anyhow::anyhow!(e.message()))?;
                }
                "restate" => {
                    model.add(&case.correction, ClaimKind::suggested(&case.correction), Origin::Added {}, clock2)
                        .map_err(|e| anyhow::anyhow!(e.message()))?;
                }
                _ => model.remove(&std::iter::once(*id).collect(), clock2),
            }
        }
        let write_ms = started.elapsed().as_secs_f64() * 1000.0 / suite.facts.len() as f64;
        for case in &suite.facts {
            let started = Instant::now();
            let selection = select_context(&model.claims, &case.question, &[], CONTEXT_BUDGET);
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            let block = selection.block;
            let current = block.find(&case.current);
            let stale = block.find(&case.stale);
            results.push(json!({
                "mode": mode,
                "entity": case.entity,
                "current_present": current.is_some(),
                "stale_present": stale.is_some(),
                "current_first": match (current, stale) { (Some(c), Some(s)) => Some(c < s), _ => None },
                "items": selection.claim_ids.len(),
                "chars": block.chars().count(),
                "read_ms": ms,
                "write_ms": write_ms,
            }));
        }
    }
    std::fs::write(out, serde_json::to_string_pretty(&results)?)?;
    Ok(())
}
