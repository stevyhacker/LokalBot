//! Renders assistant answers and generated notes: a small Markdown subset
//! (paragraphs, headings, lists, quotes, code, bold, italic, links) with
//! inline `[n]` citations in teal on a teal wash, like `SelectableDigestText`
//! with `ChatCitationParser.extract(…, linked: true)` on macOS.

use std::ops::Range;
use std::rc::Rc;

use gpui_kit::component::{ActiveTheme as _, h_flex, v_flex};
use gpui_kit::{
    App, Div, ElementId, FontWeight, HighlightStyle, InteractiveText, ParentElement as _,
    SharedString, Styled as _, StyledText, UnderlineStyle, Window, div, px,
};

use super::citations::{self, CitationSource, Piece};
use crate::theme::{LbThemeExt as _, ty};

const CITE_OPEN: char = '\u{E000}';
const CITE_CLOSE: char = '\u{E001}';

/// Inline styling of one run of text.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SpanStyle {
    pub bold: bool,
    pub emphasis: bool,
    pub code: bool,
    pub link: Option<usize>,
    pub cite: Option<usize>,
}

/// One line-wrapped run of styled text.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Inline {
    pub text: String,
    pub segments: Vec<(Range<usize>, SpanStyle)>,
}

impl Inline {
    fn push(&mut self, text: &str, style: &SpanStyle) {
        if text.is_empty() {
            return;
        }
        let start = self.text.len();
        self.text.push_str(text);
        let end = self.text.len();
        if let Some((range, last)) = self.segments.last_mut()
            && last == style
            && range.end == start
        {
            range.end = end;
            return;
        }
        self.segments.push((start..end, style.clone()));
    }

