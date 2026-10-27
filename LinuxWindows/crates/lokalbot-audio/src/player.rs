//! Plays a meeting's two tracks together (`MeetingPlayer.swift`). Both files
//! share one timeline, so one mixed source reproduces the meeting; the longest
//! track decides the duration. Gains follow `MeetingAudioAsset`: system 0.85
//! and mic 0.55 together, 1.0 for a single track.

use std::num::NonZero;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use parking_lot::Mutex;

use crate::decode::TrackReader;
use crate::stretch::{SampleSource, Wsola};
use crate::wav::SAMPLE_RATE;

pub const MIN_SPEED: f32 = 0.75;
pub const MAX_SPEED: f32 = 2.0;
/// Output block rendered under the lock: 20 ms.
const BLOCK: usize = SAMPLE_RATE as usize / 50;

struct Track {
    reader: TrackReader,
    gain: f32,
    frames: u64,
    /// Frame the reader will return next.
    cursor: u64,
}

/// Mixed tracks with a sliding read cache; positions outside every track read as silence.
struct Mix {
    tracks: Vec<Track>,
    cache: Vec<f32>,
    cache_start: i64,
    block: Vec<f32>,
}

impl Mix {
    fn frames(&self) -> u64 {
        self.tracks.iter().map(|t| t.frames).max().unwrap_or(0)
    }

    fn fill_cache(&mut self, start: i64, len: usize) {
        let end = start + len as i64;
        let cache_end = self.cache_start + self.cache.len() as i64;
        if start < self.cache_start || start > cache_end {
            self.cache.clear();
            self.cache_start = start;
        } else if start > self.cache_start + 4 * SAMPLE_RATE as i64 {
            // Keep a little history for WSOLA's look-back, drop the rest.
            let drop = (start - self.cache_start - SAMPLE_RATE as i64) as usize;
            self.cache.drain(..drop.min(self.cache.len()));
            self.cache_start += drop as i64;
        }
        let have_until = self.cache_start + self.cache.len() as i64;
        if end <= have_until {
            return;
        }
        let from = have_until;
        let need = (end - from) as usize;
        let read_len = need.max(BLOCK * 8);
        let mut mixed = vec![0.0f32; read_len];
        // Positions before the start of the file are silence.
        let lead = if from < 0 {
            ((-from) as usize).min(read_len)
        } else {
            0
        };
        let track_from = (from + lead as i64) as u64;
        for track in &mut self.tracks {
            if lead == read_len || track_from >= track.frames {
                continue;
            }
            if track.cursor != track_from {
                if track.reader.seek_frame(track_from).is_err() {
                    continue;
                }
                track.cursor = track_from;
            }
            self.block.clear();
            let available = (track.frames - track_from).min((read_len - lead) as u64) as usize;
            if let Ok(read) = track.reader.read_mono(available, &mut self.block) {
                track.cursor += read as u64;
                for (out, sample) in mixed[lead..].iter_mut().zip(&self.block) {
                    *out += sample * track.gain;
                }
            }
        }
        self.cache
            .extend(mixed.into_iter().map(|s| s.clamp(-1.0, 1.0)));
    }
}

impl SampleSource for Mix {
    fn read(&mut self, start: i64, out: &mut [f32]) {
        self.fill_cache(start, out.len());
        let offset = (start - self.cache_start) as usize;
        out.copy_from_slice(&self.cache[offset..offset + out.len()]);
    }
}

struct State {
    mix: Mix,
    playing: bool,
    speed: f32,
    /// Next timeline frame at 1× (unused while stretching).
    position: u64,
    stretch: Option<Wsola>,
    end_at: Option<u64>,
}

impl State {
    fn current_frame(&self) -> u64 {
        match &self.stretch {
            Some(wsola) => wsola.position().max(0.0) as u64,
            None => self.position,
        }
    }

    fn set_frame(&mut self, frame: u64) {
        self.position = frame;
        self.stretch = (self.speed != 1.0).then(|| Wsola::new(frame as i64));
    }

    fn render(&mut self, out: &mut Vec<f32>) {
        out.clear();
        if !self.playing {
            return;
        }
        let end = self.end_at.unwrap_or(u64::MAX).min(self.mix.frames());
        if self.current_frame() >= end {
            self.playing = false;
            self.end_at = None;
            let frame = end.min(self.mix.frames());
            self.set_frame(frame);
            return;
        }
        match self.stretch.as_mut() {
            Some(wsola) => {
                while out.len() < BLOCK {
                    wsola.render(&mut self.mix, self.speed as f64, out);
                }
            }
            None => {
                let len = BLOCK.min((end - self.position) as usize);
                out.resize(len, 0.0);
                self.mix.read(self.position as i64, out);
                self.position += len as u64;
            }
        }
    }
}

