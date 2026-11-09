//! Settings → Files (`FileSearchSettings.swift`). Nothing is read until the person
//! turns Files on after a notice and chooses a folder.

use std::path::Path;
use std::sync::Arc;
use std::sync::LazyLock;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Context, Entity, FontWeight, IntoElement, ParentElement as _, Render,
    SharedString, Styled as _, Window, div, px,
};
use lokalbot_core::files::abbreviate_home;
use lokalbot_core::files::costs::{FolderEstimate, estimate_duration};
use lokalbot_engine::files::{
    FileSearchState, NEW_FILES_LIMIT, PauseReason, estimate, reads_video_frames, suggested_folders,
};

use super::{Section, SettingsPage};
use crate::i18n::h_flex;
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

const PRIVACY_POLICY: &str = "https://www.lokalbot.com/privacy#files";
/// A desktop has no battery to ask about.
static HAS_BATTERY: LazyLock<bool> =
    LazyLock::new(|| lokalbot_platform::power::current().has_battery);

const READING_DETAILS: &str = "LokalBot reads only the folders listed here: pictures and screenshots, PDFs page by page for their words (a scanned page as its picture), and documents such as txt, md, rtf, docx, odt, xlsx, pptx and html. It skips hidden folders, app bundles, caches, code projects (except their screenshots), folders that look like datasets, and files held in the cloud that are not downloaded. Scanned PDF pages stored as JBIG2, CCITT or JPEG 2000 and legacy .doc files aren't read on this computer yet, and screenshots and scanned pages are read for their words only if screen text recognition is already downloaded. With recordings and video included, sound is read 30 seconds at a time; video frames also need ffmpeg installed. The index keeps each file's path, its text, and a vector of what it says, shows or sounds like, in the LokalBot library. The image and text model downloads once and runs only while new or changed files are read. Reading pauses while a meeting records, while saving power, and while the computer is hot. While you use the computer, a folder's first read goes at about a third of full speed, and at full speed once you step away. On battery it waits for a charger unless Read big folders on battery is on.";

/// "25 min", "2 hr, 10 min": the precision an estimate deserves.
pub fn duration_label(seconds: f64) -> String {
    let (hours, minutes) = estimate_duration(seconds);
    match (hours, minutes) {
        (0, minutes) => lokalbot_i18n::format("{0} min", &[("0", minutes.to_string())]),
        (hours, 0) => lokalbot_i18n::format("{0} hr", &[("0", hours.to_string())]),
        (hours, minutes) => lokalbot_i18n::format(
            "{0} hr, {1} min",
            &[("0", hours.to_string()), ("1", minutes.to_string())],
        ),
    }
}

/// "12 MB": the way files are sized for people.
pub fn bytes_label(bytes: f64) -> String {
    const UNITS: [&str; 4] = ["KB", "MB", "GB", "TB"];
    let mut value = bytes / 1000.0;
    let mut unit = 0;
    while value >= 1000.0 && unit + 1 < UNITS.len() {
        value /= 1000.0;
        unit += 1;
    }
    if value < 10.0 && unit > 0 {
        format!("{value:.1} {}", UNITS[unit])
    } else {
        format!("{value:.0} {}", UNITS[unit])
    }
}

fn confirm_on(data: Entity<AppData>, window: &mut Window, cx: &mut App) {
    window.open_dialog(cx, move |dialog, _, _| {
        let turn_on = data.clone();
        dialog
            .w(px(460.))
            .close_button(false)
            .title(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .child(lokalbot_i18n::tr("Search your files?")),
            )
            .child(
                v_flex()
                    .gap(px(14.))
                    .text_size(ty::BODY)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "LokalBot reads the folders you choose and keeps an index of their text, pictures and sound in its library. Nothing leaves this computer. The first time, it downloads EmbeddingGemma 2's image model (555 MB). Turning Files off deletes the index.",
                    )))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .child(
                                Button::new("files-privacy-policy")
                                    .ghost()
                                    .small()
                                    .label(lokalbot_i18n::tr("Privacy Policy"))
                                    .on_click(|_, _, _| {
                                        if let Err(err) =
                                            lokalbot_platform::opener::open_url(PRIVACY_POLICY)
                                        {
                                            log::warn!("could not open the privacy policy: {err:#}");
                                        }
                                    }),
                            )
                            .child(div().flex_1())
                            .child(
                                Button::new("files-notice-cancel")
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Cancel"))
                                    .on_click(|_, window, cx| window.close_dialog(cx)),
                            )
                            .child(
                                Button::new("files-notice-on")
                                    .primary()
                                    .small()
                                    .label(lokalbot_i18n::tr("Turn On"))
                                    .on_click(move |_, window, cx| {
                                        turn_on.update(cx, |data, cx| {
                                            data.update_settings(
                                                |s| s.file_search_enabled = true,
                                                cx,
                                            );
                                        });
                                        window.close_dialog(cx);
                                    }),
                            ),
                    ),
            )
    });
}

