//! Ask: answers from the user's meetings and screen memory with citations
//! (`Services/Chat/ChatAgent.swift`, `ChatCitation.swift`, `CLISupport/AskLibrary*`).
//!
//! The macOS agent lets the model call tools in a loop. Small local models
//! follow that protocol unreliably, so here the app retrieves first (keyword
//! search, meaning search when embeddings exist, title matches and the
//! scoped meetings), hands the model numbered sources with their citation
//! markers, streams one answer, and verifies every marker afterwards: a
//! marker for a source it was not given becomes "(source not verified)".

use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::LazyLock;
use std::sync::atomic::AtomicBool;

use anyhow::Result;
use chrono::{DateTime, Local, Utc};
use regex::Regex;
use uuid::Uuid;

use lokalbot_core::embeddings::{RRF_K, rrf_fuse};
use lokalbot_core::model::{ChatActivity, ChatMessage, ChatRole, Meeting, Transcript};
use lokalbot_core::search::{DocKind, MatchMode, SearchQuery};
use lokalbot_core::{Library, ids};

use crate::embeddings::semantic_meeting_hits;
use crate::think::{ChatRequest, ThinkClient};
use crate::{prompts, sanitize};

/// What an answer may draw on.
#[derive(Clone, Debug, PartialEq)]
pub struct AskScope {
    /// Only these meetings (empty: all).
    pub meeting_ids: Vec<Uuid>,
    pub since: Option<DateTime<Utc>>,
    /// Exclusive.
    pub until: Option<DateTime<Utc>>,
    pub include_meetings: bool,
    pub include_screen: bool,
    /// Time spent in apps (the tool loop's `activity_summary`).
    pub include_activity: bool,
}

impl Default for AskScope {
    fn default() -> Self {
        Self {
            meeting_ids: Vec::new(),
            since: None,
            until: None,
            include_meetings: true,
            include_screen: false,
            include_activity: false,
        }
    }
}

/// Progress of one answer, for the conversation view.
#[derive(Clone, Debug, PartialEq)]
pub enum AskEvent {
    /// Visible answer text as it streams.
    Delta(String),
    /// The whole visible answer so far, replacing earlier text (the tool loop
    /// re-checks citations as it streams, so text can change).
    Answer(String),
    /// A finished step: "searched meetings for “X”", "read “Title”".
    Activity(String),
    /// What is happening now: "Searching…", "Writing the answer…".
    Status(String),
}

pub const NOT_FOUND: &str = prompts::ASK_NOT_FOUND;
pub(crate) const NO_ANSWER: &str =
    "I couldn't find enough information in your meetings to answer that.";
const MAX_MEETINGS: usize = 4;
const MAX_MOMENTS_PER_MEETING: usize = 6;
const MAX_SCREENS: usize = 5;
const SUMMARY_CHARACTERS: usize = 1_800;
const MOMENT_CHARACTERS: usize = 400;
const HISTORY_MESSAGES: usize = 8;
const HISTORY_CHARACTERS: usize = 4_000;

/// `HH:MM:SS`, the stamp the Mac chat prompt asks for.
fn marker_time(seconds: f64) -> String {
    let total = seconds.max(0.0) as u64;
    format!(
        "{:02}:{:02}:{:02}",
        total / 3_600,
        (total % 3_600) / 60,
        total % 60
    )
}

pub(crate) fn meeting_marker(id: &Uuid, at: Option<f64>) -> String {
    match at {
        Some(at) => format!("[meeting:{}@{}]", ids::uuid_upper(id), marker_time(at)),
        None => format!("[meeting:{}]", ids::uuid_upper(id)),
    }
}

/// The sources one answer was given: meeting moments and screen moments
/// (`ChatEvidence`). Only these may be cited.
#[derive(Clone, Default)]
pub(crate) struct Sources {
    pub(crate) text: String,
    pub(crate) meetings: Vec<(Uuid, String)>,
    /// Whole seconds of every moment marker handed to the model, per meeting.
    pub(crate) moments: HashMap<Uuid, BTreeSet<u64>>,
    pub(crate) screens: BTreeSet<i64>,
    /// Source labels ("M1", "S2") and the markers they stand for.
    pub(crate) labels: HashMap<String, String>,
}

impl Sources {
    pub(crate) fn add_meeting(&mut self, id: Uuid, title: &str, at: Option<f64>) {
        if !self.meetings.iter().any(|(m, _)| *m == id) {
            self.meetings.push((id, title.to_string()));
        }
        if let Some(at) = at.filter(|a| a.is_finite() && *a >= 0.0) {
            self.moments.entry(id).or_default().insert(at as u64);
        }
    }