struct Output {
    _stop: crossbeam_channel::Sender<()>,
}

/// rodio source that pulls 20 ms blocks from the shared state; silent while paused.
struct PlayerSource {
    state: Arc<Mutex<State>>,
    block: Vec<f32>,
    index: usize,
}

impl Iterator for PlayerSource {
    type Item = rodio::Sample;

    fn next(&mut self) -> Option<Self::Item> {
        if self.index >= self.block.len() {
            let mut state = self.state.lock();
            state.render(&mut self.block);
            self.index = 0;
            if self.block.is_empty() {
                // Paused or finished: keep the stream alive with silence.
                return Some(0.0);
            }
        }
        let sample = self.block[self.index];
        self.index += 1;
        Some(sample)
    }
}

impl rodio::Source for PlayerSource {
    fn current_span_len(&self) -> Option<usize> {
        None
    }

    fn channels(&self) -> rodio::ChannelCount {
        NonZero::new(1).expect("one channel")
    }

    fn sample_rate(&self) -> rodio::SampleRate {
        NonZero::new(SAMPLE_RATE).expect("non-zero rate")
    }

    fn total_duration(&self) -> Option<Duration> {
        None
    }
}

pub struct Player {
    state: Arc<Mutex<State>>,
    output: Mutex<Option<Output>>,
    duration: f64,
}

impl Player {
    /// Opens the tracks (either may be missing). The output device opens on
    /// the first [`Player::play`].
    pub fn open(mic: Option<&Path>, system: Option<&Path>) -> Result<Player> {
        let both = mic.is_some() && system.is_some();
        let mut tracks = Vec::new();
        for (path, gain) in [
            (system, if both { 0.85 } else { 1.0 }),
            (mic, if both { 0.55 } else { 1.0 }),
        ] {
            let Some(path) = path else { continue };
            let reader = TrackReader::open(path)
                .with_context(|| format!("could not open {}", path.display()))?;
            if reader.sample_rate() != SAMPLE_RATE {
                bail!("{} is not a 16 kHz track", path.display());
            }
            let frames = reader.frames();
            tracks.push(Track {
                reader,
                gain,
                frames,
                cursor: 0,
            });
        }
        if tracks.is_empty() {
            bail!("This meeting has no audio.");
        }
        let mix = Mix {
            tracks,
            cache: Vec::new(),
            cache_start: 0,
            block: Vec::new(),
        };
        let duration = mix.frames() as f64 / SAMPLE_RATE as f64;
        let state = State {
            mix,
            playing: false,
            speed: 1.0,
            position: 0,
            stretch: None,
            end_at: None,
        };
        Ok(Player {
            state: Arc::new(Mutex::new(state)),
            output: Mutex::new(None),
            duration,
        })
    }

