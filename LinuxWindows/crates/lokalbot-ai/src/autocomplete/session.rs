//! A suggestion on screen and what happens to it as the user types
//! (`CotypingSession`, `CotypingSessionReconciler`,
//! `CotypingSuggestionExtension`, `CotypingSuggestionAnchorCache`).

use std::time::{Duration, Instant};

use super::stop::ends_sentence;
use super::text::is_control;

/// What a suggestion does when accepted (`CotypingSuggestionKind`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SuggestionKind {
    /// Continues the text (the normal case).
    Continuation,
    /// Replaces the `:shortcode` before the caret with its glyph.
    Emoji,
}

/// An active suggestion: the field text it was made for, the suggestion,
/// and how much of it is accepted or typed through.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Session {
    /// Text before the caret when the suggestion was made.
    pub before: String,
    /// Text after the caret then; any change to it ends the suggestion.
    pub after: String,
    pub full_text: String,
    /// Bytes of `full_text` accepted or typed through.
    pub consumed: usize,
    pub kind: SuggestionKind,
    /// The model's output was cut by the length limit, so there is more to
    /// say; only such a suggestion is topped up.
    pub open_ended: bool,
}

impl Session {
    pub fn new(before: &str, after: &str, full_text: &str, kind: SuggestionKind) -> Self {
        Self {
            before: before.to_string(),
            after: after.to_string(),
            full_text: full_text.to_string(),
            consumed: 0,
            kind,
            open_ended: false,
        }
    }

    pub fn accepted(&self) -> &str {
        &self.full_text[..self.consumed]
    }

    pub fn remaining(&self) -> &str {
        &self.full_text[self.consumed..]
    }

    pub fn is_exhausted(&self) -> bool {
        self.consumed >= self.full_text.len()
    }

    /// The text before the caret once everything accepted is in the field.
    pub fn expected_before(&self) -> String {
        format!("{}{}", self.before, self.accepted())
    }

    pub fn advanced(&self, bytes: usize) -> Self {
        let mut next = self.clone();
        next.consumed = (self.consumed + bytes).min(self.full_text.len());
        while !next.full_text.is_char_boundary(next.consumed) {
            next.consumed += 1;
        }
        next
    }

    /// `sessionAdvancedByTypedCharacters`: typing the suggestion's next
    /// characters walks through it.
    pub fn advanced_by_typing(&self, typed: &str) -> Option<Self> {
        if self.kind != SuggestionKind::Continuation
            || typed.is_empty()
            || typed.chars().any(is_control)
            || !self.remaining().starts_with(typed)
        {
            return None;
        }
        Some(self.advanced(typed.len()))
    }
}

/// How a newer read of the field relates to the suggestion on screen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Reconciled {
    /// Everything accepted so far is in the field and nothing else changed.
    Unchanged,
    /// The user typed the suggestion's next characters (or the field showed
    /// accepted text with the space a new sentence needs).
    Advanced(Session),
    /// The field moved away from the suggestion.
    Stale,
}

/// Fields longer than this may arrive as a sliding window of their end.
const WINDOWED_TEXT_BYTES: usize = 1_024;
/// How far a window may slide between two reads.
const MAX_WINDOW_SHIFT: usize = 512;

/// `sessionReconciledByPublishedTyping`, for a reader that reports whole
/// field snapshots rather than key presses.
pub fn reconcile(session: &Session, before: &str, after: &str) -> Reconciled {
    if after != session.after {
        return Reconciled::Stale;
    }
    let expected = session.expected_before();
    let (session, typed) = match typed_since(&expected, before) {
        Some(typed) => (session.clone(), typed),
        None => {
            // A new sentence got its separating space when it was typed in
            // (`insertion_chunk`); the suggestion itself did not have it.
            let accepted = session.accepted();
            let spaced = format!("{} {accepted}", session.before);
            match (!accepted.is_empty())
                .then(|| typed_since(&spaced, before))
                .flatten()
            {
                Some(typed) => {
                    let mut rebased = session.clone();
                    rebased.before.push(' ');
                    (rebased, typed)
                }
                None => return Reconciled::Stale,
            }
        }
    };
    if typed.is_empty() {
        return if session.expected_before() == expected {
            Reconciled::Unchanged
        } else {
            Reconciled::Advanced(session)
        };
    }
    match session.advanced_by_typing(typed) {
        Some(advanced) => Reconciled::Advanced(advanced),
        None => Reconciled::Stale,
    }
}

