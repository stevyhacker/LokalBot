//! Search result anatomy shared by Ask and Quick Recall (`ResultRow.swift`):
//! title, date and kind chip, then a snippet whose «matched» words are bold.

use std::ops::Range;

use crate::i18n::h_flex;
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, Div, FontWeight, HighlightStyle, Hsla, ParentElement as _, SharedString, Styled as _,
    StyledText, div, px,
};

use crate::theme::{LbThemeExt as _, ty};

/// Splits an FTS snippet on «» markers (`SnippetHighlighter.segments`).
/// Returns the plain text and the byte ranges of the matched runs.
pub fn snippet_matches(snippet: &str) -> (String, Vec<Range<usize>>) {
    let mut text = String::with_capacity(snippet.len());
    let mut matches = Vec::new();
    let mut rest = snippet;
    while let Some(open) = rest.find('«') {
        text.push_str(&rest[..open]);
        rest = &rest[open + '«'.len_utf8()..];
        match rest.find('»') {
            Some(close) => {
                let start = text.len();
                text.push_str(&rest[..close]);
                if close > 0 {
                    matches.push(start..text.len());
                }
                rest = &rest[close + '»'.len_utf8()..];
            }
            None => break,
        }
    }
    text.push_str(rest);
    (text, matches)
}

/// Drops leading snippet lines that only repeat the row title and collapses
/// whitespace (`SnippetCleaner.withoutTitleEcho`). Markers survive.
pub fn without_title_echo(snippet: &str, title: &str) -> Option<String> {
    fn normalize(text: &str) -> String {
        text.replace(['«', '»', '…'], "")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase()
    }
    fn echoes(line: &str, title: &str) -> bool {
        if line.is_empty() || line == title {
            return true;
        }
        let shortest = line.chars().count().min(title.chars().count());
        shortest >= 12 && (title.contains(line) || line.contains(title))
    }
    let title = normalize(title);
    let mut lines: Vec<&str> = snippet
        .split('\n')
        .filter(|l| !l.trim().is_empty())
        .collect();
    if !title.is_empty() {
        while lines
            .first()
            .is_some_and(|first| echoes(&normalize(first), &title))
        {
            lines.remove(0);
        }
    }
    let joined = lines
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (!joined.is_empty()).then_some(joined)
}

/// A snippet with bold matches in `emphasis` over `base` text.
pub fn highlighted(snippet: &str, emphasis: Hsla) -> StyledText {
    let (text, matches) = snippet_matches(snippet);
    let highlights = matches.into_iter().map(|range| {
        (
            range,
            HighlightStyle {
                font_weight: Some(FontWeight::BOLD),
                color: Some(emphasis),
                ..Default::default()
            },
        )
    });
    StyledText::new(text).with_highlights(highlights.collect::<Vec<_>>())
}

/// Compact capsule for a result kind ("Summary", "▶ 00:12:04 · Maya").
pub fn kind_chip(label: impl Into<SharedString>, cx: &App) -> Div {
    let lb = cx.lb();
    div()
        .flex_none()
        .px(px(8.))
        .py(px(2.))
        .rounded_full()
        .bg(lb.chip_fill)
        .text_size(ty::SMALL)
        .font_weight(FontWeight::MEDIUM)
        .text_color(lb.text_secondary)
        .whitespace_nowrap()
        .child(label.into())
}

/// The body of an Ask meeting result.
pub fn result_body(
    title: SharedString,
    date: Option<SharedString>,
    kind: SharedString,
    match_label: Option<SharedString>,
    snippet: &str,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    v_flex()
        .gap(px(3.))
        .w_full()
        .min_w_0()
        .child(
            h_flex()
                .gap(px(6.))
                .items_center()
                .min_w_0()
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(title),
                )
                .when_some(date, |this, date| {
                    this.child(
                        div()
                            .flex_none()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .child(date),
                    )
                })
                .child(div().flex_1().min_w_0())
                .child(kind_chip(kind, cx)),
        )
        .when_some(match_label, |this, label| {
            this.child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(label),
            )
        })
        .when(!snippet.trim().is_empty(), |this| {
            this.child(
                div()
                    .text_size(ty::SECONDARY)
                    .line_height(px(19.))
                    .text_color(lb.supporting)
                    .line_clamp(3)
                    .child(highlighted(snippet, lb.text)),
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_matches() {
        let (text, matches) = snippet_matches("Every «captions» and «audio» track");
        assert_eq!(text, "Every captions and audio track");
        assert_eq!(&text[matches[0].clone()], "captions");
        assert_eq!(&text[matches[1].clone()], "audio");
        let (text, matches) = snippet_matches("open « only");
        assert_eq!(text, "open  only");
        assert!(matches.is_empty());
    }

    #[test]
    fn drops_title_echo_lines() {
        let cleaned = without_title_echo(
            "Delivery checklist\nEvery client video ships with «captions».",
            "Delivery checklist",
        );
        assert_eq!(
            cleaned.as_deref(),
            Some("Every client video ships with «captions».")
        );
        assert_eq!(without_title_echo("Pages\n", "Pages"), None);
    }
}
