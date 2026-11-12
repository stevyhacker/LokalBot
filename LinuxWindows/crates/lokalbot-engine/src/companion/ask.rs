//! Answers questions from paired devices (`CompanionAskResponder.swift`) with
//! the same Ask agent, Think engine and remote-inference approvals as Ask on
//! this computer. Tools are limited to the classes the person shares:
//! meetings, and the Timeline's activity summary only when window titles are
//! shared too, because it names windows. Screen search, Dream memory and
//! Personal Context are never used.
//!
//! A device that disconnects doesn't stop its answer: the sink keeps it, in
//! memory, for the device to collect (`lokalbot-sync`'s `answers`). Only
//! turning sharing off, or quitting, cancels one.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Result;
use chrono::{DateTime, Local, Utc};
use lokalbot_ai::ask::{AskEvent, AskScope, QuestionFocus, QuestionLimit};
use lokalbot_core::model::{ChatMessage, ChatRole};
use lokalbot_core::{Library, Meeting};
use lokalbot_sync::AskSink;
use parking_lot::Mutex;
use regex::Regex;
use uuid::Uuid;

use super::library::{is_shared, read_all_meetings};
use super::records::{self, AskCitation, AskRequest, AskResult, encode, instant};
use super::sharing::{DataClasses, HistoryWindow, Sharing, parse_day_key};

/// Where an answer for a phone goes: `AskSink` from the sync host.
pub trait AskOutput: Send + Sync {
    fn delta(&self, text: String);
    fn done(&self, result_json: String);
    fn failed(&self, message: String);
}

impl AskOutput for AskSink {
    fn delta(&self, text: String) {
        AskSink::delta(self, text);
    }

    fn done(&self, result_json: String) {
        AskSink::done(self, result_json);
    }

    fn failed(&self, message: String) {
        AskSink::failed(self, message);
    }
}

// ---------------------------------------------------------------- citations

/// `ChatCitationParser.pattern`: short or full meeting ids, positive screen
/// and file row ids; meeting stamps accept M:SS, MM:SS or HH:MM:SS.
static MARKER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\[(meeting|screen|file|note):([A-Za-z0-9_-]{1,64})(?:@(\d{1,2}(?::\d{2}){1,2}))?\]",
    )
    .expect("valid pattern")
});
static SPACE_BEFORE_PUNCTUATION: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[ \t]+([.,;:!?])").expect("valid pattern"));
static DOUBLED_SPACES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\S)[ \t]{2,}").expect("valid pattern"));

#[derive(Clone, Debug, PartialEq)]
pub enum ParsedCitation {
    Meeting {
        id: String,
        seconds: Option<f64>,
    },
    Screen(i64),
    File(i64),
    /// A saved coding-agent note, by its hex id.
    Note(String),
}

fn stamp_seconds(stamp: &str) -> Option<f64> {
    let parts: Vec<i64> = stamp
        .split(':')
        .map(|part| part.parse().ok())
        .collect::<Option<_>>()?;
    if !(2..=3).contains(&parts.len()) || parts[1..].iter().any(|part| !(0..60).contains(part)) {
        return None;
    }
    Some(match parts.as_slice() {
        [minutes, seconds] => minutes * 60 + seconds,
        [hours, minutes, seconds] => hours * 3_600 + minutes * 60 + seconds,
        _ => return None,
    } as f64)
}

