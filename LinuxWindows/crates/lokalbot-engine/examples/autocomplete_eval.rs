//! Autocomplete on a real model, without the desktop: downloads the
//! Autocomplete model and the llama.cpp runtime into a scratch library
//! through the catalog and runtime code, seeds the demo library there, then
//! types realistic text into simulated fields through the engine and reports
//! the wait from the last keystroke to the suggestion.
//!
//! ```sh
//! cargo run -p lokalbot-engine --example autocomplete_eval -- <scratch dir> \
//!     [--backend auto|cpu|vulkan|cuda] [--model <catalog id>] [--debounce <ms>] [--key-ms <ms>]
//! ```
//!
//! The scratch directory must be empty or an earlier run's. Each case focuses
//! a field with all but the last few characters, types the rest one key at a
//! time, and waits for the first suggestion after the last key.

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, bail};
use crossbeam_channel::Receiver;
use lokalbot_ai::{RuntimeManager, catalog, download};
use lokalbot_core::{Library, LibraryPaths, Settings, demo};
use lokalbot_engine::{
    AutocompleteCommand, AutocompleteUpdate, Command, Engine, EngineEvent, FieldContext,
};

struct Case {
    name: &'static str,
    app_name: &'static str,
    app_id: &'static str,
    title: &'static str,
    visible: Option<&'static str>,
    url: Option<&'static str>,
    /// The text before the caret once typing is done.
    before: &'static str,
    after: &'static str,
    single_line: bool,
    /// Characters typed one key at a time at the end.
    typed: usize,
}

const MAIL: (&str, &str) = ("Thunderbird", "thunderbird");
const SLACK: (&str, &str) = ("Slack", "slack");
const CODE: (&str, &str) = ("Visual Studio Code", "code");
const FIREFOX: (&str, &str) = ("Firefox", "firefox");
const NOTES: (&str, &str) = ("Text Editor", "org.gnome.TextEditor");

fn case(
    name: &'static str,
    app: (&'static str, &'static str),
    title: &'static str,
    before: &'static str,
) -> Case {
    Case {
        name,
        app_name: app.0,
        app_id: app.1,
        title,
        visible: None,
        url: None,
        before,
        after: "",
        single_line: false,
        typed: 6,
    }
}

fn cases() -> Vec<Case> {
    vec![
        case(
            "email, next words",
            MAIL,
            "Re: Quarterly numbers - Mozilla Thunderbird",
            "Hi Sarah,\n\nThanks for sending over the quarterly numbers. I went through the revenue breakdown with the team this morning, and I wanted to follow",
        ),
        case(
            "email, mid-word",
            MAIL,
            "Partnership proposal - Mozilla Thunderbird",
            "Dear Mr. Thompson,\n\nI hope this message finds you well. I am writing to confi",
        ),
        case(
            "email, after a full stop",
            MAIL,
            "Launch update - Mozilla Thunderbird",
            "Hi team,\n\nQuick update on the launch: the beta went out to forty customers yesterday and the feedback has been positive. ",
        ),
        case(
            "email, sign-off",
            MAIL,
            "Re: Invoice 1042 - Mozilla Thunderbird",
            "Hi Marko,\n\nThe invoice is attached. Let me know if anything is missing.\n\nBest",
        ),
        Case {
            visible: Some(
                "Ana Kovač: Are we still on for lunch tomorrow?\nAna Kovač: I booked the place near the office.",
            ),
            single_line: true,
            ..case(
                "chat reply, after a comma",
                SLACK,
                "Ana Kovač (DM) - Slack",
                "Yes, see you ",
            )
        },
        Case {
            visible: Some("Marko: did the deploy go out?"),
            single_line: true,
            ..case(
                "chat reply, next words",
                SLACK,
                "#backend (Channel) - Slack",
                "Not yet, I'm waiting for the",
            )
        },
        Case {
            single_line: true,
            ..case(
                "chat, mid-word",
                SLACK,
                "#design (Channel) - Slack",
                "Sounds good, I'll send the mockups over tomor",
            )
        },
        case(
            "code comment, Rust",
            CODE,
            "client.rs - lokalbot - Visual Studio Code",
            "    // Retry the request up to three times before giving",
        ),
        case(
            "code comment, Python",
            CODE,
            "config.py - tools - Visual Studio Code",
            "def load_config(path):\n    # Parse the config file and return a dictionary of",
        ),
        Case {
            after: "eive the files",
            typed: 3,
            ..case(
                "caret inside a word",
                NOTES,
                "Notes",
                "Please let me know when you rec",
            )
        },
        case(
            "commit message",
            NOTES,
            "COMMIT_EDITMSG",
            "Fix a crash when the window is closed while a download is",
        ),
        Case {
            url: Some("https://docs.google.com/document/d/1x2y3z/edit"),
            ..case(
                "document, after a colon",
                FIREFOX,
                "Q3 plan - Google Docs — Mozilla Firefox",
                "Q3 plan\n\nOur main goal for this quarter is to reduce churn in the enterprise segment. To get there we will:",
            )
        },
        case(
            "notes, list item",
            NOTES,
            "Meeting notes",
            "Meeting notes, Tuesday\n\n- Decided to move the launch to",
        ),
        case(
            "question",
            MAIL,
            "Re: Office move - Mozilla Thunderbird",
            "Hi Lena,\n\nCould you let me know when you are",
        ),
        case(
            "German",
            MAIL,
            "Re: Termin - Mozilla Thunderbird",
            "Hallo Jonas,\n\nvielen Dank für deine Nachricht. Ich melde mich",
        ),
        Case {
            single_line: true,
            ..case(
                "Montenegrin",
                SLACK,
                "Marija (DM) - Slack",
                "Hvala na poruci, javiću ti se",
            )
        },
        case(
            "memory: Northwind captions",
            MAIL,
            "Re: Northwind first cut - Mozilla Thunderbird",
            "Hi Priya,\n\nThanks for the notes on the first cut. The captioned Northwind",
        ),
        case(
            "memory: laptop quote",
            MAIL,
            "Laptop refresh - Mozilla Thunderbird",
            "Hi John,\n\nQuick check on the laptop refresh: did the vendor send the business",
        ),
        case(
            "memory: editor candidate",
            SLACK,
            "Maya Chen (DM) - Slack",
            "About the editor candidate from the hiring debrief: the last step is",
        ),
        Case {
            typed: 3,
            ..case(
                "emoji shortcode",
                SLACK,
                "#launch (Channel) - Slack",
                "Shipped the beta :roc",
            )
        },
    ]
}

