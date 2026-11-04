//! A synthetic library (`CompanionFixtureLibrary.swift`) that deliberately
//! holds every kind of private data that must never reach a phone, and the
//! host run end to end against the protocol's own client, on loopback only.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use chrono::{DateTime, Local, TimeZone as _, Utc};
use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
use lokalbot_ai::ask::AskScope;
use lokalbot_core::coding_agents::{CodingAgentBurst, CodingAgentKind};
use lokalbot_core::model::{
    ActionItem, ChatMessage, Decision, MeetingOutcomes, OutcomeSourceCitation, OutcomeState,
    ProjectCuration, ProjectPoint, ProjectSummary, Segment, SpeakerAttribution, TrackedProject,
    Transcript,
};
use lokalbot_core::timeline::NewScreenMoment;
use lokalbot_core::{Library, LibraryPaths, Meeting, Settings};
use lokalbot_sync::{AskListener, ClientConfig, SyncClient, SyncError};
use parking_lot::Mutex;
use serde_json::{Value, json};
use uuid::Uuid;

use super::advertise::{self, Advertiser};
use super::ask::{self, AskEngine, AskOutput, AskResponder, EngineAnswer};
use super::builder::{self, RecordBuilder};
use super::host::{self, Environment, Host, HostMessage};
use super::library::CompanionLibrary;
use super::ops;
use super::publisher::{Context, Publisher, RecordSink};
use super::records::{self, *};
use super::sharing::*;
use super::*;

const WINDOW_TITLE_SECRET: &str = "Quarterly-forecast-WINDOWTITLE-SECRET.xlsx";
const OCR_SECRET: &str = "OCR-SCREEN-TEXT-SECRET account 4417";
const SCREENSHOT_PATH_SECRET: &str = "SCREENSHOT-PATH-SECRET.jpg.enc";
const ATTENDEE_EMAIL_SECRET: &str = "maya.chen.attendee-secret@example-private.test";
const UNNAMED_ATTENDEE_EMAIL: &str = "zed@unnamed-attendee-secret.test";
const VOICE_PROFILE_SECRET: &str = "VOICE-PROFILE-EVIDENCE-SECRET";
const CALENDAR_IDENTITY_SECRET: &str = "calendar-identity-SECRET-42";
const AGENDA_SECRET: &str = "AGENDA-SECRET dial-in 555-0100";
const MEETING_URL_SECRET: &str = "https://zoom.example.test/j/MEETINGURL-SECRET";
const DREAM_SECRET: &str = "DREAM-MEMORY-SECRET project goal";
const PERSONAL_CONTEXT_SECRET: &str = "PERSONAL-CONTEXT-SECRET likes";
const REVIEW_NOTE_SECRET: &str = "OVERNIGHT-REVIEW-NOTE-SECRET";

/// Strings that must never appear in any record body.
const SECRETS: [&str; 17] = [
    OCR_SECRET,
    "account 4417",
    SCREENSHOT_PATH_SECRET,
    ATTENDEE_EMAIL_SECRET,
    "example-private.test",
    UNNAMED_ATTENDEE_EMAIL,
    "unnamed-attendee-secret.test",
    VOICE_PROFILE_SECRET,
    CALENDAR_IDENTITY_SECRET,
    AGENDA_SECRET,
    "MEETINGURL-SECRET",
    DREAM_SECRET,
    PERSONAL_CONTEXT_SECRET,
    REVIEW_NOTE_SECRET,
    "speaker-evidence",
    "attribution",
    "speakerCalendarIdentityIDs",
];

const PROJECT_ID: &str = "7a1d0c55-2b8f-4f3a-a6c4-5e6f7a8b9c01";

struct Fixture {
    _dir: tempfile::TempDir,
    library: Library,
    now: DateTime<Utc>,
    /// The day of the main meeting, at local noon.
    day: DateTime<Utc>,
    design_review: Meeting,
    older: Meeting,
    merged_source: Meeting,
    merged_parent: Meeting,
    sample: Meeting,
    live: Meeting,
    screenshot: i64,
}

fn key(meeting: &Meeting) -> String {
    records::id(meeting.id)
}

fn sharing() -> Sharing {
    Sharing {
        enabled: true,
        data_classes: DataClasses::ALL,
        history: HistoryWindow::All,
        answers_questions: true,
        port: 0,
        advertises: true,
    }
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
    let now = Local::now()
        .date_naive()
        .and_hms_opt(18, 0, 0)
        .map(|at| Local.from_local_datetime(&at).earliest().unwrap())
        .unwrap()
        .with_timezone(&Utc);
    let day = now - chrono::Duration::days(2) - chrono::Duration::hours(6);

    // The main meeting: calendar attendees with emails, an agenda, a link.
    let start = day - chrono::Duration::hours(1);
    let mut design = library
        .create_meeting("Design review — onboarding", "Zoom", start)
        .unwrap();
    design.ended_at = Some(start + chrono::Duration::seconds(2520));
    design.recorded_duration = Some(2520.0);
    design.calendar_title = Some("Design review — onboarding".into());
    design.meeting_url = Some(MEETING_URL_SECRET.into());
    design.calendar_agenda = Some(AGENDA_SECRET.into());
    design.participant_name_hints = Some(vec!["Maya Chen".into()]);
    design.calendar_participant_identities = Some(vec![
        lokalbot_core::model::CalendarParticipantIdentity {
            id: CALENDAR_IDENTITY_SECRET.into(),
            name: Some("Maya Chen".into()),
            email_address: Some(ATTENDEE_EMAIL_SECRET.into()),
        },
        lokalbot_core::model::CalendarParticipantIdentity {
            id: "cal-2".into(),
            name: None,
            email_address: Some(UNNAMED_ATTENDEE_EMAIL.into()),
        },
    ]);
    library.save_meeting(&design).unwrap();
    let mut transcript = Transcript {
        segments: vec![
            segment(0.0, 9.0, "me", "Let's cut onboarding to three steps.", true),
            segment(
                721.4,
                728.9,
                "them 1",
                "Could you send me the revised deck by Thursday?",
                false,
            ),
            segment(730.0, 734.0, "them 2", "Agreed, three steps.", false),
        ],
        engine: "fixture".into(),
        speaker_aliases: BTreeMap::new(),
        speaker_calendar_identity_ids: BTreeMap::new(),
        echo_report: None,
    };
    transcript.set_speaker_alias(Some("Maya Chen"), "them 1", Some(CALENDAR_IDENTITY_SECRET));
    library.save_transcript(&design, &transcript).unwrap();
    library
        .save_summary(
            &design,
            "# Design review — onboarding — October 30, 2026 at 10:30\n**Duration:** 42 min · **App:** Zoom · **Words:** 120 · **Template:** Meeting · **Model:** Fixture\n\n## Recap\nWe agreed to cut onboarding to three steps.\n",
        )
        .unwrap();
    library
        .save_notes(&design, "- Maya wants to lead the next design review")
        .unwrap();
    let mut deck = ActionItem::new(
        "Send the revised pricing deck to Maya",
        Some("Me"),
        Some("2026-11-03"),
        Some(true),
        4,
        vec![OutcomeSourceCitation {
            meeting_id: Some(design.id),
            segment_id: "s2".into(),
            start: 721.4,
            end: 728.9,
            speaker: "them 1".into(),
            excerpt: "Could you send me the revised deck by Thursday?".into(),
        }],
        None,
    );
    deck.id = "act-deck".into();
    let mut study = ActionItem::new(
        "Confirm the study participants",
        None,
        None,
        None,
        3,
        Vec::new(),
        None,
    );
    study.id = "act-study".into();
    let mut decision = Decision::new("Ship the three-step flow behind a flag first.", Vec::new());
    decision.id = "dec-flag".into();
    library
        .save_outcomes(
            &design,
            &MeetingOutcomes {
                action_items: vec![deck, study],
                decision_records: vec![decision],
                open_questions: vec!["Which five customers go first?".into()],
                ..MeetingOutcomes::default()
            },
        )
        .unwrap();
    library
        .set_action_status(
            &design,
            "act-study",
            lokalbot_core::model::ActionStatus::Deferred,
        )
        .unwrap();
    // Private speaker evidence beside the meeting; never read by builders.
    let evidence = library.meeting_dir(&design).join("speaker-evidence");
    std::fs::create_dir_all(&evidence).unwrap();
    std::fs::write(evidence.join("assignments.sealed"), VOICE_PROFILE_SECRET).unwrap();

    // An older meeting, outside a 30-day window.
    let older_day = day - chrono::Duration::days(45);
    let mut older = library
        .create_meeting("Pricing workshop", "Google Meet", older_day)
        .unwrap();
    older.ended_at = Some(older_day + chrono::Duration::seconds(1800));
    library.save_meeting(&older).unwrap();

    // A merge: the source is folded into the parent and never shared.
    let source_start = day - chrono::Duration::hours(2);
    let mut merged_parent = library
        .create_meeting("Standup", "Zoom", source_start)
        .unwrap();
    merged_parent.ended_at = Some(source_start + chrono::Duration::seconds(600));
    let mut merged_source = library
        .create_meeting("Standup part 1", "Zoom", source_start)
        .unwrap();
    merged_source.ended_at = Some(source_start + chrono::Duration::seconds(300));
    merged_source.merged_into_meeting_id = Some(merged_parent.id);
    merged_parent.merged_source_meeting_ids = Some(vec![merged_source.id]);
    library.save_meeting(&merged_source).unwrap();
    library.save_meeting(&merged_parent).unwrap();

    // LokalBot's bundled sample meeting is made up and never shared.
    let sample_start = day - chrono::Duration::hours(3);
    let mut sample = library
        .create_meeting("Orders API sample", "Sample", sample_start)
        .unwrap();
    sample.ended_at = Some(sample_start + chrono::Duration::seconds(1000));
    sample.sample_id = Some("orders-api/en".into());
    library.save_meeting(&sample).unwrap();

    // A meeting still being recorded.
    let live = library
        .create_meeting(
            "Still recording",
            "Zoom",
            now - chrono::Duration::minutes(5),
        )
        .unwrap();

    // Activity: window titles, a screen moment with a path and text, a saved
    // moment, and a coding-agent burst.
    let block_start = day + chrono::Duration::minutes(30);
    library
        .append_activity(
            "Numbers",
            WINDOW_TITLE_SECRET,
            block_start,
            block_start + chrono::Duration::minutes(25),
        )
        .unwrap();
    let second = day + chrono::Duration::seconds(3400);
    library
        .append_activity(
            "Xcode",
            "OnboardingFlow.swift",
            second,
            second + chrono::Duration::minutes(20),
        )
        .unwrap();
    let screenshot = library
        .record_screen_moment(&NewScreenMoment {
            ts: day + chrono::Duration::seconds(2000),
            app: "Numbers".into(),
            window_title: WINDOW_TITLE_SECRET.into(),
            trigger: "manual".into(),
            path: format!("activity/{SCREENSHOT_PATH_SECRET}"),
            text: OCR_SECRET.into(),
            text_source: "ocr".into(),
            ..NewScreenMoment::default()
        })
        .unwrap();
    library
        .save_moment(screenshot, "Pricing table idea")
        .unwrap();
    library
        .upsert_coding_agent_bursts(&[CodingAgentBurst {
            actions: Vec::new(),
            active_duration: 900.0,
            agent: CodingAgentKind::ClaudeCode,
            branch: Some("main".into()),
            changed_file_count: 0,
            changed_files: Vec::new(),
            end: day + chrono::Duration::seconds(4900),
            final_reply: None,
            project: "onboarding".into(),
            prompt_count: 1,
            prompts: vec!["shorten the onboarding flow".into()],
            pull_requests: Vec::new(),
            session_id: "fixture-session".into(),
            start: day + chrono::Duration::seconds(4000),
            title: "Onboarding step reducer".into(),
            tool_call_count: 3,
        }])
        .unwrap();

    // The day's digest, with the evidence log LokalBot renders from capture.
    let journal = library.journal_path(lokalbot_core::time::local_day(day));
    std::fs::create_dir_all(journal.parent().unwrap()).unwrap();
    std::fs::write(
        &journal,
        format!(
            "## Day summary\n\n### At a glance\n- Reviewed the prototype with Maya [screen:{screenshot}].\n- Northwind accepted the annual plan.\n\n### Tasks\n- **Send the pricing deck** — In progress. Drafted the tiers.\n\n### Decisions and next steps\n- Decision: Ship behind a feature flag first.\n- Blocker: Waiting on legal counsel.\n\n## Meetings\n\n### 10:30 — Design review — onboarding\n- App: Zoom\n\n## Time allocation\n\n| App | Tracked time |\n| --- | ---: |\n| Numbers | 25m |\n\n## Full activity log\n\n- **12:30–12:55** — **Numbers** — {WINDOW_TITLE_SECRET}\n  - [screen:{screenshot}], 12:33: {OCR_SECRET}\n"
        ),
    )
    .unwrap();

    // A tracked project with a "Where it stands" note; one point came from
    // overnight review notes, which stay on this computer.
    let project_id = Uuid::parse_str(PROJECT_ID).unwrap();
    library
        .save_project_curation(&ProjectCuration {
            version: 1,
            tracked: vec![TrackedProject {
                id: project_id,
                name: "Onboarding".into(),
                other_names: Vec::new(),
                created_at: day - chrono::Duration::days(10),
            }],
            hidden_names: Vec::new(),
        })
        .unwrap();
    library
        .save_project_summary(ProjectSummary {
            project_id: format!("tracked:{}", lokalbot_core::ids::uuid_upper(&project_id)),
            overview: "Onboarding is on track.".into(),
            points: vec![
                ProjectPoint {
                    text: "Three steps agreed.".into(),
                    meeting_id: Some(lokalbot_core::ids::uuid_upper(&design.id)),
                    meeting_title: Some(design.title.clone()),
                    meeting_date: None,
                },
                ProjectPoint {
                    text: REVIEW_NOTE_SECRET.into(),
                    meeting_id: None,
                    meeting_title: None,
                    meeting_date: None,
                },
            ],
            open_questions: Vec::new(),
            meeting_ids: vec![lokalbot_core::ids::uuid_upper(&design.id)],
            evidence_fingerprint: "fixture".into(),
            generated_at: day,
            engine_name: "Fixture".into(),
            location: "this computer".into(),
        })
        .unwrap();

    // Dream memory and Personal Context files: never read.
    let memory = library.paths().root().join("memory");
    std::fs::create_dir_all(&memory).unwrap();
    std::fs::write(
        memory.join("memory.json"),
        format!("{{\"projects\":[{{\"name\":\"{DREAM_SECRET}\"}}]}}"),
    )
    .unwrap();
    std::fs::write(
        memory.join("personal-model.json.enc"),
        PERSONAL_CONTEXT_SECRET,
    )
    .unwrap();

    Fixture {
        _dir: dir,
        library,
        now,
        day,
        design_review: design,
        older,
        merged_source,
        merged_parent,
        sample,
        live,
        screenshot,
    }
}

