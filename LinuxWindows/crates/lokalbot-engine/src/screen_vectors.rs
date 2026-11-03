//! Vectors of saved screens, so screen search finds a screen by what it says and
//! shows (`EmbeddingIndex` screen backfill, `ScreenImageEmbeddings`).
//!
//! Both start only once screens have been searched by meaning, so nobody downloads
//! the image model for a search they never make. Text vectors need only the
//! embedder. Picture vectors run on the media embedder Files uses, only while
//! search by meaning is on and pictures are captured (Text + visual context). A
//! capture is decrypted in memory, sized for a 280-token budget and never written
//! to disk. A vector goes with its pixels: retention clears both, and deleting a
//! capture deletes both.
//!
//! The first pass over a library is a big read, so it is paced while the person
//! uses the computer, and on battery a pass stops after the newest few dozen
//! captures: the rest wait for a charger.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use crossbeam_channel::{RecvTimeoutError, Sender, unbounded};
use lokalbot_ai::catalog;
use lokalbot_ai::media_embedder::{MediaEmbedder, MediaError, picture_model_id};
use lokalbot_ai::think::EmbeddingClient;
use lokalbot_core::ScreenContextMode;
use lokalbot_core::screen::IMAGE_KEY_BYTES;

use crate::Shared;
use crate::files::image_sizing::{self, Rgb};
use crate::files::{PauseReason, pacing};
use crate::models::{Models, RUNTIME_ID};

const IMAGE_BUDGET: u32 = 280;
const IMAGE_BATCH: usize = 16;
/// On battery, a pass reads at most this many captures, newest first.
const BATTERY_LIMIT: usize = 3 * IMAGE_BATCH;
const TEXT_BATCH: usize = 32;
/// New captures wait this long, so one pass embeds a batch of them.
const NEW_TEXT_DELAY: Duration = Duration::from_secs(15 * 60);
const FIRST_RETRY_DELAY: Duration = Duration::from_secs(60);
const MAXIMUM_RETRY_DELAY: Duration = Duration::from_secs(30 * 60);

/// The wait after a failed pass: each further failure doubles it, up to the most.
pub(crate) fn retry_delay(failures: u32) -> Duration {
    let mut delay = FIRST_RETRY_DELAY;
    for _ in 1..failures.max(1) {
        delay *= 2;
        if delay >= MAXIMUM_RETRY_DELAY {
            return MAXIMUM_RETRY_DELAY;
        }
    }
    delay.min(MAXIMUM_RETRY_DELAY)
}

/// Pictures are read only while search by meaning is on and pictures are captured
/// (Text + visual context), and only once screens have been searched by meaning.
pub(crate) fn pictures_allowed(settings: &lokalbot_core::Settings, in_use: bool) -> bool {
    in_use
        && settings.semantic_search_enabled
        && settings.screen_context_capture_mode == ScreenContextMode::TextAndVisual
}

enum Message {
    CapturesArrived,
    SearchedByMeaning,
    ConditionsChanged,
}

/// How a pass ended.
#[derive(Debug, PartialEq, Eq)]
enum PassOutcome {
    Skipped,
    Finished,
    Paused,
    /// On battery, with more left after the newest `BATTERY_LIMIT`.
    WaitingForPower,
    Failed(String),
}

#[derive(Clone)]
pub struct ScreenVectors {
    sender: Sender<Message>,
    stop: Arc<AtomicBool>,
}

