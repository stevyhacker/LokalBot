//! What LokalBot needs from this computer (`AppControlHandler.permissionNeeds`,
//! `PermissionRow.swift`). Linux and Windows have no permission prompts like
//! macOS, so each entry says what this desktop allows instead. Shared by Settings
//! and `lokalbot-cli permissions`.

use gpui_kit::{App, Entity};
use lokalbot_core::ScreenContextMode;
use lokalbot_engine::CalendarStatus;
use lokalbot_platform::autocomplete::Support;

use crate::state::{AppData, SettingsCategory};

pub struct PermissionNeed {
    /// `microphone`, `accessibility`, …, as `permissions request` takes them.
    pub name: &'static str,
    pub title: String,
    pub granted: bool,
    /// The enabled features that need it.
    pub needed_by: Vec<String>,
    /// What this desktop allows.
    pub detail: String,
}

pub fn needs(data: &AppData, cx: &App) -> Vec<PermissionNeed> {
    let settings = &data.settings;
    let mode = settings.screen_context_capture_mode;
    let captures_text = mode != ScreenContextMode::ActivityOnly;
    let captures_pixels = mode == ScreenContextMode::TextAndVisual;
    let tr = |key: &str| lokalbot_i18n::tr(key).to_string();

    let mut microphone = vec![tr("Meeting recording")];
    let mut accessibility = Vec::new();
    let mut screen = Vec::new();
    let mut input = Vec::new();
    if settings.tracking_enabled || captures_text {
        accessibility.push(tr("Day Memory"));
    }
    if captures_pixels {
        screen.push(tr("Screen images"));
    }
    if settings.dictation_enabled {
        microphone.push(tr("Dictation"));
        input.push(tr("Dictation"));
    }
    if settings.cotyping_enabled {
        accessibility.push(tr("Autocomplete"));
    }
    if settings.quick_recall_enabled {
        input.push(tr("Ask anywhere"));
    }
    if settings.selection_actions_enabled {
        input.push(tr("Selection actions"));
    }

    let autocomplete = lokalbot_platform::autocomplete::support();
    let text_limit =
        data.screen
            .text_limitation
            .clone()
            .or(match (&autocomplete, settings.cotyping_enabled) {
                (Support::Unavailable(reason), true) => Some(reason.clone()),
                _ => None,
            });
    let shortcuts_ready = crate::desktop::desktop(cx).is_none_or(|d| d.shortcuts_ready());
    let calendar_ok = !matches!(
        data.calendar.status,
        CalendarStatus::NoSources | CalendarStatus::Failed
    );
    let on_windows = cfg!(target_os = "windows");
    vec![
        PermissionNeed {
            name: "microphone",
            title: tr("Microphone"),
            granted: true,
            needed_by: microphone,
            detail: if on_windows {
                tr("Checked when you first record. Windows keeps its own switch under Privacy & security → Microphone.")
            } else {
                tr("Checked when you first record.")
            },
        },
        PermissionNeed {
            name: "accessibility",
            title: tr("Accessibility"),
            granted: text_limit.is_none(),
            needed_by: accessibility,
            detail: text_limit.unwrap_or_else(|| {
                if on_windows {
                    tr("Reads the focused app and window title. Windows needs no extra permission for this.")
                } else {
                    tr("Reads the focused app and window title from the X11 session. No extra permission is needed.")
                }
            }),
        },
        PermissionNeed {
            name: "screen-recording",
            title: tr("Screen Recording"),
            granted: data.screen.capture_limitation.is_none(),
            needed_by: screen,
            detail: data
                .screen
                .capture_limitation
                .clone()
                .unwrap_or_else(|| tr("This desktop lets LokalBot capture the active window.")),
        },
        PermissionNeed {
            name: "input-monitoring",
            title: tr("Global shortcuts"),
            granted: shortcuts_ready,
            needed_by: input,
            detail: if shortcuts_ready {
                tr("This desktop lets LokalBot register system-wide shortcuts.")
            } else {
                tr("This desktop did not let LokalBot register system-wide shortcuts. Bind `lokalbot dictate` or `lokalbot quick-recall` to keys in your desktop's settings instead.")
            },
        },
        PermissionNeed {
            name: "calendar",
            title: tr("Calendar"),
            granted: calendar_ok,
            needed_by: if settings.calendar_detection_enabled {
                vec![tr("Calendar detection")]
            } else {
                Vec::new()
            },
            detail: tr("Reads the private calendar links you add under Settings → Meetings."),
        },
    ]
}

/// Shows the person where they can decide: the system's own switch where it
/// has one, otherwise the row in Settings that says what this desktop allows.
pub fn request(name: &str, data: &Entity<AppData>, cx: &mut App) {
    if cfg!(target_os = "windows") && name == "microphone" {
        cx.open_url("ms-settings:privacy-microphone");
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
