//! LokalBot's building blocks, matching `DesignSystem.swift`:
//! grouped surfaces, section cards, chips, status dots, icon tiles, evidence
//! pills and the proportion bar. GPUI Kit supplies inputs, buttons, switches
//! and menus; these helpers cover what it does not.
//!
//! Page code should compose these instead of restyling raw `div`s so every
//! page keeps the same radii, paddings and colors.

pub mod action_row;
pub mod answer_text;
pub mod citations;
pub mod controls;
pub mod glyphs;
pub mod markdown_view;
pub mod profile;
pub mod result_row;
pub mod rule_list;
pub mod segmented_tabs;
pub mod settings_row;
pub mod shortcut_field;
pub mod text;
pub mod waveform;

use crate::i18n::h_flex;
pub use gpui_kit::assets::IconName as Ico;
use gpui_kit::component::{Icon, v_flex};
use gpui_kit::{
    App, Div, ElementId, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, Pixels, SharedString, Stateful, StatefulInteractiveElement as _,
    Styled as _, Window, div, px, relative,
};

use crate::theme::{LbThemeExt as _, metric, ty};

/// A Lucide icon at `size`, tinted `color`.
pub fn icon(name: Ico, size: Pixels, color: Hsla) -> Icon {
    Icon::new(name).size(size).text_color(color)
}

/// The rounded well behind Recap, Action Items, Decisions and settings groups.
pub fn grouped_surface(cx: &App) -> Div {
    let lb = cx.lb();
    div()
        .rounded(metric::GROUP_RADIUS)
        .bg(lb.group_fill)
        .border_1()
        .border_color(lb.group_stroke)
}

/// A grouped surface with the standard 14px padding.
pub fn panel(cx: &App) -> Div {
    grouped_surface(cx).p(metric::PANEL_PADDING)
}

/// A tinted status surface: 10% fill, 28% stroke (recording, attention).
pub fn status_surface(tint: Hsla, cx: &App) -> Div {
    let lb = cx.lb();
    div()
        .rounded(metric::GROUP_RADIUS)
        .bg(lb.status_fill(tint))
        .border_1()
        .border_color(lb.status_stroke(tint))
}

/// `WorkspaceSection`: a bold title, an 8px gap, then a padded panel.
pub fn section(title: impl Into<SharedString>, content: impl IntoElement, cx: &App) -> Div {
    v_flex()
        .gap(metric::HEADER_TO_CONTENT)
        .child(section_title(title, cx))
        .child(panel(cx).child(content))
}

/// Bold section heading (13pt headline on macOS).
pub fn section_title(title: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .text_size(ty::SECTION)
        .font_weight(FontWeight::BOLD)
        .text_color(cx.lb().text)
        .child(title.into())
}

/// `StatTile`: icon + bold value + label, in a chip ("3h 50m tracked").
pub fn stat_chip(
    icon_name: Ico,
    value: impl Into<SharedString>,
    label: impl Into<SharedString>,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    h_flex()
        .gap_1p5()
        .items_center()
        .px(px(10.))
        .py(px(5.))
        .rounded_full()
        .bg(lb.chip_fill)
        .text_size(ty::SECONDARY)
        .child(icon(icon_name, px(13.), lb.text_secondary))
        .child(
            div()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text)
                .child(value.into()),
        )
        .child(div().text_color(lb.text_secondary).child(label.into()))
}

/// A filled circle, 8px by default.
pub fn status_dot(color: Hsla, size: Pixels) -> Div {
    div().size(size).flex_none().rounded_full().bg(color)
}

/// Rounded square with a tinted fill and a centered symbol (`IconTile`).
pub fn icon_tile(name: Ico, tint: Hsla, size: Pixels) -> Div {
    div()
        .size(size)
        .flex_none()
        .rounded(size * 0.26)
        .bg(tint.opacity(0.12))
        .flex()
        .items_center()
        .justify_center()
        .child(icon(name, size * 0.5, tint))
}

/// Empty states: a quiet symbol, a title and an explanation, centered.
pub fn empty_state(
    icon_name: Ico,
    title: impl Into<SharedString>,
    message: impl Into<SharedString>,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    v_flex()
        .items_center()
        .justify_center()
        .gap_2()
        .p_8()
        .text_center()
        .child(icon(icon_name, px(30.), lb.text_tertiary))
        .child(
            div()
                .text_size(ty::COLUMN_TITLE)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text)
                .child(title.into()),
        )
        .child(
            div()
                .max_w(px(420.))
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(text::paragraph(message)),
        )
}

/// Hairline separator.
pub fn divider(cx: &App) -> Div {
    div().h(px(1.)).w_full().bg(cx.lb().separator)
}

/// `ProportionBar`: a 10px capsule split by share (at least 1px per segment).
pub fn proportion_bar(segments: &[(Hsla, f32)], cx: &App) -> Div {
    let total: f32 = segments.iter().map(|(_, share)| share.max(0.0)).sum();
    let track = cx.lb().chip_fill;
    h_flex()
        .w_full()
        .h(px(10.))
        .rounded_full()
        .overflow_hidden()
        .bg(track)
        .children(
            segments
                .iter()
                .filter(|(_, share)| *share > 0.0)
                .map(|(color, share)| {
                    let fraction = if total > 0.0 { share / total } else { 0.0 };
                    div()
                        .h_full()
                        .min_w(px(1.))
                        .w(relative(fraction))
                        .bg(*color)
                }),
        )
}

/// A clickable text link in the accent color.
pub fn link(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let color = cx.lb().accent_text;
    div()
        .id(id)
        .cursor_pointer()
        .text_color(color)
        .hover(|style| style.underline())
        .child(label.into())
        .on_click(move |_, window, cx| on_click(window, cx))
}

/// Initials avatar tinted from the speaker palette.
pub fn avatar(initials: impl Into<SharedString>, tint: Hsla, size: Pixels) -> Div {
    div()
        .size(size)
        .flex_none()
        .rounded_full()
        .bg(tint.opacity(0.16))
        .border_1()
        .border_color(tint.opacity(0.28))
        .flex()
        .items_center()
        .justify_center()
        .text_size(size * 0.38)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(tint)
        .child(initials.into())
}
