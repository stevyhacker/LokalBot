//! Starting and stopping meeting recordings (`RecordingController.swift`).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

use anyhow::{Context as _, Result};
use parking_lot::Mutex;

use chrono::{DateTime, Utc};
use lokalbot_audio::{Recorder, RecorderOptions};
use lokalbot_core::calendar::{self as calendar_policy, CalendarEvent};
use lokalbot_core::{Library, Meeting, Settings};
use uuid::Uuid;

use crate::pipeline::Pipeline;
use crate::{EngineEvent, RecordingUpdate, Shared};

pub struct Recording {
    shared: Arc<Shared>,
    pipeline: Pipeline,
    active: Arc<Mutex<Option<Active>>>,
    /// The calendar event of the last recording the user stopped, and when,
    /// so detection cannot immediately restart a meeting they ended
    /// (`lastCalendarEventID`, `calendarRepeatCooldown`).
    last_stopped_event: Mutex<Option<(String, DateTime<Utc>)>>,
}

struct Active {
    meeting: Meeting,
    recorder: Recorder,
    ticker_stop: Arc<AtomicBool>,
    ticker: Option<JoinHandle<()>>,
    /// Started by the detector; its call's end may stop it.
    automatic: bool,
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
        }
    }

    pub fn start(&self, request: RecordingStart) {
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
        if let Err(err) = self.try_start(request) {
            log::error!("could not start recording: {err:#}");
            self.shared
                .emit(EngineEvent::Recording(RecordingUpdate::Failed {
                    message: format!("Recording could not start: {err:#}"),
                }));
        }
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
        let options = RecorderOptions {
            mic_device: Some(settings.microphone_device.clone()).filter(|d| !d.is_empty()),
            capture_system: settings.record_system_audio,
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
                        if let Some(active) = active.lock().as_ref() {
                            let levels = active.recorder.levels();
                            let status = active.recorder.status();
                            shared.emit(EngineEvent::Recording(RecordingUpdate::Levels {
                                mic: levels.mic,
                                system: levels.system,
                                mic_status: status.mic.label().to_string(),
                                system_status: status.system.label().to_string(),
                                elapsed_seconds: active.recorder.elapsed().as_secs_f64(),
                            }));
                        }
                        std::thread::sleep(Duration::from_millis(200));
                    }
                })?
        };
        self.shared.capture_active.store(true, Ordering::Relaxed);
        self.shared.recording_active.store(true, Ordering::Relaxed);
        self.shared
            .emit(EngineEvent::Recording(RecordingUpdate::Started {
                meeting: meeting.clone(),
                has_system_audio,
            }));
        self.shared.emit(EngineEvent::LibraryChanged);
        *self.active.lock() = Some(Active {
            meeting,
            recorder,
            ticker_stop,
            ticker: Some(ticker),
            automatic: request.source != StartSource::User,
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

    /// On quit: save what was recorded and leave processing for the next launch.
    pub fn stop_for_shutdown(&self) {
        self.finish(false);
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
        self.shared.capture_active.store(false, Ordering::Relaxed);
        let mut meeting = active.meeting;
        let library = &self.shared.library;
        let warnings = match active.recorder.stop() {
            Ok(result) => {
                meeting.has_system_track = result.has_system_audio && result.system.is_some();
                meeting.recorded_duration = Some(result.mic_seconds.max(result.system_seconds));
                result.warnings
            }
            Err(err) => vec![format!("Saving the recording reported an error: {err:#}")],
        };
        meeting.ended_at = Some(lokalbot_core::time::now_seconds());
        if let Err(err) = library.save_meeting(&meeting) {
            self.shared
                .error(format!("Could not save the recording details: {err:#}"));
        }
        if let Err(err) = library.reindex_meeting(&meeting) {
            log::warn!("indexing the new meeting failed: {err:#}");
        }
        self.shared
            .emit(EngineEvent::Recording(RecordingUpdate::Stopped {
                meeting_id: meeting.id,
                warnings,
            }));
        self.shared.emit(EngineEvent::LibraryChanged);
        let settings = self.shared.settings();
        if settings.auto_transcribe || settings.auto_summarize {
            if process_now {
                self.pipeline.enqueue(
                    meeting.id,
                    settings.auto_transcribe,
                    settings.auto_summarize,
                    false,
                );
            } else if let Err(err) = library.enqueue_job(
                meeting.id,
                settings.auto_transcribe,
                settings.auto_summarize,
                false,
            ) {
                log::warn!("could not queue the recording for the next launch: {err:#}");
            }
        }
    }
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
            && (settings.auto_transcribe || settings.auto_summarize)
            && let Err(err) = library.enqueue_job(
                meeting.id,
                settings.auto_transcribe,
                settings.auto_summarize,
                false,
            )
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
