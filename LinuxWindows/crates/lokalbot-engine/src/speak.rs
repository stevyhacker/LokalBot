use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use parking_lot::Mutex;

use lokalbot_audio::SpeechPlayer;
use lokalbot_speech::kokoro::{self, Kokoro, Speech, SynthesisError};
use lokalbot_speech::models::KOKORO_MODEL;

use crate::models::Models;
use crate::{EngineEvent, Shared, SpeechCommand, SpeechStatus};

const IDLE_UNLOAD: Duration = Duration::from_secs(120);
pub const EXPORT_KEY: &str = "export";

struct Session {
    id: u64,
    cancel: Arc<AtomicBool>,
    player: Option<Arc<SpeechPlayer>>,
    downloading: bool,
}

struct Loaded {
    kokoro: Arc<Kokoro>,
    last_used: Instant,
}

#[derive(Clone)]
pub struct Speaker {
    inner: Arc<Inner>,
}

struct Inner {
    shared: Arc<Shared>,
    models: Models,
    session: Mutex<Option<Session>>,
    next_id: AtomicU64,
    status: Mutex<SpeechStatus>,
    loaded: Mutex<Option<Loaded>>,
    synthesis: Mutex<()>,
}

impl Speaker {
    pub fn new(shared: Arc<Shared>, models: Models) -> Self {
        let speaker = Self {
            inner: Arc::new(Inner {
                shared,
                models,
                session: Mutex::new(None),
                next_id: AtomicU64::new(1),
                status: Mutex::new(SpeechStatus::default()),
                loaded: Mutex::new(None),
                synthesis: Mutex::new(()),
            }),
        };
        let inner = speaker.inner.clone();
        std::thread::spawn(move || {
            while !inner.shared.is_shutting_down() {
                std::thread::sleep(Duration::from_secs(30));
                inner.release_if_idle();
            }
        });
        speaker
    }

    pub fn handle(&self, command: SpeechCommand) {
        match command {
            SpeechCommand::Read { key, text } => self.read(key, text),
            SpeechCommand::Stop => self.stop(),
            SpeechCommand::Export { text, path } => self.export(text, path),
        }
    }

    pub fn stop(&self) {
        self.inner.stop_session();
        self.inner.update(|status| {
            status.reading = None;
            status.preparing = false;
            status.error = None;
        });
    }

    fn read(&self, key: String, text: String) {
        self.inner.stop_session();
        let id = self.inner.next_id.fetch_add(1, Ordering::Relaxed);
        let cancel = Arc::new(AtomicBool::new(false));
        *self.inner.session.lock() = Some(Session {
            id,
            cancel: cancel.clone(),
            player: None,
            downloading: false,
        });
        self.inner.update(|status| {
            status.reading = Some(key.clone());
            status.preparing = true;
            status.error = None;
        });
        let inner = self.inner.clone();
        std::thread::spawn(move || {
            let result = inner.speak(id, &text, &cancel);
            let current = inner.end_session(id);
            if !current {
                return;
            }
            inner.update(|status| {
                status.reading = None;
                status.preparing = false;
                if let Err(err) = &result
                    && !is_cancelled(err)
                {
                    status.error = Some((key.clone(), format!("{err:#}")));
                }
            });
        });
    }

    fn export(&self, text: String, path: PathBuf) {
        self.inner.update(|status| {
            status.exporting = true;
            status.error = None;
        });
        let inner = self.inner.clone();
        std::thread::spawn(move || {
            let result = (|| -> Result<()> {
                let cancel = Arc::new(AtomicBool::new(false));
                let speech = inner.synthesize(None, &text, &cancel)?;
                lokalbot_audio::write_wav(&path, &speech.samples, speech.sample_rate)?;
                Ok(())
            })();
            let failed = result.as_ref().err().map(|err| format!("{err:#}"));
            inner.update(|status| {
                status.exporting = false;
                if let Some(message) = &failed {
                    status.error = Some((EXPORT_KEY.to_string(), message.clone()));
                }
            });
        });
    }
}

impl Inner {
    fn update(&self, change: impl FnOnce(&mut SpeechStatus)) {
        let snapshot = {
            let mut status = self.status.lock();
            change(&mut status);
            status.clone()
        };
        self.shared.emit(EngineEvent::Speech(snapshot));
    }