struct Outcome {
    name: &'static str,
    suggestion: Option<String>,
    latency_ms: Option<f64>,
    /// The text before the caret after the last key.
    before: String,
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let Some(root) = args
        .first()
        .filter(|a| !a.starts_with("--"))
        .map(PathBuf::from)
    else {
        bail!(
            "usage: autocomplete_eval <scratch dir> [--backend auto|cpu|vulkan|cuda] [--model id] [--debounce ms] [--key-ms ms]"
        );
    };
    let backend = flag("--backend").unwrap_or_else(|| "auto".into());
    let model_id =
        flag("--model").unwrap_or_else(|| Settings::default().cotyping_built_in_model_id);
    let debounce: u32 = flag("--debounce")
        .map(|v| v.parse())
        .transpose()?
        .unwrap_or(160);
    let key_ms: u64 = flag("--key-ms")
        .map(|v| v.parse())
        .transpose()?
        .unwrap_or(140);
    let paths = LibraryPaths::new(&root);

    // The demo library has people, projects and meetings to remember.
    let fresh = !root.exists() || std::fs::read_dir(&root)?.next().is_none();
    if fresh {
        demo::seed(&paths, chrono::Utc::now()).context("seeding the demo library")?;
        eprintln!("seeded the demo library in {}", root.display());
    } else if !root.join(demo::DEMO_MARKER).is_file() {
        bail!(
            "{} is not empty and not an earlier run's demo library",
            root.display()
        );
    }

    let mut settings = Settings::load(&paths.settings_file());
    settings.cotyping_enabled = true;
    settings.cotyping_use_meeting_memory = true;
    settings.cotyping_built_in_model_id = model_id.clone();
    settings.cotyping_debounce_ms = debounce;
    settings.llama_backend = backend.clone();
    settings.save(&paths.settings_file())?;
    let entry =
        catalog::entry(&model_id).with_context(|| format!("no catalog entry {model_id}"))?;

    // Downloads through the catalog and the runtime manager, as Settings →
    // Models does. Nothing here is downloaded by Autocomplete itself.
    let cancel = AtomicBool::new(false);
    let started = Instant::now();
    RuntimeManager::new(paths.clone(), &settings).ensure_runtime(
        &settings,
        &cancel,
        &mut progress("runtime"),
    )?;
    download::download(
        &catalog::download_spec(&paths, entry),
        &cancel,
        &mut progress(entry.id),
    )?;
    eprintln!(
        "model and runtime ready in {:.1}s",
        started.elapsed().as_secs_f64()
    );

    let library = Library::open(paths.clone())?;
    let (sender, events) = crossbeam_channel::unbounded();
    let engine = Engine::start(library, settings, move |event| {
        if let EngineEvent::Autocomplete(update) = event {
            let _ = sender.send((Instant::now(), update));
        }
    })?;

