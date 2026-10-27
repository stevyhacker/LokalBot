//! The meeting list column: header with Record, search, and day groups.

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, ExternalPaths, FontWeight, InteractiveElement as _, IntoElement,
    KeyDownEvent, MouseButton, ParentElement as _, StatefulInteractiveElement as _, Styled as _,
    Window, div, list, px, white,
};
use lokalbot_core::Meeting;

use super::{Entry, MeetingsPage, dialogs, model};
use crate::state::{AppData, ProcessingStage, day_label};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

impl MeetingsPage {
    /// Rebuilds the grouped rows when the library, query or recording changed.
    pub(super) fn rebuild_entries(&mut self, cx: &mut Context<Self>) {
        let data = self.data.read(cx);
        let live = data.recording.meeting().cloned();
        let key = (
            data.revision,
            self.query.clone(),
            live.as_ref().map(|m| m.id),
            data.meetings_loaded,
            data.meetings.len(),
            self.content_generation,
        );
        if self.entries_key.as_ref() == Some(&key) {
            return;
        }
        let needle = self.query.to_lowercase();
        let content = &self.content_matches;
        let matches = |m: &Meeting| {
            needle.is_empty()
                || m.display_title().to_lowercase().contains(&needle)
                || m.app_name.to_lowercase().contains(&needle)
                || content.contains(&m.id)
        };
        let mut entries = Vec::new();
        let live_id = live.as_ref().map(|m| m.id);
        if let Some(live) = live.filter(|m| matches(m)) {
            entries.push(Entry::Header(lokalbot_i18n::tr("Recording Now").into()));
            entries.push(Entry::Meeting {
                meeting: Box::new(live),
                live: true,
            });
        }
        let mut current: Option<String> = None;
        for meeting in data
            .meetings
            .iter()
            .filter(|m| Some(m.id) != live_id && matches(m))
        {
            let label = day_label(meeting.started_at);
            if current.as_deref() != Some(label.as_str()) {
                entries.push(Entry::Header(label.clone().into()));
                current = Some(label);
            }
            entries.push(Entry::Meeting {
                meeting: Box::new(meeting.clone()),
                live: false,
            });
        }
        let old = self.list_state.item_count();
        self.list_state.splice(0..old, entries.len());
        self.entries = entries;
        self.entries_key = Some(key);
    }

    pub(super) fn meeting_ids(&self) -> Vec<uuid::Uuid> {
        self.entries
            .iter()
            .filter_map(|e| match e {
                Entry::Meeting { meeting, .. } => Some(meeting.id),
                Entry::Header(_) => None,
            })
            .collect()
    }

    fn move_selection(&mut self, by: isize, window: &mut Window, cx: &mut Context<Self>) {
        let ids = self.meeting_ids();
        if ids.is_empty() {
            return;
        }
        let current = self
            .selected
            .and_then(|id| ids.iter().position(|m| *m == id));
        let next = match current {
            Some(ix) => (ix as isize + by).clamp(0, ids.len() as isize - 1) as usize,
            None => 0,
        };
        let id = ids[next];
        self.select(id, window, cx);
        if let Some(entry_ix) = self
            .entries
            .iter()
            .position(|e| matches!(e, Entry::Meeting { meeting, .. } if meeting.id == id))
        {
            self.list_state.scroll_to_reveal_item(entry_ix);
        }
    }

    fn on_list_key(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        if event.keystroke.key == "f"
            && (event.keystroke.modifiers.control || event.keystroke.modifiers.platform)
        {
            self.open_find(window, cx);
            cx.stop_propagation();
            return;
        }
        match event.keystroke.key.as_str() {
            "space" => self.toggle_playback(cx),
            "left" => self.seek_by(-5., cx),
            "right" => self.seek_by(5., cx),
            "up" => self.move_selection(-1, window, cx),
            "down" => self.move_selection(1, window, cx),
            "delete" => {
                let ids: Vec<_> = self.selected_meetings(cx).iter().map(|m| m.id).collect();
                if !ids.is_empty() {
                    dialogs::confirm_delete(self.data.clone(), ids, window, cx);
                } else if let Some(id) = self.selected {
                    dialogs::confirm_delete(self.data.clone(), vec![id], window, cx);
                }
            }
            _ => return,
        }
        cx.stop_propagation();
    }

