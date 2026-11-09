//! One line per past week and month, condensed from the overnight reviews
//! (`DreamRollupFormat.swift`, the deterministic half of `DreamRollupService`).
//! A rollup is a cache over the daily reviews: it records a stamp of the reviews
//! it was made from, and anyone reading it recomputes that stamp, so a deleted,
//! retracted or regenerated review makes it stale at once. Stale lines are never
//! shown. Clear work memory removes them with the reviews (`dreams/rollups`).

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike as _, Duration, Months, NaiveDate, Utc, Weekday};
use serde::{Deserialize, Serialize};

use super::day_key;
use crate::library::{sha256_hex, write_atomic, write_json};
use crate::time::{iso_seconds, parse_iso};

pub const WEEKS_KEPT: i64 = 8;
pub const MONTHS_KEPT: u32 = 6;
pub const MAXIMUM_PER_NIGHT: usize = 3;
/// New lines are written at most this often: a night that rebuilds several
/// reviews runs this after each one.
pub const MINIMUM_GENERATION_INTERVAL_SECONDS: i64 = 20 * 60 * 60;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Week,
    Month,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rollup {
    pub kind: Kind,
    /// "2026-W41" or "2026-09".
    pub key: String,
    pub first_day: String,
    pub last_day: String,
    pub line: String,
    pub stamp: String,
    #[serde(with = "iso_seconds")]
    pub generated_at: DateTime<Utc>,
}

/// The fields of a stored review the briefing and rollups use.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DayReview {
    pub day: String,
    #[serde(with = "iso_seconds")]
    pub generated_at: DateTime<Utc>,
    pub narrative: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Period {
    pub kind: Kind,
    pub key: String,
    pub first_day: String,
    pub last_day: String,
    pub label: String,
}

pub fn rollups_dir(root: &Path) -> PathBuf {
    root.join("dreams").join("rollups")
}

pub fn rollup_path(root: &Path, key: &str) -> PathBuf {
    rollups_dir(root).join(format!("{key}.json"))
}

fn is_day_key(text: &str) -> bool {
    text.len() == 10
        && text.char_indices().all(|(index, c)| {
            if index == 4 || index == 7 {
                c == '-'
            } else {
                c.is_ascii_digit()
            }
        })
}

/// Every readable review, by day. One whose day doesn't match its name is
/// ignored, as the store does.
pub fn reviews(root: &Path) -> HashMap<String, DayReview> {
    let mut result = HashMap::new();
    let Ok(entries) = fs::read_dir(root.join("dreams")) else {
        return result;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(key) = name.to_str().and_then(|n| n.strip_suffix(".json")) else {
            continue;
        };
        if !is_day_key(key) {
            continue;
        }
        let Some(review) = fs::read(entry.path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<DayReview>(&bytes).ok())
        else {
            continue;
        };
        if review.day == key {
            result.insert(key.to_string(), review);
        }
    }
    result
}

pub fn rollups(root: &Path) -> Vec<Rollup> {
    let Ok(entries) = fs::read_dir(rollups_dir(root)) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter(|entry| entry.path().extension().is_some_and(|e| e == "json"))
        .filter_map(|entry| {
            let bytes = fs::read(entry.path()).ok()?;
            serde_json::from_slice(&bytes).ok()
        })
        .collect()
}

/// Reviews inside the period, oldest first.
pub fn reviews_in<'a>(
    first_day: &str,
    last_day: &str,
    reviews: &'a HashMap<String, DayReview>,
) -> Vec<&'a DayReview> {
    let mut inside: Vec<&DayReview> = reviews
        .values()
        .filter(|r| r.day.as_str() >= first_day && r.day.as_str() <= last_day)
        .collect();
    inside.sort_by(|a, b| a.day.cmp(&b.day));
    inside
}

