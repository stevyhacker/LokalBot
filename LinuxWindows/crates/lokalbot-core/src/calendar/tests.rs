//! Ported from `CalendarDetectionTests.swift`, `CalendarParticipantIdentityTests.swift`
//! and the selector part of `UpcomingMeetingPreparationTests.swift`.

use std::time::Duration;

use chrono::{DateTime, Local, TimeZone, Utc};

use super::upcoming::{self, EventStatus, UpcomingKind};
use super::*;
use crate::model::{CalendarParticipantIdentity, Meeting};

fn at(seconds: i64) -> DateTime<Utc> {
    Utc.timestamp_opt(seconds, 0).unwrap()
}

fn candidate(id: &str, start: i64, end: i64, url: Option<&str>) -> CalendarEvent {
    CalendarEvent {
        provider: "test".into(),
        external_id: id.into(),
        title: "Meeting".into(),
        start: at(start),
        end: at(end),
        meeting_url: url.map(str::to_string),
        source_calendar_title: Some("Work".into()),
        participant_names: Vec::new(),
        participant_identities: Vec::new(),
        agenda: None,
    }
}

// ------------------------------------------------------- ConferenceURLDetector

#[test]
fn detects_google_meet_link() {
    let url = first_meeting_url(Some("Join here: https://meet.google.com/abc-defg-hij")).unwrap();
    assert_eq!(url_host(&url).as_deref(), Some("meet.google.com"));
    assert!(is_meeting_url(&url));
}

#[test]
fn detects_zoom_subdomain() {
    assert!(is_meeting_url("https://us02web.zoom.us/j/123456789"));
}

#[test]
fn detects_teams_and_webex() {
    assert!(is_meeting_url(
        "https://teams.microsoft.com/l/meetup-join/x"
    ));
    assert!(is_meeting_url("https://acme.webex.com/meet/jane"));
}

#[test]
fn detects_chinese_meeting_links() {
    for link in [
        "https://meeting.tencent.com/dm/AbCdEf12",
        "https://voovmeeting.com/dm/AbCdEf12",
        "https://vc.feishu.cn/j/123456789",
        "https://vc.larksuite.com/j/123456789",
        "https://meeting.dingtalk.com/j/AbCdEf12",
    ] {
        assert!(is_meeting_url(link), "{link}");
    }
    let invite = "腾讯会议：https://meeting.tencent.com/dm/AbCdEf12 会议号：123 456 789";
    let url = first_meeting_url(Some(invite)).unwrap();
    assert_eq!(url_host(&url).as_deref(), Some("meeting.tencent.com"));
    // Other Feishu and DingTalk pages are documents and downloads, not calls.
    assert!(!is_meeting_url("https://www.feishu.cn/docx/AbC"));
    assert!(!is_meeting_url("https://www.dingtalk.com/download"));
}

#[test]
fn ignores_non_meeting_url() {
    assert_eq!(
        first_meeting_url(Some("Agenda at https://docs.example.com/agenda")),
        None
    );
    assert!(!is_meeting_url("https://example.com/zoom.us-lookalike"));
}

#[test]
fn no_url_in_plain_or_empty_text() {
    assert_eq!(first_meeting_url(None), None);
    assert_eq!(first_meeting_url(Some("")), None);
    assert_eq!(first_meeting_url(Some("No links here, just a note.")), None);
}

#[test]
fn finds_links_in_invitation_markup_and_without_a_scheme() {
    let outlook = "Join: <https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d>.";
    assert_eq!(
        first_meeting_url(Some(outlook)).as_deref(),
        Some(
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d"
        )
    );
    assert_eq!(
        first_meeting_url(Some("Dial zoom.us/j/123456789, or call.")).as_deref(),
        Some("https://zoom.us/j/123456789")
    );
    // An address on a conferencing domain is not a link.
    assert_eq!(first_meeting_url(Some("Ping ana@zoom.us/ later")), None);
    // The first conferencing link wins, not the first link.
    assert_eq!(
        first_meeting_url(Some(
            "Doc https://docs.example.com/a then https://meet.google.com/abc-defg-hij"
        ))
        .as_deref(),
        Some("https://meet.google.com/abc-defg-hij")
    );
}

// -------------------------------------------------------- CalendarEventFilter

fn raw() -> RawCalendarEvent {
    RawCalendarEvent {
        title: Some("Sprint Planning".into()),
        has_attendees: true,
        has_meeting_url: true,
        ..Default::default()
    }
}

