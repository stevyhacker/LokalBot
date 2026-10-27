//! Interface copy only. Never apply translation lookup to user content, model
//! prompts, serialized values, paths, or protocol identifiers.

use std::sync::atomic::{AtomicUsize, Ordering};

#[rustfmt::skip]
mod catalogs;
pub use catalogs::LANGUAGES;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Language {
    pub code: &'static str,
    pub name: &'static str,
    pub english_name: &'static str,
    pub rtl: bool,
}

static CURRENT: AtomicUsize = AtomicUsize::new(0);
static FOLLOW_SYSTEM: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

/// Same matching rules as AppLanguage.swift, including script/region aliases.
/// Explicit `ar-EG` is Egyptian Arabic; a system `ar-EG` is standard Arabic.
pub fn resolve(preference: &str, preferred: &[impl AsRef<str>]) -> &'static Language {
    if preference != "system"
        && let Some(language) = LANGUAGES.iter().find(|l| l.code == preference)
    {
        return language;
    }
    if preference != "system" {
        return &LANGUAGES[0];
    }
    for language in preferred {
        let normalized = language
            .as_ref()
            .split(['.', '@'])
            .next()
            .unwrap_or("")
            .replace('_', "-")
            .to_lowercase();
        let parts: Vec<_> = normalized.split('-').collect();
        let code = match parts[0] {
            "zh" => {
                if parts.contains(&"hant")
                    || (!parts.contains(&"hans")
                        && parts.iter().any(|p| ["tw", "hk", "mo"].contains(p)))
                {
                    "zh-Hant"
                } else {
                    "zh-Hans"
                }
            }
            "sr" | "cnr" => "sr-Latn",
            "arz" => "ar-EG",
            code => code,
        };
        if let Some(language) = LANGUAGES.iter().find(|l| l.code == code) {
            return language;
        }
    }
    &LANGUAGES[0]
}

/// GNU message locale precedence. C/POSIX explicitly selects English, even
/// when LANGUAGE contains another language. Windows uses the OS preference list.
pub fn unix_preferences(get: impl Fn(&str) -> Option<String>) -> Vec<String> {
    let effective = ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|key| get(key).filter(|s| !s.is_empty()));
    if effective
        .as_deref()
        .is_some_and(|s| matches!(s.split('.').next(), Some("C" | "POSIX")))
    {
        return vec!["en".into()];
    }
    let mut languages: Vec<_> = get("LANGUAGE")
        .unwrap_or_default()
        .split(':')
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    languages.extend(effective);
    languages
}

pub fn system_preferences() -> Vec<String> {
    #[cfg(target_os = "linux")]
    {
        let preferences = unix_preferences(|name| std::env::var(name).ok());
        if !preferences.is_empty() {
            return preferences;
        }
    }
    sys_locale::get_locales().collect()
}

pub fn set_language(preference: &str) -> &'static Language {
    let language = resolve(preference, &system_preferences());
    CURRENT.store(
        LANGUAGES
            .iter()
            .position(|l| l.code == language.code)
            .unwrap_or(0),
        Ordering::Relaxed,
    );
    FOLLOW_SYSTEM.store(preference == "system", Ordering::Relaxed);
    language
}

pub fn current() -> &'static Language {
    &LANGUAGES[CURRENT.load(Ordering::Relaxed)]
}

pub fn translate<'a>(locale: &str, key: &'a str) -> &'a str {
    catalogs::lookup(locale, key)
        .or_else(|| catalogs::lookup("en", key))
        .unwrap_or(key)
}

pub fn tr(key: &str) -> &str {
    translate(current().code, key)
}

/// Replaces named/numbered fields once, after translation. Argument text is
/// never looked up or interpreted as another template (including braces).
pub fn format_in(locale: &str, key: &str, arguments: &[(&str, String)]) -> String {
    let template = translate(locale, key);
    let mut result = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        result.push_str(&rest[..start]);
        let Some(end) = rest[start + 1..].find('}') else {
            result.push_str(&rest[start..]);
            return result;
        };
        let end = start + 1 + end;
        let name = &rest[start + 1..end];
        if let Some((_, value)) = arguments.iter().find(|(key, _)| *key == name) {
            result.push_str(value);
        } else {
            result.push_str(&rest[start..=end]);
        }
        rest = &rest[end + 1..];
    }
    result.push_str(rest);
    result
}

