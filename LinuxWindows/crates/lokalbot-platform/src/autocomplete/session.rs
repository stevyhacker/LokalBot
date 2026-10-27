//! The suggestion on screen and how the field's next state moves it, kept
//! pure (`CotypingSession`, `CotypingSessionReconciler.swift`,
//! `CotypingRehearsal` in `CotypingContinuationAcceptance.swift`).
//!
//! Typing the next characters of the ghost, or the app showing text an accept
//! inserted, shortens the ghost at once; anything else leaves it behind.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use unicode_segmentation::UnicodeSegmentation as _;

/// A visible suggestion for one field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GhostSession {
    pub field_id: u64,
    /// The text before the caret that `remaining` continues.
    pub anchor: String,
    /// What is still offered after the caret.
    pub remaining: String,
    /// Whether `anchor` is a clipped window of a longer text.
    pub anchor_truncated: bool,
    /// The text before the caret when the oldest accept the app has not
    /// shown yet was made. Reads from before it arrives are not a change
    /// (`shouldAwaitPostInsertionSync`).
    pub awaiting: Option<String>,
}

/// What a new state of the field does to the suggestion.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reconcile {
    /// Same text before the caret.
    Unchanged,
    /// The user typed, or the app showed, the start of the ghost.
    Advanced { typed: String },
    /// Everything offered is now in the field.
    Exhausted,
    /// The text left the suggestion behind.
    Stale,
}

impl GhostSession {
    pub fn new(field_id: u64, anchor: String, remaining: String, anchor_truncated: bool) -> Self {
        Self {
            field_id,
            anchor,
            remaining,
            anchor_truncated,
            awaiting: None,
        }
    }

    /// Moves the suggestion to `before`, the field's new text before the
    /// caret (`sessionReconciledByPublishedTyping`).
    pub fn reconcile(&mut self, before: &str, before_truncated: bool) -> Reconcile {
        if before == self.anchor {
            self.awaiting = None;
            return Reconcile::Unchanged;
        }
        // An accept the app has shown only part of, or none of, yet.
        if let Some(start) = &self.awaiting
            && self.anchor.starts_with(before)
            && before.starts_with(start.as_str())
        {
            return Reconcile::Unchanged;
        }
        let truncated = self.anchor_truncated || before_truncated;
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

    /// An accept took `chunk` (the start of `remaining`) and typed
    /// `insertion` after deleting `backward` user-perceived characters
    /// before the caret (an emoji's `:shortcode`). The ghost moves on before
    /// the app shows the text, so a quick second Tab takes the next chunk.
    /// Returns false when `chunk` is not the start.
    pub fn accept(&mut self, chunk: &str, insertion: &str, backward: usize) -> bool {
        if chunk.is_empty() || !self.remaining.starts_with(chunk) {
            return false;
        }
        if self.awaiting.is_none() {
            self.awaiting = Some(self.anchor.clone());
        }
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
        self.anchor.push_str(insertion);
        true
    }

    /// Stops waiting for an accept to arrive in the field: the next read
    /// that does not show it leaves the suggestion behind.
    pub fn stop_awaiting(&mut self) {
        self.awaiting = None;
    }

    pub fn is_exhausted(&self) -> bool {
        self.remaining.is_empty()
    }
}

/// The text typed after `anchor` to reach `before`. For clipped windows,
/// whose start moves as the text grows, the anchor's tail is found in
/// `before` instead (`hasCappedPrefixWindowOverlap`).
fn typed_since<'a>(anchor: &str, before: &'a str, truncated: bool) -> Option<&'a str> {
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
    let tail = &anchor[tail_start..];
    if tail.is_empty() {
        return None;
    }
    let at = before.rfind(tail)?;
    Some(&before[at + tail.len()..])
}

/// `text` without its first `count` user-perceived characters: the text
/// after the caret once an accept replaced the rest of a word.
pub fn drop_graphemes(text: &str, count: usize) -> String {
    let (_, forward) = replaced_bytes("", text, 0, count);
    text[forward..].to_string()
}

