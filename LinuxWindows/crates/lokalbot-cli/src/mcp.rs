//! The stdio MCP server (`MCPProtocol.swift`, `MCPDispatcher.swift`,
//! `FileLibraryToolProvider.swift`): newline-delimited JSON-RPC 2.0. The
//! handshake and `tools/list` always work; meeting tools need the meeting
//! grant, screen tools the separate screen grant.

use std::io::{BufRead as _, Write as _};

use chrono::{DateTime, Utc};
use lokalbot_core::access::{self, ScreenScope};
use serde_json::{Value, json};

use crate::session::{
    GetOptions, Session, day_bounds, local_day, local_now_day, seconds_from_stamp,
};
use crate::{ask, briefing, json as swift_json, personal, reports, screen, search, session};

pub const PROTOCOL_VERSIONS: [&str; 3] = ["2024-11-05", "2025-03-26", "2025-06-18"];
pub const MAXIMUM_RECORD_BYTES: usize = 1_048_576;
pub const INSTRUCTIONS: &str = "LokalBot is the user's local memory of their meetings, screen, and what they shared about themselves. At the start of a session, call get_briefing. Before asking the user about past work, decisions, commitments, or where something stands, search LokalBot first.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolErrorCode {
    AccessDisabled,
    ScreenAccessDisabled,
    PersonalContextDisabled,
    PersonalContextUnavailable,
    ScreenMemoryUnavailable,
    ScreenshotNotFound,
    AppNotRunning,
    EngineUnavailable,
    ModelLoadingTimeout,
    MeetingNotFound,
    AmbiguousId,
    UnknownTool,
    InvalidArguments,
}

impl ToolErrorCode {
    pub fn raw(self) -> &'static str {
        match self {
            Self::AccessDisabled => "access_disabled",
            Self::ScreenAccessDisabled => "screen_access_disabled",
            Self::PersonalContextDisabled => "personal_context_disabled",
            Self::PersonalContextUnavailable => "personal_context_unavailable",
            Self::ScreenMemoryUnavailable => "screen_memory_unavailable",
            Self::ScreenshotNotFound => "screenshot_not_found",
            Self::AppNotRunning => "app_not_running",
            Self::EngineUnavailable => "engine_unavailable",
            Self::ModelLoadingTimeout => "model_loading_timeout",
            Self::MeetingNotFound => "meeting_not_found",
            Self::AmbiguousId => "ambiguous_id",
            Self::UnknownTool => "unknown_tool",
            Self::InvalidArguments => "invalid_arguments",
        }
    }
}

/// A `tools/call` result in MCP content form.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolResult {
    pub text: String,
    pub is_error: bool,
}

impl ToolResult {
    pub fn text(text: &str) -> Self {
        Self {
            text: text.to_string(),
            is_error: false,
        }
    }

    /// `[<code>] <message>`.
    pub fn error(code: ToolErrorCode, message: &str) -> Self {
        Self {
            text: format!("[{}] {message}", code.raw()),
            is_error: true,
        }
    }

    pub fn json(&self) -> Value {
        json!({"content": [{"type": "text", "text": self.text}], "isError": self.is_error})
    }
}

