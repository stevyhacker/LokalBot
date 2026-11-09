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

impl TrackedProject {
    /// Its name and other names, matched alike.
    pub fn all_names(&self) -> impl Iterator<Item = &String> {
        std::iter::once(&self.name).chain(self.other_names.iter())
    }
}

impl ProjectCuration {
    /// The tracked project already known by this name, if any.
    pub fn tracked_named(&self, name: &str) -> Option<&TrackedProject> {
        let key = crate::people::normalized(name);
        if key.is_empty() {
            return None;
        }
        self.tracked
            .iter()
            .find(|p| p.all_names().any(|n| crate::people::normalized(n) == key))
    }

    /// Folds one tracked project into another: its names become the target's
    /// other names (`ProjectStore.merge`). Returns whether anything changed;
    /// the caller drops the source's note.
    pub fn merge(&mut self, source: Uuid, target: Uuid) -> bool {
        if source == target {
            return false;
        }
        let Some(source_project) = self.tracked.iter().find(|p| p.id == source).cloned() else {
            return false;
        };
        let Some(target_project) = self.tracked.iter_mut().find(|p| p.id == target) else {
            return false;
        };
        let names: Vec<String> = target_project
            .other_names
            .iter()
            .chain(source_project.all_names())
            .cloned()
            .collect();
        target_project.other_names = clean_other_names(&names, &target_project.name);
        self.tracked.retain(|p| p.id != source);
        true
    }

    /// Adds a suggestion's name to a tracked project (`ProjectStore.addName`).
    pub fn add_name(&mut self, name: &str, id: Uuid) -> bool {
        let Some(project) = self.tracked.iter_mut().find(|p| p.id == id) else {
            return false;
        };
        let mut names = project.other_names.clone();
        names.push(name.to_string());
        project.other_names = clean_other_names(&names, &project.name);
        true
    }
}

/// Single-spaced, without blanks, repeats or the project's own name
/// (`ProjectStore.cleanOtherNames`).
pub fn clean_other_names(names: &[String], excluding: &str) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    seen.insert(crate::people::normalized(excluding));
    names
        .iter()
        .map(|n| n.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|n| {
            let key = crate::people::normalized(n);
            !key.is_empty() && seen.insert(key)
        })
        .collect()
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
    /// Work the overnight review named that no tracked project covers.
    SuggestedReview,
}

/// What the overnight review keeps about a project (`ProjectProfile.ReviewNote`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReviewNote {
    pub name: String,
    pub status: String,
    pub last_active_day: String,
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
    /// `tracked:<UUID>`, `topic:<normalized name>` or `review:<normalized name>`.
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
    /// The overnight review's projects this one covers.
    pub review_notes: Vec<ReviewNote>,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn tracked(id: u128, name: &str, others: &[&str]) -> TrackedProject {
        TrackedProject {
            id: Uuid::from_u128(id),
            name: name.to_string(),
            other_names: others.iter().map(|s| s.to_string()).collect(),
            created_at: chrono::TimeZone::with_ymd_and_hms(&Utc, 2026, 10, 1, 9, 0, 0).unwrap(),
        }
    }

    #[test]
    fn merging_moves_every_name_to_the_target() {
        let mut curation = ProjectCuration {
            version: 1,
            tracked: vec![
                tracked(1, "Atlas", &["Orion"]),
                tracked(2, "Project X", &["Atlas Web", "orion"]),
            ],
            hidden_names: Vec::new(),
        };
        assert!(!curation.merge(Uuid::from_u128(1), Uuid::from_u128(1)));
        assert!(!curation.merge(Uuid::from_u128(9), Uuid::from_u128(1)));
        assert!(curation.merge(Uuid::from_u128(1), Uuid::from_u128(2)));
        assert_eq!(curation.tracked.len(), 1);
        assert_eq!(curation.tracked[0].name, "Project X");
        assert_eq!(
            curation.tracked[0].other_names,
            vec!["Atlas Web", "orion", "Atlas"],
            "a repeated name is kept once, spelled as the target had it"
        );
    }

    #[test]
    fn other_names_are_cleaned() {
        let names = vec![
            "  Atlas ".to_string(),
            "atlas".to_string(),
            "Orion".to_string(),
            "Project X".to_string(),
        ];
        assert_eq!(
            clean_other_names(&names, "Project X"),
            vec!["Atlas".to_string(), "Orion".to_string()]
        );
    }

    #[test]
    fn suggestions_become_other_names() {
        let mut curation = ProjectCuration {
            version: 1,
            tracked: vec![tracked(1, "Atlas", &[])],
            hidden_names: Vec::new(),
        };
        assert!(curation.add_name("  Project   X ", Uuid::from_u128(1)));
        assert!(curation.add_name("atlas", Uuid::from_u128(1)));
        assert_eq!(curation.tracked[0].other_names, vec!["Project X"]);
        assert!(curation.tracked_named("project x").is_some());
        assert!(curation.tracked_named("ATLAS").is_some());
        assert!(curation.tracked_named("Orion").is_none());
    }

    /// `projects/tracked.json` as `ProjectStore` writes it.
    #[test]
    fn curation_reads_and_writes_the_mac_format() {
        let mac = r#"{
  "hiddenNames" : [
    "standup"
  ],
  "tracked" : [
    {
      "createdAt" : "2026-10-01T09:00:00Z",
      "id" : "00000000-0000-0000-0000-00000000000A",
      "name" : "Atlas",
      "otherNames" : [
        "Orion"
      ]
    }
  ],
  "version" : 1
}"#;
        let curation: ProjectCuration = serde_json::from_str(mac).unwrap();
        assert_eq!(curation.tracked[0].other_names, vec!["Orion"]);
        let json = serde_json::to_value(&curation).unwrap();
        assert_eq!(
            json,
            serde_json::from_str::<serde_json::Value>(mac).unwrap()
        );
    }
}
