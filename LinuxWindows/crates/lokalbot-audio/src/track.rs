//! One recorded track: the writer thread that places captured buffers on the
//! meeting timeline, resamples them to 16 kHz and appends them to the WAV file,
//! plus the health counters the recording strip reads.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, Sender, TrySendError};
use parking_lot::Mutex;

use crate::resample::Resampler;
use crate::wav::{SAMPLE_RATE, WavWriter};

/// RMS at or above this counts as audible (`SystemAudioRecorder.audibleRMSThreshold`).
pub(crate) const AUDIBLE_RMS: f32 = 0.0005;
/// Small clock and scheduling jitter is tolerated without inserting silence
/// (`RecordingAudioTimeline.jitterTolerance`, 20 ms).
pub(crate) const JITTER_TOLERANCE_FRAMES: i64 = SAMPLE_RATE as i64 / 50;
/// A level older than this reads as silence (`AudioLevelMeter.maximumAgeNanoseconds`).
const LEVEL_MAX_AGE_MS: u64 = 500;
/// Meter values are the peak over windows of this length.
const LEVEL_WINDOW: Duration = Duration::from_millis(100);
const NEVER: u64 = u64::MAX;
/// Bounded queue between the audio callback and the writer (about 20 s of 10 ms buffers).
pub(crate) const QUEUE_CAPACITY: usize = 2048;

/// 0 at −55 dBFS (room noise), 1 at −10 dBFS (loud speech), as `AudioLevelMeter.normalized`.
pub fn normalized_level(rms: f32) -> f32 {
    if rms.is_nan() || rms <= 0.0 {
        return 0.0;
    }
    let decibels = 20.0 * rms.log10();
    ((decibels + 55.0) / 45.0).clamp(0.0, 1.0)
}

pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples
        .iter()
        .map(|&s| {
            if s.is_finite() {
                (s as f64) * (s as f64)
            } else {
                0.0
            }
        })
        .sum();
    (sum / samples.len() as f64).sqrt() as f32
}

/// A captured buffer, already mixed down to mono.
pub(crate) struct Chunk {
    pub samples: Vec<f32>,
    pub rate: u32,
    /// When the callback delivered it; the buffer ends at about this instant.
    pub received: Instant,
}

pub(crate) enum TrackMessage {
    Audio(Chunk),
    /// Pad to `end` on the timeline, close the file and exit.
    Finish {
        end: Instant,
    },
}

/// Counters shared by the capture callback, the writer and the UI.
pub(crate) struct TrackState {
    origin: Instant,
    level_bits: AtomicU32,
    level_at_ms: AtomicU64,
    last_audio_ms: AtomicU64,
    last_audible_ms: AtomicU64,
    frames: AtomicU64,
    audible_frames: AtomicU64,
    dropped_buffers: AtomicU64,
    /// The capture stream exists and has not reported a fatal error.
    pub running: AtomicBool,
    /// The source was attached at least once.
    pub attached: AtomicBool,
    /// 0 while healthy; otherwise the current reconnection attempt.
    pub recovering_attempt: AtomicU32,
    /// WASAPI loopback delivers no packets while nothing plays; a quiet but
    /// healthy stream then reads as silent rather than stalled.
    pub silent_without_packets: AtomicBool,
    pub degraded: Mutex<Option<String>>,
}

impl TrackState {
    pub fn new(origin: Instant) -> Self {
        Self {
            origin,
            level_bits: AtomicU32::new(0),
            level_at_ms: AtomicU64::new(NEVER),
            last_audio_ms: AtomicU64::new(NEVER),
            last_audible_ms: AtomicU64::new(NEVER),
            frames: AtomicU64::new(0),
            audible_frames: AtomicU64::new(0),
            dropped_buffers: AtomicU64::new(0),
            running: AtomicBool::new(false),
            attached: AtomicBool::new(false),
            recovering_attempt: AtomicU32::new(0),
            silent_without_packets: AtomicBool::new(false),
            degraded: Mutex::new(None),
        }
    }

