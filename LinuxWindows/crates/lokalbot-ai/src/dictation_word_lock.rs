use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use regex::Regex;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum WordLock {
    Off,
    #[default]
    DigitsNamesNegation,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    Digits,
    Negation,
    Names,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Digits => "digits",
            Reason::Negation => "negation",
            Reason::Names => "names",
        }
    }
}

const NUMBER_WORD_VALUES: [(&str, u32); 28] = [
    ("zero", 0),
    ("one", 1),
    ("two", 2),
    ("three", 3),
    ("four", 4),
    ("five", 5),
    ("six", 6),
    ("seven", 7),
    ("eight", 8),
    ("nine", 9),
    ("ten", 10),
    ("eleven", 11),
    ("twelve", 12),
    ("thirteen", 13),
    ("fourteen", 14),
    ("fifteen", 15),
    ("sixteen", 16),
    ("seventeen", 17),
    ("eighteen", 18),
    ("nineteen", 19),
    ("twenty", 20),
    ("thirty", 30),
    ("forty", 40),
    ("fifty", 50),
    ("sixty", 60),
    ("seventy", 70),
    ("eighty", 80),
    ("ninety", 90),
];

const NEGATION_WORDS: [&str; 11] = [
    "not", "no", "never", "none", "nothing", "nobody", "nowhere", "neither", "nor", "cannot",
    "without",
];

const SELF_CORRECTION_PHRASES: [&str; 8] = [
    "i mean",
    "sorry",
    "actually",
    "wait",
    "rather",
    "scratch that",
    "make that",
    "make it",
];

const FILLER_WORDS: [&str; 13] = [
    "uh", "um", "er", "erm", "ah", "oh", "hmm", "well", "so", "okay", "ok", "yeah", "like",
];

const NUMBER_WORDS: [&str; 34] = [
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    "eleven",
    "twelve",
    "thirteen",
    "fourteen",
    "fifteen",
    "sixteen",
    "seventeen",
    "eighteen",
    "nineteen",
    "twenty",
    "thirty",
    "forty",
    "fifty",
    "sixty",
    "seventy",
    "eighty",
    "ninety",
    "hundred",
    "thousand",
    "million",
    "billion",
    "half",
    "quarter",
];

const MAGNITUDE_WORDS: [&str; 6] = [
    "hundred", "thousand", "million", "billion", "half", "quarter",
];

static NUMBER_TOKENS: LazyLock<Regex> = LazyLock::new(|| {
    let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety";
    let units = "one|two|three|four|five|six|seven|eight|nine";
    Regex::new(&format!(
        "(?i)[0-9]+|\\b(?:{tens})[- ](?:{units})\\b|\\p{{L}}+"
    ))
    .expect("number token pattern")
});

static JOINED_DIGITS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new("[0-9]+(?:[.,:/][0-9]+)*").expect("joined digit pattern"));

static OPENING_NO: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bno,").expect("opening no pattern"));

struct Token<'a> {
    start: usize,
    end: usize,
    text: &'a str,
}

impl Token<'_> {
    fn is_digits(&self) -> bool {
        self.text.starts_with(|c: char| c.is_ascii_digit())
    }
}

fn tokens(text: &str) -> Vec<Token<'_>> {
    NUMBER_TOKENS
        .find_iter(text)
        .map(|m| Token {
            start: m.start(),
            end: m.end(),
            text: m.as_str(),
        })
        .collect()
}

fn word_value(word: &str) -> Option<u32> {
    NUMBER_WORD_VALUES
        .iter()
        .find(|(name, _)| *name == word)
        .map(|(_, value)| *value)
}

fn number_value(token: &str) -> Option<u32> {
    let lowered = token.to_lowercase();
    let parts: Vec<&str> = lowered
        .split([' ', '-'])
        .filter(|p| !p.is_empty())
        .collect();
    let first = parts.first()?;
    let value = word_value(first)?;
    if parts.len() != 2 {
        return Some(value);
    }
    let unit = word_value(parts[1])?;
    (value >= 20 && value % 10 == 0 && (1..=9).contains(&unit)).then_some(value + unit)
}

struct SpokenNumbers {
    run_ends: Vec<usize>,
    words_before_run: Vec<Vec<u32>>,
}

