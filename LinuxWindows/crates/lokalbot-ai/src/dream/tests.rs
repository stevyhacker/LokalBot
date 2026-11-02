use chrono::{Duration, TimeZone as _, Utc};
use serde_json::json;

use super::*;
use crate::http::testing::{Reply, StubServer};
use lokalbot_core::{Library, LibraryPaths};

/// Answers each model request with the next reply.
fn fake_server(replies: Vec<String>) -> StubServer {
    let queue = parking_lot::Mutex::new(std::collections::VecDeque::from(replies));
    StubServer::start(move |_| {
        let reply = queue.lock().pop_front().unwrap_or_default();
        Reply::Json(
            200,
            json!({"choices": [{"message": {"content": reply}, "finish_reason": "stop"}],
                   "usage": {"completion_tokens": 10}}),
        )
    })
}

fn think_for(server: &StubServer) -> ThinkClient {
    ThinkClient::llama_server(&server.url("/v1"), "token", "test-model")
}

fn library() -> (tempfile::TempDir, Library) {
    let dir = tempfile::tempdir().unwrap();
    let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
    (dir, library)
}

fn yesterday() -> NaiveDate {
    local_day(Utc::now()) - Duration::days(1)
}

/// A finished meeting yesterday with outcomes and a summary.
fn seed_meeting(library: &Library, day: NaiveDate) -> Meeting {
    let (start, _) = local_day_bounds(day);
    let at = start + Duration::hours(10);
    let mut meeting = library.create_meeting("Design review", "Zoom", at).unwrap();
    meeting.ended_at = Some(at + Duration::minutes(30));
    library.save_meeting(&meeting).unwrap();
    let outcomes = json!({
        "schemaVersion": 1,
        "actionItems": [
            {"id": "a1", "text": "Send the deck", "owner": "Me", "due": "Friday", "isForUser": true},
            {"id": "a2", "text": "Book the room", "owner": "Maya", "isForUser": false}
        ],
        "decisionRecords": [{"id": "d1", "text": "Use Redis"}],
        "openQuestions": ["Who owns the rollout?"]
    });
    std::fs::write(
        library.meeting_dir(&meeting).join("outcomes.json"),
        outcomes.to_string(),
    )
    .unwrap();
    meeting
}

const REPLY: &str = r#"{
  "narrative": "The review moved the beta forward.",
  "attention": ["Rollout owner is open `abcdef12`", "  "],
  "repeated_work": [],
  "suggested_checks": [],
  "frictions": [],
  "top_actions": ["[A1] Send the deck", "[A99] Something unknown"],
  "active_projects": [{"name": "Beta", "status": "moving", "active_today": true, "evidence": ["Used Redis"]}],
  "work_goals": [{"text": "Ship the beta", "horizon": "this month", "reinforced_today": true, "expired": false}],
  "recurring_patterns": ["Reviews slip by a day"]
}"#;

