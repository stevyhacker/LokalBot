//! The Agent page's controller (`AgentRuntimeInstaller` + `AgentSessionTabs`
//! as `AppState` owns them on macOS): Agent Mode setup and the task list,
//! driven on the UI thread by each task's inbox. Created the first time the
//! Agent page opens; stops every agent when LokalBot quits.

use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use gpui_kit::{AppContext as _, Context, Entity, Subscription, Task};
use parking_lot::RwLock;

use lokalbot_agent::session::TaskInput;
use lokalbot_agent::shell::ShellChoice;
use lokalbot_agent::{
    AgentDirectories, AgentEnvironment, InstallPhase, Installer, PiLauncher, RuntimeLayout,
    RuntimeManifest, TaskList,
};
use lokalbot_core::Settings;

use crate::state::AppData;

/// How long quitting waits for agents to stop before killing them.
const QUIT_GRACE: Duration = Duration::from_millis(1500);

pub struct AgentModel {
    data: Entity<AppData>,
    installer: Arc<Installer>,
    pub phase: InstallPhase,
    pub shell: ShellChoice,
    pub tasks: Option<TaskList>,
    settings: Arc<RwLock<Settings>>,
    dirs: AgentDirectories,
    persist_task: Option<Task<()>>,
    history_loading: bool,
    _inbox: Option<Task<()>>,
    _subscriptions: Vec<Subscription>,
}

impl AgentModel {
    pub fn new(data: Entity<AppData>, cx: &mut Context<Self>) -> Self {
        let (paths, settings) = {
            let data = data.read(cx);
            (data.library.paths().clone(), data.settings.clone())
        };
        let layout = RuntimeLayout::for_library(&paths);
        let installer = Arc::new(Installer::new(layout, RuntimeManifest::current()));
        let dirs = AgentDirectories::new(&paths);
        let subscriptions = vec![
            cx.observe(&data, |this, data, cx| this.sync_settings(&data, cx)),
            cx.on_app_quit(|this, _| {
                // Every agent is asked to stop at once, then whatever is left
                // is killed; the process tree never outlives LokalBot.
                if let Some(tasks) = this.tasks.as_mut() {
                    tasks.shutdown_all(QUIT_GRACE);
                }
                async {}
            }),
        ];
        let mut model = Self {
            data,
            installer,
            phase: InstallPhase::Checking,
            shell: ShellChoice::Default,
            tasks: None,
            settings: Arc::new(RwLock::new(settings)),
            dirs,
            persist_task: None,
            history_loading: false,
            _inbox: None,
            _subscriptions: subscriptions,
        };
        model.check_receipt(cx);
        model
    }

    /// The cheap receipt check (the deep audit runs before each launch).
    fn check_receipt(&mut self, cx: &mut Context<Self>) {
        let installer = self.installer.clone();
        let markers = self.dirs.process_markers();
        cx.spawn(async move |this, cx| {
            let (phase, shell) = cx
                .background_spawn(async move {
                    // A pi left by a crashed LokalBot is stopped first.
                    lokalbot_agent::process::stop_leftovers(&markers);
                    (installer.initial_phase(), ShellChoice::detect())
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.shell = shell;
                this.set_phase(phase, cx);
            });
        })
        .detach();
    }

    fn set_phase(&mut self, phase: InstallPhase, cx: &mut Context<Self>) {
        let installed = phase == InstallPhase::Installed;
        self.phase = phase;
        if installed {
            self.ensure_tasks(cx);
        }
        cx.notify();
    }

    pub fn installer(&self) -> &Installer {
        &self.installer
    }

    pub fn is_busy(&self) -> bool {
        matches!(
            self.phase,
            InstallPhase::Checking
                | InstallPhase::Downloading { .. }
                | InstallPhase::Installing { .. }
        )
    }

    // -------------------------------------------------------------- setup

