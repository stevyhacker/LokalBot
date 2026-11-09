// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! Inline `/macro` autocomplete (`CotypingMacro`).
//!
//! A `/` opens a query only at a word boundary (the field's start or after
//! whitespace), so `http://`, `and/or` and file paths never fire, and the
//! ghost shows only when the query computes to a result: `/5+5` → `= 10`,
//! `/10km->mi` → `6.214 mi`, `/today` → `Jun 23, 2026`, `/100usd to eur` →
//! `€92.00`, `/d20` → a roll, `/uuid` → a UUID.
//!
//! macOS formats dates and money with the user's locale through Foundation;
//! here they read as they do in en-US. `iso` and `24h` dates need no locale.

use chrono::{Datelike as _, Days, Duration, Local, Months, NaiveDateTime, Timelike as _};
use unicode_segmentation::UnicodeSegmentation as _;

use super::text::is_newline;

/// What to preview under the caret and what an accept inserts. They differ
/// for arithmetic (`= 10`, then `10`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MacroResult {
    pub preview: String,
    pub insertion: String,
}

impl MacroResult {
    fn same(value: String) -> Self {
        Self {
            preview: value.clone(),
            insertion: value,
        }
    }
}

/// A match at the caret.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MacroMatch {
    pub result: MacroResult,
    /// User-perceived characters of the typed `/query`.
    pub token_length: usize,
    pub query: String,
}

/// The best macro for the trailing `/query`, with the live clock and random
/// source.
pub fn match_trailing(before: &str) -> Option<MacroMatch> {
    match_with(before, &mut Engine::standard())
}

pub fn match_with(before: &str, engine: &mut Engine) -> Option<MacroMatch> {
    let token = scan_token(before)?;
    let result = engine.evaluate(&token.query)?;
    Some(MacroMatch {
        result,
        token_length: token.token_length,
        query: token.query,
    })
}

/// The raw query after a boundary `/` at the caret.
pub fn trailing_query(before: &str) -> Option<String> {
    scan_token(before).map(|token| token.query)
}

/// Length of the trailing `/query`, whether or not it evaluates.
pub fn trailing_token_length(before: &str) -> Option<usize> {
    scan_token(before).map(|token| token.token_length)
}

struct Token {
    query: String,
    token_length: usize,
}

const SIGIL: &str = "/";
const MAX_QUERY_LENGTH: usize = 48;

fn is_space_grapheme(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(char::is_whitespace)
}

/// Walks back from the caret until a boundary `/`. An inner `/` preceded by
/// a non-space (`5/2`) stays in the query; a newline or an over-long run ends
/// the search.
fn scan_token(text: &str) -> Option<Token> {
    let mut graphemes = text.graphemes(true).rev().peekable();
    let mut collected: Vec<&str> = Vec::new();
    while let Some(grapheme) = graphemes.next() {
        if grapheme.chars().next().is_some_and(is_newline) {
            return None;
        }
        if grapheme == SIGIL
            && graphemes
                .peek()
                .is_none_or(|prior| is_space_grapheme(prior))
        {
            if collected.is_empty() {
                return None;
            }
            let count = collected.len();
            collected.reverse();
            return Some(Token {
                query: collected.concat(),
                token_length: count + 1,
            });
        }
        collected.push(grapheme);
        if collected.len() > MAX_QUERY_LENGTH {
            return None;
        }
    }
    None
}

/// The clock and random source are injected so tests are deterministic.
pub struct Engine<'a> {
    pub now: NaiveDateTime,
    /// A whole number from the first bound to the second, inclusive.
    pub random: Box<dyn FnMut(i64, i64) -> i64 + 'a>,
    pub uuid: Box<dyn FnMut() -> String + 'a>,
}

impl Engine<'static> {
    pub fn standard() -> Self {
        Self {
            now: Local::now().naive_local(),
            random: Box::new(|low, high| {
                let span = (high - low) as u128 + 1;
                low + (uuid::Uuid::new_v4().as_u128() % span) as i64
            }),
            // Swift's `UUID().uuidString` is uppercase.
            uuid: Box::new(|| uuid::Uuid::new_v4().to_string().to_uppercase()),
        }
    }
}