fn segment(start: f64, end: f64, speaker: &str, text: &str, user: bool) -> Segment {
    Segment {
        start,
        end,
        speaker: speaker.into(),
        text: text.into(),
        confidence: None,
        timing_precision: None,
        attribution: Some(if user {
            SpeakerAttribution::microphone_user()
        } else {
            SpeakerAttribution::system_other()
        }),
    }
}

impl Fixture {
    fn loaded(&self, sharing: &Sharing) -> CompanionLibrary {
        CompanionLibrary::load(
            &self.library,
            sharing.record_scope(),
            self.now,
            None,
            &HashMap::new(),
        )
    }

    fn records(&self, sharing: &Sharing) -> Vec<Record> {
        RecordBuilder::new(&self.loaded(sharing)).all_records()
    }

    fn day_key(&self) -> String {
        day_key(lokalbot_core::time::local_day(self.day))
    }
}

fn body(records: &[Record], kind: RecordKind, key: &str) -> Value {
    let record = records
        .iter()
        .find(|record| record.kind == kind && record.key == key)
        .unwrap_or_else(|| panic!("no {} record {key}", kind.raw()));
    serde_json::from_str(&record.body_json).unwrap()
}

fn has(records: &[Record], kind: RecordKind, key: &str) -> bool {
    records
        .iter()
        .any(|record| record.kind == kind && record.key == key)
}

// ------------------------------------------------------------------ privacy

/// The exclusion contract: no record carries attendee emails, speaker
/// evidence, calendar identity links, screenshot paths, screen text, agenda
/// or meeting links, Dream memory, or Personal Context.
#[test]
fn no_record_contains_excluded_data() {
    let fixture = fixture();
    let records = fixture.records(&sharing());
    assert!(!records.is_empty());
    for record in &records {
        for secret in SECRETS {
            assert!(
                !record.body_json.contains(secret),
                "{} {} leaks {secret}",
                record.kind.raw(),
                record.key
            );
        }
    }
    // The window title is shared while that class is on…
    assert!(
        records
            .iter()
            .any(|record| record.body_json.contains(WINDOW_TITLE_SECRET)),
        "the fixture must exercise window titles"
    );
    // …and appears nowhere once it is off.
    let mut no_titles = sharing();
    no_titles.data_classes.window_titles = false;
    for record in fixture.records(&no_titles) {
        assert!(
            !record.body_json.contains("WINDOWTITLE"),
            "{} {} leaks a window title",
            record.kind.raw(),
            record.key
        );
    }
}

#[test]
fn manifest_reports_what_devices_receive() {
    let mut chosen = sharing();
    chosen.history = HistoryWindow::Days90;
    chosen.answers_questions = false;
    chosen.data_classes.meetings = false;
    let json = builder::manifest(&chosen, "Test Computer", Utc::now()).unwrap();
    let manifest: Value = serde_json::from_str(&json).unwrap();
    assert_eq!(manifest["schemaVersion"], 1);
    assert_eq!(manifest["macName"], "Test Computer");
    assert_eq!(manifest["libraryName"], "LokalBot");
    assert_eq!(manifest["historyDays"], 90);
    assert_eq!(manifest["askEnabled"], false);
    assert_eq!(manifest["dataClasses"]["meetings"], false);
    // A transcript needs its meeting.
    assert_eq!(manifest["dataClasses"]["transcripts"], false);
    assert_eq!(manifest["dataClasses"]["windowTitles"], true);
    assert!(!json.contains(":null"), "optional fields are omitted");
}

// ----------------------------------------------------------------- meetings

#[test]
fn meeting_record_carries_corrected_outcomes_and_display_names() {
    let fixture = fixture();
    let records = fixture.records(&sharing());
    let meeting = body(&records, RecordKind::Meeting, &key(&fixture.design_review));
    assert_eq!(meeting["id"], key(&fixture.design_review));
    assert_eq!(meeting["title"], "Design review — onboarding");
    assert_eq!(meeting["day"], fixture.day_key());
    assert_eq!(meeting["appName"], "Zoom");
    assert_eq!(meeting["durationSeconds"], 2520.0);
    assert_eq!(meeting["hasTranscript"], true);
    assert_eq!(
        meeting["notesMarkdown"],
        "- Maya wants to lead the next design review"
    );
    let summary = meeting["summaryMarkdown"].as_str().unwrap();
    assert!(summary.starts_with("## Recap"), "{summary}");
    assert!(!summary.contains("**Model:**"), "the provenance line stays");
    let started = meeting["startedAt"].as_str().unwrap();
    assert!(
        started.ends_with('Z') && started.contains('.'),
        "UTC with milliseconds: {started}"
    );
    assert_eq!(
        meeting["timeZoneOffsetMinutes"],
        Local
            .offset_from_utc_datetime(&fixture.design_review.started_at.naive_utc())
            .local_minus_utc()
            / 60
    );

    let actions = meeting["actions"].as_array().unwrap();
    let find = |id: &str| actions.iter().find(|a| a["id"] == id).unwrap();
    let deck = find("act-deck");
    assert_eq!(deck["owner"], "You");
    assert_eq!(deck["ownerIsUser"], true);
    assert_eq!(deck["ownerUnclear"], false);
    assert_eq!(deck["status"], "open");
    assert_eq!(deck["dueText"], "2026-11-03");
    assert_eq!(deck["dueDate"], "2026-11-03");
    assert_eq!(deck["citations"][0]["speaker"], "Maya Chen");
    assert_eq!(deck["citations"][0]["start"], 721.4);
    let study = find("act-study");
    assert_eq!(study["status"], "deferred", "the correction is applied");
    assert_eq!(study["ownerUnclear"], true);
    assert!(study.get("owner").is_none());
    assert_eq!(
        meeting["decisions"][0]["text"],
        "Ship the three-step flow behind a flag first."
    );
    assert_eq!(
        meeting["openQuestions"][0]["text"],
        "Which five customers go first?"
    );
    let people = meeting["people"].as_array().unwrap();
    assert!(people.iter().any(|p| p["displayName"] == "Maya Chen"));
    assert!(
        people
            .iter()
            .all(|p| p["id"].as_str().unwrap().starts_with("person-"))
    );
    assert_eq!(meeting["projects"][0]["name"], "Onboarding");
    assert_eq!(meeting["projects"][0]["id"], PROJECT_ID);
}

