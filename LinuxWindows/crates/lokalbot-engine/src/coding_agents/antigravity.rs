//! Reads Antigravity sessions from `~/.gemini/antigravity/brain`,
//! `~/.gemini/antigravity-cli/brain`, and `~/.gemini/antigravity-ide/brain`,
//! plus sibling `annotations/<id>.pbtxt` files for conversation titles
//! (`AntigravitySessionReader.swift`).
//!
//! Only `transcript.jsonl` (never `transcript_full.jsonl`), user prompts,
//! assistant text replies, and tool call inputs for file edits, shell commands,
//! and PR tools are read. Reasoning (`thinking`), tool output, file contents,
//! credentials, settings, and databases are never opened or kept.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::Read as _;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use lokalbot_core::coding_agents::CodingAgentKind;
use serde_json::Value;

use super::builder::{Event, EventKind, TimedEvent as _, Transcript, compacting_activity};
use super::cache::{self, FileSummary, ParseCache, StoredEvent};
use super::scanner::ReadResult;
use super::text::{self, Line};

const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;
const EDIT_TOOLS: &[&str] = &[
    "write_file",
    "edit_file",
    "write_to_file",
    "replace_file_content",
    "multi_replace_file_content",
    "Write",
    "Edit",
    "MultiEdit",
];
const SHELL_TOOLS: &[&str] = &["run_command", "bash", "shell", "Bash"];

pub struct AntigravityReader {
    /// Antigravity state folders, each holding `brain/` and `annotations/`.
    pub roots: Vec<PathBuf>,
}

impl AntigravityReader {
    pub fn standard(home: &Path) -> Self {
        let gemini = home.join(".gemini");
        Self {
            roots: vec![
                gemini.join("antigravity"),
                gemini.join("antigravity-cli"),
                gemini.join("antigravity-ide"),
            ],
        }
    }

    pub fn transcripts(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        cache: Option<&ParseCache>,
    ) -> ReadResult {
        let mut result = ReadResult::default();
        // Deduplicate by conversation id across antigravity / -cli / -ide: the
        // copy written last wins so the same session is never read twice.
        let mut chosen: HashMap<String, (cache::CandidateFile, PathBuf)> = HashMap::new();
        for root in &self.roots {
            let brain = root.join("brain");
            let Ok(entries) = std::fs::read_dir(&brain) else {
                continue;
            };
            let mut files = Vec::new();
            for entry in entries.flatten() {
                if entry.file_name().to_string_lossy().starts_with('.') {
                    continue;
                }
                if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                    files.push(
                        entry
                            .path()
                            .join(".system_generated")
                            .join("logs")
                            .join("transcript.jsonl"),
                    );
                }
            }
            for candidate in cache::candidate_files(files, start, end, false) {
                let Some(id) = conversation_id(&candidate.path) else {
                    continue;
                };
                if chosen
                    .get(&id)
                    .is_none_or(|(existing, _)| existing.modified < candidate.modified)
                {
                    chosen.insert(id, (candidate, root.clone()));
                }
            }
        }

        let mut ordered: Vec<(String, cache::CandidateFile, PathBuf)> = chosen
            .into_iter()
            .map(|(id, (candidate, root))| (id, candidate, root))
            .collect();
        ordered.sort_by(|a, b| a.1.path.cmp(&b.1.path));

        let mut selected: HashSet<PathBuf> = HashSet::new();
        for (id, candidate, root) in ordered {
            selected.insert(candidate.path.clone());
            match cache::summary_of(&candidate, start, cache, AntigravitySummary::default) {
                Ok((summary, bytes)) => {
                    if let Some(bytes) = bytes {
                        result.files_read += 1;
                        result.bytes_read += bytes;
                    }
                    if let Some(mut transcript) = summary.transcript(&id, start, end) {
                        if let Some(title) = annotation_title(&id, &root) {
                            transcript.title = Some(title);
                        }
                        result.transcripts.push(transcript);
                    }
                }
                Err(err) => {
                    log::debug!("unreadable antigravity transcript: {err}");
                    result
                        .unreadable_files
                        .push(candidate.path.display().to_string());
                }
            }
        }
        if let Some(cache) = cache {
            for root in &self.roots {
                cache.prune(&selected, root);
            }
        }
        result
    }
}

fn conversation_id(transcript_path: &Path) -> Option<String> {
    // .../<root>/brain/<id>/.system_generated/logs/transcript.jsonl
    let logs = transcript_path.parent()?;
    let generated = logs.parent()?;
    let conv = generated.parent()?;
    let name = conv.file_name()?.to_string_lossy();
    (!name.is_empty()).then(|| name.into_owned())
}

