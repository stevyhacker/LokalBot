//! The system tray icon and its menu, the Linux/Windows counterpart of the
//! macOS menu bar extra (`MenuBarView.swift`).
//!
//! Linux publishes a StatusNotifierItem over D-Bus (`ksni`; KDE, GNOME with
//! the AppIndicator extension, waybar…). Windows uses `tray-icon` on a worker
//! thread with its own message loop. Create the tray from any thread (the
//! GPUI main thread is fine); `on_event` runs on a background thread.

/// One menu row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TrayItem {
    /// A line of text that cannot be chosen (the status line).
    Status(String),
    Action {
        id: String,
        label: String,
        enabled: bool,
    },
    Separator,
}

impl TrayItem {
    pub fn action(id: &str, label: &str) -> Self {
        Self::Action {
            id: id.into(),
            label: label.into(),
            enabled: true,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TrayEvent {
    /// The icon itself was clicked (left click on Windows, activate on Linux).
    Activated,
    /// A menu item was chosen, by its id.
    Item(String),
}

/// What the standard menu shows.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TrayMenuState {
    /// Included in equality so an active recording also rebuilds its menu.
    pub interface_language: String,
    pub recording: bool,
    /// "MM:SS" while recording.
    pub timer: Option<String>,
    /// Second status line: the meeting title, "Zoom detected — ready",
    /// "Asks before recording meetings", …
    pub subtitle: String,
    pub day_memory_paused: bool,
    /// Screen context is on: offer "Capture Screen Now".
    pub screen_capture: bool,
    /// A recent dictation can be copied again.
    pub recent_dictation: bool,
    /// A newer LokalBot is on offer.
    pub update: Option<TrayUpdate>,
}

/// The update row (Sparkle's "Install Update…").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrayUpdate {
    pub version: String,
    pub action: TrayUpdateAction,
    /// Downloading or installing.
    pub busy: bool,
}

/// What the update row does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrayUpdateAction {
    /// LokalBot replaces itself and relaunches.
    Install,
    /// Opens the download.
    Download,
    /// A package manager updates this copy: opens Settings, which says how.
    Show,
}

/// Menu item ids used by [`standard_items`].
pub mod item_ids {
    pub const RECORD: &str = "record";
    pub const STOP_RECORDING: &str = "stop-recording";
    pub const COPY_LAST_DICTATION: &str = "copy-last-dictation";
    pub const ASK: &str = "ask";
    pub const OPEN: &str = "open";
    pub const SETTINGS: &str = "settings";
    pub const PAUSE_DAY_MEMORY: &str = "pause-day-memory";
    pub const RESUME_DAY_MEMORY: &str = "resume-day-memory";
    pub const CAPTURE_SCREEN: &str = "capture-screen";
    pub const INSTALL_UPDATE: &str = "install-update";
    pub const DOWNLOAD_UPDATE: &str = "download-update";
    pub const SHOW_UPDATE: &str = "show-update";
    pub const QUIT: &str = "quit";
}