impl ScreenVectors {
    pub(crate) fn start(shared: Arc<Shared>, models: Models) -> Self {
        let (sender, receiver) = unbounded();
        let stop = Arc::new(AtomicBool::new(false));
        let this = Self {
            sender: sender.clone(),
            stop: stop.clone(),
        };
        let root = shared.library.paths().root().to_path_buf();
        let hears = sender.clone();
        lokalbot_core::screen_search::observe_searches(move |searched: &Path| {
            if searched == root {
                let _ = hears.send(Message::SearchedByMeaning);
            }
        });
        let spawned = std::thread::Builder::new()
            .name("lokalbot-screen-vectors".into())
            .spawn(move || {
                crate::files::lower_this_threads_priority();
                let mut worker = Worker {
                    shared,
                    models,
                    stop,
                    in_use: false,
                    text_due: None,
                    pictures_due: None,
                    text_failures: 0,
                    picture_failures: 0,
                };
                worker.launch();
                worker.run_what_is_due();
                loop {
                    let wait = worker.next_due();
                    let message = match wait {
                        Some(wait) => match receiver.recv_timeout(wait) {
                            Ok(message) => Some(message),
                            Err(RecvTimeoutError::Timeout) => None,
                            Err(RecvTimeoutError::Disconnected) => return,
                        },
                        None => match receiver.recv() {
                            Ok(message) => Some(message),
                            Err(_) => return,
                        },
                    };
                    if worker.shared.is_shutting_down() {
                        return;
                    }
                    match message {
                        Some(Message::CapturesArrived) => worker.captures_arrived(),
                        Some(Message::SearchedByMeaning) => worker.searched_by_meaning(),
                        Some(Message::ConditionsChanged) => worker.conditions_changed(),
                        None => {}
                    }
                    worker.run_what_is_due();
                }
            });
        if let Err(err) = spawned {
            log::warn!("could not start screen vectors: {err}");
        }
        this
    }

    /// New captures were stored: one batched pass later covers them all.
    pub(crate) fn captures_arrived(&self) {
        let _ = self.sender.send(Message::CapturesArrived);
    }

    /// Settings, recording, power or heat changed.
    pub(crate) fn conditions_changed(&self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = self.sender.send(Message::ConditionsChanged);
    }
}

struct Worker {
    shared: Arc<Shared>,
    models: Models,
    stop: Arc<AtomicBool>,
    in_use: bool,
    text_due: Option<Instant>,
    pictures_due: Option<Instant>,
    text_failures: u32,
    picture_failures: u32,
}

impl Worker {
    /// Search by meaning is on, pictures are captured, and it's been used.
    fn pictures_wanted(&self) -> bool {
        pictures_allowed(&self.shared.settings(), self.in_use)
    }

    fn pause_reason(&self) -> Option<PauseReason> {
        PauseReason::current(self.shared.recording_active.load(Ordering::Relaxed))
    }

    /// Launch: catch up on what's waiting, if this library has searched by meaning.
    fn launch(&mut self) {
        let library = &self.shared.library;
        if library
            .purge_picture_vectors_except(&picture_model_id())
            .is_err()
        {
            log::debug!("screen vectors: no picture table yet");
        }
        // A search may have come before this thread was listening.
        if lokalbot_core::screen_search::was_searched_by_meaning(library.paths().root()) {
            self.searched_by_meaning();
            return;
        }
        let stale = library.has_stale_screen_vectors().unwrap_or(false);
        self.in_use = stale || library.has_screen_vectors().unwrap_or(false);
        if self.in_use {
            self.text_due = Some(Instant::now() + Duration::from_secs(60));
            self.pictures_due = Some(Instant::now() + Duration::from_secs(120));
        }
    }

    fn captures_arrived(&mut self) {
        if !self.in_use {
            self.in_use = self.shared.library.has_screen_vectors().unwrap_or(false);
        }
        if self.in_use {
            self.text_due
                .get_or_insert_with(|| Instant::now() + NEW_TEXT_DELAY);
            self.pictures_due
                .get_or_insert_with(|| Instant::now() + NEW_TEXT_DELAY);
        }
    }

    fn searched_by_meaning(&mut self) {
        self.in_use = true;
        self.text_due = Some(Instant::now());
        self.pictures_due = Some(Instant::now() + Duration::from_secs(1));
    }

    fn conditions_changed(&mut self) {
        self.stop.store(false, Ordering::Relaxed);
        if self.pictures_wanted() && self.pause_reason().is_none() {
            self.pictures_due
                .get_or_insert_with(|| Instant::now() + NEW_TEXT_DELAY);
        }
    }

    fn next_due(&self) -> Option<Duration> {
        [self.text_due, self.pictures_due]
            .into_iter()
            .flatten()
            .min()
            .map(|due| due.saturating_duration_since(Instant::now()))
    }

