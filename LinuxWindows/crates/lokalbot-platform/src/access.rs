//! What first-run setup can check about this computer before anything turns
//! on (`OnboardingAccess` on the Mac). Linux and Windows have no permission
//! prompts like macOS, so each check reads what this desktop provides
//! instead. Every check only reads: none prompts, opens a capture session,
//! loads a script, reads a window's contents or changes a setting.

use crate::session::Desktop;

/// Where one thing setup needs stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Check {
    /// It works now, with nothing left to allow.
    Ready,
    /// The system has it switched off (Windows' microphone privacy setting).
    TurnedOff,
    /// Something this desktop lacks, which the person can add.
    Missing(Gap),
    /// It can't be known before the feature first runs.
    Unknown,
}

/// What is missing, for the app to word.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Gap {
    /// GNOME on Wayland without a window-information extension ("Window Calls").
    GnomeWindowExtension,
    /// This desktop gives no way to see which window is in front.
    WindowTitles,
    /// No AT-SPI accessibility service in this session.
    AccessibilityService,
    /// No way to take a screenshot of only the window in front.
    WindowScreenshots,
    /// No Secret Service provider to keep the screenshot key.
    CredentialStore,
}

/// Windows' "Let desktop apps access your microphone" and the switches
/// above it. Elsewhere `Unknown`: there is no such switch to read.
pub fn microphone() -> Check {
    #[cfg(windows)]
    {
        win::microphone()
    }
    #[cfg(not(windows))]
    {
        Check::Unknown
    }
}

/// Seeing the app and window title in front, which day memory records.
pub fn window_titles() -> Check {
    let desktop = crate::session::desktop();
    let has_env = |name: &str| std::env::var_os(name).is_some();
    #[cfg(target_os = "linux")]
    {
        window_titles_on(&desktop, linux::gnome_window_extension, has_env)
    }
    #[cfg(not(target_os = "linux"))]
    {
        window_titles_on(&desktop, || None, has_env)
    }
}

fn window_titles_on(
    desktop: &Desktop,
    gnome_extension: impl FnOnce() -> Option<bool>,
    has_env: impl Fn(&str) -> bool,
) -> Check {
    match desktop {
        // Win32 and X11 (EWMH) tell any app which window is in front.
        Desktop::Windows | Desktop::X11 => Check::Ready,
        Desktop::Hyprland if has_env("HYPRLAND_INSTANCE_SIGNATURE") => Check::Ready,
        Desktop::Sway if has_env("SWAYSOCK") => Check::Ready,
        Desktop::Hyprland | Desktop::Sway => Check::Unknown,
        // LokalBot loads its KWin script when day memory starts.
        Desktop::Kde => Check::Unknown,
        Desktop::Gnome => match gnome_extension() {
            Some(true) => Check::Ready,
            Some(false) => Check::Missing(Gap::GnomeWindowExtension),
            None => Check::Unknown,
        },
        Desktop::OtherWayland(_) | Desktop::Headless => Check::Missing(Gap::WindowTitles),
    }
}

