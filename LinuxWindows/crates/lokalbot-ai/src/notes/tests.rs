use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::json;

use lokalbot_core::model::Segment;

use super::*;
use crate::http::testing::{Reply, StubRequest, StubServer};

pub(crate) fn northwind_meeting() -> (Meeting, Transcript) {
    let meeting: Meeting = serde_json::from_value(json!({
        "id": "44444444-4444-4444-8444-444444444444",
        "title": "Customer call - Northwind",
        "appName": "Microsoft Teams",
        "startedAt": "2026-10-15T09:47:00Z",
        "endedAt": "2026-10-15T10:27:00Z",
        "relativePath": "meetings/2026/10/15-customer-call---northwind",
    }))
    .unwrap();
    let rows = [
        (
            "them",
            "Our team loves the export feature, but we need SSO before we roll out company-wide.",
        ),
        (
            "me",
            "SSO is on the Q3 roadmap. I'll send you the security overview this week.",
        ),
        (
            "them",
            "Great. Pricing for 250 seats would help us get budget approved.",
        ),
    ];
    let transcript = Transcript {
        segments: rows
            .iter()
            .enumerate()
            .map(|(i, (speaker, text))| Segment {
                start: i as f64 * 15.0,
                end: (i + 1) as f64 * 15.0,
                speaker: speaker.to_string(),
                text: text.to_string(),
                confidence: None,
                timing_precision: None,
                attribution: None,
            })
            .collect(),
        engine: "on-device demo".into(),
        ..Default::default()
    };
    (meeting, transcript)
}

fn chat(content: serde_json::Value) -> Reply {
    Reply::Json(
        200,
        json!({"choices": [{"message": {"content": content.to_string()}, "finish_reason": "stop"}], "usage": {"completion_tokens": 120}}),
    )
}

