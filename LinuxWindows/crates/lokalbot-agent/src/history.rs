//! Saved pi sessions (`AgentSessionHistory.swift`): list metadata streamed
//! from each JSONL file in the sessions folder, without keeping prompts or
//! responses in memory. Conversation contents load only when opened.

use std::io::Read as _;
use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use chrono::{DateTime, TimeZone as _, Utc};
use serde_json::Value;

const READ_CHUNK: usize = 64 * 1024;
const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedSession {
    /// The file path, which identifies a saved session.
    pub id: String,
    pub session_id: String,
    pub file: PathBuf,
    pub workspace: PathBuf,
    pub title: String,
    pub created_at: DateTime<Utc>,
    pub modified_at: DateTime<Utc>,
    pub message_count: usize,
    pub preview: String,
}

impl SavedSession {
    pub fn searchable_text(&self) -> String {
        format!(
            "{} {} {} {}",
            self.title,
            self.workspace
                .file_name()
                .map(|n| n.to_string_lossy())
                .unwrap_or_default(),
            self.workspace.display(),
            self.preview
        )
    }
}

/// Every readable saved session, most recently active first.
pub fn load(directory: &Path) -> Result<Vec<SavedSession>> {
    let metadata = match std::fs::metadata(directory) {
        Ok(metadata) => metadata,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(err) => return Err(err.into()),
    };
    if !metadata.is_dir() {
        bail!("{} is not a folder", directory.display());
    }
    let mut sessions: Vec<SavedSession> = std::fs::read_dir(directory)?
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let name = path.file_name()?.to_string_lossy().into_owned();
            if name.starts_with('.') || !name.to_lowercase().ends_with(".jsonl") {
                return None;
            }
            let metadata = std::fs::symlink_metadata(&path).ok()?;
            if !metadata.file_type().is_file() {
                return None; // Symlinks and folders are never listed.
            }
            parse(&path, &metadata)
        })
        .collect();
    sessions.sort_by(|a, b| {
        b.modified_at
            .cmp(&a.modified_at)
            .then_with(|| a.title.cmp(&b.title))
    });
    Ok(sessions)
}

/// One session file of `directory` (for a task that knows its file).
pub fn load_file(file: &Path, directory: &Path) -> Option<SavedSession> {
    let expected = dunce::canonicalize(directory).ok()?;
    let parent = dunce::canonicalize(file.parent()?).ok()?;
    if !crate::policy::same_path(&expected, &parent) {
        return None;
    }
    let metadata = std::fs::symlink_metadata(file).ok()?;
    if !metadata.file_type().is_file() {
        return None;
    }
    parse(file, &metadata)
}

/// Re-reads the file just before opening, so a stale list entry, a replaced
/// file or a symlink cannot redirect an exact-session launch.
pub fn validated(session: &SavedSession, directory: &Path) -> Option<SavedSession> {
    let expected = dunce::canonicalize(directory).ok()?;
    let parent = dunce::canonicalize(session.file.parent()?).ok()?;
    if !crate::policy::same_path(&expected, &parent)
        || !session
            .file
            .to_string_lossy()
            .to_lowercase()
            .ends_with(".jsonl")
    {
        return None;
    }
    let metadata = std::fs::symlink_metadata(&session.file).ok()?;
    if !metadata.file_type().is_file() {
        return None;
    }
    let refreshed = parse(&session.file, &metadata)?;
    (refreshed.session_id == session.session_id
        && crate::policy::same_path(&refreshed.workspace, &session.workspace))
    .then_some(refreshed)
}

fn parse(file: &Path, metadata: &std::fs::Metadata) -> Option<SavedSession> {
    let mut handle = std::fs::File::open(file).ok()?;
    let modified: DateTime<Utc> = metadata
        .modified()
        .ok()
        .map(Into::into)
        .unwrap_or(DateTime::<Utc>::MIN_UTC);
    let created: DateTime<Utc> = metadata.created().ok().map(Into::into).unwrap_or(modified);
    let mut parser = MetadataParser::new(created);
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; READ_CHUNK];
    let mut dropping_oversized = false;
    loop {
        let read = match handle.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => read,
            Err(_) => return None,
        };
        let mut start = 0;
        if dropping_oversized {
            match chunk[..read].iter().position(|b| *b == b'\n') {
                Some(newline) => {
                    start = newline + 1;
                    dropping_oversized = false;
                }
                None => continue,
            }
        }
        buffer.extend_from_slice(&chunk[start..read]);
        let mut consumed = 0;
        while let Some(offset) = buffer[consumed..].iter().position(|b| *b == b'\n') {
            let line = &buffer[consumed..consumed + offset];
            if line.len() <= MAX_LINE_BYTES {
                parser.consume(line);
            }
            consumed += offset + 1;
        }
        buffer.drain(..consumed);
        if buffer.len() > MAX_LINE_BYTES {
            buffer.clear();
            dropping_oversized = true;
        }
    }
    if !dropping_oversized && !buffer.is_empty() && buffer.len() <= MAX_LINE_BYTES {
        parser.consume(&buffer);
    }
    parser.session(file)
}

