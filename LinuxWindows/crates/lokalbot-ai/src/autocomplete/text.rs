//! Character classes the autocomplete rules share. Swift's `Character`
//! properties map onto `char` here; a combining mark counts as part of the
//! word it follows, as it would inside one Swift `Character`.

use unicode_normalization::char::is_combining_mark;

/// `Character.isLetter || Character.isNumber`.
pub(crate) fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || is_combining_mark(c)
}

/// `Character.isLetter`.
pub(crate) fn is_letter(c: char) -> bool {
    c.is_alphabetic() || is_combining_mark(c)
}

/// `Character.isNewline`.
pub(crate) fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Swift's `CharacterSet.controlCharacters`: Cc plus the format characters
/// (Cf) a model or a host can leak into text.
pub(crate) fn is_control(c: char) -> bool {
    c.is_control()
        || matches!(c, '\u{AD}' | '\u{600}'..='\u{605}' | '\u{61C}' | '\u{6DD}' | '\u{70F}'
            | '\u{180E}' | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{206F}' | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}')
}

/// `Character.isPunctuation || Character.isSymbol`: anything visible that is
/// not part of a word.
pub(crate) fn is_punctuation_or_symbol(c: char) -> bool {
    !is_word_char(c) && !c.is_whitespace() && !is_control(c)
}

/// `cotypingBeginsSpacelessScriptWord`: scripts written without spaces
/// between words (CJK, kana, Hangul, Thai, Lao, Khmer, Myanmar).
pub(crate) fn begins_spaceless_word(c: char) -> bool {
    matches!(u32::from(c),
        0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF
        | 0xAC00..=0xD7A3 | 0x1100..=0x11FF | 0x0E00..=0x0E7F | 0x0E80..=0x0EFF
        | 0x1780..=0x17FF | 0x1000..=0x109F | 0x20000..=0x2A6DF | 0x30000..=0x3134F)
}

pub(crate) fn is_cjk_sentence_terminator(c: char) -> bool {
    matches!(c, '\u{3002}' | '\u{FF01}' | '\u{FF1F}' | '\u{FF61}')
}

pub(crate) fn is_cjk_closing_punctuation(c: char) -> bool {
    matches!(
        c,
        '\u{300D}' | '\u{300F}' | '\u{FF09}' | '\u{3011}' | '\u{3009}' | '\u{300B}' | '\u{FF63}'
    )
}

pub(crate) fn is_cjk_opening_bracket(c: char) -> bool {
    matches!(
        c,
        '\u{300C}' | '\u{300E}' | '\u{FF08}' | '\u{3010}' | '\u{3008}' | '\u{300A}' | '\u{FF62}'
    )
}

/// `cotypingIsPhraseClauseBoundary`: the CJK comma marks.
pub(crate) fn is_phrase_clause_boundary(c: char) -> bool {
    matches!(c, '\u{3001}' | '\u{FF0C}' | '\u{FF64}')
}

pub(crate) fn binds_to_preceding_spaceless_word(c: char) -> bool {
    is_cjk_sentence_terminator(c) || is_phrase_clause_boundary(c) || is_cjk_closing_punctuation(c)
}

/// Periods after these do not end a sentence.
pub(crate) const ABBREVIATIONS: [&str; 14] = [
    "mr", "mrs", "ms", "dr", "st", "vs", "eg", "ie", "etc", "no", "fig", "approx", "inc", "ltd",
];

/// Suffixes that make `name.suffix` a domain or a file name, not two sentences.
pub(crate) const DOMAIN_OR_FILE_SUFFIXES: [&str; 31] = [
    "ai", "app", "co", "com", "css", "dev", "edu", "env", "gov", "html", "io", "js", "json", "jsx",
    "local", "lock", "md", "me", "net", "org", "py", "rs", "swift", "toml", "ts", "tsx", "txt",
    "uk", "us", "yaml", "yml",
];

