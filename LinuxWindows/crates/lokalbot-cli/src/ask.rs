//! `ask_library` (`AskLibraryEngine.swift`, `AskLibraryContext.swift`): the
//! question and matching meeting context go to the app's local model server
//! on 127.0.0.1; nothing leaves this computer.
//!
//! The app records its server in `<root>/llama-server-17872.json`
//! (`port`, `pid`, `authenticationToken`). Without it the tool answers that
//! the app must be running.

use std::time::Duration;

use chrono::{DateTime, Local, Utc};
use lokalbot_core::{LibraryPaths, Meeting, access};
use serde::Deserialize;

use crate::mcp::{ToolErrorCode, ToolResult};
use crate::search;
use crate::session::{Session, day_key, short_id};

pub const MAIN_PORT: u16 = 17872;
pub const MAXIMUM_QUESTION_CHARACTERS: usize = 16_384;
const MAX_SNIPPETS: usize = 12;
const MAX_SNIPPETS_PER_MEETING_FIRST_PASS: usize = 4;
const MAX_TITLE_SUMMARY_MATCHES: usize = 4;
const MAX_SUMMARY_BYTES: usize = 6 * 1024;
const MAX_SNIPPET_LINE_BYTES: usize = 1024;
const MAX_CONTEXT_BYTES: usize = 32 * 1024;
const POLL_ATTEMPTS: usize = 60;

pub const NOT_RUNNING: &str = "ask_library needs the LokalBot app running (read tools still work without it). Open LokalBot and try again.";

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServerMarker {
    #[serde(default)]
    pid: Option<u32>,
    port: u16,
    #[serde(default)]
    authentication_token: Option<String>,
}

fn marker_path(paths: &LibraryPaths) -> std::path::PathBuf {
    paths.root().join(format!("llama-server-{MAIN_PORT}.json"))
}

/// The bearer token of a live, recorded main model server.
fn validated_token(paths: &LibraryPaths) -> Option<(u16, String)> {
    let bytes = std::fs::read(marker_path(paths)).ok()?;
    let marker: ServerMarker = serde_json::from_slice(&bytes).ok()?;
    let token = marker.authentication_token.filter(|t| t.len() >= 32)?;
    if marker.port != MAIN_PORT {
        return None;
    }
    #[cfg(target_os = "linux")]
    if let Some(pid) = marker.pid
        && !std::path::Path::new(&format!("/proc/{pid}")).exists()
    {
        return None;
    }
    #[cfg(not(target_os = "linux"))]
    let _ = marker.pid;
    Some((marker.port, token))
}

fn agent(timeout: Duration) -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(timeout))
        .build()
        .into()
}

fn healthy(paths: &LibraryPaths) -> bool {
    let Some((port, token)) = validated_token(paths) else {
        return false;
    };
    agent(Duration::from_secs(2))
        .get(&format!("http://127.0.0.1:{port}/health"))
        .header("Authorization", &format!("Bearer {token}"))
        .call()
        .is_ok_and(|r| r.status() == 200)
}

fn complete(paths: &LibraryPaths, messages: &serde_json::Value) -> anyhow::Result<String> {
    let (port, token) = validated_token(paths)
        .ok_or_else(|| anyhow::anyhow!("the model server is not available"))?;
    let body = serde_json::json!({
        "messages": messages,
        "temperature": 0.2,
        "max_tokens": 1024,
        "thinking_budget_tokens": 0,
        "chat_template_kwargs": {"enable_thinking": false},
    });
    let mut response = agent(Duration::from_secs(300))
        .post(&format!("http://127.0.0.1:{port}/v1/chat/completions"))
        .header("Authorization", &format!("Bearer {token}"))
        .send_json(&body)?;
    let value: serde_json::Value = response.body_mut().read_json()?;
    value["choices"][0]["message"]["content"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| anyhow::anyhow!("the model server sent an unreadable answer"))
}

