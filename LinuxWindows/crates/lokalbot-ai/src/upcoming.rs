//! Preparation for an upcoming meeting (`UpcomingMeetingPreparation.swift`).
//!
//! Code picks the evidence: prior meetings by attendees and recurring title,
//! their decisions, open commitments and related projects. The local Think
//! model only rewrites that packet into a short brief, which is kept in
//! memory and never saved.

use std::collections::HashSet;

use anyhow::Result;
use chrono::{DateTime, Local, Utc};
use serde::Deserialize;
use serde_json::json;
use unicode_normalization::UnicodeNormalization as _;
use unicode_normalization::char::is_combining_mark;
use uuid::Uuid;

use lokalbot_core::calendar::{CalendarEvent, resolved_meeting_identities, sanitize_agenda};
use lokalbot_core::model::ActionStatus;
use lokalbot_core::{Library, Meeting};

use crate::json::{extract_json_object, strip_reasoning};
use crate::sanitize::sanitize;
use crate::think::{ChatRequest, ThinkClient};

pub const LOOKBACK_DAYS: i64 = 180;
pub const MAXIMUM_RELATED_MEETINGS: usize = 6;
pub const MAXIMUM_REFERENCES_PER_KIND: usize = 5;
pub const MAXIMUM_PROJECTS: usize = 3;
pub const PROMPT_CONTEXT_CHARACTERS: usize = 12_000;

