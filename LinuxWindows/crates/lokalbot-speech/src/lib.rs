//! On-device speech for LokalBot on Linux and Windows, built on sherpa-onnx:
//! transcription (Qwen3-ASR by default), voice activity detection, speaker
//! separation and attribution into a [`lokalbot_core::Transcript`].
//!
//! Follows the macOS pipeline (`ProcessingPipeline`, `AttributedTrackTranscriber`,
//! `TranscriptSanitizer`): the microphone track is "Me" (`local…`), system
//! audio is "Them" (`them…`), each optionally split into voices. [`kokoro`]
//! reads text aloud.

mod asr;
mod attribution;
mod bleed_gate;
mod diarize;
mod echo;
mod echo_evidence;
pub mod kokoro;
pub mod language;
pub mod models;
mod sanitize;
mod text;
mod transcriber;
mod vad;
mod voice;

pub use asr::qwen_language_name;
pub use attribution::renumber_speakers;
pub use attribution::{Region, Turn, apply_microphone_default, regions, track_attribution};
pub use bleed_gate::BleedGate;
pub use diarize::{CLUSTER_THRESHOLD, Diarizer};
pub use echo::{EchoCanceller, EchoRemoval, remove_echo};
pub use echo_evidence::EchoAnalysis;
pub use models::{SpeechModel, diarization_models, transcription_models, vad_model};
pub use sanitize::{SanitizeReport, sanitize};
pub use text::{PromptEcho, normalized_text, prompt_terms};
pub use transcriber::{
    DetailedTranscript, MIN_AUDIO_SECONDS, MIN_SPEECH_SECONDS, RawSegment, SpeechError,
    SpeechServer, TranscribeOptions, TranscribeProgress, Transcriber, analyze_call_voices,
};
pub use voice::{VoiceChunk, VoiceExtractor, voice_chunks, voice_samples};
