//! `outcomes.json` and `outcome-state.json` (`LokalBot/Models/MeetingOutcomes.swift`,
//! `MeetingOutcomeState.swift`).
//!
//! Decoding normalizes records exactly as the Swift decoders do: ownership
//! is reconciled with the stored attribution, the user's items are owned by
//! `Me` and phrased in first person, and missing IDs get their stable FNV ID.

use std::collections::BTreeMap;
use std::sync::LazyLock;

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ids::uuid_upper_serde;
use crate::time::iso_millis;

pub const OUTCOMES_SCHEMA_VERSION: u32 = 4;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingOutcomes {
    #[serde(default = "default_outcomes_schema")]
    pub schema_version: u32,
    /// Matches `Transcript` evidence revision; a mismatch makes outcomes stale.
    /// This port cannot reproduce Swift's JSON bytes, so it treats outcomes
    /// as current regardless (see `Library::outcomes`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_revision: Option<String>,
    #[serde(default, alias = "action_items")]
    pub action_items: Vec<ActionItem>,
    #[serde(default, alias = "decisions", deserialize_with = "decisions_compat")]
    pub decision_records: Vec<Decision>,
    #[serde(default, alias = "open_questions")]
    pub open_questions: Vec<String>,
}

fn default_outcomes_schema() -> u32 {
    OUTCOMES_SCHEMA_VERSION
}

/// v1 stored decisions as plain strings.
fn decisions_compat<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Vec<Decision>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Either {
        Text(String),
        Record(Decision),
    }
    let raw = Vec::<Either>::deserialize(deserializer)?;
    Ok(raw
        .into_iter()
        .map(|item| match item {
            Either::Record(record) => record,
            Either::Text(text) => Decision::new(&text, Vec::new()),
        })
        .collect())
}

impl MeetingOutcomes {
    pub fn is_empty(&self) -> bool {
        self.action_items.is_empty()
            && self.decision_records.is_empty()
            && self.open_questions.is_empty()
    }

    pub fn user_action_items(&self) -> impl Iterator<Item = &ActionItem> {
        self.action_items.iter().filter(|a| a.is_for_user)
    }

    pub fn other_action_items(&self) -> impl Iterator<Item = &ActionItem> {
        self.action_items
            .iter()
            .filter(|a| !a.is_for_user && !a.ownership_is_unclear())
    }

    pub fn unresolved_action_items(&self) -> impl Iterator<Item = &ActionItem> {
        self.action_items
            .iter()
            .filter(|a| a.ownership_is_unclear())
    }

    /// The user's work first, then unclear-owner actions spoken on this
    /// computer's microphone, then everything else by importance
    /// (`prioritizingActionItems`). Nothing is dropped.
    pub fn prioritized(mut self) -> Self {
        let items = std::mem::take(&mut self.action_items);
        let (user, rest): (Vec<_>, Vec<_>) = items.into_iter().partition(|a| a.is_for_user);
        let (mut likely, mut others): (Vec<_>, Vec<_>) = rest
            .into_iter()
            .partition(ActionItem::is_likely_user_action);
        likely.sort_by(higher_priority_action);
        others.sort_by(higher_priority_action);
        self.action_items = user.into_iter().chain(likely).chain(others).collect();
        self
    }

    /// Microphone speaker keys ("me", "local", "local 2", merged "source1:local 2").
    pub fn is_microphone_speaker(speaker: &str) -> bool {
        let key = crate::model::Transcript::canonical_speaker_key(speaker);
        let local = key.rsplit(':').next().unwrap_or(&key);
        local == "me" || local == "local" || local.starts_with("local ")
    }

    /// FNV-1a over the normalized `kind|text|owner|due|citations…` fields.
    pub fn stable_id(
        kind: &str,
        text: &str,
        owner: Option<&str>,
        due: Option<&str>,
        citation_ids: &[String],
    ) -> String {
        let normalized = [kind, text, owner.unwrap_or(""), due.unwrap_or("")]
            .into_iter()
            .chain(citation_ids.iter().map(String::as_str))
            .map(|part| collapse_whitespace(part).to_lowercase())
            .collect::<Vec<_>>()
            .join("|");
        crate::ids::fnv_hex(&normalized)
    }
}

