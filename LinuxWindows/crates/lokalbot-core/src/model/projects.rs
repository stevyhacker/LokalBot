//! Projects: `projects/tracked.json` and `projects/summaries.json`
//! (`ProjectCuration.swift`, `ProjectStore.swift`, `ProjectLinks.swift`).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ids::uuid_upper_serde;
use crate::model::outcomes::{ActionThread, Decision};
use crate::model::people::MeetingRef;
use crate::time::iso_seconds;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCuration {
    #[serde(default = "one")]
    pub version: u32,
    #[serde(default)]
    pub tracked: Vec<TrackedProject>,
    /// Normalized names the user dismissed as "Not a Project".
    #[serde(default)]
    pub hidden_names: Vec<String>,
}

fn one() -> u32 {
    1
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackedProject {
    #[serde(with = "uuid_upper_serde")]
    pub id: Uuid,
    pub name: String,
    #[serde(default)]
    pub other_names: Vec<String>,
    #[serde(with = "iso_seconds")]
    pub created_at: DateTime<Utc>,
}

/// One entry of `projects/summaries.json`: the "Where It Stands" note.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectSummary {
    #[serde(rename = "projectID")]
    pub project_id: String,
    pub overview: String,
    #[serde(default)]
    pub points: Vec<ProjectPoint>,
    #[serde(default)]
    pub open_questions: Vec<String>,
    #[serde(default, rename = "meetingIDs")]
    pub meeting_ids: Vec<String>,
    #[serde(default)]
    pub evidence_fingerprint: String,
    #[serde(with = "iso_seconds")]
    pub generated_at: DateTime<Utc>,
    #[serde(default)]
    pub engine_name: String,
    /// "on this PC" or the remote host that wrote it.
    #[serde(default)]
    pub location: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectPoint {
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "meetingID")]
    pub meeting_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meeting_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meeting_date: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectKind {
    Tracked,
    /// A capitalized term seen in three or more meetings.
    Suggested,
}

/// A line that names a project, cut to fit around the name.
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectMention {
    pub meeting_id: Uuid,
    pub text: String,
    /// Transcript time to open the meeting at, for transcript lines.
    pub seek: Option<f64>,
}

/// Tracked window time for a project in the last 7 days.
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectWindowTime {
    pub app: String,
    pub title: String,
    pub seconds: f64,
}

/// A project joined with its meetings, actions and decisions
/// (`ProjectLinks.swift`).
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectProfile {
    /// `tracked:<UUID>` or `topic:<normalized name>`.
    pub id: String,
    pub kind: ProjectKind,
    pub name: String,
    pub other_names: Vec<String>,
    /// Newest first.
    pub meetings: Vec<MeetingRef>,
    /// Up to three lines per meeting naming the project.
    pub mentions: Vec<ProjectMention>,
    /// The user's open work on the project, attention order.
    pub my_actions: Vec<ActionThread>,
    /// Other people's open work mentioned in the last 14 days or due ahead.
    pub others_actions: Vec<ActionThread>,
    /// Other people's open work last mentioned long ago.
    pub older_others_actions: Vec<ActionThread>,
    /// Newest first, at most 8.
    pub decisions: Vec<(MeetingRef, Decision)>,
    /// Up to eight people from the project's meetings.
    pub people: Vec<String>,
    /// Tracked window time naming the project in the last 7 days.
    pub week_seconds: f64,
    /// `(YYYY-MM-DD, seconds)`, newest day first.
    pub days: Vec<(String, f64)>,
    pub windows: Vec<ProjectWindowTime>,
    pub last_active: Option<DateTime<Utc>>,
    /// The saved "Where it stands" note.
    pub summary: Option<ProjectSummary>,
}

impl ProjectProfile {
    pub fn is_tracked(&self) -> bool {
        self.kind == ProjectKind::Tracked
    }

    pub fn tracked_id(&self) -> Option<Uuid> {
        self.id
            .strip_prefix("tracked:")
            .and_then(|id| Uuid::parse_str(id).ok())
    }

    pub fn open_action_count(&self) -> usize {
        self.my_actions.len() + self.others_actions.len()
    }
}
