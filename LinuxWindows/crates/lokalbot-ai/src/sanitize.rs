//! `PromptContextSanitizer`: prompt-ready text without control bytes,
//! ragged spacing or stacked blank lines. Punctuation is kept.

/// Control characters become spaces, every newline variant becomes `\n`,
/// inline whitespace collapses to one space, blank-line runs collapse to one,
/// edges are trimmed. With `max_characters`, the result is cut at a word
/// boundary with a trailing `…` counted inside the cap.
pub fn sanitize(text: &str, max_characters: Option<usize>) -> String {
    let mut folded = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                folded.push('\n');
            }
            '\n' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}' => folded.push('\n'),
            c if c.is_control() || is_format(c) => folded.push(' '),
            c => folded.push(c),
        }
    }
    let mut lines: Vec<String> = Vec::new();
    let mut pending_blank = false;
    for line in folded.split('\n') {
        let collapsed = line
            .split(is_inline_whitespace)
            .filter(|w| !w.is_empty())
            .collect::<Vec<_>>()
            .join(" ");
        if collapsed.is_empty() {
            pending_blank = !lines.is_empty();
        } else {
            if pending_blank {
                lines.push(String::new());
            }
            pending_blank = false;
            lines.push(collapsed);
        }
    }
    let trimmed = lines.join("\n").trim().to_string();
    match max_characters {
        None => trimmed,
        Some(0) => String::new(),
        Some(cap) if trimmed.chars().count() <= cap => trimmed,
        Some(cap) => hard_cap(&trimmed, cap),
    }
}

/// Unicode format characters (Cf) Swift's control set also removes.
fn is_format(c: char) -> bool {
    matches!(c, '\u{AD}' | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2064}' | '\u{FEFF}')
}

fn is_inline_whitespace(c: char) -> bool {
    c != '\n' && c.is_whitespace()
}

fn hard_cap(text: &str, cap: usize) -> String {
    let budget = cap - 1;
    if budget == 0 {
        return text.chars().take(cap).collect();
    }
    let head: String = text.chars().take(budget).collect();
    if let Some(index) = head.rfind(char::is_whitespace) {
        let word = head[..index].trim();
        if !word.is_empty() {
            return format!("{word}…");
        }
    }
    format!("{head}…")
}

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

/// Secrets, payment cards and IBANs replaced by `[REDACTED…]` markers
/// (`ScreenContextPrivacy.redact`), with how many were replaced. Model output
/// and screen text pass through it before they are shown, saved or sent.
pub fn redaction(text: &str) -> (String, usize) {
    if text.is_empty() {
        return (String::new(), 0);
    }
    let mut output = text.to_string();
    let mut count = 0;
    for (expression, replacement) in redaction_rules() {
        let matches = expression.find_iter(&output).filter(|m| m.is_ok()).count();
        if matches == 0 {
            continue;
        }
        if let Ok(replaced) = expression.try_replacen(&output, 0, *replacement) {
            count += matches;
            output = replaced.into_owned();
        }
    }
    for (expression, replacement, is_match) in checked_rules() {
        let ranges: Vec<(usize, usize)> = expression
            .find_iter(&output)
            .filter_map(Result::ok)
            .filter(|m| is_match(m.as_str()))
            .map(|m| (m.start(), m.end()))
            .collect();
        if ranges.is_empty() {
            continue;
        }
        count += ranges.len();
        for (start, end) in ranges.into_iter().rev() {
            output.replace_range(start..end, replacement);
        }
    }
    (output, count)
}

/// [`redaction`] without the count.
pub fn redact(text: &str) -> String {
    redaction(text).0
}

