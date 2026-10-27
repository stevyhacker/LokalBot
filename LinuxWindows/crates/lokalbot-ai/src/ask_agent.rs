//! Ask's tool loop (`Services/Chat/ChatAgent.swift`, `MeetingChatTools.swift`).
//!
//! The model answers by calling tools — search, list and read meetings,
//! action items, screen text, app activity — one at a time, through a
//! prompt-driven JSON protocol (no native function calling), and writes its
//! answer once it has enough. Output is parsed tolerantly, a garbled tool
//! call gets one schema-constrained retry, and after six calls a final answer
//! is forced. Only sources a tool returned may be cited.
//!
//! `uses_tool_loop` decides when to use it: a CPU-only model or a small
//! context window keeps the single-turn, retrieve-first answer in `ask`.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::Result;
use chrono::{DateTime, Duration, Local, NaiveDate, Utc};
use serde_json::{Map, Value, json};
use uuid::Uuid;

use lokalbot_core::actions::OutcomeProjection;
use lokalbot_core::model::{
    ActionStatus, ChatActivity, ChatMessage, ChatRole, Meeting, Transcript,
};
use lokalbot_core::search::{DocKind, SearchQuery};
use lokalbot_core::{Library, time};

use crate::ask::{
    AskEvent, AskScope, NO_ANSWER, Sources, assistant, time_zone_name, verified, verified_partial,
};
use crate::embeddings::semantic_meeting_hits;
use crate::think::{ChatRequest, EmbeddingClient, ThinkClient};

/// Tool calls before a final answer is forced (`ChatAgent.maxSteps`).
pub const MAX_STEPS: usize = 6;
/// Below this window a few observations crowd out the answer.
pub const MIN_TOOL_LOOP_CONTEXT: u32 = 16_384;
const ANSWER_TOKENS: u32 = 2_048;
const HISTORY_MESSAGES: usize = 16;
const HISTORY_CHARACTERS: usize = 12_000;
const TRANSCRIPT_WINDOW: usize = 6_000;
pub const ANSWER_MARKER: &str = "FINAL_ANSWER:";

/// Whether this Think model should answer with the tool loop. Each step is a
/// model call, so a model on the CPU, or one with a small window, answers in
/// one retrieve-first turn instead.
pub fn uses_tool_loop(think: &ThinkClient) -> bool {
    !think.runs_on_cpu() && think.context_tokens() >= MIN_TOOL_LOOP_CONTEXT
}

// ------------------------------------------------------------- protocol

/// One callable tool advertised to the model.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolSpec {
    pub name: &'static str,
    pub summary: &'static str,
    pub arguments: &'static [(&'static str, &'static str, bool)],
}

/// A parsed tool call; every argument value is a string.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolCall {
    pub name: String,
    pub arguments: BTreeMap<String, String>,
}

impl ToolCall {
    /// Trimmed, non-empty argument value.
    pub fn string(&self, key: &str) -> Option<&str> {
        self.arguments
            .get(key)
            .map(|v| v.trim())
            .filter(|v| !v.is_empty())
    }

    pub fn int(&self, key: &str) -> Option<i64> {
        self.string(key).and_then(|v| v.parse().ok())
    }

    /// One canonical call back into the running transcript, written out by
    /// hand like macOS so key order never depends on serde_json's
    /// `preserve_order` feature (which GPUI turns on).
    pub fn json(&self) -> String {
        let encode = |text: &str| Value::from(text).to_string();
        let pairs: Vec<String> = self
            .arguments
            .iter()
            .map(|(key, value)| format!("{}: {}", encode(key), encode(value)))
            .collect();
        format!(
            "{{\"tool\": {}, \"arguments\": {{{}}}}}",
            encode(&self.name),
            pairs.join(", ")
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    Call(ToolCall),
    Answer(String),
}

const NAME_KEYS: [&str; 4] = ["tool", "name", "action", "tool_name"];
const ARGUMENT_KEYS: [&str; 5] = ["arguments", "args", "parameters", "params", "input"];
const TOOL_TOKENS: [&str; 9] = [
    "<|tool_call_start|>",
    "<|tool_call_end|>",
    "<|tool_calls_begin|>",
    "<|tool_calls_end|>",
    "<tool_call>",
    "</tool_call>",
    "<|tool_call|>",
    "[TOOL_CALLS]",
    "<|python_tag|>",
];

/// Removes `<think>…</think>` blocks, and everything after an unclosed one.
pub fn stripping_reasoning(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("<think>") {
        out.push_str(&rest[..start]);
        match rest[start..].find("</think>") {
            Some(end) => rest = &rest[start + end + "</think>".len()..],
            None => return out,
        }
    }
    out.push_str(rest);
    out
}

pub fn strip_tool_tokens(text: &str) -> String {
    let mut out = text.to_string();
    for token in TOOL_TOKENS {
        out = out.replace(token, "");
    }
    out.trim().to_string()
}

pub fn removing_answer_marker(text: &str) -> String {
    match text.strip_prefix(ANSWER_MARKER) {
        Some(rest) => rest.trim().to_string(),
        None => text.to_string(),
    }
}

/// The first balanced `{…}` in `text`, skipping braces inside strings.
pub fn extract_json_object(text: &str) -> Option<&str> {
    let start = text.find('{')?;
    let (mut depth, mut in_string, mut escaped) = (0usize, false, false);
    for (offset, c) in text[start..].char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if c == '\\' {
                escaped = true;
            } else if c == '"' {
                in_string = false;
            }
            continue;
        }
        match c {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&text[start..start + offset + 1]);
                }
            }
            _ => {}
        }
    }
    None
}

fn json_object(text: &str) -> Option<Map<String, Value>> {
    match serde_json::from_str::<Value>(extract_json_object(text)?).ok()? {
        Value::Object(map) => Some(map),
        _ => None,
    }
}

fn call_object(object: &Map<String, Value>) -> Map<String, Value> {
    match object.get("call") {
        Some(Value::Object(inner)) => inner.clone(),
        _ => object.clone(),
    }
}

fn tool_name(object: &Map<String, Value>) -> Option<String> {
    NAME_KEYS.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .map(str::to_string)
    })
}

/// Every value as a string: numbers and bools stringified, nulls dropped.
fn coerce(value: Option<&Value>) -> BTreeMap<String, String> {
    let Some(Value::Object(map)) = value else {
        return BTreeMap::new();
    };
    map.iter()
        .filter_map(|(key, value)| {
            let text = match value {
                Value::String(s) => s.clone(),
                Value::Null => return None,
                Value::Bool(b) => b.to_string(),
                Value::Number(n) => n.to_string(),
                other => other.to_string(),
            };
            Some((key.clone(), text))
        })
        .collect()
}

fn arguments(object: &Map<String, Value>) -> BTreeMap<String, String> {
    if let Some(key) = ARGUMENT_KEYS.iter().find(|k| object.contains_key(**k)) {
        return coerce(object.get(*key));
    }
    // Flat form: {"tool": "x", "query": "y"}.
    let mut flat = object.clone();
    for key in NAME_KEYS {
        flat.remove(key);
    }
    coerce(Some(&Value::Object(flat)))
}

/// `get_meeting(id='abc', include='summary')`, as many small models write
/// calls, optionally bracketed and wrapped in tool tokens.
pub fn pythonic_call(text: &str, tools: &BTreeSet<&str>) -> Option<ToolCall> {
    static CALL: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"(?s)([A-Za-z_][A-Za-z0-9_]*)\s*\(([^()]*)\)").expect("valid regex")
    });
    let stripped = strip_tool_tokens(text);
    CALL.captures_iter(&stripped).find_map(|caps| {
        let name = &caps[1];
        tools.contains(name).then(|| ToolCall {
            name: name.to_string(),
            arguments: parse_kwargs(&caps[2]),
        })
    })
}

