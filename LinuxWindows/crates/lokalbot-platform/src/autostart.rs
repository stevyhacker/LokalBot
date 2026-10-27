//! "Launch at login": `~/.config/autostart/lokalbot.desktop` on Linux, the
//! `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value on Windows.

use std::path::{Path, PathBuf};

/// Name of the Linux autostart entry and the Windows Run value.
pub const AUTOSTART_NAME: &str = "LokalBot";

/// Argument passed when the system starts LokalBot at login, so the app can
/// start in the tray without opening its window.
pub const AUTOSTART_ARG: &str = "--autostart";

/// Turns launching at login on or off for `exe`.
pub fn set_launch_at_login(enabled: bool, exe: &Path) -> anyhow::Result<()> {
    platform::set(enabled, exe)
}

/// Whether LokalBot is set to start at login (and not disabled by the user
/// in the system's startup settings).
pub fn launch_at_login_enabled() -> bool {
    platform::enabled()
}

/// Quotes one argument for an `Exec=` line (Desktop Entry Specification).
fn exec_quote(argument: &str) -> String {
    let reserved = |c: char| c.is_whitespace() || "\"'\\><~|&;$*?#()`".contains(c);
    let escaped = argument.replace('%', "%%");
    if !escaped.contains(reserved) {
        return escaped;
    }
    let mut out = String::from("\"");
    for c in escaped.chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// The autostart desktop entry for `exe`.
pub fn linux_desktop_entry(exe: &Path) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=LokalBot\nComment=Private work memory\nExec={} {AUTOSTART_ARG}\nIcon={}\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
        exec_quote(&exe.to_string_lossy()),
        crate::APP_ID
    )
}

/// `$XDG_CONFIG_HOME/autostart/lokalbot.desktop`.
pub fn linux_autostart_file() -> Option<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(config.join("autostart").join("lokalbot.desktop"))
}

#[cfg(any(target_os = "linux", test))]
/// Whether an autostart entry is active (not `Hidden`, not switched off).
fn linux_entry_enabled(text: &str) -> bool {
    let value = |key: &str| {
        text.lines()
            .filter_map(|line| line.trim().split_once('='))
            .find(|(k, _)| k.trim() == key)
            .map(|(_, v)| v.trim().to_string())
    };
    value("Hidden").as_deref() != Some("true")
        && value("X-GNOME-Autostart-enabled").as_deref() != Some("false")
}

#[cfg(any(target_os = "linux", test))]
fn write_linux_entry(file: &Path, enabled: bool, exe: &Path) -> anyhow::Result<()> {
    if enabled {
        if let Some(dir) = file.parent() {
            std::fs::create_dir_all(dir)?;
        }
        std::fs::write(file, linux_desktop_entry(exe))?;
    } else {
        match std::fs::remove_file(file) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => return Err(err.into()),
        }
    }
    Ok(())
}

#[cfg(any(target_os = "linux", test))]
fn read_linux_entry(file: &Path) -> bool {
    std::fs::read_to_string(file).is_ok_and(|text| linux_entry_enabled(&text))
}

/// The Run value: the quoted executable and the autostart argument.
pub fn windows_run_value(exe: &Path) -> String {
    format!("\"{}\" {AUTOSTART_ARG}", exe.display())
}

/// `Explorer\StartupApproved\Run` entries start with an even byte when the
/// item is enabled and an odd one after the user disabled it in Task Manager
/// or Settings.
pub fn windows_startup_approved(value: &[u8]) -> bool {
    value.first().is_none_or(|first| first % 2 == 0)
}

#[cfg(target_os = "linux")]
mod platform {
    use std::path::Path;

    pub(super) fn set(enabled: bool, exe: &Path) -> anyhow::Result<()> {
        let file = super::linux_autostart_file()
            .ok_or_else(|| anyhow::anyhow!("no home folder for the autostart entry"))?;
        super::write_linux_entry(&file, enabled, exe)
    }

    pub(super) fn enabled() -> bool {
        super::linux_autostart_file().is_some_and(|file| super::read_linux_entry(&file))
    }
}

#[cfg(windows)]
mod platform {
    use std::path::Path;

    use windows::Win32::Foundation::ERROR_FILE_NOT_FOUND;
    use windows::Win32::System::Registry::{
        HKEY_CURRENT_USER, REG_SZ, RRF_RT_REG_BINARY, RRF_RT_REG_SZ, RegDeleteKeyValueW,
        RegGetValueW, RegSetKeyValueW,
    };
    use windows::core::HSTRING;

    use super::AUTOSTART_NAME;

