//! Voice samples for remembering speakers. macOS gets per-speaker chunk
//! embeddings from its diarizer; sherpa-onnx returns only turns, so each chunk
//! here is embedded separately from that speaker's own audio.

use std::path::Path;

use anyhow::{Result, anyhow};
use lokalbot_core::AttributionSource;
use lokalbot_core::voice::{TurnAnchor, VOICE_DIMENSION, VOICE_MODEL, VoiceSample};
use sherpa_onnx::{SpeakerEmbeddingExtractor, SpeakerEmbeddingExtractorConfig};

use crate::attribution::Turn;
use crate::vad::SAMPLE_RATE;

/// A chunk is 3–10 s of one voice, like the Mac's.
pub const MIN_CHUNK_SECONDS: f64 = 3.0;
pub const MAX_CHUNK_SECONDS: f64 = 10.0;
/// Call speech pauses between sentences, and a pause is not another person.
const CALL_PAUSE_SECONDS: f64 = 1.5;
/// A microphone sample has to sit inside one uninterrupted turn.
const MICROPHONE_PAUSE_SECONDS: f64 = 0.5;
/// More than matching ever reads (16 for a call voice, 8 for a microphone).
const CHUNKS_PER_VOICE: usize = 24;

/// TitaNet-small through sherpa-onnx.
pub struct VoiceExtractor {
    inner: SpeakerEmbeddingExtractor,
}

impl VoiceExtractor {
    /// Fails when the model's vectors aren't [`VOICE_DIMENSION`] long, so a
    /// different model can't write samples under [`VOICE_MODEL`].
    pub fn load(model: &Path, threads: usize) -> Result<Self> {
        let config = SpeakerEmbeddingExtractorConfig {
            model: Some(model.to_string_lossy().into_owned()),
            num_threads: threads.clamp(1, 16) as i32,
            debug: false,
            provider: Some("cpu".into()),
        };
        let inner = SpeakerEmbeddingExtractor::create(&config)
            .ok_or_else(|| anyhow!("could not load the voice model"))?;
        anyhow::ensure!(
            inner.dim() as usize == VOICE_DIMENSION,
            "the voice model gives {} values where {VOICE_DIMENSION} are expected",
            inner.dim()
        );
        Ok(Self { inner })
    }

    /// A voice vector of 16 kHz mono `samples`, when there are enough.
    pub fn embed(&self, samples: &[f32]) -> Option<Vec<f32>> {
        let stream = self.inner.create_stream()?;
        stream.accept_waveform(SAMPLE_RATE as i32, samples);
        stream.input_finished();
        if !self.inner.is_ready(&stream) {
            return None;
        }
        self.inner.compute(&stream)
    }
}

/// One speaker's stretch of a track, and which parts of it are their voice.
#[derive(Clone, Debug, PartialEq)]
pub struct VoiceChunk {
    pub speaker: i32,
    pub range: TurnAnchor,
    pub frames: Vec<(f64, f64)>,
}

impl VoiceChunk {
    fn speech(&self) -> f64 {
        self.frames.iter().map(|(start, end)| end - start).sum()
    }
}

/// The parts of each turn no other speaker overlaps, in time order.
fn clean_turns(turns: &[Turn]) -> Vec<Turn> {
    let mut sorted: Vec<&Turn> = turns.iter().filter(|t| t.end > t.start).collect();
    sorted.sort_by(|a, b| a.start.total_cmp(&b.start));
    let mut out = Vec::new();
    for turn in &sorted {
        let mut parts = vec![(turn.start, turn.end)];
        for other in sorted.iter().filter(|o| o.speaker != turn.speaker) {
            parts = parts
                .into_iter()
                .flat_map(|(start, end)| {
                    if other.end <= start || other.start >= end {
                        vec![(start, end)]
                    } else {
                        let mut kept = Vec::new();
                        if other.start > start {
                            kept.push((start, other.start));
                        }
                        if other.end < end {
                            kept.push((other.end, end));
                        }
                        kept
                    }
                })
                .collect();
        }
        out.extend(parts.into_iter().map(|(start, end)| Turn {
            start,
            end,
            speaker: turn.speaker,
        }));
    }
    out.sort_by(|a, b| a.start.total_cmp(&b.start));
    out
}

/// Windows of contiguous speech from one voice, with no other voice between
/// their turns. The longest of each voice are kept.
pub fn voice_chunks(turns: &[Turn], source: AttributionSource) -> Vec<VoiceChunk> {
    let pause = if source == AttributionSource::System {
        CALL_PAUSE_SECONDS
    } else {
        MICROPHONE_PAUSE_SECONDS
    };
    let clean = clean_turns(turns);
    let mut chunks: Vec<VoiceChunk> = Vec::new();
    let mut open: Option<VoiceChunk> = None;
    for turn in &clean {
        if let Some(chunk) = &open
            && (chunk.speaker != turn.speaker || turn.start - chunk.range.end > pause)
        {
            chunks.extend(open.take());
        }
        let mut start = turn.start;
        while start < turn.end {
            // A pause can carry the next turn past this window's end.
            if open
                .as_ref()
                .is_some_and(|chunk| start >= chunk.range.start + MAX_CHUNK_SECONDS - 1e-9)
            {
                chunks.extend(open.take());
            }
            let chunk = open.get_or_insert_with(|| VoiceChunk {
                speaker: turn.speaker,
                range: TurnAnchor { start, end: start },
                frames: Vec::new(),
            });
            let end = turn.end.min(chunk.range.start + MAX_CHUNK_SECONDS);
            chunk.frames.push((start, end));
            chunk.range.end = end;
            let full = end >= chunk.range.start + MAX_CHUNK_SECONDS - 1e-9;
            start = end;
            if full {
                chunks.extend(open.take());
            }
        }
    }
    chunks.extend(open);
    chunks.retain(|c| {
        c.range.duration() >= MIN_CHUNK_SECONDS && c.speech() >= MIN_CHUNK_SECONDS * 0.6
    });
    // Longest first within each voice, then back in time order.
    chunks.sort_by(|a, b| {
        a.speaker
            .cmp(&b.speaker)
            .then(b.speech().total_cmp(&a.speech()))
    });
    let mut kept: Vec<VoiceChunk> = Vec::new();
    let mut count = 0;
    let mut speaker = None;
    for chunk in chunks {
        if speaker != Some(chunk.speaker) {
            speaker = Some(chunk.speaker);
            count = 0;
        }
        if count < CHUNKS_PER_VOICE {
            kept.push(chunk);
            count += 1;
        }
    }
    kept.sort_by(|a, b| a.range.start.total_cmp(&b.range.start));
    kept
}