/// `key='value', limit=5`; a lone positional value is kept as `arg0`.
pub fn parse_kwargs(body: &str) -> BTreeMap<String, String> {
    let unquote = |text: &str| -> String {
        let text = text.trim();
        let quoted = text.len() >= 2
            && ((text.starts_with('"') && text.ends_with('"'))
                || (text.starts_with('\'') && text.ends_with('\'')));
        if quoted {
            text[1..text.len() - 1].to_string()
        } else {
            text.to_string()
        }
    };
    let mut parts = Vec::new();
    let (mut current, mut quote) = (String::new(), None::<char>);
    for c in body.chars() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                }
                current.push(c);
            }
            None if c == '"' || c == '\'' => {
                quote = Some(c);
                current.push(c);
            }
            None if c == ',' => parts.push(std::mem::take(&mut current)),
            None => current.push(c),
        }
    }
    if !current.is_empty() {
        parts.push(current);
    }
    let mut result = BTreeMap::new();
    let mut positional = 0;
    for part in parts {
        let token = part.trim();
        if token.is_empty() {
            continue;
        }
        match token.split_once('=') {
            Some((key, value)) if !key.trim().is_empty() => {
                result.insert(key.trim().to_string(), unquote(value));
            }
            _ => {
                result.insert(format!("arg{positional}"), unquote(token));
                positional += 1;
            }
        }
    }
    result
}

/// One model turn as a tool call or the final answer. A call counts only for
/// a known tool, so an answer quoting JSON stays an answer.
pub fn parse(output: &str, tools: &BTreeSet<&str>) -> Action {
    let cleaned = stripping_reasoning(output).trim().to_string();
    if let Some(object) = json_object(&cleaned) {
        let call = call_object(&object);
        if let Some(name) = tool_name(&call).filter(|n| tools.contains(n.as_str())) {
            return Action::Call(ToolCall {
                name,
                arguments: arguments(&call),
            });
        }
    }
    if let Some(call) = pythonic_call(&cleaned, tools) {
        return Action::Call(call);
    }
    Action::Answer(removing_answer_marker(&strip_tool_tokens(&cleaned)))
}

/// The whole text is one tool call with no prose around it.
pub fn looks_like_bare_tool_call(text: &str) -> bool {
    static BARE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"^\[?\s*[A-Za-z_][A-Za-z0-9_]*\s*\([^()]*\)\s*\]?$")
            .expect("valid regex")
    });
    let cleaned = strip_tool_tokens(text);
    if let (Some(object), Some(raw)) = (json_object(&cleaned), extract_json_object(&cleaned))
        && tool_name(&call_object(&object)).is_some()
        && raw.chars().count() + 6 >= cleaned.chars().count()
    {
        return true;
    }
    BARE.is_match(&cleaned)
}

/// A turn that did not parse as a call but still looks like an attempt at
/// one: bare wrapper tokens, a call to an unknown name, or a call cut off.
pub fn looks_like_tool_attempt(output: &str) -> bool {
    static TRUNCATED: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r#""(tool|tool_name|action)"\s*:"#).expect("valid regex")
    });
    let cleaned = stripping_reasoning(output).trim().to_string();
    let stripped = strip_tool_tokens(&cleaned);
    if stripped.is_empty() && !cleaned.is_empty() {
        return true;
    }
    if let Some(object) = json_object(&stripped)
        && tool_name(&call_object(&object)).is_some()
    {
        return true;
    }
    if stripped.contains('{') && TRUNCATED.is_match(&stripped) {
        return true;
    }
    looks_like_bare_tool_call(&stripped)
}

/// The forced final pass: whatever prose the model wrote.
pub fn final_text(output: &str) -> String {
    let cleaned = strip_tool_tokens(&stripping_reasoning(output));
    if cleaned.is_empty() || looks_like_bare_tool_call(&cleaned) {
        return NO_ANSWER.into();
    }
    removing_answer_marker(&cleaned)
}

/// Prose to show while a turn streams: only after `FINAL_ANSWER:`, and never
/// a reasoning block, a tool call or a payload still being written.
pub fn streaming_answer(text: &str) -> Option<String> {
    static CALL_START: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"^\[?\s*[A-Za-z_][A-Za-z0-9_]*\s*\(").expect("valid regex")
    });
    let mut cleaned = text.trim();
    while cleaned.starts_with("<think>") {
        let end = cleaned.find("</think>")?;
        cleaned = cleaned[end + "</think>".len()..].trim();
    }
    if !cleaned.starts_with(ANSWER_MARKER) {
        return None;
    }
    let mut answer = removing_answer_marker(cleaned);
    if let Some(boundary) = answer.find(['<', '{', '`']) {
        answer.truncate(boundary);
    }
    let usable = answer.contains(char::is_whitespace)
        && !CALL_START.is_match(&answer)
        && !looks_like_bare_tool_call(&answer)
        && !looks_like_tool_attempt(&answer);
    usable.then_some(answer)
}

/// Forces exactly one valid call: `{"call": {"tool", "arguments"}}`, an
/// `anyOf` of closed per-tool shapes, as OpenAI strict outputs require.
pub fn tool_call_schema(tools: &[ToolSpec]) -> Value {
    let variants: Vec<Value> = tools
        .iter()
        .map(|tool| {
            let properties: Map<String, Value> = tool
                .arguments
                .iter()
                .map(|(name, description, required)| {
                    let kind = if *required {
                        json!("string")
                    } else {
                        json!(["string", "null"])
                    };
                    (
                        name.to_string(),
                        json!({"type": kind, "description": description}),
                    )
                })
                .collect();
            let names: Vec<&str> = tool.arguments.iter().map(|(n, _, _)| *n).collect();
            json!({
                "type": "object",
                "properties": {
                    "tool": {"type": "string", "enum": [tool.name]},
                    "arguments": {
                        "type": "object",
                        "properties": properties,
                        "required": names,
                        "additionalProperties": false,
                    },
                },
                "required": ["tool", "arguments"],
                "additionalProperties": false,
            })
        })
        .collect();
    json!({
        "type": "object",
        "properties": {"call": {"anyOf": variants}},
        "required": ["call"],
        "additionalProperties": false,
    })
}

// ----------------------------------------------------------------- tools

const SEARCH_MEETINGS: ToolSpec = ToolSpec {
    name: "search_meetings",
    summary: "Search across every meeting transcript, summary and title. Accepts natural-language or keyword queries; returns matching meetings with timestamps and snippets.",
    arguments: &[(
        "query",
        "What to look for, in natural language or keywords.",
        true,
    )],
};
const LIST_MEETINGS: ToolSpec = ToolSpec {
    name: "list_meetings",
    summary: "List recorded meetings, newest first, optionally filtered by a title substring.",
    arguments: &[
        ("query", "Optional case-insensitive title filter.", false),
        ("limit", "Maximum number to return (default 15).", false),
    ],
};
const GET_MEETING: ToolSpec = ToolSpec {
    name: "get_meeting",
    summary: "Read one meeting's summary, or its transcript one window at a time.",
    arguments: &[
        (
            "id",
            "Meeting id from another tool's output, or 'latest' for the most recent.",
            true,
        ),
        (
            "include",
            "What to return: 'summary' (default), 'transcript', or 'all'.",
            false,
        ),
        (
            "from",
            "Transcript start time as HH:MM:SS, to continue a long transcript or jump to a search hit (default: the beginning).",
            false,
        ),
    ],
};
const GET_ACTION_ITEMS: ToolSpec = ToolSpec {
    name: "get_action_items",
    summary: "Saved action items with completion status, decisions and open questions. Use status=done for completed work, active for outstanding work, or all for history. Give an id for one meeting, or scan recent days.",
    arguments: &[
        (
            "id",
            "Meeting id, or 'latest'. Omit to scan recent meetings.",
            false,
        ),
        (
            "days",
            "When no id: how many days back to scan (default 7).",
            false,
        ),
        (
            "status",
            "all (default), active (open or deferred), open, deferred, or done. Mixed threads include each source status.",
            false,
        ),
    ],
};
const SEARCH_SCREEN: ToolSpec = ToolSpec {
    name: "search_screen",
    summary: "Search text the user has SEEN on screen (from on-device screen captures, outside of meetings too). Returns app, window and a snippet with a timestamp.",
    arguments: &[(
        "query",
        "What to look for, in natural language or keywords.",
        true,
    )],
};
const ACTIVITY_SUMMARY: ToolSpec = ToolSpec {
    name: "activity_summary",
    summary: "How the user spent their time in apps on a given day: per-app durations, top windows, and any recorded meetings.",
    arguments: &[(
        "day",
        "'today' (default), 'yesterday', or a date like 2026-07-01.",
        false,
    )],
};

/// What a tool returned: the observation for the model, a short summary for
/// the activity row, and the sources it showed.
pub struct ToolResult {
    pub text: String,
    pub summary: String,
    pub(crate) evidence: Sources,
}

