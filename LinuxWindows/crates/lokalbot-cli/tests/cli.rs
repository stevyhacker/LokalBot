//! The real binary against a seeded demo library and the macOS fixture.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use lokalbot_core::{LibraryPaths, access, demo};

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
        brief.contains(". Commands: search, get, list, actions, and people.\n"),
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
    assert_eq!(tools.len(), 14);
    assert_eq!(tools[0]["name"], "get_briefing");
    assert_eq!(tools[13]["name"], "get_personal_context");
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

/// Agents relay these hints to the user, so every `Settings → <page> →
/// "<toggle>"` must exist in this app. The Mac's Personal Context page and its
/// sharing toggle do not.
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
    ];
    texts.extend(
        lokalbot_cli::mcp::tools()
            .iter()
            .map(|tool| tool["description"].as_str().unwrap().to_string()),
    );
    // A library from a Mac that shares Personal Context but has no items written.
    let control = LibraryPaths::new(&root).control_dir();
    std::fs::create_dir_all(&control).unwrap();
    std::fs::write(control.join(access::PERSONAL_MARKER), b"").unwrap();
    texts.push(stdout(&cli(&root, &["brief"])));

    let settings = settings_source();
    for text in &texts {
        for mac_only in [
            "what I shared about myself",
            "→ Personal Context",
            "Open LokalBot once",
            "timeline of recent days",
            "lokalbot-cli setup",
            "lokalbot-cli config",
            "lokalbot-cli doctor",
        ] {
            assert!(!text.contains(mac_only), "{mac_only:?} in {text}");
        }
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
