use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use parking_lot::Mutex;
use serde_json::json;
use sha2::{Digest, Sha256};

use super::{Host, Phone, fast_tuning};
use crate::keys;
use crate::messages::Message;
use crate::wire::{Channel, Inbox, PREFACE_SESSION, RawConn, session_handshake};
use crate::{RecordingInfo, SyncError, UploadListener, UploadOutcome};

#[derive(Default)]
struct Progress(Arc<Mutex<Vec<u64>>>);

impl UploadListener for Progress {
    fn on_progress(&self, _: String, sent_bytes: u64, _: u64) {
        self.0.lock().push(sent_bytes);
    }
}

fn quiet() -> Box<dyn UploadListener> {
    Box::new(Progress::default())
}

fn audio(length: usize) -> Vec<u8> {
    (0..length).map(|i| (i % 251) as u8).collect()
}

/// A finished recording on `phone`, as if a recorder wrote `bytes`.
fn recorded(phone: &Phone, bytes: &[u8]) -> RecordingInfo {
    let draft = phone
        .client
        .begin_recording(Some("Hallway chat".into()))
        .unwrap();
    assert_eq!(draft.state, "recording");
    std::fs::write(&draft.file_path, bytes).unwrap();
    phone.client.finish_recording(draft.id, 12.5).unwrap()
}

fn sha256(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn listed(phone: &Phone, id: &str) -> Option<RecordingInfo> {
    phone
        .client
        .recordings()
        .unwrap()
        .into_iter()
        .find(|r| r.id == id)
}

/// Partial files on the host.
fn partials(host: &Host) -> Vec<PathBuf> {
    let root = host.uploads_dir();
    let Ok(devices) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    devices
        .flatten()
        .flat_map(|device| {
            std::fs::read_dir(device.path())
                .into_iter()
                .flatten()
                .flatten()
        })
        .map(|file| file.path())
        .collect()
}

/// An upload session right after `welcome`.
fn upload_session(phone: &Phone) -> (Arc<Channel>, Inbox) {
    phone.client.open_session("upload", 0).unwrap()
}

/// Skips pings.
fn next(channel: &Channel, inbox: &mut Inbox) -> Message {
    loop {
        let message = inbox
            .recv(channel, &fast_tuning(), None)
            .expect("a message");
        if message != Message::Ping {
            return message;
        }
    }
}

fn begin(channel: &Channel, id: &str, bytes: &[u8]) {
    channel
        .send(&Message::UploadBegin {
            upload_id: id.into(),
            byte_count: bytes.len() as u64,
            sha256: sha256(bytes),
            recording: json!({ "format": "aac-adts", "startedAt": "2026-11-04T09:00:00.000Z" }),
        })
        .unwrap();
}

#[test]
fn a_recording_reaches_the_mac_and_leaves_the_phone() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let bytes = audio(5000);
    let recording = recorded(&phone, &bytes);
    assert_eq!(recording.state, "waiting");
    assert_eq!(recording.byte_count, 5000);

    let progress = Progress::default();
    let seen = Arc::clone(&progress.0);
    let report = phone
        .client
        .upload_recordings(Vec::new(), Box::new(progress))
        .unwrap();
    assert_eq!((report.uploaded, report.waiting, report.failed), (1, 0, 0));
    assert_eq!(seen.lock().last(), Some(&5000));
    assert!(seen.lock().len() >= 5, "1 KB chunks report as they go");

    let received = host.delegate.recordings.lock();
    let (description, data) = &received[0];
    assert_eq!(data, &bytes);
    assert_eq!(description["id"], recording.id.as_str());
    assert_eq!(description["title"], "Hallway chat");
    assert_eq!(description["format"], "aac-adts");
    assert_eq!(description["durationSeconds"], 12.5);
    assert_eq!(description["startedAt"], recording.started_at.as_str());
    assert_eq!(description["deviceId"], phone.device_id.as_str());
    assert_eq!(description["deviceName"], "Test iPad");
    assert_eq!(description["platform"], "ipados");
    drop(received);

    assert!(
        !std::path::Path::new(&recording.file_path).exists(),
        "the audio left the phone"
    );
    assert_eq!(listed(&phone, &recording.id).unwrap().state, "uploaded");
    assert!(partials(&host).is_empty(), "the Mac keeps no partial file");
}