impl ToolResult {
    fn plain(text: impl Into<String>, summary: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            summary: summary.into(),
            evidence: Sources::default(),
        }
    }
}

/// The tools for one question, limited to its scope
/// (`MeetingChatTools` + `ScopedChatToolRunner`).
pub struct Tools<'a> {
    library: &'a Library,
    embedder: Option<EmbeddingClient>,
    scope: AskScope,
    now: DateTime<Utc>,
    meetings: Vec<Meeting>,
}

impl<'a> Tools<'a> {
    pub fn new(
        library: &'a Library,
        embedder: Option<EmbeddingClient>,
        scope: AskScope,
        now: DateTime<Utc>,
    ) -> Result<Self> {
        let meetings = library
            .list_meetings()?
            .into_iter()
            .filter(|m| {
                (scope.meeting_ids.is_empty() || scope.meeting_ids.contains(&m.id))
                    && scope.since.is_none_or(|s| m.started_at >= s)
                    && scope.until.is_none_or(|u| m.started_at < u)
            })
            .collect();
        Ok(Self {
            library,
            embedder,
            scope,
            now,
            meetings,
        })
    }

    pub fn specs(&self) -> Vec<ToolSpec> {
        let mut specs = Vec::new();
        if self.scope.include_meetings {
            specs.extend([
                SEARCH_MEETINGS,
                LIST_MEETINGS,
                GET_MEETING,
                GET_ACTION_ITEMS,
            ]);
        }
        if self.scope.include_screen {
            specs.push(SEARCH_SCREEN);
        }
        if self.scope.include_activity {
            specs.push(ACTIVITY_SUMMARY);
        }
        specs
    }

    /// The newest meetings in scope, so list questions need no call.
    pub fn library_overview(&self) -> String {
        if !self.scope.include_meetings {
            return String::new();
        }
        if self.meetings.is_empty() {
            return "The user has no recorded meetings yet.".into();
        }
        let count = self.meetings.len();
        let mut lines = vec![format!(
            "The user has {count} recorded meeting{}. Most recent:",
            if count == 1 { "" } else { "s" }
        )];
        for meeting in self.meetings.iter().take(12) {
            lines.push(format!(
                "- [{}] {} — {}, {}",
                meeting.short_id(),
                meeting.display_title(),
                date_label(meeting.started_at),
                time::meeting_duration_label(meeting.duration_seconds())
            ));
        }
        if count > 12 {
            lines.push(format!("- … and {} older.", count - 12));
        }
        lines.join("\n")
    }

    pub fn run(&self, call: &ToolCall) -> ToolResult {
        let result = match call.name.as_str() {
            "search_meetings" if self.scope.include_meetings => self.search(call),
            "list_meetings" if self.scope.include_meetings => Ok(self.list(call)),
            "get_meeting" if self.scope.include_meetings => self.get(call),
            "get_action_items" if self.scope.include_meetings => self.action_items(call),
            "search_screen" if self.scope.include_screen => self.search_screen(call),
            "activity_summary" if self.scope.include_activity => self.activity_summary(call),
            name => Ok(ToolResult::plain(
                format!("Unknown tool '{name}'."),
                "unknown tool",
            )),
        };
        result.unwrap_or_else(|err| {
            log::warn!("Ask tool {} failed: {err:#}", call.name);
            ToolResult::plain(
                format!("The tool failed: {err:#}"),
                format!("{} failed", call.name),
            )
        })
    }

    fn resolve(&self, reference: &str) -> Option<&Meeting> {
        let lowered = reference.trim().to_lowercase();
        if lowered == "latest" {
            return self.meetings.first();
        }
        if let Ok(id) = Uuid::parse_str(&lowered) {
            return self.meetings.iter().find(|m| m.id == id);
        }
        let compact = lowered.replace('-', "");
        let by_id: Vec<&Meeting> = self
            .meetings
            .iter()
            .filter(|m| compact.len() >= 4 && m.id.simple().to_string().starts_with(&compact))
            .collect();
        if by_id.len() == 1 {
            return Some(by_id[0]);
        }
        self.meetings
            .iter()
            .find(|m| m.display_title().to_lowercase().contains(&lowered))
    }

    fn search(&self, call: &ToolCall) -> Result<ToolResult> {
        let Some(query) = call.string("query") else {
            return Ok(ToolResult::plain(
                "Provide a 'query' argument.",
                "missing query",
            ));
        };
        let allowed: BTreeSet<Uuid> = self.meetings.iter().map(|m| m.id).collect();
        let search = SearchQuery {
            text: query.to_string(),
            kinds: None,
            meeting_ids: (!self.scope.meeting_ids.is_empty())
                .then(|| self.scope.meeting_ids.clone()),
            since: self.scope.since,
            until: self.scope.until,
            limit: 8,
        };
        let keyword: Vec<_> = self
            .library
            .search(&search)?
            .into_iter()
            .filter(|h| allowed.contains(&h.meeting_id))
            .take(8)
            .collect();
        let seen: BTreeSet<(Uuid, i64)> = keyword
            .iter()
            .map(|h| (h.meeting_id, h.start.unwrap_or(0.0) as i64))
            .collect();
        let semantic: Vec<_> = match &self.embedder {
            Some(embedder) => semantic_meeting_hits(embedder, self.library, query, 15)
                .unwrap_or_else(|err| {
                    log::warn!("meaning search unavailable for Ask: {err:#}");
                    Vec::new()
                }),
            None => Vec::new(),
        }
        .into_iter()
        .filter(|h| {
            allowed.contains(&h.meeting_id) && !seen.contains(&(h.meeting_id, h.start as i64))
        })
        .take(5)
        .collect();
        let count = keyword.len() + semantic.len();
        let mut evidence = Sources::default();
        if count == 0 {
            return Ok(ToolResult {
                text: format!("No matches for “{query}”."),
                summary: format!("“{query}” — 0 matches"),
                evidence,
            });
        }
        let title = |id: &Uuid| {
            self.meetings
                .iter()
                .find(|m| m.id == *id)
                .map(|m| m.display_title())
                .unwrap_or_else(|| "Unknown meeting".into())
        };
        let short = |id: &Uuid| id.simple().to_string()[..8].to_string();
        let mut lines = Vec::new();
        if !keyword.is_empty() {
            lines.push("Keyword matches:".to_string());
            for hit in &keyword {
                let at = (hit.kind == DocKind::Segment)
                    .then_some(hit.start)
                    .flatten();
                let stamp = at
                    .map(|s| format!(" @ {}", time::stamp(s)))
                    .unwrap_or_default();
                let who = hit
                    .speaker
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .map(|s| format!(" ({s})"))
                    .unwrap_or_default();
                lines.push(format!(
                    "- [{}] {}{stamp} [{}]{who}: {}",
                    short(&hit.meeting_id),
                    title(&hit.meeting_id),
                    hit.kind.as_str(),
                    keyword_passage(&hit.snippet, &hit.text)
                ));
                evidence.add_meeting(hit.meeting_id, &title(&hit.meeting_id), at);
            }
        }
        if !semantic.is_empty() {
            lines.push("Related (semantic) matches:".to_string());
            for hit in &semantic {
                let at = (hit.start > 0.0).then_some(hit.start);
                let stamp = at
                    .map(|s| format!(" @ {}", time::stamp(s)))
                    .unwrap_or_default();
                lines.push(format!(
                    "- [{}] {}{stamp}: {}",
                    short(&hit.meeting_id),
                    title(&hit.meeting_id),
                    clean(&hit.text)
                ));
                evidence.add_meeting(hit.meeting_id, &title(&hit.meeting_id), at);
            }
        }
        Ok(ToolResult {
            text: lines.join("\n"),
            summary: format!(
                "“{query}” — {count} match{}",
                if count == 1 { "" } else { "es" }
            ),
            evidence,
        })
    }

    fn list(&self, call: &ToolCall) -> ToolResult {
        let filter = call.string("query").map(str::to_lowercase);
        let limit = call.int("limit").unwrap_or(15).clamp(1, 50) as usize;
        let meetings: Vec<&Meeting> = self
            .meetings
            .iter()
            .filter(|m| {
                filter
                    .as_deref()
                    .is_none_or(|f| m.display_title().to_lowercase().contains(f))
            })
            .take(limit)
            .collect();
        let mut evidence = Sources::default();
        for meeting in &meetings {
            evidence.add_meeting(meeting.id, &meeting.display_title(), None);
        }
        let text = if meetings.is_empty() {
            "No meetings match.".to_string()
        } else {
            meetings
                .iter()
                .map(|m| {
                    format!(
                        "- [{}] {} — {}, {}, {}",
                        m.short_id(),
                        m.display_title(),
                        date_label(m.started_at),
                        time::meeting_duration_label(m.duration_seconds()),
                        m.app_name
                    )
                })
                .collect::<Vec<_>>()
                .join("\n")
        };
        ToolResult {
            text,
            summary: format!(
                "{} meeting{}",
                meetings.len(),
                if meetings.len() == 1 { "" } else { "s" }
            ),
            evidence,
        }
    }

