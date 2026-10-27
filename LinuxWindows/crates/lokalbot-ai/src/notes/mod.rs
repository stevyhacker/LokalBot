//! Meeting notes (`MeetingNotesGenerator.swift`, `MeetingNotesRecovery.swift`).
//!
//! One extraction pass per transcript part yields notes, actions, decisions
//! and open questions. The model cites only `s#` row IDs; the app maps them
//! to stable segment IDs, checks every record against the cited speech,
//! repairs rejected records once or twice, and renders the Markdown itself.

pub mod budget;
pub mod evidence;
pub mod ownership;
pub mod render;
pub mod view;

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use anyhow::Result;
use chrono::Local;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use lokalbot_core::model::{ActionItem, Meeting, MeetingOutcomes, Transcript};
use lokalbot_core::settings::{NoteTemplate, Settings};

use crate::error::AiError;
use crate::think::{ChatRequest, ThinkClient};
use crate::{json as model_json, language, prompts, sanitize};

use budget::{Budget, Limits};
use evidence::{Claim, Evidence, Record, Rejection, Unit, Validated};
use view::View;

/// Notes for one meeting, ready to write.
#[derive(Clone, Debug, PartialEq)]
pub struct MeetingNotes {
    /// `summary.md`: the header line, then the rendered sections.
    pub summary_markdown: String,
    pub outcomes: MeetingOutcomes,
    /// `summary-claims.json`: `{version, transcriptRevision, claims}`.
    pub claims: Value,
}

/// Some parts could not be completed; partial files were saved when a
/// checkpoint folder was given.
#[derive(Debug, thiserror::Error)]
#[error(
    "Partial notes saved ({completed} of {total} parts source-linked). Summarize again to continue."
)]
pub struct Incomplete {
    pub completed: usize,
    pub total: usize,
}

#[derive(Clone, Default)]
pub struct NotesOptions {
    /// The meeting folder: checkpoints after every part (`notes.parts.partial.json`)
    /// and the partial files the UI can show. `None` keeps everything in memory.
    pub checkpoint_dir: Option<PathBuf>,
    /// A person asked again: parts an earlier run stopped get another scan.
    pub retrying_stopped_parts: bool,
    pub cancel: Option<Arc<AtomicBool>>,
    /// Titles of documents on screen during the meeting (context only).
    pub screen_titles: Vec<String>,
}

pub const CHECKPOINT_FILE: &str = "notes.parts.partial.json";
const PARTIAL_FILES: [&str; 5] = [
    CHECKPOINT_FILE,
    "summary.partial.md",
    "outcomes.partial.json",
    "summary.claims.partial.json",
    "notes.partial.json",
];

/// Removes the checkpoint and partial files after the final notes are saved.
pub fn remove_checkpoint(folder: &Path) {
    for name in PARTIAL_FILES {
        let _ = std::fs::remove_file(folder.join(name));
    }
}

