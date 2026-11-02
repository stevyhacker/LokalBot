use serde_json::{Value, json};

use super::{DESIGN_REVIEW, Host, fixture, fixture_days, meeting_field};
use crate::SyncError;
use crate::records::{canonical_json, content_hash};

#[test]
fn canonical_json_sorts_keys_and_drops_whitespace() {
    let a: Value =
        serde_json::from_str(r#"{ "b": 1, "a": { "y": [3, {"d": null, "c": "x"}], "x": true } }"#)
            .unwrap();
    let b: Value =
        serde_json::from_str(r#"{"a":{"x":true,"y":[3,{"c":"x","d":null}]},"b":1}"#).unwrap();
    assert_eq!(
        canonical_json(&a),
        r#"{"a":{"x":true,"y":[3,{"c":"x","d":null}]},"b":1}"#
    );
    assert_eq!(canonical_json(&a), canonical_json(&b));
    assert_eq!(
        content_hash(&canonical_json(&a)),
        content_hash(&canonical_json(&b))
    );
    // Escapes, non-ASCII text and numbers are stable.
    let c = json!({ "t": "line\n\"quote\" — 深色", "n": 721.4, "i": -3, "z": 0 });
    assert_eq!(
        canonical_json(&c),
        "{\"i\":-3,\"n\":721.4,\"t\":\"line\\n\\\"quote\\\" — 深色\",\"z\":0}"
    );
}

#[test]
fn publishing_the_same_content_is_a_no_op() {
    let host = Host::empty();
    let server = &host.server;
    let body = r#"{"id":"p1","displayName":"Maya","meetingIds":[]}"#;
    assert!(
        server
            .publish("person".into(), "p1".into(), body.into())
            .unwrap()
    );
    assert_eq!(server.current_seq().unwrap(), 1);
    // Same content, different key order and spacing.
    let reordered = r#"{ "meetingIds": [], "displayName": "Maya", "id": "p1" }"#;
    assert!(
        !server
            .publish("person".into(), "p1".into(), reordered.into())
            .unwrap()
    );
    assert_eq!(server.current_seq().unwrap(), 1);

    let changed = r#"{"id":"p1","displayName":"Maya Chen","meetingIds":[]}"#;
    assert!(
        server
            .publish("person".into(), "p1".into(), changed.into())
            .unwrap()
    );
    assert!(
        server
            .publish("person".into(), "p2".into(), body.into())
            .unwrap()
    );
    let store = host.server_store();
    let p1 = store.envelope("person", "p1").unwrap().unwrap();
    let p2 = store.envelope("person", "p2").unwrap().unwrap();
    assert_eq!((p1.version, p1.seq), (2, 2));
    assert_eq!((p2.version, p2.seq), (1, 3));
    assert_eq!(p1.body["displayName"], "Maya Chen");
    drop(store);
    assert_eq!(server.current_seq().unwrap(), 3);
}

#[test]
fn removal_writes_a_tombstone() {
    let host = Host::new();
    let server = &host.server;
    let before = server.current_seq().unwrap();
    assert!(
        server
            .record_keys("meeting".into())
            .unwrap()
            .contains(&DESIGN_REVIEW.to_owned())
    );
    assert!(
        server
            .remove("meeting".into(), DESIGN_REVIEW.into())
            .unwrap()
    );
    assert!(
        !server
            .remove("meeting".into(), DESIGN_REVIEW.into())
            .unwrap()
    );
    assert!(
        !server
            .remove("meeting".into(), "never-published".into())
            .unwrap()
    );
    assert_eq!(server.current_seq().unwrap(), before + 1);
    assert!(
        !server
            .record_keys("meeting".into())
            .unwrap()
            .contains(&DESIGN_REVIEW.to_owned())
    );
    let tombstone = host
        .server_store()
        .envelope("meeting", DESIGN_REVIEW)
        .unwrap()
        .unwrap();
    assert!(tombstone.deleted);
    assert_eq!(tombstone.version, 2);
    assert_eq!(tombstone.seq, before + 1);
    assert_eq!(tombstone.body, json!({}));
    assert_eq!(
        tombstone.sort_key,
        meeting_field(DESIGN_REVIEW, "startedAt")
    );

    // Publishing again revives it with the next version, even unchanged.
    let body = fixture()
        .into_iter()
        .find(|e| e["key"] == DESIGN_REVIEW && e["kind"] == "meeting")
        .unwrap()["body"]
        .to_string();
    assert!(
        server
            .publish("meeting".into(), DESIGN_REVIEW.into(), body)
            .unwrap()
    );
    let revived = host
        .server_store()
        .envelope("meeting", DESIGN_REVIEW)
        .unwrap()
        .unwrap();
    assert!(!revived.deleted);
    assert_eq!(revived.version, 3);
}

#[test]
fn sort_keys_follow_records_md() {
    let host = Host::new();
    let sort_key = |kind: &str, key: &str| {
        host.server_store()
            .envelope(kind, key)
            .unwrap()
            .unwrap()
            .sort_key
    };
    let started_at = meeting_field(DESIGN_REVIEW, "startedAt");
    assert_eq!(sort_key("meeting", DESIGN_REVIEW), started_at);
    assert_eq!(sort_key("transcript", DESIGN_REVIEW), started_at);
    for day in fixture_days() {
        assert_eq!(sort_key("day", &day), day);
    }
    // People, projects and the manifest use the publish time.
    let published = sort_key("person", "person:maya-chen");
    let published = chrono::DateTime::parse_from_rfc3339(&published).unwrap();
    let age = chrono::Utc::now().signed_duration_since(published);
    assert!(age.num_seconds().abs() < 60, "{published}");
    // A transcript published before its meeting falls back to the publish time.
    host.server
        .publish(
            "transcript".into(),
            "orphan".into(),
            r#"{"meetingId":"orphan","segments":[]}"#.into(),
        )
        .unwrap();
    assert_eq!(sort_key("transcript", "orphan").len(), 24);
}

#[test]
fn catch_up_order_is_newest_first_with_meetings_before_transcripts() {
    let host = Host::new();
    let store = host.server_store();
    let seq = store.current_seq().unwrap();
    let keys = store.changed_keys(0, seq).unwrap();
    assert_eq!(keys.len(), 19);
    let sort_keys: Vec<String> = keys
        .iter()
        .map(|(kind, key)| store.envelope(kind, key).unwrap().unwrap().sort_key)
        .collect();
    assert!(
        sort_keys.windows(2).all(|pair| pair[0] >= pair[1]),
        "{sort_keys:?}"
    );
    let position =
        |kind: &str, key: &str| keys.iter().position(|k| k.0 == kind && k.1 == key).unwrap();
    assert!(position("meeting", DESIGN_REVIEW) < position("transcript", DESIGN_REVIEW));
    // The newest meeting comes before the oldest day.
    let oldest_day = fixture_days().pop().unwrap();
    assert!(position("meeting", super::STANDUP) < position("day", &oldest_day));
    // Only records after the cursor.
    assert_eq!(store.changed_keys(seq - 2, seq).unwrap().len(), 2);
    assert!(store.changed_keys(seq, seq).unwrap().is_empty());
}

#[test]
fn publish_validates_its_input() {
    let host = Host::empty();
    let server = &host.server;
    assert!(matches!(
        server.publish("calendar".into(), "k".into(), "{}".into()),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        server.publish("meeting".into(), String::new(), "{}".into()),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        server.publish("meeting".into(), "k".into(), "[1]".into()),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        server.publish("meeting".into(), "k".into(), "{".into()),
        Err(SyncError::InvalidInput(_))
    ));
    server
        .set_manifest(r#"{"schemaVersion":1,"macName":"Test Mac"}"#.into())
        .unwrap();
    assert_eq!(server.record_keys("manifest".into()).unwrap(), ["library"]);
}

#[test]
fn records_survive_a_restart_of_the_server() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("companion.sqlite");
    let key = crate::generate_static_key().private_key;
    let open = || {
        crate::SyncServer::new(
            crate::ServerConfig {
                db_path: path.to_string_lossy().into_owned(),
                mac_name: "Mac".into(),
                static_private_key: key.clone(),
                port: 0,
            },
            Box::new(NoDelegate),
        )
        .unwrap()
    };
    let server = open();
    server
        .publish(
            "day".into(),
            "2026-10-30".into(),
            r#"{"date":"2026-10-30"}"#.into(),
        )
        .unwrap();
    drop(server);
    let server = open();
    assert_eq!(server.current_seq().unwrap(), 1);
    assert!(
        !server
            .publish(
                "day".into(),
                "2026-10-30".into(),
                r#"{"date":"2026-10-30"}"#.into()
            )
            .unwrap()
    );
}

struct NoDelegate;

impl crate::ServerDelegate for NoDelegate {
    fn approve_pairing(&self, _: String, _: String) -> bool {
        false
    }

    fn apply_op(&self, _: String) -> crate::OpOutcome {
        crate::OpOutcome {
            status: "rejected".into(),
            message: None,
        }
    }

    fn ask(&self, _: String, sink: std::sync::Arc<crate::AskSink>) {
        sink.failed("no".into());
    }

    fn devices_changed(&self) {}
}
