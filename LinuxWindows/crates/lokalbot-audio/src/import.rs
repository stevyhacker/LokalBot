//! Audio from a file a person imports (`MeetingImportService.exportAudio`):
//! every audio track of a recording mixed into one 16 kHz track, so a screen
//! recording's microphone and system audio both reach the transcript. A
//! video's picture is dropped and the original file is only read.

use std::io;
use std::path::Path;
use std::time::SystemTime;

use crate::decode::{CompressedReader, audio_track_ids, mp4_creation_time};
use crate::wav::{SAMPLE_RATE, WavWriter};

/// Shorter than this is no audio to transcribe.
pub const MIN_IMPORT_SECONDS: f64 = 0.3;
const CHUNK_FRAMES: usize = SAMPLE_RATE as usize;

#[derive(Debug)]
pub enum ImportError {
    /// Not a format LokalBot can decode.
    Unreadable,
    /// Readable, but with no audio, or under `MIN_IMPORT_SECONDS` of it.
    NoAudio,
    /// Decoding or writing failed part-way.
    Conversion(io::Error),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ImportedAudio {
    pub duration: f64,
    /// The recorder's own creation date, when the container has one.
    pub recorded_at: Option<SystemTime>,
}

/// Decodes `source` into a 16 kHz mono WAV at `dest`. On failure `dest` is removed.
pub fn import_audio(source: &Path, dest: &Path) -> Result<ImportedAudio, ImportError> {
    let ids = audio_track_ids(source).map_err(|_| ImportError::Unreadable)?;
    if ids.is_empty() {
        return Err(ImportError::NoAudio);
    }
    let mut readers: Vec<CompressedReader> = ids
        .iter()
        .filter_map(|id| CompressedReader::open_track(source, Some(*id)).ok())
        .collect();
    if readers.is_empty() {
        return Err(ImportError::Unreadable);
    }
    let frames = match mix(&mut readers, dest) {
        Ok(frames) => frames,
        Err(err) => {
            let _ = std::fs::remove_file(dest);
            return Err(ImportError::Conversion(err));
        }
    };
    let duration = frames as f64 / SAMPLE_RATE as f64;
    if duration < MIN_IMPORT_SECONDS {
        let _ = std::fs::remove_file(dest);
        return Err(ImportError::NoAudio);
    }
    Ok(ImportedAudio {
        duration,
        recorded_at: mp4_creation_time(source),
    })
}

/// Sums the tracks chunk by chunk; each read is full-length until its track
/// ends, so the tracks stay aligned.
fn mix(readers: &mut [CompressedReader], dest: &Path) -> io::Result<u64> {
    let mut writer = WavWriter::create(dest)?;
    let mut mixed = Vec::with_capacity(CHUNK_FRAMES);
    let mut chunk = Vec::with_capacity(CHUNK_FRAMES);
    loop {
        mixed.clear();
        for reader in readers.iter_mut() {
            chunk.clear();
            let read = reader.read_mono(CHUNK_FRAMES, &mut chunk)?;
            if mixed.len() < read {
                mixed.resize(read, 0.0);
            }
            for (sum, sample) in mixed.iter_mut().zip(&chunk) {
                *sum += sample;
            }
        }
        if mixed.is_empty() {
            break;
        }
        for sample in &mut mixed {
            *sample = sample.clamp(-1.0, 1.0);
        }
        writer.write_samples(&mixed)?;
    }
    writer.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TrackReader;

    /// One second of a 440 Hz tone as an ADTS AAC stream, the one format the
    /// phone and tablet apps send: `ffmpeg -f lavfi -i
    /// "sine=frequency=440:duration=1" -c:a aac -b:a 32k -f adts`.
    fn adts_tone() -> Vec<u8> {
        std::fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/tone-440-adts.aac"))
            .unwrap()
    }

    fn read_all(path: &Path) -> Vec<f32> {
        let mut reader = TrackReader::open(path).unwrap();
        assert_eq!(reader.sample_rate(), SAMPLE_RATE);
        let mut samples = Vec::new();
        while reader.read_mono(4_096, &mut samples).unwrap() > 0 {}
        samples
    }

    #[test]
    fn imports_an_adts_aac_stream() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("recording.aac");
        std::fs::write(&source, adts_tone()).unwrap();
        let dest = dir.path().join("mic.wav");

        let audio = import_audio(&source, &dest).unwrap();
        assert!((audio.duration - 1.0).abs() < 0.1, "{} s", audio.duration);
        assert_eq!(audio.recorded_at, None, "ADTS has no dates");

        // A 440 Hz tone crosses zero about 880 times a second.
        let samples = read_all(&dest);
        let crossings = samples
            .windows(2)
            .filter(|pair| (pair[0] < 0.0) != (pair[1] < 0.0))
            .count() as f64;
        let per_second = crossings / audio.duration;
        assert!(
            (820.0..=940.0).contains(&per_second),
            "{per_second} a second"
        );
    }

