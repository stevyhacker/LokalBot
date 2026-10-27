//! Screen context (`ScreenshotService.swift`): when the user turns it on,
//! day memory also keeps the focused window's visible text and, in "Text +
//! visual context", an encrypted image of it.
//!
//! Captures follow interaction boundaries: app and window changes from the
//! day-memory sampler, a pause after typing or pointer input, a clipboard
//! change, an idle interval (Settings: "at least every N min"), and "Capture
//! Screen Now". Event triggers share a 20 s cooldown and unchanged screens
//! are skipped. Text comes from accessibility first, then on-device OCR when
//! it is thin; secrets are redacted before anything is stored, and a capture
//! with a redaction keeps no pixels. Nothing is captured while tracking is
//! off, day memory is paused, the session is locked, or LokalBot, an
//! excluded app or site, a private window or a password field is in front.
//!
//! Differences from macOS: "Text context" may read the window's pixels in
//! memory for OCR when accessibility has little text (the pixels are never
//! stored), because many Linux and Windows apps expose less through
//! accessibility; and private browser windows are skipped.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result};
use chrono::Utc;
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use parking_lot::Mutex;
use sha2::{Digest as _, Sha256};

use lokalbot_core::ScreenContextMode;
use lokalbot_core::screen::{self as store, IMAGE_KEY_BYTES, ScreenCapture};
use lokalbot_core::{ActivitySample, Settings};
use lokalbot_platform::screen::privacy::{self, Observation};
use lokalbot_platform::screen::{
    self as platform, AccessibleWindow, CapturedImage, FocusedWindow, Interaction,
    InteractionMonitor, TextRead, TextReader, WindowCapture,
};
use lokalbot_platform::{ActivitySource, SampleDisposition};

use crate::{EngineEvent, ScreenStatus, Shared};

/// Minimum time between event-driven captures (`ScreenCapturePolicy.eventCooldown`).
const EVENT_COOLDOWN: Duration = Duration::from_secs(20);
/// Inactivity after which nothing is captured.
const IDLE_LIMIT_SECONDS: f64 = 180.0;
/// The first capture after screen context turns on.
const FIRST_CAPTURE_DELAY: Duration = Duration::from_secs(20);
/// How often the idle-interval trigger is considered.
const INTERVAL_TICK: Duration = Duration::from_secs(60);
/// Longest side of a processed frame (`ScreenshotCaptureDimensions.maximumDimension`).
const MAX_DIMENSION: u32 = 1_500;
/// Most screen text kept per capture.
const MAX_TEXT_CHARS: usize = 36_000;
/// Accessibility reads are bounded like `ScreenAccessibilityReader`.
const READ_DEADLINE: Duration = Duration::from_millis(250);
/// A tab switch or page load can change the window during a read.
const SETTLE_DELAY: Duration = Duration::from_millis(750);
/// "Capture Screen Now" waits this long for a window other than LokalBot.
const MANUAL_WAIT: Duration = Duration::from_secs(10);
const JPEG_QUALITY: u8 = 80;

/// What caused a capture; the raw value is `screenshots.capture_trigger`
/// (`ScreenCaptureTrigger`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Trigger {
    AppSwitch,
    WindowChange,
    TypingPause,
    ClipboardChange,
    Interval,
    Manual,
}

impl Trigger {
    pub(crate) fn raw(self) -> &'static str {
        match self {
            Self::AppSwitch => "app_switch",
            Self::WindowChange => "window_change",
            Self::TypingPause => "typing_pause",
            Self::ClipboardChange => "clipboard_change",
            Self::Interval => "interval",
            Self::Manual => "manual",
        }
    }
}

/// Rate limiting (`ScreenCapturePolicy`): event triggers respect the
/// cooldown, the interval trigger waits for the idle window, manual always
/// wins. `last_check` is also set when a capture was skipped as unchanged or
/// private, so those do not retry on every event.
#[derive(Debug, Default)]
pub(crate) struct CapturePolicy {
    last_check: Option<Instant>,
}

impl CapturePolicy {
    pub(crate) fn should_capture(
        &self,
        trigger: Trigger,
        idle_interval: Duration,
        now: Instant,
    ) -> bool {
        let Some(last) = self.last_check else {
            return true;
        };
        let elapsed = now.saturating_duration_since(last);
        match trigger {
            Trigger::Manual => true,
            Trigger::Interval => elapsed >= idle_interval,
            _ => elapsed >= EVENT_COOLDOWN,
        }
    }

    pub(crate) fn note_check(&mut self, now: Instant) {
        self.last_check = Some(now);
    }
}

/// The idle interval from Settings, at least a minute.
fn idle_interval(settings: &Settings) -> Duration {
    Duration::from_secs_f64((settings.screenshot_interval_minutes * 60.0).max(60.0))
}

fn captures_text(settings: &Settings) -> bool {
    settings.tracking_enabled
        && settings.screen_context_capture_mode != ScreenContextMode::ActivityOnly
}

/// The settings a capture was started under (`ScreenshotCaptureConsent`).
/// Anything that changes them while a capture runs discards it.
#[derive(Clone, Debug, PartialEq)]
struct Consent {
    tracking: bool,
    mode: ScreenContextMode,
    excluded_apps: Vec<String>,
    excluded_domains: Vec<String>,
}

impl Consent {
    fn of(settings: &Settings) -> Self {
        Self {
            tracking: settings.tracking_enabled,
            mode: settings.screen_context_capture_mode,
            excluded_apps: settings.excluded_app_list(),
            excluded_domains: settings.excluded_domain_list(),
        }
    }

