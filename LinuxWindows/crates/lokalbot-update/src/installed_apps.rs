//! The entry the per-user installer (`packaging/windows/lokalbot.iss`) adds to
//! Windows' Installed apps. An update LokalBot installs itself bypasses the
//! installer, so the entry would keep showing the installer's version.
//! [`record_version`] brings it up to date, but only in an entry that already
//! exists under HKEY_CURRENT_USER and names this installation's folder: a copy
//! run from an extracted archive never gains one.

use std::io;
use std::path::Path;

use crate::version::Version;

/// The installer's `AppId`.
pub const APP_ID: &str = "{CFF062EB-30DC-4ED9-8586-AB0B54B52A85}";
/// Inno Setup's uninstall key for [`APP_ID`], under HKEY_CURRENT_USER.
pub const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{CFF062EB-30DC-4ED9-8586-AB0B54B52A85}_is1";

/// The string Installed apps shows, as Inno Setup writes `AppVersion`.
pub fn display_version(version: &Version) -> String {
    version.to_string()
}

/// The DWORDs Inno Setup writes next to `DisplayVersion`.
pub fn version_numbers(version: &Version) -> Vec<(&'static str, u32)> {
    let (Ok(major), Ok(minor)) = (u32::try_from(version.major), u32::try_from(version.minor))
    else {
        return Vec::new();
    };
    vec![
        ("MajorVersion", major),
        ("MinorVersion", minor),
        ("VersionMajor", major),
        ("VersionMinor", minor),
    ]
}

