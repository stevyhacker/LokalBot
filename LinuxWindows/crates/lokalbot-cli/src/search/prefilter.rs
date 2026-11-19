//! Shortcuts that let [`super::hits`] skip text that cannot match, and fold
//! the rest faster, without changing a single hit.
//!
//! [`fold`] decomposes (NFD), drops combining marks, lowercases and collapses
//! whitespace. Each step works on one character at a time, with two
//! exceptions: lowercasing turns a capital sigma into `ς` or `σ` depending on
//! its neighbours, and decomposing reorders characters with a nonzero
//! combining class (all of them combining marks in current Unicode, which
//! are dropped anyway). So:
//!
//! - [`fold_fast`] folds one character at a time, with an ASCII shortcut, and
//!   hands a text with either exception to [`fold`].
//! - A *skeleton* is folded text with every run of characters that are not
//!   letters or digits written as one space, and `ς` written as `σ`. Whatever
//!   `fold(text)` contains, written the same way, the text's skeleton
//!   contains, and a whole word there is a whole word in the skeleton.
//! - [`Prefilter`] looks for each search word's skeleton in a text's
//!   skeleton, or in a `transcript.json` before it is decoded. It answers
//!   "no" only when no word can match. When it cannot read something
//!   (invalid UTF-8, a broken escape) it answers "maybe", and the decoder and
//!   matcher decide as before.

use std::cell::Cell;

use lokalbot_core::ids::fold;
use memchr::memmem::Finder;
use unicode_normalization::char::{
    canonical_combining_class, decompose_canonical, is_combining_mark,
};

const SEPARATOR: u8 = b' ';
/// A byte the ASCII loop leaves to slower code.
const SPECIAL: u8 = 0xFF;

/// Each ASCII byte folded (letters lowercased, digits kept, anything else a
/// separator); non-ASCII bytes, and in JSON a quote or backslash, special.
const fn byte_table(json: bool) -> [u8; 256] {
    let mut table = [SPECIAL; 256];
    let mut byte = 0;
    while byte < 128 {
        let b = byte as u8;
        table[byte] = if b.is_ascii_alphanumeric() {
            b.to_ascii_lowercase()
        } else if json && (b == b'"' || b == b'\\') {
            SPECIAL
        } else {
            SEPARATOR
        };
        byte += 1;
    }
    table
}

static TEXT_BYTES: [u8; 256] = byte_table(false);
static JSON_BYTES: [u8; 256] = byte_table(true);

/// Folds bytes until one `table` marks special and returns how many it
/// read. The hot loop: separators collapse without a branch, and the only
/// branch (the stop) is rarely taken, so it runs at a few cycles a byte.
fn push_run(bytes: &[u8], table: &[u8; 256], out: &mut Vec<u8>) -> usize {
    let mut separated = out.last() == Some(&SEPARATOR);
    for (index, &byte) in bytes.iter().enumerate() {
        let folded = table[usize::from(byte)];
        if folded == SPECIAL {
            return index;
        }
        // Write every byte, then take back a separator after a separator.
        out.push(folded);
        let repeated = separated && folded == SEPARATOR;
        out.truncate(out.len() - usize::from(repeated));
        separated = folded == SEPARATOR;
    }
    bytes.len()
}

/// What one character folds to, before whitespace is collapsed: its
/// canonical decomposition without combining marks, lowercased. `false`
/// when the result can depend on its neighbours (a capital sigma, or a
/// character that canonical ordering may move).
fn fold_parts(c: char, mut emit: impl FnMut(char)) -> bool {
    let mut alone = true;
    decompose_canonical(c, |part| {
        if is_combining_mark(part) {
            return;
        }
        if part == 'Σ' || canonical_combining_class(part) != 0 {
            alone = false;
        }
        for lower in part.to_lowercase() {
            emit(lower);
        }
    });
    alone
}

