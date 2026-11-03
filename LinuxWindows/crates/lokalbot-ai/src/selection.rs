//! Selection actions (`SelectionAction.swift`): the built-in actions on text
//! selected in another app, typed instructions, their prompts, and the work
//! memory an action marked "with my memory" adds. Nothing here is stored.

use std::collections::BTreeMap;

use anyhow::Result;
use chrono::{DateTime, Local, Utc};
use serde::Deserialize;
use uuid::Uuid;

use lokalbot_core::Library;

use crate::ask::AskScope;
use crate::ask_agent::{ToolCall, Tools};
use crate::dictation::compose_normalized_output;
use crate::prompts::{
    SELECTION_ACTION_EXPLAIN, SELECTION_ACTION_FIX_GRAMMAR, SELECTION_ACTION_FRIENDLY,
    SELECTION_ACTION_IMPROVE, SELECTION_ACTION_MEMORY_RULES, SELECTION_ACTION_PROFESSIONAL,
    SELECTION_ACTION_REPLY, SELECTION_ACTION_SHORTER, SELECTION_ACTION_SUMMARIZE,
    SELECTION_ACTION_SYSTEM, SELECTION_ACTION_TRANSLATE,
};
use crate::sanitize::sanitize;
use crate::think::{ChatRequest, EmbeddingClient};

pub const CUSTOM_ID: &str = "custom";
/// The selection sent to the model. Longer selections are cut, and the panel
/// says so.
pub const SELECTION_CHARACTER_LIMIT: usize = 12_000;
/// What the memory search looks for: the start of the selection is where a
/// message usually says what it is about.
pub const MEMORY_QUERY_CHARACTER_LIMIT: usize = 400;
const MEMORY_SOURCES: usize = 6;
const MEMORY_TEXT_LIMIT: usize = 6_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActionResult {
    /// A new version of the selection, offered as a replacement.
    Replacement,
    /// Text that does not stand in for the selection.
    NewText,
}

/// A built-in action, or a typed instruction.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Action {
    pub id: &'static str,
    /// Interface text, except for a typed instruction.
    pub title: String,
    /// What the model is asked to do, in the prompt's words.
    pub instruction: String,
    pub result: ActionResult,
    /// Reads matching meetings and work memory before writing.
    pub uses_memory: bool,
    /// False for actions that only make sense on selected text.
    pub works_without_selection: bool,
}

impl Action {
    fn fixed(
        id: &'static str,
        title: &str,
        instruction: &str,
        result: ActionResult,
        uses_memory: bool,
    ) -> Self {
        Self {
            id,
            title: title.to_string(),
            instruction: instruction.to_string(),
            result,
            uses_memory,
            works_without_selection: false,
        }
    }

    pub fn built_in() -> Vec<Self> {
        use ActionResult::{NewText, Replacement};
        vec![
            Self::fixed(
                "fixGrammar",
                "Fix spelling and grammar",
                SELECTION_ACTION_FIX_GRAMMAR,
                Replacement,
                false,
            ),
            Self::fixed(
                "improve",
                "Improve writing",
                SELECTION_ACTION_IMPROVE,
                Replacement,
                false,
            ),
            Self::fixed(
                "shorter",
                "Make shorter",
                SELECTION_ACTION_SHORTER,
                Replacement,
                false,
            ),
            Self::fixed(
                "professional",
                "Make more professional",
                SELECTION_ACTION_PROFESSIONAL,
                Replacement,
                false,
            ),
            Self::fixed(
                "friendly",
                "Make friendlier",
                SELECTION_ACTION_FRIENDLY,
                Replacement,
                false,
            ),
            Self::fixed(
                "translateToEnglish",
                "Translate to English",
                SELECTION_ACTION_TRANSLATE,
                Replacement,
                false,
            ),
            Self::fixed(
                "summarize",
                "Summarize",
                SELECTION_ACTION_SUMMARIZE,
                NewText,
                false,
            ),
            Self::fixed(
                "explain",
                "Explain with my memory",
                SELECTION_ACTION_EXPLAIN,
                NewText,
                true,
            ),
            Self::fixed(
                "reply",
                "Draft a reply with my memory",
                SELECTION_ACTION_REPLY,
                NewText,
                true,
            ),
        ]
    }

