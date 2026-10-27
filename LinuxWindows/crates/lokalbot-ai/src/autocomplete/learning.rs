//! Learning from accepted suggestions (`CotypingLearningStore`,
//! `CotypingLearningRanker`, `CotypingLearningScope`,
//! `CotypingAcceptedSuggestionBatch`).
//!
//! An accepted suggestion becomes an example that later prompts in the same
//! document can show the model ("Previously accepted completion: …"). Only a
//! positively identified document learns: a Google Docs document in a
//! browser, by its address. Mail, chat, code editors, terminals and unknown
//! documents neither learn nor reuse examples, and neither do suggestions
//! that used saved facts or the text above the field. macOS keeps the
//! examples encrypted on disk for 30 days; here they stay in memory and go
//! when LokalBot quits.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use sha2::{Digest as _, Sha256};

use super::normalize::looks_like_prompt_scaffolding;
use super::surface::{self, SurfaceClass};
use super::text::is_control;

const MAX_ACCEPTED_CHARACTERS: usize = 240;
const MAX_PREFIX_CHARACTERS: usize = 180;
const MAX_CONTEXT_CHARACTERS: usize = 180;
const MINIMUM_RANK_SCORE: usize = 5;
const MAX_EXAMPLES: usize = 500;
pub const RETENTION: Duration = Duration::from_secs(30 * 24 * 60 * 60);

/// Where an example was accepted.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Place {
    pub app_name: String,
    pub app_id: String,
    pub window_title: String,
    pub url: Option<String>,
    pub before: String,
}

impl Place {
    /// `CotypingLearningScope.key`: a hash of the browser and the document's
    /// stable address, or `None` when the document is not identified.
    pub fn scope_key(&self) -> Option<String> {
        if SurfaceClass::of(&self.app_id, &self.app_name) != SurfaceClass::Browser {
            return None;
        }
        let url = self.url.as_deref()?.trim();
        let rest = url.strip_prefix("https://docs.google.com/document/d/")?;
        let id = rest
            .split(['/', '?', '#'])
            .next()
            .filter(|id| !id.is_empty())?;
        let identity = format!("https://docs.google.com/document/d/{id}");
        let app = surface::normalized_app_id(&self.app_id);
        let digest = Sha256::digest(format!("{app}\u{1f}{identity}").as_bytes());
        Some(hex::encode(digest))
    }

    fn surface(&self) -> SurfaceClass {
        SurfaceClass::of(&self.app_id, &self.app_name)
    }

    fn can_learn(&self) -> bool {
        self.scope_key().is_some()
            && !matches!(
                self.surface(),
                SurfaceClass::CodeEditor
                    | SurfaceClass::Terminal
                    | SurfaceClass::Email
                    | SurfaceClass::Chat
            )
    }

    fn context_hint(&self) -> Option<String> {
        let surface = surface::compose(&self.app_name, &self.app_id, &self.window_title)?;
        clean(
            &surface::preface_lines(&surface).join(" "),
            MAX_CONTEXT_CHARACTERS,
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
struct Example {
    created: Instant,
    app_name: String,
    app_id: String,
    surface: SurfaceClass,
    context_hint: Option<String>,
    prefix_tail: String,
    accepted: String,
    scope: String,
}

/// The examples, in memory only.
#[derive(Default)]
pub struct LearningStore {
    examples: Vec<Example>,
}

impl LearningStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn len(&self) -> usize {
        self.examples.len()
    }

    pub fn is_empty(&self) -> bool {
        self.examples.is_empty()
    }

    /// One finished suggestion's accepted text (`recordCompletedSuggestion`).
    pub fn record(&mut self, place: &Place, accepted: &str, now: Instant) {
        self.prune(now);
        let (true, Some(scope), Some(accepted)) = (
            place.can_learn(),
            place.scope_key(),
            accepted_text(accepted),
        ) else {
            return;
        };
        self.examples.push(Example {
            created: now,
            app_name: place.app_name.clone(),
            app_id: surface::normalized_app_id(&place.app_id),
            surface: place.surface(),
            context_hint: place.context_hint(),
            prefix_tail: prefix_tail(&place.before).unwrap_or_default(),
            accepted,
            scope,
        });
        if self.examples.len() > MAX_EXAMPLES {
            let excess = self.examples.len() - MAX_EXAMPLES;
            self.examples.drain(..excess);
        }
    }

    /// `rankedExamples`: the same document's examples whose context shares
    /// words with what is being written, best first.
    pub fn examples(&mut self, place: &Place, limit: usize, now: Instant) -> Vec<String> {
        self.prune(now);
        let Some(scope) = place.scope_key().filter(|_| place.can_learn() && limit > 0) else {
            return Vec::new();
        };
        let app_id = surface::normalized_app_id(&place.app_id);
        let prefix_terms = terms(&place.before);
        let context_terms = place.context_hint().map(|h| terms(&h)).unwrap_or_default();
        let mut ranked: Vec<(usize, Instant, String)> = self
            .examples
            .iter()
            .filter(|e| e.scope == scope && !app_id.is_empty() && e.app_id == app_id)
            .filter_map(|e| {
                let text = accepted_text(&e.accepted)?;
                let overlap = prefix_terms.intersection(&terms(&e.prefix_tail)).count();
                if overlap < 2 {
                    return None;
                }
                let mut score = 8 + overlap.min(5);
                if e.surface == place.surface() {
                    score += 3;
                }
                if let Some(hint) = &e.context_hint {
                    score += context_terms.intersection(&terms(hint)).count().min(4);
                }
                if e.app_name
                    .trim()
                    .eq_ignore_ascii_case(place.app_name.trim())
                {
                    score += 2;
                }
                (score >= MINIMUM_RANK_SCORE).then_some((score, e.created, text))
            })
            .collect();
        ranked.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)));
        let mut seen = HashSet::new();
        ranked
            .into_iter()
            .map(|(_, _, text)| text)
            .filter(|text| seen.insert(text.to_lowercase()))
            .take(limit)
            .collect()
    }

    /// "Forget learned text".
    pub fn clear(&mut self) {
        self.examples.clear();
    }

    fn prune(&mut self, now: Instant) {
        self.examples
            .retain(|e| now.saturating_duration_since(e.created) < RETENTION);
    }
}