    fn stop_session(&self) {
        let Some(session) = self.session.lock().take() else {
            return;
        };
        session.cancel.store(true, Ordering::Relaxed);
        if let Some(player) = session.player {
            player.stop();
        }
        if session.downloading {
            self.models.cancel(KOKORO_MODEL);
        }
    }

    fn end_session(&self, id: u64) -> bool {
        let mut session = self.session.lock();
        if session.as_ref().is_some_and(|s| s.id == id) {
            *session = None;
            true
        } else {
            false
        }
    }

    fn speak(&self, id: u64, text: &str, cancel: &Arc<AtomicBool>) -> Result<()> {
        let speech = self.synthesize(Some(id), text, cancel)?;
        check_cancelled(cancel)?;
        let player = Arc::new(SpeechPlayer::start(speech.samples, speech.sample_rate)?);
        {
            let mut session = self.session.lock();
            match session.as_mut() {
                Some(session) if session.id == id => session.player = Some(player.clone()),
                _ => return Err(SynthesisError::Cancelled.into()),
            }
        }
        self.update(|status| status.preparing = false);
        while !player.is_finished() {
            std::thread::sleep(Duration::from_millis(50));
        }
        Ok(())
    }

    fn synthesize(
        &self,
        session: Option<u64>,
        text: &str,
        cancel: &Arc<AtomicBool>,
    ) -> Result<Speech> {
        if kokoro::plain_text(text).trim().is_empty() {
            return Err(SynthesisError::EmptyText.into());
        }
        self.prepare_model(session, cancel)?;
        let _one_at_a_time = self.synthesis.lock();
        check_cancelled(cancel)?;
        let settings = self.shared.settings();
        let voice = kokoro::voice(&settings.speech_voice);
        let kokoro = self.kokoro()?;
        let speech = kokoro.synthesize(text, voice, settings.speech_speed, cancel.clone());
        self.touch();
        speech
    }

    fn prepare_model(&self, session: Option<u64>, cancel: &AtomicBool) -> Result<()> {
        let ids = [KOKORO_MODEL.to_string()];
        self.wait_for_download(cancel)?;
        if self.models.missing(&ids).is_empty() {
            return Ok(());
        }
        if let Some(id) = session {
            match self.session.lock().as_mut() {
                Some(session) if session.id == id => session.downloading = true,
                _ => return Err(SynthesisError::Cancelled.into()),
            }
        }
        self.models.ensure(&ids, true)?;
        self.wait_for_download(cancel)
    }

    fn wait_for_download(&self, cancel: &AtomicBool) -> Result<()> {
        while self.models.is_downloading(KOKORO_MODEL) {
            check_cancelled(cancel)?;
            std::thread::sleep(Duration::from_millis(100));
        }
        check_cancelled(cancel)
    }

    fn kokoro(&self) -> Result<Arc<Kokoro>> {
        let mut loaded = self.loaded.lock();
        if let Some(loaded) = loaded.as_mut() {
            loaded.last_used = Instant::now();
            return Ok(loaded.kokoro.clone());
        }
        let kokoro = Arc::new(Kokoro::load(self.shared.library.paths())?);
        self.shared.speech.set_voice_loaded(true);
        *loaded = Some(Loaded {
            kokoro: kokoro.clone(),
            last_used: Instant::now(),
        });
        Ok(kokoro)
    }

    fn touch(&self) {
        if let Some(loaded) = self.loaded.lock().as_mut() {
            loaded.last_used = Instant::now();
        }
    }

    fn release_if_idle(&self) {
        let mut loaded = self.loaded.lock();
        if loaded
            .as_ref()
            .is_some_and(|l| l.last_used.elapsed() > IDLE_UNLOAD)
        {
            *loaded = None;
            self.shared.speech.set_voice_loaded(false);
        }
    }
}

fn check_cancelled(cancel: &AtomicBool) -> Result<()> {
    if cancel.load(Ordering::Relaxed) {
        Err(SynthesisError::Cancelled.into())
    } else {
        Ok(())
    }
}

fn is_cancelled(err: &anyhow::Error) -> bool {
    err.downcast_ref::<SynthesisError>()
        .is_some_and(|e| matches!(e, SynthesisError::Cancelled))
        || matches!(
            lokalbot_ai::ai_error(err),
            Some(lokalbot_ai::AiError::Cancelled)
        )
}