/// The macOS menu bar extra as a menu: status, Record Now / Stop Recording,
/// Copy last dictation once there is one, Ask, Open LokalBot, Settings…, Pause/Resume day memory, Capture Screen
/// Now while screen context is on, the update on offer, Quit LokalBot.
pub fn standard_items(state: &TrayMenuState) -> Vec<TrayItem> {
    use item_ids::*;
    use lokalbot_i18n::tr;
    let status = match (&state.timer, state.recording) {
        (Some(timer), true) => {
            lokalbot_i18n::format("Recording · {timer}", &[("timer", timer.clone())])
        }
        (None, true) => tr("Recording").to_string(),
        _ => tr("Not recording").to_string(),
    };
    let mut items = vec![TrayItem::Status(status)];
    if !state.subtitle.is_empty() {
        items.push(TrayItem::Status(state.subtitle.clone()));
    }
    items.push(TrayItem::Separator);
    items.push(if state.recording {
        TrayItem::action(STOP_RECORDING, tr("Stop Recording"))
    } else {
        TrayItem::action(RECORD, tr("Record Now"))
    });
    if state.recent_dictation {
        items.push(TrayItem::action(
            COPY_LAST_DICTATION,
            tr("Copy last dictation"),
        ));
    }
    items.push(TrayItem::Separator);
    items.push(TrayItem::action(ASK, tr("Ask")));
    items.push(TrayItem::action(OPEN, tr("Open LokalBot")));
    items.push(TrayItem::action(SETTINGS, tr("Settings…")));
    items.push(if state.day_memory_paused {
        TrayItem::action(RESUME_DAY_MEMORY, tr("Resume day memory"))
    } else {
        TrayItem::action(PAUSE_DAY_MEMORY, tr("Pause day memory"))
    });
    if state.screen_capture && !state.day_memory_paused {
        items.push(TrayItem::action(CAPTURE_SCREEN, tr("Capture Screen Now")));
    }
    items.push(TrayItem::Separator);
    if let Some(update) = &state.update {
        let version = [("version", update.version.clone())];
        items.push(match (update.busy, update.action) {
            (true, _) => TrayItem::Action {
                id: INSTALL_UPDATE.into(),
                label: lokalbot_i18n::format("Installing LokalBot {version}…", &version),
                enabled: false,
            },
            (false, TrayUpdateAction::Install) => TrayItem::action(
                INSTALL_UPDATE,
                &lokalbot_i18n::format("Install LokalBot {version} and Relaunch", &version),
            ),
            (false, TrayUpdateAction::Download) => TrayItem::action(
                DOWNLOAD_UPDATE,
                &lokalbot_i18n::format("Download LokalBot {version}…", &version),
            ),
            (false, TrayUpdateAction::Show) => TrayItem::action(
                SHOW_UPDATE,
                &lokalbot_i18n::format("LokalBot {version} is available", &version),
            ),
        });
    }
    items.push(TrayItem::action(QUIT, tr("Quit LokalBot")));
    items
}

/// RGBA pixels, width and height.
pub type TrayIcon = (Vec<u8>, u32, u32);

/// The icon with a red recording dot in its lower right corner.
pub fn recording_variant(icon: &TrayIcon) -> TrayIcon {
    let (pixels, width, height) = icon;
    let mut out = pixels.clone();
    let (w, h) = (*width as f32, *height as f32);
    let radius = w.min(h) * 0.24;
    let (cx, cy) = (w - radius - w * 0.04, h - radius - h * 0.04);
    for y in 0..*height {
        for x in 0..*width {
            let distance = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
            let index = ((y * width + x) * 4) as usize;
            let Some(pixel) = out.get_mut(index..index + 4) else {
                continue;
            };
            if distance <= radius {
                // #FF3B30, the system red the macOS menu bar uses.
                pixel.copy_from_slice(&[0xFF, 0x3B, 0x30, 0xFF]);
            } else if distance <= radius + w.min(h) * 0.06 {
                pixel.copy_from_slice(&[0xFF, 0xFF, 0xFF, 0xFF]);
            }
        }
    }
    (out, *width, *height)
}

fn tooltip_text(base: &str, recording: bool, timer: Option<&str>) -> String {
    match (recording, timer) {
        (true, Some(timer)) => format!("{base} — Recording {timer}"),
        (true, None) => format!("{base} — Recording"),
        _ => base.to_string(),
    }
}

/// The tray icon. Dropping it removes the icon.
pub struct Tray {
    inner: backend::Tray,
}

impl Tray {
    pub fn new(
        icon_rgba: TrayIcon,
        tooltip: &str,
        items: Vec<TrayItem>,
        on_activate: Box<dyn Fn(TrayEvent) + Send>,
    ) -> anyhow::Result<Tray> {
        let (_, width, height) = &icon_rgba;
        anyhow::ensure!(
            icon_rgba.0.len() == (*width as usize) * (*height as usize) * 4,
            "the tray icon must be {width}×{height} RGBA pixels"
        );
        Ok(Tray {
            inner: backend::Tray::new(icon_rgba, tooltip.to_string(), items, on_activate)?,
        })
    }

    /// Shows the recording dot and timer in the icon and tooltip.
    pub fn set_recording(&self, recording: bool, timer: Option<String>) -> anyhow::Result<()> {
        self.inner.set_recording(recording, timer)
    }

