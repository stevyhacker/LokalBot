//! Autocomplete's counters and timings (`CotypingStats.swift`,
//! `CotypingUsageHistory.swift`, `CotypingLiveMeasure.swift`).
//!
//! The Mac keeps these in `UserDefaults` (`lokalbotv3.cotypingStats`,
//! `lokalbotv3.cotypingUsage`), so there is no Mac file to match. Here they
//! are `<root>/cotyping-stats.json` and `<root>/cotyping-usage.json` in the
//! Mac's JSON encoding, the way `settings.json` stands in for its blob. A
//! damaged file reads as empty, as on the Mac. Counts and timings only: no
//! text, app name or window title.

use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Datelike as _, Duration, Local, NaiveDate, TimeZone as _};
use serde::{Deserialize, Serialize};

use crate::library::write_atomic;

pub const STATS_FILE: &str = "cotyping-stats.json";
pub const USAGE_FILE: &str = "cotyping-usage.json";

/// Rolling latency windows keep this many samples.
pub const MAX_LATENCIES: usize = 50;
/// How long an accept may wait to be read back.
pub const INSERTION_TIMEOUT_MS: i64 = 1_500;
/// Characters of the text before the caret an insertion check compares.
const INSERTION_TAIL: usize = 48;

/// Daily rows are kept this long; months keep the totals.
pub const RETAINED_DAYS: i64 = 92;
/// A longer gap between typed characters is a pause, not typing speed.
pub const MAX_TYPING_GAP_MS: i64 = 1_000;
/// Typing speed is shown once this many gaps are measured.
pub const MINIMUM_TYPING_GAPS: i64 = 200;
/// 40 words a minute at five characters a word.
pub const FALLBACK_MS_PER_KEYSTROKE: f64 = 300.0;

/// The Mac's surface raw values with their titles, in display order
/// (`CotypingSurfaceClass.measured`, `measureTitle`).
pub const SURFACES: [(&str, &str); 6] = [
    ("other", "Native apps"),
    ("browser", "Browsers"),
    ("chat", "Chat"),
    ("email", "Email"),
    ("codeEditor", "Code editors"),
    ("terminal", "Terminals"),
];

fn is_zero(value: &i64) -> bool {
    *value == 0
}

fn percentile(samples: &[i64], p: f64) -> Option<i64> {
    if samples.is_empty() {
        return None;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let index = ((sorted.len() - 1) as f64 * p).round() as usize;
    sorted.get(index.min(sorted.len() - 1)).copied()
}

fn push_latency(window: &mut Vec<i64>, latency: i64) {
    window.push(latency.max(0));
    if window.len() > MAX_LATENCIES {
        let excess = window.len() - MAX_LATENCIES;
        window.drain(..excess);
    }
}

// ------------------------------------------------------------- live measure

/// `CotypingInsertionCheck.Outcome`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertionOutcome {
    /// The app has not shown the change yet.
    Pending,
    /// The field holds the text before the caret followed by the insertion.
    Confirmed,
    /// The field changed, but not to the inserted text.
    Mismatched,
    /// The field never showed a change, or focus left before it did.
    Unconfirmed,
}

/// How autocomplete behaved while typing in one kind of app (`CotypingLiveMeasure`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LiveMeasure {
    pub shown: i64,
    pub visible_latencies_ms: Vec<i64>,
    pub accepts: i64,
    pub insertions_confirmed: i64,
    pub insertions_mismatched: i64,
    pub insertions_unconfirmed: i64,
    pub accepts_corrected: i64,
}

impl LiveMeasure {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    pub fn median_visible_ms(&self) -> Option<i64> {
        percentile(&self.visible_latencies_ms, 0.5)
    }

    pub fn p95_visible_ms(&self) -> Option<i64> {
        percentile(&self.visible_latencies_ms, 0.95)
    }

    /// Insertions with a known outcome.
    pub fn insertions_checked(&self) -> i64 {
        self.insertions_confirmed + self.insertions_mismatched
    }