const GENERIC_TERMS: &[&str] = &[
    "and", "call", "daily", "for", "meeting", "monthly", "planning", "review", "standup", "sync",
    "team", "the", "weekly", "with",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReferenceKind {
    Decision,
    Commitment,
}

/// A decision or commitment with the meeting it came from, so Today can open
/// the source instead of an uncited assertion.
#[derive(Clone, Debug, PartialEq)]
pub struct UpcomingReference {
    pub id: String,
    pub kind: ReferenceKind,
    pub text: String,
    pub meeting_id: Uuid,
    pub meeting_title: String,
    pub meeting_date: DateTime<Utc>,
    pub owner: Option<String>,
    pub is_for_user: bool,
    pub due: Option<String>,
    pub source_meeting_count: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct UpcomingProject {
    pub name: String,
    pub status: String,
    pub last_active_day: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RelatedMeeting {
    pub meeting_id: Uuid,
    pub title: String,
    pub started_at: DateTime<Utc>,
    pub summary: String,
    pub participant_matches: usize,
    pub relevance_score: i64,
}

/// The bounded evidence behind one brief (`UpcomingMeetingEvidence`).
#[derive(Clone, Debug, PartialEq)]
pub struct UpcomingEvidence {
    pub event: CalendarEvent,
    pub related_meetings: Vec<RelatedMeeting>,
    pub decisions: Vec<UpcomingReference>,
    pub commitments: Vec<UpcomingReference>,
    pub projects: Vec<UpcomingProject>,
    /// The sanitized agenda, only when agenda use is on.
    pub agenda: Option<String>,
}

impl UpcomingEvidence {
    pub fn has_preparation_context(&self) -> bool {
        !self.related_meetings.is_empty()
            || !self.decisions.is_empty()
            || !self.commitments.is_empty()
            || !self.projects.is_empty()
            || self.agenda.is_some()
    }

    /// Changes whenever the evidence does, so a new summary or outcome
    /// invalidates a brief written for the old one.
    pub fn signature(&self) -> String {
        let meetings: Vec<String> = self
            .related_meetings
            .iter()
            .map(|m| format!("{}{}", m.meeting_id, m.summary))
            .collect();
        let commitments: Vec<String> = self
            .commitments
            .iter()
            .map(|c| {
                [
                    c.text.as_str(),
                    c.owner.as_deref().unwrap_or_default(),
                    if c.is_for_user { "true" } else { "false" },
                    c.due.as_deref().unwrap_or_default(),
                    &c.source_meeting_count.to_string(),
                ]
                .join("\u{1e}")
            })
            .collect();
        let projects: Vec<String> = self
            .projects
            .iter()
            .map(|p| format!("{}{}{}", p.name, p.status, p.last_active_day))
            .collect();
        let decisions: Vec<&str> = self.decisions.iter().map(|d| d.text.as_str()).collect();
        [
            self.event.external_id.clone(),
            self.event.title.clone(),
            self.event.start.timestamp().to_string(),
            self.event.end.timestamp().to_string(),
            self.event.participant_names.join("|"),
            meetings.join("|"),
            decisions.join("|"),
            commitments.join("|"),
            projects.join("|"),
            self.agenda.clone().unwrap_or_default(),
        ]
        .join("\u{1f}")
    }

    /// A model-free brief shown at once and whenever no model writes one. It
    /// only restates selected evidence.
    pub fn fallback_brief(&self) -> String {
        let mut sentences: Vec<String> = Vec::new();
        if let Some(decision) = self.decisions.first() {
            sentences.push(format!("Last decision: {}", sentence(&decision.text)));
        }
        if let Some(commitment) = self.commitments.first() {
            let mut detail = sentence(&commitment.text);
            if let Some(owner) = non_empty(commitment.owner.as_deref()) {
                detail.push_str(&format!(
                    " Owner: {}.",
                    owner_label(owner, commitment.is_for_user)
                ));
            }
            if let Some(due) = non_empty(commitment.due.as_deref()) {
                detail.push_str(&format!(" Due: {due}."));
            }
            sentences.push(format!("Commitment to revisit: {detail}"));
        }
        if let Some(project) = self.projects.first() {
            sentences.push(format!("{}: {}", project.name, sentence(&project.status)));
        }
        if sentences.is_empty()
            && let Some(first) = self.agenda.as_deref().and_then(|a| a.lines().next())
        {
            sentences.push(format!("On the agenda: {}", sentence(first)));
        }
        if sentences.is_empty()
            && let Some(prior) = self.related_meetings.first()
        {
            sentences.push(format!(
                "The closest prior context is {} from {}.",
                prior.title,
                abbreviated_date(prior.started_at)
            ));
        }
        if sentences.is_empty() {
            return "No related decisions or commitments were found in LokalBot yet.".into();
        }
        sanitize(&sentences[..sentences.len().min(3)].join(" "), Some(520))
    }

    /// Decisions, commitments and projects first; prior summaries share the
    /// room they leave, so long summaries cannot push them past the cap.
    pub fn prompt_context(&self) -> String {
        let start = self.event.start.with_timezone(&Local);
        let end = self.event.end.with_timezone(&Local);
        let mut head = vec![
            format!("Upcoming meeting: {}", self.event.title),
            format!(
                "Scheduled: {}–{}",
                start.format("%A, %B %-d, %Y at %-I:%M %p"),
                end.format("%-I:%M %p")
            ),
        ];
        if !self.event.participant_names.is_empty() {
            head.push(format!(
                "Participants: {}",
                self.event.participant_names.join(", ")
            ));
        }
        if let Some(agenda) = &self.agenda {
            head.push(format!("Agenda from the invitation:\n{agenda}"));
        }
        let tail = self.outcome_sections();
        let mut sections = head.clone();
        if !self.related_meetings.is_empty() {
            let heading = "Prior related meetings:";
            let fixed = head
                .iter()
                .chain(tail.iter())
                .chain(std::iter::once(&heading.to_string()))
                .cloned()
                .collect::<Vec<_>>()
                .join("\n\n")
                .chars()
                .count()
                + 2;
            let share =
                PROMPT_CONTEXT_CHARACTERS.saturating_sub(fixed) / self.related_meetings.len();
            let rows: Vec<String> = self
                .related_meetings
                .iter()
                .map(|related| {
                    let row = format!(
                        "- {} · {}",
                        abbreviated_date(related.started_at),
                        related.title
                    );
                    let room = share as i64 - row.chars().count() as i64 - 4;
                    if related.summary.is_empty() || room < 80 {
                        row
                    } else {
                        format!(
                            "{row}\n  {}",
                            sanitize(&related.summary, Some(room as usize))
                        )
                    }
                })
                .collect();
            sections.push(format!("{heading}\n{}", rows.join("\n")));
        }
        sections.extend(tail);
        sanitize(&sections.join("\n\n"), Some(PROMPT_CONTEXT_CHARACTERS))
    }

    fn outcome_sections(&self) -> Vec<String> {
        let mut sections = Vec::new();
        if !self.decisions.is_empty() {
            sections.push(format!(
                "Prior decisions:\n{}",
                self.decisions
                    .iter()
                    .map(|d| format!("- {}", d.text))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
        if !self.commitments.is_empty() {
            let rows: Vec<String> = self
                .commitments
                .iter()
                .map(|reference| {
                    let mut metadata = Vec::new();
                    if let Some(owner) = non_empty(reference.owner.as_deref()) {
                        metadata.push(format!("owner: {owner}"));
                    }
                    if let Some(due) = non_empty(reference.due.as_deref()) {
                        metadata.push(format!("due: {due}"));
                    }
                    if reference.source_meeting_count > 1 {
                        metadata.push(format!(
                            "sources: {} meetings",
                            reference.source_meeting_count
                        ));
                    }
                    if metadata.is_empty() {
                        format!("- {}", reference.text)
                    } else {
                        format!("- {} ({})", reference.text, metadata.join(", "))
                    }
                })
                .collect();
            sections.push(format!(
                "Commitments from prior notes (using saved corrections and status):\n{}",
                rows.join("\n")
            ));
        }
        if !self.projects.is_empty() {
            sections.push(format!(
                "Recent project context:\n{}",
                self.projects
                    .iter()
                    .map(|p| format!(
                        "- {}: {} (last active {})",
                        p.name, p.status, p.last_active_day
                    ))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
        sections
    }
}

/// Everything LokalBot knows for `event` (`UpcomingMeetingPreparationCompiler`):
/// prior meetings of the last 180 days, scored by shared attendees, then a
/// recurring title, then recency.
pub fn compile(
    event: &CalendarEvent,
    library: &Library,
    now: DateTime<Utc>,
    include_agenda: bool,
) -> UpcomingEvidence {
    let meetings = library.list_own_meetings().unwrap_or_else(|err| {
        log::warn!("preparation: meetings could not be listed: {err:#}");
        Vec::new()
    });
    let summaries = |meeting: &Meeting| -> String {
        library
            .summary(meeting)
            .ok()
            .flatten()
            .map(|summary| sanitize(&summary, Some(1_600)))
            .unwrap_or_default()
    };
    let memory = read_projects(library);
    compile_with(
        event,
        &meetings,
        &summaries,
        library,
        &memory,
        now,
        include_agenda,
    )
}

fn compile_with(
    event: &CalendarEvent,
    meetings: &[Meeting],
    summary_of: &dyn Fn(&Meeting) -> String,
    library: &Library,
    memory: &[MemoryProject],
    now: DateTime<Utc>,
    include_agenda: bool,
) -> UpcomingEvidence {
    let cutoff = now - chrono::Duration::days(LOOKBACK_DAYS);
    let event_terms = terms(&event.title, true);
    let event_names: HashSet<String> = event
        .participant_names
        .iter()
        .map(|n| normalized_phrase(n))
        .filter(|n| !n.is_empty())
        .collect();

    let mut scored: Vec<(RelatedMeeting, &Meeting)> = meetings
        .iter()
        .filter(|m| m.ended_at.is_some() && m.started_at < now && m.started_at >= cutoff)
        .filter_map(|meeting| {
            let summary = summary_of(meeting);
            let prior_names: HashSet<String> = resolved_meeting_identities(meeting)
                .into_iter()
                .filter_map(|identity| identity.name)
                .map(|name| normalized_phrase(&name))
                .filter(|name| !name.is_empty())
                .collect();
            let direct = event_names.intersection(&prior_names).count();
            let corpus = terms(&format!("{}\n{}", meeting.title, summary), true);
            let mentioned = event
                .participant_names
                .iter()
                .filter(|name| {
                    let name_terms = terms(name, false);
                    !name_terms.is_empty() && name_terms.is_subset(&corpus)
                })
                .count();
            let participant_matches = direct.max(mentioned);
            let prior_title = meeting.calendar_title.as_deref().unwrap_or(&meeting.title);
            let exact_title = normalized_phrase(&event.title) == normalized_phrase(prior_title);
            let title_overlap = event_terms.intersection(&terms(prior_title, true)).count();
            let mut score = participant_matches as i64 * 120 + title_overlap as i64 * 24;
            if exact_title {
                score += 100;
            }
            if score <= 0 {
                return None;
            }
            if meeting.started_at >= now - chrono::Duration::days(30) {
                score += 12;
            }
            Some((
                RelatedMeeting {
                    meeting_id: meeting.id,
                    title: meeting.title.clone(),
                    started_at: meeting.started_at,
                    summary,
                    participant_matches,
                    relevance_score: score,
                },
                meeting,
            ))
        })
        .collect();
    scored.sort_by(|(a, _), (b, _)| {
        b.relevance_score
            .cmp(&a.relevance_score)
            .then(b.started_at.cmp(&a.started_at))
    });
    scored.truncate(MAXIMUM_RELATED_MEETINGS);

    let mut decisions = Vec::new();
    let mut action_references = Vec::new();
    for (_, meeting) in &scored {
        let Ok(Some(projection)) = library.outcome_projection(meeting) else {
            continue;
        };
        for (index, decision) in projection.outcomes.decision_records.iter().enumerate() {
            decisions.push(UpcomingReference {
                id: format!(
                    "{}-decision-{index}",
                    lokalbot_core::ids::uuid_upper(&meeting.id)
                ),
                kind: ReferenceKind::Decision,
                text: decision.text.clone(),
                meeting_id: meeting.id,
                meeting_title: meeting.title.clone(),
                meeting_date: meeting.started_at,
                owner: None,
                is_for_user: false,
                due: None,
                source_meeting_count: 1,
            });
        }
        action_references.extend(projection.action_references());
    }
    let commitments: Vec<UpcomingReference> =
        lokalbot_core::actions::cluster_threads(action_references)
            .into_iter()
            .filter(|thread| thread.status() != ActionStatus::Done)
            .map(|thread| {
                let source = thread.latest();
                UpcomingReference {
                    id: thread.id.clone(),
                    kind: ReferenceKind::Commitment,
                    text: thread.text.clone(),
                    meeting_id: source.meeting_id,
                    meeting_title: source.meeting_title.clone(),
                    meeting_date: source.meeting_started_at,
                    owner: thread.owner.clone(),
                    is_for_user: thread.is_for_user(),
                    due: thread.due.clone(),
                    source_meeting_count: thread.meeting_count(),
                }
            })
            .collect();
    let related: Vec<RelatedMeeting> = scored.into_iter().map(|(related, _)| related).collect();
    let projects = project_context(memory, &event_terms, &related);
    decisions.truncate(MAXIMUM_REFERENCES_PER_KIND);
    let mut commitments = commitments;
    commitments.truncate(MAXIMUM_REFERENCES_PER_KIND);
    UpcomingEvidence {
        event: event.clone(),
        related_meetings: related,
        decisions,
        commitments,
        projects,
        agenda: if include_agenda {
            sanitize_agenda(event.agenda.as_deref())
        } else {
            None
        },
    }
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MemoryProject {
    pub name: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub last_active_day: String,
    #[serde(default)]
    pub pinned: bool,
}

/// `DreamMemory.activeProjects` from `memory/memory.json`.
fn read_projects(library: &Library) -> Vec<MemoryProject> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Memory {
        #[serde(default)]
        active_projects: Vec<MemoryProject>,
    }
    std::fs::read(library.paths().root().join("memory/memory.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Memory>(&bytes).ok())
        .map(|memory| memory.active_projects)
        .unwrap_or_default()
}

fn project_context(
    memory: &[MemoryProject],
    event_terms: &HashSet<String>,
    related: &[RelatedMeeting],
) -> Vec<UpcomingProject> {
    let related_terms: HashSet<String> = related
        .iter()
        .flat_map(|item| terms(&format!("{}\n{}", item.title, item.summary), true))
        .collect();
    let mut scored: Vec<(i64, &MemoryProject)> = memory
        .iter()
        .filter_map(|project| {
            let project_terms = terms(&project.name, true);
            if project_terms.is_empty() {
                return None;
            }
            let direct = project_terms.intersection(event_terms).count() as i64;
            let contextual = project_terms.intersection(&related_terms).count() as i64;
            if direct == 0 && contextual == 0 {
                return None;
            }
            Some((
                direct * 100 + contextual * 20 + if project.pinned { 5 } else { 0 },
                project,
            ))
        })
        .collect();
    scored.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then(b.1.last_active_day.cmp(&a.1.last_active_day))
    });
    scored
        .into_iter()
        .take(MAXIMUM_PROJECTS)
        .map(|(_, project)| UpcomingProject {
            name: project.name.clone(),
            status: project.status.clone(),
            last_active_day: project.last_active_day.clone(),
        })
        .collect()
}

const BRIEF_SYSTEM: &str = "You write a concise pre-meeting brief from private evidence already selected by LokalBot.
Use only supplied evidence. Do not invent history, completion, ownership, dates, or attendee intent.
Write two or three direct sentences: what matters now, a prior decision, and a commitment or risk to revisit.
Avoid headings, bullets, greetings, and meta commentary. Return only the requested JSON object.";

/// Rewrites the evidence into two or three sentences
/// (`UpcomingMeetingBriefGenerator`). Only for a Think model on this computer.
pub fn generate_brief(think: &ThinkClient, evidence: &UpcomingEvidence) -> Result<String> {
    if !evidence.has_preparation_context() {
        anyhow::bail!("No related local context was found.");
    }
    if !think.is_local() {
        anyhow::bail!("Choose an on-device Think model to generate this brief.");
    }
    #[derive(Deserialize)]
    struct Draft {
        brief: String,
    }
    let schema = json!({
        "type": "object",
        "properties": {"brief": {"type": "string"}},
        "required": ["brief"],
        "additionalProperties": false,
    });
    let user = format!(
        "{}\n\nPrepare me for {}.",
        evidence.prompt_context(),
        evidence.event.title
    );
    let request = ChatRequest::new(BRIEF_SYSTEM, user)
        .max_tokens(420 + think.minimum_structured_output_tokens())
        .reasoning_budget(256)
        .temperature(0.2)
        .json_schema(schema);
    let output = think.complete(&request)?;
    let visible = strip_reasoning(&output);
    let draft: Draft = extract_json_object(&visible)
        .and_then(|json| serde_json::from_str(json).ok())
        .ok_or_else(|| anyhow::anyhow!("The local model returned an unreadable brief."))?;
    let clean = sanitize(&draft.brief, Some(700));
    if clean.is_empty() {
        anyhow::bail!("The local model returned an unreadable brief.");
    }
    Ok(clean)
}

fn sentence(value: &str) -> String {
    let clean = sanitize(value, Some(220));
    match clean.chars().last() {
        Some(last) if !".!?".contains(last) => format!("{clean}."),
        _ => clean,
    }
}

fn non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|v| !v.is_empty())
}

/// `SpeakerDisplayName.label` for an owner: the user reads as "You".
fn owner_label(owner: &str, is_for_user: bool) -> String {
    let trimmed = owner.trim();
    if is_for_user || trimmed.eq_ignore_ascii_case("me") {
        return "You".into();
    }
    if trimmed.eq_ignore_ascii_case("them") {
        return "Other speaker".into();
    }
    trimmed.to_string()
}

fn abbreviated_date(value: DateTime<Utc>) -> String {
    value.with_timezone(&Local).format("%b %-d, %Y").to_string()
}

/// Case- and accent-folded words joined by single spaces.
fn normalized_phrase(value: &str) -> String {
    let folded: String = value
        .nfkd()
        .filter(|c| !is_combining_mark(*c))
        .collect::<String>()
        .to_lowercase();
    folded
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

fn terms(value: &str, dropping_generic: bool) -> HashSet<String> {
    normalized_phrase(value)
        .split(' ')
        .filter(|term| {
            term.chars().count() >= 3 && (!dropping_generic || !GENERIC_TERMS.contains(term))
        })
        .map(str::to_string)
        .collect()
}

#[cfg(test)]
#[path = "upcoming_tests.rs"]
mod tests;
