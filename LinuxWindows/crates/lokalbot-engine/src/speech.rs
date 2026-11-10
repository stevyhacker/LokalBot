//! One loaded transcription model, shared by meeting processing and dictation,
//! released after two idle minutes like the macOS speech engines.
//!
//! The model is shared span by span. Dictation, the live previews and the
//! model check are answered while someone waits, so a meeting pass stands
//! aside for them between spans ([`SpeechCache::stand_aside`]).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use lokalbot_ai::remote_transcription::Client;
use lokalbot_core::Settings;
use lokalbot_core::remote_transcription::{RemoteTranscription, request_key};
use parking_lot::Mutex;

use lokalbot_speech::models::{accepts_vocabulary, is_remote};
use lokalbot_speech::{SpeechServer, Transcriber};

use crate::Shared;

const IDLE_UNLOAD: Duration = Duration::from_secs(120);

#[derive(Default)]
pub struct SpeechCache {
    loaded: Mutex<Option<Loaded>>,
    /// Calls in progress that someone is waiting on.
    urgent: AtomicUsize,
    /// Dictation's known names, kept for a day or until the library changes.
    dictation_terms: Mutex<Option<(String, Vec<String>)>>,
    voice_loaded: AtomicBool,
}

struct Loaded {
    /// The model id, or the server, model and key behind a transcription server.
    model_id: String,
    transcriber: Arc<Transcriber>,
    last_used: Instant,
}

/// Counts one urgent call until dropped.
struct Urgent<'a>(&'a AtomicUsize);

impl<'a> Urgent<'a> {
    fn begin(count: &'a AtomicUsize) -> Self {
        count.fetch_add(1, Ordering::SeqCst);
        Self(count)
    }
}

impl Drop for Urgent<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// The approved server, with its key, for one transcription.
fn server_client(settings: &Settings) -> Result<Client> {
    let key = request_key(
        &settings.remote_transcription_base_url,
        &settings.openai_base_url,
        &crate::secrets::remote_transcription_api_key().unwrap_or_default(),
        || crate::secrets::openai_api_key().unwrap_or_default(),
    );
    Ok(Client::new(
        &RemoteTranscription::from_settings(settings),
        key,
    )?)
}

struct ServerClient(Client);

impl SpeechServer for ServerClient {
    fn transcribe(
        &self,
        samples: &[f32],
        language: Option<&str>,
        prompt: Option<&str>,
        cancel: &AtomicBool,
    ) -> Result<String> {
        let wav = lokalbot_audio::wav_bytes(samples, lokalbot_audio::SAMPLE_RATE);
        Ok(self.0.transcribe(&wav, language, prompt, cancel)?)
    }

    fn provides_word_timings(&self) -> bool {
        self.0.provides_word_timings()
    }

    fn transcribe_timed(
        &self,
        samples: &[f32],
        language: Option<&str>,
        prompt: Option<&str>,
        cancel: &AtomicBool,
    ) -> Result<lokalbot_core::remote_transcription::WindowTranscription> {
        let wav = lokalbot_audio::wav_bytes(samples, lokalbot_audio::SAMPLE_RATE);
        Ok(self.0.transcribe_timed(&wav, language, prompt, cancel)?)
    }
}

impl SpeechCache {
    /// Runs `f` with the transcriber for `model_id`, loading it first if
    /// needed. For work someone is waiting on: a meeting pass in progress
    /// lets it go first.
    pub fn with<T>(
        &self,
        shared: &Shared,
        model_id: &str,
        f: impl FnOnce(&Transcriber) -> Result<T>,
    ) -> Result<T> {
        let transcriber = self.transcriber(shared, model_id)?;
        // Counted once the model is in hand: while this call waits for a pass
        // to give up another model, that pass must not wait for this call.
        let _urgent = Urgent::begin(&self.urgent);
        let result = f(&transcriber);
        self.used(&transcriber);
        result
    }

    /// [`Self::with`] for a whole meeting. `f` calls [`Self::stand_aside`]
    /// between spans, so nobody waits for more than the span being decoded.
    pub fn with_in_background<T>(
        &self,
        shared: &Shared,
        model_id: &str,
        f: impl FnOnce(&Transcriber) -> Result<T>,
    ) -> Result<T> {
        let transcriber = self.transcriber(shared, model_id)?;
        let result = f(&transcriber);
        self.used(&transcriber);
        result
    }

