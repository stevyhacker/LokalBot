//! What one accept key press takes (`CotypingAcceptanceChunker`) and the
//! exact edit it makes (`CotypingContinuationAcceptance`).

use unicode_segmentation::UnicodeSegmentation as _;

use lokalbot_core::settings::AcceptGranularity;

use super::emoji;
use super::text::{
    begins_spaceless_word, binds_to_preceding_spaceless_word, char_before,
    is_cjk_closing_punctuation, is_cjk_opening_bracket, is_cjk_sentence_terminator,
    is_phrase_clause_boundary, is_terminal_period, is_url_domain_or_file, is_url_like,
    is_word_char,
};
use super::window;

/// The acceptance settings that shape a press (`Options`). The defaults are
/// the macOS ones; this port has no settings for the last two.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AcceptOptions {
    pub granularity: AcceptGranularity,
    /// Punctuation after a word goes with it in the same press. Off, as in
    /// Cotypist: a full stop or comma takes its own press.
    pub auto_accept_trailing_punctuation: bool,
    /// Add a space after a suggestion's last word.
    pub add_space_after_accept: bool,
}

impl Default for AcceptOptions {
    fn default() -> Self {
        Self {
            granularity: AcceptGranularity::Word,
            auto_accept_trailing_punctuation: false,
            add_space_after_accept: false,
        }
    }
}

/// Which key was pressed: the next chunk, or the whole remaining suggestion.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AcceptScope {
    Chunk,
    Whole,
}

/// One accept press, planned once for the desktop's accept key and the
/// practice editor alike.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AcceptancePlan {
    /// The part of the suggestion this press consumes; report it back in
    /// `AutocompleteCommand::Accepted`.
    pub chunk: String,
    /// What to type at the caret: the chunk without a space the field
    /// already has, with the space a new sentence needs.
    pub insertion: String,
    /// User-perceived characters after the caret the insertion replaces,
    /// when it completes a word the caret is inside of.
    pub forward_delete: usize,
    /// User-perceived characters before the caret the insertion replaces:
    /// the typed `:shortcode` an emoji stands for.
    pub backward_delete: usize,
}

/// `CotypingContinuationAcceptance.plan` plus the emoji replacement of
/// `CotypingReplacementAcceptancePlanner`. `None` when nothing is accepted.
pub fn plan(
    suggestion: &str,
    scope: AcceptScope,
    before: &str,
    after: &str,
    options: AcceptOptions,
) -> Option<AcceptancePlan> {
    if suggestion.is_empty() {
        return None;
    }
    // An emoji replaces the shortcode typed before it, whole or not at all.
    if let Some(hit) = emoji::match_trailing(before)
        && hit.glyph == suggestion
    {
        return Some(AcceptancePlan {
            chunk: suggestion.to_string(),
            insertion: suggestion.to_string(),
            forward_delete: 0,
            backward_delete: hit.typed_length,
        });
    }
    let base = match scope {
        AcceptScope::Whole => suggestion.to_string(),
        AcceptScope::Chunk => match options.granularity {
            AcceptGranularity::Word => {
                next_word(suggestion, options.auto_accept_trailing_punctuation).to_string()
            }
            AcceptGranularity::Phrase => {
                next_phrase(suggestion, options.auto_accept_trailing_punctuation)
            }
        },
    };
    let chunk = if options.add_space_after_accept {
        chunk_consuming_trailing_space(&base, suggestion)
    } else {
        base
    };
    if chunk.is_empty() {
        return None;
    }
    let mut insertion = insertion_chunk(&chunk, before);
    if options.add_space_after_accept && chunk.len() == suggestion.len() {
        insertion = appending_trailing_space(&insertion);
    }
    let forward_delete = if window::should_force_continuation(before, after) {
        window::accepted_trailing_overlap(&insertion, after)
    } else {
        0
    };
    Some(AcceptancePlan {
        chunk,
        insertion,
        forward_delete,
        backward_delete: 0,
    })
}

