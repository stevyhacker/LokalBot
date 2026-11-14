//! Building blocks of a list beside a page, shared by People and Projects
//! (`WorkspacePageBlocks.swift`): a page with a side column of reference
//! blocks, a page section's heading, a side block, a decision with its
//! meeting, a meeting title row and a small label chip.

use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Div, ElementId, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, ScrollHandle, SharedString, StatefulInteractiveElement as _, Styled as _,
    Window, div, px,
};

use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

/// Between a page's sections, and between the side column's blocks
/// (`WorkspaceMetric.sectionGap`).
pub const SECTION_GAP: f32 = 22.;
/// The side column's width at the standard text size
/// (`PageSideColumnLayout.sideWidth`).
pub const WIDTH: f32 = 252.;
/// The page keeps at least this much beside the column.
pub const PAGE_MINIMUM_WIDTH: f32 = 388.;

/// The side column's width; it grows with the text size.
pub fn width(text_scale: f32) -> f32 {
    (WIDTH * text_scale.max(1.)).round()
}

/// Where the side column goes (`PageSideColumnLayout`): beside the page
/// while the pane has room for both, under it otherwise.
pub fn beside(pane_width: f32, text_scale: f32) -> bool {
    pane_width >= ((PAGE_MINIMUM_WIDTH + WIDTH) * text_scale.max(1.)).round()
}

/// How wide the page's own column is (`PageWithSideColumn`), for content
/// that picks its layout by width: beside the side column it takes what the
/// column leaves, under it the page keeps to the reading width.
pub fn main_width(pane_width: f32, text_scale: f32, has_side: bool) -> f32 {
    let padding = f32::from(metric::DETAIL_PADDING);
    if has_side && beside(pane_width, text_scale) {
        (pane_width - width(text_scale) - padding - 32.).max(0.)
    } else {
        let reading = f32::from(metric::READING_MAX_WIDTH) + padding * 2.;
        (pane_width.min(reading) - padding * 2.).max(0.)
    }
}

/// A scrolling page with a side column of reference blocks at its trailing
/// edge, divided by a line that runs the pane's height (`PageWithSideColumn`).
/// A narrow pane puts the blocks under the page. With nothing for the page
/// itself, the blocks are the page.
pub fn page(
    id: impl Into<ElementId>,
    main: Vec<AnyElement>,
    side: Vec<AnyElement>,
    pane_width: f32,
    text_scale: f32,
    scroll: &ScrollHandle,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let has_main = !main.is_empty();
    let has_side = !side.is_empty();
    let beside = has_main && has_side && beside(pane_width, text_scale);
    let gap = px(SECTION_GAP + 4.);
    let content: AnyElement = if beside {
        let rtl = lokalbot_i18n::current().rtl;
        h_flex()
            .w_full()
            .min_h_full()
            .items_stretch()
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(gap)
                    .when(!rtl, |this| this.pl(metric::DETAIL_PADDING).pr(px(32.)))
                    .when(rtl, |this| this.pr(metric::DETAIL_PADDING).pl(px(32.)))
                    .py(px(24.))
                    .children(main),
            )
            .child(
                v_flex()
                    .flex_none()
                    .w(px(width(text_scale)))
                    .gap(px(SECTION_GAP))
                    .px(px(20.))
                    .py(px(24.))
                    .border_color(lb.separator)
                    .when(!rtl, |this| this.border_l_1())
                    .when(rtl, |this| this.border_r_1())
                    .children(side),
            )
            .into_any_element()
    } else {
        v_flex()
            .w_full()
            .max_w(metric::READING_MAX_WIDTH + metric::DETAIL_PADDING * 2.)
            .gap(gap)
            .px(metric::DETAIL_PADDING)
            .py(px(24.))
            .children(main)
            .children(side)
            .into_any_element()
    };
    div()
        .id(id)
        .size_full()
        .overflow_y_scroll()
        .track_scroll(scroll)
        .child(content)
        .into_any_element()
}

/// A page section's heading (`PageSectionHeading`): its name, how many rows
/// follow, and one link.
pub fn section_heading(
    title: impl Into<SharedString>,
    count: Option<usize>,
    trailing: Option<AnyElement>,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_baseline()
        .child(
            div()
                .flex_none()
                .text_size(ty::SECTION)
                .font_weight(FontWeight::BOLD)
                .text_color(lb.text)
                .child(title.into()),
        )
        .when_some(count, |this, count| {
            this.child(
                div()
                    .flex_none()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::number(count)),
            )
        })
        .when_some(trailing, |this, trailing| {
            this.child(div().min_w_0().child(trailing))
        })
}

