use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ActivityBlock {
    pub id: i64,
    pub app: String,
    pub title: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

impl ActivityBlock {
    pub fn duration_seconds(&self) -> f64 {
        (self.end - self.start).num_milliseconds().max(0) as f64 / 1000.0
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ActivitySample {
    pub at: DateTime<Utc>,
    pub app: String,
    pub app_id: String,
    pub title: String,
    pub url: Option<String>,
    pub idle_seconds: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScreenMoment {
    pub id: i64,
    pub ts: DateTime<Utc>,
    pub app: String,
    pub window_title: String,
    pub capture_trigger: String,
    pub path: String,
    pub source_url: String,
    pub document_name: String,
    pub meeting_id: Option<Uuid>,
    pub privacy_redactions: i64,
    pub text: Option<String>,
    pub saved_note: Option<String>,
    pub is_saved: bool,
    #[serde(default)]
    pub similarity_group: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct WorkSession {
    pub id: String,
    pub title: String,
    pub title_names_apps: bool,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub active_seconds: f64,
    pub primary_app: String,
    pub apps: Vec<String>,
    pub block_ids: Vec<i64>,
    pub notable_titles: Vec<String>,
    pub context_switch_count: usize,
    pub meeting_id: Option<Uuid>,
    pub project_shares: Vec<crate::coding_agents::attribution::Share>,
    pub agent_bursts: Vec<crate::coding_agents::CodingAgentBurst>,
    pub title_names_project: bool,
}

impl WorkSession {
    pub fn is_meeting(&self) -> bool {
        self.meeting_id.is_some()
    }

    pub fn duration_seconds(&self) -> f64 {
        (self.end - self.start).num_milliseconds().max(0) as f64 / 1000.0
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AppUsage {
    pub app: String,
    pub seconds: f64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct DayActivity {
    pub day: Option<chrono::NaiveDate>,
    pub blocks: Vec<ActivityBlock>,
    pub sessions: Vec<WorkSession>,
    pub app_usage: Vec<AppUsage>,
    pub tracked_seconds: f64,
    pub moment_count: usize,
    pub meeting_count: usize,
    pub agent_bursts: Vec<crate::coding_agents::CodingAgentBurst>,
    pub project_split: crate::coding_agents::attribution::DaySplit,
}

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
