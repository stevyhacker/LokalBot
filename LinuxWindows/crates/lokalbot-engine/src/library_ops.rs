//! Library changes people make from Meetings: importing recordings, merging
//! meetings and undoing a merge, and changing a meeting's boundaries
//! (`AppState.importRecordings`, `mergeMeetings`, `undoMerge`,
//! `setMeetingBoundaries`). The app runs them on a background task, then
//! queues processing with `Command::ProcessMeeting`. A recording a paired
//! device sends takes the same import from the companion host.

use std::fs;
use std::path::Path;

use anyhow::Result;
use chrono::{DateTime, Duration, Utc};
use lokalbot_core::merge::{self, MergeError, MergeResult, Slice, UndoError};
use lokalbot_core::{ContentRange, Library, Meeting};
use uuid::Uuid;

/// A device can send any title; a meeting keeps at most this much of one.
const MAX_DEVICE_TITLE_CHARACTERS: usize = 200;
/// Well inside the 255 bytes a folder name can have, day and counter included.
const MAX_DEVICE_FOLDER_BYTES: usize = 120;

/// Why a file couldn't become a meeting (`MeetingImportService.ImportError`).
#[derive(Debug)]
pub enum ImportFailure {
    Unreadable,
    NoAudio,
    Conversion(String),
    CannotCreateMeeting(String),
    /// A device's recording whose id isn't a UUID.
    InvalidId,
}

