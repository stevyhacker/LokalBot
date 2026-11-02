//! Which languages each transcription model can be told to use
//! (`TranscriptionLanguage.swift`, `TranscriptionLanguageSupport.swift`).
//! Coverage comes from the pinned models and their publishers' cards; a shared
//! language picker is not evidence of model support.

use lokalbot_core::remote_transcription::MODEL_ID as REMOTE_MODEL_ID;

use crate::models::{self, Family};

/// `auto` plus `LanguageCode.transcriptionSupported`, with the Mac's names.
pub const TRANSCRIPTION_LANGUAGES: [(&str, &str); 24] = [
    ("auto", "Auto-detect"),
    ("en", "English"),
    ("de", "German"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("it", "Italian"),
    ("nl", "Dutch"),
    ("pt", "Portuguese"),
    ("pl", "Polish"),
    ("sv", "Swedish"),
    ("da", "Danish"),
    ("no", "Norwegian"),
    ("tr", "Turkish"),
    ("ru", "Russian"),
    ("uk", "Ukrainian"),
    ("sr", "Serbian"),
    ("zh", "Chinese (Mandarin)"),
    ("yue", "Chinese (Cantonese)"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("ar", "Arabic"),
    ("hi", "Hindi"),
    ("th", "Thai"),
    ("vi", "Vietnamese"),
];

/// The picker's name for a stored code.
pub fn language_name(code: &str) -> &'static str {
    TRANSCRIPTION_LANGUAGES
        .iter()
        .find(|(known, _)| *known == code)
        .map_or(TRANSCRIPTION_LANGUAGES[0].1, |(_, name)| name)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UkrainianSupport {
    LanguageToken,
    /// Parakeet v3 has Ukrainian but detects the language itself.
    Detected,
    ServerDependent,
    Unsupported,
}

impl UkrainianSupport {
    pub fn for_model(model_id: &str) -> Self {
        if model_id == REMOTE_MODEL_ID {
            return Self::ServerDependent;
        }
        match models::find(model_id).and_then(|model| model.family()) {
            Some(Family::Whisper) => Self::LanguageToken,
            Some(Family::NemoTransducer)
                if models::find(model_id).is_some_and(|m| m.supports_language("uk")) =>
            {
                Self::Detected
            }
            _ => Self::Unsupported,
        }
    }

    pub fn is_available(self) -> bool {
        self != Self::Unsupported
    }

    pub fn explanation(self) -> Option<&'static str> {
        match self {
            Self::LanguageToken => None,
            Self::Detected => Some(
                "Parakeet detects the language itself and cannot be told to use Ukrainian. Choose Whisper to explicitly select Ukrainian.",
            ),
            Self::ServerDependent => Some(
                "Ukrainian is sent as the language hint. Support depends on your transcription server's model.",
            ),
            Self::Unsupported => Some(
                "This model does not support Ukrainian. Choose Whisper or multilingual Parakeet, or select another language.",
            ),
        }
    }
}

pub fn is_language_selectable(model_id: &str, code: &str) -> bool {
    code != "uk" || UkrainianSupport::for_model(model_id).is_available()
}

/// What the picker explains under the chosen language.
pub fn language_selection_message(model_id: &str, code: &str) -> Option<&'static str> {
    let support = UkrainianSupport::for_model(model_id);
    if code == "uk" || support == UkrainianSupport::Unsupported {
        support.explanation()
    } else {
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error(
    "{model} does not support {language}. Choose Whisper or multilingual Parakeet, or select another language."
)]
pub struct UnsupportedTranscriptionLanguage {
    pub language: String,
    pub model: String,
}

/// Checked before reading audio or falling back to detection: a saved Ukrainian
/// choice survives model switches, but a model without it must not silently
/// transcribe in another language.
pub fn validate_language(
    model_id: &str,
    display_name: &str,
    code: Option<&str>,
) -> Result<(), UnsupportedTranscriptionLanguage> {
    let is_ukrainian = code.is_some_and(|code| code.trim().eq_ignore_ascii_case("uk"));
    if is_ukrainian && !UkrainianSupport::for_model(model_id).is_available() {
        return Err(UnsupportedTranscriptionLanguage {
            language: "Ukrainian".to_string(),
            model: display_name.to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ukrainian_follows_the_model() {
        assert_eq!(
            UkrainianSupport::for_model("whisper-large-v3-turbo"),
            UkrainianSupport::LanguageToken
        );
        assert_eq!(
            UkrainianSupport::for_model("parakeet-v3"),
            UkrainianSupport::Detected
        );
        assert_eq!(
            UkrainianSupport::for_model(REMOTE_MODEL_ID),
            UkrainianSupport::ServerDependent
        );
        for model in ["qwen3-asr-0.6b", "sense-voice", "unknown"] {
            assert_eq!(
                UkrainianSupport::for_model(model),
                UkrainianSupport::Unsupported,
                "{model}"
            );
        }
    }

    #[test]
    fn the_picker_disables_and_explains() {
        assert!(!is_language_selectable("qwen3-asr-0.6b", "uk"));
        assert!(is_language_selectable("qwen3-asr-0.6b", "de"));
        assert!(is_language_selectable("whisper-large-v3-turbo", "uk"));
        assert_eq!(
            language_selection_message("whisper-large-v3-turbo", "uk"),
            None
        );
        assert_eq!(language_selection_message("parakeet-v3", "de"), None);
        assert!(language_selection_message("parakeet-v3", "uk").is_some());
        // A model without Ukrainian says so whichever language is chosen.
        assert!(language_selection_message("sense-voice", "en").is_some());
    }

    #[test]
    fn an_unsupported_language_is_refused_before_transcribing() {
        assert_eq!(
            validate_language("qwen3-asr-0.6b", "Qwen3-ASR 0.6B", Some(" UK "))
                .unwrap_err()
                .to_string(),
            "Qwen3-ASR 0.6B does not support Ukrainian. Choose Whisper or multilingual Parakeet, or select another language."
        );
        assert!(validate_language("qwen3-asr-0.6b", "Qwen3-ASR 0.6B", Some("de")).is_ok());
        assert!(validate_language("qwen3-asr-0.6b", "Qwen3-ASR 0.6B", None).is_ok());
        assert!(validate_language("whisper-large-v3-turbo", "Whisper", Some("uk")).is_ok());
        assert!(validate_language(REMOTE_MODEL_ID, "Server", Some("uk")).is_ok());
    }

    #[test]
    fn names_cover_the_stored_codes() {
        assert_eq!(language_name("auto"), "Auto-detect");
        assert_eq!(language_name("yue"), "Chinese (Cantonese)");
        assert_eq!(language_name("xx"), "Auto-detect");
    }
}