/// Reading the text on screen through accessibility (AT-SPI, UI Automation).
pub fn screen_text() -> Check {
    #[cfg(target_os = "linux")]
    {
        match linux::service_available("org.a11y.Bus") {
            Some(true) => Check::Ready,
            Some(false) => Check::Missing(Gap::AccessibilityService),
            None => Check::Unknown,
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        // UI Automation needs no permission.
        if cfg!(windows) {
            Check::Ready
        } else {
            Check::Unknown
        }
    }
}

/// Taking a screenshot of only the window in front.
pub fn screenshots() -> Check {
    let desktop = crate::session::desktop();
    #[cfg(target_os = "linux")]
    {
        screenshots_on(
            &desktop,
            || has_program("grim"),
            linux::portal_window_screenshots,
        )
    }
    #[cfg(not(target_os = "linux"))]
    {
        screenshots_on(&desktop, || false, || None)
    }
}

fn screenshots_on(
    desktop: &Desktop,
    has_grim: impl Fn() -> bool,
    portal: impl FnOnce() -> Option<bool>,
) -> Check {
    match desktop {
        // GDI and X11 read a window's pixels without asking.
        Desktop::Windows | Desktop::X11 => Check::Ready,
        Desktop::Headless => Check::Missing(Gap::WindowScreenshots),
        Desktop::Hyprland | Desktop::Sway if has_grim() => Check::Ready,
        // The screenshot portal may ask once, the first time.
        _ => match portal() {
            Some(true) => Check::Unknown,
            Some(false) => Check::Missing(Gap::WindowScreenshots),
            None => Check::Unknown,
        },
    }
}

/// A system credential store for the key that encrypts screenshots.
pub fn credential_store() -> Check {
    #[cfg(target_os = "linux")]
    {
        match linux::service_available("org.freedesktop.secrets") {
            Some(true) => Check::Ready,
            Some(false) => Check::Missing(Gap::CredentialStore),
            None => Check::Unknown,
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        // Windows always has its Credential Manager.
        if cfg!(windows) {
            Check::Ready
        } else {
            Check::Unknown
        }
    }
}

#[cfg(target_os = "linux")]
fn has_program(name: &str) -> bool {
    std::env::var_os("PATH")
        .is_some_and(|path| std::env::split_paths(&path).any(|dir| dir.join(name).is_file()))
}

#[cfg(target_os = "linux")]
mod linux {
    use std::time::Duration;

    fn session_bus() -> Option<zbus::blocking::Connection> {
        zbus::blocking::connection::Builder::session()
            .ok()?
            .method_timeout(Duration::from_millis(800))
            .build()
            .ok()
    }

    /// Whether a D-Bus service runs now or can be started on demand,
    /// without starting it. `None` without a session bus.
    pub(super) fn service_available(name: &str) -> Option<bool> {
        let bus = session_bus()?;
        let proxy = zbus::blocking::fdo::DBusProxy::new(&bus).ok()?;
        let name = zbus::names::BusName::try_from(name).ok()?;
        if proxy.name_has_owner(name.clone()).ok()? {
            return Some(true);
        }
        let activatable = proxy.list_activatable_names().ok()?;
        Some(
            activatable
                .iter()
                .any(|candidate| candidate.as_str() == name.as_str()),
        )
    }

    /// Whether GNOME Shell has an extension that says which window is in
    /// front. Introspection lists its interface without reading any window.
    pub(super) fn gnome_window_extension() -> Option<bool> {
        let bus = session_bus()?;
        let mut answered = false;
        for (path, interface) in [
            (
                "/org/gnome/Shell/Extensions/Windows",
                "org.gnome.Shell.Extensions.Windows",
            ),
            (
                "/org/gnome/shell/extensions/FocusedWindow",
                "org.gnome.shell.extensions.FocusedWindow",
            ),
        ] {
            let Ok(reply) = bus.call_method(
                Some("org.gnome.Shell"),
                path,
                Some("org.freedesktop.DBus.Introspectable"),
                "Introspect",
                &(),
            ) else {
                continue;
            };
            answered = true;
            if reply
                .body()
                .deserialize::<String>()
                .is_ok_and(|xml| xml.contains(&format!("\"{interface}\"")))
            {
                return Some(true);
            }
        }
        answered.then_some(false)
    }

    /// Whether the screenshot portal can capture only the window in front.
    /// Reads the portal's property; takes no screenshot.
    pub(super) fn portal_window_screenshots() -> Option<bool> {
        futures_lite::future::block_on(futures_lite::future::or(
            async {
                let proxy = ashpd::desktop::screenshot::ScreenshotProxy::new()
                    .await
                    .ok()?;
                let targets = proxy.available_targets().await.ok()?;
                Some(targets.contains(ashpd::desktop::screenshot::AvailableTargets::ActiveWindow))
            },
            async {
                async_io::Timer::after(Duration::from_secs(3)).await;
                None
            },
        ))
    }
}

#[cfg(windows)]
mod win {
    use windows::Win32::System::Registry::{
        HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ, RegGetValueW,
    };
    use windows::core::HSTRING;

    use super::Check;

    const STORE: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    /// The device switch, the user's switch and the desktop-apps switch, in
    /// that order; any one set to "Deny" keeps desktop apps off the microphone.
    pub(super) fn microphone() -> Check {
        let values = [
            read(HKEY_LOCAL_MACHINE, STORE),
            read(HKEY_CURRENT_USER, STORE),
            read(HKEY_CURRENT_USER, &format!(r"{STORE}\NonPackaged")),
        ];
        super::microphone_from(&values)
    }

    fn read(root: HKEY, key: &str) -> Option<String> {
        let key = HSTRING::from(key);
        let name = HSTRING::from("Value");
        let mut size = 0u32;
        // SAFETY: the first call asks for the size; the second fills a buffer
        // of exactly that size.
        unsafe {
            RegGetValueW(
                root,
                &key,
                &name,
                RRF_RT_REG_SZ,
                None,
                None,
                Some(&mut size),
            )
            .ok()
            .ok()?;
            let mut buffer = vec![0u16; (size as usize).div_ceil(2)];
            RegGetValueW(
                root,
                &key,
                &name,
                RRF_RT_REG_SZ,
                None,
                Some(buffer.as_mut_ptr().cast()),
                Some(&mut size),
            )
            .ok()
            .ok()?;
            let text = String::from_utf16_lossy(&buffer);
            Some(text.trim_end_matches('\0').to_string())
        }
    }
}

/// The microphone's state from its privacy switches, each "Allow", "Deny"
/// or unread.
#[cfg_attr(not(windows), allow(dead_code))]
fn microphone_from(values: &[Option<String>]) -> Check {
    if values
        .iter()
        .flatten()
        .any(|value| value.eq_ignore_ascii_case("Deny"))
    {
        Check::TurnedOff
    } else if values
        .iter()
        .flatten()
        .any(|value| value.eq_ignore_ascii_case("Allow"))
    {
        Check::Ready
    } else {
        Check::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_titles_follow_the_desktop() {
        let none = |_: &str| false;
        let all = |_: &str| true;
        assert_eq!(window_titles_on(&Desktop::X11, || None, none), Check::Ready);
        assert_eq!(
            window_titles_on(&Desktop::Windows, || None, none),
            Check::Ready
        );
        assert_eq!(window_titles_on(&Desktop::Sway, || None, all), Check::Ready);
        assert_eq!(
            window_titles_on(&Desktop::Sway, || None, none),
            Check::Unknown
        );
        assert_eq!(
            window_titles_on(&Desktop::Hyprland, || None, all),
            Check::Ready
        );
        assert_eq!(
            window_titles_on(&Desktop::Kde, || None, all),
            Check::Unknown
        );
        assert_eq!(
            window_titles_on(&Desktop::Gnome, || Some(true), none),
            Check::Ready
        );
        assert_eq!(
            window_titles_on(&Desktop::Gnome, || Some(false), none),
            Check::Missing(Gap::GnomeWindowExtension)
        );
        // GNOME Shell didn't answer: nothing is claimed.
        assert_eq!(
            window_titles_on(&Desktop::Gnome, || None, none),
            Check::Unknown
        );
        assert_eq!(
            window_titles_on(&Desktop::OtherWayland("niri".into()), || None, all),
            Check::Missing(Gap::WindowTitles)
        );
    }

    #[test]
    fn screenshots_through_the_portal_are_never_claimed_allowed() {
        assert_eq!(
            screenshots_on(&Desktop::X11, || false, || None),
            Check::Ready
        );
        assert_eq!(
            screenshots_on(&Desktop::Sway, || true, || None),
            Check::Ready
        );
        // Without grim, Sway falls back to the portal like GNOME and KDE.
        assert_eq!(
            screenshots_on(&Desktop::Sway, || false, || Some(false)),
            Check::Missing(Gap::WindowScreenshots)
        );
        // The portal can ask the first time, so a capable one stays unknown.
        assert_eq!(
            screenshots_on(&Desktop::Gnome, || false, || Some(true)),
            Check::Unknown
        );
        assert_eq!(
            screenshots_on(&Desktop::Kde, || false, || None),
            Check::Unknown
        );
        assert_eq!(
            screenshots_on(&Desktop::Headless, || true, || Some(true)),
            Check::Missing(Gap::WindowScreenshots)
        );
    }

    #[test]
    fn any_denied_microphone_switch_turns_it_off() {
        let allow = || Some("Allow".to_string());
        let deny = || Some("Deny".to_string());
        assert_eq!(microphone_from(&[allow(), allow(), allow()]), Check::Ready);
        assert_eq!(
            microphone_from(&[allow(), deny(), allow()]),
            Check::TurnedOff
        );
        assert_eq!(microphone_from(&[None, None, deny()]), Check::TurnedOff);
        assert_eq!(microphone_from(&[None, allow(), None]), Check::Ready);
        assert_eq!(microphone_from(&[None, None, None]), Check::Unknown);
    }
}
