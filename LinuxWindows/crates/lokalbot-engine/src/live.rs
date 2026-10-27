//! Live transcript preview while recording (`LiveMeetingTranscriber`,
//! `LiveTranscriptChunker`). It is opt-in: nothing loads or runs until the
//! user starts it. Each track is read in 4–12 s chunks cut at a quiet moment
//! and transcribed without speakers; the full transcript replaces it after
//! the meeting.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use parking_lot::Mutex;

use lokalbot_audio::{MIC_FILE, SAMPLE_RATE, SYSTEM_FILE, WavReader};
use lokalbot_core::Transcript;

use crate::models::Models;
use crate::{EngineEvent, LiveLine, LivePreview, LivePreviewState, Shared};

const MIN_CHUNK_SECONDS: f64 = 4.0;
const TARGET_CHUNK_SECONDS: f64 = 12.0;
const CUT_SEARCH_SECONDS: f64 = 1.5;
const GATE_HIGH_PASS_HZ: f64 = 120.0;
const GATE_MINIMUM_HIGH_PASSED_ENERGY_RATIO: f32 = 0.15;
const GATE_ABSOLUTE_FLOOR: f32 = 0.003;
const MAX_LINES: usize = 400;
const MAX_CONSECUTIVE_FAILURES: u32 = 3;
const IDLE_POLL: Duration = Duration::from_secs(1);
const LIVE_EDGE_PAUSE_SECONDS: f64 = 0.4;
const RETRY_BASE_SECONDS: f64 = 1.0;

/// Starts, pauses and stops the preview; the worker thread does the audio work.
#[derive(Clone)]
pub struct LiveTranscriber {
    inner: Arc<Inner>,
}

struct Inner {
    shared: Arc<Shared>,
    models: Models,
    /// Bumped on every start, pause and stop; a worker from an older
    /// generation drops whatever it was doing.
    generation: AtomicU64,
    state: Mutex<State>,
}

struct State {
    folder: Option<PathBuf>,
    tracks: [Track; 2],
    /// Cursors are set by the first start only; resume and retry keep them so
    /// accepted chunks are never transcribed twice.
    initialized: bool,
    transcribed_once: bool,
    preview: LivePreview,
}

#[derive(Clone)]
struct Track {
    file: &'static str,
    mine: bool,
    processed_frames: u64,
    failures: u32,
    retry_after: Option<Instant>,
}

impl State {
    fn new() -> Self {
        Self {
            folder: None,
            tracks: new_tracks(),
            initialized: false,
            transcribed_once: false,
            preview: LivePreview::default(),
        }
    }
}

fn new_tracks() -> [Track; 2] {
    let track = |file, mine| Track {
        file,
        mine,
        processed_frames: 0,
        failures: 0,
        retry_after: None,
    };
    [track(MIC_FILE, true), track(SYSTEM_FILE, false)]
}

impl LiveTranscriber {
    pub fn new(shared: Arc<Shared>, models: Models) -> Self {
        Self {
            inner: Arc::new(Inner {
                shared,
                models,
                generation: AtomicU64::new(0),
                state: Mutex::new(State::new()),
            }),
        }
    }

    /// A recording started in `folder`; the preview is off until started.
    pub fn prepare(&self, folder: PathBuf) {
        self.inner.generation.fetch_add(1, Ordering::SeqCst);
        let mut state = self.inner.state.lock();
        *state = State::new();
        state.folder = Some(folder);
        self.inner.publish(&state);
    }

    /// Starts, resumes or retries. `from_beginning` applies only to the first start.
    pub fn start(&self, from_beginning: bool) {
        let session = {
            let mut state = self.inner.state.lock();
            if state.folder.is_none() || state.preview.state == LivePreviewState::Running {
                return;
            }
            let models = &self.inner.models;
            if !models.missing(&models.dictation_requirements()).is_empty() {
                state.preview.state = LivePreviewState::Failed(
                    "Download the transcription model in Settings → Models to preview the transcript."
                        .into(),
                );
                self.inner.publish(&state);
                return;
            }
            for track in &mut state.tracks {
                track.failures = 0;
                track.retry_after = None;
            }
            state.preview.state = LivePreviewState::Running;
            state.preview.status = None;
            let session = self.inner.generation.fetch_add(1, Ordering::SeqCst) + 1;
            self.inner.publish(&state);
            session
        };
        let inner = self.inner.clone();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-live-transcript".into())
            .spawn(move || inner.run(session, from_beginning));
        if let Err(err) = spawned {
            log::warn!("could not start the live transcript: {err}");
            let mut state = self.inner.state.lock();
            state.preview.state = LivePreviewState::Failed(
                "Live preview could not start. Recording is still running.".into(),
            );
            self.inner.publish(&state);
        }
    }

