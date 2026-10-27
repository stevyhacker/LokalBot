//! A follow-up email draft from one meeting's own outcomes
//! (`FollowUpDraftGenerator.swift`). Explicit (the user asks for it),
//! grounded (only the recap, decisions, corrected actions and open
//! questions) and never sent: the draft is returned for the user to review.

use std::collections::HashSet;

use anyhow::Result;
use chrono::{DateTime, Local, Utc};
use serde::Deserialize;
use serde_json::{Value, json};

use lokalbot_core::model::ActionStatus;
use lokalbot_core::{Library, Meeting, OutcomeProjection};

use crate::json::{extract_json_object, strip_reasoning};
use crate::prompts::FOLLOW_UP_SYSTEM;
use crate::sanitize::{redact, sanitize};
use crate::think::{ChatRequest, ThinkClient};

const MAXIMUM_CONTEXT_CHARACTERS: usize = 8_000;
const MAXIMUM_PARTICIPANTS: usize = 12;

#[derive(Debug, thiserror::Error)]
pub enum FollowUpError {
    #[error("This meeting has no recap or outcomes to follow up on yet.")]
    EmptyEvidence,
    #[error("The local model returned an unreadable draft. The outline is unchanged.")]
    UnreadableResponse,
}

/// The draft to show; nothing is sent.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FollowUpDraft {
    pub subject: String,
    pub body: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EvidenceAction {
    pub text: String,
    /// "Me" for the user's own work.
    pub owner: Option<String>,
    /// The resolved day ("Thu, Oct 22") or the spoken phrase.
    pub due: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Evidence {
    pub meeting_title: String,
    pub meeting_date: DateTime<Utc>,
    pub recap: Option<String>,
    pub decisions: Vec<String>,
    pub actions: Vec<EvidenceAction>,
    pub open_questions: Vec<String>,
    /// Calendar display names only, for the greeting.
    pub participant_names: Vec<String>,
}

impl Evidence {
    pub fn is_empty(&self) -> bool {
        self.recap.as_deref().unwrap_or_default().is_empty()
            && self.decisions.is_empty()
            && self.actions.is_empty()
            && self.open_questions.is_empty()
    }
}

/// The evidence for `meeting`: its outcomes with the user's corrections and
/// its saved summary's recap.
pub fn evidence_for(library: &Library, meeting: &Meeting) -> Result<Evidence> {
    let summary = library.summary(meeting)?;
    let projection = library.outcome_projection(meeting)?;
    Ok(match projection {
        Some(projection) => evidence(&projection, summary.as_deref()),
        None => Evidence {
            meeting_title: meeting.display_title(),
            meeting_date: meeting.started_at,
            recap: summary
                .as_deref()
                .and_then(|s| recap(&meeting_body(s, meeting))),
            decisions: Vec::new(),
            actions: Vec::new(),
            open_questions: Vec::new(),
            participant_names: participant_names(meeting),
        },
    })
}

/// `FollowUpDraftGenerator.evidence(for:summary:)`.
pub fn evidence(projection: &OutcomeProjection, summary: Option<&str>) -> Evidence {
    let meeting = &projection.meeting;
    let actions = projection
        .action_references()
        .into_iter()
        .filter(|r| r.status != ActionStatus::Done)
        .map(|r| EvidenceAction {
            owner: if r.is_for_user {
                Some("Me".into())
            } else {
                r.owner.clone()
            },
            due: r.due.as_ref().map(|due| match r.resolved_due_date {
                Some(day) => day.format("%a, %b %-d").to_string(),
                None => due.clone(),
            }),
            text: r.text,
        })
        .collect();
    Evidence {
        meeting_title: meeting.display_title(),
        meeting_date: meeting.started_at,
        recap: summary.and_then(|s| recap(&meeting_body(s, meeting))),
        decisions: projection
            .outcomes
            .decision_records
            .iter()
            .map(|d| d.text.clone())
            .collect(),
        actions,
        open_questions: projection.outcomes.open_questions.clone(),
        participant_names: participant_names(meeting),
    }
}

/// The evidence as prompt text, sanitized and capped at 8,000 characters.
pub fn prompt_context(evidence: &Evidence) -> String {
    let date = evidence
        .meeting_date
        .with_timezone(&Local)
        .format("%B %-d, %Y");
    let mut sections = vec![format!("Meeting: {} on {date}", evidence.meeting_title)];
    if !evidence.participant_names.is_empty() {
        let names: Vec<&str> = evidence
            .participant_names
            .iter()
            .take(MAXIMUM_PARTICIPANTS)
            .map(String::as_str)
            .collect();
        sections.push(format!("Invited participants: {}", names.join(", ")));
    }
    if let Some(recap) = evidence.recap.as_deref().filter(|r| !r.is_empty()) {
        sections.push(format!("Recap:\n{recap}"));
    }
    if !evidence.decisions.is_empty() {
        sections.push(format!("Decisions:\n{}", bullets(&evidence.decisions)));
    }
    if !evidence.actions.is_empty() {
        let lines: Vec<String> = evidence
            .actions
            .iter()
            .map(|action| {
                let mut metadata = Vec::new();
                if let Some(owner) = &action.owner {
                    metadata.push(if owner == "Me" {
                        "owner: the sender".to_string()
                    } else {
                        format!("owner: {owner}")
                    });
                }
                if let Some(due) = &action.due {
                    metadata.push(format!("due: {due}"));
                }
                if metadata.is_empty() {
                    format!("- {}", action.text)
                } else {
                    format!("- {} ({})", action.text, metadata.join(", "))
                }
            })
            .collect();
        sections.push(format!("Open actions:\n{}", lines.join("\n")));
    }
    if !evidence.open_questions.is_empty() {
        sections.push(format!(
            "Open questions:\n{}",
            bullets(&evidence.open_questions)
        ));
    }
    sanitize(&sections.join("\n\n"), Some(MAXIMUM_CONTEXT_CHARACTERS))
}

fn bullets(lines: &[String]) -> String {
    lines
        .iter()
        .map(|l| format!("- {l}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn schema() -> Value {
    json!({
        "type": "object",
        "properties": {"subject": {"type": "string"}, "body": {"type": "string"}},
        "required": ["subject", "body"],
        "additionalProperties": false
    })
}

#[derive(Deserialize)]
struct Draft {
    subject: String,
    body: String,
}

/// Drafts the follow-up email for `meeting`.
pub fn generate(
    think: &ThinkClient,
    library: &Library,
    meeting: &Meeting,
) -> Result<FollowUpDraft> {
    generate_from(think, &evidence_for(library, meeting)?)
}

/// `FollowUpDraftGenerator.generate(evidence:engine:)`.
pub fn generate_from(think: &ThinkClient, evidence: &Evidence) -> Result<FollowUpDraft> {
    if evidence.is_empty() {
        return Err(FollowUpError::EmptyEvidence.into());
    }
    let user = format!(
        "{}\n\nDraft the follow-up email for {}.",
        prompt_context(evidence),
        evidence.meeting_title
    );
    let request = ChatRequest::new(FOLLOW_UP_SYSTEM, user)
        .max_tokens(900)
        .reasoning_budget(256)
        .temperature(0.3)
        .json_schema(schema());
    let output = think.complete(&request)?;
    let visible = strip_reasoning(&output);
    let draft: Draft = extract_json_object(&visible)
        .and_then(|json| serde_json::from_str(json).ok())
        .ok_or(FollowUpError::UnreadableResponse)?;
    let subject = draft.subject.trim().to_string();
    let body = redact(&draft.body).trim().to_string();
    if body.is_empty() {
        return Err(FollowUpError::UnreadableResponse.into());
    }
    Ok(FollowUpDraft {
        subject: if subject.is_empty() {
            format!("Follow-up: {}", evidence.meeting_title)
        } else {
            subject
        },
        body,
    })
}

// ------------------------------------------------------------ presentation

/// The line older merge drafts open with (`SummaryPresentation.meetingBody`).
const MERGE_BOILERPLATE: &str =
    "This is a non-destructive merge. Source evidence remains on disk for provenance,";

/// `SummaryPresentation.meetingBody`: merged meetings show their display
/// title and drop implementation boilerplate.
pub fn meeting_body(markdown: &str, meeting: &Meeting) -> String {
    if !meeting.is_merged_meeting() {
        return markdown.to_string();
    }
    let heading = format!("# {}", meeting.title);
    markdown
        .split('\n')
        .enumerate()
        .filter(|(_, line)| !line.starts_with(MERGE_BOILERPLATE))
        .map(|(index, line)| {
            if index == 0 && (line == heading || line.starts_with(&format!("{heading} — "))) {
                format!("# {}{}", meeting.display_title(), &line[heading.len()..])
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The summary without its provenance line (`SummaryPresentation.split`).
pub fn summary_body(markdown: &str) -> String {
    let mut lines: Vec<&str> = markdown.split('\n').collect();
    for index in 0..lines.len().min(4) {
        let trimmed = lines[index].trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if metadata_pairs(trimmed) >= 2 {
            lines.remove(index);
            return lines.join("\n").trim().to_string();
        }
        break;
    }
    markdown.to_string()
}

/// How many `**Label:** value` pairs joined by " · " make up `line` (0 when
/// any piece is not one).
fn metadata_pairs(line: &str) -> usize {
    let mut count = 0;
    for piece in line.split(" · ") {
        let trimmed = piece.trim();
        let Some(rest) = trimmed.strip_prefix("**") else {
            return 0;
        };
        let Some(end) = rest.find(":**") else {
            return 0;
        };
        let label = rest[..end].trim();
        let value = rest[end + 3..].trim();
        if label.is_empty() || value.is_empty() {
            return 0;
        }
        count += 1;
    }
    count
}

/// The reading preview of a summary (`SummaryPresentation.recap`): its
/// TL;DR section, else its first prose paragraph, without speaker labels or
/// playback stamps.
pub fn recap(markdown: &str) -> Option<String> {
    let body = summary_body(markdown);
    let lines: Vec<&str> = body.split('\n').collect();
    if let Some(heading) = lines
        .iter()
        .position(|l| l.trim().to_lowercase() == "## tl;dr")
    {
        let section = lines[heading + 1..]
            .iter()
            .take_while(|l| !l.trim().starts_with('#'))
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        let section = section.trim();
        if !section.is_empty() && section.to_lowercase() != "none" {
            return recap_text(section);
        }
    }
    body.split("\n\n").find_map(|paragraph| {
        let content = paragraph
            .split('\n')
            .filter(|l| !l.trim().starts_with('#'))
            .collect::<Vec<_>>()
            .join("\n");
        let content = content.trim();
        if content.is_empty()
            || content.to_lowercase() == "none"
            || content.starts_with("- ")
            || content.starts_with("* ")
            || content.starts_with('|')
        {
            return None;
        }
        recap_text(content)
    })
}

fn recap_text(section: &str) -> Option<String> {
    static BULLET: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"^\s*[-*•]\s+(?:\*\*[^*\n]+:\*\*\s*)?").unwrap()
    });
    static STAMP: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"\s*[—–-]\s*\[\d{1,2}:\d{2}(?::\d{2})?\]\s*$").unwrap()
    });
    let text = section
        .split('\n')
        .map(|line| {
            let line = BULLET.replace(line, "• ");
            STAMP.replace(&line, "").into_owned()
        })
        .collect::<Vec<_>>()
        .join("\n");
    let text = text.trim();
    (!text.is_empty()).then(|| text.to_string())
}

/// Calendar attendee names (`resolvedCalendarParticipantIdentities`),
/// deduplicated by email, else by folded name; legacy name hints when the
/// meeting has no structured attendees.
pub fn participant_names(meeting: &Meeting) -> Vec<String> {
    struct Identity {
        name: Option<String>,
        email: Option<String>,
    }
    let structured: Vec<Identity> = meeting
        .calendar_participant_identities
        .iter()
        .flatten()
        .filter_map(|i| {
            let name = i.name.as_deref().and_then(display_name);
            let email = i.email_address.as_deref().and_then(email_address);
            (name.is_some() || email.is_some()).then_some(Identity { name, email })
        })
        .collect();
    let inputs: Vec<Identity> = if structured.is_empty() {
        meeting
            .participant_name_hints
            .iter()
            .flatten()
            .filter_map(|n| display_name(n))
            .map(|name| Identity {
                name: Some(name),
                email: None,
            })
            .collect()
    } else {
        structured
    };
    let key = |name: &str| lokalbot_core::ids::fold(name);
    let mut result: Vec<Identity> = Vec::new();
    for identity in inputs {
        if let Some(email) = &identity.email
            && let Some(existing) = result.iter_mut().find(|r| r.email.as_ref() == Some(email))
        {
            if existing.name.is_none() {
                existing.name = identity.name;
            }
            continue;
        }
        if let Some(name_key) = identity.name.as_deref().map(key) {
            let matching: Vec<usize> = (0..result.len())
                .filter(|&i| {
                    result[i].name.as_deref().map(key).as_deref() == Some(name_key.as_str())
                })
                .collect();
            if identity.email.is_some()
                && let Some(&index) = matching.iter().find(|&&i| result[i].email.is_none())
            {
                result[index].email = identity.email;
                continue;
            }
            if identity.email.is_none() && matching.len() == 1 {
                continue;
            }
        }
        result.push(identity);
    }
    let mut seen = HashSet::new();
    result
        .into_iter()
        .filter_map(|i| i.name)
        .filter(|n| seen.insert(n.clone()) || true)
        .collect()
}

/// `CalendarParticipantIdentity.normalizedDisplayName`.
fn display_name(raw: &str) -> Option<String> {
    static ROLE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"(?i)\s*\((host|co-host|organizer|presenter|you|me)\)\s*").unwrap()
    });
    let collapsed = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    let name = ROLE
        .replace_all(&collapsed, " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let count = name.chars().count();
    ((2..=80).contains(&count)
        && name.chars().any(char::is_alphabetic)
        && !name.contains('@')
        && !name.to_lowercase().contains("http"))
    .then_some(name)
}

