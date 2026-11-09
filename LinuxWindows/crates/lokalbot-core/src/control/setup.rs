//! The one way the terminal can ask for access (`AgentSetup.swift`): a
//! short-lived request file in the library's `control/` folder that the app
//! shows to the person. Only the app writes grant markers, and only after the
//! person allows the request in LokalBot. A request written by any other
//! process gains nothing without that click.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, Utc};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::protocol::{ControlError, MODEL_PRESETS, RequestState};

/// Passed by `lokalbot-cli setup start` when it opens the app.
pub const LAUNCH_ARGUMENT: &str = "--lokalbot-agent-setup";
pub const LIFETIME_SECONDS: i64 = 5 * 60;
pub const MAXIMUM_FILE_BYTES: u64 = 16_384;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Grant {
    Settings,
    MeetingLibrary,
    ScreenMemory,
    /// Search the folders chosen under Files (`search_files`).
    Files,
}

impl Grant {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Settings => "settings",
            Self::MeetingLibrary => "meetingLibrary",
            Self::ScreenMemory => "screenMemory",
            Self::Files => "files",
        }
    }
}

fn request_version() -> i64 {
    1
}

// Sorted keys, as Swift's encoder writes them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SetupRequest {
    #[serde(rename = "createdAt", with = "super::iso8601")]
    pub created_at: DateTime<Utc>,
    #[serde(rename = "expiresAt", with = "super::iso8601")]
    pub expires_at: DateTime<Utc>,
    pub grants: Vec<Grant>,
    pub nonce: String,
    /// Who asked, as the CLI saw its own process tree, for example
    /// "lokalbot-cli via claude". Shown to the person, never trusted.
    pub requester: String,
    #[serde(default = "request_version")]
    pub version: i64,
}

