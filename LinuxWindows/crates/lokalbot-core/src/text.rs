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

pub fn settings_search_matches(query: &str, haystack: &[&str]) -> bool {
    let words = search_folded(query);
    let words: Vec<&str> = words.split_whitespace().collect();
    if words.is_empty() {
        return true;
    }
    let hay = search_folded(&haystack.join(" "));
    words.iter().all(|word| hay.contains(word))
}

fn search_folded(text: &str) -> String {
    crate::ids::fold(text)
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect()
}

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

pub fn redact(text: &str) -> String {
    redaction(text).0
}

type Rule = (fancy_regex::Regex, &'static str);
type CheckedRule = (fancy_regex::Regex, &'static str, fn(&str) -> bool);

fn redaction_rules() -> &'static [Rule] {
    static RULES: std::sync::OnceLock<Vec<Rule>> = std::sync::OnceLock::new();
    RULES.get_or_init(|| {
        [
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
