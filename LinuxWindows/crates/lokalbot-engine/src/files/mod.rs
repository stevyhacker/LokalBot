pub mod documents;
pub mod image_sizing;
pub mod media;
pub mod moments;
pub mod pacing;
pub mod pass;
pub mod pdf;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use lokalbot_ai::catalog;
use lokalbot_ai::media_embedder::MediaEmbedder;
use lokalbot_core::files::change_filter::{Answers, ChangeFacts, ChangeFilter};
use lokalbot_core::files::costs::{FolderEstimate, MeasuredCosts, Measures};
use lokalbot_core::files::crawler::{crawl, is_readable_folder};
use lokalbot_core::files::index::FileIndex;
use lokalbot_core::files::search::FileReader;
use lokalbot_core::files::{self, IndexOptions, is_inside, real_path};
use lokalbot_core::{LibraryPaths, Settings};
use parking_lot::Mutex;

use crate::models::{Models, RUNTIME_ID};
use crate::{EngineEvent, Shared};

pub const NEW_FILES_LIMIT: usize = 50;
const CHANGE_DELAY: Duration = Duration::from_secs(5);
const CONDITIONS_TICK: Duration = Duration::from_secs(30);
const RELEASE_TICK: Duration = Duration::from_secs(120);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PauseReason {
    Recording,
    LowPower,
    Warm,
}

