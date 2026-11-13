//! Every setting the terminal can see (`SettingRegistry.swift`): its stored key,
//! where it lives, its type and how a change to it is authorized.

use std::collections::HashMap;
use std::sync::LazyLock;

use serde_json::{Map, Value, json};

/// Where a setting lives in Settings, with the Mac's tokens so agents read the
/// same names everywhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettingCategory {
    General,
    Recording,
    DayMemory,
    Files,
    Ask,
    PersonalContext,
    Daily,
    Writing,
    Dictation,
    Models,
    Devices,
}

impl SettingCategory {
    pub const ALL: [SettingCategory; 11] = [
        Self::General,
        Self::Recording,
        Self::DayMemory,
        Self::Files,
        Self::Ask,
        Self::PersonalContext,
        Self::Daily,
        Self::Writing,
        Self::Dictation,
        Self::Models,
        Self::Devices,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::Recording => "recording",
            Self::DayMemory => "dayMemory",
            Self::Files => "files",
            Self::Ask => "ask",
            Self::PersonalContext => "personalContext",
            Self::Daily => "daily",
            Self::Writing => "writing",
            Self::Dictation => "dictation",
            Self::Models => "models",
            Self::Devices => "devices",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|c| c.raw_value() == text)
    }
}

/// How a terminal change to a setting is authorized once the person allows
/// external agents to change settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SettingTier {
    /// Changes nothing about what is captured, read, recorded, or sent.
    Preference,
    /// Widening it (turning it on, raising it, removing an exclusion,
    /// approving an origin) needs the person's approval in the app.
    /// Narrowing it is a preference.
    Consent,
    /// Shown, never changed from the terminal.
    ReadOnly,
}

impl SettingTier {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Preference => "preference",
            Self::Consent => "consent",
            Self::ReadOnly => "readOnly",
        }
    }
}

/// What a text setting holds, for `config describe` and the schema.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextFormat {
    Plain,
    Url,
    Path,
    CommaSeparated,
    LanguageCode,
    ModelId,
    Shortcut,
}

impl TextFormat {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Plain => "plain",
            Self::Url => "url",
            Self::Path => "path",
            Self::CommaSeparated => "commaSeparated",
            Self::LanguageCode => "languageCode",
            Self::ModelId => "modelID",
            Self::Shortcut => "shortcut",
        }
    }
}

/// The value `Settings` stores for a choice.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Stored {
    Text(&'static str),
    Integer(i64),
}

impl Stored {
    pub fn json(self) -> Value {
        match self {
            Self::Text(text) => json!(text),
            Self::Integer(number) => json!(number),
        }
    }
}

/// One allowed value: the stable token agents read and write, and the value
/// `Settings` stores for it (some enums store display strings or key codes).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SettingChoice {
    pub token: &'static str,
    pub stored: Stored,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SettingKind {
    Bool,
    Integer(Option<(i64, i64)>),
    Number(Option<(f64, f64)>),
    Text(TextFormat),
    TextList,
    Choice(&'static [SettingChoice]),
    ChoiceList(&'static [SettingChoice]),
    /// A nested value (a model description) reported as stored.
    Structured,
}

impl SettingKind {
    pub fn type_name(self) -> &'static str {
        match self {
            Self::Bool => "boolean",
            Self::Integer(_) => "integer",
            Self::Number(_) => "number",
            Self::Text(_) => "string",
            Self::TextList => "string-list",
            Self::Choice(_) => "choice",
            Self::ChoiceList(_) => "choice-list",
            Self::Structured => "structured",
        }
    }

    pub fn choices(self) -> Option<&'static [SettingChoice]> {
        match self {
            Self::Choice(choices) | Self::ChoiceList(choices) => Some(choices),
            _ => None,
        }
    }
}

/// One persisted `Settings` key as the terminal sees it. The key is the stored
/// JSON key, which Settings search also uses as `settings.<key>`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SettingSpec {
    pub key: &'static str,
    pub category: SettingCategory,
    pub title: &'static str,
    pub kind: SettingKind,
    pub tier: SettingTier,
    pub aliases: &'static str,
    pub summary: &'static str,
}

