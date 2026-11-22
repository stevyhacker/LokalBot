use unicode_normalization::char::is_combining_mark;

pub(crate) fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || is_combining_mark(c)
}

pub(crate) fn is_letter(c: char) -> bool {
    c.is_alphabetic() || is_combining_mark(c)
}

pub(crate) fn is_newline(c: char) -> bool {
    matches!(
        c,
        '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

pub(crate) fn is_control(c: char) -> bool {
    c.is_control()
        || matches!(c, '\u{AD}' | '\u{600}'..='\u{605}' | '\u{61C}' | '\u{6DD}' | '\u{70F}'
            | '\u{180E}' | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{206F}' | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}')
}

pub(crate) fn is_non_text_glyph(c: char) -> bool {
    matches!(
        u32::from(c),
        0xFFFC | 0xFFFD | 0xE000..=0xF8FF | 0xF0000..=0xFFFFD | 0x100000..=0x10FFFD
    )
}

pub(crate) fn is_punctuation_or_symbol(c: char) -> bool {
    !is_word_char(c) && !c.is_whitespace() && !is_control(c)
}

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

pub(crate) fn is_phrase_clause_boundary(c: char) -> bool {
    matches!(c, '\u{3001}' | '\u{FF0C}' | '\u{FF64}')
}

pub(crate) fn binds_to_preceding_spaceless_word(c: char) -> bool {
    is_cjk_sentence_terminator(c) || is_phrase_clause_boundary(c) || is_cjk_closing_punctuation(c)
}

pub(crate) const ABBREVIATIONS: [&str; 14] = [
    "mr", "mrs", "ms", "dr", "st", "vs", "eg", "ie", "etc", "no", "fig", "approx", "inc", "ltd",
];

pub(crate) const DOMAIN_OR_FILE_SUFFIXES: [&str; 31] = [
    "ai", "app", "co", "com", "css", "dev", "edu", "env", "gov", "html", "io", "js", "json", "jsx",
    "local", "lock", "md", "me", "net", "org", "py", "rs", "swift", "toml", "ts", "tsx", "txt",
    "uk", "us", "yaml", "yml",
];

pub(crate) fn is_url_like(c: char) -> bool {
    is_word_char(c) || ".:/@_+-~%#?=&".contains(c)
}

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

pub(crate) fn char_before(text: &str, index: usize) -> Option<char> {
    text[..index].chars().next_back()
}

pub(crate) fn char_at(text: &str, index: usize) -> Option<char> {
    text[index..].chars().next()
}

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

pub(crate) fn fold(text: &str) -> String {
    use unicode_normalization::UnicodeNormalization as _;
    text.nfd()
        .filter(|c| !is_combining_mark(*c))
        .collect::<String>()
        .to_lowercase()
}

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
