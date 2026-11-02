//! Ask conversations (`chats/<UUID>.json.enc`, see `crate::chats`).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::ask_scope::{AskSourceScope, QuestionScope, canonical_scope_key, is_canonical_day_key};
use crate::ids::uuid_upper_serde;
use crate::time::iso_seconds;

/// The title of a conversation with no question yet.
pub const NEW_CONVERSATION_TITLE: &str = "New conversation";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawConversation")]
pub struct Conversation {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub title: String,
    #[serde(with = "iso_seconds")]
    pub created_at: DateTime<Utc>,
    #[serde(with = "iso_seconds")]
    pub updated_at: DateTime<Utc>,
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
}

/// What `Conversation.init(from:)` reads: every field may be missing, and turns
/// saved before question scopes existed are migrated here.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawConversation {
    #[serde(default, with = "uuid_upper_serde::option")]
    id: Option<Uuid>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default, with = "iso_seconds::option")]
    created_at: Option<DateTime<Utc>>,
    #[serde(default, with = "iso_seconds::option")]
    updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    messages: Vec<ChatMessage>,
}

impl From<RawConversation> for Conversation {
    fn from(raw: RawConversation) -> Self {
        let created_at = raw.created_at.unwrap_or_else(crate::time::now_seconds);
        let messages = raw
            .messages
            .into_iter()
            .map(|message| message.migrated(created_at))
            .collect();
        Self {
            id: raw.id.unwrap_or_else(Uuid::new_v4),
            title: raw.title.unwrap_or_else(|| NEW_CONVERSATION_TITLE.into()),
            created_at,
            updated_at: raw.updated_at.unwrap_or(created_at),
            messages,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    User,
    Assistant,
}

const CURRENT_SOURCE_SCOPE_SCHEMA_VERSION: u32 = 2;

/// One turn, stored under the Mac's key names (`ChatMessage` in
/// `ChatViewModel.swift`) so a conversation opens on either computer.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawChatMessage")]
pub struct ChatMessage {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub role: ChatRole,
    /// Assistant text keeps citations inline as `[meeting:<UUID>@m:ss]`,
    /// `[meeting:<UUID>]` or `[screen:<id>]`; the UI renders them as `[n]`.
    pub text: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub activity: Vec<ChatActivity>,
    #[serde(
        default,
        with = "iso_seconds::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub created_at: Option<DateTime<Utc>>,
    /// An older turn dated from its conversation: the UI shows no time for it.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub created_at_is_estimated: bool,
    /// Sources enabled for this question. Empty on legacy turns.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub source_scopes: Vec<AskSourceScope>,
    /// The civil day or range this question was limited to: `YYYY-MM-DD` or
    /// `YYYY-MM-DD...YYYY-MM-DD` (`AskDateScope.storageKey`). Kept apart from the
    /// sources so a date filter never grants one.
    #[serde(default, rename = "dayScope", skip_serializing_if = "Option::is_none")]
    pub day_scope_key: Option<String>,
    /// Civil days of screens attached to the question. The captured text itself
    /// stays out of the conversation; these preserve where it came from.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attached_screen_day_keys: Vec<String>,
    /// Meetings the question was bound to. `Some` with none is still a boundary.
    #[serde(
        default,
        rename = "meetingIDs",
        with = "uuid_upper_serde::vec",
        skip_serializing_if = "Option::is_none"
    )]
    pub meeting_ids: Option<Vec<Uuid>>,
    /// Screen moments the question was bound to.
    #[serde(
        default,
        rename = "screenSnapshotIDs",
        skip_serializing_if = "Option::is_none"
    )]
    pub screen_snapshot_ids: Option<Vec<i64>>,
    /// The app a question's screen search was limited to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screen_app: Option<String>,
    /// Always written as the current version, as on the Mac.
    #[serde(serialize_with = "serialize_schema_version")]
    pub source_scope_schema_version: u32,
    /// Version-1 turns didn't save enough to be reused or retried under a
    /// narrower question.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub legacy_scope_is_ambiguous: bool,
    /// The turn failed or was stopped: shown as an error, with Retry.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub is_error: bool,
    /// On the turn that answers a "Remember …" message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remember_receipt: Option<RememberReceipt>,
    /// The Personal Context items given to the model for this answer.
    #[serde(
        default,
        rename = "usedClaimIDs",
        with = "uuid_upper_serde::vec",
        skip_serializing_if = "Option::is_none"
    )]
    pub used_claim_ids: Option<Vec<Uuid>>,
}