fn user_message(request: &StubRequest) -> String {
    request.json()["messages"][1]["content"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn model(
    reply: impl Fn(&str, usize) -> Reply + Send + Sync + 'static,
) -> (StubServer, Arc<AtomicUsize>) {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let server = StubServer::start(move |request| match request.path.as_str() {
        "/tokenize" => {
            let n = request.json()["content"]
                .as_str()
                .map_or(0, |c| c.len() / 4 + 1);
            Reply::Json(200, json!({"tokens": vec![1; n]}))
        }
        "/v1/chat/completions" => reply(
            &user_message(request),
            counter.fetch_add(1, Ordering::SeqCst),
        ),
        _ => Reply::Text(404, String::new()),
    });
    (server, calls)
}

fn settings() -> Settings {
    Settings {
        summary_language: "match".into(),
        ..Settings::default()
    }
}

#[test]
fn one_pass_renders_notes_outcomes_and_header() {
    let (meeting, transcript) = northwind_meeting();
    let (server, calls) = model(|_, _| {
        chat(json!({
            "notes": [
                {"section": "TL;DR", "text": "SSO is the blocker for a company-wide rollout.", "source": "s1"},
                {"section": "Key points", "text": "SSO is on the Q3 roadmap.", "source": "s2"},
                {"section": "Open questions", "text": "What would 250 seats cost?", "source": "s3"},
            ],
            "actions": [
                {"text": "Send the security overview", "source": "s2", "context": [], "owner": "source", "basis": "commitment",
                 "quote": "I'll send you the security overview this week.", "due": "this week", "importance": 4},
            ],
            "has_more": false,
        }))
    });
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "qwen3.5-0.8b");
    let dir = tempfile::tempdir().unwrap();
    let options = NotesOptions {
        checkpoint_dir: Some(dir.path().to_path_buf()),
        ..Default::default()
    };
    let mut steps = Vec::new();
    let notes = generate_meeting_notes_with(
        &think,
        &meeting,
        &transcript,
        "",
        &settings(),
        &options,
        &mut |s| steps.push(s.to_string()),
    )
    .unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let summary = &notes.summary_markdown;
    assert!(
        summary.starts_with("# Customer call - Northwind — October 15, 2026 at "),
        "{summary}"
    );
    assert!(summary.contains("**Duration:** 40 min · **App:** Microsoft Teams · **Words:** 40 words · **Template:** Meeting · **Language:** English · **Model:** qwen3.5-0.8b · on this PC\n\n## TL;DR"), "{summary}");
    assert!(
        summary.contains(
            "## TL;DR\n\n- **Them:** SSO is the blocker for a company-wide rollout. — [00:00:00]"
        ),
        "{summary}"
    );
    assert!(
        summary.contains("## Key points\n\n- **You:** SSO is on the Q3 roadmap. — [00:00:15]"),
        "{summary}"
    );
    assert!(summary.contains("## Decisions\n\nNone\n\n## Action items\n\n### Me\n- [ ] Send the security overview — due this week — [00:00:15]\n\n### Others\nNone"), "{summary}");
    assert!(
        summary
            .contains("## Open questions\n\n- **Them:** What would 250 seats cost? — [00:00:30]"),
        "{summary}"
    );
    assert!(summary.ends_with('\n'));
    assert_eq!(notes.outcomes.action_items.len(), 1);
    assert!(notes.outcomes.action_items[0].is_for_user);
    assert_eq!(
        notes.outcomes.open_questions,
        ["Them: What would 250 seats cost?"]
    );
    assert_eq!(notes.claims["version"], 1);
    assert_eq!(notes.claims["claims"].as_array().unwrap().len(), 3);
    assert_eq!(
        notes.claims["claims"][0]["source_segment_id"],
        "segment-0000-0000000000-0000015000"
    );
    let raw: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.path().join(partial::PARTIAL_FILE)).unwrap())
            .unwrap();
    assert_eq!(raw["version"], 1);
    let snapshot = partial::MeetingNotesPartial::load(dir.path(), &transcript).unwrap();
    assert_eq!((snapshot.completed_parts, snapshot.total_parts), (1, 1));
    let mut changed = transcript.clone();
    changed.segments[0].text.push_str(" Changed.");
    assert!(partial::MeetingNotesPartial::load(dir.path(), &changed).is_none());
    std::fs::write(dir.path().join("outcomes.json"), "{}").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(20));
    std::fs::write(dir.path().join("summary.md"), "# Notes").unwrap();
    assert!(partial::MeetingNotesPartial::load(dir.path(), &transcript).is_none());
    remove_checkpoint(dir.path());
    assert!(!dir.path().join(CHECKPOINT_FILE).exists());
    assert!(!dir.path().join(partial::PARTIAL_FILE).exists());
    assert!(steps.iter().any(|s| s.contains("Writing notes")));
    let request = server
        .requests()
        .into_iter()
        .find(|r| r.path == "/v1/chat/completions")
        .unwrap()
        .json();
    assert!(
        request["messages"][0]["content"]
            .as_str()
            .unwrap()
            .starts_with("You are LokalBot, a precise meeting note-taker.\n")
    );
    assert!(
        request["messages"][1]["content"]
            .as_str()
            .unwrap()
            .contains(
                "s2|p1|SSO is on the Q3 roadmap. I'll send you the security overview this week."
            )
    );
    assert!(request.get("thinking_budget_tokens").is_none(), "{request}");
    assert_eq!(
        request["chat_template_kwargs"],
        serde_json::json!({"enable_thinking": false})
    );
    assert_eq!(request["temperature"], 0.0);
}

