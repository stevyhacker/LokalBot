//! Dictation: capture while the shortcut is held, transcribe on this PC,
//! optionally clean up or compose with Think, then insert at the cursor
//! (`DictationCoordinator.swift`). Insertion is allowed only while the app and
//! field that had focus at the press still do; otherwise the text is copied.
//! The latest results are kept, sealed on disk, so one left on the clipboard
//! can be copied again (`DictationHistory`).

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use chrono::Utc;
use crossbeam_channel::{Receiver, bounded};
use parking_lot::Mutex;
use uuid::Uuid;

use lokalbot_ai::dictation::{
    ComposeProviders as _, DictationError, permissions_match, prepare_checked, requests_context,
};
use lokalbot_ai::dictation_preview::{self as preview, InsertionVerdict};
use lokalbot_audio::MicCapture;
use lokalbot_core::Settings;
use lokalbot_core::dictation_history::{self, DictationHistory, Outcome};
use lokalbot_core::settings::{DictationIntent, DictationOutputMode};
use lokalbot_platform::autocomplete::focused;
use lokalbot_platform::focus::{self, DeliveryCheck, DeliveryTarget, FocusRead};
use lokalbot_platform::insert::paste_checked;
use lokalbot_platform::{FrontApp, Frontmost, PasteOutcome};

use crate::dictation_context::{self as context, CapturedScreen, ContextTarget, LiveProviders};
use crate::models::Models;
use crate::{DictationCommand, DictationUpdate, EngineEvent, Shared, secrets};

/// A status-only preparation reaches the overlay once it outlasts this. A warm
/// model's check ends at once and must not flash the panel.
const PREPARATION_GRACE: Duration = Duration::from_millis(600);
/// How long the press's focus read may still be finishing when speech ends.
const PRESS_WAIT: Duration = Duration::from_secs(2);
const PREVIEW_FIRST_WAIT: Duration = Duration::from_millis(1_200);
const PREVIEW_POLL: Duration = Duration::from_millis(450);
const PREVIEW_MIN_SECONDS: f64 = 1.25;
/// `MicCapture` collects 16 kHz mono.
const SAMPLE_RATE: f64 = 16_000.0;
const READ_BACK_DEADLINE: Duration = Duration::from_millis(400);
/// Sound already on its way out when a player paused, before the mic opens.
const MEDIA_SETTLE: Duration = Duration::from_millis(250);
/// An earlier resume gets this long before a new dictation goes on without it.
const MEDIA_CLEANUP_WAIT: Duration = Duration::from_millis(1500);

pub struct Dictation {
    shared: Arc<Shared>,
    models: Models,
    state: Arc<Mutex<State>>,
    /// The resume of the last dictation's players, while it runs.
    media_cleanup: Mutex<Option<std::thread::JoinHandle<()>>>,
    recent: Arc<Recent>,
    /// Bumped by every start, finish and cancel, so a superseded run never
    /// delivers or writes state.
    session: Arc<AtomicU64>,
    /// Pasted text the field did not show, one click from being copied again.
    notice: Arc<Mutex<Option<String>>>,
}

#[derive(Default)]
pub(crate) enum State {
    #[default]
    Idle,
    Listening(Box<Listening>),
    Working,
    /// The speech model failed to load; the audio waits for Retry.
    NeedsRetry(Box<Job>),
}

impl State {
    /// A dictation is under way, from the microphone to the delivered text.
    pub(crate) fn is_busy(&self) -> bool {
        !matches!(self, State::Idle)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ToggleAction {
    Start,
    Finish,
    Cancel,
    Retry,
    Ignore,
}

/// The shortcut never cancels finished speech: a second press while the text
/// is being prepared must not delete the recording and the transcript. While
/// the speech model needs attention it retries instead. The menu and other
/// on-screen controls keep their explicit Cancel (`toggleAction`).
fn toggle_action(state: &State, from_shortcut: bool) -> ToggleAction {
    match state {
        State::Idle => ToggleAction::Start,
        State::Listening(_) => ToggleAction::Finish,
        State::Working | State::NeedsRetry(_) if !from_shortcut => ToggleAction::Cancel,
        State::NeedsRetry(_) => ToggleAction::Retry,
        State::Working => ToggleAction::Ignore,
    }
}

pub(crate) struct Listening {
    capture: MicCapture,
    /// Resumed when the capture ends, however it ends.
    media: lokalbot_platform::media::PausedMedia,
    started: Instant,
    ticker_stop: Arc<AtomicBool>,
    press: Press,
    settings: Settings,
    rehearsal: bool,
}

/// What is read at the press, off the engine thread: the app and field that
/// own the result, and the focused window's context when Compose may use it.
struct Press {
    focus: Receiver<PressedFocus>,
    screen: Option<Receiver<Option<CapturedScreen>>>,
    cancel_screen: Arc<AtomicBool>,
}

#[derive(Clone, Debug)]
struct PressedFocus {
    front: Option<Frontmost>,
    read: FocusRead,
}

impl PressedFocus {
    fn nothing_known() -> Self {
        Self {
            front: None,
            read: FocusRead::TimedOut,
        }
    }
}

impl Press {
    fn start(shared: &Arc<Shared>, settings: &Settings) -> Self {
        let wants_screen = settings.dictation_intent == DictationIntent::Compose
            && settings.dictation_use_screen_context;
        let (focus_tx, focus) = bounded(1);
        let (screen_tx, screen_rx) = bounded(1);
        let cancel_screen = Arc::new(AtomicBool::new(false));
        {
            let shared = shared.clone();
            let settings = settings.clone();
            let cancel = cancel_screen.clone();
            std::thread::spawn(move || {
                let pressed = PressedFocus {
                    front: focus::frontmost(focus::DELIVERY_DEADLINE),
                    read: focus::read_focus(focus::DELIVERY_DEADLINE),
                };
                let target = context_target(&pressed);
                let _ = focus_tx.send(pressed);
                let captured = wants_screen.then_some(target).flatten().and_then(|target| {
                    context::capture_screen(&target, &settings, shared.library.paths(), &cancel)
                });
                let _ = screen_tx.send(captured);
            });
        }
        Self {
            focus,
            screen: wants_screen.then_some(screen_rx),
            cancel_screen,
        }
    }

    fn cancel(&self) {
        self.cancel_screen.store(true, Ordering::Relaxed);
    }
}

fn context_target(pressed: &PressedFocus) -> Option<ContextTarget> {
    match &pressed.read {
        FocusRead::Snapshot(snapshot) => ContextTarget::of(snapshot),
        _ => None,
    }
}

/// Where a finished dictation may go, decided at the press.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Binding {
    Target(DeliveryTarget),
    /// Why paste mode has no target.
    Issue(DeliveryCheck),
    /// This desktop says nothing about focus: paste as asked, since refusing
    /// would make dictation copy-only on the whole desktop.
    Unknown,
}

impl Binding {
    fn of(read: &FocusRead) -> Self {
        match read {
            FocusRead::Unknown => Self::Unknown,
            FocusRead::Nothing | FocusRead::TimedOut => Self::Issue(DeliveryCheck::FieldUnreadable),
            FocusRead::Snapshot(snapshot) => match DeliveryTarget::captured(snapshot) {
                Some(target) => Self::Target(target),
                None => Self::Issue(DeliveryCheck::SecureField),
            },
        }
    }

