//! Peak envelope of a meeting's tracks for the player's waveform
//! (`WaveformAnalysis.swift`): per bucket the loudest sample of any track,
//! normalised so the loudest bucket is 1. Bins follow time on the longest
//! track, so a shorter track never stretches to fill the bar.

use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::decode::TrackReader;

const CACHE_FILE: &str = ".waveform-peaks.json";
const CACHE_LIMIT_BYTES: u64 = 1 << 20;

#[derive(Serialize, Deserialize)]
struct CacheEntry {
    key: String,
    peaks: Vec<f32>,
}

/// Peaks in 0…1, one per bucket. Cached next to the audio, keyed by each
/// file's size and modification time.
pub fn waveform_peaks(paths: &[&Path], buckets: usize) -> Result<Vec<f32>> {
    if buckets == 0 {
        return Ok(Vec::new());
    }
    let paths: Vec<&Path> = paths.iter().copied().filter(|p| p.is_file()).collect();
    if paths.is_empty() {
        bail!("no audio to draw");
    }
    let key = cache_key(&paths, buckets);
    let cache = cache_path(&paths);
    if let (Some(cache), Some(key)) = (&cache, &key)
        && let Some(peaks) = read_cache(cache, key, buckets)
    {
        return Ok(peaks);
    }
    let peaks = compute_peaks(&paths, buckets)?;
    if let (Some(cache), Some(key)) = (cache, key) {
        // A read-only folder must never prevent drawing the waveform.
        let entry = CacheEntry {
            key,
            peaks: peaks.clone(),
        };
        if let Ok(json) = serde_json::to_vec(&entry) {
            let tmp = cache.with_extension("json.tmp");
            if std::fs::write(&tmp, json).is_ok() && std::fs::rename(&tmp, &cache).is_err() {
                let _ = std::fs::remove_file(&tmp);
            }
        }
    }
    Ok(peaks)
}

fn cache_path(paths: &[&Path]) -> Option<PathBuf> {
    let folder = paths.first()?.parent()?;
    paths
        .iter()
        .all(|p| p.parent() == Some(folder))
        .then(|| folder.join(CACHE_FILE))
}

fn cache_key(paths: &[&Path], buckets: usize) -> Option<String> {
    let mut key = format!("v1|{buckets}");
    for path in paths {
        let meta = std::fs::metadata(path).ok()?;
        let modified = meta
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_nanos();
        let name = path.file_name()?.to_string_lossy();
        key.push_str(&format!("|{name}:{}:{modified}", meta.len()));
    }
    Some(key)
}

fn read_cache(path: &Path, key: &str, buckets: usize) -> Option<Vec<f32>> {
    if std::fs::metadata(path).ok()?.len() > CACHE_LIMIT_BYTES {
        return None;
    }
    let entry: CacheEntry = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    (entry.key == key
        && entry.peaks.len() == buckets
        && entry
            .peaks
            .iter()
            .all(|p| p.is_finite() && (0.0..=1.0).contains(p)))
    .then_some(entry.peaks)
}

fn compute_peaks(paths: &[&Path], buckets: usize) -> Result<Vec<f32>> {
    let mut readers = Vec::new();
    for path in paths {
        match TrackReader::open(path) {
            Ok(reader) => readers.push(reader),
            Err(error) => log::warn!("waveform: skipping {}: {error}", path.display()),
        }
    }
    let duration = readers
        .iter()
        .map(|r| r.duration_seconds())
        .fold(0.0, f64::max);
    if readers.is_empty() || duration <= 0.0 {
        bail!("no audio to draw");
    }
    let mut peaks = vec![0.0f32; buckets];
    let mut block = Vec::new();
    for reader in &mut readers {
        let rate = reader.sample_rate() as f64;
        let mut frame = 0u64;
        loop {
            block.clear();
            let read = reader
                .read_mono(1 << 15, &mut block)
                .context("could not read audio")?;
            if read == 0 {
                break;
            }
            for &sample in &block {
                let time = frame as f64 / rate;
                let bin = ((time / duration) * buckets as f64) as usize;
                let bin = bin.min(buckets - 1);
                let magnitude = if sample.is_finite() {
                    sample.abs()
                } else {
                    0.0
                };
                if magnitude > peaks[bin] {
                    peaks[bin] = magnitude;
                }
                frame += 1;
            }
        }
    }
    let maximum = peaks.iter().copied().fold(0.0f32, f32::max);
    if maximum > 0.0 {
        for peak in &mut peaks {
            *peak = (*peak / maximum).min(1.0);
        }
    }
    Ok(peaks)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wav::write_wav_16k;

    #[test]
    fn peaks_follow_time_and_cache() {
        let dir = tempfile::tempdir().unwrap();
        let mic = dir.path().join("mic.wav");
        let system = dir.path().join("system.wav");
        // Mic: loud in its first half second only; system: quieter for 2 s.
        let mut mic_samples = vec![0.8f32; 8_000];
        mic_samples.extend(vec![0.0f32; 24_000]);
        write_wav_16k(&mic, &mic_samples).unwrap();
        write_wav_16k(&system, &vec![0.2f32; 32_000]).unwrap();
        let peaks = waveform_peaks(&[&mic, &system], 8).unwrap();
        assert_eq!(peaks.len(), 8);
        assert!((peaks[0] - 1.0).abs() < 1e-3);
        assert!((peaks[3] - 0.25).abs() < 0.01, "{peaks:?}");
        assert!(dir.path().join(CACHE_FILE).is_file());
        assert_eq!(waveform_peaks(&[&mic, &system], 8).unwrap(), peaks);
        // A different bucket count is recomputed, not misread.
        assert_eq!(waveform_peaks(&[&mic, &system], 4).unwrap().len(), 4);
    }
}
