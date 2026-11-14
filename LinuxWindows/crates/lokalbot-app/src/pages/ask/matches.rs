//! The matches for what is typed in Ask (`AskMatchesList`, `AskMatchesHeader`):
//! a row per meeting, screen moment, file or saved agent note, each with the
//! lines that matched. The same rows sit under the field on a new question,
//! in the tray above the field inside a conversation, and under an answer
//! that failed. Clicking a title or a line opens it.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenuItem};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, ElementId, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px,
};
use lokalbot_core::search::DocKind;

use super::AskPage;
use super::model::{self, MatchesPlacement};
use super::scope::DateScope;
use super::search::{self, Facet, Hit, MeetingGroup, ScreenResult};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, result_row, screen_thumbnail};

/// Where a list of matches is drawn.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum ListStyle {
    /// Under the field or an answer: wider rows, a column for each line's kind.
    Card,
    /// Inside the tray above a docked field.
    Tray,
}

/// How many matching lines a meeting lists before folding the rest.
const FOLDED_LINES: usize = 3;
/// Wide enough for "0:35 · Other speaker" beside the matched words.
const KIND_COLUMN: f32 = 148.;
/// The tray never covers more of the conversation than this.
pub(super) const TRAY_MAX_HEIGHT: f32 = 320.;
const CARD_RADIUS: f32 = 12.;

/// One row of the list; its frame (card, segment or tray) is the caller's.
pub(super) struct MatchRow {
    pub element: AnyElement,
}

