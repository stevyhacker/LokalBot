//! The meeting workspace: header, audio bar, status lines and the Summary,
//! Notes and Review tabs (the Transcript tab is in `transcript.rs`).

use crate::i18n::h_flex;
use crate::windows::screen_image::{self, ScreenImage};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Textarea;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, Window, div, px, white,
};
use gpui_kit::{AppContext as _, ObjectFit, StyledImage as _, img};
use lokalbot_core::ActionStatus;

use super::dialogs::{CorrectionSheet, NameSpeakerSheet};
use super::model::{self, MeetingAction, MeetingDoc};
use super::{MeetingsPage, NotesStatus, status_text};
use crate::state::{MeetingTab, ProcessingStage};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, action_row};

impl MeetingsPage {
    pub(super) fn render_detail(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // "Try a sample meeting" holds the pane until its models are here or it is cancelled.
        if self.data.read(cx).sample_setup.is_some() {
            return crate::sample::render_setup(&self.data, cx);
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
        let show_find = self.tab == MeetingTab::Transcript || self.find.open;
        let content: AnyElement = match self.tab {
            MeetingTab::Transcript => self.render_transcript(&doc, window, cx),
            tab => {
                let body = match tab {
                    MeetingTab::Summary => self.render_summary(&doc, cx),
                    MeetingTab::Notes => self.render_notes_tab(cx),
                    _ => self.render_review(&doc, cx),
                };
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
                                v_flex()
                                    .w_full()
                                    .max_w(metric::CONTENT_MAX_WIDTH)
                                    .px(metric::DETAIL_PADDING)
                                    .pt(px(4.))
                                    .pb(metric::DETAIL_PADDING)
                                    .gap(metric::SECTION_SPACING)
                                    .children(self.render_status(&doc, cx))
                                    .child(body),
                            ),
                    )
                    .vertical_scrollbar(&self.find.scroll)
                    .into_any_element()
            }
        };

