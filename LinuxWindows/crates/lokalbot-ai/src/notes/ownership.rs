//! Whose task an action is, from the speech it cites (`SpokenUndertaking.swift`,
//! `OutcomeEvidencePolicy.swift`, `ActionOwnership.swift`).
//!
//! Identity comes from the voice: the cited row's speaker as the transcript
//! attributes it. The model's owner, basis and quote are claims to check.

use std::collections::{BTreeSet, HashSet};
use std::ops::Range;
use std::sync::LazyLock;

use fancy_regex::Regex as FancyRegex;
use regex::Regex;

use lokalbot_core::model::{AttributionBasis, OwnerResolution, SpeakerIdentity};

use super::view::{Speaker, View};

// ===================================================================== words

#[derive(Clone, Debug, PartialEq)]
pub struct Word {
    /// Lowercased, straight apostrophes, no surrounding punctuation.
    pub text: String,
    pub row: usize,
    /// Byte range in the row's own text.
    pub range: Range<usize>,
    pub ends_sentence: bool,
    pub ends_question: bool,
    pub followed_by_comma: bool,
    pub is_capitalized: bool,
}

const FILLERS: [&str; 9] = ["um", "uh", "uhm", "erm", "er", "eh", "hmm", "mm", "mhm"];
const DANGLING: [&str; 58] = [
    "i", "i'll", "i'm", "i've", "i'd", "we'll", "we're", "you'll", "they'll", "he'll", "she'll",
    "to", "the", "a", "an", "and", "or", "but", "so", "because", "than", "as", "if", "when", "my",
    "our", "your", "their", "his", "of", "for", "with", "on", "at", "in", "into", "from", "by",
    "about", "before", "after", "is", "are", "was", "were", "be", "been", "have", "has", "had",
    "will", "can", "could", "should", "would", "gonna", "gotta", "wanna",
];
const ADVERBS: [&str; 22] = [
    "also",
    "still",
    "just",
    "really",
    "probably",
    "definitely",
    "actually",
    "then",
    "now",
    "first",
    "certainly",
    "already",
    "only",
    "even",
    "basically",
    "obviously",
    "honestly",
    "personally",
    "totally",
    "mostly",
    "simply",
    "maybe",
];

pub fn is_dangling(word: &str) -> bool {
    DANGLING.contains(&word)
}

fn is_adverb(word: &str) -> bool {
    ADVERBS.contains(&word)
}

/// Words of one speaker's consecutive rows. Fillers and immediately repeated
/// words are dropped, so "I I have to" reads as "I have to".
pub fn words(rows: &[&str]) -> Vec<Word> {
    let mut result: Vec<Word> = Vec::new();
    for (row, text) in rows.iter().enumerate() {
        let mut spans: Vec<(usize, usize)> = Vec::new();
        let mut open: Option<usize> = None;
        for (i, c) in text.char_indices() {
            if c.is_whitespace() {
                if let Some(s) = open.take() {
                    spans.push((s, i));
                }
            } else if open.is_none() {
                open = Some(i);
            }
        }
        if let Some(s) = open {
            spans.push((s, text.len()));
        }
        for (start, end) in spans {
            let chunk = &text[start..end];
            let first = chunk
                .char_indices()
                .find(|(_, c)| c.is_alphanumeric())
                .map(|(i, _)| i);
            let last = chunk
                .char_indices()
                .rev()
                .find(|(_, c)| c.is_alphanumeric())
                .map(|(i, c)| i + c.len_utf8());
            let (Some(first), Some(last)) = (first, last) else {
                // Free-standing punctuation still closes the sentence before it.
                if chunk.chars().any(|c| ".!?;".contains(c))
                    && let Some(previous) = result.last_mut()
                    && previous.row == row
                {
                    previous.ends_sentence = true;
                    if chunk.contains('?') {
                        previous.ends_question = true;
                    }
                }
                continue;
            };
            let core = &chunk[first..last];
            let trailing = &chunk[last..];
            let word = Word {
                text: core.to_lowercase().replace('’', "'"),
                row,
                range: start + first..start + last,
                ends_sentence: trailing.chars().any(|c| ".!?;".contains(c)),
                ends_question: trailing.contains('?'),
                followed_by_comma: trailing.contains(','),
                is_capitalized: core.chars().next().is_some_and(char::is_uppercase),
            };
            if let Some(previous) = result.last()
                && previous.text == word.text
                && (!previous.ends_sentence || is_dangling(&word.text))
            {
                *result.last_mut().expect("checked") = word;
                continue;
            }
            if FILLERS.contains(&word.text.as_str()) {
                if let Some(previous) = result.last_mut()
                    && (word.ends_sentence || word.followed_by_comma)
                {
                    previous.ends_sentence |= word.ends_sentence;
                    previous.ends_question |= word.ends_question;
                    previous.followed_by_comma |= word.followed_by_comma;
                }
                continue;
            }
            result.push(word);
        }
    }
    result
}

// ====================================================================== cues

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Grade {
    Commitment,
    Offer,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    Negated,
    Question,
    Reported,
    ConditionalClause,
    Delegated,
    Conversation,
    Unfulfilled,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Cue {
    /// The subject and its undertaking verb ("i", "have", "to").
    pub words: Range<usize>,
    pub grade: Grade,
    pub refusal: Option<Refusal>,
    /// "I can do that", "Will do": the task is whatever was asked before.
    pub names_no_task: bool,
}

impl Cue {
    pub fn is_accepted(&self) -> bool {
        self.refusal.is_none()
    }
}

const ADVERB: &str = r"(?:(?:also|still|just|really|probably|definitely|actually|then|now|first|certainly|already|only|even|basically|obviously|honestly|personally|totally|mostly|simply|maybe|do|kind of|sort of) )";

static CUE_PATTERNS: LazyLock<Vec<(FancyRegex, Grade)>> = LazyLock::new(|| {
    let going = r"(?:going to|gonna|planning to|intending to|about to|supposed to)";
    let commitment = [
        format!(
            r"\bi {ADVERB}{{0,2}}(?:will|shall|must|gotta|have to|have got to|need to|got to|plan to|intend to|commit to|agree to|promise to|am {ADVERB}{{0,2}}{going})(?= |$)"
        ),
        r"\bi'll(?= |$)".to_string(),
        format!(r"\bi'm {ADVERB}{{0,2}}{going}(?= |$)"),
        format!(r"\bi've {ADVERB}{{0,2}}got to(?= |$)"),
        format!(r"(?<=\band )i (?:are|'re) {ADVERB}{{0,2}}(?:going to|gonna|planning to)(?= |$)"),
        r"\bmy next step is(?= |$)".to_string(),
        r"\bja (?:ću|cu)(?= |$)".to_string(),
        r"\bje vais(?= |$)".to_string(),
        r"\bich werde(?= |$)".to_string(),
        r"\bvoy a(?= |$)".to_string(),
        "我会|我會".to_string(),
    ];
    let offer = [
        format!(
            r"\bi {ADVERB}{{0,2}}(?:should|can|could|ought to|want to|wanna|aim to|would like to|would love to|am {ADVERB}{{0,2}}happy to)(?= |$)"
        ),
        format!(r"\bi'm {ADVERB}{{0,2}}happy to(?= |$)"),
        format!(r"\bi'd {ADVERB}{{0,2}}(?:like to|love to)(?= |$)"),
        format!(
            r"\bi {ADVERB}{{0,2}}(?:have|got) (?:a|an|some|a few|a couple of|two|three|four|five|several|one|many|more|another|lots of|a lot of|these|those|the|this|that|my) (?:[^ ]+ ){{1,5}}?to (?!(?:the|a|an|my|our|your|this|that|be|ask|say|add|me|you|him|her|them|us)(?: |$))[^ ]+"
        ),
        r"\blet me(?= |$)".to_string(),
        r"\bleave (?:it|that|this) (?:with|to) me(?= |$)".to_string(),
        r"\b(?:that's|that is|it's|it is|this is) on me(?= |$)".to_string(),
        r"\bi'm on it(?= |$)".to_string(),
    ];
    commitment
        .iter()
        .map(|p| (p, Grade::Commitment))
        .chain(offer.iter().map(|p| (p, Grade::Offer)))
        .filter_map(|(p, grade)| FancyRegex::new(p).ok().map(|r| (r, grade)))
        .collect()
});

const SENTENCE_PREAMBLE: [&str; 16] = [
    "yeah", "yes", "yep", "ok", "okay", "so", "and", "but", "then", "also", "well", "right",
    "sure", "anyway", "still", "just",
];
const INVERSIONS: [&str; 12] = [
    "do", "did", "does", "would", "should", "shall", "could", "can", "will", "must", "may", "might",
];
const SUBORDINATORS: [&str; 6] = ["if", "when", "whenever", "unless", "until", "whether"];
const TAG_ENDINGS: [&str; 9] = [
    "okay", "ok", "right", "yeah", "yes", "alright", "fine", "cool", "good",
];
const OTHER_SUBJECTS: [&str; 11] = [
    "you",
    "he",
    "she",
    "they",
    "we",
    "someone",
    "somebody",
    "everyone",
    "everybody",
    "anyone",
    "anybody",
];

/// What a speaker says about the conversation itself, after "I'll".
pub const CONVERSATION_REMARK: &str = r"(?:be (?:a little (?:bit )?|completely |totally |very |really |quite |perfectly |brutally )?(?:more specific|more clear|clearer|brief|honest|frank|candid|upfront|blunt)\b|share (?:my|the) screen\b|say\b|admit\b|confess\b)";

static CONVERSATION_START: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(&format!("^{CONVERSATION_REMARK}")).expect("valid regex"));

