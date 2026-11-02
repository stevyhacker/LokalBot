use std::net::TcpStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use serde_json::{Value, json};

use super::{DESIGN_REVIEW, Host, Phone, days_after_latest, fast_tuning};
use crate::messages::{Envelope, Message};
use crate::wire::{Channel, Inbox, PREFACE_SESSION, RawConn, session_handshake};
use crate::{AskListener, ClientConfig, OpOutcome, SyncClient, SyncError};

const DECK: &str = "act-1f2e3d4c";

/// Messages until one matches, skipping pings.
fn recv_until(
    channel: &Channel,
    inbox: &mut Inbox,
    mut wanted: impl FnMut(&Message) -> bool,
) -> Vec<Message> {
    let tuning = fast_tuning();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    loop {
        let message = inbox
            .recv(channel, &tuning, Some(deadline))
            .expect("a message");
        if message == Message::Ping {
            continue;
        }
        let done = wanted(&message);
        seen.push(message);
        if done {
            return seen;
        }
    }
}

fn wait_for(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out waiting");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn set_status_op(op_id: &str, status: &str) -> Value {
    json!({
        "type": "action.setStatus", "opId": op_id, "meetingId": DESIGN_REVIEW, "actionId": DECK,
        "actionText": "Send the revised pricing deck to Maya", "status": status, "at": "2026-10-31T07:12:00.000Z"
    })
}

/// The Mac applies status ops to the fixture meeting and republishes it.
fn apply_status_ops(host: &Host) {
    host.delegate.on_op(|server, op| {
        let applied = Host::set_status(
            server,
            op["meetingId"].as_str().unwrap(),
            op["actionId"].as_str().unwrap(),
            op["status"].as_str().unwrap(),
        );
        OpOutcome {
            status: if applied { "applied" } else { "unmatched" }.into(),
            message: None,
        }
    });
}

#[test]
fn a_paired_phone_receives_the_whole_library() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    let port = host.server.bound_port();
    let report = phone.client.sync(vec![]).unwrap();
    assert_eq!(report.received, 19);
    assert_eq!(report.deleted, 0);
    assert_eq!(report.ops_applied, 0);
    assert_eq!(report.cursor, host.server.current_seq().unwrap());
    assert_eq!(report.address, format!("127.0.0.1:{port}"));
    assert!(report.finished_at.ends_with('Z'));

    let status = phone.client.status().unwrap();
    assert_eq!(status.cursor, report.cursor);
    assert_eq!(
        status.last_sync_at.as_deref(),
        Some(report.finished_at.as_str())
    );
    assert_eq!(
        status.last_address.as_deref(),
        Some(report.address.as_str())
    );
    assert_eq!(status.mac_name.as_deref(), Some("Test Mac"));
    assert_eq!(status.pending_ops, 0);
    assert_eq!(phone.client.meetings(None, None, 0).unwrap().len(), 6);
    let manifest: Value = serde_json::from_str(&phone.client.manifest().unwrap().unwrap()).unwrap();
    assert_eq!(manifest["libraryName"], "Sample library");

    // Nothing changed, nothing sent.
    let again = phone.client.sync(vec![]).unwrap();
    assert_eq!(
        (again.received, again.deleted, again.cursor),
        (0, 0, report.cursor)
    );

    wait_for(|| host.server.connected_device_ids().is_empty());
    let device = &host.server.paired_devices().unwrap()[0];
    assert_eq!(device.last_address.as_deref(), Some("127.0.0.1"));
    assert!(device.last_seen_at.is_some());
}

#[test]
fn extra_addresses_come_first_and_dead_ones_are_skipped() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    let port = host.server.bound_port();
    let report = phone
        .client
        .sync(vec!["127.0.0.1:1".into(), format!("localhost:{port}")])
        .unwrap();
    assert_eq!(report.received, 19);
    assert!(report.address.ends_with(&format!(":{port}")));
}

