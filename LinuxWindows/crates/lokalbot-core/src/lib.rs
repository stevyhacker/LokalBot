//! LokalBot's local library for Linux and Windows.
//!
//! The on-disk format follows the macOS app (`LokalBot/Services/StorageManager.swift`):
//! one folder per meeting with `meta.json`, `transcript.json`, `summary.md`,
//! `outcomes.json` and friends, plus `lokalbotv3.sqlite` for search indexes,
//! activity blocks and screen context. A library written by either app can be
//! read by the other; audio tracks are the one difference (`mic.wav`/`system.wav`
//! here, `mic.m4a`/`system.m4a` on macOS), and each app reads the other's.

pub mod access;
pub mod actions;
pub mod calendar;
pub mod demo;
pub mod dictation_history;
pub mod digest;
pub mod due;
pub mod embeddings;
pub mod evidence;
pub mod ids;
pub mod import;
pub mod jobs;
pub mod library;
pub mod merge;
pub mod model;
pub mod paths;
pub mod people;
pub mod projects;
pub mod retention;
pub mod screen;
pub mod search;
pub mod settings;
pub mod time;
pub mod timeline;

pub use actions::{ActionCorrection, OutcomeProjection};
pub use digest::parse_digest;
pub use embeddings::{embedding_chunks, rrf_fuse};
pub use jobs::PipelineJob;
pub use library::Library;
pub use model::*;
pub use paths::LibraryPaths;
pub use retention::RetentionReport;
pub use search::{DocKind, SearchHit, SearchQuery};
pub use settings::Settings;
pub use timeline::work_sessions;
