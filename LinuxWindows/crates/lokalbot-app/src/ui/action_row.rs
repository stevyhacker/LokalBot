//! Action rows shared by Meetings, Today, Timeline and the Actions workspace
//! (`OutcomeActionRow`, `ActionThreadRow` and `EvidencePill` on macOS): an
//! 18px status toggle, the action text, a metadata line and an options menu.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu};
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, ElementId, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, Stateful, StatefulInteractiveElement as _, Styled as _,
    Window, div, px, white,
};
use lokalbot_core::ActionStatus;

use super::{Ico, icon};
use crate::theme::{LbThemeExt as _, metric, ty};

/// The round toggle: open circle, filled teal check when done, minus for a
/// thread whose meetings disagree.
pub fn status_toggle(
    id: impl Into<ElementId>,
    status: ActionStatus,
    mixed: bool,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let lb = cx.lb();
    let size = metric::ACTION_TOGGLE;
    let done = status == ActionStatus::Done && !mixed;
    let tooltip: SharedString = if done {
        lokalbot_i18n::tr("Reopen action").into()
    } else {
        lokalbot_i18n::tr("Mark action done").into()
    };
    let hover_ring = lb.accent_text;
    div()
        .id(id)
        .flex_none()
        .size(size)
        .mt(px(1.))
        .rounded_full()
        .flex()
        .items_center()
        .justify_center()
        .cursor_pointer()
        .when(done, |this| {
            this.bg(lb.accent_fill)
                .child(icon(Ico::Check, px(12.), white()))
        })
        .when(!done, |this| {
            this.border_color(lb.text_secondary)
                .border(px(1.5))
                .hover(move |s| s.border_color(hover_ring))
                .when(mixed, |this| {
                    this.child(
                        div()
                            .w(px(8.))
                            .h(px(1.5))
                            .rounded_full()
                            .bg(lb.text_secondary),
                    )
                })
        })
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// `EvidencePill`: quote bubble + "00:00:26" in teal; the tooltip is the excerpt.
pub fn evidence_pill(
    id: impl Into<ElementId>,
    seconds: f64,
    excerpt: Option<SharedString>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let lb = cx.lb();
    let hover = lb.accent_wash;
    let stamp = lokalbot_core::time::stamp(seconds);
    let tooltip: SharedString = excerpt
        .filter(|e| !e.trim().is_empty())
        .map(|e| SharedString::from(format!("“{}”", e.trim())))
        .unwrap_or_else(|| {
            lokalbot_i18n::format(
                "Jump to evidence at {stamp}",
                &[("stamp", stamp.to_string())],
            )
            .into()
        });
    h_flex()
        .id(id)
        .flex_none()
        .gap(px(5.))
        .items_center()
        .px(px(4.))
        .py(px(1.))
        .rounded(px(5.))
        .cursor_pointer()
        .hover(move |style| style.bg(hover))
        .text_size(ty::SECONDARY)
        .text_color(lb.accent_text)
        .child(icon(Ico::MessageSquareQuote, px(14.), lb.accent_text))
        .child(stamp)
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// Plain metadata text in the row's second line.
pub fn meta_text(text: impl Into<SharedString>, color: gpui_kit::Hsla) -> Div {
    div()
        .flex_none()
        .text_size(ty::SECONDARY)
        .text_color(color)
        .child(text.into())
}

/// A teal metadata link (meeting title, "Mentioned in 3 meetings").
pub fn meta_link(
    id: impl Into<ElementId>,
    text: impl Into<SharedString>,
    leading: Option<Ico>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let color = cx.lb().accent_text;
    h_flex()
        .id(id)
        .min_w_0()
        .gap(px(4.))
        .items_center()
        .text_size(ty::SECONDARY)
        .text_color(color)
        .cursor_pointer()
        .hover(|style| style.underline())
        .when_some(leading, |this, name| this.child(icon(name, px(13.), color)))
        .child(div().min_w_0().truncate().child(text.into()))
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// Compact due chip with a calendar symbol ("by Thursday").
pub fn due_chip(text: impl Into<SharedString>, overdue: bool, cx: &App) -> Div {
    let lb = cx.lb();
    let color = if overdue {
        lb.attention_text
    } else {
        lb.supporting
    };
    h_flex()
        .flex_none()
        .gap(px(4.))
        .items_center()
        .px(px(7.))
        .py(px(1.))
        .rounded_full()
        .bg(lb.chip_fill)
        .text_size(ty::CAPTION)
        .font_weight(FontWeight::MEDIUM)
        .text_color(color)
        .child(icon(Ico::Calendar, px(12.), color))
        .child(text.into())
}

/// The trailing `ellipsis` menu.
pub fn options_menu(
    id: impl Into<ElementId>,
    build: impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static,
) -> impl IntoElement {
    Button::new(id)
        .ghost()
        .small()
        .icon(Ico::Ellipsis)
        .tooltip(lokalbot_i18n::tr("Options"))
        .dropdown_menu(build)
}

/// One row: toggle, text with its metadata line and optional hint, menu.
pub fn action_row(
    toggle: impl IntoElement,
    text: impl Into<SharedString>,
    done: bool,
    meta: Vec<AnyElement>,
    extra: Option<AnyElement>,
    menu: impl IntoElement,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .items_start()
        .gap(px(10.))
        .py(px(10.))
        .child(toggle)
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(4.))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .line_height(px(20.))
                        .text_color(if done { lb.text_secondary } else { lb.text })
                        .when(done, |this| this.line_through())
                        .child(text.into()),
                )
                .when(!meta.is_empty(), |this| {
                    this.child(
                        h_flex()
                            .flex_wrap()
                            .gap_x(px(8.))
                            .gap_y(px(2.))
                            .items_center()
                            .children(meta),
                    )
                })
                .children(extra),
        )
        .child(div().flex_none().mt(px(-2.)).child(menu))
}