    /// Reads the field again and judges it against the press.
    fn check(&self, read: impl FnOnce() -> FocusRead) -> DeliveryCheck {
        match self {
            Self::Issue(issue) => *issue,
            Self::Target(target) => match read() {
                FocusRead::Snapshot(snapshot) => target.check(&snapshot),
                _ => DeliveryCheck::FieldUnreadable,
            },
            Self::Unknown => match read() {
                FocusRead::Unknown => DeliveryCheck::Deliverable,
                FocusRead::Snapshot(snapshot) if snapshot.secure => DeliveryCheck::SecureField,
                FocusRead::Snapshot(_) => DeliveryCheck::Deliverable,
                _ => DeliveryCheck::FieldUnreadable,
            },
        }
    }
}

/// A running microphone that is not delivering audio. A Bluetooth headset
/// takes a moment to switch into headset mode (`idleMicrophoneStatus`).
fn idle_microphone_status(silent_for: Option<Duration>, elapsed: Duration) -> Option<&'static str> {
    const PATIENCE: Duration = Duration::from_secs(2);
    match silent_for {
        Some(silent) => (silent >= PATIENCE).then_some("No audio from the microphone"),
        None => (elapsed >= PATIENCE).then_some("Waiting for the microphone"),
    }
}

/// `DictationDeliveryCheck.clipboardMessage`.
fn clipboard_message(check: DeliveryCheck) -> &'static str {
    match check {
        DeliveryCheck::Deliverable => "Copied to the clipboard",
        DeliveryCheck::FocusMoved => {
            "Dictation finished after focus moved, so the text was copied to the clipboard instead of being inserted into another app."
        }
        DeliveryCheck::SelectionChanged => {
            "The selected text changed while you were dictating, so the text was copied to the clipboard instead of replacing it."
        }
        DeliveryCheck::SecureField => {
            "Dictation does not type into password fields, so the text was copied to the clipboard."
        }
        DeliveryCheck::FieldUnreadable => {
            "LokalBot could not confirm which field to paste into, so the text was copied to the clipboard."
        }
    }
}

/// One finished recording on its way to the app it was meant for.
pub(crate) struct Job {
    samples: Vec<f32>,
    settings: Settings,
    pressed: PressedFocus,
    screen: Option<Receiver<Option<CapturedScreen>>>,
    cancel_screen: Arc<AtomicBool>,
    rehearsal: bool,
}

impl Dictation {
    pub fn new(shared: Arc<Shared>, models: Models) -> Self {
        let shared_state = shared.dictation_state.clone();
        let recent = Arc::new(Recent {
            path: dictation_history::path(shared.library.paths().root()),
            history: Mutex::new(DictationHistory::default()),
            files: Mutex::new(()),
        });
        {
            // Off the engine thread: the credential store may ask to unlock.
            let recent = recent.clone();
            let shared = shared.clone();
            std::thread::spawn(move || recent.load(&shared));
        }
        Self {
            shared,
            models,
            state: shared_state,
            media_cleanup: Mutex::new(None),
            recent,
            session: Arc::new(AtomicU64::new(0)),
            notice: Arc::new(Mutex::new(None)),
        }
    }

    pub fn handle(&self, command: DictationCommand) {
        let (listening, retrying, idle) = {
            let state = self.state.lock();
            (
                matches!(*state, State::Listening(_)),
                matches!(*state, State::NeedsRetry(_)),
                matches!(*state, State::Idle),
            )
        };
        match command {
            DictationCommand::Start if !listening => self.start(false),
            DictationCommand::Stop if listening => self.finish(),
            DictationCommand::Toggle | DictationCommand::ToggleFromMenu => {
                let from_shortcut = command == DictationCommand::Toggle;
                let action = toggle_action(&self.state.lock(), from_shortcut);
                match action {
                    ToggleAction::Start => self.start(false),
                    ToggleAction::Finish => self.finish(),
                    ToggleAction::Cancel => self.cancel(),
                    ToggleAction::Retry => self.retry(),
                    ToggleAction::Ignore => {
                        log::info!("the dictation shortcut was ignored while working")
                    }
                }
            }
            // Trying it in Settings shows the result and never inserts.
            DictationCommand::ToggleRehearsal => {
                if listening {
                    self.finish()
                } else if idle {
                    self.start(true)
                } else {
                    self.cancel()
                }
            }
            // With nothing running, the overlay's X just closes its notice.
            DictationCommand::Cancel => {
                if idle {
                    *self.notice.lock() = None;
                    self.shared
                        .emit(EngineEvent::Dictation(DictationUpdate::Cancelled));
                } else {
                    self.cancel()
                }
            }
            DictationCommand::RetryPreparation if retrying => self.retry(),
            DictationCommand::CopyRecent(id) => {
                let (recent, shared) = (self.recent.clone(), self.shared.clone());
                std::thread::spawn(move || recent.copy(id, &shared));
            }
            DictationCommand::ClearRecent => self.recent.clear(&self.shared),
            DictationCommand::CopyNotice => {
                let text = self.notice.lock().clone();
                if let Some(text) = text
                    && lokalbot_platform::copy_to_clipboard(&text).is_ok()
                {
                    self.shared
                        .emit(EngineEvent::Dictation(DictationUpdate::DeliveryNotice {
                            copied: true,
                        }));
                }
            }
            DictationCommand::DismissNotice => {
                *self.notice.lock() = None;
                self.shared
                    .emit(EngineEvent::Dictation(DictationUpdate::Cancelled));
            }
            _ => {}
        }
    }

