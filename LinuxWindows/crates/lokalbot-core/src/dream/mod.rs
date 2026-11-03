//! The overnight review's artifacts (`Services/Dreaming/DreamModels.swift`):
//! one report per reviewed day and the durable work memory of active projects,
//! goals and patterns. The formats match the Mac's, so a library written by
//! either app is read by the other.

pub mod presentation;
pub mod rollup;
pub mod store;

#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Duration, Local, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

use crate::evidence::{Provenance, Source};
use crate::text::redact;
use crate::time::iso_seconds;

pub use store::{DreamStore, MemoryEntry, StoreError};

/// The retrospective looks back at most this many days, the reviewed day
/// included (`DreamCompiler.comparisonWindowDays`).
pub const COMPARISON_WINDOW_DAYS: i64 = 14;
/// `DreamScheduler.catchUpDays`: yesterday plus the six days before it.
pub const CATCH_UP_DAYS: i64 = 7;
pub const REPORT_VERSION: i32 = 3;
pub const MEMORY_VERSION: i32 = 2;

pub const MAX_PROJECTS: usize = 12;
pub const MAX_GOALS: usize = 10;
pub const MAX_PATTERNS: usize = 12;
pub const MAX_EVIDENCE_PER_PROJECT: usize = 4;
pub const PROJECT_RETENTION_DAYS: i64 = 30;
pub const GOAL_RETENTION_DAYS: i64 = 45;

/// `DreamDay.key`: local calendar days as `yyyy-MM-dd`, which sort by date.
pub fn day_key(day: NaiveDate) -> String {
    day.format("%Y-%m-%d").to_string()
}

pub fn day_from_key(key: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(key, "%Y-%m-%d").ok()
}

/// A canonical key: the same text it parses back to.
pub fn is_canonical_day_key(key: &str) -> bool {
    day_from_key(key).is_some_and(|day| day_key(day) == key)
}

/// `DreamEvidenceInvalidation.dayKeys`: a source feeds its own day and the
/// comparison windows that follow it. Days without a report are included so
/// work already in flight is cancelled.
pub fn report_day_keys(
    days: impl IntoIterator<Item = NaiveDate>,
    through: NaiveDate,
    window_days: i64,
) -> BTreeSet<String> {
    let mut keys = BTreeSet::new();
    let days: BTreeSet<NaiveDate> = days.into_iter().collect();
    for first in days {
        for offset in 0..window_days.max(1) {
            let day = first + Duration::days(offset);
            if day > through {
                break;
            }
            keys.insert(day_key(day));
        }
    }
    keys
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InferenceLocation {
    Local,
    Remote,
}

/// Where the Think model processed a review. Paths, queries, credentials and
/// keys are never stored, only the approved origin.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InferenceProvenance {
    pub location: InferenceLocation,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
}

impl InferenceProvenance {
    pub fn local() -> Self {
        Self {
            location: InferenceLocation::Local,
            origin: None,
        }
    }

    pub fn remote(origin: Option<String>) -> Self {
        Self {
            location: InferenceLocation::Remote,
            origin,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FallbackReason {
    EngineUnavailable,
    UnparseableResponse,
    EmptyDay,
}

/// One overnight retrospective, `dreams/<day>.json`. A valid report whose day
/// matches its file name doubles as the "this day was reviewed" marker. No
/// `engine_name` marks an evidence-only brief.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DreamReport {
    #[serde(default = "report_version")]
    pub version: i32,
    /// The reviewed local day, not the day the report is shown.
    pub day: String,
    #[serde(with = "iso_seconds")]
    pub generated_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub engine_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inference_provenance: Option<InferenceProvenance>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback_reason: Option<FallbackReason>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence_provenance: Option<Provenance>,
    pub narrative: String,
    #[serde(default)]
    pub attention: Vec<String>,
    #[serde(default)]
    pub repeated_work: Vec<String>,
    #[serde(default)]
    pub suggested_checks: Vec<String>,
    #[serde(default)]
    pub frictions: Vec<String>,
    #[serde(default)]
    pub top_actions: Vec<String>,
    /// The action thread behind each top action, aligned by index.
    #[serde(
        default,
        rename = "topActionThreadIDs",
        skip_serializing_if = "Option::is_none"
    )]
    pub top_action_thread_ids: Option<Vec<Option<String>>>,
}

