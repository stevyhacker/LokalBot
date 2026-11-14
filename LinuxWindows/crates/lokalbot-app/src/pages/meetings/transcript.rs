//! The Transcript tab (`MeetingTranscriptList`): one panel with Find in its
//! header and "Transcribed with …" in its footer, speaker turns on its
//! surface with a quiet time before each line. The list is virtualized, so
//! the panel is drawn in pieces: its top with the header, one piece per line,
//! and its bottom with the footer.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, Div, FontWeight, HighlightStyle, InteractiveElement as _, IntoElement,
    ParentElement as _, StatefulInteractiveElement as _, Styled as _, StyledText, Window, div,
    list, px,
};

use super::MeetingsPage;
use super::model::MeetingDoc;
use super::page_search::{Location, Section};
use super::presentation::{FindPlacement, layout};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::action_row::short_stamp;
use crate::ui::{self, Ico};

impl MeetingsPage {
    /// "2 of 5 · Transcript", or "No matches".
    fn find_status(&self) -> Option<String> {
        let total = self.find.matches.len();
        if self.find.query.trim().is_empty() {
            None
        } else if total == 0 {
            Some(lokalbot_i18n::tr("No matches").to_string())
        } else {
            let section = self.find.matches[self.find.current].location.section();
            Some(lokalbot_i18n::format(
                "{0} of {total} · {section}",
                &[
                    ("0", (self.find.current + 1).to_string()),
                    ("total", total.to_string()),
                    ("section", lokalbot_i18n::tr(section.label()).to_string()),
                ],
            ))
        }
    }

    /// The previous and next match buttons.
    fn find_steps(&self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        let has_matches = !self.find.matches.is_empty();
        vec![
            div()
                .w(px(1.))
                .h(px(18.))
                .bg(lb.separator)
                .into_any_element(),
            Button::new("find-previous")
                .ghost()
                .xsmall()
                .icon(Icon::new(Ico::ChevronUp))
                .tooltip(lokalbot_i18n::tr("Previous match"))
                .disabled(!has_matches)
                .on_click(cx.listener(|this, _, _, cx| this.move_find(-1, cx)))
                .into_any_element(),
            Button::new("find-next")
                .ghost()
                .xsmall()
                .icon(Icon::new(Ico::ChevronDown))
                .tooltip(lokalbot_i18n::tr("Next match"))
                .disabled(!has_matches)
                .on_click(cx.listener(|this, _, _, cx| this.move_find(1, cx)))
                .into_any_element(),
        ]
    }

    /// The field's surface (`workspaceControl`).
    fn find_field(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        h_flex()
            .items_center()
            .gap(px(8.))
            .px(px(10.))
            .rounded(px(7.))
            .bg(lb.panel)
            .border_1()
            .border_color(lb.separator)
            .child(ui::icon(Ico::Search, px(14.), lb.text_secondary))
            .child(
                div().flex_1().min_w_0().child(
                    Input::new(&self.find.input)
                        .appearance(false)
                        .small()
                        .cleanable(true),
                ),
            )
    }

    /// Ctrl+F's search of the whole meeting, pinned under the player because
    /// its matches move between tabs.
    pub(super) fn render_find_bar(&mut self, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let status = self.find_status();
        let steps = self.find_steps(cx);
        div().w_full().child(
            self.find_field(cx)
                .w_full()
                .max_w(px(720.))
                .py(px(4.))
                .when_some(status, |this, status| {
                    this.child(
                        div()
                            .flex_none()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .child(status),
                    )
                })
                .children(steps)
                .child(
                    Button::new("find-close")
                        .ghost()
                        .xsmall()
                        .icon(Icon::new(Ico::X))
                        .tooltip(lokalbot_i18n::tr("Close search"))
                        .on_click(cx.listener(|this, _, window, cx| this.close_find(window, cx))),
                ),
        )
    }

