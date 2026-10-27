//! Short in-memory microphone capture for dictation: 16 kHz mono samples,
//! a live level for the overlay bars, and a snapshot for live preview.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use parking_lot::Mutex;

use crate::capture::{StreamFlags, open_stream, resolve_input_device};
use crate::resample::Resampler;
use crate::track::{ChunkSink, LevelMeter, QUEUE_CAPACITY, TrackMessage, TrackState};
use crate::wav::SAMPLE_RATE;

/// Reconnections allowed before the dictation ends (`DictationCoordinator`:
/// more than 3 recoveries within 20 s ends it).
const MAX_RECOVERIES: u32 = 3;
const RECOVERY_WINDOW: Duration = Duration::from_secs(20);
/// Hard cap on memory: 30 minutes of audio.
const MAX_SAMPLES: usize = SAMPLE_RATE as usize * 60 * 30;

pub struct MicCapture {
    origin: Instant,
    state: Arc<TrackState>,
    samples: Arc<Mutex<Vec<f32>>>,
    error: Arc<Mutex<Option<String>>>,
    audio_tx: Sender<TrackMessage>,
    stop_tx: Sender<()>,
    control: Option<JoinHandle<()>>,
    worker: Option<JoinHandle<()>>,
}

impl MicCapture {
    /// Opens the microphone (`None` or empty = system default) and starts
    /// collecting audio. Fails when no microphone can be opened.
    pub fn start(device: Option<&str>) -> Result<MicCapture> {
        let origin = Instant::now();
        let state = Arc::new(TrackState::new(origin));
        let samples = Arc::new(Mutex::new(Vec::with_capacity(SAMPLE_RATE as usize * 30)));
        let error = Arc::new(Mutex::new(None));
        let (audio_tx, audio_rx) = crossbeam_channel::bounded(QUEUE_CAPACITY);
        let worker = {
            let state = Arc::clone(&state);
            let samples = Arc::clone(&samples);
            std::thread::Builder::new()
                .name("lokalbot-dictation-audio".into())
                .spawn(move || collect(audio_rx, &state, &samples))
                .context("could not start the dictation audio thread")?
        };
        let (stop_tx, stop_rx) = crossbeam_channel::bounded(1);
        let (ready_tx, ready_rx) = crossbeam_channel::bounded(1);
        let sink = ChunkSink::new(audio_tx.clone(), Arc::clone(&state));
        let device = device.map(str::to_string);
        let control_error = Arc::clone(&error);
        let control = std::thread::Builder::new()
            .name("lokalbot-dictation-mic".into())
            .spawn(move || supervise(device, sink, stop_rx, ready_tx, control_error))
            .context("could not start the dictation microphone thread")?;
        let mut capture = MicCapture {
            origin,
            state,
            samples,
            error,
            audio_tx,
            stop_tx,
            control: Some(control),
            worker: Some(worker),
        };
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => Ok(capture),
            Ok(Err(message)) => {
                capture.shutdown();
                Err(anyhow!("Could not start the microphone: {message}"))
            }
            Err(_) => {
                capture.shutdown();
                Err(anyhow!(
                    "Could not start the microphone: the audio system did not respond"
                ))
            }
        }
    }

    /// Current loudness, 0–1.
    pub fn level(&self) -> f32 {
        self.state.level()
    }

    /// Whether the microphone delivered any audio yet (the overlay dot turns red).
    pub fn has_audio(&self) -> bool {
        self.state.has_audio()
    }

    /// Time since the last buffer, `None` before the first.
    pub fn silent_for(&self) -> Option<Duration> {
        self.state.since_audio_ms().map(Duration::from_millis)
    }

    pub fn elapsed(&self) -> Duration {
        self.origin.elapsed()
    }

    /// The microphone was lost and could not be reopened.
    pub fn error(&self) -> Option<String> {
        self.error.lock().clone()
    }

    /// Seconds captured so far.
    pub fn seconds(&self) -> f64 {
        self.samples.lock().len() as f64 / SAMPLE_RATE as f64
    }

    /// Copy of everything captured so far (live preview).
    pub fn samples_16k(&self) -> Vec<f32> {
        self.samples.lock().clone()
    }

    /// Stops the microphone and returns all captured 16 kHz mono samples.
    pub fn stop(mut self) -> Vec<f32> {
        self.shutdown();
        std::mem::take(&mut *self.samples.lock())
    }

    fn shutdown(&mut self) {
        let _ = self.stop_tx.send(());
        if let Some(control) = self.control.take() {
            let _ = control.join();
        }
        let _ = self.audio_tx.send(TrackMessage::Finish {
            end: Instant::now(),
        });
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for MicCapture {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn collect(rx: Receiver<TrackMessage>, state: &TrackState, samples: &Mutex<Vec<f32>>) {
    let mut meter = LevelMeter::new();
    let mut resampler: Option<(u32, Resampler)> = None;
    let mut scratch = Vec::new();
    for message in rx.iter() {
        match message {
            TrackMessage::Audio(chunk) => {
                meter.observe(state, &chunk);
                if resampler
                    .as_ref()
                    .is_none_or(|(rate, _)| *rate != chunk.rate)
                {
                    if let Some((_, mut old)) = resampler.take() {
                        scratch.clear();
                        old.flush(&mut scratch);
                        append(samples, &scratch);
                    }
                    resampler = Some((chunk.rate, Resampler::new(chunk.rate, SAMPLE_RATE)));
                }
                if let Some((_, r)) = resampler.as_mut() {
                    scratch.clear();
                    r.process(&chunk.samples, &mut scratch);
                    append(samples, &scratch);
                }
            }
            TrackMessage::Finish { .. } => break,
        }
    }
    if let Some((_, mut r)) = resampler.take() {
        scratch.clear();
        r.flush(&mut scratch);
        append(samples, &scratch);
    }
}

fn append(samples: &Mutex<Vec<f32>>, new: &[f32]) {
    let mut samples = samples.lock();
    let room = MAX_SAMPLES.saturating_sub(samples.len());
    samples.extend_from_slice(&new[..new.len().min(room)]);
}

fn supervise(
    device: Option<String>,
    sink: ChunkSink,
    stop_rx: Receiver<()>,
    ready_tx: Sender<Result<(), String>>,
    error: Arc<Mutex<Option<String>>>,
) {
    let flags = Arc::new(StreamFlags::default());
    let open = |flags: &Arc<StreamFlags>| -> Result<cpal::Stream, String> {
        flags.reset();
        let (input, _) = resolve_input_device(device.as_deref()).map_err(|e| e.to_string())?;
        open_stream(&input, false, sink.clone(), Arc::clone(flags)).map_err(|e| format!("{e:#}"))
    };
    let mut stream = match open(&flags) {
        Ok(stream) => {
            sink.state().running.store(true, Ordering::Relaxed);
            let _ = ready_tx.send(Ok(()));
            Some(stream)
        }
        Err(message) => {
            let _ = ready_tx.send(Err(message));
            return;
        }
    };
    let mut recoveries: Vec<Instant> = Vec::new();
    loop {
        match stop_rx.recv_timeout(Duration::from_millis(200)) {
            Ok(()) | Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => {}
        }
        if !flags.failed() {
            continue;
        }
        stream = None;
        recoveries.retain(|at| at.elapsed() < RECOVERY_WINDOW);
        recoveries.push(Instant::now());
        if recoveries.len() as u32 > MAX_RECOVERIES {
            *error.lock() = Some(
                flags
                    .last_error()
                    .unwrap_or_else(|| "The microphone stopped".into()),
            );
            sink.state().running.store(false, Ordering::Relaxed);
            break;
        }
        sink.state()
            .recovering_attempt
            .store(recoveries.len() as u32, Ordering::Relaxed);
        std::thread::sleep(Duration::from_millis(300));
        match open(&flags) {
            Ok(reopened) => {
                stream = Some(reopened);
                sink.state().recovering_attempt.store(0, Ordering::Relaxed);
            }
            Err(message) => flags.fail(message),
        }
    }
    drop(stream);
    sink.state().running.store(false, Ordering::Relaxed);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mic_capture_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<MicCapture>();
    }
}
