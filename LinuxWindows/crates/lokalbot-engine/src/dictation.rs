//! Dictation: capture while the shortcut is held, transcribe on this PC,
//! optionally clean up or compose with Think, then insert at the cursor
//! (`DictationCoordinator.swift`). The latest results are kept, sealed on
//! disk, so one left on the clipboard can be copied again (`DictationHistory`).

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use chrono::Utc;
use parking_lot::Mutex;
use uuid::Uuid;

use lokalbot_audio::MicCapture;
use lokalbot_core::dictation_history::{self, DictationHistory, Outcome};
use lokalbot_core::settings::{DictationIntent, DictationOutputMode};
use lokalbot_platform::{InsertMethod, InsertOutcome};

use crate::models::Models;
use crate::{DictationCommand, DictationUpdate, EngineEvent, Shared, secrets};

pub struct Dictation {
    shared: Arc<Shared>,
    models: Models,
    state: Arc<Mutex<State>>,
    recent: Arc<Recent>,
}

enum State {
    Idle,
    Listening {
        capture: MicCapture,
        started: Instant,
        ticker_stop: Arc<AtomicBool>,
        /// The app it started in, read once off this thread.
        started_in: JoinHandle<Option<StartedIn>>,
    },
    Working,
}

impl Dictation {
    pub fn new(shared: Arc<Shared>, models: Models) -> Self {
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
            state: Arc::new(Mutex::new(State::Idle)),
            recent,
        }
    }

    pub fn handle(&self, command: DictationCommand) {
        let listening = matches!(*self.state.lock(), State::Listening { .. });
        match command {
            DictationCommand::Start if !listening => self.start(),
            DictationCommand::Stop if listening => self.finish(),
            DictationCommand::Toggle => {
                if listening {
                    self.finish()
                } else {
                    self.start()
                }
            }
            DictationCommand::Cancel if listening => self.cancel(),
            DictationCommand::CopyRecent(id) => {
                let (recent, shared) = (self.recent.clone(), self.shared.clone());
                std::thread::spawn(move || recent.copy(id, &shared));
            }
            DictationCommand::ClearRecent => self.recent.clear(&self.shared),
            _ => {}
        }
    }

    fn start(&self) {
        if !matches!(*self.state.lock(), State::Idle) {
            return;
        }
        if !self
            .models
            .missing(&self.models.dictation_requirements())
            .is_empty()
        {
            self.shared
                .emit(EngineEvent::Dictation(DictationUpdate::Failed {
                    message:
                        "Dictation needs the transcription model. Download it in Settings → Models."
                            .into(),
                }));
            return;
        }
        self.shared
            .emit(EngineEvent::Dictation(DictationUpdate::Starting));
        let settings = self.shared.settings();
        let device = Some(settings.dictation_microphone_id.clone()).filter(|d| !d.is_empty());
        let capture = match MicCapture::start(device.as_deref()) {
            Ok(capture) => capture,
            Err(err) => {
                self.shared
                    .emit(EngineEvent::Dictation(DictationUpdate::Failed {
                        message: format!("The microphone could not start: {err:#}"),
                    }));
                return;
            }
        };
        self.shared.capture_active.store(true, Ordering::Relaxed);
        let started_in = std::thread::spawn(StartedIn::focused);
        let ticker_stop = Arc::new(AtomicBool::new(false));
        {
            let state = self.state.clone();
            let shared = self.shared.clone();
            let stop = ticker_stop.clone();
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    if let State::Listening {
                        capture, started, ..
                    } = &*state.lock()
                    {
                        shared.emit(EngineEvent::Dictation(DictationUpdate::Listening {
                            level: capture.level(),
                            elapsed_seconds: started.elapsed().as_secs_f64(),
                            preview: String::new(),
                        }));
                    }
                    std::thread::sleep(Duration::from_millis(80));
                }
            });
        }
        *self.state.lock() = State::Listening {
            capture,
            started: Instant::now(),
            ticker_stop,
            started_in,
        };
    }

    fn cancel(&self) {
        let previous = std::mem::replace(&mut *self.state.lock(), State::Idle);
        if let State::Listening {
            capture,
            ticker_stop,
            ..
        } = previous
        {
            ticker_stop.store(true, Ordering::Relaxed);
            drop(capture.stop());
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
        let State::Listening {
            capture,
            ticker_stop,
            started_in,
            ..
        } = previous
        else {
            *self.state.lock() = State::Idle;
            return;
        };
        ticker_stop.store(true, Ordering::Relaxed);
        let samples = capture.stop();
        self.shared.capture_active.store(
            self.shared.recording_active.load(Ordering::Relaxed),
            Ordering::Relaxed,
        );
        let shared = self.shared.clone();
        let state = self.state.clone();
        let recent = self.recent.clone();
        std::thread::spawn(move || {
            let started_in = started_in.join().ok().flatten().unwrap_or_default();
            let update = match process(&shared, &samples, &recent, &started_in) {
                Ok(update) => update,
                Err(err) => DictationUpdate::Failed {
                    message: format!("{err:#}"),
                },
            };
            *state.lock() = State::Idle;
            shared.emit(EngineEvent::Dictation(update));
        });
    }
}