impl AskPage {
    /// "Matches · 3 in 1 meeting", the search in progress, and the keys that act
    /// on the matches.
    pub(super) fn render_matches_header(&self, hints: &[(&str, &str)], cx: &App) -> Div {
        let lb = cx.lb();
        let found = &self.results.found;
        let empty = found.meetings.is_empty()
            && found.screens.is_empty()
            && found.files.is_empty()
            && found.notes.is_empty();
        let mut row = h_flex()
            .w_full()
            .gap(px(8.))
            .items_center()
            .overflow_hidden()
            .child(
                div()
                    .flex_none()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(lokalbot_i18n::tr("Matches")),
            );
        if self.results.running {
            row = row.child(
                h_flex()
                    .min_w_0()
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(Spinner::new().xsmall().color(lb.supporting))
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .child(lokalbot_i18n::tr("Searching local sources…")),
                    ),
            );
        } else if !empty {
            row = row.child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(count_label(found)),
            );
        }
        row = row.child(div().flex_1().min_w(px(8.)));
        if !empty {
            for (key, action) in hints {
                row = row.child(
                    h_flex()
                        .flex_none()
                        .gap(px(5.))
                        .items_center()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .child(
                            h_flex()
                                .h(px(16.))
                                .min_w(px(16.))
                                .px(px(3.))
                                .justify_center()
                                .items_center()
                                .rounded(px(4.))
                                .border_1()
                                .border_color(lb.text.opacity(0.12))
                                .bg(lb.panel)
                                .text_size(ty::CAPTION)
                                .child(match *key {
                                    "↓" => ui::icon(Ico::ArrowDown, px(11.), lb.supporting)
                                        .into_any_element(),
                                    "↩" => ui::icon(Ico::CornerDownLeft, px(11.), lb.supporting)
                                        .into_any_element(),
                                    other => other.to_string().into_any_element(),
                                }),
                        )
                        .child(lokalbot_i18n::tr(action).to_string()),
                );
            }
        }
        row
    }

    /// The rows of `found`, in list order: meetings, screen moments, files and
    /// agent notes. `selected` is the row the arrow keys are on.
    pub(super) fn match_rows(
        &self,
        found: &search::Results,
        style: ListStyle,
        selected: Option<usize>,
        id: &'static str,
        cx: &mut Context<Self>,
    ) -> Vec<MatchRow> {
        let mut rows = Vec::new();
        let mut index = 0;
        for group in &found.meetings {
            rows.push(self.meeting_row(group, index, style, selected, id, cx));
            index += 1;
        }
        for screen in &found.screens {
            rows.push(self.screen_row(screen, index, style, selected, id, cx));
            index += 1;
        }
        for hit in &found.files {
            rows.push(self.file_row(hit, index, style, selected, id, cx));
            index += 1;
        }
        for hit in &found.notes {
            rows.push(self.note_row(hit, index, style, selected, id, cx));
            index += 1;
        }
        rows
    }

    /// The matches as one white card, for an answer that failed.
    pub(super) fn match_card(
        &self,
        found: &search::Results,
        id: &'static str,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let rows = self.match_rows(found, ListStyle::Card, None, id, cx);
        let mut card = v_flex()
            .w_full()
            .rounded(px(CARD_RADIUS))
            .bg(lb.panel)
            .border_1()
            .border_color(lb.group_stroke)
            .overflow_hidden();
        for (index, row) in rows.into_iter().enumerate() {
            if index > 0 {
                card = card.child(inset_divider(&lb));
            }
            card = card.child(row.element);
        }
        card
    }

    /// A new question: the matches sit under the field. Each row is its own
    /// child of the scrolling column, so the arrow keys can bring one into view.
    pub(super) fn render_matches_under_field(&mut self, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let lb = cx.lb().clone();
        let mut children = vec![
            div()
                .pt(px(20.))
                .pb(px(8.))
                .px(px(4.))
                .child(self.render_matches_header(&[("↓", "to open"), ("↩", "to ask")], cx))
                .into_any_element(),
        ];
        let found = self.results.found.clone();
        let rows = self.match_rows(
            &found,
            ListStyle::Card,
            self.results.cursor.index(),
            "ask-match",
            cx,
        );
        let last = rows.len().saturating_sub(1);
        for (index, row) in rows.into_iter().enumerate() {
            let segment = v_flex()
                .w_full()
                .bg(lb.panel)
                .border_l_1()
                .border_r_1()
                .border_color(lb.group_stroke)
                .when(index == 0, |this| {
                    this.border_t_1().rounded_t(px(CARD_RADIUS))
                })
                .when(index == last, |this| {
                    this.border_b_1().rounded_b(px(CARD_RADIUS))
                })
                .when(index > 0, |this| this.child(inset_divider(&lb)))
                .child(row.element);
            children.push(segment.into_any_element());
        }
        if found.meetings.is_empty()
            && found.screens.is_empty()
            && found.files.is_empty()
            && found.notes.is_empty()
            && !self.results.running
        {
            children.push(self.render_no_matches(cx).into_any_element());
        }
        children
    }

    /// "No matches for “…”", or what Activity alone can do, and the way out of
    /// the filters that hid them.
    fn render_no_matches(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let offered = self.offered(cx);
        let only_activity = super::scope::Source::available(offered)
            .filter(|source| self.sources.contains(*source))
            .eq([super::scope::Source::Activity]);
        let text = if only_activity {
            lokalbot_i18n::tr(
                "Activity totals are available in Ask. Enable Meetings or Screen to search source text.",
            )
            .to_string()
        } else {
            lokalbot_i18n::mac("No matches for “%@”.", &[self.query.trim()])
        };
        let filtered = self.date_scope != DateScope::AnyTime
            || self.facet != Facet::All
            || self.screen_app.is_some();
        let page = cx.entity();
        v_flex()
            .gap(px(8.))
            .px(px(4.))
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.supporting)
                    .child(ui::text::paragraph(text)),
            )
            .when(filtered, |this| {
                this.child(div().text_size(ty::SECONDARY).child(ui::link(
                    "ask-clear-filters",
                    lokalbot_i18n::tr("Clear search filters"),
                    move |window, cx| page.update(cx, |page, cx| page.clear_filters(window, cx)),
                    cx,
                )))
            })
    }

    /// Inside a conversation: the matches rise above the docked field and the
    /// thread stays where it is. Nothing to list means no tray.
    pub(super) fn render_matches_tray(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let phase = self.ask_phase(cx);
        let found = self.results.found.clone();
        let empty = found.meetings.is_empty()
            && found.screens.is_empty()
            && found.files.is_empty()
            && found.notes.is_empty();
        if phase.matches_placement() != Some(MatchesPlacement::TrayAboveField)
            || (empty && !self.results.running)
        {
            return None;
        }
        let lb = cx.lb().clone();
        let collapsed = self.tray_collapsed;
        let hints: &[(&str, &str)] = if collapsed {
            &[("↓", "to open"), ("↩", "to ask")]
        } else {
            &[("↓", "to open"), ("↩", "to ask"), ("esc", "to hide")]
        };
        let header = h_flex()
            .w_full()
            .gap(px(6.))
            .items_center()
            .px(px(10.))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(self.render_matches_header(hints, cx)),
            )
            .when(!empty, |this| {
                this.child(
                    Button::new("ask-tray-toggle")
                        .ghost()
                        .xsmall()
                        .icon(Icon::new(if collapsed {
                            Ico::ChevronUp
                        } else {
                            Ico::ChevronDown
                        }))
                        .tooltip(if collapsed {
                            lokalbot_i18n::tr("Expand")
                        } else {
                            lokalbot_i18n::tr("Collapse")
                        })
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.tray_collapsed = !this.tray_collapsed;
                            cx.notify();
                        })),
                )
            });
        let rows = if collapsed || empty {
            Vec::new()
        } else {
            self.match_rows(
                &found,
                ListStyle::Tray,
                self.results.cursor.index(),
                "ask-tray-match",
                cx,
            )
        };
        let list = (!rows.is_empty()).then(|| {
            v_flex()
                .id("ask-tray-list")
                .w_full()
                .max_h(px(TRAY_MAX_HEIGHT))
                .overflow_y_scroll()
                .track_scroll(&self.results_scroll)
                .children(rows.into_iter().map(|row| row.element))
        });
        Some(
            v_flex()
                .w_full()
                .gap(px(6.))
                .pt(px(12.))
                .pb(px(if list.is_some() { 6. } else { 12. }))
                .px(px(8.))
                .rounded(px(14.))
                .bg(lb.panel)
                .border_1()
                .border_color(lb.separator)
                .shadow_lg()
                .child(header)
                .children(list)
                .into_any_element(),
        )
    }

    // ---------------------------------------------------------------- rows

    fn meeting_row(
        &self,
        group: &MeetingGroup,
        index: usize,
        style: ListStyle,
        selected: Option<usize>,
        id: &'static str,
        cx: &mut Context<Self>,
    ) -> MatchRow {
        let lb = cx.lb().clone();
        let meeting_id = group.meeting.id;
        let key = format!("meeting:{meeting_id}");
        let expanded = self.results.expanded.contains(&key);
        let shown = if expanded {
            group.hits.len()
        } else {
            group.hits.len().min(FOLDED_LINES)
        };
        let primary_at = group.hits.first().and_then(Hit::moment);
        let now = chrono::Local::now();
        let mut content = vec![
            self.row_title(
                ElementId::NamedInteger(SharedString::from(format!("{id}-title")), index as u64),
                group.meeting.display_title(),
                Some(model::moment_label(group.meeting.started_at, now)),
                move |this, cx| this.open_meeting(meeting_id, primary_at, cx),
                cx,
            )
            .into_any_element(),
        ];
        for (line, hit) in group.hits.iter().take(shown).enumerate() {
            let at = hit.moment();
            content.push(
                self.row_line(
                    ElementId::NamedInteger(
                        SharedString::from(format!("{id}-line-{index}")),
                        line as u64,
                    ),
                    Some(meeting_kind(hit, &lb)),
                    &hit.snippet,
                    hit.is_semantic,
                    1,
                    style,
                    move |this, _, cx| this.open_meeting(meeting_id, at, cx),
                    cx,
                )
                .into_any_element(),
            );
        }
        let hidden = group.hits.len() - shown;
        if hidden > 0 {
            content.push(self.more_link(id, index, hidden, key, cx));
        }
        MatchRow {
            element: row_shell(
                index,
                selected,
                style,
                source_tile(Ico::AudioLines, px(44.), px(30.), &lb),
                content,
                &lb,
            )
            .into_any_element(),
        }
    }

    fn screen_row(
        &self,
        screen: &ScreenResult,
        index: usize,
        style: ListStyle,
        selected: Option<usize>,
        id: &'static str,
        cx: &mut Context<Self>,
    ) -> MatchRow {
        let lb = cx.lb().clone();
        let moment = screen.moment.clone();
        let title = if moment.window_title.trim().is_empty() {
            moment.app.clone()
        } else {
            moment.window_title.clone()
        };
        let when = model::moment_label(moment.ts, chrono::Local::now());
        let trailing = if moment.window_title.trim().is_empty() {
            when
        } else {
            format!("{} · {when}", moment.app)
        };
        let snippet = result_row::without_title_echo(&screen.snippet, &title)
            .unwrap_or_else(|| screen.snippet.clone());
        let data = self.data.clone();
        let opened = moment.clone();
        let title_row = self.row_title(
            ElementId::NamedInteger(SharedString::from(format!("{id}-title")), index as u64),
            title,
            Some(trailing),
            move |this, cx| super::open_screen_moment(&this.data, &opened, cx),
            cx,
        );
        let pinned = self.pins.iter().any(|pin| pin.id == moment.id);
        let pin_moment = moment.clone();
        let title_row = title_row.child(
            Button::new(ElementId::NamedInteger(
                SharedString::from(format!("{id}-pin")),
                moment.id as u64,
            ))
            .ghost()
            .xsmall()
            .icon(ui::icon(
                Ico::Pin,
                px(12.),
                if pinned {
                    lb.accent_text
                } else {
                    lb.text_secondary
                },
            ))
            .tooltip(if pinned {
                lokalbot_i18n::tr("Remove this screen from the question")
            } else {
                lokalbot_i18n::tr("Attach this screen to the question")
            })
            .on_click(cx.listener(move |this, _, _, cx| {
                cx.stop_propagation();
                this.toggle_pin(&pin_moment, cx);
            })),
        );
        let line_moment = moment.clone();
        let line = self.row_line(
            ElementId::NamedInteger(SharedString::from(format!("{id}-line-{index}")), 0),
            None,
            &snippet,
            screen.is_semantic,
            2,
            style,
            move |_, _, cx| super::open_screen_moment(&data, &line_moment, cx),
            cx,
        );
        let image = self.thumbnails.image(&moment, cx, |page| &page.thumbnails);
        MatchRow {
            element: row_shell(
                index,
                selected,
                style,
                screen_thumbnail::tile(image, &moment, px(44.), px(30.), cx)
                    .rounded(px(5.))
                    .into_any_element(),
                vec![title_row.into_any_element(), line.into_any_element()],
                &lb,
            )
            .into_any_element(),
        }
    }

    fn file_row(
        &self,
        hit: &lokalbot_core::files::FileHit,
        index: usize,
        style: ListStyle,
        selected: Option<usize>,
        id: &'static str,
        cx: &mut Context<Self>,
    ) -> MatchRow {
        let lb = cx.lb().clone();
        let opened = hit.clone();
        let line_opened = hit.clone();
        let snippet = hit
            .excerpt
            .clone()
            .unwrap_or_else(|| model::day_label(hit.date(), chrono::Local::now()));
        let title = self.row_title(
            ElementId::NamedInteger(SharedString::from(format!("{id}-title")), index as u64),
            hit.name(),
            Some(hit.folder()),
            move |_, _| search::open_file(&opened),
            cx,
        );
        let line = self.row_line(
            ElementId::NamedInteger(SharedString::from(format!("{id}-line-{index}")), 0),
            Some(
                div()
                    .truncate()
                    .child(search::file_kind_label(hit))
                    .into_any_element(),
            ),
            &snippet,
            hit.is_semantic,
            2,
            style,
            move |_, _, _| search::open_file(&line_opened),
            cx,
        );
        let (menu_open, revealed) = (hit.clone(), hit.path.clone());
        let element = row_shell(
            index,
            selected,
            style,
            div()
                .w(px(44.))
                .h(px(30.))
                .flex()
                .items_center()
                .justify_center()
                .child(ui::icon(
                    search::file_icon(hit.kind),
                    px(24.),
                    lb.text_secondary,
                ))
                .into_any_element(),
            vec![title.into_any_element(), line.into_any_element()],
            &lb,
        )
        .id(ElementId::NamedInteger(
            SharedString::from(format!("{id}-file")),
            index as u64,
        ))
        .context_menu(move |menu, _, _| {
            let opened = menu_open.clone();
            let revealed = revealed.clone();
            menu.item(
                PopupMenuItem::new(lokalbot_i18n::tr("Open"))
                    .on_click(move |_, _, _| search::open_file(&opened)),
            )
            .item(
                PopupMenuItem::new(lokalbot_i18n::tr("Show in folder"))
                    .on_click(move |_, _, _| reveal(&revealed)),
            )
        });
        MatchRow {
            element: element.into_any_element(),
        }
    }

    /// A note a coding agent saved for itself: its title, the agent and
    /// project, then the matched words. It opens the agent's own file.
    fn note_row(
        &self,
        hit: &lokalbot_core::agent_notes::NoteHit,
        index: usize,
        style: ListStyle,
        selected: Option<usize>,
        id: &'static str,
        cx: &mut Context<Self>,
    ) -> MatchRow {
        let lb = cx.lb().clone();
        let opened = hit.clone();
        let line_opened = hit.clone();
        let title = self.row_title(
            ElementId::NamedInteger(SharedString::from(format!("{id}-title")), index as u64),
            hit.title.clone(),
            Some(hit.source_label()),
            move |_, _| search::open_note(&opened),
            cx,
        );
        let line = self.row_line(
            ElementId::NamedInteger(SharedString::from(format!("{id}-line-{index}")), 0),
            Some(
                div()
                    .child(model::day_label(hit.modified, chrono::Local::now()))
                    .into_any_element(),
            ),
            &search::note_snippet(hit),
            false,
            2,
            style,
            move |_, _, _| search::open_note(&line_opened),
            cx,
        );
        let (menu_open, revealed) = (hit.clone(), hit.path.clone());
        let element = row_shell(
            index,
            selected,
            style,
            source_tile(Ico::FileText, px(44.), px(30.), &lb),
            vec![title.into_any_element(), line.into_any_element()],
            &lb,
        )
        .id(ElementId::NamedInteger(
            SharedString::from(format!("{id}-note")),
            index as u64,
        ))
        .context_menu(move |menu, _, _| {
            let opened = menu_open.clone();
            let revealed = revealed.clone();
            menu.item(
                PopupMenuItem::new(lokalbot_i18n::tr("Open"))
                    .on_click(move |_, _, _| search::open_note(&opened)),
            )
            .item(
                PopupMenuItem::new(lokalbot_i18n::tr("Show in folder"))
                    .on_click(move |_, _, _| reveal(&revealed)),
            )
        });
        MatchRow {
            element: element.into_any_element(),
        }
    }

    // ------------------------------------------------------------- anatomy

    /// A source's name, which opens it, and its date or place on the right.
    fn row_title(
        &self,
        id: ElementId,
        title: String,
        trailing: Option<String>,
        open: impl Fn(&mut Self, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        h_flex()
            .w_full()
            .gap(px(8.))
            .items_center()
            .child(
                div()
                    .id(id)
                    .min_w_0()
                    .truncate()
                    .cursor_pointer()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .hover(|style| style.underline())
                    .child(title)
                    .on_click(cx.listener(move |this, _, _, cx| open(this, cx))),
            )
            .child(div().flex_1().min_w(px(8.)))
            .when_some(trailing, |this, trailing| {
                this.child(
                    div()
                        .flex_none()
                        .max_w(px(280.))
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .child(trailing),
                )
            })
    }

    /// One matching line: what kind it is, then the words, matched ones bold.
    #[allow(clippy::too_many_arguments)]
    fn row_line(
        &self,
        id: ElementId,
        kind: Option<AnyElement>,
        snippet: &str,
        is_semantic: bool,
        lines: usize,
        style: ListStyle,
        open: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> gpui_kit::Stateful<Div> {
        let lb = cx.lb().clone();
        h_flex()
            .id(id)
            .w_full()
            .gap(px(10.))
            .items_start()
            .ml(px(-6.))
            .px(px(6.))
            .py(px(3.))
            .rounded(px(6.))
            .cursor_pointer()
            .hover(move |style| style.bg(lb.hover))
            .when_some(kind, |this, kind| {
                this.child(
                    div()
                        .flex_none()
                        .when(style == ListStyle::Card, |this| this.w(px(KIND_COLUMN)))
                        .overflow_hidden()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .child(kind),
                )
            })
            .when(is_semantic, |this| {
                this.child(
                    div()
                        .id("ask-match-meaning")
                        .flex_none()
                        .pt(px(4.))
                        .child(ui::icon(Ico::Sparkle, px(10.), lb.text_secondary))
                        .tooltip(|window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(lokalbot_i18n::tr(
                                "Related by meaning",
                            ))
                            .build(window, cx)
                        }),
                )
            })
            .child({
                // Matched words keep their own direction in a right-to-left
                // interface, so a cut line loses its end, not its start.
                let plain = model::plain_snippet(snippet);
                div()
                    .flex_1()
                    .min_w_0()
                    .text_align(crate::i18n::content_alignment(&plain))
                    .text_size(ty::BODY)
                    .line_height(px(20.))
                    .text_color(lb.supporting)
                    .line_clamp(lines)
                    .child(result_row::highlighted(&plain, lb.text))
            })
            .on_click(cx.listener(move |this, _, window, cx| open(this, window, cx)))
    }

    fn more_link(
        &self,
        id: &'static str,
        index: usize,
        hidden: usize,
        key: String,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let page = cx.entity();
        div()
            .pt(px(1.))
            .text_size(ty::SECONDARY)
            .child(ui::link(
                ElementId::NamedInteger(SharedString::from(format!("{id}-more")), index as u64),
                lokalbot_i18n::interface_directional(&lokalbot_i18n::mac(
                    "Show %lld more",
                    &[&lokalbot_i18n::number(hidden)],
                )),
                move |_, cx| {
                    let key = key.clone();
                    page.update(cx, |page, cx| {
                        page.results.expanded.insert(key);
                        cx.notify();
                    })
                },
                cx,
            ))
            .into_any_element()
    }
}

