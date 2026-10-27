//! Day Digest: `journal/YYYY-MM-DD.md` plus its `.meta.json` sidecar
//! (`DayDigestJournalWriter.swift`, `DayDigestPresentation.swift`).

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

/// `journal/YYYY-MM-DD.meta.json` (v2, `DayDigestGenerationMetadata`).
/// Dates use Swift's default encoding (seconds since 2001-01-01), which the
/// macOS decoder requires; ISO strings are accepted when reading.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DigestMeta {
    #[serde(default = "default_meta_version")]
    pub version: u32,
    #[serde(default)]
    pub quality: DigestQuality,
    #[serde(with = "swift_date")]
    pub generated_at: DateTime<Utc>,
    /// Modification time of the journal when the sidecar was written;
    /// filled in by `Library::save_digest` when `None`.
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
    /// Repeated degraded writes for unchanged evidence (at most 3).
    #[serde(default)]
    pub degraded_attempt_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence_signature: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meeting_evidence_signature: Option<String>,
    /// SHA-256 of the journal Markdown. A journal whose digest no longer
    /// matches was edited by the user and is never overwritten. Filled in by
    /// `Library::save_digest` when empty.
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

/// Active seconds of evidence that reached the digest over all tracked seconds.
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
    /// No status lead; shown under "Other work".
    Unknown,
}

impl TaskStatus {
    /// The task group heading (`DayDigestPresentation.TaskGroup.Kind.title`).
    pub fn group_title(self) -> &'static str {
        match self {
            TaskStatus::Blocked => "Blocked",
            TaskStatus::InProgress => "In progress",
            TaskStatus::Unknown => "Other work",
            TaskStatus::Completed => "Done",
        }
    }
}

/// One task in the digest (`### Tasks` bullets).
#[derive(Clone, Debug, PartialEq)]
pub struct DigestTask {
    /// The bold heading, or the whole item when it has none (then
    /// `has_heading` is false and `summary` is empty).
    pub title: String,
    pub has_heading: bool,
    pub status: TaskStatus,
    pub summary: String,
    pub next_step: Option<String>,
    /// `09:00–10:30` from older `**time · topic**` headings.
    pub time_range: Option<String>,
    /// `[screen:N]` source IDs, when present.
    pub screen_sources: Vec<i64>,
}

/// One row of the `## Time allocation` table.
#[derive(Clone, Debug, PartialEq)]
pub struct DigestTimeAllocation {
    pub app: String,
    /// As written ("2h 5m", "<1m").
    pub detail: String,
    pub seconds: f64,
}

/// `## Full activity log` entries grouped by hour.
#[derive(Clone, Debug, PartialEq)]
pub struct DigestActivityGroup {
    /// Two-digit hour ("09"), or "Other".
    pub hour: String,
    pub entries: Vec<DigestActivityEntry>,
}

impl DigestActivityGroup {
    /// "09:00–09:59".
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

/// The digest parsed back from Markdown for display.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DayDigest {
    pub day: Option<chrono::NaiveDate>,
    pub markdown: String,
    /// The concise overview: at most three bullets, or the paragraph(s).
    pub at_a_glance_markdown: String,
    /// "At a glance" items, shown as Highlights (at most 3).
    pub highlights: Vec<String>,
    /// Ordered as written; group them with `TaskStatus::group_title`
    /// (Blocked, In progress, Other work, Done).
    pub tasks: Vec<DigestTask>,
    pub other_activity: Vec<DigestTask>,
    pub decisions: Vec<String>,
    pub blockers: Vec<String>,
    /// Follow-ups that are neither decisions, blockers nor a task's next step.
    pub follow_ups: Vec<String>,
    /// The same follow-ups as rows (title plus optional next step).
    pub follow_up_tasks: Vec<DigestTask>,
    pub meetings_markdown: Option<String>,
    pub agent_sessions_markdown: Option<String>,
    pub time_allocations: Vec<DigestTimeAllocation>,
    pub activity_groups: Vec<DigestActivityGroup>,
    pub meta: Option<DigestMeta>,
    /// The journal file's modification time.
    pub modified_at: Option<DateTime<Utc>>,
    pub latest_evidence_at: Option<DateTime<Utc>>,
    /// Newer evidence exists than what the digest covers.
    pub is_stale: bool,
}
