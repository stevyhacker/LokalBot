#![allow(clippy::field_reassign_with_default)] // Test fixtures change one permission at a time.
use lokalbot_desktop::{
    agent,
    audio::{ChunkWriter, recover_chunks},
    domain::*,
    fixtures,
    inference::Engine,
    privacy::{self, EgressGrant, Observation},
    services,
    storage::Library,
};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::TcpListener,
};

fn library() -> (tempfile::TempDir, Library) {
    let dir = tempfile::tempdir().unwrap();
    let lib = Library::open(dir.path()).unwrap();
    (dir, lib)
}
fn seeded() -> (tempfile::TempDir, Library) {
    let (dir, mut lib) = library();
    fixtures::seed(&mut lib).unwrap();
    (dir, lib)
}
fn observation() -> Observation {
    Observation {
        app: "Editor".into(),
        title: "Synthetic project".into(),
        window: "42".into(),
        pid: 123,
        field: Some("field-7".into()),
        focus_verified: true,
        secure: Some(false),
        domain: None,
        browser: false,
    }
}

#[test]
fn installs_are_local_and_empty_by_default() {
    let (_, lib) = library();
    let s = lib.settings().unwrap();
    assert_eq!(s.backend, Backend::Local);
    assert!(s.activity_enabled);
    assert!(
        !s.screen_text_enabled
            && !s.pixels_enabled
            && !s.meeting_access
            && !s.screen_access
            && !s.agent_enabled
            && !s.remote_audio
    );
    assert!(lib.meetings().unwrap().is_empty());
}
#[test]
fn synthetic_seed_refuses_overwrite() {
    let (_, mut lib) = seeded();
    assert!(fixtures::seed(&mut lib).is_err());
    assert_eq!(lib.meetings().unwrap().len(), 3);
}
#[test]
fn notes_and_actions_survive_restart() {
    let (dir, mut lib) = seeded();
    let mut m = lib.meetings().unwrap().remove(0);
    m.notes = "Review checkpoint vermilion".into();
    m.summary = Some(Summary {
        overview: "Test".into(),
        actions: vec![Action {
            id: new_id(),
            text: "Review Linux".into(),
            owner: "Maya".into(),
            due: "Thursday".into(),
            source: m.segments[0].id.clone(),
            done: false,
            corrected: false,
        }],
        ..Default::default()
    });
    let action = m.summary.as_ref().unwrap().actions[0].id.clone();
    lib.save_meeting(&m).unwrap();
    lib.toggle_action(&m.id, &action).unwrap();
    drop(lib);
    let lib = Library::open(dir.path()).unwrap();
    let m = lib.meeting(&m.id).unwrap();
    assert_eq!(m.notes, "Review checkpoint vermilion");
    assert!(m.summary.unwrap().actions[0].done);
    assert!(!lib.search("vermilion", 10).unwrap().is_empty());
}
#[test]
fn corrections_replace_search_evidence() {
    let (_, mut lib) = seeded();
    let mut m = lib.meetings().unwrap().remove(0);
    m.notes = "obsoleteword".into();
    lib.save_meeting(&m).unwrap();
    assert!(!lib.search("obsoleteword", 10).unwrap().is_empty());
    m.notes = "replacementword".into();
    lib.save_meeting(&m).unwrap();
    assert!(lib.search("obsoleteword", 10).unwrap().is_empty());
    assert!(!lib.search("replacementword", 10).unwrap().is_empty());
}
#[test]
fn deleting_sources_retracts_search_and_generated_journals() {
    let (_, mut lib) = seeded();
    let m = lib.meetings().unwrap().remove(0);
    lib.save_digest(&Digest {
        day: "2026-10-02".into(),
        text: "Generated fact".into(),
        sources: vec![m.id.clone()],
        fingerprint: "test".into(),
        created_at: now(),
    })
    .unwrap();
    lib.delete_meeting(&m.id).unwrap();
    assert!(lib.meeting(&m.id).is_err());
    assert!(lib.evidence(&m.segments[0].id).is_err());
    assert!(lib.digest("2026-10-02").unwrap().is_none());
}
#[test]
fn invalid_timestamps_do_not_mutate_a_meeting() {
    let (_, mut lib) = seeded();
    let original = lib.meetings().unwrap().remove(0);
    let mut m = original.clone();
    m.segments[0].start = -1.;
    assert!(lib.save_meeting(&m).is_err());
    assert_eq!(lib.meeting(&m.id).unwrap(), original);
}
#[test]
fn file_ids_cannot_escape_the_library() {
    let (_, mut lib) = library();
    let mut m = Meeting::empty("test");
    m.id = "../../outside".into();
    assert!(lib.save_meeting(&m).is_err());
    assert!(lib.delete_meeting("../outside").is_err());
}
#[test]
fn duplicate_gui_process_is_refused() {
    let (dir, lib) = library();
    let lock = lib.gui_lock().unwrap();
    let other = Library::open(dir.path()).unwrap();
    assert!(other.gui_lock().is_err());
    drop(lock);
    assert!(other.gui_lock().is_ok());
}
#[test]
fn independent_external_grants_are_enforced() {
    let (_, mut lib) = seeded();
    assert!(lib.external_meetings().is_err());
    assert!(lib.external_moments(now()).is_err());
    let mut s = lib.settings().unwrap();
    s.meeting_access = true;
    lib.save_settings(&mut s).unwrap();
    assert!(lib.external_meetings().is_ok());
    assert!(lib.external_moments(now()).is_err());
    s.meeting_access = false;
    s.screen_access = true;
    lib.save_settings(&mut s).unwrap();
    assert!(lib.external_meetings().is_err());
    assert!(lib.external_moments(now()).is_ok());
}
#[test]
fn screen_external_access_obeys_time_scope_and_hides_pixel_paths() {
    let (_, mut lib) = library();
    let at = now();
    for (age, saved) in [(1, false), (9, true)] {
        lib.save_moment(&Moment {
            id: new_id(),
            app: "Test".into(),
            title: "Test".into(),
            text: "Test".into(),
            created_at: at - age * 86400,
            saved,
            pixels: Some("pixels/private.enc".into()),
        })
        .unwrap();
    }
    let mut s = lib.settings().unwrap();
    s.screen_access = true;
    s.screen_access_days = Some(7);
    lib.save_settings(&mut s).unwrap();
    let rows = lib.external_moments(at).unwrap();
    assert_eq!(rows.len(), 1);
    assert!(rows[0].pixels.is_none());
}
#[test]
fn retention_removes_unsaved_text_and_keeps_saved_moments() {
    let (_, mut lib) = library();
    let at = now();
    for saved in [false, true] {
        lib.save_moment(&Moment {
            id: new_id(),
            app: "Test".into(),
            title: "Old".into(),
            text: if saved {
                "retainedneedle"
            } else {
                "expiredneedle"
            }
            .into(),
            created_at: at - 20 * 86400,
            saved,
            pixels: None,
        })
        .unwrap();
    }
    assert_eq!(lib.expire(at).unwrap(), 1);
    assert!(lib.search("expiredneedle", 10).unwrap().is_empty());
    assert_eq!(lib.search("retainedneedle", 10).unwrap().len(), 1);
}
#[test]
fn activity_titles_expire_while_duration_remains() {
    let (_, mut lib) = library();
    let a = Activity {
        id: new_id(),
        app: "Editor".into(),
        title: "Private old document".into(),
        start: now() - 20 * 86400,
        end: now() - 20 * 86400 + 300,
        private: false,
    };
    lib.save_activity(&a).unwrap();
    lib.expire(now()).unwrap();
    let current = lib.activity().unwrap().remove(0);
    assert!(current.title.is_empty());
    assert_eq!(current.end - current.start, 300);
    assert_eq!(current.app, "Editor");
}
#[test]
fn origins_require_exact_approval() {
    let mut s = Settings::default();
    s.backend = Backend::OpenRouter;
    s.endpoint = "https://openrouter.ai/api/v1".into();
    assert!(privacy::check_inference(&s).is_err());
    s.approved_origins.push("https://openrouter.ai".into());
    assert!(privacy::check_inference(&s).is_ok());
    s.endpoint = "https://openrouter.ai.evil.test/api/v1".into();
    assert!(privacy::check_inference(&s).is_err());
}
#[test]
fn endpoint_credentials_and_remote_http_are_rejected() {
    for url in [
        "http://remote.test/v1",
        "https://key@server.test/v1",
        "https://server.test/v1?token=secret",
        "file:///tmp/api",
    ] {
        assert!(privacy::origin(url).is_err());
    }
    assert!(privacy::origin("http://[::1]:1234/v1").is_ok());
}
#[test]
fn revocation_invalidates_pending_generation() {
    let (_, mut lib) = library();
    let grant = EgressGrant::acquire(&lib).unwrap();
    let mut s = lib.settings().unwrap();
    s.paused = true;
    lib.save_settings(&mut s).unwrap();
    assert!(grant.verify(&lib).is_err());
}
#[test]
fn secrets_and_emails_are_removed_from_model_context() {
    let input = "email maya@example.test sk-or-v1-abcdefghijklmnopqrstuvwxyz secret=SYNTHETIC-CREDENTIAL-NEVER-SEND Bearer supersecrettoken";
    let text = privacy::redact(input);
    for secret in [
        "maya@example.test",
        "abcdefghijklmnopqrstuvwxyz",
        "SYNTHETIC-CREDENTIAL-NEVER-SEND",
        "supersecrettoken",
    ] {
        assert!(!text.contains(secret));
    }
    assert!(text.contains("[redacted]"));
}
#[test]
fn focus_unknown_secure_and_excluded_windows_refuse_screen_capture() {
    let mut s = Settings::default();
    s.screen_text_enabled = true;
    let mut o = observation();
    assert!(privacy::allow_screen(&o, &s));
    o.secure = None;
    assert!(!privacy::allow_screen(&o, &s));
    o.secure = Some(true);
    assert!(!privacy::allow_screen(&o, &s));
    o.secure = Some(false);
    o.focus_verified = false;
    assert!(!privacy::allow_screen(&o, &s));
    o.focus_verified = true;
    o.app = "Bitwarden".into();
    assert!(!privacy::allow_screen(&o, &s));
}
#[test]
fn a_browser_with_unknown_domain_fails_closed_when_exclusions_exist() {
    let mut s = Settings::default();
    s.screen_text_enabled = true;
    s.excluded_domains.push("private.test".into());
    let mut o = observation();
    o.browser = true;
    assert!(!privacy::allow_screen(&o, &s));
    o.domain = Some("docs.public.test".into());
    assert!(privacy::allow_screen(&o, &s));
    o.domain = Some("sub.private.test".into());
    assert!(!privacy::allow_screen(&o, &s));
}
#[test]
fn changed_focus_or_permissions_discards_a_capture() {
    let mut s = Settings::default();
    s.screen_text_enabled = true;
    let before = observation();
    let mut after = before.clone();
    after.window = "43".into();
    assert!(!privacy::capture_still_valid(&before, &after, &s, 0));
    assert!(privacy::capture_still_valid(&before, &before, &s, 0));
    s.revision = 1;
    assert!(!privacy::capture_still_valid(&before, &before, &s, 0));
}
#[test]
fn encrypted_pixels_are_authenticated_and_not_plaintext() {
    let (dir, _) = library();
    let plaintext = b"SYNTHETIC-PIXELS-NOT-PLAINTEXT";
    let encrypted = privacy::encrypt_pixels(dir.path(), plaintext).unwrap();
    assert!(!encrypted.windows(plaintext.len()).any(|w| w == plaintext));
    assert_eq!(
        privacy::decrypt_pixels(dir.path(), &encrypted).unwrap(),
        plaintext
    );
    let mut tampered = encrypted;
    tampered[15] ^= 1;
    assert!(privacy::decrypt_pixels(dir.path(), &tampered).is_err());
}
#[test]
fn audio_checkpoints_preserve_trailing_frames() {
    let (dir, _) = library();
    let chunks = dir.path().join("chunks");
    let mut writer = ChunkWriter::new(&chunks, 16000).unwrap();
    let samples = (0..70013).map(|i| (i % 200) as i16).collect::<Vec<_>>();
    writer.append(&samples).unwrap();
    let out = dir.path().join("mic.wav");
    let duration = writer.finish(2, &out).unwrap();
    let mut reader = hound::WavReader::open(out).unwrap();
    let decoded = reader
        .samples::<i16>()
        .map(Result::unwrap)
        .collect::<Vec<_>>();
    assert_eq!(samples, decoded);
    assert!((duration - 70013. / 16000.).abs() < 0.0001);
}
#[test]
fn crash_recovery_uses_only_verified_closed_checkpoints() {
    let (dir, _) = library();
    let chunks = dir.path().join("chunks");
    let mut writer = ChunkWriter::new(&chunks, 16000).unwrap();
    writer.append(&vec![5; 65000]).unwrap();
    drop(writer);
    let out = dir.path().join("repaired.wav");
    let duration = recover_chunks(&chunks, &out).unwrap();
    assert_eq!(duration, 4.);
    let chunk = chunks.join("000000.wav");
    std::fs::write(chunk, b"corrupted").unwrap();
    assert!(recover_chunks(&chunks, &out).is_err());
    assert_eq!(hound::WavReader::open(out).unwrap().duration(), 64000);
}
#[test]
fn interrupted_jobs_do_not_authorize_new_recording() {
    let (_, lib) = library();
    lib.save_job(&Job {
        id: new_id(),
        meeting_id: None,
        kind: "recording".into(),
        status: "running".into(),
        error: None,
        updated_at: now(),
    })
    .unwrap();
    assert_eq!(lib.recover_jobs().unwrap(), 1);
    let job = lib.jobs().unwrap().remove(0);
    assert_eq!(job.status, "interrupted");
    assert!(job.error.unwrap().contains("not restarted"));
    assert_eq!(lib.recover_jobs().unwrap(), 0);
}
#[test]
fn semantic_search_rejects_old_model_and_mismatched_dimensions() {
    let (_, lib) = seeded();
    let m = lib.meetings().unwrap().remove(0);
    lib.save_embedding(&m.segments[0].id, "model-v1", &[1., 0.])
        .unwrap();
    assert_eq!(
        lib.semantic_search(&[1., 0.], "model-v1", 5).unwrap().len(),
        1
    );
    assert!(
        lib.semantic_search(&[1., 0.], "model-v2", 5)
            .unwrap()
            .is_empty()
    );
    assert!(
        lib.semantic_search(&[1., 0., 0.], "model-v1", 5)
            .unwrap()
            .is_empty()
    );
}
#[test]
fn imported_json_cannot_overwrite_existing_records_or_adopt_external_media() {
    let (dir, mut lib) = seeded();
    let original = lib.meetings().unwrap().remove(0);
    let mut file = original.clone();
    file.title = "Attacker collision".into();
    file.media = vec![Media {
        track: "mic".into(),
        path: "/etc/passwd".into(),
    }];
    let path = dir.path().join("import.json");
    std::fs::write(&path, serde_json::to_vec(&file).unwrap()).unwrap();
    let id = services::import_transcript(&mut lib, &path, None).unwrap();
    assert_ne!(id, original.id);
    assert!(lib.meeting(&id).unwrap().media.is_empty());
    assert_eq!(lib.meeting(&original.id).unwrap(), original);
}
#[test]
fn empty_library_answers_without_a_model_or_network() {
    let (_, lib) = library();
    let answer = services::ask(&lib, "Where is the cobalt shipment?").unwrap();
    assert!(answer.answer.sources.is_empty());
    assert!(answer.answer.text.contains("could not find"));
    assert!(lib.generations().unwrap().is_empty());
}
#[test]
fn agent_shell_wrappers_and_hidden_commands_are_refused() {
    for program in ["bash", "cmd.exe", "powershell.exe", "pwsh"] {
        assert!(
            agent::validate_proposal(&agent::Proposal {
                program: program.into(),
                args: vec!["encodedCommand".into()],
                reason: "test".into()
            })
            .is_err()
        );
    }
    assert!(
        agent::validate_proposal(&agent::Proposal {
            program: "git".into(),
            args: vec!["status".into(), "--short".into()],
            reason: "Review changes".into()
        })
        .is_ok()
    );
}
#[test]
fn openrouter_requests_preserve_private_only_routing() {
    let mut s = Settings::default();
    s.backend = Backend::OpenRouter;
    s.endpoint = "https://openrouter.ai/api/v1".into();
    s.approved_origins.push("https://openrouter.ai".into());
    let engine = Engine::with_key(s, Some("synthetic-key".into())).unwrap();
    let body = engine.request_body("test", json!("test"), None);
    assert_eq!(body["provider"]["data_collection"], "deny");
    assert_eq!(body["provider"]["require_parameters"], true);
    assert!(!body.to_string().contains("synthetic-key"));
}
#[test]
fn transcription_cannot_silently_relax_private_only() {
    let (dir, _) = library();
    let audio = dir.path().join("a.wav");
    std::fs::write(&audio, b"test").unwrap();
    let mut s = Settings::default();
    s.backend = Backend::OpenRouter;
    s.endpoint = "https://openrouter.ai/api/v1".into();
    s.approved_origins.push("https://openrouter.ai".into());
    s.remote_audio = true;
    let engine = Engine::with_key(s, Some("synthetic-key".into())).unwrap();
    assert!(
        engine
            .transcribe(&audio)
            .unwrap_err()
            .to_string()
            .contains("private-only")
    );
}

