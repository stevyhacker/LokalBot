use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ids::uuid_upper_serde;
use crate::time::iso_seconds;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Meeting {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub title: String,
    pub app_name: String,
    #[serde(with = "iso_seconds")]
    pub started_at: DateTime<Utc>,
    #[serde(
        default,
        with = "iso_seconds::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub ended_at: Option<DateTime<Utc>>,
    pub relative_path: String,
    #[serde(default)]
    pub has_system_track: bool,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub calendar_provider: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "calendarEventID"
    )]
    pub calendar_event_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub calendar_title: Option<String>,
    #[serde(
        default,
        with = "iso_seconds::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub scheduled_start_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        with = "iso_seconds::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub scheduled_end_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "meetingURL"
    )]
    pub meeting_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub participant_name_hints: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub calendar_participant_identities: Option<Vec<CalendarParticipantIdentity>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub calendar_agenda: Option<String>,
    #[serde(
        default,
        with = "uuid_upper_serde::vec",
        skip_serializing_if = "Option::is_none",
        rename = "mergedSourceMeetingIDs"
    )]
    pub merged_source_meeting_ids: Option<Vec<Uuid>>,
    #[serde(
        default,
        with = "uuid_upper_serde::option",
        skip_serializing_if = "Option::is_none",
        rename = "mergedIntoMeetingID"
    )]
    pub merged_into_meeting_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub imported_file_names: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recorded_duration: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_range: Option<ContentRange>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_range_source: Option<ContentRangeSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub capture_intent: Option<CaptureIntent>,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "sampleID")]
    pub sample_id: Option<String>,
    #[serde(flatten)]
    pub extra: serde_json::Map<String, serde_json::Value>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarParticipantIdentity {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email_address: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ContentRange {
    pub start: f64,
    pub end: f64,
}

impl ContentRange {
    pub fn is_valid(&self) -> bool {
        self.start.is_finite() && self.end.is_finite() && self.start >= 0.0 && self.end > self.start
    }

    pub fn apply(&self, transcript: &mut crate::model::Transcript) {
        let valid = self.is_valid();
        transcript
            .segments
            .retain(|s| valid && s.start >= self.start && s.end <= self.end);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContentRangeSource {
    UserReviewed,
    ConfirmedCallEnd,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureIntent {
    pub system_audio_requested: bool,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "appBundleID"
    )]
    pub app_bundle_id: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "meetingURL"
    )]
    pub meeting_url: Option<String>,
}

const GENERIC_TITLES: &[&str] = &[
    "meeting",
    "manual recording",
    "recording",
    "untitled meeting",
];

impl Meeting {
    pub fn new(
        title: &str,
        app_name: &str,
        started_at: DateTime<Utc>,
        relative_path: &str,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            title: title.to_string(),
            app_name: app_name.to_string(),
            started_at,
            ended_at: None,
            relative_path: relative_path.to_string(),
            has_system_track: false,
            calendar_provider: None,
            calendar_event_id: None,
            calendar_title: None,
            scheduled_start_at: None,
            scheduled_end_at: None,
            meeting_url: None,
            participant_name_hints: None,
            calendar_participant_identities: None,
            calendar_agenda: None,
            merged_source_meeting_ids: None,
            merged_into_meeting_id: None,
            imported_file_names: None,
            recorded_duration: None,
            content_range: None,
            content_range_source: None,
            capture_intent: None,
            sample_id: None,
            extra: Default::default(),
        }
    }

    pub fn is_live(&self) -> bool {
        self.ended_at.is_none()
    }

    pub fn is_merged_source(&self) -> bool {
        self.merged_into_meeting_id.is_some()
    }

    pub fn is_sample(&self) -> bool {
        self.sample_id.is_some()
    }

    pub fn is_own_work(&self) -> bool {
        !self.is_merged_source() && !self.is_sample()
    }

    pub fn is_imported(&self) -> bool {
        self.imported_file_names
            .as_ref()
            .is_some_and(|names| !names.is_empty())
    }

    pub fn is_merged_meeting(&self) -> bool {
        self.merged_source_meeting_ids
            .as_ref()
            .is_some_and(|ids| !ids.is_empty())
    }

    pub fn additional_saved_audio_duration(&self) -> f64 {
        match (&self.content_range, self.recorded_duration) {
            (Some(range), Some(recorded)) => (recorded - range.end).max(0.0),
            _ => 0.0,
        }
    }

    pub fn valid_content_range(&self) -> Option<ContentRange> {
        self.content_range.filter(ContentRange::is_valid)
    }

    pub fn started_plus(&self, seconds: f64) -> DateTime<Utc> {
        chrono::TimeDelta::try_milliseconds((seconds * 1000.0) as i64)
            .and_then(|length| self.started_at.checked_add_signed(length))
            .unwrap_or(self.started_at)
    }

    pub fn duration_seconds(&self) -> f64 {
        if let Some(recorded) = self.recorded_duration {
            return recorded;
        }
        let end = self.ended_at.unwrap_or_else(Utc::now);
        (end - self.started_at).num_milliseconds().max(0) as f64 / 1000.0
    }

    pub fn display_title(&self) -> String {
        let trimmed = self.title.trim();
        let lower = trimmed.to_lowercase();
        let generic = trimmed.is_empty()
            || GENERIC_TITLES.contains(&lower.as_str())
            || lower.starts_with("meeting ");
        if !generic {
            return trimmed.to_string();
        }
        if let Some(calendar) = self
            .calendar_title
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty())
        {
            return calendar.to_string();
        }
        format!(
            "{} at {}",
            self.app_name,
            crate::time::clock_time(self.started_at)
        )
    }

    pub fn short_id(&self) -> String {
        crate::ids::short_id(&self.id)
    }
}