/// Replaces markers with ordered `[n]` references and returns the deduped
/// citations (`ChatCitationParser.extract`). Repeated sources keep their
/// first number; a malformed marker stays as text.
pub fn extract_citations(text: &str) -> (String, Vec<ParsedCitation>) {
    if !["[meeting:", "[screen:", "[file:", "[note:"]
        .iter()
        .any(|marker| text.contains(marker))
    {
        return (text.to_string(), Vec::new());
    }
    let mut citations: Vec<ParsedCitation> = Vec::new();
    let mut display = String::with_capacity(text.len());
    let mut cursor = 0;
    for captures in MARKER.captures_iter(text) {
        let whole = captures.get(0).expect("the whole match");
        let source = &captures[2];
        let stamp = captures.get(3).map(|m| m.as_str());
        let citation = match &captures[1] {
            "screen" if stamp.is_none() => source
                .parse()
                .ok()
                .filter(|id| *id > 0)
                .map(ParsedCitation::Screen),
            "file" if stamp.is_none() => source
                .parse()
                .ok()
                .filter(|id| *id > 0)
                .map(ParsedCitation::File),
            "note"
                if stamp.is_none()
                    && source.len() >= 8
                    && source.chars().all(|c| c.is_ascii_hexdigit()) =>
            {
                Some(ParsedCitation::Note(source.to_lowercase()))
            }
            "meeting"
                if source.chars().count() >= 3
                    && stamp.is_none_or(|s| stamp_seconds(s).is_some()) =>
            {
                Some(ParsedCitation::Meeting {
                    id: source.to_string(),
                    seconds: stamp.and_then(stamp_seconds),
                })
            }
            _ => None,
        };
        let Some(citation) = citation else {
            continue;
        };
        display.push_str(&text[cursor..whole.start()]);
        cursor = whole.end();
        let number = match citations.iter().position(|known| *known == citation) {
            Some(existing) => existing + 1,
            None => {
                citations.push(citation);
                citations.len()
            }
        };
        display.push_str(&format!("[{number}]"));
    }
    display.push_str(&text[cursor..]);
    (cleaned(&display), citations)
}

/// Tidies the gaps removed markers leave. Line-leading indentation stays: it
/// means something to the Markdown renderer.
fn cleaned(text: &str) -> String {
    let text = SPACE_BEFORE_PUNCTUATION.replace_all(text, "$1");
    let text = DOUBLED_SPACES.replace_all(&text, "$1 ");
    text.trim().to_string()
}

/// "12:04" within the first hour, "1:02:03" after it.
pub fn clock(seconds: f64) -> String {
    let total = seconds.max(0.0) as u64;
    let (hours, minutes, rest) = (total / 3_600, (total % 3_600) / 60, total % 60);
    if hours > 0 {
        format!("{hours}:{minutes:02}:{rest:02}")
    } else {
        format!("{minutes}:{rest:02}")
    }
}

/// Short ids and full UUIDs both work. Only an unambiguous match names a
/// meeting.
pub fn resolve_meeting<'a>(id: &str, meetings: &'a [Meeting]) -> Option<&'a Meeting> {
    let needle = id.to_lowercase();
    if let Ok(uuid) = Uuid::parse_str(&needle) {
        return meetings.iter().find(|meeting| meeting.id == uuid);
    }
    let compact = needle.replace('-', "");
    let mut matches = meetings
        .iter()
        .filter(|meeting| meeting.id.simple().to_string().starts_with(&compact));
    let first = matches.next()?;
    matches.next().is_none().then_some(first)
}

/// Turns the agent's `[meeting:ID@HH:MM:SS]` markers into records.md's `[n]`
/// references and citation list. Screen and file citations stay text only and
/// never name what they point at.
pub fn map_citations(answer: &str, meetings: &[Meeting]) -> (String, Vec<AskCitation>) {
    let (display, parsed) = extract_citations(answer);
    let citations = parsed
        .into_iter()
        .enumerate()
        .map(|(offset, citation)| {
            let index = offset + 1;
            let (id, seconds) = match citation {
                ParsedCitation::Meeting { id, seconds } => (id, seconds),
                ParsedCitation::Screen(_) => {
                    return AskCitation {
                        index,
                        meeting_id: None,
                        at: None,
                        label: "Screen moment".into(),
                    };
                }
                // Files are never searched for a device; a stray marker names no file.
                ParsedCitation::File(_) => {
                    return AskCitation {
                        index,
                        meeting_id: None,
                        at: None,
                        label: "File".into(),
                    };
                }
                // Agent notes are never searched for a device either.
                ParsedCitation::Note(_) => {
                    return AskCitation {
                        index,
                        meeting_id: None,
                        at: None,
                        label: "Agent note".into(),
                    };
                }
            };
            let Some(meeting) = resolve_meeting(&id, meetings) else {
                return AskCitation {
                    index,
                    meeting_id: None,
                    at: seconds,
                    label: "Meeting".into(),
                };
            };
            let when = seconds.map(clock).unwrap_or_else(|| {
                meeting
                    .started_at
                    .with_timezone(&Local)
                    .format("%b %-d, %Y")
                    .to_string()
            });
            AskCitation {
                index,
                meeting_id: Some(records::id(meeting.id)),
                at: seconds,
                label: format!("{} · {when}", meeting.display_title()),
            }
        })
        .collect();
    (display, citations)
}

