//! Plays one synthesized clip (Read aloud). Meeting playback is 16 kHz and
//! seekable ([`crate::Player`]); this takes any rate, plays once and stops.

use std::num::NonZero;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};

/// Audio the device has taken but not yet played when the clip's samples end.
const DRAIN: Duration = Duration::from_millis(200);

struct Clip {
    samples: Vec<f32>,
    index: usize,
    sample_rate: NonZero<u32>,
    stop: Arc<AtomicBool>,
    ended: Arc<AtomicBool>,
}

impl Iterator for Clip {
    type Item = rodio::Sample;

    fn next(&mut self) -> Option<Self::Item> {
        if self.stop.load(Ordering::Relaxed) || self.index >= self.samples.len() {
            self.ended.store(true, Ordering::Relaxed);
            return None;
        }
        let sample = self.samples[self.index];
        self.index += 1;
        Some(sample)
    }
}

impl rodio::Source for Clip {
    fn current_span_len(&self) -> Option<usize> {
        None
    }

    fn channels(&self) -> rodio::ChannelCount {
        NonZero::new(1).expect("one channel")
    }

    fn sample_rate(&self) -> rodio::SampleRate {
        self.sample_rate
    }

    fn total_duration(&self) -> Option<Duration> {
        Some(Duration::from_secs_f64(
            self.samples.len() as f64 / self.sample_rate.get() as f64,
        ))
    }
}

/// A clip playing on the default output. Dropping it stops the sound.
pub struct SpeechPlayer {
    stop: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
}

impl SpeechPlayer {
    /// Opens the speakers and starts `samples` (mono).
    pub fn start(samples: Vec<f32>, sample_rate: u32) -> Result<SpeechPlayer> {
        let Some(rate) = NonZero::new(sample_rate) else {
            bail!("Could not start speech playback.");
        };
        let stop = Arc::new(AtomicBool::new(false));
        let ended = Arc::new(AtomicBool::new(false));
        let finished = Arc::new(AtomicBool::new(false));
        let clip = Clip {
            samples,
            index: 0,
            sample_rate: rate,
            stop: Arc::clone(&stop),
            ended: Arc::clone(&ended),
        };
        let (ready_tx, ready_rx) = crossbeam_channel::bounded::<Result<(), String>>(1);
        let done = Arc::clone(&finished);
        let stopped = Arc::clone(&stop);
        std::thread::Builder::new()
            .name("lokalbot-speech-output".into())
            .spawn(
                move || match rodio::DeviceSinkBuilder::open_default_sink() {
                    Ok(mut sink) => {
                        sink.log_on_drop(false);
                        sink.mixer().add(clip);
                        let _ = ready_tx.send(Ok(()));
                        // A stopped clip doesn't wait for a stalled device to
                        // ask for its next sample.
                        while !ended.load(Ordering::Relaxed) && !stopped.load(Ordering::Relaxed) {
                            std::thread::sleep(Duration::from_millis(25));
                        }
                        if !stopped.load(Ordering::Relaxed) {
                            std::thread::sleep(DRAIN);
                        }
                        done.store(true, Ordering::Relaxed);
                    }
                    Err(error) => {
                        done.store(true, Ordering::Relaxed);
                        let _ = ready_tx.send(Err(error.to_string()));
                    }
                },
            )
            .context("could not start speech playback")?;
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => Ok(SpeechPlayer { stop, finished }),
            Ok(Err(error)) => Err(anyhow!("Could not open the speakers: {error}")),
            Err(_) => {
                stop.store(true, Ordering::Relaxed);
                Err(anyhow!(
                    "Could not open the speakers: the audio system did not respond"
                ))
            }
        }
    }

    /// The clip ended or was stopped, and the device is released.
    pub fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Relaxed)
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

impl Drop for SpeechPlayer {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rodio::Source as _;

    fn clip(samples: Vec<f32>, sample_rate: u32) -> (Clip, Arc<AtomicBool>, Arc<AtomicBool>) {
        let stop = Arc::new(AtomicBool::new(false));
        let ended = Arc::new(AtomicBool::new(false));
        (
            Clip {
                samples,
                index: 0,
                sample_rate: NonZero::new(sample_rate).unwrap(),
                stop: Arc::clone(&stop),
                ended: Arc::clone(&ended),
            },
            stop,
            ended,
        )
    }

    #[test]
    fn a_clip_keeps_its_rate_and_ends_once() {
        let (mut clip, _, ended) = clip(vec![0.25; 24_000], 24_000);
        assert_eq!(clip.sample_rate().get(), 24_000);
        assert_eq!(clip.total_duration(), Some(Duration::from_secs(1)));
        assert!(!ended.load(Ordering::Relaxed));
        assert_eq!((&mut clip).count(), 24_000);
        assert!(ended.load(Ordering::Relaxed));
        assert_eq!(clip.next(), None);
    }

    #[test]
    fn stop_ends_a_clip_early() {
        let (mut clip, stop, ended) = clip(vec![0.25; 100], 24_000);
        assert!(clip.next().is_some());
        stop.store(true, Ordering::Relaxed);
        assert_eq!(clip.next(), None);
        assert!(ended.load(Ordering::Relaxed));
    }
}
