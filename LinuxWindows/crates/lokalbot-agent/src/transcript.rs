//! The display transcript (`AgentTranscript.swift`): a pure state machine
//! that folds pi events into ordered items, so every folding rule is unit
//! tested without a process or UI.

use crate::messages::{AssistantDelta, PiEvent, terminal_failure};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolStatus {
    Running,
    Succeeded,
    Failed,
}

/// One edit of an `edit` request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Edit {
    pub old_text: String,
    pub new_text: String,
}

/// An app-owned, structured description of a tool request, so the approval
/// card shows the exact command or content rather than a model-written
/// summary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApprovalRequest {
    pub id: String,
    pub tool: String,
    pub workspace: Option<String>,
    pub path: Option<String>,
    pub command: Option<String>,
    pub content: Option<String>,
    pub edits: Vec<Edit>,
    pub summary: Option<String>,
    pub is_truncated: bool,
    /// Exact JSON arguments of a tool without a dedicated preview (MCP tools,
    /// codemode, tools later pi releases add).
    pub arguments: Option<String>,
}

pub const MAX_APPROVAL_TEXT_UTF16: usize = 64 * 1024;

pub fn is_shell_tool(tool: &str) -> bool {
    matches!(
        tool.to_lowercase().as_str(),
        "bash" | "shell" | "powershell"
    )
}

impl ApprovalRequest {
    /// Also enforced by the extension before it asks. The host stays fail
    /// closed for old, malformed or locally bounded payloads. Lengths are
    /// UTF-16 units, as JavaScript counts them.
    pub fn can_approve(&self) -> bool {
        if let Some(arguments) = &self.arguments {
            return !self.is_truncated
                && arguments.encode_utf16().count() <= MAX_APPROVAL_TEXT_UTF16;
        }
        if !is_shell_tool(&self.tool) {
            return true;
        }
        match &self.command {
            Some(command) if !command.is_empty() => {
                !self.is_truncated && command.encode_utf16().count() <= MAX_APPROVAL_TEXT_UTF16
            }
            _ => false,
        }
    }

    pub fn has_structured_details(&self) -> bool {
        self.workspace.is_some()
            || self.path.is_some()
            || self.command.is_some()
            || self.content.is_some()
            || !self.edits.is_empty()
            || self.arguments.is_some()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TranscriptItem {
    User {
        id: String,
        text: String,
    },
    Assistant {
        id: String,
        text: String,
        is_streaming: bool,
    },
    Tool {
        id: String,
        name: String,
        args_json: String,
        output: String,
        status: ToolStatus,
    },
    Approval(ApprovalRequest),
    Notice {
        id: String,
        text: String,
        is_error: bool,
    },
}

impl TranscriptItem {
    pub fn id(&self) -> &str {
        match self {
            TranscriptItem::User { id, .. }
            | TranscriptItem::Assistant { id, .. }
            | TranscriptItem::Tool { id, .. }
            | TranscriptItem::Notice { id, .. } => id,
            TranscriptItem::Approval(request) => &request.id,
        }
    }

    pub fn searchable_text(&self) -> String {
        match self {
            TranscriptItem::User { text, .. }
            | TranscriptItem::Assistant { text, .. }
            | TranscriptItem::Notice { text, .. } => text.clone(),
            TranscriptItem::Tool {
                name,
                args_json,
                output,
                ..
            } => format!("{name} {args_json} {output}"),
            TranscriptItem::Approval(request) => {
                format!("{} {}", request.tool, request.path.as_deref().unwrap_or(""))
            }
        }
    }

    fn character_count(&self) -> usize {
        let count = |s: &str| s.chars().count();
        match self {
            TranscriptItem::User { id, text } | TranscriptItem::Notice { id, text, .. } => {
                count(id) + count(text)
            }
            TranscriptItem::Assistant { id, text, .. } => count(id) + count(text),
            TranscriptItem::Tool {
                id,
                name,
                args_json,
                output,
                ..
            } => count(id) + count(name) + count(args_json) + count(output),
            TranscriptItem::Approval(r) => {
                let optional = |v: &Option<String>| v.as_deref().map(count).unwrap_or(0);
                count(&r.id)
                    + count(&r.tool)
                    + optional(&r.workspace)
                    + optional(&r.path)
                    + optional(&r.command)
                    + optional(&r.arguments)
                    + optional(&r.content)
                    + optional(&r.summary)
                    + r.edits
                        .iter()
                        .map(|e| count(&e.old_text) + count(&e.new_text))
                        .sum::<usize>()
            }
        }
    }
}

/// Folds pi events into display items.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TranscriptFolder {
    items: Vec<TranscriptItem>,
    is_agent_running: bool,
    terminal_failure: Option<String>,
    streaming_assistant_id: Option<String>,
    streaming_assistant_characters: usize,
    retained_characters: usize,
    counter: u64,
}

impl TranscriptFolder {
    pub const MAX_ITEMS: usize = 500;
    pub const MAX_MESSAGE_CHARACTERS: usize = 1_000_000;
    pub const MAX_TOOL_CHARACTERS: usize = 256 * 1024;
    pub const MAX_TOTAL_CHARACTERS: usize = 8 * 1024 * 1024;
    pub const MAX_PENDING_APPROVALS: usize = 16;
    pub const MAX_APPROVAL_ID_CHARACTERS: usize = 1024;

