//! Privacy rules for day memory, ported from `ScreenContextPrivacy.swift`:
//! app and site exclusions, password managers, and secret redaction.
//!
//! The rules favor false positives on purpose: a redacted title stays useful,
//! while a stored credential cannot be taken back.

use std::sync::LazyLock;

use lokalbot_core::{ActivitySample, Settings};
use regex::{Captures, Regex};

/// App name stored for excluded apps and sites (`activity_blocks.app`).
pub const PRIVATE_APP: &str = "Private";

/// `app_id` the samplers give LokalBot's own windows. Their titles are never
/// read and [`disposition`] skips them.
pub const SELF_APP_ID: &str = "lokalbot";

/// What day memory may store for one sample
/// (`ScreenContextPrivacy.activityDisposition`).
#[derive(Clone, Debug, PartialEq)]
pub enum SampleDisposition {
    /// Store the sample. The title is redacted, or empty when a configured site
    /// exclusion cannot be ruled out; the URL is sanitized.
    Keep(ActivitySample),
    /// An excluded app or site: store the time as app [`PRIVATE_APP`] with an
    /// empty title and no URL.
    Private,
    /// Store nothing and leave the current block as it is, as when no app is
    /// frontmost: LokalBot's own windows and the lock screen.
    Skip,
}

/// Applies the user's exclusions, the built-in password-manager list and
/// title redaction to one sample.
pub fn disposition(sample: &ActivitySample, settings: &Settings) -> SampleDisposition {
    disposition_with_rules(
        sample,
        &settings.excluded_app_list(),
        &settings.excluded_domain_list(),
    )
}

/// [`disposition`] with explicit rule lists.
pub fn disposition_with_rules(
    sample: &ActivitySample,
    excluded_apps: &[String],
    excluded_domains: &[String],
) -> SampleDisposition {
    if is_skipped(&sample.app_id) {
        return SampleDisposition::Skip;
    }
    if is_excluded_app(&sample.app, &sample.app_id, excluded_apps)
        || is_excluded_url(sample.url.as_deref(), excluded_domains)
    {
        return SampleDisposition::Private;
    }
    let has_domain_rules = excluded_domains.iter().any(|rule| !rule.trim().is_empty());
    let url = sanitized_url(sample.url.as_deref());
    // A browser whose address is unknown cannot be shown to be outside a
    // configured site exclusion, so only its time is kept.
    let unverifiable_site =
        has_domain_rules && is_browser(&sample.app, &sample.app_id) && url.is_none();
    let title = if unverifiable_site {
        String::new()
    } else {
        redact(&sample.title).0
    };
    SampleDisposition::Keep(ActivitySample {
        title,
        url,
        ..sample.clone()
    })
}

/// App ids whose windows are not activity: LokalBot itself and lock screens.
fn is_skipped(app_id: &str) -> bool {
    let id = app_id.to_lowercase();
    id == SELF_APP_ID
        || matches!(
            id.as_str(),
            "lockapp.exe" | "logonui.exe" | "i3lock" | "xscreensaver" | "light-locker"
        )
}

/// Password managers and credential prompts are never captured, whatever the
/// editable list says. Ids are desktop-file ids, Wayland app ids, `WM_CLASS`
/// values and Windows executable names (lowercase).
const PASSWORD_MANAGER_IDS: &[&str] = &[
    "1password",
    "1password.exe",
    "com.1password.1password",
    "bitwarden",
    "bitwarden.exe",
    "com.bitwarden.desktop",
    "keepassxc",
    "keepassxc.exe",
    "org.keepassxc.keepassxc",
    "keepass",
    "keepass2",
    "keepass.exe",
    "keepassx",
    "keepassx.exe",
    "proton-pass",
    "proton pass",
    "proton pass.exe",
    "protonpass.exe",
    "me.proton.pass",
    "enpass",
    "enpass.exe",
    "dashlane",
    "dashlane.exe",
    "nordpass",
    "nordpass.exe",
    "keeperpasswordmanager.exe",
    "roboform.exe",
    "seahorse",
    "org.gnome.seahorse.application",
    "org.gnome.world.secrets",
    "kwalletmanager",
    "kwalletmanager5",
    "org.kde.kwalletmanager",
    "org.kde.kwalletmanager5",
    // The Windows credential prompt ("Windows Security").
    "credentialuibroker.exe",
];

