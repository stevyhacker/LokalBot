use std::collections::{HashMap, HashSet};
use std::path::Path;

use chrono::{Duration, Local, NaiveDate, TimeZone as _, Utc};
use lokalbot_core::settings::{DailyMemoryExportFormat, ExportFormat};
use lokalbot_core::timeline::NewScreenMoment;
use lokalbot_core::{Library, LibraryPaths, Meeting};

use super::meeting_notes::{self, Configuration, ExistingNotes, Note};
use super::{daily, next_daily_export};

fn library(dir: &Path) -> Library {
    Library::open(LibraryPaths::new(dir.join("library"))).unwrap()
}

fn never() -> bool {
    false
}

fn finished_meeting(library: &Library, title: &str, summary: &str) -> Meeting {
    let start = Local
        .with_ymd_and_hms(2026, 9, 29, 10, 30, 0)
        .unwrap()
        .with_timezone(&Utc);
    let mut meeting = library.create_meeting(title, "Zoom", start).unwrap();
    meeting.ended_at = Some(start + Duration::minutes(45));
    library.save_meeting(&meeting).unwrap();
    std::fs::write(library.meeting_dir(&meeting).join("summary.md"), summary).unwrap();
    meeting
}

fn configuration(destination: &Path, format: ExportFormat) -> Configuration {
    Configuration {
        destination: destination.to_path_buf(),
        format,
        includes_transcript: true,
    }
}

fn run(
    library: &Library,
    configuration: &Configuration,
    previous: &HashMap<uuid::Uuid, String>,
) -> meeting_notes::Report {
    meeting_notes::export(library, configuration, previous, &never).unwrap()
}

#[test]
fn a_note_is_named_for_its_meeting_and_found_again() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let meeting = finished_meeting(&library, "Atlas: release/sync?", "# Notes\n");
    let name = meeting_notes::file_name(&meeting);
    assert_eq!(
        name,
        format!("2026-09-29 Atlas release sync ({}).md", meeting.short_id())
    );
    assert_eq!(
        meeting_notes::meeting_id_in_file_name(&name),
        Some(meeting.short_id())
    );
    assert_eq!(meeting_notes::meeting_id_in_file_name("notes.md"), None);
    assert_eq!(
        meeting_notes::meeting_id_in_file_name("a (nothex!!).md"),
        None
    );

    let mut untitled = meeting.clone();
    untitled.title = "   ...   ".into();
    untitled.app_name = "".into();
    assert!(meeting_notes::file_name(&untitled).contains(&meeting.short_id()));
}

#[test]
fn a_pass_writes_each_finished_meeting_once_and_skips_what_it_should() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let destination = dir.path().join("vault");
    let config = configuration(&destination, ExportFormat::Markdown);
    let meeting = finished_meeting(
        &library,
        "Atlas sync",
        "# Atlas\n\n## TL;DR\n\nWe talked.\n",
    );
    // Still in progress: no note.
    library
        .create_meeting("Ongoing", "Zoom", Utc::now())
        .unwrap();
    let report = run(&library, &config, &HashMap::new());
    assert_eq!(report.written.len(), 1);
    assert!(report.failures.is_empty());
    let note = &report.written[0];
    let text = std::fs::read_to_string(note).unwrap();
    assert!(text.starts_with(meeting_notes::GENERATED_FILE_MARKER));
    assert!(text.contains("# Atlas sync"));
    assert!(text.contains("- **App:** Zoom"));
    assert!(text.contains(&format!("- **Meeting:** `{}`", meeting.short_id())));
    assert!(text.contains("We talked."));

    // Nothing changed: the fingerprint skips it, without even reading it.
    let again = run(&library, &config, &report.fingerprints);
    assert!(again.written.is_empty());
    assert_eq!(again.fingerprints, report.fingerprints);

    // A changed summary refreshes the note under the same name.
    std::thread::sleep(std::time::Duration::from_millis(5));
    std::fs::write(
        library.meeting_dir(&meeting).join("summary.md"),
        "Now different.",
    )
    .unwrap();
    let refreshed = run(&library, &config, &report.fingerprints);
    assert_eq!(refreshed.written, report.written);
    assert!(
        std::fs::read_to_string(note)
            .unwrap()
            .contains("Now different.")
    );
}

