//! pi RPC records (`PiRPCMessages.swift`): commands written to stdin and the
//! events read from stdout. Only the fields Agent Mode displays are decoded;
//! everything else becomes [`PiEvent::Unknown`] so protocol additions never
//! break the client.

use serde_json::{Map, Value, json};

/// Commands sent to pi, one JSON object per line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PiCommand {
    Prompt {
        id: String,
        message: String,
        streaming_behavior: Option<String>,
    },
    Steer {
        id: String,
        message: String,
    },
    Abort {
        id: String,
    },
    NewSession {
        id: String,
    },
    GetState {
        id: String,
    },
    GetMessages {
        id: String,
    },
    GetSessionStats {
        id: String,
    },
    UiConfirmResponse {
        request_id: String,
        confirmed: bool,
    },
    UiCancelResponse {
        request_id: String,
    },
}

impl PiCommand {
    /// The correlation id we put into the command, if pi answers it.
    /// UI responses correlate to pi's request id and get no response.
    pub fn id(&self) -> Option<&str> {
        match self {
            PiCommand::Prompt { id, .. }
            | PiCommand::Steer { id, .. }
            | PiCommand::Abort { id }
            | PiCommand::NewSession { id }
            | PiCommand::GetState { id }
            | PiCommand::GetMessages { id }
            | PiCommand::GetSessionStats { id } => Some(id),
            PiCommand::UiConfirmResponse { .. } | PiCommand::UiCancelResponse { .. } => None,
        }
    }

    /// One line of JSON with sorted keys and no trailing newline.
    pub fn json_line(&self) -> String {
        let value = match self {
            PiCommand::Prompt {
                id,
                message,
                streaming_behavior,
            } => {
                let mut value = json!({"type": "prompt", "id": id, "message": message});
                if let Some(behavior) = streaming_behavior {
                    value["streamingBehavior"] = json!(behavior);
                }
                value
            }
            PiCommand::Steer { id, message } => {
                json!({"type": "steer", "id": id, "message": message})
            }
            PiCommand::Abort { id } => json!({"type": "abort", "id": id}),
            PiCommand::NewSession { id } => json!({"type": "new_session", "id": id}),
            PiCommand::GetState { id } => json!({"type": "get_state", "id": id}),
            PiCommand::GetMessages { id } => json!({"type": "get_messages", "id": id}),
            PiCommand::GetSessionStats { id } => {
                json!({"type": "get_session_stats", "id": id})
            }
            PiCommand::UiConfirmResponse {
                request_id,
                confirmed,
            } => json!({"type": "extension_ui_response", "id": request_id, "confirmed": confirmed}),
            PiCommand::UiCancelResponse { request_id } => {
                json!({"type": "extension_ui_response", "id": request_id, "cancelled": true})
            }
        };
        canonical_json(&value)
    }
}

/// `{"type":"response", …}`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PiResponse {
    pub id: Option<String>,
    pub command: String,
    pub success: bool,
    pub error: Option<String>,
    /// `data`, re-encoded with sorted keys.
    pub data_json: Option<String>,
}

impl PiResponse {
    pub fn data(&self) -> Option<Value> {
        serde_json::from_str(self.data_json.as_deref()?).ok()
    }
}

/// An `extension_ui_request` (dialogs answered with `extension_ui_response`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PiUiRequest {
    pub id: String,
    pub method: String,
    pub title: Option<String>,
    pub message: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AssistantDelta {
    TextDelta(String),
    Other(String),
}

/// One decoded stdout record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PiEvent {
    Response(PiResponse),
    AgentStart,
    AgentEnd,
    AgentSettled,
    MessageStart {
        role: String,
    },
    MessageUpdate(AssistantDelta),
    MessageEnd {
        role: String,
        text: String,
        stop_reason: Option<String>,
        error_message: Option<String>,
    },
    ToolExecutionStart {
        call_id: String,
        name: String,
        args_json: String,
    },
    ToolExecutionUpdate {
        call_id: String,
        output: String,
    },
    ToolExecutionEnd {
        call_id: String,
        output: String,
        is_error: bool,
    },
    ExtensionUiRequest(PiUiRequest),
    ExtensionError {
        message: String,
    },
    Unknown {
        kind: String,
    },
}