    pub fn pause(&self) {
        let mut state = self.inner.state.lock();
        if state.preview.state != LivePreviewState::Running {
            return;
        }
        self.inner.generation.fetch_add(1, Ordering::SeqCst);
        state.preview.state = LivePreviewState::Paused;
        state.preview.status = None;
        state.preview.working = false;
        self.inner.publish(&state);
    }

    /// The recording ended: drop the preview.
    pub fn stop(&self) {
        self.inner.generation.fetch_add(1, Ordering::SeqCst);
        let mut state = self.inner.state.lock();
        *state = State::new();
        self.inner.publish(&state);
    }
}

/// What the next chunk of one track holds.
enum Chunk {
    NoWork,
    /// Nothing worth transcribing up to this frame.
    Advance(u64),
    Ready {
        samples: Vec<f32>,
        start_seconds: f64,
        end_frame: u64,
    },
}

impl Inner {
    fn publish(&self, state: &State) {
        self.shared
            .emit(EngineEvent::LivePreview(state.preview.clone()));
    }

    fn is_current(&self, session: u64) -> bool {
        self.generation.load(Ordering::SeqCst) == session && !self.shared.is_shutting_down()
    }

    /// Runs `f` on the state only while `session` is still the current one.
    fn update<T>(&self, session: u64, f: impl FnOnce(&mut State) -> T) -> Option<T> {
        let mut state = self.state.lock();
        if !self.is_current(session) {
            return None;
        }
        Some(f(&mut state))
    }

    fn run(&self, session: u64, from_beginning: bool) {
        let Some((folder, initialized)) =
            self.update(session, |state| (state.folder.clone(), state.initialized))
        else {
            return;
        };
        let Some(folder) = folder else { return };
        if !initialized {
            let start = if from_beginning {
                0.0
            } else {
                recent_start(&folder)
            };
            let frame = (start * f64::from(SAMPLE_RATE)) as u64;
            let applied = self.update(session, |state| {
                for track in &mut state.tracks {
                    track.processed_frames = frame;
                }
                state.initialized = true;
                state.preview.start = Some(start);
                self.publish(state);
            });
            if applied.is_none() {
                return;
            }
        }
        while self.is_current(session) {
            let mut did_work = false;
            for index in 0..2 {
                let Some(track) = self.update(session, |state| state.tracks[index].clone()) else {
                    return;
                };
                if track.retry_after.is_some_and(|at| Instant::now() < at) {
                    continue;
                }
                match next_chunk(&folder.join(track.file), track.processed_frames) {
                    Ok(Chunk::NoWork) => {}
                    Ok(Chunk::Advance(frame)) => {
                        did_work = true;
                        if self
                            .update(session, |state| {
                                state.tracks[index].processed_frames = frame
                            })
                            .is_none()
                        {
                            return;
                        }
                    }
                    Ok(Chunk::Ready {
                        samples,
                        start_seconds,
                        end_frame,
                    }) => {
                        did_work = true;
                        if !self.transcribe(
                            session,
                            index,
                            &track,
                            &samples,
                            start_seconds,
                            end_frame,
                        ) {
                            return;
                        }
                    }
                    Err(err) => {
                        did_work = true;
                        if !self.failed(session, index, &err) {
                            return;
                        }
                    }
                }
            }
            if !did_work {
                std::thread::sleep(IDLE_POLL);
            }
        }
    }