/// `CalendarParticipantIdentity.normalizedEmailAddress`.
fn email_address(raw: &str) -> Option<String> {
    let email = raw.trim().to_lowercase();
    let count = email.chars().count();
    if !(3..=254).contains(&count) || email.contains(char::is_whitespace) {
        return None;
    }
    let parts: Vec<&str> = email.split('@').collect();
    (parts.len() == 2 && !parts[0].is_empty() && !parts[1].is_empty()).then_some(email)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{Reply, StubServer};

    fn chat(content: &str) -> Reply {
        Reply::Json(
            200,
            json!({"choices": [{"message": {"content": content}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 10}}),
        )
    }

    #[test]
    fn recap_prefers_the_tldr_without_labels_or_stamps() {
        let summary = "# Sync — October 17, 2026 at 9:00 AM\n**Duration:** 30 min · **App:** Zoom\n\n## TL;DR\n- **Maya Chen:** Ship on Friday. — [00:01:36]\n- Budget approved.\n\n## Key points\n- Other";
        assert_eq!(
            recap(summary).as_deref(),
            Some("• Ship on Friday.\n• Budget approved.")
        );
        let prose =
            "# Title\n**Duration:** 1 min · **App:** Zoom\n\nWe agreed to ship.\n\n- a bullet";
        assert_eq!(recap(prose).as_deref(), Some("We agreed to ship."));
        assert_eq!(
            recap("## TL;DR\nNone\n\n## Key points\n- only bullets"),
            None
        );
    }

    #[test]
    fn drafts_from_the_fixture_meeting() {
        let Some((_dir, library)) = crate::test_support::fixture_library() else {
            return;
        };
        let meeting = library
            .list_meetings()
            .unwrap()
            .into_iter()
            .find(|m| m.title == "Customer call - Northwind")
            .unwrap();
        let evidence = evidence_for(&library, &meeting).unwrap();
        assert!(!evidence.is_empty());
        let context = prompt_context(&evidence);
        assert!(
            context.starts_with("Meeting: Customer call - Northwind on "),
            "{context}"
        );
        let seen = std::sync::Arc::new(parking_lot::Mutex::new(Value::Null));
        let sent = seen.clone();
        let server = StubServer::start(move |request| {
            *sent.lock() = request.json();
            chat(
                r#"{"subject": "", "body": "Hi all,\n\nThanks for the call. My key is sk-abcdefghijklmnop1234.\n- I will send the security overview."}"#,
            )
        });
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let draft = generate_from(&think, &evidence).unwrap();
        assert_eq!(draft.subject, "Follow-up: Customer call - Northwind");
        assert!(
            draft.body.contains("[REDACTED_KEY]") && !draft.body.contains("sk-abc"),
            "{}",
            draft.body
        );
        let body = seen.lock().clone();
        let user = body["messages"][1]["content"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        assert!(
            user.ends_with("Draft the follow-up email for Customer call - Northwind."),
            "{user}"
        );
        assert_eq!(body["max_tokens"], 900);
        assert_eq!(body["response_format"]["type"], "json_schema");
    }

    #[test]
    fn empty_and_unreadable_outputs_are_errors() {
        let empty = Evidence {
            meeting_title: "Sync".into(),
            meeting_date: Utc::now(),
            recap: None,
            decisions: vec![],
            actions: vec![],
            open_questions: vec![],
            participant_names: vec![],
        };
        let think = ThinkClient::llama_server("http://127.0.0.1:9/v1", "t", "m");
        let err = generate_from(&think, &empty).unwrap_err();
        assert_eq!(
            err.to_string(),
            "This meeting has no recap or outcomes to follow up on yet."
        );
        let server = StubServer::start(|_| chat("Sure! Here is a draft."));
        let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
        let evidence = Evidence {
            decisions: vec!["Ship Friday".into()],
            ..empty
        };
        let err = generate_from(&think, &evidence).unwrap_err();
        assert_eq!(
            err.to_string(),
            "The local model returned an unreadable draft. The outline is unchanged."
        );
    }

    #[test]
    fn participant_names_are_cleaned_and_deduplicated() {
        assert_eq!(
            display_name("  Maya   Chen (Host) "),
            Some("Maya Chen".into())
        );
        assert_eq!(display_name("maya@example.com"), None);
        assert_eq!(
            email_address(" Maya@Example.com "),
            Some("maya@example.com".into())
        );
    }
}