#[test]
fn transcript_uses_display_names_and_stable_colors() {
    let fixture = fixture();
    let records = fixture.records(&sharing());
    let transcript = body(
        &records,
        RecordKind::Transcript,
        &key(&fixture.design_review),
    );
    let segments = transcript["segments"].as_array().unwrap();
    assert_eq!(segments[0]["speaker"], "You");
    assert_eq!(segments[0]["colorIndex"], 0);
    assert_eq!(segments[1]["speaker"], "Maya Chen");
    assert_eq!(segments[1]["colorIndex"], 1);
    assert_eq!(segments[2]["speaker"], "Speaker 2");
    assert_eq!(segments[2]["colorIndex"], 2);
    assert_eq!(transcript["meetingId"], key(&fixture.design_review));
    // Identity evidence stays home.
    assert!(segments[0].get("attribution").is_none());
}

#[test]
fn color_index_wraps_the_palette_and_marks_unclear_voices() {
    assert_eq!(builder::color_index(0, "me"), 0);
    assert_eq!(builder::color_index(1, "them 1"), 1);
    assert_eq!(builder::color_index(7, "them 7"), 7);
    assert_eq!(builder::color_index(8, "them 8"), 1);
    assert_eq!(builder::color_index(3, "them unclear"), -1);
}

#[test]
fn merged_sources_the_sample_and_unfinished_meetings_are_not_shared() {
    let fixture = fixture();
    let records = fixture.records(&sharing());
    for meeting in [&fixture.merged_source, &fixture.sample, &fixture.live] {
        assert!(!has(&records, RecordKind::Meeting, &key(meeting)));
        assert!(!has(&records, RecordKind::Transcript, &key(meeting)));
    }
    assert!(has(
        &records,
        RecordKind::Meeting,
        &key(&fixture.merged_parent)
    ));
}

#[test]
fn disabled_classes_build_no_records() {
    let fixture = fixture();
    let of_kind = |records: &[Record], kind| records.iter().filter(|r| r.kind == kind).count();

    let mut no_meetings = sharing();
    no_meetings.data_classes.meetings = false;
    let records = fixture.records(&no_meetings);
    assert_eq!(of_kind(&records, RecordKind::Meeting), 0);
    assert_eq!(
        of_kind(&records, RecordKind::Transcript),
        0,
        "needs a meeting"
    );

    let mut no_transcripts = sharing();
    no_transcripts.data_classes.transcripts = false;
    let records = fixture.records(&no_transcripts);
    assert_eq!(of_kind(&records, RecordKind::Transcript), 0);
    assert_eq!(
        body(&records, RecordKind::Meeting, &key(&fixture.design_review))["hasTranscript"],
        false
    );

    let mut no_people = sharing();
    no_people.data_classes.people = false;
    no_people.data_classes.projects = false;
    let records = fixture.records(&no_people);
    assert_eq!(of_kind(&records, RecordKind::Person), 0);
    assert_eq!(of_kind(&records, RecordKind::Project), 0);

    let mut no_digests = sharing();
    no_digests.data_classes.digests = false;
    no_digests.data_classes.timeline = false;
    let records = fixture.records(&no_digests);
    let day = body(&records, RecordKind::Day, &fixture.day_key());
    assert!(day.get("digest").is_none());
    assert!(day.get("timeline").is_none());
    assert!(
        day["meetingIds"]
            .as_array()
            .is_some_and(|ids| !ids.is_empty())
    );
}

#[test]
fn history_window_leaves_older_records_out() {
    let fixture = fixture();
    let mut window = sharing();
    window.history = HistoryWindow::Days30;
    let records = fixture.records(&window);
    assert!(!has(&records, RecordKind::Meeting, &key(&fixture.older)));
    assert!(has(
        &records,
        RecordKind::Meeting,
        &key(&fixture.design_review)
    ));
    assert!(!has(
        &records,
        RecordKind::Day,
        &day_key(lokalbot_core::time::local_day(fixture.older.started_at))
    ));
    // People and projects reach no further than the meetings they may see.
    for record in records.iter().filter(|r| r.kind != RecordKind::Meeting) {
        assert!(
            !record.body_json.contains(&key(&fixture.older)),
            "{} {} names a meeting outside the window",
            record.kind.raw(),
            record.key
        );
    }
    assert!(
        fixture
            .records(&sharing())
            .iter()
            .any(|r| r.key == key(&fixture.older))
    );
}

#[test]
fn history_window_starts_on_local_days() {
    let now = Local
        .with_ymd_and_hms(2026, 10, 30, 15, 0, 0)
        .unwrap()
        .with_timezone(&Utc);
    let first = |window: HistoryWindow| window.first_day(lokalbot_core::time::local_day(now));
    assert_eq!(first(HistoryWindow::All), None);
    assert_eq!(
        first(HistoryWindow::Days30).map(day_key).as_deref(),
        Some("2026-10-01")
    );
    assert_eq!(
        first(HistoryWindow::Days90).map(day_key).as_deref(),
        Some("2026-08-02")
    );
    assert_eq!(HistoryWindow::from_days(365), HistoryWindow::Days365);
    assert_eq!(HistoryWindow::from_days(7), HistoryWindow::All);
}

// --------------------------------------------------------------------- days

#[test]
fn day_record_has_digest_sections_timeline_and_screen_times() {
    let fixture = fixture();
    let records = fixture.records(&sharing());
    let day = body(&records, RecordKind::Day, &fixture.day_key());
    assert_eq!(day["date"], fixture.day_key());
    let digest = &day["digest"];
    let markdown = digest["markdown"].as_str().unwrap();
    assert!(markdown.contains("## Day summary"));
    assert!(
        !markdown.contains("Full activity log"),
        "the evidence log stays on this computer"
    );
    assert!(markdown.contains("(screen moment at"), "{markdown}");
    assert!(!markdown.contains("[screen:"), "{markdown}");
    assert_eq!(digest["userEdited"], true, "no sidecar: not generated");
    let sections = &digest["sections"];
    assert!(
        sections["highlights"]
            .as_array()
            .unwrap()
            .iter()
            .any(|item| item.as_str().unwrap().contains("Northwind"))
    );
    assert_eq!(sections["tasks"][0], "Send the pricing deck");
    assert_eq!(
        sections["decisions"][0],
        "Ship behind a feature flag first."
    );
    assert_eq!(sections["blockers"][0], "Waiting on legal counsel.");

    let timeline = &day["timeline"];
    assert!(timeline["trackedSeconds"].as_f64().unwrap() > 0.0);
    let sessions = timeline["sessions"].as_array().unwrap();
    let kinds: Vec<&str> = sessions
        .iter()
        .map(|s| s["kind"].as_str().unwrap())
        .collect();
    assert!(kinds.contains(&"work") && kinds.contains(&"meeting") && kinds.contains(&"agent"));
    assert_eq!(
        sessions.iter().find(|s| s["kind"] == "agent").unwrap()["title"],
        "Onboarding step reducer"
    );
    assert!(
        sessions
            .iter()
            .find(|s| s["kind"] == "meeting" && s["meetingId"] == key(&fixture.design_review))
            .is_some()
    );
    assert_eq!(timeline["savedMoments"][0]["label"], "Pricing table idea");
    assert!(
        timeline["byApp"]
            .as_array()
            .unwrap()
            .iter()
            .any(|app| app["name"] == "Numbers")
    );
    let ids = day["meetingIds"].as_array().unwrap();
    assert!(
        ids.iter()
            .any(|id| *id == json!(key(&fixture.design_review)))
    );
    assert!(!ids.iter().any(|id| *id == json!(key(&fixture.sample))));
    assert!(fixture.screenshot > 0);
}

#[test]
fn a_digest_with_a_matching_sidecar_is_generated() {
    let fixture = fixture();
    let day = lokalbot_core::time::local_day(fixture.day);
    let markdown = fixture.library.journal_markdown(day).unwrap().unwrap();
    let generated = fixture.day;
    fixture
        .library
        .save_digest(
            day,
            &markdown,
            &lokalbot_core::model::DigestMeta {
                generated_at: generated,
                ..Default::default()
            },
        )
        .unwrap();
    let records = fixture.records(&sharing());
    let body = body(&records, RecordKind::Day, &fixture.day_key());
    assert_eq!(body["digest"]["userEdited"], false);
    assert_eq!(body["digest"]["generatedAt"], instant(generated));
}

#[test]
fn screen_citation_rewrite_drops_missing_captures() {
    let at = Local
        .with_ymd_and_hms(2026, 10, 30, 14, 32, 0)
        .unwrap()
        .with_timezone(&Utc);
    let time = |id: i64| (id == 42).then_some(at);
    assert_eq!(
        builder::rewriting_screen_citations("Saw it [screen:42].", &time),
        "Saw it (screen moment at 14:32)."
    );
    assert_eq!(
        builder::rewriting_screen_citations("Gone [screen:7] and bare [screen].", &time),
        "Gone and bare."
    );
    assert_eq!(
        builder::rewriting_screen_citations("None here.", &time),
        "None here."
    );
}

#[test]
fn digest_items_read_bullets_or_paragraphs() {
    assert_eq!(builder::items("- one\n* two\n  - nested\n"), ["one", "two"]);
    assert_eq!(builder::items("First.\n\nSecond.\n"), ["First.", "Second."]);
}

#[test]
fn only_generated_evidence_sections_are_removed() {
    let text = "# Day\n## Day summary\nKept\n## Full activity log\nraw\n## Chronological work log\nraw\n# Next\nKept too";
    assert_eq!(
        builder::removing_evidence_sections(text),
        "# Day\n## Day summary\nKept\n# Next\nKept too"
    );
}

#[test]
fn summary_loses_its_title_and_provenance_only() {
    let fixture = fixture();
    let text = builder::shareable_summary(
        "# Title — when\n**Duration:** 42 min · **App:** Zoom\n\n**Next steps:** do it\n\n## Recap\nBody",
        &fixture.design_review,
    )
    .unwrap();
    assert_eq!(text, "**Next steps:** do it\n\n## Recap\nBody");
    assert_eq!(
        builder::shareable_summary("# Only a title\n", &fixture.design_review),
        None
    );
}

// ------------------------------------------------------- people and projects

#[test]
fn people_and_projects_carry_names_work_and_meetings() {
    let fixture = fixture();
    let records = fixture.records(&sharing());
    let person = records
        .iter()
        .filter(|record| record.kind == RecordKind::Person)
        .map(|record| serde_json::from_str::<Value>(&record.body_json).unwrap())
        .find(|person| person["displayName"] == "Maya Chen")
        .expect("Maya Chen has a person record");
    assert!(person["id"].as_str().unwrap().starts_with("person-"));
    assert!(person["lastMetAt"].as_str().unwrap().ends_with('Z'));
    assert!(
        person["meetingIds"]
            .as_array()
            .unwrap()
            .contains(&json!(key(&fixture.design_review)))
    );
    let project = body(&records, RecordKind::Project, PROJECT_ID);
    assert_eq!(project["name"], "Onboarding");
    let stands = project["whereItStands"].as_str().unwrap();
    assert!(stands.contains("Onboarding is on track."));
    assert!(stands.contains("Three steps agreed."));
    assert!(!stands.contains(REVIEW_NOTE_SECRET));
    assert!(
        project["meetingIds"]
            .as_array()
            .unwrap()
            .contains(&json!(key(&fixture.design_review)))
    );
}