/// The first word-like chunk of `text`, keeping its leading whitespace.
/// Scripts without spaces advance one UAX #29 word at a time (macOS uses
/// ICU's dictionary words), with CJK punctuation bound to the word before it.
pub fn next_word(text: &str, auto_accept_trailing_punctuation: bool) -> &str {
    if text.is_empty() {
        return "";
    }
    let token_start = text.len() - text.trim_start().len();
    let token_end = text[token_start..]
        .find(char::is_whitespace)
        .map_or(text.len(), |i| token_start + i);
    let mut end = token_end;
    if token_start < token_end {
        let first = text[token_start..].chars().next().unwrap_or(' ');
        if begins_spaceless_word(first) {
            let word_end = text[token_start..token_end]
                .split_word_bound_indices()
                .next()
                .map_or(token_end, |(i, w)| token_start + i + w.len());
            end = end_of_cjk_punctuation_run(text, word_end, token_end, false);
        } else if binds_to_preceding_spaceless_word(first) || is_cjk_opening_bracket(first) {
            end = end_of_cjk_punctuation_run(text, token_start, token_end, true);
        }
    }
    if !auto_accept_trailing_punctuation
        && let Some(word_end) = word_end_trimming_trailing_punctuation(text, token_start, end)
    {
        end = word_end;
    }
    &text[..end]
}

/// Up to and including the next sentence or clause boundary, or the whole
/// text when there is none. ASCII commas stay inside the phrase.
pub fn next_phrase(text: &str, auto_accept_trailing_punctuation: bool) -> String {
    let mut accumulated = String::new();
    let mut working = text;
    while !working.is_empty() {
        let chunk = next_word(working, auto_accept_trailing_punctuation);
        if chunk.is_empty() {
            break;
        }
        if let Some(newline) = chunk.find('\n') {
            accumulated.push_str(&chunk[..=newline]);
            return accumulated;
        }
        accumulated.push_str(chunk);
        working = &working[chunk.len()..];
        if ends_at_phrase_boundary(&accumulated) {
            return accumulated;
        }
    }
    accumulated
}

fn end_of_cjk_punctuation_run(text: &str, from: usize, limit: usize, openers: bool) -> usize {
    let mut end = from;
    for c in text[from..limit].chars() {
        if !(binds_to_preceding_spaceless_word(c) || (openers && is_cjk_opening_bracket(c))) {
            break;
        }
        end += c.len_utf8();
    }
    end
}

fn ends_at_phrase_boundary(text: &str) -> bool {
    let body = text.trim_end_matches(|c: char| c == ' ' || c == '\t' || is_phrase_closing(c));
    let Some(last) = body.chars().next_back() else {
        return false;
    };
    if is_phrase_clause_boundary(last) {
        return true;
    }
    match last {
        '.' => is_terminal_period(body, body.len() - 1),
        '!' | '?' => true,
        c => is_cjk_sentence_terminator(c),
    }
}

fn is_phrase_closing(c: char) -> bool {
    matches!(c, '"' | '\'' | '\u{201D}' | '\u{2019}' | ')' | ']' | '}')
        || is_cjk_closing_punctuation(c)
}

fn word_end_trimming_trailing_punctuation(text: &str, start: usize, end: usize) -> Option<usize> {
    let last_word_end = text[start..end]
        .char_indices()
        .rev()
        .find(|(_, c)| is_word_char(*c))
        .map(|(i, c)| start + i + c.len_utf8())?;
    (last_word_end < end).then_some(last_word_end)
}

/// The chunk as typed: a leading space the field already has is not typed
/// twice, and a new sentence gets its separating space.
pub fn insertion_chunk(chunk: &str, before: &str) -> String {
    let after_space = before
        .chars()
        .next_back()
        .is_some_and(|c| c == '\t' || (c.is_whitespace() && !super::text::is_newline(c)));
    let chunk = if after_space {
        chunk.trim_start_matches(|c: char| {
            c == '\t' || (c.is_whitespace() && !super::text::is_newline(c))
        })
    } else {
        chunk
    };
    prefixing_sentence_boundary_space(chunk, before)
}

