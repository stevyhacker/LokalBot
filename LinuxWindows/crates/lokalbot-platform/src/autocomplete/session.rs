use std::collections::VecDeque;
use std::time::{Duration, Instant};

use unicode_segmentation::UnicodeSegmentation as _;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GhostSession {
    pub field_id: u64,
    pub anchor: String,
    pub remaining: String,
    pub anchor_truncated: bool,
    pub awaiting: Option<String>,
    pub awaiting_deleted: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reconcile {
    Unchanged,
    Advanced { typed: String },
    Exhausted,
    Stale,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertProgress {
    InFlight,
    Settled,
    Diverged,
}

impl GhostSession {
    pub fn new(field_id: u64, anchor: String, remaining: String, anchor_truncated: bool) -> Self {
        Self {
            field_id,
            anchor,
            remaining,
            anchor_truncated,
            awaiting: None,
            awaiting_deleted: None,
        }
    }

    pub fn reconcile(&mut self, before: &str, before_truncated: bool) -> Reconcile {
        let truncated = self.anchor_truncated || before_truncated;
        if before == self.anchor {
            self.awaiting = None;
            self.awaiting_deleted = None;
            self.anchor_truncated = before_truncated;
            return Reconcile::Unchanged;
        }
        if let Some(start) = self.awaiting.clone() {
            let (Some(expected), Some(actual)) = (
                typed_since(&start, &self.anchor, truncated),
                typed_since(&start, before, truncated),
            ) else {
                return Reconcile::Stale;
            };
            if actual == expected {
                self.awaiting = None;
                self.awaiting_deleted = None;
                self.anchor = before.to_string();
                self.anchor_truncated = before_truncated;
                return Reconcile::Unchanged;
            }
            if !actual.is_empty()
                && self
                    .awaiting_deleted
                    .as_deref()
                    .is_some_and(|deleted| deleted.starts_with(actual))
            {
                return Reconcile::Unchanged;
            }
            if expected.starts_with(actual) {
                self.awaiting_deleted = None;
                return Reconcile::Unchanged;
            }
            let Some(extra) = actual.strip_prefix(expected) else {
                return Reconcile::Stale;
            };
            if extra.chars().any(char::is_control) || !self.remaining.starts_with(extra) {
                return Reconcile::Stale;
            }
            let typed = extra.to_string();
            self.awaiting = None;
            self.awaiting_deleted = None;
            self.remaining = self.remaining[typed.len()..].to_string();
            self.anchor = before.to_string();
            self.anchor_truncated = before_truncated;
            return if self.remaining.is_empty() {
                Reconcile::Exhausted
            } else {
                Reconcile::Advanced { typed }
            };
        }
        let Some(typed) = typed_since(&self.anchor, before, truncated) else {
            return Reconcile::Stale;
        };
        if typed.is_empty() {
            self.anchor = before.to_string();
            self.anchor_truncated = before_truncated;
            return Reconcile::Unchanged;
        }
        if typed.chars().any(char::is_control) || !self.remaining.starts_with(typed) {
            return Reconcile::Stale;
        }
        let typed = typed.to_string();
        self.remaining = self.remaining[typed.len()..].to_string();
        self.anchor = before.to_string();
        self.anchor_truncated = before_truncated;
        if self.remaining.is_empty() {
            Reconcile::Exhausted
        } else {
            Reconcile::Advanced { typed }
        }
    }

    pub fn accept(&mut self, chunk: &str, insertion: &str, backward: usize) -> bool {
        if chunk.is_empty() || !self.remaining.starts_with(chunk) {
            return false;
        }
        let original = self.anchor.clone();
        self.remaining = self.remaining[chunk.len()..].to_string();
        if backward > 0 {
            let keep = self
                .anchor
                .grapheme_indices(true)
                .rev()
                .nth(backward - 1)
                .map_or(0, |(index, _)| index);
            self.anchor.truncate(keep);
        }
        let floor = if backward > 0 {
            &self.anchor
        } else {
            &original
        };
        match &mut self.awaiting {
            None => {
                self.awaiting = Some(floor.to_string());
                self.awaiting_deleted = (backward > 0)
                    .then(|| original.strip_prefix(floor).map(str::to_string))
                    .flatten()
                    .filter(|s| !s.is_empty());
            }
            Some(start)
                if !floor.starts_with(start.as_str())
                    && !(self.anchor_truncated && typed_since(start, floor, true).is_some()) =>
            {
                let common = start
                    .char_indices()
                    .zip(floor.chars())
                    .take_while(|((_, a), b)| *a == *b)
                    .last()
                    .map_or(0, |((idx, ch), _)| idx + ch.len_utf8());
                start.truncate(common);
                self.awaiting_deleted = None;
            }
            Some(_) => {}
        }
        self.anchor.push_str(insertion);
        true
    }

    pub fn stop_awaiting(&mut self) {
        self.awaiting = None;
        self.awaiting_deleted = None;
    }

    pub fn is_exhausted(&self) -> bool {
        self.remaining.is_empty()
    }
}

pub fn progression_between(
    floor: &str,
    target: &str,
    before: &str,
    truncated: bool,
) -> InsertProgress {
    let (Some(expected), Some(actual)) = (
        typed_since(floor, target, truncated),
        typed_since(floor, before, truncated),
    ) else {
        return InsertProgress::Diverged;
    };
    if actual == expected {
        InsertProgress::Settled
    } else if expected.starts_with(actual) {
        InsertProgress::InFlight
    } else {
        InsertProgress::Diverged
    }
}

pub fn typed_since<'a>(anchor: &str, before: &'a str, truncated: bool) -> Option<&'a str> {
    if let Some(rest) = before.strip_prefix(anchor) {
        return Some(rest);
    }
    if !truncated {
        return None;
    }
    let tail_start = anchor
        .char_indices()
        .rev()
        .nth(255)
        .map_or(0, |(index, _)| index);
    (1..=tail_start)
        .filter(|shift| anchor.is_char_boundary(*shift))
        .find_map(|shift| before.strip_prefix(&anchor[shift..]))
}

