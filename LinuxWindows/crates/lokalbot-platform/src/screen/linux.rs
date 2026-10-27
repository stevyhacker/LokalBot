//! Linux: the capture backend for this session, and whether it is locked.

use std::sync::OnceLock;
use std::time::Duration;

use super::{Unavailable, WindowCapture};
use crate::session::Desktop;

pub(super) fn window_capture() -> Box<dyn WindowCapture> {
    let desktop = crate::session::desktop();
    match &desktop {
        Desktop::X11 => match super::x11::X11Capture::connect() {
            Ok(capture) => Box::new(capture),
            Err(err) => {
                log::warn!("screen capture: {err:#}");
                Box::new(Unavailable(
                    "LokalBot could not connect to the X server, so it cannot capture screen context."
                        .into(),
                ))
            }
        },
        Desktop::Sway | Desktop::Hyprland => match super::wayland::Grim::new(desktop.clone()) {
            Some(grim) => Box::new(grim),
            None => Box::new(super::wayland::Portal::new(desktop.clone())),
        },
        Desktop::Gnome | Desktop::Kde | Desktop::OtherWayland(_) => {
            Box::new(super::wayland::Portal::new(desktop.clone()))
        }
        Desktop::Headless | Desktop::Windows => Box::new(Unavailable(
            "No desktop session was found, so LokalBot cannot capture screen context.".into(),
        )),
    }
}

/// The lock screen is up: logind's `LockedHint` for this session, or an
/// active screen saver.
pub(super) fn session_locked() -> bool {
    logind_locked() || screensaver_active()
}

fn bus(system: bool) -> Option<&'static zbus::blocking::Connection> {
    static SYSTEM: OnceLock<Option<zbus::blocking::Connection>> = OnceLock::new();
    static SESSION: OnceLock<Option<zbus::blocking::Connection>> = OnceLock::new();
    let cell = if system { &SYSTEM } else { &SESSION };
    cell.get_or_init(|| {
        let builder = if system {
            zbus::blocking::connection::Builder::system()
        } else {
            zbus::blocking::connection::Builder::session()
        };
        builder
            .ok()?
            .method_timeout(Duration::from_millis(500))
            .build()
            .ok()
    })
    .as_ref()
}

fn logind_locked() -> bool {
    let Some(bus) = bus(true) else { return false };
    let proxy = zbus::blocking::Proxy::new(
        bus,
        "org.freedesktop.login1",
        "/org/freedesktop/login1/session/auto",
        "org.freedesktop.login1.Session",
    );
    proxy
        .ok()
        .and_then(|proxy| proxy.get_property::<bool>("LockedHint").ok())
        .unwrap_or(false)
}

fn screensaver_active() -> bool {
    let Some(bus) = bus(false) else { return false };
    let Ok(dbus) = zbus::blocking::fdo::DBusProxy::new(bus) else {
        return false;
    };
    [
        (
            "org.freedesktop.ScreenSaver",
            "/org/freedesktop/ScreenSaver",
            "org.freedesktop.ScreenSaver",
        ),
        (
            "org.gnome.ScreenSaver",
            "/org/gnome/ScreenSaver",
            "org.gnome.ScreenSaver",
        ),
    ]
    .iter()
    .any(|(name, path, interface)| {
        // Asking an unowned name could start a screen saver service.
        let owned = zbus::names::BusName::try_from(*name)
            .ok()
            .and_then(|bus_name| dbus.name_has_owner(bus_name).ok())
            .unwrap_or(false);
        owned
            && bus
                .call_method(Some(*name), *path, Some(*interface), "GetActive", &())
                .ok()
                .and_then(|reply| reply.body().deserialize::<bool>().ok())
                .unwrap_or(false)
    })
}
