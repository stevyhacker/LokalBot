//! Agent Mode for Linux and Windows: a local coding and file agent powered by
//! the selected Think model (`LokalBot/Agent` on macOS).
//!
//! LokalBot does not implement the agent loop. It installs a pinned Bun and
//! the open-source pi coding agent ([`install`]), runs pi as a subprocess in
//! RPC mode ([`process`], [`launch`]) and drives it over JSONL on stdio
//! ([`frame`], [`messages`], [`rpc`]). pi's model is the Think model behind
//! an OpenAI-compatible endpoint ([`endpoint`]); LokalBot's pi extension
//! gates every tool except workspace reads, and [`policy`] decides which of
//! those requests the user must approve. [`session`] and [`tabs`] hold the
//! state the Agent page shows; [`history`], [`archive`] and [`tasks`] read
//! and write the same files as the Mac app.

pub mod archive;
pub mod context;
pub mod digest;
pub mod endpoint;
pub mod fileurl;
pub mod frame;
mod fsutil;
pub mod history;
pub mod install;
pub mod launch;
pub mod launcher;
pub mod layout;
pub mod manifest;
pub mod messages;
pub mod policy;
pub mod process;
pub mod resources;
pub mod rpc;
pub mod session;
pub mod shell;
pub mod tabs;
pub mod tasks;
pub mod transcript;

pub use install::{InstallPhase, Installer};
pub use launcher::PiLauncher;
pub use layout::{AgentDirectories, RuntimeLayout};
pub use manifest::RuntimeManifest;
pub use policy::{ApprovalMode, ApprovalScope};
pub use session::{AgentEnvironment, AgentSession, RecoveryAction, SessionState, TaskInput};
pub use tabs::{Tab, TaskList};
pub use transcript::{ApprovalRequest, ToolStatus, TranscriptItem};