    fn merge(&mut self, other: &Self) {
        self.shown += other.shown;
        self.visible_latencies_ms
            .extend_from_slice(&other.visible_latencies_ms);
        self.accepts += other.accepts;
        self.insertions_confirmed += other.insertions_confirmed;
        self.insertions_mismatched += other.insertions_mismatched;
        self.insertions_unconfirmed += other.insertions_unconfirmed;
        self.accepts_corrected += other.accepts_corrected;
    }
}

/// `CotypingStats`: usage and latency counters, shown under "Usage and timing".
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CotypingStats {
    pub generations: i64,
    pub errors: i64,
    pub accepts: i64,
    pub chars_accepted: i64,
    pub latencies_ms: Vec<i64>,
    /// By surface raw value.
    pub live: BTreeMap<String, LiveMeasure>,
}

impl CotypingStats {
    pub fn median_latency_ms(&self) -> Option<i64> {
        percentile(&self.latencies_ms, 0.5)
    }

    pub fn p95_latency_ms(&self) -> Option<i64> {
        percentile(&self.latencies_ms, 0.95)
    }

    pub fn record_generation(&mut self, latency_ms: i64) {
        self.generations += 1;
        push_latency(&mut self.latencies_ms, latency_ms);
    }

    pub fn record_error(&mut self) {
        self.errors += 1;
    }

    pub fn record_accept(&mut self, chars: i64, surface: &str) {
        self.accepts += 1;
        self.chars_accepted += chars.max(0);
        self.live.entry(surface.to_string()).or_default().accepts += 1;
    }

    pub fn record_shown(&mut self, latency_ms: i64, surface: &str) {
        let measure = self.live.entry(surface.to_string()).or_default();
        measure.shown += 1;
        push_latency(&mut measure.visible_latencies_ms, latency_ms);
    }

    pub fn record_insertion(&mut self, outcome: InsertionOutcome, count: i64, surface: &str) {
        let measure = self.live.entry(surface.to_string()).or_default();
        for _ in 0..count.max(0) {
            match outcome {
                InsertionOutcome::Confirmed => measure.insertions_confirmed += 1,
                InsertionOutcome::Mismatched => measure.insertions_mismatched += 1,
                InsertionOutcome::Unconfirmed => measure.insertions_unconfirmed += 1,
                InsertionOutcome::Pending => {}
            }
        }
    }

    pub fn record_correction(&mut self, surface: &str) {
        self.live
            .entry(surface.to_string())
            .or_default()
            .accepts_corrected += 1;
    }

    /// The recorded surfaces in display order, with their titles.
    pub fn live_rows(&self) -> Vec<(&'static str, &LiveMeasure)> {
        SURFACES
            .iter()
            .filter_map(|(key, title)| {
                self.live
                    .get(*key)
                    .filter(|m| !m.is_empty())
                    .map(|m| (*title, m))
            })
            .collect()
    }

    /// `report(model:)`: a plain-text table for comparing runs. Counts and
    /// timings only. Unlike the Mac's, it says the numbers come from field
    /// reads: this port has no keyboard monitor.
    pub fn report(&self, model: &str) -> String {
        let mut lines = vec![format!("Autocomplete typing measurements ({model})")];
        let generation = self
            .median_latency_ms()
            .map(|median| {
                format!(
                    " · generation median {median} ms, p95 {} ms",
                    self.p95_latency_ms().unwrap_or(median)
                )
            })
            .unwrap_or_default();
        lines.push(format!(
            "Suggested {} · accepted {}{generation}",
            self.generations, self.accepts
        ));
        lines.push("Measured from reads of the field, so timings are approximate.".to_string());
        lines.push(String::new());
        lines.push("| Surface | Shown | Keystroke to visible (median / p95) | Accepted | Insertions confirmed / wrong / unconfirmed | Corrected right after |".to_string());
        lines.push("| --- | ---: | ---: | ---: | ---: | ---: |".to_string());
        let mut total = LiveMeasure::default();
        let rows = self.live_rows();
        for (_, measure) in &rows {
            total.merge(measure);
        }
        let mut row = |title: &str, measure: &LiveMeasure| {
            let timing = measure.median_visible_ms().map_or_else(
                || "n/a".to_string(),
                |median| {
                    format!(
                        "{median} / {} ms",
                        measure.p95_visible_ms().unwrap_or(median)
                    )
                },
            );
            lines.push(format!(
                "| {title} | {} | {timing} | {} | {} / {} / {} | {} |",
                measure.shown,
                measure.accepts,
                measure.insertions_confirmed,
                measure.insertions_mismatched,
                measure.insertions_unconfirmed,
                measure.accepts_corrected
            ));
        };
        for (title, measure) in &rows {
            row(title, measure);
        }
        if rows.len() > 1 {
            row("All", &total);
        }
        if rows.is_empty() {
            lines.push("| No typing measured yet | 0 | n/a | 0 | 0 / 0 / 0 | 0 |".to_string());
        }
        lines.join("\n")
    }
}

