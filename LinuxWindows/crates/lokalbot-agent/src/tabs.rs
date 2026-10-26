//! The task list (`AgentSessionTabs.swift`): a persistent catalog of tasks
//! with lazily loaded transcripts. The four-process limit applies to running
//! agents, never to browsing tasks or saved history.

use std::path::Path;
use std::sync::Arc;

use chrono::Utc;
use uuid::Uuid;

use crate::archive;
use crate::history::{self, SavedSession};
use crate::session::{AgentEnvironment, AgentSession, Inbox, SessionState, TaskInput};
use crate::tasks::{TaskRecord, TaskStore};
use crate::transcript::TranscriptItem;

pub const MAX_LIVE_SESSIONS: usize = 4;

pub const UNAVAILABLE: &str =
    "That saved task is no longer available. Refresh the task list and try again.";
pub const ALREADY_OPEN: &str = "That task is already open.";
pub const MAX_LIVE_MESSAGE: &str = "Four agents are already working. Stop one before starting another task. You can still browse every saved task.";

pub struct Tab {
    pub id: Uuid,
    pub number: usize,
    pub session: AgentSession,
    pub record: TaskRecord,
    pub saved: Option<SavedSession>,
}

impl Tab {
    pub fn title(&self) -> String {
        self.record
            .title
            .clone()
            .or_else(|| self.session.session_title.clone())
            .or_else(|| self.saved.as_ref().map(|s| s.title.clone()))
            .unwrap_or_else(|| "New task".into())
    }

    fn file(&self) -> Option<&Path> {
        self.session
            .active_session_file
            .as_deref()
            .or(self.record.session_file.as_deref())
    }
}

pub struct TaskList {
    env: Arc<AgentEnvironment>,
    inbox: Inbox,
    pub tabs: Vec<Tab>,
    pub selected_id: Uuid,
    pub error: Option<String>,
    store: TaskStore,
    next_number: usize,
    can_persist: bool,
    /// Something task metadata depends on changed; the owner saves soon.
    pub needs_persist: bool,
}

impl TaskList {
    pub fn new(env: Arc<AgentEnvironment>, inbox: Inbox) -> Self {
        let store = TaskStore::new(env.dirs.sessions());
        let mut list = Self {
            env,
            inbox,
            tabs: Vec::new(),
            selected_id: Uuid::nil(),
            error: None,
            store,
            next_number: 1,
            can_persist: true,
            needs_persist: false,
        };
        match list.store.load() {
            Ok(records) => {
                for record in records {
                    let mut session = list.make_session(record.id);
                    session.workspace = record.workspace.clone();
                    session.draft = record.draft.clone();
                    session.attachments = record.attachments.clone();
                    session.restore_queue(record.queued_prompts.clone());
                    session.restore_sources(record.sources.clone());
                    let number = list.take_number();
                    list.tabs.push(Tab {
                        id: record.id,
                        number,
                        session,
                        record,
                        saved: None,
                    });
                }
            }
            Err(err) => {
                list.can_persist = false;
                list.error = Some(format!(
                    "Couldn’t read task metadata. Existing metadata was preserved: {err:#}"
                ));
            }
        }
        if list.tabs.is_empty() {
            list.push_new_tab();
        }
        list.selected_id = list
            .tabs
            .iter()
            .find(|t| !t.record.is_archived)
            .unwrap_or(&list.tabs[0])
            .id;
        list
    }

    fn make_session(&self, id: Uuid) -> AgentSession {
        AgentSession::new(self.env.clone(), id, self.inbox.clone())
    }

    fn take_number(&mut self) -> usize {
        let number = self.next_number;
        self.next_number += 1;
        number
    }

    fn push_new_tab(&mut self) -> Uuid {
        let id = Uuid::new_v4();
        let session = self.make_session(id);
        let mut record = TaskRecord::new(session.workspace.clone());
        record.id = id;
        let number = self.take_number();
        self.tabs.push(Tab {
            id,
            number,
            session,
            record,
            saved: None,
        });
        id
    }

    // ------------------------------------------------------------ queries

    pub fn selected(&self) -> Option<&Tab> {
        self.tab(self.selected_id)
    }

    pub fn tab(&self, id: Uuid) -> Option<&Tab> {
        self.tabs.iter().find(|t| t.id == id)
    }

