//! Text the way keyword search keeps and matches it (`SearchText`), and how
//! documents are cut for it (`DocExtractor.chunks`, `excerpt`).

use std::sync::LazyLock;

use regex::Regex;
use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;

/// NFKC, invisible formatting dropped (zero-width joiners, direction marks),
/// and Arabic the way people type it: no tatweel, no short vowels, one alef.
pub fn normalized(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for scalar in text.nfkc() {
        match scalar as u32 {
            0x200B => out.push(' '),
            0x00AD
            | 0x061C
            | 0x200C..=0x200F
            | 0x202A..=0x202E
            | 0x2060..=0x2064
            | 0x2066..=0x2069
            | 0xFEFF => {}
            0x0640 | 0x064B..=0x065F | 0x0670 => {}
            0x0622 | 0x0623 | 0x0625 | 0x0671 => out.push('\u{0627}'),
            _ => out.push(scalar),
        }
    }
    out
}

fn is_indic(c: char) -> bool {
    (0x0900..=0x0DFF).contains(&(c as u32))
}

fn is_arabic(c: char) -> bool {
    (0x0600..=0x06FF).contains(&(c as u32))
}

/// Words of scripts that attach endings are matched as prefixes.
pub fn inflects(word: &str) -> bool {
    word.chars().any(|c| is_indic(c) || is_arabic(c))
}

/// `CharacterSet.letters`: letters and marks.
fn is_letter(c: char) -> bool {
    c.is_alphabetic() || is_combining_mark(c)
}

/// `CharacterSet.alphanumerics`: letters, marks and numbers.
pub(crate) fn is_word_character(c: char) -> bool {
    c.is_alphanumeric() || is_combining_mark(c)
}

/// At least a fifth of what isn't space is letters. A data dump or a table of
/// numbers isn't, and gets keyword search only.
pub fn has_words(text: &str) -> bool {
    let (mut letters, mut others) = (0usize, 0usize);
    for c in text.chars().filter(|c| !c.is_whitespace()) {
        if is_letter(c) {
            letters += 1;
        } else {
            others += 1;
        }
    }
    letters > 0 && letters * 4 >= others
}

/// Enough prose for a vector: `has_words`, and at least four words with a
/// letter in them.
pub fn has_prose(text: &str) -> bool {
    has_words(text)
        && text
            .split_whitespace()
            .filter(|word| word.chars().any(is_letter))
            .take(4)
            .count()
            >= 4
}

/// One character's form for matching: normalized, lowercased, no diacritics.
fn folded(c: char) -> Vec<char> {
    let mut buffer = [0u8; 4];
    normalized(c.encode_utf8(&mut buffer))
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}

/// Where `word` is in `text` as keyword search would find it, as char ranges of
/// the text as written (`SearchText.matches`).
fn matches(word: &str, text: &[char]) -> Vec<std::ops::Range<usize>> {
    let needle: Vec<char> = word.chars().flat_map(folded).collect();
    if needle.is_empty() {
        return Vec::new();
    }
    let mut haystack: Vec<char> = Vec::with_capacity(text.len());
    let mut origin: Vec<usize> = Vec::with_capacity(text.len());
    for (index, c) in text.iter().enumerate() {
        for piece in folded(*c) {
            haystack.push(piece);
            origin.push(index);
        }
    }
    let prefix = inflects(word);
    let mut found: Vec<std::ops::Range<usize>> = Vec::new();
    let mut at = 0;
    while found.len() < 500 && at + needle.len() <= haystack.len() {
        if haystack[at..at + needle.len()] != needle[..] {
            at += 1;
            continue;
        }
        let first = origin[at];
        let mut end = origin[at + needle.len() - 1] + 1;
        at += needle.len();
        if first > 0 && is_word_character(text[first - 1]) {
            continue;
        }
        if end < text.len() && is_word_character(text[end]) {
            if !prefix {
                continue;
            }
            while end < text.len() && is_word_character(text[end]) {
                end += 1;
            }
        }
        if found.last().is_some_and(|last| first < last.end) {
            continue;
        }
        found.push(first..end);
    }
    found
}

/// One line around the first of `terms` it has, the terms marked « » as SQLite's
/// `snippet()` marks them; `None` when none of them is in it.
pub fn snippet(text: &str, terms: &[String], words: usize) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut marks: Vec<std::ops::Range<usize>> = terms
        .iter()
        .flat_map(|term| matches(term, &chars))
        .collect();
    marks.sort_by_key(|mark| mark.start);
    let first = marks.first()?.clone();
    let (mut start, mut before) = (first.start, 0);
    while start > 0 && before < words / 3 {
        start -= 1;
        if chars[start].is_whitespace() && start < first.start && !chars[start + 1].is_whitespace()
        {
            before += 1;
        }
    }
    if start > 0 || chars[start].is_whitespace() {
        start = (start + 1).min(chars.len());
    }
    let (mut end, mut after) = (first.end, 0);
    while end < chars.len() && after < words.saturating_sub(before) {
        if chars[end].is_whitespace() {
            after += 1;
        }
        end += 1;
    }
    let mut out = if start > 0 {
        "…".to_string()
    } else {
        String::new()
    };
    let mut cursor = start;
    for mark in &marks {
        if mark.start >= start && mark.end <= end && mark.start >= cursor {
            out.extend(&chars[cursor..mark.start]);
            out.push('«');
            out.extend(&chars[mark.clone()]);
            out.push('»');
            cursor = mark.end;
        }
    }
    out.extend(&chars[cursor..end]);
    if end < chars.len() {
        out.push('…');
    }
    Some(out.split_whitespace().collect::<Vec<_>>().join(" "))
}

