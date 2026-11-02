//! "Export audio": a meeting's tracks mixed into one file to keep or share
//! (`MeetingAudioAsset.exportMixedRecording`). The Mac writes AAC with its
//! system exporter; there is no AAC encoder here, so this writes a 16 kHz WAV.

use std::io;
use std::path::Path;

use crate::wav::WavWriter;
use crate::{Resampler, TrackReader};

const BLOCK_FRAMES: usize = 16_000 * 10;

struct Track {
    reader: TrackReader,
    resampler: Option<Resampler>,
    pending: Vec<f32>,
    finished: bool,
}

impl Track {
    fn open(path: &Path) -> io::Result<Self> {
        let reader = TrackReader::open(path)?;
        let rate = reader.sample_rate();
        Ok(Self {
            reader,
            resampler: (rate != crate::wav::SAMPLE_RATE)
                .then(|| Resampler::new(rate, crate::wav::SAMPLE_RATE)),
            pending: Vec::new(),
            finished: false,
        })
    }

    /// Reads until at least `frames` samples wait, or the track ends.
    fn fill(&mut self, frames: usize) -> io::Result<()> {
        let mut block = Vec::new();
        while self.pending.len() < frames && !self.finished {
            block.clear();
            if self.reader.read_mono(BLOCK_FRAMES, &mut block)? == 0 {
                self.finished = true;
                if let Some(resampler) = &mut self.resampler {
                    resampler.flush(&mut self.pending);
                }
                break;
            }
            match &mut self.resampler {
                Some(resampler) => resampler.process(&block, &mut self.pending),
                None => self.pending.extend_from_slice(&block),
            }
        }
        Ok(())
    }
}

/// Writes `mic` and `system` summed onto one timeline, reading in blocks so a
/// long meeting never sits in memory. Returns the length in seconds.
pub fn export_mixed(
    mic: Option<&Path>,
    system: Option<&Path>,
    destination: &Path,
) -> io::Result<f64> {
    let mut tracks = Vec::new();
    for path in [mic, system].into_iter().flatten() {
        tracks.push(Track::open(path)?);
    }
    if tracks.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "this meeting has no recording",
        ));
    }
    let result = write_mix(&mut tracks, destination);
    if result.is_err() {
        let _ = std::fs::remove_file(destination);
    }
    result
}

fn write_mix(tracks: &mut [Track], destination: &Path) -> io::Result<f64> {
    let mut writer = WavWriter::create(destination)?;
    let mut mixed = Vec::with_capacity(BLOCK_FRAMES);
    loop {
        for track in tracks.iter_mut() {
            track.fill(BLOCK_FRAMES)?;
        }
        let frames = tracks
            .iter()
            .map(|t| t.pending.len().min(BLOCK_FRAMES))
            .max()
            .unwrap_or(0);
        if frames == 0 {
            break;
        }
        mixed.clear();
        mixed.resize(frames, 0f32);
        for track in tracks.iter_mut() {
            let take = track.pending.len().min(frames);
            for (out, sample) in mixed.iter_mut().zip(track.pending.drain(..take)) {
                *out += sample;
            }
        }
        for sample in &mut mixed {
            *sample = sample.clamp(-1.0, 1.0);
        }
        writer.write_samples(&mixed)?;
    }
    let seconds = writer.seconds();
    writer.finish()?;
    Ok(seconds)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wav::{read_mono_16k, write_wav_16k};

    #[test]
    fn tracks_are_summed_and_the_longer_one_decides_the_length() {
        let dir = tempfile::tempdir().unwrap();
        let (mic, system, out) = (
            dir.path().join("mic.wav"),
            dir.path().join("system.wav"),
            dir.path().join("out.wav"),
        );
        write_wav_16k(&mic, &vec![0.25f32; 48_000]).unwrap();
        write_wav_16k(&system, &vec![0.5f32; 16_000]).unwrap();
        let seconds = export_mixed(Some(&mic), Some(&system), &out).unwrap();
        assert!((seconds - 3.0).abs() < 0.01);
        let mixed = read_mono_16k(&out).unwrap();
        assert_eq!(mixed.len(), 48_000);
        assert!((mixed[100] - 0.75).abs() < 0.01);
        assert!((mixed[40_000] - 0.25).abs() < 0.01);
    }

    #[test]
    fn one_track_is_enough_and_none_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let (mic, out) = (dir.path().join("mic.wav"), dir.path().join("out.wav"));
        write_wav_16k(&mic, &vec![0.25f32; 16_000]).unwrap();
        assert!(export_mixed(Some(&mic), None, &out).is_ok());
        assert!(export_mixed(None, None, &dir.path().join("none.wav")).is_err());
    }

    #[test]
    fn loud_passages_are_kept_within_range() {
        let dir = tempfile::tempdir().unwrap();
        let (mic, system, out) = (
            dir.path().join("mic.wav"),
            dir.path().join("system.wav"),
            dir.path().join("out.wav"),
        );
        write_wav_16k(&mic, &vec![0.9f32; 16_000]).unwrap();
        write_wav_16k(&system, &vec![0.9f32; 16_000]).unwrap();
        export_mixed(Some(&mic), Some(&system), &out).unwrap();
        assert!(read_mono_16k(&out).unwrap().iter().all(|s| s.abs() <= 1.0));
    }
}