type Rule = (fancy_regex::Regex, &'static str);
type CheckedRule = (fancy_regex::Regex, &'static str, fn(&str) -> bool);

fn redaction_rules() -> &'static [Rule] {
    static RULES: std::sync::OnceLock<Vec<Rule>> = std::sync::OnceLock::new();
    RULES.get_or_init(|| {
        [
            // The name may carry a prefix ("DB_PASSWORD", "GITHUB_TOKEN").
            (
                r#"(?i)\b((?:[A-Za-z0-9]+[_.-])*(?:api[\s_-]?key|access[\s_-]?token|auth[\s_-]?token|client[\s_-]?secret|password|passwd|secret|private[\s_-]?key|access[_-]?key|account[_-]?key|shared[_-]?access[_-]?key|token))(\s*[:=]\s*)["']?(?!\[REDACTED)[^\s"',;]{6,}"#,
                "${1}${2}[REDACTED]",
            ),
            (r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}", "Bearer [REDACTED]"),
            (r"\bAKIA[0-9A-Z]{16}\b", "[REDACTED_AWS_KEY]"),
            (r"(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b", "[REDACTED_TOKEN]"),
            (r"\bsk-[A-Za-z0-9_-]{16,}\b", "[REDACTED_KEY]"),
            (r"\bgithub_pat_[A-Za-z0-9_]{22,}", "[REDACTED_TOKEN]"),
            (r"\bglpat-[A-Za-z0-9_-]{20,}", "[REDACTED_TOKEN]"),
            (r"\bxox[abposr]-[A-Za-z0-9-]{10,}", "[REDACTED_TOKEN]"),
            (r"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+", "[REDACTED_WEBHOOK]"),
            (r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}", "[REDACTED_KEY]"),
            (r"\bAIza[0-9A-Za-z_-]{35}", "[REDACTED_KEY]"),
            (r"\bGOCSPX-[A-Za-z0-9_-]{20,}", "[REDACTED_KEY]"),
            (r"\bnpm_[A-Za-z0-9]{36}", "[REDACTED_TOKEN]"),
            (r"\bhf_[A-Za-z0-9]{30,}", "[REDACTED_TOKEN]"),
            (r"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}", "[REDACTED_KEY]"),
            (r"\bpypi-[A-Za-z0-9_-]{50,}", "[REDACTED_TOKEN]"),
            // "postgres://admin:hunter22@db:5432" keeps its user and host.
            (r"(?i)\b([a-z][a-z0-9+.-]*://[^\s:/@]+):(?!\[REDACTED)[^\s@/]+@", "${1}:[REDACTED]@"),
            (r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b", "[REDACTED_JWT]"),
            (
                r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
                "[REDACTED_PRIVATE_KEY]",
            ),
        ]
        .into_iter()
        .map(|(pattern, replacement)| {
            (fancy_regex::Regex::new(pattern).expect("built-in redaction pattern"), replacement)
        })
        .collect()
    })
}

/// Numbers whose checksum makes them almost certainly a payment card (a
/// known issuer prefix and Luhn) or an IBAN (mod 97); order, tracking and
/// phone numbers stay readable.
fn checked_rules() -> &'static [CheckedRule] {
    static RULES: std::sync::OnceLock<Vec<CheckedRule>> = std::sync::OnceLock::new();
    RULES.get_or_init(|| {
        let card =
            r"\b(?:\d{13,19}|\d{4}([ -])\d{4}\1\d{4}\1\d{4}(?:\1\d{3})?|\d{4}([ -])\d{6}\2\d{5})\b";
        let iban = r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b";
        vec![
            (
                fancy_regex::Regex::new(card).expect("card pattern"),
                "[REDACTED_CARD]",
                is_payment_card_number,
            ),
            (
                fancy_regex::Regex::new(iban).expect("IBAN pattern"),
                "[REDACTED_IBAN]",
                is_iban,
            ),
        ]
    })
}

/// A known issuer prefix (Visa, Mastercard, Amex, Diners, Discover, JCB,
/// UnionPay) and a valid Luhn checksum.
pub fn is_payment_card_number(candidate: &str) -> bool {
    let digits: Vec<u32> = candidate.chars().filter_map(|c| c.to_digit(10)).collect();
    if !(13..=19).contains(&digits.len()) {
        return false;
    }
    let two = digits[0] * 10 + digits[1];
    let three = two * 10 + digits[2];
    let four = three * 10 + digits[3];
    let issued = digits[0] == 4
        || (51..=55).contains(&two)
        || (2_221..=2_720).contains(&four)
        || [34, 36, 37, 38, 39, 62, 65].contains(&two)
        || (300..=305).contains(&three)
        || four == 6_011
        || (644..=649).contains(&three)
        || (3_528..=3_589).contains(&four);
    if !issued {
        return false;
    }
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(index, digit)| {
            let value = if index % 2 == 1 { digit * 2 } else { *digit };
            if value > 9 { value - 9 } else { value }
        })
        .sum();
    sum.is_multiple_of(10)
}

/// The IBAN mod-97 check.
pub fn is_iban(candidate: &str) -> bool {
    let compact: Vec<char> = candidate.chars().filter(|c| !c.is_whitespace()).collect();
    if !(15..=34).contains(&compact.len()) {
        return false;
    }
    let mut remainder: u64 = 0;
    for c in compact[4..].iter().chain(&compact[..4]) {
        let value = if c.is_ascii_alphabetic() {
            u64::from(c.to_ascii_uppercase() as u8) - 55
        } else if let Some(digit) = c.to_digit(10) {
            u64::from(digit)
        } else {
            return false;
        };
        remainder = (remainder * if value > 9 { 100 } else { 10 } + value) % 97;
    }
    remainder == 1
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
