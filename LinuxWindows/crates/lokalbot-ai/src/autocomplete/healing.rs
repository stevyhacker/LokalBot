//! Token healing (`CotypingTokenHealing`) on llama-server.
//!
//! A prompt that ends mid-word ("…I wanted to follo") tokenizes unnaturally
//! at its end, and a small model then treats the fragment as a finished
//! word. Healing cuts the prompt back to the last word boundary ("…I wanted
//! to") and makes the cut text (" follo") a decode constraint: generation
//! must first re-type those bytes through natural tokens (" follow"
//! overshooting the caret), then runs free. The suggestion is everything
//! after the constraint. A trailing space is healed the same way, so " is"
//! is one natural token instead of a lone space token.
//!
//! macOS enforces the constraint inside its llama.cpp decode loop. Here it is
//! a GBNF grammar on the `/completion` request, `root ::= "<cut text>" any*`:
//! llama.cpp's grammar sampler accepts a token only while its bytes stay on
//! that path, so " follow" passes for " follo" and " up" does not. macOS also
//! searches four tokenizations of a fragment for the most probable path;
//! the grammar picks the best compatible token one step at a time.

/// Longest word fragment worth healing; longer runs (URLs, identifiers)
/// would spend many constrained steps on text the model should not assist.
pub const MAX_WORD_LENGTH: usize = 16;
pub const MAX_SEPARATOR_LENGTH: usize = 8;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Split {
    /// The prompt cut at the word boundary, separator removed too.
    pub healed_prompt: String,
    /// The cut text the output must begin with.
    pub required_prefix: String,
}

/// `CotypingTokenHealing.split`: `None` when the prompt does not end in a
/// word fragment or spaces after a word, the fragment is too long, or
/// cutting it would leave no context.
pub fn split(prompt: &str) -> Option<Split> {
    let last = prompt.chars().next_back()?;
    if last.is_whitespace() && !super::text::is_newline(last) {
        let start = prompt
            .char_indices()
            .rev()
            .take_while(|(_, c)| c.is_whitespace() && !super::text::is_newline(*c))
            .last()
            .map_or(prompt.len(), |(i, _)| i);
        if prompt[start..].chars().count() > MAX_SEPARATOR_LENGTH
            || prompt[..start].trim().is_empty()
        {
            return None;
        }
        // A finished word followed by a space must not be extended
        // (cat → cats): replay the space through natural tokens, then hide it.
        return Some(Split {
            healed_prompt: prompt[..start].to_string(),
            required_prefix: prompt[start..].to_string(),
        });
    }
    if !is_word_character(last) {
        return None;
    }
    let word_start = prompt
        .char_indices()
        .rev()
        .take_while(|(_, c)| is_word_character(*c))
        .last()
        .map_or(prompt.len(), |(i, _)| i);
    if prompt[word_start..].chars().count() > MAX_WORD_LENGTH {
        return None;
    }
    let cut_start = prompt[..word_start]
        .char_indices()
        .rev()
        .take_while(|(_, c)| c.is_whitespace() && !super::text::is_newline(*c))
        .last()
        .map_or(word_start, |(i, _)| i);
    if prompt[cut_start..word_start].chars().count() > MAX_SEPARATOR_LENGTH {
        return None;
    }
    let healed = &prompt[..cut_start];
    if healed.trim().is_empty() {
        return None;
    }
    Some(Split {
        healed_prompt: healed.to_string(),
        required_prefix: prompt[cut_start..].to_string(),
    })
}

fn is_word_character(c: char) -> bool {
    super::text::is_word_char(c)
}

/// The prompt and required prefix a request is sent with
/// (`LocalLlamaCotypingEngine.healedGeneration`): healing applies when the
/// caret is inside or right after a word, or after a space.
pub fn healed_generation(prompt: &str, word_prefix: &str, ends_with_whitespace: bool) -> Split {
    if (!word_prefix.is_empty() || ends_with_whitespace)
        && let Some(split) = split(prompt)
    {
        return split;
    }
    Split {
        healed_prompt: prompt.to_string(),
        required_prefix: String::new(),
    }
}

/// The GBNF grammar that makes generation start with `required_prefix` and
/// lets anything follow. Every character is written as a code point escape,
/// so no prefix can break out of the string literal.
pub fn grammar(required_prefix: &str) -> String {
    let mut literal = String::with_capacity(required_prefix.len() * 6);
    for c in required_prefix.chars() {
        let code = u32::from(c);
        if code <= 0xFFFF {
            literal.push_str(&format!("\\u{code:04X}"));
        } else {
            literal.push_str(&format!("\\U{code:08X}"));
        }
    }
    format!("root ::= \"{literal}\" [^\\x00]*")
}

/// `CotypingRequiredPrefixMatcher`: one token's bytes against the remaining
/// required prefix. Bytes, because tokens can split a UTF-8 character.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PrefixMatch {
    /// The token lies inside the remaining prefix.
    Consumes(usize),
    /// The token covers the rest of the prefix and goes on; the extra bytes
    /// are the first visible text.
    Overshoots(Vec<u8>),
    Mismatch,
}

