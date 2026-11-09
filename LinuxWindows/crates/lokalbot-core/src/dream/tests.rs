use std::collections::BTreeSet;

use chrono::{Local, NaiveDate, TimeZone as _, Utc};

use super::store::{GENERATED_MARKER, Revocation};
use super::*;
use crate::evidence::{self, Provenance, Source};

fn at() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 20, 8, 0, 0).unwrap()
}

fn store() -> (tempfile::TempDir, DreamStore) {
    let dir = tempfile::tempdir().unwrap();
    let store = DreamStore::new(dir.path());
    (dir, store)
}

fn source(kind: &str, id: &str, day: &str) -> Source {
    Source {
        kind: kind.into(),
        id: id.into(),
        day_key: day.into(),
    }
}

fn provenance(revision: u64, sources: Vec<Source>) -> Provenance {
    Provenance {
        sources,
        revision,
        includes_unattributed_context: false,
    }
}

const MEETING: &str = "4E1C1B59-6E0B-4F38-9E57-3C1B1F0A2D11";

/// `dreams/<day>.json` as the Mac writes it: pretty, sorted, ISO dates, and
/// optional fields left out rather than null.
const MAC_REPORT: &str = r#"{
  "attention" : [ "Beta blocked on review" ],
  "day" : "2026-10-19",
  "engineName" : "Qwen3.5 4B",
  "evidenceProvenance" : {
    "includesUnattributedContext" : false,
    "revision" : 4,
    "sources" : [
      { "dayKey" : "2026-10-19", "id" : "4E1C1B59-6E0B-4F38-9E57-3C1B1F0A2D11", "kind" : "meeting" },
      { "dayKey" : "2026-10-19", "id" : "2026-10-19", "kind" : "screenDay" }
    ]
  },
  "frictions" : [ ],
  "generatedAt" : "2026-10-20T04:00:12Z",
  "inferenceProvenance" : { "location" : "remote", "origin" : "https://llm.example.com" },
  "narrative" : "The beta moved forward.",
  "repeatedWork" : [ ],
  "suggestedChecks" : [ ],
  "topActionThreadIDs" : [ "thread-00000000000000ab", null ],
  "topActions" : [ "Send the deck", "Book the room" ],
  "version" : 3
}"#;

/// `memory/memory.json` as the Mac writes it.
const MAC_MEMORY: &str = r#"{
  "activeProjects" : [ {
    "evidence" : [ "Review moved to Friday" ],
    "lastActiveDay" : "2026-10-19",
    "name" : "Beta launch",
    "pinned" : true,
    "provenance" : {
      "includesUnattributedContext" : false, "revision" : 4,
      "sources" : [ { "dayKey" : "2026-10-19", "id" : "4E1C1B59-6E0B-4F38-9E57-3C1B1F0A2D11", "kind" : "meeting" } ]
    },
    "status" : "blocked on review"
  } ],
  "lastDreamDay" : "2026-10-19",
  "patternProvenance" : {
    "Reviews slip by a day" : { "includesUnattributedContext" : false, "revision" : 4, "sources" : [ ] }
  },
  "recurringPatterns" : [ "Reviews slip by a day" ],
  "updatedAt" : "2026-10-20T04:00:12Z",
  "version" : 2,
  "workGoals" : [ {
    "horizon" : "this month",
    "lastReinforcedDay" : "2026-10-18",
    "text" : "Ship the beta"
  } ]
}"#;

#[test]
fn it_reads_and_rewrites_the_macs_report_with_the_same_keys() {
    let report: DreamReport = serde_json::from_str(MAC_REPORT).unwrap();
    assert_eq!(
        report.top_action_thread_id(0),
        Some("thread-00000000000000ab")
    );
    assert_eq!(report.top_action_thread_id(1), None);
    assert_eq!(
        report
            .inference_provenance
            .as_ref()
            .unwrap()
            .origin
            .as_deref(),
        Some("https://llm.example.com")
    );
    let written = serde_json::to_value(&report).unwrap();
    let original: serde_json::Value = serde_json::from_str(MAC_REPORT).unwrap();
    assert_eq!(written, original);
}

