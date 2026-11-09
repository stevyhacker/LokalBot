//! The CLI's requests to the running app (`AppControlProtocol.swift`): one JSON
//! object per line, one request per connection.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

pub const VERSION: i64 = 1;
pub const MAXIMUM_MESSAGE_BYTES: usize = 1_048_576;

/// `lokalbot-cli` starting the app for a request comes up in the tray like a
/// login launch, with no window. The same flag the autostart entry passes.
pub const BACKGROUND_LAUNCH_ARGUMENT: &str = "--autostart";

/// Settings sections `open settings <name>` accepts besides setting keys.
pub const SETTINGS_DESTINATIONS: [&str; 11] = [
    "models",
    "permissions",
    "agentAccess",
    "screenMemoryAccess",
    "personalContextAccess",
    "filesAccess",
    "settingsControlAccess",
    "memoryHealth",
    "resourceMonitor",
    "autocompleteStatistics",
    "dictationWritingProfile",
];

/// Names `permissions request` accepts.
pub const PERMISSION_NAMES: [&str; 5] = [
    "microphone",
    "accessibility",
    "screen-recording",
    "input-monitoring",
    "calendar",
];

/// Model presets `models preset` and setup plans accept.
pub const MODEL_PRESETS: [&str; 2] = ["recommended", "lightweight"];

pub const METHOD_HELLO: &str = "hello";
pub const METHOD_SETTINGS_LIST: &str = "settings.list";
pub const METHOD_SETTINGS_GET: &str = "settings.get";
pub const METHOD_SETTINGS_SET: &str = "settings.set";
pub const METHOD_SETTINGS_REQUEST: &str = "settings.request";
pub const METHOD_SECRET_LIST: &str = "secret.list";
pub const METHOD_SECRET_SET: &str = "secret.set";
pub const METHOD_SECRET_CLEAR: &str = "secret.clear";
pub const METHOD_SETUP_PLAN: &str = "setup.plan";
pub const METHOD_SETUP_FINISH: &str = "setup.finish";
pub const METHOD_MODELS_STATUS: &str = "models.status";
pub const METHOD_MODELS_PRESET: &str = "models.preset";
pub const METHOD_MODELS_DOWNLOAD: &str = "models.download";
pub const METHOD_MODELS_CANCEL: &str = "models.cancel";
pub const METHOD_PERMISSIONS_LIST: &str = "permissions.list";
pub const METHOD_PERMISSIONS_REQUEST: &str = "permissions.request";
pub const METHOD_LAUNCH_AT_LOGIN: &str = "app.launchAtLogin";
pub const METHOD_RESTART: &str = "app.restart";
pub const METHOD_DOCTOR: &str = "doctor";
pub const METHOD_STATUS: &str = "status";
pub const METHOD_OPEN: &str = "open";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub protocol: i64,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub params: Option<Map<String, Value>>,
}

impl Request {
    pub fn new(method: &str, params: Option<Map<String, Value>>) -> Self {
        Self {
            protocol: VERSION,
            method: method.to_string(),
            params,
        }
    }
}

/// A stable error the CLI prints as `[code] message`, like the MCP tools'
/// `[access_disabled]`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ControlError {
    pub code: String,
    pub message: String,
    /// Structured detail an agent can act on, such as the changes that need
    /// approval.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

impl std::fmt::Display for ControlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl std::error::Error for ControlError {}

impl ControlError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
            details: None,
        }
    }

    pub fn other(code: &str, message: impl Into<String>) -> Self {
        Self::new(code, message)
    }

    pub fn settings_access_disabled() -> Self {
        Self::new(
            "settings_access_disabled",
            crate::access::SETTINGS_CONTROL_DISABLED_MESSAGE,
        )
    }

    pub fn unknown_key(key: &str) -> Self {
        Self::new(
            "unknown_key",
            format!(
                "No setting is named {key}. Run `lokalbot-cli config search <words>` to find one."
            ),
        )
    }

    pub fn invalid_value(key: &str, message: &str) -> Self {
        Self::new("invalid_value", format!("{key} {message}."))
    }

    pub fn read_only(keys: &[&str]) -> Self {
        Self {
            details: Some(json!(keys)),
            ..Self::new(
                "read_only",
                format!("{} can't be changed from the terminal.", keys.join(", ")),
            )
        }
    }

    /// A widening change, or a new API key, waits for the person in LokalBot.
    /// `details` is the request as `settings.request` reports it.
    pub fn needs_approval(request: Value, asking: &str) -> Self {
        let id = request["id"].as_str().unwrap_or("<id>").to_string();
        Self {
            details: Some(request),
            ..Self::new(
                "needs_approval",
                format!(
                    "{asking} needs the person's approval in LokalBot, so the request is waiting there. Nothing changes unless they approve it. Run `lokalbot-cli config request {id} --wait 120` for the answer."
                ),
            )
        }
    }

    pub fn denied() -> Self {
        Self::new(
            "denied",
            "The person declined this request in LokalBot. Nothing was changed. Don't ask again unless they say so.",
        )
    }

    pub fn expired() -> Self {
        Self::new(
            "expired",
            "Nobody answered this request in LokalBot before it expired. Nothing was changed.",
        )
    }

    pub fn unknown_request(id: &str) -> Self {
        Self::new(
            "unknown_request",
            format!(
                "LokalBot has no request {id}. Requests are forgotten 30 minutes after they're answered, and when LokalBot quits."
            ),
        )
    }

    pub fn too_many_requests() -> Self {
        Self::new(
            "too_many_requests",
            "Requests are already waiting for the person in LokalBot. Wait for them to be answered first.",
        )
    }

    pub fn unknown_secret(name: &str) -> Self {
        let names: Vec<&str> = AppSecret::ALL.iter().map(|s| s.raw_value()).collect();
        Self::new(
            "unknown_secret",
            format!(
                "No API key is named {name}. Choose one of: {}.",
                names.join(", ")
            ),
        )
    }

    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self::new("invalid_request", message)
    }

    pub fn unknown_method(method: &str) -> Self {
        Self::new(
            "unknown_method",
            format!("LokalBot does not handle {method}."),
        )
    }

    pub fn unsupported_protocol() -> Self {
        Self::new(
            "app_outdated",
            "The running LokalBot does not understand this lokalbot-cli. Restart LokalBot to finish updating it.",
        )
    }

    pub fn app_not_running(reason: impl Into<String>) -> Self {
        Self::new("app_not_running", reason)
    }

    pub fn app_not_responding() -> Self {
        Self::new(
            "app_not_responding",
            "LokalBot is running but did not answer. If it was just updated, restart it.",
        )
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub protocol: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ControlError>,
}