fn prefixing_sentence_boundary_space(chunk: &str, before: &str) -> String {
    let (Some(first), Some(last)) = (chunk.chars().next(), before.chars().next_back()) else {
        return chunk.to_string();
    };
    if !is_word_char(first) || begins_spaceless_word(first) || !matches!(last, '.' | '!' | '?') {
        return chunk.to_string();
    }
    if last == '.' && keeps_dot_attached(before, first, chunk) {
        return chunk.to_string();
    }
    format!(" {chunk}")
}

fn keeps_dot_attached(before: &str, next: char, chunk: &str) -> bool {
    let dot = before.len() - 1;
    if let Some(before_dot) = char_before(before, dot) {
        if before_dot.is_numeric() && next.is_numeric() {
            return true;
        }
        // "U." + "S": a dotted initialism goes on.
        if next.is_uppercase() && super::text::trailing_letters(before, dot).chars().count() == 1 {
            return true;
        }
    }
    let suffix_start = before
        .char_indices()
        .rev()
        .take_while(|(_, c)| is_url_like(*c))
        .last()
        .map_or(before.len(), |(i, _)| i);
    let prefix_end = chunk
        .char_indices()
        .find(|(_, c)| !is_url_like(*c))
        .map_or(chunk.len(), |(i, _)| i);
    is_url_domain_or_file(&format!(
        "{}{}",
        &before[suffix_start..],
        &chunk[..prefix_end]
    ))
}

/// `acceptanceChunkConsumingTrailingSpace`: with the trailing-space option the
/// model's own space after a finished word goes with it.
pub fn chunk_consuming_trailing_space(chunk: &str, remaining: &str) -> String {
    let Some(last) = chunk.chars().next_back() else {
        return chunk.to_string();
    };
    if !is_word_char(last) || begins_spaceless_word(last) {
        return chunk.to_string();
    }
    let rest = remaining.get(chunk.len()..).unwrap_or("");
    let spaces = rest.len() - rest.trim_start_matches([' ', '\t']).len();
    format!("{chunk}{}", &rest[..spaces])
}

fn appending_trailing_space(chunk: &str) -> String {
    match chunk.chars().next_back() {
        Some(last) if is_word_char(last) && !begins_spaceless_word(last) => format!("{chunk} "),
        _ => chunk.to_string(),
    }
}