/// Reads the `title: "..."` field from `<root>/annotations/<id>.pbtxt`.
pub(crate) fn annotation_title(conversation_id: &str, root: &Path) -> Option<String> {
    let path = root
        .join("annotations")
        .join(format!("{conversation_id}.pbtxt"));
    let file = File::open(&path).ok()?;
    let mut contents = String::new();
    file.take(64 * 1024).read_to_string(&mut contents).ok()?;
    for line in contents.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("title:") {
            let literal = rest.trim();
            if let Some(decoded) = decode_json_string_literal(literal) {
                return text::title(&decoded);
            }
        }
    }
    None
}

fn decode_json_string_literal(raw: &str) -> Option<String> {
    if raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"') {
        serde_json::from_str::<String>(raw).ok()
    } else {
        None
    }
}

#[derive(Clone, Debug)]
struct Record {
    at: DateTime<Utc>,
    directory: i32,
}

#[derive(Clone, Debug, Default)]
struct AntigravitySummary {
    records: Vec<Record>,
    working_directories: Vec<String>,
    events: Vec<StoredEvent>,
    consulted_lokalbot: bool,
    current_working_directory: Option<String>,
    has_explicit_cwd: bool,
}

impl FileSummary for AntigravitySummary {
    fn consume(&mut self, line: Line<'_>, start: DateTime<Utc>) {
        let interesting = line.0.len() <= MAX_LINE_BYTES
            && [
                b"\"type\":\"USER_INPUT\"".as_slice(),
                b"\"type\": \"USER_INPUT\"".as_slice(),
                b"\"type\":\"PLANNER_RESPONSE\"".as_slice(),
                b"\"type\": \"PLANNER_RESPONSE\"".as_slice(),
            ]
            .iter()
            .any(|needle| line.0.windows(needle.len()).any(|w| w == *needle));
        if !interesting {
            if let Some(at) = fast_timestamp(line)
                && at >= start
            {
                let dir = self.directory_index(self.current_working_directory.clone());
                let index = self.append_record(at, dir);
                self.append(EventKind::Activity, at, index);
            }
            return;
        }
        let Some(record) = line.object() else {
            return;
        };
        let Some(kind) = record.get("type").and_then(Value::as_str) else {
            return;
        };
        if kind == "PLANNER_RESPONSE" {
            self.inspect_for_lokalbot_access(&record);
        }
        let Some(at) = record
            .get("created_at")
            .and_then(Value::as_str)
            .and_then(text::timestamp)
        else {
            return;
        };
        if at < start {
            return;
        }
        match kind {
            "USER_INPUT" => {
                let dir = self.directory_index(self.current_working_directory.clone());
                let index = self.append_record(at, dir);
                if record.get("source").and_then(Value::as_str) == Some("SYSTEM") {
                    self.append(EventKind::Activity, at, index);
                    return;
                }
                if let Some(prompt) = record
                    .get("content")
                    .and_then(Value::as_str)
                    .and_then(text::prompt)
                {
                    self.append(EventKind::Prompt(prompt), at, index);
                } else {
                    self.append(EventKind::Activity, at, index);
                }
            }
            "PLANNER_RESPONSE" => self.append_planner_response(&record, at),
            _ => {}
        }
    }

    fn finish(&mut self) {
        self.events = compacting_activity(&self.events);
    }

    fn trim(&mut self, start: DateTime<Utc>) {
        if !self.records.iter().any(|r| r.at < start) && !self.events.iter().any(|e| e.at < start) {
            return;
        }
        let mut moved = vec![-1i32; self.records.len()];
        let mut kept = Vec::new();
        for (index, record) in self.records.iter().enumerate() {
            if record.at >= start {
                moved[index] = kept.len() as i32;
                kept.push(record.clone());
            }
        }
        self.records = kept;
        self.events = self
            .events
            .iter()
            .filter(|e| e.at >= start)
            .map(|e| {
                let mut event = e.clone();
                if event.record >= 0 {
                    event.record = moved[event.record as usize];
                }
                event
            })
            .collect();
    }
}

