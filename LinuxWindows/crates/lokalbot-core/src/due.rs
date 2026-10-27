//! Spoken due phrases to local calendar days (`ActionDueResolver.swift`).
//!
//! Deterministic English and Serbian grammar resolved against the day the
//! phrase was said. It never guesses: phrases outside the grammar stay
//! unresolved. Ranges resolve to their last day ("next week" is the Friday
//! of next week, "end of Q3" is September 30).
//!
//! Weeks start on Monday here (ISO), which only matters for "next <weekday>"
//! said on a Sunday; macOS follows the user's locale.

use std::sync::LazyLock;

use chrono::{DateTime, Datelike as _, Days, Months, NaiveDate, Utc, Weekday};
use regex::Regex;

const LEADING: &str = r"^(?:(?:by|before|until|till|on|due|this|do|u) )?(?:the )?";

const WEEKDAY_NAMES: &[(u32, &[&str])] = &[
    (1, &["sunday", "sun", "nedelja", "nedelju", "nedelje"]),
    (2, &["monday", "mon", "ponedeljak", "ponedeljka"]),
    (3, &["tuesday", "tue", "tues", "utorak", "utorka"]),
    (4, &["wednesday", "wed", "sreda", "sredu", "srede"]),
    (
        5,
        &[
            "thursday",
            "thu",
            "thur",
            "thurs",
            "cetvrtak",
            "četvrtak",
            "cetvrtka",
            "četvrtka",
        ],
    ),
    (6, &["friday", "fri", "petak", "petka"]),
    (7, &["saturday", "sat", "subota", "subotu", "subote"]),
];

const MONTH_NAMES: &[(u32, &[&str])] = &[
    (1, &["january", "jan", "januar"]),
    (2, &["february", "feb", "februar"]),
    (3, &["march", "mar", "mart"]),
    (4, &["april", "apr"]),
    (5, &["may", "maj"]),
    (6, &["june", "jun"]),
    (7, &["july", "jul"]),
    (8, &["august", "aug", "avgust"]),
    (9, &["september", "sep", "sept", "septembar"]),
    (10, &["october", "oct", "oktobar"]),
    (11, &["november", "nov", "novembar"]),
    (12, &["december", "dec", "decembar"]),
];

/// Longest first, so "couple of" wins over shorter words.
const NUMBER_WORDS: &[(&str, u32)] = &[
    ("couple of", 2),
    ("three", 3),
    ("seven", 7),
    ("eight", 8),
    ("four", 4),
    ("five", 5),
    ("nine", 9),
    ("one", 1),
    ("two", 2),
    ("six", 6),
    ("ten", 10),
    ("an", 1),
    ("a", 1),
];

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap_or_else(|err| panic!("invalid due-date pattern {pattern}: {err}"))
}

static TODAY: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"^(?:(?:by|before|until|till) )?(?:the )?(?:today|tonight|end of (?:the )?day|eod|close of business|cob|danas|do kraja dana)$",
    )
});
static LATER_TODAY: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"^(?:(?:during|later|sometime|over|within) (?:the )?day(?: today)?|(?:later|sometime) today|today during the day|(?:this|today) (?:morning|afternoon|evening)|(?:danas )?(?:tokom|u toku) dana|kasnije danas)$",
    )
});
static TOMORROW: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"^(?:(?:by|before|until|till) )?(?:tomorrow|sutra)(?: (?:morning|afternoon|evening|eod))?$",
    )
});
static THIS_WEEK: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"^(?:(?:by|before|until|till) )?(?:the )?(?:end of (?:the |this )?week|eow|this week|later this week|do kraja nedelje|ove nedelje)$",
    )
});
static NEXT_WEEK: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"^(?:(?:by|before|until|till|during|sometime) )?(?:the )?(?:end of )?next week$|^(?:sledece|sledeće) nedelje$",
    )
});
static THIS_MONTH: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"^(?:(?:by|before|until|till) )?(?:the )?(?:end of (?:the |this )?month|eom|this month|do kraja meseca)$",
    )
});
static NEXT_MONTH: LazyLock<Regex> = LazyLock::new(|| {
    regex(r"^(?:(?:by|before|until|till|during) )?(?:the )?(?:end of )?next month$")
});
static ISO_DATE: LazyLock<Regex> =
    LazyLock::new(|| regex(r"^(?:(?:by|before|until|on|due) )?(\d{4})-(\d{2})-(\d{2})$"));