fn serialize_schema_version<S: serde::Serializer>(
    _: &u32,
    serializer: S,
) -> Result<S::Ok, S::Error> {
    serializer.serialize_u32(CURRENT_SOURCE_SCOPE_SCHEMA_VERSION)
}

/// What `ChatMessage.init(from:)` reads.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawChatMessage {
    #[serde(default, with = "uuid_upper_serde::option")]
    id: Option<Uuid>,
    role: ChatRole,
    text: String,
    #[serde(default)]
    activity: Vec<ChatActivity>,
    #[serde(default, with = "iso_seconds::option")]
    created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    created_at_is_estimated: Option<bool>,
    #[serde(default)]
    source_scopes: Vec<AskSourceScope>,
    /// A string on current turns; older builds saved an instant, or a key that
    /// no longer parses. Kept raw so a dropped value can mark the turn ambiguous.
    #[serde(default, rename = "dayScope", deserialize_with = "present_value")]
    day_scope: Option<serde_json::Value>,
    #[serde(default)]
    attached_screen_day_keys: Vec<String>,
    #[serde(default, rename = "meetingIDs", with = "uuid_upper_serde::vec")]
    meeting_ids: Option<Vec<Uuid>>,
    #[serde(default, rename = "screenSnapshotIDs")]
    screen_snapshot_ids: Option<Vec<i64>>,
    #[serde(default)]
    screen_app: Option<String>,
    #[serde(default)]
    source_scope_schema_version: Option<u32>,
    #[serde(default)]
    legacy_scope_is_ambiguous: bool,
    #[serde(default)]
    is_error: bool,
    #[serde(default)]
    remember_receipt: Option<RememberReceipt>,
    #[serde(default, rename = "usedClaimIDs", with = "uuid_upper_serde::vec")]
    used_claim_ids: Option<Vec<Uuid>>,
}

/// Tells a present `null` from a missing key.
fn present_value<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<serde_json::Value>, D::Error> {
    serde_json::Value::deserialize(deserializer).map(Some)
}

impl From<RawChatMessage> for ChatMessage {
    fn from(raw: RawChatMessage) -> Self {
        let mut legacy_scope_is_ambiguous = raw.legacy_scope_is_ambiguous;
        let day_scope_key = raw
            .day_scope
            .as_ref()
            .and_then(|value| value.as_str())
            .and_then(canonical_scope_key);
        // An absolute date from an older build: its time zone was never saved,
        // so turning it into a civil day could move the boundary. Drop the day
        // and keep a retry from silently widening the old request.
        if raw.day_scope.is_some() && day_scope_key.is_none() {
            legacy_scope_is_ambiguous = true;
        }
        Self {
            id: raw.id.unwrap_or_else(Uuid::new_v4),
            role: raw.role,
            text: raw.text,
            activity: raw.activity,
            created_at_is_estimated: raw
                .created_at_is_estimated
                .unwrap_or(raw.created_at.is_none()),
            created_at: raw.created_at,
            source_scopes: raw.source_scopes,
            day_scope_key,
            attached_screen_day_keys: raw
                .attached_screen_day_keys
                .into_iter()
                .filter(|key| is_canonical_day_key(key))
                .collect(),
            meeting_ids: raw.meeting_ids,
            screen_snapshot_ids: raw.screen_snapshot_ids,
            screen_app: raw.screen_app,
            source_scope_schema_version: raw.source_scope_schema_version.unwrap_or(1),
            legacy_scope_is_ambiguous,
            is_error: raw.is_error,
            remember_receipt: raw.remember_receipt,
            used_claim_ids: raw.used_claim_ids,
        }
    }
}