/// Whether an accepted suggestion really arrived in the field
/// (`CotypingInsertionCheck`): what the app shows afterwards against what was
/// sent. Holds a little text only until it is resolved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InsertionCheck {
    tail: String,
    inserted: String,
    /// Accepts this check stands for.
    pub count: i64,
    pub surface: String,
    pub pid: u32,
    pub field_id: u64,
    pub started_ms: i64,
}

impl InsertionCheck {
    pub fn new(
        before: &str,
        inserted: &str,
        surface: &str,
        pid: u32,
        field_id: u64,
        started_ms: i64,
    ) -> Self {
        let tail: String = {
            let count = before.chars().count();
            before
                .chars()
                .skip(count.saturating_sub(INSERTION_TAIL))
                .collect()
        };
        Self {
            tail: normalized(&tail),
            inserted: normalized(inserted),
            count: 1,
            surface: surface.to_string(),
            pid,
            field_id,
            started_ms,
        }
    }

    /// An accept sent while this one is still unread is checked with it.
    pub fn extend(&mut self, inserted: &str, at_ms: i64) {
        self.inserted.push_str(&normalized(inserted));
        self.count += 1;
        self.started_ms = at_ms;
    }

    /// `live` is the focused field's identity and text, or `None` when
    /// nothing editable has focus.
    pub fn outcome(&self, live: Option<(u32, u64, &str)>, now_ms: i64) -> InsertionOutcome {
        let timed_out = now_ms - self.started_ms >= INSERTION_TIMEOUT_MS;
        let silent = if timed_out {
            InsertionOutcome::Unconfirmed
        } else {
            InsertionOutcome::Pending
        };
        let Some((_, _, before)) =
            live.filter(|(pid, field_id, _)| *pid == self.pid && *field_id == self.field_id)
        else {
            return silent;
        };
        let text = normalized(before);
        let wanted = self.tail.chars().count() + self.inserted.chars().count() + 64;
        let count = text.chars().count();
        let window: String = text.chars().skip(count.saturating_sub(wanted)).collect();
        if window.contains(&format!("{}{}", self.tail, self.inserted)) {
            return InsertionOutcome::Confirmed;
        }
        if !timed_out {
            return InsertionOutcome::Pending;
        }
        let after = if self.tail.is_empty() {
            window.as_str()
        } else {
            match window.rfind(&self.tail) {
                Some(at) => &window[at + self.tail.len()..],
                None => return InsertionOutcome::Unconfirmed,
            }
        };
        if after.is_empty() {
            InsertionOutcome::Unconfirmed
        } else {
            InsertionOutcome::Mismatched
        }
    }
}

/// Browsers publish a trailing space as a non-breaking space.
fn normalized(text: &str) -> String {
    text.replace('\u{00A0}', " ")
}

// ------------------------------------------------------------ usage history

/// What autocomplete did for one period (`CotypingUsageCounts`). Zero counts
/// are left out of the file.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageCounts {
    #[serde(skip_serializing_if = "is_zero")]
    pub shown: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub used: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub accepts: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub words: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub characters: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub taken_back: i64,
}

impl UsageCounts {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// Share of shown suggestions used; `used` is capped at `shown`, since an
    /// accept just after midnight can land on a later day than its suggestion.
    pub fn acceptance_rate(&self) -> Option<f64> {
        (self.shown > 0).then(|| self.used.min(self.shown) as f64 / self.shown as f64)
    }

    pub fn words_per_used_suggestion(&self) -> Option<f64> {
        (self.used > 0).then(|| self.words as f64 / self.used as f64)
    }