    pub(crate) fn merge(&mut self, other: &Sources) {
        for (id, title) in &other.meetings {
            self.add_meeting(*id, title, None);
        }
        for (id, seconds) in &other.moments {
            self.moments.entry(*id).or_default().extend(seconds);
        }
        self.screens.extend(&other.screens);
    }
}

fn summary_excerpt(summary: &str) -> String {
    let body: Vec<&str> = summary
        .lines()
        .filter(|l| !l.starts_with("# ") && !l.starts_with("**Duration:**"))
        .collect();
    sanitize::sanitize(&body.join("\n"), Some(SUMMARY_CHARACTERS))
}

fn segment_at(transcript: &Transcript, start: f64) -> Option<usize> {
    transcript
        .segments
        .iter()
        .enumerate()
        .filter(|(_, s)| s.start <= start + 0.5)
        .min_by(|(_, a), (_, b)| {
            (start - a.start)
                .abs()
                .partial_cmp(&(start - b.start).abs())
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|(i, _)| i)
}

fn retrieval_text(question: &str, history: &[ChatMessage]) -> String {
    // A short follow-up ("and the second one?") searches with the question before it.
    if question.split_whitespace().count() <= 8
        && let Some(previous) = history.iter().rev().find(|m| m.role == ChatRole::User)
    {
        return format!("{} {question}", previous.text);
    }
    question.to_string()
}

#[allow(clippy::too_many_arguments)]
fn gather(
    think: &ThinkClient,
    library: &Library,
    question: &str,
    history: &[ChatMessage],
    scope: &AskScope,
    on_event: &mut dyn FnMut(AskEvent),
    activity: &mut Vec<ChatActivity>,
) -> Result<Sources> {
    let mut sources = Sources::default();
    let mut blocks: Vec<String> = Vec::new();
    let query_text = retrieval_text(question, history);
    let shown_query = sanitize::prefix(question.trim(), 80);
    let in_scope = |meeting: &Meeting| {
        (scope.meeting_ids.is_empty() || scope.meeting_ids.contains(&meeting.id))
            && scope.since.is_none_or(|s| meeting.started_at >= s)
            && scope.until.is_none_or(|u| meeting.started_at < u)
    };
    if scope.include_meetings {
        on_event(AskEvent::Status("Searching meetings…".into()));
        let meetings: Vec<Meeting> = library
            .list_meetings()?
            .into_iter()
            .filter(|m| in_scope(m))
            .collect();
        let query = SearchQuery {
            text: query_text.clone(),
            kinds: None,
            meeting_ids: (!scope.meeting_ids.is_empty()).then(|| scope.meeting_ids.clone()),
            since: scope.since,
            until: scope.until,
            limit: 30,
        };
        let mut keyword = library.search(&query)?;
        if keyword.is_empty() {
            keyword = library.search_with_mode(&query, MatchMode::Any)?;
        }
        let semantic = match think.embedder() {
            Some(embedder) => semantic_meeting_hits(&embedder, library, &query_text, 15)
                .unwrap_or_else(|err| {
                    log::warn!("meaning search unavailable for Ask: {err:#}");
                    Vec::new()
                }),
            None => Vec::new(),
        };
        let allowed: HashSet<Uuid> = meetings.iter().map(|m| m.id).collect();
        let semantic: Vec<_> = semantic
            .into_iter()
            .filter(|h| allowed.contains(&h.meeting_id))
            .collect();
        record(
            activity,
            on_event,
            "search_meetings",
            "magnifyingglass",
            format!("searched meetings for “{shown_query}”"),
        );

        let lowered = question.to_lowercase();
        let mut first: Vec<Uuid> = meetings
            .iter()
            .filter(|m| {
                m.title.trim().chars().count() >= 4
                    && lowered.contains(&m.title.trim().to_lowercase())
            })
            .map(|m| m.id)
            .collect();
        if !scope.meeting_ids.is_empty() && scope.meeting_ids.len() <= MAX_MEETINGS {
            first.extend(scope.meeting_ids.iter().filter(|id| allowed.contains(id)));
        }
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
        for id in first.into_iter().chain(
            rrf_fuse(&lexical, &meaning, RRF_K)
                .into_iter()
                .map(|(id, _)| id),
        ) {
            if !ranked.contains(&id) && allowed.contains(&id) {
                ranked.push(id);
            }
        }
        for (number, id) in ranked.into_iter().take(MAX_MEETINGS).enumerate() {
            let Some(meeting) = meetings.iter().find(|m| m.id == id) else {
                continue;
            };
            let title = meeting.display_title();
            let date = meeting
                .started_at
                .with_timezone(&Local)
                .format("%A, %b %-d, %Y")
                .to_string();
            let mut block = vec![format!(
                "[M{}] {title} — {date} · {}",
                number + 1,
                meeting_marker(&meeting.id, None)
            )];
            if let Some(summary) = library
                .summary(meeting)?
                .map(|s| summary_excerpt(&s))
                .filter(|s| !s.is_empty())
            {
                block.push(format!("Summary:\n{summary}"));
            }
            let transcript = library.transcript(meeting)?;
            let mut starts: Vec<f64> = keyword
                .iter()
                .filter(|h| h.meeting_id == id && h.kind == DocKind::Segment)
                .filter_map(|h| h.start)
                .chain(
                    semantic
                        .iter()
                        .filter(|h| h.meeting_id == id && h.start > 0.0)
                        .map(|h| h.start),
                )
                .collect();
            starts.dedup();
            if let Some(transcript) = &transcript {
                let roster = transcript.speaker_roster();
                let mut rows: BTreeSet<usize> = BTreeSet::new();
                for start in starts {
                    if let Some(index) = segment_at(transcript, start) {
                        rows.insert(index);
                        if index + 1 < transcript.segments.len() {
                            rows.insert(index + 1);
                        }
                    }
                    if rows.len() >= MAX_MOMENTS_PER_MEETING {
                        break;
                    }
                }
                let moments: Vec<String> = rows
                    .into_iter()
                    .take(MAX_MOMENTS_PER_MEETING)
                    .filter_map(|index| {
                        let segment = &transcript.segments[index];
                        let text = Transcript::display_text(&segment.text);
                        if text.is_empty() {
                            return None;
                        }
                        let name = roster
                            .get(&Transcript::canonical_speaker_key(&segment.speaker))
                            .cloned()
                            .unwrap_or_else(|| Transcript::default_speaker_name(&segment.speaker));
                        sources
                            .moments
                            .entry(id)
                            .or_default()
                            .insert(segment.start.max(0.0) as u64);
                        Some(format!(
                            "- {} {name}: {}",
                            meeting_marker(&id, Some(segment.start)),
                            sanitize::prefix(&text, MOMENT_CHARACTERS)
                        ))
                    })
                    .collect();
                if !moments.is_empty() {
                    block.push(format!("Moments:\n{}", moments.join("\n")));
                }
            }
            if block.len() == 1 {
                continue;
            }
            record(
                activity,
                on_event,
                "get_meeting",
                "doc.text",
                format!("read “{title}”"),
            );
            sources
                .labels
                .insert(format!("M{}", number + 1), meeting_marker(&id, None));
            sources.meetings.push((id, title));
            blocks.push(block.join("\n"));
        }
    }
    if scope.include_screen {
        on_event(AskEvent::Status("Searching screen memory…".into()));
        let hits = library.search_screen_hits(&query_text, None, None, 20)?;
        let hits: Vec<_> = hits
            .into_iter()
            .filter(|h| {
                scope.since.is_none_or(|s| h.moment.ts >= s)
                    && scope.until.is_none_or(|u| h.moment.ts < u)
            })
            .take(MAX_SCREENS)
            .collect();
        record(
            activity,
            on_event,
            "search_screen",
            "rectangle.on.rectangle",
            format!("searched screen memory for “{shown_query}”"),
        );
        for (number, hit) in hits.iter().enumerate() {
            let moment = &hit.moment;
            let when = moment
                .ts
                .with_timezone(&Local)
                .format("%A, %b %-d, %Y at %H:%M");
            let window = if moment.window_title.is_empty() {
                String::new()
            } else {
                format!(" — {}", moment.window_title)
            };
            let text = moment
                .text
                .as_deref()
                .map(|t| sanitize::single_line(t, 600))
                .filter(|t| !t.is_empty())
                .unwrap_or_else(|| hit.snippet.replace(['«', '»'], ""));
            blocks.push(format!(
                "[S{}] {}{window} · {when} · [screen:{}]\n{text}",
                number + 1,
                moment.app,
                moment.id
            ));
            sources.screens.insert(moment.id);
            sources.labels.insert(
                format!("S{}", number + 1),
                format!("[screen:{}]", moment.id),
            );
        }
    }
    sources.text = blocks.join("\n\n");
    Ok(sources)
}

fn record(
    activity: &mut Vec<ChatActivity>,
    on_event: &mut dyn FnMut(AskEvent),
    tool: &str,
    icon: &str,
    text: String,
) {
    on_event(AskEvent::Activity(text.clone()));
    activity.push(ChatActivity {
        id: Uuid::new_v4(),
        tool: tool.into(),
        icon: icon.into(),
        text,
        done: true,
    });
}

/// The Mac chat system prompt (`ChatAgent.systemPrompt`) without its tool
/// catalogue: sources are retrieved up front and supplied in the user
/// message, so one model turn answers.
fn system_prompt(think: &ThinkClient, include_screen: bool) -> String {
    let (context, screen) = if include_screen {
        (
            ", and about their workday context — text seen on screen and time spent in apps",
            "\n• When part of your final answer comes from a screen source, append the exact [screen:ID] marker that source shows. The app renders it as a private, local thumbnail linking to that captured moment. Never invent a screen id.",
        )
    } else {
        ("", "")
    };
    format!(
        "You are LokalBot's assistant. You answer questions about the user's on-device meeting recordings, transcripts and summaries{context}. The source library is stored on this PC. {} Be concise and specific, and cite meetings by their title and date. Never invent content — answer only from the sources in the user message, and if they hold nothing relevant, reply exactly: {NOT_FOUND}

Citing sources:
• When part of your final answer comes from a specific meeting, append a citation marker right after that sentence: [meeting:ID], or [meeting:ID@HH:MM:SS] to point at a moment in the transcript. Use the exact meeting id a source shows — never invent one. Use only a timestamp explicitly shown in a source. The app renders markers as links; don't explain them.{screen}",
        think.inference_privacy()
    )
}

static CITATION: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\[(meeting|screen):([A-Za-z0-9_-]{1,64})(?:@(\d{1,2}(?::\d{2}){1,2}))?\]")
        .expect("valid regex")
});