/// Exactly [`fold`]`(text)`, computed one character at a time.
pub(super) fn fold_fast(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut space = false;
    let mut push = |c: char, out: &mut String| {
        if c.is_whitespace() {
            space = !out.is_empty();
        } else {
            if space {
                out.push(' ');
                space = false;
            }
            out.push(c);
        }
    };
    for c in text.chars() {
        if c.is_ascii() {
            push(c.to_ascii_lowercase(), &mut out);
        } else if !fold_parts(c, |part| push(part, &mut out)) {
            return fold(text);
        }
    }
    out
}

fn push_separator(out: &mut Vec<u8>) {
    if out.last() != Some(&SEPARATOR) {
        out.push(SEPARATOR);
    }
}

fn push_ascii(byte: u8, out: &mut Vec<u8>) {
    match TEXT_BYTES[usize::from(byte)] {
        SEPARATOR => push_separator(out),
        folded => out.push(folded),
    }
}

/// One already folded character, as the skeleton writes it.
fn push_folded(c: char, out: &mut Vec<u8>) {
    if c.is_ascii() {
        push_ascii(c as u8, out);
    } else if c.is_alphanumeric() {
        let c = if c == 'ς' { 'σ' } else { c };
        out.extend_from_slice(c.encode_utf8(&mut [0; 4]).as_bytes());
    } else {
        push_separator(out);
    }
}

/// Adds one character of the original text; `false` when canonical ordering
/// may move what it folds to (never in current Unicode).
fn push_char(c: char, out: &mut Vec<u8>) -> bool {
    if c.is_ascii() {
        push_ascii(c as u8, out);
        return true;
    }
    let mut ordered = true;
    decompose_canonical(c, |part| {
        if is_combining_mark(part) {
            return;
        }
        if canonical_combining_class(part) != 0 {
            ordered = false;
        }
        for lower in part.to_lowercase() {
            push_folded(lower, out);
        }
    });
    ordered
}

/// The skeleton of a text; `false` when it cannot be written.
fn text_skeleton(text: &str, out: &mut Vec<u8>) -> bool {
    out.clear();
    let mut at = 0;
    loop {
        at += push_run(&text.as_bytes()[at..], &TEXT_BYTES, out);
        // The run stopped before a non-ASCII character, or at the end.
        let Some(c) = text[at..].chars().next() else {
            return true;
        };
        if !push_char(c, out) {
            return false;
        }
        at += c.len_utf8();
    }
}

fn skip_json_whitespace(json: &[u8], mut at: usize) -> usize {
    while json
        .get(at)
        .is_some_and(|b| matches!(b, b' ' | b'\t' | b'\n' | b'\r'))
    {
        at += 1;
    }
    at
}

/// Where the string starting at `start` (after its opening quote) ends, and
/// whether it has an escape.
fn json_string_end(json: &[u8], start: usize) -> Option<(usize, bool)> {
    let mut at = start;
    let mut escaped = false;
    loop {
        at += memchr::memchr2(b'"', b'\\', json.get(at..)?)?;
        if json[at] == b'"' {
            return Some((at, escaped));
        }
        // The escaped byte, then (for \u) four hex digits, hold no quote.
        escaped = true;
        at += 2;
    }
}

fn hex4(json: &[u8], at: usize) -> Option<u32> {
    let digits = json.get(at..at + 4)?;
    digits.iter().try_fold(0, |value, &digit| {
        Some(value * 16 + char::from(digit).to_digit(16)?)
    })
}

/// The character a `\u` escape at `at` spells (a surrogate pair takes two),
/// and the escape's length.
fn unicode_escape(json: &[u8], at: usize) -> Option<(char, usize)> {
    let unit = hex4(json, at + 2)?;
    if (0xD800..0xDC00).contains(&unit) {
        if json.get(at + 6..at + 8)? != b"\\u" {
            return None;
        }
        let low = hex4(json, at + 8)?;
        if !(0xDC00..0xE000).contains(&low) {
            return None;
        }
        let c = char::from_u32(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))?;
        return Some((c, 12));
    }
    Some((char::from_u32(unit)?, 6))
}

