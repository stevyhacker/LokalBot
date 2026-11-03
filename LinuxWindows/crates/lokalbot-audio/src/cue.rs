//! The short cue played when the dictation microphone starts delivering audio
//! (`DictationCoordinator.startSound`, "Tink" at 0.35 on macOS). It is
//! synthesized, so no sound file ships with the app.

use std::time::Duration;

use rodio::buffer::SamplesBuffer;

const RATE: u32 = 44_100;
const SECONDS: f32 = 0.07;
const FREQUENCY: f32 = 1_760.0;
/// As quiet as the Mac's.
const VOLUME: f32 = 0.35;

fn samples() -> Vec<f32> {
    let count = (RATE as f32 * SECONDS) as usize;
    (0..count)
        .map(|index| {
            let t = index as f32 / RATE as f32;
            let attack = (t / 0.003).min(1.0);
            let decay = (-t * 55.0).exp();
            (t * FREQUENCY * std::f32::consts::TAU).sin() * attack * decay * VOLUME
        })
        .collect()
}

/// Plays the cue on its own thread. A machine with no output just stays quiet.
pub fn play_start() {
    let spawned = std::thread::Builder::new()
        .name("lokalbot-dictation-cue".into())
        .spawn(|| {
            let Ok(mut sink) = rodio::DeviceSinkBuilder::open_default_sink() else {
                log::debug!("no audio output for the dictation cue");
                return;
            };
            sink.log_on_drop(false);
            let (Some(channels), Some(rate)) =
                (std::num::NonZero::new(1u16), std::num::NonZero::new(RATE))
            else {
                return;
            };
            sink.mixer()
                .add(SamplesBuffer::new(channels, rate, samples()));
            // Hold the device until the sound has played.
            std::thread::sleep(Duration::from_secs_f32(SECONDS) + Duration::from_millis(60));
        });
    if let Err(err) = spawned {
        log::debug!("could not play the dictation cue: {err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cue_is_short_and_quiet() {
        let samples = samples();
        assert_eq!(samples.len(), 3_087);
        let peak = samples.iter().fold(0.0_f32, |peak, s| peak.max(s.abs()));
        assert!(peak > 0.1 && peak <= VOLUME, "{peak}");
        assert!(samples.last().unwrap().abs() < 0.05, "it fades out");
    }
}