fn server(status: &str, response: Value) -> (Settings, std::thread::JoinHandle<Value>) {
    server_with_hook(status, response, |_| {})
}
fn server_with_hook(
    status: &str,
    response: Value,
    hook: impl FnOnce(&Value) + Send + 'static,
) -> (Settings, std::thread::JoinHandle<Value>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let status = status.to_string();
    let thread = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let mut header = vec![];
        while !header.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            stream.read_exact(&mut byte).unwrap();
            header.push(byte[0]);
        }
        let header = String::from_utf8(header).unwrap();
        let length = header
            .lines()
            .find_map(|l| {
                l.to_ascii_lowercase()
                    .strip_prefix("content-length:")
                    .and_then(|s| s.trim().parse::<usize>().ok())
            })
            .unwrap();
        let mut body = vec![0; length];
        stream.read_exact(&mut body).unwrap();
        let mut request: Value = serde_json::from_slice(&body).unwrap();
        hook(&request);
        request["_headers"] = json!(header);
        let data = response.to_string();
        write!(stream,"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{data}",data.len()).unwrap();
        request
    });
    let settings = Settings {
        endpoint: format!("http://{address}/v1"),
        ..Default::default()
    };
    (settings, thread)
}
#[test]
fn real_transport_sends_redacted_context() {
    let (s, thread) = server(
        "200 OK",
        json!({"choices":[{"finish_reason":"stop","message":{"content":"OK"}}]}),
    );
    let engine = Engine::with_key(s, None).unwrap();
    assert_eq!(
        engine
            .generate(
                "test",
                "Test",
                "secret=SYNTHETIC-CREDENTIAL-NEVER-SEND",
                None
            )
            .unwrap()
            .0,
        "OK"
    );
    let request = thread.join().unwrap();
    assert!(!request.to_string().contains("SYNTHETIC-CREDENTIAL"));
}
#[test]
fn transport_rejects_truncation() {
    let (s, thread) = server(
        "200 OK",
        json!({"choices":[{"finish_reason":"length","message":{"content":"half"}}]}),
    );
    let engine = Engine::with_key(s, None).unwrap();
    assert!(
        engine
            .generate("test", "Test", "data", None)
            .unwrap_err()
            .to_string()
            .contains("truncated")
    );
    thread.join().unwrap();
}
#[test]
fn http_errors_do_not_expose_remote_response_bodies() {
    let (s, thread) = server(
        "401 Unauthorized",
        json!({"error":{"message":"SYNTHETIC_PRIVATE_PROVIDER_BODY"}}),
    );
    let engine = Engine::with_key(s, None).unwrap();
    let error = engine
        .generate("test", "Test", "data", None)
        .unwrap_err()
        .to_string();
    assert!(error.contains("401"));
    assert!(!error.contains("SYNTHETIC_PRIVATE"));
    thread.join().unwrap();
}
#[test]
fn an_invented_summary_source_is_rejected_before_persistence() {
    let (dir, mut lib) = seeded();
    let m = lib.meetings().unwrap().remove(0);
    let output = json!({"overview":"Test","decisions":[{"text":"Invented","source":"nonexistent"}],"actions":[],"questions":[]});
    let (s, thread) = server(
        "200 OK",
        json!({"choices":[{"finish_reason":"stop","message":{"content":output.to_string()}}]}),
    );
    let mut settings = s;
    lib.save_settings(&mut settings).unwrap();
    assert!(services::summarize(&mut lib, &m.id).is_err());
    assert!(
        Library::open(dir.path())
            .unwrap()
            .meeting(&m.id)
            .unwrap()
            .summary
            .is_none()
    );
    thread.join().unwrap();
}