    pub fn items(&self) -> &[TranscriptItem] {
        &self.items
    }

    pub fn is_agent_running(&self) -> bool {
        self.is_agent_running
    }

    pub fn terminal_failure(&self) -> Option<&str> {
        self.terminal_failure.as_deref()
    }

    fn streaming_index(&self) -> Option<usize> {
        let id = self.streaming_assistant_id.as_deref()?;
        self.items.iter().position(|item| item.id() == id)
    }

    // ------------------------------------------------- local inserts

    pub fn note_user_prompt(&mut self, text: &str) {
        let id = self.next_id("user");
        self.append(TranscriptItem::User {
            id,
            text: bounded(text, Self::MAX_MESSAGE_CHARACTERS),
        });
    }

    pub fn append_assistant_message(&mut self, text: &str) {
        let id = self.next_id("assistant");
        self.append(TranscriptItem::Assistant {
            id,
            text: bounded(text, Self::MAX_MESSAGE_CHARACTERS),
            is_streaming: false,
        });
    }

    pub fn append_notice(&mut self, text: &str, is_error: bool) {
        let id = self.next_id("notice");
        self.append(TranscriptItem::Notice {
            id,
            text: bounded(text, Self::MAX_MESSAGE_CHARACTERS),
            is_error,
        });
    }

    pub fn can_accept_approval(&self) -> bool {
        self.pending_approval_ids().len() < Self::MAX_PENDING_APPROVALS
    }

    /// False when too many approvals are waiting or the id is oversized.
    pub fn add_approval(&mut self, request: ApprovalRequest) -> bool {
        if !self.can_accept_approval()
            || request.id.chars().count() > Self::MAX_APPROVAL_ID_CHARACTERS
        {
            return false;
        }
        self.append(TranscriptItem::Approval(bounded_approval(request)));
        true
    }

    pub fn resolve_approval(&mut self, request_id: &str) {
        if let Some(index) = self.items.iter().position(
            |item| matches!(item, TranscriptItem::Approval(request) if request.id == request_id),
        ) {
            self.remove(index);
        }
    }

    pub fn pending_approval_ids(&self) -> Vec<String> {
        self.items
            .iter()
            .filter_map(|item| match item {
                TranscriptItem::Approval(request) => Some(request.id.clone()),
                _ => None,
            })
            .collect()
    }

    pub fn pending_approvals(&self) -> Vec<&ApprovalRequest> {
        self.items
            .iter()
            .filter_map(|item| match item {
                TranscriptItem::Approval(request) => Some(request),
                _ => None,
            })
            .collect()
    }

