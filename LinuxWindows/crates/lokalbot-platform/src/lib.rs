//! Operating-system integration for LokalBot on Linux and Windows: activity
//! sampling, privacy rules, single instance and IPC, global shortcuts, text
//! insertion, autocomplete's field reading and key handling, the tray,
//! notifications, launch at login, meeting detection, calendars, screen
//! context capture and opening files.
//!
//! Everything compiles on both systems and degrades with an explanation where
//! a desktop cannot provide something (for example GNOME on Wayland without a
//! window-information extension).

pub mod activity;
pub mod autocomplete;
pub mod autostart;
pub mod calendar;
pub mod insert;
pub mod instance;
pub mod meeting;
pub mod notify;
pub mod opener;
pub mod privacy;
pub mod screen;
pub mod session;
pub mod shortcuts;
pub mod tray;

#[cfg(target_os = "linux")]
mod process;
#[cfg(windows)]
mod win32_loop;

/// Application id shared with the GPUI app (`cx.set_app_identity`, Wayland
/// `app_id`). Portals and Windows notifications use it.
pub const APP_ID: &str = "com.lokalbot.LokalBot";

pub use activity::{ActivitySource, activity_source};
pub use autostart::{launch_at_login_enabled, set_launch_at_login};
pub use insert::{InsertMethod, InsertOutcome, copy_to_clipboard, insert_text};
pub use instance::{
    InstanceError, InstanceGuard, IpcCommand, IpcError, IpcServer, acquire_instance, listen, send,
};
pub use meeting::{CalendarHint, DetectedMeeting, DetectorEvent, MeetingDetector};
pub use notify::{NotificationHandle, notify, notify_with_timeout};
pub use opener::{open_path, open_url, reveal_in_file_manager};
pub use privacy::{PRIVATE_APP, SampleDisposition, disposition, redact};
pub use session::{Desktop, desktop};
pub use shortcuts::{
    GlobalShortcuts, Key, Shortcut, ShortcutError, ShortcutEvent, ShortcutParseError,
    ShortcutProblem,
};
pub use tray::{Tray, TrayEvent, TrayItem, TrayMenuState, TrayUpdate, TrayUpdateAction};