impl PiEvent {
    /// Decodes one JSONL record; `None` when it is not a JSON object with a type.
    pub fn decode(line: &str) -> Option<PiEvent> {
        let value: Value = serde_json::from_str(line).ok()?;
        let object = value.as_object()?;
        let kind = object.get("type")?.as_str()?;
        let string = |key: &str| object.get(key).and_then(Value::as_str).map(str::to_string);
        Some(match kind {
            "response" => PiEvent::Response(PiResponse {
                id: string("id"),
                command: string("command").unwrap_or_default(),
                success: object
                    .get("success")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                error: string("error"),
                data_json: object
                    .get("data")
                    .filter(|data| data.is_object() || data.is_array())
                    .map(canonical_json),
            }),
            "agent_start" => PiEvent::AgentStart,
            "agent_end" => PiEvent::AgentEnd,
            "agent_settled" => PiEvent::AgentSettled,
            "message_start" => PiEvent::MessageStart {
                role: role(object.get("message")),
            },
            "message_update" => {
                let delta = object
                    .get("assistantMessageEvent")
                    .and_then(Value::as_object);
                let delta_kind = delta.and_then(|d| d.get("type")).and_then(Value::as_str);
                match (
                    delta_kind,
                    delta.and_then(|d| d.get("delta")).and_then(Value::as_str),
                ) {
                    (Some("text_delta"), Some(text)) => {
                        PiEvent::MessageUpdate(AssistantDelta::TextDelta(text.to_string()))
                    }
                    (Some(other), _) => PiEvent::MessageUpdate(AssistantDelta::Other(other.into())),
                    (None, _) => PiEvent::MessageUpdate(AssistantDelta::Other(String::new())),
                }
            }
            "message_end" => {
                let message = object.get("message").and_then(Value::as_object);
                let field = |key: &str| {
                    message
                        .and_then(|m| m.get(key))
                        .and_then(Value::as_str)
                        .map(str::to_string)
                };
                PiEvent::MessageEnd {
                    role: role(object.get("message")),
                    text: content_text(message.and_then(|m| m.get("content")), ""),
                    stop_reason: field("stopReason"),
                    error_message: field("errorMessage"),
                }
            }
            "tool_execution_start" => PiEvent::ToolExecutionStart {
                call_id: string("toolCallId").unwrap_or_default(),
                name: string("toolName").unwrap_or_default(),
                args_json: object
                    .get("args")
                    .filter(|args| args.is_object() || args.is_array())
                    .map(canonical_json)
                    .unwrap_or_else(|| "{}".into()),
            },
            "tool_execution_update" => PiEvent::ToolExecutionUpdate {
                call_id: string("toolCallId").unwrap_or_default(),
                output: result_text(object.get("partialResult")),
            },
            "tool_execution_end" => PiEvent::ToolExecutionEnd {
                call_id: string("toolCallId").unwrap_or_default(),
                output: result_text(object.get("result")),
                is_error: object
                    .get("isError")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            },
            "extension_ui_request" => match (string("id"), string("method")) {
                (Some(id), Some(method)) => PiEvent::ExtensionUiRequest(PiUiRequest {
                    id,
                    method,
                    title: string("title"),
                    message: string("message"),
                }),
                _ => PiEvent::Unknown { kind: kind.into() },
            },
            "extension_error" => PiEvent::ExtensionError {
                message: string("error")
                    .or_else(|| string("message"))
                    .unwrap_or_else(|| "extension error".into()),
            },
            other => PiEvent::Unknown { kind: other.into() },
        })
    }

    /// Text deltas are the only events that may be dropped under pressure.
    pub fn is_lossy_text_delta(&self) -> bool {
        matches!(self, PiEvent::MessageUpdate(AssistantDelta::TextDelta(_)))
    }
}

/// What a stopped assistant turn reports, or `None` when it finished normally.
pub fn terminal_failure(stop_reason: Option<&str>, error_message: Option<&str>) -> Option<String> {
    if stop_reason != Some("error") && stop_reason != Some("aborted") {
        return None;
    }
    if let Some(detail) = error_message.map(str::trim).filter(|d| !d.is_empty()) {
        return Some(detail.to_string());
    }
    Some(if stop_reason == Some("aborted") {
        "The model response was cancelled.".into()
    } else {
        "The model could not complete this response.".into()
    })
}

