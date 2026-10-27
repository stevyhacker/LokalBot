//! LokalBot for Linux and Windows.

#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

mod assets;
mod autocomplete;
mod bridge;
mod component_i18n;
mod desktop;
mod hud;
mod i18n;
mod pages;
mod sample;
mod shell;
mod state;
mod theme;
mod ui;
mod updates;
mod windows;

use gpui_kit::component::TitleBar;
use gpui_kit::{
    App, AppContext as _, Bounds, Entity, KeyBinding, Size, Window, WindowBounds, WindowKind,
    WindowOptions, actions, px, size,
};
use lokalbot_core::{Library, LibraryPaths, Settings};

use crate::state::{AppData, AppEvent, AppHandle, Section};
use lokalbot_platform::{InstanceError, IpcCommand};

actions!(lokalbot, [Quit, ToggleRecording]);

/// Command-line options. Most users never pass any; they exist for tests,
/// screenshots and a second library.
#[derive(Default)]
struct Options {
    storage_root: Option<std::path::PathBuf>,
    section: Option<Section>,
    /// Screenshot target for the Models settings, including runtime selection.
    models_settings: bool,
    /// `--window quick-recall|onboarding` opens that window at startup.
    window: Option<String>,
    /// `--moment <id>` opens Timeline on that screen moment.
    moment: Option<i64>,
    /// Started at login: stay in the tray without opening the main window.
    autostart: bool,
    /// `lokalbot quick-recall`, `toggle-recording`, `dictate --toggle|--start|--stop`,
    /// `show`, `install-update`: forwarded to a running LokalBot, or run after
    /// startup. This is how Wayland users bind compositor shortcuts.
    command: Option<IpcCommand>,
    /// Started by an update: the copy it replaced is still quitting.
    after_update: bool,
}

fn parse_options() -> Options {
    let args: Vec<String> = std::env::args().collect();
    let mut options = Options {
        storage_root: LibraryPaths::root_from_args(&args),
        ..Default::default()
    };
    options.autostart = args
        .iter()
        .any(|a| a == lokalbot_platform::autostart::AUTOSTART_ARG);
    options.after_update = args
        .iter()
        .any(|a| a == lokalbot_update::install::AFTER_UPDATE_ARG);
    // The subcommand is the first argument that is neither an option nor an
    // option's value, so `lokalbot --lokalbot-storage-root <dir> show` works too.
    let mut positional = None;
    let mut rest = args.iter().enumerate().skip(1);
    while let Some((index, arg)) = rest.next() {
        if matches!(
            arg.as_str(),
            "--page" | "--window" | lokalbot_core::paths::STORAGE_ROOT_FLAG
        ) {
            rest.next();
        } else if !arg.starts_with("--") {
            positional = Some(index);
            break;
        }
    }
    options.command = positional.and_then(|index| match args[index].as_str() {
        "quick-recall" => Some(IpcCommand::QuickRecall),
        "toggle-recording" => Some(IpcCommand::ToggleRecording),
        "show" => Some(IpcCommand::Show),
        "install-update" => Some(IpcCommand::InstallUpdate),
        "dictate" => Some(match args.get(index + 1).map(String::as_str) {
            Some("--start") => IpcCommand::StartDictation,
            Some("--stop") => IpcCommand::StopDictation,
            _ => IpcCommand::ToggleDictation,
        }),
        _ => None,
    });
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--page" {
            if let Some(name) = iter.next() {
                options.section = section_named(name);
                options.models_settings = name.eq_ignore_ascii_case("settings-models");
            }
        } else if arg == "--window" {
            options.window = iter.next().cloned();
        } else if arg == "--moment" {
            options.moment = iter.next().and_then(|id| id.parse().ok());
        }
    }
    options
}

/// Logs go to `<library>/logs/lokalbot.log` (Settings → Advanced → Logs) and,
/// when there is one, the terminal. Release builds on Windows have no console.
fn init_logging(paths: &LibraryPaths) {
    let mut builder = env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info,zbus=warn,tracing=warn"),
    );
    if let Some(file) = open_log_file(&paths.logs_dir()) {
        builder.target(env_logger::Target::Pipe(Box::new(Tee(file))));
    }
    builder.init();
}