#[test]
fn notes_reserve_reasoning_room_and_charge_a_retried_request_twice() {
    let server = StubServer::start(|request| match request.path.as_str() {
        "/tokenize" => Reply::Json(200, json!({"tokens": [1, 2, 3]})),
        _ if request.json()["thinking_budget_tokens"] == 0 => Reply::Json(
            200,
            json!({"choices": [{"message": {"content": "{\"notes\": [], \"actions\": []}"}, "finish_reason": "stop"}], "usage": {"completion_tokens": 300}}),
        ),
        _ => Reply::Json(
            200,
            json!({"choices": [{"message": {"content": "<think>weighing"}, "finish_reason": "length"}], "usage": {"completion_tokens": 2_000}}),
        ),
    });
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "qwen3.5-4b");
    let mut budget = Budget::new(Limits {
        seconds: 600.0,
        requests: 3,
        input_tokens: 100_000,
        output_tokens: 3_000,
        scales_with_parts: false,
    });
    let (text, truncated) = request(
        &think,
        &mut budget,
        "system",
        "prompt",
        &[],
        json!({"type": "object"}),
        1_000,
        "extract-1",
        32_768,
        false,
        TaskReasoning::ModelDefault,
    )
    .unwrap();
    assert_eq!(text, "{\"notes\": [], \"actions\": []}");
    assert!(!truncated);
    let bodies: Vec<serde_json::Value> = server
        .requests()
        .iter()
        .filter(|r| r.path == "/v1/chat/completions")
        .map(|r| r.json())
        .collect();
    assert_eq!(bodies[0]["max_tokens"], 2_000);
    assert_eq!(bodies[0]["thinking_budget_tokens"], 1_000);
    assert_eq!(bodies[1]["max_tokens"], 1_000);
    assert!(
        budget.reserve(0, 701).is_err(),
        "both attempts' tokens count"
    );
    budget.reserve(0, 700).unwrap();
    assert!(
        budget.reserve(0, 0).is_err(),
        "both attempts count as requests"
    );

    let mut tight = Budget::new(Limits::for_preset(
        lokalbot_core::settings::GenerationBudget::Unlimited,
    ));
    request(
        &think,
        &mut tight,
        "system",
        "prompt",
        &[],
        json!({"type": "object"}),
        1_000,
        "extract-1",
        ENVELOPE_TOKENS + 3 + 1_500,
        false,
        TaskReasoning::ModelDefault,
    )
    .unwrap();
    let last = server
        .requests()
        .into_iter()
        .rfind(|r| r.path == "/v1/chat/completions")
        .unwrap()
        .json();
    assert_eq!(
        last["max_tokens"], 1_000,
        "no room to reason, so it is sent off"
    );
    assert_eq!(last["thinking_budget_tokens"], 0);
}

#[test]
fn notes_retry_reserves_input_and_slots_before_dispatch_and_preserves_recovery() {
    let server = StubServer::start(|request| match request.path.as_str() {
        "/tokenize" => Reply::Json(200, json!({"tokens": [1, 2, 3]})),
        _ if request.json()["thinking_budget_tokens"] == 0 => Reply::Json(
            200,
            json!({"choices": [{"message": {"content": "{\"notes\": [], \"actions\": []}"}, "finish_reason": "stop"}], "usage": {"completion_tokens": 100}}),
        ),
        _ => Reply::Json(
            200,
            json!({"choices": [{"message": {"content": "<think>weighing"}, "finish_reason": "length"}]}),
        ),
    });
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "qwen3.5-4b");
    let prompt_input = u64::from(ENVELOPE_TOKENS + 3);

    let mut partial_usage = Budget::new(Limits {
        seconds: 600.0,
        requests: 3,
        input_tokens: prompt_input * 2 + 50,
        output_tokens: 3_000,
        scales_with_parts: false,
    });
    let (text, truncated) = request(
        &think,
        &mut partial_usage,
        "system",
        "prompt",
        &[],
        json!({"type": "object"}),
        1_000,
        "extract-1",
        32_768,
        false,
        TaskReasoning::ModelDefault,
    )
    .unwrap();
    assert_eq!(text, "{\"notes\": [], \"actions\": []}");
    assert!(!truncated);
    assert!(
        partial_usage.reserve(51, 0).is_err(),
        "retry prompt input must be charged"
    );
    assert!(
        partial_usage.reserve(0, 901).is_err(),
        "unreported first attempt keeps its 2,000-token estimate plus 100 actual"
    );
    partial_usage.reserve(50, 900).unwrap();

    let single_slot_server = StubServer::start(|request| match request.path.as_str() {
        "/tokenize" => Reply::Json(200, json!({"tokens": [1, 2, 3]})),
        _ => Reply::Json(
            200,
            json!({"choices": [{"message": {"content": "<think>weighing"}, "finish_reason": "length"}]}),
        ),
    });
    let single_think =
        ThinkClient::llama_server(&single_slot_server.url("/v1"), "token", "qwen3.5-4b");
    let mut one_slot = Budget::new(Limits {
        seconds: 600.0,
        requests: 1,
        input_tokens: 100_000,
        output_tokens: 10_000,
        scales_with_parts: false,
    });
    let (empty, was_truncated) = request(
        &single_think,
        &mut one_slot,
        "system",
        "prompt",
        &[],
        json!({"type": "object"}),
        1_000,
        "extract-1",
        32_768,
        false,
        TaskReasoning::ModelDefault,
    )
    .unwrap();
    assert!(empty.is_empty());
    assert!(was_truncated);
    let chat_calls = single_slot_server
        .requests()
        .iter()
        .filter(|r| r.path == "/v1/chat/completions")
        .count();
    assert_eq!(
        chat_calls, 1,
        "no retry is sent when no request slot remains"
    );

    let failing_off_server = StubServer::start(|request| match request.path.as_str() {
        "/tokenize" => Reply::Json(200, json!({"tokens": [1, 2, 3]})),
        _ if request.json()["thinking_budget_tokens"] == 0
            && request.json()["max_tokens"] == 1_000 =>
        {
            Reply::Json(400, json!({"error": {"message": "same-size off rejected"}}))
        }
        _ if request.json()["thinking_budget_tokens"] == 0 => Reply::Json(
            200,
            json!({"choices": [{"message": {"content": "{\"notes\": [], \"actions\": []}"}, "finish_reason": "stop"}], "usage": {"completion_tokens": 120}}),
        ),
        _ => Reply::Json(
            200,
            json!({"choices": [{"message": {"content": "<think>weighing"}, "finish_reason": "length"}]}),
        ),
    });
    let recovery_think =
        ThinkClient::llama_server(&failing_off_server.url("/v1"), "token", "qwen3.5-4b");
    let mut generous = Budget::new(Limits::for_preset(
        lokalbot_core::settings::GenerationBudget::Unlimited,
    ));
    let (recovered, recovered_truncated) = request(
        &recovery_think,
        &mut generous,
        "system",
        "prompt",
        &[],
        json!({"type": "object"}),
        1_000,
        "extract-1",
        32_768,
        false,
        TaskReasoning::ModelDefault,
    )
    .unwrap();
    assert_eq!(recovered, "{\"notes\": [], \"actions\": []}");
    assert!(!recovered_truncated);
}

