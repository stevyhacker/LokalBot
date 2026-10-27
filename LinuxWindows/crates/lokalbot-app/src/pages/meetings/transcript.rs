//! The Transcript tab: a find bar and a virtualized list of speaker turns.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, HighlightStyle, InteractiveElement as _, IntoElement,
    ParentElement as _, StatefulInteractiveElement as _, Styled as _, StyledText, Window, div,
    list, px,
};

use super::MeetingsPage;
use super::model::MeetingDoc;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

impl MeetingsPage {
    pub(super) fn render_find_bar(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let total = self.find.matches.len();
        let status = if self.find.query.trim().is_empty() {
            None
        } else if total == 0 {
            Some(lokalbot_i18n::tr("No matches").to_string())
        } else {
            Some(lokalbot_i18n::format(
                "{0} of {total} · Transcript",
                &[
                    ("0", format!("{}", self.find.current + 1)),
                    ("total", format!("{}", total)),
                ],
            ))
        };
        let has_matches = total > 0;
        h_flex()
            .w_full()
            .justify_end()
            .px(metric::DETAIL_PADDING)
            .py(px(10.))
            .child(
                ui::grouped_surface(cx)
                    .w_full()
                    .max_w(metric::READING_MAX_WIDTH)
                    .px(px(10.))
                    .py(px(4.))
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .child(ui::icon(Ico::Search, px(15.), lb.text_secondary))
                    .child(
                        div().flex_1().min_w_0().child(
                            Input::new(&self.find.input)
                                .appearance(false)
                                .small()
                                .cleanable(true),
                        ),
                    )
                    .when_some(status, |this, status| {
                        this.child(
                            div()
                                .flex_none()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(status),
                        )
                    })
                    .child(div().w(px(1.)).h(px(18.)).bg(lb.separator))
                    .child(
                        Button::new("find-previous")
                            .ghost()
                            .small()
                            .icon(Icon::new(Ico::ChevronUp))
                            .tooltip(lokalbot_i18n::tr("Previous match"))
                            .disabled(!has_matches)
                            .on_click(cx.listener(|this, _, _, cx| this.move_find(-1, cx))),
                    )
                    .child(
                        Button::new("find-next")
                            .ghost()
                            .small()
                            .icon(Icon::new(Ico::ChevronDown))
                            .tooltip(lokalbot_i18n::tr("Next match"))
                            .disabled(!has_matches)
                            .on_click(cx.listener(|this, _, _, cx| this.move_find(1, cx))),
                    )
                    .when(self.find.open, |this| {
                        this.child(
                            Button::new("find-close")
                                .ghost()
                                .small()
                                .icon(Icon::new(Ico::X))
                                .tooltip(lokalbot_i18n::tr("Close search"))
                                .on_click(
                                    cx.listener(|this, _, window, cx| this.close_find(window, cx)),
                                ),
                        )
                    }),
            )
    }