    fn start(&self, rehearsal: bool) {
        if !matches!(*self.state.lock(), State::Idle) {
            return;
        }
        if self.shared.recording_active.load(Ordering::Relaxed) {
            self.shared.error(lokalbot_i18n::tr(
                "Stop the current meeting recording before starting dictation.",
            ));
            return;
        }
        // A newer dictation ends any read-back and notice from the last one.
        let session = self.session.fetch_add(1, Ordering::SeqCst) + 1;
        *self.notice.lock() = None;
        self.shared
            .emit(EngineEvent::Dictation(DictationUpdate::Starting));
        // The settings at the press decide this recording.
        let settings = self.shared.settings();
        // The focus read starts at the shortcut, alongside the microphone: a
        // read during recording would bind whichever app had focus by then.
        let press = Press::start(&self.shared, &settings);
        // An earlier cancel may still be restoring the players it paused. Wait,
        // or its late resume could interrupt this capture. Then pause what is
        // playing now and give the sound a moment to stop.
        self.finish_media_cleanup();
        let media = lokalbot_platform::media::pause_playing();
        if !media.is_empty() {
            std::thread::sleep(MEDIA_SETTLE);
        }
        let device = Some(settings.dictation_microphone_id.clone()).filter(|d| !d.is_empty());
        let capture = match MicCapture::start(device.as_deref()) {
            Ok(capture) => capture,
            Err(err) => {
                press.cancel();
                self.resume_media(media);
                self.shared
                    .emit(EngineEvent::Dictation(DictationUpdate::Failed {
                        message: format!("The microphone could not start: {err:#}"),
                    }));
                return;
            }
        };
        self.shared.capture_active.store(true, Ordering::Relaxed);
        // The model is ready when the person finishes speaking, not after: one
        // that is missing downloads now, and the speech waits in memory.
        let requirements = self.models.dictation_requirements();
        {
            let shared = self.shared.clone();
            let models = self.models.clone();
            let requirements = requirements.clone();
            let model = settings.transcription_model.clone();
            std::thread::spawn(move || {
                let prepared = models
                    .ensure_installed(&requirements)
                    .and_then(|()| shared.speech.with(&shared, &model, |_| Ok(())));
                if let Err(err) = prepared {
                    log::warn!("the dictation model is not ready yet: {err:#}");
                    if !models.missing(&requirements).is_empty() {
                        shared.error(lokalbot_i18n::tr(
                            "Could not prepare the dictation model. It will retry when recording ends.",
                        ));
                    }
                }
            });
        }
        let ticker_stop = Arc::new(AtomicBool::new(false));
        let preview_text = Arc::new(Mutex::new(String::new()));
        *self.state.lock() = State::Listening(Box::new(Listening {
            capture,
            media,
            started: Instant::now(),
            ticker_stop: ticker_stop.clone(),
            press,
            settings,
            rehearsal,
        }));
        {
            let state = self.state.clone();
            let shared = self.shared.clone();
            let stop = ticker_stop.clone();
            let text = preview_text.clone();
            let models = self.models.clone();
            std::thread::spawn(move || {
                let mut announced = false;
                while !stop.load(Ordering::Relaxed) {
                    if let State::Listening(listening) = &*state.lock() {
                        let live = listening.capture.has_audio();
                        // The cue plays only once audio arrives: pressing the
                        // shortcut does not mean the microphone is listening.
                        if live && !announced {
                            announced = true;
                            if shared.settings().dictation_plays_start_sound {
                                lokalbot_audio::cue::play_start();
                            }
                        }
                        // Only real download progress shows while recording,
                        // so a warm model never flashes the panel
                        // (`shouldShowModelPreparation`).
                        let update = match models.download_progress(&requirements) {
                            Some(progress) => DictationUpdate::Preparing { progress },
                            None => DictationUpdate::Listening {
                                level: listening.capture.level(),
                                elapsed_seconds: listening.started.elapsed().as_secs_f64(),
                                preview: text.lock().clone(),
                                microphone_live: live,
                                capture_status: idle_microphone_status(
                                    listening.capture.silent_for(),
                                    listening.started.elapsed(),
                                )
                                .map_or_else(String::new, |status| {
                                    lokalbot_i18n::tr(status).to_string()
                                }),
                            },
                        };
                        shared.emit(EngineEvent::Dictation(update));
                    }
                    std::thread::sleep(Duration::from_millis(80));
                }
            });
        }
        {
            let state = self.state.clone();
            let shared = self.shared.clone();
            let sessions = self.session.clone();
            std::thread::spawn(move || {
                run_preview(
                    &state,
                    &shared,
                    &sessions,
                    session,
                    &ticker_stop,
                    &preview_text,
                );
            });
        }
    }

    /// Ends the dictation at any stage. A result still being prepared is
    /// dropped when it comes back.
    fn cancel(&self) {
        self.session.fetch_add(1, Ordering::SeqCst);
        let previous = std::mem::replace(&mut *self.state.lock(), State::Idle);
        match previous {
            State::Listening(listening) => {
                let Listening {
                    capture,
                    media,
                    ticker_stop,
                    press,
                    ..
                } = *listening;
                ticker_stop.store(true, Ordering::Relaxed);
                press.cancel();
                drop(capture.stop());
                self.resume_media(media);
            }
            State::NeedsRetry(job) => job.cancel_screen.store(true, Ordering::Relaxed),
            State::Idle | State::Working => {}
        }
        self.shared.capture_active.store(
            self.shared.recording_active.load(Ordering::Relaxed),
            Ordering::Relaxed,
        );
        self.shared
            .emit(EngineEvent::Dictation(DictationUpdate::Cancelled));
    }

    fn finish(&self) {
        let previous = std::mem::replace(&mut *self.state.lock(), State::Working);
        let State::Listening(listening) = previous else {
            *self.state.lock() = State::Idle;
            return;
        };
        // Cleared again by `Runner::run`, however that run ends.
        self.shared.dictation_working.store(true, Ordering::Relaxed);
        let Listening {
            capture,
            media,
            ticker_stop,
            press,
            settings,
            rehearsal,
            ..
        } = *listening;
        ticker_stop.store(true, Ordering::Relaxed);
        let samples = capture.stop();
        self.resume_media(media);
        self.shared.capture_active.store(
            self.shared.recording_active.load(Ordering::Relaxed),
            Ordering::Relaxed,
        );
        self.shared
            .emit(EngineEvent::Dictation(DictationUpdate::Transcribing));
        let session = self.session.fetch_add(1, Ordering::SeqCst) + 1;
        let runner = self.runner();
        std::thread::spawn(move || {
            let pressed = press
                .focus
                .recv_timeout(PRESS_WAIT)
                .unwrap_or_else(|_| PressedFocus::nothing_known());
            if runner.shared.settings().dictation_retain_audio {
                keep_audio(&runner.shared, &samples);
            }
            runner.run(
                Job {
                    samples,
                    settings,
                    pressed,
                    screen: press.screen,
                    cancel_screen: press.cancel_screen,
                    rehearsal,
                },
                session,
            );
        });
    }

    /// Resumes players off the engine thread, as soon as the capture is over.
    fn resume_media(&self, media: lokalbot_platform::media::PausedMedia) {
        if media.is_empty() {
            return;
        }
        self.finish_media_cleanup();
        *self.media_cleanup.lock() = Some(std::thread::spawn(move || {
            lokalbot_platform::media::resume(media);
        }));
    }