/// "3 in 1 meeting", or how many sources matched.
pub(super) fn count_label(found: &search::Results) -> String {
    model::matches_count_label(
        found.meetings.len(),
        found.meetings.iter().map(|group| group.hits.len()).sum(),
        found.screens.len() + found.files.len() + found.notes.len(),
        found.truncated,
    )
}

/// Every row's frame: a leading tile or picture, then the title and lines.
fn row_shell(
    index: usize,
    selected: Option<usize>,
    style: ListStyle,
    lead: AnyElement,
    content: Vec<AnyElement>,
    lb: &crate::theme::Palette,
) -> Div {
    let is_selected = selected == Some(index);
    h_flex()
        .w_full()
        .gap(px(12.))
        .items_start()
        .px(px(if style == ListStyle::Card { 14. } else { 10. }))
        .py(px(if style == ListStyle::Card { 12. } else { 9. }))
        .rounded(metric::ROW_RADIUS)
        .when(is_selected, |this| this.bg(lb.accent_wash))
        .child(div().flex_none().w(px(44.)).h(px(30.)).child(lead))
        .child(v_flex().flex_1().min_w_0().gap(px(3.)).children(content))
}

/// `AskSourceTile`: the small rounded tile that leads a row here and in an
/// answer's sources list.
pub(super) fn source_tile(
    icon: Ico,
    width: gpui_kit::Pixels,
    height: gpui_kit::Pixels,
    lb: &crate::theme::Palette,
) -> AnyElement {
    div()
        .flex_none()
        .w(width)
        .h(height)
        .rounded(px(6.))
        .bg(lb.group_fill)
        .border_1()
        .border_color(lb.group_stroke)
        .flex()
        .items_center()
        .justify_center()
        .child(ui::icon(icon, height * 0.45, lb.accent_text))
        .into_any_element()
}