/// Adds the skeleton of the JSON string starting at `start` and returns the
/// index of its closing quote; `None` when it cannot be read.
fn push_json_string(json: &[u8], start: usize, out: &mut Vec<u8>) -> Option<usize> {
    let mut at = start;
    loop {
        at += push_run(json.get(at..)?, &JSON_BYTES, out);
        let byte = *json.get(at)?;
        match byte {
            b'"' => return Some(at),
            b'\\' => match json.get(at + 1)? {
                // `"`, `\`, `/` and control characters: separators.
                b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't' => {
                    push_separator(out);
                    at += 2;
                }
                b'u' => {
                    let (c, length) = unicode_escape(json, at)?;
                    if !push_char(c, out) {
                        return None;
                    }
                    at += length;
                }
                _ => return None,
            },
            // The run stopped, so this starts a non-ASCII character.
            _ => {
                let width = match byte {
                    0xC2..=0xDF => 2,
                    0xE0..=0xEF => 3,
                    0xF0..=0xF4 => 4,
                    _ => return None,
                };
                let c = std::str::from_utf8(json.get(at..at + width)?)
                    .ok()?
                    .chars()
                    .next()?;
                if !push_char(c, out) {
                    return None;
                }
                at += width;
            }
        }
    }
}

/// The skeletons of a `transcript.json`'s `"text"` values, one after
/// another. A key with an escape might spell `text`, so its value counts
/// too. `false` when the file cannot be read this way.
fn transcript_skeleton(json: &[u8], out: &mut Vec<u8>) -> bool {
    out.clear();
    let mut at = 0;
    while let Some(offset) = memchr::memchr(b'"', &json[at..]) {
        let start = at + offset + 1;
        let Some((end, escaped)) = json_string_end(json, start) else {
            return false;
        };
        at = end + 1;
        // A key is followed by a colon; anything else was a value.
        let colon = skip_json_whitespace(json, at);
        if json.get(colon) != Some(&b':') {
            continue;
        }
        at = skip_json_whitespace(json, colon + 1);
        if json.get(at) != Some(&b'"') || !(escaped || &json[start..end] == b"text") {
            continue;
        }
        push_separator(out);
        let Some(end) = push_json_string(json, at + 1, out) else {
            return false;
        };
        push_separator(out);
        at = end + 1;
    }
    true
}

/// One search word as a skeleton.
struct Needle {
    finder: Finder<'static>,
    /// Up to three ASCII characters match only as a whole word.
    whole_word: bool,
    /// The word starts (ends) with a separator, which stands for the
    /// characters around it as well.
    open_start: bool,
    open_end: bool,
}

impl Needle {
    /// `None` when the word has no letter or digit to look for.
    fn new(term: &str) -> Option<Self> {
        let mut bytes = Vec::with_capacity(term.len());
        for c in term.chars() {
            push_folded(c, &mut bytes);
        }
        if bytes.iter().all(|&b| b == SEPARATOR) {
            return None;
        }
        Some(Self {
            whole_word: term.chars().count() <= 3 && term.is_ascii(),
            open_start: bytes.first() == Some(&SEPARATOR),
            open_end: bytes.last() == Some(&SEPARATOR),
            finder: Finder::new(&bytes).into_owned(),
        })
    }

    fn found_in(&self, skeleton: &[u8]) -> bool {
        let length = self.finder.needle().len();
        let mut from = 0;
        while let Some(offset) = self.finder.find(&skeleton[from..]) {
            let start = from + offset;
            if !self.whole_word {
                return true;
            }
            let end = start + length;
            let before = self.open_start || start == 0 || skeleton[start - 1] == SEPARATOR;
            let after = self.open_end || end == skeleton.len() || skeleton[end] == SEPARATOR;
            if before && after {
                return true;
            }
            from = start + 1;
        }
        false
    }
}