fn role(message: Option<&Value>) -> String {
    message
        .and_then(|m| m.get("role"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

/// Joins the `text` blocks of a `content` array (or returns a string content).
pub fn content_text(content: Option<&Value>, separator: &str) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|block| block.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join(separator),
        _ => String::new(),
    }
}

fn result_text(result: Option<&Value>) -> String {
    match result.and_then(|r| r.get("content")) {
        Some(Value::Array(_)) => content_text(result.and_then(|r| r.get("content")), "\n"),
        _ => String::new(),
    }
}

/// Compact JSON with recursively sorted keys and unescaped slashes, so
/// displayed arguments and stored data are stable whatever serde_json's map
/// ordering is.
pub fn canonical_json(value: &Value) -> String {
    fn sorted(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let mut keys: Vec<&String> = map.keys().collect();
                keys.sort();
                let mut out = Map::new();
                for key in keys {
                    out.insert(key.clone(), sorted(&map[key]));
                }
                Value::Object(out)
            }
            Value::Array(items) => Value::Array(items.iter().map(sorted).collect()),
            other => other.clone(),
        }
    }
    // With serde_json's `preserve_order` the map keeps insertion order, which
    // `sorted` made alphabetical; without it the map sorts anyway.
    serde_json::to_string(&sorted(value)).unwrap_or_else(|_| "{}".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn object(line: &str) -> Map<String, Value> {
        serde_json::from_str::<Value>(line)
            .unwrap()
            .as_object()
            .unwrap()
            .clone()
    }

    #[test]
    fn prompt_encodes_single_line() {
        let line = PiCommand::Prompt {
            id: "req-1".into(),
            message: "Hello\nworld".into(),
            streaming_behavior: None,
        }
        .json_line();
        assert!(!line.contains('\n'));
        let obj = object(&line);
        assert_eq!(obj["type"], "prompt");
        assert_eq!(obj["id"], "req-1");
        assert_eq!(obj["message"], "Hello\nworld");
        assert!(!obj.contains_key("streamingBehavior"));
    }

    #[test]
    fn prompt_with_steering_behavior() {
        let line = PiCommand::Prompt {
            id: "req-2".into(),
            message: "x".into(),
            streaming_behavior: Some("steer".into()),
        }
        .json_line();
        assert_eq!(object(&line)["streamingBehavior"], "steer");
    }

    #[test]
    fn ui_responses() {
        let confirm = object(
            &PiCommand::UiConfirmResponse {
                request_id: "uuid-2".into(),
                confirmed: true,
            }
            .json_line(),
        );
        assert_eq!(confirm["type"], "extension_ui_response");
        assert_eq!(confirm["id"], "uuid-2");
        assert_eq!(confirm["confirmed"], true);
        let cancel = object(
            &PiCommand::UiCancelResponse {
                request_id: "uuid-3".into(),
            }
            .json_line(),
        );
        assert_eq!(cancel["cancelled"], true);
        assert_eq!(
            PiCommand::UiCancelResponse {
                request_id: "x".into()
            }
            .id(),
            None
        );
    }

    #[test]
    fn simple_command_types() {
        let id = || "a".to_string();
        for (command, kind) in [
            (
                PiCommand::Steer {
                    id: id(),
                    message: "m".into(),
                },
                "steer",
            ),
            (PiCommand::Abort { id: id() }, "abort"),
            (PiCommand::NewSession { id: id() }, "new_session"),
            (PiCommand::GetState { id: id() }, "get_state"),
            (PiCommand::GetMessages { id: id() }, "get_messages"),
            (PiCommand::GetSessionStats { id: id() }, "get_session_stats"),
        ] {
            assert_eq!(object(&command.json_line())["type"], kind);
            assert_eq!(command.id(), Some("a"));
        }
    }

    #[test]
    fn decodes_response_and_preserves_data() {
        assert_eq!(
            PiEvent::decode(
                r#"{"id": "req-1", "type": "response", "command": "prompt", "success": true}"#
            ),
            Some(PiEvent::Response(PiResponse {
                id: Some("req-1".into()),
                command: "prompt".into(),
                success: true,
                error: None,
                data_json: None,
            }))
        );
        let Some(PiEvent::Response(response)) = PiEvent::decode(
            r#"{"id":"h1","type":"response","command":"get_messages","success":true,"data":{"messages":[{"role":"user","content":"Hi"}]}}"#,
        ) else {
            panic!("expected a response");
        };
        assert_eq!(
            response.data_json.as_deref(),
            Some(r#"{"messages":[{"content":"Hi","role":"user"}]}"#)
        );
    }

    #[test]
    fn decodes_lifecycle_and_text_deltas() {
        assert_eq!(
            PiEvent::decode(r#"{"type": "agent_start"}"#),
            Some(PiEvent::AgentStart)
        );
        assert_eq!(
            PiEvent::decode(r#"{"type": "agent_settled"}"#),
            Some(PiEvent::AgentSettled)
        );
        let line = r#"{"type":"message_update","message":{"role":"assistant","content":[]},"assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hello ","partial":{}}}"#;
        assert_eq!(
            PiEvent::decode(line),
            Some(PiEvent::MessageUpdate(AssistantDelta::TextDelta(
                "Hello ".into()
            )))
        );
        assert!(PiEvent::decode(line).unwrap().is_lossy_text_delta());
    }

    #[test]
    fn decodes_message_end_joining_text_blocks() {
        let line = r#"{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"boom","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Hello "},{"type":"text","text":"world"}]}}"#;
        assert_eq!(
            PiEvent::decode(line),
            Some(PiEvent::MessageEnd {
                role: "assistant".into(),
                text: "Hello world".into(),
                stop_reason: Some("error".into()),
                error_message: Some("boom".into()),
            })
        );
    }

    #[test]
    fn decodes_tool_lifecycle_without_escaping_slashes() {
        assert_eq!(
            PiEvent::decode(
                r#"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"read","args":{"path":"/Users/me/notes.md"}}"#
            ),
            Some(PiEvent::ToolExecutionStart {
                call_id: "call_1".into(),
                name: "read".into(),
                args_json: r#"{"path":"/Users/me/notes.md"}"#.into(),
            })
        );
        assert_eq!(
            PiEvent::decode(
                r#"{"type":"tool_execution_update","toolCallId":"c","partialResult":{"content":[{"type":"text","text":"partial"}],"details":{}}}"#
            ),
            Some(PiEvent::ToolExecutionUpdate {
                call_id: "c".into(),
                output: "partial".into()
            })
        );
        assert_eq!(
            PiEvent::decode(
                r#"{"type":"tool_execution_end","toolCallId":"c","result":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]},"isError":true}"#
            ),
            Some(PiEvent::ToolExecutionEnd {
                call_id: "c".into(),
                output: "a\nb".into(),
                is_error: true
            })
        );
    }

    #[test]
    fn decodes_extension_ui_confirm_request() {
        let line = r#"{"type":"extension_ui_request","id":"uuid-2","method":"confirm","title":"lokalbot_tool_approval","message":"{\"tool\":\"bash\"}"}"#;
        assert_eq!(
            PiEvent::decode(line),
            Some(PiEvent::ExtensionUiRequest(PiUiRequest {
                id: "uuid-2".into(),
                method: "confirm".into(),
                title: Some("lokalbot_tool_approval".into()),
                message: Some(r#"{"tool":"bash"}"#.into()),
            }))
        );
    }

    #[test]
    fn unknown_and_garbage() {
        assert_eq!(
            PiEvent::decode(r#"{"type":"queue_update","steering":[]}"#),
            Some(PiEvent::Unknown {
                kind: "queue_update".into()
            })
        );
        assert_eq!(PiEvent::decode("not json"), None);
        assert_eq!(PiEvent::decode("[1,2,3]"), None);
    }

    #[test]
    fn terminal_failures() {
        assert_eq!(terminal_failure(Some("stop"), None), None);
        assert_eq!(
            terminal_failure(Some("aborted"), Some("  ")).as_deref(),
            Some("The model response was cancelled.")
        );
        assert_eq!(
            terminal_failure(Some("error"), Some("HTTP 500")).as_deref(),
            Some("HTTP 500")
        );
    }
}
