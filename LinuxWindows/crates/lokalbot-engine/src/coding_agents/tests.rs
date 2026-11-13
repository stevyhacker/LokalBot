use std::fs;
use std::path::{Path, PathBuf};

use chrono::{Duration, TimeZone as _};
use lokalbot_core::LibraryPaths;
use lokalbot_core::coding_agents::CodingAgentAction;
use serde_json::json;

use super::builder::{Event, EventKind, Transcript, compacting_activity};
use super::*;

fn iso(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// Noon local time `days` days ago, so a scan's window always holds it.
fn noon(days: i64) -> DateTime<Utc> {
    let day = Local::now().date_naive() - Duration::days(days);
    Local
        .from_local_datetime(&day.and_hms_opt(12, 0, 0).unwrap())
        .single()
        .unwrap()
        .with_timezone(&Utc)
}

/// Transcript stamps have no finer detail than this needs.
fn whole_second_now() -> DateTime<Utc> {
    Utc.timestamp_opt(Utc::now().timestamp(), 0).unwrap()
}

fn write_lines(path: &Path, lines: &[serde_json::Value]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let body: String = lines.iter().map(|line| format!("{line}\n")).collect();
    fs::write(path, body).unwrap();
}

fn claude_user(at: DateTime<Utc>, uuid: &str, text: &str) -> serde_json::Value {
    json!({
        "type": "user", "uuid": uuid, "timestamp": iso(at), "cwd": "/home/me/GitHub/app",
        "gitBranch": "main", "message": {"role": "user", "content": text},
    })
}

fn claude_assistant(at: DateTime<Utc>, uuid: &str, blocks: serde_json::Value) -> serde_json::Value {
    json!({
        "type": "assistant", "uuid": uuid, "timestamp": iso(at), "cwd": "/home/me/GitHub/app",
        "gitBranch": "main", "message": {"role": "assistant", "content": blocks},
    })
}

fn chosen() -> Settings {
    Settings {
        coding_agent_evidence_confirmed: true,
        ..Settings::default()
    }
}

fn library(dir: &Path) -> Library {
    Library::open(LibraryPaths::new(dir.join("library"))).unwrap()
}

fn claude_session(home: &Path, name: &str) -> PathBuf {
    home.join(".claude/projects/-home-me-GitHub-app")
        .join(format!("{name}.jsonl"))
}

fn scan_today(home: &Path, settings: &Settings) -> DayScan {
    let configuration = Configuration::new(settings);
    let today = Local::now().date_naive();
    Scanner::standard(home, &configuration.agents, configuration.excluded_folders).scan(
        today - chrono::Duration::days(WINDOW_DAYS - 1),
        today,
        None,
    )
}

#[test]
fn claude_sessions_keep_requests_actions_and_files_but_no_tool_output() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let at = noon(1);
    let session = claude_session(home, "session-1");
    write_lines(
        &session,
        &[
            json!({"type": "ai-title", "aiTitle": "Automatic title"}),
            json!({"type": "custom-title", "customTitle": "Export the notes"}),
            claude_user(
                at,
                "u1",
                "Fix the export <system-reminder>secret context</system-reminder>",
            ),
            claude_assistant(
                at + Duration::seconds(10),
                "a1",
                json!([
                    {"type": "text", "text": "Working on it."},
                    {"type": "tool_use", "name": "Edit", "input": {"file_path": "/home/me/GitHub/app/src/export.rs"}},
                    {"type": "tool_use", "name": "Bash", "input": {
                        "command": "cargo test && git commit -m \"Add the export\" && git push && gh pr create --title 'Export notes' https://github.com/acme/app/pull/12"
                    }},
                ]),
            ),
            json!({
                "type": "user", "uuid": "u2", "timestamp": iso(at + Duration::seconds(20)),
                "message": {"content": [{"type": "tool_result", "content": "FILE CONTENTS MUST NOT SURVIVE"}]},
            }),
            json!({"type": "user", "uuid": "side", "isSidechain": true, "timestamp": iso(at), "message": {"content": "a subagent prompt"}}),
            json!({"type": "user", "uuid": "meta", "isMeta": true, "timestamp": iso(at), "message": {"content": "meta"}}),
            json!({"type": "user", "uuid": "compact", "isCompactSummary": true, "timestamp": iso(at), "message": {"content": "summary"}}),
            json!({"type": "pr-link", "prUrl": "https://github.com/acme/app/pull/12", "timestamp": iso(at + Duration::seconds(30))}),
        ],
    );
    let scan = scan_today(home, &chosen());
    assert_eq!(scan.bursts.len(), 1, "{scan:?}");
    let burst = &scan.bursts[0];
    assert_eq!(burst.title, "Export the notes");
    assert_eq!(burst.session_id, "session-1");
    assert_eq!(burst.project, "app");
    assert_eq!(burst.branch.as_deref(), Some("main"));
    assert_eq!(burst.prompts, vec!["Fix the export".to_string()]);
    assert_eq!(burst.final_reply.as_deref(), Some("Working on it."));
    assert_eq!(burst.changed_files, vec!["src/export.rs".to_string()]);
    assert_eq!(burst.tool_call_count, 2);
    assert_eq!(
        burst.pull_requests,
        vec!["https://github.com/acme/app/pull/12".to_string()]
    );
    assert!(burst.actions.contains(&CodingAgentAction::Commit {
        message: "Add the export".into()
    }));
    assert!(burst.actions.contains(&CodingAgentAction::Pushed {}));
    assert!(burst.actions.contains(&CodingAgentAction::RanTests {}));
    assert!(
        burst
            .actions
            .contains(&CodingAgentAction::OpenedPullRequest {
                title: "Export notes".into()
            })
    );
    let stored = serde_json::to_string(burst).unwrap();
    assert!(!stored.contains("FILE CONTENTS"));
    assert!(!stored.contains("secret context"));
    assert!(!stored.contains("subagent"));
}