    /// A recorder that dies stops in the middle of a frame, and the earlier
    /// frames are still the recording.
    #[test]
    fn imports_what_a_dead_recorder_left() {
        let dir = tempfile::tempdir().unwrap();
        let whole = adts_tone();
        let source = dir.path().join("recording.aac");
        std::fs::write(&source, &whole[..whole.len() - whole.len() / 4 + 3]).unwrap();
        let dest = dir.path().join("mic.wav");

        let audio = import_audio(&source, &dest).unwrap();
        assert!(
            (0.6..=0.9).contains(&audio.duration),
            "{} s of what was written",
            audio.duration
        );
        assert!(read_all(&dest).iter().any(|sample| sample.abs() > 0.01));
    }

    /// `frame` with padding the decoder never reads, which an ADTS header counts.
    fn padded(frame: &[u8], extra: usize) -> Vec<u8> {
        let mut padded = frame.to_vec();
        padded.resize(frame.len() + extra, 0);
        let length = padded.len();
        padded[3] = padded[3] & !0b11 | (length >> 11) as u8;
        padded[4] = (length >> 3) as u8;
        padded[5] = padded[5] & 0b1_1111 | (length << 5) as u8;
        padded
    }

    /// ADTS doesn't say how long it is, and Symphonia's figure comes from the
    /// frames at four points in the file. A device deletes its copy once the
    /// meeting is stored, so one that's bigger there than elsewhere must still
    /// arrive whole.
    #[test]
    fn imports_all_of_a_stream_whose_frames_vary_in_size() {
        let tone = adts_tone();
        let mut frames = Vec::new();
        let mut rest = tone.as_slice();
        while rest.len() >= 7 {
            let length = usize::from(rest[3] & 0b11) << 11
                | usize::from(rest[4]) << 3
                | usize::from(rest[5]) >> 5;
            frames.push(&rest[..length]);
            rest = &rest[length..];
        }
        const FRAMES: usize = 1_000;
        let mut stream = Vec::new();
        for (index, frame) in frames.iter().cycle().take(FRAMES).enumerate() {
            let extra = if index < 100 { 1_000 } else { 0 };
            stream.extend_from_slice(&padded(frame, extra));
        }
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("recording.aac");
        std::fs::write(&source, stream).unwrap();
        let dest = dir.path().join("mic.wav");

        let audio = import_audio(&source, &dest).unwrap();
        let written = FRAMES as f64 * 1_024.0 / 44_100.0;
        assert!(
            (audio.duration - written).abs() < 0.1,
            "{} s of {written} s",
            audio.duration
        );
    }

    #[test]
    fn a_stream_shorter_than_the_minimum_is_no_audio() {
        let dir = tempfile::tempdir().unwrap();
        let whole = adts_tone();
        let source = dir.path().join("recording.aac");
        std::fs::write(&source, &whole[..whole.len() / 10]).unwrap();
        let dest = dir.path().join("mic.wav");
        assert!(matches!(
            import_audio(&source, &dest),
            Err(ImportError::NoAudio)
        ));
        assert!(!dest.exists());
    }
}
