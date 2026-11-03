// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 24 June 2026.
// See THIRD_PARTY_NOTICES.md.

//! Clipboard context for the prompt (`CotypingClipboardContext.swift`), the
//! pure half: sanitizing, bounding, relevance and the already-in-the-field
//! guard. A snippet may be pinned in memory for one field and one clipboard
//! state to keep the prompt's start stable; it is never saved or logged.

use std::collections::HashSet;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use regex::Regex;

/// The most the prompt ever gets (Cotabby's 1,200).
pub const MAX_SNIPPET_CHARACTERS: usize = 1_200;
const COMPACT_LINE_THRESHOLD: usize = 3;
const HEAD_FALLBACK_CHARACTERS: usize = 300;
/// A copy older than this no longer says what the user is working on.
pub const STALE_AFTER: Duration = Duration::from_secs(300);

static ANSI_ESCAPE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new("\u{1B}\\[[0-?]*[ -/]*[@-~]").expect("the ANSI pattern is valid"));

/// `CotypingPromptContextSanitizer.sanitize`: shell prompts, Markdown fences
/// and punctuation-heavy output are what small models copy back, so only
/// letters, digits, whitespace, `@` and `.` survive.
pub fn sanitize_text(raw: &str, max_characters: Option<usize>) -> String {
    let without_ansi = ANSI_ESCAPE.replace_all(raw, " ");
    let kept: String = without_ansi
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c.is_whitespace() || c == '@' || c == '.' {
                c
            } else {
                ' '
            }
        })
        .collect();
    let lines: Vec<String> = kept
        .split(super::text::is_newline)
        .map(|line| line.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|line| !line.is_empty())
        .collect();
    let joined = lines.join("\n");
    let bounded: String = match max_characters {
        Some(cap) => joined.chars().take(cap).collect(),
        None => joined,
    };
    bounded.trim().to_string()
}

fn significant_tokens(text: &str) -> HashSet<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| word.chars().count() >= 3)
        .map(str::to_string)
        .collect()
}

/// Sanitized text, or `None` for empty or punctuation-only input.
pub fn sanitize(raw: &str, max_characters: Option<usize>) -> Option<String> {
    let sanitized = sanitize_text(raw, max_characters);
    (!sanitized.is_empty() && sanitized.chars().any(char::is_alphanumeric)).then_some(sanitized)
}

fn collapsed(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// False when the snippet is already in the text being typed: no point in
/// feeding back what was just pasted.
pub fn should_include(snippet: &str, preceding: &str) -> bool {
    let normalized = collapsed(snippet);
    !normalized.is_empty() && !collapsed(&sanitize_text(preceding, None)).contains(&normalized)
}

/// Keeps the clipboard lines that share a word with the prefix. Short
/// snippets pass through; long unrelated copies shrink to a small head sample.
fn distill(clipboard: &str, prefix: &str) -> String {
    let lines: Vec<&str> = clipboard.split('\n').collect();
    if lines.len() <= COMPACT_LINE_THRESHOLD {
        return clipboard.to_string();
    }
    let prefix_tokens = significant_tokens(prefix);
    if prefix_tokens.is_empty() {
        return clipboard.to_string();
    }
    let relevant: Vec<&str> = lines
        .iter()
        .copied()
        .filter(|line| !significant_tokens(line).is_disjoint(&prefix_tokens))
        .collect();
    if relevant.is_empty() {
        return clipboard.chars().take(HEAD_FALLBACK_CHARACTERS).collect();
    }
    relevant.join("\n")
}

/// Sanitize, distill, cap, guard: the snippet to include, or `None`.
pub fn resolve(raw: &str, preceding: &str) -> Option<String> {
    let sanitized = sanitize(raw, None)?;
    let distilled = distill(&sanitized, preceding);
    sanitize(&distilled, Some(MAX_SNIPPET_CHARACTERS))
        .filter(|snippet| should_include(snippet, preceding))
}

/// The first observation is a baseline of unknown age, not a fresh copy.
/// Only later copies count, while fresh and related to what is being typed
/// (`CotypingClipboardRelevanceFilter`).
#[derive(Clone, Debug, Default)]
pub struct RelevanceFilter {
    last_count: Option<u64>,
    last_change: Option<Instant>,
}

impl RelevanceFilter {
    pub fn filter<'a>(
        &mut self,
        raw: &'a str,
        count: u64,
        preceding: &str,
        now: Instant,
    ) -> Option<&'a str> {
        let Some(baseline) = self.last_count else {
            self.last_count = Some(count);
            return None;
        };
        if count != baseline {
            self.last_count = Some(count);
            self.last_change = Some(now);
        }
        let changed = self.last_change?;
        if now.saturating_duration_since(changed) >= STALE_AFTER {
            return None;
        }
        let tokens = significant_tokens(raw);
        (!tokens.is_empty() && !tokens.is_disjoint(&significant_tokens(preceding))).then_some(raw)
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

/// One clipboard state as the desktop read it (`CotypingClipboardSnapshot`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub count: u64,
    pub text: String,
}