/// Every first-person undertaking in `words`, refused or not.
pub fn cues(words: &[Word]) -> Vec<Cue> {
    if words.is_empty() {
        return Vec::new();
    }
    let mut offsets = Vec::with_capacity(words.len());
    let mut joined = String::new();
    for word in words {
        if !joined.is_empty() {
            joined.push(' ');
        }
        offsets.push(joined.len());
        joined.push_str(&word.text);
    }
    let word_index = |offset: usize| -> usize {
        match offsets.binary_search(&offset) {
            Ok(i) => i,
            Err(i) => i.saturating_sub(1),
        }
    };
    let mut found: Vec<Cue> = Vec::new();
    for (regex, grade) in CUE_PATTERNS.iter() {
        for m in regex.find_iter(&joined).flatten() {
            if m.end() == m.start() {
                continue;
            }
            let start = word_index(m.start());
            let end = word_index(m.end() - 1) + 1;
            found.push(Cue {
                words: start..end,
                grade: *grade,
                refusal: None,
                names_no_task: false,
            });
        }
    }
    // A dropped subject at a sentence start: "Still have to go through it", "Will do".
    for start in 0..words.len() {
        if !(start == 0 || words[start - 1].ends_sentence) {
            continue;
        }
        let mut index = start;
        while index < words.len()
            && index - start < 3
            && SENTENCE_PREAMBLE.contains(&words[index].text.as_str())
        {
            index += 1;
        }
        if index >= words.len() {
            continue;
        }
        let next = words.get(index + 1).map(|w| w.text.as_str()).unwrap_or("");
        let text = words[index].text.as_str();
        if ["have", "need", "got", "going"].contains(&text) && next == "to" {
            found.push(Cue {
                words: index..index + 2,
                grade: Grade::Offer,
                refusal: None,
                names_no_task: false,
            });
        } else if ["gonna", "gotta"].contains(&text) {
            found.push(Cue {
                words: index..index + 1,
                grade: Grade::Offer,
                refusal: None,
                names_no_task: false,
            });
        } else if text == "will" && next == "do" {
            found.push(Cue {
                words: index..index + 2,
                grade: Grade::Offer,
                refusal: None,
                names_no_task: false,
            });
        }
    }
    found.sort_by_key(|c| c.words.start);
    let mut seen = HashSet::new();
    found.retain(|c| seen.insert(c.words.start));
    found.into_iter().map(|cue| judged(cue, words)).collect()
}

fn judged(mut cue: Cue, words: &[Word]) -> Cue {
    let phrase: Vec<&str> = words[cue.words.clone()]
        .iter()
        .map(|w| w.text.as_str())
        .collect();
    let mut following: Vec<&Word> = Vec::new();
    let mut index = cue.words.end;
    let mut open =
        !words[cue.words.end - 1].ends_sentence || phrase.last().is_some_and(|w| is_dangling(w));
    while open && index < words.len() && following.len() < 8 {
        following.push(&words[index]);
        open = !words[index].ends_sentence
            || (following.len() < 3
                && (is_dangling(&words[index].text) || is_adverb(&words[index].text)));
        index += 1;
    }
    let tail: Vec<&Word> = following
        .iter()
        .copied()
        .skip_while(|w| is_adverb(&w.text))
        .collect();
    let content: Vec<&str> = tail.iter().map(|w| w.text.as_str()).collect();
    let before: Vec<&str> = words[..cue.words.start]
        .iter()
        .rev()
        .take(3)
        .rev()
        .map(|w| w.text.as_str())
        .collect();
    let previous = cue.words.start.checked_sub(1).map(|i| &words[i]);
    let continues_clause = previous.is_some_and(|p| !p.ends_sentence && !p.followed_by_comma);
    let previous_text = previous.map(|p| p.text.as_str()).unwrap_or("");

    cue.refusal = if matches!(content.first(), Some(&"not") | Some(&"never"))
        || content.starts_with(&["no", "longer"])
    {
        Some(Refusal::Negated)
    } else if (continues_clause
        && phrase.first() == Some(&"i")
        && INVERSIONS.contains(&previous_text))
        || ends_in_question(&cue, words)
    {
        Some(Refusal::Question)
    } else if is_reported(&before) {
        Some(Refusal::Reported)
    } else if continues_clause
        && (SUBORDINATORS.contains(&previous_text)
            || ["every time", "each time", "in case", "so that"]
                .contains(&before[before.len().saturating_sub(2)..].join(" ").as_str()))
    {
        Some(Refusal::ConditionalClause)
    } else if ["should", "could", "must", "would"]
        .iter()
        .any(|m| phrase.contains(m))
        && matches!(content.first(), Some(&"have") | Some(&"'ve"))
    {
        Some(Refusal::Unfulfilled)
    } else if is_delegation(&tail) {
        Some(Refusal::Delegated)
    } else if is_conversation(&phrase, &content) {
        Some(Refusal::Conversation)
    } else {
        None
    };
    let last_two = phrase[phrase.len().saturating_sub(2)..].join(" ");
    cue.names_no_task = tail.is_empty()
        || phrase == ["will", "do"]
        || points_at_an_earlier_task(&tail)
        || (tail.len() <= 2 && ["on me", "on it", "with me", "to me"].contains(&last_two.as_str()));
    cue
}

/// "…do that", "…take it, but after lunch"; "…handle that migration" names its task.
fn points_at_an_earlier_task(tail: &[&Word]) -> bool {
    if tail.len() < 2 || !["that", "it", "this", "those", "them"].contains(&tail[1].text.as_str()) {
        return false;
    }
    if tail.len() == 2 || tail[1].ends_sentence || tail[1].followed_by_comma {
        return true;
    }
    [
        "on", "but", "and", "so", "tomorrow", "today", "tonight", "later", "now", "then", "after",
        "before", "if", "when", "for", "too", "yeah", "sure", "okay", "this", "next", "by",
        "right", "soon", "over",
    ]
    .contains(&tail[2].text.as_str())
}

fn ends_in_question(cue: &Cue, words: &[Word]) -> bool {
    let Some(end) = (cue.words.end - 1..words.len()).find(|i| words[*i].ends_sentence) else {
        return false;
    };
    if !words[end].ends_question {
        return false;
    }
    // "I'll send it tomorrow, okay?" still commits.
    !(TAG_ENDINGS.contains(&words[end].text.as_str()) && end >= cue.words.end)
}

fn is_reported(before: &[&str]) -> bool {
    let verbs = [
        "said",
        "say",
        "says",
        "saying",
        "thought",
        "mentioned",
        "promised",
        "claimed",
        "assumed",
    ];
    let mut words = before.to_vec();
    if words.last() == Some(&"that") {
        words.pop();
    }
    let Some(last) = words.last() else {
        return false;
    };
    if verbs.contains(last) {
        return true;
    }
    words.len() >= 2 && ["told", "tell"].contains(&words[words.len() - 2])
}

/// "I'll need you to send it" hands the work to someone else.
fn is_delegation(tail: &[&Word]) -> bool {
    if tail.len() < 3
        || !["need", "want", "like", "expect", "require"].contains(&tail[0].text.as_str())
    {
        return false;
    }
    let object = tail[1];
    if !(OTHER_SUBJECTS.contains(&object.text.as_str())
        || ["him", "her", "them"].contains(&object.text.as_str())
        || object.is_capitalized)
    {
        return false;
    }
    tail[2..].iter().take(2).any(|w| w.text == "to")
}

fn is_conversation(phrase: &[&str], tail: &[&str]) -> bool {
    if phrase.len() >= 2 && phrase[phrase.len() - 2..] == ["let", "me"] {
        return [
            "know",
            "see",
            "think",
            "say",
            "put",
            "rephrase",
            "explain",
            "clarify",
            "finish",
            "stop",
            "interrupt",
            "jump",
            "start",
            "begin",
            "repeat",
            "mention",
            "ask",
            "share",
            "show",
            "tell",
            "be",
        ]
        .contains(tail.first().unwrap_or(&""));
    }
    CONVERSATION_START.is_match(&tail.join(" "))
}

// ==================================================================== actors

