//! One night's review, end to end (`DreamCompiler`, `DreamPrompts`, `DreamService`):
//! compile the previous day's evidence, ask the Think model for the retrospective
//! and the memory update, merge and save. When no model is reachable a
//! deterministic evidence-only brief is written instead, and the report says
//! which kind it is. Evidence comes from the local library; generation follows the
//! Think model's privacy boundary, and artifacts stay inside the library.

use std::collections::HashMap;

use anyhow::Result;
use chrono::{DateTime, NaiveDate, Utc};
use regex::Regex;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use lokalbot_core::actions::{attention_sorted, cluster_threads};
use lokalbot_core::day_stats::{AppTime, DaySummary, SavedMoment};
use lokalbot_core::dream::{
    COMPARISON_WINDOW_DAYS, DreamMemory, DreamReport, DreamStore, FallbackReason,
    InferenceProvenance, MAX_EVIDENCE_PER_PROJECT, MAX_GOALS, MAX_PATTERNS, MAX_PROJECTS,
    MemoryUpdate, ProposedGoal, ProposedProject, StoreError, day_key,
};
use lokalbot_core::evidence::Source;
use lokalbot_core::model::{
    ActionItem, ActionReference, ActionStatus, ActionThread, Meeting, MeetingOutcomes,
};
use lokalbot_core::time::{local_day, local_day_bounds};
use lokalbot_core::{Library, Settings, ids};

use crate::error::{AiError, ai_error};
use crate::json::{extract_json_object, strip_reasoning};
use crate::prompts;
use crate::sanitize::sanitize;
use crate::think::{ChatRequest, ThinkClient};

pub const EVIDENCE_CHARACTER_LIMIT: usize = 24_000;
/// The journal's share of the pack. Its activity log can run to hundreds of KB;
/// unbounded it pushed everything else past the limit.
pub const DIGEST_CHARACTER_LIMIT: usize = 12_000;
pub const MAX_OPEN_ACTIONS: usize = 30;
/// Under five tracked minutes a day counts as empty.
pub const EMPTY_DAY_TRACKED_SECONDS_FLOOR: f64 = 300.0;

const MAX_OUTPUT_TOKENS: u32 = 4_096;
const REASONING_BUDGET_TOKENS: u32 = 1_024;
const TRUNCATION_RETRY_OUTPUT_TOKENS: u32 = 6_144;
const MAX_LIST_ITEMS: usize = 8;
const MAX_TOP_ACTIONS: usize = 3;
const MAX_LINE_CHARACTERS: usize = 400;

