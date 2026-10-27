//! Text helpers shared by the engines and the transcript cleanup.

use std::collections::HashSet;

use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// `Transcript.normalizedText`: Whisper-style `<|…|>` control tokens removed,
/// whitespace collapsed, and empty when nothing alphanumeric is left.
pub fn normalized_text(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(start) = rest.find("<|") {
        out.push_str(&rest[..start]);
        out.push(' ');
        match rest[start + 2..].find("|>") {
            Some(end) => rest = &rest[start + 2 + end + 2..],
            None => {
                out.push_str(&rest[start..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    let collapsed = out.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().any(char::is_alphanumeric) {
        collapsed
    } else {
        String::new()
    }
}

/// Lowercased, accent-folded letter/digit runs (apostrophes kept inside words),
/// so "Marković", "Markovic" and "MARKOVIC" are one word.
pub fn folded_words(text: &str) -> Vec<String> {
    let folded: String = text
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect();
    folded
        .split(|c: char| !c.is_alphanumeric() && c != '\'' && c != '’')
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

/// `TranscriptionPrompt.normalized`: the trimmed prompt, or `None` when blank.
pub fn normalized_prompt(prompt: Option<&str>) -> Option<&str> {
    prompt.map(str::trim).filter(|p| !p.is_empty())
}

/// Text a prompt-capable model copied from its vocabulary prompt instead of
/// hearing (`TranscriptionPromptEcho`): on near-silent spans Qwen3-ASR returns
/// the hint list itself as a row of words.
pub struct PromptEcho {
    words: HashSet<String>,
    terms: HashSet<String>,
}

impl PromptEcho {
    /// `None` for a prompt without words, so callers skip the check cheaply.
    pub fn new(prompt: Option<&str>) -> Option<Self> {
        let prompt = normalized_prompt(prompt)?;
        let terms: Vec<String> = prompt
            .split([',', ';', '\n', '\r'])
            .map(|term| folded_words(term).join(" "))
            .filter(|term| !term.is_empty())
            .collect();
        if terms.is_empty() {
            return None;
        }
        let words = terms
            .iter()
            .flat_map(|t| t.split(' ').map(str::to_string))
            .collect();
        Some(Self {
            words,
            terms: terms.into_iter().collect(),
        })
    }

    /// Every word is a prompt word and the row is more than one listed term
    /// (a lone "Mila Novak" may be someone saying a name).
    pub fn matches(&self, text: &str) -> bool {
        let row = folded_words(text);
        if row.len() < 2 || !row.iter().all(|w| self.words.contains(w)) {
            return false;
        }
        !self.terms.contains(&row.join(" "))
    }
}

/// Vocabulary prompt → hotword list for Qwen3-ASR: the comma-, semicolon- or
/// line-separated terms, trimmed of trailing punctuation, at most 40 terms and
/// 480 characters (`TranscriptionVocabulary` limits).
pub fn prompt_terms(prompt: Option<&str>) -> Vec<String> {
    let Some(prompt) = normalized_prompt(prompt) else {
        return Vec::new();
    };
    let mut seen = HashSet::new();
    let mut total = 0usize;
    let mut terms = Vec::new();
    for raw in prompt.split([',', ';', '\n', '\r']) {
        let term = raw
            .trim()
            .trim_end_matches(['.', '!', '?'])
            .trim()
            .replace('\0', "");
        let chars = term.chars().count();
        if !(2..=60).contains(&chars) || !seen.insert(folded_words(&term).join(" ")) {
            continue;
        }
        if terms.len() == 40 || total + chars > 480 {
            break;
        }
        total += chars;
        terms.push(term);
    }
    terms
}

/// Joins span texts: a space between words, none between CJK characters.
pub fn join_texts<'a>(texts: impl IntoIterator<Item = &'a str>) -> String {
    let mut out = String::new();
    for text in texts {
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let joins_cjk =
            out.chars().last().is_some_and(is_cjk) && text.chars().next().is_some_and(is_cjk);
        if !out.is_empty() && !joins_cjk {
            out.push(' ');
        }
        out.push_str(text);
    }
    out
}

/// Han, kana and Hangul, which are written without spaces between words.
pub fn is_cjk(c: char) -> bool {
    matches!(c as u32,
        0x3040..=0x30FF | 0x31F0..=0x31FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF
        | 0xFF66..=0xFF9D | 0xAC00..=0xD7AF | 0x20000..=0x2FA1F | 0x30000..=0x323AF
        | 0x3000..=0x303F | 0xFF00..=0xFF65)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_like_macos() {
        assert_eq!(
            normalized_text("<|en|><|transcribe|> Hello   world <|0.00|>"),
            "Hello world"
        );
        assert_eq!(normalized_text("  ... "), "");
        assert_eq!(normalized_text("<|nospeech|>"), "");
        assert_eq!(normalized_text("a <|broken"), "a <|broken");
    }

    #[test]
    fn prompt_echo_rules() {
        let echo = PromptEcho::new(Some("Weekly sync\nMila Novak, Orion Launch, Acme.")).unwrap();
        assert!(echo.matches("Mila Novak, Orion Launch, Acme."));
        assert!(echo.matches("orion launch acme"));
        assert!(
            !echo.matches("Mila Novak"),
            "one listed term may be real speech"
        );
        assert!(!echo.matches("Mila said the launch slipped"));
        assert!(PromptEcho::new(Some("   ")).is_none());
        assert!(echo.matches("MILA NOVÁK, Acme"));
    }

    #[test]
    fn hotword_terms() {
        assert_eq!(
            prompt_terms(Some("Mila Novak, Orion Launch, Acme.")),
            vec!["Mila Novak", "Orion Launch", "Acme"]
        );
        assert_eq!(prompt_terms(Some("a, OK, ok")), vec!["OK"]);
        assert!(prompt_terms(None).is_empty());
    }

    #[test]
    fn joins_cjk_without_spaces() {
        assert_eq!(join_texts(["你好", "世界"]), "你好世界");
        assert_eq!(join_texts(["Hello", "world", ""]), "Hello world");
    }
}
