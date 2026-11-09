// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! Typo and autocorrect rules (`CotypingTypo.swift`,
//! `CotypingSpellChecker.swift`, `CotypingSpellLanguageGate.swift`), pure:
//! the words and verdicts come from a [`SpellSource`] the desktop provides.
//! Only non-words are flagged; real-word errors (their/there) are out of scope.

use unicode_segmentation::UnicodeSegmentation as _;

use super::window;

/// What a platform's spell checker answers. Calls must be quick: they run on
/// the autocomplete worker, and a dictionary still loading answers "not a
/// typo" and "no dictionary" rather than wait.
pub trait SpellSource: Send + Sync {
    /// The languages with a dictionary, as `en_US` or `en-US`. Empty when
    /// spell checking is not available here.
    fn languages(&self) -> Vec<String>;
    fn is_typo(&self, word: &str) -> bool;
    /// Suggestions for `word`, best first.
    fn guesses(&self, word: &str) -> Vec<String>;
    /// A longer dictionary word starts with `word`.
    fn is_completable_prefix(&self, word: &str) -> bool;
}

/// The trailing word at the caret and its length in user-perceived
/// characters: one Delete press removes one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Word {
    pub word: String,
    pub character_count: usize,
}

/// The trailing word, or `None` when the caret is on whitespace or the token
/// is not plausibly natural language.
pub fn extract(before: &str) -> Option<Word> {
    let last = before.chars().next_back()?;
    if last.is_whitespace() {
        return None;
    }
    let start = before
        .grapheme_indices(true)
        .rev()
        .take_while(|(_, g)| !g.chars().next().is_some_and(char::is_whitespace))
        .last()
        .map_or(before.len(), |(index, _)| index);
    let word = &before[start..];
    if !is_plausible_natural_word(word) {
        return None;
    }
    Some(Word {
        word: word.to_string(),
        character_count: word.graphemes(true).count(),
    })
}

/// Tolerates exactly one trailing space, so a just-finished word stays
/// actionable after pressing Space.
pub fn extract_trailing_word(before: &str) -> Option<(Word, usize)> {
    let Some(without_space) = before.strip_suffix(' ') else {
        return extract(before).map(|word| (word, 0));
    };
    if without_space
        .chars()
        .next_back()
        .is_some_and(char::is_whitespace)
    {
        return None;
    }
    extract(without_space).map(|word| (word, 1))
}

/// Skips code, URLs, numbers and all-caps acronyms. Conservative: a miss is
/// fine, a false positive on code is not.
pub fn is_plausible_natural_word(word: &str) -> bool {
    const CODE_LIKE: [char; 24] = [
        '@', '/', '\\', '_', ':', '.', '#', '<', '>', '(', ')', '[', ']', '{', '}', '$', '%', '^',
        '*', '=', '+', '|', '~', '`',
    ];
    if word.graphemes(true).count() < 2 {
        return false;
    }
    if word
        .chars()
        .any(|c| c.is_numeric() || CODE_LIKE.contains(&c))
    {
        return false;
    }
    let mut letters = word.chars().filter(|c| c.is_alphabetic()).peekable();
    !(letters.peek().is_some() && letters.all(char::is_uppercase))
}

/// Copies a typo's capitalization onto its correction (`Teh` → `The`,
/// `HTE` → `THE`).
pub fn apply_case(source: &str, correction: &str) -> String {
    let letters: Vec<char> = source.chars().filter(|c| c.is_alphabetic()).collect();
    if correction.is_empty() || letters.is_empty() {
        return correction.to_string();
    }
    if letters.len() > 1 && letters.iter().all(|c| c.is_uppercase()) {
        return correction.to_uppercase();
    }
    if letters[0].is_uppercase() {
        let mut chars = correction.chars();
        return match chars.next() {
            Some(first) => first.to_uppercase().chain(chars).collect(),
            None => String::new(),
        };
    }
    correction.to_string()
}

/// What to do about the trailing word before the caret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TypoDecision {
    /// No actionable typo: generate a normal continuation.
    Proceed,
    /// Misspelled, no correction: hide the continuation.
    Suppress,
    /// Misspelled, with a fix to offer as a one-key replacement.
    Offer { word: String, corrected: String },
}