/// Another party's task in the same speech: "you will send it", "Alice will review".
#[derive(Clone, Debug, PartialEq)]
pub struct Actor {
    pub start: usize,
    pub label: String,
}

const NOT_ACTORS: [&str; 53] = [
    "i",
    "it",
    "that",
    "this",
    "those",
    "these",
    "there",
    "which",
    "what",
    "who",
    "something",
    "everything",
    "anything",
    "nothing",
    "things",
    "stuff",
    "one",
    "so",
    "and",
    "but",
    "then",
    "also",
    "yeah",
    "yes",
    "okay",
    "ok",
    "well",
    "maybe",
    "probably",
    "hopefully",
    "now",
    "today",
    "tomorrow",
    "next",
    "if",
    "when",
    "because",
    "the",
    "a",
    "an",
    "my",
    "our",
    "your",
    "their",
    "his",
    "her",
    "not",
    "just",
    "still",
    "really",
    "actually",
    "after",
    "before",
];
const NOT_ACTORS_MORE: [&str; 3] = ["once", "while", "as"];
const DETERMINERS: [&str; 9] = ["the", "a", "an", "my", "our", "your", "their", "his", "her"];

fn is_not_actor(word: &str) -> bool {
    NOT_ACTORS.contains(&word) || NOT_ACTORS_MORE.contains(&word)
}

/// Length of an obligation or plan at `index` ("will", "needs to", "is going to").
fn modal_length(words: &[Word], index: usize) -> Option<usize> {
    let mut index = index;
    let mut skipped = 0;
    while index < words.len() && skipped < 2 && is_adverb(&words[index].text) {
        index += 1;
        skipped += 1;
    }
    let text = words.get(index)?.text.as_str();
    let next = words.get(index + 1).map(|w| w.text.as_str()).unwrap_or("");
    let third = words.get(index + 2).map(|w| w.text.as_str()).unwrap_or("");
    let length = if ["will", "shall", "must", "should", "can", "could"].contains(&text) {
        Some(1)
    } else if ["have", "has", "need", "needs", "plan", "plans", "got"].contains(&text)
        && next == "to"
    {
        Some(2)
    } else if (["is", "are", "am"].contains(&text) && next == "going" && third == "to")
        || (text == "is" && next == "responsible" && third == "for")
    {
        Some(3)
    } else {
        None
    };
    let length = length?;
    if index + length >= words.len() {
        return Some(length + skipped);
    }
    // A passive ("can be simplified") names no actor.
    (words[index + length].text != "be").then_some(length + skipped)
}

pub fn other_actors(words: &[Word]) -> Vec<Actor> {
    let mut actors: Vec<Actor> = Vec::new();
    for index in 0..words.len() {
        let word = &words[index];
        let previous = if index > 0 {
            words[index - 1].text.as_str()
        } else {
            ""
        };
        let starts_sentence = index == 0 || words[index - 1].ends_sentence;
        let starts_clause = starts_sentence
            || words[index - 1].followed_by_comma
            || ["and", "but", "while"].contains(&previous);
        let next = words.get(index + 1).map(|w| w.text.as_str()).unwrap_or("");
        let push = |actors: &mut Vec<Actor>, label: &str| {
            actors.push(Actor {
                start: index,
                label: label.to_string(),
            })
        };
        if ["can", "could", "would", "will"].contains(&word.text.as_str())
            && next == "you"
            && previous != "i"
        {
            push(&mut actors, "you");
            continue;
        }
        if word.text == "you"
            && ((["need", "want", "like"].contains(&previous)
                && index + 1 < words.len()
                && next == "to")
                || (previous == "sure" && index >= 2 && words[index - 2].text == "make"))
        {
            push(&mut actors, "you");
            continue;
        }
        if word.text == "please" && starts_sentence && !next.is_empty() && next != "note" {
            push(&mut actors, "you");
            continue;
        }
        if OTHER_SUBJECTS.contains(&word.text.as_str()) {
            if ![
                "so", "do", "did", "does", "what", "how", "why", "where", "whether",
            ]
            .contains(&previous)
                && modal_length(words, index + 1).is_some()
            {
                push(&mut actors, &word.text);
            }
            continue;
        }
        if let Some(subject) = word.text.strip_suffix("'ll")
            && subject != "i"
            && !is_not_actor(subject)
        {
            push(&mut actors, subject);
            continue;
        }
        if !word.text.chars().any(char::is_alphabetic) {
            continue;
        }
        if word.is_capitalized && !is_not_actor(&word.text) && !is_adverb(&word.text) {
            let mut end = index + 1;
            if end < words.len()
                && words[end].is_capitalized
                && !is_not_actor(&words[end].text)
                && modal_length(words, end).is_none()
            {
                end += 1;
            }
            if modal_length(words, end).is_some() {
                push(&mut actors, &word.text);
                continue;
            }
        }
        if !starts_clause
            || !(DETERMINERS.contains(&word.text.as_str()) || !is_not_actor(&word.text))
        {
            continue;
        }
        for length in 1..=3 {
            if index + length >= words.len() {
                break;
            }
            let subject: Vec<&str> = words[index..index + length]
                .iter()
                .map(|w| w.text.as_str())
                .collect();
            let last = subject[subject.len() - 1];
            if subject
                .iter()
                .any(|s| *s == "i" || s.starts_with("i'") || OTHER_SUBJECTS.contains(s))
                || is_not_actor(last)
                || is_adverb(last)
            {
                continue;
            }
            if modal_length(words, index + length).is_some() {
                push(&mut actors, &subject.join(" "));
                break;
            }
        }
    }
    let mut seen = HashSet::new();
    actors.retain(|a| seen.insert(a.start));
    actors
}

// ================================================================= alignment

const STOPWORDS: [&str; 66] = [
    "the", "a", "an", "to", "of", "in", "on", "for", "with", "and", "or", "but", "if", "is", "are",
    "be", "it", "that", "this", "i", "you", "we", "they", "he", "she", "will", "can", "should",
    "have", "has", "need", "going", "get", "got", "do", "does", "did", "about", "from", "at", "by",
    "as", "so", "then", "also", "just", "up", "out", "into", "their", "our", "my", "your", "me",
    "us", "them", "bit", "more", "some", "any", "all", "not", "no", "i'll", "i'm", "please",
];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Alignment {
    pub matches: usize,
    /// The clause carries the task's leading verb.
    pub leads: bool,
}

impl Alignment {
    pub fn is_about_task(&self) -> bool {
        self.leads || self.matches >= 2
    }

    fn beats(&self, other: &Alignment) -> bool {
        if self.leads != other.leads {
            self.leads
        } else {
            self.matches > other.matches
        }
    }
}

fn same_stem(lhs: &str, rhs: &str) -> bool {
    if lhs == rhs {
        return true;
    }
    let (short, long) = if lhs.chars().count() <= rhs.chars().count() {
        (lhs, rhs)
    } else {
        (rhs, lhs)
    };
    if short.chars().count() >= 3 && long.starts_with(short) {
        return true;
    }
    lhs.chars()
        .zip(rhs.chars())
        .take_while(|(a, b)| a == b)
        .count()
        >= 5
}

pub fn alignment<'w>(task: &str, clause: impl IntoIterator<Item = &'w Word>) -> Alignment {
    let spoken: BTreeSet<&str> = clause
        .into_iter()
        .map(|w| w.text.as_str())
        .filter(|t| !STOPWORDS.contains(t))
        .collect();
    let wanted: Vec<String> = words(&[task])
        .into_iter()
        .map(|w| w.text)
        .filter(|t| !STOPWORDS.contains(&t.as_str()))
        .collect();
    let mut result = Alignment::default();
    let mut counted = HashSet::new();
    for (position, word) in wanted.iter().enumerate() {
        if spoken.iter().any(|s| same_stem(s, word)) {
            if counted.insert(word.clone()) {
                result.matches += 1;
            }
            if position == 0 {
                result.leads = true;
            }
        }
    }
    result
}

/// Where a model's quote occurs in `words`, tolerating casing and punctuation.
pub fn occurrences(quote: &str, words_in: &[Word]) -> Vec<Range<usize>> {
    let wanted: Vec<String> = words(&[quote]).into_iter().map(|w| w.text).collect();
    if wanted.is_empty() || wanted.len() > words_in.len() {
        return Vec::new();
    }
    (0..=words_in.len() - wanted.len())
        .filter(|start| {
            wanted
                .iter()
                .zip(&words_in[*start..])
                .all(|(w, word)| *w == word.text)
        })
        .map(|start| start..start + wanted.len())
        .collect()
}

// ============================================================ evidence policy