impl SpokenNumbers {
    fn new(spoken: &str) -> Self {
        let mut run_ends = Vec::new();
        let mut words_before_run: Vec<Vec<u32>> = vec![Vec::new()];
        let mut digits = 0;
        for token in tokens(spoken) {
            if token.is_digits() {
                digits += token.text.len();
                run_ends.push(digits);
                words_before_run.push(Vec::new());
            } else if let Some(value) = number_value(token.text) {
                words_before_run
                    .last_mut()
                    .expect("one run always exists")
                    .push(value);
            }
        }
        Self {
            run_ends,
            words_before_run,
        }
    }
}

fn joined_digits(spoken: &str) -> Vec<bool> {
    let mut flags = Vec::new();
    for found in JOINED_DIGITS.find_iter(spoken) {
        let token = found.as_str();
        let digits = token.chars().filter(|c| c.is_ascii_digit()).count();
        flags.extend(std::iter::repeat_n(digits != token.chars().count(), digits));
    }
    flags
}

struct Cursor<'a> {
    remaining: &'a str,
    consumed: usize,
    run: usize,
    spoken_words: Vec<u32>,
}

impl Cursor<'_> {
    fn consume(&mut self, count: usize, layout: &SpokenNumbers) {
        self.remaining = &self.remaining[count..];
        self.consumed += count;
        while self.run < layout.run_ends.len() && self.consumed >= layout.run_ends[self.run] {
            self.run += 1;
            self.spoken_words = layout.words_before_run[self.run].clone();
        }
    }
}

pub fn restoring_digits(spoken: &str, cleaned: &str) -> Option<String> {
    let all_digits = digit_sequence(spoken);
    if all_digits.is_empty() {
        return None;
    }
    let joined = joined_digits(spoken);
    let layout = SpokenNumbers::new(spoken);
    let mut cursor = Cursor {
        remaining: &all_digits,
        consumed: 0,
        run: 0,
        spoken_words: layout.words_before_run[0].clone(),
    };
    let mut result = String::new();
    let mut last = 0;
    let mut changed = false;
    let mut written: HashMap<u32, usize> = HashMap::new();
    let mut restored: HashMap<u32, usize> = HashMap::new();
    for token in tokens(cleaned) {
        if token.is_digits() {
            if !cursor.remaining.starts_with(token.text) {
                return None;
            }
            cursor.consume(token.text.len(), &layout);
            continue;
        }
        let Some(value) = number_value(token.text) else {
            continue;
        };
        *written.entry(value).or_default() += 1;
        if let Some(said) = cursor.spoken_words.iter().position(|w| *w == value) {
            cursor.spoken_words.remove(said);
            continue;
        }
        let digits = value.to_string();
        if !cursor.remaining.starts_with(&digits) {
            continue;
        }
        let from = cursor.consumed;
        if joined[from..from + digits.len()].iter().any(|j| *j) {
            return None;
        }
        result.push_str(&cleaned[last..token.start]);
        result.push_str(&digits);
        last = token.end;
        cursor.consume(digits.len(), &layout);
        *restored.entry(value).or_default() += 1;
        changed = true;
    }
    if !changed || !cursor.remaining.is_empty() {
        return None;
    }
    let mut said: HashMap<u32, usize> = HashMap::new();
    for value in layout.words_before_run.iter().flatten() {
        *said.entry(*value).or_default() += 1;
    }
    let accounted = restored.iter().all(|(value, count)| {
        written.get(value).copied() == Some(count + said.get(value).copied().unwrap_or(0))
    });
    accounted.then(|| result + &cleaned[last..])
}

fn is_letter(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(char::is_alphabetic)
}

fn is_number(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(char::is_numeric)
}

fn is_word_part(grapheme: &str) -> bool {
    is_letter(grapheme) || is_number(grapheme) || grapheme == "'" || grapheme == "’"
}

pub fn words(text: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut word = String::new();
    for grapheme in text.graphemes(true) {
        if is_word_part(grapheme) {
            word.push_str(grapheme);
        } else if !word.is_empty() {
            result.push(std::mem::take(&mut word));
        }
    }
    if !word.is_empty() {
        result.push(word);
    }
    result
}

pub fn digit_sequence(text: &str) -> String {
    text.chars().filter(char::is_ascii_digit).collect()
}

fn is_subsequence(short: &str, long: &str) -> bool {
    let mut remaining = short.chars().peekable();
    for character in long.chars() {
        if remaining.peek() == Some(&character) {
            remaining.next();
        }
    }
    remaining.peek().is_none()
}