    /// A typed instruction. With a selection it can replace it; without one
    /// it writes new text at the cursor.
    pub fn custom(instruction: &str, uses_memory: bool) -> Self {
        Self {
            id: CUSTOM_ID,
            title: instruction.to_string(),
            instruction: instruction.to_string(),
            result: ActionResult::Replacement,
            uses_memory,
            works_without_selection: true,
        }
    }

    pub fn is_custom(&self) -> bool {
        self.id == CUSTOM_ID
    }

    /// Built-in actions whose title contains every typed word, in English or
    /// in the interface language.
    pub fn matching(
        query: &str,
        has_selection: bool,
        localized: impl Fn(&str) -> String,
    ) -> Vec<Self> {
        let available: Vec<Self> = Self::built_in()
            .into_iter()
            .filter(|action| has_selection || action.works_without_selection)
            .collect();
        let query = query.to_lowercase();
        let tokens: Vec<&str> = query.split_whitespace().collect();
        if tokens.is_empty() {
            return available;
        }
        available
            .into_iter()
            .filter(|action| {
                let haystack =
                    format!("{} {}", action.title, localized(&action.title)).to_lowercase();
                tokens.iter().all(|token| haystack.contains(token))
            })
            .collect()
    }

    /// The panel's rows: the matching actions, then the typed instruction.
    pub fn rows(
        query: &str,
        has_selection: bool,
        instruction_uses_memory: bool,
        localized: impl Fn(&str) -> String,
    ) -> Vec<Self> {
        let trimmed = query.trim();
        let mut rows = Self::matching(trimmed, has_selection, localized);
        if !trimmed.is_empty() {
            rows.push(Self::custom(trimmed, instruction_uses_memory));
        }
        rows
    }
}

/// A meeting the memory lookup matched, so a claim can be checked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MemorySource {
    pub id: Uuid,
    pub title: String,
    pub date: Option<DateTime<Utc>>,
}

/// Retrieved work memory for one request (`SelectionMemoryContext`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MemoryContext {
    pub excerpts: String,
    pub sources: Vec<MemorySource>,
}

impl MemoryContext {
    pub fn is_empty(&self) -> bool {
        self.excerpts.is_empty()
    }
}

pub fn system_prompt(uses_memory: bool) -> String {
    if uses_memory {
        format!("{SELECTION_ACTION_SYSTEM}\n{SELECTION_ACTION_MEMORY_RULES}")
    } else {
        SELECTION_ACTION_SYSTEM.to_string()
    }
}

pub fn user_prompt(action: &Action, selection: &str, memory: &MemoryContext) -> String {
    let mut parts = vec![format!("Task: {}", action.instruction)];
    let selected = clipped_selection(selection);
    if selected.is_empty() {
        parts.push(
            "Nothing is selected. Write the text the task asks for; it will be inserted at the cursor."
                .to_string(),
        );
    } else {
        parts.push(format!("Selected text:\n<<<\n{selected}\n>>>"));
    }
    if action.uses_memory {
        parts.push(if memory.is_empty() {
            "Work memory: nothing relevant was found. Do not make up details.".to_string()
        } else {
            format!("Work memory:\n<<<\n{}\n>>>", memory.excerpts)
        });
    }
    parts.join("\n\n")
}

/// No thinking turn: someone is waiting to paste. The output ceiling fits a
/// long rewritten passage.
pub fn request(action: &Action, selection: &str, memory: &MemoryContext) -> ChatRequest {
    ChatRequest::new(
        system_prompt(action.uses_memory),
        user_prompt(action, selection, memory),
    )
    .max_tokens(4_096)
    .reasoning_budget(0)
    .temperature(0.3)
}

pub fn clipped_selection(selection: &str) -> String {
    selection
        .trim()
        .chars()
        .take(SELECTION_CHARACTER_LIMIT)
        .collect()
}

/// The text the memory search runs on.
pub fn memory_query(action: &Action, selection: &str) -> String {
    let selected = selection.trim();
    let base = if selected.is_empty() {
        action.instruction.as_str()
    } else {
        selected
    };
    base.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MEMORY_QUERY_CHARACTER_LIMIT)
        .collect()
}