struct MetadataParser {
    fallback_created: DateTime<Utc>,
    session_id: Option<String>,
    workspace: Option<PathBuf>,
    created_at: Option<DateTime<Utc>>,
    modified_at: Option<DateTime<Utc>>,
    explicit_name: Option<String>,
    first_user_message: Option<String>,
    message_count: usize,
    preview: String,
}

impl MetadataParser {
    fn new(created: DateTime<Utc>) -> Self {
        Self {
            fallback_created: created,
            session_id: None,
            workspace: None,
            created_at: None,
            modified_at: None,
            explicit_name: None,
            first_user_message: None,
            message_count: 0,
            preview: String::new(),
        }
    }

    fn consume(&mut self, line: &[u8]) {
        let Ok(value) = serde_json::from_slice::<Value>(line) else {
            return;
        };
        let Some(kind) = value.get("type").and_then(Value::as_str) else {
            return;
        };
        if self.session_id.is_none() {
            let id = value
                .get("id")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty());
            let cwd = value
                .get("cwd")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty());
            if kind != "session" {
                return;
            }
            let (Some(id), Some(cwd)) = (id, cwd) else {
                return;
            };
            self.session_id = Some(id.to_string());
            self.workspace = Some(PathBuf::from(cwd));
            self.created_at = Some(date(value.get("timestamp")).unwrap_or(self.fallback_created));
            return;
        }
        if kind == "session_info" {
            self.explicit_name = value
                .get("name")
                .and_then(Value::as_str)
                .map(|n| n.trim().to_string())
                .filter(|n| !n.is_empty());
            return;
        }
        let Some(message) = value.get("message").filter(|_| kind == "message") else {
            return;
        };
        let role = message
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if role != "user" && role != "assistant" {
            return;
        }
        self.message_count += 1;
        let text = crate::messages::content_text(message.get("content"), "\n");
        let trimmed = text.trim();
        if !trimmed.is_empty() {
            self.preview = trimmed.chars().take(1200).collect();
        }
        if let Some(activity) =
            date(message.get("timestamp")).or_else(|| date(value.get("timestamp")))
            && self.modified_at.is_none_or(|current| activity > current)
        {
            self.modified_at = Some(activity);
        }
        if role == "user" && self.first_user_message.is_none() && !trimmed.is_empty() {
            self.first_user_message =
                Some(crate::context::display_prompt(trimmed).trim().to_string());
        }
    }

    fn session(self, file: &Path) -> Option<SavedSession> {
        let (Some(session_id), Some(workspace)) = (self.session_id, self.workspace) else {
            return None;
        };
        if self.message_count == 0 {
            return None;
        }
        let title_source = self
            .explicit_name
            .or(self.first_user_message)
            .unwrap_or_else(|| "Untitled session".into());
        let created_at = self.created_at.unwrap_or(self.fallback_created);
        Some(SavedSession {
            id: file.to_string_lossy().into_owned(),
            session_id,
            file: file.to_path_buf(),
            workspace,
            title: display_title(&title_source),
            created_at,
            modified_at: self.modified_at.unwrap_or(created_at),
            message_count: self.message_count,
            preview: self.preview,
        })
    }
}

/// Milliseconds since 1970, or an ISO 8601 string.
fn date(value: Option<&Value>) -> Option<DateTime<Utc>> {
    match value? {
        Value::Number(number) => {
            let millis = number.as_f64()?;
            Utc.timestamp_millis_opt(millis as i64).single()
        }
        Value::String(text) => DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|d| d.with_timezone(&Utc)),
        _ => None,
    }
}