#[test]
fn recordable_meeting_passes() {
    assert!(is_recordable_meeting(&raw()));
}

#[test]
fn rejects_all_day_canceled_declined_empty_ooo() {
    let check = |event: RawCalendarEvent, label: &str| {
        assert!(!is_recordable_meeting(&event), "{label}");
    };
    check(
        RawCalendarEvent {
            is_all_day: true,
            ..raw()
        },
        "all-day",
    );
    check(
        RawCalendarEvent {
            is_canceled: true,
            ..raw()
        },
        "canceled",
    );
    check(
        RawCalendarEvent {
            is_declined_by_me: true,
            ..raw()
        },
        "declined",
    );
    check(
        RawCalendarEvent {
            title: Some("   ".into()),
            ..raw()
        },
        "blank title",
    );
    check(
        RawCalendarEvent {
            title: None,
            ..raw()
        },
        "nil title",
    );
    check(
        RawCalendarEvent {
            availability_unavailable: true,
            ..raw()
        },
        "out of office",
    );
}

#[test]
fn rejects_solo_focus_block() {
    assert!(!is_recordable_meeting(&RawCalendarEvent {
        availability_free: true,
        has_attendees: false,
        has_meeting_url: false,
        ..raw()
    }));
}

#[test]
fn free_time_still_recordable_with_attendees_or_link() {
    assert!(is_recordable_meeting(&RawCalendarEvent {
        availability_free: true,
        has_meeting_url: false,
        ..raw()
    }));
    assert!(is_recordable_meeting(&RawCalendarEvent {
        availability_free: true,
        has_attendees: false,
        ..raw()
    }));
}

// ------------------------------------------------------ Active-event selection

#[test]
fn is_active_window() {
    let now = at(10_000);
    let url = Some("https://meet.google.com/abc");
    // In progress.
    assert!(candidate("evt", 9_700, 10_600, url).is_active(now));
    // Within the one-minute early-join grace (a beat early).
    assert!(candidate("evt", 10_030, 10_900, url).is_active(now));
    // Beyond the grace: never auto-record minutes ahead of the start.
    assert!(!candidate("evt", 10_120, 11_000, url).is_active(now));
    assert!(!candidate("evt", 10_600, 11_000, url).is_active(now));
    // Already ended.
    assert!(!candidate("evt", 9_000, 9_900, url).is_active(now));
}

#[test]
fn active_candidate_prefers_in_progress() {
    let now = at(10_000);
    let upcoming = candidate("soon", 10_030, 10_800, None);
    let live = candidate("live", 9_800, 10_500, None);
    let events = [upcoming, live];
    assert_eq!(
        active_event(&events, now).map(|e| e.external_id.as_str()),
        Some("live")
    );
}

#[test]
fn active_candidate_none_when_none_active() {
    let now = at(10_000);
    let events = [
        candidate("past", 8_000, 9_000, None),
        candidate("future", 12_000, 13_000, None),
    ];
    assert!(active_event(&events, now).is_none());
}

#[test]
fn detection_window_spans_fifteen_minutes_back_and_ninety_ahead() {
    let now = at(100_000);
    let events = [
        candidate("ended-long-ago", 90_000, 100_000 - 16 * 60, None),
        candidate("ended-recently", 95_000, 100_000 - 14 * 60, None),
        candidate("later", 100_000 + 89 * 60, 100_000 + 120 * 60, None),
        candidate("too-far", 100_000 + 91 * 60, 100_000 + 120 * 60, None),
    ];
    let ids: Vec<String> = detection_window(&events, now)
        .into_iter()
        .map(|e| e.external_id)
        .collect();
    assert_eq!(ids, ["ended-recently", "later"]);
}

// ------------------------------------------------- Browser-meeting decision

#[test]
fn title_match_alone_does_not_record() {
    assert!(!browser_counts_as_meeting(true, false, false, false, false));
}

#[test]
fn no_title_no_calendar_does_not_record() {
    assert!(!browser_counts_as_meeting(false, true, false, false, false));
}

#[test]
fn calendar_backed_browser_audio_does_not_record() {
    assert!(!browser_counts_as_meeting(false, true, true, false, false));
}

#[test]
fn calendar_without_audio_does_not_record() {
    assert!(!browser_counts_as_meeting(false, false, true, false, false));
}