    pub fn tab_mut(&mut self, id: Uuid) -> Option<&mut Tab> {
        self.tabs.iter_mut().find(|t| t.id == id)
    }

    pub fn session_mut(&mut self, id: Uuid) -> Option<&mut AgentSession> {
        self.tab_mut(id).map(|t| &mut t.session)
    }

    /// Pinned first, then most recently modified.
    pub fn ordered(&self) -> Vec<&Tab> {
        let mut tabs: Vec<&Tab> = self.tabs.iter().collect();
        tabs.sort_by(|a, b| {
            b.record
                .is_pinned
                .cmp(&a.record.is_pinned)
                .then_with(|| b.record.modified_at.cmp(&a.record.modified_at))
        });
        tabs
    }

    pub fn live_count(&self) -> usize {
        self.tabs
            .iter()
            .filter(|t| t.session.has_live_runtime())
            .count()
    }

    pub fn is_open(&self, session: &SavedSession) -> bool {
        self.tabs.iter().any(|t| {
            t.file()
                .is_some_and(|f| crate::policy::same_path(f, &session.file))
        })
    }

    pub fn workspace_display_name(&self, workspace: &Path) -> String {
        match self.selected() {
            Some(tab) => tab.session.workspace_display_name_for(workspace),
            None => workspace
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
        }
    }

    pub fn any_running(&self) -> bool {
        self.tabs.iter().any(|t| {
            matches!(
                t.session.state,
                SessionState::Running | SessionState::Starting
            )
        })
    }

    // -------------------------------------------------------------- edits

    /// The selected task, or a new one when it is archived.
    pub fn ensure_selected(&mut self) -> Uuid {
        match self.selected() {
            Some(tab) if !tab.record.is_archived => tab.id,
            _ => self.add_session(),
        }
    }

    pub fn add_session(&mut self) -> Uuid {
        let id = self.push_new_tab();
        self.selected_id = id;
        self.needs_persist = true;
        id
    }

    /// Selects a task and loads its saved transcript for browsing.
    pub fn select(&mut self, id: Uuid) {
        if self.tab(id).is_none() {
            return;
        }
        self.selected_id = id;
        self.load_preview(id);
    }

    pub fn select_neighbor(&mut self, offset: isize) {
        let visible: Vec<Uuid> = self
            .ordered()
            .into_iter()
            .filter(|t| !t.record.is_archived)
            .map(|t| t.id)
            .collect();
        if visible.is_empty() {
            return;
        }
        let index = visible
            .iter()
            .position(|id| *id == self.selected_id)
            .unwrap_or(0) as isize;
        let count = visible.len() as isize;
        self.select(visible[((index + offset) % count + count) as usize % visible.len()]);
    }

    fn load_preview(&mut self, id: Uuid) {
        let Some(tab) = self.tab_mut(id) else { return };
        if tab.session.has_live_runtime() || !tab.session.items().is_empty() {
            return;
        }
        match tab.saved.clone() {
            Some(saved) => tab.session.load_saved_preview(saved),
            None => {
                if tab.record.session_file.is_some() {
                    self.error = Some("The saved conversation is unavailable. Its draft and task metadata remain intact.".into());
                }
            }
        }
    }

    pub fn rename(&mut self, id: Uuid, title: &str) {
        let clean = title.trim();
        if let Some(tab) = self.tab_mut(id) {
            tab.record.title = (!clean.is_empty()).then(|| clean.chars().take(120).collect());
        }
        self.persist();
    }

    pub fn toggle_pin(&mut self, id: Uuid) {
        if let Some(tab) = self.tab_mut(id) {
            tab.record.is_pinned = !tab.record.is_pinned;
        }
        self.persist();
    }

    pub fn set_archived(&mut self, id: Uuid, archived: bool) {
        let Some(tab) = self.tab_mut(id) else { return };
        if matches!(
            tab.session.state,
            SessionState::Running | SessionState::Starting
        ) {
            self.error = Some("Stop this task before archiving it.".into());
            return;
        }
        if !tab.session.park() {
            self.error = Some(
                "This conversation has not finished saving. Try again after it is saved.".into(),
            );
            return;
        }
        tab.record.is_archived = archived;
        if archived && self.selected_id == id {
            match self
                .tabs
                .iter()
                .find(|t| !t.record.is_archived)
                .map(|t| t.id)
            {
                Some(next) => self.select(next),
                None => {
                    self.add_session();
                }
            }
        }
        self.persist();
    }

