//! What LokalBot needs from this computer (`AppControlHandler.permissionNeeds`,
//! `PermissionRow.swift`). Linux and Windows have no permission prompts like
//! macOS, so each entry says what this desktop allows instead, read the way
//! setup reads it (`crate::access`), so Settings, setup and `lokalbot-cli
//! permissions` say the same. Shared by Settings and `lokalbot-cli permissions`.

use gpui_kit::{App, Entity};
use lokalbot_core::{ScreenContextMode, Settings};
use lokalbot_engine::CalendarStatus;

use crate::access::{Observed, Permission, Probe, State};
use crate::state::{AppData, SettingsCategory};

/// What the person can do about a permission here, if anything.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fix {
    /// Windows' own switch (Privacy & security → Microphone).
    SystemSettings,
    /// The calendar links under Meetings.
    CalendarLinks,
    /// GNOME's Window Calls extension, for the window in front.
    WindowCalls,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PermissionNeed {
    /// `microphone`, `accessibility`, …, as `permissions request` takes them.
    pub name: &'static str,
    pub title: String,
    /// Allowed now. False both when it isn't and when that can't be known.
    pub granted: bool,
    /// False where nothing can be read before the feature first runs.
    pub checked: bool,
    /// The enabled features that need it.
    pub needed_by: Vec<String>,
    /// What this desktop allows.
    pub detail: String,
    pub fix: Option<Fix>,
}

impl PermissionNeed {
    /// A feature that is on uses it, and it is known not to be allowed.
    pub fn missing(&self) -> bool {
        self.checked && !self.granted && !self.needed_by.is_empty()
    }
}

/// Everything the needs are worked out from, read from the app.
#[derive(Clone, Debug, Default)]
pub struct Inputs {
    pub settings: Settings,
    pub probe: Probe,
    pub observed: Observed,
    pub linux: bool,
    pub windows: bool,
    /// Autocomplete reads other apps through the input method, not
    /// accessibility (Linux on Wayland).
    pub autocomplete_by_input_method: bool,
    pub shortcuts_ready: bool,
    pub calendar_ok: bool,
}

pub fn needs(data: &AppData, cx: &App) -> Vec<PermissionNeed> {
    needs_from(&Inputs {
        settings: data.settings.clone(),
        probe: data.access,
        observed: data.access_observed(),
        linux: cfg!(target_os = "linux"),
        windows: cfg!(target_os = "windows"),
        autocomplete_by_input_method: cfg!(target_os = "linux")
            && lokalbot_platform::session::is_wayland(),
        shortcuts_ready: crate::desktop::desktop(cx).is_none_or(|d| d.shortcuts_ready()),
        calendar_ok: !matches!(
            data.calendar.status,
            CalendarStatus::NoSources | CalendarStatus::Failed
        ),
    })
}