#[test]
fn strict_mode_requires_calendar() {
    assert!(!browser_counts_as_meeting(true, true, false, true, false));
    assert!(!browser_counts_as_meeting(true, true, false, true, true));
    assert!(browser_counts_as_meeting(false, true, true, true, true));
    assert!(browser_counts_as_meeting(false, true, false, false, true));
}

// ------------------------------------------------------ Repeat suppression

#[test]
fn suppresses_same_event_within_cooldown() {
    assert!(should_suppress_repeat(
        Some("evt#1"),
        Some("evt#1"),
        Some(at(9_900)),
        at(10_000),
        Duration::from_secs(300)
    ));
}

#[test]
fn allows_same_event_after_cooldown() {
    assert!(!should_suppress_repeat(
        Some("evt#1"),
        Some("evt#1"),
        Some(at(9_600)),
        at(10_000),
        Duration::from_secs(300)
    ));
}

#[test]
fn allows_different_event_and_first_recording() {
    assert!(
        !should_suppress_repeat(
            Some("evt#2"),
            Some("evt#1"),
            Some(at(9_990)),
            at(10_000),
            Duration::from_secs(300)
        ),
        "different event"
    );
    assert!(
        !should_suppress_repeat(
            Some("evt#1"),
            None,
            None,
            at(10_000),
            Duration::from_secs(300)
        ),
        "no prior recording"
    );
}

// ------------------------------------------------- Back-to-back handoff

#[test]
fn splits_when_active_calendar_event_changes() {
    assert!(should_split_for_calendar_handoff(
        Some("evt#standup"),
        Some("evt#planning")
    ));
}

#[test]
fn does_not_split_for_same_or_missing_calendar_event() {
    assert!(!should_split_for_calendar_handoff(
        Some("evt#standup"),
        Some("evt#standup")
    ));
    assert!(!should_split_for_calendar_handoff(
        None,
        Some("evt#planning")
    ));
    assert!(!should_split_for_calendar_handoff(
        Some("evt#standup"),
        None
    ));
}

#[test]
fn next_calendar_event_records_after_the_user_stopped_the_previous_one() {
    assert_eq!(
        switch_action(CALENDAR_HANDOFF, true, true),
        SwitchAction::Split
    );
    assert_eq!(
        switch_action(CALENDAR_HANDOFF, false, false),
        SwitchAction::Start
    );
    assert_eq!(
        switch_action(CALENDAR_HANDOFF, false, true),
        SwitchAction::Ignore,
        "a recording the call does not own is left alone"
    );
    assert_eq!(
        switch_action("meeting-app-handoff", false, false),
        SwitchAction::Ignore
    );
}

// ---------------------------------------------------------------- Titling

#[test]
fn recording_title_prefers_calendar() {
    assert_eq!(
        recording_title(Some("Weekly Sync"), true, Some("Google Chrome")),
        "Weekly Sync"
    );
}

#[test]
fn recording_title_falls_back_when_titles_off() {
    assert_eq!(
        recording_title(Some("Weekly Sync"), false, Some("Google Chrome")),
        "Google Chrome meeting"
    );
}

#[test]
fn recording_title_falls_back_when_no_calendar_title() {
    assert_eq!(
        recording_title(Some("  "), true, Some("Zoom")),
        "Zoom meeting"
    );
    assert_eq!(recording_title(None, true, None), "Manual recording");
    assert_eq!(meeting_title("Google Meet meeting"), "Google Meet meeting");
}

#[test]
fn confidence_levels() {
    assert_eq!(confidence(true, true), Confidence::High);
    assert_eq!(confidence(true, false), Confidence::Medium);
    assert_eq!(confidence(false, true), Confidence::Low);
}

// ------------------------------------------------- Meeting metadata (meta.json)

fn fixture_meeting() -> Meeting {
    serde_json::from_str(
        r#"{"id":"7E57C0DE-0000-4000-8000-000000000001","title":"Sprint Planning","appName":"Google Chrome","startedAt":"2023-11-14T22:13:20Z","endedAt":"2023-11-14T23:13:20Z","relativePath":"meetings/2026/06/16-sprint-planning","hasSystemTrack":true}"#,
    )
    .unwrap()
}

