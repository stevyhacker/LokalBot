//! The list column (`ActionsFilterBar`, `ActionsList`, `ActionsStaleBar`):
//! Open / Deferred / Done, the Filter menu with a removable chip per active
//! choice and the search field; the list under its headings; and the Review
//! bar for open actions nobody has mentioned in three weeks.

use std::rc::Rc;

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    Pixels, SharedString, StatefulInteractiveElement as _, Styled as _, Window, canvas, div, list,
    px,
};
use lokalbot_core::ActionStatus;

use super::model::{
    self, BarLayout, ChipKind, DueFilter, Grouping, ListContent, ListFilter, STATUSES, state_key,
};
use super::{ActionsPage, Entry};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::action_row::{self, ListRowStyle};
use crate::ui::{self, Ico, segmented_tabs};

/// The search field's width beside the other controls.
const SEARCH_WIDTH: f32 = 230.;
/// A chip's padding and close mark around its words.
const CHIP_CHROME: f32 = 32.;
/// The Filter button's icon, caret and padding around its word.
const FILTER_CHROME: f32 = 60.;

/// The widest of `texts` as drawn at `size`, for controls sized by their words.
pub(super) fn text_width(texts: &[&str], size: Pixels, window: &mut Window) -> Pixels {
    let style = window.text_style();
    texts
        .iter()
        .map(|text| {
            let text: SharedString = text.to_string().into();
            let run = style.to_run(text.len());
            window
                .text_system()
                .shape_line(text, size, &[run], None)
                .width()
        })
        .fold(px(0.), Pixels::max)
}