#[test]
fn subagent_folders_copied_records_and_consulted_replies_stay_out() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let at = noon(1);
    // A subagent transcript in the session's own subfolder is not read.
    let nested = home.join(".claude/projects/-home-me-GitHub-app/session-1/subagents/one.jsonl");
    write_lines(&nested, &[claude_user(at, "n1", "subagent work")]);
    let first = claude_session(home, "first");
    write_lines(
        &first,
        &[
            claude_user(at, "shared", "The original request"),
            claude_assistant(
                at + Duration::seconds(5),
                "shared-2",
                json!([{"type": "tool_use", "name": "mcp__lokalbot__search", "input": {}},
                       {"type": "text", "text": "What the library said"}]),
            ),
        ],
    );
    // A forked session copies the records it inherited under their own ids.
    let forked = claude_session(home, "forked");
    write_lines(
        &forked,
        &[
            claude_user(at, "shared", "The original request"),
            claude_user(at + Duration::seconds(30), "fresh", "The new request"),
        ],
    );
    let scan = scan_today(home, &chosen());
    let all: Vec<String> = scan.bursts.iter().flat_map(|b| b.prompts.clone()).collect();
    assert_eq!(
        all.iter().filter(|p| *p == "The original request").count(),
        1
    );
    assert!(all.contains(&"The new request".to_string()));
    assert!(!all.contains(&"subagent work".to_string()));
    // The session read LokalBot's library, so its replies are withheld.
    assert!(scan.bursts.iter().all(|b| b.final_reply.is_none()));
}