/// The first line, whitespace collapsed, cut at a word near 80 characters.
pub fn display_title(text: &str) -> String {
    let first_line = text.lines().next().unwrap_or(text);
    let collapsed = first_line.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= 80 {
        return collapsed;
    }
    let prefix: String = collapsed.chars().take(79).collect();
    let cut = prefix.rfind(' ').map(|at| &prefix[..at]).unwrap_or(&prefix);
    format!("{cut}…")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn write(file: &Path, records: &[Value]) {
        let text: String = records.iter().map(|r| format!("{r}\n")).collect();
        std::fs::write(file, text).unwrap();
    }

    fn session(id: &str, timestamp: &str, cwd: &Path) -> Value {
        json!({"type": "session", "id": id, "timestamp": timestamp, "cwd": cwd.to_string_lossy()})
    }

    fn message(role: &str, content: Value, timestamp: i64) -> Value {
        json!({"type": "message", "message": {"role": role, "content": content, "timestamp": timestamp}})
    }

    #[test]
    fn loads_metadata_and_sorts_by_latest_conversation_activity() {
        let dir = tempfile::tempdir().unwrap();
        let older_ws = dir.path().join("Older Project");
        let newer_ws = dir.path().join("Newer Project");
        write(
            &dir.path().join("older.jsonl"),
            &[
                session("older", "2026-07-10T09:55:17.265Z", &older_ws),
                message(
                    "user",
                    json!([{"type": "text", "text": "Review the launch checklist"}]),
                    1_783_677_336_124,
                ),
                message("assistant", json!("Ready."), 1_783_677_337_124),
                json!({"type": "session_info", "name": "Launch review"}),
            ],
        );
        write(
            &dir.path().join("newer.jsonl"),
            &[
                session("newer", "2026-08-05T20:52:04.304Z", &newer_ws),
                message(
                    "user",
                    json!("Summarize the latest plan"),
                    1_785_963_156_269,
                ),
            ],
        );
        let loaded = load(dir.path()).unwrap();
        assert_eq!(
            loaded
                .iter()
                .map(|s| s.session_id.as_str())
                .collect::<Vec<_>>(),
            vec!["newer", "older"]
        );
        assert_eq!(loaded[0].title, "Summarize the latest plan");
        assert_eq!(loaded[0].message_count, 1);
        assert_eq!(loaded[0].workspace, newer_ws);
        assert_eq!(loaded[0].created_at.timestamp_millis(), 1_785_963_124_304);
        assert_eq!(loaded[1].title, "Launch review");
        assert_eq!(loaded[1].message_count, 2);
        assert!(loaded[1].searchable_text().contains("Older Project"));
    }

    #[test]
    fn ignores_malformed_empty_and_symlinked_files() {
        let dir = tempfile::tempdir().unwrap();
        let valid = dir.path().join("valid.jsonl");
        write(
            &valid,
            &[
                session("valid", "2026-08-05T20:52:04Z", dir.path()),
                message("user", json!("Keep me"), 1_785_963_156_269),
            ],
        );
        std::fs::write(dir.path().join("malformed.jsonl"), "not json\n").unwrap();
        write(
            &dir.path().join("empty.jsonl"),
            &[session("empty", "2026-08-05T20:52:04Z", dir.path())],
        );
        #[cfg(unix)]
        std::os::unix::fs::symlink(&valid, dir.path().join("linked.jsonl")).unwrap();
        let loaded = load(dir.path()).unwrap();
        assert_eq!(
            loaded
                .iter()
                .map(|s| s.session_id.as_str())
                .collect::<Vec<_>>(),
            vec!["valid"]
        );
    }

    #[test]
    fn validation_rejects_a_replaced_session() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("saved.jsonl");
        write(
            &file,
            &[
                session("original", "2026-08-05T20:52:04Z", dir.path()),
                message("user", json!("Original"), 1_785_963_156_269),
            ],
        );
        let original = load(dir.path()).unwrap().remove(0);
        assert!(validated(&original, dir.path()).is_some());
        write(
            &file,
            &[
                session("replacement", "2026-08-05T20:52:04Z", dir.path()),
                message("user", json!("Replacement"), 1_785_963_156_270),
            ],
        );
        assert!(validated(&original, dir.path()).is_none());
    }

    #[test]
    fn titles_are_cut_at_a_word() {
        assert_eq!(display_title("  short\nsecond line"), "short");
        let long = "word ".repeat(30);
        let title = display_title(&long);
        assert!(title.ends_with('…'));
        assert!(title.chars().count() <= 80);
    }
}