fn higher_priority_action(lhs: &ActionItem, rhs: &ActionItem) -> std::cmp::Ordering {
    rhs.importance
        .cmp(&lhs.importance)
        .then_with(|| {
            let left = lhs.citations.first().map_or(f64::INFINITY, |c| c.start);
            let right = rhs.citations.first().map_or(f64::INFINITY, |c| c.start);
            left.partial_cmp(&right)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .then_with(|| lhs.text.to_lowercase().cmp(&rhs.text.to_lowercase()))
}

fn collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawActionItem")]
pub struct ActionItem {
    pub id: String,
    #[serde(default = "default_outcomes_schema")]
    pub schema_version: u32,
    pub text: String,
    /// As named; `Me` for the user's own items; `None` when unresolved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// The due phrase as spoken ("by Friday"), not normalized.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
    #[serde(default)]
    pub is_for_user: bool,
    pub importance: u8,
    #[serde(default)]
    pub citations: Vec<OutcomeSourceCitation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attribution: Option<ActionAttribution>,
}

/// The stored shape before Swift's decoder normalization.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawActionItem {
    #[serde(default)]
    id: Option<String>,
    text: String,
    #[serde(default)]
    owner: Option<String>,
    #[serde(default)]
    due: Option<String>,
    #[serde(default)]
    is_for_user: Option<bool>,
    #[serde(default)]
    importance: Option<i64>,
    #[serde(default)]
    citations: Vec<OutcomeSourceCitation>,
    #[serde(default)]
    attribution: Option<ActionAttribution>,
}

impl From<RawActionItem> for ActionItem {
    fn from(raw: RawActionItem) -> Self {
        let attribution = raw
            .attribution
            .map(|a| a.consistent_with(raw.is_for_user))
            .unwrap_or_else(|| ActionAttribution::legacy(raw.owner.as_deref(), raw.is_for_user));
        let is_for_user = attribution.resolution == OwnerResolution::User;
        let mut owner = raw.owner;
        if attribution.resolution == OwnerResolution::Unresolved {
            owner = None;
        }
        if is_for_user {
            owner = Some("Me".into());
        }
        let text = action_text(&raw.text, is_for_user);
        let citation_ids: Vec<String> =
            raw.citations.iter().map(|c| c.segment_id.clone()).collect();
        let id = raw.id.unwrap_or_else(|| {
            MeetingOutcomes::stable_id(
                "action",
                &text,
                owner.as_deref(),
                raw.due.as_deref(),
                &citation_ids,
            )
        });
        ActionItem {
            id,
            schema_version: OUTCOMES_SCHEMA_VERSION,
            text,
            owner,
            due: raw.due,
            is_for_user,
            importance: raw.importance.unwrap_or(3).clamp(1, 5) as u8,
            citations: raw.citations,
            attribution: Some(attribution),
        }
    }
}

impl ActionItem {
    /// A new extracted action, normalized like the Swift initializer.
    pub fn new(
        text: &str,
        owner: Option<&str>,
        due: Option<&str>,
        is_for_user: Option<bool>,
        importance: u8,
        citations: Vec<OutcomeSourceCitation>,
        attribution: Option<ActionAttribution>,
    ) -> Self {
        ActionItem::from(RawActionItem {
            id: None,
            text: text.trim().to_string(),
            owner: owner.map(str::to_string),
            due: due.map(str::to_string),
            is_for_user,
            importance: Some(i64::from(importance)),
            citations,
            attribution,
        })
    }

    pub fn ownership_is_unclear(&self) -> bool {
        self.attribution
            .as_ref()
            .is_some_and(|a| a.resolution == OwnerResolution::Unresolved)
            || self.owner.is_none()
    }

    /// Unclear ownership whose evidence was spoken on the microphone: most
    /// likely the user's own work.
    pub fn is_likely_user_action(&self) -> bool {
        if self.is_for_user || !self.ownership_is_unclear() {
            return false;
        }
        let speaker = self
            .attribution
            .as_ref()
            .and_then(|a| a.speaker_id.as_deref())
            .or_else(|| self.citations.first().map(|c| c.speaker.as_str()));
        speaker.is_some_and(MeetingOutcomes::is_microphone_speaker)
    }

    /// The text as shown: first person for the user, "Requested: " for requests.
    pub fn display_text(&self) -> String {
        let prose = action_text(&self.text, self.is_for_user);
        let is_request = self
            .attribution
            .as_ref()
            .is_some_and(|a| a.basis == AttributionBasis::Request);
        if is_request && !prose.starts_with("Requested: ") {
            format!("Requested: {prose}")
        } else {
            prose
        }
    }
}

static ME_POSSESSIVE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)^me['’]s\b").expect("valid regex"));
static ME_SUBJECT: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"(?i)^me\b").expect("valid regex"));

