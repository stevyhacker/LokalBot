pub mod accept;
pub mod client;
pub mod clipboard;
pub mod confidence;
pub mod debounce;
pub mod emoji;
pub mod healing;
pub mod learning;
pub mod macros;
pub mod memory;
pub mod normalize;
pub mod prompt;
pub mod seam;
pub mod server;
pub mod session;
pub mod stop;
pub mod surface;
mod text;
pub mod typo;
pub mod window;
pub mod window_text;

pub use accept::{AcceptOptions, AcceptScope, AcceptancePlan};
pub use client::{Cancelled, Completer, Completion, Timings};
pub use normalize::{Normalized, Suppression};
pub use prompt::{Extras, Field, Personalization, Request, build_request};
pub use session::{Reconciled, Session, SuggestionKind, inline_after};

pub fn accept_chunk(suggestion: &str, options: AcceptOptions) -> String {
    match options.granularity {
        lokalbot_core::settings::AcceptGranularity::Word => {
            accept::next_word(suggestion, options.auto_accept_trailing_punctuation).to_string()
        }
        lokalbot_core::settings::AcceptGranularity::Phrase => {
            accept::next_phrase(suggestion, options.auto_accept_trailing_punctuation)
        }
    }
}

pub fn plan_acceptance(
    suggestion: &str,
    kind: &SuggestionKind,
    scope: AcceptScope,
    before: &str,
    after: &str,
    options: AcceptOptions,
) -> Option<AcceptancePlan> {
    match kind {
        SuggestionKind::Continuation | SuggestionKind::Emoji => {
            accept::plan(suggestion, scope, before, after, options)
        }
        SuggestionKind::Macro { query, .. } => {
            if macros::trailing_query(before).as_deref() != Some(query.as_str()) {
                return None;
            }
            Some(AcceptancePlan {
                chunk: suggestion.to_string(),
                insertion: suggestion.to_string(),
                forward_delete: 0,
                backward_delete: macros::trailing_token_length(before)?,
            })
        }
        SuggestionKind::Correction { typo } => {
            let plan = typo::correction_plan(before, typo, suggestion)?;
            Some(AcceptancePlan {
                chunk: suggestion.to_string(),
                insertion: plan.replacement,
                forward_delete: 0,
                backward_delete: plan.deleting_characters,
            })
        }
    }
}

pub fn emoji_ghost(before: &str, suggestion: &str) -> Option<String> {
    emoji::ghost(before, suggestion)
}

pub fn is_right_to_left(before: &str) -> bool {
    const RTL: [(u32, u32); 4] = [
        (0x0590, 0x08FF),
        (0xFB1D, 0xFDFF),
        (0xFE70, 0xFEFF),
        (0x200F, 0x200F),
    ];
    const LTR: [(u32, u32); 7] = [
        (0x41, 0x5A),
        (0x61, 0x7A),
        (0xC0, 0x24F),
        (0x370, 0x3FF),
        (0x400, 0x4FF),
        (0x4E00, 0x9FFF),
        (0x200E, 0x200E),
    ];
    let within =
        |ranges: &[(u32, u32)], code: u32| ranges.iter().any(|(a, b)| (*a..=*b).contains(&code));
    for c in before.chars().rev() {
        let code = u32::from(c);
        if within(&RTL, code) {
            return true;
        }
        if within(&LTR, code) {
            return false;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::settings::AcceptGranularity;

    #[test]
    fn one_tab_takes_a_word_or_a_phrase() {
        let word = AcceptOptions::default();
        let phrase = AcceptOptions {
            granularity: AcceptGranularity::Phrase,
            ..word
        };
        let with_punctuation = AcceptOptions {
            auto_accept_trailing_punctuation: true,
            ..word
        };
        assert_eq!(accept_chunk(" up on the timeline.", word), " up");
        assert_eq!(accept_chunk(" yes, please", word), " yes");
        assert_eq!(accept_chunk(" yes, please", with_punctuation), " yes,");
        assert_eq!(accept_chunk(",", word), ",");
        assert_eq!(
            accept_chunk(" up tomorrow. Then we plan.", phrase),
            " up tomorrow."
        );
        assert_eq!(accept_chunk("🚀", word), "🚀");
        assert_eq!(accept_chunk("", word), "");
    }

    #[test]
    fn plans_cover_spacing_mid_word_and_emoji() {
        let word = AcceptOptions::default();
        let plan = plan_acceptance(
            " world",
            &SuggestionKind::Continuation,
            AcceptScope::Chunk,
            "Hello ",
            "",
            word,
        )
        .unwrap();
        assert_eq!(
            (plan.chunk.as_str(), plan.insertion.as_str()),
            (" world", "world")
        );
        let mid = plan_acceptance(
            "ld peace",
            &SuggestionKind::Continuation,
            AcceptScope::Whole,
            "Hello wor",
            "ld!",
            word,
        )
        .unwrap();
        assert_eq!(mid.forward_delete, 2);
        let emoji = plan_acceptance(
            "🚀",
            &SuggestionKind::Emoji,
            AcceptScope::Chunk,
            "Ship it :roc",
            "",
            word,
        )
        .unwrap();
        assert_eq!(emoji.backward_delete, 4);
        assert_eq!(
            emoji_ghost("Ship it :roc", "🚀").as_deref(),
            Some("🚀 :rocket:")
        );
    }

    #[test]
    fn a_trailing_space_option_consumes_and_adds_a_space() {
        let spaced = AcceptOptions {
            add_space_after_accept: true,
            ..AcceptOptions::default()
        };
        let plan = plan_acceptance(
            " up on",
            &SuggestionKind::Continuation,
            AcceptScope::Chunk,
            "follow",
            "",
            spaced,
        )
        .unwrap();
        assert_eq!(plan.chunk, " up ");
        let last = plan_acceptance(
            " up",
            &SuggestionKind::Continuation,
            AcceptScope::Chunk,
            "follow",
            "",
            spaced,
        )
        .unwrap();
        assert_eq!(last.insertion, " up ");
    }

    #[test]
    fn replacements_check_the_live_text() {
        let word = AcceptOptions::default();
        let plan = |text, kind: SuggestionKind, before| {
            plan_acceptance(text, &kind, AcceptScope::Chunk, before, "", word)
        };
        let calc = SuggestionKind::Macro {
            query: "5+5".into(),
            preview: "= 10".into(),
        };
        let done = plan("10", calc.clone(), "Total /5+5").unwrap();
        assert_eq!((done.backward_delete, done.insertion.as_str()), (4, "10"));
        assert_eq!(plan("10", calc, "Total /5+55"), None);
        let fix = SuggestionKind::Correction {
            typo: "wrld".into(),
        };
        let fixed = plan("world", fix.clone(), "hello wrld ").unwrap();
        assert_eq!(
            (fixed.backward_delete, fixed.insertion.as_str()),
            (5, "world ")
        );
        assert_eq!(fixed.chunk, "world");
        assert_eq!(plan("world", fix, "hello word"), None);
    }

    #[test]
    fn the_text_nearest_the_caret_sets_the_direction() {
        assert!(is_right_to_left("Hello \u{5E9}\u{5DC}\u{5D5}\u{5DD} 12 "));
        assert!(!is_right_to_left("\u{5E9}\u{5DC}\u{5D5}\u{5DD} hello"));
        assert!(!is_right_to_left("123 ..."));
        assert!(is_right_to_left("\u{645}\u{631}\u{62D}\u{628}\u{627}"));
    }
}