const COMMITMENT_PREAMBLE: &str = r"^(?:(?:yes|yeah|yep|okay|ok|sure|right|well|so|and|then|absolutely|after this|next|also|um|uh|(?:on|from) my (?:side|end)|for my part|as for me)[,!.: ]+)*";
const FIRST_PERSON_UNDERTAKING: &str = r"(?:i (?:will|shall|am going to|am gonna|commit to|agree to|(?:do )?(?:plan|intend) to|am (?:planning|intending) to)|i['’]m (?:going to|gonna|planning to|intending to)|i['’]ll|my next step is|(?:i think )?i (?:still )?(?:have to|need to|must))";

static BARE_ACCEPTANCE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(r"{COMMITMENT_PREAMBLE}i can (?:do (?:that|it)|take (?:that|it)(?: on)?|handle (?:that|it))[.! ]*$")).expect("valid regex")
});
static CONVERSATION_MANAGEMENT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        r"{COMMITMENT_PREAMBLE}{FIRST_PERSON_UNDERTAKING} {CONVERSATION_REMARK}(?: with (?:you|everyone|you all|you guys))?[.! ]*$"
    ))
    .expect("valid regex")
});
static CLAUSES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[^.!?;]+[.!?;]*").expect("valid regex"));
static NEGATED_OR_QUESTIONED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"\?|\b(?:not|never|cannot|can't|can’t|won't|won’t|don't|don’t|shouldn't|shouldn’t)\b",
    )
    .expect("valid regex")
});
static UNDERTAKING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\b(?:will|shall|going to|gonna|need to|needs to|have to|has to|got to|should|must|can|could|let me|let['’]s|let us|plan to|want to)\b|['’]ll\b").expect("valid regex")
});
static POLITE_IF: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\bif you (?:could|can|would|don['’]t mind)\b").expect("valid regex")
});
static HYPOTHETICAL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b(?:if|unless|might|perhaps)\b").expect("valid regex"));
static GROUP_ADDRESS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\byou (?:all|guys|both|two)\b|\b(?:everyone|everybody|anyone|anybody|someone|somebody|y['’]all)\b").expect("valid regex")
});
static REQUEST_PATTERNS: LazyLock<Vec<FancyRegex>> = LazyLock::new(|| {
    [
        r"\b(?:can|could|would|will) you (?:please |maybe |also |just )*(?!not\b)\w",
        r"\byou (?:need to|have to|must|should|will need to|['’]ll need to)\s+(?!not\b|never\b)\w",
        r"\bi(?:['’]d| would)? (?:need|want|like) you to\b",
        r"\bmake sure (?:that )?you\b",
        r"(?:^|[.!?]\s*)please (?!note\b)\w",
    ]
    .iter()
    .filter_map(|p| FancyRegex::new(p).ok())
    .collect()
});
static TARGET_HYPOTHETICAL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b(?:if|unless|might|maybe|perhaps)\b").expect("valid regex"));

fn normalized(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// "I can do that" names no task of its own.
pub fn is_bare_acceptance(raw: &str) -> bool {
    BARE_ACCEPTANCE.is_match(&normalized(raw))
}

/// The whole row is a remark about the conversation ("I'll be brief").
pub fn is_conversation_management(raw: &str) -> bool {
    CONVERSATION_MANAGEMENT.is_match(&normalized(raw))
}

fn canonical_clauses(text: &str) -> Vec<String> {
    CLAUSES
        .find_iter(text)
        .map(|m| m.as_str().trim().to_string())
        .filter(|q| !q.is_empty() && q.chars().count() <= 1_000)
        .collect()
}

pub fn is_negated_or_questioned(raw: &str) -> bool {
    NEGATED_OR_QUESTIONED.is_match(&normalized(raw))
}

/// Every forward-looking sentence of the row is a question or a negation.
pub fn undertaking_is_negated_or_questioned(raw: &str) -> bool {
    let sentences: Vec<String> = canonical_clauses(raw)
        .into_iter()
        .filter(|s| expresses_undertaking(s))
        .collect();
    !sentences.is_empty() && sentences.iter().all(|s| is_negated_or_questioned(s))
}

pub fn expresses_undertaking(raw: &str) -> bool {
    UNDERTAKING.is_match(&normalized(raw))
}

/// A direct second-person request to one listener.
pub fn is_second_person_request(raw: &str) -> bool {
    let text = POLITE_IF
        .replace_all(&normalized(raw), "could you")
        .into_owned();
    if HYPOTHETICAL.is_match(&text) || GROUP_ADDRESS.is_match(&text) {
        return false;
    }
    REQUEST_PATTERNS
        .iter()
        .any(|p| p.is_match(&text).unwrap_or(false))
}

/// A first-person undertaking anywhere in the text.
pub fn is_commitment(raw: &str) -> bool {
    cues(&words(&[raw])).iter().any(Cue::is_accepted)
}

fn evidence_clause(quote: &str, source: &str) -> Option<String> {
    let text = normalized(source);
    let needle = normalized(quote);
    let at = text.find(&needle)?;
    let end_of_match = at + needle.len();
    let start = text[..at]
        .rfind(|c| ".!?;".contains(c))
        .map(|i| i + 1)
        .unwrap_or(0);
    let quote_ends_clause = text[..end_of_match]
        .chars()
        .next_back()
        .is_some_and(|c| ".!?;".contains(c));
    let end = if quote_ends_clause {
        end_of_match
    } else {
        text[end_of_match..]
            .find(|c| ".!?;".contains(c))
            .map(|i| end_of_match + i + 1)
            .unwrap_or(text.len())
    };
    Some(text[start..end].to_string())
}

static PLACEHOLDER_NAME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^(?:them|local|speaker)(?:\s+\d+|\s+unclear)?$").expect("valid regex")
});

fn unique_target_names(
    person: &Speaker,
    roster: &std::collections::BTreeMap<String, Speaker>,
) -> Vec<String> {
    let name = normalized(&person.name);
    if ["me", "you", "them", "local speaker", "speaker unclear"].contains(&name.as_str())
        || PLACEHOLDER_NAME.is_match(&name)
    {
        return Vec::new();
    }
    let mut candidates: Vec<String> = vec![name.clone()];
    if let Some(first) = name.split(' ').next() {
        candidates.push(first.to_string());
    }
    candidates.sort();
    candidates.dedup();
    candidates
        .into_iter()
        .filter(|candidate| {
            roster
                .values()
                .filter(|other| {
                    let other_name = normalized(&other.name);
                    other_name == *candidate
                        || other_name.split(' ').next() == Some(candidate.as_str())
                })
                .count()
                == 1
        })
        .collect()
}

fn has_explicit_target(name: &str, quote: &str, basis: AttributionBasis) -> bool {
    let subject = regex::escape(name);
    let text = normalized(quote);
    if TARGET_HYPOTHETICAL.is_match(&text) {
        return false;
    }
    let start = r"(?:^|[.!?]\s*)(?:(?:okay|ok|so|and|then|yes|yeah)[, ]+)*";
    let patterns = if basis == AttributionBasis::Request {
        vec![
            format!(r"{start}{subject}[, :]+(?:please\b|(?:can|could|would|will) you\b)"),
            format!(r"{start}(?:can|could|would|will) you,\s*{subject}[, :]"),
            format!(r"{start}(?:please|can|could|would|will)\s+{subject}\s+(?!not\b)\w"),
        ]
    } else {
        vec![format!(
            r"{start}{subject}\s+(?:will\s+(?!not\b)|is responsible for\s+|owns\s+|to\s+)\w"
        )]
    };
    patterns.iter().any(|p| {
        FancyRegex::new(p)
            .ok()
            .and_then(|r| r.is_match(&text).ok())
            .unwrap_or(false)
    })
}

// =============================================================== attribution

/// Why an ownership claim was not accepted (`OutcomeAttribution.RejectionReason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RejectionReason {
    MissingSpeaker,
    UnknownSpeaker,
    UnconfirmedIdentity,
    MissingBasis,
    MissingQuote,
    QuoteNotFound,
    UnsupportedCommitment,
    SpeakerMismatch,
    AmbiguousName,
    TargetNotExplicit,
    AmbiguousQuote,
}