#[test]
fn parse_is_tolerant_of_wrapping_and_strict_about_memory() {
    let wrapped = format!("<think>x</think>Here it is:\n```json\n{REPLY}\n```");
    let synthesis = parse(&wrapped).unwrap();
    assert_eq!(synthesis.attention.len(), 1, "a blank bullet is dropped");
    assert_eq!(synthesis.memory.active_projects[0].active_today, Some(true));
    assert_eq!(synthesis.memory.work_goals[0].text, "Ship the beta");

    // A blank memory string would replace a stored entry: the whole reply is bad.
    let bad = REPLY.replace("\"status\": \"moving\"", "\"status\": \"  \"");
    assert!(parse(&bad).is_none());
    // Every declared field must be there.
    assert!(parse(r#"{"narrative":"x"}"#).is_none());
    assert!(parse("no json at all").is_none());
}

#[test]
fn top_actions_link_to_their_threads_without_inventing() {
    let ids = vec!["thread-1".to_string(), "thread-2".to_string()];
    let (texts, links) = link_top_actions(
        &[
            "[A2] Send the deck".to_string(),
            "[A2]: Duplicate".to_string(),
            "[A9] Unknown".to_string(),
            "Plain advice".to_string(),
        ],
        &ids,
    );
    assert_eq!(
        texts,
        vec!["Send the deck", "Duplicate", "Unknown", "Plain advice"]
    );
    assert_eq!(links, vec![Some("thread-2".to_string()), None, None, None]);
}

#[test]
fn the_system_prompt_matches_the_macs_rules() {
    assert!(prompts::DREAM_SYSTEM.starts_with("You are LokalBot's overnight \"dreaming\" pass:"));
    assert!(prompts::DREAM_SYSTEM.contains("prefix inferred items with \"Likely:\""));
    assert!(prompts::DREAM_SYSTEM.ends_with("generic advice is worse than an empty list."));
    let required = schema()["properties"]["work_goals"]["items"]["required"].clone();
    assert_eq!(
        required,
        json!(["text", "horizon", "reinforced_today", "expired"])
    );
}

#[test]
fn a_journals_log_is_cut_so_the_rest_of_the_pack_fits() {
    let head = "# Day\n\nWork happened.";
    let journal = format!("{head}\n## Full activity log\n{}", "x".repeat(50_000));
    let cut = digest_for_dream(&journal);
    assert!(cut.starts_with(head));
    assert!(cut.ends_with("…(activity log truncated)"));
    assert!(cut.chars().count() <= DIGEST_CHARACTER_LIMIT);
    assert_eq!(digest_for_dream(head), head);
    let long = "y".repeat(20_000);
    assert!(digest_for_dream(&long).ends_with('…'));
}

#[test]
fn compile_reads_the_day_and_a_bounded_window() {
    let (_dir, library) = library();
    let day = yesterday();
    let meeting = seed_meeting(&library, day);
    seed_meeting(&library, day - Duration::days(3));
    seed_meeting(&library, day - Duration::days(30));
    let evidence = compile(&library, day).unwrap();
    assert_eq!(evidence.meetings.len(), 1);
    assert_eq!(evidence.meetings[0].short_id, meeting.short_id());
    assert_eq!(evidence.prior_meetings.len(), 1);
    assert_eq!(
        evidence
            .sources
            .iter()
            .filter(|s| s.kind == "meeting")
            .count(),
        2
    );
    assert!(evidence.sources.iter().any(|s| s.kind == "screenDay"));
    assert!(evidence.sources.iter().any(|s| s.kind == "digest"));
    assert!(!evidence.open_actions.is_empty());
    assert!(evidence.open_actions[0].starts_with("- [ ] [A1] "));
    let pack = evidence_pack(&evidence);
    assert!(pack.contains("Design review"));
    assert!(pack.contains("decision: Use Redis"));
    assert!(pack.contains("open question: Who owns the rollout?"));
    assert!(pack.contains("comparison window only"));
    assert!(!evidence.is_substantively_empty());
}

#[test]
fn an_empty_day_writes_a_stub_without_waking_a_model() {
    let (_dir, library) = library();
    let day = yesterday();
    let report = dream(
        &library,
        &DreamRequest {
            day,
            is_automatic: true,
            transient_failures: 0,
            make_engine: &|| panic!("no model call on an empty day"),
            cancelled: &|| false,
        },
    )
    .unwrap();
    assert_eq!(report.fallback_reason, Some(FallbackReason::EmptyDay));
    let store = DreamStore::new(library.paths().root());
    assert!(store.has_report(&day_key(day)));
    // Empty-day stubs mark the day but are never shown.
    assert!(today_report(&library, day + Duration::days(1)).is_none());
}

fn request<'a>(
    day: NaiveDate,
    make_engine: &'a dyn Fn() -> Result<(ThinkClient, InferenceProvenance)>,
) -> DreamRequest<'a> {
    DreamRequest {
        day,
        is_automatic: true,
        transient_failures: 0,
        make_engine,
        cancelled: &|| false,
    }
}

#[test]
fn a_model_reply_becomes_a_report_and_merged_memory() {
    let (_dir, library) = library();
    let day = yesterday();
    seed_meeting(&library, day);
    let server = fake_server(vec![REPLY.to_string()]);
    let make = || Ok((think_for(&server), InferenceProvenance::local()));
    let report = dream(&library, &request(day, &make)).unwrap();
    assert_eq!(report.narrative, "The review moved the beta forward.");
    assert!(report.engine_name.is_some());
    assert_eq!(report.top_actions[0], "Send the deck");
    assert!(report.top_action_thread_id(0).is_some());
    assert_eq!(report.top_action_thread_id(1), None);

    let store = DreamStore::new(library.paths().root());
    let memory = store.load_memory().unwrap().unwrap();
    assert_eq!(memory.active_projects[0].name, "Beta");
    assert_eq!(
        memory.last_dream_day.as_deref(),
        Some(day_key(day).as_str())
    );
    assert!(memory.active_projects[0].provenance.is_some());
    // Readers that were written against the Mac's file still read it.
    let bytes = lokalbot_core::evidence::read_work_memory(library.paths().root()).unwrap();
    let context = crate::selection::work_memory_context(&bytes, true);
    assert!(context.contains("**Beta**"), "{context}");
    assert_eq!(
        today_report(&library, day + Duration::days(1)).unwrap().day,
        day_key(day)
    );
}

#[test]
fn an_older_day_never_replays_over_newer_memory() {
    let (_dir, library) = library();
    let day = yesterday();
    seed_meeting(&library, day);
    seed_meeting(&library, day - Duration::days(2));
    let server = fake_server(vec![REPLY.to_string(), REPLY.replace("Beta", "Older")]);
    let make = || Ok((think_for(&server), InferenceProvenance::local()));
    dream(&library, &request(day, &make)).unwrap();
    dream(&library, &request(day - Duration::days(2), &make)).unwrap();
    let store = DreamStore::new(library.paths().root());
    let memory = store.load_memory().unwrap().unwrap();
    assert_eq!(memory.active_projects.len(), 1);
    assert_eq!(memory.active_projects[0].name, "Beta");
    assert!(store.has_report(&day_key(day - Duration::days(2))));
}

