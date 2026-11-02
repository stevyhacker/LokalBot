//! Reads Codex rollouts from `~/.codex/sessions/YYYY/MM/DD/*.jsonl` and
//! `~/.codex/archived_sessions/` (`CodexSessionReader.swift`).
//!
//! A rollout stays in the folder of the day it started even when it is resumed
//! weeks later, so files are selected by modification date rather than by
//! folder. Subagent threads, including approval reviewers, are skipped: their
//! parent session reports the work. Titles come from `session_index.jsonl`;
//! credentials and the internal SQLite state are never opened.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use lokalbot_core::coding_agents::CodingAgentKind;
use serde_json::Value;

use super::builder::{Event, EventKind, TimedEvent as _, Transcript, compacting_activity};
use super::cache::{self, FileSummary, ParseCache, StoredEvent};
use super::scanner::ReadResult;
use super::text::{self, Line};

/// Every file under `directory`, without entering hidden folders.
fn walk(directory: &Path, into: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let path = entry.path();
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => walk(&path, into),
            Ok(_) => into.push(path),
            Err(_) => {}
        }
    }
}

pub struct CodexReader {
    pub root: PathBuf,
}

impl CodexReader {
    pub fn transcripts(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        cache: Option<&ParseCache>,
    ) -> ReadResult {
        let mut result = ReadResult::default();
        let mut files = Vec::new();
        for folder in ["sessions", "archived_sessions"] {
            walk(&self.root.join(folder), &mut files);
        }
        let mut candidates = cache::candidate_files(files, start, end);
        candidates.sort_by(|a, b| a.path.cmp(&b.path));
        let mut selected: HashSet<PathBuf> = HashSet::new();
        for candidate in candidates {
            selected.insert(candidate.path.clone());
            match cache::summary_of(&candidate, start, cache, CodexSummary::default) {
                Ok((summary, bytes)) => {
                    if let Some(bytes) = bytes {
                        result.files_read += 1;
                        result.bytes_read += bytes;
                    }
                    if let Some(transcript) = summary.transcript(start, end) {
                        result.transcripts.push(transcript);
                    }
                }
                Err(err) => {
                    log::debug!("unreadable agent transcript: {err}");
                    result
                        .unreadable_files
                        .push(candidate.path.display().to_string());
                }
            }
        }
        let index = self.root.join("session_index.jsonl");
        selected.insert(index.clone());
        if let Some(cache) = cache {
            cache.prune(&selected, &self.root);
        }
        if !result.transcripts.is_empty() {
            let titles = thread_titles(&index, cache);
            for transcript in &mut result.transcripts {
                transcript.title = titles
                    .get(&transcript.session_id)
                    .and_then(|raw| text::title(raw));
            }
        }
        result
    }
}

/// Thread names by id; later lines are renames and win.
fn thread_titles(index: &Path, cache: Option<&ParseCache>) -> HashMap<String, String> {
    let (past, future) = (cache::distant_past(), DateTime::<Utc>::MAX_UTC);
    let Some(file) = cache::candidate_files([index.to_path_buf()], past, future)
        .into_iter()
        .next()
    else {
        return HashMap::new();
    };
    cache::summary_of(&file, past, cache, ThreadTitles::default)
        .map(|(summary, _)| summary.titles)
        .unwrap_or_default()
}

#[derive(Clone, Debug, Default)]
struct ThreadTitles {
    titles: HashMap<String, String>,
}

impl FileSummary for ThreadTitles {
    fn consume(&mut self, line: Line<'_>, _start: DateTime<Utc>) {
        let Some(record) = line.object() else {
            return;
        };
        if let (Some(id), Some(name)) = (record["id"].as_str(), record["thread_name"].as_str())
            && !name.is_empty()
        {
            self.titles.insert(id.to_string(), name.to_string());
        }
    }

    fn trim(&mut self, _start: DateTime<Utc>) {}
}

/// Opening bytes of records that never carry evidence beyond their time.
const TIMESTAMP_ONLY_MARKERS: &[&str] = &[
    r#""type":"function_call_output""#,
    r#""type":"custom_tool_call_output""#,
    r#""type":"reasoning""#,
    r#""type":"token_count""#,
    r#""type":"token_usage_record""#,
    r#""item":{"type":"Reasoning""#,
    r#""item":{"type":"AgentMessage""#,
    r#""item":{"type":"UserMessage""#,
    r#""item":{"type":"ImageView""#,
];

