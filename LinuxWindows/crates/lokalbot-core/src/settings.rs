//! `settings.json` in the library root.
//!
//! Keys follow the macOS `AppSettings` blob where the setting exists on both
//! platforms. Decoding is tolerant: a missing or unreadable key takes its
//! default, so older or newer files always load.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::model::activity::ScreenContextMode;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    // General
    pub launch_at_login: bool,
    /// Closing the window keeps LokalBot running in the system tray.
    #[serde(rename = "menuBarOnly")]
    pub run_in_tray: bool,
    pub app_theme: AppTheme,
    /// Interface only; compatible with macOS's appLanguage preference.
    pub app_language: String,
    pub text_size: TextSize,
    pub quick_recall_enabled: bool,
    pub quick_recall_shortcut: String,
    pub check_for_updates: bool,
    pub onboarding_completed: bool,
    pub getting_started_dismissed: bool,

    // Meetings
    pub auto_record_mode: AutoRecordMode,
    pub stop_debounce_seconds: f64,
    pub record_system_audio: bool,
    /// Empty means the system default input.
    pub microphone_device: String,
    pub auto_transcribe: bool,
    pub auto_summarize: bool,
    pub note_template: NoteTemplate,
    /// `match`, a language code, or `custom:<name>`.
    pub summary_language: String,
    pub multi_speaker_diarization: bool,
    pub microphone_is_user: bool,
    pub suggest_action_completion: bool,
    pub generation_budget_preset: GenerationBudget,
    pub meeting_note_export_enabled: bool,
    pub meeting_note_export_folder: String,
    pub meeting_note_export_format: ExportFormat,
    pub meeting_note_export_includes_transcript: bool,

    // Day memory
    pub tracking_enabled: bool,
    pub screen_context_capture_mode: ScreenContextMode,
    pub screenshot_interval_minutes: f64,
    pub day_digest_auto_enabled: bool,
    pub day_digest_hour: u32,
    pub day_digest_custom_prompt: String,
    pub coding_agent_evidence_enabled: bool,
    pub coding_agent_reads_claude_code: bool,
    pub coding_agent_reads_codex: bool,

    // Privacy
    pub excluded_apps: String,
    pub excluded_screen_domains: String,
    pub retention_days: u32,
    #[serde(rename = "keepOCRTextForever")]
    pub keep_ocr_text_forever: bool,
    pub approved_remote_inference_origins: Vec<String>,
    pub approved_remote_transcription_origins: Vec<String>,
    pub approved_remote_autocomplete_origins: Vec<String>,

    // Models
    pub transcription_model: String,
    pub transcription_language: String,
    pub transcription_prompt: String,
    pub auto_transcription_vocabulary: bool,
    pub summarizer_backend: SummarizerBackend,
    #[serde(rename = "builtInModelID")]
    pub built_in_model_id: String,
    #[serde(rename = "ollamaBaseURL")]
    pub ollama_base_url: String,
    pub ollama_model: String,
    #[serde(rename = "openAIBaseURL")]
    pub openai_base_url: String,
    #[serde(rename = "openAIModel")]
    pub openai_model: String,
    /// OpenRouter's per-request provider policy for Think and Autocomplete.
    /// Private routing stays the default; following the account's policy is
    /// an explicit opt-in (`openRouterDataPolicy`).
    pub open_router_data_policy: OpenRouterDataPolicy,
    /// Model slug for the ChatGPT plan, from the signed-in account's list.
    #[serde(rename = "chatGPTPlanModel")]
    pub chatgpt_plan_model: String,
    /// Model for the Claude plan: an alias Claude Code accepts ("sonnet") or a
    /// full model id. Empty uses Claude Code's own default.
    pub claude_plan_model: String,
    /// The one-time "You're using your ChatGPT plan" notice was dismissed.
    #[serde(rename = "chatGPTPlanNoticeAcknowledged")]
    pub chatgpt_plan_notice_acknowledged: bool,
    pub think_reasoning_level: ReasoningLevel,
    /// Agent Mode's own reasoning level, chosen in the Agent composer; `None`
    /// follows Think (`agentReasoningLevel`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_reasoning_level: Option<ReasoningLevel>,
    pub semantic_search_enabled: bool,
    /// llama.cpp build for the built-in runtime: `auto`, `cuda`, `vulkan` or `cpu`.
    /// CUDA is opt-in while native NVIDIA validation is pending.
    pub llama_backend: String,

    // Dictation
    pub dictation_enabled: bool,
    pub dictation_intent: DictationIntent,
    pub dictation_trigger_mode: DictationTriggerMode,
    pub dictation_shortcut: String,
    pub dictation_output_mode: DictationOutputMode,
    pub dictation_show_overlay: bool,
    pub dictation_plays_start_sound: bool,
    #[serde(rename = "dictationMicrophoneID")]
    pub dictation_microphone_id: String,
    pub dictation_retain_audio: bool,

    // Writing (autocomplete)
    pub cotyping_enabled: bool,
    pub cotyping_user_name: String,
    pub cotyping_style_note: String,
    pub cotyping_max_words: u32,
    pub cotyping_debounce_ms: u32,
    pub cotyping_multi_line: bool,
    pub cotyping_accept_granularity: AcceptGranularity,
    #[serde(rename = "cotypingBuiltInModelID")]
    pub cotyping_built_in_model_id: String,
    pub cotyping_excluded_apps: String,
    /// Sites where autocomplete never runs: a host (subdomains included) or a
    /// full URL, comma-separated (`cotypingExcludedDomains`).
    pub cotyping_excluded_domains: String,
    /// Use the text shown just above the field, such as the conversation
    /// being answered (`cotypingUseVisibleContext`, on as on macOS).
    pub cotyping_use_visible_context: bool,
    /// Let suggestions use relevant facts from saved meetings. A grant of
    /// its own, off by default, as on macOS.
    pub cotyping_use_meeting_memory: bool,

    // Calendar (macOS `AppSettings` keys). Feed links are secrets and live in
    // the system credential store, never here.
    /// Read the user's calendars to confirm meetings and title recordings.
    /// Off by default: calendar contents are sensitive.
    pub calendar_detection_enabled: bool,
    /// Prefer the matched event's title over the app-derived name.
    pub use_calendar_titles: bool,
    /// Only auto-record a browser call backed by an active calendar event
    /// with a meeting link.
    pub require_calendar_for_browser: bool,
    /// Read the invitation agenda (notes without joining details) and save
    /// it with calendar-matched recordings. Off by default.
    pub use_calendar_agenda: bool,
    /// Meeting notes may use the calendar title and invited names as
    /// secondary context.
    pub meeting_notes_use_calendar_context: bool,
    /// Linux: also read calendars from Evolution Data Server, which includes
    /// GNOME Online Accounts. Local; makes no network request of its own.
    pub calendar_evolution_enabled: bool,
    /// The user's own addresses, comma-separated, so feeds can tell the user
    /// from other attendees and skip invitations the user declined.
    pub calendar_my_email_addresses: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            launch_at_login: false,
            run_in_tray: true,
            app_theme: AppTheme::System,
            app_language: "system".into(),
            text_size: TextSize::Standard,
            quick_recall_enabled: false,
            quick_recall_shortcut: "Ctrl+Shift+Space".into(),
            check_for_updates: true,
            onboarding_completed: false,
            getting_started_dismissed: false,

            auto_record_mode: AutoRecordMode::Ask,
            stop_debounce_seconds: 15.0,
            record_system_audio: true,
            microphone_device: String::new(),
            auto_transcribe: true,
            auto_summarize: true,
            note_template: NoteTemplate::Meeting,
            summary_language: "match".into(),
            multi_speaker_diarization: true,
            microphone_is_user: true,
            suggest_action_completion: true,
            generation_budget_preset: GenerationBudget::Standard,
            meeting_note_export_enabled: false,
            meeting_note_export_folder: String::new(),
            meeting_note_export_format: ExportFormat::Markdown,
            meeting_note_export_includes_transcript: true,

            tracking_enabled: true,
            screen_context_capture_mode: ScreenContextMode::ActivityOnly,
            screenshot_interval_minutes: 3.0,
            day_digest_auto_enabled: true,
            day_digest_hour: 18,
            day_digest_custom_prompt: String::new(),
            coding_agent_evidence_enabled: true,
            coding_agent_reads_claude_code: true,
            coding_agent_reads_codex: true,

            excluded_apps: "1Password, Bitwarden, KeePassXC, KeePass".into(),
            excluded_screen_domains: String::new(),
            retention_days: 14,
            keep_ocr_text_forever: false,
            approved_remote_inference_origins: Vec::new(),
            approved_remote_transcription_origins: Vec::new(),
            approved_remote_autocomplete_origins: Vec::new(),

            transcription_model: "qwen3-asr-0.6b".into(),
            transcription_language: "auto".into(),
            transcription_prompt: String::new(),
            auto_transcription_vocabulary: true,
            summarizer_backend: SummarizerBackend::BuiltIn,
            built_in_model_id: "qwen3.5-4b".into(),
            ollama_base_url: "http://localhost:11434".into(),
            ollama_model: String::new(),
            openai_base_url: "http://localhost:1234/v1".into(),
            openai_model: String::new(),
            open_router_data_policy: OpenRouterDataPolicy::PrivateOnly,
            chatgpt_plan_model: String::new(),
            claude_plan_model: String::new(),
            chatgpt_plan_notice_acknowledged: false,
            think_reasoning_level: ReasoningLevel::Automatic,
            agent_reasoning_level: None,
            semantic_search_enabled: true,
            llama_backend: "auto".into(),

            dictation_enabled: false,
            dictation_intent: DictationIntent::Transcribe,
            dictation_trigger_mode: DictationTriggerMode::PushToTalk,
            dictation_shortcut: "Alt+Space".into(),
            dictation_output_mode: DictationOutputMode::Paste,
            dictation_show_overlay: true,
            dictation_plays_start_sound: true,
            dictation_microphone_id: String::new(),
            dictation_retain_audio: false,

            cotyping_enabled: false,
            cotyping_user_name: String::new(),
            cotyping_style_note: String::new(),
            cotyping_max_words: 4,
            cotyping_debounce_ms: 160,
            cotyping_multi_line: false,
            cotyping_accept_granularity: AcceptGranularity::Word,
            cotyping_built_in_model_id: "lfm2.5-1.2b-instruct".into(),
            cotyping_excluded_apps: "1Password, Bitwarden, KeePassXC, KeePass".into(),
            cotyping_excluded_domains: String::new(),
            cotyping_use_visible_context: true,
            cotyping_use_meeting_memory: false,

            calendar_detection_enabled: false,
            use_calendar_titles: true,
            require_calendar_for_browser: false,
            use_calendar_agenda: false,
            meeting_notes_use_calendar_context: true,
            calendar_evolution_enabled: true,
            calendar_my_email_addresses: String::new(),
        }
    }
}