/// Whether a text may contain any of the search words.
pub(super) struct Prefilter {
    needles: Vec<Needle>,
    /// Some word has no letter or digit, so any text may match it.
    everything: bool,
    buffer: Cell<Vec<u8>>,
}

impl Prefilter {
    pub(super) fn new(terms: &[String]) -> Self {
        let needles: Vec<Option<Needle>> = terms.iter().map(|t| Needle::new(t)).collect();
        Self {
            everything: needles.iter().any(Option::is_none),
            needles: needles.into_iter().flatten().collect(),
            buffer: Cell::default(),
        }
    }

    fn found(&self, skeleton: impl FnOnce(&mut Vec<u8>) -> bool) -> bool {
        if self.everything {
            return true;
        }
        if self.needles.is_empty() {
            return false;
        }
        let mut buffer = self.buffer.take();
        let found = !skeleton(&mut buffer) || self.needles.iter().any(|n| n.found_in(&buffer));
        self.buffer.set(buffer);
        found
    }

    /// `false` only when no search word can match `fold(text)`.
    pub(super) fn may_match(&self, text: &str) -> bool {
        self.found(|out| text_skeleton(text, out))
    }

    /// `false` only when no search word can match any segment of the
    /// transcript these bytes decode to.
    pub(super) fn may_match_transcript(&self, json: &[u8]) -> bool {
        self.found(|out| transcript_skeleton(json, out))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::search::word_range;

    /// SplitMix64: deterministic and dependency-free.
    pub(crate) struct Random(pub u64);

    impl Random {
        pub(crate) fn next(&mut self) -> u64 {
            self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
            let mut z = self.0;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
            z ^ (z >> 31)
        }

        pub(crate) fn below(&mut self, n: usize) -> usize {
            (self.next() % n as u64) as usize
        }

        pub(crate) fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
            &items[self.below(items.len())]
        }
    }

    /// Characters where folding goes wrong if done carelessly.
    pub(crate) const TRICKY: &[&str] = &[
        "a",
        "B",
        "z",
        "Q",
        "0",
        "7",
        " ",
        "  ",
        "\n",
        "\t",
        "\u{b}",
        "-",
        ".",
        ",",
        "'",
        "\"",
        "\\",
        "/",
        "_",
        "é",
        "É",
        "e\u{301}",
        "E\u{301}",
        "\u{301}",
        "\u{345}",
        "\u{316}",
        "\u{301}\u{316}",
        "ά",
        "Ά",
        "ΐ",
        "Σ",
        "σ",
        "ς",
        "ΟΔΟΣ",
        "Σοφία",
        "İ",
        "ı",
        "ß",
        "ẞ",
        "\u{212a}",
        "ǅ",
        "ǆ",
        "한",
        "\u{1100}\u{1161}",
        "東京",
        "会议",
        "ア",
        "ｱ",
        "Ж",
        "ж",
        "đ",
        "Đ",
        "ž",
        "Ž",
        "č",
        "ć",
        "ш",
        "مرحبا",
        "😀",
        "👍🏽",
        "\u{a0}",
        "\u{2000}",
        "\u{3000}",
        "½",
        "①",
        "ﬁ",
        "क",
        "\u{93f}",
        "\u{94d}",
        "\u{200d}",
        "\u{ad}",
        "\u{feff}",
        "\u{0}",
        "\u{1}",
        "\u{7f}",
        "\u{85}",
        "\u{2028}",
        "Å",
        "\u{212b}",
        "ǈ",
        "Ⅻ",
        "ⅻ",
        "𝐀",
        "ℌ",
    ];

    pub(crate) fn tricky_text(random: &mut Random, max: usize) -> String {
        (0..random.below(max) + 1)
            .map(|_| *random.pick(TRICKY))
            .collect()
    }

    /// What the skeleton should be, built from `fold` itself.
    fn skeleton_of_folded(folded: &str) -> Vec<u8> {
        let mut out = Vec::new();
        for c in folded.chars() {
            push_folded(c, &mut out);
        }
        out
    }

