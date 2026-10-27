//! Turning an audio or video file into a meeting (`MeetingImportService.swift`).
//!
//! The file's audio becomes the meeting's system track, so it is separated
//! into speakers like call audio. The original file is only read. Decoding
//! happens in `lokalbot-audio`; these are the rules around it.

use std::path::Path;

use chrono::{DateTime, Duration, TimeZone as _, Utc};

/// Shown where a recorded meeting shows its meeting app.
pub const IMPORTED_APP_NAME: &str = "Imported file";

/// File types the import dialog offers and a drop accepts. Whether the audio
/// in one can actually be read is only known once it is decoded.
pub const IMPORTABLE_EXTENSIONS: &[&str] = &[
    "mp3", "m4a", "m4b", "aac", "mp4", "m4v", "mov", "wav", "wave", "aif", "aiff", "aifc", "caf",
    "flac", "ogg", "oga", "mkv", "mka",
];

pub fn is_importable(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| IMPORTABLE_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
}

/// The file name without its extension: "Team sync.m4a" becomes "Team sync".
pub fn title(path: &Path) -> String {
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().trim().to_string())
        .unwrap_or_default();
    if stem.is_empty() {
        "Imported recording".into()
    } else {
        stem
    }
}

/// Best guess at when the recording began, never so late that it would end
/// in the future (`MeetingImportService.recordingStart`). A recorder's own
/// creation date names the start. File dates are weaker: modification usually
/// marks when recording stopped and survives a copy, while a copy's creation
/// date is when it was copied, so the earlier reading wins. Dates before 2001
/// are unset container fields, not recordings.
pub fn recording_start(
    metadata: Option<DateTime<Utc>>,
    file_created: Option<DateTime<Utc>>,
    file_modified: Option<DateTime<Utc>>,
    duration: f64,
    now: DateTime<Utc>,
) -> DateTime<Utc> {
    let length = Duration::milliseconds((duration * 1000.0).round() as i64);
    let latest = now - length;
    if let Some(metadata) = plausible(metadata) {
        return metadata.min(latest);
    }
    [
        plausible(file_created),
        plausible(file_modified).map(|m| m - length),
    ]
    .into_iter()
    .flatten()
    .min()
    .unwrap_or(latest)
    .min(latest)
}

fn plausible(date: Option<DateTime<Utc>>) -> Option<DateTime<Utc>> {
    let reference = Utc.with_ymd_and_hms(2001, 1, 1, 0, 0, 0).single()?;
    date.filter(|d| *d > reference)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recording_start_prefers_the_recorder_and_never_ends_in_the_future() {
        let now = Utc.timestamp_opt(1_790_000_000, 0).unwrap();
        let recorded = Utc.timestamp_opt(1_780_000_000, 0).unwrap();
        let start =
            |metadata, created, modified| recording_start(metadata, created, modified, 60.0, now);

        assert_eq!(start(Some(recorded), Some(now), Some(now)), recorded);
        assert_eq!(
            start(None, Some(recorded), Some(recorded + Duration::seconds(65))),
            recorded
        );
        assert_eq!(
            start(None, Some(now - Duration::seconds(100)), Some(recorded)),
            recorded - Duration::seconds(60),
            "a copy keeps the time recording stopped"
        );
        assert_eq!(
            start(Some(Utc.timestamp_opt(0, 0).unwrap()), None, None),
            now - Duration::seconds(60),
            "an unset container date is not a recording date"
        );
        assert_eq!(start(Some(now), None, None), now - Duration::seconds(60));
        assert_eq!(start(None, None, None), now - Duration::seconds(60));
    }

    #[test]
    fn the_file_name_becomes_the_title() {
        assert_eq!(title(Path::new("/tmp/Team sync.m4a")), "Team sync");
        assert_eq!(title(Path::new("/tmp/ .mp3")), "Imported recording");
    }

    #[test]
    fn only_audio_and_video_files_are_importable() {
        for name in [
            "call.mp3", "call.M4A", "call.wav", "call.mp4", "call.mov", "call.ogg",
        ] {
            assert!(is_importable(Path::new(name)), "{name}");
        }
        for name in ["notes.txt", "slides.pdf", "photo.png", "noextension"] {
            assert!(!is_importable(Path::new(name)), "{name}");
        }
    }
}
