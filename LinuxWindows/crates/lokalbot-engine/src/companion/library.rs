//! What one companion build reads from the library (`CompanionLibrary.swift`).
//! Nothing here writes: a build never repairs metadata.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use lokalbot_core::actions::OutcomeProjection;
use lokalbot_core::library::resolve_merge_relationships;
use lokalbot_core::{Library, Meeting};
use uuid::Uuid;

use super::sharing::{HistoryWindow, RecordScope};
use lokalbot_core::model::{PersonProfile, ProjectProfile, ProjectSummary};

pub struct CompanionLibrary {
    pub library: Library,
    pub scope: RecordScope,
    pub now: DateTime<Utc>,
    /// Every meeting on disk, merged sources included.
    pub all_meetings: Vec<Meeting>,
    /// The person's own finished meetings inside the history window, newest
    /// first. Merged sources, the sample meeting, and a meeting still being
    /// recorded are left out.
    pub meetings: Vec<Meeting>,
    pub projections: HashMap<Uuid, OutcomeProjection>,
    pub people: Vec<PersonProfile>,
    /// Tracked projects only: their UUIDs are the record keys.
    pub projects: Vec<ProjectProfile>,
    pub project_summaries: HashMap<Uuid, ProjectSummary>,
}

pub fn is_shared(meeting: &Meeting, history: HistoryWindow, now: DateTime<Utc>) -> bool {
    meeting.is_own_work() && meeting.ended_at.is_some() && history.contains(meeting.started_at, now)
}

/// Every meeting on disk with its merge marker resolved in memory only,
/// newest first (`SessionLookup.loadAllMeetings`).
pub fn read_all_meetings(library: &Library) -> Vec<Meeting> {
    let mut meetings = library.list_all_meetings().unwrap_or_else(|err| {
        log::warn!("companion: could not read the meetings: {err:#}");
        Vec::new()
    });
    let resolved = resolve_merge_relationships(&meetings);
    for (meeting, parent) in meetings.iter_mut().zip(resolved) {
        meeting.merged_into_meeting_id = parent;
    }
    meetings.sort_by_key(|meeting| std::cmp::Reverse(meeting.started_at));
    meetings
}

impl CompanionLibrary {
    /// `all`, when given, is used instead of reading the meetings again, and
    /// outcomes are reused from `known` where present.
    pub fn load(
        library: &Library,
        scope: RecordScope,
        now: DateTime<Utc>,
        all: Option<Vec<Meeting>>,
        known: &HashMap<Uuid, OutcomeProjection>,
    ) -> Self {
        let all = all.unwrap_or_else(|| read_all_meetings(library));
        let shared: Vec<Meeting> = all
            .iter()
            .filter(|meeting| is_shared(meeting, scope.history, now))
            .cloned()
            .collect();
        let classes = scope.data_classes;
        let needs_outcomes = classes.meetings || classes.people || classes.projects;
        let projections = if needs_outcomes {
            load_projections(library, &shared, known)
        } else {
            HashMap::new()
        };
        let (mut people, mut projects) = (Vec::new(), Vec::new());
        if needs_outcomes {
            // Dream memory is never read: its projects and review notes stay
            // on this computer, so only tracked projects and recurring topics
            // remain.
            match lokalbot_core::projects::build_people_and_projects_from(library, shared.clone()) {
                Ok((built_people, built_projects)) => {
                    people = built_people;
                    projects = built_projects;
                    projects.retain(ProjectProfile::is_tracked);
                }
                Err(err) => log::warn!("companion: people and projects failed: {err:#}"),
            }
        }
        let project_summaries = if classes.projects {
            load_project_summaries(library)
        } else {
            HashMap::new()
        };
        Self {
            library: library.clone(),
            scope,
            now,
            all_meetings: all,
            meetings: shared,
            projections,
            people,
            projects,
            project_summaries,
        }
    }

    /// The library again after a change: meetings re-read, outcomes reused
    /// from `cached` where present, people and projects rebuilt only when
    /// asked.
    pub fn reloading(
        previous: Self,
        now: DateTime<Utc>,
        cached: &HashMap<Uuid, OutcomeProjection>,
        recompute_connections: bool,
    ) -> Self {
        let all = read_all_meetings(&previous.library);
        if recompute_connections {
            return Self::load(&previous.library, previous.scope, now, Some(all), cached);
        }
        let scope = previous.scope;
        let shared: Vec<Meeting> = all
            .iter()
            .filter(|meeting| is_shared(meeting, scope.history, now))
            .cloned()
            .collect();
        let classes = scope.data_classes;
        let projections = if classes.meetings || classes.people || classes.projects {
            load_projections(&previous.library, &shared, cached)
        } else {
            HashMap::new()
        };
        Self {
            all_meetings: all,
            meetings: shared,
            projections,
            now,
            ..previous
        }
    }
}

fn load_projections(
    library: &Library,
    meetings: &[Meeting],
    known: &HashMap<Uuid, OutcomeProjection>,
) -> HashMap<Uuid, OutcomeProjection> {
    let mut projections = HashMap::new();
    for meeting in meetings {
        let projection = known
            .get(&meeting.id)
            .filter(|cached| cached.meeting == *meeting)
            .cloned()
            .or_else(|| library.outcome_projection(meeting).ok().flatten());
        if let Some(projection) = projection {
            projections.insert(meeting.id, projection);
        }
    }
    projections
}

fn load_project_summaries(library: &Library) -> HashMap<Uuid, ProjectSummary> {
    library
        .project_summaries()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|summary| {
            let id = summary
                .project_id
                .strip_prefix("tracked:")
                .and_then(|id| Uuid::parse_str(id).ok())?;
            Some((id, summary))
        })
        .collect()
}
