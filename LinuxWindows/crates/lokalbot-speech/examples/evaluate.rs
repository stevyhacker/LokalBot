//! End-to-end check on a scripted meeting: per-track word error rate,
//! attribution, speaker labels, timing, and the dictation path.
//!
//! `cargo run -p lokalbot-speech --release --example evaluate -- --root <library> --model qwen3-asr-0.6b --fixture <dir> [--diarize] [--mic mic.wav] [--prompt] [--threads 8]`
//!
//! `<dir>` holds `mic.wav`, `system.wav`, `scenario.json` (`{"turns": [{"track", "voice", "start", "end", "text"}]}`)
//! and optionally `dictation.wav` + `dictation.json` (`{"text"}`).

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Instant;

use anyhow::{Context, Result};
use lokalbot_core::{AttributionSource, LibraryPaths};
use lokalbot_speech::{TranscribeOptions, TranscribeProgress, Transcriber};
use serde::Deserialize;

#[derive(Deserialize)]
struct Scenario {
    turns: Vec<Turn>,
    #[serde(default)]
    vocabulary: String,
}

#[derive(Deserialize)]
struct Turn {
    track: String,
    voice: String,
    start: f64,
    end: f64,
    text: String,
}

fn words(text: &str) -> Vec<String> {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric() && c != '\'')
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

fn wer(reference: &[String], hypothesis: &[String]) -> f64 {
    let mut previous: Vec<usize> = (0..=hypothesis.len()).collect();
    for (i, r) in reference.iter().enumerate() {
        let mut current = vec![i + 1; hypothesis.len() + 1];
        for (j, h) in hypothesis.iter().enumerate() {
            current[j + 1] = (previous[j] + usize::from(r != h))
                .min(previous[j + 1] + 1)
                .min(current[j] + 1);
        }
        previous = current;
    }
    previous[hypothesis.len()] as f64 / reference.len().max(1) as f64
}