    fn permits(&self, current: &Consent, paused: bool) -> bool {
        self == current && self.tracking && self.mode != ScreenContextMode::ActivityOnly && !paused
    }
}

// --------------------------------------------------------------- processing

/// One frame to turn into stored context (`ScreenshotProcessingRequest`).
pub(crate) struct Request<'a> {
    pub image: &'a CapturedImage,
    pub trigger: Trigger,
    /// Visible accessibility text, already redacted.
    pub accessible_text: &'a str,
    /// Redactions made so far (text, title, address, document name).
    pub prior_redactions: usize,
    /// Whether this capture may keep pixels at all ("Text + visual context"
    /// with an image key).
    pub may_keep_pixels: bool,
}

#[derive(Debug, PartialEq)]
pub(crate) struct Processed {
    pub content_hash: [u8; 32],
    pub text: String,
    pub text_source: String,
    pub keep_pixels: bool,
    pub privacy_redactions: usize,
    pub used_ocr: bool,
    pub perceptual_hash: u64,
    /// The bounded frame, for encoding when `keep_pixels`.
    pub frame: CapturedImage,
}

#[derive(Debug, PartialEq)]
pub(crate) enum Outcome {
    Unchanged,
    Stored(Box<Processed>),
}

/// Hash, text-source choice, OCR and redaction in one order
/// (`ScreenshotProcessingWorker`). The content hash is compared with the
/// last frame that was stored, so an identical screen is skipped.
#[derive(Default)]
pub(crate) struct Processor {
    last_content_hash: Option<[u8; 32]>,
}

impl Processor {
    pub(crate) fn process(
        &mut self,
        request: &Request<'_>,
        recognize: &mut dyn FnMut(&CapturedImage) -> Option<String>,
    ) -> Outcome {
        let frame = request.image.bounded(MAX_DIMENSION);
        let content_hash = content_hash(&frame);
        if request.trigger != Trigger::Manual && Some(content_hash) == self.last_content_hash {
            return Outcome::Unchanged;
        }
        let (accessible, accessible_count) = redaction(request.accessible_text);
        let accessibility_redactions = request.prior_redactions + accessible_count;
        let rich = privacy::has_rich_accessible_text(&accessible);
        let (ocr, ocr_count, used_ocr) = if rich {
            (String::new(), 0, false)
        } else {
            match recognize(&frame) {
                Some(text) => {
                    let (text, count) = redaction(&text);
                    (text, count, true)
                }
                None => (String::new(), 0, false),
            }
        };
        let suffix = |redacted: bool| if redacted { "_redacted" } else { "" };
        let (text, text_source) = if rich {
            (
                accessible,
                format!("accessibility{}", suffix(accessibility_redactions > 0)),
            )
        } else if !accessible.is_empty() && !ocr.is_empty() {
            (
                format!("{accessible}\n{ocr}")
                    .chars()
                    .take(MAX_TEXT_CHARS)
                    .collect(),
                format!("hybrid{}", suffix(accessibility_redactions + ocr_count > 0)),
            )
        } else if !accessible.is_empty() {
            (
                accessible,
                format!("accessibility{}", suffix(accessibility_redactions > 0)),
            )
        } else {
            (ocr, format!("ocr{}", suffix(ocr_count > 0)))
        };
        let privacy_redactions = accessibility_redactions + ocr_count;
        // A detected credential keeps only its redacted text: dropping the
        // pixels is safer than guessing where on screen it was.
        let keep_pixels = request.may_keep_pixels && privacy_redactions == 0;
        Outcome::Stored(Box::new(Processed {
            content_hash,
            text,
            text_source,
            keep_pixels,
            privacy_redactions,
            used_ocr,
            perceptual_hash: store::perceptual_hash(&frame.rgba, frame.width, frame.height),
            frame,
        }))
    }

    /// Records a frame as stored once its rows commit.
    pub(crate) fn commit(&mut self, content_hash: [u8; 32]) {
        self.last_content_hash = Some(content_hash);
    }
}

fn redaction(text: &str) -> (String, usize) {
    lokalbot_ai::sanitize::redaction(text)
}

/// SHA-256 of the frame's size and pixels (`ScreenshotImageProcessing.contentHash`).
fn content_hash(frame: &CapturedImage) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(u64::from(frame.width).to_le_bytes());
    hasher.update(u64::from(frame.height).to_le_bytes());
    hasher.update(&frame.rgba);
    hasher.finalize().into()
}

/// A text-only capture's identity, so an unchanged window is not stored
/// again (`ScreenshotService.storeTextContext`).
fn text_fingerprint(app: &str, title: &str, text: &str) -> [u8; 32] {
    Sha256::digest(format!("{app}\u{1f}{title}\u{1f}{text}").as_bytes()).into()
}

fn encode_jpeg(frame: &CapturedImage) -> Result<Vec<u8>> {
    let rgb: Vec<u8> = frame
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|[r, g, b, _]| [*r, *g, *b])
        .collect();
    let mut out = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, JPEG_QUALITY)
        .encode(
            &rgb,
            frame.width,
            frame.height,
            image::ExtendedColorType::Rgb8,
        )
        .context("encoding the screen image")?;
    Ok(out)
}

// ------------------------------------------------------------------- worker

enum Message {
    Boundary { app_changed: bool },
    CaptureNow,
    Stop,
}