    pub fn approval(&self, id: &str) -> Option<&ApprovalRequest> {
        self.pending_approvals().into_iter().find(|r| r.id == id)
    }

    pub fn resolve_all_approvals(&mut self) {
        for index in (0..self.items.len()).rev() {
            if matches!(self.items[index], TranscriptItem::Approval(_)) {
                self.remove(index);
            }
        }
    }

    /// Drops the oldest non-approval items until within the item and
    /// character budgets.
    pub fn enforce_resource_limits(&mut self) {
        while self.items.len() > Self::MAX_ITEMS
            || self.retained_characters > Self::MAX_TOTAL_CHARACTERS
        {
            let Some(index) = self
                .items
                .iter()
                .position(|item| !matches!(item, TranscriptItem::Approval(_)))
            else {
                break;
            };
            self.remove(index);
        }
    }

    // --------------------------------------------------------- folding

    pub fn fold(&mut self, event: &PiEvent) {
        match event {
            PiEvent::AgentStart => {
                self.is_agent_running = true;
                self.terminal_failure = None;
            }
            PiEvent::AgentSettled => {
                self.is_agent_running = false;
                self.finish_streaming_assistant();
                if let Some(failure) = self.terminal_failure.clone() {
                    self.append_notice(&failure, true);
                }
            }
            PiEvent::MessageStart { role } => {
                if role != "assistant" {
                    return;
                }
                // A fresh attempt can recover from pi's automatic retry; only
                // the outcome left at agent_settled is terminal.
                self.terminal_failure = None;
                let id = self.next_id("assistant");
                self.append(TranscriptItem::Assistant {
                    id: id.clone(),
                    text: String::new(),
                    is_streaming: true,
                });
                self.streaming_assistant_id = Some(id);
                self.streaming_assistant_characters = 0;
            }
            PiEvent::MessageUpdate(AssistantDelta::TextDelta(delta)) => {
                self.append_to_streaming_assistant(delta)
            }
            PiEvent::MessageEnd {
                role,
                text,
                stop_reason,
                error_message,
            } => {
                if role != "assistant" {
                    return;
                }
                self.terminal_failure =
                    terminal_failure(stop_reason.as_deref(), error_message.as_deref());
                if let Some(index) = self.streaming_index() {
                    if let TranscriptItem::Assistant {
                        id, text: streamed, ..
                    } = self.items[index].clone()
                    {
                        let final_text = bounded(
                            if text.is_empty() { &streamed } else { text },
                            Self::MAX_MESSAGE_CHARACTERS,
                        );
                        if final_text.is_empty() {
                            self.remove(index); // tool-call-only turn
                        } else {
                            self.replace(
                                index,
                                TranscriptItem::Assistant {
                                    id,
                                    text: final_text,
                                    is_streaming: false,
                                },
                            );
                        }
                    }
                } else if !text.is_empty() {
                    let id = self.next_id("assistant");
                    self.append(TranscriptItem::Assistant {
                        id,
                        text: bounded(text, Self::MAX_MESSAGE_CHARACTERS),
                        is_streaming: false,
                    });
                }
                self.streaming_assistant_id = None;
                self.streaming_assistant_characters = 0;
            }
            PiEvent::ToolExecutionStart {
                call_id,
                name,
                args_json,
            } => self.append(TranscriptItem::Tool {
                id: call_id.clone(),
                name: bounded(name, 256),
                args_json: bounded(args_json, Self::MAX_TOOL_CHARACTERS),
                output: String::new(),
                status: ToolStatus::Running,
            }),
            PiEvent::ToolExecutionUpdate { call_id, output } => {
                self.update_tool(call_id, output, ToolStatus::Running)
            }
            PiEvent::ToolExecutionEnd {
                call_id,
                output,
                is_error,
            } => self.update_tool(
                call_id,
                output,
                if *is_error {
                    ToolStatus::Failed
                } else {
                    ToolStatus::Succeeded
                },
            ),
            PiEvent::ExtensionError { message } => self.append_notice(message, true),
            PiEvent::AgentEnd
            | PiEvent::MessageUpdate(_)
            | PiEvent::Response(_)
            | PiEvent::ExtensionUiRequest(_)
            | PiEvent::Unknown { .. } => {}
        }
    }