#[derive(Clone, Debug, PartialEq)]
pub struct MeetingEvidence {
    pub short_id: String,
    pub title: String,
    pub duration_label: String,
    pub started_at: DateTime<Utc>,
    pub outcomes: MeetingOutcomes,
    pub action_references: Vec<ActionReference>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PriorMeeting {
    pub day_key: String,
    pub title: String,
}

/// Everything one review reads, gathered up front so the synthesis is a pure
/// function of this value.
#[derive(Clone, Debug, PartialEq)]
pub struct DreamEvidence {
    pub day: NaiveDate,
    pub day_key: String,
    pub digest: Option<String>,
    pub meetings: Vec<MeetingEvidence>,
    pub app_usage: Vec<AppTime>,
    pub stats: DaySummary,
    pub saved_moments: Vec<SavedMoment>,
    /// Titles and days only, so recurring themes show without re-reading.
    pub prior_meetings: Vec<PriorMeeting>,
    /// Rendered candidates, `- [ ] [A1] …`; each handle indexes the ids below.
    pub open_actions: Vec<String>,
    pub open_action_thread_ids: Vec<String>,
    /// The complete, app-owned dependency set of the rendered input.
    pub sources: Vec<Source>,
}

impl DreamEvidence {
    /// The analyzed day itself produced nothing worth a model pass. The
    /// comparison window never counts.
    pub fn is_substantively_empty(&self) -> bool {
        self.meetings.is_empty()
            && self.digest.is_none()
            && self.saved_moments.is_empty()
            && self.stats.tracked_seconds < EMPTY_DAY_TRACKED_SECONDS_FLOOR
    }
}

fn clean(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace('`', "\\`")
}

fn duration(seconds: f64) -> String {
    let minutes = (seconds.round() as i64 / 60).max(0);
    if minutes >= 60 {
        format!("{}h {}m", minutes / 60, minutes % 60)
    } else {
        format!("{minutes}m")
    }
}

/// `MeetingOutcomes` with done actions left out, as the day's meetings show them.
fn active_outcomes(outcomes: &MeetingOutcomes, references: &[ActionReference]) -> MeetingOutcomes {
    let mut result = outcomes.clone();
    result.action_items = references
        .iter()
        .filter(|reference| reference.status != ActionStatus::Done)
        .map(ActionReference::effective_action)
        .collect();
    result
}

fn thread_description(thread: &ActionThread) -> String {
    let mut suffix: Vec<String> = Vec::new();
    if let Some(owner) = thread.owner.as_deref().filter(|o| !o.is_empty()) {
        suffix.push(format!("owner: {}", clean(owner)));
    }
    if let Some(due) = thread.due.as_deref().filter(|d| !d.is_empty()) {
        suffix.push(format!("due: {}", clean(due)));
    }
    if thread.status() == ActionStatus::Deferred {
        suffix.push("status: deferred".into());
    }
    let mut sources: Vec<String> = Vec::new();
    for reference in &thread.references {
        let id = ids::short_id(&reference.meeting_id);
        if !sources.contains(&id) {
            sources.push(id);
        }
    }
    let listed: Vec<String> = sources.iter().map(|id| format!("`{id}`")).collect();
    suffix.push(format!("sources: {}", listed.join(", ")));
    format!("{} ({})", clean(&thread.text), suffix.join(", "))
}

fn item_description(item: &ActionItem, short_id: &str) -> String {
    let mut suffix: Vec<String> = Vec::new();
    if let Some(owner) = item.owner.as_deref().filter(|o| !o.is_empty()) {
        suffix.push(format!("owner: {}", clean(owner)));
    }
    if let Some(due) = item.due.as_deref().filter(|d| !d.is_empty()) {
        suffix.push(format!("due: {}", clean(due)));
    }
    let details = if suffix.is_empty() {
        String::new()
    } else {
        format!(" ({})", suffix.join(", "))
    };
    format!("{}{details} — `{short_id}`", clean(&item.text))
}

fn meeting_day_key(meeting: &Meeting) -> String {
    day_key(local_day(meeting.started_at))
}

/// `DreamCompiler.compile`: read-only over the library.
pub fn compile(library: &Library, day: NaiveDate) -> Result<DreamEvidence> {
    let (start, end) = local_day_bounds(day);
    let all = library.list_meetings()?;
    // The sample meeting is made up: it never becomes part of the day.
    let mut day_meetings: Vec<&Meeting> = all
        .iter()
        .filter(|m| !m.is_sample() && m.started_at >= start && m.started_at < end)
        .collect();
    day_meetings.sort_by_key(|m| m.started_at);
    let mut meetings = Vec::new();
    let mut day_references: HashMap<Uuid, Vec<ActionReference>> = HashMap::new();
    for meeting in day_meetings {
        let projection = library.outcome_projection(meeting).ok().flatten();
        let references = projection
            .as_ref()
            .map(|p| p.action_references())
            .unwrap_or_default();
        let outcomes = projection
            .as_ref()
            .map(|p| active_outcomes(&p.outcomes, &references))
            .unwrap_or_default();
        day_references.insert(meeting.id, references.clone());
        meetings.push(MeetingEvidence {
            short_id: meeting.short_id(),
            title: meeting.title.clone(),
            duration_label: lokalbot_core::time::meeting_duration_label(meeting.duration_seconds()),
            started_at: meeting.started_at,
            outcomes,
            action_references: references,
        });
    }

    let window_start = local_day_bounds(day - chrono::Duration::days(COMPARISON_WINDOW_DAYS - 1)).0;
    let mut in_window: Vec<&Meeting> = all
        .iter()
        .filter(|m| m.started_at >= window_start && m.started_at < end)
        .collect();
    in_window.sort_by_key(|m| m.started_at);
    let prior_meetings: Vec<PriorMeeting> = in_window
        .iter()
        .filter(|m| m.started_at < start)
        .map(|m| PriorMeeting {
            day_key: meeting_day_key(m),
            title: m.title.clone(),
        })
        .collect();
    let references: Vec<ActionReference> = in_window
        .iter()
        .rev()
        .flat_map(|meeting| {
            day_references.get(&meeting.id).cloned().unwrap_or_else(|| {
                library
                    .outcome_projection(meeting)
                    .ok()
                    .flatten()
                    .map(|p| p.action_references())
                    .unwrap_or_default()
            })
        })
        .collect();
    let open_threads: Vec<ActionThread> = cluster_threads(references)
        .into_iter()
        .filter(|thread| thread.status() != ActionStatus::Done)
        .take(MAX_OPEN_ACTIONS)
        .collect();
    let open_actions = open_threads
        .iter()
        .enumerate()
        .map(|(index, thread)| format!("- [ ] [A{}] {}", index + 1, thread_description(thread)))
        .collect();

    let key = day_key(day);
    let mut sources: Vec<Source> = in_window
        .iter()
        .map(|m| Source {
            kind: "meeting".into(),
            id: ids::uuid_upper(&m.id),
            day_key: meeting_day_key(m),
        })
        .collect();
    sources.push(Source {
        kind: "screenDay".into(),
        id: key.clone(),
        day_key: key.clone(),
    });
    sources.push(Source {
        kind: "digest".into(),
        id: key.clone(),
        day_key: key.clone(),
    });

    let digest = crate::digest::generated_digest(library, day)
        .filter(|(_, current)| *current)
        .map(|(text, _)| text.trim().to_string())
        .filter(|text| !text.is_empty());

    Ok(DreamEvidence {
        day,
        day_key: key,
        digest,
        meetings,
        app_usage: library.app_time(start, end, 100)?,
        stats: library.day_summary(start, end)?,
        saved_moments: library.saved_moments_between(start, end, 500)?,
        prior_meetings,
        open_actions,
        open_action_thread_ids: open_threads.iter().map(|t| t.id.clone()).collect(),
        sources,
    })
}

/// The journal's grounded sections, then as much of its raw activity log as fits.
pub fn digest_for_dream(journal: &str) -> String {
    const MARKER: &str = "\n## Full activity log";
    let head = journal
        .find(MARKER)
        .map(|index| &journal[..index])
        .unwrap_or(journal);
    let head_count = head.chars().count();
    if head_count >= DIGEST_CHARACTER_LIMIT {
        let cut: String = head.chars().take(DIGEST_CHARACTER_LIMIT - 1).collect();
        return format!("{cut}…");
    }
    if journal.chars().count() <= DIGEST_CHARACTER_LIMIT {
        return journal.to_string();
    }
    const NOTICE: &str = "\n…(activity log truncated)";
    let room = DIGEST_CHARACTER_LIMIT.saturating_sub(head_count + NOTICE.chars().count());
    let rest: String = journal.chars().skip(head_count).take(room).collect();
    format!("{head}{rest}{NOTICE}")
}

/// Every section as labeled plain text, sanitized and hard-capped so an OCR-heavy
/// day can't blow the context window.
pub fn evidence_pack(evidence: &DreamEvidence) -> String {
    let mut sections: Vec<String> = Vec::new();
    if evidence.meetings.is_empty() {
        sections.push(format!("Meetings on {}: none recorded.", evidence.day_key));
    } else {
        let mut lines = vec![format!("Meetings on {}:", evidence.day_key)];
        for meeting in &evidence.meetings {
            lines.push(format!(
                "- {} (`{}`, {})",
                clean(&meeting.title),
                meeting.short_id,
                meeting.duration_label
            ));
            for decision in &meeting.outcomes.decision_records {
                lines.push(format!("  decision: {}", clean(&decision.text)));
            }
            for item in &meeting.outcomes.action_items {
                let mut line = format!("  action: {}", clean(&item.text));
                if let Some(owner) = item.owner.as_deref().filter(|o| !o.is_empty()) {
                    line.push_str(&format!(" (owner: {})", clean(owner)));
                }
                if let Some(due) = item.due.as_deref().filter(|d| !d.is_empty()) {
                    line.push_str(&format!(" (due: {})", clean(due)));
                }
                lines.push(line);
            }
            for question in &meeting.outcomes.open_questions {
                lines.push(format!("  open question: {}", clean(question)));
            }
        }
        sections.push(lines.join("\n"));
    }
    if let Some(digest) = &evidence.digest {
        sections.push(format!("Day digest:\n{}", digest_for_dream(digest)));
    }
    if !evidence.app_usage.is_empty() {
        let rows: Vec<String> = evidence
            .app_usage
            .iter()
            .take(10)
            .map(|usage| {
                format!(
                    "- {}: {}",
                    clean(&usage.app),
                    duration(usage.duration_seconds)
                )
            })
            .collect();
        sections.push(format!("App-time totals:\n{}", rows.join("\n")));
    }
    sections.push(format!(
        "Day stats: tracked {} across {} apps, {} context captures.",
        duration(evidence.stats.tracked_seconds),
        evidence.stats.app_count,
        evidence.stats.screenshot_count
    ));
    if !evidence.saved_moments.is_empty() {
        let rows: Vec<String> = evidence
            .saved_moments
            .iter()
            .take(10)
            .map(|moment| {
                let label = if moment.window_title.is_empty() {
                    moment.app.clone()
                } else {
                    format!("{} — {}", moment.app, moment.window_title)
                };
                let note = clean(&moment.note);
                if note.is_empty() {
                    format!("- {}", clean(&label))
                } else {
                    format!("- {} (note: {note})", clean(&label))
                }
            })
            .collect();
        sections.push(format!("Saved moments:\n{}", rows.join("\n")));
    }
    if !evidence.prior_meetings.is_empty() {
        let start = evidence.prior_meetings.len().saturating_sub(40);
        let rows: Vec<String> = evidence.prior_meetings[start..]
            .iter()
            .map(|m| format!("- {}: {}", m.day_key, clean(&m.title)))
            .collect();
        sections.push(format!(
            "Meetings in the prior {} days (comparison window only):\n{}",
            COMPARISON_WINDOW_DAYS - 1,
            rows.join("\n")
        ));
    }
    if !evidence.open_actions.is_empty() {
        sections.push(format!(
            "Action candidates from the last {COMPARISON_WINDOW_DAYS} days (using saved corrections and status):\n{}",
            evidence.open_actions.join("\n")
        ));
    }
    sanitize(&sections.join("\n\n"), Some(EVIDENCE_CHARACTER_LIMIT))
}

/// The model-free brief: it only restates evidence, so it can never invent.
pub fn fallback_report(
    evidence: &DreamEvidence,
    generated_at: DateTime<Utc>,
    reason: FallbackReason,
    note: &str,
) -> DreamReport {
    let count = evidence.meetings.len();
    let phrase = if count == 1 {
        "1 recorded meeting".to_string()
    } else {
        format!("{count} recorded meetings")
    };
    let narrative = format!(
        "{note} The day had {phrase}, {} tracked across {} apps.",
        duration(evidence.stats.tracked_seconds),
        evidence.stats.app_count
    );
    let attention: Vec<String> = evidence
        .meetings
        .iter()
        .flat_map(|meeting| {
            meeting
                .outcomes
                .open_questions
                .iter()
                .map(|q| format!("{} — `{}`", clean(q), meeting.short_id))
        })
        .take(5)
        .collect();
    let user_references: Vec<ActionReference> = evidence
        .meetings
        .iter()
        .flat_map(|m| m.action_references.iter().cloned())
        .filter(|r| r.is_for_user)
        .collect();
    let (top_actions, thread_ids): (Vec<String>, Vec<Option<String>>) =
        if user_references.is_empty() {
            let items = evidence
                .meetings
                .iter()
                .flat_map(|meeting| {
                    meeting
                        .outcomes
                        .action_items
                        .iter()
                        .filter(|item| item.is_for_user)
                        .map(|item| item_description(item, &meeting.short_id))
                })
                .take(MAX_TOP_ACTIONS)
                .collect();
            (items, Vec::new())
        } else {
            let open: Vec<ActionThread> = cluster_threads(user_references)
                .into_iter()
                .filter(|t| t.status() != ActionStatus::Done)
                .collect();
            let threads = attention_sorted(open, local_day(generated_at));
            (
                threads
                    .iter()
                    .take(MAX_TOP_ACTIONS)
                    .map(thread_description)
                    .collect(),
                threads
                    .iter()
                    .take(MAX_TOP_ACTIONS)
                    .map(|t| Some(t.id.clone()))
                    .collect(),
            )
        };
    let mut report = DreamReport::new(evidence.day_key.clone(), generated_at, narrative);
    report.fallback_reason = Some(reason);
    report.attention = attention;
    report.top_actions = top_actions;
    report.top_action_thread_ids = (!thread_ids.is_empty()).then_some(thread_ids);
    report
}

/// JSON schema matching the system prompt, for grammar-constrained backends.
/// Strict structured outputs need every declared property, so `expired` is
/// required here and the prompt says to return false for an active goal.
pub fn schema() -> Value {
    let list = json!({"type": "array", "items": {"type": "string"}});
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "narrative": {"type": "string"},
            "attention": list,
            "repeated_work": list,
            "suggested_checks": list,
            "frictions": list,
            "top_actions": list,
            "active_projects": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "name": {"type": "string"},
                        "status": {"type": "string"},
                        "active_today": {"type": "boolean"},
                        "evidence": list,
                    },
                    "required": ["name", "status", "active_today", "evidence"],
                },
            },
            "work_goals": {
                "type": "array",
                "items": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "text": {"type": "string"},
                        "horizon": {"type": "string"},
                        "reinforced_today": {"type": "boolean"},
                        "expired": {"type": "boolean"},
                    },
                    "required": ["text", "horizon", "reinforced_today", "expired"],
                },
            },
            "recurring_patterns": list,
        },
        "required": ["narrative", "attention", "repeated_work", "suggested_checks",
                     "frictions", "top_actions", "active_projects", "work_goals",
                     "recurring_patterns"],
    })
}

