//! A project's "Where it stands" note (`ProjectStatusGenerator.swift`):
//! grounded in the lines of its recent meetings that name it and the
//! decisions and actions that name it, cited per meeting, and stamped with
//! an evidence fingerprint so the page can tell when newer evidence exists.

use std::collections::{HashMap, HashSet};

use anyhow::Result;
use chrono::{DateTime, Local, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use lokalbot_core::model::{
    ActionStatus, ActionThread, ProjectPoint, ProjectProfile, ProjectSummary,
};
use lokalbot_core::{Library, ids};

use crate::json::{extract_json_object, strip_reasoning};
use crate::prompts::PROJECT_STATUS_SYSTEM;
use crate::sanitize::{redact, sanitize};
use crate::think::{ChatRequest, ThinkClient};

pub const MAXIMUM_MEETINGS: usize = 10;
pub const MAXIMUM_POINTS: usize = 5;
pub const MAXIMUM_QUESTIONS: usize = 3;
pub const MAXIMUM_CONTEXT_CHARACTERS: usize = 9_000;

#[derive(Debug, thiserror::Error)]
pub enum ProjectStatusError {
    #[error("No meetings or overnight review notes name this project yet.")]
    EmptyEvidence,
    #[error("The model returned an unreadable summary. The previous one is unchanged.")]
    UnreadableResponse,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MeetingEvidence {
    pub id: Uuid,
    /// "M1" is the newest meeting.
    pub label: String,
    pub title: String,
    pub date: DateTime<Utc>,
    pub lines: Vec<String>,
    pub decisions: Vec<String>,
    pub actions: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Evidence {
    pub project_name: String,
    pub other_names: Vec<String>,
    pub meetings: Vec<MeetingEvidence>,
    /// Open actions from meetings older than the ones listed, sorted.
    pub other_actions: Vec<String>,
    /// Overnight review notes; there is no overnight review on this platform
    /// yet, so this stays empty unless a caller supplies them.
    pub review_notes: Vec<String>,
}

impl Evidence {
    pub fn is_empty(&self) -> bool {
        self.meetings.is_empty() && self.review_notes.is_empty()
    }

    pub fn meeting_ids(&self) -> Vec<Uuid> {
        self.meetings.iter().map(|m| m.id).collect()
    }
}

/// `ProjectStatusGenerator.evidence(for:)`.
pub fn evidence(project: &ProjectProfile) -> Evidence {
    let mut decisions_by_meeting: HashMap<Uuid, Vec<String>> = HashMap::new();
    for (meeting, decision) in &project.decisions {
        decisions_by_meeting
            .entry(meeting.id)
            .or_default()
            .push(decision.text.clone());
    }
    let mut actions_by_meeting: HashMap<Uuid, Vec<String>> = HashMap::new();
    let threads = project
        .my_actions
        .iter()
        .chain(&project.others_actions)
        .chain(&project.older_others_actions);
    for thread in threads {
        actions_by_meeting
            .entry(thread.latest().meeting_id)
            .or_default()
            .push(action_line(thread));
    }
    let mut meetings = Vec::new();
    let mut listed = HashSet::new();
    for (index, meeting) in project.meetings.iter().take(MAXIMUM_MEETINGS).enumerate() {
        listed.insert(meeting.id);
        meetings.push(MeetingEvidence {
            id: meeting.id,
            label: format!("M{}", index + 1),
            title: meeting.title.clone(),
            date: meeting.started_at,
            lines: project
                .mentions
                .iter()
                .filter(|m| m.meeting_id == meeting.id)
                .map(|m| m.text.clone())
                .collect(),
            decisions: decisions_by_meeting
                .get(&meeting.id)
                .cloned()
                .unwrap_or_default(),
            actions: actions_by_meeting
                .get(&meeting.id)
                .cloned()
                .unwrap_or_default(),
        });
    }
    let mut other_actions: Vec<String> = actions_by_meeting
        .into_iter()
        .filter(|(meeting, _)| !listed.contains(meeting))
        .flat_map(|(_, actions)| actions)
        .collect();
    other_actions.sort();
    Evidence {
        project_name: project.name.clone(),
        other_names: project.other_names.clone(),
        meetings,
        other_actions,
        review_notes: Vec::new(),
    }
}

fn action_line(thread: &ActionThread) -> String {
    let mut details = Vec::new();
    if thread.is_for_user() {
        details.push("owner: the user".to_string());
    } else if let Some(owner) = &thread.owner {
        details.push(format!("owner: {}", speaker_label(owner)));
    }
    if let Some(due) = &thread.due {
        details.push(format!("due: {due}"));
    }
    details.push(
        if thread.status() == ActionStatus::Deferred {
            "deferred"
        } else {
            "open"
        }
        .to_string(),
    );
    format!("{} ({})", thread.text, details.join(", "))
}

/// `SpeakerDisplayName.label`: raw speaker keys read as people.
fn speaker_label(name: &str) -> String {
    let trimmed = name.trim();
    if trimmed.eq_ignore_ascii_case("them") {
        return "Other speaker".into();
    }
    if let Some(number) = trimmed
        .strip_prefix("Them ")
        .or_else(|| trimmed.strip_prefix("them "))
        && !number.is_empty()
        && number.chars().all(|c| c.is_ascii_digit())
    {
        return format!("Speaker {number}");
    }
    name.to_string()
}

fn short_date(date: &DateTime<Utc>) -> String {
    date.with_timezone(&Local).format("%b %-d, %Y").to_string()
}

/// The evidence as prompt text. It carries no date of its own, so its hash
/// changes only when the evidence does.
pub fn prompt_context(evidence: &Evidence) -> String {
    let mut header = format!("Project: {}", evidence.project_name);
    if !evidence.other_names.is_empty() {
        header.push_str(&format!(
            " (also called {})",
            evidence.other_names.join(", ")
        ));
    }
    let mut sections = vec![header];
    for meeting in &evidence.meetings {
        let mut lines = vec![format!(
            "{} · {} · {}",
            meeting.label,
            meeting.title,
            short_date(&meeting.date)
        )];
        lines.extend(meeting.lines.iter().map(|l| format!("- {l}")));
        if !meeting.decisions.is_empty() {
            lines.push("Decisions:".into());
            lines.extend(meeting.decisions.iter().map(|d| format!("- {d}")));
        }
        if !meeting.actions.is_empty() {
            lines.push("Actions:".into());
            lines.extend(meeting.actions.iter().map(|a| format!("- {a}")));
        }
        sections.push(lines.join("\n"));
    }
    if !evidence.other_actions.is_empty() {
        let mut lines = vec!["Open actions from older meetings:".to_string()];
        lines.extend(evidence.other_actions.iter().map(|a| format!("- {a}")));
        sections.push(lines.join("\n"));
    }
    if !evidence.review_notes.is_empty() {
        let mut lines = vec!["Overnight review notes (label: review):".to_string()];
        lines.extend(evidence.review_notes.iter().map(|n| format!("- {n}")));
        sections.push(lines.join("\n"));
    }
    sanitize(&sections.join("\n\n"), Some(MAXIMUM_CONTEXT_CHARACTERS))
}

/// SHA-256 (hex) of the prompt context.
pub fn fingerprint(evidence: &Evidence) -> String {
    hex::encode(Sha256::digest(prompt_context(evidence).as_bytes()))
}

/// Points cite a meeting label or "review"; the enum is dropped when the
/// server cannot hold that many values.
pub fn schema(labels: &[String], enum_limit: Option<usize>) -> Value {
    let mut sources: Vec<String> = labels.to_vec();
    sources.push("review".into());
    let mut source = json!({"type": "string"});
    if enum_limit.is_none_or(|limit| sources.len() <= limit) {
        source["enum"] = json!(sources);
    }
    json!({
        "type": "object",
        "properties": {
            "overview": {"type": "string"},
            "points": {"type": "array", "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "source": source},
                "required": ["text", "source"],
                "additionalProperties": false
            }},
            "open_questions": {"type": "array", "items": {"type": "string"}}
        },
        "required": ["overview", "points", "open_questions"],
        "additionalProperties": false
    })
}

#[derive(Deserialize)]
struct ReplyPoint {
    text: String,
    #[serde(default)]
    source: Option<String>,
}

#[derive(Deserialize)]
struct Reply {
    overview: String,
    #[serde(default)]
    points: Option<Vec<ReplyPoint>>,
    #[serde(default)]
    open_questions: Option<Vec<String>>,
}

/// Writes the status note for `project`. The library is the source of the
/// project's evidence (`Library::projects`); the note is returned, not saved
/// (`Library::save_project_summary` saves it).
pub fn generate(
    think: &ThinkClient,
    _library: &Library,
    project: &ProjectProfile,
) -> Result<ProjectSummary> {
    generate_from(think, &evidence(project), &project.id, Utc::now())
}

/// `ProjectStatusGenerator.generate(evidence:projectID:engine:location:now:)`.
pub fn generate_from(
    think: &ThinkClient,
    evidence: &Evidence,
    project_id: &str,
    now: DateTime<Utc>,
) -> Result<ProjectSummary> {
    if evidence.is_empty() {
        return Err(ProjectStatusError::EmptyEvidence.into());
    }
    let labels: Vec<String> = evidence.meetings.iter().map(|m| m.label.clone()).collect();
    let user = format!(
        "{}\n\nToday is {}. Write the status note for {}.",
        prompt_context(evidence),
        short_date(&now),
        evidence.project_name
    );
    let request = ChatRequest::new(PROJECT_STATUS_SYSTEM, user)
        .max_tokens(1_000 + think.minimum_structured_output_tokens())
        .reasoning_budget(256)
        .temperature(0.2)
        .json_schema(schema(&labels, think.structured_output_enum_limit()));
    let output = think.complete(&request)?;
    let visible = strip_reasoning(&output);
    let reply: Reply = extract_json_object(&visible)
        .and_then(|json| serde_json::from_str(json).ok())
        .ok_or(ProjectStatusError::UnreadableResponse)?;
    let overview = clean(&reply.overview);
    if overview.is_empty() {
        return Err(ProjectStatusError::UnreadableResponse.into());
    }
    let by_label: HashMap<&str, &MeetingEvidence> = evidence
        .meetings
        .iter()
        .map(|m| (m.label.as_str(), m))
        .collect();
    let mut points: Vec<ProjectPoint> = Vec::new();
    for point in reply.points.unwrap_or_default() {
        let text = clean(&point.text);
        if text.is_empty() || points.iter().any(|p| p.text == text) {
            continue;
        }
        let label = point
            .source
            .as_deref()
            .unwrap_or_default()
            .trim()
            .to_uppercase();
        let meeting = by_label.get(label.as_str());
        points.push(ProjectPoint {
            text,
            meeting_id: meeting.map(|m| ids::uuid_upper(&m.id)),
            meeting_title: meeting.map(|m| m.title.clone()),
            meeting_date: meeting.map(|m| {
                lokalbot_core::time::local_day(m.date)
                    .format("%Y-%m-%d")
                    .to_string()
            }),
        });
        if points.len() == MAXIMUM_POINTS {
            break;
        }
    }
    let open_questions: Vec<String> = reply
        .open_questions
        .unwrap_or_default()
        .into_iter()
        .map(|q| clean(&q))
        .filter(|q| !q.is_empty())
        .take(MAXIMUM_QUESTIONS)
        .collect();
    Ok(ProjectSummary {
        project_id: project_id.to_string(),
        overview,
        points,
        open_questions,
        meeting_ids: evidence.meeting_ids().iter().map(ids::uuid_upper).collect(),
        evidence_fingerprint: fingerprint(evidence),
        generated_at: now,
        engine_name: think.model_label(),
        location: think.location(),
    })
}

fn clean(text: &str) -> String {
    redact(text).trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply as Stub, StubServer};

    fn sample() -> Evidence {
        let date = DateTime::parse_from_rfc3339("2026-10-15T09:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        Evidence {
            project_name: "Laptop refresh".into(),
            other_names: vec!["Refresh".into()],
            meetings: vec![MeetingEvidence {
                id: Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap(),
                label: "M1".into(),
                title: "Budget review".into(),
                date,
                lines: vec!["The laptop refresh waits for the vendor quote.".into()],
                decisions: vec!["Refresh the editors first".into()],
                actions: vec!["Send the quote (owner: Speaker 2, open)".into()],
            }],
            other_actions: vec![],
            review_notes: vec![],
        }
    }

    #[test]
    fn context_and_schema_match_the_mac_layout() {
        let context = prompt_context(&sample());
        assert!(
            context.starts_with(
                "Project: Laptop refresh (also called Refresh)\n\nM1 · Budget review · Oct 1"
            ),
            "{context}"
        );
        assert!(context.contains("\nDecisions:\n- Refresh the editors first\nActions:\n- Send the quote (owner: Speaker 2, open)"));
        assert_eq!(fingerprint(&sample()).len(), 64);
        let schema = schema(&["M1".into()], None);
        assert_eq!(
            schema["properties"]["points"]["items"]["properties"]["source"]["enum"],
            json!(["M1", "review"])
        );
        let limited = super::schema(&["M1".into()], Some(1));
        assert!(
            limited["properties"]["points"]["items"]["properties"]["source"]
                .get("enum")
                .is_none()
        );
        assert_eq!(speaker_label("Them 3"), "Speaker 3");
        assert_eq!(speaker_label("them"), "Other speaker");
        assert_eq!(speaker_label("Maya"), "Maya");
    }

    #[test]
    fn generates_a_cited_note() {
        let server = StubServer::start(|_| {
            Stub::Json(
                200,
                json!({"choices": [{"message": {"content": r#"{"overview": " Waiting on the vendor quote. ", "points": [{"text": "Editors go first.", "source": "m1"}, {"text": "Editors go first.", "source": "M1"}, {"text": "Review says AKIAABCDEFGHIJKLMNOP leaked.", "source": "review"}], "open_questions": ["When does the quote arrive?", ""]}"#}, "finish_reason": "stop"}]}),
            )
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "qwen");
        let now = Utc::now();
        let summary = generate_from(&think, &sample(), "tracked:ABC", now).unwrap();
        assert_eq!(summary.overview, "Waiting on the vendor quote.");
        assert_eq!(summary.points.len(), 2);
        assert_eq!(
            summary.points[0].meeting_id.as_deref(),
            Some("11111111-1111-4111-8111-111111111111")
        );
        assert_eq!(
            summary.points[0].meeting_title.as_deref(),
            Some("Budget review")
        );
        assert!(summary.points[1].meeting_id.is_none());
        assert_eq!(
            summary.points[1].text,
            "Review says [REDACTED_AWS_KEY] leaked."
        );
        assert_eq!(
            summary.open_questions,
            vec!["When does the quote arrive?".to_string()]
        );
        assert_eq!(
            summary.meeting_ids,
            vec!["11111111-1111-4111-8111-111111111111".to_string()]
        );
        assert_eq!(summary.project_id, "tracked:ABC");
        assert_eq!(summary.location, "on this PC");
        let empty = Evidence {
            meetings: vec![],
            ..sample()
        };
        assert_eq!(
            generate_from(&think, &empty, "x", now)
                .unwrap_err()
                .to_string(),
            "No meetings or overnight review notes name this project yet."
        );
    }

    #[test]
    fn fixture_projects_build_evidence() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        for project in library.projects().unwrap() {
            let evidence = evidence(&project);
            assert!(evidence.meetings.len() <= MAXIMUM_MEETINGS);
            assert!(prompt_context(&evidence).starts_with(&format!("Project: {}", project.name)));
        }
    }
}
