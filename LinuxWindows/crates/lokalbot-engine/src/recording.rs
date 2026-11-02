//! Starting and stopping meeting recordings (`RecordingController.swift`).

use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

use anyhow::{Context as _, Result};
use parking_lot::Mutex;

use chrono::{DateTime, Utc};
use lokalbot_audio::{AppAudioTarget, Recorder, RecorderOptions, next_target};
use lokalbot_core::calendar::{self as calendar_policy, CalendarEvent};
use lokalbot_core::meeting_review::{recording_advisory, short_capture_warning};
use lokalbot_core::{Library, Meeting, Settings};
use uuid::Uuid;

use crate::pipeline::Pipeline;
use crate::{EngineEvent, RecordingSaved, RecordingUpdate, Shared};

pub struct Recording {
    shared: Arc<Shared>,
    pipeline: Pipeline,
    active: Arc<Mutex<Option<Active>>>,
    /// The calendar event of the last recording the user stopped, and when,
    /// so detection cannot immediately restart a meeting they ended
    /// (`lastCalendarEventID`, `calendarRepeatCooldown`).
    last_stopped_event: Mutex<Option<(String, DateTime<Utc>)>>,
    /// Stopped recordings whose details or processing job could not be saved.
    /// Quitting saves them again and stays open if it still can't
    /// (`pendingFinalizations`).
    pending: Mutex<HashMap<Uuid, PendingFinalization>>,
    /// Free bytes on the library's volume, replaced in tests.
    free_bytes: fn(&Path) -> Option<u64>,
}

/// A stopped recording on its way to disk (`PendingFinalization`).
struct PendingFinalization {
    meeting: Meeting,
    transcribe: bool,
    summarize: bool,
    metadata_saved: bool,
}

struct Active {
    meeting: Meeting,
    recorder: Recorder,
    ticker_stop: Arc<AtomicBool>,
    ticker: Option<JoinHandle<()>>,
    /// Started by the detector; its call's end may stop it.
    automatic: bool,
    /// Live warnings and `recording-health.json`.
    health: crate::capture_health::CaptureMonitor,
    /// The meeting app whose sound the system track is bound to.
    system_app: Option<AppAudioTarget>,
}

/// The sound to record for a detected call.
fn audio_target(meeting: &lokalbot_platform::DetectedMeeting) -> AppAudioTarget {
    AppAudioTarget {
        pid: meeting.audio_pid,
        process_name: meeting.process_name.clone(),
        app_name: meeting.app_name.clone(),
    }
}

/// Whether a detected call can be the one a recording is for
/// (`CaptureIntent.accepts`): a recording that names a room accepts only that
/// room. Calendar links can carry query parameters such as `?authuser=0`.
fn accepts_call(recording_url: Option<&str>, detected_url: Option<&str>) -> bool {
    let room = |url: &str| lokalbot_platform::meet_url(url).unwrap_or_else(|| url.to_string());
    match (recording_url, detected_url) {
        (Some(recording), Some(detected)) => room(recording) == room(detected),
        _ => true,
    }
}

/// A call found during a recording: its sound from now on, and its room.
fn bind_detected_call(
    active: &mut Active,
    detected: &lokalbot_platform::DetectedMeeting,
    library: &Library,
) {
    if !accepts_call(
        active.meeting.meeting_url.as_deref(),
        detected.meeting_url.as_deref(),
    ) {
        return;
    }
    let bound_app = active.system_app.is_none();
    if let Some(next) = next_target(active.system_app.as_ref(), Some(&audio_target(detected))) {
        active.recorder.set_system_app(next.clone());
        active.system_app = Some(next);
    }
    let same_app = !bound_app
        && active
            .system_app
            .as_ref()
            .is_some_and(|app| app.same_app(&audio_target(detected)));
    if (bound_app || same_app)
        && active.meeting.meeting_url.is_none()
        && detected.meeting_url.is_some()
    {
        active.meeting.meeting_url = detected.meeting_url.clone();
        if let Err(err) = library.save_meeting(&active.meeting) {
            log::warn!("could not save the room of the recording: {err:#}");
        }
    }
}

/// What a recording is for (`MeetingDetectionContext`).
#[derive(Clone, Debug, Default)]
pub struct RecordingStart {
    pub title: Option<String>,
    pub app_name: Option<String>,
    /// The calendar event it is stamped with.
    pub calendar: Option<CalendarEvent>,
    pub source: StartSource,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum StartSource {
    /// Record Now, the tray, a notification or Today.
    #[default]
    User,
    /// Automatic mode; suppressed for an event the user just stopped.
    Detector,
    /// The next event of a call the detector is recording.
    CalendarHandoff,
}

impl Recording {
    pub fn new(shared: Arc<Shared>, pipeline: Pipeline) -> Self {
        Self {
            shared,
            pipeline,
            active: Arc::new(Mutex::new(None)),
            last_stopped_event: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            free_bytes: lokalbot_platform::disk::available_bytes,
        }
    }