pub fn prompt(evidence: &DreamEvidence) -> String {
    format!(
        "Conduct the retrospective of {} from this evidence:\n\n{}",
        evidence.day_key,
        evidence_pack(evidence)
    )
}

pub fn context(evidence: &DreamEvidence, memory: &DreamMemory) -> Vec<String> {
    let mut context = vec![format!("Analyzed local day: {}", evidence.day_key)];
    if memory.is_empty() {
        context.push("Current structured work memory: empty — this is the first dream.".into());
    } else {
        context.push(format!(
            "Current structured work memory:\n{}",
            sanitize(&memory.markdown(), Some(6_000))
        ));
    }
    context
}

/// What one night proposed; pure data.
#[derive(Clone, Debug, PartialEq)]
pub struct Synthesis {
    pub narrative: String,
    pub attention: Vec<String>,
    pub repeated_work: Vec<String>,
    pub suggested_checks: Vec<String>,
    pub frictions: Vec<String>,
    pub top_actions: Vec<String>,
    pub memory: MemoryUpdate,
}

impl Synthesis {
    fn is_empty(&self) -> bool {
        self.narrative.is_empty()
            && self.attention.is_empty()
            && self.repeated_work.is_empty()
            && self.suggested_checks.is_empty()
            && self.frictions.is_empty()
            && self.top_actions.is_empty()
            && self.memory.is_empty()
    }

