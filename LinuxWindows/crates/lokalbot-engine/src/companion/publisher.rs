//! Keeps the host's records equal to what the library shares
//! (`CompanionPublisher.swift`). A full reconcile builds every record,
//! publishes it, and withdraws keys that no longer exist (deleted, merged,
//! out of the history window, or a class turned off). Change hooks queue
//! narrower rebuilds, coalesced on one thread, so a burst of edits costs one
//! pass.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime};

use chrono::{NaiveDate, Utc};
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, bounded, unbounded};
use lokalbot_core::actions::OutcomeProjection;
use lokalbot_core::library::{
    META_FILE, NOTES_FILE, OUTCOME_STATE_FILE, OUTCOMES_FILE, SUMMARY_FILE, TRANSCRIPT_FILE,
};
use lokalbot_core::time::local_day;
use lokalbot_core::{Library, Meeting};
use parking_lot::Mutex;
use uuid::Uuid;

use super::builder::{self, RecordBuilder};
use super::library::{CompanionLibrary, is_shared, read_all_meetings};
use super::records::{self, Record, RecordKind};
use super::sharing::{Sharing, day_key};

/// Where built records go: the sync host while sharing is on, an in-memory
/// store in tests. Publishing an unchanged body is a no-op on the host.
pub trait RecordSink: Send + Sync {
    fn publish(&self, kind: &str, key: &str, body_json: &str) -> anyhow::Result<bool>;
    fn remove(&self, kind: &str, key: &str) -> anyhow::Result<bool>;
    fn record_keys(&self, kind: &str) -> anyhow::Result<Vec<String>>;
    fn set_manifest(&self, body_json: &str) -> anyhow::Result<()>;
}

/// What one pass changed, for logs and tests.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Report {
    pub published: usize,
    pub changed: usize,
    pub removed: usize,
    pub failed: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Context {
    pub sharing: Sharing,
    pub mac_name: String,
}

#[derive(Default)]
struct Pending {
    full: bool,
    meeting_ids: HashSet<Uuid>,
    day_keys: BTreeSet<String>,
    connections: bool,
    /// Compare the library with what the records were built from.
    rescan: bool,
}

impl Pending {
    fn is_empty(&self) -> bool {
        !self.full
            && self.meeting_ids.is_empty()
            && self.day_keys.is_empty()
            && !self.connections
            && !self.rescan
    }
}

enum Request {
    Update(Box<Context>),
    Change(Box<dyn FnOnce(&mut Pending) + Send>),
    /// Rebuild one meeting and what depends on it now.
    Now(Uuid, Sender<()>),
    /// Run whatever is queued and report it.
    #[cfg(test)]
    Flush(Sender<Report>),
    Today {
        window: chrono::Duration,
    },
    /// Look for changes the hooks don't report.
    Check,
    Stop,
}