    /// Every way to start a recording ends here: the buttons, the tray, the
    /// palette, a second `lokalbot` process, the detector, a notification and
    /// Today's calendar rows.
    pub fn start(&self, request: RecordingStart) {
        // A calendar handoff continues a recording, which dictation can't be
        // running over; every other start asks first (`startRecording`).
        if request.source != StartSource::CalendarHandoff
            && self.shared.dictation_state.lock().is_busy()
        {
            self.refuse(lokalbot_i18n::tr(
                "Finish or cancel dictation before starting a meeting recording.",
            ));
            return;
        }
        if self.active.lock().is_some() {
            if request.source == StartSource::User {
                self.shared.message("LokalBot is already recording.");
            }
            return;
        }
        if request.source == StartSource::Detector {
            let last = self.last_stopped_event.lock().clone();
            if calendar_policy::should_suppress_repeat(
                request.calendar.as_ref().map(|e| e.external_id.as_str()),
                last.as_ref().map(|(id, _)| id.as_str()),
                last.as_ref().map(|(_, at)| *at),
                Utc::now(),
                calendar_policy::REPEAT_COOLDOWN,
            ) {
                log::info!("not recording again a calendar event the user just stopped");
                return;
            }
        }
        // A recording that dies mid-meeting from a full disk loses the meeting;
        // a clear refusal doesn't. Nothing has been created yet.
        let root = self.shared.library.paths().root();
        if let Some(advisory) = recording_advisory((self.free_bytes)(root)) {
            log::warn!("not recording: low disk space");
            self.refuse(&advisory);
            return;
        }
        if let Err(err) = self.try_start(request) {
            log::error!("could not start recording: {err:#}");
            self.shared
                .emit(EngineEvent::Recording(RecordingUpdate::Failed {
                    message: format!("Recording could not start: {err:#}"),
                }));
        }
    }

    fn refuse(&self, message: &str) {
        self.shared
            .emit(EngineEvent::Recording(RecordingUpdate::Failed {
                message: message.to_string(),
            }));
    }

    fn try_start(&self, request: RecordingStart) -> Result<()> {
        let settings = self.shared.settings();
        let library = &self.shared.library;
        let calendar_title = request
            .calendar
            .as_ref()
            .filter(|_| settings.use_calendar_titles)
            .map(|event| event.title.trim())
            .filter(|title| !title.is_empty());
        let title = match calendar_title {
            Some(title) => title.to_string(),
            None => request.title.clone().unwrap_or_else(|| {
                calendar_policy::recording_title(None, false, request.app_name.as_deref())
            }),
        };
        let app_name = request.app_name.unwrap_or_else(|| "Recording".to_string());
        let mut meeting =
            library.create_meeting(&title, &app_name, lokalbot_core::time::now_seconds())?;
        if let Some(event) = &request.calendar {
            calendar_policy::stamp_meeting(&mut meeting, event, settings.use_calendar_agenda);
            if let Err(err) = library.save_meeting(&meeting) {
                log::warn!("could not save the calendar details of the recording: {err:#}");
            }
        }
        let detected = self.shared.detected_meeting.lock().clone().filter(|call| {
            accepts_call(meeting.meeting_url.as_deref(), call.meeting_url.as_deref())
        });
        let system_app = detected
            .as_ref()
            .filter(|_| settings.record_system_audio)
            .map(audio_target);
        if meeting.meeting_url.is_none()
            && let Some(url) = detected.as_ref().and_then(|call| call.meeting_url.clone())
        {
            meeting.meeting_url = Some(url);
            if let Err(err) = library.save_meeting(&meeting) {
                log::warn!("could not save the room of the recording: {err:#}");
            }
        }
        let options = RecorderOptions {
            mic_device: Some(settings.microphone_device.clone()).filter(|d| !d.is_empty()),
            capture_system: settings.record_system_audio,
            system_app: system_app.clone(),
        };
        let recorder = match Recorder::start(&library.meeting_dir(&meeting), options) {
            Ok(recorder) => recorder,
            Err(err) => {
                let _ = library.delete_meeting(&meeting);
                return Err(err).context("opening the microphone");
            }
        };
        let has_system_audio = recorder.has_system_audio();
        let ticker_stop = Arc::new(AtomicBool::new(false));
        let ticker = {
            let active = self.active.clone();
            let shared = self.shared.clone();
            let stop = ticker_stop.clone();
            std::thread::Builder::new()
                .name("lokalbot-recording-levels".into())
                .spawn(move || {
                    while !stop.load(Ordering::Relaxed) {
                        if let Some(active) = active.lock().as_mut() {
                            let detected = shared.detected_meeting.lock().clone();
                            if let Some(detected) = &detected
                                && active.recorder.has_system_audio()
                            {
                                bind_detected_call(active, detected, &shared.library);
                            }
                            if let Some((warnings, notify)) = active.health.tick(&active.recorder) {
                                shared.emit(EngineEvent::Recording(
                                    RecordingUpdate::CaptureWarnings { warnings, notify },
                                ));
                            }
                            let levels = active.recorder.levels();
                            let status = active.recorder.status();
                            shared.emit(EngineEvent::Recording(RecordingUpdate::Levels {
                                mic: levels.mic,
                                system: levels.system,
                                mic_status: status.mic.label().to_string(),
                                system_status: status.system.label().to_string(),
                                elapsed_seconds: active.recorder.elapsed().as_secs_f64(),
                                last_recovery: active.recorder.since_recovery().and_then(|since| {
                                    chrono::Duration::from_std(since)
                                        .ok()
                                        .map(|since| chrono::Utc::now() - since)
                                }),
                            }));
                        }
                        std::thread::sleep(Duration::from_millis(200));
                    }
                })?
        };
        self.shared.capture_active.store(true, Ordering::Relaxed);
        self.shared.recording_active.store(true, Ordering::Relaxed);
        self.shared.background_conditions_changed();
        *self.shared.recording_meeting.lock() = Some(meeting.id);
        self.shared
            .emit(EngineEvent::Recording(RecordingUpdate::Started {
                meeting: meeting.clone(),
                has_system_audio,
            }));
        self.shared.emit(EngineEvent::LibraryChanged);
        let health = crate::capture_health::CaptureMonitor::new(
            library.meeting_dir(&meeting),
            library.paths().root().to_path_buf(),
            settings.record_system_audio,
        );
        *self.active.lock() = Some(Active {
            meeting,
            recorder,
            ticker_stop,
            ticker: Some(ticker),
            automatic: request.source != StartSource::User,
            health,
            system_app,
        });
        Ok(())
    }