fn open_log_file(dir: &std::path::Path) -> Option<std::fs::File> {
    const MAX_BYTES: u64 = 5 * 1024 * 1024;
    std::fs::create_dir_all(dir).ok()?;
    let path = dir.join("lokalbot.log");
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > MAX_BYTES) {
        let _ = std::fs::rename(&path, dir.join("lokalbot.log.1"));
    }
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .ok()
}

struct Tee(std::fs::File);

impl std::io::Write for Tee {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _ = std::io::stderr().write_all(buf);
        self.0.write_all(buf)?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let _ = std::io::stderr().flush();
        self.0.flush()
    }
}

fn section_named(name: &str) -> Option<Section> {
    Some(match name.to_ascii_lowercase().as_str() {
        "today" => Section::Today,
        "meetings" => Section::Meetings,
        "timeline" => Section::Timeline,
        "people" => Section::People,
        "projects" => Section::Projects,
        "ask" => Section::Ask,
        "agent" => Section::Agent,
        "settings" | "settings-models" => Section::Settings,
        _ => return None,
    })
}

/// `lokalbot --version` (or `-V`) wherever it appears. `main` checks it before
/// anything else, so it never opens the library or wakes a running LokalBot.
fn wants_version(args: &[String]) -> bool {
    args.iter()
        .skip(1)
        .any(|arg| arg == "--version" || arg == "-V")
}