/// `CotypingTypoGate.resolve`. A word still being typed that is a live prefix
/// of a real word ("follo") is not a typo: the model must complete it. Only a
/// fragment no word starts with is a typo mid-word; once finished with a
/// space, being completable no longer matters.
pub fn resolve(
    before: &str,
    enabled: bool,
    is_typo: impl Fn(&str) -> bool,
    best_correction: impl Fn(&str) -> Option<String>,
    is_completable_prefix: impl Fn(&str) -> bool,
) -> TypoDecision {
    if !enabled {
        return TypoDecision::Proceed;
    }
    let Some((current, trailing_spaces)) = extract_trailing_word(before) else {
        return TypoDecision::Proceed;
    };
    if !is_typo(&current.word) {
        return TypoDecision::Proceed;
    }
    if trailing_spaces == 0 && is_completable_prefix(&current.word) {
        return TypoDecision::Proceed;
    }
    match best_correction(&current.word) {
        None => TypoDecision::Suppress,
        Some(corrected) => TypoDecision::Offer {
            word: current.word,
            corrected,
        },
    }
}

/// The edit that replaces a verified trailing typo, recomputed from the live
/// text at accept time (`CotypingCorrectionPlan`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CorrectionPlan {
    pub deleting_characters: usize,
    pub replacement: String,
}

pub fn correction_plan(
    before: &str,
    expected_typo: &str,
    corrected: &str,
) -> Option<CorrectionPlan> {
    let corrected = corrected.trim();
    if corrected.is_empty() || corrected == expected_typo {
        return None;
    }
    let (live, spaces) = extract_trailing_word(before)?;
    if live.word != expected_typo {
        return None;
    }
    Some(CorrectionPlan {
        deleting_characters: live.character_count + spaces,
        replacement: format!("{corrected}{}", " ".repeat(spaces)),
    })
}

/// The caret-preceding window language recognition looks at.
pub const CONTEXT_WINDOW_CHARACTERS: usize = 200;
/// Below this the recognizer is guessing, so spell checking stays on.
const MINIMUM_CONFIDENCE: f64 = 0.5;
/// One token is never enough evidence to turn spell checks off.
const MINIMUM_WORD_COUNT: usize = 2;

fn last_chars(text: &str, count: usize) -> &str {
    text.char_indices()
        .rev()
        .nth(count.saturating_sub(1))
        .map_or(text, |(index, _)| &text[index..])
}

/// Whether spell verdicts mean anything for the text at the caret
/// (`CotypingSpellLanguageGate`): text confidently in a language with no
/// dictionary would otherwise be flagged word by word. `whatlang` stands in
/// for `NLLanguageRecognizer`; its confidence is its own scale.
pub fn spell_verdicts_apply(context: &str, languages: &[String]) -> bool {
    let window = last_chars(context, CONTEXT_WINDOW_CHARACTERS).trim();
    if window.is_empty() || window.split_whitespace().count() < MINIMUM_WORD_COUNT {
        return true;
    }
    let Some(info) = whatlang::detect(window) else {
        return true;
    };
    if info.confidence() < MINIMUM_CONFIDENCE {
        return true;
    }
    has_dictionary(iso_639_1(info.lang()), languages)
}

/// "en" covers "en_GB".
fn has_dictionary(code: &str, languages: &[String]) -> bool {
    languages.iter().any(|language| {
        language
            .split(['_', '-'])
            .next()
            .is_some_and(|base| base.eq_ignore_ascii_case(code))
    })
}

fn iso_639_1(lang: whatlang::Lang) -> &'static str {
    use whatlang::Lang::*;
    match lang {
        Afr => "af",
        Aka => "ak",
        Amh => "am",
        Ara => "ar",
        Aze => "az",
        Bel => "be",
        Ben => "bn",
        Bul => "bg",
        Cat => "ca",
        Ces => "cs",
        Cmn => "zh",
        Cym => "cy",
        Dan => "da",
        Deu => "de",
        Ell => "el",
        Eng => "en",
        Epo => "eo",
        Est => "et",
        Fin => "fi",
        Fra => "fr",
        Guj => "gu",
        Heb => "he",
        Hin => "hi",
        Hrv => "hr",
        Hun => "hu",
        Hye => "hy",
        Ind => "id",
        Ita => "it",
        Jav => "jv",
        Jpn => "ja",
        Kan => "kn",
        Kat => "ka",
        Khm => "km",
        Kor => "ko",
        Lat => "la",
        Lav => "lv",
        Lit => "lt",
        Mal => "ml",
        Mar => "mr",
        Mkd => "mk",
        Mya => "my",
        Nep => "ne",
        Nld => "nl",
        Nob => "nb",
        Ori => "or",
        Pan => "pa",
        Pes => "fa",
        Pol => "pl",
        Por => "pt",
        Ron => "ro",
        Rus => "ru",
        Sin => "si",
        Slk => "sk",
        Slv => "sl",
        Sna => "sn",
        Spa => "es",
        Srp => "sr",
        Swe => "sv",
        Tam => "ta",
        Tel => "te",
        Tgl => "tl",
        Tha => "th",
        Tuk => "tk",
        Tur => "tr",
        Ukr => "uk",
        Urd => "ur",
        Uzb => "uz",
        Vie => "vi",
        Yid => "yi",
        Zul => "zu",
    }
}