#[test]
fn decodes_legacy_meeting_without_calendar_fields() {
    let json = r#"{"id":"7E57C0DE-0000-4000-8000-000000000001","title":"Standup","appName":"Zoom","startedAt":"2026-06-16T09:00:00Z","relativePath":"meetings/2026/06/16-standup","hasSystemTrack":true}"#;
    let meeting: Meeting = serde_json::from_str(json).unwrap();
    assert_eq!(meeting.title, "Standup");
    assert!(meeting.has_system_track);
    assert!(meeting.calendar_provider.is_none());
    assert!(meeting.calendar_event_id.is_none());
    assert!(meeting.scheduled_start_at.is_none());
    assert!(meeting.meeting_url.is_none());
    assert!(meeting.participant_name_hints.is_none());
    assert!(meeting.calendar_participant_identities.is_none());
}

fn planning_event() -> CalendarEvent {
    CalendarEvent {
        provider: provider::ICS.into(),
        external_id: CalendarEvent::occurrence_id("evt", at(1_700_000_000)),
        title: "Sprint Planning".into(),
        start: at(1_700_000_000),
        end: at(1_700_003_600),
        meeting_url: Some("https://meet.google.com/abc-defg-hij".into()),
        source_calendar_title: Some("Work".into()),
        participant_names: vec!["Ana".into(), "Stevan".into()],
        participant_identities: vec![
            CalendarParticipantIdentity::new(
                "ana-calendar-id",
                Some("Ana"),
                Some("ana@example.com"),
            )
            .unwrap(),
            CalendarParticipantIdentity::new("", Some("Stevan"), None).unwrap(),
        ],
        agenda: Some("Review the sprint goals\nPick the release owner".into()),
    }
}

#[test]
fn stamped_calendar_fields_use_the_macos_keys_and_round_trip() {
    let mut meeting = fixture_meeting();
    stamp_meeting(&mut meeting, &planning_event(), false);
    let json = serde_json::to_value(&meeting).unwrap();
    assert_eq!(json["calendarProvider"], "ics");
    assert_eq!(json["calendarEventID"], "evt#1700000000");
    assert_eq!(json["calendarTitle"], "Sprint Planning");
    assert_eq!(json["scheduledStartAt"], "2023-11-14T22:13:20Z");
    assert_eq!(json["scheduledEndAt"], "2023-11-14T23:13:20Z");
    assert_eq!(json["meetingURL"], "https://meet.google.com/abc-defg-hij");
    assert_eq!(
        json["participantNameHints"],
        serde_json::json!(["Ana", "Stevan"])
    );
    assert_eq!(
        json["calendarParticipantIdentities"][0],
        serde_json::json!({"id": "ana-calendar-id", "name": "Ana", "emailAddress": "ana@example.com"})
    );
    assert!(
        json["calendarParticipantIdentities"][1]
            .get("emailAddress")
            .is_none()
    );
    assert!(
        json.get("calendarAgenda").is_none(),
        "agendas stay out unless agenda use is on"
    );
    let decoded: Meeting = serde_json::from_value(json).unwrap();
    assert_eq!(decoded, meeting);

    stamp_meeting(&mut meeting, &planning_event(), true);
    assert_eq!(
        meeting.calendar_agenda.as_deref(),
        Some("Review the sprint goals\nPick the release owner")
    );
}

#[test]
fn decodes_calendar_metadata_written_by_the_mac_app() {
    // JSONEncoder output with `.sortedKeys`, `.prettyPrinted` and escaped
    // slashes, as StorageManager writes meta.json.
    let json = r#"{
  "appName" : "Google Chrome",
  "calendarEventID" : "5F1E2D3C-AAAA-BBBB-CCCC-000000000001:abc#1700000000",
  "calendarParticipantIdentities" : [
    {
      "emailAddress" : "ana@example.com",
      "id" : "C0FFEE00-0000-4000-8000-000000000001",
      "name" : "Ana Petrović"
    },
    {
      "emailAddress" : "jordan@example.com",
      "id" : "C0FFEE00-0000-4000-8000-000000000002"
    }
  ],
  "calendarProvider" : "eventkit",
  "calendarTitle" : "Sprint Planning",
  "hasSystemTrack" : true,
  "id" : "7E57C0DE-0000-4000-8000-000000000001",
  "meetingURL" : "https:\/\/meet.google.com\/abc-defg-hij",
  "participantNameHints" : [
    "Ana Petrović"
  ],
  "relativePath" : "meetings\/2026\/06\/16-sprint-planning",
  "scheduledEndAt" : "2023-11-14T23:13:20Z",
  "scheduledStartAt" : "2023-11-14T22:13:20Z",
  "startedAt" : "2023-11-14T22:13:20Z",
  "title" : "Sprint Planning"
}"#;
    let meeting: Meeting = serde_json::from_str(json).unwrap();
    assert_eq!(meeting.calendar_provider.as_deref(), Some("eventkit"));
    assert_eq!(
        meeting.meeting_url.as_deref(),
        Some("https://meet.google.com/abc-defg-hij")
    );
    assert_eq!(meeting.scheduled_start_at, Some(at(1_700_000_000)));
    let identities = resolved_meeting_identities(&meeting);
    assert_eq!(identities.len(), 2);
    assert_eq!(
        identities[1].suggested_speaker_name().as_deref(),
        Some("Jordan")
    );
    assert!(identities[1].name.is_none());
}

