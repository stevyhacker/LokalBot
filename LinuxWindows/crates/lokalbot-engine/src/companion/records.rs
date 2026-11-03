//! Companion records, schema version 1 (`Companion/protocol/records.md`,
//! `CompanionRecords.swift`).
//!
//! These types are the allowlist: a field reaches a phone only if it is
//! declared here. Optional fields are omitted from the JSON, never `null`.
//! Instants are ISO 8601 UTC strings with milliseconds; calendar days are
//! `YYYY-MM-DD` in this computer's time zone; offsets inside a meeting are
//! seconds from the start of its audio.

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::sharing::DataClasses;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RecordKind {
    Meeting,
    Transcript,
    Day,
    Person,
    Project,
}

impl RecordKind {
    /// Kinds whose keys the publisher reconciles. The manifest is a single
    /// record set through `set_manifest`.
    pub const RECONCILED: [Self; 5] = [
        Self::Meeting,
        Self::Transcript,
        Self::Day,
        Self::Person,
        Self::Project,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Meeting => "meeting",
            Self::Transcript => "transcript",
            Self::Day => "day",
            Self::Person => "person",
            Self::Project => "project",
        }
    }
}

/// One built record. The host adds the envelope (`version`, `seq`, `sortKey`,
/// `deleted`).
#[derive(Clone, Debug, PartialEq)]
pub struct Record {
    pub kind: RecordKind,
    pub key: String,
    pub body_json: String,
}

pub fn encode<T: Serialize>(value: &T) -> Option<String> {
    serde_json::to_string(value).ok()
}

pub fn instant(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// Meeting and project UUIDs travel in lower case, as in the fixtures.
pub fn id(uuid: Uuid) -> String {
    uuid.to_string()
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestBody {
    pub schema_version: u32,
    pub library_name: String,
    /// This computer's name; the protocol keeps the Mac's key.
    pub mac_name: String,
    pub data_classes: DataClasses,
    pub history_days: u32,
    pub ask_enabled: bool,
    pub generated_at: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Citation {
    pub start: f64,
    pub end: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speaker: Option<String>,
    pub excerpt: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Action {
    pub id: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    pub owner_is_user: bool,
    pub owner_unclear: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_text: Option<String>,
    pub status: String,
    pub importance: u8,
    pub citations: Vec<Citation>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Statement {
    pub id: String,
    pub text: String,
    pub citations: Vec<Citation>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NamedRef {
    pub id: String,
    pub display_name: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ProjectRef {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingBody {
    pub id: String,
    pub title: String,
    pub started_at: String,
    pub ended_at: String,
    pub day: String,
    pub time_zone_offset_minutes: i32,
    pub duration_seconds: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_name: Option<String>,
    pub people: Vec<NamedRef>,
    pub projects: Vec<ProjectRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summary_markdown: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes_markdown: Option<String>,
    pub actions: Vec<Action>,
    pub decisions: Vec<Statement>,
    pub open_questions: Vec<Statement>,
    pub has_transcript: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub merged_into: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptSegment {
    pub start: f64,
    pub end: f64,
    pub speaker: String,
    pub color_index: i32,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptBody {
    pub meeting_id: String,
    pub segments: Vec<TranscriptSegment>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DigestSections {
    pub highlights: Vec<String>,
    pub decisions: Vec<String>,
    pub tasks: Vec<String>,
    pub blockers: Vec<String>,
    pub follow_ups: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DigestBody {
    pub markdown: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub generated_at: Option<String>,
    pub user_edited: bool,
    pub sections: DigestSections,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Seconds {
    pub name: String,
    pub seconds: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub start: String,
    pub end: String,
    pub title: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meeting_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    pub apps: Vec<Seconds>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_titles: Option<Vec<String>>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SavedMoment {
    pub at: String,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Timeline {
    pub tracked_seconds: f64,
    pub sessions: Vec<Session>,
    pub by_project: Vec<Seconds>,
    pub by_app: Vec<Seconds>,
    pub saved_moments: Vec<SavedMoment>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DayBody {
    pub date: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub digest: Option<DigestBody>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeline: Option<Timeline>,
    pub meeting_ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenWork {
    pub meeting_id: String,
    pub action_id: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    pub theirs: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DecisionRef {
    pub meeting_id: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonBody {
    pub id: String,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_met_at: Option<String>,
    pub open_work: Vec<OpenWork>,
    pub decisions_together: Vec<DecisionRef>,
    pub meeting_ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct YourAction {
    pub meeting_id: String,
    pub action_id: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WaitingOn {
    pub meeting_id: String,
    pub action_id: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectBody {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub where_it_stands: Option<String>,
    pub your_actions: Vec<YourAction>,
    pub waiting_on_others: Vec<WaitingOn>,
    pub decisions: Vec<DecisionRef>,
    pub time_this_week_seconds: f64,
    pub people: Vec<NamedRef>,
    pub meeting_ids: Vec<String>,
}

// ------------------------------------------------------------ phone → host

/// `action.setStatus`, the only op in schema version 1.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetStatusOp {
    #[serde(rename = "type")]
    pub kind: String,
    pub meeting_id: String,
    pub action_id: String,
    pub action_text: Option<String>,
    pub status: String,
}

pub const SET_STATUS: &str = "action.setStatus";

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct AskTurn {
    pub role: String,
    pub text: String,
}

#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AskRequestScope {
    pub day: Option<String>,
    pub meeting_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AskRequest {
    pub request_id: String,
    pub question: String,
    pub history: Option<Vec<AskTurn>>,
    pub scope: Option<AskRequestScope>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AskCitation {
    pub index: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub meeting_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at: Option<f64>,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AskResult {
    pub request_id: String,
    pub answer: String,
    pub citations: Vec<AskCitation>,
    pub engine_label: String,
    /// `mac` for an engine on this computer (the protocol's value), `remote`
    /// for an approved server.
    pub location: String,
    pub answered_at: String,
}