    /// Waits a bounded time for an earlier resume to finish.
    fn finish_media_cleanup(&self) {
        let Some(cleanup) = self.media_cleanup.lock().take() else {
            return;
        };
        let deadline = Instant::now() + MEDIA_CLEANUP_WAIT;
        while !cleanup.is_finished() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn retry(&self) {
        let previous = std::mem::replace(&mut *self.state.lock(), State::Working);
        let State::NeedsRetry(job) = previous else {
            *self.state.lock() = previous;
            return;
        };
        self.shared.dictation_working.store(true, Ordering::Relaxed);
        self.shared
            .emit(EngineEvent::Dictation(DictationUpdate::Transcribing));
        let session = self.session.fetch_add(1, Ordering::SeqCst) + 1;
        let runner = self.runner();
        std::thread::spawn(move || runner.run(*job, session));
    }

    fn runner(&self) -> Runner {
        Runner {
            shared: self.shared.clone(),
            models: self.models.clone(),
            state: self.state.clone(),
            sessions: self.session.clone(),
            recent: self.recent.clone(),
            notice: self.notice.clone(),
        }
    }
}

/// Keep dictation audio files: `<library>/dictations`, as on macOS, as WAV.
fn keep_audio(shared: &Shared, samples: &[f32]) {
    if samples.is_empty() {
        return;
    }
    let folder = shared.library.paths().root().join("dictations");
    let path = folder.join(format!(
        "dictation-{}-{}.wav",
        Utc::now().timestamp(),
        Uuid::new_v4()
    ));
    let written = std::fs::create_dir_all(&folder)
        .and_then(|()| lokalbot_audio::write_wav_16k(&path, samples));
    if let Err(err) = written {
        log::warn!("the dictation audio was not kept: {err}");
    }
}

/// Clears `Shared::dictation_working` when dropped.
struct StillWorking(Arc<Shared>);

impl Drop for StillWorking {
    fn drop(&mut self) {
        self.0.dictation_working.store(false, Ordering::Relaxed);
    }
}

/// What a recording needs on its way to the end.
struct Runner {
    shared: Arc<Shared>,
    models: Models,
    state: Arc<Mutex<State>>,
    sessions: Arc<AtomicU64>,
    recent: Arc<Recent>,
    notice: Arc<Mutex<Option<String>>>,
}

impl Runner {
    fn is_current(&self, session: u64) -> bool {
        self.sessions.load(Ordering::SeqCst) == session
    }

    /// Runs one recording to the end, unless it was cancelled meanwhile.
    fn run(self, job: Job, session: u64) {
        // Day digests and overnight reviews wait while this is set, so every
        // way out clears it: a cancel or a failed load before the text too.
        let working = StillWorking(self.shared.clone());
        if let Err(err) = self.prepare_model(&job.settings, session) {
            if !self.is_current(session) {
                return;
            }
            log::warn!("the dictation model did not load: {err:#}");
            // The audio stays in memory for Retry; nothing is lost.
            *self.state.lock() = State::NeedsRetry(Box::new(job));
            self.shared
                .emit(EngineEvent::Dictation(DictationUpdate::PreparationFailed {
                    message: lokalbot_i18n::tr(
                        "Check your connection and free disk space, then try again.",
                    )
                    .to_string(),
                }));
            return;
        }
        if !self.is_current(session) {
            return;
        }
        self.shared
            .emit(EngineEvent::Dictation(DictationUpdate::Transcribing));
        let result = process(&self.shared, &job, &self.recent, &|| {
            self.is_current(session)
        });
        drop(working);
        if !self.is_current(session) {
            return;
        }
        let (update, read_back) = match result {
            Ok(done) => done,
            Err(err)
                if matches!(
                    err.downcast_ref::<DictationError>(),
                    Some(DictationError::Cancelled)
                ) =>
            {
                return;
            }
            Err(err) => (
                DictationUpdate::Failed {
                    message: format!("{err:#}"),
                },
                None,
            ),
        };
        *self.state.lock() = State::Idle;
        self.shared.emit(EngineEvent::Dictation(update));
        if let Some(read_back) = read_back {
            read_back.run(&self, session);
        }
    }

    /// Finishes downloading a missing model, with its progress in the overlay.
    /// The audio stays in memory for as long as that takes.
    fn install_model(&self, session: u64) -> Result<()> {
        let requirements = self.models.dictation_requirements();
        if self.models.missing(&requirements).is_empty() {
            return Ok(());
        }
        let installing = {
            let (models, requirements) = (self.models.clone(), requirements.clone());
            std::thread::spawn(move || models.ensure_installed(&requirements))
        };
        while !installing.is_finished() {
            if !self.is_current(session) {
                // Cancelled: the download goes on, as it would from Settings.
                return Ok(());
            }
            let progress = self.models.download_progress(&requirements);
            self.shared
                .emit(EngineEvent::Dictation(DictationUpdate::Preparing {
                    progress: progress.flatten(),
                }));
            std::thread::sleep(Duration::from_millis(150));
        }
        installing
            .join()
            .map_err(|_| anyhow::anyhow!("the model download stopped"))?
    }