#[test]
fn an_unknown_device_is_dropped_during_the_handshake() {
    let host = Host::new();
    let stranger = crate::generate_static_key();
    let stream = TcpStream::connect(("127.0.0.1", host.server.bound_port())).unwrap();
    let mut conn = RawConn::new(stream, &fast_tuning()).unwrap();
    conn.send_packet(&[PREFACE_SESSION]).unwrap();
    let private = crate::keys::key_array(&stranger.private_key, "k").unwrap();
    let mut handshake = session_handshake(&private, Some(&host.server.public_key())).unwrap();
    conn.write_handshake(&mut handshake).unwrap();
    // The Mac closes without sending a single byte back.
    assert!(matches!(conn.recv_packet(), Err(SyncError::Io(_))));

    // A copy of a paired phone's store with another key cannot sync either.
    let phone = Phone::paired(&host);
    let impostor = SyncClient::new(ClientConfig {
        db_path: phone
            .dir
            .path()
            .join("companion.sqlite")
            .to_string_lossy()
            .into_owned(),
        device_id: phone.device_id.clone(),
        device_name: "Impostor".into(),
        platform: "android".into(),
        static_private_key: stranger.private_key,
    })
    .unwrap();
    impostor.set_tuning(fast_tuning());
    assert!(matches!(
        impostor.sync(vec![]),
        Err(SyncError::Unreachable(_))
    ));
    assert!(host.server.connected_device_ids().is_empty());
}

#[test]
fn a_removed_device_is_revoked_and_erases_its_copy() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    phone.client.sync(vec![]).unwrap();
    assert_eq!(phone.client.meetings(None, None, 0).unwrap().len(), 6);
    phone
        .client
        .queue_question(r#"{"requestId":"q1","question":"What changed?"}"#.into())
        .unwrap();

    host.server.remove_device(phone.device_id.clone()).unwrap();
    assert!(host.server.paired_devices().unwrap().is_empty());
    assert!(matches!(
        phone.client.sync(vec![]),
        Err(SyncError::Revoked(_))
    ));

    let status = phone.client.status().unwrap();
    assert!(!status.paired);
    assert_eq!(status.cursor, 0);
    assert!(phone.client.meetings(None, None, 0).unwrap().is_empty());
    assert!(
        phone
            .client
            .search("pricing".into(), 10)
            .unwrap()
            .is_empty()
    );
    assert!(phone.client.queued_questions().unwrap().is_empty());
    assert!(phone.client.manifest().unwrap().is_none());
    assert!(matches!(
        phone.client.sync(vec![]),
        Err(SyncError::NotPaired(_))
    ));
}

#[test]
fn a_device_removed_while_connected_is_told_at_once() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = phone.client.open_live().unwrap();
    wait_for(|| host.server.connected_device_ids() == [phone.device_id.clone()]);
    host.server.remove_device(phone.device_id.clone()).unwrap();
    let seen = recv_until(&channel, &mut inbox, |m| *m == Message::Revoked);
    assert_eq!(seen.last(), Some(&Message::Revoked));
    wait_for(|| host.server.connected_device_ids().is_empty());
}

