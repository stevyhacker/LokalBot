//! LokalBot's local library for Linux and Windows.
//!
//! The on-disk format follows the macOS app (`LokalBot/Services/Storage/StorageManager.swift`):
//! one folder per meeting with `meta.json`, `transcript.json`, `summary.md`,
//! `outcomes.json` and friends, plus `lokalbotv3.sqlite` for search indexes,
//! activity blocks and screen context. A library written by either app can be
//! read by the other; audio tracks are the one difference (`mic.wav`/`system.wav`
//! here, `mic.m4a`/`system.m4a` on macOS), and each app reads the other's.

pub mod access;
pub mod action_completion;
pub mod actions;
pub mod agent_handoff;
pub mod agent_notes;
pub mod audio_files;
pub mod calendar;
pub mod chats;
pub mod coding_agents;
pub mod control;
pub mod cotyping_stats;
pub mod day_stats;
pub mod demo;
pub mod dictation_history;
pub mod digest;
pub mod dream;
pub mod due;
pub mod embeddings;
pub mod evidence;
pub mod files;
pub mod generated_file;
pub mod github_star;
pub mod health;
pub mod ids;
pub mod import;
pub mod jobs;
pub mod library;
pub mod meeting_review;
pub mod meeting_screen;
pub mod merge;
pub mod model;
pub mod paths;
pub mod people;
pub mod personal;
pub mod projects;
pub mod remote_transcription;
pub mod retention;
pub mod routines;
pub mod screen;
pub mod screen_search;
pub mod sealed;
pub mod search;
pub mod settings;
pub mod speaker_bleed;
pub mod text;
pub mod time;
pub mod timeline;
pub mod vocabulary;
pub mod voice;

pub use actions::{ActionCorrection, OutcomeProjection};
pub use digest::parse_digest;
pub use embeddings::{embedding_chunks, rrf_fuse};
pub use jobs::PipelineJob;
pub use library::Library;
pub use model::*;
pub use paths::LibraryPaths;
pub use retention::{CaptureDeletionReview, RetentionReport, RetentionReview};
pub use search::{DocKind, SearchHit, SearchQuery};
pub use settings::Settings;
pub use timeline::work_sessions;