static RELATIVE: LazyLock<Regex> = LazyLock::new(|| {
    let words = NUMBER_WORDS
        .iter()
        .map(|(w, _)| regex::escape(w))
        .collect::<Vec<_>>()
        .join("|");
    regex(&format!(
        r"^(?:(?:in|within|over) (?:the next )?)(\d{{1,3}}|{words}) (business day|working day|day|week|month)s?(?: from now)?$"
    ))
});
static WEEKDAY: LazyLock<Regex> = LazyLock::new(|| {
    let names = WEEKDAY_NAMES
        .iter()
        .flat_map(|(_, n)| n.iter().copied())
        .collect::<Vec<_>>()
        .join("|");
    regex(&format!(
        r"^(?:(?:by|before|until|till|on|due|do|u) )?(?:the )?(this |next |sledeci |sledeći )?({names})(?: (?:morning|afternoon|evening|eod|end of day))?$"
    ))
});
static QUARTER: LazyLock<Regex> = LazyLock::new(|| {
    regex(&format!(
        r"{LEADING}(?:end of )?(?:q([1-4])|(first|second|third|fourth) quarter)(?: (\d{{4}}))?$"
    ))
});
static MONTH_FIRST: LazyLock<Regex> = LazyLock::new(|| {
    let months = month_alternation();
    regex(&format!(
        r"{LEADING}({months})\.? (\d{{1,2}})(?:st|nd|rd|th|\.)?(?:,? (\d{{4}}))?$"
    ))
});
static DAY_FIRST: LazyLock<Regex> = LazyLock::new(|| {
    let months = month_alternation();
    regex(&format!(
        r"{LEADING}(\d{{1,2}})(?:st|nd|rd|th|\.)? (?:of )?({months})\.?(?:,? (\d{{4}}))?$"
    ))
});
static PUNCTUATION: LazyLock<Regex> = LazyLock::new(|| regex(r"[!?;]+"));
static SPACES: LazyLock<Regex> = LazyLock::new(|| regex(r"\s+"));

fn month_alternation() -> String {
    MONTH_NAMES
        .iter()
        .flat_map(|(_, n)| n.iter().copied())
        .collect::<Vec<_>>()
        .join("|")
}

/// Resolves `phrase` said at `spoken_at` (interpreted in the local time zone).
pub fn resolve_at(phrase: Option<&str>, spoken_at: DateTime<Utc>) -> Option<NaiveDate> {
    resolve(phrase, crate::time::local_day(spoken_at))
}

/// Resolves `phrase` said on the local day `spoken_on`.
pub fn resolve(phrase: Option<&str>, spoken_on: NaiveDate) -> Option<NaiveDate> {
    let text = normalized(phrase?);
    if text.is_empty() || text.chars().count() > 80 {
        return None;
    }
    if let Some(iso) = iso_date(&text) {
        return Some(iso);
    }
    let day = spoken_on;
    if TODAY.is_match(&text) || LATER_TODAY.is_match(&text) {
        return Some(day);
    }
    if TOMORROW.is_match(&text) {
        return day.checked_add_days(Days::new(1));
    }
    if THIS_WEEK.is_match(&text) {
        return Some(end_of_work_week(day));
    }
    if NEXT_WEEK.is_match(&text) {
        return day.checked_add_days(Days::new(7)).map(end_of_work_week);
    }
    if THIS_MONTH.is_match(&text) {
        return last_day_of_month(day);
    }
    if NEXT_MONTH.is_match(&text) {
        return day
            .checked_add_months(Months::new(1))
            .and_then(last_day_of_month);
    }
    relative_offset(&text, day)
        .or_else(|| weekday(&text, day))
        .or_else(|| quarter(&text, day))
        .or_else(|| month_day(&text, day))
}