/// Display names of the same apps, compared case-insensitively.
const PASSWORD_MANAGER_NAMES: &[&str] = &[
    "1password",
    "bitwarden",
    "proton pass",
    "enpass",
    "dashlane",
    "nordpass",
    "lastpass",
    "keeper password manager",
    "roboform",
    "passwords and keys",
    "kde wallet manager",
    "kwalletmanager",
    "credential manager ui host",
];

pub fn is_password_manager(app_name: &str, app_id: &str) -> bool {
    let id = app_id.to_lowercase();
    if PASSWORD_MANAGER_IDS.contains(&id.as_str()) {
        return true;
    }
    let name = app_name.trim().to_lowercase();
    // KeePass, KeePassXC, KeePassX, "KeePass Password Safe".
    name.starts_with("keepass") || PASSWORD_MANAGER_NAMES.contains(&name.as_str())
}

/// A rule excludes an app when it is a case-insensitive substring of the app
/// name, or when it contains a dot and equals the app id or a dotted prefix of
/// it (`ScreenContextPrivacy.isExcluded(appName:bundleIdentifier:rules:)`).
pub fn is_excluded_app(app_name: &str, app_id: &str, rules: &[String]) -> bool {
    if is_password_manager(app_name, app_id) {
        return true;
    }
    let id = app_id.to_lowercase();
    let name = app_name.to_lowercase();
    rules.iter().any(|raw| {
        let term = raw.trim();
        if term.is_empty() {
            return false;
        }
        let rule = term.to_lowercase();
        if name.contains(&rule) {
            return true;
        }
        rule.contains('.') && !id.is_empty() && (id == rule || id.starts_with(&format!("{rule}.")))
    })
}

/// Whether a page address matches a site rule: a URL prefix (`https://x/y`),
/// a host or `*.host` (subdomains included), or `host/path`
/// (`ScreenContextPrivacy.isExcluded(sourceURL:rules:)`).
pub fn is_excluded_url(source_url: Option<&str>, rules: &[String]) -> bool {
    let Some(source_url) = source_url else {
        return false;
    };
    if rules.is_empty() {
        return false;
    }
    let lowered = source_url.to_lowercase();
    let host = url::Url::parse(source_url)
        .ok()
        .and_then(|url| url.host_str().map(str::to_lowercase));
    rules.iter().any(|raw| {
        let mut rule = raw.trim().to_lowercase();
        if rule.is_empty() {
            return false;
        }
        if rule.contains("://") {
            return lowered.starts_with(&rule);
        }
        if let Some(stripped) = rule.strip_prefix("*.") {
            rule = stripped.to_string();
        }
        let rule = rule.trim_matches('/');
        if let Some(slash) = rule.find('/') {
            let host_rule = &rule[..slash];
            let Some(host) = &host else {
                return false;
            };
            if !host_matches(host, host_rule) {
                return false;
            }
            return lowered.contains(&rule[slash..]);
        }
        match &host {
            Some(host) => host_matches(host, rule),
            None => lowered.contains(rule),
        }
    })
}

fn host_matches(host: &str, rule: &str) -> bool {
    host == rule || host.ends_with(&format!(".{rule}"))
}

/// Removes credentials, query and fragment before an address is stored, at
/// most 800 characters (`ScreenContextPrivacy.sanitizedURL`).
pub fn sanitized_url(raw: Option<&str>) -> Option<String> {
    let raw = raw?.trim();
    if raw.is_empty() {
        return None;
    }
    let mut url = url::Url::parse(raw).ok()?;
    url.host_str()?;
    let _ = url.set_username("");
    let _ = url.set_password(None);
    url.set_query(None);
    url.set_fragment(None);
    Some(url.as_str().chars().take(800).collect())
}