    /// Loads the speech model, showing that in the overlay only once it takes
    /// a while (`shouldShowModelPreparation`). A preview pass still holding the
    /// model is not preparation, and this waits for it.
    fn prepare_model(&self, settings: &Settings, session: u64) -> Result<()> {
        self.install_model(session)?;
        if !self.is_current(session) {
            return Ok(());
        }
        let done = Arc::new(AtomicBool::new(false));
        if !self.shared.speech.is_loaded(&settings.transcription_model) {
            let (shared, sessions, done) =
                (self.shared.clone(), self.sessions.clone(), done.clone());
            std::thread::spawn(move || {
                std::thread::sleep(PREPARATION_GRACE);
                if !done.load(Ordering::SeqCst) && sessions.load(Ordering::SeqCst) == session {
                    shared.emit(EngineEvent::Dictation(DictationUpdate::Preparing {
                        progress: None,
                    }));
                }
            });
        }
        let loaded = self
            .shared
            .speech
            .with(&self.shared, &settings.transcription_model, |_| Ok(()));
        done.store(true, Ordering::SeqCst);
        loaded
    }
}

/// The rolling live transcript (`runLivePreviewLoop`): overlapping windows of
/// the recording, stitched together. It shares the loaded speech model with
/// the final pass, which waits for a pass in progress.
fn run_preview(
    state: &Mutex<State>,
    shared: &Shared,
    sessions: &AtomicU64,
    session: u64,
    stop: &AtomicBool,
    text: &Mutex<String>,
) {
    let stopped = || stop.load(Ordering::Relaxed) || sessions.load(Ordering::SeqCst) != session;
    let wait = |duration: Duration| {
        let until = Instant::now() + duration;
        while Instant::now() < until {
            if stopped() {
                return false;
            }
            std::thread::sleep(Duration::from_millis(40));
        }
        !stopped()
    };
    if !wait(PREVIEW_FIRST_WAIT) {
        return;
    }
    let mut previewed = 0.0_f64;
    loop {
        let settings = shared.settings();
        if !settings.dictation_show_overlay || !settings.dictation_live_preview {
            if !wait(PREVIEW_POLL) {
                return;
            }
            continue;
        }
        let window = {
            let guard = state.lock();
            let State::Listening(listening) = &*guard else {
                return;
            };
            let duration = listening.capture.seconds();
            if duration < PREVIEW_MIN_SECONDS
                || duration - previewed < preview::minimum_advance(duration)
            {
                None
            } else {
                preview::window_range(previewed, duration).map(|range| {
                    let index = |seconds: f64| (seconds * SAMPLE_RATE) as usize;
                    let samples = listening
                        .capture
                        .samples_between(index(range.start), index(range.end));
                    (duration, range, samples)
                })
            }
        };
        let Some((duration, range, samples)) = window else {
            if !wait(PREVIEW_POLL) {
                return;
            }
            continue;
        };
        let language =
            Some(settings.transcription_language.clone()).filter(|l| l != "auto" && !l.is_empty());
        let prompt = shared.speech.dictation_prompt(shared, &settings);
        let heard = shared
            .speech
            .with(shared, &settings.transcription_model, |t| {
                t.transcribe_dictation_with_prompt(&samples, language.as_deref(), Some(&prompt))
            });
        if stopped() {
            return;
        }
        // Too short and no speech still advance, so one silent window is not
        // retried forever; anything else tries the same audio again later.
        match heard {
            Ok(heard) => {
                previewed = range.end;
                let heard = heard.trim();
                if !heard.is_empty() {
                    let mut text = text.lock();
                    // While the overlap reaches the recording's beginning,
                    // this window is the complete prefix.
                    *text = if range.start == 0.0 {
                        heard.to_string()
                    } else {
                        preview::stitch(&text, heard)
                    };
                }
            }
            Err(err)
                if matches!(
                    err.downcast_ref::<lokalbot_speech::SpeechError>(),
                    Some(
                        lokalbot_speech::SpeechError::NoSpeech
                            | lokalbot_speech::SpeechError::TooShort
                    )
                ) =>
            {
                previewed = range.end;
            }
            Err(err) => log::debug!("dictation live preview skipped: {err:#}"),
        }
        if !wait(Duration::from_secs_f64(preview::interval_after(duration))) {
            return;
        }
    }
}

fn process(
    shared: &Shared,
    job: &Job,
    recent: &Recent,
    is_current: &dyn Fn() -> bool,
) -> Result<(DictationUpdate, Option<ReadBack>)> {
    let settings = &job.settings;
    let started_in = match &job.pressed.front {
        Some(Frontmost::App(front)) => StartedIn::of(front),
        _ => StartedIn::default(),
    };
    let language =
        Some(settings.transcription_language.clone()).filter(|l| l != "auto" && !l.is_empty());
    let prompt = shared.speech.dictation_prompt(shared, settings);
    let mut asr_name = String::new();
    let spoken = shared
        .speech
        .with(shared, &settings.transcription_model, |t| {
            asr_name = t.display_name().to_string();
            t.transcribe_dictation_with_prompt(&job.samples, language.as_deref(), Some(&prompt))
        })?;
    if !is_current() {
        return Err(DictationError::Cancelled.into());
    }
    if spoken.trim().is_empty() {
        return Err(anyhow!("No speech detected."));
    }
    let compose = settings.dictation_intent == DictationIntent::Compose;
    // A direct sentence must not acquire claims from nearby messages, so the
    // capture that began during recording stops here.
    if !compose || !requests_context(&spoken) {
        job.cancel_screen.store(true, Ordering::Relaxed);
    }
    if compose {
        shared.emit(EngineEvent::Dictation(DictationUpdate::Spoken {
            text: spoken.clone(),
        }));
        shared.emit(EngineEvent::Dictation(DictationUpdate::Composing));
    }
    let mut providers = LiveProviders::new(
        shared,
        context_target(&job.pressed),
        job.screen.clone(),
        is_current,
    );
    let prepared = prepare_checked(&spoken, settings, &mut providers).and_then(|checked| {
        // Sources and grants guard delivery too.
        let current = shared.settings();
        if compose
            && (!permissions_match(settings, &current)
                || !providers.memory_is_current(&checked.facts, &current))
        {
            return Err(DictationError::ContextChanged.into());
        }
        Ok(checked.prepared)
    });
    let prepared = match prepared {
        Ok(prepared) => prepared,
        Err(err)
            if matches!(
                err.downcast_ref::<DictationError>(),
                Some(DictationError::Cancelled)
            ) =>
        {
            return Err(err);
        }
        Err(err) => {
            if !is_current() {
                return Err(DictationError::Cancelled.into());
            }
            // Compose failing must not lose minutes of transcribed speech.
            recent.keep(shared, &spoken, Outcome::NotInserted, &started_in);
            return Err(anyhow!(
                "{}: {err:#}",
                lokalbot_i18n::tr("Could not compose dictation")
            ));
        }
    };
    let text = prepared.text;
    if !is_current() {
        return Err(DictationError::Cancelled.into());
    }
    let mode = if job.rehearsal {
        DictationOutputMode::ShowInApp
    } else {
        settings.dictation_output_mode
    };
    let binding = Binding::of(&job.pressed.read);
    let delivered = deliver(&text, mode, &binding, is_current);
    match &delivered {
        Ok(Delivered::Cancelled) => return Err(DictationError::Cancelled.into()),
        // Text meant for a password field is never kept.
        Ok(Delivered::Withheld(DeliveryCheck::SecureField)) => {}
        Ok(Delivered::Inserted) => recent.keep(shared, &text, Outcome::Inserted, &started_in),
        Ok(Delivered::Shown) => recent.keep(shared, &text, Outcome::Shown, &started_in),
        Ok(Delivered::Copied(_) | Delivered::Withheld(_)) => {
            recent.keep(shared, &text, Outcome::Copied, &started_in)
        }
        Err(_) => recent.keep(shared, &text, Outcome::NotInserted, &started_in),
    }
    let delivered = delivered?;
    let inserted = delivered == Delivered::Inserted;
    if inserted {
        keep_for_learning(shared, &spoken, &job.pressed);
    }
    let read_back = inserted
        .then(|| ReadBack::of(&binding, &job.pressed, &text, shared))
        .flatten();
    let notice = match delivered {
        Delivered::Inserted | Delivered::Shown | Delivered::Cancelled => None,
        Delivered::Copied(notice) => Some(notice),
        Delivered::Withheld(check) => Some(lokalbot_i18n::tr(clipboard_message(check)).to_string()),
    };
    let context = prepared.context_use.map(|used| {
        used.summary(
            |key| lokalbot_i18n::tr(key).to_string(),
            |key, value| lokalbot_i18n::format(key, &[("0", value.to_string())]),
        )
    });
    let engine = match prepared.composition_model {
        Some(model) => format!("{asr_name} → {model}"),
        None => asr_name,
    };
    Ok((
        DictationUpdate::Finished {
            inserted,
            text,
            notice,
            spoken: spoken.trim().to_string(),
            engine,
            context,
        },
        read_back,
    ))
}

/// Where the text went.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Delivered {
    Inserted,
    Shown,
    /// On the clipboard, with this notice.
    Copied(String),
    /// On the clipboard instead of pasted, for this reason.
    Withheld(DeliveryCheck),
    Cancelled,
}

/// Errors only when even the clipboard failed.
fn deliver(
    text: &str,
    mode: DictationOutputMode,
    binding: &Binding,
    is_current: &dyn Fn() -> bool,
) -> Result<Delivered> {
    deliver_with(
        text,
        mode,
        binding,
        is_current,
        &|| focus::read_focus(focus::DELIVERY_DEADLINE),
        &|text, still_valid| paste_checked(text, still_valid),
        &lokalbot_platform::copy_to_clipboard,
    )
}

type PasteFn<'a> = &'a dyn Fn(&str, &mut dyn FnMut() -> bool) -> Result<PasteOutcome>;