/// Tools in `tools/list` order with their descriptions and schemas.
pub fn tools() -> Vec<Value> {
    let tool = |name: &str, description: &str, schema: Value| json!({"name": name, "description": description, "inputSchema": schema});
    vec![
        tool(
            briefing::TOOL_NAME,
            briefing::DESCRIPTION,
            json!({"type": "object", "properties": {}}),
        ),
        tool(
            "list_meetings",
            "List recorded meetings, newest first. Returns id, title, date, and duration for each; include \"summary\" adds each meeting's summary, so one call covers several meetings.",
            json!({"type": "object", "properties": {
                "limit": {"type": "integer", "description": format!("Maximum meetings to return (default 20; with summaries default {}, at most {}).", session::DEFAULT_SUMMARY_LIST_COUNT, session::MAXIMUM_SUMMARY_LIST_COUNT)},
                "include": {"type": "string", "description": format!("\"summary\" adds each meeting's summary. The summaries share {} characters; a cut one has summary_truncated, and get_meeting reads it whole.", session::LIST_SUMMARY_BUDGET)},
                "since": {"type": "string", "description": "Only meetings on or after this local calendar day (YYYY-MM-DD)."},
                "query": {"type": "string", "description": "Case-insensitive title substring filter."},
            }}),
        ),
        tool(
            "get_meeting",
            "Fetch one meeting as markdown. Sections: metadata, summary, transcript. A long transcript comes in windows of max_characters; a cut window ends with the transcript_from value that continues it.",
            json!({"type": "object", "properties": {
                "id": {"type": "string", "description": "Short id from list_meetings, full UUID, or \"latest\"."},
                "include": {"type": "string", "description": "Comma-separated subset of metadata,summary,transcript. Default: all three."},
                "transcript_from": {"type": "string", "description": "Optional HH:MM:SS; the transcript starts at the first line at or after it."},
                "max_characters": {"type": "integer", "description": "Transcript characters per call (default 40,000, maximum 200,000)."},
            }, "required": ["id"]}),
        ),
        tool(
            "search_meetings",
            "Word search across meeting titles, summaries, and transcripts. Meetings with every query word (any order, case- and accent-insensitive) come first, then partial matches; rare words weigh more, exact-phrase hits lead, and ties keep recency. Words of up to three letters or digits match only whole words. Wrap the query in double quotes for an exact phrase. Hits carry kind, snippet, and timestamp; one meeting gives at most five transcript hits.",
            json!({"type": "object", "properties": {
                "query": {"type": "string", "description": "Text to search for."},
                "limit": {"type": "integer", "description": "Maximum hits (default 50)."},
            }, "required": ["query"]}),
        ),
        tool(
            "ask_library",
            "Ask a question and get an answer synthesized by LokalBot's local model from the meeting library, with meeting citations — raw transcripts never leave this computer. Needs the LokalBot app running; the first call may take up to a minute while the model loads.",
            json!({"type": "object", "properties": {
                "question": {"type": "string", "description": "The question to answer from the user's meetings."},
            }, "required": ["question"]}),
        ),
        tool(
            "get_action_items",
            "List action items extracted from recent meetings, with the user's saved corrections and status applied. Overdue and soon-due work comes first. Due phrases are resolved to a date only when unambiguous (due_date); otherwise only the spoken phrase is returned.",
            json!({"type": "object", "properties": {
                "status": {"type": "string", "description": "active (default: open or deferred), open, deferred, done, or all."},
                "owner": {"type": "string", "description": "\"me\" for the user's own commitments, \"others\", or a participant name substring. Default: anyone."},
                "days": {"type": "integer", "description": "Meetings from the last N days (default 30, maximum 365). Ignored with meeting_id."},
                "meeting_id": {"type": "string", "description": "Optional short id or full UUID to limit results to one meeting."},
                "limit": {"type": "integer", "description": "Maximum action threads (default 50, maximum 200)."},
            }}),
        ),
        tool(
            "list_people",
            "List people the user meets, joined from calendar attendee names, speaker names applied in LokalBot, and action owners. Returns names, meeting counts, last meeting, and open-action counts in each direction. Email addresses are never returned.",
            json!({"type": "object", "properties": {
                "query": {"type": "string", "description": "Optional name substring."},
                "limit": {"type": "integer", "description": "Maximum people (default 50, maximum 200)."},
            }}),
        ),
        tool(
            "get_person",
            "One person's open commitments in both directions (what the user owes them and what they owe the user), recent decisions made in small meetings together, and shared meetings.",
            json!({"type": "object", "properties": {
                "person": {"type": "string", "description": "Person id from list_people, or a name."},
            }, "required": ["person"]}),
        ),
        tool(
            "search_screen",
            "Search locally captured screen text and window titles. Returns text snippets and context metadata only; never pixels or encrypted file paths. Repeated captures of the same window and text count once. Requires the separate screen-memory permission.",
            json!({"type": "object", "properties": {
                "query": {"type": "string", "description": "Text to search for."},
                "day": {"type": "string", "description": "Optional local calendar day (YYYY-MM-DD)."},
                "app": {"type": "string", "description": "Optional app-name substring."},
                "limit": {"type": "integer", "description": "Maximum hits (default 40, maximum 200)."},
            }, "required": ["query"]}),
        ),
        tool(
            "get_timeline",
            "Get activity blocks and screen-context metadata for one local calendar day, oldest first. No pixels or encrypted file paths are returned. A list cut at the limit sets activity_truncated or screenshots_truncated; call again with after set to its last ended_at or captured_at to continue. Requires the separate screen-memory permission.",
            json!({"type": "object", "properties": {
                "day": {"type": "string", "description": "Local calendar day (YYYY-MM-DD); defaults to today."},
                "after": {"type": "string", "description": "Optional ISO 8601 time; return only what follows it within the day."},
                "limit": {"type": "integer", "description": "Maximum activity blocks and screenshots (default 200, maximum 500)."},
            }}),
        ),
        tool(
            "get_recent_activity",
            "Get recent app/window activity blocks, newest first. Requires the separate screen-memory permission.",
            json!({"type": "object", "properties": {
                "minutes": {"type": "integer", "description": "Lookback window in minutes (default 120, maximum 10080)."},
                "limit": {"type": "integer", "description": "Maximum blocks (default 50, maximum 200)."},
            }}),
        ),
        tool(
            "get_app_usage",
            "Aggregate tracked time by app for one local calendar day. Requires the separate screen-memory permission.",
            json!({"type": "object", "properties": {
                "day": {"type": "string", "description": "Local calendar day (YYYY-MM-DD); defaults to today."},
                "limit": {"type": "integer", "description": "Maximum apps (default 30, maximum 100)."},
            }}),
        ),
        tool(
            "get_screenshot_detail",
            "Get captured text and metadata for one context-moment id. It reports whether encrypted pixels exist but never returns decrypted pixels or a file path. Requires the separate screen-memory permission.",
            json!({"type": "object", "properties": {
                "snapshot_id": {"type": "integer", "description": "Screenshot id returned by search_screen or get_timeline."},
            }, "required": ["snapshot_id"]}),
        ),
        tool(
            personal::NAME,
            "Get what the user shared about themselves (facts, preferences, goals, principles) that is relevant to a task, most relevant first. Only items the user marked as shared are returned. The user writes and shares them, under a separate permission, in the Mac app; the Windows and Linux app has neither, so there they come only from a library that came from a Mac.",
            json!({"type": "object", "properties": {
                "task": {"type": "string", "description": "What you are helping with, in a sentence (for example \"Evaluate a job offer\")."},
                "kinds": {"type": "array", "items": {"type": "string", "enum": ["fact", "preference", "goal", "principle"]}, "description": "Optional: only these kinds."},
                "max_items": {"type": "integer", "description": format!("Maximum items (default {}, maximum {}).", personal::DEFAULT_ITEMS, personal::MAXIMUM_ITEMS)},
            }, "required": ["task"]}),
        ),
    ]
}

