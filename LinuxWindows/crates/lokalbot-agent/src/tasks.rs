//! Task metadata (`AgentTaskStore.swift`): titles, drafts, attachments,
//! queued follow-ups, pins and archive state, kept apart from pi's
//! append-only conversation. Archiving never deletes history, and browsing a
//! task never needs a running process.
//!
//! `tasks.json` sits next to pi's session files in `<library>/agent/sessions`
//! and uses the macOS encoding: uppercase UUID strings, `file://` URLs and
//! dates as seconds since 2001-01-01.

use std::path::{Path, PathBuf};

use anyhow::{Context as _, Result, bail};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use uuid::Uuid;

use crate::fileurl::{from_file_url, to_file_url};
use crate::transcript::{ToolStatus, TranscriptItem};

pub const MAX_METADATA_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AttachmentKind {
    File,
    Meeting,
    Moment,
}

/// A reference to source material. The text is re-read with current
/// permissions when a message is sent; only references are stored.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Attachment {
    pub id: String,
    pub kind: AttachmentKind,
    pub title: String,
    pub reference: String,
}

impl Attachment {
    pub fn file(path: &Path) -> Self {
        let path = path.to_string_lossy().into_owned();
        Self {
            id: format!("file:{path}"),
            kind: AttachmentKind::File,
            title: Path::new(&path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| path.clone()),
            reference: path,
        }
    }

    pub fn meeting(id: Uuid, title: &str) -> Self {
        let reference = id.hyphenated().to_string().to_uppercase();
        Self {
            id: format!("meeting:{reference}"),
            kind: AttachmentKind::Meeting,
            title: title.to_string(),
            reference,
        }
    }

    pub fn moment(snapshot_id: i64, title: &str) -> Self {
        Self {
            id: format!("moment:{snapshot_id}"),
            kind: AttachmentKind::Moment,
            title: title.to_string(),
            reference: snapshot_id.to_string(),
        }
    }
}

/// A follow-up kept in the host queue until delivery.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueuedPrompt {
    #[serde(with = "swift_uuid")]
    pub id: Uuid,
    pub text: String,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
}

impl QueuedPrompt {
    pub fn new(text: impl Into<String>, attachments: Vec<Attachment>) -> Self {
        Self {
            id: Uuid::new_v4(),
            text: text.into(),
            attachments,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskRecord {
    #[serde(with = "swift_uuid")]
    pub id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(with = "directory_url")]
    pub workspace: PathBuf,
    #[serde(
        default,
        with = "optional_file_url",
        skip_serializing_if = "Option::is_none"
    )]
    pub session_file: Option<PathBuf>,
    #[serde(default)]
    pub draft: String,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
    #[serde(default)]
    pub queued_prompts: Vec<QueuedPrompt>,
    #[serde(default)]
    pub sources: Vec<Attachment>,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub is_archived: bool,
    #[serde(default = "distant_past", with = "lokalbot_core::time::swift_date")]
    pub modified_at: DateTime<Utc>,
}

impl TaskRecord {
    pub fn new(workspace: PathBuf) -> Self {
        Self {
            id: Uuid::new_v4(),
            title: None,
            workspace,
            session_file: None,
            draft: String::new(),
            attachments: Vec::new(),
            queued_prompts: Vec::new(),
            sources: Vec::new(),
            is_pinned: false,
            is_archived: false,
            modified_at: Utc::now(),
        }
    }
}

fn distant_past() -> DateTime<Utc> {
    DateTime::<Utc>::MIN_UTC
}

/// `tasks.json` in the sessions folder.
#[derive(Clone, Debug)]
pub struct TaskStore {
    pub directory: PathBuf,
    pub maximum_bytes: usize,
}

impl TaskStore {
    pub fn new(directory: PathBuf) -> Self {
        Self {
            directory,
            maximum_bytes: MAX_METADATA_BYTES,
        }
    }

    pub fn file(&self) -> PathBuf {
        self.directory.join("tasks.json")
    }

    /// Records with duplicate ids dropped. A symlinked or oversized file is
    /// an error, so the caller keeps it untouched instead of overwriting it.
    pub fn load(&self) -> Result<Vec<TaskRecord>> {
        let file = self.file();
        let metadata = match std::fs::symlink_metadata(&file) {
            Ok(metadata) => metadata,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(err) => return Err(err).context("reading task metadata"),
        };
        if metadata.file_type().is_symlink() || metadata.len() as usize > self.maximum_bytes {
            bail!("The task metadata file is unreadable.");
        }
        let records: Vec<TaskRecord> =
            serde_json::from_slice(&std::fs::read(&file)?).context("decoding task metadata")?;
        let mut seen = std::collections::HashSet::new();
        Ok(records
            .into_iter()
            .filter(|record| seen.insert(record.id))
            .collect())
    }