#[test]
fn manual_meeting_omits_calendar_keys() {
    let mut meeting = fixture_meeting();
    meeting.ended_at = None;
    let json = serde_json::to_value(&meeting).unwrap();
    for key in [
        "calendarProvider",
        "calendarEventID",
        "meetingURL",
        "participantNameHints",
        "calendarParticipantIdentities",
        "calendarAgenda",
    ] {
        assert!(json.get(key).is_none(), "{key}");
    }
}

#[test]
fn stamping_a_macos_fixture_meeting_keeps_its_other_fields() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../LokalBotTests/Fixtures/upgrade/0.10.9/library");
    if !root.is_dir() {
        eprintln!("fixture missing at {}", root.display());
        return;
    }
    let source = crate::Library::open_read_only(crate::LibraryPaths::new(root)).unwrap();
    let original = source
        .list_meetings()
        .unwrap()
        .into_iter()
        .find(|m| m.title == "Design review")
        .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let copy = crate::Library::open(crate::LibraryPaths::new(dir.path())).unwrap();
    let mut meeting = original.clone();
    std::fs::create_dir_all(copy.meeting_dir(&meeting)).unwrap();
    stamp_meeting(&mut meeting, &planning_event(), true);
    copy.save_meeting(&meeting).unwrap();
    let reread = copy.meeting(meeting.id).unwrap().unwrap();
    assert_eq!(reread, meeting);
    let restored = Meeting {
        calendar_provider: None,
        calendar_event_id: None,
        calendar_title: None,
        scheduled_start_at: None,
        scheduled_end_at: None,
        meeting_url: None,
        participant_name_hints: None,
        calendar_participant_identities: None,
        calendar_agenda: None,
        ..reread
    };
    assert_eq!(restored, original);
}

// -------------------------------------------- CalendarParticipantIdentityTests

#[test]
fn missing_calendar_names_offer_editable_email_suggestions_without_changing_metadata() {
    for (address, expected) in [
        ("ana@example.com", "Ana"),
        ("ana.petrovic+meetings@example.com", "Ana Petrovic"),
        ("alex_kim@example.com", "Alex Kim"),
        ("jean-luc@example.com", "Jean Luc"),
    ] {
        let guest = CalendarParticipantIdentity::new("guest", None, Some(address)).unwrap();
        assert_eq!(guest.suggested_speaker_name().as_deref(), Some(expected));
        assert!(guest.name.is_none());
        let encoded = serde_json::to_string(&guest).unwrap();
        let restored: CalendarParticipantIdentity = serde_json::from_str(&encoded).unwrap();
        assert_eq!(restored, guest);
        assert!(restored.name.is_none());
        assert_eq!(restored.suggested_speaker_name().as_deref(), Some(expected));
        assert!(!encoded.contains("suggestedSpeakerName"));
    }
}

#[test]
fn display_names_win_and_ambiguous_mailbox_handles_need_manual_names() {
    let named =
        CalendarParticipantIdentity::new("", Some("Ana Petrović"), Some("alias@example.com"))
            .unwrap();
    assert_eq!(
        named.suggested_speaker_name().as_deref(),
        Some("Ana Petrović")
    );
    for address in [
        "support@example.com",
        "no-reply@example.com",
        "room123@example.com",
        "a9b81c7d@example.com",
        "a@example.com",
        "person=alias@example.com",
    ] {
        let guest = CalendarParticipantIdentity::new("", None, Some(address)).unwrap();
        assert_eq!(guest.suggested_speaker_name(), None, "{address}");
    }
}

