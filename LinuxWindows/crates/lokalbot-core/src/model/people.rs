//! People: `people/curation.json` plus profiles derived from meetings
//! (`PeopleDirectory.swift`, `PeopleCuration.swift`).

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
pub struct MeetingRef {
    pub id: Uuid,
    pub title: String,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    /// Parts of one call recorded separately share it.
    pub calendar_event_id: Option<String>,
    /// Named people in the meeting other than the user.
    pub participant_count: usize,
}

/// A project named around a person (`PersonProfile.ProjectLink`).
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectLink {
    /// The project's ID on the Projects page.
    pub id: String,
    pub name: String,
    pub is_tracked: bool,
    pub mentions: usize,
}

/// A person assembled from speaker names, calendar attendees and action owners.
#[derive(Clone, Debug, PartialEq)]
pub struct PersonProfile {
    /// `person-%016llx` of the join key.
    pub id: String,
    pub name: String,
    pub other_names: Vec<String>,
    /// Every person ID folded into this one, its own first; curation saved
    /// under an earlier ID still applies.
    pub member_ids: Vec<String>,
    /// Newest first; every recording, including parts of one call.
    pub meetings: Vec<MeetingRef>,
    /// Open or deferred work the person owns, attention order.
    pub their_actions: Vec<ActionThread>,
    /// The user's open work that names the person or came from a small
    /// meeting with them, attention order.
    pub my_actions: Vec<ActionThread>,
    /// Newest first, at most 8.
    pub decisions: Vec<(MeetingRef, Decision)>,
    /// Up to three lines from the newest meeting notes about the person.
    pub recent_notes: Vec<String>,
    /// The meeting `recent_notes` come from.
    pub notes_meeting: Option<MeetingRef>,
    /// Names of projects named around the person (see `project_links`).
    pub projects: Vec<String>,
    pub project_links: Vec<ProjectLink>,
}

impl PersonProfile {
    pub fn last_met(&self) -> Option<DateTime<Utc>> {
        self.meetings.iter().map(|m| m.started_at).max()
    }

    /// Meetings as occasions: a call recorded in parts counts once.
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