#[test]
fn local_transport_never_receives_an_openrouter_credential() {
    let (settings, thread) = server(
        "200 OK",
        json!({"choices":[{"finish_reason":"stop","message":{"content":"OK"}}]}),
    );
    Engine::with_key(settings, Some("SYNTHETIC_OPENROUTER_KEY".into()))
        .unwrap()
        .generate("test", "Test", "Test", None)
        .unwrap();
    let request = thread.join().unwrap();
    assert!(
        !request["_headers"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .contains("authorization")
    );
}
#[test]
fn fields_must_be_identified_and_remain_focused() {
    let mut s = Settings::default();
    s.screen_text_enabled = true;
    let before = observation();
    let mut after = before.clone();
    after.field = Some("different-field-in-same-window".into());
    assert!(!privacy::capture_still_valid(
        &before, &after, &s, s.revision
    ));
    after.field = None;
    assert!(!privacy::allow_screen(&after, &s));
}
#[test]
fn guarded_writes_rollback_and_refuse_stale_permissions() {
    let (_, mut lib) = seeded();
    let mut s = lib.settings().unwrap();
    lib.save_settings(&mut s).unwrap();
    let before = lib.meetings().unwrap().remove(0);
    let mut changed = before.clone();
    changed.notes = "uncommittedneedle".into();
    let result: anyhow::Result<()> = lib.guarded_write_mut(s.revision, |lib| {
        lib.save_meeting(&changed)?;
        anyhow::bail!("Abort final validation")
    });
    assert!(result.is_err());
    assert_eq!(lib.meeting(&before.id).unwrap(), before);
    assert!(lib.search("uncommittedneedle", 5).unwrap().is_empty());
    assert!(lib.guarded_write(s.revision - 1, |_| Ok(())).is_err());
}
fn completion(output: Value) -> Value {
    json!({"choices":[{"finish_reason":"stop","message":{"content":output.to_string()}}]})
}
#[test]
fn malformed_summary_marks_the_whole_job_failed() {
    let (_, mut lib) = seeded();
    let m = lib.meetings().unwrap().remove(0);
    let (mut settings, thread) = server("200 OK", completion(json!({"invalid":"schema"})));
    lib.save_settings(&mut settings).unwrap();
    assert!(services::summarize(&mut lib, &m.id).is_err());
    assert_eq!(lib.jobs().unwrap()[0].status, "failed");
    thread.join().unwrap();
}
#[test]
fn concurrent_title_edits_discard_generated_notes() {
    let (dir, mut lib) = seeded();
    let m = lib.meetings().unwrap().remove(0);
    let copy = m.clone();
    let root = dir.path().to_owned();
    let (mut settings, thread) = server_with_hook(
        "200 OK",
        completion(json!({"overview":"Old title","decisions":[],"actions":[],"questions":[]})),
        move |_| {
            let mut lib = Library::open(root).unwrap();
            let mut current = lib.meeting(&copy.id).unwrap();
            current.title = "Corrected title".into();
            lib.save_meeting(&current).unwrap();
        },
    );
    lib.save_settings(&mut settings).unwrap();
    assert!(services::summarize(&mut lib, &m.id).is_err());
    assert!(lib.meeting(&m.id).unwrap().summary.is_none());
    thread.join().unwrap();
}
#[test]
fn action_corrections_during_generation_survive_without_duplicate_ids() {
    let (dir, mut lib) = seeded();
    let mut m = lib.meetings().unwrap().remove(0);
    let source = m.segments[0].id.clone();
    let old = Action {
        id: new_id(),
        text: "Original".into(),
        owner: "Maya".into(),
        due: "".into(),
        source: source.clone(),
        done: false,
        corrected: false,
    };
    m.summary = Some(Summary {
        actions: vec![old.clone()],
        ..Default::default()
    });
    lib.save_meeting(&m).unwrap();
    let mut generated = old.clone();
    generated.id.clear();
    let other = Action {
        text: "Different action".into(),
        ..generated.clone()
    };
    let root = dir.path().to_owned();
    let id = m.id.clone();
    let old_id = old.id.clone();
    let (mut settings, thread) = server_with_hook(
        "200 OK",
        completion(
            json!({"overview":"Updated","decisions":[],"actions":[generated,other],"questions":[]}),
        ),
        move |_| {
            Library::open(root)
                .unwrap()
                .correct_action(
                    &id,
                    &old_id,
                    "Reviewed correction".into(),
                    "Alex".into(),
                    "Monday".into(),
                )
                .unwrap();
        },
    );
    lib.save_settings(&mut settings).unwrap();
    let summary = services::summarize(&mut lib, &m.id).unwrap();
    assert_eq!(summary.actions.len(), 2);
    assert_ne!(summary.actions[0].id, summary.actions[1].id);
    assert_eq!(summary.actions[0].text, "Reviewed correction");
    assert_eq!(summary.actions[0].owner, "Alex");
    thread.join().unwrap();
}
#[test]
fn digest_rejects_deleted_sources_and_never_sends_pixel_paths() {
    let (dir, mut lib) = seeded();
    let m = lib.meetings().unwrap().remove(0);
    let root = dir.path().to_owned();
    let id = m.id.clone();
    lib.save_moment(&Moment {
        id: new_id(),
        app: "Editor".into(),
        title: "Fictional".into(),
        text: "Synthetic visible text".into(),
        created_at: now(),
        saved: false,
        pixels: Some("pixels/PRIVATE_PATH.enc".into()),
    })
    .unwrap();
    let (mut settings, thread) = server_with_hook(
        "200 OK",
        json!({"choices":[{"finish_reason":"stop","message":{"content":"A daily digest"}}]}),
        move |request| {
            assert!(!request.to_string().contains("PRIVATE_PATH"));
            Library::open(root).unwrap().delete_meeting(&id).unwrap();
        },
    );
    settings.screen_text_enabled = true;
    lib.save_settings(&mut settings).unwrap();
    assert!(services::digest(&lib, &services::today()).is_err());
    assert!(lib.digest(&services::today()).unwrap().is_none());
    assert_eq!(lib.jobs().unwrap()[0].status, "failed");
    thread.join().unwrap();
}
#[test]
fn approved_commands_strip_credentials_from_inherited_environment() {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "credential_environment_parent", "--nocapture"])
        .env("LOKALBOT_TEST_ENV_PARENT", "1")
        .env("OPENROUTER_API_KEY", "SYNTHETIC_KEY")
        .env("UNRELATED_SECRET", "SYNTHETIC_SECRET")
        .env("LOKALBOT_STORAGE_ROOT", "SYNTHETIC_ROOT")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
}
#[test]
fn credential_environment_parent() {
    if std::env::var_os("LOKALBOT_TEST_ENV_PARENT").is_none() {
        return;
    }
    assert_eq!(
        std::env::var("OPENROUTER_API_KEY").unwrap(),
        "SYNTHETIC_KEY"
    );
    let mut command = lokalbot_desktop::process::approved_command(
        std::env::current_exe().unwrap().to_str().unwrap(),
    );
    command
        .args(["--exact", "credential_environment_leaf"])
        .env("LOKALBOT_TEST_ENV_LEAF", "1");
    let output = lokalbot_desktop::process::bounded_output(
        &mut command,
        std::time::Duration::from_secs(5),
        64000,
    )
    .unwrap();
    assert!(output.status.success());
}
#[test]
fn credential_environment_leaf() {
    if std::env::var_os("LOKALBOT_TEST_ENV_LEAF").is_none() {
        return;
    }
    for name in [
        "OPENROUTER_API_KEY",
        "UNRELATED_SECRET",
        "LOKALBOT_STORAGE_ROOT",
    ] {
        assert!(std::env::var_os(name).is_none());
    }
}