impl SetupRequest {
    pub fn is_live(&self, at: DateTime<Utc>) -> bool {
        self.version == 1
            && !self.nonce.is_empty()
            && self.grants.contains(&Grant::Settings)
            && self.created_at <= at + Duration::seconds(60)
            && at < self.expires_at
            && (self.expires_at - self.created_at).num_seconds() <= LIFETIME_SECONDS + 1
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SetupAnswer {
    #[serde(rename = "answeredAt", with = "super::iso8601")]
    pub answered_at: DateTime<Utc>,
    /// What the person allowed; empty when they declined.
    pub grants: Vec<Grant>,
    pub nonce: String,
    pub state: RequestState,
}

pub fn request_path(control_dir: &Path) -> PathBuf {
    control_dir.join("setup-request.json")
}

pub fn answer_path(control_dir: &Path) -> PathBuf {
    control_dir.join("setup-answer.json")
}

pub fn read<T: DeserializeOwned>(path: &Path) -> Option<T> {
    let size = std::fs::metadata(path).ok()?.len();
    if size > MAXIMUM_FILE_BYTES {
        return None;
    }
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// Writes into the private control folder, readable by this user only.
pub fn write<T: Serialize>(value: &T, path: &Path) -> std::io::Result<()> {
    if let Some(directory) = path.parent() {
        crate::access::ensure_private_dir(directory)?;
    }
    let bytes = serde_json::to_vec(value).map_err(std::io::Error::other)?;
    crate::library::write_atomic(path, &bytes)?;
    crate::access::restrict_file(path);
    Ok(())
}

/// What `setup plan` prints and `setup apply` reads: the settings a setup
/// conversation covers, a model preset, and launch at login. `settings` has the
/// same shape as `config export`, so `config import` reads it too.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SetupPlan {
    pub settings: Map<String, Value>,
    pub models: Option<String>,
    pub launch_at_login: Option<bool>,
}

impl SetupPlan {
    /// The settings to talk through with the person, in the order to ask.
    pub const KEYS: [&'static str; 13] = [
        "autoRecordMode",
        "calendarDetectionEnabled",
        "transcriptionLanguage",
        "summaryLanguage",
        "noteTemplate",
        "trackingEnabled",
        "screenContextCaptureMode",
        "dayDigestAutoEnabled",
        "dreamingEnabled",
        "dictationEnabled",
        "cotypingEnabled",
        "menuBarOnly",
        "appLanguage",
    ];

    pub fn from_json(value: &Value) -> Result<Self, ControlError> {
        let Some(object) = value.as_object() else {
            return Err(ControlError::invalid_request(
                "A setup plan is a JSON object with \"settings\", \"models\", and \"launchAtLogin\".",
            ));
        };
        let plan = Self {
            settings: object
                .get("settings")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default(),
            models: object
                .get("models")
                .and_then(Value::as_str)
                .map(str::to_string),
            launch_at_login: object.get("launchAtLogin").and_then(Value::as_bool),
        };
        if let Some(models) = &plan.models
            && !MODEL_PRESETS.contains(&models.as_str())
        {
            return Err(ControlError::invalid_request(format!(
                "\"models\" must be one of: {}.",
                MODEL_PRESETS.join(", ")
            )));
        }
        if plan.settings.is_empty() && plan.models.is_none() && plan.launch_at_login.is_none() {
            return Err(ControlError::invalid_request(
                "The setup plan changes nothing.",
            ));
        }
        Ok(plan)
    }

    pub fn json(&self) -> Value {
        let mut object = Map::new();
        object.insert("settings".into(), Value::Object(self.settings.clone()));
        if let Some(models) = &self.models {
            object.insert("models".into(), json!(models));
        }
        if let Some(launch) = self.launch_at_login {
            object.insert("launchAtLogin".into(), json!(launch));
        }
        Value::Object(object)
    }
}

/// Names the program behind a process: its own name and, when it runs under a
/// shell, the nearest ancestor that is not one, such as "lokalbot-cli via
/// claude". Used for the audit log and the setup request. Never trusted.
pub fn describe_process(pid: u32) -> Option<String> {
    let name = process_name(pid)?;
    let mut ancestor = parent_of(pid);
    for _ in 0..6 {
        let Some(current) = ancestor else {
            break;
        };
        if let Some(parent) = process_name(current)
            && !is_shell(&parent)
        {
            return Some(format!("{name} via {parent}"));
        }
        ancestor = parent_of(current);
    }
    Some(name)
}

fn is_shell(name: &str) -> bool {
    const SHELLS: [&str; 17] = [
        "zsh",
        "bash",
        "sh",
        "fish",
        "dash",
        "login",
        "env",
        "sudo",
        "timeout",
        "nohup",
        "tmux",
        "screen",
        "cmd",
        "powershell",
        "pwsh",
        "conhost",
        "wezterm-gui",
    ];
    SHELLS.contains(&name.to_lowercase().as_str())
}

#[cfg(target_os = "linux")]
fn process_name(pid: u32) -> Option<String> {
    let path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    path.file_name().map(|n| n.to_string_lossy().into_owned())
}

#[cfg(target_os = "linux")]
fn parent_of(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &stat[stat.rfind(')')? + 1..];
    let parent: u32 = rest.split_whitespace().nth(1)?.parse().ok()?;
    (parent > 1).then_some(parent)
}

#[cfg(windows)]
fn snapshot_entry(pid: u32) -> Option<(String, u32)> {
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW,
        TH32CS_SNAPPROCESS,
    };
    // SAFETY: the snapshot handle is checked and closed here, and the entry is
    // a plain struct whose size field the API requires.
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return None;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        let mut found = None;
        let mut more = Process32FirstW(snapshot, &mut entry) != 0;
        while more {
            if entry.th32ProcessID == pid {
                let end = entry
                    .szExeFile
                    .iter()
                    .position(|c| *c == 0)
                    .unwrap_or(entry.szExeFile.len());
                let name = String::from_utf16_lossy(&entry.szExeFile[..end]);
                found = Some((
                    name.trim_end_matches(".exe").to_string(),
                    entry.th32ParentProcessID,
                ));
                break;
            }
            more = Process32NextW(snapshot, &mut entry) != 0;
        }
        CloseHandle(snapshot);
        found
    }
}

#[cfg(windows)]
fn process_name(pid: u32) -> Option<String> {
    snapshot_entry(pid).map(|(name, _)| name)
}