fn report_version() -> i32 {
    1
}

impl DreamReport {
    pub fn new(day: String, generated_at: DateTime<Utc>, narrative: String) -> Self {
        Self {
            version: REPORT_VERSION,
            day,
            generated_at,
            engine_name: None,
            inference_provenance: None,
            fallback_reason: None,
            evidence_provenance: None,
            narrative,
            attention: Vec::new(),
            repeated_work: Vec::new(),
            suggested_checks: Vec::new(),
            frictions: Vec::new(),
            top_actions: Vec::new(),
            top_action_thread_ids: None,
        }
    }

    pub fn top_action_thread_id(&self, index: usize) -> Option<&str> {
        self.top_action_thread_ids.as_ref()?.get(index)?.as_deref()
    }

    pub fn is_fallback(&self) -> bool {
        self.engine_name.is_none()
    }

    /// Today and the Markdown copy tell the same truth about where the model
    /// ran and why a brief is evidence-only. Written for the file; `tr` keys
    /// are used by the page when it shows this.
    pub fn provenance_description(&self) -> String {
        if let Some(engine) = &self.engine_name {
            return match self.inference_provenance.as_ref().map(|p| p.location) {
                Some(InferenceLocation::Local) => {
                    format!("Dreamed by {engine} on this computer.")
                }
                Some(InferenceLocation::Remote) => {
                    let destination = self
                        .inference_provenance
                        .as_ref()
                        .and_then(|p| p.origin.as_ref())
                        .map(|origin| format!(" at {origin}"))
                        .unwrap_or_default();
                    format!(
                        "Dreamed by {engine} using approved remote inference{destination}. The report was saved in your local library."
                    )
                }
                None => format!(
                    "Dreamed by {engine} using your configured Think model. The report was saved in your local library."
                ),
            };
        }
        match self.fallback_reason {
            Some(FallbackReason::EngineUnavailable) => {
                "No model was reachable overnight; this evidence-only brief was saved locally."
                    .into()
            }
            Some(FallbackReason::UnparseableResponse) => {
                "The model replied, but its response could not be read; this evidence-only brief was saved locally."
                    .into()
            }
            Some(FallbackReason::EmptyDay) => {
                "Nothing substantive was recorded that day, so no model ran; this placeholder just keeps the record complete."
                    .into()
            }
            None => "Written as an evidence-only fallback and saved locally.".into(),
        }
    }

    pub fn markdown(&self) -> String {
        let mut lines = vec![format!("# Morning brief — {}", self.day), String::new()];
        lines.push(format!("_{}_", self.provenance_description()));
        if !self.narrative.is_empty() {
            lines.push(String::new());
            lines.push(self.narrative.clone());
        }
        section("Needs attention first", &self.attention, &mut lines, false);
        section("Top actions today", &self.top_actions, &mut lines, true);
        section(
            "Repeated work worth automating",
            &self.repeated_work,
            &mut lines,
            false,
        );
        section(
            "Suggested recurring checks",
            &self.suggested_checks,
            &mut lines,
            false,
        );
        section("Friction to smooth out", &self.frictions, &mut lines, false);
        lines.join("\n")
    }

    /// Reports derive from screen text and transcripts, so the same credential
    /// scrubbing applied to exports runs before anything is saved.
    pub fn redacted(&self) -> Self {
        let mut report = self.clone();
        report.narrative = redact(&self.narrative);
        report.attention = self.attention.iter().map(|t| redact(t)).collect();
        report.repeated_work = self.repeated_work.iter().map(|t| redact(t)).collect();
        report.suggested_checks = self.suggested_checks.iter().map(|t| redact(t)).collect();
        report.frictions = self.frictions.iter().map(|t| redact(t)).collect();
        report.top_actions = self.top_actions.iter().map(|t| redact(t)).collect();
        report
    }
}