    /// Archives (closing a task keeps its draft).
    pub fn close(&mut self, id: Uuid) {
        self.set_archived(id, true);
    }

    // -------------------------------------------------------------- history

    /// Saved sessions read off the UI thread are matched to tasks; sessions
    /// without one get a task, so every saved conversation can be browsed.
    pub fn apply_history(&mut self, saved: Vec<SavedSession>) {
        for session in saved {
            if let Some(tab) = self.tabs.iter_mut().find(|t| {
                t.file()
                    .is_some_and(|f| crate::policy::same_path(f, &session.file))
            }) {
                tab.record.session_file = Some(session.file.clone());
                tab.saved = Some(session);
            } else {
                let id = Uuid::new_v4();
                let mut tab_session = self.make_session(id);
                tab_session.workspace = session.workspace.clone();
                let mut record = TaskRecord::new(session.workspace.clone());
                record.id = id;
                record.session_file = Some(session.file.clone());
                record.modified_at = session.modified_at;
                let number = self.take_number();
                self.tabs.push(Tab {
                    id,
                    number,
                    session: tab_session,
                    record,
                    saved: Some(session),
                });
            }
        }
        self.load_preview(self.selected_id);
        self.needs_persist = true;
    }

    pub fn load_saved_sessions(&self) -> anyhow::Result<Vec<SavedSession>> {
        history::load(&self.store.directory)
    }

    pub fn sessions_directory(&self) -> &Path {
        &self.store.directory
    }

    // ------------------------------------------------------------- running

    /// Makes room and checks a task before its runtime starts: idle runtimes
    /// beyond the limit are parked, and a missing saved file never silently
    /// becomes a fresh conversation.
    fn prepare_start(&mut self, id: Uuid) -> bool {
        let Some(tab) = self.tab(id) else {
            return false;
        };
        if tab.record.is_archived {
            return false;
        }
        if matches!(
            tab.session.state,
            SessionState::Ready | SessionState::Running | SessionState::Starting
        ) {
            return true;
        }
        if self.live_count() >= MAX_LIVE_SESSIONS {
            let idle = self.tabs.iter().position(|t| {
                t.id != id
                    && t.session.state == SessionState::Ready
                    && !t.session.is_sending
                    && (t.session.items().is_empty() || t.session.active_session_file.is_some())
            });
            let Some(index) = idle else {
                self.error = Some(MAX_LIVE_MESSAGE.into());
                return false;
            };
            if !self.tabs[index].session.park() {
                self.error = Some(
                    "An idle task is still saving. Try starting this task again in a moment."
                        .into(),
                );
                return false;
            }
        }
        if let Err(error) = self.check_saved_and_workspace(id) {
            self.error = Some(error);
            return false;
        }
        true
    }

    fn check_saved_and_workspace(&mut self, id: Uuid) -> Result<(), String> {
        let directory = self.store.directory.clone();
        let tab = self.tab_mut(id).ok_or_else(|| UNAVAILABLE.to_string())?;
        if let Some(file) = tab.record.session_file.clone() {
            if !file.is_file() {
                return Err(UNAVAILABLE.into());
            }
            let saved = tab
                .saved
                .clone()
                .or_else(|| history::load_file(&file, &directory))
                .and_then(|s| history::validated(&s, &directory))
                .ok_or_else(|| UNAVAILABLE.to_string())?;
            if tab.session.items().is_empty() {
                tab.session.load_saved_preview_now(&saved)?;
            }
            tab.saved = Some(saved);
        }
        tab.session.prepare_workspace()
    }

    /// Starts a task's runtime (Reconnect).
    pub fn start(&mut self, id: Uuid) -> bool {
        if !self.prepare_start(id) {
            return false;
        }
        if let Some(session) = self.session_mut(id) {
            session.start();
        }
        true
    }

    /// Sends the composer's draft, starting the task first when needed.
    pub fn submit(&mut self, id: Uuid, steer: bool) {
        let Some(tab) = self.tab(id) else { return };
        let live = tab.session.has_live_runtime();
        if !live && !self.prepare_start(id) {
            return;
        }
        if let Some(session) = self.session_mut(id) {
            session.submit(steer);
        }
        self.needs_persist = true;
    }

