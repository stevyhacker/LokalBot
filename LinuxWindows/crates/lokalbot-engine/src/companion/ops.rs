//! Applies `action.setStatus` ops from paired devices
//! (`CompanionOpApplier.swift`) through the same library path as the action
//! rows, so the outcome state and every derived surface update exactly as for
//! a click here.

use lokalbot_core::Library;
use lokalbot_core::model::{ActionReference, ActionStatus};
use lokalbot_sync::OpOutcome;
use uuid::Uuid;

use super::records::{SET_STATUS, SetStatusOp};

/// The op's meeting when it parsed, for the republish that follows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outcome {
    pub result: OpOutcome,
    pub meeting_id: Option<Uuid>,
}

impl Outcome {
    fn rejected(message: impl Into<String>) -> Self {
        Self {
            result: outcome("rejected", Some(message.into())),
            meeting_id: None,
        }
    }

    fn for_meeting(status: &str, message: Option<&str>, meeting_id: Uuid) -> Self {
        Self {
            result: outcome(status, message.map(str::to_string)),
            meeting_id: Some(meeting_id),
        }
    }
}

fn outcome(status: &str, message: Option<String>) -> OpOutcome {
    OpOutcome {
        status: status.to_string(),
        message,
    }
}

/// Finds the action a phone's op names. Action ids are content hashes, so
/// reprocessing a meeting can change them while the phone still holds the old
/// one; the op's text snapshot then finds the action when exactly one matches.
/// Anything else is reported back as unmatched, never guessed.
pub fn match_action(
    action_id: &str,
    action_text: Option<&str>,
    references: &[ActionReference],
) -> Option<String> {
    if references.iter().any(|r| r.action.id == action_id) {
        return Some(action_id.to_string());
    }
    let wanted = lokalbot_core::actions::normalized_words(action_text.unwrap_or(""));
    if wanted.is_empty() {
        return None;
    }
    let mut ids: Vec<&str> = references
        .iter()
        .filter(|reference| {
            [
                reference.text.as_str(),
                reference.action.text.as_str(),
                reference.action.display_text().as_str(),
            ]
            .iter()
            .any(|text| lokalbot_core::actions::normalized_words(text) == wanted)
        })
        .map(|reference| reference.action.id.as_str())
        .collect();
    ids.sort_unstable();
    ids.dedup();
    match ids.as_slice() {
        [only] => Some((*only).to_string()),
        _ => None,
    }
}

fn parse_status(raw: &str) -> Option<ActionStatus> {
    match raw {
        "open" => Some(ActionStatus::Open),
        "done" => Some(ActionStatus::Done),
        "deferred" => Some(ActionStatus::Deferred),
        _ => None,
    }
}

pub fn apply(library: &Library, json: &str) -> Outcome {
    let Ok(op) = serde_json::from_str::<SetStatusOp>(json) else {
        return Outcome::rejected("The change could not be read.");
    };
    if op.kind != SET_STATUS {
        return Outcome::rejected(format!(
            "This computer does not support “{}” changes.",
            op.kind
        ));
    }
    let Some(status) = parse_status(&op.status) else {
        return Outcome::rejected(format!("“{}” is not an action status.", op.status));
    };
    let Ok(meeting_id) = Uuid::parse_str(&op.meeting_id) else {
        return Outcome::rejected("The change names no meeting.");
    };
    let meeting = library
        .meeting(meeting_id)
        .ok()
        .flatten()
        .filter(|meeting| meeting.is_own_work());
    let Some(meeting) = meeting else {
        return Outcome::for_meeting(
            "unmatched",
            Some("This meeting is no longer on your computer."),
            meeting_id,
        );
    };
    let Some(projection) = library.outcome_projection(&meeting).ok().flatten() else {
        return Outcome::for_meeting(
            "unmatched",
            Some("This meeting has no action items on your computer."),
            meeting_id,
        );
    };
    let references = projection.action_references();
    let Some(action_id) = match_action(&op.action_id, op.action_text.as_deref(), &references)
    else {
        return Outcome::for_meeting(
            "unmatched",
            Some("This action changed on your computer. Open the meeting to update it."),
            meeting_id,
        );
    };
    if references
        .iter()
        .find(|reference| reference.action.id == action_id)
        .is_some_and(|reference| reference.status == status)
    {
        return Outcome::for_meeting("applied", None, meeting_id);
    }
    match library.set_action_status(&meeting, &action_id, status) {
        Ok(()) => Outcome::for_meeting("applied", None, meeting_id),
        Err(err) => {
            log::warn!("companion op could not be saved: {err:#}");
            Outcome::for_meeting(
                "rejected",
                Some("Your computer could not save the change."),
                meeting_id,
            )
        }
    }
}