    const RUN: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    const APPROVED: &str =
        r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    pub(super) fn set(enabled: bool, exe: &Path) -> anyhow::Result<()> {
        let key = HSTRING::from(RUN);
        let name = HSTRING::from(AUTOSTART_NAME);
        if enabled {
            let value: Vec<u16> = super::windows_run_value(exe)
                .encode_utf16()
                .chain(Some(0))
                .collect();
            // SAFETY: `value` is a NUL-terminated UTF-16 buffer of the size
            // passed in bytes.
            unsafe {
                RegSetKeyValueW(
                    HKEY_CURRENT_USER,
                    &key,
                    &name,
                    REG_SZ.0,
                    Some(value.as_ptr().cast()),
                    (value.len() * 2) as u32,
                )
                .ok()?;
                // A "disabled" mark from Task Manager would keep it off.
                let _ = RegDeleteKeyValueW(HKEY_CURRENT_USER, &HSTRING::from(APPROVED), &name);
            }
        } else {
            // SAFETY: deletes one named value; a missing value is fine.
            let deleted = unsafe { RegDeleteKeyValueW(HKEY_CURRENT_USER, &key, &name) };
            if deleted.is_err() && deleted != ERROR_FILE_NOT_FOUND {
                deleted.ok()?;
            }
        }
        Ok(())
    }

    fn read(
        key: &str,
        kind: windows::Win32::System::Registry::REG_ROUTINE_FLAGS,
    ) -> Option<Vec<u8>> {
        let key = HSTRING::from(key);
        let name = HSTRING::from(AUTOSTART_NAME);
        let mut size = 0u32;
        // SAFETY: first call asks for the size; the second fills a buffer of
        // exactly that size.
        unsafe {
            RegGetValueW(
                HKEY_CURRENT_USER,
                &key,
                &name,
                kind,
                None,
                None,
                Some(&mut size),
            )
            .ok()
            .ok()?;
            let mut buffer = vec![0u8; size as usize];
            RegGetValueW(
                HKEY_CURRENT_USER,
                &key,
                &name,
                kind,
                None,
                Some(buffer.as_mut_ptr().cast()),
                Some(&mut size),
            )
            .ok()
            .ok()?;
            buffer.truncate(size as usize);
            Some(buffer)
        }
    }

    pub(super) fn enabled() -> bool {
        if read(RUN, RRF_RT_REG_SZ).is_none() {
            return false;
        }
        read(APPROVED, RRF_RT_REG_BINARY)
            .is_none_or(|value| super::windows_startup_approved(&value))
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod platform {
    use std::path::Path;

    pub(super) fn set(_: bool, _: &Path) -> anyhow::Result<()> {
        anyhow::bail!("launch at login is not available on this system")
    }

    pub(super) fn enabled() -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_entry_quotes_the_executable() {
        let entry = linux_desktop_entry(Path::new("/opt/LokalBot/lokalbot"));
        assert!(entry.contains("\nExec=/opt/LokalBot/lokalbot --autostart\n"));
        assert!(entry.contains("\nIcon=com.lokalbot.LokalBot\n"));
        let entry = linux_desktop_entry(Path::new("/home/a b/100%/lokal$bot"));
        assert!(
            entry.contains(r#"Exec="/home/a b/100%%/lokal\$bot" --autostart"#),
            "{entry}"
        );
    }

    #[test]
    fn linux_entries_round_trip_in_a_temp_folder() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("autostart").join("lokalbot.desktop");
        assert!(!read_linux_entry(&file));
        write_linux_entry(&file, true, Path::new("/usr/bin/lokalbot")).unwrap();
        assert!(read_linux_entry(&file));
        std::fs::write(&file, "[Desktop Entry]\nHidden=true\n").unwrap();
        assert!(!read_linux_entry(&file));
        write_linux_entry(&file, false, Path::new("/usr/bin/lokalbot")).unwrap();
        assert!(!file.exists());
        // Turning off twice is fine.
        write_linux_entry(&file, false, Path::new("/usr/bin/lokalbot")).unwrap();
    }

    #[test]
    fn windows_values() {
        assert_eq!(
            windows_run_value(Path::new(r"C:\Program Files\LokalBot\lokalbot.exe")),
            r#""C:\Program Files\LokalBot\lokalbot.exe" --autostart"#
        );
        assert!(windows_startup_approved(&[0x02, 0, 0, 0]));
        assert!(windows_startup_approved(&[0x06]));
        assert!(!windows_startup_approved(&[0x03, 0, 0, 0, 1, 2, 3, 4]));
        assert!(windows_startup_approved(&[]));
    }

    /// Read-only: never enables anything on a test machine.
    #[test]
    fn reading_the_state_does_not_fail() {
        eprintln!("launch at login: {}", launch_at_login_enabled());
    }
}