    /// "Send next" on the queue, starting the task when needed.
    pub fn send_next_queued(&mut self, id: Uuid) {
        let Some(tab) = self.tab(id) else { return };
        if !tab.session.has_live_runtime() && !self.prepare_start(id) {
            return;
        }
        if let Some(session) = self.session_mut(id) {
            session.send_next_queued();
        }
        self.needs_persist = true;
    }

    /// Opens one saved session, in the selected blank task when there is one.
    pub fn open_saved_session(&mut self, session: &SavedSession) -> Result<(), String> {
        let Some(refreshed) = history::validated(session, &self.store.directory) else {
            return Err(UNAVAILABLE.into());
        };
        if let Some(existing) = self
            .tabs
            .iter()
            .find(|t| {
                t.file()
                    .is_some_and(|f| crate::policy::same_path(f, &session.file))
            })
            .map(|t| t.id)
        {
            self.select(existing);
            return Ok(());
        }
        let target = match self.selected() {
            Some(tab) if tab.session.can_replace_with_saved_session() => tab.id,
            _ => self.add_session(),
        };
        let tab = self
            .tab_mut(target)
            .ok_or_else(|| UNAVAILABLE.to_string())?;
        tab.saved = Some(refreshed.clone());
        tab.record.session_file = Some(refreshed.file.clone());
        tab.record.workspace = refreshed.workspace.clone();
        tab.session.load_saved_preview_now(&refreshed)?;
        self.selected_id = target;
        self.persist();
        Ok(())
    }

    /// An independent task through `item_id`. Existing files are unchanged.
    pub fn fork(&mut self, id: Uuid, item_id: &str) {
        let directory = self.store.directory.clone();
        let Some(tab) = self.tab(id) else { return };
        let busy = matches!(
            tab.session.state,
            SessionState::Running | SessionState::Starting
        ) || tab.session.is_sending;
        let Some(file) = tab.file().map(Path::to_path_buf).filter(|_| !busy) else {
            self.error = Some("Wait for this task to finish and save before branching.".into());
            return;
        };
        let items = tab.session.items();
        let Some(index) = items.iter().position(|i| i.id() == item_id) else {
            return;
        };
        let item = items[index].clone();
        let occurrence = items[index + 1..]
            .iter()
            .filter(|other| match (other, &item) {
                (TranscriptItem::User { text: a, .. }, TranscriptItem::User { text: b, .. }) => {
                    a == b
                }
                (
                    TranscriptItem::Assistant { text: a, .. },
                    TranscriptItem::Assistant { text: b, .. },
                ) => a == b,
                _ => false,
            })
            .count();
        let title = tab.title();
        let result = history::load_file(&file, &directory)
            .ok_or(archive::ArchiveError::UnsavedMessage)
            .and_then(|saved| archive::fork(&saved, &item, occurrence, &directory));
        match result {
            Ok(branch) => {
                let new = self.add_session();
                if let Err(error) = self.open_saved_session(&branch) {
                    self.error = Some(error);
                    return;
                }
                self.rename(new, &format!("Branch: {title}"));
            }
            Err(error) => self.error = Some(error.to_string()),
        }
    }

    /// App quit: every pi is asked to stop at once, then whatever is left
    /// after `grace` is killed.
    pub fn shutdown_all(&mut self, grace: std::time::Duration) {
        self.persist();
        let processes: Vec<_> = self
            .tabs
            .iter_mut()
            .filter_map(|t| t.session.begin_quit())
            .collect();
        let deadline = std::time::Instant::now() + grace;
        while processes.iter().any(|p| p.is_running()) && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        for process in processes {
            process.kill_tree();
        }
    }

    /// Stops every task and removes saved conversations and task metadata.
    pub fn clear_saved_history(&mut self) -> anyhow::Result<()> {
        for tab in &mut self.tabs {
            tab.session.shutdown();
        }
        self.tabs.clear();
        let directory = self.store.directory.clone();
        if directory.exists() {
            std::fs::remove_dir_all(&directory)?;
        }
        self.can_persist = true;
        self.add_session();
        self.persist();
        Ok(())
    }

    /// Routes one completion to its task.
    pub fn handle(&mut self, input: TaskInput) -> bool {
        let Some(tab) = self.tab_mut(input.task) else {
            return false;
        };
        let before = tab.session.state.clone();
        let changed = tab.session.handle(input.generation, input.input);
        let after = tab.session.state.clone();
        let mut persist = false;
        if before != after && matches!(after, SessionState::Running | SessionState::Ready) {
            tab.record.modified_at = Utc::now();
            persist = true;
        }
        if tab.session.active_session_file.is_some()
            && tab.record.session_file != tab.session.active_session_file
        {
            persist = true;
        }
        self.needs_persist |= persist;
        changed
    }