impl AntigravitySummary {
    fn transcript(
        &self,
        session_id: &str,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Option<Transcript> {
        let mut transcript = Transcript {
            agent: CodingAgentKind::Antigravity,
            session_id: session_id.to_string(),
            title: None,
            working_directory: None,
            branch: None,
            consulted_lokalbot: self.consulted_lokalbot,
            events: Vec::new(),
        };
        let mut labeled_by = i32::MAX;
        for (index, record) in self.records.iter().enumerate() {
            if record.at < start || record.at >= end {
                continue;
            }
            if transcript.working_directory.is_none()
                && let Some(folder) = self.directory(record.directory)
            {
                transcript.working_directory = Some(folder.to_string());
                labeled_by = index as i32;
            }
        }
        let session_folder = transcript.working_directory.as_deref();
        for stored in &self.events {
            if stored.at < start || stored.at >= end {
                continue;
            }
            if stored.record < 0 {
                transcript
                    .events
                    .push(Event::new(stored.at, stored.kind.clone()));
                continue;
            }
            let record = &self.records[stored.record as usize];
            let folder = self.directory(record.directory);
            let kind = match &stored.kind {
                EventKind::FileChange(path) if folder.is_none() => {
                    EventKind::FileChange(text::display_path(
                        path,
                        (labeled_by < stored.record)
                            .then_some(session_folder)
                            .flatten(),
                    ))
                }
                other => other.clone(),
            };
            transcript.events.push(Event {
                at: stored.at,
                kind,
                record_key: None,
                working_directory: folder.map(str::to_string),
                branch: None,
            });
        }
        transcript
            .events
            .iter()
            .any(|e| !e.is_annotation())
            .then_some(transcript)
    }

    fn append_planner_response(&mut self, record: &Value, at: DateTime<Utc>) {
        let tool_calls = record
            .get("tool_calls")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        for call in tool_calls {
            let name = call.get("name").and_then(Value::as_str).unwrap_or("");
            let args = call.get("args").and_then(Value::as_object);
            if let Some(args) = args {
                self.update_working_directory(name, args);
            }
        }
        let working_directory = self.current_working_directory.clone();
        let dir = self.directory_index(working_directory.clone());
        let index = self.append_record(at, dir);
        let mut appended = false;

        // Never read `thinking`: reasoning stays private.
        if let Some(reply) = record
            .get("content")
            .and_then(Value::as_str)
            .and_then(text::reply)
        {
            self.append(EventKind::Reply(reply), at, index);
            appended = true;
        }
        for call in tool_calls {
            appended = true;
            self.append(EventKind::ToolCall, at, index);
            let name = call.get("name").and_then(Value::as_str).unwrap_or("");
            let Some(args) = call.get("args").and_then(Value::as_object) else {
                continue;
            };
            if EDIT_TOOLS.contains(&name) {
                if let Some(path) = string_arg(args, &["Path", "TargetFile", "file_path", "path"])
                    && !is_internal_artifact_path(&path)
                {
                    let named = working_directory
                        .as_deref()
                        .map(|cwd| text::display_path(&path, Some(cwd)))
                        .unwrap_or(path);
                    self.append(EventKind::FileChange(named), at, index);
                }
            } else if SHELL_TOOLS.contains(&name) {
                if let Some(command) = command_arg(args) {
                    for action in text::actions_in_command(&command) {
                        self.append(EventKind::Action(action), at, index);
                    }
                    for url in text::pull_request_urls(&command) {
                        self.append(EventKind::PullRequest(url), at, index);
                    }
                }
            } else {
                let title = string_arg(args, &["title"]);
                let number = int_arg(args, &["number"]);
                let url = string_arg(args, &["url"]);
                let urls = string_array_arg(args, &["urls"]);
                for kind in
                    text::pull_request_events(name, title.as_deref(), number, url.as_deref(), &urls)
                {
                    self.append(kind, at, index);
                }
            }
        }
        if !appended {
            self.append(EventKind::Activity, at, index);
        }
    }

    fn update_working_directory(&mut self, tool_name: &str, args: &serde_json::Map<String, Value>) {
        if SHELL_TOOLS.contains(&tool_name)
            && let Some(cwd) = string_arg(args, &["Cwd", "cwd"])
            && let Some(valid) = usable_cwd(&cwd)
        {
            self.current_working_directory = Some(valid);
            self.has_explicit_cwd = true;
            return;
        }
        if self.has_explicit_cwd {
            return;
        }
        if let Some(dir) = string_arg(args, &["DirectoryPath", "SearchPath"])
            && let Some(inferred) = text::inferred_project_directory(&dir, true)
        {
            if self.current_working_directory.is_none() {
                self.current_working_directory = Some(inferred);
            }
            return;
        }
        if let Some(path) = string_arg(
            args,
            &["Path", "TargetFile", "AbsolutePath", "file_path", "path"],
        ) && let Some(inferred) = text::inferred_project_directory(&path, false)
            && self.current_working_directory.is_none()
        {
            self.current_working_directory = Some(inferred);
        }
    }

    fn inspect_for_lokalbot_access(&mut self, record: &Value) {
        if self.consulted_lokalbot {
            return;
        }
        let Some(calls) = record.get("tool_calls").and_then(Value::as_array) else {
            return;
        };
        for call in calls {
            let name = call.get("name").and_then(Value::as_str).unwrap_or("");
            if text::reads_lokalbot_tool(name) {
                self.consulted_lokalbot = true;
                return;
            }
            if SHELL_TOOLS.contains(&name)
                && let Some(args) = call.get("args").and_then(Value::as_object)
                && let Some(command) = command_arg(args)
                && text::reads_lokalbot_command(&command)
            {
                self.consulted_lokalbot = true;
                return;
            }
        }
    }

    fn directory(&self, index: i32) -> Option<&str> {
        (index >= 0)
            .then(|| self.working_directories.get(index as usize))
            .flatten()
            .map(String::as_str)
    }

    fn directory_index(&mut self, value: Option<String>) -> i32 {
        let Some(value) = value.filter(|v| !v.is_empty()) else {
            return -1;
        };
        if let Some(index) = self
            .working_directories
            .iter()
            .rposition(|existing| *existing == value)
        {
            return index as i32;
        }
        self.working_directories.push(value);
        (self.working_directories.len() - 1) as i32
    }

    fn append_record(&mut self, at: DateTime<Utc>, directory: i32) -> i32 {
        self.records.push(Record { at, directory });
        (self.records.len() - 1) as i32
    }

    fn append(&mut self, kind: EventKind, at: DateTime<Utc>, record: i32) {
        self.events.push(StoredEvent { at, kind, record });
    }
}

fn fast_timestamp(line: Line<'_>) -> Option<DateTime<Utc>> {
    if let Some(value) = line.string_value("created_at") {
        return text::timestamp(&value);
    }
    if line.0.len() > 65_536 {
        return None;
    }
    let marker = b"\"created_at\": \"";
    let start = line.0.windows(marker.len()).position(|w| w == marker)? + marker.len();
    let length = line.0[start..].iter().position(|b| *b == b'"')?;
    let value = std::str::from_utf8(&line.0[start..start + length]).ok()?;
    text::timestamp(value)
}

fn unquote_arg(value: &Value) -> Option<String> {
    let raw = value.as_str()?;
    if let Some(decoded) = decode_json_string_literal(raw) {
        return Some(decoded);
    }
    Some(raw.to_string())
}

fn string_arg(args: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(val) = args.get(*key).and_then(unquote_arg)
            && !val.is_empty()
        {
            return Some(val);
        }
    }
    None
}