// ----------------------------------------------------- format compatibility

fn numbers_as_floats(value: &mut Value) {
    match value {
        Value::Number(number) => *value = json!(number.as_f64().unwrap_or_default()),
        Value::Array(items) => items.iter_mut().for_each(numbers_as_floats),
        Value::Object(map) => map.values_mut().for_each(numbers_as_floats),
        _ => {}
    }
}

fn round_trips<T: serde::de::DeserializeOwned + serde::Serialize>(body: &Value) {
    let parsed: T =
        serde_json::from_value(body.clone()).unwrap_or_else(|err| panic!("{err}: {body}"));
    let (mut before, mut after) = (body.clone(), serde_json::to_value(&parsed).unwrap());
    numbers_as_floats(&mut before);
    numbers_as_floats(&mut after);
    assert_eq!(before, after, "the schema's fields round trip");
}

/// Every record of the sample library the phones and the protocol test
/// against reads and writes back unchanged: same keys, nesting, optional
/// fields and types as the Mac's `Codable` bodies.
#[test]
fn the_protocols_sample_library_round_trips_through_these_types() {
    let library: Vec<Value> = serde_json::from_str(include_str!(
        "../../../../../Companion/protocol/fixtures/sample-library.json"
    ))
    .unwrap();
    assert!(library.len() >= 19);
    for record in &library {
        let body = &record["body"];
        match record["kind"].as_str().unwrap() {
            "manifest" => round_trips::<ManifestBody>(body),
            "meeting" => round_trips::<MeetingBody>(body),
            "transcript" => round_trips::<TranscriptBody>(body),
            "day" => round_trips::<DayBody>(body),
            "person" => round_trips::<PersonBody>(body),
            "project" => round_trips::<ProjectBody>(body),
            other => panic!("unknown kind {other}"),
        }
    }
}

/// What this computer builds, the phones' store accepts.
#[test]
fn built_records_are_accepted_by_the_sync_host() {
    let fixture = fixture();
    let dir = tempfile::tempdir().unwrap();
    let server = lokalbot_sync::SyncServer::new(
        lokalbot_sync::ServerConfig {
            db_path: dir
                .path()
                .join("host.sqlite")
                .to_string_lossy()
                .into_owned(),
            mac_name: "Test".into(),
            static_private_key: lokalbot_sync::generate_static_key().private_key,
            port: 0,
        },
        Box::new(RefuseEverything),
    )
    .unwrap();
    for record in fixture.records(&sharing()) {
        assert!(
            server
                .publish(record.kind.raw().into(), record.key, record.body_json)
                .unwrap()
        );
    }
    assert!(!server.is_running(), "publishing never opens a listener");
}

struct RefuseEverything;

impl lokalbot_sync::ServerDelegate for RefuseEverything {
    fn approve_pairing(&self, _: String, _: String) -> bool {
        false
    }
    fn apply_op(&self, _: String) -> lokalbot_sync::OpOutcome {
        lokalbot_sync::OpOutcome {
            status: "rejected".into(),
            message: None,
        }
    }
    fn ask(&self, _: String, sink: Arc<lokalbot_sync::AskSink>) {
        sink.failed("no".into());
    }
    fn devices_changed(&self) {}
}

#[test]
fn the_macs_settings_keys_decode_into_sharing() {
    let settings: Settings = serde_json::from_value(json!({
        "companionSharingEnabled": true,
        "companionShareMeetings": true,
        "companionShareTranscripts": false,
        "companionShareDigests": true,
        "companionShareTimeline": false,
        "companionShareWindowTitles": true,
        "companionSharePeople": false,
        "companionShareProjects": true,
        "companionHistory": 90,
        "companionAnswersQuestions": false,
        "companionPort": 80,
        "companionAdvertisesOnBonjour": false,
    }))
    .unwrap();
    let sharing = Sharing::new(&settings);
    assert!(sharing.enabled);
    assert!(!sharing.data_classes.shares_transcripts());
    assert!(!sharing.data_classes.shares_window_titles());
    assert_eq!(sharing.history, HistoryWindow::Days90);
    assert!(!sharing.answers_questions);
    assert_eq!(sharing.port, LOWEST_PORT, "clamped");
    assert!(!sharing.advertises);
}

#[test]
fn sharing_is_off_by_default_with_generous_classes() {
    let sharing = Sharing::new(&Settings::default());
    assert!(!sharing.enabled);
    assert_eq!(sharing.data_classes, DataClasses::ALL);
    assert_eq!(sharing.history, HistoryWindow::All);
    assert!(sharing.answers_questions);
    assert_eq!(sharing.port, DEFAULT_PORT);
    assert!(sharing.advertises);
}

// ---------------------------------------------------------------------- ops

fn set_status(meeting: &Meeting, action: &str, text: Option<&str>, status: &str) -> String {
    json!({
        "type": "action.setStatus", "opId": "op", "meetingId": key(meeting),
        "actionId": action, "actionText": text, "status": status,
        "at": "2026-10-31T07:12:00.000Z",
    })
    .to_string()
}

fn action_status(library: &Library, meeting: &Meeting, id: &str) -> &'static str {
    library
        .meeting_actions(meeting)
        .unwrap()
        .iter()
        .find(|reference| reference.action.id == id)
        .unwrap()
        .status
        .raw()
}

