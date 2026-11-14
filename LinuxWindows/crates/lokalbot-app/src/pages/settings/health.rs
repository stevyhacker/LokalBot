//! Advanced → Memory health (`MemoryHealthSection.swift`): one operational view
//! across activity, screen context, meeting audio, processing, retention and
//! routines, plus the health check and Export Diagnostics.

use chrono::{Local, Utc};
use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::Button;
use gpui_kit::component::v_flex;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, IntoElement as _,
    ParentElement as _, SharedString, Styled as _, div, px,
};
use lokalbot_core::ScreenContextMode;

use super::models::size_label;
use super::routines::relative_time;
use super::{Section, SettingsPage};
use crate::i18n::h_flex;
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// How a value reads at a glance: running as intended, needing the person,
/// deliberately off or waiting, or a plain measurement.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    Good,
    Attention,
    Idle,
    Neutral,
}

impl Tone {
    /// Status strings outside both lists are unexpected, so they ask for a look.
    fn status(value: &str, good: &[&str], idle: &[&str]) -> Self {
        if good.contains(&value) {
            Self::Good
        } else if idle.contains(&value) {
            Self::Idle
        } else {
            Self::Attention
        }
    }

    /// Only live input is good; quiet states between meetings are idle; stalls,
    /// recovery, degradation and a missing track need a look.
    fn audio(status: &str) -> Self {
        Self::status(
            status,
            &["Receiving audio"],
            &["Idle", "Silent", "Waiting for audio"],
        )
    }
}

/// One row of the table.
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub title: &'static str,
    pub icon: Ico,
    pub value: String,
    pub detail: Option<String>,
    pub tone: Tone,
}

fn when(at: Option<chrono::DateTime<Utc>>) -> Option<String> {
    at.map(relative_time)
}

fn activity_status(tracking: bool, paused: bool) -> &'static str {
    if !tracking {
        "Off"
    } else if paused {
        "Paused"
    } else {
        "Healthy"
    }
}

/// `missingPermissions`: Linux and Windows have no permission prompts, so this is
/// what this desktop can't do for the features that are on: seeing the window in
/// front, capturing it, reading text over the accessibility bus or UI Automation,
/// global shortcuts, and the credential store that keeps the screen image key,
/// as Privacy & permissions and setup read them.
fn missing_capabilities(data: &AppData, cx: &App) -> Vec<String> {
    crate::control::permissions::needs(data, cx)
        .into_iter()
        .filter(|need| need.name != "calendar" && need.missing())
        .map(|need| need.title)
        .collect()
}

/// The Permissions row, from what this desktop is missing.
fn permissions_item(missing: &[String]) -> Item {
    Item {
        title: "Permissions",
        icon: Ico::ShieldCheck,
        value: if missing.is_empty() {
            "Healthy".to_string()
        } else {
            lokalbot_i18n::format("{0} needed", &[("0", missing.len().to_string())])
        },
        detail: Some(if missing.is_empty() {
            lokalbot_i18n::tr("This desktop supports every enabled feature").to_string()
        } else {
            missing.join(", ")
        }),
        tone: if missing.is_empty() {
            Tone::Good
        } else {
            Tone::Attention
        },
    }
}

/// The capture rows from what the engine reports.
pub fn capture_items(
    data: &AppData,
    missing: &[String],
    latest_activity: Option<chrono::DateTime<chrono::Utc>>,
) -> Vec<Item> {
    let settings = &data.settings;
    let screen = &data.screen;
    let paused = data.day_memory_paused;
    let tracking = settings.tracking_enabled;
    let activity = activity_status(tracking, paused);
    let captures_text =
        tracking && settings.screen_context_capture_mode != ScreenContextMode::ActivityOnly;
    let text = if !captures_text {
        "Off"
    } else if paused {
        "Paused"
    } else if screen.text_limitation.is_some() && screen.capture_limitation.is_some() {
        "Needs attention"
    } else {
        "Healthy"
    };
    let captures_pixels =
        tracking && settings.screen_context_capture_mode == ScreenContextMode::TextAndVisual;
    let visual = if !captures_pixels {
        "Off"
    } else if paused {
        "Paused"
    } else if screen.images_unavailable.is_some() || screen.capture_limitation.is_some() {
        "Text-only fallback"
    } else {
        "Encrypted"
    };
    let source = screen.last_text_source.as_deref();
    vec![
        Item {
            title: "Activity",
            icon: Ico::Clock,
            value: activity.into(),
            detail: when(latest_activity),
            tone: Tone::status(activity, &["Healthy"], &["Off", "Paused"]),
        },
        Item {
            title: "Accessible text",
            icon: Ico::ScanText,
            value: text.into(),
            detail: screen
                .text_limitation
                .clone()
                .or_else(|| when(screen.last_capture)),
            tone: Tone::status(text, &["Healthy"], &["Off", "Paused"]),
        },
        Item {
            title: "Visual context",
            icon: Ico::Camera,
            value: visual.into(),
            detail: screen
                .images_unavailable
                .clone()
                .or_else(|| screen.capture_limitation.clone()),
            tone: Tone::status(visual, &["Encrypted"], &["Off", "Paused"]),
        },
        Item {
            title: "Local OCR",
            icon: Ico::TextSearch,
            value: source.map_or_else(
                || "Waiting".to_string(),
                super::day_memory::text_source_label,
            ),
            detail: when(screen.last_capture),
            tone: if source.is_none() {
                Tone::Idle
            } else {
                Tone::Good
            },
        },
        permissions_item(missing),
    ]
}