/// Browsers, by app id (desktop id, executable) or display name.
pub fn is_browser(app_name: &str, app_id: &str) -> bool {
    const IDS: &[&str] = &[
        "firefox",
        "org.mozilla.firefox",
        "firefox-esr",
        "librewolf",
        "chrome",
        "google-chrome",
        "com.google.chrome",
        "chromium",
        "chromium-browser",
        "org.chromium.chromium",
        "microsoft-edge",
        "com.microsoft.edge",
        "msedge",
        "brave",
        "brave-browser",
        "com.brave.browser",
        "opera",
        "vivaldi",
        "vivaldi-stable",
        "zen",
        "app.zen_browser.zen",
        "epiphany",
        "org.gnome.epiphany",
        "falkon",
        "org.kde.falkon",
        "firefox.exe",
        "chrome.exe",
        "msedge.exe",
        "brave.exe",
        "opera.exe",
        "vivaldi.exe",
        "zen.exe",
        "librewolf.exe",
        "arc.exe",
    ];
    const NAMES: &[&str] = &[
        "firefox",
        "chrome",
        "google chrome",
        "chromium",
        "microsoft edge",
        "brave",
        "brave browser",
        "opera",
        "vivaldi",
        "zen",
        "zen browser",
        "arc",
        "librewolf",
        "web",
        "falkon",
    ];
    let id = app_id.to_lowercase();
    let name = app_name.trim().to_lowercase();
    IDS.contains(&id.as_str()) || NAMES.contains(&name.as_str())
}

/// Private or incognito window titles (`ScreenContextPrivacy.isPrivateWindow`).
pub fn is_private_window(title: &str) -> bool {
    let normalized = fold_diacritics(&title.to_lowercase());
    [
        "private browsing",
        "private window",
        "incognito",
        "inprivate",
        "navigation privee",
        "navegacion privada",
        "privates fenster",
    ]
    .iter()
    .any(|marker| normalized.contains(marker))
}

fn fold_diacritics(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            'à' | 'á' | 'â' | 'ä' | 'ã' | 'å' => 'a',
            'ç' => 'c',
            'è' | 'é' | 'ê' | 'ë' => 'e',
            'ì' | 'í' | 'î' | 'ï' => 'i',
            'ñ' => 'n',
            'ò' | 'ó' | 'ô' | 'ö' | 'õ' => 'o',
            'ù' | 'ú' | 'û' | 'ü' => 'u',
            other => other,
        })
        .collect()
}

// ------------------------------------------------------------- redaction

enum Guard {
    Always,
    /// Stands in for the Swift `(?!\[REDACTED)` lookahead: the capture group
    /// must not already be a redaction marker.
    NotRedacted(usize),
    /// Card and IBAN candidates must pass their checksum.
    Checksum(fn(&str) -> bool),
}

struct Rule {
    expression: Regex,
    replacement: &'static str,
    guard: Guard,
}

impl Rule {
    fn new(pattern: &str, replacement: &'static str, guard: Guard) -> Self {
        // Built-in patterns; a failure is a programming error caught by tests.
        let expression = Regex::new(pattern).expect("built-in redaction pattern compiles");
        Self {
            expression,
            replacement,
            guard,
        }
    }

    fn accepts(&self, caps: &Captures<'_>) -> bool {
        match self.guard {
            Guard::Always => true,
            Guard::NotRedacted(group) => caps
                .get(group)
                .is_none_or(|m| !m.as_str().starts_with("[REDACTED")),
            Guard::Checksum(check) => caps.get(0).is_some_and(|m| check(m.as_str())),
        }
    }

    /// Replaces every accepted match. A rejected match is retried one
    /// character later, which is how the Swift lookahead behaves.
    fn apply(&self, text: &str) -> (String, usize) {
        let mut out = String::with_capacity(text.len());
        let mut copied = 0;
        let mut position = 0;
        let mut count = 0;
        while position <= text.len() {
            let Some(caps) = self.expression.captures_at(text, position) else {
                break;
            };
            let Some(whole) = caps.get(0) else {
                break;
            };
            if !self.accepts(&caps) {
                position = next_boundary(text, whole.start());
                continue;
            }
            out.push_str(&text[copied..whole.start()]);
            caps.expand(self.replacement, &mut out);
            copied = whole.end();
            count += 1;
            position = if whole.is_empty() {
                next_boundary(text, whole.end())
            } else {
                whole.end()
            };
        }
        out.push_str(&text[copied..]);
        (out, count)
    }
}

