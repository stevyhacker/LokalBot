use std::ops::Range;

use gpui_kit::component::resizable::{h_resizable, resizable_panel};
use gpui_kit::{App, Entity, IntoElement, ParentElement as _, Pixels, px};

use crate::state::AppData;

pub const LIST_RANGE: Range<f32> = 240.0..340.0;
pub const DETAILS_RANGE: Range<f32> = 280.0..440.0;

fn saved_width(
    key: &str,
    default: Pixels,
    range: &Range<f32>,
    data: &Entity<AppData>,
    cx: &App,
) -> Pixels {
    let width = data
        .read(cx)
        .settings
        .pane_widths
        .get(key)
        .copied()
        .map_or(f32::from(default), |w| w as f32);
    px(width.clamp(range.start, range.end))
}

fn save_width(key: &'static str, width: Pixels, data: &Entity<AppData>, cx: &mut App) {
    let width = f64::from(f32::from(width));
    data.update(cx, |data, cx| {
        if data.settings.pane_widths.get(key).copied() != Some(width) {
            data.update_settings(
                |settings| {
                    settings.pane_widths.insert(key.to_string(), width);
                },
                cx,
            );
        }
    });
}

pub fn leading(
    key: &'static str,
    default: Pixels,
    range: Range<f32>,
    list: impl IntoElement,
    detail: impl IntoElement,
    data: &Entity<AppData>,
    cx: &App,
) -> impl IntoElement {
    let width = saved_width(key, default, &range, data, cx);
    let save = data.clone();
    h_resizable(key)
        .on_resize(move |state, _, cx| {
            if let Some(width) = state.read(cx).sizes().first().copied() {
                save_width(key, width, &save, cx);
            }
        })
        .child(
            resizable_panel()
                .size(width)
                .size_range(px(range.start)..px(range.end))
                .child(list.into_any_element()),
        )
        .child(resizable_panel().child(detail.into_any_element()))
}

pub fn trailing(
    key: &'static str,
    default: Pixels,
    range: Range<f32>,
    content: impl IntoElement,
    pane: impl IntoElement,
    data: &Entity<AppData>,
    cx: &App,
) -> impl IntoElement {
    let width = saved_width(key, default, &range, data, cx);
    let save = data.clone();
    h_resizable(key)
        .on_resize(move |state, _, cx| {
            if let Some(width) = state.read(cx).sizes().last().copied() {
                save_width(key, width, &save, cx);
            }
        })
        .child(resizable_panel().child(content.into_any_element()))
        .child(
            resizable_panel()
                .size(width)
                .size_range(px(range.start)..px(range.end))
                .child(pane.into_any_element()),
        )
}

#[allow(clippy::too_many_arguments)]
pub fn trailing_pane(
    key: &'static str,
    default: Pixels,
    range: Range<f32>,
    content_minimum: Pixels,
    content: impl IntoElement,
    pane: impl IntoElement,
    data: &Entity<AppData>,
    cx: &App,
) -> impl IntoElement {
    let width = saved_width(key, default, &range, data, cx);
    let save = data.clone();
    h_resizable(key)
        .on_resize(move |state, _, cx| {
            if let Some(width) = state.read(cx).sizes().last().copied() {
                save_width(key, width, &save, cx);
            }
        })
        .child(
            resizable_panel()
                .size_range(content_minimum..Pixels::MAX)
                .child(content.into_any_element()),
        )
        .child(
            resizable_panel()
                .size(width)
                .size_range(px(range.start)..px(range.end))
                .child(pane.into_any_element()),
        )
}
