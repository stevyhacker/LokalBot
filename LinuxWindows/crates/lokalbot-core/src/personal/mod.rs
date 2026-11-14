//! Personal Context (`Services/PersonalModel/*`, `CLISupport/PersonalContextAccess.swift`):
//! what the person told LokalBot about themselves, and what it learned from their
//! own words. Saved claims are the person's; learned ones carry the source they
//! came from and retract with it. Principles are never learned.
//!
//! `memory/personal-model.json.enc` is private by default. Ask and Quick Recall
//! read it; external agents get only items marked for them, through the plaintext
//! copy in `control/personal-context.json`, and only while that grant is on.
//! Agent Mode, Autocomplete, notes, exports and diagnostics never read it.

pub mod access;
pub mod controller;
pub mod dictation_log;
pub mod learning;
pub mod promotion;

#[cfg(test)]
mod tests;

use std::collections::HashSet;

use anyhow::Result;
use chrono::{DateTime, Duration, Local, Utc};
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization as _;
use uuid::Uuid;

use crate::evidence::Provenance;
use crate::ids::{self, uuid_upper_serde};
use crate::library::sha256_hex;
use crate::text::{redaction, sanitize};
use crate::time::iso_seconds;

pub use controller::Personal;

pub const MODEL_VERSION: i32 = 1;
pub const MAX_CLAIMS: usize = 300;
pub const MAX_CHARACTERS: usize = 280;
pub const MAX_PROPOSALS: usize = 20;
const PROPOSAL_LIFETIME_DAYS: i64 = 14;
const TOMBSTONE_LIFETIME_DAYS: i64 = 180;
const LEARNED_DAY_LIFETIME_DAYS: i64 = 60;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClaimKind {
    Fact,
    Preference,
    Goal,
    Principle,
}

impl ClaimKind {
    pub const ALL: [Self; 4] = [Self::Fact, Self::Preference, Self::Goal, Self::Principle];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Fact => "fact",
            Self::Preference => "preference",
            Self::Goal => "goal",
            Self::Principle => "principle",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Fact => lokalbot_i18n::tr("Fact"),
            Self::Preference => lokalbot_i18n::tr("Preference"),
            Self::Goal => lokalbot_i18n::tr("Goal"),
            Self::Principle => lokalbot_i18n::tr("Principle"),
        }
    }

    pub fn group_title(self) -> &'static str {
        match self {
            Self::Fact => lokalbot_i18n::tr("Facts"),
            Self::Preference => lokalbot_i18n::tr("Preferences"),
            Self::Goal => lokalbot_i18n::tr("Goals"),
            Self::Principle => lokalbot_i18n::tr("Principles"),
        }
    }

    pub fn placeholder(self) -> &'static str {
        match self {
            Self::Fact => "Maya Chen is my manager.",
            Self::Preference => "Answer in bullet points, amounts in EUR.",
            Self::Goal => "Ship LokalBot 1.0 this year.",
            Self::Principle => "I don't take work that requires relocating my family.",
        }
    }

    /// A starting kind for a statement typed in Ask. Only obvious English
    /// openings are recognized; principles are never guessed.
    pub fn suggested(text: &str) -> Self {
        let lowered = text.to_lowercase();
        const PREFERENCE: [&str; 10] = [
            "i prefer",
            "i like",
            "i don't like",
            "i do not like",
            "i dislike",
            "answer in",
            "reply in",
            "respond in",
            "always answer",
            "use ",
        ];
        if PREFERENCE.iter().any(|p| lowered.starts_with(p)) {
            return Self::Preference;
        }
        const GOAL: [&str; 7] = [
            "my goal",
            "i want to",
            "i'm working toward",
            "i am working toward",
            "i'm trying to",
            "i am trying to",
            "i plan to",
        ];
        if GOAL.iter().any(|p| lowered.starts_with(p)) {
            return Self::Goal;
        }
        Self::Fact
    }
}