#[test]
fn a_page_with_more_continues_from_the_ledger() {
    let (meeting, transcript) = northwind_meeting();
    let (server, calls) = model(|prompt, call| {
        if call == 0 {
            chat(json!({
                "notes": [{"section": "TL;DR", "text": "SSO is the blocker.", "source": "s1"}],
                "actions": [{"text": "Send the security overview", "source": "s2", "context": [], "owner": "source", "basis": "commitment",
                             "quote": "I'll send you the security overview this week.", "due": "this week", "importance": 4}],
                "has_more": true,
            }))
        } else {
            assert!(prompt.contains("Previously accepted records: [{\"kind\":\"notes\",\"source\":\"s1\",\"text\":\"SSO is the blocker.\"},{\"kind\":\"actions\",\"source\":\"s2\",\"text\":\"Send the security overview\"}]"), "{prompt}");
            chat(
                json!({"notes": [{"section": "Key points", "text": "Pricing for 250 seats would help.", "source": "s3"}], "actions": [], "has_more": false}),
            )
        }
    });
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "m");
    let notes = generate_meeting_notes(&think, &meeting, &transcript, "", &settings(), &mut |_| {})
        .unwrap();
    assert!(calls.load(Ordering::SeqCst) >= 2);
    assert!(
        notes
            .summary_markdown
            .contains("Pricing for 250 seats would help.")
    );
}