fn confirm_off(data: Entity<AppData>, window: &mut Window, cx: &mut App) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let data = data.clone();
        alert
            .title(lokalbot_i18n::tr("Turn off Files?"))
            .description(lokalbot_i18n::tr(
                "LokalBot stops reading the chosen folders and deletes the file index. Your files are not touched.",
            ))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Turn Off and Delete the Index"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                data.update(cx, |data, cx| {
                    data.update_settings(|s| s.file_search_enabled = false, cx);
                });
                true
            })
    });
}

/// Before a folder is added: what it holds and how long its first read takes,
/// counted from metadata while the sheet is open. Nothing is read until the person
/// adds it, and adding doesn't wait for the count.
struct AddFolderSheet {
    data: Entity<AppData>,
    folders: Vec<String>,
    name: Option<String>,
    checked: Arc<AtomicUsize>,
    estimate: Option<FolderEstimate>,
}

impl AddFolderSheet {
    fn open(
        data: Entity<AppData>,
        folders: Vec<String>,
        name: Option<String>,
        window: &mut Window,
        cx: &mut App,
    ) {
        let sheet = cx.new(|cx: &mut Context<Self>| {
            let checked = Arc::new(AtomicUsize::new(0));
            let (paths, chosen, includes_media) = {
                let app = data.read(cx);
                (
                    app.library.paths().clone(),
                    app.settings.file_search_folders.clone(),
                    app.settings.file_search_includes_media,
                )
            };
            let counted = folders.clone();
            let counter = checked.clone();
            let work = cx.background_spawn(async move {
                estimate(&paths, &counted, &chosen, includes_media, &mut |seen| {
                    counter.store(seen, Ordering::Relaxed);
                })
            });
            cx.spawn(async move |this, cx| {
                let found = work.await;
                let _ = this.update(cx, |this, cx| {
                    this.estimate = Some(found);
                    cx.notify();
                });
            })
            .detach();
            // The count moves while the walk runs.
            cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor()
                        .timer(Duration::from_millis(250))
                        .await;
                    let waiting = this
                        .update(cx, |this, cx| {
                            cx.notify();
                            this.estimate.is_none()
                        })
                        .unwrap_or(false);
                    if !waiting {
                        return;
                    }
                }
            })
            .detach();
            Self {
                data,
                folders,
                name,
                checked,
                estimate: None,
            }
        });
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(460.)).close_button(false).child(sheet.clone())
        });
    }

    fn title(&self) -> String {
        if self.folders.len() == 1 {
            let name = self.name.clone().unwrap_or_else(|| {
                Path::new(&self.folders[0])
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| self.folders[0].clone())
            });
            lokalbot_i18n::format("Add “{0}”?", &[("0", name)])
        } else {
            lokalbot_i18n::format("Add {0} folders?", &[("0", self.folders.len().to_string())])
        }
    }

    fn summary(&self, estimate: &FolderEstimate, cx: &App) -> Vec<gpui_kit::AnyElement> {
        let lb = cx.lb().clone();
        let mut out: Vec<gpui_kit::AnyElement> = Vec::new();
        if !estimate.unreadable.is_empty() {
            out.push(
                div()
                    .text_color(lb.attention_text)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "LokalBot can't open this folder. Check its permissions, then add it again.",
                    )))
                    .into_any_element(),
            );
        }
        if estimate.files == 0 {
            if estimate.unreadable.is_empty() {
                out.push(
                    ui::text::paragraph(lokalbot_i18n::tr(
                        "LokalBot found nothing here it reads yet. New files are read as they arrive.",
                    ))
                    .into_any_element(),
                );
            }
            return out;
        }
        let mut rows: Vec<(String, String, bool)> = Vec::new();
        if estimate.pictures > 0 {
            rows.push((
                lokalbot_i18n::tr("Pictures").into(),
                estimate.pictures.to_string(),
                false,
            ));
        }
        if estimate.documents > 0 {
            rows.push((
                lokalbot_i18n::tr("PDFs and documents").into(),
                estimate.documents.to_string(),
                false,
            ));
        }
        if estimate.recordings > 0 {
            rows.push((
                lokalbot_i18n::tr("Recordings and video").into(),
                format!(
                    "{} · {}",
                    estimate.recordings,
                    duration_label(estimate.playing_seconds)
                ),
                false,
            ));
        }
        rows.push((
            lokalbot_i18n::tr("First read").into(),
            if estimate.seconds < 60.0 {
                lokalbot_i18n::tr("Under a minute").into()
            } else {
                lokalbot_i18n::format("About {0}", &[("0", duration_label(estimate.seconds))])
            },
            true,
        ));
        if estimate.later_seconds >= 60.0 {
            rows.push((
                lokalbot_i18n::tr("Rest of long PDFs and documents").into(),
                lokalbot_i18n::format(
                    "About {0} more",
                    &[("0", duration_label(estimate.later_seconds))],
                ),
                false,
            ));
        }
        rows.push((
            lokalbot_i18n::tr("Index on this computer").into(),
            lokalbot_i18n::format("About {0}", &[("0", bytes_label(estimate.index_bytes))]),
            false,
        ));
        if estimate.download_bytes > 0 {
            rows.push((
                lokalbot_i18n::tr("Model download, first time only").into(),
                bytes_label(estimate.download_bytes as f64),
                false,
            ));
        }
        out.push(
            v_flex()
                .gap(px(6.))
                .children(rows.into_iter().map(|(label, value, strong)| {
                    h_flex()
                        .gap(px(16.))
                        .when(strong, |this| this.font_weight(FontWeight::BOLD))
                        .child(div().flex_1().child(label))
                        .child(value)
                }))
                .into_any_element(),
        );
        let mut note: String = lokalbot_i18n::tr(
            "Times are for this computer at full speed. While you use the computer, LokalBot reads at about a third of that and goes at full speed when you step away.",
        )
        .into();
        if estimate.rough {
            note.push(' ');
            note.push_str(lokalbot_i18n::tr(
                "They are a rough guide until this computer has read some files.",
            ));
        }
        out.push(
            div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(ui::text::paragraph(note))
                .into_any_element(),
        );
        let waits_for_charger =
            *HAS_BATTERY && !self.data.read(cx).settings.file_search_reads_on_battery;
        if waits_for_charger && estimate.files > NEW_FILES_LIMIT {
            out.push(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "On battery, the first read waits for a charger.",
                    )))
                    .into_any_element(),
            );
        }
        out
    }
}