    /// Transcribes one chunk; returns false when the session is over.
    fn transcribe(
        &self,
        session: u64,
        index: usize,
        track: &Track,
        samples: &[f32],
        start_seconds: f64,
        end_frame: u64,
    ) -> bool {
        let settings = self.shared.settings();
        let preparing = self.update(session, |state| {
            state.preview.working = true;
            if !state.transcribed_once {
                state.preview.status = Some("Preparing the transcription model…".into());
            }
            self.publish(state);
        });
        if preparing.is_none() {
            return false;
        }
        let language =
            Some(settings.transcription_language.clone()).filter(|l| l != "auto" && !l.is_empty());
        let result =
            self.shared
                .speech
                .with(&self.shared, &settings.transcription_model, |transcriber| {
                    transcriber.transcribe_samples(samples, language.as_deref())
                });
        match result {
            Ok(segments) => {
                let fresh: Vec<LiveLine> = segments
                    .into_iter()
                    .filter_map(|segment| {
                        let text = Transcript::display_text(&segment.text);
                        (!text.is_empty()).then_some(LiveLine {
                            time: start_seconds + segment.start,
                            mine: track.mine,
                            text,
                        })
                    })
                    .collect();
                self.update(session, |state| {
                    let tracked = &mut state.tracks[index];
                    tracked.processed_frames = end_frame;
                    tracked.failures = 0;
                    tracked.retry_after = None;
                    state.transcribed_once = true;
                    state.preview.working = false;
                    state.preview.status = None;
                    if !fresh.is_empty() {
                        let lines = &mut state.preview.lines;
                        lines.extend(fresh);
                        lines.sort_by(|a, b| a.time.total_cmp(&b.time));
                        let excess = lines.len().saturating_sub(MAX_LINES);
                        lines.drain(..excess);
                    }
                    self.publish(state);
                })
                .is_some()
            }
            Err(err) => self.failed(session, index, &err),
        }
    }

    /// Backs one track off, or stops the preview after repeated failures.
    /// Returns false when the session is over.
    fn failed(&self, session: u64, index: usize, err: &anyhow::Error) -> bool {
        self.update(session, |state| {
            let track = &mut state.tracks[index];
            track.failures += 1;
            let failures = track.failures;
            log::warn!(
                "live transcript failed track={} attempt={failures}: {err:#}",
                track.file
            );
            state.preview.working = false;
            if failures >= MAX_CONSECUTIVE_FAILURES {
                let message =
                    "Live preview could not continue. Retry from this point; recording is still running.";
                state.preview.state = LivePreviewState::Failed(message.into());
                state.preview.status = Some(message.into());
                self.generation.fetch_add(1, Ordering::SeqCst);
                self.publish(state);
                return false;
            }
            let delay = RETRY_BASE_SECONDS * 2f64.powi(failures as i32 - 1);
            track.retry_after = Some(Instant::now() + Duration::from_secs_f64(delay));
            state.preview.status = Some(format!(
                "Retrying live preview… ({failures}/{MAX_CONSECUTIVE_FAILURES})"
            ));
            self.publish(state);
            true
        })
        .unwrap_or(false)
    }
}

/// The latest 12 seconds of the longer track, as one start for both tracks.
fn recent_start(folder: &Path) -> f64 {
    let duration = [MIC_FILE, SYSTEM_FILE]
        .iter()
        .filter_map(|file| lokalbot_audio::read_info(&folder.join(file)).ok())
        .map(|info| info.duration_seconds())
        .fold(0.0, f64::max);
    (duration - TARGET_CHUNK_SECONDS).max(0.0)
}

/// Reads the next unprocessed chunk of a track that is still being written.
fn next_chunk(path: &Path, processed_frames: u64) -> Result<Chunk> {
    if !path.exists() {
        return Ok(Chunk::NoWork);
    }
    let mut reader = WavReader::open(path)?;
    let rate = f64::from(reader.info().sample_rate.max(1));
    let total = reader.info().frames();
    let Some((start, count)) = chunk_range(processed_frames, total, rate) else {
        return Ok(Chunk::NoWork);
    };
    reader.seek_frame(start)?;
    let mut samples = Vec::with_capacity(count as usize);
    reader.read_mono(count as usize, &mut samples)?;
    // At the live edge someone may still be mid-sentence: wait for a pause
    // rather than cut a sentence in two, unless 12 s have built up.
    let capped = (count as f64) >= TARGET_CHUNK_SECONDS * rate;
    if start + count == total && !capped && !ends_quietly(&samples, rate) {
        return Ok(Chunk::NoWork);
    }
    let search = samples.len().min((CUT_SEARCH_SECONDS * rate) as usize);
    if search > 0 {
        let cut = refined_cut_offset(&samples[samples.len() - search..], rate);
        samples.truncate(samples.len() - search + cut);
    }
    if samples.is_empty() {
        return Ok(Chunk::NoWork);
    }
    let end_frame = start + samples.len() as u64;
    let Some(mut candidate) = speech_candidate(&samples, rate) else {
        return Ok(Chunk::Advance(end_frame));
    };
    if reader.info().sample_rate != SAMPLE_RATE {
        candidate = lokalbot_audio::resample(&candidate, reader.info().sample_rate, SAMPLE_RATE);
    }
    Ok(Chunk::Ready {
        samples: candidate,
        start_seconds: start as f64 / rate,
        end_frame,
    })
}