#[test]
fn it_reads_and_rewrites_the_macs_memory_with_the_same_keys() {
    let memory: DreamMemory = serde_json::from_str(MAC_MEMORY).unwrap();
    assert!(memory.active_projects[0].pinned);
    assert!(!memory.work_goals[0].pinned);
    let written = serde_json::to_value(&memory).unwrap();
    assert_eq!(written["updatedAt"], "2026-10-20T04:00:12Z");
    assert_eq!(written["activeProjects"][0]["lastActiveDay"], "2026-10-19");
    assert_eq!(
        written["patternProvenance"]["Reviews slip by a day"]["revision"],
        4
    );
    assert!(
        memory
            .markdown()
            .contains("- **Beta launch** — blocked on review _(pinned, last active 2026-10-19)_")
    );
}

#[test]
fn a_saved_report_is_the_days_completion_marker_with_a_markdown_copy() {
    let (dir, store) = store();
    let report = DreamReport::new("2026-10-19".into(), at(), "A day.".into());
    store.save_generated(&report, None, 0).unwrap();
    assert!(store.has_report("2026-10-19"));
    assert!(!store.has_report("2026-10-18"));
    let markdown = std::fs::read_to_string(dir.path().join("dreams/2026-10-19.md")).unwrap();
    assert!(markdown.starts_with(GENERATED_MARKER));
    assert!(markdown.contains("# Morning brief — 2026-10-19"));
    assert_eq!(store.latest_report().unwrap().day, "2026-10-19");
    // A file whose day doesn't match its name is not a marker.
    std::fs::copy(
        dir.path().join("dreams/2026-10-19.json"),
        dir.path().join("dreams/2026-10-18.json"),
    )
    .unwrap();
    assert!(!store.has_report("2026-10-18"));
}

#[test]
fn a_review_overtaken_by_a_change_to_its_sources_is_not_saved() {
    let (dir, store) = store();
    let revision = store.evidence_revision().unwrap();
    let mut report = DreamReport::new("2026-10-19".into(), at(), "A day.".into());
    report.evidence_provenance = Some(provenance(
        revision,
        vec![source("meeting", MEETING, "2026-10-19")],
    ));
    store
        .invalidate_evidence(
            &Revocation {
                days: BTreeSet::from(["2026-10-19".to_string()]),
                ..Default::default()
            },
            at(),
        )
        .unwrap();
    assert!(matches!(
        store.save_generated(&report, None, revision),
        Err(StoreError::Cancelled)
    ));
    assert!(!dir.path().join("dreams/2026-10-19.json").exists());
}

#[test]
fn a_change_to_another_day_does_not_discard_the_run() {
    let (_dir, store) = store();
    let revision = store.evidence_revision().unwrap();
    let mut report = DreamReport::new("2026-10-19".into(), at(), "A day.".into());
    report.evidence_provenance = Some(provenance(
        revision,
        vec![source("screenDay", "2026-10-19", "2026-10-19")],
    ));
    store
        .invalidate_evidence(
            &Revocation {
                days: BTreeSet::from(["2026-09-01".to_string()]),
                ..Default::default()
            },
            at(),
        )
        .unwrap();
    store.save_generated(&report, None, revision).unwrap();
    assert!(store.has_report("2026-10-19"));
}