/// Where a claim came from. Swift encodes these as `{"case":{...}}`, with `{}`
/// for a case without fields.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Origin {
    /// "Remember …" typed in Ask or Quick Recall.
    Said {
        #[serde(rename = "conversationID", with = "uuid_upper_serde")]
        conversation_id: Uuid,
        #[serde(rename = "messageID", with = "uuid_upper_serde")]
        message_id: Uuid,
    },
    /// Added in Settings → About you.
    Added {},
    /// Picked up overnight from the person's own line in this meeting.
    Learned {
        #[serde(rename = "meetingID", with = "uuid_upper_serde")]
        meeting_id: Uuid,
        #[serde(rename = "dayKey")]
        day_key: String,
    },
    /// Picked up overnight from something the person typed that day.
    Typed {
        source: TypedSource,
        #[serde(rename = "dayKey")]
        day_key: String,
    },
    /// A goal or project the review kept for weeks; the day it was first seen.
    WorkMemory {
        #[serde(rename = "dayKey")]
        day_key: String,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TypedSource {
    /// A request to Claude Code or Codex, saved by Read coding agent sessions.
    CodingAgent { name: String },
    /// A question asked in Ask or Quick Recall.
    Ask {
        #[serde(rename = "conversationID", with = "uuid_upper_serde")]
        conversation_id: Uuid,
    },
    /// Words dictated into another app, kept only until the night's pass.
    Dictation { app: String },
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Sharing {
    /// Ask and Quick Recall only. The default for every claim.
    #[default]
    LokalBotOnly,
    /// Also external agents, while the Personal context grant is on.
    Agents,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Status {
    /// In use by Ask and, if shared, agents.
    #[default]
    Confirmed,
    /// A learned suggestion waiting for review; never used.
    Proposed,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Authority {
    /// The person stated it or kept it as their own statement.
    #[default]
    Stated,
    /// Saved automatically from what the person said in a meeting.
    Learned,
    /// Learned, then confirmed by the person in review.
    Confirmed,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Claim {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub kind: ClaimKind,
    pub text: String,
    pub origin: Origin,
    /// Included first in every eligible prompt, ahead of relevance ranking.
    #[serde(default)]
    pub always_use: bool,
    #[serde(default)]
    pub sharing: Sharing,
    #[serde(default)]
    pub status: Status,
    #[serde(default)]
    pub authority: Authority,
    /// What a learned claim came from. `None` means no evidence dependency.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence: Option<Provenance>,
    /// The person's own line the claim was learned from, shown in review.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quote: Option<String>,
    #[serde(with = "iso_seconds")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "iso_seconds")]
    pub updated_at: DateTime<Utc>,
    #[serde(
        default,
        with = "iso_seconds::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_used_at: Option<DateTime<Utc>>,
}

impl Claim {
    fn new(kind: ClaimKind, text: String, origin: Origin, now: DateTime<Utc>) -> Self {
        Self {
            id: Uuid::new_v4(),
            kind,
            text,
            origin,
            always_use: false,
            sharing: Sharing::LokalBotOnly,
            status: Status::Confirmed,
            authority: Authority::Stated,
            evidence: None,
            quote: None,
            created_at: now,
            updated_at: now,
            last_used_at: None,
        }
    }

    /// Learned automatically rather than stated.
    pub fn is_learned(&self) -> bool {
        matches!(
            self.origin,
            Origin::Learned { .. } | Origin::Typed { .. } | Origin::WorkMemory { .. }
        )
    }

    /// Dictated words are gone once read, so nothing can retract the item.
    pub fn has_removable_source(&self) -> bool {
        !matches!(
            self.origin,
            Origin::Typed {
                source: TypedSource::Dictation { .. },
                ..
            }
        )
    }

    /// `PersonalContextSettings.keepLabel`.
    pub fn keep_label(&self) -> &'static str {
        match &self.origin {
            Origin::Learned { .. } => lokalbot_i18n::tr("Keep Even If the Meeting Is Deleted"),
            Origin::Typed {
                source: TypedSource::Ask { .. },
                ..
            } => lokalbot_i18n::tr("Keep Even If the Conversation Is Deleted"),
            _ => lokalbot_i18n::tr("Keep Even If the Source Is Deleted"),
        }
    }

    /// `PersonalContextProjection.Claim`'s source string.
    pub fn projection_source(&self) -> &'static str {
        let stated = self.authority == Authority::Stated;
        match &self.origin {
            Origin::Said { .. } => "asked_to_remember",
            Origin::Added {} => "added_in_settings",
            _ if stated => "added_in_settings",
            Origin::Learned { .. } => "learned_from_meeting",
            Origin::Typed {
                source: TypedSource::Dictation { .. },
                ..
            } => "learned_from_dictation",
            Origin::Typed { .. } => "learned_from_typing",
            Origin::WorkMemory { .. } => "learned_from_work_memory",
        }
    }
}

/// `PersonalContextSelection`'s view of an item, so the app (all claims) and the
/// CLI (the shared copy) rank with the same rules.
pub trait ContextItem {
    fn id(&self) -> Uuid;
    fn kind(&self) -> &str;
    fn text(&self) -> &str;
    fn updated_at(&self) -> DateTime<Utc>;
    fn always_use(&self) -> bool;
}

impl ContextItem for Claim {
    fn id(&self) -> Uuid {
        self.id
    }
    fn kind(&self) -> &str {
        self.kind.as_str()
    }
    fn text(&self) -> &str {
        &self.text
    }
    fn updated_at(&self) -> DateTime<Utc> {
        self.updated_at
    }
    fn always_use(&self) -> bool {
        self.always_use
    }
}

const STOPWORDS: &[&str] = &[
    "the", "and", "for", "are", "but", "not", "you", "your", "with", "that", "this", "have", "has",
    "had", "was", "were", "will", "would", "should", "could", "what", "when", "where", "which",
    "who", "whom", "why", "how", "about", "from", "into", "than", "then", "them", "they", "their",
    "there", "these", "those", "our", "out", "can", "did", "does", "doing", "just", "like", "more",
    "most", "some", "such", "only", "also", "very", "too", "any", "all", "its", "it's", "i'm",
    "myself", "mine", "me", "my", "his", "her", "him", "she", "one", "get", "got", "let", "make",
    "made", "want", "need", "tell", "know", "think", "remember", "please", "always", "never",
];

/// Case- and diacritic-folded words of three or more letters, minus stopwords.
/// Works for any script, so Serbian Latin and Cyrillic match themselves.
pub fn content_words(text: &str) -> HashSet<String> {
    ids::fold(text)
        .split(|c: char| !c.is_alphanumeric() && c != '\'')
        .map(|w| w.trim_matches('\''))
        .filter(|w| w.chars().count() >= 3 && !STOPWORDS.contains(w))
        .map(str::to_string)
        .collect()
}

/// `PersonalContextSelection.ordered`: always-use items, then principles and
/// preferences, then facts and goals sharing words with the query (most shared
/// first), then the rest; newest first within each step.
pub fn ordered<'a, Item: ContextItem>(
    items: &'a [Item],
    query: &str,
    recent_turns: &[String],
) -> Vec<&'a Item> {
    let mut query_words = content_words(query);
    let start = recent_turns.len().saturating_sub(2);
    for turn in &recent_turns[start..] {
        query_words.extend(content_words(turn));
    }
    let mut newest: Vec<&Item> = items.iter().collect();
    newest.sort_by(|a, b| {
        b.updated_at()
            .cmp(&a.updated_at())
            .then_with(|| ids::uuid_upper(&a.id()).cmp(&ids::uuid_upper(&b.id())))
    });
    let mut placed: HashSet<Uuid> = HashSet::new();
    let mut out: Vec<&Item> = Vec::new();
    for item in newest.iter().filter(|i| i.always_use()) {
        if placed.insert(item.id()) {
            out.push(item);
        }
    }
    for item in newest
        .iter()
        .filter(|i| i.kind() == "principle" || i.kind() == "preference")
    {
        if placed.insert(item.id()) {
            out.push(item);
        }
    }
    // A stable sort keeps newest first among ties.
    let mut matches: Vec<(&Item, usize)> = newest
        .iter()
        .filter(|i| !placed.contains(&i.id()))
        .map(|i| {
            (
                *i,
                content_words(i.text()).intersection(&query_words).count(),
            )
        })
        .filter(|(_, score)| *score > 0)
        .collect();
    matches.sort_by_key(|m| std::cmp::Reverse(m.1));
    for (item, _) in matches {
        if placed.insert(item.id()) {
            out.push(item);
        }
    }
    for item in newest {
        if placed.insert(item.id()) {
            out.push(item);
        }
    }
    out
}

/// Why an item can't be kept. Over-long text is refused rather than cut: a cut
/// sentence can drop a negation.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum EditError {
    #[error("There's nothing to remember.")]
    Empty,
    #[error(
        "That's {0} characters. LokalBot remembers up to {MAX_CHARACTERS}; shorten it and try again."
    )]
    TooLong(usize),
    #[error(
        "LokalBot already remembers {MAX_CLAIMS} things about you. Forget some in Settings → About you first."
    )]
    Full,
    #[error("This looks like a password, key, or card number. LokalBot doesn't remember those.")]
    LooksSecret,
    #[error("That item was already forgotten.")]
    NotFound,
    #[error("LokalBot couldn't open what it remembers about you, so it won't change it now.")]
    Unavailable,
}

