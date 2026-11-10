//! Live capture warnings and `recording-health.json`
//! (`RecordingController.updateCaptureWarnings`). The meeting view shows every
//! warning as it happens; the saved report is what its page warns from later.

use std::path::PathBuf;
use std::time::{Duration, Instant};

use lokalbot_audio::Recorder;
use lokalbot_core::library::write_json;
use lokalbot_core::meeting_review::{
    CaptureObservation, CaptureWarningNotifications, DISK_LOW_WARNING, DROPPED_BUFFERS_WARNING,
    HEALTH_NOT_SAVED_WARNING, RECORDING_FLOOR_BYTES, RecordingHealthReport, capture_warnings,
};

const CHECK_INTERVAL: Duration = Duration::from_secs(1);
const DISK_CHECK_INTERVAL: Duration = Duration::from_secs(15);
const REPORT_INTERVAL: Duration = Duration::from_secs(30);

pub(crate) struct CaptureMonitor {
    folder: PathBuf,
    root: PathBuf,
    system_requested: bool,
    started: Instant,
    report: RecordingHealthReport,
    notifications: CaptureWarningNotifications,
    last_check: Option<Instant>,
    last_disk_check: Option<Instant>,
    last_report: Option<Instant>,
    disk_low: bool,
    shown: Vec<String>,
}

impl CaptureMonitor {
    pub fn new(folder: PathBuf, root: PathBuf, system_requested: bool) -> Self {
        Self {
            folder,
            root,
            system_requested,
            started: Instant::now(),
            report: RecordingHealthReport::default(),
            notifications: CaptureWarningNotifications::default(),
            last_check: None,
            last_disk_check: None,
            last_report: None,
            disk_low: false,
            shown: Vec::new(),
        }
    }

    /// At most once a second: what to show and notify, when that changed.
    pub fn tick(&mut self, recorder: &Recorder) -> Option<(Vec<String>, Vec<String>)> {
        let now = Instant::now();
        if self
            .last_check
            .is_some_and(|last| now.duration_since(last) < CHECK_INTERVAL)
        {
            return None;
        }
        self.last_check = Some(now);
        let elapsed = now.duration_since(self.started).as_secs_f64();
        let health = recorder.capture_health();
        let mut messages = capture_warnings(&CaptureObservation {
            system_requested: self.system_requested,
            has_system_target: health.system_attached,
            microphone_age: health.mic_age,
            system_age: health.system_age,
            system_quiet_is_normal: health.system_quiet_is_normal,
            elapsed,
        });
        if !health.mic_attached {
            // The recording went on from system audio alone.
            messages.retain(|m| !m.starts_with("Microphone audio is not arriving"));
        }
        if elapsed >= 5.0 && !messages.is_empty() {
            self.report.had_missing_audio = Some(true);
        }
        if health.mic_write_error.is_some() || health.system_write_error.is_some() {
            self.report.had_write_failure = Some(true);
        }
        if RecordingHealthReport::drops_are_noticeable(health.mic_dropped, health.system_dropped) {
            messages.push(DROPPED_BUFFERS_WARNING.to_string());
        }
        for (source, error) in [
            ("Microphone", &health.mic_write_error),
            ("System audio", &health.system_write_error),
        ] {
            if let Some(error) = error {
                messages.push(format!("{source} saving needs attention: {error}"));
            }
        }
        if self
            .last_disk_check
            .is_none_or(|last| now.duration_since(last) >= DISK_CHECK_INTERVAL)
        {
            self.last_disk_check = Some(now);
            self.disk_low = lokalbot_platform::disk::available_bytes(&self.root)
                .is_some_and(|free| free < RECORDING_FLOOR_BYTES);
        }
        if self.disk_low {
            messages.push(DISK_LOW_WARNING.to_string());
        }
        self.report.microphone_dropped_buffers = health.mic_dropped;
        self.report.system_dropped_buffers = health.system_dropped;
        let changed = self.report.observe(&messages, elapsed);
        if !self.save_when_due(changed, now) {
            messages.push(HEALTH_NOT_SAVED_WARNING.to_string());
        }
        let notify = if elapsed >= 5.0 {
            self.notifications.due(&messages, elapsed)
        } else {
            Vec::new()
        };
        if messages == self.shown && notify.is_empty() {
            return None;
        }
        self.shown = messages.clone();
        Some((messages, notify))
    }

    /// Saves the report when it changed, and otherwise every `REPORT_INTERVAL`
    /// since the last save. False when a due save failed; the next check
    /// tries again.
    fn save_when_due(&mut self, changed: bool, now: Instant) -> bool {
        let due = changed
            || self
                .last_report
                .is_none_or(|last| now.duration_since(last) >= REPORT_INTERVAL);
        if !due {
            return true;
        }
        if !self.save() {
            return false;
        }
        self.last_report = Some(now);
        true
    }

    fn save(&self) -> bool {
        let path = self.folder.join(RecordingHealthReport::FILE_NAME);
        match write_json(&path, &self.report) {
            Ok(()) => true,
            Err(err) => {
                log::warn!("recording health not saved: {err:#}");
                false
            }
        }
    }

    /// The final report, read for the warning on the meeting's page.
    pub fn finish(&mut self, write_failed: bool) {
        if write_failed {
            self.report.had_write_failure = Some(true);
        }
        self.report.completed_at = Some(chrono::Utc::now());
        self.save();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unchanged_report_is_saved_again_every_interval() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join(RecordingHealthReport::FILE_NAME);
        let mut monitor =
            CaptureMonitor::new(dir.path().to_path_buf(), dir.path().to_path_buf(), false);
        let start = Instant::now();

        assert!(monitor.save_when_due(false, start), "the first check saves");
        assert!(file.exists());
        std::fs::remove_file(&file).unwrap();

        // Checks run once a second. They used to move the last-saved time
        // forward each time, so the interval never passed.
        for second in 1..REPORT_INTERVAL.as_secs() {
            assert!(monitor.save_when_due(false, start + Duration::from_secs(second)));
            assert!(!file.exists(), "saved early, after {second} s");
        }
        assert!(monitor.save_when_due(false, start + REPORT_INTERVAL));
        assert!(file.exists(), "saved once the interval has passed");

        std::fs::remove_file(&file).unwrap();
        assert!(monitor.save_when_due(true, start + REPORT_INTERVAL + Duration::from_secs(1)));
        assert!(file.exists(), "a change saves at once");
    }
}
