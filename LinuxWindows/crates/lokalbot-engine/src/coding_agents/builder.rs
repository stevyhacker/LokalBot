//! Transcript events into bursts (`CodingAgentBurstBuilder`).

use chrono::{DateTime, Utc};
use lokalbot_core::coding_agents::{
    ACTIVE_GAP_CAP_SECONDS, CodingAgentAction, CodingAgentBurst, CodingAgentKind,
    INACTIVITY_GAP_SECONDS, STORED_FILES, STORED_PROMPTS, UNTITLED, project_name, request_title,
};
use lokalbot_core::time::local_day;

/// One timestamped fact from a transcript. Tool output, file contents, reasoning
/// and injected system or developer text never become events.
#[derive(Clone, Debug, PartialEq)]
pub enum EventKind {
    Prompt(String),
    Reply(String),
    ToolCall,
    FileChange(String),
    Action(CodingAgentAction),
    /// A pull request the agent associated with the session. Claude Code emits
    /// these links again every turn, so they annotate work but never start,
    /// extend or keep alive a burst on their own.
    PullRequest(String),
    /// Timestamp-only evidence that the agent was working, such as a tool
    /// result whose content is deliberately not read.
    Activity,
}

/// An event's time and kind, as activity compaction reads them.
pub trait TimedEvent {
    fn at(&self) -> DateTime<Utc>;
    fn kind(&self) -> &EventKind;

    fn is_annotation(&self) -> bool {
        matches!(self.kind(), EventKind::PullRequest(_))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub at: DateTime<Utc>,
    pub kind: EventKind,
    /// The source record's hashed id, for dropping copies a fork or resumed
    /// session carries. Hashes are per process and never persisted.
    pub record_key: Option<u64>,
    /// The folder and branch the source record names, for readers whose records
    /// carry them. A burst is labeled from its own records, so a session that
    /// moves on never relabels work that already settled.
    pub working_directory: Option<String>,
    pub branch: Option<String>,
}

impl Event {
    pub fn new(at: DateTime<Utc>, kind: EventKind) -> Self {
        Self {
            at,
            kind,
            record_key: None,
            working_directory: None,
            branch: None,
        }
    }
}

impl TimedEvent for Event {
    fn at(&self) -> DateTime<Utc> {
        self.at
    }