    /// The user stopped the recording: detection may not restart its
    /// calendar event for a while.
    pub fn stop(&self) {
        let event = self
            .active
            .lock()
            .as_ref()
            .and_then(|active| active.meeting.calendar_event_id.clone());
        if let Some(event) = event {
            *self.last_stopped_event.lock() = Some((event, Utc::now()));
        }
        self.finish(true);
    }

    /// The recording was started by the detector (or a calendar handoff).
    pub fn is_automatic(&self) -> bool {
        self.active.lock().as_ref().is_some_and(|a| a.automatic)
    }

    /// The detector's call ended on its own: stop the recording it started.
    /// A call that ended this way never starts the repeat cooldown.
    pub fn call_ended(&self) {
        let automatic = self.active.lock().as_ref().is_some_and(|a| a.automatic);
        if automatic {
            *self.last_stopped_event.lock() = None;
            self.finish(true);
        }
    }

    /// Back-to-back events in one call (`splitForCalendarHandoff`): the
    /// recording the detector started ends and the next event's begins.
    pub fn split_for_calendar_handoff(&self, next: RecordingStart) {
        let current = self
            .active
            .lock()
            .as_ref()
            .map(|active| (active.automatic, active.meeting.calendar_event_id.clone()));
        let Some((true, current_event)) = current else {
            return;
        };
        let next_event = next.calendar.as_ref().map(|e| e.external_id.as_str());
        if !calendar_policy::should_split_for_calendar_handoff(current_event.as_deref(), next_event)
        {
            return;
        }
        log::info!("calendar handoff: starting a new recording for the next event");
        self.finish(true);
        self.start(RecordingStart {
            source: StartSource::CalendarHandoff,
            ..next
        });
    }

    /// The folder of the meeting being recorded, if any.
    pub fn active_folder(&self) -> Option<std::path::PathBuf> {
        let active = self.active.lock();
        active
            .as_ref()
            .map(|active| self.shared.library.meeting_dir(&active.meeting))
    }

    /// On quit: saves what was recorded and leaves processing for the next
    /// launch. False while anything stopped could not be saved
    /// (`prepareForTermination`).
    pub fn prepare_for_quit(&self) -> bool {
        let retry: Vec<Uuid> = self.pending.lock().keys().copied().collect();
        self.finish(false);
        for id in retry {
            self.persist(id, true);
        }
        self.pending.lock().is_empty()
    }

    fn finish(&self, process_now: bool) {
        let Some(mut active) = self.active.lock().take() else {
            return;
        };
        active.ticker_stop.store(true, Ordering::Relaxed);
        if let Some(ticker) = active.ticker.take() {
            let _ = ticker.join();
        }
        self.shared.recording_active.store(false, Ordering::Relaxed);
        self.shared.background_conditions_changed();
        self.shared.capture_active.store(false, Ordering::Relaxed);
        *self.shared.recording_meeting.lock() = None;
        let mut meeting = active.meeting;
        let mut health = active.health;
        let stopped = active.recorder.stop();
        let write_failed = match &stopped {
            Ok(result) => result
                .warnings
                .iter()
                .any(|w| w.contains("could not finish")),
            Err(_) => true,
        };
        let mut warnings = match stopped {
            Ok(result) => {
                meeting.has_system_track = result.has_system_audio && result.system.is_some();
                meeting.recorded_duration = Some(result.mic_seconds.max(result.system_seconds));
                result.warnings
            }
            Err(err) => vec![format!("Saving the recording reported an error: {err:#}")],
        };
        health.finish(write_failed);
        let ended = lokalbot_core::time::now_seconds();
        meeting.ended_at = Some(ended);
        // The wall clock can outlast the audio: a device that dropped out
        // truncates the tracks while the session stays live.
        if let Some(recorded) = meeting.recorded_duration {
            let session = (ended - meeting.started_at).num_milliseconds() as f64 / 1000.0;
            if let Some(warning) = short_capture_warning(recorded, session) {
                warnings.insert(0, warning);
            }
        }
        self.finalize(meeting, process_now, warnings);
    }

