//! Voice memory (`MeetingSpeakerEvidence.swift`, `SpeakerVoiceProfile.swift`,
//! `SpeakerVoiceMatcher.swift`, `SpeakerIdentityResolver.swift`,
//! `MeetingSpeakerEvidenceStore.swift`, `MeetingSpeakerIdentityService.swift`).
//!
//! Naming a speaker teaches an encrypted voice profile; later meetings offer
//! or apply the name. Everything here is private: it stays out of the
//! transcript model, search, exports, the CLI and prompts.
//!
//! # Files
//!
//! `speaker-profiles/profiles.sealed` under the library root and
//! `speaker-evidence/identity.sealed` in a meeting's folder, as on macOS: the
//! `Codable` JSON sealed with AES-256-GCM as `nonce ‖ ciphertext ‖ tag`, with
//! the file's path under the root as associated data. The key is per install
//! and lives in the system credential store, so a Mac's files don't open here.
//! That reads as an error, never as empty, so they are not overwritten.
//!
//! # Models
//!
//! Every sample and profile names the voice model that made it. This port uses
//! TitaNet where the Mac uses pyannote; the two spaces are not comparable, so
//! only vectors of [`VOICE_MODEL`] are ever scored or added to.

mod evidence;
mod matcher;
mod resolver;
mod service;
mod store;
mod timing;

#[cfg(test)]
mod tests;

use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;
use uuid::Uuid;

use crate::ids::uuid_upper_serde;
use crate::model::AttributionSource;
use crate::time::swift_date;

pub use evidence::{MicrophoneEvidence, label_samples, label_turns, select_microphone_samples};
pub use matcher::{
    Voiceprint, call, can_enroll, cosine, eligible, matches, normalized, voiceprint,
};
pub use resolver::{apply as apply_candidates, remap};
pub use service::{
    Choice, ChooseError, ProcessRequest, Revisit, SavedMeetingAccess, VoiceMemory, audio_revision,
    recognized_speakers, recording_revision, same_person, summary_needs_refresh,
    transcript_signature,
};
pub use store::{Failure, Store};
pub use timing::{AudioClockSpan, RecordingAudioTiming, TrackClock, reference_clock};

/// The voice model this app's vectors come from. A changed model or
/// preprocessing needs a new value, which leaves older profiles unmatched.
pub const VOICE_MODEL: &str = "sherpa-onnx/nemo-titanet-small/embedding192/16k-mono-v1";
/// TitaNet's vector length. The Mac's pyannote vectors have 256.
pub const VOICE_DIMENSION: usize = 192;

/// Bumped when call voices start being analyzed differently, so saved
/// meetings are revisited once (`callVoicesVersion`).
pub const CALL_VOICES_VERSION: u32 = 1;

pub const EVIDENCE_FOLDER: &str = "speaker-evidence";
pub const IDENTITY_FILE: &str = "identity.sealed";
pub const PROFILES_FILE: &str = "speaker-profiles/profiles.sealed";

/// A span of a track, in seconds (`SpeakerTurnAnchor`).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct TurnAnchor {
    pub start: f64,
    pub end: f64,
}

impl TurnAnchor {
    pub fn duration(&self) -> f64 {
        (self.end - self.start).max(0.0)
    }

    pub fn is_valid(&self) -> bool {
        self.start.is_finite() && self.end.is_finite() && self.start >= 0.0 && self.end > self.start
    }

    pub fn overlap(&self, other: &Self) -> f64 {
        (self.end.min(other.end) - self.start.max(other.start)).max(0.0)
    }
}

/// Overlapping or touching spans merged (`VisualSpeakerMatcher.union`).
pub fn union(ranges: impl IntoIterator<Item = TurnAnchor>) -> Vec<TurnAnchor> {
    let mut ranges: Vec<TurnAnchor> = ranges.into_iter().filter(TurnAnchor::is_valid).collect();
    ranges.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut out: Vec<TurnAnchor> = Vec::with_capacity(ranges.len());
    for range in ranges {
        match out.last_mut() {
            Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
            _ => out.push(range),
        }
    }
    out
}

/// One speaker's turn on a track (`SpeakerAudioTurn`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AudioTurn {
    pub speaker: String,
    pub range: TurnAnchor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<AttributionSource>,
}

impl AudioTurn {
    pub fn resolved_source(&self) -> AttributionSource {
        self.source.unwrap_or_else(|| legacy_source(&self.speaker))
    }
}

/// `SpeakerAudioTurn.legacySource`.
pub fn legacy_source(speaker: &str) -> AttributionSource {
    if speaker == "me" || speaker.starts_with("local") {
        AttributionSource::Microphone
    } else {
        AttributionSource::System
    }
}