/// One line, at most `limit` characters (`excerpt`): only the start is cleaned
/// up, since a page or a chunk can be thousands of characters.
pub fn excerpt(text: &str, limit: usize) -> String {
    let cut = limit * 8;
    let start: String = text.chars().take(cut).collect();
    let line = start.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > limit || text.chars().nth(cut).is_some() {
        let mut short: String = line.chars().take(limit).collect();
        short.push('…');
        short
    } else {
        line
    }
}

static SPACES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new("[ \t\u{00A0}]+").expect("a valid pattern"));
static BLANK_LINES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\n\s*\n\s*\n+").expect("a valid pattern"));

/// About 1,800-character pieces (~450 tokens) that overlap a little, breaking
/// at whitespace (`DocExtractor.chunks`). The same text is always cut the same
/// way, so a later step of a long file goes on where the last one stopped.
pub fn chunks(text: &str, limit: usize) -> Vec<String> {
    const SIZE: usize = 1800;
    const OVERLAP: usize = 200;
    let clean = SPACES.replace_all(text, " ");
    let clean = BLANK_LINES.replace_all(&clean, "\n\n");
    let chars: Vec<char> = clean.trim().chars().collect();
    let mut out = Vec::new();
    let mut start = 0;
    while start < chars.len() && out.len() < limit {
        let mut end = (start + SIZE).min(chars.len());
        if end < chars.len()
            && let Some(space) = (start..end).rev().find(|i| chars[*i].is_whitespace())
            && space - start > SIZE / 2
        {
            end = space;
        }
        let chunk: String = chars[start..end].iter().collect();
        let chunk = chunk.trim();
        if !chunk.is_empty() {
            out.push(chunk.to_string());
        }
        if end >= chars.len() {
            break;
        }
        let mut next = if end - start >= OVERLAP {
            end - OVERLAP
        } else {
            end
        };
        if next <= start {
            next = end;
        }
        while next < end && !chars[next].is_whitespace() {
            next += 1;
        }
        start = if next < end { next } else { end };
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizing_folds_what_people_type_differently() {
        assert_eq!(normalized("ﬁle"), "file");
        assert_eq!(normalized("a\u{200B}b"), "a b");
        assert_eq!(normalized("a\u{200C}b\u{FEFF}"), "ab");
        assert_eq!(normalized("أحمد"), "احمد");
        assert_eq!(normalized("مَدرَسة"), "مدرسة");
    }

    #[test]
    fn words_and_prose() {
        assert!(has_words("Quarterly plan 2026"));
        assert!(!has_words("123 456 789 000 111 222"));
        assert!(!has_words(""));
        assert!(has_prose("a plan for the quarter"));
        assert!(!has_prose("DEBUG=true"));
        assert!(!has_prose("root = true"));
    }

    #[test]
    fn excerpts_are_one_line() {
        assert_eq!(excerpt("  one\n\ntwo\tthree ", 240), "one two three");
        let long = "word ".repeat(100);
        let cut = excerpt(&long, 20);
        assert_eq!(cut.chars().count(), 21);
        assert!(cut.ends_with('…'));
    }

    #[test]
    fn chunks_overlap_and_break_at_spaces() {
        let text = "word ".repeat(1200);
        let cut = chunks(&text, 100);
        assert!(cut.len() >= 3);
        assert!(cut.iter().all(|c| c.chars().count() <= 1800));
        assert!(
            cut.iter()
                .all(|c| c.starts_with("word") && c.ends_with("word"))
        );
        assert_eq!(chunks(&text, 2).len(), 2);
        assert_eq!(chunks("short", 5), vec!["short".to_string()]);
        assert!(chunks("  \n ", 5).is_empty());
        // No spaces at all still ends.
        assert!(chunks(&"x".repeat(9000), 100).len() >= 5);
    }

    #[test]
    fn snippets_mark_whole_words_in_the_text_as_written() {
        let terms = ["cafe".to_string()];
        assert_eq!(
            snippet("We met at the Café on Tuesday", &terms, 12).as_deref(),
            Some("…met at the «Café» on Tuesday")
        );
        assert_eq!(
            snippet("Café today", &terms, 12).as_deref(),
            Some("«Café» today")
        );
        assert_eq!(snippet("cafeteria only", &terms, 12), None);
        let terms = ["مدرس".to_string()];
        assert!(
            snippet("في مدرسة جديدة", &terms, 12)
                .unwrap()
                .contains("«مدرسة»")
        );
    }
}