    fn is_blank(&self) -> bool {
        self.text.trim().is_empty()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Block {
    Paragraph(Inline),
    Heading {
        level: u8,
        inline: Inline,
    },
    Item {
        marker: Option<String>,
        depth: usize,
        inline: Inline,
    },
    Quote(Inline),
    Code(String),
    Rule,
}

/// A parsed answer: blocks, the cited sources in number order and the link targets.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Answer {
    pub blocks: Vec<Block>,
    pub citations: Vec<CitationSource>,
    pub links: Vec<String>,
}

impl Answer {
    pub fn is_empty(&self) -> bool {
        self.blocks.is_empty()
    }
}

/// Parses Markdown with LokalBot citation markers.
pub fn parse(text: &str) -> Answer {
    let (pieces, citations) = citations::split(text);
    let mut source = String::with_capacity(text.len());
    for piece in pieces {
        match piece {
            Piece::Text(text) => source.push_str(&text),
            Piece::Cite(index) => {
                source.push(CITE_OPEN);
                source.push_str(&index.to_string());
                source.push(CITE_CLOSE);
            }
        }
    }
    let mut answer = Answer {
        citations,
        ..Default::default()
    };
    parse_blocks(&source, &mut answer);
    answer
}

fn parse_blocks(source: &str, answer: &mut Answer) {
    let mut paragraph: Vec<&str> = Vec::new();
    let mut quote: Vec<&str> = Vec::new();
    let mut code: Option<Vec<&str>> = None;
    let mut lines = source.lines().peekable();

    fn flush_paragraph(lines: &mut Vec<&str>, answer: &mut Answer) {
        if lines.is_empty() {
            return;
        }
        let inline = inline(&lines.join("\n"), &mut answer.links);
        if !inline.is_blank() {
            answer.blocks.push(Block::Paragraph(inline));
        }
        lines.clear();
    }
    fn flush_quote(lines: &mut Vec<&str>, answer: &mut Answer) {
        if lines.is_empty() {
            return;
        }
        let inline = inline(&lines.join("\n"), &mut answer.links);
        answer.blocks.push(Block::Quote(inline));
        lines.clear();
    }

    while let Some(line) = lines.next() {
        if let Some(code_lines) = code.as_mut() {
            if line.trim_start().starts_with("```") {
                answer.blocks.push(Block::Code(code_lines.join("\n")));
                code = None;
            } else {
                code_lines.push(line);
            }
            continue;
        }
        let trimmed = line.trim();
        if trimmed.starts_with("```") {
            flush_paragraph(&mut paragraph, answer);
            flush_quote(&mut quote, answer);
            code = Some(Vec::new());
            continue;
        }
        if trimmed.is_empty() {
            flush_paragraph(&mut paragraph, answer);
            flush_quote(&mut quote, answer);
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix('>') {
            flush_paragraph(&mut paragraph, answer);
            quote.push(rest.strip_prefix(' ').unwrap_or(rest));
            continue;
        }
        flush_quote(&mut quote, answer);
        if is_rule(trimmed) {
            flush_paragraph(&mut paragraph, answer);
            answer.blocks.push(Block::Rule);
            continue;
        }
        if let Some((level, text)) = heading(trimmed) {
            flush_paragraph(&mut paragraph, answer);
            let inline = inline(text, &mut answer.links);
            answer.blocks.push(Block::Heading { level, inline });
            continue;
        }
        if let Some((depth, marker, text)) = list_item(line) {
            flush_paragraph(&mut paragraph, answer);
            let mut body = text.to_string();
            // Indented continuation lines belong to the item.
            while let Some(next) = lines.peek() {
                let next_trimmed = next.trim();
                let indented = next.starts_with("  ") || next.starts_with('\t');
                if next_trimmed.is_empty() || !indented || list_item(next).is_some() {
                    break;
                }
                body.push(' ');
                body.push_str(next_trimmed);
                lines.next();
            }
            let inline = inline(&body, &mut answer.links);
            answer.blocks.push(Block::Item {
                marker,
                depth,
                inline,
            });
            continue;
        }
        paragraph.push(line.trim_end());
    }
    if let Some(code_lines) = code {
        answer.blocks.push(Block::Code(code_lines.join("\n")));
    }
    flush_paragraph(&mut paragraph, answer);
    flush_quote(&mut quote, answer);
}

fn is_rule(line: &str) -> bool {
    let compact: String = line.chars().filter(|c| !c.is_whitespace()).collect();
    compact.len() >= 3
        && ["-", "*", "_"]
            .iter()
            .any(|m| compact.chars().all(|c| c.to_string() == *m))
}

fn heading(line: &str) -> Option<(u8, &str)> {
    let hashes = line.bytes().take_while(|b| *b == b'#').count();
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let rest = line[hashes..].strip_prefix(' ')?;
    Some((hashes as u8, rest.trim_end_matches('#').trim()))
}

/// `- item`, `* item`, `+ item`, `• item`, `1. item`, `2) item`.
fn list_item(line: &str) -> Option<(usize, Option<String>, &str)> {
    let indent: usize = line
        .chars()
        .take_while(|c| *c == ' ' || *c == '\t')
        .map(|c| if c == '\t' { 4 } else { 1 })
        .sum();
    let trimmed = line.trim_start();
    let depth = indent / 2;
    for bullet in ["- ", "* ", "+ ", "• "] {
        if let Some(rest) = trimmed.strip_prefix(bullet) {
            return Some((depth, None, rest.trim_start()));
        }
    }
    let digits = trimmed.bytes().take_while(u8::is_ascii_digit).count();
    if (1..=3).contains(&digits) {
        let rest = &trimmed[digits..];
        for punct in [". ", ") "] {
            if let Some(body) = rest.strip_prefix(punct) {
                return Some((
                    depth,
                    Some(format!("{}.", &trimmed[..digits])),
                    body.trim_start(),
                ));
            }
        }
    }
    None
}

fn inline(source: &str, links: &mut Vec<String>) -> Inline {
    let mut out = Inline::default();
    parse_inline(source, &SpanStyle::default(), &mut out, links);
    out
}

fn parse_inline(source: &str, style: &SpanStyle, out: &mut Inline, links: &mut Vec<String>) {
    let mut plain = String::new();
    let mut i = 0;
    let bytes = source.as_bytes();
    while i < source.len() {
        let rest = &source[i..];
        let Some(c) = rest.chars().next() else { break };
        if c == CITE_OPEN
            && let Some(close) = rest.find(CITE_CLOSE)
            && let Ok(index) = rest[CITE_OPEN.len_utf8()..close].parse::<usize>()
        {
            out.push(&std::mem::take(&mut plain), style);
            let cite = SpanStyle {
                cite: Some(index),
                link: None,
                ..style.clone()
            };
            out.push(&format!("[{}]", index + 1), &cite);
            i += close + CITE_CLOSE.len_utf8();
            continue;
        }
        if c == '\\'
            && let Some(next) = rest[1..].chars().next()
            && next.is_ascii_punctuation()
        {
            plain.push(next);
            i += 1 + next.len_utf8();
            continue;
        }
        if (rest.starts_with("**") || rest.starts_with("__"))
            && let Some(len) = closing(&rest[2..], &rest[..2])
        {
            out.push(&std::mem::take(&mut plain), style);
            let bold = SpanStyle {
                bold: true,
                ..style.clone()
            };
            parse_inline(&rest[2..2 + len], &bold, out, links);
            i += 2 + len + 2;
            continue;
        }
        if c == '`'
            && let Some(len) = rest[1..].find('`')
            && len > 0
        {
            out.push(&std::mem::take(&mut plain), style);
            let code = SpanStyle {
                code: true,
                ..style.clone()
            };
            out.push(&rest[1..1 + len], &code);
            i += len + 2;
            continue;
        }
        if (c == '*' || c == '_') && opens_emphasis(bytes, i) {
            let marker = &rest[..1];
            if let Some(len) = closing(&rest[1..], marker) {
                out.push(&std::mem::take(&mut plain), style);
                let emphasis = SpanStyle {
                    emphasis: true,
                    ..style.clone()
                };
                parse_inline(&rest[1..1 + len], &emphasis, out, links);
                i += len + 2;
                continue;
            }
        }
        if c == '['
            && let Some((label, url, consumed)) = link(rest)
        {
            out.push(&std::mem::take(&mut plain), style);
            links.push(url.to_string());
            let linked = SpanStyle {
                link: Some(links.len() - 1),
                ..style.clone()
            };
            parse_inline(label, &linked, out, links);
            i += consumed;
            continue;
        }
        plain.push(c);
        i += c.len_utf8();
    }
    out.push(&plain, style);
}

/// Length of the content before the closing `marker`, if the span is valid:
/// non-empty, not starting or ending with whitespace.
fn closing(rest: &str, marker: &str) -> Option<usize> {
    if rest.starts_with(char::is_whitespace) {
        return None;
    }
    let mut search = 0;
    while let Some(found) = rest[search..].find(marker) {
        let at = search + found;
        let before = rest[..at].chars().last();
        let after = rest[at + marker.len()..].chars().next();
        let valid_end = at > 0 && before.is_some_and(|b| !b.is_whitespace());
        // `_` closes only at a word boundary, so snake_case stays literal.
        let boundary = !marker.starts_with('_') || after.is_none_or(|a| !a.is_alphanumeric());
        if valid_end && boundary {
            return Some(at);
        }
        search = at + marker.len();
    }
    None
}

fn opens_emphasis(bytes: &[u8], i: usize) -> bool {
    let next = bytes.get(i + 1).copied();
    if next.is_none_or(|n| n.is_ascii_whitespace()) {
        return false;
    }
    // `_` inside a word is literal.
    bytes[i] != b'_' || i == 0 || !bytes[i - 1].is_ascii_alphanumeric()
}

/// `[label](url)` at the start of `rest`.
fn link(rest: &str) -> Option<(&str, &str, usize)> {
    let close = rest.find("](")?;
    let label = &rest[1..close];
    if label.is_empty() || label.contains('\n') {
        return None;
    }
    let after = &rest[close + 2..];
    let end = after.find(')')?;
    let url = after[..end].trim();
    if url.is_empty() || url.contains(char::is_whitespace) {
        return None;
    }
    Some((label, url, close + 2 + end + 1))
}

// ------------------------------------------------------------------ render

/// Called with the 0-based citation index when a `[n]` is clicked.
pub type CiteHandler = Rc<dyn Fn(usize, &mut Window, &mut App)>;

/// Text size and color of a rendered answer.
#[derive(Clone, Copy)]
pub struct AnswerStyle {
    pub size: gpui_kit::Pixels,
    pub line_height: gpui_kit::Pixels,
    pub color: gpui_kit::Hsla,
}

impl AnswerStyle {
    pub fn editorial(cx: &App) -> Self {
        Self {
            size: ty::BODY,
            line_height: px(22.),
            color: cx.lb().text,
        }
    }
}

/// Lays out the parsed answer. `id` must be unique in the window.
pub fn render(
    id: impl Into<ElementId>,
    answer: &Answer,
    style: AnswerStyle,
    on_cite: CiteHandler,
    cx: &App,
) -> Div {
    let id: ElementId = id.into();
    let lb = cx.lb();
    let mut column = v_flex().gap(px(10.)).w_full().min_w_0();
    for (index, block) in answer.blocks.iter().enumerate() {
        let block_id = ElementId::NamedChild(
            std::sync::Arc::new(id.clone()),
            SharedString::from(format!("block-{index}")),
        );
        let element = match block {
            Block::Paragraph(inline) => div()
                .text_align(crate::i18n::content_alignment(&inline.text))
                .w_full()
                .text_size(style.size)
                .line_height(style.line_height)
                .text_color(style.color)
                .child(styled(block_id, inline, &answer.links, on_cite.clone(), cx)),
            Block::Heading { level, inline } => {
                let size = match level {
                    1 => style.size + px(4.),
                    2 => style.size + px(2.),
                    _ => style.size + px(1.),
                };
                div()
                    .text_align(crate::i18n::content_alignment(&inline.text))
                    .w_full()
                    .pt(px(4.))
                    .text_size(size)
                    .line_height(style.line_height + px(2.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(styled(block_id, inline, &answer.links, on_cite.clone(), cx))
            }
            Block::Item {
                marker,
                depth,
                inline,
            } => h_flex()
                .text_align(crate::i18n::content_alignment(&inline.text))
                .w_full()
                .items_start()
                .pl(px(*depth as f32 * 18.))
                .gap(px(6.))
                .text_size(style.size)
                .line_height(style.line_height)
                .text_color(style.color)
                .child(
                    div()
                        .flex_none()
                        .min_w(px(16.))
                        .text_color(lb.text_secondary)
                        .child(marker.clone().unwrap_or_else(|| "•".into())),
                )
                .child(div().flex_1().min_w_0().child(styled(
                    block_id,
                    inline,
                    &answer.links,
                    on_cite.clone(),
                    cx,
                ))),
            Block::Quote(inline) => div()
                .text_align(crate::i18n::content_alignment(&inline.text))
                .w_full()
                .pl(px(12.))
                .border_l_2()
                .border_color(lb.separator)
                .text_size(style.size)
                .line_height(style.line_height)
                .text_color(lb.text_secondary)
                .child(styled(block_id, inline, &answer.links, on_cite.clone(), cx)),
            Block::Code(code) => div()
                .text_align(gpui_kit::TextAlign::Left)
                .w_full()
                .p(px(10.))
                .rounded(px(8.))
                .bg(lb.chip_fill)
                .font_family(cx.theme().mono_font_family.clone())
                .text_size(style.size - px(1.))
                .text_color(lb.text)
                .child(code.clone()),
            Block::Rule => div().w_full().my(px(4.)).h(px(1.)).bg(lb.separator),
        };
        column = column.child(element);
    }
    column
}

fn styled(
    id: ElementId,
    inline: &Inline,
    links: &[String],
    on_cite: CiteHandler,
    cx: &App,
) -> InteractiveText {
    let lb = cx.lb();
    let mono = cx.theme().mono_font_family.clone();
    let mut highlights = Vec::with_capacity(inline.segments.len());
    let mut fonts = Vec::new();
    let mut clickable: Vec<(Range<usize>, Click)> = Vec::new();
    for (range, span) in &inline.segments {
        if span == &SpanStyle::default() {
            continue;
        }
        let mut highlight = HighlightStyle::default();
        if span.bold {
            highlight.font_weight = Some(FontWeight::SEMIBOLD);
        } else if span.emphasis {
            // Inter ships without italics here; medium weight carries the emphasis.
            highlight.font_weight = Some(FontWeight::MEDIUM);
        }
        if span.code {
            highlight.background_color = Some(lb.chip_fill);
            fonts.push((range.clone(), mono.clone()));
        }
        if let Some(link) = span.link {
            highlight.color = Some(lb.accent_text);
            highlight.underline = Some(UnderlineStyle {
                thickness: px(1.),
                color: Some(lb.accent_text.opacity(0.5)),
                wavy: false,
            });
            clickable.push((
                range.clone(),
                Click::Link(links.get(link).cloned().unwrap_or_default()),
            ));
        }
        if let Some(cite) = span.cite {
            highlight.color = Some(lb.accent_text);
            highlight.font_weight = Some(FontWeight::SEMIBOLD);
            highlight.background_color = Some(lb.accent_wash);
            clickable.push((range.clone(), Click::Cite(cite)));
        }
        highlights.push((range.clone(), highlight));
    }
    let text = StyledText::new(inline.text.clone())
        .with_highlights(highlights)
        .with_font_family_overrides(fonts);
    let ranges: Vec<Range<usize>> = clickable.iter().map(|(range, _)| range.clone()).collect();
    let targets: Vec<Click> = clickable.into_iter().map(|(_, click)| click).collect();
    InteractiveText::new(id, text).on_click(ranges, move |index, window, cx| {
        match targets.get(index) {
            Some(Click::Cite(cite)) => on_cite(*cite, window, cx),
            Some(Click::Link(url)) if url.starts_with("http://") || url.starts_with("https://") => {
                cx.open_url(url)
            }
            _ => {}
        }
    })
}

enum Click {
    Cite(usize),
    Link(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_of(block: &Block) -> &str {
        match block {
            Block::Paragraph(inline) | Block::Quote(inline) => &inline.text,
            Block::Heading { inline, .. } | Block::Item { inline, .. } => &inline.text,
            Block::Code(code) => code,
            Block::Rule => "",
        }
    }

    #[test]
    fn paragraphs_lists_and_citations() {
        let answer = parse(
            "You settled it **in review** [meeting:11111111-1111-4111-8111-111111111111@0:12].\n\n- one [screen:4]\n- two\n  continued\n1. first",
        );
        assert_eq!(answer.citations.len(), 2);
        assert_eq!(answer.blocks.len(), 4);
        assert_eq!(text_of(&answer.blocks[0]), "You settled it in review [1].");
        let Block::Paragraph(inline) = &answer.blocks[0] else {
            panic!()
        };
        assert!(
            inline
                .segments
                .iter()
                .any(|(r, s)| s.bold && &inline.text[r.clone()] == "in review")
        );
        assert!(
            inline
                .segments
                .iter()
                .any(|(r, s)| s.cite == Some(0) && &inline.text[r.clone()] == "[1]")
        );
        assert_eq!(text_of(&answer.blocks[2]), "two continued");
        assert!(matches!(&answer.blocks[3], Block::Item { marker: Some(m), .. } if m == "1."));
    }

    #[test]
    fn snake_case_and_stray_markers_stay_literal() {
        let answer = parse("keep snake_case_name and 2 * 3 * 4 and `code_here`");
        let Block::Paragraph(inline) = &answer.blocks[0] else {
            panic!()
        };
        assert_eq!(
            inline.text,
            "keep snake_case_name and 2 * 3 * 4 and code_here"
        );
        assert!(inline.segments.iter().all(|(_, s)| !s.emphasis));
    }

    #[test]
    fn segments_never_overlap() {
        let answer = parse("**bold _and em_ [link](https://x.y)** tail [screen:9]");
        let Block::Paragraph(inline) = &answer.blocks[0] else {
            panic!()
        };
        let mut end = 0;
        for (range, _) in &inline.segments {
            assert!(range.start >= end);
            end = range.end;
        }
        assert_eq!(answer.links, vec!["https://x.y".to_string()]);
        assert_eq!(inline.text, "bold and em link tail [1]");
    }

    #[test]
    fn headings_rules_and_code() {
        let answer = parse("## Next steps\n---\n```\nlet x = 1;\n```\n> quoted");
        assert!(matches!(answer.blocks[0], Block::Heading { level: 2, .. }));
        assert!(matches!(answer.blocks[1], Block::Rule));
        assert_eq!(text_of(&answer.blocks[2]), "let x = 1;");
        assert!(matches!(answer.blocks[3], Block::Quote(_)));
    }
}