    // Starts the server and loads the model; not measured.
    let started = Instant::now();
    let warm = case(
        "warm-up",
        NOTES,
        "Warm-up",
        "This is a short warm-up sentence to load the",
    );
    let warm_up = run(
        &engine,
        &events,
        &warm,
        1,
        key_ms,
        Duration::from_secs(120),
        true,
    );
    eprintln!(
        "warm-up (server start and model load) took {:.1}s: {:?}",
        started.elapsed().as_secs_f64(),
        warm_up.suggestion
    );

    let mut outcomes = Vec::new();
    let facts_library = Library::open_read_only(paths.clone())?;
    let settings = Settings::load(&paths.settings_file());
    for (index, case) in cases().iter().enumerate() {
        {
            let field = FieldContext {
                app_name: case.app_name.into(),
                app_id: case.app_id.into(),
                window_title: case.title.into(),
                before: case.before.into(),
                visible_text: case.visible.map(String::from),
                ..FieldContext::default()
            };
            for (title, fact) in
                lokalbot_engine::autocomplete_saved_facts(&facts_library, &field, &settings)
            {
                eprintln!("  saved fact from \"{title}\": {fact}");
            }
        }
        let outcome = run(
            &engine,
            &events,
            case,
            100 + index as u64,
            key_ms,
            Duration::from_secs(8),
            true,
        );
        eprintln!(
            "{:<28} {:>8}  {:?}",
            outcome.name,
            outcome
                .latency_ms
                .map_or("—".into(), |ms| format!("{ms:.0} ms")),
            outcome.suggestion.as_deref().unwrap_or("(none)")
        );
        outcomes.push(outcome);
    }
    // Accepting word by word keeps the ghost a few words ahead: each Tab
    // shortens it at once, and a top-up appends more once two words are left.
    let flows: Vec<(Case, Vec<Step>)> = [
        case(
            "email",
            MAIL,
            "Re: Quarterly numbers - Mozilla Thunderbird",
            "Hi Sarah,\n\nThanks for sending over the quarterly numbers. I went through the revenue breakdown with the team this morning, and I wanted to follow",
        ),
        case(
            "notes",
            NOTES,
            "Release notes",
            "Release notes\n\nThis version improves the startup time and fixes a crash that happened when",
        ),
    ]
    .into_iter()
    .enumerate()
    .map(|(index, case)| {
        let steps = accept_word_by_word(&engine, &events, &case, 500 + index as u64, key_ms, 6);
        (case, steps)
    })
    .collect();
    drop(engine);

    for (case, steps) in &flows {
        println!(
            "\nAccepting word by word ({}): …{}",
            case.name,
            tail(case.before, 40)
        );
        for step in steps {
            // A used-up suggestion is followed by a new one, not topped up.
            let what = if step.used_up {
                "next suggestion"
            } else {
                "topped up"
            };
            println!(
                "- Tab takes `{}`, ghost now `{}`{}",
                step.chunk,
                step.ghost,
                step.grew_ms
                    .map(|ms| format!(" ({what} {ms:.0} ms after the Tab)"))
                    .unwrap_or_default()
            );
        }
    }

    let mut latencies: Vec<f64> = outcomes.iter().filter_map(|o| o.latency_ms).collect();
    latencies.sort_by(f64::total_cmp);
    let percentile = |p: f64| -> f64 {
        if latencies.is_empty() {
            return f64::NAN;
        }
        let rank = ((p / 100.0) * latencies.len() as f64).ceil() as usize;
        latencies[rank.clamp(1, latencies.len()) - 1]
    };
    println!("\n| Case | Suggestion | Last key → suggestion |");
    println!("| --- | --- | --- |");
    for outcome in &outcomes {
        println!(
            "| {} | {} | {} |",
            outcome.name,
            outcome
                .suggestion
                .as_deref()
                .map_or("(none)".to_string(), |s| format!(
                    "`{}`",
                    s.replace('\n', "⏎")
                )),
            outcome
                .latency_ms
                .map_or("—".into(), |ms| format!("{ms:.0} ms"))
        );
    }
    println!(
        "\nmodel {model_id}, backend {backend}, debounce {debounce} ms, {key_ms} ms per key: {} of {} cases got a suggestion; p50 {:.0} ms, p95 {:.0} ms, max {:.0} ms",
        latencies.len(),
        outcomes.len(),
        percentile(50.0),
        percentile(95.0),
        latencies.last().copied().unwrap_or(f64::NAN)
    );
    Ok(())
}

fn context(case: &Case, field_id: u64, before: &str) -> FieldContext {
    FieldContext {
        field_id,
        app_name: case.app_name.into(),
        app_id: case.app_id.into(),
        window_title: case.title.into(),
        before: before.into(),
        after: case.after.into(),
        visible_text: case.visible.map(String::from),
        url: case.url.map(String::from),
        single_line: case.single_line,
    }
}

fn tail(text: &str, n: usize) -> String {
    let count = text.chars().count();
    text.chars()
        .skip(count.saturating_sub(n))
        .collect::<String>()
        .replace('\n', "⏎")
}

