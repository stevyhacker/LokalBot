//! Learning from accepted suggestions (`CotypingLearningStore`,
//! `CotypingLearningRanker`, `CotypingLearningScope`,
//! `CotypingAcceptedSuggestionBatch`).
//!
//! An accepted suggestion becomes an example that later prompts in the same
//! document can show the model ("Previously accepted completion: …"). Only a
//! positively identified document learns: a Google Docs document in a
//! browser, by its address. Mail, chat, code editors, terminals and unknown
//! documents neither learn nor reuse examples, and neither do suggestions
//! that used saved facts or the text above the field. Examples are kept for
//! 30 days; the engine seals them on disk in the Mac's format.

use std::collections::HashSet;

use chrono::{DateTime, Duration, Utc};
use lokalbot_core::time::swift_date;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use uuid::Uuid;

use super::normalize::looks_like_prompt_scaffolding;
use super::surface::{self, SurfaceClass};
use super::text::is_control;

/// `<root>/cotyping-learning.enc`: this JSON sealed with AES-256-GCM as
/// `nonce ‖ ciphertext ‖ tag`.
pub const FILE_NAME: &str = "cotyping-learning.enc";

const MAX_ACCEPTED_CHARACTERS: usize = 240;
const MAX_PREFIX_CHARACTERS: usize = 180;
const MAX_CONTEXT_CHARACTERS: usize = 180;
const MINIMUM_RANK_SCORE: usize = 5;
const MAX_EXAMPLES: usize = 500;
pub const RETENTION_DAYS: i64 = 30;

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

/// One learned example (`CotypingLearningExample`). Keys and encoding match
/// the Mac: `createdAt` is seconds since 2001, UUIDs are uppercase, and empty
/// optionals are left out.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Example {
    #[serde(with = "uppercase_uuid")]
    pub id: Uuid,
    #[serde(with = "swift_date")]
    pub created_at: DateTime<Utc>,
    pub app_name: String,
    #[serde(rename = "bundleID", default, skip_serializing_if = "Option::is_none")]
    pub bundle_id: Option<String>,
    pub surface_class: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_hint: Option<String>,
    pub prefix_tail: String,
    pub accepted_text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope_key: Option<String>,
}

mod uppercase_uuid {
    use serde::{Deserialize as _, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(value: &Uuid, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&value.to_string().to_uppercase())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Uuid, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Uuid::parse_str(&raw).map_err(serde::de::Error::custom)
    }
}

/// `CotypingLearningSnapshot`: the file's JSON, with no version wrapper.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    #[serde(default)]
    pub examples: Vec<Example>,
}

fn is_retained(example: &Example, now: DateTime<Utc>) -> bool {
    example.scope_key.as_deref().is_some_and(|k| !k.is_empty())
        && example.created_at <= now
        && now - example.created_at < Duration::days(RETENTION_DAYS)
}

fn same_bundle(a: Option<&str>, b: &str) -> bool {
    a.is_some_and(|a| !a.is_empty() && !b.is_empty() && a.eq_ignore_ascii_case(b))
}

