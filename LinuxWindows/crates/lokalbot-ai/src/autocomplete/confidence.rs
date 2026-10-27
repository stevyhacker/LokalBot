//! The confidence gate (`CotypingFirstWordConfidence`,
//! `CotypingConfidenceDecision`): stay quiet when the model is unsure of a
//! suggestion's first word, as Cotypist does.
//!
//! The probability is the product of the emitted tokens' probabilities up to
//! and including the token in which the first word ends (softmax at
//! temperature 1, whatever the sampler's settings). macOS measured that a
//! minimum of 0.1 halves wrong suggestions for about 1.5 points of
//! keystrokes saved. Suggestions inside a word are not gated: their first
//! token is forced to re-type the fragment.
//!
//! The app runs the "selective one-word hybrid": when the gate fails but the
//! probability that the first word is complete (the mass of every token that
//! starts a new word or ends the text) still clears 0.31, the suggestion is
//! cut to that one word instead of being dropped. llama-server reports the
//! top candidates of each step (`n_probs`), so that mass is summed over them
//! rather than the whole vocabulary; a long tail makes it a little stricter.

use std::sync::OnceLock;

use super::normalize::{Normalized, Suppression};

/// The gate's minimum for the first word.
pub const MINIMUM_PROBABILITY: f32 = 0.1;
/// The one-word fallback's minimum.
pub const HYBRID_MINIMUM: f32 = 0.31;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BoundaryMode {
    /// Weigh the tokens of the first word, including the one that ends it.
    SelectedToken,
    /// Like `SelectedToken`, but the token that starts the next word counts 1.
    WordOnly,
    /// That token counts as the probability that any word boundary follows.
    BoundaryMass,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FirstWordConfidence {
    pub minimum: f32,
    pub mode: BoundaryMode,
    pub probability: f32,
    text: String,
    /// The first word has ended, or the gate is off.
    pub settled: bool,
}

impl FirstWordConfidence {
    pub fn new(minimum: f32, mode: BoundaryMode) -> Self {
        Self {
            minimum,
            mode,
            probability: 1.0,
            text: String::new(),
            settled: minimum <= 0.0,
        }
    }

    pub fn needs_boundary_mass(&self, piece: &str) -> bool {
        !self.settled && self.mode == BoundaryMode::BoundaryMass && self.starts_new_boundary(piece)
    }

    fn starts_new_boundary(&self, piece: &str) -> bool {
        piece
            .chars()
            .next()
            .is_some_and(|first| ends_first_word(&format!("{}{first}", self.text)))
    }

    /// Weighs the next emitted token. False once the first word is known to
    /// fall below the minimum; the product only falls, so generation can stop.
    pub fn accept(&mut self, piece: &str, probability: f32, boundary: Option<f32>) -> bool {
        if self.settled {
            return true;
        }
        if self.mode != BoundaryMode::SelectedToken && self.starts_new_boundary(piece) {
            let factor = match self.mode {
                BoundaryMode::WordOnly => 1.0,
                _ => boundary.unwrap_or(0.0),
            };
            self.probability *= if factor.is_finite() {
                factor.clamp(0.0, 1.0)
            } else {
                0.0
            };
            self.settled = true;
            return self.probability >= self.minimum;
        }
        self.text.push_str(piece);
        self.probability *= probability.max(0.0);
        if self.probability < self.minimum {
            return false;
        }
        if ends_first_word(&self.text) {
            self.settled = true;
        }
        true
    }
}

/// A word character followed by one that cannot continue the word.
pub fn ends_first_word(text: &str) -> bool {
    let mut in_word = false;
    for c in text.trim_start().chars() {
        if super::text::is_word_char(c) || c == '_' {
            in_word = true;
        } else if in_word && !"'’-".contains(c) {
            return true;
        }
    }
    false
}

/// Whether a token's bytes start a new word: its first complete character is
/// not a letter, digit, joiner or mark. A token that is only part of a
/// character never does.
pub fn token_starts_boundary(bytes: &[u8]) -> bool {
    let Some(&lead) = bytes.first() else {
        return false;
    };
    let length = match lead {
        0x00..=0x7F => 1,
        0xC2..=0xDF => 2,
        0xE0..=0xEF => 3,
        0xF0..=0xF4 => 4,
        _ => return false,
    };
    let Some(Ok(text)) = bytes.get(..length).map(std::str::from_utf8) else {
        return false;
    };
    let Some(c) = text.chars().next() else {
        return false;
    };
    if unicode_normalization::char::is_combining_mark(c) || super::text::is_control(c) {
        return false;
    }
    !(super::text::is_word_char(c) || c == '_' || "'’-".contains(c))
}

/// One token stream with a sticky decision for the gate and, under the
/// hybrid, its one-word fallback. The fallback never revives a gate that
/// failed nor changes one that passed.
#[derive(Clone, Debug, PartialEq)]
pub struct ConfidenceDecision {
    pub primary: FirstWordConfidence,
    pub fallback: Option<FirstWordConfidence>,
    pub primary_passed: bool,
    pub fallback_passed: bool,
}

impl ConfidenceDecision {
    pub fn new(minimum: f32, mode: BoundaryMode, hybrid: bool) -> Self {
        let fallback = (hybrid && minimum > 0.0)
            .then(|| FirstWordConfidence::new(HYBRID_MINIMUM, BoundaryMode::BoundaryMass));
        Self {
            primary: FirstWordConfidence::new(minimum, mode),
            fallback_passed: fallback.is_some(),
            fallback,
            primary_passed: true,
        }
    }

    /// The app's gate: the selected-token minimum with the one-word hybrid.
    /// Inside a word there is nothing to weigh.
    pub fn for_autocomplete(at_word_boundary: bool) -> Self {
        let minimum = if at_word_boundary {
            MINIMUM_PROBABILITY
        } else {
            0.0
        };
        Self::new(minimum, BoundaryMode::SelectedToken, true)
    }

    fn fallback_open(&self) -> bool {
        self.fallback_passed && self.fallback.as_ref().is_some_and(|f| !f.settled)
    }

    pub fn needs_evaluation(&self) -> bool {
        (self.primary_passed && !self.primary.settled) || self.fallback_open()
    }

    pub fn needs_eog_evaluation(&self) -> bool {
        (self.primary_passed
            && !self.primary.settled
            && self.primary.mode != BoundaryMode::SelectedToken)
            || self.fallback_open()
    }

    pub fn uses_fallback(&self) -> bool {
        !self.primary_passed && self.fallback_passed
    }

    pub fn needs_boundary_mass(&self, piece: &str) -> bool {
        (self.primary_passed && self.primary.needs_boundary_mass(piece))
            || (self.fallback_passed
                && self
                    .fallback
                    .as_ref()
                    .is_some_and(|f| f.needs_boundary_mass(piece)))
    }

    pub fn accept(
        &mut self,
        piece: &str,
        probability: f32,
        boundary: Option<f32>,
        is_eog: bool,
    ) -> bool {
        // The selected-token gate does not weigh the end of the text.
        if self.primary_passed && (!is_eog || self.primary.mode != BoundaryMode::SelectedToken) {
            self.primary_passed = self.primary.accept(piece, probability, boundary);
        }
        if self.fallback_passed {
            self.fallback_passed = self
                .fallback
                .as_mut()
                .is_some_and(|f| f.accept(piece, probability, boundary));
        }
        self.primary_passed || self.fallback_passed
    }
}

/// The hybrid's cap: only the first word of a finished normalization, its
/// suppression kept.
pub fn one_word_fallback(normalized: Normalized) -> Normalized {
    if normalized.suppression.is_some() || normalized.text.is_empty() {
        return normalized;
    }
    static WORD: OnceLock<regex::Regex> = OnceLock::new();
    let word = WORD.get_or_init(|| {
        regex::Regex::new(r"^\s*[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*")
            .expect("word pattern compiles")
    });
    match word.find(&normalized.text) {
        Some(m) => Normalized::shown(m.as_str()),
        None => Normalized::suppressed(Suppression::NormalizedToEmpty),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hybrid() -> ConfidenceDecision {
        ConfidenceDecision::new(0.1, BoundaryMode::SelectedToken, true)
    }

    #[test]
    fn the_hybrid_keeps_a_passing_gate_and_never_revives_the_fallback() {
        let mut gate = hybrid();
        assert!(gate.accept(" word", 0.2, None, false));
        assert!(!gate.fallback_passed);
        assert!(gate.accept(" next", 0.8, Some(1.0), false));
        assert!(gate.primary_passed && !gate.uses_fallback() && !gate.fallback_passed);
    }

    #[test]
    fn the_hybrid_falls_back_without_reviving_the_gate() {
        let mut gate = hybrid();
        assert!(gate.accept(" store", 0.8, None, false));
        assert!(gate.needs_boundary_mass(" on"));
        assert!(gate.accept(" on", 0.01, Some(0.8), false));
        assert!(gate.uses_fallback());
        assert!(gate.accept(" my", 1.0, Some(1.0), false));
        assert!(!gate.primary_passed);
        assert!((gate.fallback.unwrap().probability - 0.64).abs() < 1e-4);
    }

    #[test]
    fn the_hybrid_stops_only_when_both_fail_and_midword_is_not_gated() {
        let mut gate = hybrid();
        assert!(!gate.accept(" uncertain", 0.01, None, false));
        assert!(!gate.primary_passed && !gate.fallback_passed);
        let mut midword = ConfidenceDecision::for_autocomplete(false);
        assert!(!midword.needs_evaluation());
        assert!(midword.fallback.is_none());
        assert!(midword.accept("orrow", 0.0, None, false));
        assert!(!midword.uses_fallback());
    }

    #[test]
    fn the_end_of_text_never_changes_the_selected_token_gate() {
        let mut gate = hybrid();
        assert!(gate.accept(" word", 0.8, None, false));
        assert!(gate.needs_eog_evaluation());
        assert!(gate.accept(" ", 0.001, Some(0.001), true));
        assert!(gate.primary_passed);
        assert_eq!(gate.primary.probability, 0.8);
        assert!(!gate.fallback_passed);
    }

    #[test]
    fn the_cap_keeps_the_first_unicode_word_and_any_suppression() {
        for (text, expected) in [
            ("the .", "the"),
            ("рока, чак и", "рока"),
            (" I'm here", " I'm"),
            ("next-generation test", "next-generation"),
            ("...", ""),
        ] {
            assert_eq!(one_word_fallback(Normalized::shown(text)).text, expected);
        }
        for reason in [
            Suppression::QuestionContinuation,
            Suppression::PromptContextLeak,
            Suppression::UnsafeToInsert,
        ] {
            let result = Normalized::suppressed(reason);
            assert_eq!(one_word_fallback(result.clone()), result);
        }
    }

    #[test]
    fn boundary_mass_marginalizes_the_next_word() {
        let mut gate = FirstWordConfidence::new(0.2, BoundaryMode::BoundaryMass);
        assert!(gate.accept(" follow", 0.5, None));
        assert!(gate.needs_boundary_mass(" up"));
        assert!(gate.accept(" up", 0.01, Some(0.6)));
        assert!((gate.probability - 0.3).abs() < 1e-4);
        assert!(gate.settled);
        assert!(gate.accept(" later", 0.001, None));
        let mut uncertain = FirstWordConfidence::new(0.2, BoundaryMode::BoundaryMass);
        assert!(uncertain.accept(" follow", 0.5, None));
        assert!(!uncertain.accept(" up", 0.9, Some(0.1)));
        let mut closed = FirstWordConfidence::new(0.1, BoundaryMode::BoundaryMass);
        assert!(closed.accept(" word", 0.8, None));
        assert!(
            !closed.accept(" next", 0.8, None),
            "an unknown mass fails closed"
        );
    }

    #[test]
    fn the_first_word_is_weighed_up_to_the_token_that_ends_it() {
        let mut gate = FirstWordConfidence::new(0.1, BoundaryMode::SelectedToken);
        assert!(!gate.accept(" maybe", 0.05, None));
        let mut gate = FirstWordConfidence::new(0.1, BoundaryMode::SelectedToken);
        assert!(gate.accept(" fol", 0.5, None));
        assert!(gate.accept("low", 0.3, None));
        assert!(!gate.settled);
        assert!(!gate.accept(" up", 0.5, None), "0.5 × 0.3 × 0.5 = 0.075");
        let mut later = FirstWordConfidence::new(0.1, BoundaryMode::SelectedToken);
        assert!(later.accept(" follow", 0.4, None));
        assert!(later.accept(" up", 0.5, None));
        assert!(later.settled);
        assert!(later.accept(" on", 0.01, None));
        assert!((later.probability - 0.2).abs() < 1e-4);
        let mut off = FirstWordConfidence::new(0.0, BoundaryMode::SelectedToken);
        assert!(off.settled && off.accept(" anything", 0.0, None));
    }

    #[test]
    fn where_the_first_word_ends() {
        assert!(ends_first_word(" follow up"));
        assert!(ends_first_word("42."));
        assert!(ends_first_word("(maybe)"));
        assert!(ends_first_word(" well-known,"));
        assert!(!ends_first_word(" follow"));
        assert!(!ends_first_word(" don't"));
        assert!(!ends_first_word("  ("));
        assert!(ends_first_word(" šta je"));
    }

    #[test]
    fn boundary_tokens() {
        for text in [" word", "\u{a0}word", "\u{3000}word", ",next", ".", "🙂"] {
            assert!(token_starts_boundary(text.as_bytes()), "{text}");
        }
        for text in [
            "word", "č", "'s", "’s", "-known", "_name", "\u{301}", "\u{200d}",
        ] {
            assert!(!token_starts_boundary(text.as_bytes()), "{text}");
        }
        assert!(!token_starts_boundary(&[0xC3]));
        assert!(!token_starts_boundary(&[0xA9]));
        assert!(token_starts_boundary(&[32, 0xC3]));
    }
}