/// Answers a question from the library through the app's local model.
pub fn ask(session: &Session, question: &str) -> ToolResult {
    let paths = &session.paths;
    let token = std::env::var(access::CAPABILITY_ENV).ok();
    let authorization = || access::meetings_authorization(paths, token.as_deref());
    let Some(grant) = authorization() else {
        return ToolResult::error(
            ToolErrorCode::AccessDisabled,
            access::MEETINGS_DISABLED_MESSAGE,
        );
    };
    let still_authorized = || authorization().as_ref() == Some(&grant);
    let trimmed = question.trim();
    if trimmed.is_empty() {
        return ToolResult::error(
            ToolErrorCode::InvalidArguments,
            "ask_library requires a non-empty \"question\" string.",
        );
    }
    if trimmed.chars().count() > MAXIMUM_QUESTION_CHARACTERS {
        return ToolResult::error(
            ToolErrorCode::InvalidArguments,
            &format!(
                "ask_library questions are limited to {MAXIMUM_QUESTION_CHARACTERS} characters."
            ),
        );
    }
    if !marker_path(paths).exists() {
        return ToolResult::error(ToolErrorCode::AppNotRunning, NOT_RUNNING);
    }
    if !healthy(paths)
        && let Some(failure) = wake_and_wait(paths, &still_authorized)
    {
        return failure;
    }
    if !still_authorized() {
        return ToolResult::error(
            ToolErrorCode::AccessDisabled,
            access::MEETINGS_DISABLED_MESSAGE,
        );
    }
    let meetings = session.meetings().unwrap_or_default();
    if meetings.is_empty() {
        return ToolResult::text(
            "The meeting library is empty — record a meeting in LokalBot first.",
        );
    }
    let bundle = build_context(session, trimmed, &meetings);
    if bundle.text.is_empty() {
        return ToolResult::text(
            "I couldn't find anything in your meetings matching that question. Try search_meetings with a specific keyword.",
        );
    }
    let answer = match complete(paths, &messages(trimmed, &bundle.text, Utc::now())) {
        Ok(answer) => answer,
        Err(err) => {
            if !still_authorized() {
                return ToolResult::error(
                    ToolErrorCode::AccessDisabled,
                    access::MEETINGS_DISABLED_MESSAGE,
                );
            }
            return ToolResult::error(
                ToolErrorCode::AppNotRunning,
                &format!(
                    "Lost the connection to LokalBot's model server mid-answer ({err}). Make sure the LokalBot app is running and try again."
                ),
            );
        }
    };
    if !still_authorized() {
        return ToolResult::error(
            ToolErrorCode::AccessDisabled,
            access::MEETINGS_DISABLED_MESSAGE,
        );
    }
    if bundle.citations.is_empty() {
        return ToolResult::text(&answer);
    }
    let sources: Vec<String> = bundle
        .citations
        .iter()
        .map(|(id, title, date)| format!("- {title} ({date}, id {id})"))
        .collect();
    ToolResult::text(&format!("{answer}\n\nSources:\n{}", sources.join("\n")))
}

fn wake_and_wait(paths: &LibraryPaths, authorized: &dyn Fn() -> bool) -> Option<ToolResult> {
    access::clear_wake_error(paths);
    if let Err(err) = access::touch_wake(paths) {
        return Some(ToolResult::error(
            ToolErrorCode::AppNotRunning,
            &format!("Could not signal the LokalBot app ({err}). Open LokalBot and try again."),
        ));
    }
    for _ in 0..POLL_ATTEMPTS {
        std::thread::sleep(Duration::from_secs(1));
        if !authorized() {
            return Some(ToolResult::error(
                ToolErrorCode::AccessDisabled,
                access::MEETINGS_DISABLED_MESSAGE,
            ));
        }
        if healthy(paths) {
            return None;
        }
        if let Some(reason) = access::read_wake_error(paths) {
            return Some(ToolResult::error(ToolErrorCode::EngineUnavailable, &reason));
        }
    }
    if access::wake_pending(paths) {
        return Some(ToolResult::error(ToolErrorCode::AppNotRunning, NOT_RUNNING));
    }
    Some(ToolResult::error(
        ToolErrorCode::ModelLoadingTimeout,
        "The model is still loading. Try again in a moment — the first question after a cold start takes the longest.",
    ))
}