fn main() {
    if wants_version(&std::env::args().collect::<Vec<_>>()) {
        println!("LokalBot {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    let options = parse_options();
    let paths = LibraryPaths::resolve(options.storage_root.as_deref());
    if std::env::args().any(|arg| arg == "--seed-demo") {
        // Writes the fictional demo library used for screenshots, then exits.
        match lokalbot_core::demo::seed(&paths, chrono::Utc::now()) {
            Ok(()) => {
                println!("Seeded the demo library at {}", paths.root().display());
                return;
            }
            Err(err) => {
                eprintln!("Could not seed the demo library: {err:#}");
                std::process::exit(1);
            }
        }
    }
    init_logging(&paths);
    // One LokalBot per library: a second launch hands its request to the first.
    let instance = match acquire_instance(&paths, options.after_update) {
        Ok(guard) => Some(guard),
        Err(InstanceError::AlreadyRunning) => {
            let command = options.command.clone().unwrap_or(IpcCommand::Show);
            if let Err(err) = lokalbot_platform::send(paths.root(), command) {
                eprintln!("LokalBot is already running but did not respond: {err}");
                std::process::exit(1);
            }
            return;
        }
        Err(err) => {
            log::warn!("could not check for another LokalBot: {err}");
            None
        }
    };
    let library = match Library::open(paths.clone()) {
        Ok(library) => library,
        Err(err) => {
            eprintln!(
                "LokalBot could not open its library at {}: {err:#}",
                paths.root().display()
            );
            std::process::exit(1);
        }
    };
    let settings = Settings::load(&paths.settings_file());
    log::info!("library: {}", paths.root().display());
    // Only the instance that owns the library may decide a recording was
    // abandoned, and before its engine starts processing.
    if instance.is_some() {
        let recovered = lokalbot_engine::recover_unfinished_recordings(&library, &settings);
        if !recovered.is_empty() {
            log::info!(
                "closed {} recording(s) an earlier run left open",
                recovered.len()
            );
        }
    }

    gpui_kit::application()
        .with_assets(assets::Assets)
        .run(move |cx: &mut App| {
            gpui_kit::init(cx);
            i18n::apply(&settings.app_language, cx);
            assets::load_fonts(cx);
            cx.set_app_identity("com.lokalbot.LokalBot", "LokalBot");

            let data = cx.new(|_| AppData::new(library, settings));
            if let Some(section) = options.section {
                data.update(cx, |data, _| data.section = section);
            }
            if options.models_settings {
                data.update(cx, |data, cx| {
                    data.open_settings(state::SettingsCategory::Models, cx)
                });
            }
            if let Some(id) = options.moment {
                let moment = data.read(cx).library.screen_moment(id).ok().flatten();
                if let Some(moment) = moment {
                    data.update(cx, |data, cx| data.open_screen_moment(id, moment.ts, cx));
                }
            }
            cx.set_global(AppHandle(data.clone()));
            bind_actions(cx);
            if let Err(err) = bridge::start(&data, cx) {
                log::error!("the background engine could not start: {err:#}");
            }
            desktop::start(&data, paths.root(), cx);
            updates::start(&data, cx);
            autocomplete::start(&data, cx);
            let first_launch = !data.read(cx).settings.onboarding_completed;
            if !options.autostart {
                open_main_window(data.clone(), cx);
            }
            data.update(cx, |data, cx| data.reload(cx));
            match options.window.as_deref() {
                Some("quick-recall") => windows::quick_recall::open(cx),
                Some("onboarding") => windows::onboarding::open(cx),
                _ if first_launch && !options.autostart && options.section.is_none() => {
                    windows::onboarding::open(cx)
                }
                _ => {}
            }
            match options.command.clone() {
                Some(IpcCommand::QuickRecall) => windows::quick_recall::open(cx),
                Some(IpcCommand::ToggleRecording) => {
                    data.update(cx, |data, cx| data.toggle_recording(cx))
                }
                Some(IpcCommand::StartDictation | IpcCommand::ToggleDictation) => bridge::send(
                    lokalbot_engine::Command::Dictation(lokalbot_engine::DictationCommand::Start),
                    cx,
                ),
                Some(IpcCommand::InstallUpdate) => {
                    if let Some(updates) = updates::global(cx) {
                        updates.update(cx, |updates, cx| updates.install_from_command(cx));
                    }
                }
                _ => {}
            }
            // Keep the instance lock for the life of the process.
            std::mem::forget(instance);
        });
}

/// The instance lock. After an update, the copy that started this one holds
/// it until it has quit, so wait for it instead of handing over.
fn acquire_instance(
    paths: &LibraryPaths,
    after_update: bool,
) -> Result<lokalbot_platform::InstanceGuard, InstanceError> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    loop {
        match lokalbot_platform::acquire_instance(paths.root()) {
            Err(InstanceError::AlreadyRunning)
                if after_update && std::time::Instant::now() < deadline =>
            {
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
            result => {
                if after_update && result.is_ok() {
                    log::info!(
                        "LokalBot {} started after an update",
                        env!("CARGO_PKG_VERSION")
                    );
                }
                return result;
            }
        }
    }
}

fn bind_actions(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("ctrl-q", Quit, None),
        KeyBinding::new("ctrl-shift-r", ToggleRecording, None),
    ]);
    cx.on_action(|_: &Quit, cx: &mut App| cx.quit());
    cx.on_action(|_: &ToggleRecording, cx: &mut App| {
        AppData::global(cx).update(cx, |data, cx| data.toggle_recording(cx));
    });
}

pub(crate) fn open_main_window(data: Entity<AppData>, cx: &mut App) {
    let mut window_size = size(px(1280.), px(820.));
    if let Some(display) = cx.primary_display() {
        let display_size = display.bounds().size;
        window_size.width = window_size.width.min(display_size.width * 0.92);
        window_size.height = window_size.height.min(display_size.height * 0.92);
    }
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
            None,
            window_size,
            cx,
        ))),
        window_min_size: Some(Size {
            width: px(960.),
            height: px(640.),
        }),
        kind: WindowKind::Normal,
        app_id: Some("com.lokalbot.LokalBot".into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..TitleBar::window_options()
    };
    let result = gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title("LokalBot");
        apply_appearance(&data, window, cx);
        let observed = data.clone();
        window
            .observe_window_appearance(move |window, cx| apply_appearance(&observed, window, cx))
            .detach();
        let subscribed = data.clone();
        window
            .subscribe(&data, cx, move |_, event: &AppEvent, window, cx| {
                handle_event(&subscribed, event, window, cx)
            })
            .detach();
        // Closing the window keeps LokalBot in the tray when that is on and a
        // tray icon exists; otherwise it quits.
        let closing = data.clone();
        window.on_window_should_close(cx, move |_, cx| {
            let keep = closing.read(cx).settings.run_in_tray
                && desktop::desktop(cx).is_some_and(|d| d.has_tray());
            if !keep {
                cx.quit();
            }
            true
        });
        cx.new(|cx| shell::Workspace::new(window, cx))
    });
    match result {
        Ok((handle, _)) => {
            if let Some(desktop) = desktop::desktop(cx) {
                *desktop.main_window.lock() = Some(handle);
            }
        }
        Err(err) => {
            log::error!("could not open the main window: {err:#}");
            cx.quit();
        }
    }
}