    fn ms(&self, at: Instant) -> u64 {
        at.saturating_duration_since(self.origin).as_millis() as u64
    }

    pub fn now_ms(&self) -> u64 {
        self.ms(Instant::now())
    }

    pub fn level(&self) -> f32 {
        let at = self.level_at_ms.load(Ordering::Relaxed);
        if at == NEVER || self.now_ms().saturating_sub(at) > LEVEL_MAX_AGE_MS {
            return 0.0;
        }
        f32::from_bits(self.level_bits.load(Ordering::Relaxed))
    }

    fn publish_level(&self, level: f32, at: Instant) {
        self.level_bits.store(level.to_bits(), Ordering::Relaxed);
        self.level_at_ms.store(self.ms(at), Ordering::Relaxed);
    }

    /// Milliseconds since the last delivered buffer, or `None` if none arrived yet.
    pub fn since_audio_ms(&self) -> Option<u64> {
        let at = self.last_audio_ms.load(Ordering::Relaxed);
        (at != NEVER).then(|| self.now_ms().saturating_sub(at))
    }

    pub fn since_audible_ms(&self) -> Option<u64> {
        let at = self.last_audible_ms.load(Ordering::Relaxed);
        (at != NEVER).then(|| self.now_ms().saturating_sub(at))
    }

    pub fn has_audio(&self) -> bool {
        self.last_audio_ms.load(Ordering::Relaxed) != NEVER
    }

    pub fn dropped_buffers(&self) -> u64 {
        self.dropped_buffers.load(Ordering::Relaxed)
    }
}

/// Feeds a capture callback's buffers to a track. Cheap to clone; never blocks.
#[derive(Clone)]
pub(crate) struct ChunkSink {
    tx: Sender<TrackMessage>,
    state: Arc<TrackState>,
}

impl ChunkSink {
    pub fn new(tx: Sender<TrackMessage>, state: Arc<TrackState>) -> Self {
        Self { tx, state }
    }

    pub fn state(&self) -> &Arc<TrackState> {
        &self.state
    }

    /// Only the Linux sound-server capture lacks capture timestamps.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub fn push(&self, samples: Vec<f32>, rate: u32) {
        self.push_captured(samples, rate, None);
    }

    /// `latency` is how long ago the buffer's first frame was captured, when
    /// the backend knows it; the buffer is then placed by capture time.
    pub fn push_captured(&self, samples: Vec<f32>, rate: u32, latency: Option<Duration>) {
        if samples.is_empty() || rate == 0 {
            return;
        }
        let now = Instant::now();
        let length = Duration::from_secs_f64(samples.len() as f64 / rate as f64);
        let received = match latency.filter(|l| *l < Duration::from_secs(10)) {
            Some(latency) => (now.checked_sub(latency).unwrap_or(now) + length).min(now),
            None => now,
        };
        let chunk = Chunk {
            samples,
            rate,
            received,
        };
        match self.tx.try_send(TrackMessage::Audio(chunk)) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) => {
                self.state.dropped_buffers.fetch_add(1, Ordering::Relaxed);
            }
            Err(TrySendError::Disconnected(_)) => {}
        }
    }
}

/// Places buffers on the shared meeting timeline: silence fills any gap
/// longer than the jitter tolerance before a buffer, so a late start, a
/// reconnect or a quiet loopback never shifts later speech earlier.
pub(crate) struct Timeline {
    origin: Instant,
    resampler: Option<Resampler>,
    rate: u32,
    scratch: Vec<f32>,
}

impl Timeline {
    pub fn new(origin: Instant) -> Self {
        Self {
            origin,
            resampler: None,
            rate: 0,
            scratch: Vec::new(),
        }
    }