#[test]
fn codex_rollouts_read_only_what_they_should() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let at = noon(1);
    let rollout = home.join(".codex/sessions/2026/10/15/rollout-1.jsonl");
    write_lines(
        &rollout,
        &[
            json!({"type": "session_meta", "timestamp": iso(at), "payload": {
                "id": "thread-1", "cwd": "/home/me/GitHub/app", "source": "cli", "git": {"branch": "feature"},
            }}),
            json!({"type": "response_item", "timestamp": iso(at), "payload": {
                "type": "message", "role": "user", "content": [
                    {"type": "input_text", "text": "# AGENTS.md instructions for the repo"},
                    {"type": "input_text", "text": "IDE context ## My request for Codex: Add a CLI flag"},
                ],
            }}),
            json!({"type": "response_item", "timestamp": iso(at + Duration::seconds(5)), "payload": {
                "type": "function_call", "name": "shell", "arguments": "{\"command\":[\"/bin/zsh\",\"-lc\",\"git commit -m 'Add flag'\"]}",
            }}),
            json!({"type": "response_item", "timestamp": iso(at + Duration::seconds(6)), "payload": {
                "type": "function_call_output", "output": "OUTPUT MUST NOT SURVIVE",
            }}),
            json!({"type": "response_item", "timestamp": iso(at + Duration::seconds(7)), "payload": {
                "type": "custom_tool_call", "name": "apply_patch",
                "input": "*** Begin Patch\n*** Update File: /home/me/GitHub/app/src/cli.rs\n*** End Patch",
            }}),
            json!({"type": "event_msg", "timestamp": iso(at + Duration::seconds(8)), "payload": {
                "type": "item_completed", "item": {"type": "FileChange", "changes": {
                    "/home/me/GitHub/app/b.rs": {"diff": "DIFF MUST NOT SURVIVE"},
                }},
            }}),
            json!({"type": "response_item", "timestamp": iso(at + Duration::seconds(9)), "payload": {
                "type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Done."}],
            }}),
        ],
    );
    // A guardian thread reports through its parent.
    let reviewer = home.join(".codex/archived_sessions/rollout-2.jsonl");
    write_lines(
        &reviewer,
        &[
            json!({"type": "session_meta", "timestamp": iso(at), "payload": {
                "id": "thread-2", "source": {"subagent": {"other": "guardian"}},
            }}),
            json!({"type": "response_item", "timestamp": iso(at), "payload": {
                "type": "message", "role": "user", "content": [{"type": "input_text", "text": "Review this"}],
            }}),
        ],
    );
    let index = home.join(".codex/session_index.jsonl");
    write_lines(
        &index,
        &[
            json!({"id": "thread-1", "thread_name": "First name"}),
            json!({"id": "thread-1", "thread_name": "Renamed"}),
        ],
    );
    // Codex's credentials and database are never parsed, whatever they hold.
    fs::write(home.join(".codex/auth.json"), "{\"token\":\"not read\"}").unwrap();
    let scan = scan_today(home, &chosen());
    assert_eq!(scan.bursts.len(), 1, "{scan:?}");
    let burst = &scan.bursts[0];
    assert_eq!(burst.session_id, "thread-1");
    assert_eq!(burst.title, "Renamed");
    assert_eq!(burst.branch.as_deref(), Some("feature"));
    assert_eq!(burst.prompts, vec!["Add a CLI flag".to_string()]);
    assert_eq!(burst.final_reply.as_deref(), Some("Done."));
    assert_eq!(
        burst.changed_files,
        vec!["src/cli.rs".to_string(), "b.rs".to_string()]
    );
    assert_eq!(
        burst.actions,
        vec![CodingAgentAction::Commit {
            message: "Add flag".into()
        }]
    );
    let stored = serde_json::to_string(burst).unwrap();
    assert!(!stored.contains("MUST NOT SURVIVE"));
}