    /// Replaces the menu.
    pub fn set_items(&self, items: Vec<TrayItem>) -> anyhow::Result<()> {
        self.inner.set_items(items)
    }

    pub fn set_tooltip(&self, tooltip: &str) -> anyhow::Result<()> {
        self.inner.set_tooltip(tooltip.to_string())
    }
}

#[cfg(target_os = "linux")]
mod backend {
    use ksni::blocking::TrayMethods as _;
    use ksni::menu::{MenuItem, StandardItem};

    use super::{TrayEvent, TrayIcon, TrayItem, recording_variant, tooltip_text};

    /// ARGB32 in network byte order, as StatusNotifierItem expects.
    fn pixmap(icon: &TrayIcon) -> Vec<ksni::Icon> {
        let (pixels, width, height) = icon;
        let data = pixels
            .as_chunks::<4>()
            .0
            .iter()
            .flat_map(|[r, g, b, a]| [*a, *r, *g, *b])
            .collect();
        vec![ksni::Icon {
            width: *width as i32,
            height: *height as i32,
            data,
        }]
    }

    struct Sni {
        idle_icon: Vec<ksni::Icon>,
        recording_icon: Vec<ksni::Icon>,
        tooltip: String,
        items: Vec<TrayItem>,
        recording: bool,
        timer: Option<String>,
        on_event: Box<dyn Fn(TrayEvent) + Send>,
    }

    impl ksni::Tray for Sni {
        fn id(&self) -> String {
            crate::APP_ID.into()
        }

        fn title(&self) -> String {
            "LokalBot".into()
        }

        fn icon_pixmap(&self) -> Vec<ksni::Icon> {
            if self.recording {
                self.recording_icon.clone()
            } else {
                self.idle_icon.clone()
            }
        }

        fn tool_tip(&self) -> ksni::ToolTip {
            ksni::ToolTip {
                title: tooltip_text(&self.tooltip, self.recording, self.timer.as_deref()),
                ..Default::default()
            }
        }

        fn activate(&mut self, _x: i32, _y: i32) {
            (self.on_event)(TrayEvent::Activated);
        }

        fn menu(&self) -> Vec<MenuItem<Self>> {
            self.items
                .iter()
                .map(|item| match item {
                    TrayItem::Status(text) => StandardItem {
                        label: text.replace('_', "__"),
                        enabled: false,
                        ..Default::default()
                    }
                    .into(),
                    TrayItem::Action { id, label, enabled } => {
                        let id = id.clone();
                        StandardItem {
                            label: label.replace('_', "__"),
                            enabled: *enabled,
                            activate: Box::new(move |tray: &mut Sni| {
                                (tray.on_event)(TrayEvent::Item(id.clone()))
                            }),
                            ..Default::default()
                        }
                        .into()
                    }
                    TrayItem::Separator => MenuItem::Separator,
                })
                .collect()
        }
    }

    pub(super) struct Tray {
        handle: ksni::blocking::Handle<Sni>,
    }

    impl Tray {
        pub(super) fn new(
            icon: TrayIcon,
            tooltip: String,
            items: Vec<TrayItem>,
            on_event: Box<dyn Fn(TrayEvent) + Send>,
        ) -> anyhow::Result<Self> {
            let tray = Sni {
                idle_icon: pixmap(&icon),
                recording_icon: pixmap(&recording_variant(&icon)),
                tooltip,
                items,
                recording: false,
                timer: None,
                on_event,
            };
            let handle = tray.spawn().map_err(|err| {
                anyhow::anyhow!(
                    "the desktop has no system tray ({err}). On GNOME, the AppIndicator extension adds one."
                )
            })?;
            Ok(Self { handle })
        }

        fn update(&self, change: impl FnOnce(&mut Sni)) -> anyhow::Result<()> {
            self.handle
                .update(change)
                .ok_or_else(|| anyhow::anyhow!("the tray stopped"))
        }

        pub(super) fn set_recording(
            &self,
            recording: bool,
            timer: Option<String>,
        ) -> anyhow::Result<()> {
            self.update(|tray| {
                tray.recording = recording;
                tray.timer = timer;
            })
        }