/// What was typed after `expected`, when `before` still starts with it. A
/// long field read as a window of its end may have slid by a few characters.
pub fn typed_since<'a>(expected: &str, before: &'a str) -> Option<&'a str> {
    if let Some(rest) = before.strip_prefix(expected) {
        return Some(rest);
    }
    if expected.len() < WINDOWED_TEXT_BYTES {
        return None;
    }
    (1..=MAX_WINDOW_SHIFT.min(expected.len() - WINDOWED_TEXT_BYTES))
        .filter(|shift| expected.is_char_boundary(*shift))
        .find_map(|shift| before.strip_prefix(&expected[shift..]))
}

/// `isStaleAcceptanceEcho`: a new suggestion that only repeats the chunk just
/// accepted, while the field has not shown it yet, is not shown.
pub fn is_stale_acceptance_echo(
    result: &str,
    accepted_chunk: &str,
    current_before: &str,
    accepted_before: &str,
) -> bool {
    let chunk = accepted_chunk.trim();
    !chunk.is_empty() && result.trim() == chunk && current_before == accepted_before
}

// ----------------------------------------------------------------- extension

/// A suggestion is topped up once this many words, or fewer, are left.
pub const EXTENSION_THRESHOLD_WORDS: usize = 2;

/// Words left at which a top-up starts. A one-word limit never tops up.
pub fn extension_threshold(word_limit: usize) -> usize {
    EXTENSION_THRESHOLD_WORDS.min(word_limit.saturating_sub(1))
}

/// Words asked for in one top-up: one fewer than a fresh suggestion, so the
/// ghost never grows past the limit plus one.
pub fn top_up_word_limit(word_limit: usize) -> usize {
    word_limit.saturating_sub(1).max(1)
}

pub fn word_count(text: &str) -> usize {
    text.split_whitespace()
        .filter(|w| w.chars().any(super::text::is_word_char))
        .count()
}

/// Whether output stopped at the length limit rather than at the end of a
/// thought. One word short still counts: the token budget can run out
/// before the last word is whole.
pub fn is_open_ended(chunk: &str, word_limit: usize) -> bool {
    !chunk.contains(super::text::is_newline)
        && !ends_sentence(chunk)
        && word_count(chunk) >= word_limit.saturating_sub(1).max(1)
}

pub fn should_extend(session: &Session, word_limit: usize) -> bool {
    let threshold = extension_threshold(word_limit);
    threshold > 0
        && session.kind == SuggestionKind::Continuation
        && session.open_ended
        && !session.is_exhausted()
        && word_count(session.remaining()) <= threshold
}

/// The text a top-up continues from: what stood before the caret when the
/// suggestion was made, then the whole suggestion.
pub fn continuation_prefix(session: &Session) -> String {
    format!("{}{}", session.before, session.full_text)
}

/// The part of `output` that may be appended to `suggestion`. Words already
/// on screen must not change, so the addition starts a new word (or adds
/// punctuation) and does not repeat what the suggestion just said.
pub fn addition(output: &str, suggestion: &str) -> Option<String> {
    let first = output.chars().next()?;
    let last = suggestion.chars().next_back()?;
    if output.trim().is_empty() || output.contains(super::text::is_newline) {
        return None;
    }
    if super::text::is_word_char(last) && super::text::is_word_char(first) {
        return None;
    }
    let normalized = |text: &str| {
        text.to_lowercase()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    };
    let said = normalized(suggestion);
    let added = normalized(output);
    (!added.is_empty() && !said.ends_with(&added)).then(|| output.to_string())
}