/// Handle to the capture worker.
pub(crate) struct ScreenContext {
    sender: Sender<Message>,
    receiver: Mutex<Option<Receiver<Message>>>,
    shared: Arc<Shared>,
}

impl ScreenContext {
    pub(crate) fn new(shared: Arc<Shared>) -> Self {
        let (sender, receiver) = unbounded();
        Self {
            sender,
            receiver: Mutex::new(Some(receiver)),
            shared,
        }
    }

    /// Called by the day-memory sampler when a new activity block begins.
    pub(crate) fn boundary_hook(&self) -> impl Fn(bool) + Send + 'static {
        let sender = self.sender.clone();
        move |app_changed| {
            let _ = sender.send(Message::Boundary { app_changed });
        }
    }

    /// Starts the worker; `paused` is day memory's pause switch.
    pub(crate) fn start(&self, paused: Arc<AtomicBool>) {
        let Some(receiver) = self.receiver.lock().take() else {
            return;
        };
        let shared = self.shared.clone();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-screen".into())
            .spawn(move || Worker::new(shared, paused).run(receiver));
        if let Err(err) = spawned {
            log::warn!("could not start screen context: {err}");
        }
    }

    pub(crate) fn capture_now(&self) {
        let _ = self.sender.send(Message::CaptureNow);
    }

    pub(crate) fn stop(&self) {
        let _ = self.sender.send(Message::Stop);
    }
}

/// Why a capture attempt kept nothing. `Note` also starts the cooldown.
enum Skip {
    Quiet(&'static str),
    Note(String),
}

/// What was stored, for the log and the status.
struct Stored {
    app: String,
    text_source: String,
    chars: usize,
    pixels: bool,
}

struct Devices {
    activity: Box<dyn ActivitySource>,
    capture: Box<dyn WindowCapture>,
    reader: Box<dyn TextReader>,
    monitor: InteractionMonitor,
}

struct Worker {
    shared: Arc<Shared>,
    paused: Arc<AtomicBool>,
    devices: Option<Devices>,
    ocr: Option<lokalbot_ai::ocr::OcrEngine>,
    processor: Processor,
    policy: CapturePolicy,
    last_text_fingerprint: Option<[u8; 32]>,
    image_key: Option<std::result::Result<[u8; IMAGE_KEY_BYTES], String>>,
    status: ScreenStatus,
    published: Option<ScreenStatus>,
    enabled_since: Option<Instant>,
    first_capture_done: bool,
    last_interval_tick: Instant,
    manual_until: Option<Instant>,
    last_probe: Option<Instant>,
}

impl Worker {
    fn new(shared: Arc<Shared>, paused: Arc<AtomicBool>) -> Self {
        Self {
            shared,
            paused,
            devices: None,
            ocr: None,
            processor: Processor::default(),
            policy: CapturePolicy::default(),
            last_text_fingerprint: None,
            image_key: None,
            status: ScreenStatus::default(),
            published: None,
            enabled_since: None,
            first_capture_done: false,
            last_interval_tick: Instant::now(),
            manual_until: None,
            last_probe: None,
        }
    }

    fn run(mut self, receiver: Receiver<Message>) {
        loop {
            let message = match receiver.recv_timeout(Duration::from_secs(1)) {
                Ok(Message::Stop) | Err(RecvTimeoutError::Disconnected) => break,
                Ok(message) => Some(message),
                Err(RecvTimeoutError::Timeout) => None,
            };
            if self.shared.is_shutting_down() {
                break;
            }
            let settings = self.shared.settings();
            self.refresh(&settings);
            match message {
                Some(Message::CaptureNow) => {
                    if captures_text(&settings) {
                        self.manual_until = Some(Instant::now() + MANUAL_WAIT);
                    } else {
                        self.shared.message(
                            "Screen context is off. Choose Text context or Text + visual context in Settings → Day Memory.",
                        );
                    }
                }
                Some(Message::Boundary { app_changed }) => self.attempt(
                    &settings,
                    if app_changed {
                        Trigger::AppSwitch
                    } else {
                        Trigger::WindowChange
                    },
                ),
                _ => {}
            }
            if !captures_text(&settings) {
                continue;
            }
            self.poll_manual(&settings);
            let interactions = self
                .devices
                .as_mut()
                .map(|devices| {
                    let idle = devices.activity.idle_seconds();
                    devices.monitor.poll(idle)
                })
                .unwrap_or_default();
            for interaction in interactions {
                self.attempt(
                    &settings,
                    match interaction {
                        Interaction::TypingPause => Trigger::TypingPause,
                        Interaction::ClipboardChange => Trigger::ClipboardChange,
                    },
                );
            }
            let now = Instant::now();
            if !self.first_capture_done
                && self
                    .enabled_since
                    .is_some_and(|since| now.duration_since(since) >= FIRST_CAPTURE_DELAY)
            {
                self.first_capture_done = true;
                self.attempt(&settings, Trigger::Interval);
            }
            if now.duration_since(self.last_interval_tick) >= INTERVAL_TICK {
                self.last_interval_tick = now;
                self.attempt(&settings, Trigger::Interval);
            }
        }
        log::debug!("screen context stopped");
    }