const MEETING_TOOLS: &[&str] = &[
    "list_meetings",
    "get_meeting",
    "search_meetings",
    "ask_library",
    "get_action_items",
    "list_people",
    "get_person",
];
const SCREEN_TOOLS: &[&str] = &[
    "search_screen",
    "get_timeline",
    "get_recent_activity",
    "get_app_usage",
    "get_screenshot_detail",
];

/// JSON numbers that are exact integers.
fn int_value(value: &Value) -> Option<i64> {
    if let Some(i) = value.as_i64() {
        return Some(i);
    }
    let f = value.as_f64()?;
    (f.fract() == 0.0 && f.abs() <= 9_007_199_254_740_991.0).then_some(f as i64)
}

fn bounded(arguments: &Value, name: &str, default: i64, maximum: i64) -> Result<i64, ToolResult> {
    match arguments.get(name) {
        None | Some(Value::Null) => Ok(default),
        Some(raw) => int_value(raw)
            .filter(|v| (1..=maximum).contains(v))
            .ok_or_else(|| {
                ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    &format!("\"{name}\" must be an integer between 1 and {maximum}."),
                )
            }),
    }
}

fn read_failure(err: anyhow::Error) -> ToolResult {
    ToolResult::error(
        ToolErrorCode::MeetingNotFound,
        &format!("Could not read the meeting library: {err}"),
    )
}

fn screen_failure(err: anyhow::Error) -> ToolResult {
    ToolResult::error(
        ToolErrorCode::ScreenMemoryUnavailable,
        &format!("Could not read local screen memory: {err:#}"),
    )
}

/// Pretty, sorted, unescaped slashes, ISO dates (screen-memory encoder).
fn screen_json<T: serde::Serialize>(value: &T) -> String {
    swift_json::pretty(value, false)
}

pub struct Provider {
    pub session: Session,
    /// Fixed clock for tests.
    pub now: Option<DateTime<Utc>>,
}

impl Provider {
    fn now(&self) -> DateTime<Utc> {
        self.now.unwrap_or_else(Utc::now)
    }

    fn meetings_authorized(&self) -> bool {
        access::meetings_access_authorized(&self.session.paths)
    }

    fn screen_cutoff(&self) -> Option<DateTime<Utc>> {
        match access::screen_access_scope(&self.session.paths)? {
            ScreenScope::Today => Some(session::today_start()),
            ScreenScope::RecentWeek => Some(self.now() - chrono::Duration::days(7)),
            ScreenScope::RetainedHistory => None,
        }
    }