fn inset_divider(lb: &crate::theme::Palette) -> Div {
    div().ml(px(14.)).h(px(1.)).bg(lb.separator)
}

/// What a meeting line is: "▶ 0:35 · Other speaker", "Summary", "Outcome".
fn meeting_kind(hit: &Hit, lb: &crate::theme::Palette) -> AnyElement {
    match hit.kind {
        DocKind::Segment => {
            let speaker = hit
                .speaker
                .as_deref()
                .map(search::speaker_label)
                .filter(|s| !s.is_empty());
            h_flex()
                .gap(px(4.))
                .items_center()
                .overflow_hidden()
                .child(
                    h_flex()
                        .flex_none()
                        .gap(px(3.))
                        .items_center()
                        .text_color(lb.accent_text)
                        .child(ui::icon(Ico::Play, px(7.), lb.accent_text))
                        .child(ui::action_row::short_stamp(hit.start.unwrap_or(0.))),
                )
                .when_some(speaker, |this, speaker| {
                    this.child(div().min_w_0().truncate().child(format!("· {speaker}")))
                })
                .into_any_element()
        }
        _ => div().truncate().child(hit.kind_label()).into_any_element(),
    }
}

fn reveal(path: &str) {
    if let Err(err) = lokalbot_platform::opener::reveal_in_file_manager(std::path::Path::new(path))
    {
        log::warn!("could not show a file: {err:#}");
    }
}