impl Engine<'_> {
    /// Date, random, unit, currency, then arithmetic as the catch-all.
    pub fn evaluate(&mut self, raw_query: &str) -> Option<MacroResult> {
        let query = trim_spaces(raw_query);
        if query.is_empty() {
            return None;
        }
        self.evaluate_date(query)
            .or_else(|| self.evaluate_random(query))
            .or_else(|| evaluate_unit(query))
            .or_else(|| evaluate_currency(query))
            .or_else(|| evaluate_arithmetic(query))
    }

    // ------------------------------------------------------------- dates

    fn evaluate_date(&self, query: &str) -> Option<MacroResult> {
        let lower = query.to_lowercase();
        let (raw_base, argument) = split_argument(&lower);
        let base = canonical_base(raw_base);
        let style = date_style(argument);
        let time_24 = argument == Some("24h");
        if let Some(relative) = self.relative_date(&base) {
            return Some(MacroResult::same(format_date(relative, style)));
        }
        let now = self.now;
        let result = match base.as_str() {
            "today" | "date" => format_date(now, style),
            "tomorrow" => format_date(now.checked_add_days(Days::new(1))?, style),
            "yesterday" => format_date(now.checked_sub_days(Days::new(1))?, style),
            "now" | "time" => format_time(now, time_24),
            "datetime" => format!("{} at {}", medium_date(now), format_time(now, false)),
            "noon" => format_time(now.date().and_hms_opt(12, 0, 0)?, time_24),
            "midnight" => format_time(now.date().and_hms_opt(0, 0, 0)?, time_24),
            _ => format_date(self.weekday_date(&base)?, style),
        };
        Some(MacroResult::same(result))
    }

    /// `+3d`, `-5d`, `+2w`, `+1mo`, `+1y`.
    fn relative_date(&self, base: &str) -> Option<NaiveDateTime> {
        let mut chars = base.chars();
        let sign = chars.next()?;
        if sign != '+' && sign != '-' {
            return None;
        }
        let rest = chars.as_str();
        let digits_end = rest.find(|c: char| !c.is_numeric()).unwrap_or(rest.len());
        let magnitude: i64 = rest[..digits_end].parse().ok()?;
        let unit = &rest[digits_end..];
        let value = if sign == '-' { -magnitude } else { magnitude };
        let now = self.now;
        match unit {
            "d" | "day" | "days" => now.checked_add_signed(Duration::try_days(value)?),
            "w" | "wk" | "wks" | "week" | "weeks" => {
                now.checked_add_signed(Duration::try_weeks(value)?)
            }
            "mo" | "month" | "months" => add_months(now, value),
            "y" | "yr" | "yrs" | "year" | "years" => add_months(now, value.checked_mul(12)?),
            _ => None,
        }
    }

    /// `next-<weekday>` (strictly after today), `this-<weekday>` (including
    /// today), `last-<weekday>` (strictly before today).
    fn weekday_date(&self, base: &str) -> Option<NaiveDateTime> {
        let (which, day) = base.split_once('-')?;
        let target = weekday_number(day)?;
        let today = i64::from(self.now.weekday().num_days_from_sunday()) + 1;
        let forward = (target - today + 7) % 7;
        let delta = match which {
            "this" => forward,
            "next" if forward == 0 => 7,
            "next" => forward,
            "last" if forward == 0 => -7,
            "last" => forward - 7,
            _ => return None,
        };
        self.now.checked_add_signed(Duration::try_days(delta)?)
    }

    // ------------------------------------------------------------ random

    fn evaluate_random(&mut self, query: &str) -> Option<MacroResult> {
        let lower = query.to_lowercase();
        let value = match lower.as_str() {
            "uuid" | "guid" => (self.uuid)(),
            "dice" | "die" | "roll" => (self.random)(1, 6).to_string(),
            "coin" | "flip" | "coinflip" | "coin-flip" => {
                if (self.random)(0, 1) == 0 {
                    "Heads".to_string()
                } else {
                    "Tails".to_string()
                }
            }
            "random" | "rand" | "rnd" => (self.random)(0, 100).to_string(),
            _ => {
                if let Some(sides) = dice_sides(&lower) {
                    (self.random)(1, sides).to_string()
                } else {
                    return self.parameterized_random(&lower);
                }
            }
        };
        Some(MacroResult::same(value))
    }

    fn parameterized_random(&mut self, lower: &str) -> Option<MacroResult> {
        let inner = ["random(", "rand(", "rnd("]
            .iter()
            .find_map(|prefix| lower.strip_prefix(prefix))?
            .strip_suffix(')')?;
        let parts: Vec<&str> = inner
            .split(',')
            .filter(|part| !part.is_empty())
            .map(trim_spaces)
            .collect();
        let values: Vec<i64> = parts.iter().filter_map(|part| part.parse().ok()).collect();
        if values.len() != parts.len() || values.is_empty() {
            return None;
        }
        let value = match values[..] {
            [high] if high >= 1 => (self.random)(1, high),
            [a, b] => (self.random)(a.min(b), a.max(b)),
            _ => return None,
        };
        Some(MacroResult::same(value.to_string()))
    }
}

