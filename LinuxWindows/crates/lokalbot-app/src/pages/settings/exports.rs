//! Meeting note export and daily note export, each writing Markdown to a folder
//! the person picks (`SettingsView.meetingNoteExportSection`,
//! `dailyNoteExportSection`).

use gpui_kit::component::Sizable as _;
use gpui_kit::component::button::Button;
use gpui_kit::{App, Context, Entity, SharedString};
use lokalbot_core::Settings;
use lokalbot_core::settings::{DailyMemoryExportFormat, ExportFormat};

use super::{Section, SettingsPage, hour_label};
use crate::state::AppData;
use crate::ui::settings_row;

/// Asks for a folder and saves it with `set`. Backing out of the first choice
/// leaves the feature off through `cancelled`, as on the Mac.
pub(super) fn choose_folder(
    data: Entity<AppData>,
    prompt: &'static str,
    set: fn(&mut Settings, String),
    cancelled: Option<fn(&mut Settings)>,
    cx: &mut App,
) {
    let receiver = cx.prompt_for_paths(gpui_kit::PathPromptOptions {
        files: false,
        directories: true,
        multiple: false,
        prompt: Some(lokalbot_i18n::tr(prompt).into()),
    });
    cx.spawn(async move |cx| {
        let picked = receiver.await;
        data.update(cx, |data, cx| match picked {
            Ok(Ok(Some(paths))) => match paths.first().and_then(|path| path.to_str()) {
                Some(folder) => {
                    let folder = folder.to_string();
                    data.update_settings(|s| set(s, folder), cx);
                }
                None => {
                    if let Some(cancelled) = cancelled {
                        data.update_settings(cancelled, cx);
                    }
                }
            },
            Ok(Ok(None)) | Err(_) => {
                if let Some(cancelled) = cancelled {
                    data.update_settings(cancelled, cx);
                }
            }
            Ok(Err(err)) => {
                if let Some(cancelled) = cancelled {
                    data.update_settings(cancelled, cx);
                }
                data.show_error(
                    lokalbot_i18n::format(
                        "No file chooser is available: {err}",
                        &[("err", format!("{err:#}"))],
                    ),
                    cx,
                );
            }
        });
    })
    .detach();
}

/// A button that shows the folder's name and changes it.
pub(super) fn folder_button(
    id: &'static str,
    folder: &str,
    data: Entity<AppData>,
    prompt: &'static str,
    set: fn(&mut Settings, String),
) -> Button {
    let label: SharedString = std::path::Path::new(folder)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|_| !folder.is_empty())
        .unwrap_or_else(|| lokalbot_i18n::tr("Choose…").to_string())
        .into();
    Button::new(id)
        .outline()
        .small()
        .label(label)
        .on_click(move |_, _, cx| choose_folder(data.clone(), prompt, set, None, cx))
}

