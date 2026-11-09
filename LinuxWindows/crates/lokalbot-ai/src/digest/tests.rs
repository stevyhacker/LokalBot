use lokalbot_core::coding_agents::{CodingAgentAction, CodingAgentBurst, PullRequestReference};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use chrono::{Duration, TimeZone};
use serde_json::json;

use super::*;
use crate::http::testing::{Reply, StubServer};

fn day() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 10, 17).unwrap()
}

fn chat(content: Value) -> Reply {
    Reply::Json(
        200,
        json!({"choices": [{"message": {"content": content.to_string()}, "finish_reason": "stop"}]}),
    )
}

fn focus(task: &str, substantive: bool) -> Value {
    json!({"substantive": substantive, "task": task, "work_done": format!("Worked on {task}."), "status": "in_progress",
           "outcome": "", "next_step": "", "source_ids": [1, 999], "other_tasks": []})
}

fn local(hour: u32, minute: u32) -> DateTime<Utc> {
    Local
        .from_local_datetime(&day().and_hms_opt(hour, minute, 0).unwrap())
        .unwrap()
        .with_timezone(&Utc)
}

fn synthetic() -> DayEvidence {
    let (start, end) = lokalbot_core::time::local_day_bounds(day());
    let block = |id: i64, app: &str, title: &str, from: (u32, u32), to: (u32, u32)| {
        lokalbot_core::model::ActivityBlock {
            id,
            app: app.into(),
            title: title.into(),
            start: local(from.0, from.1),
            end: local(to.0, to.1),
        }
    };
    let blocks = vec![
        block(1, "Code", "TimelineView.swift", (9, 0), (10, 30)),
        block(
            2,
            "Firefox",
            "Pull request #42 - caching",
            (10, 30),
            (11, 15),
        ),
        block(3, "Terminal", "lokalbot build", (14, 20), (15, 0)),
    ];
    let contexts = vec![
        ScreenContext {
            snapshot_id: 1,
            captured_at: local(9, 24),
            app: "Code".into(),
            window_title: "TimelineView.swift".into(),
            text: "Context rewind keeps the selected moment".into(),
        },
        ScreenContext {
            snapshot_id: 1,
            captured_at: local(9, 25),
            app: "Code".into(),
            window_title: "TimelineView.swift".into(),
            text: "Context rewind keeps the selected moment".into(),
        },
        ScreenContext {
            snapshot_id: 7,
            captured_at: local(16, 0),
            app: "Notes".into(),
            window_title: "".into(),
            text: "Standalone capture".into(),
        },
    ];
    let meetings = vec![MeetingEvidence {
        id: Uuid::nil(),
        title: "Design review".into(),
        app: "Zoom".into(),
        started_at: local(11, 40),
        ended_at: local(12, 5),
        source_summary: "# Design review — x\n**Duration:** 25 min\n\n## TL;DR\n\n- **Them:** Ship the empty states. — [00:01:00]".into(),
        outcomes: "Decisions:\n- Ship the empty states".into(),
        artifact_modified_at: None,
    }];
    DayEvidence::build(day(), start, end, blocks, contexts, meetings, Vec::new())
}

#[test]
fn evidence_attaches_screen_text_and_splits_at_idle_gaps() {
    let evidence = synthetic();
    assert_eq!(
        evidence.activities[0].contexts.len(),
        1,
        "a repeated capture counts once"
    );
    assert_eq!(evidence.standalone_contexts.len(), 1);
    let segments = evidence.summary_segments();
    // 09:00–11:15 is one session of 2h15m (two segments); the meeting after
    // a 25-minute gap, 14:20 and 16:00 start their own.
    assert_eq!(
        segments.len(),
        5,
        "{:?}",
        segments
            .iter()
            .map(|s| (time(s.start), time(s.end)))
            .collect::<Vec<_>>()
    );
    assert!(
        segments[0]
            .evidence
            .starts_with("WORK CONTENT — primary evidence:\nWORK SOURCE: ACTIVITY")
    );
    assert!(segments.iter().any(|s| s.evidence.contains("WORK SOURCE: MEETING\nTask context: Design review\nOutcomes:\nDecisions:\n- Ship the empty states")));
    assert!(
        segments
            .iter()
            .all(|s| !s.evidence.contains("**Duration:**")),
        "the meeting header is not evidence"
    );
    assert_eq!(segments[0].source_ids, [1]);
    assert!(segments[0].evidence.contains("LOW-PRIORITY TRACE METADATA — context only, never a work item:\n[09:00–10:30] Code — TimelineView.swift"));
}