    /// Key presses not made: every inserted character, less the accept presses.
    pub fn keystrokes_saved(&self) -> i64 {
        (self.characters - self.accepts).max(0)
    }

    pub fn merge(&mut self, other: &Self) {
        self.shown += other.shown;
        self.used += other.used;
        self.accepts += other.accepts;
        self.words += other.words;
        self.characters += other.characters;
        self.taken_back += other.taken_back;
    }
}

fn counts_empty(counts: &UsageCounts) -> bool {
    counts.is_empty()
}

/// One day or month (`CotypingUsageBucket`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UsageBucket {
    #[serde(skip_serializing_if = "counts_empty")]
    pub suggestions: UsageCounts,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub surfaces: BTreeMap<String, UsageCounts>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub models: BTreeMap<String, UsageCounts>,
    #[serde(skip_serializing_if = "is_zero")]
    pub typed_characters: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub typing_milliseconds: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub typing_gaps: i64,
    #[serde(skip_serializing_if = "is_zero")]
    pub typos_fixed: i64,
}

impl UsageBucket {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// Share of the text written where autocomplete works that came from it.
    pub fn share_of_text(&self) -> Option<f64> {
        let total = self.suggestions.characters + self.typed_characters;
        (total > 0).then(|| self.suggestions.characters as f64 / total as f64)
    }

    /// Average time per typed character, once there are enough gaps to say.
    pub fn milliseconds_per_keystroke(&self) -> Option<f64> {
        (self.typing_gaps >= MINIMUM_TYPING_GAPS)
            .then(|| self.typing_milliseconds as f64 / self.typing_gaps as f64)
    }

    pub fn merge(&mut self, other: &Self) {
        self.suggestions.merge(&other.suggestions);
        for (key, counts) in &other.surfaces {
            self.surfaces.entry(key.clone()).or_default().merge(counts);
        }
        for (key, counts) in &other.models {
            self.models.entry(key.clone()).or_default().merge(counts);
        }
        self.typed_characters += other.typed_characters;
        self.typing_milliseconds += other.typing_milliseconds;
        self.typing_gaps += other.typing_gaps;
        self.typos_fixed += other.typos_fixed;
    }

    fn update(&mut self, surface: &str, model: &str, change: impl Fn(&mut UsageCounts)) {
        change(&mut self.suggestions);
        change(self.surfaces.entry(surface.to_string()).or_default());
        change(self.models.entry(model.to_string()).or_default());
    }
}

/// `CotypingUsageRange`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum UsageRange {
    Week,
    #[default]
    Month,
    Year,
    AllTime,
}

/// One bar of a chart: a day or month with its counts.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UsageBar {
    pub start: NaiveDate,
    pub bucket: UsageBucket,
}

/// One range, ready to show (`CotypingUsageSummary`).
#[derive(Clone, Debug, PartialEq)]
pub struct UsageSummary {
    pub range: UsageRange,
    pub total: UsageBucket,
    pub bars: Vec<UsageBar>,
    /// Bars are months, not days.
    pub monthly: bool,
    /// Measured from everything recorded: typing speed is a habit, not a
    /// property of the range.
    pub milliseconds_per_keystroke: Option<f64>,
}

impl UsageSummary {
    pub fn words_per_minute(&self) -> Option<i64> {
        self.milliseconds_per_keystroke
            .map(|ms| (60_000.0 / (ms * 5.0)).round() as i64)
    }

    pub fn time_saved_seconds(&self) -> f64 {
        self.total.suggestions.keystrokes_saved() as f64
            * self
                .milliseconds_per_keystroke
                .unwrap_or(FALLBACK_MS_PER_KEYSTROKE)
            / 1_000.0
    }

    pub fn active_bars(&self) -> usize {
        self.bars
            .iter()
            .filter(|bar| bar.bucket.suggestions.accepts > 0)
            .count()
    }

    /// Headroom above the tallest bar, with a floor so a quiet week is not
    /// drawn full height.
    pub fn word_ceiling(&self) -> i64 {
        let tallest = self
            .bars
            .iter()
            .map(|bar| bar.bucket.suggestions.words)
            .max()
            .unwrap_or(0);
        (tallest + (tallest + 9) / 10).max(10)
    }
}