/// The examples in memory. The engine loads and saves them.
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

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            examples: self.examples.clone(),
        }
    }

    /// Adds what the file held, before anything learned while it opened.
    pub fn merge_loaded(&mut self, snapshot: Snapshot, now: DateTime<Utc>) {
        let mut examples = snapshot.examples;
        examples.append(&mut self.examples);
        self.examples = examples;
        self.trim();
        self.prune(now);
    }

    /// One finished suggestion's accepted text (`recordCompletedSuggestion`).
    /// True when the store changed and should be saved.
    pub fn record(&mut self, place: &Place, accepted: &str, now: DateTime<Utc>) -> bool {
        let pruned = self.prune(now);
        let (true, Some(scope), Some(accepted)) = (
            place.can_learn(),
            place.scope_key(),
            accepted_text(accepted),
        ) else {
            return pruned;
        };
        self.examples.push(Example {
            id: Uuid::new_v4(),
            created_at: now,
            app_name: place.app_name.clone(),
            bundle_id: Some(surface::normalized_app_id(&place.app_id)),
            surface_class: place.surface().raw_name().to_string(),
            context_hint: place.context_hint(),
            prefix_tail: prefix_tail(&place.before).unwrap_or_default(),
            accepted_text: accepted,
            scope_key: Some(scope),
        });
        self.trim();
        true
    }

    /// `rankedExamples`: the same document's examples whose context shares
    /// words with what is being written, best first.
    pub fn examples(&self, place: &Place, limit: usize, now: DateTime<Utc>) -> Vec<String> {
        let Some(scope) = place.scope_key().filter(|_| place.can_learn() && limit > 0) else {
            return Vec::new();
        };
        let app_id = surface::normalized_app_id(&place.app_id);
        let surface_class = place.surface().raw_name();
        let prefix_terms = terms(&place.before);
        let context_terms = place.context_hint().map(|h| terms(&h)).unwrap_or_default();
        let mut ranked: Vec<(usize, DateTime<Utc>, String)> = self
            .examples
            .iter()
            .filter(|e| {
                e.scope_key.as_deref() == Some(scope.as_str())
                    && same_bundle(e.bundle_id.as_deref(), &app_id)
                    && is_retained(e, now)
            })
            .filter_map(|e| {
                let text = accepted_text(&e.accepted_text)?;
                let overlap = prefix_terms.intersection(&terms(&e.prefix_tail)).count();
                if overlap < 2 {
                    return None;
                }
                let mut score = 8 + overlap.min(5);
                if e.surface_class == surface_class {
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
                (score >= MINIMUM_RANK_SCORE).then_some((score, e.created_at, text))
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

    /// "Forget learned text", or autocomplete turning off.
    pub fn clear(&mut self) {
        self.examples.clear();
    }

    /// True when expired examples went, so the file should be saved.
    pub fn prune(&mut self, now: DateTime<Utc>) -> bool {
        let before = self.examples.len();
        self.examples.retain(|e| is_retained(e, now));
        self.examples.len() != before
    }

    fn trim(&mut self) {
        if self.examples.len() > MAX_EXAMPLES {
            let excess = self.examples.len() - MAX_EXAMPLES;
            self.examples.drain(..excess);
        }
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
    /// `learn` is false when learning is off, and for suggestions that used
    /// saved facts or nearby text.
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
        let now = Utc::now();
        let mut store = LearningStore::new();
        let before = "The quarterly revenue review showed churn in the enterprise segment, so";
        store.record(
            &doc(before),
            " we should prioritize the retention playbook",
            now,
        );
        store.record(&doc("Unrelated grocery list"), " eggs and flour", now);
        // Prompt scaffolding and tiny texts are never learned.
        assert!(!store.record(&doc(before), "Previously accepted completion: x", now));
        assert!(!store.record(&doc(before), "ok", now));
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
                .examples(
                    &doc("enterprise revenue churn"),
                    3,
                    now + Duration::days(RETENTION_DAYS)
                )
                .is_empty()
        );
        store.record(&doc(before), " again", now);
        store.clear();
        assert!(store.is_empty());
    }

    #[test]
    fn the_macs_encoding_reads_and_writes_back_the_same() {
        // From `CotypingLearningExample`'s `Codable`: a default `JSONEncoder`
        // date is seconds since 2001-01-01, and a nil optional is left out.
        let json = r#"{"examples":[{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","createdAt":815000000.5,"appName":"Firefox","bundleID":"firefox","surfaceClass":"browser","contextHint":"Topic: Q3 plan","prefixTail":"we should","acceptedText":"prioritize retention","scopeKey":"abc"},{"id":"16FD2706-8BAF-433B-82EB-8C7FADA847DA","createdAt":815000001.25,"appName":"Word","surfaceClass":"other","prefixTail":"","acceptedText":"thanks"}]}"#;
        let snapshot: Snapshot = serde_json::from_str(json).unwrap();
        assert_eq!(snapshot.examples[0].bundle_id.as_deref(), Some("firefox"));
        assert_eq!(snapshot.examples[0].created_at.timestamp(), 1_793_307_200);
        assert_eq!(snapshot.examples[1].scope_key, None);
        assert_eq!(serde_json::to_string(&snapshot).unwrap(), json);
    }

    #[test]
    fn expired_and_future_examples_go_when_loaded() {
        let now = Utc::now();
        let example = |created_at| Example {
            id: Uuid::new_v4(),
            created_at,
            app_name: "Firefox".into(),
            bundle_id: Some("firefox".into()),
            surface_class: "browser".into(),
            context_hint: None,
            prefix_tail: "a b c".into(),
            accepted_text: "kept text".into(),
            scope_key: Some("k".into()),
        };
        let mut store = LearningStore::new();
        store.merge_loaded(
            Snapshot {
                examples: vec![
                    example(now),
                    example(now - Duration::days(RETENTION_DAYS)),
                    example(now + Duration::hours(1)),
                ],
            },
            now,
        );
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn the_store_keeps_the_newest_five_hundred() {
        let now = Utc::now();
        let mut store = LearningStore::new();
        for index in 0..510 {
            assert!(store.record(&doc("x"), &format!("number {index}"), now));
        }
        assert_eq!(store.len(), MAX_EXAMPLES);
        assert_eq!(store.snapshot().examples[0].accepted_text, "number 10");
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