    pub(super) fn render_list_column(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let lb = cx.lb().clone();
        let data = self.data.read(cx);
        let count = data
            .meetings
            .iter()
            .filter(|m| !m.is_merged_source())
            .count();
        let recording = data.recording.is_active();
        let loaded = data.meetings_loaded;
        let library_empty = data.meetings.is_empty() && data.recording.meeting().is_none();
        let failed: Vec<uuid::Uuid> = data
            .processing
            .iter()
            .filter(|(_, stage)| matches!(stage, ProcessingStage::Failed(_)))
            .map(|(id, _)| *id)
            .collect();
        let importing = data.importing.first().cloned();
        let selection = self.selected_meetings(cx);
        let can_merge = lokalbot_core::merge::can_merge(&selection, |id| data.is_processing(id));
        let data_entity = self.data.clone();

        let import_button = {
            let data_entity = data_entity.clone();
            ui::controls::toolbar_icon(
                "meetings-import",
                Ico::Import,
                lokalbot_i18n::tr("Import an audio or video recording"),
            )
            .on_click(move |_, _, cx| choose_recordings(data_entity.clone(), cx))
        };

        let record_button = {
            let tint = lb.recording;
            let text = lb.recording_text;
            let data_entity = data_entity.clone();
            h_flex()
                .id("meetings-record")
                .flex_none()
                .h(px(28.))
                .px(px(10.))
                .gap(px(6.))
                .items_center()
                .rounded(px(7.))
                .bg(tint.opacity(0.10))
                .border_1()
                .border_color(tint.opacity(0.32))
                .hover(move |s| s.bg(tint.opacity(0.18)))
                .cursor_pointer()
                .child(if recording {
                    div()
                        .size(px(11.))
                        .rounded(px(2.))
                        .bg(tint)
                        .into_any_element()
                } else {
                    div()
                        .size(px(13.))
                        .rounded_full()
                        .bg(tint)
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(div().size(px(5.)).rounded_full().bg(white()))
                        .into_any_element()
                })
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(text)
                        .child(if recording {
                            lokalbot_i18n::tr("Stop Recording")
                        } else {
                            lokalbot_i18n::tr("Record")
                        }),
                )
                .tooltip(move |window, cx| {
                    gpui_kit::component::tooltip::Tooltip::new(if recording {
                        lokalbot_i18n::tr("Stop Recording")
                    } else {
                        lokalbot_i18n::tr("Record Now")
                    })
                    .build(window, cx)
                })
                .on_click(move |_, _, cx| {
                    data_entity.update(cx, |data, cx| data.toggle_recording(cx))
                })
        };