#[test]
fn nothing_is_read_until_the_person_has_chosen() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let at = whole_second_now();
    let session = claude_session(&home, "session-1");
    write_lines(&session, &[claude_user(at, "u1", "Do the work")]);
    let library = library(dir.path());
    let now = at + Duration::hours(1);
    let ingestor = Ingestor::default();

    // Saved as true on every existing install, without ever having been asked.
    let unconfirmed = Settings::default();
    assert!(unconfirmed.coding_agent_evidence_enabled);
    let changed = ingestor.refresh_from(&library, &home, || unconfirmed.clone(), None, now);
    assert!(changed.is_empty());
    assert!(library.coding_agent_bursts(at, now).unwrap().is_empty());
    // A library moved from a Mac starts the same way.
    let moved: Settings =
        serde_json::from_value(json!({"codingAgentEvidenceEnabled": true})).unwrap();
    ingestor.refresh_from(&library, &home, || moved.clone(), None, now);
    assert!(library.coding_agent_bursts(at, now).unwrap().is_empty());
    // Choosing off stays off.
    let declined = Settings {
        coding_agent_evidence_enabled: false,
        ..chosen()
    };
    ingestor.refresh_from(&library, &home, || declined.clone(), None, now);
    assert!(library.coding_agent_bursts(at, now).unwrap().is_empty());
    // The unconfirmed gate returns before any transcript is parsed.
    assert!(ingestor.cache.state_count() == 0);

    let changed = ingestor.refresh_from(&library, &home, chosen, None, now);
    assert_eq!(changed, vec![local_day(at)]);
    assert_eq!(library.coding_agent_bursts(at, now).unwrap().len(), 1);
    // The agent's files are read, never written.
    assert_eq!(fs::read_dir(session.parent().unwrap()).unwrap().count(), 1);
}

#[test]
fn only_settled_work_is_stored_and_additions_dont_touch_a_digest() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let at = whole_second_now();
    write_lines(
        &claude_session(&home, "session-1"),
        &[claude_user(at, "u1", "Do the work")],
    );
    let library = library(dir.path());
    let ingestor = Ingestor::default();
    let early = at + Duration::minutes(5);
    ingestor.refresh_from(&library, &home, chosen, None, early);
    assert!(library.coding_agent_bursts(at, early).unwrap().is_empty());
    let later = at + Duration::minutes(11);
    ingestor.refresh_from(&library, &home, chosen, None, later);
    assert_eq!(library.coding_agent_bursts(at, later).unwrap().len(), 1);
    // A plain addition advances no evidence.
    let state = lokalbot_core::evidence::read_state(library.paths().root()).unwrap();
    assert_eq!(state.revision, 0);
    // Scanning again with nothing new changes nothing.
    assert!(
        ingestor
            .refresh_from(&library, &home, chosen, None, later)
            .is_empty()
    );
    assert_eq!(
        lokalbot_core::evidence::read_state(library.paths().root())
            .unwrap()
            .revision,
        0
    );
}

#[test]
fn a_removed_session_withdraws_but_an_unreadable_one_does_not() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let at = noon(1);
    let session = claude_session(&home, "session-1");
    write_lines(&session, &[claude_user(at, "u1", "Do the work")]);
    let library = library(dir.path());
    let configuration = Configuration::new(&chosen());
    let later = at + Duration::hours(1);
    let scan = scan_today(&home, &chosen());
    apply_scan(&library, &scan, &configuration, later).unwrap();
    assert_eq!(library.coding_agent_bursts(at, later).unwrap().len(), 1);

    // An unreadable file says nothing about what was deleted.
    let unreadable = DayScan {
        bursts: Vec::new(),
        unreadable_files: vec!["/gone".into()],
        start: scan.start,
        end: scan.end,
        session_count: 0,
        files_read: 0,
        bytes_read: 0,
        excluded_sessions: 0,
    };
    assert!(
        apply_scan(&library, &unreadable, &configuration, later)
            .unwrap()
            .is_empty()
    );
    assert_eq!(library.coding_agent_bursts(at, later).unwrap().len(), 1);

    // A deleted session is removed, as a revision.
    fs::remove_file(&session).unwrap();
    let scan = scan_today(&home, &chosen());
    let changed = apply_scan(&library, &scan, &configuration, later).unwrap();
    assert_eq!(changed, vec![local_day(at)]);
    assert!(library.coding_agent_bursts(at, later).unwrap().is_empty());
    let state = lokalbot_core::evidence::read_state(library.paths().root()).unwrap();
    assert_eq!(state.revision, 1);
    assert!(state.invalidated_days.is_empty());
}