pub fn format(key: &str, arguments: &[(&str, String)]) -> String {
    format_in(current().code, key, arguments)
}

pub fn picker_label(preference: &str) -> &str {
    if preference == "system" {
        tr("Follow System")
    } else {
        LANGUAGES
            .iter()
            .find(|l| l.code == preference)
            .map_or(preference, |l| l.name)
    }
}

pub fn date_locale_for(code: &str) -> chrono::Locale {
    let name = match code {
        "en" => "en_US",
        "zh-Hans" => "zh_CN",
        "zh-Hant" => "zh_TW",
        "hi" => "hi_IN",
        "es" => "es_ES",
        "ar" => "ar_SA",
        "fr" => "fr_FR",
        "bn" => "bn_BD",
        "pt" => "pt_BR",
        "id" => "id_ID",
        "ur" => "ur_PK",
        "ru" => "ru_RU",
        "de" => "de_DE",
        "ja" => "ja_JP",
        "pcm" => "en_NG",
        "ar-EG" => "ar_EG",
        "mr" => "mr_IN",
        "vi" => "vi_VN",
        "te" => "te_IN",
        "sw" => "sw_KE",
        "ha" => "ha_NG",
        "ko" => "ko_KR",
        "it" => "it_IT",
        "sr-Latn" => "sr_RS@latin",
        name => name,
    };
    name.parse().unwrap_or(chrono::Locale::en_US)
}

pub fn date_locale() -> chrono::Locale {
    if FOLLOW_SYSTEM.load(Ordering::Relaxed)
        && let Some(system) = sys_locale::get_locale()
        && let Ok(locale) = system.replace('-', "_").parse()
    {
        return locale;
    }
    date_locale_for(current().code)
}

pub fn first_weekday() -> chrono::Weekday {
    first_weekday_in(date_locale())
}

pub fn first_weekday_in(locale: chrono::Locale) -> chrono::Weekday {
    use chrono::Datelike as _;
    // GNU locale data defines FIRST_WEEKDAY as a one-based offset from the
    // reference date in WEEK (normally 1997-11-30, a Sunday).
    let reference = pure_rust_locales::locale_match!(locale => LC_TIME::WEEK)
        .and_then(|week| week.get(1))
        .copied()
        .unwrap_or(19971130);
    let offset = pure_rust_locales::locale_match!(locale => LC_TIME::FIRST_WEEKDAY).unwrap_or(1);
    let base = chrono::NaiveDate::from_ymd_opt(
        (reference / 10000) as i32,
        ((reference / 100) % 100) as u32,
        (reference % 100) as u32,
    )
    .unwrap_or_else(|| chrono::NaiveDate::from_ymd_opt(1997, 11, 30).unwrap());
    (base + chrono::Days::new((offset.clamp(1, 7) - 1) as u64)).weekday()
}

/// Locale date/time order and 12/24-hour conventions, not a hard-coded US
/// layout. Storage timestamps, filenames and media timecodes never call this.
pub fn date_pattern(pattern: &str) -> &str {
    date_pattern_in(pattern, date_locale())
}

pub fn date_pattern_in(pattern: &str, locale: chrono::Locale) -> &str {
    // Retain the existing English presentation, while using the regional
    // date order and clock convention for other locales. Compact UI clocks
    // must not acquire seconds just because %X includes them.
    if locale == chrono::Locale::en_US {
        return pattern;
    }
    let time = pure_rust_locales::locale_match!(locale => LC_TIME::T_FMT);
    let twelve_hour = ["%I", "%l", "%r"].iter().any(|item| time.contains(item));
    match pattern {
        "%A, %B %-d, %Y" | "%A, %B %-d" => "%A, %x",
        "%a, %b %-d" => "%a, %x",
        "%b %-d, %Y at %-I:%M %p" | "%b %-d, %Y, %-I:%M %p" => {
            if twelve_hour {
                "%x %-I:%M %p"
            } else {
                "%x %H:%M"
            }
        }
        "%b %-d" | "%b %-d, %Y" | "%B %-d, %Y" => "%x",
        "%-I:%M %p" | "%-I:00 %p" => {
            if twelve_hour {
                "%-I:%M %p"
            } else {
                "%H:%M"
            }
        }
        "%-I:%M:%S %p" => {
            if twelve_hour {
                "%-I:%M:%S %p"
            } else {
                "%H:%M:%S"
            }
        }
        "%-I %p" => {
            if twelve_hour {
                "%-I %p"
            } else {
                "%H:%M"
            }
        }
        other => other,
    }
}