impl Settings {
    /// Loads settings, falling back to defaults for anything missing or unreadable.
    /// A field with the wrong type falls back on its own; the rest still load.
    pub fn load(path: &Path) -> Self {
        let Ok(bytes) = std::fs::read(path) else {
            return Self::default();
        };
        match serde_json::from_slice::<Settings>(&bytes) {
            Ok(settings) => settings,
            Err(_) => Self::load_field_by_field(&bytes),
        }
    }

    fn load_field_by_field(bytes: &[u8]) -> Self {
        let Ok(serde_json::Value::Object(stored)) =
            serde_json::from_slice::<serde_json::Value>(bytes)
        else {
            return Self::default();
        };
        let serde_json::Value::Object(mut merged) =
            serde_json::to_value(Self::default()).expect("settings serialize")
        else {
            return Self::default();
        };
        for (key, value) in stored {
            if !merged.contains_key(&key) {
                continue;
            }
            let mut candidate = merged.clone();
            candidate.insert(key.clone(), value.clone());
            if serde_json::from_value::<Settings>(serde_json::Value::Object(candidate)).is_ok() {
                merged.insert(key, value);
            } else {
                log::warn!("settings.json: ignoring unreadable value for {key}");
            }
        }
        serde_json::from_value(serde_json::Value::Object(merged)).unwrap_or_default()
    }

