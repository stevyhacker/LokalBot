//! Remembering speakers end to end on real voices: real speaker separation,
//! voice samples, naming, then a later meeting, with no speech model.
//!
//! `cargo run -p lokalbot-speech --example voice_meeting_check -- <segmentation.onnx> <titanet.onnx> <dir> <library>`
//!
//! `<dir>` holds `<speaker>/<recording>/*.wav`. Each round builds two calls of
//! the same three people from different recordings, plus one stranger in the
//! second. Everyone in the first call is named as a person would, then the
//! second call is identified. Prints what it decided about each voice.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use lokalbot_core::model::{AttributionSource, Segment};
use lokalbot_core::voice::{
    Choice, DecisionAction, MatchTier, MicrophoneEvidence, ProcessRequest, VoiceMemory,
    label_samples, label_turns,
};
use lokalbot_core::{Library, LibraryPaths, Meeting, Transcript};
use lokalbot_speech::{CLUSTER_THRESHOLD, Diarizer, Turn, VoiceExtractor, regions, voice_samples};

const SAMPLE_RATE: usize = 16_000;

struct Truth {
    speaker: String,
    start: f64,
    end: f64,
}

struct Call {
    samples: Vec<f32>,
    truth: Vec<Truth>,
}

/// Turns of 8–15 s from each person in rotation, with short pauses.
fn build_call(people: &[(String, PathBuf)]) -> Result<Call> {
    let mut audio = Vec::new();
    for (speaker, recording) in people {
        let mut files: Vec<PathBuf> = std::fs::read_dir(recording)?
            .filter_map(|e| Some(e.ok()?.path()))
            .filter(|p| p.is_file())
            .collect();
        files.sort();
        let mut samples = Vec::new();
        for file in files {
            samples.extend(lokalbot_audio::read_mono_16k(&file)?);
        }
        audio.push((speaker.clone(), samples));
    }
    let mut out = vec![0f32; SAMPLE_RATE];
    let mut truth = Vec::new();
    let mut cursors = vec![0usize; audio.len()];
    let lengths = [8.0, 12.0, 15.0, 10.0, 9.0, 13.0];
    for round in 0..18 {
        let index = round % audio.len();
        let (speaker, samples) = &audio[index];
        let take = (lengths[round % lengths.len()] * SAMPLE_RATE as f64) as usize;
        let from = cursors[index];
        let to = (from + take).min(samples.len());
        if to <= from {
            continue;
        }
        let start = out.len() as f64 / SAMPLE_RATE as f64;
        out.extend_from_slice(&samples[from..to]);
        truth.push(Truth {
            speaker: speaker.clone(),
            start,
            end: out.len() as f64 / SAMPLE_RATE as f64,
        });
        cursors[index] = to;
        out.extend(std::iter::repeat_n(0.0, SAMPLE_RATE * 2 / 5));
    }
    Ok(Call {
        samples: out,
        truth,
    })
}

/// A transcript of the separated voices, as the transcriber would make.
fn transcript_of(duration: f64, turns: &[Turn]) -> Transcript {
    let segments = regions(duration, turns, AttributionSource::System, true)
        .into_iter()
        .filter(|r| r.speaker != "them")
        .map(|region| Segment {
            start: region.start,
            end: region.end,
            speaker: region.speaker,
            text: "words".into(),
            confidence: None,
            timing_precision: None,
            attribution: Some(region.attribution),
        })
        .collect();
    Transcript {
        segments,
        engine: "check".into(),
        ..Default::default()
    }
}

/// Who a label mostly is, and how much of it that is.
fn majority(transcript: &Transcript, label: &str, truth: &[Truth]) -> (String, f64) {
    let mut seconds: BTreeMap<&str, f64> = BTreeMap::new();
    for segment in transcript.segments.iter().filter(|s| s.speaker == label) {
        for turn in truth {
            let overlap = segment.end.min(turn.end) - segment.start.max(turn.start);
            if overlap > 0.0 {
                *seconds.entry(turn.speaker.as_str()).or_default() += overlap;
            }
        }
    }
    let total: f64 = seconds.values().sum();
    let best = seconds
        .iter()
        .max_by(|a, b| a.1.total_cmp(b.1))
        .map(|(speaker, value)| (speaker.to_string(), *value))
        .unwrap_or_default();
    (best.0, if total > 0.0 { best.1 / total } else { 0.0 })
}

#[derive(Default)]
struct Tally {
    voices: usize,
    known_automatic_right: usize,
    known_automatic_wrong: usize,
    known_suggested_right: usize,
    known_suggested_wrong: usize,
    known_silent: usize,
    stranger_automatic: usize,
    stranger_suggested: usize,
    stranger_silent: usize,
    enrolled_labels: usize,
    named_labels: usize,
}