const STOPWORDS: &[&str] = &[
    "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "by", "for", "with",
    "from", "about", "into", "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
    "have", "has", "had", "will", "would", "should", "could", "can", "may", "might", "must",
    "what", "when", "where", "which", "who", "whom", "whose", "why", "how", "that", "this",
    "these", "those", "there", "it", "its", "i", "me", "my", "we", "us", "our", "you", "your",
    "he", "him", "his", "she", "her", "they", "them", "their", "any", "some", "all", "not", "so",
    "as", "than", "then", "also", "just", "tell", "say", "said", "please", "meeting", "meetings",
];

/// The question's content words.
pub fn search_terms(question: &str) -> Vec<String> {
    search::search_terms(&lokalbot_core::ids::fold(question))
        .into_iter()
        .filter(|t| !STOPWORDS.contains(&t.as_str()))
        .collect()
}

pub struct ContextBundle {
    pub text: String,
    /// `(short id, title, YYYY-MM-DD)`, newest first.
    pub citations: Vec<(String, String, String)>,
}

fn truncated_utf8(value: &str, max_bytes: usize, marker: &str) -> String {
    if max_bytes == 0 {
        return String::new();
    }
    if value.len() <= max_bytes {
        return value.to_string();
    }
    let can_mark = marker.len() <= max_bytes;
    let budget = if can_mark {
        max_bytes - marker.len()
    } else {
        max_bytes
    };
    let mut end = budget.min(value.len());
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    if can_mark {
        format!("{}{marker}", &value[..end])
    } else {
        value[..end].to_string()
    }
}

struct ContextWriter {
    text: String,
}

impl ContextWriter {
    fn is_full(&self) -> bool {
        self.text.len() >= MAX_CONTEXT_BYTES
    }

    fn append_section(&mut self, section: &str) -> bool {
        let fragment = if self.text.is_empty() {
            section.to_string()
        } else {
            format!("\n\n{section}")
        };
        self.append_fragment(&fragment)
    }

    fn append_fragment(&mut self, fragment: &str) -> bool {
        let available = MAX_CONTEXT_BYTES.saturating_sub(self.text.len());
        if available == 0 || fragment.is_empty() {
            return false;
        }
        let bounded = truncated_utf8(fragment, available, "\n[… context budget reached …]");
        if bounded.is_empty() {
            return false;
        }
        self.text.push_str(&bounded);
        true
    }
}

