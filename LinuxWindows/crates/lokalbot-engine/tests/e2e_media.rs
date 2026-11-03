//! The media embedder with the real llama-server and the real projector. Needs the
//! network and about 1 GB of disk; run on a development machine:
//!
//! ```sh
//! LOKALBOT_E2E_ROOT=~/scratch-root cargo test -p lokalbot-engine --test e2e_media -- --ignored --nocapture
//! ```
//!
//! The Mac's 30 October parity run qualified its own build; this checks that the
//! Linux or Windows build takes the same request shapes and that a text's vector
//! matches the text-only embedder's, as search relies on.

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;

use lokalbot_ai::catalog;
use lokalbot_ai::media_embedder::MediaEmbedder;
use lokalbot_ai::think::dot;
use lokalbot_ai::{EmbeddingClient, RuntimeManager, download};
use lokalbot_core::files::crawler::crawl;
use lokalbot_core::files::index::FileIndex;
use lokalbot_core::files::search::{FileInterval, FileReader};
use lokalbot_core::files::{self, IndexOptions};
use lokalbot_core::{LibraryPaths, Settings};
use lokalbot_engine::files::image_sizing::{self, Rgb};
use lokalbot_engine::files::pass::{NoText, Pass};

fn root() -> PathBuf {
    std::env::var_os("LOKALBOT_E2E_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("lokalbot-media-e2e"))
}

fn square(red: u8, green: u8, blue: u8) -> Rgb {
    let (width, height) = (600, 400);
    let mut pixels = Vec::with_capacity(width * height * 3);
    for _ in 0..width * height {
        pixels.extend([red, green, blue]);
    }
    Rgb {
        width,
        height,
        pixels,
    }
}

#[test]
#[ignore = "downloads the llama.cpp runtime, the embedder and its projector"]
fn the_projector_embeds_pictures_sound_and_text_and_a_pass_finds_them() {
    let paths = LibraryPaths::new(root());
    let settings = Settings {
        llama_backend: std::env::var("LOKALBOT_E2E_BACKEND").unwrap_or_else(|_| "cpu".into()),
        ..Settings::default()
    };
    let cancel = AtomicBool::new(false);
    let runtime = RuntimeManager::new(paths.clone(), &settings);
    runtime
        .ensure_runtime(&settings, &cancel, &mut |_, _| {})
        .expect("runtime installs");
    eprintln!("llama.cpp: {:?}", runtime.installed_version());
    for entry in [catalog::embedding_entry(), catalog::projector_entry()] {
        if !catalog::is_downloaded(&paths, entry) {
            download::download(
                &catalog::download_spec(&paths, entry),
                &cancel,
                &mut |_, _| {},
            )
            .expect("downloads");
        }
    }
    let embedder = MediaEmbedder::start(&runtime).expect("the server starts with the projector");

    let text = "A quarterly budget review with the finance team";
    let vectors = embedder
        .embed_texts(&[text.to_string()])
        .expect("embeds text");
    assert_eq!(vectors[0].len(), 768);
    assert!((dot(&vectors[0], &vectors[0]) - 1.0).abs() < 1e-3);

    // A text's vector here must match the text-only embedder's: searches embed
    // their words there and score against the index.
    let client = EmbeddingClient::new(&runtime);
    let plain = client
        .embed(&[text.to_string()], "")
        .expect("the text embedder answers");
    let same = dot(&vectors[0], &plain[0]);
    eprintln!("text vs text-only embedder cosine: {same}");
    assert!(same > 0.999, "{same}");

    // Each medium as a typed part, at the budgets the indexer uses.
    let mut seen = Vec::new();
    for (budget, picture) in [
        (140, square(200, 30, 30)),
        (280, square(30, 30, 200)),
        (70, square(30, 200, 30)),
    ] {
        let png = image_sizing::png(&picture, budget).expect("sizes");
        let started = std::time::Instant::now();
        let vector = embedder.embed_image(&png).expect("embeds a picture");
        eprintln!(
            "picture at budget {budget}: {:.2} s",
            started.elapsed().as_secs_f64()
        );
        assert_eq!(vector.len(), 768);
        assert!((dot(&vector, &vector) - 1.0).abs() < 1e-3);
        seen.push(vector);
    }
    assert!(
        dot(&seen[0], &seen[1]) < 0.9999,
        "different pictures differ"
    );

    let samples: Vec<f32> = (0..16_000 * 10)
        .map(|i| (i as f32 * 0.05).sin() * 0.4)
        .collect();
    let wav = lokalbot_audio::wav_bytes(&samples, 16_000);
    let started = std::time::Instant::now();
    let sound = embedder.embed_audio(&wav).expect("embeds sound");
    eprintln!("10 s of sound: {:.2} s", started.elapsed().as_secs_f64());
    assert_eq!(sound.len(), 768);
    assert!((dot(&sound, &sound) - 1.0).abs() < 1e-3);

    // A text longer than one batch is cut to fit, not refused.
    let long = "word ".repeat(4_000);
    assert_eq!(embedder.embed_texts(&[long]).expect("cuts").len(), 1);

    // A whole pass over a folder, then a search by meaning without its words.
    let folder = root().join("folder");
    std::fs::create_dir_all(&folder).unwrap();
    const TOPICS: [&str; 24] = [
        "Hiking routes through the mountains and where to camp overnight.",
        "A recipe for sourdough bread with a long cold fermentation.",
        "Notes on repairing a bicycle chain and adjusting the gears.",
        "The history of the Roman aqueducts and how they carried water.",
        "How to prune apple trees in late winter for a better harvest.",
        "A guide to watching migratory birds along the northern coast.",
        "Tips for learning the violin as an adult beginner.",
        "The rules of chess openings and common traps for new players.",
        "Planning a kitchen renovation with new cabinets and tiles.",
        "A description of volcanic islands and how they form in the ocean.",
        "Caring for houseplants that prefer low light and little water.",
        "A short story about a lighthouse keeper and a stranded sailor.",
        "How noise cancelling headphones reduce sound with inverted waves.",
        "Training plan for a first marathon over sixteen weeks of running.",
        "Choosing a telescope for watching planets from a city balcony.",
        "A review of a new science fiction novel about a generation ship.",
        "How honey bees communicate the location of flowers by dancing.",
        "Knitting a winter scarf with a simple rib stitch pattern.",
        "The basics of sailing a small dinghy in light summer wind.",
        "Restoring an old wooden chair with oil and careful sanding.",
        "How glaciers carve valleys and leave moraines behind them.",
        "A travel diary from a train journey across the Trans-Siberian line.",
        "Making pottery on a wheel and firing glazed mugs at home.",
        "Understanding tides and why they change through the lunar month.",
    ];
    for (index, topic) in TOPICS.iter().enumerate() {
        std::fs::write(folder.join(format!("note{index}.md")), topic).unwrap();
    }
    std::fs::write(
        folder.join("forecast.md"),
        "Next year's budget: revenue is projected to grow while spending on salaries and rent stays flat, and the finance team expects a modest profit.",
    )
    .unwrap();
    image::RgbImage::from_pixel(600, 400, image::Rgb([200, 30, 30]))
        .save(folder.join("red.png"))
        .unwrap();
    let directory = files::index_dir(paths.root());
    let _ = std::fs::remove_dir_all(&directory);
    let index = FileIndex::open(&directory).unwrap();
    let options = IndexOptions::default();
    let folders = [folder.to_string_lossy().into_owned()];
    let report = crawl(std::slice::from_ref(&folder), &options, &mut |_| {});
    let summary = index.sync(&folders, &report.candidates).unwrap();
    assert_eq!(summary.added, TOPICS.len() + 2);
    let mut words = NoText;
    let scratch = root().join("scratch");
    let started = std::time::Instant::now();
    let mut pass = Pass::new(&index, &options, &embedder, &mut words, &scratch);
    let (read, _) = pass.run(None, &mut || false, &mut |_| {}).unwrap();
    eprintln!(
        "read {read} files in {:.1} s",
        started.elapsed().as_secs_f64()
    );
    assert_eq!(read, TOPICS.len() + 2);
    assert_eq!(index.counts().unwrap().vectors, TOPICS.len() + 2);
    assert!(
        index
            .meta("fingerprint")
            .unwrap()
            .unwrap()
            .ends_with("photo140 shot280 page280 frame70/3.0s audio30.0/25.0s")
    );
    drop(index);

    let reader = FileReader::shared(paths.root());
    let query = "how much money will the company make";
    let vector = client.embed_query(query).expect("embeds the query");
    let by_meaning = reader.search(query, Some(&vector), &folders, FileInterval::default(), 5);
    eprintln!(
        "by meaning: {:?}",
        by_meaning.iter().map(|hit| hit.name()).collect::<Vec<_>>()
    );
    assert_eq!(by_meaning[0].name(), "forecast.md");
    assert!(
        by_meaning[0].is_semantic,
        "none of its words were asked for"
    );
    let by_words = reader.search("sourdough", None, &folders, FileInterval::default(), 5);
    assert_eq!(by_words.len(), 1);
    assert!(
        by_words[0]
            .excerpt
            .as_deref()
            .unwrap()
            .contains("«sourdough»")
    );
    reader.close();
    let _ = std::fs::remove_dir_all(&directory);
    let _ = std::fs::remove_dir_all(&folder);
}

/// Text vectors through the running engine, once a first search asks for them,
/// and a sealed capture's picture vector made in memory.
#[test]
#[ignore = "needs the runtime and models the test above downloads"]
fn screens_are_found_by_what_they_say_and_show() {
    use lokalbot_core::screen_search::{self, ScreenFilter};
    let root = root().join("screens");
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let source = self::root();
    for folder in ["models", "runtimes"] {
        let status = std::process::Command::new("cp")
            .arg("-al")
            .arg(source.join(folder))
            .arg(root.join(folder))
            .status()
            .unwrap();
        assert!(status.success());
    }
    let paths = LibraryPaths::new(&root);
    let library = lokalbot_core::Library::open(paths.clone()).unwrap();
    let topics = [
        (
            "Numbers",
            "Quarterly budget with projected revenue, salaries and the expected profit for next year.",
        ),
        (
            "Maps",
            "Hiking routes through the mountains and where to camp overnight in late summer.",
        ),
        (
            "Notes",
            "A recipe for sourdough bread with a long cold fermentation and a very hot oven.",
        ),
    ];
    let mut budget_screen = 0;
    for (index, (app, text)) in topics.iter().enumerate() {
        let id = library
            .record_screen_moment(&lokalbot_core::timeline::NewScreenMoment {
                ts: lokalbot_core::time::from_epoch(1_800_000_000.0 + index as f64 * 60.0),
                app: (*app).into(),
                window_title: "Window".into(),
                trigger: "manual".into(),
                text: (*text).into(),
                text_source: "ocr".into(),
                ..Default::default()
            })
            .unwrap();
        if index == 0 {
            budget_screen = id;
        }
    }
    drop(library);

    let library = lokalbot_core::Library::open(paths.clone()).unwrap();
    let settings = Settings {
        onboarding_completed: true,
        llama_backend: "cpu".into(),
        semantic_search_enabled: true,
        ..Settings::default()
    };
    let engine = lokalbot_engine::Engine::start(library.clone(), settings, |_| {}).unwrap();
    assert!(
        !library.has_screen_vectors().unwrap(),
        "nothing happens before a search by meaning"
    );
    screen_search::note_searched_by_meaning(paths.root());
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(120);
    while library.screen_documents_without_vectors(1).unwrap().len() == 1 {
        assert!(std::time::Instant::now() < deadline, "no vectors in time");
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    let query = "how much money will the company make";
    let vector = lokalbot_engine::query_vector(query).expect("the embedder answers");
    let model = lokalbot_ai::media_embedder::picture_model_id();
    let meanings = library
        .screen_meanings(&vector, &model, &ScreenFilter::default())
        .unwrap();
    assert_eq!(meanings.len(), 3);
    let best = meanings
        .iter()
        .max_by(|a, b| a.1.meaning.z.total_cmp(&b.1.meaning.z))
        .unwrap();
    assert_eq!(*best.0, budget_screen, "{meanings:?}");
    eprintln!("best screen z = {:.2}", best.1.meaning.z);

    // A sealed capture: decrypted in memory, sized, embedded, its vector stored.
    let key = lokalbot_core::screen::new_image_key();
    let picture = image::RgbImage::from_pixel(800, 500, image::Rgb([20, 120, 220]));
    let mut jpeg = Vec::new();
    picture
        .write_to(
            &mut std::io::Cursor::new(&mut jpeg),
            image::ImageFormat::Jpeg,
        )
        .unwrap();
    let sealed = lokalbot_core::screen::seal_image(&key, &jpeg).unwrap();
    let at = lokalbot_core::time::from_epoch(1_800_000_600.0);
    let file = lokalbot_core::screen::capture_file_path(paths.root(), at, uuid::Uuid::new_v4());
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, sealed).unwrap();
    let stored = file.to_string_lossy().into_owned();
    let id = library
        .record_screen_moment(&lokalbot_core::timeline::NewScreenMoment {
            ts: at,
            app: "Viewer".into(),
            window_title: "Picture".into(),
            trigger: "manual".into(),
            path: stored.clone(),
            ..Default::default()
        })
        .unwrap();
    let runtime = engine.runtime().clone();
    let session = MediaEmbedder::start(&runtime).unwrap();
    let lokalbot_engine::screen_vectors::Embedded::Vector(made) =
        lokalbot_engine::screen_vectors::embed_capture(&library, &key, &stored, &session)
    else {
        panic!("the sealed capture wasn't embedded");
    };
    assert_eq!(made.len(), 768);
    assert!(
        library
            .store_picture_vector(&model, id, &stored, Some(&made))
            .unwrap()
    );
    assert_eq!(library.picture_vector_count(&model).unwrap(), 1);
    let with_picture = library
        .screen_meanings(&vector, &model, &ScreenFilter::default())
        .unwrap();
    assert_eq!(
        with_picture[&id].meaning.modality,
        lokalbot_core::screen_search::Modality::Image
    );
    drop(session);
    drop(engine);
    let _ = std::fs::remove_dir_all(&root);
}
