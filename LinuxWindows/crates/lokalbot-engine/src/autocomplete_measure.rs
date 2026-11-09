//! Local measurements of how autocomplete behaves while typing in other apps
//! (`CotypingCoordinator+Measurement.swift`). Counts and timings only.
//!
//! The Mac watches keys. Nothing here taps the keyboard, so typing is worked
//! out from reads of the field: what was added since the last read, less
//! anything an accept typed. Reads can coalesce keys, so these counts and the
//! gaps between keys are approximate; the UI words them that way.

use std::time::{Duration, Instant};

use lokalbot_core::cotyping_stats::{
    CotypingStats, INSERTION_TIMEOUT_MS, InsertionCheck, InsertionOutcome, UsageHistory, local_day,
};

/// A deletion this soon after an accept counts as correcting it.
const CORRECTION_WINDOW: Duration = Duration::from_millis(5_000);
/// Longer waits are a suggestion restored later, not typing latency.
const MAX_MEASURED_VISIBLE: Duration = Duration::from_millis(10_000);

struct Shown {
    surface: String,
    model: String,
    used: bool,
}

struct AcceptAwaiting {
    surface: String,
    model: String,
    at: Instant,
    /// The text before the caret once the accept is in the field.
    expected: String,
    /// The field has shown the accept, so a deletion now takes it back.
    shown: bool,
}

/// What one newer read of a field did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Change {
    Typed,
    Deleted,
    CaretMoved,
    Other,
}

/// The counters and what they are waiting to hear about.
pub(crate) struct Measures {
    pub stats: CotypingStats,
    pub usage: UsageHistory,
    start: Instant,
    revision: u64,
    saved_revision: u64,
    usage_revision: u64,
    saved_usage_revision: u64,
    /// The field read that asked for the next suggestion.
    pending_keystroke: Option<Instant>,
    shown: Option<Shown>,
    last_typed: Option<Instant>,
    check: Option<InsertionCheck>,
    awaiting: Option<AcceptAwaiting>,
    /// Text accepts typed that no read has shown yet: not the user's typing.
    pending_inserted: String,
}

impl Measures {
    pub fn new(stats: CotypingStats, usage: UsageHistory) -> Self {
        Self {
            stats,
            usage,
            start: Instant::now(),
            revision: 0,
            saved_revision: 0,
            usage_revision: 0,
            saved_usage_revision: 0,
            pending_keystroke: None,
            shown: None,
            last_typed: None,
            check: None,
            awaiting: None,
            pending_inserted: String::new(),
        }
    }

    fn today() -> chrono::NaiveDate {
        local_day(chrono::Utc::now())
    }

    fn ms(&self, at: Instant) -> i64 {
        at.saturating_duration_since(self.start).as_millis() as i64
    }

    fn stats_changed(&mut self) {
        self.revision += 1;
    }

    fn usage_changed(&mut self) {
        self.usage_revision += 1;
    }

    /// A newer read of the same field, as (before, after) the caret. `counts`
    /// is false in LokalBot's own practice editor.
    pub fn note_read(
        &mut self,
        previous: (&str, &str),
        live: (&str, &str),
        pid: u32,
        field_id: u64,
        counts: bool,
        now: Instant,
    ) {
        let before = live.0;
        let (typed, change) = classify(previous, live);
        // What an accept typed is not the user's typing.
        let typed = self.strip_inserted(typed);
        if let Some(awaiting) = self.awaiting.as_mut()
            && before.starts_with(&awaiting.expected)
        {
            awaiting.shown = true;
        }
        match change {
            Change::Typed => {
                if !typed.is_empty() {
                    // The first key after an accept shows it was kept.
                    self.awaiting = None;
                    if counts {
                        self.note_typing(&typed, now);
                    }
                }
            }
            Change::Deleted => {
                self.last_typed = None;
                self.pending_inserted.clear();
                self.note_deletion(before, now);
            }
            Change::CaretMoved | Change::Other => {
                self.last_typed = None;
                self.awaiting = None;
                self.pending_inserted.clear();
            }
        }
        self.resolve(Some((pid, field_id, before)), now, false);
        // A key that takes text back or moves the caret changes what is before
        // the caret, so an accept still unread can no longer be read back.
        if matches!(change, Change::Deleted | Change::CaretMoved) {
            self.close(InsertionOutcome::Unconfirmed);
        }
    }

    /// Removes the start of `typed` an accept is known to have typed.
    fn strip_inserted(&mut self, typed: &str) -> String {
        if self.pending_inserted.is_empty() {
            return typed.to_string();
        }
        let (mut matched, mut bytes) = (0, 0);
        for (sent, shown) in self.pending_inserted.chars().zip(typed.chars()) {
            // Browsers publish a trailing space as a non-breaking space.
            if sent != shown && !(sent == ' ' && shown == '\u{a0}') {
                break;
            }
            matched += 1;
            bytes += shown.len_utf8();
        }
        self.pending_inserted = self.pending_inserted.chars().skip(matched).collect();
        typed[bytes..].to_string()
    }