        let header =
            v_flex()
                .flex_none()
                .p(metric::PANEL_PADDING)
                .gap(px(10.))
                .child(
                    h_flex()
                        .gap(px(8.))
                        .items_start()
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(2.))
                                .child(
                                    div()
                                        .text_size(ty::COLUMN_TITLE)
                                        .font_weight(FontWeight::BOLD)
                                        .text_color(lb.text)
                                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                            "Meetings",
                                        ))),
                                )
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.text_secondary)
                                        .child(lokalbot_i18n::count(count, "meeting")),
                                ),
                        )
                        .child(import_button)
                        .child(record_button),
                )
                .child(Input::new(&self.search).small().cleanable(true))
                .when_some(importing, |this, name| {
                    this.child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(Spinner::new().xsmall())
                            .child(div().flex_1().min_w_0().truncate().child(
                                lokalbot_i18n::tr("Importing %@…").replacen("%@", &name, 1),
                            )),
                    )
                })
                .when(!failed.is_empty(), |this| {
                    let data_entity = data_entity.clone();
                    let failed = failed.clone();
                    this.child(
                        h_flex()
                            .gap(px(6.))
                            .items_center()
                            .text_size(ty::SECONDARY)
                            .child(ui::icon(Ico::TriangleAlert, px(14.), lb.attention_text))
                            .child(div().flex_1().text_color(lb.attention_text).child(
                                crate::ui::text::paragraph(lokalbot_i18n::format(
                                    "{0} failed",
                                    &[("0", format!("{}", failed.len()))],
                                )),
                            ))
                            .child(ui::link(
                                "meetings-retry-failed",
                                lokalbot_i18n::tr("Retry"),
                                move |_, cx| {
                                    data_entity.update(cx, |data, cx| {
                                        for id in &failed {
                                            data.request(
                                                crate::state::AppEvent::ProcessMeeting {
                                                    meeting_id: *id,
                                                    transcribe: true,
                                                    summarize: true,
                                                },
                                                cx,
                                            );
                                        }
                                    })
                                },
                                cx,
                            )),
                    )
                });

        let body: AnyElement = if !loaded {
            v_flex()
                .flex_1()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .child(Spinner::new().small())
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Loading your meeting library…",
                        ))),
                )
                .into_any_element()
        } else if self.entries.is_empty() {
            let (title, message) = if library_empty && self.query.is_empty() {
                (
                    lokalbot_i18n::tr("No meetings yet"),
                    lokalbot_i18n::tr(
                        "LokalBot detects meeting apps automatically, or start a recording now.",
                    ),
                )
            } else {
                (
                    lokalbot_i18n::tr("No matching meetings"),
                    lokalbot_i18n::tr("Try different words, a meeting title, or app."),
                )
            };
            let offer_sample = library_empty && self.query.is_empty();
            let sample_data = data_entity.clone();
            v_flex()
                .flex_1()
                .justify_center()
                .child(
                    ui::empty_state(Ico::AudioLines, title, message, cx)
                        .w_full()
                        .when(offer_sample, |this| {
                            this.child(
                                div().pt(px(8.)).child(
                                    Button::new("meetings-try-sample")
                                        .outline()
                                        .small()
                                        .label(lokalbot_i18n::tr("Try a sample meeting"))
                                        .on_click(move |_, _, cx| {
                                            sample_data.update(cx, |data, cx| data.try_sample(cx))
                                        }),
                                ),
                            )
                        }),
                )
                .into_any_element()
        } else {
            div()
                .id("meetings-list")
                .relative()
                .flex_1()
                .min_h_0()
                .child(
                    list(
                        self.list_state.clone(),
                        cx.processor(|this, ix: usize, window, cx| {
                            this.render_entry(ix, window, cx)
                        }),
                    )
                    .size_full(),
                )
                .vertical_scrollbar(&self.list_state)
                .into_any_element()
        };

        let merge_bar = (selection.len() > 1).then(|| {
            let page = cx.entity().downgrade();
            let meetings = selection.clone();
            // The column is narrow: the action shares the title row and the
            // explanation gets the full width below it.
            v_flex()
                .flex_none()
                .mx(px(10.))
                .mb(px(10.))
                .px(px(12.))
                .py(px(9.))
                .gap(px(4.))
                .rounded(metric::ROW_RADIUS)
                .border_1()
                .border_color(lb.accent_fill.opacity(0.22))
                .bg(lb.hover)
                .child(
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .child(ui::icon(Ico::Group, px(16.), lb.accent_text))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child(lokalbot_i18n::format(
                                    "{count} meetings selected",
                                    &[("count", selection.len().to_string())],
                                )),
                        )
                        .child(
                            ui::controls::bordered("meetings-merge", lokalbot_i18n::tr("Merge…"))
                                .small()
                                .disabled(!can_merge)
                                .on_click(move |_, window, cx| {
                                    let meetings = meetings.clone();
                                    let _ = page.update(cx, |this, cx| {
                                        dialogs::MergeSheet::open(
                                            this.data.clone(),
                                            meetings,
                                            window,
                                            cx,
                                        )
                                    });
                                }),
                        ),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(if can_merge {
                            lokalbot_i18n::tr("Create one timeline and fold the originals into it")
                        } else {
                            lokalbot_i18n::tr("Select completed meetings that are not processing")
                        })),
                )
        });

        let drop_target = lb.accent_fill;
        let drop_data = data_entity.clone();
        v_flex()
            .id("meetings-column")
            .w(metric::CONTENT_COLUMN_WIDTH)
            .flex_none()
            .h_full()
            .border_r_1()
            .border_color(lb.separator)
            .track_focus(&self.list_focus)
            .on_key_down(cx.listener(Self::on_list_key))
            .drag_over::<ExternalPaths>(move |style, _, _, _| style.bg(drop_target.opacity(0.08)))
            .on_drop(move |paths: &ExternalPaths, _, cx| {
                let files: Vec<_> = paths
                    .paths()
                    .iter()
                    .filter(|p| lokalbot_core::import::is_importable(p))
                    .cloned()
                    .collect();
                drop_data.update(cx, |data, cx| data.import_recordings(files, cx));
            })
            .child(header)
            .child(body)
            .children(merge_bar)
    }

    fn render_entry(
        &mut self,
        ix: usize,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let Some(entry) = self.entries.get(ix).cloned() else {
            return div().into_any_element();
        };
        match entry {
            Entry::Header(label) => div()
                .px(px(18.))
                .pt(px(if ix == 0 { 4. } else { 12. }))
                .pb(px(5.))
                .text_size(ty::CAPTION)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(label)
                .into_any_element(),
            Entry::Meeting { meeting, live } => {
                let selected =
                    self.selected == Some(meeting.id) || self.selection.contains(&meeting.id);
                let next_selected = matches!(self.entries.get(ix + 1), Some(Entry::Meeting { meeting: next, .. }) if Some(next.id) == self.selected || self.selection.contains(&next.id));
                let next_is_meeting =
                    matches!(self.entries.get(ix + 1), Some(Entry::Meeting { .. }));
                let stage = self.data.read(cx).processing.get(&meeting.id).cloned();
                let live_level = match &self.data.read(cx).recording {
                    crate::state::RecordingState::Recording {
                        started,
                        mic_level,
                        system_level,
                        ..
                    } if live => Some((
                        mic_level.max(*system_level),
                        started.elapsed().as_secs_f64(),
                    )),
                    _ => None,
                };
                let id = meeting.id;
                let detail = model::row_detail(&meeting, live);
                let hover = lb.hover;
                let data = self.data.clone();
                let row = h_flex()
                    .id(("meeting-row", ix))
                    .w_full()
                    .px(px(8.))
                    .py(px(7.))
                    .gap(px(10.))
                    .items_center()
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .when(selected, |this| this.bg(lb.sidebar_selection))
                    .when(!selected, |this| this.hover(move |s| s.bg(hover)))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                h_flex()
                                    .gap(px(6.))
                                    .items_center()
                                    .when(live, |this| {
                                        this.child(ui::status_dot(lb.recording, px(9.)))
                                    })
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .truncate()
                                            .text_size(ty::BODY)
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .text_color(lb.text)
                                            .child(meeting.display_title()),
                                    )
                                    .when_some(live_level, |this, (level, elapsed)| {
                                        this.child(super::live::live_bars(
                                            level,
                                            elapsed,
                                            lb.recording,
                                        ))
                                    }),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .text_color(if selected { lb.text } else { lb.supporting })
                                    .child(detail),
                            ),
                    )
                    .when_some(stage.filter(|_| !live), |this, stage| {
                        this.child(stage_badge(&stage, id, data, cx))
                    })
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(|this, _, window, cx| {
                            this.list_focus.focus(window, cx);
                        }),
                    )
                    .on_click(
                        cx.listener(move |this, event: &gpui_kit::ClickEvent, window, cx| {
                            this.click_row(id, event.modifiers(), window, cx)
                        }),
                    )
                    .context_menu({
                        let data = self.data.clone();
                        let page = cx.entity().downgrade();
                        // A menu on a selected row acts on the whole selection.
                        let group: Vec<Meeting> = {
                            let selection = self.selected_meetings(cx);
                            if selection.len() > 1 && selection.iter().any(|m| m.id == id) {
                                selection
                            } else {
                                Vec::new()
                            }
                        };
                        let can_merge = lokalbot_core::merge::can_merge(&group, |id| {
                            self.data.read(cx).is_processing(id)
                        });
                        move |menu, _, _| {
                            let data = data.clone();
                            if group.len() > 1 {
                                let ids: Vec<_> = group.iter().map(|m| m.id).collect();
                                let count = group.len().to_string();
                                let page = page.clone();
                                let meetings = group.clone();
                                let merge_data = data.clone();
                                menu.item(
                                    PopupMenuItem::new(lokalbot_i18n::format(
                                        "Merge {count} meetings…",
                                        &[("count", count.clone())],
                                    ))
                                    .disabled(!can_merge)
                                    .on_click(
                                        move |_, window, cx| {
                                            let meetings = meetings.clone();
                                            let data = merge_data.clone();
                                            let _ = page.update(cx, |_, cx| {
                                                dialogs::MergeSheet::open(
                                                    data, meetings, window, cx,
                                                )
                                            });
                                        },
                                    ),
                                )
                                .item(
                                    PopupMenuItem::new(lokalbot_i18n::format(
                                        "Delete {count} meetings…",
                                        &[("count", count)],
                                    ))
                                    .on_click(
                                        move |_, window, cx| {
                                            dialogs::confirm_delete(
                                                data.clone(),
                                                ids.clone(),
                                                window,
                                                cx,
                                            );
                                        },
                                    ),
                                )
                            } else {
                                menu.item(
                                    PopupMenuItem::new(lokalbot_i18n::tr("Delete meeting…"))
                                        .on_click(move |_, window, cx| {
                                            dialogs::confirm_delete(
                                                data.clone(),
                                                vec![id],
                                                window,
                                                cx,
                                            );
                                        }),
                                )
                            }
                        }
                    });
                v_flex()
                    .w_full()
                    .px(px(10.))
                    .child(row)
                    .when(next_is_meeting && !selected && !next_selected, |this| {
                        this.child(div().mx(px(8.)).h(px(1.)).bg(lb.separator))
                    })
                    .when(!(next_is_meeting && !selected && !next_selected), |this| {
                        this.child(div().h(px(1.)))
                    })
                    .into_any_element()
            }
        }
    }
}