/// The two tracks from the live statuses, "Idle" between meetings, and when a lost
/// track last came back.
pub fn audio_items(
    statuses: Option<&(SharedString, SharedString)>,
    last_recovery: Option<chrono::DateTime<Utc>>,
) -> Vec<Item> {
    let status = |value: Option<&SharedString>, prefix: &str| -> String {
        value
            .map(|text| {
                text.split_once(" · ")
                    .filter(|(label, _)| *label == prefix)
                    .map_or_else(|| text.to_string(), |(_, status)| status.to_string())
            })
            .unwrap_or_else(|| "Idle".to_string())
    };
    let microphone = status(statuses.map(|s| &s.0), "Mic");
    let system = status(statuses.map(|s| &s.1), "System");
    let mut items = vec![
        Item {
            title: "Your microphone",
            icon: Ico::Mic,
            tone: Tone::audio(&microphone),
            value: microphone,
            detail: None,
        },
        Item {
            title: "Other side (system audio)",
            icon: Ico::AudioLines,
            tone: Tone::audio(&system),
            value: system,
            detail: None,
        },
    ];
    if let Some(recovery) = last_recovery {
        items.push(Item {
            title: "Last audio recovery",
            icon: Ico::RefreshCw,
            value: relative_time(recovery),
            detail: Some(
                recovery
                    .with_timezone(&Local)
                    .format_localized(
                        lokalbot_i18n::date_pattern("%b %-d, %Y at %-I:%M:%S %p"),
                        lokalbot_i18n::date_locale(),
                    )
                    .to_string(),
            ),
            tone: Tone::Neutral,
        });
    }
    items
}

pub fn background_items(
    data: &AppData,
    storage: Option<(u64, Option<u64>)>,
    pending: usize,
) -> Vec<Item> {
    let busy = !data.processing.is_empty();
    let routines = &data.routines;
    let routine_value = if !data.settings.memory_routines_enabled {
        lokalbot_i18n::tr("Off").to_string()
    } else if let Some(kind) = routines.current.filter(|_| routines.is_running) {
        lokalbot_i18n::format(
            "Running {0}",
            &[("0", lokalbot_i18n::tr(kind.display_name()).to_string())],
        )
    } else {
        lokalbot_i18n::format(
            "{0} pending",
            &[("0", format!("{}", routines.pending_count()))],
        )
    };
    let retention_ok = data.retention.last_error.is_none();
    vec![
        Item {
            title: "Processing queue",
            icon: Ico::ListChecks,
            value: lokalbot_i18n::format("{0} pending", &[("0", format!("{pending}"))]),
            detail: Some(
                if busy {
                    lokalbot_i18n::tr("Processing now")
                } else {
                    lokalbot_i18n::tr("Idle")
                }
                .to_string(),
            ),
            tone: if busy { Tone::Good } else { Tone::Idle },
        },
        Item {
            title: "Routines",
            icon: Ico::Calendar,
            value: routine_value,
            detail: when(routines.last_run_at),
            tone: if data.settings.memory_routines_enabled && routines.is_running {
                Tone::Good
            } else {
                Tone::Idle
            },
        },
        Item {
            title: "Retention",
            icon: Ico::Trash,
            value: if retention_ok {
                "Healthy"
            } else {
                "Needs attention"
            }
            .into(),
            detail: when(data.retention.last_run),
            tone: if retention_ok {
                Tone::Good
            } else {
                Tone::Attention
            },
        },
        Item {
            title: "Local library",
            icon: Ico::HardDrive,
            value: storage.map_or_else(
                || lokalbot_i18n::tr("Calculating…").to_string(),
                |(total, _)| size_label(total),
            ),
            detail: storage
                .and_then(|(_, available)| available)
                .map(|available| {
                    lokalbot_i18n::format("{0} available", &[("0", size_label(available))])
                }),
            tone: Tone::Neutral,
        },
    ]
}