fn distance(lhs: &str, rhs: &str) -> usize {
    let a: Vec<char> = lhs.chars().collect();
    let b: Vec<char> = rhs.chars().collect();
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, x) in a.iter().enumerate() {
        let mut current = vec![i + 1];
        for (j, y) in b.iter().enumerate() {
            current.push(
                (previous[j + 1] + 1)
                    .min(current[j] + 1)
                    .min(previous[j] + usize::from(x != y)),
            );
        }
        previous = current;
    }
    previous[b.len()]
}

pub fn self_corrects(text: &str) -> bool {
    let lowered = text.to_lowercase();
    if OPENING_NO.is_match(&lowered) {
        return true;
    }
    let spaced = format!(" {} ", words(&lowered).join(" "));
    SELF_CORRECTION_PHRASES
        .iter()
        .any(|phrase| spaced.contains(&format!(" {phrase} ")))
}

pub fn negations(text: &str) -> HashSet<String> {
    let mut result = HashSet::new();
    let normalized = text.to_lowercase().replace('’', "'");
    let mut sentences: Vec<Vec<&str>> = vec![Vec::new()];
    for grapheme in normalized.graphemes(true) {
        if matches!(grapheme, "." | "!" | "?" | "\n") {
            sentences.push(Vec::new());
        } else {
            sentences.last_mut().expect("one sentence").push(grapheme);
        }
    }
    for sentence in sentences {
        let mut opening = true;
        for word in words(&sentence.concat()) {
            if opening && FILLER_WORDS.contains(&word.as_str()) {
                continue;
            }
            if word.ends_with("n't") || word == "cannot" {
                result.insert("not".to_string());
            } else if NEGATION_WORDS.contains(&word.as_str()) && !(opening && word == "no") {
                result.insert(word);
            }
            opening = false;
        }
    }
    result
}

pub fn names(text: &str) -> Vec<String> {
    fn finish(word: &mut String, starts_sentence: &mut bool, result: &mut Vec<String>) {
        if word.is_empty() {
            return;
        }
        let mut parts = word.graphemes(true);
        let first = parts.next().unwrap_or_default();
        let capitalized = first.chars().next().is_some_and(char::is_uppercase)
            && parts.any(|g| g.chars().next().is_some_and(char::is_lowercase));
        if !*starts_sentence
            && word != "I"
            && !word.starts_with("I'")
            && !word.starts_with("I’")
            && capitalized
        {
            result.push(word.clone());
        }
        *starts_sentence = false;
        word.clear();
    }
    let mut result = Vec::new();
    let mut starts_sentence = true;
    let mut word = String::new();
    for grapheme in text.graphemes(true) {
        if is_word_part(grapheme) {
            word.push_str(grapheme);
        } else {
            finish(&mut word, &mut starts_sentence, &mut result);
            if matches!(grapheme, "." | "!" | "?" | "\n") {
                starts_sentence = true;
            }
        }
    }
    finish(&mut word, &mut starts_sentence, &mut result);
    result
}

pub fn missing_names(spoken: &str, cleaned: &str, glossary: Option<&str>) -> Vec<String> {
    let written: HashSet<String> = words(cleaned).iter().map(|w| w.to_lowercase()).collect();
    let respellings: Vec<String> = words(glossary.unwrap_or_default())
        .iter()
        .map(|w| w.to_lowercase())
        .filter(|w| written.contains(w))
        .collect();
    names(spoken)
        .into_iter()
        .filter(|name| {
            let key = name.to_lowercase();
            !written.contains(&key) && !respellings.iter().any(|r| distance(r, &key) <= 2)
        })
        .collect()
}

pub fn says_number_words(text: &str) -> bool {
    words(&text.to_lowercase())
        .iter()
        .any(|w| NUMBER_WORDS.contains(&w.as_str()))
}

pub fn number_words_account_for(written: &str, spoken: &str) -> bool {
    if !says_number_words(spoken) {
        return false;
    }
    if words(&spoken.to_lowercase())
        .iter()
        .any(|w| MAGNITUDE_WORDS.contains(&w.as_str()))
    {
        return true;
    }
    let mut kept_as_words: Vec<u32> = tokens(written)
        .iter()
        .filter_map(|t| number_value(t.text))
        .collect();
    let mut sayable = String::new();
    for token in tokens(spoken) {
        if token.is_digits() {
            sayable.push_str(token.text);
            continue;
        }
        let Some(value) = number_value(token.text) else {
            continue;
        };
        if let Some(kept) = kept_as_words.iter().position(|w| *w == value) {
            kept_as_words.remove(kept);
        } else {
            sayable.push_str(&value.to_string());
        }
    }
    is_subsequence(&digit_sequence(written), &sayable)
}

