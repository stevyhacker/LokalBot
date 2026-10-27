//! Read-only transcript loading and branching (`AgentConversationArchive.swift`).
//! Opening a saved conversation needs no model, process, tool run or grant.

use std::collections::{HashMap, HashSet};
use std::io::Read as _;
use std::path::Path;

use serde_json::{Map, Value};

use crate::history::{self, SavedSession};
use crate::messages::{PiEvent, canonical_json, terminal_failure};
use crate::tasks::Attachment;
use crate::transcript::{TranscriptFolder, TranscriptItem};

pub const MAX_BYTES: usize = 32 * 1024 * 1024;

#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum ArchiveError {
    #[error("That saved task is no longer available. Refresh the task list and try again.")]
    Unavailable,
    #[error(
        "This conversation is too large to preview (32 MB limit). Its saved history is unchanged."
    )]
    TooLarge,
    #[error(
        "This message is not yet available in saved history. Wait for the turn to finish and try again."
    )]
    UnsavedMessage,
    #[error("The saved conversation could not be read: {0}")]
    Corrupt(String),
}

type Record = Map<String, Value>;

/// Every record of a validated session file.
pub fn records(session: &SavedSession, directory: &Path) -> Result<Vec<Record>, ArchiveError> {
    if history::validated(session, directory).is_none() {
        return Err(ArchiveError::Unavailable);
    }
    let mut data = Vec::new();
    std::fs::File::open(&session.file)
        .map_err(|_| ArchiveError::Unavailable)?
        .take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|err| ArchiveError::Corrupt(err.to_string()))?;
    if data.len() > MAX_BYTES {
        return Err(ArchiveError::TooLarge);
    }
    data.split(|b| *b == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| match serde_json::from_slice::<Value>(line) {
            Ok(Value::Object(record)) => Ok(record),
            _ => Err(ArchiveError::Corrupt("a line is not a JSON object".into())),
        })
        .collect()
}

/// pi files hold a tree; only the newest leaf's ancestors are visible, so
/// abandoned branches never leak into previews or forks.
pub fn active_branch(records: &[Record]) -> Vec<Record> {
    let entries: Vec<&Record> = records
        .iter()
        .filter(|r| r.get("type").and_then(Value::as_str) != Some("session"))
        .collect();
    let Some(leaf) = entries
        .last()
        .and_then(|e| e.get("id"))
        .and_then(Value::as_str)
    else {
        return entries.into_iter().cloned().collect();
    };
    let by_id: HashMap<&str, &Record> = entries
        .iter()
        .filter_map(|e| Some((e.get("id")?.as_str()?, *e)))
        .collect();
    let mut result = Vec::new();
    let mut visited = HashSet::new();
    let mut next = Some(leaf);
    while let Some(id) = next {
        if !visited.insert(id) {
            break;
        }
        let Some(entry) = by_id.get(id) else {
            break;
        };
        result.push((*entry).clone());
        next = entry.get("parentId").and_then(Value::as_str);
    }
    result.reverse();
    result
}

/// A saved conversation as a transcript, with the sources each prompt carried.
pub struct Preview {
    pub folder: TranscriptFolder,
    pub attachments: HashMap<String, Vec<Attachment>>,
}

pub fn preview(session: &SavedSession, directory: &Path) -> Result<Preview, ArchiveError> {
    let mut folder = TranscriptFolder::default();
    let mut attachments: HashMap<String, Vec<Attachment>> = HashMap::new();
    for entry in active_branch(&records(session, directory)?) {
        let Some(message) = entry.get("message").and_then(Value::as_object) else {
            continue;
        };
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let text = message_text(message);
        match role {
            "user" if !text.is_empty() => {
                folder.note_user_prompt(crate::context::display_prompt(&text));
                if let Some(item) = folder.items().last() {
                    attachments
                        .insert(item.id().to_string(), crate::context::attachments_in(&text));
                }
            }
            "assistant" => {
                if !text.is_empty() {
                    folder.append_assistant_message(&text);
                }
                if let Some(failure) = terminal_failure(
                    message.get("stopReason").and_then(Value::as_str),
                    message.get("errorMessage").and_then(Value::as_str),
                ) {
                    folder.append_notice(&failure, true);
                }
                for block in message
                    .get("content")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("toolCall"))
                {
                    folder.fold(&PiEvent::ToolExecutionStart {
                        call_id: block
                            .get("id")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string()),
                        name: block
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or("Tool")
                            .to_string(),
                        args_json: canonical_json(
                            block.get("arguments").unwrap_or(&Value::Object(Map::new())),
                        ),
                    });
                }
            }
            "toolResult" => folder.fold(&PiEvent::ToolExecutionEnd {
                call_id: message
                    .get("toolCallId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                output: text,
                is_error: message
                    .get("isError")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            }),
            _ => {}
        }
    }
    folder.enforce_resource_limits();
    let visible: HashSet<String> = folder.items().iter().map(|i| i.id().to_string()).collect();
    attachments.retain(|id, _| visible.contains(id));
    Ok(Preview {
        folder,
        attachments,
    })
}

