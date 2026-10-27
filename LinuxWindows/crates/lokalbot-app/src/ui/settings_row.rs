//! Grouped settings forms (`SettingsLabel`, `SettingsHelp`, `SettingsDetails`
//! and the grouped `Form` sections of `SettingsView.swift`).
//!
//! A section is a bold title over a rounded panel; each row puts the label and
//! its help text on the left and the control on the right.

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Div, ElementId, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, Stateful, StatefulInteractiveElement as _, Styled as _,
    Window, div, px,
};

use super::{Ico, icon};
use crate::theme::{LbThemeExt as _, metric, ty};

/// One section: optional title, then rows in a grouped panel.
pub fn section(title: Option<SharedString>, rows: Vec<AnyElement>, cx: &App) -> Div {
    let lb = cx.lb();
    let count = rows.len();
    let mut panel = v_flex()
        .w_full()
        .rounded(metric::GROUP_RADIUS)
        .bg(lb.group_fill)
        .border_1()
        .border_color(lb.group_stroke);
    for (index, row) in rows.into_iter().enumerate() {
        panel = panel.child(row);
        if index + 1 < count {
            panel = panel.child(div().mx(px(14.)).h(px(1.)).bg(lb.separator));
        }
    }
    v_flex()
        .w_full()
        .gap(px(8.))
        .when_some(title, |this, title| {
            this.child(
                div()
                    .px(px(4.))
                    .text_size(ty::SECTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(title),
            )
        })
        .child(panel)
}

/// Label with help text underneath (`SettingsLabel`).
pub fn label(title: impl Into<SharedString>, help: Option<SharedString>, cx: &App) -> Div {
    let lb = cx.lb();
    v_flex()
        .gap(px(3.))
        .min_w_0()
        .child(
            div()
                .text_size(ty::BODY)
                .text_color(lb.text)
                .child(super::text::paragraph(title)),
        )
        .when_some(help, |this, help| {
            this.child(
                div()
                    .text_size(ty::SECONDARY)
                    .line_height(px(18.))
                    .text_color(lb.text_secondary)
                    .child(super::text::paragraph(help)),
            )
        })
}

/// A row with the label on the left and `control` on the right.
pub fn row(
    id: impl Into<ElementId>,
    title: impl Into<SharedString>,
    help: Option<SharedString>,
    control: impl IntoElement,
    highlighted: bool,
    cx: &App,
) -> Stateful<Div> {
    // A wide control drops under its label instead of squeezing it.
    row_frame(id, highlighted, cx).child(
        h_flex()
            .w_full()
            .flex_wrap()
            .gap_x(px(16.))
            .gap_y(px(8.))
            .items_center()
            .child(label(title, help, cx).flex_1().min_w(px(220.)))
            .child(div().flex_none().max_w_full().child(control)),
    )
}

/// A row whose content sits under the label, full width (editors, lists).
pub fn stacked_row(
    id: impl Into<ElementId>,
    title: impl Into<SharedString>,
    help: Option<SharedString>,
    content: impl IntoElement,
    highlighted: bool,
    cx: &App,
) -> Stateful<Div> {
    row_frame(id, highlighted, cx).child(
        v_flex()
            .w_full()
            .gap(px(8.))
            .child(label(title, help, cx))
            .child(content),
    )
}

/// A row of free content (help paragraphs, button rows).
pub fn content_row(
    id: impl Into<ElementId>,
    content: impl IntoElement,
    highlighted: bool,
    cx: &App,
) -> Stateful<Div> {
    row_frame(id, highlighted, cx).child(content)
}

fn row_frame(id: impl Into<ElementId>, highlighted: bool, cx: &App) -> Stateful<Div> {
    let lb = cx.lb();
    div()
        .id(id)
        .w_full()
        .px(px(14.))
        .py(px(10.))
        .rounded(metric::GROUP_RADIUS)
        .when(highlighted, |this| this.bg(lb.accent_fill.opacity(0.14)))
}

/// Quiet explanatory text (`SettingsHelp`).
pub fn help(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_size(ty::SECONDARY)
        .line_height(px(18.))
        .text_color(cx.lb().text_secondary)
        .child(super::text::paragraph(text))
}

/// Secondary value text on the right of a row ("0.1.0", "Granted").
pub fn value(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_size(ty::BODY)
        .text_color(cx.lb().text_secondary)
        .child(text.into())
}

/// A teal switch bound to a boolean.
pub fn switch(
    id: impl Into<ElementId>,
    checked: bool,
    on_change: impl Fn(bool, &mut Window, &mut App) + 'static,
) -> Switch {
    Switch::new(id)
        .checked(checked)
        .on_click(move |checked, window, cx| on_change(*checked, window, cx))
}

/// A segmented control (`.pickerStyle(.segmented)`): a quiet track with the
/// selected segment raised, in both light and dark windows.
pub fn segmented(
    id: impl Into<ElementId>,
    labels: &[&'static str],
    selected: usize,
    on_select: impl Fn(usize, &mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let lb = cx.lb();
    let raised = if lb.dark {
        gpui_kit::white().opacity(0.18)
    } else {
        lb.elevated
    };
    let on_select = std::rc::Rc::new(on_select);
    h_flex()
        .id(id)
        .flex_none()
        .p(px(2.))
        .gap(px(2.))
        .rounded(px(8.))
        .bg(lb.chip_fill)
        .children(labels.iter().enumerate().map(|(index, label)| {
            let on_select = on_select.clone();
            let is_selected = index == selected;
            div()
                .id(("segment", index))
                .h(px(24.))
                .px(px(10.))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(6.))
                .text_size(ty::SECONDARY)
                .text_color(lb.text)
                .whitespace_nowrap()
                .when(is_selected, |this| {
                    this.bg(raised).shadow_sm().font_weight(FontWeight::MEDIUM)
                })
                .when(!is_selected, |this| {
                    this.cursor_pointer().hover(|s| s.bg(lb.hover))
                })
                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(label)))
                .on_click(move |_, window, cx| on_select(index, window, cx))
        }))
}