#[test]
fn source_deletion_retracts_even_pinned_items_and_their_reports() {
    let (dir, store) = store();
    let mut memory: DreamMemory = serde_json::from_str(MAC_MEMORY).unwrap();
    // The goal has no provenance, so the first change takes it too.
    memory.active_projects[0].provenance = Some(provenance(
        0,
        vec![source("meeting", MEETING, "2026-10-19")],
    ));
    let mut report = DreamReport::new("2026-10-19".into(), at(), "A day.".into());
    report.evidence_provenance = Some(provenance(
        0,
        vec![source("meeting", MEETING, "2026-10-19")],
    ));
    store.save_generated(&report, Some(&memory), 0).unwrap();
    assert_eq!(
        store.load_memory().unwrap().unwrap().active_projects.len(),
        1
    );

    let meeting: crate::Meeting = serde_json::from_value(serde_json::json!({
        "id": MEETING, "title": "Review", "appName": "Zoom",
        "startedAt": "2026-10-19T09:00:00Z", "endedAt": "2026-10-19T09:30:00Z",
        "relativePath": "meetings/x"
    }))
    .unwrap();
    evidence::with_meeting_removal(dir.path(), &[&meeting], || Ok(())).unwrap();

    let memory = store.load_memory().unwrap().unwrap();
    assert!(
        memory.active_projects.is_empty(),
        "pinned goes with its source"
    );
    assert!(memory.work_goals.is_empty());
    assert!(!store.has_report("2026-10-19"));
    assert!(!dir.path().join("dreams/2026-10-19.json").exists());
    // The rewritten memory no longer holds them for anyone reading the file.
    let on_disk = std::fs::read_to_string(dir.path().join("memory/memory.json")).unwrap();
    assert!(!on_disk.contains("Beta launch"));
    // The windows after a meeting are reopened too.
    assert_eq!(evidence::read_state(dir.path()).unwrap().revision, 1);
    assert!(!dir.path().join(evidence::PENDING_FILE).exists());
}

#[test]
fn an_unfinished_revocation_blocks_use_until_it_is_recovered() {
    let (dir, store) = store();
    let mut memory: DreamMemory = serde_json::from_str(MAC_MEMORY).unwrap();
    memory.active_projects[0]
        .provenance
        .as_mut()
        .unwrap()
        .revision = 0;
    store.save_memory(&memory).unwrap();
    // The Mac crashed after writing its intent.
    std::fs::write(
        dir.path().join(evidence::PENDING_FILE),
        format!(
            r#"[{{"id":"{MEETING}","days":["2026-10-19"],"meetings":[],"reports":["2026-10-19"],
            "awaitingSourceMutation":false}}]"#
        ),
    )
    .unwrap();
    assert!(store.load_memory().unwrap().is_none());
    assert!(!store.has_report("2026-10-19"));
    assert!(store.evidence_check().is_none());
    assert!(evidence::read_work_memory(dir.path()).is_none());
    assert!(matches!(
        store.save_memory(&memory),
        Err(StoreError::RetractionIncomplete)
    ));

    // The scheduler's next revision read finishes the cleanup.
    assert_eq!(store.evidence_revision().unwrap(), 1);
    assert!(!dir.path().join(evidence::PENDING_FILE).exists());
    let memory = store.load_memory().unwrap().unwrap();
    assert!(memory.active_projects.is_empty());
}

#[test]
fn clear_all_removes_everything_and_a_review_begun_before_it_cant_write_back() {
    let (dir, store) = store();
    let memory: DreamMemory = serde_json::from_str(MAC_MEMORY).unwrap();
    let report = DreamReport::new("2026-10-19".into(), at(), "A day.".into());
    let revision = store.evidence_revision().unwrap();
    store
        .save_generated(&report, Some(&memory), revision)
        .unwrap();
    rollup::write(
        &rollup::Rollup {
            kind: rollup::Kind::Week,
            key: "2026-W42".into(),
            first_day: "2026-10-12".into(),
            last_day: "2026-10-18".into(),
            line: "A week.".into(),
            stamp: "x".into(),
            generated_at: at(),
        },
        dir.path(),
    )
    .unwrap();

    store.clear_all().unwrap();
    assert!(store.load_memory().unwrap().is_none());
    assert_eq!(
        std::fs::read_dir(dir.path().join("dreams"))
            .unwrap()
            .count(),
        0
    );
    assert!(!dir.path().join("memory/memory.md").exists());
    assert!(matches!(
        store.save_generated(&report, Some(&memory), revision),
        Err(StoreError::Cancelled)
    ));
}

