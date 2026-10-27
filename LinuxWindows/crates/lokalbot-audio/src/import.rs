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
