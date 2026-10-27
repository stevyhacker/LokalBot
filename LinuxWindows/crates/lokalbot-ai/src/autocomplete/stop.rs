//! `CotypingDecodeStopPolicy`: where a streamed completion stops early, at
//! the same visible boundary the in-process macOS runtime stops its decode.

use super::normalize::STOP_MARKERS;
use super::text::{is_cjk_closing_punctuation, is_terminal_period};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StopReason {
    SentenceBoundary,
    ScaffoldingMarker,
}

/// A chat control token stops at once; a sentence end once two tokens are in.
pub fn verdict(accumulated: &str, tokens_generated: usize) -> Option<StopReason> {
    verdict_with_minimum(accumulated, tokens_generated, 2)
}

pub fn verdict_with_minimum(
    accumulated: &str,
    tokens_generated: usize,
    minimum_tokens: usize,
) -> Option<StopReason> {
    if accumulated.contains('<') && STOP_MARKERS.iter().any(|m| accumulated.contains(m)) {
        return Some(StopReason::ScaffoldingMarker);
    }
    if tokens_generated < minimum_tokens {
        return None;
    }
    ends_sentence(accumulated).then_some(StopReason::SentenceBoundary)
}

/// `CotypingSentenceBoundary.endsSentence`: `!`, `?`, a CJK terminator, or a
/// period that ends a sentence, optionally followed by closing quotes or
/// brackets and whitespace.
pub fn ends_sentence(text: &str) -> bool {
    let body = text.trim_end();
    let body = body.trim_end_matches(is_sentence_closing_punctuation);
    let Some(last) = body.chars().next_back() else {
        return false;
    };
    match last {
        '!' | '?' => true,
        '\u{3002}' | '\u{FF01}' | '\u{FF1F}' | '\u{FF61}' | '\u{0964}' | '\u{0965}' => true,
        '.' => is_terminal_period(body, body.len() - 1),
        _ => false,
    }
}

fn is_sentence_closing_punctuation(c: char) -> bool {
    matches!(c, '"' | '\'' | ')' | ']' | '}' | '\u{201D}' | '\u{2019}')
        || is_cjk_closing_punctuation(c)
        || matches!(
            c,
            '\u{3015}'
                | '\u{3017}'
                | '\u{3019}'
                | '\u{301B}'
                | '\u{FF3D}'
                | '\u{FF5D}'
                | '\u{FF60}'
                | '\u{3001}'
                | '\u{FF0C}'
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stops_after_a_sentence_once_enough_tokens_arrived() {
        assert_eq!(
            verdict(" up with the final numbers today.", 4),
            Some(StopReason::SentenceBoundary)
        );
        assert_eq!(verdict(" today.", 1), None);
        assert_eq!(verdict(" to review e.g.", 4), None);
        assert_eq!(verdict(" by version 1.2", 4), None);
        assert_eq!(
            verdict(" it works!\" ", 4),
            Some(StopReason::SentenceBoundary)
        );
    }

    #[test]
    fn stops_on_scaffolding_without_waiting() {
        assert_eq!(
            verdict("<end_of_turn>", 1),
            Some(StopReason::ScaffoldingMarker)
        );
    }
}
