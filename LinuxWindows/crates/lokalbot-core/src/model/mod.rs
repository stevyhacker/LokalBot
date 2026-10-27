//! Serializable records of the library. Field names follow the macOS JSON so
//! files round-trip between both apps.

pub mod activity;
pub mod chat;
pub mod digest;
pub mod follow_up;
pub mod meeting;
pub mod outcomes;
pub mod people;
pub mod projects;
pub mod transcript;

pub use activity::*;
pub use chat::*;
pub use digest::*;
pub use follow_up::*;
pub use meeting::*;
pub use outcomes::*;
pub use people::*;
pub use projects::*;
pub use transcript::*;
