// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    pub const fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn right(&self) -> f32 {
        self.x + self.width
    }

    pub fn bottom(&self) -> f32 {
        self.y + self.height
    }

    pub fn mid_y(&self) -> f32 {
        self.y + self.height / 2.0
    }

    pub fn is_finite(&self) -> bool {
        self.x.is_finite()
            && self.y.is_finite()
            && self.width.is_finite()
            && self.height.is_finite()
    }

    pub fn inset(&self, dx: f32, dy: f32) -> Rect {
        Rect::new(
            self.x + dx,
            self.y + dy,
            self.width - 2.0 * dx,
            self.height - 2.0 * dy,
        )
    }

    pub fn contains_rect(&self, other: &Rect) -> bool {
        other.x >= self.x
            && other.y >= self.y
            && other.right() <= self.right()
            && other.bottom() <= self.bottom()
    }

    pub fn contains_point(&self, x: f32, y: f32) -> bool {
        x >= self.x && x < self.right() && y >= self.y && y < self.bottom()
    }

    pub fn intersects(&self, other: &Rect) -> bool {
        self.x < other.right()
            && other.x < self.right()
            && self.y < other.bottom()
            && other.y < self.bottom()
    }

    pub fn union(&self, other: &Rect) -> Rect {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        Rect::new(
            x,
            y,
            self.right().max(other.right()) - x,
            self.bottom().max(other.bottom()) - y,
        )
    }

    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = self.right().min(other.right());
        let bottom = self.bottom().min(other.bottom());
        (right > x && bottom > y).then(|| Rect::new(x, y, right - x, bottom - y))
    }

    pub fn integral(&self) -> Rect {
        let x = self.x.floor();
        let y = self.y.floor();
        Rect::new(
            x,
            y,
            (self.right().ceil() - x).max(1.0),
            (self.bottom().ceil() - y).max(1.0),
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    pub const BLACK: Rgb = Rgb { r: 0, g: 0, b: 0 };
    pub const WHITE: Rgb = Rgb {
        r: 255,
        g: 255,
        b: 255,
    };

    pub fn parse(text: &str) -> Option<Rgb> {
        let text = text.trim();
        let hex = text.strip_prefix('#').unwrap_or(text);
        if hex.len() == 6 && hex.chars().all(|c| c.is_ascii_hexdigit()) {
            let value = u32::from_str_radix(hex, 16).ok()?;
            return Some(Rgb {
                r: (value >> 16) as u8,
                g: (value >> 8) as u8,
                b: value as u8,
            });
        }
        let inner = text
            .strip_prefix("rgba(")
            .or_else(|| text.strip_prefix("rgb("))
            .map(|rest| rest.trim_end_matches(')'))
            .unwrap_or(text);
        let parts: Vec<f32> = inner
            .split(',')
            .map(|part| part.trim().parse::<f32>())
            .collect::<Result<_, _>>()
            .ok()?;
        if parts.len() < 3 {
            return None;
        }
        let scale = if parts[..3].iter().any(|v| *v > 255.0) {
            257.0
        } else {
            1.0
        };
        let channel = |v: f32| (v / scale).round().clamp(0.0, 255.0) as u8;
        Some(Rgb {
            r: channel(parts[0]),
            g: channel(parts[1]),
            b: channel(parts[2]),
        })
    }

    pub fn luminance(&self) -> f32 {
        (0.299 * f32::from(self.r) + 0.587 * f32::from(self.g) + 0.114 * f32::from(self.b)) / 255.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Paint {
    pub rgb: Rgb,
    pub alpha: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FieldStyle {
    pub font_family: Option<String>,
    pub font_points: Option<f32>,
    pub color: Option<Rgb>,
    pub background: Option<Rgb>,
}

pub const GHOST_OPACITY: f32 = 0.4;
pub const EMPHASIS_OPACITY: f32 = 0.62;
const UNRELIABLE_CONTRAST: f32 = 2.0;
const MIN_LEGIBLE_CONTRAST: f32 = 3.0;

fn contrast(a: f32, b: f32) -> f32 {
    (a.max(b) + 0.05) / (a.min(b) + 0.05)
}

fn dim_hint(dark_background: bool) -> Paint {
    Paint {
        rgb: if dark_background {
            Rgb::WHITE
        } else {
            Rgb::BLACK
        },
        alpha: GHOST_OPACITY,
    }
}

pub fn ghost_paint(
    style: Option<&FieldStyle>,
    dark_environment: bool,
    sampled: Option<f32>,
) -> Paint {
    let host = style.and_then(|s| s.color);
    if let Some(luminance) = sampled {
        if let Some(host) = host
            && contrast(host.luminance(), luminance) >= MIN_LEGIBLE_CONTRAST
        {
            return Paint {
                rgb: host,
                alpha: GHOST_OPACITY,
            };
        }
        return dim_hint(luminance < 0.5);
    }
    let background = style.and_then(|s| s.background);
    match (host, background) {
        (Some(host), Some(background))
            if contrast(host.luminance(), background.luminance()) < UNRELIABLE_CONTRAST =>
        {
            dim_hint(background.luminance() < 0.5)
        }
        (Some(host), _) => Paint {
            rgb: host,
            alpha: GHOST_OPACITY,
        },
        (None, Some(background)) => dim_hint(background.luminance() < 0.5),
        (None, None) => dim_hint(dark_environment),
    }
}

pub const MIN_FONT_PX: f32 = 10.0;
pub const MAX_FONT_PX: f32 = 64.0;
pub const MAX_ESTIMATED_FONT_PX: f32 = 21.0;
const GLYPH_BOX_PER_SIZE: f32 = 1.2;

pub fn points_to_px(points: f32) -> f32 {
    points * 96.0 / 72.0
}

pub fn ghost_font_px(style_px: Option<f32>, caret_height: f32, caret_exact: bool) -> f32 {
    let size = match style_px.filter(|px| px.is_finite() && *px > 0.0) {
        Some(reported) => {
            if caret_exact && caret_height.is_finite() && caret_height > 0.0 {
                let ratio = caret_height / (reported * GLYPH_BOX_PER_SIZE);
                if ratio < 0.8 {
                    reported * ratio
                } else if ratio > 2.4 {
                    reported * ratio / 1.2
                } else {
                    reported
                }
            } else {
                reported
            }
        }
        None if caret_height.is_finite() && caret_height > 0.0 => {
            let estimate = caret_height / GLYPH_BOX_PER_SIZE;
            if caret_exact {
                estimate
            } else {
                estimate.min(MAX_ESTIMATED_FONT_PX)
            }
        }
        None => points_to_px(11.0),
    };
    size.clamp(MIN_FONT_PX, MAX_FONT_PX)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RenderMode {
    Inline,
    Pill,
}

pub fn render_mode(caret_exact: bool, caret_at_end_of_line: bool) -> RenderMode {
    if caret_exact && caret_at_end_of_line {
        RenderMode::Inline
    } else {
        RenderMode::Pill
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FontMetrics {
    pub line_height: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct InlineLine {
    pub text: String,
    pub offset: usize,
    pub x: f32,
    pub y: f32,
    pub height: f32,
    pub width: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct InlineLayout {
    pub lines: Vec<InlineLine>,
    pub right_to_left: bool,
    pub complete: bool,
    pub wrap_edge: f32,
}

pub const FIELD_INSET: f32 = 8.0;
pub const SCREEN_MARGIN: f32 = 8.0;
pub const MAX_INLINE_LINES: usize = 6;
const FIELD_EDGE_TOLERANCE: f32 = 1.0;

#[derive(Clone, Copy, Debug)]
pub struct InlineInput<'a> {
    pub caret: Rect,
    pub field: Option<Rect>,
    pub preceding_line: &'a str,
    pub screen: Option<Rect>,
    pub right_to_left: bool,
    pub lines_below_free: bool,
    pub metrics: FontMetrics,
}

impl InlineLayout {
    pub fn make(
        text: &str,
        input: &InlineInput<'_>,
        known_wrap_edge: Option<f32>,
        measure: &dyn Fn(&str) -> f32,
    ) -> InlineLayout {
        let display = display_text(text);
        let span = text_span(input.caret, input.field, input.screen);
        let rtl = input.right_to_left;
        let anchor = if rtl {
            input.caret.x
        } else {
            input.caret.right()
        };
        let wrap_edge = known_wrap_edge.unwrap_or_else(|| {
            wrap_edge(
                input.preceding_line,
                anchor,
                input.field,
                span,
                rtl,
                measure,
            )
        });
        let pitch = input.caret.height.max(input.metrics.line_height);
        let mut top = input.caret.y;
        let height = input.caret.height.max(1.0);
        let lowest_bottom = input
            .field
            .map(|field| field.bottom() + FIELD_EDGE_TOLERANCE);
        let continues_word = input
            .preceding_line
            .chars()
            .last()
            .is_some_and(|c| !c.is_whitespace())
            && display.chars().next().is_some_and(|c| !c.is_whitespace());

        let mut lines = Vec::new();
        let chars: Vec<char> = display.chars().collect();
        let mut position = 0usize;
        let mut line_start = anchor;
        let mut budget = if rtl {
            anchor - span.0
        } else {
            span.1 - anchor
        };
        let mut first = true;
        while position < chars.len() && lines.len() < MAX_INLINE_LINES {
            if !first {
                let fits = lowest_bottom.is_none_or(|lowest| top + height <= lowest);
                if !input.lines_below_free || !fits {
                    break;
                }
            }
            let remaining: String = chars[position..].iter().collect();
            let piece = fitting_prefix(&remaining, budget, !first, measure);
            if first && piece.is_empty() && continues_word {
                return InlineLayout {
                    lines: Vec::new(),
                    right_to_left: rtl,
                    complete: false,
                    wrap_edge,
                };
            }
            let count = piece.chars().count();
            if count > 0 {
                let width = measure(&piece);
                lines.push(InlineLine {
                    text: piece,
                    offset: position,
                    x: line_start,
                    y: top,
                    height,
                    width,
                });
                position += count;
            }
            while position < chars.len() && (chars[position] == ' ' || chars[position] == '\n') {
                position += 1;
            }
            top += pitch;
            line_start = wrap_edge;
            budget = if rtl {
                wrap_edge - span.0
            } else {
                span.1 - wrap_edge
            };
            first = false;
        }
        InlineLayout {
            lines,
            right_to_left: rtl,
            complete: position >= chars.len(),
            wrap_edge,
        }
    }

    pub fn bounds(&self) -> Option<Rect> {
        self.lines
            .iter()
            .map(|line| {
                let x = if self.right_to_left {
                    line.x - line.width
                } else {
                    line.x
                };
                Rect::new(x, line.y, line.width.max(1.0), line.height)
            })
            .reduce(|a, b| a.union(&b))
    }

    pub fn longest_drawable(
        text: &str,
        allow_partial: bool,
        layout: &dyn Fn(&str) -> InlineLayout,
    ) -> Option<(String, InlineLayout)> {
        let whole = layout(text);
        if whole.complete && !whole.lines.is_empty() {
            return Some((text.to_string(), whole));
        }
        if !allow_partial {
            return None;
        }
        word_prefixes(text)
            .into_iter()
            .rev()
            .filter(|prefix| prefix.len() < text.len())
            .find_map(|prefix| {
                let candidate = layout(&prefix);
                (candidate.complete && !candidate.lines.is_empty()).then_some((prefix, candidate))
            })
    }

    pub fn caret_after_typing(
        typed: &str,
        input: &InlineInput<'_>,
        wrap_edge: Option<f32>,
        measure: &dyn Fn(&str) -> f32,
    ) -> Option<Rect> {
        if typed.is_empty() || typed.contains('\n') {
            return None;
        }
        let layout = InlineLayout::make(typed, input, wrap_edge, measure);
        if !layout.complete {
            return None;
        }
        let rtl = input.right_to_left;
        let anchor = if rtl {
            input.caret.x
        } else {
            input.caret.right()
        };
        let trailing: String = typed
            .chars()
            .rev()
            .take_while(|c| c.is_whitespace())
            .collect();
        let spaces = measure(&trailing);
        let (end_x, end_y) = match layout.lines.last() {
            Some(last) => (
                if rtl {
                    last.x - last.width
                } else {
                    last.x + last.width
                },
                last.y,
            ),
            None => (anchor, input.caret.y),
        };
        let x = if rtl { end_x - spaces } else { end_x + spaces };
        let mut caret = input.caret;
        caret.x += x - anchor;
        caret.y = end_y;
        Some(caret)
    }
}

pub fn word_prefixes(text: &str) -> Vec<String> {
    let mut prefixes = Vec::new();
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let mut i = 0;
    while i < chars.len() {
        while i < chars.len() && chars[i].1.is_whitespace() {
            i += 1;
        }
        if i >= chars.len() {
            break;
        }
        while i < chars.len() && !chars[i].1.is_whitespace() {
            i += 1;
        }
        let end = chars.get(i).map_or(text.len(), |(index, _)| *index);
        prefixes.push(text[..end].to_string());
    }
    prefixes
}

pub fn display_text(text: &str) -> String {
    text.split('\n')
        .map(|line| {
            let words: Vec<&str> = line.split_whitespace().collect();
            if words.is_empty() {
                return String::new();
            }
            let joined = words.join(" ");
            if line.starts_with(char::is_whitespace) {
                format!(" {joined}")
            } else {
                joined
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn text_span(caret: Rect, field: Option<Rect>, screen: Option<Rect>) -> (f32, f32) {
    let screen =
        screen.unwrap_or_else(|| Rect::new(caret.x - 400.0, caret.y - 300.0, 1200.0, 600.0));
    let mut min = screen.x + SCREEN_MARGIN;
    let mut max = screen.right() - SCREEN_MARGIN;
    if let Some(field) = field
        && field.width > FIELD_INSET * 2.0 + 48.0
    {
        min = min.max(field.x + FIELD_INSET);
        max = max.min(field.right() - FIELD_INSET);
    }
    (min, max.max(min))
}

fn wrap_edge(
    preceding_line: &str,
    anchor: f32,
    field: Option<Rect>,
    span: (f32, f32),
    rtl: bool,
    measure: &dyn Fn(&str) -> f32,
) -> f32 {
    let paragraph = preceding_line.rsplit('\n').next().unwrap_or("");
    if let Some(field) = field
        && !paragraph.is_empty()
    {
        let width = measure(paragraph);
        if rtl {
            let edge = anchor + width;
            if edge <= field.right() + 1.0 && edge >= field.right() - 40.0 {
                return edge;
            }
        } else {
            let edge = anchor - width;
            if edge >= field.x - 1.0 && edge <= field.x + 40.0 {
                return edge;
            }
        }
    }
    if rtl { span.1 } else { span.0 }
}

fn fitting_prefix(
    text: &str,
    available: f32,
    must_take_something: bool,
    measure: &dyn Fn(&str) -> f32,
) -> String {
    let paragraph: String = text.chars().take_while(|c| *c != '\n').collect();
    if paragraph.is_empty() || measure(&paragraph) <= available {
        return paragraph;
    }
    let chars: Vec<char> = paragraph.chars().collect();
    let mut fitted = 0usize;
    let mut index = 0usize;
    while index < chars.len() {
        let mut end = index;
        while end < chars.len() && chars[end] == ' ' {
            end += 1;
        }
        while end < chars.len() && chars[end] != ' ' {
            end += 1;
        }
        let candidate: String = chars[..end].iter().collect();
        if measure(&candidate) > available {
            break;
        }
        fitted = end;
        index = end;
    }
    if fitted == 0 && must_take_something {
        let leading = chars.iter().take_while(|c| **c == ' ').count();
        let mut taken = leading + 1;
        for count in (leading + 2)..=chars.len() {
            let candidate: String = chars[leading..count].iter().collect();
            if measure(&candidate) > available {
                break;
            }
            taken = count;
        }
        return chars[..taken.min(chars.len())].iter().collect();
    }
    chars[..fitted].iter().collect()
}

pub const PILL_GAP: f32 = 2.0;
pub const REANCHOR_TOLERANCE: f32 = 1.5;
pub const BACKWARD_DRIFT_HOLD_MS: u64 = 300;

pub fn pill_frame_at_caret(caret: Rect, width: f32, height: f32, screen: Option<Rect>) -> Rect {
    let width = width.max(8.0);
    let height = height.max(18.0);
    let mut x = match screen {
        Some(screen) => caret.x.min(screen.right() - width),
        None => caret.x,
    };
    if let Some(screen) = screen {
        x = x.max(screen.x + PILL_GAP);
    }
    let mut y = caret.bottom() + PILL_GAP;
    if let Some(screen) = screen
        && y + height > screen.bottom()
    {
        y = caret.y - PILL_GAP - height;
    }
    Rect::new(x, y, width, height)
}

pub fn pill_frame(
    caret: Rect,
    caret_exact: bool,
    field: Option<Rect>,
    width: f32,
    height: f32,
    screen: Option<Rect>,
) -> Option<Rect> {
    if caret_exact {
        return Some(pill_frame_at_caret(caret, width, height, screen));
    }
    let field = field?;
    let width = width.max(8.0);
    let height = height.max(18.0);
    let mut x = match screen {
        Some(screen) => field.x.min(screen.right() - width),
        None => field.x,
    };
    if let Some(screen) = screen {
        x = x.max(screen.x + PILL_GAP);
    }
    let below = Rect::new(x, field.bottom() + PILL_GAP, width, height);
    let Some(screen) = screen else {
        return Some(below);
    };
    if below.bottom() <= screen.bottom() {
        return Some(below);
    }
    let above = Rect::new(x, field.y - PILL_GAP - height, width, height);
    (above.y >= screen.y).then_some(above)
}

pub fn should_hold_reanchor(
    current: (f32, f32),
    target: (f32, f32),
    ms_since_accept: Option<u64>,
    right_to_left: bool,
) -> bool {
    let dy = target.1 - current.1;
    if dy.abs() > REANCHOR_TOLERANCE {
        return false;
    }
    let dx = target.0 - current.0;
    let caret_ahead = if right_to_left { -dx } else { dx };
    if caret_ahead.abs() <= REANCHOR_TOLERANCE {
        return true;
    }
    caret_ahead < 0.0 && ms_since_accept.is_some_and(|ms| ms <= BACKWARD_DRIFT_HOLD_MS)
}

pub const PILL_MAX_TEXT_WIDTH: f32 = 420.0;
pub const PILL_MIN_TEXT_WIDTH: f32 = 80.0;
pub const PILL_MAX_LINES: usize = 4;

pub fn pill_text_width(screen: Option<Rect>) -> f32 {
    match screen {
        Some(screen) => (screen.width - 48.0).clamp(PILL_MIN_TEXT_WIDTH, PILL_MAX_TEXT_WIDTH),
        None => PILL_MAX_TEXT_WIDTH,
    }
}

pub fn pill_lines(
    text: &str,
    max_width: f32,
    max_lines: usize,
    measure: &dyn Fn(&str) -> f32,
) -> Vec<String> {
    let paragraphs: Vec<String> = text
        .lines()
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|line| !line.is_empty())
        .collect();
    let mut lines: Vec<String> = Vec::new();
    let mut truncated = false;
    'paragraphs: for (index, paragraph) in paragraphs.iter().enumerate() {
        let mut words: Vec<String> = paragraph.split(' ').map(str::to_string).collect();
        while !words.is_empty() {
            if lines.len() >= max_lines {
                truncated = true;
                break 'paragraphs;
            }
            let mut line = String::new();
            let mut used = 0;
            for word in &words {
                let candidate = if line.is_empty() {
                    word.clone()
                } else {
                    format!("{line} {word}")
                };
                if measure(&candidate) <= max_width || line.is_empty() {
                    line = candidate;
                    used += 1;
                } else {
                    break;
                }
            }
            words.drain(..used);
            if measure(&line) > max_width {
                let mut cut = String::new();
                for c in line.chars() {
                    let mut next = cut.clone();
                    next.push(c);
                    if !cut.is_empty() && measure(&next) > max_width {
                        break;
                    }
                    cut = next;
                }
                let rest: String = line.chars().skip(cut.chars().count()).collect();
                lines.push(cut);
                if !rest.is_empty() {
                    words.insert(0, rest);
                }
                continue;
            }
            lines.push(line);
        }
        if lines.len() >= max_lines && index + 1 < paragraphs.len() {
            truncated = true;
            break;
        }
    }
    if truncated && let Some(last) = lines.last_mut() {
        let mut candidate = last.trim_end().to_string();
        while !candidate.is_empty() && measure(&format!("{candidate}...")) > max_width {
            candidate.pop();
        }
        *last = format!("{candidate}...");
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mono(text: &str) -> f32 {
        text.chars().count() as f32 * 8.0
    }

    fn input<'a>(caret: Rect, field: Option<Rect>, preceding: &'a str) -> InlineInput<'a> {
        InlineInput {
            caret,
            field,
            preceding_line: preceding,
            screen: Some(Rect::new(0.0, 0.0, 1600.0, 1000.0)),
            right_to_left: false,
            lines_below_free: true,
            metrics: FontMetrics { line_height: 18.0 },
        }
    }

    #[test]
    fn inline_text_starts_at_the_caret() {
        let field = Rect::new(100.0, 100.0, 600.0, 200.0);
        let caret = Rect::new(300.0, 110.0, 1.0, 18.0);
        let layout = InlineLayout::make(" world", &input(caret, Some(field), "Hello"), None, &mono);
        assert!(layout.complete);
        assert_eq!(layout.lines.len(), 1);
        assert_eq!(layout.lines[0].x, 301.0);
        assert_eq!(layout.lines[0].y, 110.0);
        assert_eq!(layout.lines[0].text, " world");
        assert_eq!(layout.bounds(), Some(Rect::new(301.0, 110.0, 48.0, 18.0)));
    }

    #[test]
    fn long_text_wraps_at_the_field_text_edge_onto_free_lines() {
        let field = Rect::new(100.0, 100.0, 200.0, 200.0);
        let caret = Rect::new(123.0, 110.0, 1.0, 18.0);
        let layout = InlineLayout::make(
            " there, this wraps around",
            &input(caret, Some(field), "Hi"),
            None,
            &mono,
        );
        assert!(layout.complete);
        assert!(layout.lines.len() >= 2);
        assert_eq!(layout.lines[1].x, 108.0);
        assert_eq!(layout.lines[1].y, 128.0);
        for line in &layout.lines {
            assert!(line.x + line.width <= field.right() - FIELD_INSET + 0.01);
        }
        let mut busy = input(caret, Some(field), "Hi");
        busy.lines_below_free = false;
        let partial = InlineLayout::make(" there, this wraps around", &busy, None, &mono);
        assert!(!partial.complete);
        assert_eq!(partial.lines.len(), 1);
    }

    #[test]
    fn a_word_that_moves_to_the_next_line_has_no_place() {
        let field = Rect::new(0.0, 0.0, 200.0, 100.0);
        let caret = Rect::new(190.0, 10.0, 1.0, 18.0);
        let layout = InlineLayout::make("ing", &input(caret, Some(field), "follow"), None, &mono);
        assert!(layout.lines.is_empty());
        assert!(!layout.complete);
    }

    #[test]
    fn longest_drawable_cuts_after_a_word() {
        let field = Rect::new(0.0, 0.0, 200.0, 30.0);
        let caret = Rect::new(120.0, 5.0, 1.0, 18.0);
        let text = " one two three four";
        let input = input(caret, Some(field), "Some text");
        let make = |candidate: &str| InlineLayout::make(candidate, &input, None, &mono);
        let (shown, layout) = InlineLayout::longest_drawable(text, true, &make).unwrap();
        assert_eq!(shown, " one two");
        assert!(layout.complete);
        assert!(InlineLayout::longest_drawable(text, false, &make).is_none());
        assert_eq!(word_prefixes(" a bc d"), [" a", " a bc", " a bc d"]);
    }

    #[test]
    fn caret_after_typing_moves_along_the_line() {
        let caret = Rect::new(300.0, 110.0, 1.0, 18.0);
        let field = Rect::new(100.0, 100.0, 600.0, 200.0);
        let input = input(caret, Some(field), "Hello");
        let moved = InlineLayout::caret_after_typing(" up", &input, None, &mono).unwrap();
        assert_eq!(moved.x, 324.0);
        assert_eq!(moved.y, 110.0);
        let spaced = InlineLayout::caret_after_typing(" up ", &input, None, &mono).unwrap();
        assert_eq!(spaced.x, 332.0);
        assert!(InlineLayout::caret_after_typing("a\nb", &input, None, &mono).is_none());
    }

    #[test]
    fn display_text_collapses_spaces() {
        assert_eq!(display_text(" up   on\tthe"), " up on the");
        assert_eq!(display_text("a\n  b"), "a\n b");
    }

    #[test]
    fn pill_goes_below_the_caret_or_above_near_the_bottom() {
        let screen = Some(Rect::new(0.0, 0.0, 1000.0, 800.0));
        let caret = Rect::new(100.0, 100.0, 1.0, 18.0);
        let below = pill_frame_at_caret(caret, 120.0, 24.0, screen);
        assert_eq!(below, Rect::new(100.0, 120.0, 120.0, 24.0));
        let low = Rect::new(100.0, 780.0, 1.0, 18.0);
        let above = pill_frame_at_caret(low, 120.0, 24.0, screen);
        assert_eq!(above.y, 780.0 - PILL_GAP - 24.0);
        let edge = pill_frame_at_caret(Rect::new(990.0, 10.0, 1.0, 18.0), 120.0, 24.0, screen);
        assert_eq!(edge.x, 880.0);
        let field = Rect::new(50.0, 300.0, 400.0, 100.0);
        let pill = pill_frame(caret, false, Some(field), 120.0, 24.0, screen).unwrap();
        assert_eq!(pill.y, 402.0);
        let tall = Rect::new(50.0, 2.0, 400.0, 796.0);
        assert!(pill_frame(caret, false, Some(tall), 120.0, 24.0, screen).is_none());
        assert!(pill_frame(caret, false, None, 120.0, 24.0, screen).is_none());
    }

    #[test]
    fn render_mode_needs_an_exact_caret_at_the_line_end() {
        assert_eq!(render_mode(true, true), RenderMode::Inline);
        assert_eq!(render_mode(true, false), RenderMode::Pill);
        assert_eq!(render_mode(false, true), RenderMode::Pill);
    }

    #[test]
    fn reanchor_holds_small_moves_and_recent_backward_drift() {
        assert!(should_hold_reanchor(
            (100.0, 50.0),
            (101.0, 50.5),
            None,
            false
        ));
        assert!(!should_hold_reanchor(
            (100.0, 50.0),
            (130.0, 50.0),
            None,
            false
        ));
        assert!(should_hold_reanchor(
            (130.0, 50.0),
            (100.0, 50.0),
            Some(120),
            false
        ));
        assert!(!should_hold_reanchor(
            (130.0, 50.0),
            (100.0, 50.0),
            Some(900),
            false
        ));
        assert!(!should_hold_reanchor(
            (100.0, 50.0),
            (100.0, 70.0),
            Some(10),
            false
        ));
    }

    #[test]
    fn font_size_follows_the_field_or_the_caret() {
        assert_eq!(ghost_font_px(Some(15.0), 18.0, true), 15.0);
        let zoomed = ghost_font_px(Some(12.0), 60.0, true);
        assert!(zoomed > 30.0, "{zoomed}");
        assert_eq!(ghost_font_px(None, 24.0, true), 20.0);
        assert_eq!(ghost_font_px(None, 60.0, false), MAX_ESTIMATED_FONT_PX);
        assert_eq!(ghost_font_px(None, 2.0, true), MIN_FONT_PX);
        assert_eq!(points_to_px(12.0), 16.0);
    }

    #[test]
    fn ghost_color_stays_legible() {
        let dark_text = FieldStyle {
            color: Some(Rgb::BLACK),
            background: Some(Rgb::WHITE),
            ..Default::default()
        };
        assert_eq!(
            ghost_paint(Some(&dark_text), false, None),
            Paint {
                rgb: Rgb::BLACK,
                alpha: GHOST_OPACITY
            }
        );
        let wrong = FieldStyle {
            color: Some(Rgb::BLACK),
            background: Some(Rgb { r: 5, g: 5, b: 5 }),
            ..Default::default()
        };
        assert_eq!(ghost_paint(Some(&wrong), false, None).rgb, Rgb::WHITE);
        assert_eq!(
            ghost_paint(Some(&dark_text), false, Some(0.05)).rgb,
            Rgb::WHITE
        );
        assert_eq!(ghost_paint(None, true, None).rgb, Rgb::WHITE);
        assert_eq!(ghost_paint(None, false, None).rgb, Rgb::BLACK);
    }

    #[test]
    fn colors_parse_in_toolkit_forms() {
        assert_eq!(
            Rgb::parse("#ff0080"),
            Some(Rgb {
                r: 255,
                g: 0,
                b: 128
            })
        );
        assert_eq!(Rgb::parse("0,0,0"), Some(Rgb::BLACK));
        assert_eq!(Rgb::parse("65535,65535,65535"), Some(Rgb::WHITE));
        assert_eq!(
            Rgb::parse("rgb(10, 20, 30)"),
            Some(Rgb {
                r: 10,
                g: 20,
                b: 30
            })
        );
        assert_eq!(Rgb::parse("teal"), None);
    }

    #[test]
    fn pill_text_wraps_and_ellipsizes() {
        let lines = pill_lines("one two three four five six", 80.0, 4, &mono);
        assert_eq!(lines, ["one two", "three four", "five six"]);
        let cut = pill_lines("one two three four five six seven", 80.0, 2, &mono);
        assert_eq!(cut.len(), 2);
        assert!(cut[1].ends_with("..."));
        let long = pill_lines("abcdefghijklmnop", 64.0, 4, &mono);
        assert_eq!(long, ["abcdefgh", "ijklmnop"]);
    }
}
