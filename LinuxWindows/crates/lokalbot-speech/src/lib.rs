//! On-device speech for LokalBot on Linux and Windows, built on sherpa-onnx:
//! transcription (Qwen3-ASR by default), voice activity detection, speaker
//! separation and attribution into a [`lokalbot_core::Transcript`].
//!
//! Follows the macOS pipeline (`ProcessingPipeline`, `AttributedTrackTranscriber`,
//! `TranscriptSanitizer`): the microphone track is "Me" (`local…`), system
//! audio is "Them" (`them…`), each optionally split into voices.

mod asr;
mod attribution;
mod bleed;
mod bleed_gate;
mod diarize;
pub mod models;
mod sanitize;
mod text;
mod transcriber;
mod vad;

pub use asr::qwen_language_name;
pub use attribution::{Region, Turn, apply_microphone_default, regions, track_attribution};
pub use bleed::{BLEED_MIN_SIMILARITY, BLEED_WINDOW_SECONDS, remove_bleed};
pub use bleed_gate::BleedGate;
pub use diarize::{CLUSTER_THRESHOLD, Diarizer};
pub use models::{SpeechModel, diarization_models, transcription_models, vad_model};
pub use sanitize::{SanitizeReport, sanitize};
pub use text::{PromptEcho, normalized_text, prompt_terms};
pub use transcriber::{
    MIN_AUDIO_SECONDS, MIN_SPEECH_SECONDS, RawSegment, SpeechError, TranscribeOptions,
    TranscribeProgress, Transcriber,
};
