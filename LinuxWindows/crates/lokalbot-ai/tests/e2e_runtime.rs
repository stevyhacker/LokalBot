//! Real downloads and a real `llama-server`. Needs the network and ~1 GB of
//! disk; run on a development machine:
//!
//! ```sh
//! LOKALBOT_E2E_ROOT=~/scratch-root cargo test -p lokalbot-ai --test e2e_runtime -- --ignored --nocapture
//! ```

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

use lokalbot_ai::catalog;
use lokalbot_ai::think::dot;
use lokalbot_ai::{ChatRequest, EmbeddingClient, RuntimeManager, ThinkClient, download};
use lokalbot_core::{LibraryPaths, Settings};

pub fn e2e_root() -> PathBuf {
    std::env::var_os("LOKALBOT_E2E_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("lokalbot-ai-e2e"))
}

fn progress(label: &'static str) -> impl FnMut(u64, u64) {
    let mut last = 0u64;
    move |done, total| {
        let step = total / 4;
        if total > 0 && (done == total || done >= last + step.max(1)) {
            last = done;
            eprintln!(
                "  {label}: {:.0}% of {:.1} MB",
                done as f64 * 100.0 / total as f64,
                total as f64 / 1e6
            );
        }
    }
}

#[test]
#[ignore = "downloads the llama.cpp runtime and two models"]
fn installs_runtime_downloads_models_and_answers() {
    let root = e2e_root();
    let paths = LibraryPaths::new(&root);
    let settings = Settings {
        built_in_model_id: catalog::COMPACT_FALLBACK_ID.into(),
        llama_backend: std::env::var("LOKALBOT_E2E_BACKEND").unwrap_or_else(|_| "auto".into()),
        ..Settings::default()
    };
    let cancel = AtomicBool::new(false);
    let runtime = RuntimeManager::new(paths.clone(), &settings);

    let started = Instant::now();
    runtime
        .ensure_runtime(&settings, &cancel, &mut progress("runtime"))
        .expect("runtime installs");
    eprintln!(
        "runtime ready in {:.1}s: backend={:?} version={:?}",
        started.elapsed().as_secs_f64(),
        runtime.installed_backend(),
        runtime.installed_version()
    );
    assert!(runtime.installed_backend().is_some());
    if settings.llama_backend == "cuda" {
        assert_eq!(runtime.installed_backend().as_deref(), Some("CUDA"));
    }
    if std::env::var_os("LOKALBOT_E2E_RUNTIME_ONLY").is_some() {
        return;
    }

    for id in [catalog::COMPACT_FALLBACK_ID, catalog::EMBEDDING_ID] {
        let entry = catalog::entry(id).unwrap();
        let started = Instant::now();
        download(
            &catalog::download_spec(&paths, entry),
            &cancel,
            &mut progress(entry.id),
        )
        .expect("model downloads");
        eprintln!("{id} ready in {:.1}s", started.elapsed().as_secs_f64());
        assert!(catalog::is_downloaded(&paths, entry));
        assert!(catalog::verify_downloaded(&paths, entry).unwrap());
    }

    let think = ThinkClient::new(&runtime, &settings).unwrap();
    let started = Instant::now();
    let hello = think
        .complete(
            &ChatRequest::new(
                "You are a connectivity test. Reply with one short sentence.",
                "Say hello and name the model you are.",
            )
            .max_tokens(96)
            .reasoning_budget(0)
            .temperature(0.2),
        )
        .expect("chat works");
    eprintln!(
        "first reply (cold start) in {:.1}s: {hello:?}",
        started.elapsed().as_secs_f64()
    );
    assert!(!hello.trim().is_empty());
    assert!(think.token_count("Hello there").unwrap().unwrap() >= 2);

    #[derive(serde::Deserialize, Debug)]
    struct Colors {
        colors: Vec<String>,
    }
    let schema = serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "required": ["colors"],
        "properties": {"colors": {"type": "array", "maxItems": 3, "items": {"type": "string", "enum": ["red", "green", "blue", "black"]}}}
    });
    let started = Instant::now();
    let colors: Colors = think
        .complete_json(
            &ChatRequest::new("Return only JSON.", "Name the colors of a traffic light.")
                .max_tokens(128)
                .reasoning_budget(0)
                .temperature(0.0)
                .json_schema(schema),
        )
        .expect("schema-constrained JSON");
    eprintln!(
        "json reply in {:.1}s: {colors:?}",
        started.elapsed().as_secs_f64()
    );
    assert!(!colors.colors.is_empty());

    let mut streamed = String::new();
    let text = think
        .stream(
            &ChatRequest::new("Answer briefly.", "Count from one to five in words.")
                .max_tokens(64)
                .reasoning_budget(0),
            &mut |d| streamed.push_str(d),
        )
        .expect("streaming works");
    eprintln!("streamed: {text:?}");
    assert_eq!(text.trim(), streamed.trim());

    let embedder = EmbeddingClient::new(&runtime);
    let started = Instant::now();
    let documents = embedder
        .embed_documents(&[
            "Redis caching layer review and failover benchmark".into(),
            "Lunch menu for Friday".into(),
        ])
        .unwrap();
    let query = embedder.embed_query("cache failover benchmark").unwrap();
    eprintln!(
        "embeddings in {:.1}s: dims={} related={:.3} unrelated={:.3}",
        started.elapsed().as_secs_f64(),
        query.len(),
        dot(&query, &documents[0]),
        dot(&query, &documents[1])
    );
    assert_eq!(query.len(), catalog::EMBEDDING_DIMENSIONS);
    assert!(dot(&query, &documents[0]) > dot(&query, &documents[1]));
    for status in runtime.statuses() {
        if settings.llama_backend == "cuda"
            && matches!(
                status.role,
                lokalbot_ai::runtime::Role::Main | lokalbot_ai::runtime::Role::Embedder
            )
        {
            assert!(status.running, "both exercised CUDA roles must be running");
            assert_eq!(status.backend, Some(lokalbot_ai::LlamaBackend::Cuda));
            assert!(
                lokalbot_ai::runtime::read_marker(&paths, status.port)
                    .unwrap()
                    .gpu_offloaded,
                "CUDA validation must establish model offload, not just a healthy CPU server"
            );
            eprintln!("confirmed GPU model offload for {:?}", status.role);
        }
        eprintln!(
            "server {:?}: running={} model={:?} backend={:?}",
            status.role, status.running, status.model_id, status.backend
        );
    }
    runtime.shutdown();
    assert!(runtime.statuses().iter().all(|s| !s.running));
}