/// `VisualSpeakerMatcher.mergedTurns`: same-speaker neighbours within 0.5 s.
pub(crate) fn merged_turns(turns: &[AudioTurn]) -> Vec<AudioTurn> {
    let mut sorted: Vec<&AudioTurn> = turns.iter().filter(|t| t.range.is_valid()).collect();
    sorted.sort_by(|a, b| a.range.start.total_cmp(&b.range.start));
    let mut out: Vec<AudioTurn> = Vec::with_capacity(sorted.len());
    for turn in sorted {
        match out.last_mut() {
            Some(last)
                if last.speaker == turn.speaker && turn.range.start - last.range.end <= 0.5 =>
            {
                last.range.end = last.range.end.max(turn.range.end);
            }
            _ => out.push(turn.clone()),
        }
    }
    out
}

/// A speaker's display name is safe to keep and teach (`safeName`): 2–80
/// characters with no address, URL, control character or a secret that
/// `has_secret` finds, and not a word meeting apps show for people.
pub fn safe_name(raw: &str, has_secret: &dyn Fn(&str) -> bool) -> Option<String> {
    let name = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let count = name.chars().count();
    if !(2..=80).contains(&count)
        || name.contains('@')
        || name.contains("://")
        || name.chars().any(char::is_control)
        || [
            "you",
            "presentation",
            "presenting",
            "everyone",
            "shared room",
        ]
        .contains(&name.to_lowercase().as_str())
        || has_secret(&name)
    {
        return None;
    }
    Some(name)
}

/// Case- and accent-insensitive key for names (`ParticipantObservation.nameKey`).
pub fn name_key(name: &str) -> String {
    let folded: String = name
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .collect::<String>()
        .to_lowercase();
    folded.trim().to_string()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MatchTier {
    Automatic,
    Suggested,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MatchSource {
    /// The retired Google Meet naming; saved meetings still decode it.
    Visual,
    Profile,
}

/// `SpeakerNameMatch`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NameMatch {
    pub name: String,
    pub participant_reference: String,
    pub tier: MatchTier,
    pub source: MatchSource,
    pub support_seconds: f64,
    pub independent_turns: usize,
    pub support_fraction: f64,
    pub contradiction_seconds: f64,
    pub evidence: Vec<TurnAnchor>,
    #[serde(
        default,
        with = "uuid_upper_serde::option",
        skip_serializing_if = "Option::is_none",
        rename = "profileID"
    )]
    pub profile_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_revision: Option<u64>,
    #[serde(default = "default_policy_version")]
    pub policy_version: String,
}

fn default_policy_version() -> String {
    "speaker-identity-1-experimental".into()
}

/// How an assignment got its name (`SpeakerIdentityAssignment.Origin`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Origin {
    VisualAutomatic,
    ProfileAutomatic,
    CalendarAutomatic,
    UserConfirmed,
    UserCorrected,
    Legacy,
}

impl Origin {
    /// A name from a person: automatic work never replaces it.
    pub fn is_protected(self) -> bool {
        matches!(
            self,
            Self::UserConfirmed | Self::UserCorrected | Self::Legacy
        )
    }
}

/// `SpeakerIdentityAssignment`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Assignment {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "calendarIdentityID"
    )]
    pub calendar_identity_id: Option<String>,
    pub origin: Origin,
    pub audio_revision: String,
    pub anchors: Vec<TurnAnchor>,
    #[serde(default)]
    pub suppressed_names: Vec<String>,
    #[serde(default)]
    pub automatic_disabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "match")]
    pub matched: Option<NameMatch>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub supporting_matches: Option<Vec<NameMatch>>,
    #[serde(
        default,
        with = "uuid_upper_serde::option",
        skip_serializing_if = "Option::is_none",
        rename = "profileID"
    )]
    pub profile_id: Option<Uuid>,
    /// Independent of a display alias, including an alias spelled "Me".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_local_user: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<AttributionSource>,
}

impl Assignment {
    pub fn new(
        label: &str,
        origin: Origin,
        audio_revision: &str,
        anchors: Vec<TurnAnchor>,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            label: label.to_string(),
            name: None,
            calendar_identity_id: None,
            origin,
            audio_revision: audio_revision.to_string(),
            anchors,
            suppressed_names: Vec::new(),
            automatic_disabled: false,
            matched: None,
            supporting_matches: None,
            profile_id: None,
            is_local_user: None,
            source: None,
        }
    }

    pub fn resolved_source(&self) -> AttributionSource {
        self.source.unwrap_or_else(|| legacy_source(&self.label))
    }

    pub fn is_unresolved_label(&self) -> bool {
        self.label.starts_with("unresolved-")
    }
}

/// `SpeakerAliasDecision.Action`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DecisionAction {
    Assign,
    Dismiss,
    Reset,
    Undo,
    Resume,
    ConfirmUser,
    ConfirmOther,
}

impl DecisionAction {
    pub fn confirms_identity(self) -> bool {
        matches!(self, Self::ConfirmUser | Self::ConfirmOther)
    }

    pub fn changes_attribution(self) -> bool {
        self != Self::Dismiss
    }
}

