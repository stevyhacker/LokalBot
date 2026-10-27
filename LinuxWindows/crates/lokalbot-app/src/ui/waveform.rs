//! The audio overview in a meeting's audio bar (`WaveformView.swift`): bars in
//! a quiet grey, the played part in teal, a 2px playhead, and a time bubble
//! while hovering. Clicking or dragging seeks.

use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;

use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, Bounds, Corners, Div, ElementId, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    MouseButton, ParentElement as _, PathBuilder, Pixels, Point, Stateful,
    StatefulInteractiveElement as _, Styled as _, Window, canvas, div, point, px, quad, size,
    transparent_black,
};

use crate::theme::{LbThemeExt as _, ty};

/// Distance between bar starts; bars are 2px wide.
const BAR_STEP: f32 = 4.;
pub const HEIGHT: Pixels = px(40.);

#[derive(Clone, Copy)]
struct Colors {
    bars: Hsla,
    played: Hsla,
    playhead: Hsla,
    hover: Hsla,
}

/// Fraction of `bounds` under `position`, clamped to 0…1.
fn fraction(bounds: Bounds<Pixels>, position: Point<Pixels>) -> f32 {
    let width = f32::from(bounds.size.width).max(1.);
    ((f32::from(position.x - bounds.origin.x)) / width).clamp(0., 1.)
}