fn deliver_with(
    text: &str,
    mode: DictationOutputMode,
    binding: &Binding,
    is_current: &dyn Fn() -> bool,
    read: &dyn Fn() -> FocusRead,
    paste: PasteFn<'_>,
    copy: &dyn Fn(&str) -> Result<()>,
) -> Result<Delivered> {
    if !is_current() {
        return Ok(Delivered::Cancelled);
    }
    let copied = lokalbot_i18n::tr("Copied to the clipboard").to_string();
    match mode {
        DictationOutputMode::ShowInApp => Ok(Delivered::Shown),
        DictationOutputMode::Clipboard => {
            copy(text)?;
            Ok(Delivered::Copied(copied))
        }
        DictationOutputMode::Paste => {
            let check = binding.check(read);
            if !is_current() {
                return Ok(Delivered::Cancelled);
            }
            if check != DeliveryCheck::Deliverable {
                copy(text)?;
                return Ok(Delivered::Withheld(check));
            }
            // An earlier paste may hold the queue; check the field again.
            let mut queued = DeliveryCheck::Deliverable;
            let outcome = paste(text, &mut || {
                if !is_current() {
                    return false;
                }
                queued = binding.check(read);
                queued == DeliveryCheck::Deliverable && is_current()
            });
            if !is_current() {
                return Ok(Delivered::Cancelled);
            }
            match outcome {
                Ok(PasteOutcome::Pasted) => Ok(Delivered::Inserted),
                Ok(PasteOutcome::LeftOnClipboard) => Ok(Delivered::Copied(copied)),
                Ok(PasteOutcome::Skipped) => {
                    copy(text)?;
                    Ok(Delivered::Withheld(queued))
                }
                Err(err) => {
                    copy(text)?;
                    Ok(Delivered::Copied(format!("{copied} ({err})")))
                }
            }
        }
    }
}

/// Reads the field back after a paste. Only a field that can be read and still
/// lacks the text raises the notice; an unreadable one (many Electron and web
/// editors) is left alone rather than guessed at. The read is compared here
/// and dropped.
struct ReadBack {
    text: String,
    pid: u32,
    identity: String,
}

impl ReadBack {
    /// Only the exact field the text went to, and never an excluded app.
    fn of(binding: &Binding, pressed: &PressedFocus, text: &str, shared: &Shared) -> Option<Self> {
        let Binding::Target(target) = binding else {
            return None;
        };
        let FocusRead::Snapshot(snapshot) = &pressed.read else {
            return None;
        };
        if context::is_excluded(&snapshot.front, &shared.settings()) {
            return None;
        }
        Some(Self {
            text: text.to_string(),
            pid: target.pid?,
            identity: target.identity.clone().filter(|key| !key.is_empty())?,
        })
    }

    fn run(self, runner: &Runner, session: u64) {
        let mut waited = 0;
        for delay in preview::READ_DELAYS_MS {
            std::thread::sleep(Duration::from_millis(delay - waited));
            waited = delay;
            if !runner.is_current(session) {
                return;
            }
            let (pid, identity) = (self.pid, self.identity.clone());
            let before = focus::with_deadline(READ_BACK_DEADLINE, move || {
                focused::text_before_caret(pid, &identity)
            })
            .flatten();
            match preview::insertion_verdict(before.as_deref(), &self.text) {
                InsertionVerdict::Landed | InsertionVerdict::Unknown => return,
                InsertionVerdict::Missing => {}
            }
        }
        if runner.is_current(session) {
            log::info!("dictation paste was not found in the target field");
            *runner.notice.lock() = Some(self.text);
            runner
                .shared
                .emit(EngineEvent::Dictation(DictationUpdate::DeliveryNotice {
                    copied: false,
                }));
        }
    }
}

/// Learn from my dictation (`keepForLearning`): reads the pasted-into window's
/// title and page address once, and keeps the spoken words only if they pass the
/// same exclusions as nearby text. Anything unreadable keeps nothing.
fn keep_for_learning(shared: &Shared, spoken: &str, pressed: &PressedFocus) {
    let settings = shared.settings();
    if !settings.learns_from_dictation() {
        return;
    }
    let Some(Frontmost::App(front)) = pressed.front.clone() else {
        return;
    };
    if front.is_self() {
        return;
    }
    let library = shared.library.clone();
    let spoken = spoken.to_string();
    let read = pressed.read.clone();
    std::thread::spawn(move || {
        let Some((target, surface)) =
            crate::dictation_context::ContextTarget::of_learning(&read, front)
        else {
            return;
        };
        if !crate::dictation_context::learning_permits(&target, &surface, &settings) {
            return;
        }
        if let Err(err) = library
            .dictation_log()
            .append(&spoken, &target.front.app_name)
        {
            log::warn!("dictation for learning not kept: {err:#}");
        }
    });
}

/// The app a dictation started in.
#[derive(Clone, Debug, Default)]
struct StartedIn {
    /// `None` for LokalBot itself or when it can't be read.
    app_name: Option<String>,
    /// Text dictated into a password manager is never kept.
    password_manager: bool,
}

impl StartedIn {
    fn of(front: &FrontApp) -> Self {
        if front.is_self() {
            return Self::default();
        }
        Self {
            password_manager: lokalbot_platform::privacy::is_password_manager(
                &front.app_name,
                &front.app_id,
            ),
            app_name: Some(front.app_name.clone()).filter(|name| !name.trim().is_empty()),
        }
    }
}

/// Recent dictations: in memory, and sealed in the library whenever the
/// credential store can keep their key. Without one they last until quit.
struct Recent {
    path: PathBuf,
    history: Mutex<DictationHistory>,
    /// Orders writes and deletes; each writes the history as it is then.
    files: Mutex<()>,
}

impl Recent {
    fn load(&self, shared: &Shared) {
        if !self.path.exists() {
            return;
        }
        let saved = match secrets::recent_dictations_key(false) {
            Ok(key) => dictation_history::load(&self.path, &key, Utc::now()),
            Err(err) => {
                log::warn!("recent dictations not read: {err:#}");
                return;
            }
        };
        let snapshot = {
            let mut history = self.history.lock();
            let mut entries = saved.entries().to_vec();
            entries.extend(history.entries().iter().cloned());
            *history = DictationHistory::new(entries, Utc::now());
            history.entries().to_vec()
        };
        shared.emit(EngineEvent::RecentDictations(snapshot));
    }

    fn keep(&self, shared: &Shared, text: &str, outcome: Outcome, started_in: &StartedIn) {
        if started_in.password_manager {
            return;
        }
        let snapshot = {
            let mut history = self.history.lock();
            if !history.record(text, outcome, started_in.app_name.clone(), Utc::now()) {
                return;
            }
            history.entries().to_vec()
        };
        shared.emit(EngineEvent::RecentDictations(snapshot));
        self.write();
    }

    fn copy(&self, id: Option<Uuid>, shared: &Shared) {
        let Some(text) = self.history.lock().find(id).map(|entry| entry.text.clone()) else {
            return;
        };
        match lokalbot_platform::copy_to_clipboard(&text) {
            Ok(()) => shared.message(lokalbot_i18n::tr("Copied.")),
            Err(err) => shared.error(format!("{err:#}")),
        }
    }

    fn clear(self: &Arc<Self>, shared: &Shared) {
        self.history.lock().clear();
        shared.emit(EngineEvent::RecentDictations(Vec::new()));
        let recent = self.clone();
        std::thread::spawn(move || recent.write());
    }