#[test]
fn same_suggested_name_does_not_merge_distinct_guests() {
    let first = CalendarParticipantIdentity::new("one", None, Some("ana@one.example")).unwrap();
    let second = CalendarParticipantIdentity::new("two", None, Some("ana@two.example")).unwrap();
    let guests = CalendarParticipantIdentity::normalized(&[first, second]);
    let names: Vec<Option<String>> = guests.iter().map(|g| g.suggested_speaker_name()).collect();
    assert_eq!(names, [Some("Ana".to_string()), Some("Ana".to_string())]);
    let ids: Vec<&str> = guests.iter().map(|g| g.id.as_str()).collect();
    assert_eq!(ids, ["one", "two"]);
}

#[test]
fn extracts_and_normalizes_mailto_address() {
    assert_eq!(
        CalendarParticipantIdentity::email_from_participant_uri(
            "mailto:Ana.Petrovic%2BMeetings@Example.COM?subject=Hello"
        )
        .as_deref(),
        Some("ana.petrovic+meetings@example.com")
    );
    assert_eq!(
        CalendarParticipantIdentity::email_from_participant_uri("urn:uuid:participant-123"),
        None
    );
}

#[test]
fn deduplicates_by_email_and_prefers_available_name() {
    let email_only =
        CalendarParticipantIdentity::new("first", None, Some("ANA@example.com")).unwrap();
    let named =
        CalendarParticipantIdentity::new("second", Some(" Ana Petrović "), Some("ana@example.com"))
            .unwrap();
    let result = CalendarParticipantIdentity::normalized(&[email_only, named]);
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].id, "first");
    assert_eq!(result[0].name.as_deref(), Some("Ana Petrović"));
    assert_eq!(result[0].email_address.as_deref(), Some("ana@example.com"));
}

#[test]
fn same_name_with_different_emails_remains_distinct() {
    let first =
        CalendarParticipantIdentity::new("first", Some("Alex Kim"), Some("alex@one.example"))
            .unwrap();
    let second =
        CalendarParticipantIdentity::new("second", Some("Alex Kim"), Some("alex@two.example"))
            .unwrap();
    assert_eq!(
        CalendarParticipantIdentity::normalized(&[first, second]).len(),
        2
    );
}

#[test]
fn legacy_name_identity_is_stable_across_loads() {
    let first = CalendarParticipantIdentity::from_legacy_names(&["Ana Petrović".into()]);
    let second = CalendarParticipantIdentity::from_legacy_names(&["Ana Petrović".into()]);
    assert_eq!(first[0].id, second[0].id);
}

#[test]
fn display_names_drop_role_suffixes_and_reject_addresses() {
    assert_eq!(
        CalendarParticipantIdentity::normalized_display_name("  Ana   Petrović (Organizer) ")
            .as_deref(),
        Some("Ana Petrović")
    );
    assert_eq!(
        CalendarParticipantIdentity::normalized_display_name("ana@example.com"),
        None
    );
    assert_eq!(
        CalendarParticipantIdentity::normalized_display_name("x"),
        None
    );
}

// ------------------------------------------------------------------ Agenda

#[test]
fn agenda_drops_joining_details_links_and_markup() {
    let notes = "<p>Agenda:</p><ul><li>Review Q3 numbers</li><li>Plan the launch</li></ul>\
        <br>Join Zoom Meeting<br>https://zoom.us/j/123456789<br>Meeting ID: 123 456 789\
        <br>Passcode: 4242<br>+1 646 558 8656<br>Questions? ana@example.com<br>-----------";
    assert_eq!(
        sanitize_agenda(Some(notes)).as_deref(),
        Some("Agenda:\nReview Q3 numbers\nPlan the launch\nQuestions?")
    );
    assert_eq!(sanitize_agenda(Some("Join with Google Meet")), None);
    assert_eq!(sanitize_agenda(None), None);
    let long = "Discuss roadmap item. ".repeat(100);
    let cut = sanitize_agenda(Some(&long)).unwrap();
    assert_eq!(cut.chars().count(), MAX_AGENDA_CHARACTERS + 1);
    assert!(cut.ends_with('…'));
}

// ------------------------------------------------- UpcomingMeetingSelector

fn local(day: chrono::NaiveDate, hour: u32, minute: u32) -> DateTime<Utc> {
    Local
        .from_local_datetime(&day.and_hms_opt(hour, minute, 0).unwrap())
        .earliest()
        .unwrap()
        .with_timezone(&Utc)
}