fn add_months(now: NaiveDateTime, months: i64) -> Option<NaiveDateTime> {
    let count = u32::try_from(months.unsigned_abs()).ok()?;
    if months < 0 {
        now.checked_sub_months(Months::new(count))
    } else {
        now.checked_add_months(Months::new(count))
    }
}

fn weekday_number(name: &str) -> Option<i64> {
    Some(match name {
        "sun" | "sunday" => 1,
        "mon" | "monday" => 2,
        "tue" | "tues" | "tuesday" => 3,
        "wed" | "weds" | "wednesday" => 4,
        "thu" | "thur" | "thurs" | "thursday" => 5,
        "fri" | "friday" => 6,
        "sat" | "saturday" => 7,
        _ => return None,
    })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum DateStyle {
    Iso,
    Short,
    Medium,
    Long,
}

fn date_style(argument: Option<&str>) -> DateStyle {
    match argument {
        Some("iso") => DateStyle::Iso,
        Some("long") => DateStyle::Long,
        Some("short") => DateStyle::Short,
        _ => DateStyle::Medium,
    }
}

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

fn medium_date(date: NaiveDateTime) -> String {
    format!(
        "{} {}, {}",
        &MONTHS[date.month0() as usize][..3],
        date.day(),
        date.year()
    )
}

fn format_date(date: NaiveDateTime, style: DateStyle) -> String {
    match style {
        DateStyle::Iso => format!("{:04}-{:02}-{:02}", date.year(), date.month(), date.day()),
        DateStyle::Short => format!(
            "{}/{}/{:02}",
            date.month(),
            date.day(),
            date.year().rem_euclid(100)
        ),
        DateStyle::Medium => medium_date(date),
        DateStyle::Long => format!(
            "{} {}, {}",
            MONTHS[date.month0() as usize],
            date.day(),
            date.year()
        ),
    }
}

fn format_time(date: NaiveDateTime, use_24_hour: bool) -> String {
    if use_24_hour {
        return format!("{:02}:{:02}", date.hour(), date.minute());
    }
    let (afternoon, hour) = date.hour12();
    format!(
        "{hour}:{:02} {}",
        date.minute(),
        if afternoon { "PM" } else { "AM" }
    )
}

fn split_argument(text: &str) -> (&str, Option<&str>) {
    let (Some(open), Some(inner_end)) = (text.find('('), text.strip_suffix(')')) else {
        return (text, None);
    };
    let argument = &inner_end[open + 1..];
    (&text[..open], (!argument.is_empty()).then_some(argument))
}

/// Short forms and misspellings of the keywords, then a `next`/`this`/`last`
/// weekday written with a space or no separator as `next-fri`.
fn canonical_base(base: &str) -> String {
    let alias = match base {
        "tdy" | "tod" | "tody" | "2day" => "today",
        "tmr" | "tmrw" | "tmw" | "tom" | "tomo" | "tomorow" | "2moro" | "2mrw" => "tomorrow",
        "yest" | "yday" | "ystdy" | "yesty" | "yesterdy" => "yesterday",
        "rn" | "rightnow" | "atm" => "now",
        "midday" | "noontime" => "noon",
        "midnite" => "midnight",
        "dt" => "datetime",
        _ => "",
    };
    if !alias.is_empty() {
        return alias.to_string();
    }
    for prefix in ["next", "this", "last"] {
        if let Some(rest) = base.strip_prefix(prefix)
            && !rest.is_empty()
        {
            let rest = rest.trim_start_matches([' ', '-', '_']);
            if !rest.is_empty() {
                return format!("{prefix}-{rest}");
            }
        }
    }
    base.to_string()
}

fn dice_sides(lower: &str) -> Option<i64> {
    lower
        .strip_prefix('d')?
        .parse::<i64>()
        .ok()
        .filter(|sides| *sides >= 1)
}

fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|c: char| c.is_whitespace() && !is_newline(c))
}

fn is_number_part(c: char) -> bool {
    c.is_numeric() || c == '.' || c == '-' || c == '+'
}