#[test]
fn pins_reload_before_changing_and_a_gone_item_says_so() {
    let (_dir, store) = store();
    let memory: DreamMemory = serde_json::from_str(MAC_MEMORY).unwrap();
    store.save_memory(&memory).unwrap();
    let updated = store
        .set_pinned(true, &MemoryEntry::Goal("SHIP THE BETA".into()), at())
        .unwrap()
        .unwrap();
    assert!(updated.work_goals[0].pinned);
    assert!(store.load_memory().unwrap().unwrap().work_goals[0].pinned);
    assert!(
        store
            .set_pinned(true, &MemoryEntry::Project("Gone".into()), at())
            .unwrap()
            .is_none()
    );
}

fn project(name: &str, active: Option<bool>) -> ProposedProject {
    ProposedProject {
        name: name.into(),
        status: "moving".into(),
        evidence: vec!["e".into()],
        active_today: active,
    }
}

fn goal(text: &str, reinforced: bool, expired: bool) -> ProposedGoal {
    ProposedGoal {
        text: text.into(),
        horizon: "this month".into(),
        reinforced_today: reinforced,
        expired,
    }
}

#[test]
fn the_merge_follows_the_days_evidence_and_keeps_what_the_model_forgot() {
    let memory: DreamMemory = serde_json::from_str(MAC_MEMORY).unwrap();
    let merged = memory.merging(
        &MemoryUpdate {
            active_projects: vec![
                project("BETA LAUNCH", Some(false)),
                project("Carried only", Some(false)),
                project("New work", Some(true)),
            ],
            work_goals: vec![
                goal("Ship the beta", false, false),
                goal("Invented goal", false, false),
                goal("Real goal", true, false),
            ],
            recurring_patterns: vec![],
        },
        "2026-10-20",
        at(),
        None,
    );
    let names: Vec<&str> = merged
        .active_projects
        .iter()
        .map(|p| p.name.as_str())
        .collect();
    // A pinned project sorts first; an inactive one is never inserted.
    assert_eq!(names, vec!["Beta launch", "New work"]);
    assert_eq!(merged.active_projects[0].last_active_day, "2026-10-19");
    let goals: Vec<&str> = merged.work_goals.iter().map(|g| g.text.as_str()).collect();
    assert_eq!(goals, vec!["Real goal", "Ship the beta"]);
    assert_eq!(merged.work_goals[1].last_reinforced_day, "2026-10-18");
    // An explicit empty list clears the patterns.
    assert!(merged.recurring_patterns.is_empty());
    assert!(merged.pattern_provenance.is_empty());
    assert_eq!(merged.last_dream_day.as_deref(), Some("2026-10-20"));
}

#[test]
fn old_entries_age_out_expiry_needs_evidence_and_pins_stay() {
    let mut memory: DreamMemory = serde_json::from_str(MAC_MEMORY).unwrap();
    memory.active_projects[0].pinned = false;
    memory.active_projects.push(MemoryProject {
        name: "Pinned old".into(),
        status: "s".into(),
        last_active_day: "2020-01-01".into(),
        evidence: vec![],
        pinned: true,
        provenance: None,
    });
    memory.work_goals.push(MemoryGoal {
        text: "Pinned goal".into(),
        horizon: "h".into(),
        last_reinforced_day: "2020-01-01".into(),
        pinned: true,
        provenance: None,
    });
    let merged = memory.merging(
        &MemoryUpdate {
            work_goals: vec![
                goal("Ship the beta", false, true),
                goal("Pinned goal", false, true),
            ],
            ..Default::default()
        },
        "2026-12-25",
        at(),
        None,
    );
    assert_eq!(merged.active_projects.len(), 1);
    assert_eq!(merged.active_projects[0].name, "Pinned old");
    assert_eq!(merged.work_goals.len(), 1);
    assert_eq!(merged.work_goals[0].text, "Pinned goal");
}

#[test]
fn memory_is_capped() {
    let memory = DreamMemory::empty(at());
    let merged = memory.merging(
        &MemoryUpdate {
            active_projects: (0..30)
                .map(|i| project(&format!("P{i}"), Some(true)))
                .collect(),
            work_goals: (0..30)
                .map(|i| goal(&format!("G{i}"), true, false))
                .collect(),
            recurring_patterns: (0..30).map(|i| format!("R{i}")).collect(),
        },
        "2026-10-20",
        at(),
        None,
    );
    assert_eq!(merged.active_projects.len(), MAX_PROJECTS);
    assert_eq!(merged.work_goals.len(), MAX_GOALS);
    assert_eq!(merged.recurring_patterns.len(), MAX_PATTERNS);
}