#[test]
fn a_recording_stays_listed_until_its_meeting_arrives() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let recording = recorded(&phone, &audio(100));
    phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    assert!(listed(&phone, &recording.id).is_some());

    // The Mac publishes meeting keys in its own case.
    host.server
        .publish(
            "meeting".into(),
            recording.id.to_uppercase(),
            json!({ "id": recording.id, "title": "Hallway chat" }).to_string(),
        )
        .unwrap();
    phone.client.sync(Vec::new()).unwrap();
    assert!(listed(&phone, &recording.id).is_none());
}

#[test]
fn an_interrupted_upload_resumes_where_it_stopped() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let bytes = audio(5000);
    let recording = recorded(&phone, &bytes);

    let (channel, mut inbox) = upload_session(&phone);
    begin(&channel, &recording.id, &bytes);
    assert!(matches!(
        next(&channel, &mut inbox),
        Message::UploadReady { offset: 0, .. }
    ));
    channel
        .send(&Message::UploadChunk {
            upload_id: recording.id.clone(),
            offset: 0,
            data: STANDARD.encode(&bytes[..2000]),
        })
        .unwrap();
    assert!(matches!(
        next(&channel, &mut inbox),
        Message::UploadAck { offset: 2000, .. }
    ));
    channel.close();

    // The Mac notices the connection is gone and lets go of the upload.
    let (channel, inbox) = loop {
        let (channel, mut inbox) = upload_session(&phone);
        begin(&channel, &recording.id, &bytes);
        match next(&channel, &mut inbox) {
            Message::UploadReady { offset, .. } => {
                assert_eq!(offset, 2000, "only the rest is sent");
                break (channel, inbox);
            }
            Message::UploadDone { status, .. } => assert_eq!(status, "deferred"),
            other => panic!("unexpected {other:?}"),
        }
        channel.close();
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    channel.close();
    drop(inbox);

    // The app's own pass finishes it. It retries while the session above lets go.
    let mut report = phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    for _ in 0..100 {
        if report.uploaded == 1 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
        report = phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    }
    assert_eq!(report.uploaded, 1);
    assert_eq!(host.delegate.recordings.lock()[0].1, bytes);
}

#[test]
fn a_lost_confirmation_does_not_make_a_second_meeting() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let recording = recorded(&phone, &audio(100));
    let bytes = audio(100);
    phone.client.upload_recordings(Vec::new(), quiet()).unwrap();

    // As if the phone never heard the answer and asked again.
    let (channel, mut inbox) = upload_session(&phone);
    begin(&channel, &recording.id, &bytes);
    match next(&channel, &mut inbox) {
        Message::UploadDone {
            status, meeting_id, ..
        } => {
            assert_eq!(status, "accepted");
            assert_eq!(meeting_id.as_deref(), Some(recording.id.as_str()));
        }
        other => panic!("unexpected {other:?}"),
    }
    assert_eq!(host.delegate.recordings.lock().len(), 1);
}

#[test]
fn a_mac_that_is_not_accepting_gets_no_audio() {
    let host = Host::empty();
    host.delegate
        .accepts_recordings
        .store(false, Ordering::SeqCst);
    let phone = Phone::paired(&host);
    let recording = recorded(&phone, &audio(100));

    let report = phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    assert_eq!((report.uploaded, report.waiting), (0, 1));
    let row = listed(&phone, &recording.id).unwrap();
    assert_eq!(row.state, "waiting");
    assert!(row.message.unwrap().contains("Accept recordings"));
    assert!(partials(&host).is_empty());
    assert!(std::path::Path::new(&recording.file_path).exists());

    host.delegate
        .accepts_recordings
        .store(true, Ordering::SeqCst);
    assert_eq!(
        phone
            .client
            .upload_recordings(Vec::new(), quiet())
            .unwrap()
            .uploaded,
        1
    );
}

#[test]
fn a_recording_the_mac_cannot_use_is_kept_until_the_person_decides() {
    let host = Host::empty();
    host.delegate.on_recording(|_, _| UploadOutcome {
        status: "rejected".into(),
        meeting_id: None,
        message: Some("It has no audio to transcribe.".into()),
    });
    let phone = Phone::paired(&host);
    let recording = recorded(&phone, &audio(100));

    let report = phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    assert_eq!((report.uploaded, report.waiting, report.failed), (0, 0, 1));
    let row = listed(&phone, &recording.id).unwrap();
    assert_eq!(row.state, "failed");
    assert_eq!(
        row.message.as_deref(),
        Some("It has no audio to transcribe.")
    );
    assert!(std::path::Path::new(&recording.file_path).exists());
    assert!(partials(&host).is_empty());
    // Failed recordings aren't sent again on their own.
    phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    assert_eq!(host.delegate.recordings.lock().len(), 1);

    phone.client.retry_recording(recording.id.clone()).unwrap();
    assert_eq!(listed(&phone, &recording.id).unwrap().state, "waiting");
    phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    assert_eq!(host.delegate.recordings.lock().len(), 2);

    phone
        .client
        .discard_recording(recording.id.clone())
        .unwrap();
    assert!(listed(&phone, &recording.id).is_none());
    assert!(!std::path::Path::new(&recording.file_path).exists());
}