fn section(title: &str, items: &[String], lines: &mut Vec<String>, numbered: bool) {
    if items.is_empty() {
        return;
    }
    lines.extend([String::new(), format!("## {title}"), String::new()]);
    for (index, item) in items.iter().enumerate() {
        lines.push(if numbered {
            format!("{}. {item}", index + 1)
        } else {
            format!("- {item}")
        });
    }
}

/// What one night proposes: full updated lists, merged by [`DreamMemory::merging`]
/// so day stamps, retention and caps stay app code rather than model behaviour.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MemoryUpdate {
    pub active_projects: Vec<ProposedProject>,
    pub work_goals: Vec<ProposedGoal>,
    pub recurring_patterns: Vec<String>,
}

impl MemoryUpdate {
    pub fn is_empty(&self) -> bool {
        self.active_projects.is_empty()
            && self.work_goals.is_empty()
            && self.recurring_patterns.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProposedProject {
    pub name: String,
    pub status: String,
    pub evidence: Vec<String>,
    /// True only when the day's evidence shows work on it; `None` when a
    /// backend left it out, which keeps the older text-change rule.
    pub active_today: Option<bool>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProposedGoal {
    pub text: String,
    pub horizon: String,
    pub reinforced_today: bool,
    pub expired: bool,
}

/// `memory/memory.json`, fed back into the next night's review.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DreamMemory {
    pub version: i32,
    #[serde(with = "iso_seconds")]
    pub updated_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_dream_day: Option<String>,
    pub active_projects: Vec<MemoryProject>,
    pub work_goals: Vec<MemoryGoal>,
    pub recurring_patterns: Vec<String>,
    /// Missing entries are unattributed legacy data.
    #[serde(default)]
    pub pattern_provenance: BTreeMap<String, Provenance>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryProject {
    pub name: String,
    pub status: String,
    pub last_active_day: String,
    #[serde(default)]
    pub evidence: Vec<String>,
    /// Exempt from age-out and the cap. A review can update it, never remove it.
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provenance: Option<Provenance>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryGoal {
    pub text: String,
    /// As stated or inferred ("this week", "Q3"), never a normalized date.
    pub horizon: String,
    pub last_reinforced_day: String,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provenance: Option<Provenance>,
}

fn same_text(lhs: &str, rhs: &str) -> bool {
    lhs.to_lowercase() == rhs.to_lowercase()
}

impl DreamMemory {
    pub fn empty(updated_at: DateTime<Utc>) -> Self {
        Self {
            version: MEMORY_VERSION,
            updated_at,
            last_dream_day: None,
            active_projects: Vec::new(),
            work_goals: Vec::new(),
            recurring_patterns: Vec::new(),
            pattern_provenance: BTreeMap::new(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.active_projects.is_empty()
            && self.work_goals.is_empty()
            && self.recurring_patterns.is_empty()
    }

    /// `DreamMemory.merging`: projects update or insert by case-insensitive
    /// name; goals refresh or insert only when tied to the day's evidence; a
    /// goal marked expired goes unless pinned; what the model didn't mention
    /// stays until it ages out; pins skip age-out and the cap; patterns are a
    /// full replacement list.
    pub fn merging(
        &self,
        update: &MemoryUpdate,
        dream_day: &str,
        at: DateTime<Utc>,
        provenance: Option<&Provenance>,
    ) -> Self {
        let mut merged = self.clone();
        merged.version = MEMORY_VERSION;
        merged.updated_at = at;
        merged.last_dream_day = Some(dream_day.to_string());

        let mut projects = self.active_projects.clone();
        for proposed in update.active_projects.iter().take(MAX_PROJECTS) {
            let evidence: Vec<String> = proposed
                .evidence
                .iter()
                .take(MAX_EVIDENCE_PER_PROJECT)
                .cloned()
                .collect();
            if let Some(project) = projects
                .iter_mut()
                .find(|p| same_text(&p.name, &proposed.name))
            {
                let changed = project.status != proposed.status || project.evidence != evidence;
                project.status = proposed.status.clone();
                project.evidence = evidence;
                // Freshness follows the day's evidence, not wording: a
                // paraphrase mustn't keep a dead project alive, and an active
                // project repeated verbatim mustn't age out.
                let active = proposed.active_today.unwrap_or(changed);
                if active {
                    project.last_active_day = dream_day.to_string();
                }
                if active || changed {
                    project.provenance = provenance.cloned();
                }
            } else if proposed.active_today != Some(false) {
                projects.push(MemoryProject {
                    name: proposed.name.clone(),
                    status: proposed.status.clone(),
                    last_active_day: dream_day.to_string(),
                    evidence,
                    pinned: false,
                    provenance: provenance.cloned(),
                });
            }
        }
        projects.retain(|p| {
            p.pinned || is_fresh(&p.last_active_day, dream_day, PROJECT_RETENTION_DAYS)
        });
        projects.sort_by(|a, b| {
            b.pinned
                .cmp(&a.pinned)
                .then_with(|| b.last_active_day.cmp(&a.last_active_day))
                .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
        });
        projects.truncate(MAX_PROJECTS);
        merged.active_projects = projects;

        let mut goals = self.work_goals.clone();
        for proposed in update.work_goals.iter().filter(|g| g.expired) {
            if let Some(index) = goals
                .iter()
                .position(|g| same_text(&g.text, &proposed.text))
                && !goals[index].pinned
            {
                goals.remove(index);
            }
        }
        for proposed in update
            .work_goals
            .iter()
            .filter(|g| !g.expired)
            .take(MAX_GOALS)
        {
            if let Some(goal) = goals
                .iter_mut()
                .find(|g| same_text(&g.text, &proposed.text))
            {
                if proposed.reinforced_today {
                    goal.horizon = proposed.horizon.clone();
                    goal.last_reinforced_day = dream_day.to_string();
                    goal.provenance = provenance.cloned();
                }
            } else if proposed.reinforced_today {
                goals.push(MemoryGoal {
                    text: proposed.text.clone(),
                    horizon: proposed.horizon.clone(),
                    last_reinforced_day: dream_day.to_string(),
                    pinned: false,
                    provenance: provenance.cloned(),
                });
            }
        }
        goals.retain(|g| {
            g.pinned || is_fresh(&g.last_reinforced_day, dream_day, GOAL_RETENTION_DAYS)
        });
        goals.sort_by(|a, b| {
            b.pinned
                .cmp(&a.pinned)
                .then_with(|| b.last_reinforced_day.cmp(&a.last_reinforced_day))
                .then_with(|| a.text.to_lowercase().cmp(&b.text.to_lowercase()))
        });
        goals.truncate(MAX_GOALS);
        merged.work_goals = goals;

        merged.recurring_patterns = update
            .recurring_patterns
            .iter()
            .take(MAX_PATTERNS)
            .cloned()
            .collect();
        merged.pattern_provenance = BTreeMap::new();
        for pattern in &merged.recurring_patterns {
            // An unchanged pattern keeps its dependencies; a reworded or new
            // one depends on everything the synthesis could read.
            let kept = if self.recurring_patterns.contains(pattern) {
                self.pattern_provenance.get(pattern)
            } else {
                provenance
            };
            if let Some(kept) = kept {
                merged
                    .pattern_provenance
                    .insert(pattern.clone(), kept.clone());
            }
        }
        merged
    }

    /// A synthesis can use any memory item in its context, so its dependencies
    /// are everything memory depends on as well as `sources`.
    pub fn provenance_adding(&self, sources: &[Source], revision: u64) -> Provenance {
        let mut dependencies: Vec<Option<&Provenance>> = Vec::new();
        dependencies.extend(self.active_projects.iter().map(|p| p.provenance.as_ref()));
        dependencies.extend(self.work_goals.iter().map(|g| g.provenance.as_ref()));
        dependencies.extend(
            self.recurring_patterns
                .iter()
                .map(|p| self.pattern_provenance.get(p)),
        );
        let mut all: Vec<Source> = sources.to_vec();
        let mut unattributed = false;
        for dependency in dependencies {
            match dependency {
                Some(provenance) => {
                    all.extend(provenance.sources.iter().cloned());
                    unattributed |= provenance.includes_unattributed_context;
                }
                None => unattributed = true,
            }
        }
        all.sort_by(|a, b| {
            a.day_key
                .cmp(&b.day_key)
                .then_with(|| a.kind.cmp(&b.kind))
                .then_with(|| a.id.cmp(&b.id))
        });
        all.dedup();
        Provenance {
            sources: all,
            revision,
            includes_unattributed_context: unattributed,
        }
    }

    pub fn markdown(&self) -> String {
        const NONE: &str = "_None observed yet._";
        let updated = self.updated_at.with_timezone(&Local).format("%Y-%m-%d");
        let mut lines = vec![
            "# Work memory".to_string(),
            String::new(),
            format!("_Maintained overnight by dreaming. Updated {updated}._"),
            String::new(),
            "## Active projects".to_string(),
            String::new(),
        ];
        if self.active_projects.is_empty() {
            lines.push(NONE.into());
        }
        for project in &self.active_projects {
            let pinned = if project.pinned { "pinned, " } else { "" };
            lines.push(format!(
                "- **{}** — {} _({pinned}last active {})_",
                project.name, project.status, project.last_active_day
            ));
            lines.extend(project.evidence.iter().map(|item| format!("  - {item}")));
        }
        lines.extend([String::new(), "## Current goals".into(), String::new()]);
        if self.work_goals.is_empty() {
            lines.push(NONE.into());
        }
        for goal in &self.work_goals {
            let pinned = if goal.pinned { "pinned, " } else { "" };
            lines.push(format!(
                "- {} _({}, {pinned}reinforced {})_",
                goal.text, goal.horizon, goal.last_reinforced_day
            ));
        }
        lines.extend([String::new(), "## Recurring patterns".into(), String::new()]);
        if self.recurring_patterns.is_empty() {
            lines.push(NONE.into());
        }
        lines.extend(self.recurring_patterns.iter().map(|p| format!("- {p}")));
        lines.join("\n")
    }

    pub fn redacted(&self) -> Self {
        let mut memory = self.clone();
        for project in &mut memory.active_projects {
            project.name = redact(&project.name);
            project.status = redact(&project.status);
            project.evidence = project.evidence.iter().map(|t| redact(t)).collect();
        }
        for goal in &mut memory.work_goals {
            goal.text = redact(&goal.text);
            goal.horizon = redact(&goal.horizon);
        }
        memory.pattern_provenance = BTreeMap::new();
        let mut unattributed: BTreeSet<String> = BTreeSet::new();
        memory.recurring_patterns = self
            .recurring_patterns
            .iter()
            .map(|pattern| {
                let scrubbed = redact(pattern);
                match self.pattern_provenance.get(pattern) {
                    Some(provenance) => {
                        // Redaction can collapse two strings; keep both's sources.
                        let merged = match memory.pattern_provenance.get(&scrubbed) {
                            Some(prior) => {
                                let mut sources = prior.sources.clone();
                                for source in &provenance.sources {
                                    if !sources.contains(source) {
                                        sources.push(source.clone());
                                    }
                                }
                                Provenance {
                                    sources,
                                    revision: prior.revision.min(provenance.revision),
                                    includes_unattributed_context: prior
                                        .includes_unattributed_context
                                        || provenance.includes_unattributed_context,
                                }
                            }
                            None => provenance.clone(),
                        };
                        memory.pattern_provenance.insert(scrubbed.clone(), merged);
                    }
                    None => {
                        unattributed.insert(scrubbed.clone());
                    }
                }
                scrubbed
            })
            .collect();
        for pattern in unattributed {
            memory.pattern_provenance.remove(&pattern);
        }
        memory
    }
}

/// An unparseable stamp counts as stale: a corrupted entry ages out.
fn is_fresh(day: &str, reference: &str, retention_days: i64) -> bool {
    match (day_from_key(day), day_from_key(reference)) {
        (Some(day), Some(reference)) => day >= reference - Duration::days(retention_days),
        _ => false,
    }
}
