//! What a meeting's page says about its notes and its capture: carrying the
//! user's edits to regenerated actions (`MeetingOutcomeStore.reconcileState`),
//! the retry a failed job really needs (`ProcessingPipeline.retryWork`), and
//! the capture health sidecar (`RecordingHealthReport`).

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::Path;

use anyhow::Result;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;

use crate::actions::OutcomeProjection;
use crate::jobs::PipelineJob;
use crate::library::{Library, REFRESH_MARKER, read_json};
use crate::model::{ActionItem, Meeting, MeetingOutcomes, OutcomeState};
use crate::time::swift_date;

/// `outcomes.previous.json`: the notes a transcript change moved aside.
pub const PREVIOUS_OUTCOMES_FILE: &str = "outcomes.previous.json";

fn normalized(text: &str) -> String {
    let folded: String = text
        .nfd()
        .filter(|c| !is_combining_mark(*c))
        .collect::<String>()
        .to_lowercase();
    folded
        .split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn tokens(text: &str) -> BTreeSet<String> {
    normalized(text)
        .split(' ')
        .filter(|word| !word.is_empty())
        .map(str::to_string)
        .collect()
}

fn match_score(lhs: &ActionItem, rhs: &ActionItem) -> f64 {
    let left: HashSet<&str> = lhs
        .citations
        .iter()
        .map(|c| c.segment_id.as_str())
        .collect();
    let shares_evidence = rhs
        .citations
        .iter()
        .any(|c| left.contains(c.segment_id.as_str()));
    let (left_tokens, right_tokens) = (tokens(&lhs.text), tokens(&rhs.text));
    let union = left_tokens.union(&right_tokens).count();
    let text_score = if union == 0 {
        0.0
    } else {
        left_tokens.intersection(&right_tokens).count() as f64 / union as f64
    };
    if lhs.id == rhs.id {
        return 1.0;
    }
    if shares_evidence && normalized(&lhs.text) == normalized(&rhs.text) {
        return 1.0;
    }
    if shares_evidence && text_score >= 0.6 {
        text_score.max(0.85)
    } else {
        0.0
    }
}

/// Carries user-owned state across a safe re-extraction. A transfer requires
/// an unambiguous match in both directions and compatible source evidence;
/// unmatched edits stay available for review.
pub fn reconcile_state(
    state: &OutcomeState,
    previous: &MeetingOutcomes,
    next: &MeetingOutcomes,
) -> OutcomeState {
    let old_actions: Vec<&ActionItem> = previous
        .action_items
        .iter()
        .filter(|action| state.actions.contains_key(&action.id))
        .collect();
    let matches: HashMap<&str, Vec<&ActionItem>> = next
        .action_items
        .iter()
        .map(|action| {
            (
                action.id.as_str(),
                old_actions
                    .iter()
                    .copied()
                    .filter(|old| match_score(old, action) >= 0.8)
                    .collect(),
            )
        })
        .collect();
    let mut reconciled = OutcomeState {
        schema_version: state.schema_version.max(2),
        ..Default::default()
    };
    let mut consumed: HashSet<&str> = HashSet::new();
    for action in &next.action_items {
        let [old] = matches[action.id.as_str()].as_slice() else {
            continue;
        };
        let claimed_once = matches
            .values()
            .filter(|candidates| candidates.iter().any(|c| c.id == old.id))
            .count()
            == 1;
        let (true, Some(saved)) = (claimed_once, state.actions.get(&old.id)) else {
            continue;
        };
        reconciled.actions.insert(action.id.clone(), saved.clone());
        consumed.insert(old.id.as_str());
    }
    let mut unmatched = state.unmatched_actions.clone().unwrap_or_default();
    let mut texts = state.unmatched_action_text.clone().unwrap_or_default();
    for (id, saved) in &state.actions {
        if consumed.contains(id.as_str()) {
            continue;
        }
        unmatched.insert(id.clone(), saved.clone());
        match previous.action_items.iter().find(|a| a.id == *id) {
            Some(action) => {
                texts.insert(id.clone(), action.text.clone());
            }
            None => {
                texts.remove(id);
            }
        }
    }
    reconciled.unmatched_actions = (!unmatched.is_empty()).then_some(unmatched);
    reconciled.unmatched_action_text = (!texts.is_empty()).then_some(texts);
    reconciled
}

/// What a retry should run. With no saved request a finished transcript is
/// never overwritten; the Process menu stays there for a deliberate redo.
pub fn retry_work(
    has_transcript: bool,
    auto_summarize: bool,
    job: Option<&PipelineJob>,
) -> (bool, bool) {
    match job {
        None => (!has_transcript, auto_summarize),
        Some(job) => (
            job.transcribe && !job.transcription_completed,
            job.summarize && (!job.summary_follows_setting || auto_summarize),
        ),
    }
}

impl Library {
    /// The transcript or speakers changed since the notes were written.
    pub fn notes_marked_stale(&self, meeting: &Meeting) -> bool {
        self.meeting_dir(meeting).join(REFRESH_MARKER).is_file()
    }

    pub fn previous_outcomes(&self, meeting: &Meeting) -> Result<Option<MeetingOutcomes>> {
        read_json(&self.meeting_dir(meeting).join(PREVIOUS_OUTCOMES_FILE))
    }

    /// The actions a refresh moved aside, shown for review until new notes
    /// exist (`MeetingOutcomeProjection.load(includingPrevious:)`).
    pub fn previous_outcome_projection(
        &self,
        meeting: &Meeting,
    ) -> Result<Option<OutcomeProjection>> {
        let Some(outcomes) = self.previous_outcomes(meeting)? else {
            return Ok(None);
        };
        Ok(Some(OutcomeProjection {
            meeting: meeting.clone(),
            outcomes,
            state: self.outcome_state(meeting).unwrap_or_default(),
        }))
    }

    /// `ProcessingPipeline.retryWork` for one meeting.
    pub fn retry_work(&self, meeting: &Meeting, auto_summarize: bool) -> Result<(bool, bool)> {
        let has_transcript = self
            .meeting_dir(meeting)
            .join(crate::library::TRANSCRIPT_FILE)
            .is_file();
        let job = self.job(meeting.id)?;
        Ok(retry_work(has_transcript, auto_summarize, job.as_ref()))
    }
}

/// `recording-health.json`, written while recording and read for the warning
/// on the meeting's page. Keys the Mac's decoder requires are always written.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingHealthReport {
    pub version: u32,
    #[serde(
        default,
        with = "swift_date::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_verified_call_at: Option<DateTime<Utc>>,
    #[serde(
        default,
        with = "swift_date::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub completed_at: Option<DateTime<Utc>>,
    pub events: Vec<HealthEvent>,
    pub microphone_dropped_buffers: u64,
    pub system_dropped_buffers: u64,
    pub attachment_attempts: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub had_missing_audio: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub had_write_failure: Option<bool>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HealthEvent {
    pub seconds: f64,
    pub messages: Vec<String>,
}

impl Default for RecordingHealthReport {
    fn default() -> Self {
        Self {
            version: 1,
            last_verified_call_at: None,
            completed_at: None,
            events: Vec::new(),
            microphone_dropped_buffers: 0,
            system_dropped_buffers: 0,
            attachment_attempts: 0,
            had_missing_audio: None,
            had_write_failure: None,
        }
    }
}

impl RecordingHealthReport {
    pub const FILE_NAME: &str = "recording-health.json";
    /// Fewer than this are isolated callbacks no listener would notice.
    pub const NOTICEABLE_DROPPED_BUFFERS: u64 = 5;

    pub fn drops_are_noticeable(microphone: u64, system: u64) -> bool {
        microphone >= Self::NOTICEABLE_DROPPED_BUFFERS || system >= Self::NOTICEABLE_DROPPED_BUFFERS
    }

    pub fn has_capture_issues(&self) -> bool {
        self.had_missing_audio == Some(true)
            || self.had_write_failure == Some(true)
            || Self::drops_are_noticeable(
                self.microphone_dropped_buffers,
                self.system_dropped_buffers,
            )
    }

    pub fn load(folder: &Path) -> Option<Self> {
        read_json(&folder.join(Self::FILE_NAME)).ok().flatten()
    }

    /// Records a change of warnings, keeping the history bounded but its first
    /// failure. Returns whether anything changed.
    pub fn observe(&mut self, messages: &[String], seconds: f64) -> bool {
        if self.events.last().is_some_and(|e| e.messages == messages) {
            return false;
        }
        if self.events.len() >= 1_000 {
            self.events.remove(1);
        }
        self.events.push(HealthEvent {
            seconds: seconds.max(0.0),
            messages: messages.to_vec(),
        });
        true
    }
}

pub const DROPPED_BUFFERS_WARNING: &str =
    "Audio buffers were dropped while saving. Some audio may be missing.";
pub const DISK_LOW_WARNING: &str =
    "Disk space is low. Free space now to keep saving this recording.";
pub const HEALTH_NOT_SAVED_WARNING: &str = "Recording health could not be saved. Check disk space.";
/// Audio that stops arriving must persist this long before it notifies.
pub const SUSTAINED_AUDIO_WARNING_SECONDS: f64 = 15.0;
/// Recording onto a nearly full volume risks truncated tracks.
pub const RECORDING_FLOOR_BYTES: u64 = 1_000_000_000;
/// A session this much longer than its audio is worth saying so, as long as
/// the audio is also well under its length (`stop`).
const MISSING_AUDIO_SECONDS: f64 = 60.0;
const CAPTURED_SHARE_WARNING: f64 = 0.8;

/// Why a recording can't start on this volume, when the system can say
/// (`DiskSpacePrecheck.recordingAdvisory`). A recording that dies mid-meeting
/// loses the meeting; a clear refusal doesn't.
pub fn recording_advisory(available_bytes: Option<u64>) -> Option<String> {
    let available = available_bytes.filter(|free| *free < RECORDING_FLOOR_BYTES)?;
    Some(lokalbot_i18n::format(
        "Recording needs at least {floor} of free disk space, but only {free} is available. Free up space and try again.",
        &[
            ("floor", byte_count(RECORDING_FLOOR_BYTES)),
            ("free", byte_count(available)),
        ],
    ))
}

/// A file size as the Mac's `ByteCountFormatter` writes it: decimal units,
/// whole KB and MB, up to two decimals from GB on.
fn byte_count(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["KB", "MB", "GB", "TB"];
    if bytes < 1_000 {
        return format!("{bytes} bytes");
    }
    let mut value = bytes as f64 / 1_000.0;
    let mut unit = 0;
    while value >= 1_000.0 && unit + 1 < UNITS.len() {
        value /= 1_000.0;
        unit += 1;
    }
    if unit < 2 {
        return format!("{} {}", value.round() as u64, UNITS[unit]);
    }
    let text = format!("{value:.2}");
    let text = text.trim_end_matches('0').trim_end_matches('.');
    format!("{text} {}", UNITS[unit])
}

/// The warning for a session with much less audio than time, such as a device
/// that dropped out and never came back.
pub fn short_capture_warning(recorded_seconds: f64, session_seconds: f64) -> Option<String> {
    if session_seconds - recorded_seconds <= MISSING_AUDIO_SECONDS
        || recorded_seconds >= session_seconds * CAPTURED_SHARE_WARNING
    {
        return None;
    }
    let minutes = recorded_seconds.max(0.0) as u64 / 60;
    let captured = if minutes >= 60 {
        lokalbot_i18n::format(
            "{0} hr {1} min",
            &[
                ("0", (minutes / 60).to_string()),
                ("1", (minutes % 60).to_string()),
            ],
        )
    } else {
        lokalbot_i18n::format("{minutes} min", &[("minutes", minutes.to_string())])
    };
    let session = lokalbot_i18n::format(
        "{minutes} min",
        &[("minutes", (session_seconds as u64 / 60).max(1).to_string())],
    );
    Some(lokalbot_i18n::format(
        "Recording saved, but only {captured} of audio was captured from a {session} session.",
        &[("captured", captured), ("session", session)],
    ))
}

/// When a live capture warning also becomes a notification. The meeting view
/// shows every warning as it happens; a notification interrupts the call, so
/// it is kept for conditions that lasted long enough to matter.
#[derive(Clone, Debug, Default)]
pub struct CaptureWarningNotifications {
    first_seen: BTreeMap<String, f64>,
    notified: BTreeSet<String>,
}

impl CaptureWarningNotifications {
    /// Seconds a warning must persist before it notifies; `None` never does.
    fn delay(message: &str) -> Option<f64> {
        if message == DROPPED_BUFFERS_WARNING {
            return None;
        }
        if message.starts_with("Disk space is low")
            || message.contains("saving needs attention")
            || message.starts_with("Recording health could not be saved")
        {
            return Some(0.0);
        }
        Some(SUSTAINED_AUDIO_WARNING_SECONDS)
    }

    /// Warnings due for a notification now, each at most once per recording.
    pub fn due(&mut self, messages: &[String], elapsed: f64) -> Vec<String> {
        self.first_seen.retain(|key, _| messages.contains(key));
        let mut due = Vec::new();
        for message in messages {
            let since = *self.first_seen.entry(message.clone()).or_insert(elapsed);
            if let Some(delay) = Self::delay(message)
                && elapsed - since >= delay
                && self.notified.insert(message.clone())
            {
                due.push(message.clone());
            }
        }
        due
    }
}

/// What the app can observe about the tracks for [`capture_warnings`].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CaptureObservation {
    /// Recording what the computer plays was asked for.
    pub system_requested: bool,
    /// System capture attached.
    pub has_system_target: bool,
    /// Seconds since microphone audio reached the writer.
    pub microphone_age: Option<f64>,
    /// Seconds since system audio reached the writer; `None` before the first.
    pub system_age: Option<f64>,
    /// A quiet loopback delivers nothing while nothing plays, and that is fine.
    pub system_quiet_is_normal: bool,
    pub elapsed: f64,
}

