use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::time::swift_date;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DigestQuality {
    #[default]
    Complete,
    Partial,
    Fallback,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DigestMeta {
    #[serde(default = "default_meta_version")]
    pub version: u32,
    #[serde(default)]
    pub quality: DigestQuality,
    #[serde(with = "swift_date")]
    pub generated_at: DateTime<Utc>,
    #[serde(
        default,
        with = "swift_date::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub journal_modified_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        with = "swift_date::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub evidence_latest_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub degraded_attempt_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence_signature: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meeting_evidence_signature: Option<String>,
    #[serde(default)]
    pub journal_digest: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coverage: Option<DigestCoverage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub engine: Option<String>,
}

impl Default for DigestMeta {
    fn default() -> Self {
        Self {
            version: 2,
            quality: DigestQuality::Complete,
            generated_at: crate::time::now_seconds(),
            journal_modified_at: None,
            evidence_latest_at: None,
            degraded_attempt_count: 0,
            evidence_signature: None,
            meeting_evidence_signature: None,
            journal_digest: String::new(),
            coverage: None,
            engine: None,
        }
    }
}

fn default_meta_version() -> u32 {
    2
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DigestCoverage {
    pub covered_seconds: f64,
    pub tracked_seconds: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Completed,
    InProgress,
    Blocked,
    Unknown,
}

impl TaskStatus {
    pub fn group_title(self) -> &'static str {
        match self {
            TaskStatus::Blocked => "Blocked",
            TaskStatus::InProgress => "In progress",
            TaskStatus::Unknown => "Other work",
            TaskStatus::Completed => "Done",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DigestTask {
    pub title: String,
    pub has_heading: bool,
    pub status: TaskStatus,
    pub summary: String,
    pub next_step: Option<String>,
    pub time_range: Option<String>,
    pub screen_sources: Vec<i64>,
    pub source_moments: Vec<Option<DigestSourceMoment>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DigestSourceMoment {
    pub id: i64,
    pub app: String,
    pub document_name: String,
    pub ts: DateTime<Utc>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DigestTimeAllocation {
    pub app: String,
    pub detail: String,
    pub seconds: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DigestActivityGroup {
    pub hour: String,
    pub entries: Vec<DigestActivityEntry>,
}

impl DigestActivityGroup {
    pub fn label(&self) -> String {
        match self.hour.parse::<u32>() {
            Ok(hour) => format!("{hour:02}:00–{hour:02}:59"),
            Err(_) => self.hour.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DigestActivityEntry {
    pub headline: String,
    pub evidence: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DayDigest {
    pub day: Option<chrono::NaiveDate>,
    pub markdown: String,
    pub at_a_glance_markdown: String,
    pub highlights: Vec<String>,
    pub tasks: Vec<DigestTask>,
    pub other_activity: Vec<DigestTask>,
    pub decisions: Vec<String>,
    pub blockers: Vec<String>,
    pub follow_ups: Vec<String>,
    pub follow_up_tasks: Vec<DigestTask>,
    pub meetings_markdown: Option<String>,
    pub agent_sessions_markdown: Option<String>,
    pub time_allocations: Vec<DigestTimeAllocation>,
    pub activity_groups: Vec<DigestActivityGroup>,
    pub meta: Option<DigestMeta>,
    pub modified_at: Option<DateTime<Utc>>,
    pub latest_evidence_at: Option<DateTime<Utc>>,
    pub is_stale: bool,
}