impl Render for AddFolderSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let body: Vec<gpui_kit::AnyElement> = match &self.estimate {
            Some(estimate) => self.summary(estimate, cx),
            None => vec![
                ui::text::paragraph(lokalbot_i18n::format(
                    "Counting files… {0} so far",
                    &[("0", self.checked.load(Ordering::Relaxed).to_string())],
                ))
                .into_any_element(),
            ],
        };
        let add_label = if self.folders.len() == 1 {
            "Add Folder"
        } else {
            "Add Folders"
        };
        v_flex()
            .gap(px(14.))
            .text_size(ty::BODY)
            .child(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .child(self.title()),
            )
            .children(body)
            .child(
                h_flex()
                    .gap(px(8.))
                    .justify_end()
                    .child(
                        Button::new("files-add-cancel")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("files-add-confirm")
                            .primary()
                            .small()
                            .label(lokalbot_i18n::tr(add_label))
                            .on_click(cx.listener(|this, _, window, cx| {
                                let folders = this.folders.clone();
                                this.data.update(cx, |data, cx| {
                                    data.update_settings(
                                        |settings| {
                                            for folder in folders {
                                                if !settings.file_search_folders.contains(&folder) {
                                                    settings.file_search_folders.push(folder);
                                                }
                                            }
                                        },
                                        cx,
                                    );
                                });
                                window.close_dialog(cx);
                            })),
                    ),
            )
    }
}