pub struct Publisher {
    requests: Sender<Request>,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Publisher {
    pub fn start(
        library: Library,
        sink: Arc<dyn RecordSink>,
        context: Context,
        debounce: Duration,
    ) -> Self {
        let (requests, receiver) = unbounded();
        let thread = std::thread::Builder::new()
            .name("lokalbot-companion-publisher".into())
            .spawn(move || {
                Worker {
                    library,
                    sink,
                    context,
                    debounce,
                    pending: Pending::default(),
                    due: None,
                    projection_cache: HashMap::new(),
                    built: None,
                    fingerprints: HashMap::new(),
                    curation_stamp: None,
                }
                .run(receiver)
            })
            .ok();
        Self {
            requests,
            thread: Mutex::new(thread),
        }
    }

    /// Replace the settings the records depend on. A different record scope
    /// rebuilds everything; the manifest is always refreshed.
    pub fn update(&self, context: Context) {
        let _ = self.requests.send(Request::Update(Box::new(context)));
    }

    pub fn reconcile_all(&self) {
        self.change(|pending| pending.full = true);
    }

    /// Meeting evidence changed on these days: outcomes, notes, processing,
    /// deletion or a merge. Which meetings is found by comparing the library
    /// with what the records were built from.
    pub fn evidence_changed(&self, days: &[NaiveDate]) {
        let keys: Vec<String> = days.iter().copied().map(day_key).collect();
        self.change(move |pending| {
            pending.day_keys.extend(keys);
            pending.rescan = true;
        });
    }

    pub fn library_changed(&self) {
        self.change(|pending| pending.rescan = true);
    }

    pub fn day_changed(&self, day: NaiveDate) {
        let key = day_key(day);
        self.change(move |pending| {
            pending.day_keys.insert(key);
        });
    }

    /// Today's Timeline grows while the person works; rebuild today's record
    /// when anything was recorded within `window`.
    pub fn refresh_today_if_active(&self, window: chrono::Duration) {
        let _ = self.requests.send(Request::Today { window });
    }

    /// Writes from other pages (notes, a new title, people and project
    /// choices) reach no hook. One stat per file finds them.
    pub fn check_for_changes(&self) {
        let _ = self.requests.send(Request::Check);
    }

    /// Rebuild one meeting and what depends on it before returning, for ops
    /// the device waits on. Returns false when the pass did not finish in time.
    pub fn republish_now(&self, meeting_id: Uuid, timeout: Duration) -> bool {
        let (done, finished) = bounded(1);
        if self.requests.send(Request::Now(meeting_id, done)).is_err() {
            return false;
        }
        finished.recv_timeout(timeout).is_ok()
    }

    /// Run whatever is queued now and wait for it, for tests.
    #[cfg(test)]
    pub fn flush(&self) -> Report {
        let (done, finished) = bounded(1);
        if self.requests.send(Request::Flush(done)).is_err() {
            return Report::default();
        }
        finished.recv().unwrap_or_default()
    }

    /// Queued work is dropped; a pass under way finishes on its own thread.
    pub fn stop(&self) {
        let _ = self.requests.send(Request::Stop);
        self.thread.lock().take();
    }

    fn change(&self, change: impl FnOnce(&mut Pending) + Send + 'static) {
        let _ = self.requests.send(Request::Change(Box::new(change)));
    }
}

impl Drop for Publisher {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Worker {
    library: Library,
    sink: Arc<dyn RecordSink>,
    context: Context,
    debounce: Duration,
    pending: Pending,
    due: Option<Instant>,
    projection_cache: HashMap<Uuid, OutcomeProjection>,
    built: Option<CompanionLibrary>,
    /// When each shared meeting's sources last changed, as of its last build.
    fingerprints: HashMap<Uuid, Fingerprint>,
    curation_stamp: Option<[Option<SystemTime>; 3]>,
}

impl Worker {
    fn run(mut self, requests: Receiver<Request>) {
        loop {
            let request = match self.due {
                Some(due) => {
                    match requests.recv_timeout(due.saturating_duration_since(Instant::now())) {
                        Ok(request) => request,
                        Err(RecvTimeoutError::Timeout) => {
                            self.due = None;
                            self.drain();
                            continue;
                        }
                        Err(RecvTimeoutError::Disconnected) => return,
                    }
                }
                None => match requests.recv() {
                    Ok(request) => request,
                    Err(_) => return,
                },
            };
            match request {
                Request::Update(next) => {
                    let rebuild =
                        next.sharing.record_scope() != self.context.sharing.record_scope();
                    self.context = *next;
                    if rebuild {
                        self.built = None;
                        self.projection_cache.clear();
                        self.enqueue(|pending| pending.full = true);
                    } else {
                        self.publish_manifest();
                    }
                }
                Request::Change(change) => self.enqueue(change),
                Request::Now(meeting_id, done) => {
                    self.pending.meeting_ids.insert(meeting_id);
                    self.pending.connections = true;
                    self.drain();
                    let _ = done.send(());
                }
                #[cfg(test)]
                Request::Flush(done) => {
                    self.due = None;
                    let _ = done.send(self.drain());
                }
                Request::Today { window } => {
                    let now = Utc::now();
                    let active = self
                        .library
                        .latest_activity_end()
                        .ok()
                        .flatten()
                        .is_some_and(|latest| now - latest <= window);
                    if active {
                        let key = day_key(local_day(now));
                        self.enqueue(move |pending| {
                            pending.day_keys.insert(key);
                        });
                    }
                }
                Request::Check => {
                    if self.changed_on_disk() {
                        self.enqueue(|pending| pending.rescan = true);
                    }
                }
                Request::Stop => return,
            }
        }
    }

    fn enqueue(&mut self, change: impl FnOnce(&mut Pending)) {
        change(&mut self.pending);
        if self.due.is_none() {
            self.due = Some(Instant::now() + self.debounce);
        }
    }