    // --------------------------------------------------------- helpers

    fn next_id(&mut self, prefix: &str) -> String {
        self.counter += 1;
        format!("{prefix}-{}", self.counter)
    }

    fn append(&mut self, item: TranscriptItem) {
        self.retained_characters += item.character_count();
        self.items.push(item);
    }

    fn replace(&mut self, index: usize, item: TranscriptItem) {
        self.retained_characters = self
            .retained_characters
            .saturating_sub(self.items[index].character_count())
            + item.character_count();
        self.items[index] = item;
    }

    fn remove(&mut self, index: usize) {
        let item = self.items.remove(index);
        self.retained_characters = self
            .retained_characters
            .saturating_sub(item.character_count());
    }

    fn append_to_streaming_assistant(&mut self, delta: &str) {
        if self.streaming_index().is_none() {
            let id = self.next_id("assistant");
            self.append(TranscriptItem::Assistant {
                id: id.clone(),
                text: String::new(),
                is_streaming: true,
            });
            self.streaming_assistant_id = Some(id);
            self.streaming_assistant_characters = 0;
        }
        let Some(index) = self.streaming_index() else {
            return;
        };
        let room = Self::MAX_MESSAGE_CHARACTERS.saturating_sub(self.streaming_assistant_characters);
        if room == 0 {
            return;
        }
        let bounded_delta = bounded(delta, room);
        let added = bounded_delta.chars().count();
        if let TranscriptItem::Assistant { text, .. } = &mut self.items[index] {
            text.push_str(&bounded_delta);
            self.streaming_assistant_characters += added;
            self.retained_characters += added;
        }
    }

    fn finish_streaming_assistant(&mut self) {
        if let Some(index) = self.streaming_index() {
            let empty = matches!(&self.items[index], TranscriptItem::Assistant { text, .. } if text.is_empty());
            if empty {
                self.remove(index);
            } else if let TranscriptItem::Assistant { is_streaming, .. } = &mut self.items[index] {
                *is_streaming = false;
            }
        }
        self.streaming_assistant_id = None;
        self.streaming_assistant_characters = 0;
    }