pub fn needs_from(inputs: &Inputs) -> Vec<PermissionNeed> {
    let settings = &inputs.settings;
    let mode = settings.screen_context_capture_mode;
    let tracking = settings.tracking_enabled;
    let captures_text = tracking && mode != ScreenContextMode::ActivityOnly;
    let captures_pixels = tracking && mode == ScreenContextMode::TextAndVisual;
    let tr = |key: &str| lokalbot_i18n::tr(key).to_string();

    let mut microphone = vec![tr("Meetings")];
    let mut window_titles = Vec::new();
    let mut accessibility = Vec::new();
    let mut screen = Vec::new();
    let mut key = Vec::new();
    let mut input = Vec::new();
    if tracking {
        window_titles.push(tr("Screen & activity"));
    }
    if captures_text {
        accessibility.push(tr("Screen & activity"));
    }
    if captures_pixels {
        screen.push(tr("Screen images"));
        key.push(tr("Screen images"));
    }
    if settings.dictation_enabled {
        microphone.push(tr("Dictation"));
        input.push(tr("Dictation"));
    }
    if settings.cotyping_enabled && !inputs.autocomplete_by_input_method {
        accessibility.push(tr("Autocomplete"));
    }
    if settings.quick_recall_enabled {
        input.push(tr("Ask anywhere"));
    }
    if settings.selection_actions_enabled {
        input.push(tr("Selection actions"));
    }

    // Read the way setup reads it, so the two never disagree.
    let shared = |permission: Permission, needed_by: Vec<String>, about: Option<String>| {
        let state = permission.state(&inputs.probe, &inputs.observed, inputs.linux);
        let fix = match (permission, state) {
            (Permission::Microphone, _) if inputs.windows => Some(Fix::SystemSettings),
            (
                Permission::WindowTitles,
                State::Missing(lokalbot_platform::access::Gap::GnomeWindowExtension),
            ) => Some(Fix::WindowCalls),
            _ => None,
        };
        PermissionNeed {
            name: permission.name(),
            title: permission.title().to_string(),
            granted: state == State::Allowed,
            checked: state != State::Unchecked,
            needed_by,
            detail: permission
                .note(state)
                .map(str::to_string)
                .or(about)
                .unwrap_or_else(|| permission.reason().to_string()),
            fix,
        }
    };

    vec![
        shared(Permission::Microphone, microphone, None),
        shared(Permission::WindowTitles, window_titles, None),
        shared(Permission::Accessibility, accessibility, None),
        shared(
            Permission::Screenshots,
            screen,
            Some(tr("This desktop lets LokalBot capture the active window.")),
        ),
        // It keeps more than the screenshot key here.
        shared(
            Permission::CredentialStore,
            key,
            Some(tr(
                "Keeps the key for screen images, private calendar links, and server keys.",
            )),
        ),
        PermissionNeed {
            name: "input-monitoring",
            title: tr("Global shortcuts"),
            granted: inputs.shortcuts_ready,
            checked: true,
            needed_by: input,
            detail: if inputs.shortcuts_ready {
                tr("This desktop lets LokalBot register system-wide shortcuts.")
            } else {
                tr(
                    "This desktop did not let LokalBot register system-wide shortcuts. Bind `lokalbot dictate` or `lokalbot quick-recall` to keys in your desktop's settings instead.",
                )
            },
            fix: None,
        },
        PermissionNeed {
            name: "calendar",
            title: tr("Calendar"),
            granted: inputs.calendar_ok,
            // No calendar is read while calendar use is off.
            checked: settings.calendar_detection_enabled,
            needed_by: if settings.calendar_detection_enabled {
                vec![tr("Calendar detection")]
            } else {
                Vec::new()
            },
            detail: tr("Reads the private calendar links you add under Settings → Meetings."),
            fix: Some(Fix::CalendarLinks),
        },
    ]
}