fn next_boundary(text: &str, index: usize) -> usize {
    text[index..]
        .chars()
        .next()
        .map_or(text.len() + 1, |c| index + c.len_utf8())
}

static RULES: LazyLock<Vec<Rule>> = LazyLock::new(|| {
    use Guard::*;
    vec![
        // The name may carry a prefix ("DB_PASSWORD", "aws_secret_access_key").
        Rule::new(
            r#"(?i)\b((?:[A-Za-z0-9]+[_.-])*(?:api[\s_-]?key|access[\s_-]?token|auth[\s_-]?token|client[\s_-]?secret|password|passwd|secret|private[\s_-]?key|access[_-]?key|account[_-]?key|shared[_-]?access[_-]?key|token))(\s*[:=]\s*)["']?([^\s"',;]{6,})"#,
            "${1}${2}[REDACTED]",
            NotRedacted(3),
        ),
        Rule::new(
            r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}",
            "Bearer [REDACTED]",
            Always,
        ),
        Rule::new(r"\bAKIA[0-9A-Z]{16}\b", "[REDACTED_AWS_KEY]", Always),
        Rule::new(
            r"(?i)\bgh[pousr]_[A-Za-z0-9]{20,}\b",
            "[REDACTED_TOKEN]",
            Always,
        ),
        Rule::new(r"\bsk-[A-Za-z0-9_-]{16,}\b", "[REDACTED_KEY]", Always),
        Rule::new(
            r"\bgithub_pat_[A-Za-z0-9_]{22,}",
            "[REDACTED_TOKEN]",
            Always,
        ),
        Rule::new(r"\bglpat-[A-Za-z0-9_-]{20,}", "[REDACTED_TOKEN]", Always),
        Rule::new(
            r"\bxox[abposr]-[A-Za-z0-9-]{10,}",
            "[REDACTED_TOKEN]",
            Always,
        ),
        Rule::new(
            r"https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+",
            "[REDACTED_WEBHOOK]",
            Always,
        ),
        Rule::new(
            r"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}",
            "[REDACTED_KEY]",
            Always,
        ),
        Rule::new(r"\bAIza[0-9A-Za-z_-]{35}", "[REDACTED_KEY]", Always),
        Rule::new(r"\bGOCSPX-[A-Za-z0-9_-]{20,}", "[REDACTED_KEY]", Always),
        Rule::new(r"\bnpm_[A-Za-z0-9]{36}", "[REDACTED_TOKEN]", Always),
        Rule::new(r"\bhf_[A-Za-z0-9]{30,}", "[REDACTED_TOKEN]", Always),
        Rule::new(
            r"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}",
            "[REDACTED_KEY]",
            Always,
        ),
        Rule::new(r"\bpypi-[A-Za-z0-9_-]{50,}", "[REDACTED_TOKEN]", Always),
        // "postgres://admin:hunter22@db:5432" keeps its user and host.
        Rule::new(
            r"(?i)\b([a-z][a-z0-9+.-]*://[^\s:/@]+):([^\s@/]+)@",
            "${1}:[REDACTED]@",
            NotRedacted(2),
        ),
        Rule::new(
            r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b",
            "[REDACTED_JWT]",
            Always,
        ),
        Rule::new(
            r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
            "[REDACTED_PRIVATE_KEY]",
            Always,
        ),
    ]
});

/// Numbers whose checksum makes them almost certainly a payment card or an
/// IBAN. The Swift card pattern's `\1`/`\2` backreferences are spelled out
/// per separator.
static CHECKED_RULES: LazyLock<Vec<Rule>> = LazyLock::new(|| {
    vec![
        Rule::new(
            r"\b(?:[0-9]{13,19}|[0-9]{4} [0-9]{4} [0-9]{4} [0-9]{4}(?: [0-9]{3})?|[0-9]{4}-[0-9]{4}-[0-9]{4}-[0-9]{4}(?:-[0-9]{3})?|[0-9]{4} [0-9]{6} [0-9]{5}|[0-9]{4}-[0-9]{6}-[0-9]{5})\b",
            "[REDACTED_CARD]",
            Guard::Checksum(is_payment_card_number),
        ),
        Rule::new(
            r"\b[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,4})?\b",
            "[REDACTED_IBAN]",
            Guard::Checksum(is_iban),
        ),
    ]
});