    fn update_tool(&mut self, call_id: &str, output: &str, status: ToolStatus) {
        let Some(index) = self.items.iter().position(|item| item.id() == call_id) else {
            return;
        };
        if let TranscriptItem::Tool {
            id,
            name,
            args_json,
            ..
        } = self.items[index].clone()
        {
            self.replace(
                index,
                TranscriptItem::Tool {
                    id,
                    name,
                    args_json,
                    output: bounded(output, Self::MAX_TOOL_CHARACTERS),
                    status,
                },
            );
        }
    }
}

fn bounded(text: &str, limit: usize) -> String {
    match text.char_indices().nth(limit) {
        Some((at, _)) => text[..at].to_string(),
        None => text.to_string(),
    }
}

/// Bounds a card's preview fields to one shared budget; anything cut marks
/// it truncated, which also blocks approving a shell command or arguments.
fn bounded_approval(request: ApprovalRequest) -> ApprovalRequest {
    struct Budget {
        remaining: usize,
        truncated: bool,
    }
    impl Budget {
        fn take(&mut self, value: Option<String>) -> Option<String> {
            let value = value?;
            let kept = bounded(&value, self.remaining);
            let kept_count = kept.chars().count();
            if kept_count < value.chars().count() {
                self.truncated = true;
            }
            self.remaining -= kept_count;
            Some(kept)
        }
    }
    let mut budget = Budget {
        remaining: TranscriptFolder::MAX_TOOL_CHARACTERS,
        truncated: request.is_truncated,
    };
    let workspace = budget.take(request.workspace);
    let path = budget.take(request.path);
    let command = budget.take(request.command);
    let arguments = budget.take(request.arguments);
    let content = budget.take(request.content);
    let mut edits = Vec::new();
    let edit_count = request.edits.len();
    for edit in request.edits {
        if budget.remaining == 0 {
            break;
        }
        let old_text = budget.take(Some(edit.old_text)).unwrap_or_default();
        let new_text = budget.take(Some(edit.new_text)).unwrap_or_default();
        edits.push(Edit { old_text, new_text });
    }
    if edits.len() < edit_count {
        budget.truncated = true;
    }
    let summary = budget.take(request.summary);
    ApprovalRequest {
        id: request.id,
        tool: bounded(&request.tool, 256),
        workspace,
        path,
        command,
        content,
        edits,
        summary,
        is_truncated: budget.truncated,
        arguments,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn end(text: &str) -> PiEvent {
        PiEvent::MessageEnd {
            role: "assistant".into(),
            text: text.into(),
            stop_reason: None,
            error_message: None,
        }
    }

    fn start() -> PiEvent {
        PiEvent::MessageStart {
            role: "assistant".into(),
        }
    }

    fn delta(text: &str) -> PiEvent {
        PiEvent::MessageUpdate(AssistantDelta::TextDelta(text.into()))
    }

    fn approval(id: &str, command: &str) -> ApprovalRequest {
        ApprovalRequest {
            id: id.into(),
            tool: "bash".into(),
            workspace: Some("/tmp".into()),
            path: None,
            command: Some(command.into()),
            content: None,
            edits: Vec::new(),
            summary: None,
            is_truncated: false,
            arguments: None,
        }
    }

    #[test]
    fn terminal_model_error_preserves_partial_answer_and_failure() {
        let mut folder = TranscriptFolder::default();
        folder.fold(&PiEvent::AgentStart);
        folder.fold(&start());
        folder.fold(&delta("Partial answer"));
        folder.fold(
            &PiEvent::decode(r#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"401 Invalid API key"}}"#)
                .unwrap(),
        );
        assert!(
            !folder
                .items()
                .iter()
                .any(|i| matches!(i, TranscriptItem::Notice { .. }))
        );
        folder.fold(&PiEvent::AgentSettled);
        assert_eq!(folder.terminal_failure(), Some("401 Invalid API key"));
        assert!(folder.items().iter().any(|i| matches!(i, TranscriptItem::Assistant { text, is_streaming: false, .. } if text == "Partial answer")));
        assert!(folder.items().iter().any(|i| matches!(i, TranscriptItem::Notice { text, is_error: true, .. } if text == "401 Invalid API key")));
    }

    #[test]
    fn automatic_retry_success_is_not_a_terminal_failure() {
        let mut folder = TranscriptFolder::default();
        folder.fold(&PiEvent::AgentStart);
        folder.fold(&PiEvent::MessageEnd {
            role: "assistant".into(),
            text: String::new(),
            stop_reason: Some("error".into()),
            error_message: Some("retry me".into()),
        });
        folder.fold(&PiEvent::AgentEnd);
        folder.fold(&start());
        folder.fold(&PiEvent::MessageEnd {
            role: "assistant".into(),
            text: "Recovered".into(),
            stop_reason: Some("stop".into()),
            error_message: None,
        });
        folder.fold(&PiEvent::AgentSettled);
        assert_eq!(folder.terminal_failure(), None);
        assert!(
            !folder
                .items()
                .iter()
                .any(|i| matches!(i, TranscriptItem::Notice { is_error: true, .. }))
        );
    }

    #[test]
    fn streaming_assistant_message_lifecycle() {
        let mut folder = TranscriptFolder::default();
        folder.fold(&PiEvent::AgentStart);
        assert!(folder.is_agent_running());
        folder.fold(&start());
        folder.fold(&delta("Hello"));
        folder.fold(&delta(" world"));
        assert!(
            matches!(folder.items().last(), Some(TranscriptItem::Assistant { text, is_streaming: true, .. }) if text == "Hello world")
        );
        folder.fold(&end("Hello world!"));
        folder.fold(&PiEvent::AgentSettled);
        assert!(!folder.is_agent_running());
        assert_eq!(folder.items().len(), 1);
        assert!(
            matches!(&folder.items()[0], TranscriptItem::Assistant { text, is_streaming: false, .. } if text == "Hello world!")
        );
    }

    #[test]
    fn delta_without_message_start_creates_bubble_and_empty_bubbles_drop() {
        let mut folder = TranscriptFolder::default();
        folder.fold(&delta("hi"));
        assert!(
            matches!(&folder.items()[0], TranscriptItem::Assistant { text, is_streaming: true, .. } if text == "hi")
        );
        let mut empty = TranscriptFolder::default();
        empty.fold(&start());
        empty.fold(&end(""));
        assert!(empty.items().is_empty());
        empty.fold(&PiEvent::MessageStart {
            role: "user".into(),
        });
        empty.fold(&PiEvent::MessageEnd {
            role: "toolResult".into(),
            text: "x".into(),
            stop_reason: None,
            error_message: None,
        });
        assert!(empty.items().is_empty());
    }

    #[test]
    fn tool_card_lifecycle() {
        let mut folder = TranscriptFolder::default();
        folder.fold(&PiEvent::ToolExecutionStart {
            call_id: "call_1".into(),
            name: "bash".into(),
            args_json: r#"{"command":"ls"}"#.into(),
        });
        folder.fold(&PiEvent::ToolExecutionUpdate {
            call_id: "call_1".into(),
            output: "partial".into(),
        });
        folder.fold(&PiEvent::ToolExecutionEnd {
            call_id: "call_1".into(),
            output: "total 48".into(),
            is_error: false,
        });
        assert_eq!(
            folder.items(),
            &[TranscriptItem::Tool {
                id: "call_1".into(),
                name: "bash".into(),
                args_json: r#"{"command":"ls"}"#.into(),
                output: "total 48".into(),
                status: ToolStatus::Succeeded,
            }]
        );
        folder.fold(&PiEvent::ToolExecutionStart {
            call_id: "call_2".into(),
            name: "write".into(),
            args_json: "{}".into(),
        });
        folder.fold(&PiEvent::ToolExecutionEnd {
            call_id: "call_2".into(),
            output: "denied".into(),
            is_error: true,
        });
        assert!(matches!(
            folder.items()[1],
            TranscriptItem::Tool {
                status: ToolStatus::Failed,
                ..
            }
        ));
    }

    #[test]
    fn resolving_an_approval_keeps_deltas_on_the_right_bubble() {
        let mut folder = TranscriptFolder::default();
        folder.add_approval(approval("uuid-1", "ls"));
        folder.fold(&start());
        folder.fold(&delta("Hello"));
        folder.resolve_approval("uuid-1");
        folder.fold(&delta(" world"));
        assert_eq!(folder.items().len(), 1);
        assert!(
            matches!(&folder.items()[0], TranscriptItem::Assistant { text, is_streaming: true, .. } if text == "Hello world")
        );
        folder.fold(&end(""));
        assert!(
            matches!(&folder.items()[0], TranscriptItem::Assistant { text, is_streaming: false, .. } if text == "Hello world")
        );
    }

    #[test]
    fn user_prompts_notices_and_settling() {
        let mut folder = TranscriptFolder::default();
        folder.note_user_prompt("do the thing");
        folder.append_notice("Denied bash", false);
        folder.fold(&PiEvent::ExtensionError {
            message: "boom".into(),
        });
        assert!(
            matches!(&folder.items()[2], TranscriptItem::Notice { text, is_error: true, .. } if text == "boom")
        );
        let mut aborted = TranscriptFolder::default();
        aborted.fold(&delta("partial answer"));
        aborted.fold(&PiEvent::AgentSettled);
        assert!(
            matches!(&aborted.items()[0], TranscriptItem::Assistant { text, is_streaming: false, .. } if text == "partial answer")
        );
    }

    #[test]
    fn every_message_insertion_path_is_bounded() {
        let oversized = "x".repeat(TranscriptFolder::MAX_MESSAGE_CHARACTERS + 1);
        let mut folder = TranscriptFolder::default();
        folder.note_user_prompt(&oversized);
        folder.append_assistant_message(&oversized);
        folder.append_notice(&oversized, false);
        folder.fold(&end(&oversized));
        assert_eq!(folder.items().len(), 4);
        for item in folder.items() {
            let text = match item {
                TranscriptItem::User { text, .. }
                | TranscriptItem::Assistant { text, .. }
                | TranscriptItem::Notice { text, .. } => text,
                other => panic!("unexpected {other:?}"),
            };
            assert_eq!(
                text.chars().count(),
                TranscriptFolder::MAX_MESSAGE_CHARACTERS
            );
        }
    }

    #[test]
    fn resource_limit_evicts_oldest_text() {
        let mut folder = TranscriptFolder::default();
        for index in 0..10 {
            folder.note_user_prompt(&format!(
                "{index}{}",
                "x".repeat(TranscriptFolder::MAX_MESSAGE_CHARACTERS - 1)
            ));
        }
        folder.enforce_resource_limits();
        assert!(folder.items().len() < 10);
        let retained: usize = folder
            .items()
            .iter()
            .map(|item| match item {
                TranscriptItem::User { text, .. } => text.len(),
                _ => 0,
            })
            .sum();
        assert!(retained <= TranscriptFolder::MAX_TOTAL_CHARACTERS);
        assert!(
            !folder
                .items()
                .iter()
                .any(|i| matches!(i, TranscriptItem::User { text, .. } if text.starts_with('0')))
        );
    }

    #[test]
    fn approvals_have_independent_count_and_preview_bounds() {
        let mut folder = TranscriptFolder::default();
        let oversized = "x".repeat(TranscriptFolder::MAX_TOOL_CHARACTERS + 1);
        for index in 0..TranscriptFolder::MAX_PENDING_APPROVALS {
            assert!(folder.add_approval(approval(&format!("approval-{index}"), &oversized)));
        }
        assert!(!folder.add_approval(approval("overflow", "must be rejected")));
        assert_eq!(
            folder.pending_approval_ids().len(),
            TranscriptFolder::MAX_PENDING_APPROVALS
        );
        let TranscriptItem::Approval(first) = &folder.items()[0] else {
            panic!("expected an approval");
        };
        assert_eq!(
            first.workspace.as_ref().unwrap().len() + first.command.as_ref().unwrap().len(),
            TranscriptFolder::MAX_TOOL_CHARACTERS
        );
        assert!(first.is_truncated);
        assert!(!first.can_approve());
        let mut fresh = TranscriptFolder::default();
        assert!(!fresh.add_approval(approval(
            &"i".repeat(TranscriptFolder::MAX_APPROVAL_ID_CHARACTERS + 1),
            "oversized id"
        )));
    }

    #[test]
    fn shell_approval_requires_the_complete_command_in_utf16_units() {
        let mut request = approval("a", &"#".repeat(MAX_APPROVAL_TEXT_UTF16));
        assert!(request.can_approve());
        // 32,768 emoji are 65,536 UTF-16 units; one more character is over.
        request.command = Some(format!("{}x", "😀".repeat(32_768)));
        assert!(!request.can_approve());
        request.command = None;
        assert!(!request.can_approve());
        request.tool = "powershell".into();
        request.command = Some("Get-ChildItem".into());
        assert!(request.can_approve());
        let mut other = approval("b", "");
        other.tool = "mcp__stub__touch".into();
        other.command = None;
        other.arguments = Some("{}".into());
        assert!(other.can_approve());
        other.arguments = Some("x".repeat(MAX_APPROVAL_TEXT_UTF16 + 1));
        assert!(!other.can_approve());
    }
}
