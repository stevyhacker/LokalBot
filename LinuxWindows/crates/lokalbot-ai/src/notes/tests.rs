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

/// A llama-server stand-in: `/tokenize` counts about four characters per token.
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
    // Checkpoints are removed once the notes are complete.
    assert!(!dir.path().join(CHECKPOINT_FILE).exists());
    assert!(steps.iter().any(|s| s.contains("Writing notes")));
    // The request carried the verbatim system prompt and the evidence rows.
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
    assert_eq!(request["thinking_budget_tokens"], 0);
    assert_eq!(request["temperature"], 0.0);
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
    let think = ThinkClient::llama_server(&server.url("/v1"), "token", "m");
    let notes = generate_meeting_notes(&think, &meeting, &transcript, "", &settings(), &mut |_| {})
        .unwrap();
    assert!(
        server
            .requests()
            .iter()
            .any(|r| r.path == "/v1/chat/completions"
                && user_message(r).starts_with("This is a targeted repair."))
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
    // An automatic rerun keeps the stop; a person's retry scans again.
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