#[test]
fn an_unfound_ownership_quote_is_repaired() {
    let (meeting, mut transcript) = northwind_meeting();
    transcript.segments[1].text = "SSO is on the Q3 roadmap.".into();
    let (server, _calls) = model(|prompt, _| {
        if prompt.starts_with("This is a targeted repair.") {
            assert!(prompt.contains("ownership_quote_not_found"), "{prompt}");
            chat(json!({
                "notes": [],
                "actions": [{"text": "Prepare a 250-seat quote", "source": "s3", "context": [], "owner": "unknown", "basis": "unclear",
                             "quote": "", "due": "", "importance": 3}],
                "has_more": false,
            }))
        } else {
            chat(json!({
                "notes": [{"section": "TL;DR", "text": "SSO is the blocker.", "source": "s1"}],
                "actions": [{"text": "Prepare a 250-seat quote", "source": "s3", "context": [], "owner": "p1", "basis": "request",
                             "quote": "Can you price it", "due": "", "importance": 3}],
                "has_more": false,
            }))
        }
    });
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "qwen3.5-4b");
    let notes = generate_meeting_notes(&think, &meeting, &transcript, "", &settings(), &mut |_| {})
        .unwrap();
    let chat_requests: Vec<_> = server
        .requests()
        .into_iter()
        .filter(|r| r.path == "/v1/chat/completions")
        .collect();
    let repair_request = chat_requests
        .iter()
        .find(|r| user_message(r).starts_with("This is a targeted repair."))
        .expect("targeted repair request");
    let primary_request = chat_requests
        .iter()
        .find(|r| !user_message(r).starts_with("This is a targeted repair."))
        .expect("primary notes request");
    assert_ne!(primary_request.json()["thinking_budget_tokens"], 0);
    assert_eq!(repair_request.json()["thinking_budget_tokens"], 0);
    assert_eq!(
        repair_request.json()["chat_template_kwargs"],
        json!({"enable_thinking": false})
    );
    assert_eq!(notes.outcomes.action_items.len(), 1);
    let action = &notes.outcomes.action_items[0];
    assert!(action.ownership_is_unclear(), "{action:?}");
    assert!(
        notes
            .summary_markdown
            .contains("### Owner unclear\n- [ ] Prepare a 250-seat quote — [00:00:30]"),
        "{}",
        notes.summary_markdown
    );
}

#[test]
fn empty_transcripts_render_none_sections() {
    let (meeting, mut transcript) = northwind_meeting();
    transcript.segments.clear();
    let (server, calls) = model(|_, _| panic!("no request expected"));
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "m");
    let notes = generate_meeting_notes(&think, &meeting, &transcript, "", &settings(), &mut |_| {})
        .unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert!(notes.summary_markdown.contains("## TL;DR\n\nNone"));
    assert!(notes.outcomes.is_empty());
}

#[test]
fn provider_failures_leave_partial_checkpoints() {
    let (meeting, transcript) = northwind_meeting();
    let (server, _) = model(|_, _| {
        chat(
            json!({"notes": [{"section": "TL;DR", "text": "x", "source": "s99"}], "actions": [], "has_more": false}),
        )
    });
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "m");
    let dir = tempfile::tempdir().unwrap();
    let options = NotesOptions {
        checkpoint_dir: Some(dir.path().to_path_buf()),
        ..Default::default()
    };
    let err = generate_meeting_notes_with(
        &think,
        &meeting,
        &transcript,
        "",
        &settings(),
        &options,
        &mut |_| {},
    )
    .unwrap_err();
    assert!(
        err.to_string().contains("missing or invalid evidence IDs"),
        "{err}"
    );
    assert!(dir.path().join(CHECKPOINT_FILE).exists());
    assert!(
        std::fs::read_to_string(dir.path().join("summary.partial.md"))
            .unwrap()
            .starts_with("# Partial notes — 0/1 parts source-linked")
    );
    let again = generate_meeting_notes_with(
        &think,
        &meeting,
        &transcript,
        "",
        &settings(),
        &options,
        &mut |_| {},
    )
    .unwrap_err();
    assert!(
        again
            .to_string()
            .contains("missing or invalid evidence IDs")
    );
}