static LABEL: LazyLock<Regex> = LazyLock::new(|| {
    let one = r"[MS]\d{1,2}(?:@\d{1,2}(?::\d{2}){1,2})?";
    Regex::new(&format!(r"\[({one}(?:\s*[,;]\s*{one})*)\]")).expect("valid regex")
});

/// Small models often cite a source by its label ("[M1]", "[M1@00:00:43]")
/// rather than its marker; turns labels into the markers they stand for.
/// `[meetings:A, B]` or `[meeting:A; B@00:01:10]`: several meetings in one
/// marker, which small models write despite the prompt.
static GROUPED: LazyLock<Regex> = LazyLock::new(|| {
    let one = r"(?:meeting:)?[A-Za-z0-9_-]{1,64}(?:@\d{1,2}(?::\d{2}){1,2})?";
    Regex::new(&format!(
        r"\[meetings?:\s*({one}(?:\s*[,;]\s*{one})+|{one})\]"
    ))
    .expect("valid regex")
});

/// Splits grouped meeting markers into one `[meeting:…]` per meeting, so each
/// is verified on its own.
fn split_grouped(text: &str) -> String {
    GROUPED
        .replace_all(text, |caps: &regex::Captures| {
            caps[1]
                .split([',', ';'])
                .map(|part| {
                    let part = part.trim();
                    format!(
                        "[meeting:{}]",
                        part.strip_prefix("meeting:").unwrap_or(part)
                    )
                })
                .collect::<Vec<_>>()
                .join(" ")
        })
        .into_owned()
}