// -------------------------------------------------------------- anchor cache

/// Recently shown suggestions, so common edits re-show a still-valid tail
/// without a model call: focus bounce, backspace, typing through after the
/// session was cleared.
pub struct AnchorCache {
    entries: Vec<AnchorEntry>,
}

struct AnchorEntry {
    identity: String,
    fingerprint: String,
    prefix_tail: String,
    full_text: String,
    open_ended: bool,
    recorded: Instant,
}

/// A still-valid tail, and whether its suggestion may be topped up.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Restoration {
    pub text: String,
    pub open_ended: bool,
}

const PREFIX_TAIL_CHARACTERS: usize = 256;
const CAPACITY: usize = 16;
pub const MAX_ENTRY_AGE: Duration = Duration::from_secs(180);

impl Default for AnchorCache {
    fn default() -> Self {
        Self::new()
    }
}

impl AnchorCache {
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    pub fn record(
        &mut self,
        identity: &str,
        fingerprint: &str,
        before: &str,
        full_text: &str,
        open_ended: bool,
        now: Instant,
    ) {
        if identity.is_empty() || fingerprint.is_empty() || full_text.is_empty() {
            return;
        }
        let prefix_tail = tail(before);
        self.entries.retain(|e| {
            !(e.identity == identity
                && e.fingerprint == fingerprint
                && e.prefix_tail == prefix_tail
                && e.full_text == full_text)
        });
        self.entries.push(AnchorEntry {
            identity: identity.to_string(),
            fingerprint: fingerprint.to_string(),
            prefix_tail,
            full_text: full_text.to_string(),
            open_ended,
            recorded: now,
        });
        if self.entries.len() > CAPACITY {
            let excess = self.entries.len() - CAPACITY;
            self.entries.drain(..excess);
        }
    }

    /// The deepest still-valid tail for the text now before the caret.
    pub fn restoration(
        &mut self,
        identity: &str,
        fingerprint: &str,
        before: &str,
        now: Instant,
    ) -> Option<Restoration> {
        self.entries
            .retain(|e| now.saturating_duration_since(e.recorded) <= MAX_ENTRY_AGE);
        let live: Vec<char> = tail(before).chars().collect();
        let mut best: Option<(usize, Instant, Restoration)> = None;
        for entry in self.entries.iter().rev() {
            if entry.identity != identity || entry.fingerprint != fingerprint {
                continue;
            }
            let Some(consumed) = consumed_prefix(&live, &entry.prefix_tail, &entry.full_text)
            else {
                continue;
            };
            let better = best
                .as_ref()
                .is_none_or(|(c, at, _)| consumed > *c || (consumed == *c && entry.recorded > *at));
            if better {
                let text: String = entry.full_text.chars().skip(consumed).collect();
                best = Some((
                    consumed,
                    entry.recorded,
                    Restoration {
                        text,
                        open_ended: entry.open_ended,
                    },
                ));
            }
        }
        best.map(|(_, _, r)| r)
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }
}

fn tail(text: &str) -> String {
    let count = text.chars().count();
    text.chars()
        .skip(count.saturating_sub(PREFIX_TAIL_CHARACTERS))
        .collect()
}