    /// The part of stopping that can fail on a full or read-only disk, apart
    /// from the capture device. Says whether it was all saved (`finalize`).
    fn finalize(&self, meeting: Meeting, process_now: bool, warnings: Vec<String>) -> bool {
        let settings = self.shared.settings();
        let id = meeting.id;
        let library = &self.shared.library;
        self.pending.lock().insert(
            id,
            PendingFinalization {
                meeting: meeting.clone(),
                transcribe: settings.auto_transcribe,
                summarize: settings.auto_summarize,
                metadata_saved: false,
            },
        );
        let saved = self.persist(id, !process_now);
        let meeting = current_metadata(library, &meeting).unwrap_or(meeting);
        if let Err(err) = library.reindex_meeting(&meeting) {
            log::warn!("indexing the new meeting failed: {err:#}");
        }
        let notice = (saved && process_now).then(|| {
            let waiting = settings.auto_transcribe && !self.pipeline.transcription_ready();
            RecordingSaved {
                title: meeting.display_title(),
                duration_seconds: meeting.duration_seconds(),
                will_transcribe: settings.auto_transcribe && !waiting,
                waiting_for_models: waiting,
            }
        });
        self.shared
            .emit(EngineEvent::Recording(RecordingUpdate::Stopped {
                meeting_id: id,
                warnings,
                saved: notice,
            }));
        self.shared.emit(EngineEvent::LibraryChanged);
        saved
    }