/// `RecordingController.captureWarnings`.
pub fn capture_warnings(seen: &CaptureObservation) -> Vec<String> {
    let mut warnings = Vec::new();
    if seen.system_requested && !seen.has_system_target {
        warnings.push("Couldn't capture this computer's audio; microphone only.".to_string());
    }
    if seen.system_requested
        && seen.has_system_target
        && seen.system_age.is_none()
        && !seen.system_quiet_is_normal
    {
        warnings.push(
            "Waiting for meeting audio to reach disk; microphone recording continues.".to_string(),
        );
    }
    if seen.elapsed < 5.0 {
        return warnings;
    }
    if seen.microphone_age.is_none_or(|age| age >= 5.0) {
        warnings.push("Microphone audio is not arriving. Trying to recover it.".to_string());
    }
    if seen.system_requested
        && seen.has_system_target
        && !seen.system_quiet_is_normal
        && seen.system_age.is_none_or(|age| age >= 5.0)
    {
        warnings.push("Meeting audio is not arriving; the microphone continues.".to_string());
    }
    warnings
}

/// Actions in a meeting's outcome state whose edits didn't carry over.
pub fn unmatched_edits(state: &OutcomeState) -> Vec<(String, String)> {
    let Some(unmatched) = &state.unmatched_actions else {
        return Vec::new();
    };
    unmatched
        .iter()
        .map(|(id, saved)| {
            let text = saved
                .text_correction
                .clone()
                .or_else(|| {
                    state
                        .unmatched_action_text
                        .as_ref()
                        .and_then(|texts| texts.get(id).cloned())
                })
                .unwrap_or_else(|| "Previous action".to_string());
            let detail = std::iter::once(saved.status.label().to_string())
                .chain(saved.owner_override.clone())
                .chain(saved.due_override.clone())
                .collect::<Vec<_>>()
                .join(" · ");
            (text, detail)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{ActionState, ActionStatus};

    fn action(id: &str, text: &str, segment: &str) -> ActionItem {
        serde_json::from_value(serde_json::json!({
            "id": id,
            "text": text,
            "importance": 3,
            "citations": [{"segmentID": segment, "start": 1.0, "end": 2.0, "speaker": "them 1", "excerpt": "x"}],
        }))
        .unwrap()
    }

    fn outcomes(actions: Vec<ActionItem>) -> MeetingOutcomes {
        serde_json::from_value(serde_json::json!({
            "schemaVersion": 2,
            "actionItems": actions,
            "decisionRecords": [],
            "openQuestions": [],
        }))
        .unwrap()
    }

    fn done() -> ActionState {
        ActionState {
            status: ActionStatus::Done,
            ..serde_json::from_value(serde_json::json!({"status": "done"})).unwrap()
        }
    }

    #[test]
    fn edits_follow_an_unambiguous_action_and_the_rest_stay_reviewable() {
        let previous = outcomes(vec![
            action("a", "Send the security overview", "s1"),
            action("b", "Book the venue", "s2"),
        ]);
        let next = outcomes(vec![action("c", "Send the security overview!", "s1")]);
        let mut state = OutcomeState::default();
        state.actions.insert("a".into(), done());
        state.actions.insert("b".into(), done());
        let reconciled = reconcile_state(&state, &previous, &next);
        assert_eq!(reconciled.actions["c"].status, ActionStatus::Done);
        assert!(!reconciled.actions.contains_key("a"));
        let unmatched = reconciled.unmatched_actions.as_ref().unwrap();
        assert!(unmatched.contains_key("b") && !unmatched.contains_key("a"));
        assert_eq!(
            reconciled.unmatched_action_text.as_ref().unwrap()["b"],
            "Book the venue"
        );
        assert_eq!(unmatched_edits(&reconciled)[0].0, "Book the venue");
    }

    #[test]
    fn two_new_actions_claiming_one_edit_get_neither() {
        let previous = outcomes(vec![action("a", "Send the overview", "s1")]);
        let next = outcomes(vec![
            action("b", "Send the overview", "s1"),
            action("c", "send the overview.", "s1"),
        ]);
        let mut state = OutcomeState::default();
        state.actions.insert("a".into(), done());
        let reconciled = reconcile_state(&state, &previous, &next);
        assert!(reconciled.actions.is_empty());
        assert!(reconciled.unmatched_actions.unwrap().contains_key("a"));
    }

    #[test]
    fn text_alone_never_carries_an_edit() {
        let previous = outcomes(vec![action("a", "Send the overview", "s1")]);
        let next = outcomes(vec![action("b", "Send the overview", "s9")]);
        let mut state = OutcomeState::default();
        state.actions.insert("a".into(), done());
        assert!(reconcile_state(&state, &previous, &next).actions.is_empty());
    }

    fn job(transcribe: bool, completed: bool, summarize: bool, follows: bool) -> PipelineJob {
        PipelineJob {
            meeting_id: uuid::Uuid::nil(),
            transcribe,
            transcription_completed: completed,
            summarize,
            summary_follows_setting: follows,
            attempts: 3,
            last_error: Some("failed".into()),
        }
    }

    #[test]
    fn a_retry_repeats_only_what_failed() {
        // No saved job: a finished transcript is kept.
        assert_eq!(retry_work(true, true, None), (false, true));
        assert_eq!(retry_work(false, false, None), (true, false));
        // A finished transcription isn't redone for a failed summary.
        let notes_failed = job(true, true, true, false);
        assert_eq!(retry_work(true, false, Some(&notes_failed)), (false, true));
        // An automatic summary follows the current setting.
        let automatic = job(true, false, true, true);
        assert_eq!(retry_work(false, false, Some(&automatic)), (true, false));
        assert_eq!(retry_work(false, true, Some(&automatic)), (true, true));
    }

    #[test]
    fn reads_and_writes_the_macs_health_report() {
        let report: RecordingHealthReport = serde_json::from_str(
            r#"{"version":1,"lastVerifiedCallAt":800000000.5,"events":[{"seconds":5,"messages":["Microphone audio is not arriving. Trying to recover it."]}],
            "microphoneDroppedBuffers":2,"systemDroppedBuffers":0,"attachmentAttempts":1,"hadMissingAudio":true}"#,
        )
        .unwrap();
        assert!(report.has_capture_issues());
        assert!(report.last_verified_call_at.is_some());
        // Non-optional Swift fields are required when the Mac decodes.
        let json = serde_json::to_value(RecordingHealthReport::default()).unwrap();
        for key in [
            "version",
            "events",
            "microphoneDroppedBuffers",
            "systemDroppedBuffers",
            "attachmentAttempts",
        ] {
            assert!(json.get(key).is_some(), "{key}");
        }
        assert!(!RecordingHealthReport::default().has_capture_issues());
    }

    #[test]
    fn isolated_drops_are_not_a_capture_issue() {
        let mut report = RecordingHealthReport {
            microphone_dropped_buffers: 4,
            ..Default::default()
        };
        assert!(!report.has_capture_issues());
        report.microphone_dropped_buffers = 5;
        assert!(report.has_capture_issues());
    }

    #[test]
    fn health_history_is_bounded_and_keeps_the_first_failure() {
        let mut report = RecordingHealthReport::default();
        assert!(report.observe(&["first".to_string()], 1.0));
        assert!(!report.observe(&["first".to_string()], 2.0), "unchanged");
        for i in 0..1_500 {
            report.observe(&[format!("w{i}")], i as f64);
        }
        assert_eq!(report.events.len(), 1_000);
        assert_eq!(report.events[0].messages[0], "first");
    }

    #[test]
    fn a_notification_waits_for_the_warning_to_last() {
        let mut notifications = CaptureWarningNotifications::default();
        let audio = vec!["Microphone audio is not arriving. Trying to recover it.".to_string()];
        assert!(notifications.due(&audio, 10.0).is_empty());
        assert!(notifications.due(&audio, 20.0).is_empty());
        assert_eq!(notifications.due(&audio, 25.0), audio);
        assert!(notifications.due(&audio, 40.0).is_empty(), "only once");
        // A hiccup that ended never notifies.
        let mut hiccup = CaptureWarningNotifications::default();
        assert!(hiccup.due(&audio, 10.0).is_empty());
        assert!(hiccup.due(&[], 12.0).is_empty());
        assert!(hiccup.due(&audio, 30.0).is_empty());
        // Saving problems notify at once; dropped buffers never do.
        let disk = vec![DISK_LOW_WARNING.to_string()];
        assert_eq!(notifications.due(&disk, 50.0), disk);
        let drops = vec![DROPPED_BUFFERS_WARNING.to_string()];
        assert!(notifications.due(&drops, 60.0).is_empty());
        assert!(notifications.due(&drops, 600.0).is_empty());
    }

    #[test]
    fn capture_warnings_follow_what_arrives() {
        let healthy = CaptureObservation {
            system_requested: true,
            has_system_target: true,
            microphone_age: Some(0.2),
            system_age: Some(0.2),
            elapsed: 60.0,
            ..Default::default()
        };
        assert!(capture_warnings(&healthy).is_empty());
        let stalled = CaptureObservation {
            microphone_age: Some(8.0),
            system_age: Some(8.0),
            ..healthy.clone()
        };
        assert_eq!(capture_warnings(&stalled).len(), 2);
        // A quiet Windows loopback delivers nothing while nothing plays.
        let quiet = CaptureObservation {
            system_age: None,
            system_quiet_is_normal: true,
            ..healthy.clone()
        };
        assert!(capture_warnings(&quiet).is_empty());
        let early = CaptureObservation {
            microphone_age: None,
            elapsed: 2.0,
            ..healthy.clone()
        };
        assert!(capture_warnings(&early).is_empty());
        let unattached = CaptureObservation {
            has_system_target: false,
            ..healthy
        };
        assert_eq!(capture_warnings(&unattached).len(), 1);
    }
}