impl PauseReason {
    pub fn current(is_recording: bool) -> Option<Self> {
        if is_recording {
            return Some(Self::Recording);
        }
        let power = lokalbot_platform::power::current();
        if power.saving_power {
            return Some(Self::LowPower);
        }
        power.is_hot.then_some(Self::Warm)
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub enum FileSearchState {
    #[default]
    Off,
    NoFolders,
    Downloading,
    Indexing {
        done: usize,
        total: usize,
    },
    FinishingLongFiles {
        left: usize,
    },
    Paused(PauseReason),
    WaitingForPower {
        left: usize,
    },
    Ready,
    Failed(String),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FileSearchTotals {
    pub searchable: usize,
    pub pending: usize,
    pub failed: usize,
    pub skipped: usize,
    pub index_bytes: u64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PassReport {
    pub files_read: usize,
    pub model_seconds: f64,
    pub wall_seconds: f64,
    pub rested_seconds: f64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FileSearchStatus {
    pub state: FileSearchState,
    pub totals: FileSearchTotals,
    pub last_pass: Option<PassReport>,
    pub seconds_left: Option<f64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Configuration {
    enabled: bool,
    folders: Vec<String>,
    includes_media: bool,
    reads_on_battery: bool,
}

impl Configuration {
    fn from_settings(settings: &Settings) -> Self {
        Self {
            enabled: settings.file_search_enabled,
            folders: settings.file_search_folders.clone(),
            includes_media: settings.file_search_includes_media,
            reads_on_battery: settings.file_search_reads_on_battery,
        }
    }

    fn is_available(&self) -> bool {
        self.enabled && !self.folders.is_empty()
    }
}

enum Message {
    Settings(Box<Settings>),
    FoldersChanged,
    ConditionsChanged,
    PassFinished,
    Shutdown,
}

#[derive(Clone)]
pub struct FileSearch {
    sender: Sender<Message>,
}

impl FileSearch {
    pub(crate) fn start(shared: Arc<Shared>, models: Models) -> Self {
        let (sender, receiver) = unbounded();
        let control = Control {
            shared,
            models,
            sender: sender.clone(),
            configuration: Configuration::default(),
            status: Arc::new(Mutex::new(FileSearchStatus::default())),
            stop: Arc::new(AtomicBool::new(false)),
            applied: false,
            pass_running: false,
            pass_wanted: false,
            watcher: None,
            change_deadline: None,
            pass: None,
        };
        let spawned = std::thread::Builder::new()
            .name("lokalbot-files".into())
            .spawn(move || control.run(receiver));
        if let Err(err) = spawned {
            log::warn!("could not start file search: {err}");
        }
        Self { sender }
    }

    pub(crate) fn settings_changed(&self, settings: &Settings) {
        let _ = self
            .sender
            .send(Message::Settings(Box::new(settings.clone())));
    }

    pub(crate) fn conditions_changed(&self) {
        let _ = self.sender.send(Message::ConditionsChanged);
    }

    pub(crate) fn shutdown(&self) {
        let _ = self.sender.send(Message::Shutdown);
    }
}

struct Control {
    shared: Arc<Shared>,
    models: Models,
    sender: Sender<Message>,
    configuration: Configuration,
    status: Arc<Mutex<FileSearchStatus>>,
    stop: Arc<AtomicBool>,
    applied: bool,
    pass_running: bool,
    pass_wanted: bool,
    watcher: Option<notify::RecommendedWatcher>,
    change_deadline: Option<Instant>,
    pass: Option<std::thread::JoinHandle<()>>,
}

impl Control {
    fn run(mut self, receiver: Receiver<Message>) {
        self.apply(Configuration::from_settings(&self.shared.settings()));
        let mut last_release = Instant::now();
        loop {
            let message = if self.configuration.enabled {
                let wait = self.change_deadline.map_or(CONDITIONS_TICK, |deadline| {
                    deadline
                        .saturating_duration_since(Instant::now())
                        .min(CONDITIONS_TICK)
                });
                match receiver.recv_timeout(wait) {
                    Ok(message) => Some(message),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            } else {
                match receiver.recv() {
                    Ok(message) => Some(message),
                    Err(_) => return,
                }
            };
            match message {
                Some(Message::Settings(settings)) => {
                    self.apply(Configuration::from_settings(&settings));
                }
                Some(Message::FoldersChanged) => {
                    if self.configuration.is_available() {
                        self.change_deadline = Some(Instant::now() + CHANGE_DELAY);
                    }
                }
                Some(Message::ConditionsChanged) => self.conditions_changed(),
                Some(Message::PassFinished) => self.pass_finished(),
                Some(Message::Shutdown) => {
                    self.stop.store(true, Ordering::Relaxed);
                    self.watcher = None;
                    if let Some(pass) = self.pass.take() {
                        let _ = pass.join();
                    }
                    return;
                }
                None => self.conditions_changed(),
            }
            if self
                .change_deadline
                .is_some_and(|deadline| deadline <= Instant::now())
            {
                self.change_deadline = None;
                self.request_pass();
            }
            if last_release.elapsed() >= RELEASE_TICK {
                last_release = Instant::now();
                FileReader::shared(self.shared.library.paths().root()).release_if_idle();
            }
        }
    }

    fn paths(&self) -> &LibraryPaths {
        self.shared.library.paths()
    }

    fn publish(&self) {
        let status = self.status.lock().clone();
        self.shared.emit(EngineEvent::Files(status));
    }

    fn set_state(&self, state: FileSearchState) {
        self.status.lock().state = state;
        self.publish();
    }

    fn pause_reason(&self) -> Option<PauseReason> {
        PauseReason::current(self.shared.recording_active.load(Ordering::Relaxed))
    }

    fn big_reads_wait_for_power(&self) -> bool {
        !self.configuration.reads_on_battery && lokalbot_platform::power::current().on_battery
    }

    fn apply(&mut self, next: Configuration) {
        let previous = std::mem::replace(&mut self.configuration, next.clone());
        let folders = next.enabled.then_some(next.folders.as_slice());
        if let Err(err) = files::access::refresh(self.paths(), folders) {
            log::warn!("file search: the agents' folder list wasn't written: {err:#}");
        }
        if !next.enabled {
            if previous.enabled || self.status.lock().state != FileSearchState::Off {
                self.turn_off();
            }
            return;
        }
        if next == previous && self.applied {
            return;
        }
        self.applied = true;
        if next.folders != previous.folders
            || next.includes_media != previous.includes_media
            || self.watcher.is_none()
        {
            self.watcher = start_watcher(&next.folders, next.includes_media, self.sender.clone());
        }
        if next.folders.is_empty() {
            self.stop.store(true, Ordering::Relaxed);
            self.set_state(FileSearchState::NoFolders);
            return;
        }
        if previous.reads_on_battery && !next.reads_on_battery {
            self.stop.store(true, Ordering::Relaxed);
        }
        self.request_pass();
    }

    fn conditions_changed(&mut self) {
        if !self.configuration.is_available() {
            return;
        }
        let state = self.status.lock().state.clone();
        if let Some(reason) = self.pause_reason() {
            self.stop.store(true, Ordering::Relaxed);
            if !self.pass_running {
                self.set_state(FileSearchState::Paused(reason));
            }
        } else if matches!(state, FileSearchState::WaitingForPower { .. }) {
            if !self.big_reads_wait_for_power() {
                self.request_pass();
            }
        } else if matches!(state, FileSearchState::Paused(_)) || self.pass_wanted {
            self.request_pass();
        }
    }

    fn turn_off(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if self.status.lock().state == FileSearchState::Downloading {
            self.models.cancel(catalog::PROJECTOR_ID);
        }
        self.watcher = None;
        self.change_deadline = None;
        self.pass_wanted = false;
        if let Some(pass) = self.pass.take() {
            let _ = pass.join();
            self.pass_running = false;
        }
        let root = self.paths().root().to_path_buf();
        FileReader::shared(&root).close();
        let directory = files::index_dir(&root);
        match std::fs::remove_dir_all(&directory) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                log::warn!("file search: the index wasn't deleted: {err}");
            }
            _ => {}
        }
        *self.status.lock() = FileSearchStatus::default();
        self.applied = false;
        self.publish();
    }

    fn request_pass(&mut self) {
        if !self.configuration.is_available() {
            return;
        }
        self.pass_wanted = true;
        if self.pass_running {
            return;
        }
        self.start_next_pass();
    }

    fn start_next_pass(&mut self) {
        self.pass_wanted = false;
        if let Some(reason) = self.pause_reason() {
            self.set_state(FileSearchState::Paused(reason));
            return;
        }
        self.pass_running = true;
        self.stop.store(false, Ordering::Relaxed);
        let run = PassRun {
            shared: self.shared.clone(),
            models: self.models.clone(),
            configuration: self.configuration.clone(),
            status: self.status.clone(),
            stop: self.stop.clone(),
        };
        let sender = self.sender.clone();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-files-pass".into())
            .spawn(move || {
                run.run();
                let _ = sender.send(Message::PassFinished);
            });
        match spawned {
            Ok(handle) => {
                if let Some(old) = self.pass.replace(handle) {
                    let _ = old.join();
                }
            }
            Err(err) => {
                self.pass_running = false;
                self.set_state(FileSearchState::Failed(err.to_string()));
            }
        }
    }

    fn pass_finished(&mut self) {
        self.pass_running = false;
        {
            let mut status = self.status.lock();
            status.seconds_left = None;
            if matches!(
                status.state,
                FileSearchState::Indexing { .. } | FileSearchState::FinishingLongFiles { .. }
            ) {
                status.state = FileSearchState::Ready;
            }
        }
        self.publish();
        if self.pass_wanted && self.configuration.is_available() {
            self.start_next_pass();
        }
    }
}

fn start_watcher(
    folders: &[String],
    includes_media: bool,
    sender: Sender<Message>,
) -> Option<notify::RecommendedWatcher> {
    use notify::{RecursiveMode, Watcher as _};
    let existing: Vec<&String> = folders.iter().filter(|f| Path::new(f).exists()).collect();
    if existing.is_empty() {
        return None;
    }
    let filter = ChangeFilter::new(
        folders,
        IndexOptions::for_settings(includes_media),
        files::home_dir(),
    );
    let mut answers = Answers::default();
    let mut answers_from = Instant::now();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let Ok(event) = event else {
            return;
        };
        if matches!(event.kind, notify::EventKind::Access(_)) {
            return;
        }
        if answers_from.elapsed() > ANSWERS_LAST {
            answers = Answers::default();
            answers_from = Instant::now();
        }
        let facts = change_facts(&event);
        if event
            .paths
            .iter()
            .any(|path| filter.matters(path, facts(path), &mut answers))
        {
            let _ = sender.send(Message::FoldersChanged);
        }
    })
    .map_err(|err| log::warn!("file search: can't watch the folders: {err}"))
    .ok()?;
    for folder in existing {
        if let Err(err) = watcher.watch(Path::new(folder), RecursiveMode::Recursive) {
            log::warn!("file search: can't watch a folder: {err}");
        }
    }
    Some(watcher)
}

const ANSWERS_LAST: Duration = Duration::from_secs(2);

fn change_facts(event: &notify::Event) -> impl Fn(&Path) -> ChangeFacts + use<> {
    use notify::EventKind::{Create, Modify, Remove};
    use notify::event::{CreateKind, ModifyKind, RemoveKind};
    let lost_track = event.need_rescan();
    let (said_folder, came_or_went, arrived_whole) = match event.kind {
        Create(CreateKind::File) | Remove(RemoveKind::File) => (Some(false), true, false),
        Create(CreateKind::Folder) | Remove(RemoveKind::Folder) => (Some(true), true, false),
        Create(_) | Remove(_) => (None, true, false),
        Modify(ModifyKind::Name(_)) => (None, true, true),
        _ => (None, false, false),
    };
    move |path| ChangeFacts {
        lost_track,
        is_folder: said_folder.or_else(|| std::fs::metadata(path).ok().map(|m| m.is_dir())),
        came_or_went,
        arrived_whole,
    }
}

struct PassRun {
    shared: Arc<Shared>,
    models: Models,
    configuration: Configuration,
    status: Arc<Mutex<FileSearchStatus>>,
    stop: Arc<AtomicBool>,
}

impl PassRun {
    fn publish(&self) {
        let status = self.status.lock().clone();
        self.shared.emit(EngineEvent::Files(status));
    }

    fn set_state(&self, state: FileSearchState) {
        self.status.lock().state = state;
        self.publish();
    }

    fn pause_state(&self) -> FileSearchState {
        PauseReason::current(self.shared.recording_active.load(Ordering::Relaxed))
            .map_or(FileSearchState::Ready, FileSearchState::Paused)
    }

    fn refresh_totals(&self, index: &FileIndex) {
        let Ok(counts) = index.counts() else {
            return;
        };
        let mut totals = FileSearchTotals {
            index_bytes: index.size_on_disk(),
            ..FileSearchTotals::default()
        };
        for states in counts.by_kind_and_state.values() {
            let count = |state: &str| states.get(state).copied().unwrap_or(0);
            totals.searchable += count("done") + count("partial");
            totals.pending += count("pending");
            totals.failed += count("failed");
            totals.skipped += count("skipped");
        }
        self.status.lock().totals = totals;
        self.publish();
    }

    fn run(self) {
        lower_this_threads_priority();
        let root = self.shared.library.paths().root().to_path_buf();
        let directory = files::index_dir(&root);
        let index = match FileIndex::open(&directory) {
            Ok(index) => index,
            Err(err) => {
                self.set_state(FileSearchState::Failed(format!(
                    "Couldn’t read the chosen folders: {err:#}"
                )));
                return;
            }
        };
        if let Err(err) = self.pass(&index, &root) {
            log::warn!("file search: pass stopped: {err:#}");
            self.set_state(FileSearchState::Failed(format!(
                "Indexing stopped: {err:#}"
            )));
        }
        FileReader::shared(&root).mark_stale();
    }

    fn pass(&self, index: &FileIndex, root: &Path) -> Result<()> {
        let started = Instant::now();
        let options = IndexOptions::for_settings(self.configuration.includes_media);
        let (waiting, fresh) = sync(index, &self.configuration.folders, &options)?;
        self.refresh_totals(index);
        if waiting == 0 {
            self.set_state(FileSearchState::Ready);
            return Ok(());
        }
        if self.stop.load(Ordering::Relaxed) {
            self.set_state(self.pause_state());
            return Ok(());
        }
        let reads_on_battery = self.configuration.reads_on_battery;
        let waits_for_power =
            move || !reads_on_battery && lokalbot_platform::power::current().on_battery;
        let mut only: Option<HashSet<i64>> = None;
        if waits_for_power() {
            if fresh.is_empty() {
                self.set_state(FileSearchState::WaitingForPower { left: waiting });
                return Ok(());
            }
            only = Some(fresh);
        }

        let needs = [
            catalog::EMBEDDING_MODEL_ID.to_string(),
            catalog::PROJECTOR_ID.to_string(),
            RUNTIME_ID.to_string(),
        ];
        if !self.models.missing(&needs).is_empty() {
            self.set_state(FileSearchState::Downloading);
            if let Err(err) = self.models.ensure(&needs, true) {
                self.set_state(FileSearchState::Failed(format!(
                    "The image and text model couldn’t start: {err:#}"
                )));
                return Ok(());
            }
        }
        let embedder = match MediaEmbedder::start(&self.shared.runtime) {
            Ok(embedder) => embedder,
            Err(err) => {
                log::warn!("file search: the media embedder did not start: {err:#}");
                self.set_state(FileSearchState::Failed(format!(
                    "The image and text model couldn’t start: {err:#}"
                )));
                return Ok(());
            }
        };

        let total = only.as_ref().map_or(waiting, HashSet::len);
        self.set_state(FileSearchState::Indexing { done: 0, total });
        let scratch = std::env::temp_dir().join(format!(
            "lokalbot-files-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4().simple()
        ));
        let mut words = ScreenshotWords::new(self.shared.library.paths());
        let mut read_pass = pass::Pass::new(index, &options, &embedder, &mut words, &scratch);
        read_pass.check_model()?;
        let big_read = only.is_none();
        let mut pacer = pacing::Pacer::live();
        let reading = Instant::now();
        let stop = self.stop.clone();
        let mut last_progress = Instant::now() - Duration::from_secs(1);
        let mut progress = |update: pass::PassProgress| match update {
            pass::PassProgress::Files { done, total } => {
                if done < total && last_progress.elapsed() < Duration::from_millis(250) {
                    return;
                }
                last_progress = Instant::now();
                {
                    let mut status = self.status.lock();
                    status.state = FileSearchState::Indexing { done, total };
                    if done >= 10 && total > done {
                        status.seconds_left = Some(
                            reading.elapsed().as_secs_f64() / done as f64 * (total - done) as f64,
                        );
                    } else if done >= total {
                        status.seconds_left = None;
                    }
                }
                self.publish();
            }
            pass::PassProgress::LongFiles { left } => {
                self.status.lock().state = FileSearchState::FinishingLongFiles { left };
                self.publish();
            }
        };
        let (read, mut model_seconds) = {
            let stop = stop.clone();
            let mut should_stop = || {
                if stop.load(Ordering::Relaxed) || (big_read && waits_for_power()) {
                    return true;
                }
                let stop = stop.clone();
                pacer.rest_between_jobs(&move || stop.load(Ordering::Relaxed));
                self.stop.load(Ordering::Relaxed)
            };
            read_pass.run(only.as_ref(), &mut should_stop, &mut progress)?
        };
        if big_read {
            let stop = stop.clone();
            let mut should_stop = || {
                if stop.load(Ordering::Relaxed) || waits_for_power() {
                    return true;
                }
                let stop = stop.clone();
                pacer.rest_between_jobs(&move || stop.load(Ordering::Relaxed));
                self.stop.load(Ordering::Relaxed)
            };
            if !should_stop() {
                model_seconds += read_pass.finish_long_files(&mut should_stop, &mut progress)?;
            }
        }
        let left = index.pending_count()? + index.unfinished_count()?.0;
        let report = PassReport {
            files_read: read,
            model_seconds,
            wall_seconds: started.elapsed().as_secs_f64(),
            rested_seconds: pacer.rested,
        };
        if read > 0 {
            log::info!(
                "file search: read {read} files in {:.0} s (model {:.0} s, rested {:.0} s)",
                report.wall_seconds,
                report.model_seconds,
                report.rested_seconds
            );
        }
        {
            let mut status = self.status.lock();
            status.last_pass = Some(report);
            status.seconds_left = None;
        }
        let _ = std::fs::remove_dir_all(&scratch);
        FileReader::shared(root).mark_stale();
        self.refresh_totals(index);
        if self.stop.load(Ordering::Relaxed) {
            self.set_state(self.pause_state());
        } else if left > 0 && waits_for_power() {
            self.set_state(FileSearchState::WaitingForPower { left });
        } else {
            self.set_state(FileSearchState::Ready);
        }
        Ok(())
    }
}

fn sync(
    index: &FileIndex,
    folders: &[String],
    options: &IndexOptions,
) -> Result<(usize, HashSet<i64>)> {
    index.prune(folders)?;
    let readable: Vec<String> = folders
        .iter()
        .filter(|f| is_readable_folder(Path::new(f)))
        .cloned()
        .collect();
    let roots: Vec<PathBuf> = readable.iter().map(PathBuf::from).collect();
    let report = crawl(&roots, options, &mut |_| {});
    let summary = index.sync(&readable, &report.candidates)?;
    let waiting = index.pending_count()? + index.unfinished_count()?.0;
    let fresh = if summary.queued.len() <= NEW_FILES_LIMIT {
        summary.queued.into_iter().collect()
    } else {
        HashSet::new()
    };
    Ok((waiting, fresh))
}

struct ScreenshotWords {
    paths: LibraryPaths,
    engine: Option<lokalbot_ai::ocr::OcrEngine>,
    tried: bool,
}

impl ScreenshotWords {
    fn new(paths: &LibraryPaths) -> Self {
        Self {
            paths: paths.clone(),
            engine: None,
            tried: false,
        }
    }
}

impl pass::ReadText for ScreenshotWords {
    fn text_of(&mut self, rgb: &image_sizing::Rgb) -> String {
        if !self.tried {
            self.tried = true;
            if lokalbot_ai::ocr::is_ready(&self.paths) {
                match lokalbot_ai::ocr::OcrEngine::load(&self.paths) {
                    Ok(engine) => self.engine = Some(engine),
                    Err(err) => log::debug!("file search: no OCR: {err:#}"),
                }
            }
        }
        let Some(engine) = &self.engine else {
            return String::new();
        };
        let mut rgba = Vec::with_capacity(rgb.pixels.len() / 3 * 4);
        for pixel in rgb.pixels.as_chunks::<3>().0 {
            rgba.extend_from_slice(pixel);
            rgba.push(255);
        }
        engine
            .recognize(&rgba, rgb.width as u32, rgb.height as u32)
            .unwrap_or_default()
    }
}

pub(crate) fn lower_this_threads_priority() {
    #[cfg(target_os = "linux")]
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS, 0, 10);
    }
    #[cfg(windows)]
    unsafe {
        use windows_sys::Win32::System::Threading::{
            GetCurrentThread, SetThreadPriority, THREAD_PRIORITY_BELOW_NORMAL,
        };
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    }
}

struct LiveMeasures;

impl Measures for LiveMeasures {
    fn pages(&self, path: &str) -> usize {
        pdf::page_count(Path::new(path))
    }

