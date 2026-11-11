//! `AgentMemoryReaderTests.swift`, and the background reader's part of
//! `AgentNotesTests.swift`.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use lokalbot_core::LibraryPaths;
use lokalbot_core::agent_notes::AgentNote;
use lokalbot_core::coding_agents::CodingAgentKind::{ClaudeCode, Codex};
use parking_lot::RwLock;
use serde_json::json;

use super::exclusions::claude_project_slug;
use super::*;

fn scan_home(home: &Path, excluded: &[&str]) -> NoteScan {
    let excluded: Vec<String> = excluded.iter().map(|folder| folder.to_string()).collect();
    scan(home, &CodingAgentKind::ALL, &excluded)
}

/// A Claude Code project folder with notes, and optionally one session file
/// that names the project's real path.
fn write_claude_project(home: &Path, cwd: &str, session: bool, notes: &[(&str, &str)]) -> PathBuf {
    let project = home
        .join(".claude")
        .join("projects")
        .join(claude_project_slug(cwd));
    let memory = project.join("memory");
    fs::create_dir_all(&memory).unwrap();
    for (name, contents) in notes {
        fs::write(memory.join(name), contents).unwrap();
    }
    if session {
        let line = json!({"type": "user", "cwd": cwd});
        fs::write(project.join("S1.jsonl"), line.to_string()).unwrap();
    }
    project
}

fn write_codex(home: &Path, relative_path: &str, contents: &str) {
    let file = home.join(".codex").join("memories").join(relative_path);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, contents).unwrap();
}

// ------------------------------------------------------------ Claude Code

#[test]
fn claude_notes_carry_title_description_type_and_project() {
    let home = tempfile::tempdir().unwrap();
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/app",
        true,
        &[
            (
                "release-gotchas.md",
                "---\nname: release-gotchas\ndescription: \"Per-release lessons: tag by SHA, retry the \\\"501\\\" upload\"\nmetadata:\n  node_type: memory\n  type: project\n---\n\nTag the release by SHA. The upload token is ghp_abcdefghijklmnopqrstuvwxyz0123456789.\n",
            ),
            (
                "MEMORY.md",
                "- [Release runbook gotchas](release-gotchas.md) — per-release lessons\n",
            ),
        ],
    );

    let scan = scan_home(home.path(), &[]);

    assert_eq!(scan.notes.len(), 1, "the index file is not a note");
    assert_eq!(scan.files_read, 1);
    let note = &scan.notes[0];
    assert_eq!(note.agent, ClaudeCode);
    assert_eq!(
        note.title, "Release runbook gotchas",
        "the index's title wins over the file's slug"
    );
    assert_eq!(
        note.summary.as_deref(),
        Some("Per-release lessons: tag by SHA, retry the \"501\" upload")
    );
    assert_eq!(note.category.as_deref(), Some("project"));
    assert_eq!(
        note.working_directory.as_deref(),
        Some("/Users/me/GitHub/app")
    );
    assert_eq!(note.project_name().as_deref(), Some("app"));
    assert!(note.text.starts_with("Tag the release by SHA."));
    assert!(
        !note.text.contains("ghp_"),
        "credentials are redacted before a note is kept"
    );
    assert!(
        !note.text.contains("node_type"),
        "the header is not part of the text"
    );
    assert!(Path::new(&note.path).ends_with("memory/release-gotchas.md"));
    assert_eq!(
        note.id,
        AgentNote::identifier(
            ClaudeCode,
            "-Users-me-GitHub-app/memory/release-gotchas.md",
            ""
        )
    );
}