#[test]
fn a_note_the_person_touched_is_theirs() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let destination = dir.path().join("vault");
    let config = configuration(&destination, ExportFormat::Markdown);
    let meeting = finished_meeting(&library, "Atlas sync", "One.");
    let report = run(&library, &config, &HashMap::new());
    let note = report.written[0].clone();

    // Edited: left alone, and the pass counts as done.
    let mut edited = std::fs::read_to_string(&note).unwrap();
    edited.push_str("\nMy own line.\n");
    std::fs::write(&note, &edited).unwrap();
    std::fs::write(library.meeting_dir(&meeting).join("summary.md"), "Two.").unwrap();
    let second = run(&library, &config, &HashMap::new());
    assert!(second.written.is_empty() && second.failures.is_empty());
    assert_eq!(std::fs::read_to_string(&note).unwrap(), edited);

    // Deleted while its sidecar stays: never written again.
    std::fs::remove_file(&note).unwrap();
    let existing = ExistingNotes::read(&destination).unwrap();
    assert!(existing.removed.contains(&meeting.short_id()));
    let third = run(&library, &config, &HashMap::new());
    assert!(third.written.is_empty());
    assert!(!note.exists());

    // A file LokalBot didn't write under the name stays too.
    let other = dir.path().join("other");
    std::fs::create_dir_all(&other).unwrap();
    std::fs::write(other.join(meeting_notes::file_name(&meeting)), "mine").unwrap();
    let elsewhere = run(
        &library,
        &configuration(&other, ExportFormat::Markdown),
        &HashMap::new(),
    );
    assert!(elsewhere.written.is_empty());
    assert_eq!(
        std::fs::read_to_string(other.join(meeting_notes::file_name(&meeting))).unwrap(),
        "mine"
    );
}

#[test]
fn a_renamed_meeting_keeps_its_note_and_the_sample_stays_out() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let destination = dir.path().join("vault");
    let config = configuration(&destination, ExportFormat::Markdown);
    let mut meeting = finished_meeting(&library, "First name", "Body.");
    let first = run(&library, &config, &HashMap::new());
    meeting.title = "Second name".into();
    library.save_meeting(&meeting).unwrap();
    let second = run(&library, &config, &HashMap::new());
    assert_eq!(second.written, first.written);
    assert!(
        std::fs::read_to_string(&first.written[0])
            .unwrap()
            .contains("# Second name")
    );
    assert_eq!(std::fs::read_dir(&destination).unwrap().count(), 2);

    let mut sample = finished_meeting(&library, "Sample", "Made up.");
    sample.sample_id = Some("lokalbot-sample".into());
    library.save_meeting(&sample).unwrap();
    assert!(sample.is_sample());
    let third = run(&library, &config, &HashMap::new());
    assert!(
        third
            .written
            .iter()
            .all(|path| !path.to_string_lossy().contains("Sample"))
    );
    assert_eq!(std::fs::read_dir(&destination).unwrap().count(), 2);
}

fn note(meeting: Meeting) -> Note {
    Note {
        meeting,
        people: vec!["Ana Díaz".into()],
        projects: vec!["Atlas [core]".into()],
        summary: Some("# Title\n\n## Action items\n\nold items\n\n## Other\n\nkept".into()),
        actions: Vec::new(),
        transcript: Some("**[00:00:01] Me:** token=abcdef123456 said it".into()),
    }
}