impl EditError {
    pub fn message(&self) -> String {
        match self {
            Self::Empty => lokalbot_i18n::tr("There's nothing to remember.").into(),
            Self::TooLong(count) => lokalbot_i18n::format(
                "That's {0} characters. LokalBot remembers up to {1}; shorten it and try again.",
                &[("0", count.to_string()), ("1", MAX_CHARACTERS.to_string())],
            ),
            Self::Full => lokalbot_i18n::format(
                "LokalBot already remembers {0} things about you. Forget some in Settings → About you first.",
                &[("0", MAX_CLAIMS.to_string())],
            ),
            Self::LooksSecret => lokalbot_i18n::tr(
                "This looks like a password, key, or card number. LokalBot doesn't remember those.",
            )
            .into(),
            Self::NotFound => lokalbot_i18n::tr("That item was already forgotten.").into(),
            Self::Unavailable => lokalbot_i18n::tr(
                "LokalBot couldn't open what it remembers about you, so it won't change it now.",
            )
            .into(),
        }
    }
}

/// A forgotten learned claim or a dismissed suggestion, as a one-way hash.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tombstone {
    pub key: String,
    #[serde(with = "iso_seconds")]
    pub created_at: DateTime<Utc>,
}

/// When a work-memory item was first seen, as a hash of its text.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkSighting {
    pub key: String,
    pub first_day_key: String,
}

