use serde_json::{Value, json};

use super::{
    DESIGN_REVIEW, FIXTURE, Phone, STANDUP, days_after_latest, due_date, fixture_body,
    fixture_days, meeting_field,
};

const NORTHWIND: &str = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e03";
const PRICING_WORKSHOP: &str = "3f6c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e05";
use crate::messages::Envelope;
use crate::{ActionFilter, SyncError};

fn parse(rows: Vec<String>) -> Vec<Value> {
    rows.iter()
        .map(|row| serde_json::from_str(row).unwrap())
        .collect()
}

fn ids(rows: &[Value], field: &str) -> Vec<String> {
    rows.iter()
        .map(|row| {
            row.pointer(field)
                .and_then(Value::as_str)
                .unwrap()
                .to_owned()
        })
        .collect()
}

fn action_ids(phone: &Phone, filter: ActionFilter, today: &str) -> Vec<String> {
    ids(
        &parse(phone.client.actions_on(&filter, today).unwrap()),
        "/action/id",
    )
}

#[test]
fn the_sample_library_imports_and_is_marked() {
    let phone = Phone::new();
    assert!(!phone.client.is_sample().unwrap());
    assert_eq!(phone.client.import_records(FIXTURE.into()).unwrap(), 19);
    assert!(phone.client.is_sample().unwrap());
    // Importing again changes nothing: the versions are the same.
    assert_eq!(phone.client.import_records(FIXTURE.into()).unwrap(), 0);
    assert!(matches!(
        phone.client.import_records("{}".into()),
        Err(SyncError::InvalidInput(_))
    ));
    let status = phone.client.status().unwrap();
    assert!(!status.paired);
    assert_eq!(status.cursor, 0);
}