fn choose_folders(data: Entity<AppData>, window: &mut Window, cx: &mut App) {
    let receiver = cx.prompt_for_paths(gpui_kit::PathPromptOptions {
        files: false,
        directories: true,
        multiple: true,
        prompt: Some(lokalbot_i18n::tr("Choose").into()),
    });
    let window = window.window_handle();
    cx.spawn(async move |cx| {
        let Ok(Ok(Some(paths))) = receiver.await else {
            return;
        };
        let _ = cx.update_window(window, |_, window, cx| {
            let known = data.read(cx).settings.file_search_folders.clone();
            let chosen: Vec<String> = paths
                .iter()
                .filter_map(|path| path.to_str().map(str::to_string))
                .filter(|path| !known.contains(path))
                .collect();
            if !chosen.is_empty() {
                AddFolderSheet::open(data.clone(), chosen, None, window, cx);
            }
        });
    })
    .detach();
}

impl SettingsPage {
    pub(super) fn files_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let settings = self.data.read(cx).settings.clone();
        let on = settings.file_search_enabled;
        let toggle_data = self.data.clone();
        let mut section = Section::new(lokalbot_i18n::tr("Files")).row(
            "settings.fileSearchEnabled",
            settings_row::row(
                "settings.fileSearchEnabled",
                lokalbot_i18n::tr("Search my files"),
                Some(lokalbot_i18n::tr("Search the folders you choose by what is in them: documents and PDFs by their words and meaning, pictures and screenshots by what they show. Files are read on this computer and never changed.").into()),
                settings_row::switch("settings.fileSearchEnabled", on, move |next, window, cx| {
                    if next {
                        confirm_on(toggle_data.clone(), window, cx);
                    } else {
                        confirm_off(toggle_data.clone(), window, cx);
                    }
                }),
                self.is_focused("settings.fileSearchEnabled"),
                cx,
            ),
        );
        if on {
            section = self.files_rows(section, &settings, cx);
        }
        let details_id = "settings.fileSearchDetails";
        let expanded = self.open_details.contains(details_id);
        let page = cx.entity();
        section = section.row(
            details_id,
            settings_row::content_row(
                details_id,
                settings_row::details(
                    details_id,
                    lokalbot_i18n::tr("What LokalBot reads"),
                    lokalbot_i18n::tr(READING_DETAILS),
                    expanded,
                    move |_, cx| {
                        page.update(cx, |page, cx| {
                            if !page.open_details.remove(details_id) {
                                page.open_details.insert(details_id);
                            }
                            cx.notify();
                        })
                    },
                    cx,
                ),
                false,
                cx,
            ),
        );
        vec![section]
    }

    fn files_rows(
        &mut self,
        mut section: Section,
        settings: &lokalbot_core::Settings,
        cx: &mut Context<Self>,
    ) -> Section {
        let lb = cx.lb().clone();
        let mut folder_rows: Vec<gpui_kit::AnyElement> = Vec::new();
        for (index, folder) in settings.file_search_folders.iter().enumerate() {
            let remove_data = self.data.clone();
            let removed = folder.clone();
            folder_rows.push(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::icon(Ico::Folder, px(14.), lb.text_secondary))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .child(abbreviate_home(folder)),
                    )
                    .when(!Path::new(folder).exists(), |this| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(lokalbot_i18n::tr("Not available")),
                        )
                    })
                    .child(
                        Button::new(("files-remove-folder", index))
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Remove"))
                            .on_click(move |_, _, cx| {
                                let removed = removed.clone();
                                remove_data.update(cx, |data, cx| {
                                    data.update_settings(
                                        |s| s.file_search_folders.retain(|f| *f != removed),
                                        cx,
                                    );
                                });
                            }),
                    )
                    .into_any_element(),
            );
        }
        let add_data = self.data.clone();
        folder_rows.push(
            h_flex()
                .child(
                    Button::new("settings-files-add-folder")
                        .outline()
                        .small()
                        .label(lokalbot_i18n::tr("Add Folder…"))
                        .on_click(move |_, window, cx| {
                            choose_folders(add_data.clone(), window, cx)
                        }),
                )
                .into_any_element(),
        );
        section = section.row(
            "settings.fileSearchFolders",
            settings_row::content_row(
                "settings.fileSearchFolders",
                v_flex().gap(px(8.)).children(folder_rows),
                self.is_focused("settings.fileSearchFolders"),
                cx,
            ),
        );
        if settings.file_search_folders.is_empty() {
            let common = suggested_folders(&settings.file_search_folders);
            if !common.is_empty() {
                let mut buttons = h_flex().gap(px(8.));
                for (index, (name, path)) in common.into_iter().enumerate() {
                    let data = self.data.clone();
                    let label = lokalbot_i18n::tr(match name.as_str() {
                        "Documents" => "Documents",
                        "Desktop" => "Desktop",
                        _ => "Downloads",
                    });
                    buttons = buttons.child(
                        Button::new(("files-suggested", index))
                            .outline()
                            .small()
                            .label(label)
                            .tooltip(abbreviate_home(&path))
                            .on_click(move |_, window, cx| {
                                AddFolderSheet::open(
                                    data.clone(),
                                    vec![path.clone()],
                                    Some(label.to_string()),
                                    window,
                                    cx,
                                );
                            }),
                    );
                }
                section = section.row(
                    "settings.fileSearchSuggestions",
                    settings_row::row(
                        "settings.fileSearchSuggestions",
                        lokalbot_i18n::tr("Suggested folders"),
                        Some(lokalbot_i18n::tr("Each shows what it holds and how long its first read takes before anything is read.").into()),
                        buttons,
                        false,
                        cx,
                    ),
                );
            }
        }
        let media_data = self.data.clone();
        let mut media_help: String = lokalbot_i18n::tr(
            "Sound is read 30 seconds at a time and video a frame per shot. A first pass over hours of video takes a while.",
        )
        .into();
        if !reads_video_frames() {
            media_help.push(' ');
            media_help.push_str(lokalbot_i18n::tr(
                "Video frames need ffmpeg, which isn't installed here: videos are read for their sound only.",
            ));
        }
        section = section.row(
            "settings.fileSearchIncludesMedia",
            settings_row::row(
                "settings.fileSearchIncludesMedia",
                lokalbot_i18n::tr("Include recordings and video"),
                Some(SharedString::from(media_help)),
                settings_row::switch(
                    "settings.fileSearchIncludesMedia",
                    settings.file_search_includes_media,
                    move |next, _, cx| {
                        media_data.update(cx, |data, cx| {
                            data.update_settings(|s| s.file_search_includes_media = next, cx);
                        });
                    },
                ),
                self.is_focused("settings.fileSearchIncludesMedia"),
                cx,
            ),
        );
        if *HAS_BATTERY {
            let battery_data = self.data.clone();
            section = section.row(
                "settings.fileSearchReadsOnBattery",
                settings_row::row(
                    "settings.fileSearchReadsOnBattery",
                    lokalbot_i18n::tr("Read big folders on battery"),
                    Some(lokalbot_i18n::tr("Off, a folder's first read waits until the computer is plugged in. New files are read right away either way.").into()),
                    settings_row::switch(
                        "settings.fileSearchReadsOnBattery",
                        settings.file_search_reads_on_battery,
                        move |next, _, cx| {
                            battery_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.file_search_reads_on_battery = next, cx);
                            });
                        },
                    ),
                    self.is_focused("settings.fileSearchReadsOnBattery"),
                    cx,
                ),
            );
        }
        section.row(
            "settings.fileSearchStatus",
            settings_row::content_row(
                "settings.fileSearchStatus",
                self.files_status(cx),
                false,
                cx,
            ),
        )
    }

    /// What Files is doing now, and what the index holds.
    fn files_status(&self, cx: &mut Context<Self>) -> gpui_kit::Div {
        let lb = cx.lb().clone();
        let data = self.data.read(cx);
        let status = data.files.clone();
        let projector = lokalbot_ai::catalog::PROJECTOR_ID;
        let fraction = data
            .downloads
            .get(projector)
            .filter(|d| d.total_bytes > 0)
            .map(|d| d.done_bytes as f32 / d.total_bytes as f32);
        let metadata = |text: String| {
            div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(ui::text::paragraph(text))
        };
        let mut column = v_flex().gap(px(4.)).text_size(ty::BODY);
        match &status.state {
            FileSearchState::Off => {}
            FileSearchState::NoFolders => {
                column = column.child(lokalbot_i18n::tr("Choose a folder to start."));
            }
            FileSearchState::Downloading => {
                let text: String = match fraction {
                    Some(fraction) => format!(
                        "{} {:.0}%",
                        lokalbot_i18n::tr("Downloading the image and text model…"),
                        fraction * 100.0
                    ),
                    None => lokalbot_i18n::tr("Downloading the image and text model…").into(),
                };
                column = column.child(text);
            }
            FileSearchState::Indexing { done, total } => {
                column = column.child(lokalbot_i18n::format(
                    "Reading files: {0} of {1}",
                    &[("0", done.to_string()), ("1", total.to_string())],
                ));
                if let Some(left) = status.seconds_left.filter(|left| *left >= 60.0) {
                    column = column.child(metadata(lokalbot_i18n::format(
                        "About {0} left",
                        &[("0", duration_label(left))],
                    )));
                }
            }
            FileSearchState::FinishingLongFiles { left } => {
                column = column.child(lokalbot_i18n::format(
                    "Reading the rest of {0} long files",
                    &[("0", left.to_string())],
                ));
            }
            FileSearchState::Paused(PauseReason::Recording) => {
                column = column.child(lokalbot_i18n::tr("Paused while a meeting records."));
            }
            FileSearchState::Paused(PauseReason::LowPower) => {
                column = column.child(lokalbot_i18n::tr("Paused while saving power."));
            }
            FileSearchState::Paused(PauseReason::Warm) => {
                column = column.child(lokalbot_i18n::tr("Paused while the computer is hot."));
            }
            FileSearchState::WaitingForPower { left } => {
                column = column.child(lokalbot_i18n::format(
                    "Waiting for a charger: {0} files left to read.",
                    &[("0", left.to_string())],
                ));
            }
            FileSearchState::Ready => {
                column = column.child(lokalbot_i18n::tr("Up to date."));
            }
            FileSearchState::Failed(message) => {
                column = column.child(
                    div()
                        .text_color(lb.attention_text)
                        .child(ui::text::paragraph(message.clone())),
                );
            }
        }
        if status.totals.searchable > 0 {
            column = column.child(metadata(lokalbot_i18n::format(
                "{0} files searchable · index {1}",
                &[
                    ("0", status.totals.searchable.to_string()),
                    ("1", bytes_label(status.totals.index_bytes as f64)),
                ],
            )));
        }
        if let Some(pass) = status.last_pass.as_ref().filter(|pass| pass.files_read > 0) {
            column = column.child(metadata(lokalbot_i18n::format(
                "Last pass read {0} files in {1}.",
                &[
                    ("0", pass.files_read.to_string()),
                    ("1", duration_label(pass.wall_seconds)),
                ],
            )));
        }
        column
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_read_like_files() {
        assert_eq!(bytes_label(555_000_000.0), "555 MB");
        assert_eq!(bytes_label(1_500_000.0), "1.5 MB");
        assert_eq!(bytes_label(2_700.0), "3 KB");
        assert_eq!(bytes_label(2_500_000_000.0), "2.5 GB");
    }

    #[test]
    fn durations_read_at_an_estimates_precision() {
        assert_eq!(duration_label(1500.0), "25 min");
        assert_eq!(duration_label(3700.0), "1 hr");
        assert_eq!(duration_label(7800.0), "2 hr, 10 min");
    }
}