/// Autocomplete use by local calendar day and month (`CotypingUsageHistory`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct UsageHistory {
    pub days: BTreeMap<String, UsageBucket>,
    pub months: BTreeMap<String, UsageBucket>,
}

impl UsageHistory {
    pub fn is_empty(&self) -> bool {
        self.months.values().all(UsageBucket::is_empty)
    }

    pub fn record_shown(&mut self, surface: &str, model: &str, day: NaiveDate) {
        self.record(day, |bucket| {
            bucket.update(surface, model, |counts| counts.shown += 1)
        });
    }

    /// One accept press. `first_of_suggestion` marks the suggestion as used.
    pub fn record_accept(
        &mut self,
        words: i64,
        characters: i64,
        first_of_suggestion: bool,
        surface: &str,
        model: &str,
        day: NaiveDate,
    ) {
        self.record(day, |bucket| {
            bucket.update(surface, model, |counts| {
                counts.accepts += 1;
                counts.words += words.max(0);
                counts.characters += characters.max(0);
                if first_of_suggestion {
                    counts.used += 1;
                }
            })
        });
    }

    pub fn record_taken_back(&mut self, surface: &str, model: &str, day: NaiveDate) {
        self.record(day, |bucket| {
            bucket.update(surface, model, |counts| counts.taken_back += 1)
        });
    }

    /// Characters typed in one read of the field. There is no key tap here,
    /// so `elapsed_ms` since the previous read stands in for the gaps between
    /// them: a read up to `MAX_TYPING_GAP_MS` after the last counts each
    /// character as one gap, and a longer one counts none.
    pub fn record_typed(&mut self, characters: i64, elapsed_ms: Option<i64>, day: NaiveDate) {
        if characters <= 0 {
            return;
        }
        self.record(day, |bucket| {
            bucket.typed_characters += characters;
            if let Some(elapsed) = elapsed_ms.filter(|ms| (0..=MAX_TYPING_GAP_MS).contains(ms)) {
                bucket.typing_milliseconds += elapsed;
                bucket.typing_gaps += characters;
            }
        });
    }

    pub fn record_typo_fixed(&mut self, day: NaiveDate) {
        self.record(day, |bucket| bucket.typos_fixed += 1);
    }

    fn record(&mut self, day: NaiveDate, change: impl Fn(&mut UsageBucket)) {
        let key = day_key(day);
        if !self.days.contains_key(&key) {
            self.prune(day);
        }
        change(self.days.entry(key).or_default());
        change(self.months.entry(month_key(day)).or_default());
    }

    /// Zero-padded keys sort in date order.
    fn prune(&mut self, today: NaiveDate) {
        let oldest = day_key(today - Duration::days(RETAINED_DAYS - 1));
        self.days.retain(|key, _| key.as_str() >= oldest.as_str());
    }

    /// `summary(_:now:calendar:)`.
    pub fn summary(&self, range: UsageRange, today: NaiveDate) -> UsageSummary {
        let mut bars = Vec::new();
        let monthly = matches!(range, UsageRange::Year | UsageRange::AllTime);
        match range {
            UsageRange::Week | UsageRange::Month => {
                let count = if range == UsageRange::Week { 7 } else { 30 };
                for offset in (0..count).rev() {
                    let day = today - Duration::days(offset);
                    bars.push(UsageBar {
                        start: day,
                        bucket: self.days.get(&day_key(day)).cloned().unwrap_or_default(),
                    });
                }
            }
            UsageRange::Year | UsageRange::AllTime => {
                let this_month = first_of_month(today);
                let mut count = 12;
                if range == UsageRange::AllTime {
                    // From the first recorded month, never fewer than one bar.
                    let first = self
                        .months
                        .iter()
                        .filter(|(_, bucket)| !bucket.is_empty())
                        .map(|(key, _)| key)
                        .min()
                        .and_then(|key| month_start(key))
                        .unwrap_or(this_month);
                    count = (months_between(first, this_month) + 1).max(1);
                }
                for offset in (0..count).rev() {
                    let month = months_back(this_month, offset);
                    bars.push(UsageBar {
                        start: month,
                        bucket: self
                            .months
                            .get(&month_key(month))
                            .cloned()
                            .unwrap_or_default(),
                    });
                }
            }
        }
        let mut total = UsageBucket::default();
        for bar in &bars {
            total.merge(&bar.bucket);
        }
        let mut everything = UsageBucket::default();
        for month in self.months.values() {
            everything.typing_milliseconds += month.typing_milliseconds;
            everything.typing_gaps += month.typing_gaps;
        }
        UsageSummary {
            range,
            total,
            bars,
            monthly,
            milliseconds_per_keystroke: everything.milliseconds_per_keystroke(),
        }
    }
}