    fn duration(&self, path: &str) -> f64 {
        media::duration(Path::new(path))
    }
}

pub fn estimate(
    paths: &LibraryPaths,
    folders: &[String],
    chosen: &[String],
    includes_media: bool,
    progress: &mut dyn FnMut(usize),
) -> FolderEstimate {
    let options = IndexOptions::for_settings(includes_media);
    let unreadable: Vec<String> = folders
        .iter()
        .filter(|f| !is_readable_folder(Path::new(f)))
        .cloned()
        .collect();
    let readable: Vec<PathBuf> = folders
        .iter()
        .filter(|f| !unreadable.contains(f))
        .map(PathBuf::from)
        .collect();
    let report = crawl(&readable, &options, progress);
    let indexed: Vec<String> = chosen
        .iter()
        .flat_map(|folder| [folder.clone(), real_path(folder)])
        .collect();
    let candidates: Vec<_> = report
        .candidates
        .into_iter()
        .filter(|file| !indexed.iter().any(|folder| is_inside(&file.path, folder)))
        .collect();
    let measured = MeasuredCosts::load(&files::index_dir(paths.root()));
    let mut estimate = FolderEstimate::of(&candidates, &options, &measured.costs(), &LiveMeasures);
    estimate.rough = measured.is_unmeasured();
    estimate.unreadable = unreadable;
    estimate.download_bytes = missing_download_bytes(paths);
    estimate
}

pub fn missing_download_bytes(paths: &LibraryPaths) -> u64 {
    [catalog::embedding_entry(), catalog::projector_entry()]
        .into_iter()
        .filter(|entry| !catalog::is_downloaded(paths, entry))
        .map(|entry| entry.size_bytes)
        .sum()
}

pub fn suggested_folders(chosen: &[String]) -> Vec<(String, String)> {
    let Some(dirs) = directories::UserDirs::new() else {
        return Vec::new();
    };
    [
        ("Documents", dirs.document_dir()),
        ("Desktop", dirs.desktop_dir()),
        ("Downloads", dirs.download_dir()),
    ]
    .into_iter()
    .filter_map(|(name, folder)| {
        let folder = folder?.to_string_lossy().into_owned();
        (Path::new(&folder).is_dir()
            && !chosen
                .iter()
                .any(|known| known == &folder || is_inside(&folder, known)))
        .then(|| (name.to_string(), folder))
    })
    .collect()
}

pub fn reads_video_frames() -> bool {
    media::ffmpeg().is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_watcher_event_says_what_it_can_and_the_path_says_the_rest() {
        use notify::event::{CreateKind, EventKind, Flag, ModifyKind, RemoveKind, RenameMode};
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("notes.md");
        std::fs::write(&file, "x").unwrap();
        let gone = dir.path().join("gone");
        let facts = |kind: EventKind, path: &Path| change_facts(&notify::Event::new(kind))(path);

        let made = facts(EventKind::Create(CreateKind::Folder), &gone);
        assert_eq!((made.is_folder, made.came_or_went), (Some(true), true));
        assert!(!made.arrived_whole);
        let removed = facts(EventKind::Remove(RemoveKind::File), &gone);
        assert_eq!(
            (removed.is_folder, removed.came_or_went),
            (Some(false), true)
        );
        let written = facts(EventKind::Modify(ModifyKind::Any), &file);
        assert_eq!(
            (written.is_folder, written.came_or_went),
            (Some(false), false)
        );
        let folder = facts(EventKind::Modify(ModifyKind::Any), dir.path());
        assert_eq!(folder.is_folder, Some(true));
        assert_eq!(
            facts(EventKind::Remove(RemoveKind::Any), &gone).is_folder,
            None
        );
        let moved = facts(
            EventKind::Modify(ModifyKind::Name(RenameMode::To)),
            dir.path(),
        );
        assert!(moved.arrived_whole && moved.came_or_went);
        let dropped = notify::Event::new(EventKind::Other).set_flag(Flag::Rescan);
        assert!(change_facts(&dropped)(&file).lost_track);
    }

    #[test]
    fn syncing_finds_a_few_new_files_or_a_big_read() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("docs");
        std::fs::create_dir_all(&root).unwrap();
        for i in 0..3 {
            std::fs::write(root.join(format!("n{i}.txt")), "x").unwrap();
        }
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let folders = [root.to_string_lossy().into_owned()];
        let options = IndexOptions::default();
        let (waiting, fresh) = sync(&index, &folders, &options).unwrap();
        assert_eq!((waiting, fresh.len()), (3, 3));
        let (waiting, fresh) = sync(&index, &folders, &options).unwrap();
        assert_eq!((waiting, fresh.len()), (3, 0));
        for i in 0..(NEW_FILES_LIMIT + 1) {
            std::fs::write(root.join(format!("m{i}.txt")), "x").unwrap();
        }
        let (waiting, fresh) = sync(&index, &folders, &options).unwrap();
        assert_eq!((waiting, fresh.len()), (3 + NEW_FILES_LIMIT + 1, 0));
        let (waiting, _) = sync(&index, &[], &options).unwrap();
        assert_eq!(waiting, 0);
    }