#[test]
fn a_synthesis_depends_on_everything_memory_depends_on() {
    let mut memory = DreamMemory::empty(at());
    memory.active_projects.push(MemoryProject {
        name: "Old".into(),
        status: "s".into(),
        last_active_day: "2026-10-01".into(),
        evidence: vec![],
        pinned: false,
        provenance: Some(provenance(
            1,
            vec![source("meeting", MEETING, "2026-10-01")],
        )),
    });
    let provenance = memory.provenance_adding(&[source("digest", "2026-10-19", "2026-10-19")], 9);
    assert_eq!(provenance.revision, 9);
    assert_eq!(provenance.sources.len(), 2);
    assert!(!provenance.includes_unattributed_context);

    memory.work_goals.push(MemoryGoal {
        text: "Legacy".into(),
        horizon: "h".into(),
        last_reinforced_day: "2026-10-01".into(),
        pinned: false,
        provenance: None,
    });
    assert!(
        memory
            .provenance_adding(&[], 9)
            .includes_unattributed_context
    );
}

#[test]
fn secrets_never_reach_a_saved_report_or_memory() {
    let mut report = DreamReport::new(
        "2026-10-19".into(),
        at(),
        "Used token: abcdefghijklmnop today.".into(),
    );
    report.top_actions = vec!["Rotate sk-abcdefghijklmnopqrstuvwx".into()];
    let scrubbed = report.redacted();
    assert!(!scrubbed.narrative.contains("abcdefghijklmnop"));
    assert!(scrubbed.top_actions[0].contains("[REDACTED_KEY]"));

    let mut memory = DreamMemory::empty(at());
    memory.recurring_patterns = vec!["sk-abcdefghijklmnopqrstuvwx leaks".into()];
    assert!(memory.redacted().recurring_patterns[0].contains("[REDACTED_KEY]"));
}

#[test]
fn report_days_cover_the_following_comparison_windows_up_to_today() {
    let day = NaiveDate::from_ymd_opt(2026, 10, 1).unwrap();
    let today = NaiveDate::from_ymd_opt(2026, 10, 5).unwrap();
    let keys = report_day_keys([day], today, COMPARISON_WINDOW_DAYS);
    assert_eq!(keys.len(), 5);
    assert!(keys.contains("2026-10-05"));
    assert_eq!(report_day_keys([day], today, 1).len(), 1);
}

// ------------------------------------------------------------------ rollups

fn review(day: &str, generated: &str) -> rollup::DayReview {
    rollup::DayReview {
        day: day.into(),
        generated_at: crate::time::parse_iso(generated).unwrap(),
        narrative: "One sentence. Two sentences. Three.".into(),
    }
}

#[test]
fn weeks_and_months_use_the_macs_keys() {
    // 2026-10-07 is a Wednesday in ISO week 41.
    let week = rollup::week_containing(NaiveDate::from_ymd_opt(2026, 10, 7).unwrap());
    assert_eq!(week.key, "2026-W41");
    assert_eq!(week.first_day, "2026-10-05");
    assert_eq!(week.last_day, "2026-10-11");
    assert_eq!(week.label, "Week of Oct 5");
    let month = rollup::month_containing(NaiveDate::from_ymd_opt(2026, 2, 7).unwrap());
    assert_eq!(month.key, "2026-02");
    assert_eq!(month.last_day, "2026-02-28");
    assert_eq!(month.label, "February 2026");
}

#[test]
fn only_finished_periods_are_offered_newest_first() {
    let today = NaiveDate::from_ymd_opt(2026, 10, 7).unwrap();
    let periods = rollup::periods(today);
    assert!(periods.iter().all(|p| p.last_day.as_str() < "2026-10-07"));
    assert_eq!(periods[0].key, "2026-W40");
    assert!(periods.iter().any(|p| p.key == "2026-09"));
    assert_eq!(periods.len(), 14);
}

