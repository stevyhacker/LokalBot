//! Library changes people make from Meetings: importing recordings, merging
//! meetings and undoing a merge, and changing a meeting's boundaries
//! (`AppState.importRecordings`, `mergeMeetings`, `undoMerge`,
//! `setMeetingBoundaries`). The app runs them on a background task, then
//! queues processing with `Command::ProcessMeeting`.

use std::fs;
use std::path::Path;

use anyhow::Result;
use chrono::{DateTime, Duration, Utc};
use lokalbot_core::merge::{self, MergeError, MergeResult, Slice, UndoError};
use lokalbot_core::{ContentRange, Library, Meeting};

/// Why a file couldn't become a meeting (`MeetingImportService.ImportError`).
#[derive(Debug)]
pub enum ImportFailure {
    Unreadable,
    NoAudio,
    Conversion(String),
    CannotCreateMeeting(String),
}

impl ImportFailure {
    /// The message for `name`, in the interface language.
    pub fn localized(&self, name: &str) -> String {
        let name = ("name", name.to_string());
        match self {
            Self::Unreadable => lokalbot_i18n::format(
                "LokalBot can't read audio from “{name}”. Try an MP3, M4A, WAV, MP4, or MOV file.",
                &[name],
            ),
            Self::NoAudio => lokalbot_i18n::format("“{name}” has no audio to transcribe.", &[name]),
            Self::Conversion(reason) => lokalbot_i18n::format(
                "Couldn't convert the audio in “{name}”: {reason}",
                &[name, ("reason", reason.clone())],
            ),
            Self::CannotCreateMeeting(reason) => lokalbot_i18n::format(
                "Couldn't add “{name}” to your meetings: {reason}",
                &[name, ("reason", reason.clone())],
            ),
        }
    }
}

/// Makes `source` a meeting whose system track is the file's audio. The
/// meeting appears only once complete: the audio is converted beside the
/// library, moved into a reserved folder, and `meta.json` is written last.
pub fn import_recording(
    library: &Library,
    source: &Path,
    now: DateTime<Utc>,
) -> Result<Meeting, ImportFailure> {
    import_file(library, source, now, None)
}

/// Adds LokalBot's sample meeting through the same import, or returns the
/// one the library already has. It is dated now, titled in its own language
/// and marked with its id, so personal memory leaves it out.
pub fn import_sample(
    library: &Library,
    sample: &crate::sample::Sample,
    now: DateTime<Utc>,
) -> Result<Meeting, ImportFailure> {
    let cannot = |e: &dyn std::fmt::Display| ImportFailure::CannotCreateMeeting(e.to_string());
    if let Some(existing) = library
        .sample_meeting()
        .map_err(|e| cannot(&format!("{e:#}")))?
    {
        return Ok(existing);
    }
    let staging = library
        .paths()
        .root()
        .join(format!(".sample-{}", uuid::Uuid::new_v4()));
    let source = staging.join(sample.file_name);
    let result = fs::create_dir_all(&staging)
        .and_then(|()| fs::write(&source, sample.audio))
        .map_err(|e| cannot(&e))
        .and_then(|()| import_file(library, &source, now, Some(sample)));
    let _ = fs::remove_dir_all(&staging);
    result
}