/// Characters a URL, address or file name is made of.
pub(crate) fn is_url_like(c: char) -> bool {
    is_word_char(c) || ".:/@_+-~%#?=&".contains(c)
}

/// Whether `token` (no spaces) reads as a URL, an address or a file name.
pub(crate) fn is_url_domain_or_file(token: &str) -> bool {
    if !token.contains('.') {
        return false;
    }
    let lower = token.to_lowercase();
    if lower.contains("://") || lower.contains('@') || lower.contains('/') {
        return true;
    }
    if lower != token {
        return false;
    }
    lower
        .split('.')
        .rfind(|part| !part.is_empty())
        .is_some_and(|suffix| DOMAIN_OR_FILE_SUFFIXES.contains(&suffix))
}

/// The letters directly before byte `end` of `text`.
pub(crate) fn trailing_letters(text: &str, end: usize) -> &str {
    let head = &text[..end];
    let start = head
        .char_indices()
        .rev()
        .take_while(|(_, c)| is_letter(*c))
        .last()
        .map_or(end, |(i, _)| i);
    &head[start..]
}

/// The character before byte `index`, if any.
pub(crate) fn char_before(text: &str, index: usize) -> Option<char> {
    text[..index].chars().next_back()
}

/// The character at byte `index`, if any.
pub(crate) fn char_at(text: &str, index: usize) -> Option<char> {
    text[index..].chars().next()
}

/// Whether the period at byte `period` ends a sentence: not after a digit
/// (`1.5`), a lone letter (`U.S.`) or an abbreviation (`e.g.`, `Dr.`).
pub(crate) fn is_terminal_period(text: &str, period: usize) -> bool {
    let Some(before) = char_before(text, period) else {
        return true;
    };
    if before.is_numeric() {
        return false;
    }
    if is_letter(before) {
        let before_start = period - before.len_utf8();
        let prior_is_letter = char_before(text, before_start).is_some_and(is_letter);
        if !prior_is_letter {
            return false;
        }
        let word = trailing_letters(text, period).to_lowercase();
        if ABBREVIATIONS.contains(&word.as_str()) {
            return false;
        }
    }
    true
}

/// Lowercase without diacritics, for comparisons (`folding(options:
/// [.caseInsensitive, .diacriticInsensitive])`).
pub(crate) fn fold(text: &str) -> String {
    use unicode_normalization::UnicodeNormalization as _;
    text.nfd()
        .filter(|c| !is_combining_mark(*c))
        .collect::<String>()
        .to_lowercase()
}

/// User-perceived characters, as one Backspace or Delete removes them.
pub(crate) fn grapheme_count(text: &str) -> usize {
    use unicode_segmentation::UnicodeSegmentation as _;
    text.graphemes(true).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn periods_end_sentences_except_after_digits_initials_and_abbreviations() {
        assert!(is_terminal_period("done.", 4));
        assert!(!is_terminal_period("1.", 1));
        assert!(!is_terminal_period("U.", 1));
        assert!(!is_terminal_period("see e.g.", 7));
        assert!(!is_terminal_period("Dr.", 2));
        assert!(is_terminal_period(".", 0));
    }

    #[test]
    fn domains_and_files_are_recognized() {
        assert!(is_url_domain_or_file("example.com"));
        assert!(is_url_domain_or_file("main.rs"));
        assert!(is_url_domain_or_file("https://x.y"));
        assert!(!is_url_domain_or_file("done.Next"));
        assert!(!is_url_domain_or_file("word"));
    }

    #[test]
    fn folding_drops_case_and_diacritics() {
        assert_eq!(fold("Déjà Vu"), "deja vu");
        assert_eq!(grapheme_count("e\u{301}x"), 2);
        assert!(is_word_char('\u{301}'));
        assert!(!is_punctuation_or_symbol(' '));
        assert!(is_punctuation_or_symbol('!'));
    }
}
