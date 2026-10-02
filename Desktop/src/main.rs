mod pages;
mod style;
use gpui_kit::assets::IconName;
use gpui_kit::component::{
    Icon,
    input::{Input, InputEvent, InputState, Textarea, TextareaState},
    theme::{Theme, ThemeMode},
};
use gpui_kit::{prelude::*, *};
use lokalbot_desktop::{
    agent, audio,
    domain::Action as MeetingAction,
    domain::*,
    inference, platform, privacy, services,
    storage::{GuiLock, Library, default_root},
};
use std::{
    borrow::Cow,
    collections::BTreeMap,
    sync::mpsc::{self, Receiver, Sender},
    time::{Duration, Instant},
};
use style::*;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Page {
    Today,
    Timeline,
    Meetings,
    Ask,
    Type,
    Agent,
    Settings,
    People,
    Projects,
}
impl Page {
    fn label(self) -> &'static str {
        match self {
            Self::Today => "Today",
            Self::Timeline => "Timeline",
            Self::Meetings => "Meetings",
            Self::Ask => "Ask",
            Self::Type => "Type",
            Self::Agent => "Agent",
            Self::Settings => "Settings",
            Self::People => "People",
            Self::Projects => "Projects",
        }
    }
    fn icon(self) -> IconName {
        match self {
            Self::Today => IconName::Sun,
            Self::Timeline => IconName::Clock,
            Self::Meetings => IconName::Video,
            Self::Ask => IconName::Search,
            Self::Type => IconName::Keyboard,
            Self::Agent => IconName::Bot,
            Self::Settings => IconName::Settings,
            Self::People => IconName::User,
            Self::Projects => IconName::Folder,
        }
    }
    fn from_arg(s: &str) -> Self {
        match s {
            "meetings" => Self::Meetings,
            "timeline" => Self::Timeline,
            "ask" => Self::Ask,
            "type" => Self::Type,
            "agent" => Self::Agent,
            "settings" => Self::Settings,
            "people" => Self::People,
            "projects" => Self::Projects,
            _ => Self::Today,
        }
    }
}
enum Output {
    Refresh,
    Selected(String),
    Answer(Conversation),
    Text(String),
    Agent(agent::Task),
    Settings(Settings),
}
struct Snapshot {
    requested: Option<String>,
    meeting_revision: u64,
    meetings: Option<Vec<MeetingPreview>>,
    detail: Option<Meeting>,
    detail_loaded: bool,
    waveform: Vec<f32>,
    settings: Settings,
    moments: Vec<Moment>,
    activity: Vec<Activity>,
    today_activity: Vec<Activity>,
}
struct Event {
    kind: String,
    result: Result<Output, String>,
    backend_job: bool,
}
struct AppView {
    library: Library,
    _lock: GuiLock,
    page: Page,
    meetings: Vec<MeetingPreview>,
    detail: Option<Meeting>,
    waveform: Vec<f32>,
    meeting_revision: u64,
    notes_selection: Option<String>,
    snapshot_worker: Option<std::thread::JoinHandle<anyhow::Result<Snapshot>>>,
    refresh_requested: bool,
    moments: Vec<Moment>,
    activity: Vec<Activity>,
    today_activity: Vec<Activity>,
    settings: Settings,
    selected: Option<String>,
    tab: usize,
    query: String,
    search: Entity<InputState>,
    ask_input: Entity<InputState>,
    notes: Entity<TextareaState>,
    writing: Entity<TextareaState>,
    agent_input: Entity<InputState>,
    endpoint: Entity<InputState>,
    model: Entity<InputState>,
    key_input: Entity<InputState>,
    whisper_exe: Entity<InputState>,
    whisper_model: Entity<InputState>,
    workspace: Entity<InputState>,
    retention: Entity<InputState>,
    exclusions: Entity<InputState>,
    domains: Entity<InputState>,
    screen_days: Entity<InputState>,
    backend_choice: Backend,
    edit_action: Option<(String, String)>,
    action_text: Entity<InputState>,
    action_owner: Entity<InputState>,
    action_due: Entity<InputState>,
    answer: Option<Conversation>,
    agent_task: Option<agent::Task>,
    busy: Option<String>,
    notice: String,
    error: String,
    delete_confirm: bool,
    recording: Option<audio::Recording>,
    dictating: bool,
    playback: Option<audio::Playback>,
    seek: f64,
    sender: Sender<Event>,
    receiver: Receiver<Event>,
    focus: FocusHandle,
    _subscriptions: Vec<Subscription>,
    last_activity: Instant,
    capture_worker: Option<std::thread::JoinHandle<anyhow::Result<()>>>,
    capture_status: String,
}
impl AppView {
    fn new(
        library: Library,
        page: Page,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> anyhow::Result<Self> {
        let lock = library.gui_lock()?;
        let settings = library.settings()?;
        let meetings: Vec<MeetingPreview> = vec![];
        let selected = None;
        let make =
            |value: String, placeholder: &str, window: &mut Window, cx: &mut Context<Self>| {
                cx.new(|cx| {
                    let mut state = InputState::new(window, cx).placeholder(placeholder.to_owned());
                    state.set_value(value, window, cx);
                    state
                })
            };
        let search = make(String::new(), "Search meetings", window, cx);
        let ask_input = make(String::new(), "Ask about your work…", window, cx);
        let notes = cx.new(|cx| {
            let mut state = TextareaState::new(window, cx).placeholder("Add your notes…");
            state.set_value(
                meetings
                    .first()
                    .map(|m| m.notes.clone())
                    .unwrap_or_default(),
                window,
                cx,
            );
            state
        });
        let writing = cx
            .new(|cx| TextareaState::new(window, cx).placeholder("Type a thought, or dictate it…"));
        let agent_input = make(String::new(), "Describe a task for your agent…", window, cx);
        let endpoint = make(settings.endpoint.clone(), "Inference endpoint", window, cx);
        let model = make(settings.model.clone(), "Model ID", window, cx);
        let key_input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("OpenRouter API key (OS credential store)")
                .masked(true)
        });
        let whisper_exe = make(
            settings.whisper_executable.clone(),
            "whisper-cli executable",
            window,
            cx,
        );
        let whisper_model = make(
            settings.whisper_model.clone(),
            "Whisper GGML model path",
            window,
            cx,
        );
        let workspace = make(
            settings.agent_workspace.clone(),
            "Agent working folder",
            window,
            cx,
        );
        let retention = make(
            settings.retention_days.to_string(),
            "Retention days",
            window,
            cx,
        );
        let exclusions = make(
            settings.excluded_apps.join(", "),
            "Excluded apps",
            window,
            cx,
        );
        let domains = make(
            settings.excluded_domains.join(", "),
            "Excluded domains",
            window,
            cx,
        );
        let screen_days = make(
            settings
                .screen_access_days
                .map(|d| d.to_string())
                .unwrap_or_default(),
            "Screen access days (blank for all)",
            window,
            cx,
        );
        let action_text = make(String::new(), "Action", window, cx);
        let action_owner = make(String::new(), "Owner", window, cx);
        let action_due = make(String::new(), "Due (leave blank when unknown)", window, cx);
        let sub_search = cx.subscribe(&search, |this, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.query = input.read(cx).value().to_string();
                cx.notify();
            }
        });
        let sub_ask = cx.subscribe(&ask_input, |this, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::PressEnter { .. }) {
                this.submit_question(cx);
            }
        });
        let (sender, receiver) = mpsc::channel();
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        cx.spawn_in(window, async move |view, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(200))
                    .await;
                if view
                    .update_in(cx, |this, window, cx| this.poll(window, cx))
                    .is_err()
                {
                    break;
                }
            }
        })
        .detach();
        let mut view = Self {
            moments: vec![],
            activity: vec![],
            today_activity: vec![],
            answer: library.conversations()?.into_iter().next(),
            agent_task: library.agent_tasks()?.into_iter().next(),
            library,
            _lock: lock,
            page,
            meetings,
            detail: None,
            waveform: vec![],
            meeting_revision: u64::MAX,
            notes_selection: None,
            snapshot_worker: None,
            refresh_requested: true,
            selected,
            tab: 0,
            query: String::new(),
            search,
            ask_input,
            notes,
            writing,
            agent_input,
            endpoint,
            model,
            key_input,
            whisper_exe,
            whisper_model,
            workspace,
            retention,
            exclusions,
            domains,
            screen_days,
            backend_choice: settings.backend.clone(),
            edit_action: None,
            action_text,
            action_owner,
            action_due,
            busy: None,
            notice: String::new(),
            error: String::new(),
            delete_confirm: false,
            recording: None,
            dictating: false,
            playback: None,
            seek: 0.,
            sender,
            receiver,
            focus,
            _subscriptions: vec![sub_search, sub_ask],
            last_activity: Instant::now(),
            capture_worker: None,
            capture_status: "Waiting for desktop accessibility".into(),
            settings,
        };
        view.spawn(
            "Library recovery",
            |lib| {
                lib.recover_jobs()?;
                lib.cleanup_capture_files()?;
                audio::recover_recordings(lib)?;
                lib.expire(now())?;
                Ok(Output::Refresh)
            },
            cx,
        );
        view.refresh()?;
        Ok(view)
    }
    fn refresh(&mut self) -> anyhow::Result<()> {
        self.refresh_requested = true;
        if self.snapshot_worker.is_some() {
            return Ok(());
        }
        self.refresh_requested = false;
        let root = self.library.root.clone();
        let requested = self.selected.clone();
        let revision = self.meeting_revision;
        let cached_id = self.detail.as_ref().map(|m| m.id.clone());
        self.snapshot_worker = Some(std::thread::spawn(move || {
            let lib = Library::open(root)?;
            let meeting_revision = lib.meeting_revision()?;
            let meetings = if revision != meeting_revision {
                Some(lib.meeting_previews()?)
            } else {
                None
            };
            let id = requested
                .as_ref()
                .filter(|id| {
                    meetings
                        .as_ref()
                        .is_none_or(|ms| ms.iter().any(|m| &m.id == *id))
                })
                .cloned()
                .or_else(|| {
                    meetings
                        .as_ref()
                        .and_then(|ms| ms.first().map(|m| m.id.clone()))
                });
            // Load exactly one transcript only when selection or meeting data changed.
            let detail_loaded = revision != meeting_revision || id != cached_id;
            let detail = if detail_loaded {
                id.as_deref().map(|id| lib.meeting(id)).transpose()?
            } else {
                None
            };
            let waveform = detail
                .as_ref()
                .and_then(|m| audio::envelope(&lib, m).ok())
                .unwrap_or_default();
            let (start, end) = services::day_bounds(&services::today())?;
            Ok(Snapshot {
                requested,
                meeting_revision,
                meetings,
                detail,
                detail_loaded,
                waveform,
                settings: lib.settings()?,
                moments: lib.moments()?,
                activity: lib.activity()?,
                today_activity: lib.activity_between(start, end)?,
            })
        }));
        Ok(())
    }
    fn show_result(&mut self, result: anyhow::Result<()>, success: &str, cx: &mut Context<Self>) {
        match result {
            Ok(()) => {
                self.error.clear();
                self.notice = success.into();
                if let Err(error) = self.refresh() {
                    self.error = error.to_string();
                }
            }
            Err(error) => self.error = privacy::redact(&error.to_string()),
        }
        cx.notify();
    }
    fn spawn(
        &mut self,
        kind: &str,
        operation: impl FnOnce(&mut Library) -> anyhow::Result<Output> + Send + 'static,
        cx: &mut Context<Self>,
    ) {
        if self.busy.is_some() {
            self.error = "Wait for the current job to finish.".into();
            cx.notify();
            return;
        }
        if self.recording.is_some() {
            self.error = "Stop recording before starting model processing.".into();
            cx.notify();
            return;
        }
        self.busy = Some(kind.into());
        self.error.clear();
        let sender = self.sender.clone();
        let root = self.library.root.clone();
        let kind = kind.to_string();
        std::thread::spawn(move || {
            let result = Library::open(root)
                .and_then(|mut library| operation(&mut library))
                .map_err(|e| privacy::redact(&e.to_string()));
            let _ = sender.send(Event {
                kind,
                result,
                backend_job: true,
            });
        });
        cx.notify();
    }
    fn poll(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .snapshot_worker
            .as_ref()
            .is_some_and(|w| w.is_finished())
        {
            let worker = self.snapshot_worker.take().unwrap();
            match worker.join() {
                Ok(Ok(snapshot)) => {
                    self.meeting_revision = snapshot.meeting_revision;
                    if let Some(meetings) = snapshot.meetings {
                        self.meetings = meetings;
                    }
                    if self.selected == snapshot.requested && snapshot.detail_loaded {
                        self.selected = snapshot.detail.as_ref().map(|m| m.id.clone());
                        if self.notes_selection != self.selected {
                            self.notes.update(cx, |s, cx| {
                                s.set_value(
                                    snapshot
                                        .detail
                                        .as_ref()
                                        .map(|m| m.notes.clone())
                                        .unwrap_or_default(),
                                    window,
                                    cx,
                                )
                            });
                            self.notes_selection = self.selected.clone();
                        }
                        self.detail = snapshot.detail;
                        self.waveform = snapshot.waveform;
                    } else if self.selected != snapshot.requested {
                        self.refresh_requested = true;
                    }
                    if snapshot.settings.revision >= self.settings.revision {
                        self.settings = snapshot.settings;
                    } else {
                        self.refresh_requested = true;
                    }
                    self.moments = snapshot.moments;
                    self.activity = snapshot.activity;
                    self.today_activity = snapshot.today_activity;
                }
                Ok(Err(error)) => self.error = privacy::redact(&error.to_string()),
                Err(_) => self.error = "Library refresh stopped unexpectedly".into(),
            }
            cx.notify();
        }
        if self.refresh_requested && self.snapshot_worker.is_none() {
            let _ = self.refresh();
        }
        while let Ok(event) = self.receiver.try_recv() {
            if event.backend_job {
                self.busy = None;
            }
            match event.result {
                Ok(output) => {
                    if event.kind == "Action correction" {
                        self.edit_action = None;
                    }
                    match output {
                        Output::Refresh => {}
                        Output::Selected(id) => self.selected = Some(id),
                        Output::Answer(answer) => self.answer = Some(answer),
                        Output::Text(text) => self
                            .writing
                            .update(cx, |s, cx| s.set_value(text, window, cx)),
                        Output::Agent(task) => self.agent_task = Some(task),
                        Output::Settings(settings) => {
                            self.settings = settings;
                            self.key_input
                                .update(cx, |input, cx| input.set_value("", window, cx));
                        }
                    }
                    self.notice = format!("{} complete · saved locally", event.kind);
                    self.error.clear();
                    if let Err(error) = self.refresh() {
                        self.error = error.to_string();
                    }
                }
                Err(error) => {
                    self.error = error;
                    let _ = self.refresh();
                }
            }
            cx.notify();
        }
        if self.playback.as_mut().is_some_and(|p| p.finished()) {
            self.playback = None;
            cx.notify();
        }
        let recording_error = self
            .recording
            .as_ref()
            .and_then(|recording| recording.stream_error.lock().ok().and_then(|s| s.clone()));
        if let Some(error) = recording_error {
            self.record(false, cx);
            self.error = error;
        }
        if self.recording.is_some() {
            cx.notify();
        }
        if self
            .capture_worker
            .as_ref()
            .is_some_and(|w| w.is_finished())
            && let Some(worker) = self.capture_worker.take()
        {
            self.capture_status = match worker.join() {
                Ok(Ok(())) => "Desktop activity sampled".into(),
                Ok(Err(error)) => privacy::redact(&error.to_string()),
                Err(_) => "Desktop helper stopped unexpectedly".into(),
            };
            let _ = self.refresh();
            cx.notify();
        }
        if self.last_activity.elapsed() > Duration::from_secs(5) && self.capture_worker.is_none() {
            self.last_activity = Instant::now();
            let root = self.library.root.clone();
            self.capture_worker = Some(std::thread::spawn(move || {
                let mut lib = Library::open(root)?;
                let settings = lib.settings()?;
                lib.expire(now())?;
                if !settings.paused && settings.activity_enabled {
                    platform::sample_activity(&lib)?;
                }
                if settings.screen_text_enabled && !settings.paused {
                    platform::capture_screen(&mut lib)?;
                }
                Ok(())
            }));
        }
    }

    fn navigate(&mut self, page: Page, window: &mut Window, cx: &mut Context<Self>) {
        self.page = page;
        self.delete_confirm = false;
        window.focus(&self.focus, cx);
        cx.notify();
    }
    fn select(&mut self, id: String, tab: usize, window: &mut Window, cx: &mut Context<Self>) {
        self.selected = Some(id.clone());
        self.tab = tab;
        self.seek = 0.;
        self.playback = None;
        self.detail = None;
        self.waveform.clear();
        let _ = self.refresh();
        self.navigate(Page::Meetings, window, cx);
    }
    fn current(&self) -> Option<&Meeting> {
        self.detail
            .as_ref()
            .filter(|m| self.selected.as_ref() == Some(&m.id))
    }
    fn submit_question(&mut self, cx: &mut Context<Self>) {
        let question = self.ask_input.read(cx).value().to_string();
        if !question.trim().is_empty() {
            self.spawn(
                "Answer",
                move |lib| Ok(Output::Answer(services::ask(lib, &question)?)),
                cx,
            );
        }
    }
    fn inference_label(&self) -> String {
        format!(
            "{} · {}",
            if self.settings.backend == Backend::OpenRouter {
                "OpenRouter"
            } else {
                "Compatible server"
            },
            self.settings.model
        )
    }
    fn record(&mut self, dictation: bool, cx: &mut Context<Self>) {
        if let Some(recording) = self.recording.take() {
            let finalizing = recording.stop();
            self.dictating = false;
            self.spawn(
                "Save recording",
                move |lib| {
                    let id = finalizing.finish(lib)?;
                    if dictation {
                        services::transcribe_meeting(lib, &id)?;
                        let text = lib
                            .meeting(&id)?
                            .segments
                            .iter()
                            .map(|s| s.text.clone())
                            .collect::<Vec<_>>()
                            .join(" ");
                        lib.delete_meeting(&id)?;
                        Ok(Output::Text(text))
                    } else {
                        Ok(Output::Selected(id))
                    }
                },
                cx,
            );
        } else {
            if self.busy.is_some() {
                self.error = "Wait for the current job to finish before recording.".into();
                cx.notify();
                return;
            }
            match audio::Recording::start(
                &mut self.library,
                if dictation {
                    "Dictation scratch audio"
                } else {
                    "New meeting"
                },
            ) {
                Ok(recording) => {
                    self.selected = Some(recording.meeting_id.clone());
                    self.recording = Some(recording);
                    self.dictating = dictation;
                    self.error.clear();
                    let _ = self.refresh();
                }
                Err(error) => self.error = error.to_string(),
            }
        }
        cx.notify();
    }
    fn import(&mut self, is_audio: bool, window: &mut Window, cx: &mut Context<Self>) {
        let prompt = cx.prompt_for_paths(PathPromptOptions {
            files: true,
            directories: false,
            multiple: false,
            prompt: Some(
                if is_audio {
                    "Import audio"
                } else {
                    "Import transcript (TXT or JSON)"
                }
                .into(),
            ),
        });
        cx.spawn_in(window, async move |view, cx| {
            if let Ok(Ok(Some(paths))) = prompt.await
                && let Some(path) = paths.into_iter().next()
            {
                let _ = view.update_in(cx, |this, _, cx| {
                    this.spawn(
                        "Import",
                        move |lib| {
                            if is_audio {
                                audio::import_audio(lib, &path, None)?;
                            } else {
                                services::import_transcript(lib, &path, None)?;
                            }
                            Ok(Output::Refresh)
                        },
                        cx,
                    )
                });
            }
        })
        .detach();
    }
    fn export(&mut self, id: String, window: &mut Window, cx: &mut Context<Self>) {
        let prompt = cx.prompt_for_new_path(
            &std::env::current_dir().unwrap_or_default(),
            Some("meeting.md"),
        );
        cx.spawn_in(window, async move |view, cx| {
            if let Ok(Ok(Some(path))) = prompt.await {
                let _ = view.update_in(cx, |this, _, cx| {
                    let result = this.library.export_meeting(&id, &path);
                    this.show_result(result, "Meeting exported", cx);
                });
            }
        })
        .detach();
    }
    fn save_config(&mut self, approve: bool, _window: &mut Window, cx: &mut Context<Self>) {
        let mut s = self.settings.clone();
        s.backend = self.backend_choice.clone();
        s.endpoint = self.endpoint.read(cx).value().to_string();
        s.model = self.model.read(cx).value().to_string();
        s.whisper_executable = self.whisper_exe.read(cx).value().to_string();
        s.whisper_model = self.whisper_model.read(cx).value().to_string();
        s.agent_workspace = self.workspace.read(cx).value().to_string();
        let result: anyhow::Result<()> = (|| {
            s.retention_days = self
                .retention
                .read(cx)
                .value()
                .parse()
                .map_err(|_| anyhow::anyhow!("Retention must be a whole number of days"))?;
            s.excluded_apps = self
                .exclusions
                .read(cx)
                .value()
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect();
            s.excluded_domains = self
                .domains
                .read(cx)
                .value()
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect();
            let days = self.screen_days.read(cx).value().to_string();
            s.screen_access_days =
                if days.trim().is_empty() {
                    None
                } else {
                    Some(days.parse().map_err(|_| {
                        anyhow::anyhow!("Screen scope must be a whole number of days")
                    })?)
                };
            let origin = privacy::origin(&s.endpoint)?;
            if approve && !s.approved_origins.contains(&origin) {
                s.approved_origins.push(origin);
            }
            Ok(())
        })();
        if let Err(error) = result {
            self.error = privacy::redact(&error.to_string());
            cx.notify();
            return;
        }
        self.save_preferences(
            s,
            self.key_input.read(cx).value().to_string(),
            if approve {
                "Inference origin approval"
            } else {
                "Settings"
            },
            cx,
        );
    }
    fn toggle_setting(&mut self, change: impl FnOnce(&mut Settings), cx: &mut Context<Self>) {
        let mut settings = self.settings.clone();
        change(&mut settings);
        self.save_preferences(settings, String::new(), "Preference", cx);
    }
    fn save_preferences(
        &mut self,
        mut settings: Settings,
        key: String,
        kind: &str,
        cx: &mut Context<Self>,
    ) {
        let root = self.library.root.clone();
        let sender = self.sender.clone();
        let kind = kind.to_owned();
        std::thread::spawn(move || {
            let result = (|| {
                let mut lib = Library::open(root)?;
                if !key.is_empty() {
                    inference::save_api_key(&key)?;
                }
                lib.save_settings(&mut settings)?;
                Ok(Output::Settings(settings))
            })()
            .map_err(|e: anyhow::Error| privacy::redact(&e.to_string()));
            let _ = sender.send(Event {
                kind,
                result,
                backend_job: false,
            });
        });
        cx.notify();
    }
    fn action_row(
        &self,
        meeting_id: String,
        action: MeetingAction,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = action.id.clone();
        if self.edit_action.as_ref() == Some(&(meeting_id.clone(), id.clone())) {
            return panel()
                .p(px(16.))
                .gap(px(12.))
                .child(Input::new(&self.action_text).aria_label("Action text"))
                .child(
                    row()
                        .child(Input::new(&self.action_owner).aria_label("Action owner"))
                        .child(Input::new(&self.action_due).aria_label("Action due date")),
                )
                .child(
                    row()
                        .child(
                            button("save-action-edit", "Save correction", IconName::Check, true)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    let meeting_id = meeting_id.clone();
                                    let id = id.clone();
                                    let text = this.action_text.read(cx).value().to_string();
                                    let owner = this.action_owner.read(cx).value().to_string();
                                    let due = this.action_due.read(cx).value().to_string();
                                    this.spawn(
                                        "Action correction",
                                        move |lib| {
                                            lib.correct_action(&meeting_id, &id, text, owner, due)?;
                                            Ok(Output::Refresh)
                                        },
                                        cx,
                                    );
                                })),
                        )
                        .child(
                            button("cancel-action-edit", "Cancel", IconName::X, false).on_click(
                                cx.listener(|this, _, _, cx| {
                                    this.edit_action = None;
                                    cx.notify();
                                }),
                            ),
                        ),
                )
                .into_any_element();
        }
        let edit_meeting = meeting_id.clone();
        let edit_action = action.clone();
        row()
            .id(format!("action-{id}"))
            .py(px(13.))
            .child(
                row()
                    .id(format!("toggle-{id}"))
                    .justify_center()
                    .size(px(22.))
                    .cursor_pointer()
                    .rounded_full()
                    .border_1()
                    .border_color(rgb(if action.done { ACCENT } else { MUTED }))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        let meeting_id = meeting_id.clone();
                        let id = id.clone();
                        this.spawn(
                            "Action update",
                            move |lib| {
                                lib.toggle_action(&meeting_id, &id)?;
                                Ok(Output::Refresh)
                            },
                            cx,
                        );
                    }))
                    .when(action.done, |d| {
                        d.child(icon(IconName::Check, ACCENT).size(px(11.)))
                    }),
            )
            .child(
                column()
                    .flex_1()
                    .gap(px(5.))
                    .child(label(
                        action.text,
                        13.,
                        if action.done { MUTED } else { TEXT },
                    ))
                    .child(label(
                        format!(
                            "{} · {}",
                            action.owner,
                            if action.due.is_empty() {
                                "No due date"
                            } else {
                                &action.due
                            }
                        ),
                        11.,
                        MUTED,
                    )),
            )
            .child(
                button(
                    format!("edit-{}", edit_action.id),
                    "Edit",
                    IconName::Pencil,
                    false,
                )
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.edit_action = Some((edit_meeting.clone(), edit_action.id.clone()));
                    this.action_text.update(cx, |s, cx| {
                        s.set_value(edit_action.text.clone(), window, cx)
                    });
                    this.action_owner.update(cx, |s, cx| {
                        s.set_value(edit_action.owner.clone(), window, cx)
                    });
                    this.action_due
                        .update(cx, |s, cx| s.set_value(edit_action.due.clone(), window, cx));
                    cx.notify();
                })),
            )
            .into_any_element()
    }
    fn nav_item(&self, page: Page, shortcut: &str, cx: &mut Context<Self>) -> AnyElement {
        let active = self.page == page;
        row()
            .id(format!("nav-{}", page.label()))
            .h(px(40.))
            .px(px(12.))
            .rounded(px(7.))
            .bg(rgb(if active { ACCENT_BG } else { SIDEBAR }))
            .cursor_pointer()
            .on_click(cx.listener(move |this, _, window, cx| this.navigate(page, window, cx)))
            .child(icon(page.icon(), if active { ACCENT } else { MUTED }))
            .child(label(page.label(), 13., if active { ACCENT } else { 0xb7c0cc }).flex_1())
            .child(label(shortcut.to_owned(), 10., 0x55616d))
            .into_any_element()
    }
    fn sidebar(&self, cx: &mut Context<Self>) -> AnyElement {
        column()
            .w(px(212.))
            .h_full()
            .flex_shrink_0()
            .bg(rgb(SIDEBAR))
            .border_r_1()
            .border_color(rgb(BORDER))
            .child(
                row()
                    .h(px(85.))
                    .flex_shrink_0()
                    .px(px(21.))
                    .child(
                        row()
                            .justify_center()
                            .size(px(35.))
                            .rounded(px(10.))
                            .bg(rgb(ACCENT_BG))
                            .child(icon(IconName::Bot, ACCENT)),
                    )
                    .child(
                        column()
                            .gap(px(4.))
                            .child(heading("LokalBot", 17.))
                            .child(label("Private work memory", 10., MUTED)),
                    ),
            )
            .child(
                column()
                    .px(px(11.))
                    .gap(px(5.))
                    .child(self.nav_item(Page::Today, "1", cx))
                    .child(label("REMEMBER", 9., MUTED).mt(px(15.)).px(px(12.)))
                    .child(self.nav_item(Page::Timeline, "2", cx))
                    .child(self.nav_item(Page::Meetings, "3", cx))
                    .child(self.nav_item(Page::People, "8", cx))
                    .child(self.nav_item(Page::Projects, "9", cx))
                    .child(self.nav_item(Page::Ask, "4", cx))
                    .child(label("WRITE & ACT", 9., MUTED).mt(px(15.)).px(px(12.)))
                    .child(self.nav_item(Page::Type, "5", cx))
                    .child(self.nav_item(Page::Agent, "6", cx)),
            )
            .child(div().flex_1())
            .child(
                column()
                    .px(px(11.))
                    .pb(px(20.))
                    .gap(px(16.))
                    .child(self.nav_item(Page::Settings, "7", cx))
                    .child(separator())
                    .child(
                        label(
                            self.busy
                                .as_deref()
                                .unwrap_or("Your library stays on this device"),
                            11.,
                            if self.busy.is_some() { ACCENT } else { MUTED },
                        )
                        .px(px(11.)),
                    ),
            )
            .into_any_element()
    }
}
impl Render for AppView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let content = match self.page {
            Page::Today => self.today(cx),
            Page::Meetings => self.meetings_page(cx),
            Page::Timeline => self.timeline(cx),
            Page::Ask => self.ask_page(cx),
            Page::Settings => self.settings_page(cx),
            Page::Type => self.type_page(cx),
            Page::Agent => self.agent_page(cx),
            Page::People => self.people(cx),
            Page::Projects => self.projects(cx),
        };
        column()
            .size_full()
            .font_family("Inter Variable")
            .text_size(px(13.))
            .text_color(rgb(TEXT))
            .bg(rgb(BG))
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if event.keystroke.modifiers.control {
                    let page = match event.keystroke.key.as_str() {
                        "1" => Some(Page::Today),
                        "2" => Some(Page::Timeline),
                        "3" => Some(Page::Meetings),
                        "4" => Some(Page::Ask),
                        "5" => Some(Page::Type),
                        "6" => Some(Page::Agent),
                        "7" => Some(Page::Settings),
                        "8" => Some(Page::People),
                        "9" => Some(Page::Projects),
                        _ => None,
                    };
                    if let Some(page) = page {
                        this.navigate(page, window, cx);
                    }
                }
            }))
            .child(
                row()
                    .h(px(48.))
                    .flex_shrink_0()
                    .px(px(20.))
                    .bg(rgb(0x14181e))
                    .border_b_1()
                    .border_color(rgb(BORDER))
                    .child(icon(IconName::PanelLeft, MUTED))
                    .child(label(self.page.label(), 12., TEXT))
                    .child(div().flex_1())
                    .child(badge(
                        if self.library.root.join(".synthetic-fixture").exists() {
                            "Synthetic test library"
                        } else {
                            "Local library"
                        },
                        false,
                    )),
            )
            .child(
                row()
                    .items_start()
                    .gap(px(0.))
                    .h(window.viewport_size().height - px(74.))
                    .flex_shrink_0()
                    .w_full()
                    .child(self.sidebar(cx))
                    .child(content),
            )
            .child(
                row()
                    .h(px(26.))
                    .flex_shrink_0()
                    .px(px(14.))
                    .bg(rgb(0x0d1116))
                    .border_t_1()
                    .border_color(rgb(BORDER))
                    .child(
                        div()
                            .size(px(5.))
                            .rounded_full()
                            .bg(rgb(if self.error.is_empty() {
                                ACCENT
                            } else {
                                0xe99186
                            })),
                    )
                    .child(
                        label(
                            if !self.error.is_empty() {
                                self.error.clone()
                            } else if let Some(busy) = &self.busy {
                                format!("{busy} · {}", self.inference_label())
                            } else if !self.notice.is_empty() {
                                self.notice.clone()
                            } else {
                                "Rust + GPUI · local-first desktop".into()
                            },
                            10.,
                            MUTED,
                        )
                        .flex_1(),
                    )
                    .child(label("Ctrl 1–9 to navigate", 10., MUTED)),
            )
    }
}
fn main() {
    let args: Vec<_> = std::env::args().collect();
    let page = args
        .windows(2)
        .find(|pair| pair[0] == "--page")
        .map(|pair| Page::from_arg(&pair[1]))
        .unwrap_or(Page::Today);
    let root = match default_root() {
        Ok(root) => root,
        Err(error) => {
            eprintln!("{error}");
            return;
        }
    };
    gpui_kit::application()
        .with_assets(gpui_kit::assets::AllAssets)
        .run(move |cx| {
            gpui_kit::init(cx);
            Theme::change(ThemeMode::Dark, None, cx);
            cx.text_system()
                .add_fonts(vec![Cow::Borrowed(include_bytes!(
                    "../assets/fonts/InterVariable.ttf"
                ))])
                .expect("load Inter");
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        point(px(0.), px(0.)),
                        size(px(1440.), px(960.)),
                    ))),
                    titlebar: Some(TitlebarOptions {
                        title: Some("LokalBot — Desktop".into()),
                        ..Default::default()
                    }),
                    app_id: Some("me.dotenv.LokalBotDesktop".into()),
                    ..Default::default()
                },
                cx,
                move |window, cx| {
                    cx.new(|cx| {
                        AppView::new(
                            Library::open(&root).expect("open local library"),
                            page,
                            window,
                            cx,
                        )
                        .expect("initialize desktop app")
                    })
                },
            )
            .expect("open desktop window");
            cx.activate(true);
        });
}
