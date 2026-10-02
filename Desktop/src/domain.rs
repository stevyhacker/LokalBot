use serde::{Deserialize, Serialize};

pub fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Segment {
    pub id: String,
    pub start: f64,
    pub end: f64,
    pub speaker: String,
    pub text: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Decision {
    pub text: String,
    pub source: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Action {
    pub id: String,
    pub text: String,
    pub owner: String,
    pub due: String,
    pub source: String,
    #[serde(default)]
    pub done: bool,
    #[serde(default)]
    pub corrected: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Summary {
    pub overview: String,
    #[serde(default)]
    pub decisions: Vec<Decision>,
    #[serde(default)]
    pub actions: Vec<Action>,
    #[serde(default)]
    pub questions: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Media {
    pub track: String,
    pub path: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Meeting {
    pub id: String,
    pub title: String,
    pub started_at: i64,
    pub duration: f64,
    pub app: String,
    #[serde(default)]
    pub people: Vec<String>,
    #[serde(default)]
    pub segments: Vec<Segment>,
    #[serde(default)]
    pub notes: String,
    pub summary: Option<Summary>,
    #[serde(default)]
    pub media: Vec<Media>,
    #[serde(default)]
    pub warnings: Vec<String>,
}
impl Meeting {
    pub fn empty(title: impl Into<String>) -> Self {
        Self {
            id: new_id(),
            title: title.into(),
            started_at: now(),
            duration: 0.,
            app: "Manual".into(),
            people: vec![],
            segments: vec![],
            notes: String::new(),
            summary: None,
            media: vec![],
            warnings: vec![],
        }
    }
    pub fn transcript(&self) -> String {
        self.segments
            .iter()
            .map(|s| format!("[{}] {} {}: {}", s.id, timecode(s.start), s.speaker, s.text))
            .collect::<Vec<_>>()
            .join("\n")
    }
    pub fn markdown(&self) -> String {
        let mut text = format!(
            "# {}\n\n{}\n\n",
            self.title,
            chrono::DateTime::from_timestamp(self.started_at, 0)
                .map(|d| d.to_rfc3339())
                .unwrap_or_default()
        );
        if let Some(s) = &self.summary {
            text.push_str(&format!("## Summary\n\n{}\n\n## Decisions\n\n", s.overview));
            for d in &s.decisions {
                text.push_str(&format!("- {} [{}]\n", d.text, d.source));
            }
            text.push_str("\n## Actions\n\n");
            for a in &s.actions {
                text.push_str(&format!(
                    "- [{}] {} — {} · {} [{}]\n",
                    if a.done { "x" } else { " " },
                    a.text,
                    a.owner,
                    a.due,
                    a.source
                ));
            }
        }
        text.push_str(&format!(
            "\n## Notes\n\n{}\n\n## Transcript\n\n{}\n",
            self.notes,
            self.transcript()
        ));
        text
    }
}

pub fn timecode(seconds: f64) -> String {
    let s = seconds.max(0.) as u64;
    format!("{:02}:{:02}", s / 60, s % 60)
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Evidence {
    pub id: String,
    pub meeting_id: Option<String>,
    pub title: String,
    pub kind: String,
    pub start: f64,
    pub text: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Answer {
    pub text: String,
    pub sources: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Conversation {
    pub id: String,
    pub question: String,
    pub answer: Answer,
    pub created_at: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Activity {
    pub id: String,
    pub app: String,
    pub title: String,
    pub start: i64,
    pub end: i64,
    pub private: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Moment {
    pub id: String,
    pub app: String,
    pub title: String,
    pub text: String,
    pub created_at: i64,
    pub saved: bool,
    pub pixels: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Digest {
    pub day: String,
    pub text: String,
    pub sources: Vec<String>,
    pub fingerprint: String,
    pub created_at: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum Backend {
    Local,
    OpenRouter,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub backend: Backend,
    pub endpoint: String,
    pub model: String,
    pub approved_origins: Vec<String>,
    pub revision: u64,
    pub activity_enabled: bool,
    pub screen_text_enabled: bool,
    pub pixels_enabled: bool,
    pub paused: bool,
    pub retention_days: u32,
    pub excluded_apps: Vec<String>,
    pub excluded_domains: Vec<String>,
    pub meeting_access: bool,
    pub screen_access: bool,
    pub screen_access_days: Option<u32>,
    pub agent_enabled: bool,
    pub agent_workspace: String,
    pub remote_audio: bool,
    pub account_data_policy: bool,
    pub whisper_executable: String,
    pub whisper_model: String,
    pub transcription_model: String,
    pub embedding_model: String,
    pub digest_hour: Option<u32>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            backend: Backend::Local,
            endpoint: "http://127.0.0.1:17872/v1".into(),
            model: "local".into(),
            approved_origins: vec![],
            revision: 0,
            activity_enabled: true,
            screen_text_enabled: false,
            pixels_enabled: false,
            paused: false,
            retention_days: 14,
            excluded_apps: vec!["1Password".into(), "Bitwarden".into(), "KeePassXC".into()],
            excluded_domains: vec![],
            meeting_access: false,
            screen_access: false,
            screen_access_days: Some(7),
            agent_enabled: false,
            agent_workspace: String::new(),
            remote_audio: false,
            account_data_policy: false,
            whisper_executable: "whisper-cli".into(),
            whisper_model: String::new(),
            transcription_model: "openai/whisper-large-v3-turbo".into(),
            embedding_model: String::new(),
            digest_hour: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Job {
    pub id: String,
    pub meeting_id: Option<String>,
    pub kind: String,
    pub status: String,
    pub error: Option<String>,
    pub updated_at: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Generation {
    pub purpose: String,
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost: f64,
    pub created_at: i64,
}
