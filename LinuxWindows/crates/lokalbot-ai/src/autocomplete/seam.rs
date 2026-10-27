// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 25 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! `CotypingSeamGuard`: no suggestion beats a junk punctuation run or a
//! mid-word splice that misspells the word being typed.

use super::text::{is_letter, is_punctuation_or_symbol};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SeamVerdict {
    Allow,
    JunkPunctuationRun,
    SeamMisspelling(String),
}

const JUNK_RUN_LENGTH: usize = 4;
const MINIMUM_SEAM_WORD_LENGTH: usize = 4;

/// `is_known_word` answers for the joined word at the caret. Without a
/// spell checker for the text's language it should say yes to everything,
/// as macOS does where it has no dictionary.
pub fn verdict(
    before: &str,
    completion: &str,
    is_known_word: impl Fn(&str) -> bool,
) -> SeamVerdict {
    if introduces_junk_punctuation_run(before, completion) {
        return SeamVerdict::JunkPunctuationRun;
    }
    if let Some(word) = misspelling_candidate(before, completion)
        && !is_known_word(&word)
    {
        return SeamVerdict::SeamMisspelling(word);
    }
    SeamVerdict::Allow
}

fn introduces_junk_punctuation_run(before: &str, completion: &str) -> bool {
    let mut run_char: Option<char> = None;
    let mut run_length = 0;
    let mut run_starts_at_start = false;
    for (index, c) in completion.chars().enumerate() {
        if Some(c) == run_char {
            run_length += 1;
        } else {
            run_char = Some(c);
            run_length = 1;
            run_starts_at_start = index == 0;
        }
        if run_length < JUNK_RUN_LENGTH || !is_punctuation_or_symbol(c) {
            continue;
        }
        // Continuing a divider the text already has ("--" + "----") is fine.
        if run_starts_at_start && before.chars().rev().take_while(|p| *p == c).count() >= 2 {
            continue;
        }
        return true;
    }
    false
}

fn misspelling_candidate(before: &str, completion: &str) -> Option<String> {
    let last = before.chars().next_back()?;
    let first = completion.chars().next()?;
    if !is_letter(last) || !is_letter(first) {
        return None;
    }
    let head: String = {
        let mut letters: Vec<char> = before.chars().rev().take_while(|c| is_letter(*c)).collect();
        letters.reverse();
        letters.into_iter().collect()
    };
    let tail: String = completion.chars().take_while(|c| is_letter(*c)).collect();
    let word = head + &tail;
    if word.chars().count() < MINIMUM_SEAM_WORD_LENGTH {
        return None;
    }
    if !word.chars().next().is_some_and(char::is_lowercase) {
        return None;
    }
    if word.chars().any(is_cjk) {
        return None;
    }
    Some(word)
}

fn is_cjk(c: char) -> bool {
    matches!(u32::from(c), 0x2E80..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF | 0xFF65..=0xFF9F)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_normal_completions_and_known_joins() {
        assert_eq!(
            verdict("I wanted to follow", " up tomorrow", |_| true),
            SeamVerdict::Allow
        );
        assert_eq!(
            verdict("after", "noon", |w| w == "afternoon"),
            SeamVerdict::Allow
        );
        assert_eq!(verdict("--", "----", |_| true), SeamVerdict::Allow);
    }

    #[test]
    fn rejects_junk_runs_and_misspelled_joins() {
        assert_eq!(
            verdict("Thanks", " !!!!", |_| true),
            SeamVerdict::JunkPunctuationRun
        );
        assert_eq!(
            verdict("I am gre", "atful", |w| w == "grateful"),
            SeamVerdict::SeamMisspelling("greatful".into())
        );
    }
}