/// Converts the agent's growing answer into the next piece for the phone,
/// with citation markers already numbered. A partial that is not an extension
/// of what was sent (the agent restarted its answer) sends nothing; the final
/// result replaces the streamed text anyway.
#[derive(Default)]
pub struct AnswerStream {
    sent: String,
}

impl AnswerStream {
    pub fn next(&mut self, partial: &str) -> Option<String> {
        let (display, _) = extract_citations(without_partial_marker(partial));
        if display.len() <= self.sent.len() || !display.starts_with(&self.sent) {
            return None;
        }
        let delta = display[self.sent.len()..].to_string();
        self.sent = display;
        Some(delta)
    }
}

/// A marker still being written is held back until it closes.
fn without_partial_marker(text: &str) -> &str {
    let Some(bracket) = text.rfind('[') else {
        return text;
    };
    let suffix = &text[bracket..];
    let writing = !suffix.contains(']')
        && ["[meeting:", "[meetings:", "[screen:", "[file:", "[note:"]
            .iter()
            .any(|marker| marker.starts_with(suffix) || suffix.starts_with(marker));
    if writing { &text[..bracket] } else { text }
}

// ---------------------------------------------------------------- responder

/// The answer the engine wrote and how to describe it.
pub struct EngineAnswer {
    pub text: String,
    pub engine_label: String,
    pub is_local: bool,
}

/// Runs the Ask agent. `on_text` gets the whole visible answer so far.
pub trait AskEngine: Send + Sync {
    fn answer(
        &self,
        question: &str,
        history: &[ChatMessage],
        scope: &AskScope,
        cancel: &AtomicBool,
        on_text: &mut dyn FnMut(&str),
    ) -> Result<EngineAnswer>;
}

/// The Think engine, with its existing approvals: an unapproved remote server
/// fails here exactly as it does for Ask.
pub struct LiveAskEngine {
    pub shared: Arc<crate::Shared>,
    pub models: crate::models::Models,
}

impl AskEngine for LiveAskEngine {
    fn answer(
        &self,
        question: &str,
        history: &[ChatMessage],
        scope: &AskScope,
        cancel: &AtomicBool,
        on_text: &mut dyn FnMut(&str),
    ) -> Result<EngineAnswer> {
        if !self
            .models
            .missing(&self.models.think_requirements())
            .is_empty()
        {
            anyhow::bail!(
                "Your computer needs the Think model to answer. Download it in Settings → Models, then ask again."
            );
        }
        let settings = self.shared.settings();
        let think = self.shared.think(&settings)?.with_priority(
            lokalbot_ai::remote_gate::Priority::Interactive,
            "companion ask",
        );
        let engine_label = think.model_label();
        let is_local = think.is_local();
        let mut text = String::new();
        let mut on_event = |event: AskEvent| {
            match event {
                AskEvent::Delta(delta) => text.push_str(&delta),
                AskEvent::Answer(answer) => text = answer,
                AskEvent::Activity(_) | AskEvent::Status(_) => return,
            }
            on_text(&text);
        };
        let library = &self.shared.library;
        // A CPU-only or small-window model answers in one turn, as in Ask.
        let reply = if lokalbot_ai::ask_agent::uses_tool_loop(&think) {
            lokalbot_ai::ask_agent::answer_with_tools(
                &think,
                library,
                question,
                history,
                scope,
                cancel,
                &mut on_event,
            )?
        } else {
            lokalbot_ai::ask::answer(
                &think,
                library,
                question,
                history,
                scope,
                cancel,
                &mut on_event,
            )?
        };
        Ok(EngineAnswer {
            text: reply.text,
            engine_label,
            is_local,
        })
    }
}