/// A [`SpellSource`] with the per-keystroke rules of `CotypingSpellChecker`
/// around it. One keystroke asks several times about the same text, so the
/// language is recognized once.
pub struct Speller {
    source: std::sync::Arc<dyn SpellSource>,
    last_verdict: parking_lot::Mutex<Option<(String, bool)>>,
}

impl Speller {
    pub fn new(source: std::sync::Arc<dyn SpellSource>) -> Self {
        Self {
            source,
            last_verdict: parking_lot::Mutex::new(None),
        }
    }

    pub fn verdicts_apply(&self, context: &str) -> bool {
        let window = last_chars(context, CONTEXT_WINDOW_CHARACTERS);
        let mut last = self.last_verdict.lock();
        if let Some((seen, applies)) = last.as_ref()
            && seen == window
        {
            return *applies;
        }
        let languages = self.source.languages();
        let applies = !languages.is_empty() && spell_verdicts_apply(window, &languages);
        *last = Some((window.to_string(), applies));
        applies
    }

    pub fn is_typo(&self, word: &str) -> bool {
        !word.is_empty() && self.source.is_typo(word)
    }

    /// Unknown coverage must not turn every fragment into a spelling error.
    pub fn word_prefix_is_valid_word(&self, context: &str) -> bool {
        let partial = window::current_partial_word(context);
        if partial.graphemes(true).count() < 2 || !self.verdicts_apply(context) {
            return true;
        }
        !self.is_typo(partial)
    }

    /// The top guess that is a different single word, recased to match.
    pub fn best_correction(&self, word: &str) -> Option<String> {
        let lower = word.to_lowercase();
        let candidate = self
            .source
            .guesses(word)
            .into_iter()
            .map(|guess| guess.trim().to_string())
            .find(|guess| {
                !guess.is_empty() && guess.to_lowercase() != lower && !guess.contains(' ')
            })?;
        Some(apply_case(word, &candidate))
    }

    /// The trailing word's decision, with verdicts standing down where they
    /// do not apply.
    pub fn typo_decision(&self, before: &str, enabled: bool) -> TypoDecision {
        if !self.verdicts_apply(before) {
            return TypoDecision::Proceed;
        }
        resolve(
            before,
            enabled,
            |word| self.is_typo(word),
            |word| self.best_correction(word),
            |word| self.source.is_completable_prefix(word),
        )
    }