/// Changes whenever a review in the period appears, disappears or is regenerated.
pub fn stamp(reviews: &[&DayReview]) -> String {
    let mut sorted = reviews.to_vec();
    sorted.sort_by(|a, b| a.day.cmp(&b.day));
    let material = sorted
        .iter()
        .map(|review| {
            format!(
                "{}|{}",
                review.day,
                review
                    .generated_at
                    .to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    sha256_hex(material.as_bytes())
}

pub fn is_valid(rollup: &Rollup, reviews: &HashMap<String, DayReview>) -> bool {
    let inside = reviews_in(&rollup.first_day, &rollup.last_day, reviews);
    !inside.is_empty() && stamp(&inside) == rollup.stamp
}

/// The Monday-to-Sunday week containing `day`.
pub fn week_containing(day: NaiveDate) -> Period {
    let week = day.iso_week();
    let start = NaiveDate::from_isoywd_opt(week.year(), week.week(), Weekday::Mon).unwrap_or(day);
    let end = start + Duration::days(6);
    Period {
        kind: Kind::Week,
        key: format!("{:04}-W{:02}", week.year(), week.week()),
        first_day: day_key(start),
        last_day: day_key(end),
        label: format!("Week of {}", start.format("%b %-d")),
    }
}

/// The calendar month containing `day`.
pub fn month_containing(day: NaiveDate) -> Period {
    let start = day.with_day(1).unwrap_or(day);
    let next = start.checked_add_months(Months::new(1)).unwrap_or(start);
    let end = next - Duration::days(1);
    Period {
        kind: Kind::Month,
        key: format!("{:04}-{:02}", start.year(), start.month()),
        first_day: day_key(start),
        last_day: day_key(end),
        label: start.format("%B %Y").to_string(),
    }
}

/// The finished weeks and months the briefing can show, newest first.
pub fn periods(today: NaiveDate) -> Vec<Period> {
    let today_key = day_key(today);
    let mut periods: Vec<Period> = (1..=WEEKS_KEPT)
        .map(|offset| week_containing(today - Duration::days(7 * offset)))
        .collect();
    let this_month = today.with_day(1).unwrap_or(today);
    for offset in 1..=MONTHS_KEPT {
        if let Some(month) = this_month.checked_sub_months(Months::new(offset)) {
            periods.push(month_containing(month));
        }
    }
    periods.retain(|p| p.last_day < today_key);
    periods.sort_by(|a, b| {
        b.last_day
            .cmp(&a.last_day)
            .then_with(|| (b.kind == Kind::Week).cmp(&(a.kind == Kind::Week)))
    });
    periods
}

/// Periods with reviews but no current line, newest first.
pub fn due(
    reviews: &HashMap<String, DayReview>,
    rollups: &[Rollup],
    today: NaiveDate,
) -> Vec<Period> {
    let current: BTreeSet<&str> = rollups
        .iter()
        .filter(|r| is_valid(r, reviews))
        .map(|r| r.key.as_str())
        .collect();
    periods(today)
        .into_iter()
        .filter(|p| {
            !current.contains(p.key.as_str())
                && !reviews_in(&p.first_day, &p.last_day, reviews).is_empty()
        })
        .collect()
}

fn generation_marker(root: &Path) -> PathBuf {
    rollups_dir(root).join(".last-generation")
}

pub fn last_generation(root: &Path) -> Option<DateTime<Utc>> {
    parse_iso(fs::read_to_string(generation_marker(root)).ok()?.trim())
}

pub fn record_generation(root: &Path, at: DateTime<Utc>) {
    let text = at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    if let Err(err) = write_atomic(&generation_marker(root), text.as_bytes()) {
        log::warn!("could not record the rollup time: {err}");
    }
}

/// Removes every line covering `day_key`, for when that review goes.
pub fn remove_covering(day_key: &str, root: &Path) {
    for rollup in rollups(root) {
        if rollup.first_day.as_str() <= day_key && day_key <= rollup.last_day.as_str() {
            let _ = fs::remove_file(rollup_path(root, &rollup.key));
        }
    }
}

pub fn write(rollup: &Rollup, root: &Path) -> anyhow::Result<()> {
    write_json(&rollup_path(root, &rollup.key), rollup)
}

/// The first `count` sentences of a review's narrative, on one line.
pub fn sentences(text: &str, count: usize, max_characters: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut taken = 0;
    let mut end = flat.len();
    let mut chars = flat.char_indices().peekable();
    while let Some((index, c)) = chars.next() {
        if !matches!(c, '.' | '!' | '?' | '…') {
            continue;
        }
        let after = index + c.len_utf8();
        let at_boundary = chars.peek().is_none_or(|(_, next)| next.is_whitespace());
        if at_boundary {
            taken += 1;
            if taken >= count {
                end = after;
                break;
            }
        }
    }
    let result = flat[..end].trim();
    if result.chars().count() <= max_characters {
        return result.to_string();
    }
    let head: String = result
        .chars()
        .take(max_characters.saturating_sub(1))
        .collect();
    format!("{}…", head.trim())
}
