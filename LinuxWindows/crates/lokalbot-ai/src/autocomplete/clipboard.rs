// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 24 June 2026.
// See THIRD_PARTY_NOTICES.md.

use std::collections::HashSet;
use std::sync::LazyLock;
use std::time::{Duration, Instant};

use regex::Regex;

pub const MAX_SNIPPET_CHARACTERS: usize = 1_200;
const COMPACT_LINE_THRESHOLD: usize = 3;
const HEAD_FALLBACK_CHARACTERS: usize = 300;
pub const STALE_AFTER: Duration = Duration::from_secs(300);

static ANSI_ESCAPE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new("\u{1B}\\[[0-?]*[ -/]*[@-~]").expect("the ANSI pattern is valid"));

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

pub fn sanitize(raw: &str, max_characters: Option<usize>) -> Option<String> {
    let sanitized = sanitize_text(raw, max_characters);
    (!sanitized.is_empty() && sanitized.chars().any(char::is_alphanumeric)).then_some(sanitized)
}

fn collapsed(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn should_include(snippet: &str, preceding: &str) -> bool {
    let normalized = collapsed(snippet);
    !normalized.is_empty() && !collapsed(&sanitize_text(preceding, None)).contains(&normalized)
}

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

pub fn resolve(raw: &str, preceding: &str) -> Option<String> {
    let sanitized = sanitize(raw, None)?;
    let distilled = distill(&sanitized, preceding);
    sanitize(&distilled, Some(MAX_SNIPPET_CHARACTERS))
        .filter(|snippet| should_include(snippet, preceding))
}

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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub count: u64,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Memo {
    identity: String,
    count: u64,
    value: String,
}

#[derive(Clone, Debug, Default)]
pub struct Preface {
    memo: Option<Memo>,
    filter: RelevanceFilter,
}

impl Preface {
    pub fn clear(&mut self) {
        *self = Self::default();
    }

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
        assert!(
            preface
                .resolve(Some(&copied), "unrelated", "f", now)
                .is_some()
        );
        assert_eq!(preface.resolve(Some(&copied), "unrelated", "g", now), None);
        assert_eq!(preface.resolve(None, "cutover", "f", now), None);
        let after = snapshot(3, "cutover on Thursday");
        assert_eq!(preface.resolve(Some(&after), "cutover", "f", now), None);
        preface.clear();
        assert_eq!(preface.resolve(Some(&after), "cutover", "f", now), None);
    }
}
