//! Suggests long-running work as Personal Context items (`WorkMemoryPromotion`).
//! The review keeps short-lived work memory; a goal or project it keeps seeing
//! for two weeks or more, and saw in the last week, says something durable about
//! the person. No model call. Every promotion waits for review and depends on the
//! review's evidence.

use std::collections::HashMap;

use super::{ClaimKind, LearningCandidate, Origin, WorkSighting, tombstone_key};
use crate::dream::{DreamMemory, day_from_key};
use crate::evidence::Provenance;

pub const MINIMUM_DAYS: i64 = 14;
pub const RECENT_DAYS: i64 = 7;

#[derive(Clone, Debug, PartialEq)]
pub struct Promotion {
    pub sightings: Vec<WorkSighting>,
    pub candidates: Vec<LearningCandidate>,
}

fn days_between(start: &str, end: &str) -> i64 {
    match (day_from_key(start), day_from_key(end)) {
        (Some(start), Some(end)) => (end - start).num_days(),
        _ => 0,
    }
}

/// Records when each current goal and project was first seen, forgets ones the
/// memory no longer holds, and returns those that qualify.
pub fn evaluate(memory: &DreamMemory, sightings: &[WorkSighting], day_key: &str) -> Promotion {
    let first_seen: HashMap<&str, &str> = sightings
        .iter()
        .map(|s| (s.key.as_str(), s.first_day_key.as_str()))
        .collect();
    let mut kept = Vec::new();
    let mut candidates = Vec::new();
    let mut consider = |key: String,
                        kind: ClaimKind,
                        text: String,
                        last_active: &str,
                        provenance: Option<&Provenance>| {
        let first = first_seen
            .get(key.as_str())
            .copied()
            .unwrap_or(day_key)
            .to_string();
        kept.push(WorkSighting {
            key,
            first_day_key: first.clone(),
        });
        let Some(provenance) = provenance.filter(|p| !p.includes_unattributed_context) else {
            return;
        };
        if days_between(&first, day_key) >= MINIMUM_DAYS
            && days_between(last_active, day_key) <= RECENT_DAYS
        {
            candidates.push(LearningCandidate {
                kind,
                text,
                quote: None,
                origin: Origin::WorkMemory { day_key: first },
                evidence: Some(provenance.clone()),
                needs_review: true,
            });
        }
    };
    for goal in &memory.work_goals {
        consider(
            format!("goal:{}", tombstone_key(&goal.text)),
            ClaimKind::Goal,
            goal.text.clone(),
            &goal.last_reinforced_day,
            goal.provenance.as_ref(),
        );
    }
    for project in &memory.active_projects {
        consider(
            format!("project:{}", tombstone_key(&project.name)),
            ClaimKind::Fact,
            project_claim(&project.name),
            &project.last_active_day,
            project.provenance.as_ref(),
        );
    }
    Promotion {
        sightings: kept,
        candidates,
    }
}

pub(crate) fn project_claim(name: &str) -> String {
    format!("I work on {name}.")
}