/// The bytes an accept replaces: the last `backward` user-perceived
/// characters of `before` and the first `forward` of `after`.
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

/// Contexts recently sent for one field, newest last, so a suggestion that
/// arrives after more typing can be fitted to the field's current text.
#[derive(Clone, Debug, Default)]
pub struct SentContexts {
    sent: VecDeque<(u64, String, Instant)>,
}

impl SentContexts {
    const KEEP: usize = 8;
    const MAX_AGE: Duration = Duration::from_secs(3);

    pub fn record(&mut self, field_id: u64, before: &str, now: Instant) {
        if self
            .sent
            .back()
            .is_some_and(|(id, text, _)| *id == field_id && text == before)
        {
            return;
        }
        self.sent.push_back((field_id, before.to_string(), now));
        while self.sent.len() > Self::KEEP {
            self.sent.pop_front();
        }
    }

    pub fn clear(&mut self) {
        self.sent.clear();
    }

    /// `suggestion` as it continues `latest`. A suggestion made for an
    /// earlier context that the user has since typed into starts with what
    /// was typed; that part is already in the field.
    pub fn fit<'a>(
        &self,
        field_id: u64,
        latest: &str,
        suggestion: &'a str,
        now: Instant,
    ) -> &'a str {
        for (id, older, at) in self.sent.iter().rev() {
            if *id != field_id || now.duration_since(*at) > Self::MAX_AGE || older == latest {
                continue;
            }
            let Some(typed) = latest.strip_prefix(older.as_str()) else {
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
        // Backspace or a caret move to earlier text.
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
        // A read from before the insert arrived, then a partial one: still
        // waiting for the app.
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow", false),
            Reconcile::Unchanged
        );
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow u", false),
            Reconcile::Unchanged
        );
        // The app then shows it all.
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow up", false),
            Reconcile::Unchanged
        );
        assert_eq!(ghost.awaiting, None);
        // Once shown, a step back is a real change.
        assert_eq!(
            ghost.reconcile("Thanks, I wanted to follow", false),
            Reconcile::Stale
        );
        assert!(!session().accept(" off", " off", 0));
        // The typed text may differ from the chunk (a space the field had).
        let mut spaced = GhostSession::new(1, "Hi ".into(), " there friend".into(), false);
        assert!(spaced.accept(" there", "there", 0));
        assert_eq!(spaced.anchor, "Hi there");
        assert_eq!(spaced.reconcile("Hi there", false), Reconcile::Unchanged);
        // An emoji replaces its shortcode.
        let mut emoji = GhostSession::new(2, "Launch :rock".into(), "🚀".into(), false);
        assert!(emoji.accept("🚀", "🚀", 5));
        assert_eq!(emoji.anchor, "Launch 🚀");
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
        // The window moved by one character as one was typed.
        let before = format!("{} ", &text[1001..]);
        assert_eq!(
            ghost.reconcile(&before, true),
            Reconcile::Advanced { typed: " ".into() }
        );
        assert_eq!(ghost.remaining, "more words");
    }

    #[test]
    fn late_suggestions_fit_the_text_typed_since() {
        let now = Instant::now();
        let mut sent = SentContexts::default();
        sent.record(3, "Hello", now);
        sent.record(3, "Hello ", now);
        // Made for "Hello" and arriving after the space: the space is typed.
        assert_eq!(sent.fit(3, "Hello ", " world", now), "world");
        // Made for "Hello ": shown as is.
        assert_eq!(sent.fit(3, "Hello ", "world", now), "world");
        // Another field's history is not used.
        assert_eq!(sent.fit(4, "Hello ", " world", now), " world");
        // Old entries are forgotten.
        let later = now + Duration::from_secs(10);
        assert_eq!(sent.fit(3, "Hello ", " world", later), " world");
    }
}