fn identify(
    extractor: &VoiceExtractor,
    diarizer: &Diarizer,
    memory: &VoiceMemory,
    meeting: &Meeting,
    call: &Call,
) -> Result<Transcript> {
    let turns = diarizer.turns(&call.samples)?;
    let duration = call.samples.len() as f64 / SAMPLE_RATE as f64;
    let transcript = transcript_of(duration, &turns);
    let raw_turns: Vec<_> = turns
        .iter()
        .map(|t| {
            (
                t.speaker.to_string(),
                lokalbot_core::voice::TurnAnchor {
                    start: t.start,
                    end: t.end,
                },
            )
        })
        .collect();
    let labeled_turns = label_turns(&raw_turns, &transcript, AttributionSource::System);
    let samples = voice_samples(
        extractor,
        &call.samples,
        &turns,
        AttributionSource::System,
        &|| false,
    );
    let labeled = label_samples(&samples, &transcript, AttributionSource::System);
    memory
        .process(ProcessRequest {
            transcript: &transcript,
            meeting,
            turns: &labeled_turns,
            evidence: MicrophoneEvidence {
                samples: labeled,
                counts: Default::default(),
            },
            mic: None,
            system: None,
            previous: None,
            name_automatically: false,
        })
        .context("identifying")
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [segmentation, titanet, dir, root] = args.as_slice() else {
        anyhow::bail!("usage: voice_meeting_check <segmentation> <titanet> <dir> <library>");
    };
    let diarizer = Diarizer::load(
        Path::new(segmentation),
        Path::new(titanet),
        4,
        CLUSTER_THRESHOLD,
    )?;
    let extractor = VoiceExtractor::load(Path::new(titanet), 4)?;
    let library = Library::open(LibraryPaths::new(root.clone()))?;
    let memory = VoiceMemory::new(library.clone(), Box::new(|| Ok([5; 32])), |_| false);

    // Speakers with at least two recordings, in folder order.
    let mut speakers: Vec<(String, Vec<PathBuf>)> = Vec::new();
    let mut folders: Vec<PathBuf> = std::fs::read_dir(dir)?
        .filter_map(|e| Some(e.ok()?.path()))
        .filter(|p| p.is_dir())
        .collect();
    folders.sort();
    for folder in folders {
        let mut recordings: Vec<PathBuf> = std::fs::read_dir(&folder)?
            .filter_map(|e| Some(e.ok()?.path()))
            .filter(|p| p.is_dir())
            .collect();
        recordings.sort();
        let name = format!(
            "Person {}",
            folder.file_name().unwrap_or_default().to_string_lossy()
        );
        speakers.push((name, recordings));
    }
    let with_two: Vec<&(String, Vec<PathBuf>)> =
        speakers.iter().filter(|s| s.1.len() >= 2).collect();

    let mut tally = Tally::default();
    for round in 0..with_two.len() / 4 {
        let group = &with_two[round * 4..round * 4 + 4];
        let (known, stranger) = group.split_at(3);
        let first: Vec<(String, PathBuf)> = known
            .iter()
            .map(|s| (s.0.clone(), s.1[0].clone()))
            .collect();
        let mut second: Vec<(String, PathBuf)> = known
            .iter()
            .map(|s| (s.0.clone(), s.1[1].clone()))
            .collect();
        second.push((stranger[0].0.clone(), stranger[0].1[0].clone()));

        let earlier =
            library.create_meeting("First", "Zoom", lokalbot_core::time::now_seconds())?;
        let call = build_call(&first)?;
        let transcript = identify(&extractor, &diarizer, &memory, &earlier, &call)?;
        let mut current = transcript.clone();
        let labels: Vec<String> = {
            let mut labels: Vec<String> = transcript
                .segments
                .iter()
                .map(|s| s.speaker.clone())
                .collect();
            labels.sort();
            labels.dedup();
            labels
        };
        for label in &labels {
            let (person, _) = majority(&transcript, label, &call.truth);
            if person.is_empty() {
                continue;
            }
            let before = memory.profiles()?.len();
            current = memory.choose(
                &Choice::new(label, Some(person), DecisionAction::Assign),
                &earlier,
                &current,
            )?;
            tally.named_labels += 1;
            if memory.profiles()?.len() > before || memory.notice().is_none() {
                tally.enrolled_labels += 1;
            }
        }

        let later = library.create_meeting("Second", "Zoom", lokalbot_core::time::now_seconds())?;
        let call = build_call(&second)?;
        let transcript = identify(&extractor, &diarizer, &memory, &later, &call)?;
        let state = memory.state(&later)?;
        let mut labels: Vec<String> = transcript
            .segments
            .iter()
            .map(|s| s.speaker.clone())
            .collect();
        labels.sort();
        labels.dedup();
        for label in &labels {
            let (person, purity) = majority(&transcript, label, &call.truth);
            let is_known = known.iter().any(|k| k.0 == person);
            let offered = state.suggestions.get(label).cloned().unwrap_or_default();
            let automatic = offered.iter().find(|m| m.tier == MatchTier::Automatic);
            let best = offered.first();
            tally.voices += 1;
            match (is_known, automatic, best) {
                (true, Some(found), _) if found.name == person => tally.known_automatic_right += 1,
                (true, Some(_), _) => tally.known_automatic_wrong += 1,
                (true, None, Some(found)) if found.name == person => {
                    tally.known_suggested_right += 1
                }
                (true, None, Some(_)) => tally.known_suggested_wrong += 1,
                (true, None, None) => tally.known_silent += 1,
                (false, Some(_), _) => tally.stranger_automatic += 1,
                (false, None, Some(_)) => tally.stranger_suggested += 1,
                (false, None, None) => tally.stranger_silent += 1,
            }
            println!(
                "round {round} {label}: truth={person} purity={purity:.2} offered={:?}",
                offered
                    .iter()
                    .map(|m| (
                        m.name.as_str(),
                        m.tier,
                        (m.support_fraction * 100.0).round() / 100.0
                    ))
                    .collect::<Vec<_>>()
            );
        }
    }
    println!(
        "{}",
        serde_json::json!({
            "profiles": memory.profiles()?.len(),
            "named_labels": tally.named_labels,
            "enrolled_labels": tally.enrolled_labels,
            "voices": tally.voices,
            "known_automatic_right": tally.known_automatic_right,
            "known_automatic_wrong": tally.known_automatic_wrong,
            "known_suggested_right": tally.known_suggested_right,
            "known_suggested_wrong": tally.known_suggested_wrong,
            "known_silent": tally.known_silent,
            "stranger_automatic": tally.stranger_automatic,
            "stranger_suggested": tally.stranger_suggested,
            "stranger_silent": tally.stranger_silent,
        })
    );
    Ok(())
}
