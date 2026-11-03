//! Whose sound the "Them" track records (`SystemAudioRecorder.swift`,
//! `RecordingController.swift`): the meeting app's when it can be separated,
//! so other sounds stay out, otherwise everything the computer plays.
//!
//! Everything the meeting app plays is also in the whole output, so the whole
//! output is always the safe answer: a tap that can't open, or an app with no
//! open output stream, never costs the recording its other side.

use std::time::{Duration, Instant};

/// How long a meeting app may have no output stream before the whole output
/// is recorded instead. An app that closes its stream between sentences comes
/// back to its tap as soon as the stream reopens.
pub(crate) const NO_OUTPUT_GRACE: Duration = Duration::from_secs(10);
/// How long after a tap failed it isn't tried again.
pub(crate) const TAP_RETRY: Duration = Duration::from_secs(30);

/// The meeting app whose sound the "Them" track records.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppAudioTarget {
    /// The top process of the app. On Windows its whole process tree counts.
    pub pid: u32,
    /// Executable name as the OS reports it ("Zoom.exe", "chrome").
    pub process_name: String,
    /// What to call it ("Zoom", "Google Meet").
    pub app_name: String,
}

impl AppAudioTarget {
    /// The same app, even when it restarted under a new process.
    pub fn same_app(&self, other: &AppAudioTarget) -> bool {
        normalized(&self.process_name) == normalized(&other.process_name)
    }
}

/// The target a recording moves to when a call is detected
/// (`considerDetectedSource`): one with no target binds to the call, and one
/// bound to an app only follows that app's replacement process. It never moves
/// to another app's call.
pub fn next_target(
    current: Option<&AppAudioTarget>,
    detected: Option<&AppAudioTarget>,
) -> Option<AppAudioTarget> {
    let detected = detected?;
    match current {
        None => Some(detected.clone()),
        Some(current) if current != detected && current.same_app(detected) => {
            Some(detected.clone())
        }
        Some(_) => None,
    }
}

/// `ZOOM.exe` and `zoom` are one app.
pub(crate) fn normalized(name: &str) -> String {
    let lower = name.trim().to_lowercase();
    lower.strip_suffix(".exe").unwrap_or(&lower).to_string()
}

/// Process loopback exists from Windows 10 build 20348.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn build_has_process_loopback(build: u32) -> bool {
    build >= 20_348
}

/// What the capture records right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Scope {
    App,
    WholeOutput,
}

/// Chooses between the app's tap and the whole output, from what each poll
/// sees. Pure, so the fallback rules are testable without a sound server.
#[derive(Clone, Debug)]
pub(crate) struct ScopeChooser {
    /// There is an app to tap and this system can tap it.
    can_tap: bool,
    scope: Scope,
    last_output: Option<Instant>,
    retry_at: Option<Instant>,
}

impl ScopeChooser {
    pub fn new(can_tap: bool) -> Self {
        Self {
            can_tap,
            scope: Scope::WholeOutput,
            last_output: None,
            retry_at: None,
        }
    }

    /// `app_output` is whether the app has an open output stream, or `None`
    /// when that couldn't be read. An unreadable state changes nothing.
    pub fn observe(&mut self, app_output: Option<bool>, now: Instant) -> Scope {
        if !self.can_tap {
            self.scope = Scope::WholeOutput;
            return self.scope;
        }
        let retrying_later = self.retry_at.is_some_and(|at| now < at);
        match app_output {
            Some(true) => {
                self.last_output = Some(now);
                if !retrying_later {
                    self.scope = Scope::App;
                }
            }
            Some(false) => {
                let expired = self
                    .last_output
                    .is_none_or(|at| now.saturating_duration_since(at) >= NO_OUTPUT_GRACE);
                if expired {
                    self.scope = Scope::WholeOutput;
                }
            }
            None => {}
        }
        self.scope
    }

    /// A tap didn't open or broke: the whole output, and no retry for a while.
    pub fn tap_failed(&mut self, now: Instant) -> Scope {
        self.scope = Scope::WholeOutput;
        self.retry_at = Some(now + TAP_RETRY);
        self.scope
    }
}

/// One of the app's open output streams.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct AppStream {
    /// The sink input (Linux) or the emitting process (Windows).
    pub id: u32,
    /// The output device it plays on. A stream that moves is reopened.
    pub device: u32,
}

/// Mixes a tap's streams into one track. A stream that stops delivering (it
/// paused, or the app is about to close it) must not hold up the others, so
/// it counts as silence once it is `MAX_SKEW` frames behind.
#[derive(Debug, Default)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) struct StreamMixer {
    lanes: std::collections::BTreeMap<u32, std::collections::VecDeque<f32>>,
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
impl StreamMixer {
    /// 40 ms at 16 kHz.
    const MAX_SKEW: usize = 640;

    pub fn add(&mut self, lane: u32) {
        self.lanes.entry(lane).or_default();
    }

    pub fn remove(&mut self, lane: u32) {
        self.lanes.remove(&lane);
    }