/// Shows the person where they can decide: the system's own switch where it
/// has one, GNOME's Window Calls extension when that is what's missing,
/// otherwise the row in Settings that says what this desktop allows.
pub fn request(name: &str, data: &Entity<AppData>, cx: &mut App) {
    if cfg!(target_os = "windows") && name == "microphone" {
        cx.open_url("ms-settings:privacy-microphone");
        return;
    }
    if name == Permission::WindowTitles.name()
        && needs(data.read(cx), cx)
            .iter()
            .any(|need| need.name == name && need.fix == Some(Fix::WindowCalls))
    {
        cx.open_url(crate::access::WINDOW_CALLS_URL);
        return;
    }
    let (category, focus) = if name == "calendar" {
        (SettingsCategory::Meetings, "settings.calendarLinks")
    } else {
        (SettingsCategory::Privacy, "settings.permissions")
    };
    data.update(cx, |data, cx| {
        data.open_settings(category, cx);
        data.settings_focus = Some(focus.to_string());
        cx.notify();
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_platform::access::{Check, Gap};

    fn inputs(probe: Probe) -> Inputs {
        let settings = Settings {
            tracking_enabled: true,
            screen_context_capture_mode: ScreenContextMode::TextAndVisual,
            ..Settings::default()
        };
        Inputs {
            settings,
            probe,
            linux: true,
            shortcuts_ready: true,
            calendar_ok: true,
            ..Inputs::default()
        }
    }

    fn need<'a>(needs: &'a [PermissionNeed], name: &str) -> &'a PermissionNeed {
        needs.iter().find(|need| need.name == name).unwrap()
    }

    const SHARED: [Permission; 5] = [
        Permission::Microphone,
        Permission::WindowTitles,
        Permission::Accessibility,
        Permission::Screenshots,
        Permission::CredentialStore,
    ];

    /// Every permission setup asks about is read from the same check here,
    /// whatever that check says.
    #[test]
    fn settings_reads_each_permission_as_setup_does() {
        let checks = [
            Check::Ready,
            Check::TurnedOff,
            Check::Missing(Gap::GnomeWindowExtension),
            Check::Missing(Gap::CredentialStore),
            Check::Unknown,
        ];
        for check in checks {
            let probe = Probe {
                microphone: check,
                window_titles: check,
                screen_text: check,
                screenshots: check,
                credential_store: check,
            };
            let input = inputs(probe);
            let needs = needs_from(&input);
            for permission in SHARED {
                let state = permission.state(&probe, &input.observed, true);
                let row = need(&needs, permission.name());
                let case = format!("{permission:?} {check:?}");
                assert_eq!(row.granted, state == State::Allowed, "{case}");
                assert_eq!(row.checked, state != State::Unchecked, "{case}");
                assert_eq!(
                    row.missing(),
                    matches!(state, State::TurnedOff | State::Missing(_)),
                    "{case}"
                );
                assert_eq!(row.title, permission.title(), "{case}");
            }
        }
    }

    #[test]
    fn an_unknown_state_is_never_claimed_either_way() {
        let needs = needs_from(&inputs(Probe::default()));
        for permission in SHARED {
            let row = need(&needs, permission.name());
            assert!(
                !row.granted && !row.checked && !row.missing(),
                "{permission:?}"
            );
        }
        // The microphone says when it is checked instead; Windows also names
        // its own privacy switch.
        let expected = if cfg!(target_os = "windows") {
            "Checked when you first record. Windows keeps its own switch under Privacy & security → Microphone."
        } else {
            "Checked when you first record."
        };
        assert_eq!(
            need(&needs, "microphone").detail,
            lokalbot_i18n::tr(expected)
        );
    }

    #[test]
    fn problems_carry_setups_words_and_fixes() {
        let probe = Probe {
            microphone: Check::TurnedOff,
            window_titles: Check::Missing(Gap::GnomeWindowExtension),
            screen_text: Check::Missing(Gap::AccessibilityService),
            ..Probe::default()
        };
        let mut input = inputs(probe);
        input.windows = true;
        input.linux = false;
        let needs = needs_from(&input);
        let microphone = need(&needs, "microphone");
        assert!(microphone.missing());
        assert_eq!(microphone.fix, Some(Fix::SystemSettings));
        let titles = need(&needs, "window-titles");
        assert_eq!(titles.fix, Some(Fix::WindowCalls));
        assert_eq!(
            titles.detail,
            crate::access::gap_text(Gap::GnomeWindowExtension)
        );
        assert_eq!(
            need(&needs, "accessibility").detail,
            crate::access::gap_text(Gap::AccessibilityService)
        );
        // Off Windows the microphone has no switch to open.
        input.windows = false;
        assert_eq!(need(&needs_from(&input), "microphone").fix, None);
    }

    #[test]
    fn needs_follow_the_features_that_are_on() {
        let ready = Probe {
            microphone: Check::Ready,
            window_titles: Check::Ready,
            screen_text: Check::Missing(Gap::AccessibilityService),
            screenshots: Check::Ready,
            credential_store: Check::Ready,
        };
        let mut input = inputs(ready);
        input.settings.tracking_enabled = false;
        input.settings.cotyping_enabled = false;
        let needs = needs_from(&input);
        for name in [
            "window-titles",
            "accessibility",
            "screen-recording",
            "credential-store",
        ] {
            assert!(need(&needs, name).needed_by.is_empty(), "{name}");
        }
        // Text capture and autocomplete on X11 read through accessibility.
        input.settings.tracking_enabled = true;
        input.settings.screen_context_capture_mode = ScreenContextMode::Text;
        input.settings.cotyping_enabled = true;
        let needs = needs_from(&input);
        assert_eq!(need(&needs, "accessibility").needed_by.len(), 2);
        assert!(need(&needs, "accessibility").missing());
        assert!(need(&needs, "screen-recording").needed_by.is_empty());
        // On Wayland autocomplete goes through the input method instead.
        input.autocomplete_by_input_method = true;
        input.settings.tracking_enabled = false;
        assert!(!need(&needs_from(&input), "accessibility").missing());
    }

    #[test]
    fn a_failed_screenshot_key_marks_screen_images_missing() {
        let mut input = inputs(Probe {
            screenshots: Check::Ready,
            credential_store: Check::Ready,
            ..Probe::default()
        });
        input.observed.key_failed = true;
        let needs = needs_from(&input);
        assert!(need(&needs, "credential-store").missing());
        assert!(!need(&needs, "screen-recording").missing());
    }
}