    pub fn report(
        &self,
        day: &str,
        generated_at: DateTime<Utc>,
        engine_name: &str,
        provenance: InferenceProvenance,
        action_thread_ids: &[String],
    ) -> DreamReport {
        let (texts, links) = link_top_actions(&self.top_actions, action_thread_ids);
        let mut report = DreamReport::new(day.to_string(), generated_at, self.narrative.clone());
        report.engine_name = Some(engine_name.to_string());
        report.inference_provenance = Some(provenance);
        report.attention = self.attention.clone();
        report.repeated_work = self.repeated_work.clone();
        report.suggested_checks = self.suggested_checks.clone();
        report.frictions = self.frictions.clone();
        report.top_actions = texts;
        report.top_action_thread_ids = links.iter().any(Option::is_some).then_some(links);
        report
    }
}

/// Strips candidate handles ("[A2] …") and maps each to its thread. Unknown or
/// out-of-range handles are removed without inventing a link; duplicates keep
/// only their first link.
pub fn link_top_actions(
    actions: &[String],
    thread_ids: &[String],
) -> (Vec<String>, Vec<Option<String>>) {
    static HANDLE: std::sync::LazyLock<Regex> = std::sync::LazyLock::new(|| {
        Regex::new(r"^\s*\[A(\d{1,3})\]\s*[:\-–—]?\s*").expect("valid regex")
    });
    let mut texts = Vec::new();
    let mut links = Vec::new();
    let mut used: Vec<&String> = Vec::new();
    for action in actions {
        let mut text = action.as_str();
        let mut link = None;
        if let Some(captures) = HANDLE.captures(action) {
            text = &action[captures.get(0).map_or(0, |m| m.end())..];
            let thread = captures[1]
                .parse::<usize>()
                .ok()
                .and_then(|handle| handle.checked_sub(1))
                .and_then(|index| thread_ids.get(index));
            if let Some(thread) = thread
                && !used.contains(&thread)
            {
                used.push(thread);
                link = Some(thread.clone());
            }
        }
        let trimmed = text.trim();
        texts.push(if trimmed.is_empty() {
            action.clone()
        } else {
            trimmed.to_string()
        });
        links.push(link);
    }
    (texts, links)
}

