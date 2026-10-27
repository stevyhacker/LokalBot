//! A merged meeting's tracks (`MeetingMergeService.export`): a part of each
//! source track laid end to end. A source without that track, or a track
//! that ends early, leaves silence, so both tracks and the transcript keep
//! the same timeline.

use std::io;
use std::path::Path;

use crate::decode::TrackReader;
use crate::resample::Resampler;
use crate::wav::{SAMPLE_RATE, WavWriter};

/// One source's part: `(track, start, end)` in seconds on that source's
/// timeline. A missing track still takes up `end - start`.
pub type SplicePart<'a> = (Option<&'a Path>, f64, f64);

/// Writes the parts in order into a 16 kHz WAV at `dest` and returns which
/// parts contributed audio. When none did, nothing is written.
pub fn splice_tracks(parts: &[SplicePart<'_>], dest: &Path) -> io::Result<Vec<bool>> {
    if dest.exists() {
        std::fs::remove_file(dest)?;
    }
    let mut used = vec![false; parts.len()];
    let mut writer: Option<WavWriter> = None;
    let mut cursor: u64 = 0;
    let result = (|| -> io::Result<()> {
        for (index, (track, start, end)) in parts.iter().enumerate() {
            let slot = frames(end - start);
            if let Some(mut reader) = track.and_then(|path| TrackReader::open(path).ok()) {
                let stop = end.min(reader.duration_seconds());
                if stop > *start {
                    let writer = match writer.as_mut() {
                        Some(writer) => writer,
                        None => writer.insert(WavWriter::create(dest)?),
                    };
                    writer.write_silence(cursor.saturating_sub(writer.frames()))?;
                    copy(&mut reader, *start, stop, slot, writer)?;
                    used[index] = true;
                }
            }
            cursor += slot;
        }
        Ok(())
    })();
    match (result, writer) {
        (Ok(()), Some(mut writer)) => {
            writer.write_silence(cursor.saturating_sub(writer.frames()))?;
            writer.finish()?;
            Ok(used)
        }
        (Ok(()), None) => Ok(used),
        (Err(err), _) => {
            let _ = std::fs::remove_file(dest);
            Err(err)
        }
    }
}

fn frames(seconds: f64) -> u64 {
    (seconds.max(0.0) * SAMPLE_RATE as f64).round() as u64
}

/// `start..stop` of `reader` at 16 kHz, at most `limit` frames.
fn copy(
    reader: &mut TrackReader,
    start: f64,
    stop: f64,
    limit: u64,
    writer: &mut WavWriter,
) -> io::Result<()> {
    let rate = reader.sample_rate();
    reader.seek_frame((start * rate as f64).round() as u64)?;
    let mut remaining = ((stop - start) * rate as f64).round() as u64;
    let mut resampler = (rate != SAMPLE_RATE).then(|| Resampler::new(rate, SAMPLE_RATE));
    let first = writer.frames();
    let mut input = Vec::new();
    let mut output = Vec::new();
    while remaining > 0 {
        input.clear();
        let read = reader.read_mono(remaining.min(SAMPLE_RATE as u64) as usize, &mut input)?;
        if read == 0 {
            break;
        }
        remaining -= read as u64;
        let samples = match resampler.as_mut() {
            Some(resampler) => {
                output.clear();
                resampler.process(&input, &mut output);
                &output
            }
            None => &input,
        };
        let room = limit.saturating_sub(writer.frames() - first) as usize;
        writer.write_samples(&samples[..samples.len().min(room)])?;
    }
    if let Some(mut resampler) = resampler {
        output.clear();
        resampler.flush(&mut output);
        let room = limit.saturating_sub(writer.frames() - first) as usize;
        writer.write_samples(&output[..output.len().min(room)])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wav::{read_mono_16k, write_wav_16k};

    fn tone(seconds: f64, level: f32) -> Vec<f32> {
        vec![level; frames(seconds) as usize]
    }

    #[test]
    fn parts_follow_each_other_with_silence_for_missing_tracks() {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first.wav");
        let third = dir.path().join("third.wav");
        write_wav_16k(&first, &tone(4.0, 0.5)).unwrap();
        // Shorter than its part: the rest of the part is silence.
        write_wav_16k(&third, &tone(1.0, -0.25)).unwrap();
        let dest = dir.path().join("merged.wav");
        let used = splice_tracks(
            &[
                (Some(first.as_path()), 1.0, 3.0),
                (None, 0.0, 2.0),
                (Some(third.as_path()), 0.0, 1.5),
            ],
            &dest,
        )
        .unwrap();
        assert_eq!(used, [true, false, true]);
        let samples = read_mono_16k(&dest).unwrap();
        assert_eq!(samples.len(), frames(5.5) as usize);
        let at = |seconds: f64| samples[frames(seconds) as usize];
        assert!((at(0.5) - 0.5).abs() < 0.01);
        assert_eq!(at(2.5), 0.0);
        assert!((at(4.5) + 0.25).abs() < 0.01);
        assert_eq!(at(5.25), 0.0);
    }

    #[test]
    fn no_track_writes_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("merged.wav");
        let used = splice_tracks(&[(None, 0.0, 2.0), (None, 0.0, 1.0)], &dest).unwrap();
        assert_eq!(used, [false, false]);
        assert!(!dest.exists());
    }
}