impl RejectionReason {
    pub fn raw(self) -> &'static str {
        match self {
            Self::MissingSpeaker => "missingSpeaker",
            Self::UnknownSpeaker => "unknownSpeaker",
            Self::UnconfirmedIdentity => "unconfirmedIdentity",
            Self::MissingBasis => "missingBasis",
            Self::MissingQuote => "missingQuote",
            Self::QuoteNotFound => "quoteNotFound",
            Self::UnsupportedCommitment => "unsupportedCommitment",
            Self::SpeakerMismatch => "speakerMismatch",
            Self::AmbiguousName => "ambiguousName",
            Self::TargetNotExplicit => "targetNotExplicit",
            Self::AmbiguousQuote => "ambiguousQuote",
        }
    }

    /// The repair a rejection queues, if any.
    pub fn repair_reason(self) -> Option<&'static str> {
        match self {
            Self::MissingQuote => Some("missing_ownership_evidence"),
            Self::AmbiguousQuote => Some("ambiguous_ownership_evidence"),
            Self::QuoteNotFound => Some("ownership_quote_not_found"),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Attribution {
    pub resolution: OwnerResolution,
    pub speaker_id: Option<String>,
    pub basis: AttributionBasis,
    pub quote: Option<String>,
    pub rejection: Option<RejectionReason>,
}

impl Attribution {
    fn unresolved(
        reason: RejectionReason,
        speaker: Option<&str>,
        roster: &std::collections::BTreeMap<String, Speaker>,
    ) -> Self {
        Self {
            resolution: OwnerResolution::Unresolved,
            speaker_id: speaker
                .filter(|s| roster.contains_key(*s))
                .map(str::to_string),
            basis: AttributionBasis::Unclear,
            quote: None,
            rejection: Some(reason),
        }
    }

    fn resolved(person: &Speaker, basis: AttributionBasis, quote: Option<String>) -> Self {
        Self {
            resolution: if person.identity == SpeakerIdentity::User {
                OwnerResolution::User
            } else {
                OwnerResolution::Other
            },
            speaker_id: Some(person.id.clone()),
            basis,
            quote,
            rejection: None,
        }
    }

    pub fn into_core(self) -> lokalbot_core::model::ActionAttribution {
        lokalbot_core::model::ActionAttribution {
            resolution: self.resolution,
            speaker_id: self.speaker_id,
            basis: self.basis,
            quote: self.quote,
            rejection_reason: self.rejection.map(|r| r.raw().to_string()),
        }
    }
}

fn basis_from(raw: &str) -> Option<AttributionBasis> {
    match raw {
        "commitment" => Some(AttributionBasis::Commitment),
        "assignment" => Some(AttributionBasis::Assignment),
        "request" => Some(AttributionBasis::Request),
        "unclear" => Some(AttributionBasis::Unclear),
        _ => None,
    }
}

/// `OutcomeEvidencePolicy.resolve` for one source row.
fn resolve_policy(
    view: &View,
    speaker_id: Option<&str>,
    basis: &str,
    quote: Option<&str>,
    source: usize,
    addressed_to_user: bool,
) -> Attribution {
    let roster = &view.roster;
    let Some(speaker_id) = speaker_id else {
        return Attribution::unresolved(RejectionReason::MissingSpeaker, None, roster);
    };
    let Some(person) = roster.get(speaker_id) else {
        return Attribution::unresolved(RejectionReason::UnknownSpeaker, Some(speaker_id), roster);
    };
    if person.identity == SpeakerIdentity::Unresolved {
        return Attribution::unresolved(
            RejectionReason::UnconfirmedIdentity,
            Some(speaker_id),
            roster,
        );
    }
    let Some(basis) = basis_from(basis).filter(|b| {
        matches!(
            b,
            AttributionBasis::Commitment | AttributionBasis::Assignment | AttributionBasis::Request
        )
    }) else {
        return Attribution::unresolved(RejectionReason::MissingBasis, Some(speaker_id), roster);
    };
    let Some(quote) = quote.filter(|q| !normalized(q).is_empty() && q.chars().count() <= 1_000)
    else {
        return Attribution::unresolved(RejectionReason::MissingQuote, Some(speaker_id), roster);
    };
    let source_text = &view.texts[source];
    if basis == AttributionBasis::Commitment {
        let source_words = words(&[source_text.as_str()]);
        if occurrences(quote, &source_words).is_empty() {
            return Attribution::unresolved(
                RejectionReason::QuoteNotFound,
                Some(speaker_id),
                roster,
            );
        }
        if !undertakes(quote, source_text) {
            return Attribution::unresolved(
                RejectionReason::UnsupportedCommitment,
                Some(speaker_id),
                roster,
            );
        }
        if !(view.keys[source] == speaker_id
            && view.attributions[source].identity == person.identity
            && view.is_own_voice(source))
        {
            return Attribution::unresolved(
                RejectionReason::SpeakerMismatch,
                Some(speaker_id),
                roster,
            );
        }
    } else {
        if !normalized(source_text).contains(&normalized(quote)) {
            return Attribution::unresolved(
                RejectionReason::QuoteNotFound,
                Some(speaker_id),
                roster,
            );
        }
        let names = unique_target_names(person, roster);
        let named = names.iter().any(|name| {
            has_explicit_target(name, quote, basis)
                && evidence_clause(quote, source_text)
                    .is_some_and(|clause| has_explicit_target(name, &clause, basis))
        });
        let answered_by_user = addressed_to_user
            && person.identity == SpeakerIdentity::User
            && roster
                .get(&view.keys[source])
                .is_some_and(|s| s.identity == SpeakerIdentity::Other)
            && evidence_clause(quote, source_text).is_some_and(|c| is_second_person_request(&c));
        if !(named || answered_by_user) {
            let reason = if names.is_empty() && !addressed_to_user {
                RejectionReason::AmbiguousName
            } else {
                RejectionReason::TargetNotExplicit
            };
            return Attribution::unresolved(reason, Some(speaker_id), roster);
        }
    }
    Attribution::resolved(person, basis, Some(quote.to_string()))
}

/// `OutcomeEvidencePolicy.resolveTarget`: a request or assignment read from its row.
fn resolve_target(
    view: &View,
    speaker_id: Option<&str>,
    basis: &str,
    source: usize,
    addressed_to_user: bool,
    quote: Option<&str>,
) -> Attribution {
    let supplied = quote.filter(|q| !normalized(q).is_empty());
    let visible = &view.texts[source];
    let clauses: Vec<String> = match supplied {
        Some(q) => vec![q.to_string()],
        None => canonical_clauses(visible),
    };
    if supplied.is_none()
        && clauses
            .iter()
            .filter(|c| expresses_undertaking(c) || is_second_person_request(c))
            .count()
            > 1
    {
        return Attribution::unresolved(RejectionReason::MissingQuote, speaker_id, &view.roster);
    }
    let mut failure = resolve_policy(view, speaker_id, basis, None, source, false);
    let mut accepted: Vec<Attribution> = Vec::new();
    for clause in &clauses {
        let attribution = resolve_policy(
            view,
            speaker_id,
            basis,
            Some(clause),
            source,
            addressed_to_user,
        );
        if attribution.resolution != OwnerResolution::Unresolved {
            accepted.push(attribution.clone());
        }
        failure = attribution;
    }
    if accepted.len() > 1 {
        return Attribution {
            resolution: OwnerResolution::Unresolved,
            speaker_id: speaker_id.map(str::to_string),
            basis: AttributionBasis::Unclear,
            quote: None,
            rejection: Some(RejectionReason::AmbiguousQuote),
        };
    }
    accepted.into_iter().next().unwrap_or(failure)
}

/// The sentence the quote sits in carries the speaker's own undertaking.
fn undertakes(quote: &str, source: &str) -> bool {
    let source_words = words(&[source]);
    let Some(hit) = occurrences(quote, &source_words).into_iter().next() else {
        return false;
    };
    let start = source_words[..hit.start]
        .iter()
        .rposition(|w| w.ends_sentence)
        .map(|i| i + 1)
        .unwrap_or(0);
    let end = source_words[hit.end - 1..]
        .iter()
        .position(|w| w.ends_sentence)
        .map(|i| hit.end - 1 + i + 1)
        .unwrap_or(source_words.len());
    cues(&source_words)
        .iter()
        .any(|c| c.is_accepted() && (start..end).contains(&c.words.start))
}

// ================================================================= ownership

/// The model's ownership claim for one action.
pub struct Claim<'a> {
    /// Speaker key the model named, `None` for "source"/"unknown".
    pub owner: Option<&'a str>,
    pub names_source: bool,
    pub basis: &'a str,
    pub quote: Option<&'a str>,
    pub task: &'a str,
}

#[derive(Clone, Debug)]
pub struct Finding {
    pub attribution: Attribution,
    /// Transcript index of the cited row the ownership evidence belongs to.
    pub anchor: usize,
    pub cites_undertaking: bool,
    pub cites_only_refused_undertakings: bool,
    pub looks_forward: bool,
}

struct Turn {
    rows: Vec<usize>,
    words: Vec<Word>,
    cues: Vec<Cue>,
    actors: Vec<Actor>,
}

impl Turn {
    fn row_of(&self, word: usize) -> usize {
        self.rows[self.words[word].row]
    }

    fn word_range_in_row(&self, row: usize) -> Range<usize> {
        let Some(position) = self.rows.iter().position(|r| *r == row) else {
            return 0..0;
        };
        let first = self.words.iter().position(|w| w.row == position);
        let last = self.words.iter().rposition(|w| w.row == position);
        match (first, last) {
            (Some(first), Some(last)) => first..last + 1,
            _ => 0..0,
        }
    }

    fn closes(&self, index: usize) -> bool {
        self.words[index].ends_sentence && !is_dangling(&self.words[index].text)
    }

