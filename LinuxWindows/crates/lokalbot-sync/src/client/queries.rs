//! Read queries over the phone's copy (ffi.md, reads). Bodies come back as
//! the JSON records.md describes, with local action states applied.

use std::cmp::Reverse;
use std::collections::HashMap;

use serde_json::{Value, json};

use super::store::{ActionState, ClientStore};
use crate::error::Result;
use crate::records::{
    DAY, MANIFEST, MANIFEST_KEY, MEETING, PERSON, PROJECT, TRANSCRIPT, str_field,
};

/// Which action items `actions` returns.
#[derive(Clone, Debug, Default, PartialEq, Eq, uniffi::Record)]
pub struct ActionFilter {
    /// Only actions the person using LokalBot owns.
    #[uniffi(default = false)]
    pub mine_only: bool,
    /// `open`, `done` or `deferred`; all when absent.
    #[uniffi(default = None)]
    pub status: Option<String>,
    #[uniffi(default = false)]
    pub owner_unclear_only: bool,
    /// Only actions due before this day (`YYYY-MM-DD`, exclusive).
    #[uniffi(default = None)]
    pub due_before: Option<String>,
}

/// `0` means no limit.
fn take<T>(items: Vec<T>, limit: u32) -> Vec<T> {
    if limit == 0 {
        items
    } else {
        items.into_iter().take(limit as usize).collect()
    }
}

fn is_merged(meeting: &Value) -> bool {
    meeting.get("mergedInto").is_some_and(|v| !v.is_null())
}

/// Applies pending statuses (`"pending": true`) and op notes (`"syncNote"`)
/// to a meeting body's actions.
fn apply_states(
    meeting_id: &str,
    body: &mut Value,
    states: &HashMap<(String, String), ActionState>,
) {
    let Some(actions) = body.get_mut("actions").and_then(Value::as_array_mut) else {
        return;
    };
    for action in actions {
        let Some(action_id) = str_field(action, "id").map(str::to_owned) else {
            continue;
        };
        let Some(state) = states.get(&(meeting_id.to_owned(), action_id)) else {
            continue;
        };
        if let Some(status) = &state.pending_status {
            action["status"] = Value::String(status.clone());
            action["pending"] = Value::Bool(true);
        }
        if let Some(note) = &state.note {
            action["syncNote"] = note.clone();
        }
    }
}

impl ClientStore {
    pub fn manifest(&self) -> Result<Option<String>> {
        Ok(self
            .body(MANIFEST, MANIFEST_KEY)?
            .map(|body| body.to_string()))
    }

    /// Meetings newest first, merged ones hidden, optionally within days
    /// `from_day..=to_day`.
    pub fn meetings(
        &self,
        from_day: Option<&str>,
        to_day: Option<&str>,
        limit: u32,
    ) -> Result<Vec<String>> {
        let states = self.action_states()?;
        let meetings = self
            .bodies(MEETING, "json_extract(body, '$.startedAt') DESC, key")?
            .into_iter()
            .filter(|(_, body)| !is_merged(body))
            .filter(|(_, body)| {
                let day = str_field(body, "day").unwrap_or_default();
                from_day.is_none_or(|from| day >= from) && to_day.is_none_or(|to| day <= to)
            })
            .map(|(key, mut body)| {
                apply_states(&key, &mut body, &states);
                body.to_string()
            })
            .collect();
        Ok(take(meetings, limit))
    }

    pub fn meeting(&self, id: &str) -> Result<Option<String>> {
        let Some(mut body) = self.body(MEETING, id)? else {
            return Ok(None);
        };
        apply_states(id, &mut body, &self.action_states()?);
        Ok(Some(body.to_string()))
    }

    pub fn transcript(&self, meeting_id: &str) -> Result<Option<String>> {
        Ok(self
            .body(TRANSCRIPT, meeting_id)?
            .map(|body| body.to_string()))
    }

    /// Day keys that have a record, newest first.
    pub fn days(&self, limit: u32) -> Result<Vec<String>> {
        let days = self
            .bodies(DAY, "key DESC")?
            .into_iter()
            .map(|(key, _)| key)
            .collect();
        Ok(take(days, limit))
    }

    pub fn day(&self, date: &str) -> Result<Option<String>> {
        Ok(self.body(DAY, date)?.map(|body| body.to_string()))
    }