    fn scoped(
        &self,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> Option<(DateTime<Utc>, DateTime<Utc>)> {
        let start = match self.screen_cutoff() {
            Some(cutoff) => start.max(cutoff),
            None => start,
        };
        (end > start).then_some((start, end))
    }

    fn day_interval(
        &self,
        arguments: &Value,
        name: &str,
    ) -> Result<(DateTime<Utc>, DateTime<Utc>), ToolResult> {
        let day = match arguments.get(name) {
            None | Some(Value::Null) => local_now_day(),
            Some(raw) => raw.as_str().and_then(local_day).ok_or_else(|| {
                ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    &format!("\"{name}\" must be a real local calendar day formatted YYYY-MM-DD."),
                )
            })?,
        };
        Ok(day_bounds(day))
    }

    pub fn briefing(&self) -> String {
        briefing::render(
            &self.session,
            self.meetings_authorized(),
            self.now(),
            briefing::Vocabulary::Mcp,
        )
    }

    pub fn call(&self, name: &str, arguments: &Value) -> ToolResult {
        if MEETING_TOOLS.contains(&name) && !self.meetings_authorized() {
            return ToolResult::error(
                ToolErrorCode::AccessDisabled,
                access::MEETINGS_DISABLED_MESSAGE,
            );
        }
        if SCREEN_TOOLS.contains(&name)
            && access::screen_access_scope(&self.session.paths).is_none()
        {
            return ToolResult::error(
                ToolErrorCode::ScreenAccessDisabled,
                access::SCREEN_DISABLED_MESSAGE,
            );
        }
        let result = match name {
            "list_meetings" => self.list_meetings(arguments),
            "get_meeting" => self.get_meeting(arguments),
            "search_meetings" => self.search_meetings(arguments),
            "ask_library" => match arguments
                .get("question")
                .and_then(Value::as_str)
                .map(str::trim)
            {
                Some(question) if !question.is_empty() => Ok(ask::ask(&self.session, question)),
                _ => Err(ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    "ask_library requires a non-empty \"question\" string.",
                )),
            },
            "get_action_items" => self.action_items(arguments),
            "list_people" => self.list_people(arguments),
            "get_person" => self.get_person(arguments),
            "search_screen" => self.search_screen(arguments),
            "get_timeline" => self.timeline(arguments),
            "get_recent_activity" => self.recent_activity(arguments),
            "get_app_usage" => self.app_usage(arguments),
            "get_screenshot_detail" => self.screenshot_detail(arguments),
            personal::NAME => self.personal_context(arguments),
            briefing::TOOL_NAME => Ok(ToolResult::text(&self.briefing())),
            _ => {
                let names: Vec<String> = tools()
                    .iter()
                    .filter_map(|t| t["name"].as_str().map(str::to_string))
                    .collect();
                Err(ToolResult::error(
                    ToolErrorCode::UnknownTool,
                    &format!("No tool named \"{name}\". Available: {}.", names.join(", ")),
                ))
            }
        };
        result.unwrap_or_else(|failure| failure)
    }

    fn list_meetings(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let include = arguments
            .get("include")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let include_summary = session::list_includes_summary(include).map_err(|err| {
            ToolResult::error(
                ToolErrorCode::InvalidArguments,
                &match err {
                    session::ListIncludeError::Transcript => "list_meetings doesn't include transcripts. Read one meeting's with get_meeting.".to_string(),
                    session::ListIncludeError::Unknown(values) => format!(
                        "Unknown include value(s): {}. list_meetings takes \"summary\".",
                        values.join(", ")
                    ),
                },
            )
        })?;
        let mut meetings = self.session.meetings().map_err(read_failure)?;
        if let Some(query) = arguments
            .get("query")
            .and_then(Value::as_str)
            .filter(|q| !q.is_empty())
        {
            let needle = query.to_lowercase();
            meetings.retain(|m| m.title.to_lowercase().contains(&needle));
        }
        if let Some(raw) = arguments.get("since").filter(|v| !v.is_null()) {
            let text = raw.as_str().unwrap_or_default();
            let Some(day) = local_day(text) else {
                return Err(ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    &format!(
                        "\"since\" must be a real local calendar day formatted YYYY-MM-DD, got \"{text}\"."
                    ),
                ));
            };
            let start = day_bounds(day).0;
            meetings.retain(|m| m.started_at >= start);
        }
        let limit = if include_summary {
            bounded(
                arguments,
                "limit",
                session::DEFAULT_SUMMARY_LIST_COUNT as i64,
                session::MAXIMUM_SUMMARY_LIST_COUNT as i64,
            )?
        } else {
            bounded(arguments, "limit", 20, 1000)?
        } as usize;
        meetings.truncate(limit);
        Ok(ToolResult::text(&session::list_json(
            &self.session,
            &meetings,
            include_summary,
        )))
    }

    fn get_meeting(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let Some(id) = arguments
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && id.chars().count() <= 64)
        else {
            return Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                "get_meeting requires an \"id\" string (short id, full UUID, or \"latest\").",
            ));
        };
        let mut options = match arguments
            .get("include")
            .and_then(Value::as_str)
            .filter(|i| !i.is_empty())
        {
            None => GetOptions::all(),
            Some(include) => {
                let parts: Vec<String> = include
                    .to_lowercase()
                    .split(',')
                    .map(|p| p.trim().to_string())
                    .collect();
                GetOptions {
                    include_summary: parts.iter().any(|p| p == "summary"),
                    include_transcript: parts.iter().any(|p| p == "transcript"),
                    include_metadata: parts.iter().any(|p| p == "metadata"),
                    transcript_characters: None,
                    transcript_from: None,
                }
            }
        };
        options.transcript_characters =
            Some(bounded(arguments, "max_characters", 40_000, 200_000)? as usize);
        if let Some(raw) = arguments.get("transcript_from").filter(|v| !v.is_null()) {
            let seconds = raw.as_str().and_then(seconds_from_stamp).ok_or_else(|| {
                ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    "\"transcript_from\" must be a time such as 00:42:10.",
                )
            })?;
            options.transcript_from = Some(seconds);
        }
        let meetings = self.session.meetings().map_err(read_failure)?;
        let needle = id.to_lowercase();
        if needle != "latest" && uuid::Uuid::parse_str(&needle).is_err() {
            let matches = self.session.prefix_matches(&needle, &meetings);
            if matches.len() > 1 {
                return Err(ToolResult::error(
                    ToolErrorCode::AmbiguousId,
                    &format!(
                        "\"{id}\" matches several meetings ({}). Use a longer id.",
                        matches.join(", ")
                    ),
                ));
            }
        }
        let Some(meeting) = self.session.find(id, &meetings) else {
            return Err(ToolResult::error(
                ToolErrorCode::MeetingNotFound,
                &format!(
                    "No meeting matches \"{id}\". Use list_meetings or search_meetings to find ids."
                ),
            ));
        };
        Ok(ToolResult::text(&session::get_markdown(
            &self.session,
            &meeting,
            &options,
        )))
    }

    fn search_meetings(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let query = arguments
            .get("query")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        if query.is_empty() || query.chars().count() > search::MAXIMUM_QUERY_CHARACTERS {
            return Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                &format!(
                    "search_meetings requires a non-empty \"query\" string of at most {} characters.",
                    search::MAXIMUM_QUERY_CHARACTERS
                ),
            ));
        }
        let limit = bounded(
            arguments,
            "limit",
            search::DEFAULT_LIMIT as i64,
            search::MAXIMUM_SEARCH_HITS as i64,
        )?;
        let meetings = self.session.meetings().map_err(read_failure)?;
        let hits = search::hits(
            &self.session,
            query,
            limit as usize,
            &meetings,
            Some(search::MAXIMUM_TRANSCRIPT_HITS_PER_MEETING),
            true,
        );
        Ok(ToolResult::text(&session::search_json(&hits)))
    }

    fn action_items(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let mut filter = reports::ActionFilter::default();
        if let Some(raw) = arguments.get("status").and_then(Value::as_str) {
            filter.status = reports::StatusFilter::parse(raw).ok_or_else(|| {
                ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    "\"status\" must be one of all, active, open, deferred, or done.",
                )
            })?;
        }
        if let Some(owner) = arguments.get("owner").and_then(Value::as_str) {
            if owner.chars().count() > 120 {
                return Err(ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    "\"owner\" must be at most 120 characters.",
                ));
            }
            filter.owner = reports::OwnerFilter::parse(Some(owner));
        }
        filter.days = bounded(
            arguments,
            "days",
            i64::from(reports::DEFAULT_DAYS),
            i64::from(reports::MAXIMUM_DAYS),
        )? as u32;
        filter.limit = bounded(arguments, "limit", 50, reports::MAXIMUM_ENTRIES as i64)? as usize;
        let meetings = self.session.meetings().map_err(read_failure)?;
        if let Some(id) = arguments
            .get("meeting_id")
            .and_then(Value::as_str)
            .filter(|i| !i.is_empty())
        {
            let found = (id.chars().count() <= 64)
                .then(|| self.session.find(id, &meetings))
                .flatten();
            let Some(meeting) = found else {
                return Err(ToolResult::error(
                    ToolErrorCode::MeetingNotFound,
                    &format!(
                        "No meeting matches \"{id}\". Use list_meetings or search_meetings to find ids."
                    ),
                ));
            };
            filter.meeting_id = Some(meeting.id);
        }
        let entries = reports::action_entries(&self.session, &meetings, &filter, self.now());
        Ok(ToolResult::text(&reports::actions_json(&entries)))
    }

    fn list_people(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let query = arguments.get("query").and_then(Value::as_str);
        if query.is_some_and(|q| q.chars().count() > 120) {
            return Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                "\"query\" must be at most 120 characters.",
            ));
        }
        let limit = bounded(arguments, "limit", 50, reports::MAXIMUM_ENTRIES as i64)? as usize;
        let people = self.session.library.people().map_err(read_failure)?;
        Ok(ToolResult::text(&swift_json::pretty(
            &reports::person_summaries(&people, query, limit),
            true,
        )))
    }

    fn get_person(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let needle = arguments
            .get("person")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        if needle.is_empty() || needle.chars().count() > 120 {
            return Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                "get_person requires a \"person\" id or name of at most 120 characters.",
            ));
        }
        let people = self.session.library.people().map_err(read_failure)?;
        let Some(person) = reports::find_person(needle, &people) else {
            return Err(ToolResult::error(
                ToolErrorCode::MeetingNotFound,
                &format!("No single person matches \"{needle}\". Use list_people to find ids."),
            ));
        };
        Ok(ToolResult::text(&swift_json::pretty(
            &reports::person_detail(person, self.now()),
            true,
        )))
    }

    fn search_screen(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let query = arguments
            .get("query")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or("");
        if query.is_empty() || query.chars().count() > search::MAXIMUM_QUERY_CHARACTERS {
            return Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                &format!(
                    "search_screen requires a non-empty \"query\" string of at most {} characters.",
                    search::MAXIMUM_QUERY_CHARACTERS
                ),
            ));
        }
        let limit = bounded(arguments, "limit", 40, 200)? as usize;
        let interval = match arguments.get("day") {
            None | Some(Value::Null) => None,
            Some(_) => Some(self.day_interval(arguments, "day")?),
        };
        let app = arguments.get("app").and_then(Value::as_str).map(str::trim);
        if app.is_some_and(|a| a.chars().count() > 200) {
            return Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                "\"app\" must be at most 200 characters.",
            ));
        }
        let scoped = interval.and_then(|(s, e)| self.scoped(s, e));
        if interval.is_some() && scoped.is_none() {
            return Ok(ToolResult::text(&screen_json(
                &Vec::<screen::SearchHit>::new(),
            )));
        }
        let cutoff = self.screen_cutoff();
        let reader = screen::ScreenReader::new(self.session.paths.root());
        let raw = reader
            .search(
                query,
                scoped.map(|s| s.0).or(cutoff),
                scoped.map(|s| s.1),
                app,
                limit * 4,
            )
            .map_err(screen_failure)?;
        let mut seen = std::collections::HashSet::new();
        let hits: Vec<screen::SearchHit> = raw
            .into_iter()
            .filter(|h| seen.insert(format!("{}|{}|{}", h.app, h.window_title, h.snippet)))
            .take(limit)
            .filter(|h| cutoff.is_none_or(|c| h.captured_at >= c))
            .collect();
        Ok(ToolResult::text(&screen_json(&hits)))
    }

    fn timeline(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let (start, end) = self.day_interval(arguments, "day")?;
        let limit = bounded(arguments, "limit", 200, 500)? as usize;
        let mut after: Option<DateTime<Utc>> = None;
        if let Some(raw) = arguments.get("after").filter(|v| !v.is_null()) {
            after = Some(
                raw.as_str()
                    .and_then(lokalbot_core::time::parse_iso)
                    .ok_or_else(|| {
                        ToolResult::error(
                            ToolErrorCode::InvalidArguments,
                            "\"after\" must be an ISO 8601 time such as 2026-05-27T14:30:00Z.",
                        )
                    })?,
            );
        }
        let Some((scoped_start, scoped_end)) = self
            .scoped(start, end)
            .filter(|(s, e)| *e > after.unwrap_or(*s))
        else {
            return Ok(ToolResult::text(&screen_json(&screen::Timeline {
                start,
                end,
                activity: Vec::new(),
                screenshots: Vec::new(),
                activity_truncated: None,
                screenshots_truncated: None,
            })));
        };
        let from = after.map_or(scoped_start, |a| a.max(scoped_start));
        let timeline = screen::ScreenReader::new(self.session.paths.root())
            .timeline(from, scoped_end, limit)
            .map_err(screen_failure)?;
        Ok(ToolResult::text(&screen_json(&timeline)))
    }

    fn recent_activity(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let minutes = bounded(arguments, "minutes", 120, 10_080)?;
        let limit = bounded(arguments, "limit", 50, 200)? as usize;
        let requested = self.now() - chrono::Duration::minutes(minutes);
        let start = self.screen_cutoff().map_or(requested, |c| requested.max(c));
        let blocks = screen::ScreenReader::new(self.session.paths.root())
            .recent_activity(start, limit)
            .map_err(screen_failure)?;
        Ok(ToolResult::text(&screen_json(&blocks)))
    }

    fn app_usage(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let (start, end) = self.day_interval(arguments, "day")?;
        let limit = bounded(arguments, "limit", 30, 100)? as usize;
        let Some((start, end)) = self.scoped(start, end) else {
            return Ok(ToolResult::text(&screen_json(
                &Vec::<screen::AppUsage>::new(),
            )));
        };
        let usage = screen::ScreenReader::new(self.session.paths.root())
            .app_usage(start, end, limit)
            .map_err(screen_failure)?;
        Ok(ToolResult::text(&screen_json(&usage)))
    }

    fn screenshot_detail(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let Some(id) = arguments
            .get("snapshot_id")
            .and_then(int_value)
            .filter(|id| *id > 0)
        else {
            return Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                "get_screenshot_detail requires a positive integer \"snapshot_id\".",
            ));
        };
        let detail = screen::ScreenReader::new(self.session.paths.root())
            .screenshot_detail(id)
            .map_err(screen_failure)?;
        let Some(detail) = detail else {
            return Err(ToolResult::error(
                ToolErrorCode::ScreenshotNotFound,
                &format!(
                    "No screen-context metadata matches id {id}. Use search_screen or get_timeline to find ids."
                ),
            ));
        };
        if self.screen_cutoff().is_some_and(|c| detail.captured_at < c) {
            return Err(ToolResult::error(
                ToolErrorCode::ScreenshotNotFound,
                &format!(
                    "No screen-context metadata matches id {id} inside the granted screen-memory scope."
                ),
            ));
        }
        Ok(ToolResult::text(&screen_json(&detail)))
    }

    fn personal_context(&self, arguments: &Value) -> Result<ToolResult, ToolResult> {
        let paths = &self.session.paths;
        if !access::personal_context_enabled(paths) {
            return Err(ToolResult::error(
                ToolErrorCode::PersonalContextDisabled,
                personal::DISABLED_MESSAGE,
            ));
        }
        let Some(task) = arguments.get("task").and_then(Value::as_str) else {
            return Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                &format!("{} requires a \"task\" string.", personal::NAME),
            ));
        };
        let mut kinds: Option<Vec<String>> = None;
        if let Some(raw) = arguments.get("kinds").filter(|v| !v.is_null()) {
            let invalid = || {
                ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    "\"kinds\" must be an array of strings.",
                )
            };
            let values = raw.as_array().ok_or_else(invalid)?;
            kinds = Some(
                values
                    .iter()
                    .map(|v| v.as_str().map(str::to_string))
                    .collect::<Option<Vec<_>>>()
                    .ok_or_else(invalid)?,
            );
        }
        let mut max_items = None;
        if let Some(raw) = arguments.get("max_items").filter(|v| !v.is_null()) {
            max_items = Some(int_value(raw).ok_or_else(|| {
                ToolResult::error(
                    ToolErrorCode::InvalidArguments,
                    &format!(
                        "\"max_items\" must be an integer between 1 and {}.",
                        personal::MAXIMUM_ITEMS
                    ),
                )
            })?);
        }
        match personal::report(paths, task, kinds.as_deref(), max_items) {
            Ok(report) => Ok(ToolResult::text(&swift_json::pretty(&report, false))),
            Err(personal::Failure::Disabled) => Err(ToolResult::error(
                ToolErrorCode::PersonalContextDisabled,
                personal::DISABLED_MESSAGE,
            )),
            Err(personal::Failure::Unavailable) => Err(ToolResult::error(
                ToolErrorCode::PersonalContextUnavailable,
                personal::UNAVAILABLE_MESSAGE,
            )),
            Err(failure) => Err(ToolResult::error(
                ToolErrorCode::InvalidArguments,
                &failure.message(),
            )),
        }
    }
}

