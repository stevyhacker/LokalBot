//! Ported from `UpcomingMeetingPreparationTests.swift`.

use chrono::TimeZone as _;
use lokalbot_core::model::{ActionItem, CalendarParticipantIdentity, Decision, MeetingOutcomes};
use lokalbot_core::{ActionCorrection, LibraryPaths};
use serde_json::Value;

use super::*;
use crate::http::testing::{Reply, StubServer};

fn now() -> DateTime<Utc> {
    Utc.timestamp_opt(2_000_000_000, 0).unwrap()
}

fn event(
    id: &str,
    title: &str,
    starts_in: i64,
    duration: i64,
    participants: &[&str],
) -> CalendarEvent {
    let start = now() + chrono::Duration::seconds(starts_in);
    CalendarEvent {
        provider: "test".into(),
        external_id: id.into(),
        title: title.into(),
        start,
        end: start + chrono::Duration::seconds(duration),
        meeting_url: Some("https://meet.google.com/abc-defg-hij".into()),
        source_calendar_title: Some("Work".into()),
        participant_names: participants.iter().map(|p| p.to_string()).collect(),
        participant_identities: Vec::new(),
        agenda: None,
    }
}

fn library() -> (tempfile::TempDir, Library) {
    let dir = tempfile::tempdir().unwrap();
    let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
    (dir, library)
}

fn meeting(
    library: &Library,
    title: &str,
    calendar_title: Option<&str>,
    days_ago: i64,
    participants: &[&str],
    summary: &str,
    outcomes: MeetingOutcomes,
) -> Meeting {
    let started = now() - chrono::Duration::days(days_ago);
    let mut meeting = library.create_meeting(title, "Zoom", started).unwrap();
    meeting.ended_at = Some(started + chrono::Duration::seconds(1_800));
    meeting.calendar_title = calendar_title.map(str::to_string);
    meeting.participant_name_hints = Some(participants.iter().map(|p| p.to_string()).collect());
    library.save_meeting(&meeting).unwrap();
    library.save_summary(&meeting, summary).unwrap();
    library.save_outcomes(&meeting, &outcomes).unwrap();
    meeting
}

fn action(text: &str, due: &str) -> ActionItem {
    ActionItem::new(text, Some("Me"), Some(due), None, 3, Vec::new(), None)
}

fn outcomes(actions: Vec<ActionItem>, decisions: &[&str]) -> MeetingOutcomes {
    MeetingOutcomes {
        action_items: actions,
        decision_records: decisions
            .iter()
            .map(|d| Decision::new(d, Vec::new()))
            .collect(),
        ..Default::default()
    }
}

fn write_memory(library: &Library, projects: Value) {
    let folder = library.paths().root().join("memory");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(
        folder.join("memory.json"),
        serde_json::to_vec(&serde_json::json!({"activeProjects": projects})).unwrap(),
    )
    .unwrap();
}

fn empty_evidence(event: CalendarEvent) -> UpcomingEvidence {
    UpcomingEvidence {
        event,
        related_meetings: Vec::new(),
        decisions: Vec::new(),
        commitments: Vec::new(),
        projects: Vec::new(),
        agenda: None,
    }
}

#[test]
fn signature_changes_when_calendar_evidence_changes() {
    let first = event("series", "Atlas review", 600, 1_800, &["Ana"]);
    let mut revised = first.clone();
    revised.title = "Atlas launch review".into();
    revised.participant_names = vec!["Ana".into(), "Marko".into()];
    assert_ne!(
        empty_evidence(first).signature(),
        empty_evidence(revised).signature()
    );
}

#[test]
fn compiler_uses_participant_history_outcomes_and_project_memory() {
    let (_dir, library) = library();
    let related = meeting(
        &library,
        "Launch checkpoint",
        None,
        7,
        &["Ana Petrović"],
        "Ana reviewed the Atlas launch. The team kept the staged rollout.",
        outcomes(
            vec![action("Send the rollout checklist", "Friday")],
            &["Keep the Atlas rollout staged."],
        ),
    );
    meeting(
        &library,
        "Unrelated finance call",
        None,
        1,
        &["Marko"],
        "Quarterly budget review.",
        outcomes(Vec::new(), &["Freeze travel spend."]),
    );
    write_memory(
        &library,
        serde_json::json!([{
            "name": "Atlas",
            "status": "Staged launch awaiting the final checklist",
            "lastActiveDay": "2033-05-17",
            "evidence": []
        }]),
    );
    let upcoming = event(
        "atlas-review",
        "Atlas launch review",
        1_200,
        1_800,
        &["Ana Petrovic"],
    );

    let evidence = compile(&upcoming, &library, now(), false);

    let ids: Vec<Uuid> = evidence
        .related_meetings
        .iter()
        .map(|m| m.meeting_id)
        .collect();
    assert_eq!(ids, [related.id]);
    let decisions: Vec<&str> = evidence.decisions.iter().map(|d| d.text.as_str()).collect();
    assert_eq!(decisions, ["Keep the Atlas rollout staged."]);
    let commitments: Vec<&str> = evidence
        .commitments
        .iter()
        .map(|c| c.text.as_str())
        .collect();
    assert_eq!(commitments, ["Send the rollout checklist"]);
    assert_eq!(evidence.commitments[0].owner.as_deref(), Some("Me"));
    assert!(evidence.commitments[0].is_for_user);
    let projects: Vec<&str> = evidence.projects.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(projects, ["Atlas"]);
    let brief = evidence.fallback_brief();
    assert!(brief.contains("Keep the Atlas rollout staged"), "{brief}");
    assert!(brief.contains("Owner: You."), "{brief}");
    assert!(
        evidence
            .prompt_context()
            .contains("using saved corrections and status")
    );
}

