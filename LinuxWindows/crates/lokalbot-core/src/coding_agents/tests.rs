use chrono::{TimeZone as _, Utc};
use serde_json::json;

use super::*;
use crate::settings::Settings;

fn at(second: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 15, 12, 0, second).unwrap()
}

fn burst(session: &str, start: DateTime<Utc>, end: DateTime<Utc>) -> CodingAgentBurst {
    CodingAgentBurst {
        actions: Vec::new(),
        active_duration: (end - start).num_seconds() as f64,
        agent: CodingAgentKind::ClaudeCode,
        branch: None,
        changed_file_count: 0,
        changed_files: Vec::new(),
        end,
        final_reply: None,
        project: "lokalbot".into(),
        prompt_count: 1,
        prompts: vec!["Fix the export".into()],
        pull_requests: Vec::new(),
        session_id: session.into(),
        start,
        title: "Export fix".into(),
        tool_call_count: 2,
    }
}

/// `JSONEncoder` with `.sortedKeys` over the Swift `CodingAgentBurst`: dates as
/// seconds since 2001, enums with associated values as `{"case":{...}}`, and a
/// `nil` optional left out.
fn mac_payload() -> serde_json::Value {
    json!({
        "actions": [
            {"commit": {"message": "Add export"}},
            {"openedPullRequest": {"title": "Export notes"}},
            {"mergedPullRequest": {"number": 42}},
            {"mergedPullRequest": {}},
            {"release": {"tag": "v1.2"}},
            {"pushed": {}},
            {"ranTests": {}}
        ],
        "activeDuration": 120.5,
        "agent": "codex",
        "changedFileCount": 3,
        "changedFiles": ["a.rs", "b.rs"],
        "end": 782_222_460.5,
        "project": "lokalbot",
        "promptCount": 2,
        "prompts": ["Add export"],
        "pullRequests": ["https://github.com/acme/lokalbot/pull/42"],
        "sessionID": "019f-session",
        "start": 782_222_340.0,
        "title": "Export notes",
        "toolCallCount": 7
    })
}

#[test]
fn decodes_what_the_mac_writes() {
    let burst: CodingAgentBurst = serde_json::from_value(mac_payload()).unwrap();
    assert_eq!(burst.agent, CodingAgentKind::Codex);
    assert_eq!(burst.session_id, "019f-session");
    assert_eq!(burst.branch, None);
    assert_eq!(burst.final_reply, None);
    assert_eq!(burst.changed_file_count, 3);
    assert_eq!(burst.tool_call_count, 7);
    assert_eq!(
        burst.actions,
        vec![
            CodingAgentAction::Commit {
                message: "Add export".into()
            },
            CodingAgentAction::OpenedPullRequest {
                title: "Export notes".into()
            },
            CodingAgentAction::MergedPullRequest { number: Some(42) },
            CodingAgentAction::MergedPullRequest { number: None },
            CodingAgentAction::Release { tag: "v1.2".into() },
            CodingAgentAction::Pushed {},
            CodingAgentAction::RanTests {},
        ]
    );
    // 2001-01-01Z plus the stored seconds.
    assert_eq!(burst.start.timestamp(), 978_307_200 + 782_222_340);
    assert_eq!(burst.id(), "codex:019f-session:1760529540");
}

