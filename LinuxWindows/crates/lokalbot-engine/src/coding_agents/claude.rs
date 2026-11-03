//! Reads Claude Code sessions from `~/.claude/projects/<cwd-slug>/<id>.jsonl`
//! (`ClaudeCodeSessionReader.swift`).
//!
//! Only user prompts, the agent's text replies, tool names and inputs for file
//! edits and shell commands, titles and pull request links are read. Tool
//! results are recognised from their opening bytes and contribute only a
//! timestamp. Subagent sidechains, meta records and compaction summaries are
//! skipped.

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash as _, Hasher as _};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use lokalbot_core::coding_agents::CodingAgentKind;
use serde_json::Value;

use super::builder::{Event, EventKind, TimedEvent as _, Transcript, compacting_activity};
use super::cache::{self, FileSummary, ParseCache, StoredEvent};
use super::scanner::ReadResult;
use super::text::{self, Line};

fn listed(directory: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
        .map(|entry| entry.path())
        .collect()
}

pub struct ClaudeCodeReader {
    pub root: PathBuf,
}

impl ClaudeCodeReader {
    pub fn transcripts(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        cache: Option<&ParseCache>,
    ) -> ReadResult {
        let mut result = ReadResult::default();
        // Top level of each project folder only: subagent transcripts live in
        // per-session subfolders and are not the person's sessions.
        let files: Vec<PathBuf> = listed(&self.root)
            .into_iter()
            .flat_map(|folder| listed(&folder))
            .collect();
        // A fork or resumed session copies earlier records under their original
        // ids. Reading older files first credits that history to the session
        // where it happened.
        let mut candidates = cache::candidate_files(files, start, end);
        candidates.sort_by(|a, b| a.created.cmp(&b.created).then(a.path.cmp(&b.path)));
        let mut seen_records: HashSet<u64> = HashSet::new();
        let mut selected: HashSet<PathBuf> = HashSet::new();
        for candidate in candidates {
            selected.insert(candidate.path.clone());
            let summary = match cache::summary_of(&candidate, start, cache, ClaudeSummary::default)
            {
                Ok((summary, bytes)) => {
                    if let Some(bytes) = bytes {
                        result.files_read += 1;
                        result.bytes_read += bytes;
                    }
                    summary
                }
                Err(err) => {
                    log::debug!("unreadable agent transcript: {err}");
                    result
                        .unreadable_files
                        .push(candidate.path.display().to_string());
                    continue;
                }
            };
            // De-duplication against other files depends on the whole scan, so
            // it happens here rather than in the cached summary.
            let session_id = candidate
                .path
                .file_stem()
                .map(|stem| stem.to_string_lossy().into_owned())
                .unwrap_or_default();
            let Some((mut transcript, record_keys)) = summary.transcript(&session_id, start, end)
            else {
                continue;
            };
            transcript.events.retain(|event| {
                !event
                    .record_key
                    .is_some_and(|key| seen_records.contains(&key))
            });
            // A file whose window holds only copies claims nothing.
            if !transcript.events.iter().any(|event| !event.is_annotation()) {
                continue;
            }
            seen_records.extend(record_keys);
            result.transcripts.push(transcript);
        }
        if let Some(cache) = cache {
            cache.prune(&selected, &self.root);
        }
        result
    }
}

#[derive(Clone, Debug)]
struct Record {
    at: DateTime<Utc>,
    key: Option<u64>,
    /// Index into `labels`, or `-1` for a record naming neither.
    label: i32,
}

/// A folder and branch records ran in. Records naming the same pair share one
/// copy, so a long session holds each path once.
#[derive(Clone, Debug, PartialEq)]
struct Label {
    working_directory: Option<String>,
    branch: Option<String>,
}

const EDIT_TOOLS: &[&str] = &["Edit", "MultiEdit", "Write", "NotebookEdit"];
const TITLE_ORDER: &[&str] = &["custom", "agent", "ai", "summary"];

fn record_key(id: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    id.hash(&mut hasher);
    hasher.finish()
}

/// What the reader keeps of one session file between scans: each timed record's
/// time, id and labels, the events those records hold with redundant activity
/// compacted away, and the file's titles.
#[derive(Clone, Debug, Default)]
pub struct ClaudeSummary {
    records: Vec<Record>,
    held: HashSet<u64>,
    labels: Vec<Label>,
    events: Vec<StoredEvent>,
    /// Checked across the whole file, not just the window: text read from the
    /// library earlier can still be restated in today's replies.
    consulted_lokalbot: bool,
    title: Option<String>,
    titles: HashMap<&'static str, String>,
}