    /// Opens or releases the capture devices as screen context turns on or
    /// off, and publishes the status when it changes.
    fn refresh(&mut self, settings: &Settings) {
        let enabled = captures_text(settings);
        if enabled && self.devices.is_none() {
            let capture = platform::window_capture();
            let reader = platform::text_reader();
            log::info!(
                "screen context: {} capture, {} text",
                capture.name(),
                reader.name()
            );
            self.status.capture_limitation = capture.limitation();
            self.devices = Some(Devices {
                activity: lokalbot_platform::activity_source(),
                capture,
                reader,
                monitor: InteractionMonitor::new(),
            });
            self.enabled_since = Some(Instant::now());
            self.first_capture_done = false;
        } else if !enabled && self.devices.is_some() {
            self.devices = None;
            self.ocr = None;
            self.processor = Processor::default();
            self.last_text_fingerprint = None;
            self.manual_until = None;
            self.enabled_since = None;
        }
        // The model files and the backend's limits change rarely.
        if self
            .last_probe
            .is_none_or(|at| at.elapsed() >= Duration::from_secs(5))
        {
            self.last_probe = Some(Instant::now());
            if let Some(devices) = &self.devices {
                self.status.capture_limitation = devices.capture.limitation();
            }
            self.status.ocr_installed = lokalbot_ai::ocr::is_installed(self.shared.library.paths());
        }
        self.status.active = enabled && !self.paused.load(Ordering::Relaxed);
        self.status.waiting_for_window = self.manual_until.is_some();
        if self.published.as_ref() != Some(&self.status) {
            self.published = Some(self.status.clone());
            self.shared.emit(EngineEvent::Screen(self.status.clone()));
        }
    }

    /// A pending "Capture Screen Now" runs once a window other than
    /// LokalBot is in front, or gives up after [`MANUAL_WAIT`].
    fn poll_manual(&mut self, settings: &Settings) {
        let Some(until) = self.manual_until else {
            return;
        };
        let own_window_in_front = self
            .devices
            .as_mut()
            .and_then(|devices| devices.activity.sample().ok().flatten())
            .is_none_or(|sample| sample.app_id == lokalbot_platform::privacy::SELF_APP_ID);
        if own_window_in_front {
            if Instant::now() >= until {
                self.manual_until = None;
                self.shared
                    .message("Nothing was captured: no other window came to the front.");
            } else if !self.status.waiting_for_window {
                self.shared
                    .message("Switch to the window you want to capture. LokalBot captures it when it comes to the front.");
            }
            return;
        }
        self.manual_until = None;
        self.attempt(settings, Trigger::Manual);
    }

    fn attempt(&mut self, settings: &Settings, trigger: Trigger) {
        let started = Instant::now();
        let result = self.capture(settings, trigger);
        let manual = trigger == Trigger::Manual;
        match result {
            Ok(stored) => {
                log::info!(
                    "context ok: {} ({} chars, source: {}, app: {}, trigger: {}, {:.2}s)",
                    if stored.pixels {
                        "image + text"
                    } else {
                        "text only"
                    },
                    stored.chars,
                    stored.text_source,
                    stored.app,
                    trigger.raw(),
                    started.elapsed().as_secs_f64()
                );
                self.status.last_capture = Some(Utc::now());
                self.status.last_text_source = Some(stored.text_source);
                self.status.last_error = None;
                self.shared.emit(EngineEvent::LibraryChanged);
                if manual {
                    self.shared
                        .message(format!("Saved a screen moment from {}.", stored.app));
                }
            }
            Err(CaptureError::Skipped(skip)) => {
                let reason = match skip {
                    Skip::Quiet(reason) => reason.to_string(),
                    Skip::Note(reason) => {
                        self.policy.note_check(Instant::now());
                        reason
                    }
                };
                if trigger != Trigger::Interval || manual {
                    log::debug!("context skip ({}): {reason}", trigger.raw());
                }
                if manual {
                    self.shared
                        .message(format!("Nothing was captured: {reason}."));
                }
            }
            Err(CaptureError::Failed(err)) => {
                log::warn!("context FAILED ({}): {err:#}", trigger.raw());
                self.status.last_error = Some(format!("{err:#}"));
                if manual {
                    self.shared
                        .error(format!("The screen capture failed: {err:#}"));
                }
            }
        }
        self.refresh(settings);
    }