#[test]
fn each_format_carries_its_own_front_matter_and_secrets_go() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let meeting = finished_meeting(&library, "Atlas: \"sync\"", "x");
    let source = note(meeting.clone());

    let markdown = meeting_notes::render(&source, ExportFormat::Markdown);
    assert!(markdown.starts_with(&format!(
        "{}\n\n# Atlas: \"sync\"\n\n- **When:** September 29, 2026, 10:30 · 45 min",
        meeting_notes::GENERATED_FILE_MARKER
    )));
    assert!(markdown.contains("- **People:** Ana Díaz"));
    assert!(markdown.contains("- **Projects:** Atlas \\[core\\]"));

    let obsidian = meeting_notes::render(&source, ExportFormat::Obsidian);
    assert!(obsidian.starts_with("---\naliases:\n  - \"Atlas: \\\"sync\\\"\"\ndate: 2026-09-29\n"));
    assert!(obsidian.contains("people:\n  - \"[[Ana Díaz]]\"\n"));
    assert!(obsidian.contains("projects:\n  - \"[[Atlas core]]\"\n"));
    assert!(obsidian.contains("tags:\n  - lokalbot/meeting\n"));
    assert!(obsidian.contains(&format!("lokalbot-id: \"{}\"", meeting.short_id())));

    let logseq = meeting_notes::render(&source, ExportFormat::Logseq);
    assert!(
        logseq.starts_with("date:: 2026-09-29\npeople:: [[Ana Díaz]]\nprojects:: [[Atlas core]]\n")
    );
    assert!(logseq.contains("tags:: lokalbot, meeting\n"));
    assert!(logseq.contains("10:30 · 45 min · Zoom"));

    for text in [&markdown, &obsidian, &logseq] {
        assert!(text.contains("## Transcript\n\n"));
        assert!(!text.contains("abcdef123456"), "{text}");
        assert!(text.contains("[REDACTED]"));
    }
}

#[test]
fn the_action_list_marks_status_and_replaces_the_summarys_section() {
    use lokalbot_core::{ActionItem, ActionReference, ActionStatus};
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let meeting = finished_meeting(&library, "Sync", "x");
    let at = meeting.started_at;
    let reference = |id: &str, text: &str, owner: Option<&str>, for_user: bool, status| {
        let action = ActionItem {
            id: id.into(),
            schema_version: 1,
            text: text.into(),
            owner: owner.map(str::to_string),
            due: (id == "a").then(|| "Friday".to_string()),
            is_for_user: for_user,
            importance: 1,
            citations: Vec::new(),
            attribution: None,
        };
        ActionReference {
            id: id.into(),
            meeting_id: meeting.id,
            meeting_title: meeting.title.clone(),
            meeting_started_at: at,
            action_id: id.into(),
            text: text.into(),
            original_text: text.into(),
            owner: owner.map(str::to_string),
            due: action.due.clone(),
            resolved_due_date: None,
            is_for_user: for_user,
            status,
            importance: 1,
            citations: Vec::new(),
            action,
            state_updated_at: at,
            text_was_corrected: false,
            owner_was_corrected: false,
            due_was_corrected: false,
            text_corrected_at: None,
            owner_corrected_at: None,
            due_corrected_at: None,
            is_thread_excluded: false,
        }
    };
    let actions = vec![
        reference("a", "Send the notes", Some("Me"), true, ActionStatus::Done),
        reference(
            "b",
            "Review the doc",
            Some("Ana"),
            false,
            ActionStatus::Open,
        ),
        reference(
            "c",
            "Book the room",
            Some("Ana"),
            false,
            ActionStatus::Deferred,
        ),
    ];
    let lines = meeting_notes::action_lines(&actions, ExportFormat::Markdown);
    assert_eq!(lines[0], "### Me");
    assert_eq!(lines[1], "- [x] Send the notes — due Friday");
    assert_eq!(lines[3], "### Others");
    assert_eq!(lines[4], "- [ ] Ana: Review the doc");
    assert_eq!(lines[5], "- [ ] Ana: Book the room — deferred");
    let logseq = meeting_notes::action_lines(&actions, ExportFormat::Logseq);
    assert_eq!(logseq[1], "- DONE Send the notes — due Friday");
    assert_eq!(logseq[4], "- TODO Ana: Review the doc");
    // No owner group stays out until something belongs in it.
    assert!(!lines.iter().any(|line| line == "### Owner unclear"));
    let empty = meeting_notes::action_lines(&actions[1..], ExportFormat::Markdown);
    assert_eq!(empty[1], "None");

    let mut with_actions = note(meeting);
    with_actions.actions = actions;
    let text = meeting_notes::render(&with_actions, ExportFormat::Markdown);
    assert!(text.contains("## Action items\n\n### Me\n- [x] Send the notes"));
    assert!(!text.contains("old items"));
    assert!(text.contains("## Other\n\nkept"));
}