#[test]
fn an_excluded_folder_is_skipped_and_withdraws_what_was_stored() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let at = noon(1);
    write_lines(
        &claude_session(&home, "session-1"),
        &[claude_user(at, "u1", "Do the work")],
    );
    let library = library(dir.path());
    let later = at + Duration::hours(1);
    let scan = scan_today(&home, &chosen());
    apply_scan(&library, &scan, &Configuration::new(&chosen()), later).unwrap();

    let excluding = Settings {
        coding_agent_excluded_folders: "/home/me/GitHub/app/".into(),
        ..chosen()
    };
    let scan = scan_today(&home, &excluding);
    assert_eq!(scan.excluded_sessions, 1);
    assert!(scan.bursts.is_empty());
    apply_scan(&library, &scan, &Configuration::new(&excluding), later).unwrap();
    assert!(library.coding_agent_bursts(at, later).unwrap().is_empty());

    let scanner = Scanner::standard(
        Path::new("/home/me"),
        &[],
        vec![
            "~/secret".into(),
            "/".into(),
            "".into(),
            r"C:\Work\Private".into(),
        ],
    );
    assert!(scanner.is_excluded(Some("/home/me/secret")));
    assert!(scanner.is_excluded(Some("/home/me/secret/sub/./dir")));
    assert!(!scanner.is_excluded(Some("/home/me/secret-other")));
    assert!(!scanner.is_excluded(Some("/elsewhere")));
    assert!(!scanner.is_excluded(None));
    assert!(scanner.is_excluded(Some(r"c:\work\private\repo")));
    assert!(!scanner.is_excluded(Some(r"C:\Work\Public")));
}

#[test]
fn a_finished_day_keeps_its_bursts_when_only_the_label_changed() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let at = noon(2);
    let later = noon(0);
    let burst = CodingAgentBurst {
        actions: Vec::new(),
        active_duration: 60.0,
        agent: CodingAgentKind::ClaudeCode,
        branch: Some("main".into()),
        changed_file_count: 0,
        changed_files: Vec::new(),
        end: at + Duration::minutes(1),
        final_reply: None,
        project: "app".into(),
        prompt_count: 1,
        prompts: vec!["Work".into()],
        pull_requests: Vec::new(),
        session_id: "s".into(),
        start: at,
        title: "Old name".into(),
        tool_call_count: 0,
    };
    library
        .upsert_coding_agent_bursts(std::slice::from_ref(&burst))
        .unwrap();
    let scan_of = |bursts: Vec<CodingAgentBurst>| DayScan {
        start: at - Duration::days(1),
        end: later + Duration::days(1),
        bursts,
        session_count: 1,
        files_read: 1,
        bytes_read: 1,
        unreadable_files: Vec::new(),
        excluded_sessions: 0,
    };
    let configuration = Configuration::new(&chosen());
    let renamed = CodingAgentBurst {
        title: "New name".into(),
        branch: Some("other".into()),
        ..burst.clone()
    };
    assert!(
        apply_scan(&library, &scan_of(vec![renamed]), &configuration, later)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        library.coding_agent_bursts(at, later).unwrap()[0].title,
        "Old name"
    );
    // Today's burst follows its session's name.
    let today = noon(0) - Duration::hours(2);
    let current = CodingAgentBurst {
        start: today,
        end: today + Duration::minutes(1),
        ..burst.clone()
    };
    library
        .upsert_coding_agent_bursts(std::slice::from_ref(&current))
        .unwrap();
    let renamed_today = CodingAgentBurst {
        title: "New name".into(),
        ..current
    };
    apply_scan(
        &library,
        &scan_of(vec![burst.clone(), renamed_today]),
        &configuration,
        later,
    )
    .unwrap();
    assert_eq!(
        library.coding_agent_bursts(today, later).unwrap()[0].title,
        "New name"
    );
    // Changed work on a finished day replaces the stored burst.
    let changed = CodingAgentBurst {
        prompts: vec!["Different work".into()],
        ..burst.clone()
    };
    apply_scan(
        &library,
        &scan_of(vec![changed]),
        &Configuration::new(&chosen()),
        later,
    )
    .unwrap();
    assert_eq!(
        library
            .coding_agent_bursts(at, at + Duration::minutes(2))
            .unwrap()[0]
            .prompts,
        vec!["Different work".to_string()]
    );
}

