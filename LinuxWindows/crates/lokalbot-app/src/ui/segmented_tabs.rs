//! The meeting workspace tab switcher (`ToolbarTabs` on macOS): equal-width
//! segments in a capsule, with a teal pill behind the selected one.

use std::rc::Rc;

use crate::i18n::h_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, Div, ElementId, FontWeight, InteractiveElement as _, MouseButton, ParentElement as _,
    Pixels, Stateful, StatefulInteractiveElement as _, Styled as _, Window, div, px, white,
};

use crate::theme::{LbThemeExt as _, ty};

/// Height of the whole control, including the 3px track inset.
pub const HEIGHT: Pixels = px(32.);

/// Total width for `count` segments of `segment_width`.
pub fn width(count: usize, segment_width: Pixels) -> Pixels {
    segment_width * count as f32 + px(2.) * count.saturating_sub(1) as f32 + px(8.)
}

pub fn segmented_tabs(
    id: impl Into<ElementId>,
    labels: &[&'static str],
    selected: usize,
    segment_width: Pixels,
    on_select: impl Fn(usize, &mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let lb = cx.lb();
    let on_select = Rc::new(on_select);
    let hover = lb.hover;
    h_flex()
        .id(id)
        .h(HEIGHT)
        .p(px(3.))
        .gap(px(2.))
        .rounded_full()
        .bg(if lb.dark { lb.chip_fill } else { lb.elevated })
        .border_1()
        .border_color(lb.separator)
        .occlude()
        .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
        .children(labels.iter().enumerate().map(|(ix, label)| {
            let on_select = on_select.clone();
            let is_selected = ix == selected;
            div()
                .id(ix)
                .w(segment_width)
                .h_full()
                .flex()
                .items_center()
                .justify_center()
                .rounded_full()
                .text_size(if segment_width < px(76.) {
                    ty::CAPTION
                } else {
                    ty::SECONDARY
                })
                .when(is_selected, |this| {
                    this.bg(lb.accent_fill)
                        .text_color(white())
                        .font_weight(FontWeight::SEMIBOLD)
                })
                .when(!is_selected, |this| {
                    this.text_color(lb.text)
                        .font_weight(FontWeight::MEDIUM)
                        .hover(move |s| s.bg(hover))
                })
                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(label)))
                .on_click(move |_, window, cx| on_select(ix, window, cx))
        }))
}