#[test]
fn set_status_by_id() {
    let fixture = fixture();
    let meeting = &fixture.design_review;
    let outcome = ops::apply(
        &fixture.library,
        &set_status(meeting, "act-deck", None, "done"),
    );
    assert_eq!(outcome.result.status, "applied");
    assert_eq!(outcome.meeting_id, Some(meeting.id));
    assert_eq!(action_status(&fixture.library, meeting, "act-deck"), "done");
    // Saved where the Actions list reads it.
    let state: OutcomeState = serde_json::from_slice(
        &std::fs::read(
            fixture
                .library
                .meeting_dir(meeting)
                .join("outcome-state.json"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(state.actions["act-deck"].status.raw(), "done");
    assert!(state.actions["act-deck"].user_edited);
}

#[test]
fn set_status_falls_back_to_the_text_snapshot() {
    let fixture = fixture();
    let meeting = &fixture.design_review;
    let outcome = ops::apply(
        &fixture.library,
        &set_status(
            meeting,
            "act-gone",
            Some("send the REVISED pricing deck to maya!"),
            "deferred",
        ),
    );
    assert_eq!(outcome.result.status, "applied");
    assert_eq!(
        action_status(&fixture.library, meeting, "act-deck"),
        "deferred"
    );
}

#[test]
fn unknown_action_is_unmatched_and_changes_nothing() {
    let fixture = fixture();
    let meeting = &fixture.design_review;
    let outcome = ops::apply(
        &fixture.library,
        &set_status(meeting, "act-gone", Some("Something else"), "done"),
    );
    assert_eq!(outcome.result.status, "unmatched");
    assert_eq!(action_status(&fixture.library, meeting, "act-deck"), "open");
}

#[test]
fn malformed_ops_are_rejected() {
    let fixture = fixture();
    let meeting = &fixture.design_review;
    for op in [
        "not json".to_string(),
        json!({"type": "action.delete", "meetingId": key(meeting), "actionId": "a", "status": "done"}).to_string(),
        set_status(meeting, "act-deck", None, "archived"),
        json!({"type": "action.setStatus", "meetingId": "nope", "actionId": "a", "status": "done"}).to_string(),
    ] {
        assert_eq!(ops::apply(&fixture.library, &op).result.status, "rejected", "{op}");
    }
}

#[test]
fn sample_meetings_cannot_be_changed_from_a_device() {
    let fixture = fixture();
    let outcome = ops::apply(
        &fixture.library,
        &set_status(&fixture.sample, "act", None, "done"),
    );
    assert_eq!(outcome.result.status, "unmatched");
}

#[test]
fn matcher_needs_an_unambiguous_text() {
    let fixture = fixture();
    let mut references = fixture
        .library
        .meeting_actions(&fixture.design_review)
        .unwrap();
    assert_eq!(
        ops::match_action("act-deck", None, &references).as_deref(),
        Some("act-deck")
    );
    assert_eq!(ops::match_action("gone", None, &references), None);
    assert_eq!(ops::match_action("gone", Some(" "), &references), None);
    let mut twin = references[0].clone();
    twin.action.id = "act-twin".into();
    references.push(twin);
    assert_eq!(
        ops::match_action("gone", Some(&references[0].text.clone()), &references),
        None,
        "two actions share this text"
    );
}

// ---------------------------------------------------------------------- ask

#[test]
fn meeting_markers_become_numbered_citations() {
    let fixture = fixture();
    let meetings = vec![fixture.design_review.clone()];
    let upper = lokalbot_core::ids::uuid_upper(&fixture.design_review.id);
    let (answer, citations) = ask::map_citations(
        &format!(
            "We cut it [meeting:{upper}@00:12:04]. Again [meeting:{upper}@00:12:04] and [meeting:{upper}]."
        ),
        &meetings,
    );
    assert_eq!(answer, "We cut it [1]. Again [1] and [2].");
    assert_eq!(citations.len(), 2);
    assert_eq!(citations[0].index, 1);
    assert_eq!(
        citations[0].meeting_id.as_deref(),
        Some(key(&fixture.design_review).as_str())
    );
    assert_eq!(citations[0].at, Some(724.0));
    assert_eq!(citations[0].label, "Design review — onboarding · 12:04");
    assert_eq!(citations[1].at, None);
    assert!(
        citations[1]
            .label
            .starts_with("Design review — onboarding · ")
    );
    // Short ids work when they name one meeting.
    let short = fixture.design_review.short_id();
    let (_, citations) = ask::map_citations(&format!("[meeting:{short}]"), &meetings);
    assert_eq!(
        citations[0].meeting_id.as_deref(),
        Some(key(&fixture.design_review).as_str())
    );
}

#[test]
fn screen_file_and_unknown_citations_carry_no_meeting() {
    let (answer, citations) =
        ask::map_citations("A [screen:42], B [file:7], C [meeting:abc@1:05].", &[]);
    assert_eq!(answer, "A [1], B [2], C [3].");
    assert_eq!(citations[0].label, "Screen moment");
    assert_eq!(citations[0].meeting_id, None);
    assert_eq!(citations[1].label, "File");
    assert_eq!(citations[2].label, "Meeting");
    assert_eq!(citations[2].at, Some(65.0));
    assert_eq!(citations[2].meeting_id, None);
}

#[test]
fn clock_labels() {
    assert_eq!(ask::clock(724.0), "12:04");
    assert_eq!(ask::clock(3723.0), "1:02:03");
    assert_eq!(ask::clock(-5.0), "0:00");
}

#[test]
fn stream_sends_only_new_numbered_text() {
    let mut stream = ask::AnswerStream::default();
    assert_eq!(stream.next("Hello"), Some("Hello".to_string()));
    assert_eq!(stream.next("Hello"), None);
    assert_eq!(
        stream.next("Hello [meeting:abc"),
        Some(" ".to_string()),
        "held until it closes"
    );
    assert_eq!(
        stream.next("Hello [meeting:abc@1:05] there"),
        Some("[1] there".to_string())
    );
    assert_eq!(stream.next("Restarted"), None, "not an extension");
}

#[test]
fn tools_follow_the_shared_classes() {
    assert_eq!(ask::sources_for(DataClasses::ALL), (true, true));
    let mut classes = DataClasses::ALL;
    classes.window_titles = false;
    assert_eq!(ask::sources_for(classes), (true, false), "it names windows");
    classes.meetings = false;
    assert_eq!(ask::sources_for(classes), (false, false));
}

#[derive(Default)]
struct RecordingOutput {
    deltas: Mutex<Vec<String>>,
    finished: Mutex<Option<std::result::Result<String, String>>>,
}

impl AskOutput for RecordingOutput {
    fn delta(&self, text: String) {
        self.deltas.lock().push(text);
    }
    fn done(&self, result_json: String) {
        *self.finished.lock() = Some(Ok(result_json));
    }
    fn failed(&self, message: String) {
        *self.finished.lock() = Some(Err(message));
    }
}

impl RecordingOutput {
    fn wait(&self) -> std::result::Result<String, String> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(finished) = self.finished.lock().clone() {
                return finished;
            }
            assert!(Instant::now() < deadline, "no answer");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

/// Stands in for the model, recording what it was allowed to read.
#[derive(Default)]
struct FakeEngine {
    calls: AtomicUsize,
    scope: Mutex<Option<AskScope>>,
    history: Mutex<Vec<ChatMessage>>,
    /// The answer holds here, after its first words, until released.
    gate: Mutex<Option<Receiver<()>>>,
    reply: Mutex<String>,
    is_remote: AtomicBool,
}

impl AskEngine for FakeEngine {
    fn answer(
        &self,
        _question: &str,
        history: &[ChatMessage],
        scope: &AskScope,
        cancel: &AtomicBool,
        on_text: &mut dyn FnMut(&str),
    ) -> Result<EngineAnswer> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        *self.scope.lock() = Some(scope.clone());
        *self.history.lock() = history.to_vec();
        on_text("Working");
        if let Some(gate) = self.gate.lock().take() {
            while gate.recv_timeout(Duration::from_millis(20)).is_err() {
                if cancel.load(Ordering::Relaxed) {
                    break;
                }
            }
        }
        let text = self.reply.lock().clone();
        on_text(&text);
        Ok(EngineAnswer {
            text,
            engine_label: "Fixture Model".into(),
            is_local: !self.is_remote.load(Ordering::SeqCst),
        })
    }
}

fn asking(fixture: &Fixture, engine: Arc<FakeEngine>) -> AskResponder {
    AskResponder::new(fixture.library.clone(), engine)
}

fn question(extra: Value) -> String {
    let mut request = json!({
        "requestId": "req-1", "conversationId": "c-1", "question": "What did we decide?",
        "history": [{"role": "user", "text": "Hi"}, {"role": "assistant", "text": "Hello"}, {"role": "tool", "text": "x"}],
    });
    if let (Value::Object(request), Value::Object(extra)) = (&mut request, extra) {
        request.extend(extra);
    }
    request.to_string()
}

#[test]
fn answer_streams_and_finishes_with_mapped_citations() {
    let fixture = fixture();
    let upper = lokalbot_core::ids::uuid_upper(&fixture.design_review.id);
    let engine = Arc::new(FakeEngine::default());
    *engine.reply.lock() = format!("Working out: three steps [meeting:{upper}@00:12:04].");
    let output = Arc::new(RecordingOutput::default());
    asking(&fixture, engine.clone()).answer(&question(json!({})), sharing(), output.clone());
    let result: Value = serde_json::from_str(&output.wait().unwrap()).unwrap();
    assert_eq!(result["requestId"], "req-1");
    assert_eq!(result["answer"], "Working out: three steps [1].");
    assert_eq!(result["citations"][0]["index"], 1);
    assert_eq!(
        result["citations"][0]["meetingId"],
        key(&fixture.design_review)
    );
    assert_eq!(result["citations"][0]["at"], 724.0);
    assert_eq!(result["engineLabel"], "Fixture Model");
    assert_eq!(result["location"], "mac", "the protocol's value");
    assert!(result["answeredAt"].as_str().unwrap().ends_with('Z'));
    assert_eq!(
        output.deltas.lock().join(""),
        "Working out: three steps [1]."
    );
    assert_eq!(engine.history.lock().len(), 2, "an unknown role is dropped");
    let scope = engine.scope.lock().clone().unwrap();
    assert!(scope.include_meetings && scope.include_activity);
    assert!(!scope.include_screen, "screen memory is never searched");
    assert!(scope.meeting_ids.contains(&fixture.design_review.id));
    for hidden in [&fixture.sample, &fixture.live, &fixture.merged_source] {
        assert!(!scope.meeting_ids.contains(&hidden.id), "{}", hidden.title);
    }
    assert_eq!(
        scope.limit, None,
        "all history and no scope: nothing to name"
    );
}

#[test]
fn a_remote_engine_says_so() {
    let fixture = fixture();
    let engine = Arc::new(FakeEngine::default());
    engine.is_remote.store(true, Ordering::SeqCst);
    *engine.reply.lock() = "Done".into();
    let output = Arc::new(RecordingOutput::default());
    asking(&fixture, engine).answer(&question(json!({})), sharing(), output.clone());
    let result: Value = serde_json::from_str(&output.wait().unwrap()).unwrap();
    assert_eq!(result["location"], "remote");
}

#[test]
fn answering_off_fails_without_running_the_model() {
    let fixture = fixture();
    let engine = Arc::new(FakeEngine::default());
    let mut off = sharing();
    off.answers_questions = false;
    let output = Arc::new(RecordingOutput::default());
    asking(&fixture, engine.clone()).answer(&question(json!({})), off, output.clone());
    assert!(output.wait().unwrap_err().contains("turned off"));

    let mut nothing = sharing();
    nothing.data_classes.meetings = false;
    nothing.data_classes.window_titles = false;
    let output = Arc::new(RecordingOutput::default());
    asking(&fixture, engine.clone()).answer(&question(json!({})), nothing, output.clone());
    assert!(
        output
            .wait()
            .unwrap_err()
            .contains("nothing to answer from")
    );

    let output = Arc::new(RecordingOutput::default());
    asking(&fixture, engine.clone()).answer("not json", sharing(), output.clone());
    assert!(output.wait().unwrap_err().contains("could not read"));
    assert_eq!(engine.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn out_of_window_scope_is_refused() {
    let fixture = fixture();
    let engine = Arc::new(FakeEngine::default());
    let mut window = sharing();
    window.history = HistoryWindow::Days30;

    let output = Arc::new(RecordingOutput::default());
    let scope = json!({"scope": {"meetingId": key(&fixture.older)}});
    asking(&fixture, engine.clone()).answer(&question(scope), window, output.clone());
    assert!(output.wait().unwrap_err().contains("not shared"));

    let output = Arc::new(RecordingOutput::default());
    let old_day = day_key(lokalbot_core::time::local_day(fixture.older.started_at));
    let scope = json!({"scope": {"day": old_day}});
    asking(&fixture, engine.clone()).answer(&question(scope), window, output.clone());
    assert!(output.wait().unwrap_err().contains("not shared"));

    let output = Arc::new(RecordingOutput::default());
    let scope = json!({"scope": {"day": "2026-13-40"}});
    asking(&fixture, engine.clone()).answer(&question(scope), window, output.clone());
    assert!(output.wait().unwrap_err().contains("not shared"));

    // The sample is never shared, even with all history.
    let output = Arc::new(RecordingOutput::default());
    let scope = json!({"scope": {"meetingId": key(&fixture.sample)}});
    asking(&fixture, engine.clone()).answer(&question(scope), sharing(), output.clone());
    assert!(output.wait().unwrap_err().contains("not shared"));
    assert_eq!(engine.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn the_window_limits_what_the_agent_may_read_and_the_day_only_focuses_it() {
    let fixture = fixture();
    let engine = Arc::new(FakeEngine::default());
    let mut window = sharing();
    window.history = HistoryWindow::Days30;
    let output = Arc::new(RecordingOutput::default());
    asking(&fixture, engine.clone()).answer(&question(json!({})), window, output.clone());
    output.wait().unwrap();
    let scope = engine.scope.lock().clone().unwrap();
    assert!(!scope.meeting_ids.contains(&fixture.older.id));
    assert_eq!(scope.since, window.history.start(Utc::now()));
    assert_eq!(scope.until, None);
    // The model is told the window is the limit, not a date to remove.
    let limit = scope.limit.unwrap();
    assert_eq!(
        limit.words,
        "meetings from the last 30 days, the history the user shares with this device"
    );
    assert!(!limit.removable_dates);

    let output = Arc::new(RecordingOutput::default());
    let chosen =
        json!({"scope": {"day": fixture.day_key(), "meetingId": key(&fixture.design_review)}});
    asking(&fixture, engine.clone()).answer(&question(chosen), window, output.clone());
    output.wait().unwrap();
    let scope = engine.scope.lock().clone().unwrap();
    // "Ask About Today" on a tablet once held the question to that day and
    // answered "the library has only one meeting": the day and the meeting
    // are where the answer starts, and only the window limits it.
    assert!(scope.meeting_ids.len() > 1, "{:?}", scope.meeting_ids);
    assert!(scope.meeting_ids.contains(&fixture.design_review.id));
    assert_eq!(scope.since, window.history.start(Utc::now()));
    assert_eq!(scope.until, None);
    let focus = scope.focus.unwrap();
    assert!(
        focus.subject.starts_with(&format!(
            "the meeting “{}” [{}] on ",
            fixture.design_review.display_title(),
            fixture.design_review.short_id()
        )),
        "{}",
        focus.subject
    );
    assert!(focus.subject.contains(" and the day "), "{}", focus.subject);
    assert_eq!(focus.meeting_ids[0], fixture.design_review.id);
    assert!(!scope.limit.unwrap().removable_dates);
}

/// To Ask an empty list means every meeting, and to a device it must mean none.
#[test]
fn no_shared_meetings_reach_no_meetings() {
    let dir = tempfile::tempdir().unwrap();
    let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
    let old = Utc::now() - chrono::Duration::days(100);
    let mut meeting = library.create_meeting("Old", "Zoom", old).unwrap();
    meeting.ended_at = Some(old + chrono::Duration::minutes(5));
    library.save_meeting(&meeting).unwrap();
    let engine = Arc::new(FakeEngine::default());
    let mut window = sharing();
    window.history = HistoryWindow::Days30;
    let output = Arc::new(RecordingOutput::default());
    AskResponder::new(library, engine.clone()).answer(&question(json!({})), window, output.clone());
    output.wait().unwrap();
    let scope = engine.scope.lock().clone().unwrap();
    assert_eq!(scope.meeting_ids, [Uuid::nil()]);
}

#[test]
fn turning_sharing_off_cancels_an_answer() {
    let fixture = fixture();
    let engine = Arc::new(FakeEngine::default());
    let (_release, gate) = bounded::<()>(1);
    *engine.gate.lock() = Some(gate);
    *engine.reply.lock() = "Never sent".into();
    let responder = asking(&fixture, engine.clone());
    let output = Arc::new(RecordingOutput::default());
    responder.answer(&question(json!({})), sharing(), output.clone());
    let deadline = Instant::now() + Duration::from_secs(10);
    while engine.calls.load(Ordering::SeqCst) == 0 {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(5));
    }
    responder.cancel_all();
    assert!(output.wait().unwrap_err().contains("stopped answering"));
}

// ---------------------------------------------------------------- publisher

#[derive(Default)]
struct MemorySink {
    records: Mutex<HashMap<(String, String), String>>,
    manifests: Mutex<Vec<String>>,
    removed: Mutex<Vec<(String, String)>>,
}

impl RecordSink for MemorySink {
    fn publish(&self, kind: &str, key: &str, body_json: &str) -> Result<bool> {
        let mut records = self.records.lock();
        let slot = (kind.to_string(), key.to_string());
        if records.get(&slot).map(String::as_str) == Some(body_json) {
            return Ok(false);
        }
        records.insert(slot, body_json.to_string());
        Ok(true)
    }

    fn remove(&self, kind: &str, key: &str) -> Result<bool> {
        let slot = (kind.to_string(), key.to_string());
        let removed = self.records.lock().remove(&slot).is_some();
        if removed {
            self.removed.lock().push(slot);
        }
        Ok(removed)
    }

    fn record_keys(&self, kind: &str) -> Result<Vec<String>> {
        Ok(self
            .records
            .lock()
            .keys()
            .filter(|(k, _)| k == kind)
            .map(|(_, key)| key.clone())
            .collect())
    }

    fn set_manifest(&self, body_json: &str) -> Result<()> {
        self.manifests.lock().push(body_json.to_string());
        Ok(())
    }
}

impl MemorySink {
    fn has(&self, kind: RecordKind, key: &str) -> bool {
        self.records
            .lock()
            .contains_key(&(kind.raw().to_string(), key.to_string()))
    }

    fn body(&self, kind: RecordKind, key: &str) -> Value {
        serde_json::from_str(&self.records.lock()[&(kind.raw().to_string(), key.to_string())])
            .unwrap()
    }
}

fn publisher(fixture: &Fixture, chosen: Sharing) -> (Publisher, Arc<MemorySink>) {
    let sink = Arc::new(MemorySink::default());
    let publisher = Publisher::start(
        fixture.library.clone(),
        sink.clone(),
        Context {
            sharing: chosen,
            mac_name: "Test Computer".into(),
        },
        Duration::from_secs(60),
    );
    (publisher, sink)
}

#[test]
fn reconcile_publishes_every_record_and_the_manifest() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    let report = publisher.flush();
    assert!(report.published > 0);
    assert_eq!(report.changed, report.published);
    assert_eq!(report.failed, 0);
    assert!(sink.has(RecordKind::Meeting, &key(&fixture.design_review)));
    assert!(sink.has(RecordKind::Transcript, &key(&fixture.design_review)));
    assert!(sink.has(RecordKind::Day, &fixture.day_key()));
    assert!(sink.has(RecordKind::Project, PROJECT_ID));
    assert_eq!(sink.manifests.lock().len(), 1);
    publisher.reconcile_all();
    assert_eq!(publisher.flush().changed, 0, "nothing changed");
}

#[test]
fn narrowing_the_scope_withdraws_records() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    publisher.flush();
    let mut narrower = sharing();
    narrower.data_classes.transcripts = false;
    narrower.data_classes.people = false;
    narrower.history = HistoryWindow::Days30;
    publisher.update(Context {
        sharing: narrower,
        mac_name: "Test Computer".into(),
    });
    let report = publisher.flush();
    assert!(report.removed > 0);
    assert!(!sink.has(RecordKind::Transcript, &key(&fixture.design_review)));
    assert!(!sink.has(RecordKind::Meeting, &key(&fixture.older)));
    assert!(sink.has(RecordKind::Meeting, &key(&fixture.design_review)));
    assert_eq!(sink.record_keys("person").unwrap().len(), 0);
}

#[test]
fn changing_only_the_manifest_rebuilds_nothing() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    publisher.flush();
    let mut chosen = sharing();
    chosen.answers_questions = false;
    publisher.update(Context {
        sharing: chosen,
        mac_name: "Test Computer".into(),
    });
    assert_eq!(publisher.flush(), Default::default());
    let manifests = sink.manifests.lock();
    assert_eq!(manifests.len(), 2);
    assert!(manifests[1].contains("\"askEnabled\":false"));
}

#[test]
fn a_deleted_meeting_is_withdrawn() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    publisher.flush();
    let day = lokalbot_core::time::local_day(fixture.design_review.started_at);
    fixture
        .library
        .delete_meeting(&fixture.design_review)
        .unwrap();
    publisher.evidence_changed(&[day]);
    let report = publisher.flush();
    assert!(report.removed >= 2, "{report:?}");
    assert!(!sink.has(RecordKind::Meeting, &key(&fixture.design_review)));
    assert!(!sink.has(RecordKind::Transcript, &key(&fixture.design_review)));
    assert!(
        !sink
            .body(RecordKind::Day, &fixture.day_key())
            .to_string()
            .contains(&key(&fixture.design_review))
    );
}

/// A write with no evidence hook, such as a finished recording or a summary,
/// is found by comparing the library with what was built.
#[test]
fn a_rescan_finds_what_changed_without_a_hook() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    publisher.flush();
    publisher.library_changed();
    assert_eq!(publisher.flush(), Default::default(), "nothing changed");

    let mut finished = fixture.live.clone();
    finished.ended_at = Some(fixture.now);
    fixture.library.save_meeting(&finished).unwrap();
    publisher.library_changed();
    publisher.flush();
    assert!(sink.has(RecordKind::Meeting, &key(&finished)));

    std::thread::sleep(Duration::from_millis(20));
    fixture
        .library
        .save_summary(&finished, "## Recap\nWritten later.\n")
        .unwrap();
    publisher.library_changed();
    publisher.flush();
    assert_eq!(
        sink.body(RecordKind::Meeting, &key(&finished))["summaryMarkdown"],
        "## Recap\nWritten later."
    );
}

/// Notes saved from the meeting page reach no hook.
#[test]
fn the_periodic_check_finds_a_write_no_hook_reports() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    publisher.flush();
    publisher.check_for_changes();
    assert_eq!(publisher.flush(), Default::default(), "nothing changed");
    std::thread::sleep(Duration::from_millis(20));
    fixture
        .library
        .save_notes(&fixture.design_review, "A new thought")
        .unwrap();
    publisher.check_for_changes();
    publisher.flush();
    assert_eq!(
        sink.body(RecordKind::Meeting, &key(&fixture.design_review))["notesMarkdown"],
        "A new thought"
    );
    publisher.check_for_changes();
    assert_eq!(publisher.flush(), Default::default(), "no second pass");
}

