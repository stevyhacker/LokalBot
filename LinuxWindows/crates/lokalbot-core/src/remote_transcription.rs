use crate::access::{is_loopback_url, is_private_network_url, origin_of};
use crate::settings::Settings;

pub const MODEL_ID: &str = "remote-server";

const WORD_TIMING_MODELS: &[(&str, &[&str])] = &[(
    "https://openrouter.ai",
    &[
        "microsoft/mai-transcribe-2",
        "google/gemini-3.5-transcribe",
        "openai/whisper-large-v3-turbo",
    ],
)];

#[derive(Clone, Debug, PartialEq)]
pub struct TimedWord {
    pub text: String,
    pub start: f64,
    pub end: f64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct WindowTranscription {
    pub text: String,
    pub words: Vec<TimedWord>,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum RemoteTranscriptionError {
    #[error("Enter a transcription server URL under Settings → Models → Transcribe.")]
    NotConfigured,
    #[error("Use an http or https transcription server URL without a query or a user name.")]
    InvalidUrl,
    #[error(
        "Transcription server {0} is not encrypted. Use HTTPS, or a server on this PC, your local network, or your tailnet."
    )]
    Insecure(String),
    #[error(
        "Allow sending audio to {0} under Settings → Models → Transcribe before transcribing with it."
    )]
    ApprovalRequired(String),
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RemoteTranscription {
    pub base_url: String,
    pub model: String,
    pub approved_origins: Vec<String>,
}

impl RemoteTranscription {
    pub fn from_settings(settings: &Settings) -> Self {
        Self {
            base_url: settings.remote_transcription_base_url.clone(),
            model: settings.remote_transcription_model.clone(),
            approved_origins: settings.approved_remote_transcription_origins.clone(),
        }
    }

    pub fn trimmed_model(&self) -> &str {
        self.model.trim()
    }

    pub fn requests_word_timings(&self) -> bool {
        let model = self.trimmed_model().to_lowercase();
        self.origin().is_some_and(|origin| {
            WORD_TIMING_MODELS
                .iter()
                .any(|(known, models)| *known == origin && models.contains(&model.as_str()))
        })
    }

    pub fn word_timing_key(&self) -> String {
        format!(
            "{}|{}",
            self.origin().unwrap_or_else(|| self.base_url.clone()),
            self.trimmed_model().to_lowercase()
        )
    }

    pub fn is_configured(&self) -> bool {
        !self.base_url.trim().is_empty()
    }

    pub fn endpoint(&self) -> Option<String> {
        let raw = self.base_url.trim();
        let origin = origin_of(raw)?;
        if !(origin.starts_with("http://") || origin.starts_with("https://"))
            || raw.contains(['?', '#'])
        {
            return None;
        }
        let (_, rest) = raw.split_once("://")?;
        let path = rest.split_once('/').map_or("", |(_, path)| path);
        let path = path.trim_end_matches('/');
        let mut url = if path.is_empty() {
            origin
        } else {
            format!("{origin}/{path}")
        };
        if !url.ends_with("/audio/transcriptions") && !url.ends_with("/inference") {
            url.push_str("/audio/transcriptions");
        }
        Some(url)
    }

    pub fn origin(&self) -> Option<String> {
        self.endpoint().as_deref().and_then(origin_of)
    }

    pub fn validated_endpoint(&self) -> Result<String, RemoteTranscriptionError> {
        if !self.is_configured() {
            return Err(RemoteTranscriptionError::NotConfigured);
        }
        let endpoint = self
            .endpoint()
            .ok_or(RemoteTranscriptionError::InvalidUrl)?;
        if is_loopback_url(&endpoint) {
            return Ok(endpoint);
        }
        let origin = origin_of(&endpoint).ok_or(RemoteTranscriptionError::InvalidUrl)?;
        if !origin.starts_with("https://") && !is_private_network_url(&endpoint) {
            return Err(RemoteTranscriptionError::Insecure(origin));
        }
        if self
            .approved_origins
            .iter()
            .any(|approved| approved.eq_ignore_ascii_case(&origin))
        {
            Ok(endpoint)
        } else {
            Err(RemoteTranscriptionError::ApprovalRequired(origin))
        }
    }