/// A day the learning pass read, and a hash of the lines it read.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LearnedDay {
    pub day_key: String,
    pub fingerprint: String,
    #[serde(with = "iso_seconds")]
    pub learned_at: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LearningCandidate {
    pub kind: ClaimKind,
    pub text: String,
    /// The person's own words it came from; `None` for work memory.
    pub quote: Option<String>,
    pub origin: Origin,
    /// `None` only for Ask questions, which retract with their conversation.
    pub evidence: Option<Provenance>,
    /// From typing, work memory, or grounded only by meaning across languages:
    /// even a fact or goal waits for review.
    pub needs_review: bool,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct LearningOutcome {
    pub saved: Vec<Claim>,
    pub proposed: Vec<Claim>,
    pub skipped: usize,
}

/// The person's claims plus the rules every edit goes through.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PersonalModel {
    pub version: i32,
    pub claims: Vec<Claim>,
    pub tombstones: Vec<Tombstone>,
    pub work_sightings: Vec<WorkSighting>,
    pub learned_days: Vec<LearnedDay>,
}

impl Default for PersonalModel {
    fn default() -> Self {
        Self {
            version: MODEL_VERSION,
            claims: Vec::new(),
            tombstones: Vec::new(),
            work_sightings: Vec::new(),
            learned_days: Vec::new(),
        }
    }
}

/// Case-, width- and diacritic-insensitive key used to merge duplicates.
pub fn duplicate_key(text: &str) -> String {
    let wide: String = text.nfkd().collect();
    let mut key = ids::fold(&wide);
    while key.ends_with('.') {
        key.pop();
    }
    key
}

pub fn tombstone_key(text: &str) -> String {
    sha256_hex(duplicate_key(text).as_bytes())
}

/// Prompt-safe text, or why it can't be kept.
pub fn validated_text(raw: &str) -> Result<String, EditError> {
    let text = sanitize(raw, None);
    if text.is_empty() {
        return Err(EditError::Empty);
    }
    let count = text.chars().count();
    if count > MAX_CHARACTERS {
        return Err(EditError::TooLong(count));
    }
    if redaction(&text).1 > 0 {
        return Err(EditError::LooksSecret);
    }
    Ok(text)
}

/// The same thing reworded: most content words of the shorter text appear in
/// the other. Models restate known items despite being told not to.
pub fn is_near_duplicate(lhs: &str, rhs: &str) -> bool {
    let left = content_words(lhs);
    let right = content_words(rhs);
    let smaller = left.len().min(right.len());
    if smaller == 0 {
        return false;
    }
    left.intersection(&right).count() as f64 / smaller as f64 >= 0.7
}