/// Retrieval and citations for one question (`AskLibraryContext.build`).
pub fn build_context(session: &Session, question: &str, meetings: &[Meeting]) -> ContextBundle {
    let by_short: std::collections::HashMap<String, &Meeting> =
        meetings.iter().map(|m| (short_id(m), m)).collect();
    let mut context = ContextWriter {
        text: String::new(),
    };
    let mut cited: Vec<String> = Vec::new();
    let lowered = question.to_lowercase();
    let mut title_matches: Vec<&Meeting> = meetings
        .iter()
        .filter(|m| {
            let title = m.title.trim();
            title.chars().count() >= 4 && lowered.contains(&title.to_lowercase())
        })
        .collect();
    title_matches.sort_by(|a, b| {
        b.title
            .trim()
            .chars()
            .count()
            .cmp(&a.title.trim().chars().count())
            .then(b.started_at.cmp(&a.started_at))
            .then_with(|| a.id.to_string().cmp(&b.id.to_string()))
    });
    let mut appended = 0;
    for meeting in title_matches {
        if appended >= MAX_TITLE_SUMMARY_MATCHES || context.is_full() {
            break;
        }
        let Some(summary) = session.summary(meeting) else {
            continue;
        };
        let bounded = truncated_utf8(&summary, MAX_SUMMARY_BYTES, "\n[… summary truncated …]");
        let section = format!(
            "## {} — {} — full summary\n{bounded}",
            meeting.title,
            day_key(meeting.started_at)
        );
        if context.append_section(&section) {
            appended += 1;
            cited.push(short_id(meeting));
        }
    }
    let terms = search_terms(question);
    let hits = if terms.is_empty() {
        Vec::new()
    } else {
        search::hits(
            session,
            &terms.join(" "),
            search::MAXIMUM_SEARCH_HITS,
            meetings,
            None,
            false,
        )
    };
    let mut seen = std::collections::HashSet::new();
    let mut per_meeting: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();
    let (mut first_pass, mut rest) = (Vec::new(), Vec::new());
    for hit in hits {
        if !seen.insert(format!("{}|{}", hit.meeting_id, hit.snippet)) {
            continue;
        }
        let taken = per_meeting.entry(hit.meeting_id.clone()).or_default();
        *taken += 1;
        if *taken <= MAX_SNIPPETS_PER_MEETING_FIRST_PASS {
            first_pass.push(hit);
        } else {
            rest.push(hit);
        }
    }
    let mut has_section = false;
    for (count, hit) in first_pass.into_iter().chain(rest).enumerate() {
        if count >= MAX_SNIPPETS || context.is_full() {
            break;
        }
        let stamp = hit
            .timestamp
            .as_ref()
            .map(|t| format!(" @{t}"))
            .unwrap_or_default();
        let day = by_short
            .get(&hit.meeting_id)
            .map(|m| format!(" ({})", day_key(m.started_at)))
            .unwrap_or_default();
        let line = truncated_utf8(
            &format!(
                "- [{}{stamp}] {}{day}: {}",
                hit.match_kind, hit.meeting_title, hit.snippet
            ),
            MAX_SNIPPET_LINE_BYTES,
            "…",
        );
        let prefix = if has_section {
            "\n"
        } else if context.text.is_empty() {
            "## Snippets\n"
        } else {
            "\n\n## Snippets\n"
        };
        if !context.append_fragment(&format!("{prefix}{line}")) {
            break;
        }
        has_section = true;
        cited.push(hit.meeting_id);
    }
    let mut unique = std::collections::HashSet::new();
    let mut cited_meetings: Vec<&Meeting> = cited
        .into_iter()
        .filter(|id| unique.insert(id.clone()))
        .filter_map(|id| by_short.get(&id).copied())
        .collect();
    cited_meetings.sort_by_key(|m| std::cmp::Reverse(m.started_at));
    ContextBundle {
        text: context.text,
        citations: cited_meetings
            .into_iter()
            .map(|m| (short_id(m), m.title.clone(), day_key(m.started_at)))
            .collect(),
    }
}

/// The local time zone's name for the prompt.
fn time_zone_name() -> String {
    if let Ok(tz) = std::env::var("TZ")
        && !tz.is_empty()
    {
        return tz.trim_start_matches(':').to_string();
    }
    #[cfg(unix)]
    {
        if let Ok(name) = std::fs::read_to_string("/etc/timezone") {
            let name = name.trim();
            if !name.is_empty() {
                return name.to_string();
            }
        }
        if let Ok(target) = std::fs::read_link("/etc/localtime") {
            let target = target.to_string_lossy();
            if let Some((_, name)) = target.split_once("zoneinfo/") {
                return name.to_string();
            }
        }
    }
    Local::now().format("UTC%:z").to_string()
}

pub fn messages(question: &str, context: &str, now: DateTime<Utc>) -> serde_json::Value {
    let today = now.with_timezone(&Local).format("%A, %Y-%m-%d");
    serde_json::json!([
        {
            "role": "system",
            "content": format!(
                "You are LokalBot's meeting-library assistant. Answer the user's question using ONLY the meeting context provided. Cite the meetings you used by title and date. If the context does not contain the answer, reply exactly: I couldn't find that in your meetings. Today is {today} ({}); meeting dates in the context are days in that time zone.",
                time_zone_name()
            ),
        },
        {"role": "user", "content": format!("Meeting context:\n\n{context}\n\nQuestion: {question}")},
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn question_terms_drop_framing_words() {
        assert_eq!(
            search_terms("What did we decide about the Redis cache?"),
            ["decide", "redis", "cache"]
        );
        assert_eq!(search_terms("Who owns Q3?"), ["owns", "q3"]);
    }

    #[test]
    fn utf8_truncation_keeps_characters_whole() {
        assert_eq!(truncated_utf8("ććć", 3, ""), "ć");
        assert_eq!(truncated_utf8("abcdef", 5, "…"), "ab…");
        assert_eq!(truncated_utf8("abc", 5, "…"), "abc");
    }
}