    fn drain(&mut self) -> Report {
        let work = std::mem::take(&mut self.pending);
        if work.is_empty() {
            return Report::default();
        }
        let started = Instant::now();
        let full = work.full;
        let report = if full {
            self.reconcile()
        } else {
            self.apply(work)
        };
        if report != Report::default() {
            log::info!(
                "companion publish {}: {} built, {} changed, {} withdrawn, {} failed in {:.2}s",
                if full { "full" } else { "incremental" },
                report.published,
                report.changed,
                report.removed,
                report.failed,
                started.elapsed().as_secs_f64()
            );
        }
        report
    }

    fn reconcile(&mut self) -> Report {
        let loaded = CompanionLibrary::load(
            &self.library,
            self.context.sharing.record_scope(),
            Utc::now(),
            None,
            &HashMap::new(),
        );
        self.projection_cache = loaded.projections.clone();
        self.fingerprints = fingerprints(&self.library, &loaded.meetings);
        self.curation_stamp = Some(curation_stamp(&self.library));
        let mut report = Report::default();
        let records = RecordBuilder::new(&loaded).all_records();
        self.publish(&records, &mut report);
        for kind in RecordKind::RECONCILED {
            let wanted: HashSet<&str> = records
                .iter()
                .filter(|record| record.kind == kind)
                .map(|record| record.key.as_str())
                .collect();
            self.withdraw(kind, &wanted, &mut report);
        }
        self.built = Some(loaded);
        self.publish_manifest();
        report
    }

    fn apply(&mut self, mut work: Pending) -> Report {
        let now = Utc::now();
        let Some(previous) = self.built.take() else {
            return self.reconcile();
        };
        if work.rescan {
            self.rescan(&mut work);
            if work.meeting_ids.is_empty() && work.day_keys.is_empty() && !work.connections {
                self.built = Some(previous);
                return Report::default();
            }
        }
        // The meeting list is cheap to read again; outcomes are reloaded only
        // for the meetings that changed.
        for id in &work.meeting_ids {
            self.projection_cache.remove(id);
        }
        let recompute = work.connections || !work.meeting_ids.is_empty();
        let current = CompanionLibrary::reloading(previous, now, &self.projection_cache, recompute);
        self.projection_cache = current.projections.clone();
        let mut report = Report::default();
        {
            let builder = RecordBuilder::new(&current);
            let mut day_keys = work.day_keys.clone();
            let by_id: HashMap<Uuid, &Meeting> = current
                .all_meetings
                .iter()
                .map(|meeting| (meeting.id, meeting))
                .collect();
            for id in &work.meeting_ids {
                let key = records::id(*id);
                let records = by_id
                    .get(id)
                    .map(|meeting| builder.meeting_records(meeting))
                    .unwrap_or_default();
                self.publish(&records, &mut report);
                for kind in [RecordKind::Meeting, RecordKind::Transcript] {
                    if !records.iter().any(|record| record.kind == kind) {
                        self.remove(kind, &key, &mut report);
                    }
                }
                if let Some(meeting) = by_id.get(id) {
                    day_keys.insert(day_key(local_day(meeting.started_at)));
                }
            }
            for key in &day_keys {
                match builder.day_record(key) {
                    Some(record) => self.publish(&[record], &mut report),
                    None => self.remove(RecordKind::Day, key, &mut report),
                }
            }
            if recompute {
                let people = builder.person_records();
                let projects = builder.project_records();
                self.publish(&people, &mut report);
                self.publish(&projects, &mut report);
                let keys = |list: &[Record]| -> HashSet<String> {
                    list.iter().map(|record| record.key.clone()).collect()
                };
                let (people, projects) = (keys(&people), keys(&projects));
                self.withdraw(
                    RecordKind::Person,
                    &people.iter().map(String::as_str).collect(),
                    &mut report,
                );
                self.withdraw(
                    RecordKind::Project,
                    &projects.iter().map(String::as_str).collect(),
                    &mut report,
                );
            }
        }
        // What was just rebuilt needs no second pass.
        for id in &work.meeting_ids {
            self.fingerprints.remove(id);
        }
        let rebuilt: Vec<Meeting> = current
            .meetings
            .iter()
            .filter(|meeting| work.meeting_ids.contains(&meeting.id))
            .cloned()
            .collect();
        self.fingerprints
            .extend(fingerprints(&self.library, &rebuilt));
        self.built = Some(current);
        report
    }

