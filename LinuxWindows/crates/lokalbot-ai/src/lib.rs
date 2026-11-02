//! Think, Autocomplete and embeddings for LokalBot on Linux and Windows.
//!
//! - [`catalog`]: the pinned GGUF models (same files and digests as macOS).
//! - [`download`]: verified, resumable HTTPS downloads and archive extraction.
//! - [`runtime`]: prebuilt llama.cpp `llama-server` subprocesses, one per role.
//! - [`think`]: chat, embedding and raw-completion clients with the consent gate.
//! - [`anthropic`]: Claude through Anthropic's Messages API.
//! - [`plans`]: Think on the user's ChatGPT or Claude plan.
//! - [`ocr`]: on-device screen text recognition (ocrs, Tesseract, Windows).
//!
//! Errors are `anyhow::Error`; the ones callers act on are [`AiError`] values
//! inside it (`err.downcast_ref::<AiError>()`).

pub mod anthropic;
pub mod ask;
pub mod ask_agent;
pub mod autocomplete;
pub mod catalog;
pub mod dictation;
pub mod dictation_preview;
pub mod digest;
pub mod download;
pub mod download_source;
pub mod dream;
pub mod dream_rollup;
pub mod embeddings;
mod error;
pub mod follow_up;
mod http;
pub mod hugging_face;
pub mod json;
pub mod language;
pub mod media_embedder;
pub mod notes;
pub mod ocr;
pub mod personal_learning;
pub mod plans;
mod process;
pub mod project_status;
pub mod prompts;
mod reasoning_lookup;
pub mod remote_gate;
pub mod remote_transcription;
pub mod runtime;
pub mod sanitize;
pub mod selection;
pub mod think;
pub mod upcoming;

#[cfg(test)]
mod test_support;

pub use catalog::{ModelEntry, ModelKind, Preset};
pub use download::{DownloadSpec, download, extract_archive};
pub use error::{AiError, ai_error};
pub use runtime::{Lease, LlamaBackend, LlamaServer, Role, RuntimeManager};
pub use think::{
    ChatRequest, Completion, CompletionClient, CompletionRequest, EmbeddingClient, ThinkClient,
};