        pub(super) fn set_items(&self, items: Vec<TrayItem>) -> anyhow::Result<()> {
            self.update(|tray| tray.items = items)
        }

        pub(super) fn set_tooltip(&self, tooltip: String) -> anyhow::Result<()> {
            self.update(|tray| tray.tooltip = tooltip)
        }
    }

    impl Drop for Tray {
        fn drop(&mut self) {
            self.handle.shutdown().wait();
        }
    }
}

#[cfg(windows)]
mod backend {
    use std::sync::{Arc, Once};

    use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
    use parking_lot::Mutex;
    use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
    use tray_icon::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};

    use super::{TrayEvent, TrayIcon, TrayItem, recording_variant, tooltip_text};

    type Handler = Arc<Mutex<Box<dyn Fn(TrayEvent) + Send>>>;

    /// `tray-icon` and `muda` allow one event handler each per process.
    static HANDLER: Mutex<Option<Handler>> = Mutex::new(None);

    fn install_handlers() {
        static ONCE: Once = Once::new();
        ONCE.call_once(|| {
            MenuEvent::set_event_handler(Some(|event: MenuEvent| {
                deliver(TrayEvent::Item(event.id.0));
            }));
            TrayIconEvent::set_event_handler(Some(|event: TrayIconEvent| {
                if let TrayIconEvent::Click {
                    button: MouseButton::Left,
                    button_state: MouseButtonState::Up,
                    ..
                } = event
                {
                    deliver(TrayEvent::Activated);
                }
            }));
        });
    }

    fn deliver(event: TrayEvent) {
        let handler = HANDLER.lock().clone();
        if let Some(handler) = handler {
            (handler.lock())(event);
        }
    }

    enum Command {
        Recording(bool, Option<String>),
        Items(Vec<TrayItem>),
        Tooltip(String),
        Stop,
    }

    pub(super) struct Tray {
        commands: Sender<Command>,
        thread_id: u32,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    fn menu(items: &[TrayItem]) -> anyhow::Result<Menu> {
        let menu = Menu::new();
        for item in items {
            match item {
                TrayItem::Status(text) => menu.append(&MenuItem::new(text, false, None))?,
                TrayItem::Action { id, label, enabled } => {
                    menu.append(&MenuItem::with_id(id.as_str(), label, *enabled, None))?
                }
                TrayItem::Separator => menu.append(&PredefinedMenuItem::separator())?,
            }
        }
        Ok(menu)
    }

    fn icon(icon: &TrayIcon) -> anyhow::Result<tray_icon::Icon> {
        Ok(tray_icon::Icon::from_rgba(icon.0.clone(), icon.1, icon.2)?)
    }

    fn run(
        base: TrayIcon,
        mut tooltip: String,
        items: Vec<TrayItem>,
        commands: Receiver<Command>,
        ready: Sender<anyhow::Result<u32>>,
    ) {
        let created = (|| -> anyhow::Result<_> {
            let idle = icon(&base)?;
            let recording = icon(&recording_variant(&base))?;
            let tray = TrayIconBuilder::new()
                .with_id(crate::APP_ID)
                .with_icon(idle.clone())
                .with_tooltip(&tooltip)
                .with_menu(Box::new(menu(&items)?))
                .with_menu_on_left_click(false)
                .build()?;
            Ok((tray, idle, recording))
        })();
        let (tray, idle, recording_icon) = match created {
            Ok(created) => created,
            Err(err) => {
                let _ = ready.send(Err(err));
                return;
            }
        };
        let mut recording = false;
        let mut timer: Option<String> = None;
        crate::win32_loop::run(
            |thread_id| {
                let _ = ready.send(Ok(thread_id));
            },
            || {
                while let Ok(command) = commands.try_recv() {
                    let result: anyhow::Result<()> = match command {
                        Command::Recording(on, time) => {
                            recording = on;
                            timer = time;
                            let shown = if on { &recording_icon } else { &idle };
                            tray.set_icon(Some(shown.clone()))
                                .map_err(Into::into)
                                .and_then(|()| {
                                    tray.set_tooltip(Some(tooltip_text(
                                        &tooltip,
                                        recording,
                                        timer.as_deref(),
                                    )))
                                    .map_err(Into::into)
                                })
                        }
                        Command::Items(items) => menu(&items).map(|menu| {
                            tray.set_menu(Some(Box::new(menu)));
                        }),
                        Command::Tooltip(text) => {
                            tooltip = text;
                            tray.set_tooltip(Some(tooltip_text(
                                &tooltip,
                                recording,
                                timer.as_deref(),
                            )))
                            .map_err(Into::into)
                        }
                        Command::Stop => return false,
                    };
                    if let Err(err) = result {
                        log::warn!("tray: {err:#}");
                    }
                }
                true
            },
        );
        drop(tray);
    }

    impl Tray {
        pub(super) fn new(
            icon: TrayIcon,
            tooltip: String,
            items: Vec<TrayItem>,
            on_event: Box<dyn Fn(TrayEvent) + Send>,
        ) -> anyhow::Result<Self> {
            install_handlers();
            *HANDLER.lock() = Some(Arc::new(Mutex::new(on_event)));
            let (commands, receiver) = unbounded();
            let (ready_tx, ready_rx) = bounded(1);
            let thread = std::thread::Builder::new()
                .name("lokalbot-tray".into())
                .spawn(move || run(icon, tooltip, items, receiver, ready_tx))?;
            let thread_id = ready_rx
                .recv()
                .map_err(|_| anyhow::anyhow!("the tray thread stopped"))??;
            Ok(Self {
                commands,
                thread_id,
                thread: Some(thread),
            })
        }

        fn send(&self, command: Command) -> anyhow::Result<()> {
            self.commands
                .send(command)
                .map_err(|_| anyhow::anyhow!("the tray stopped"))?;
            crate::win32_loop::wake(self.thread_id);
            Ok(())
        }

        pub(super) fn set_recording(
            &self,
            recording: bool,
            timer: Option<String>,
        ) -> anyhow::Result<()> {
            self.send(Command::Recording(recording, timer))
        }

        pub(super) fn set_items(&self, items: Vec<TrayItem>) -> anyhow::Result<()> {
            self.send(Command::Items(items))
        }

        pub(super) fn set_tooltip(&self, tooltip: String) -> anyhow::Result<()> {
            self.send(Command::Tooltip(tooltip))
        }
    }

    impl Drop for Tray {
        fn drop(&mut self) {
            let _ = self.send(Command::Stop);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
            *HANDLER.lock() = None;
        }
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod backend {
    use super::{TrayEvent, TrayIcon, TrayItem};

    pub(super) struct Tray;

    impl Tray {
        pub(super) fn new(
            _: TrayIcon,
            _: String,
            _: Vec<TrayItem>,
            _: Box<dyn Fn(TrayEvent) + Send>,
        ) -> anyhow::Result<Self> {
            anyhow::bail!("no system tray on this system")
        }
        pub(super) fn set_recording(&self, _: bool, _: Option<String>) -> anyhow::Result<()> {
            Ok(())
        }
        pub(super) fn set_items(&self, _: Vec<TrayItem>) -> anyhow::Result<()> {
            Ok(())
        }
        pub(super) fn set_tooltip(&self, _: String) -> anyhow::Result<()> {
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_menu_mirrors_the_menu_bar_extra() {
        let idle = standard_items(&TrayMenuState {
            subtitle: "Asks before recording meetings".into(),
            ..Default::default()
        });
        let labels: Vec<String> = idle
            .iter()
            .filter_map(|item| match item {
                TrayItem::Status(text) => Some(text.clone()),
                TrayItem::Action { label, .. } => Some(label.clone()),
                TrayItem::Separator => None,
            })
            .collect();
        assert_eq!(
            labels,
            [
                "Not recording",
                "Asks before recording meetings",
                "Record Now",
                "Ask",
                "Open LokalBot",
                "Settings…",
                "Pause day memory",
                "Quit LokalBot"
            ]
        );
        let live = standard_items(&TrayMenuState {
            recording: true,
            timer: Some("12:04".into()),
            subtitle: "Weekly sync".into(),
            day_memory_paused: true,
            screen_capture: true,
            ..Default::default()
        });
        assert_eq!(live[0], TrayItem::Status("Recording · 12:04".into()));
        assert!(live.contains(&TrayItem::action(
            item_ids::STOP_RECORDING,
            "Stop Recording"
        )));
        assert!(live.contains(&TrayItem::action(
            item_ids::RESUME_DAY_MEMORY,
            "Resume day memory"
        )));
        // Nothing is captured while day memory is paused.
        assert!(!live.iter().any(
            |item| matches!(item, TrayItem::Action { id, .. } if id == item_ids::CAPTURE_SCREEN)
        ));
        let capturing = standard_items(&TrayMenuState {
            screen_capture: true,
            ..Default::default()
        });
        assert!(capturing.contains(&TrayItem::action(
            item_ids::CAPTURE_SCREEN,
            "Capture Screen Now"
        )));
    }

    #[test]
    fn a_recent_dictation_can_be_copied_from_the_menu() {
        let copy = TrayItem::action(item_ids::COPY_LAST_DICTATION, "Copy last dictation");
        assert!(!standard_items(&TrayMenuState::default()).contains(&copy));
        let items = standard_items(&TrayMenuState {
            recent_dictation: true,
            ..Default::default()
        });
        let record = items
            .iter()
            .position(|item| *item == TrayItem::action(item_ids::RECORD, "Record Now"))
            .unwrap();
        assert_eq!(items[record + 1], copy);
    }

    #[test]
    fn an_offered_update_sits_above_quit() {
        let update = |action, busy| {
            standard_items(&TrayMenuState {
                update: Some(TrayUpdate {
                    version: "0.10.11".into(),
                    action,
                    busy,
                }),
                ..Default::default()
            })
        };
        let items = update(TrayUpdateAction::Install, false);
        let count = items.len();
        assert_eq!(
            items[count - 2],
            TrayItem::action(
                item_ids::INSTALL_UPDATE,
                "Install LokalBot 0.10.11 and Relaunch"
            )
        );
        assert_eq!(
            items[count - 1],
            TrayItem::action(item_ids::QUIT, "Quit LokalBot")
        );
        assert!(
            update(TrayUpdateAction::Download, false).contains(&TrayItem::action(
                item_ids::DOWNLOAD_UPDATE,
                "Download LokalBot 0.10.11…"
            ))
        );
        // A package manager's copy: Settings says how to update it.
        assert!(
            update(TrayUpdateAction::Show, false).contains(&TrayItem::action(
                item_ids::SHOW_UPDATE,
                "LokalBot 0.10.11 is available"
            ))
        );
        assert!(
            update(TrayUpdateAction::Install, true).contains(&TrayItem::Action {
                id: item_ids::INSTALL_UPDATE.into(),
                label: "Installing LokalBot 0.10.11…".into(),
                enabled: false,
            })
        );
        assert!(
            !standard_items(&TrayMenuState::default())
                .iter()
                .any(|item| matches!(item, TrayItem::Action { id, .. } if id.contains("update")))
        );
    }

    #[test]
    fn recording_icon_has_a_red_dot() {
        let icon = (vec![0u8; 32 * 32 * 4], 32, 32);
        let (pixels, w, h) = recording_variant(&icon);
        assert_eq!((w, h), (32, 32));
        let at =
            |x: u32, y: u32| &pixels[((y * 32 + x) * 4) as usize..((y * 32 + x) * 4 + 4) as usize];
        assert_eq!(at(23, 23), &[0xFF, 0x3B, 0x30, 0xFF]);
        assert_eq!(at(2, 2), &[0, 0, 0, 0]);
        assert_eq!(
            tooltip_text("LokalBot", true, Some("01:02")),
            "LokalBot — Recording 01:02"
        );
        assert_eq!(tooltip_text("LokalBot", false, Some("01:02")), "LokalBot");
    }

    #[test]
    fn bad_icon_sizes_are_refused() {
        let result = Tray::new(
            (vec![0; 10], 4, 4),
            "LokalBot",
            Vec::new(),
            Box::new(|_| {}),
        );
        assert!(result.is_err());
    }
}