    fn trimmed(bytes: &[u8]) -> &[u8] {
        let start = bytes
            .iter()
            .position(|&b| b != SEPARATOR)
            .unwrap_or(bytes.len());
        let end = bytes
            .iter()
            .rposition(|&b| b != SEPARATOR)
            .map_or(start, |e| e + 1);
        &bytes[start..end]
    }

    fn skeleton(text: &str) -> Vec<u8> {
        let mut out = Vec::new();
        assert!(text_skeleton(text, &mut out), "{text:?}");
        out
    }

    fn check(text: &str) {
        let folded = fold(text);
        assert_eq!(fold_fast(text), folded, "{text:?}");
        assert_eq!(
            trimmed(&skeleton(text)),
            trimmed(&skeleton_of_folded(&folded)),
            "{text:?}"
        );
    }

    #[test]
    fn every_scalar_folds_the_same_alone_and_among_marks() {
        let mut text = String::new();
        for c in (0..=0x10_FFFF).filter_map(char::from_u32) {
            // The shortcuts rely on this; they would fall back otherwise.
            assert!(
                canonical_combining_class(c) == 0 || is_combining_mark(c),
                "{c:?}"
            );
            text.clear();
            text.push(c);
            check(&text);
            text.clear();
            text.push_str("A\u{316}");
            text.push(c);
            text.push_str("\u{301}b");
            check(&text);
        }
    }

    #[test]
    fn fast_fold_and_skeleton_match_fold_on_fuzzed_text() {
        let mut random = Random(1);
        for _ in 0..200_000 {
            check(&tricky_text(&mut random, 12));
        }
    }

    #[test]
    fn a_capital_sigma_takes_the_slow_path() {
        assert_eq!(fold_fast("ΟΔΟΣ ΚΑΙ"), "οδος και");
        assert_eq!(fold_fast("ΟΔΟΣ ΚΑΙ"), fold("ΟΔΟΣ ΚΑΙ"));
    }

    fn may_match(term: &str, text: &str) -> bool {
        Prefilter::new(&[term.to_string()]).may_match(text)
    }

    #[test]
    fn skips_what_cannot_match() {
        assert!(may_match("izvestaj", "IZVEŠTAJ o radu"));
        assert!(may_match("cafe", "Short CAFÉ note"));
        assert!(may_match("οδος", "ΟΔΟΣ"));
        assert!(may_match("会议", "东京会议记录"));
        assert!(may_match("api", "the API, works"));
        assert!(!may_match("api", "rapid growth"));
        assert!(!may_match("telescope", "the quick brown fox"));
        assert!(may_match("a b", "x a\n\tb y"));
        assert!(!may_match("a b", "x ab y"));
        // A word without letters or digits may match anything.
        assert!(may_match("...", "plain"));
        // No words: nothing matches, as in the matcher.
        assert!(!Prefilter::new(&[]).may_match("anything"));
    }

    /// Words worth looking for in `folded`: its own pieces, so many match.
    fn needles(random: &mut Random, folded: &str) -> Vec<String> {
        let chars: Vec<char> = folded.chars().collect();
        let mut out = vec![tricky_text(random, 3), fold(&tricky_text(random, 4))];
        for _ in 0..4 {
            if chars.is_empty() {
                break;
            }
            let start = random.below(chars.len());
            let end = (start + 1 + random.below(5)).min(chars.len());
            out.push(chars[start..end].iter().collect());
        }
        out.retain(|n| !n.is_empty());
        out
    }

    #[test]
    fn never_skips_a_text_the_matcher_would_find() {
        let mut random = Random(2);
        let mut found = 0;
        let mut skipped = 0;
        for _ in 0..200_000 {
            let text = tricky_text(&mut random, 10);
            let folded = fold(&text);
            for needle in needles(&mut random, &folded) {
                let matches = word_range(&needle, &folded).is_some();
                let maybe = may_match(&needle, &text);
                assert!(maybe || !matches, "{needle:?} in {text:?}");
                found += usize::from(matches);
                skipped += usize::from(!maybe);
            }
        }
        // The fuzz exercised both sides.
        assert!(found > 100_000 && skipped > 100_000, "{found} {skipped}");
    }