/// Replaces credentials, tokens, private keys, payment cards and IBANs with
/// markers. Returns the text and how many replacements were made
/// (`ScreenContextPrivacy.redact`).
pub fn redact(text: &str) -> (String, usize) {
    if text.is_empty() {
        return (String::new(), 0);
    }
    let mut output = text.to_string();
    let mut count = 0;
    for rule in RULES.iter().chain(CHECKED_RULES.iter()) {
        let (next, matches) = rule.apply(&output);
        if matches > 0 {
            output = next;
            count += matches;
        }
    }
    (output, count)
}

/// A known issuer prefix and a valid Luhn checksum
/// (`ScreenContextPrivacy.isPaymentCardNumber`).
pub fn is_payment_card_number(candidate: &str) -> bool {
    let digits: Vec<u32> = candidate.chars().filter_map(|c| c.to_digit(10)).collect();
    if !(13..=19).contains(&digits.len()) {
        return false;
    }
    let two = digits[0] * 10 + digits[1];
    let three = two * 10 + digits[2];
    let four = three * 10 + digits[3];
    // Visa, Mastercard, Amex, Diners, Discover, JCB, UnionPay.
    let issued = digits[0] == 4
        || (51..=55).contains(&two)
        || (2221..=2720).contains(&four)
        || [34, 36, 37, 38, 39, 62, 65].contains(&two)
        || (300..=305).contains(&three)
        || four == 6011
        || (644..=649).contains(&three)
        || (3528..=3589).contains(&four);
    if !issued {
        return false;
    }
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(index, &digit)| {
            let value = if index % 2 == 1 { digit * 2 } else { digit };
            if value > 9 { value - 9 } else { value }
        })
        .sum();
    sum.is_multiple_of(10)
}