    /// Writes atomically (temp file + rename), pretty-printed.
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        let json = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        crate::library::write_atomic(path, &json)
    }

    /// The level Agent Mode uses: its own choice, else Think's.
    pub fn effective_agent_reasoning_level(&self) -> ReasoningLevel {
        self.agent_reasoning_level
            .unwrap_or(self.think_reasoning_level)
    }

    /// Whether the selected Think backend runs on this machine without approval.
    pub fn think_is_local(&self) -> bool {
        match self.summarizer_backend {
            SummarizerBackend::BuiltIn => true,
            SummarizerBackend::Ollama => crate::access::is_loopback_url(&self.ollama_base_url),
            SummarizerBackend::OpenAICompatible => {
                crate::access::is_loopback_url(&self.openai_base_url)
            }
            SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => false,
        }
    }

    /// The subscription plan Think runs on, if any.
    pub fn think_plan(&self) -> Option<SubscriptionPlan> {
        SubscriptionPlan::for_backend(self.summarizer_backend)
    }

    pub fn excluded_app_list(&self) -> Vec<String> {
        split_list(&self.excluded_apps)
    }

    pub fn excluded_domain_list(&self) -> Vec<String> {
        split_list(&self.excluded_screen_domains)
    }

    pub fn cotyping_excluded_app_list(&self) -> Vec<String> {
        split_list(&self.cotyping_excluded_apps)
    }

    pub fn cotyping_excluded_domain_list(&self) -> Vec<String> {
        split_list(&self.cotyping_excluded_domains)
    }
}