    fn get(&self, call: &ToolCall) -> Result<ToolResult> {
        let reference = call.string("id").unwrap_or("latest");
        let Some(meeting) = self.resolve(reference) else {
            return Ok(ToolResult::plain(
                format!("No meeting matches '{reference}'. Use list_meetings to see ids."),
                format!("no match for {reference}"),
            ));
        };
        let title = meeting.display_title();
        let include = call.string("include").unwrap_or("summary").to_lowercase();
        let all = include.contains("all");
        let mut evidence = Sources::default();
        evidence.add_meeting(meeting.id, &title, None);
        let mut lines = vec![
            format!("# {title}"),
            format!(
                "Date: {} · Duration: {} · App: {} · ID: {}",
                date_label(meeting.started_at),
                time::meeting_duration_label(meeting.duration_seconds()),
                meeting.app_name,
                meeting.short_id()
            ),
        ];
        if all || include.contains("summary") || !include.contains("transcript") {
            lines.push(String::new());
            lines.push("## Summary".into());
            lines.push(
                self.library
                    .summary(meeting)?
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "No summary available for this meeting yet.".into()),
            );
        }
        if all || include.contains("transcript") {
            lines.push(String::new());
            lines.push("## Transcript".into());
            match self.library.transcript(meeting)? {
                Some(transcript) if !transcript.segments.is_empty() => {
                    let start = call
                        .string("from")
                        .and_then(time::parse_stamp)
                        .unwrap_or(0.0);
                    let window = transcript_window(&transcript, start, TRANSCRIPT_WINDOW);
                    if window.text.is_empty() && start > 0.0 {
                        lines.push(format!(
                            "No transcript lines at or after {}.",
                            time::stamp(start)
                        ));
                    } else {
                        lines.push(window.text);
                    }
                    for seconds in window.seconds {
                        evidence.add_meeting(meeting.id, &title, Some(seconds));
                    }
                    if let Some(next) = window.next_start {
                        lines.push(String::new());
                        lines.push(format!(
                            "[The transcript continues at {stamp}. To read on, call get_meeting with this id, include=transcript and from={stamp}.]",
                            stamp = time::stamp(next)
                        ));
                    }
                }
                _ => lines.push("No transcript available for this meeting yet.".into()),
            }
        }
        Ok(ToolResult {
            text: lines.join("\n"),
            summary: title,
            evidence,
        })
    }

    fn action_items(&self, call: &ToolCall) -> Result<ToolResult> {
        let filter = call.string("status").unwrap_or("all").to_lowercase();
        let keep = |status: ActionStatus| match filter.as_str() {
            "all" => Some(true),
            "active" => Some(status != ActionStatus::Done),
            "open" => Some(status == ActionStatus::Open),
            "deferred" => Some(status == ActionStatus::Deferred),
            "done" => Some(status == ActionStatus::Done),
            _ => None,
        };
        if keep(ActionStatus::Open).is_none() {
            return Ok(ToolResult::plain(
                "Choose status: all, active, open, deferred, or done.",
                "invalid status filter",
            ));
        }
        let (scoped, label): (Vec<&Meeting>, String) = match call.string("id") {
            Some(reference) => match self.resolve(reference) {
                Some(meeting) => (vec![meeting], meeting.display_title()),
                None => {
                    return Ok(ToolResult::plain(
                        format!("No meeting matches '{reference}'. Use list_meetings to see ids."),
                        format!("no match for {reference}"),
                    ));
                }
            },
            None if !self.scope.meeting_ids.is_empty() => {
                (self.meetings.iter().collect(), "Selected meetings".into())
            }
            None if self.scope.since.is_some() || self.scope.until.is_some() => {
                (self.meetings.iter().collect(), "the chosen dates".into())
            }
            None => {
                let days = call.int("days").unwrap_or(7).clamp(1, 90);
                let cutoff = self.now - Duration::days(days);
                (
                    self.meetings
                        .iter()
                        .filter(|m| m.started_at >= cutoff)
                        .collect(),
                    format!("last {days} days"),
                )
            }
        };
        let projections: Vec<OutcomeProjection> = scoped
            .iter()
            .filter_map(|m| self.library.outcome_projection(m).ok().flatten())
            .collect();
        let threads: Vec<_> = lokalbot_core::actions::cluster_threads(
            projections
                .iter()
                .flat_map(|p| p.action_references())
                .collect(),
        )
        .into_iter()
        .filter(|t| keep(t.status()) == Some(true))
        .collect();
        let mut evidence = Sources::default();
        let mut sections = Vec::new();
        if !threads.is_empty() {
            let mut lines = vec!["# Action threads".to_string()];
            for thread in &threads {
                let mut notes = Vec::new();
                if let Some(owner) = thread.owner.as_deref().filter(|_| !thread.is_for_user()) {
                    notes.push(format!("owner: {owner}"));
                }
                if let Some(due) = &thread.due {
                    notes.push(format!("due: {due}"));
                }
                notes.push(format!("status: {}", thread.status_label().to_lowercase()));
                let mut sources: Vec<String> = Vec::new();
                for reference in &thread.references {
                    evidence.add_meeting(reference.meeting_id, &reference.meeting_title, None);
                    let short = format!("[{}]", &reference.meeting_id.simple().to_string()[..8]);
                    if !sources.contains(&short) {
                        sources.push(short);
                    }
                }
                notes.push(format!("sources: {}", sources.join(", ")));
                if thread.is_mixed() {
                    notes.push(
                        thread
                            .references
                            .iter()
                            .map(|r| {
                                format!(
                                    "[{}]: {}",
                                    &r.meeting_id.simple().to_string()[..8],
                                    r.status.label().to_lowercase()
                                )
                            })
                            .collect::<Vec<_>>()
                            .join(", "),
                    );
                }
                lines.push(format!("- {} ({})", thread.text, notes.join(", ")));
            }
            sections.push(lines.join("\n"));
        }
        for projection in &projections {
            let outcomes = projection.corrected_outcomes();
            if outcomes.decision_records.is_empty() && outcomes.open_questions.is_empty() {
                continue;
            }
            let meeting = &projection.meeting;
            evidence.add_meeting(meeting.id, &meeting.display_title(), None);
            let mut lines = vec![format!(
                "# [{}] {} — {}",
                meeting.short_id(),
                meeting.display_title(),
                date_label(meeting.started_at)
            )];
            if !outcomes.decision_records.is_empty() {
                lines.push("Decisions:".into());
                lines.extend(
                    outcomes
                        .decision_records
                        .iter()
                        .map(|d| format!("- {}", d.text)),
                );
            }
            if !outcomes.open_questions.is_empty() {
                lines.push("Open questions:".into());
                lines.extend(outcomes.open_questions.iter().map(|q| format!("- {q}")));
            }
            sections.push(lines.join("\n"));
        }
        let text = if !sections.is_empty() {
            sections.join("\n\n")
        } else if !projections.is_empty() {
            let status = if filter == "all" {
                String::new()
            } else {
                format!("{filter} ")
            };
            format!("No {status}action items found in this scope.")
        } else {
            "No structured outcomes found. Outcomes are extracted when a meeting is summarized, so meetings that were never summarized have none.".into()
        };
        Ok(ToolResult {
            text,
            summary: format!(
                "{label} — {} action item{}",
                threads.len(),
                if threads.len() == 1 { "" } else { "s" }
            ),
            evidence,
        })
    }

    fn search_screen(&self, call: &ToolCall) -> Result<ToolResult> {
        let Some(query) = call.string("query") else {
            return Ok(ToolResult::plain(
                "Provide a 'query' argument.",
                "missing query",
            ));
        };
        let hits: Vec<_> = self
            .library
            .search_screen_hits(query, None, None, 40)?
            .into_iter()
            .filter(|h| {
                self.scope.since.is_none_or(|s| h.moment.ts >= s)
                    && self.scope.until.is_none_or(|u| h.moment.ts < u)
            })
            .take(12)
            .collect();
        let mut evidence = Sources::default();
        let text = if hits.is_empty() {
            format!(
                "No screen-text matches for “{query}”. Screen text is only kept for the configured retention window."
            )
        } else {
            let mut lines =
                vec!["Screen-text matches (from on-device screen captures):".to_string()];
            for hit in &hits {
                let moment = &hit.moment;
                evidence.screens.insert(moment.id);
                let window = if moment.window_title.is_empty() {
                    String::new()
                } else {
                    format!(" · {}", clean(&moment.window_title))
                };
                lines.push(format!(
                    "- [screen:{}] [{}{window}] {}: {}",
                    moment.id,
                    moment.app,
                    date_label(moment.ts),
                    clean(&hit.snippet)
                ));
            }
            lines.join("\n")
        };
        Ok(ToolResult {
            text,
            summary: format!(
                "“{query}” — {} screen match{}",
                hits.len(),
                if hits.len() == 1 { "" } else { "es" }
            ),
            evidence,
        })
    }

    fn activity_summary(&self, call: &ToolCall) -> Result<ToolResult> {
        let (start, end, label) = match (self.scope.since, self.scope.until) {
            (Some(since), Some(until)) => (since, until, "the chosen dates".to_string()),
            _ => {
                let argument = call.string("day").unwrap_or("today");
                let Some(day) = parse_day(argument, self.now) else {
                    return Ok(ToolResult::plain(
                        format!("Could not understand day '{argument}'."),
                        "bad day argument",
                    ));
                };
                let (start, end) = time::local_day_bounds(day);
                (start, end, day.format("%A, %b %-d, %Y").to_string())
            }
        };
        let blocks = self.library.activity_blocks(start, end)?;
        let meetings: Vec<&Meeting> = self
            .meetings
            .iter()
            .filter(|m| m.started_at >= start && m.started_at < end)
            .collect();
        let mut evidence = Sources::default();
        if blocks.is_empty() {
            return Ok(ToolResult {
                text: format!("No app activity tracked on {label}."),
                summary: format!("{label} — 0 activity blocks"),
                evidence,
            });
        }
        let mut totals: HashMap<&str, f64> = HashMap::new();
        let mut titles: HashMap<&str, HashMap<&str, f64>> = HashMap::new();
        for block in &blocks {
            let seconds = (block.end.min(end) - block.start.max(start))
                .num_milliseconds()
                .max(0) as f64
                / 1000.0;
            *totals.entry(&block.app).or_default() += seconds;
            if !block.title.is_empty() {
                *titles
                    .entry(&block.app)
                    .or_default()
                    .entry(&block.title)
                    .or_default() += seconds;
            }
        }
        let tracked: f64 = totals.values().sum();
        let mut lines = vec![
            format!("# Activity on {label}"),
            format!(
                "Tracked {} across {} app{}.",
                activity_duration(tracked),
                totals.len(),
                if totals.len() == 1 { "" } else { "s" }
            ),
        ];
        let mut apps: Vec<(&&str, &f64)> = totals.iter().collect();
        apps.sort_by(|a, b| b.1.total_cmp(a.1).then(a.0.cmp(b.0)));
        for (app, seconds) in apps.into_iter().take(10) {
            let mut top: Vec<(&&str, &f64)> = titles
                .get(*app)
                .map(|t| t.iter().collect())
                .unwrap_or_default();
            top.sort_by(|a, b| b.1.total_cmp(a.1).then(a.0.cmp(b.0)));
            let detail: Vec<String> = top.iter().take(3).map(|(t, _)| clean(t)).collect();
            let detail = if detail.is_empty() {
                String::new()
            } else {
                format!(" — {}", detail.join("; "))
            };
            lines.push(format!("- {app}: {}{detail}", activity_duration(*seconds)));
        }
        if !meetings.is_empty() {
            lines.push(String::new());
            lines.push("Recorded meetings that day:".into());
            for meeting in &meetings {
                evidence.add_meeting(meeting.id, &meeting.display_title(), None);
                lines.push(format!(
                    "- [{}] {} — {}, {}",
                    meeting.short_id(),
                    meeting.display_title(),
                    date_label(meeting.started_at),
                    time::meeting_duration_label(meeting.duration_seconds())
                ));
            }
        }
        Ok(ToolResult {
            text: lines.join("\n"),
            summary: format!(
                "{label} — {} activity block{}",
                blocks.len(),
                if blocks.len() == 1 { "" } else { "s" }
            ),
            evidence,
        })
    }
}