/// "Due Fri, Oct 2 · said “Friday”", or the phrase with the day it was said.
pub fn label(phrase: &str, spoken_at: DateTime<Utc>) -> String {
    let spoken_day = crate::time::local_day(spoken_at);
    let Some(date) = resolve(Some(phrase), spoken_day) else {
        return format!("{phrase} — said on {}", spoken_day.format("%b %-d, %Y"));
    };
    let resolved = date.format("%a, %b %-d");
    let trimmed = phrase.trim();
    let explicit = trimmed.len() == 10 && NaiveDate::parse_from_str(trimmed, "%Y-%m-%d").is_ok();
    if explicit {
        format!("Due {resolved}")
    } else {
        format!("Due {resolved} · said “{trimmed}”")
    }
}

fn normalized(phrase: &str) -> String {
    let lowered = phrase.to_lowercase().replace('’', "'");
    let spaced = PUNCTUATION.replace_all(&lowered, " ");
    let collapsed = SPACES.replace_all(&spaced, " ");
    collapsed
        .trim_matches(|c: char| c.is_whitespace() || c == '.' || c == ',')
        .to_string()
}

/// Returns every capture group, with unmatched optional groups as "".
fn captures(regex: &Regex, text: &str) -> Option<Vec<String>> {
    let caps = regex.captures(text)?;
    Some(
        (1..caps.len())
            .map(|i| {
                caps.get(i)
                    .map(|m| m.as_str().to_string())
                    .unwrap_or_default()
            })
            .collect(),
    )
}

fn iso_date(text: &str) -> Option<NaiveDate> {
    let groups = captures(&ISO_DATE, text)?;
    NaiveDate::from_ymd_opt(
        groups[0].parse().ok()?,
        groups[1].parse().ok()?,
        groups[2].parse().ok()?,
    )
}

/// Sunday = 1 … Saturday = 7, as in Foundation's Gregorian calendar.
fn weekday_number(day: NaiveDate) -> u32 {
    day.weekday().number_from_sunday()
}

fn weekday(text: &str, day: NaiveDate) -> Option<NaiveDate> {
    let groups = captures(&WEEKDAY, text)?;
    let target = WEEKDAY_NAMES
        .iter()
        .find(|(_, names)| names.contains(&groups[1].as_str()))?
        .0;
    let current = weekday_number(day);
    let modifier = groups[0].trim();
    let mut offset = (target + 7 - current) % 7;
    // "This Friday" said on a Friday is that day; a bare or "next" weekday
    // said on the same weekday means the following week.
    if offset == 0 && modifier != "this" {
        offset = 7;
    }
    let mut date = day.checked_add_days(Days::new(u64::from(offset)))?;
    if matches!(modifier, "next" | "sledeci" | "sledeći") && date.iso_week() == day.iso_week() {
        // "Next Friday" said on a Tuesday means Friday of the following week.
        date = date.checked_add_days(Days::new(7))?;
    }
    Some(date)
}

fn relative_offset(text: &str, day: NaiveDate) -> Option<NaiveDate> {
    let groups = captures(&RELATIVE, text)?;
    let amount: u32 = groups[0].parse().ok().or_else(|| {
        NUMBER_WORDS
            .iter()
            .find(|(w, _)| *w == groups[0])
            .map(|(_, n)| *n)
    })?;
    if amount == 0 {
        return None;
    }
    match groups[1].as_str() {
        "day" => day.checked_add_days(Days::new(u64::from(amount))),
        "business day" | "working day" => {
            let mut date = day;
            let mut remaining = amount;
            while remaining > 0 {
                date = date.checked_add_days(Days::new(1))?;
                if !matches!(date.weekday(), Weekday::Sat | Weekday::Sun) {
                    remaining -= 1;
                }
            }
            Some(date)
        }
        "week" => day.checked_add_days(Days::new(u64::from(amount) * 7)),
        "month" => day.checked_add_months(Months::new(amount)),
        _ => None,
    }
}

fn quarter(text: &str, day: NaiveDate) -> Option<NaiveDate> {
    let groups = captures(&QUARTER, text)?;
    let number: u32 = groups[0].parse().ok().or(match groups[1].as_str() {
        "first" => Some(1),
        "second" => Some(2),
        "third" => Some(3),
        "fourth" => Some(4),
        _ => None,
    })?;
    let end = |year: i32| NaiveDate::from_ymd_opt(year, number * 3, 1).and_then(last_day_of_month);
    let mut year: i32 = groups[2].parse().unwrap_or(day.year());
    let mut date = end(year)?;
    if groups[2].is_empty() && date < day {
        year += 1;
        date = end(year).unwrap_or(date);
    }
    Some(date)
}