impl FileSummary for ClaudeSummary {
    fn consume(&mut self, line: Line<'_>, start: DateTime<Utc>) {
        // Tool results carry most of the bytes; read only their time.
        if line.prefix_contains(768, r#""type":"tool_result""#) {
            if line.prefix_contains(768, r#""isSidechain":true"#) {
                return;
            }
            let Some(at) = line
                .string_value("timestamp")
                .as_deref()
                .and_then(text::timestamp)
                .filter(|at| *at >= start)
            else {
                return;
            };
            let Some(key) = self.admit(line.string_value("uuid").as_deref()) else {
                return;
            };
            let record = self.append_record(at, key, -1);
            self.append(EventKind::Activity, at, record);
            return;
        }
        let Some(record) = line.object() else {
            return;
        };
        let Some(kind) = record["type"].as_str() else {
            return;
        };
        match kind {
            "custom-title" => self.set_title("custom", &record["customTitle"]),
            "agent-name" => self.set_title("agent", &record["agentName"]),
            "ai-title" => self.set_title("ai", &record["aiTitle"]),
            "summary" => self.set_title("summary", &record["summary"]),
            "pr-link" => {
                if let Some(url) = record["prUrl"].as_str()
                    && let Some(at) = record["timestamp"]
                        .as_str()
                        .and_then(text::timestamp)
                        .filter(|at| *at >= start)
                {
                    self.append(EventKind::PullRequest(url.to_string()), at, -1);
                }
            }
            "user" | "assistant" => {
                self.inspect_for_lokalbot_access(&record);
                if record["isSidechain"].as_bool() == Some(true)
                    || record["isMeta"].as_bool() == Some(true)
                    || record["isCompactSummary"].as_bool() == Some(true)
                {
                    return;
                }
                let Some(at) = record["timestamp"]
                    .as_str()
                    .and_then(text::timestamp)
                    .filter(|at| *at >= start)
                else {
                    return;
                };
                let Some(key) = self.admit(record["uuid"].as_str()) else {
                    return;
                };
                // Each record names the folder and branch it ran in; its events
                // keep them, so a burst is labeled by its own work.
                let working_directory = record["cwd"].as_str().map(str::to_string);
                let branch = record["gitBranch"]
                    .as_str()
                    .filter(|branch| !branch.is_empty() && *branch != "HEAD")
                    .map(str::to_string);
                let label = self.label_index(working_directory.clone(), branch);
                let index = self.append_record(at, key, label);
                let content = &record["message"]["content"];
                if kind == "user" {
                    self.append_prompt(content, at, index);
                } else {
                    self.append_assistant(content, at, index, working_directory.as_deref());
                }
            }
            _ => {}
        }
    }

    fn finish(&mut self) {
        self.title = TITLE_ORDER
            .iter()
            .find_map(|key| self.titles.get(key).and_then(|raw| text::title(raw)));
        self.events = compacting_activity(&self.events);
    }

    fn trim(&mut self, start: DateTime<Utc>) {
        if !self.records.iter().any(|record| record.at < start)
            && !self.events.iter().any(|event| event.at < start)
        {
            return;
        }
        let mut moved = vec![-1; self.records.len()];
        let mut kept = Vec::new();
        for (index, record) in self.records.iter().enumerate() {
            if record.at >= start {
                moved[index] = kept.len() as i32;
                kept.push(record.clone());
            }
        }
        self.records = kept;
        self.held = self.records.iter().filter_map(|r| r.key).collect();
        self.events.retain(|event| event.at >= start);
        for event in &mut self.events {
            if event.record >= 0 {
                event.record = moved[event.record as usize];
            }
        }
    }
}

impl ClaudeSummary {
    /// A record the file already holds is a copy, with the same time; it counts
    /// where it first appears. `None` for a copy.
    fn admit(&mut self, id: Option<&str>) -> Option<Option<u64>> {
        let Some(id) = id else {
            return Some(None);
        };
        let key = record_key(id);
        self.held.insert(key).then_some(Some(key))
    }

    fn set_title(&mut self, key: &'static str, value: &Value) {
        match value.as_str() {
            Some(title) => {
                self.titles.insert(key, title.to_string());
            }
            None => {
                self.titles.remove(key);
            }
        }
    }

    fn append_record(&mut self, at: DateTime<Utc>, key: Option<u64>, label: i32) -> i32 {
        self.records.push(Record { at, key, label });
        self.records.len() as i32 - 1
    }

    fn append(&mut self, kind: EventKind, at: DateTime<Utc>, record: i32) {
        self.events.push(StoredEvent { at, kind, record });
    }

    fn label_index(&mut self, working_directory: Option<String>, branch: Option<String>) -> i32 {
        if working_directory.is_none() && branch.is_none() {
            return -1;
        }
        let label = Label {
            working_directory,
            branch,
        };
        if let Some(index) = self.labels.iter().rposition(|known| *known == label) {
            return index as i32;
        }
        self.labels.push(label);
        self.labels.len() as i32 - 1
    }