    /// `ScreenshotService.captureIfAppropriate`.
    fn capture(&mut self, settings: &Settings, trigger: Trigger) -> Result<Stored, CaptureError> {
        use CaptureError::Skipped;
        if !captures_text(settings) {
            return Err(Skipped(Skip::Quiet("screen context is off")));
        }
        if self.paused.load(Ordering::Relaxed) {
            return Err(Skipped(Skip::Quiet("day memory is paused")));
        }
        if trigger != Trigger::Manual {
            if self.shared.recording_active.load(Ordering::Relaxed) {
                return Err(Skipped(Skip::Quiet("a meeting is being recorded")));
            }
            if self.shared.capture_active.load(Ordering::Relaxed) {
                return Err(Skipped(Skip::Quiet("dictation has priority")));
            }
        }
        // X11 cannot leave the ghost-text window out of a screen grab (Windows
        // excludes it from capture), so no capture while a suggestion shows.
        if cfg!(target_os = "linux")
            && settings.cotyping_enabled
            && self.shared.autocomplete_visible.load(Ordering::Relaxed)
        {
            return Err(Skipped(Skip::Quiet(
                "an autocomplete suggestion is on screen",
            )));
        }
        let now = Instant::now();
        if !self
            .policy
            .should_capture(trigger, idle_interval(settings), now)
        {
            return Err(Skipped(Skip::Quiet("cooldown")));
        }
        let consent = Consent::of(settings);
        let devices = self
            .devices
            .as_mut()
            .ok_or(Skipped(Skip::Quiet("capture is not running")))?;
        if devices
            .activity
            .idle_seconds()
            .is_some_and(|idle| idle >= IDLE_LIMIT_SECONDS)
        {
            return Err(Skipped(Skip::Quiet("away from the computer")));
        }
        if platform::session_locked() {
            return Err(Skipped(Skip::Quiet("the session is locked")));
        }
        let sample = devices
            .activity
            .sample()
            .map_err(CaptureError::Failed)?
            .ok_or(Skipped(Skip::Quiet("no window is in front")))?;
        if sample.app_id == lokalbot_platform::privacy::SELF_APP_ID {
            return Err(Skipped(Skip::Quiet("LokalBot is in front")));
        }
        let kept = match lokalbot_platform::disposition(&sample, settings) {
            SampleDisposition::Keep(kept) => kept,
            SampleDisposition::Private => {
                return Err(Skipped(Skip::Quiet("the app or site is excluded")));
            }
            SampleDisposition::Skip => return Err(Skipped(Skip::Quiet("nothing to capture"))),
        };
        if lokalbot_platform::privacy::is_private_window(&sample.title) {
            return Err(Skipped(Skip::Quiet("private windows are not captured")));
        }
        let window = devices
            .capture
            .focused()
            .map_err(CaptureError::Failed)?
            .ok_or(Skipped(Skip::Note(
                "the window in front could not be found".into(),
            )))?;
        if window.pid == Some(std::process::id()) {
            return Err(Skipped(Skip::Quiet("LokalBot is in front")));
        }
        if !window.title.is_empty() && !sample.title.is_empty() && window.title != sample.title {
            return Err(Skipped(Skip::Note(
                "the window changed while it was read".into(),
            )));
        }

        let accessible = read_accessibility(devices.reader.as_mut(), &window, true)?;
        let observation = observation(&sample, &window, accessible.as_ref());
        if !privacy::permits_content(
            &observation,
            &consent.excluded_apps,
            &consent.excluded_domains,
            true,
        ) {
            return Err(Skipped(Skip::Note(
                "the window is excluded or shows a password field".into(),
            )));
        }
        let title = observation.window_title.clone().unwrap_or_default();
        if lokalbot_platform::privacy::is_private_window(&title) {
            return Err(Skipped(Skip::Quiet("private windows are not captured")));
        }

        let source_url =
            lokalbot_platform::privacy::sanitized_url(observation.source_url.as_deref());
        let (accessible_text, text_count) = redaction(
            accessible
                .as_ref()
                .map(|a| a.text.as_str())
                .unwrap_or_default(),
        );
        let (title, title_count) = redaction(&title);
        let (source_url, url_count) = redaction(source_url.as_deref().unwrap_or_default());
        let document = accessible
            .as_ref()
            .and_then(|a| privacy::sanitized_document_name(a.document_name.as_deref()));
        let (document, document_count) = redaction(document.as_deref().unwrap_or_default());
        let prior_redactions = text_count + title_count + url_count + document_count;
        let app = kept.app.clone();

        let visual = consent.mode == ScreenContextMode::TextAndVisual;
        let image_key = if visual && prior_redactions == 0 {
            self.image_key()
        } else {
            None
        };
        let ocr_available = !privacy::has_rich_accessible_text(&accessible_text)
            && lokalbot_ai::ocr::is_installed(self.shared.library.paths());
        let ts = Utc::now();
        let mut capture = ScreenCapture {
            ts,
            app: app.clone(),
            window_title: title.clone(),
            trigger: trigger.raw().into(),
            source_url,
            document_name: document,
            privacy_redactions: prior_redactions as i64,
            ..Default::default()
        };

        if image_key.is_none() && !ocr_available {
            // Accessibility text only (`storeTextContext`).
            let text: String = accessible_text.chars().take(MAX_TEXT_CHARS).collect();
            if text.trim().is_empty() {
                return Err(Skipped(Skip::Note("no readable text".into())));
            }
            let fingerprint = text_fingerprint(&app, &title, &text);
            if trigger != Trigger::Manual && Some(fingerprint) == self.last_text_fingerprint {
                return Err(Skipped(Skip::Note("unchanged text".into())));
            }
            if !consent.permits(
                &Consent::of(&self.shared.settings()),
                self.paused.load(Ordering::Relaxed),
            ) {
                return Err(Skipped(Skip::Quiet("settings changed during the capture")));
            }
            capture.text_source = (if prior_redactions > 0 {
                "accessibility_redacted"
            } else {
                "accessibility"
            })
            .into();
            capture.text = text;
            let chars = capture.text.chars().count();
            self.shared
                .library
                .insert_screen_capture(&capture)
                .map_err(CaptureError::Failed)?;
            self.last_text_fingerprint = Some(fingerprint);
            self.policy.note_check(now);
            return Ok(Stored {
                app,
                text_source: capture.text_source,
                chars,
                pixels: false,
            });
        }

        // Pixels are needed: for the image, or for OCR.
        let devices = self
            .devices
            .as_mut()
            .ok_or(Skipped(Skip::Quiet("capture is not running")))?;
        let image = devices
            .capture
            .capture(&window)
            .map_err(CaptureError::Failed)?;
        // The window, its address or its password-field state can change
        // while the pixels are read; any change discards them. The activity
        // sample is read again too: some backends (the portal) cannot name
        // the window they captured.
        let recheck = read_accessibility(devices.reader.as_mut(), &window, false)?;
        let same_app = devices
            .activity
            .sample()
            .ok()
            .flatten()
            .is_some_and(|after| after.app_id == sample.app_id && after.title == sample.title);
        if !same_app
            || !focus_still_matches(
                &window,
                accessible.as_ref(),
                recheck.as_ref(),
                devices.capture.as_mut(),
            )
        {
            return Err(Skipped(Skip::Note(
                "the window or its privacy state changed during the capture".into(),
            )));
        }
        let ocr = if ocr_available {
            load_ocr(&mut self.ocr, self.shared.library.paths())
        } else {
            None
        };
        let request = Request {
            image: &image,
            trigger,
            accessible_text: &accessible_text,
            prior_redactions,
            may_keep_pixels: image_key.is_some(),
        };
        let outcome = self.processor.process(&request, &mut |frame| {
            let engine = ocr?;
            match engine.recognize(&frame.rgba, frame.width, frame.height) {
                Ok(text) => Some(text),
                Err(err) => {
                    log::warn!("screen text recognition failed: {err:#}");
                    None
                }
            }
        });
        let Outcome::Stored(processed) = outcome else {
            return Err(Skipped(Skip::Note("unchanged screen".into())));
        };
        if processed.text.trim().is_empty() && !processed.keep_pixels {
            return Err(Skipped(Skip::Note("no readable text".into())));
        }
        if !consent.permits(
            &Consent::of(&self.shared.settings()),
            self.paused.load(Ordering::Relaxed),
        ) {
            return Err(Skipped(Skip::Quiet("settings changed during the capture")));
        }
        capture.text = processed.text.clone();
        capture.text_source = processed.text_source.clone();
        capture.privacy_redactions = processed.privacy_redactions as i64;
        capture.perceptual_hash = Some(processed.perceptual_hash);
        let mut file = None;
        if let (true, Some(key)) = (processed.keep_pixels, image_key) {
            let jpeg = encode_jpeg(&processed.frame).map_err(CaptureError::Failed)?;
            let sealed = store::seal_image(&key, &jpeg).map_err(CaptureError::Failed)?;
            let path = store::capture_file_path(
                self.shared.library.paths().root(),
                ts,
                uuid::Uuid::new_v4(),
            );
            lokalbot_core::library::write_atomic(&path, &sealed)
                .context("writing the screen image")
                .map_err(CaptureError::Failed)?;
            capture.path = path.to_string_lossy().into_owned();
            file = Some(path);
        }
        if let Err(err) = self.shared.library.insert_screen_capture(&capture) {
            // A file is not a capture until its rows commit.
            if let Some(path) = file
                && let Err(cleanup) = std::fs::remove_file(&path)
            {
                log::warn!("could not remove an unrecorded screen image: {cleanup}");
            }
            return Err(CaptureError::Failed(err));
        }
        self.processor.commit(processed.content_hash);
        self.policy.note_check(now);
        if processed.used_ocr {
            log::debug!(
                "screen text recognized ({} chars)",
                processed.text.chars().count()
            );
        }
        Ok(Stored {
            app,
            text_source: processed.text_source.clone(),
            chars: processed.text.chars().count(),
            pixels: file.is_some(),
        })
    }