#[test]
fn a_refresh_parses_only_appended_lines_and_rereads_a_rewritten_file() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let at = noon(1);
    let session = claude_session(home, "session-1");
    write_lines(&session, &[claude_user(at, "u1", "First request")]);
    let configuration = Configuration::new(&chosen());
    let scanner = Scanner::standard(home, &configuration.agents, Vec::new());
    let today = Local::now().date_naive();
    let window = today - chrono::Duration::days(6);
    let cache = ParseCache::default();
    let first = scanner.scan(window, today, Some(&cache));
    assert_eq!(first.files_read, 1);
    assert_eq!(first.bursts[0].prompt_count, 1);
    // Nothing changed: the file isn't opened.
    let second = scanner.scan(window, today, Some(&cache));
    assert_eq!(second.files_read, 0);
    assert_eq!(second.bursts, first.bursts);
    // Only the appended bytes are read, and a half-written line counts for this
    // scan only.
    let before = fs::metadata(&session).unwrap().len();
    let appended = format!(
        "{}\n",
        claude_user(at + Duration::seconds(30), "u2", "Second request")
    );
    let half = claude_user(at + Duration::seconds(40), "u3", "Third request").to_string();
    let mut body = fs::read_to_string(&session).unwrap();
    body.push_str(&appended);
    body.push_str(&half);
    fs::write(&session, &body).unwrap();
    let third = scanner.scan(window, today, Some(&cache));
    assert_eq!(third.bytes_read, body.len() as u64 - before);
    assert_eq!(third.bursts[0].prompt_count, 3);
    // The rest of the line arrives; the request isn't counted twice.
    body.push('\n');
    fs::write(&session, &body).unwrap();
    let fourth = scanner.scan(window, today, Some(&cache));
    assert_eq!(fourth.bursts[0].prompt_count, 3);
    // A rewritten file starts over.
    write_lines(&session, &[claude_user(at, "u9", "Only this now")]);
    let fifth = scanner.scan(window, today, Some(&cache));
    assert_eq!(fifth.bursts[0].prompts, vec!["Only this now".to_string()]);
    assert_eq!(fifth.bursts[0].prompt_count, 1);
    // A later window drops what it no longer needs, and reaching back past what
    // was kept parses the file again.
    assert!(scanner.scan(today, today, Some(&cache)).bursts.is_empty());
    let widened = scanner.scan(window, today, Some(&cache));
    assert_eq!(widened.files_read, 1);
    assert_eq!(widened.bursts, fifth.bursts);
}