#[test]
fn existing_notes_prefer_the_one_lokalbot_wrote() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path();
    let id = "0123abcd";
    std::fs::write(folder.join(format!("2026-01-01 A ({id}).md")), "copy").unwrap();
    std::fs::write(folder.join(format!("2026-01-01 B ({id}).md")), "owned").unwrap();
    std::fs::write(
        folder.join(format!(".2026-01-01 B ({id}).md.lokalbot-generated.sha256")),
        "v1:x\n",
    )
    .unwrap();
    std::fs::write(
        folder.join(".2026-01-02 C (deadbeef).md.lokalbot-generated.sha256"),
        "v1:x\n",
    )
    .unwrap();
    std::fs::write(folder.join("unrelated.md"), "x").unwrap();
    let existing = ExistingNotes::read(folder).unwrap();
    assert_eq!(existing.names[id], format!("2026-01-01 B ({id}).md"));
    assert_eq!(existing.names.len(), 1);
    assert!(existing.removed.contains("deadbeef"));
}

fn day() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 9, 29).unwrap()
}

#[test]
fn the_daily_note_reads_the_day_and_names_its_file_by_format() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    finished_meeting(&library, "Atlas sync", "x");
    let (start, _) = lokalbot_core::time::local_day_bounds(day());
    library
        .append_activity("Editor", "main.rs", start, start + Duration::hours(2))
        .unwrap();
    let moment = library
        .record_screen_moment(&NewScreenMoment {
            ts: start + Duration::hours(1),
            app: "Editor".into(),
            window_title: "main.rs".into(),
            text: "Some captured text".into(),
            ..Default::default()
        })
        .unwrap();
    library.save_moment(moment, "remember this").unwrap();
    let destination = dir.path().join("daily");

    let outcome = daily::export(
        &library,
        day(),
        &destination,
        DailyMemoryExportFormat::Markdown,
        daily::Pass::Refresh,
    )
    .unwrap();
    let daily::Outcome::Written(path) = outcome else {
        panic!("expected a new file");
    };
    assert_eq!(path, destination.join("2026-09-29.md"));
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.starts_with(&format!(
        "{}\n\n# Daily memory — September 29, 2026\n\n## Digest\n\n_No day digest was generated._\n\n## Meetings\n\n- **10:30** — Atlas sync · 45m (`",
        daily::GENERATED_FILE_MARKER
    )));
    assert!(text.contains(&format!("(`screen:{moment}`)")));
    assert!(text.contains("  - Note: remember this"));
    assert!(text.contains("  - OCR: Some captured text"));
    assert!(text.contains("| Tracked time | 2h 0m |"));
    assert!(text.contains("| Saved moments | 1 |"));
    assert!(text.contains("- Editor: 2h 0m"));

    // Identical content isn't rewritten.
    assert_eq!(
        daily::export(
            &library,
            day(),
            &destination,
            DailyMemoryExportFormat::Markdown,
            daily::Pass::Refresh,
        )
        .unwrap(),
        daily::Outcome::Unchanged(path.clone())
    );
    // A catch-up leaves any existing file alone.
    assert_eq!(
        daily::export(
            &library,
            day(),
            &destination,
            DailyMemoryExportFormat::Markdown,
            daily::Pass::CatchUp,
        )
        .unwrap(),
        daily::Outcome::Skipped
    );
    let logseq = dir.path().join("graph");
    let daily::Outcome::Written(path) = daily::export(
        &library,
        day(),
        &logseq,
        DailyMemoryExportFormat::Logseq,
        daily::Pass::Refresh,
    )
    .unwrap() else {
        panic!("expected a new file");
    };
    assert_eq!(path, logseq.join("2026_09_29.md"));
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.starts_with("title:: Daily memory — September 29, 2026\ndate:: 2026-09-29\ntags:: lokalbot, daily-memory\n\n"));
}