    fn note_deletion(&mut self, before: &str, now: Instant) {
        let Some(awaiting) = self.awaiting.as_ref() else {
            return;
        };
        // A partly shown accept is still arriving, not being taken back.
        let arriving = !awaiting.shown && awaiting.expected.starts_with(before);
        if arriving {
            return;
        }
        let Some(awaiting) = self.awaiting.take() else {
            return;
        };
        if now.saturating_duration_since(awaiting.at) > CORRECTION_WINDOW {
            return;
        }
        self.stats.record_correction(&awaiting.surface);
        self.usage
            .record_taken_back(&awaiting.surface, &awaiting.model, Self::today());
        self.stats_changed();
        self.usage_changed();
    }

    fn note_typing(&mut self, typed: &str, now: Instant) {
        let elapsed = self
            .last_typed
            .map(|at| now.saturating_duration_since(at).as_millis() as i64);
        self.last_typed = Some(now);
        self.usage
            .record_typed(typed.chars().count() as i64, elapsed, Self::today());
        self.usage_changed();
    }

    /// A text change asks for a suggestion: the wait starts here.
    pub fn note_asked(&mut self, now: Instant) {
        self.pending_keystroke = Some(now);
    }

    /// A generation came back and was checked against the field.
    pub fn note_generation(&mut self, latency_ms: i64) {
        self.stats.record_generation(latency_ms);
        self.stats_changed();
    }

    pub fn note_error(&mut self) {
        self.stats.record_error();
        self.stats_changed();
    }

    /// A continuation became visible.
    pub fn note_shown(&mut self, surface: &str, model: &str, now: Instant) {
        self.shown = Some(Shown {
            surface: surface.to_string(),
            model: model.to_string(),
            used: false,
        });
        self.usage.record_shown(surface, model, Self::today());
        self.usage_changed();
        let Some(asked) = self.pending_keystroke.take() else {
            return;
        };
        let waited = now.saturating_duration_since(asked);
        if waited <= MAX_MEASURED_VISIBLE {
            self.stats.record_shown(waited.as_millis() as i64, surface);
            self.stats_changed();
        }
    }

    /// One accept press typed `inserted` into the field.
    #[allow(clippy::too_many_arguments)]
    pub fn note_accept(
        &mut self,
        surface: &str,
        model: &str,
        before: &str,
        inserted: &str,
        characters: i64,
        words: i64,
        pid: u32,
        field_id: u64,
        now: Instant,
    ) {
        self.stats.record_accept(characters, surface);
        self.stats_changed();
        // Without a shown suggestion nothing is marked used.
        let (shown_surface, shown_model, first) = match self.shown.as_mut() {
            Some(shown) => {
                let first = !shown.used;
                shown.used = true;
                (shown.surface.clone(), shown.model.clone(), first)
            }
            None => (surface.to_string(), model.to_string(), false),
        };
        self.usage.record_accept(
            words,
            characters,
            first,
            &shown_surface,
            &shown_model,
            Self::today(),
        );
        self.usage_changed();
        self.last_typed = None;
        self.awaiting = Some(AcceptAwaiting {
            surface: shown_surface,
            model: shown_model,
            at: now,
            expected: format!("{before}{inserted}"),
            shown: false,
        });
        if inserted.is_empty() {
            return;
        }
        self.pending_inserted.push_str(inserted);
        let at = self.ms(now);
        self.resolve(Some((pid, field_id, before)), now, false);
        match self.check.as_mut() {
            // The app has not shown the previous accept yet: check both together.
            Some(check) => check.extend(inserted, at),
            None => {
                self.check = Some(InsertionCheck::new(
                    before, inserted, surface, pid, field_id, at,
                ))
            }
        }
    }

    /// Accepting a correction, which is not a shown or accepted suggestion.
    pub fn note_typo_fixed(&mut self) {
        self.usage.record_typo_fixed(Self::today());
        self.usage_changed();
    }

    /// Focus left the field: an accept not read back by now never will be.
    pub fn note_left_field(&mut self, now: Instant) {
        self.pending_keystroke = None;
        self.last_typed = None;
        self.awaiting = None;
        self.pending_inserted.clear();
        self.resolve(None, now, false);
    }