fn main() -> Result<()> {
    env_logger_lite();
    let mut args = std::env::args().skip(1);
    let (mut root, mut model, mut fixture) = (None, "qwen3-asr-0.6b".to_string(), None);
    let (mut diarize, mut mic_name, mut prompt, mut threads) =
        (false, "mic.wav".to_string(), false, 8usize);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().map(PathBuf::from),
            "--model" => model = args.next().context("--model needs a value")?,
            "--fixture" => fixture = args.next().map(PathBuf::from),
            "--diarize" => diarize = true,
            "--mic" => mic_name = args.next().context("--mic needs a value")?,
            "--prompt" => prompt = true,
            "--threads" => threads = args.next().context("--threads needs a value")?.parse()?,
            other => anyhow::bail!("unknown argument {other}"),
        }
    }
    let root = root.context("--root is required")?;
    let fixture = fixture.context("--fixture is required")?;
    let scenario: Scenario =
        serde_json::from_slice(&std::fs::read(fixture.join("scenario.json"))?)?;
    let paths = LibraryPaths::new(&root);

    let started = Instant::now();
    let transcriber = Transcriber::load(&paths, &model, threads)?;
    let load_seconds = started.elapsed().as_secs_f64();

    let options = TranscribeOptions {
        language: None,
        diarize,
        microphone_is_user: true,
        vocabulary_prompt: prompt.then(|| scenario.vocabulary.clone()),
        content_range: None,
    };
    let mic = fixture.join(&mic_name);
    let system = fixture.join("system.wav");
    let started = Instant::now();
    let mut steps = Vec::new();
    let transcript =
        transcriber.transcribe_meeting(Some(&mic), Some(&system), &options, &mut |p| {
            if !matches!(p, TranscribeProgress::Transcribing { .. }) {
                steps.push(format!("{p:?}"));
            }
        })?;
    let seconds = started.elapsed().as_secs_f64();
    let audio = lokalbot_audio::duration_seconds(&system)?;

    println!(
        "== {} ({model}) diarize={diarize} mic={mic_name} prompt={prompt}",
        transcriber.display_name()
    );
    for segment in &transcript.segments {
        let method = segment
            .attribution
            .map(|a| format!("{:?}/{:?}", a.source, a.identity))
            .unwrap_or_default();
        println!(
            "[{:6.2}-{:6.2}] {:<12} {:<18} {}",
            segment.start, segment.end, segment.speaker, method, segment.text
        );
    }
    for (track, source) in [
        ("mic", AttributionSource::Microphone),
        ("system", AttributionSource::System),
    ] {
        let reference: Vec<String> = scenario
            .turns
            .iter()
            .filter(|t| t.track == track)
            .flat_map(|t| words(&t.text))
            .collect();
        let hypothesis: Vec<String> = transcript
            .segments
            .iter()
            .filter(|s| s.attribution.map(|a| a.source) == Some(source))
            .flat_map(|s| words(&s.text))
            .collect();
        println!(
            "WER {track}: {:.1}% ({} reference words, {} hypothesis words)",
            100.0 * wer(&reference, &hypothesis),
            reference.len(),
            hypothesis.len()
        );
    }
    // Speaker labels on the system track: majority voice per label, then word accuracy.
    let mut votes: HashMap<(String, String), usize> = HashMap::new();
    let mut labelled = Vec::new();
    for segment in transcript
        .segments
        .iter()
        .filter(|s| s.speaker.starts_with("them"))
    {
        let middle = (segment.start + segment.end) / 2.0;
        let voice = scenario
            .turns
            .iter()
            .filter(|t| t.track == "system")
            .min_by(|a, b| {
                let da = if middle < a.start {
                    a.start - middle
                } else if middle > a.end {
                    middle - a.end
                } else {
                    0.0
                };
                let db = if middle < b.start {
                    b.start - middle
                } else if middle > b.end {
                    middle - b.end
                } else {
                    0.0
                };
                da.total_cmp(&db)
            })
            .map(|t| t.voice.clone())
            .unwrap_or_default();
        let n = words(&segment.text).len();
        *votes
            .entry((segment.speaker.clone(), voice.clone()))
            .or_default() += n;
        labelled.push((segment.speaker.clone(), voice, n));
    }
    let mut mapping: HashMap<String, (String, usize)> = HashMap::new();
    for ((label, voice), n) in &votes {
        let entry = mapping.entry(label.clone()).or_insert((voice.clone(), 0));
        if *n > entry.1 {
            *entry = (voice.clone(), *n);
        }
    }
    let total: usize = labelled.iter().map(|l| l.2).sum();
    let correct: usize = labelled
        .iter()
        .filter(|(label, voice, _)| mapping.get(label).is_some_and(|m| &m.0 == voice))
        .map(|l| l.2)
        .sum();
    let labels: Vec<String> = mapping
        .iter()
        .map(|(l, (v, _))| format!("{l}→{v}"))
        .collect();
    println!(
        "system labels: {} | words with the majority label: {:.1}%",
        labels.join(", "),
        100.0 * correct as f64 / total.max(1) as f64
    );
    println!("steps: {}", steps.join(" → "));
    println!(
        "timing: load {load_seconds:.2}s, transcribe {seconds:.2}s for {audio:.1}s of audio × 2 tracks (RTF {:.3} per track-second)",
        seconds / (audio * 2.0)
    );

    let dictation = fixture.join("dictation.wav");
    if dictation.is_file() {
        #[derive(Deserialize)]
        struct Dictation {
            text: String,
        }
        let reference: Dictation =
            serde_json::from_slice(&std::fs::read(fixture.join("dictation.json"))?)?;
        let samples = lokalbot_audio::read_mono_16k(&dictation)?;
        let started = Instant::now();
        let text = transcriber.transcribe_dictation(&samples, None)?;
        println!(
            "dictation: {:.2}s for {:.1}s, WER {:.1}%: {text}",
            started.elapsed().as_secs_f64(),
            samples.len() as f64 / 16_000.0,
            100.0 * wer(&words(&reference.text), &words(&text))
        );
        println!(
            "too short: {}",
            transcriber
                .transcribe_dictation(&samples[..3_000], None)
                .unwrap_err()
        );
        println!(
            "silence: {}",
            transcriber
                .transcribe_dictation(&vec![0.0; 32_000], None)
                .unwrap_err()
        );
    }
    Ok(())
}

/// Logs `info` and above to stderr when `RUST_LOG` is set, without a logger dependency.
fn env_logger_lite() {
    struct Stderr;
    impl log::Log for Stderr {
        fn enabled(&self, metadata: &log::Metadata) -> bool {
            metadata.level() <= log::max_level()
        }
        fn log(&self, record: &log::Record) {
            if self.enabled(record.metadata()) {
                eprintln!("{} {}", record.level(), record.args());
            }
        }
        fn flush(&self) {}
    }
    let Some(level) = std::env::var_os("RUST_LOG") else {
        return;
    };
    if log::set_logger(&Stderr).is_ok() {
        log::set_max_level(if level == "debug" {
            log::LevelFilter::Debug
        } else {
            log::LevelFilter::Info
        });
    }
}
