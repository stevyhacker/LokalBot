//! Measures the voice model on labeled speech, for the matching rules in
//! `lokalbot_core::voice`.
//!
//! `cargo run -p lokalbot-speech --example voice_calibration -- <titanet.onnx> <dir>`
//!
//! `<dir>` holds `<speaker>/<recording>/*.wav` (or any format the app reads).
//! Each speaker/recording pair stands for one meeting: its files are cut into
//! 6 s chunks, up to 16 chunks are averaged as `voice::voiceprint` does, and
//! every meeting is scored against the average of each person's other
//! meetings. Prints JSON: score distributions, and what the Mac's rules would
//! decide when the person is remembered and when they are a stranger.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use lokalbot_core::voice::{call, cosine, voiceprint};
use lokalbot_speech::VoiceExtractor;

const CHUNK: usize = 16_000 * 6;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [model, dir] = args.as_slice() else {
        anyhow::bail!("usage: voice_calibration <titanet.onnx> <dir>");
    };
    let extractor = VoiceExtractor::load(Path::new(model), 4)?;
    let mut meetings: BTreeMap<(String, String), Vec<Vec<f32>>> = BTreeMap::new();
    for speaker in folders(Path::new(dir))? {
        for recording in folders(&speaker)? {
            let mut audio = Vec::new();
            let mut files: Vec<PathBuf> = std::fs::read_dir(&recording)?
                .filter_map(|e| Some(e.ok()?.path()))
                .filter(|p| p.is_file())
                .collect();
            files.sort();
            for file in files {
                if let Ok(samples) = lokalbot_audio::read_mono_16k(&file) {
                    audio.extend(samples);
                }
            }
            let mut vectors = Vec::new();
            for chunk in audio
                .chunks(CHUNK)
                .filter(|c| c.len() == CHUNK)
                .take(call::SAMPLE_LIMIT)
            {
                if let Some(vector) = extractor.embed(chunk) {
                    vectors.push(vector);
                }
            }
            if vectors.len() >= 3 {
                meetings.insert((name(&speaker), name(&recording)), vectors);
            }
        }
    }

    // One voiceprint per meeting, plus how well its chunks agree.
    let mut prints: Vec<(String, String, Vec<f32>)> = Vec::new();
    let mut consistency = Vec::new();
    for ((speaker, recording), vectors) in &meetings {
        let refs: Vec<&[f32]> = vectors.iter().map(Vec::as_slice).collect();
        let print = voiceprint(&refs).context("no voiceprint")?;
        consistency.push(print.consistency);
        prints.push((speaker.clone(), recording.clone(), print.vector));
    }

    // A single meeting against a person remembered from their other meetings.
    let mut same = Vec::new();
    let mut different = Vec::new();
    let mut speakers: Vec<&String> = prints.iter().map(|(s, _, _)| s).collect();
    speakers.dedup();
    // Closed set: the person is remembered. Open set: they are a stranger, the
    // case where naming anyone is wrong.
    let mut known = Decisions::default();
    let mut stranger = Decisions::default();
    for (index, (speaker, _, vector)) in prints.iter().enumerate() {
        let mut scores: Vec<(&String, f64)> = Vec::new();
        for other in &speakers {
            let theirs: Vec<&[f32]> = prints
                .iter()
                .enumerate()
                .filter(|(i, (s, _, _))| *i != index && s == *other)
                .map(|(_, (_, _, v))| v.as_slice())
                .collect();
            if theirs.is_empty() {
                continue;
            }
            let remembered = voiceprint(&theirs).context("no voiceprint")?;
            let score = cosine(vector, &remembered.vector);
            if *other == speaker {
                same.push(score);
            } else {
                different.push(score);
            }
            scores.push((other, score));
        }
        scores.sort_by(|a, b| b.1.total_cmp(&a.1));
        if scores.iter().any(|(s, _)| *s == speaker) {
            known.observe(&scores, speaker);
        }
        let without: Vec<(&String, f64)> = scores
            .iter()
            .filter(|(s, _)| *s != speaker)
            .copied()
            .collect();
        stranger.observe(&without, speaker);
    }
    println!(
        "{}",
        serde_json::json!({
            "meetings": prints.len(),
            "speakers": speakers.len(),
            "consistency": summary(&mut consistency),
            "same": summary(&mut same),
            "different": summary(&mut different),
            "known_person": known.report(),
            "stranger": stranger.report(),
        })
    );
    Ok(())
}

/// What the Mac's rules would decide (`SpeakerVoiceMatcher.callMatches`).
#[derive(Default)]
struct Decisions {
    queries: usize,
    suggested_right: usize,
    suggested_wrong: usize,
    automatic_right: usize,
    automatic_wrong: usize,
}

impl Decisions {
    fn observe(&mut self, scores: &[(&String, f64)], truth: &String) {
        self.queries += 1;
        let Some((best, score)) = scores.first() else {
            return;
        };
        let next = scores.get(1).map_or(-1.0, |(_, s)| *s);
        if *score >= call::SUGGESTED_SCORE {
            if *best == truth {
                self.suggested_right += 1;
            } else {
                self.suggested_wrong += 1;
            }
        }
        if *score >= call::AUTOMATIC_SCORE && score - next >= call::AUTOMATIC_MARGIN {
            if *best == truth {
                self.automatic_right += 1;
            } else {
                self.automatic_wrong += 1;
            }
        }
    }

    fn report(&self) -> serde_json::Value {
        serde_json::json!({
            "queries": self.queries,
            "suggested_right": self.suggested_right,
            "suggested_wrong": self.suggested_wrong,
            "automatic_right": self.automatic_right,
            "automatic_wrong": self.automatic_wrong,
        })
    }
}

fn folders(path: &Path) -> Result<Vec<PathBuf>> {
    let mut out: Vec<PathBuf> = std::fs::read_dir(path)?
        .filter_map(|e| Some(e.ok()?.path()))
        .filter(|p| p.is_dir())
        .collect();
    out.sort();
    Ok(out)
}

fn name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn summary(values: &mut [f64]) -> serde_json::Value {
    values.sort_by(f64::total_cmp);
    let at = |p: f64| {
        values
            .get(((values.len().saturating_sub(1)) as f64 * p).round() as usize)
            .copied()
            .unwrap_or(f64::NAN)
    };
    serde_json::json!({
        "n": values.len(),
        "min": at(0.0),
        "p1": at(0.01),
        "p5": at(0.05),
        "p50": at(0.5),
        "p95": at(0.95),
        "p99": at(0.99),
        "max": at(1.0),
    })
}