    /// Takes one stream's samples and returns what is ready to write.
    pub fn push(&mut self, lane: u32, samples: &[f32]) -> Vec<f32> {
        self.lanes.entry(lane).or_default().extend(samples);
        let longest = self.lanes.values().map(|l| l.len()).max().unwrap_or(0);
        let shortest = self.lanes.values().map(|l| l.len()).min().unwrap_or(0);
        let ready = shortest.max(longest.saturating_sub(Self::MAX_SKEW));
        let mut mixed = vec![0.0_f32; ready];
        for queue in self.lanes.values_mut() {
            let count = ready.min(queue.len());
            for (out, sample) in mixed.iter_mut().zip(queue.drain(..count)) {
                *out += sample;
            }
        }
        for sample in &mut mixed {
            *sample = sample.clamp(-1.0, 1.0);
        }
        mixed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(pid: u32, name: &str) -> AppAudioTarget {
        AppAudioTarget {
            pid,
            process_name: name.into(),
            app_name: name.into(),
        }
    }

    #[test]
    fn a_recording_binds_once_and_only_follows_its_own_app() {
        let zoom = target(1, "Zoom.exe");
        assert_eq!(next_target(None, Some(&zoom)), Some(zoom.clone()));
        assert_eq!(next_target(None, None), None);
        assert_eq!(next_target(Some(&zoom), None), None, "the call ended");
        assert_eq!(next_target(Some(&zoom), Some(&zoom)), None);
        let restarted = target(2, "zoom.EXE");
        assert_eq!(
            next_target(Some(&zoom), Some(&restarted)),
            Some(restarted.clone())
        );
        let slack = target(3, "slack");
        assert_eq!(next_target(Some(&zoom), Some(&slack)), None);
    }

    #[test]
    fn process_loopback_needs_build_20348() {
        assert!(!build_has_process_loopback(19_045), "Windows 10 22H2");
        assert!(build_has_process_loopback(20_348));
        assert!(build_has_process_loopback(26_100));
    }

    #[test]
    fn without_a_tap_the_whole_output_is_recorded() {
        let now = Instant::now();
        let mut chooser = ScopeChooser::new(false);
        assert_eq!(chooser.observe(Some(true), now), Scope::WholeOutput);
        assert_eq!(chooser.observe(None, now), Scope::WholeOutput);
    }

    #[test]
    fn an_app_with_nothing_to_tap_starts_on_the_whole_output() {
        let now = Instant::now();
        let mut chooser = ScopeChooser::new(true);
        assert_eq!(chooser.observe(Some(false), now), Scope::WholeOutput);
        let later = now + Duration::from_secs(2);
        assert_eq!(chooser.observe(Some(true), later), Scope::App);
    }

    #[test]
    fn a_short_gap_stays_on_the_app_and_a_long_one_does_not() {
        let now = Instant::now();
        let mut chooser = ScopeChooser::new(true);
        assert_eq!(chooser.observe(Some(true), now), Scope::App);
        let during = now + NO_OUTPUT_GRACE - Duration::from_secs(1);
        assert_eq!(chooser.observe(Some(false), during), Scope::App);
        let after = now + NO_OUTPUT_GRACE;
        assert_eq!(chooser.observe(Some(false), after), Scope::WholeOutput);
        let back = after + Duration::from_secs(2);
        assert_eq!(chooser.observe(Some(true), back), Scope::App);
    }

    #[test]
    fn an_unreadable_state_changes_nothing() {
        let now = Instant::now();
        let mut chooser = ScopeChooser::new(true);
        assert_eq!(chooser.observe(None, now), Scope::WholeOutput);
        chooser.observe(Some(true), now);
        let later = now + NO_OUTPUT_GRACE * 3;
        assert_eq!(chooser.observe(None, later), Scope::App);
    }

    #[test]
    fn a_failed_tap_records_the_whole_output_until_its_retry() {
        let now = Instant::now();
        let mut chooser = ScopeChooser::new(true);
        chooser.observe(Some(true), now);
        assert_eq!(chooser.tap_failed(now), Scope::WholeOutput);
        let soon = now + TAP_RETRY - Duration::from_secs(1);
        assert_eq!(chooser.observe(Some(true), soon), Scope::WholeOutput);
        let later = now + TAP_RETRY;
        assert_eq!(chooser.observe(Some(true), later), Scope::App);
    }

    #[test]
    fn streams_mix_sample_by_sample() {
        let mut mixer = StreamMixer::default();
        mixer.add(1);
        mixer.add(2);
        assert!(mixer.push(1, &[0.25, 0.25]).is_empty(), "waits for lane 2");
        assert_eq!(mixer.push(2, &[0.5, 0.5, 0.5]), vec![0.75, 0.75]);
        assert_eq!(mixer.push(1, &[0.25]), vec![0.75]);
    }

    #[test]
    fn a_stream_that_stopped_counts_as_silence() {
        let mut mixer = StreamMixer::default();
        mixer.add(1);
        mixer.add(2);
        let long = vec![0.5; StreamMixer::MAX_SKEW + 10];
        let mixed = mixer.push(1, &long);
        assert_eq!(mixed, vec![0.5; 10]);
        mixer.remove(2);
        assert_eq!(mixer.push(1, &[]).len(), StreamMixer::MAX_SKEW);
    }

    #[test]
    fn mixing_never_clips_past_full_scale() {
        let mut mixer = StreamMixer::default();
        mixer.add(1);
        mixer.add(2);
        mixer.push(1, &[0.9]);
        assert_eq!(mixer.push(2, &[0.9]), vec![1.0]);
    }
}