#[test]
fn records_an_op_rebuilt_arrive_before_its_result() {
    let host = Host::new();
    apply_status_ops(&host);
    let phone = Phone::paired(&host);
    let cursor = phone.client.sync(vec![]).unwrap().cursor;
    let (channel, mut inbox) = phone.client.open_session("sync", cursor).unwrap();
    channel
        .send(&Message::Op {
            op: set_status_op("op-1", "done"),
        })
        .unwrap();
    let seen = recv_until(&channel, &mut inbox, |m| {
        matches!(m, Message::OpResult { .. })
    });

    // The empty catch-up, then the rebuilt meeting, then the result.
    let records: Vec<(usize, &Vec<Envelope>, bool)> = seen
        .iter()
        .enumerate()
        .filter_map(|(i, m)| match m {
            Message::Records { items, done, .. } => Some((i, items, *done)),
            _ => None,
        })
        .collect();
    assert!(records.iter().all(|(_, _, done)| *done));
    let (rebuilt_at, items, _) = records
        .iter()
        .find(|(_, items, _)| items.iter().any(|e| e.key == DESIGN_REVIEW))
        .expect("the rebuilt meeting arrives");
    let meeting = items
        .iter()
        .find(|e| e.key == DESIGN_REVIEW && e.kind == "meeting")
        .unwrap();
    assert_eq!(meeting.version, 2);
    let action = meeting.body["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == DECK)
        .unwrap();
    assert_eq!(action["status"], "done");
    let result_at = seen.len() - 1;
    assert!(*rebuilt_at < result_at);
    assert_eq!(
        seen[result_at],
        Message::OpResult {
            op_id: "op-1".into(),
            status: "applied".into(),
            message: None
        }
    );
}

#[test]
fn a_status_change_from_the_phone_reaches_the_mac() {
    let host = Host::new();
    apply_status_ops(&host);
    let phone = Phone::paired(&host);
    phone.client.sync(vec![]).unwrap();

    phone
        .client
        .set_action_status(DESIGN_REVIEW.into(), DECK.into(), "done".into())
        .unwrap();
    let row = phone.action(DESIGN_REVIEW, DECK);
    assert_eq!(row["action"]["status"], "done");
    assert_eq!(row["pending"], true);
    assert_eq!(phone.client.status().unwrap().pending_ops, 1);
    let meeting: Value =
        serde_json::from_str(&phone.client.meeting(DESIGN_REVIEW.into()).unwrap().unwrap())
            .unwrap();
    let action = meeting["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["id"] == DECK)
        .unwrap()
        .clone();
    assert_eq!(
        (action["status"].as_str(), action["pending"].as_bool()),
        (Some("done"), Some(true))
    );

    let report = phone.client.sync(vec![]).unwrap();
    assert_eq!(report.ops_applied, 1);
    assert_eq!(report.received, 1);
    let row = phone.action(DESIGN_REVIEW, DECK);
    assert_eq!(row["action"]["status"], "done");
    assert_eq!(row["pending"], false);
    assert_eq!(phone.client.status().unwrap().pending_ops, 0);

    let ops = host.delegate.ops.lock();
    assert_eq!(ops.len(), 1);
    assert_eq!(ops[0]["type"], "action.setStatus");
    assert_eq!(ops[0]["meetingId"], DESIGN_REVIEW);
    assert_eq!(ops[0]["actionId"], DECK);
    assert_eq!(
        ops[0]["actionText"],
        "Send the revised pricing deck to Maya"
    );
    assert_eq!(ops[0]["status"], "done");
    assert!(ops[0]["opId"].as_str().is_some_and(|id| id.len() == 36));
    assert!(ops[0]["at"].as_str().is_some_and(|at| at.ends_with('Z')));
}

#[test]
fn an_unmatched_op_reverts_and_keeps_a_note() {
    let host = Host::new();
    host.delegate.on_op(|_, _| OpOutcome {
        status: "unmatched".into(),
        message: Some("The action changed on the Mac.".into()),
    });
    let phone = Phone::paired(&host);
    phone.client.sync(vec![]).unwrap();
    phone
        .client
        .set_action_status(DESIGN_REVIEW.into(), DECK.into(), "done".into())
        .unwrap();
    assert_eq!(phone.action(DESIGN_REVIEW, DECK)["pending"], true);

    let report = phone.client.sync(vec![]).unwrap();
    assert_eq!(report.ops_applied, 0);
    let row = phone.action(DESIGN_REVIEW, DECK);
    assert_eq!(row["action"]["status"], "open");
    assert_eq!(row["pending"], false);
    assert_eq!(row["syncNote"]["status"], "unmatched");
    assert_eq!(row["syncNote"]["requestedStatus"], "done");
    assert_eq!(row["syncNote"]["message"], "The action changed on the Mac.");
    assert_eq!(phone.client.status().unwrap().pending_ops, 0);

    // A new version of the meeting from the Mac retires the note.
    Host::set_status(&host.server, DESIGN_REVIEW, "act-58ab2e19", "open");
    phone.client.sync(vec![]).unwrap();
    assert!(phone.action(DESIGN_REVIEW, DECK).get("syncNote").is_none());
}

#[test]
fn offline_changes_wait_for_the_mac_and_coalesce() {
    let host = Host::new();
    apply_status_ops(&host);
    let phone = Phone::paired(&host);
    phone.client.sync(vec![]).unwrap();
    host.server.stop();
    assert!(!host.server.is_running());

    phone
        .client
        .set_action_status(DESIGN_REVIEW.into(), DECK.into(), "done".into())
        .unwrap();
    phone
        .client
        .set_action_status(DESIGN_REVIEW.into(), DECK.into(), "deferred".into())
        .unwrap();
    assert!(matches!(
        phone.client.sync(vec![]),
        Err(SyncError::Unreachable(_))
    ));
    assert_eq!(phone.client.status().unwrap().pending_ops, 1);
    assert_eq!(
        phone.action(DESIGN_REVIEW, DECK)["action"]["status"],
        "deferred"
    );
    assert_eq!(phone.action(DESIGN_REVIEW, DECK)["pending"], true);

    // The Mac comes back on another port; Bonjour would report it.
    host.server.start().unwrap();
    let address = format!("127.0.0.1:{}", host.server.bound_port());
    let report = phone.client.sync(vec![address]).unwrap();
    assert_eq!(report.ops_applied, 1);
    assert_eq!(host.delegate.ops.lock().len(), 1);
    assert_eq!(host.delegate.ops.lock()[0]["status"], "deferred");
    let row = phone.action(DESIGN_REVIEW, DECK);
    assert_eq!(
        (row["action"]["status"].as_str(), row["pending"].as_bool()),
        (Some("deferred"), Some(false))
    );
}

#[test]
fn status_changes_need_a_known_action_and_status() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    phone.client.sync(vec![]).unwrap();
    let set = |meeting: &str, action: &str, status: &str| {
        phone
            .client
            .set_action_status(meeting.into(), action.into(), status.into())
    };
    assert!(matches!(
        set(DESIGN_REVIEW, DECK, "finished"),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        set(DESIGN_REVIEW, "act-missing", "done"),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        set("no-meeting", DECK, "done"),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        Phone::new()
            .client
            .set_action_status(DESIGN_REVIEW.into(), DECK.into(), "done".into()),
        Err(SyncError::InvalidInput(_))
    ));
}

struct Collector(Arc<Mutex<Vec<String>>>);

impl AskListener for Collector {
    fn on_delta(&self, text: String) {
        self.0.lock().push(text);
    }
}

fn question(request_id: &str) -> String {
    json!({
        "requestId": request_id, "conversationId": "c1",
        "question": "What did we decide about onboarding this week?",
        "history": [], "scope": { "day": "2026-10-30" }
    })
    .to_string()
}

#[test]
fn asking_streams_the_answer_and_keeps_it() {
    let host = Host::new();
    host.delegate.on_ask(|request, sink| {
        std::thread::spawn(move || {
            for part in ["You agreed to cut ", "onboarding to three steps ", "[1]."] {
                std::thread::sleep(Duration::from_millis(30));
                sink.delta(part.into());
            }
            let result = json!({
                "requestId": request["requestId"],
                "answer": "You agreed to cut onboarding to three steps [1].",
                "citations": [ { "index": 1, "meetingId": DESIGN_REVIEW, "at": 724, "label": "Design review — onboarding · 12:04" } ],
                "engineLabel": "Test engine", "location": "mac", "answeredAt": "2026-10-31T07:15:02.000Z"
            });
            sink.done(result.to_string());
            // Late calls are ignored.
            sink.delta("ignored".into());
            sink.failed("ignored".into());
        });
    });
    let phone = Phone::paired(&host);
    phone.client.queue_question(question("q1")).unwrap();
    assert_eq!(phone.client.queued_questions().unwrap().len(), 1);

    let deltas = Arc::new(Mutex::new(Vec::new()));
    let result = phone
        .client
        .ask(
            question("q1"),
            vec![],
            Box::new(Collector(Arc::clone(&deltas))),
        )
        .unwrap();
    assert_eq!(
        *deltas.lock(),
        ["You agreed to cut ", "onboarding to three steps ", "[1]."]
    );
    let result: Value = serde_json::from_str(&result).unwrap();
    assert_eq!(result["requestId"], "q1");
    assert_eq!(result["citations"][0]["meetingId"], DESIGN_REVIEW);
    assert_eq!(result["location"], "mac");

    let history = phone.client.ask_history(10).unwrap();
    assert_eq!(history.len(), 1);
    let entry: Value = serde_json::from_str(&history[0]).unwrap();
    assert_eq!(
        entry["request"]["question"],
        "What did we decide about onboarding this week?"
    );
    assert_eq!(
        entry["result"]["answer"],
        "You agreed to cut onboarding to three steps [1]."
    );
    assert!(phone.client.queued_questions().unwrap().is_empty());

    // Newest first.
    phone
        .client
        .ask(question("q2"), vec![], Box::new(Collector(Arc::default())))
        .unwrap();
    let history = phone.client.ask_history(0).unwrap();
    assert_eq!(history.len(), 2);
    assert!(history[0].contains("\"q2\""));
    assert_eq!(phone.client.ask_history(1).unwrap().len(), 1);
}

#[test]
fn a_failed_answer_is_an_error_and_is_not_kept() {
    let host = Host::new();
    host.delegate
        .on_ask(|_, sink| sink.failed("The model is not loaded.".into()));
    let phone = Phone::paired(&host);
    let error = phone
        .client
        .ask(question("q1"), vec![], Box::new(Collector(Arc::default())))
        .unwrap_err();
    assert_eq!(
        error,
        SyncError::Protocol("The model is not loaded.".into())
    );
    assert!(phone.client.ask_history(0).unwrap().is_empty());

    // An unreadable result is reported as a failure too.
    host.delegate.on_ask(|_, sink| sink.done("not json".into()));
    assert!(matches!(
        phone
            .client
            .ask(question("q2"), vec![], Box::new(Collector(Arc::default()))),
        Err(SyncError::Protocol(_))
    ));
}

#[test]
fn queued_questions_leave_the_queue_only_once_answered() {
    let host = Host::new();
    let asked = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&asked);
    host.delegate.on_ask(move |_, sink| {
        counter.fetch_add(1, Ordering::SeqCst);
        sink.failed("The model is not loaded.".into());
    });
    let phone = Phone::paired(&host);
    let queued = |phone: &Phone| -> Vec<String> {
        phone
            .client
            .queued_questions()
            .unwrap()
            .iter()
            .map(|q| {
                serde_json::from_str::<Value>(q).unwrap()["requestId"]
                    .as_str()
                    .unwrap()
                    .to_owned()
            })
            .collect()
    };
    phone.client.queue_question(question("q1")).unwrap();
    phone.client.queue_question(question("q2")).unwrap();

    // A sync never sends queued questions.
    phone.client.sync(vec![]).unwrap();
    assert_eq!(asked.load(Ordering::SeqCst), 0);
    assert_eq!(queued(&phone), ["q1", "q2"]);

    // A failed answer keeps the question queued.
    let ask = |phone: &Phone, id: &str, extra: Vec<String>| {
        phone
            .client
            .ask(question(id), extra, Box::new(Collector(Arc::default())))
    };
    assert!(matches!(
        ask(&phone, "q1", vec![]),
        Err(SyncError::Protocol(_))
    ));
    assert_eq!(asked.load(Ordering::SeqCst), 1);
    assert_eq!(queued(&phone), ["q1", "q2"]);

    // So does an unreachable Mac.
    host.server.stop();
    assert!(matches!(
        ask(&phone, "q1", vec![]),
        Err(SyncError::Unreachable(_))
    ));
    assert_eq!(queued(&phone), ["q1", "q2"]);

    // An answer removes exactly that question and keeps the answer.
    host.server.start().unwrap();
    host.delegate.on_ask(|request, sink| {
        let result = json!({ "requestId": request["requestId"], "answer": "Three steps.", "citations": [],
                             "engineLabel": "Test engine", "location": "mac", "answeredAt": "2026-10-31T07:15:02.000Z" });
        sink.done(result.to_string());
    });
    let address = format!("127.0.0.1:{}", host.server.bound_port());
    ask(&phone, "q1", vec![address.clone()]).unwrap();
    assert_eq!(queued(&phone), ["q2"]);
    assert_eq!(phone.client.ask_history(0).unwrap().len(), 1);
    // Asking something that was never queued leaves the queue alone.
    ask(&phone, "q3", vec![address]).unwrap();
    assert_eq!(queued(&phone), ["q2"]);
}