    /// `text` as a JSON string, with some characters escaped the long way.
    pub(crate) fn json_string(random: &mut Random, text: &str) -> String {
        let mut out = String::from('"');
        for c in text.chars() {
            let mut units = [0u16; 2];
            let escape_all = random.below(4) == 0;
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '/' if random.below(2) == 0 => out.push_str("\\/"),
                '\n' => out.push_str("\\n"),
                '\t' => out.push_str("\\t"),
                c if (c as u32) < 0x20 || escape_all => {
                    for unit in c.encode_utf16(&mut units) {
                        out.push_str(&format!("\\u{unit:04x}"));
                    }
                }
                c => out.push(c),
            }
        }
        out.push('"');
        out
    }

    #[test]
    fn never_skips_a_transcript_the_matcher_would_find() {
        let mut random = Random(3);
        let mut found = 0;
        let mut skipped = 0;
        for _ in 0..20_000 {
            let texts: Vec<String> = (0..random.below(3) + 1)
                .map(|_| tricky_text(&mut random, 8))
                .collect();
            let segments: Vec<String> = texts
                .iter()
                .enumerate()
                .map(|(index, text)| {
                    // Keys spelled with escapes still name the field.
                    let key = *random.pick(&["\"text\"", "\"te\\u0078t\"", "\"\\u0074ext\""]);
                    format!(
                        "{{\"end\": {index}.5, \"speaker\": \"them\", \"start\": {index}.0, {key} : {}}}",
                        json_string(&mut random, text)
                    )
                })
                .collect();
            let json = format!(
                "{{\n  \"engine\": \"t\\\"e\\\\xt\",\n  \"segments\": [{}]\n}}",
                segments.join(",\n")
            );
            let decoded: lokalbot_core::Transcript =
                serde_json::from_str(&json).unwrap_or_else(|e| panic!("{e}: {json}"));
            assert_eq!(
                decoded.segments.iter().map(|s| &s.text).collect::<Vec<_>>(),
                texts.iter().collect::<Vec<_>>()
            );
            let folded: Vec<String> = texts.iter().map(|t| fold(t)).collect();
            let joined = folded.join(" ");
            for needle in needles(&mut random, &joined) {
                let matches = folded.iter().any(|f| word_range(&needle, f).is_some());
                let maybe = Prefilter::new(std::slice::from_ref(&needle))
                    .may_match_transcript(json.as_bytes());
                assert!(maybe || !matches, "{needle:?} in {json}");
                found += usize::from(matches);
                skipped += usize::from(!maybe);
            }
        }
        assert!(found > 10_000 && skipped > 10_000, "{found} {skipped}");
    }

    #[test]
    fn reads_only_text_values_and_gives_up_on_what_it_cannot_read() {
        let filter = Prefilter::new(&["speaker".to_string(), "naive".to_string()]);
        let json = br#"{"segments": [{"speaker": "speaker", "text": "Na\u00efve"}]}"#;
        assert!(filter.may_match_transcript(json));
        let json = br#"{"segments": [{"speaker": "speaker", "text": "plain"}]}"#;
        assert!(!filter.may_match_transcript(json));
        // Unreadable: maybe, and the decoder decides.
        for broken in [
            &br#"{"text": "\ud800"}"#[..],
            br#"{"text": "\x"}"#,
            br#"{"text": "\u12"}"#,
            b"{\"text\": \"\xff\"}",
            br#"{"text": "open"#,
        ] {
            assert!(filter.may_match_transcript(broken), "{broken:?}");
        }
        // UTF-16 never decodes, so skipping it changes nothing.
        let utf16: Vec<u8> = "{\"text\": \"plain\"}"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        assert!(serde_json::from_slice::<lokalbot_core::Transcript>(&utf16).is_err());
    }
}