fn expand_labels(text: &str, sources: &Sources) -> String {
    LABEL
        .replace_all(text, |caps: &regex::Captures| {
            caps[1]
                .split([',', ';'])
                .map(|part| {
                    let (label, at) = match part.trim().split_once('@') {
                        Some((label, at)) => (label, Some(at)),
                        None => (part.trim(), None),
                    };
                    match (sources.labels.get(label), at) {
                        (Some(marker), Some(at)) if marker.starts_with("[meeting:") => {
                            format!("{}@{at}]", marker.trim_end_matches(']'))
                        }
                        (Some(marker), _) => marker.clone(),
                        (None, _) => "(source not verified)".into(),
                    }
                })
                .collect::<Vec<_>>()
                .join(" ")
        })
        .into_owned()
}

/// `verified` for a partial answer: a marker still being written is held
/// back rather than shown and then retracted.
pub(crate) fn verified_partial(text: &str, sources: &Sources) -> String {
    let mut text = text;
    if let Some(bracket) = text.rfind('[')
        && !text[bracket..].contains(']')
    {
        let suffix = &text[bracket..];
        if "[meetings:".starts_with(suffix)
            || "[screen:".starts_with(suffix)
            || suffix.starts_with("[meeting:")
            || suffix.starts_with("[meetings:")
            || suffix.starts_with("[screen:")
        {
            text = &text[..bracket];
        }
    }
    verified(text, sources)
}