    /// Saves one stopped recording's details, then its processing job. A step
    /// that fails stays pending and tells the person what to do
    /// (`persistFinalization`).
    fn persist(&self, id: Uuid, defer_processing: bool) -> bool {
        let mut pending = self.pending.lock();
        let Some(entry) = pending.get_mut(&id) else {
            return true;
        };
        let library = &self.shared.library;
        let folder = library.meeting_dir(&entry.meeting);
        // Deleted while its details couldn't be saved: nothing is left to keep
        // (`forgetFinalization`).
        if !folder.is_dir() {
            pending.remove(&id);
            return true;
        }
        if let Some(current) = current_metadata(library, &entry.meeting) {
            entry.meeting = merging_finalization(&entry.meeting, current);
        }
        if !entry.metadata_saved {
            if let Err(err) = library.save_meeting(&entry.meeting) {
                self.shared.error(lokalbot_i18n::format(
                    "Capture stopped and audio was retained, but meeting details could not be saved: {err}. Resolve the storage error, then retry quitting to save them.",
                    &[("err", format!("{err:#}"))],
                ));
                return false;
            }
            entry.metadata_saved = true;
        }
        if entry.transcribe {
            let queued = if defer_processing {
                self.pipeline
                    .defer_until_next_launch(id, entry.summarize)
                    .inspect_err(|err| log::warn!("could not queue {id}: {err:#}"))
                    .is_ok()
            } else {
                self.pipeline.enqueue(id, true, entry.summarize, false)
            };
            if !queued {
                self.shared.error(lokalbot_i18n::tr(
                    "Recording saved, but its processing job could not be saved. Resolve the storage error, then retry quitting to keep automatic processing queued.",
                ));
                return false;
            }
        }
        pending.remove(&id);
        true
    }
}

/// The meeting as it is on disk now, if it is still the same one. Its title and
/// boundaries may be newer than what the recording started with.
fn current_metadata(library: &Library, meeting: &Meeting) -> Option<Meeting> {
    let path = library
        .meeting_dir(meeting)
        .join(lokalbot_core::library::META_FILE);
    let mut current: Meeting = lokalbot_core::library::read_json(&path).ok().flatten()?;
    current.relative_path = meeting.relative_path.clone();
    (current.id == meeting.id).then_some(current)
}

/// The latest saved details win for anything the person can edit. Stopping only
/// fills in the capture facts an in-progress `meta.json` can't know yet
/// (`mergingFinalization`).
fn merging_finalization(finalized: &Meeting, current: Meeting) -> Meeting {
    let mut merged = current;
    if merged.ended_at.is_none() {
        merged.ended_at = finalized.ended_at;
        merged.has_system_track |= finalized.has_system_track;
        if merged.recorded_duration.is_none() {
            merged.recorded_duration = finalized.recorded_duration;
        }
        if merged.content_range.is_none()
            && merged.content_range_source != Some(lokalbot_core::ContentRangeSource::UserReviewed)
        {
            merged.content_range = finalized.content_range;
            merged.content_range_source = finalized.content_range_source;
        }
        if merged.capture_intent.is_none() {
            merged.capture_intent = finalized.capture_intent.clone();
        }
    }
    merged
}

/// Closes recordings a crash or power loss left open. Their `meta.json` has no
/// `endedAt`, so they would stay "recording" for good: processing skips live
/// meetings and the player refuses them. As the macOS app does when it loads
/// a library, each one ends at its audio's last write, or where its longest
/// track ends if that is later, once the WAV headers are repaired; then it is
/// queued the way a stopped recording is.
///
/// Call only while holding the library's single-instance lock and before the
/// engine starts, so a recording that is still running is never closed.
/// Returns the meetings it closed.
pub fn recover_unfinished_recordings(library: &Library, settings: &Settings) -> Vec<Uuid> {
    if library.is_read_only() {
        return Vec::new();
    }
    let meetings = match library.list_meetings() {
        Ok(meetings) => meetings,
        Err(err) => {
            log::warn!("could not look for unfinished recordings: {err:#}");
            return Vec::new();
        }
    };
    let mut recovered = Vec::new();
    for mut meeting in meetings.into_iter().filter(Meeting::is_live) {
        let audio = library.audio(&meeting);
        let mut last_write: Option<DateTime<Utc>> = None;
        let mut longest = 0.0f64;
        let mut system_seconds = 0.0f64;
        for (path, system) in [(audio.mic, false), (audio.system, true)] {
            let Some(path) = path else { continue };
            // Before the repair, which writes to the file.
            let Ok(modified) = std::fs::metadata(&path).and_then(|m| m.modified()) else {
                continue;
            };
            last_write = last_write.max(Some(DateTime::<Utc>::from(modified)));
            let wav = path
                .extension()
                .is_some_and(|e| e.eq_ignore_ascii_case("wav"));
            if wav && let Err(err) = lokalbot_audio::repair_wav(&path) {
                log::warn!("could not repair {}: {err}", path.display());
                continue;
            }
            let seconds = lokalbot_audio::duration_seconds(&path).unwrap_or(0.0);
            longest = longest.max(seconds);
            if system {
                system_seconds = seconds;
            }
        }
        let audio_end =
            meeting.started_at + chrono::Duration::milliseconds((longest * 1000.0).round() as i64);
        meeting.ended_at = Some(
            last_write
                .map_or(audio_end, |write| write.max(audio_end))
                .max(meeting.started_at),
        );
        meeting.has_system_track = system_seconds > 0.0;
        if longest > 0.0 {
            meeting.recorded_duration = Some(longest);
        }
        if let Err(err) = library.save_meeting(&meeting) {
            log::warn!(
                "could not close the unfinished recording {}: {err:#}",
                meeting.id
            );
            continue;
        }
        if let Err(err) = library.reindex_meeting(&meeting) {
            log::warn!("indexing the recovered recording failed: {err:#}");
        }
        log::info!(
            "closed recording {} that an earlier run left open ({longest:.1} s of audio)",
            meeting.id
        );
        if longest > 0.0
            && settings.auto_transcribe
            && let Err(err) = library.enqueue_job(meeting.id, true, settings.auto_summarize, false)
        {
            log::warn!("could not queue the recovered recording: {err:#}");
        }
        recovered.push(meeting.id);
    }
    recovered
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::LibraryPaths;

    #[test]
    fn a_recording_that_names_a_room_accepts_only_that_room() {
        let room = "https://meet.google.com/abc-defg-hij";
        assert!(accepts_call(None, Some(room)));
        assert!(accepts_call(Some(room), None));
        assert!(accepts_call(Some(room), Some(room)));
        assert!(accepts_call(
            Some("https://meet.google.com/abc-defg-hij?authuser=0"),
            Some(room)
        ));
        assert!(!accepts_call(
            Some("https://meet.google.com/xyz-xyzx-xyz"),
            Some(room)
        ));
        assert!(!accepts_call(Some("https://zoom.us/j/1"), Some(room)));
    }

    #[test]
    fn the_sound_target_is_the_top_process_of_the_call() {
        let target = audio_target(&lokalbot_platform::DetectedMeeting {
            app_name: "Teams".into(),
            process_name: "msedgewebview2.exe".into(),
            pid: 30,
            audio_pid: 10,
            meeting_url: None,
            title_hint: None,
        });
        assert_eq!(target.pid, 10);
        assert_eq!(target.app_name, "Teams");
    }

    /// A meeting whose recording stopped without `finish`: no `endedAt`, and
    /// WAV headers that still say the files are empty, as after a crash.
    fn crashed_recording(library: &Library, seconds: f64, system: bool) -> Meeting {
        let started = lokalbot_core::time::now_seconds() - chrono::Duration::seconds(600);
        let meeting = library
            .create_meeting("Manual recording", "Recording", started)
            .unwrap();
        let folder = library.meeting_dir(&meeting);
        let samples = vec![0.25f32; (seconds * 16_000.0) as usize];
        let mut tracks = vec![lokalbot_audio::MIC_FILE];
        if system {
            tracks.push(lokalbot_audio::SYSTEM_FILE);
        }
        for track in tracks {
            let path = folder.join(track);
            lokalbot_audio::write_wav_16k(&path, &samples).unwrap();
            // The writer had not updated the RIFF and data sizes yet.
            let mut bytes = std::fs::read(&path).unwrap();
            bytes[4..8].copy_from_slice(&36u32.to_le_bytes());
            bytes[40..44].copy_from_slice(&0u32.to_le_bytes());
            std::fs::write(&path, bytes).unwrap();
        }
        meeting
    }

    fn library() -> (tempfile::TempDir, Library) {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path())).unwrap();
        (dir, library)
    }

    /// A controller with no capture device, and everything it reported.
    struct Harness {
        _dir: tempfile::TempDir,
        recording: Recording,
        pipeline: Pipeline,
        shared: Arc<Shared>,
        events: Arc<Mutex<Vec<EngineEvent>>>,
    }

    impl Harness {
        fn new(settings: Settings) -> Self {
            let (dir, library) = library();
            let events = Arc::new(Mutex::new(Vec::new()));
            let log = events.clone();
            let shared = Shared::for_tests(library, settings, move |event| log.lock().push(event));
            let models = crate::models::Models::new(shared.clone());
            let pipeline = Pipeline::start(shared.clone(), models);
            // Started jobs aren't what these tests are about.
            pipeline.stop();
            let mut recording = Recording::new(shared.clone(), pipeline.clone());
            recording.free_bytes = |_| Some(50_000_000_000);
            Self {
                _dir: dir,
                recording,
                pipeline,
                shared,
                events,
            }
        }

        fn library(&self) -> &Library {
            &self.shared.library
        }

        /// A meeting as `finish` hands it over: stopped, audio on disk, details
        /// not saved yet.
        fn stopped_meeting(&self, seconds: f64) -> Meeting {
            let started = lokalbot_core::time::now_seconds() - chrono::Duration::seconds(600);
            let mut meeting = self
                .library()
                .create_meeting("Weekly sync", "Zoom", started)
                .unwrap();
            lokalbot_audio::write_wav_16k(
                &self
                    .library()
                    .meeting_dir(&meeting)
                    .join(lokalbot_audio::MIC_FILE),
                &vec![0.25f32; (seconds * 16_000.0) as usize],
            )
            .unwrap();
            meeting.ended_at = Some(lokalbot_core::time::now_seconds());
            meeting.recorded_duration = Some(seconds);
            meeting
        }

        fn stops(&self) -> Vec<(Vec<String>, Option<RecordingSaved>)> {
            self.events
                .lock()
                .iter()
                .filter_map(|event| match event {
                    EngineEvent::Recording(RecordingUpdate::Stopped {
                        warnings, saved, ..
                    }) => Some((warnings.clone(), saved.clone())),
                    _ => None,
                })
                .collect()
        }

        fn refusals(&self) -> Vec<String> {
            self.events
                .lock()
                .iter()
                .filter_map(|event| match event {
                    EngineEvent::Recording(RecordingUpdate::Failed { message }) => {
                        Some(message.clone())
                    }
                    _ => None,
                })
                .collect()
        }

        #[cfg(unix)]
        fn errors(&self) -> Vec<String> {
            self.events
                .lock()
                .iter()
                .filter_map(|event| match event {
                    EngineEvent::Message {
                        text,
                        is_error: true,
                    } => Some(text.clone()),
                    _ => None,
                })
                .collect()
        }
    }

    fn manual_start() -> RecordingStart {
        RecordingStart::default()
    }

    #[test]
    fn a_nearly_full_disk_refuses_the_recording_up_front() {
        let mut harness = Harness::new(Settings::default());
        harness.recording.free_bytes = |_| Some(250_000_000);
        harness.recording.start(manual_start());
        let refusals = harness.refusals();
        assert_eq!(refusals.len(), 1, "{refusals:?}");
        assert!(
            refusals[0].contains("1 GB") && refusals[0].contains("250 MB"),
            "{refusals:?}"
        );
        assert!(harness.library().list_meetings().unwrap().is_empty());
        assert!(!harness.shared.recording_active.load(Ordering::Relaxed));
    }

    #[test]
    fn a_disk_that_cannot_say_does_not_refuse() {
        assert_eq!(recording_advisory(None), None);
        assert_eq!(recording_advisory(Some(1_000_000_000)), None);
    }

    #[test]
    fn no_entry_point_starts_a_recording_during_dictation() {
        for (source, calendar) in [
            (StartSource::User, None),
            (StartSource::Detector, None),
            (StartSource::User, Some(calendar_event("standup"))),
        ] {
            let harness = Harness::new(Settings::default());
            *harness.shared.dictation_state.lock() = crate::dictation::State::Working;
            harness.recording.start(RecordingStart {
                source,
                calendar,
                ..Default::default()
            });
            assert_eq!(
                harness.refusals(),
                vec!["Finish or cancel dictation before starting a meeting recording.".to_string()]
            );
            assert!(harness.library().list_meetings().unwrap().is_empty());
        }
    }

    fn calendar_event(id: &str) -> CalendarEvent {
        let now = Utc::now();
        CalendarEvent {
            provider: "ical".into(),
            external_id: id.into(),
            title: "Standup".into(),
            start: now,
            end: now + chrono::Duration::minutes(30),
            meeting_url: None,
            source_calendar_title: None,
            participant_names: Vec::new(),
            participant_identities: Vec::new(),
            agenda: None,
        }
    }

    /// The Mac's quit: stopping leaves a finished meeting and a job for the
    /// next launch, with no notification and nothing processing now.
    #[test]
    fn quitting_saves_the_recording_and_defers_its_processing() {
        let harness = Harness::new(Settings {
            auto_transcribe: true,
            auto_summarize: true,
            ..Settings::default()
        });
        let meeting = harness.stopped_meeting(4.0);
        assert!(
            harness
                .recording
                .finalize(meeting.clone(), false, Vec::new())
        );
        assert!(harness.recording.prepare_for_quit());

        let saved = harness.library().meeting(meeting.id).unwrap().unwrap();
        assert!(!saved.is_live());
        assert_eq!(saved.recorded_duration, Some(4.0));
        let jobs = harness.library().pending_jobs().unwrap();
        assert_eq!(jobs.len(), 1);
        assert!(jobs[0].transcribe && jobs[0].summarize);
        assert!(!harness.pipeline.is_processing(meeting.id));
        assert_eq!(harness.stops(), vec![(Vec::new(), None)]);
    }

    /// A queued job a person asked for during the retry survives the deferral.
    #[test]
    fn a_durable_request_outranks_the_deferred_one() {
        let harness = Harness::new(Settings::default());
        let meeting = harness.stopped_meeting(4.0);
        harness
            .library()
            .enqueue_job(meeting.id, true, false, true)
            .unwrap();
        assert!(
            harness
                .recording
                .finalize(meeting.clone(), false, Vec::new())
        );
        let job = harness.library().job(meeting.id).unwrap().unwrap();
        assert!(!job.summarize && !job.summary_follows_setting);
    }

    /// Details that can't be saved keep the app open until a later quit can.
    #[cfg(unix)]
    #[test]
    fn quit_is_refused_until_the_details_are_saved() {
        use std::os::unix::fs::PermissionsExt as _;
        let harness = Harness::new(Settings::default());
        let meeting = harness.stopped_meeting(4.0);
        let folder = harness.library().meeting_dir(&meeting);
        let lock = |mode| {
            std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(mode)).unwrap()
        };
        lock(0o500);
        assert!(
            !harness
                .recording
                .finalize(meeting.clone(), false, Vec::new())
        );
        assert!(!harness.recording.prepare_for_quit());
        let errors = harness.errors();
        assert!(
            errors.iter().all(|e| e.contains("retry quitting")) && errors.len() == 2,
            "{errors:?}"
        );
        assert!(harness.library().pending_jobs().unwrap().is_empty());
        lock(0o700);

        assert!(harness.recording.prepare_for_quit());
        assert!(
            !harness
                .library()
                .meeting(meeting.id)
                .unwrap()
                .unwrap()
                .is_live()
        );
        assert_eq!(harness.library().pending_jobs().unwrap().len(), 1);
    }

    /// A meeting deleted while it was pending can't hold quitting up forever.
    #[test]
    fn a_deleted_meeting_no_longer_blocks_quitting() {
        let harness = Harness::new(Settings::default());
        let meeting = harness.stopped_meeting(4.0);
        harness.recording.pending.lock().insert(
            meeting.id,
            PendingFinalization {
                meeting: meeting.clone(),
                transcribe: true,
                summarize: true,
                metadata_saved: false,
            },
        );
        std::fs::remove_dir_all(harness.library().meeting_dir(&meeting)).unwrap();
        assert!(harness.recording.prepare_for_quit());
    }

    /// A title changed during the recording survives stopping.
    #[test]
    fn the_details_saved_during_a_recording_win() {
        let harness = Harness::new(Settings::default());
        let meeting = harness.stopped_meeting(4.0);
        let mut edited = meeting.clone();
        edited.ended_at = None;
        edited.recorded_duration = None;
        edited.title = "Renamed while recording".into();
        harness.library().save_meeting(&edited).unwrap();

        assert!(
            harness
                .recording
                .finalize(meeting.clone(), false, Vec::new())
        );

        let saved = harness.library().meeting(meeting.id).unwrap().unwrap();
        assert_eq!(saved.title, "Renamed while recording");
        assert_eq!(saved.ended_at, meeting.ended_at);
        assert_eq!(saved.recorded_duration, Some(4.0));
    }

    #[test]
    fn the_notification_says_transcribing_only_when_true() {
        // Automatic transcription off: nothing runs and nothing says it will.
        let harness = Harness::new(Settings {
            auto_transcribe: false,
            ..Settings::default()
        });
        let meeting = harness.stopped_meeting(125.0);
        assert!(harness.recording.finalize(meeting, true, Vec::new()));
        let (_, saved) = harness.stops().remove(0);
        let saved = saved.unwrap();
        assert!(!saved.will_transcribe && !saved.waiting_for_models);
        assert_eq!(saved.body(), "Weekly sync · 2 min");
        assert!(harness.library().pending_jobs().unwrap().is_empty());

        // On, with the speech model not downloaded: the job parks.
        let harness = Harness::new(Settings {
            auto_transcribe: true,
            ..Settings::default()
        });
        let meeting = harness.stopped_meeting(125.0);
        assert!(harness.recording.finalize(meeting, true, Vec::new()));
        let (_, saved) = harness.stops().remove(0);
        let saved = saved.unwrap();
        assert!(!saved.will_transcribe && saved.waiting_for_models);
        assert_eq!(
            saved.body(),
            "Weekly sync · 2 min · processes after models download"
        );
        assert_eq!(harness.library().pending_jobs().unwrap().len(), 1);
    }

    #[test]
    fn the_notification_says_transcribing_when_it_will() {
        let saved = RecordingSaved {
            title: "Weekly sync".into(),
            duration_seconds: 59.0,
            will_transcribe: true,
            waiting_for_models: false,
        };
        assert_eq!(saved.body(), "Weekly sync · 1 min · transcribing…");
    }

    #[test]
    fn a_session_with_much_less_audio_says_so() {
        assert_eq!(
            short_capture_warning(120.0, 3600.0).as_deref(),
            Some("Recording saved, but only 2 min of audio was captured from a 60 min session.")
        );
        assert_eq!(
            short_capture_warning(4500.0, 7200.0).as_deref(),
            Some(
                "Recording saved, but only 1 hr 15 min of audio was captured from a 120 min session."
            )
        );
        // Under a minute missing, or at least 80% captured: nothing to say.
        assert_eq!(short_capture_warning(30.0, 80.0), None);
        assert_eq!(short_capture_warning(3000.0, 3600.0), None);
        assert_eq!(short_capture_warning(3599.0, 3600.0), None);
    }

    #[test]
    fn a_library_recovered_on_this_platform_follows_automatic_transcription() {
        let (_dir, library) = library();
        let meeting = crashed_recording(&library, 2.5, false);
        let settings = Settings {
            auto_transcribe: false,
            auto_summarize: true,
            ..Settings::default()
        };
        assert_eq!(
            recover_unfinished_recordings(&library, &settings),
            vec![meeting.id]
        );
        assert!(library.pending_jobs().unwrap().is_empty());
    }

    /// The Mac's crash audio is closed like this app's own: no `endedAt`, an
    /// AAC that never finished and a tee with a data chunk of unknown size.
    #[test]
    fn closes_a_mac_recording_from_its_crash_audio() {
        let (_dir, library) = library();
        let started = lokalbot_core::time::now_seconds() - chrono::Duration::seconds(600);
        let meeting = library
            .create_meeting("Crashed on a Mac", "Zoom", started)
            .unwrap();
        let folder = library.meeting_dir(&meeting);
        std::fs::write(folder.join("mic.m4a"), b"\0\0\0\x10ftypM4A \0\0\0\0").unwrap();
        let samples = vec![0.25f32; 16_000 * 3];
        std::fs::write(folder.join("mic.live.caf"), growing_caf(&samples)).unwrap();
        let settings = Settings::default();

        assert_eq!(
            recover_unfinished_recordings(&library, &settings),
            vec![meeting.id]
        );

        let closed = library.meeting(meeting.id).unwrap().unwrap();
        assert!(!closed.is_live());
        assert!(!closed.has_system_track);
        assert!((closed.recorded_duration.unwrap() - 3.0).abs() < 0.01);
        let audio = library.audio(&closed);
        assert_eq!(audio.mic, Some(folder.join("mic.live.caf")));
        let decoded = lokalbot_audio::read_mono_16k(audio.mic.as_deref().unwrap()).unwrap();
        assert_eq!(decoded.len(), samples.len());
        assert!((decoded[100] - 0.25).abs() < 0.001);
    }

    /// What `AVAudioFile` leaves behind for the tee when the process dies.
    fn growing_caf(samples: &[f32]) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"caff");
        bytes.extend_from_slice(&1u16.to_be_bytes());
        bytes.extend_from_slice(&0u16.to_be_bytes());
        bytes.extend_from_slice(b"desc");
        bytes.extend_from_slice(&32i64.to_be_bytes());
        bytes.extend_from_slice(&16_000f64.to_be_bytes());
        bytes.extend_from_slice(b"lpcm");
        bytes.extend_from_slice(&3u32.to_be_bytes()); // float, little-endian
        bytes.extend_from_slice(&4u32.to_be_bytes());
        bytes.extend_from_slice(&1u32.to_be_bytes());
        bytes.extend_from_slice(&1u32.to_be_bytes());
        bytes.extend_from_slice(&32u32.to_be_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(-1i64).to_be_bytes());
        bytes.extend_from_slice(&0u32.to_be_bytes()); // edit count
        for sample in samples {
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        bytes
    }

    #[test]
    fn closes_a_recording_left_open_and_queues_it() {
        let (_dir, library) = library();
        let meeting = crashed_recording(&library, 2.5, true);
        let settings = Settings {
            auto_transcribe: true,
            auto_summarize: true,
            ..Settings::default()
        };

        assert_eq!(
            recover_unfinished_recordings(&library, &settings),
            vec![meeting.id]
        );

        let closed = library.meeting(meeting.id).unwrap().unwrap();
        assert!(!closed.is_live());
        // The files were written just now, long after the meeting started.
        let ended = closed.ended_at.unwrap();
        assert!(ended >= meeting.started_at + chrono::Duration::milliseconds(2_500));
        assert!(closed.has_system_track);
        assert_eq!(closed.recorded_duration, Some(2.5));
        let mic = library.meeting_dir(&meeting).join(lokalbot_audio::MIC_FILE);
        assert_eq!(lokalbot_audio::duration_seconds(&mic).unwrap(), 2.5);
        let jobs = library.pending_jobs().unwrap();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].meeting_id, meeting.id);
        assert!(jobs[0].transcribe && jobs[0].summarize);

        // Nothing is left to close the next time.
        assert!(recover_unfinished_recordings(&library, &settings).is_empty());
        assert_eq!(library.pending_jobs().unwrap().len(), 1);
    }

    #[test]
    fn a_recording_without_audio_is_closed_but_not_queued() {
        let (_dir, library) = library();
        let started = lokalbot_core::time::now_seconds() - chrono::Duration::seconds(60);
        let meeting = library
            .create_meeting("Manual recording", "Recording", started)
            .unwrap();
        let settings = Settings {
            auto_transcribe: true,
            ..Settings::default()
        };

        assert_eq!(
            recover_unfinished_recordings(&library, &settings),
            vec![meeting.id]
        );

        let closed = library.meeting(meeting.id).unwrap().unwrap();
        assert_eq!(closed.ended_at, Some(meeting.started_at));
        assert!(!closed.has_system_track);
        assert!(library.pending_jobs().unwrap().is_empty());
    }

    #[test]
    fn finished_meetings_are_left_alone() {
        let (_dir, library) = library();
        let mut meeting = crashed_recording(&library, 1.0, false);
        let ended = meeting.started_at + chrono::Duration::seconds(30);
        meeting.ended_at = Some(ended);
        library.save_meeting(&meeting).unwrap();

        assert!(recover_unfinished_recordings(&library, &Settings::default()).is_empty());
        assert_eq!(
            library.meeting(meeting.id).unwrap().unwrap().ended_at,
            Some(ended)
        );
    }
}