impl PersonalModel {
    pub fn has_learned(&self, day_key: &str, fingerprint: &str) -> bool {
        self.learned_days
            .iter()
            .any(|d| d.day_key == day_key && d.fingerprint == fingerprint)
    }

    pub fn record_learned(&mut self, day_key: &str, fingerprint: &str, at: DateTime<Utc>) {
        self.learned_days.retain(|d| d.day_key != day_key);
        self.learned_days.push(LearnedDay {
            day_key: day_key.to_string(),
            fingerprint: fingerprint.to_string(),
            learned_at: at,
        });
    }

    /// Adds a claim, or refreshes the one with the same text. Saved claims are
    /// never evicted to make room.
    pub fn add(
        &mut self,
        raw: &str,
        kind: ClaimKind,
        origin: Origin,
        now: DateTime<Utc>,
    ) -> Result<Claim, EditError> {
        let text = validated_text(raw)?;
        let key = duplicate_key(&text);
        if let Some(existing) = self
            .claims
            .iter_mut()
            .find(|c| duplicate_key(&c.text) == key)
        {
            // Saying what LokalBot learned makes it the person's statement.
            if existing.is_learned() {
                existing.status = Status::Confirmed;
                existing.authority = Authority::Stated;
                existing.evidence = None;
            }
            existing.updated_at = now;
            return Ok(existing.clone());
        }
        if self.confirmed_count() >= MAX_CLAIMS {
            return Err(EditError::Full);
        }
        let claim = Claim::new(kind, text, origin, now);
        self.claims.push(claim.clone());
        Ok(claim)
    }

    fn confirmed_count(&self) -> usize {
        self.claims
            .iter()
            .filter(|c| c.status == Status::Confirmed)
            .count()
    }

    pub fn update(
        &mut self,
        id: Uuid,
        edit: ClaimEdit,
        now: DateTime<Utc>,
    ) -> Result<Claim, EditError> {
        let mut claim = self
            .claims
            .iter()
            .find(|c| c.id == id)
            .cloned()
            .ok_or(EditError::NotFound)?;
        if let Some(raw) = &edit.text {
            claim.text = validated_text(raw)?;
            let key = duplicate_key(&claim.text);
            // Editing into another claim merges them: the edited one stays.
            self.claims
                .retain(|c| c.id == id || duplicate_key(&c.text) != key);
        }
        if let Some(kind) = edit.kind {
            claim.kind = kind;
        }
        if let Some(always) = edit.always_use {
            claim.always_use = always;
        }
        if let Some(sharing) = edit.sharing {
            claim.sharing = sharing;
        }
        claim.updated_at = now;
        let current = self
            .claims
            .iter_mut()
            .find(|c| c.id == id)
            .ok_or(EditError::NotFound)?;
        *current = claim.clone();
        Ok(claim)
    }

    /// Forgetting a learned claim leaves a tombstone so tomorrow's review
    /// doesn't learn it again; stated claims leave nothing behind.
    pub fn remove(&mut self, ids: &HashSet<Uuid>, now: DateTime<Utc>) {
        for claim in &self.claims {
            if ids.contains(&claim.id) && claim.is_learned() && claim.authority != Authority::Stated
            {
                self.tombstones.push(Tombstone {
                    key: tombstone_key(&claim.text),
                    created_at: now,
                });
            }
        }
        self.claims.retain(|c| !ids.contains(&c.id));
    }

    /// Source deletion or correction: the claim goes, with no tombstone, so it
    /// can be learned again from evidence that still exists.
    pub fn retract(&mut self, ids: &HashSet<Uuid>) {
        self.claims.retain(|c| !ids.contains(&c.id));
    }

    /// Deleting an Ask conversation takes back what was learned from the
    /// questions in it, unless the person kept it as their own statement.
    pub fn retract_learned_from_conversation(&mut self, conversation_id: Uuid) {
        self.claims.retain(|claim| {
            let from_it = matches!(
                &claim.origin,
                Origin::Typed { source: TypedSource::Ask { conversation_id: id }, .. }
                    if *id == conversation_id
            );
            !(from_it && claim.authority != Authority::Stated)
        });
    }

    /// The source changed but still has the line a claim quotes: tie the claim
    /// to the current revision instead of retracting it.
    pub fn refresh_evidence(&mut self, ids: &HashSet<Uuid>, revision: u64) {
        for claim in &mut self.claims {
            if ids.contains(&claim.id)
                && let Some(evidence) = &mut claim.evidence
            {
                evidence.revision = revision;
            }
        }
    }