/// One window of a transcript from `start`: whole lines up to `limit`
/// characters, and where the next window starts when the rest did not fit
/// (`MeetingChatFormat.transcriptObservation`).
pub struct TranscriptWindow {
    pub text: String,
    pub seconds: Vec<f64>,
    pub next_start: Option<f64>,
}

pub fn transcript_window(transcript: &Transcript, start: f64, limit: usize) -> TranscriptWindow {
    let roster = transcript.speaker_roster();
    let mut window = TranscriptWindow {
        text: String::new(),
        seconds: Vec::new(),
        next_start: None,
    };
    let mut full = false;
    for segment in &transcript.segments {
        if !(segment.start.is_finite() && segment.start >= 0.0)
            || (segment.start < start && segment.end <= start)
        {
            continue;
        }
        let text = Transcript::display_text(&segment.text);
        if text.is_empty() {
            continue;
        }
        if full {
            window.next_start = Some(segment.start);
            return window;
        }
        let name = roster
            .get(&Transcript::canonical_speaker_key(&segment.speaker))
            .cloned()
            .unwrap_or_else(|| Transcript::default_speaker_name(&segment.speaker));
        let line = format!("**[{}] {name}:** {text}", time::stamp(segment.start));
        let separator = if window.text.is_empty() { 0 } else { 2 };
        let used = window.text.chars().count();
        if line.chars().count() + separator + used <= limit {
            if separator > 0 {
                window.text.push_str("\n\n");
            }
            window.text.push_str(&line);
            window.seconds.push(segment.start);
            continue;
        }
        if !window.text.is_empty() {
            window.next_start = Some(segment.start);
            return window;
        }
        // A line longer than a window is cut, and reading moves past it.
        window.text = line
            .chars()
            .take(limit.saturating_sub(1))
            .collect::<String>()
            + "…";
        window.seconds.push(segment.start);
        full = true;
    }
    window
}

/// The whole utterance around a keyword match, not just the FTS snippet,
/// so a nearby "not" is never cut away (`MeetingChatFormat.keywordPassage`).
fn keyword_passage(snippet: &str, source: &str) -> String {
    let anchor = snippet
        .replace(['«', '»'], "")
        .trim_matches('…')
        .to_string();
    if anchor.is_empty() {
        return clean(snippet);
    }
    let Some(at) = source.find(&anchor) else {
        return clean(snippet);
    };
    let start = source[..at].rfind('\n').map_or(0, |i| i + 1);
    let end = source[at + anchor.len()..]
        .find('\n')
        .map_or(source.len(), |i| at + anchor.len() + i);
    let line = source[start..end]
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if line.chars().count() <= 600 {
        line
    } else {
        clean(snippet)
    }
}

/// Without FTS markers, on one line, at most 220 characters.
fn clean(text: &str) -> String {
    let collapsed = text
        .replace(['«', '»'], "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if collapsed.chars().count() > 220 {
        collapsed.chars().take(220).collect::<String>() + "…"
    } else {
        collapsed
    }
}

fn date_label(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local)
        .format("%b %-d, %Y at %-I:%M %p")
        .to_string()
}

/// "2h 05m", "12m", "40s".
fn activity_duration(seconds: f64) -> String {
    let total = seconds.max(0.0) as u64;
    let (hours, minutes) = (total / 3_600, (total % 3_600) / 60);
    if hours > 0 {
        format!("{hours}h {minutes:02}m")
    } else if minutes > 0 {
        format!("{minutes}m")
    } else {
        format!("{total}s")
    }
}

/// 'today', 'yesterday' or `YYYY-MM-DD`.
fn parse_day(argument: &str, now: DateTime<Utc>) -> Option<NaiveDate> {
    let today = now.with_timezone(&Local).date_naive();
    match argument.trim().to_lowercase().as_str() {
        "" | "today" => Some(today),
        "yesterday" => today.pred_opt(),
        other => NaiveDate::parse_from_str(other, "%Y-%m-%d").ok(),
    }
}