    /// Writes `tasks.json` from every task's current state.
    pub fn persist(&mut self) {
        self.needs_persist = false;
        if !self.can_persist {
            return;
        }
        for tab in &mut self.tabs {
            let session = &tab.session;
            tab.record.workspace = session.workspace.clone();
            tab.record.draft = session.draft.clone();
            tab.record.attachments = session.attachments.clone();
            tab.record.queued_prompts = session.queued_prompts.clone();
            tab.record.sources = session.source_attachments.clone();
            if let Some(file) = &session.active_session_file {
                tab.record.session_file = Some(file.clone());
            }
        }
        let records: Vec<TaskRecord> = self.tabs.iter().map(|t| t.record.clone()).collect();
        if let Err(err) = self.store.save(&records) {
            self.error = Some(format!("Couldn’t save task metadata: {err:#}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint::{LlmEndpoint, ReasoningDialect};
    use crate::layout::{AgentDirectories, RuntimeLayout};
    use crate::rpc::tests::RecordingTransport;
    use crate::rpc::{LineTransport, REQUEST_TIMEOUT, RpcClient, Sink};
    use crate::session::{LaunchError, LaunchRequest, Launched, Launcher, RequestTag};
    use parking_lot::{Mutex, RwLock};

    struct Instant {
        launches: Mutex<usize>,
    }

    impl Launcher for Instant {
        fn launch(
            &self,
            _request: LaunchRequest,
            sink: Sink<RequestTag>,
            done: Box<dyn FnOnce(Result<Launched, LaunchError>) + Send>,
        ) {
            *self.launches.lock() += 1;
            let client = RpcClient::new(sink, REQUEST_TIMEOUT);
            client.attach(Arc::new(RecordingTransport::default()) as Arc<dyn LineTransport>);
            done(Ok(Launched {
                client,
                process: None,
                lease: None,
                relay: None,
                capability: None,
                endpoint: LlmEndpoint {
                    base_url: "http://127.0.0.1:17872/v1".into(),
                    model: "qwen3.5-4b".into(),
                    context_tokens: 32_768,
                    api_key: None,
                    reasoning_dialect: ReasoningDialect::LlamaServer,
                    api: Default::default(),
                    plan: None,
                },
                reports_session_file: false,
            }));
        }
    }

    struct Fixture {
        env: Arc<AgentEnvironment>,
        launcher: Arc<Instant>,
        rx: async_channel::Receiver<TaskInput>,
        tx: Inbox,
        /// Dropped last: Windows can't remove the library while it is open.
        _dir: tempfile::TempDir,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = dunce::canonicalize(dir.path()).unwrap().join("LokalBot");
        let paths = lokalbot_core::LibraryPaths::new(&root);
        let launcher = Arc::new(Instant {
            launches: Mutex::new(0),
        });
        let env = Arc::new(AgentEnvironment {
            library: lokalbot_core::Library::open(paths.clone()).unwrap(),
            dirs: AgentDirectories::new(&paths),
            layout: RuntimeLayout::for_library(&paths),
            settings: Arc::new(RwLock::new(lokalbot_core::Settings::default())),
            launcher: launcher.clone(),
        });
        let (tx, rx) = async_channel::unbounded();
        Fixture {
            env,
            launcher,
            rx,
            tx,
            _dir: dir,
        }
    }

    fn pump(list: &mut TaskList, rx: &async_channel::Receiver<TaskInput>) {
        while let Ok(input) = rx.try_recv() {
            list.handle(input);
        }
    }

    #[test]
    fn adding_a_task_creates_an_independent_selected_session() {
        let f = fixture();
        let mut list = TaskList::new(f.env.clone(), f.tx.clone());
        let first = list.selected_id;
        let second = list.add_session();
        assert_ne!(first, second);
        assert_eq!(list.selected_id, second);
        assert_eq!(list.tabs.len(), 2);
    }

    #[test]
    fn drafts_titles_pins_and_archives_survive_relaunch_without_spawning() {
        let f = fixture();
        let id;
        {
            let mut list = TaskList::new(f.env.clone(), f.tx.clone());
            id = list.selected_id;
            list.session_mut(id).unwrap().draft = "unsent".into();
            list.rename(id, "  Pinned work  ");
            list.toggle_pin(id);
            let other = list.add_session();
            list.set_archived(other, true);
            list.persist();
        }
        let list = TaskList::new(f.env.clone(), f.tx.clone());
        let tab = list.tab(id).unwrap();
        assert_eq!(tab.session.draft, "unsent");
        assert_eq!(tab.title(), "Pinned work");
        assert!(tab.record.is_pinned);
        assert!(list.tabs.iter().any(|t| t.record.is_archived));
        assert_eq!(*f.launcher.launches.lock(), 0);
    }

    #[test]
    fn runtime_limit_parks_idle_tasks_and_rejects_a_fifth_busy_one() {
        let f = fixture();
        let mut list = TaskList::new(f.env.clone(), f.tx.clone());
        let mut ids = vec![list.selected_id];
        for _ in 0..4 {
            ids.push(list.add_session());
        }
        for id in &ids[..4] {
            assert!(list.start(*id));
            pump(&mut list, &f.rx);
        }
        assert_eq!(list.live_count(), 4);
        // An idle, empty runtime is parked to make room.
        assert!(list.start(ids[4]));
        pump(&mut list, &f.rx);
        assert_eq!(list.live_count(), 4);
        // With every runtime busy, a new one is refused but tasks still open.
        for id in &ids {
            if let Some(session) = list.session_mut(*id)
                && session.has_live_runtime()
            {
                session.state = SessionState::Running;
            }
        }
        let parked = *ids
            .iter()
            .find(|id| !list.tab(**id).unwrap().session.has_live_runtime())
            .unwrap();
        assert!(!list.start(parked));
        assert_eq!(list.error.as_deref(), Some(MAX_LIVE_MESSAGE));
        list.add_session();
    }

    #[test]
    fn archiving_keeps_history_and_closing_the_last_task_creates_a_fresh_one() {
        let f = fixture();
        let mut list = TaskList::new(f.env.clone(), f.tx.clone());
        let only = list.selected_id;
        list.close(only);
        assert!(list.tab(only).unwrap().record.is_archived);
        assert_ne!(list.selected_id, only);
        assert!(!list.tab(list.selected_id).unwrap().record.is_archived);
    }

    #[test]
    fn saved_sessions_open_in_a_blank_task_and_only_once() {
        let f = fixture();
        let sessions = f.env.dirs.sessions();
        std::fs::create_dir_all(&sessions).unwrap();
        let workspace = f.env.dirs.default_workspace();
        std::fs::create_dir_all(&workspace).unwrap();
        std::fs::write(
            sessions.join("saved.jsonl"),
            format!(
                "{}\n{}\n",
                serde_json::json!({"type": "session", "id": "saved", "cwd": workspace.to_string_lossy()}),
                serde_json::json!({"type": "message", "id": "u", "parentId": null, "message": {"role": "user", "content": "Saved question"}}),
            ),
        )
        .unwrap();
        let mut list = TaskList::new(f.env.clone(), f.tx.clone());
        let blank = list.selected_id;
        let saved = list.load_saved_sessions().unwrap().remove(0);
        list.open_saved_session(&saved).unwrap();
        assert_eq!(list.selected_id, blank);
        assert_eq!(list.tab(blank).unwrap().session.items().len(), 1);
        assert!(list.is_open(&saved));
        list.add_session();
        list.open_saved_session(&saved).unwrap();
        assert_eq!(
            list.selected_id, blank,
            "an open session is selected, not opened twice"
        );
        assert_eq!(*f.launcher.launches.lock(), 0, "browsing never starts pi");
    }

    #[test]
    fn clearing_history_stops_tasks_and_removes_files() {
        let f = fixture();
        let mut list = TaskList::new(f.env.clone(), f.tx.clone());
        let id = list.selected_id;
        list.start(id);
        pump(&mut list, &f.rx);
        list.persist();
        assert!(list.sessions_directory().join("tasks.json").is_file());
        list.clear_saved_history().unwrap();
        assert_eq!(list.tabs.len(), 1);
        assert!(!list.tabs[0].session.has_live_runtime());
        assert!(!list.sessions_directory().join("x.jsonl").exists());
    }
}