/// Rewrites markers to the canonical `[meeting:<UUID>@HH:MM:SS]` form, keeping
/// only those the answer was given (`ChatEvidence`).
pub(crate) fn verified(text: &str, sources: &Sources) -> String {
    let text = expand_labels(&split_grouped(text), sources);
    CITATION
        .replace_all(&text, |caps: &regex::Captures| {
            let id = &caps[2];
            if &caps[1] == "screen" {
                return match id.parse::<i64>() {
                    Ok(snapshot) if sources.screens.contains(&snapshot) => {
                        format!("[screen:{snapshot}]")
                    }
                    _ => "(source not verified)".into(),
                };
            }
            let lowered = id.to_lowercase();
            let meeting = sources.meetings.iter().map(|(m, _)| *m).find(|m| {
                let full = m.hyphenated().to_string();
                full == lowered
                    || (lowered.len() >= 8
                        && m.simple()
                            .to_string()
                            .starts_with(&lowered.replace('-', "")))
            });
            let Some(meeting) = meeting else {
                return "(source not verified)".into();
            };
            let at = caps
                .get(3)
                .and_then(|t| lokalbot_core::time::parse_stamp(t.as_str()))
                .map(|s| s as u64);
            match at {
                Some(second)
                    if sources
                        .moments
                        .get(&meeting)
                        .is_some_and(|m| m.contains(&second)) =>
                {
                    meeting_marker(&meeting, Some(second as f64))
                }
                _ => meeting_marker(&meeting, None),
            }
        })
        .into_owned()
}

fn history_block(history: &[ChatMessage]) -> String {
    let mut lines: Vec<String> = Vec::new();
    let mut used = 0;
    for message in history.iter().rev().take(HISTORY_MESSAGES) {
        let speaker = if message.role == ChatRole::User {
            "User"
        } else {
            "Assistant"
        };
        let text = sanitize::single_line(&CITATION.replace_all(&message.text, ""), 1_200);
        used += text.len();
        if used > HISTORY_CHARACTERS {
            break;
        }
        lines.push(format!("{speaker}: {text}"));
    }
    lines.reverse();
    lines.join("\n")
}

pub(crate) fn assistant(text: String, activity: Vec<ChatActivity>) -> ChatMessage {
    ChatMessage {
        id: Uuid::new_v4(),
        role: ChatRole::Assistant,
        text,
        activity,
        created_at: Some(lokalbot_core::time::now_seconds()),
    }
}

/// Answers `question` from the library within `scope`, streaming deltas
/// through `on_event`. When `cancel` is set the answer stops promptly and
/// keeps what arrived.
pub fn answer(
    think: &ThinkClient,
    library: &Library,
    question: &str,
    history: &[ChatMessage],
    scope: &AskScope,
    cancel: &AtomicBool,
    on_event: &mut dyn FnMut(AskEvent),
) -> Result<ChatMessage> {
    let mut activity = Vec::new();
    let sources = gather(
        think,
        library,
        question,
        history,
        scope,
        on_event,
        &mut activity,
    )?;
    if sources.text.trim().is_empty() {
        on_event(AskEvent::Delta(NOT_FOUND.into()));
        return Ok(assistant(NOT_FOUND.into(), activity));
    }
    on_event(AskEvent::Status("Writing the answer…".into()));
    let now = Local::now();
    let past = history_block(history);
    let conversation = if past.is_empty() {
        String::new()
    } else {
        format!("Conversation so far:\n{past}\n\n")
    };
    let user = format!(
        "Current local time: {} ({}). Resolve relative dates such as \"yesterday\" or \"last Tuesday\" from it.\n\nSources:\n{}\n\n{conversation}Question: {}",
        now.format("%A, %-d %B %Y, %H:%M"),
        time_zone_name(),
        sources.text,
        question.trim()
    );
    let request = ChatRequest::new(system_prompt(think, scope.include_screen), user)
        .max_tokens(1_024)
        .temperature(0.2)
        .reasoning_budget(0)
        .keep_truncated();
    let completion = think.stream_full(&request, Some(cancel), &mut |delta| {
        on_event(AskEvent::Delta(delta.to_string()))
    })?;
    let mut text = verified(completion.text.trim(), &sources);
    if text.trim().is_empty() {
        text = if completion.cancelled {
            String::new()
        } else {
            NO_ANSWER.into()
        };
    }
    Ok(assistant(text, activity))
}