/// Strips reasoning, code fences, and quotation marks the model wrapped
/// around the whole answer. Applied to partial output too.
pub fn normalized_output(raw: &str, selection: &str) -> String {
    let mut output = compose_normalized_output(raw);
    let selected_first = selection.trim().chars().next();
    for (open, close) in [('"', '"'), ('“', '”'), ('\'', '\'')] {
        let mut chars = output.chars();
        if output.chars().count() >= 2
            && chars.next() == Some(open)
            && chars.next_back() == Some(close)
            && selected_first != Some(open)
        {
            output = chars.as_str().trim().to_string();
        }
    }
    output
}

/// Meetings that match the selection, plus the overnight work memory
/// (`AppState.selectionMemoryContext`). Uses the same search as Ask's tool.
pub fn memory_context(
    library: &Library,
    embedder: Option<EmbeddingClient>,
    query: &str,
    dreaming_enabled: bool,
) -> Result<MemoryContext> {
    if query.is_empty() {
        return Ok(MemoryContext::default());
    }
    let tools = Tools::new(library, embedder, AskScope::default(), Utc::now())?;
    let search = tools.run(&ToolCall {
        name: "search_meetings".into(),
        arguments: BTreeMap::from([("query".to_string(), query.to_string())]),
    });
    let mut parts = Vec::new();
    let mut sources = Vec::new();
    if !search.evidence.meetings.is_empty() {
        parts.push(sanitize(&search.text, Some(MEMORY_TEXT_LIMIT)));
        let matched = |id: &Uuid| search.evidence.meetings.iter().any(|(m, _)| m == id);
        sources = library
            .list_meetings()?
            .into_iter()
            .filter(|meeting| matched(&meeting.id))
            .take(MEMORY_SOURCES)
            .map(|meeting| MemorySource {
                id: meeting.id,
                title: meeting.display_title(),
                date: Some(meeting.started_at),
            })
            .collect();
    }
    let work_memory = lokalbot_core::evidence::read_work_memory(library.paths().root())
        .map(|bytes| work_memory_context(&bytes, dreaming_enabled))
        .unwrap_or_default();
    if !work_memory.is_empty() {
        parts.push(format!("Ongoing work:\n{work_memory}"));
    }
    Ok(MemoryContext {
        excerpts: parts.join("\n\n"),
        sources,
    })
}