#[test]
fn compiler_deduplicates_commitments_and_keeps_latest_correction() {
    let (_dir, library) = library();
    meeting(
        &library,
        "Atlas planning",
        None,
        7,
        &["Ana"],
        "Reviewed the Atlas proposal.",
        outcomes(
            vec![action("I will send the revised launch proposal", "Friday")],
            &[],
        ),
    );
    let later = action("Send the revised launch proposal", "Monday");
    let later_id = later.id.clone();
    let latest = meeting(
        &library,
        "Atlas review",
        None,
        2,
        &["Ana"],
        "Reviewed the revised Atlas proposal.",
        outcomes(vec![later], &[]),
    );
    library
        .correct_action(
            &latest,
            &later_id,
            ActionCorrection {
                text: Some("Send Acme the revised launch proposal".into()),
                due: Some(Some("Tuesday".into())),
                ..Default::default()
            },
        )
        .unwrap();

    let evidence = compile(
        &event("atlas", "Atlas launch review", 900, 1_800, &["Ana"]),
        &library,
        now(),
        false,
    );

    assert_eq!(evidence.commitments.len(), 1, "{:?}", evidence.commitments);
    assert_eq!(
        evidence.commitments[0].text,
        "Send Acme the revised launch proposal"
    );
    assert_eq!(evidence.commitments[0].due.as_deref(), Some("Tuesday"));
    assert_eq!(evidence.commitments[0].source_meeting_count, 2);
}

#[test]
fn compiler_falls_back_to_recurring_calendar_title_without_participants() {
    let (_dir, library) = library();
    let prior = meeting(
        &library,
        "Browser meeting",
        Some("Weekly Product Sync"),
        14,
        &[],
        "Reviewed onboarding activation.",
        outcomes(Vec::new(), &["Keep onboarding as the first milestone."]),
    );
    let evidence = compile(
        &event("series", "Weekly Product Sync", 900, 1_800, &[]),
        &library,
        now(),
        false,
    );
    assert_eq!(evidence.related_meetings[0].meeting_id, prior.id);
    assert_eq!(
        evidence.decisions[0].text,
        "Keep onboarding as the first milestone."
    );
}

#[test]
fn compiler_does_not_pull_unrelated_recent_work() {
    let (_dir, library) = library();
    meeting(
        &library,
        "Finance review",
        None,
        1,
        &["Marko"],
        "Reviewed the annual budget.",
        outcomes(Vec::new(), &["Reduce travel spend."]),
    );
    let evidence = compile(
        &event("design", "Design critique", 900, 1_800, &["Ana"]),
        &library,
        now(),
        false,
    );
    assert!(!evidence.has_preparation_context());
    assert!(evidence.related_meetings.is_empty());
    assert_eq!(
        evidence.fallback_brief(),
        "No related decisions or commitments were found in LokalBot yet."
    );
}

#[test]
fn compiler_matches_structured_attendees_and_keeps_the_agenda_only_when_asked() {
    let (_dir, library) = library();
    let started = now() - chrono::Duration::days(3);
    let mut prior = library
        .create_meeting("Customer call", "Zoom", started)
        .unwrap();
    prior.ended_at = Some(started + chrono::Duration::seconds(600));
    prior.calendar_participant_identities = Some(vec![
        CalendarParticipantIdentity::new("x", Some("Jordan Lee"), Some("jordan@example.com"))
            .unwrap(),
    ]);
    library.save_meeting(&prior).unwrap();
    let mut upcoming = event("next", "Renewal", 600, 1_800, &["Jordan Lee"]);
    upcoming.agenda = Some("Renewal terms\nPricing questions".into());

    let without = compile(&upcoming, &library, now(), false);
    assert_eq!(without.related_meetings.len(), 1);
    assert_eq!(without.related_meetings[0].participant_matches, 1);
    assert_eq!(without.agenda, None);
    let with = compile(&upcoming, &library, now(), true);
    assert_eq!(
        with.agenda.as_deref(),
        Some("Renewal terms\nPricing questions")
    );
    assert_ne!(with.signature(), without.signature());
}

