// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! How much of the text before the caret a request reads
//! (`CotypingPrefixWindow`), and the word the caret sits in
//! (`CotypingMidWord`).

use super::text::{grapheme_count, is_word_char};

/// Generate only when there is something besides whitespace before the caret.
pub fn should_generate(before: &str) -> bool {
    !before.trim().is_empty()
}

/// The latest text, bounded by characters and words, without rewriting
/// paragraph breaks, list indentation or the whitespace at the caret.
///
/// A window cut from longer text starts at a sentence or line boundary near
/// its front: the server keeps what it has read of an unchanged prompt
/// start, and a window that moved by one character per keystroke would make
/// it read the whole window again every time.
pub fn truncated_prefix(before: &str, max_characters: usize, max_words: usize) -> String {
    if max_characters == 0 || max_words == 0 {
        return String::new();
    }
    let total = before.chars().count();
    let mut start = if total > max_characters {
        before
            .char_indices()
            .nth(total - max_characters)
            .map_or(0, |(i, _)| i)
    } else {
        0
    };
    let word_starts = word_start_offsets(&before[start..]);
    if word_starts.len() > max_words {
        start += word_starts[word_starts.len() - max_words];
    }
    let window = &before[start..];
    if window.len() == before.len() {
        return window.to_string();
    }
    window[stable_start(window)..].to_string()
}

/// Byte offsets where whitespace-separated words start.
fn word_start_offsets(text: &str) -> Vec<usize> {
    let mut starts = Vec::new();
    let mut in_word = false;
    for (i, c) in text.char_indices() {
        if c.is_whitespace() {
            in_word = false;
        } else if !in_word {
            starts.push(i);
            in_word = true;
        }
    }
    starts
}

/// Just after the first line break or sentence end in the front quarter of
/// `window`, or 0 when there is none.
fn stable_start(window: &str) -> usize {
    let chars: Vec<(usize, char)> = window.char_indices().collect();
    let front = chars.len() / 4;
    for index in 0..front {
        let (_, c) = chars[index];
        let next = chars.get(index + 1);
        if c == '\n' {
            return next.map_or(window.len(), |(i, _)| *i);
        }
        // A full stop after a letter ends a sentence; "1. " numbers a list.
        if ".?!".contains(c)
            && next.is_some_and(|(_, n)| *n == ' ')
            && index > 0
            && super::text::is_letter(chars[index - 1].1)
        {
            return chars.get(index + 2).map_or(window.len(), |(i, _)| *i);
        }
    }
    0
}

/// True only when the caret is strictly inside a word, with a letter or
/// digit on both sides. At a word end, ordinary next-word prediction (which
/// wants a leading space) is left alone, as in Cotabby.
pub fn should_force_continuation(before: &str, after: &str) -> bool {
    before.chars().next_back().is_some_and(is_word_char)
        && after.chars().next().is_some_and(is_word_char)
}

/// The run of word characters the caret sits at the end of ("" at a word
/// boundary).
pub fn current_partial_word(before: &str) -> &str {
    let start = before
        .char_indices()
        .rev()
        .take_while(|(_, c)| is_word_char(*c))
        .last()
        .map_or(before.len(), |(i, _)| i);
    &before[start..]
}

pub fn leading_word_run(text: &str) -> &str {
    let end = text
        .char_indices()
        .find(|(_, c)| !is_word_char(*c))
        .map_or(text.len(), |(i, _)| i);
    &text[..end]
}

/// How many characters to the right of the caret a forced mid-word accept
/// replaces. Only an overlap that completes the accepted word fragment or
/// the word fragment on the right counts, so a weak shared first letter
/// ("operate" against "ord") is left alone. Counted in user-perceived
/// characters.
pub fn accepted_trailing_overlap(accepted: &str, after: &str) -> usize {
    let accepted_word: Vec<char> = leading_word_run(accepted).chars().collect();
    let trailing = leading_word_run(after);
    let trailing_word: Vec<char> = trailing.chars().collect();
    if accepted_word.is_empty() || trailing_word.is_empty() {
        return 0;
    }
    let common = accepted_word
        .iter()
        .zip(&trailing_word)
        .take_while(|(a, b)| a == b)
        .count();
    if common != accepted_word.len().min(trailing_word.len()) {
        return 0;
    }
    let end = trailing
        .char_indices()
        .nth(common)
        .map_or(trailing.len(), |(i, _)| i);
    grapheme_count(&trailing[..end])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn should_generate_requires_non_whitespace() {
        assert!(!should_generate("   \n"));
        assert!(should_generate("hi"));
    }

    #[test]
    fn keeps_trailing_words_and_characters() {
        assert_eq!(truncated_prefix("one two three four", 100, 2), "three four");
        assert_eq!(truncated_prefix(&"a".repeat(50), 5, 10), "aaaaa");
        assert_eq!(truncated_prefix("hello", 0, 3), "");
        assert_eq!(truncated_prefix("hello", 3, 0), "");
    }

    #[test]
    fn preserves_paragraphs_lists_and_caret_indentation() {
        let text = "Hi Ana,\n\nNext steps:\n  1. Review\n  2. ";
        assert_eq!(truncated_prefix(text, 2500, 500), text);
        assert_eq!(truncated_prefix(text, 2500, 3), "1. Review\n  2. ");
    }

    /// Typing on at the end of a long draft keeps the window's start in place.
    #[test]
    fn a_long_drafts_window_start_stays_put_while_typing() {
        let sentence = "We reviewed the onboarding funnel again this week. ";
        let draft = sentence.repeat(80) + "The next step is to share";
        let mut starts = std::collections::HashSet::new();
        for typed in ["", " t", " the", " the res", " the results"] {
            let window = truncated_prefix(&(draft.clone() + typed), 2500, 500);
            assert!(window.starts_with("We reviewed"), "{window:.40}");
            assert!(window.ends_with(&format!("share{typed}")));
            assert!(window.chars().count() <= 2500);
            starts.insert(window.chars().take(200).collect::<String>());
        }
        assert_eq!(starts.len(), 1);
    }

    #[test]
    fn production_window_keeps_earlier_document_facts() {
        let text =
            "Release owner: Irena.\n\n".to_string() + &"reviewed item ".repeat(100) + "\nAsk ";
        assert_eq!(truncated_prefix(&text, 2500, 500), text);
    }

    #[test]
    fn forces_continuation_only_strictly_inside_a_word() {
        assert!(should_force_continuation("rec", "eive"));
        assert!(!should_force_continuation("rec", ""));
        assert!(!should_force_continuation("rec", " more"));
        assert!(!should_force_continuation("rec", "."));
        assert!(!should_force_continuation("rec ", "x"));
        assert!(!should_force_continuation("", "x"));
    }

    #[test]
    fn current_partial_word_is_the_run_at_the_caret() {
        assert_eq!(current_partial_word("I want to rec"), "rec");
        assert_eq!(current_partial_word("I want to "), "");
        assert_eq!(current_partial_word("price is 42"), "42");
        assert_eq!(current_partial_word("end."), "");
    }

    #[test]
    fn accepted_overlap_deletes_only_a_real_fragment() {
        assert_eq!(accepted_trailing_overlap("ord", "ord"), 3);
        assert_eq!(accepted_trailing_overlap("ording", "ord"), 3);
        assert_eq!(accepted_trailing_overlap("or", "ord"), 2);
        assert_eq!(accepted_trailing_overlap("operate", "ord"), 0);
        assert_eq!(accepted_trailing_overlap("ld peace", "ld!"), 2);
    }
}