#[derive(Deserialize)]
struct PayloadProject {
    name: String,
    status: String,
    evidence: Vec<String>,
    #[serde(default)]
    active_today: Option<bool>,
}

#[derive(Deserialize)]
struct PayloadGoal {
    text: String,
    horizon: String,
    reinforced_today: bool,
    #[serde(default)]
    expired: Option<bool>,
}

#[derive(Deserialize)]
struct Payload {
    narrative: String,
    attention: Vec<String>,
    repeated_work: Vec<String>,
    suggested_checks: Vec<String>,
    frictions: Vec<String>,
    top_actions: Vec<String>,
    active_projects: Vec<PayloadProject>,
    work_goals: Vec<PayloadGoal>,
    recurring_patterns: Vec<String>,
}

fn cleaned(raw: &str, cap: usize) -> Option<String> {
    let collapsed = raw
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if collapsed.is_empty() {
        return None;
    }
    if collapsed.chars().count() > cap {
        let cut: String = collapsed.chars().take(cap).collect();
        return Some(format!("{cut}…"));
    }
    Some(collapsed)
}

fn cleaned_list(values: &[String]) -> Option<Vec<String>> {
    values
        .iter()
        .map(|v| cleaned(v, MAX_LINE_CHARACTERS))
        .collect()
}

