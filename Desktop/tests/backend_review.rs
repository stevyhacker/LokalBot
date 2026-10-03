#![allow(clippy::field_reassign_with_default)]
use lokalbot_desktop::{
    audio::{self, ChunkWriter},
    domain::*,
    privacy, services,
    storage::{Library, valid_id},
};
use rusqlite::{Connection, params};
use std::{
    fs,
    io::{Read, Write},
    net::TcpListener,
    process::Command,
    time::{Duration, Instant},
};

fn library() -> (tempfile::TempDir, Library) {
    let directory = tempfile::tempdir().unwrap();
    let library = Library::open(directory.path()).unwrap();
    (directory, library)
}
fn moment(id: String, at: i64) -> Moment {
    Moment {
        id,
        app: "Editor".into(),
        title: "Synthetic work".into(),
        text: "synthetic evidence".into(),
        created_at: at,
        saved: false,
        pixels: None,
    }
}

#[test]
fn retention_reaches_rows_beyond_both_display_limits_and_removes_pixels() {
    let (directory, mut lib) = library();
    let at = now();
    let mut db = Connection::open(directory.path().join("desktop.sqlite")).unwrap();
    let tx = db.transaction().unwrap();
    fs::create_dir(directory.path().join("pixels")).unwrap();
    for i in 0..2202 {
        let expired = i < 1201;
        let mut m = moment(
            format!("moment-{i}"),
            if expired { at - 20 * 86400 } else { at },
        );
        m.pixels = Some(format!("pixels/{}.enc", m.id));
        fs::write(
            directory.path().join(m.pixels.as_ref().unwrap()),
            b"synthetic encrypted fixture",
        )
        .unwrap();
        tx.execute(
            "INSERT INTO moments VALUES(?1,?2,0,?3)",
            params![m.id, m.created_at, serde_json::to_string(&m).unwrap()],
        )
        .unwrap();
        tx.execute("INSERT INTO evidence(id,meeting_id,title,kind,start,text) VALUES(?1,NULL,'Synthetic','screen',0,?2)",params![m.id,if expired{"expiredneedle"}else{"currentneedle"}]).unwrap();
    }
    for i in 0..4004 {
        let start = if i < 2002 { at - 20 * 86400 } else { at };
        let a = Activity {
            id: format!("activity-{i}"),
            app: "Editor".into(),
            title: "Synthetic title".into(),
            start,
            end: start + 5,
            private: false,
        };
        tx.execute(
            "INSERT INTO activity VALUES(?1,?2,?3,?4)",
            params![a.id, a.start, a.end, serde_json::to_string(&a).unwrap()],
        )
        .unwrap();
    }
    tx.commit().unwrap();
    assert_eq!(lib.moments().unwrap().len(), 1000);
    assert_eq!(lib.activity().unwrap().len(), 2000);
    assert_eq!(lib.expire(at).unwrap(), 1201);
    assert!(lib.search("expiredneedle", 10).unwrap().is_empty());
    assert_eq!(
        fs::read_dir(directory.path().join("pixels"))
            .unwrap()
            .count(),
        1001
    );
    let titles: i64 = db
        .query_row(
            "SELECT count(*) FROM activity WHERE end<?1 AND json_extract(data,'$.title')<>''",
            [at - 14 * 86400],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(titles, 0);
    assert_eq!(lib.expire(at).unwrap(), 0);
    let durations: i64 = db
        .query_row("SELECT sum(end-start) FROM activity", [], |r| r.get(0))
        .unwrap();
    assert_eq!(durations, 4004 * 5);
}

#[test]
fn digest_includes_the_full_day_even_when_newer_rows_fill_the_display_lists() {
    let (directory, mut lib) = library();
    let day = "2026-09-20";
    let (start, end) = services::day_bounds(day).unwrap();
    let m = moment("early-moment".into(), start + 10);
    lib.save_moment(&m).unwrap();
    let a = Activity {
        id: "early-activity".into(),
        app: "Editor".into(),
        title: "Synthetic morning work".into(),
        start: start + 20,
        end: start + 25,
        private: false,
    };
    lib.save_activity(&a).unwrap();
    let mut db = Connection::open(directory.path().join("desktop.sqlite")).unwrap();
    let tx = db.transaction().unwrap();
    for i in 0..2100 {
        let m = moment(format!("later-{i}"), end + 100 + i);
        tx.execute(
            "INSERT INTO moments VALUES(?1,?2,0,?3)",
            params![m.id, m.created_at, serde_json::to_string(&m).unwrap()],
        )
        .unwrap();
        let a = Activity {
            id: format!("later-activity-{i}"),
            start: m.created_at,
            end: m.created_at + 5,
            ..a.clone()
        };
        tx.execute(
            "INSERT INTO activity VALUES(?1,?2,?3,?4)",
            params![a.id, a.start, a.end, serde_json::to_string(&a).unwrap()],
        )
        .unwrap();
    }
    tx.commit().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    // Bounded accept also makes this regression fail promptly with the old code,
    // which incorrectly reports "No evidence" before issuing a request.
    listener.set_nonblocking(true).unwrap();
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut stream = loop {
            if let Ok((stream, _)) = listener.accept() {
                break stream;
            }
            assert!(
                Instant::now() < deadline,
                "Digest never requested its early-day evidence"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut header = vec![];
        while !header.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            header.push(byte[0]);
        }
        let header = String::from_utf8(header).unwrap();
        let length: usize = header
            .lines()
            .find_map(|line| {
                line.to_ascii_lowercase()
                    .strip_prefix("content-length:")
                    .map(|value| value.trim().parse().unwrap())
            })
            .unwrap();
        let mut body = vec![0; length];
        stream.read_exact(&mut body).unwrap();
        let body = String::from_utf8(body).unwrap();
        assert!(body.contains("early-moment") && body.contains("early-activity"));
        assert!(!body.contains("later-activity"));
        let response = r#"{"choices":[{"finish_reason":"stop","message":{"content":"Synthetic full-day digest"}}]}"#;
        write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}",response.len(),response).unwrap();
    });
    let mut settings = lib.settings().unwrap();
    settings.endpoint = format!("http://{address}/v1");
    settings.screen_text_enabled = true;
    lib.save_settings(&mut settings).unwrap();
    let digest = services::digest(&lib, day).unwrap();
    assert_eq!(digest.sources, vec!["early-moment", "early-activity"]);
    server.join().unwrap();
}