    /// Facts and goals are saved and used at once; preferences, and items that
    /// need review, wait; principles are never learned. Duplicates, forgotten or
    /// dismissed text, invalid text and anything past the limits are skipped.
    pub fn learn(
        &mut self,
        candidates: &[LearningCandidate],
        now: DateTime<Utc>,
    ) -> LearningOutcome {
        let mut outcome = LearningOutcome::default();
        for candidate in candidates {
            let Some(text) = (candidate.kind != ClaimKind::Principle)
                .then(|| validated_text(&candidate.text).ok())
                .flatten()
            else {
                outcome.skipped += 1;
                continue;
            };
            let key = duplicate_key(&text);
            let tombstone = tombstone_key(&text);
            if self
                .claims
                .iter()
                .any(|c| duplicate_key(&c.text) == key || is_near_duplicate(&c.text, &text))
                || self.tombstones.iter().any(|t| t.key == tombstone)
            {
                outcome.skipped += 1;
                continue;
            }
            let proposes = candidate.kind == ClaimKind::Preference || candidate.needs_review;
            let limit_reached = if proposes {
                self.claims
                    .iter()
                    .filter(|c| c.status == Status::Proposed)
                    .count()
                    >= MAX_PROPOSALS
            } else {
                self.confirmed_count() >= MAX_CLAIMS
            };
            if limit_reached {
                outcome.skipped += 1;
                continue;
            }
            let mut claim = Claim::new(candidate.kind, text, candidate.origin.clone(), now);
            claim.status = if proposes {
                Status::Proposed
            } else {
                Status::Confirmed
            };
            claim.authority = Authority::Learned;
            claim.evidence = candidate.evidence.clone();
            claim.quote = candidate
                .quote
                .as_ref()
                .map(|q| sanitize(q, None).chars().take(400).collect());
            self.claims.push(claim.clone());
            if proposes {
                outcome.proposed.push(claim);
            } else {
                outcome.saved.push(claim);
            }
        }
        outcome
    }

    /// Review of a learned suggestion: keep it as confirmed.
    pub fn confirm(&mut self, id: Uuid, now: DateTime<Utc>) -> Result<Claim, EditError> {
        let claim = self
            .claims
            .iter_mut()
            .find(|c| c.id == id)
            .ok_or(EditError::NotFound)?;
        claim.status = Status::Confirmed;
        claim.authority = Authority::Confirmed;
        claim.updated_at = now;
        Ok(claim.clone())
    }

    /// The person vouches for a learned claim: it no longer depends on its source.
    pub fn keep_as_statement(&mut self, id: Uuid, now: DateTime<Utc>) -> Result<Claim, EditError> {
        let claim = self
            .claims
            .iter_mut()
            .find(|c| c.id == id)
            .ok_or(EditError::NotFound)?;
        claim.status = Status::Confirmed;
        claim.authority = Authority::Stated;
        claim.evidence = None;
        claim.updated_at = now;
        Ok(claim.clone())
    }

    /// Drops suggestions nobody reviewed and old tombstones.
    pub fn prune(&mut self, now: DateTime<Utc>) {
        self.claims.retain(|c| {
            !(c.status == Status::Proposed
                && now - c.created_at > Duration::days(PROPOSAL_LIFETIME_DAYS))
        });
        self.tombstones
            .retain(|t| now - t.created_at <= Duration::days(TOMBSTONE_LIFETIME_DAYS));
        self.learned_days
            .retain(|d| now - d.learned_at <= Duration::days(LEARNED_DAY_LIFETIME_DAYS));
    }

    pub fn mark_used(&mut self, ids: &HashSet<Uuid>, at: DateTime<Utc>) {
        for claim in &mut self.claims {
            if ids.contains(&claim.id) {
                claim.last_used_at = Some(at);
            }
        }
    }
}

/// What an edit changes; anything left `None` stays as it is.
#[derive(Clone, Debug, Default)]
pub struct ClaimEdit {
    pub text: Option<String>,
    pub kind: Option<ClaimKind>,
    pub always_use: Option<bool>,
    pub sharing: Option<Sharing>,
}