    pub fn save(&self, records: &[TaskRecord]) -> Result<()> {
        let bytes = serde_json::to_vec(records)?;
        if bytes.len() > self.maximum_bytes {
            bail!(
                "Task metadata is too large to save. Shorten drafts or queued messages and try again. Previously saved tasks are preserved; current edits remain open."
            );
        }
        crate::fsutil::create_private_dir(&self.directory)?;
        let file = self.file();
        lokalbot_core::library::write_atomic(&file, &bytes)
            .with_context(|| format!("writing {}", file.display()))?;
        crate::fsutil::restrict_file(&file);
        Ok(())
    }
}

// ------------------------------------------------------------ presentation

/// Consecutive tool items collapse into one activity group; approvals live
/// in the approval dock, not the transcript (`AgentTranscriptGroup`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TranscriptGroup {
    pub id: String,
    pub items: Vec<TranscriptItem>,
}

impl TranscriptGroup {
    pub fn make(items: &[TranscriptItem]) -> Vec<TranscriptGroup> {
        let mut groups = Vec::new();
        let mut tools: Vec<TranscriptItem> = Vec::new();
        let flush = |tools: &mut Vec<TranscriptItem>, groups: &mut Vec<TranscriptGroup>| {
            if let Some(first) = tools.first() {
                groups.push(TranscriptGroup {
                    id: first.id().to_string(),
                    items: std::mem::take(tools),
                });
            }
        };
        for item in items {
            match item {
                TranscriptItem::Approval(_) => {}
                TranscriptItem::Tool { .. } => tools.push(item.clone()),
                _ => {
                    flush(&mut tools, &mut groups);
                    groups.push(TranscriptGroup {
                        id: item.id().to_string(),
                        items: vec![item.clone()],
                    });
                }
            }
        }
        flush(&mut tools, &mut groups);
        groups
    }

    pub fn is_activity(&self) -> bool {
        self.items
            .iter()
            .all(|item| matches!(item, TranscriptItem::Tool { .. }))
    }

    pub fn is_running(&self) -> bool {
        self.items.iter().any(|item| {
            matches!(
                item,
                TranscriptItem::Tool {
                    status: ToolStatus::Running,
                    ..
                }
            )
        })
    }

    pub fn has_failure(&self) -> bool {
        self.items.iter().any(|item| {
            matches!(
                item,
                TranscriptItem::Tool {
                    status: ToolStatus::Failed,
                    ..
                }
            )
        })
    }

    /// "Read 3 files", "2 file changes", "4 activities".
    pub fn summary(&self) -> String {
        let names: Vec<String> = self
            .items
            .iter()
            .filter_map(|item| match item {
                TranscriptItem::Tool { name, .. } => Some(name.to_lowercase()),
                _ => None,
            })
            .collect();
        let count = names.len();
        if names.iter().all(|n| n == "read") {
            return format!("Read {count} {}", if count == 1 { "file" } else { "files" });
        }
        if names.iter().all(|n| n == "write" || n == "edit") {
            return format!(
                "{count} file {}",
                if count == 1 { "change" } else { "changes" }
            );
        }
        format!(
            "{count} {}",
            if count == 1 { "activity" } else { "activities" }
        )
    }
}

/// One line of an activity group: "Read notes.md", "Run command".
pub fn activity_summary(name: &str, args_json: &str) -> String {
    let object: serde_json::Value = serde_json::from_str(args_json).unwrap_or_default();
    if let Some(path) = object.get("path").and_then(|v| v.as_str()) {
        let verb = match name {
            "read" => "Read",
            "write" => "Write",
            "edit" => "Edit",
            other => other,
        };
        return format!("{verb} {}", file_name(path));
    }
    if let Some(command) = object.get("command").and_then(|v| v.as_str())
        && command.contains("lokalbot-cli")
    {
        return if command.contains("search") {
            "Search meeting library".into()
        } else {
            "Read meeting evidence".into()
        };
    }
    match name {
        "bash" | "powershell" => "Run command".into(),
        other => other.to_string(),
    }
}

