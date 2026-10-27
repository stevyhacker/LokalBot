//! `follow-up-draft.json` in a meeting folder (`FollowUpDraft` in
//! `MeetingOutcomeState.swift`): the follow-up the user reviews, copies and
//! sends themselves. LokalBot never sends it.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ids::uuid_upper_serde;
use crate::model::{Meeting, MeetingOutcomes};
use crate::time::iso_millis;

pub const FOLLOW_UP_FILE: &str = "follow-up-draft.json";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FollowUpDraft {
    #[serde(default = "default_schema")]
    pub schema_version: u32,
    #[serde(default)]
    pub recipient: String,
    #[serde(default)]
    pub cc: String,
    #[serde(default)]
    pub subject: String,
    #[serde(default)]
    pub body: String,
    #[serde(with = "iso_millis", default = "Utc::now")]
    pub updated_at: DateTime<Utc>,
    /// Still the outline built from the outcomes, not edited or saved.
    #[serde(default)]
    pub seeded: bool,
    #[serde(default)]
    pub reviewed: bool,
    #[serde(
        default,
        rename = "sourceMeetingID",
        with = "uuid_upper_serde::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub source_meeting_id: Option<Uuid>,
}

fn default_schema() -> u32 {
    1
}

impl FollowUpDraft {
    /// The outline macOS starts from (`FollowUpDraft.seeded`): up to three
    /// decisions and five next steps with their owners and due dates.
    pub fn seeded(meeting: &Meeting, outcomes: &MeetingOutcomes) -> Self {
        let title = meeting.display_title();
        let decisions: Vec<String> = outcomes
            .decision_records
            .iter()
            .take(3)
            .map(|d| format!("- {}", d.text))
            .collect();
        let actions: Vec<String> = outcomes
            .action_items
            .iter()
            .take(5)
            .map(|item| {
                let owner = item
                    .owner
                    .as_deref()
                    .map(|o| format!(" -- {o}"))
                    .unwrap_or_default();
                let due = item
                    .due
                    .as_deref()
                    .map(|d| format!(" ({d})"))
                    .unwrap_or_default();
                format!("- {}{owner}{due}", item.text)
            })
            .collect();
        let mut sections = vec![
            "Hi,".to_string(),
            String::new(),
            format!("Here is the follow-up from {title}."),
        ];
        if !decisions.is_empty() {
            sections.extend([String::new(), "Decisions".into(), decisions.join("\n")]);
        }
        if !actions.is_empty() {
            sections.extend([String::new(), "Next steps".into(), actions.join("\n")]);
        }
        sections.extend([String::new(), "Best,".into()]);
        Self {
            schema_version: default_schema(),
            recipient: String::new(),
            cc: String::new(),
            subject: format!("Follow-up: {title}"),
            body: sections.join("\n"),
            updated_at: crate::time::now_millis(),
            seeded: true,
            reviewed: false,
            source_meeting_id: Some(meeting.id),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_macos_draft() {
        let json = r#"{"body":"Hi","cc":"","recipient":"","reviewed":false,"schemaVersion":1,"seeded":false,"sourceMeetingID":"44444444-4444-4444-8444-444444444444","subject":"Follow-up: Sync","updatedAt":"2026-10-15T09:47:00.123Z"}"#;
        let draft: FollowUpDraft = serde_json::from_str(json).unwrap();
        assert_eq!(draft.subject, "Follow-up: Sync");
        assert!(!draft.seeded);
        let back = serde_json::to_value(&draft).unwrap();
        assert_eq!(back["updatedAt"], "2026-10-15T09:47:00.123Z");
        assert_eq!(
            back["sourceMeetingID"],
            "44444444-4444-4444-8444-444444444444"
        );
    }

    #[test]
    fn seeds_the_macos_outline() {
        let dir = tempfile::tempdir().unwrap();
        let library = crate::Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
        let meeting = library
            .create_meeting("Weekly sync", "Zoom", crate::time::now_seconds())
            .unwrap();
        let outcomes: MeetingOutcomes = serde_json::from_value(serde_json::json!({
            "actionItems": [{"id": "a1", "text": "Send the deck", "owner": "Maya", "due": "Friday"}],
            "decisionRecords": [{"id": "d1", "text": "Ship on Friday."}]
        }))
        .unwrap();
        let draft = FollowUpDraft::seeded(&meeting, &outcomes);
        assert_eq!(draft.subject, "Follow-up: Weekly sync");
        assert_eq!(
            draft.body,
            "Hi,\n\nHere is the follow-up from Weekly sync.\n\nDecisions\n- Ship on Friday.\n\nNext steps\n- Send the deck -- Maya (Friday)\n\nBest,"
        );
        library.save_follow_up_draft(&meeting, &draft).unwrap();
        let saved = library.follow_up_draft(&meeting).unwrap().unwrap();
        assert!(!saved.seeded);
        assert_eq!(saved.source_meeting_id, Some(meeting.id));
    }
}