/// Content direction comes from its own first strong character, independently
/// of interface chrome. URLs/code/media controls can opt into LTR explicitly.
pub fn content_is_rtl(text: &str) -> bool {
    use unicode_bidi::{BidiClass, bidi_class};
    text.chars()
        .find_map(|ch| match bidi_class(ch) {
            BidiClass::L => Some(false),
            BidiClass::R | BidiClass::AL => Some(true),
            _ => None,
        })
        .unwrap_or(false)
}

/// Complete count phrases are translated together; never append an English
/// plural suffix to a translated noun.
pub fn count(n: usize, noun: &str) -> String {
    let (one, many) = match noun {
        "meeting" => ("{count} meeting", "{count} meetings"),
        "more meeting" => ("{count} more meeting", "{count} more meetings"),
        "older action" => ("{count} older action", "{count} older actions"),
        "decision" => ("{count} decision", "{count} decisions"),
        "screen moment" => ("{count} screen moment", "{count} screen moments"),
        "moment" => ("{count} moment", "{count} moments"),
        "result" => ("{count} result", "{count} results"),
        "conversation" => ("{count} conversation", "{count} conversations"),
        "person" => ("{count} person", "{count} people"),
        "message" => ("{count} message", "{count} messages"),
        "work session" => ("{count} work session", "{count} work sessions"),
        "app" => ("{count} app", "{count} apps"),
        _ => return format!("{} {noun}", number(n)),
    };
    format(if n == 1 { one } else { many }, &[("count", number(n))])
}

/// A count with the locale's digit grouping: "12,345", "12.345", "12 345".
pub fn number(n: usize) -> String {
    number_in(date_locale(), n)
}