    /// Returns once no urgent call is using the model.
    pub fn stand_aside(&self) {
        while self.urgent.load(Ordering::SeqCst) > 0 {
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The transcriber for `model_id`, loading it first if needed.
    fn transcriber(&self, shared: &Shared, model_id: &str) -> Result<Arc<Transcriber>> {
        // Checked each time, so a revoked approval counts from the next clip.
        let settings = shared.settings();
        let server = is_remote(model_id)
            .then(|| server_client(&settings))
            .transpose()?;
        let identity = match &server {
            Some(client) => format!("{model_id}|{}", client.identity()),
            None => model_id.to_string(),
        };
        let mut loaded = self.loaded.lock();
        // Two models never share memory: a call still using the other one
        // finishes first, as it did when the model was held for a whole call.
        while loaded
            .as_ref()
            .is_some_and(|l| l.model_id != identity && Arc::strong_count(&l.transcriber) > 1)
        {
            drop(loaded);
            std::thread::sleep(Duration::from_millis(50));
            loaded = self.loaded.lock();
        }
        if loaded.as_ref().is_none_or(|l| l.model_id != identity) {
            *loaded = None;
            let threads = std::thread::available_parallelism()
                .map(|n| n.get().clamp(2, 8))
                .unwrap_or(4);
            let paths = shared.library.paths();
            let transcriber = match server {
                Some(client) => Transcriber::with_server(
                    paths,
                    threads,
                    RemoteTranscription::from_settings(&settings).transcript_engine(),
                    Arc::new(ServerClient(client)),
                ),
                None => Transcriber::load(paths, model_id, threads)?,
            };
            *loaded = Some(Loaded {
                model_id: identity,
                transcriber: Arc::new(transcriber),
                last_used: Instant::now(),
            });
        }
        let entry = loaded.as_mut().expect("loaded above");
        entry.last_used = Instant::now();
        Ok(entry.transcriber.clone())
    }

    /// Restarts the idle clock when a call ends.
    fn used(&self, transcriber: &Arc<Transcriber>) {
        if let Some(entry) = self.loaded.lock().as_mut()
            && Arc::ptr_eq(&entry.transcriber, transcriber)
        {
            entry.last_used = Instant::now();
        }
    }

    /// Whether `model_id` is in memory. One still loading is not there yet.
    pub fn is_loaded(&self, model_id: &str) -> bool {
        self.loaded
            .try_lock()
            .is_some_and(|loaded| loaded.as_ref().is_some_and(|l| l.model_id == model_id))
    }

    /// Read aloud's voice model came into or left memory.
    pub fn set_voice_loaded(&self, loaded: bool) {
        self.voice_loaded.store(loaded, Ordering::Relaxed);
    }

    /// Speech models held in this process, with the role each serves. A model
    /// still loading is missed for that reading; it never blocks the caller.
    pub fn loaded_models(&self) -> Vec<(&'static str, String)> {
        let mut models = Vec::new();
        if let Some(loaded) = self.loaded.try_lock()
            && let Some(loaded) = loaded.as_ref()
            && !is_remote(loaded.model_id.split('|').next().unwrap_or_default())
        {
            models.push((
                "Speech recognition",
                loaded.transcriber.display_name().to_string(),
            ));
        }
        if self.voice_loaded.load(Ordering::Relaxed) {
            models.push(("Speech synthesis", "Kokoro 82M".to_string()));
        }
        models
    }

    /// Dictation has no meeting of its own, so prompt-capable models get recent
    /// attendee and project names beside the manual vocabulary
    /// (`AppState.dictationTranscriptionSettings`).
    pub fn dictation_prompt(&self, shared: &Shared, settings: &Settings) -> String {
        if !settings.auto_transcription_vocabulary
            || !accepts_vocabulary(&settings.transcription_model)
        {
            return settings.transcription_prompt.clone();
        }
        let meetings = shared.library.list_all_meetings().unwrap_or_default();
        let key = format!(
            "{}|{}|{:?}",
            chrono::Local::now().date_naive(),
            meetings.len(),
            meetings.iter().map(|m| m.started_at).max()
        );
        let mut cached = self.dictation_terms.lock();
        let terms = match cached.as_ref() {
            Some((cached_key, terms)) if *cached_key == key => terms.clone(),
            _ => {
                let terms =
                    lokalbot_core::vocabulary::terms(&lokalbot_core::vocabulary::recent_sources(
                        &meetings,
                        shared.library.paths(),
                        chrono::Utc::now(),
                    ));
                *cached = Some((key, terms.clone()));
                terms
            }
        };
        lokalbot_core::vocabulary::prompt(&settings.transcription_prompt, &terms)
    }

    /// Frees the model when it has not been used for a while. A call in
    /// progress holds its own reference, so a long pass is never idle.
    pub fn release_if_idle(&self) {
        if let Some(mut loaded) = self.loaded.try_lock()
            && loaded.as_ref().is_some_and(|l| {
                Arc::strong_count(&l.transcriber) == 1 && l.last_used.elapsed() > IDLE_UNLOAD
            })
        {
            *loaded = None;
        }
    }
}

/// Starts the idle-release timer.
pub fn start_idle_release(cache: Arc<SpeechCache>, shared: Arc<Shared>) {
    std::thread::spawn(move || {
        while !shared.is_shutting_down() {
            std::thread::sleep(Duration::from_secs(30));
            cache.release_if_idle();
        }
    });
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc::channel;

    use super::*;

    const MODEL: &str = lokalbot_speech::models::DEFAULT_TRANSCRIPTION_MODEL;

    struct NoWords;

    impl SpeechServer for NoWords {
        fn transcribe(
            &self,
            _samples: &[f32],
            _language: Option<&str>,
            _prompt: Option<&str>,
            _cancel: &AtomicBool,
        ) -> Result<String> {
            Ok(String::new())
        }
    }

    /// An engine whose cache already holds a transcriber under `MODEL`.
    fn loaded() -> (tempfile::TempDir, Arc<Shared>) {
        let dir = tempfile::tempdir().unwrap();
        let library =
            lokalbot_core::Library::open(lokalbot_core::LibraryPaths::new(dir.path())).unwrap();
        let shared = Shared::for_tests(library, Settings::default(), |_| {});
        let transcriber =
            Transcriber::with_server(shared.library.paths(), 1, "test".into(), Arc::new(NoWords));
        *shared.speech.loaded.lock() = Some(Loaded {
            model_id: MODEL.into(),
            transcriber: Arc::new(transcriber),
            last_used: Instant::now(),
        });
        (dir, shared)
    }

    #[test]
    fn a_dictation_is_answered_while_a_meeting_pass_has_the_model() {
        let (_dir, shared) = loaded();
        let (started, pass_started) = channel();
        let (finish, finished) = channel::<()>();
        let pass = {
            let shared = shared.clone();
            std::thread::spawn(move || {
                shared.speech.with_in_background(&shared, MODEL, |_| {
                    started.send(()).unwrap();
                    let _ = finished.recv();
                    Ok(())
                })
            })
        };
        pass_started.recv().unwrap();

        let (answered, answer) = channel();
        {
            let shared = shared.clone();
            std::thread::spawn(move || {
                let text = shared.speech.with(&shared, MODEL, |_| Ok(7));
                let _ = answered.send(text.ok());
            });
        }
        let got = answer.recv_timeout(Duration::from_secs(5));
        finish.send(()).unwrap();
        pass.join().unwrap().unwrap();
        assert_eq!(got, Ok(Some(7)), "the dictation waited for the pass to end");
    }

    #[test]
    fn a_meeting_pass_stands_aside_until_the_dictation_has_its_text() {
        let (_dir, shared) = loaded();
        let (entered, dictating) = channel();
        let (release, released) = channel::<()>();
        let dictation = {
            let shared = shared.clone();
            std::thread::spawn(move || {
                shared.speech.with(&shared, MODEL, |_| {
                    entered.send(()).unwrap();
                    let _ = released.recv();
                    Ok(())
                })
            })
        };
        dictating.recv().unwrap();

        let resumed = Arc::new(AtomicBool::new(false));
        let pass = {
            let (shared, resumed) = (shared.clone(), resumed.clone());
            std::thread::spawn(move || {
                shared.speech.stand_aside();
                resumed.store(true, Ordering::SeqCst);
            })
        };
        std::thread::sleep(Duration::from_millis(200));
        assert!(
            !resumed.load(Ordering::SeqCst),
            "the pass went on while the dictation was being transcribed"
        );
        release.send(()).unwrap();
        dictation.join().unwrap().unwrap();
        pass.join().unwrap();
        assert!(resumed.load(Ordering::SeqCst));
        // Nothing is left counted, so the next span starts at once.
        shared.speech.stand_aside();
    }

    #[test]
    fn a_call_for_another_model_waits_for_the_pass_and_does_not_stop_it() {
        let (_dir, shared) = loaded();
        let (started, pass_started) = channel();
        let (go_on, told) = channel::<()>();
        let pass = {
            let shared = shared.clone();
            std::thread::spawn(move || {
                shared.speech.with_in_background(&shared, MODEL, |_| {
                    started.send(()).unwrap();
                    let _ = told.recv();
                    // The other call is waiting for this model to be freed, so
                    // it must not make this pass wait in turn.
                    shared.speech.stand_aside();
                    Ok(())
                })
            })
        };
        pass_started.recv().unwrap();

        let (answered, answer) = channel();
        {
            let shared = shared.clone();
            std::thread::spawn(move || {
                let other = shared.speech.with(&shared, "parakeet-v3", |_| Ok(()));
                let _ = answered.send(other.is_err());
            });
        }
        assert!(
            answer.recv_timeout(Duration::from_millis(300)).is_err(),
            "the first model was dropped while the pass still used it"
        );
        go_on.send(()).unwrap();
        pass.join().unwrap().unwrap();
        // Then it tries to load its own model, which is not installed here.
        assert_eq!(answer.recv_timeout(Duration::from_secs(5)), Ok(true));
    }
}