impl SettingsPage {
    pub(super) fn meeting_note_export_section(&mut self, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let data = self.data.clone();
        let mut section = Section::new(lokalbot_i18n::tr("Meeting note export")).row(
            "settings.meetingNoteExportEnabled",
            settings_row::row(
                "settings.meetingNoteExportEnabled",
                lokalbot_i18n::tr("Export a note for each meeting"),
                Some(lokalbot_i18n::tr("Writes one unencrypted Markdown note per meeting, including meetings already recorded, to a folder you choose, such as an Obsidian vault. Each note has the summary, action items as you corrected them, and the people and tracked projects involved. A note you edit, move, or delete is yours: LokalBot leaves it alone.").into()),
                settings_row::switch(
                    "settings.meetingNoteExportEnabled",
                    settings.meeting_note_export_enabled,
                    move |on, _, cx| {
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| s.meeting_note_export_enabled = on, cx)
                        });
                        if on && data.read(cx).settings.meeting_note_export_folder.is_empty() {
                            choose_folder(
                                data.clone(),
                                "Choose meeting note export folder",
                                |s, folder| s.meeting_note_export_folder = folder,
                                Some(|s| s.meeting_note_export_enabled = false),
                                cx,
                            );
                        }
                    },
                ),
                self.is_focused("settings.meetingNoteExportEnabled"),
                cx,
            ),
        );
        if settings.meeting_note_export_enabled {
            section = section
                .row(
                    "settings.meetingNoteExportFormat",
                    self.choice(
                        "settings.meetingNoteExportFormat",
                        lokalbot_i18n::tr("Format"),
                        None,
                        vec![
                            (ExportFormat::Markdown, "Markdown".into()),
                            (ExportFormat::Obsidian, "Obsidian".into()),
                            (ExportFormat::Logseq, "Logseq".into()),
                        ],
                        settings.meeting_note_export_format,
                        |s, v| s.meeting_note_export_format = v,
                        cx,
                    ),
                )
                .row(
                    "settings.meetingNoteExportIncludesTranscript",
                    self.toggle(
                        "settings.meetingNoteExportIncludesTranscript",
                        lokalbot_i18n::tr("Include the transcript"),
                        None,
                        settings.meeting_note_export_includes_transcript,
                        |s, v| s.meeting_note_export_includes_transcript = v,
                        cx,
                    ),
                )
                .row(
                    "settings.meetingNoteExportFolder",
                    settings_row::row(
                        "settings.meetingNoteExportFolder",
                        lokalbot_i18n::tr("Folder"),
                        None,
                        folder_button(
                            "settings-meeting-note-folder",
                            &settings.meeting_note_export_folder,
                            self.data.clone(),
                            "Choose meeting note export folder",
                            |s, folder| s.meeting_note_export_folder = folder,
                        ),
                        false,
                        cx,
                    ),
                );
        }
        section
    }

    pub(super) fn daily_note_export_section(&mut self, cx: &mut Context<Self>) -> Section {
        let settings = self.data.read(cx).settings.clone();
        let data = self.data.clone();
        let mut section = Section::new(lokalbot_i18n::tr("Daily note export")).row(
            "settings.dailyMemoryExportEnabled",
            settings_row::row(
                "settings.dailyMemoryExportEnabled",
                lokalbot_i18n::tr("Export a daily memory note"),
                Some(lokalbot_i18n::tr("Writes one unencrypted Markdown file per day with the digest, meeting links, app time, and saved moments. A day missed while your computer was asleep is written later. Existing non-LokalBot content is never overwritten.").into()),
                settings_row::switch(
                    "settings.dailyMemoryExportEnabled",
                    settings.daily_memory_export_enabled,
                    move |on, _, cx| {
                        data.update(cx, |data, cx| {
                            data.update_settings(|s| s.daily_memory_export_enabled = on, cx)
                        });
                        if on && data.read(cx).settings.daily_memory_export_folder.is_empty() {
                            choose_folder(
                                data.clone(),
                                "Choose daily note export folder",
                                |s, folder| s.daily_memory_export_folder = folder,
                                Some(|s| s.daily_memory_export_enabled = false),
                                cx,
                            );
                        }
                    },
                ),
                self.is_focused("settings.dailyMemoryExportEnabled"),
                cx,
            ),
        );
        if settings.daily_memory_export_enabled {
            let hour = settings.daily_memory_export_hour.min(23);
            let hour_data = self.data.clone();
            section = section
                .row(
                    "settings.dailyMemoryExportFormat",
                    self.choice(
                        "settings.dailyMemoryExportFormat",
                        lokalbot_i18n::tr("Format"),
                        None,
                        vec![
                            (DailyMemoryExportFormat::Markdown, "Markdown".into()),
                            (DailyMemoryExportFormat::Obsidian, "Obsidian".into()),
                            (DailyMemoryExportFormat::Logseq, "Logseq".into()),
                        ],
                        settings.daily_memory_export_format,
                        |s, v| s.daily_memory_export_format = v,
                        cx,
                    ),
                )
                .row(
                    "settings.dailyMemoryExportFolder",
                    settings_row::row(
                        "settings.dailyMemoryExportFolder",
                        lokalbot_i18n::tr("Folder"),
                        None,
                        folder_button(
                            "settings-daily-note-folder",
                            &settings.daily_memory_export_folder,
                            self.data.clone(),
                            "Choose daily note export folder",
                            |s, folder| s.daily_memory_export_folder = folder,
                        ),
                        false,
                        cx,
                    ),
                )
                .row(
                    "settings.dailyMemoryExportHour",
                    settings_row::row(
                        "settings.dailyMemoryExportHour",
                        lokalbot_i18n::format("Refresh at {0}", &[("0", hour_label(hour))]),
                        None,
                        settings_row::stepper(
                            "settings-daily-note-hour",
                            hour_label(hour),
                            hour > 0,
                            hour < 23,
                            move |step, _, cx| {
                                let next = (hour as i32 + step).clamp(0, 23) as u32;
                                hour_data.update(cx, |data, cx| {
                                    data.update_settings(|s| s.daily_memory_export_hour = next, cx)
                                });
                            },
                            cx,
                        ),
                        false,
                        cx,
                    ),
                );
        }
        section
    }
}