/// `LiveTranscriptChunker.nextChunk`: at least 4 s available, at most 12 s.
fn chunk_range(processed: u64, total: u64, rate: f64) -> Option<(u64, u64)> {
    if !(rate.is_finite() && rate > 0.0) || total < processed {
        return None;
    }
    let available = total - processed;
    if (available as f64) / rate < MIN_CHUNK_SECONDS {
        return None;
    }
    let count = available.min((TARGET_CHUNK_SECONDS * rate) as u64);
    Some((processed, count))
}

/// Whether the last 400 ms are a pause relative to the chunk.
fn ends_quietly(samples: &[f32], rate: f64) -> bool {
    let tail = samples.len().min((LIVE_EDGE_PAUSE_SECONDS * rate) as usize);
    if tail == 0 {
        return true;
    }
    let tail_rms = rms(&samples[samples.len() - tail..]);
    tail_rms < (0.2 * rms(samples)).max(GATE_ABSOLUTE_FLOOR)
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (energy(samples) / samples.len() as f32).sqrt()
}

/// `LiveTranscriptChunker.refinedCutOffset`: the middle of the quietest
/// 200 ms window, so a chunk does not end mid-word.
fn refined_cut_offset(tail: &[f32], rate: f64) -> usize {
    let window = (0.2 * rate) as usize;
    let hop = (0.05 * rate) as usize;
    if window == 0 || hop == 0 || tail.len() <= window {
        return tail.len();
    }
    let mut quietest_start = 0;
    let mut quietest = f32::MAX;
    let mut start = 0;
    while start + window <= tail.len() {
        let energy: f32 = tail[start..start + window].iter().map(|s| s * s).sum();
        if energy < quietest {
            quietest = energy;
            quietest_start = start;
        }
        start += hop;
    }
    quietest_start + window / 2
}

/// `LiveTranscriptChunker.speechCandidate`: drops silence and low-frequency
/// drift only; speech detection itself is left to the VAD.
fn speech_candidate(samples: &[f32], rate: f64) -> Option<Vec<f32>> {
    if !(rate.is_finite() && rate > 0.0) || samples.is_empty() {
        return None;
    }
    let filtered = high_pass(samples, rate);
    let source_energy = energy(samples);
    let filtered_energy = energy(&filtered);
    let audible = has_audible_window(&filtered, rate);
    (source_energy.is_finite()
        && filtered_energy.is_finite()
        && source_energy > 0.0
        && filtered_energy / source_energy >= GATE_MINIMUM_HIGH_PASSED_ENERGY_RATIO
        && audible)
        .then_some(filtered)
}

fn has_audible_window(samples: &[f32], rate: f64) -> bool {
    let window = ((rate * 0.2).min(samples.len() as f64) as usize).max(1);
    let hop = (window / 2).max(1);
    let mut start = 0;
    while start < samples.len() {
        let end = (start + window).min(samples.len());
        let count = (end - start) as f32;
        let sum: f32 = samples[start..end].iter().map(|s| s * s).sum();
        if (sum / count).sqrt() > GATE_ABSOLUTE_FLOOR {
            return true;
        }
        start += hop;
    }
    false
}

fn energy(samples: &[f32]) -> f32 {
    samples.iter().map(|s| s * s).sum()
}