/// What the reader keeps of one rollout between scans: the session's id and
/// labels, and its events with redundant activity compacted away.
#[derive(Clone, Debug, Default)]
pub struct CodexSummary {
    session_id: String,
    working_directory: Option<String>,
    branch: Option<String>,
    consulted_lokalbot: bool,
    is_subagent: bool,
    events: Vec<StoredEvent>,
}

impl FileSummary for CodexSummary {
    fn consume(&mut self, line: Line<'_>, start: DateTime<Utc>) {
        if self.is_subagent {
            return;
        }
        if TIMESTAMP_ONLY_MARKERS
            .iter()
            .any(|marker| line.prefix_contains(400, marker))
        {
            if let Some(at) = line
                .string_value("timestamp")
                .as_deref()
                .and_then(text::timestamp)
                .filter(|at| *at >= start)
            {
                self.append(EventKind::Activity, at);
            }
            return;
        }
        let Some(record) = line.object() else {
            return;
        };
        let payload = &record["payload"];
        if !payload.is_object() {
            return;
        }
        let kind = record["type"].as_str();
        if kind == Some("session_meta") {
            // A subagent's `source` is an object such as
            // {"subagent":{"other":"guardian"}}; people start "vscode" or "cli".
            if payload["source"].get("subagent").is_some() {
                self.is_subagent = true;
                self.events.clear();
                return;
            }
            if let Some(id) = payload["id"].as_str() {
                self.session_id = id.to_string();
            }
            self.working_directory = payload["cwd"].as_str().map(str::to_string);
            if let Some(branch) = payload["git"]["branch"].as_str()
                && !branch.is_empty()
                && branch != "HEAD"
            {
                self.branch = Some(branch.to_string());
            }
            return;
        }
        self.inspect_for_lokalbot_access(payload);
        let Some(at) = record["timestamp"]
            .as_str()
            .and_then(text::timestamp)
            .filter(|at| *at >= start)
        else {
            return;
        };
        let before = self.events.len();
        match kind {
            Some("response_item") => self.append_response_item(payload, at),
            Some("event_msg")
                if payload["type"].as_str() == Some("item_completed")
                    && payload["item"].is_object() =>
            {
                self.append_completed_item(&payload["item"], at);
            }
            _ => {}
        }
        if self.events.len() == before {
            self.append(EventKind::Activity, at);
        }
    }

    fn finish(&mut self) {
        self.events = compacting_activity(&self.events);
    }

    fn trim(&mut self, start: DateTime<Utc>) {
        self.events.retain(|event| event.at >= start);
    }
}

impl CodexSummary {
    fn append(&mut self, kind: EventKind, at: DateTime<Utc>) {
        self.events.push(StoredEvent {
            at,
            kind,
            record: -1,
        });
    }

    fn display_path(&self, path: &str) -> String {
        text::display_path(path, self.working_directory.as_deref())
    }

