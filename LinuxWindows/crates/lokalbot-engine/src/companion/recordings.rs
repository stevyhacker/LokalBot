//! Makes meetings of the recordings paired devices send
//! (`CompanionRecordingReceiver.swift`). A device deletes its copy once it hears
//! `accepted`, so that answer waits until the meeting is stored; `rejected` is
//! for what no retry can fix, and everything else is `deferred`.

use std::path::Path;

use chrono::{DateTime, Utc};
use lokalbot_core::Library;
use lokalbot_sync::UploadOutcome;
use serde_json::Value;
use uuid::Uuid;

use super::records;
use crate::library_ops::{self, DeviceImport, DeviceRecording, ImportFailure};

/// ADTS AAC, which a recorder that dies leaves readable.
const SUPPORTED_FORMAT: &str = "aac-adts";
const UNREADABLE_DESCRIPTION: &str = "The recording's description could not be read.";

/// What became of one recording.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Received {
    pub outcome: UploadOutcome,
    /// The meeting this call made of it. One from an earlier attempt already
    /// went through the queue, and may have notes by now.
    pub new_meeting: Option<Uuid>,
}

pub fn deferred(message: impl Into<String>) -> UploadOutcome {
    outcome("deferred", message)
}

fn outcome(status: &str, message: impl Into<String>) -> UploadOutcome {
    UploadOutcome {
        status: status.into(),
        meeting_id: None,
        message: Some(message.into()),
    }
}

/// Reads `file` and makes a meeting of it. `recording_json` is the recording as
/// `receive_recording` describes it (Companion/protocol/ffi.md); the device name
/// comes from the pairing, the rest from the device.
pub fn receive(
    library: &Library,
    recording_json: &str,
    file: &Path,
    now: DateTime<Utc>,
) -> Received {
    let refused = |message: String| Received {
        outcome: outcome("rejected", message),
        new_meeting: None,
    };
    let Ok(description) = serde_json::from_str::<Value>(recording_json) else {
        return refused(UNREADABLE_DESCRIPTION.into());
    };
    let text = |field: &str| description[field].as_str();
    let (Some(id), Some(format)) = (text("id"), text("format")) else {
        return refused(UNREADABLE_DESCRIPTION.into());
    };
    if format != SUPPORTED_FORMAT {
        return refused(format!(
            "This computer can't read “{format}” recordings. Update LokalBot on it."
        ));
    }
    let device_name = super::device_display_name(text("deviceName").unwrap_or(""));
    let recording = DeviceRecording {
        id,
        title: text("title"),
        started_at: text("startedAt"),
        device_name: &device_name,
    };
    match library_ops::import_device_recording(library, file, &recording, now) {
        Ok(DeviceImport { meeting, is_new }) => {
            if is_new {
                log::info!("device recording received meeting={}", meeting.id);
            }
            Received {
                outcome: UploadOutcome {
                    status: "accepted".into(),
                    meeting_id: Some(records::id(meeting.id)),
                    message: None,
                },
                new_meeting: is_new.then_some(meeting.id),
            }
        }
        Err(failure) => {
            // The message names the recording; keep titles out of the log.
            log::warn!("device recording import failed id={id}");
            Received {
                outcome: failure_outcome(&failure, &recording.meeting_title()),
                new_meeting: None,
            }
        }
    }
}

/// `name` says which recording, for a device holding several.
pub fn failure_outcome(failure: &ImportFailure, name: &str) -> UploadOutcome {
    match failure {
        ImportFailure::Unreadable | ImportFailure::NoAudio => outcome(
            "rejected",
            "This recording has no audio your computer can transcribe.",
        ),
        ImportFailure::InvalidId => outcome("rejected", UNREADABLE_DESCRIPTION),
        ImportFailure::Conversion(_) | ImportFailure::CannotCreateMeeting(_) => {
            deferred(failure.localized(name))
        }
    }
}