fn apply_appearance(data: &Entity<AppData>, window: &mut Window, cx: &mut App) {
    let settings = data.read(cx).settings.clone();
    let dark = theme::is_dark(settings.app_theme, window.appearance());
    theme::apply(dark, settings.text_size.scale(), Some(window), cx);
}

fn handle_event(data: &Entity<AppData>, event: &AppEvent, window: &mut Window, cx: &mut App) {
    match event {
        AppEvent::AppearanceChanged => apply_appearance(data, window, cx),
        AppEvent::SettingsChanged => {
            bridge::handle_request(event, cx);
            desktop::sync_shortcuts_later(cx);
            apply_launch_at_login(data, cx);
        }
        AppEvent::OpenOnboarding => windows::onboarding::open(cx),
        AppEvent::MeetingDetected { app_name, title } => {
            desktop::notify_meeting_detected(app_name.clone(), title.clone(), cx)
        }
        AppEvent::SaveApiKey(key) => {
            let key = key.clone();
            let data = data.clone();
            cx.spawn(async move |cx| {
                let result = cx
                    .background_spawn(
                        async move { lokalbot_engine::secrets::save_openai_api_key(&key) },
                    )
                    .await;
                data.update(cx, |data, cx| match result {
                    Ok(()) => data.show_message(
                        lokalbot_i18n::tr("Saved the API key in the system credential store."),
                        cx,
                    ),
                    Err(err) => data.show_error(
                        lokalbot_i18n::format(
                            "The API key was not saved: {err}",
                            &[("err", format!("{:#}", err))],
                        ),
                        cx,
                    ),
                });
            })
            .detach();
        }
        other => {
            if !bridge::handle_request(other, cx) {
                log::debug!("unhandled request: {other:?}");
            }
        }
    }
}

/// Matches the autostart entry to "Launch LokalBot at login".
fn apply_launch_at_login(data: &Entity<AppData>, cx: &mut App) {
    let wanted = data.read(cx).settings.launch_at_login;
    cx.background_spawn(async move {
        if lokalbot_platform::launch_at_login_enabled() == wanted {
            return;
        }
        match std::env::current_exe() {
            Ok(exe) => {
                if let Err(err) = lokalbot_platform::set_launch_at_login(wanted, &exe) {
                    log::warn!("could not update launch at login: {err:#}");
                }
            }
            Err(err) => log::warn!("could not find the LokalBot executable: {err}"),
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::wants_version;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|arg| arg.to_string()).collect()
    }

    #[test]
    fn version_flag_counts_anywhere_after_the_program() {
        assert!(wants_version(&args(&["lokalbot", "--version"])));
        assert!(wants_version(&args(&["lokalbot", "-V"])));
        assert!(wants_version(&args(&[
            "lokalbot",
            "--lokalbot-storage-root",
            "/tmp/library",
            "show",
            "--version",
        ])));
        assert!(!wants_version(&args(&["lokalbot"])));
        assert!(!wants_version(&args(&["lokalbot", "show", "--autostart"])));
        assert!(!wants_version(&args(&["lokalbot", "--versions", "-v"])));
    }
}