/// Local calendar day.
pub fn local_day(now: DateTime<chrono::Utc>) -> NaiveDate {
    Local.from_utc_datetime(&now.naive_utc()).date_naive()
}

fn day_key(day: NaiveDate) -> String {
    format!("{:04}-{:02}-{:02}", day.year(), day.month(), day.day())
}

fn month_key(day: NaiveDate) -> String {
    format!("{:04}-{:02}", day.year(), day.month())
}

fn first_of_month(day: NaiveDate) -> NaiveDate {
    day.with_day(1).unwrap_or(day)
}

fn month_start(key: &str) -> Option<NaiveDate> {
    let (year, month) = key.split_once('-')?;
    NaiveDate::from_ymd_opt(year.parse().ok()?, month.parse().ok()?, 1)
}

fn months_between(first: NaiveDate, last: NaiveDate) -> i64 {
    (i64::from(last.year()) * 12 + i64::from(last.month()))
        - (i64::from(first.year()) * 12 + i64::from(first.month()))
}

fn months_back(month: NaiveDate, offset: i64) -> NaiveDate {
    let months = i64::from(month.year()) * 12 + i64::from(month.month0()) - offset;
    NaiveDate::from_ymd_opt(
        months.div_euclid(12) as i32,
        months.rem_euclid(12) as u32 + 1,
        1,
    )
    .unwrap_or(month)
}

// -------------------------------------------------------------------- files

/// Reads both files; a missing or damaged one reads as empty.
pub fn load(root: &Path) -> (CotypingStats, UsageHistory) {
    fn read<T: serde::de::DeserializeOwned + Default>(path: &Path) -> T {
        std::fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }
    (read(&root.join(STATS_FILE)), read(&root.join(USAGE_FILE)))
}

pub fn save_stats(root: &Path, stats: &CotypingStats) -> anyhow::Result<()> {
    write_atomic(&root.join(STATS_FILE), &serde_json::to_vec(stats)?)?;
    Ok(())
}

pub fn save_usage(root: &Path, usage: &UsageHistory) -> anyhow::Result<()> {
    write_atomic(&root.join(USAGE_FILE), &serde_json::to_vec(usage)?)?;
    Ok(())
}

pub fn remove_stats(root: &Path) -> std::io::Result<()> {
    remove(&root.join(STATS_FILE))
}

pub fn remove_usage(root: &Path) -> std::io::Result<()> {
    remove(&root.join(USAGE_FILE))
}