#[test]
fn a_rollups_stamp_goes_stale_when_a_review_changes_and_matches_the_macs_format() {
    let mut reviews = std::collections::HashMap::new();
    reviews.insert(
        "2026-10-05".to_string(),
        review("2026-10-05", "2026-10-06T04:00:00Z"),
    );
    let inside = rollup::reviews_in("2026-10-05", "2026-10-11", &reviews);
    let stamp = rollup::stamp(&inside);
    // SHA-256 of "2026-10-05|2026-10-06T04:00:00Z".
    assert_eq!(
        stamp,
        crate::library::sha256_hex(b"2026-10-05|2026-10-06T04:00:00Z")
    );
    let line = rollup::Rollup {
        kind: rollup::Kind::Week,
        key: "2026-W41".into(),
        first_day: "2026-10-05".into(),
        last_day: "2026-10-11".into(),
        line: "A week.".into(),
        stamp,
        generated_at: at(),
    };
    assert!(rollup::is_valid(&line, &reviews));
    reviews.insert(
        "2026-10-05".to_string(),
        review("2026-10-05", "2026-10-07T04:00:00Z"),
    );
    assert!(!rollup::is_valid(&line, &reviews));
    reviews.clear();
    assert!(!rollup::is_valid(&line, &reviews));
}

#[test]
fn deleting_a_report_removes_the_lines_covering_it() {
    let (dir, store) = store();
    let report = DreamReport::new("2026-10-06".into(), at(), "A day.".into());
    store.save_generated(&report, None, 0).unwrap();
    let line = rollup::Rollup {
        kind: rollup::Kind::Week,
        key: "2026-W41".into(),
        first_day: "2026-10-05".into(),
        last_day: "2026-10-11".into(),
        line: "A week.".into(),
        stamp: "s".into(),
        generated_at: at(),
    };
    rollup::write(&line, dir.path()).unwrap();
    assert_eq!(rollup::rollups(dir.path()).len(), 1);
    // A Mac can read what is written here.
    let json: serde_json::Value = serde_json::from_slice(
        &std::fs::read(rollup::rollup_path(dir.path(), "2026-W41")).unwrap(),
    )
    .unwrap();
    assert_eq!(json["kind"], "week");
    assert_eq!(json["firstDay"], "2026-10-05");
    store.invalidate_report("2026-10-06").unwrap();
    assert!(rollup::rollups(dir.path()).is_empty());
}

#[test]
fn sentences_stop_at_the_count_and_the_length() {
    assert_eq!(rollup::sentences("One. Two. Three.", 2, 100), "One. Two.");
    assert_eq!(rollup::sentences("No ending", 2, 100), "No ending");
    assert_eq!(
        rollup::sentences("Version 1.2 shipped.", 1, 100),
        "Version 1.2 shipped."
    );
    assert_eq!(rollup::sentences("abcdefghij", 1, 5), "abcd…");
}

#[test]
fn the_markdown_uses_a_local_date() {
    let memory = DreamMemory::empty(at());
    let local = at().with_timezone(&Local).format("%Y-%m-%d").to_string();
    assert!(memory.markdown().contains(&format!("Updated {local}")));
    assert!(memory.markdown().contains("_None observed yet._"));
}

#[test]
fn the_brief_says_where_the_model_ran() {
    let mut report = DreamReport::new("2026-10-19".into(), at(), "A day.".into());
    report.fallback_reason = Some(FallbackReason::EngineUnavailable);
    assert!(
        report
            .provenance_description()
            .contains("No model was reachable")
    );
    report.engine_name = Some("Local".into());
    report.inference_provenance = Some(InferenceProvenance::local());
    assert_eq!(
        report.provenance_description(),
        "Dreamed by Local on this computer."
    );
    report.inference_provenance = Some(InferenceProvenance::remote(Some(
        "https://x.example".into(),
    )));
    assert!(
        report
            .provenance_description()
            .contains("at https://x.example")
    );
}