/// The IANA zone name when the environment names one, else the UTC offset.
pub(crate) fn time_zone_name() -> String {
    if let Ok(zone) = std::env::var("TZ")
        && !zone.trim().is_empty()
    {
        return zone.trim_start_matches(':').to_string();
    }
    #[cfg(unix)]
    if let Ok(target) = std::fs::read_link("/etc/localtime") {
        let path = target.to_string_lossy().into_owned();
        if let Some((_, zone)) = path.split_once("zoneinfo/") {
            return zone.to_string();
        }
    }
    Local::now().format("UTC%:z").to_string()
}

// ----------------------------------------------------------- ask_library

const LIBRARY_STOPWORDS: [&str; 82] = [
    "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "by", "for", "with",
    "from", "about", "into", "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
    "have", "has", "had", "will", "would", "should", "could", "can", "may", "might", "must",
    "what", "when", "where", "which", "who", "whom", "whose", "why", "how", "that", "this",
    "these", "those", "there", "it", "its", "i", "me", "my", "we", "us", "our", "you", "your",
    "he", "him", "his", "she", "her", "they", "them", "their", "any", "some", "all", "not", "so",
    "as", "than", "then", "also", "just", "tell",
];
const LIBRARY_EXTRA_STOPWORDS: [&str; 5] = ["say", "said", "please", "meeting", "meetings"];

fn truncated_utf8(value: &str, max_bytes: usize, marker: &str) -> String {
    if value.len() <= max_bytes {
        return value.to_string();
    }
    let budget = if marker.len() <= max_bytes {
        max_bytes - marker.len()
    } else {
        max_bytes
    };
    let mut end = budget.min(value.len());
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    if marker.len() <= max_bytes {
        format!("{}{marker}", &value[..end])
    } else {
        value[..end].to_string()
    }
}