struct Step {
    chunk: String,
    ghost: String,
    grew_ms: Option<f64>,
    /// The Tab took the rest of the suggestion.
    used_up: bool,
}

/// Types a case, then presses Tab `presses` times the way the desktop does:
/// it inserts `accept_chunk` of the ghost, reports it, and the field shows it.
fn accept_word_by_word(
    engine: &Engine,
    events: &Receiver<(Instant, AutocompleteUpdate)>,
    case: &Case,
    field_id: u64,
    key_ms: u64,
    presses: usize,
) -> Vec<Step> {
    let first = run(
        engine,
        events,
        case,
        field_id,
        key_ms,
        Duration::from_secs(8),
        false,
    );
    let mut steps = Vec::new();
    let mut ghost = first.suggestion.unwrap_or_default();
    let mut before = first.before;
    for _ in 0..presses {
        let chunk = lokalbot_ai::autocomplete::accept_chunk(
            &ghost,
            lokalbot_core::settings::AcceptGranularity::Word,
        );
        if chunk.is_empty() {
            break;
        }
        let expected = ghost[chunk.len()..].to_string();
        before.push_str(&chunk);
        let accepted_at = Instant::now();
        engine.send(Command::Autocomplete(AutocompleteCommand::Accepted {
            field_id,
            text: chunk.clone(),
        }));
        engine.send(Command::Autocomplete(AutocompleteCommand::Context(
            context(case, field_id, &before),
        )));
        let mut latest = expected.clone();
        let mut grew_ms = None;
        let deadline = accepted_at + Duration::from_millis(1_200);
        while let Ok((at, update)) = events.recv_deadline(deadline) {
            match update {
                AutocompleteUpdate::Suggestion { field_id: id, text } if id == field_id => {
                    if grew_ms.is_none()
                        && text.len() > expected.len()
                        && text.starts_with(&expected)
                    {
                        grew_ms = Some(at.duration_since(accepted_at).as_secs_f64() * 1000.0);
                    }
                    latest = text;
                }
                AutocompleteUpdate::Clear => latest.clear(),
                _ => {}
            }
        }
        steps.push(Step {
            chunk,
            ghost: latest.clone(),
            grew_ms,
            used_up: expected.is_empty(),
        });
        ghost = latest;
    }
    engine.send(Command::Autocomplete(AutocompleteCommand::Dismiss));
    std::thread::sleep(Duration::from_millis(150));
    while events.try_recv().is_ok() {}
    steps
}

/// Focuses a field, types the case's last characters, and waits for the
/// first suggestion after the last key.
fn run(
    engine: &Engine,
    events: &Receiver<(Instant, AutocompleteUpdate)>,
    case: &Case,
    field_id: u64,
    key_ms: u64,
    timeout: Duration,
    dismiss: bool,
) -> Outcome {
    let chars: Vec<char> = case.before.chars().collect();
    let split = chars.len().saturating_sub(case.typed);
    let mut before: String = chars[..split].iter().collect();
    let send = |before: &str| {
        engine.send(Command::Autocomplete(AutocompleteCommand::Context(
            context(case, field_id, before),
        )));
    };
    // Focus: the engine reads the field's prompt ahead and looks up facts.
    send(&before);
    std::thread::sleep(Duration::from_millis(900));
    let mut last_key = Instant::now();
    for (i, c) in chars[split..].iter().enumerate() {
        if i > 0 {
            std::thread::sleep(Duration::from_millis(key_ms));
        }
        before.push(*c);
        last_key = Instant::now();
        send(&before);
    }
    let deadline = last_key + timeout;
    let mut result = Outcome {
        name: case.name,
        suggestion: None,
        latency_ms: None,
        before: before.clone(),
    };
    while let Ok((at, update)) = events.recv_deadline(deadline) {
        if at < last_key {
            continue;
        }
        if let AutocompleteUpdate::Suggestion { field_id: id, text } = update
            && id == field_id
        {
            result.suggestion = Some(text);
            result.latency_ms = Some(at.duration_since(last_key).as_secs_f64() * 1000.0);
            break;
        }
    }
    if dismiss {
        engine.send(Command::Autocomplete(AutocompleteCommand::Dismiss));
        std::thread::sleep(Duration::from_millis(150));
        while events.try_recv().is_ok() {}
    }
    result
}

fn progress(label: &'static str) -> impl FnMut(u64, u64) {
    let mut last = 0u64;
    move |done, total| {
        let step = (total / 4).max(1);
        if total > 0 && (done == total || done >= last + step) {
            last = done;
            eprintln!(
                "  {label}: {:.0}% of {:.0} MB",
                done as f64 * 100.0 / total as f64,
                total as f64 / 1e6
            );
        }
    }
}
