use chrono::{DateTime, Utc};
use lokalbot_core::coding_agents::{
    ACTIVE_GAP_CAP_SECONDS, CodingAgentAction, CodingAgentBurst, CodingAgentKind,
    INACTIVITY_GAP_SECONDS, STORED_FILES, STORED_PROMPTS, UNTITLED, project_name, request_title,
};
use lokalbot_core::time::local_day;

#[derive(Clone, Debug, PartialEq)]
pub enum EventKind {
    Prompt(String),
    Reply(String),
    ToolCall,
    FileChange(String),
    Action(CodingAgentAction),
    PullRequest(String),
    Activity,
}

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
    pub record_key: Option<u64>,
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

#[derive(Clone, Debug, PartialEq)]
pub struct Transcript {
    pub agent: CodingAgentKind,
    pub session_id: String,
    pub title: Option<String>,
    pub working_directory: Option<String>,
    pub branch: Option<String>,
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
        .fold(0.0, |total, gap| total + gap);
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