#[test]
fn journal_sections_follow_the_macos_layout() {
    let evidence = synthetic();
    let journal = evidence
        .render_document("### Tasks\n- **Caching review** — In progress. Reviewed the cache.");
    assert!(journal.starts_with("## Day summary\n\n### Tasks\n- **Caching review** — In progress. Reviewed the cache.\n\n## Meetings\n\n### "));
    assert!(journal.contains("— Design review\n- App: Zoom\n- Duration: 25m\n- Source summary: "));
    assert!(journal.contains("## Time allocation\n\n| App | Tracked time |\n| --- | ---: |\n| Code | 1h 30m |\n| Firefox | 45m |\n| Terminal | 40m |"));
    assert!(journal.contains("## Full activity log\n\n- **09:00–10:30** — **Code** — TimelineView.swift\n  - [screen:1], 09:24: Context rewind keeps the selected moment"));
    assert!(journal.contains("— **Meeting** — Design review (Zoom)"));
    assert!(journal.contains("— **Screen context** — Notes\n  - [screen:7]: Standalone capture"));
    assert!(journal.ends_with('\n'));
    let parsed = lokalbot_core::digest::parse_digest(&journal);
    assert_eq!(parsed.tasks.len(), 1);
    assert_eq!(parsed.tasks[0].title, "Caching review");
    assert_eq!(parsed.time_allocations.len(), 3);
}

#[test]
fn two_passes_build_tasks_and_follow_ups() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let server = StubServer::start(move |request| {
        if request.path != "/v1/chat/completions" {
            return Reply::Text(404, String::new());
        }
        counter.fetch_add(1, Ordering::SeqCst);
        let body = request.json();
        let system = body["messages"][0]["content"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let user = body["messages"][1]["content"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        assert!(
            user.starts_with("Date: Saturday, October 17, 2026\n\n"),
            "{user}"
        );
        if system.starts_with("You extract substantive work") {
            assert_eq!(body["max_tokens"], 2048);
            assert_eq!(body["thinking_budget_tokens"], 256);
            if user.contains("Standalone capture") {
                return chat(focus("Notes capture", false));
            }
            let task = if user.contains("lokalbot build") {
                "LokalBot build"
            } else if user.contains("Pull request #42") {
                "Caching review"
            } else if user.contains("WORK SOURCE: MEETING") {
                "Design review"
            } else {
                "Timeline polish"
            };
            chat(focus(task, true))
        } else {
            assert!(
                user.contains("WORK CANDIDATES (primary first, then secondary):"),
                "{user}"
            );
            assert!(user.contains("Priority: secondary"));
            chat(json!({
                "tasks": [{"title": "Caching review", "status": "completed", "summary": "The user reviewed PR #42 and approved it.", "next_step": "Benchmark failover.", "block_indices": [1, 99]}],
                "decisions": ["Keep Redis as the cache."],
                "blockers": [],
            }))
        }
    });
    let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
    let overview = generate_overview(&think, &synthetic(), "", &mut |_| {}).unwrap();
    assert_eq!(overview.quality, DigestQuality::Complete);
    let summary = overview.summary;
    assert!(
        summary.starts_with(
            "### Tasks\n- **Caching review** — Completed. Reviewed PR #42 and approved it."
        ),
        "{summary}"
    );
    assert!(
        summary.contains("- **Timeline polish** — In progress. Worked on Timeline polish."),
        "{summary}"
    );
    assert!(
        summary.contains("- **LokalBot build** — In progress. Worked on LokalBot build."),
        "{summary}"
    );
    assert!(
        summary.contains("- **Notes capture** — In progress. Worked on Notes capture."),
        "{summary}"
    );
    assert!(summary.contains("### Decisions and next steps\n- Decision: Keep Redis as the cache.\n- Next — Caching review: Benchmark failover."), "{summary}");
    let first_run = calls.load(Ordering::SeqCst);
    // A second run reuses the cached answers for unchanged evidence.
    generate_overview(&think, &synthetic(), "", &mut |_| {}).unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), first_run);
    purge_cache(&[day()]);
}