impl SettingSpec {
    /// The stored value presented to agents: choice values become tokens. A
    /// stored value that matches no known choice is returned unchanged.
    pub fn presented(&self, stored: &Value) -> Value {
        match self.kind {
            SettingKind::Choice(choices) => choice_token(choices, stored),
            SettingKind::ChoiceList(choices) => match stored {
                Value::Array(values) => {
                    Value::Array(values.iter().map(|v| choice_token(choices, v)).collect())
                }
                other => other.clone(),
            },
            _ => stored.clone(),
        }
    }

    /// What `config describe` prints.
    pub fn description_json(&self) -> Value {
        let mut object = Map::new();
        object.insert("key".into(), json!(self.key));
        object.insert("title".into(), json!(self.title));
        object.insert("summary".into(), json!(self.summary));
        object.insert("category".into(), json!(self.category.raw_value()));
        object.insert("tier".into(), json!(self.tier.raw_value()));
        object.insert("type".into(), json!(self.kind.type_name()));
        match self.kind {
            SettingKind::Integer(Some((low, high))) => {
                object.insert("minimum".into(), json!(low));
                object.insert("maximum".into(), json!(high));
            }
            SettingKind::Number(Some((low, high))) => {
                object.insert("minimum".into(), json!(low));
                object.insert("maximum".into(), json!(high));
            }
            SettingKind::Text(format) => {
                object.insert("format".into(), json!(format.raw_value()));
            }
            SettingKind::Choice(choices) | SettingKind::ChoiceList(choices) => {
                let values: Vec<&str> = choices.iter().map(|c| c.token).collect();
                object.insert("values".into(), json!(values));
            }
            _ => {}
        }
        Value::Object(object)
    }

    /// The JSON Schema property for this key.
    pub fn schema_property(&self) -> Value {
        let mut object = Map::new();
        object.insert("title".into(), json!(self.title));
        object.insert("description".into(), json!(self.summary));
        object.insert(
            "x-lokalbot-category".into(),
            json!(self.category.raw_value()),
        );
        object.insert("x-lokalbot-tier".into(), json!(self.tier.raw_value()));
        match self.kind {
            SettingKind::Bool => {
                object.insert("type".into(), json!("boolean"));
            }
            SettingKind::Integer(range) => {
                object.insert("type".into(), json!("integer"));
                if let Some((low, high)) = range {
                    object.insert("minimum".into(), json!(low));
                    object.insert("maximum".into(), json!(high));
                }
            }
            SettingKind::Number(range) => {
                object.insert("type".into(), json!("number"));
                if let Some((low, high)) = range {
                    object.insert("minimum".into(), json!(low));
                    object.insert("maximum".into(), json!(high));
                }
            }
            SettingKind::Text(format) => {
                object.insert("type".into(), json!("string"));
                if format == TextFormat::Url {
                    object.insert("format".into(), json!("uri"));
                } else if format != TextFormat::Plain {
                    object.insert("x-lokalbot-format".into(), json!(format.raw_value()));
                }
            }
            SettingKind::TextList => {
                object.insert("type".into(), json!("array"));
                object.insert("items".into(), json!({"type": "string"}));
            }
            SettingKind::Choice(choices) => {
                let values: Vec<&str> = choices.iter().map(|c| c.token).collect();
                object.insert("type".into(), json!("string"));
                object.insert("enum".into(), json!(values));
            }
            SettingKind::ChoiceList(choices) => {
                let values: Vec<&str> = choices.iter().map(|c| c.token).collect();
                object.insert("type".into(), json!("array"));
                object.insert("uniqueItems".into(), json!(true));
                object.insert("items".into(), json!({"type": "string", "enum": values}));
            }
            SettingKind::Structured => {}
        }
        Value::Object(object)
    }
}

fn choice_token(choices: &[SettingChoice], stored: &Value) -> Value {
    choices
        .iter()
        .find(|c| super::json_eq(&c.stored.json(), stored))
        .map(|c| json!(c.token))
        .unwrap_or_else(|| stored.clone())
}