#[test]
fn curation_saved_elsewhere_reaches_people_and_projects() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    publisher.flush();
    std::thread::sleep(Duration::from_millis(20));
    fixture
        .library
        .save_project_curation(&ProjectCuration::default())
        .unwrap();
    publisher.library_changed();
    publisher.flush();
    assert!(
        !sink.has(RecordKind::Project, PROJECT_ID),
        "no longer tracked"
    );
}

#[test]
fn status_change_is_republished_before_returning() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    publisher.flush();
    let outcome = ops::apply(
        &fixture.library,
        &set_status(&fixture.design_review, "act-deck", None, "done"),
    );
    assert_eq!(outcome.result.status, "applied");
    assert!(publisher.republish_now(fixture.design_review.id, Duration::from_secs(30)));
    let meeting = sink.body(RecordKind::Meeting, &key(&fixture.design_review));
    let deck = meeting["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|action| action["id"] == "act-deck")
        .unwrap();
    assert_eq!(deck["status"], "done");
}

#[test]
fn the_digest_hook_rebuilds_its_day() {
    let fixture = fixture();
    let (publisher, sink) = publisher(&fixture, sharing());
    publisher.reconcile_all();
    publisher.flush();
    let day = lokalbot_core::time::local_day(fixture.day);
    fixture
        .library
        .save_digest(
            day,
            "## Day summary\n\n### At a glance\n- A new day.\n",
            &lokalbot_core::model::DigestMeta::default(),
        )
        .unwrap();
    publisher.day_changed(day);
    publisher.flush();
    assert!(
        sink.body(RecordKind::Day, &fixture.day_key())["digest"]["markdown"]
            .as_str()
            .unwrap()
            .contains("A new day.")
    );
}

// ---------------------------------------------------- small pieces of the UI

#[test]
fn tailscale_addresses_are_recognized() {
    use CompanionNetwork::*;
    for tailscale in [
        "100.101.102.103",
        "100.64.0.1",
        "fd7a:115c:a1e0::5",
        "::ffff:100.64.0.1",
    ] {
        assert_eq!(
            CompanionNetwork::classify(tailscale),
            Some(Tailscale),
            "{tailscale}"
        );
    }
    for local in [
        "192.168.1.20",
        "10.0.0.2",
        "100.128.0.1",
        "fe80::1",
        "[fd12::1]:1234",
    ] {
        assert_eq!(
            CompanionNetwork::classify(local),
            Some(LocalNetwork),
            "{local}"
        );
    }
    assert_eq!(CompanionNetwork::classify("  "), None);
    assert_eq!(
        CompanionNetwork::classify("100.70.0.1:17890"),
        Some(Tailscale)
    );
}

