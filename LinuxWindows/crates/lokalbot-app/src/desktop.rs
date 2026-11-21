use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use gpui_kit::{AnyWindowHandle, App, Entity, Global, SharedString};
use parking_lot::Mutex;

use lokalbot_core::settings::DictationTriggerMode;
use lokalbot_engine::{Command, DictationCommand, SelectionCommand};
use lokalbot_platform::chord::ChordAction;
use lokalbot_platform::shortcuts::{GlobalShortcuts, Shortcut, ShortcutError, ShortcutEvent};
use lokalbot_platform::tray::{
    self, Tray, TrayEvent, TrayMenuState, TrayUpdate, TrayUpdateAction, item_ids,
};
use lokalbot_platform::{IpcCommand, IpcServer};

use crate::state::{AppData, AppEvent, DictationHud, MeetingTab, SettingsCategory};

const DICTATION_ID: &str = "dictation";
const QUICK_RECALL_ID: &str = "quick-recall";
const SELECTION_ACTIONS_ID: &str = "selection-actions";
const DICTATION_CANCEL_ID: &str = "dictation-cancel";
const DICTATION_CANCEL_HELD_ID: &str = "dictation-cancel-held";
const TAP_THRESHOLD: Duration = Duration::from_millis(300);

enum DesktopEvent {
    Tray(TrayEvent),
    Shortcut(ShortcutEvent),
    Ipc(IpcCommand),
    RecordDetected {
        title: String,
        app_name: String,
    },
    ShowUpdate,
    ShortcutsApplied(Vec<ShortcutOutcome>),
    ShortcutsUnavailable,
    #[cfg(target_os = "linux")]
    Terminate,
}

