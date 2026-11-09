//! `PromptContextSanitizer`: prompt-ready text without control bytes,
//! ragged spacing or stacked blank lines. Punctuation is kept.

pub use lokalbot_core::text::{is_iban, is_payment_card_number, redact, redaction, sanitize};

/// `sanitize` with every whitespace run (newlines included) as one space.
pub fn single_line(text: &str, max_characters: usize) -> String {
    sanitize(text, Some(max_characters))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Whitespace runs collapsed and trimmed.
pub fn collapse(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The first `n` characters (not bytes).
pub fn prefix(text: &str, n: usize) -> String {
    text.chars().take(n).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleans_control_bytes_spacing_and_blank_lines() {
        assert_eq!(sanitize("raw\u{7}output", None), "raw output");
        assert_eq!(sanitize("  a \t b \r\n\n\n\n c  ", None), "a b\n\nc");
        assert_eq!(sanitize("\n\nx\n", None), "x");
    }

    #[test]
    fn caps_at_a_word_boundary_with_an_ellipsis() {
        assert_eq!(sanitize("alpha beta gamma", Some(12)), "alpha beta…");
        assert_eq!(sanitize("alphabetagamma", Some(5)), "alph…");
        assert_eq!(sanitize("short", Some(10)), "short");
        assert_eq!(sanitize("x", Some(0)), "");
        assert_eq!(single_line("a\nb   c", 100), "a b c");
    }

    #[test]
    fn redacts_secrets_cards_and_ibans() {
        assert_eq!(
            redact("DB_PASSWORD=hunter2222 next"),
            "DB_PASSWORD=[REDACTED] next"
        );
        assert_eq!(
            redact("Authorization: Bearer abcdefgh12345"),
            "Authorization: Bearer [REDACTED]"
        );
        assert_eq!(
            redact("key AKIAABCDEFGHIJKLMNOP end"),
            "key [REDACTED_AWS_KEY] end"
        );
        assert_eq!(redact("use sk-abcdefghijklmnop1234"), "use [REDACTED_KEY]");
        assert_eq!(
            redact("postgres://admin:hunter22@db:5432/app"),
            "postgres://admin:[REDACTED]@db:5432/app"
        );
        assert_eq!(
            redact("card 4111 1111 1111 1111 ok"),
            "card [REDACTED_CARD] ok"
        );
        assert_eq!(redact("order 1234567890123"), "order 1234567890123");
        assert_eq!(
            redact("IBAN GB82 WEST 1234 5698 7654 32"),
            "IBAN [REDACTED_IBAN]"
        );
        assert_eq!(
            redaction("nothing secret here"),
            ("nothing secret here".to_string(), 0)
        );
        let (text, count) = redaction("token: abcdef123456 and ghp_abcdefghijklmnopqrstuvwxyz");
        assert_eq!(text, "token: [REDACTED] and [REDACTED_TOKEN]");
        assert_eq!(count, 2);
        // Already redacted values are not redacted again.
        assert_eq!(redact("password=[REDACTED]"), "password=[REDACTED]");
    }
}