#[test]
fn a_claude_note_without_header_or_index_falls_back_to_heading_then_file_name() {
    let home = tempfile::tempdir().unwrap();
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/app",
        false,
        &[
            (
                "with-heading.md",
                "# Build recipe\n\nRun the fast build first.\n",
            ),
            ("plain-note.md", "Just a line the agent kept.\n"),
            ("empty.md", "---\nname: empty\n---\n"),
            ("notes.txt", "not markdown"),
        ],
    );
    // Instruction files beside the notes folder are never read.
    let project = home
        .path()
        .join(".claude/projects")
        .join(claude_project_slug("/Users/me/GitHub/app"));
    fs::write(project.join("CLAUDE.md"), "Always answer in French.").unwrap();
    fs::write(
        home.path().join(".claude/CLAUDE.md"),
        "Global instructions.",
    )
    .unwrap();

    let mut notes = scan_home(home.path(), &[]).notes;
    notes.sort_by(|a, b| a.title.cmp(&b.title));

    assert_eq!(
        notes
            .iter()
            .map(|note| note.title.as_str())
            .collect::<Vec<_>>(),
        ["Build recipe", "plain note"]
    );
    assert_eq!(
        notes[0].working_directory, None,
        "without a session file the folder's real path is unknown"
    );
    assert_eq!(notes[0].category, None);
    assert!(notes.iter().all(|note| !note.text.contains("French")));
}

#[test]
fn claude_note_ids_are_stable_and_differ_per_file() {
    let home = tempfile::tempdir().unwrap();
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/app",
        false,
        &[("a.md", "First note."), ("b.md", "Second note.")],
    );
    let ids =
        |scan: NoteScan| -> BTreeSet<String> { scan.notes.into_iter().map(|n| n.id).collect() };

    let first = ids(scan_home(home.path(), &[]));
    let second = ids(scan_home(home.path(), &[]));

    assert_eq!(first, second);
    assert_eq!(first.len(), 2);
}

#[test]
fn an_excluded_folder_leaves_out_claude_notes_even_without_a_session_file() {
    let home = tempfile::tempdir().unwrap();
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/secret",
        false,
        &[("a.md", "Secret plan.")],
    );
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/secret/tools",
        true,
        &[("b.md", "Inside it.")],
    );
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/open",
        true,
        &[("c.md", "Public plan.")],
    );

    let scan = scan_home(home.path(), &["/Users/me/GitHub/secret"]);

    assert_eq!(
        scan.notes
            .iter()
            .map(|n| n.text.as_str())
            .collect::<Vec<_>>(),
        ["Public plan."]
    );
    assert_eq!(scan.excluded_notes, 2);
}

#[test]
fn a_windows_project_is_named_and_excluded_by_its_path() {
    let home = tempfile::tempdir().unwrap();
    let project = write_claude_project(
        home.path(),
        r"C:\Users\me\Code\app",
        true,
        &[("a.md", "Build with the fast profile.")],
    );
    assert!(project.ends_with("C--Users-me-Code-app"));
    write_claude_project(
        home.path(),
        r"C:\Users\me\Code\secret",
        true,
        &[("b.md", "Secret plan.")],
    );

    let scan = scan_home(home.path(), &[r"c:\users\me\code\secret"]);

    assert_eq!(scan.excluded_notes, 1);
    assert_eq!(scan.notes.len(), 1);
    assert_eq!(
        scan.notes[0].working_directory.as_deref(),
        Some(r"C:\Users\me\Code\app")
    );
    assert_eq!(scan.notes[0].project_name().as_deref(), Some("app"));
}

#[test]
fn the_working_directory_is_taken_only_from_a_session_that_matches_the_project_folder() {
    let home = tempfile::tempdir().unwrap();
    let project = write_claude_project(
        home.path(),
        "/Users/me/GitHub/app",
        false,
        &[("a.md", "Note.")],
    );
    // A session that later moved elsewhere still names its start folder first.
    fs::write(
        project.join("S1.jsonl"),
        "{\"type\":\"user\",\"cwd\":\"/Users/me/Other\"}\n{\"type\":\"user\",\"cwd\":\"/Users/me/GitHub/app\"}",
    )
    .unwrap();

    assert_eq!(
        claude::working_directory(&project).as_deref(),
        Some("/Users/me/GitHub/app")
    );
}