fn reference(
    kind: ReferenceKind,
    text: String,
    meeting: &RelatedMeeting,
    index: usize,
) -> UpcomingReference {
    UpcomingReference {
        id: format!("{}-{index}", meeting.meeting_id),
        kind,
        text,
        meeting_id: meeting.meeting_id,
        meeting_title: meeting.title.clone(),
        meeting_date: meeting.started_at,
        owner: (kind == ReferenceKind::Commitment).then(|| "Me".to_string()),
        is_for_user: kind == ReferenceKind::Commitment,
        due: (kind == ReferenceKind::Commitment).then(|| "Friday".to_string()),
        source_meeting_count: 1,
    }
}

fn prior(index: i64, summary: &str) -> RelatedMeeting {
    RelatedMeeting {
        meeting_id: Uuid::new_v4(),
        title: format!("Atlas sync {index}"),
        started_at: now() - chrono::Duration::days(index + 1),
        summary: summary.to_string(),
        participant_matches: 1,
        relevance_score: 100,
    }
}

#[test]
fn generator_returns_bounded_structured_brief() {
    let server = StubServer::start(|request| match request.path.as_str() {
        "/v1/chat/completions" => Reply::Json(
            200,
            serde_json::json!({"choices": [{"message": {"role": "assistant", "content": "{\"brief\":\"The staged rollout is still the key decision. Confirm the review status before expanding access.\"}"}, "finish_reason": "stop"}]}),
        ),
        "/tokenize" => Reply::Json(200, serde_json::json!({"tokens": [1, 2, 3]})),
        "/props" => Reply::Json(
            200,
            serde_json::json!({"default_generation_settings": {"n_ctx": 8192}}),
        ),
        _ => Reply::Text(404, "nope".into()),
    });
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "qwen3.5-4b");
    let related = prior(0, "The staged rollout remains in review.");
    let mut evidence = empty_evidence(event("next", "Atlas review", 600, 1_800, &[]));
    evidence.decisions = vec![reference(
        ReferenceKind::Decision,
        "Keep the rollout staged.".into(),
        &related,
        0,
    )];
    evidence.related_meetings = vec![related];

    let brief = generate_brief(&think, &evidence).unwrap();

    assert_eq!(
        brief,
        "The staged rollout is still the key decision. Confirm the review status before expanding access."
    );
    assert!(brief.chars().count() <= 700);
    let sent = server.last_json("/v1/chat/completions");
    let user = sent["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|m| m["role"] == "user")
        .unwrap()["content"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(user.contains("Prior decisions:\n- Keep the rollout staged."));
    assert!(user.ends_with("Prepare me for Atlas review."));
}

#[test]
fn long_prior_summaries_leave_room_for_decisions_commitments_and_projects() {
    let summary: String = "The staged rollout stays in review this week. "
        .repeat(40)
        .chars()
        .take(1_600)
        .collect();
    let detail =
        " The owners confirmed the region list, the rollback plan, and the dashboard thresholds.";
    let priors: Vec<RelatedMeeting> = (0..6).map(|i| prior(i, &summary)).collect();
    let mut evidence = empty_evidence(event("next", "Atlas review", 600, 1_800, &[]));
    for index in 0..5 {
        evidence.decisions.push(reference(
            ReferenceKind::Decision,
            format!("Decision {index}: keep region {index} staged.{detail}"),
            &priors[0],
            index,
        ));
        evidence.commitments.push(reference(
            ReferenceKind::Commitment,
            format!("Commitment {index}: send the region {index} report.{detail}"),
            &priors[1],
            index,
        ));
    }
    evidence.projects = (0..3)
        .map(|i| UpcomingProject {
            name: format!("Project {i}"),
            status: format!("Rollout in review.{detail}"),
            last_active_day: "2033-05-17".into(),
        })
        .collect();
    evidence.agenda = Some("Review the rollout. ".repeat(60));
    evidence.related_meetings = priors.clone();

    let context = evidence.prompt_context();

    assert!(context.chars().count() <= PROMPT_CONTEXT_CHARACTERS);
    for index in 0..5 {
        assert!(
            context.contains(&format!("Decision {index}:")),
            "decision {index} was cut"
        );
        assert!(
            context.contains(&format!("Commitment {index}:")),
            "commitment {index} was cut"
        );
    }
    assert!(context.contains("Project 2:"), "project context was cut");
    for prior in &priors {
        assert!(context.contains(&prior.title), "{}", prior.title);
    }
}

#[test]
fn remote_main_llm_is_never_eligible_for_pre_meeting_generation() {
    let remote = ThinkClient::openai_compatible(
        "https://api.example.com/v1",
        "model",
        None,
        &["https://api.example.com".to_string()],
    )
    .unwrap();
    assert!(!remote.is_local());
    let mut evidence = empty_evidence(event("next", "Atlas review", 600, 1_800, &[]));
    evidence.agenda = Some("Renewal terms".into());
    let error = generate_brief(&remote, &evidence).unwrap_err().to_string();
    assert!(error.contains("on-device"), "{error}");
    let local = ThinkClient::openai_compatible(
        "http://127.0.0.1:1234/v1",
        "model",
        None,
        &["http://127.0.0.1:1234".to_string()],
    )
    .unwrap();
    assert!(local.is_local());
}
