//! "Looks done?" (`ActionCompletionHints.swift`): a suggestion, never a status
//! change. A later screen capture that looks like the user finished one of
//! their open actions needs at least two of the action's distinctive words and
//! a completion phrase that fits the action's verb. Only locally retained
//! screen text and titles are read.

use std::collections::{BTreeSet, HashMap, HashSet};

use chrono::{DateTime, Utc};

use crate::library::{Library, read_json, write_json};
use crate::model::{ActionStatus, ActionThread};
use crate::search::MatchMode;

pub const MAXIMUM_THREADS: usize = 60;
pub const HITS_PER_THREAD: usize = 6;
pub const MINIMUM_MATCHING_TERMS: usize = 2;
const MAXIMUM_DISMISSED: usize = 500;
const DISMISSED_FILE: &str = "action-completion-dismissed.json";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompletionHint {
    pub thread_id: String,
    pub snapshot_id: i64,
    pub captured_at: DateTime<Utc>,
    pub app: String,
    pub title: String,
    pub cue: String,
}

impl CompletionHint {
    pub fn dismissal_key(&self) -> String {
        format!("{}#{}", self.thread_id, self.snapshot_id)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Capture {
    pub snapshot_id: i64,
    pub captured_at: DateTime<Utc>,
    pub app: String,
    pub title: String,
    pub text: String,
}

const STOP_WORDS: [&str; 46] = [
    "the",
    "and",
    "for",
    "with",
    "from",
    "into",
    "onto",
    "about",
    "this",
    "that",
    "these",
    "those",
    "their",
    "them",
    "they",
    "your",
    "yours",
    "mine",
    "have",
    "will",
    "would",
    "should",
    "could",
    "before",
    "after",
    "next",
    "week",
    "today",
    "tomorrow",
    "friday",
    "monday",
    "tuesday",
    "wednesday",
    "thursday",
    "saturday",
    "sunday",
    "until",
    "also",
    "some",
    "more",
    "over",
    "back",
    "then",
    "when",
    "what",
    "which",
];
const MORE_STOP_WORDS: [&str; 6] = ["make", "sure", "please", "need", "needs", "still"];
const GENERIC_VERBS: [&str; 47] = [
    "send", "sends", "share", "shares", "review", "prepare", "update", "follow", "check",
    "schedule", "book", "draft", "write", "finish", "complete", "look", "take", "give", "provide",
    "create", "file", "submit", "merge", "publish", "post", "email", "reply", "forward", "ping",
    "call", "confirm", "approve", "deploy", "release", "fix", "open", "close", "resolve", "invite",
    "set", "add", "move", "get", "find", "ask", "pay", "plan",
];
const CUE_FAMILIES: [(&[&str], &[&str]); 8] = [
    (
        &[
            "send", "email", "mail", "reply", "forward", "ping", "message",
        ],
        &[
            "message sent",
            "has been sent",
            "was sent",
            "email sent",
            "sent to",
            "sent mail",
            "sent messages",
        ],
    ),
    (
        &["share", "invite"],
        &[
            "shared with",
            "now has access",
            "invitation sent",
            "invite sent",
            "link copied",
        ],
    ),
    (
        &["merge", "pr", "pull", "land"],
        &["merged", "successfully merged", "pull request merged"],
    ),
    (
        &["submit", "file", "apply", "upload"],
        &[
            "submitted",
            "submission received",
            "successfully submitted",
            "uploaded",
        ],
    ),
    (
        &["publish", "post", "deploy", "release", "ship"],
        &["published", "deployed", "released", "is live", "posted"],
    ),
    (
        &["schedule", "book", "reserve", "calendar"],
        &[
            "event created",
            "invitation sent",
            "added to calendar",
            "booked",
            "confirmed",
            "reservation confirmed",
        ],
    ),
    (
        &["review", "approve"],
        &["approved", "review submitted", "changes approved"],
    ),
    (
        &["fix", "resolve", "close", "finish", "complete"],
        &["resolved", "marked as done", "completed", "closed", "fixed"],
    ),
];
const GENERAL_CUES: [&str; 8] = [
    "marked as done",
    "completed",
    "resolved",
    "has been sent",
    "message sent",
    "submitted",
    "merged",
    "published",
];

/// Distinctive words: not stop words or generic task verbs, and either four
/// or more letters, containing a digit, or capitalized in the source.
pub fn distinctive_terms(text: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .filter_map(|word| {
            let lower = word.to_lowercase();
            let count = lower.chars().count();
            if STOP_WORDS.contains(&lower.as_str())
                || MORE_STOP_WORDS.contains(&lower.as_str())
                || GENERIC_VERBS.contains(&lower.as_str())
            {
                return None;
            }
            let has_digit = word.chars().any(char::is_numeric);
            let capitalized = word.chars().next().is_some_and(char::is_uppercase);
            (count >= 4 || (has_digit && count >= 2) || (capitalized && count >= 3))
                .then_some(lower)
        })
        .filter(|word| seen.insert(word.clone()))
        .collect()
}

/// Completion phrases for the action's verb, falling back to a general set.
pub fn cues(action_text: &str) -> Vec<&'static str> {
    let lower = action_text.to_lowercase();
    let words: HashSet<&str> = lower
        .split(|c: char| !c.is_alphabetic())
        .filter(|word| !word.is_empty())
        .collect();
    let mut result: Vec<&'static str> = Vec::new();
    for (verbs, phrases) in CUE_FAMILIES {
        if verbs.iter().any(|verb| words.contains(verb)) {
            result.extend_from_slice(phrases);
        }
    }
    if result.is_empty() {
        GENERAL_CUES.to_vec()
    } else {
        result
    }
}

/// The phrase with no letter or digit touching either end.
fn contains_phrase(haystack: &str, phrase: &str) -> bool {
    let mut from = 0;
    while let Some(found) = haystack[from..].find(phrase) {
        let start = from + found;
        let end = start + phrase.len();
        let before = haystack[..start].chars().next_back();
        let after = haystack[end..].chars().next();
        if !before.is_some_and(char::is_alphanumeric) && !after.is_some_and(char::is_alphanumeric) {
            return true;
        }
        from = start + phrase.chars().next().map_or(1, char::len_utf8);
    }
    false
}

fn cue_in(capture: &Capture, phrases: &[&'static str]) -> Option<&'static str> {
    let haystack = format!("{}\n{}", capture.title, capture.text).to_lowercase();
    phrases
        .iter()
        .find(|phrase| contains_phrase(&haystack, phrase))
        .copied()
}

fn matches_terms(capture: &Capture, terms: &[String]) -> bool {
    if terms.len() < MINIMUM_MATCHING_TERMS {
        return false;
    }
    let haystack = format!("{}\n{}", capture.title, capture.text).to_lowercase();
    let words: BTreeSet<&str> = haystack
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect();
    terms
        .iter()
        .filter(|term| words.contains(term.as_str()))
        .count()
        >= MINIMUM_MATCHING_TERMS
}

/// Evaluates a thread against captures already fetched for it.
pub fn hint(
    thread: &ActionThread,
    captures: &[Capture],
    dismissed: &HashSet<String>,
) -> Option<CompletionHint> {
    if !thread.is_for_user() || thread.status() != ActionStatus::Open {
        return None;
    }
    let terms = distinctive_terms(&thread.text);
    if terms.len() < MINIMUM_MATCHING_TERMS {
        return None;
    }
    let since = thread.latest().meeting_started_at;
    let phrases = cues(&thread.text);
    let mut sorted: Vec<&Capture> = captures.iter().collect();
    sorted.sort_by_key(|c| std::cmp::Reverse(c.captured_at));
    for capture in sorted.into_iter().filter(|c| c.captured_at > since) {
        if dismissed.contains(&format!("{}#{}", thread.id, capture.snapshot_id))
            || !matches_terms(capture, &terms)
        {
            continue;
        }
        let Some(cue) = cue_in(capture, &phrases) else {
            continue;
        };
        return Some(CompletionHint {
            thread_id: thread.id.clone(),
            snapshot_id: capture.snapshot_id,
            captured_at: capture.captured_at,
            app: capture.app.clone(),
            title: capture.title.clone(),
            cue: cue.to_string(),
        });
    }
    None
}

impl Library {
    /// Hints for open actions of the user, from retained screen text.
    pub fn action_completion_hints(
        &self,
        threads: &[ActionThread],
        now: DateTime<Utc>,
    ) -> HashMap<String, CompletionHint> {
        let dismissed: HashSet<String> = self.dismissed_completion_hints().into_iter().collect();
        let mut result = HashMap::new();
        let open = threads
            .iter()
            .filter(|t| t.is_for_user() && t.status() == ActionStatus::Open)
            .take(MAXIMUM_THREADS);
        for thread in open {
            let terms = distinctive_terms(&thread.text);
            if terms.len() < MINIMUM_MATCHING_TERMS {
                continue;
            }
            let since = thread.latest().meeting_started_at;
            if since >= now {
                continue;
            }
            let query = terms.iter().take(4).cloned().collect::<Vec<_>>().join(" ");
            let hits = match self.search_ocr(
                &query,
                MatchMode::Any,
                Some((since, now)),
                None,
                HITS_PER_THREAD,
            ) {
                Ok(hits) => hits,
                Err(err) => {
                    log::debug!("action completion search failed: {err:#}");
                    continue;
                }
            };
            let captures: Vec<Capture> = hits
                .into_iter()
                .map(|hit| Capture {
                    snapshot_id: hit.moment.id,
                    captured_at: hit.moment.ts,
                    app: hit.moment.app.clone(),
                    title: hit.moment.window_title.clone(),
                    text: self
                        .screen_text(hit.moment.id, 4_000)
                        .unwrap_or_else(|| hit.snippet.clone()),
                })
                .collect();
            if let Some(found) = hint(thread, &captures, &dismissed) {
                result.insert(thread.id.clone(), found);
            }
        }
        result
    }

    /// Text captured with one screen row, at most `max_chars`.
    pub fn screen_text(&self, snapshot_id: i64, max_chars: usize) -> Option<String> {
        self.with_db(|db| {
            let text: Option<String> = db
                .query_row(
                    "SELECT text FROM ocr_fts WHERE CAST(snapshot_id AS INTEGER) = ?1 LIMIT 1",
                    [snapshot_id],
                    |row| row.get(0),
                )
                .ok();
            Ok(text.map(|text| text.chars().take(max_chars).collect()))
        })
        .ok()
        .flatten()
    }

    pub fn dismissed_completion_hints(&self) -> Vec<String> {
        read_json(&self.paths().root().join(DISMISSED_FILE))
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    /// "Not Yet": the same capture isn't offered again.
    pub fn dismiss_completion_hint(&self, found: &CompletionHint) -> anyhow::Result<()> {
        let mut dismissed = self.dismissed_completion_hints();
        dismissed.push(found.dismissal_key());
        if dismissed.len() > MAXIMUM_DISMISSED {
            dismissed.drain(..dismissed.len() - MAXIMUM_DISMISSED);
        }
        write_json(&self.paths().root().join(DISMISSED_FILE), &dismissed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capture(id: i64, title: &str, text: &str, seconds: i64) -> Capture {
        Capture {
            snapshot_id: id,
            captured_at: DateTime::from_timestamp(1_800_000_000 + seconds, 0).unwrap(),
            app: "Mail".into(),
            title: title.into(),
            text: text.into(),
        }
    }

    fn thread(text: &str, status: &str, for_user: bool) -> ActionThread {
        let meeting: crate::model::Meeting = serde_json::from_value(serde_json::json!({
            "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            "title": "Call",
            "appName": "Zoom",
            "startedAt": "2027-01-15T08:00:00Z",
            "relativePath": "meetings/x",
        }))
        .unwrap();
        let outcomes: crate::model::MeetingOutcomes = serde_json::from_value(serde_json::json!({
            "schemaVersion": 2,
            "actionItems": [{"id": "a", "text": text, "importance": 3, "isForUser": for_user, "owner": "Me"}],
            "decisionRecords": [],
            "openQuestions": [],
        }))
        .unwrap();
        let mut state = crate::model::OutcomeState::default();
        state.actions.insert(
            "a".into(),
            serde_json::from_value(serde_json::json!({"status": status})).unwrap(),
        );
        let projection = crate::actions::OutcomeProjection {
            meeting,
            outcomes,
            state,
        };
        crate::actions::cluster_threads(projection.action_references())
            .into_iter()
            .next()
            .unwrap()
    }

    #[test]
    fn terms_skip_stop_words_and_generic_verbs() {
        assert_eq!(
            distinctive_terms("Send the Q3 security overview to Ana before Friday"),
            vec!["q3", "security", "overview", "ana"]
        );
        assert!(distinctive_terms("Send it to them").is_empty());
    }

    #[test]
    fn cues_fit_the_verb() {
        assert!(cues("Send the overview").contains(&"message sent"));
        assert!(cues("Merge the pull request").contains(&"merged"));
        assert_eq!(cues("Think about it"), GENERAL_CUES.to_vec());
    }

    #[test]
    fn phrases_stand_alone() {
        assert!(contains_phrase("the pr was merged.", "merged"));
        assert!(!contains_phrase("unmerged changes", "merged"));
        assert!(!contains_phrase("merged2", "merged"));
    }

    #[test]
    fn a_hint_needs_the_words_and_the_phrase_after_the_meeting() {
        let open = thread("Send the security overview to Ana", "open", true);
        let dismissed = HashSet::new();
        // Words and phrase together, in a capture after the meeting.
        let after = (open.latest().meeting_started_at
            - DateTime::from_timestamp(1_800_000_000, 0).unwrap())
        .num_seconds()
            + 60;
        let good = capture(1, "Mail", "Message sent. Security overview for Ana", after);
        assert_eq!(
            hint(&open, std::slice::from_ref(&good), &dismissed)
                .unwrap()
                .cue,
            "message sent"
        );
        // Words without a phrase, or a phrase without the words.
        let words_only = capture(2, "Mail", "Security overview for Ana", after);
        assert!(hint(&open, &[words_only], &dismissed).is_none());
        let phrase_only = capture(3, "Mail", "Message sent. Lunch plans", after);
        assert!(hint(&open, &[phrase_only], &dismissed).is_none());
        // Before the meeting doesn't count.
        let early = capture(
            4,
            "Mail",
            "Message sent. Security overview for Ana",
            after - 120,
        );
        assert!(hint(&open, &[early], &dismissed).is_none());
        // A dismissed capture isn't offered again.
        let found = hint(&open, std::slice::from_ref(&good), &dismissed).unwrap();
        let gone: HashSet<String> = [found.dismissal_key()].into();
        assert!(hint(&open, std::slice::from_ref(&good), &gone).is_none());
        // Only the user's open actions.
        let done = thread("Send the security overview to Ana", "done", true);
        assert!(hint(&done, std::slice::from_ref(&good), &dismissed).is_none());
        let theirs = thread("Send the security overview to Ana", "open", false);
        assert!(hint(&theirs, std::slice::from_ref(&good), &dismissed).is_none());
    }
}