fn number_prefix(text: &str) -> (&str, &str) {
    let end = text.find(|c| !is_number_part(c)).unwrap_or(text.len());
    text.split_at(end)
}

// --------------------------------------------------------------- conversions

/// `<value><from> <sep> <to>`, on `->`, `→` or ` to `. Shared by the unit and
/// currency families.
fn split_conversion(query: &str) -> Option<(&str, &str)> {
    for token in ["->", "→"] {
        if let Some(found) = query.split_once(token) {
            return Some(found);
        }
    }
    // Case-insensitive " to ": ASCII, so byte offsets hold.
    let at = query
        .as_bytes()
        .windows(4)
        .position(|window| window.eq_ignore_ascii_case(b" to "))?;
    Some((&query[..at], &query[at + 4..]))
}

#[derive(Clone, Copy)]
enum Quantity {
    Length(f64),
    Mass(f64),
    Volume(f64),
    /// Coefficient and constant to kelvin.
    Temperature(f64, f64),
}

const FAHRENHEIT: Quantity = Quantity::Temperature(0.55555555555556, 255.37222222222427);

/// Foundation's `Dimension` coefficients, so conversions print as on macOS.
fn unit(token: &str) -> Option<Quantity> {
    use Quantity::*;
    Some(match token {
        "mm" | "millimeter" | "millimeters" => Length(1e-3),
        "cm" | "centimeter" | "centimeters" => Length(1e-2),
        "m" | "meter" | "meters" | "metre" | "metres" => Length(1.0),
        "km" | "kilometer" | "kilometers" => Length(1e3),
        "in" | "inch" | "inches" => Length(0.0254),
        "ft" | "foot" | "feet" => Length(0.3048),
        "yd" | "yard" | "yards" => Length(0.9144),
        "mi" | "mile" | "miles" => Length(1609.34),
        "mg" | "milligram" | "milligrams" => Mass(1e-6),
        "g" | "gram" | "grams" => Mass(1e-3),
        "kg" | "kgs" | "kilo" | "kilos" | "kilogram" | "kilograms" => Mass(1.0),
        "oz" | "ounce" | "ounces" => Mass(0.0283495),
        "lb" | "lbs" | "pound" | "pounds" => Mass(0.453592),
        // Foundation's table has 0.157473 here, which is stones per kilogram;
        // a stone is 6.35029 kg.
        "st" | "stone" | "stones" => Mass(6.35029),
        "c" | "celsius" | "centigrade" => Temperature(1.0, 273.15),
        "f" | "fahrenheit" => FAHRENHEIT,
        "k" | "kelvin" => Temperature(1.0, 0.0),
        "ml" | "milliliter" | "milliliters" => Volume(1e-3),
        "l" | "liter" | "liters" | "litre" | "litres" => Volume(1.0),
        "cup" | "cups" => Volume(0.24),
        "tbsp" | "tablespoon" | "tablespoons" => Volume(0.0147868),
        "tsp" | "teaspoon" | "teaspoons" => Volume(0.00492892),
        "floz" => Volume(0.0295735),
        "gal" | "gallon" | "gallons" => Volume(3.78541),
        "pt" | "pint" | "pints" => Volume(0.473176),
        "qt" | "quart" | "quarts" => Volume(0.946353),
        _ => return None,
    })
}

fn convert(value: f64, from: Quantity, to: Quantity) -> Option<f64> {
    use Quantity::*;
    match (from, to) {
        (Length(a), Length(b)) | (Mass(a), Mass(b)) | (Volume(a), Volume(b)) => Some(value * a / b),
        (Temperature(a, c), Temperature(b, d)) => Some(((value * a + c) - d) / b),
        _ => None,
    }
}

fn evaluate_unit(query: &str) -> Option<MacroResult> {
    let (lhs, rhs) = split_conversion(query)?;
    let lhs = trim_spaces(lhs);
    let to_token = trim_spaces(rhs).to_lowercase();
    let (number, rest) = number_prefix(lhs);
    let from_token = trim_spaces(rest).to_lowercase();
    let value: f64 = number.parse().ok()?;
    if from_token.is_empty() || to_token.is_empty() {
        return None;
    }
    let converted = convert(value, unit(&from_token)?, unit(&to_token)?)?;
    Some(MacroResult::same(format!(
        "{} {to_token}",
        unit_format(converted)
    )))
}