    fn ensure_output(&self) -> Result<()> {
        let mut output = self.output.lock();
        if output.is_some() {
            return Ok(());
        }
        let (stop_tx, stop_rx) = crossbeam_channel::bounded::<()>(0);
        let (ready_tx, ready_rx) = crossbeam_channel::bounded::<Result<(), String>>(1);
        let source = PlayerSource {
            state: Arc::clone(&self.state),
            block: Vec::new(),
            index: 0,
        };
        std::thread::Builder::new()
            .name("lokalbot-playback".into())
            .spawn(
                move || match rodio::DeviceSinkBuilder::open_default_sink() {
                    Ok(mut sink) => {
                        sink.log_on_drop(false);
                        sink.mixer().add(source);
                        let _ = ready_tx.send(Ok(()));
                        // Hold the device until the player goes away.
                        let _ = stop_rx.recv();
                    }
                    Err(error) => {
                        let _ = ready_tx.send(Err(error.to_string()));
                    }
                },
            )
            .context("could not start playback")?;
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => {
                *output = Some(Output { _stop: stop_tx });
                Ok(())
            }
            Ok(Err(error)) => Err(anyhow!("Could not open the speakers: {error}")),
            Err(_) => Err(anyhow!(
                "Could not open the speakers: the audio system did not respond"
            )),
        }
    }

    /// Starts or resumes playback; at the end it starts over.
    pub fn play(&self) -> Result<()> {
        self.ensure_output()?;
        let mut state = self.state.lock();
        state.end_at = None;
        if state.current_frame() >= state.mix.frames() {
            state.set_frame(0);
        }
        state.playing = true;
        Ok(())
    }

    /// Plays `start..end` seconds and stops (evidence passages).
    pub fn play_range(&self, start: f64, end: f64) -> Result<()> {
        if !(start.is_finite() && end.is_finite() && end > start) {
            bail!("invalid passage");
        }
        self.ensure_output()?;
        let mut state = self.state.lock();
        let frames = state.mix.frames();
        let start = ((start.max(0.0) * SAMPLE_RATE as f64) as u64).min(frames);
        state.set_frame(start);
        state.end_at = Some(((end * SAMPLE_RATE as f64) as u64).min(frames));
        state.playing = true;
        Ok(())
    }

    pub fn pause(&self) {
        let mut state = self.state.lock();
        state.playing = false;
        state.end_at = None;
    }

    pub fn toggle(&self) -> Result<()> {
        if self.is_playing() {
            self.pause();
            Ok(())
        } else {
            self.play()
        }
    }

    /// Moves the playhead; playback continues if it was playing.
    pub fn seek(&self, seconds: f64) {
        let mut state = self.state.lock();
        let frames = state.mix.frames();
        let frame = if seconds.is_finite() {
            ((seconds.max(0.0) * SAMPLE_RATE as f64) as u64).min(frames)
        } else {
            0
        };
        state.set_frame(frame);
    }

    /// Playback rate, clamped to 0.75–2.0; pitch is preserved.
    pub fn set_speed(&self, speed: f32) {
        let speed = if speed.is_finite() {
            speed.clamp(MIN_SPEED, MAX_SPEED)
        } else {
            1.0
        };
        let mut state = self.state.lock();
        if (state.speed - speed).abs() < f32::EPSILON {
            return;
        }
        let frame = state.current_frame();
        state.speed = speed;
        state.set_frame(frame);
    }

    pub fn speed(&self) -> f32 {
        self.state.lock().speed
    }

    /// Seconds into the meeting.
    pub fn position(&self) -> f64 {
        self.state.lock().current_frame() as f64 / SAMPLE_RATE as f64
    }

    pub fn duration(&self) -> f64 {
        self.duration
    }

    pub fn is_playing(&self) -> bool {
        self.state.lock().playing
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wav::write_wav_16k;

    fn player_with(mic: &[f32], system: &[f32]) -> (tempfile::TempDir, Player) {
        let dir = tempfile::tempdir().unwrap();
        let mic_path = dir.path().join("mic.wav");
        let system_path = dir.path().join("system.wav");
        write_wav_16k(&mic_path, mic).unwrap();
        write_wav_16k(&system_path, system).unwrap();
        let player = Player::open(Some(&mic_path), Some(&system_path)).unwrap();
        (dir, player)
    }

    fn drain(player: &Player, max_blocks: usize) -> Vec<f32> {
        let mut out = Vec::new();
        let mut block = Vec::new();
        for _ in 0..max_blocks {
            player.state.lock().render(&mut block);
            if block.is_empty() {
                break;
            }
            out.extend_from_slice(&block);
        }
        out
    }

    #[test]
    fn mixes_both_tracks_with_meeting_gains() {
        let (_dir, player) = player_with(&vec![0.5; 16_000], &vec![0.5; 32_000]);
        assert!((player.duration() - 2.0).abs() < 1e-9);
        player.state.lock().playing = true;
        let out = drain(&player, 1_000);
        assert_eq!(out.len(), 32_000);
        assert!(
            (out[100] - 0.5 * (0.55 + 0.85)).abs() < 1e-3,
            "{}",
            out[100]
        );
        assert!((out[20_000] - 0.5 * 0.85).abs() < 1e-3);
        assert!(!player.is_playing());
        assert!((player.position() - 2.0).abs() < 1e-9);
    }

    #[test]
    fn seek_range_and_speed() {
        let (_dir, player) = player_with(&vec![0.25; 16_000 * 4], &vec![0.0; 16_000 * 4]);
        player.seek(1.0);
        assert!((player.position() - 1.0).abs() < 1e-9);
        {
            let mut state = player.state.lock();
            state.end_at = Some(16_000 * 2);
            state.playing = true;
        }
        assert_eq!(drain(&player, 1_000).len(), 16_000);
        player.seek(0.0);
        player.set_speed(2.0);
        player.state.lock().playing = true;
        let fast = drain(&player, 1_000);
        assert!((fast.len() as i64 - 32_000).abs() < 1_000, "{}", fast.len());
        player.set_speed(5.0);
        assert_eq!(player.speed(), MAX_SPEED);
    }
}
