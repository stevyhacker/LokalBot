mod claude;
mod codex;
mod exclusions;
#[cfg(test)]
mod tests;
mod text;

use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use lokalbot_core::agent_notes::{NoteScan, NotesIndex, store};
use lokalbot_core::coding_agents::CodingAgentKind;
use lokalbot_core::{Library, Settings};
use parking_lot::Mutex;

use crate::{EngineEvent, Shared};
use claude::ClaudeNotesReader;
use codex::CodexNotesReader;
use exclusions::Exclusions;

const REFRESH_INTERVAL: Duration = Duration::from_secs(10 * 60);
const FIRST_REFRESH_DELAY: Duration = Duration::from_secs(5);

pub fn scan(home: &Path, agents: &[CodingAgentKind], excluded_folders: &[String]) -> NoteScan {
    let exclusions = Exclusions::new(excluded_folders, home.to_str());
    let mut scan = NoteScan::default();
    for agent in CodingAgentKind::ALL {
        if !agents.contains(&agent) {
            continue;
        }
        let found = match agent {
            CodingAgentKind::ClaudeCode => ClaudeNotesReader {
                root: home.join(".claude").join("projects"),
            }
            .scan(&exclusions),
            CodingAgentKind::Codex => CodexNotesReader {
                root: home.join(".codex").join("memories"),
            }
            .scan(&exclusions),
            CodingAgentKind::Antigravity | CodingAgentKind::T3Code => continue,
        };
        scan.merge(found);
    }
    scan.notes.sort_by(|a, b| {
        b.modified_at
            .cmp(&a.modified_at)
            .then_with(|| a.id.cmp(&b.id))
    });
    scan
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Configuration {
    pub agents: Vec<CodingAgentKind>,
    pub excluded_folders: Vec<String>,
}

impl Configuration {
    pub fn new(settings: &Settings) -> Self {
        Self {
            agents: settings.coding_agent_note_agents(),
            excluded_folders: settings.coding_agent_excluded_folder_list(),
        }
    }

    pub fn reads(&self) -> bool {
        !self.agents.is_empty()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AgentNotesStatus {
    pub counts: Vec<(CodingAgentKind, usize)>,
    pub error: Option<String>,
}

impl AgentNotesStatus {
    pub fn total(&self) -> usize {
        self.counts.iter().map(|(_, count)| count).sum()
    }
}

#[derive(Default)]
pub struct Ingestor {
    running: Mutex<()>,
    last_error: Mutex<Option<String>>,
    reported: Mutex<Option<AgentNotesStatus>>,
}

impl Ingestor {
    pub fn refresh(&self, library: &Library, settings: impl Fn() -> Settings) -> bool {
        let Some(home) = std::env::home_dir() else {
            return false;
        };
        self.refresh_with(library, settings, |configuration| {
            scan(
                &home,
                &configuration.agents,
                &configuration.excluded_folders,
            )
        })
    }

    fn refresh_with(
        &self,
        library: &Library,
        settings: impl Fn() -> Settings,
        scan: impl Fn(&Configuration) -> NoteScan,
    ) -> bool {
        if library.is_read_only() {
            return false;
        }
        let _running = self.running.lock();
        let root = library.paths().root();
        let configuration = Configuration::new(&settings());
        if !configuration.reads() {
            return self.remove_all(root);
        }
        let found = scan(&configuration);
        log::debug!(
            "agent notes scan: {} notes, {} files, {} unreadable, {} excluded",
            found.notes.len(),
            found.files_read,
            found.unreadable_files.len(),
            found.excluded_notes
        );
        let current = Configuration::new(&settings());
        if current != configuration {
            return !current.reads() && self.remove_all(root);
        }
        match store::apply(root, &found, &configuration.agents) {
            Ok(change) => {
                *self.last_error.lock() = None;
                !change.is_empty()
            }
            Err(err) => {
                log::warn!("agent notes update failed: {err:#}");
                *self.last_error.lock() = Some(format!("{err:#}"));
                false
            }
        }
    }

    fn remove_all(&self, root: &Path) -> bool {
        *self.last_error.lock() = None;
        if !NotesIndex::new(root).exists() {
            return false;
        }
        for attempt in 0..10 {
            if store::delete_all(root) {
                return true;
            }
            if attempt < 9 {
                std::thread::sleep(Duration::from_millis(200));
            }
        }
        false
    }

    pub fn status(&self, library: &Library) -> AgentNotesStatus {
        let saved = NotesIndex::new(library.paths().root())
            .counts()
            .unwrap_or_default();
        AgentNotesStatus {
            counts: CodingAgentKind::ALL
                .into_iter()
                .filter_map(|agent| {
                    let count = saved.get(agent.raw_value()).copied().unwrap_or(0);
                    (count > 0).then_some((agent, count))
                })
                .collect(),
            error: self.last_error.lock().clone(),
        }
    }

    fn changed_status(&self, library: &Library) -> Option<AgentNotesStatus> {
        let status = self.status(library);
        let mut reported = self.reported.lock();
        (reported.as_ref() != Some(&status)).then(|| {
            *reported = Some(status.clone());
            status
        })
    }
}

pub(crate) fn start(shared: Arc<Shared>) {
    let spawned = std::thread::Builder::new()
        .name("lokalbot-agent-notes".into())
        .spawn(move || {
            let mut next = Instant::now() + FIRST_REFRESH_DELAY;
            while !shared.is_shutting_down() {
                std::thread::sleep(Duration::from_secs(1));
                if Instant::now() < next {
                    continue;
                }
                next = Instant::now() + REFRESH_INTERVAL;
                refresh(&shared);
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start reading coding-agent notes: {err}");
    }
}

pub(crate) fn refresh(shared: &Arc<Shared>) {
    let changed = shared
        .agent_notes
        .refresh(&shared.library, || shared.settings());
    if let Some(status) = shared.agent_notes.changed_status(&shared.library) {
        shared.emit(EngineEvent::AgentNotes(status));
    }
    if changed {
        log::info!("saved coding-agent notes changed");
        shared.emit(EngineEvent::LibraryChanged);
    }
}