fn unit_format(value: f64) -> String {
    // Foundation's rounded temperature constants leave `32f to c` a hair off
    // zero; a whole number should print as one.
    let whole = value.round();
    if (value - whole).abs() < 1e-9 && value.abs() < 1e12 {
        return (whole as i64).to_string();
    }
    format_g(value, 4)
}

/// C's `%.<precision>g`: significant digits, trailing zeros removed, and an
/// exponent below 1e-4 or from 1e<precision> up. Rust has no `%g`.
pub fn format_g(value: f64, precision: usize) -> String {
    if !value.is_finite() {
        return if value.is_nan() {
            "nan".to_string()
        } else if value < 0.0 {
            "-inf".to_string()
        } else {
            "inf".to_string()
        };
    }
    if value == 0.0 {
        return "0".to_string();
    }
    let precision = precision.max(1);
    let scientific = format!("{:.*e}", precision - 1, value);
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let strip = |text: &str| -> String {
        if text.contains('.') {
            text.trim_end_matches('0').trim_end_matches('.').to_string()
        } else {
            text.to_string()
        }
    };
    if exponent < -4 || exponent >= precision as i32 {
        let sign = if exponent < 0 { '-' } else { '+' };
        return format!("{}e{sign}{:02}", strip(mantissa), exponent.abs());
    }
    let decimals = (precision as i32 - 1 - exponent).max(0) as usize;
    strip(&format!("{value:.decimals$}"))
}

// ------------------------------------------------------------------ currency

/// Bundled, offline, approximate rates, units per US dollar. Never reaches
/// the network. As of 2026-06.
const RATES_PER_USD: [(&str, f64); 32] = [
    ("USD", 1.0),
    ("EUR", 0.92),
    ("GBP", 0.79),
    ("JPY", 151.0),
    ("CAD", 1.36),
    ("AUD", 1.51),
    ("CHF", 0.90),
    ("CNY", 7.24),
    ("INR", 83.4),
    ("MXN", 17.1),
    ("BRL", 5.05),
    ("ZAR", 18.6),
    ("KRW", 1360.0),
    ("SGD", 1.35),
    ("HKD", 7.82),
    ("NZD", 1.63),
    ("SEK", 10.5),
    ("NOK", 10.7),
    ("DKK", 6.87),
    ("PLN", 3.95),
    ("TRY", 32.1),
    ("RUB", 90.0),
    ("AED", 3.67),
    ("SAR", 3.75),
    ("THB", 36.5),
    ("IDR", 15800.0),
    ("MYR", 4.70),
    ("PHP", 56.5),
    ("CZK", 23.2),
    ("HUF", 360.0),
    ("ILS", 3.70),
    ("TWD", 32.3),
];

fn rate(code: &str) -> Option<f64> {
    RATES_PER_USD
        .iter()
        .find(|(known, _)| *known == code)
        .map(|(_, rate)| *rate)
}

fn currency_alias(token: &str) -> Option<&'static str> {
    Some(match token {
        "us" | "usa" | "dollar" | "dollars" | "buck" | "bucks" | "$" => "USD",
        "euro" | "euros" | "€" => "EUR",
        "pound" | "pounds" | "quid" | "sterling" | "£" => "GBP",
        "yen" | "¥" => "JPY",
        "yuan" | "rmb" | "renminbi" => "CNY",
        "rupee" | "rupees" | "₹" => "INR",
        "peso" | "pesos" => "MXN",
        "real" | "reais" | "r$" => "BRL",
        "rand" => "ZAR",
        "won" | "₩" => "KRW",
        "ruble" | "rubles" | "rouble" | "₽" => "RUB",
        "baht" | "฿" => "THB",
        "shekel" | "shekels" | "₪" => "ILS",
        "forint" => "HUF",
        "zloty" | "zł" => "PLN",
        "ringgit" => "MYR",
        "rupiah" => "IDR",
        "dirham" | "dirhams" => "AED",
        "riyal" | "rial" => "SAR",
        "franc" | "francs" => "CHF",
        "₱" => "PHP",
        "c$" => "CAD",
        "a$" => "AUD",
        "hk$" => "HKD",
        "nz$" => "NZD",
        "nt$" => "TWD",
        "s$" => "SGD",
        _ => return None,
    })
}

fn resolve_code(token: &str) -> Option<String> {
    if let Some(code) = currency_alias(&token.to_lowercase()) {
        return Some(code.to_string());
    }
    let upper = token.to_uppercase();
    (upper.chars().count() == 3).then_some(upper)
}