pub struct ShortcutOutcome {
    id: &'static str,
    shortcut: Shortcut,
    refusal: Option<Refusal>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    Rule,
    Taken,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RefusalAnswer {
    Leave,
    Restore(String),
    TurnOff,
}

pub fn refusal_answer(refusal: Refusal, refused: &str, working: Option<&str>) -> RefusalAnswer {
    match (refusal, working) {
        (Refusal::Rule, _) => RefusalAnswer::Leave,
        (Refusal::Taken, Some(working)) if working != refused => {
            RefusalAnswer::Restore(working.to_string())
        }
        (Refusal::Taken, _) => RefusalAnswer::TurnOff,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct WantedShortcuts {
    dictation: Option<Shortcut>,
    quick_recall: Option<Shortcut>,
    selection_actions: Option<Shortcut>,
    mode: DictationTriggerMode,
    paused: bool,
}

#[derive(Default)]
struct ShortcutSyncs {
    calls: u64,
    registered: Option<WantedShortcuts>,
}

impl ShortcutSyncs {
    fn request(&mut self, wanted: WantedShortcuts) -> Option<u64> {
        self.calls += 1;
        (self.registered != Some(wanted)).then_some(self.calls)
    }

    fn begin(&mut self, number: u64) -> bool {
        if self.calls != number {
            return false;
        }
        self.registered = None;
        true
    }

    fn finish(&mut self, number: u64, wanted: WantedShortcuts, accepted: bool) {
        if self.calls == number && accepted {
            self.registered = Some(wanted);
        }
    }
}

pub struct Desktop {
    tray: Option<Tray>,
    tray_state: Mutex<Option<TrayMenuState>>,
    shortcuts: Arc<Mutex<Option<GlobalShortcuts>>>,
    shortcut_syncs: Arc<Mutex<ShortcutSyncs>>,
    _ipc: Option<IpcServer>,
    sender: smol::channel::Sender<DesktopEvent>,
    dictation_pressed_at: Mutex<Option<Instant>>,
    dictation_cancel_keys: Arc<AtomicBool>,
    pub main_window: Mutex<Option<AnyWindowHandle>>,
    working_shortcuts: Mutex<std::collections::HashMap<&'static str, String>>,
    reported_shortcuts: Mutex<std::collections::HashMap<&'static str, String>>,
}

impl Desktop {
    pub fn has_tray(&self) -> bool {
        self.tray.is_some()
    }

    pub fn shortcuts_ready(&self) -> bool {
        self.shortcuts.lock().is_some()
    }

    pub fn main_window_is_set(&self) -> bool {
        self.main_window.lock().is_some()
    }
}

pub struct DesktopHandle(pub Arc<Desktop>);

impl Global for DesktopHandle {}

pub fn desktop(cx: &App) -> Option<Arc<Desktop>> {
    cx.try_global::<DesktopHandle>().map(|d| d.0.clone())
}

pub fn start(data: &Entity<AppData>, root: &Path, cx: &mut App) {
    let (sender, receiver) = smol::channel::unbounded::<DesktopEvent>();

    let tray = {
        let tx = sender.clone();
        match tray_icon_rgba() {
            Some(icon) => match Tray::new(
                icon,
                "LokalBot",
                tray::standard_items(&crate::tray_status::menu_state(
                    data.read(cx),
                    chrono::Utc::now(),
                    tray_update(cx),
                    0,
                )),
                if cfg!(windows) {
                    crate::tray_status::glyph_pixels()
                } else {
                    Vec::new()
                },
                Box::new(move |event| {
                    let _ = tx.send_blocking(DesktopEvent::Tray(event));
                }),
            ) {
                Ok(tray) => Some(tray),
                Err(err) => {
                    log::warn!("no tray icon: {err:#}");
                    None
                }
            },
            None => None,
        }
    };

    let ipc = {
        let tx = sender.clone();
        match lokalbot_platform::listen(root, move |command| {
            let _ = tx.send_blocking(DesktopEvent::Ipc(command));
        }) {
            Ok(server) => Some(server),
            Err(err) => {
                log::warn!("commands from other lokalbot processes are unavailable: {err}");
                None
            }
        }
    };

    let desktop = Arc::new(Desktop {
        tray,
        tray_state: Mutex::new(None),
        shortcuts: Arc::new(Mutex::new(None)),
        shortcut_syncs: Arc::new(Mutex::new(ShortcutSyncs::default())),
        _ipc: ipc,
        sender: sender.clone(),
        dictation_pressed_at: Mutex::new(None),
        dictation_cancel_keys: Arc::new(AtomicBool::new(false)),
        main_window: Mutex::new(None),
        working_shortcuts: Mutex::new(Default::default()),
        reported_shortcuts: Mutex::new(Default::default()),
    });
    cx.set_global(DesktopHandle(desktop.clone()));

    #[cfg(target_os = "linux")]
    {
        let tx = sender.clone();
        lokalbot_platform::session::on_termination(move || {
            let _ = tx.send_blocking(DesktopEvent::Terminate);
        });
    }

    {
        let shortcuts = desktop.shortcuts.clone();
        let tx = sender;
        std::thread::spawn(move || {
            let handler_tx = tx.clone();
            match GlobalShortcuts::new(move |event| {
                let _ = handler_tx.send_blocking(DesktopEvent::Shortcut(event));
            }) {
                Ok(manager) => *shortcuts.lock() = Some(manager),
                Err(err) => log::warn!("global shortcuts are unavailable: {err}"),
            }
        });
    }
    sync_shortcuts_later(cx);

    let data = data.clone();
    cx.spawn(async move |cx| {
        while let Ok(event) = receiver.recv().await {
            cx.update(|cx| handle(&data, event, cx));
        }
    })
    .detach();

    let data_for_tray = AppData::global(cx);
    cx.spawn(async move |cx| {
        loop {
            smol::Timer::after(Duration::from_secs(1)).await;
            cx.update(|cx| refresh_tray(&data_for_tray, false, cx));
        }
    })
    .detach();
}

fn tray_icon_rgba() -> Option<(Vec<u8>, u32, u32)> {
    let png = include_bytes!("../../../packaging/icons/lokalbot-32.png");
    let image = image::load_from_memory_with_format(png, image::ImageFormat::Png)
        .ok()?
        .to_rgba8();
    let (width, height) = image.dimensions();
    Some((image.into_raw(), width, height))
}

fn tray_update(cx: &App) -> Option<TrayUpdate> {
    let updates = crate::updates::global(cx)?;
    let updates = updates.read(cx);
    let release = updates.status.release()?;
    Some(TrayUpdate {
        version: release.version.to_string(),
        action: match updates.route(release) {
            crate::updates::Route::Install => TrayUpdateAction::Install,
            crate::updates::Route::Download => TrayUpdateAction::Download,
            crate::updates::Route::PackageManager => TrayUpdateAction::Show,
        },
        busy: updates.status.busy(),
    })
}

fn refresh_tray(data: &Entity<AppData>, opening: bool, cx: &mut App) {
    let Some(desktop) = desktop(cx) else { return };
    let Some(tray) = desktop.tray.as_ref() else {
        return;
    };
    let approvals =
        crate::control::global(cx).map_or(0, |host| host.read(cx).approvals.pending.len());
    let state = crate::tray_status::menu_state(
        data.read(cx),
        chrono::Utc::now(),
        tray_update(cx),
        approvals,
    );
    let mut last = desktop.tray_state.lock();
    if !opening && last.as_ref() == Some(&state) {
        return;
    }
    let _ = tray.set_items(tray::standard_items(&state));
    if last
        .as_ref()
        .is_none_or(|last| last.icon_state() != state.icon_state())
    {
        let _ = tray.set_icon_state(state.icon_state());
    }
    *last = Some(state);
}

pub fn sync_shortcuts_later(cx: &mut App) {
    let Some(desktop) = desktop(cx) else { return };
    let data = AppData::global(cx);
    let data = data.read(cx);
    let paused = data.shortcut_recording;
    let dictation = (data.settings.dictation_enabled && !paused)
        .then(|| Shortcut::parse(&data.settings.dictation_shortcut).ok())
        .flatten();
    let quick_recall = (data.settings.quick_recall_enabled && !paused)
        .then(|| Shortcut::parse(&data.settings.quick_recall_shortcut).ok())
        .flatten();
    let selection_actions = (data.settings.selection_actions_enabled && !paused)
        .then(|| Shortcut::parse(&data.settings.selection_actions_shortcut).ok())
        .flatten();
    let breaks_a_rule = [
        dictation.as_ref().and_then(|s| s.dictation_problem(None)),
        quick_recall
            .as_ref()
            .and_then(|s| s.quick_recall_problem(dictation.as_ref())),
        selection_actions
            .as_ref()
            .and_then(|s| s.selection_actions_problem(dictation.as_ref(), quick_recall.as_ref())),
    ];
    let mode = data.settings.dictation_trigger_mode;
    let shortcuts = desktop.shortcuts.clone();
    let active = desktop.dictation_cancel_keys.clone();
    let sender = desktop.sender.clone();
    let syncs = desktop.shortcut_syncs.clone();
    let wanted = WantedShortcuts {
        dictation,
        quick_recall,
        selection_actions,
        mode,
        paused,
    };
    let Some(sync) = syncs.lock().request(wanted) else {
        return;
    };
    std::thread::spawn(move || {
        for _ in 0..50 {
            if shortcuts.lock().is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        let mut guard = shortcuts.lock();
        if !syncs.lock().begin(sync) {
            return;
        }
        let Some(manager) = guard.as_mut() else {
            let _ = sender.send_blocking(DesktopEvent::ShortcutsUnavailable);
            return;
        };
        let mut outcomes = Vec::new();
        for ((id, shortcut), problem) in [
            (DICTATION_ID, dictation),
            (QUICK_RECALL_ID, quick_recall),
            (SELECTION_ACTIONS_ID, selection_actions),
        ]
        .into_iter()
        .zip(breaks_a_rule)
        {
            let _ = manager.unregister(id);
            let Some(shortcut) = shortcut else { continue };
            let result = match problem {
                Some(problem) => Err(ShortcutError::Invalid(problem)),
                None if shortcut.is_modifier_only() => {
                    manager.register_chord(id, &shortcut, mode, active.clone())
                }
                None => manager.register(id, &shortcut),
            };
            let refusal = result.err().map(|err| {
                log::warn!(
                    "could not register the {id} shortcut {}: {err}",
                    shortcut.label()
                );
                match err {
                    ShortcutError::Invalid(_) => Refusal::Rule,
                    _ => Refusal::Taken,
                }
            });
            outcomes.push(ShortcutOutcome {
                id,
                shortcut,
                refusal,
            });
        }
        let accepted = outcomes.iter().all(|outcome| outcome.refusal.is_none());
        syncs.lock().finish(sync, wanted, accepted);
        if !paused {
            let _ = sender.send_blocking(DesktopEvent::ShortcutsApplied(outcomes));
        }
    });
}

fn shortcuts_applied(data: &Entity<AppData>, outcomes: Vec<ShortcutOutcome>, cx: &mut App) {
    use lokalbot_platform::shortcuts as messages;
    let Some(desktop) = desktop(cx) else { return };
    let mut dictation_inactive = false;
    let mut said = Vec::new();
    let mut answers = Vec::new();
    for outcome in &outcomes {
        let text = outcome.shortcut.label();
        let Some(refusal) = outcome.refusal else {
            desktop
                .working_shortcuts
                .lock()
                .insert(outcome.id, text.clone());
            desktop.reported_shortcuts.lock().remove(outcome.id);
            continue;
        };
        let message = match outcome.id {
            DICTATION_ID => {
                dictation_inactive = true;
                messages::dictation_registration_failed_message(&outcome.shortcut)
            }
            QUICK_RECALL_ID => messages::ask_registration_failed_message(&outcome.shortcut),
            _ => messages::selection_actions_registration_failed_message(&outcome.shortcut),
        };
        if desktop
            .reported_shortcuts
            .lock()
            .insert(outcome.id, text.clone())
            != Some(text.clone())
        {
            said.push(message);
        }
        if outcome.id != DICTATION_ID {
            let working = desktop.working_shortcuts.lock().get(outcome.id).cloned();
            answers.push((
                outcome.id,
                refusal_answer(refusal, &text, working.as_deref()),
            ));
        }
    }
    data.update(cx, |data, cx| {
        data.dictation_shortcut_inactive = dictation_inactive;
        for message in said {
            data.show_error(message, cx);
        }
        for (id, answer) in answers {
            let quick_recall = id == QUICK_RECALL_ID;
            match answer {
                RefusalAnswer::Leave => {}
                RefusalAnswer::Restore(previous) => data.update_settings(
                    |s| {
                        if quick_recall {
                            s.quick_recall_shortcut = previous
                        } else {
                            s.selection_actions_shortcut = previous
                        }
                    },
                    cx,
                ),
                RefusalAnswer::TurnOff => data.update_settings(
                    |s| {
                        if quick_recall {
                            s.quick_recall_enabled = false
                        } else {
                            s.selection_actions_enabled = false
                        }
                    },
                    cx,
                ),
            }
        }
        cx.notify();
    });
}

pub fn sync_dictation_cancel_keys(cx: &mut App) {
    let Some(desktop) = desktop(cx) else { return };
    let data = AppData::global(cx);
    let data = data.read(cx);
    let wanted = !lokalbot_platform::session::is_wayland()
        && matches!(
            data.dictation,
            DictationHud::Starting | DictationHud::Listening { .. }
        );
    if desktop.dictation_cancel_keys.swap(wanted, Ordering::SeqCst) == wanted {
        return;
    }
    let held = Shortcut::parse(&data.settings.dictation_shortcut)
        .ok()
        .map(|shortcut| shortcut.cancel_key());
    let flag = desktop.dictation_cancel_keys.clone();
    let shortcuts = desktop.shortcuts.clone();
    std::thread::spawn(move || {
        let mut guard = shortcuts.lock();
        let Some(manager) = guard.as_mut() else {
            return;
        };
        if flag.load(Ordering::SeqCst) {
            let plain = Shortcut::parse("Esc").ok();
            for (id, key) in [
                (DICTATION_CANCEL_ID, plain),
                (
                    DICTATION_CANCEL_HELD_ID,
                    held.filter(|key| Some(*key) != plain),
                ),
            ] {
                if let Some(key) = key
                    && let Err(err) = manager.register(id, &key)
                {
                    log::debug!("could not take {} to cancel dictation: {err}", key.label());
                }
            }
        } else {
            let _ = manager.unregister(DICTATION_CANCEL_ID);
            let _ = manager.unregister(DICTATION_CANCEL_HELD_ID);
        }
    });
}

pub fn invoke_selection_actions(data: &Entity<AppData>, cx: &mut App) {
    if data.read(cx).settings.selection_actions_enabled {
        crate::bridge::send(Command::Selection(SelectionCommand::Invoke), cx);
    } else {
        data.update(cx, |data, cx| data.open_settings(SettingsCategory::Ask, cx));
    }
}

fn handle(data: &Entity<AppData>, event: DesktopEvent, cx: &mut App) {
    match event {
        DesktopEvent::Tray(TrayEvent::Activated) => show_main_window(cx),
        DesktopEvent::Tray(TrayEvent::MenuOpening) => refresh_tray(data, true, cx),
        DesktopEvent::Tray(TrayEvent::Item(id)) => match id.as_str() {
            item_ids::RECORD => crate::bridge::send(
                Command::StartRecording {
                    title: None,
                    app_name: None,
                },
                cx,
            ),
            item_ids::STOP_RECORDING => crate::bridge::send(Command::StopRecording, cx),
            item_ids::COPY_LAST_DICTATION => {
                crate::bridge::send(Command::Dictation(DictationCommand::CopyRecent(None)), cx)
            }
            item_ids::ASK => crate::windows::quick_recall::open(cx),
            item_ids::OPEN => show_main_window(cx),
            item_ids::SETTINGS => data.update(cx, |data, cx| {
                let category = data.settings_category;
                data.open_settings(category, cx)
            }),
            item_ids::LIVE_TRANSCRIPT => {
                show_main_window(cx);
                data.update(cx, |data, cx| {
                    if let Some(meeting) = data.recording.meeting().cloned() {
                        data.open_meeting(meeting.id, MeetingTab::Summary, None, cx);
                    }
                });
            }
            item_ids::DICTATION_BUTTON => {
                crate::bridge::send(Command::Dictation(DictationCommand::ToggleFromMenu), cx)
            }
            item_ids::AUTOCOMPLETE_ENABLED => data.update(cx, |data, cx| {
                data.update_settings(|s| s.cotyping_enabled = !s.cotyping_enabled, cx)
            }),
            item_ids::APPROVALS => crate::windows::settings_approval::open(cx),
            item_ids::DISMISS_ERROR => data.update(cx, |data, cx| data.dismiss_toast(cx)),
            item_ids::PAUSE_DAY_MEMORY | item_ids::RESUME_DAY_MEMORY => {
                let paused = id == item_ids::PAUSE_DAY_MEMORY;
                data.update(cx, |data, cx| {
                    data.day_memory_paused = paused;
                    cx.notify();
                });
                crate::bridge::send(Command::SetDayMemoryPaused(paused), cx);
            }
            item_ids::CAPTURE_SCREEN => crate::bridge::send(Command::CaptureScreenNow, cx),
            item_ids::INSTALL_UPDATE => {
                if let Some(updates) = crate::updates::global(cx) {
                    updates.update(cx, |updates, cx| updates.install(cx));
                }
            }
            item_ids::DOWNLOAD_UPDATE => crate::updates::open_release_page(cx),
            item_ids::SHOW_UPDATE => data.update(cx, |data, cx| {
                data.open_settings(SettingsCategory::General, cx)
            }),
            item_ids::QUIT => crate::quit::request(cx),
            other if other.starts_with(item_ids::JOIN_PREFIX) => {
                let id = other
                    .strip_prefix(item_ids::JOIN_PREFIX)
                    .unwrap_or_default();
                if let Some(url) = calendar_event(data, id, cx).and_then(|e| e.meeting_url) {
                    cx.open_url(&url);
                }
            }
            other if other.starts_with(item_ids::RECORD_EVENT_PREFIX) => {
                let id = other
                    .strip_prefix(item_ids::RECORD_EVENT_PREFIX)
                    .unwrap_or_default();
                if let Some(event) = calendar_event(data, id, cx) {
                    data.update(cx, |data, cx| {
                        data.request(AppEvent::RecordCalendarEvent(Box::new(event)), cx)
                    });
                }
            }
            other if other.starts_with(item_ids::DICTATION_PREFIX) => {
                let id = other
                    .strip_prefix(item_ids::DICTATION_PREFIX)
                    .and_then(|id| uuid::Uuid::parse_str(id).ok());
                crate::bridge::send(Command::Dictation(DictationCommand::CopyRecent(id)), cx)
            }
            other => match other
                .strip_prefix(item_ids::MEETING_PREFIX)
                .and_then(|id| uuid::Uuid::parse_str(id).ok())
            {
                Some(id) => {
                    show_main_window(cx);
                    data.update(cx, |data, cx| {
                        data.open_meeting(id, MeetingTab::Summary, None, cx)
                    });
                }
                None => log::debug!("unknown tray item {other}"),
            },
        },
        DesktopEvent::Shortcut(event) => match event.id.as_str() {
            QUICK_RECALL_ID if event.pressed => crate::windows::quick_recall::open(cx),
            SELECTION_ACTIONS_ID if event.pressed => invoke_selection_actions(data, cx),
            DICTATION_CANCEL_ID | DICTATION_CANCEL_HELD_ID if event.pressed => {
                crate::bridge::send(Command::Dictation(DictationCommand::Cancel), cx)
            }
            DICTATION_ID => match event.chord {
                Some(action) => crate::bridge::send(
                    Command::Dictation(match action {
                        ChordAction::Start => DictationCommand::Start,
                        ChordAction::Stop => DictationCommand::Stop,
                        ChordAction::Toggle => DictationCommand::Toggle,
                        ChordAction::Cancel => DictationCommand::Cancel,
                    }),
                    cx,
                ),
                None => dictation_shortcut(data, event.pressed, cx),
            },
            _ => {}
        },
        DesktopEvent::Ipc(command) => match command {
            IpcCommand::Show => show_main_window(cx),
            IpcCommand::QuickRecall => crate::windows::quick_recall::open(cx),
            IpcCommand::SelectionActions => invoke_selection_actions(data, cx),
            IpcCommand::ToggleRecording => data.update(cx, |data, cx| data.toggle_recording(cx)),
            IpcCommand::StartDictation => {
                crate::bridge::send(Command::Dictation(DictationCommand::Start), cx)
            }
            IpcCommand::StopDictation => {
                crate::bridge::send(Command::Dictation(DictationCommand::Stop), cx)
            }
            IpcCommand::ToggleDictation => {
                crate::bridge::send(Command::Dictation(DictationCommand::Toggle), cx)
            }
            IpcCommand::InstallUpdate => {
                if let Some(updates) = crate::updates::global(cx) {
                    updates.update(cx, |updates, cx| updates.install_from_command(cx));
                }
            }
            IpcCommand::OpenMeeting(id) => {
                show_main_window(cx);
                if let Ok(id) = uuid::Uuid::parse_str(&id) {
                    data.update(cx, |data, cx| {
                        data.open_meeting(id, MeetingTab::Summary, None, cx)
                    });
                }
            }
        },
        DesktopEvent::RecordDetected { title, app_name } => crate::bridge::send(
            Command::StartRecording {
                title: Some(title),
                app_name: Some(app_name),
            },
            cx,
        ),
        DesktopEvent::ShowUpdate => data.update(cx, |data, cx| {
            data.open_settings(SettingsCategory::General, cx)
        }),
        DesktopEvent::ShortcutsApplied(outcomes) => shortcuts_applied(data, outcomes, cx),
        DesktopEvent::ShortcutsUnavailable => data.update(cx, |data, cx| {
            data.dictation_shortcut_inactive = data.settings.dictation_enabled;
            cx.notify();
        }),
        #[cfg(target_os = "linux")]
        DesktopEvent::Terminate => crate::quit::request(cx),
    }
}

fn calendar_event(
    data: &Entity<AppData>,
    external_id: &str,
    cx: &App,
) -> Option<lokalbot_core::calendar::CalendarEvent> {
    data.read(cx)
        .calendar
        .events
        .iter()
        .find(|event| event.external_id == external_id)
        .cloned()
}

fn dictation_shortcut(data: &Entity<AppData>, pressed: bool, cx: &mut App) {
    let Some(desktop) = desktop(cx) else { return };
    let mode = data.read(cx).settings.dictation_trigger_mode;
    let command = match (mode, pressed) {
        (DictationTriggerMode::PushToTalk, true) => Some(DictationCommand::Start),
        (DictationTriggerMode::PushToTalk, false) => Some(DictationCommand::Stop),
        (DictationTriggerMode::Toggle, true) => Some(DictationCommand::Toggle),
        (DictationTriggerMode::Toggle, false) => None,
        (DictationTriggerMode::TapOrHold, true) => {
            *desktop.dictation_pressed_at.lock() = Some(Instant::now());
            Some(DictationCommand::Toggle)
        }
        (DictationTriggerMode::TapOrHold, false) => {
            let held = desktop
                .dictation_pressed_at
                .lock()
                .take()
                .map(|at| at.elapsed());
            held.filter(|held| *held >= TAP_THRESHOLD)
                .map(|_| DictationCommand::Stop)
        }
    };
    if let Some(command) = command {
        crate::bridge::send(Command::Dictation(command), cx);
    }
}

pub fn show_main_window(cx: &mut App) {
    let existing = desktop(cx).and_then(|d| *d.main_window.lock());
    if let Some(handle) = existing
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        return;
    }
    crate::open_main_window(AppData::global(cx), cx);
}

pub fn notify_meeting_detected(app_name: String, title: String, cx: &mut App) {
    let Some(desktop) = desktop(cx) else { return };
    let tx = desktop.sender.clone();
    std::thread::spawn(move || {
        let body = lokalbot_i18n::format("Record {title}?", &[("title", title.to_string())]);
        let callback_title = title.clone();
        let result = lokalbot_platform::notify::notify_with_timeout(
            lokalbot_i18n::tr("Meeting detected"),
            &body,
            &[
                ("record", lokalbot_i18n::tr("Record")),
                ("ignore", lokalbot_i18n::tr("Ignore")),
            ],
            Some(Box::new(move |action| {
                if action == "record" || action == "default" {
                    let _ = tx.send_blocking(DesktopEvent::RecordDetected {
                        title: callback_title.clone(),
                        app_name: app_name.clone(),
                    });
                }
            })),
            Some(lokalbot_platform::notify::MEETING_PROMPT_LIFETIME),
        );
        if let Err(err) = result {
            log::warn!(
                "{}: {err:#}",
                lokalbot_platform::notify::notifications_unavailable_message(&title)
            );
        }
    });
}

pub fn notify_recording_saved(saved: lokalbot_engine::RecordingSaved) {
    std::thread::spawn(move || {
        if let Err(err) = lokalbot_platform::notify(
            lokalbot_i18n::tr("Recording saved"),
            &saved.body(),
            &[],
            None,
        ) {
            log::debug!("recording-saved notification failed: {err:#}");
        }
    });
}

pub fn notify_capture_needs_attention(message: String) {
    std::thread::spawn(move || {
        if let Err(err) = lokalbot_platform::notify(
            lokalbot_i18n::tr("Recording needs attention"),
            lokalbot_i18n::tr(&message),
            &[],
            None,
        ) {
            log::debug!("capture warning notification failed: {err:#}");
        }
    });
}

pub fn notify_update_available(version: String, body: SharedString, cx: &mut App) {
    let Some(desktop) = desktop(cx) else { return };
    let tx = desktop.sender.clone();
    std::thread::spawn(move || {
        let title =
            lokalbot_i18n::format("LokalBot {version} is available", &[("version", version)]);
        let result = lokalbot_platform::notify(
            &title,
            &body,
            &[],
            Some(Box::new(move |action| {
                if action == "default" {
                    let _ = tx.send_blocking(DesktopEvent::ShowUpdate);
                }
            })),
        );
        if let Err(err) = result {
            log::debug!("update notification failed: {err:#}");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wanted(dictation: &str) -> WantedShortcuts {
        WantedShortcuts {
            dictation: Some(Shortcut::parse(dictation).unwrap()),
            quick_recall: None,
            selection_actions: None,
            mode: DictationTriggerMode::PushToTalk,
            paused: false,
        }
    }

    fn registered(shortcuts: WantedShortcuts) -> ShortcutSyncs {
        let mut syncs = ShortcutSyncs::default();
        let call = syncs.request(shortcuts).unwrap();
        assert!(syncs.begin(call));
        syncs.finish(call, shortcuts, true);
        syncs
    }

    #[test]
    fn a_sync_that_would_change_nothing_does_not_start() {
        let space = wanted("Ctrl+Shift+Space");
        let mut syncs = registered(space);
        assert_eq!(syncs.request(space), None);
        assert_eq!(syncs.request(space), None);
        assert!(syncs.request(wanted("Ctrl+Alt+K")).is_some());
    }

    #[test]
    fn a_refused_shortcut_is_tried_again_by_the_next_sync() {
        let space = wanted("Ctrl+Shift+Space");
        let mut syncs = ShortcutSyncs::default();
        let call = syncs.request(space).unwrap();
        assert!(syncs.begin(call));
        syncs.finish(call, space, false);
        assert!(syncs.request(space).is_some());
    }

    #[test]
    fn going_back_before_a_change_registered_leaves_what_is_registered() {
        let (space, other) = (wanted("Ctrl+Shift+Space"), wanted("Ctrl+Alt+K"));
        let mut syncs = registered(space);
        let waiting = syncs.request(other).unwrap();
        assert_eq!(syncs.request(space), None);
        assert!(
            !syncs.begin(waiting),
            "the older call registered what the settings no longer ask for"
        );
    }

    #[test]
    fn going_back_while_a_change_registers_puts_the_first_back() {
        let (space, other) = (wanted("Ctrl+Shift+Space"), wanted("Ctrl+Alt+K"));
        let mut syncs = registered(space);
        let changing = syncs.request(other).unwrap();
        assert!(syncs.begin(changing));
        let back = syncs.request(space).expect("nothing would put it back");
        syncs.finish(changing, other, true);
        assert!(syncs.begin(back));
        syncs.finish(back, space, true);
        assert_eq!(syncs.request(space), None);
        assert!(syncs.request(other).is_some());
    }

    #[test]
    fn a_taken_shortcut_goes_back_to_what_worked_or_turns_off() {
        assert_eq!(
            refusal_answer(Refusal::Taken, "Ctrl+Alt+K", Some("Ctrl+Shift+Space")),
            RefusalAnswer::Restore("Ctrl+Shift+Space".into())
        );
        assert_eq!(
            refusal_answer(Refusal::Taken, "Ctrl+Alt+K", None),
            RefusalAnswer::TurnOff
        );
        assert_eq!(
            refusal_answer(Refusal::Taken, "Ctrl+Alt+K", Some("Ctrl+Alt+K")),
            RefusalAnswer::TurnOff
        );
    }

    #[test]
    fn breaking_this_platforms_rules_changes_no_settings() {
        assert_eq!(
            refusal_answer(Refusal::Rule, "Ctrl+Shift+W", Some("Ctrl+Alt+K")),
            RefusalAnswer::Leave
        );
    }
}