fn file_name(path: &str) -> String {
    path.rsplit(['/', '\\'])
        .find(|part| !part.is_empty())
        .unwrap_or(path)
        .to_string()
}

/// What the results panel shows for a tool result or source (`AgentResultPreview`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResultPreview {
    pub id: String,
    pub title: String,
    pub detail: String,
    pub text: String,
    pub original: Option<String>,
    pub proposed: Option<String>,
    pub file_path: Option<String>,
}

impl ResultPreview {
    pub fn tool(item: &TranscriptItem) -> Option<ResultPreview> {
        let TranscriptItem::Tool {
            id,
            name,
            args_json,
            output,
            status,
        } = item
        else {
            return None;
        };
        let object: serde_json::Value = serde_json::from_str(args_json).unwrap_or_default();
        let text_field = |key: &str| object.get(key).and_then(|v| v.as_str()).map(str::to_string);
        let path = text_field("path").or_else(|| text_field("file_path"));
        let state = match status {
            ToolStatus::Succeeded => "Completed",
            ToolStatus::Failed => "Failed",
            ToolStatus::Running => "In progress",
        };
        // pi's edit tool sends `edits: [{oldText, newText}]`; older calls a single pair.
        let first_edit = object
            .get("edits")
            .and_then(|e| e.as_array())
            .and_then(|e| e.first());
        let edit_field = |key: &str| {
            first_edit
                .and_then(|e| e.get(key))
                .and_then(|v| v.as_str())
                .map(str::to_string)
                .or_else(|| text_field(key))
        };
        Some(ResultPreview {
            id: id.clone(),
            title: path
                .as_deref()
                .map(file_name)
                .unwrap_or_else(|| name.clone()),
            detail: format!("{state} · {}", path.as_deref().unwrap_or(name)),
            text: if name == "write" {
                text_field("content").unwrap_or_else(|| output.clone())
            } else {
                output.clone()
            },
            original: edit_field("oldText"),
            proposed: edit_field("newText"),
            file_path: path,
        })
    }
}

// --------------------------------------------------------------- encoding

/// Swift encodes `UUID` as an uppercase hyphenated string.
mod swift_uuid {
    use super::*;

    pub fn serialize<S: Serializer>(id: &Uuid, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&id.hyphenated().to_string().to_uppercase())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Uuid, D::Error> {
        let text = String::deserialize(deserializer)?;
        Uuid::parse_str(&text).map_err(serde::de::Error::custom)
    }
}

mod directory_url {
    use super::*;