/// Which sources a device's question may use.
pub fn sources_for(classes: DataClasses) -> (bool, bool) {
    (classes.meetings, classes.shares_window_titles())
}

pub struct AskResponder {
    library: Library,
    engine: Arc<dyn AskEngine>,
    tasks: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
}

impl AskResponder {
    pub fn new(library: Library, engine: Arc<dyn AskEngine>) -> Self {
        Self {
            library,
            engine,
            tasks: Arc::default(),
        }
    }

    /// Checks the question against what is shared, then answers on its own
    /// thread. `sharing` is read fresh for each question.
    pub fn answer(&self, request_json: &str, sharing: Sharing, output: Arc<dyn AskOutput>) {
        let request: Option<AskRequest> = serde_json::from_str(request_json).ok();
        let Some(request) = request.filter(|r| !r.question.trim().is_empty()) else {
            output.failed("Your computer could not read this question.".into());
            return;
        };
        if !sharing.enabled || !sharing.answers_questions {
            output.failed(
                "Answering questions from your devices is turned off on your computer.".into(),
            );
            return;
        }
        let (include_meetings, include_activity) = sources_for(sharing.data_classes);
        if !include_meetings && !include_activity {
            output.failed(
                "Your computer shares no meetings or Timeline with this device, so it has nothing to answer from."
                    .into(),
            );
            return;
        }
        let now = Utc::now();
        let meetings: Vec<Meeting> = read_all_meetings(&self.library)
            .into_iter()
            .filter(|meeting| is_shared(meeting, sharing.history, now))
            .collect();
        let mut meeting_ids: Vec<Uuid> = meetings.iter().map(|meeting| meeting.id).collect();
        // The history window is the only limit: it is what the computer shares.
        let held_to = (sharing.history != HistoryWindow::All).then(|| {
            format!(
                "meetings from the last {} days, the history the user shares with this device",
                sharing.history.days()
            )
        });
        // The day or meeting a question was asked about is where the answer
        // starts, never a limit: "Ask About Today" on a tablet once answered
        // "the library has only one meeting".
        let day_label =
            |at: DateTime<Utc>| at.with_timezone(&Local).format("%-d %b %Y").to_string();
        let mut subjects: Vec<String> = Vec::new();
        let mut focus_ids: Vec<Uuid> = Vec::new();
        let request_scope = request.scope.clone().unwrap_or_default();
        if let Some(raw) = &request_scope.meeting_id {
            let found = Uuid::parse_str(raw)
                .ok()
                .and_then(|id| meetings.iter().find(|meeting| meeting.id == id));
            let Some(meeting) = found else {
                output.failed("That meeting is not shared with this device.".into());
                return;
            };
            subjects.push(format!(
                "the meeting “{}” [{}] on {}",
                meeting.display_title(),
                meeting.short_id(),
                day_label(meeting.started_at)
            ));
            focus_ids.push(meeting.id);
        }
        // An empty list means "all meetings" to Ask, and here nothing is
        // shared: an id no meeting has keeps the tools empty-handed.
        if meeting_ids.is_empty() {
            meeting_ids.push(Uuid::nil());
        }
        if let Some(key) = &request_scope.day {
            match parse_day_key(key).filter(|day| sharing.history.contains_day(*day, now)) {
                Some(day) => {
                    let (start, end) = lokalbot_core::time::local_day_bounds(day);
                    subjects.push(format!("the day {}", day_label(start)));
                    for meeting in &meetings {
                        let on_day = meeting.started_at >= start && meeting.started_at < end;
                        if on_day && !focus_ids.contains(&meeting.id) {
                            focus_ids.push(meeting.id);
                        }
                    }
                }
                None => {
                    output.failed("That day is not shared with this device.".into());
                    return;
                }
            }
        }
        let focus = (!subjects.is_empty()).then(|| QuestionFocus {
            subject: subjects.join(" and "),
            meeting_ids: focus_ids,
        });
        let scope = AskScope {
            meeting_ids,
            since: sharing.history.start(now),
            until: None,
            include_meetings,
            include_screen: false,
            include_activity,
            // A phone never gets screen search, the overnight review's memory
            // or Personal Context (`CompanionAskResponder`).
            personal_context: String::new(),
            work_memory: String::new(),
            search_by_meaning: lokalbot_core::Settings::load(&self.library.paths().settings_file())
                .semantic_search_enabled,
            // Nor the folders chosen under Files, nor coding-agent notes.
            include_files: false,
            file_folders: Vec::new(),
            include_agent_notes: false,
            screen_ids: Vec::new(),
            screen_app: None,
            attached_context: None,
            moments: Default::default(),
            // The window is named with the meetings, not as a date the
            // person could remove.
            limit: QuestionLimit::new(None, None, held_to),
            focus,
        };
        let history = history_messages(&request);
        let cancel = Arc::new(AtomicBool::new(false));
        if let Some(earlier) = self
            .tasks
            .lock()
            .insert(request.request_id.clone(), cancel.clone())
        {
            earlier.store(true, Ordering::Relaxed);
        }
        let engine = self.engine.clone();
        let tasks = self.tasks.clone();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-companion-ask".into())
            .spawn({
                let output = output.clone();
                move || {
                    run(
                        &*engine, &request, &history, &scope, &meetings, &cancel, &*output,
                    );
                    let mut tasks = tasks.lock();
                    if tasks
                        .get(&request.request_id)
                        .is_some_and(|current| Arc::ptr_eq(current, &cancel))
                    {
                        tasks.remove(&request.request_id);
                    }
                }
            });
        if spawned.is_err() {
            output.failed("Your computer could not start answering this question.".into());
        }
    }