fn int_arg(args: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<i64> {
    for key in keys {
        let Some(val) = args.get(*key) else { continue };
        if let Some(number) = val.as_i64() {
            return Some(number);
        }
        if let Some(text) = unquote_arg(val)
            && let Ok(number) = text.trim().parse::<i64>()
        {
            return Some(number);
        }
    }
    None
}

fn string_array_arg(args: &serde_json::Map<String, Value>, keys: &[&str]) -> Vec<String> {
    for key in keys {
        let Some(val) = args.get(*key) else { continue };
        if let Some(items) = val.as_array() {
            return items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect();
        }
        if let Some(raw) = val.as_str()
            && raw.starts_with('[')
            && let Ok(items) = serde_json::from_str::<Vec<String>>(raw)
        {
            return items;
        }
    }
    Vec::new()
}

fn command_arg(args: &serde_json::Map<String, Value>) -> Option<String> {
    if let Some(cmd) = string_arg(args, &["CommandLine", "command", "cmd"]) {
        return Some(cmd);
    }
    args.get("command")
        .and_then(Value::as_array)
        .and_then(|argv| argv.last())
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn usable_cwd(cwd: &str) -> Option<String> {
    let normalized = text::standardized_path(cwd, text::home_directory().as_deref());
    let lowered = normalized.to_lowercase();
    if lowered.contains("/.gemini/") || lowered.contains("/.t3/userdata/") {
        return None;
    }
    Some(normalized)
}

fn is_internal_artifact_path(path: &str) -> bool {
    let lowered = path.replace('\\', "/").to_lowercase();
    lowered.contains("/.system_generated/")
        || lowered.contains("/.gemini/antigravity")
        || lowered.contains("/.t3/userdata/")
}
