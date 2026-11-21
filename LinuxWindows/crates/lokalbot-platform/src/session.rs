#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Desktop {
    Windows,
    X11,
    Hyprland,
    Sway,
    Kde,
    Gnome,
    OtherWayland(String),
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

    pub fn tiles_windows(&self) -> bool {
        matches!(self, Self::Hyprland | Self::Sway)
    }
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

pub fn is_wayland() -> bool {
    if cfg!(windows) {
        return false;
    }
    env("WAYLAND_DISPLAY").is_some()
        || env("XDG_SESSION_TYPE").is_some_and(|kind| kind.eq_ignore_ascii_case("wayland"))
}

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

#[cfg(target_os = "linux")]
pub fn on_termination(then: impl FnOnce() + Send + 'static) {
    use std::sync::atomic::{AtomicBool, Ordering};
    static ASKED: AtomicBool = AtomicBool::new(false);
    extern "C" fn asked(signal: libc::c_int) {
        ASKED.store(true, Ordering::SeqCst);
        unsafe { libc::signal(signal, libc::SIG_DFL) };
    }
    for signal in [libc::SIGTERM, libc::SIGHUP, libc::SIGINT] {
        unsafe {
            libc::signal(
                signal,
                asked as extern "C" fn(libc::c_int) as libc::sighandler_t,
            )
        };
    }
    let spawned = std::thread::Builder::new()
        .name("lokalbot-termination".into())
        .spawn(move || {
            while !ASKED.load(Ordering::SeqCst) {
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
            then();
        });
    if let Err(err) = spawned {
        log::warn!("no handling of termination signals: {err}");
    }
}