    /// Find in transcript, at the trailing edge of the Transcript panel's
    /// header with its count before it; the steps show once something is
    /// typed.
    fn render_panel_find(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let scale = self.text_scale(cx);
        let status = self.find_status();
        let typed = !self.find.query.is_empty();
        let steps = if typed {
            self.find_steps(cx)
        } else {
            Vec::new()
        };
        h_flex()
            .flex_1()
            .min_w_0()
            .justify_end()
            .gap(px(8.))
            .items_center()
            .when_some(status, |this, status| {
                this.child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .child(status),
                )
            })
            .child(
                self.find_field(cx)
                    .flex_none()
                    .w(layout::scaled(layout::FIND_FIELD, scale))
                    .min_w(px(layout::FIND_FIELD_MIN))
                    .py(px(1.))
                    .children(steps),
            )
            .into_any_element()
    }

    /// The panel's header bar: its symbol, "Transcript", and Find.
    fn transcript_header(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let find = (super::presentation::find_placement(self.tab, self.find.open)
            == FindPlacement::TranscriptPanel)
            .then(|| self.render_panel_find(cx));
        h_flex()
            .w_full()
            .min_h(metric::PANEL_HEADER_HEIGHT)
            .pl(metric::PANEL_INSET)
            .pr(metric::PANEL_INSET - px(4.))
            .py(px(6.))
            .gap(px(8.))
            .items_center()
            .child(
                div()
                    .w(px(18.))
                    .flex_none()
                    .flex()
                    .justify_center()
                    .child(ui::icon(Ico::MessageSquareText, px(15.), lb.accent_text)),
            )
            .child(
                div()
                    .flex_none()
                    .text_size(ty::PANEL_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(lokalbot_i18n::tr("Transcript")),
            )
            .child(div().flex_1().min_w(px(8.)))
            .children(find)
            .into_any_element()
    }

    pub(super) fn render_transcript(
        &mut self,
        doc: &MeetingDoc,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if doc.rows.is_empty() {
            let status = self.render_status(doc, cx);
            let header = self.transcript_header(cx);
            let empty = div()
                .px(metric::PANEL_INSET)
                .py(px(10.))
                .text_size(ty::BODY)
                .text_color(cx.lb().supporting)
                .child(self.find_marked(
                    Location::EmptyState(Section::Transcript),
                    lokalbot_i18n::tr("No transcript yet."),
                    lokalbot_i18n::tr("No transcript yet."),
                    false,
                    cx,
                ));
            return div()
                .id("transcript-empty")
                .size_full()
                .overflow_y_scrollbar()
                .child(
                    div().w_full().flex().justify_center().child(
                        self.page_column(cx)
                            .pt(px(4.))
                            .pb(layout::GUTTER)
                            .gap(layout::PANEL_GAP)
                            .children(status)
                            .child(
                                crate::ui::section_panel::panel_surface(cx)
                                    .flex()
                                    .flex_col()
                                    .child(header)
                                    .child(ui::divider(cx))
                                    .child(empty),
                            ),
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

    /// One piece of the page: item 0 is the status lines and the panel's
    /// top; item r + 1 is line r, the last one closing the panel.
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
        let column = |this: &Self, cx: &mut Context<Self>, piece: AnyElement| {
            div()
                .w_full()
                .flex()
                .justify_center()
                .child(this.page_column(cx).child(piece))
                .into_any_element()
        };
        if ix == 0 {
            let status = self.render_status(&doc, cx);
            let on_screen = (!doc.screen.is_empty()).then(|| self.render_on_screen_now(&doc, cx));
            let header = self.transcript_header(cx);
            let top = v_flex()
                .w_full()
                .bg(lb.panel)
                .border_t_1()
                .border_l_1()
                .border_r_1()
                .border_color(lb.group_stroke)
                .rounded_t(metric::GROUP_RADIUS)
                .child(header)
                .child(ui::divider(cx))
                .child(div().h(px(2.)));
            let piece = v_flex()
                .w_full()
                .pt(px(4.))
                .gap(layout::PANEL_GAP)
                .children(status)
                .children(on_screen)
                .child(top)
                .into_any_element();
            return column(self, cx, piece);
        }
        let row_ix = ix - 1;
        if row_ix >= doc.rows.len() {
            return div().into_any_element();
        }
        let last = row_ix + 1 == doc.rows.len();
        let line = self.render_line(&doc, row_ix, cx);
        let middle = v_flex()
            .w_full()
            .bg(lb.panel)
            .border_l_1()
            .border_r_1()
            .border_color(lb.group_stroke)
            .px(metric::PANEL_INSET - px(layout::LINE_INSET))
            .child(line)
            .when(last, |this| this.pb(px(14.)));
        let piece = if last {
            let engine = super::page_search::engine_line(&doc);
            let footer = engine.map(|engine| {
                h_flex()
                    .w_full()
                    .min_h(metric::PANEL_FOOTER_HEIGHT)
                    .px(metric::PANEL_INSET)
                    .py(px(6.))
                    .items_center()
                    .bg(lb.group_fill)
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(self.find_marked(
                        Location::TranscriptEngine,
                        &engine,
                        engine.clone(),
                        false,
                        cx,
                    ))
            });
            v_flex()
                .w_full()
                .pb(layout::GUTTER)
                .child(
                    v_flex()
                        .w_full()
                        .rounded_b(metric::GROUP_RADIUS)
                        .overflow_hidden()
                        .border_b_1()
                        .border_color(lb.group_stroke)
                        .child(middle)
                        .when_some(footer, |this, footer| {
                            this.child(
                                div()
                                    .border_l_1()
                                    .border_r_1()
                                    .border_color(lb.group_stroke)
                                    .child(ui::divider(cx))
                                    .child(footer),
                            )
                        }),
                )
                .into_any_element()
        } else {
            middle.into_any_element()
        };
        column(self, cx, piece)
    }

    /// One line: on a new speaker turn the speaker above it, then a quiet
    /// time and what was said. The line being played or opened is
    /// highlighted, and any time plays from there.
    fn render_line(
        &mut self,
        doc: &MeetingDoc,
        row_ix: usize,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let Some(row) = doc.rows.get(row_ix).cloned() else {
            return div().into_any_element();
        };
        let current_match = self.find.matches.get(self.find.current).cloned();
        let row_location = Location::Row(row_ix);
        let highlights: Vec<_> = self
            .find
            .matches
            .iter()
            .filter(|found| found.location == row_location)
            .map(|found| {
                let is_current = current_match.as_ref().is_some_and(|current| {
                    current.location == row_location && current.range == found.range
                });
                (
                    found.range.clone(),
                    HighlightStyle {
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
        let is_current = self.focused_row == Some(row_ix)
            || current_match
                .as_ref()
                .is_some_and(|current| current.location.transcript_row() == Some(row_ix));
        let start = row.start;
        let stamp = short_stamp(start);
        let marked_stamp =
            self.find_marked(Location::RowTime(row_ix), &stamp, stamp.clone(), false, cx);
        let scale = self.text_scale(cx);
        let measure = layout::scaled(layout::PROSE, scale)
            + px(layout::TIME_COLUMN + layout::COLUMN_GAP + 2. * layout::LINE_INSET);

        let speaker = row.begins_turn.then(|| {
            let needs_name = doc
                .speakers
                .iter()
                .any(|s| s.key == row.speaker && s.needs_name);
            let key = row.speaker.clone();
            let name = row.name.clone();
            let marked_name = self.find_marked(
                Location::RowSpeaker(row_ix),
                &row.name,
                row.name.clone(),
                false,
                cx,
            );
            h_flex()
                .h(px(20.))
                .mt(px(12.))
                .pl(px(layout::TIME_COLUMN
                    + layout::COLUMN_GAP
                    + layout::LINE_INSET))
                .gap(px(6.))
                .items_center()
                .child(ui::status_dot(super::speaker_color(row.color, cx), px(7.)))
                .child(
                    div()
                        .id(("segment-speaker", row_ix))
                        .min_w_0()
                        .truncate()
                        .cursor_pointer()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .when(needs_name, |this| {
                            this.underline()
                                .text_decoration_1()
                                .text_decoration_color(lb.text_secondary)
                        })
                        .when(!needs_name, |this| this.hover(|s| s.underline()))
                        .child(marked_name)
                        .tooltip(move |window, cx| {
                            Tooltip::new(if needs_name {
                                lokalbot_i18n::tr("Name this speaker").to_string()
                            } else {
                                lokalbot_i18n::format(
                                    "Rename speaker: {name}",
                                    &[("name", name.to_string())],
                                )
                            })
                            .build(window, cx)
                        })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if needs_name {
                                this.open_naming_sheet(window, cx);
                            } else {
                                this.open_name_speaker_key(&key, window, cx);
                            }
                        })),
                )
        });

        let time = h_flex()
            .id(("segment-time", row_ix))
            .w(px(layout::TIME_COLUMN))
            .flex_none()
            .justify_end()
            .gap(px(3.))
            .items_center()
            .h(px(22.))
            .cursor_pointer()
            .text_size(ty::SECONDARY)
            .text_color(if is_current {
                lb.accent_text
            } else {
                lb.supporting
            })
            .when(is_current, |this| {
                this.font_weight(FontWeight::SEMIBOLD)
                    .child(crate::ui::waveform::play_glyph(px(7.), lb.accent_text))
            })
            .child(marked_stamp)
            .tooltip({
                let stamp = stamp.clone();
                move |window, cx| {
                    Tooltip::new(lokalbot_i18n::tr("Play from %@").replace("%@", &stamp))
                        .build(window, cx)
                }
            })
            .on_click(cx.listener(move |this, _, _, cx| {
                this.focus_at = Some(start);
                if this.player.is_some() {
                    this.play_from(start, cx);
                }
                cx.notify();
            }));

        v_flex()
            .w_full()
            .max_w(measure)
            .children(speaker)
            .child(
                h_flex()
                    .id(("segment", row_ix))
                    .w_full()
                    .items_start()
                    .gap(px(layout::COLUMN_GAP))
                    .mt(px(if row.begins_turn { 1. } else { 0. }))
                    .py(px(3.))
                    .px(px(layout::LINE_INSET))
                    .rounded(px(6.))
                    .when(is_current, |this| this.bg(lb.accent_fill.opacity(0.14)))
                    .child(time)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::READING)
                            .line_height(px(22.))
                            .text_color(lb.text)
                            .child(StyledText::new(row.text.clone()).with_highlights(highlights)),
                    ),
            )
            .into_any_element()
    }
}