/// Words with at least one letter or digit (`acceptedWordCount`).
pub fn accepted_word_count(text: &str) -> usize {
    text.split_whitespace()
        .filter(|w| w.chars().any(|c| c.is_alphanumeric()))
        .count()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn word(text: &str) -> &str {
        next_word(text, true)
    }

    #[test]
    fn latin_words() {
        assert_eq!(word("hello world"), "hello");
        assert_eq!(word("don't stop now"), "don't");
        assert_eq!(word("U.S.A today"), "U.S.A");
        assert_eq!(word("1.5 times"), "1.5");
        assert_eq!(word("caf\u{e9} Ren\u{e9}"), "caf\u{e9}");
        assert_eq!(word("world \u{4f60}\u{597d}"), "world");
    }

    #[test]
    fn trailing_punctuation_takes_its_own_press_by_default() {
        assert_eq!(next_word("you?", false), "you");
        assert_eq!(next_word("?!", false), "?!");
        assert_eq!(next_word("U.S.A.", false), "U.S.A");
        assert_eq!(next_word(" don't!", false), " don't");
    }

    #[test]
    fn spaceless_scripts_advance_by_a_word_with_their_punctuation() {
        for run in [
            "\u{4f60}\u{597d}\u{4e16}\u{754c}",
            "\u{4eca}\u{65e5}\u{306f}\u{3044}\u{3044}\u{5929}\u{6c17}\u{3067}\u{3059}",
            "\u{0e2a}\u{0e27}\u{0e31}\u{0e2a}\u{0e14}\u{0e35}\u{0e04}\u{0e23}\u{0e31}\u{0e1a}",
        ] {
            let chunk = word(run);
            assert!(
                !chunk.is_empty() && run.starts_with(chunk) && chunk.len() < run.len(),
                "{run}"
            );
        }
        // UAX #29 words are one ideograph; CJK punctuation stays with the word.
        assert_eq!(word("\u{6599}\u{3001}\u{5185}\u{5bb9}"), "\u{6599}\u{3001}");
        assert_eq!(
            word("\u{3001}\u{7406}\u{89e3}\u{3057}\u{3001}\u{305d}\u{306e}\u{5185}\u{5bb9}"),
            "\u{3001}"
        );
        assert_eq!(
            word("\u{3002}\u{300d}\u{6b21}\u{306e}\u{6587}"),
            "\u{3002}\u{300d}"
        );
        assert_eq!(
            word(
                "\u{300c}\u{5206}\u{304b}\u{3063}\u{305f}\u{300d}\u{3068}\u{8a00}\u{3063}\u{305f}"
            ),
            "\u{300c}"
        );
    }

    #[test]
    fn phrases_stop_at_sentences_newlines_and_cjk_clauses() {
        let phrase = |t: &str| next_phrase(t, true);
        assert_eq!(phrase("Hi Sarah, thanks."), "Hi Sarah, thanks.");
        assert_eq!(phrase("the quick brown"), "the quick brown");
        assert_eq!(phrase("done. next thing"), "done.");
        assert_eq!(phrase("done\nnext thing"), "done\n");
        assert_eq!(
            phrase("\u{8cc7}\u{6599}\u{3092}\u{8aad}\u{307f}\u{3001}\u{6b21}\u{3078}"),
            "\u{8cc7}\u{6599}\u{3092}\u{8aad}\u{307f}\u{3001}"
        );
        assert_eq!(
            phrase("\u{4f60}\u{597d}\u{3002}\u{518d}\u{89c1}"),
            "\u{4f60}\u{597d}\u{3002}"
        );
        assert_eq!(phrase("U.S.A. is great."), "U.S.A. is great.");
        assert_eq!(phrase("version 1.2 is ready."), "version 1.2 is ready.");
        assert_eq!(
            phrase("for example, e.g. this one."),
            "for example, e.g. this one."
        );
        assert_eq!(phrase("item 1. next"), "item 1. next");
        assert_eq!(next_phrase("you? Yes.", true), "you?");
        assert_eq!(next_phrase("you? Yes.", false), "you?");
    }

    #[test]
    fn insertion_spacing() {
        assert_eq!(insertion_chunk(" world", "hello "), "world");
        assert_eq!(insertion_chunk(" world", "hello"), " world");
        assert_eq!(insertion_chunk("Next", "done."), " Next");
        assert_eq!(insertion_chunk("Next", "done!"), " Next");
        assert_eq!(insertion_chunk("Next", "done?"), " Next");
        assert_eq!(insertion_chunk(" Next", "done."), " Next");
        assert_eq!(insertion_chunk("2", "version 1."), "2");
        assert_eq!(insertion_chunk("S", "U."), "S");
        assert_eq!(insertion_chunk("com", "example."), "com");
        assert_eq!(insertion_chunk("env", "."), "env");
        assert_eq!(
            chunk_consuming_trailing_space("hello", "hello world"),
            "hello "
        );
        assert_eq!(
            chunk_consuming_trailing_space("hello", "helloworld"),
            "hello"
        );
        assert_eq!(
            chunk_consuming_trailing_space("\u{8cc7}\u{6599}", "\u{8cc7}\u{6599} \u{5185}\u{5bb9}"),
            "\u{8cc7}\u{6599}"
        );
    }

    fn plan_chunk(suggestion: &str, before: &str) -> Option<AcceptancePlan> {
        plan(
            suggestion,
            AcceptScope::Chunk,
            before,
            "",
            AcceptOptions::default(),
        )
    }

    #[test]
    fn a_press_takes_one_word_or_phrase_and_the_full_key_takes_all() {
        let word = plan_chunk(" up on the timeline.", "I wanted to follow").unwrap();
        assert_eq!(
            (word.chunk.as_str(), word.insertion.as_str()),
            (" up", " up")
        );
        assert_eq!(word.forward_delete, 0);
        let phrase = plan(
            " up tomorrow. Then we plan.",
            AcceptScope::Chunk,
            "I will follow",
            "",
            AcceptOptions {
                granularity: AcceptGranularity::Phrase,
                ..AcceptOptions::default()
            },
        )
        .unwrap();
        assert_eq!(phrase.chunk, " up tomorrow.");
        for granularity in [AcceptGranularity::Word, AcceptGranularity::Phrase] {
            let all = plan(
                " up on the timeline.",
                AcceptScope::Whole,
                "I wanted to follow",
                "",
                AcceptOptions {
                    granularity,
                    ..AcceptOptions::default()
                },
            )
            .unwrap();
            assert_eq!(all.chunk, " up on the timeline.");
        }
    }

    #[test]
    fn spacing_and_punctuation_follow_the_options() {
        assert_eq!(
            plan_chunk(" world again", "Hello ").unwrap().insertion,
            "world"
        );
        assert_eq!(plan_chunk("Next step", "Done.").unwrap().insertion, " Next");
        assert_eq!(plan_chunk(" yes, please", "I say").unwrap().chunk, " yes");
        let attached = AcceptOptions {
            auto_accept_trailing_punctuation: true,
            ..AcceptOptions::default()
        };
        assert_eq!(
            plan(" yes, please", AcceptScope::Chunk, "I say", "", attached)
                .unwrap()
                .chunk,
            " yes,"
        );
        let spaced = AcceptOptions {
            add_space_after_accept: true,
            ..AcceptOptions::default()
        };
        assert_eq!(
            plan(" soon", AcceptScope::Chunk, "See you", "", spaced)
                .unwrap()
                .insertion,
            " soon "
        );
        assert_eq!(
            plan(" very soon", AcceptScope::Chunk, "See you", "", spaced)
                .unwrap()
                .insertion,
            " very "
        );
    }

    #[test]
    fn completing_a_word_replaces_its_typed_tail() {
        let plan = plan(
            "ld peace",
            AcceptScope::Whole,
            "Hello wor",
            "ld!",
            AcceptOptions::default(),
        )
        .unwrap();
        assert_eq!(plan.insertion, "ld peace");
        assert_eq!(plan.forward_delete, 2);
        assert_eq!(plan_chunk("", "follow up"), None);
    }

    #[test]
    fn an_emoji_replaces_its_shortcode() {
        let rocket = plan_chunk("🚀", "Launch day :roc").unwrap();
        assert_eq!(rocket.chunk, "🚀");
        assert_eq!(rocket.insertion, "🚀");
        assert_eq!(rocket.backward_delete, 4);
        assert_eq!(
            plan_chunk("🚀", "Launch day :rocket:")
                .unwrap()
                .backward_delete,
            8
        );
        // Another glyph, or no shortcode, is an ordinary continuation.
        assert_eq!(
            plan_chunk("🎉", "Launch day :roc").unwrap().backward_delete,
            0
        );
        assert_eq!(plan_chunk("🚀", "Launch day").unwrap().backward_delete, 0);
    }

    /// Accepting piece by piece reproduces the suggestion exactly, for
    /// accents, emoji, punctuation runs and scripts written without spaces.
    #[test]
    fn accepting_piece_by_piece_reproduces_the_suggestion() {
        for suggestion in [
            " up on the migration timeline we scoped yesterday.",
            " café — déjà vu, naïve 🙂.",
            " („Zitat“) – fertig!",
            "明天见面。然后再讨论。",
            " one\ttwo  three",
        ] {
            for granularity in [AcceptGranularity::Word, AcceptGranularity::Phrase] {
                let options = AcceptOptions {
                    granularity,
                    ..AcceptOptions::default()
                };
                let mut text = "Notes".to_string();
                let mut remaining = suggestion;
                let mut presses = 0;
                while !remaining.is_empty() {
                    let step = plan(remaining, AcceptScope::Chunk, &text, "", options)
                        .unwrap_or_else(|| panic!("{suggestion} stalled at {remaining}"));
                    text.push_str(&step.insertion);
                    remaining = &remaining[step.chunk.len()..];
                    presses += 1;
                    assert!(presses < 40);
                }
                assert_eq!(text, format!("Notes{suggestion}"), "{granularity:?}");
                if granularity == AcceptGranularity::Word && suggestion.contains(" on ") {
                    assert!(presses > 3, "one word per press");
                }
            }
        }
    }

    #[test]
    fn counts_accepted_words() {
        assert_eq!(accepted_word_count(" up on — the"), 3);
    }
}
