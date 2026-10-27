//! Sweeps speaker-separation settings on a WAV with a known script.
//!
//! `cargo run -p lokalbot-speech --release --example diarize -- <segmentation.onnx> <embedding.onnx> <track.wav> <scenario.json> <track name> [thresholds…]`

use std::path::Path;

use lokalbot_speech::Turn;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [
        segmentation,
        embedding,
        wav,
        scenario,
        track,
        thresholds @ ..,
    ] = args.as_slice()
    else {
        anyhow::bail!(
            "usage: diarize <segmentation> <embedding> <wav> <scenario.json> <track> [thresholds…]"
        );
    };
    let scenario: serde_json::Value = serde_json::from_slice(&std::fs::read(scenario)?)?;
    let truth: Vec<(f64, f64, String)> = scenario["turns"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|t| t["track"] == track.as_str())
        .map(|t| {
            (
                t["start"].as_f64().unwrap_or(0.0),
                t["end"].as_f64().unwrap_or(0.0),
                t["voice"].as_str().unwrap_or("").to_string(),
            )
        })
        .collect();
    let samples = lokalbot_audio::read_mono_16k(Path::new(wav))?;
    let thresholds: Vec<f32> = if thresholds.is_empty() {
        vec![0.5]
    } else {
        thresholds.iter().filter_map(|t| t.parse().ok()).collect()
    };
    for threshold in thresholds {
        let started = std::time::Instant::now();
        let diarizer = lokalbot_speech::Diarizer::load(
            Path::new(segmentation),
            Path::new(embedding),
            8,
            threshold,
        )?;
        let turns: Vec<Turn> = diarizer.turns(&samples)?;
        let mut speakers: Vec<i32> = turns.iter().map(|t| t.speaker).collect();
        speakers.sort_unstable();
        speakers.dedup();
        // Purity: seconds of each turn whose majority truth voice matches the speaker's majority voice.
        let mut overlap = std::collections::HashMap::<(i32, String), f64>::new();
        for turn in &turns {
            for (start, end, voice) in &truth {
                let seconds = turn.end.min(*end) - turn.start.max(*start);
                if seconds > 0.0 {
                    *overlap.entry((turn.speaker, voice.clone())).or_default() += seconds;
                }
            }
        }
        let mut best = std::collections::HashMap::<i32, (String, f64)>::new();
        for ((speaker, voice), seconds) in &overlap {
            let entry = best.entry(*speaker).or_insert((voice.clone(), 0.0));
            if *seconds > entry.1 {
                *entry = (voice.clone(), *seconds);
            }
        }
        let total: f64 = overlap.values().sum();
        let matched: f64 = best.values().map(|(_, s)| s).sum();
        let mapping: Vec<String> = best.iter().map(|(s, (v, _))| format!("{s}→{v}")).collect();
        println!(
            "threshold {threshold:.2}: {} voices [{}], purity {:.1}%, {:.2}s",
            speakers.len(),
            mapping.join(", "),
            100.0 * matched / total.max(1e-9),
            started.elapsed().as_secs_f64()
        );
    }
    Ok(())
}
