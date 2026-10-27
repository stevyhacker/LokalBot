//! The frontmost app and window title, and how long the user has been idle
//! (`ActivitySampler` in `ActivityTracker.swift`).
//!
//! [`activity_source`] picks the backend at runtime: Win32 on Windows; on
//! Linux, X11 (EWMH) or the Wayland compositor's own interface (Hyprland,
//! Sway, KDE Plasma, GNOME with a window-information extension). The engine
//! samples every 5 s from a background thread and runs [`crate::disposition`]
//! on each sample before storing it.

use lokalbot_core::ActivitySample;

#[cfg(target_os = "linux")]
mod desktop_entries;
#[cfg(target_os = "linux")]
mod idle;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
mod wayland;
#[cfg(windows)]
mod win32;
#[cfg(target_os = "linux")]
mod x11;

#[cfg(target_os = "linux")]
pub(crate) use linux::{AppResolver, WindowLister};
#[cfg(windows)]
pub(crate) use win32::app_for_pid;

/// One way of reading the focused window. Implementations must not block for
/// long: each call is bounded by short timeouts.
pub trait ActivitySource: Send {
    /// The frontmost window now, or `None` when nothing is focused (the
    /// desktop, a lock screen, a headless session). LokalBot's own windows
    /// come back as app "LokalBot" with [`crate::privacy::SELF_APP_ID`] and no
    /// title. Errors mean the backend itself failed.
    fn sample(&mut self) -> anyhow::Result<Option<ActivitySample>>;
    /// Seconds since the last keyboard or pointer input, if known.
    fn idle_seconds(&mut self) -> Option<f64>;
    /// Short name for diagnostics: `win32`, `x11`, `hyprland`, `sway`, `kwin`,
    /// `gnome-extension`, `unavailable`.
    fn backend_name(&self) -> &'static str;
    /// What this desktop cannot provide, worded for Settings, or `None`.
    fn limitation(&self) -> Option<String>;
}

/// The best source for this session.
pub fn activity_source() -> Box<dyn ActivitySource> {
    #[cfg(windows)]
    {
        Box::new(win32::WindowsSource::new())
    }
    #[cfg(target_os = "linux")]
    {
        linux::source()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Box::new(Unavailable::new(
            "Activity tracking is not available on this system.".into(),
        ))
    }
}

/// A quick, lowercase identifier for the focused app (executable, `WM_CLASS`
/// or app id), for choosing how to paste. `None` where the desktop cannot
/// tell cheaply (GNOME and KDE on Wayland).
pub(crate) fn focused_app_hint() -> Option<String> {
    #[cfg(windows)]
    {
        win32::foreground_app_id()
    }
    #[cfg(target_os = "linux")]
    {
        linux::focused_app_hint()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        None
    }
}

/// A source that never sees anything, with the reason why.
pub struct Unavailable {
    reason: String,
}

impl Unavailable {
    pub fn new(reason: String) -> Self {
        Self { reason }
    }
}

impl ActivitySource for Unavailable {
    fn sample(&mut self) -> anyhow::Result<Option<ActivitySample>> {
        Ok(None)
    }

    fn idle_seconds(&mut self) -> Option<f64> {
        None
    }

    fn backend_name(&self) -> &'static str {
        "unavailable"
    }

    fn limitation(&self) -> Option<String> {
        Some(self.reason.clone())
    }
}

/// The sample for LokalBot's own windows: app name only.
pub(crate) fn own_window_sample(idle_seconds: f64) -> ActivitySample {
    ActivitySample {
        at: chrono::Utc::now(),
        app: "LokalBot".into(),
        app_id: crate::privacy::SELF_APP_ID.into(),
        title: String::new(),
        url: None,
        idle_seconds,
    }
}

/// Turns "gnome-terminal-server" into "Gnome-terminal-server" when nothing
/// better is known.
pub(crate) fn capitalized(name: &str) -> String {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}