pub fn drop_graphemes(text: &str, count: usize) -> String {
    let (_, forward) = replaced_bytes("", text, 0, count);
    text[forward..].to_string()
}

pub fn replaced_bytes(
    before: &str,
    after: &str,
    backward: usize,
    forward: usize,
) -> (usize, usize) {
    let back = match backward {
        0 => 0,
        n => before
            .grapheme_indices(true)
            .rev()
            .nth(n - 1)
            .map_or(before.len(), |(index, _)| before.len() - index),
    };
    let ahead = match forward {
        0 => 0,
        n => after
            .grapheme_indices(true)
            .nth(n)
            .map_or(after.len(), |(index, _)| index),
    };
    (back, ahead)
}

pub fn inline_text(text: &str, whole: bool) -> Option<String> {
    const LIMIT: usize = 3900;
    let line = text.split('\n').next().unwrap_or("").trim_end_matches('\r');
    let mut end = line.len().min(LIMIT);
    while !line.is_char_boundary(end) {
        end -= 1;
    }
    let shown = &line[..end];
    if shown.is_empty() || (whole && shown.len() < text.len()) {
        return None;
    }
    Some(shown.to_string())
}

#[derive(Clone, Debug, Default)]
pub struct SentContexts {
    sent: VecDeque<(u64, String, bool, Instant)>,
}

impl SentContexts {
    const KEEP: usize = 8;
    const MAX_AGE: Duration = Duration::from_secs(3);

    pub fn record(&mut self, field_id: u64, before: &str, truncated: bool, now: Instant) {
        if self
            .sent
            .back()
            .is_some_and(|(id, text, t, _)| *id == field_id && text == before && *t == truncated)
        {
            return;
        }
        self.sent
            .push_back((field_id, before.to_string(), truncated, now));
        while self.sent.len() > Self::KEEP {
            self.sent.pop_front();
        }
    }

    pub fn clear(&mut self) {
        self.sent.clear();
    }