#[test]
fn a_mac_that_defers_after_receiving_needs_no_audio_again() {
    let host = Host::empty();
    let calls = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&calls);
    host.delegate.on_recording(move |recording, _| {
        if counted.fetch_add(1, Ordering::SeqCst) == 0 {
            UploadOutcome {
                status: "deferred".into(),
                meeting_id: None,
                message: Some("The disk is full.".into()),
            }
        } else {
            UploadOutcome {
                status: "accepted".into(),
                meeting_id: recording["id"].as_str().map(str::to_owned),
                message: None,
            }
        }
    });
    let phone = Phone::paired(&host);
    let recording = recorded(&phone, &audio(3000));
    phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    assert_eq!(
        listed(&phone, &recording.id).unwrap().message.as_deref(),
        Some("The disk is full.")
    );
    assert_eq!(partials(&host).len(), 1, "whole and checked, so it stays");

    let progress = Progress::default();
    let seen = Arc::clone(&progress.0);
    let report = phone
        .client
        .upload_recordings(Vec::new(), Box::new(progress))
        .unwrap();
    assert_eq!(report.uploaded, 1);
    assert!(seen.lock().is_empty(), "no chunk was sent again");
}

#[test]
fn damage_on_the_way_is_caught_and_starts_over() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let bytes = audio(100);
    let recording = recorded(&phone, &bytes);

    let (channel, mut inbox) = upload_session(&phone);
    begin(&channel, &recording.id, &bytes);
    next(&channel, &mut inbox);
    let mut damaged = bytes.clone();
    damaged[50] ^= 0xFF;
    channel
        .send(&Message::UploadChunk {
            upload_id: recording.id.clone(),
            offset: 0,
            data: STANDARD.encode(&damaged),
        })
        .unwrap();
    next(&channel, &mut inbox);
    channel
        .send(&Message::UploadFinish {
            upload_id: recording.id.clone(),
        })
        .unwrap();
    match next(&channel, &mut inbox) {
        Message::UploadDone { status, .. } => assert_eq!(status, "deferred"),
        other => panic!("unexpected {other:?}"),
    }
    assert!(
        host.delegate.recordings.lock().is_empty(),
        "the Mac never saw it"
    );
    assert!(partials(&host).is_empty());
}

#[test]
fn an_upload_id_cannot_name_a_path_or_a_second_writer() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = upload_session(&phone);
    begin(&channel, "../../../evil", b"x");
    match next(&channel, &mut inbox) {
        Message::UploadDone { status, .. } => assert_eq!(status, "rejected"),
        other => panic!("unexpected {other:?}"),
    }
    assert!(partials(&host).is_empty());

    // One id, two connections: the second is told to come back.
    let id = uuid::Uuid::new_v4().to_string();
    begin(&channel, &id, b"xyz");
    assert!(matches!(
        next(&channel, &mut inbox),
        Message::UploadReady { .. }
    ));
    let (other, mut other_inbox) = upload_session(&phone);
    begin(&other, &id, b"xyz");
    match next(&other, &mut other_inbox) {
        Message::UploadDone { status, .. } => assert_eq!(status, "deferred"),
        message => panic!("unexpected {message:?}"),
    }
}

#[test]
fn a_chunk_for_the_wrong_position_moves_the_phone_back() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let bytes = audio(100);
    let recording = recorded(&phone, &bytes);
    let (channel, mut inbox) = upload_session(&phone);
    begin(&channel, &recording.id, &bytes);
    next(&channel, &mut inbox);
    channel
        .send(&Message::UploadChunk {
            upload_id: recording.id.clone(),
            offset: 40,
            data: STANDARD.encode(&bytes[40..50]),
        })
        .unwrap();
    assert!(matches!(
        next(&channel, &mut inbox),
        Message::UploadReady { offset: 0, .. }
    ));
    // Finishing early just says where things stand.
    channel
        .send(&Message::UploadFinish {
            upload_id: recording.id.clone(),
        })
        .unwrap();
    assert!(matches!(
        next(&channel, &mut inbox),
        Message::UploadReady { offset: 0, .. }
    ));
}