/// Writes a new session file through `item` (the `matching_occurrence_from_end`
/// -th identical message, counted from the end), including the recorded
/// results of its tool calls, so the fork never has dangling calls.
pub fn fork(
    session: &SavedSession,
    item: &TranscriptItem,
    matching_occurrence_from_end: usize,
    directory: &Path,
) -> Result<SavedSession, ArchiveError> {
    let (role, text) = match item {
        TranscriptItem::User { text, .. } => ("user", text.as_str()),
        TranscriptItem::Assistant {
            text,
            is_streaming: false,
            ..
        } => ("assistant", text.as_str()),
        _ => return Err(ArchiveError::UnsavedMessage),
    };
    let raw = records(session, directory)?;
    let branch = active_branch(&raw);
    let matches: Vec<usize> = branch
        .iter()
        .enumerate()
        .filter(|(_, entry)| {
            let Some(message) = entry.get("message").and_then(Value::as_object) else {
                return false;
            };
            if message.get("role").and_then(Value::as_str) != Some(role) {
                return false;
            }
            let body = message_text(message);
            if role == "user" {
                crate::context::display_prompt(&body) == text
            } else {
                body == text
            }
        })
        .map(|(index, _)| index)
        .collect();
    let mut header = raw
        .first()
        .filter(|h| h.get("type").and_then(Value::as_str) == Some("session"))
        .cloned()
        .ok_or(ArchiveError::UnsavedMessage)?;
    if matching_occurrence_from_end >= matches.len() {
        return Err(ArchiveError::UnsavedMessage);
    }
    let mut last = matches[matches.len() - 1 - matching_occurrence_from_end];
    let mut pending: HashSet<String> = branch[last]
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("toolCall"))
        .filter_map(|b| b.get("id").and_then(Value::as_str).map(str::to_string))
        .collect();
    while !pending.is_empty() && last + 1 < branch.len() {
        let next = branch[last + 1].get("message").and_then(Value::as_object);
        if next.is_some_and(|m| m.get("role").and_then(Value::as_str) != Some("toolResult")) {
            break;
        }
        last += 1;
        if let Some(call) = next
            .and_then(|m| m.get("toolCallId"))
            .and_then(Value::as_str)
        {
            pending.remove(call);
        }
    }
    if !pending.is_empty() {
        return Err(ArchiveError::UnsavedMessage);
    }
    let id = uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase();
    header.insert("id".into(), Value::String(id.clone()));
    header.insert(
        "parentSession".into(),
        Value::String(session.file.to_string_lossy().into_owned()),
    );
    header.insert(
        "timestamp".into(),
        Value::String(chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()),
    );
    let file = directory.join(format!("{id}.jsonl"));
    let mut data = String::new();
    for record in std::iter::once(&header).chain(branch[..=last].iter()) {
        data.push_str(&canonical_json(&Value::Object(record.clone())));
        data.push('\n');
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    let mut out = options
        .open(&file)
        .map_err(|err| ArchiveError::Corrupt(err.to_string()))?;
    std::io::Write::write_all(&mut out, data.as_bytes())
        .map_err(|err| ArchiveError::Corrupt(err.to_string()))?;
    crate::fsutil::restrict_file(&file);
    history::load(directory)
        .map_err(|err| ArchiveError::Corrupt(err.to_string()))?
        .into_iter()
        .find(|s| crate::policy::same_path(&s.file, &file))
        .ok_or(ArchiveError::UnsavedMessage)
}

