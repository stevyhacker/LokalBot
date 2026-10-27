//! Desktop notifications (`RecordingNotifier.swift`): "Meeting detected /
//! Record <title>?" with Record and Ignore, "Recording saved", and friends.
//!
//! Linux uses `org.freedesktop.Notifications` with actions; Windows shows a
//! toast with buttons. Action callbacks run on a background thread, one per
//! notification that has actions; forward them to the app.

use std::time::Duration;

use anyhow::Context as _;

/// "Meeting detected" prompts are withdrawn after two minutes on macOS.
pub const MEETING_PROMPT_LIFETIME: Duration = Duration::from_secs(120);

/// Shown in the app when notifications cannot be posted
/// (`RecordingNotifier`).
pub fn notifications_unavailable_message(title: &str) -> String {
    format!(
        "Notifications are unavailable. Choose Record Now in the LokalBot menu to record {title}."
    )
}

/// A posted notification, to withdraw it early (for example when the meeting
/// it asks about has ended).
pub struct NotificationHandle {
    #[cfg(target_os = "linux")]
    id: u32,
}

impl NotificationHandle {
    /// Removes the notification if it is still shown.
    pub fn close(&self) {
        #[cfg(target_os = "linux")]
        close_by_id(self.id);
    }
}

/// Posts a notification. `actions` are `(id, label)` pairs; `on_action`
/// receives the chosen id ("default" when the notification body is clicked).
pub fn notify(
    title: &str,
    body: &str,
    actions: &[(&str, &str)],
    on_action: Option<Box<dyn Fn(String) + Send>>,
) -> anyhow::Result<()> {
    notify_with_timeout(title, body, actions, on_action, None).map(|_| ())
}

/// [`notify`] that expires after `timeout` and can be withdrawn.
pub fn notify_with_timeout(
    title: &str,
    body: &str,
    actions: &[(&str, &str)],
    on_action: Option<Box<dyn Fn(String) + Send>>,
    timeout: Option<Duration>,
) -> anyhow::Result<NotificationHandle> {
    let mut notification = notify_rust::Notification::new();
    notification.summary(title).body(body).appname("LokalBot");
    #[cfg(target_os = "linux")]
    notification.icon(crate::APP_ID);
    #[cfg(windows)]
    notification.app_id(&windows_app_id());
    for (id, label) in actions {
        notification.action(id, label);
    }
    if let Some(timeout) = timeout {
        notification.timeout(notify_rust::Timeout::Milliseconds(
            u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX),
        ));
    }
    #[cfg(target_os = "linux")]
    anyhow::ensure!(
        server_available(),
        "no notification service is running on this desktop"
    );
    // A stuck notification service must not hold up the caller.
    let (sent, received) = crossbeam_channel::bounded(1);
    std::thread::Builder::new()
        .name("lokalbot-notification-show".into())
        .spawn(move || {
            let _ = sent.send(notification.show());
        })?;
    let shown = received
        .recv_timeout(SHOW_TIMEOUT)
        .map_err(|_| anyhow::anyhow!("the notification service did not answer"))?
        .context("the notification could not be shown")?;
    #[cfg(target_os = "linux")]
    let id = shown.id();
    if let Some(on_action) = on_action
        && !actions.is_empty()
    {
        std::thread::Builder::new()
            .name("lokalbot-notification".into())
            .spawn(move || {
                shown.wait_for_action(|action| {
                    if action != "__closed" {
                        on_action(action.to_string());
                    }
                });
            })?;
        // Servers that ignore the expiry (GNOME keeps it in its list) are
        // asked to withdraw it, like the macOS prompt.
        #[cfg(target_os = "linux")]
        if let Some(timeout) = timeout {
            let _ = std::thread::Builder::new()
                .name("lokalbot-notification-expiry".into())
                .spawn(move || {
                    std::thread::sleep(timeout);
                    close_by_id(id);
                });
        }
    }
    Ok(NotificationHandle {
        #[cfg(target_os = "linux")]
        id,
    })
}

const SHOW_TIMEOUT: Duration = Duration::from_secs(5);

/// Whether something owns `org.freedesktop.Notifications` or D-Bus can start
/// it. Without this check, posting waits for D-Bus activation to time out.
#[cfg(target_os = "linux")]
fn server_available() -> bool {
    const NAME: &str = "org.freedesktop.Notifications";
    let check = || -> anyhow::Result<bool> {
        let bus = zbus::blocking::connection::Builder::session()?
            .method_timeout(Duration::from_secs(2))
            .build()?;
        let dbus = zbus::blocking::fdo::DBusProxy::new(&bus)?;
        if dbus.name_has_owner(NAME.try_into()?)? {
            return Ok(true);
        }
        Ok(dbus
            .list_activatable_names()?
            .iter()
            .any(|name| name.as_str() == NAME))
    };
    check().unwrap_or_else(|err| {
        log::debug!("notification service check: {err:#}");
        false
    })
}

#[cfg(target_os = "linux")]
fn close_by_id(id: u32) {
    let closed = zbus::blocking::Connection::session().and_then(|bus| {
        bus.call_method(
            Some("org.freedesktop.Notifications"),
            "/org/freedesktop/Notifications",
            Some("org.freedesktop.Notifications"),
            "CloseNotification",
            &(id,),
        )
        .map(|_| ())
    });
    if let Err(err) = closed {
        log::debug!("closing notification {id}: {err}");
    }
}

/// Windows shows a toast under a registered app id (a Start menu shortcut
/// carrying `System.AppUserModel.ID`, created by the installer). Without one,
/// toasts appear under Windows PowerShell rather than not at all.
#[cfg(windows)]
fn windows_app_id() -> String {
    use windows::Win32::System::Registry::{
        HKEY, HKEY_CURRENT_USER, KEY_READ, RegCloseKey, RegOpenKeyExW,
    };
    use windows::core::HSTRING;

    let key = HSTRING::from(format!(
        r"Software\Classes\AppUserModelId\{}",
        crate::APP_ID
    ));
    let mut handle = HKEY::default();
    // SAFETY: opens and closes a read-only registry key handle.
    let registered = unsafe {
        let opened = RegOpenKeyExW(HKEY_CURRENT_USER, &key, None, KEY_READ, &mut handle);
        if opened.is_ok() {
            let _ = RegCloseKey(handle);
        }
        opened.is_ok()
    };
    if registered || start_menu_shortcut_exists() {
        crate::APP_ID.to_string()
    } else {
        "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe"
            .to_string()
    }
}

#[cfg(windows)]
fn start_menu_shortcut_exists() -> bool {
    std::env::var_os("APPDATA").is_some_and(|appdata| {
        std::path::Path::new(&appdata)
            .join(r"Microsoft\Windows\Start Menu\Programs\LokalBot.lnk")
            .exists()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unavailable_copy() {
        assert_eq!(
            notifications_unavailable_message("Zoom meeting"),
            "Notifications are unavailable. Choose Record Now in the LokalBot menu to record Zoom meeting."
        );
    }

    /// Needs a notification server; over SSH there is none, which must be an
    /// error rather than a hang or a crash. Linux only: on Windows a toast
    /// would reach the signed-in user's desktop.
    #[cfg(target_os = "linux")]
    #[test]
    fn posting_without_a_desktop_fails_cleanly() {
        let started = std::time::Instant::now();
        let result = notify("LokalBot test", "Ignore this", &[], None);
        eprintln!("notify without a desktop: {result:?}");
        assert!(started.elapsed() < Duration::from_secs(10));
    }
}