    /// The image key, created on first use. Without a credential store no
    /// image is kept; that is reported once in the status.
    fn image_key(&mut self) -> Option<[u8; IMAGE_KEY_BYTES]> {
        if self.image_key.is_none() {
            let key = crate::secrets::screen_image_key(true).map_err(|err| format!("{err:#}"));
            if let Err(err) = &key {
                log::warn!("screen images are not kept: {err}");
            }
            self.status.images_unavailable = key.as_ref().err().map(|_| {
                "Screen images need the system credential store (the Secret Service on Linux), so only text is kept."
                    .to_string()
            });
            self.image_key = Some(key);
        }
        self.image_key
            .as_ref()
            .and_then(|key| key.as_ref().ok().copied())
    }
}

/// The OCR engine, loaded on first use and kept while screen context is on.
fn load_ocr<'a>(
    slot: &'a mut Option<lokalbot_ai::ocr::OcrEngine>,
    paths: &lokalbot_core::LibraryPaths,
) -> Option<&'a lokalbot_ai::ocr::OcrEngine> {
    if slot.is_none() {
        match lokalbot_ai::ocr::OcrEngine::load(paths) {
            Ok(engine) => *slot = Some(engine),
            Err(err) => {
                log::warn!("screen text recognition is unavailable: {err:#}");
                return None;
            }
        }
    }
    slot.as_ref()
}

enum CaptureError {
    Skipped(Skip),
    Failed(anyhow::Error),
}

/// Reads accessibility once, and once more after a moment when the window
/// was changing (`lastTextReadFailure(...).isTransient`). `None` when this
/// desktop or app offers no accessibility; a timeout fails closed.
fn read_accessibility(
    reader: &mut dyn TextReader,
    window: &FocusedWindow,
    include_text: bool,
) -> Result<Option<AccessibleWindow>, CaptureError> {
    let mut read = reader.read(window, include_text, READ_DEADLINE);
    if matches!(read, TextRead::Changed(_)) {
        std::thread::sleep(SETTLE_DELAY);
        read = reader.read(window, include_text, READ_DEADLINE);
    }
    match read {
        TextRead::Read(snapshot) => Ok(Some(snapshot)),
        TextRead::Unavailable(reason) => {
            log::debug!("accessibility unavailable: {reason}");
            Ok(None)
        }
        TextRead::Changed(reason) => Err(CaptureError::Skipped(Skip::Note(format!(
            "the window kept changing ({reason})"
        )))),
        TextRead::TimedOut => Err(CaptureError::Skipped(Skip::Note(
            "accessibility did not answer in time".into(),
        ))),
    }
}