    /// "Set Up Agent Mode" / "Repair Agent Mode". Repair stops every agent
    /// first: a running Bun keeps its files open on Windows.
    pub fn install(&mut self, force: bool, cx: &mut Context<Self>) {
        if self.is_busy() {
            return;
        }
        if force && let Some(tasks) = self.tasks.as_mut() {
            for tab in &mut tasks.tabs {
                if !tab.session.park() {
                    tab.session.shutdown();
                }
            }
        }
        self.phase = InstallPhase::Downloading {
            name: lokalbot_i18n::format(
                "Bun {0}",
                &[("0", lokalbot_agent::manifest::BUN_VERSION.to_string())],
            ),
            progress: Some(0.0),
        };
        cx.notify();
        let installer = self.installer.clone();
        let (tx, rx) = async_channel::unbounded::<InstallPhase>();
        std::thread::Builder::new()
            .name("lokalbot-agent-setup".into())
            .spawn(move || {
                let cancel = AtomicBool::new(false);
                let result = installer.install(force, &cancel, &mut |phase| {
                    let _ = tx.send_blocking(phase);
                });
                if let Err(error) = result {
                    log::warn!("Agent Mode setup failed: {error}");
                    let _ = tx.send_blocking(InstallPhase::Failed(error.to_string()));
                }
            })
            .ok();
        cx.spawn(async move |this, cx| {
            while let Ok(phase) = rx.recv().await {
                if this
                    .update(cx, |this, cx| this.set_phase(phase, cx))
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();
    }

    /// "Verify Agent runtime…": hashes every runtime file. A failed audit
    /// parks every task until the runtime is repaired.
    pub fn verify(&mut self, cx: &mut Context<Self>) {
        if self.is_busy() {
            return;
        }
        self.phase = InstallPhase::Checking;
        cx.notify();
        let installer = self.installer.clone();
        cx.spawn(async move |this, cx| {
            let valid = cx.background_spawn(async move { installer.verify() }).await;
            let _ = this.update(cx, |this, cx| {
                if valid {
                    this.set_phase(InstallPhase::Installed, cx);
                    return;
                }
                if let Some(tasks) = this.tasks.as_mut() {
                    tasks.persist();
                    for tab in &mut tasks.tabs {
                        if !tab.session.park() {
                            tab.session.shutdown();
                        }
                    }
                }
                this.set_phase(
                    InstallPhase::Failed(lokalbot_i18n::tr("The installed Agent runtime failed its integrity check. Repair it before starting another session.").into()),
                    cx,
                );
            });
        })
        .detach();
    }

    // -------------------------------------------------------------- tasks

    fn ensure_tasks(&mut self, cx: &mut Context<Self>) {
        if self.tasks.is_some() {
            self.refresh_history(cx);
            return;
        }
        let (library, paths) = {
            let data = self.data.read(cx);
            (data.library.clone(), data.library.paths().clone())
        };
        let runtime = cx
            .try_global::<crate::bridge::EngineHandle>()
            .map(|engine| engine.0.runtime().clone());
        let layout = self.installer.layout().clone();
        let launcher = PiLauncher {
            paths: paths.clone(),
            dirs: self.dirs.clone(),
            layout: layout.clone(),
            manifest: self.installer.manifest().clone(),
            runtime,
            api_key: Arc::new(lokalbot_engine::secrets::openai_api_key),
            chatgpt_account: lokalbot_ai::plans::chatgpt::shared(),
            helpers_dir: PiLauncher::bundled_helpers_dir(),
            shell: None,
        };
        let env = Arc::new(AgentEnvironment {
            library,
            dirs: self.dirs.clone(),
            layout,
            settings: self.settings.clone(),
            launcher: Arc::new(launcher),
        });
        let (tx, rx) = async_channel::bounded::<TaskInput>(4096);
        self.tasks = Some(TaskList::new(env, tx));
        self._inbox = Some(cx.spawn(async move |this, cx| {
            while let Ok(input) = rx.recv().await {
                if this.update(cx, |this, cx| this.handle(input, cx)).is_err() {
                    break;
                }
            }
        }));
        self.refresh_history(cx);
    }

    fn handle(&mut self, input: TaskInput, cx: &mut Context<Self>) {
        let Some(tasks) = self.tasks.as_mut() else {
            return;
        };
        tasks.handle(input);
        if tasks.needs_persist {
            self.persist_soon(cx);
        }
        cx.notify();
    }

    /// Saves task metadata 200 ms after the last change.
    pub fn persist_soon(&mut self, cx: &mut Context<Self>) {
        self.persist_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(200))
                .await;
            let _ = this.update(cx, |this, _| {
                if let Some(tasks) = this.tasks.as_mut() {
                    tasks.persist();
                }
            });
        }));
    }

    /// Lists saved conversations off the UI thread and adds them as tasks.
    pub fn refresh_history(&mut self, cx: &mut Context<Self>) {
        let Some(tasks) = self.tasks.as_ref() else {
            return;
        };
        if self.history_loading {
            return;
        }
        self.history_loading = true;
        let directory = tasks.sessions_directory().to_path_buf();
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move { lokalbot_agent::history::load(&directory) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.history_loading = false;
                if let Some(tasks) = this.tasks.as_mut() {
                    match loaded {
                        Ok(saved) => tasks.apply_history(saved),
                        Err(err) => tasks.error = Some(format!("{err:#}")),
                    }
                    if tasks.needs_persist {
                        this.persist_soon(cx);
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Runs `change` on the task list and saves soon.
    pub fn update_tasks<R>(
        &mut self,
        cx: &mut Context<Self>,
        change: impl FnOnce(&mut TaskList) -> R,
    ) -> Option<R> {
        let tasks = self.tasks.as_mut()?;
        let result = change(tasks);
        self.persist_soon(cx);
        cx.notify();
        Some(result)
    }

    /// Settings changes reach new launches; a reasoning change also reaches
    /// running agents from their next model call.
    fn sync_settings(&mut self, data: &Entity<AppData>, cx: &mut Context<Self>) {
        let latest = data.read(cx).settings.clone();
        let changed_reasoning = {
            let current = self.settings.read();
            if *current == latest {
                return;
            }
            current.effective_agent_reasoning_level() != latest.effective_agent_reasoning_level()
        };
        *self.settings.write() = latest;
        if changed_reasoning && let Some(tasks) = self.tasks.as_mut() {
            for tab in &mut tasks.tabs {
                tab.session.reasoning_level_did_change();
            }
        }
        cx.notify();
    }
}