fn scheduled(id: &str, title: &str, start: DateTime<Utc>, minutes: i64) -> CalendarEvent {
    CalendarEvent {
        provider: "test".into(),
        external_id: id.into(),
        title: title.into(),
        start,
        end: start + chrono::Duration::minutes(minutes),
        meeting_url: Some("https://zoom.us/j/1".into()),
        source_calendar_title: None,
        participant_names: vec!["Maya".into()],
        participant_identities: Vec::new(),
        agenda: None,
    }
}

#[test]
fn schedule_includes_ended_and_distant_meetings_across_the_whole_day() {
    let day = chrono::NaiveDate::from_ymd_opt(2026, 10, 19).unwrap();
    let events = [
        scheduled("late", "Late review", local(day, 17, 0), 30),
        scheduled("early", "Early sync", local(day, 8, 0), 30),
        scheduled(
            "yesterday",
            "Yesterday",
            local(day.pred_opt().unwrap(), 10, 0),
            30,
        ),
        scheduled(
            "tomorrow",
            "Tomorrow",
            local(day.succ_opt().unwrap(), 10, 0),
            30,
        ),
    ];
    let ids: Vec<String> = upcoming::schedule(&events, day)
        .into_iter()
        .map(|e| e.external_id)
        .collect();
    assert_eq!(ids, ["early", "late"]);
}

#[test]
fn selector_prefers_active_then_soonest_and_excludes_current_recording() {
    let now = at(100_000);
    let schedule = [
        scheduled("ended", "Ended", now - chrono::Duration::hours(2), 30),
        scheduled("active", "Active", now - chrono::Duration::minutes(10), 60),
        scheduled("soon", "Soon", now + chrono::Duration::minutes(20), 30),
        scheduled("later", "Later", now + chrono::Duration::hours(3), 30),
    ];
    let pick = |excluding: Option<&str>| {
        upcoming::primary(&schedule, now, excluding).map(|e| e.external_id.clone())
    };
    assert_eq!(pick(None).as_deref(), Some("active"));
    assert_eq!(pick(Some("active")).as_deref(), Some("soon"));
}

#[test]
fn today_leaves_out_personal_appointments_and_keeps_solo_meetings_without_recording() {
    let day = chrono::NaiveDate::from_ymd_opt(2026, 10, 19).unwrap();
    let mut dentist = scheduled("dentist", "Dentist", local(day, 9, 0), 60);
    dentist.meeting_url = None;
    dentist.participant_names.clear();
    let mut standup = scheduled("standup", "Daily standup", local(day, 10, 0), 15);
    standup.meeting_url = None;
    standup.participant_names.clear();
    assert_eq!(upcoming::kind(&dentist), UpcomingKind::Personal);
    assert_eq!(upcoming::kind(&standup), UpcomingKind::SoloMeeting);
    let ids: Vec<String> = upcoming::schedule(&[dentist, standup], day)
        .into_iter()
        .map(|e| e.external_id)
        .collect();
    assert_eq!(ids, ["standup"]);
}

#[test]
fn meeting_titles_are_recognized_without_matching_inside_other_words() {
    for title in [
        "Weekly sync",
        "1:1 with Ana",
        "Sastanak tima",
        "Design review",
        "Kick-off",
    ] {
        assert!(upcoming::looks_like_meeting(title), "{title}");
    }
    for title in [
        "Dentist",
        "Pick up groceries",
        "Recalls paperwork",
        "Syncope check",
    ] {
        assert!(!upcoming::looks_like_meeting(title), "{title}");
    }
}

#[test]
fn presentation_labels_past_meeting_as_ended() {
    let now = at(100_000);
    let event = scheduled("x", "Sync", now - chrono::Duration::hours(1), 30);
    assert_eq!(upcoming::status(&event, now), EventStatus::Ended);
    let next = scheduled("y", "Sync", now + chrono::Duration::minutes(75), 30);
    assert_eq!(
        upcoming::status(&next, now),
        EventStatus::InHours {
            hours: 1,
            minutes: 15
        }
    );
    let soon = scheduled("z", "Sync", now + chrono::Duration::seconds(30), 30);
    assert_eq!(upcoming::status(&soon, now), EventStatus::StartingNow);
    let mut many = scheduled("w", "Sync", now, 30);
    many.participant_names = ["A", "B", "C", "D", "E", "F"].map(String::from).to_vec();
    assert_eq!(
        upcoming::participant_label(&many).as_deref(),
        Some("A, B, C, D +2")
    );
}