pub fn split_list(raw: &str) -> Vec<String> {
    raw.split([',', '\n'])
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AppTheme {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TextSize {
    Small,
    #[default]
    Standard,
    Large,
    Larger,
    Largest,
}

impl TextSize {
    /// Multiplier on the base type scale (Small 1.0 … Largest 1.45).
    pub fn scale(self) -> f32 {
        match self {
            TextSize::Small => 0.93,
            TextSize::Standard => 1.0,
            TextSize::Large => 1.1,
            TextSize::Larger => 1.2,
            TextSize::Largest => 1.35,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum AutoRecordMode {
    #[serde(rename = "Record automatically")]
    Automatic,
    #[default]
    #[serde(rename = "Ask via notification")]
    Ask,
    #[serde(rename = "Never auto-record")]
    Manual,
}

impl AutoRecordMode {
    pub const ALL: [AutoRecordMode; 3] = [Self::Automatic, Self::Ask, Self::Manual];

    pub fn label(self) -> &'static str {
        match self {
            Self::Automatic => "Record automatically",
            Self::Ask => "Ask via notification",
            Self::Manual => "Never auto-record",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NoteTemplate {
    #[default]
    Meeting,
    Lecture,
    StudyGuide,
    Podcast,
    Freeform,
}

impl NoteTemplate {
    pub const ALL: [NoteTemplate; 5] = [
        Self::Meeting,
        Self::Lecture,
        Self::StudyGuide,
        Self::Podcast,
        Self::Freeform,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::Meeting => "Meeting",
            Self::Lecture => "Lecture",
            Self::StudyGuide => "Study guide",
            Self::Podcast => "Podcast / interview",
            Self::Freeform => "Free-form",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GenerationBudget {
    Conservative,
    #[default]
    Standard,
    Generous,
    Unlimited,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExportFormat {
    #[default]
    Markdown,
    Obsidian,
    Logseq,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SummarizerBackend {
    #[default]
    #[serde(rename = "Built-in (no setup)")]
    BuiltIn,
    #[serde(rename = "Ollama")]
    Ollama,
    #[serde(rename = "OpenAI-compatible server")]
    OpenAICompatible,
    /// The user's ChatGPT plan through Sign in with ChatGPT.
    #[serde(rename = "ChatGPT plan")]
    ChatGptPlan,
    /// The user's Claude plan through their own Claude Code installation.
    #[serde(rename = "Claude plan")]
    ClaudePlan,
}

impl SummarizerBackend {
    pub const ALL: [SummarizerBackend; 5] = [
        Self::BuiltIn,
        Self::Ollama,
        Self::OpenAICompatible,
        Self::ChatGptPlan,
        Self::ClaudePlan,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::BuiltIn => "Built-in (no setup)",
            Self::Ollama => "Ollama",
            Self::OpenAICompatible => "OpenAI-compatible server",
            Self::ChatGptPlan => "ChatGPT plan",
            Self::ClaudePlan => "Claude plan",
        }
    }
}

/// Think backends that run on the user's own ChatGPT or Claude plan instead
/// of an API key (`SubscriptionPlan.swift`). Requests count toward that
/// plan's usage limits.
///
/// Each plan has its own entry in `approved_remote_inference_origins`. The
/// entries are not URL origins, so approving an API server
/// (`https://api.openai.com` with a key) never approves plan usage, and the
/// reverse: the two run under different provider terms.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SubscriptionPlan {
    ChatGpt,
    Claude,
}

impl SubscriptionPlan {
    pub const ALL: [SubscriptionPlan; 2] = [Self::ChatGpt, Self::Claude];

    pub fn for_backend(backend: SummarizerBackend) -> Option<Self> {
        match backend {
            SummarizerBackend::ChatGptPlan => Some(Self::ChatGpt),
            SummarizerBackend::ClaudePlan => Some(Self::Claude),
            SummarizerBackend::BuiltIn
            | SummarizerBackend::Ollama
            | SummarizerBackend::OpenAICompatible => None,
        }
    }

    pub fn backend(self) -> SummarizerBackend {
        match self {
            Self::ChatGpt => SummarizerBackend::ChatGptPlan,
            Self::Claude => SummarizerBackend::ClaudePlan,
        }
    }

    /// "ChatGPT plan", "Claude plan" (shared interface keys).
    pub fn title(self) -> &'static str {
        match self {
            Self::ChatGpt => "ChatGPT plan",
            Self::Claude => "Claude plan",
        }
    }

    pub fn provider_name(self) -> &'static str {
        match self {
            Self::ChatGpt => "OpenAI",
            Self::Claude => "Anthropic",
        }
    }

    /// Where Think content goes. Claude requests travel through the user's
    /// own Claude Code installation, which sends them to Anthropic.
    pub fn destination_host(self) -> &'static str {
        match self {
            Self::ChatGpt => "api.openai.com",
            Self::Claude => "api.anthropic.com",
        }
    }

    /// The approval entry, the same string the Mac stores.
    pub fn consent_key(self) -> &'static str {
        match self {
            Self::ChatGpt => "chatgpt-plan://api.openai.com",
            Self::Claude => "claude-plan://api.anthropic.com",
        }
    }

    /// The provider's own page for checking and capping plan usage.
    pub fn manage_usage_url(self) -> &'static str {
        match self {
            Self::ChatGpt => "https://chatgpt.com/settings/usage",
            Self::Claude => "https://claude.ai/settings/usage",
        }
    }

    pub fn for_consent_key(key: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|plan| plan.consent_key().eq_ignore_ascii_case(key.trim()))
    }

    pub fn is_approved(self, settings: &Settings) -> bool {
        settings
            .approved_remote_inference_origins
            .iter()
            .any(|entry| entry.eq_ignore_ascii_case(self.consent_key()))
    }

    /// Approves or revokes this plan, leaving every other entry alone.
    pub fn set_approved(self, settings: &mut Settings, approved: bool) {
        settings
            .approved_remote_inference_origins
            .retain(|entry| !entry.eq_ignore_ascii_case(self.consent_key()));
        if approved {
            settings
                .approved_remote_inference_origins
                .push(self.consent_key().to_string());
        }
    }

    pub fn model(self, settings: &Settings) -> &str {
        match self {
            Self::ChatGpt => settings.chatgpt_plan_model.trim(),
            Self::Claude => settings.claude_plan_model.trim(),
        }
    }

    /// Why Think cannot use this plan yet (`SubscriptionPlanError`).
    pub fn approval_required_message(self) -> String {
        format!(
            "Allow sending context to {} with your {} under Settings → Models → Think before Think uses it.",
            self.provider_name(),
            self.title()
        )
    }

    /// The approval list shows a plan entry by name rather than its key.
    pub fn approval_display_name(entry: &str) -> String {
        match Self::for_consent_key(entry) {
            Some(plan) => format!("{} · {}", plan.title(), plan.destination_host()),
            None => entry.to_string(),
        }
    }
}

/// OpenRouter's request-level provider preference (`OpenRouterDataPolicy`).
/// Account, API-key, workspace and guardrail filters apply after it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OpenRouterDataPolicy {
    /// Only providers that do not collect inference data.
    #[default]
    PrivateOnly,
    /// Whatever the OpenRouter account, key, workspace or guardrail allows.
    AccountPolicy,
}

impl OpenRouterDataPolicy {
    pub const ALL: [OpenRouterDataPolicy; 2] = [Self::PrivateOnly, Self::AccountPolicy];

    /// `provider.data_collection` on every OpenRouter request.
    pub fn data_collection(self) -> &'static str {
        match self {
            Self::PrivateOnly => "deny",
            Self::AccountPolicy => "allow",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::PrivateOnly => "Private endpoints only (Recommended)",
            Self::AccountPolicy => "Follow my OpenRouter privacy settings",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReasoningLevel {
    #[default]
    Automatic,
    Off,
    Minimal,
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

impl ReasoningLevel {
    /// Thinking budget in tokens; `None` lets the task decide.
    pub fn budget_tokens(self) -> Option<u32> {
        match self {
            Self::Automatic => None,
            Self::Off => Some(0),
            Self::Minimal => Some(256),
            Self::Low => Some(512),
            Self::Medium => Some(4096),
            Self::High => Some(8192),
            Self::Xhigh => Some(16_384),
            Self::Max => Some(24_576),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum DictationIntent {
    #[default]
    Transcribe,
    Compose,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum DictationTriggerMode {
    #[default]
    #[serde(rename = "Push to talk")]
    PushToTalk,
    Toggle,
    #[serde(rename = "Tap or hold")]
    TapOrHold,
}

impl DictationTriggerMode {
    pub const ALL: [DictationTriggerMode; 3] = [Self::PushToTalk, Self::Toggle, Self::TapOrHold];

    pub fn label(self) -> &'static str {
        match self {
            Self::PushToTalk => "Push to talk",
            Self::Toggle => "Toggle",
            Self::TapOrHold => "Tap or hold",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum DictationOutputMode {
    #[default]
    #[serde(rename = "Paste into focused app")]
    Paste,
    #[serde(rename = "Copy to clipboard")]
    Clipboard,
    #[serde(rename = "Show in LokalBot")]
    ShowInApp,
}

impl DictationOutputMode {
    pub const ALL: [DictationOutputMode; 3] = [Self::Paste, Self::Clipboard, Self::ShowInApp];

    pub fn label(self) -> &'static str {
        match self {
            Self::Paste => "Paste into focused app",
            Self::Clipboard => "Copy to clipboard",
            Self::ShowInApp => "Show in LokalBot",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AcceptGranularity {
    #[default]
    Word,
    Phrase,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_round_trip() {
        let json = serde_json::to_string(&Settings::default()).unwrap();
        let back: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(back, Settings::default());
        assert!(json.contains("\"autoRecordMode\":\"Ask via notification\""));
        assert!(json.contains("\"builtInModelID\":\"qwen3.5-4b\""));
    }

    #[test]
    fn provider_choices_round_trip_with_the_mac_keys() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        // As the Mac writes them, beside keys this port does not know.
        std::fs::write(
            &path,
            r#"{"summarizerBackend":"Claude plan","claudePlanModel":"sonnet","chatGPTPlanModel":"gpt-5.5","chatGPTPlanNoticeAcknowledged":true,"openRouterDataPolicy":"accountPolicy","approvedRemoteInferenceOrigins":["claude-plan://api.anthropic.com","https://openrouter.ai"],"diarizationModel":"nemotron3"}"#,
        )
        .unwrap();
        let settings = Settings::load(&path);
        assert_eq!(settings.summarizer_backend, SummarizerBackend::ClaudePlan);
        assert_eq!(settings.claude_plan_model, "sonnet");
        assert_eq!(settings.chatgpt_plan_model, "gpt-5.5");
        assert!(settings.chatgpt_plan_notice_acknowledged);
        assert_eq!(
            settings.open_router_data_policy,
            OpenRouterDataPolicy::AccountPolicy
        );
        assert_eq!(settings.think_plan(), Some(SubscriptionPlan::Claude));
        assert!(!settings.think_is_local());
        assert!(SubscriptionPlan::Claude.is_approved(&settings));
        assert!(!SubscriptionPlan::ChatGpt.is_approved(&settings));
        settings.save(&path).unwrap();
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(saved["summarizerBackend"], "Claude plan");
        assert_eq!(saved["claudePlanModel"], "sonnet");
        assert_eq!(saved["chatGPTPlanModel"], "gpt-5.5");
        assert_eq!(saved["chatGPTPlanNoticeAcknowledged"], true);
        assert_eq!(saved["openRouterDataPolicy"], "accountPolicy");

        // New installs and libraries written before these settings.
        let fresh = serde_json::to_value(Settings::default()).unwrap();
        assert_eq!(fresh["openRouterDataPolicy"], "privateOnly");
        assert_eq!(
            Settings::default()
                .open_router_data_policy
                .data_collection(),
            "deny"
        );
        std::fs::write(&path, r#"{"summarizerBackend":"ChatGPT plan"}"#).unwrap();
        let older = Settings::load(&path);
        assert_eq!(older.summarizer_backend, SummarizerBackend::ChatGptPlan);
        assert_eq!(
            older.open_router_data_policy,
            OpenRouterDataPolicy::PrivateOnly
        );
        std::fs::write(&path, r#"{"openRouterDataPolicy":"sometimes"}"#).unwrap();
        assert_eq!(
            Settings::load(&path).open_router_data_policy,
            OpenRouterDataPolicy::PrivateOnly
        );
    }

    #[test]
    fn plan_approval_is_its_own_entry() {
        let mut settings = Settings {
            approved_remote_inference_origins: vec!["https://api.openai.com".into()],
            ..Settings::default()
        };
        // An API-server approval for the same company never covers a plan.
        assert!(!SubscriptionPlan::ChatGpt.is_approved(&settings));
        SubscriptionPlan::ChatGpt.set_approved(&mut settings, true);
        SubscriptionPlan::ChatGpt.set_approved(&mut settings, true);
        assert_eq!(
            settings.approved_remote_inference_origins,
            vec![
                "https://api.openai.com".to_string(),
                "chatgpt-plan://api.openai.com".to_string()
            ]
        );
        assert!(
            crate::access::remote_block_reason(
                "https://api.openai.com/v1",
                &["chatgpt-plan://api.openai.com".to_string()]
            )
            .is_some()
        );
        assert_eq!(
            SubscriptionPlan::approval_display_name("chatgpt-plan://api.openai.com"),
            "ChatGPT plan · api.openai.com"
        );
        assert_eq!(
            SubscriptionPlan::approval_display_name("https://openrouter.ai"),
            "https://openrouter.ai"
        );
        SubscriptionPlan::ChatGpt.set_approved(&mut settings, false);
        assert_eq!(
            settings.approved_remote_inference_origins,
            vec!["https://api.openai.com".to_string()]
        );
        for plan in SubscriptionPlan::ALL {
            assert_eq!(SubscriptionPlan::for_backend(plan.backend()), Some(plan));
            assert_eq!(
                SubscriptionPlan::for_consent_key(plan.consent_key()),
                Some(plan)
            );
        }
    }

    #[test]
    fn a_bad_field_does_not_reset_the_rest() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"retentionDays": "fourteen", "trackingEnabled": false, "dayDigestHour": 9}"#,
        )
        .unwrap();
        let settings = Settings::load(&path);
        assert_eq!(settings.retention_days, 14);
        assert!(!settings.tracking_enabled);
        assert_eq!(settings.day_digest_hour, 9);
    }

    #[test]
    fn interface_language_survives_an_existing_library_upgrade() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        // The same preference key is used by the macOS app. Changing the
        // interface must not change the language of generated meeting notes,
        // shortcuts or any capture/consent choice.
        std::fs::write(&path, r#"{"appLanguage":"sr-Latn","summaryLanguage":"de","trackingEnabled":false,"recordSystemAudio":false,"quickRecallShortcut":"Ctrl+Shift+Space"}"#).unwrap();
        let settings = Settings::load(&path);
        settings.save(&path).unwrap();
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(saved["appLanguage"], "sr-Latn");
        assert_eq!(saved["summaryLanguage"], "de");
        assert_eq!(saved["trackingEnabled"], false);
        assert_eq!(saved["recordSystemAudio"], false);
        assert_eq!(saved["quickRecallShortcut"], "Ctrl+Shift+Space");

        std::fs::write(&path, r#"{"summaryLanguage":"ja","trackingEnabled":false}"#).unwrap();
        let older = Settings::load(&path);
        let upgraded = serde_json::to_value(&older).unwrap();
        assert_eq!(upgraded["appLanguage"], "system");
        assert_eq!(upgraded["summaryLanguage"], "ja");
        assert_eq!(upgraded["trackingEnabled"], false);
        assert_eq!(
            Settings::load(&path),
            older,
            "loading does not rewrite an older library"
        );
    }
}