pub fn broken(spoken: &str, cleaned: &str, glossary: Option<&str>) -> Vec<Reason> {
    let corrects = self_corrects(spoken);
    let mut reasons = Vec::new();
    let heard = digit_sequence(spoken);
    let written = digit_sequence(cleaned);
    if heard != written {
        let added = is_subsequence(&heard, &written) && number_words_account_for(cleaned, spoken);
        let dropped = is_subsequence(&written, &heard) && corrects;
        if !added && !dropped {
            reasons.push(Reason::Digits);
        }
    }
    if !corrects && !negations(spoken).is_empty() && negations(cleaned).is_empty() {
        reasons.push(Reason::Negation);
    }
    if !corrects && !missing_names(spoken, cleaned, glossary).is_empty() {
        reasons.push(Reason::Names);
    }
    reasons
}

impl WordLock {
    pub fn kept(
        self,
        spoken: &str,
        cleaned: &str,
        glossary: Option<&str>,
    ) -> (String, Vec<Reason>) {
        if self != WordLock::DigitsNamesNegation {
            return (cleaned.to_string(), Vec::new());
        }
        let broken_now = broken(spoken, cleaned, glossary);
        if (broken_now.is_empty() || broken_now == [Reason::Digits])
            && digit_sequence(spoken) != digit_sequence(cleaned)
            && let Some(restored) = restoring_digits(spoken, cleaned)
            && broken(spoken, &restored, glossary).is_empty()
        {
            return (restored, Vec::new());
        }
        if broken_now.is_empty() {
            (cleaned.to_string(), Vec::new())
        } else {
            (spoken.to_string(), broken_now)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Reason::{Digits, Names, Negation};

    fn check(spoken: &str, cleaned: &str) -> Vec<Reason> {
        broken(spoken, cleaned, None)
    }

    const PRODUCTION: WordLock = WordLock::DigitsNamesNegation;

    #[test]
    fn dictation_word_lock_fluent_cleanup_passes() {
        assert_eq!(
            check(
                "um so the meeting is at 3 tomorrow",
                "The meeting is at 3 tomorrow."
            ),
            []
        );
        assert_eq!(
            check(
                "lets ship the 6 fixes tomorrow",
                "Let's ship the 6 fixes tomorrow."
            ),
            []
        );
        assert_eq!(
            check(
                "we are not ready we are not ready yet",
                "We are not ready yet."
            ),
            []
        );
        assert_eq!(
            check("call 14:30 with Orion", "Call at 14:30 with Orion."),
            []
        );
    }

    #[test]
    fn dictation_word_lock_digits_must_stay_as_spoken() {
        assert_eq!(
            check(
                "Can you send me the 4 slides before noon?",
                "Can you send me the four slides before noon?"
            ),
            [Digits],
            "spelled out"
        );
        assert_eq!(
            check(
                "Javi mi sutra da li dolaziš na 3 sastanka.",
                "Javi mi sutra da li dolaziš na tri sastanka."
            ),
            [Digits],
            "in any language"
        );
        assert_eq!(
            check("we meet at 3", "We meet at 3 or 4."),
            [Digits],
            "a digit is never invented"
        );
        assert_eq!(check("the budget is 120", "The budget is 1,200."), [Digits]);
    }

    #[test]
    fn dictation_word_lock_negation_must_not_disappear() {
        assert_eq!(
            check("i'm not ready to sign yet", "I'm ready to sign."),
            [Negation]
        );
        assert_eq!(check("don't send the draft", "Send the draft."), [Negation]);
        assert_eq!(
            check("we never ship on fridays", "We ship on Fridays."),
            [Negation]
        );
        assert_eq!(
            check("i can't make the call", "I cannot make the call."),
            [],
            "same negation, other spelling"
        );
        assert_eq!(check("don't merge it", "Do not merge it."), []);
        assert_eq!(
            check(
                "uh no I don't think that works",
                "I don't think that works."
            ),
            [],
            "an opening \"no\" is an answer, not a negation"
        );
        assert_eq!(
            check("there is no budget left", "There is budget left."),
            [Negation]
        );
    }

    #[test]
    fn dictation_word_lock_names_must_survive_unless_respelled_from_the_glossary() {
        assert_eq!(
            check("send it to Mila Novak today", "Send it to Mila today."),
            [Names]
        );
        assert_eq!(
            broken(
                "send it to Mila Novack today",
                "Send it to Mila Novak today.",
                Some("Mila Novak, Orion")
            ),
            [],
            "a respelling to a glossary term is a fix"
        );
        assert_eq!(
            check(
                "send it to Mila Novack today",
                "Send it to Mila Novak today."
            ),
            [Names]
        );
        assert_eq!(
            check("I think I'll call later", "I'll call later."),
            [],
            "\"I\" is not a name"
        );
        assert_eq!(
            check("Marko said yes", "He said yes."),
            [],
            "a sentence's first word isn't treated as a name"
        );
    }

    #[test]
    fn dictation_word_lock_real_speech_recognition_does_not_trip_the_lock() {
        assert_eq!(
            check(
                "we checked the items Related to the order Was it shipped",
                "We checked the items related to the order. Was it shipped?"
            ),
            [],
            "a capital that only marks a missed sentence start may be lowered"
        );
        assert_eq!(
            check(
                "the bill came to 1500 dollars",
                "The bill came to 1,500 dollars."
            ),
            [],
            "grouping only"
        );
        assert_eq!(
            check(
                "the bill came to 1500 dollars",
                "The bill came to 1 500 dollars."
            ),
            []
        );
        assert_eq!(
            check("it was twelve hundred dollars", "It was 1200 dollars."),
            [],
            "spoken numbers may become digits"
        );
        assert_eq!(
            check("meet me at 930 tomorrow", "Meet me at 9:30 tomorrow."),
            [],
            "same digits, a time's colon added"
        );
        assert_eq!(check("the code is 213 292", "The code is 213-292."), []);
        assert_eq!(
            check("there was not anything left", "There was nothing left."),
            [],
            "negation by meaning"
        );
        assert_eq!(check("we are not done", "We are done."), [Negation]);
        assert_eq!(
            check("ask Zorana to call", "Ask Zarana to call."),
            [Names],
            "a respelled name still counts"
        );
    }

    #[test]
    fn dictation_word_lock_a_self_correction_may_drop_what_it_corrects() {
        assert_eq!(check("let's meet at 3, no, 4", "Let's meet at 4."), []);
        assert_eq!(check("send it to Ana I mean Mila", "Send it to Mila."), []);
        assert_eq!(
            check("let's meet at 3, no, 4", "Let's meet at 4 or 5."),
            [Digits],
            "inventing a digit still breaks it"
        );
    }

    #[test]
    fn dictation_word_lock_a_time_or_decimal_spelled_out_keeps_the_transcript() {
        let lock = PRODUCTION;
        let time = lock.kept(
            "um the call is at 3:30 tomorrow",
            "The call is at three thirty tomorrow.",
            None,
        );
        assert_eq!(time.0, "um the call is at 3:30 tomorrow");
        assert_eq!(time.1, [Digits]);
        let decimal = lock.kept(
            "it grew 2.5 percent",
            "It grew two point five percent.",
            None,
        );
        assert_eq!(decimal.0, "it grew 2.5 percent");
        let mixed = lock.kept("at 3:30 for 2 weeks", "At 3:30 for two weeks.", None);
        assert_eq!(mixed.0, "At 3:30 for 2 weeks.");
    }

    #[test]
    fn dictation_word_lock_spelled_out_numbers_are_turned_back_into_the_spoken_digits() {
        let lock = PRODUCTION;
        let text = |spoken: &str, cleaned: &str| lock.kept(spoken, cleaned, None).0;
        assert_eq!(
            text(
                "uh the last 3 releases slipped",
                "The last three releases slipped."
            ),
            "The last 3 releases slipped.",
            "cleanup is kept and the digit comes back"
        );
        assert_eq!(
            text(
                "we need 2 or 3 people for about 25 minutes",
                "We need two or three people for about twenty-five minutes."
            ),
            "We need 2 or 3 people for about 25 minutes."
        );
        assert_eq!(
            text("one of us will call at 3", "One of us will call at three."),
            "One of us will call at 3.",
            "a pronoun \"one\" is left alone"
        );
        let serbian = lock.kept(
            "Javi mi sutra da li dolaziš na 3 sastanka.",
            "Javi mi sutra da li dolaziš na tri sastanka.",
            None,
        );
        assert_eq!(serbian.0, "Javi mi sutra da li dolaziš na 3 sastanka.");
        assert_eq!(
            serbian.1,
            [Digits],
            "only English number words are turned back"
        );
        assert_eq!(
            lock.kept("we meet at 3", "We meet at three or 4.", None).1,
            [Digits],
            "an invented digit still keeps the transcript"
        );
        assert_eq!(restoring_digits("no digits here", "No digits here."), None);
        assert_eq!(
            text(
                "honestly the last 3 releases slipped and I would rather wait",
                "Honestly, the last three releases slipped, and I would rather wait."
            ),
            "Honestly, the last 3 releases slipped, and I would rather wait.",
            "an everyday \"rather\" or \"wait\" doesn't let a spelled-out digit through"
        );
        assert_eq!(
            text("let's meet at 3, no, 4", "Let's meet at 4."),
            "Let's meet at 4.",
            "a real self-correction is left as cleaned"
        );
    }

    #[test]
    fn dictation_word_lock_a_spoken_number_word_is_not_mistaken_for_the_digit_to_restore() {
        let lock = PRODUCTION;
        assert_eq!(
            lock.kept(
                "one of us needs 1 ticket",
                "One of us needs one ticket.",
                None
            )
            .0,
            "One of us needs 1 ticket.",
            "the spoken \"one\" stays a word; the spoken digit comes back"
        );
        assert_eq!(
            lock.kept(
                "book 2 rooms for two nights",
                "Book two rooms for two nights.",
                None
            )
            .0,
            "Book 2 rooms for two nights."
        );
        let dropped = lock.kept(
            "one one of us needs 1 ticket",
            "Of us needs one ticket.",
            None,
        );
        assert_eq!(
            dropped.0, "one one of us needs 1 ticket",
            "when the words don't line up the transcript is kept"
        );
        assert_eq!(dropped.1, [Digits]);
        let ambiguous = lock.kept(
            "one of us needs 1 ticket and one pass",
            "Someone needs one ticket and one pass.",
            None,
        );
        assert_eq!(
            ambiguous.0, "one of us needs 1 ticket and one pass",
            "a spoken number word that cleanup dropped leaves no way to tell which word was the digit"
        );
        assert_eq!(ambiguous.1, [Digits]);
    }

    #[test]
    fn dictation_word_lock_added_digits_must_come_from_the_spoken_number_words() {
        let lock = PRODUCTION;
        let invented = lock.kept(
            "we need 3 slides and one summary",
            "We need 34 slides and one summary.",
            None,
        );
        assert_eq!(
            invented.1,
            [Digits],
            "a number word elsewhere doesn't excuse an invented digit"
        );
        assert_eq!(invented.0, "we need 3 slides and one summary");
        let still_said = lock.kept(
            "we need 3 slides and four summaries",
            "We need 34 slides and four summaries.",
            None,
        );
        assert_eq!(
            still_said.1,
            [Digits],
            "a number word that is still there as a word explains no digit"
        );
        assert_eq!(
            lock.kept(
                "twelve of them arrive at 3",
                "12 of them arrive at 3.",
                None
            )
            .1,
            []
        );
        assert_eq!(
            lock.kept(
                "it was twenty twenty six by then",
                "It was 2026 by then.",
                None
            )
            .1,
            []
        );
        assert_eq!(
            lock.kept("about twelve hundred dollars", "About 1200 dollars.", None)
                .1,
            [],
            "hundreds and thousands are not converted, so they stay allowed"
        );
    }

    #[test]
    fn dictation_word_lock_keeps_the_transcript_only_when_on() {
        let spoken = "Can you send me the 4 slides?";
        let cleaned = "Can you send me the 4 or 5 slides?";
        assert_eq!(WordLock::default(), WordLock::DigitsNamesNegation);
        assert_eq!(PRODUCTION.kept(spoken, cleaned, None).0, spoken);
        assert_eq!(PRODUCTION.kept(spoken, cleaned, None).1, [Digits]);
        assert_eq!(WordLock::Off.kept(spoken, cleaned, None).0, cleaned);
        assert_eq!(
            PRODUCTION
                .kept(spoken, "Can you send me the 4 slides?", None)
                .0,
            "Can you send me the 4 slides?"
        );
    }
}