// ------------------------------------------------------------------ Codex

#[test]
fn codex_task_groups_become_notes_with_scope_and_folder() {
    let home = tempfile::tempdir().unwrap();
    write_codex(
        home.path(),
        "MEMORY.md",
        "# Task Group: /Users/me/GitHub/app release checks\n\nscope: Verify a notarized release before publishing.\napplies_to: cwd=/Users/me/GitHub/app; reuse_rule=check the current tag\n\n## Task 1: Verify the DMG\n\n```sh\n# not a heading\nspctl --assess LokalBot.dmg\n```\n\n# Task Group: Expense documents\n\nscope: Find receipts.\napplies_to: cwd=/Users/me/GitHub/secret; reuse_rule=none\n\n## Task 1: Hotel invoice\n",
    );

    let scan = scan_home(home.path(), &["/Users/me/GitHub/secret"]);

    assert_eq!(scan.notes.len(), 1);
    assert_eq!(scan.excluded_notes, 1);
    let note = &scan.notes[0];
    assert_eq!(note.agent, Codex);
    assert_eq!(note.title, "/Users/me/GitHub/app release checks");
    assert_eq!(
        note.summary.as_deref(),
        Some("Verify a notarized release before publishing.")
    );
    assert_eq!(
        note.working_directory.as_deref(),
        Some("/Users/me/GitHub/app")
    );
    assert!(
        note.text.contains("# not a heading"),
        "a heading inside fenced code stays text"
    );
    assert!(note.text.contains("## Task 1: Verify the DMG"));
}

#[test]
fn codex_summary_sections_and_session_summaries() {
    let home = tempfile::tempdir().unwrap();
    write_codex(
        home.path(),
        "memory_summary.md",
        "v1\n\n## User preferences\n\nPrefers short status notes.\n\n## What's in Memory\n\n### /Users/me/GitHub/app\n\nRelease checks and build recipes.\n\n### /Users/me/GitHub/secret / 2026-10-01\n\nHidden work.\n",
    );
    // Written on Windows, with its line endings.
    write_codex(
        home.path(),
        "rollout_summaries/2026-11-10T10-29-23-o6E8-release_checks.md",
        "thread_id: 01a1c501\r\nupdated_at: 2026-11-10T10:38:19+00:00\r\nrollout_path: /Users/me/.codex/sessions/2026/11/10/rollout.jsonl\r\ncwd: /Users/me/GitHub/app\r\n\r\n# Verified the notarized release\r\n\r\nOutcome: success.\r\n",
    );
    write_codex(
        home.path(),
        "rollout_summaries/2026-11-09T09-00-00-aaaa-hidden.md",
        "thread_id: 01a1c502\ncwd: /Users/me/GitHub/secret/tools\n\n# Hidden session\n\nOutcome: success.\n",
    );
    write_codex(
        home.path(),
        "raw_memories.md",
        "# Raw Memories\n\n## Thread `x`\n\nDuplicate of the summaries.\n",
    );
    // Instructions and skills are not notes.
    fs::write(home.path().join(".codex/AGENTS.md"), "Global instructions.").unwrap();
    write_codex(
        home.path(),
        "skills/release/SKILL.md",
        "# A procedure\n\nSteps.\n",
    );

    let scan = scan_home(home.path(), &["/Users/me/GitHub/secret"]);
    let titles: BTreeSet<&str> = scan.notes.iter().map(|n| n.title.as_str()).collect();

    assert_eq!(
        titles,
        BTreeSet::from([
            "User preferences",
            "/Users/me/GitHub/app",
            "Verified the notarized release"
        ])
    );
    assert_eq!(scan.excluded_notes, 2);
    let session = scan
        .notes
        .iter()
        .find(|n| n.title == "Verified the notarized release")
        .unwrap();
    assert_eq!(
        session.working_directory.as_deref(),
        Some("/Users/me/GitHub/app")
    );
    assert_eq!(
        session.modified_at,
        chrono::DateTime::parse_from_rfc3339("2026-11-10T10:38:19Z").unwrap()
    );
    assert!(
        !session.text.contains("thread_id"),
        "the header lines are not part of the text"
    );
    assert!(!session.text.contains('\r'));
    let project = scan
        .notes
        .iter()
        .find(|n| n.title == "/Users/me/GitHub/app")
        .unwrap();
    assert_eq!(project.summary.as_deref(), Some("What's in Memory"));
    assert_eq!(
        project.working_directory.as_deref(),
        Some("/Users/me/GitHub/app")
    );
}