    fn append_response_item(&mut self, payload: &Value, at: DateTime<Utc>) {
        match payload["type"].as_str() {
            Some("message") => {
                let role = payload["role"].as_str();
                if !matches!(role, Some("user" | "assistant")) {
                    return;
                }
                let Some(content) = payload["content"].as_array() else {
                    return;
                };
                // Codex sends injected instructions and context as separate
                // items of the same user message; each is judged on its own.
                let texts: Vec<&str> = content
                    .iter()
                    .filter(|item| {
                        matches!(item["type"].as_str(), Some("input_text" | "output_text"))
                    })
                    .filter_map(|item| item["text"].as_str())
                    .collect();
                if role == Some("user") {
                    let prompts: Vec<String> =
                        texts.iter().filter_map(|text| text::prompt(text)).collect();
                    if !prompts.is_empty() {
                        let joined = text::truncated(&prompts.join(" "), text::PROMPT_CHARACTERS);
                        self.append(EventKind::Prompt(joined), at);
                    }
                } else if let Some(reply) = text::reply(&texts.join("\n")) {
                    self.append(EventKind::Reply(reply), at);
                }
            }
            Some("function_call" | "custom_tool_call") => {
                self.append(EventKind::ToolCall, at);
                let body = payload
                    .get("arguments")
                    .or_else(|| payload.get("input"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                for path in patched_files(body) {
                    let named = self.display_path(&path);
                    self.append(EventKind::FileChange(named), at);
                }
                if let Some(command) = shell_command_in_arguments(body) {
                    for action in text::actions_in_command(&command) {
                        self.append(EventKind::Action(action), at);
                    }
                }
                for url in text::pull_request_urls(body) {
                    self.append(EventKind::PullRequest(url), at);
                }
            }
            _ => {}
        }
    }

    fn append_completed_item(&mut self, item: &Value, at: DateTime<Utc>) {
        match item["type"].as_str() {
            Some("CommandExecution") => {
                // Only the command; `aggregated_output` and friends are never read.
                let Some(command) = command_in_item(item) else {
                    return;
                };
                for action in text::actions_in_command(&command) {
                    self.append(EventKind::Action(action), at);
                }
                for url in text::pull_request_urls(&command) {
                    self.append(EventKind::PullRequest(url), at);
                }
            }
            Some("FileChange") => {
                // `changes` maps each path to its diff; only the keys are used.
                let Some(changes) = item["changes"].as_object() else {
                    return;
                };
                let mut paths: Vec<&String> = changes.keys().collect();
                paths.sort();
                for path in paths {
                    let named = self.display_path(path);
                    self.append(EventKind::FileChange(named), at);
                }
            }
            _ => {}
        }
    }

    fn inspect_for_lokalbot_access(&mut self, payload: &Value) {
        if self.consulted_lokalbot {
            return;
        }
        let item = payload.get("item").filter(|item| item.is_object());
        let server = item.and_then(|item| item["server"].as_str()).unwrap_or("");
        let name = payload["name"].as_str().unwrap_or("");
        let command = item.and_then(command_in_item).or_else(|| {
            shell_command_in_arguments(
                payload
                    .get("arguments")
                    .or_else(|| payload.get("input"))
                    .and_then(Value::as_str)
                    .unwrap_or(""),
            )
        });
        if text::reads_lokalbot_tool(server)
            || text::reads_lokalbot_tool(name)
            || text::reads_lokalbot_command(&text::unwrapped_shell_command(
                command.as_deref().unwrap_or(""),
            ))
        {
            self.consulted_lokalbot = true;
        }
    }

    /// The session's transcript inside the window, or `None` for a subagent
    /// thread or a window holding no work.
    fn transcript(&self, start: DateTime<Utc>, end: DateTime<Utc>) -> Option<Transcript> {
        if self.is_subagent || self.session_id.is_empty() {
            return None;
        }
        let events: Vec<Event> = self
            .events
            .iter()
            .filter(|stored| stored.at >= start && stored.at <= end)
            .map(|stored| Event::new(stored.at, stored.kind.clone()))
            .collect();
        if !events.iter().any(|event| !event.is_annotation()) {
            return None;
        }
        Some(Transcript {
            agent: CodingAgentKind::Codex,
            session_id: self.session_id.clone(),
            title: None,
            working_directory: self.working_directory.clone(),
            branch: self.branch.clone(),
            consulted_lokalbot: self.consulted_lokalbot,
            events,
        })
    }
}

/// A completed command as the shell ran it. Codex records the argv as an array
/// such as `["/bin/zsh", "-lc", "git push"]`; the script is last.
fn command_in_item(item: &Value) -> Option<String> {
    string_array_last(&item["command"]).or_else(|| item["command"].as_str().map(str::to_string))
}

fn string_array_last(value: &Value) -> Option<String> {
    let items = value.as_array()?;
    if !items.iter().all(Value::is_string) {
        return None;
    }
    items.last()?.as_str().map(str::to_string)
}

/// `apply_patch` names each file on a header line.
fn patched_files(body: &str) -> Vec<String> {
    if !body.contains("*** ") {
        return Vec::new();
    }
    body.split('\n')
        .filter_map(|line| {
            ["*** Update File: ", "*** Add File: "]
                .iter()
                .find_map(|header| line.strip_prefix(header))
                .map(|path| path.trim().to_string())
        })
        .collect()
}

/// Shell tools pass JSON arguments with `cmd` (string) or `command` (string or
/// argv).
fn shell_command_in_arguments(body: &str) -> Option<String> {
    if !body.starts_with('{') {
        return None;
    }
    let arguments: Value = serde_json::from_str(body).ok()?;
    let first = arguments.get("cmd").or_else(|| arguments.get("command"))?;
    first
        .as_str()
        .map(str::to_string)
        .or_else(|| string_array_last(&arguments["command"]))
}