    /// Frame on the 16 kHz timeline where a buffer of `frames` at `rate`,
    /// delivered at `received`, began.
    fn start_frame(&self, received: Instant, frames: usize, rate: u32) -> i64 {
        let end = received
            .saturating_duration_since(self.origin)
            .as_secs_f64();
        let start = end - frames as f64 / rate as f64;
        (start * SAMPLE_RATE as f64).round() as i64
    }

    /// Appends one buffer through `write`, padding and resampling as needed.
    /// `written` is the number of frames already in the output.
    pub fn place(
        &mut self,
        chunk: &Chunk,
        written: u64,
        out: &mut dyn FnMut(Segment<'_>) -> io::Result<()>,
    ) -> io::Result<()> {
        let mut written = written;
        if self.rate != chunk.rate || self.resampler.is_none() {
            self.flush(out, &mut written)?;
            self.resampler = Some(Resampler::new(chunk.rate, SAMPLE_RATE));
            self.rate = chunk.rate;
        }
        let start = self.start_frame(chunk.received, chunk.samples.len(), chunk.rate);
        let pending = self.resampler.as_ref().map_or(0, |r| {
            // Output the resampler still owes for input it has already seen.
            let owed = (r.input_frames() * SAMPLE_RATE as u64).div_ceil(chunk.rate as u64);
            owed.saturating_sub(r.output_len())
        });
        let missing = start - (written + pending) as i64;
        if missing > JITTER_TOLERANCE_FRAMES {
            // A gap: finish the previous run, fill the silence, restart cleanly.
            self.flush(out, &mut written)?;
            let missing = start - written as i64;
            if missing > 0 {
                out(Segment::Silence(missing as u64))?;
            }
            self.resampler = Some(Resampler::new(chunk.rate, SAMPLE_RATE));
        }
        self.scratch.clear();
        if let Some(resampler) = self.resampler.as_mut() {
            resampler.process(&chunk.samples, &mut self.scratch);
        }
        if !self.scratch.is_empty() {
            out(Segment::Samples(&self.scratch))?;
        }
        Ok(())
    }

    fn flush(
        &mut self,
        out: &mut dyn FnMut(Segment<'_>) -> io::Result<()>,
        written: &mut u64,
    ) -> io::Result<()> {
        if let Some(mut resampler) = self.resampler.take() {
            self.scratch.clear();
            resampler.flush(&mut self.scratch);
            if !self.scratch.is_empty() {
                *written += self.scratch.len() as u64;
                out(Segment::Samples(&self.scratch))?;
            }
        }
        Ok(())
    }

    /// Flushes the resampler and pads the track to `end`.
    pub fn finish(
        &mut self,
        end: Instant,
        written: u64,
        out: &mut dyn FnMut(Segment<'_>) -> io::Result<()>,
    ) -> io::Result<()> {
        let mut written = written;
        self.flush(out, &mut written)?;
        let end_frame = (end.saturating_duration_since(self.origin).as_secs_f64()
            * SAMPLE_RATE as f64)
            .round() as i64;
        let missing = end_frame - written as i64;
        if missing > JITTER_TOLERANCE_FRAMES {
            out(Segment::Silence(missing as u64))?;
        }
        Ok(())
    }
}

pub(crate) enum Segment<'a> {
    Samples(&'a [f32]),
    Silence(u64),
}

/// A track being written to disk.
pub(crate) struct TrackWriter {
    pub path: PathBuf,
    pub state: Arc<TrackState>,
    pub tx: Sender<TrackMessage>,
    handle: Option<JoinHandle<io::Result<u64>>>,
}

impl TrackWriter {
    pub fn create(path: &Path, origin: Instant) -> io::Result<Self> {
        let writer = WavWriter::create(path)?;
        let state = Arc::new(TrackState::new(origin));
        let (tx, rx) = crossbeam_channel::bounded(QUEUE_CAPACITY);
        let thread_state = Arc::clone(&state);
        let handle = std::thread::Builder::new()
            .name("lokalbot-track-writer".into())
            .spawn(move || run_writer(writer, rx, thread_state, origin))?;
        Ok(Self {
            path: path.to_path_buf(),
            state,
            tx,
            handle: Some(handle),
        })
    }

    pub fn sink(&self) -> ChunkSink {
        ChunkSink::new(self.tx.clone(), Arc::clone(&self.state))
    }

    /// Pads to `end`, closes the file and returns its length in frames.
    pub fn finish(mut self, end: Instant) -> io::Result<u64> {
        let _ = self.tx.send(TrackMessage::Finish { end });
        match self.handle.take() {
            Some(handle) => handle
                .join()
                .map_err(|_| io::Error::other("track writer panicked"))?,
            None => Ok(0),
        }
    }
}

impl Drop for TrackWriter {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            let _ = self.tx.send(TrackMessage::Finish {
                end: Instant::now(),
            });
            let _ = handle.join();
        }
    }
}

/// Updates a track's health counters and meter for each delivered buffer.
pub(crate) struct LevelMeter {
    peak: f32,
    window_start: Option<Instant>,
}

impl LevelMeter {
    pub fn new() -> Self {
        Self {
            peak: 0.0,
            window_start: None,
        }
    }

