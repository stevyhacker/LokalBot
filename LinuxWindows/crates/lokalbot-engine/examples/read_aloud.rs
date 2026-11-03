//! Reads text with the real pipeline, without the UI: downloads Kokoro if it
//! is missing, saves the speech to a WAV file and tries the speakers.
//!
//! `cargo run -p lokalbot-engine --example read_aloud -- <library> <out.wav> ["text"]`

use std::time::{Duration, Instant};

use anyhow::{Result, bail};
use lokalbot_core::{Library, LibraryPaths, Settings};
use lokalbot_engine::{Command, Engine, EngineEvent, SpeechCommand, SpeechStatus};

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (Some(root), Some(out)) = (args.first(), args.get(1)) else {
        bail!("usage: read_aloud <library> <out.wav> [\"text\"]");
    };
    let text = args
        .get(2)
        .cloned()
        .unwrap_or_else(|| "Here is a sample of LokalBot's voice.".to_string());
    let paths = LibraryPaths::new(root);
    let library = Library::open(paths.clone())?;
    let settings = Settings::load(&paths.settings_file());
    let (sender, receiver) = crossbeam_channel::unbounded();
    let engine = Engine::start(library, settings, move |event| {
        let _ = sender.send(event);
    })?;

    let clock = Instant::now();
    engine.send(Command::Speech(SpeechCommand::Export {
        text: text.clone(),
        path: out.into(),
    }));
    let done = |status: &SpeechStatus| !status.exporting;
    let status = wait_for(&receiver, &clock, done)?;
    if let Some((_, message)) = &status.error {
        bail!("the export failed: {message}");
    }
    let info = lokalbot_audio::read_info(std::path::Path::new(out))?;
    println!(
        "[{:6.1}s] saved {out}: {:.1}s at {} Hz",
        clock.elapsed().as_secs_f64(),
        info.duration_seconds(),
        info.sample_rate
    );

    engine.send(Command::Speech(SpeechCommand::Read {
        key: "example".into(),
        text,
    }));
    let finished = |status: &SpeechStatus| status.reading.is_none();
    let status = wait_for(&receiver, &clock, finished)?;
    match &status.error {
        Some((_, message)) => println!("speakers: {message}"),
        None => println!("[{:6.1}s] played", clock.elapsed().as_secs_f64()),
    }
    Ok(())
}

fn wait_for(
    receiver: &crossbeam_channel::Receiver<EngineEvent>,
    clock: &Instant,
    done: impl Fn(&SpeechStatus) -> bool,
) -> Result<SpeechStatus> {
    loop {
        match receiver.recv_timeout(Duration::from_secs(600))? {
            EngineEvent::Speech(status) => {
                println!("[{:6.1}s] {status:?}", clock.elapsed().as_secs_f64());
                if done(&status) {
                    return Ok(status);
                }
            }
            EngineEvent::Message { text, .. } => println!("message: {text}"),
            _ => {}
        }
    }
}