/// The accepted chunks of one shown suggestion, learned as one example once
/// it is done (`CotypingAcceptedSuggestionBatch`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AcceptedBatch {
    place: Option<Place>,
    text: String,
}

impl AcceptedBatch {
    /// `learn` is false for suggestions that used saved facts or nearby text.
    pub fn append(&mut self, place: &Place, accepted: &str, learn: bool) {
        if accepted.is_empty() || !learn {
            return;
        }
        if self.place.is_none() {
            self.place = Some(place.clone());
        }
        self.text.push_str(accepted);
    }

    pub fn discard(&mut self) {
        *self = Self::default();
    }

    /// The example to learn, once; the batch is empty afterwards.
    pub fn complete(&mut self) -> Option<(Place, String)> {
        let batch = std::mem::take(self);
        batch.place.map(|place| (place, batch.text))
    }
}

fn accepted_text(text: &str) -> Option<String> {
    let cleaned = clean(text, MAX_ACCEPTED_CHARACTERS)?;
    (cleaned.chars().count() >= 3 && !looks_like_prompt_scaffolding(&cleaned)).then_some(cleaned)
}

fn prefix_tail(text: &str) -> Option<String> {
    let count = text.chars().count();
    let tail: String = text
        .chars()
        .skip(count.saturating_sub(MAX_PREFIX_CHARACTERS))
        .collect();
    clean(&tail, MAX_PREFIX_CHARACTERS)
}

fn clean(text: &str, max_characters: usize) -> Option<String> {
    let replaced: String = text
        .chars()
        .map(|c| if is_control(c) { ' ' } else { c })
        .collect();
    let collapsed = replaced.split_whitespace().collect::<Vec<_>>().join(" ");
    (!collapsed.is_empty()).then(|| collapsed.chars().take(max_characters).collect())
}

fn terms(text: &str) -> HashSet<String> {
    const SKIP: [&str; 8] = ["the", "and", "for", "that", "this", "with", "you", "your"];
    text.to_lowercase()
        .split(|c: char| !super::text::is_word_char(c))
        .filter(|w| w.chars().count() >= 3 && !SKIP.contains(w))
        .map(str::to_string)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(before: &str) -> Place {
        Place {
            app_name: "Firefox".into(),
            app_id: "firefox".into(),
            window_title: "Q3 plan - Google Docs — Mozilla Firefox".into(),
            url: Some("https://docs.google.com/document/d/abc123/edit?tab=t.0".into()),
            before: before.into(),
        }
    }

    #[test]
    fn only_identified_documents_have_a_scope() {
        assert!(doc("x").scope_key().is_some());
        let same = Place {
            url: Some("https://docs.google.com/document/d/abc123/".into()),
            ..doc("y")
        };
        assert_eq!(doc("x").scope_key(), same.scope_key());
        let other = Place {
            url: Some("https://docs.google.com/document/d/other/edit".into()),
            ..doc("x")
        };
        assert_ne!(doc("x").scope_key(), other.scope_key());
        for url in [
            None,
            Some("https://mail.google.com/mail/u/0"),
            Some("http://docs.google.com/document/d/abc123"),
        ] {
            let place = Place {
                url: url.map(String::from),
                ..doc("x")
            };
            assert_eq!(place.scope_key(), None, "{url:?}");
        }
        let native = Place {
            app_name: "Writer".into(),
            app_id: "soffice".into(),
            ..doc("x")
        };
        assert_eq!(native.scope_key(), None);
    }

    #[test]
    fn examples_are_ranked_by_shared_context_in_the_same_document() {
        let now = Instant::now();
        let mut store = LearningStore::new();
        let before = "The quarterly revenue review showed churn in the enterprise segment, so";
        store.record(
            &doc(before),
            " we should prioritize the retention playbook",
            now,
        );
        store.record(&doc("Unrelated grocery list"), " eggs and flour", now);
        // Prompt scaffolding and tiny texts are never learned.
        store.record(&doc(before), "Previously accepted completion: x", now);
        store.record(&doc(before), "ok", now);
        assert_eq!(store.len(), 2);
        let examples = store.examples(&doc("For the enterprise segment the revenue churn"), 3, now);
        assert_eq!(examples, ["we should prioritize the retention playbook"]);
        let other = Place {
            url: Some("https://docs.google.com/document/d/other/edit".into()),
            ..doc("For the enterprise segment the revenue churn")
        };
        assert!(store.examples(&other, 3, now).is_empty());
        assert!(
            store
                .examples(&doc("enterprise revenue churn"), 3, now + RETENTION)
                .is_empty()
        );
        store.record(&doc(before), " again", now);
        store.clear();
        assert!(store.is_empty());
    }

    #[test]
    fn a_batch_learns_once_and_only_when_allowed() {
        let mut batch = AcceptedBatch::default();
        batch.append(&doc("x"), " up", true);
        batch.append(&doc("x y"), " on", true);
        assert_eq!(batch.complete(), Some((doc("x"), " up on".to_string())));
        assert_eq!(batch.complete(), None);
        batch.append(&doc("x"), " up", false);
        assert_eq!(batch.complete(), None);
        batch.append(&doc("x"), " up", true);
        batch.discard();
        assert_eq!(batch.complete(), None);
    }
}