#[test]
fn an_unreadable_reply_or_no_model_leaves_an_evidence_only_brief_and_memory_alone() {
    let (_dir, library) = library();
    let day = yesterday();
    seed_meeting(&library, day);
    let server = fake_server(vec!["not json".to_string()]);
    let make = || Ok((think_for(&server), InferenceProvenance::local()));
    let report = dream(&library, &request(day, &make)).unwrap();
    assert_eq!(
        report.fallback_reason,
        Some(FallbackReason::UnparseableResponse)
    );
    assert!(report.engine_name.is_none());
    assert!(report.narrative.contains("1 recorded meeting"));
    assert!(report.attention[0].starts_with("Who owns the rollout?"));
    assert_eq!(report.top_actions.len(), 1);
    assert!(report.top_action_thread_id(0).is_some());
    let store = DreamStore::new(library.paths().root());
    assert!(store.load_memory().unwrap().unwrap().is_empty());

    let make_none = || -> Result<(ThinkClient, InferenceProvenance)> {
        Err(AiError::ConsentRequired("Not approved".into()).into())
    };
    let report = dream(&library, &request(day, &make_none)).unwrap();
    assert_eq!(
        report.fallback_reason,
        Some(FallbackReason::EngineUnavailable)
    );
    assert!(is_retryable_failure(&report, day + Duration::days(1)));
}

#[test]
fn a_rate_limit_defers_an_automatic_run_and_then_gives_up() {
    let (_dir, library) = library();
    let day = yesterday();
    seed_meeting(&library, day);
    let make = || -> Result<(ThinkClient, InferenceProvenance)> {
        Err(AiError::HttpStatus {
            code: 429,
            detail: "slow down".into(),
            retry_after: None,
        }
        .into())
    };
    let store = DreamStore::new(library.paths().root());
    assert!(matches!(
        dream(&library, &request(day, &make)),
        Err(DreamError::Deferred(_))
    ));
    assert!(!store.has_report(&day_key(day)));
    let last = DreamRequest {
        transient_failures: TRANSIENT_ATTEMPTS_BEFORE_FALLBACK - 1,
        ..request(day, &make)
    };
    assert_eq!(
        dream(&library, &last).unwrap().fallback_reason,
        Some(FallbackReason::EngineUnavailable)
    );
    // "Review now" doesn't wait for a retry either.
    let manual = DreamRequest {
        is_automatic: false,
        ..request(day - Duration::days(1), &make)
    };
    assert!(dream(&library, &manual).is_ok());
}

#[test]
fn a_source_changing_mid_run_discards_the_review() {
    let (_dir, library) = library();
    let day = yesterday();
    let meeting = seed_meeting(&library, day);
    let server = fake_server(vec![REPLY.to_string()]);
    let root = library.paths().root().to_path_buf();
    let make = || {
        lokalbot_core::evidence::with_meeting_mutation(&root, &[&meeting], || Ok(())).unwrap();
        Ok((think_for(&server), InferenceProvenance::local()))
    };
    assert!(matches!(
        dream(&library, &request(day, &make)),
        Err(DreamError::Cancelled)
    ));
    assert!(!DreamStore::new(library.paths().root()).has_report(&day_key(day)));
}

#[test]
fn reports_and_memory_are_scrubbed_before_saving() {
    let (_dir, library) = library();
    let day = yesterday();
    seed_meeting(&library, day);
    let reply = REPLY
        .replace("moved the beta forward", "used sk-abcdefghijklmnopqrstuvwx")
        .replace("Reviews slip by a day", "AKIAABCDEFGHIJKLMNOP leaks");
    let server = fake_server(vec![reply]);
    let make = || Ok((think_for(&server), InferenceProvenance::local()));
    let report = dream(&library, &request(day, &make)).unwrap();
    assert!(report.narrative.contains("[REDACTED_KEY]"));
    let saved = std::fs::read_to_string(library.paths().root().join("memory/memory.json")).unwrap();
    assert!(!saved.contains("AKIAABCDEFGHIJKLMNOP"));
}

#[test]
fn today_prefers_yesterday_and_looks_back_only_five_days() {
    let (_dir, library) = library();
    let today = Utc
        .with_ymd_and_hms(2026, 10, 20, 12, 0, 0)
        .unwrap()
        .date_naive();
    let store = DreamStore::new(library.paths().root());
    let save = |days_back: i64, reason: Option<FallbackReason>| {
        let mut report = DreamReport::new(
            day_key(today - Duration::days(days_back)),
            Utc::now(),
            "A day.".into(),
        );
        report.fallback_reason = reason;
        store.save_report(&report).unwrap();
    };
    save(6, None);
    assert!(today_report(&library, today).is_none());
    save(3, None);
    assert_eq!(today_report(&library, today).unwrap().day, "2026-10-17");
    save(1, Some(FallbackReason::EmptyDay));
    assert_eq!(today_report(&library, today).unwrap().day, "2026-10-17");
    save(1, None);
    assert_eq!(today_report(&library, today).unwrap().day, "2026-10-19");
}
