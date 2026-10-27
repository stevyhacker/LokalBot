//! Action items and people for the CLI and MCP (`ActionItemsReport.swift`,
//! `PeopleReport.swift`). Owners and names only; email addresses never
//! appear.

use std::collections::HashSet;

use chrono::{DateTime, Utc};
use lokalbot_core::actions::{attention_sorted, cluster_threads};
use lokalbot_core::people::normalized;
use lokalbot_core::{ActionStatus, ActionThread, Meeting, PersonProfile};
use serde::Serialize;
use uuid::Uuid;

use crate::json;
use crate::session::{Session, iso8601, render_table, short_uuid};

pub const DEFAULT_DAYS: u32 = 30;
pub const MAXIMUM_DAYS: u32 = 365;
pub const MAXIMUM_ENTRIES: usize = 200;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusFilter {
    All,
    Active,
    Open,
    Deferred,
    Done,
}

impl StatusFilter {
    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw.to_lowercase().as_str() {
            "all" => Self::All,
            "active" => Self::Active,
            "open" => Self::Open,
            "deferred" => Self::Deferred,
            "done" => Self::Done,
            _ => return None,
        })
    }

    fn includes(self, thread: &ActionThread) -> bool {
        thread.references.iter().any(|r| match self {
            Self::All => true,
            Self::Active => r.status != ActionStatus::Done,
            Self::Open => r.status == ActionStatus::Open,
            Self::Deferred => r.status == ActionStatus::Deferred,
            Self::Done => r.status == ActionStatus::Done,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OwnerFilter {
    Anyone,
    Me,
    Others,
    Named(String),
}

impl OwnerFilter {
    pub fn parse(raw: Option<&str>) -> Self {
        let value = raw.map(str::trim).unwrap_or("");
        match value.to_lowercase().as_str() {
            "" | "any" | "anyone" | "all" => Self::Anyone,
            "me" | "mine" | "user" => Self::Me,
            "others" | "other" => Self::Others,
            _ => Self::Named(value.to_string()),
        }
    }

    fn includes(&self, thread: &ActionThread) -> bool {
        match self {
            Self::Anyone => true,
            Self::Me => thread.is_for_user(),
            Self::Others => !thread.is_for_user(),
            Self::Named(name) => {
                !thread.is_for_user()
                    && thread
                        .owner
                        .as_ref()
                        .is_some_and(|o| o.to_lowercase().contains(&name.to_lowercase()))
            }
        }
    }
}

pub struct ActionFilter {
    pub status: StatusFilter,
    pub days: u32,
    pub owner: OwnerFilter,
    pub meeting_id: Option<Uuid>,
    pub limit: usize,
}

impl Default for ActionFilter {
    fn default() -> Self {
        Self {
            status: StatusFilter::Active,
            days: DEFAULT_DAYS,
            owner: OwnerFilter::Anyone,
            meeting_id: None,
            limit: 50,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct MeetingRefEntry {
    pub id: String,
    pub title: String,
    pub date: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ActionEntry {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    pub for_user: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due_date: Option<String>,
    pub overdue: bool,
    pub status: String,
    pub mention_count: usize,
    pub meetings: Vec<MeetingRefEntry>,
}

pub fn action_entries(
    session: &Session,
    meetings: &[Meeting],
    filter: &ActionFilter,
    now: DateTime<Utc>,
) -> Vec<ActionEntry> {
    let cutoff = now - chrono::Duration::days(i64::from(filter.days.max(1)));
    let references = meetings
        .iter()
        .filter(|m| match filter.meeting_id {
            Some(id) => m.id == id,
            // The sample meeting's actions are made up: only listed when asked for by id.
            None => m.is_own_work() && m.started_at >= cutoff,
        })
        .flat_map(|m| session.library.meeting_actions(m).unwrap_or_default())
        .collect();
    let threads: Vec<ActionThread> = cluster_threads(references)
        .into_iter()
        .filter(|t| filter.status.includes(t) && filter.owner.includes(t))
        .collect();
    let today = lokalbot_core::time::local_day(now);
    attention_sorted(threads, today)
        .iter()
        .take(filter.limit.clamp(1, MAXIMUM_ENTRIES))
        .map(|t| action_entry(t, now))
        .collect()
}

pub fn action_entry(thread: &ActionThread, now: DateTime<Utc>) -> ActionEntry {
    let mut seen = HashSet::new();
    let meetings = thread
        .references
        .iter()
        .filter(|r| seen.insert(r.meeting_id))
        .map(|r| MeetingRefEntry {
            id: short_uuid(&r.meeting_id),
            title: r.meeting_title.clone(),
            date: iso8601(r.meeting_started_at),
        })
        .collect();
    let for_user = thread.is_for_user();
    ActionEntry {
        text: thread.text.clone(),
        owner: if for_user {
            Some("Me".into())
        } else {
            thread.owner.clone()
        },
        for_user,
        due: thread.due.clone(),
        due_date: thread
            .resolved_due_date
            .map(|d| d.format("%Y-%m-%d").to_string()),
        overdue: thread.is_overdue(lokalbot_core::time::local_day(now)),
        status: if thread.is_mixed() {
            "mixed".into()
        } else {
            thread.status().raw().into()
        },
        mention_count: thread.mention_count(),
        meetings,
    }
}

pub fn actions_json(entries: &[ActionEntry]) -> String {
    json::pretty(&entries, true)
}

pub fn actions_table(entries: &[ActionEntry]) -> String {
    if entries.is_empty() {
        return "(no action items)".into();
    }
    let rows: Vec<Vec<String>> = entries
        .iter()
        .map(|e| {
            vec![
                if e.overdue {
                    "overdue".into()
                } else {
                    e.status.clone()
                },
                e.due_date
                    .clone()
                    .or_else(|| e.due.clone())
                    .unwrap_or_default(),
                e.owner.clone().unwrap_or_else(|| "unclear".into()),
                e.text.clone(),
                e.meetings
                    .first()
                    .map(|m| format!("{} {}", m.id, m.title))
                    .unwrap_or_default(),
            ]
        })
        .collect();
    render_table(&["Status", "Due", "Owner", "Action", "Meeting"], &rows)
}

// ------------------------------------------------------------------ people

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct PersonSummary {
    pub id: String,
    pub name: String,
    pub other_names: Vec<String>,
    pub meeting_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_met: Option<String>,
    pub you_owe: usize,
    pub they_owe: usize,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DecisionEntry {
    pub text: String,
    pub meeting_id: String,
    pub meeting_title: String,
    pub date: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct PersonDetail {
    pub id: String,
    pub name: String,
    pub other_names: Vec<String>,
    pub you_owe: Vec<ActionEntry>,
    pub they_owe: Vec<ActionEntry>,
    pub decisions: Vec<DecisionEntry>,
    pub meetings: Vec<MeetingRefEntry>,
}

/// Person ID, exact name, then a unique case-insensitive substring.
pub fn find_person<'a>(needle: &str, people: &'a [PersonProfile]) -> Option<&'a PersonProfile> {
    let trimmed = needle.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(person) = people.iter().find(|p| p.id == trimmed) {
        return Some(person);
    }
    let key = normalized(trimmed);
    let names = |p: &PersonProfile| {
        std::iter::once(p.name.clone())
            .chain(p.other_names.clone())
            .collect::<Vec<_>>()
    };
    let exact: Vec<&PersonProfile> = people
        .iter()
        .filter(|p| names(p).iter().any(|n| normalized(n) == key))
        .collect();
    if exact.len() == 1 {
        return Some(exact[0]);
    }
    let lowered = trimmed.to_lowercase();
    let partial: Vec<&PersonProfile> = people
        .iter()
        .filter(|p| names(p).iter().any(|n| n.to_lowercase().contains(&lowered)))
        .collect();
    (partial.len() == 1).then(|| partial[0])
}

pub fn person_summaries(
    people: &[PersonProfile],
    query: Option<&str>,
    limit: usize,
) -> Vec<PersonSummary> {
    let needle = query.map(str::trim).unwrap_or("").to_lowercase();
    people
        .iter()
        .filter(|p| {
            needle.is_empty()
                || std::iter::once(&p.name)
                    .chain(&p.other_names)
                    .any(|n| n.to_lowercase().contains(&needle))
        })
        .take(limit.clamp(1, MAXIMUM_ENTRIES))
        .map(|p| PersonSummary {
            id: p.id.clone(),
            name: p.name.clone(),
            other_names: p.other_names.clone(),
            meeting_count: p.meeting_count(),
            last_met: p.last_met().map(iso8601),
            you_owe: p.my_actions.len(),
            they_owe: p.their_actions.len(),
        })
        .collect()
}

pub fn person_detail(person: &PersonProfile, now: DateTime<Utc>) -> PersonDetail {
    PersonDetail {
        id: person.id.clone(),
        name: person.name.clone(),
        other_names: person.other_names.clone(),
        you_owe: person
            .my_actions
            .iter()
            .map(|t| action_entry(t, now))
            .collect(),
        they_owe: person
            .their_actions
            .iter()
            .map(|t| action_entry(t, now))
            .collect(),
        decisions: person
            .decisions
            .iter()
            .map(|(meeting, decision)| DecisionEntry {
                text: decision.text.clone(),
                meeting_id: short_uuid(&meeting.id),
                meeting_title: meeting.title.clone(),
                date: iso8601(meeting.started_at),
            })
            .collect(),
        meetings: person
            .meetings
            .iter()
            .take(20)
            .map(|m| MeetingRefEntry {
                id: short_uuid(&m.id),
                title: m.title.clone(),
                date: iso8601(m.started_at),
            })
            .collect(),
    }
}

pub fn people_table(summaries: &[PersonSummary]) -> String {
    if summaries.is_empty() {
        return "(no people)".into();
    }
    let rows: Vec<Vec<String>> = summaries
        .iter()
        .map(|s| {
            vec![
                s.name.clone(),
                s.meeting_count.to_string(),
                s.last_met
                    .as_ref()
                    .map(|d| d.chars().take(10).collect())
                    .unwrap_or_default(),
                s.you_owe.to_string(),
                s.they_owe.to_string(),
            ]
        })
        .collect();
    render_table(
        &["Name", "Meetings", "Last met", "You owe", "They owe"],
        &rows,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owner_filter_parsing() {
        assert_eq!(OwnerFilter::parse(None), OwnerFilter::Anyone);
        assert_eq!(OwnerFilter::parse(Some(" Mine ")), OwnerFilter::Me);
        assert_eq!(OwnerFilter::parse(Some("other")), OwnerFilter::Others);
        assert_eq!(
            OwnerFilter::parse(Some("Ana")),
            OwnerFilter::Named("Ana".into())
        );
        assert_eq!(StatusFilter::parse("ACTIVE"), Some(StatusFilter::Active));
        assert_eq!(StatusFilter::parse("pending"), None);
    }
}