impl Response {
    pub fn success(result: Value) -> Self {
        Self {
            protocol: VERSION,
            result: Some(result),
            error: None,
        }
    }

    pub fn failure(error: ControlError) -> Self {
        Self {
            protocol: VERSION,
            result: None,
            error: Some(error),
        }
    }
}

/// Where a request that needs the person stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RequestState {
    Pending,
    Approved,
    Denied,
    Expired,
}

impl RequestState {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Approved => "approved",
            Self::Denied => "denied",
            Self::Expired => "expired",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "pending" => Some(Self::Pending),
            "approved" => Some(Self::Approved),
            "denied" => Some(Self::Denied),
            "expired" => Some(Self::Expired),
            _ => None,
        }
    }
}

/// The API keys `lokalbot-cli secret` can set. Keys are write-only from the
/// terminal: the CLI can say whether one is saved, never read it back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppSecret {
    OpenAICompatible,
    RemoteTranscription,
    AutocompleteServer,
}

impl AppSecret {
    pub const ALL: [AppSecret; 3] = [
        Self::OpenAICompatible,
        Self::RemoteTranscription,
        Self::AutocompleteServer,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::OpenAICompatible => "openai-compatible",
            Self::RemoteTranscription => "remote-transcription",
            Self::AutocompleteServer => "autocomplete-server",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.raw_value() == name)
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::OpenAICompatible => "OpenAI-compatible server API key",
            Self::RemoteTranscription => "Transcription server API key",
            Self::AutocompleteServer => "Autocomplete server API key",
        }
    }

    pub fn summary(self) -> &'static str {
        match self {
            Self::OpenAICompatible => {
                "Sent with Think requests to the OpenAI-compatible server in Settings → Models. The transcription server uses it too when it has no key of its own."
            }
            Self::RemoteTranscription => {
                "Sent with transcription requests to the server in Settings → Models."
            }
            Self::AutocompleteServer => {
                "Sent with autocomplete requests to the server in Settings → Models."
            }
        }
    }

    /// The last four characters, so the person can tell which key they are
    /// approving without seeing it.
    pub fn hint(value: &str) -> String {
        let characters: Vec<char> = value.chars().collect();
        if characters.len() > 8 {
            format!(
                "…{}",
                characters[characters.len() - 4..]
                    .iter()
                    .collect::<String>()
            )
        } else {
            String::new()
        }
    }
}

/// An API key held only until its request is answered. It never prints.
#[derive(Clone, PartialEq, Eq, Default)]
pub struct SecretValue(String);

impl SecretValue {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn expose(&self) -> &str {
        &self.0
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl std::fmt::Debug for SecretValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SecretValue(<hidden>)")
    }
}

/// Reads a key from `secret.set`: one line of at most 4 KiB.
pub fn validated_secret_value(raw: &str) -> Option<String> {
    let value = raw.trim();
    (!value.is_empty() && value.len() <= 4096 && !value.contains(['\n', '\r']))
        .then(|| value.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_format_matches_the_mac() {
        let mut params = Map::new();
        params.insert("keys".into(), json!(["appTheme"]));
        let line = serde_json::to_string(&Request::new(METHOD_SETTINGS_GET, Some(params))).unwrap();
        assert_eq!(
            line,
            r#"{"protocol":1,"method":"settings.get","params":{"keys":["appTheme"]}}"#
        );
        let decoded: Request = serde_json::from_str(r#"{"method":"hello","protocol":1}"#).unwrap();
        assert_eq!(decoded.method, "hello");
        let failure = Response::failure(ControlError::denied());
        let text = serde_json::to_string(&failure).unwrap();
        assert!(text.contains(r#""error":{"code":"denied""#));
        assert!(!text.contains("result"));
        assert_eq!(
            ControlError::denied().to_string().split(']').next(),
            Some("[denied")
        );
    }

    #[test]
    fn secrets_never_print_and_show_only_a_hint() {
        let value = SecretValue::new("sk-abcdefgh1234");
        assert_eq!(format!("{value:?}"), "SecretValue(<hidden>)");
        assert_eq!(AppSecret::hint("sk-abcdefgh1234"), "…1234");
        assert_eq!(AppSecret::hint("short"), "");
        assert_eq!(validated_secret_value("  key\n").as_deref(), Some("key"));
        assert_eq!(validated_secret_value("two\nlines"), None);
        assert_eq!(validated_secret_value("   "), None);
        assert_eq!(validated_secret_value(&"k".repeat(4097)), None);
    }
}