    fn append_prompt(&mut self, content: &Value, at: DateTime<Utc>, record: i32) {
        let raw = if let Some(text) = content.as_str() {
            text.to_string()
        } else if let Some(blocks) = content.as_array() {
            blocks
                .iter()
                .filter(|block| block["type"].as_str() == Some("text"))
                .filter_map(|block| block["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n")
        } else {
            return;
        };
        match text::prompt(&raw) {
            Some(prompt) => self.append(EventKind::Prompt(prompt), at, record),
            None => self.append(EventKind::Activity, at, record),
        }
        // A command the person ran in the agent's terminal mode is theirs, and
        // still work in this session.
        if let Some(command) = text::terminal_command(&raw) {
            for action in text::actions_in_command(&command) {
                self.append(EventKind::Action(action), at, record);
            }
        }
    }

    /// An edited file is named relative to the record's folder. A record without
    /// one keeps the path as written, named when a window is read.
    fn append_assistant(
        &mut self,
        content: &Value,
        at: DateTime<Utc>,
        record: i32,
        working_directory: Option<&str>,
    ) {
        let Some(blocks) = content.as_array() else {
            return;
        };
        let mut appended = false;
        for block in blocks {
            match block["type"].as_str() {
                Some("text") => {
                    if let Some(reply) = block["text"].as_str().and_then(text::reply) {
                        self.append(EventKind::Reply(reply), at, record);
                        appended = true;
                    }
                }
                Some("tool_use") => {
                    appended = true;
                    self.append(EventKind::ToolCall, at, record);
                    let name = block["name"].as_str().unwrap_or("");
                    let input = &block["input"];
                    if EDIT_TOOLS.contains(&name) {
                        if let Some(path) = input
                            .get("file_path")
                            .or_else(|| input.get("notebook_path"))
                            .and_then(Value::as_str)
                        {
                            let named = working_directory.map_or_else(
                                || path.to_string(),
                                |folder| text::display_path(path, Some(folder)),
                            );
                            self.append(EventKind::FileChange(named), at, record);
                        }
                    } else if name == "Bash"
                        && let Some(command) = input["command"].as_str()
                    {
                        for action in text::actions_in_command(command) {
                            self.append(EventKind::Action(action), at, record);
                        }
                        for url in text::pull_request_urls(command) {
                            self.append(EventKind::PullRequest(url), at, record);
                        }
                    }
                }
                _ => {}
            }
        }
        if !appended {
            self.append(EventKind::Activity, at, record);
        }
    }

    fn inspect_for_lokalbot_access(&mut self, record: &Value) {
        if self.consulted_lokalbot || record["type"].as_str() != Some("assistant") {
            return;
        }
        let Some(blocks) = record["message"]["content"].as_array() else {
            return;
        };
        for block in blocks
            .iter()
            .filter(|block| block["type"].as_str() == Some("tool_use"))
        {
            let name = block["name"].as_str().unwrap_or("");
            let command = block["input"]["command"].as_str().unwrap_or("");
            if text::reads_lokalbot_tool(name)
                || (name == "Bash" && text::reads_lokalbot_command(command))
            {
                self.consulted_lokalbot = true;
                return;
            }
        }
    }

    /// The session's transcript inside the window and the ids of the records it
    /// holds there, or `None` when the window holds no work.
    fn transcript(
        &self,
        session_id: &str,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Option<(Transcript, HashSet<u64>)> {
        let inside = |at: DateTime<Utc>| at >= start && at <= end;
        let mut record_keys = HashSet::new();
        let mut working_directory = None;
        // The session is labeled by the first record naming a folder. Files a
        // record without one edited are named relative to it, once it is known.
        let mut labeled_by = i32::MAX;
        for (index, record) in self.records.iter().enumerate() {
            if !inside(record.at) {
                continue;
            }
            if let Some(key) = record.key {
                record_keys.insert(key);
            }
            if working_directory.is_none()
                && let Some(folder) = self
                    .label(record.label)
                    .and_then(|label| label.working_directory.clone())
            {
                working_directory = Some(folder);
                labeled_by = index as i32;
            }
        }
        let events: Vec<Event> = self
            .events
            .iter()
            .filter(|stored| inside(stored.at))
            .map(|stored| {
                if stored.record < 0 {
                    return Event::new(stored.at, stored.kind.clone());
                }
                let record = &self.records[stored.record as usize];
                let named = self.label(record.label);
                let kind = match &stored.kind {
                    EventKind::FileChange(path)
                        if named.is_none_or(|label| label.working_directory.is_none()) =>
                    {
                        let folder = (labeled_by < stored.record)
                            .then_some(working_directory.as_deref())
                            .flatten();
                        EventKind::FileChange(text::display_path(path, folder))
                    }
                    kind => kind.clone(),
                };
                Event {
                    at: stored.at,
                    kind,
                    record_key: record.key,
                    working_directory: named.and_then(|label| label.working_directory.clone()),
                    branch: named.and_then(|label| label.branch.clone()),
                }
            })
            .collect();
        if !events.iter().any(|event| !event.is_annotation()) {
            return None;
        }
        Some((
            Transcript {
                agent: CodingAgentKind::ClaudeCode,
                session_id: session_id.to_string(),
                title: self.title.clone(),
                working_directory,
                branch: None,
                consulted_lokalbot: self.consulted_lokalbot,
                events,
            },
            record_keys,
        ))
    }

    fn label(&self, index: i32) -> Option<&Label> {
        (index >= 0).then(|| &self.labels[index as usize])
    }
}