#[test]
fn a_disabled_agent_is_not_read() {
    let home = tempfile::tempdir().unwrap();
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/app",
        false,
        &[("a.md", "Claude note.")],
    );
    write_codex(
        home.path(),
        "MEMORY.md",
        "# Task Group: Codex work\n\nscope: Something.\n",
    );

    let scan = scan(home.path(), &[Codex], &[]);

    assert_eq!(
        scan.notes.iter().map(|n| n.agent).collect::<Vec<_>>(),
        [Codex]
    );
    assert_eq!(scan.files_read, 1);
}

#[test]
fn a_file_too_large_to_be_a_note_is_skipped_without_blocking_deletions() {
    let home = tempfile::tempdir().unwrap();
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/app",
        false,
        &[("small.md", "A real note.")],
    );
    let huge = "x".repeat(usize::try_from(text::MAX_FILE_BYTES).unwrap() + 1);
    write_claude_project(
        home.path(),
        "/Users/me/GitHub/app",
        false,
        &[("huge.md", huge.as_str())],
    );

    let scan = scan_home(home.path(), &[]);

    assert_eq!(scan.notes.len(), 1);
    assert!(scan.unreadable_files.is_empty());
}

// ------------------------------------------------------- Background reader

fn library(dir: &Path) -> Library {
    Library::open(LibraryPaths::new(dir.join("library"))).unwrap()
}

fn release() -> AgentNote {
    AgentNote {
        id: "c0ffee000001".into(),
        agent: ClaudeCode,
        title: "Release runbook".into(),
        summary: Some("Per-release lessons".into()),
        category: Some("project".into()),
        working_directory: Some("/Users/me/GitHub/app".into()),
        path: "/Users/me/.claude/projects/-Users-me-GitHub-app/memory/release.md".into(),
        modified_at: chrono::DateTime::from_timestamp(1_800_000_000, 0).unwrap(),
        text: "Tag the release by SHA, never by branch name.".into(),
    }
}

#[test]
fn settings_choose_the_agents_and_folders_for_notes() {
    let mut settings = Settings::default();
    assert!(
        !settings.coding_agent_notes_enabled,
        "notes are off until turned on"
    );
    assert!(!Configuration::new(&settings).reads());

    settings.coding_agent_notes_enabled = true;
    settings.coding_agent_evidence_enabled = false;
    settings.coding_agent_evidence_confirmed = false;
    settings.coding_agent_reads_codex = false;
    settings.coding_agent_excluded_folders = "~/Secret, /tmp/x".into();
    let configuration = Configuration::new(&settings);
    assert!(
        configuration.reads(),
        "notes do not depend on reading sessions"
    );
    assert_eq!(configuration.agents, [ClaudeCode]);
    assert_eq!(configuration.excluded_folders, ["~/Secret", "/tmp/x"]);

    settings.coding_agent_reads_claude_code = false;
    assert!(!Configuration::new(&settings).reads());

    let stored: Settings =
        serde_json::from_value(json!({"codingAgentNotesEnabled": true})).unwrap();
    assert!(stored.coding_agent_notes_enabled);
    assert_eq!(
        serde_json::to_value(&stored).unwrap()["codingAgentNotesEnabled"],
        true
    );
}