#[test]
fn manifest_meetings_and_transcripts() {
    let phone = Phone::sample();
    let manifest: Value = serde_json::from_str(&phone.client.manifest().unwrap().unwrap()).unwrap();
    assert_eq!(manifest["macName"], "Sample Mac");

    let meetings = parse(phone.client.meetings(None, None, 0).unwrap());
    assert_eq!(
        ids(&meetings, "/title"),
        [
            "Product standup",
            "Call with Northwind",
            "1:1 with Maya",
            "Design review — onboarding",
            "Pricing workshop",
            "Product standup"
        ]
    );
    assert_eq!(meetings[0]["id"], STANDUP);
    // The design review's day has three meetings.
    let review_day = meeting_field(DESIGN_REVIEW, "day");
    let that_day = parse(
        phone
            .client
            .meetings(Some(review_day.clone()), Some(review_day), 0)
            .unwrap(),
    );
    assert_eq!(that_day.len(), 3);
    assert_eq!(phone.client.meetings(None, None, 2).unwrap().len(), 2);
    assert_eq!(
        phone
            .client
            .meetings(Some(meeting_field(STANDUP, "day")), None, 0)
            .unwrap()
            .len(),
        1
    );
    assert_eq!(
        phone
            .client
            .meetings(None, Some(meeting_field(PRICING_WORKSHOP, "day")), 0)
            .unwrap()
            .len(),
        2
    );

    let meeting: Value =
        serde_json::from_str(&phone.client.meeting(DESIGN_REVIEW.into()).unwrap().unwrap())
            .unwrap();
    assert_eq!(meeting["title"], "Design review — onboarding");
    assert_eq!(meeting["actions"].as_array().unwrap().len(), 3);
    assert!(phone.client.meeting("missing".into()).unwrap().is_none());

    let transcript: Value = serde_json::from_str(
        &phone
            .client
            .transcript(DESIGN_REVIEW.into())
            .unwrap()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(transcript["segments"].as_array().unwrap().len(), 10);
    assert_eq!(transcript["segments"][3]["start"], 721.4);
    assert!(phone.client.transcript(NORTHWIND.into()).unwrap().is_none());
}

#[test]
fn days_newest_first() {
    let phone = Phone::sample();
    let days = fixture_days();
    assert_eq!(days.len(), 4);
    assert_eq!(phone.client.days(0).unwrap(), days);
    assert_eq!(phone.client.days(2).unwrap(), days[..2]);
    let day: Value = serde_json::from_str(
        &phone
            .client
            .day(meeting_field(DESIGN_REVIEW, "day"))
            .unwrap()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        day["digest"]["sections"]["blockers"][0],
        "Waiting on legal review of the pricing tiers."
    );
    assert_eq!(day["timeline"]["sessions"].as_array().unwrap().len(), 6);
    // The newest day has no digest yet.
    let today: Value =
        serde_json::from_str(&phone.client.day(days[0].clone()).unwrap().unwrap()).unwrap();
    assert!(today.get("digest").is_none());
    assert!(phone.client.day("2026-01-01".into()).unwrap().is_none());
}

#[test]
fn actions_sort_overdue_first_then_by_due_date() {
    let phone = Phone::sample();
    let all = parse(
        phone
            .client
            .actions_on(&ActionFilter::default(), &days_after_latest(1))
            .unwrap(),
    );
    assert_eq!(
        ids(&all, "/action/id"),
        [
            "act-1f2e3d4c", // overdue
            "act-7c1e40a2",
            "act-a3f61b28",
            "act-4d2c9e07",
            "act-c40f8d62",
            "act-e2a7c915",
            "act-91b0d3f5", // no due date, newest meeting first
            "act-0e5d77c3",
            "act-58ab2e19",
            "act-6b3d0f44",
        ]
    );
    let first = &all[0];
    assert_eq!(first["meetingId"], DESIGN_REVIEW);
    assert_eq!(first["meetingTitle"], "Design review — onboarding");
    assert_eq!(
        first["meetingStartedAt"],
        meeting_field(DESIGN_REVIEW, "startedAt")
    );
    assert_eq!(first["pending"], false);
    assert_eq!(
        first["action"]["dueText"],
        fixture_body("meeting", DESIGN_REVIEW)["actions"][0]["dueText"]
    );
    assert_eq!(first["action"]["citations"][0]["start"], 721.4);
    assert!(first.get("syncNote").is_none());

    // A deferred action is not overdue, so overdue open ones go first.
    phone
        .client
        .set_action_status(
            DESIGN_REVIEW.into(),
            "act-1f2e3d4c".into(),
            "deferred".into(),
        )
        .unwrap();
    // A week on, every open action due within six days is overdue.
    let later = action_ids(&phone, ActionFilter::default(), &days_after_latest(7));
    assert_eq!(
        later[..6],
        [
            "act-7c1e40a2",
            "act-a3f61b28",
            "act-4d2c9e07",
            "act-c40f8d62",
            "act-1f2e3d4c",
            "act-e2a7c915"
        ]
    );
}

#[test]
fn actions_due_the_same_day_list_the_newer_meeting_first() {
    let meeting = |id: &str, started: &str, action: &str| {
        json!({
            "kind": "meeting", "key": id, "version": 1, "seq": 1, "deleted": false,
            "sortKey": started,
            "body": {
                "id": id, "title": id, "startedAt": started, "endedAt": started,
                "day": &started[..10], "timeZoneOffsetMinutes": 0, "durationSeconds": 60,
                "people": [], "projects": [],
                "actions": [{
                    "id": action, "text": action, "ownerIsUser": true, "ownerUnclear": false,
                    "dueDate": "2030-01-10", "status": "open", "importance": 3, "citations": []
                }],
                "decisions": [], "openQuestions": [], "hasTranscript": false
            }
        })
    };
    let phone = Phone::new();
    let records = json!([
        meeting("older", "2030-01-01T09:00:00.000Z", "act-older"),
        meeting("newer", "2030-01-02T09:00:00.000Z", "act-newer"),
    ]);
    phone.client.import_records(records.to_string()).unwrap();
    assert_eq!(
        action_ids(&phone, ActionFilter::default(), "2030-01-05"),
        ["act-newer", "act-older"]
    );
}

#[test]
fn action_filters() {
    let phone = Phone::sample();
    let today = &days_after_latest(1);
    let filter = |mine_only, status: Option<&str>, owner_unclear_only, due_before: Option<&str>| {
        ActionFilter {
            mine_only,
            status: status.map(str::to_owned),
            owner_unclear_only,
            due_before: due_before.map(str::to_owned),
        }
    };
    assert_eq!(
        action_ids(&phone, filter(true, None, false, None), today),
        [
            "act-1f2e3d4c",
            "act-7c1e40a2",
            "act-4d2c9e07",
            "act-0e5d77c3"
        ]
    );
    assert_eq!(
        action_ids(&phone, filter(false, Some("open"), false, None), today).len(),
        7
    );
    assert_eq!(
        action_ids(&phone, filter(false, Some("done"), false, None), today),
        ["act-0e5d77c3", "act-58ab2e19", "act-6b3d0f44"]
    );
    assert!(action_ids(&phone, filter(false, Some("deferred"), false, None), today).is_empty());
    assert_eq!(
        action_ids(&phone, filter(false, None, true, None), today),
        ["act-91b0d3f5"]
    );
    assert_eq!(
        action_ids(
            &phone,
            filter(
                false,
                None,
                false,
                Some(&due_date(NORTHWIND, "act-4d2c9e07"))
            ),
            today
        ),
        ["act-1f2e3d4c", "act-7c1e40a2", "act-a3f61b28"]
    );
    assert_eq!(
        action_ids(
            &phone,
            filter(
                true,
                Some("open"),
                false,
                Some(&due_date(NORTHWIND, "act-a3f61b28"))
            ),
            today
        ),
        ["act-1f2e3d4c", "act-7c1e40a2"]
    );
    // The FFI entry point uses this device's date.
    assert_eq!(
        phone.client.actions(ActionFilter::default()).unwrap().len(),
        10
    );
}

#[test]
fn the_sample_library_keeps_status_changes_without_a_mac() {
    let phone = Phone::sample();
    phone
        .client
        .set_action_status(DESIGN_REVIEW.into(), "act-1f2e3d4c".into(), "done".into())
        .unwrap();
    let row = phone.action(DESIGN_REVIEW, "act-1f2e3d4c");
    assert_eq!(
        (row["action"]["status"].as_str(), row["pending"].as_bool()),
        (Some("done"), Some(false))
    );
    assert_eq!(phone.client.status().unwrap().pending_ops, 0);
}

#[test]
fn people_and_projects() {
    let phone = Phone::sample();
    let people = parse(phone.client.people().unwrap());
    assert_eq!(
        ids(&people, "/displayName"),
        ["Ben Ortiz", "Maya Chen", "Priya Nair", "Alex Romero"]
    );
    let maya: Value = serde_json::from_str(
        &phone
            .client
            .person("person:maya-chen".into())
            .unwrap()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(maya["openWork"][0]["actionId"], "act-1f2e3d4c");
    assert!(
        phone
            .client
            .person("person:nobody".into())
            .unwrap()
            .is_none()
    );

    let projects = parse(phone.client.projects().unwrap());
    assert_eq!(ids(&projects, "/name"), ["Onboarding", "Pricing"]);
    let pricing: Value = serde_json::from_str(
        &phone
            .client
            .project("7a1d0c55-2b8f-4f3a-a6c4-5e6f7a8b9c02".into())
            .unwrap()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(pricing["waitingOnOthers"].as_array().unwrap().len(), 2);
    assert!(phone.client.project("missing".into()).unwrap().is_none());
}

#[test]
fn merged_meetings_are_hidden() {
    let phone = Phone::sample();
    let merged = json!([{
        "kind": "meeting", "key": "merged-1", "version": 1, "seq": 100, "deleted": false,
        "sortKey": "2026-10-31T09:00:00.000Z",
        "body": {
            "id": "merged-1", "title": "Zeppelin sync", "startedAt": "2026-10-31T09:00:00.000Z",
            "endedAt": "2026-10-31T09:10:00.000Z", "day": "2026-10-31", "timeZoneOffsetMinutes": 60,
            "durationSeconds": 600, "people": [], "projects": [],
            "summaryMarkdown": "Zeppelin launch plan",
            "actions": [ { "id": "act-z", "text": "Inflate the zeppelin", "ownerIsUser": true, "ownerUnclear": false,
                           "status": "open", "importance": 3, "citations": [] } ],
            "decisions": [], "openQuestions": [], "hasTranscript": false, "mergedInto": STANDUP
        }
    }]);
    assert_eq!(phone.client.import_records(merged.to_string()).unwrap(), 1);
    assert_eq!(phone.client.meetings(None, None, 0).unwrap().len(), 6);
    assert!(
        phone
            .client
            .search("zeppelin".into(), 10)
            .unwrap()
            .is_empty()
    );
    assert!(
        !action_ids(&phone, ActionFilter::default(), &days_after_latest(1))
            .contains(&"act-z".to_owned())
    );
    // A direct lookup still finds it, so links can follow `mergedInto`.
    assert!(phone.client.meeting("merged-1".into()).unwrap().is_some());
}

#[test]
fn a_record_keeps_its_highest_version() {
    let phone = Phone::new();
    let envelope = |version: u64, title: &str, deleted: bool| Envelope {
        kind: "meeting".into(),
        key: "m1".into(),
        version,
        seq: version,
        deleted,
        sort_key: "2026-10-30T09:30:00.000Z".into(),
        body: if deleted {
            json!({})
        } else {
            json!({ "id": "m1", "title": title, "startedAt": "2026-10-30T09:30:00.000Z", "day": "2026-10-30", "actions": [] })
        },
    };
    phone
        .client
        .apply_batch(&[envelope(2, "Second", false)], Some(2))
        .unwrap();
    phone
        .client
        .apply_batch(&[envelope(1, "First", false)], Some(3))
        .unwrap();
    let title = |phone: &Phone| {
        phone.client.meeting("m1".into()).unwrap().map(|m| {
            serde_json::from_str::<Value>(&m).unwrap()["title"]
                .as_str()
                .unwrap()
                .to_owned()
        })
    };
    assert_eq!(title(&phone).as_deref(), Some("Second"));
    assert_eq!(phone.client.status().unwrap().cursor, 3);
    phone
        .client
        .apply_batch(&[envelope(3, "", true)], None)
        .unwrap();
    assert_eq!(title(&phone), None);
    assert!(phone.client.search("second".into(), 5).unwrap().is_empty());
    // An older version cannot resurrect a tombstone.
    phone
        .client
        .apply_batch(&[envelope(2, "Second", false)], None)
        .unwrap();
    assert_eq!(title(&phone), None);
    phone
        .client
        .apply_batch(&[envelope(4, "Fourth", false)], None)
        .unwrap();
    assert_eq!(title(&phone).as_deref(), Some("Fourth"));
}

#[test]
fn unpairing_erases_everything() {
    let phone = Phone::sample();
    phone
        .client
        .queue_question(r#"{"requestId":"q1","question":"What is left?"}"#.into())
        .unwrap();
    phone
        .client
        .queue_question(r#"{"requestId":"q2","question":"Who owns pricing?"}"#.into())
        .unwrap();
    // The same request again replaces it.
    phone
        .client
        .queue_question(r#"{"requestId":"q1","question":"What is still left?"}"#.into())
        .unwrap();
    let queued = parse(phone.client.queued_questions().unwrap());
    assert_eq!(
        ids(&queued, "/question"),
        ["What is still left?", "Who owns pricing?"]
    );

    phone.client.unpair().unwrap();
    assert!(!phone.client.is_sample().unwrap());
    assert!(phone.client.manifest().unwrap().is_none());
    assert!(phone.client.meetings(None, None, 0).unwrap().is_empty());
    assert!(phone.client.days(0).unwrap().is_empty());
    assert!(phone.client.people().unwrap().is_empty());
    assert!(
        phone
            .client
            .search("pricing".into(), 10)
            .unwrap()
            .is_empty()
    );
    assert!(phone.client.queued_questions().unwrap().is_empty());
    assert!(phone.client.paired_mac().unwrap().is_none());
    // Neither the file nor its WAL holds any of the old text.
    for name in ["companion.sqlite", "companion.sqlite-wal"] {
        let bytes = std::fs::read(phone.dir.path().join(name)).unwrap_or_default();
        assert!(
            !String::from_utf8_lossy(&bytes).contains("Northwind"),
            "{name}"
        );
    }
}

#[test]
fn client_construction_validates_its_config() {
    let dir = tempfile::TempDir::new().unwrap();
    let config = |key: Vec<u8>, device_id: &str, platform: &str| crate::ClientConfig {
        db_path: dir.path().join("c.sqlite").to_string_lossy().into_owned(),
        device_id: device_id.into(),
        device_name: "Phone".into(),
        platform: platform.into(),
        static_private_key: key,
    };
    let key = crate::generate_static_key().private_key;
    assert!(crate::SyncClient::new(config(key.clone(), "d", "android")).is_ok());
    assert!(matches!(
        crate::SyncClient::new(config(vec![0; 3], "d", "ios")),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        crate::SyncClient::new(config(key.clone(), " ", "ios")),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        crate::SyncClient::new(config(key, "d", "watchos")),
        Err(SyncError::InvalidInput(_))
    ));
}