#[test]
fn a_failing_model_still_writes_an_evidence_journal() {
    let server = StubServer::start(|_| Reply::Json(500, json!({"error": {"message": "boom"}})));
    let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
    let mut evidence = synthetic();
    evidence.day = day() + Duration::days(400);
    let overview = generate_overview(&think, &evidence, "", &mut |_| {}).unwrap();
    assert_eq!(overview.quality, DigestQuality::Fallback);
    assert!(
        overview
            .summary
            .starts_with("### Tasks\n- **Design review** — "),
        "{}",
        overview.summary
    );
    assert!(overview.summary.contains("- **TimelineView.swift** — Activity related to this item was recorded; no more specific outcome was visible."));
}

#[test]
fn an_empty_day_needs_no_model() {
    let (start, end) = lokalbot_core::time::local_day_bounds(day());
    let evidence = DayEvidence::build(
        day(),
        start,
        end,
        Vec::new(),
        Vec::new(),
        Vec::new(),
        Vec::new(),
    );
    let server = StubServer::start(|_| panic!("no request expected"));
    let think = ThinkClient::llama_server(&server.url("/v1"), "t", "m");
    let overview = generate_overview(&think, &evidence, "", &mut |_| {}).unwrap();
    assert_eq!(
        evidence.render_document(&overview.summary),
        "## Day summary\n\n### At a glance\n_No activity was recorded._\n\n## Meetings\n\n_None._\n\n## Time allocation\n\n_No tracked app time._\n\n## Full activity log\n\n_No activity was recorded._\n"
    );
}

#[test]
fn the_fixture_day_loads_and_signs_its_evidence() {
    let Some((_dir, library)) = crate::test_support::fixture_library() else {
        return;
    };
    let evidence = DayEvidence::load(&library, day()).unwrap();
    assert_eq!(evidence.activities.len(), 6);
    assert!(evidence.meetings.iter().any(|m| m.title == "Design review"));
    assert!(!evidence.summary_segments().is_empty());
    let (signature, meetings) = evidence_signatures(&library, day()).unwrap();
    assert_eq!(signature, evidence.content_signature());
    assert_eq!(meetings.len(), 64);
    let _ = Utc.timestamp_opt(0, 0);
}

fn burst(session: &str, minute: u32, actions: Vec<CodingAgentAction>) -> CodingAgentBurst {
    let (start, _) = lokalbot_core::time::local_day_bounds(day());
    let at = start + chrono::Duration::hours(9) + chrono::Duration::minutes(i64::from(minute));
    CodingAgentBurst {
        actions,
        active_duration: 300.0,
        agent: lokalbot_core::coding_agents::CodingAgentKind::ClaudeCode,
        branch: Some("main".into()),
        changed_file_count: 7,
        changed_files: vec!["a.rs".into(), "b.rs".into()],
        end: at + chrono::Duration::minutes(5),
        final_reply: Some("All done, trust me".into()),
        project: "lokalbot".into(),
        prompt_count: 4,
        prompts: vec!["Export the notes".into()],
        pull_requests: vec!["https://github.com/acme/lokalbot/pull/12".into()],
        session_id: session.into(),
        start: at,
        title: "Export the notes".into(),
        tool_call_count: 3,
    }
}

fn with_bursts(bursts: Vec<CodingAgentBurst>) -> DayEvidence {
    let (start, end) = lokalbot_core::time::local_day_bounds(day());
    DayEvidence::build(
        day(),
        start,
        end,
        Vec::new(),
        Vec::new(),
        Vec::new(),
        bursts,
    )
}