fn report_list(values: &[String]) -> Vec<String> {
    values
        .iter()
        .filter_map(|v| cleaned(v, MAX_LINE_CHARACTERS))
        .collect()
}

fn take<T>(mut values: Vec<T>, limit: usize) -> Vec<T> {
    values.truncate(limit);
    values
}

/// `DreamPrompts.parse`: tolerant extraction of the JSON object, then strict typed
/// decoding. Report sections drop blank bullets; memory lists stay strict because
/// they replace stored entries. `None` sends the service to the fallback.
pub fn parse(output: &str) -> Option<Synthesis> {
    let visible = strip_reasoning(output);
    let object = extract_json_object(&visible)?;
    let payload: Payload = serde_json::from_str(object).ok()?;
    let narrative = cleaned(&payload.narrative, 1_200)?;
    let recurring = cleaned_list(&payload.recurring_patterns)?;
    let mut projects = Vec::new();
    for project in &payload.active_projects {
        let evidence = cleaned_list(&project.evidence)?;
        projects.push(ProposedProject {
            name: cleaned(&project.name, MAX_LINE_CHARACTERS)?,
            status: cleaned(&project.status, MAX_LINE_CHARACTERS)?,
            evidence: take(evidence, MAX_EVIDENCE_PER_PROJECT),
            active_today: project.active_today,
        });
    }
    let mut goals = Vec::new();
    for goal in &payload.work_goals {
        goals.push(ProposedGoal {
            text: cleaned(&goal.text, MAX_LINE_CHARACTERS)?,
            horizon: cleaned(&goal.horizon, MAX_LINE_CHARACTERS)?,
            reinforced_today: goal.reinforced_today,
            expired: goal.expired.unwrap_or(false),
        });
    }
    let synthesis = Synthesis {
        narrative,
        attention: take(report_list(&payload.attention), MAX_LIST_ITEMS),
        repeated_work: take(report_list(&payload.repeated_work), MAX_LIST_ITEMS),
        suggested_checks: take(report_list(&payload.suggested_checks), MAX_LIST_ITEMS),
        frictions: take(report_list(&payload.frictions), MAX_LIST_ITEMS),
        top_actions: take(report_list(&payload.top_actions), MAX_TOP_ACTIONS),
        memory: MemoryUpdate {
            active_projects: take(projects, MAX_PROJECTS),
            work_goals: take(goals, MAX_GOALS),
            recurring_patterns: take(recurring, MAX_PATTERNS),
        },
    };
    (!synthesis.is_empty()).then_some(synthesis)
}

