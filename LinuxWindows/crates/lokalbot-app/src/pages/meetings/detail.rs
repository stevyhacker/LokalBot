//! A saved meeting's page (`MeetingWorkspaceView.swift`, v2): one compact
//! title block and the player pinned above content that fills the pane with
//! 24px gutters. Summary is a recap lead panel, Decisions, Actions (For you /
//! For others), Open questions and a closed Full summary panel; Notes is one
//! panel with the save status in its footer. The Transcript tab is in
//! `transcript.rs`, the naming sheet in `naming.rs`.

use crate::i18n::h_flex;
use crate::windows::screen_image::{self, ScreenImage};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Textarea;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, Div, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px, white,
};
use gpui_kit::{AppContext as _, ObjectFit, StyledImage as _, img};
use lokalbot_core::{ActionCorrection, ActionStatus};

use super::dialogs::{CorrectionSheet, NameSpeakerSheet};
use super::model::{self, MeetingAction, MeetingDoc};
use super::page_search::{ActionField, DecisionField, Location, Section};
use super::presentation::{self, ActionsPanel, FindPlacement, OwnerKind, OwnerOption, layout};
use super::{MeetingsPage, NotesStatus, status_text};
use crate::state::{MeetingTab, ProcessingStage};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::action_row::{self, DueTone};
use crate::ui::section_panel::{SectionPanel, SectionPanelLead, footer_text, panel_surface};
use crate::ui::{self, Ico};

/// The tone of a status line at the top of the content
/// (`MeetingStatusBanner.Tone`).
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum BannerTone {
    /// Something to notice or fix.
    Attention,
    /// Work in progress or an offer.
    Info,
}

impl MeetingsPage {
    pub(super) fn text_scale(&self, cx: &gpui_kit::App) -> f32 {
        self.data.read(cx).settings.text_size.scale()
    }

    /// The page's column: the full pane up to its widest, with the gutters.
    pub(super) fn page_column(&self, cx: &gpui_kit::App) -> Div {
        v_flex()
            .w_full()
            .max_w(layout::scaled(layout::COLUMN_MAX, self.text_scale(cx)))
            .px(layout::GUTTER)
    }