    fn run_what_is_due(&mut self) {
        let now = Instant::now();
        if self.text_due.is_some_and(|due| due <= now) {
            self.text_due = None;
            match self.text_pass() {
                PassOutcome::Failed(why) => {
                    self.text_failures += 1;
                    let delay = retry_delay(self.text_failures);
                    log::warn!(
                        "screen embedding backfill failed: {why}; retrying in {} s",
                        delay.as_secs()
                    );
                    self.text_due = Some(Instant::now() + delay);
                }
                PassOutcome::Paused => {
                    // A meeting is recording: come back after it.
                    self.text_due = Some(Instant::now() + FIRST_RETRY_DELAY);
                }
                _ => self.text_failures = 0,
            }
        }
        if self.pictures_due.is_some_and(|due| due <= Instant::now()) {
            self.pictures_due = None;
            self.stop.store(false, Ordering::Relaxed);
            match self.picture_pass() {
                PassOutcome::Failed(why) => {
                    self.picture_failures += 1;
                    let delay = retry_delay(self.picture_failures);
                    log::warn!(
                        "screen image embedding failed: {why}; retrying in {} s",
                        delay.as_secs()
                    );
                    self.pictures_due = Some(Instant::now() + delay);
                }
                PassOutcome::Finished | PassOutcome::WaitingForPower => self.picture_failures = 0,
                PassOutcome::Paused | PassOutcome::Skipped => {}
            }
        }
    }

    /// Embeds captures' text until none is left. Needs only the embedder, which
    /// search by meaning already downloaded.
    fn text_pass(&mut self) -> PassOutcome {
        let settings = self.shared.settings();
        if !settings.semantic_search_enabled
            || !self
                .models
                .missing(&self.models.embedding_requirements())
                .is_empty()
        {
            return PassOutcome::Skipped;
        }
        let embedder = EmbeddingClient::new(&self.shared.runtime);
        loop {
            if self.shared.is_shutting_down() {
                return PassOutcome::Paused;
            }
            if self.shared.capture_active.load(Ordering::Relaxed) {
                return PassOutcome::Paused;
            }
            let batch = match self
                .shared
                .library
                .screen_documents_without_vectors(TEXT_BATCH)
            {
                Ok(batch) => batch,
                Err(err) => return PassOutcome::Failed(format!("{err:#}")),
            };
            if batch.is_empty() {
                return PassOutcome::Finished;
            }
            let texts: Vec<String> = batch.iter().map(|doc| doc.text.clone()).collect();
            let vectors = match embedder.embed_documents(&texts) {
                Ok(vectors) => vectors,
                Err(err) => return PassOutcome::Failed(format!("{err:#}")),
            };
            let rows: Vec<_> = batch.into_iter().zip(vectors).collect();
            if let Err(err) = self.shared.library.store_screen_vectors(&rows) {
                return PassOutcome::Failed(format!("{err:#}"));
            }
        }
    }

    /// Embeds retained captures without a picture vector, newest first, until none
    /// are left, a pause condition appears, the embedder fails, or, on battery,
    /// `BATTERY_LIMIT` captures are through.
    fn picture_pass(&mut self) -> PassOutcome {
        if !self.pictures_wanted() {
            return PassOutcome::Skipped;
        }
        if self.pause_reason().is_some() {
            return PassOutcome::Paused;
        }
        let library = self.shared.library.clone();
        let model = picture_model_id();
        match library.screens_without_picture_vectors(&model, 1) {
            Ok(waiting) if waiting.is_empty() => return PassOutcome::Finished,
            Ok(_) => {}
            Err(err) => return PassOutcome::Failed(format!("{err:#}")),
        }
        let key = match crate::secrets::screen_image_key(false) {
            Ok(key) => key,
            Err(err) => {
                return PassOutcome::Failed(format!(
                    "the screenshot key is not available: {err:#}"
                ));
            }
        };
        let session = match self.start_session() {
            Ok(session) => session,
            Err(err) => {
                return PassOutcome::Failed(format!("the image model did not start: {err:#}"));
            }
        };
        let mut pacer = pacing::Pacer::live();
        let mut tried = 0;
        loop {
            if self.shared.is_shutting_down()
                || self.stop.load(Ordering::Relaxed)
                || !self.pictures_wanted()
                || self.pause_reason().is_some()
            {
                return PassOutcome::Paused;
            }
            let batch = match library.screens_without_picture_vectors(&model, IMAGE_BATCH) {
                Ok(batch) => batch,
                Err(err) => return PassOutcome::Failed(format!("{err:#}")),
            };
            if batch.is_empty() {
                return PassOutcome::Finished;
            }
            if tried >= BATTERY_LIMIT && lokalbot_platform::power::current().on_battery {
                return PassOutcome::WaitingForPower;
            }
            for (id, path) in &batch {
                match embed_capture(&library, &key, path, &session) {
                    Embedded::Vector(vector) => {
                        // The pixels may be gone by now: `store` checks.
                        if let Err(err) =
                            library.store_picture_vector(&model, *id, path, Some(&vector))
                        {
                            return PassOutcome::Failed(format!(
                                "could not store picture vectors: {err:#}"
                            ));
                        }
                    }
                    Embedded::Unreadable => {
                        if let Err(err) = library.store_picture_vector(&model, *id, path, None) {
                            return PassOutcome::Failed(format!(
                                "could not store picture vectors: {err:#}"
                            ));
                        }
                    }
                    Embedded::Unavailable(why) => return PassOutcome::Failed(why),
                }
            }
            tried += batch.len();
            let stop = self.stop.clone();
            pacer.rest_between_jobs(&move || stop.load(Ordering::Relaxed));
        }
    }