/// Generates notes with default options (no checkpoint folder).
pub fn generate_meeting_notes(
    think: &ThinkClient,
    meeting: &Meeting,
    transcript: &Transcript,
    user_notes: &str,
    settings: &Settings,
    progress: &mut dyn FnMut(&str),
) -> Result<MeetingNotes> {
    generate_meeting_notes_with(
        think,
        meeting,
        transcript,
        user_notes,
        settings,
        &NotesOptions::default(),
        progress,
    )
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Recovery {
    next_page: usize,
    scan_complete: bool,
    records: Vec<Record>,
    pending: Vec<Rejection>,
    repair_token_floor: Option<u32>,
    terminal_failure: Option<String>,
    no_progress_attempts: Option<u32>,
    settled_ownership: Option<Vec<String>>,
    answered_commitments: Option<Vec<String>>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct Part {
    claims: Vec<Claim>,
    outcomes: MeetingOutcomes,
    complete: bool,
    recovery: Option<Recovery>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Checkpoint {
    version: u32,
    fingerprint: String,
    parts: BTreeMap<String, Part>,
}

struct Job<'e, 'a> {
    evidence: &'e Evidence<'a>,
    units: &'e [Unit],
    think: &'e ThinkClient,
    template: NoteTemplate,
    language: Option<String>,
    context: &'e [String],
    context_tokens: u32,
    number: usize,
    remaining_parts: usize,
    output_scale: f64,
    retrying_stopped: bool,
    cancel: Option<&'e AtomicBool>,
}

fn cancelled(cancel: Option<&AtomicBool>) -> Result<()> {
    cancel.map_or(Ok(()), crate::error::check_cancelled)
}

/// The generator with explicit options.
pub fn generate_meeting_notes_with(
    think: &ThinkClient,
    meeting: &Meeting,
    transcript: &Transcript,
    user_notes: &str,
    settings: &Settings,
    options: &NotesOptions,
    progress: &mut dyn FnMut(&str),
) -> Result<MeetingNotes> {
    let cancel = options.cancel.as_deref();
    let _hold = think.hold()?;
    let template = settings.note_template;
    let language = language::prompt_language(&settings.summary_language, transcript);
    let evidence = Evidence::new(
        View::new(transcript, settings.microphone_is_user),
        meeting.id,
        language::is_mostly_english(transcript),
    );
    let system =
        prompts::meeting_notes_system(template, language.as_deref(), &evidence::sections(template));
    let repair_system = prompts::meeting_notes_repair_system(language.as_deref());
    let context = context_items(meeting, user_notes, &options.screen_titles, settings);
    let context_tokens = think.context_tokens();
    let mut limits = Limits::for_preset(settings.generation_budget_preset);
    // The time allowance assumes GPU decoding; a CPU-only PC gets three times as long.
    if think.runs_on_cpu() {
        limits.seconds *= 3.0;
    }
    let mut budget = Budget::new(limits);

    progress("Planning the notes…");
    let chunks = make_chunks(
        &evidence,
        think,
        &system,
        &context,
        context_tokens,
        template,
        cancel,
    )?;
    let fixed = format!(
        "{}\n\n",
        std::iter::once(system.clone())
            .chain(context.iter().cloned())
            .collect::<Vec<_>>()
            .join("\n\n")
    );
    let mut scales = Vec::with_capacity(chunks.len());
    for chunk in &chunks {
        let size = prompt_size(think, &format!("{fixed}{}", evidence.prompt(chunk)))?;
        scales.push((size.planning as f64 / STANDARD_PART_TOKENS as f64).max(1.0));
    }
    budget.record_plan(chunks.len(), scales.iter().sum());
    let revision = view::evidence_revision(transcript);
    let fingerprint = {
        let mut parts = vec![
            "notes-v1".to_string(),
            evidence::OWNERSHIP_POLICY_VERSION.into(),
            revision.clone(),
            think.checkpoint_identity(),
            system.clone(),
            repair_system.clone(),
        ];
        parts.extend(context.iter().cloned());
        parts.extend(chunks.iter().map(|c| evidence.prompt(c)));
        lokalbot_core::library::sha256_hex(parts.join("\n\n").as_bytes())
    };
    let mut checkpoint = options
        .checkpoint_dir
        .as_ref()
        .and_then(|dir| std::fs::read(dir.join(CHECKPOINT_FILE)).ok())
        .and_then(|bytes| serde_json::from_slice::<Checkpoint>(&bytes).ok())
        .filter(|c| c.version == 2 && c.fingerprint == fingerprint)
        .unwrap_or(Checkpoint {
            version: 2,
            fingerprint,
            parts: BTreeMap::new(),
        });

    for (index, chunk) in chunks.iter().enumerate() {
        cancelled(cancel)?;
        let key = index.to_string();
        if checkpoint.parts.get(&key).is_some_and(|p| p.complete) {
            continue;
        }
        if chunks.len() > 1 {
            progress(&format!(
                "Writing notes · part {} of {}",
                index + 1,
                chunks.len()
            ));
        } else {
            progress("Writing notes…");
        }
        let job = Job {
            evidence: &evidence,
            units: chunk,
            think,
            template,
            language: language.clone(),
            context: &context,
            context_tokens,
            number: index + 1,
            remaining_parts: chunks.len() - index,
            output_scale: scales[index],
            retrying_stopped: options.retrying_stopped_parts,
            cancel,
        };
        let initial = checkpoint.parts.get(&key).cloned().unwrap_or_default();
        generate_part(initial, &job, &mut budget, &mut |part: &Part| {
            checkpoint.parts.insert(key.clone(), part.clone());
            if let Some(dir) = &options.checkpoint_dir {
                save_checkpoint(
                    dir,
                    &checkpoint,
                    &evidence,
                    template,
                    chunks.len(),
                    &revision,
                );
            }
        })?;
    }
    let completed = checkpoint.parts.values().filter(|p| p.complete).count();
    if completed != chunks.len() {
        return Err(Incomplete {
            completed,
            total: chunks.len(),
        }
        .into());
    }
    let (claims, outcomes, body) = merged(&checkpoint, &evidence, template, &revision);
    let header = header(meeting, transcript, settings, language.as_deref(), think);
    let claims_value = json!({"version": 1, "transcriptRevision": revision, "claims": claims});
    if let Some(dir) = &options.checkpoint_dir {
        remove_checkpoint(dir);
    }
    progress("Notes ready");
    Ok(MeetingNotes {
        summary_markdown: format!("{header}{body}"),
        outcomes,
        claims: claims_value,
    })
}

/// `# {title} — {date}` and the provenance line (`ProcessingPipeline.summarize`).
fn header(
    meeting: &Meeting,
    transcript: &Transcript,
    settings: &Settings,
    language: Option<&str>,
    think: &ThinkClient,
) -> String {
    let started = meeting.started_at.with_timezone(&Local);
    let date = started.format("%B %-d, %Y at %-I:%M %p");
    let duration = meeting.recorded_duration.or_else(|| {
        meeting
            .ended_at
            .map(|end| (end - meeting.started_at).num_milliseconds() as f64 / 1000.0)
    });
    let duration = match duration {
        None => "in progress".to_string(),
        Some(seconds) => {
            let minutes = (seconds.max(0.0) as u64) / 60;
            if minutes >= 60 {
                format!("{}h {}m", minutes / 60, minutes % 60)
            } else {
                format!("{minutes} min")
            }
        }
    };
    let words = transcript.word_count();
    let words = format!(
        "{} {}",
        grouped(words),
        if words == 1 { "word" } else { "words" }
    );
    let mut line = format!(
        "**Duration:** {duration} · **App:** {} · **Words:** {words} · **Template:** {}",
        meeting.app_name,
        settings.note_template.label()
    );
    if let Some(language) = language {
        line.push_str(&format!(" · **Language:** {language}"));
    }
    line.push_str(&format!(" · **Model:** {}", think.display_name()));
    format!("# {} — {date}\n{line}\n\n", meeting.title)
}

fn grouped(count: usize) -> String {
    let digits = count.to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// User notes, then the secondary meeting-context block (≤2,400 characters,
/// `MeetingGenerationContext`): the calendar title and invited names when
/// `meetingNotesUseCalendarContext` is on, the saved agenda when
/// `useCalendarAgenda` is on, and on-screen document titles.
fn context_items(
    meeting: &Meeting,
    user_notes: &str,
    screen_titles: &[String],
    settings: &Settings,
) -> Vec<String> {
    let mut items = Vec::new();
    if !user_notes.trim().is_empty() {
        items.push(prompts::user_notes_context(user_notes.trim()));
    }
    let mut lines = Vec::new();
    if settings.meeting_notes_use_calendar_context {
        calendar_lines(meeting, &mut lines);
    }
    if settings.use_calendar_agenda
        && let Some(agenda) =
            lokalbot_core::calendar::sanitize_agenda(meeting.calendar_agenda.as_deref())
    {
        lines.push(format!("Agenda from the calendar invitation:\n{agenda}"));
    }
    let titles: Vec<String> = screen_titles
        .iter()
        .take(8)
        .map(|t| sanitize::collapse(t))
        .filter(|t| !t.is_empty())
        .collect();
    if !titles.is_empty() {
        lines.push(format!(
            "Documents and pages on the user's screen during the meeting (titles only): {}",
            titles.join("; ")
        ));
    }
    if !lines.is_empty() {
        items.push(format!(
            "{}\n{}",
            prompts::MEETING_CONTEXT_HEADER,
            sanitize::sanitize(&lines.join("\n"), Some(2_400))
        ));
    }
    items
}

/// The scheduled title and invited names; never email addresses.
fn calendar_lines(meeting: &Meeting, lines: &mut Vec<String>) {
    if let Some(title) = meeting
        .calendar_title
        .as_deref()
        .map(sanitize::collapse)
        .filter(|t| !t.is_empty())
    {
        lines.push(format!("Scheduled title: {title}"));
    }
    let names: Vec<String> = meeting
        .calendar_participant_identities
        .iter()
        .flatten()
        .filter_map(|p| {
            p.name
                .as_deref()
                .map(sanitize::collapse)
                .filter(|n| !n.is_empty())
        })
        .chain(
            meeting
                .participant_name_hints
                .iter()
                .flatten()
                .map(|n| sanitize::collapse(n))
                .filter(|n| !n.is_empty()),
        )
        .collect::<Vec<_>>();
    let mut seen = HashSet::new();
    let names: Vec<String> = names
        .into_iter()
        .filter(|n| seen.insert(n.to_lowercase()))
        .take(20)
        .collect();
    if !names.is_empty() {
        lines.push(format!(
            "Invited participants (names from the calendar; they may not all have spoken): {}",
            names.join(", ")
        ));
    }
}

// ------------------------------------------------------------------ sizing

const STANDARD_PART_TOKENS: u32 = 6_000;
const ENVELOPE_TOKENS: u32 = 1_536;

fn notes_part_tokens(context_tokens: u32) -> u32 {
    match context_tokens {
        128_000.. => 24_000,
        64_000.. => 16_000,
        _ => STANDARD_PART_TOKENS,
    }
}

struct PromptSize {
    upper: u32,
    planning: u32,
}

/// Native tokens when the server can count them; otherwise UTF-8 bytes bound
/// the context and bytes/3 plans part sizes.
fn prompt_size(think: &ThinkClient, text: &str) -> Result<PromptSize> {
    let native = think.token_count(text)?.map(|n| n as u32);
    let bytes = text.len() as u32;
    Ok(PromptSize {
        upper: native.unwrap_or(bytes).max(1),
        planning: native.unwrap_or(bytes.div_ceil(3)).max(1),
    })
}

fn token_count(think: &ThinkClient, text: &str) -> Result<u32> {
    Ok(prompt_size(think, text)?.upper)
}

/// Parts fit the context, the planning step, and a hosted server's limit on
/// schema enum values; neighbours overlap by two rows.
fn make_chunks(
    evidence: &Evidence,
    think: &ThinkClient,
    system: &str,
    context: &[String],
    context_tokens: u32,
    template: NoteTemplate,
    cancel: Option<&AtomicBool>,
) -> Result<Vec<Vec<Unit>>> {
    let units = &evidence.units;
    if units.is_empty() {
        return Ok(Vec::new());
    }
    let context_ceiling = context_tokens.saturating_sub(4_096 + ENVELOPE_TOKENS);
    let planning_ceiling = notes_part_tokens(context_tokens).min(context_ceiling);
    let fixed = format!(
        "{}\n\n",
        std::iter::once(system.to_string())
            .chain(context.iter().cloned())
            .collect::<Vec<_>>()
            .join("\n\n")
    );
    let enum_limit = think.structured_output_enum_limit();
    let mut chunks = Vec::new();
    let mut start = 0;
    while start < units.len() {
        cancelled(cancel)?;
        let mut end = units.len();
        loop {
            let slice = &units[start..end];
            let size = prompt_size(think, &format!("{fixed}{}", evidence.prompt(slice)))?;
            let enums = enum_limit
                .map(|_| evidence::enum_value_count(&evidence.schema(slice, template, 1, 1, None)))
                .unwrap_or(0);
            if size.upper <= context_ceiling
                && size.planning <= planning_ceiling
                && enum_limit.is_none_or(|l| enums <= l)
            {
                chunks.push(slice.to_vec());
                break;
            }
            if end <= start + 1 {
                return Err(AiError::BadResponse(
                    "meeting context cannot fit the model's input allowance".into(),
                )
                .into());
            }
            let mut ratio = (context_ceiling.max(1) as f64 / size.upper as f64)
                .min(planning_ceiling.max(1) as f64 / size.planning as f64);
            if let Some(limit) = enum_limit {
                ratio = ratio.min(limit as f64 / enums.max(1) as f64);
            }
            let fraction = (ratio * 0.9).clamp(0.1, 0.9);
            end = start + (((end - start) as f64 * fraction) as usize).max(1);
        }
        if end == units.len() {
            break;
        }
        start = (start + 1).max(end.saturating_sub(2));
    }
    Ok(chunks)
}

// ----------------------------------------------------------------- requests

fn expanded_tokens(tokens: u32, input: u32, context_tokens: u32) -> Option<u32> {
    let available = context_tokens.checked_sub(input)?;
    (tokens > 0 && available > tokens).then(|| available.min(16_384.min((tokens * 2).max(8_192))))
}

fn record_count(text: &str) -> usize {
    model_json::complete_records(text, &["notes", "actions"])
        .arrays
        .values()
        .map(Vec::len)
        .sum()
}

/// One structured call. A reply cut off at its limit gets one larger retry
/// (not for repairs); whichever holds more complete records is kept.
#[allow(clippy::too_many_arguments)]
fn request(
    think: &ThinkClient,
    budget: &mut Budget,
    system: &str,
    prompt: &str,
    context: &[String],
    schema: Value,
    tokens: u32,
    stage: &str,
    context_tokens: u32,
    truncation_retry: bool,
) -> Result<(String, bool)> {
    let joined = std::iter::once(system.to_string())
        .chain(context.iter().cloned())
        .chain(std::iter::once(prompt.to_string()))
        .collect::<Vec<_>>()
        .join("\n\n");
    let input = token_count(think, &joined)? + ENVELOPE_TOKENS;
    if input + tokens > context_tokens {
        return Err(AiError::BadResponse("Notes request cannot fit the model's input allowance. Source-linked progress was saved.".into()).into());
    }
    budget.reserve(u64::from(input), u64::from(tokens))?;
    // The transcript travels as context, so a server with prompt caching
    // (Anthropic) reuses it across this meeting's requests; every other
    // server gets it joined in front of the instruction as before.
    let request = ChatRequest::new(system, prompt)
        .context(context.to_vec())
        .max_tokens(tokens)
        .reasoning_budget(0)
        .temperature(0.0)
        .json_schema(schema.clone());
    let completion = match think.complete_full(&request) {
        Ok(completion) => completion,
        Err(err) => {
            budget.finish(u64::from(tokens), None);
            return Err(err);
        }
    };
    budget.finish(
        u64::from(tokens),
        completion.usage.as_ref().and_then(|u| u.completion_tokens),
    );
    log::info!(
        "notes {stage}: {} chars, truncated={}",
        completion.text.len(),
        completion.truncated
    );
    if !completion.truncated {
        return Ok((completion.text, false));
    }
    if !stage.contains("repair")
        && !truncation_retry
        && let Some(expanded) = expanded_tokens(tokens, input, context_tokens)
        && expanded > tokens
    {
        match self::request(
            think,
            budget,
            system,
            prompt,
            context,
            schema,
            expanded,
            &format!("expanded-{stage}"),
            context_tokens,
            true,
        ) {
            Ok((text, true))
                if record_count(&completion.text) >= record_count(&text)
                    && !completion.text.is_empty() =>
            {
                return Ok((completion.text, true));
            }
            Ok(result) => return Ok(result),
            Err(err) if crate::error::is_cancelled(&err) => return Err(err),
            Err(_) => return Ok((completion.text, true)),
        }
    }
    Ok((completion.text, true))
}

// -------------------------------------------------------------------- parts

fn same_task(lhs: &ActionItem, rhs: &ActionItem) -> bool {
    evidence::similarity_normalized(&lhs.text) == evidence::similarity_normalized(&rhs.text)
        && lhs
            .citations
            .iter()
            .any(|c| rhs.citations.iter().any(|d| d.segment_id == c.segment_id))
}

fn accept(part: &mut Part, recovery: &mut Recovery, value: &Validated) {
    let mut claims = std::mem::take(&mut part.claims);
    claims.extend(value.claims.iter().cloned());
    part.claims = render::distinct_claims(claims);
    let pending_ids: HashSet<String> = recovery
        .pending
        .iter()
        .filter_map(|r| r.action_id.clone())
        .collect();
    let mut held: Vec<ActionItem> = part
        .outcomes
        .action_items
        .iter()
        .filter(|a| pending_ids.contains(&a.id))
        .cloned()
        .collect();
    let mut previous = part.outcomes.clone();
    previous
        .action_items
        .retain(|a| !pending_ids.contains(&a.id));
    let new_pending: HashSet<String> = value
        .rejected
        .iter()
        .filter_map(|r| r.action_id.clone())
        .collect();
    let mut incoming = value.outcomes.clone();
    incoming
        .action_items
        .retain(|a| !new_pending.contains(&a.id));
    for action in &incoming.action_items {
        let replaced: HashSet<String> = held
            .iter()
            .filter(|h| same_task(h, action))
            .map(|h| h.id.clone())
            .collect();
        held.retain(|h| !replaced.contains(&h.id));
        recovery
            .pending
            .retain(|r| r.action_id.as_ref().is_none_or(|id| !replaced.contains(id)));
    }
    for rejection in &value.rejected {
        let Some(action_id) = &rejection.action_id else {
            continue;
        };
        let Some(action) = value
            .outcomes
            .action_items
            .iter()
            .find(|a| &a.id == action_id)
        else {
            continue;
        };
        if held.iter().any(|h| same_task(h, action)) {
            continue;
        }
        held.push(action.clone());
        recovery.pending.push(rejection.clone());
    }
    part.outcomes = render::merge_outcomes(&[previous, incoming]);
    part.outcomes.action_items.extend(held);
    let mut seen: HashSet<String> = recovery.records.iter().map(Record::key).collect();
    for record in &value.records {
        if seen.insert(record.key()) {
            recovery.records.push(record.clone());
        }
    }
}

/// The output room beside this request's input, or `None` when even the
/// structured-output minimum cannot fit.
fn output_room(
    job: &Job,
    system: &str,
    prompt: &str,
    context: &[String],
    tokens: u32,
) -> Result<Option<u32>> {
    let joined = std::iter::once(system.to_string())
        .chain(context.iter().cloned())
        .chain(std::iter::once(prompt.to_string()))
        .collect::<Vec<_>>()
        .join("\n\n");
    let input = token_count(job.think, &joined)?;
    let room = tokens.min(job.context_tokens.saturating_sub(input + ENVELOPE_TOKENS));
    Ok((room >= 512.max(job.think.minimum_structured_output_tokens())).then_some(room))
}

fn input_room_exceeded() -> anyhow::Error {
    AiError::BadResponse("Notes continuation cannot fit the model's input allowance. Source-linked progress was saved.".into()).into()
}

fn continuation(records: &[Record], omitted: usize) -> String {
    let ledger: Vec<Value> = records
        .iter()
        .map(|r| json!({"kind": r.kind, "source": r.source, "text": r.text}))
        .collect();
    prompts::notes_continuation(&Value::Array(ledger).to_string(), omitted)
}

/// A continuation's ledger comes out of the output allowance; a long one
/// keeps its newest records.
fn fitted_page(
    job: &Job,
    rows: &str,
    suffix: &str,
    ledger: Option<&[Record]>,
    system: &str,
    allowance: u32,
) -> Result<(String, u32)> {
    let mut kept = ledger.map_or(0, <[Record]>::len);
    loop {
        let ledger_text = ledger
            .map(|l| continuation(&l[l.len() - kept..], l.len() - kept))
            .unwrap_or_default();
        let page = format!("{rows}{ledger_text}{suffix}");
        if let Some(room) = output_room(job, system, &page, job.context, allowance)? {
            return Ok((page, room));
        }
        if kept == 0 {
            return Err(input_room_exceeded());
        }
        kept /= 2;
    }
}

fn repair_batch(rejected: &[Rejection], units: &[Unit]) -> Vec<Rejection> {
    let sources: HashSet<&str> = units.iter().map(|u| u.source.as_str()).collect();
    let known: Vec<&Rejection> = rejected
        .iter()
        .filter(|r| r.sources.iter().any(|s| sources.contains(s.as_str())))
        .collect();
    let ownership: Vec<Rejection> = known
        .iter()
        .filter(|r| r.action_id.is_some())
        .take(10)
        .map(|r| (*r).clone())
        .collect();
    if !ownership.is_empty() {
        return ownership;
    }
    let mut batch: Vec<Rejection> = known
        .iter()
        .filter(|r| r.kind == "notes")
        .take(12)
        .map(|r| (*r).clone())
        .collect();
    batch.extend(
        known
            .iter()
            .filter(|r| r.kind == "actions")
            .take(10)
            .map(|r| (*r).clone()),
    );
    batch
}

/// ±2 rows around a rejected note, ±8 around a rejected action.
fn repair_evidence(rejected: &[Rejection], units: &[Unit]) -> Vec<Unit> {
    let sources: HashSet<&str> = rejected
        .iter()
        .flat_map(|r| r.sources.iter().map(String::as_str))
        .collect();
    let action_sources: HashSet<&str> = rejected
        .iter()
        .filter(|r| r.kind == "actions")
        .flat_map(|r| r.sources.iter().map(String::as_str))
        .collect();
    let mut indices = BTreeSet::new();
    for (index, unit) in units.iter().enumerate() {
        if sources.contains(unit.source.as_str()) {
            let radius = if action_sources.contains(unit.source.as_str()) {
                8
            } else {
                2
            };
            for i in index.saturating_sub(radius)..=(index + radius).min(units.len() - 1) {
                indices.insert(i);
            }
        }
    }
    indices.into_iter().map(|i| units[i].clone()).collect()
}

fn repair_prompt(
    job: &Job,
    rejected: &[Rejection],
    units: &[Unit],
    note_limit: usize,
    action_limit: usize,
) -> String {
    let sources: HashSet<&str> = units.iter().map(|u| u.source.as_str()).collect();
    let feedback: Vec<Value> = rejected
        .iter()
        .map(|r| {
            let mut value = json!({
                "kind": r.kind,
                "reason": r.reason,
                "sources": r.sources.iter().filter(|s| sources.contains(s.as_str())).cloned().collect::<Vec<_>>().join(", "),
            });
            if let Some(text) = &r.text {
                value["text"] = json!(sanitize::prefix(text, 280));
            }
            value
        })
        .collect();
    prompts::notes_repair_prompt(
        note_limit,
        action_limit,
        &Value::Array(feedback).to_string(),
        &job.evidence.prompt(units),
    )
}

/// The user's undertakings that no user task cites.
fn missing_commitments(part: &Part, job: &Job, recovery: &Recovery) -> Vec<String> {
    let view = &job.evidence.view;
    let cited: HashSet<&str> = part
        .outcomes
        .user_action_items()
        .flat_map(|a| a.citations.iter().map(|c| c.segment_id.as_str()))
        .collect();
    let settled: HashSet<&String> = recovery.settled_ownership.iter().flatten().collect();
    let compact: HashMap<&str, String> = view
        .segment_ids
        .iter()
        .enumerate()
        .map(|(i, id)| (id.as_str(), View::citation_id(i)))
        .collect();
    let mut settled_sources: HashSet<String> = HashSet::new();
    for action in part.outcomes.unresolved_action_items() {
        if settled.contains(&evidence::similarity_normalized(&action.text)) {
            settled_sources.extend(
                action
                    .citations
                    .iter()
                    .filter_map(|c| compact.get(c.segment_id.as_str()).cloned()),
            );
        }
    }
    job.units
        .iter()
        .filter(|unit| {
            let Some(row) = view.index_of(&unit.source) else {
                return false;
            };
            if !unit.is_user_commitment || cited.contains(view.segment_ids[row].as_str()) {
                return false;
            }
            let missing = Rejection {
                sources: vec![unit.source.clone()],
                kind: "actions".into(),
                reason: "missing_user_commitment".into(),
                text: None,
                action_id: None,
            };
            !repair_evidence(&[missing], job.units)
                .iter()
                .any(|u| u.speaker == unit.speaker && settled_sources.contains(&u.source))
        })
        .map(|u| u.source.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Queue a repair for each user undertaking no user task cites: finish a
/// nearby owner-unclear task first, else ask for the missing action.
fn queue_missing_commitments(part: &Part, job: &Job, recovery: &mut Recovery) {
    if !recovery.scan_complete {
        return;
    }
    let view = &job.evidence.view;
    let compact: HashMap<&str, String> = view
        .segment_ids
        .iter()
        .enumerate()
        .map(|(i, id)| (id.as_str(), View::citation_id(i)))
        .collect();
    let answered: HashSet<String> = recovery
        .answered_commitments
        .iter()
        .flatten()
        .cloned()
        .collect();
    for source in missing_commitments(part, job, recovery) {
        let missing = Rejection {
            sources: vec![source.clone()],
            kind: "actions".into(),
            reason: "missing_user_commitment".into(),
            text: None,
            action_id: None,
        };
        let nearby: HashSet<String> = repair_evidence(std::slice::from_ref(&missing), job.units)
            .into_iter()
            .map(|u| u.source)
            .collect();
        if recovery
            .pending
            .iter()
            .any(|r| r.kind == "actions" && r.sources.iter().any(|s| nearby.contains(s)))
        {
            continue;
        }
        let candidates: Vec<&ActionItem> = part
            .outcomes
            .unresolved_action_items()
            .filter(|a| {
                a.citations
                    .first()
                    .and_then(|c| compact.get(c.segment_id.as_str()))
                    .is_some_and(|s| nearby.contains(s))
            })
            .collect();
        if candidates.len() == 1 {
            let action = candidates[0];
            if let Some(anchor) = action
                .citations
                .first()
                .and_then(|c| compact.get(c.segment_id.as_str()))
            {
                recovery.pending.push(Rejection {
                    sources: vec![anchor.clone()],
                    kind: "actions".into(),
                    reason: "missing_ownership_evidence".into(),
                    text: Some(action.text.clone()),
                    action_id: Some(action.id.clone()),
                });
            }
        } else if candidates.is_empty() && !answered.contains(&source) {
            recovery.pending.push(missing);
        }
    }
}

/// Ownership repairs keep each task's text fixed; replacement is atomic.
fn accept_ownership_repairs(
    fixed: &Validated,
    requested: &[Rejection],
    job: &Job,
    complete: bool,
    part: &mut Part,
    recovery: &mut Recovery,
) {
    let view = &job.evidence.view;
    for request in requested {
        let (Some(action_id), Some(text)) = (&request.action_id, &request.text) else {
            continue;
        };
        let Some(index) = recovery.pending.iter().position(|p| p == request) else {
            continue;
        };
        let wanted = evidence::similarity_normalized(text);
        let matches = |value: &str| evidence::similarity_normalized(value) == wanted;
        let allowed: HashSet<String> = repair_evidence(std::slice::from_ref(request), job.units)
            .iter()
            .filter_map(|u| {
                view.index_of(&u.source)
                    .map(|i| view.segment_ids[i].clone())
            })
            .collect();
        let actions: Vec<&ActionItem> = fixed
            .outcomes
            .action_items
            .iter()
            .filter(|a| {
                matches(&a.text) && a.citations.iter().all(|c| allowed.contains(&c.segment_id))
            })
            .collect();
        if actions.len() != 1 {
            let terminal = fixed.rejected.iter().any(|r| {
                r.text.as_deref().is_some_and(matches)
                    && !r.sources.is_empty()
                    && r.sources.iter().all(|s| {
                        view.index_of(s)
                            .is_some_and(|i| allowed.contains(&view.segment_ids[i]))
                    })
                    && [
                        "unsupported_commitment",
                        "conversation_management",
                        "status_not_task",
                    ]
                    .contains(&r.reason.as_str())
            });
            if complete && terminal {
                part.outcomes.action_items.retain(|a| &a.id != action_id);
                recovery.pending.remove(index);
            }
            continue;
        }
        let action = actions[0].clone();
        part.outcomes.action_items.retain(|a| &a.id != action_id);
        part.outcomes.action_items.push(action.clone());
        recovery
            .records
            .retain(|r| !(r.kind == "actions" && matches(&r.text)));
        recovery.records.extend(
            fixed
                .records
                .iter()
                .filter(|r| r.kind == "actions" && matches(&r.text))
                .cloned(),
        );
        if let Some(rejection) = fixed
            .rejected
            .iter()
            .find(|r| r.action_id.as_ref() == Some(&action.id))
        {
            recovery.pending[index] = rejection.clone();
        } else if complete {
            recovery.pending.remove(index);
        } else {
            recovery.pending[index].action_id = Some(action.id.clone());
        }
    }
}

/// At most three extraction pages and two rounds of repairs per part.
fn generate_part(
    initial: Part,
    job: &Job,
    budget: &mut Budget,
    save: &mut dyn FnMut(&Part),
) -> Result<()> {
    let mut part = initial;
    let mut recovery = part.recovery.take().unwrap_or_default();
    if recovery.pending.iter().any(|r| r.sources.is_empty()) {
        recovery.pending.retain(|r| !r.sources.is_empty());
        recovery.scan_complete = false;
        recovery.next_page = 0;
        recovery.no_progress_attempts = None;
        recovery.terminal_failure = None;
    }
    if job.retrying_stopped && recovery.terminal_failure.is_some() {
        recovery.terminal_failure = None;
        recovery.no_progress_attempts = None;
    }
    if let Some(failure) = &recovery.terminal_failure {
        return Err(AiError::BadResponse(failure.clone()).into());
    }
    let minimum = job.think.minimum_structured_output_tokens();
    let known_sources: HashSet<&str> = job.units.iter().map(|u| u.source.as_str()).collect();
    let mut checkpoint = |part: &mut Part, recovery: &Recovery| {
        part.recovery = Some(recovery.clone());
        save(part);
    };
    let system = prompts::meeting_notes_system(
        job.template,
        job.language.as_deref(),
        &evidence::sections(job.template),
    );
    let rows = job.evidence.prompt(job.units);
    let word_count: usize = job
        .units
        .iter()
        .map(|u| u.text.split_whitespace().count())
        .sum();

    let mut shape_retry_used = false;
    let mut shape_retry_pending = false;
    for _ in 0..3 {
        if recovery.scan_complete {
            break;
        }
        cancelled(job.cancel)?;
        let desired = (16_384f64.min(4_096.0 * job.output_scale)) as u32;
        let allowance = budget.allowance(job.remaining_parts, desired, minimum)?;
        let continuing = !recovery.records.is_empty();
        let stage = if continuing {
            format!("continue-{}-{}", job.number, recovery.next_page)
        } else {
            format!("extract-{}", job.number)
        };
        let suffix = if shape_retry_pending {
            shape_retry_pending = false;
            prompts::NOTES_SHAPE_RETRY
        } else {
            ""
        };
        let ledger = continuing.then_some(recovery.records.as_slice());
        let (prompt, tokens) = fitted_page(job, &rows, suffix, ledger, &system, allowance)?;
        let maximum_notes =
            ((12.0 * job.output_scale) as usize).min((tokens as usize / 200).max(3));
        let maximum_actions =
            ((10.0 * job.output_scale) as usize).min((tokens as usize / 350).max(2));
        let schema = job.evidence.schema(
            job.units,
            job.template,
            maximum_notes,
            maximum_actions,
            None,
        );
        let (raw, truncated) = request(
            job.think,
            budget,
            &system,
            &prompt,
            job.context,
            schema,
            tokens,
            &stage,
            job.context_tokens,
            false,
        )?;
        let mut validated = job.evidence.validate(
            &raw,
            job.units,
            job.template,
            maximum_notes,
            maximum_actions,
        );
        let previous_count = recovery.records.len();
        accept(&mut part, &mut recovery, &validated);
        // Empty output cannot certify a substantial untouched transcript.
        if part.claims.is_empty() && part.outcomes.is_empty() && word_count > 500 {
            validated.complete = false;
        }
        for rejection in &validated.rejected {
            if rejection.action_id.is_none()
                && !rejection.sources.is_empty()
                && !recovery.pending.contains(rejection)
            {
                recovery.pending.push(rejection.clone());
            }
        }
        let source_less_shape_error = validated.rejected.iter().any(|r| {
            r.sources.is_empty() && (r.reason == "invalid_action" || r.reason == "invalid_note")
        });
        if !shape_retry_used
            && !truncated
            && recovery.pending.is_empty()
            && !validated.complete
            && source_less_shape_error
        {
            shape_retry_used = true;
            shape_retry_pending = true;
        }
        recovery.scan_complete = validated.complete && !truncated;
        recovery.next_page += 1;
        checkpoint(&mut part, &recovery);
        if validated.rejected.iter().any(|r| {
            !r.sources.is_empty()
                && r.sources
                    .iter()
                    .all(|s| !known_sources.contains(s.as_str()))
        }) {
            let failure = "The summary provider returned missing or invalid evidence IDs. Source-linked partial notes were saved. Choose a different summary model or provider before retrying.";
            recovery.terminal_failure = Some(failure.into());
            checkpoint(&mut part, &recovery);
            return Err(AiError::BadResponse(failure.into()).into());
        }
        if recovery.records.len() == previous_count && !recovery.scan_complete {
            if shape_retry_pending {
                checkpoint(&mut part, &recovery);
                continue;
            }
            if !truncated && recovery.pending.is_empty() {
                let attempts = recovery.no_progress_attempts.unwrap_or(0) + 1;
                recovery.no_progress_attempts = Some(attempts);
                if attempts >= 2 {
                    let failure = "The summary provider made no further source-linked progress. Partial notes were saved. Choose a different summary model or provider before retrying.";
                    recovery.terminal_failure = Some(failure.into());
                    checkpoint(&mut part, &recovery);
                    return Err(AiError::BadResponse(failure.into()).into());
                }
            }
            checkpoint(&mut part, &recovery);
            break;
        }
        recovery.no_progress_attempts = None;
    }

    let terminal = [
        "unsupported_commitment",
        "conversation_management",
        "status_not_task",
        "empty_outcome",
    ];
    recovery
        .pending
        .retain(|r| !terminal.contains(&r.reason.as_str()));
    queue_missing_commitments(&part, job, &mut recovery);
    checkpoint(&mut part, &recovery);

    let ownership_reasons = [
        "missing_ownership_evidence",
        "ambiguous_ownership_evidence",
        "ownership_quote_not_found",
    ];
    let repair_system = prompts::meeting_notes_repair_system(job.language.as_deref());
    for phase in 0..2 {
        let mut answered_ownership: HashSet<String> = HashSet::new();
        let mut repaired_ownership = false;
        let mut previous_tokens = 0u32;
        for attempt in 0..2 {
            if recovery.pending.is_empty() {
                break;
            }
            cancelled(job.cancel)?;
            let repairable = repair_batch(&recovery.pending, job.units);
            if repairable.is_empty() {
                break;
            }
            let repair_units = repair_evidence(&repairable, job.units);
            let note_limit = repairable.iter().filter(|r| r.kind == "notes").count();
            let action_limit = repairable.iter().filter(|r| r.kind == "actions").count();
            let first = (512 + note_limit as u32 * 128 + action_limit as u32 * 384).min(2_048);
            let desired = 4_096.min(minimum.max(recovery.repair_token_floor.unwrap_or(0)).max(
                if attempt == 0 {
                    first
                } else {
                    previous_tokens * 2
                },
            ));
            let allowance = budget.allowance(job.remaining_parts, desired, minimum)?;
            if attempt > 0 && recovery.repair_token_floor.is_some() && allowance <= previous_tokens
            {
                break;
            }
            let ownership_repair = repairable.first().is_some_and(|r| r.action_id.is_some());
            let mut prompt =
                repair_prompt(job, &repairable, &repair_units, note_limit, action_limit);
            if attempt > 0 && !ownership_repair {
                let ledger: Vec<Record> = recovery
                    .records
                    .iter()
                    .filter(|r| repair_units.iter().any(|u| u.source == r.source))
                    .cloned()
                    .collect();
                prompt.push_str(&continuation(&ledger, 0));
            }
            let Some(repair_tokens) = output_room(job, &repair_system, &prompt, &[], allowance)?
            else {
                return Err(input_room_exceeded());
            };
            let stage = if attempt == 0 {
                format!("repair-{}", job.number)
            } else {
                format!("continue-repair-{}", job.number)
            };
            let action_texts: Option<Vec<String>> =
                (repairable.iter().all(|r| r.action_id.is_some()))
                    .then(|| repairable.iter().filter_map(|r| r.text.clone()).collect());
            let schema = job.evidence.schema(
                &repair_units,
                job.template,
                note_limit,
                action_limit,
                action_texts.as_deref(),
            );
            let (raw, truncated) = request(
                job.think,
                budget,
                &repair_system,
                &prompt,
                &[],
                schema,
                repair_tokens,
                &stage,
                job.context_tokens,
                false,
            )?;
            let fixed =
                job.evidence
                    .validate(&raw, &repair_units, job.template, note_limit, action_limit);
            let repair_sources: HashSet<&str> =
                repair_units.iter().map(|u| u.source.as_str()).collect();
            if fixed.rejected.iter().any(|r| {
                r.sources
                    .iter()
                    .all(|s| !repair_sources.contains(s.as_str()))
            }) {
                let failure = "The summary provider returned missing or invalid evidence IDs during repair. Source-linked partial notes were saved. Choose a different summary model or provider before retrying.";
                recovery.terminal_failure = Some(failure.into());
                checkpoint(&mut part, &recovery);
                return Err(AiError::BadResponse(failure.into()).into());
            }
            let complete = fixed.complete && !truncated;
            if ownership_repair {
                repaired_ownership = true;
                accept_ownership_repairs(
                    &fixed,
                    &repairable,
                    job,
                    complete,
                    &mut part,
                    &mut recovery,
                );
                let texts: Vec<String> = repairable
                    .iter()
                    .filter_map(|r| r.text.as_deref().map(evidence::similarity_normalized))
                    .collect();
                if complete {
                    answered_ownership.extend(texts);
                } else {
                    for text in texts {
                        answered_ownership.remove(&text);
                    }
                }
            } else {
                accept(&mut part, &mut recovery, &fixed);
            }
            if complete {
                if !ownership_repair {
                    recovery.pending.retain(|r| !repairable.contains(r));
                    let answered: Vec<String> = repairable
                        .iter()
                        .filter(|r| r.reason == "missing_user_commitment")
                        .flat_map(|r| r.sources.clone())
                        .collect();
                    if !answered.is_empty() {
                        let mut all: BTreeSet<String> = recovery
                            .answered_commitments
                            .take()
                            .unwrap_or_default()
                            .into_iter()
                            .collect();
                        all.extend(answered);
                        recovery.answered_commitments = Some(all.into_iter().collect());
                    }
                }
                recovery.repair_token_floor = None;
            } else if truncated {
                recovery.repair_token_floor = Some(4_096.min(repair_tokens * 2));
            }
            queue_missing_commitments(&part, job, &mut recovery);
            previous_tokens = repair_tokens;
            checkpoint(&mut part, &recovery);
            if truncated && repair_tokens >= 4_096 {
                break;
            }
            if !fixed.complete && !truncated && fixed.has_more != Some(true) {
                break;
            }
        }
        let mut settled: BTreeSet<String> = recovery
            .settled_ownership
            .take()
            .unwrap_or_default()
            .into_iter()
            .collect();
        let outcomes = part.outcomes.clone();
        recovery.pending.retain(|rejection| {
            let (Some(action_id), Some(text)) = (&rejection.action_id, &rejection.text) else {
                return true;
            };
            let normalized = evidence::similarity_normalized(text);
            let settles = ownership_reasons.contains(&rejection.reason.as_str())
                && answered_ownership.contains(&normalized)
                && outcomes
                    .action_items
                    .iter()
                    .any(|a| &a.id == action_id && a.ownership_is_unclear());
            if settles {
                settled.insert(normalized);
            }
            !settles
        });
        if !settled.is_empty() {
            recovery.settled_ownership = Some(settled.into_iter().collect());
        }
        if phase != 0
            || !repaired_ownership
            || recovery.pending.is_empty()
            || recovery.pending.iter().any(|r| r.action_id.is_some())
        {
            break;
        }
        checkpoint(&mut part, &recovery);
    }
    part.complete = recovery.scan_complete && recovery.pending.is_empty();
    checkpoint(&mut part, &recovery);
    Ok(())
}

// ------------------------------------------------------------------- merged

fn merged(
    checkpoint: &Checkpoint,
    evidence: &Evidence,
    template: NoteTemplate,
    revision: &str,
) -> (Vec<Claim>, MeetingOutcomes, String) {
    let mut keys: Vec<&String> = checkpoint.parts.keys().collect();
    keys.sort_by_key(|k| k.parse::<usize>().unwrap_or(0));
    let parts: Vec<&Part> = keys
        .iter()
        .filter_map(|k| checkpoint.parts.get(*k))
        .collect();
    let claims = render::distinct_claims(render::interleaving_tldr(
        &parts.iter().map(|p| p.claims.clone()).collect::<Vec<_>>(),
    ));
    let mut outcomes =
        render::merge_outcomes(&parts.iter().map(|p| p.outcomes.clone()).collect::<Vec<_>>())
            .prioritized();
    outcomes.transcript_revision = Some(revision.to_string());
    let mut rendered = claims.clone();
    if !claims.iter().any(|c| c.section == "TL;DR") {
        let mut overview = render::overview_claims(&claims, &outcomes);
        overview.extend(rendered);
        rendered = overview;
    }
    let body = render::synchronize(
        &render::render_claims(&rendered, &evidence.view, template),
        &outcomes,
        template,
    );
    (claims, outcomes, body)
}

fn save_checkpoint(
    dir: &Path,
    checkpoint: &Checkpoint,
    evidence: &Evidence,
    template: NoteTemplate,
    total: usize,
    revision: &str,
) {
    let write = |name: &str, bytes: &[u8]| {
        if let Err(err) = lokalbot_core::library::write_atomic(&dir.join(name), bytes) {
            log::warn!("could not save notes progress ({name}): {err}");
        }
    };
    if let Ok(bytes) = serde_json::to_vec(checkpoint) {
        write(CHECKPOINT_FILE, &bytes);
    }
    let (claims, outcomes, body) = merged(checkpoint, evidence, template, revision);
    let complete = checkpoint.parts.values().filter(|p| p.complete).count();
    write(
        "summary.partial.md",
        format!("# Partial notes — {complete}/{total} parts source-linked\n\n{body}").as_bytes(),
    );
    if let Ok(bytes) = serde_json::to_vec_pretty(&outcomes) {
        write("outcomes.partial.json", &bytes);
    }
    if let Ok(bytes) =
        serde_json::to_vec(&json!({"version": 1, "transcriptRevision": revision, "claims": claims}))
    {
        write("summary.claims.partial.json", &bytes);
    }
    let partial = json!({
        "transcriptRevision": revision,
        "summary": body,
        "outcomes": outcomes,
        "completedParts": complete,
        "totalParts": total,
        "template": template,
    });
    if let Ok(bytes) = serde_json::to_vec_pretty(&partial) {
        write("notes.partial.json", &bytes);
    }
}

/// The error text a person sees for a stopped notes job.
pub fn describe_error(err: &anyhow::Error) -> String {
    if let Some(incomplete) = err.downcast_ref::<Incomplete>() {
        return incomplete.to_string();
    }
    err.to_string()
}

#[cfg(test)]
mod tests;