    /// When an unread accept stops being waited for. An app that ignores an
    /// insertion publishes nothing, and typing may stop there.
    pub fn check_due(&self) -> Option<Instant> {
        let check = self.check.as_ref()?;
        Some(self.start + Duration::from_millis((check.started_ms + INSERTION_TIMEOUT_MS) as u64))
    }

    pub fn resolve(&mut self, live: Option<(u32, u64, &str)>, now: Instant, expired: bool) {
        let Some(check) = self.check.as_ref() else {
            return;
        };
        let at = if expired {
            self.ms(now).max(check.started_ms + INSERTION_TIMEOUT_MS)
        } else {
            self.ms(now)
        };
        let outcome = check.outcome(live, at);
        if outcome != InsertionOutcome::Pending {
            self.close(outcome);
        }
    }

    fn close(&mut self, outcome: InsertionOutcome) {
        if let Some(check) = self.check.take() {
            self.stats
                .record_insertion(outcome, check.count, &check.surface);
            self.stats_changed();
        }
    }

    pub fn clear_usage(&mut self) {
        self.usage = UsageHistory::default();
        self.usage_revision += 1;
        self.saved_usage_revision = self.usage_revision;
    }

    pub fn reset_stats(&mut self) {
        self.stats = CotypingStats::default();
        self.revision += 1;
        self.saved_revision = self.revision;
    }

    /// What to write now: the counters, and the usage history only when it
    /// changed. `None` when nothing did.
    pub fn take_unsaved(&mut self) -> Option<(CotypingStats, Option<UsageHistory>)> {
        if self.revision == self.saved_revision && self.usage_revision == self.saved_usage_revision
        {
            return None;
        }
        self.saved_revision = self.revision;
        let usage = (self.usage_revision != self.saved_usage_revision).then(|| self.usage.clone());
        self.saved_usage_revision = self.usage_revision;
        Some((self.stats.clone(), usage))
    }

    /// `resetMeasurementState`: autocomplete stopped.
    pub fn reset_pending(&mut self) {
        self.pending_keystroke = None;
        self.shown = None;
        self.last_typed = None;
        self.check = None;
        self.awaiting = None;
        self.pending_inserted.clear();
    }
}

/// What changed between two reads of a field, and any text added.
fn classify<'a>(previous: (&str, &str), live: (&'a str, &str)) -> (&'a str, Change) {
    let (old_before, old_after) = previous;
    let (before, after) = live;
    if old_before.len() + old_after.len() == before.len() + after.len()
        && old_before != before
        && format!("{old_before}{old_after}") == format!("{before}{after}")
    {
        return ("", Change::CaretMoved);
    }
    if after == old_after
        && let Some(typed) = lokalbot_ai::autocomplete::session::typed_since(old_before, before)
    {
        return (typed, Change::Typed);
    }
    if after == old_after && old_before.starts_with(before) {
        return ("", Change::Deleted);
    }
    ("", Change::Other)
}

#[cfg(test)]
mod tests {
    use super::*;

    const AT: u64 = 1;

    fn measures() -> Measures {
        Measures::new(CotypingStats::default(), UsageHistory::default())
    }

    fn read(m: &mut Measures, old: &str, new: &str, at: Instant) {
        m.note_read((old, ""), (new, ""), 7, AT, true, at);
    }

    fn today(m: &Measures) -> lokalbot_core::cotyping_stats::UsageBucket {
        m.usage.days.values().next().cloned().unwrap_or_default()
    }

    #[test]
    fn typing_is_what_reads_added_with_gaps_only_for_quick_reads() {
        let mut m = measures();
        let start = Instant::now();
        read(&mut m, "H", "Hi", start);
        read(&mut m, "Hi", "Hi th", start + Duration::from_millis(400));
        read(
            &mut m,
            "Hi th",
            "Hi the",
            start + Duration::from_millis(2_000),
        );
        let bucket = today(&m);
        assert_eq!(bucket.typed_characters, 1 + 3 + 1);
        assert_eq!(bucket.typing_gaps, 3);
        assert_eq!(bucket.typing_milliseconds, 400);
    }

    #[test]
    fn deleting_and_moving_break_the_run_and_practice_does_not_count() {
        let mut m = measures();
        let start = Instant::now();
        read(&mut m, "H", "Hi", start);
        read(&mut m, "Hi", "H", start + Duration::from_millis(100));
        read(&mut m, "H", "Ho", start + Duration::from_millis(200));
        // No gap: the deletion broke the run.
        assert_eq!(today(&m).typing_gaps, 0);
        assert_eq!(today(&m).typed_characters, 2);
        let mut own = measures();
        own.note_read(("H", ""), ("Hi", ""), 7, AT, false, start);
        assert!(own.usage.is_empty());
    }

