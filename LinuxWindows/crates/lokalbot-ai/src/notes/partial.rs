use std::path::Path;
use std::time::SystemTime;

use lokalbot_core::library::{OUTCOMES_FILE, SUMMARY_FILE};
use lokalbot_core::settings::NoteTemplate;
use lokalbot_core::{MeetingOutcomes, Transcript};
use serde::{Deserialize, Serialize};

use super::view::evidence_revision;

pub const PARTIAL_FILE: &str = "notes.partial.json";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingNotesPartial {
    pub version: u32,
    pub transcript_revision: String,
    pub summary: String,
    pub outcomes: MeetingOutcomes,
    pub completed_parts: usize,
    pub total_parts: usize,
    #[serde(default)]
    pub template: NoteTemplate,
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

impl MeetingNotesPartial {
    pub fn load(folder: &Path, transcript: &Transcript) -> Option<Self> {
        let path = folder.join(PARTIAL_FILE);
        let snapshot: Self = serde_json::from_slice(&std::fs::read(&path).ok()?).ok()?;
        let revision = evidence_revision(transcript);
        if snapshot.version != 1
            || snapshot.transcript_revision != revision
            || snapshot.outcomes.transcript_revision.as_deref() != Some(revision.as_str())
            || snapshot.total_parts == 0
            || snapshot.completed_parts > snapshot.total_parts
        {
            return None;
        }
        if folder.join(OUTCOMES_FILE).is_file()
            && modified(&folder.join(SUMMARY_FILE)) >= modified(&path)
        {
            return None;
        }
        Some(snapshot)
    }
}
