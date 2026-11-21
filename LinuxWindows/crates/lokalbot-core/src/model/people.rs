use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::model::outcomes::{ActionThread, Decision};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PeopleCuration {
    #[serde(default = "one")]
    pub version: u32,
    #[serde(default)]
    pub names: BTreeMap<String, String>,
    #[serde(default)]
    pub merges: Vec<PersonMerge>,
    #[serde(default)]
    pub hidden: Vec<HiddenPerson>,
}

fn one() -> u32 {
    1
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonMerge {
    #[serde(rename = "sourceID")]
    pub source_id: String,
    #[serde(rename = "targetID")]
    pub target_id: String,
    pub source_name: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HiddenPerson {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct NotePoint {
    pub text: String,
    pub speaker: Option<String>,
    pub meeting_id: Uuid,
    pub seek: Option<f64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeetingRef {
    pub id: Uuid,
    pub title: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub calendar_event_id: Option<String>,
    pub participant_count: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProjectLink {
    pub id: String,
    pub name: String,
    pub is_tracked: bool,
    pub mentions: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PersonProfile {
    pub id: String,
    pub name: String,
    pub other_names: Vec<String>,
    pub member_ids: Vec<String>,
    pub meetings: Vec<MeetingRef>,
    pub their_actions: Vec<ActionThread>,
    pub my_actions: Vec<ActionThread>,
    pub decisions: Vec<(MeetingRef, Decision)>,
    pub recent_notes: Vec<NotePoint>,
    pub notes_meeting: Option<MeetingRef>,
    pub notes_is_latest_meeting: bool,
    pub projects: Vec<String>,
    pub project_links: Vec<ProjectLink>,
}

impl PeopleCuration {
    pub fn merge(&mut self, source: &PersonProfile, target: &PersonProfile) -> bool {
        if source.id == target.id {
            return false;
        }
        for id in source.member_ids.iter().chain([&source.id]) {
            self.names.remove(id);
        }
        self.merges.push(PersonMerge {
            source_id: source.id.clone(),
            target_id: target.id.clone(),
            source_name: source.name.clone(),
        });
        true
    }

    pub fn merges_into(&self, person: &PersonProfile) -> Vec<PersonMerge> {
        let is_member = |id: &String| *id == person.id || person.member_ids.contains(id);
        self.merges
            .iter()
            .filter(|m| is_member(&m.target_id) && is_member(&m.source_id))
            .cloned()
            .collect()
    }
}

impl PersonProfile {
    pub fn last_met(&self) -> Option<DateTime<Utc>> {
        self.meetings.iter().map(|m| m.started_at).max()
    }

    pub fn meeting_count(&self) -> usize {
        crate::people::occasions(&self.meetings).len()
    }

    pub fn open_count(&self) -> usize {
        self.my_actions.len() + self.their_actions.len()
    }

    pub fn first_name(&self) -> &str {
        self.name.split_whitespace().next().unwrap_or(&self.name)
    }

    pub fn initials(&self) -> String {
        self.name
            .split_whitespace()
            .filter_map(|w| w.chars().next())
            .take(2)
            .collect::<String>()
            .to_uppercase()
    }
}
