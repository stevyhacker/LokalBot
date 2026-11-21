use std::path::PathBuf;
use std::time::Instant;

use anyhow::{Context as _, Result, bail};
use lokalbot_ai::ThinkClient;
use lokalbot_ai::notes::{NotesOptions, generate_meeting_notes_with};
use lokalbot_core::settings::ReasoningLevel;
use lokalbot_core::{Meeting, Settings, Transcript};

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [transcript, out, base, token, model, rest @ ..] = args.as_slice() else {
        bail!(
            "usage: notes_replay <transcript.json> <out dir> <llama-server /v1 url> <token> <model id> [reasoning level]"
        );
    };
    let level: ReasoningLevel = match rest.first() {
        Some(level) => serde_json::from_value(serde_json::Value::String(level.clone()))
            .with_context(|| format!("unknown reasoning level {level}"))?,
        None => ReasoningLevel::Automatic,
    };
    let transcript: Transcript = serde_json::from_slice(
        &std::fs::read(transcript).with_context(|| format!("reading {transcript}"))?,
    )?;
    let out = PathBuf::from(out);
    std::fs::create_dir_all(&out)?;
    let think = ThinkClient::llama_server(base, token, model).with_reasoning_level(level);
    let meeting = Meeting::new(
        "Replay",
        "Benchmark",
        chrono::Utc::now() - chrono::Duration::minutes(30),
        "replay",
    );
    let settings = Settings::default();
    let options = NotesOptions {
        checkpoint_dir: Some(out.clone()),
        ..NotesOptions::default()
    };
    let started = Instant::now();
    let result = generate_meeting_notes_with(
        &think,
        &meeting,
        &transcript,
        "",
        &settings,
        &options,
        &mut |stage| eprintln!("[{:>7.1}s] {stage}", started.elapsed().as_secs_f64()),
    );
    let seconds = started.elapsed().as_secs_f64();
    match result {
        Ok(notes) => {
            std::fs::write(out.join("summary.md"), &notes.summary_markdown)?;
            std::fs::write(
                out.join("outcomes.json"),
                serde_json::to_vec_pretty(&notes.outcomes)?,
            )?;
            std::fs::write(
                out.join("claims.json"),
                serde_json::to_vec_pretty(&notes.claims)?,
            )?;
            std::fs::write(
                out.join("replay.json"),
                serde_json::to_vec_pretty(&serde_json::json!({
                    "model": model, "level": rest.first(), "seconds": seconds, "outcome": "complete",
                }))?,
            )?;
            println!("complete in {seconds:.1}s");
            Ok(())
        }
        Err(error) => {
            std::fs::write(
                out.join("replay.json"),
                serde_json::to_vec_pretty(&serde_json::json!({
                    "model": model, "level": rest.first(), "seconds": seconds,
                    "outcome": "failed", "error": error.to_string(),
                }))?,
            )?;
            bail!("failed after {seconds:.1}s: {error}")
        }
    }
}