/// One-pole high-pass filter, started without a false DC impulse.
fn high_pass(samples: &[f32], rate: f64) -> Vec<f32> {
    let rc = 1.0 / (2.0 * std::f64::consts::PI * GATE_HIGH_PASS_HZ);
    let alpha = (rc / (rc + 1.0 / rate)) as f32;
    let mut out = Vec::with_capacity(samples.len());
    let mut previous_input = samples[0];
    let mut previous_output = 0.0f32;
    for &value in samples {
        let clean = alpha * (previous_output + value - previous_input);
        out.push(clean);
        previous_input = value;
        previous_output = clean;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: f64 = 16_000.0;

    #[test]
    fn chunks_wait_for_four_seconds_and_take_at_most_twelve() {
        assert_eq!(chunk_range(0, 3 * 16_000, RATE), None);
        assert_eq!(chunk_range(0, 5 * 16_000, RATE), Some((0, 5 * 16_000)));
        assert_eq!(
            chunk_range(16_000, 40 * 16_000, RATE),
            Some((16_000, 12 * 16_000))
        );
        assert_eq!(chunk_range(10, 5, RATE), None);
    }

    #[test]
    fn cuts_in_the_quietest_window() {
        let mut tail = vec![0.5f32; (1.5 * RATE) as usize];
        let quiet = (0.8 * RATE) as usize;
        for sample in &mut tail[quiet..quiet + (0.2 * RATE) as usize] {
            *sample = 0.0;
        }
        let cut = refined_cut_offset(&tail, RATE);
        assert!(
            cut >= quiet && cut <= quiet + (0.2 * RATE) as usize,
            "{cut}"
        );
    }

    #[test]
    fn silence_and_drift_are_not_speech_candidates() {
        assert!(speech_candidate(&vec![0.0; 16_000], RATE).is_none());
        // A constant offset is all DC: the high-pass filter removes it.
        assert!(speech_candidate(&vec![0.2; 16_000], RATE).is_none());
        let tone: Vec<f32> = (0..16_000)
            .map(|i| 0.1 * (i as f32 * 2.0 * std::f32::consts::PI * 440.0 / 16_000.0).sin())
            .collect();
        assert!(speech_candidate(&tone, RATE).is_some());
    }

    #[test]
    fn waits_for_a_pause_at_the_live_edge() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(SYSTEM_FILE);
        let speech = |seconds: f64| -> Vec<f32> {
            (0..(seconds * RATE) as usize)
                .map(|i| 0.2 * (i as f32 * 2.0 * std::f32::consts::PI * 220.0 / 16_000.0).sin())
                .collect()
        };
        // Still talking at the end of what has been recorded: wait.
        lokalbot_audio::write_wav_16k(&path, &speech(6.0)).unwrap();
        assert!(matches!(next_chunk(&path, 0).unwrap(), Chunk::NoWork));
        // A pause at the end: transcribe up to it.
        let mut paused = speech(6.0);
        paused.extend(std::iter::repeat_n(0.0, (0.6 * RATE) as usize));
        lokalbot_audio::write_wav_16k(&path, &paused).unwrap();
        assert!(matches!(next_chunk(&path, 0).unwrap(), Chunk::Ready { .. }));
        // Twelve seconds of uninterrupted speech are transcribed anyway.
        lokalbot_audio::write_wav_16k(&path, &speech(13.0)).unwrap();
        assert!(matches!(next_chunk(&path, 0).unwrap(), Chunk::Ready { .. }));
    }

    #[test]
    fn reads_a_growing_track_in_chunks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(MIC_FILE);
        let mut tone: Vec<f32> = (0..(6 * 16_000))
            .map(|i| 0.2 * (i as f32 * 2.0 * std::f32::consts::PI * 220.0 / 16_000.0).sin())
            .collect();
        tone.extend(std::iter::repeat_n(0.0, 8_000));
        lokalbot_audio::write_wav_16k(&path, &tone).unwrap();
        match next_chunk(&path, 0).unwrap() {
            Chunk::Ready {
                samples, end_frame, ..
            } => {
                assert!(end_frame <= 6 * 16_000 + 8_000 && end_frame > 4 * 16_000);
                assert_eq!(samples.len() as u64, end_frame);
            }
            _ => panic!("expected a chunk"),
        }
        assert!(matches!(
            next_chunk(&path, 3 * 16_000).unwrap(),
            Chunk::NoWork
        ));
    }
}