    fn kind(&self) -> &EventKind {
        &self.kind
    }
}

/// One parsed session, with events already clipped to the requested days.
#[derive(Clone, Debug, PartialEq)]
pub struct Transcript {
    pub agent: CodingAgentKind,
    pub session_id: String,
    pub title: Option<String>,
    /// Session-wide labels, for bursts whose events carry none.
    pub working_directory: Option<String>,
    pub branch: Option<String>,
    /// The session read LokalBot's own library through its CLI or MCP. Its
    /// replies may restate library content, so they are withheld to keep the
    /// digest from consuming its own output.
    pub consulted_lokalbot: bool,
    pub events: Vec<Event>,
}

fn seconds(from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
    (to - from).num_milliseconds() as f64 / 1000.0
}

pub fn bursts(transcript: &Transcript) -> Vec<CodingAgentBurst> {
    let mut ordered: Vec<&Event> = transcript.events.iter().collect();
    ordered.sort_by_key(|event| event.at);
    let mut groups: Vec<Vec<&Event>> = Vec::new();
    for event in ordered.iter().copied().filter(|e| !e.is_annotation()) {
        match groups.last_mut() {
            Some(group)
                if group
                    .last()
                    .is_some_and(|last| seconds(last.at, event.at) <= INACTIVITY_GAP_SECONDS) =>
            {
                group.push(event);
            }
            _ => groups.push(vec![event]),
        }
    }
    // Annotations join the burst that was active when they were written; a link
    // written again while nothing else happened is dropped.
    for annotation in ordered.iter().copied().filter(|e| e.is_annotation()) {
        let group = groups.iter_mut().rev().find(|group| {
            let (Some(first), Some(last)) = (group.first(), group.last()) else {
                return false;
            };
            annotation.at >= first.at && seconds(last.at, annotation.at) <= INACTIVITY_GAP_SECONDS
        });
        if let Some(group) = group {
            group.push(annotation);
        }
    }
    let title = transcript
        .title
        .as_deref()
        .map(str::trim)
        .filter(|title| !title.is_empty())
        .map(str::to_string)
        .or_else(|| {
            ordered.iter().find_map(|event| match &event.kind {
                EventKind::Prompt(text) => Some(request_title(text)),
                _ => None,
            })
        })
        .unwrap_or_else(|| UNTITLED.to_string());
    groups
        .iter()
        .filter_map(|group| burst(group, transcript, &title))
        .collect()
}

fn burst(events: &[&Event], transcript: &Transcript, title: &str) -> Option<CodingAgentBurst> {
    let mut prompts: Vec<String> = Vec::new();
    let mut prompt_count = 0;
    let mut reply: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    let mut actions: Vec<CodingAgentAction> = Vec::new();
    let mut pull_requests: Vec<String> = Vec::new();
    let mut tool_calls = 0;
    for event in events {
        match &event.kind {
            EventKind::Prompt(text) => {
                prompt_count += 1;
                if prompts.len() < STORED_PROMPTS {
                    prompts.push(text.clone());
                }
            }
            EventKind::Reply(text) => reply = Some(text.clone()),
            EventKind::ToolCall => tool_calls += 1,
            EventKind::FileChange(path) => {
                if !files.contains(path) {
                    files.push(path.clone());
                }
            }
            EventKind::Action(action) => {
                if !actions.contains(action) {
                    actions.push(action.clone());
                }
            }
            EventKind::PullRequest(url) => {
                if !pull_requests.contains(url) {
                    pull_requests.push(url.clone());
                }
            }
            EventKind::Activity => {}
        }
    }
    if transcript.consulted_lokalbot {
        reply = None;
    }
    if prompt_count == 0 && reply.is_none() && files.is_empty() && actions.is_empty() {
        return None;
    }
    let times: Vec<DateTime<Utc>> = events
        .iter()
        .filter(|event| !event.is_annotation())
        .map(|event| event.at)
        .collect();
    let (start, end) = (*times.first()?, *times.last()?);
    let active = times
        .windows(2)
        .map(|pair| seconds(pair[0], pair[1]).min(ACTIVE_GAP_CAP_SECONDS))
        // Not `sum`: an empty float sum is -0.0, which would reach the payload.
        .fold(0.0, |total, gap| total + gap);
    // A scan reads a window of days, and a long session changes branch and
    // folder within it. Labels from the session as a whole would relabel this
    // burst on every such change and as the window slides.
    let working_directory = events
        .iter()
        .find_map(|event| event.working_directory.clone())
        .or_else(|| transcript.working_directory.clone());
    let branch = events
        .iter()
        .rev()
        .find_map(|event| event.branch.clone())
        .or_else(|| transcript.branch.clone());
    let changed_file_count = files.len();
    files.truncate(STORED_FILES);
    Some(CodingAgentBurst {
        actions,
        active_duration: active,
        agent: transcript.agent,
        branch,
        changed_file_count,
        changed_files: files,
        end,
        final_reply: reply,
        project: project_name(working_directory.as_deref()),
        prompt_count,
        prompts,
        pull_requests,
        session_id: transcript.session_id.clone(),
        start,
        title: title.to_string(),
        tool_call_count: tool_calls,
    })
}

/// Drops timestamp-only events that change neither a burst boundary nor its
/// active time. A ping is redundant when the events either side of it are
/// within the active-gap cap of each other: the gaps it splits count in full
/// either way. Busy sessions log thousands of tool results, so this keeps cached
/// transcripts small without changing any burst.
///
/// Bursts are cut at midnight, so a ping is kept when its neighbours fall on
/// different days: otherwise the next day's first event, or the scan window's
/// start, would move the edge of a burst already saved.
pub fn compacting_activity<E: TimedEvent + Clone>(events: &[E]) -> Vec<E> {
    let annotations: Vec<E> = events
        .iter()
        .filter(|event| event.is_annotation())
        .cloned()
        .collect();
    let mut ordered: Vec<&E> = events
        .iter()
        .filter(|event| !event.is_annotation())
        .collect();
    ordered.sort_by_key(|event| event.at());
    if ordered.len() <= 2 {
        return ordered.into_iter().cloned().chain(annotations).collect();
    }
    let mut kept: Vec<E> = vec![ordered[0].clone()];
    for index in 1..ordered.len() - 1 {
        let event = ordered[index];
        let next = ordered[index + 1];
        if matches!(event.kind(), EventKind::Activity)
            && let Some(previous) = kept.last()
            && seconds(previous.at(), next.at()) <= ACTIVE_GAP_CAP_SECONDS
            && local_day(previous.at()) == local_day(next.at())
        {
            continue;
        }
        kept.push(event.clone());
    }
    kept.push(ordered[ordered.len() - 1].clone());
    kept.extend(annotations);
    kept
}
