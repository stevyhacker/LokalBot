//! The list column (`PeopleListColumn`): the search field with "Where People
//! comes from" as its header, then people under Coming up, Last 2 weeks and
//! Earlier. Hidden entries are restored from its foot.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::ContextMenuExt as _;
use gpui_kit::component::popover::Popover;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, Div, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};

use super::model::{self, Badge, Row};
use super::{PROVENANCE, PeoplePage};
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, profile};

/// A capsule label (`LabelChip`): amber for what needs the reader, quiet
/// otherwise. The list's badge is the small size.
pub(super) fn label_chip(
    text: impl Into<SharedString>,
    attention: bool,
    small: bool,
    cx: &gpui_kit::App,
) -> Div {
    let lb = cx.lb();
    let (fill, color) = if attention {
        (lb.attention.opacity(0.12), lb.attention_text)
    } else {
        (lb.quiet_fill, lb.supporting)
    };
    div()
        .flex_none()
        .rounded_full()
        .bg(fill)
        .text_color(color)
        .when(small, |this| {
            this.px(px(7.))
                .py(px(1.))
                .text_size(ty::CAPTION)
                .font_weight(FontWeight::MEDIUM)
        })
        .when(!small, |this| {
            this.px(px(9.))
                .py(px(3.))
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
        })
        .child(text.into())
}

impl PeoplePage {
    pub(super) fn render_list(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let content = self.list_content();
        let selected_id = self.selected_person().map(|p| p.id.clone());
        let mut rows: Vec<AnyElement> = Vec::new();
        for section in &content.sections {
            // A heading row, as in the Meetings list: it scrolls with its
            // people.
            rows.push(
                div()
                    .id(SharedString::from(format!(
                        "people-group-{:?}",
                        section.group
                    )))
                    .px(px(18.))
                    .pt(px(12.))
                    .pb(px(4.))
                    .text_size(ty::CAPTION)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.supporting)
                    .child(section.group.title())
                    .into_any_element(),
            );
            for row in &section.rows {
                rows.push(self.render_row(
                    row,
                    selected_id.as_deref() == Some(row.id.as_str()),
                    cx,
                ));
            }
        }
        let overlay: Option<SharedString> = if !self.loaded {
            Some(lokalbot_i18n::tr("Loading…").into())
        } else if self.people.is_empty() {
            Some(
                lokalbot_i18n::tr(
                    "People appear after meetings with calendar attendees, named speakers, or named action owners.",
                )
                .into(),
            )
        } else if content.is_empty() {
            Some(lokalbot_i18n::tr("No matches").into())
        } else {
            None
        };
        // Over the list where people would be (`overlay`), above the
        // restore link.
        if let Some(text) = overlay {
            rows.push(
                div()
                    .w_full()
                    .p(px(24.))
                    .text_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(text))
                    .into_any_element(),
            );
        }
        if !self.curation.hidden.is_empty() {
            let mut names: Vec<String> = self
                .curation
                .hidden
                .iter()
                .map(|h| h.name.clone())
                .collect();
            names.sort();
            let names: SharedString = names.join(", ").into();
            let page = cx.entity();
            rows.push(
                div()
                    .px(px(18.))
                    .py(px(10.))
                    .child(
                        profile::link(
                            "people-restore-hidden",
                            model::restore_hidden(self.curation.hidden.len()),
                            move |_, cx| page.update(cx, |page, cx| page.restore_hidden(cx)),
                            cx,
                        )
                        .tooltip(move |window, cx| Tooltip::new(names.clone()).build(window, cx)),
                    )
                    .into_any_element(),
            );
        }
        v_flex()
            .size_full()
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .px(px(10.))
                    .pt(px(10.))
                    .pb(px(8.))
                    .child(div().flex_1().min_w_0().child(
                        Input::new(&self.search).cleanable(true).prefix(ui::icon(
                            Ico::Search,
                            px(14.),
                            lb.text_secondary,
                        )),
                    ))
                    .child(
                        Popover::new("people-provenance")
                            .trigger(
                                Button::new("people-info")
                                    .ghost()
                                    .xsmall()
                                    .icon(Icon::new(Ico::Info))
                                    .tooltip(lokalbot_i18n::tr("Where People comes from")),
                            )
                            .content(|_, _, cx| {
                                div()
                                    .w(px(300.))
                                    .text_size(ty::SECONDARY)
                                    .text_color(cx.lb().text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        PROVENANCE,
                                    )))
                            }),
                    ),
            )
            .child(
                div()
                    .id("people-list")
                    .flex_1()
                    .min_h_0()
                    .relative()
                    .overflow_y_scroll()
                    .track_scroll(&self.list_scroll)
                    .pb(px(12.))
                    .children(rows),
            )
    }

    /// One person in the list (`PersonRow`): avatar, name and when, then the
    /// latest or next meeting and which way open work runs.
    fn render_row(&self, row: &Row, selected: bool, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let id = row.id.clone();
        let tint = profile::name_tint(&row.name, cx);
        let page = cx.entity();
        let person = self.people.iter().find(|p| p.id == row.id).cloned();
        let merges = person
            .as_ref()
            .map(|p| self.curation.merges_into(p))
            .unwrap_or_default();
        let badge = row
            .badge
            .map(|badge: Badge| label_chip(badge.text(), badge.needs_attention(), true, cx));
        h_flex()
            .id(SharedString::from(format!("person-{}", row.id)))
            .mx(px(8.))
            .px(px(10.))
            .py(px(6.))
            .gap(px(10.))
            .items_center()
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.sidebar_selection))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(ui::avatar(model::initials(&row.name), tint, px(28.)))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(row.name.clone()),
                            )
                            .when(!row.when.is_empty(), |this| {
                                this.child(
                                    div()
                                        .flex_none()
                                        .text_size(ty::CAPTION)
                                        .text_color(lb.supporting)
                                        .child(row.when.clone()),
                                )
                            }),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(row.detail.clone()),
                            )
                            .children(badge),
                    ),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.select(Some(id.clone()));
                cx.notify();
            }))
            .context_menu(move |menu, window, cx| match person.clone() {
                Some(person) => {
                    Self::person_menu_items(&page, merges.clone(), person, menu, window, cx)
                }
                None => menu,
            })
            .into_any_element()
    }
}
