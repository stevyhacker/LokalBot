//! Meeting recording: `mic.wav` ("Me") and `system.wav` ("Them") on one timeline.
//!
//! Streams live on a control thread (cpal streams are not `Send` everywhere),
//! which also reconnects a lost microphone and follows the default output
//! device. Each track has its own writer thread. `Recorder` itself only holds
//! channels and counters, so it is `Send` and can sit behind a mutex.

use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use parking_lot::Mutex;

use crate::capture::{StreamFlags, open_stream, resolve_input_device};
use crate::system::SystemCapture;
use crate::track::{ChunkSink, TrackState, TrackWriter};

pub const MIC_FILE: &str = "mic.wav";
pub const SYSTEM_FILE: &str = "system.wav";

/// A source counts as recently active within this window (`RecordingMemoryHealthSnapshot.isRecent`).
const RECENT_MS: u64 = 10_000;
/// A microphone that delivers nothing for this long is reopened.
const MIC_STALL_MS: u64 = 3_000;
/// The Linux monitor delivers silence continuously; nothing for this long means it broke.
const SYSTEM_STALL_MS: u64 = 5_000;
const CONTROL_TICK: Duration = Duration::from_millis(250);
const START_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RecorderOptions {
    /// Stored microphone id (see [`crate::AudioDevice::id`]) or name; `None` or
    /// empty records from the system default input.
    pub mic_device: Option<String>,
    /// Record what the computer plays (`settings.recordSystemAudio`).
    pub capture_system: bool,
}

/// Current loudness, 0–1, for the 20-segment meters.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Levels {
    pub mic: f32,
    pub system: f32,
}

/// One source in the recording health strip.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TrackHealth {
    ReceivingAudio,
    WaitingForAudio,
    NoRecentAudio,
    /// System audio arrives but is silent.
    Silent,
    /// System audio is off or could not be captured.
    NotAttached,
    Stopped,
    /// Reconnecting the microphone; `attempt` starts at 1.
    Recovering {
        attempt: u32,
    },
    Degraded(String),
}

impl TrackHealth {
    /// The macOS health strip wording (without the attempt number or detail).
    pub fn label(&self) -> &'static str {
        match self {
            Self::ReceivingAudio => "Receiving audio",
            Self::WaitingForAudio => "Waiting for audio",
            Self::NoRecentAudio => "No recent audio",
            Self::Silent => "Silent",
            Self::NotAttached => "Not attached",
            Self::Stopped => "Stopped",
            Self::Recovering { .. } => "Recovering",
            Self::Degraded(_) => "Degraded",
        }
    }

    pub fn is_good(&self) -> bool {
        matches!(self, Self::ReceivingAudio)
    }
}