/// "Import Recording…": an open dialog for one or more audio or video files.
pub(crate) fn choose_recordings(data: gpui_kit::Entity<AppData>, cx: &mut gpui_kit::App) {
    let receiver = cx.prompt_for_paths(gpui_kit::PathPromptOptions {
        files: true,
        directories: false,
        multiple: true,
        prompt: Some(lokalbot_i18n::tr("Import Recording").into()),
    });
    cx.spawn(async move |cx| {
        let picked = receiver.await;
        data.update(cx, |data, cx| match picked {
            Ok(Ok(Some(paths))) => data.import_recordings(paths, cx),
            Ok(Ok(None)) | Err(_) => {}
            Ok(Err(err)) => data.show_error(
                lokalbot_i18n::format(
                    "No file chooser is available: {err}",
                    &[("err", format!("{:#}", err))],
                ),
                cx,
            ),
        });
    })
    .detach();
}

/// Processing status at the trailing edge of a row.
fn stage_badge(
    stage: &ProcessingStage,
    meeting_id: uuid::Uuid,
    data: gpui_kit::Entity<AppData>,
    cx: &mut Context<MeetingsPage>,
) -> AnyElement {
    let lb = cx.lb().clone();
    let retry = move |label: &'static str, id: &'static str| {
        let data = data.clone();
        div()
            .id(id)
            .text_size(ty::SECONDARY)
            .text_color(lb.accent_text)
            .cursor_pointer()
            .hover(|s| s.underline())
            .child(label)
            .on_click(move |_, _, cx| {
                data.update(cx, |data, cx| {
                    data.request(
                        crate::state::AppEvent::ProcessMeeting {
                            meeting_id,
                            transcribe: true,
                            summarize: true,
                        },
                        cx,
                    )
                })
            })
    };
    match stage {
        ProcessingStage::Failed(reason) => v_flex()
            .flex_none()
            .items_end()
            .gap(px(2.))
            .child(
                h_flex()
                    .gap(px(4.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.attention_text)
                    .child(ui::icon(Ico::TriangleAlert, px(13.), lb.attention_text))
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Failed"))),
            )
            .child(retry(lokalbot_i18n::tr("Retry"), "row-retry"))
            .id(("row-failed", meeting_id.as_u128() as u64))
            .tooltip({
                let reason = reason.clone();
                move |window, cx| {
                    gpui_kit::component::tooltip::Tooltip::new(reason.clone()).build(window, cx)
                }
            })
            .into_any_element(),
        ProcessingStage::WaitingForModels => v_flex()
            .flex_none()
            .items_end()
            .gap(px(2.))
            .child(
                h_flex()
                    .gap(px(4.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::icon(Ico::CircleArrowDown, px(13.), lb.text_secondary))
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Waiting for models",
                    ))),
            )
            .child(retry(
                lokalbot_i18n::tr("Download & process"),
                "row-download",
            ))
            .into_any_element(),
        other => h_flex()
            .flex_none()
            .gap(px(5.))
            .items_center()
            .text_size(ty::CAPTION)
            .text_color(lb.text_secondary)
            .child(Spinner::new().xsmall())
            .child(row_stage_label(other))
            .into_any_element(),
    }
}

/// `ProcessingPipeline.Stage.rowLabel`.
fn row_stage_label(stage: &ProcessingStage) -> String {
    match stage {
        ProcessingStage::Queued => lokalbot_i18n::tr("Queued").into(),
        ProcessingStage::PreparingModel(name) => {
            let lower = name.to_lowercase();
            if lower.contains("speaker") {
                lokalbot_i18n::tr("Preparing speaker model").into()
            } else if lower.contains("think") || lower.contains("summar") {
                lokalbot_i18n::tr("Preparing summary model").into()
            } else {
                lokalbot_i18n::tr("Preparing speech model").into()
            }
        }
        ProcessingStage::Transcribing => lokalbot_i18n::tr("Transcribing").into(),
        ProcessingStage::IdentifyingSpeakers => lokalbot_i18n::tr("Identifying speakers").into(),
        ProcessingStage::Summarizing => lokalbot_i18n::tr("Summarizing").into(),
        ProcessingStage::WaitingForModels => lokalbot_i18n::tr("Waiting for models").into(),
        ProcessingStage::Failed(_) => lokalbot_i18n::tr("Failed").into(),
    }
}