    pub fn observe(&mut self, state: &TrackState, chunk: &Chunk) {
        let level_rms = rms(&chunk.samples);
        let at = state.ms(chunk.received);
        state.last_audio_ms.store(at, Ordering::Relaxed);
        if level_rms >= AUDIBLE_RMS {
            state.last_audible_ms.store(at, Ordering::Relaxed);
            let frames = chunk.samples.len() as u64 * SAMPLE_RATE as u64 / chunk.rate.max(1) as u64;
            state.audible_frames.fetch_add(frames, Ordering::Relaxed);
        }
        self.peak = self.peak.max(normalized_level(level_rms));
        let window = *self.window_start.get_or_insert(chunk.received);
        if chunk.received.saturating_duration_since(window) >= LEVEL_WINDOW
            || state.level_at_ms.load(Ordering::Relaxed) == NEVER
        {
            state.publish_level(self.peak, chunk.received);
            self.peak = 0.0;
            self.window_start = Some(chunk.received);
        }
    }
}

fn run_writer(
    mut writer: WavWriter,
    rx: Receiver<TrackMessage>,
    state: Arc<TrackState>,
    origin: Instant,
) -> io::Result<u64> {
    let mut timeline = Timeline::new(origin);
    let mut meter = LevelMeter::new();
    let mut result: io::Result<()> = Ok(());
    let mut end = None;
    for message in rx.iter() {
        match message {
            TrackMessage::Audio(chunk) => {
                meter.observe(&state, &chunk);
                if result.is_ok() {
                    let written = writer.frames();
                    result = timeline.place(&chunk, written, &mut |segment| {
                        write_segment(&mut writer, segment)
                    });
                    state.frames.store(writer.frames(), Ordering::Relaxed);
                    if let Err(error) = &result {
                        log::error!(
                            "audio track {}: write failed: {error}",
                            writer.path().display()
                        );
                        *state.degraded.lock() = Some(format!("Could not write audio: {error}"));
                    }
                }
            }
            TrackMessage::Finish { end: at } => {
                end = Some(at);
                break;
            }
        }
    }
    if result.is_ok() {
        let written = writer.frames();
        let end = end.unwrap_or_else(Instant::now);
        result = timeline.finish(end, written, &mut |segment| {
            write_segment(&mut writer, segment)
        });
    }
    state.frames.store(writer.frames(), Ordering::Relaxed);
    let frames = writer.finish()?;
    result.map(|()| frames)
}

fn write_segment(writer: &mut WavWriter, segment: Segment<'_>) -> io::Result<()> {
    match segment {
        Segment::Samples(samples) => writer.write_samples(samples),
        Segment::Silence(frames) => writer.write_silence(frames),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Collector {
        samples: Vec<f32>,
    }

    impl Collector {
        fn write(&mut self, segment: Segment<'_>) -> io::Result<()> {
            match segment {
                Segment::Samples(s) => self.samples.extend_from_slice(s),
                Segment::Silence(n) => self.samples.extend(std::iter::repeat_n(0.0, n as usize)),
            }
            Ok(())
        }
    }

    fn chunk(origin: Instant, end_ms: u64, frames: usize, rate: u32, value: f32) -> Chunk {
        Chunk {
            samples: vec![value; frames],
            rate,
            received: origin + Duration::from_millis(end_ms),
        }
    }

    #[test]
    fn late_start_is_padded_with_silence() {
        let origin = Instant::now();
        let mut timeline = Timeline::new(origin);
        let mut out = Collector {
            samples: Vec::new(),
        };
        // First buffer covers 1.00–1.01 s at 48 kHz.
        for i in 0..100u64 {
            let c = chunk(origin, 1010 + i * 10, 480, 48_000, 0.5);
            let written = out.samples.len() as u64;
            timeline.place(&c, written, &mut |s| out.write(s)).unwrap();
        }
        let written = out.samples.len() as u64;
        timeline
            .finish(origin + Duration::from_millis(2010), written, &mut |s| {
                out.write(s)
            })
            .unwrap();
        // ~1 s of silence, then ~1 s of signal, total ~2.01 s.
        assert!(
            (out.samples.len() as i64 - 32_160).abs() <= 400,
            "{}",
            out.samples.len()
        );
        let first_signal = out.samples.iter().position(|&s| s > 0.25).unwrap();
        assert!(
            (first_signal as i64 - 16_000).abs() <= 200,
            "{first_signal}"
        );
    }

    #[test]
    fn jitter_does_not_insert_silence() {
        let origin = Instant::now();
        let mut timeline = Timeline::new(origin);
        let mut out = Collector {
            samples: Vec::new(),
        };
        for i in 0..200u64 {
            // ±5 ms of delivery jitter around a steady 10 ms cadence at 16 kHz.
            let jitter = if i % 2 == 0 { 5 } else { 0 };
            let c = chunk(origin, 10 + i * 10 + jitter, 160, 16_000, 0.5);
            let written = out.samples.len() as u64;
            timeline.place(&c, written, &mut |s| out.write(s)).unwrap();
        }
        assert_eq!(out.samples.len(), 200 * 160);
        assert!(out.samples.iter().all(|&s| s == 0.5));
    }

    #[test]
    fn a_gap_mid_track_keeps_later_audio_in_place() {
        let origin = Instant::now();
        let mut timeline = Timeline::new(origin);
        let mut out = Collector {
            samples: Vec::new(),
        };
        for i in 0..50u64 {
            let c = chunk(origin, 10 + i * 10, 160, 16_000, 0.5);
            let written = out.samples.len() as u64;
            timeline.place(&c, written, &mut |s| out.write(s)).unwrap();
        }
        // Device reconnects: nothing between 0.5 s and 3.0 s.
        for i in 0..50u64 {
            let c = chunk(origin, 3010 + i * 10, 160, 16_000, -0.5);
            let written = out.samples.len() as u64;
            timeline.place(&c, written, &mut |s| out.write(s)).unwrap();
        }
        let resumed = out.samples.iter().position(|&s| s < -0.25).unwrap();
        assert!((resumed as i64 - 48_000).abs() <= 2, "{resumed}");
        assert!(out.samples[8_000..47_990].iter().all(|&s| s == 0.0));
    }

    #[test]
    fn levels_follow_the_meter_scale() {
        assert_eq!(normalized_level(0.0), 0.0);
        assert!((normalized_level(10f32.powf(-55.0 / 20.0))).abs() < 1e-4);
        assert!((normalized_level(10f32.powf(-10.0 / 20.0)) - 1.0).abs() < 1e-4);
        assert!((normalized_level(10f32.powf(-32.5 / 20.0)) - 0.5).abs() < 1e-3);
    }
}