/// `SpeakerAliasDecision`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    #[serde(with = "uuid_upper_serde", rename = "speakerID")]
    pub speaker_id: Uuid,
    pub action: DecisionAction,
    pub source_revision: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(with = "swift_date")]
    pub confirmed_at: DateTime<Utc>,
}

/// `MeetingSpeakerIdentityState`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IdentityState {
    pub schema_version: u32,
    #[serde(with = "uuid_upper_serde", rename = "meetingID")]
    pub meeting_id: Uuid,
    pub revision: u64,
    pub evidence_revision: u64,
    pub audio_revision: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript_signature: Option<String>,
    pub timeline: Vec<AudioTurn>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acoustic_timeline: Option<Vec<AudioTurn>>,
    pub assignments: Vec<Assignment>,
    pub decisions: Vec<Decision>,
    pub suggestions: std::collections::BTreeMap<String, Vec<NameMatch>>,
    #[serde(with = "swift_date")]
    pub analyzed_at: DateTime<Utc>,
    pub voice_samples: Vec<VoiceSample>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub microphone_sample_diagnostics: Option<std::collections::BTreeMap<String, u32>>,
    /// Set once call voices were analyzed; meetings processed before that are
    /// revisited once.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_voices_analyzed: Option<u32>,
}

impl IdentityState {
    pub fn new(meeting_id: Uuid) -> Self {
        Self {
            schema_version: 1,
            meeting_id,
            revision: 0,
            evidence_revision: 0,
            audio_revision: String::new(),
            transcript_signature: None,
            timeline: Vec::new(),
            acoustic_timeline: None,
            assignments: Vec::new(),
            decisions: Vec::new(),
            suggestions: Default::default(),
            analyzed_at: Utc::now(),
            voice_samples: Vec::new(),
            microphone_sample_diagnostics: None,
            call_voices_analyzed: None,
        }
    }

    pub fn assignment(&self, label: &str) -> Option<&Assignment> {
        self.assignments.iter().find(|a| a.label == label)
    }

    /// When the speakers last changed, for "Notes need a refresh".
    pub fn latest_attribution_change(&self) -> Option<DateTime<Utc>> {
        self.decisions
            .iter()
            .filter(|d| d.action.changes_attribution())
            .map(|d| d.confirmed_at)
            .max()
    }
}

/// `SpeakerVoiceSample`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct VoiceSample {
    pub speaker: String,
    pub range: TurnAnchor,
    pub vector: Vec<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<AttributionSource>,
    pub model: String,
}

impl VoiceSample {
    pub fn resolved_source(&self) -> AttributionSource {
        self.source.unwrap_or(AttributionSource::System)
    }
}

/// `SpeakerVoiceProfile.Contribution`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Contribution {
    #[serde(with = "uuid_upper_serde", rename = "meetingID")]
    pub meeting_id: Uuid,
    pub audio_revision: String,
    #[serde(with = "uuid_upper_serde", rename = "speakerID")]
    pub speaker_id: Uuid,
    #[serde(with = "uuid_upper_serde", rename = "decisionID")]
    pub decision_id: Uuid,
    #[serde(with = "swift_date")]
    pub confirmed_at: DateTime<Utc>,
    pub samples: Vec<VoiceSample>,
    /// Call voices keep the average of every eligible chunk instead of the chunks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub voiceprint: Option<Vec<f32>>,
}

/// `SpeakerVoiceProfile`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceProfile {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_local_user: Option<bool>,
    pub confirmed_names: Vec<String>,
    pub revision: u64,
    pub contributions: Vec<Contribution>,
    pub model: String,
}

/// `SpeakerVoiceProfileDatabase`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileDatabase {
    pub schema_version: u32,
    pub revision: u64,
    pub profiles: Vec<VoiceProfile>,
    #[serde(with = "uuid_set")]
    pub forgotten_profiles: BTreeSet<Uuid>,
    #[serde(with = "uuid_set")]
    pub deleted_meetings: BTreeSet<Uuid>,
    #[serde(with = "uuid_set", rename = "revokedDecisionIDs")]
    pub revoked_decision_ids: BTreeSet<Uuid>,
}

impl Default for ProfileDatabase {
    fn default() -> Self {
        Self {
            schema_version: 1,
            revision: 0,
            profiles: Vec::new(),
            forgotten_profiles: BTreeSet::new(),
            deleted_meetings: BTreeSet::new(),
            revoked_decision_ids: BTreeSet::new(),
        }
    }
}

/// A Swift `Set<UUID>`: an array of uppercase strings.
mod uuid_set {
    use std::collections::BTreeSet;

    use serde::{Deserialize, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(
        set: &BTreeSet<Uuid>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        serializer.collect_seq(set.iter().map(crate::ids::uuid_upper))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<BTreeSet<Uuid>, D::Error> {
        Vec::<String>::deserialize(deserializer)?
            .iter()
            .map(|raw| Uuid::parse_str(raw).map_err(serde::de::Error::custom))
            .collect()
    }
}