const REMEMBER_TRIGGERS: &[&str] = &[
    "please remember that ",
    "please remember: ",
    "please remember ",
    "remember that ",
    "remember: ",
    "remember:",
    "remember ",
    "molim te zapamti da ",
    "molim te zapamti ",
    "zapamti da ",
    "zapamti: ",
    "zapamti:",
    "zapamti ",
    "молим те запамти да ",
    "молим те запамти ",
    "запамти да ",
    "запамти: ",
    "запамти:",
    "запамти ",
];
/// After these a question word means the message asks about the past.
const QUESTION_CHECKED_TRIGGERS: &[&str] = &[
    "please remember ",
    "remember ",
    "molim te zapamti da ",
    "molim te zapamti ",
    "zapamti da ",
    "zapamti ",
    "молим те запамти да ",
    "молим те запамти ",
    "запамти да ",
    "запамти ",
];
const QUESTION_OPENINGS: &[&str] = &[
    "when",
    "what",
    "who",
    "whom",
    "whose",
    "where",
    "how",
    "why",
    "if",
    "whether",
    "which",
    "kad",
    "kada",
    "šta",
    "sta",
    "ko",
    "koga",
    "gde",
    "kako",
    "zašto",
    "zasto",
    "li",
    "koji",
    "koja",
    "кад",
    "када",
    "шта",
    "ко",
    "кога",
    "где",
    "како",
    "зашто",
    "ли",
    "који",
    "која",
];

/// `RememberIntent.parse`: the statement to remember, or `None` when the message
/// isn't a request to remember something (including every question about the
/// past). Recognizes English and Serbian, Latin and Cyrillic.
pub fn remember_statement(message: &str) -> Option<String> {
    let trimmed = message.trim();
    if trimmed.ends_with('?') {
        return None;
    }
    let lowered = trimmed.to_lowercase();
    let trigger = REMEMBER_TRIGGERS
        .iter()
        .find(|trigger| lowered.starts_with(**trigger))?;
    let remainder: String = trimmed.chars().skip(trigger.chars().count()).collect();
    let remainder = remainder.trim();
    if remainder.is_empty() {
        return None;
    }
    if QUESTION_CHECKED_TRIGGERS.contains(trigger) {
        let first = remainder
            .split(|c: char| !c.is_alphabetic())
            .find(|word| !word.is_empty())
            .unwrap_or("")
            .to_lowercase();
        if QUESTION_OPENINGS.contains(&first.as_str()) {
            return None;
        }
    }
    let mut chars = remainder.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().chain(chars).collect())
}

pub const CONTEXT_BUDGET: usize = 2_000;
const CONTEXT_HEADER: &str = "What LokalBot knows about the user. Items marked \"learned\" were picked up from what they said in meetings and may be out of date; the rest are their own statements. None of these are evidence:";
const CONTEXT_FOOTER: &str = "Use these only when they bear on the question. They are not sources: never cite them as a meeting or screen source. If retrieved evidence contradicts one, say so. If two conflict, prefer the newer one and point out the conflict.";

/// What one question gets from the personal model (`PersonalContextBuilder`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ContextSelection {
    pub claim_ids: Vec<Uuid>,
    pub block: String,
}

fn context_line(claim: &Claim) -> String {
    let text = sanitize(&claim.text, Some(MAX_CHARACTERS));
    let learned = if claim.authority == Authority::Learned {
        "learned "
    } else {
        ""
    };
    let day = claim.updated_at.with_timezone(&Local).format("%Y-%m-%d");
    format!("- [{} · {learned}{day}] {text}", claim.kind.as_str())
}

/// The smallest useful slice, as a prompt block. Claims that don't fit the budget
/// are skipped, not cut.
pub fn select_context(
    claims: &[Claim],
    question: &str,
    recent_user_turns: &[String],
    budget: usize,
) -> ContextSelection {
    if claims.is_empty() {
        return ContextSelection::default();
    }
    let mut used = CONTEXT_HEADER.chars().count() + CONTEXT_FOOTER.chars().count();
    let mut chosen = Vec::new();
    let mut lines = vec![CONTEXT_HEADER.to_string()];
    for claim in ordered(claims, question, recent_user_turns) {
        let line = context_line(claim);
        let cost = line.chars().count() + 1;
        if used + cost > budget {
            continue;
        }
        used += cost;
        chosen.push(claim.id);
        lines.push(line);
    }
    if chosen.is_empty() {
        return ContextSelection::default();
    }
    lines.push(CONTEXT_FOOTER.to_string());
    ContextSelection {
        claim_ids: chosen,
        block: lines.join("\n"),
    }
}