fn process(
    shared: &Shared,
    samples: &[f32],
    recent: &Recent,
    started_in: &StartedIn,
) -> Result<DictationUpdate> {
    let settings = shared.settings();
    shared.emit(EngineEvent::Dictation(DictationUpdate::Transcribing));
    let language =
        Some(settings.transcription_language.clone()).filter(|l| l != "auto" && !l.is_empty());
    let mut text = shared
        .speech
        .with(shared, &settings.transcription_model, |t| {
            t.transcribe_dictation(samples, language.as_deref())
        })?;
    if text.trim().is_empty() {
        return Err(anyhow!("No speech detected."));
    }
    if settings.dictation_intent == DictationIntent::Compose {
        shared.emit(EngineEvent::Dictation(DictationUpdate::Composing));
        let composed = shared
            .think(&settings)
            .and_then(|think| lokalbot_ai::dictation::prepare(&think, &text, &settings));
        match composed {
            Ok(composed) => text = composed,
            Err(err) => {
                // Compose failing must not lose minutes of transcribed speech.
                recent.keep(shared, &text, Outcome::NotInserted, started_in);
                return Err(err);
            }
        }
    }
    let delivered = deliver(&text, settings.dictation_output_mode);
    recent.keep(
        shared,
        &text,
        match &delivered {
            Ok((true, _)) => Outcome::Inserted,
            Ok((false, None)) => Outcome::Shown,
            Ok((false, Some(_))) => Outcome::Copied,
            Err(_) => Outcome::NotInserted,
        },
        started_in,
    );
    let (inserted, notice) = delivered?;
    Ok(DictationUpdate::Finished {
        text,
        inserted,
        notice,
    })
}

/// Where the text went: inserted, and the notice when it went to the
/// clipboard instead. Errors only when even the clipboard failed.
fn deliver(text: &str, mode: DictationOutputMode) -> Result<(bool, Option<String>)> {
    Ok(match mode {
        DictationOutputMode::Paste => {
            match lokalbot_platform::insert_text(text, InsertMethod::Paste) {
                Ok(InsertOutcome::Inserted) => (true, None),
                Ok(InsertOutcome::CopiedToClipboard) => {
                    (false, Some("Copied to the clipboard".to_string()))
                }
                Err(err) => {
                    lokalbot_platform::copy_to_clipboard(text)?;
                    (false, Some(format!("Copied to the clipboard ({err})")))
                }
            }
        }
        DictationOutputMode::Clipboard => {
            lokalbot_platform::copy_to_clipboard(text)?;
            (false, Some("Copied to the clipboard".to_string()))
        }
        DictationOutputMode::ShowInApp => (false, None),
    })
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
    fn focused() -> Option<Self> {
        let sample = lokalbot_platform::activity_source().sample().ok()??;
        if sample.app_id == lokalbot_platform::privacy::SELF_APP_ID {
            return Some(Self::default());
        }
        Some(Self {
            password_manager: lokalbot_platform::privacy::is_password_manager(
                &sample.app,
                &sample.app_id,
            ),
            app_name: Some(sample.app).filter(|name| !name.trim().is_empty()),
        })
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