    /// For the seam guard: a known word, or verdicts that do not apply.
    pub fn is_known_word(&self, context: &str, word: &str) -> bool {
        !self.verdicts_apply(context) || !self.is_typo(word)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_trailing_word_is_natural_language_only() {
        assert_eq!(extract("hello wrld").unwrap().word, "wrld");
        assert_eq!(extract("hello wrld").unwrap().character_count, 4);
        assert_eq!(extract("hello "), None);
        assert_eq!(extract("see http://x.y"), None);
        assert_eq!(extract("foo_bar"), None);
        assert_eq!(extract("abc123"), None);
        assert_eq!(extract("NASA"), None);
        assert_eq!(extract("a"), None);
        assert_eq!(extract_trailing_word("wrld ").unwrap().1, 1);
        assert_eq!(extract_trailing_word("wrld  "), None);
        assert_eq!(extract_trailing_word("wrld").unwrap().1, 0);
    }

    #[test]
    fn case_follows_the_typo() {
        assert_eq!(apply_case("Teh", "the"), "The");
        assert_eq!(apply_case("HTE", "the"), "THE");
        assert_eq!(apply_case("teh", "the"), "the");
        assert_eq!(apply_case("", "the"), "the");
    }

    #[test]
    fn the_gate_offers_suppresses_or_proceeds() {
        let typo = |word: &str| word != "fine";
        let fix = |word: &str| (word == "wrld").then(|| "world".to_string());
        let live = |word: &str| word == "follo";
        assert_eq!(
            resolve("a wrld", false, typo, fix, live),
            TypoDecision::Proceed
        );
        assert_eq!(
            resolve("a fine", true, typo, fix, live),
            TypoDecision::Proceed
        );
        // Still being typed and a live prefix: the model completes it.
        assert_eq!(
            resolve("I follo", true, typo, fix, live),
            TypoDecision::Proceed
        );
        // Finished with a space, being a prefix no longer saves it.
        assert_eq!(
            resolve("I follo ", true, typo, fix, live),
            TypoDecision::Suppress
        );
        assert_eq!(
            resolve("a wrld", true, typo, fix, live),
            TypoDecision::Offer {
                word: "wrld".into(),
                corrected: "world".into()
            }
        );
        assert_eq!(
            resolve("xyzzy", true, typo, fix, live),
            TypoDecision::Suppress
        );
    }

    #[test]
    fn a_correction_replaces_the_word_and_keeps_its_space() {
        assert_eq!(
            correction_plan("a wrld ", "wrld", "world"),
            Some(CorrectionPlan {
                deleting_characters: 5,
                replacement: "world ".into()
            })
        );
        assert_eq!(
            correction_plan("a wrld", "wrld", "world")
                .unwrap()
                .deleting_characters,
            4
        );
        assert_eq!(correction_plan("a word", "wrld", "world"), None);
        assert_eq!(correction_plan("a wrld", "wrld", "wrld"), None);
    }

    struct Fake;
    impl SpellSource for Fake {
        fn languages(&self) -> Vec<String> {
            vec!["en_US".to_string()]
        }
        fn is_typo(&self, word: &str) -> bool {
            word == "wrld" || word == "Teh"
        }
        fn guesses(&self, word: &str) -> Vec<String> {
            match word {
                "wrld" => vec!["wrld".into(), "w rld".into(), "world".into()],
                "Teh" => vec!["the".into()],
                _ => Vec::new(),
            }
        }
        fn is_completable_prefix(&self, _: &str) -> bool {
            false
        }
    }

    #[test]
    fn the_speller_skips_unusable_guesses_and_recases() {
        let speller = Speller::new(std::sync::Arc::new(Fake));
        assert_eq!(speller.best_correction("wrld").as_deref(), Some("world"));
        assert_eq!(speller.best_correction("Teh").as_deref(), Some("The"));
        assert_eq!(speller.best_correction("xyz"), None);
        assert!(!speller.word_prefix_is_valid_word("hello wrld"));
        assert!(speller.word_prefix_is_valid_word("hello w"));
    }

    #[test]
    fn verdicts_stand_down_for_a_language_without_a_dictionary() {
        let en = ["en_US".to_string()];
        let serbian = "Dobar dan svima, hvala vam na brzom odgovoru. Vidimo se sutra u kancelariji oko deset sati ujutru.";
        assert!(!spell_verdicts_apply(serbian, &en));
        let english = "Thanks for the update, I wanted to follow up on the migration timeline we scoped yesterday.";
        assert!(spell_verdicts_apply(english, &en));
        // A single token is never enough evidence.
        assert!(spell_verdicts_apply("Hvala", &en));
        assert!(spell_verdicts_apply("", &en));
        assert!(spell_verdicts_apply(
            serbian,
            &["hr_HR".into(), "sr-Latn".into()]
        ));
    }

    #[test]
    fn no_dictionary_means_no_verdicts() {
        struct Empty;
        impl SpellSource for Empty {
            fn languages(&self) -> Vec<String> {
                Vec::new()
            }
            fn is_typo(&self, _: &str) -> bool {
                true
            }
            fn guesses(&self, _: &str) -> Vec<String> {
                Vec::new()
            }
            fn is_completable_prefix(&self, _: &str) -> bool {
                false
            }
        }
        let speller = Speller::new(std::sync::Arc::new(Empty));
        assert_eq!(speller.typo_decision("a wrld", true), TypoDecision::Proceed);
        assert!(speller.word_prefix_is_valid_word("a wrld"));
        assert!(speller.is_known_word("a wrld", "wrld"));
    }
}