#[test]
fn the_ingestor_reads_only_while_on_and_deletes_when_turned_off() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let index = NotesIndex::new(library.paths().root());
    let settings = RwLock::new(Settings::default());
    let scans = AtomicUsize::new(0);
    let ingestor = Ingestor::default();
    let refresh = || {
        ingestor.refresh_with(
            &library,
            || settings.read().clone(),
            |_| {
                scans.fetch_add(1, Ordering::SeqCst);
                NoteScan {
                    notes: vec![release()],
                    ..Default::default()
                }
            },
        )
    };

    assert!(!refresh());
    assert_eq!(
        scans.load(Ordering::SeqCst),
        0,
        "nothing is read before the person turns it on"
    );
    assert!(!index.exists());
    assert_eq!(ingestor.status(&library), AgentNotesStatus::default());

    settings.write().coding_agent_notes_enabled = true;
    assert!(refresh());
    assert_eq!(scans.load(Ordering::SeqCst), 1);
    let status = ingestor.status(&library);
    assert_eq!(status.counts, [(ClaudeCode, 1)]);
    assert_eq!(status.total(), 1);
    assert_eq!(ingestor.changed_status(&library), Some(status));
    assert_eq!(ingestor.changed_status(&library), None, "reported once");
    assert!(!refresh(), "an unchanged scan changes nothing");

    settings.write().coding_agent_notes_enabled = false;
    assert!(refresh(), "turning it off deletes the saved copy");
    assert!(!index.exists());
    assert_eq!(scans.load(Ordering::SeqCst), 2);
    assert!(ingestor.status(&library).counts.is_empty());
    assert!(!refresh());
}

#[test]
fn a_scan_that_outlives_its_setting_is_not_kept() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let index = NotesIndex::new(library.paths().root());
    let settings = RwLock::new(Settings {
        coding_agent_notes_enabled: true,
        ..Settings::default()
    });
    let ingestor = Ingestor::default();
    let found = || NoteScan {
        notes: vec![release()],
        ..Default::default()
    };

    // Turned off while the files were being read.
    let changed = ingestor.refresh_with(
        &library,
        || settings.read().clone(),
        |_| {
            settings.write().coding_agent_notes_enabled = false;
            found()
        },
    );
    assert!(!changed);
    assert!(!index.exists());

    // An exclusion added during the read waits for the next one.
    settings.write().coding_agent_notes_enabled = true;
    let changed = ingestor.refresh_with(
        &library,
        || settings.read().clone(),
        |_| {
            settings.write().coding_agent_excluded_folders = "/Users/me/GitHub/app".into();
            found()
        },
    );
    assert!(!changed);
    assert!(!index.exists());
}

#[test]
fn a_real_scan_is_saved_and_searchable() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    write_claude_project(
        &home,
        "/Users/me/GitHub/app",
        true,
        &[(
            "release.md",
            "Tag the release by SHA, never by branch name.",
        )],
    );
    write_codex(
        &home,
        "MEMORY.md",
        "# Task Group: Build recipe\n\nscope: Building.\n\nRun the fast build first.\n",
    );
    let library = library(dir.path());
    let settings = Settings {
        coding_agent_notes_enabled: true,
        ..Settings::default()
    };
    let ingestor = Ingestor::default();

    let changed = ingestor.refresh_with(
        &library,
        || settings.clone(),
        |configuration| {
            scan(
                &home,
                &configuration.agents,
                &configuration.excluded_folders,
            )
        },
    );

    assert!(changed);
    let index = NotesIndex::new(library.paths().root());
    let hits = index.search("release SHA", None, 5).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].source_label(), "Claude Code · app");
    assert_eq!(
        ingestor.status(&library).counts,
        [(ClaudeCode, 1), (Codex, 1)]
    );
}