/// The model ran out of room: retry once with thinking off and more room for the
/// visible JSON, as the day digest does.
fn generate_synthesis(
    think: &ThinkClient,
    evidence: &DreamEvidence,
    memory: &DreamMemory,
) -> Result<String> {
    let first = ChatRequest::new(prompts::DREAM_SYSTEM, prompt(evidence))
        .context(context(evidence, memory))
        .json_schema(schema())
        .max_tokens(MAX_OUTPUT_TOKENS)
        .reasoning_budget(REASONING_BUDGET_TOKENS)
        .temperature(0.2);
    match think.complete(&first) {
        Ok(text) => Ok(text),
        Err(err) if matches!(ai_error(&err), Some(AiError::Truncated { .. })) => {
            log::info!("dreaming: reply hit the output limit, retrying without reasoning");
            let retry = ChatRequest::new(prompts::DREAM_SYSTEM, prompt(evidence))
                .context(context(evidence, memory))
                .json_schema(schema())
                .max_tokens(TRUNCATION_RETRY_OUTPUT_TOKENS)
                .reasoning_budget(0)
                .temperature(0.0);
            think.complete(&retry)
        }
        Err(err) => Err(err),
    }
}

/// Where a Think client runs, for the report (`DreamInferenceProvenance`).
pub fn inference_provenance(think: &ThinkClient, settings: &Settings) -> InferenceProvenance {
    if think.is_local() {
        return InferenceProvenance::local();
    }
    if let Some(plan) = settings.think_plan() {
        return InferenceProvenance::remote(Some(plan.consent_key().to_string()));
    }
    let base = match settings.summarizer_backend {
        lokalbot_core::settings::SummarizerBackend::Ollama => &settings.ollama_base_url,
        _ => &settings.openai_base_url,
    };
    InferenceProvenance::remote(lokalbot_core::access::origin_of(base))
}

/// What a run needs that the engine decides.
pub struct DreamRequest<'a> {
    pub day: NaiveDate,
    pub is_automatic: bool,
    /// Consecutive transient failures already seen for this day.
    pub transient_failures: u32,
    /// `None` when the Think model can't be made; the brief is then evidence-only.
    pub make_engine: &'a dyn Fn() -> Result<(ThinkClient, InferenceProvenance)>,
    /// True once the run has been overtaken and must not continue.
    pub cancelled: &'a dyn Fn() -> bool,
}

/// Automatic runs that hit a rate limit or dropped connection are retried after
/// the backoff; the evidence-only brief is written only after this many.
pub const TRANSIENT_ATTEMPTS_BEFORE_FALLBACK: u32 = 3;

