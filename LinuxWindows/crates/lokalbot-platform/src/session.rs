//! Which desktop session LokalBot runs in, decided at runtime so one Linux
//! build serves X11 and every Wayland desktop.

/// The desktop or compositor, as far as it changes how LokalBot talks to it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Desktop {
    Windows,
    X11,
    Hyprland,
    Sway,
    Kde,
    Gnome,
    /// Another Wayland compositor, named by `XDG_CURRENT_DESKTOP` if set.
    OtherWayland(String),
    /// No graphical session (SSH, a service, CI without a display).
    Headless,
}

impl Desktop {
    pub fn label(&self) -> String {
        match self {
            Self::Windows => "Windows".into(),
            Self::X11 => "X11".into(),
            Self::Hyprland => "Hyprland".into(),
            Self::Sway => "Sway".into(),
            Self::Kde => "KDE Plasma (Wayland)".into(),
            Self::Gnome => "GNOME (Wayland)".into(),
            Self::OtherWayland(name) if name.is_empty() => "Wayland".into(),
            Self::OtherWayland(name) => format!("{name} (Wayland)"),
            Self::Headless => "no desktop session".into(),
        }
    }

    /// Hyprland (Omarchy) and Sway tile every ordinary window. Both float a
    /// window that has a parent window, as they do dialogs.
    pub fn tiles_windows(&self) -> bool {
        matches!(self, Self::Hyprland | Self::Sway)
    }
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

/// True in a Wayland session, where X11 only sees XWayland windows.
pub fn is_wayland() -> bool {
    if cfg!(windows) {
        return false;
    }
    env("WAYLAND_DISPLAY").is_some()
        || env("XDG_SESSION_TYPE").is_some_and(|kind| kind.eq_ignore_ascii_case("wayland"))
}

/// True when an X server accepts connections (`DISPLAY`).
#[cfg(target_os = "linux")]
pub fn has_x11_display() -> bool {
    env("DISPLAY").is_some() && x11rb::connect(None).is_ok()
}

pub fn desktop() -> Desktop {
    if cfg!(windows) {
        return Desktop::Windows;
    }
    if is_wayland() {
        let current = env("XDG_CURRENT_DESKTOP").unwrap_or_default();
        let lower = current.to_lowercase();
        if env("HYPRLAND_INSTANCE_SIGNATURE").is_some() || lower.contains("hyprland") {
            return Desktop::Hyprland;
        }
        if env("SWAYSOCK").is_some() || lower.split(':').any(|part| part == "sway") {
            return Desktop::Sway;
        }
        if lower.split(':').any(|part| part == "kde") || env("KDE_FULL_SESSION").is_some() {
            return Desktop::Kde;
        }
        if lower.split(':').any(|part| part == "gnome") {
            return Desktop::Gnome;
        }
        return Desktop::OtherWayland(current);
    }
    if env("DISPLAY").is_some() {
        return Desktop::X11;
    }
    Desktop::Headless
}