#[test]
fn advertised_name_and_txt_record_are_neutral() {
    assert_eq!(
        advertise::instance_name("ab12cd34ef56ab78"),
        "LokalBot-AB12"
    );
    assert_eq!(
        advertise::txt_value("ab12cd34ef56ab78ffff"),
        "ab12cd34ef56ab78"
    );
    // Building the announcement opens nothing.
    let info = advertise::service_info(
        17890,
        "ab12cd34ef56ab78",
        &[
            "192.168.1.20".parse().unwrap(),
            "100.64.0.9".parse().unwrap(),
        ],
    )
    .unwrap();
    assert_eq!(info.get_type(), "_lokalbot._tcp.local.");
    assert_eq!(info.get_fullname(), "LokalBot-AB12._lokalbot._tcp.local.");
    assert_eq!(info.get_hostname(), "LokalBot-AB12.local.");
    assert_eq!(info.get_port(), 17890);
    assert_eq!(info.get_property_val_str("k"), Some("ab12cd34ef56ab78"));
    assert_eq!(info.get_properties().len(), 1, "nothing else is announced");
}

#[test]
fn pairing_prompt_shows_a_bounded_name() {
    assert_eq!(device_display_name("  Maya's\nPhone\u{7}  "), "Maya'sPhone");
    assert_eq!(device_display_name("\n\t"), "A device");
    let long = "x".repeat(100);
    let shown = device_display_name(&long);
    assert_eq!(shown.chars().count(), 60);
    assert!(shown.ends_with('…'));
}

#[test]
fn a_pairing_offers_debug_output_hides_the_secret() {
    let pairing = CompanionPairing {
        qr_payload: "lokalbot://pair?d=SECRET".into(),
        expires_at: Utc::now(),
    };
    assert!(!format!("{pairing:?}").contains("SECRET"));
}

#[test]
fn loopback_is_requested_only_when_set() {
    assert!(!host::loopback_requested(None));
    assert!(!host::loopback_requested(Some("")));
    assert!(!host::loopback_requested(Some("0")));
    assert!(host::loopback_requested(Some("1")));
}

#[test]
fn computer_name_prefers_the_pretty_hostname() {
    assert_eq!(
        host::pretty_hostname("ICON_NAME=computer\nPRETTY_HOSTNAME=\"Stevan's Desk\"\n").as_deref(),
        Some("Stevan's Desk")
    );
    assert_eq!(host::pretty_hostname("CHASSIS=desktop\n"), None);
    assert!(!host::computer_name().is_empty());
}

/// Tools and examples start the engine too; only the app's Enable listens.
#[test]
fn nothing_follows_the_setting_until_the_app_enables_it() {
    let (sender, receiver) = unbounded();
    let companion = Companion::default();
    *companion.sender.lock() = Some(sender);
    let settings = Settings {
        companion_sharing_enabled: true,
        ..Settings::default()
    };
    companion.settings_changed(&settings);
    assert!(receiver.try_recv().is_err());
    companion.command(CompanionCommand::Enable, &settings);
    assert!(matches!(receiver.try_recv(), Ok(HostMessage::Apply(s)) if s.enabled));
}

// ------------------------------------------------------------- the host, end
// to end, against the protocol's client. Loopback only: the environment asks
// for it, and the only advertiser here records calls.

#[derive(Clone, Default)]
struct AdvertiserLog(Arc<Mutex<Vec<String>>>);

impl AdvertiserLog {
    fn entries(&self) -> Vec<String> {
        self.0.lock().clone()
    }
}

struct FakeAdvertiser(AdvertiserLog);

impl Advertiser for FakeAdvertiser {
    fn start(&mut self, port: u16, fingerprint: &str, addresses: &[String]) -> Result<()> {
        self.0.0.lock().push(format!(
            "start {port} {fingerprint} {}",
            addresses.join(",")
        ));
        Ok(())
    }

    fn stop(&mut self) {
        self.0.0.lock().push("stop".into());
    }
}

struct TestEnvironment {
    settings: Mutex<Settings>,
    key: [u8; 32],
    key_failure: AtomicBool,
    advertisements: AdvertiserLog,
    addresses: Mutex<Vec<String>>,
}

impl Environment for TestEnvironment {
    fn settings(&self) -> Settings {
        self.settings.lock().clone()
    }

    fn static_key(&self) -> Result<[u8; 32]> {
        anyhow::ensure!(
            !self.key_failure.load(Ordering::SeqCst),
            "no store is reachable"
        );
        Ok(self.key)
    }

    fn addresses(&self) -> Vec<String> {
        self.addresses.lock().clone()
    }

    fn computer_name(&self) -> String {
        "Test Desktop".into()
    }

    fn loopback_only(&self) -> bool {
        true
    }

    fn announces(&self) -> bool {
        true
    }

    fn advertiser(&self) -> Box<dyn Advertiser> {
        Box::new(FakeAdvertiser(self.advertisements.clone()))
    }
}

struct Harness {
    fixture: Fixture,
    environment: Arc<TestEnvironment>,
    engine: Arc<FakeEngine>,
    host: Sender<HostMessage>,
    snapshots: Receiver<CompanionSnapshot>,
    latest: CompanionSnapshot,
    thread: Option<std::thread::JoinHandle<()>>,
    phones: tempfile::TempDir,
    phone_key: Vec<u8>,
}

impl Harness {
    fn start() -> Self {
        let fixture = fixture();
        let (host, messages) = unbounded();
        let (snapshots_in, snapshots) = unbounded();
        let key: [u8; 32] = lokalbot_sync::generate_static_key()
            .private_key
            .try_into()
            .unwrap();
        let environment = Arc::new(TestEnvironment {
            settings: Mutex::new(Settings {
                companion_sharing_enabled: true,
                ..Settings::default()
            }),
            key,
            key_failure: AtomicBool::new(false),
            advertisements: AdvertiserLog::default(),
            addresses: Mutex::new(vec!["127.0.0.1".into()]),
        });
        let engine = Arc::new(FakeEngine::default());
        let running = Host::new(
            fixture.library.clone(),
            environment.clone(),
            engine.clone(),
            host.clone(),
            Box::new(move |snapshot| {
                let _ = snapshots_in.send(snapshot);
            }),
        );
        let thread = std::thread::spawn(move || running.run(messages));
        Self {
            fixture,
            environment,
            engine,
            host,
            snapshots,
            latest: CompanionSnapshot::default(),
            thread: Some(thread),
            phones: tempfile::tempdir().unwrap(),
            phone_key: lokalbot_sync::generate_static_key().private_key,
        }
    }

    fn apply(&self, chosen: Sharing) {
        self.host.send(HostMessage::Apply(chosen)).unwrap();
    }

    fn send(&self, command: CompanionCommand) {
        self.host.send(HostMessage::Command(command)).unwrap();
    }

    fn wait(&mut self, mut condition: impl FnMut(&CompanionSnapshot) -> bool) -> CompanionSnapshot {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if condition(&self.latest) {
                return self.latest.clone();
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            self.latest = self
                .snapshots
                .recv_timeout(remaining)
                .expect("the host reached the expected state");
        }
    }

    fn listening_port(&mut self) -> u16 {
        let snapshot = self.wait(|s| matches!(s.status, CompanionStatus::Listening { .. }));
        match snapshot.status {
            CompanionStatus::Listening { port } => port,
            _ => unreachable!(),
        }
    }

    fn phone(&self, name: &str) -> Arc<SyncClient> {
        SyncClient::new(ClientConfig {
            db_path: self
                .phones
                .path()
                .join(format!("{name}.sqlite"))
                .to_string_lossy()
                .into_owned(),
            device_id: format!("device-{name}"),
            device_name: name.into(),
            platform: "android".into(),
            static_private_key: self.phone_key.clone(),
        })
        .unwrap()
    }

    /// Scans the code on a phone and answers the prompt.
    fn pair(&mut self, phone: &Arc<SyncClient>, allow: bool) -> Result<(), SyncError> {
        self.send(CompanionCommand::BeginPairing);
        let code = self
            .wait(|s| s.pairing.is_some())
            .pairing
            .unwrap()
            .qr_payload;
        let scanning = phone.clone();
        let pairing = std::thread::spawn(move || scanning.pair(code).map(|_| ()));
        let request = self.wait(|s| s.approval.is_some()).approval.unwrap();
        assert_eq!(request.platform, "android");
        self.send(CompanionCommand::AnswerPairing {
            id: request.id,
            allow,
        });
        let result = pairing.join().unwrap();
        self.wait(|s| s.approval.is_none());
        result
    }