fn parse_amount(lhs: &str) -> Option<(f64, String)> {
    let trimmed = trim_spaces(lhs);
    let first = trimmed.chars().next()?;
    if currency_alias(first.encode_utf8(&mut [0; 4])).is_some() {
        let amount = trim_spaces(&trimmed[first.len_utf8()..]).parse().ok()?;
        return Some((amount, first.to_string()));
    }
    let (number, rest) = number_prefix(trimmed);
    Some((number.parse().ok()?, trim_spaces(rest).to_string()))
}

fn evaluate_currency(query: &str) -> Option<MacroResult> {
    let (lhs, rhs) = split_conversion(query)?;
    let (amount, from_token) = parse_amount(lhs)?;
    let from = resolve_code(&from_token)?;
    let to = resolve_code(trim_spaces(rhs))?;
    let converted = amount / rate(&from)? * rate(&to)?;
    Some(MacroResult::same(format_currency(converted, &to)))
}

/// `NumberFormatter`'s `.currency` style in en-US: its symbols, its grouping,
/// and no decimals for yen and won.
fn format_currency(value: f64, code: &str) -> String {
    let symbol = match code {
        "USD" => "$",
        "EUR" => "€",
        "GBP" => "£",
        "JPY" => "¥",
        "CAD" => "CA$",
        "AUD" => "A$",
        "CNY" => "CN¥",
        "INR" => "₹",
        "MXN" => "MX$",
        "BRL" => "R$",
        "KRW" => "₩",
        "HKD" => "HK$",
        "NZD" => "NZ$",
        "PHP" => "₱",
        "ILS" => "₪",
        "TWD" => "NT$",
        other => return format!("{other}\u{a0}{}", grouped(value, 2)),
    };
    let decimals = if matches!(code, "JPY" | "KRW") { 0 } else { 2 };
    let digits = grouped(value.abs(), decimals);
    if value < 0.0 {
        format!("-{symbol}{digits}")
    } else {
        format!("{symbol}{digits}")
    }
}