fn month_day(text: &str, day: NaiveDate) -> Option<NaiveDate> {
    let month_number = |name: &str| {
        MONTH_NAMES
            .iter()
            .find(|(_, names)| names.contains(&name))
            .map(|(n, _)| *n)
    };
    let (month, day_of_month, explicit_year) = if let Some(groups) = captures(&MONTH_FIRST, text) {
        (
            month_number(&groups[0]),
            groups[1].parse::<u32>().ok(),
            groups[2].parse::<i32>().ok(),
        )
    } else {
        let groups = captures(&DAY_FIRST, text)?;
        (
            month_number(&groups[1]),
            groups[0].parse::<u32>().ok(),
            groups[2].parse::<i32>().ok(),
        )
    };
    let (month, day_of_month) = (month?, day_of_month?);
    if !(1..=31).contains(&day_of_month) {
        return None;
    }
    let mut year = explicit_year.unwrap_or(day.year());
    let mut date = NaiveDate::from_ymd_opt(year, month, day_of_month)?;
    // Without a year, a date well before the meeting refers to next year.
    if explicit_year.is_none()
        && day
            .checked_sub_days(Days::new(31))
            .is_some_and(|cutoff| date < cutoff)
    {
        year += 1;
        date = NaiveDate::from_ymd_opt(year, month, day_of_month).unwrap_or(date);
    }
    Some(date)
}

/// Friday of the week containing `day`; a Saturday keeps the stated day.
fn end_of_work_week(day: NaiveDate) -> NaiveDate {
    let offset = 6 - weekday_number(day) as i64;
    if offset >= 0 {
        day + chrono::Duration::days(offset)
    } else {
        day
    }
}