    #[test]
    fn a_missing_folder_keeps_its_files() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("drive");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("a.txt"), "x").unwrap();
        let index = FileIndex::open(&dir.path().join("index")).unwrap();
        let folders = [root.to_string_lossy().into_owned()];
        let options = IndexOptions::default();
        assert_eq!(sync(&index, &folders, &options).unwrap().0, 1);
        std::fs::remove_dir_all(&root).unwrap();
        assert_eq!(sync(&index, &folders, &options).unwrap().0, 1);
    }

    #[test]
    fn estimates_ignore_what_is_already_chosen() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path().join("lib"));
        let top = dir.path().join("docs");
        std::fs::create_dir_all(top.join("old")).unwrap();
        std::fs::write(top.join("a.txt"), "x".repeat(4000)).unwrap();
        std::fs::write(top.join("old/b.txt"), "x").unwrap();
        let top_text = top.to_string_lossy().into_owned();
        let old = top.join("old").to_string_lossy().into_owned();
        let estimate = estimate(
            &paths,
            &[top_text, "/no/such/folder".into()],
            &[old],
            true,
            &mut |_| {},
        );
        assert_eq!(estimate.files, 1);
        assert_eq!(estimate.documents, 1);
        assert_eq!(estimate.unreadable, ["/no/such/folder"]);
        assert!(estimate.rough);
        assert_eq!(estimate.download_bytes, 309_855_456 + 554_821_024);
    }
}