/// The IBAN mod-97 check (`ScreenContextPrivacy.isIBAN`).
pub fn is_iban(candidate: &str) -> bool {
    let compact: Vec<char> = candidate.chars().filter(|c| !c.is_whitespace()).collect();
    if !(15..=34).contains(&compact.len()) {
        return false;
    }
    let mut remainder: u32 = 0;
    for &character in compact[4..].iter().chain(compact[..4].iter()) {
        let value = if character.is_ascii_uppercase() {
            character as u32 - 55
        } else if let Some(digit) = character.to_digit(10) {
            digit
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
    use chrono::Utc;

    fn sample(app: &str, app_id: &str, title: &str) -> ActivitySample {
        ActivitySample {
            at: Utc::now(),
            app: app.into(),
            app_id: app_id.into(),
            title: title.into(),
            url: None,
            idle_seconds: 0.0,
        }
    }

    fn rules(list: &str) -> Vec<String> {
        lokalbot_core::settings::split_list(list)
    }

    #[test]
    fn key_value_secrets_keep_their_names() {
        assert_eq!(
            redact("DB_PASSWORD=hunter22 and api_key: abcdef123").0,
            "DB_PASSWORD=[REDACTED] and api_key: [REDACTED]"
        );
        assert_eq!(redact("GITHUB_TOKEN=abcdef12").1, 1);
        // Too short to be a secret.
        assert_eq!(redact("password=abc").0, "password=abc");
        // The opening quote is consumed, as in the Swift template.
        assert_eq!(
            redact(r#"password="hunter2222""#).0,
            r#"password=[REDACTED]""#
        );
    }

    #[test]
    fn redaction_is_idempotent() {
        let once = redact("token=abcdef123456 Bearer abcdefghijkl postgres://u:pw123456@db").0;
        let twice = redact(&once);
        assert_eq!(twice.0, once);
        assert_eq!(twice.1, 0);
    }

    #[test]
    fn a_skipped_marker_does_not_hide_a_later_secret() {
        // The lookahead port retries after a rejected match.
        assert_eq!(
            redact("password=[REDACTED]token=abcdefgh").0,
            "password=[REDACTED]token=[REDACTED]"
        );
    }

    #[test]
    fn provider_tokens() {
        let cases = [
            ("AKIAABCDEFGHIJKLMNOP", "[REDACTED_AWS_KEY]"),
            ("ghp_abcdefghijklmnopqrstuvwx", "[REDACTED_TOKEN]"),
            ("sk-abcdefghijklmnop1234", "[REDACTED_KEY]"),
            ("github_pat_abcdefghijklmnopqrstuvwxyz", "[REDACTED_TOKEN]"),
            ("glpat-abcdefghijklmnopqrst", "[REDACTED_TOKEN]"),
            ("xoxb-1234567890-abc", "[REDACTED_TOKEN]"),
            (
                "https://hooks.slack.com/services/T000/B000/XXXX",
                "[REDACTED_WEBHOOK]",
            ),
            ("sk_live_abcdefghijklmnop", "[REDACTED_KEY]"),
            ("AIzaSyA1234567890abcdefghijklmnopqrstuv", "[REDACTED_KEY]"),
            ("GOCSPX-abcdefghijklmnopqrstu", "[REDACTED_KEY]"),
            (
                "npm_abcdefghijklmnopqrstuvwxyz0123456789",
                "[REDACTED_TOKEN]",
            ),
            ("hf_abcdefghijklmnopqrstuvwxyz01234", "[REDACTED_TOKEN]"),
            ("SG.abcdefghijklmnopqr.abcdefghijklmnopqr", "[REDACTED_KEY]"),
            (
                "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop",
                "[REDACTED_JWT]",
            ),
        ];
        for (input, expected) in cases {
            assert_eq!(redact(input).0, expected, "{input}");
        }
        assert_eq!(
            redact("Authorization: Bearer abc.def-ghi_jkl").0,
            "Authorization: Bearer [REDACTED]"
        );
        assert_eq!(
            redact("postgres://admin:hunter22@db:5432/app").0,
            "postgres://admin:[REDACTED]@db:5432/app"
        );
        let pem = "a -----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY----- b";
        assert_eq!(redact(pem).0, "a [REDACTED_PRIVATE_KEY] b");
    }

    #[test]
    fn cards_and_ibans_need_a_valid_checksum() {
        assert_eq!(
            redact("card 4111 1111 1111 1111 ok").0,
            "card [REDACTED_CARD] ok"
        );
        assert_eq!(redact("4111-1111-1111-1111").0, "[REDACTED_CARD]");
        assert_eq!(redact("Amex 3782 822463 10005").0, "Amex [REDACTED_CARD]");
        // Luhn fails: an order number stays readable.
        assert_eq!(redact("order 4111111111111112").0, "order 4111111111111112");
        // Mixed separators are not a card.
        assert_eq!(redact("4111 1111-1111 1111").1, 0);
        assert_eq!(
            redact("IBAN DE89 3704 0044 0532 0130 00").0,
            "IBAN [REDACTED_IBAN]"
        );
        assert_eq!(redact("GB82WEST12345698765432").0, "[REDACTED_IBAN]");
        assert_eq!(redact("DE89 3704 0044 0532 0130 01").1, 0);
        assert!(!is_iban("DE89"));
    }

    #[test]
    fn ordinary_titles_are_untouched() {
        let title = "Design review – Q4 roadmap.pdf - Google Chrome";
        assert_eq!(redact(title), (title.to_string(), 0));
        assert_eq!(redact(""), (String::new(), 0));
    }

    #[test]
    fn excluded_apps_and_password_managers_become_private() {
        let apps = rules("1Password, Bitwarden, KeePassXC, KeePass");
        let out = disposition_with_rules(&sample("KeePassXC", "keepassxc", "Vault"), &apps, &[]);
        assert_eq!(out, SampleDisposition::Private);
        // Built-in list even when the user cleared theirs.
        let out = disposition_with_rules(&sample("Proton Pass", "proton pass.exe", "x"), &[], &[]);
        assert_eq!(out, SampleDisposition::Private);
        let out = disposition_with_rules(
            &sample("Windows Security", "CredentialUIBroker.exe", "x"),
            &[],
            &[],
        );
        assert_eq!(out, SampleDisposition::Private);
        // Substring of the name, and dotted id prefixes.
        assert!(is_excluded_app("Slack", "slack", &rules("sla")));
        assert!(is_excluded_app(
            "Notes",
            "org.gnome.notes",
            &rules("org.gnome")
        ));
        assert!(!is_excluded_app(
            "Notes",
            "org.gnomex.notes",
            &rules("org.gnome")
        ));
        assert!(is_excluded_app("Thing", "thing.exe", &rules("thing.exe")));
        assert!(!is_excluded_app("Terminal", "terminal", &rules("")));
    }

    #[test]
    fn self_and_lock_screen_are_skipped() {
        let out = disposition_with_rules(&sample("LokalBot", SELF_APP_ID, ""), &[], &[]);
        assert_eq!(out, SampleDisposition::Skip);
        let out = disposition_with_rules(&sample("Lock", "LockApp.exe", ""), &[], &[]);
        assert_eq!(out, SampleDisposition::Skip);
    }

    #[test]
    fn titles_are_redacted_and_kept() {
        let out = disposition_with_rules(
            &sample("Terminal", "gnome-terminal", "export TOKEN=abcdef123456"),
            &[],
            &[],
        );
        let SampleDisposition::Keep(kept) = out else {
            panic!("kept");
        };
        assert_eq!(kept.title, "export TOKEN=[REDACTED]");
        assert_eq!(kept.app, "Terminal");
    }

    #[test]
    fn site_rules_drop_unverifiable_browser_titles() {
        let domains = rules("bank.example");
        let kept = |out: SampleDisposition| match out {
            SampleDisposition::Keep(sample) => Some(sample),
            _ => None,
        };
        let out =
            disposition_with_rules(&sample("Firefox", "firefox", "Inbox - Mail"), &[], &domains);
        assert_eq!(
            kept(out).map(|s| (s.app, s.title)),
            Some(("Firefox".into(), String::new()))
        );
        // Native apps keep titles.
        let out = disposition_with_rules(
            &sample("Files", "org.gnome.nautilus", "Home"),
            &[],
            &domains,
        );
        assert_eq!(kept(out).map(|s| s.title), Some("Home".into()));
        // A known excluded address is private.
        let mut browsing = sample("Google Chrome", "chrome.exe", "Account");
        browsing.url = Some("https://login.bank.example/home?session=1".into());
        assert_eq!(
            disposition_with_rules(&browsing, &[], &domains),
            SampleDisposition::Private
        );
        // A readable address outside the rules keeps the title, sanitized.
        let mut browsing = sample("Google Chrome", "chrome.exe", "Docs");
        browsing.url = Some("https://user:pw@docs.example/a?b=c#d".into());
        let stored = kept(disposition_with_rules(&browsing, &[], &domains)).unwrap();
        assert_eq!(stored.title, "Docs");
        assert_eq!(stored.url.as_deref(), Some("https://docs.example/a"));
    }

    #[test]
    fn url_rules() {
        let check = |url: &str, rule: &str| is_excluded_url(Some(url), &rules(rule));
        assert!(check("https://mail.google.com/x", "google.com"));
        assert!(check("https://mail.google.com/x", "*.google.com"));
        assert!(!check("https://notgoogle.com/x", "google.com"));
        assert!(check("https://github.com/org/private", "github.com/org"));
        assert!(!check("https://github.com/other", "github.com/org"));
        assert!(check("https://github.com/org/x", "https://github.com/org"));
        assert!(!is_excluded_url(None, &rules("a.com")));
    }

    #[test]
    fn private_windows() {
        assert!(is_private_window("New Tab - Private Browsing"));
        assert!(is_private_window("Nouvel onglet – Navigation privée"));
        assert!(is_private_window("InPrivate - Microsoft Edge"));
        assert!(!is_private_window("Docs"));
    }
}