// ---------------------------------------------------------------- prompt

/// `ChatPrompt.systemPrompt`: the tool catalogue, how to call tools and
/// how to cite.
pub fn system_prompt(tools: &[ToolSpec], overview: &str, inference_privacy: &str) -> String {
    let mut lines = vec![format!(
        "You are LokalBot's assistant. You answer questions about the user's on-device meeting recordings, transcripts and summaries, and about their workday context — text seen on screen and time spent in apps. The source library is stored on this PC. {inference_privacy} Be concise and specific, and cite meetings by their title and date. Never invent content — if the tools return nothing relevant, say so plainly."
    )];
    lines.push(String::new());
    lines.push("You can call tools to look things up. Available tools:".into());
    for tool in tools {
        let signature: Vec<String> = tool
            .arguments
            .iter()
            .map(|(name, _, required)| format!("{name}{}", if *required { "" } else { "?" }))
            .collect();
        lines.push(format!(
            "- {}({}): {}",
            tool.name,
            signature.join(", "),
            tool.summary
        ));
        for (name, description, required) in tool.arguments {
            lines.push(format!(
                "    • {name} ({}): {description}",
                if *required { "required" } else { "optional" }
            ));
        }
    }
    lines.push(String::new());
    lines.push(
        "How to use tools:
• To call a tool, reply with EXACTLY one JSON object and nothing else, e.g.
  {\"tool\": \"search_meetings\", \"arguments\": {\"query\": \"pricing decision\"}}
• You then receive a line starting with \"Observation:\" with the result.
• Call one tool at a time. When you have enough information, reply with your final answer in plain language — no JSON, no tool call.
• Prefer search_meetings for questions about what was said or decided. Use get_meeting to read a specific meeting's summary or transcript. Use list_meetings to enumerate meetings. Use get_action_items for to-dos, decisions, or follow-ups. Use search_screen for things the user read or saw on screen (docs, sites, code, messages). Use activity_summary for how a day was spent across apps."
            .into(),
    );
    lines.push(String::new());
    lines.push(
        "Citing sources:
• When part of your final answer comes from a specific meeting, append a citation marker right after that sentence: [meeting:ID], or [meeting:ID@HH:MM:SS] to point at a moment in the transcript. Use the exact meeting id a tool returned — never invent one. Use only a timestamp explicitly returned in an observation. The app renders markers as links; don't explain them.
• When part of your final answer comes from search_screen, append the exact [screen:ID] marker that search_screen returned. The app renders it as a private, local thumbnail linking to that captured moment. Never invent a screen id."
            .into(),
    );
    if !overview.is_empty() {
        lines.push(String::new());
        lines.push(
            "Current meeting library (navigation metadata only; call a tool before citing or describing meeting contents):".into(),
        );
        lines.push(overview.to_string());
    }
    lines.join("\n")
}

/// Lets the model resolve "yesterday" (`ChatPrompt.currentTimeLine`).
pub fn current_time_line(now: DateTime<Utc>) -> String {
    format!(
        "Current local time: {} ({}). Resolve relative dates such as \"yesterday\" or \"last Tuesday\" from it.",
        now.with_timezone(&Local).format("%A, %-d %B %Y, %H:%M"),
        time_zone_name()
    )
}

/// The newest messages within both budgets, oldest first, never starting
/// with an answer whose question was cut off (`ChatAgent.replayedHistory`).
pub fn replayed_history(
    history: &[ChatMessage],
    messages: usize,
    characters: usize,
) -> Vec<String> {
    let mut kept: Vec<&ChatMessage> = Vec::new();
    let mut used = 0;
    for message in history.iter().rev() {
        let length = message.text.chars().count();
        if kept.len() >= messages || used + length > characters {
            break;
        }
        kept.push(message);
        used += length;
    }
    if kept.last().is_some_and(|m| m.role == ChatRole::Assistant) {
        kept.pop();
    }
    kept.iter()
        .rev()
        .map(|m| {
            let speaker = if m.role == ChatRole::User {
                "User"
            } else {
                "Assistant"
            };
            format!("{speaker}: {}", m.text)
        })
        .collect()
}

fn icon(tool: &str) -> &'static str {
    match tool {
        "search_meetings" => "magnifyingglass",
        "list_meetings" => "list.bullet",
        "get_meeting" => "doc.text",
        "get_action_items" => "checklist",
        "search_screen" => "rectangle.on.rectangle",
        "activity_summary" => "calendar.day.timeline.left",
        _ => "wrench.and.screwdriver",
    }
}

/// `ChatViewModel.startLabel`.
fn start_label(call: &ToolCall) -> String {
    match call.name.as_str() {
        "search_meetings" => format!(
            "Searching meetings for “{}”",
            call.string("query").unwrap_or("")
        ),
        "list_meetings" => call
            .string("query")
            .map(|q| format!("Listing meetings matching “{q}”"))
            .unwrap_or_else(|| "Listing meetings".into()),
        "get_meeting" => format!("Reading meeting {}", call.string("id").unwrap_or("latest")),
        "get_action_items" => call
            .string("id")
            .map(|id| format!("Collecting outcomes from meeting {id}"))
            .unwrap_or_else(|| "Collecting recent outcomes".into()),
        "search_screen" => format!(
            "Searching screen text for “{}”",
            call.string("query").unwrap_or("")
        ),
        "activity_summary" => format!(
            "Summarising activity for {}",
            call.string("day").unwrap_or("today")
        ),
        other => format!("Running {other}"),
    }
}

/// `ChatViewModel.finishLabel`.
fn finish_label(tool: &str, summary: &str) -> String {
    match tool {
        "search_meetings" => format!("Searched meetings — {summary}"),
        "list_meetings" => format!("Listed {summary}"),
        "get_meeting" => format!("Read “{summary}”"),
        "get_action_items" => format!("Collected outcomes — {summary}"),
        "search_screen" => format!("Searched screen text — {summary}"),
        "activity_summary" => format!("Summarised {summary}"),
        _ => summary.to_string(),
    }
}

// ------------------------------------------------------------------ loop