        v_flex()
            .size_full()
            .when(show_find, |this| {
                this.child(self.render_find_bar(cx))
                    .child(div().h(px(1.)).w_full().bg(lb.separator))
            })
            .child(
                v_flex()
                    .flex_none()
                    .max_w(metric::CONTENT_MAX_WIDTH)
                    .px(metric::DETAIL_PADDING)
                    .pt(px(8.))
                    .pb(px(14.))
                    .gap(px(12.))
                    .child(self.render_header(&doc, cx))
                    .child(self.render_audio_bar(&doc, cx)),
            )
            .child(div().flex_1().min_h_0().child(content))
            .into_any_element()
    }

    fn render_header(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let meeting = &doc.meeting;
        use super::page_search::{Location, MetadataField, app_chip, audio_chip};
        let date = model::date_label(meeting.started_at);
        let duration = model::duration_label(meeting);
        let marked_date = self.find_marked(
            Location::Metadata(MetadataField::Date),
            &date,
            date.clone(),
            false,
            cx,
        );
        let marked_duration = self.find_marked(
            Location::Metadata(MetadataField::Duration),
            &duration,
            duration.clone(),
            false,
            cx,
        );
        let marked_app = app_chip(meeting).map(|app| {
            self.find_marked(
                Location::Metadata(MetadataField::App),
                &app,
                app.clone(),
                false,
                cx,
            )
        });
        let marked_audio = audio_chip(meeting).map(|audio| {
            self.find_marked(
                Location::Metadata(MetadataField::AudioSource),
                audio,
                audio,
                false,
                cx,
            )
        });
        let title = meeting.display_title();
        let marked_title = self.find_marked(Location::Title, &title, title.clone(), false, cx);
        let chip = |icon: Ico, text: AnyElement, color: gpui_kit::Hsla| {
            h_flex()
                .flex_none()
                .gap(px(5.))
                .items_center()
                .text_size(ty::SECONDARY)
                .text_color(color)
                .child(ui::icon(icon, px(14.), color))
                .child(text)
        };
        let mut chips = vec![
            chip(Ico::Calendar, marked_date, lb.supporting).into_any_element(),
            chip(Ico::Clock, marked_duration, lb.supporting).into_any_element(),
        ];
        if let Some(app) = marked_app {
            let (icon, color) = if meeting.is_sample() {
                (Ico::Sparkles, lb.accent_text)
            } else {
                (Ico::Video, lb.supporting)
            };
            chips.push(chip(icon, app, color).into_any_element());
        }
        // An imported file's audio came from neither this PC's microphone nor
        // its system audio, so neither label applies.
        if let Some(audio) = marked_audio {
            if meeting.has_system_track {
                chips.push(chip(Ico::Volume2, audio, lb.supporting).into_any_element());
            } else {
                chips.push(
                    chip(Ico::TriangleAlert, audio, lb.attention_text)
                        .id("mic-only")
                        .tooltip(|window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(
                                lokalbot_i18n::tr("Only your microphone was recorded. Other participants are captured only if your mic picked them up."),
                            )
                            .build(window, cx)
                        })
                        .into_any_element(),
                );
            }
        }
        v_flex()
            .gap(px(8.))
            .child(
                div()
                    .text_size(ty::PAGE_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .line_clamp(2)
                    .child(marked_title),
            )
            .child(
                h_flex()
                    .flex_wrap()
                    .gap_x(px(14.))
                    .gap_y(px(6.))
                    .items_center()
                    .children(chips),
            )
    }

    fn render_audio_bar(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        if !doc.has_audio {
            return ui::grouped_surface(cx)
                .h(px(64.))
                .px(px(12.))
                .flex()
                .items_center()
                .gap(px(12.))
                .text_color(lb.text_secondary)
                .child(
                    div()
                        .size(px(30.))
                        .rounded_full()
                        .bg(lb.text_tertiary.opacity(0.7))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(crate::ui::waveform::play_glyph(px(12.), white())),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "No recording available",
                        ))),
                )
                .into_any_element();
        }
        if self.player.is_none() {
            let label = if self.player_loading {
                lokalbot_i18n::tr("Loading recording…")
            } else {
                lokalbot_i18n::tr("No recording available")
            };
            return ui::grouped_surface(cx)
                .h(px(64.))
                .px(px(12.))
                .flex()
                .items_center()
                .gap(px(12.))
                .text_color(lb.text_secondary)
                .child(
                    div()
                        .size(px(30.))
                        .rounded_full()
                        .bg(lb.text_tertiary.opacity(0.7))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(crate::ui::waveform::play_glyph(px(12.), white())),
                )
                .child(div().text_size(ty::SECONDARY).child(label))
                .into_any_element();
        }
        let (current, duration) = self.playback_times(doc.meeting.duration_seconds());
        let page = cx.entity().downgrade();
        let hover_page = page.clone();
        let speed_target = page.clone();
        let speed = self.speed;
        ui::grouped_surface(cx)
            .px(px(12.))
            .py(px(12.))
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
                        gpui_kit::component::tooltip::Tooltip::new(lokalbot_i18n::tr(
                            "Play / pause (Space)",
                        ))
                        .build(window, cx)
                    })
                    .on_click(cx.listener(|this, _, _, cx| this.toggle_playback(cx))),
            )
            .child(crate::ui::waveform::waveform(
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
            ))
            .child(
                div()
                    .flex_none()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(format!(
                        "{} / {}",
                        lokalbot_core::time::stamp(current),
                        lokalbot_core::time::stamp(duration)
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

    /// Processing, empty-speech and speaker-review lines above the tab content.
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
                doc.transcript
                    .as_ref()
                    .is_some_and(|t| !t.segments.is_empty()),
                doc.summary.is_some(),
                cx,
            ));
        }
        if doc.capture_needs_attention {
            out.push(
                ui::status_surface(lb.attention, cx)
                    .px(px(12.))
                    .py(px(10.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(ui::icon(Ico::TriangleAlert, px(16.), lb.attention_text))
                    .child(div().flex_1().min_w_0().text_size(ty::BODY).text_color(lb.text).child(
                        crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Audio capture was interrupted or saving reported an error. Review the saved recording for missing audio.",
                        )),
                    ))
                    .into_any_element(),
            );
        }
        if doc.recovery_needs_attention {
            out.push(
                ui::status_surface(lb.attention, cx)
                    .px(px(12.))
                    .py(px(10.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(ui::icon(Ico::TriangleAlert, px(16.), lb.attention_text))
                    .child(div().flex_1().min_w_0().text_size(ty::BODY).text_color(lb.text).child(
                        crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Some recovery audio could not be verified. Saved audio and original checkpoints are retained.",
                        )),
                    ))
                    .into_any_element(),
            );
        }
        if doc.additional_audio > 0.1 {
            let meeting = doc.meeting.clone();
            let data = self.data.clone();
            out.push(
                ui::grouped_surface(cx)
                    .px(px(12.))
                    .py(px(10.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(ui::icon(Ico::AudioLines, px(16.), lb.text_secondary))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Additional saved audio is outside the meeting boundaries.",
                            ))),
                    )
                    .child(
                        Button::new("review-saved-audio")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Review additional saved audio…"))
                            .on_click(move |_, window, cx| {
                                super::dialogs::BoundarySheet::open(
                                    data.clone(),
                                    meeting.clone(),
                                    window,
                                    cx,
                                );
                            }),
                    )
                    .into_any_element(),
            );
        }
        if let Some(stage) = self.data.read(cx).processing.get(&doc.meeting.id).cloned() {
            let (icon, color) = match &stage {
                ProcessingStage::Failed(_) => (Ico::TriangleAlert, lb.attention_text),
                ProcessingStage::WaitingForModels => (Ico::CircleArrowDown, lb.text_secondary),
                _ => (Ico::Sparkles, lb.text_secondary),
            };
            let button = match &stage {
                ProcessingStage::Failed(_) => Some((lokalbot_i18n::tr("Retry"), "status-retry")),
                ProcessingStage::WaitingForModels => {
                    Some((lokalbot_i18n::tr("Download & process"), "status-download"))
                }
                _ => None,
            };
            out.push(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        h_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(6.))
                            .items_start()
                            .text_size(ty::SECONDARY)
                            .text_color(color)
                            .child(ui::icon(icon, px(14.), color))
                            .child(div().flex_1().min_w_0().child({
                                let label = stage_label(&stage);
                                self.find_text(
                                    super::page_search::Location::Status,
                                    &label,
                                    label.clone(),
                                    cx,
                                )
                            })),
                    )
                    .when_some(button, |this, (label, id)| {
                        this.child(
                            Button::new(id)
                                .outline()
                                .small()
                                .label(label)
                                .on_click(cx.listener(|this, _, _, cx| this.retry_processing(cx))),
                        )
                    })
                    .into_any_element(),
            );
        }
        if doc
            .transcript
            .as_ref()
            .is_some_and(|t| t.segments.is_empty())
        {
            out.push(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("No speech detected. Saved audio remains available for playback and export.")))
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
                        div().text_size(ty::CAPTION).text_color(lb.text_secondary).child(
                            crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Source-linked notes and actions are saved below. Actions become editable when the notes finish.",
                            )),
                        ),
                    )
                    .into_any_element(),
            );
        } else if doc.notes_need_refresh && self.tab == MeetingTab::Summary {
            out.push(
                ui::grouped_surface(cx)
                    .p(px(12.))
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .child(
                        h_flex()
                            .gap(px(6.))
                            .items_center()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(ui::icon(Ico::TriangleAlert, px(15.), lb.attention_text))
                            .child(lokalbot_i18n::tr("Transcript or speaker details changed")),
                    )
                    .child(
                        div().text_size(ty::BODY).text_color(lb.text_secondary).child(
                            crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Review speakers and action owners, then refresh the derived notes.",
                            )),
                        ),
                    )
                    .child(
                        h_flex().child(
                            Button::new("review-stale-notes")
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Review speakers and follow-ups"))
                                .on_click(
                                    cx.listener(|this, _, _, cx| this.set_tab(MeetingTab::Review, cx)),
                                ),
                        ),
                    )
                    .into_any_element(),
            );
        }
        if !doc.unmatched_edits.is_empty() {
            let expanded = self.unmatched_expanded;
            out.push(
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
                                if expanded { Ico::ChevronDown } else { Ico::ChevronRight },
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
                            div().text_size(ty::CAPTION).text_color(lb.text_secondary).child(
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
                                        .text_color(lb.text_secondary)
                                        .child(detail.clone()),
                                )
                        }))
                    })
                    .into_any_element(),
            );
        }
        if let Some(notice) = &doc.speaker_notice {
            out.push(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::tr(notice).to_string())
                    .into_any_element(),
            );
        }
        if !doc.recognized.is_empty() {
            out.push(self.render_recognized(doc, cx));
        }
        let unnamed = doc.unnamed_remote;
        if self.tab == MeetingTab::Summary
            && unnamed > 0
            && !doc.notes_need_refresh
            && doc.recognized.is_empty()
        {
            let text = if unnamed == 1 {
                lokalbot_i18n::tr("1 speaker needs a name. Review action-linked voices first.")
                    .to_string()
            } else {
                lokalbot_i18n::format(
                    "{unnamed} speakers need names. Review action-linked voices first.",
                    &[("unnamed", format!("{}", unnamed))],
                )
            };
            out.push(
                ui::status_surface(lb.attention, cx)
                    .px(px(12.))
                    .py(px(10.))
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .child(ui::icon(Ico::Users, px(16.), lb.attention_text))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(text),
                    )
                    .child(
                        Button::new("review-speakers")
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Review Speakers…"))
                            .on_click(
                                cx.listener(|this, _, _, cx| this.set_tab(MeetingTab::Review, cx)),
                            ),
                    )
                    .into_any_element(),
            );
        }
        out
    }

    // -------------------------------------------------------------- summary

    fn render_summary(&mut self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let mut sections: Vec<AnyElement> = Vec::new();
        if !doc.recap.is_empty() {
            let total = doc.recap.len();
            let shown = if self.recap_expanded {
                total
            } else {
                total.min(5)
            };
            let points = doc.recap.iter().take(shown).map(|point| {
                div()
                    .text_size(ty::BODY)
                    .line_height(px(21.))
                    .text_color(lb.text)
                    .child(point.clone())
                    .into_any_element()
            });
            let toggle = (total > 5).then(|| {
                let label = if self.recap_expanded {
                    lokalbot_i18n::tr("Show Less").to_string()
                } else {
                    lokalbot_i18n::format(
                        "Show {0} More Points",
                        &[("0", format!("{}", total - 5))],
                    )
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
            sections.push(card(
                lokalbot_i18n::tr("Recap"),
                v_flex().gap(px(10.)).children(points).children(toggle),
                cx,
            ));
        }
        sections.push(self.render_action_items(doc, cx));
        if doc.has_outcomes() {
            let decisions: AnyElement = if doc.decisions.is_empty() {
                self.empty_row_marked(
                    super::page_search::Section::Decisions,
                    lokalbot_i18n::tr("No cited decisions were extracted."),
                    cx,
                )
            } else {
                v_flex()
                    .gap(px(12.))
                    .children(doc.decisions.iter().enumerate().map(|(ix, decision)| {
                        let citation = decision.citations.first().cloned();
                        h_flex()
                            .gap(px(10.))
                            .items_start()
                            .child(div().mt(px(2.)).child(ui::icon(
                                Ico::CircleCheck,
                                px(16.),
                                lb.success_text,
                            )))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .text_size(ty::BODY)
                                    .line_height(px(20.))
                                    .text_color(lb.text)
                                    .child({
                                        let shown = doc.speakers_text(&decision.text).to_string();
                                        self.find_text(
                                            super::page_search::Location::Decision(
                                                ix,
                                                super::page_search::DecisionField::Text,
                                            ),
                                            &shown,
                                            shown.clone(),
                                            cx,
                                        )
                                    }),
                            )
                            .when_some(citation, |this, citation| {
                                let start = citation.start;
                                let page = cx.entity().downgrade();
                                let pill = action_row::evidence_pill(
                                    ("decision-evidence", ix),
                                    start,
                                    Some(citation.excerpt.clone().into()),
                                    move |_, cx| {
                                        let _ = page
                                            .update(cx, |this, cx| this.show_evidence(start, cx));
                                    },
                                    cx,
                                );
                                this.child(self.find_tinted(
                                    pill,
                                    super::page_search::Location::Decision(
                                        ix,
                                        super::page_search::DecisionField::Evidence,
                                    ),
                                    cx,
                                ))
                            })
                            .into_any_element()
                    }))
                    .into_any_element()
            };
            sections.push(self.card_marked(
                lokalbot_i18n::tr("Decisions"),
                super::page_search::Section::Decisions,
                decisions,
                cx,
            ));
            if !doc.questions.is_empty() {
                let rows = doc.questions.iter().map(|question| {
                    h_flex()
                        .gap(px(10.))
                        .items_start()
                        .child(div().mt(px(2.)).child(ui::icon(
                            Ico::CircleQuestionMark,
                            px(16.),
                            lb.attention_text,
                        )))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .text_size(ty::BODY)
                                .line_height(px(20.))
                                .text_color(lb.text)
                                .child(question.clone()),
                        )
                        .into_any_element()
                });
                sections.push(card(
                    lokalbot_i18n::tr("Open Questions"),
                    v_flex().gap(px(10.)).children(rows),
                    cx,
                ));
            }
        }
        sections.push(self.render_full_notes(doc, cx));
        if !doc.screen.materials.is_empty() {
            sections.push(self.render_screen_materials(doc, cx));
        }
        v_flex()
            .gap(metric::SECTION_SPACING)
            .children(sections)
            .into_any_element()
    }

    pub(super) fn render_action_items(
        &self,
        doc: &MeetingDoc,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        // The Review tab keeps the previous actions in view until new notes exist.
        let actions = if doc.actions.is_empty() && self.tab == MeetingTab::Review {
            &doc.previous_actions
        } else {
            &doc.actions
        };
        let content: AnyElement = if actions.is_empty() {
            self.empty_row_marked(
                super::page_search::Section::ActionItems,
                lokalbot_i18n::tr("No action items were extracted from this meeting."),
                cx,
            )
        } else {
            let count = actions.len();
            v_flex()
                .children(actions.iter().enumerate().map(|(ix, action)| {
                    let row = self.render_action(ix, action, doc, cx);
                    v_flex()
                        .child(row)
                        .when(ix + 1 < count, |this| {
                            this.child(div().h(px(1.)).bg(lb.separator))
                        })
                        .into_any_element()
                }))
                .into_any_element()
        };
        self.card_marked(
            lokalbot_i18n::tr("Action Items"),
            super::page_search::Section::ActionItems,
            content,
            cx,
        )
    }

    fn render_action(
        &self,
        ix: usize,
        action: &MeetingAction,
        doc: &MeetingDoc,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let done = action.status == ActionStatus::Done;
        let toggle_id = action.id.clone();
        let toggle = action_row::status_toggle(
            ("action-toggle", ix),
            action.status,
            false,
            {
                let page = cx.entity().downgrade();
                move |_, cx| {
                    let id = toggle_id.clone();
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
                }
            },
            cx,
        );
        let mut meta: Vec<AnyElement> = Vec::new();
        let owner_text = action
            .owner_label
            .clone()
            .unwrap_or_else(|| lokalbot_i18n::tr("Owner unclear").into());
        let owner_color = if action.owner_label.is_some() {
            lb.text_secondary
        } else {
            lb.attention_text
        };
        let correct_page = cx.entity().downgrade();
        let correct_action = action.clone();
        meta.push(
            div()
                .id(("action-owner", ix))
                .text_size(ty::SECONDARY)
                .text_color(owner_color)
                .cursor_pointer()
                .hover(|s| s.underline())
                .child(self.find_text(
                    super::page_search::Location::Action(
                        ix,
                        super::page_search::ActionField::Owner,
                    ),
                    &owner_text,
                    owner_text.clone(),
                    cx,
                ))
                .on_click(move |_, window, cx| {
                    let action = correct_action.clone();
                    let _ = correct_page
                        .update(cx, |this, cx| this.open_correction(action, window, cx));
                })
                .into_any_element(),
        );
        if let Some(due) = action.due.clone() {
            let label: gpui_kit::SharedString = action
                .due_label
                .clone()
                .unwrap_or_else(|| due.clone())
                .into();
            let chip = action_row::due_chip(due, false, cx)
                .id(("action-due", ix))
                .tooltip(move |window, cx| {
                    gpui_kit::component::tooltip::Tooltip::new(label.clone()).build(window, cx)
                });
            meta.push(
                self.find_tinted(
                    chip,
                    super::page_search::Location::Action(ix, super::page_search::ActionField::Due),
                    cx,
                )
                .into_any_element(),
            );
        }
        if let Some(citation) = action.citation.clone() {
            let start = citation.start;
            let page = cx.entity().downgrade();
            let pill = action_row::evidence_pill(
                ("action-evidence", ix),
                start,
                Some(citation.excerpt.into()),
                move |_, cx| {
                    let _ = page.update(cx, |this, cx| this.show_evidence(start, cx));
                },
                cx,
            );
            meta.push(
                self.find_tinted(
                    pill,
                    super::page_search::Location::Action(
                        ix,
                        super::page_search::ActionField::Evidence,
                    ),
                    cx,
                )
                .into_any_element(),
            );
        }
        let status = action.status;
        let menu_page = cx.entity().downgrade();
        let menu_action = action.clone();
        let menu_data = self.data.clone();
        let menu_meeting = doc.meeting.clone();
        let menu = action_row::options_menu(("action-menu", ix), move |menu, _, _| {
            let mut menu = menu;
            for option in [
                ActionStatus::Open,
                ActionStatus::Done,
                ActionStatus::Deferred,
            ] {
                let page = menu_page.clone();
                let id = menu_action.id.clone();
                menu = menu.item(
                    PopupMenuItem::new(lokalbot_i18n::tr(option.label()))
                        .checked(option == status)
                        .on_click(move |_, _, cx| {
                            let id = id.clone();
                            let _ =
                                page.update(cx, |this, cx| this.set_action_status(id, option, cx));
                        }),
                );
            }
            let page = menu_page.clone();
            let action = menu_action.clone();
            let prompt = lokalbot_core::agent_handoff::agent_prompt_from_meeting(
                &menu_meeting.display_title(),
                &menu_action.text,
            );
            let agent_data = menu_data.clone();
            let mut menu = menu
                .separator()
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Correct owner or due date")).on_click(
                        move |_, window, cx| {
                            let action = action.clone();
                            let _ = page
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
                let data = menu_data.clone();
                let meeting = menu_meeting.clone();
                let id = menu_action.id.clone();
                menu = menu.item(
                    PopupMenuItem::new(crate::pages::today::threads::open_in_label(target))
                        .on_click(move |_, _, cx| {
                            crate::agent_handoff::hand_off_meeting_action(
                                &data,
                                &meeting,
                                id.clone(),
                                target,
                                cx,
                            )
                        }),
                );
            }
            menu
        });
        let _ = doc;
        action_row::action_row_with(
            toggle,
            self.find_text(
                super::page_search::Location::Action(ix, super::page_search::ActionField::Text),
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

    /// `text`, with Find's matches at `location` marked; the current one
    /// scrolls into view (`MeetingPageSearchMatch`).
    fn find_text(
        &self,
        location: super::page_search::Location,
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
        location: super::page_search::Location,
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

    /// A section card whose title Find can mark.
    fn card_marked(
        &self,
        title: &'static str,
        section: super::page_search::Section,
        content: impl IntoElement,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        v_flex()
            .gap(metric::HEADER_TO_CONTENT)
            .child(
                div()
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(self.find_text(
                        super::page_search::Location::SectionHeader(section),
                        title,
                        title,
                        cx,
                    )),
            )
            .child(ui::panel(cx).child(v_flex().gap(px(8.)).child(content)))
            .into_any_element()
    }

    fn empty_row_marked(
        &self,
        section: super::page_search::Section,
        text: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        div()
            .py(px(6.))
            .text_size(ty::BODY)
            .text_color(cx.lb().text_secondary)
            .child(self.find_text(
                super::page_search::Location::EmptyState(section),
                text,
                text,
                cx,
            ))
            .into_any_element()
    }

    /// `find_text`, for text that isn't in the overview's scroll view and so
    /// has nothing to scroll with `anchored` off.
    pub(super) fn find_marked(
        &self,
        location: super::page_search::Location,
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
                (
                    found.range.clone(),
                    gpui_kit::HighlightStyle {
                        background_color: Some(lb.attention.opacity(if is_current {
                            0.55
                        } else {
                            0.22
                        })),
                        ..Default::default()
                    },
                )
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
        location: super::page_search::Location,
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
                        gpui_kit::HighlightStyle {
                            background_color: Some(lb.attention.opacity(if is_current {
                                0.55
                            } else {
                                0.22
                            })),
                            ..Default::default()
                        },
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

    fn render_full_notes(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let expanded = self.full_notes_expanded;
        let disclosure = h_flex()
            .id("full-notes")
            .gap(px(6.))
            .items_center()
            .cursor_pointer()
            .text_size(ty::BODY)
            .text_color(lb.text)
            .child(ui::icon(
                if expanded {
                    Ico::ChevronDown
                } else {
                    Ico::ChevronRight
                },
                px(14.),
                lb.text_secondary,
            ))
            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                "Show Full Notes",
            )))
            .on_click(cx.listener(|this, _, _, cx| {
                this.full_notes_expanded = !this.full_notes_expanded;
                cx.notify();
            }));
        if !expanded {
            return disclosure.into_any_element();
        }
        let notes = self.notes.saved.trim().to_string();
        let body: AnyElement = if notes.is_empty() && !doc.has_summary() {
            self.empty_row_marked(
                super::page_search::Section::Summary,
                lokalbot_i18n::tr("No summary yet."),
                cx,
            )
        } else {
            v_flex()
                .max_w(metric::READING_MAX_WIDTH)
                .gap(px(14.))
                .when(!notes.is_empty(), |this| {
                    this.child(
                        v_flex()
                            .gap(px(6.))
                            .p(px(12.))
                            .rounded(metric::GROUP_RADIUS)
                            .bg(lb.chip_fill.opacity(0.6))
                            .child(
                                h_flex()
                                    .gap(px(6.))
                                    .items_center()
                                    .text_size(ty::SECONDARY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text_secondary)
                                    .child(ui::icon(Ico::SquarePen, px(14.), lb.text_secondary))
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "Your notes",
                                    ))),
                            )
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child(notes.clone()),
                            ),
                    )
                })
                .when_some(doc.summary_meta.clone(), |this, meta| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(self.find_text(
                                super::page_search::Location::SummaryMeta,
                                &meta,
                                meta.clone(),
                                cx,
                            )),
                    )
                })
                .when(doc.has_summary(), |this| {
                    let matched = self.find_lines(
                        super::page_search::Location::Summary,
                        &doc.summary_body,
                        cx,
                    );
                    this.child(
                        div().text_size(ty::BODY).child(match matched {
                            Some(lines) => lines,
                            None => crate::ui::markdown_view::markdown(
                                SharedString::from(format!("summary-{}", doc.meeting.id)),
                                doc.summary_body.clone(),
                            )
                            .selectable(true)
                            .into_any_element(),
                        }),
                    )
                })
                .into_any_element()
        };
        v_flex()
            .gap(px(12.))
            .child(disclosure)
            .child(self.card_marked(
                lokalbot_i18n::tr("Summary"),
                super::page_search::Section::Summary,
                body,
                cx,
            ))
            .into_any_element()
    }

    // ---------------------------------------------------------------- notes

    fn render_notes_tab(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let status = self.notes.status.clone();
        v_flex()
            .gap(px(12.))
            .child(
                h_flex()
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(self.find_marked(
                                super::page_search::Location::NotesLabel,
                                lokalbot_i18n::tr("Your notes"),
                                lokalbot_i18n::tr("Your notes"),
                                false,
                                cx,
                            )),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(status_text(&status)),
                    ),
            )
            .child(
                ui::grouped_surface(cx).p(px(6.)).child(
                    Textarea::new(&self.notes.input)
                        .large()
                        .appearance(false)
                        .h(px(460.)),
                ),
            )
            .when_some(
                match status {
                    NotesStatus::Failed(message) => Some(message),
                    _ => None,
                },
                |this, message| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.attention_text)
                            .child(message),
                    )
                    .child(
                        h_flex().child(
                            Button::new("notes-retry")
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Retry saving"))
                                .on_click(cx.listener(|this, _, _, cx| this.save_notes(false, cx))),
                        ),
                    )
                },
            )
            .into_any_element()
    }

    // --------------------------------------------------------------- review

    fn render_review(&mut self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let total = doc.review.len();
        let shown = if self.speakers_expanded {
            total
        } else {
            total.min(5)
        };
        let mut speaker_rows: Vec<AnyElement> = vec![
            div()
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child("Listen to a short excerpt, then confirm a name or whether the speaker is you. Leave uncertain voices unresolved.")
                .into_any_element(),
        ];
        if doc.review.is_empty() {
            speaker_rows.push(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "No transcript speakers are available yet.",
                    )))
                    .into_any_element(),
            );
        }
        for (ix, speaker) in doc.review.iter().take(shown).enumerate() {
            let named = speaker.is_named;
            let review_speaker = speaker.clone();
            let page = cx.entity().downgrade();
            let row = v_flex()
                .gap(px(8.))
                .py(px(8.))
                .child(
                    h_flex()
                        .gap(px(12.))
                        .items_start()
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(3.))
                                .child(
                                    h_flex()
                                        .gap(px(6.))
                                        .items_center()
                                        .child(ui::status_dot(super::speaker_color(speaker.color, cx), px(7.)))
                                        .child(
                                            div()
                                                .text_size(ty::BODY)
                                                .font_weight(FontWeight::SEMIBOLD)
                                                .text_color(lb.text)
                                                .child(speaker.name.clone()),
                                        ),
                                )
                                .child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(speaker.status()))
                                .when(speaker.action_count > 0, |this| {
                                    this.child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::format("Linked actions: {count}", &[("count", speaker.action_count.to_string())]))))
                                }),
                        )
                        .child(
                            h_flex()
                                .flex_none()
                                .gap(px(8.))
                                .when(speaker.sample.is_some(), |this| {
                                    this.child(
                                        Button::new(("speaker-listen", ix))
                                            .outline()
                                            .small()
                                            .icon(Icon::new(Ico::Play))
                                            .label(lokalbot_i18n::tr("Listen"))
                                            .disabled(self.player.is_none())
                                            .on_click({
                                                let sample = speaker.sample.as_ref().map(|(start, _)| *start).unwrap_or(0.);
                                                cx.listener(move |this, _, _, cx| this.play_excerpt(sample, sample + 12., cx))
                                            }),
                                    )
                                })
                                .child(
                                    Button::new(("speaker-name", ix))
                                        .outline()
                                        .small()
                                        .label(if named { lokalbot_i18n::tr("Review Name…") } else { lokalbot_i18n::tr("Name Speaker…") })
                                        .on_click(move |_, window, cx| {
                                            let speaker = review_speaker.clone();
                                            let _ = page.update(cx, |this, cx| this.open_name_speaker(speaker, window, cx));
                                        }),
                                ),
                        ),
                )
                .child(match &speaker.sample {
                    Some((_, text)) => div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .line_clamp(3)
                        .child(format!("“{text}”"))
                        .into_any_element(),
                    None => div()
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("No clear voice excerpt available. Review the transcript before assigning a name.")))
                        .into_any_element(),
                });
            if ix > 0 {
                speaker_rows.push(div().h(px(1.)).bg(lb.separator).into_any_element());
            }
            speaker_rows.push(row.into_any_element());
        }
        if total > 5 {
            let label = if self.speakers_expanded {
                lokalbot_i18n::tr("Show Fewer Speakers").to_string()
            } else {
                lokalbot_i18n::format("Show {0} More Speakers", &[("0", format!("{}", total - 5))])
            };
            speaker_rows.push(
                ui::link(
                    "speakers-more",
                    label,
                    {
                        let page = cx.entity().downgrade();
                        move |_, cx| {
                            let _ = page.update(cx, |this, cx| {
                                this.speakers_expanded = !this.speakers_expanded;
                                cx.notify();
                            });
                        }
                    },
                    cx,
                )
                .text_size(ty::SECONDARY)
                .into_any_element(),
            );
        }

        let think_local = self.data.read(cx).settings.think_is_local();
        let processing = self
            .data
            .read(cx)
            .processing
            .get(&doc.meeting.id)
            .is_some_and(|stage| !matches!(stage, ProcessingStage::Failed(_)));
        let has_summary = doc.has_summary();
        let (freshness, freshness_icon) = if doc.notes_need_refresh {
            (
                lokalbot_i18n::tr("Notes need a refresh"),
                Ico::TriangleAlert,
            )
        } else if has_summary {
            (
                lokalbot_i18n::tr("Notes use the latest saved speaker details"),
                Ico::CircleCheck,
            )
        } else {
            (lokalbot_i18n::tr("No derived notes yet"), Ico::FileText)
        };
        let refresh = v_flex()
            .gap(px(8.))
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(ui::icon(freshness_icon, px(15.), lb.text_secondary))
                    .child(freshness),
            )
            .child(div().text_size(ty::BODY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Refresh the summary and extracted owners after reviewing speakers. Saved action corrections stay separate; unmatched edits remain available for review."))))
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::icon(Ico::ShieldCheck, px(14.), lb.accent_text))
                    .child(if think_local {
                        lokalbot_i18n::tr("Refreshing processes the transcript on this PC.")
                    } else {
                        lokalbot_i18n::tr("Refreshing sends the transcript and confirmed names to your approved model server.")
                    }),
            )
            .child(
                h_flex().pt(px(4.)).child(
                    Button::new("refresh-notes")
                        .primary()
                        .label(if processing { lokalbot_i18n::tr("Processing…") } else { lokalbot_i18n::tr("Refresh Notes and Owners") })
                        .disabled(processing || !doc.has_transcript() || doc.partial_progress.is_some())
                        .on_click(cx.listener(|this, _, _, cx| this.process(false, true, cx))),
                ),
            );

        v_flex()
            .gap(metric::SECTION_SPACING)
            .child(card(lokalbot_i18n::tr("Review Speakers"), v_flex().gap(px(8.)).children(speaker_rows), cx))
            .child(
                v_flex()
                    .gap(px(8.))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .child(ui::icon(Ico::UserRoundCheck, px(16.), lb.accent_text))
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("2. Review action owners"))),
                    )
                    .child(div().text_size(ty::BODY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("All actions from this meeting. Only yours appear in My actions. Choose an owner to correct it, or a timestamp to check the source."))))
                    .when(doc.actions.is_empty() && !doc.previous_actions.is_empty(), |this| {
                        this.child(div().text_size(ty::BODY).text_color(lb.attention_text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("These actions are from the previous notes. Review their owners, then refresh to regenerate notes from the corrected transcript."))))
                    })
                    .child(self.render_action_items(doc, cx)),
            )
            .child(card(lokalbot_i18n::tr("Refresh Notes"), refresh, cx))
            .into_any_element()
    }

    /// `MeetingScreenMaterialsSection`. The time plays the recording from when
    /// it first appeared, the capture opens in Timeline and a page whose
    /// address was captured can be reopened.
    fn render_screen_materials(&self, doc: &MeetingDoc, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let rows = doc
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
                    .gap(px(12.))
                    .py(px(6.))
                    .items_center()
                    .child(
                        Button::new(("screen-play", ix))
                            .ghost()
                            .small()
                            .label(lokalbot_core::time::stamp(offset))
                            .tooltip(lokalbot_i18n::tr(
                                "Play the recording from when this first appeared",
                            ))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.focus_at = Some(offset);
                                this.play_from(offset, cx);
                            })),
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
                                        gpui_kit::component::tooltip::Tooltip::new(
                                            lokalbot_i18n::tr("Open this capture in Timeline"),
                                        )
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
                                    .text_color(lb.text_secondary)
                                    .child(screen_detail(material)),
                            ),
                    )
                    .when_some(page, |row, url| {
                        row.child(
                            Button::new(("screen-page", ix))
                                .ghost()
                                .small()
                                .label(lokalbot_i18n::tr("Open Page"))
                                .on_click(move |_, _, cx| cx.open_url(&url)),
                        )
                    })
            });
        card(
            lokalbot_i18n::tr("On Screen During the Meeting"),
            v_flex()
                .children(rows)
                .child(div().pt(px(6.)).text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("From screen memory on this computer. Time on screen is estimated from captures, which follow your screen retention setting.")))),
            cx,
        )
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
                                    .text_color(lb.text_secondary)
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
                            .text_color(lb.text_secondary)
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
                .text_color(lb.text_secondary)
                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                    "Play or select a transcript line to see what was on screen.",
                )))
                .into_any_element(),
        };
        ui::grouped_surface(cx)
            .p(px(10.))
            .flex()
            .items_center()
            .gap(px(10.))
            .child(ui::icon(Ico::Monitor, px(15.), lb.text_secondary))
            .child(body)
            .into_any_element()
    }

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
}

impl MeetingDoc {
    /// Decision and question text with display speaker names.
    pub(super) fn speakers_text(&self, text: &str) -> String {
        text.to_string()
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

/// `WorkspaceSection`: bold title, 8px gap, padded grouped panel.
pub(super) fn card(
    title: &'static str,
    content: impl IntoElement,
    cx: &mut Context<MeetingsPage>,
) -> AnyElement {
    ui::section(title, v_flex().gap(px(8.)).child(content), cx).into_any_element()
}
