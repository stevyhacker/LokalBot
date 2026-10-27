//! Times the dictation path on a WAV file.
//!
//! `cargo run -p lokalbot-speech --release --example dictate -- <library root> <model id> <wav> [threads…]`

use std::time::Instant;

use lokalbot_core::LibraryPaths;
use lokalbot_speech::Transcriber;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [root, model, wav, threads @ ..] = args.as_slice() else {
        anyhow::bail!("usage: dictate <library root> <model id> <wav> [threads…]");
    };
    let samples = lokalbot_audio::read_mono_16k(std::path::Path::new(wav))?;
    let threads: Vec<usize> = if threads.is_empty() {
        vec![4]
    } else {
        threads.iter().filter_map(|t| t.parse().ok()).collect()
    };
    for count in threads {
        let started = Instant::now();
        let transcriber = Transcriber::load(&LibraryPaths::new(root), model, count)?;
        let load = started.elapsed().as_secs_f64();
        let mut best = f64::MAX;
        let mut text = String::new();
        for _ in 0..3 {
            let started = Instant::now();
            text = transcriber.transcribe_dictation(&samples, None)?;
            best = best.min(started.elapsed().as_secs_f64());
        }
        println!(
            "threads {count:>2}: load {load:.2}s, best of 3 {best:.2}s for {:.1}s audio: {text}",
            samples.len() as f64 / 16_000.0
        );
    }
    Ok(())
}