    pub fn fit<'a>(
        &self,
        field_id: u64,
        latest: &str,
        latest_truncated: bool,
        suggestion: &'a str,
        now: Instant,
    ) -> &'a str {
        for (id, older, older_truncated, at) in self.sent.iter().rev() {
            if *id != field_id || now.duration_since(*at) > Self::MAX_AGE || older == latest {
                continue;
            }
            let truncated = *older_truncated || latest_truncated;
            let Some(typed) = typed_since(older.as_str(), latest, truncated) else {
                continue;
            };
            if !typed.is_empty() && suggestion.len() > typed.len() && suggestion.starts_with(typed)
            {
                return &suggestion[typed.len()..];
            }
        }
        suggestion
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> GhostSession {
        GhostSession::new(
            7,
            "Thanks, I wanted to follow".into(),
            " up on the plan".into(),
            false,
        )
    }

    #[test]
    fn typing_the_ghost_advances_it() {
        let mut ghost = session();
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow", false),
            Reconcile::Unchanged
        );
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow u", false),
            Reconcile::Advanced { typed: " u".into() }
        );
        assert_eq!(ghost.remaining, "p on the plan");
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow up on the plan", false),
            Reconcile::Exhausted
        );
    }

    #[test]
    fn other_typing_and_caret_moves_leave_it_behind() {
        let mut ghost = session();
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow x", false),
            Reconcile::Stale
        );
        let mut ghost = session();
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follo", false),
            Reconcile::Stale
        );
        let mut ghost = session();
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow\n", false),
            Reconcile::Stale
        );
    }

    #[test]
    fn accepting_moves_the_anchor_before_the_app_shows_it() {
        let mut ghost = session();
        assert!(ghost.accept(" up", " up", 0));
        assert_eq!(ghost.remaining, " on the plan");
        assert_eq!(ghost.anchor, "Thanks, I wanted to follow up");
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow", false),
            Reconcile::Unchanged
        );
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow u", false),
            Reconcile::Unchanged
        );
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow up", false),
            Reconcile::Unchanged
        );
        assert_eq!(ghost.awaiting, None);
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow", false),
            Reconcile::Stale
        );
        assert!(!session().accept(" off", " off", 0));
        let mut spaced = GhostSession::new(1, "Hi ".into(), " there friend".into(), false);
        assert!(spaced.accept(" there", "there", 0));
        assert_eq!(spaced.anchor, "Hi there");
        assert_eq!(spaced.reconcile("Hi there", false), Reconcile::Unchanged);
        let mut emoji = GhostSession::new(2, "Launch :rock".into(), "🚀".into(), false);
        assert!(emoji.accept("🚀", "🚀", 5));
        assert_eq!(emoji.anchor, "Launch 🚀");
        assert_eq!(emoji.reconcile("Launch ", false), Reconcile::Unchanged);
        assert_eq!(emoji.reconcile("Launch 🚀", false), Reconcile::Unchanged);
        assert!(emoji.is_exhausted());
        assert_eq!(drop_graphemes("ing now", 3), " now");
        assert_eq!(drop_graphemes("e\u{301}x", 1), "x");
        assert_eq!(drop_graphemes("ab", 5), "");
        assert_eq!(replaced_bytes("Launch :rock", "", 5, 0), (5, 0));
        assert_eq!(replaced_bytes("x", "ing now", 3, 3), (1, 3));
    }

    #[test]
    fn clipped_windows_still_follow_typing() {
        let text = "x".repeat(5000);
        let anchor = text[1000..].to_string();
        let mut ghost = GhostSession::new(1, anchor, " more words".into(), true);
        let before = format!("{} ", &text[1001..]);
        assert_eq!(
            ghost.reconcile(&before, true),
            Reconcile::Advanced { typed: " ".into() }
        );
        assert_eq!(ghost.remaining, "more words");
    }

    #[test]
    fn clipped_windows_keep_multi_word_accept_bursts_synced() {
        let base: String = (0..1000).map(|i| format!("w{i:03} ")).collect();
        let window_start = base.len() - 4090;
        let floor = base[window_start..].to_string();
        let mut ghost = GhostSession::new(1, floor.clone(), " one two three".into(), true);
        assert!(ghost.accept(" one", " one", 0));
        assert!(ghost.accept(" two", " two", 0));
        assert_eq!(ghost.remaining, " three");

        let partial = format!("{} on", &floor[3..]);
        assert_eq!(ghost.reconcile(&partial, true), Reconcile::Unchanged);
        assert!(ghost.awaiting.is_some());
        assert_eq!(
            progression_between(&floor, &ghost.anchor, &partial, true),
            InsertProgress::InFlight
        );

        let mid_word = format!("{} one", &floor[4..]);
        assert_eq!(ghost.reconcile(&mid_word, true), Reconcile::Unchanged);
        assert!(ghost.awaiting.is_some());

        let settled = format!("{} one two", &floor[8..]);
        assert_eq!(
            progression_between(&floor, &ghost.anchor, &settled, true),
            InsertProgress::Settled
        );
        assert_eq!(ghost.reconcile(&settled, true), Reconcile::Unchanged);
        assert_eq!(ghost.awaiting, None);
        assert_eq!(ghost.anchor, settled);

        let walked = format!("{} one two ", &floor[9..]);
        assert_eq!(
            ghost.reconcile(&walked, true),
            Reconcile::Advanced { typed: " ".into() }
        );
        assert_eq!(ghost.remaining, "three");
    }

    #[test]
    fn inline_text_is_one_line_and_whole_suggestions_stay_whole() {
        assert_eq!(
            inline_text(" up on it", false).as_deref(),
            Some(" up on it")
        );
        assert_eq!(
            inline_text(" first\nsecond", false).as_deref(),
            Some(" first")
        );
        assert_eq!(inline_text(" first\nsecond", true), None);
        assert_eq!(inline_text("🚀", true).as_deref(), Some("🚀"));
        assert_eq!(inline_text("\nsecond", false), None);
        assert_eq!(inline_text("", false), None);
        let long = "é".repeat(4000);
        let shown = inline_text(&long, false).unwrap();
        assert!(shown.len() <= 3900);
        assert_eq!(inline_text(&long, true), None);
    }

    #[test]
    fn late_suggestions_fit_the_text_typed_since() {
        let now = Instant::now();
        let mut sent = SentContexts::default();
        sent.record(3, "Hello", false, now);
        sent.record(3, "Hello ", false, now);
        assert_eq!(sent.fit(3, "Hello ", false, " world", now), "world");
        assert_eq!(sent.fit(3, "Hello ", false, "world", now), "world");
        assert_eq!(sent.fit(4, "Hello ", false, " world", now), " world");
        let later = now + Duration::from_secs(10);
        assert_eq!(sent.fit(3, "Hello ", false, " world", later), " world");

        let long_base = format!("A{} tail", "x".repeat(1_200));
        let edited_start = format!("B{} tail up", "x".repeat(1_200));
        sent.record(5, &long_base, false, now);
        assert_eq!(
            sent.fit(5, &edited_start, false, " up next", now),
            " up next"
        );
        let repeated_anchor = format!("A{}", "x".repeat(1_023));
        let repeated_shifted = "x".repeat(1_024);
        assert_eq!(
            typed_since(&repeated_anchor, &repeated_shifted, true),
            Some("x")
        );
    }

    #[test]
    fn replacement_stays_pending_through_deletion_phase() {
        let mut ghost = GhostSession::new(7, "Launch :rock".into(), "🚀".into(), false);
        assert!(ghost.accept("🚀", "🚀", 5));
        assert_eq!(ghost.reconcile("Launch :rock", false), Reconcile::Unchanged);
        assert_eq!(ghost.reconcile("Launch :roc", false), Reconcile::Unchanged);
        assert_eq!(ghost.reconcile("Launch ", false), Reconcile::Unchanged);
        assert_eq!(ghost.reconcile("Launch 🚀", false), Reconcile::Unchanged);
        assert!(ghost.awaiting.is_none());
    }
}
