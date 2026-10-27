//! Keyword results while typing (`AskView.results`).

use crate::i18n::h_flex;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    StatefulInteractiveElement as _, Styled as _, div, px,
};

use super::scope::DateScope;
use super::search::{Facet, MeetingGroup, ScreenResult};
use super::{AskPage, history};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, result_row};

/// Rows above the first result in the scroll list (status line, count line).
pub const HEADER_ROWS: usize = 2;

impl AskPage {
    pub(super) fn render_results(&mut self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let count = self.results.count();
        let asks = !self.results.picked_with_keyboard && super::search::is_question(&self.query);
        let count_text = {
            let base = history::count_label(count, "result");
            let base = if self.results.truncated {
                lokalbot_i18n::format("More than {base}", &[("base", base.to_string())])
            } else {
                base
            };
            if asks {
                lokalbot_i18n::format(
                    "{base} · Return asks · ↓ to pick a result",
                    &[("base", base.to_string())],
                )
            } else {
                lokalbot_i18n::format(
                    "{base} · Return opens · Ctrl+Return asks",
                    &[("base", base.to_string())],
                )
            }
        };
        let column = |element: AnyElement| {
            div()
                .w_full()
                .max_w(metric::READING_MAX_WIDTH + metric::DETAIL_PADDING * 2.)
                .px(metric::DETAIL_PADDING)
                .child(element)
                .into_any_element()
        };

        let mut rows: Vec<AnyElement> = Vec::new();
        rows.push(column(
            div()
                .pt(px(14.))
                .when(self.results.running, |this| {
                    this.child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .pb(px(4.))
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(Spinner::new().xsmall().color(lb.text_secondary))
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Searching local sources…",
                            ))),
                    )
                })
                .into_any_element(),
        ));
        rows.push(column(
            div()
                .pb(px(6.))
                .text_size(ty::SECONDARY)
                .text_color(lb.supporting)
                .when(!self.results.running || count > 0, |this| {
                    this.child(count_text)
                })
                .into_any_element(),
        ));

        if count == 0 && !self.results.running {
            let message = lokalbot_i18n::format(
                "No results for “{0}” in {1} · {2}.",
                &[
                    ("0", self.query.trim().to_string()),
                    ("1", self.sources.summary().to_string()),
                    ("2", self.date_scope.label().to_string()),
                ],
            );
            let filtered = self.facet != Facet::All || self.date_scope != DateScope::AnyTime;
            rows.push(column(
                v_flex()
                    .gap(px(6.))
                    .py(px(6.))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(message),
                    )
                    .when(filtered, |this| {
                        let page = cx.entity();
                        this.child(div().text_size(ty::SECONDARY).child(ui::link(
                            "ask-clear-filters",
                            lokalbot_i18n::tr("Clear search filters"),
                            move |window, cx| {
                                page.update(cx, |page, cx| page.clear_filters(window, cx))
                            },
                            cx,
                        )))
                    })
                    .into_any_element(),
            ));
        }

        let groups = self.results.meetings.clone();
        for (index, group) in groups.iter().enumerate() {
            rows.push(column(
                self.render_group(index, group, cx).into_any_element(),
            ));
        }
        let screens = self.results.screens.clone();
        for (offset, screen) in screens.iter().enumerate() {
            let index = groups.len() + offset;
            rows.push(column(
                self.render_screen(index, screen, cx).into_any_element(),
            ));
        }
        rows.push(div().h(px(12.)).into_any_element());

        // Rows are direct children so the scroll handle can reveal a selected row.
        v_flex()
            .id("ask-results")
            .size_full()
            .items_center()
            .overflow_y_scroll()
            .track_scroll(&self.results_scroll)
            .children(rows)
    }

    fn render_group(
        &self,
        index: usize,
        group: &MeetingGroup,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let selected = index == self.results.selected;
        let meeting_id = group.meeting.id;
        let key = history::element_key(meeting_id);
        let title = group.meeting.display_title();
        let date = group
            .meeting
            .started_at
            .with_timezone(&chrono::Local)
            .format_localized(
                lokalbot_i18n::date_pattern("%b %-d, %Y"),
                lokalbot_i18n::date_locale(),
            )
            .to_string();
        let expanded = self.results.expanded.contains(&meeting_id);
        let primary = group.hits[0].clone();
        let more = group.hits.len() - 1;

        let hit_row = |id: (&'static str, u64),
                       hit: &super::search::Hit,
                       cx: &mut Context<Self>| {
            let at = hit.moment();
            div()
                .id(id)
                .w_full()
                .cursor_pointer()
                .child(result_row::result_body(
                    title.clone().into(),
                    Some(date.clone().into()),
                    hit.kind_label().into(),
                    None,
                    &hit.snippet,
                    cx,
                ))
                .on_click(cx.listener(move |this, _, _, cx| this.open_meeting(meeting_id, at, cx)))
        };

        v_flex()
            .w_full()
            .gap(px(4.))
            .px(px(10.))
            .py(px(8.))
            .rounded(metric::ROW_RADIUS)
            .when(selected, |this| this.bg(lb.accent_wash))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(hit_row(("ask-result", key), &primary, cx))
            .when(more > 0, |this| {
                let label = if more == 1 {
                    lokalbot_i18n::tr("1 more match").to_string()
                } else {
                    lokalbot_i18n::format("{more} more matches", &[("more", format!("{}", more))])
                };
                this.child(
                    h_flex()
                        .id(("ask-result-more", key))
                        .gap(px(4.))
                        .items_center()
                        .cursor_pointer()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(lb.text_secondary)
                        .hover(|s| s.text_color(lb.text))
                        .child(ui::icon(
                            if expanded {
                                Ico::ChevronDown
                            } else {
                                Ico::ChevronRight
                            },
                            px(12.),
                            lb.text_secondary,
                        ))
                        .child(label)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if !this.results.expanded.remove(&meeting_id) {
                                this.results.expanded.insert(meeting_id);
                            }
                            cx.notify();
                        })),
                )
            })
            .when(expanded, |this| {
                let hits: Vec<_> = group.hits.iter().skip(1).cloned().collect();
                this.child(
                    v_flex().gap(px(8.)).pl(px(16.)).pt(px(2.)).children(
                        hits.iter()
                            .enumerate()
                            .map(|(i, hit)| {
                                hit_row(("ask-result-hit", key.wrapping_add(i as u64 + 1)), hit, cx)
                            })
                            .collect::<Vec<_>>(),
                    ),
                )
            })
    }

    /// A screen moment: thumbnail, title, "App · date" and the matched text.
    fn render_screen(
        &self,
        index: usize,
        screen: &ScreenResult,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let selected = index == self.results.selected;
        let moment = screen.moment.clone();
        let title = if moment.window_title.trim().is_empty() {
            moment.app.clone()
        } else {
            moment.window_title.clone()
        };
        let snippet = result_row::without_title_echo(&screen.snippet, &title).unwrap_or_default();
        let when = moment
            .ts
            .with_timezone(&chrono::Local)
            .format_localized(
                lokalbot_i18n::date_pattern("%b %-d, %Y at %-I:%M %p"),
                lokalbot_i18n::date_locale(),
            )
            .to_string();
        let mut meta = lokalbot_i18n::format(
            "{0} · {when}",
            &[("0", moment.app.to_string()), ("when", when.to_string())],
        );
        if screen.captures > 1 {
            meta.push_str(&lokalbot_i18n::format(
                " · {0} captures",
                &[("0", format!("{}", screen.captures))],
            ));
        }
        let data = self.data.clone();
        h_flex()
            .id(("ask-screen", moment.id as u64))
            .w_full()
            .gap(px(12.))
            .items_start()
            .px(px(10.))
            .py(px(8.))
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.accent_wash))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(screen_tile(&moment.app, px(116.), px(72.), cx))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(3.))
                    .child(
                        h_flex()
                            .gap(px(6.))
                            .items_center()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(title),
                            )
                            .child(result_row::kind_chip(lokalbot_i18n::tr("Screen"), cx)),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .child(meta),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .line_height(px(19.))
                            .text_color(lb.supporting)
                            .line_clamp(2)
                            .child(result_row::highlighted(&snippet, lb.text)),
                    ),
            )
            .on_click(move |_, _, cx| super::open_screen_moment(&data, &moment, cx))
    }
}

/// A screen moment's thumbnail stand-in: the app's color with a display glyph.
pub fn screen_tile(
    app: &str,
    width: gpui_kit::Pixels,
    height: gpui_kit::Pixels,
    cx: &gpui_kit::App,
) -> gpui_kit::Div {
    let lb = cx.lb();
    let tint = lb.app_color(app);
    div()
        .w(width)
        .h(height)
        .flex_none()
        .rounded(metric::ROW_RADIUS)
        .bg(tint.opacity(0.16))
        .border_1()
        .border_color(tint.opacity(0.28))
        .flex()
        .items_center()
        .justify_center()
        .child(ui::icon(Ico::Monitor, height * 0.4, tint))
}
