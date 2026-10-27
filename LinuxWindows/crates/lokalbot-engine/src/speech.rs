//! One loaded transcription model, shared by meeting processing and dictation,
//! released after two idle minutes like the macOS speech engines.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use parking_lot::Mutex;

use lokalbot_speech::Transcriber;

use crate::Shared;

const IDLE_UNLOAD: Duration = Duration::from_secs(120);

#[derive(Default)]
pub struct SpeechCache {
    loaded: Mutex<Option<Loaded>>,
}

struct Loaded {
    model_id: String,
    transcriber: Transcriber,
    last_used: Instant,
}

impl SpeechCache {
    /// Runs `f` with the transcriber for `model_id`, loading it first if needed.
    pub fn with<T>(
        &self,
        shared: &Shared,
        model_id: &str,
        f: impl FnOnce(&Transcriber) -> Result<T>,
    ) -> Result<T> {
        let mut loaded = self.loaded.lock();
        if loaded.as_ref().is_none_or(|l| l.model_id != model_id) {
            *loaded = None;
            let threads = std::thread::available_parallelism()
                .map(|n| n.get().clamp(2, 8))
                .unwrap_or(4);
            let transcriber = Transcriber::load(shared.library.paths(), model_id, threads)?;
            *loaded = Some(Loaded {
                model_id: model_id.to_string(),
                transcriber,
                last_used: Instant::now(),
            });
        }
        let entry = loaded.as_mut().expect("loaded above");
        entry.last_used = Instant::now();
        let result = f(&entry.transcriber);
        entry.last_used = Instant::now();
        result
    }

    /// Frees the model when it has not been used for a while.
    pub fn release_if_idle(&self) {
        if let Some(mut loaded) = self.loaded.try_lock()
            && loaded
                .as_ref()
                .is_some_and(|l| l.last_used.elapsed() > IDLE_UNLOAD)
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