    /// ActionRow JSON: overdue first, then by due date (none last), then by
    /// meeting start, newest first. `today` is `YYYY-MM-DD`.
    pub fn actions(&self, filter: &ActionFilter, today: &str) -> Result<Vec<String>> {
        let states = self.action_states()?;
        let mut rows: Vec<(bool, Option<String>, String, Value)> = Vec::new();
        for (meeting_id, mut meeting) in self.bodies(MEETING, "key")? {
            if is_merged(&meeting) {
                continue;
            }
            apply_states(&meeting_id, &mut meeting, &states);
            let title = str_field(&meeting, "title").unwrap_or_default().to_owned();
            let started_at = str_field(&meeting, "startedAt")
                .unwrap_or_default()
                .to_owned();
            for action in meeting
                .get("actions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                let status = str_field(action, "status").unwrap_or("open");
                let due = str_field(action, "dueDate");
                let flag = |name: &str| action.get(name).and_then(Value::as_bool).unwrap_or(false);
                if (filter.mine_only && !flag("ownerIsUser"))
                    || (filter.owner_unclear_only && !flag("ownerUnclear"))
                    || filter
                        .status
                        .as_deref()
                        .is_some_and(|wanted| wanted != status)
                    || filter
                        .due_before
                        .as_deref()
                        .is_some_and(|before| due.is_none_or(|due| due >= before))
                {
                    continue;
                }
                let overdue = status == "open" && due.is_some_and(|due| due < today);
                let mut action = action.clone();
                let pending = action
                    .as_object_mut()
                    .and_then(|object| object.remove("pending"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let note = action
                    .as_object_mut()
                    .and_then(|object| object.remove("syncNote"));
                let mut row = json!({
                    "meetingId": meeting_id,
                    "meetingTitle": title,
                    "meetingStartedAt": started_at,
                    "action": action,
                    "pending": pending,
                });
                if let Some(note) = note {
                    row["syncNote"] = note;
                }
                rows.push((overdue, due.map(str::to_owned), started_at.clone(), row));
            }
        }
        rows.sort_by(|a, b| {
            (!a.0, a.1.is_none(), &a.1, Reverse(&a.2)).cmp(&(
                !b.0,
                b.1.is_none(),
                &b.1,
                Reverse(&b.2),
            ))
        });
        Ok(rows.into_iter().map(|(.., row)| row.to_string()).collect())
    }

    /// People, most recently met first.
    pub fn people(&self) -> Result<Vec<String>> {
        let mut people: Vec<Value> = self
            .bodies(PERSON, "key")?
            .into_iter()
            .map(|(_, body)| body)
            .collect();
        people.sort_by(|a, b| {
            let key = |p: &Value| {
                (
                    Reverse(str_field(p, "lastMetAt").unwrap_or_default().to_owned()),
                    str_field(p, "displayName")
                        .unwrap_or_default()
                        .to_lowercase(),
                )
            };
            key(a).cmp(&key(b))
        });
        Ok(people.into_iter().map(|p| p.to_string()).collect())
    }

    pub fn person(&self, id: &str) -> Result<Option<String>> {
        Ok(self.body(PERSON, id)?.map(|body| body.to_string()))
    }

    /// Projects, the one with the most recent meeting first.
    pub fn projects(&self) -> Result<Vec<String>> {
        let started: HashMap<String, String> = self
            .bodies(MEETING, "key")?
            .into_iter()
            .filter_map(|(key, body)| Some((key, str_field(&body, "startedAt")?.to_owned())))
            .collect();
        let latest = |project: &Value| -> String {
            project
                .get("meetingIds")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|id| started.get(id.as_str()?))
                .max()
                .cloned()
                .unwrap_or_default()
        };
        let mut projects: Vec<(String, String, Value)> = self
            .bodies(PROJECT, "key")?
            .into_iter()
            .map(|(_, body)| {
                (
                    latest(&body),
                    str_field(&body, "name").unwrap_or_default().to_lowercase(),
                    body,
                )
            })
            .collect();
        projects.sort_by(|a, b| (Reverse(&a.0), &a.1).cmp(&(Reverse(&b.0), &b.1)));
        Ok(projects
            .into_iter()
            .map(|(.., body)| body.to_string())
            .collect())
    }

    pub fn project(&self, id: &str) -> Result<Option<String>> {
        Ok(self.body(PROJECT, id)?.map(|body| body.to_string()))
    }
}