#[test]
fn only_an_upload_session_takes_recordings() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let (channel, _inbox) = phone.client.open_session("sync", 0).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    begin(&channel, &id, b"xyz");
    std::thread::sleep(std::time::Duration::from_millis(100));
    assert!(partials(&host).is_empty());
}

#[test]
fn an_app_that_died_recording_keeps_what_was_written() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let written = phone.client.begin_recording(None).unwrap();
    std::fs::write(&written.file_path, audio(100)).unwrap();
    let empty = phone.client.begin_recording(None).unwrap();

    assert_eq!(phone.client.recover_recordings().unwrap(), 1);
    let row = listed(&phone, &written.id).unwrap();
    assert_eq!(
        (row.state.as_str(), row.byte_count, row.duration_seconds),
        ("waiting", 100, None)
    );
    assert!(listed(&phone, &empty.id).is_none());
    assert_eq!(
        phone
            .client
            .upload_recordings(Vec::new(), quiet())
            .unwrap()
            .uploaded,
        1
    );
    assert!(host.delegate.recordings.lock()[0].0.get("title").is_none());
}

#[test]
fn stopping_with_nothing_written_leaves_no_recording() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let draft = phone.client.begin_recording(None).unwrap();
    assert!(matches!(
        phone.client.finish_recording(draft.id.clone(), 3.0),
        Err(SyncError::InvalidInput(_))
    ));
    assert!(listed(&phone, &draft.id).is_none());
}

#[test]
fn recording_needs_a_paired_mac() {
    assert!(matches!(
        Phone::new().client.begin_recording(None),
        Err(SyncError::NotPaired(_))
    ));
    assert!(matches!(
        Phone::sample().client.begin_recording(None),
        Err(SyncError::NotPaired(_))
    ));
}

#[test]
fn pairing_again_keeps_recordings_but_removing_the_device_erases_them() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let recording = recorded(&phone, &audio(100));

    phone.client.pair(host.offer()).unwrap();
    assert_eq!(listed(&phone, &recording.id).unwrap().state, "waiting");
    assert!(std::path::Path::new(&recording.file_path).exists());

    phone.client.unpair().unwrap();
    assert!(phone.client.recordings().unwrap().is_empty());
    assert!(!std::path::Path::new(&recording.file_path).exists());
}

/// Removing a device is often how someone starts pairing it again, and these
/// exist nowhere else.
#[test]
fn a_revoked_device_keeps_what_has_not_arrived_until_it_pairs_again() {
    let host = Host::new();
    let phone = Phone::paired(&host);
    phone.client.sync(Vec::new()).unwrap();
    let bytes = audio(100);
    let recording = recorded(&phone, &bytes);

    let (channel, mut inbox) = upload_session(&phone);
    begin(&channel, &recording.id, &bytes);
    next(&channel, &mut inbox);
    assert_eq!(partials(&host).len(), 1);
    host.server.remove_device(phone.device_id.clone()).unwrap();
    assert!(partials(&host).is_empty(), "the Mac drops its partial file");
    channel.close();

    assert!(matches!(
        phone.client.upload_recordings(Vec::new(), quiet()),
        Err(SyncError::Revoked(_))
    ));
    assert!(
        phone.client.manifest().unwrap().is_none(),
        "the library goes"
    );
    assert!(phone.client.paired_mac().unwrap().is_none());
    let kept = listed(&phone, &recording.id).unwrap();
    assert_eq!(kept.state, "waiting");
    assert!(std::path::Path::new(&recording.file_path).exists());

    // Closing a sample library leaves them too; only a removal by the person does not.
    phone.client.unpair().unwrap();
    assert!(listed(&phone, &recording.id).is_some());
    assert!(matches!(
        phone.client.begin_recording(None),
        Err(SyncError::NotPaired(_))
    ));

    phone.client.pair(host.offer()).unwrap();
    assert_eq!(
        phone
            .client
            .upload_recordings(Vec::new(), quiet())
            .unwrap()
            .uploaded,
        1
    );
    assert_eq!(host.delegate.recordings.lock()[0].1, bytes);
}

struct DeleteOnFirstChunk {
    client: Arc<crate::SyncClient>,
    deleted: std::sync::atomic::AtomicBool,
}