#[cfg(windows)]
fn parent_of(pid: u32) -> Option<u32> {
    snapshot_entry(pid)
        .map(|(_, parent)| parent)
        .filter(|parent| *parent > 4)
}

#[cfg(not(any(target_os = "linux", windows)))]
fn process_name(_: u32) -> Option<String> {
    None
}

#[cfg(not(any(target_os = "linux", windows)))]
fn parent_of(_: u32) -> Option<u32> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(1_800_000_000 + seconds, 0).unwrap()
    }

    fn request(grants: Vec<Grant>, created: i64, expires: i64) -> SetupRequest {
        SetupRequest {
            created_at: at(created),
            expires_at: at(expires),
            grants,
            nonce: "A".into(),
            requester: "lokalbot-cli via claude".into(),
            version: 1,
        }
    }

    #[test]
    fn a_request_must_ask_for_settings_and_be_short_lived() {
        assert!(request(vec![Grant::Settings], 0, 300).is_live(at(10)));
        assert!(!request(vec![Grant::MeetingLibrary], 0, 300).is_live(at(10)));
        assert!(!request(vec![Grant::Settings], 0, 300).is_live(at(300)));
        assert!(!request(vec![Grant::Settings], 0, 3000).is_live(at(10)));
        assert!(!request(vec![Grant::Settings], 500, 700).is_live(at(10)));
        let mut empty = request(vec![Grant::Settings], 0, 300);
        empty.nonce.clear();
        assert!(!empty.is_live(at(10)));
    }

    #[test]
    fn request_files_match_the_macs_and_stay_private() {
        let dir = tempfile::tempdir().unwrap();
        let control = dir.path().join("control");
        let path = request_path(&control);
        let written = request(
            vec![Grant::Settings, Grant::ScreenMemory, Grant::Files],
            0,
            300,
        );
        write(&written, &path).unwrap();
        assert_eq!(read::<SetupRequest>(&path).unwrap(), written);
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.starts_with(r#"{"createdAt":"2027-01-15T"#));
        assert!(text.contains(r#""grants":["settings","screenMemory","files"]"#));
        assert!(text.ends_with(r#""version":1}"#));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                std::fs::metadata(&control).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        // A file as Swift writes it.
        std::fs::write(
            &path,
            r#"{"createdAt":"2026-10-17T12:00:00Z","expiresAt":"2026-10-17T12:05:00Z","grants":["settings"],"nonce":"N","requester":"r","version":1}"#,
        )
        .unwrap();
        assert_eq!(read::<SetupRequest>(&path).unwrap().nonce, "N");
        // Oversized files are not read.
        std::fs::write(&path, vec![b' '; MAXIMUM_FILE_BYTES as usize + 1]).unwrap();
        assert!(read::<SetupRequest>(&path).is_none());
    }

    #[test]
    fn answers_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = answer_path(dir.path());
        let answer = SetupAnswer {
            answered_at: at(0),
            grants: vec![Grant::Settings],
            nonce: "N".into(),
            state: RequestState::Approved,
        };
        write(&answer, &path).unwrap();
        assert_eq!(read::<SetupAnswer>(&path).unwrap(), answer);
        assert!(
            std::fs::read_to_string(&path)
                .unwrap()
                .contains(r#""state":"approved""#)
        );
    }

    #[test]
    fn plans_read_what_they_print() {
        let plan = SetupPlan::from_json(&json!({
            "settings": {"appTheme": "dark"},
            "models": "lightweight",
            "launchAtLogin": true,
        }))
        .unwrap();
        assert_eq!(SetupPlan::from_json(&plan.json()).unwrap(), plan);
        assert_eq!(
            SetupPlan::from_json(&json!({"settings": {}}))
                .unwrap_err()
                .code,
            "invalid_request"
        );
        assert_eq!(
            SetupPlan::from_json(&json!({"models": "huge"}))
                .unwrap_err()
                .code,
            "invalid_request"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn describes_this_process() {
        let described = describe_process(std::process::id()).unwrap();
        assert!(described.contains("lokalbot_core"), "{described}");
    }
}