    fn finish(mut self) {
        let _ = self.host.send(HostMessage::Stop);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

struct PrintNothing(Arc<Mutex<String>>);

impl AskListener for PrintNothing {
    fn on_delta(&self, text: String) {
        self.0.lock().push_str(&text);
    }
}

fn address(port: u16) -> String {
    format!("127.0.0.1:{port}")
}

#[test]
fn a_phone_pairs_syncs_changes_status_asks_and_is_removed() {
    let mut harness = Harness::start();
    let mut chosen = sharing();
    chosen.port = 0;
    harness.apply(chosen);
    let port = harness.listening_port();

    let phone = harness.phone("pixel");
    harness.pair(&phone, true).unwrap();
    let snapshot = harness.wait(|s| s.devices.len() == 1);
    assert_eq!(snapshot.devices[0].name, "pixel");
    assert!(snapshot.pairing.is_none(), "pairing consumes the offer");

    // The publisher's first pass runs after its debounce.
    let design = key(&harness.fixture.design_review);
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        phone.sync(vec![address(port)]).unwrap();
        if phone.meeting(design.clone()).unwrap().is_some()
            && phone.manifest().unwrap().is_some()
            && !phone.people().unwrap().is_empty()
        {
            break;
        }
        assert!(Instant::now() < deadline, "the records never arrived");
        std::thread::sleep(Duration::from_millis(200));
    }
    let manifest: Value = serde_json::from_str(&phone.manifest().unwrap().unwrap()).unwrap();
    assert_eq!(manifest["macName"], "Test Desktop");
    assert_eq!(manifest["libraryName"], "LokalBot");
    assert_eq!(
        phone.status().unwrap().mac_name.as_deref(),
        Some("Test Desktop")
    );
    assert!(phone.transcript(design.clone()).unwrap().is_some());
    assert!(phone.day(harness.fixture.day_key()).unwrap().is_some());
    assert!(phone.project(PROJECT_ID.into()).unwrap().is_some());
    // The sample never left this computer, and neither did what's excluded.
    assert!(
        phone
            .meeting(key(&harness.fixture.sample))
            .unwrap()
            .is_none()
    );
    let found = phone.search("Thursday".into(), 5).unwrap();
    assert!(!found.is_empty(), "the phone searches its own copy");
    assert!(
        phone
            .search("WINDOWTITLE".into(), 5)
            .unwrap()
            .iter()
            .all(|hit| { !hit.snippet.contains(OCR_SECRET) })
    );

    // A status change on the phone lands in the library and comes back.
    phone
        .set_action_status(design.clone(), "act-deck".into(), "done".into())
        .unwrap();
    let report = phone.sync(vec![address(port)]).unwrap();
    assert_eq!(report.ops_applied, 1);
    assert_eq!(
        action_status(
            &harness.fixture.library,
            &harness.fixture.design_review,
            "act-deck"
        ),
        "done"
    );
    let meeting: Value =
        serde_json::from_str(&phone.meeting(design.clone()).unwrap().unwrap()).unwrap();
    let deck = meeting["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|action| action["id"] == "act-deck")
        .unwrap()
        .clone();
    assert_eq!(deck["status"], "done");

    // A question is answered by this computer, with its citation mapped.
    let upper = lokalbot_core::ids::uuid_upper(&harness.fixture.design_review.id);
    *harness.engine.reply.lock() = format!("Three steps [meeting:{upper}@00:12:04].");
    let streamed = Arc::new(Mutex::new(String::new()));
    let request = json!({
        "requestId": Uuid::new_v4().to_string(), "conversationId": Uuid::new_v4().to_string(),
        "question": "What did we decide?", "history": [],
    });
    let result = phone
        .ask(
            request.to_string(),
            vec![address(port)],
            Box::new(PrintNothing(streamed.clone())),
        )
        .unwrap();
    let result: Value = serde_json::from_str(&result).unwrap();
    assert_eq!(result["answer"], "Three steps [1].");
    assert_eq!(result["citations"][0]["meetingId"], design);
    assert_eq!(result["location"], "mac");

    // Removing it refuses its next connection, and its copy is erased.
    let device = harness.latest.devices[0].id.clone();
    harness.send(CompanionCommand::RemoveDevice(device));
    harness.wait(|s| s.devices.is_empty());
    let refused = phone.sync(vec![address(port)]);
    assert!(
        matches!(refused, Err(SyncError::Revoked { .. })),
        "{refused:?}"
    );
    assert!(phone.meeting(design).unwrap().is_none());

    // Turning sharing off closes the port.
    let mut off = chosen;
    off.enabled = false;
    harness.apply(off);
    harness.wait(|s| s.status == CompanionStatus::Off);
    assert!(std::net::TcpStream::connect(address(port)).is_err());
    harness.finish();
}

#[test]
fn a_refused_device_gets_nothing() {
    let mut harness = Harness::start();
    harness.apply(sharing());
    harness.listening_port();
    let phone = harness.phone("stranger");
    let refused = harness.pair(&phone, false);
    assert!(refused.is_err());
    assert!(harness.latest.devices.is_empty());
    assert!(phone.manifest().unwrap().is_none());
    assert!(phone.meetings(None, None, 0).unwrap().is_empty());
    harness.finish();
}

/// With no answer the prompt goes away and the device is refused.
#[test]
fn stopping_refuses_a_waiting_device() {
    let mut harness = Harness::start();
    harness.apply(sharing());
    harness.listening_port();
    let phone = harness.phone("late");
    harness.send(CompanionCommand::BeginPairing);
    let code = harness
        .wait(|s| s.pairing.is_some())
        .pairing
        .unwrap()
        .qr_payload;
    let pairing = std::thread::spawn(move || phone.pair(code).map(|_| ()));
    harness.wait(|s| s.approval.is_some());
    let mut off = sharing();
    off.enabled = false;
    harness.apply(off);
    harness.wait(|s| s.status == CompanionStatus::Off && s.approval.is_none());
    assert!(pairing.join().unwrap().is_err());
    harness.finish();
}

/// A device that asks again with the same id attaches to the answer this
/// computer is still writing: the model runs once and both get the result.
/// `lokalbot-sync`'s own tests cover a device that dropped its connection.
#[test]
fn an_answer_outlives_the_connection_that_asked() {
    let mut harness = Harness::start();
    harness.apply(sharing());
    let port = harness.listening_port();
    let phone = harness.phone("pixel");
    harness.pair(&phone, true).unwrap();
    let (release, gate) = bounded::<()>(1);
    *harness.engine.gate.lock() = Some(gate);
    *harness.engine.reply.lock() = "Working it out.".into();
    let request = json!({
        "requestId": "req-kept", "conversationId": "c", "question": "Q", "history": [],
    })
    .to_string();
    let first = {
        let phone = phone.clone();
        let request = request.clone();
        let streamed = Arc::new(Mutex::new(String::new()));
        std::thread::spawn(move || {
            phone.ask(
                request,
                vec![address(port)],
                Box::new(PrintNothing(streamed)),
            )
        })
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    while harness.engine.calls.load(Ordering::SeqCst) == 0 {
        assert!(Instant::now() < deadline, "the model never started");
        std::thread::sleep(Duration::from_millis(10));
    }
    let same_phone = harness.phone("pixel");
    let second = {
        let streamed = Arc::new(Mutex::new(String::new()));
        std::thread::spawn(move || {
            same_phone.ask(
                request,
                vec![address(port)],
                Box::new(PrintNothing(streamed)),
            )
        })
    };
    std::thread::sleep(Duration::from_millis(300));
    release.send(()).unwrap();
    let first = first.join().unwrap().unwrap();
    let second = second.join().unwrap();
    let first: Value = serde_json::from_str(&first).unwrap();
    assert_eq!(first["answer"], "Working it out.");
    if let Ok(second) = second {
        let second: Value = serde_json::from_str(&second).unwrap();
        assert_eq!(second["answer"], "Working it out.");
    }
    assert_eq!(harness.engine.calls.load(Ordering::SeqCst), 1);
    harness.finish();
}

#[test]
fn a_missing_credential_store_says_why_and_listens_for_nothing() {
    let mut harness = Harness::start();
    harness
        .environment
        .key_failure
        .store(true, Ordering::SeqCst);
    harness.apply(sharing());
    let snapshot = harness.wait(|s| matches!(s.status, CompanionStatus::Failed(_)));
    let CompanionStatus::Failed(message) = snapshot.status else {
        unreachable!()
    };
    assert!(message.contains("credential store"), "{message}");
    assert!(harness.environment.advertisements.entries().is_empty());
    // The key never reached a file.
    assert!(
        !harness
            .fixture
            .library
            .paths()
            .root()
            .join("companion")
            .exists()
    );
    harness.finish();
}

#[test]
fn a_port_already_in_use_is_reported() {
    let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = occupied.local_addr().unwrap().port();
    let _occupied_v6 = std::net::TcpListener::bind(("::1", port));
    let mut harness = Harness::start();
    let mut chosen = sharing();
    chosen.port = port;
    harness.apply(chosen);
    let snapshot = harness.wait(|s| matches!(s.status, CompanionStatus::Failed(_)));
    let CompanionStatus::Failed(message) = snapshot.status else {
        unreachable!()
    };
    assert!(message.contains("Couldn't listen"), "{message}");
    assert!(harness.environment.advertisements.entries().is_empty());
    harness.finish();
}

/// Sharing off: no key is read, nothing is announced, no database is created.
#[test]
fn sharing_off_builds_and_announces_nothing() {
    let mut harness = Harness::start();
    let mut off = sharing();
    off.enabled = false;
    harness.apply(off);
    harness.send(CompanionCommand::BeginPairing);
    std::thread::sleep(Duration::from_millis(100));
    while let Ok(snapshot) = harness.snapshots.try_recv() {
        harness.latest = snapshot;
    }
    assert_eq!(harness.latest.status, CompanionStatus::Off);
    assert!(harness.latest.pairing.is_none(), "no code without sharing");
    assert!(
        !harness
            .environment
            .advertisements
            .entries()
            .iter()
            .any(|entry| entry.starts_with("start"))
    );
    assert!(
        !harness
            .fixture
            .library
            .paths()
            .root()
            .join("companion")
            .exists()
    );
    harness.finish();
}

#[test]
fn the_announcement_follows_the_setting_and_the_listener() {
    let mut harness = Harness::start();
    harness.apply(sharing());
    let port = harness.listening_port();
    let log = harness.environment.advertisements.clone();
    let first = log.entries();
    assert_eq!(first.len(), 1, "{first:?}");
    assert!(first[0].starts_with(&format!("start {port} ")), "{first:?}");
    assert!(first[0].ends_with(" 127.0.0.1"), "{first:?}");

    // Reapplying the same settings doesn't announce twice.
    harness.apply(sharing());
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(log.entries().len(), 1);

    // Off in Settings: withdrawn while the listener stays up.
    let mut quiet = sharing();
    quiet.advertises = false;
    harness.apply(quiet);
    let deadline = Instant::now() + Duration::from_secs(5);
    while log.entries().last().map(String::as_str) != Some("stop") {
        assert!(Instant::now() < deadline, "{:?}", log.entries());
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(harness.listening_port(), port, "the same listener");

    // Sharing off stops it for good.
    harness.apply(sharing());
    let deadline = Instant::now() + Duration::from_secs(5);
    while log
        .entries()
        .iter()
        .filter(|e| e.starts_with("start"))
        .count()
        < 2
    {
        assert!(Instant::now() < deadline, "{:?}", log.entries());
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut off = sharing();
    off.enabled = false;
    harness.apply(off);
    harness.wait(|s| s.status == CompanionStatus::Off);
    assert_eq!(log.entries().last().map(String::as_str), Some("stop"));
    harness.finish();
}

/// The addresses a code carries are read when it's made, so a new network or
/// Tailscale coming up reaches the next device.
#[test]
fn a_code_carries_the_current_addresses() {
    let mut harness = Harness::start();
    harness.apply(sharing());
    harness.listening_port();
    harness
        .environment
        .addresses
        .lock()
        .extend(["192.168.1.20".to_string(), "100.100.1.2".to_string()]);
    harness.send(CompanionCommand::BeginPairing);
    let code = harness
        .wait(|s| s.pairing.is_some())
        .pairing
        .unwrap()
        .qr_payload;
    let info = lokalbot_sync::parse_pairing_payload(code).unwrap();
    assert_eq!(info.addresses, ["127.0.0.1", "192.168.1.20", "100.100.1.2"]);
    assert_eq!(info.mac_name, "Test Desktop");
    harness.finish();
}

#[test]
fn the_database_lives_in_the_librarys_companion_folder() {
    let mut harness = Harness::start();
    harness.apply(sharing());
    harness.listening_port();
    let root = harness.fixture.library.paths().root().to_path_buf();
    let folder = root.join("companion");
    assert!(folder.join("companion.sqlite").is_file());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(&folder).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }
    harness.finish();
}