#[test]
fn concurrent_pixel_writes_share_one_key() {
    let (dir, _) = library();
    let workers = (0..8)
        .map(|i| {
            let root = dir.path().to_owned();
            std::thread::spawn(move || {
                let data = format!("fictional pixels {i}").into_bytes();
                let encrypted = privacy::encrypt_pixels(&root, &data).unwrap();
                (data, encrypted)
            })
        })
        .collect::<Vec<_>>();
    for worker in workers {
        let (data, encrypted) = worker.join().unwrap();
        assert_eq!(
            privacy::decrypt_pixels(dir.path(), &encrypted).unwrap(),
            data
        );
    }
}

#[test]
fn long_multilingual_transcripts_are_bounded_without_losing_evidence() {
    let mut meeting = Meeting::empty("Long fictional meeting");
    let text = "Članovi tima će pregledati snimak. ".repeat(2000);
    meeting.segments.push(Segment {
        id: new_id(),
        start: 0.,
        end: 300.,
        speaker: "Alex".into(),
        text: text.clone(),
    });
    let chunks = services::summary_chunks(&meeting).unwrap();
    assert!(chunks.len() > 1);
    let id = &meeting.segments[0].id;
    let mut reconstructed = String::new();
    for (chunk, sources) in chunks {
        assert!(chunk.len() <= 18000);
        assert_eq!(sources, vec![id.clone()]);
        let (_, body) = chunk.split_once(": ").unwrap();
        reconstructed.push_str(body.trim_end_matches('\n'));
    }
    assert_eq!(reconstructed, text);
}