pub fn number_in(locale: chrono::Locale, n: usize) -> String {
    let digits = n.to_string();
    let separator = pure_rust_locales::locale_match!(locale => LC_NUMERIC::THOUSANDS_SEP);
    if separator.is_empty() {
        return digits;
    }
    // POSIX grouping: group sizes from the right, the last one repeating,
    // until a size of -1 (or none) leaves the rest whole.
    let grouping = pure_rust_locales::locale_match!(locale => LC_NUMERIC::GROUPING);
    let mut sizes = grouping.iter();
    let mut size = 0;
    let mut rest = digits.as_str();
    let mut groups = Vec::new();
    loop {
        if let Some(next) = sizes.next() {
            size = *next;
        }
        let Ok(width) = usize::try_from(size) else {
            break;
        };
        if width == 0 || rest.len() <= width {
            break;
        }
        let (head, tail) = rest.split_at(rest.len() - width);
        groups.push(tail);
        rest = head;
    }
    groups.push(rest);
    groups.reverse();
    groups.join(separator)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_catalog_table_is_sorted_for_binary_search() {
        assert_eq!(catalogs::TABLES.len(), LANGUAGES.len());
        for (code, table) in catalogs::TABLES {
            assert!(
                table.windows(2).all(|pair| pair[0].0 < pair[1].0),
                "{code} is not strictly sorted"
            );
            for (key, value) in table.iter() {
                assert_eq!(catalogs::lookup(code, key), Some(*value));
            }
        }
        assert_eq!(catalogs::lookup("en", "no such key"), None);
        assert_eq!(catalogs::lookup("xx", "Settings"), None);
    }

    #[test]
    fn matches_the_mac_language_and_region_rules() {
        for (system, expected) in [
            ("zh_TW.UTF-8", "zh-Hant"),
            ("zh-HK", "zh-Hant"),
            ("zh-Hans-TW", "zh-Hans"),
            ("zh-Hant-CN", "zh-Hant"),
            ("sr-Cyrl-RS", "sr-Latn"),
            ("cnr-ME", "sr-Latn"),
            ("ar-EG", "ar"),
            ("arz", "ar-EG"),
            ("pt-PT", "pt"),
            ("it-IT", "it"),
            ("pcm-NG", "pcm"),
            ("ur-PK", "ur"),
            ("hr-HR", "en"),
            ("bs-BA", "en"),
        ] {
            assert_eq!(resolve("system", &[system]).code, expected, "{system}");
        }
        assert_eq!(resolve("system", &["fi-FI", "de-DE"]).code, "de");
        assert_eq!(resolve("ar-EG", &["en-US"]).code, "ar-EG");
        assert_eq!(resolve("en", &["de-DE"]).code, "en");
        assert_eq!(resolve("unknown", &["de-DE"]).code, "en");
    }

    #[test]
    fn unix_precedence_and_c_locale_are_respected() {
        let env = [
            ("LANG", "en_US.UTF-8"),
            ("LC_MESSAGES", "de_DE.UTF-8"),
            ("LANGUAGE", "fi:fr:de"),
        ];
        let get = |key: &str| {
            env.iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| v.to_string())
        };
        assert_eq!(unix_preferences(get), ["fi", "fr", "de", "de_DE.UTF-8"]);
        assert_eq!(
            unix_preferences(|k| if k == "LC_ALL" {
                Some("C.UTF-8".into())
            } else {
                get(k)
            }),
            ["en"]
        );
    }

    #[test]
    fn embedded_catalogs_translate_and_fall_back_safely() {
        assert_eq!(LANGUAGES.len(), 24);
        assert_eq!(translate("de", "Settings"), "Einstellungen");
        assert_eq!(translate("zh-Hans", "App language"), "界面语言");
        assert_eq!(translate("en", "Settings"), "Settings");
        assert_eq!(translate("unknown", "Settings"), "Settings");
        assert_eq!(
            translate("de", "an unknown diagnostic"),
            "an unknown diagnostic"
        );
        assert_eq!(
            LANGUAGES
                .iter()
                .filter(|l| l.rtl)
                .map(|l| l.code)
                .collect::<Vec<_>>(),
            ["ar", "ur", "ar-EG"]
        );
    }

    #[test]
    fn formatting_preserves_arbitrary_user_content() {
        let user_text = "日本語 {count} %s C:\\Users\\Me";
        assert_eq!(
            format_in(
                "en",
                "{title}: {count}",
                &[("title", user_text.into()), ("count", "2".into())]
            ),
            format!("{user_text}: 2")
        );
    }

    #[test]
    fn counts_use_the_locale_digit_grouping() {
        let number = |code: &str, n| number_in(date_locale_for(code), n);
        assert_eq!(number("en", 999), "999");
        assert_eq!(number("en", 1_234_567), "1,234,567");
        assert_eq!(number("de", 12_345), "12.345");
        assert_eq!(number("fr", 12_345), "12\u{202f}345");
        assert_eq!(number("bn", 1_234_567), "12,34,567");
        assert_eq!(number("ar", 12_345), "12345");
    }

    #[test]
    fn content_direction_does_not_follow_interface_language() {
        assert!(!content_is_rtl("123 Hello العربية"));
        assert!(content_is_rtl("123 العربية Hello"));
        assert!(!content_is_rtl("2026-10-19"));
    }

    #[test]
    fn dates_and_times_use_localized_names_and_order() {
        let date = chrono::NaiveDate::from_ymd_opt(2026, 10, 19).unwrap();
        assert_eq!(
            date.format_localized("%A", date_locale_for("de"))
                .to_string(),
            "Montag"
        );
        assert_ne!(
            date.format_localized("%x", date_locale_for("de"))
                .to_string(),
            date.format_localized("%x", date_locale_for("en"))
                .to_string()
        );
        assert_eq!(date_pattern("%Y-%m-%d"), "%Y-%m-%d");
        assert_eq!(
            first_weekday_in(chrono::Locale::de_DE),
            chrono::Weekday::Mon
        );
        assert_eq!(
            first_weekday_in(chrono::Locale::en_US),
            chrono::Weekday::Sun
        );
        assert_eq!(
            first_weekday_in(chrono::Locale::ar_EG),
            chrono::Weekday::Sat
        );
        assert_eq!(date_pattern_in("%-I:%M %p", chrono::Locale::en_GB), "%H:%M");
        assert_eq!(
            date_pattern_in("%-I:%M %p", chrono::Locale::en_US),
            "%-I:%M %p"
        );
        for language in LANGUAGES.iter().filter(|l| l.code != "en") {
            assert_ne!(
                date_locale_for(language.code),
                chrono::Locale::en_US,
                "{} has no date locale",
                language.code
            );
        }
    }
}