    #[test]
    fn an_accept_is_not_typing_and_arrives_confirmed() {
        let mut m = measures();
        let start = Instant::now();
        m.note_shown("chat", "m", start);
        m.note_accept("chat", "m", "Hi", " there", 6, 1, 7, AT, start);
        assert_eq!(m.stats.accepts, 1);
        assert_eq!(today(&m).suggestions.used, 1);
        assert_eq!(today(&m).suggestions.words, 1);
        // The field shows it, then the user types on.
        read(&mut m, "Hi", "Hi there", start + Duration::from_millis(50));
        assert_eq!(today(&m).typed_characters, 0);
        assert_eq!(m.stats.live["chat"].insertions_confirmed, 1);
        read(
            &mut m,
            "Hi there",
            "Hi there!",
            start + Duration::from_millis(100),
        );
        assert_eq!(today(&m).typed_characters, 1);
        // A second accept from the same suggestion is not a second use.
        m.note_accept("chat", "m", "Hi there!", " Bye", 4, 1, 7, AT, start);
        assert_eq!(today(&m).suggestions.used, 1);
        assert_eq!(today(&m).suggestions.accepts, 2);
    }

    #[test]
    fn a_partly_shown_accept_waits_and_a_deletion_afterwards_takes_it_back() {
        let mut m = measures();
        let start = Instant::now();
        m.note_shown("chat", "m", start);
        m.note_accept("chat", "m", "Hi", " there", 6, 1, 7, AT, start);
        // Part of the accept has arrived: no change of mind yet.
        read(&mut m, "Hi", "Hi th", start + Duration::from_millis(10));
        assert_eq!(today(&m).suggestions.taken_back, 0);
        assert_eq!(today(&m).typed_characters, 0);
        read(
            &mut m,
            "Hi th",
            "Hi there",
            start + Duration::from_millis(20),
        );
        read(&mut m, "Hi there", "Hi", start + Duration::from_millis(30));
        assert_eq!(today(&m).suggestions.taken_back, 1);
        assert_eq!(m.stats.live["chat"].accepts_corrected, 1);
    }

    #[test]
    fn a_deletion_long_after_or_after_another_key_is_not_taken_back() {
        let mut m = measures();
        let start = Instant::now();
        m.note_accept("chat", "m", "Hi", " there", 6, 1, 7, AT, start);
        read(&mut m, "Hi", "Hi there", start);
        read(
            &mut m,
            "Hi there",
            "Hi",
            start + CORRECTION_WINDOW + Duration::from_millis(1),
        );
        assert_eq!(today(&m).suggestions.taken_back, 0);

        let mut typed_on = measures();
        typed_on.note_accept("chat", "m", "Hi", " there", 6, 1, 7, AT, start);
        read(&mut typed_on, "Hi", "Hi there", start);
        read(&mut typed_on, "Hi there", "Hi there!", start);
        read(&mut typed_on, "Hi there!", "Hi there", start);
        assert_eq!(today(&typed_on).suggestions.taken_back, 0);
    }

    #[test]
    fn an_accept_never_shown_expires_unconfirmed() {
        let mut m = measures();
        let start = Instant::now();
        m.note_accept("chat", "m", "Hi", " there", 6, 1, 7, AT, start);
        assert!(m.check_due().is_some());
        m.resolve(Some((7, AT, "Hi")), start, true);
        assert_eq!(m.stats.live["chat"].insertions_unconfirmed, 1);
        assert_eq!(m.check_due(), None);
    }

    #[test]
    fn the_wait_is_measured_once_per_request_and_old_waits_are_left_out() {
        let mut m = measures();
        let start = Instant::now();
        m.note_asked(start);
        m.note_shown("chat", "m", start + Duration::from_millis(300));
        assert_eq!(m.stats.live["chat"].visible_latencies_ms, [300]);
        m.note_shown("chat", "m", start + Duration::from_millis(400));
        assert_eq!(m.stats.live["chat"].shown, 1);
        assert_eq!(today(&m).suggestions.shown, 2);
        m.note_asked(start);
        m.note_shown("chat", "m", start + MAX_MEASURED_VISIBLE * 2);
        assert_eq!(m.stats.live["chat"].shown, 1);
    }

    #[test]
    fn saving_writes_usage_only_when_it_changed() {
        let mut m = measures();
        assert!(m.take_unsaved().is_none());
        m.note_generation(10);
        let (stats, usage) = m.take_unsaved().unwrap();
        assert_eq!(stats.generations, 1);
        assert!(usage.is_none());
        assert!(m.take_unsaved().is_none());
        m.note_typo_fixed();
        assert!(m.take_unsaved().unwrap().1.is_some());
        m.clear_usage();
        m.reset_stats();
        assert!(m.take_unsaved().is_none());
        assert!(m.usage.is_empty());
    }
}