/// `ask_library` served by the app (the CLI talks to the app's server itself;
/// see `lokalbot-cli`): title-matched summaries, then keyword snippets, one
/// answer, and a `Sources:` list.
pub fn ask_library(think: &ThinkClient, library: &Library, question: &str) -> Result<String> {
    let meetings = library.list_meetings()?;
    if meetings.is_empty() {
        return Ok("The meeting library is empty — record a meeting in LokalBot first.".into());
    }
    let day = |m: &Meeting| {
        m.started_at
            .with_timezone(&Local)
            .format("%Y-%m-%d")
            .to_string()
    };
    let mut context = String::new();
    let mut cited: Vec<Uuid> = Vec::new();
    let max_context = 32 * 1_024;
    let append = |context: &mut String, fragment: &str| -> bool {
        let available = max_context - context.len().min(max_context);
        if available == 0 || fragment.is_empty() {
            return false;
        }
        context.push_str(&truncated_utf8(
            fragment,
            available,
            "\n[… context budget reached …]",
        ));
        true
    };
    let lowered = question.to_lowercase();
    let mut titled: Vec<&Meeting> = meetings
        .iter()
        .filter(|m| {
            m.title.trim().chars().count() >= 4 && lowered.contains(&m.title.trim().to_lowercase())
        })
        .collect();
    titled.sort_by(|a, b| {
        b.title
            .chars()
            .count()
            .cmp(&a.title.chars().count())
            .then(b.started_at.cmp(&a.started_at))
    });
    for meeting in titled.into_iter().take(4) {
        let Some(summary) = library.summary(meeting)? else {
            continue;
        };
        let section = format!(
            "## {} — {} — full summary\n{}",
            meeting.title,
            day(meeting),
            truncated_utf8(&summary, 6 * 1_024, "\n[… summary truncated …]")
        );
        let separator = if context.is_empty() { "" } else { "\n\n" };
        if append(&mut context, &format!("{separator}{section}")) {
            cited.push(meeting.id);
        }
    }
    let terms: Vec<String> = lokalbot_core::ids::fold(question)
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| {
            !t.is_empty() && !LIBRARY_STOPWORDS.contains(t) && !LIBRARY_EXTRA_STOPWORDS.contains(t)
        })
        .map(str::to_string)
        .collect();
    if !terms.is_empty() {
        let hits =
            library.search_with_mode(&SearchQuery::new(terms.join(" "), 50), MatchMode::Any)?;
        let mut per_meeting: HashMap<Uuid, usize> = HashMap::new();
        let mut seen = HashSet::new();
        let (mut first, mut rest) = (Vec::new(), Vec::new());
        for hit in hits {
            if !seen.insert(format!("{}|{}", hit.meeting_id, hit.snippet)) {
                continue;
            }
            let taken = per_meeting.entry(hit.meeting_id).or_default();
            *taken += 1;
            if *taken <= 4 {
                first.push(hit)
            } else {
                rest.push(hit)
            }
        }
        let mut count = 0;
        for hit in first.into_iter().chain(rest) {
            if count == 12 {
                break;
            }
            let Some(meeting) = meetings.iter().find(|m| m.id == hit.meeting_id) else {
                continue;
            };
            let stamp = hit
                .start
                .map(|s| format!(" @{}", lokalbot_core::time::stamp(s)))
                .unwrap_or_default();
            let kind = if hit.kind == DocKind::Segment {
                "transcript"
            } else {
                hit.kind.as_str()
            };
            let line = truncated_utf8(
                &format!(
                    "- [{kind}{stamp}] {} ({}): {}",
                    meeting.title,
                    day(meeting),
                    hit.snippet
                ),
                1_024,
                "…",
            );
            let prefix = if count > 0 {
                "\n"
            } else if context.is_empty() {
                "## Snippets\n"
            } else {
                "\n\n## Snippets\n"
            };
            if !append(&mut context, &format!("{prefix}{line}")) {
                break;
            }
            count += 1;
            cited.push(meeting.id);
        }
    }
    if context.is_empty() {
        return Ok("I couldn't find anything in your meetings matching that question. Try search_meetings with a specific keyword.".into());
    }
    let today = Local::now().format("%A, %Y-%m-%d").to_string();
    let request = ChatRequest::new(
        prompts::ask_library_system(&today, &time_zone_name()),
        format!("Meeting context:\n\n{context}\n\nQuestion: {question}"),
    )
    .max_tokens(1_024)
    .temperature(0.2)
    .reasoning_budget(0)
    .keep_truncated();
    let reply = think.complete(&request)?;
    let mut unique = Vec::new();
    for id in cited {
        if !unique.contains(&id) {
            unique.push(id);
        }
    }
    let mut used: Vec<&Meeting> = unique
        .iter()
        .filter_map(|id| meetings.iter().find(|m| m.id == *id))
        .collect();
    used.sort_by_key(|m| std::cmp::Reverse(m.started_at));
    let sources: Vec<String> = used
        .iter()
        .map(|m| format!("- {} ({}, id {})", m.title, day(m), m.short_id()))
        .collect();
    Ok(format!(
        "{}\n\nSources:\n{}",
        reply.trim(),
        sources.join("\n")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};
    use serde_json::json;
    use std::sync::Arc;
    use std::sync::atomic::Ordering;

    fn sse(text: &str) -> Reply {
        let mut events: Vec<String> = text
            .split_inclusive(' ')
            .map(|piece| {
                json!({"choices": [{"delta": {"content": piece}, "finish_reason": null}]})
                    .to_string()
            })
            .collect();
        events.push(json!({"choices": [{"delta": {}, "finish_reason": "stop"}]}).to_string());
        events.push("[DONE]".into());
        Reply::Sse(events)
    }

    #[test]
    fn answers_with_verified_citations() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let northwind = library
            .list_meetings()
            .unwrap()
            .into_iter()
            .find(|m| m.title == "Customer call - Northwind")
            .unwrap();
        let id = ids::uuid_upper(&northwind.id);
        let prompt = Arc::new(parking_lot::Mutex::new(String::new()));
        let seen = prompt.clone();
        let reply = format!(
            "Northwind needs SSO before a company-wide rollout [meeting:{id}@0:00]. You promised the security overview [meeting:44444444@00:00:15]. Budget is fine [meeting:99999999-9999-4999-8999-999999999999]."
        );
        let server = StubServer::start(move |request| {
            *seen.lock() = request.json()["messages"][1]["content"]
                .as_str()
                .unwrap_or_default()
                .to_string();
            sse(&reply)
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let mut events = Vec::new();
        let message = answer(
            &think,
            &library,
            "What does Northwind need before rollout?",
            &[],
            &AskScope::default(),
            &AtomicBool::new(false),
            &mut |e| events.push(e),
        )
        .unwrap();
        let sent = prompt.lock().clone();
        assert!(
            sent.contains("Sources:\n[M1] Customer call - Northwind"),
            "{sent}"
        );
        assert!(
            sent.contains(&format!(
                "[meeting:{id}@00:00:15] Me: SSO is on the Q3 roadmap."
            )),
            "{sent}"
        );
        assert_eq!(
            message.text,
            format!(
                "Northwind needs SSO before a company-wide rollout [meeting:{id}@00:00:00]. You promised the security overview [meeting:{id}@00:00:15]. Budget is fine (source not verified)."
            )
        );
        assert!(
            message
                .activity
                .iter()
                .any(|a| a.text
                    == "searched meetings for “What does Northwind need before rollout?”")
        );
        assert!(
            message
                .activity
                .iter()
                .any(|a| a.text == "read “Customer call - Northwind”")
        );
        assert!(events.iter().any(|e| matches!(e, AskEvent::Delta(_))));
        let citations = lokalbot_core::model::Citation::parse_all(&message.text);
        assert_eq!(citations.len(), 2);
    }

    #[test]
    fn nothing_relevant_needs_no_model() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = calls.clone();
        let server = StubServer::start(move |_| {
            counter.fetch_add(1, Ordering::SeqCst);
            sse("x")
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let scope = AskScope {
            since: Some(Utc::now()),
            ..AskScope::default()
        };
        let message = answer(
            &think,
            &library,
            "zebra quantum xylophone",
            &[],
            &scope,
            &AtomicBool::new(false),
            &mut |_| {},
        )
        .unwrap();
        assert_eq!(message.text, NOT_FOUND);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn ask_library_appends_sources() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let server = StubServer::start(|request| {
            let body = request.json();
            assert_eq!(body["thinking_budget_tokens"], 0);
            assert!(
                body["messages"][0]["content"]
                    .as_str()
                    .unwrap()
                    .starts_with("You are LokalBot's meeting-library assistant.")
            );
            assert!(
                body["messages"][1]["content"]
                    .as_str()
                    .unwrap()
                    .contains("## Snippets\n- [")
            );
            Reply::Json(
                200,
                json!({"choices": [{"message": {"content": "Northwind wants SSO."}, "finish_reason": "stop"}]}),
            )
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let text = ask_library(&think, &library, "What did Northwind say about SSO?").unwrap();
        assert!(
            text.starts_with("Northwind wants SSO.\n\nSources:\n- "),
            "{text}"
        );
        assert!(
            text.contains("\n- Customer call - Northwind (2026-10-15, id 44444444)"),
            "{text}"
        );
    }

    #[test]
    fn source_labels_become_markers() {
        let id = Uuid::new_v4();
        let mut sources = Sources::default();
        sources.meetings.push((id, "Weekly sync".into()));
        sources.moments.entry(id).or_default().insert(43);
        sources
            .labels
            .insert("M1".into(), meeting_marker(&id, None));
        sources.screens.insert(7);
        sources.labels.insert("S1".into(), "[screen:7]".into());
        let marker = ids::uuid_upper(&id);
        assert_eq!(
            verified(
                "Friday [M1]. The demo [M1@00:00:43]. Both [M1, S1]. Other [M3].",
                &sources
            ),
            format!(
                "Friday [meeting:{marker}]. The demo [meeting:{marker}@00:00:43]. Both [meeting:{marker}] [screen:7]. Other (source not verified)."
            )
        );
    }

    #[test]
    fn grouped_meeting_markers_are_verified_one_by_one() {
        let first = Uuid::parse_str("00000024-0000-4000-8000-000000000024").unwrap();
        let second = Uuid::parse_str("00000026-0000-4000-8000-000000000026").unwrap();
        let mut sources = Sources::default();
        sources.meetings.push((first, "Client call".into()));
        sources.meetings.push((second, "Delivery check".into()));
        sources.moments.entry(second).or_default().insert(70);
        let (a, b) = (ids::uuid_upper(&first), ids::uuid_upper(&second));
        assert_eq!(
            verified(
                "Cut [meetings:00000024, 00000026]. Mix [meeting:00000026@00:01:10; 99999999].",
                &sources
            ),
            format!(
                "Cut [meeting:{a}] [meeting:{b}]. Mix [meeting:{b}@00:01:10] (source not verified)."
            )
        );
        assert_eq!(verified_partial("Cut [meetings:0000", &sources), "Cut ");
    }

    #[test]
    fn markers_use_minutes_and_hours() {
        assert_eq!(marker_time(75.0), "00:01:15");
        assert_eq!(marker_time(3_725.0), "01:02:05");
    }
}