#[test]
fn action_edits_keep_transcript_rowids_embeddings_and_only_update_one_evidence_row() {
    let (directory, mut lib) = library();
    let mut meeting = Meeting::empty("Long synthetic meeting");
    for i in 0..2000 {
        meeting.segments.push(Segment {
            id: format!("segment-{i}"),
            start: i as f64,
            end: i as f64 + 1.,
            speaker: "Alex".into(),
            text: "synthetic transcript".into(),
        });
    }
    let action = Action {
        id: "action-1".into(),
        text: "Review fixtures".into(),
        owner: "Alex".into(),
        due: "".into(),
        source: meeting.segments[0].id.clone(),
        done: false,
        corrected: false,
    };
    meeting.summary = Some(Summary {
        overview: "Synthetic summary".into(),
        actions: vec![action],
        ..Default::default()
    });
    lib.save_meeting(&meeting).unwrap();
    lib.save_embedding("segment-0", "test", &[1., 0.]).unwrap();
    let db = Connection::open(directory.path().join("desktop.sqlite")).unwrap();
    db.execute_batch("CREATE TABLE evidence_writes(kind TEXT); CREATE TRIGGER count_evidence_delete AFTER DELETE ON evidence BEGIN INSERT INTO evidence_writes VALUES('delete'); END; CREATE TRIGGER count_evidence_insert AFTER INSERT ON evidence BEGIN INSERT INTO evidence_writes VALUES('insert'); END; CREATE TRIGGER count_evidence_update AFTER UPDATE ON evidence BEGIN INSERT INTO evidence_writes VALUES('update'); END;").unwrap();
    let original: i64 = db
        .query_row("SELECT rowid FROM evidence WHERE id='segment-0'", [], |r| {
            r.get(0)
        })
        .unwrap();
    lib.toggle_action(&meeting.id, "action-1").unwrap();
    let writes: i64 = db
        .query_row("SELECT count(*) FROM evidence_writes", [], |r| r.get(0))
        .unwrap();
    assert_eq!(writes, 1);
    assert_eq!(
        db.query_row("SELECT rowid FROM evidence WHERE id='segment-0'", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        original
    );
    assert_eq!(lib.semantic_search(&[1., 0.], "test", 1).unwrap().len(), 1);
    let triggers: String = db
        .query_row(
            "SELECT sql FROM sqlite_master WHERE name='evidence_delete'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(triggers.contains("rowid=old.rowid"));
    assert!(lib.meeting_previews().unwrap()[0].segments.is_empty());
}

#[test]
fn stale_settings_cannot_restore_a_cli_revocation() {
    let (directory, mut gui) = library();
    let mut settings = gui.settings().unwrap();
    settings.meeting_access = true;
    settings.screen_access = true;
    settings.agent_enabled = true;
    gui.save_settings(&mut settings).unwrap();
    let mut stale = settings.clone();
    let mut cli = Library::open(directory.path()).unwrap();
    settings.meeting_access = false;
    settings.screen_access = false;
    settings.agent_enabled = false;
    cli.save_settings(&mut settings).unwrap();
    stale.retention_days = 30;
    assert!(gui.save_settings(&mut stale).is_err());
    let current = gui.settings().unwrap();
    assert!(!current.meeting_access && !current.screen_access && !current.agent_enabled);
    assert_eq!(current.revision, settings.revision);
    assert_eq!(stale.revision, settings.revision - 1);
}

#[test]
fn drive_relative_and_windows_device_ids_are_rejected_on_all_platforms() {
    let (_, mut lib) = library();
    for id in [
        "C:Users",
        "C:",
        "c:folder",
        "NUL",
        "con",
        "COM1",
        "LPT9",
        "../outside",
        "..\\outside",
        "/absolute",
    ] {
        assert!(valid_id(id).is_err(), "Accepted {id}");
        assert!(lib.delete_meeting(id).is_err());
        assert!(lib.delete_moment(id).is_err());
    }
    assert!(valid_id("meeting-123_abc").is_ok());
}

#[test]
fn browser_exclusions_do_not_depend_on_the_helpers_browser_flag() {
    let mut settings = Settings::default();
    settings.screen_text_enabled = true;
    settings.excluded_domains = vec!["private.test".into()];
    for app in [
        "Vivaldi",
        "Opera",
        "LibreWolf",
        "Zen",
        "Chromium",
        "Brave",
        "Microsoft Edge",
        "Firefox",
    ] {
        let observation = privacy::Observation {
            app: app.into(),
            title: "Synthetic site".into(),
            window: "1".into(),
            pid: 1,
            field: Some("field".into()),
            focus_verified: true,
            secure: Some(false),
            domain: None,
            browser: false,
        };
        assert!(
            !privacy::allow_screen(&observation, &settings),
            "Captured {app}"
        );
    }
}

#[test]
fn crashed_capture_files_are_removed_without_touching_other_files() {
    let (directory, mut lib) = library();
    let leftover = directory.path().join(".tmp-legacy");
    fs::create_dir(&leftover).unwrap();
    fs::write(leftover.join("capture.png"), b"synthetic plaintext").unwrap();
    fs::write(directory.path().join("owner-export.png"), b"export").unwrap();
    fs::create_dir(directory.path().join("pixels")).unwrap();
    fs::write(directory.path().join("pixels/orphan.enc"), b"orphan").unwrap();
    let mut m = moment("saved".into(), now());
    m.saved = true;
    m.pixels = Some("pixels/saved.enc".into());
    lib.save_moment(&m).unwrap();
    fs::write(directory.path().join("pixels/saved.enc"), b"retained").unwrap();
    assert_eq!(lib.cleanup_capture_files().unwrap(), 2);
    assert!(!leftover.exists());
    assert!(!directory.path().join("pixels/orphan.enc").exists());
    assert!(directory.path().join("pixels/saved.enc").exists());
    assert!(directory.path().join("owner-export.png").exists());
}

#[test]
fn unchanged_capture_is_throttled_and_activity_samples_are_coalesced() {
    let (_, mut lib) = library();
    let at = now();
    lib.save_moment(&moment("first".into(), at)).unwrap();
    assert_eq!(
        lib.duplicate_capture("Editor", "Synthetic work", "synthetic evidence", at + 5)
            .unwrap(),
        Some("first".into())
    );
    assert!(
        lib.duplicate_capture("Editor", "Synthetic work", "changed", at + 5)
            .unwrap()
            .is_none()
    );
    assert!(
        lib.duplicate_capture("Editor", "Synthetic work", "synthetic evidence", at + 300)
            .unwrap()
            .is_none()
    );
    for i in 0..20 {
        lib.save_activity_sample(&Activity {
            id: new_id(),
            app: "Editor".into(),
            title: "Synthetic work".into(),
            start: at + i * 5,
            end: at + (i + 1) * 5,
            private: false,
        })
        .unwrap();
    }
    let activity = lib.activity().unwrap();
    assert_eq!(activity.len(), 1);
    assert_eq!(activity[0].end - activity[0].start, 100);
}

#[test]
fn one_missing_audio_piece_does_not_prevent_other_recordings_from_recovering() {
    let (directory, mut lib) = library();
    let mut ids = vec![];
    for i in 0..2 {
        let meeting = Meeting::empty(format!("Synthetic recovery {i}"));
        lib.save_meeting(&meeting).unwrap();
        let chunks = directory
            .path()
            .join("meetings")
            .join(&meeting.id)
            .join("mic-chunks");
        let mut writer = ChunkWriter::new(&chunks, 16000).unwrap();
        writer.append(&vec![7; 65000]).unwrap();
        drop(writer);
        if i == 0 {
            fs::remove_file(chunks.join("000000.wav")).unwrap();
        }
        ids.push(meeting.id);
    }
    let recovered = audio::recover_recordings(&mut lib).unwrap();
    assert_eq!(recovered, vec![ids[1].clone()]);
    assert!(
        lib.meeting(&ids[0])
            .unwrap()
            .warnings
            .iter()
            .any(|w| w.contains("Audio recovery failed"))
    );
    assert!(
        directory
            .path()
            .join("meetings")
            .join(&ids[0])
            .join("mic-chunks/manifest.json")
            .exists()
    );
    assert!(
        !directory
            .path()
            .join("meetings")
            .join(&ids[1])
            .join("mic-chunks")
            .exists()
    );
    assert_eq!(lib.meeting(&ids[1]).unwrap().duration, 4.);
    audio::recover_recordings(&mut lib).unwrap();
    assert_eq!(lib.jobs().unwrap().len(), 1);
}

#[test]
fn interrupted_job_recovery_is_not_capped_by_history() {
    let (_, lib) = library();
    for i in 0..120 {
        lib.save_job(&Job {
            id: format!("job-{i}"),
            meeting_id: None,
            kind: "synthetic".into(),
            status: if i == 0 { "running" } else { "complete" }.into(),
            error: None,
            updated_at: now(),
        })
        .unwrap();
    }
    assert_eq!(lib.recover_jobs().unwrap(), 1);
}

#[test]
fn retranscription_preserves_reviewed_actions_and_their_exact_original_sources() {
    let (_, mut lib) = library();
    let mut meeting = Meeting::empty("Synthetic reviewed meeting");
    let old = Segment {
        id: "old-source".into(),
        start: 0.,
        end: 10.,
        speaker: "Alex".into(),
        text: "I will review Linux on Monday".into(),
    };
    meeting.segments = vec![old.clone()];
    let action = Action {
        id: "reviewed-action".into(),
        text: "Reviewed correction".into(),
        owner: "Maya".into(),
        due: "Tuesday".into(),
        source: old.id.clone(),
        done: true,
        corrected: true,
    };
    let summary = Summary {
        overview: "Existing notes".into(),
        actions: vec![action],
        ..Default::default()
    };
    meeting.summary = Some(summary.clone());
    lib.save_meeting(&meeting).unwrap();
    meeting.replace_transcript(vec![Segment {
        id: "new-source".into(),
        text: "A different ASR passage".into(),
        ..old.clone()
    }]);
    lib.save_meeting(&meeting).unwrap();
    let current = lib.meeting(&meeting.id).unwrap();
    assert_eq!(current.summary, Some(summary));
    assert_eq!(current.retained_segments, vec![old]);
    assert!(lib.evidence("old-source").unwrap().text.contains("Monday"));
    assert!(
        lib.evidence("new-source")
            .unwrap()
            .text
            .contains("different")
    );
}

#[test]
fn schema_v2_upgrade_preserves_sources_and_rebuilds_fts_rowid_lookup() {
    let directory = tempfile::tempdir().unwrap();
    let db = Connection::open(directory.path().join("desktop.sqlite")).unwrap();
    db.execute_batch("CREATE TABLE meetings(id TEXT PRIMARY KEY,title TEXT NOT NULL,started_at INTEGER NOT NULL,data TEXT NOT NULL);
        CREATE TABLE evidence(id TEXT PRIMARY KEY,meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,title TEXT NOT NULL,kind TEXT NOT NULL,start REAL NOT NULL,text TEXT NOT NULL);
        CREATE VIRTUAL TABLE evidence_fts USING fts5(id UNINDEXED,title,text,tokenize='unicode61');
        CREATE TRIGGER evidence_delete AFTER DELETE ON evidence BEGIN DELETE FROM evidence_fts WHERE id=old.id; END;
        PRAGMA user_version=2;").unwrap();
    let mut meeting = Meeting::empty("Old synthetic library");
    meeting.segments = vec![Segment {
        id: "old-segment".into(),
        start: 0.,
        end: 2.,
        speaker: "Alex".into(),
        text: "upgradecanary".into(),
    }];
    db.execute(
        "INSERT INTO meetings VALUES(?1,?2,?3,?4)",
        params![
            meeting.id,
            meeting.title,
            meeting.started_at,
            serde_json::to_string(&meeting).unwrap()
        ],
    )
    .unwrap();
    db.execute(
        "INSERT INTO evidence VALUES('old-segment',?1,'Old','transcript',0,'upgradecanary')",
        [&meeting.id],
    )
    .unwrap();
    db.execute("INSERT INTO evidence_fts(rowid,id,title,text) VALUES(42,'old-segment','Old','upgradecanary')",[]).unwrap();
    let mut lib = Library::open(directory.path()).unwrap();
    assert_eq!(lib.search("upgradecanary", 10).unwrap().len(), 1);
    assert_eq!(lib.meeting(&meeting.id).unwrap(), meeting);
    let rowids: (i64, i64) = db
        .query_row(
            "SELECT e.rowid,f.rowid FROM evidence e JOIN evidence_fts f ON e.id=f.id",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!(rowids.0, rowids.1);
    lib.delete_meeting(&meeting.id).unwrap();
    assert!(lib.search("upgradecanary", 10).unwrap().is_empty());
    drop(lib);
    Library::open(directory.path()).unwrap();
}

#[test]
fn long_audio_parts_preserve_all_samples_and_global_timestamps() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("long.wav");
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: 48000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(&path, spec).unwrap();
    let count = 14_000_013usize;
    for i in 0..count {
        writer.write_sample((i % 173) as i16).unwrap();
    }
    writer.finalize().unwrap();
    assert!(fs::metadata(&path).unwrap().len() > 25 * 1024 * 1024);
    let parts = audio::remote_audio_parts(&path).unwrap();
    assert!(parts.parts.len() > 1);
    let mut total = 0usize;
    for part in &parts.parts {
        assert!(fs::metadata(&part.path).unwrap().len() <= 20 * 1024 * 1024);
        assert!((part.offset - total as f64 / 48000.).abs() < 0.000001);
        let mut reader = hound::WavReader::open(&part.path).unwrap();
        for sample in reader.samples::<i16>() {
            assert_eq!(sample.unwrap(), (total % 173) as i16);
            total += 1;
        }
        let rows = lokalbot_desktop::inference::transcription_segments(
            &serde_json::json!({"text":"synthetic speech"}),
            part.offset,
            part.duration,
        )
        .unwrap();
        assert_eq!(rows[0].start, part.offset);
        assert!((rows[0].end - part.offset - part.duration).abs() < 0.000001);
    }
    assert_eq!(total, count);
}

#[test]
fn helper_timeout_kills_descendants_and_releases_the_next_job() {
    let directory = tempfile::tempdir().unwrap();
    let marker = directory.path().join("escaped.txt");
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args(["--exact", "process_tree_fixture", "--nocapture"])
        .env("LOKALBOT_PROCESS_ROLE", "parent")
        .env("LOKALBOT_PROCESS_MARKER", &marker);
    let start = Instant::now();
    let result =
        lokalbot_desktop::process::bounded_output(&mut command, Duration::from_millis(400), 64000);
    assert!(result.is_err());
    assert!(start.elapsed() < Duration::from_secs(3));
    std::thread::sleep(Duration::from_millis(900));
    assert!(!marker.exists(), "Timed-out descendant kept running");
    let mut next = Command::new(std::env::current_exe().unwrap());
    next.args(["--exact", "process_tree_fixture"]);
    assert!(
        lokalbot_desktop::process::bounded_output(&mut next, Duration::from_secs(3), 64000)
            .unwrap()
            .status
            .success()
    );
}
#[test]
fn process_tree_fixture() {
    match std::env::var("LOKALBOT_PROCESS_ROLE").as_deref() {
        Ok("leaf") => {
            std::thread::sleep(Duration::from_secs(1));
            fs::write(
                std::env::var_os("LOKALBOT_PROCESS_MARKER").unwrap(),
                b"escaped",
            )
            .unwrap();
        }
        Ok("parent") => {
            let mut child = Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "process_tree_fixture"])
                .env("LOKALBOT_PROCESS_ROLE", "leaf")
                .spawn()
                .unwrap();
            child.wait().unwrap();
        }
        _ => {}
    }
}

#[test]
fn loopback_requests_bypass_proxy_environment_without_exposing_context() {
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "loopback_proxy_fixture", "--nocapture"])
        .env("LOKALBOT_PROXY_FIXTURE", "1")
        .env("http_proxy", "http://127.0.0.1:1")
        .env("HTTP_PROXY", "http://127.0.0.1:1")
        .env("ALL_PROXY", "http://127.0.0.1:1")
        .env_remove("NO_PROXY")
        .env_remove("no_proxy")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
}
#[test]
fn loopback_proxy_fixture() {
    if std::env::var_os("LOKALBOT_PROXY_FIXTURE").is_none() {
        return;
    }
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    listener.set_nonblocking(true).unwrap();
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut stream = loop {
            if let Ok((stream, _)) = listener.accept() {
                break stream;
            }
            if Instant::now() > deadline {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        };
        let mut bytes = [0; 4096];
        let _ = stream.read(&mut bytes).unwrap();
        let response = r#"{"choices":[{"finish_reason":"stop","message":{"content":"Synthetic direct answer"}}]}"#;
        write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}",response.len(),response).unwrap();
    });
    let settings = Settings {
        endpoint: format!("http://{address}/v1"),
        ..Default::default()
    };
    let answer = lokalbot_desktop::inference::Engine::with_key(settings, None)
        .unwrap()
        .generate(
            "synthetic",
            "Synthetic system",
            "Synthetic local context",
            None,
        );
    server.join().unwrap();
    assert!(answer.is_ok(), "{answer:?}");
}