impl ActionsPage {
    pub(super) fn render_list_column(
        &mut self,
        content: &Rc<ListContent>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let current = self.selection.current(&content.order);
        self.current_ids = current.into_iter().collect();
        let shows_stale_bar = self.filter.status == ActionStatus::Open
            && !self.filter.stale_only
            && content.stale_count > 0;
        let body: AnyElement = if !self.is_loaded {
            div().flex_1().into_any_element()
        } else if content.is_empty() {
            self.render_empty(cx)
        } else {
            div()
                .id("actions-list")
                .relative()
                .flex_1()
                .min_h_0()
                .track_focus(&self.list_focus)
                .on_key_down(cx.listener(Self::on_list_key))
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
        let bounds = self.list_bounds.clone();
        let measure = canvas(
            move |b, window, _| {
                if bounds.get().map(|old| old.size) != Some(b.size) {
                    bounds.set(Some(b));
                    window.request_animation_frame();
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();
        v_flex()
            .relative()
            .size_full()
            .child(measure)
            .child(self.render_filter_bar(content, window, cx))
            .child(ui::divider(cx))
            .child(body)
            .when(shows_stale_bar, |this| {
                this.child(ui::divider(cx))
                    .child(self.render_stale_bar(content.stale_count, cx))
            })
            .into_any_element()
    }

    // ------------------------------------------------------------ controls

    fn render_filter_bar(
        &self,
        content: &ListContent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let keys = STATUSES.map(state_key);
        let words: Vec<&str> = keys.iter().map(|k| lokalbot_i18n::tr(k)).collect();
        // Each segment fits the longest status in the interface language.
        let segment =
            px((f32::from(text_width(&words, ty::SECONDARY, window)) + 24.).clamp(76., 160.));
        let selected = STATUSES
            .iter()
            .position(|s| *s == self.filter.status)
            .unwrap_or(0);
        let on_status = cx.listener(|this, ix: &usize, _, cx| {
            let status = STATUSES[*ix];
            this.update_filter(|filter| filter.show(status), cx);
        });
        let status = segmented_tabs::segmented_tabs(
            "actions-status",
            &keys,
            selected,
            segment,
            move |ix, window, cx| on_status(&ix, window, cx),
            cx,
        );
        let chip_list = self.filter.chips(&self.links);
        let chip_widths: Vec<f32> = chip_list
            .iter()
            .map(|chip| f32::from(text_width(&[&chip.label], ty::SECONDARY, window)) + CHIP_CHROME)
            .collect();
        let chips = chip_list
            .into_iter()
            .enumerate()
            .map(|(ix, chip)| self.chip(ix, chip.kind, chip.label, cx).into_any_element())
            .collect::<Vec<_>>();
        // One row when it fits; more chips than the row holds go to a row of
        // their own, and in a narrow list so does the search field
        // (`ViewThatFits`).
        let width = self
            .list_bounds
            .get()
            .map_or(f32::INFINITY, |b| f32::from(b.size.width));
        let filter_width = f32::from(text_width(
            &[lokalbot_i18n::tr("Filter")],
            ty::SECONDARY,
            window,
        )) + FILTER_CHROME;
        let layout = model::filter_bar_layout(
            width,
            f32::from(segmented_tabs::width(STATUSES.len(), segment)),
            filter_width,
            &chip_widths,
            SEARCH_WIDTH,
        );
        let search = |full: bool| {
            div()
                .flex_none()
                .when(full, |this| this.w_full())
                .when(!full, |this| this.w(px(SEARCH_WIDTH)))
                .child(
                    Input::new(&self.search)
                        .small()
                        .cleanable(true)
                        .prefix(ui::icon(Ico::Search, px(14.), lb.text_secondary)),
                )
        };
        let mut first = h_flex()
            .w_full()
            .items_center()
            .gap(px(8.))
            .child(status)
            .child(self.filter_menu(content, cx));
        let mut chips = Some(chips).filter(|c| !c.is_empty());
        if layout == BarLayout::OneRow {
            first = first.children(chips.take().unwrap_or_default());
        }
        if layout != BarLayout::SearchBelow {
            first = first.child(div().flex_1()).child(search(false));
        }
        v_flex()
            .w_full()
            .gap(px(8.))
            .px(px(16.))
            .py(px(8.))
            .min_h(px(44.))
            .justify_center()
            .child(first)
            .children(chips.map(|chips| h_flex().w_full().flex_wrap().gap(px(6.)).children(chips)))
            .when(layout == BarLayout::SearchBelow, |this| {
                this.child(search(true))
            })
    }

    /// One active Filter menu choice; clicking it removes the choice.
    fn chip(
        &self,
        ix: usize,
        kind: ChipKind,
        label: String,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        h_flex()
            .id(("actions-chip", ix))
            .flex_none()
            .gap(px(5.))
            .items_center()
            .pl(px(9.))
            .pr(px(8.))
            .py(px(3.))
            .rounded_full()
            .bg(lb.accent_wash)
            .text_size(ty::SECONDARY)
            .font_weight(FontWeight::MEDIUM)
            .text_color(lb.accent_text)
            .cursor_pointer()
            .child(div().child(label))
            .child(ui::icon(Ico::Close, px(10.), lb.accent_text))
            .tooltip(|window, cx| {
                Tooltip::new(lokalbot_i18n::tr("Remove filter")).build(window, cx)
            })
            .on_click(cx.listener(move |this, _, _, cx| {
                this.update_filter(|filter| filter.remove(kind), cx)
            }))
    }

    /// The Filter menu: due, person, project, meeting, the stale review and
    /// how the open list is grouped. People and Projects only know open and
    /// deferred work, and grouping and the stale review are for open work.
    fn filter_menu(
        &self,
        content: &ListContent,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let page = cx.entity().downgrade();
        let filter = self.filter.clone();
        let links = self.links.clone();
        let meetings = content.meeting_titles.clone();
        Button::new("actions-filter")
            .outline()
            .small()
            .icon(Icon::new(Ico::ListFilter))
            .label(lokalbot_i18n::tr("Filter"))
            .dropdown_caret(true)
            .dropdown_menu(move |menu, window, cx| {
                // A menu entry that changes the filter.
                let set = |change: Rc<dyn Fn(&mut ListFilter)>| {
                    let page = page.clone();
                    move |_: &gpui_kit::ClickEvent, _: &mut Window, cx: &mut gpui_kit::App| {
                        let change = change.clone();
                        let _ = page.update(cx, |this, cx| this.update_filter(|f| change(f), cx));
                    }
                };
                let mut menu = menu.label(lokalbot_i18n::tr("Due"));
                for (label, due) in [
                    (lokalbot_i18n::tr("Any date"), DueFilter::Any),
                    (lokalbot_i18n::tr("Overdue"), DueFilter::Overdue),
                    (lokalbot_i18n::tr("Has a date"), DueFilter::Dated),
                    (lokalbot_i18n::tr("No date"), DueFilter::Undated),
                ] {
                    menu = menu.item(
                        PopupMenuItem::new(label)
                            .checked(filter.due == due)
                            .on_click(set(Rc::new(move |f| f.due = due))),
                    );
                }
                menu = menu.separator();
                let open_work_only = filter.status == ActionStatus::Done;
                if !links.people.is_empty() {
                    let label = lokalbot_i18n::tr("Person");
                    menu = if open_work_only {
                        menu.item(PopupMenuItem::new(label).disabled(true))
                    } else {
                        let choices: Vec<(Option<String>, String)> =
                            std::iter::once((None, lokalbot_i18n::tr("Anyone").to_string()))
                                .chain(
                                    links
                                        .people
                                        .iter()
                                        .map(|p| (Some(p.id.clone()), p.name.clone())),
                                )
                                .collect();
                        let current = filter.person_id.clone();
                        let page = page.clone();
                        menu.submenu(label, window, cx, move |menu, _, _| {
                            choice_items(menu, &choices, &current, &page, |f, id| f.person_id = id)
                        })
                    };
                }
                if !links.projects.is_empty() {
                    let label = lokalbot_i18n::tr("Project");
                    menu = if open_work_only {
                        menu.item(PopupMenuItem::new(label).disabled(true))
                    } else {
                        let choices: Vec<(Option<String>, String)> =
                            std::iter::once((None, lokalbot_i18n::tr("Any project").to_string()))
                                .chain(
                                    links
                                        .projects
                                        .iter()
                                        .map(|p| (Some(p.id.clone()), p.name.clone())),
                                )
                                .collect();
                        let current = filter.project_id.clone();
                        let page = page.clone();
                        menu.submenu(label, window, cx, move |menu, _, _| {
                            choice_items(menu, &choices, &current, &page, |f, id| f.project_id = id)
                        })
                    };
                }
                if !meetings.is_empty() {
                    let choices: Vec<(Option<String>, String)> =
                        std::iter::once((None, lokalbot_i18n::tr("Any meeting").to_string()))
                            .chain(meetings.iter().map(|t| (Some(t.clone()), t.clone())))
                            .collect();
                    let current = filter.meeting_title.clone();
                    let page = page.clone();
                    menu = menu.submenu(
                        lokalbot_i18n::tr("Meeting"),
                        window,
                        cx,
                        move |menu, _, _| {
                            choice_items(menu, &choices, &current, &page, |f, title| {
                                f.meeting_title = title
                            })
                        },
                    );
                }
                let stale = !filter.stale_only;
                menu = menu
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Not mentioned in 3 weeks"))
                            .checked(filter.stale_only)
                            .disabled(filter.status != ActionStatus::Open)
                            .on_click(set(Rc::new(move |f| f.stale_only = stale))),
                    )
                    .separator()
                    .label(lokalbot_i18n::tr("Group by"));
                for (label, grouping) in [
                    (lokalbot_i18n::tr("Due date"), Grouping::Due),
                    (lokalbot_i18n::tr("Meeting"), Grouping::Meeting),
                    (lokalbot_i18n::tr("None"), Grouping::None),
                ] {
                    menu = menu.item(
                        PopupMenuItem::new(label)
                            .checked(filter.grouping == grouping)
                            .disabled(filter.status != ActionStatus::Open)
                            .on_click(set(Rc::new(move |f| {
                                f.grouping = grouping;
                                f.stale_only = false;
                            }))),
                    );
                }
                menu
            })
    }

    // ---------------------------------------------------------------- list

    fn render_empty(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let page = cx.entity().downgrade();
        v_flex()
            .id("actions-empty")
            .flex_1()
            .items_center()
            .gap(px(8.))
            .px(px(20.))
            .pt(px(64.))
            .child(
                div()
                    .max_w(px(420.))
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .text_center()
                    .child(ui::text::paragraph(model::empty_text(&self.filter))),
            )
            .when(self.filter.narrows_list(), |this| {
                this.child(
                    ui::link(
                        "actions-clear-filters",
                        lokalbot_i18n::tr("Clear filters"),
                        move |window, cx| {
                            let _ = page.update(cx, |this, cx| this.clear_filters(window, cx));
                        },
                        cx,
                    )
                    .text_size(ty::BODY),
                )
            })
            .into_any_element()
    }

    pub(super) fn render_entry(
        &mut self,
        ix: usize,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let (Some(entry), Some((_, content))) = (self.entries.get(ix).copied(), &self.content)
        else {
            return div().into_any_element();
        };
        let content = content.clone();
        match entry {
            Entry::Gap(height) => div().h(px(height)).into_any_element(),
            Entry::Heading(section) => {
                let Some(section) = content.sections.get(section) else {
                    return div().into_any_element();
                };
                h_flex()
                    .px(px(20.))
                    .pt(px(12.))
                    .pb(px(5.))
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .font_weight(FontWeight::BOLD)
                            .text_color(if section.is_late {
                                lb.overdue_text
                            } else {
                                lb.text
                            })
                            .child(section.title.clone().unwrap_or_default()),
                    )
                    .child(
                        div()
                            .flex_none()
                            .text_color(lb.text_secondary)
                            .child(lokalbot_i18n::number(section.rows.len())),
                    )
                    .into_any_element()
            }
            Entry::Row(section, row) => {
                let Some(row) = content.sections.get(section).and_then(|s| s.rows.get(row)) else {
                    return div().into_any_element();
                };
                let Some(thread) = self.loaded.threads.get(row.thread).cloned() else {
                    return div().into_any_element();
                };
                let (on_click, on_status, on_edit, on_not_mine) = self.row_handlers(&thread, cx);
                let style = ListRowStyle {
                    source: row.source.clone(),
                    due: row.due.clone().map(|due| (due.text, due.tone)),
                    selected: self.current_ids.contains(&row.id),
                    batch: self.current_ids.len() > 1,
                    hint: self
                        .loaded
                        .hints
                        .get(&thread.id)
                        .map(model::completion_hint),
                    on_click,
                    on_status,
                    on_edit,
                    on_not_mine,
                };
                div()
                    .px(px(10.))
                    .child(action_row::list_row(
                        SharedString::from(format!("actions-row-{ix}")),
                        &thread,
                        style,
                        &self.data,
                        cx,
                    ))
                    .into_any_element()
            }
        }
    }

    /// "8 open actions haven’t been mentioned in 3 weeks. Review": the quiet
    /// bar under the list that replaces the "Still open?" question on rows.
    fn render_stale_bar(&self, count: usize, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let page = cx.entity().downgrade();
        h_flex()
            .id("actions-stale-bar")
            .flex_none()
            .w_full()
            .min_h(px(34.))
            .px(px(16.))
            .py(px(6.))
            .gap(px(8.))
            .items_center()
            .text_size(ty::SECONDARY)
            .child(ui::icon(Ico::Clock, px(14.), lb.attention_text))
            .child(
                div()
                    .min_w_0()
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(model::stale_summary(count))),
            )
            .child(
                ui::link(
                    "actions-stale-review",
                    lokalbot_i18n::tr("Review"),
                    move |_, cx| {
                        let _ = page.update(cx, |this, cx| {
                            this.update_filter(|filter| filter.stale_only = true, cx)
                        });
                    },
                    cx,
                )
                .flex_none(),
            )
            .child(div().flex_1())
    }
}

/// "Anyone", then each choice, the current one checked; picking one sets the
/// filter through `apply`.
fn choice_items(
    menu: PopupMenu,
    choices: &[(Option<String>, String)],
    current: &Option<String>,
    page: &gpui_kit::WeakEntity<ActionsPage>,
    apply: fn(&mut ListFilter, Option<String>),
) -> PopupMenu {
    let mut menu = menu.scrollable(true).max_h(px(420.));
    for (value, label) in choices {
        let page = page.clone();
        let value = value.clone();
        menu = menu.item(
            PopupMenuItem::new(label.clone())
                .checked(*current == value)
                .on_click(move |_, _, cx| {
                    let value = value.clone();
                    let _ = page.update(cx, |this, cx| {
                        this.update_filter(|filter| apply(filter, value), cx)
                    });
                }),
        );
    }
    menu
}