/// A value in a tone: a dot and a word, the word keeping its meaning without
/// color. Only states that need the person are emphasized.
fn status(item: &Item, cx: &App) -> AnyElement {
    let lb = cx.lb();
    let value = lokalbot_i18n::tr(&item.value).to_string();
    match item.tone {
        Tone::Neutral => div()
            .text_size(ty::SECONDARY)
            .font_weight(FontWeight::MEDIUM)
            .text_color(lb.text_secondary)
            .child(value)
            .into_any_element(),
        Tone::Attention => h_flex()
            .gap(px(6.))
            .items_center()
            .px(px(9.))
            .py(px(3.))
            .rounded_full()
            .bg(lb.attention_text.opacity(0.14))
            .child(ui::status_dot(lb.attention_text, px(7.)))
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.attention_text)
                    .child(value),
            )
            .into_any_element(),
        Tone::Good | Tone::Idle => h_flex()
            .gap(px(6.))
            .items_center()
            .child(ui::status_dot(
                if item.tone == Tone::Good {
                    lb.accent_text
                } else {
                    lb.text_tertiary
                },
                px(7.),
            ))
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(value),
            )
            .into_any_element(),
    }
}

fn table(id: &'static str, items: &[Item], cx: &App) -> AnyElement {
    let lb = cx.lb().clone();
    settings_row::content_row(
        id,
        v_flex()
            .w_full()
            .gap(px(9.))
            .children(items.iter().map(|item| {
                h_flex()
                    .w_full()
                    .gap(px(12.))
                    .items_center()
                    .child(ui::icon(item.icon, px(16.), lb.accent_text))
                    .child(
                        div()
                            .min_w(px(130.))
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(lokalbot_i18n::tr(item.title)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .children(item.detail.clone()),
                    )
                    .child(status(item, cx))
            })),
        false,
        cx,
    )
    .into_any_element()
}

/// One line that answers "is everything working?", and the button that starts
/// capture afresh.
fn summary(attention: &[&Item], data: Entity<AppData>, cx: &App) -> AnyElement {
    let lb = cx.lb().clone();
    let (title, detail): (String, String) = if attention.is_empty() {
        (
            lokalbot_i18n::tr("Memory capture is working").to_string(),
            lokalbot_i18n::tr("Capture, audio, and background work are running as configured.")
                .to_string(),
        )
    } else {
        let names: Vec<&str> = attention
            .iter()
            .map(|i| lokalbot_i18n::tr(i.title))
            .collect();
        (
            if attention.len() == 1 {
                lokalbot_i18n::tr("1 item needs attention").to_string()
            } else {
                lokalbot_i18n::format(
                    "{0} items need attention",
                    &[("0", format!("{}", attention.len()))],
                )
            },
            names.join(" · "),
        )
    };
    settings_row::content_row(
        "settings.memoryHealth.summary",
        h_flex()
            .gap(px(12.))
            .items_center()
            .child(ui::icon_tile(
                if attention.is_empty() {
                    Ico::BadgeCheck
                } else {
                    Ico::TriangleAlert
                },
                if attention.is_empty() {
                    lb.accent_text
                } else {
                    lb.attention_text
                },
                px(32.),
            ))
            .child(
                v_flex()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(detail),
                    ),
            )
            .child(div().flex_1())
            .child(
                Button::new("settings-restart-memory-capture")
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Restart memory capture"))
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| {
                            data.request(AppEvent::RestartMemoryCapture, cx)
                        })
                    }),
            ),
        false,
        cx,
    )
    .into_any_element()
}

