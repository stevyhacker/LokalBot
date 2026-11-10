//! The real binary against a seeded demo library and the macOS fixture.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use lokalbot_core::{LibraryPaths, access, demo};
#[cfg(unix)]
use serde_json::Value;

fn seeded() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    demo::seed(&LibraryPaths::new(&root), chrono::Utc::now()).unwrap();
    (dir, root)
}

fn cli(root: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_lokalbot-cli"))
        .args(args)
        .env("LOKALBOT_STORAGE_ROOT", root)
        .env_remove(access::CAPABILITY_ENV)
        .output()
        .unwrap()
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// Every file under `meetings/` with its size and modification time.
fn snapshot(root: &Path) -> Vec<(PathBuf, u64, std::time::SystemTime)> {
    let mut out = Vec::new();
    let mut stack = vec![root.join("meetings")];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(dir).unwrap().flatten() {
            let path = entry.path();
            let metadata = entry.metadata().unwrap();
            if metadata.is_dir() {
                stack.push(path);
            } else {
                out.push((path, metadata.len(), metadata.modified().unwrap()));
            }
        }
    }
    out.sort();
    out
}

#[test]
fn commands_honor_the_access_gate() {
    let (_dir, root) = seeded();
    let output = cli(&root, &["list", "--table"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("External agent access is off"));
    // Each source that is off answers with the code the skill tells agents
    // to look for, as its MCP tool does.
    for (command, code) in [
        (&["list"][..], "access_disabled"),
        (&["search-files", "invoice"][..], "files_access_disabled"),
        (
            &["personal-context", "--task", "Plan a trip"][..],
            "personal_context_disabled",
        ),
    ] {
        let output = cli(&root, command);
        assert_eq!(output.status.code(), Some(1), "{command:?}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.starts_with(&format!("Error: [{code}] ")),
            "{command:?}: {stderr}"
        );
    }
    let brief = cli(&root, &["brief"]);
    assert!(brief.status.success());
    assert!(stdout(&brief).contains("- Meetings: off."));
}

#[test]
fn list_get_search_actions_and_people() {
    let (_dir, root) = seeded();
    access::set_meetings_access(&LibraryPaths::new(&root), true).unwrap();
    let before = snapshot(&root);

    let table = stdout(&cli(&root, &["list", "--table"]));
    assert!(table.starts_with("ID        Date"), "{table}");
    assert!(table.contains("Holiday shoot planning"));
    assert_eq!(table.lines().count(), 2 + 17);

    let json: serde_json::Value =
        serde_json::from_str(&stdout(&cli(&root, &["get", "latest", "--format", "json"]))).unwrap();
    assert_eq!(json["uuid"], "55555555-5555-4555-8555-555555555555");
    assert_eq!(json["id"], "55555555");
    assert!(json["summary"].as_str().unwrap().contains("## TL;DR"));
    assert!(
        json["transcript"]
            .as_str()
            .unwrap()
            .contains("**[00:00:12] Maya Chen:**")
    );
    assert!(
        json["folder"]
            .as_str()
            .unwrap()
            .ends_with("holiday-shoot-planning")
    );

    let markdown = stdout(&cli(
        &root,
        &["get", "5555", "--include", "metadata,transcript"],
    ));
    assert!(markdown.starts_with("# Holiday shoot planning\n**Date:** "));
    assert!(markdown.contains("## Transcript") && !markdown.contains("## Summary"));

    let hits: serde_json::Value =
        serde_json::from_str(&stdout(&cli(&root, &["search", "softbox"]))).unwrap();
    let hits = hits.as_array().unwrap();
    assert!(!hits.is_empty());
    assert!(
        hits.iter()
            .all(|h| h["meeting_id"].as_str().unwrap().len() == 8)
    );
    assert!(
        hits.iter()
            .any(|h| h["match_kind"] == "transcript" && h["timestamp"].is_string())
    );

    let quoted: serde_json::Value =
        serde_json::from_str(&stdout(&cli(&root, &["search", "\"photo studio\""]))).unwrap();
    assert!(quoted.as_array().unwrap().iter().all(|h| {
        h["snippet"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .contains("photo studio")
    }));

    let actions: serde_json::Value = serde_json::from_str(&stdout(&cli(
        &root,
        &["actions", "--owner", "me", "--days", "30"],
    )))
    .unwrap();
    let first = &actions.as_array().unwrap()[0];
    assert_eq!(first["overdue"], true);
    assert_eq!(first["owner"], "Me");

    let people = stdout(&cli(&root, &["people", "--table"]));
    assert!(people.contains("Maya Chen") && people.contains("John Park"));
    let maya: serde_json::Value =
        serde_json::from_str(&stdout(&cli(&root, &["people", "Maya"]))).unwrap();
    assert_eq!(maya["name"], "Maya Chen");
    assert!(maya["meetings"].as_array().unwrap().len() >= 5);

    let bad = cli(&root, &["get", "latest", "--include", "audio"]);
    assert_eq!(bad.status.code(), Some(64));
    assert!(String::from_utf8_lossy(&bad.stderr).contains("Unknown --include value(s): audio."));
    let path = stdout(&cli(&root, &["path"]));
    assert_eq!(path.trim(), root.display().to_string());

    assert_eq!(
        before,
        snapshot(&root),
        "the CLI must never write into meetings/"
    );
}

#[test]
fn brief_names_cli_commands_where_get_briefing_names_tools() {
    let (_dir, root) = seeded();
    let paths = LibraryPaths::new(&root);
    access::set_meetings_access(&paths, true).unwrap();
    access::set_screen_access(&paths, Some(access::ScreenScope::RecentWeek)).unwrap();
    let brief = stdout(&cli(&root, &["brief"]));
    let tools = lokalbot_cli::mcp::Provider {
        session: lokalbot_cli::session::Session::open(paths).unwrap(),
        now: None,
    }
    .briefing();

    assert!(
        brief.contains(
            ". Commands: search, get, list, actions, people, and ask while the app runs.\n"
        ),
        "{brief}"
    );
    assert!(
        brief
            .contains("- Screen memory: on, the last 7 days. No lokalbot-cli command searches it.")
    );
    assert!(brief.contains("For more, run lokalbot-cli: search and get for what was said, list --include summary for several meetings' summaries at once,"));
    for tool in [
        "search_meetings",
        "get_meeting",
        "list_meetings",
        "get_action_items",
        "get_person",
        "ask_library",
        "search_screen",
        "get_timeline",
        "get_personal_context",
    ] {
        assert!(!brief.contains(tool), "{tool} in {brief}");
    }
    assert!(tools.contains(". Tools: search_meetings, get_meeting, list_meetings,"));
    assert!(tools.contains(
        "list_meetings with include \"summary\" for several meetings' summaries at once"
    ));

    // The same briefing apart from the names: the meetings, screen and
    // closing lines differ, nothing else.
    let brief_lines: Vec<&str> = brief.trim_end().lines().collect();
    let tool_lines: Vec<&str> = tools.lines().collect();
    assert_eq!(brief_lines.len(), tool_lines.len());
    let differing: Vec<&str> = brief_lines
        .iter()
        .zip(&tool_lines)
        .filter(|(a, b)| a != b)
        .map(|(a, _)| *a)
        .collect();
    assert_eq!(differing.len(), 3, "{differing:#?}");
    assert!(differing[0].starts_with("- Meetings: on."));
    assert!(differing[1].starts_with("- Screen memory: on,"));
    assert!(differing[2].starts_with("For more"));
}

/// `has_summary` and `has_transcript` come from the files being there, not
/// from reading them, and say the same with and without `--include summary`.
#[test]
fn list_flags_say_which_files_a_meeting_has() {
    let (_dir, root) = seeded();
    let paths = LibraryPaths::new(&root);
    access::set_meetings_access(&paths, true).unwrap();
    let session = lokalbot_cli::session::Session::open(paths).unwrap();
    let mut meetings = session.meetings().unwrap();
    meetings.truncate(lokalbot_cli::session::DEFAULT_SUMMARY_LIST_COUNT);
    let has = |index: usize, name: &str| session.folder(&meetings[index]).join(name).is_file();
    let complete: Vec<usize> = (0..meetings.len())
        .filter(|&i| has(i, "summary.md") && has(i, "transcript.md"))
        .collect();
    assert!(complete.len() >= 2, "the demo library has full meetings");
    std::fs::remove_file(session.folder(&meetings[complete[0]]).join("summary.md")).unwrap();
    std::fs::remove_file(session.folder(&meetings[complete[1]]).join("transcript.md")).unwrap();

    for include_summary in [false, true] {
        let rows: serde_json::Value = serde_json::from_str(&lokalbot_cli::session::list_json(
            &session,
            &meetings,
            include_summary,
        ))
        .unwrap();
        for (index, row) in rows.as_array().unwrap().iter().enumerate() {
            assert_eq!(row["has_summary"], has(index, "summary.md"), "{row}");
            assert_eq!(row["has_transcript"], has(index, "transcript.md"), "{row}");
        }
        assert_eq!(rows[complete[0]]["has_summary"], false);
        assert_eq!(rows[complete[1]]["has_transcript"], false);
    }
}

#[test]
fn list_includes_summaries_within_one_budget() {
    let (_dir, root) = seeded();
    access::set_meetings_access(&LibraryPaths::new(&root), true).unwrap();

    let rows: serde_json::Value =
        serde_json::from_str(&stdout(&cli(&root, &["list", "--include", "summary"]))).unwrap();
    let rows = rows.as_array().unwrap();
    assert_eq!(
        rows.len(),
        lokalbot_cli::session::DEFAULT_SUMMARY_LIST_COUNT,
        "summaries default to ten meetings"
    );
    let mut total = 0;
    for row in rows {
        assert_eq!(
            row["summary"].is_string(),
            row["has_summary"] == true,
            "{row}"
        );
        total += row["summary"].as_str().map_or(0, |s| s.chars().count());
    }
    assert!(total > 0 && total <= lokalbot_cli::session::LIST_SUMMARY_BUDGET);
    let first = &rows[0];
    assert_eq!(first["id"], "55555555");
    assert!(first["summary"].as_str().unwrap().contains("## TL;DR"));
    assert!(first.get("summary_truncated").is_none());
    // Uncut, it is the summary `get` prints.
    let one: serde_json::Value = serde_json::from_str(&stdout(&cli(
        &root,
        &[
            "get",
            "55555555",
            "--include",
            "summary",
            "--format",
            "json",
        ],
    )))
    .unwrap();
    assert_eq!(one["summary"].as_str().unwrap().trim(), first["summary"]);

    let plain: serde_json::Value =
        serde_json::from_str(&stdout(&cli(&root, &["list", "--limit", "3"]))).unwrap();
    assert!(
        plain
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r.get("summary").is_none())
    );
    let all: serde_json::Value = serde_json::from_str(&stdout(&cli(
        &root,
        &["list", "--include", "metadata,summary", "--limit", "50"],
    )))
    .unwrap();
    assert_eq!(all.as_array().unwrap().len(), 17);

    let table = stdout(&cli(
        &root,
        &["list", "--limit", "2", "--include", "summary", "--table"],
    ));
    assert!(table.starts_with("ID        Date"), "{table}");
    assert!(
        table.contains("\n\n── 55555555 · Holiday shoot planning\n"),
        "{table}"
    );

    let transcripts = cli(&root, &["list", "--include", "summary,transcript"]);
    assert_eq!(transcripts.status.code(), Some(64));
    assert!(String::from_utf8_lossy(&transcripts.stderr).contains(
        "list doesn't include transcripts. Read one meeting's with `get <id> --include transcript`."
    ));
    let unknown = cli(&root, &["list", "--include", "audio"]);
    assert!(
        String::from_utf8_lossy(&unknown.stderr)
            .contains("Unknown --include value(s): audio. list takes summary.")
    );
    let over = cli(&root, &["list", "--include", "summary", "--limit", "51"]);
    assert_eq!(over.status.code(), Some(64));
    assert!(
        String::from_utf8_lossy(&over.stderr)
            .contains("--limit must be between 1 and 50 with --include summary.")
    );
    assert!(cli(&root, &["list", "--limit", "51"]).status.success());
}

/// `get_meeting {"include": "summary,transcripts"}` used to come back as the
/// summary alone, with nothing saying the transcript was not included.
#[test]
fn mcp_get_meeting_refuses_include_values_it_does_not_know() {
    let (_dir, root) = seeded();
    let paths = LibraryPaths::new(&root);
    access::set_meetings_access(&paths, true).unwrap();
    let tools = lokalbot_cli::mcp::Provider {
        session: lokalbot_cli::session::Session::open(paths).unwrap(),
        now: None,
    };
    let get = |include: &str| {
        tools.call(
            "get_meeting",
            &serde_json::json!({"id": "latest", "include": include}),
        )
    };
    let refused = get("summary, Transcripts,notes");
    assert!(refused.is_error);
    assert_eq!(
        refused.text,
        "[invalid_arguments] Unknown include value(s): notes, transcripts. get_meeting takes \"metadata\", \"summary\" and \"transcript\"."
    );
    let known = get("Summary, transcript");
    assert!(!known.is_error, "{}", known.text);
    assert!(!known.text.is_empty());
}

#[test]
fn mcp_round_trip() {
    let (_dir, root) = seeded();
    access::set_meetings_access(&LibraryPaths::new(&root), true).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_lokalbot-cli"))
        .arg("mcp")
        .env("LOKALBOT_STORAGE_ROOT", &root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let requests = [
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#,
        r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"captioned","limit":3}}}"#,
        r#"{"jsonrpc":"2.0","id":"x","method":"tools/call","params":{"name":"get_timeline","arguments":{}}}"#,
        r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_meetings","arguments":{"limit":0}}}"#,
        "",
        r#"{"jsonrpc":"2.0","id":6,"method":"ping"}"#,
        r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_meetings","arguments":{"include":"summary","limit":2}}}"#,
        r#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"list_meetings","arguments":{"include":"transcript"}}}"#,
    ];
    {
        let stdin = child.stdin.as_mut().unwrap();
        for request in requests {
            writeln!(stdin, "{request}").unwrap();
        }
    }
    let output = child.wait_with_output().unwrap();
    let lines: Vec<serde_json::Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(lines.len(), 8, "notifications and blank lines get no reply");
    assert_eq!(lines[0]["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(lines[0]["result"]["serverInfo"]["name"], "lokalbot");
    let tools = lines[1]["result"]["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 15);
    assert_eq!(tools[0]["name"], "get_briefing");
    assert_eq!(tools[13]["name"], "get_personal_context");
    assert_eq!(tools[14]["name"], "search_files");
    assert_eq!(lines[2]["result"]["isError"], false);
    let hits: serde_json::Value =
        serde_json::from_str(lines[2]["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert!(!hits.as_array().unwrap().is_empty());
    assert_eq!(lines[3]["id"], "x");
    assert_eq!(lines[3]["result"]["isError"], true);
    assert!(
        lines[3]["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .starts_with("[screen_access_disabled] ")
    );
    assert_eq!(
        lines[4]["result"]["content"][0]["text"],
        "[invalid_arguments] \"limit\" must be an integer between 1 and 1000."
    );
    assert_eq!(lines[5]["result"], serde_json::json!({}));
    let listed: serde_json::Value =
        serde_json::from_str(lines[6]["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    let listed = listed.as_array().unwrap();
    assert_eq!(listed.len(), 2);
    assert!(listed[0]["summary"].as_str().unwrap().contains("## TL;DR"));
    assert_eq!(
        lines[7]["result"]["content"][0]["text"],
        "[invalid_arguments] list_meetings doesn't include transcripts. Read one meeting's with get_meeting."
    );
    assert!(String::from_utf8_lossy(&output.stderr).contains("lokalbot-cli mcp: serving on stdio"));
}

/// The source of this app's Settings pages.
fn settings_source() -> String {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../lokalbot-app/src/pages/settings");
    let mut source = String::new();
    for entry in std::fs::read_dir(dir).unwrap().flatten() {
        source.push_str(&std::fs::read_to_string(entry.path()).unwrap());
    }
    source
}

/// Days in detail, older weeks as a line, but only with both grants, and a line
/// whose reviews changed is never shown (`Briefing.timeline`).
#[test]
fn the_briefing_shows_a_timeline_of_reviews_under_both_grants() {
    use lokalbot_core::dream::{DreamReport, day_key, rollup};

    let (_dir, root) = seeded();
    let today = chrono::Local::now().date_naive();
    let store = lokalbot_core::dream::DreamStore::new(&root);
    let yesterday = today - chrono::Duration::days(1);
    let mut report = DreamReport::new(
        day_key(yesterday),
        chrono::Utc::now(),
        "Yesterday went well. It really did. Third sentence.".into(),
    );
    report.evidence_provenance = Some(lokalbot_core::evidence::Provenance {
        revision: store.evidence_revision().unwrap(),
        ..Default::default()
    });
    store.save_report(&report).unwrap();
    let older = today - chrono::Duration::days(21);
    let week = rollup::week_containing(older);
    report.day = week.first_day.clone();
    store.save_report(&report).unwrap();
    let reviews = rollup::reviews(&root);
    let inside = rollup::reviews_in(&week.first_day, &week.last_day, &reviews);
    rollup::write(
        &rollup::Rollup {
            kind: week.kind,
            key: week.key.clone(),
            first_day: week.first_day.clone(),
            last_day: week.last_day.clone(),
            line: "Shipped the beta.".into(),
            stamp: rollup::stamp(&inside),
            generated_at: chrono::Utc::now(),
        },
        &root,
    )
    .unwrap();

    let paths = LibraryPaths::new(&root);
    access::set_meetings_access(&paths, true).unwrap();
    assert!(!stdout(&cli(&root, &["brief"])).contains("## Recent days"));
    access::set_screen_access(&paths, Some(access::ScreenScope::RetainedHistory)).unwrap();
    let brief = stdout(&cli(&root, &["brief"]));
    assert!(
        brief.contains("## Recent days, then weeks and months"),
        "{brief}"
    );
    assert!(
        brief.contains("Yesterday went well. It really did."),
        "{brief}"
    );
    assert!(!brief.contains("Third sentence"), "{brief}");
    assert!(
        brief.contains(&format!("{}: Shipped the beta.", week.label)),
        "{brief}"
    );

    // A regenerated review makes the week's line stale at once.
    report.generated_at = chrono::Utc::now() + chrono::Duration::hours(1);
    store.save_report(&report).unwrap();
    assert!(!stdout(&cli(&root, &["brief"])).contains("Shipped the beta"));
}

/// Agents relay these hints to the user, so every `Settings → <page> →
/// "<toggle>"` must exist in this app.
#[test]
fn agent_text_names_only_settings_this_app_has() {
    let (_dir, root) = seeded();
    let mut texts = vec![
        stdout(&cli(&root, &["brief"])),
        String::from_utf8_lossy(&cli(&root, &["personal-context", "--task", "Plan a trip"]).stderr)
            .into_owned(),
        stdout(&cli(&root, &["--help"])),
        stdout(&cli(&root, &["personal-context", "--help"])),
        lokalbot_cli::mcp::INSTRUCTIONS.to_string(),
        lokalbot_cli::personal::UNAVAILABLE_MESSAGE.to_string(),
        access::MEETINGS_DISABLED_MESSAGE.to_string(),
        access::SCREEN_DISABLED_MESSAGE.to_string(),
        access::SETTINGS_CONTROL_DISABLED_MESSAGE.to_string(),
    ];
    texts.extend(
        lokalbot_cli::mcp::tools()
            .iter()
            .map(|tool| tool["description"].as_str().unwrap().to_string()),
    );
    // Sharing is on, but no items have been written yet.
    let control = LibraryPaths::new(&root).control_dir();
    std::fs::create_dir_all(&control).unwrap();
    std::fs::write(control.join(access::PERSONAL_MARKER), b"").unwrap();
    texts.push(stdout(&cli(&root, &["brief"])));

    let settings = settings_source();
    for text in &texts {
        for (at, marker) in text.match_indices("Settings → ") {
            let rest = &text[at + marker.len()..];
            let end = rest
                .find(" → ")
                .unwrap_or_else(|| rest.find(['.', '\n']).unwrap_or(rest.len()));
            let page = &rest[..end];
            assert!(
                settings.contains(&format!("=> \"{page}\"")),
                "no Settings page {page:?}, named in {text}"
            );
            let toggle = rest[end..]
                .strip_prefix(" → \"")
                .and_then(|label| label.split_once('"'))
                .map(|(label, _)| label);
            if let Some(toggle) = toggle {
                assert!(
                    settings.contains(&format!("tr(\"{toggle}\")")),
                    "no setting {toggle:?}, named in {text}"
                );
            }
        }
    }
}

#[test]
fn version_exits_without_touching_the_library() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    for flag in ["--version", "-V"] {
        let output = cli(&root, &[flag]);
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(
            stdout(&output),
            format!("lokalbot-cli {}\n", env!("CARGO_PKG_VERSION"))
        );
    }
    assert!(!root.exists());
}

#[test]
fn reads_the_macos_fixture() {
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../LokalBotTests/Fixtures/upgrade/0.10.9/library");
    if !fixture.is_dir() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    copy_dir(&fixture, &root);
    access::set_meetings_access(&LibraryPaths::new(&root), true).unwrap();
    let list: serde_json::Value = serde_json::from_str(&stdout(&cli(&root, &["list"]))).unwrap();
    assert!(list.as_array().unwrap().len() >= 10);
    let hits: serde_json::Value =
        serde_json::from_str(&stdout(&cli(&root, &["search", "Redis"]))).unwrap();
    assert!(!hits.as_array().unwrap().is_empty());
    let get = stdout(&cli(&root, &["get", "44444444", "--include", "summary"]));
    assert!(get.contains("## Summary"));
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// A stand-in for the app's control socket: answers each request in turn and
/// hands back what it was sent.
#[cfg(unix)]
struct FakeApp {
    requests: std::sync::mpsc::Receiver<Value>,
    _dir: tempfile::TempDir,
    root: PathBuf,
}

#[cfg(unix)]
fn fake_app(replies: Vec<Value>) -> FakeApp {
    use std::io::{BufRead as _, BufReader, Write as _};
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let paths = LibraryPaths::new(&root);
    std::fs::create_dir_all(&root).unwrap();
    access::set_settings_control(&paths, true).unwrap();
    let endpoint = lokalbot_core::control::socket::endpoint(&root).unwrap();
    let _ = std::fs::remove_file(&endpoint);
    let listener = std::os::unix::net::UnixListener::bind(&endpoint).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for reply in replies {
            let (stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(&stream).read_line(&mut line).unwrap();
            let _ = tx.send(serde_json::from_str::<Value>(&line).unwrap());
            let mut writer = &stream;
            writer.write_all(format!("{reply}\n").as_bytes()).unwrap();
        }
        let _ = std::fs::remove_file(&endpoint);
    });
    FakeApp {
        requests: rx,
        _dir: dir,
        root,
    }
}

#[cfg(unix)]
fn waiting_request(state: &str) -> Value {
    serde_json::json!({
        "id": "ID-1",
        "state": state,
        "caller": "test",
        "changes": [],
    })
}

#[cfg(unix)]
fn needs_approval() -> Value {
    serde_json::json!({"protocol": 1, "error": {
        "code": "needs_approval",
        "message": "It needs the person's approval.",
        "details": waiting_request("pending"),
    }})
}

/// Exit 3 waiting, 0 approved, 4 declined and 5 expired, so a script can tell them apart.
#[cfg(unix)]
#[test]
fn requests_that_need_the_person_exit_by_their_state() {
    let app = fake_app(vec![needs_approval()]);
    let output = cli(&app.root, &["config", "set", "trackingEnabled=true"]);
    assert_eq!(output.status.code(), Some(3), "{output:?}");
    let reply: Value = serde_json::from_str(&stdout(&output)).unwrap();
    assert_eq!(reply["error"], "needs_approval");
    assert_eq!(reply["details"]["id"], "ID-1");
    let sent = app.requests.recv().unwrap();
    assert_eq!(sent["method"], "settings.set");
    assert_eq!(sent["params"]["changes"]["trackingEnabled"], true);

    for (state, code) in [("approved", 0), ("denied", 4), ("expired", 5)] {
        let app = fake_app(vec![
            needs_approval(),
            serde_json::json!({"protocol": 1, "result": waiting_request("pending")}),
            serde_json::json!({"protocol": 1, "result": waiting_request(state)}),
        ]);
        let output = cli(
            &app.root,
            &["config", "set", "trackingEnabled=true", "--wait", "30"],
        );
        assert_eq!(output.status.code(), Some(code), "{state}: {output:?}");
        let reply: Value = serde_json::from_str(&stdout(&output)).unwrap();
        assert_eq!(reply["state"], state);
    }
}

/// A key comes from standard input, one line, and never appears in any output.
#[cfg(unix)]
#[test]
fn api_keys_come_from_standard_input_and_never_print() {
    use std::io::Write as _;
    let app = fake_app(vec![needs_approval()]);
    let mut child = Command::new(env!("CARGO_BIN_EXE_lokalbot-cli"))
        .args(["secret", "set", "openai-compatible"])
        .env("LOKALBOT_STORAGE_ROOT", &app.root)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"sk-a-very-secret-key\n")
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(3), "{output:?}");
    let sent = app.requests.recv().unwrap();
    assert_eq!(sent["method"], "secret.set");
    assert_eq!(sent["params"]["value"], "sk-a-very-secret-key");
    assert!(!stdout(&output).contains("sk-a-very-secret-key"));
    assert!(!String::from_utf8_lossy(&output.stderr).contains("sk-a-very-secret-key"));

    // Two lines aren't a key, and nothing reaches the app.
    let app = fake_app(vec![]);
    let mut child = Command::new(env!("CARGO_BIN_EXE_lokalbot-cli"))
        .args(["secret", "set", "openai-compatible"])
        .env("LOKALBOT_STORAGE_ROOT", &app.root)
        .stdin(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"line one\nline two\n")
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(64), "{output:?}");
}

/// Stable errors print as `[code] message`, and no grant means no connection.
#[cfg(unix)]
#[test]
fn errors_from_the_app_print_their_code() {
    let app = fake_app(vec![serde_json::json!({"protocol": 1, "error": {
        "code": "app_outdated",
        "message": "Restart LokalBot.",
    }})]);
    let output = cli(&app.root, &["status", "--no-launch"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("Error: [app_outdated] Restart LokalBot.")
    );

    let (_dir, root) = seeded();
    let output = cli(&root, &["status", "--no-launch"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("[settings_access_disabled]"),
        "{output:?}"
    );
}

/// `--files` asks for Files like the other read access, and asking grants nothing.
#[cfg(unix)]
#[test]
fn setup_start_can_ask_to_search_files() {
    use lokalbot_core::control::setup::{self, Grant, SetupRequest};
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let paths = LibraryPaths::new(&root);
    let control = paths.control_dir();
    std::fs::create_dir_all(&root).unwrap();
    let lock = std::fs::File::create(paths.instance_lock()).unwrap();
    lock.lock().unwrap();
    let output = cli(&root, &["setup", "start", "--files"]);
    assert_eq!(output.status.code(), Some(3), "{output:?}");
    let request: SetupRequest = setup::read(&setup::request_path(&control)).unwrap();
    assert_eq!(request.grants, [Grant::Settings, Grant::Files]);
    assert!(!lokalbot_core::files::access::is_enabled(&paths));
    assert!(!access::settings_control_enabled(&paths));

    // Already on: nothing to ask for that box, and so nothing to ask at all.
    access::set_settings_control(&paths, true).unwrap();
    lokalbot_core::files::access::set_enabled(&paths, true).unwrap();
    std::fs::remove_file(setup::request_path(&control)).unwrap();
    let output = cli(&root, &["setup", "start", "--files"]);
    assert!(output.status.success(), "{output:?}");
    let reply: Value = serde_json::from_str(&stdout(&output)).unwrap();
    assert_eq!(reply["alreadyAllowed"], true);
    assert!(!setup::request_path(&control).exists());
}

/// `setup start` leaves a request the app shows, and asking grants nothing.
#[cfg(unix)]
#[test]
fn setup_start_waits_for_the_answer_in_the_control_folder() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let paths = LibraryPaths::new(&root);
    let control = paths.control_dir();
    // A running copy finds the request itself, so nothing is launched here.
    std::fs::create_dir_all(&root).unwrap();
    let lock = std::fs::File::create(paths.instance_lock()).unwrap();
    lock.lock().unwrap();
    let output = cli(&root, &["setup", "start", "--screen-memory"]);
    assert_eq!(output.status.code(), Some(3), "{output:?}");
    let reply: Value = serde_json::from_str(&stdout(&output)).unwrap();
    assert_eq!(reply["state"], "pending");
    let request: lokalbot_core::control::setup::SetupRequest =
        lokalbot_core::control::setup::read(&lokalbot_core::control::setup::request_path(&control))
            .unwrap();
    assert!(request.is_live(chrono::Utc::now()));
    assert_eq!(
        request.grants,
        [
            lokalbot_core::control::setup::Grant::Settings,
            lokalbot_core::control::setup::Grant::ScreenMemory
        ]
    );
    // Nothing was granted by asking.
    assert!(!access::settings_control_enabled(&paths));
    assert!(access::screen_access_scope(&paths).is_none());
}