    fn changed_on_disk(&self) -> bool {
        let Some(built) = &self.built else {
            return false;
        };
        self.curation_stamp != Some(curation_stamp(&self.library))
            || built.meetings.iter().any(|meeting| {
                self.fingerprints.get(&meeting.id) != Some(&fingerprint(&self.library, meeting))
            })
    }

    /// Names the meetings whose files changed, and those gone or newly
    /// shared. Only dates reach the change hook here, and writes outside the
    /// evidence path (a finished recording, a summary) reach it not at all.
    fn rescan(&mut self, work: &mut Pending) {
        let now = Utc::now();
        let history = self.context.sharing.history;
        let shared: Vec<Meeting> = read_all_meetings(&self.library)
            .into_iter()
            .filter(|meeting| is_shared(meeting, history, now))
            .collect();
        let current = fingerprints(&self.library, &shared);
        for meeting in &shared {
            if self.fingerprints.get(&meeting.id) != current.get(&meeting.id) {
                work.meeting_ids.insert(meeting.id);
                work.day_keys.insert(day_key(local_day(meeting.started_at)));
            }
        }
        for id in self.fingerprints.keys() {
            if !current.contains_key(id) {
                work.meeting_ids.insert(*id);
            }
        }
        self.fingerprints = current;
        let stamp = curation_stamp(&self.library);
        if self.curation_stamp != Some(stamp) {
            self.curation_stamp = Some(stamp);
            work.connections = true;
        }
    }

    fn publish_manifest(&self) {
        let Some(body) =
            builder::manifest(&self.context.sharing, &self.context.mac_name, Utc::now())
        else {
            return;
        };
        if let Err(err) = self.sink.set_manifest(&body) {
            log::warn!("companion manifest publish failed: {err:#}");
        }
    }

    fn publish(&self, records: &[Record], report: &mut Report) {
        for record in records {
            report.published += 1;
            match self
                .sink
                .publish(record.kind.raw(), &record.key, &record.body_json)
            {
                Ok(true) => report.changed += 1,
                Ok(false) => {}
                Err(err) => {
                    report.failed += 1;
                    log::warn!(
                        "companion publish failed kind={}: {err:#}",
                        record.kind.raw()
                    );
                }
            }
        }
    }

    fn remove(&self, kind: RecordKind, key: &str, report: &mut Report) {
        match self.sink.remove(kind.raw(), key) {
            Ok(true) => report.removed += 1,
            Ok(false) => {}
            Err(err) => {
                report.failed += 1;
                log::warn!("companion withdraw failed kind={}: {err:#}", kind.raw());
            }
        }
    }

    fn withdraw(&self, kind: RecordKind, wanted: &HashSet<&str>, report: &mut Report) {
        let existing = match self.sink.record_keys(kind.raw()) {
            Ok(existing) => existing,
            Err(err) => {
                report.failed += 1;
                log::warn!("companion key listing failed kind={}: {err:#}", kind.raw());
                return;
            }
        };
        for key in existing {
            if !wanted.contains(key.as_str()) {
                self.remove(kind, &key, report);
            }
        }
    }
}

/// When a meeting's record's sources last changed.
type Fingerprint = [Option<SystemTime>; 6];

fn fingerprint(library: &Library, meeting: &Meeting) -> Fingerprint {
    let folder = library.meeting_dir(meeting);
    [
        META_FILE,
        TRANSCRIPT_FILE,
        SUMMARY_FILE,
        NOTES_FILE,
        OUTCOMES_FILE,
        OUTCOME_STATE_FILE,
    ]
    .map(|file| modified(&folder.join(file)))
}

fn fingerprints(library: &Library, meetings: &[Meeting]) -> HashMap<Uuid, Fingerprint> {
    meetings
        .iter()
        .map(|meeting| (meeting.id, fingerprint(library, meeting)))
        .collect()
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
}

/// When People and Projects choices and the "Where it stands" notes last
/// changed: `people/curation.json`, `projects/tracked.json`,
/// `projects/summaries.json`.
fn curation_stamp(library: &Library) -> [Option<SystemTime>; 3] {
    let paths = library.paths();
    [
        modified(&paths.root().join("people").join("curation.json")),
        modified(&paths.projects_dir().join("tracked.json")),
        modified(&paths.projects_dir().join("summaries.json")),
    ]
}