#[test]
fn ask_needs_a_pairing_and_a_well_formed_question() {
    let phone = Phone::new();
    let ask = |json: &str| {
        phone
            .client
            .ask(json.into(), vec![], Box::new(Collector(Arc::default())))
    };
    assert!(matches!(ask(&question("q")), Err(SyncError::NotPaired(_))));
    assert!(matches!(ask("nope"), Err(SyncError::InvalidInput(_))));
    assert!(matches!(
        ask(r#"{"question":"Why?"}"#),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        ask(r#"{"requestId":"q","question":" "}"#),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(matches!(
        phone.client.queue_question("{}".into()),
        Err(SyncError::InvalidInput(_))
    ));
}

#[test]
fn records_published_while_connected_are_pushed() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = phone.client.open_live().unwrap();
    // A day after the fixture's newest.
    let date = days_after_latest(1);
    let day = json!({ "date": date, "timeline": { "trackedSeconds": 60, "sessions": [] }, "meetingIds": [] });
    assert!(
        host.server
            .publish("day".into(), date.clone(), day.to_string())
            .unwrap()
    );
    let seen = recv_until(&channel, &mut inbox, |m| {
        matches!(m, Message::Records { .. })
    });
    let Some(Message::Records {
        items,
        last_seq,
        done,
    }) = seen.last()
    else {
        panic!("expected records")
    };
    assert!(*done);
    assert_eq!(*last_seq, host.server.current_seq().unwrap());
    assert_eq!(items.len(), 1);
    assert_eq!(
        (items[0].kind.as_str(), items[0].key.as_str()),
        ("day", date.as_str())
    );
    assert_eq!(items[0].body, day);

    assert!(host.server.remove("day".into(), date).unwrap());
    let seen = recv_until(&channel, &mut inbox, |m| {
        matches!(m, Message::Records { .. })
    });
    let Some(Message::Records { items, .. }) = seen.last() else {
        panic!("expected records")
    };
    assert!(items[0].deleted);
    assert_eq!(items[0].version, 2);
}