/// Bytes in the library, and bytes free on its drive.
fn measure_storage(root: &std::path::Path) -> (u64, Option<u64>) {
    fn walk(directory: &std::path::Path, total: &mut u64) {
        let Ok(entries) = std::fs::read_dir(directory) else {
            return;
        };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_dir() {
                walk(&entry.path(), total);
            } else if kind.is_file() {
                *total += entry.metadata().map_or(0, |metadata| metadata.len());
            }
        }
    }
    let mut total = 0;
    walk(root, &mut total);
    (total, lokalbot_ai::download::free_space(root))
}

fn export_diagnostics(data: Entity<AppData>, cx: &mut App) {
    let directory = std::env::home_dir().unwrap_or_else(|| std::path::PathBuf::from("."));
    let name = format!(
        "LokalBot Diagnostics {}.zip",
        Local::now().date_naive().format("%Y-%m-%d")
    );
    let receiver = cx.prompt_for_new_path(&directory, Some(&name));
    let (library, settings) = {
        let state = data.read(cx);
        (state.library.clone(), state.settings.clone())
    };
    cx.spawn(async move |cx| {
        let Ok(Ok(Some(destination))) = receiver.await else {
            return;
        };
        let result = cx
            .background_spawn(async move {
                lokalbot_engine::diagnostics::export(&library, &settings, &destination)
            })
            .await;
        data.update(cx, |data, cx| match result {
            Ok(_) => data.show_message(lokalbot_i18n::tr("Diagnostics exported."), cx),
            Err(err) => data.show_error(
                lokalbot_i18n::format(
                    "Could not export diagnostics: {err}",
                    &[("err", format!("{err:#}"))],
                ),
                cx,
            ),
        });
    })
    .detach();
}

fn run_health_check(data: Entity<AppData>, cx: &mut App) {
    let (library, settings) = {
        let state = data.read(cx);
        (state.library.clone(), state.settings.clone())
    };
    cx.spawn(async move |cx| {
        let result = cx
            .background_spawn(
                async move { lokalbot_engine::health_check::run_now(&library, &settings) },
            )
            .await;
        match result {
            Ok(path) => {
                cx.update(|cx| cx.open_with_system(&path));
            }
            Err(err) => {
                data.update(cx, |data, cx| {
                    data.show_error(
                        lokalbot_i18n::format(
                            "The health check could not be saved: {err}",
                            &[("err", format!("{err:#}"))],
                        ),
                        cx,
                    )
                });
            }
        }
    })
    .detach();
}

const STORAGE_REFRESH: std::time::Duration = std::time::Duration::from_secs(30);