/// What is known about the window for [`privacy::permits_content`]. Without
/// accessibility the focus is unknown and no password field is known to be
/// visible.
fn observation(
    sample: &ActivitySample,
    window: &FocusedWindow,
    accessible: Option<&AccessibleWindow>,
) -> Observation {
    let fallback_title = if window.title.is_empty() {
        sample.title.clone()
    } else {
        window.title.clone()
    };
    match accessible {
        Some(snapshot) => Observation {
            app_name: sample.app.clone(),
            app_id: sample.app_id.clone(),
            window_title: snapshot.window_title.clone().or(Some(fallback_title)),
            source_url: snapshot.source_url.clone().or(sample.url.clone()),
            focused_secure_field: snapshot.focused_secure_field,
            has_web_content: snapshot.has_web_content,
            contains_secure_field: snapshot.contains_secure_field,
            framed_urls: snapshot.framed_urls.clone(),
            has_unattributed_web_content: snapshot.has_unattributed_web_content,
        },
        None => Observation {
            app_name: sample.app.clone(),
            app_id: sample.app_id.clone(),
            window_title: Some(fallback_title),
            source_url: sample.url.clone(),
            ..Default::default()
        },
    }
}

/// `ScreenshotWindowFocusValidation.matches`: the same window is still in
/// front with the same title, address and password-field state.
fn focus_still_matches(
    window: &FocusedWindow,
    before: Option<&AccessibleWindow>,
    after: Option<&AccessibleWindow>,
    capture: &mut dyn WindowCapture,
) -> bool {
    let still_in_front = match capture.focused() {
        Ok(Some(current)) => {
            current.id == window.id && (window.title.is_empty() || current.title == window.title)
        }
        _ => false,
    };
    if !still_in_front {
        return false;
    }
    match (before, after) {
        (None, None) => true,
        (Some(before), Some(after)) => {
            privacy::focus_permits_capture(after.focused_secure_field, after.contains_secure_field)
                && after.window_title == before.window_title
                && after.source_url == before.source_url
                && after.has_web_content == before.has_web_content
                && after.contains_secure_field == before.contains_secure_field
                && privacy::settled_focus(before.focused_secure_field, after.focused_secure_field).0
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(value: u8) -> CapturedImage {
        CapturedImage {
            width: 4,
            height: 2,
            rgba: vec![value; 4 * 2 * 4],
        }
    }

    fn request<'a>(image: &'a CapturedImage, trigger: Trigger, text: &'a str) -> Request<'a> {
        Request {
            image,
            trigger,
            accessible_text: text,
            prior_redactions: 0,
            may_keep_pixels: true,
        }
    }

    #[test]
    fn policy_matches_the_mac() {
        let mut policy = CapturePolicy::default();
        let t0 = Instant::now();
        let idle = Duration::from_secs(180);
        assert!(
            policy.should_capture(Trigger::AppSwitch, idle, t0),
            "first check"
        );
        policy.note_check(t0);
        assert!(!policy.should_capture(Trigger::AppSwitch, idle, t0 + Duration::from_secs(5)));
        assert!(!policy.should_capture(Trigger::WindowChange, idle, t0 + Duration::from_secs(19)));
        assert!(policy.should_capture(Trigger::WindowChange, idle, t0 + Duration::from_secs(21)));
        assert!(policy.should_capture(Trigger::TypingPause, idle, t0 + Duration::from_secs(21)));
        assert!(!policy.should_capture(Trigger::Interval, idle, t0 + Duration::from_secs(60)));
        assert!(policy.should_capture(Trigger::Interval, idle, t0 + Duration::from_secs(181)));
        assert!(policy.should_capture(Trigger::Manual, idle, t0 + Duration::from_secs(1)));
    }

    #[test]
    fn idle_interval_is_at_least_a_minute() {
        let settings = Settings {
            screenshot_interval_minutes: 0.2,
            ..Settings::default()
        };
        assert_eq!(idle_interval(&settings), Duration::from_secs(60));
        let settings = Settings {
            screenshot_interval_minutes: 3.0,
            ..Settings::default()
        };
        assert_eq!(idle_interval(&settings), Duration::from_secs(180));
    }

    #[test]
    fn screen_context_needs_a_mode_and_tracking() {
        let mut settings = Settings::default();
        assert!(!captures_text(&settings), "off by default");
        settings.screen_context_capture_mode = ScreenContextMode::Text;
        assert!(captures_text(&settings));
        settings.tracking_enabled = false;
        assert!(!captures_text(&settings));
    }

    #[test]
    fn consent_changes_discard_a_capture() {
        let mut settings = Settings {
            screen_context_capture_mode: ScreenContextMode::TextAndVisual,
            ..Settings::default()
        };
        let consent = Consent::of(&settings);
        assert!(consent.permits(&Consent::of(&settings), false));
        assert!(!consent.permits(&Consent::of(&settings), true), "paused");
        settings.excluded_apps.push_str(", Firefox");
        assert!(!consent.permits(&Consent::of(&settings), false));
        let off = Settings::default();
        assert!(!Consent::of(&off).permits(&Consent::of(&off), false));
    }

    #[test]
    fn automatic_duplicates_are_skipped_but_manual_captures_are_kept() {
        let mut processor = Processor::default();
        let image = frame(40);
        let mut ocr = |_: &CapturedImage| Some("Quarterly report revenue grew".to_string());
        let Outcome::Stored(first) =
            processor.process(&request(&image, Trigger::AppSwitch, ""), &mut ocr)
        else {
            panic!("the first capture is stored");
        };
        assert_eq!(first.text, "Quarterly report revenue grew");
        assert_eq!(first.text_source, "ocr");
        assert!(first.keep_pixels && first.used_ocr);
        // Not committed (the rows failed): the same screen may retry.
        assert!(matches!(
            processor.process(&request(&image, Trigger::WindowChange, ""), &mut ocr),
            Outcome::Stored(_)
        ));
        processor.commit(first.content_hash);
        assert_eq!(
            processor.process(&request(&image, Trigger::WindowChange, ""), &mut ocr),
            Outcome::Unchanged
        );
        assert!(matches!(
            processor.process(&request(&image, Trigger::Manual, ""), &mut ocr),
            Outcome::Stored(_)
        ));
        assert!(matches!(
            processor.process(&request(&frame(41), Trigger::Interval, ""), &mut ocr),
            Outcome::Stored(_)
        ));
    }

    #[test]
    fn rich_accessibility_text_skips_ocr_and_secrets_drop_pixels() {
        let mut processor = Processor::default();
        let image = frame(10);
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz123456";
        let text = format!(
            "Deployment settings for the local desktop application. This paragraph is deliberately long enough to be useful without optical recognition. API key: {secret}"
        );
        let mut ocr = |_: &CapturedImage| -> Option<String> { panic!("rich text must avoid OCR") };
        let Outcome::Stored(stored) =
            processor.process(&request(&image, Trigger::TypingPause, &text), &mut ocr)
        else {
            panic!("the redacted text is kept");
        };
        assert!(!stored.keep_pixels);
        assert!(!stored.used_ocr);
        assert_eq!(stored.text_source, "accessibility_redacted");
        assert!(stored.privacy_redactions > 0);
        assert!(stored.text.contains("[REDACTED"));
        assert!(!stored.text.contains(secret));
    }

    #[test]
    fn thin_accessibility_text_is_combined_with_ocr() {
        let mut processor = Processor::default();
        let image = frame(90);
        let mut ocr = |_: &CapturedImage| Some("password: hunter2222".to_string());
        let Outcome::Stored(stored) =
            processor.process(&request(&image, Trigger::Interval, "Sign in"), &mut ocr)
        else {
            panic!("stored");
        };
        assert_eq!(stored.text, "Sign in\npassword: [REDACTED]");
        assert_eq!(stored.text_source, "hybrid_redacted");
        assert!(!stored.keep_pixels, "OCR found a credential");
        let Outcome::Stored(plain) = processor.process(
            &Request {
                prior_redactions: 0,
                may_keep_pixels: false,
                ..request(&frame(91), Trigger::Interval, "Inbox")
            },
            &mut |_| None,
        ) else {
            panic!("stored");
        };
        assert_eq!(plain.text_source, "accessibility");
        assert!(!plain.keep_pixels, "text context keeps no pixels");
    }

    #[test]
    fn frames_are_bounded_before_hashing_and_ocr() {
        let mut processor = Processor::default();
        let image = CapturedImage {
            width: 3_000,
            height: 1_500,
            rgba: vec![200; 3_000 * 1_500 * 4],
        };
        let mut seen = Vec::new();
        let mut ocr = |frame: &CapturedImage| {
            seen.push((frame.width, frame.height));
            Some("Text recovered from the bounded frame".to_string())
        };
        let Outcome::Stored(stored) =
            processor.process(&request(&image, Trigger::Manual, ""), &mut ocr)
        else {
            panic!("stored");
        };
        assert_eq!(seen, [(1_500, 750)]);
        assert_eq!((stored.frame.width, stored.frame.height), (1_500, 750));
        let jpeg = encode_jpeg(&stored.frame).unwrap();
        assert_eq!(&jpeg[..2], &[0xFF, 0xD8], "a JPEG");
    }

    #[test]
    fn fingerprints_follow_app_title_and_text() {
        let a = text_fingerprint("Files", "Home", "Documents");
        assert_eq!(a, text_fingerprint("Files", "Home", "Documents"));
        assert_ne!(a, text_fingerprint("Files", "Home", "Downloads"));
        assert_ne!(a, text_fingerprint("Files", "Desktop", "Documents"));
    }

    #[test]
    fn observations_without_accessibility_have_unknown_focus() {
        let sample = ActivitySample {
            at: Utc::now(),
            app: "Text Editor".into(),
            app_id: "gedit".into(),
            title: "notes.txt".into(),
            url: None,
            idle_seconds: 0.0,
        };
        let window = FocusedWindow::default();
        let observation = observation(&sample, &window, None);
        assert_eq!(observation.window_title.as_deref(), Some("notes.txt"));
        assert_eq!(observation.focused_secure_field, None);
        assert!(privacy::permits_content(&observation, &[], &[], true));
        let secure = AccessibleWindow {
            window_title: Some("Sign in".into()),
            focused_secure_field: Some(true),
            ..Default::default()
        };
        let observation = super::observation(&sample, &window, Some(&secure));
        assert!(!privacy::permits_content(&observation, &[], &[], true));
    }
}