/// Whether `install_location` (`InstallLocation`, which ends in a backslash)
/// names `dir`. Windows compares paths without regard to case.
pub fn names_dir(install_location: &str, dir: &Path) -> bool {
    fn normalized(path: &str) -> String {
        let path = path.trim();
        let path = path.strip_prefix(r"\\?\").unwrap_or(path);
        path.replace('/', "\\")
            .trim_end_matches('\\')
            .to_lowercase()
    }
    let location = normalized(install_location);
    !location.is_empty() && location == normalized(&dir.to_string_lossy())
}

/// Sets the installer's Installed apps entry to `version` when it describes
/// the installation in `dir`. Returns whether anything changed; with no such
/// entry (an extracted archive, Linux) nothing is written.
pub fn record_version(dir: &Path, version: &Version) -> io::Result<bool> {
    #[cfg(windows)]
    {
        registry::record_version(UNINSTALL_KEY, dir, version)
    }
    #[cfg(not(windows))]
    {
        let _ = (dir, version);
        Ok(false)
    }
}

#[cfg(windows)]
mod registry {
    use std::io;
    use std::path::Path;

    use windows_sys::Win32::Foundation::{ERROR_FILE_NOT_FOUND, ERROR_SUCCESS, WIN32_ERROR};
    use windows_sys::Win32::System::Registry::{
        HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_DWORD, REG_SZ,
        RRF_RT_REG_DWORD, RRF_RT_REG_SZ, RegCloseKey, RegGetValueW, RegOpenKeyExW, RegSetValueExW,
    };

    use super::{display_version, names_dir, version_numbers};
    use crate::version::Version;

    pub(super) fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }

    fn check(status: WIN32_ERROR) -> io::Result<()> {
        if status == ERROR_SUCCESS {
            Ok(())
        } else {
            Err(io::Error::from_raw_os_error(status as i32))
        }
    }

    struct Key(HKEY);

    impl Drop for Key {
        fn drop(&mut self) {
            // SAFETY: closes the handle `RegOpenKeyExW` returned, once.
            unsafe { RegCloseKey(self.0) };
        }
    }

    impl Key {
        /// An existing key; `None` when there is none. Never creates one.
        fn open(subkey: &str) -> io::Result<Option<Self>> {
            let mut handle: HKEY = std::ptr::null_mut();
            // SAFETY: `subkey` is NUL-terminated and `handle` receives the key.
            let status = unsafe {
                RegOpenKeyExW(
                    HKEY_CURRENT_USER,
                    wide(subkey).as_ptr(),
                    0,
                    KEY_QUERY_VALUE | KEY_SET_VALUE,
                    &mut handle,
                )
            };
            if status == ERROR_FILE_NOT_FOUND {
                return Ok(None);
            }
            check(status)?;
            Ok(Some(Self(handle)))
        }

        fn string(&self, name: &str) -> io::Result<Option<String>> {
            let name = wide(name);
            let mut size = 0u32;
            // SAFETY: the first call asks for the size in bytes; the second
            // fills a buffer of at least that size.
            unsafe {
                let status = RegGetValueW(
                    self.0,
                    std::ptr::null(),
                    name.as_ptr(),
                    RRF_RT_REG_SZ,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut size,
                );
                if status == ERROR_FILE_NOT_FOUND {
                    return Ok(None);
                }
                check(status)?;
                let mut buffer = vec![0u16; (size as usize).div_ceil(2)];
                check(RegGetValueW(
                    self.0,
                    std::ptr::null(),
                    name.as_ptr(),
                    RRF_RT_REG_SZ,
                    std::ptr::null_mut(),
                    buffer.as_mut_ptr().cast(),
                    &mut size,
                ))?;
                buffer.truncate(size as usize / 2);
                while buffer.last() == Some(&0) {
                    buffer.pop();
                }
                Ok(Some(String::from_utf16_lossy(&buffer)))
            }
        }

        fn has_dword(&self, name: &str) -> bool {
            // SAFETY: with no buffer, only checks that a DWORD value exists.
            unsafe {
                RegGetValueW(
                    self.0,
                    std::ptr::null(),
                    wide(name).as_ptr(),
                    RRF_RT_REG_DWORD,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                ) == ERROR_SUCCESS
            }
        }

        fn set(&self, name: &str, kind: u32, data: &[u8]) -> io::Result<()> {
            // SAFETY: `data` is valid for the length passed.
            check(unsafe {
                RegSetValueExW(
                    self.0,
                    wide(name).as_ptr(),
                    0,
                    kind,
                    data.as_ptr(),
                    data.len() as u32,
                )
            })
        }
    }

    pub(super) fn record_version(subkey: &str, dir: &Path, version: &Version) -> io::Result<bool> {
        let Some(key) = Key::open(subkey)? else {
            return Ok(false);
        };
        let location = match key.string("InstallLocation")? {
            Some(location) => Some(location),
            None => key.string("Inno Setup: App Path")?,
        };
        if !location.is_some_and(|location| names_dir(&location, dir)) {
            return Ok(false);
        }
        let display = display_version(version);
        if key.string("DisplayVersion")?.as_deref() == Some(display.as_str()) {
            return Ok(false);
        }
        let text: Vec<u8> = wide(&display)
            .into_iter()
            .flat_map(u16::to_le_bytes)
            .collect();
        key.set("DisplayVersion", REG_SZ, &text)?;
        for (name, number) in version_numbers(version) {
            if key.has_dword(name) {
                key.set(name, REG_DWORD, &number.to_le_bytes())?;
            }
        }
        Ok(true)
    }

    #[cfg(test)]
    mod tests {
        use std::path::Path;

        use windows_sys::Win32::System::Registry::{
            HKEY_CURRENT_USER, REG_DWORD, REG_SZ, RRF_RT_REG_DWORD, RRF_RT_REG_SZ, RegDeleteTreeW,
            RegGetValueW, RegSetKeyValueW,
        };

        use super::{record_version, wide};
        use crate::version::Version;

        /// A scratch key under HKEY_CURRENT_USER\Software, deleted on drop.
        struct Scratch(String);

        impl Scratch {
            fn new(name: &str) -> Self {
                let key = Self(format!(
                    r"Software\LokalBot-update-test-{}-{name}",
                    std::process::id()
                ));
                drop_tree(&key.0);
                key
            }

            fn set_string(&self, name: &str, value: &str) {
                let data = wide(value);
                // SAFETY: creates the key if needed and writes a
                // NUL-terminated UTF-16 string of the size passed in bytes.
                let status = unsafe {
                    RegSetKeyValueW(
                        HKEY_CURRENT_USER,
                        wide(&self.0).as_ptr(),
                        wide(name).as_ptr(),
                        REG_SZ,
                        data.as_ptr().cast(),
                        (data.len() * 2) as u32,
                    )
                };
                assert_eq!(status, 0);
            }

            fn set_dword(&self, name: &str, value: u32) {
                // SAFETY: writes one DWORD.
                let status = unsafe {
                    RegSetKeyValueW(
                        HKEY_CURRENT_USER,
                        wide(&self.0).as_ptr(),
                        wide(name).as_ptr(),
                        REG_DWORD,
                        (&value as *const u32).cast(),
                        4,
                    )
                };
                assert_eq!(status, 0);
            }

            fn string(&self, name: &str) -> String {
                let mut buffer = vec![0u16; 512];
                let mut size = (buffer.len() * 2) as u32;
                // SAFETY: reads a string into a buffer of the size passed.
                let status = unsafe {
                    RegGetValueW(
                        HKEY_CURRENT_USER,
                        wide(&self.0).as_ptr(),
                        wide(name).as_ptr(),
                        RRF_RT_REG_SZ,
                        std::ptr::null_mut(),
                        buffer.as_mut_ptr().cast(),
                        &mut size,
                    )
                };
                assert_eq!(status, 0, "{name}");
                buffer.truncate(size as usize / 2 - 1);
                String::from_utf16(&buffer).unwrap()
            }

            fn dword(&self, name: &str) -> Option<u32> {
                let mut value = 0u32;
                let mut size = 4u32;
                // SAFETY: reads one DWORD.
                let status = unsafe {
                    RegGetValueW(
                        HKEY_CURRENT_USER,
                        wide(&self.0).as_ptr(),
                        wide(name).as_ptr(),
                        RRF_RT_REG_DWORD,
                        std::ptr::null_mut(),
                        (&mut value as *mut u32).cast(),
                        &mut size,
                    )
                };
                (status == 0).then_some(value)
            }

            fn exists(&self) -> bool {
                super::Key::open(&self.0).unwrap().is_some()
            }
        }

        impl Drop for Scratch {
            fn drop(&mut self) {
                drop_tree(&self.0);
            }
        }

        fn drop_tree(subkey: &str) {
            // SAFETY: deletes a key this test created; a missing key is fine.
            unsafe { RegDeleteTreeW(HKEY_CURRENT_USER, wide(subkey).as_ptr()) };
        }

        #[test]
        fn updates_only_the_installers_entry_for_this_folder() {
            let dir = Path::new(r"C:\Users\someone\AppData\Local\Programs\LokalBot");
            let version = Version::new(0, 11, 1);

            let missing = Scratch::new("missing");
            assert!(!record_version(&missing.0, dir, &version).unwrap());
            assert!(!missing.exists(), "a missing entry is never created");

            let other = Scratch::new("other");
            other.set_string("InstallLocation", r"C:\Elsewhere\LokalBot\");
            other.set_string("DisplayVersion", "0.11.0");
            assert!(!record_version(&other.0, dir, &version).unwrap());
            assert_eq!(other.string("DisplayVersion"), "0.11.0");

            let ours = Scratch::new("ours");
            ours.set_string(
                "InstallLocation",
                r"c:\users\someone\appdata\local\programs\lokalbot\",
            );
            ours.set_string("DisplayVersion", "0.11.0");
            ours.set_dword("MajorVersion", 0);
            ours.set_dword("MinorVersion", 11);
            assert!(record_version(&ours.0, dir, &Version::new(1, 2, 3)).unwrap());
            assert_eq!(ours.string("DisplayVersion"), "1.2.3");
            assert_eq!(ours.dword("MajorVersion"), Some(1));
            assert_eq!(ours.dword("MinorVersion"), Some(2));
            assert_eq!(
                ours.dword("VersionMajor"),
                None,
                "absent values stay absent"
            );
            assert!(
                !record_version(&ours.0, dir, &Version::new(1, 2, 3)).unwrap(),
                "an entry already at this version is left alone"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_key_matches_the_installers_app_id() {
        let script = include_str!("../../../packaging/windows/lokalbot.iss");
        let app_id = script
            .lines()
            .find_map(|line| line.strip_prefix("AppId="))
            .expect("lokalbot.iss sets AppId");
        // Inno Setup writes a literal `{` as `{{`.
        assert_eq!(app_id.replacen("{{", "{", 1), APP_ID);
        assert_eq!(
            UNINSTALL_KEY,
            format!(r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{APP_ID}_is1")
        );
    }

    #[test]
    fn values_follow_inno_setups_app_version() {
        let version = Version::new(0, 11, 1);
        assert_eq!(display_version(&version), "0.11.1");
        assert_eq!(
            version_numbers(&version),
            [
                ("MajorVersion", 0),
                ("MinorVersion", 11),
                ("VersionMajor", 0),
                ("VersionMinor", 11),
            ]
        );
        assert!(version_numbers(&Version::new(u64::MAX, 0, 0)).is_empty());
    }

    #[test]
    fn install_location_names_the_folder_however_it_is_spelled() {
        let dir = Path::new(r"C:\Users\someone\AppData\Local\Programs\LokalBot");
        for location in [
            r"C:\Users\someone\AppData\Local\Programs\LokalBot\",
            r"C:\Users\someone\AppData\Local\Programs\LokalBot",
            r"c:\users\someone\appdata\local\programs\lokalbot\",
            r"\\?\C:\Users\someone\AppData\Local\Programs\LokalBot\",
            "C:/Users/someone/AppData/Local/Programs/LokalBot/",
        ] {
            assert!(names_dir(location, dir), "{location}");
        }
        for location in [
            "",
            r"\",
            r"C:\Users\someone\AppData\Local\Programs\LokalBot2\",
            r"C:\Users\someone\Downloads\LokalBot-0.11.0-windows-x86_64\",
        ] {
            assert!(!names_dir(location, dir), "{location}");
        }
    }

    #[test]
    fn other_platforms_write_nothing() {
        if !cfg!(windows) {
            let dir = Path::new("/home/someone/.local/share/lokalbot");
            assert!(!record_version(dir, &Version::new(0, 11, 1)).unwrap());
        }
    }
}