fn remove(path: &Path) -> std::io::Result<()> {
    match std::fs::remove_file(path) {
        Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(err),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(text: &str) -> NaiveDate {
        NaiveDate::parse_from_str(text, "%Y-%m-%d").unwrap()
    }

    /// Derived from the Swift `Codable` types; no capture from a Mac exists.
    const USAGE: &str = r#"{"days":{"2026-10-14":{"suggestions":{"shown":4,"used":2,"accepts":3,"words":5,"characters":27,"takenBack":1},"surfaces":{"browser":{"shown":4,"used":2,"accepts":3,"words":5,"characters":27,"takenBack":1}},"models":{"gemma-4-e2b":{"shown":4,"used":2,"accepts":3,"words":5,"characters":27,"takenBack":1}},"typedCharacters":120,"typingMilliseconds":21000,"typingGaps":100,"typosFixed":1}},"months":{"2026-09":{},"2026-10":{"suggestions":{"shown":4,"used":2,"accepts":3,"words":5,"characters":27,"takenBack":1},"typedCharacters":120,"typingMilliseconds":21000,"typingGaps":100,"typosFixed":1}}}"#;
    const STATS: &str = r#"{"generations":12,"errors":1,"accepts":3,"charsAccepted":27,"latenciesMs":[180,240],"live":{"chat":{"shown":2,"visibleLatenciesMs":[300,350],"accepts":1,"insertionsConfirmed":1,"insertionsMismatched":0,"insertionsUnconfirmed":0,"acceptsCorrected":0}}}"#;

    #[test]
    fn the_macs_encoding_reads_and_writes_back_the_same() {
        let usage: UsageHistory = serde_json::from_str(USAGE).unwrap();
        let bucket = &usage.days["2026-10-14"];
        assert_eq!(bucket.suggestions.taken_back, 1);
        assert_eq!(bucket.surfaces["browser"].used, 2);
        assert_eq!(bucket.typing_gaps, 100);
        assert_eq!(serde_json::to_string(&usage).unwrap(), USAGE);
        let stats: CotypingStats = serde_json::from_str(STATS).unwrap();
        assert_eq!(stats.live["chat"].visible_latencies_ms, [300, 350]);
        assert_eq!(serde_json::to_string(&stats).unwrap(), STATS);
    }

    #[test]
    fn a_record_saved_before_a_field_existed_keeps_its_values() {
        let stats: CotypingStats = serde_json::from_str(r#"{"generations":3}"#).unwrap();
        assert_eq!(stats.generations, 3);
        let usage: UsageHistory = serde_json::from_str("{}").unwrap();
        assert!(usage.is_empty());
    }

    #[test]
    fn files_round_trip_and_damage_reads_as_empty() {
        let dir = tempfile::tempdir().unwrap();
        let mut stats = CotypingStats::default();
        stats.record_generation(120);
        let mut usage = UsageHistory::default();
        usage.record_shown("chat", "m", day("2026-10-14"));
        save_stats(dir.path(), &stats).unwrap();
        save_usage(dir.path(), &usage).unwrap();
        assert_eq!(load(dir.path()), (stats, usage));
        std::fs::write(dir.path().join(STATS_FILE), b"not json").unwrap();
        assert_eq!(load(dir.path()).0, CotypingStats::default());
        remove_usage(dir.path()).unwrap();
        remove_usage(dir.path()).unwrap();
        assert!(load(dir.path()).1.is_empty());
    }

    #[test]
    fn latency_windows_roll_and_percentiles_are_nearest_rank() {
        let mut stats = CotypingStats::default();
        for latency in 0..60 {
            stats.record_generation(latency);
        }
        assert_eq!(stats.generations, 60);
        assert_eq!(stats.latencies_ms.len(), MAX_LATENCIES);
        assert_eq!(stats.latencies_ms[0], 10);
        assert_eq!(stats.median_latency_ms(), Some(35));
        assert_eq!(stats.p95_latency_ms(), Some(57));
    }

    #[test]
    fn daily_rows_expire_and_months_keep_the_totals() {
        let mut usage = UsageHistory::default();
        usage.record_shown("chat", "m", day("2026-01-01"));
        usage.record_shown("chat", "m", day("2026-06-01"));
        assert_eq!(usage.days.len(), 1);
        assert_eq!(usage.months.len(), 2);
        assert_eq!(usage.months["2026-01"].suggestions.shown, 1);
    }

    #[test]
    fn typing_counts_gaps_only_for_short_reads() {
        let mut usage = UsageHistory::default();
        let today = day("2026-10-14");
        usage.record_typed(3, Some(600), today);
        usage.record_typed(2, Some(1_001), today);
        usage.record_typed(1, None, today);
        usage.record_typed(0, Some(100), today);
        let bucket = &usage.days["2026-10-14"];
        assert_eq!(bucket.typed_characters, 6);
        assert_eq!(bucket.typing_gaps, 3);
        assert_eq!(bucket.typing_milliseconds, 600);
    }

    #[test]
    fn summaries_have_a_bar_per_period_and_price_keystrokes() {
        let today = day("2026-10-14");
        let mut usage = UsageHistory::default();
        usage.record_accept(5, 27, true, "browser", "m", today);
        usage.record_shown("browser", "m", today);
        usage.record_accept(1, 4, false, "chat", "m", day("2026-08-02"));
        let week = usage.summary(UsageRange::Week, today);
        assert_eq!(week.bars.len(), 7);
        assert_eq!(week.total.suggestions.words, 5);
        assert_eq!(week.active_bars(), 1);
        assert_eq!(week.total.suggestions.keystrokes_saved(), 26);
        assert_eq!(week.time_saved_seconds(), 26.0 * 0.3);
        assert_eq!(week.word_ceiling(), 10);
        assert_eq!(usage.summary(UsageRange::Month, today).bars.len(), 30);
        let year = usage.summary(UsageRange::Year, today);
        assert_eq!(year.bars.len(), 12);
        assert_eq!(year.bars[0].start, day("2025-11-01"));
        assert_eq!(year.total.suggestions.words, 6);
        let all = usage.summary(UsageRange::AllTime, today);
        assert_eq!(all.bars.len(), 3);
        assert!(all.monthly);
        let empty = UsageHistory::default().summary(UsageRange::AllTime, today);
        assert_eq!(empty.bars.len(), 1);
    }

    #[test]
    fn typing_speed_comes_from_every_month() {
        let mut usage = UsageHistory::default();
        let today = day("2026-10-14");
        for _ in 0..4 {
            usage.record_typed(100, Some(1_000), day("2025-01-10"));
        }
        let summary = usage.summary(UsageRange::Week, today);
        assert_eq!(summary.milliseconds_per_keystroke, Some(10.0));
        assert_eq!(summary.words_per_minute(), Some(1_200));
    }

    #[test]
    fn rates_cap_used_at_shown() {
        let counts = UsageCounts {
            shown: 2,
            used: 5,
            ..Default::default()
        };
        assert_eq!(counts.acceptance_rate(), Some(1.0));
        assert_eq!(UsageCounts::default().acceptance_rate(), None);
    }

    #[test]
    fn insertion_checks_follow_the_field() {
        let check = InsertionCheck::new("Hi there", " you", "chat", 7, 1, 0);
        let live = |text: &'static str| Some((7u32, 1u64, text));
        assert_eq!(
            check.outcome(live("Hi there"), 10),
            InsertionOutcome::Pending
        );
        assert_eq!(
            check.outcome(live("Hi there you"), 10),
            InsertionOutcome::Confirmed
        );
        // Typing may already have gone on, and a browser's space may be NBSP.
        assert_eq!(
            check.outcome(live("Hi there\u{a0}you and"), 10),
            InsertionOutcome::Confirmed
        );
        assert_eq!(
            check.outcome(live("Hi there"), 1_500),
            InsertionOutcome::Unconfirmed
        );
        assert_eq!(
            check.outcome(live("Hi there yo"), 1_500),
            InsertionOutcome::Mismatched
        );
        assert_eq!(
            check.outcome(live("Other"), 1_500),
            InsertionOutcome::Unconfirmed
        );
        assert_eq!(check.outcome(None, 10), InsertionOutcome::Pending);
        assert_eq!(check.outcome(None, 1_500), InsertionOutcome::Unconfirmed);
        // Another field or app says nothing.
        assert_eq!(
            check.outcome(Some((8, 1, "Hi there you")), 1_500),
            InsertionOutcome::Unconfirmed
        );
        let mut both = check.clone();
        both.extend(" all", 100);
        assert_eq!(both.count, 2);
        assert_eq!(
            both.outcome(live("Hi there you all"), 110),
            InsertionOutcome::Confirmed
        );
    }

    #[test]
    fn the_report_holds_counts_and_timings() {
        let mut stats = CotypingStats::default();
        stats.record_generation(100);
        stats.record_accept(4, "chat");
        stats.record_shown(300, "chat");
        stats.record_insertion(InsertionOutcome::Confirmed, 1, "chat");
        let report = stats.report("LFM");
        assert!(report.contains("Suggested 1 · accepted 1 · generation median 100 ms, p95 100 ms"));
        assert!(report.contains("| Chat | 1 | 300 / 300 ms | 1 | 1 / 0 / 0 | 0 |"));
        assert!(
            CotypingStats::default()
                .report("m")
                .contains("No typing measured yet")
        );
    }
}