    pub fn serialize<S: Serializer>(path: &Path, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&to_file_url(path, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<PathBuf, D::Error> {
        let text = String::deserialize(deserializer)?;
        from_file_url(&text).ok_or_else(|| serde::de::Error::custom("invalid folder URL"))
    }
}

mod optional_file_url {
    use super::*;

    pub fn serialize<S: Serializer>(
        path: &Option<PathBuf>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        match path {
            Some(path) => serializer.serialize_str(&to_file_url(path, false)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<PathBuf>, D::Error> {
        let text = Option::<String>::deserialize(deserializer)?;
        Ok(text.and_then(|t| from_file_url(&t)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metadata_stores_references_and_queued_drafts_without_source_text() {
        let dir = tempfile::tempdir().unwrap();
        let store = TaskStore::new(dir.path().join("sessions"));
        let mut record = TaskRecord::new(dir.path().join("work"));
        record.draft = "draft".into();
        record.attachments = vec![Attachment::file(&dir.path().join("notes.md"))];
        record.queued_prompts = vec![QueuedPrompt::new("next", Vec::new())];
        store.save(&[record.clone(), record.clone()]).unwrap();
        let loaded = store.load().unwrap();
        assert_eq!(loaded.len(), 1, "duplicate ids are dropped");
        assert_eq!(loaded[0].draft, "draft");
        assert_eq!(loaded[0].attachments, record.attachments);
        assert_eq!(loaded[0].queued_prompts[0].text, "next");
        let raw = std::fs::read_to_string(store.file()).unwrap();
        assert!(raw.contains("\"workspace\":\"file://"));
        assert!(raw.contains(&record.id.to_string().to_uppercase()));
        assert!(!raw.contains("notes text"));
    }

    #[cfg(unix)]
    #[test]
    fn reads_metadata_written_by_the_mac_app() {
        let json = r#"[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","workspace":"file:///Users/me/Work/","sessionFile":"file:///Users/me/LokalBot/agent/sessions/x.jsonl","draft":"hi","attachments":[{"id":"meeting:ABC","kind":"meeting","title":"Standup","reference":"ABC"}],"queuedPrompts":[],"sources":[],"isPinned":true,"isArchived":false,"modifiedAt":750000000}]"#;
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("tasks.json"), json).unwrap();
        let records = TaskStore::new(dir.path().to_path_buf()).load().unwrap();
        assert_eq!(records[0].workspace, PathBuf::from("/Users/me/Work"));
        assert_eq!(
            records[0].session_file.as_deref(),
            Some(Path::new("/Users/me/LokalBot/agent/sessions/x.jsonl"))
        );
        assert!(records[0].is_pinned);
        assert_eq!(records[0].attachments[0].kind, AttachmentKind::Meeting);
        assert_eq!(
            records[0].modified_at.timestamp(),
            750_000_000 + 978_307_200
        );
    }

    #[test]
    fn oversized_metadata_is_refused_and_existing_file_kept() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = TaskStore::new(dir.path().to_path_buf());
        store.save(&[TaskRecord::new(dir.path().into())]).unwrap();
        store.maximum_bytes = 64;
        let mut big = TaskRecord::new(dir.path().into());
        big.draft = "x".repeat(1000);
        assert!(
            store
                .save(&[big])
                .unwrap_err()
                .to_string()
                .contains("too large")
        );
        store.maximum_bytes = MAX_METADATA_BYTES;
        assert_eq!(store.load().unwrap().len(), 1);
    }

    #[test]
    fn grouping_preserves_order_and_keeps_approvals_out() {
        let tool = |id: &str, name: &str| TranscriptItem::Tool {
            id: id.into(),
            name: name.into(),
            args_json: r#"{"path":"/w/a.md"}"#.into(),
            output: String::new(),
            status: ToolStatus::Succeeded,
        };
        let items = vec![
            TranscriptItem::User {
                id: "u".into(),
                text: "go".into(),
            },
            tool("t1", "read"),
            tool("t2", "read"),
            TranscriptItem::Approval(crate::transcript::ApprovalRequest {
                id: "a".into(),
                tool: "bash".into(),
                workspace: None,
                path: None,
                command: Some("ls".into()),
                content: None,
                edits: Vec::new(),
                summary: None,
                is_truncated: false,
                arguments: None,
            }),
            TranscriptItem::Assistant {
                id: "r".into(),
                text: "done".into(),
                is_streaming: false,
            },
            tool("t3", "write"),
        ];
        let groups = TranscriptGroup::make(&items);
        assert_eq!(
            groups.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
            vec!["u", "t1", "r", "t3"]
        );
        assert!(groups[1].is_activity());
        assert_eq!(groups[1].summary(), "Read 2 files");
        assert_eq!(groups[3].summary(), "1 file change");
        assert_eq!(
            activity_summary("read", r#"{"path":"/w/notes.md"}"#),
            "Read notes.md"
        );
        assert_eq!(
            activity_summary("bash", r#"{"command":"lokalbot-cli search \"x\""}"#),
            "Search meeting library"
        );
        assert_eq!(
            activity_summary("bash", r#"{"command":"ls"}"#),
            "Run command"
        );
    }

    #[test]
    fn result_preview_for_writes_and_edits() {
        let write = TranscriptItem::Tool {
            id: "w".into(),
            name: "write".into(),
            args_json: r#"{"path":"/w/hello.txt","content":"hi"}"#.into(),
            output: "ok".into(),
            status: ToolStatus::Succeeded,
        };
        let preview = ResultPreview::tool(&write).unwrap();
        assert_eq!(preview.title, "hello.txt");
        assert_eq!(preview.text, "hi");
        assert_eq!(preview.detail, "Completed · /w/hello.txt");
        let edit = TranscriptItem::Tool {
            id: "e".into(),
            name: "edit".into(),
            args_json: r#"{"path":"/w/a.md","edits":[{"oldText":"a","newText":"b"}]}"#.into(),
            output: String::new(),
            status: ToolStatus::Running,
        };
        let preview = ResultPreview::tool(&edit).unwrap();
        assert_eq!(preview.original.as_deref(), Some("a"));
        assert_eq!(preview.proposed.as_deref(), Some("b"));
    }
}