    fn sentence_end(&self, cue: &Cue) -> usize {
        let mut end = cue.words.end - 1;
        let mut crossed = 0;
        while end + 1 < self.words.len() && crossed < 12 {
            if self.closes(end) {
                break;
            }
            end += 1;
            crossed += 1;
        }
        end
    }

    fn reach(&self, cue: &Cue) -> usize {
        self.row_of(self.sentence_end(cue))
    }

    fn spoken(&self, cue: &Cue, text: &dyn Fn(usize) -> Option<String>) -> String {
        let mut start = cue.words.start;
        while start > 0
            && self.words[start - 1].row == self.words[start].row
            && !self.closes(start - 1)
        {
            start -= 1;
        }
        let mut end = self.sentence_end(cue);
        while end + 1 < self.words.len()
            && self.words[end + 1].row == self.words[end].row
            && !self.closes(end)
        {
            end += 1;
        }
        let mut positions: Vec<usize> = self.words[start..=end].iter().map(|w| w.row).collect();
        positions.dedup();
        let mut parts = Vec::new();
        for position in positions {
            let Some(source) = text(self.rows[position]) else {
                continue;
            };
            let span = &self.words[start..=end];
            let (Some(first), Some(last)) = (
                span.iter().find(|w| w.row == position),
                span.iter().rev().find(|w| w.row == position),
            ) else {
                continue;
            };
            let upper = source[last.range.end..]
                .find(char::is_whitespace)
                .map(|i| last.range.end + i)
                .unwrap_or(source.len());
            parts.push(source[first.range.start..upper].to_string());
        }
        parts.join(" ").chars().take(1_000).collect()
    }

    fn clause(&self, start: usize) -> &[Word] {
        let next = self
            .cues
            .iter()
            .map(|c| c.words.start)
            .chain(self.actors.iter().map(|a| a.start))
            .filter(|s| *s > start)
            .min()
            .unwrap_or(self.words.len());
        let close = (start..next).find(|i| self.closes(*i));
        &self.words[start..close.map(|c| c + 1).unwrap_or(next)]
    }

    fn sentence_around(&self, row: usize) -> &[Word] {
        let range = self.word_range_in_row(row);
        if range.is_empty() {
            return &self.words[0..0];
        }
        let mut start = range.start;
        while start > 0 && range.start - start < 12 && !self.closes(start - 1) {
            start -= 1;
        }
        let mut end = range.end;
        while end < self.words.len() && end - range.end < 12 && !self.closes(end - 1) {
            end += 1;
        }
        &self.words[start..end]
    }
}

struct Candidate<'t> {
    turn: &'t Turn,
    cue: Cue,
    row: usize,
    speaker: String,
    quoted: bool,
}

/// `ActionOwnership`: decides whose task an extracted action is.
pub struct Ownership<'v, 'a> {
    pub view: &'v View<'a>,
    pub is_english: bool,
    /// Text a row offers as evidence; `None` when outside this evidence.
    pub text: Box<dyn Fn(usize) -> Option<String> + 'v>,
}

const ROWS_BEFORE: usize = 8;
const ROWS_AFTER: usize = 3;
const LONGEST_PAUSE: f64 = 4.0;
const CARRY_OVER_SECONDS: f64 = 30.0;
const REPLY_SECONDS: f64 = 15.0;

impl Ownership<'_, '_> {
    fn key(&self, index: usize) -> &str {
        &self.view.keys[index]
    }

    fn same_voice_rows(&self, lhs: usize, rhs: usize) -> bool {
        self.view.is_own_voice(lhs)
            && self.view.is_own_voice(rhs)
            && self.same_voice(&self.view.keys[lhs].clone(), rhs)
    }

    fn same_voice(&self, speaker: &str, index: usize) -> bool {
        let roster = &self.view.roster;
        speaker == self.key(index)
            || (roster
                .get(speaker)
                .is_some_and(|s| s.identity == SpeakerIdentity::User)
                && roster
                    .get(self.key(index))
                    .is_some_and(|s| s.identity == SpeakerIdentity::User))
    }

    fn is_interjection(&self, index: usize) -> bool {
        let segment = &self.view.transcript.segments[index];
        let duration = segment.end - segment.start;
        let words = self.view.texts[index].split_whitespace().count();
        duration <= 1.0 || words <= 3 || words as f64 / duration > 6.0
    }

    fn turn(&self, index: usize, rows_before: usize, rows_after: usize) -> Turn {
        let segments = &self.view.transcript.segments;
        let mut rows = vec![index];
        let mut cursor = index as isize - 1;
        while cursor >= 0 && rows.len() <= rows_before {
            let c = cursor as usize;
            if self.same_voice_rows(c, index) && (self.text)(c).is_some() {
                if segments[rows[0]].start - segments[c].end > LONGEST_PAUSE {
                    break;
                }
                rows.insert(0, c);
            } else if !self.is_interjection(c) {
                break;
            }
            cursor -= 1;
        }
        let mut last = index;
        let mut cursor = index + 1;
        let mut added = 0;
        while cursor < segments.len() && added < rows_after {
            if self.same_voice_rows(cursor, index) && (self.text)(cursor).is_some() {
                if segments[cursor].start - segments[last].end > LONGEST_PAUSE {
                    break;
                }
                rows.push(cursor);
                last = cursor;
                added += 1;
            } else if !self.is_interjection(cursor) {
                break;
            }
            cursor += 1;
        }
        let texts: Vec<String> = rows
            .iter()
            .map(|r| (self.text)(*r).unwrap_or_default())
            .collect();
        let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
        let words = words(&refs);
        let cues = cues(&words);
        let actors = other_actors(&words);
        Turn {
            rows,
            words,
            cues,
            actors,
        }
    }

    /// The speaker's own unrefused commitment starts in this row.
    pub fn states_commitment(&self, index: usize) -> bool {
        if !self.view.is_own_voice(index) || (self.text)(index).is_none() {
            return false;
        }
        let turn = self.turn(index, 1, 2);
        turn.cues.iter().any(|c| {
            c.is_accepted() && c.grade == Grade::Commitment && turn.row_of(c.words.start) == index
        })
    }