fn copy_dir(from: &std::path::Path, to: &std::path::Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap().flatten() {
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// The macOS upgrade fixture, copied so nothing writes into it.
pub fn fixture_library() -> (tempfile::TempDir, lokalbot_core::Library) {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../LokalBotTests/Fixtures/upgrade/0.10.9/library");
    let dir = tempfile::tempdir().unwrap();
    copy_dir(&source, dir.path());
    let library = lokalbot_core::Library::open(LibraryPaths::new(dir.path())).unwrap();
    (dir, library)
}

#[test]
#[ignore = "needs the runtime and models from installs_runtime_downloads_models_and_answers"]
fn generates_notes_for_a_fixture_meeting() {
    let _ = env_logger::builder()
        .is_test(true)
        .filter_level(log::LevelFilter::Info)
        .try_init();
    let root = e2e_root();
    let model =
        std::env::var("LOKALBOT_E2E_MODEL").unwrap_or_else(|_| catalog::COMPACT_FALLBACK_ID.into());
    let settings = Settings {
        built_in_model_id: model,
        llama_backend: "auto".into(),
        ..Settings::default()
    };
    let runtime = RuntimeManager::new(LibraryPaths::new(&root), &settings);
    let think = ThinkClient::new(&runtime, &settings).unwrap();
    let (_dir, library) = fixture_library();
    let title = std::env::var("LOKALBOT_E2E_MEETING")
        .unwrap_or_else(|_| "Customer call - Northwind".into());
    let meeting = library
        .list_meetings()
        .unwrap()
        .into_iter()
        .find(|m| m.title == title)
        .expect("fixture meeting");
    let transcript = library.transcript(&meeting).unwrap().unwrap();
    let notes_text = library.notes(&meeting).unwrap();
    let started = Instant::now();
    let notes = lokalbot_ai::notes::generate_meeting_notes(
        &think,
        &meeting,
        &transcript,
        &notes_text,
        &settings,
        &mut |step| eprintln!("  [{:.1}s] {step}", started.elapsed().as_secs_f64()),
    )
    .expect("notes generate");
    eprintln!(
        "notes for {title:?} in {:.1}s:\n{}",
        started.elapsed().as_secs_f64(),
        notes.summary_markdown
    );
    eprintln!(
        "outcomes: {}",
        serde_json::to_string_pretty(&notes.outcomes).unwrap()
    );
    assert!(notes.summary_markdown.contains("## TL;DR"));
    runtime.shutdown();
}

#[test]
#[ignore = "needs the runtime and models from installs_runtime_downloads_models_and_answers"]
fn generates_a_digest_for_a_fixture_day() {
    let _ = env_logger::builder()
        .is_test(true)
        .filter_level(log::LevelFilter::Info)
        .try_init();
    let root = e2e_root();
    let model =
        std::env::var("LOKALBOT_E2E_MODEL").unwrap_or_else(|_| catalog::COMPACT_FALLBACK_ID.into());
    let settings = Settings {
        built_in_model_id: model,
        llama_backend: "auto".into(),
        ..Settings::default()
    };
    let runtime = RuntimeManager::new(LibraryPaths::new(&root), &settings);
    let think = ThinkClient::new(&runtime, &settings).unwrap();
    let (_dir, library) = fixture_library();
    let day = chrono::NaiveDate::from_ymd_opt(2026, 10, 17).unwrap();
    let started = Instant::now();
    let (markdown, meta) =
        lokalbot_ai::digest::generate_day_digest(&think, &library, day, &settings, &mut |step| {
            eprintln!("  [{:.1}s] {step}", started.elapsed().as_secs_f64())
        })
        .expect("digest generates");
    eprintln!(
        "digest for {day} in {:.1}s (quality {:?}):\n{markdown}",
        started.elapsed().as_secs_f64(),
        meta.quality
    );
    library.save_digest(day, &markdown, &meta).unwrap();
    let parsed = library.day_digest(day).unwrap().unwrap();
    assert!(!parsed.tasks.is_empty());
    runtime.shutdown();
}

#[test]
#[ignore = "needs the runtime and models from installs_runtime_downloads_models_and_answers"]
fn asks_dictates_and_drafts_with_the_real_model() {
    let _ = env_logger::builder()
        .is_test(true)
        .filter_level(log::LevelFilter::Info)
        .try_init();
    let root = e2e_root();
    let model =
        std::env::var("LOKALBOT_E2E_MODEL").unwrap_or_else(|_| catalog::COMPACT_FALLBACK_ID.into());
    let mut settings = Settings {
        built_in_model_id: model,
        llama_backend: "auto".into(),
        ..Settings::default()
    };
    let runtime = RuntimeManager::new(LibraryPaths::new(&root), &settings);
    let think = ThinkClient::new(&runtime, &settings).unwrap();
    let (_dir, library) = fixture_library();
    let cancel = AtomicBool::new(false);

    let started = Instant::now();
    let indexed =
        lokalbot_ai::embeddings::index_pending(&runtime, &library, &cancel, &mut |_, _| {})
            .expect("index meetings");
    eprintln!(
        "indexed {indexed} meetings in {:.1}s",
        started.elapsed().as_secs_f64()
    );

    let started = Instant::now();
    let mut events = Vec::new();
    let message = lokalbot_ai::ask::answer(
        &think,
        &library,
        "What does Northwind need before a company-wide rollout?",
        &[],
        &lokalbot_ai::ask::AskScope::default(),
        &cancel,
        &mut |event| events.push(event),
    )
    .expect("ask answers");
    eprintln!(
        "ask in {:.1}s ({} events):\n{}",
        started.elapsed().as_secs_f64(),
        events.len(),
        message.text
    );
    assert!(!message.text.trim().is_empty());

    settings.dictation_intent = lokalbot_core::settings::DictationIntent::Compose;
    for speech in [
        "um so lets meet on friday at 3 pm and uh bring the slides",
        "draft a short reply saying friday works for me",
    ] {
        let started = Instant::now();
        let text = lokalbot_ai::dictation::prepare(&think, speech, &settings).expect("dictation");
        eprintln!(
            "dictation {speech:?} -> {text:?} in {:.1}s",
            started.elapsed().as_secs_f64()
        );
        assert!(!text.is_empty());
    }

    let meeting = library
        .list_meetings()
        .unwrap()
        .into_iter()
        .find(|m| m.title == "Customer call - Northwind")
        .expect("fixture meeting");
    let started = Instant::now();
    match lokalbot_ai::follow_up::generate(&think, &library, &meeting) {
        Ok(draft) => eprintln!(
            "follow-up in {:.1}s:\nSubject: {}\n{}",
            started.elapsed().as_secs_f64(),
            draft.subject,
            draft.body
        ),
        Err(err) => eprintln!("follow-up failed: {err:#}"),
    }

    if let Some(project) = library
        .projects()
        .unwrap()
        .into_iter()
        .find(|p| !p.meetings.is_empty())
    {
        let started = Instant::now();
        match lokalbot_ai::project_status::generate(&think, &library, &project) {
            Ok(summary) => eprintln!(
                "project {:?} in {:.1}s: {}\n{:#?}",
                project.name,
                started.elapsed().as_secs_f64(),
                summary.overview,
                summary.points
            ),
            Err(err) => eprintln!("project status failed: {err:#}"),
        }
    }
    runtime.shutdown();
}
