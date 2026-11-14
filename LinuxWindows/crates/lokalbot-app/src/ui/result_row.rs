//! Search snippets shared by Ask and Quick Recall (`ResultRow.swift`):
//! «matched» words in bold, and no lines that only repeat the row's title.

use std::ops::Range;

use gpui_kit::{FontWeight, HighlightStyle, Hsla, StyledText};

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