#[test]
fn agent_work_has_its_own_section_with_recorded_facts_only() {
    let evidence = with_bursts(vec![
        burst("s1", 0, vec![CodingAgentAction::Pushed {}]),
        burst(
            "s1",
            30,
            vec![CodingAgentAction::MergedPullRequest { number: Some(12) }],
        ),
    ]);
    assert!(!evidence.is_empty());
    assert!(evidence.latest_evidence_at().is_some());
    let document = evidence.render_document("");
    let section = document
        .split("## Agent sessions\n\n")
        .nth(1)
        .unwrap()
        .split("## Time allocation")
        .next()
        .unwrap();
    // One entry per session, with what was recorded and not what it claimed.
    assert_eq!(section.matches("### ").count(), 1);
    assert!(section.contains("- Project: lokalbot (branch main)"));
    assert!(section.contains("- Recorded actions: pushed; merged PR #12"));
    assert!(section.contains("[acme/lokalbot#12](https://github.com/acme/lokalbot/pull/12)"));
    assert!(section.contains("(+6 more)"));
    assert!(section.contains("- Changed files (12): a.rs, b.rs, +10 more"));
    assert!(!section.contains("trust me"));
    // The lossless log lists every burst.
    let log = document.split("## Full activity log").nth(1).unwrap();
    assert_eq!(log.matches("**Claude Code**").count(), 2);
}

#[test]
fn days_without_agent_work_keep_their_shape_and_signature() {
    let (start, end) = lokalbot_core::time::local_day_bounds(day());
    let plain = DayEvidence::build(
        day(),
        start,
        end,
        Vec::new(),
        Vec::new(),
        Vec::new(),
        Vec::new(),
    );
    assert!(!plain.render_document("").contains("Agent sessions"));
    let worked = with_bursts(vec![burst("s1", 0, Vec::new())]);
    assert_ne!(plain.content_signature(), worked.content_signature());
    // Bursts of other days don't join this one.
    let mut elsewhere = burst("s1", 0, Vec::new());
    elsewhere.start = end + chrono::Duration::hours(1);
    assert!(with_bursts(vec![elsewhere]).is_empty());
}

#[test]
fn screen_text_in_a_host_app_defers_to_the_session_covering_it() {
    let (start, end) = lokalbot_core::time::local_day_bounds(day());
    let at = start + chrono::Duration::hours(9);
    let context = |minute: i64| ScreenContext {
        snapshot_id: minute + 1,
        captured_at: at + chrono::Duration::minutes(minute),
        app: "Konsole".into(),
        window_title: "claude".into(),
        text: format!("terminal text {minute}"),
    };
    let block = lokalbot_core::model::ActivityBlock {
        id: 1,
        app: "Konsole".into(),
        title: "claude".into(),
        start: at,
        end: at + chrono::Duration::minutes(30),
    };
    let evidence = DayEvidence::build(
        day(),
        start,
        end,
        vec![block],
        vec![context(1), context(10), context(20), context(40)],
        Vec::new(),
        vec![burst("s1", 0, Vec::new())],
    );
    let segments = evidence.summary_segments();
    let text: String = segments.iter().map(|s| s.evidence.clone()).collect();
    assert!(text.contains("A coding-agent session covers this interval"));
    assert!(text.contains("WORK SOURCE: AGENT SESSION [agent:claude-code:s1]"));
    assert!(text.contains("Agent's final report (a claim; corroborate with actions)"));
    // The standalone capture at 09:40 is outside the block but also after the
    // burst, so it stays; only one capture from the covered block remains.
    assert_eq!(text.matches("terminal text").count(), 2, "{text}");
}