#[test]
fn bursts_split_on_inactivity_and_never_cross_midnight() {
    let at = noon(1);
    let event = |offset: i64, kind: EventKind| Event::new(at + Duration::minutes(offset), kind);
    let transcript = Transcript {
        agent: CodingAgentKind::Codex,
        session_id: "s".into(),
        title: None,
        working_directory: Some("/home/me/app".into()),
        branch: None,
        consulted_lokalbot: false,
        events: vec![
            event(0, EventKind::Prompt("First".into())),
            event(9, EventKind::Activity),
            event(30, EventKind::Prompt("Second".into())),
            event(
                31,
                EventKind::PullRequest("https://github.com/a/b/pull/1".into()),
            ),
            // A link written when nothing was running joins nothing.
            event(
                90,
                EventKind::PullRequest("https://github.com/a/b/pull/2".into()),
            ),
            // Only activity makes no burst.
            event(200, EventKind::Activity),
        ],
    };
    let bursts = builder::bursts(&transcript);
    assert_eq!(bursts.len(), 2);
    assert_eq!(bursts[0].title, "First");
    assert_eq!(bursts[0].active_duration, 300.0);
    assert_eq!(bursts[1].pull_requests.len(), 1);

    // A burst of one event has no active time, and says so as the Mac does.
    let single = Transcript {
        events: vec![event(0, EventKind::Prompt("Only".into()))],
        ..transcript.clone()
    };
    let only = &builder::bursts(&single)[0];
    assert!(only.active_duration.is_sign_positive());
    assert!(
        serde_json::to_string(only)
            .unwrap()
            .contains(r#""activeDuration":0.0"#)
    );

    // Compaction keeps the same bursts.
    let compacted = compacting_activity(&transcript.events);
    let again = Transcript {
        events: compacted,
        ..transcript.clone()
    };
    assert_eq!(builder::bursts(&again), bursts);

    // Compaction keeps a ping between two days.
    let midnight = local_day_bounds(Local::now().date_naive()).0;
    let across = vec![
        Event::new(
            midnight - Duration::seconds(30),
            EventKind::Prompt("Late".into()),
        ),
        Event::new(midnight - Duration::seconds(1), EventKind::Activity),
        Event::new(
            midnight + Duration::seconds(10),
            EventKind::Prompt("Early".into()),
        ),
    ];
    assert_eq!(compacting_activity(&across).len(), 3);
}

#[test]
fn text_rules_match_the_mac() {
    use text::*;
    assert_eq!(prompt("<system-reminder>x</system-reminder>"), None);
    assert_eq!(prompt("Caveat: messages below"), None);
    assert_eq!(prompt("[Request interrupted by user]"), None);
    assert_eq!(
        prompt("<command-name>/code-review</command-name><command-args>high</command-args>")
            .as_deref(),
        Some("/code-review high")
    );
    assert_eq!(prompt("<command-name>/fast</command-name>"), None);
    assert_eq!(
        prompt("<bash-input>git status</bash-input><bash-stdout>noise</bash-stdout>").as_deref(),
        Some("Ran in terminal: git status")
    );
    assert_eq!(
        prompt("<heartbeat>x<automation_id> nightly </automation_id></heartbeat>").as_deref(),
        Some("Scheduled automation: nightly")
    );
    assert_eq!(
        prompt(r#"<scheduled-task name="digest">body</scheduled-task>"#).as_deref(),
        Some("Scheduled task: digest")
    );
    assert_eq!(
        prompt("look at <pasted_content id=1>long paste</pasted_content> please").as_deref(),
        Some("look at [pasted text] please")
    );
    // An unclosed harness tag is still harness text; HTML a person pasted isn't.
    assert_eq!(prompt("<ide-opened-file>src/a.rs"), None);
    assert_eq!(
        prompt("Why is <div>x</div> wrong").as_deref(),
        Some("Why is <div>x</div> wrong")
    );
    assert_eq!(
        prompt("Rotate password=hunter2secret now").as_deref(),
        Some("Rotate password=[REDACTED] now")
    );
    let long = "word ".repeat(200);
    assert!(prompt(&long).unwrap().chars().count() <= PROMPT_CHARACTERS);
    assert!(reply(&long).unwrap().chars().count() <= REPLY_CHARACTERS);
    assert!(title(&long).unwrap().chars().count() <= TITLE_CHARACTERS);

    assert_eq!(
        actions_in_command(
            r#"["/bin/zsh","-lc","gh pr merge 12 && gh release create v1.2 --notes x"]"#
        ),
        vec![
            CodingAgentAction::MergedPullRequest { number: Some(12) },
            CodingAgentAction::Release { tag: "v1.2".into() },
        ]
    );
    assert_eq!(
        actions_in_command("gh pr merge https://github.com/a/b/pull/7"),
        vec![CodingAgentAction::MergedPullRequest { number: Some(7) }]
    );
    assert_eq!(
        actions_in_command("gh pr merge"),
        vec![CodingAgentAction::MergedPullRequest { number: None }]
    );
    assert_eq!(
        actions_in_command("git commit -m \"$(cat <<'EOF'\nAdd the flag\n\nBody\nEOF\n)\""),
        vec![CodingAgentAction::Commit {
            message: "Add the flag".into()
        }]
    );
    assert_eq!(
        actions_in_command("git -C /tmp/x push origin main"),
        vec![CodingAgentAction::Pushed {}]
    );
    assert_eq!(
        actions_in_command("pnpm run test"),
        vec![CodingAgentAction::RanTests {}]
    );
    // The UI-test runner moved to Scripts/test/; older sessions still name the old path.
    for command in [
        "Scripts/test/ui-tests.sh --remote",
        "bash Scripts/ui-tests.sh --remote",
    ] {
        assert_eq!(
            actions_in_command(command),
            vec![CodingAgentAction::RanTests {}]
        );
    }
    assert!(actions_in_command("ls -la").is_empty());
    assert!(reads_lokalbot_command("lokalbot-cli search foo"));
    assert!(reads_lokalbot_command("cd x; lokalbot get abc"));
    assert!(!reads_lokalbot_command("cd lokalbot && ls"));
    assert!(reads_lokalbot_tool("mcp__LokalBot__search"));
    assert_eq!(
        pull_request_urls("see https://github.com/a/b/pull/1 and https://github.com/a/b/pull/1"),
        vec!["https://github.com/a/b/pull/1".to_string()]
    );
}

#[test]
fn changed_files_read_as_the_person_would_name_them() {
    use text::display_path_in as name;
    let home = Some("/home/me");
    assert_eq!(
        name("/home/me/app/src/a.rs", Some("/home/me/app"), home),
        "src/a.rs"
    );
    assert_eq!(
        name(
            "/home/me/app/.claude/worktrees/x/src/a.rs",
            Some("/home/me/app"),
            home
        ),
        "src/a.rs"
    );
    assert_eq!(
        name("/home/me/.codex/worktrees/ab12/app/src/a.rs", None, home),
        "src/a.rs"
    );
    assert_eq!(
        name(
            "/tmp/claude-1000/slug/12345678-1234-1234-1234-123456789012/scratchpad/n.md",
            None,
            home
        ),
        "scratchpad/n.md"
    );
    assert_eq!(
        name("/home/me/notes/a.md", Some("/home/me/app"), home),
        "~/notes/a.md"
    );
    assert_eq!(name("/etc/hosts", None, home), "/etc/hosts");
    assert_eq!(
        name(
            r"C:\Users\me\app\src\a.rs",
            Some(r"c:\users\me\app"),
            Some("C:/Users/me")
        ),
        "src/a.rs"
    );
    assert_eq!(
        name(
            r"C:\Users\me\app\.claude\worktrees\x\src\a.rs",
            None,
            Some("C:/Users/me")
        ),
        "src/a.rs"
    );
    assert_eq!(
        text::standardized_path("~/a/../b/./c", home),
        "/home/me/b/c"
    );
    assert_eq!(text::standardized_path("/a//b/", None), "/a/b");
}

#[test]
fn lines_are_classified_without_decoding_them() {
    let line = text::Line(br#"{"type":"user","timestamp":"2026-10-01T10:00:00.5Z","uuid":"x"}"#);
    assert!(line.prefix_contains(30, r#""type":"user""#));
    assert!(!line.prefix_contains(5, r#""type":"user""#));
    assert_eq!(line.string_value("uuid").as_deref(), Some("x"));
    assert_eq!(line.string_value("missing"), None);
    let at = text::timestamp(&line.string_value("timestamp").unwrap()).unwrap();
    assert_eq!(
        at,
        Utc.with_ymd_and_hms(2026, 10, 1, 10, 0, 0).unwrap() + Duration::milliseconds(500)
    );
    assert_eq!(text::timestamp("yesterday"), None);
    assert!(text::Line(b"[1,2]").object().is_none());
}

#[test]
fn a_windows_folder_rule_under_home_matches_its_sessions() {
    let home = Some(r"C:\Users\Ana");
    let folder = text::standardized_path(r"~\Code\client", home);
    assert_eq!(folder, "C:/Users/Ana/Code/client");
    let session = text::standardized_path(r"C:\Users\Ana\Code\client\app", home);
    assert!(text::is_inside(&session, &folder));
    // Windows paths compare without case, and a sibling isn't inside.
    let other_case = text::standardized_path(r"c:\users\ana\code\CLIENT", home);
    assert!(text::is_inside(&other_case, &folder));
    let sibling = text::standardized_path(r"C:\Users\Ana\Code\client-two", home);
    assert!(!text::is_inside(&sibling, &folder));
}