    fn write(&self) {
        let _files = self.files.lock();
        let entries = self.history.lock().entries().to_vec();
        let result = if entries.is_empty() {
            dictation_history::delete(&self.path)
        } else {
            secrets::recent_dictations_key(true)
                .and_then(|key| dictation_history::save(&self.path, &key, &entries))
        };
        if let Err(err) = result {
            log::warn!("recent dictations kept in memory only: {err:#}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_platform::focus::FocusSnapshot;
    use std::cell::{Cell, RefCell};

    /// A coordinator with no microphone, and everything it reported.
    fn coordinator() -> (
        tempfile::TempDir,
        Dictation,
        Arc<Shared>,
        Arc<Mutex<Vec<EngineEvent>>>,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let library =
            lokalbot_core::Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let log = events.clone();
        let shared = Shared::for_tests(library, Settings::default(), move |event| {
            log.lock().push(event)
        });
        let models = Models::new(shared.clone());
        let dictation = Dictation::new(shared.clone(), models);
        (dir, dictation, shared, events)
    }

    /// A recording waiting for its speech model, which is "downloading" for
    /// as long as the test runs, so nothing is fetched.
    fn waiting_for_the_model(dictation: &Dictation) -> Job {
        for id in dictation.models.dictation_requirements() {
            dictation.models.pretend_downloading(&id);
        }
        Job {
            samples: Vec::new(),
            settings: Settings::default(),
            pressed: PressedFocus::nothing_known(),
            screen: None,
            cancel_screen: Arc::new(AtomicBool::new(false)),
            rehearsal: false,
        }
    }

    /// Day digests and overnight reviews wait while `dictation_working` is
    /// set, so a run that ends before the text must clear it too.
    #[test]
    fn a_run_cancelled_while_its_model_loads_stops_counting_as_working() {
        let (_dir, dictation, shared, _events) = coordinator();
        let job = waiting_for_the_model(&dictation);
        shared.dictation_working.store(true, Ordering::Relaxed);
        let session = dictation.session.load(Ordering::SeqCst);
        dictation.session.fetch_add(1, Ordering::SeqCst);

        dictation.runner().run(job, session);

        assert!(!shared.dictation_working.load(Ordering::Relaxed));
    }

    #[test]
    fn a_retry_counts_as_working_until_it_is_cancelled() {
        let (_dir, dictation, shared, _events) = coordinator();
        let job = waiting_for_the_model(&dictation);
        *shared.dictation_state.lock() = State::NeedsRetry(Box::new(job));

        dictation.retry();
        assert!(shared.dictation_working.load(Ordering::Relaxed));

        dictation.cancel();
        let cancelled = Instant::now();
        while shared.dictation_working.load(Ordering::Relaxed) {
            assert!(cancelled.elapsed() < Duration::from_secs(10));
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn finishing_with_nothing_listening_does_not_count_as_working() {
        let (_dir, dictation, shared, _events) = coordinator();
        dictation.finish();
        assert!(!shared.dictation_working.load(Ordering::Relaxed));
        assert!(!shared.dictation_state.lock().is_busy());
    }

    #[test]
    fn the_cancel_row_cancels_while_the_text_is_being_prepared() {
        let (_dir, dictation, shared, events) = coordinator();
        *shared.dictation_state.lock() = State::Working;
        dictation.handle(DictationCommand::ToggleFromMenu);
        assert!(!shared.dictation_state.lock().is_busy());
        assert!(
            events
                .lock()
                .iter()
                .any(|e| matches!(e, EngineEvent::Dictation(DictationUpdate::Cancelled)))
        );
    }

    #[test]
    fn the_shortcut_never_cancels_finished_speech() {
        let (_dir, dictation, shared, events) = coordinator();
        *shared.dictation_state.lock() = State::Working;
        dictation.handle(DictationCommand::Toggle);
        assert!(matches!(*shared.dictation_state.lock(), State::Working));
        assert!(events.lock().is_empty());
    }

    #[test]
    fn toggle_follows_the_macs_table() {
        for (state, shortcut, menu) in [
            (State::Idle, ToggleAction::Start, ToggleAction::Start),
            (State::Working, ToggleAction::Ignore, ToggleAction::Cancel),
        ] {
            assert_eq!(toggle_action(&state, true), shortcut);
            assert_eq!(toggle_action(&state, false), menu);
        }
    }

    /// The two share a microphone; the meeting recording wins.
    #[test]
    fn dictation_does_not_start_during_a_meeting_recording() {
        let (_dir, dictation, shared, events) = coordinator();
        shared.recording_active.store(true, Ordering::Relaxed);
        for command in [
            DictationCommand::Start,
            DictationCommand::Toggle,
            DictationCommand::ToggleFromMenu,
            DictationCommand::ToggleRehearsal,
        ] {
            dictation.handle(command);
            assert!(!shared.dictation_state.lock().is_busy());
        }
        let events = events.lock();
        let refused = |event: &&EngineEvent| {
            matches!(event, EngineEvent::Message { text, is_error: true }
                if text == "Stop the current meeting recording before starting dictation.")
        };
        assert_eq!(events.iter().filter(refused).count(), 4);
        assert!(
            !events
                .iter()
                .any(|e| matches!(e, EngineEvent::Dictation(DictationUpdate::Starting))),
            "{events:?}"
        );
    }

    fn snapshot(identity: Option<&str>) -> FocusSnapshot {
        FocusSnapshot {
            front: FrontApp {
                pid: Some(7),
                app_name: "Editor".into(),
                app_id: "editor".into(),
                window: Some(1),
                title: String::new(),
            },
            field_pid: Some(7),
            identity: identity.map(str::to_string),
            accessible: true,
            ..FocusSnapshot::default()
        }
    }

    /// Delivery with fakes: what was pasted and what was copied.
    struct Fakes {
        reads: RefCell<Vec<FocusRead>>,
        pasted: RefCell<Vec<String>>,
        copied: RefCell<Vec<String>>,
        paste_result: PasteOutcome,
        current: Cell<bool>,
        cancel_during_paste: Cell<bool>,
    }

    impl Fakes {
        fn new(reads: Vec<FocusRead>) -> Self {
            Self {
                reads: RefCell::new(reads),
                pasted: RefCell::new(Vec::new()),
                copied: RefCell::new(Vec::new()),
                paste_result: PasteOutcome::Pasted,
                current: Cell::new(true),
                cancel_during_paste: Cell::new(false),
            }
        }

        fn deliver(&self, mode: DictationOutputMode, binding: &Binding) -> Result<Delivered> {
            let is_current = || self.current.get();
            let read = || {
                let mut reads = self.reads.borrow_mut();
                if reads.is_empty() {
                    FocusRead::TimedOut
                } else {
                    reads.remove(0)
                }
            };
            let paste =
                |text: &str, still_valid: &mut dyn FnMut() -> bool| -> Result<PasteOutcome> {
                    if !still_valid() {
                        return Ok(PasteOutcome::Skipped);
                    }
                    if self.cancel_during_paste.get() {
                        self.current.set(false);
                    }
                    self.pasted.borrow_mut().push(text.to_string());
                    Ok(self.paste_result)
                };
            let copy = |text: &str| -> Result<()> {
                self.copied.borrow_mut().push(text.to_string());
                Ok(())
            };
            deliver_with("text", mode, binding, &is_current, &read, &paste, &copy)
        }
    }

    fn at_field(identity: &str) -> Binding {
        Binding::of(&FocusRead::Snapshot(snapshot(Some(identity))))
    }

    fn still(identity: Option<&str>) -> FocusRead {
        FocusRead::Snapshot(snapshot(identity))
    }

    #[test]
    fn the_same_field_gets_the_paste() {
        let fakes = Fakes::new(vec![still(Some("a")), still(Some("a"))]);
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::Paste, &at_field("a"))
                .unwrap(),
            Delivered::Inserted
        );
        assert_eq!(*fakes.pasted.borrow(), ["text"]);
        assert!(fakes.copied.borrow().is_empty());
    }

    #[test]
    fn moved_focus_copies_instead() {
        let fakes = Fakes::new(vec![still(Some("b"))]);
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::Paste, &at_field("a"))
                .unwrap(),
            Delivered::Withheld(DeliveryCheck::FocusMoved)
        );
        assert!(fakes.pasted.borrow().is_empty());
        assert_eq!(*fakes.copied.borrow(), ["text"]);
    }

    #[test]
    fn a_password_field_is_never_pasted_into() {
        let mut secure = snapshot(None);
        secure.secure = true;
        // It had focus at the press: no target is ever bound.
        let binding = Binding::of(&FocusRead::Snapshot(secure.clone()));
        assert_eq!(binding, Binding::Issue(DeliveryCheck::SecureField));
        let fakes = Fakes::new(Vec::new());
        assert_eq!(
            fakes.deliver(DictationOutputMode::Paste, &binding).unwrap(),
            Delivered::Withheld(DeliveryCheck::SecureField)
        );
        assert!(fakes.pasted.borrow().is_empty());
        // It took focus later, in the same app.
        let fakes = Fakes::new(vec![FocusRead::Snapshot(secure)]);
        let app_only = Binding::of(&still(None));
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::Paste, &app_only)
                .unwrap(),
            Delivered::Withheld(DeliveryCheck::SecureField)
        );
        assert!(fakes.pasted.borrow().is_empty());
    }

    #[test]
    fn an_unreadable_field_copies() {
        for pressed in [FocusRead::TimedOut, FocusRead::Nothing] {
            let binding = Binding::of(&pressed);
            let fakes = Fakes::new(Vec::new());
            assert_eq!(
                fakes.deliver(DictationOutputMode::Paste, &binding).unwrap(),
                Delivered::Withheld(DeliveryCheck::FieldUnreadable)
            );
        }
        let fakes = Fakes::new(vec![FocusRead::TimedOut]);
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::Paste, &at_field("a"))
                .unwrap(),
            Delivered::Withheld(DeliveryCheck::FieldUnreadable)
        );
    }

    #[test]
    fn a_desktop_that_says_nothing_still_pastes() {
        let binding = Binding::of(&FocusRead::Unknown);
        assert_eq!(binding, Binding::Unknown);
        let fakes = Fakes::new(vec![FocusRead::Unknown, FocusRead::Unknown]);
        assert_eq!(
            fakes.deliver(DictationOutputMode::Paste, &binding).unwrap(),
            Delivered::Inserted
        );
        // Unless it found out meanwhile that a password field has focus.
        let mut secure = snapshot(None);
        secure.secure = true;
        let fakes = Fakes::new(vec![FocusRead::Snapshot(secure)]);
        assert_eq!(
            fakes.deliver(DictationOutputMode::Paste, &binding).unwrap(),
            Delivered::Withheld(DeliveryCheck::SecureField)
        );
    }

    #[test]
    fn the_queue_checks_the_field_again() {
        // Fine before waiting for an earlier paste, gone after it.
        let fakes = Fakes::new(vec![still(Some("a")), still(Some("b"))]);
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::Paste, &at_field("a"))
                .unwrap(),
            Delivered::Withheld(DeliveryCheck::FocusMoved)
        );
        assert!(fakes.pasted.borrow().is_empty());
        assert_eq!(*fakes.copied.borrow(), ["text"]);
    }

    #[test]
    fn a_cancelled_dictation_touches_nothing() {
        let fakes = Fakes::new(vec![still(Some("a"))]);
        fakes.current.set(false);
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::Paste, &at_field("a"))
                .unwrap(),
            Delivered::Cancelled
        );
        assert!(fakes.pasted.borrow().is_empty() && fakes.copied.borrow().is_empty());
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::Clipboard, &at_field("a"))
                .unwrap(),
            Delivered::Cancelled
        );
        assert!(fakes.copied.borrow().is_empty());

        // Cancelled while the paste waited: reported so, with no fallback.
        let fakes = Fakes::new(vec![still(Some("a")), still(Some("a"))]);
        fakes.cancel_during_paste.set(true);
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::Paste, &at_field("a"))
                .unwrap(),
            Delivered::Cancelled
        );
        assert!(fakes.copied.borrow().is_empty());
    }

    #[test]
    fn other_output_modes_never_read_the_field() {
        let fakes = Fakes::new(vec![still(Some("b"))]);
        assert_eq!(
            fakes
                .deliver(DictationOutputMode::ShowInApp, &at_field("a"))
                .unwrap(),
            Delivered::Shown
        );
        assert!(fakes.copied.borrow().is_empty());
        assert_eq!(fakes.reads.borrow().len(), 1);
        assert!(matches!(
            fakes
                .deliver(DictationOutputMode::Clipboard, &at_field("a"))
                .unwrap(),
            Delivered::Copied(_)
        ));
        assert_eq!(*fakes.copied.borrow(), ["text"]);
        assert_eq!(fakes.reads.borrow().len(), 1);
    }

    #[test]
    fn a_paste_without_keystrokes_stays_on_the_clipboard() {
        let mut fakes = Fakes::new(vec![still(Some("a")), still(Some("a"))]);
        fakes.paste_result = PasteOutcome::LeftOnClipboard;
        assert!(matches!(
            fakes
                .deliver(DictationOutputMode::Paste, &at_field("a"))
                .unwrap(),
            Delivered::Copied(_)
        ));
    }

    #[test]
    fn a_silent_microphone_is_named_after_two_seconds() {
        let at = Duration::from_secs;
        assert_eq!(idle_microphone_status(None, at(1)), None);
        assert_eq!(
            idle_microphone_status(None, at(2)),
            Some("Waiting for the microphone")
        );
        assert_eq!(idle_microphone_status(Some(at(1)), at(30)), None);
        assert_eq!(
            idle_microphone_status(Some(at(2)), at(30)),
            Some("No audio from the microphone")
        );
    }

    #[test]
    fn started_in_never_names_lokalbot_and_flags_password_managers() {
        let mut front = snapshot(None).front;
        assert_eq!(StartedIn::of(&front).app_name.as_deref(), Some("Editor"));
        front.app_id = lokalbot_platform::privacy::SELF_APP_ID.into();
        assert_eq!(StartedIn::of(&front).app_name, None);
        front.app_id = "keepassxc".into();
        front.app_name = "KeePassXC".into();
        assert!(StartedIn::of(&front).password_manager);
    }
}