/// Max-pools `peaks` into `count` bars.
pub fn resample(peaks: &[f32], count: usize) -> Vec<f32> {
    if peaks.is_empty() || count == 0 {
        return Vec::new();
    }
    (0..count)
        .map(|ix| {
            let start = ix * peaks.len() / count;
            let end = ((ix + 1) * peaks.len() / count)
                .max(start + 1)
                .min(peaks.len());
            peaks[start..end]
                .iter()
                .copied()
                .fold(0., f32::max)
                .clamp(0., 1.)
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
pub fn waveform(
    id: impl Into<ElementId>,
    peaks: Option<Arc<[f32]>>,
    progress: f32,
    hover: Option<f32>,
    duration: f64,
    on_hover: impl Fn(Option<f32>, &mut Window, &mut App) + 'static,
    on_seek: impl Fn(f32, &mut Window, &mut App) + 'static,
    cx: &App,
) -> Stateful<Div> {
    let lb = cx.lb();
    let colors = Colors {
        bars: lb.text_secondary.opacity(0.5),
        played: lb.accent_text,
        playhead: lb.text,
        hover: lb.text_secondary,
    };
    let bounds_cell = Rc::new(Cell::new(Bounds::default()));
    let on_hover = Rc::new(on_hover);
    let progress = progress.clamp(0., 1.);

    let paint_bounds = bounds_cell.clone();
    let painter = canvas(
        move |bounds, _, _| paint_bounds.set(bounds),
        move |bounds, _, window, _| {
            paint_waveform(bounds, peaks.as_deref(), progress, hover, colors, window)
        },
    )
    .absolute()
    .size_full();

    let on_seek = Rc::new(on_seek);
    let move_bounds = bounds_cell.clone();
    let move_hover = on_hover.clone();
    let move_seek = on_seek.clone();
    let down_bounds = bounds_cell;
    div()
        .id(id)
        .relative()
        .flex_1()
        .min_w(px(80.))
        .h(HEIGHT)
        .child(painter)
        .when_some(hover, |this, hover| {
            let stamp = lokalbot_core::time::stamp(f64::from(hover) * duration);
            this.child(
                div()
                    .absolute()
                    .top(px(-4.))
                    .left(gpui_kit::relative(hover))
                    .ml(px(-28.))
                    .w(px(56.))
                    .flex()
                    .justify_center()
                    .child(
                        div()
                            .px(px(4.))
                            .rounded(px(3.))
                            .bg(lb.elevated)
                            .border_1()
                            .border_color(lb.separator)
                            .text_size(ty::SMALL)
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.text)
                            .child(stamp),
                    ),
            )
        })
        .on_mouse_move(move |event, window, cx| {
            let bounds = move_bounds.get();
            if bounds.contains(&event.position) {
                let at = fraction(bounds, event.position);
                move_hover(Some(at), window, cx);
                if event.pressed_button == Some(MouseButton::Left) {
                    move_seek(at, window, cx);
                }
            }
        })
        .on_hover(move |hovered, window, cx| {
            if !*hovered {
                on_hover(None, window, cx);
            }
        })
        .on_mouse_down(MouseButton::Left, move |event, window, cx| {
            let bounds = down_bounds.get();
            on_seek(fraction(bounds, event.position), window, cx);
        })
}

fn paint_waveform(
    bounds: Bounds<Pixels>,
    peaks: Option<&[f32]>,
    progress: f32,
    hover: Option<f32>,
    colors: Colors,
    window: &mut Window,
) {
    let width = f32::from(bounds.size.width);
    let height = f32::from(bounds.size.height);
    let center = height / 2.;
    let cut = width * progress;
    let origin = bounds.origin;
    let rect = |x: f32, y: f32, w: f32, h: f32| {
        Bounds::new(origin + point(px(x), px(y)), size(px(w), px(h)))
    };
    let fill = |window: &mut Window, b: Bounds<Pixels>, radius: f32, color: Hsla| {
        window.paint_quad(quad(
            b,
            Corners::all(px(radius)),
            color,
            px(0.),
            transparent_black(),
            Default::default(),
        ));
    };

    let bars = peaks
        .map(|peaks| resample(peaks, (width / BAR_STEP).floor().max(0.) as usize))
        .unwrap_or_default();
    if bars.is_empty() {
        // Flat line until peaks are available, as on macOS.
        fill(window, rect(0., center - 1., width, 2.), 1., colors.bars);
        if cut > 0. {
            fill(window, rect(0., center - 1., cut, 2.), 1., colors.played);
        }
    } else {
        for (ix, peak) in bars.iter().enumerate() {
            let x = ix as f32 * BAR_STEP;
            let h = (peak * (height - 10.)).max(2.);
            let color = if x + 1. <= cut {
                colors.played
            } else {
                colors.bars
            };
            fill(window, rect(x, center - h / 2., 2., h), 1., color);
        }
    }
    let playhead_x = (cut - 1.).clamp(0., (width - 2.).max(0.));
    fill(
        window,
        rect(playhead_x, 3., 2., height - 6.),
        1.,
        colors.playhead,
    );
    if let Some(hover) = hover {
        let x = (width * hover).clamp(0., (width - 1.).max(0.));
        fill(window, rect(x, 10., 1., height - 15.), 0., colors.hover);
    }
}

/// A filled play triangle (Lucide's play symbol is outlined).
pub fn play_glyph(glyph: Pixels, color: Hsla) -> impl IntoElement {
    canvas(
        |_, _, _| {},
        move |bounds, _, window, _| {
            let (w, h) = (f32::from(bounds.size.width), f32::from(bounds.size.height));
            let at = |x: f32, y: f32| bounds.origin + point(px(w * x), px(h * y));
            let mut path = PathBuilder::fill();
            path.move_to(at(0.24, 0.14));
            path.line_to(at(0.90, 0.5));
            path.line_to(at(0.24, 0.86));
            path.close();
            if let Ok(path) = path.build() {
                window.paint_path(path, color);
            }
        },
    )
    .size(glyph)
}

#[cfg(test)]
mod tests {
    use super::resample;

    #[test]
    fn resampling_keeps_the_loudest_peak_per_bar() {
        assert_eq!(resample(&[0.1, 0.9, 0.2, 0.4], 2), vec![0.9, 0.4]);
        assert_eq!(resample(&[0.5], 3), vec![0.5, 0.5, 0.5]);
        assert!(resample(&[], 3).is_empty());
    }
}