#[test]
fn a_session_with_outcomes_always_reaches_the_summary_and_settles_its_status() {
    let mut merged = burst(
        "s1",
        0,
        vec![CodingAgentAction::MergedPullRequest { number: Some(12) }],
    );
    merged.title = "Untitled session".into();
    merged.prompts = vec!["why is this slow?".into()];
    merged.actions.push(CodingAgentAction::OpenedPullRequest {
        title: "fix: speed up the export".into(),
    });
    let mut scheduled = burst("s2", 40, vec![CodingAgentAction::Pushed {}]);
    scheduled.prompts = vec!["Scheduled task: nightly".into()];
    let evidence = with_bursts(vec![merged, scheduled]);
    let candidates = session_candidates(&evidence);
    assert_eq!(candidates.len(), 1);
    assert_eq!(candidates[0].block.task, "Speed up the export (lokalbot)");
    assert_eq!(candidates[0].block.status, "completed");
    assert!(candidates[0].block.outcome.contains("acme/lokalbot#12"));
    let rendered = render(
        &[FocusBlock {
            task: "Other work".into(),
            work_done: "Something else.".into(),
            status: "unknown".into(),
            outcome: String::new(),
            next_step: String::new(),
            source_ids: Vec::new(),
        }],
        None,
        &candidates,
    );
    assert!(
        rendered.contains("Speed up the export (lokalbot)"),
        "{rendered}"
    );

    // Named by the model already: the session merges in, adding only what's new.
    let mut tasks = vec![NormalizedTask {
        title: "acme/lokalbot#12 review".into(),
        status: "in_progress".into(),
        summary: "Reviewed it.".into(),
        next_step: String::new(),
    }];
    merge_session_candidate(&candidates[0], &mut tasks);
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].status, "completed");
    assert!(tasks[0].summary.contains("Pull requests: acme/lokalbot#12"));
    merge_session_candidate(&candidates[0], &mut tasks);
    assert_eq!(tasks[0].summary.matches("acme/lokalbot#12").count(), 1);

    // With no model at all, the fallback still names the session's work.
    let fallback = fallback_summary(&evidence);
    assert!(fallback.contains("Speed up the export"), "{fallback}");
    assert!(
        fallback.contains("Worked with Claude Code in lokalbot."),
        "{fallback}"
    );
}

#[test]
fn matching_a_session_to_a_task_needs_the_same_work() {
    assert!(work_words("Review the pull requests").contains("pr"));
    assert_eq!(
        pull_request_numbers("PRs #12 and PR 7, #9"),
        HashSet::from([12, 7, 9])
    );
    assert_eq!(
        unmentioned_outcome("Pull requests: a/b#10", "see a/b#105"),
        "Pull requests: a/b#10"
    );
    assert_eq!(
        unmentioned_outcome("Pull requests: a/b#10", "see a/b#10."),
        ""
    );
    let candidate = SessionCandidate {
        block: FocusBlock {
            task: "t".into(),
            work_done: String::new(),
            status: "in_progress".into(),
            outcome: String::new(),
            next_step: String::new(),
            source_ids: Vec::new(),
        },
        name: "Review all open PRs".into(),
        project: Some("LokalBot".into()),
        pull_requests: vec![PullRequestReference {
            owner: "acme".into(),
            repository: "lokalbot".into(),
            number: 290,
        }],
    };
    let task = |title: &str| NormalizedTask {
        title: title.into(),
        status: "unknown".into(),
        summary: String::new(),
        next_step: String::new(),
    };
    assert!(describes_same_work(
        &task("LokalBot open PR review and fixes"),
        &candidate
    ));
    assert!(!describes_same_work(
        &task("LokalBot PR #17 open review"),
        &candidate
    ));
    assert!(!describes_same_work(
        &task("Other open PR review"),
        &candidate
    ));
    assert!(names_pull_request("lokalbot PR 290", &candidate));
    assert!(names_pull_request("acme/lokalbot#290", &candidate));
    assert!(!names_pull_request("other #290", &candidate));
}

#[test]
fn sessions_in_the_library_wait_for_the_users_choice() {
    let dir = tempfile::tempdir().unwrap();
    let library = Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
    let recorded = burst("from-a-mac", 10, Vec::new());
    let day = lokalbot_core::time::local_day(recorded.start);
    library.upsert_coding_agent_bursts(&[recorded]).unwrap();
    let settings_file = library.paths().settings_file();

    // A library moved from a Mac has them, with the key saved as true.
    Settings::default().save(&settings_file).unwrap();
    let evidence = DayEvidence::load(&library, day).unwrap();
    assert!(evidence.coding_agent_bursts.is_empty());

    Settings {
        coding_agent_evidence_confirmed: true,
        ..Settings::default()
    }
    .save(&settings_file)
    .unwrap();
    let evidence = DayEvidence::load(&library, day).unwrap();
    assert_eq!(evidence.coding_agent_bursts.len(), 1);
}