impl UploadListener for DeleteOnFirstChunk {
    fn on_progress(&self, recording_id: String, _: u64, _: u64) {
        if !self.deleted.swap(true, Ordering::SeqCst) {
            self.client.discard_recording(recording_id).unwrap();
        }
    }
}

#[test]
fn a_recording_deleted_on_the_way_never_becomes_a_meeting() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let recording = recorded(&phone, &audio(5000));
    let report = phone
        .client
        .upload_recordings(
            Vec::new(),
            Box::new(DeleteOnFirstChunk {
                client: Arc::clone(&phone.client),
                deleted: std::sync::atomic::AtomicBool::new(false),
            }),
        )
        .unwrap();
    assert_eq!((report.uploaded, report.waiting), (0, 0));
    assert!(listed(&phone, &recording.id).is_none());
    std::thread::sleep(std::time::Duration::from_millis(100));
    assert!(host.delegate.recordings.lock().is_empty());
}

#[test]
fn one_device_cannot_pile_up_unfinished_files() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let (channel, mut inbox) = upload_session(&phone);
    let mut refused = None;
    for _ in 0..20 {
        begin(&channel, &uuid::Uuid::new_v4().to_string(), b"xyz");
        if let Message::UploadDone {
            status, message, ..
        } = next(&channel, &mut inbox)
        {
            refused = Some((status, message));
            break;
        }
    }
    let (status, message) = refused.expect("a limit");
    assert_eq!(status, "deferred");
    assert!(message.unwrap().contains("too many unfinished"));
    assert_eq!(partials(&host).len(), 16);
}

#[test]
fn nothing_waiting_means_no_connection() {
    let phone = Phone::new();
    let report = phone.client.upload_recordings(Vec::new(), quiet()).unwrap();
    assert_eq!((report.uploaded, report.waiting, report.failed), (0, 0, 0));
}

#[test]
fn a_mac_that_is_away_leaves_recordings_waiting() {
    let host = Host::empty();
    let phone = Phone::paired(&host);
    let recording = recorded(&phone, &audio(100));
    host.server.stop();
    assert!(matches!(
        phone.client.upload_recordings(Vec::new(), quiet()),
        Err(SyncError::Unreachable(_))
    ));
    assert_eq!(listed(&phone, &recording.id).unwrap().state, "waiting");
}

/// A Mac from before uploads existed, which refuses the session's purpose.
#[test]
fn a_mac_too_old_for_recordings_leaves_them_waiting_and_says_why() {
    let key = crate::generate_static_key();
    let private_key = keys::key_array(&key.private_key, "test key").unwrap();
    let public_key = keys::key_array(&key.public_key, "test key").unwrap();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let old_mac = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let tuning = fast_tuning();
        let mut conn = RawConn::new(stream, &tuning).unwrap();
        assert_eq!(conn.recv_packet().unwrap(), vec![PREFACE_SESSION]);
        let mut handshake = session_handshake(&private_key, None).unwrap();
        conn.read_handshake(&mut handshake).unwrap();
        conn.write_handshake(&mut handshake).unwrap();
        let (channel, mut inbox) = conn
            .into_channel(handshake.into_transport_mode().unwrap())
            .unwrap();
        assert!(matches!(
            inbox.recv(&channel, &tuning, None).unwrap(),
            Message::Hello { purpose, .. } if purpose == "upload"
        ));
        channel
            .send(&Message::Welcome {
                mac_name: "Old Mac".into(),
                server_time: crate::records::now_iso(),
                manifest: None,
            })
            .unwrap();
        channel
            .send(&Message::Error {
                code: "unsupported_purpose".into(),
                message: "Unknown session purpose \"upload\".".into(),
            })
            .unwrap();
        // Holds the connection until the phone has read that.
        while inbox.recv(&channel, &tuning, None).is_ok() {}
    });

    let phone = Phone::new();
    phone.client.pair_with_key(&public_key, port).unwrap();
    let recording = recorded(&phone, &audio(100));
    let error = phone
        .client
        .upload_recordings(Vec::new(), quiet())
        .unwrap_err();
    assert!(matches!(error, SyncError::Protocol(_)));
    old_mac.join().unwrap();

    let row = listed(&phone, &recording.id).unwrap();
    assert_eq!(row.state, "waiting");
    assert!(row.message.unwrap().contains("Update LokalBot"));
    assert!(std::path::Path::new(&recording.file_path).exists());
}