#[derive(Debug, thiserror::Error)]
pub enum DreamError {
    /// A transient failure the scheduler retries after its backoff, quietly.
    #[error("{0}")]
    Deferred(String),
    /// The sources changed, Clear work memory ran, or the run was stopped.
    #[error("The review was cancelled.")]
    Cancelled,
    #[error(transparent)]
    Store(StoreError),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl From<StoreError> for DreamError {
    fn from(err: StoreError) -> Self {
        match err {
            StoreError::Cancelled => Self::Cancelled,
            other => Self::Store(other),
        }
    }
}

/// `DreamService.dream`.
pub fn dream(library: &Library, request: &DreamRequest<'_>) -> Result<DreamReport, DreamError> {
    let store = DreamStore::new(library.paths().root());
    // Read before compiling: a source change while the library is being read
    // can't be noticed any other way.
    let revision = store.evidence_revision()?;
    let evidence = compile(library, request.day)?;
    if (request.cancelled)() {
        return Err(DreamError::Cancelled);
    }
    let now = Utc::now;
    let memory = store
        .load_memory()?
        .unwrap_or_else(|| DreamMemory::empty(now()));
    // A missing historical report may need rebuilding after later days advanced
    // memory: rebuild it from its own evidence, but never replay an older
    // synthesis over newer state.
    let watermark = [
        memory.last_dream_day.clone(),
        store.latest_report().map(|report| report.day),
    ]
    .into_iter()
    .flatten()
    .max();
    let advances_memory = watermark.is_none_or(|day| day <= evidence.day_key);
    let context_memory = if advances_memory {
        memory.clone()
    } else {
        DreamMemory::empty(now())
    };
    let mut updated = memory.clone();
    let mut provenance = DreamMemory::empty(now()).provenance_adding(&evidence.sources, revision);

    let mut report = if evidence.is_substantively_empty() {
        // Nothing happened that day: don't wake a model to say so. The stub
        // marks the day reviewed so catch-up moves on, and memory carries forward.
        fallback_report(
            &evidence,
            now(),
            FallbackReason::EmptyDay,
            "Nothing substantive was recorded, so there is no retrospective.",
        )
    } else {
        match (request.make_engine)().and_then(|(think, inference)| {
            let output = generate_synthesis(&think, &evidence, &context_memory)?;
            Ok((think, inference, output))
        }) {
            Ok((think, inference, output)) => {
                if (request.cancelled)() {
                    return Err(DreamError::Cancelled);
                }
                match parse(&output) {
                    Some(synthesis) => {
                        provenance = context_memory.provenance_adding(&evidence.sources, revision);
                        if advances_memory {
                            updated = memory.merging(
                                &synthesis.memory,
                                &evidence.day_key,
                                now(),
                                Some(&provenance),
                            );
                        }
                        synthesis.report(
                            &evidence.day_key,
                            now(),
                            &think.display_name(),
                            inference,
                            &evidence.open_action_thread_ids,
                        )
                    }
                    None => {
                        log::info!(
                            "dreaming: model reply was unparseable, writing evidence-only brief"
                        );
                        fallback_report(
                            &evidence,
                            now(),
                            FallbackReason::UnparseableResponse,
                            "The model's reply could not be read, so this brief lists evidence only.",
                        )
                    }
                }
            }
            Err(err) if crate::error::is_cancelled(&err) => return Err(DreamError::Cancelled),
            Err(err)
                if ai_error(&err).is_some_and(AiError::is_retryable)
                    && request.is_automatic
                    && request.transient_failures + 1 < TRANSIENT_ATTEMPTS_BEFORE_FALLBACK =>
            {
                // A rate limit or dropped connection isn't a broken backend.
                log::info!(
                    "dreaming: deferred after transient error day={} attempt={}",
                    evidence.day_key,
                    request.transient_failures + 1
                );
                return Err(DreamError::Deferred(err.to_string()));
            }
            Err(err) => {
                // No model prepared, server down, remote origin unapproved, or
                // still failing: deliver the morning surface, memory untouched,
                // and mark the day done. "Review now" can redo it.
                log::warn!("dreaming: engine unavailable, writing evidence-only brief: {err:#}");
                fallback_report(
                    &evidence,
                    now(),
                    FallbackReason::EngineUnavailable,
                    "No model was reachable overnight, so this brief lists evidence only.",
                )
            }
        }
    };

    report.evidence_provenance = Some(provenance);
    let report = report.redacted();
    if (request.cancelled)() {
        return Err(DreamError::Cancelled);
    }
    if advances_memory {
        updated.last_dream_day = Some(evidence.day_key.clone());
        updated.updated_at = now();
        store.save_generated(&report, Some(&updated.redacted()), revision)?;
    } else {
        store.save_generated(&report, None, revision)?;
    }
    Ok(report)
}

/// `TodayDreamSelection.report`: yesterday's brief when there is one, otherwise the
/// newest substantive brief within the last five days. Empty-day stubs exist only
/// to mark their day reviewed and are never shown.
pub fn today_report(library: &Library, today: NaiveDate) -> Option<DreamReport> {
    const LOOKBACK_DAYS: i64 = 5;
    let store = DreamStore::new(library.paths().root());
    (1..=LOOKBACK_DAYS)
        .filter_map(|back| store.report(&day_key(today - chrono::Duration::days(back))))
        .find(|report| report.fallback_reason != Some(FallbackReason::EmptyDay))
}

/// A current evidence-only brief caused by model generation can be retried
/// (`TodayDreamSelection.isRetryableFailure`). An empty day has nothing to redo.
pub fn is_retryable_failure(report: &DreamReport, today: NaiveDate) -> bool {
    let yesterday = day_key(today - chrono::Duration::days(1));
    report.day == yesterday
        && matches!(
            report.fallback_reason,
            Some(FallbackReason::EngineUnavailable | FallbackReason::UnparseableResponse)
        )
}

#[cfg(test)]
mod tests;
