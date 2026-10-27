//! Meeting detection and the recording mode it follows (`MeetingDetector.swift`):
//! record automatically, ask through a notification, or never auto-record.
//!
//! With calendar detection on, the active calendar event backs the call
//! ([`CalendarHint`]), titles the recording, and splits a recording the
//! detector started when back-to-back events hand over within one call.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crossbeam_channel::Sender;
use parking_lot::Mutex;

use lokalbot_core::calendar::{self as policy, CalendarEvent, SwitchAction};
use lokalbot_core::settings::AutoRecordMode;
use lokalbot_platform::{CalendarHint, DetectedMeeting, DetectorEvent, MeetingDetector};

use crate::{Command, EngineEvent, Shared};

const POLL_INTERVAL: Duration = Duration::from_secs(2);

pub struct Detector {
    stop: Arc<AtomicBool>,
}

impl Detector {
    pub fn start(
        shared: Arc<Shared>,
        commands: Sender<Command>,
        detector: Arc<Mutex<MeetingDetector>>,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        std::thread::Builder::new()
            .name("lokalbot-meeting-detector".into())
            .spawn(move || run(shared, commands, flag, detector))
            .expect("spawning the meeting detector");
        Self { stop }
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// The call the detector is following.
struct Call {
    meeting: DetectedMeeting,
    /// The calendar event the call is bound to (`activeCalendarEvent`).
    event_id: Option<String>,
    /// LokalBot started recording this call automatically.
    recording: bool,
}

fn run(
    shared: Arc<Shared>,
    commands: Sender<Command>,
    stop: Arc<AtomicBool>,
    detector: Arc<Mutex<MeetingDetector>>,
) {
    let mut call: Option<Call> = None;
    while !stop.load(Ordering::Relaxed) {
        std::thread::sleep(POLL_INTERVAL);
        let settings = shared.settings();
        let now = chrono::Utc::now();
        let event = shared.calendar.active_event(&settings, now);
        let events = {
            let mut detector = detector.lock();
            detector.set_stop_debounce(Duration::from_secs_f64(
                settings.stop_debounce_seconds.clamp(5.0, 120.0),
            ));
            detector.set_calendar(hint(&settings, event.as_ref()));
            detector.poll()
        };
        for detected in events {
            match detected {
                DetectorEvent::Started(meeting) => {
                    // Another app's call took over; the old one ended first.
                    call = Some(Call {
                        meeting: meeting.clone(),
                        event_id: event.as_ref().map(|e| e.external_id.clone()),
                        recording: false,
                    });
                    *shared.detected_call.lock() = Some(meeting.app_name.clone());
                    if shared.recording_active.load(Ordering::Relaxed) {
                        continue;
                    }
                    let title = title(&settings, &meeting, event.as_ref());
                    match settings.auto_record_mode {
                        AutoRecordMode::Automatic => {
                            if let Some(call) = &mut call {
                                call.recording = true;
                            }
                            let _ = commands.send(Command::StartDetectedRecording {
                                title,
                                app_name: meeting.app_name,
                                calendar: event.clone().map(Box::new),
                            });
                        }
                        AutoRecordMode::Ask => {
                            shared.emit(EngineEvent::MeetingDetected {
                                app_name: meeting.app_name,
                                title,
                            });
                        }
                        AutoRecordMode::Manual => {}
                    }
                }
                DetectorEvent::Ended(meeting) => {
                    if let Some(ended) = call.take_if(|c| c.meeting.pid == meeting.pid) {
                        *shared.detected_call.lock() = None;
                        if ended.recording {
                            let _ = commands.send(Command::CallEnded);
                        }
                    }
                }
            }
        }
        if let (Some(current), Some(next)) = (&mut call, &event) {
            hand_over(&shared, &commands, &settings, current, next);
        }
    }
}

/// Back-to-back events within one call: the recording the detector started
/// splits; with nothing recording (the user stopped the previous event), the
/// next event records in automatic mode.
fn hand_over(
    shared: &Shared,
    commands: &Sender<Command>,
    settings: &lokalbot_core::Settings,
    call: &mut Call,
    next: &CalendarEvent,
) {
    if !policy::should_split_for_calendar_handoff(
        call.event_id.as_deref(),
        Some(next.external_id.as_str()),
    ) {
        if call.event_id.is_none() {
            call.event_id = Some(next.external_id.clone());
        }
        return;
    }
    call.event_id = Some(next.external_id.clone());
    if settings.auto_record_mode != AutoRecordMode::Automatic {
        return;
    }
    let recording_active = shared.recording_active.load(Ordering::Relaxed);
    let owns_recording = call.recording && recording_active;
    match policy::switch_action(policy::CALENDAR_HANDOFF, owns_recording, recording_active) {
        SwitchAction::Split => {
            log::info!("calendar handoff: splitting the recording for the next event");
            let _ = commands.send(Command::SplitForCalendarHandoff {
                title: title(settings, &call.meeting, Some(next)),
                app_name: call.meeting.app_name.clone(),
                calendar: Box::new(next.clone()),
            });
        }
        SwitchAction::Start => {
            call.recording = true;
            let _ = commands.send(Command::StartDetectedRecording {
                title: title(settings, &call.meeting, Some(next)),
                app_name: call.meeting.app_name.clone(),
                calendar: Some(Box::new(next.clone())),
            });
        }
        SwitchAction::Ignore => {}
    }
}

/// The calendar title when titling is on, else the Meet tab's meeting name,
/// else "<App> meeting".
fn title(
    settings: &lokalbot_core::Settings,
    meeting: &DetectedMeeting,
    event: Option<&CalendarEvent>,
) -> String {
    let calendar_title = event.map(|e| e.title.as_str());
    if settings.use_calendar_titles && calendar_title.is_some_and(|t| !t.trim().is_empty()) {
        return policy::recording_title(calendar_title, true, Some(&meeting.app_name));
    }
    meeting
        .title_hint
        .clone()
        .unwrap_or_else(|| policy::recording_title(None, false, Some(&meeting.app_name)))
}

fn hint(settings: &lokalbot_core::Settings, event: Option<&CalendarEvent>) -> CalendarHint {
    if !settings.calendar_detection_enabled {
        return CalendarHint::default();
    }
    CalendarHint {
        active: event.is_some(),
        meeting_url: event.and_then(|e| e.meeting_url.clone()),
        require_for_browser: settings.require_calendar_for_browser,
        grace: event.map(|_| policy::CALENDAR_BACKED_GRACE),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn event(title: &str) -> CalendarEvent {
        CalendarEvent {
            provider: "ics".into(),
            external_id: format!("{title}#1"),
            title: title.into(),
            start: chrono::Utc.timestamp_opt(0, 0).unwrap(),
            end: chrono::Utc.timestamp_opt(3_600, 0).unwrap(),
            meeting_url: Some("https://zoom.us/j/1".into()),
            source_calendar_title: None,
            participant_names: Vec::new(),
            participant_identities: Vec::new(),
            agenda: None,
        }
    }

    fn meet(hint: Option<&str>) -> DetectedMeeting {
        DetectedMeeting {
            app_name: "Google Meet".into(),
            process_name: "chrome".into(),
            pid: 1,
            title_hint: hint.map(str::to_string),
        }
    }

    #[test]
    fn titles_prefer_the_calendar_then_the_tab_then_the_app() {
        let mut settings = lokalbot_core::Settings::default();
        let planning = event("Sprint planning");
        assert_eq!(
            title(&settings, &meet(Some("Weekly sync")), Some(&planning)),
            "Sprint planning"
        );
        settings.use_calendar_titles = false;
        assert_eq!(
            title(&settings, &meet(Some("Weekly sync")), Some(&planning)),
            "Weekly sync"
        );
        assert_eq!(title(&settings, &meet(None), None), "Google Meet meeting");
    }

    #[test]
    fn the_hint_is_empty_while_calendar_detection_is_off() {
        let mut settings = lokalbot_core::Settings {
            require_calendar_for_browser: true,
            ..Default::default()
        };
        let planning = event("Sprint planning");
        assert_eq!(hint(&settings, Some(&planning)), CalendarHint::default());
        settings.calendar_detection_enabled = true;
        let backed = hint(&settings, Some(&planning));
        assert!(backed.active && backed.require_for_browser);
        assert_eq!(backed.meeting_url.as_deref(), Some("https://zoom.us/j/1"));
        assert_eq!(backed.grace, Some(policy::CALENDAR_BACKED_GRACE));
        assert!(!hint(&settings, None).active);
    }
}