impl ChatMessage {
    /// A new turn at this moment, with no question scope.
    pub fn new(role: ChatRole, text: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            role,
            text: text.into(),
            activity: Vec::new(),
            created_at: Some(crate::time::now_seconds()),
            created_at_is_estimated: false,
            source_scopes: Vec::new(),
            day_scope_key: None,
            attached_screen_day_keys: Vec::new(),
            meeting_ids: None,
            screen_snapshot_ids: None,
            screen_app: None,
            source_scope_schema_version: CURRENT_SOURCE_SCOPE_SCHEMA_VERSION,
            legacy_scope_is_ambiguous: false,
            is_error: false,
            remember_receipt: None,
            used_claim_ids: None,
        }
    }

    /// Records the boundary of the question this turn belongs to.
    pub fn with_scope(mut self, scope: &QuestionScope) -> Self {
        self.source_scopes = scope.sources.clone();
        self.day_scope_key = scope.day_scope_key.clone();
        self.attached_screen_day_keys = scope.attached_screen_day_keys.clone();
        self.meeting_ids = scope.meeting_ids.clone();
        self.screen_snapshot_ids = scope.screen_snapshot_ids.clone();
        self.screen_app = scope.screen_app.clone();
        self
    }

    /// `Conversation.init(from:)`: a turn with no date takes its conversation's,
    /// marked estimated, and version-1 scopes are never trusted for reuse.
    fn migrated(mut self, conversation_created_at: DateTime<Utc>) -> Self {
        if self.created_at.is_none() {
            self.created_at = Some(conversation_created_at);
            self.created_at_is_estimated = true;
        }
        if self.source_scope_schema_version < CURRENT_SOURCE_SCOPE_SCHEMA_VERSION {
            // Version 1 also omitted pinned-screen provenance, so even a
            // Meetings-only label could have hidden captured text in its prompt.
            self.legacy_scope_is_ambiguous = true;
            // Version 1 overloaded Today as a source and, selected alone, as a
            // one-day grant to every source. Restore source types without
            // inventing a civil day; the old answer stays history for full scope.
            if self.source_scopes.contains(&AskSourceScope::Today) {
                let selected: std::collections::BTreeSet<_> =
                    self.source_scopes.iter().copied().collect();
                if selected != AskSourceScope::defaults() {
                    self.source_scopes = AskSourceScope::ALL.to_vec();
                }
                self.day_scope_key = None;
            }
            self.source_scope_schema_version = CURRENT_SOURCE_SCOPE_SCHEMA_VERSION;
        }
        self
    }
}

/// `ChatMessage.RememberReceipt`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RememberReceipt {
    /// The saved claim, or `None` when the statement was refused.
    #[serde(
        default,
        rename = "claimID",
        with = "uuid_upper_serde::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub claim_id: Option<Uuid>,
}

/// One tool step shown as "worked: searched transcripts · read summary".
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChatActivity {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub tool: String,
    #[serde(default)]
    pub icon: String,
    pub text: String,
    #[serde(default)]
    pub done: bool,
}

/// A citation parsed from assistant text.
#[derive(Clone, Debug, PartialEq)]
pub enum Citation {
    Meeting { meeting_id: Uuid, at: Option<f64> },
    Screen { snapshot_id: i64 },
}

impl Citation {
    /// Parses every `[meeting:…]`/`[screen:…]` marker in order of appearance,
    /// keeping the first occurrence of each.
    pub fn parse_all(text: &str) -> Vec<(std::ops::Range<usize>, Citation)> {
        let mut out = Vec::new();
        let mut cursor = 0;
        while let Some(open) = text[cursor..].find('[') {
            let start = cursor + open;
            let Some(close_rel) = text[start..].find(']') else {
                break;
            };
            let end = start + close_rel + 1;
            let inner = &text[start + 1..end - 1];
            if let Some(rest) = inner.strip_prefix("meeting:") {
                let (id, at) = match rest.split_once('@') {
                    Some((id, at)) => (id, crate::time::parse_stamp(at)),
                    None => (rest, None),
                };
                if let Ok(meeting_id) = Uuid::parse_str(id.trim()) {
                    out.push((start..end, Citation::Meeting { meeting_id, at }));
                }
            } else if let Some(rest) = inner.strip_prefix("screen:")
                && let Ok(snapshot_id) = rest.trim().parse()
            {
                out.push((start..end, Citation::Screen { snapshot_id }));
            }
            cursor = end;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_meeting_and_screen_citations() {
        let text = "Redis [meeting:11111111-1111-4111-8111-111111111111@0:12] and [screen:42] [x]";
        let parsed = Citation::parse_all(text);
        assert_eq!(parsed.len(), 2);
        assert!(matches!(parsed[0].1, Citation::Meeting { at: Some(t), .. } if t == 12.0));
        assert!(matches!(parsed[1].1, Citation::Screen { snapshot_id: 42 }));
    }
}