impl fmt::Display for TrackHealth {
    /// Full wording: "Recovering (attempt 2)", "Degraded: …".
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Recovering { attempt } => write!(f, "Recovering (attempt {attempt})"),
            Self::Degraded(detail) => write!(f, "Degraded: {detail}"),
            other => f.write_str(other.label()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrackStatus {
    pub mic: TrackHealth,
    pub system: TrackHealth,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct RecordingResult {
    pub mic: Option<PathBuf>,
    pub system: Option<PathBuf>,
    pub mic_seconds: f64,
    pub system_seconds: f64,
    pub has_system_audio: bool,
    pub warnings: Vec<String>,
}

impl RecordingResult {
    /// The longer track (`meeting.recordedDuration`).
    pub fn duration_seconds(&self) -> f64 {
        self.mic_seconds.max(self.system_seconds)
    }
}

enum Control {
    Stop,
}

struct StartReport {
    mic: Result<(), String>,
    system: Option<Result<(), String>>,
    warnings: Vec<String>,
}

pub struct Recorder {
    dir: PathBuf,
    origin: Instant,
    mic: Option<TrackWriter>,
    system: Option<TrackWriter>,
    mic_state: Arc<TrackState>,
    system_state: Option<Arc<TrackState>>,
    control_tx: Sender<Control>,
    control: Option<JoinHandle<()>>,
    warnings: Arc<Mutex<Vec<String>>>,
    has_system_audio: bool,
}

impl Recorder {
    /// Starts recording into `dir` (created if needed). The microphone must
    /// open unless system audio does; a system-audio failure records the
    /// microphone alone with a warning, as on macOS.
    pub fn start(dir: &Path, options: RecorderOptions) -> Result<Recorder> {
        std::fs::create_dir_all(dir)
            .with_context(|| format!("could not create {}", dir.display()))?;
        let origin = Instant::now();
        let mic =
            TrackWriter::create(&dir.join(MIC_FILE), origin).context("could not create mic.wav")?;
        let system = if options.capture_system {
            Some(
                TrackWriter::create(&dir.join(SYSTEM_FILE), origin)
                    .context("could not create system.wav")?,
            )
        } else {
            None
        };
        let warnings = Arc::new(Mutex::new(Vec::new()));
        let (control_tx, control_rx) = crossbeam_channel::unbounded();
        let (report_tx, report_rx) = crossbeam_channel::bounded(1);
        let mic_sink = mic.sink();
        let system_sink = system.as_ref().map(TrackWriter::sink);
        let thread_warnings = Arc::clone(&warnings);
        let mic_device = options.mic_device.clone();
        let control = std::thread::Builder::new()
            .name("lokalbot-recorder".into())
            .spawn(move || {
                run_control(
                    mic_device,
                    mic_sink,
                    system_sink,
                    control_rx,
                    report_tx,
                    thread_warnings,
                )
            })
            .context("could not start the recorder thread")?;

        let report: StartReport = match report_rx.recv_timeout(START_TIMEOUT) {
            Ok(report) => report,
            Err(_) => StartReport {
                mic: Err("the audio system did not respond".into()),
                system: system
                    .as_ref()
                    .map(|_| Err("the audio system did not respond".into())),
                warnings: Vec::new(),
            },
        };
        let mic_state = Arc::clone(&mic.state);
        let system_state = system.as_ref().map(|s| Arc::clone(&s.state));
        let mut recorder = Recorder {
            dir: dir.to_path_buf(),
            origin,
            mic: Some(mic),
            system,
            mic_state,
            system_state,
            control_tx,
            control: Some(control),
            warnings,
            has_system_audio: false,
        };
        recorder.warnings.lock().extend(report.warnings);
        let system_ok = match &report.system {
            Some(Ok(())) => true,
            Some(Err(error)) => {
                let message =
                    format!("System audio capture failed ({error}) — recording mic only.");
                log::warn!("audio: {message}");
                recorder.warnings.lock().push(message);
                recorder.drop_system_track();
                false
            }
            None => false,
        };
        recorder.has_system_audio = system_ok;
        if let Err(error) = &report.mic {
            if !system_ok {
                recorder.shutdown(Instant::now());
                let _ = std::fs::remove_file(dir.join(MIC_FILE));
                return Err(anyhow!("Could not start the microphone: {error}"));
            }
            let message =
                format!("Microphone capture failed ({error}) — recording system audio only.");
            log::warn!("audio: {message}");
            recorder.warnings.lock().push(message);
            if let Some(mic) = recorder.mic.take() {
                let _ = mic.finish(Instant::now());
            }
            let _ = std::fs::remove_file(dir.join(MIC_FILE));
        }
        Ok(recorder)
    }

    fn drop_system_track(&mut self) {
        if let Some(system) = self.system.take() {
            let path = system.path.clone();
            let _ = system.finish(Instant::now());
            let _ = std::fs::remove_file(path);
        }
        self.system_state = None;
    }

    /// True when system capture attached at start; false means a mic-only recording.
    pub fn has_system_audio(&self) -> bool {
        self.has_system_audio
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn elapsed(&self) -> Duration {
        self.origin.elapsed()
    }

    pub fn levels(&self) -> Levels {
        Levels {
            mic: if self.mic.is_some() {
                self.mic_state.level()
            } else {
                0.0
            },
            system: self.system_state.as_ref().map_or(0.0, |s| s.level()),
        }
    }

    pub fn status(&self) -> TrackStatus {
        TrackStatus {
            mic: if self.mic.is_some() {
                mic_health(&self.mic_state)
            } else {
                TrackHealth::Stopped
            },
            system: match &self.system_state {
                Some(state) => system_health(state),
                None => TrackHealth::NotAttached,
            },
        }
    }

    /// Warnings so far (system capture failure, microphone fallback).
    pub fn warnings(&self) -> Vec<String> {
        self.warnings.lock().clone()
    }

    /// Stops both tracks at the same instant and closes the files.
    pub fn stop(mut self) -> Result<RecordingResult> {
        let end = Instant::now();
        self.shutdown_control();
        let mut result = RecordingResult {
            has_system_audio: self.has_system_audio,
            ..Default::default()
        };
        let mut first_error = None;
        if let Some(mic) = self.mic.take() {
            let path = mic.path.clone();
            match mic.finish(end) {
                Ok(frames) => {
                    result.mic_seconds = frames as f64 / crate::wav::SAMPLE_RATE as f64;
                    result.mic = Some(path);
                }
                Err(error) => {
                    first_error = Some(anyhow!(error).context("could not finish mic.wav"))
                }
            }
        }
        if let Some(system) = self.system.take() {
            let path = system.path.clone();
            match system.finish(end) {
                Ok(frames) => {
                    result.system_seconds = frames as f64 / crate::wav::SAMPLE_RATE as f64;
                    result.system = Some(path);
                }
                Err(error) => {
                    first_error
                        .get_or_insert(anyhow!(error).context("could not finish system.wav"));
                }
            }
        }
        result.has_system_audio = result.system.is_some();
        result.warnings = self.warnings.lock().clone();
        for (name, state) in [
            ("mic", Some(&self.mic_state)),
            ("system", self.system_state.as_ref()),
        ] {
            if let Some(dropped) = state.map(|s| s.dropped_buffers()).filter(|n| *n > 0) {
                log::warn!("audio: {name} track dropped {dropped} buffers (writer fell behind)");
            }
        }
        match first_error {
            Some(error) if result.mic.is_none() && result.system.is_none() => Err(error),
            Some(error) => {
                result.warnings.push(format!("{error:#}"));
                Ok(result)
            }
            None => Ok(result),
        }
    }

    fn shutdown_control(&mut self) {
        let _ = self.control_tx.send(Control::Stop);
        if let Some(control) = self.control.take() {
            let _ = control.join();
        }
    }

    fn shutdown(&mut self, end: Instant) {
        self.shutdown_control();
        if let Some(mic) = self.mic.take() {
            let _ = mic.finish(end);
        }
        if let Some(system) = self.system.take() {
            let _ = system.finish(end);
        }
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        self.shutdown(Instant::now());
    }
}

fn mic_health(state: &TrackState) -> TrackHealth {
    if let Some(detail) = state.degraded.lock().clone() {
        return TrackHealth::Degraded(detail);
    }
    let attempt = state.recovering_attempt.load(Ordering::Relaxed);
    if attempt > 0 {
        return TrackHealth::Recovering { attempt };
    }
    if !state.running.load(Ordering::Relaxed) {
        return TrackHealth::Stopped;
    }
    match state.since_audio_ms() {
        None => TrackHealth::WaitingForAudio,
        Some(ms) if ms <= RECENT_MS => TrackHealth::ReceivingAudio,
        Some(_) => TrackHealth::NoRecentAudio,
    }
}

fn system_health(state: &TrackState) -> TrackHealth {
    if !state.attached.load(Ordering::Relaxed) {
        return TrackHealth::NotAttached;
    }
    let quiet_loopback = state.silent_without_packets.load(Ordering::Relaxed)
        && state.running.load(Ordering::Relaxed);
    match state.since_audio_ms() {
        None if quiet_loopback => TrackHealth::Silent,
        None => TrackHealth::WaitingForAudio,
        Some(ms) if ms > RECENT_MS && !quiet_loopback => TrackHealth::NoRecentAudio,
        Some(_) => match state.since_audible_ms() {
            Some(ms) if ms <= RECENT_MS => TrackHealth::ReceivingAudio,
            _ => TrackHealth::Silent,
        },
    }
}

/// Exponential backoff for reconnecting: 0.5 s, 1 s, 2 s, then every 4 s.
fn retry_delay(attempt: u32) -> Duration {
    Duration::from_millis(match attempt {
        0 | 1 => 500,
        2 => 1_000,
        3 => 2_000,
        _ => 4_000,
    })
}

struct MicSource {
    preferred: Option<String>,
    sink: ChunkSink,
    flags: Arc<StreamFlags>,
    stream: Option<cpal::Stream>,
    attempt: u32,
    next_retry: Option<Instant>,
}

impl MicSource {
    fn open(&mut self, warnings: &Mutex<Vec<String>>) -> Result<(), String> {
        self.stream = None;
        self.flags.reset();
        let (device, warning) =
            resolve_input_device(self.preferred.as_deref()).map_err(|e| e.to_string())?;
        let stream = open_stream(&device, false, self.sink.clone(), Arc::clone(&self.flags))
            .map_err(|e| format!("{e:#}"))?;
        if let Some(warning) = warning {
            let mut warnings = warnings.lock();
            if !warnings.contains(&warning) {
                warnings.push(warning);
            }
        }
        self.stream = Some(stream);
        let state = self.sink.state();
        state.running.store(true, Ordering::Relaxed);
        state.attached.store(true, Ordering::Relaxed);
        Ok(())
    }

    /// Reopens the microphone after an error or a stall.
    fn supervise(&mut self, warnings: &Mutex<Vec<String>>, opened_at: &mut Instant) {
        let state = Arc::clone(self.sink.state());
        let stalled = self.stream.is_some()
            && opened_at.elapsed() > Duration::from_millis(MIC_STALL_MS)
            && match state.since_audio_ms() {
                Some(ms) => ms > MIC_STALL_MS,
                None => true,
            };
        if self.stream.is_some() && !self.flags.failed() && !stalled {
            return;
        }
        if self.stream.is_some() {
            let reason = self
                .flags
                .last_error()
                .unwrap_or_else(|| "no audio from the microphone".into());
            log::warn!("audio: microphone lost ({reason}); reconnecting");
            self.stream = None;
            state.running.store(false, Ordering::Relaxed);
            self.next_retry = Some(Instant::now() + retry_delay(1));
            self.attempt = 1;
            state.recovering_attempt.store(1, Ordering::Relaxed);
            return;
        }
        let Some(next) = self.next_retry else { return };
        if Instant::now() < next {
            return;
        }
        state
            .recovering_attempt
            .store(self.attempt, Ordering::Relaxed);
        match self.open(warnings) {
            Ok(()) => {
                log::info!(
                    "audio: microphone reconnected after {} attempt(s)",
                    self.attempt
                );
                self.attempt = 0;
                self.next_retry = None;
                state.recovering_attempt.store(0, Ordering::Relaxed);
                *state.degraded.lock() = None;
                *opened_at = Instant::now();
            }
            Err(error) => {
                self.attempt += 1;
                self.next_retry = Some(Instant::now() + retry_delay(self.attempt));
                state
                    .recovering_attempt
                    .store(self.attempt, Ordering::Relaxed);
                if self.attempt > 10 {
                    *state.degraded.lock() = Some(error);
                }
            }
        }
    }
}

fn run_control(
    mic_device: Option<String>,
    mic_sink: ChunkSink,
    system_sink: Option<ChunkSink>,
    control_rx: Receiver<Control>,
    report_tx: Sender<StartReport>,
    warnings: Arc<Mutex<Vec<String>>>,
) {
    let mut mic = MicSource {
        preferred: mic_device,
        sink: mic_sink,
        flags: Arc::new(StreamFlags::default()),
        stream: None,
        attempt: 0,
        next_retry: None,
    };
    let mic_result = mic.open(&warnings);
    let mut mic_opened_at = Instant::now();
    let mut system = None;
    let system_result = system_sink.map(|sink| {
        let state = Arc::clone(sink.state());
        match SystemCapture::start(sink, Arc::new(StreamFlags::default())) {
            Ok(capture) => {
                state.running.store(true, Ordering::Relaxed);
                state.attached.store(true, Ordering::Relaxed);
                system = Some((capture, state));
                Ok(())
            }
            Err(error) => Err(format!("{error:#}")),
        }
    });
    let mic_failed = mic_result.is_err();
    let _ = report_tx.send(StartReport {
        mic: mic_result,
        system: system_result,
        warnings: Vec::new(),
    });
    if mic_failed {
        mic.stream = None;
    }

    let mut system_retry: Option<(Instant, u32)> = None;
    loop {
        match control_rx.recv_timeout(CONTROL_TICK) {
            Ok(Control::Stop) | Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => {}
        }
        if !mic_failed {
            mic.supervise(&warnings, &mut mic_opened_at);
        }
        if let Some((capture, state)) = system.as_mut() {
            if let Some(note) = capture.follow_default_device() {
                log::info!("audio: {note}");
            }
            let stalled = !state.silent_without_packets.load(Ordering::Relaxed)
                && state
                    .since_audio_ms()
                    .is_some_and(|ms| ms > SYSTEM_STALL_MS);
            if capture.flags().failed() || stalled {
                let due = system_retry.is_none_or(|(at, _)| Instant::now() >= at);
                if due {
                    let attempt = system_retry.map_or(1, |(_, n)| n + 1);
                    match capture.restart() {
                        Ok(()) => {
                            log::info!("audio: system audio capture restarted");
                            system_retry = None;
                            state.running.store(true, Ordering::Relaxed);
                        }
                        Err(error) => {
                            log::warn!("audio: system audio restart failed: {error:#}");
                            state.running.store(false, Ordering::Relaxed);
                            system_retry = Some((Instant::now() + retry_delay(attempt), attempt));
                        }
                    }
                }
            }
        }
    }
    mic.stream = None;
    mic.sink.state().running.store(false, Ordering::Relaxed);
    if let Some((capture, state)) = system.take() {
        drop(capture);
        state.running.store(false, Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn labels_match_the_health_strip() {
        assert_eq!(TrackHealth::ReceivingAudio.label(), "Receiving audio");
        assert_eq!(TrackHealth::NotAttached.to_string(), "Not attached");
        assert_eq!(
            TrackHealth::Recovering { attempt: 2 }.to_string(),
            "Recovering (attempt 2)"
        );
        assert_eq!(
            TrackHealth::Degraded("device lost".into()).to_string(),
            "Degraded: device lost"
        );
    }

    #[test]
    fn fresh_tracks_wait_for_audio() {
        let state = TrackState::new(Instant::now());
        state.running.store(true, Ordering::Relaxed);
        state.attached.store(true, Ordering::Relaxed);
        assert_eq!(mic_health(&state), TrackHealth::WaitingForAudio);
        assert_eq!(system_health(&state), TrackHealth::WaitingForAudio);
        state.silent_without_packets.store(true, Ordering::Relaxed);
        assert_eq!(system_health(&state), TrackHealth::Silent);
        let detached = TrackState::new(Instant::now());
        assert_eq!(system_health(&detached), TrackHealth::NotAttached);
        assert_eq!(mic_health(&detached), TrackHealth::Stopped);
    }

    #[test]
    fn recorder_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<Recorder>();
    }
}
