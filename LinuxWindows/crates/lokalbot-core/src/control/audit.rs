//! Settings changed from the terminal (`AgentSettingsChanges.swift`): an
//! append-only log in `diagnostics/settings-changes.jsonl` and the recent list
//! Settings shows with Undo. Values are kept as stored, so Undo restores them
//! exactly. API keys are named but never stored.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use super::change::PlanItem;
use super::protocol::AppSecret;
use super::setup::Grant;
use super::{encoded, json_eq, registry};
use crate::paths::LibraryPaths;
use crate::settings::Settings;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub caller: String,
    #[serde(with = "crate::ids::uuid_upper_serde")]
    pub id: Uuid,
    pub key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous: Option<Value>,
    #[serde(with = "super::iso8601")]
    pub time: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<Value>,
}

pub const RECENT_LIMIT: usize = 20;
/// The log keeps the newest entries once it grows past this size.
pub const MAXIMUM_LOG_BYTES: u64 = 1_048_576;
pub const KEPT_ENTRIES: usize = 1_000;

/// Undoing a retention change could delete without the review a shorter policy
/// needs, so those are changed back in Settings instead.
pub const KEYS_WITHOUT_UNDO: [&str; 2] = ["retentionDays", "keepOCRTextForever"];

pub struct AgentSettingsChanges {
    pub recent: Vec<Entry>,
    log: PathBuf,
}

impl AgentSettingsChanges {
    pub fn new(paths: &LibraryPaths) -> Self {
        let log = paths
            .root()
            .join("diagnostics")
            .join("settings-changes.jsonl");
        let mut entries = load(&log);
        if std::fs::metadata(&log).is_ok_and(|m| m.len() > MAXIMUM_LOG_BYTES) {
            if entries.len() > KEPT_ENTRIES {
                entries.drain(..entries.len() - KEPT_ENTRIES);
            }
            let _ = std::fs::remove_file(&log);
            append(&log, &entries);
        }
        let recent = entries.iter().rev().take(RECENT_LIMIT).cloned().collect();
        Self { recent, log }
    }

    pub fn record(&mut self, items: &[PlanItem], caller: &str, time: DateTime<Utc>) {
        let entries: Vec<Entry> = items
            .iter()
            .map(|item| Entry {
                caller: caller.to_string(),
                id: Uuid::new_v4(),
                key: item.spec.key.to_string(),
                previous: item.previous.clone(),
                time,
                value: item.stored.clone(),
            })
            .collect();
        self.add(entries);
    }

    /// An API key, which the log names but never stores.
    pub fn record_secret(
        &mut self,
        secret: AppSecret,
        is_set: bool,
        caller: &str,
        time: DateTime<Utc>,
    ) {
        self.record_event(
            &format!("secret.{}", secret.raw_value()),
            json!(if is_set { "set" } else { "cleared" }),
            caller,
            time,
        );
    }

    /// Access the person allowed from an agent's setup request.
    pub fn record_setup(&mut self, grants: &[Grant], caller: &str, time: DateTime<Utc>) {
        let names: Vec<&str> = grants.iter().map(|g| g.raw_value()).collect();
        self.record_event("setup.access", json!(names.join(", ")), caller, time);
    }

    /// Something an agent did that is not a stored setting, such as choosing a
    /// model preset or launch at login. Listed, never undone.
    pub fn record_event(&mut self, key: &str, value: Value, caller: &str, time: DateTime<Utc>) {
        self.add(vec![Entry {
            caller: caller.to_string(),
            id: Uuid::new_v4(),
            key: key.to_string(),
            previous: None,
            time,
            value: Some(value),
        }]);
    }

    fn add(&mut self, entries: Vec<Entry>) {
        if entries.is_empty() {
            return;
        }
        append(&self.log, &entries);
        for entry in entries {
            self.recent.insert(0, entry);
        }
        self.recent.truncate(RECENT_LIMIT);
    }
}

/// Undo is offered only while the setting still holds the agent's value.
pub fn can_undo(entry: &Entry, settings: &Settings) -> bool {
    registry::spec(&entry.key).is_some()
        && !KEYS_WITHOUT_UNDO.contains(&entry.key.as_str())
        && match (encoded(settings).get(&entry.key), &entry.value) {
            (Some(now), Some(value)) => json_eq(now, value),
            (None, None) => true,
            _ => false,
        }
}

/// One line about an entry, for Settings.
pub fn summary(entry: &Entry) -> String {
    let text = |value: &Option<Value>| {
        value
            .as_ref()
            .and_then(Value::as_str)
            .unwrap_or("changed")
            .to_string()
    };
    match entry.key.as_str() {
        "setup.access" => {
            return format!(
                "Agent setup allowed: {}",
                entry
                    .value
                    .as_ref()
                    .and_then(Value::as_str)
                    .unwrap_or("settings")
            );
        }
        "models.preset" => return format!("Model preset: {}", text(&entry.value)),
        "launchAtLogin" => {
            return format!(
                "Launch at login: {}",
                if entry.value == Some(json!(true)) {
                    "on"
                } else {
                    "off"
                }
            );
        }
        _ => {}
    }
    if let Some(secret) = entry.key.strip_prefix("secret.").and_then(AppSecret::parse) {
        return format!("{}: {}", secret.title(), text(&entry.value));
    }
    let Some(spec) = registry::spec(&entry.key) else {
        return entry.key.clone();
    };
    let shown = |value: &Option<Value>| {
        let Some(value) = value else {
            return "default".to_string();
        };
        match spec.presented_redacted(Some(value)) {
            Value::String(text) if text.is_empty() => "empty".to_string(),
            Value::String(text) => text,
            Value::Bool(flag) => if flag { "on" } else { "off" }.to_string(),
            Value::Array(items) => format!("{} entries", items.len()),
            other => other.to_string(),
        }
    };
    format!(
        "{}: {} → {}",
        spec.title,
        shown(&entry.previous),
        shown(&entry.value)
    )
}

