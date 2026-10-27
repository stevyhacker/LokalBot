// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

//! From a suggestion and the field it is for to the ghost window's frame and
//! lines (`CotypingOverlayController.show`): inline right after the caret in
//! the field's own font when the caret is exact and ends its line, else a
//! pill under the caret's line. Geometry is the platform crate's pure math;
//! this adds GPUI text measurement and colors.

use gpui_kit::{App, Hsla, SharedString, font, px};
use lokalbot_platform::autocomplete::geometry::{
    self, EMPHASIS_OPACITY, FontMetrics, InlineInput, InlineLayout, Paint, RenderMode,
};
use lokalbot_platform::autocomplete::{FieldSnapshot, Rect, policy};

use super::overlay::{Chrome, GhostContent, GhostLine};

/// Room around the glyphs so antialiased edges are never clipped.
const INLINE_PADDING: f32 = 2.0;
const PILL_PADDING: (f32, f32) = (8.0, 4.0);
/// The pill's font, 11–17 pt on macOS.
const PILL_FONT_PX: (f32, f32) = (14.5, 22.5);

/// Colors and the fallback font, from the app's theme.
#[derive(Clone, Debug)]
pub struct Appearance {
    pub dark: bool,
    pub ui_font: SharedString,
    pub pill_background: Hsla,
    pub pill_border: Hsla,
    pub pill_text: Hsla,
    pub pill_emphasis: Hsla,
}

/// Where the ghost goes and what it draws.
#[derive(Clone, Debug)]
pub struct Placement {
    /// Screen pixels.
    pub frame: Rect,
    pub content: GhostContent,
    /// The part of the suggestion on screen: an inline ghost leaves out what
    /// has no room, and an accept never takes words the user could not see.
    pub shown: String,
    pub mode: RenderMode,
}