/// One non-empty verdict pinned to a field and a clipboard state. A nil
/// verdict is not pinned: it is looked at again as more is typed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Memo {
    identity: String,
    count: u64,
    value: String,
}

/// Clipboard state between requests (`pinnedClipboardContext`).
#[derive(Clone, Debug, Default)]
pub struct Preface {
    memo: Option<Memo>,
    filter: RelevanceFilter,
}

impl Preface {
    /// The grant is off.
    pub fn clear(&mut self) {
        *self = Self::default();
    }

    /// `CotypingClipboardPrefaceResolver.resolve`. `snapshot` is `None` when
    /// the clipboard holds nothing readable, or something concealed: the next
    /// copy after that starts a new baseline.
    pub fn resolve(
        &mut self,
        snapshot: Option<&Snapshot>,
        preceding: &str,
        identity: &str,
        now: Instant,
    ) -> Option<String> {
        let Some(snapshot) = snapshot else {
            self.filter.reset();
            self.memo = None;
            return None;
        };
        if let Some(memo) = &self.memo
            && memo.identity == identity
            && memo.count == snapshot.count
        {
            return Some(memo.value.clone());
        }
        self.memo = None;
        let relevant = self
            .filter
            .filter(&snapshot.text, snapshot.count, preceding, now)?;
        let value = resolve(relevant, preceding)?;
        self.memo = Some(Memo {
            identity: identity.to_string(),
            count: snapshot.count,
            value: value.clone(),
        });
        Some(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noise_is_stripped_and_lines_are_kept() {
        assert_eq!(
            sanitize_text("\u{1b}[31m$ git   push\u{1b}[0m\n\n```a@b.c```", None),
            "git push\na@b.c"
        );
        assert_eq!(sanitize("  --- !!! ", None), None);
        assert_eq!(sanitize("x", Some(1200)).as_deref(), Some("x"));
        assert_eq!(sanitize_text("abcdef", Some(3)), "abc");
    }

    #[test]
    fn a_snippet_already_in_the_field_is_left_out() {
        assert!(!should_include("Hello  world", "I said Hello world today"));
        assert!(should_include("Hello world", "Nothing like it"));
        assert_eq!(
            resolve("migration timeline", "the migration timeline is"),
            None
        );
    }

    #[test]
    fn long_copies_keep_related_lines_or_a_small_head() {
        let long = "alpha beta\ngamma delta\nepsilon zeta\neta theta";
        assert_eq!(
            resolve(long, "about gamma today").as_deref(),
            Some("gamma delta")
        );
        let unrelated = format!("{}\nb\nc\nd", "a".repeat(400));
        assert_eq!(resolve(&unrelated, "nothing shared").unwrap().len(), 300);
        assert_eq!(
            resolve("one line only", "nothing shared").as_deref(),
            Some("one line only")
        );
        assert!(
            resolve(&"word ".repeat(600), "other")
                .unwrap()
                .chars()
                .count()
                <= 1200
        );
    }

    #[test]
    fn the_first_observation_is_only_a_baseline() {
        let now = Instant::now();
        let mut filter = RelevanceFilter::default();
        assert_eq!(filter.filter("the migration", 1, "migration", now), None);
        // Same clipboard later: its age is still unknown.
        assert_eq!(filter.filter("the migration", 1, "migration", now), None);
        assert_eq!(
            filter.filter("the migration", 2, "migration", now),
            Some("the migration")
        );
        assert_eq!(
            filter.filter("the migration", 2, "unrelated words", now),
            None
        );
        assert_eq!(
            filter.filter("the migration", 2, "migration", now + STALE_AFTER),
            None
        );
    }

    #[test]
    fn a_verdict_is_pinned_to_a_field_and_a_clipboard_state() {
        let now = Instant::now();
        let mut preface = Preface::default();
        let snapshot = |count, text: &str| Snapshot {
            count,
            text: text.to_string(),
        };
        let first = snapshot(1, "cutover on Thursday");
        assert_eq!(preface.resolve(Some(&first), "cutover", "f", now), None);
        let copied = snapshot(2, "cutover on Thursday");
        assert_eq!(
            preface
                .resolve(Some(&copied), "the cutover", "f", now)
                .as_deref(),
            Some("cutover on Thursday")
        );
        // Pinned, whatever is typed next.
        assert!(
            preface
                .resolve(Some(&copied), "unrelated", "f", now)
                .is_some()
        );
        // Another field looks again.
        assert_eq!(preface.resolve(Some(&copied), "unrelated", "g", now), None);
        // A concealed copy resets: the next one is a new baseline.
        assert_eq!(preface.resolve(None, "cutover", "f", now), None);
        let after = snapshot(3, "cutover on Thursday");
        assert_eq!(preface.resolve(Some(&after), "cutover", "f", now), None);
        preface.clear();
        assert_eq!(preface.resolve(Some(&after), "cutover", "f", now), None);
    }
}