#[test]
fn an_interrupted_catch_up_repeats_safely() {
    let host = Host::new();
    let mut tuning = fast_tuning();
    tuning.batch_bytes = 2048;
    host.server.set_tuning(tuning);
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = phone.client.open_session("sync", 0).unwrap();
    let seen = recv_until(&channel, &mut inbox, |m| {
        matches!(m, Message::Records { .. })
    });
    let Some(Message::Records { items, done, .. }) = seen.last() else {
        panic!("expected records")
    };
    assert!(!done, "a small batch size splits the catch-up");
    assert!(!items.is_empty() && items.len() < 19);
    phone.client.apply_batch(items, None).unwrap();
    // The connection drops before the catch-up finishes.
    channel.close();
    drop(inbox);
    assert_eq!(phone.client.status().unwrap().cursor, 0);

    let report = phone.client.sync(vec![]).unwrap();
    assert_eq!(report.cursor, host.server.current_seq().unwrap());
    assert_eq!(report.received as usize, 19 - items.len());
    assert_eq!(phone.client.meetings(None, None, 0).unwrap().len(), 6);
    assert_eq!(phone.client.days(0).unwrap().len(), 4);
    assert_eq!(phone.client.people().unwrap().len(), 4);
    assert!(
        phone
            .client
            .transcript(DESIGN_REVIEW.into())
            .unwrap()
            .is_some()
    );
}