    pub fn is_ready(&self) -> bool {
        self.validated_endpoint().is_ok()
    }

    pub fn is_on_this_computer(&self) -> bool {
        self.endpoint().as_deref().is_some_and(is_loopback_url)
    }

    pub fn display_name(&self) -> String {
        let host = self
            .origin()
            .and_then(|origin| origin.split_once("://").map(|(_, host)| host.to_string()))
            .unwrap_or_else(|| "not set up".to_string());
        if self.trimmed_model().is_empty() {
            format!("Transcription server · {host}")
        } else {
            format!("{} · {host}", self.trimmed_model())
        }
    }

    pub fn transcript_engine(&self) -> String {
        let model = if self.trimmed_model().is_empty() {
            "server default"
        } else {
            self.trimmed_model()
        };
        let origin = self.origin().unwrap_or_else(|| "server".to_string());
        format!("{model} (remote {origin})")
    }
}

pub fn audio_destination(settings: &Settings) -> Option<String> {
    if settings.transcription_model != MODEL_ID {
        return None;
    }
    let server = RemoteTranscription::from_settings(settings);
    if !server.is_ready() || server.is_on_this_computer() {
        return None;
    }
    let origin = server.origin()?;
    origin.split_once("://").map(|(_, host)| host.to_string())
}

pub fn request_key(
    transcription_base_url: &str,
    think_base_url: &str,
    own_key: &str,
    think_key: impl FnOnce() -> String,
) -> String {
    if !own_key.is_empty() {
        return own_key.to_string();
    }
    if uses_think_key(transcription_base_url, think_base_url) {
        think_key()
    } else {
        String::new()
    }
}