pub fn match_piece(piece: &[u8], remaining: &[u8]) -> PrefixMatch {
    if piece.is_empty() || remaining.is_empty() {
        return PrefixMatch::Mismatch;
    }
    if piece.len() <= remaining.len() {
        return if remaining.starts_with(piece) {
            PrefixMatch::Consumes(piece.len())
        } else {
            PrefixMatch::Mismatch
        };
    }
    if piece.starts_with(remaining) {
        PrefixMatch::Overshoots(piece[remaining.len()..].to_vec())
    } else {
        PrefixMatch::Mismatch
    }
}

/// Whether an overshoot goes on spelling the word (a letter, digit,
/// apostrophe or the lead byte of a multi-byte character).
pub fn extends_word(extra: &[u8]) -> bool {
    match extra.first() {
        None => false,
        Some(&b) if b >= 0x80 => true,
        Some(&b) => b.is_ascii_alphanumeric() || b == b'\'',
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(healed: &str, required: &str) -> Option<Split> {
        Some(Split {
            healed_prompt: healed.into(),
            required_prefix: required.into(),
        })
    }

    #[test]
    fn splits_a_trailing_fragment_with_its_separator() {
        assert_eq!(split("I wanted to follo"), s("I wanted to", " follo"));
        assert_eq!(split("(follo"), s("(", "follo"));
        assert_eq!(
            split("vielen Dank für deine Unterstüt"),
            s("vielen Dank für deine", " Unterstüt")
        );
    }

    #[test]
    fn replays_the_space_after_a_completed_word() {
        assert_eq!(split("I wanted to "), s("I wanted to", " "));
        assert_eq!(split("end."), None);
        for separator in [" ", "\t", "  ", "\u{a0}"] {
            assert_eq!(split(&format!("word{separator}")), s("word", separator));
        }
        assert_eq!(split(&format!("word{}", " ".repeat(9))), None);
        assert_eq!(split("   "), None);
    }

    #[test]
    fn newlines_stay_in_the_context() {
        assert_eq!(split("line one\nfollo"), s("line one\n", "follo"));
        assert_eq!(split("line one\n"), None);
        assert_eq!(split("line one\n  follo"), s("line one\n", "  follo"));
    }

    #[test]
    fn fragment_length_is_bounded_and_needs_context() {
        let at_limit = "a".repeat(MAX_WORD_LENGTH);
        assert_eq!(
            split(&format!("see {at_limit}")),
            s("see", &format!(" {at_limit}"))
        );
        assert_eq!(split(&format!("see {at_limit}a")), None);
        assert_eq!(split("follo"), None);
        assert_eq!(split("  follo"), None);
    }

    #[test]
    fn healing_applies_inside_and_after_words_only() {
        assert_eq!(
            healed_generation("I wanted to follo", "follo", false).required_prefix,
            " follo"
        );
        assert_eq!(
            healed_generation("Let's celebrate ", "", true).required_prefix,
            " "
        );
        let unhealed = healed_generation("Done.", "", false);
        assert_eq!(unhealed.healed_prompt, "Done.");
        assert_eq!(unhealed.required_prefix, "");
    }

    #[test]
    fn grammar_escapes_every_character() {
        assert_eq!(grammar(" fo"), r#"root ::= "\u0020\u0066\u006F" [^\x00]*"#);
        assert_eq!(grammar("\"😀"), r#"root ::= "\u0022\U0001F600" [^\x00]*"#);
    }

    #[test]
    fn pieces_match_the_remaining_prefix_byte_by_byte() {
        let m = |piece: &str, remaining: &str| match_piece(piece.as_bytes(), remaining.as_bytes());
        assert_eq!(m(" fol", " follo"), PrefixMatch::Consumes(4));
        assert_eq!(m(" follo", " follo"), PrefixMatch::Consumes(6));
        assert_eq!(
            m(" follow", " follo"),
            PrefixMatch::Overshoots(b"w".to_vec())
        );
        assert_eq!(m(" xyz", " follo"), PrefixMatch::Mismatch);
        assert_eq!(m(" follxx", " follo"), PrefixMatch::Mismatch);
        assert_eq!(m("", " follo"), PrefixMatch::Mismatch);
        assert_eq!(m(" f", ""), PrefixMatch::Mismatch);
        let u = "ü".as_bytes();
        assert_eq!(match_piece(&u[..1], u), PrefixMatch::Consumes(1));
    }

    #[test]
    fn overshoots_that_extend_the_word() {
        assert!(extends_word(b"w"));
        assert!(extends_word(b"0"));
        assert!(extends_word(b"'t"));
        assert!(extends_word(&[0xC3]));
        for extra in [".", ",", " ", "-", ". And"] {
            assert!(!extends_word(extra.as_bytes()), "{extra:?}");
        }
        assert!(!extends_word(b""));
    }
}