    /// The first picture pass downloads the projector, as the notice says.
    fn start_session(&self) -> Result<MediaEmbedder> {
        let needs = [
            catalog::EMBEDDING_MODEL_ID.to_string(),
            catalog::PROJECTOR_ID.to_string(),
            RUNTIME_ID.to_string(),
        ];
        if !self.models.ensure(&needs, true)? {
            return Err(anyhow!("the image model isn't downloaded"));
        }
        MediaEmbedder::start(&self.shared.runtime)
    }
}

pub enum Embedded {
    Vector(Vec<f32>),
    /// The pixels could not be read or the server rejected them: marked, so a
    /// broken capture isn't tried on every pass.
    Unreadable,
    Unavailable(String),
}

/// Decrypts in memory: nothing is written to disk.
pub fn embed_capture(
    library: &lokalbot_core::Library,
    key: &[u8; IMAGE_KEY_BYTES],
    stored_path: &str,
    session: &MediaEmbedder,
) -> Embedded {
    let Some(path) = library.screen_image_file(stored_path) else {
        return Embedded::Unreadable;
    };
    let Ok(bytes) = lokalbot_core::screen::read_image(key, &path) else {
        return Embedded::Unreadable;
    };
    let Ok(image) = image::load_from_memory(&bytes) else {
        return Embedded::Unreadable;
    };
    let rgb = image.to_rgb8();
    let sized = Rgb {
        width: rgb.width() as usize,
        height: rgb.height() as usize,
        pixels: rgb.into_raw(),
    };
    let Ok(png) = image_sizing::png(&sized, IMAGE_BUDGET) else {
        return Embedded::Unreadable;
    };
    match session.embed_image(&png) {
        Ok(vector) => Embedded::Vector(vector),
        Err(MediaError::Rejected(_)) => Embedded::Unreadable,
        Err(err) => Embedded::Unavailable(err.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_model_id_is_the_macs() {
        assert_eq!(
            picture_model_id(),
            "embeddinggemma-2-q8-mmproj-q8-image280-v1"
        );
    }

    #[test]
    fn pictures_need_visual_context_search_by_meaning_and_a_first_search() {
        let mut settings = lokalbot_core::Settings {
            screen_context_capture_mode: ScreenContextMode::TextAndVisual,
            semantic_search_enabled: true,
            ..Default::default()
        };
        assert!(pictures_allowed(&settings, true));
        assert!(
            !pictures_allowed(&settings, false),
            "no search by meaning yet"
        );
        settings.semantic_search_enabled = false;
        assert!(!pictures_allowed(&settings, true));
        settings.semantic_search_enabled = true;
        settings.screen_context_capture_mode = ScreenContextMode::Text;
        assert!(!pictures_allowed(&settings, true));
        settings.screen_context_capture_mode = ScreenContextMode::ActivityOnly;
        assert!(!pictures_allowed(&settings, true));
    }

    #[test]
    fn retries_double_up_to_half_an_hour() {
        assert_eq!(retry_delay(1), Duration::from_secs(60));
        assert_eq!(retry_delay(2), Duration::from_secs(120));
        assert_eq!(retry_delay(3), Duration::from_secs(240));
        assert_eq!(retry_delay(10), Duration::from_secs(1800));
    }
}
