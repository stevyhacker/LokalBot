#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PowerState {
    pub has_battery: bool,
    pub on_battery: bool,
    pub saving_power: bool,
    pub is_hot: bool,
}

pub fn current() -> PowerState {
    imp::current()
}

pub fn on_battery() -> bool {
    current().on_battery
}

#[cfg(windows)]
mod imp {
    use super::PowerState;
    use windows::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};

    const NO_BATTERY: u8 = 128;
    const UNKNOWN_BATTERY: u8 = 255;

    pub(super) fn current() -> PowerState {
        let mut status = SYSTEM_POWER_STATUS::default();
        if unsafe { GetSystemPowerStatus(&mut status) }.is_err() {
            return PowerState::default();
        }
        let has_battery =
            status.BatteryFlag & NO_BATTERY == 0 && status.BatteryFlag != UNKNOWN_BATTERY;
        PowerState {
            has_battery,
            on_battery: has_battery && status.ACLineStatus == 0,
            saving_power: status.SystemStatusFlag == 1,
            is_hot: false,
        }
    }
}

#[cfg(not(windows))]
mod imp {
    use super::PowerState;
    use std::path::{Path, PathBuf};

    fn read(path: &Path) -> Option<String> {
        Some(std::fs::read_to_string(path).ok()?.trim().to_string())
    }

    pub(super) fn current() -> PowerState {
        let (has_battery, on_battery) = battery_state(Path::new("/sys/class/power_supply"));
        PowerState {
            has_battery,
            on_battery,
            saving_power: saving_power(Path::new("/sys/firmware/acpi/platform_profile")),
            is_hot: is_hot(Path::new("/sys/class/thermal")),
        }
    }

    pub(super) fn battery_state(folder: &Path) -> (bool, bool) {
        let Ok(entries) = std::fs::read_dir(folder) else {
            return (false, false);
        };
        let (mut has_battery, mut discharging, mut plugged_in) = (false, false, false);
        for entry in entries.flatten() {
            let path = entry.path();
            let kind = read(&path.join("type")).unwrap_or_default();
            if read(&path.join("scope")).is_some_and(|s| s.eq_ignore_ascii_case("device")) {
                continue;
            }
            match kind.as_str() {
                "Battery" => {
                    has_battery = true;
                    discharging |= read(&path.join("status")).as_deref() == Some("Discharging");
                }
                "Mains" | "USB" | "USB_C" | "UPS"
                    if read(&path.join("online")).as_deref() == Some("1") =>
                {
                    plugged_in = true;
                }
                _ => {}
            }
        }
        (has_battery, has_battery && discharging && !plugged_in)
    }

    pub(super) fn saving_power(profile: &Path) -> bool {
        read(profile).is_some_and(|value| matches!(value.as_str(), "low-power" | "quiet"))
    }

    pub(super) fn is_hot(folder: &Path) -> bool {
        const FALLBACK_LIMIT: i64 = 90_000;
        let Ok(entries) = std::fs::read_dir(folder) else {
            return false;
        };
        for entry in entries.flatten() {
            let zone: PathBuf = entry.path();
            if !entry
                .file_name()
                .to_string_lossy()
                .starts_with("thermal_zone")
            {
                continue;
            }
            let Some(temperature) = read(&zone.join("temp")).and_then(|t| t.parse::<i64>().ok())
            else {
                continue;
            };
            let kind = read(&zone.join("type")).unwrap_or_default().to_lowercase();
            if !(kind.contains("cpu")
                || kind.contains("pkg")
                || kind.contains("acpi")
                || kind.contains("soc"))
            {
                continue;
            }
            let mut limit = None;
            for index in 0..16 {
                let Some(trip) = read(&zone.join(format!("trip_point_{index}_type"))) else {
                    break;
                };
                if trip == "passive"
                    && let Some(value) = read(&zone.join(format!("trip_point_{index}_temp")))
                        .and_then(|t| t.parse::<i64>().ok())
                    && value > 0
                {
                    limit = Some(limit.map_or(value, |known: i64| known.min(value)));
                }
            }
            if temperature >= limit.unwrap_or(FALLBACK_LIMIT) {
                return true;
            }
        }
        false
    }
}

#[cfg(all(test, not(windows)))]
mod tests {
    use super::imp::{battery_state, is_hot, saving_power};
    use std::fs;
    use std::path::Path;

    fn supply(root: &Path, name: &str, files: &[(&str, &str)]) {
        let dir = root.join(name);
        fs::create_dir_all(&dir).unwrap();
        for (file, value) in files {
            fs::write(dir.join(file), value).unwrap();
        }
    }

    #[test]
    fn a_desktop_has_no_battery() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(battery_state(dir.path()), (false, false));
        supply(dir.path(), "AC", &[("type", "Mains\n"), ("online", "1\n")]);
        assert_eq!(battery_state(dir.path()), (false, false));
    }

    #[test]
    fn a_mouse_battery_does_not_count() {
        let dir = tempfile::tempdir().unwrap();
        supply(
            dir.path(),
            "hidpp_battery_0",
            &[
                ("type", "Battery\n"),
                ("scope", "Device\n"),
                ("status", "Discharging\n"),
            ],
        );
        assert_eq!(battery_state(dir.path()), (false, false));
    }

    #[test]
    fn a_laptop_on_battery_and_on_a_charger() {
        let dir = tempfile::tempdir().unwrap();
        supply(
            dir.path(),
            "BAT0",
            &[("type", "Battery\n"), ("status", "Discharging\n")],
        );
        supply(dir.path(), "AC", &[("type", "Mains\n"), ("online", "0\n")]);
        assert_eq!(battery_state(dir.path()), (true, true));
        supply(dir.path(), "AC", &[("type", "Mains\n"), ("online", "1\n")]);
        assert_eq!(battery_state(dir.path()), (true, false));
        supply(dir.path(), "AC", &[("type", "Mains\n"), ("online", "0\n")]);
        supply(
            dir.path(),
            "BAT0",
            &[("type", "Battery\n"), ("status", "Charging\n")],
        );
        assert_eq!(battery_state(dir.path()), (true, false));
    }

    #[test]
    fn profiles_and_heat() {
        let dir = tempfile::tempdir().unwrap();
        let profile = dir.path().join("platform_profile");
        assert!(!saving_power(&profile));
        fs::write(&profile, "low-power\n").unwrap();
        assert!(saving_power(&profile));
        fs::write(&profile, "balanced\n").unwrap();
        assert!(!saving_power(&profile));

        supply(
            dir.path(),
            "thermal_zone0",
            &[
                ("type", "x86_pkg_temp\n"),
                ("temp", "70000\n"),
                ("trip_point_0_type", "passive\n"),
                ("trip_point_0_temp", "85000\n"),
            ],
        );
        assert!(!is_hot(dir.path()));
        supply(dir.path(), "thermal_zone0", &[("temp", "85000\n")]);
        assert!(is_hot(dir.path()));
        supply(dir.path(), "thermal_zone0", &[("temp", "60000\n")]);
        supply(
            dir.path(),
            "thermal_zone1",
            &[("type", "wifi\n"), ("temp", "95000\n")],
        );
        assert!(!is_hot(dir.path()));
        supply(
            dir.path(),
            "thermal_zone2",
            &[("type", "acpitz\n"), ("temp", "91000\n")],
        );
        assert!(is_hot(dir.path()));
    }
}