    pub(super) fn render_detail(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // "Try a sample meeting" holds the pane until its models are here or it is cancelled.
        if self.data.read(cx).sample_setup.is_some() {
            return crate::sample::render_setup(&self.data, cx);
        }
        if self.selection.len() > 1 {
            return self.render_multi_selection(cx);
        }
        let Some(doc) = self
            .doc
            .clone()
            .filter(|d| Some(d.meeting.id) == self.selected)
        else {
            return if self.selected.is_some() && self.doc_loading {
                v_flex()
                    .size_full()
                    .items_center()
                    .justify_center()
                    .gap(px(8.))
                    .child(Spinner::new())
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(cx.lb().text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Loading meeting…",
                            ))),
                    )
                    .into_any_element()
            } else {
                div()
                    .size_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(ui::empty_state(
                        Ico::AudioLines,
                        lokalbot_i18n::tr("No meeting selected"),
                        lokalbot_i18n::tr("Select a meeting to review its outcomes and evidence."),
                        cx,
                    ))
                    .into_any_element()
            };
        };

        let lb = cx.lb().clone();
        let placement = presentation::find_placement(self.tab, self.find.open);
        let content: AnyElement = match self.tab {
            MeetingTab::Transcript => self.render_transcript(&doc, window, cx),
            tab => {
                let body = match tab {
                    MeetingTab::Notes => self.render_notes_tab(cx),
                    _ => self.render_summary(&doc, cx),
                };
                let status = self.render_status(&doc, cx);
                div()
                    .relative()
                    .size_full()
                    .child(
                        div()
                            .id("meeting-scroll")
                            .size_full()
                            .overflow_y_scroll()
                            .track_scroll(&self.find.scroll)
                            .child(
                                div().w_full().flex().justify_center().child(
                                    self.page_column(cx)
                                        .pt(px(4.))
                                        .pb(layout::GUTTER)
                                        .gap(layout::PANEL_GAP)
                                        .children(status)
                                        .child(body),
                                ),
                            ),
                    )
                    .vertical_scrollbar(&self.find.scroll)
                    .into_any_element()
            }
        };

        // The title, who spoke and the player stay put on every tab; only
        // the tab's content scrolls beneath them.
        v_flex()
            .size_full()
            .bg(lb.page)
            .child(
                div().w_full().flex().justify_center().flex_none().child(
                    self.page_column(cx)
                        .pt(px(14.))
                        .pb(px(12.))
                        .gap(px(14.))
                        .child(self.render_title_block(&doc, cx))
                        .child(self.render_player(&doc, cx))
                        .when(placement == FindPlacement::PinnedBar, |this| {
                            this.child(self.render_find_bar(cx))
                        }),
                ),
            )
            .child(div().flex_1().min_h_0().child(content))
            .into_any_element()
    }

    /// Several meetings selected: what can be done with them
    /// (`MeetingLibraryDetailView.libraryContent`).
    fn render_multi_selection(&self, cx: &mut Context<Self>) -> AnyElement {
        let count = self.selection.len();
        let ids = self.selection.clone();
        let data = self.data.clone();
        div()
            .size_full()
            .bg(cx.lb().page)
            .flex()
            .items_center()
            .justify_center()
            .child(
                ui::empty_state(
                    Ico::ListChecks,
                    lokalbot_i18n::format(
                        "{count} meetings selected",
                        &[("count", lokalbot_i18n::number(count))],
                    ),
                    lokalbot_i18n::tr("Press Delete or use the list menu to remove them."),
                    cx,
                )
                .child(
                    div().pt(px(4.)).child(
                        ui::controls::bordered(
                            "meetings-delete-selection",
                            lokalbot_i18n::format(
                                "Delete {count} meetings…",
                                &[("count", lokalbot_i18n::number(count))],
                            ),
                        )
                        .on_click(move |_, window, cx| {
                            super::dialogs::confirm_delete(data.clone(), ids.clone(), window, cx)
                        }),
                    ),
                ),
            )
            .into_any_element()
    }

    // ------------------------------------------------------------- header

    /// The meeting's one title: name, a date line, and who spoke. Unnamed
    /// voices are named from here (`MeetingDetailHeader`).
    fn render_title_block(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let title = doc.meeting.display_title();
        v_flex()
            .w_full()
            .gap(px(5.))
            .child(
                div()
                    .text_size(px(20.))
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .line_clamp(2)
                    .child(self.find_marked(Location::Title, &title, title.clone(), false, cx)),
            )
            .child(self.render_date_line(doc, cx))
            .children(self.render_speaker_line(doc, cx))
            .into_any_element()
    }

    /// "Today at 11:00 AM · 1 min · Zoom", and "Mic only" in amber when only
    /// the microphone was recorded.
    fn render_date_line(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        use super::page_search::{MetadataField, app_chip, audio_chip};
        let lb = cx.lb().clone();
        let meeting = &doc.meeting;
        let mut items: Vec<(MetadataField, String, bool)> = vec![
            (
                MetadataField::Date,
                presentation::date_text(meeting.started_at, chrono::Local::now().date_naive()),
                false,
            ),
            (
                MetadataField::Duration,
                model::duration_label(meeting),
                false,
            ),
        ];
        if let Some(app) = app_chip(meeting) {
            items.push((MetadataField::App, app, false));
        }
        if let Some(audio) = audio_chip(meeting) {
            items.push((MetadataField::AudioSource, audio.to_string(), true));
        }
        let mut row = h_flex()
            .flex_wrap()
            .items_center()
            .text_size(ty::SECONDARY)
            .text_color(lb.supporting);
        for (ix, (field, text, warning)) in items.into_iter().enumerate() {
            if ix > 0 {
                row = row.child(div().flex_none().child(" · "));
            }
            // Each part is its own line: "25 دقيقة" keeps its number in
            // Arabic only with the right-to-left mark (as page search sees it).
            let text = lokalbot_i18n::directional(text);
            let marked =
                self.find_marked(Location::Metadata(field), &text, text.clone(), false, cx);
            row = row.child(if warning {
                div()
                    .id("meeting-mic-only")
                    .flex_none()
                    .text_color(lb.attention_text)
                    .child(marked)
                    .tooltip(|window, cx| {
                        Tooltip::new(lokalbot_i18n::tr(
                            "Only your microphone was recorded. Other participants are captured only if your mic picked them up.",
                        ))
                        .build(window, cx)
                    })
                    .into_any_element()
            } else {
                div().flex_none().child(marked).into_any_element()
            });
        }
        row.into_any_element()
    }

    /// Everyone who spoke, then "Name 2 speakers…" while voices need names.
    fn render_speaker_line(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> Option<AnyElement> {
        if doc.speakers.is_empty() {
            return None;
        }
        let lb = cx.lb().clone();
        let unnamed = doc.unnamed().count();
        let mut row = h_flex()
            .pt(px(2.))
            .flex_wrap()
            .gap_x(px(14.))
            .gap_y(px(5.))
            .items_center();
        for (ix, speaker) in doc.speakers.iter().enumerate() {
            let needs_name = speaker.needs_name;
            let key = speaker.key.clone();
            let tooltip: SharedString = if needs_name {
                lokalbot_i18n::tr("Name this speaker").into()
            } else {
                lokalbot_i18n::format("Rename speaker: {name}", &[("name", speaker.name.clone())])
                    .into()
            };
            row = row.child(
                h_flex()
                    .id(("meeting-speaker", ix))
                    .flex_none()
                    .gap(px(6.))
                    .items_center()
                    .cursor_pointer()
                    .child(ui::status_dot(
                        super::speaker_color(speaker.color, cx),
                        px(7.),
                    ))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(if needs_name { lb.text } else { lb.supporting })
                            .when(needs_name, |this| {
                                this.underline()
                                    .text_decoration_1()
                                    .text_decoration_color(lb.text_secondary)
                            })
                            .when(!needs_name, |this| this.hover(|s| s.underline()))
                            .child(speaker.name.clone()),
                    )
                    .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        if needs_name {
                            this.open_naming_sheet(window, cx);
                        } else {
                            this.open_name_speaker_key(&key, window, cx);
                        }
                    })),
            );
        }
        if unnamed > 0 {
            let label = if unnamed == 1 {
                lokalbot_i18n::tr("Name speaker…").to_string()
            } else {
                lokalbot_i18n::mac("Name %lld speakers…", &[&lokalbot_i18n::number(unnamed)])
            };
            row =
                row.child(attention_chip("meeting-name-speakers", label, cx).on_click(
                    cx.listener(|this, _, window, cx| this.open_naming_sheet(window, cx)),
                ));
        }
        Some(row.into_any_element())
    }

    // ------------------------------------------------------------- player

    /// One slim bar under the title on every tab: play, who is speaking and
    /// what is being said at the playhead, the waveform, the time and speed
    /// (`MeetingPlayerBar`). It takes the panels' raised surface.
    fn render_player(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        if !doc.has_audio || self.player.is_none() {
            let label = if doc.has_audio && self.player_loading {
                lokalbot_i18n::tr("Loading recording…")
            } else {
                lokalbot_i18n::tr("No recording available")
            };
            return panel_surface(cx)
                .id("meeting-audio-placeholder")
                .px(px(14.))
                .py(px(9.))
                .min_h(px(48.))
                .flex()
                .items_center()
                .gap(px(12.))
                .child(
                    div()
                        .flex_none()
                        .size(px(26.))
                        .rounded_full()
                        .bg(lb.text_secondary)
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(crate::ui::waveform::play_glyph(px(10.), lb.panel)),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(label),
                )
                .into_any_element();
        }
        let (current, duration) = self.playback_times(doc.meeting.duration_seconds());
        let caption = caption_at(doc, current);
        let page = cx.entity().downgrade();
        let hover_page = page.clone();
        let speed_target = page.clone();
        let speed = self.speed;
        let waveform = crate::ui::waveform::waveform(
            "meeting-waveform",
            doc.peaks.clone(),
            self.playhead,
            self.hover,
            duration,
            move |hover, _, cx| {
                let _ = hover_page.update(cx, |this, cx| {
                    if this.hover != hover {
                        this.hover = hover;
                        cx.notify();
                    }
                });
            },
            move |at, _, cx| {
                let _ = page.update(cx, |this, cx| this.seek(at, cx));
            },
            cx,
        )
        .h(px(if caption.is_some() { 24. } else { 40. }));
        panel_surface(cx)
            .id("meeting-audio-player")
            .px(px(14.))
            .py(px(9.))
            .flex()
            .items_center()
            .gap(px(12.))
            .child(
                div()
                    .id("audio-play")
                    .flex_none()
                    .size(px(30.))
                    .rounded_full()
                    .bg(lb.accent_fill)
                    .hover(|s| s.opacity(0.9))
                    .cursor_pointer()
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(if self.playing {
                        h_flex()
                            .gap(px(3.))
                            .child(div().w(px(3.)).h(px(11.)).rounded(px(1.)).bg(white()))
                            .child(div().w(px(3.)).h(px(11.)).rounded(px(1.)).bg(white()))
                            .into_any_element()
                    } else {
                        crate::ui::waveform::play_glyph(px(12.), white()).into_any_element()
                    })
                    .tooltip(|window, cx| {
                        Tooltip::new(lokalbot_i18n::tr("Play / pause (Space)")).build(window, cx)
                    })
                    .on_click(cx.listener(|this, _, _, cx| this.toggle_playback(cx))),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(4.))
                    .when_some(caption, |this, row| {
                        this.child(self.render_caption(doc, row, cx))
                    })
                    .child(waveform),
            )
            .child(
                div()
                    .flex_none()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(format!(
                        "{} / {}",
                        action_row::short_stamp(current),
                        action_row::short_stamp(duration)
                    )),
            )
            .child(
                Button::new("audio-speed")
                    .ghost()
                    .small()
                    .label(speed_label(speed))
                    .dropdown_caret(true)
                    .dropdown_menu(move |menu, _, _| {
                        let mut menu = menu;
                        for value in [0.75f32, 1., 1.25, 1.5, 1.75, 2.] {
                            let target = speed_target.clone();
                            menu = menu.item(
                                PopupMenuItem::new(speed_label(value))
                                    .checked((speed - value).abs() < 0.01)
                                    .on_click(move |_, _, cx| {
                                        let _ =
                                            target.update(cx, |this, cx| this.set_speed(value, cx));
                                    }),
                            );
                        }
                        let target = speed_target.clone();
                        menu.separator().item(
                            PopupMenuItem::new(lokalbot_i18n::tr("Reset to 1x")).on_click(
                                move |_, _, cx| {
                                    let _ = target.update(cx, |this, cx| this.set_speed(1., cx));
                                },
                            ),
                        )
                    }),
            )
            .into_any_element()
    }

    /// Who is speaking and what is being said at the playhead, with "Show in
    /// transcript" off the Transcript tab.
    fn render_caption(&self, doc: &MeetingDoc, row: usize, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let Some(line) = doc.rows.get(row) else {
            return div().into_any_element();
        };
        let start = line.start;
        h_flex()
            .w_full()
            .gap(px(6.))
            .items_center()
            .child(ui::status_dot(super::speaker_color(line.color, cx), px(7.)))
            .child(
                div()
                    .flex_none()
                    .max_w(px(200.))
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(line.name.clone()),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(line.text.clone()),
            )
            .when(self.tab != MeetingTab::Transcript, |this| {
                this.child(
                    div().flex_none().child(
                        ui::link(
                            "meeting-show-in-transcript",
                            lokalbot_i18n::tr("Show in transcript"),
                            {
                                let page = cx.entity().downgrade();
                                move |_, cx| {
                                    let _ = page
                                        .update(cx, |this, cx| this.show_in_transcript(start, cx));
                                }
                            },
                            cx,
                        )
                        .text_size(ty::SECONDARY),
                    ),
                )
            })
            .into_any_element()
    }

    // ------------------------------------------------------------- status

    /// One line of status above the tab's content: what happened and, when
    /// there is one, the single thing to do about it (`MeetingStatusBanner`).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn banner(
        &self,
        tone: BannerTone,
        icon: Option<Ico>,
        busy: bool,
        message: AnyElement,
        trailing: Vec<AnyElement>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let (tint, icon_color) = match tone {
            BannerTone::Attention => (lb.attention, lb.attention_text),
            BannerTone::Info => (lb.accent_fill, lb.accent_text),
        };
        ui::status_surface(tint, cx)
            .w_full()
            .px(px(12.))
            .py(px(9.))
            .flex()
            .flex_wrap()
            .items_center()
            .gap(px(10.))
            .when(busy, |this| this.child(Spinner::new().small()))
            .when_some(icon.filter(|_| !busy), |this, icon| {
                this.child(ui::icon(icon, px(15.), icon_color))
            })
            .child(
                div()
                    .flex_1()
                    .min_w(px(160.))
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(message),
            )
            .children(trailing)
            .into_any_element()
    }

    /// The status lines above the tab's content, in the Mac's order
    /// (`meetingStatusContent`).
    pub(super) fn render_status(
        &self,
        doc: &MeetingDoc,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        let mut out = Vec::new();
        if doc.meeting.is_sample() {
            out.push(crate::sample::render_banner(
                &self.data,
                doc.meeting.id,
                doc.has_transcript(),
                doc.has_summary(),
                cx,
            ));
        }
        let outside_audio = doc.additional_audio > 0.1;
        if doc.capture_needs_attention || outside_audio {
            let message = v_flex()
                .gap(px(2.))
                .when(doc.capture_needs_attention, |this| {
                    this.child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Audio capture was interrupted or saving reported an error. Review the saved recording for missing audio.",
                    )))
                })
                .when(outside_audio, |this| {
                    this.child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Additional saved audio is outside the meeting boundaries.",
                    )))
                })
                .into_any_element();
            let trailing = if outside_audio {
                let meeting = doc.meeting.clone();
                let data = self.data.clone();
                vec![
                    ui::controls::bordered(
                        "review-saved-audio",
                        lokalbot_i18n::tr("Edit start and end…"),
                    )
                    .small()
                    .on_click(move |_, window, cx| {
                        super::dialogs::BoundarySheet::open(
                            data.clone(),
                            meeting.clone(),
                            window,
                            cx,
                        );
                    })
                    .into_any_element(),
                ]
            } else {
                Vec::new()
            };
            out.push(self.banner(
                BannerTone::Attention,
                Some(Ico::TriangleAlert),
                false,
                message,
                trailing,
                cx,
            ));
        }
        if doc.recovery_needs_attention {
            out.push(self.banner(
                BannerTone::Attention,
                Some(Ico::TriangleAlert),
                false,
                crate::ui::text::paragraph(lokalbot_i18n::tr(
                    "Some recovery audio could not be verified. Saved audio and original checkpoints are retained.",
                )),
                Vec::new(),
                cx,
            ));
        }
        let stage = self.data.read(cx).processing.get(&doc.meeting.id).cloned();
        let processing = stage
            .as_ref()
            .is_some_and(|stage| !matches!(stage, ProcessingStage::Failed(_)));
        if let Some(stage) = stage {
            out.push(self.render_stage(doc, &stage, cx));
        }
        if doc
            .transcript
            .as_ref()
            .is_some_and(|t| t.segments.is_empty())
        {
            out.push(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.supporting)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "No speech detected. Saved audio remains available for playback and export.",
                    )))
                    .into_any_element(),
            );
        }
        if let Some(progress) = &doc.partial_progress {
            out.push(
                v_flex()
                    .gap(px(3.))
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.text)
                            .child(progress.clone()),
                    )
                    .child(
                        div().text_size(ty::CAPTION).text_color(lb.supporting).child(
                            crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Source-linked notes and actions are saved below. Actions become editable when the notes finish.",
                            )),
                        ),
                    )
                    .into_any_element(),
            );
        } else if doc.notes_need_refresh && self.tab == MeetingTab::Summary && !processing {
            out.push(self.render_refresh_banner(doc, cx));
        }
        if !doc.unmatched_edits.is_empty() {
            out.push(self.render_unmatched_edits(doc, cx));
        }
        if let Some(notice) = &doc.speaker_notice {
            out.push(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(lokalbot_i18n::tr(notice).to_string())
                    .into_any_element(),
            );
        }
        out
    }

    /// Processing, waiting for models or failed, each with its one action.
    fn render_stage(
        &self,
        doc: &MeetingDoc,
        stage: &ProcessingStage,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let label = stage_label(stage);
        let marked = self.find_text(Location::Status, &label, label.clone(), cx);
        match stage {
            ProcessingStage::Failed(_) => self.banner(
                BannerTone::Attention,
                Some(Ico::TriangleAlert),
                false,
                div()
                    .text_color(lb.recording_text)
                    .child(marked)
                    .into_any_element(),
                vec![
                    ui::controls::bordered("status-retry", lokalbot_i18n::tr("Retry"))
                        .small()
                        .on_click(cx.listener(|this, _, _, cx| this.retry_processing(cx)))
                        .into_any_element(),
                ],
                cx,
            ),
            ProcessingStage::WaitingForModels => self.banner(
                BannerTone::Info,
                Some(Ico::CircleArrowDown),
                false,
                marked,
                vec![
                    ui::controls::bordered(
                        "status-download",
                        lokalbot_i18n::tr("Download & process"),
                    )
                    .small()
                    .on_click(cx.listener(|this, _, _, cx| this.retry_processing(cx)))
                    .into_any_element(),
                ],
                cx,
            ),
            _ => {
                // With nothing written yet, say what will appear and offer
                // the transcript meanwhile. A refresh keeps the earlier
                // summary below.
                let awaits_first = self.tab == MeetingTab::Summary && !doc.has_summary_content();
                let message = v_flex()
                    .gap(px(2.))
                    .child(marked)
                    .when(awaits_first, |this| {
                        this.child(div().text_color(lb.supporting).child(
                            crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Recap, decisions and actions appear here when it is done.",
                            )),
                        ))
                    })
                    .into_any_element();
                let trailing = if awaits_first && doc.has_transcript() {
                    vec![
                        ui::controls::bordered(
                            "meeting-read-transcript",
                            lokalbot_i18n::tr("Read the transcript"),
                        )
                        .small()
                        .on_click(
                            cx.listener(|this, _, _, cx| this.set_tab(MeetingTab::Transcript, cx)),
                        )
                        .into_any_element(),
                    ]
                } else {
                    Vec::new()
                };
                self.banner(BannerTone::Info, None, true, message, trailing, cx)
            }
        }
    }

    /// Offered only after speaker names changed. The summary written before
    /// the change stays on the page until the refresh finishes. Where the
    /// refresh runs is said beside the button, as the consent boundary is.
    fn render_refresh_banner(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let settings = &self.data.read(cx).settings;
        let local = settings.think_is_local();
        let blocked = !lokalbot_ai::think::allows_automatic_main_inference(settings);
        let destination: SharedString = if local {
            lokalbot_i18n::tr("On this PC").into()
        } else if blocked {
            lokalbot_i18n::tr("AI: connection blocked").into()
        } else {
            crate::state::remote_ai_hosts(settings)
                .into_iter()
                .next()
                .unwrap_or_else(|| lokalbot_i18n::tr("AI: local + remote").to_string())
                .into()
        };
        let detail: SharedString = if local {
            lokalbot_i18n::tr("Refreshing processes the transcript on this PC.").into()
        } else {
            lokalbot_i18n::tr(
                "Refreshing sends the transcript and confirmed names to your approved model server.",
            )
            .into()
        };
        let can_refresh = doc.has_transcript();
        self.banner(
            BannerTone::Info,
            Some(Ico::RotateCcw),
            false,
            crate::ui::text::paragraph(lokalbot_i18n::tr(
                "Speaker names changed after this summary was written.",
            )),
            vec![
                div()
                    .id("meeting-refresh-destination")
                    .flex_none()
                    .max_w(px(220.))
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .text_color(if blocked && !local {
                        lb.attention_text
                    } else {
                        lb.supporting
                    })
                    .child(destination)
                    .tooltip(move |window, cx| Tooltip::new(detail.clone()).build(window, cx))
                    .into_any_element(),
                ui::controls::bordered(
                    "meeting-refresh-summary",
                    lokalbot_i18n::tr("Refresh summary"),
                )
                .small()
                .disabled(!can_refresh)
                .on_click(cx.listener(|this, _, _, cx| this.process(false, true, cx)))
                .into_any_element(),
            ],
            cx,
        )
    }

    fn render_unmatched_edits(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let expanded = self.unmatched_expanded;
        v_flex()
            .gap(px(6.))
            .child(
                h_flex()
                    .id("unmatched-edits")
                    .gap(px(6.))
                    .items_center()
                    .cursor_pointer()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(lb.text)
                    .child(ui::icon(
                        if expanded {
                            Ico::ChevronDown
                        } else if lokalbot_i18n::current().rtl {
                            Ico::ChevronLeft
                        } else {
                            Ico::ChevronRight
                        },
                        px(13.),
                        lb.text_secondary,
                    ))
                    .child(lokalbot_i18n::format(
                        "Review {count} unmatched action edits",
                        &[("count", doc.unmatched_edits.len().to_string())],
                    ))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.unmatched_expanded = !this.unmatched_expanded;
                        cx.notify();
                    })),
            )
            .when(expanded, |this| {
                this.child(
                    div().text_size(ty::CAPTION).text_color(lb.supporting).child(
                        crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "These saved edits did not match a single regenerated action. Apply them to the correct action after reviewing its source.",
                        )),
                    ),
                )
                .children(doc.unmatched_edits.iter().map(|(text, detail)| {
                    v_flex()
                        .gap(px(2.))
                        .child(div().text_size(ty::BODY).text_color(lb.text).child(text.clone()))
                        .child(
                            div()
                                .text_size(ty::CAPTION)
                                .text_color(lb.supporting)
                                .child(detail.clone()),
                        )
                }))
            })
            .into_any_element()
    }

    // ------------------------------------------------------------ summary

    /// The Summary tab leads with the outcome, each part on its own panel:
    /// the recap, decisions, actions split by whose they are, open
    /// questions, what was on screen, and the full summary on demand.
    fn render_summary(&mut self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let processing = self.data.read(cx).is_processing(doc.meeting.id);
        let mut panels: Vec<AnyElement> = Vec::new();
        if doc.has_summary_content() {
            if !doc.recap.is_empty() {
                panels.push(self.render_recap(doc, cx));
            }
            if !doc.shown_decisions().is_empty() {
                panels.push(self.render_decisions(doc, cx));
            }
            panels.push(self.render_actions(doc, cx));
            if !doc.shown_questions().is_empty() {
                panels.push(self.render_questions(doc, cx));
            }
        } else if !processing {
            panels.push(
                SectionPanelLead::new("meeting-no-summary")
                    .child(self.empty_row_marked(
                        Section::Summary,
                        lokalbot_i18n::tr("No summary yet."),
                        cx,
                    ))
                    .into_any_element(),
            );
        }
        if !doc.screen.materials.is_empty() {
            panels.push(self.render_screen_materials(doc, cx));
        }
        if doc.has_summary() {
            panels.push(self.render_full_summary(doc, cx));
        }
        v_flex()
            .w_full()
            .gap(layout::PANEL_GAP)
            .children(panels)
            .into_any_element()
    }

    /// The recap as the lead panel: five points, then "Show N More Points".
    fn render_recap(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let total = doc.recap.len();
        let shown = if self.recap_expanded {
            total
        } else {
            total.min(5)
        };
        let prose = layout::scaled(layout::PROSE, self.text_scale(cx));
        let points = doc.recap.iter().take(shown).map(|point| {
            div()
                .max_w(prose)
                .text_size(ty::READING)
                .line_height(px(22.))
                .text_color(lb.text)
                .child(crate::ui::text::paragraph(point.clone()))
                .into_any_element()
        });
        let toggle = (total > 5).then(|| {
            let label = if self.recap_expanded {
                lokalbot_i18n::tr("Show Less").to_string()
            } else {
                lokalbot_i18n::format("Show {0} More Points", &[("0", (total - 5).to_string())])
            };
            div()
                .id("recap-more")
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.accent_text)
                .cursor_pointer()
                .hover(|s| s.underline())
                .child(label)
                .on_click(cx.listener(|this, _, _, cx| {
                    this.recap_expanded = !this.recap_expanded;
                    cx.notify();
                }))
                .into_any_element()
        });
        SectionPanelLead::new("meeting-recap")
            .child(v_flex().gap(px(10.)).children(points).children(toggle))
            .into_any_element()
    }

    /// Decisions: what was decided, and at the row's trailing edge the time
    /// it was said, which plays in place.
    fn render_decisions(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let decisions = doc.shown_decisions();
        let rows: Vec<AnyElement> = decisions
            .iter()
            .enumerate()
            .map(|(ix, decision)| {
                let shown = doc.speakers_text(&decision.text);
                let citation = decision.citations.first().cloned();
                h_flex()
                    .w_full()
                    .py(px(10.))
                    .gap(px(14.))
                    .items_start()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .line_height(px(20.))
                            .text_color(lb.text)
                            .child(self.find_text(
                                Location::Decision(ix, DecisionField::Text),
                                &shown,
                                shown.clone(),
                                cx,
                            )),
                    )
                    .when_some(citation, |this, citation| {
                        let start = citation.start;
                        let page = cx.entity().downgrade();
                        let time = action_row::play_time(
                            ("decision-play", ix),
                            start,
                            Some(citation.excerpt.clone().into()),
                            move |_, cx| {
                                let _ = page.update(cx, |this, cx| this.play_in_place(start, cx));
                            },
                            cx,
                        )
                        .mr(px(-4.));
                        this.child(self.find_tinted(
                            time,
                            Location::Decision(ix, DecisionField::Evidence),
                            cx,
                        ))
                    })
                    .into_any_element()
            })
            .collect();
        SectionPanel::new("meeting-decisions", lokalbot_i18n::tr("Decisions"))
            .icon(Ico::Check)
            .count(decisions.len())
            .rows(rows)
            .into_any_element()
    }

    /// One panel for every action: a band for yours, then a band for
    /// everyone else's. A side with none says so under its band.
    fn render_actions(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let actions = doc.shown_actions();
        let panel = ActionsPanel::new(actions);
        let mut section = SectionPanel::new("meeting-actions", lokalbot_i18n::tr("Actions"))
            .section(crate::state::Section::Actions);
        if let Some(count) = panel.count() {
            section = section.count(count);
        }
        if panel.shows_actions_link(
            doc.has_projection && doc.partial_progress.is_none(),
            doc.meeting.is_sample(),
        ) {
            let data = self.data.clone();
            section = section.trailing_link(
                "meeting-actions-open-all",
                lokalbot_i18n::tr("Also in Actions"),
                move |_, cx| data.update(cx, |data, cx| data.open_actions(cx)),
            );
        }
        if !panel.shows_bands() {
            return section
                .child(div().px(metric::PANEL_INSET).child(self.empty_row_marked(
                    Section::ActionItems,
                    lokalbot_i18n::tr("No action items were extracted from this meeting."),
                    cx,
                )))
                .into_any_element();
        }
        let for_you = lokalbot_i18n::mac(
            "For you · %lld",
            &[&lokalbot_i18n::number(panel.for_you.len())],
        );
        let for_others = lokalbot_i18n::mac(
            "For others · %lld",
            &[&lokalbot_i18n::number(panel.for_others.len())],
        );
        let yours = if panel.for_you.is_empty() {
            self.empty_group_line(lokalbot_i18n::tr("Nothing for you from this meeting."), cx)
        } else {
            self.action_rows(doc, &panel.for_you, false, cx)
        };
        let theirs = if panel.for_others.is_empty() {
            self.empty_group_line(
                lokalbot_i18n::tr("Nothing for others from this meeting."),
                cx,
            )
        } else {
            self.action_rows(doc, &panel.for_others, true, cx)
        };
        section
            .band(for_you, false)
            .child(yours)
            .band(for_others, true)
            .child(theirs)
            .into_any_element()
    }

    /// The one line under a band whose side of the meeting has no actions.
    fn empty_group_line(&self, text: &str, cx: &mut Context<Self>) -> AnyElement {
        div()
            .w_full()
            .px(metric::PANEL_INSET)
            .py(px(11.))
            .text_size(ty::SECONDARY)
            .text_color(cx.lb().supporting)
            .child(crate::ui::text::paragraph(text.to_string()))
            .into_any_element()
    }

    fn action_rows(
        &self,
        doc: &MeetingDoc,
        rows: &[usize],
        shows_owner: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let count = rows.len();
        v_flex()
            .w_full()
            .children(rows.iter().enumerate().flat_map(|(position, &ix)| {
                let mut parts = vec![
                    div()
                        .w_full()
                        .pl(metric::PANEL_INSET)
                        .pr(px(6.))
                        .child(self.render_action(ix, doc, shows_owner, cx))
                        .into_any_element(),
                ];
                if position + 1 < count {
                    parts.push(
                        div()
                            .px(metric::PANEL_INSET)
                            .child(ui::divider(cx))
                            .into_any_element(),
                    );
                }
                parts
            }))
            .into_any_element()
    }

    /// One action (`MeetingActionRow`): toggle, text, then the owner (on
    /// other people's actions) as a small menu, the due date coloured as in
    /// Actions, and a ▶ time that plays in place; the "…" menu at the end.
    fn render_action(
        &self,
        ix: usize,
        doc: &MeetingDoc,
        shows_owner: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(action) = doc.shown_actions().get(ix).cloned() else {
            return div().into_any_element();
        };
        let editable = doc.partial_progress.is_none();
        // Previous notes kept on screen during a refresh can't change state.
        let can_set_status = editable && doc.has_projection;
        let done = action.status == ActionStatus::Done;
        let toggle = {
            let page = cx.entity().downgrade();
            let id = action.id.clone();
            action_row::status_toggle(
                ("action-toggle", ix),
                action.status,
                false,
                move |_, cx| {
                    if !can_set_status {
                        return;
                    }
                    let id = id.clone();
                    let _ = page.update(cx, |this, cx| {
                        this.set_action_status(
                            id,
                            if done {
                                ActionStatus::Open
                            } else {
                                ActionStatus::Done
                            },
                            cx,
                        )
                    });
                },
                cx,
            )
            .when(!can_set_status, |this| this.opacity(0.5).cursor_default())
        };
        let options = presentation::owner_options(
            action.owner.as_deref(),
            action.is_for_user,
            &doc.speakers,
            &doc.stored_names,
            &doc.invited,
        );
        let mut meta: Vec<AnyElement> = Vec::new();
        if shows_owner {
            meta.push(self.owner_chip(ix, &action, doc, &options, editable, cx));
        }
        if let Some(due) = action.due.clone() {
            let label = action.due_label.clone().unwrap_or(due);
            let tone = DueTone::of(
                action.resolved_due_date,
                action.status == ActionStatus::Open,
                chrono::Local::now().date_naive(),
            );
            meta.push(
                self.find_tinted(
                    action_row::due_text(("action-due", ix), label, tone, cx),
                    Location::Action(ix, ActionField::Due),
                    cx,
                )
                .into_any_element(),
            );
        }
        if let Some(citation) = action.citation.clone() {
            let start = citation.start;
            let page = cx.entity().downgrade();
            let time = action_row::play_time(
                ("action-play", ix),
                start,
                Some(citation.excerpt.into()),
                move |_, cx| {
                    let _ = page.update(cx, |this, cx| this.play_in_place(start, cx));
                },
                cx,
            );
            meta.push(
                self.find_tinted(time, Location::Action(ix, ActionField::Evidence), cx)
                    .into_any_element(),
            );
        }
        let menu: AnyElement = if editable {
            self.action_menu(ix, &action, doc, options, can_set_status, cx)
        } else {
            Button::new(("action-menu", ix))
                .ghost()
                .small()
                .icon(Ico::Ellipsis)
                .disabled(true)
                .into_any_element()
        };
        action_row::action_row_with(
            toggle,
            self.find_text(
                Location::Action(ix, ActionField::Text),
                &action.text,
                action.text.clone(),
                cx,
            ),
            done,
            meta,
            None,
            menu,
            cx,
        )
        .into_any_element()
    }

    /// Someone else's action carries its owner as a small menu; it turns
    /// amber while the owner is missing or still an unnamed voice
    /// (`MeetingActionOwnerMenu`).
    fn owner_chip(
        &self,
        ix: usize,
        action: &MeetingAction,
        doc: &MeetingDoc,
        options: &[OwnerOption],
        editable: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let attention = presentation::owner_needs_attention(
            action.owner.as_deref(),
            action.owner_label.as_deref(),
            action.is_for_user,
        );
        let shown = owner_text(action);
        let color = if attention {
            lb.attention_text
        } else {
            lb.text
        };
        let chip = h_flex()
            .gap(px(3.))
            .items_center()
            .pl(px(7.))
            .pr(px(5.))
            .py(px(2.))
            .rounded(px(5.))
            .border_1()
            .border_color(if attention {
                lb.attention.opacity(0.4)
            } else {
                lb.text.opacity(0.16)
            })
            .when(attention, |this| this.bg(lb.attention.opacity(0.12)))
            .text_size(ty::SECONDARY)
            .text_color(color)
            .child(self.find_text(
                Location::Action(ix, ActionField::Owner),
                &shown,
                shown.clone(),
                cx,
            ))
            .child(ui::icon(Ico::ChevronDown, px(10.), color.opacity(0.7)));
        let offers_naming =
            doc.unnamed().next().is_some() && attention && action.owner_label.is_some();
        let page = cx.entity().downgrade();
        let options = options.to_vec();
        let action = action.clone();
        let tooltip: SharedString =
            lokalbot_i18n::format("Owner: {0}", &[("0", shown.clone())]).into();
        Button::new(("action-owner", ix))
            .ghost()
            .p_0()
            .h_auto()
            .disabled(!editable)
            .tooltip(tooltip)
            .child(chip)
            .dropdown_menu(move |menu, _, _| {
                let item = |option: &OwnerOption| {
                    let page = page.clone();
                    let option = option.clone();
                    let action = action.clone();
                    PopupMenuItem::new(option.label())
                        .checked(option.is_selected)
                        .on_click(move |_, _, cx| {
                            let _ =
                                page.update(cx, |this, cx| this.set_owner(&option, &action, cx));
                        })
                };
                let mut menu = menu;
                for option in options
                    .iter()
                    .filter(|o| matches!(o.kind, OwnerKind::You | OwnerKind::Speaker))
                {
                    menu = menu.item(item(option));
                }
                let invited: Vec<&OwnerOption> = options
                    .iter()
                    .filter(|o| o.kind == OwnerKind::Invited)
                    .collect();
                if !invited.is_empty() {
                    menu = menu.separator().label(lokalbot_i18n::tr("Invited"));
                    for option in invited {
                        menu = menu.item(item(option));
                    }
                }
                menu = menu.separator();
                if offers_naming {
                    let page = page.clone();
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Name this speaker…")).on_click(
                            move |_, window, cx| {
                                let _ =
                                    page.update(cx, |this, cx| this.open_naming_sheet(window, cx));
                            },
                        ),
                    );
                }
                for option in options.iter().filter(|o| o.kind == OwnerKind::None) {
                    menu = menu.item(item(option));
                }
                menu
            })
            .into_any_element()
    }

    /// The row's "…" menu: status, Owner, corrections and hand-offs.
    fn action_menu(
        &self,
        ix: usize,
        action: &MeetingAction,
        doc: &MeetingDoc,
        options: Vec<OwnerOption>,
        can_set_status: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let page = cx.entity().downgrade();
        let action = action.clone();
        let data = self.data.clone();
        let meeting = doc.meeting.clone();
        action_row::options_menu(("action-menu", ix), move |menu, window, cx| {
            let mut menu = menu;
            for option in [
                ActionStatus::Open,
                ActionStatus::Done,
                ActionStatus::Deferred,
            ] {
                let page = page.clone();
                let id = action.id.clone();
                menu = menu.item(
                    PopupMenuItem::new(lokalbot_i18n::tr(option.label()))
                        .checked(option == action.status)
                        .disabled(!can_set_status)
                        .on_click(move |_, _, cx| {
                            let id = id.clone();
                            let _ =
                                page.update(cx, |this, cx| this.set_action_status(id, option, cx));
                        }),
                );
            }
            menu = menu.separator();
            if !options.is_empty() {
                let options = options.clone();
                let page = page.clone();
                let action = action.clone();
                menu = menu.submenu(lokalbot_i18n::tr("Owner"), window, cx, move |sub, _, _| {
                    let mut sub = sub;
                    for option in &options {
                        let page = page.clone();
                        let option = option.clone();
                        let action = action.clone();
                        sub = sub.item(
                            PopupMenuItem::new(option.label())
                                .checked(option.is_selected)
                                .on_click(move |_, _, cx| {
                                    let _ = page.update(cx, |this, cx| {
                                        this.set_owner(&option, &action, cx)
                                    });
                                }),
                        );
                    }
                    sub
                });
            }
            let correct = page.clone();
            let correct_action = action.clone();
            let prompt = lokalbot_core::agent_handoff::agent_prompt_from_meeting(
                &meeting.display_title(),
                &action.text,
            );
            let agent_data = data.clone();
            menu = menu
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Correct owner or due date")).on_click(
                        move |_, window, cx| {
                            let action = correct_action.clone();
                            let _ = correct
                                .update(cx, |this, cx| this.open_correction(action, window, cx));
                        },
                    ),
                )
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Open in Agent")).on_click(
                        move |_, _, cx| {
                            let prompt = prompt.clone();
                            agent_data.update(cx, |data, cx| data.open_agent(prompt, cx));
                        },
                    ),
                );
            for target in crate::agent_handoff::for_actions() {
                let data = data.clone();
                let meeting = meeting.clone();
                let id = action.id.clone();
                menu = menu.item(
                    PopupMenuItem::new(action_row::open_in_label(target)).on_click(
                        move |_, _, cx| {
                            crate::agent_handoff::hand_off_meeting_action(
                                &data,
                                &meeting,
                                id.clone(),
                                target,
                                cx,
                            )
                        },
                    ),
                );
            }
            menu
        })
        .into_any_element()
    }

    fn render_questions(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let questions = doc.shown_questions();
        SectionPanel::new("meeting-questions", lokalbot_i18n::tr("Open questions"))
            .icon(Ico::CircleQuestionMark)
            .count(questions.len())
            .rows(questions.iter().map(|question| {
                div()
                    .w_full()
                    .py(px(10.))
                    .text_size(ty::BODY)
                    .line_height(px(20.))
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(doc.speakers_text(question)))
            }))
            .into_any_element()
    }

    /// A panel that is only its header until it is opened in place.
    fn render_full_summary(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let expanded = self.full_notes_expanded;
        let page = cx.entity().downgrade();
        let mut panel =
            SectionPanel::new("meeting-full-summary", lokalbot_i18n::tr("Full summary"))
                .icon(Ico::TextAlignStart)
                .disclosure(expanded, move |_, cx| {
                    let _ = page.update(cx, |this, cx| {
                        this.full_notes_expanded = !this.full_notes_expanded;
                        cx.notify();
                    });
                });
        if expanded {
            let prose = layout::scaled(layout::PROSE, self.text_scale(cx));
            let matched = self.find_lines(Location::Summary, &doc.summary_body, cx);
            panel = panel.child(
                v_flex()
                    .w_full()
                    .max_w(prose + metric::PANEL_INSET * 2.)
                    .px(metric::PANEL_INSET)
                    .py(px(14.))
                    .gap(px(14.))
                    .when_some(doc.summary_meta.clone(), |this, meta| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.supporting)
                                .child(self.find_text(
                                    Location::SummaryMeta,
                                    &meta,
                                    meta.clone(),
                                    cx,
                                )),
                        )
                    })
                    .child(
                        div().text_size(ty::BODY).child(match matched {
                            Some(lines) => lines,
                            None => crate::ui::markdown_view::markdown(
                                SharedString::from(format!("summary-{}", doc.meeting.id)),
                                doc.summary_body.clone(),
                            )
                            .selectable(true)
                            .into_any_element(),
                        }),
                    ),
            );
        }
        panel.into_any_element()
    }

    // -------------------------------------------------------------- notes

    /// Your notes on one panel: the editor is its body, and the line that
    /// says whether they are saved is its footer.
    fn render_notes_tab(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let status = self.notes.status.clone();
        let mut panel = SectionPanel::new("meeting-notes", lokalbot_i18n::tr("Your notes"))
            .icon(Ico::Pencil)
            .child(
                div().w_full().px(px(6.)).py(px(6.)).child(
                    Textarea::new(&self.notes.input)
                        .large()
                        .appearance(false)
                        .h(px(420.)),
                ),
            )
            .footer(footer_text(status_text(&status)));
        if let NotesStatus::Failed(message) = status {
            panel = panel
                .footer(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_color(lb.attention_text)
                        .child(crate::ui::text::paragraph(message)),
                )
                .footer(crate::ui::section_panel::panel_link(
                    "notes-retry",
                    lokalbot_i18n::tr("Retry saving"),
                    {
                        let page = cx.entity().downgrade();
                        move |_, cx| {
                            let _ = page.update(cx, |this, cx| this.save_notes(false, cx));
                        }
                    },
                    cx,
                ));
        }
        panel.into_any_element()
    }

    // --------------------------------------------------------- on screen

    /// `MeetingScreenMaterialsSection`. The time plays the recording from
    /// when it first appeared, the capture opens in Timeline and a page whose
    /// address was captured can be reopened.
    fn render_screen_materials(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let rows: Vec<AnyElement> = doc
            .screen
            .materials
            .iter()
            .enumerate()
            .map(|(ix, material)| {
                let offset = material.first_offset;
                let data = self.data.clone();
                let snapshot = material.first_snapshot_id;
                let captured = doc
                    .screen
                    .moments
                    .iter()
                    .find(|m| m.snapshot_id == snapshot)
                    .map(|m| m.captured_at);
                let page = material.page_url.clone();
                let thumbnail = match self.screen_thumbnail(snapshot, cx) {
                    Some(ScreenImage::Ready(image)) => div()
                        .size_full()
                        .bg(gpui_kit::black().opacity(0.82))
                        .child(img(image).size_full().object_fit(ObjectFit::Contain))
                        .into_any_element(),
                    _ => div()
                        .size_full()
                        .flex()
                        .items_center()
                        .justify_center()
                        .bg(lb.chip_fill)
                        .child(ui::icon(Ico::Camera, px(16.), lb.text_secondary))
                        .into_any_element(),
                };
                h_flex()
                    .w_full()
                    .gap(px(12.))
                    .py(px(8.))
                    .items_center()
                    .child(
                        div().flex_none().child(
                            ui::link(
                                ("screen-play", ix),
                                lokalbot_core::time::stamp(offset),
                                {
                                    let page = cx.entity().downgrade();
                                    move |_, cx| {
                                        let _ = page.update(cx, |this, cx| {
                                            this.focus_at = Some(offset);
                                            this.play_from(offset, cx);
                                        });
                                    }
                                },
                                cx,
                            )
                            .text_size(ty::SECONDARY)
                            .tooltip(|window, cx| {
                                Tooltip::new(lokalbot_i18n::tr(
                                    "Play the recording from when this first appeared",
                                ))
                                .build(window, cx)
                            }),
                        ),
                    )
                    .child(
                        // The retained capture, opening in Timeline.
                        div()
                            .id(("screen-open", ix))
                            .w(px(74.))
                            .h(px(46.))
                            .flex_none()
                            .rounded(metric::ROW_RADIUS)
                            .overflow_hidden()
                            .child(thumbnail)
                            .when_some(captured, |this, at| {
                                this.cursor_pointer()
                                    .tooltip(|window, cx| {
                                        Tooltip::new(lokalbot_i18n::tr(
                                            "Open this capture in Timeline",
                                        ))
                                        .build(window, cx)
                                    })
                                    .on_click(move |_, _, cx| {
                                        data.update(cx, |data, cx| {
                                            data.open_screen_moment(snapshot, at, cx)
                                        });
                                    })
                            }),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .line_clamp(2)
                                    .child(material.title.clone()),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(screen_detail(material)),
                            ),
                    )
                    .when_some(page, |row, url| {
                        row.child(
                            div().flex_none().child(
                                ui::link(
                                    ("screen-page", ix),
                                    lokalbot_i18n::tr("Open Page"),
                                    move |_, cx| cx.open_url(&url),
                                    cx,
                                )
                                .text_size(ty::SECONDARY),
                            ),
                        )
                    })
                    .into_any_element()
            })
            .collect();
        SectionPanel::new(
            "meeting-on-screen",
            lokalbot_i18n::tr("On Screen During the Meeting"),
        )
        .icon(Ico::AppWindow)
        .count(doc.screen.materials.len())
        .rows(rows)
        .footer(footer_text(lokalbot_i18n::tr(
            "From screen memory on this computer. Time on screen is estimated from captures, which follow your screen retention setting.",
        )))
        .into_any_element()
    }

    /// A capture's small image, loading it the first time it is asked for.
    fn screen_thumbnail(&self, snapshot: i64, cx: &mut Context<Self>) -> Option<ScreenImage> {
        const PIXELS: u32 = 240;
        /// A call shows few documents; later rows keep their icon.
        const MAX: usize = 32;
        {
            let thumbnails = self.screen_thumbnails.borrow();
            if let Some(entry) = thumbnails.get(&snapshot) {
                return entry.clone();
            }
            if thumbnails.len() >= MAX {
                return None;
            }
        }
        self.screen_thumbnails.borrow_mut().insert(snapshot, None);
        let library = self.data.read(cx).library.clone();
        let thumbnails = self.screen_thumbnails.clone();
        cx.spawn(async move |this, cx| {
            let image = cx
                .background_spawn(async move {
                    let moment = library.screen_moment(snapshot).ok().flatten()?;
                    if moment.path.is_empty() {
                        return None;
                    }
                    Some(screen_image::load(&library, &moment, PIXELS))
                })
                .await;
            let _ = this.update(cx, |_, cx| {
                // A meeting that was left meanwhile gave its entries up.
                if let Some(entry) = thumbnails.borrow_mut().get_mut(&snapshot) {
                    *entry = image;
                    cx.notify();
                }
            });
        })
        .detach();
        None
    }

    /// Lets go of another meeting's pixels.
    pub(super) fn release_screen_thumbnails(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.screen_thumbnails_for != self.selected {
            self.screen_thumbnails_for = self.selected;
            let released = std::mem::take(&mut *self.screen_thumbnails.borrow_mut());
            for image in released.into_values().flatten() {
                if let ScreenImage::Ready(image) = image {
                    self.released_thumbnails.push(image);
                }
            }
        }
        for image in self.released_thumbnails.drain(..) {
            cx.drop_image(image, Some(window));
        }
    }

    pub(super) fn retry_processing(&mut self, cx: &mut Context<Self>) {
        if let Some(meeting_id) = self.selected {
            self.data
                .update(cx, |data, cx| data.retry_processing(meeting_id, cx));
        }
    }

    /// `MeetingOnScreenNowBar`: which window was in front at the playhead.
    pub(super) fn render_on_screen_now(
        &self,
        doc: &MeetingDoc,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let position = self.player.as_ref().map(|p| p.position()).or(self.focus_at);
        let moment = position.and_then(|at| doc.screen.moment(at)).cloned();
        let body = match moment {
            Some(moment) => {
                let data = self.data.clone();
                let (id, at) = (moment.snapshot_id, moment.captured_at);
                h_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(1.))
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(lokalbot_i18n::format(
                                        "On screen at {time}",
                                        &[("time", lokalbot_core::time::stamp(moment.offset))],
                                    )),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child(if moment.is_call {
                                        lokalbot_i18n::tr("The call").to_string()
                                    } else {
                                        moment.title.clone()
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .flex_none()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .child(moment.site.clone().unwrap_or_else(|| moment.app.clone())),
                    )
                    .child(
                        Button::new("screen-now-open")
                            .ghost()
                            .small()
                            .label(lokalbot_i18n::tr("Open Capture"))
                            .on_click(move |_, _, cx| {
                                data.update(cx, |data, cx| data.open_screen_moment(id, at, cx));
                            }),
                    )
                    .into_any_element()
            }
            None => div()
                .flex_1()
                .text_size(ty::SECONDARY)
                .text_color(lb.supporting)
                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                    "Play or select a transcript line to see what was on screen.",
                )))
                .into_any_element(),
        };
        panel_surface(cx)
            .px(px(14.))
            .py(px(10.))
            .flex()
            .items_center()
            .gap(px(10.))
            .child(ui::icon(Ico::AppWindow, px(15.), lb.text_secondary))
            .child(body)
            .into_any_element()
    }

    // ------------------------------------------------------------ actions

    /// A ▶ time on a decision or action: play from there and stay on the
    /// page. Without a recording, the line is shown in the transcript instead.
    pub(super) fn play_in_place(&mut self, seconds: f64, cx: &mut Context<Self>) {
        if self.player.is_some() {
            self.focus_at = Some(seconds);
            self.play_from(seconds, cx);
            cx.notify();
        } else {
            self.show_evidence(seconds, cx);
        }
    }

    /// The player's "Show in transcript": go to the line being said, without
    /// interrupting playback.
    pub(super) fn show_in_transcript(&mut self, seconds: f64, cx: &mut Context<Self>) {
        self.focus_at = Some(seconds);
        self.pending_reveal = true;
        self.set_tab(MeetingTab::Transcript, cx);
        self.reveal_focus();
        cx.notify();
    }

    /// Saves a new owner picked from a row's menu.
    pub(super) fn set_owner(
        &mut self,
        option: &OwnerOption,
        action: &MeetingAction,
        cx: &mut Context<Self>,
    ) {
        let Some(owner) = presentation::owner_correction(option, action) else {
            return;
        };
        let Some(doc) = self.doc.clone() else { return };
        if doc.partial_progress.is_some() {
            return;
        }
        let library = self.data.read(cx).library.clone();
        let meeting = doc.meeting.clone();
        let action_id = action.id.clone();
        let data = self.data.clone();
        cx.spawn(async move |_, cx| {
            let result = cx
                .background_spawn(async move {
                    library.correct_action(
                        &meeting,
                        &action_id,
                        ActionCorrection {
                            text: None,
                            owner: Some(owner),
                            due: None,
                        },
                    )
                })
                .await;
            data.update(cx, |data, cx| match result {
                Ok(()) => data.mark_library_changed(cx),
                Err(err) => data.show_error(
                    lokalbot_i18n::format(
                        "The correction could not be saved. {err}",
                        &[("err", format!("{err:#}"))],
                    ),
                    cx,
                ),
            });
        })
        .detach();
    }

    fn open_correction(
        &mut self,
        action: MeetingAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(doc) = self.doc.clone() else { return };
        // Actions become editable when the notes finish.
        if doc.partial_progress.is_some() {
            return;
        }
        CorrectionSheet::open(
            self.data.clone(),
            doc.meeting.clone(),
            action,
            &doc.review,
            window,
            cx,
        );
    }

    /// Renames one speaker (`WorkspaceSpeakerRenameSheet`).
    pub(super) fn open_name_speaker(
        &mut self,
        speaker: model::ReviewSpeaker,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(doc) = self.doc.clone() else { return };
        let Some(transcript) = doc.transcript.clone() else {
            return;
        };
        NameSpeakerSheet::open(
            self.data.clone(),
            doc.meeting.clone(),
            transcript,
            speaker,
            doc.identity.clone(),
            doc.speaker_notice.clone(),
            cx.entity().downgrade(),
            window,
            cx,
        );
    }

    pub(super) fn open_name_speaker_key(
        &mut self,
        key: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let speaker = self
            .doc
            .as_ref()
            .and_then(|doc| doc.review.iter().find(|s| s.key == key).cloned());
        if let Some(speaker) = speaker {
            self.open_name_speaker(speaker, window, cx);
        }
    }

    /// The one sheet that goes through this meeting's unnamed voices.
    pub(super) fn open_naming_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(doc) = self.doc.clone() else { return };
        if doc.transcript.is_none() {
            return;
        }
        super::naming::NamingSheet::open(
            self.data.clone(),
            doc,
            self.player.is_some(),
            cx.entity().downgrade(),
            window,
            cx,
        );
    }

    // --------------------------------------------------------------- find

    /// `text`, with Find's matches at `location` marked; the current one
    /// scrolls into view (`MeetingPageSearchMatch`).
    pub(super) fn find_text(
        &self,
        location: Location,
        source: &str,
        shown: impl Into<SharedString>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.find_marked(location, source, shown, true, cx)
    }

    /// A small control that can't mark its own words, tinted while Find has a
    /// match in it.
    fn find_tinted(
        &self,
        element: gpui_kit::Stateful<gpui_kit::Div>,
        location: Location,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Stateful<gpui_kit::Div> {
        if !self.find.matches.iter().any(|m| m.location == location) {
            return element;
        }
        let current = self
            .find
            .matches
            .get(self.find.current)
            .is_some_and(|m| m.location == location);
        let tint = cx.lb().attention.opacity(if current { 0.55 } else { 0.22 });
        element
            .relative()
            .bg(tint)
            .when(current, |this| this.child(self.find_anchor()))
    }

    fn empty_row_marked(
        &self,
        section: Section,
        text: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        div()
            .py(px(10.))
            .text_size(ty::BODY)
            .text_color(cx.lb().supporting)
            .child(self.find_text(Location::EmptyState(section), text, text, cx))
            .into_any_element()
    }

    /// `find_text`, for text that isn't in the overview's scroll view and so
    /// has nothing to scroll with `anchored` off.
    pub(super) fn find_marked(
        &self,
        location: Location,
        source: &str,
        shown: impl Into<SharedString>,
        anchored: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let shown: SharedString = shown.into();
        let matches: Vec<&super::page_search::PageMatch> = self
            .find
            .matches
            .iter()
            .filter(|found| found.location == location)
            .collect();
        // A shown text that differs from its source (names filled in) keeps
        // its ranges only when they still land on the same words.
        if matches.is_empty() || shown.as_ref() != source {
            return div().child(shown).into_any_element();
        }
        let current = self.find.matches.get(self.find.current);
        let lb = cx.lb().clone();
        let mut has_current = false;
        let highlights: Vec<_> = matches
            .iter()
            .map(|found| {
                let is_current = current.is_some_and(|c| *c == **found);
                has_current |= is_current;
                (found.range.clone(), highlight(&lb.attention, is_current))
            })
            .collect();
        div()
            .relative()
            .child(gpui_kit::StyledText::new(shown).with_highlights(highlights))
            .when(has_current && anchored, |this| {
                this.child(self.find_anchor())
            })
            .into_any_element()
    }

    /// Plain lines with Find's matches marked, while Find has a match in a
    /// Markdown block that cannot mark its own text; `None` otherwise.
    fn find_lines(
        &self,
        location: Location,
        text: &str,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let matches: Vec<&super::page_search::PageMatch> = self
            .find
            .matches
            .iter()
            .filter(|found| found.location == location)
            .collect();
        if matches.is_empty() {
            return None;
        }
        let current = self.find.matches.get(self.find.current);
        let lb = cx.lb().clone();
        let mut offset = 0;
        let mut lines = Vec::new();
        for line in text.split_inclusive('\n') {
            let span = offset..offset + line.len();
            offset = span.end;
            let shown = line.trim_end_matches('\n').to_string();
            let mut has_current = false;
            let highlights: Vec<_> = matches
                .iter()
                .filter(|found| found.range.start >= span.start && found.range.end <= span.end)
                .map(|found| {
                    let is_current = current.is_some_and(|c| *c == **found);
                    has_current |= is_current;
                    (
                        found.range.start - span.start..found.range.end - span.start,
                        highlight(&lb.attention, is_current),
                    )
                })
                .collect();
            lines.push(
                div()
                    .relative()
                    .min_h(px(10.))
                    .child(gpui_kit::StyledText::new(shown).with_highlights(highlights))
                    .when(has_current, |this| this.child(self.find_anchor()))
                    .into_any_element(),
            );
        }
        Some(v_flex().gap(px(3.)).children(lines).into_any_element())
    }

    /// Marks where the current match is and, the first time it paints, scrolls
    /// the overview so it shows.
    fn find_anchor(&self) -> impl IntoElement + use<> {
        let scroll = self.find.scroll.clone();
        let reveal = self.find.reveal.clone();
        gpui_kit::canvas(
            move |bounds, window, _| {
                if !reveal.replace(false) {
                    return;
                }
                let view = scroll.bounds();
                let offset = scroll.offset();
                let top = bounds.origin.y - view.origin.y;
                let bottom = top + bounds.size.height;
                let margin = px(24.);
                let y = if top < margin {
                    offset.y + margin - top
                } else if bottom > view.size.height - margin {
                    offset.y - (bottom - view.size.height + margin)
                } else {
                    return;
                };
                scroll.set_offset(gpui_kit::point(offset.x, y));
                window.request_animation_frame();
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full()
    }
}

impl MeetingDoc {
    /// Decision and question text with display speaker names.
    pub(super) fn speakers_text(&self, text: &str) -> String {
        text.to_string()
    }
}

/// The owner a row shows: its name, or "No owner".
pub(super) fn owner_text(action: &MeetingAction) -> String {
    action
        .owner_label
        .clone()
        .unwrap_or_else(|| lokalbot_i18n::tr("No owner").to_string())
}

/// The line being said at `seconds`: the latest that has started, or the
/// first before any speech (`PlayheadIndex.caption`).
pub(super) fn caption_at(doc: &MeetingDoc, seconds: f64) -> Option<usize> {
    if doc.rows.is_empty() {
        return None;
    }
    Some(
        doc.rows
            .iter()
            .rposition(|row| row.start <= seconds)
            .unwrap_or(0),
    )
}

/// The small amber control that asks for a missing name
/// (`MeetingAttentionChipStyle`).
fn attention_chip(
    id: &'static str,
    label: impl Into<SharedString>,
    cx: &Context<MeetingsPage>,
) -> gpui_kit::Stateful<Div> {
    let lb = cx.lb();
    let fill = lb.attention;
    div()
        .id(id)
        .flex_none()
        .px(px(9.))
        .py(px(3.))
        .rounded(px(6.))
        .bg(fill.opacity(0.12))
        .border_1()
        .border_color(fill.opacity(0.4))
        .hover(move |s| s.bg(fill.opacity(0.22)))
        .cursor_pointer()
        .text_size(ty::SECONDARY)
        .font_weight(FontWeight::MEDIUM)
        .text_color(lb.attention_text)
        .child(label.into())
}

fn highlight(attention: &Hsla, current: bool) -> gpui_kit::HighlightStyle {
    gpui_kit::HighlightStyle {
        background_color: Some(attention.opacity(if current { 0.55 } else { 0.22 })),
        ..Default::default()
    }
}

/// "Gmail · 4 min on screen"; the source is left out when the title already
/// names it.
fn screen_detail(material: &lokalbot_core::meeting_screen::Material) -> String {
    let source = material.site.as_deref().unwrap_or(&material.app);
    let minutes = (material.seconds_on_screen / 60.).round() as u64;
    let duration = match minutes {
        0 => lokalbot_i18n::tr("Under a minute on screen").to_string(),
        1..=59 => lokalbot_i18n::format(
            "{minutes} min on screen",
            &[("minutes", minutes.to_string())],
        ),
        _ => lokalbot_i18n::format(
            "{hours} hr {minutes} min on screen",
            &[
                ("hours", (minutes / 60).to_string()),
                ("minutes", (minutes % 60).to_string()),
            ],
        ),
    };
    if source.eq_ignore_ascii_case(&material.title) {
        duration
    } else {
        format!("{source} · {duration}")
    }
}

fn speed_label(speed: f32) -> String {
    let text = format!("{speed}");
    format!("{}x", text.trim_end_matches(".0"))
}

pub(super) fn stage_label(stage: &ProcessingStage) -> String {
    match stage {
        ProcessingStage::Queued => lokalbot_i18n::tr("Queued…").into(),
        ProcessingStage::WaitingForModels => lokalbot_i18n::tr("Waiting for models — the recording is saved. Download the selected models in Settings → Models, or use Download & process to fetch them now.").into(),
        ProcessingStage::PreparingModel(name) => lokalbot_i18n::format("Preparing {name}…", &[("name", format!("{}", name))]),
        ProcessingStage::Transcribing => lokalbot_i18n::tr("Transcribing…").into(),
        ProcessingStage::IdentifyingSpeakers => lokalbot_i18n::tr("Identifying speakers…").into(),
        ProcessingStage::Summarizing => lokalbot_i18n::tr("Summarizing…").into(),
        ProcessingStage::Failed(reason) => lokalbot_i18n::format("Failed: {reason}", &[("reason", format!("{}", reason))]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speed_labels_drop_a_trailing_zero() {
        assert_eq!(speed_label(1.), "1x");
        assert_eq!(speed_label(1.25), "1.25x");
        assert_eq!(speed_label(0.75), "0.75x");
    }
}