#[test]
fn relaunch_repairs_recording_metadata_without_starting_capture() {
    let (dir, mut lib) = library();
    let meeting = Meeting::empty("Interrupted fictional recording");
    lib.save_meeting(&meeting).unwrap();
    let chunks = dir
        .path()
        .join("meetings")
        .join(&meeting.id)
        .join("mic-chunks");
    let mut writer = ChunkWriter::new(&chunks, 16000).unwrap();
    writer.append(&vec![42; 70000]).unwrap();
    drop(writer);
    assert_eq!(
        lokalbot_desktop::audio::recover_recordings(&mut lib).unwrap(),
        vec![meeting.id.clone()]
    );
    let repaired = lib.meeting(&meeting.id).unwrap();
    assert_eq!(repaired.duration, 4.);
    assert!(repaired.warnings[0].contains("not restarted"));
    assert!(
        lokalbot_desktop::audio::recover_recordings(&mut lib)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn summary_retry_reuses_only_validated_parts_from_the_same_input() {
    let (_, mut lib) = library();
    let mut meeting = Meeting::empty("Long synthetic pipeline");
    for i in 0..2 {
        meeting.segments.push(Segment {
            id: new_id(),
            start: i as f64 * 60.,
            end: (i + 1) as f64 * 60.,
            speaker: "Alex".into(),
            text: "Fictional passage. ".repeat(700),
        });
    }
    lib.save_meeting(&meeting).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let first = completion(
        json!({"overview":"First retained part","decisions":[{"text":"First decision","source":meeting.segments[0].id}],"actions":[],"questions":[]}),
    );
    let second = completion(
        json!({"overview":"Second retained part","decisions":[{"text":"Second decision","source":meeting.segments[1].id}],"actions":[],"questions":[]}),
    );
    let thread = std::thread::spawn(move || {
        for (status, response) in [
            ("200 OK", first),
            (
                "500 Internal Server Error",
                json!({"error":"injected failure"}),
            ),
            ("200 OK", second),
        ] {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
            let mut header = Vec::new();
            while !header.ends_with(b"\r\n\r\n") {
                let mut b = [0];
                stream.read_exact(&mut b).unwrap();
                header.push(b[0]);
            }
            let header = String::from_utf8(header).unwrap();
            let length = header
                .lines()
                .find_map(|l| {
                    l.to_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|s| s.trim().parse::<usize>().ok())
                })
                .unwrap();
            let mut body = vec![0; length];
            stream.read_exact(&mut body).unwrap();
            let body: Value = serde_json::from_slice(&body).unwrap();
            assert!(body["messages"][1]["content"].as_str().unwrap().len() < 19000);
            let data = response.to_string();
            write!(stream,"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{data}",data.len()).unwrap();
        }
    });
    let mut settings = Settings {
        endpoint: format!("http://{address}/v1"),
        ..Default::default()
    };
    lib.save_settings(&mut settings).unwrap();
    assert!(services::summarize(&mut lib, &meeting.id).is_err());
    assert!(lib.meeting(&meeting.id).unwrap().summary.is_none());
    assert_eq!(lib.generations().unwrap().len(), 1);
    let summary = services::summarize(&mut lib, &meeting.id).unwrap();
    assert!(
        summary.overview.contains("First retained part")
            && summary.overview.contains("Second retained part")
    );
    assert_eq!(summary.decisions.len(), 2);
    assert_eq!(lib.generations().unwrap().len(), 2);
    thread.join().unwrap();
}