fn append(log: &Path, entries: &[Entry]) {
    let mut lines = Vec::new();
    for entry in entries {
        if let Ok(line) = serde_json::to_vec(entry) {
            lines.extend_from_slice(&line);
            lines.push(b'\n');
        }
    }
    if let Some(parent) = log.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    match options.open(log) {
        Ok(mut file) => {
            if let Err(err) = file.write_all(&lines) {
                log::warn!("could not write the settings change log: {err}");
            }
        }
        Err(err) => log::warn!("could not open the settings change log: {err}"),
    }
}

fn load(log: &Path) -> Vec<Entry> {
    let Ok(text) = std::fs::read_to_string(log) else {
        return Vec::new();
    };
    text.lines()
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control::change::ChangeClass;

    fn item(key: &str, previous: Value, stored: Value) -> PlanItem {
        PlanItem {
            spec: *registry::spec(key).unwrap(),
            previous: Some(previous),
            stored: Some(stored),
            change: ChangeClass::Preference,
        }
    }

    #[test]
    fn reads_the_macs_log_format() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        std::fs::create_dir_all(dir.path().join("diagnostics")).unwrap();
        // As Swift's JSONEncoder writes `Entry`: sorted keys and `.iso8601`.
        std::fs::write(
            dir.path().join("diagnostics/settings-changes.jsonl"),
            concat!(
                r#"{"caller":"lokalbot-cli via claude","id":"6F0E2C52-7B0C-4D2F-9A53-0B8E4D5F1A10","key":"appTheme","previous":"system","time":"2026-10-17T12:00:00Z","value":"dark"}"#,
                "\n",
                r#"{"caller":"You (Undo)","id":"7F0E2C52-7B0C-4D2F-9A53-0B8E4D5F1A10","key":"agentReasoningLevel","time":"2026-10-17T12:01:00Z"}"#,
                "\n",
            ),
        )
        .unwrap();
        let changes = AgentSettingsChanges::new(&paths);
        assert_eq!(changes.recent.len(), 2);
        assert_eq!(changes.recent[1].key, "appTheme");
        assert_eq!(changes.recent[1].value, Some(json!("dark")));
        assert_eq!(changes.recent[0].value, None);
    }

    #[test]
    fn writes_what_the_mac_reads() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        let mut changes = AgentSettingsChanges::new(&paths);
        let time = DateTime::parse_from_rfc3339("2026-10-17T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        changes.record(
            &[item("appTheme", json!("system"), json!("dark"))],
            "claude",
            time,
        );
        let text =
            std::fs::read_to_string(dir.path().join("diagnostics/settings-changes.jsonl")).unwrap();
        let line = text.lines().next().unwrap();
        assert!(line.starts_with(r#"{"caller":"claude","id":""#));
        assert!(line.ends_with(
            r#","key":"appTheme","previous":"system","time":"2026-10-17T12:00:00Z","value":"dark"}"#
        ));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(dir.path().join("diagnostics/settings-changes.jsonl"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        // It survives a reload.
        assert_eq!(AgentSettingsChanges::new(&paths).recent.len(), 1);
    }

    #[test]
    fn the_recent_list_is_bounded_and_newest_first() {
        let dir = tempfile::tempdir().unwrap();
        let mut changes = AgentSettingsChanges::new(&LibraryPaths::new(dir.path()));
        for hour in 0..30 {
            changes.record_event("models.preset", json!(hour), "claude", Utc::now());
        }
        assert_eq!(changes.recent.len(), RECENT_LIMIT);
        assert_eq!(changes.recent[0].value, Some(json!(29)));
    }

    #[test]
    fn secrets_are_named_and_never_stored() {
        let dir = tempfile::tempdir().unwrap();
        let mut changes = AgentSettingsChanges::new(&LibraryPaths::new(dir.path()));
        changes.record_secret(AppSecret::OpenAICompatible, true, "claude", Utc::now());
        assert_eq!(changes.recent[0].key, "secret.openai-compatible");
        assert_eq!(changes.recent[0].value, Some(json!("set")));
        assert_eq!(
            summary(&changes.recent[0]),
            "OpenAI-compatible server API key: set"
        );
    }

    #[test]
    fn undo_needs_the_agents_value_still_there() {
        let entry = Entry {
            caller: "claude".into(),
            id: Uuid::new_v4(),
            key: "appTheme".into(),
            previous: Some(json!("system")),
            time: Utc::now(),
            value: Some(json!("dark")),
        };
        let mut settings = Settings::default();
        assert!(!can_undo(&entry, &settings));
        settings.app_theme = crate::settings::AppTheme::Dark;
        assert!(can_undo(&entry, &settings));
        let retention = Entry {
            key: "retentionDays".into(),
            value: Some(json!(14)),
            ..entry.clone()
        };
        assert!(!can_undo(&retention, &Settings::default()));
        let event = Entry {
            key: "models.preset".into(),
            value: Some(json!("recommended")),
            ..entry
        };
        assert!(!can_undo(&event, &settings));
    }
}