#[test]
fn catch_up_is_newest_first_in_batches() {
    let host = Host::new();
    let mut tuning = fast_tuning();
    tuning.batch_bytes = 4096;
    host.server.set_tuning(tuning);
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = phone.client.open_session("sync", 0).unwrap();
    let seen = recv_until(&channel, &mut inbox, |m| {
        matches!(m, Message::Records { done: true, .. })
    });
    let items: Vec<&Envelope> = seen
        .iter()
        .flat_map(|m| match m {
            Message::Records { items, .. } => items.iter().collect(),
            _ => Vec::new(),
        })
        .collect();
    assert!(seen.len() > 2);
    assert_eq!(items.len(), 19);
    assert!(
        items
            .windows(2)
            .all(|pair| pair[0].sort_key >= pair[1].sort_key)
    );
    let position = |kind: &str| {
        items
            .iter()
            .position(|e| e.kind == kind && e.key == DESIGN_REVIEW)
            .unwrap()
    };
    assert!(position("meeting") < position("transcript"));
    // Every batch but the last is at most the batch size, unless it holds a
    // single larger record.
    for message in &seen[..seen.len() - 1] {
        if let Message::Records { items, done, .. } = message {
            assert!(!done);
            let size: usize = items
                .iter()
                .map(|e| serde_json::to_string(e).unwrap().len() + 1)
                .sum();
            assert!(size <= 4096 || items.len() == 1, "{size}");
        }
    }
}