/// Answers `question` with the tool loop (`ChatAgent.respond`). The visible
/// answer streams through `AskEvent::Answer`, with citations checked against
/// the sources tools returned so far.
pub fn answer_with_tools(
    think: &ThinkClient,
    library: &Library,
    question: &str,
    history: &[ChatMessage],
    scope: &AskScope,
    cancel: &AtomicBool,
    on_event: &mut dyn FnMut(AskEvent),
) -> Result<ChatMessage> {
    let now = Utc::now();
    let tools = Tools::new(library, think.embedder(), scope.clone(), now)?;
    let specs = tools.specs();
    let names: BTreeSet<&str> = specs.iter().map(|s| s.name).collect();
    let system = system_prompt(
        &specs,
        &tools.library_overview(),
        &think.inference_privacy(),
    );
    let clock = current_time_line(now);
    let mut transcript = replayed_history(history, HISTORY_MESSAGES, HISTORY_CHARACTERS);
    transcript.push(format!("User: {}", question.trim()));
    let mut evidence = Sources::default();
    let mut activity: Vec<ChatActivity> = Vec::new();

    let turn = |instruction: &str,
                transcript: &[String],
                evidence: &Sources,
                on_event: &mut dyn FnMut(AskEvent)|
     -> Result<(String, bool)> {
        let request = ChatRequest::new(
            system.clone(),
            format!("{}\n\n{clock}\n\n{instruction}", transcript.join("\n\n")),
        )
        .max_tokens(ANSWER_TOKENS)
        .keep_truncated();
        let mut raw = String::new();
        let mut shown = String::new();
        let completion = think.stream_full(&request, Some(cancel), &mut |delta| {
            raw.push_str(delta);
            if let Some(answer) = streaming_answer(&raw) {
                let visible = verified_partial(&answer, evidence);
                if visible != shown {
                    shown = visible.clone();
                    on_event(AskEvent::Answer(visible));
                }
            }
        })?;
        Ok((completion.text, completion.cancelled))
    };

    for step in 0..MAX_STEPS {
        let directive = if step == 0 {
            "Decide how to respond to the user's last message. If you need data from a tool, reply with a single tool-call JSON object; otherwise reply with your final answer."
        } else {
            "Continue. Call another tool (one JSON object) if you still need data, or give your final answer in plain language."
        };
        let instruction = format!(
            "{directive} Begin a final prose answer with {ANSWER_MARKER} on its own line. Never use this prefix for a tool call."
        );
        let (output, cancelled) = turn(&instruction, &transcript, &evidence, on_event)?;
        if cancelled || cancel.load(Ordering::Relaxed) {
            let partial = streaming_answer(&output)
                .map(|a| verified(&a, &evidence))
                .unwrap_or_default();
            return Ok(assistant(partial, activity));
        }
        let mut action = parse(&output, &names);
        if matches!(action, Action::Answer(_)) && looks_like_tool_attempt(&output) {
            // One decode-constrained second chance, never a hard gate.
            let retry = ChatRequest::new(
                system.clone(),
                format!(
                    "{}\n\n{clock}\n\nYour previous reply was not a valid tool call. Reply with exactly one JSON object of the form {{\"call\": {{\"tool\": \"…\", \"arguments\": {{ … }}}}}} for the tool you meant to call.",
                    transcript.join("\n\n")
                ),
            )
            .json_schema(tool_call_schema(&specs))
            .max_tokens(512)
            .reasoning_budget(128)
            .temperature(0.1)
            .keep_truncated();
            match think.complete_full(&retry) {
                Ok(retried) => {
                    if let Action::Call(call) = parse(&retried.text, &names) {
                        action = Action::Call(call);
                    }
                }
                Err(err) => log::info!("Ask tool-call retry failed: {err:#}"),
            }
        }
        match action {
            Action::Answer(text) => {
                let text = verified(text.trim(), &evidence);
                let text = if text.trim().is_empty() {
                    NO_ANSWER.into()
                } else {
                    text
                };
                return Ok(assistant(text, activity));
            }
            Action::Call(call) => {
                on_event(AskEvent::Answer(String::new()));
                on_event(AskEvent::Status(start_label(&call)));
                let result = tools.run(&call);
                evidence.merge(&result.evidence);
                let label = finish_label(&call.name, &result.summary);
                on_event(AskEvent::Activity(label.clone()));
                activity.push(ChatActivity {
                    id: Uuid::new_v4(),
                    tool: call.name.clone(),
                    icon: icon(&call.name).into(),
                    text: label,
                    done: true,
                });
                transcript.push(format!("Assistant: {}", call.json()));
                transcript.push(format!("Observation: {}", result.text));
            }
        }
    }

    // Out of tool calls: answer from what was gathered.
    on_event(AskEvent::Status("Writing the answer…".into()));
    let (output, _) = turn(
        &format!(
            "Give your final answer now in plain language using the observations above. Begin with {ANSWER_MARKER} on its own line. Do not call any more tools. If the observations do not cover everything the user asked, say which part you could not check."
        ),
        &transcript,
        &evidence,
        on_event,
    )?;
    Ok(assistant(
        verified(&final_text(&output), &evidence),
        activity,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};
    use std::sync::Arc;

    fn names() -> BTreeSet<&'static str> {
        [
            "search_meetings",
            "list_meetings",
            "get_meeting",
            "get_action_items",
            "search_screen",
            "activity_summary",
        ]
        .into_iter()
        .collect()
    }

    fn call(name: &str, arguments: &[(&str, &str)]) -> Action {
        Action::Call(ToolCall {
            name: name.into(),
            arguments: arguments
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        })
    }

    #[test]
    fn parses_the_json_call_forms_models_write() {
        let tools = names();
        assert_eq!(
            parse(
                r#"{"tool": "search_meetings", "arguments": {"query": "pricing"}}"#,
                &tools
            ),
            call("search_meetings", &[("query", "pricing")])
        );
        assert_eq!(
            parse(
                r#"Let me look. {"call": {"name": "list_meetings", "args": {"limit": 5, "query": null}}}"#,
                &tools
            ),
            call("list_meetings", &[("limit", "5")])
        );
        assert_eq!(
            parse(
                r#"{"action": "get_meeting", "id": "latest", "include": "all"}"#,
                &tools
            ),
            call("get_meeting", &[("id", "latest"), ("include", "all")])
        );
        assert_eq!(
            parse(
                r#"<think>maybe {"tool":"x"}</think>{"tool_name": "search_screen", "parameters": {"query": "{brace}"}}"#,
                &tools
            ),
            call("search_screen", &[("query", "{brace}")])
        );
        // An unknown name, or prose quoting JSON, stays an answer.
        assert_eq!(
            parse(r#"Use {"tool": "delete_everything"} carefully."#, &tools),
            Action::Answer(r#"Use {"tool": "delete_everything"} carefully."#.into())
        );
        assert_eq!(
            parse("FINAL_ANSWER:\nThe launch moved to May.", &tools),
            Action::Answer("The launch moved to May.".into())
        );
    }

    #[test]
    fn parses_native_function_call_forms() {
        let tools = names();
        assert_eq!(
            parse(
                "<|tool_call_start|>[get_meeting(id='abc', include=\"summary, transcript\")]<|tool_call_end|>",
                &tools
            ),
            call(
                "get_meeting",
                &[("id", "abc"), ("include", "summary, transcript")]
            )
        );
        assert_eq!(
            parse("[TOOL_CALLS] search_meetings('roadmap')", &tools),
            call("search_meetings", &[("arg0", "roadmap")])
        );
        assert_eq!(
            parse("<tool_call>Hello there</tool_call>", &tools),
            Action::Answer("Hello there".into())
        );
    }

    #[test]
    fn recognizes_garbled_tool_attempts() {
        assert!(looks_like_tool_attempt(
            r#"{"tool": "search_meeting", "arguments": {}}"#
        ));
        assert!(looks_like_tool_attempt(
            r#"{"tool": "search_meetings", "arguments": {"query": "x""#
        ));
        assert!(looks_like_tool_attempt(
            "<|tool_call_start|><|tool_call_end|>"
        ));
        assert!(looks_like_tool_attempt("search_meeting(query='x')"));
        assert!(!looks_like_tool_attempt(
            "The decision was to ship on Friday."
        ));
        assert_eq!(final_text(r#"{"tool": "list_meetings"}"#), NO_ANSWER);
        assert_eq!(
            final_text("FINAL_ANSWER: Nothing more to add."),
            "Nothing more to add."
        );
    }

    #[test]
    fn streams_only_after_the_answer_marker() {
        assert_eq!(streaming_answer("The answer is"), None);
        assert_eq!(streaming_answer("<think>planning"), None);
        assert_eq!(streaming_answer(r#"{"tool": "search_"#), None);
        assert_eq!(streaming_answer("FINAL_ANSWER:"), None);
        assert_eq!(
            streaming_answer("<think>ok</think>\nFINAL_ANSWER:\nShip it on Friday"),
            Some("Ship it on Friday".into())
        );
        assert_eq!(
            streaming_answer("FINAL_ANSWER: Ship it {\"tool\""),
            Some("Ship it ".into())
        );
        assert_eq!(
            streaming_answer("FINAL_ANSWER: search_meetings(query"),
            None
        );
    }

    #[test]
    fn the_retry_schema_closes_every_tool() {
        let schema = tool_call_schema(&[SEARCH_MEETINGS, LIST_MEETINGS]);
        let variants = schema["properties"]["call"]["anyOf"].as_array().unwrap();
        assert_eq!(variants.len(), 2);
        assert_eq!(
            variants[0]["properties"]["tool"]["enum"],
            json!(["search_meetings"])
        );
        assert_eq!(
            variants[1]["properties"]["arguments"]["required"],
            json!(["query", "limit"])
        );
        assert_eq!(
            variants[1]["properties"]["arguments"]["properties"]["limit"]["type"],
            json!(["string", "null"])
        );
        assert_eq!(variants[1]["additionalProperties"], json!(false));
    }

    #[test]
    fn replayed_history_never_starts_with_an_orphaned_answer() {
        let message = |role, text: &str| ChatMessage {
            id: Uuid::new_v4(),
            role,
            text: text.into(),
            activity: Vec::new(),
            created_at: None,
        };
        let history = vec![
            message(ChatRole::User, "first question"),
            message(ChatRole::Assistant, &"long answer ".repeat(100)),
            message(ChatRole::User, "second"),
            message(ChatRole::Assistant, "short"),
        ];
        assert_eq!(
            replayed_history(&history, 16, 100),
            ["User: second", "Assistant: short"]
        );
        assert_eq!(replayed_history(&history, 3, 10_000).len(), 2);
    }

    #[test]
    fn long_transcripts_are_read_in_windows() {
        let mut transcript = Transcript::default();
        for i in 0..40 {
            transcript.segments.push(
                serde_json::from_value(json!({
                    "start": i as f64 * 10.0, "end": i as f64 * 10.0 + 9.0,
                    "speaker": "them", "text": format!("Point number {i} about the rollout plan.")
                }))
                .unwrap(),
            );
        }
        let first = transcript_window(&transcript, 0.0, 500);
        let next = first.next_start.unwrap();
        assert!(
            first
                .text
                .starts_with("**[00:00:00] Them:** Point number 0")
        );
        assert!(first.text.chars().count() <= 500);
        let second = transcript_window(&transcript, next, 500);
        assert_eq!(second.seconds[0], next);
        let tail = transcript_window(&transcript, 395.0, 500);
        assert_eq!(tail.next_start, None);
        assert_eq!(tail.seconds, [390.0]);
    }

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

    fn props(context: u64) -> Reply {
        Reply::Json(200, json!({"n_ctx": context}))
    }

    /// `text` as the request asked for it. A rejected stream is retried
    /// without streaming, so replies depend on the prompt, never on a count.
    fn reply(body: &Value, text: &str) -> Reply {
        if body["stream"] == json!(true) {
            sse(text)
        } else {
            Reply::Json(
                200,
                json!({"choices": [{"message": {"content": text}, "finish_reason": "stop"}]}),
            )
        }
    }

    fn user_prompt(body: &Value) -> String {
        body["messages"][1]["content"]
            .as_str()
            .unwrap_or_default()
            .to_string()
    }

    fn ask(think: &ThinkClient, library: &Library, question: &str) -> (ChatMessage, Vec<AskEvent>) {
        let mut events = Vec::new();
        let message = answer_with_tools(
            think,
            library,
            question,
            &[],
            &AskScope::default(),
            &AtomicBool::new(false),
            &mut |e| events.push(e),
        )
        .unwrap();
        (message, events)
    }

    #[test]
    fn calls_a_tool_then_answers_with_verified_citations() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let northwind = library
            .list_meetings()
            .unwrap()
            .into_iter()
            .find(|m| m.title == "Customer call - Northwind")
            .unwrap();
        let full = lokalbot_core::ids::uuid_upper(&northwind.id);
        let prompts = Arc::new(parking_lot::Mutex::new(Vec::<String>::new()));
        let seen = prompts.clone();
        let server = StubServer::start(move |request| {
            if request.path.ends_with("/props") {
                return props(32_768);
            }
            let body = request.json();
            let user = user_prompt(&body);
            let mut seen = seen.lock();
            if seen.last() != Some(&user) {
                seen.push(user.clone());
            }
            let text = if user.contains("Observation: # Customer call - Northwind") {
                "FINAL_ANSWER:\nNorthwind needs SSO first [meeting:44444444@00:00:15]. The budget is approved [meeting:99999999]."
            } else if user.contains("Observation: Keyword matches") {
                r#"{"tool": "get_meeting", "arguments": {"id": "44444444", "include": "transcript"}}"#
            } else {
                r#"{"tool": "search_meetings", "arguments": {"query": "SSO rollout"}}"#
            };
            reply(&body, text)
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        assert!(uses_tool_loop(&think));
        let (message, events) = ask(&think, &library, "What does Northwind need before rollout?");
        assert_eq!(
            message.text,
            format!(
                "Northwind needs SSO first [meeting:{full}@00:00:15]. The budget is approved (source not verified)."
            )
        );
        assert_eq!(message.activity.len(), 2);
        assert_eq!(message.activity[0].tool, "search_meetings");
        assert_eq!(message.activity[1].text, "Read “Customer call - Northwind”");
        assert!(
            message.activity[0]
                .text
                .starts_with("Searched meetings — “SSO rollout” —"),
            "{}",
            message.activity[0].text
        );
        let prompts = prompts.lock();
        assert_eq!(prompts.len(), 3);
        // The summary hit alone doesn't make the 0:15 moment citable; reading
        // the transcript does.
        assert!(!prompts[1].contains("@ 00:00:15"));
        assert!(prompts[2].contains("**[00:00:15] Me:** SSO is on the Q3 roadmap."));
        assert!(prompts[0].starts_with("User: What does Northwind need before rollout?"));
        assert!(
            prompts[1].contains(
                r#"Assistant: {"tool": "search_meetings", "arguments": {"query": "SSO rollout"}}"#
            ),
            "{}",
            prompts[1]
        );
        assert!(
            prompts[1]
                .contains("Observation: Keyword matches:\n- [44444444] Customer call - Northwind")
        );
        assert!(events.iter().any(
            |e| matches!(e, AskEvent::Status(s) if s == "Searching meetings for “SSO rollout”")
        ));
        assert!(events.iter().any(|e| matches!(e, AskEvent::Answer(a) if a.contains(&format!("[meeting:{full}@00:00:15]")))));
    }

    #[test]
    fn a_garbled_call_gets_one_constrained_retry() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let retry_schema = Arc::new(parking_lot::Mutex::new(String::new()));
        let schema = retry_schema.clone();
        let server = StubServer::start(move |request| {
            if request.path.ends_with("/props") {
                return props(32_768);
            }
            let body = request.json();
            let text = if body.to_string().contains("anyOf") {
                *schema.lock() = body.to_string();
                json!({"call": {"tool": "list_meetings", "arguments": {"query": null, "limit": "2"}}})
                    .to_string()
            } else if user_prompt(&body).contains("Observation:") {
                "FINAL_ANSWER: You have recent meetings.".to_string()
            } else {
                r#"{"tool": "list_meeting", "arguments": {"limit": 2}}"#.to_string()
            };
            reply(&body, &text)
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let (message, _) = ask(&think, &library, "Which meetings did I have?");
        assert_eq!(message.text, "You have recent meetings.");
        assert_eq!(message.activity.len(), 1);
        assert_eq!(message.activity[0].text, "Listed 2 meetings");
        assert!(
            retry_schema.lock().contains("anyOf"),
            "{}",
            retry_schema.lock()
        );
    }

    #[test]
    fn a_final_answer_is_forced_after_six_calls() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let forced = Arc::new(AtomicBool::new(false));
        let flag = forced.clone();
        let server = StubServer::start(move |request| {
            if request.path.ends_with("/props") {
                return props(32_768);
            }
            let body = request.json();
            if user_prompt(&body).contains("Give your final answer now") {
                flag.store(true, Ordering::SeqCst);
                return reply(&body, "FINAL_ANSWER: Here is what I found.");
            }
            reply(&body, r#"{"tool": "list_meetings", "arguments": {}}"#)
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let (message, _) = ask(&think, &library, "Keep looking");
        assert!(forced.load(Ordering::SeqCst));
        assert_eq!(message.activity.len(), MAX_STEPS);
        assert_eq!(message.text, "Here is what I found.");
    }

    #[test]
    fn a_small_window_keeps_the_single_turn_answer() {
        let server = StubServer::start(|request| {
            if request.path.ends_with("/props") {
                return props(8_192);
            }
            Reply::Json(404, json!({}))
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        assert!(!uses_tool_loop(&think));
    }

    #[test]
    fn scope_limits_tools_and_meetings() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let scope = AskScope {
            include_meetings: false,
            include_screen: true,
            include_activity: true,
            ..AskScope::default()
        };
        let tools = Tools::new(&library, None, scope, Utc::now()).unwrap();
        let specs: Vec<&str> = tools.specs().iter().map(|s| s.name).collect();
        assert_eq!(specs, ["search_screen", "activity_summary"]);
        assert!(tools.library_overview().is_empty());
        let refused = tools.run(&ToolCall {
            name: "list_meetings".into(),
            arguments: BTreeMap::new(),
        });
        assert_eq!(refused.text, "Unknown tool 'list_meetings'.");

        let one = library.list_meetings().unwrap()[0].clone();
        let scope = AskScope {
            meeting_ids: vec![one.id],
            ..AskScope::default()
        };
        let tools = Tools::new(&library, None, scope, Utc::now()).unwrap();
        let listed = tools.run(&ToolCall {
            name: "list_meetings".into(),
            arguments: BTreeMap::new(),
        });
        assert_eq!(listed.summary, "1 meeting");
        assert!(listed.text.contains(&one.short_id()));
    }
}