// ---------------------------------------------------------------- JSON-RPC

/// A JSON-RPC request ID; `None` marks a notification.
#[derive(Clone, Debug, PartialEq)]
pub enum RequestId {
    Number(i64),
    Text(String),
}

impl RequestId {
    fn json(&self) -> Value {
        match self {
            RequestId::Number(n) => json!(n),
            RequestId::Text(s) => json!(s),
        }
    }
}

fn response(id: Option<&RequestId>, result: Value) -> String {
    swift_json::compact(
        &json!({"jsonrpc": "2.0", "id": id.map_or(Value::Null, RequestId::json), "result": result}),
    )
}

pub fn failure(id: Option<&RequestId>, code: i64, message: &str) -> String {
    swift_json::compact(&json!({
        "jsonrpc": "2.0",
        "id": id.map_or(Value::Null, RequestId::json),
        "error": {"code": code, "message": message},
    }))
}

/// One line in, at most one line out (`MCPDispatcher.handle(line:)`).
pub fn handle_line(provider: &Provider, line: &str, server_version: &str) -> Option<String> {
    if line.len() > MAXIMUM_RECORD_BYTES {
        return Some(failure(None, -32600, "Request exceeds the 1 MiB limit"));
    }
    let Ok(Value::Object(object)) = serde_json::from_str::<Value>(line) else {
        return Some(failure(None, -32700, "Parse error"));
    };
    let id = match object.get("id") {
        Some(Value::Number(n)) => match int_value(&Value::Number(n.clone())) {
            Some(i) => Some(RequestId::Number(i)),
            None => return Some(failure(None, -32600, "Invalid numeric request id")),
        },
        Some(Value::String(s)) => Some(RequestId::Text(s.clone())),
        _ => None,
    };
    let method = match (object.get("jsonrpc"), object.get("method")) {
        (Some(Value::String(version)), Some(Value::String(method))) if version == "2.0" => {
            method.clone()
        }
        _ => return Some(failure(id.as_ref(), -32600, "Invalid Request")),
    };
    let id = id?;
    let params = object.get("params").cloned().unwrap_or(Value::Null);
    Some(match method.as_str() {
        "initialize" => {
            let requested = params
                .get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("");
            let version = if PROTOCOL_VERSIONS.contains(&requested) {
                requested
            } else {
                PROTOCOL_VERSIONS[2]
            };
            response(
                Some(&id),
                json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "lokalbot", "version": server_version},
                    "instructions": INSTRUCTIONS,
                }),
            )
        }
        "tools/list" => response(Some(&id), json!({"tools": tools()})),
        "tools/call" => {
            let Some(name) = params.get("name").and_then(Value::as_str) else {
                return Some(failure(
                    Some(&id),
                    -32602,
                    "tools/call requires params.name",
                ));
            };
            let arguments = params.get("arguments").cloned().unwrap_or(Value::Null);
            response(Some(&id), provider.call(name, &arguments).json())
        }
        "ping" => response(Some(&id), json!({})),
        other => failure(Some(&id), -32601, &format!("Method not found: {other}")),
    })
}