#[test]
fn tombstones_reach_the_phone() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    phone.client.sync(vec![]).unwrap();
    assert!(
        host.server
            .remove("meeting".into(), DESIGN_REVIEW.into())
            .unwrap()
    );
    assert!(
        host.server
            .remove("transcript".into(), DESIGN_REVIEW.into())
            .unwrap()
    );
    let report = phone.client.sync(vec![]).unwrap();
    assert_eq!((report.received, report.deleted), (0, 2));
    assert!(
        phone
            .client
            .meeting(DESIGN_REVIEW.into())
            .unwrap()
            .is_none()
    );
    assert!(
        phone
            .client
            .transcript(DESIGN_REVIEW.into())
            .unwrap()
            .is_none()
    );
    assert_eq!(phone.client.meetings(None, None, 0).unwrap().len(), 5);
    assert!(
        phone
            .client
            .search("revised deck".into(), 10)
            .unwrap()
            .iter()
            .all(|hit| hit.meeting_id.as_deref() != Some(DESIGN_REVIEW))
    );
    assert!(
        phone
            .client
            .actions(Default::default())
            .unwrap()
            .iter()
            .all(|row| !row.contains(DECK))
    );
}

#[test]
fn a_newer_protocol_version_is_refused() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = phone.client.connect_raw().unwrap();
    channel
        .send(&Message::Hello {
            protocol_version: 2,
            schema_version: 1,
            device_id: phone.device_id.clone(),
            cursor: 0,
            purpose: "sync".into(),
        })
        .unwrap();
    let seen = recv_until(&channel, &mut inbox, |m| matches!(m, Message::Error { .. }));
    let Some(Message::Error { code, .. }) = seen.last() else {
        panic!("expected an error")
    };
    assert_eq!(code, "unsupported_version");
}

#[test]
fn quiet_connections_are_closed() {
    let host = Host::new();
    let mut tuning = fast_tuning();
    tuning.idle_timeout = Duration::from_millis(700);
    host.server.set_tuning(tuning);
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = phone.client.open_session("ask", 0).unwrap();
    // Read without ever sending: the Mac's pings arrive, then it gives up.
    let started = Instant::now();
    while inbox.poll(&channel).is_ok() {
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "the Mac kept the connection open"
        );
    }
    assert!(started.elapsed() >= Duration::from_millis(500));
}

#[test]
fn stopping_the_server_closes_sessions_and_it_can_start_again() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = phone.client.open_live().unwrap();
    wait_for(|| !host.server.connected_device_ids().is_empty());
    host.server.stop();
    assert!(!host.server.is_running());
    let tuning = fast_tuning();
    let deadline = Some(Instant::now() + Duration::from_secs(5));
    while inbox.recv(&channel, &tuning, deadline).is_ok() {}
    wait_for(|| host.server.connected_device_ids().is_empty());
    host.server.start().unwrap();
    assert!(host.server.is_running());
    let address = format!("127.0.0.1:{}", host.server.bound_port());
    assert_eq!(phone.client.sync(vec![address]).unwrap().received, 0);
}