    pub fn cancel_all(&self) {
        for (_, cancel) in self.tasks.lock().drain() {
            cancel.store(true, Ordering::Relaxed);
        }
    }
}

fn history_messages(request: &AskRequest) -> Vec<ChatMessage> {
    request
        .history
        .iter()
        .flatten()
        .filter_map(|turn| {
            let role = match turn.role.as_str() {
                "user" => ChatRole::User,
                "assistant" => ChatRole::Assistant,
                _ => return None,
            };
            Some(ChatMessage::new(role, turn.text.clone()))
        })
        .collect()
}

fn run(
    engine: &dyn AskEngine,
    request: &AskRequest,
    history: &[ChatMessage],
    scope: &AskScope,
    meetings: &[Meeting],
    cancel: &AtomicBool,
    output: &dyn AskOutput,
) {
    let mut stream = AnswerStream::default();
    let result = engine.answer(&request.question, history, scope, cancel, &mut |text| {
        if let Some(delta) = stream.next(text) {
            output.delta(delta);
        }
    });
    if cancel.load(Ordering::Relaxed) {
        output.failed("Your computer stopped answering this question.".into());
        return;
    }
    match result {
        Ok(answer) => {
            let body = finished_result(request, &answer, meetings, Utc::now());
            match encode(&body) {
                Some(json) => output.done(json),
                None => output.failed("Your computer produced an unreadable answer.".into()),
            }
        }
        Err(err) => {
            log::warn!("companion ask failed: {err:#}");
            output.failed(format!("{err:#}"));
        }
    }
}

pub fn finished_result(
    request: &AskRequest,
    answer: &EngineAnswer,
    meetings: &[Meeting],
    now: DateTime<Utc>,
) -> AskResult {
    let (text, citations) = map_citations(&answer.text, meetings);
    AskResult {
        request_id: request.request_id.clone(),
        answer: text,
        citations,
        engine_label: answer.engine_label.clone(),
        location: if answer.is_local { "mac" } else { "remote" }.to_string(),
        answered_at: instant(now),
    }
}