/// A pop-up picker: the current choice with a caret, options with a check.
pub fn picker(
    id: impl Into<ElementId>,
    current: impl Into<SharedString>,
    options: Vec<(SharedString, bool)>,
    on_select: impl Fn(usize, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let on_select = std::rc::Rc::new(on_select);
    Button::new(id)
        .outline()
        .small()
        .label(current)
        .dropdown_caret(true)
        .dropdown_menu(move |mut menu, _, _| {
            // The language list is taller than onboarding's window. GPUI
            // only enables scrolling automatically for with_menu_items().
            menu = menu.scrollable(options.len() > 12);
            for (index, (label, checked)) in options.iter().enumerate() {
                let on_select = on_select.clone();
                menu = menu.item(
                    PopupMenuItem::new(label.clone())
                        .checked(*checked)
                        .on_click(move |_, window, cx| on_select(index, window, cx)),
                );
            }
            menu
        })
}

/// "value [−|+]" stepper (`Stepper`).
pub fn stepper(
    id: &'static str,
    text: impl Into<SharedString>,
    can_decrease: bool,
    can_increase: bool,
    on_step: impl Fn(i32, &mut Window, &mut App) + 'static,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    let on_step = std::rc::Rc::new(on_step);
    let cell = |suffix: &str, glyph: Ico, step: i32, enabled: bool| {
        let on_step = on_step.clone();
        let hover = lb.hover;
        div()
            .id(SharedString::from(format!("{id}-{suffix}")))
            .w(px(26.))
            .h_full()
            .flex()
            .items_center()
            .justify_center()
            .when(enabled, |this| {
                this.cursor_pointer().hover(move |s| s.bg(hover))
            })
            .when(!enabled, |this| this.opacity(0.35))
            .child(icon(glyph, px(12.), lb.text))
            .on_click(move |_, window, cx| {
                if enabled {
                    on_step(step, window, cx)
                }
            })
    };
    let text: SharedString = text.into();
    h_flex()
        .gap(px(8.))
        .items_center()
        .when(!text.is_empty(), |this| {
            this.child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(text),
            )
        })
        .child(
            h_flex()
                .h(px(24.))
                .rounded(px(6.))
                .border_1()
                .border_color(lb.separator.opacity(1.6))
                .bg(lb.elevated)
                .overflow_hidden()
                .child(cell("down", Ico::Minus, -1, can_decrease))
                .child(div().w(px(1.)).h_full().bg(lb.separator))
                .child(cell("up", Ico::Plus, 1, can_increase)),
        )
}

/// A collapsed "How this works" disclosure (`SettingsDetails`).
pub fn details(
    id: impl Into<ElementId>,
    title: impl Into<SharedString>,
    text: impl Into<SharedString>,
    expanded: bool,
    on_toggle: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    v_flex()
        .gap(px(6.))
        .child(
            h_flex()
                .id(id)
                .gap(px(6.))
                .items_center()
                .cursor_pointer()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::MEDIUM)
                .text_color(lb.text_secondary)
                .hover(|s| s.text_color(lb.text))
                .child(icon(
                    if expanded {
                        Ico::ChevronDown
                    } else {
                        Ico::ChevronRight
                    },
                    px(12.),
                    lb.text_secondary,
                ))
                .child(title.into())
                .on_click(move |_, window, cx| on_toggle(window, cx)),
        )
        .when(expanded, |this| this.child(help(text, cx).pl(px(18.))))
}

/// A teal text button ("Choose…", "Manage in Models…" as a link).
pub fn link_button(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let color = cx.lb().accent_text;
    div()
        .id(id)
        .cursor_pointer()
        .text_size(ty::BODY)
        .text_color(color)
        .hover(|s| s.underline())
        .child(label.into())
        .on_click(move |_, window, cx| on_click(window, cx))
}