fn last_day_of_month(day: NaiveDate) -> Option<NaiveDate> {
    let first = NaiveDate::from_ymd_opt(day.year(), day.month(), 1)?;
    first.checked_add_months(Months::new(1))?.pred_opt()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tuesday, 22 September 2026, as in `ActionDueResolverTests.swift`.
    fn tuesday() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 9, 22).unwrap()
    }

    fn resolved(phrase: &str) -> Option<String> {
        resolved_from(phrase, tuesday())
    }

    fn resolved_from(phrase: &str, day: NaiveDate) -> Option<String> {
        resolve(Some(phrase), day).map(|d| d.format("%Y-%m-%d").to_string())
    }

    #[test]
    fn explicit_iso_dates_resolve_exactly() {
        assert_eq!(resolved("2026-10-01").as_deref(), Some("2026-10-01"));
        assert_eq!(resolved("by 2026-10-01").as_deref(), Some("2026-10-01"));
        assert_eq!(resolved("2026-02-30"), None);
    }

    #[test]
    fn day_relative_phrases() {
        assert_eq!(resolved("today").as_deref(), Some("2026-09-22"));
        assert_eq!(resolved("by end of day").as_deref(), Some("2026-09-22"));
        assert_eq!(resolved("EOD").as_deref(), Some("2026-09-22"));
        assert_eq!(resolved("Tomorrow").as_deref(), Some("2026-09-23"));
        assert_eq!(
            resolved("by tomorrow morning").as_deref(),
            Some("2026-09-23")
        );
        assert_eq!(resolved("sutra").as_deref(), Some("2026-09-23"));
    }

    #[test]
    fn later_the_same_day_phrases() {
        for phrase in [
            "during the day",
            "During the day.",
            "later today",
            "this afternoon",
            "tokom dana",
            "u toku dana",
        ] {
            assert_eq!(resolved(phrase).as_deref(), Some("2026-09-22"), "{phrase}");
        }
        assert_eq!(resolved("during the week of the audit"), None);
    }

    #[test]
    fn weekdays_resolve_to_the_next_occurrence() {
        assert_eq!(resolved("Friday").as_deref(), Some("2026-09-25"));
        assert_eq!(resolved("by Friday.").as_deref(), Some("2026-09-25"));
        assert_eq!(resolved("on Monday").as_deref(), Some("2026-09-28"));
        assert_eq!(resolved("Tuesday").as_deref(), Some("2026-09-29"));
        assert_eq!(resolved("do petka").as_deref(), Some("2026-09-25"));
        assert_eq!(resolved("tues").as_deref(), Some("2026-09-29"));
    }

    #[test]
    fn this_weekday_said_on_that_weekday_means_today() {
        let friday = tuesday() + chrono::Duration::days(3);
        assert_eq!(
            resolved_from("this Friday", friday).as_deref(),
            Some("2026-09-25")
        );
        assert_eq!(
            resolved_from("by this Friday", friday).as_deref(),
            Some("2026-09-25")
        );
        assert_eq!(
            resolved_from("Friday", friday).as_deref(),
            Some("2026-10-02")
        );
        assert_eq!(resolved("this Friday").as_deref(), Some("2026-09-25"));
    }

    #[test]
    fn next_weekday_means_the_following_week() {
        assert_eq!(resolved("next Friday").as_deref(), Some("2026-10-02"));
        let saturday = tuesday() + chrono::Duration::days(4);
        assert_eq!(
            resolved_from("next Monday", saturday).as_deref(),
            Some("2026-09-28")
        );
    }

    #[test]
    fn ranges_resolve_to_their_last_working_day() {
        assert_eq!(resolved("end of the week").as_deref(), Some("2026-09-25"));
        assert_eq!(resolved("EOW").as_deref(), Some("2026-09-25"));
        assert_eq!(resolved("this week").as_deref(), Some("2026-09-25"));
        assert_eq!(resolved("next week").as_deref(), Some("2026-10-02"));
        assert_eq!(resolved("by end of month").as_deref(), Some("2026-09-30"));
        assert_eq!(resolved("next month").as_deref(), Some("2026-10-31"));
        assert_eq!(resolved("end of Q3").as_deref(), Some("2026-09-30"));
        assert_eq!(resolved("Q4").as_deref(), Some("2026-12-31"));
        assert_eq!(resolved("Q1").as_deref(), Some("2027-03-31"));
        assert_eq!(resolved("Q1 2026").as_deref(), Some("2026-03-31"));
        assert_eq!(resolved("do kraja nedelje").as_deref(), Some("2026-09-25"));
    }

    #[test]
    fn relative_offsets() {
        assert_eq!(resolved("in 3 days").as_deref(), Some("2026-09-25"));
        assert_eq!(resolved("in two weeks").as_deref(), Some("2026-10-06"));
        assert_eq!(resolved("within a week").as_deref(), Some("2026-09-29"));
        assert_eq!(
            resolved("in 5 business days").as_deref(),
            Some("2026-09-29")
        );
        assert_eq!(resolved("in a couple of days").as_deref(), None);
        assert_eq!(resolved("in couple of days").as_deref(), Some("2026-09-24"));
    }

    #[test]
    fn month_and_day_phrases() {
        assert_eq!(resolved("Oct 5").as_deref(), Some("2026-10-05"));
        assert_eq!(resolved("by October 5th").as_deref(), Some("2026-10-05"));
        assert_eq!(resolved("5 October").as_deref(), Some("2026-10-05"));
        assert_eq!(
            resolved("the 5th of October").as_deref(),
            Some("2026-10-05")
        );
        assert_eq!(resolved("Sep 20").as_deref(), Some("2026-09-20"));
        assert_eq!(resolved("January 10").as_deref(), Some("2027-01-10"));
        assert_eq!(resolved("January 10, 2026").as_deref(), Some("2026-01-10"));
        assert_eq!(resolved("February 30"), None);
    }

    #[test]
    fn unsupported_phrases_stay_unresolved() {
        for phrase in [
            "once the budget lands",
            "soon",
            "before the next release",
            "",
        ] {
            assert_eq!(resolved(phrase), None, "{phrase}");
        }
        assert_eq!(resolve(None, tuesday()), None);
        assert_eq!(resolved(&"x".repeat(81)), None);
    }

    #[test]
    fn labels_keep_the_original_phrase() {
        let at = chrono::TimeZone::with_ymd_and_hms(&Utc, 2026, 9, 22, 10, 30, 0).unwrap();
        let label = label("Friday", at);
        assert!(label.starts_with("Due "), "{label}");
        assert!(label.contains("said “Friday”"), "{label}");
        assert!(!super::label("2026-10-01", at).contains("said"));
        assert!(super::label("when ready", at).contains("said on"));
    }
}