pub fn uses_think_key(transcription_base_url: &str, think_base_url: &str) -> bool {
    let transcription = RemoteTranscription {
        base_url: transcription_base_url.to_string(),
        ..Default::default()
    }
    .origin();
    transcription.is_some() && transcription == origin_of(think_base_url.trim())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_models_checked_to_time_words_are_asked_for_them() {
        let server = |base: &str, model: &str| RemoteTranscription {
            base_url: base.to_string(),
            model: model.to_string(),
            approved_origins: Vec::new(),
        };
        let openrouter = "https://openrouter.ai/api/v1";
        for model in [
            "microsoft/mai-transcribe-2",
            "Google/Gemini-3.5-Transcribe ",
            "openai/whisper-large-v3-turbo",
        ] {
            assert!(server(openrouter, model).requests_word_timings(), "{model}");
        }
        assert!(!server(openrouter, "openai/whisper-large-v3").requests_word_timings());
        assert!(
            !server("https://api.openai.com/v1", "openai/whisper-large-v3-turbo")
                .requests_word_timings()
        );
        assert!(!server("", "microsoft/mai-transcribe-2").requests_word_timings());
        assert_eq!(
            server(openrouter, " Model ").word_timing_key(),
            "https://openrouter.ai|model"
        );
    }

    fn server(url: &str, approved: &[&str]) -> RemoteTranscription {
        RemoteTranscription {
            base_url: url.to_string(),
            model: "whisper-1".to_string(),
            approved_origins: approved.iter().map(|o| o.to_string()).collect(),
        }
    }

    #[test]
    fn endpoints_follow_the_openai_shape() {
        for (raw, endpoint) in [
            (
                "https://api.openai.com/v1",
                "https://api.openai.com/v1/audio/transcriptions",
            ),
            (
                " https://api.openai.com/v1/// ",
                "https://api.openai.com/v1/audio/transcriptions",
            ),
            (
                "https://x.example/v1/audio/transcriptions/",
                "https://x.example/v1/audio/transcriptions",
            ),
            (
                "http://192.168.1.5:8080/inference",
                "http://192.168.1.5:8080/inference",
            ),
            (
                "http://localhost:9000",
                "http://localhost:9000/audio/transcriptions",
            ),
        ] {
            assert_eq!(
                server(raw, &[]).endpoint().as_deref(),
                Some(endpoint),
                "{raw}"
            );
        }
        for raw in [
            "https://x.example/v1?key=1",
            "https://x.example/v1#a",
            "https://user:pw@x.example/v1",
            "ftp://x.example/v1",
            "not a url",
        ] {
            assert_eq!(server(raw, &[]).endpoint(), None, "{raw}");
        }
    }

    #[test]
    fn audio_needs_its_own_approval() {
        assert_eq!(
            server(" ", &[]).validated_endpoint(),
            Err(RemoteTranscriptionError::NotConfigured)
        );
        assert_eq!(
            server("https://x.example/v1?a", &[]).validated_endpoint(),
            Err(RemoteTranscriptionError::InvalidUrl)
        );
        assert!(server("http://127.0.0.1:9000/v1", &[]).is_ready());
        assert!(server("http://127.0.0.1:9000/v1", &[]).is_on_this_computer());
        assert_eq!(
            server("http://x.example/v1", &["http://x.example"]).validated_endpoint(),
            Err(RemoteTranscriptionError::Insecure(
                "http://x.example".into()
            ))
        );
        assert_eq!(
            server("https://x.example/v1", &["https://y.example"]).validated_endpoint(),
            Err(RemoteTranscriptionError::ApprovalRequired(
                "https://x.example".into()
            ))
        );
        assert!(server("https://x.example/v1", &["https://x.example"]).is_ready());
        assert!(!server("https://x.example/v1", &["https://x.example"]).is_on_this_computer());
        assert_eq!(
            server("http://192.168.1.5:8080/inference", &[]).validated_endpoint(),
            Err(RemoteTranscriptionError::ApprovalRequired(
                "http://192.168.1.5:8080".into()
            ))
        );
        assert!(
            server(
                "http://192.168.1.5:8080/inference",
                &["http://192.168.1.5:8080"]
            )
            .is_ready()
        );
        assert!(server("http://gpu.ts.net/v1", &["http://gpu.ts.net"]).is_ready());
    }

    #[test]
    fn think_approvals_do_not_send_audio() {
        let settings = Settings {
            remote_transcription_base_url: "https://x.example/v1".into(),
            approved_remote_inference_origins: vec!["https://x.example".into()],
            ..Default::default()
        };
        assert!(!RemoteTranscription::from_settings(&settings).is_ready());
    }

    #[test]
    fn only_an_approved_remote_server_is_a_destination() {
        let mut settings = Settings {
            remote_transcription_base_url: "https://x.example/v1".into(),
            approved_remote_transcription_origins: vec!["https://x.example".into()],
            ..Default::default()
        };
        assert_eq!(audio_destination(&settings), None);
        settings.transcription_model = MODEL_ID.into();
        assert_eq!(audio_destination(&settings).as_deref(), Some("x.example"));
        settings.approved_remote_transcription_origins.clear();
        assert_eq!(audio_destination(&settings), None);
        settings.remote_transcription_base_url = "http://127.0.0.1:9000/v1".into();
        assert_eq!(audio_destination(&settings), None);
    }

    #[test]
    fn names_never_hold_credentials() {
        let named = server("https://api.openai.com/v1", &[]);
        assert_eq!(named.display_name(), "whisper-1 · api.openai.com");
        assert_eq!(
            named.transcript_engine(),
            "whisper-1 (remote https://api.openai.com)"
        );
        let unnamed = RemoteTranscription {
            base_url: "https://user:secret@x.example/v1".into(),
            ..Default::default()
        };
        assert_eq!(unnamed.display_name(), "Transcription server · not set up");
        assert_eq!(
            unnamed.transcript_engine(),
            "server default (remote server)"
        );
    }

    #[test]
    fn the_think_key_only_goes_to_think_s_own_origin() {
        let think = "https://openrouter.ai/api/v1";
        assert_eq!(
            request_key("https://x.example/v1", think, "own", || "think".into()),
            "own"
        );
        assert_eq!(
            request_key("https://openrouter.ai/api/v1", think, "", || "think".into()),
            "think"
        );
        assert_eq!(
            request_key("https://x.example/v1", think, "", || "think".into()),
            ""
        );
    }
}