    pub fn resolve(
        &self,
        claim: &Claim,
        primary: usize,
        context: &[usize],
        quoted_row: Option<usize>,
        user_reply: Option<&str>,
    ) -> Finding {
        let roster = &self.view.roster;
        let mut cited = vec![primary];
        cited.extend(context.iter().copied().filter(|r| *r != primary));
        let anchor = quoted_row.unwrap_or(primary);
        let anchor_speaker = self.key(anchor).to_string();
        let mut target_failure: Option<Attribution> = None;
        if claim.basis == "request" || claim.basis == "assignment" {
            let target = resolve_target(
                self.view,
                claim.owner.or(user_reply),
                claim.basis,
                anchor,
                user_reply.is_some(),
                claim.quote,
            );
            if target.resolution != OwnerResolution::Unresolved {
                return Finding {
                    attribution: target,
                    anchor,
                    cites_undertaking: false,
                    cites_only_refused_undertakings: false,
                    looks_forward: false,
                };
            }
            target_failure = Some(target);
        }

        let mut turns: Vec<Turn> = Vec::new();
        for row in &cited {
            if self.view.is_own_voice(*row) && !turns.iter().any(|t| t.rows.contains(row)) {
                turns.push(self.turn(*row, ROWS_BEFORE, ROWS_AFTER));
            }
        }
        let mut candidates: Vec<Candidate> = Vec::new();
        let mut refused = false;
        let mut looks_forward = false;
        let mut quote_hits = 0;
        for turn in &turns {
            for row in cited.iter().filter(|r| turn.rows.contains(r)) {
                let sentence = turn
                    .sentence_around(*row)
                    .iter()
                    .map(|w| w.text.as_str())
                    .collect::<Vec<_>>()
                    .join(" ");
                looks_forward = looks_forward || expresses_undertaking(&sentence);
            }
            let quoted: Vec<Range<usize>> = claim
                .quote
                .map(|q| occurrences(q, &turn.words))
                .unwrap_or_default();
            quote_hits += quoted.len();
            for cue in &turn.cues {
                let row = turn.row_of(cue.words.start);
                let reach = turn.reach(cue);
                if !cited
                    .iter()
                    .any(|c| *c >= row && *c <= reach && turn.rows.contains(c))
                {
                    continue;
                }
                if !cue.is_accepted() {
                    if cited.contains(&row)
                        && matches!(
                            cue.refusal,
                            Some(
                                Refusal::Negated
                                    | Refusal::Question
                                    | Refusal::Reported
                                    | Refusal::Unfulfilled
                            )
                        )
                    {
                        refused = true;
                    }
                    continue;
                }
                let reach_end = turn.word_range_in_row(reach).end.max(cue.words.end);
                let sentence = &turn.words[cue.words.start..reach_end];
                if !cited.contains(&row) && !alignment(claim.task, sentence).is_about_task() {
                    continue;
                }
                let is_quoted = Some(row) == quoted_row
                    || quoted.iter().any(|hit| {
                        let (a, b) = (turn.row_of(hit.start), turn.row_of(hit.end - 1));
                        a <= reach && row <= b
                    });
                candidates.push(Candidate {
                    turn,
                    cue: cue.clone(),
                    row,
                    speaker: self.key(row).to_string(),
                    quoted: is_quoted,
                });
            }
        }
        if candidates.iter().any(|c| c.quoted) {
            candidates.retain(|c| c.quoted);
        }
        if let Some(quoted_row) = quoted_row
            && candidates.iter().any(|c| c.row == quoted_row)
        {
            candidates.retain(|c| c.row == quoted_row);
        }
        let mut finding = Finding {
            attribution: Attribution::unresolved(
                RejectionReason::MissingBasis,
                Some(claim.owner.unwrap_or(&anchor_speaker)),
                roster,
            ),
            anchor,
            cites_undertaking: !candidates.is_empty(),
            cites_only_refused_undertakings: candidates.is_empty() && refused,
            looks_forward,
        };

        let chosen = candidates
            .iter()
            .map(|c| (c, alignment(claim.task, c.turn.clause(c.cue.words.start))))
            .min_by(|(l, la), (r, ra)| {
                if la.leads != ra.leads {
                    return if la.leads {
                        std::cmp::Ordering::Less
                    } else {
                        std::cmp::Ordering::Greater
                    };
                }
                if la.matches != ra.matches {
                    return ra.matches.cmp(&la.matches);
                }
                (l.row as isize - primary as isize)
                    .abs()
                    .cmp(&(r.row as isize - primary as isize).abs())
            })
            .map(|(c, _)| c);
        if let Some(chosen) = chosen {
            if !candidates
                .iter()
                .all(|c| self.same_voice(&c.speaker, chosen.row))
            {
                finding.attribution = Attribution::unresolved(
                    RejectionReason::AmbiguousQuote,
                    Some(claim.owner.unwrap_or(&anchor_speaker)),
                    roster,
                );
                return finding;
            }
            finding.anchor = if cited.contains(&chosen.row) {
                chosen.row
            } else {
                cited
                    .iter()
                    .copied()
                    .find(|c| *c >= chosen.row && *c <= chosen.turn.reach(&chosen.cue))
                    .unwrap_or(anchor)
            };
            finding.attribution =
                self.attribution_for(chosen, claim, primary, &turns, target_failure.as_ref());
            return finding;
        }

        let claims_source = claim.basis == "commitment"
            && (claim.names_source || claim.owner.is_some_and(|o| self.same_voice(o, anchor)));
        if claims_source
            && self.view.is_own_voice(anchor)
            && let Some(person) = roster.get(&anchor_speaker)
        {
            if person.identity == SpeakerIdentity::Unresolved {
                finding.attribution = Attribution::unresolved(
                    RejectionReason::UnconfirmedIdentity,
                    Some(&anchor_speaker),
                    roster,
                );
                return finding;
            }
            if self.is_english {
                if !refused
                    && let Some(carried) =
                        self.carried_undertaking(anchor, &cited, claim.task, &turns)
                {
                    finding.attribution =
                        Attribution::resolved(person, AttributionBasis::Commitment, Some(carried));
                    return finding;
                }
            } else if !(self.text)(anchor).is_some_and(|t| t.contains('?')) {
                finding.attribution = Attribution::resolved(
                    person,
                    AttributionBasis::Commitment,
                    self.exact_quote(claim.quote, anchor),
                );
                return finding;
            }
        }

        if let Some(failure) = target_failure {
            finding.attribution = failure;
        } else if let Some(quote) = claim.quote.filter(|q| !q.is_empty())
            && quote_hits == 0
            && !cited
                .iter()
                .any(|c| self.exact_quote(Some(quote), *c).is_some())
        {
            finding.attribution = Attribution::unresolved(
                RejectionReason::QuoteNotFound,
                Some(claim.owner.unwrap_or(&anchor_speaker)),
                roster,
            );
        } else if refused {
            finding.attribution = Attribution::unresolved(
                RejectionReason::UnsupportedCommitment,
                Some(claim.owner.unwrap_or(&anchor_speaker)),
                roster,
            );
        } else if claim.basis == "commitment"
            && let Some(owner) = claim.owner
            && !self.same_voice(owner, anchor)
        {
            finding.attribution =
                Attribution::unresolved(RejectionReason::SpeakerMismatch, Some(owner), roster);
        }
        finding
    }

    fn attribution_for(
        &self,
        chosen: &Candidate,
        claim: &Claim,
        primary: usize,
        turns: &[Turn],
        target_failure: Option<&Attribution>,
    ) -> Attribution {
        let roster = &self.view.roster;
        let Some(person) = roster.get(&chosen.speaker) else {
            return Attribution::unresolved(RejectionReason::UnknownSpeaker, None, roster);
        };
        if person.identity == SpeakerIdentity::Unresolved {
            return Attribution::unresolved(
                RejectionReason::UnconfirmedIdentity,
                Some(&chosen.speaker),
                roster,
            );
        }
        let turn = chosen.turn;
        let own = alignment(claim.task, turn.clause(chosen.cue.words.start));
        let contradicts = target_failure.is_some()
            || claim.owner.is_some_and(|o| !self.same_voice(o, chosen.row));
        if contradicts && !own.is_about_task() {
            return target_failure.cloned().unwrap_or_else(|| {
                Attribution::unresolved(RejectionReason::SpeakerMismatch, claim.owner, roster)
            });
        }
        let primary_turn = turns.iter().find(|t| t.rows.contains(&primary));
        let handed_over: Vec<&[Word]> = primary_turn
            .map(|t| {
                t.actors
                    .iter()
                    .filter(|a| t.row_of(a.start) == primary)
                    .map(|a| t.clause(a.start))
                    .collect()
            })
            .unwrap_or_default();
        if chosen.row != primary {
            let owns_in_primary = primary_turn.is_some_and(|t| {
                t.cues
                    .iter()
                    .any(|c| c.is_accepted() && t.row_of(c.words.start) == primary)
            });
            let mixed_source = handed_over.len() + usize::from(owns_in_primary) > 1;
            if !(own.is_about_task()
                || (chosen.quoted && !mixed_source)
                || self.answers_primary(chosen, primary))
            {
                return Attribution::unresolved(
                    RejectionReason::AmbiguousQuote,
                    Some(&chosen.speaker),
                    roster,
                );
            }
        }
        // "I'll prepare the policy, and you will send the measurements".
        let in_turn = turn.rows.contains(&primary);
        let last = turn
            .reach(&chosen.cue)
            .max(if in_turn { primary } else { chosen.row });
        let first = chosen.row.min(if in_turn { primary } else { chosen.row });
        let mut rivals: Vec<&[Word]> = turn
            .actors
            .iter()
            .filter(|a| (first..=last).contains(&turn.row_of(a.start)))
            .map(|a| turn.clause(a.start))
            .collect();
        if !in_turn && self.same_voice(&chosen.speaker, primary) {
            rivals.extend(handed_over.iter().copied());
        }
        if !rivals.is_empty() {
            let mut theirs = Alignment::default();
            for rival in rivals {
                let a = alignment(claim.task, rival);
                if a.beats(&theirs) {
                    theirs = a;
                }
            }
            let mine = turn
                .cues
                .iter()
                .filter(|c| c.is_accepted())
                .map(|c| alignment(claim.task, turn.clause(c.words.start)))
                .fold(None::<Alignment>, |best, a| match best {
                    Some(b) if !a.beats(&b) => Some(b),
                    _ => Some(a),
                })
                .unwrap_or(own);
            if !mine.beats(&theirs) {
                return Attribution::unresolved(
                    RejectionReason::AmbiguousQuote,
                    Some(&chosen.speaker),
                    roster,
                );
            }
        }
        Attribution::resolved(
            person,
            AttributionBasis::Commitment,
            Some(turn.spoken(&chosen.cue, &*self.text)),
        )
    }

    /// "Could you send the draft?" / "Yeah, I can do that".
    fn answers_primary(&self, chosen: &Candidate, primary: usize) -> bool {
        if !chosen.cue.names_no_task || chosen.row <= primary {
            return false;
        }
        let segments = &self.view.transcript.segments;
        let mut end = segments[primary].end;
        for (row, segment) in segments
            .iter()
            .enumerate()
            .take(chosen.row)
            .skip(primary + 1)
        {
            if self.same_voice(&self.view.keys[primary].clone(), row) {
                end = end.max(segment.end);
                continue;
            }
            if !(!self.view.is_own_voice(row)
                || self.is_interjection(row)
                || self.same_voice(&chosen.speaker, row))
            {
                return false;
            }
        }
        segments[chosen.row].start - end <= REPLY_SECONDS
    }