fn grouped(value: f64, decimals: usize) -> String {
    let fixed = format!("{value:.decimals$}");
    let (sign, unsigned) = match fixed.strip_prefix('-') {
        Some(rest) => ("-", rest),
        None => ("", fixed.as_str()),
    };
    let (whole, fraction) = match unsigned.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (unsigned, None),
    };
    let mut out = String::new();
    for (index, digit) in whole.chars().enumerate() {
        if index > 0 && (whole.len() - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    match fraction {
        Some(fraction) => format!("{sign}{out}.{fraction}"),
        None => format!("{sign}{out}"),
    }
}

// ---------------------------------------------------------------- arithmetic

fn evaluate_arithmetic(query: &str) -> Option<MacroResult> {
    let literal = query.strip_suffix('=').unwrap_or(query);
    if literal.is_empty() {
        return None;
    }
    let normalized = literal.replace(['x', 'X', '×'], "*").replace('÷', "/");
    let mut parser = Arithmetic::new(&normalized);
    let value = parser.parse()?;
    if !parser.used_operator || !value.is_finite() {
        return None;
    }
    let text = format_number(value)?;
    Some(MacroResult {
        preview: format!("= {text}"),
        insertion: text,
    })
}

/// Whole numbers print without a point; others with up to 10 significant digits.
pub fn format_number(value: f64) -> Option<String> {
    if !value.is_finite() {
        return None;
    }
    if value == value.round() && value.abs() < 1e15 {
        return Some((value as i64).to_string());
    }
    Some(format_g(value, 10))
}

/// A hand-written parser: nothing in a query is ever evaluated as code.
struct Arithmetic {
    characters: Vec<char>,
    index: usize,
    used_operator: bool,
    valid: bool,
}

impl Arithmetic {
    fn new(text: &str) -> Self {
        Self {
            characters: text.chars().filter(|c| !c.is_whitespace()).collect(),
            index: 0,
            used_operator: false,
            valid: true,
        }
    }

    fn parse(&mut self) -> Option<f64> {
        let value = self.expression();
        (self.valid && self.index == self.characters.len()).then_some(value)
    }

    fn peek(&self) -> Option<char> {
        self.characters.get(self.index).copied()
    }

    fn advance(&mut self) {
        self.index += 1;
    }

    fn expression(&mut self) -> f64 {
        let mut value = self.term();
        while let Some(op @ ('+' | '-')) = self.peek() {
            self.advance();
            self.used_operator = true;
            let rhs = self.term();
            if op == '+' {
                value += rhs;
            } else {
                value -= rhs;
            }
        }
        value
    }

    fn term(&mut self) -> f64 {
        let mut value = self.power();
        while let Some(op @ ('*' | '/')) = self.peek() {
            self.advance();
            self.used_operator = true;
            let rhs = self.power();
            if op == '/' {
                if rhs == 0.0 {
                    self.valid = false;
                    return 0.0;
                }
                value /= rhs;
            } else {
                value *= rhs;
            }
        }
        value
    }

    fn power(&mut self) -> f64 {
        let base = self.unary();
        if self.peek() == Some('^') {
            self.advance();
            self.used_operator = true;
            // Right associative.
            return base.powf(self.power());
        }
        base
    }

    fn unary(&mut self) -> f64 {
        match self.peek() {
            Some('-') => {
                self.advance();
                -self.postfix()
            }
            Some('+') => {
                self.advance();
                self.postfix()
            }
            _ => self.postfix(),
        }
    }

    fn postfix(&mut self) -> f64 {
        let mut value = self.primary();
        while self.peek() == Some('%') {
            self.advance();
            self.used_operator = true;
            value /= 100.0;
        }
        value
    }

    fn primary(&mut self) -> f64 {
        if self.peek() == Some('(') {
            self.advance();
            let value = self.expression();
            if self.peek() == Some(')') {
                self.advance();
            } else {
                self.valid = false;
            }
            return value;
        }
        self.number()
    }

    fn number(&mut self) -> f64 {
        let mut digits = String::new();
        while let Some(c) = self.peek().filter(|c| c.is_numeric() || *c == '.') {
            digits.push(c);
            self.advance();
        }
        match digits.parse() {
            Ok(value) => value,
            Err(_) => {
                self.valid = false;
                0.0
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;

    /// Tuesday 23 June 2026, 15:04.
    fn engine() -> Engine<'static> {
        Engine {
            now: NaiveDate::from_ymd_opt(2026, 6, 23)
                .unwrap()
                .and_hms_opt(15, 4, 0)
                .unwrap(),
            random: Box::new(|low, _| low),
            uuid: Box::new(|| "ABCD-1234".to_string()),
        }
    }

    fn eval(query: &str) -> Option<String> {
        engine().evaluate(query).map(|r| r.preview)
    }

    #[test]
    fn a_slash_opens_a_query_only_at_a_boundary() {
        assert_eq!(trailing_query("/5+5").as_deref(), Some("5+5"));
        assert_eq!(trailing_query("sum /5/2").as_deref(), Some("5/2"));
        assert_eq!(trailing_query("http://x"), None);
        assert_eq!(trailing_query("and/or"), None);
        assert_eq!(trailing_query("/"), None);
        assert_eq!(trailing_query("a /b\nc"), None);
        assert_eq!(trailing_token_length("say /ab"), Some(3));
        assert_eq!(trailing_query(&format!("/{}", "a".repeat(49))), None);
        assert!(trailing_query(&format!("/{}", "a".repeat(48))).is_some());
    }

    #[test]
    fn a_query_that_computes_nothing_shows_nothing() {
        assert!(match_with("/hello world", &mut engine()).is_none());
        assert!(match_with("/", &mut engine()).is_none());
        // A number alone is not a calculation.
        assert!(match_with("/42", &mut engine()).is_none());
        let hit = match_with("Total /5+5", &mut engine()).unwrap();
        assert_eq!(hit.token_length, 4);
        assert_eq!(hit.query, "5+5");
        assert_eq!(
            hit.result,
            MacroResult {
                preview: "= 10".into(),
                insertion: "10".into()
            }
        );
    }

    #[test]
    fn arithmetic_follows_the_usual_precedence() {
        for (query, want) in [
            ("5+5", "= 10"),
            ("2+3*4", "= 14"),
            ("(2+3)*4", "= 20"),
            ("2^3^2", "= 512"),
            ("-2+5", "= 3"),
            ("50%", "= 0.5"),
            ("10x2", "= 20"),
            ("10×2", "= 20"),
            ("10÷4", "= 2.5"),
            ("5+5=", "= 10"),
            ("1 + 1", "= 2"),
            ("1/3", "= 0.3333333333"),
            ("1e5+1", ""),
        ] {
            assert_eq!(eval(query).as_deref().unwrap_or(""), want, "{query}");
        }
        assert_eq!(eval("1/0"), None);
        assert_eq!(eval("(1+2"), None);
    }

    #[test]
    fn numbers_print_like_printf() {
        assert_eq!(format_g(6.21371, 4), "6.214");
        assert_eq!(format_g(1234.56, 4), "1235");
        assert_eq!(format_g(0.0000123456, 4), "1.235e-05");
        assert_eq!(format_g(123456.7, 4), "1.235e+05");
        assert_eq!(format_g(2.5, 10), "2.5");
        assert_eq!(format_g(0.1, 10), "0.1");
        assert_eq!(format_number(3.0).as_deref(), Some("3"));
        assert_eq!(format_number(1e15).as_deref(), Some("1e+15"));
    }

    #[test]
    fn units_keep_the_typed_token() {
        assert_eq!(eval("10km->mi").as_deref(), Some("6.214 mi"));
        assert_eq!(eval("10 km to Miles").as_deref(), Some("6.214 miles"));
        assert_eq!(eval("100c→f").as_deref(), Some("212 f"));
        assert_eq!(eval("32f to c").as_deref(), Some("0 c"));
        assert_eq!(eval("1l to ml").as_deref(), Some("1000 ml"));
        assert_eq!(eval("1 cup to l").as_deref(), Some("0.24 l"));
        assert_eq!(eval("1kg->km"), None);
    }

    #[test]
    fn currency_uses_the_bundled_table() {
        assert_eq!(eval("100usd to eur").as_deref(), Some("€92.00"));
        assert_eq!(eval("$100 to gbp").as_deref(), Some("£79.00"));
        assert_eq!(eval("1 usd to jpy").as_deref(), Some("¥151"));
        assert_eq!(eval("1000 usd to krw").as_deref(), Some("₩1,360,000"));
        assert_eq!(eval("1 usd to chf").as_deref(), Some("CHF\u{a0}0.90"));
        assert_eq!(eval("10 abc to eur"), None);
    }

    #[test]
    fn dates_come_from_the_injected_clock() {
        assert_eq!(eval("today").as_deref(), Some("Jun 23, 2026"));
        assert_eq!(eval("tmr").as_deref(), Some("Jun 24, 2026"));
        assert_eq!(eval("yesterday").as_deref(), Some("Jun 22, 2026"));
        assert_eq!(eval("today(iso)").as_deref(), Some("2026-06-23"));
        assert_eq!(eval("today(long)").as_deref(), Some("June 23, 2026"));
        assert_eq!(eval("today(short)").as_deref(), Some("6/23/26"));
        assert_eq!(eval("now").as_deref(), Some("3:04 PM"));
        assert_eq!(eval("now(24h)").as_deref(), Some("15:04"));
        assert_eq!(eval("noon").as_deref(), Some("12:00 PM"));
        assert_eq!(eval("midnight(24h)").as_deref(), Some("00:00"));
        assert_eq!(eval("dt").as_deref(), Some("Jun 23, 2026 at 3:04 PM"));
        assert_eq!(eval("+3d(iso)").as_deref(), Some("2026-06-26"));
        assert_eq!(eval("-1w(iso)").as_deref(), Some("2026-06-16"));
        assert_eq!(eval("+1mo(iso)").as_deref(), Some("2026-07-23"));
        assert_eq!(eval("+1y(iso)").as_deref(), Some("2027-06-23"));
        // Tuesday: this week's Tuesday is today, next and last are a week off.
        assert_eq!(eval("this-tue(iso)").as_deref(), Some("2026-06-23"));
        assert_eq!(eval("next tue(iso)").as_deref(), Some("2026-06-30"));
        assert_eq!(eval("lastfri(iso)").as_deref(), Some("2026-06-19"));
    }

    #[test]
    fn random_macros_use_the_injected_source() {
        assert_eq!(eval("uuid").as_deref(), Some("ABCD-1234"));
        assert_eq!(eval("dice").as_deref(), Some("1"));
        assert_eq!(eval("coin").as_deref(), Some("Heads"));
        assert_eq!(eval("d20").as_deref(), Some("1"));
        assert_eq!(eval("rand(5,3)").as_deref(), Some("3"));
        assert_eq!(eval("rand(0)"), None);
        let mut standard = Engine::standard();
        for _ in 0..50 {
            let roll: i64 = standard.evaluate("d6").unwrap().preview.parse().unwrap();
            assert!((1..=6).contains(&roll));
        }
        let uuid = standard.evaluate("uuid").unwrap().preview;
        assert_eq!(uuid, uuid.to_uppercase());
    }
}
