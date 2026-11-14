//! Builders for unit tests: action references and threads with only what a
//! test sets, the rest neutral.

use chrono::{NaiveDate, TimeZone as _, Utc};
use lokalbot_core::{ActionItem, ActionReference, ActionStatus, ActionThread};
use uuid::Uuid;

/// One action from a meeting on 2026-10-`started`, the user's unless
/// `for_user` is false.
pub fn reference(
    id: &str,
    status: ActionStatus,
    for_user: bool,
    due: Option<NaiveDate>,
    started: u32,
) -> ActionReference {
    let action: ActionItem =
        serde_json::from_value(serde_json::json!({ "id": id, "text": id, "importance": 0 }))
            .unwrap();
    let at = Utc.with_ymd_and_hms(2026, 10, started, 9, 0, 0).unwrap();
    ActionReference {
        id: format!("{}:{id}", Uuid::from_u128(u128::from(started))),
        meeting_id: Uuid::from_u128(u128::from(started)),
        meeting_title: format!("Meeting {started}"),
        meeting_started_at: at,
        action_id: id.to_string(),
        text: format!("Do {id}"),
        original_text: format!("Do {id}"),
        owner: Some(if for_user { "Me" } else { "Ana" }.to_string()),
        due: due.map(|d| d.to_string()),
        resolved_due_date: due,
        is_for_user: for_user,
        status,
        importance: 0,
        citations: Vec::new(),
        action,
        state_updated_at: at,
        text_was_corrected: false,
        owner_was_corrected: false,
        due_was_corrected: false,
        text_corrected_at: None,
        owner_corrected_at: None,
        due_corrected_at: None,
        is_thread_excluded: false,
    }
}

/// A thread of `references`, newest first, due when its newest is.
pub fn thread(references: Vec<ActionReference>) -> ActionThread {
    let latest = references[0].clone();
    ActionThread {
        id: format!("thread-{}", latest.id),
        canonical_text: String::new(),
        text: latest.text.clone(),
        owner: latest.owner.clone(),
        due: latest.due.clone(),
        due_source_meeting_date: latest.due.as_ref().map(|_| latest.meeting_started_at),
        due_reference_date: latest.due.as_ref().map(|_| latest.meeting_started_at),
        resolved_due_date: latest.resolved_due_date,
        references,
    }
}