#[test]
fn chunks_split_long_transcripts_with_overlap() {
    let (meeting, mut transcript) = northwind_meeting();
    let long =
        "We reviewed the caching layer and the failover benchmark plan in detail. ".repeat(12);
    transcript.segments = (0..60)
        .map(|i| Segment {
            start: i as f64 * 10.0,
            end: i as f64 * 10.0 + 9.0,
            speaker: if i % 2 == 0 {
                "them".into()
            } else {
                "me".into()
            },
            text: long.clone(),
            confidence: None,
            timing_precision: None,
            attribution: None,
        })
        .collect();
    let (server, _) = model(|_, _| chat(json!({"notes": [], "actions": [], "has_more": false})));
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "m");
    let evidence = Evidence::new(View::new(&transcript, true), meeting.id, true);
    let system = prompts::meeting_notes_system(
        NoteTemplate::Meeting,
        None,
        &evidence::sections(NoteTemplate::Meeting),
    );
    let chunks = make_chunks(
        &evidence,
        &think,
        &system,
        &[],
        32_768,
        NoteTemplate::Meeting,
        None,
    )
    .unwrap();
    assert!(chunks.len() >= 3, "{}", chunks.len());
    for pair in chunks.windows(2) {
        let last_two: Vec<&str> = pair[0][pair[0].len() - 2..]
            .iter()
            .map(|u| u.source.as_str())
            .collect();
        assert_eq!(
            last_two,
            pair[1][..2]
                .iter()
                .map(|u| u.source.as_str())
                .collect::<Vec<_>>()
        );
    }
}

#[test]
fn calendar_context_and_agenda_follow_their_settings() {
    let (mut meeting, _) = northwind_meeting();
    meeting.calendar_title = Some("Northwind renewal".into());
    meeting.calendar_participant_identities =
        Some(vec![lokalbot_core::model::CalendarParticipantIdentity {
            id: "a".into(),
            name: Some("Jordan Lee".into()),
            email_address: Some("jordan@example.com".into()),
        }]);
    meeting.calendar_agenda = Some("Renewal terms\nSSO timeline".into());
    let block = |settings: &Settings| context_items(&meeting, "", &[], settings).join("\n");

    let defaults = block(&Settings::default());
    assert!(defaults.contains("Scheduled title: Northwind renewal"));
    assert!(defaults.contains(
        "Invited participants (names from the calendar; they may not all have spoken): Jordan Lee"
    ));
    assert!(
        !defaults.contains("jordan@example.com"),
        "addresses never reach a prompt"
    );
    assert!(
        !defaults.contains("Agenda"),
        "a saved agenda needs agenda use on"
    );

    let with_agenda = block(&Settings {
        use_calendar_agenda: true,
        ..Settings::default()
    });
    assert!(
        with_agenda.contains("Agenda from the calendar invitation:\nRenewal terms\nSSO timeline")
    );

    let without_calendar = block(&Settings {
        meeting_notes_use_calendar_context: false,
        ..Settings::default()
    });
    assert!(without_calendar.is_empty(), "{without_calendar}");
}

#[test]
fn multi_part_notes_extract_before_repair_and_batch_concurrently() {
    let (meeting, mut transcript) = northwind_meeting();
    let filler =
        "We reviewed the caching layer, rollout schedule, and failover benchmark plan in detail. "
            .repeat(12);
    transcript.segments = (0..45)
        .map(|i| Segment {
            start: i as f64 * 10.0,
            end: i as f64 * 10.0 + 9.0,
            speaker: "them".into(),
            text: format!("Part segment {i}. {filler}"),
            confidence: None,
            timing_precision: None,
            attribution: None,
        })
        .collect();

    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let events = Arc::new(parking_lot::Mutex::new(Vec::<String>::new()));

    let active_c = active.clone();
    let peak_c = peak.clone();
    let events_c = events.clone();
    let (server, _) = model(move |prompt, _| {
        let now = active_c.fetch_add(1, Ordering::SeqCst) + 1;
        peak_c.fetch_max(now, Ordering::SeqCst);
        let is_repair = prompt.starts_with("This is a targeted repair.");
        events_c
            .lock()
            .push(if is_repair { "repair" } else { "extract" }.to_string());
        std::thread::sleep(std::time::Duration::from_millis(60));
        active_c.fetch_sub(1, Ordering::SeqCst);
        if is_repair {
            chat(json!({
                "notes": [{"section": "Key points", "text": "Repaired part one finding.", "source": "s2"}],
                "actions": [],
                "has_more": false,
            }))
        } else if prompt.contains("s1|") {
            chat(json!({
                "notes": [
                    {"section": "Key points", "text": "Part one accepted finding.", "source": "s1"},
                    {"section": "Wrong", "text": "Needs repair", "source": "s2"}
                ],
                "actions": [],
                "has_more": false,
            }))
        } else {
            let source = prompt
                .lines()
                .rev()
                .find_map(|line| {
                    line.split_once('|').map(|(id, _)| id).filter(|id| {
                        id.strip_prefix('s')
                            .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
                    })
                })
                .unwrap_or("s1");
            chat(json!({
                "notes": [{"section": "Key points", "text": format!("Summary for {source}."), "source": source}],
                "actions": [],
                "has_more": false,
            }))
        }
    });

    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "qwen3.5-4b");
    assert_eq!(think.max_concurrent_notes_parts(), 2);
    let dir = tempfile::tempdir().unwrap();
    let options = NotesOptions {
        checkpoint_dir: Some(dir.path().to_path_buf()),
        ..Default::default()
    };
    let notes = generate_meeting_notes_with(
        &think,
        &meeting,
        &transcript,
        "",
        &settings(),
        &options,
        &mut |_| {},
    )
    .unwrap();

    let recorded = events.lock().clone();
    let first_repair = recorded
        .iter()
        .position(|kind| kind == "repair")
        .expect("part one should trigger repair");
    let last_extract = recorded
        .iter()
        .rposition(|kind| kind == "extract")
        .expect("parts should extract");
    assert!(
        last_extract < first_repair,
        "all extractions must run before repair: {recorded:?}"
    );
    assert_eq!(
        peak.load(Ordering::SeqCst),
        2,
        "expected 2 concurrent slots"
    );
    assert!(
        notes
            .summary_markdown
            .contains("Repaired part one finding.")
    );
}