/// `DreamMemory`, as much of it as the prompt shows.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct DreamMemory {
    updated_at: Option<DateTime<Utc>>,
    active_projects: Vec<DreamProject>,
    work_goals: Vec<DreamGoal>,
    recurring_patterns: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct DreamProject {
    name: String,
    status: String,
    last_active_day: String,
    evidence: Vec<String>,
    pinned: bool,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct DreamGoal {
    text: String,
    horizon: String,
    last_reinforced_day: String,
    pinned: bool,
}

/// `ChatPrompt.workMemoryContext`: empty when the overnight review is off,
/// the file is unreadable, or the memory holds nothing.
pub fn work_memory_context(json: &[u8], dreaming_enabled: bool) -> String {
    if !dreaming_enabled {
        return String::new();
    }
    let Ok(memory) = serde_json::from_slice::<DreamMemory>(json) else {
        return String::new();
    };
    if memory.active_projects.is_empty()
        && memory.work_goals.is_empty()
        && memory.recurring_patterns.is_empty()
    {
        return String::new();
    }
    sanitize(&work_memory_markdown(&memory), Some(MEMORY_TEXT_LIMIT))
}

/// `DreamMemory.markdown()`.
fn work_memory_markdown(memory: &DreamMemory) -> String {
    const NONE: &str = "_None observed yet._";
    let updated = memory
        .updated_at
        .map(|at| at.with_timezone(&Local).format("%Y-%m-%d").to_string())
        .unwrap_or_default();
    let mut lines = vec![
        "# Work memory".to_string(),
        String::new(),
        format!("_Maintained overnight by dreaming. Updated {updated}._"),
        String::new(),
        "## Active projects".to_string(),
        String::new(),
    ];
    if memory.active_projects.is_empty() {
        lines.push(NONE.to_string());
    }
    for project in &memory.active_projects {
        let pinned = if project.pinned { "pinned, " } else { "" };
        lines.push(format!(
            "- **{}** — {} _({pinned}last active {})_",
            project.name, project.status, project.last_active_day
        ));
        lines.extend(project.evidence.iter().map(|item| format!("  - {item}")));
    }
    lines.extend([String::new(), "## Current goals".to_string(), String::new()]);
    if memory.work_goals.is_empty() {
        lines.push(NONE.to_string());
    }
    for goal in &memory.work_goals {
        let pinned = if goal.pinned { "pinned, " } else { "" };
        lines.push(format!(
            "- {} _({}, {pinned}reinforced {})_",
            goal.text, goal.horizon, goal.last_reinforced_day
        ));
    }
    lines.extend([
        String::new(),
        "## Recurring patterns".to_string(),
        String::new(),
    ]);
    if memory.recurring_patterns.is_empty() {
        lines.push(NONE.to_string());
    }
    lines.extend(
        memory
            .recurring_patterns
            .iter()
            .map(|pattern| format!("- {pattern}")),
    );
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};
    use crate::think::ThinkClient;
    use serde_json::json;

    fn plain(text: &str) -> String {
        text.to_string()
    }

    #[test]
    fn built_in_actions_match_the_mac() {
        let actions = Action::built_in();
        let ids: Vec<&str> = actions.iter().map(|a| a.id).collect();
        assert_eq!(
            ids,
            [
                "fixGrammar",
                "improve",
                "shorter",
                "professional",
                "friendly",
                "translateToEnglish",
                "summarize",
                "explain",
                "reply"
            ]
        );
        for action in &actions {
            assert!(!action.works_without_selection, "{}", action.id);
            let memory = matches!(action.id, "explain" | "reply");
            assert_eq!(action.uses_memory, memory, "{}", action.id);
            let new_text = matches!(action.id, "summarize" | "explain" | "reply");
            assert_eq!(
                action.result == ActionResult::NewText,
                new_text,
                "{}",
                action.id
            );
        }
    }

    #[test]
    fn rows_offer_matches_then_the_typed_instruction() {
        assert_eq!(Action::rows("", true, true, plain).len(), 9);
        assert!(
            Action::rows("", false, true, plain).is_empty(),
            "built-ins need a selection"
        );
        let rows = Action::rows("make short", true, false, plain);
        assert_eq!(rows[0].id, "shorter");
        assert_eq!(rows.last().unwrap().id, CUSTOM_ID);
        assert!(!rows.last().unwrap().uses_memory);
        let rows = Action::rows("a status update", false, true, plain);
        assert_eq!(rows.len(), 1);
        assert!(rows[0].works_without_selection && rows[0].uses_memory);
        let rows = Action::matching("skrati", true, |title| {
            if title == "Make shorter" {
                "Skrati".into()
            } else {
                title.to_string()
            }
        });
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "shorter");
    }

    #[test]
    fn prompts_fence_the_selection_and_say_what_memory_found() {
        let action = Action::built_in().remove(0);
        let prompt = user_prompt(&action, "  helo wrld ", &MemoryContext::default());
        assert_eq!(
            prompt,
            format!("Task: {SELECTION_ACTION_FIX_GRAMMAR}\n\nSelected text:\n<<<\nhelo wrld\n>>>")
        );
        assert_eq!(system_prompt(false), SELECTION_ACTION_SYSTEM);
        assert!(system_prompt(true).ends_with(SELECTION_ACTION_MEMORY_RULES));
        let custom = Action::custom("write a status update", true);
        let prompt = user_prompt(&custom, "", &MemoryContext::default());
        assert!(prompt.contains("Nothing is selected."), "{prompt}");
        assert!(
            prompt.ends_with("Work memory: nothing relevant was found. Do not make up details.")
        );
        let memory = MemoryContext {
            excerpts: "the beta ships Friday".into(),
            sources: Vec::new(),
        };
        assert!(
            user_prompt(&custom, "", &memory)
                .ends_with("Work memory:\n<<<\nthe beta ships Friday\n>>>")
        );
    }

    #[test]
    fn limits_follow_the_mac() {
        let long = "a".repeat(SELECTION_CHARACTER_LIMIT + 50);
        assert_eq!(
            clipped_selection(&long).chars().count(),
            SELECTION_CHARACTER_LIMIT
        );
        let custom = Action::custom("find   the\nnotes", true);
        assert_eq!(memory_query(&custom, " "), "find the notes");
        let words = "word ".repeat(200);
        assert_eq!(
            memory_query(&custom, &words).chars().count(),
            MEMORY_QUERY_CHARACTER_LIMIT
        );
    }

    #[test]
    fn output_loses_what_the_model_wrapped_around_it() {
        assert_eq!(normalized_output("\"Hello.\"", "hello"), "Hello.");
        assert_eq!(normalized_output("“Hello.”", "hello"), "Hello.");
        assert_eq!(
            normalized_output("\"Quoted.\"", " \"quoted\""),
            "\"Quoted.\""
        );
        assert_eq!(normalized_output("```\nFixed.\n```", "fixed"), "Fixed.");
        assert_eq!(normalized_output("<think>x</think>Done", "done"), "Done");
    }

    #[test]
    fn the_request_has_no_thinking_turn() {
        let seen = std::sync::Arc::new(parking_lot::Mutex::new(Vec::new()));
        let sent = seen.clone();
        let server = StubServer::start(move |request| {
            sent.lock().push(request.json());
            Reply::Json(
                200,
                json!({"choices": [{"message": {"content": "ok"}, "finish_reason": "stop"}]}),
            )
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let action = Action::built_in().remove(1);
        assert_eq!(
            think
                .complete(&request(&action, "text", &MemoryContext::default()))
                .unwrap(),
            "ok"
        );
        let body = seen.lock()[0].clone();
        assert_eq!(body["max_tokens"], 4096);
        assert!((body["temperature"].as_f64().unwrap() - 0.3).abs() < 1e-6);
        assert_eq!(body["chat_template_kwargs"]["enable_thinking"], false);
    }

    /// `memory/memory.json` as `DreamStore` writes it (`.iso8601` dates).
    const MAC_MEMORY: &str = r#"{
      "version": 2,
      "updatedAt": "2026-10-20T04:12:33Z",
      "activeProjects": [
        {"name": "Beta launch", "status": "blocked on review", "lastActiveDay": "2026-10-19",
         "evidence": ["Review moved to Friday"], "pinned": true,
         "provenance": {"sources": [], "revision": 1, "includesUnattributedContext": false}}
      ],
      "workGoals": [
        {"text": "Ship the beta", "horizon": "this month", "lastReinforcedDay": "2026-10-18",
         "pinned": false}
      ],
      "recurringPatterns": ["Reviews slip by a day"],
      "patternProvenance": {}
    }"#;

    #[test]
    fn reads_the_macs_work_memory() {
        let text = work_memory_context(MAC_MEMORY.as_bytes(), true);
        assert!(text.starts_with("# Work memory"), "{text}");
        assert!(
            text.contains(
                "- **Beta launch** — blocked on review _(pinned, last active 2026-10-19)_"
            ),
            "{text}"
        );
        assert!(text.contains("- Review moved to Friday"), "{text}");
        assert!(
            text.contains("- Ship the beta _(this month, reinforced 2026-10-18)_"),
            "{text}"
        );
        assert!(text.contains("- Reviews slip by a day"), "{text}");
        assert_eq!(work_memory_context(MAC_MEMORY.as_bytes(), false), "");
        assert_eq!(work_memory_context(b"not json", true), "");
        assert_eq!(
            work_memory_context(br#"{"activeProjects": [], "workGoals": []}"#, true),
            ""
        );
    }

    #[test]
    fn an_empty_library_gives_no_memory() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let context = memory_context(&library, None, "beta launch", true).unwrap();
        assert!(context.is_empty() && context.sources.is_empty());
        assert!(
            memory_context(&library, None, "", true)
                .unwrap()
                .sources
                .is_empty()
        );
    }
}