#[test]
fn a_catch_up_skips_an_empty_day_and_a_refresh_respects_the_persons_edits() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let destination = dir.path().join("daily");
    let empty = day() - Duration::days(30);
    assert_eq!(
        daily::export(
            &library,
            empty,
            &destination,
            DailyMemoryExportFormat::Markdown,
            daily::Pass::CatchUp
        )
        .unwrap(),
        daily::Outcome::Skipped
    );
    assert!(!destination.exists());

    std::fs::create_dir_all(&destination).unwrap();
    let mine = destination.join("2026-09-29.md");
    std::fs::write(&mine, "my own note").unwrap();
    assert!(matches!(
        daily::export(
            &library,
            day(),
            &destination,
            DailyMemoryExportFormat::Markdown,
            daily::Pass::Refresh
        ),
        Err(daily::ExportError::DestinationCollision(_))
    ));
    assert_eq!(std::fs::read_to_string(&mine).unwrap(), "my own note");
}

#[test]
fn the_digest_appears_only_while_generated_unedited_and_current() {
    let dir = tempfile::tempdir().unwrap();
    let library = library(dir.path());
    let (start, _) = lokalbot_core::time::local_day_bounds(day());
    library
        .append_activity("Editor", "main.rs", start, start + Duration::hours(1))
        .unwrap();
    let (signature, meeting_signature) =
        lokalbot_ai::digest::evidence_signatures(&library, day()).unwrap();
    let meta = lokalbot_core::model::DigestMeta {
        evidence_signature: Some(signature),
        meeting_evidence_signature: Some(meeting_signature),
        ..serde_json::from_value(serde_json::json!({
            "version": 2,
            "quality": "complete",
            "generatedAt": 800_000_000.0,
        }))
        .unwrap()
    };
    library
        .save_digest(day(), "## Day summary\n\nThe digest.\n", &meta)
        .unwrap();
    let snapshot = daily::snapshot(&library, day()).unwrap();
    assert!(
        snapshot
            .digest
            .as_deref()
            .is_some_and(|d| d.contains("The digest."))
    );
    assert!(!snapshot.digest_is_out_of_date);

    // New evidence makes it out of date; it's left out and the note says so.
    library
        .append_activity(
            "Editor",
            "more.rs",
            start + Duration::hours(2),
            start + Duration::hours(3),
        )
        .unwrap();
    let snapshot = daily::snapshot(&library, day()).unwrap();
    assert_eq!(snapshot.digest, None);
    assert!(snapshot.digest_is_out_of_date);
    assert!(
        daily::render(&snapshot, DailyMemoryExportFormat::Markdown)
            .contains("_The day's digest is out of date. It is added here once it is updated._")
    );

    // An edited journal is the person's, and stays out of the export.
    std::fs::write(library.journal_path(day()), "edited").unwrap();
    let snapshot = daily::snapshot(&library, day()).unwrap();
    assert_eq!(snapshot.digest, None);
    assert!(!snapshot.digest_is_out_of_date);
}

fn at(hour: u32) -> chrono::DateTime<Local> {
    Local
        .from_local_datetime(&day().and_hms_opt(hour, 0, 0).unwrap())
        .single()
        .unwrap()
}

#[test]
fn the_daily_schedule_catches_up_then_waits_for_the_hour() {
    let none = HashSet::new();
    // Past days first, oldest first.
    assert_eq!(
        next_daily_export(at(8), 18, None, &none, &none),
        Some((day() - Duration::days(7), daily::Pass::CatchUp))
    );
    let caught: HashSet<NaiveDate> = (1..=7).map(|back| day() - Duration::days(back)).collect();
    assert_eq!(next_daily_export(at(8), 18, None, &caught, &none), None);
    assert_eq!(
        next_daily_export(at(18), 18, None, &caught, &none),
        Some((day(), daily::Pass::Refresh))
    );
    assert_eq!(
        next_daily_export(at(19), 18, Some(day()), &caught, &none),
        None
    );
    // A reopened day comes first, outside the window doesn't count.
    let reopened: HashSet<NaiveDate> =
        [day() - Duration::days(2), day() - Duration::days(20)].into();
    assert_eq!(
        next_daily_export(at(8), 18, None, &caught, &reopened),
        Some((day() - Duration::days(2), daily::Pass::Refresh))
    );
}