    pub(super) fn render_transcript(
        &mut self,
        doc: &MeetingDoc,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if doc.rows.is_empty() {
            let lb = cx.lb().clone();
            return div()
                .id("transcript-empty")
                .size_full()
                .overflow_y_scrollbar()
                .child(
                    v_flex()
                        .px(metric::DETAIL_PADDING)
                        .pt(px(4.))
                        .gap(metric::SECTION_SPACING)
                        .children(self.render_status(doc, cx))
                        .child(
                            div()
                                .py(px(6.))
                                .text_size(ty::BODY)
                                .text_color(lb.text_secondary)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "No transcript yet.",
                                ))),
                        ),
                )
                .into_any_element();
        }
        self.focused_row = self.focus_at.and_then(|at| doc.row_at(at));
        div()
            .id("transcript")
            .relative()
            .size_full()
            .child(
                list(
                    self.transcript_state.clone(),
                    cx.processor(|this, ix: usize, window, cx| {
                        this.render_transcript_item(ix, window, cx)
                    }),
                )
                .size_full(),
            )
            .vertical_scrollbar(&self.transcript_state)
            .into_any_element()
    }

    fn render_transcript_item(
        &mut self,
        ix: usize,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(doc) = self.doc.clone() else {
            return div().into_any_element();
        };
        let lb = cx.lb().clone();
        if ix == 0 {
            let engine = doc
                .transcript
                .as_ref()
                .map(|t| t.engine.clone())
                .unwrap_or_default();
            return v_flex()
                .px(metric::DETAIL_PADDING)
                .pt(px(4.))
                .pb(px(4.))
                .gap(px(12.))
                .children(self.render_status(&doc, cx))
                .when(!engine.is_empty() && engine != "merged", |this| {
                    this.child(
                        h_flex()
                            .max_w(metric::CONTENT_MAX_WIDTH)
                            .gap(px(6.))
                            .items_center()
                            .px(px(10.))
                            .py(px(6.))
                            .rounded(metric::GROUP_RADIUS)
                            .bg(lb.chip_fill.opacity(0.6))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(ui::icon(Ico::AudioLines, px(14.), lb.accent_text))
                            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                "Transcribed with {engine}",
                                &[("engine", engine.to_string())],
                            ))),
                    )
                })
                .into_any_element();
        }
        let row_ix = ix - 1;
        let Some(row) = doc.rows.get(row_ix).cloned() else {
            return div().into_any_element();
        };
        let focused_row = self.focused_row;
        let current_match = self.find.matches.get(self.find.current).cloned();
        let highlights: Vec<_> = self
            .find
            .matches
            .iter()
            .filter(|(r, range)| *r == row_ix && !range.is_empty())
            .map(|(_, range)| {
                let is_current = current_match
                    .as_ref()
                    .is_some_and(|(r, cr)| *r == row_ix && cr == range);
                let color = if is_current {
                    lb.attention.opacity(0.55)
                } else {
                    lb.attention.opacity(0.22)
                };
                (
                    range.clone(),
                    HighlightStyle {
                        background_color: Some(color),
                        ..Default::default()
                    },
                )
            })
            .collect();
        let is_focused = focused_row == Some(row_ix)
            || current_match
                .as_ref()
                .is_some_and(|(r, range)| *r == row_ix && range.is_empty());
        let start = row.start;
        let speaker_key = row.speaker.clone();
        let stamp = lokalbot_core::time::stamp(start);
        let color = super::speaker_color(row.color, cx);
        let hover = lb.accent_wash;

        let time = h_flex()
            .id(("segment-time", row_ix))
            .w(px(80.))
            .flex_none()
            .justify_end()
            .gap(px(4.))
            .items_center()
            .h(px(21.))
            .cursor_pointer()
            .text_size(ty::SECONDARY)
            .text_color(lb.accent_text)
            .child(crate::ui::waveform::play_glyph(px(9.), lb.accent_text))
            .child(stamp.clone())
            .tooltip(move |window, cx| {
                gpui_kit::component::tooltip::Tooltip::new(lokalbot_i18n::format(
                    "Play from {stamp}",
                    &[("stamp", stamp.to_string())],
                ))
                .build(window, cx)
            })
            .on_click(cx.listener(move |this, _, _, cx| {
                this.focus_at = Some(start);
                if this.player.is_some() {
                    this.play_from(start, cx);
                }
                cx.notify();
            }));

        let speaker: AnyElement = if row.begins_turn {
            let review = doc.review.iter().find(|s| s.key == speaker_key).cloned();
            h_flex()
                .id(("segment-speaker", row_ix))
                .w(px(128.))
                .flex_none()
                .h(px(21.))
                .gap(px(6.))
                .items_center()
                .overflow_hidden()
                .cursor_pointer()
                .child(ui::status_dot(color, px(6.)))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .hover(|s| s.underline())
                        .child(row.name.clone()),
                )
                .tooltip({
                    let name = row.name.clone();
                    move |window, cx| {
                        gpui_kit::component::tooltip::Tooltip::new(lokalbot_i18n::format(
                            "Rename speaker: {name}",
                            &[("name", format!("{}", name))],
                        ))
                        .build(window, cx)
                    }
                })
                .on_click(cx.listener(move |this, _, window, cx| {
                    if let Some(speaker) = review.clone() {
                        this.open_name_speaker(speaker, window, cx);
                    }
                }))
                .into_any_element()
        } else {
            div().w(px(128.)).flex_none().into_any_element()
        };

        div()
            .px(px(22.))
            .child(
                h_flex()
                    .id(("segment", row_ix))
                    .max_w(metric::CONTENT_MAX_WIDTH)
                    .items_start()
                    .gap(px(10.))
                    .mt(px(if row.begins_turn { 12. } else { 2. }))
                    .pb(px(3.))
                    .pt(px(1.))
                    .px(px(6.))
                    .rounded(px(6.))
                    .when(is_focused, |this| this.bg(hover))
                    .child(time)
                    .child(speaker)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::READING)
                            .line_height(px(21.))
                            .text_color(lb.text)
                            .child(StyledText::new(row.text.clone()).with_highlights(highlights)),
                    ),
            )
            .when(row_ix + 1 == doc.rows.len(), |this| {
                this.pb(metric::DETAIL_PADDING)
            })
            .into_any_element()
    }
}