/// `OutcomeProse.actionText`: the internal `Me` owner label becomes "I"/"My".
pub fn action_text(text: &str, is_for_user: bool) -> String {
    if !is_for_user {
        return text.to_string();
    }
    let trimmed = text.trim();
    let possessive = ME_POSSESSIVE.replace(trimmed, "My");
    ME_SUBJECT.replace(&possessive, "I").into_owned()
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawDecision")]
pub struct Decision {
    pub id: String,
    #[serde(default = "default_outcomes_schema")]
    pub schema_version: u32,
    pub text: String,
    #[serde(default)]
    pub citations: Vec<OutcomeSourceCitation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attribution: Option<DecisionAttribution>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawDecision {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    schema_version: Option<u32>,
    text: String,
    #[serde(default)]
    citations: Vec<OutcomeSourceCitation>,
    #[serde(default)]
    attribution: Option<DecisionAttribution>,
}

impl From<RawDecision> for Decision {
    fn from(raw: RawDecision) -> Self {
        let text = raw.text.trim().to_string();
        let citation_ids: Vec<String> =
            raw.citations.iter().map(|c| c.segment_id.clone()).collect();
        Decision {
            id: raw.id.unwrap_or_else(|| {
                MeetingOutcomes::stable_id("decision", &text, None, None, &citation_ids)
            }),
            schema_version: raw.schema_version.unwrap_or(1),
            text,
            citations: raw.citations,
            attribution: raw.attribution,
        }
    }
}

impl Decision {
    pub fn new(text: &str, citations: Vec<OutcomeSourceCitation>) -> Self {
        let mut decision = Decision::from(RawDecision {
            id: None,
            schema_version: None,
            text: text.to_string(),
            citations,
            attribution: None,
        });
        decision.schema_version = OUTCOMES_SCHEMA_VERSION;
        decision
    }

    /// "<Speaker>: <text>" when attributed.
    pub fn display_text(&self) -> String {
        match &self.attribution {
            Some(a) => format!("{}: {}", a.speaker_label, self.text),
            None => self.text.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutcomeSourceCitation {
    #[serde(
        default,
        with = "uuid_upper_serde::option",
        skip_serializing_if = "Option::is_none",
        rename = "meetingID"
    )]
    pub meeting_id: Option<Uuid>,
    #[serde(rename = "segmentID")]
    pub segment_id: String,
    pub start: f64,
    pub end: f64,
    pub speaker: String,
    pub excerpt: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActionAttribution {
    pub resolution: OwnerResolution,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "speakerID")]
    pub speaker_id: Option<String>,
    pub basis: AttributionBasis,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quote: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rejection_reason: Option<String>,
}

impl ActionAttribution {
    /// A stored attribution that disagrees with the stored `isForUser` flag
    /// becomes unresolved (`OutcomeAttribution.consistent(with:)`).
    pub fn consistent_with(self, for_user: Option<bool>) -> Self {
        match for_user {
            Some(flag) if flag != (self.resolution == OwnerResolution::User) => ActionAttribution {
                resolution: OwnerResolution::Unresolved,
                speaker_id: self.speaker_id,
                basis: AttributionBasis::Unclear,
                quote: self.quote,
                rejection_reason: Some("conflictingOwner".into()),
            },
            _ => self,
        }
    }

    /// Attribution for records written before attribution existed.
    pub fn legacy(owner: Option<&str>, for_user: Option<bool>) -> Self {
        let name = owner.map(str::trim).filter(|o| !o.is_empty());
        let user = name.is_some_and(|n| n.eq_ignore_ascii_case("me"));
        let conflict =
            for_user.is_some_and(|flag| if flag { name.is_some() && !user } else { user });
        let resolution = if conflict {
            OwnerResolution::Unresolved
        } else if for_user.unwrap_or(user) {
            OwnerResolution::User
        } else if name.is_none() {
            OwnerResolution::Unresolved
        } else {
            OwnerResolution::Other
        };
        ActionAttribution {
            resolution,
            speaker_id: None,
            basis: AttributionBasis::Legacy,
            quote: None,
            rejection_reason: None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OwnerResolution {
    User,
    Other,
    Unresolved,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AttributionBasis {
    Commitment,
    Assignment,
    Request,
    Unclear,
    Legacy,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DecisionAttribution {
    #[serde(rename = "speakerID")]
    pub speaker_id: String,
    pub speaker_label: String,
    pub identity: crate::model::transcript::SpeakerIdentity,
    pub quote: String,
}

/// `outcome-state.json`: the user's corrections layered over extracted actions.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutcomeState {
    #[serde(default = "default_state_schema")]
    pub schema_version: u32,
    #[serde(default)]
    pub actions: BTreeMap<String, ActionState>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unmatched_actions: Option<BTreeMap<String, ActionState>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unmatched_action_text: Option<BTreeMap<String, String>>,
}

fn default_state_schema() -> u32 {
    2
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ActionStatus {
    #[default]
    Open,
    Done,
    Deferred,
}

impl ActionStatus {
    pub fn label(self) -> &'static str {
        match self {
            ActionStatus::Open => "Open",
            ActionStatus::Done => "Done",
            ActionStatus::Deferred => "Deferred",
        }
    }

    /// The lowercase JSON value (`open`, `done`, `deferred`).
    pub fn raw(self) -> &'static str {
        match self {
            ActionStatus::Open => "open",
            ActionStatus::Done => "done",
            ActionStatus::Deferred => "deferred",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawActionState")]
pub struct ActionState {
    pub status: ActionStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_override: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub due_override: Option<String>,
    #[serde(default)]
    pub owner_was_cleared: bool,
    #[serde(default)]
    pub due_was_cleared: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text_correction: Option<String>,
    #[serde(
        default,
        with = "iso_millis::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub text_corrected_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        with = "iso_millis::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub owner_corrected_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        with = "iso_millis::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub due_corrected_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub is_thread_excluded: bool,
    #[serde(with = "iso_millis")]
    pub updated_at: DateTime<Utc>,
    #[serde(default)]
    pub user_edited: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawActionState {
    #[serde(default)]
    status: Option<ActionStatus>,
    #[serde(default)]
    owner_override: Option<String>,
    #[serde(default)]
    due_override: Option<String>,
    #[serde(default)]
    owner_was_cleared: Option<bool>,
    #[serde(default)]
    due_was_cleared: Option<bool>,
    #[serde(default)]
    text_correction: Option<String>,
    #[serde(default, with = "iso_millis::option")]
    text_corrected_at: Option<DateTime<Utc>>,
    #[serde(default, with = "iso_millis::option")]
    owner_corrected_at: Option<DateTime<Utc>>,
    #[serde(default, with = "iso_millis::option")]
    due_corrected_at: Option<DateTime<Utc>>,
    #[serde(default)]
    is_thread_excluded: Option<bool>,
    #[serde(default, with = "iso_millis::option")]
    updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    user_edited: Option<bool>,
}

impl From<RawActionState> for ActionState {
    /// Legacy records without per-field correction dates freeze them at
    /// `updatedAt`, before a later status write advances it.
    fn from(raw: RawActionState) -> Self {
        let status = raw.status.unwrap_or_default();
        let updated_at = millis(raw.updated_at.unwrap_or_else(Utc::now));
        let owner_was_cleared = raw.owner_was_cleared.unwrap_or(false);
        let due_was_cleared = raw.due_was_cleared.unwrap_or(false);
        let is_thread_excluded = raw.is_thread_excluded.unwrap_or(false);
        let text_corrected_at = raw
            .text_corrected_at
            .or(raw.text_correction.as_ref().map(|_| updated_at));
        let owner_corrected_at = raw
            .owner_corrected_at
            .or((raw.owner_override.is_some() || owner_was_cleared).then_some(updated_at));
        let due_corrected_at = raw
            .due_corrected_at
            .or((raw.due_override.is_some() || due_was_cleared).then_some(updated_at));
        let user_edited = raw.user_edited.unwrap_or(
            status != ActionStatus::Open
                || raw.owner_override.is_some()
                || raw.due_override.is_some()
                || owner_was_cleared
                || due_was_cleared
                || raw.text_correction.is_some()
                || is_thread_excluded,
        );
        ActionState {
            status,
            owner_override: raw.owner_override,
            due_override: raw.due_override,
            owner_was_cleared,
            due_was_cleared,
            text_correction: raw.text_correction,
            text_corrected_at,
            owner_corrected_at,
            due_corrected_at,
            is_thread_excluded,
            updated_at,
            user_edited,
        }
    }
}

/// Millisecond precision, as persisted (`outcomePersistedTimestamp`).
pub fn millis(value: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::from_timestamp_millis(value.timestamp_millis()).unwrap_or(value)
}

impl ActionState {
    pub fn new(status: ActionStatus) -> Self {
        Self {
            status,
            owner_override: None,
            due_override: None,
            owner_was_cleared: false,
            due_was_cleared: false,
            text_correction: None,
            text_corrected_at: None,
            owner_corrected_at: None,
            due_corrected_at: None,
            is_thread_excluded: false,
            updated_at: millis(Utc::now()),
            user_edited: true,
        }
    }

    /// The untouched default for an action without saved state.
    pub fn untouched() -> Self {
        Self {
            user_edited: false,
            ..Self::new(ActionStatus::Open)
        }
    }
}

/// An action item with the user's corrections applied, joined to its meeting
/// (`OutcomeActionReference`). `id` is `"<MEETING-UUID>:<actionID>"`.
#[derive(Clone, Debug, PartialEq)]
pub struct ActionReference {
    pub id: String,
    pub meeting_id: Uuid,
    pub meeting_title: String,
    pub meeting_started_at: DateTime<Utc>,
    pub action_id: String,
    /// The corrected text, or the extracted display text.
    pub text: String,
    /// The extracted display text.
    pub original_text: String,
    pub owner: Option<String>,
    pub due: Option<String>,
    pub resolved_due_date: Option<NaiveDate>,
    pub is_for_user: bool,
    pub status: ActionStatus,
    pub importance: u8,
    pub citations: Vec<OutcomeSourceCitation>,
    /// The extracted action, normalized but without corrections.
    pub action: ActionItem,
    /// When the user last edited it, or the meeting start when never edited.
    pub state_updated_at: DateTime<Utc>,
    pub text_was_corrected: bool,
    pub owner_was_corrected: bool,
    pub due_was_corrected: bool,
    pub text_corrected_at: Option<DateTime<Utc>>,
    pub owner_corrected_at: Option<DateTime<Utc>>,
    pub due_corrected_at: Option<DateTime<Utc>>,
    pub is_thread_excluded: bool,
}

impl ActionReference {
    pub fn first_citation(&self) -> Option<&OutcomeSourceCitation> {
        self.citations.first()
    }

    /// Open (or deferred) work whose resolved due day is before `today`.
    pub fn is_overdue(&self, today: NaiveDate) -> bool {
        self.status != ActionStatus::Done && self.resolved_due_date.is_some_and(|due| due < today)
    }

    /// A corrected due phrase is read from the day the user typed it; an
    /// extracted one from the day of the meeting.
    pub fn due_reference_date(&self) -> DateTime<Utc> {
        if self.due_was_corrected {
            self.due_corrected_at.unwrap_or(self.state_updated_at)
        } else {
            self.meeting_started_at
        }
    }

    /// The extracted action with the user's corrections applied.
    pub fn effective_action(&self) -> ActionItem {
        let mut result = self.action.clone();
        result.text = self.text.clone();
        result.owner = self.owner.clone();
        result.due = self.due.clone();
        result.is_for_user = self.is_for_user;
        if self.owner_was_corrected {
            result.attribution = Some(ActionAttribution {
                resolution: if self.is_for_user {
                    OwnerResolution::User
                } else {
                    OwnerResolution::Other
                },
                speaker_id: None,
                basis: self
                    .action
                    .attribution
                    .as_ref()
                    .map_or(AttributionBasis::Assignment, |a| a.basis),
                quote: None,
                rejection_reason: None,
            });
        }
        result
    }
}

/// The same commitment across meetings (`ActionThreads.swift`).
#[derive(Clone, Debug, PartialEq)]
pub struct ActionThread {
    /// `thread-%016llx` of the sorted reference IDs.
    pub id: String,
    /// The folded clustering key of the newest member (empty when the
    /// thread could not be clustered, e.g. too few significant words).
    pub canonical_text: String,
    /// Newest meeting first.
    pub references: Vec<ActionReference>,
    /// The text to show: the latest correction, else the most descriptive.
    pub text: String,
    pub owner: Option<String>,
    pub due: Option<String>,
    pub due_source_meeting_date: Option<DateTime<Utc>>,
    /// The day the effective due phrase was said or corrected.
    pub due_reference_date: Option<DateTime<Utc>>,
    pub resolved_due_date: Option<NaiveDate>,
}

impl ActionThread {
    /// Days after the last mention when open, undated work counts as stale.
    pub const STALE_AFTER_DAYS: i64 = 21;

    /// Open if any member is open, else deferred if any, else done.
    pub fn status(&self) -> ActionStatus {
        if self
            .references
            .iter()
            .any(|r| r.status == ActionStatus::Open)
        {
            ActionStatus::Open
        } else if self
            .references
            .iter()
            .any(|r| r.status == ActionStatus::Deferred)
        {
            ActionStatus::Deferred
        } else {
            ActionStatus::Done
        }
    }

    pub fn is_mixed(&self) -> bool {
        let first = self.references.first().map(|r| r.status);
        self.references.iter().any(|r| Some(r.status) != first)
    }

    /// "Mixed" or the status label.
    pub fn status_label(&self) -> &'static str {
        if self.is_mixed() {
            "Mixed"
        } else {
            self.status().label()
        }
    }

    /// The newest member.
    pub fn latest(&self) -> &ActionReference {
        &self.references[0]
    }

    pub fn meeting_count(&self) -> usize {
        let mut ids: Vec<Uuid> = self.references.iter().map(|r| r.meeting_id).collect();
        ids.sort();
        ids.dedup();
        ids.len()
    }

    pub fn mention_count(&self) -> usize {
        self.references.len()
    }

    /// The newest owner correction decides; otherwise every member must be the user's.
    pub fn is_for_user(&self) -> bool {
        let correction = self
            .references
            .iter()
            .filter(|r| r.owner_was_corrected)
            .max_by_key(|r| r.owner_corrected_at.unwrap_or(r.state_updated_at));
        match correction {
            Some(reference) => reference.is_for_user,
            None => self.references.iter().all(|r| r.is_for_user),
        }
    }

    /// Open work whose resolved due day is behind `today`.
    pub fn is_overdue(&self, today: NaiveDate) -> bool {
        self.status() == ActionStatus::Open && self.resolved_due_date.is_some_and(|due| due < today)
    }

    /// Whole days since the newest meeting that mentioned this work.
    pub fn days_since_last_mention(&self, today: NaiveDate) -> i64 {
        (today - crate::time::local_day(self.latest().meeting_started_at)).num_days()
    }

    /// Open work nobody mentioned for weeks and that is not due ahead.
    pub fn is_stale(&self, today: NaiveDate) -> bool {
        if self.status() != ActionStatus::Open {
            return false;
        }
        if self.resolved_due_date.is_some_and(|due| due >= today) {
            return false;
        }
        self.days_since_last_mention(today) >= Self::STALE_AFTER_DAYS
    }

    /// Distinct due phrases, newest first, case-insensitively.
    pub fn due_history(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for due in self.references.iter().filter_map(|r| r.due.as_ref()) {
            if !out.iter().any(|d| d.eq_ignore_ascii_case(due)) {
                out.push(due.clone());
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_owner_strings_normalize_like_swift() {
        let json = r#"{"actionItems":[
            {"id":"a","text":"Me to send the deck","owner":"me"},
            {"id":"b","text":"Review the doc","owner":"Ana"},
            {"id":"c","text":"Somebody books the room"},
            {"id":"d","text":"Conflicting","owner":"Ana","isForUser":true},
            {"text":"Me's notes get shared","owner":"Me","isForUser":true,"importance":9}
        ],"decisions":["Ship it"]}"#;
        let outcomes: MeetingOutcomes = serde_json::from_str(json).unwrap();
        let a = &outcomes.action_items;
        assert!(a[0].is_for_user);
        assert_eq!(a[0].owner.as_deref(), Some("Me"));
        assert_eq!(a[0].text, "I to send the deck");
        assert!(!a[1].is_for_user);
        assert_eq!(a[1].owner.as_deref(), Some("Ana"));
        assert!(a[2].ownership_is_unclear());
        assert_eq!(
            a[3].owner, None,
            "conflicting legacy ownership becomes unresolved"
        );
        assert_eq!(a[4].text, "My notes get shared");
        assert_eq!(a[4].importance, 5);
        assert_eq!(a[4].id.len(), 16);
        assert_eq!(outcomes.decision_records[0].text, "Ship it");
        assert_eq!(
            outcomes.decision_records[0].id,
            MeetingOutcomes::stable_id("decision", "Ship it", None, None, &[])
        );
    }

    #[test]
    fn prioritized_puts_user_then_microphone_then_importance() {
        let cite = |speaker: &str, start: f64| OutcomeSourceCitation {
            meeting_id: None,
            segment_id: format!("s{start}"),
            start,
            end: start + 1.0,
            speaker: speaker.into(),
            excerpt: String::new(),
        };
        let outcomes = MeetingOutcomes {
            action_items: vec![
                ActionItem::new(
                    "Other low",
                    Some("Ana"),
                    None,
                    None,
                    2,
                    vec![cite("them", 5.0)],
                    None,
                ),
                ActionItem::new(
                    "Unclear on mic",
                    None,
                    None,
                    None,
                    1,
                    vec![cite("local 2", 9.0)],
                    None,
                ),
                ActionItem::new(
                    "Other high",
                    Some("Ana"),
                    None,
                    None,
                    5,
                    vec![cite("them", 7.0)],
                    None,
                ),
                ActionItem::new(
                    "Mine",
                    Some("Me"),
                    None,
                    None,
                    1,
                    vec![cite("me", 1.0)],
                    None,
                ),
            ],
            ..Default::default()
        }
        .prioritized();
        let texts: Vec<_> = outcomes
            .action_items
            .iter()
            .map(|a| a.text.as_str())
            .collect();
        assert_eq!(texts, ["Mine", "Unclear on mic", "Other high", "Other low"]);
    }

    #[test]
    fn legacy_state_freezes_correction_dates() {
        let state: ActionState =
            serde_json::from_str(r#"{"ownerOverride":"Ana","updatedAt":"2026-10-01T10:00:00Z"}"#)
                .unwrap();
        assert_eq!(state.status, ActionStatus::Open);
        assert!(state.user_edited);
        assert_eq!(state.owner_corrected_at, Some(state.updated_at));
        assert_eq!(state.text_corrected_at, None);
    }
}