    /// The nearest undertaking earlier in the same turn, when the cited row
    /// is a fragment of that speech.
    fn carried_undertaking(
        &self,
        anchor: usize,
        cited: &[usize],
        task: &str,
        turns: &[Turn],
    ) -> Option<String> {
        let turn = turns.iter().find(|t| t.rows.contains(&anchor))?;
        if (self.text)(anchor).is_some_and(|t| t.contains('?')) {
            return None;
        }
        let anchor_words = turn.word_range_in_row(anchor);
        let last = turn.words[anchor_words.clone()].last()?;
        if !(anchor_words.len() <= 3 || !last.ends_sentence || is_dangling(&last.text)) {
            return None;
        }
        let spoken: Vec<&Word> = cited
            .iter()
            .filter(|r| turn.rows.contains(r))
            .flat_map(|r| turn.words[turn.word_range_in_row(*r)].iter())
            .collect();
        if !alignment(task, spoken).is_about_task() {
            return None;
        }
        let cue = turn
            .cues
            .iter()
            .rev()
            .find(|c| c.is_accepted() && c.words.end <= anchor_words.start)?;
        let row = turn.row_of(cue.words.start);
        let others = [
            "you", "your", "we", "us", "our", "they", "them", "their", "he", "she", "him", "her",
            "his",
        ];
        let segments = &self.view.transcript.segments;
        let ok = segments[anchor].start - segments[row].start <= CARRY_OVER_SECONDS
            && !turn
                .actors
                .iter()
                .any(|a| a.start > cue.words.start && a.start < anchor_words.end)
            && !turn.words[cue.words.end..anchor_words.end]
                .iter()
                .any(|w| others.contains(&w.text.as_str()))
            && !turn.cues.iter().any(|c| {
                !c.is_accepted()
                    && c.words.start > cue.words.start
                    && c.words.start < anchor_words.end
            })
            && !is_negated_or_questioned(&(self.text)(anchor).unwrap_or_default());
        ok.then(|| turn.spoken(cue, &*self.text))
    }

    fn exact_quote(&self, quote: Option<&str>, row: usize) -> Option<String> {
        let quote = quote.filter(|q| !q.is_empty())?;
        let source = (self.text)(row)?;
        let collapsed = source.split_whitespace().collect::<Vec<_>>().join(" ");
        collapsed.contains(quote).then(|| quote.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::Transcript;
    use lokalbot_core::model::Segment;

    fn cue_texts(text: &str) -> Vec<(String, Option<Refusal>)> {
        let w = words(&[text]);
        cues(&w)
            .into_iter()
            .map(|c| {
                (
                    w[c.words.clone()]
                        .iter()
                        .map(|x| x.text.clone())
                        .collect::<Vec<_>>()
                        .join(" "),
                    c.refusal,
                )
            })
            .collect()
    }

    #[test]
    fn words_drop_fillers_and_stumbles() {
        let w = words(&["Um, I I have to update the tickets."]);
        assert_eq!(
            w.iter().map(|x| x.text.as_str()).collect::<Vec<_>>(),
            ["i", "have", "to", "update", "the", "tickets"]
        );
        assert!(w.last().unwrap().ends_sentence);
        assert_eq!(
            &"Um, I I have to update the tickets."[w[0].range.clone()],
            "I"
        );
    }

    #[test]
    fn cues_find_and_judge_undertakings() {
        assert_eq!(
            cue_texts("I'll send you the security overview this week."),
            [("i'll".to_string(), None)]
        );
        assert_eq!(
            cue_texts("the report is something I have to update"),
            [("i have to".to_string(), None)]
        );
        assert_eq!(cue_texts("I'll not ship it.")[0].1, Some(Refusal::Negated));
        assert_eq!(
            cue_texts("Will I have to send it?")[0].1,
            Some(Refusal::Question)
        );
        assert_eq!(cue_texts("I'll send it tomorrow, okay?")[0].1, None);
        assert_eq!(
            cue_texts("She said I'll handle it.")[0].1,
            Some(Refusal::Reported)
        );
        assert_eq!(
            cue_texts("I'll be honest with you.")[0].1,
            Some(Refusal::Conversation)
        );
        assert_eq!(
            cue_texts("I'll need you to send the measurements.")[0].1,
            Some(Refusal::Delegated)
        );
        assert!(cue_texts("We are done.").is_empty());
        assert!(is_commitment("Yeah, I can do that."));
    }

    #[test]
    fn policy_patterns_match_macos() {
        assert!(is_bare_acceptance("Yeah, I can do that."));
        assert!(!is_bare_acceptance("I can do the migration."));
        assert!(is_conversation_management("I'm going to share my screen."));
        assert!(!is_conversation_management(
            "I'll share the deck after the call."
        ));
        assert!(is_second_person_request("Could you send the measurements?"));
        assert!(!is_second_person_request("Could you all send updates?"));
        assert!(undertaking_is_negated_or_questioned(
            "We should not deploy on Friday."
        ));
        assert!(expresses_undertaking("we'll see"));
    }

    fn view_for(rows: &[(&str, &str)]) -> Transcript {
        Transcript {
            segments: rows
                .iter()
                .enumerate()
                .map(|(i, (speaker, text))| Segment {
                    start: i as f64 * 5.0,
                    end: i as f64 * 5.0 + 4.5,
                    speaker: speaker.to_string(),
                    text: text.to_string(),
                    confidence: None,
                    timing_precision: None,
                    attribution: None,
                })
                .collect(),
            ..Default::default()
        }
    }

    #[test]
    fn the_voice_decides_a_commitment() {
        let transcript = view_for(&[
            (
                "them",
                "Our team loves the export feature, but we need SSO before we roll out company-wide.",
            ),
            (
                "me",
                "SSO is on the Q3 roadmap. I'll send you the security overview this week.",
            ),
        ]);
        let view = View::new(&transcript, true);
        let texts = view.texts.clone();
        let ownership = Ownership {
            view: &view,
            is_english: true,
            text: Box::new(move |i| texts.get(i).cloned()),
        };
        let claim = Claim {
            owner: None,
            names_source: true,
            basis: "commitment",
            quote: Some("I'll send you the security overview this week."),
            task: "Send the security overview",
        };
        let finding = ownership.resolve(&claim, 1, &[], None, None);
        assert_eq!(finding.attribution.resolution, OwnerResolution::User);
        assert_eq!(finding.attribution.speaker_id.as_deref(), Some("me"));
        assert_eq!(
            finding.attribution.quote.as_deref(),
            Some("I'll send you the security overview this week.")
        );
        assert!(ownership.states_commitment(1));
        assert!(!ownership.states_commitment(0));

        // A row with no undertaking: the model's claim cannot stand alone.
        let claim = Claim {
            owner: None,
            names_source: true,
            basis: "commitment",
            quote: Some("we need SSO"),
            task: "Ship SSO",
        };
        let finding = ownership.resolve(&claim, 0, &[], None, None);
        assert_eq!(finding.attribution.resolution, OwnerResolution::Unresolved);
    }

    #[test]
    fn mixed_actors_do_not_borrow_a_promise() {
        let transcript = view_for(&[(
            "me",
            "I'll prepare the policy, and you will send the measurements.",
        )]);
        let view = View::new(&transcript, true);
        let texts = view.texts.clone();
        let ownership = Ownership {
            view: &view,
            is_english: true,
            text: Box::new(move |i| texts.get(i).cloned()),
        };
        let claim = Claim {
            owner: None,
            names_source: true,
            basis: "commitment",
            quote: None,
            task: "Send the measurements",
        };
        let finding = ownership.resolve(&claim, 0, &[], None, None);
        assert_eq!(finding.attribution.resolution, OwnerResolution::Unresolved);
        let claim = Claim {
            owner: None,
            names_source: true,
            basis: "commitment",
            quote: None,
            task: "Prepare the policy",
        };
        assert_eq!(
            ownership
                .resolve(&claim, 0, &[], None, None)
                .attribution
                .resolution,
            OwnerResolution::User
        );
    }

    #[test]
    fn a_request_answered_by_the_user_is_theirs() {
        let transcript = view_for(&[
            ("them", "Could you send the draft by Friday?"),
            ("me", "Yeah, I can do that."),
        ]);
        let view = View::new(&transcript, true);
        let texts = view.texts.clone();
        let ownership = Ownership {
            view: &view,
            is_english: true,
            text: Box::new(move |i| texts.get(i).cloned()),
        };
        let claim = Claim {
            owner: Some("me"),
            names_source: false,
            basis: "request",
            quote: Some("Could you send the draft by Friday?"),
            task: "Send the draft",
        };
        let finding = ownership.resolve(&claim, 0, &[1], None, Some("me"));
        assert_eq!(finding.attribution.resolution, OwnerResolution::User);
        assert_eq!(finding.attribution.basis, AttributionBasis::Request);
    }
}