/// One block of the side column (`SideColumnBlock`): a quiet heading over a
/// few links or rows.
pub fn side_block(title: impl Into<SharedString>, count: Option<usize>, cx: &App) -> Div {
    let lb = cx.lb();
    v_flex().w_full().gap(px(6.)).child(
        h_flex()
            .gap(px(6.))
            .items_baseline()
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.supporting)
                    .child(title.into()),
            )
            .when_some(count, |this, count| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(lokalbot_i18n::number(count)),
                )
            }),
    )
}

/// A capsule label (`LabelChip`): amber for what needs the reader, quiet
/// otherwise. A list's badge is the small size.
pub fn label_chip(text: impl Into<SharedString>, attention: bool, small: bool, cx: &App) -> Div {
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

/// A decision with the meeting it was made in at the trailing edge
/// (`PageDecisionRow`). People names the meeting quietly; Projects, whose
/// decisions come from many meetings, shows it with its date as an accent
/// link (`accent`). `description` is the meeting with its date, on hover.
pub fn decision_row(
    id: impl Into<ElementId>,
    text: impl Into<SharedString>,
    link: impl Into<SharedString>,
    description: impl Into<SharedString>,
    accent: bool,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let description: SharedString = description.into();
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_start()
        .py(px(4.))
        .child(div().flex_none().w(px(16.)).pt(px(2.)).child(ui::icon(
            Ico::CircleCheck,
            px(14.),
            lb.success_text,
        )))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::BODY)
                .text_color(lb.text)
                .child(ui::text::paragraph(text.into())),
        )
        .child(
            div()
                .id(id)
                .flex_none()
                .max_w(px(if accent { 260. } else { 200. }))
                .truncate()
                .cursor_pointer()
                .text_size(ty::SECONDARY)
                .text_color(if accent {
                    lb.accent_text
                } else {
                    lb.supporting
                })
                .hover(|s| s.underline())
                .child(link.into())
                .tooltip(move |window, cx| Tooltip::new(description.clone()).build(window, cx))
                .on_click(move |_, window, cx| on_click(window, cx)),
        )
        .into_any_element()
}

/// Whether a meeting row opens something or folds a series.
#[derive(Clone, Copy, PartialEq)]
pub enum Disclosure {
    None,
    Collapsed,
    Expanded,
}

/// A meeting title in the side column with its detail under it and a
/// chevron that turns down while a series is open (`MeetingLinkRow`).
pub fn meeting_link_row(
    id: SharedString,
    title: String,
    detail: Option<String>,
    disclosure: Disclosure,
    indented: bool,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let chevron = match disclosure {
        Disclosure::Expanded => Ico::ChevronDown,
        _ if lokalbot_i18n::current().rtl => Ico::ChevronLeft,
        _ => Ico::ChevronRight,
    };
    let chevron_color = if disclosure == Disclosure::None {
        lb.text_tertiary
    } else {
        lb.text_secondary
    };
    h_flex()
        .id(id)
        .w_full()
        .gap(px(8.))
        .items_center()
        .mx(px(-6.))
        .px(px(6.))
        .py(px(5.))
        .when(indented, |this| this.pl(px(18.)))
        .rounded(px(6.))
        .cursor_pointer()
        .hover(|s| s.bg(lb.hover))
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(1.))
                .child(
                    div()
                        .truncate()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(title),
                )
                .when_some(detail, |this, detail| {
                    this.child(
                        div()
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(detail),
                    )
                }),
        )
        .child(
            div()
                .flex_none()
                .child(ui::icon(chevron, px(11.), chevron_color)),
        )
        .on_click(move |_, window, cx| on_click(window, cx))
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_side_column_moves_under_the_page_when_the_pane_is_narrow() {
        assert!(beside(640., 1.0));
        assert!(!beside(639., 1.0));
        assert!(!beside(700., 1.2), "larger text needs a wider pane");
        assert_eq!(width(1.2), 302.);
        assert_eq!(width(0.93), 252., "never narrower than standard");
    }

    #[test]
    fn the_page_column_is_what_the_side_column_leaves_or_the_reading_width() {
        // Beside: 1000 − 252 − 28 − 32.
        assert_eq!(main_width(1000., 1.0, true), 688.);
        // Under: the reading width, never wider.
        assert_eq!(main_width(1000., 1.0, false), 720.);
        assert_eq!(main_width(600., 1.0, true), 544.);
    }
}