fn import_file(
    library: &Library,
    source: &Path,
    now: DateTime<Utc>,
    sample: Option<&crate::sample::Sample>,
) -> Result<Meeting, ImportFailure> {
    let cannot = |e: &dyn std::fmt::Display| ImportFailure::CannotCreateMeeting(e.to_string());
    let name = source
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let staging = library
        .paths()
        .root()
        .join(format!(".import-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&staging).map_err(|e| cannot(&e))?;
    let converted = staging.join(lokalbot_core::library::SYSTEM_TRACK);
    let result = (|| {
        let audio = lokalbot_audio::import_audio(source, &converted).map_err(|e| match e {
            lokalbot_audio::ImportError::Unreadable => ImportFailure::Unreadable,
            lokalbot_audio::ImportError::NoAudio => ImportFailure::NoAudio,
            lokalbot_audio::ImportError::Conversion(e) => ImportFailure::Conversion(e.to_string()),
        })?;
        let file = fs::metadata(source).ok();
        let date = |time: Option<std::time::SystemTime>| time.map(DateTime::<Utc>::from);
        let started_at = match sample {
            // The sample was "recorded" just now, whatever its file says.
            Some(_) => now - Duration::milliseconds((audio.duration * 1000.0).round() as i64),
            None => lokalbot_core::import::recording_start(
                date(audio.recorded_at),
                date(file.as_ref().and_then(|m| m.created().ok())),
                date(file.as_ref().and_then(|m| m.modified().ok())),
                audio.duration,
                now,
            ),
        };
        let started_at = DateTime::from_timestamp(started_at.timestamp(), 0).unwrap_or(started_at);
        let title = match sample {
            Some(sample) => sample.title.to_string(),
            None => lokalbot_core::import::title(source),
        };
        let relative = library
            .reserve_meeting_folder(&title, started_at)
            .map_err(|e| cannot(&format!("{e:#}")))?;
        let mut meeting = Meeting::new(
            &title,
            lokalbot_core::import::IMPORTED_APP_NAME,
            started_at,
            &relative,
        );
        meeting.ended_at =
            Some(started_at + Duration::milliseconds((audio.duration * 1000.0).round() as i64));
        meeting.recorded_duration = Some(audio.duration);
        meeting.has_system_track = true;
        meeting.imported_file_names = Some(vec![name.clone()]);
        meeting.sample_id = sample.map(|s| s.id.to_string());
        let folder = library.meeting_dir(&meeting);
        let moved = fs::rename(
            &converted,
            folder.join(lokalbot_core::library::SYSTEM_TRACK),
        )
        .map_err(anyhow::Error::from)
        .and_then(|()| library.save_meeting(&meeting));
        if let Err(err) = moved {
            let _ = fs::remove_dir_all(&folder);
            return Err(cannot(&format!("{err:#}")));
        }
        Ok(meeting)
    })();
    let _ = fs::remove_dir_all(&staging);
    result
}

/// Merges `meetings` into a new one with WAV tracks. On success the
/// merged meeting is indexed for search; the sources leave it.
pub fn merge_meetings(
    library: &Library,
    meetings: &[Meeting],
    title: &str,
) -> Result<MergeResult, MergeError> {
    let splice = |slices: &[Slice], dest: &Path| {
        let parts: Vec<lokalbot_audio::SplicePart<'_>> = slices
            .iter()
            .map(|s| (s.source.as_deref(), s.start, s.end))
            .collect();
        lokalbot_audio::splice_tracks(&parts, dest)
    };
    let result = merge::merge_meetings(library, meetings, title, &splice)?;
    if let Err(err) = library.reindex_meeting(&result.meeting) {
        log::warn!("indexing the merged meeting failed: {err:#}");
    }
    Ok(result)
}

/// Removes a merged meeting and indexes its restored sources again.
pub fn undo_merge(library: &Library, merged: &Meeting) -> Result<Vec<Meeting>, UndoError> {
    let restored = merge::undo_merge(library, merged)?;
    for meeting in &restored {
        if let Err(err) = library.reindex_meeting(meeting) {
            log::warn!("indexing a restored meeting failed: {err:#}");
        }
    }
    Ok(restored)
}

/// Saves the reviewed range and re-indexes what is left of the transcript.
pub fn set_meeting_boundaries(
    library: &Library,
    meeting: &Meeting,
    range: ContentRange,
) -> Result<Meeting> {
    let updated = library.set_meeting_boundaries(meeting, range)?;
    library.reindex_meeting(&updated)?;
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::LibraryPaths;

    fn write_tone(path: &Path, seconds: f64, rate: u32, channels: u16) {
        // 16-bit PCM at any rate and channel count, as recorders write it.
        let frames = (seconds * rate as f64) as usize;
        let mut data = Vec::with_capacity(frames * channels as usize * 2);
        for i in 0..frames {
            let sample =
                ((i as f64 * 440.0 * std::f64::consts::TAU / rate as f64).sin() * 8000.0) as i16;
            for _ in 0..channels {
                data.extend_from_slice(&sample.to_le_bytes());
            }
        }
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&1u16.to_le_bytes());
        bytes.extend_from_slice(&channels.to_le_bytes());
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&(rate * channels as u32 * 2).to_le_bytes());
        bytes.extend_from_slice(&(channels * 2).to_le_bytes());
        bytes.extend_from_slice(&16u16.to_le_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&data);
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn every_sample_recording_imports_in_its_own_language() {
        for sample in crate::sample::SAMPLES {
            let dir = tempfile::tempdir().unwrap();
            let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
            let meeting = import_sample(&library, sample, Utc::now()).unwrap();
            assert_eq!(meeting.title, sample.title);
            assert_eq!(meeting.sample_id.as_deref(), Some(sample.id));
            let duration = meeting.recorded_duration.unwrap();
            assert!(
                (180.0..300.0).contains(&duration),
                "{} runs {duration} s",
                sample.id
            );
        }
    }

    #[test]
    fn the_sample_imports_once_and_stays_out_of_personal_memory() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let source = dir.path().join("Design review.wav");
        write_tone(&source, 2.0, 16_000, 1);
        let own = import_recording(&library, &source, Utc::now()).unwrap();
        let now = Utc::now();

        let sample = import_sample(&library, &crate::sample::ENGLISH, now).unwrap();
        assert_eq!(sample.title, "Sample: Orders API delivery window");
        assert_eq!(sample.sample_id.as_deref(), Some("orders-api/en"));
        assert!(sample.is_sample() && !sample.is_own_work() && sample.is_imported());
        let duration = sample.recorded_duration.unwrap();
        assert!(
            (200.0..240.0).contains(&duration),
            "the sample runs {duration} s"
        );
        assert!(
            (sample.ended_at.unwrap() - now).num_seconds().abs() <= 1,
            "dated now"
        );
        assert!(library.audio(&sample).system.is_some());
        let on_disk: serde_json::Value = serde_json::from_slice(
            &fs::read(library.meeting_dir(&sample).join("meta.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(on_disk["sampleID"], "orders-api/en");

        // A second request opens the same sample instead of adding another.
        let again = import_sample(&library, &crate::sample::ENGLISH, Utc::now()).unwrap();
        assert_eq!(again.id, sample.id);
        assert_eq!(library.list_meetings().unwrap().len(), 2);
        assert_eq!(
            library
                .list_own_meetings()
                .unwrap()
                .iter()
                .map(|m| m.id)
                .collect::<Vec<_>>(),
            vec![own.id]
        );
        assert_eq!(
            library.sample_meeting().unwrap().map(|m| m.id),
            Some(sample.id)
        );
        let day = lokalbot_core::time::local_day(sample.started_at);
        assert_eq!(
            library.day_activity(day).unwrap().meeting_count,
            1,
            "only the own meeting"
        );
        assert!(!lokalbot_core::merge::can_merge(
            &[own.clone(), sample.clone()],
            |_| false
        ));
        assert!(fs::read_dir(library.paths().root()).unwrap().all(|e| {
            !e.unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".sample-")
        }));

        // Removing it is one call.
        library.delete_meeting(&sample).unwrap();
        assert!(library.sample_meeting().unwrap().is_none());
        assert_eq!(library.list_meetings().unwrap().len(), 1);
    }

    #[test]
    fn an_imported_file_becomes_a_system_track_meeting() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let source = dir.path().join("Design review.wav");
        write_tone(&source, 2.0, 44_100, 2);
        let original = fs::read(&source).unwrap();
        let now = Utc::now();

        let meeting = import_recording(&library, &source, now).unwrap();
        assert_eq!(meeting.title, "Design review");
        assert_eq!(meeting.app_name, "Imported file");
        assert_eq!(
            meeting.imported_file_names.as_deref(),
            Some(&["Design review.wav".to_string()][..])
        );
        assert!(meeting.has_system_track && meeting.is_imported() && !meeting.is_live());
        assert!((meeting.recorded_duration.unwrap() - 2.0).abs() < 0.05);
        assert!(meeting.ended_at.unwrap() <= now + Duration::seconds(1));

        let audio = library.audio(&meeting);
        assert!(audio.mic.is_none());
        let system = audio.system.unwrap();
        assert_eq!(system.file_name().unwrap(), "system.wav");
        let info = lokalbot_audio::read_info(&system).unwrap();
        assert_eq!((info.sample_rate, info.channels), (16_000, 1));
        assert_eq!(
            fs::read(&source).unwrap(),
            original,
            "the original file is only read"
        );
        let listed = library.list_meetings().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].imported_file_names, meeting.imported_file_names);
        // Staging beside the library is cleaned up.
        assert!(fs::read_dir(library.paths().root()).unwrap().all(|e| {
            !e.unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".import-")
        }));
    }

    #[test]
    fn an_unreadable_file_leaves_no_meeting_behind() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let source = dir.path().join("call.mp3");
        fs::write(&source, b"not audio at all").unwrap();
        let failure = import_recording(&library, &source, Utc::now()).unwrap_err();
        assert!(matches!(failure, ImportFailure::Unreadable), "{failure:?}");
        assert!(failure.localized("call.mp3").contains("call.mp3"));
        assert!(library.list_all_meetings().unwrap().is_empty());
        let silent = dir.path().join("silent.wav");
        write_tone(&silent, 0.1, 16_000, 1);
        assert!(matches!(
            import_recording(&library, &silent, Utc::now()).unwrap_err(),
            ImportFailure::NoAudio
        ));
        assert!(library.list_all_meetings().unwrap().is_empty());
    }

    /// A macOS-recorded AAC track imports through the MP4 path.
    #[test]
    fn imports_a_macos_aac_recording() {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../../LokalBotTests/Fixtures/upgrade/0.10.9/library/meetings/2026/10/17-design-review/mic.m4a",
        );
        if !fixture.is_file() {
            eprintln!("fixture missing at {}", fixture.display());
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let meeting = import_recording(&library, &fixture, Utc::now()).unwrap();
        assert!((meeting.recorded_duration.unwrap() - 140.0).abs() < 0.1);
    }

    #[test]
    fn merge_writes_tracks_end_to_end_and_undo_restores_the_sources() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let mut sources = Vec::new();
        for (index, seconds) in [3.0, 2.0].into_iter().enumerate() {
            let started = Utc::now() - Duration::hours(2 - index as i64);
            let mut meeting = library
                .create_meeting(&format!("Part {}", index + 1), "Zoom", started)
                .unwrap();
            write_tone(
                &library.meeting_dir(&meeting).join("mic.wav"),
                seconds,
                16_000,
                1,
            );
            meeting.ended_at = Some(started + Duration::seconds(seconds as i64));
            meeting.recorded_duration = Some(seconds);
            library.save_meeting(&meeting).unwrap();
            sources.push(meeting);
        }
        // Keep only 0.5–2.5 s of the first part.
        sources[0] = library
            .set_meeting_boundaries(
                &sources[0],
                ContentRange {
                    start: 0.5,
                    end: 2.5,
                },
            )
            .unwrap();

        let result = merge_meetings(&library, &sources, "  Whole   call ").unwrap();
        let merged = &result.meeting;
        assert_eq!(merged.title, "Whole call");
        assert_eq!(merged.app_name, "Merged meetings");
        assert_eq!(merged.recorded_duration, Some(4.0));
        assert!(!merged.has_system_track);
        let audio = library.audio(merged);
        let mic = lokalbot_audio::duration_seconds(audio.mic.as_ref().unwrap()).unwrap();
        assert!((mic - 4.0).abs() < 0.01, "{mic}");
        assert!(audio.system.is_none());
        let visible: Vec<_> = library
            .list_meetings()
            .unwrap()
            .iter()
            .map(|m| m.id)
            .collect();
        assert_eq!(visible, [merged.id]);
        let manifest: merge::Manifest = lokalbot_core::library::read_json(
            &library.meeting_dir(merged).join(merge::MANIFEST_FILE),
        )
        .unwrap()
        .unwrap();
        assert_eq!(manifest.version, 2);
        assert_eq!(manifest.sources[0].duration, 2.0);
        assert_eq!(manifest.sources[0].has_audio, Some(true));
        assert_eq!(manifest.sources[1].has_transcript, Some(false));

        let restored = undo_merge(&library, merged).unwrap();
        assert_eq!(restored.len(), 2);
        assert!(restored.iter().all(|m| m.merged_into_meeting_id.is_none()));
        let mut visible: Vec<_> = library
            .list_meetings()
            .unwrap()
            .iter()
            .map(|m| m.id)
            .collect();
        visible.sort();
        let mut expected: Vec<_> = sources.iter().map(|m| m.id).collect();
        expected.sort();
        assert_eq!(visible, expected);
        assert!(!library.meeting_dir(merged).exists());
    }
}
