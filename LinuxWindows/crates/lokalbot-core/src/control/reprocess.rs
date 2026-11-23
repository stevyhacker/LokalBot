use std::path::Path;

use serde_json::{Map, Value, json};

use super::protocol::ControlError;
use crate::library::MeetingLookup;
use crate::model::Meeting;

pub const SETTLED_STATES: [&str; 3] = ["idle", "failed", "waitingForModels"];

pub fn work(params: &Map<String, Value>) -> Result<(bool, bool), ControlError> {
    let transcribe = flag(params, "transcribe", false)?;
    let summarize = flag(params, "summarize", true)?;
    if !transcribe && !summarize {
        return Err(ControlError::invalid_request(
            "Ask meetings.reprocess to transcribe, summarize, or both.",
        ));
    }
    Ok((transcribe, summarize))
}

fn flag(params: &Map<String, Value>, key: &str, default: bool) -> Result<bool, ControlError> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(ControlError::invalid_request(format!(
            "\"{key}\" must be true or false."
        ))),
    }
}

pub fn meeting(meetings: &[Meeting], params: &Map<String, Value>) -> Result<Meeting, ControlError> {
    let id = params
        .get("id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .ok_or_else(|| {
            ControlError::invalid_request(
                "Name the meeting in \"id\": an ID from `lokalbot-cli list`, or latest.",
            )
        })?;
    match MeetingLookup::find(meetings, id) {
        MeetingLookup::Found(meeting) => Ok(meeting),
        MeetingLookup::NotFound | MeetingLookup::Ambiguous(_) => {
            Err(ControlError::unknown_meeting(id))
        }
    }
}

pub fn require_transcript(
    meeting: &Meeting,
    folder: &Path,
    transcribe: bool,
) -> Result<(), ControlError> {
    if transcribe || folder.join("transcript.json").exists() {
        return Ok(());
    }
    Err(ControlError::invalid_request(format!(
        "{} has no transcript to summarize yet. Pass --transcribe to transcribe it first.",
        meeting.title
    )))
}

pub fn status(meeting: &Meeting, state: &str, message: Option<&str>, folder: &Path) -> Value {
    let mut object = Map::new();
    object.insert("id".into(), json!(meeting.short_id()));
    object.insert("title".into(), json!(meeting.title));
    object.insert("state".into(), json!(state));
    if let Some(message) = message {
        object.insert("message".into(), json!(message));
    }
    if let Ok(modified) = std::fs::metadata(folder.join("summary.md")).and_then(|m| m.modified()) {
        let saved: chrono::DateTime<chrono::Utc> = modified.into();
        object.insert(
            "notesSavedAt".into(),
            json!(saved.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
        );
    }
    Value::Object(object)
}

pub fn is_settled(state: Option<&str>) -> bool {
    SETTLED_STATES.contains(&state.unwrap_or("idle"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn meeting(id: &str, title: &str, day: u32) -> Meeting {
        serde_json::from_value(json!({
            "id": id,
            "title": title,
            "appName": "Zoom",
            "startedAt": chrono::Utc
                .with_ymd_and_hms(2026, 11, day, 10, 0, 0)
                .unwrap()
                .to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "relativePath": format!("meetings/2026/11/{day}-{title}"),
        }))
        .unwrap()
    }

    fn library() -> Vec<Meeting> {
        vec![
            meeting("fb709013-0000-4000-8000-000000000001", "Pricing review", 11),
            meeting("fb70aaaa-0000-4000-8000-000000000002", "Hiring sync", 10),
            meeting("0a11ce00-0000-4000-8000-000000000003", "Design review", 9),
        ]
    }

    fn params(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn summarizing_again_is_the_default_and_some_work_is_required() {
        assert_eq!(work(&params(json!({}))).unwrap(), (false, true));
        assert_eq!(
            work(&params(json!({"transcribe": true, "summarize": false}))).unwrap(),
            (true, false)
        );
        let nothing = work(&params(json!({"summarize": false}))).unwrap_err();
        assert_eq!(nothing.code, "invalid_request");
        let not_a_flag = work(&params(json!({"transcribe": "yes"}))).unwrap_err();
        assert_eq!(not_a_flag.code, "invalid_request");
    }

    #[test]
    fn meetings_are_found_by_short_id_full_id_or_latest() {
        let meetings = library();
        let by_short = meeting_named(&meetings, "fb709013");
        assert_eq!(by_short, "Pricing review");
        assert_eq!(
            meeting_named(&meetings, "0A11CE00-0000-4000-8000-000000000003"),
            "Design review"
        );
        assert_eq!(meeting_named(&meetings, "latest"), "Pricing review");
        for unknown in ["fb70", "deadbeef"] {
            let error = super::meeting(&meetings, &params(json!({"id": unknown}))).unwrap_err();
            assert_eq!(error.code, "unknown_meeting", "{unknown}");
        }
        let missing = super::meeting(&meetings, &params(json!({"id": "  "}))).unwrap_err();
        assert_eq!(missing.code, "invalid_request");
    }

    fn meeting_named(meetings: &[Meeting], id: &str) -> String {
        super::meeting(meetings, &params(json!({"id": id})))
            .unwrap()
            .title
    }

    #[test]
    fn summarizing_needs_a_transcript_unless_it_transcribes_first() {
        let dir = tempfile::tempdir().unwrap();
        let meeting = library().remove(0);
        let error = require_transcript(&meeting, dir.path(), false).unwrap_err();
        assert_eq!(error.code, "invalid_request");
        assert!(error.message.contains("--transcribe"), "{}", error.message);
        assert!(require_transcript(&meeting, dir.path(), true).is_ok());
        std::fs::write(dir.path().join("transcript.json"), "{}").unwrap();
        assert!(require_transcript(&meeting, dir.path(), false).is_ok());
    }

    #[test]
    fn the_status_names_the_meeting_and_when_its_notes_were_saved() {
        let dir = tempfile::tempdir().unwrap();
        let meeting = library().remove(0);
        let queued = status(&meeting, "queued", Some("Queued…"), dir.path());
        assert_eq!(queued["id"], "fb709013");
        assert_eq!(queued["title"], "Pricing review");
        assert_eq!(queued["state"], "queued");
        assert_eq!(queued["message"], "Queued…");
        assert!(queued.get("notesSavedAt").is_none());
        std::fs::write(dir.path().join("summary.md"), "# Pricing review\n").unwrap();
        let idle = status(&meeting, "idle", None, dir.path());
        assert!(idle.get("message").is_none());
        assert!(idle["notesSavedAt"].as_str().unwrap().ends_with('Z'));
    }

    #[test]
    fn waiting_stops_once_the_work_is_done_failed_or_needs_models() {
        for state in ["idle", "failed", "waitingForModels"] {
            assert!(is_settled(Some(state)), "{state}");
        }
        assert!(is_settled(None));
        for state in ["queued", "preparing", "transcribing", "summarizing"] {
            assert!(!is_settled(Some(state)), "{state}");
        }
    }
}
