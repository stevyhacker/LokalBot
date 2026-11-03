//! Runs Check model setup without the UI, as Settings does.
//!
//! `cargo run -p lokalbot-engine --example check_models -- <library> [--prepare] [transcribe|think|autocomplete]...`
//!
//! `--prepare` downloads what the current settings need for Transcribe first.

use std::time::Duration;

use anyhow::{Result, bail};
use lokalbot_core::{Library, LibraryPaths, Settings};
use lokalbot_engine::{Command, Engine, EngineEvent, ModelRole};

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(root) = args.first() else {
        bail!("usage: check_models <library> [--prepare] [transcribe|think|autocomplete]...");
    };
    let prepare = args.iter().any(|arg| arg == "--prepare");
    let mut roles: Vec<ModelRole> = args[1..]
        .iter()
        .filter_map(|arg| match arg.as_str() {
            "transcribe" => Some(ModelRole::Transcribe),
            "think" => Some(ModelRole::Think),
            "autocomplete" => Some(ModelRole::Autocomplete),
            _ => None,
        })
        .collect();
    if roles.is_empty() {
        roles = ModelRole::ALL.to_vec();
    }
    let paths = LibraryPaths::new(root);
    let library = Library::open(paths.clone())?;
    let settings = Settings::load(&paths.settings_file());
    let (sender, receiver) = crossbeam_channel::unbounded();
    let engine = Engine::start(library, settings.clone(), move |event| {
        let _ = sender.send(event);
    })?;
    // `--download <id>` fetches one model through the chosen download source.
    if let Some(index) = args.iter().position(|arg| arg == "--download") {
        let id = args.get(index + 1).map(String::as_str).unwrap_or_default();
        engine.send(Command::DownloadModel(id.to_string()));
        return wait_for_download(&receiver, id);
    }
    if prepare {
        for id in lokalbot_speech::models::supporting_ids(false) {
            engine.send(Command::DownloadModel(id.clone()));
            wait_for_download(&receiver, &id)?;
        }
        if !lokalbot_speech::models::is_remote(&settings.transcription_model) {
            engine.send(Command::DownloadModel(settings.transcription_model.clone()));
            wait_for_download(&receiver, &settings.transcription_model)?;
        }
    }
    engine.send(Command::CheckModels(roles));
    loop {
        if let EngineEvent::ModelChecks(status) = receiver.recv_timeout(Duration::from_secs(600))? {
            println!("testing: {:?}", status.testing);
            if !status.running {
                for result in &status.results {
                    println!(
                        "{:?}: {:.1}s {}",
                        result.role,
                        result.elapsed_seconds,
                        result.failure.as_deref().unwrap_or("passed")
                    );
                }
                return Ok(());
            }
        }
    }
}

fn wait_for_download(receiver: &crossbeam_channel::Receiver<EngineEvent>, id: &str) -> Result<()> {
    loop {
        if let EngineEvent::Download(update) = receiver.recv_timeout(Duration::from_secs(600))?
            && update.id == id
        {
            if let Some(error) = update.error {
                bail!("{id}: {error}");
            }
            if update.finished {
                println!("{id}: ready");
                return Ok(());
            }
        }
    }
}