/// Serves stdin/stdout until EOF. Lines over 1 MiB are rejected without
/// buffering them whole.
pub fn serve(provider: &Provider, server_version: &str) -> anyhow::Result<()> {
    eprintln!(
        "lokalbot-cli mcp: serving on stdio (library: {})",
        provider.session.paths.root().display()
    );
    let stdin = std::io::stdin();
    let mut reader = std::io::BufReader::with_capacity(64 * 1024, stdin.lock());
    let mut stdout = std::io::stdout();
    let mut record: Vec<u8> = Vec::new();
    let mut oversized = false;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            if !oversized && !record.is_empty() {
                answer(provider, &record, server_version, &mut stdout)?;
            }
            return Ok(());
        }
        let (chunk, complete) = match available.iter().position(|b| *b == b'\n') {
            Some(index) => (&available[..index], true),
            None => (available, false),
        };
        if !oversized {
            record.extend_from_slice(chunk);
            if record.len() > MAXIMUM_RECORD_BYTES {
                record.clear();
                oversized = true;
                writeln!(
                    stdout,
                    "{}",
                    failure(None, -32600, "Request exceeds the 1 MiB limit")
                )?;
                stdout.flush()?;
            }
        }
        let consumed = chunk.len() + usize::from(complete);
        reader.consume(consumed);
        if complete {
            if !oversized {
                answer(provider, &record, server_version, &mut stdout)?;
            }
            record.clear();
            oversized = false;
        }
    }
}

fn answer(
    provider: &Provider,
    record: &[u8],
    server_version: &str,
    out: &mut impl std::io::Write,
) -> anyhow::Result<()> {
    let mut line = String::from_utf8_lossy(record).into_owned();
    if line.ends_with('\r') {
        line.pop();
    }
    if line.trim().is_empty() {
        return Ok(());
    }
    if let Some(reply) = handle_line(provider, &line, server_version) {
        writeln!(out, "{reply}")?;
        out.flush()?;
    }
    Ok(())
}