/// Vectors for a track's chunks, hearing only each speaker's own frames. The
/// `speaker` is the diarizer's until `lokalbot_core::voice::label_samples` runs.
pub fn voice_samples(
    extractor: &VoiceExtractor,
    samples_16k: &[f32],
    turns: &[Turn],
    source: AttributionSource,
    cancelled: &dyn Fn() -> bool,
) -> Vec<VoiceSample> {
    let at =
        |seconds: f64| ((seconds * SAMPLE_RATE as f64).round() as usize).min(samples_16k.len());
    let mut out = Vec::new();
    for chunk in voice_chunks(turns, source) {
        if cancelled() {
            break;
        }
        let audio: Vec<f32> = chunk
            .frames
            .iter()
            .flat_map(|(start, end)| samples_16k[at(*start)..at(*end)].iter().copied())
            .collect();
        let Some(vector) = extractor.embed(&audio) else {
            continue;
        };
        out.push(VoiceSample {
            speaker: chunk.speaker.to_string(),
            range: chunk.range,
            vector,
            source: Some(source),
            model: VOICE_MODEL.to_string(),
        });
    }
    out
}

/// A diarizer turn as `lokalbot_core::voice::label_turns` wants it.
pub fn raw_turns(turns: &[Turn]) -> Vec<(String, TurnAnchor)> {
    turns
        .iter()
        .map(|t| {
            (
                t.speaker.to_string(),
                TurnAnchor {
                    start: t.start,
                    end: t.end,
                },
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(start: f64, end: f64, speaker: i32) -> Turn {
        Turn {
            start,
            end,
            speaker,
        }
    }

    #[test]
    fn chunks_hold_one_voice_and_stay_within_the_limits() {
        let turns = [
            turn(0.0, 2.0, 1),
            turn(3.0, 6.0, 1),
            turn(6.0, 8.0, 2),
            turn(8.0, 33.0, 1),
        ];
        let chunks = voice_chunks(&turns, AttributionSource::System);
        // The pause joined the first two; the other voice ended that chunk.
        assert_eq!(chunks[0].speaker, 1);
        assert_eq!(chunks[0].frames, vec![(0.0, 2.0), (3.0, 6.0)]);
        assert_eq!(
            chunks[0].range,
            TurnAnchor {
                start: 0.0,
                end: 6.0
            }
        );
        // 2 s of voice 2 is too short; 25 s of voice 1 splits, and its 5 s tail stays.
        assert!(chunks.iter().all(|c| c.speaker == 1));
        let lengths: Vec<f64> = chunks.iter().map(|c| c.range.duration()).collect();
        assert_eq!(lengths, vec![6.0, 10.0, 10.0, 5.0]);
    }

    #[test]
    fn a_turn_after_a_pause_past_the_window_starts_a_new_chunk() {
        let chunks = voice_chunks(
            &[turn(90.0, 99.5, 1), turn(100.5, 110.0, 1)],
            AttributionSource::System,
        );
        assert_eq!(chunks.len(), 2, "{chunks:?}");
        for chunk in &chunks {
            assert!(
                chunk.frames.iter().all(|(start, end)| end > start),
                "{chunk:?}"
            );
        }
        assert_eq!(chunks[1].range.start, 100.5);
    }

    #[test]
    fn overlapped_speech_is_left_out() {
        let chunks = voice_chunks(
            &[turn(0.0, 8.0, 1), turn(4.0, 12.0, 2)],
            AttributionSource::System,
        );
        for chunk in &chunks {
            assert!(
                chunk.range.end <= 4.0 || chunk.range.start >= 8.0,
                "{chunk:?}"
            );
        }
        assert_eq!(chunks.len(), 2);
    }

    #[test]
    fn a_microphone_pause_ends_a_chunk() {
        let turns = [turn(0.0, 3.0, 1), turn(4.0, 7.5, 1)];
        assert_eq!(voice_chunks(&turns, AttributionSource::Microphone).len(), 2);
        assert_eq!(voice_chunks(&turns, AttributionSource::System).len(), 1);
    }

    #[test]
    fn a_voice_keeps_its_longest_chunks() {
        let mut turns = Vec::new();
        for i in 0..40 {
            let start = i as f64 * 10.0;
            turns.push(turn(start, start + 3.5 + (i % 3) as f64, 1));
        }
        let chunks = voice_chunks(&turns, AttributionSource::Microphone);
        assert_eq!(chunks.len(), CHUNKS_PER_VOICE);
        assert!(
            chunks
                .windows(2)
                .all(|w| w[0].range.start < w[1].range.start)
        );
        assert!(chunks.iter().filter(|c| c.speech() >= 5.0).count() >= 13);
    }
}