impl ImportFailure {
    /// The message for `name`, in the interface language.
    pub fn localized(&self, name: &str) -> String {
        let name = ("name", name.to_string());
        match self {
            // `lokalbot-sync` refuses a bad id before any audio is sent.
            Self::Unreadable | Self::InvalidId => lokalbot_i18n::format(
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

/// Where a file's audio came from, which decides the meeting it makes.
enum Origin<'a> {
    File,
    Sample(&'a crate::sample::Sample),
    Device {
        id: Uuid,
        title: String,
        started_at: Option<DateTime<Utc>>,
        device_name: &'a str,
    },
}

/// Makes `source` a meeting whose system track is the file's audio. The
/// meeting appears only once complete: the audio is converted beside the
/// library, moved into a reserved folder, and `meta.json` is written last.
pub fn import_recording(
    library: &Library,
    source: &Path,
    now: DateTime<Utc>,
) -> Result<Meeting, ImportFailure> {
    import_file(library, source, now, &Origin::File)
}

/// A recording a paired phone or tablet sent, as the device and its pairing
/// describe it.
#[derive(Clone, Copy, Debug)]
pub struct DeviceRecording<'a> {
    /// The UUID the meeting takes, so sending it again makes no second one.
    pub id: &'a str,
    pub title: Option<&'a str>,
    /// ISO 8601, by the device's clock.
    pub started_at: Option<&'a str>,
    pub device_name: &'a str,
}

impl DeviceRecording<'_> {
    /// What the person called it, or which device it came from.
    pub fn meeting_title(&self) -> String {
        let chosen = lokalbot_core::text::sanitize(
            self.title.unwrap_or(""),
            Some(MAX_DEVICE_TITLE_CHARACTERS),
        )
        .replace('\n', " ");
        if chosen.is_empty() {
            lokalbot_i18n::mac("Recording from %@", &[self.device_name])
        } else {
            chosen
        }
    }
}

/// The meeting a device's recording is, and whether this call made it.
#[derive(Debug)]
pub struct DeviceImport {
    pub meeting: Meeting,
    /// False when it was already here, from an earlier attempt.
    pub is_new: bool,
}

/// Makes a meeting of a recording from a paired device, or returns the one that
/// already has its id, untouched. It is the device's microphone, the person's
/// own, so it becomes the microphone track: their speech counts as theirs, and
/// other voices in the room are treated as this computer's microphone treats
/// them, not as call participants. Like any import it takes no screen context,
/// because the person wasn't at this computer.
pub fn import_device_recording(
    library: &Library,
    source: &Path,
    recording: &DeviceRecording<'_>,
    now: DateTime<Utc>,
) -> Result<DeviceImport, ImportFailure> {
    let id = Uuid::parse_str(recording.id).map_err(|_| ImportFailure::InvalidId)?;
    let existing = library
        .meeting(id)
        .map_err(|e| ImportFailure::CannotCreateMeeting(format!("{e:#}")))?;
    if let Some(meeting) = existing {
        return Ok(DeviceImport {
            meeting,
            is_new: false,
        });
    }
    let started_at = recording
        .started_at
        .and_then(|at| DateTime::parse_from_rfc3339(at).ok())
        .map(|at| at.with_timezone(&Utc));
    let origin = Origin::Device {
        id,
        title: recording.meeting_title(),
        started_at,
        device_name: recording.device_name,
    };
    Ok(DeviceImport {
        meeting: import_file(library, source, now, &origin)?,
        is_new: true,
    })
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
        .and_then(|()| import_file(library, &source, now, &Origin::Sample(sample)));
    let _ = fs::remove_dir_all(&staging);
    result
}

fn import_file(
    library: &Library,
    source: &Path,
    now: DateTime<Utc>,
    origin: &Origin<'_>,
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
    let track = match origin {
        Origin::Device { .. } => lokalbot_core::library::MIC_TRACK,
        _ => lokalbot_core::library::SYSTEM_TRACK,
    };
    let converted = staging.join(track);
    let result = (|| {
        let audio = lokalbot_audio::import_audio(source, &converted).map_err(|e| match e {
            lokalbot_audio::ImportError::Unreadable => ImportFailure::Unreadable,
            lokalbot_audio::ImportError::NoAudio => ImportFailure::NoAudio,
            lokalbot_audio::ImportError::Conversion(e) => ImportFailure::Conversion(e.to_string()),
        })?;
        let file = fs::metadata(source).ok();
        let date = |time: Option<std::time::SystemTime>| time.map(DateTime::<Utc>::from);
        let recorded_at = match origin {
            Origin::Device {
                started_at: Some(at),
                ..
            } => Some(*at),
            _ => date(audio.recorded_at),
        };
        let started_at = match origin {
            // The sample was "recorded" just now, whatever its file says.
            Origin::Sample(_) => {
                now - Duration::milliseconds((audio.duration * 1000.0).round() as i64)
            }
            _ => lokalbot_core::import::recording_start(
                recorded_at,
                date(file.as_ref().and_then(|m| m.created().ok())),
                date(file.as_ref().and_then(|m| m.modified().ok())),
                audio.duration,
                now,
            ),
        };
        let started_at = DateTime::from_timestamp(started_at.timestamp(), 0).unwrap_or(started_at);
        let title = match origin {
            Origin::File => lokalbot_core::import::title(source),
            Origin::Sample(sample) => sample.title.to_string(),
            Origin::Device { title, .. } => title.clone(),
        };
        let folder_title = match origin {
            Origin::Device { .. } => device_folder_title(&title),
            _ => title.clone(),
        };
        let relative = library
            .reserve_meeting_folder(&folder_title, started_at)
            .map_err(|e| cannot(&format!("{e:#}")))?;
        let app_name = match origin {
            Origin::Device { device_name, .. } => *device_name,
            _ => lokalbot_core::import::IMPORTED_APP_NAME,
        };
        let mut meeting = Meeting::new(&title, app_name, started_at, &relative);
        meeting.ended_at =
            Some(started_at + Duration::milliseconds((audio.duration * 1000.0).round() as i64));
        meeting.recorded_duration = Some(audio.duration);
        meeting.has_system_track = track == lokalbot_core::library::SYSTEM_TRACK;
        meeting.imported_file_names = Some(vec![name.clone()]);
        match origin {
            Origin::File => {}
            Origin::Sample(sample) => meeting.sample_id = Some(sample.id.to_string()),
            Origin::Device { id, .. } => {
                meeting.id = *id;
                // The upload's own name means nothing to anyone.
                meeting.imported_file_names =
                    Some(vec![format!("{}.aac", lokalbot_core::ids::uuid_upper(id))]);
            }
        }
        let folder = library.meeting_dir(&meeting);
        let moved = fs::rename(&converted, folder.join(track))
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

/// The start of a device's title whose slug fits a folder name. Characters
/// aren't enough to count: a Hangul syllable takes nine bytes in a slug.
fn device_folder_title(title: &str) -> String {
    let mut fitting = title.to_string();
    while lokalbot_core::ids::slugify(&fitting).len() > MAX_DEVICE_FOLDER_BYTES {
        fitting.pop();
    }
    fitting
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
        // The own meeting's day: the sample starts minutes before now, which just
        // after midnight is yesterday.
        let day = lokalbot_core::time::local_day(own.started_at);
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

    /// The audio phones and tablets send: one second of a 440 Hz tone, as an
    /// ADTS AAC stream.
    const ADTS_TONE: &[u8] = include_bytes!("../../lokalbot-audio/tests/data/tone-440-adts.aac");

    /// A partial upload's name, as `lokalbot-sync` keeps it.
    fn device_file(dir: &Path, bytes: &[u8]) -> std::path::PathBuf {
        let path = dir.join("upload-0123456789abcdef.aac");
        fs::write(&path, bytes).unwrap();
        path
    }

    const DEVICE_ID: &str = "6f1c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e77";

    fn from_device<'a>(title: Option<&'a str>, started_at: Option<&'a str>) -> DeviceRecording<'a> {
        DeviceRecording {
            id: DEVICE_ID,
            title,
            started_at,
            device_name: "Maya's Pixel",
        }
    }

    #[test]
    fn a_device_recording_becomes_a_microphone_meeting_with_its_id() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let source = device_file(dir.path(), ADTS_TONE);
        let now = Utc::now();

        let imported = import_device_recording(
            &library,
            &source,
            &from_device(Some("  Site visit\n"), Some("2026-10-01T09:30:00.250Z")),
            now,
        )
        .unwrap();
        assert!(imported.is_new);
        let meeting = imported.meeting;
        assert_eq!(meeting.id, Uuid::parse_str(DEVICE_ID).unwrap());
        assert_eq!(meeting.title, "Site visit");
        assert_eq!(meeting.app_name, "Maya's Pixel");
        assert_eq!(meeting.started_at.to_rfc3339(), "2026-10-01T09:30:00+00:00");
        assert!(!meeting.has_system_track && !meeting.is_live());
        assert!(
            meeting.is_imported() && meeting.is_own_work(),
            "imported, so it takes no screen context"
        );
        assert_eq!(
            meeting.imported_file_names.as_deref(),
            Some(&["6F1C2A10-8A4E-4D2B-9B1E-0A1B2C3D4E77.aac".to_string()][..])
        );
        assert!((meeting.recorded_duration.unwrap() - 1.0).abs() < 0.1);

        let audio = library.audio(&meeting);
        assert!(audio.system.is_none());
        let mic = audio.mic.unwrap();
        assert_eq!(mic.file_name().unwrap(), "mic.wav");
        let info = lokalbot_audio::read_info(&mic).unwrap();
        assert_eq!((info.sample_rate, info.channels), (16_000, 1));

        assert_eq!(
            fs::read(&source).unwrap(),
            ADTS_TONE,
            "the upload is only read"
        );
        let stored = library.meeting(meeting.id).unwrap().unwrap();
        assert_eq!(stored.app_name, meeting.app_name);
        assert_eq!(stored.imported_file_names, meeting.imported_file_names);
        assert_eq!(library.list_meetings().unwrap().len(), 1);
    }

    #[test]
    fn a_device_recording_arrives_once() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let source = device_file(dir.path(), ADTS_TONE);
        let recording = from_device(Some("Site visit"), None);
        let first = import_device_recording(&library, &source, &recording, Utc::now()).unwrap();
        assert!(first.is_new);
        let meta = library.meeting_dir(&first.meeting).join("meta.json");
        let written = fs::read(&meta).unwrap();

        // Whatever a retry says, and even with its audio gone.
        fs::remove_file(&source).unwrap();
        let again = import_device_recording(
            &library,
            &source,
            &from_device(Some("Another title"), None),
            Utc::now(),
        )
        .unwrap();
        assert!(!again.is_new);
        assert_eq!(again.meeting.id, first.meeting.id);
        assert_eq!(again.meeting.title, "Site visit");
        assert_eq!(fs::read(&meta).unwrap(), written, "nothing is touched");
        assert_eq!(library.list_meetings().unwrap().len(), 1);
    }

    #[test]
    fn a_device_recording_without_a_title_says_where_it_came_from() {
        for title in [None, Some(""), Some(" \n ")] {
            assert_eq!(
                from_device(title, None).meeting_title(),
                "Recording from Maya's Pixel"
            );
        }
        // A device name can't be read as a template.
        let odd = DeviceRecording {
            device_name: "%@ {name}",
            ..from_device(None, None)
        };
        assert_eq!(odd.meeting_title(), "Recording from %@ {name}");
    }

    #[test]
    fn a_device_title_of_any_length_makes_a_folder() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let source = device_file(dir.path(), ADTS_TONE);
        for (index, words) in ["Састанак на градилишту ", "현장 방문 회의 "]
            .iter()
            .enumerate()
        {
            let id = format!("6f1c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e0{index}");
            let title = words.repeat(200);
            let recording = DeviceRecording {
                id: &id,
                ..from_device(Some(&title), None)
            };
            let meeting = import_device_recording(&library, &source, &recording, Utc::now())
                .unwrap()
                .meeting;
            assert!(meeting.title.chars().count() <= MAX_DEVICE_TITLE_CHARACTERS);
            assert!(meeting.title.starts_with(words.trim()));
            assert!(library.meeting_dir(&meeting).join("mic.wav").is_file());
        }
    }

    #[test]
    fn a_device_recording_never_ends_in_the_future() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let source = device_file(dir.path(), ADTS_TONE);
        let now = Utc::now();
        // A phone whose clock runs ahead, one that says nothing, and nonsense.
        let ahead = (now + Duration::hours(3)).to_rfc3339();
        for (id, started_at) in [
            ("6f1c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e01", Some(ahead.as_str())),
            ("6f1c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e02", None),
            ("6f1c2a10-8a4e-4d2b-9b1e-0a1b2c3d4e03", Some("yesterday")),
        ] {
            let recording = DeviceRecording {
                id,
                ..from_device(Some("Site visit"), started_at)
            };
            let meeting = import_device_recording(&library, &source, &recording, now)
                .unwrap()
                .meeting;
            assert!(meeting.ended_at.unwrap() <= now, "{started_at:?}");
            assert!(meeting.started_at <= now, "{started_at:?}");
            assert!(
                now - meeting.started_at < Duration::minutes(1),
                "{started_at:?} starts about now, as the file dates say"
            );
        }
    }

    #[test]
    fn a_device_recording_that_cant_be_used_leaves_no_meeting_behind() {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().join("library"))).unwrap();
        let source = device_file(dir.path(), ADTS_TONE);
        for id in ["", "not-a-uuid", "../../meetings"] {
            let recording = DeviceRecording {
                id,
                ..from_device(None, None)
            };
            let failure =
                import_device_recording(&library, &source, &recording, Utc::now()).unwrap_err();
            assert!(matches!(failure, ImportFailure::InvalidId), "{failure:?}");
            assert!(failure.localized("the recording").contains("the recording"));
        }

        let recording = from_device(None, None);
        // Stopped under MIN_IMPORT_SECONDS.
        let short = device_file(dir.path(), &ADTS_TONE[..ADTS_TONE.len() / 10]);
        let failure =
            import_device_recording(&library, &short, &recording, Utc::now()).unwrap_err();
        assert!(matches!(failure, ImportFailure::NoAudio), "{failure:?}");

        let garbage = device_file(dir.path(), b"not audio at all");
        let failure =
            import_device_recording(&library, &garbage, &recording, Utc::now()).unwrap_err();
        assert!(matches!(failure, ImportFailure::Unreadable), "{failure:?}");

        assert!(library.list_all_meetings().unwrap().is_empty());
        assert!(fs::read_dir(library.paths().root()).unwrap().all(|e| {
            !e.unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".import-")
        }));
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
