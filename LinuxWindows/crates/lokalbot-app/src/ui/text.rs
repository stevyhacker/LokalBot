//! Plain interface paragraphs with logical-order line breaking.
//!
//! GPUI 0.3.9 wraps an already-shaped line in glyph order. That order is not
//! logical text order for Arabic/Urdu and can produce overflowing, reversed
//! rows. Break at Unicode opportunities before shaping each display line.
//! This adapter leaves the source string, input editors and dependency pins
//! intact. Single-line/truncated controls retain GPUI's native text element.

use std::{cell::RefCell, ops::Range, rc::Rc};

use gpui_kit::{
    AnyElement, App, AvailableSpace, Bounds, Element, ElementId, GlobalElementId,
    InspectorElementId, IntoElement, LayoutId, Pixels, ShapedLine, SharedString, StyledText,
    TextAlign, WhiteSpace, Window, px, size,
};
use unicode_segmentation::UnicodeSegmentation as _;

pub fn paragraph(text: impl Into<SharedString>) -> AnyElement {
    Paragraph(text.into()).into_any_element()
}

struct Paragraph(SharedString);

struct Layout {
    native: Option<StyledText>,
    lines: Rc<RefCell<Vec<ShapedLine>>>,
    line_height: Pixels,
    align: TextAlign,
}

impl IntoElement for Paragraph {
    type Element = Self;
    fn into_element(self) -> Self {
        self
    }
}

impl Element for Paragraph {
    type RequestLayoutState = Layout;
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Layout) {
        let style = window.text_style();
        let font_size = style.font_size.to_pixels(window.rem_size());
        let line_height = window.pixel_snap(
            style
                .line_height
                .to_pixels(font_size.into(), window.rem_size()),
        );
        let mut state = Layout {
            native: None,
            lines: Rc::default(),
            line_height,
            align: style.text_align,
        };
        if style.white_space != WhiteSpace::Normal
            || style.text_overflow.is_some()
            || style.line_clamp.is_some()
        {
            let mut native = StyledText::new(self.0.clone());
            let (layout, ()) = native.request_layout(id, inspector_id, window, cx);
            state.native = Some(native);
            return (layout, state);
        }
        let text = self.0.clone();
        let lines = state.lines.clone();
        let layout = window.request_measured_layout(
            Default::default(),
            move |known, available, window, _| {
                let width = known.width.or(match available.width {
                    AvailableSpace::Definite(width) => Some(width),
                    _ => None,
                });
                let mut shaped = Vec::new();
                for source in text.split('\n') {
                    // Preserve the paragraph's base direction when a wrapped row
                    // happens to begin with a Latin product name or a number.
                    // The mark is for shaping only; it is never stored or copied.
                    let direction = if lokalbot_i18n::content_is_rtl(source) {
                        '\u{200f}'
                    } else {
                        '\u{200e}'
                    };
                    let shape = |part: &str| {
                        let display: SharedString = format!("{direction}{part}").into();
                        let run = style.to_run(display.len());
                        window
                            .text_system()
                            .shape_line(display, font_size, &[run], None)
                    };
                    let ranges = wrap_ranges(source, width.map(f32::from), |part| {
                        f32::from(shape(part).width())
                    });
                    shaped.extend(ranges.into_iter().map(|range| shape(&source[range])));
                }
                let natural_width = shaped
                    .iter()
                    .map(|line| line.width())
                    .fold(px(0.), Pixels::max);
                let measured = size(
                    width
                        .map_or(natural_width, |width| width.min(natural_width))
                        .ceil(),
                    line_height * shaped.len(),
                );
                *lines.borrow_mut() = shaped;
                measured
            },
        );
        (layout, state)
    }

    fn prepaint(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut Layout,
        window: &mut Window,
        cx: &mut App,
    ) {
        if let Some(native) = &mut state.native {
            native.prepaint(id, inspector_id, bounds, &mut (), window, cx);
        }
    }

    fn paint(
        &mut self,
        id: Option<&GlobalElementId>,
        inspector_id: Option<&InspectorElementId>,
        bounds: Bounds<Pixels>,
        state: &mut Layout,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        if let Some(native) = &mut state.native {
            native.paint(id, inspector_id, bounds, &mut (), &mut (), window, cx);
            return;
        }
        let mut origin = bounds.origin;
        for line in state.lines.borrow().iter() {
            if let Err(error) = line.paint(
                origin,
                state.line_height,
                state.align,
                Some(bounds.size.width),
                window,
                cx,
            ) {
                log::warn!("Cannot paint interface paragraph: {error}");
            }
            origin.y += state.line_height;
        }
    }
}

/// Contiguous source ranges: no reordering, lost spaces or split graphemes.
// One line covering the whole text is a single range, not the range's items.
#[allow(clippy::single_range_in_vec_init)]
fn wrap_ranges(
    text: &str,
    width: Option<f32>,
    mut measure: impl FnMut(&str) -> f32,
) -> Vec<Range<usize>> {
    let Some(width) = width.filter(|w| w.is_finite() && *w > 0.) else {
        return vec![0..text.len()];
    };
    if text.is_empty() {
        return vec![0..0];
    }
    let breaks: Vec<_> = unicode_linebreak::linebreaks(text)
        .map(|(end, _)| end)
        .collect();
    let mut result = Vec::new();
    let mut start = 0;
    while start < text.len() {
        let mut end = start;
        for next in breaks.iter().copied().filter(|&next| next > start) {
            if measure(&text[start..next]) > width {
                break;
            }
            end = next;
        }
        if end == start {
            // An overlong token still progresses at whole grapheme boundaries.
            for (offset, grapheme) in text[start..].grapheme_indices(true) {
                let next = start + offset + grapheme.len();
                if end > start && measure(&text[start..next]) > width {
                    break;
                }
                end = next;
                if breaks.contains(&end) {
                    break;
                }
            }
        }
        result.push(start..end);
        start = end;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrapped_paragraphs_keep_logical_order_and_every_character() {
        for text in [
            "يؤدي إغلاق النافذة إلى إبقاء LokalBot قيد التشغيل في علبة النظام، ويكون جاهزًا لمتابعة الاجتماعات.",
            "LokalBot کو سسٹم ٹرے میں چلتا رکھیں اور تمام ملاقاتیں یاد رکھیں۔",
            "اضغط Ctrl+Shift+Space للبحث في ذاكرة العمل الخاصة بك.",
            "अपनी कार्य स्मृति खोजें और सहेजी गई मीटिंग के बारे में पूछें।",
            "输入关键字来查找会议和屏幕时刻，或提出问题。",
        ] {
            let lines = wrap_ranges(text, Some(12.), |part| part.graphemes(true).count() as f32);
            assert!(lines.len() > 1);
            assert_eq!(
                lines.iter().map(|r| &text[r.clone()]).collect::<String>(),
                text
            );
            assert!(
                lines
                    .iter()
                    .all(|r| text[r.clone()].graphemes(true).count() <= 12)
            );
        }
    }

    #[test]
    fn narrow_rows_preserve_joined_emoji_and_arabic_combining_marks() {
        let text = "نَصّ👨‍👩‍👧‍👦طويلमीटिंग";
        let lines = wrap_ranges(text, Some(1.), |part| part.graphemes(true).count() as f32);
        assert_eq!(
            lines.iter().map(|r| &text[r.clone()]).collect::<Vec<_>>(),
            text.graphemes(true).collect::<Vec<_>>()
        );
        assert_eq!(wrap_ranges("", Some(1.), |_| 0.), vec![0..0]);
        assert_eq!(wrap_ranges(text, None, |_| 0.), vec![0..text.len()]);
    }
}
