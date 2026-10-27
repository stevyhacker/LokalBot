//! Day memory: activity blocks, screen moments and work sessions
//! (`ActivityTracker.swift`, `TimelineWorkSession.swift`, `ScreenshotService.swift`).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// One contiguous stretch in a single app/window (`activity_blocks` row).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ActivityBlock {
    pub id: i64,
    pub app: String,
    /// Cleared after the retention window; `Private` app with an empty title
    /// for excluded apps and sites.
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

impl ActivityBlock {
    pub fn duration_seconds(&self) -> f64 {
        (self.end - self.start).num_milliseconds().max(0) as f64 / 1000.0
    }
}

/// What the sampler saw at one instant, before blocks are formed.
#[derive(Clone, Debug, PartialEq)]
pub struct ActivitySample {
    pub at: DateTime<Utc>,
    pub app: String,
    /// Executable or desktop-file id, used for exclusion rules.
    pub app_id: String,
    pub title: String,
    pub url: Option<String>,
    pub idle_seconds: f64,
}

/// A retained screen context moment (`screenshots` row). Pixels, when kept,
/// are encrypted on disk and never leave the app.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScreenMoment {
    pub id: i64,
    pub ts: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    pub capture_trigger: String,
    /// Empty when only text was kept or after pixels expired.
    pub path: String,
    pub source_url: String,
    pub document_name: String,
    pub meeting_id: Option<Uuid>,
    pub privacy_redactions: i64,
    pub text: Option<String>,
    pub saved_note: Option<String>,
    pub is_saved: bool,
}

/// Work sessions computed on the fly from activity blocks
/// (`TimelineWorkSession.sessions`), or a recorded meeting on the timeline.
#[derive(Clone, Debug, PartialEq)]
pub struct WorkSession {
    /// `work-<first block id>` or `meeting-<UUID>`.
    pub id: String,
    /// Up to two representative window titles joined by " · ", or the
    /// session's apps ("AppA, AppB +2") when no title covered enough of it.
    pub title: String,
    /// True when `title` lists apps because no window title named the session.
    pub title_names_apps: bool,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    /// Union of block intervals, in seconds.
    pub active_seconds: f64,
    /// The app with the most time.
    pub primary_app: String,
    /// Apps in order of time spent.
    pub apps: Vec<String>,
    pub block_ids: Vec<i64>,
    /// Observed window titles, most time first.
    pub notable_titles: Vec<String>,
    pub context_switch_count: usize,
    /// Set when the session is a recorded meeting rather than app activity.
    pub meeting_id: Option<Uuid>,
}

impl WorkSession {
    pub fn is_meeting(&self) -> bool {
        self.meeting_id.is_some()
    }

    pub fn duration_seconds(&self) -> f64 {
        (self.end - self.start).num_milliseconds().max(0) as f64 / 1000.0
    }
}

/// Time per app for one local day.
#[derive(Clone, Debug, PartialEq)]
pub struct AppUsage {
    pub app: String,
    pub seconds: f64,
}

/// Everything Today and Timeline show for one local day.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DayActivity {
    pub day: Option<chrono::NaiveDate>,
    pub blocks: Vec<ActivityBlock>,
    pub sessions: Vec<WorkSession>,
    pub app_usage: Vec<AppUsage>,
    pub tracked_seconds: f64,
    pub moment_count: usize,
    pub meeting_count: usize,
}

/// How much screen context day memory keeps (`screenContextCaptureMode`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ScreenContextMode {
    #[default]
    #[serde(rename = "Activity only")]
    ActivityOnly,
    #[serde(rename = "Text context")]
    Text,
    #[serde(rename = "Text + visual context")]
    TextAndVisual,
}

impl ScreenContextMode {
    pub const ALL: [ScreenContextMode; 3] = [Self::ActivityOnly, Self::Text, Self::TextAndVisual];

    pub fn label(self) -> &'static str {
        match self {
            Self::ActivityOnly => "Activity only",
            Self::Text => "Text context",
            Self::TextAndVisual => "Text + visual context",
        }
    }
}