pub fn message_text(message: &Map<String, Value>) -> String {
    crate::messages::content_text(message.get("content"), "")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn entry(id: &str, parent: Option<&str>, role: &str, text: &str) -> Value {
        json!({"type": "message", "id": id, "parentId": parent, "message": {"role": role, "content": text}})
    }

    fn write(file: &Path, values: &[Value]) {
        let text: String = values.iter().map(|v| format!("{v}\n")).collect();
        std::fs::write(file, text).unwrap();
    }

    fn texts(folder: &TranscriptFolder) -> Vec<String> {
        folder.items().iter().map(|i| i.searchable_text()).collect()
    }

    #[test]
    fn archive_uses_only_the_selected_branch_and_fork_preserves_the_original() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let file = root.join("branches.jsonl");
        write(
            &file,
            &[
                json!({"type": "session", "version": 3, "id": "s", "cwd": root.to_string_lossy()}),
                entry("u1", None, "user", "Question"),
                entry("a1", Some("u1"), "assistant", "Abandoned answer"),
                entry("a2", Some("u1"), "assistant", "Chosen answer"),
                entry("u2", Some("a2"), "user", "Later question"),
            ],
        );
        let original = std::fs::read(&file).unwrap();
        let saved = history::load(root).unwrap().remove(0);
        let preview = preview(&saved, root).unwrap();
        assert_eq!(
            texts(&preview.folder),
            vec!["Question", "Chosen answer", "Later question"]
        );
        let branch = fork(&saved, &preview.folder.items()[1], 0, root).unwrap();
        assert_ne!(branch.file, file);
        assert_eq!(std::fs::read(&file).unwrap(), original);
        assert_eq!(
            texts(&super::preview(&branch, root).unwrap().folder),
            vec!["Question", "Chosen answer"]
        );
        let records = records(&branch, root).unwrap();
        assert_eq!(
            records[0].get("parentSession").and_then(Value::as_str),
            Some(file.to_string_lossy().as_ref())
        );
    }

    #[test]
    fn context_edits_keep_visible_history_and_fork_ancestors() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        write(
            &root.join("edited.jsonl"),
            &[
                json!({"type": "session", "version": 3, "id": "session", "cwd": root.to_string_lossy()}),
                entry("u1", None, "user", "Original context"),
                json!({"type": "context_edit", "id": "e1", "parentId": "u1", "targetId": "u1", "replacement": {"content": "Condensed context"}}),
                entry("a1", Some("e1"), "assistant", "Continued answer"),
            ],
        );
        let saved = history::load(root).unwrap().remove(0);
        let preview = preview(&saved, root).unwrap();
        assert_eq!(
            texts(&preview.folder),
            vec!["Original context", "Continued answer"]
        );
        let branch = fork(&saved, &preview.folder.items()[1], 0, root).unwrap();
        let entries = active_branch(&records(&branch, root).unwrap());
        assert_eq!(
            entries
                .iter()
                .filter_map(|e| e.get("type")?.as_str())
                .collect::<Vec<_>>(),
            vec!["message", "context_edit", "message"]
        );
    }

    #[test]
    fn branch_chooses_the_correct_repeated_message() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        write(
            &root.join("repeated.jsonl"),
            &[
                json!({"type": "session", "version": 3, "id": "session", "cwd": root.to_string_lossy()}),
                entry("u1", None, "user", "Again"),
                entry("a1", Some("u1"), "assistant", "First"),
                entry("u2", Some("a1"), "user", "Again"),
            ],
        );
        let saved = history::load(root).unwrap().remove(0);
        let item = TranscriptItem::User {
            id: "local".into(),
            text: "Again".into(),
        };
        let branch = fork(&saved, &item, 1, root).unwrap();
        assert_eq!(
            super::preview(&branch, root).unwrap().folder.items().len(),
            1
        );
    }

    #[test]
    fn fork_carries_recorded_tool_results_without_replaying_calls() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        write(
            &root.join("tools.jsonl"),
            &[
                json!({"type": "session", "version": 3, "id": "tools", "cwd": root.to_string_lossy()}),
                entry("u", None, "user", "Read notes"),
                json!({"type": "message", "id": "a", "parentId": "u", "message": {"role": "assistant", "content": [
                    {"type": "text", "text": "Reading notes"},
                    {"type": "toolCall", "id": "call", "name": "read", "arguments": {"path": "notes.md"}}
                ]}}),
                json!({"type": "message", "id": "t", "parentId": "a", "message": {"role": "toolResult", "toolCallId": "call", "content": "Notes"}}),
                entry("later", Some("t"), "assistant", "Later answer"),
            ],
        );
        let saved = history::load(root).unwrap().remove(0);
        let preview = preview(&saved, root).unwrap();
        assert!(preview.folder.items().iter().any(|i| matches!(i, TranscriptItem::Tool { name, output, .. } if name == "read" && output == "Notes")));
        let item = TranscriptItem::Assistant {
            id: "a".into(),
            text: "Reading notes".into(),
            is_streaming: false,
        };
        let branch = fork(&saved, &item, 0, root).unwrap();
        let entries = records(&branch, root).unwrap();
        assert_eq!(
            entries.last().unwrap().get("id").and_then(Value::as_str),
            Some("t")
        );
        assert!(
            !entries
                .iter()
                .any(|e| e.get("id").and_then(Value::as_str) == Some("later"))
        );
    }

    #[cfg(unix)]
    #[test]
    fn archive_rejects_a_replaced_file_and_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        let file = root.join("original.jsonl");
        let records_json = [
            json!({"type": "session", "id": "a", "cwd": root.to_string_lossy()}),
            entry("u", None, "user", "Hello"),
        ];
        write(&file, &records_json);
        let saved = history::load(root).unwrap().remove(0);
        let other = root.join("other.jsonl");
        write(&other, &records_json);
        std::fs::remove_file(&file).unwrap();
        std::os::unix::fs::symlink(&other, &file).unwrap();
        assert!(matches!(
            preview(&saved, root),
            Err(ArchiveError::Unavailable)
        ));
    }
}
