//! Runs one recording through the real pipeline without the UI: transcription,
//! speaker attribution, notes and actions, indexing, and optionally Ask.
//!
//! `cargo run -p lokalbot-engine --example process_meeting -- <library> <mic.wav> [system.wav] [--prepare] [--ask "question"]`
//!
//! `--prepare` first downloads the models `settings.json` selects, the way
//! Settings → Models does; without it the library must already hold them.
//! `--ask` then asks a question across the library and prints the answer.

use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, bail};
use crossbeam_channel::Receiver;
use lokalbot_core::{Library, LibraryPaths, Settings};
use lokalbot_engine::{AskScope, AskUpdate, Command, Engine, EngineEvent, Stage};
use uuid::Uuid;

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();
    let mut positional = Vec::new();
    let mut prepare = false;
    let mut question = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--prepare" => prepare = true,
            "--ask" => question = args.next(),
            _ => positional.push(arg),
        }
    }
    let (Some(root), Some(mic)) = (positional.first(), positional.get(1)) else {
        bail!(
            "usage: process_meeting <library> <mic.wav> [system.wav] [--prepare] [--ask \"question\"]"
        );
    };
    let system = positional.get(2);
    let paths = LibraryPaths::new(root);
    let library = Library::open(paths.clone())?;
    let settings = Settings::load(&paths.settings_file());

    let (sender, receiver) = crossbeam_channel::unbounded();
    let engine = Engine::start(library.clone(), settings, move |event| {
        let _ = sender.send(event);
    })?;
    let clock = Instant::now();
    if prepare {
        prepare_models(&engine, &receiver, &clock)?;
    }

    let started = lokalbot_core::time::now_seconds() - chrono::Duration::minutes(5);
    let mut meeting = library.create_meeting("Pipeline check", "Test call", started)?;
    let dir = library.meeting_dir(&meeting);
    std::fs::copy(mic, dir.join("mic.wav")).context("copying the mic track")?;
    if let Some(system) = system {
        std::fs::copy(system, dir.join("system.wav")).context("copying the system track")?;
        meeting.has_system_track = true;
    }
    meeting.ended_at = Some(lokalbot_core::time::now_seconds());
    library.save_meeting(&meeting)?;

    let processing = Instant::now();
    engine.send(Command::ProcessMeeting {
        meeting_id: meeting.id,
        transcribe: true,
        summarize: true,
    });
    loop {
        match next(&receiver, &clock)? {
            EngineEvent::Processing { meeting_id, stage } if meeting_id == meeting.id => {
                match stage {
                    Some(Stage::Failed(message)) => bail!("processing failed: {message}"),
                    Some(Stage::WaitingForModels) => {
                        bail!("the library is missing models for these settings (try --prepare)")
                    }
                    Some(stage) => println!("[{:>6.1}s] {stage:?}", clock.elapsed().as_secs_f64()),
                    None => break,
                }
            }
            EngineEvent::Message {
                text,
                is_error: true,
            } => eprintln!("error: {text}"),
            _ => {}
        }
    }
    println!("processed in {:.1}s\n", processing.elapsed().as_secs_f64());
    let transcript = library.transcript(&meeting)?.unwrap_or_default();
    println!(
        "=== transcript ({} segments, engine {})\n{}\n",
        transcript.segments.len(),
        transcript.engine,
        transcript.markdown()
    );
    println!(
        "=== summary.md\n{}",
        library.summary(&meeting)?.unwrap_or_default()
    );
    let outcomes = library.outcomes(&meeting)?.unwrap_or_default();
    println!(
        "=== outcomes: {} actions, {} decisions, {} open questions\n",
        outcomes.action_items.len(),
        outcomes.decision_records.len(),
        outcomes.open_questions.len()
    );

    if let Some(question) = question {
        ask(&engine, &receiver, &library, &clock, &question)?;
    }
    drop(engine);
    Ok(())
}

fn next(receiver: &Receiver<EngineEvent>, clock: &Instant) -> Result<EngineEvent> {
    let deadline = Duration::from_secs(60 * 60);
    receiver
        .recv_timeout(deadline.saturating_sub(clock.elapsed()))
        .map_err(|_| anyhow::anyhow!("timed out after {:?}", clock.elapsed()))
}

/// Downloads whatever the settings need and waits until every role is ready.
fn prepare_models(
    engine: &Engine,
    receiver: &Receiver<EngineEvent>,
    clock: &Instant,
) -> Result<()> {
    engine.send(Command::PrepareModels);
    let mut reported: std::collections::HashMap<String, u64> = Default::default();
    loop {
        match next(receiver, clock)? {
            EngineEvent::Models(status) => {
                if status.transcription_ready && status.think_ready && status.embeddings_ready {
                    println!(
                        "[{:>6.1}s] models ready (runtime: {})",
                        clock.elapsed().as_secs_f64(),
                        status.runtime_backend.unwrap_or_default()
                    );
                    return Ok(());
                }
            }
            EngineEvent::Download(update) => {
                if let Some(error) = update.error {
                    bail!("downloading {} failed: {error}", update.id);
                }
                let percent = (update.done_bytes * 100)
                    .checked_div(update.total_bytes)
                    .unwrap_or(0);
                let last = reported.entry(update.id.clone()).or_insert(u64::MAX);
                if update.finished || *last == u64::MAX || percent >= last.wrapping_add(25) {
                    *last = percent;
                    println!(
                        "[{:>6.1}s] {} {}",
                        clock.elapsed().as_secs_f64(),
                        update.id,
                        if update.finished {
                            "downloaded".to_string()
                        } else {
                            format!("{percent}% of {} MB", update.total_bytes / 1_000_000)
                        }
                    );
                }
            }
            EngineEvent::Message { text, is_error } => {
                if is_error {
                    bail!("{text}");
                }
                println!("[{:>6.1}s] {text}", clock.elapsed().as_secs_f64());
            }
            _ => {}
        }
    }
}

/// Asks across the whole library and prints the saved answer.
fn ask(
    engine: &Engine,
    receiver: &Receiver<EngineEvent>,
    library: &Library,
    clock: &Instant,
    question: &str,
) -> Result<()> {
    let conversation_id = Uuid::new_v4();
    let asked = Instant::now();
    engine.send(Command::Ask {
        conversation_id,
        question: question.to_string(),
        scope: AskScope {
            include_meetings: true,
            ..Default::default()
        },
    });
    let mut first_text = None;
    loop {
        match next(receiver, clock)? {
            EngineEvent::Ask(AskUpdate::Progress { text, .. }) => {
                if first_text.is_none() && !text.is_empty() {
                    first_text = Some(asked.elapsed());
                }
            }
            EngineEvent::Ask(AskUpdate::Finished { .. }) => break,
            EngineEvent::Ask(AskUpdate::Failed { message, .. }) => bail!("ask failed: {message}"),
            _ => {}
        }
    }
    let conversation = library
        .conversations()?
        .into_iter()
        .find(|c| c.id == conversation_id)
        .context("the conversation was not saved")?;
    let answer = conversation.messages.last().context("no answer saved")?;
    println!(
        "=== ask: {question}\n(first text after {:.1}s, done after {:.1}s)\n{}\n\nsteps: {}",
        first_text.unwrap_or_default().as_secs_f64(),
        asked.elapsed().as_secs_f64(),
        answer.text,
        answer
            .activity
            .iter()
            .map(|a| a.text.as_str())
            .collect::<Vec<_>>()
            .join(" · ")
    );
    Ok(())
}