/// Lays out `text` for `field`. `caret` overrides the field's caret, for a
/// ghost moved ahead of the app after an accept. `None` when it has no
/// place on screen that covers no text; the suggestion is then dropped.
#[allow(clippy::too_many_arguments)]
pub fn place(
    text: &str,
    emphasis: &str,
    field: &FieldSnapshot,
    caret: Rect,
    screen: Option<Rect>,
    scale: f32,
    sampled_luminance: Option<f32>,
    appearance: &Appearance,
    cx: &App,
) -> Option<Placement> {
    if text.is_empty() || !caret.is_finite() {
        return None;
    }
    let scale = scale.max(0.5);
    let logical = |r: Rect| Rect::new(r.x / scale, r.y / scale, r.width / scale, r.height / scale);
    let caret_l = logical(caret);
    let field_l = field.field_frame.map(logical);
    let screen_l = screen.map(logical);
    let style = field.style.as_ref();
    let family: SharedString = style
        .and_then(|s| s.font_family.clone())
        .map(SharedString::from)
        .unwrap_or_else(|| appearance.ui_font.clone());
    let mode = geometry::render_mode(
        field.caret_exact,
        policy::caret_at_end_of_line(&field.after),
    );
    let emphasis_chars = geometry::display_text(emphasis).chars().count();
    let placement = match mode {
        RenderMode::Inline => {
            let size = geometry::ghost_font_px(
                style
                    .and_then(|s| s.font_points)
                    .map(geometry::points_to_px),
                caret_l.height,
                field.caret_exact,
            );
            let measure = measurer(cx, &family, size);
            let preceding_line = field.before.rsplit('\n').next().unwrap_or("");
            let input = InlineInput {
                caret: caret_l,
                field: field_l,
                preceding_line,
                screen: screen_l,
                right_to_left: lokalbot_ai::autocomplete::is_right_to_left(&field.before),
                lines_below_free: field.after.trim().is_empty(),
                metrics: FontMetrics {
                    line_height: size * 1.25,
                },
            };
            let make = |candidate: &str| InlineLayout::make(candidate, &input, None, &measure);
            let (shown, layout) = InlineLayout::longest_drawable(text, true, &make)?;
            let drawn = layout
                .bounds()?
                .inset(-INLINE_PADDING, -INLINE_PADDING)
                .integral();
            // Room past the measured end, so a glyph wider than measured (or
            // rounding at another scale) is never cut off; the window is
            // transparent there.
            let slack = (size * 0.5).ceil().max(2.0);
            let bounds = Rect::new(drawn.x, drawn.y, drawn.width + slack, drawn.height);
            let paint = geometry::ghost_paint(style, appearance.dark, sampled_luminance);
            let lines = layout
                .lines
                .iter()
                .map(|line| GhostLine {
                    text: line.text.clone(),
                    offset: line.offset,
                    x: line.x - bounds.x,
                    y: line.y - bounds.y,
                })
                .collect();
            Placement {
                frame: bounds,
                content: GhostContent {
                    lines,
                    font_family: family,
                    font_size: size,
                    line_height: caret_l.height.max(1.0),
                    color: hsla_of(paint),
                    emphasis_color: hsla_of(Paint {
                        alpha: EMPHASIS_OPACITY,
                        ..paint
                    }),
                    emphasis_chars,
                    chrome: None,
                },
                shown,
                mode,
            }
        }
        RenderMode::Pill => {
            let reported = style
                .and_then(|s| s.font_points)
                .map(geometry::points_to_px);
            let size = geometry::ghost_font_px(reported, caret_l.height, field.caret_exact)
                .clamp(PILL_FONT_PX.0, PILL_FONT_PX.1);
            let family = appearance.ui_font.clone();
            let measure = measurer(cx, &family, size);
            let lines = geometry::pill_lines(
                text.trim_start(),
                geometry::pill_text_width(screen_l),
                geometry::PILL_MAX_LINES,
                &measure,
            );
            if lines.is_empty() {
                return None;
            }
            let line_height = (size * 1.3).ceil();
            let widest = lines.iter().map(|l| measure(l)).fold(0.0, f32::max);
            let width = widest.ceil() + PILL_PADDING.0 * 2.0;
            let height = line_height * lines.len() as f32 + PILL_PADDING.1 * 2.0;
            let frame =
                geometry::pill_frame(caret_l, field.caret_exact, field_l, width, height, screen_l)?
                    .integral();
            let mut offset = 0;
            let ghost_lines = lines
                .iter()
                .enumerate()
                .map(|(index, line)| {
                    let ghost = GhostLine {
                        text: line.clone(),
                        offset,
                        x: PILL_PADDING.0,
                        y: PILL_PADDING.1 + line_height * index as f32,
                    };
                    offset += line.chars().count() + 1;
                    ghost
                })
                .collect();
            let leading = text.chars().take_while(|c| c.is_whitespace()).count();
            Placement {
                frame,
                content: GhostContent {
                    lines: ghost_lines,
                    font_family: family,
                    font_size: size,
                    line_height,
                    color: appearance.pill_text,
                    emphasis_color: appearance.pill_emphasis,
                    emphasis_chars: emphasis_chars.saturating_sub(leading),
                    chrome: Some(Chrome {
                        background: appearance.pill_background,
                        border: appearance.pill_border,
                    }),
                },
                // A pill shows the whole suggestion, or what fits of it.
                shown: text.to_string(),
                mode,
            }
        }
    };
    Some(Placement {
        frame: Rect::new(
            placement.frame.x * scale,
            placement.frame.y * scale,
            placement.frame.width * scale,
            placement.frame.height * scale,
        ),
        ..placement
    })
}

/// A string's width in `family` at `size` logical pixels, from GPUI's text
/// system: the font's advances (so no layout cache grows with every
/// suggestion), and for a character the font lacks (an emoji, another
/// script) the width it is drawn at from a fallback font.
pub fn measurer(cx: &App, family: &SharedString, size: f32) -> impl Fn(&str) -> f32 + use<> {
    let text_system = cx.text_system().clone();
    let font_id = text_system.resolve_font(&font(family.clone()));
    move |text: &str| {
        text.chars()
            .map(|c| match text_system.advance(font_id, px(size), c) {
                Ok(advance) => f32::from(advance.width),
                Err(_) => f32::from(text_system.layout_width(font_id, px(size), c)),
            })
            .sum()
    }
}

fn hsla_of(paint: Paint) -> Hsla {
    gpui_kit::Rgba {
        r: f32::from(paint.rgb.r) / 255.0,
        g: f32::from(paint.rgb.g) / 255.0,
        b: f32::from(paint.rgb.b) / 255.0,
        a: paint.alpha,
    }
    .into()
}