/// Stored keys that are bookkeeping or that only the app's own screens change:
/// never listed or changed from the terminal. `launchAtLogin` has its own
/// method, and `codingAgentEvidenceConfirmed` records the person's own choice.
pub const INTERNAL_KEYS: [&str; 10] = [
    "onboardingCompleted",
    "gettingStartedDismissed",
    "chatGPTPlanNoticeAcknowledged",
    "codingAgentEvidenceConfirmed",
    "launchAtLogin",
    "githubStarDismissed",
    "githubStarSummaryCompleted",
    "githubStarActiveDays",
    "autocompleteDefaultAdopted",
    "paneWidths",
];

/// Stored only so a library from a Mac round-trips; nothing reads it here.
pub const UNUSED_HERE_KEYS: [&str; 1] = ["diarizationModel"];

static ALL: LazyLock<Vec<SettingSpec>> = LazyLock::new(super::registry_table::table);

static BY_KEY: LazyLock<HashMap<&'static str, SettingSpec>> =
    LazyLock::new(|| ALL.iter().map(|spec| (spec.key, *spec)).collect());

pub fn all() -> &'static [SettingSpec] {
    &ALL
}

pub fn spec(key: &str) -> Option<&'static SettingSpec> {
    BY_KEY.get(key)
}

/// Settings matching every word of the query in the key, title, aliases,
/// summary, or category, best matches first.
pub fn search(query: &str) -> Vec<&'static SettingSpec> {
    let normalized = query.trim().to_lowercase();
    let mut found: Vec<&'static SettingSpec> = all()
        .iter()
        .filter(|spec| {
            crate::text::settings_search_matches(
                query,
                &[
                    spec.key,
                    spec.title,
                    spec.aliases,
                    spec.summary,
                    spec.category.raw_value(),
                ],
            )
        })
        .collect();
    let score = |spec: &SettingSpec| {
        let title = spec.title.to_lowercase();
        if spec.key.to_lowercase() == normalized || title == normalized {
            3
        } else if title.starts_with(&normalized) {
            2
        } else {
            1
        }
    };
    found.sort_by(|a, b| score(b).cmp(&score(a)).then_with(|| a.key.cmp(b.key)));
    found
}