impl SettingsPage {
    fn refresh_storage(&mut self, cx: &mut Context<Self>) {
        if self
            .storage_measured_at
            .is_some_and(|at| at.elapsed() < STORAGE_REFRESH)
        {
            return;
        }
        self.storage_measured_at = Some(std::time::Instant::now());
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            // The page redraws on every engine event, several times a second
            // while recording, so what it shows from the database is read
            // here and not while drawing.
            let (measured, latest_activity, pending) = cx
                .background_spawn(async move {
                    (
                        measure_storage(library.paths().root()),
                        library.latest_activity_end().ok().flatten(),
                        library.pending_jobs().map_or(0, |jobs| jobs.len()),
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.storage = Some(measured);
                this.latest_activity = latest_activity;
                this.pending_jobs = pending;
                cx.notify();
            });
        })
        .detach();
    }

    pub(super) fn memory_health_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        self.refresh_storage(cx);
        let storage = self.storage;
        let data = self.data.read(cx);
        let missing = missing_capabilities(data, cx);
        let capture = capture_items(data, &missing, self.latest_activity);
        let audio = audio_items(data.recording_statuses.as_ref(), data.last_audio_recovery);
        let background = background_items(data, storage, self.pending_jobs);
        let active_error = data
            .screen
            .last_error
            .clone()
            .or_else(|| data.retention.last_error.clone())
            .or_else(|| data.routines.last_error.clone());
        let attention: Vec<&Item> = capture
            .iter()
            .chain(&audio)
            .chain(&background)
            .filter(|item| item.tone == Tone::Attention)
            .collect();
        let health = Section::new(lokalbot_i18n::tr("Memory health"))
            .row(
                "settings.memoryHealth",
                summary(&attention, self.data.clone(), cx),
            )
            .row(
                "settings.memoryHealth.capture",
                table("settings.memoryHealth.capture", &capture, cx),
            );
        let meeting_audio = Section::new(lokalbot_i18n::tr("Meeting audio")).row(
            "settings.memoryHealth.audio",
            table("settings.memoryHealth.audio", &audio, cx),
        );
        let retention_data = self.data.clone();
        let mut work = Section::new(lokalbot_i18n::tr("Background work")).row(
            "settings.memoryHealth.background",
            table("settings.memoryHealth.background", &background, cx),
        );
        if let Some(error) = active_error {
            let lb = cx.lb().clone();
            work = work.row(
                "settings.memoryHealth.error",
                settings_row::content_row(
                    "settings.memoryHealth.error",
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(crate::ui::text::paragraph(error)),
                    false,
                    cx,
                ),
            );
        }
        work = work.row(
            "settings.runRetentionNow",
            settings_row::row(
                "settings.runRetentionNow",
                lokalbot_i18n::tr("Run retention now"),
                Some(lokalbot_i18n::tr("Meeting recording and autocomplete take priority over OCR, embeddings, and routines, which catch up when those tasks are idle.").into()),
                Button::new("settings-run-retention")
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Run retention now"))
                    .on_click(move |_, _, cx| {
                        retention_data.update(cx, |data, cx| {
                            data.request(AppEvent::RunRetentionNow, cx)
                        })
                    }),
                false,
                cx,
            ),
        );
        let export_data = self.data.clone();
        let check_data = self.data.clone();
        work = work.row(
            "settings.exportDiagnostics",
            settings_row::row(
                "settings.exportDiagnostics",
                lokalbot_i18n::tr("Export Diagnostics…"),
                Some(lokalbot_i18n::tr("Diagnostics include logs, health reports, settings without secrets, and library counts. Never meeting audio, transcripts, notes, or screenshots.").into()),
                h_flex()
                    .gap(px(8.))
                    .child(
                        Button::new("settings-export-diagnostics")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Export Diagnostics…"))
                            .on_click(move |_, _, cx| export_diagnostics(export_data.clone(), cx)),
                    )
                    .child(
                        Button::new("settings-run-health-check")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Run Health Check Now"))
                            .on_click(move |_, _, cx| run_health_check(check_data.clone(), cx)),
                    ),
                self.is_focused("settings.exportDiagnostics"),
                cx,
            ),
        );
        vec![health, meeting_audio, work]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn audio_tones_match_the_mac() {
        assert_eq!(Tone::audio("Receiving audio"), Tone::Good);
        assert_eq!(Tone::audio("Idle"), Tone::Idle);
        assert_eq!(Tone::audio("Not attached"), Tone::Attention);
    }

    #[test]
    fn the_permissions_row_says_what_this_desktop_is_missing() {
        let healthy = permissions_item(&[]);
        assert_eq!(healthy.value, "Healthy");
        assert_eq!(healthy.tone, Tone::Good);
        let missing = permissions_item(&["Screen Recording".into(), "Credential store".into()]);
        assert_eq!(missing.value, "2 needed");
        assert_eq!(missing.tone, Tone::Attention);
        assert_eq!(
            missing.detail.as_deref(),
            Some("Screen Recording, Credential store")
        );
    }

    #[test]
    fn the_last_recovery_shows_only_after_one() {
        assert_eq!(audio_items(None, None).len(), 2);
        let items = audio_items(None, Some(Utc::now()));
        assert_eq!(items.len(), 3);
        assert_eq!(items[2].title, "Last audio recovery");
        assert_eq!(items[2].tone, Tone::Neutral);
        assert!(items[2].detail.is_some());
    }

    #[test]
    fn audio_rows_read_the_recording_statuses() {
        let items = audio_items(None, None);
        assert_eq!(items[0].value, "Idle");
        assert_eq!(items[0].tone, Tone::Idle);
        let live: (SharedString, SharedString) = (
            "Mic · Receiving audio".into(),
            "System · Not attached".into(),
        );
        let items = audio_items(Some(&live), None);
        assert_eq!(items[0].value, "Receiving audio");
        assert_eq!(items[0].tone, Tone::Good);
        assert_eq!(items[1].value, "Not attached");
        assert_eq!(items[1].tone, Tone::Attention);
    }

    #[test]
    fn storage_adds_up_the_files_under_the_library() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("a/b")).unwrap();
        std::fs::write(dir.path().join("a/b/c"), [0u8; 10]).unwrap();
        std::fs::write(dir.path().join("d"), [0u8; 5]).unwrap();
        assert_eq!(measure_storage(dir.path()).0, 15);
    }
}