/// How many characters of `full_text` the live text has typed through.
fn consumed_prefix(live: &[char], anchor_tail: &str, full_text: &str) -> Option<usize> {
    let composed: Vec<char> = anchor_tail.chars().chain(full_text.chars()).collect();
    let anchor_count = anchor_tail.chars().count();
    (0..composed.len().saturating_sub(anchor_count)).find(|consumed| {
        let end = anchor_count + consumed;
        let start = end.saturating_sub(PREFIX_TAIL_CHARACTERS);
        end - start == live.len() && composed[start..end] == *live
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(suggestion: &str, before: &str) -> Session {
        Session::new(before, "", suggestion, SuggestionKind::Continuation)
    }

    #[test]
    fn typing_the_next_characters_walks_through_the_ghost() {
        let draft = "Hi Sarah, thanks for the update. I wanted to follow";
        let s = session(" up on", draft);
        let Reconciled::Advanced(walked) = reconcile(&s, &format!("{draft} "), "") else {
            panic!("typed a space")
        };
        assert_eq!(walked.remaining(), "up on");
        let Reconciled::Advanced(walked) = reconcile(&walked, &format!("{draft} up"), "") else {
            panic!("typed up")
        };
        assert_eq!(walked.remaining(), " on");
        assert_eq!(
            reconcile(&walked, &format!("{draft} up"), ""),
            Reconciled::Unchanged
        );
        // Any other edit leaves the suggestion behind.
        assert_eq!(reconcile(&s, &format!("{draft} x"), ""), Reconciled::Stale);
        assert_eq!(
            reconcile(&s, &draft[..draft.len() - 1], ""),
            Reconciled::Stale
        );
        assert_eq!(reconcile(&s, draft, "!"), Reconciled::Stale);
        // Typed to its end, the suggestion is used up.
        let Reconciled::Advanced(done) = reconcile(&s, &format!("{draft} up on"), "") else {
            panic!("typed through")
        };
        assert!(done.is_exhausted());
    }

    #[test]
    fn accepted_text_with_an_added_sentence_space_is_still_the_suggestion() {
        let s = session("Next step", "Done.").advanced("Next".len());
        let Reconciled::Advanced(rebased) = reconcile(&s, "Done. Next", "") else {
            panic!("rebased")
        };
        assert_eq!(rebased.before, "Done. ");
        assert_eq!(rebased.remaining(), " step");
        assert_eq!(reconcile(&rebased, "Done. Next", ""), Reconciled::Unchanged);
    }

    #[test]
    fn a_sliding_window_of_a_long_field_still_reconciles() {
        let long = "word ".repeat(400);
        let s = session(" next words", &long);
        let slid = format!("{} next", &long[5..]);
        let Reconciled::Advanced(walked) = reconcile(&s, &slid, "") else {
            panic!("slid window")
        };
        assert_eq!(walked.remaining(), " words");
        assert_eq!(typed_since("short", "different"), None);
    }

    #[test]
    fn control_input_and_replacements_do_not_walk() {
        let s = session(" up on", "follow");
        assert_eq!(s.advanced_by_typing("\u{8}"), None);
        let emoji = Session::new("x :roc", "", "🚀", SuggestionKind::Emoji);
        assert_eq!(emoji.advanced_by_typing("🚀"), None);
    }

    #[test]
    fn stale_acceptance_echoes() {
        assert!(is_stale_acceptance_echo(" up", "up", "follow", "follow"));
        assert!(!is_stale_acceptance_echo(
            " up",
            "up",
            "follow up",
            "follow"
        ));
        assert!(!is_stale_acceptance_echo(" on", "up", "follow", "follow"));
        assert!(!is_stale_acceptance_echo(" ", " ", "follow", "follow"));
    }

    #[test]
    fn only_output_cut_by_the_limit_is_continued() {
        assert!(is_open_ended(" between the number", 3));
        assert!(is_open_ended(" discuss how", 3));
        assert!(!is_open_ended(" care of it.", 3));
        assert!(!is_open_ended(" 16:", 3));
        assert!(!is_open_ended(" first line\nsecond line", 3));
    }

    #[test]
    fn a_top_up_starts_once_two_words_are_left() {
        let mut fresh = session(" between the number", "The main tradeoff is");
        fresh.open_ended = true;
        assert!(!should_extend(&fresh, 3));
        assert!(should_extend(&fresh.advanced(" between".len()), 3));
        assert!(should_extend(&fresh.advanced(" between t".len()), 3));
        assert!(!should_extend(&fresh.advanced(fresh.full_text.len()), 3));
        let mut finished = session(" care of it.", "x");
        finished.open_ended = false;
        assert!(!should_extend(&finished.advanced(" care".len()), 3));
        assert_eq!(extension_threshold(3), 2);
        assert_eq!(extension_threshold(12), 2);
        assert_eq!(extension_threshold(2), 1);
        assert_eq!(extension_threshold(1), 0);
        assert_eq!(top_up_word_limit(4), 3);
        assert_eq!(top_up_word_limit(1), 1);
        assert_eq!(
            continuation_prefix(&fresh.advanced(" between".len())),
            "The main tradeoff is between the number"
        );
    }

    #[test]
    fn an_addition_never_changes_words_on_screen() {
        let shown = " between the number";
        assert_eq!(
            addition(" of menu items", shown).as_deref(),
            Some(" of menu items")
        );
        assert_eq!(addition(", and", shown).as_deref(), Some(", and"));
        assert_eq!(addition("s of items", shown), None);
        assert_eq!(addition("   ", shown), None);
        assert_eq!(addition("", shown), None);
        assert_eq!(addition(" of\nitems", shown), None);
        assert_eq!(addition(" the number", shown), None);
        assert_eq!(addition(" The  Number", shown), None);
        assert_eq!(
            addition(" the numbers add up", shown).as_deref(),
            Some(" the numbers add up")
        );
        assert_eq!(word_count(" up with you"), 3);
        assert_eq!(word_count(" it ."), 1);
        assert_eq!(word_count(" — "), 0);
    }

    #[test]
    fn the_anchor_cache_restores_still_valid_tails() {
        let now = Instant::now();
        let mut cache = AnchorCache::new();
        cache.record("field", "a", "Hello", " world again", false, now);
        let rest = |cache: &mut AnchorCache, before: &str| {
            cache.restoration("field", "a", before, now).map(|r| r.text)
        };
        assert_eq!(rest(&mut cache, "Hello").as_deref(), Some(" world again"));
        assert_eq!(rest(&mut cache, "Hello wo").as_deref(), Some("rld again"));
        assert_eq!(rest(&mut cache, "Hello").as_deref(), Some(" world again"));
        assert_eq!(rest(&mut cache, "Hello wa"), None);
        assert_eq!(cache.restoration("other", "a", "Hello", now), None);
        assert_eq!(cache.restoration("field", "b", "Hello", now), None);
        cache.record("field", "a", "Hello wo", "rld forever", false, now);
        assert_eq!(rest(&mut cache, "Hello wor").as_deref(), Some("ld again"));
        let mut used = AnchorCache::new();
        used.record("field", "a", "Hello", " world", false, now);
        assert_eq!(used.restoration("field", "a", "Hello world", now), None);
        assert_eq!(
            used.restoration(
                "field",
                "a",
                "Hello",
                now + MAX_ENTRY_AGE + Duration::from_secs(1)
            ),
            None
        );
    }

    #[test]
    fn the_anchor_cache_is_bounded_and_matches_long_prefixes_on_their_tail() {
        let now = Instant::now();
        let mut cache = AnchorCache::new();
        for i in 0..CAPACITY + 4 {
            cache.record(
                "field",
                "a",
                &format!("prefix {i}"),
                &format!("suffix {i}"),
                false,
                now,
            );
        }
        assert_eq!(cache.restoration("field", "a", "prefix 0", now), None);
        let last = CAPACITY + 3;
        assert_eq!(
            cache
                .restoration("field", "a", &format!("prefix {last}"), now)
                .map(|r| r.text),
            Some(format!("suffix {last}"))
        );
        let long = "a".repeat(2_000) + " ending here";
        cache.record("field", "a", &long, " and more", true, now);
        assert_eq!(
            cache.restoration("field", "a", &format!("{long} and"), now),
            Some(Restoration {
                text: " more".into(),
                open_ended: true
            })
        );
        cache.clear();
        assert_eq!(cache.restoration("field", "a", &long, now), None);
    }
}