#[test]
fn encodes_the_way_the_mac_encodes() {
    let burst: CodingAgentBurst = serde_json::from_value(mac_payload()).unwrap();
    let encoded = serde_json::to_string(&burst).unwrap();
    // Sorted keys, as `.sortedKeys` writes them, with absent optionals gone.
    let keys: Vec<&str> = [
        "\"actions\"",
        "\"activeDuration\"",
        "\"agent\"",
        "\"changedFileCount\"",
        "\"changedFiles\"",
        "\"end\"",
        "\"project\"",
        "\"promptCount\"",
        "\"prompts\"",
        "\"pullRequests\"",
        "\"sessionID\"",
        "\"start\"",
        "\"title\"",
        "\"toolCallCount\"",
    ]
    .to_vec();
    let mut last = 0;
    for key in keys {
        let position = last
            + encoded[last..]
                .find(key)
                .unwrap_or_else(|| panic!("{key} is out of order in {encoded}"));
        last = position;
    }
    assert!(!encoded.contains("\"branch\""));
    assert!(!encoded.contains("\"finalReply\""));
    assert!(encoded.contains(r#"{"mergedPullRequest":{}}"#));
    assert!(encoded.contains(r#"{"pushed":{}}"#));
    assert!(encoded.contains(r#"{"ranTests":{}}"#));
    assert!(encoded.contains(r#"{"mergedPullRequest":{"number":42}}"#));
    // Dates are Swift-reference seconds, not ISO text.
    let value: serde_json::Value = serde_json::from_str(&encoded).unwrap();
    assert_eq!(value["start"], json!(782_222_340.0));
    assert_eq!(value["end"], json!(782_222_460.5));
    let again: CodingAgentBurst = serde_json::from_str(&encoded).unwrap();
    assert_eq!(again, burst);
}

#[test]
fn absent_fields_decode_to_their_empty_values() {
    let burst: CodingAgentBurst = serde_json::from_value(json!({
        "agent": "claude-code",
        "sessionID": "s",
        "start": 782_222_340.0,
        "end": 782_222_460.0,
    }))
    .unwrap();
    assert!(burst.actions.is_empty() && burst.prompts.is_empty());
    assert_eq!(burst.title, "");
    assert_eq!(burst.active_duration, 0.0);
}

#[test]
fn a_store_round_trip_keeps_mac_rows_and_skips_what_it_cannot_read() {
    let dir = tempfile::tempdir().unwrap();
    let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
    let mac: CodingAgentBurst = serde_json::from_value(mac_payload()).unwrap();
    library
        .with_db(|db| {
            db.execute(
                "INSERT INTO coding_agent_bursts (id, agent, start, end, payload) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    mac.id(),
                    "codex",
                    to_epoch(mac.start),
                    to_epoch(mac.end),
                    mac_payload().to_string()
                ],
            )?;
            db.execute(
                "INSERT INTO coding_agent_bursts (id, agent, start, end, payload) VALUES ('bad', 'codex', ?1, ?2, 'not json')",
                params![to_epoch(mac.start), to_epoch(mac.end)],
            )?;
            Ok(())
        })
        .unwrap();
    let day = crate::time::local_day(mac.start);
    assert_eq!(
        library.coding_agent_bursts_on(day).unwrap(),
        vec![mac.clone()]
    );
    assert_eq!(library.coding_agent_burst_starts().unwrap().len(), 2);

    let own = burst("own", at(0), at(30));
    library
        .upsert_coding_agent_bursts(std::slice::from_ref(&own))
        .unwrap();
    assert!(
        library
            .coding_agent_bursts(at(0), at(1))
            .unwrap()
            .iter()
            .any(|b| b.is_same_as_stored(&own))
    );
    library.delete_coding_agent_bursts(&[own.id()]).unwrap();
    assert!(
        library
            .coding_agent_bursts(at(0), at(1))
            .unwrap()
            .is_empty()
    );
}

#[test]
fn deleting_saved_sessions_withdraws_generated_journals_and_nothing_else() {
    let dir = tempfile::tempdir().unwrap();
    let library = Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
    let first = burst("one", at(0), at(30));
    library
        .upsert_coding_agent_bursts(std::slice::from_ref(&first))
        .unwrap();
    let meta = serde_json::from_value(json!({
        "version": 2,
        "quality": "complete",
        "generatedAt": 800_000_000.0,
    }))
    .unwrap();
    let day = crate::time::local_day(first.start);
    library.save_digest(day, "the digest", &meta).unwrap();

    assert_eq!(library.delete_coding_agent_evidence().unwrap(), 1);
    assert!(library.coding_agent_bursts_on(day).unwrap().is_empty());
    assert!(!library.journal_path(day).exists());
    assert_eq!(crate::evidence::read_state(dir.path()).unwrap().revision, 1);
    // Nothing left to do: no further revision.
    assert_eq!(library.delete_coding_agent_evidence().unwrap(), 0);
    assert_eq!(crate::evidence::read_state(dir.path()).unwrap().revision, 1);
}

#[test]
fn reading_needs_both_the_setting_and_a_choice_the_person_made() {
    let defaults = Settings::default();
    assert!(defaults.coding_agent_evidence_enabled);
    assert!(!defaults.coding_agent_evidence_confirmed);
    assert!(defaults.enabled_coding_agents().is_empty());

    // Existing installs here, and libraries moved from a Mac, carry the key
    // as true without ever having been asked.
    let moved: Settings =
        serde_json::from_value(json!({"codingAgentEvidenceEnabled": true})).unwrap();
    assert!(moved.coding_agent_evidence_enabled);
    assert!(moved.enabled_coding_agents().is_empty());

    let chosen = Settings {
        coding_agent_evidence_confirmed: true,
        ..Settings::default()
    };
    assert_eq!(
        chosen.enabled_coding_agents(),
        vec![CodingAgentKind::ClaudeCode, CodingAgentKind::Codex]
    );
    let declined = Settings {
        coding_agent_evidence_enabled: false,
        coding_agent_evidence_confirmed: true,
        ..Settings::default()
    };
    assert!(declined.enabled_coding_agents().is_empty());
    let one_agent = Settings {
        coding_agent_evidence_confirmed: true,
        coding_agent_reads_claude_code: false,
        ..Settings::default()
    };
    assert_eq!(
        one_agent.enabled_coding_agents(),
        vec![CodingAgentKind::Codex]
    );
}

#[test]
fn the_excluded_folders_key_splits_on_commas_like_the_mac() {
    let settings = Settings {
        coding_agent_excluded_folders: " ~/work ,/opt/secret,, ".into(),
        ..Settings::default()
    };
    assert_eq!(
        settings.coding_agent_excluded_folder_list(),
        vec!["~/work".to_string(), "/opt/secret".to_string()]
    );
}

#[test]
fn a_session_is_named_by_its_work() {
    let mut named = burst("s", at(0), at(30));
    assert!(named.title_names_work());
    assert_eq!(named.work_title(), "Export fix");

    named.title = "can you add a demo to the PR?".into();
    assert!(!named.title_names_work());
    named.actions = vec![
        CodingAgentAction::Commit {
            message: "wip: first try".into(),
        },
        CodingAgentAction::Commit {
            message: "feat(export): write daily notes.".into(),
        },
    ];
    assert_eq!(named.work_title(), "Write daily notes");
    named.actions.push(CodingAgentAction::OpenedPullRequest {
        title: "fix: keep edited notes".into(),
    });
    assert_eq!(named.work_title(), "Keep edited notes");

    let mut untitled = burst("s", at(0), at(30));
    untitled.title = UNTITLED.into();
    untitled.prompts = vec!["let's commit the benchmark.".into()];
    assert_eq!(untitled.work_title(), "Commit the benchmark");
    untitled.prompts = vec!["why is this so slow?".into()];
    assert_eq!(untitled.work_title(), "Claude Code session");
    untitled.pull_requests = vec!["https://github.com/acme/app/pull/7".into()];
    assert_eq!(untitled.work_title(), "Work on PR #7");
    assert_eq!(request_title("  Fix\n the  thing "), "Fix\nthe thing");
}

#[test]
fn the_repository_names_the_project_when_the_folder_does_not() {
    let mut work = burst("s", at(0), at(30));
    work.project = "github".into();
    assert_eq!(work.work_project(), None);
    work.pull_requests = vec!["https://github.com/acme/lokalbot/pull/9".into()];
    assert_eq!(work.work_project().as_deref(), Some("lokalbot"));
    work.project = "lokalbot-port".into();
    assert_eq!(work.work_project().as_deref(), Some("lokalbot"));
    work.project = "alpha".into();
    assert_eq!(work.work_project().as_deref(), Some("alpha"));
    assert!(names_no_project("scratch-2026-10-19-6f7eb7"));
    assert!(names_no_project(UNKNOWN_PROJECT));
    assert!(!names_no_project("lokalbot"));
}

#[test]
fn worktrees_name_their_repository_on_every_platform() {
    assert_eq!(
        project_name(Some("/home/me/lokalbot/.claude/worktrees/agent-1")),
        "lokalbot"
    );
    assert_eq!(
        project_name(Some(r"C:\Users\me\lokalbot\.claude\worktrees\agent-1")),
        "lokalbot"
    );
    assert_eq!(project_name(Some(r"C:\Users\me\site")), "site");
    assert_eq!(project_name(Some("/home/me/code/./app/")), "app");
    assert_eq!(project_name(None), UNKNOWN_PROJECT);
}

#[test]
fn a_session_merges_once_and_counts_hidden_files() {
    let mut first = burst("s", at(0), at(10));
    first.changed_files = vec!["a.rs".into()];
    first.changed_file_count = 3;
    first.actions = vec![CodingAgentAction::Pushed {}];
    let mut second = burst("s", at(20), at(40));
    second.changed_files = vec!["a.rs".into(), "b.rs".into()];
    second.changed_file_count = 2;
    second.actions = vec![CodingAgentAction::Pushed {}, CodingAgentAction::RanTests {}];
    second.final_reply = Some("done".into());
    let merged = merging(&[second.clone(), first.clone()]).unwrap();
    assert_eq!(merged.start, first.start);
    assert_eq!(merged.end, second.end);
    assert_eq!(merged.prompt_count, 2);
    assert_eq!(merged.changed_file_count, 4);
    assert_eq!(merged.actions.len(), 2);
    assert_eq!(merged.final_reply.as_deref(), Some("done"));
    assert_eq!(merging(&[]), None);
    let grouped = sessions(&[first, burst("other", at(5), at(6)), second]);
    assert_eq!(grouped.len(), 2);
    assert_eq!(grouped[0].len(), 2);
}

#[test]
fn evidence_text_states_facts_and_marks_claims() {
    let mut work = burst("0123456789", at(0), at(30));
    work.branch = Some("main".into());
    work.final_reply = Some("All done".into());
    work.actions = vec![CodingAgentAction::MergedPullRequest { number: Some(4) }];
    let text = work.evidence_text(3);
    assert!(text.starts_with("WORK SOURCE: AGENT SESSION [agent:claude-code:01234567]"));
    assert!(text.contains("Project: lokalbot (branch main)"));
    assert!(text.contains("Recorded actions: merged PR #4"));
    assert!(text.contains("Agent's final report (a claim; corroborate with actions): All done"));

    work.prompts = vec!["Scheduled task: nightly".into()];
    let scheduled = work.evidence_text(3);
    assert!(work.is_scheduled_run());
    assert!(scheduled.contains("Scheduled run: its report is omitted"));
    assert!(!scheduled.contains("All done"));
}

#[test]
fn only_settled_bursts_count_and_edge_rounding_is_not_a_change() {
    let work = burst("s", at(0), at(30));
    assert!(!work.is_settled(at(30) + chrono::Duration::minutes(9)));
    assert!(work.is_settled(at(30) + chrono::Duration::minutes(10)));

    let mut rounded = work.clone();
    rounded.start += chrono::Duration::nanoseconds(100);
    rounded.active_duration += 0.000_1;
    assert!(work.is_same_as_stored(&rounded));
    rounded.title = "Renamed".into();
    assert!(!work.is_same_as_stored(&rounded));
    assert!(work.has_same_work(&rounded));
    rounded.prompts = vec!["Something else".into()];
    assert!(!work.has_same_work(&rounded));
}

#[test]
fn signature_fields_follow_the_mac_order() {
    let work = burst("s", at(0), at(30));
    let fields = work.signature_fields();
    assert_eq!(fields.len(), 17);
    assert_eq!(fields[0], work.id());
    assert_eq!(fields[1], "claude-code");
    assert_eq!(fields[6], "1792065600.0");
    assert_eq!(fields[10], "1");
}

#[test]
fn hosts_cover_each_platforms_terminals_and_outcomes_count_once() {
    use attribution::{Outcomes, hosts};
    assert!(hosts("Konsole", CodingAgentKind::Codex));
    assert!(hosts("WindowsTerminal", CodingAgentKind::ClaudeCode));
    assert!(hosts("Claude", CodingAgentKind::ClaudeCode));
    assert!(!hosts("Claude", CodingAgentKind::Codex));
    assert!(!hosts("Slack", CodingAgentKind::ClaudeCode));
    let mut work = burst("s", at(0), at(30));
    work.actions = vec![
        CodingAgentAction::Commit {
            message: "a".into(),
        },
        CodingAgentAction::MergedPullRequest { number: None },
        CodingAgentAction::OpenedPullRequest { title: "t".into() },
        CodingAgentAction::Pushed {},
    ];
    let outcomes = Outcomes::of([&work]);
    assert_eq!(outcomes.commits, 1);
    assert_eq!(outcomes.merged_pull_requests, 1);
    assert_eq!(outcomes.opened_pull_requests, vec!["t".to_string()]);
    assert!(Outcomes::of([]).is_empty());
}