#[test]
fn effective_concurrency_drops_to_one_when_high_reasoning_exceeds_shared_context() {
    let planned = vec![
        PlannedChunk {
            units: Vec::new(),
            planning: 6_000,
            upper: 6_000,
        },
        PlannedChunk {
            units: Vec::new(),
            planning: 6_000,
            upper: 6_000,
        },
    ];
    let scales = vec![1.0, 1.0];
    assert_eq!(effective_concurrency(2, &planned, &scales, 32_768, 0), 2);
    assert_eq!(
        effective_concurrency(2, &planned, &scales, 32_768, 8_192),
        1
    );
    assert_eq!(effective_concurrency(2, &planned, &scales, 16_384, 0), 1);
}

#[test]
fn extraction_failure_still_repairs_already_extracted_part() {
    let (meeting, mut transcript) = northwind_meeting();
    let filler =
        "We reviewed the caching layer, rollout schedule, and failover benchmark plan in detail. "
            .repeat(12);
    transcript.segments = (0..45)
        .map(|i| Segment {
            start: i as f64 * 10.0,
            end: i as f64 * 10.0 + 9.0,
            speaker: "them".into(),
            text: format!("Part segment {i}. {filler}"),
            confidence: None,
            timing_precision: None,
            attribution: None,
        })
        .collect();

    let (server, _) = model(move |prompt, _| {
        if prompt.starts_with("This is a targeted repair.") {
            chat(json!({
                "notes": [{"section": "Key points", "text": "Repaired part one finding.", "source": "s2"}],
                "actions": [],
                "has_more": false,
            }))
        } else if prompt.contains("s1|") {
            chat(json!({
                "notes": [
                    {"section": "Key points", "text": "Part one accepted finding.", "source": "s1"},
                    {"section": "Wrong", "text": "Needs repair", "source": "s2"}
                ],
                "actions": [],
                "has_more": false,
            }))
        } else {
            std::thread::sleep(std::time::Duration::from_millis(30));
            Reply::Text(500, "simulated part two failure".into())
        }
    });

    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "qwen3.5-4b");
    let dir = tempfile::tempdir().unwrap();
    let options = NotesOptions {
        checkpoint_dir: Some(dir.path().to_path_buf()),
        ..Default::default()
    };
    let result = generate_meeting_notes_with(
        &think,
        &meeting,
        &transcript,
        "",
        &settings(),
        &options,
        &mut |_| {},
    );
    assert!(result.is_err());
    let saved = std::fs::read_to_string(dir.path().join(CHECKPOINT_FILE)).unwrap();
    assert!(
        saved.contains("Repaired part one finding."),
        "part one repair must persist even when part two fails extraction: {saved}"
    );
}