pub fn json_schema() -> Value {
    let properties: Map<String, Value> = all()
        .iter()
        .map(|spec| (spec.key.to_string(), spec.schema_property()))
        .collect();
    json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "LokalBot settings",
        "description": "Keys accepted by lokalbot-cli config. Values use the tokens listed here.",
        "type": "object",
        "properties": properties,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::Settings;

    #[test]
    fn every_stored_key_has_one_spec_or_is_set_aside() {
        let stored = serde_json::to_value(Settings {
            agent_reasoning_level: Some(Default::default()),
            ..Default::default()
        })
        .unwrap();
        let stored: std::collections::BTreeSet<String> =
            stored.as_object().unwrap().keys().cloned().collect();
        let mut seen = std::collections::BTreeSet::new();
        for spec in all() {
            assert!(seen.insert(spec.key.to_string()), "{} twice", spec.key);
        }
        let mut expected = seen.clone();
        expected.extend(INTERNAL_KEYS.iter().map(|k| k.to_string()));
        expected.extend(UNUSED_HERE_KEYS.iter().map(|k| k.to_string()));
        assert_eq!(
            stored, expected,
            "add new Settings keys to the registry, or list bookkeeping keys in INTERNAL_KEYS"
        );
    }

    #[test]
    fn choices_decode_into_the_real_settings() {
        // Each stored choice has to be something `Settings` accepts, and it
        // comes back the same. This keeps the table in step with the enums.
        let base = serde_json::to_value(Settings::default()).unwrap();
        for spec in all() {
            let Some(choices) = spec.kind.choices() else {
                continue;
            };
            for choice in choices {
                let mut object = base.clone();
                object[spec.key] = match spec.kind {
                    SettingKind::ChoiceList(_) => json!([choice.stored.json()]),
                    _ => choice.stored.json(),
                };
                let decoded: Settings = serde_json::from_value(object)
                    .unwrap_or_else(|err| panic!("{} rejects {}: {err}", spec.key, choice.token));
                let back = serde_json::to_value(decoded).unwrap();
                let expected = match spec.kind {
                    SettingKind::ChoiceList(_) => json!([choice.stored.json()]),
                    _ => choice.stored.json(),
                };
                assert!(
                    crate::control::json_eq(&back[spec.key], &expected),
                    "{} {}",
                    spec.key,
                    choice.token
                );
            }
        }
    }

    #[test]
    fn defaults_fit_their_kinds() {
        let defaults = serde_json::to_value(Settings::default()).unwrap();
        for spec in all() {
            let Some(value) = defaults.get(spec.key) else {
                // Only an optional setting may be absent by default.
                assert_eq!(spec.key, "agentReasoningLevel");
                continue;
            };
            let fits = match spec.kind {
                SettingKind::Bool => value.is_boolean(),
                SettingKind::Integer(_) => value.is_i64() || value.is_u64(),
                SettingKind::Number(_) => value.is_number(),
                SettingKind::Text(_) => value.is_string(),
                SettingKind::TextList | SettingKind::ChoiceList(_) | SettingKind::Structured => {
                    value.is_array() || value.is_object()
                }
                SettingKind::Choice(_) => {
                    !spec.presented(value).is_null()
                        && spec
                            .kind
                            .choices()
                            .unwrap()
                            .iter()
                            .any(|c| crate::control::json_eq(&c.stored.json(), value))
                }
            };
            assert!(fits, "{} default {value} doesn't fit", spec.key);
            match spec.kind {
                SettingKind::Integer(Some((low, high))) => {
                    let number = value.as_i64().unwrap();
                    assert!((low..=high).contains(&number), "{}", spec.key);
                }
                SettingKind::Number(Some((low, high))) => {
                    let number = value.as_f64().unwrap();
                    assert!((low..=high).contains(&number), "{}", spec.key);
                }
                _ => {}
            }
        }
    }

    #[test]
    fn languages_stay_in_step_with_the_interface() {
        let choices = spec("appLanguage").unwrap().kind.choices().unwrap();
        for language in lokalbot_i18n::LANGUAGES {
            assert!(
                choices
                    .iter()
                    .any(|c| c.stored == Stored::Text(language.code)),
                "{} has no choice",
                language.code
            );
        }
    }

    #[test]
    fn sensitive_settings_keep_the_macs_tier() {
        for key in [
            "autoRecordMode",
            "trackingEnabled",
            "screenContextCaptureMode",
            "retentionDays",
            "keepOCRTextForever",
            "excludedApps",
            "excludedScreenDomains",
            "approvedRemoteInferenceOrigins",
            "approvedRemoteTranscriptionOrigins",
            "approvedRemoteAutocompleteOrigins",
            "openRouterDataPolicy",
            "modelDownloadSource",
            "cotypingEnabled",
            "dictationEnabled",
            "dictationRetainAudio",
            "companionSharingEnabled",
            "companionHistory",
            "fileSearchEnabled",
            "fileSearchFolders",
            "codingAgentEvidenceEnabled",
            "codingAgentNotesEnabled",
            "memoryRoutineFolder",
            "dailyMemoryExportFolder",
            "meetingNoteExportFolder",
            "recordSystemAudio",
            "calendarEvolutionEnabled",
            "checkForUpdates",
        ] {
            assert_eq!(spec(key).unwrap().tier, SettingTier::Consent, "{key}");
        }
        assert_eq!(
            spec("customBuiltInModels").unwrap().tier,
            SettingTier::ReadOnly
        );
        for key in INTERNAL_KEYS.iter().chain(UNUSED_HERE_KEYS.iter()) {
            assert!(spec(key).is_none(), "{key}");
        }
    }

    #[test]
    fn search_finds_settings_by_plain_words() {
        let keys = |query: &str| -> Vec<&str> { search(query).iter().map(|s| s.key).collect() };
        assert!(keys("dark mode").contains(&"appTheme"));
        assert!(keys("auto-record").contains(&"autoRecordMode"));
        assert_eq!(keys("autoRecordMode").first(), Some(&"autoRecordMode"));
    }

    #[test]
    fn the_schema_describes_every_key() {
        let schema = json_schema();
        for spec in all() {
            assert!(schema["properties"].get(spec.key).is_some(), "{}", spec.key);
        }
        assert_eq!(
            spec("noteTemplate").unwrap().description_json()["values"][1],
            "lecture"
        );
    }
}
