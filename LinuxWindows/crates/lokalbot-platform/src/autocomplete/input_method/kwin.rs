//! The route on KDE Plasma, the app's side of the KWin input method.
//!
//! Plasma runs one input method at a time, the one chosen under System Settings
//! → Keyboard → Virtual Keyboard, and talks to it over `zwp_input_method_v1`.
//! Choosing LokalBot there starts [`super::kwin_helper`], which holds that
//! connection for the session. This route connects to the helper and runs
//! [`Core`] here, like the other routes; the compositor names the window in
//! front through a KWin script (see [`super::surface`]). Until the helper is
//! running, Settings says how to choose it.
//!
//! This thread does no blocking work beyond a local socket's.

use std::os::fd::AsRawFd as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::Context as _;
use crossbeam_channel::{Receiver, Sender};

use super::super::policy::ReadPolicy;
use super::super::{AcceptKeys, FocusHandler, InputSourceSteps};
use super::kwin_wire::{self, Event, Inbox, Outbox, Request, VERSION};
use super::surface::{self, Request as Question};
use super::{Command, Content, Core, Handle, Output, Surrounding};

/// How soon to look for the helper again while it isn't there.
const RETRY_EVERY: Duration = Duration::from_secs(3);
/// After a helper from another release answered: one that matches arrives
/// only with the next session.
const RETRY_MISMATCHED: Duration = Duration::from_secs(30);

pub(super) const ENTRY_FILE: &str = "com.lokalbot.LokalBot.InputMethod.desktop";

pub(super) fn start(
    policy: ReadPolicy,
    handler: FocusHandler,
    handle: Handle,
    commands: Receiver<Command>,
    wake: UnixStream,
) -> anyhow::Result<JoinHandle<()>> {
    let (requests, questions) = crossbeam_channel::unbounded();
    let answers = handle.clone();
    // KWin enforces one input method itself, so there is nothing to look out for.
    std::thread::Builder::new()
        .name("lokalbot-input-method-surface".into())
        .spawn(move || surface::run(questions, answers, false))
        .context("could not start the input method's reader")?;
    let reading = policy.enabled;
    let core = Core::new(policy, handler, requests.clone(), handle.limitation.clone());
    let route = Route {
        core,
        link: Link::default(),
        handle,
        requests,
        reading,
        accept_keys: AcceptKeys::default(),
        retry_at: Some(Instant::now()),
    };
    std::thread::Builder::new()
        .name("lokalbot-input-method".into())
        .spawn(move || run(route, commands, wake))
        .context("could not start the input method")
}

fn run(mut route: Route, commands: Receiver<Command>, mut wake: UnixStream) {
    loop {
        while let Ok(command) = commands.try_recv() {
            if !route.command(command) {
                route.disconnect();
                let _ = route.requests.send(Question::Stop);
                return;
            }
        }
        route.tick(Instant::now());
        route.read();
        route.flush();
        let timeout = route.poll_timeout(Instant::now());
        let mut fds = vec![libc::pollfd {
            fd: wake.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        }];
        if let Some(stream) = &route.link.stream {
            let mut events = libc::POLLIN;
            if !route.link.outbox.is_empty() {
                events |= libc::POLLOUT;
            }
            fds.push(libc::pollfd {
                fd: stream.as_raw_fd(),
                events,
                revents: 0,
            });
        }
        // SAFETY: `fds` is a valid array for its length, for the whole call.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
        if ready < 0 && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            log::warn!("autocomplete: could not wait for the input method");
            break;
        }
        if fds[0].revents != 0 {
            use std::io::Read as _;
            let mut drain = [0u8; 64];
            while matches!(wake.read(&mut drain), Ok(n) if n > 0) {}
        }
    }
    route.disconnect();
    let _ = route.requests.send(Question::Stop);
    route.core.deliver_none();
}

/// The socket to the helper and what is in flight on it.
#[derive(Default)]
struct Link {
    stream: Option<UnixStream>,
    inbox: Inbox,
    outbox: Outbox,
}

impl Link {
    fn push(&mut self, request: &Request) {
        if self.stream.is_some() {
            self.outbox.push(request);
        }
    }
}

impl Output for Link {
    fn preedit(&mut self, text: &str) {
        self.push(&Request::Preedit { text: text.into() });
    }

    fn commit(&mut self, removed_before: &str, removed_after: &str, text: &str, preedit: &str) {
        self.push(&Request::Commit {
            delete_before: u32::try_from(removed_before.len()).unwrap_or(u32::MAX),
            delete_after: u32::try_from(removed_after.len()).unwrap_or(u32::MAX),
            text: text.into(),
            preedit: preedit.into(),
        });
    }

    fn release_keys(&mut self) {
        self.push(&Request::Grab { on: false });
    }
}

struct Route {
    core: Core,
    link: Link,
    handle: Handle,
    requests: Sender<Question>,
    /// Autocomplete is on, so text around the caret may come.
    reading: bool,
    accept_keys: AcceptKeys,
    /// When to look for the helper, while not connected.
    retry_at: Option<Instant>,
}

impl Route {
    /// False to stop.
    fn command(&mut self, command: Command) -> bool {
        if let Command::Policy(policy) = &command {
            self.reading = policy.enabled;
            self.link.push(&Request::Reading { on: self.reading });
        }
        match self.core.command(command, &mut self.link) {
            None => {}
            Some(Command::Stop) => return false,
            Some(Command::Keys(keys)) => {
                self.accept_keys = keys;
                self.link.push(&Request::keys(keys));
            }
            Some(Command::Grab(on)) => self.link.push(&Request::Grab { on }),
            Some(Command::PassThrough(key)) => {
                self.link.push(&Request::PassThrough { key: key.into() })
            }
            Some(_) => {}
        }
        true
    }

    fn tick(&mut self, now: Instant) {
        self.core.tick(now, &mut self.link);
        if self.link.stream.is_none() && self.retry_at.is_some_and(|at| now >= at) {
            self.connect();
        }
    }

    fn poll_timeout(&self, now: Instant) -> i32 {
        let retry = self.retry_at.filter(|_| self.link.stream.is_none());
        [self.core.next_deadline(), retry]
            .into_iter()
            .flatten()
            .min()
            .map_or(-1, |at| {
                i32::try_from(
                    at.saturating_duration_since(now)
                        .as_millis()
                        .saturating_add(1),
                )
                .unwrap_or(i32::MAX)
            })
    }

    fn connect(&mut self) {
        let stream = kwin_wire::socket_path()
            .and_then(UnixStream::connect)
            .and_then(|stream| stream.set_nonblocking(true).map(|()| stream));
        let stream = match stream {
            Ok(stream) => stream,
            Err(_) => {
                self.retry_at = Some(Instant::now() + RETRY_EVERY);
                self.core.set_limitation(Some(not_chosen_text()));
                return;
            }
        };
        log::info!("autocomplete: connected to the KWin input method");
        self.retry_at = None;
        self.link.stream = Some(stream);
        self.link.push(&Request::Hello { version: VERSION });
        self.link.push(&Request::Reading { on: self.reading });
        self.link.push(&Request::keys(self.accept_keys));
        self.core
            .set_limitation(super::module_override(|name| std::env::var(name).ok()));
    }

    fn disconnect(&mut self) {
        if self.link.stream.is_none() {
            return;
        }
        if let Some(mut stream) = self.link.stream.take() {
            let _ = self.link.outbox.flush(&mut stream);
        }
        self.link.inbox.clear();
        self.link.outbox.clear();
        self.core.deactivate(&mut self.link);
    }

    /// The helper went away: say so, and look for it again soon. KWin starts it
    /// again if it crashed.
    fn lost(&mut self, retry_after: Duration, why: String) {
        log::info!("autocomplete: the KWin input method went away");
        self.disconnect();
        self.retry_at = Some(Instant::now() + retry_after);
        self.core.set_limitation(Some(why));
    }

    fn read(&mut self) {
        let Some(stream) = &mut self.link.stream else {
            return;
        };
        if !matches!(self.link.inbox.fill(stream), Ok(true)) {
            self.lost(RETRY_EVERY, not_chosen_text());
            return;
        }
        while self.link.stream.is_some() {
            match self.link.inbox.next::<Event>() {
                None => return,
                Some(Ok(event)) => self.event(event),
                Some(Err(err)) => {
                    log::warn!("autocomplete: unreadable message from the input method: {err}");
                    self.lost(RETRY_EVERY, not_chosen_text());
                }
            }
        }
    }

    fn flush(&mut self) {
        let Some(stream) = &mut self.link.stream else {
            return;
        };
        if self.link.outbox.flush(stream).is_err() {
            self.lost(RETRY_EVERY, not_chosen_text());
        }
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Hello { version } => {
                if version != VERSION {
                    log::warn!(
                        "autocomplete: the KWin input method speaks version {version}, LokalBot {VERSION}"
                    );
                    self.lost(RETRY_MISMATCHED, mismatched_text());
                }
            }
            Event::Field => self.core.activate(&mut self.link),
            Event::NoField => self.core.deactivate(&mut self.link),
            Event::State {
                content,
                surrounding,
            } => {
                let content = content.map(|(purpose, hint)| Content { purpose, hint });
                // A field already ruled out: its text is not even held.
                let surrounding =
                    surrounding
                        .filter(|_| !self.core.refuses_text())
                        .map(|s| Surrounding {
                            text: s.text,
                            cursor: s.cursor,
                            anchor: s.anchor,
                        });
                self.core.update(content, surrounding, &mut self.link);
            }
            Event::Key { key } => {
                let handler = self.handle.keys.lock().clone();
                if let Some(handler) = handler {
                    handler(key.into());
                }
            }
            Event::Passed => self.core.blank_for_key(&mut self.link),
        }
    }
}

fn not_chosen_text() -> String {
    lokalbot_i18n::tr(
        "LokalBot is not the desktop's input method yet, so autocomplete cannot suggest in other apps. Choose it in System Settings, under Keyboard, Virtual Keyboard.",
    )
    .into()
}

fn mismatched_text() -> String {
    lokalbot_i18n::tr(
        "LokalBot was updated while its input method kept running. Log out and back in once, so KDE Plasma starts the new one.",
    )
    .into()
}

/// What the user does on KDE Plasma, worded for the Settings row.
pub(super) fn steps() -> InputSourceSteps {
    let steps = lokalbot_i18n::tr(
        "On KDE Plasma, LokalBot reaches your text fields as the desktop's input method, the way language input tools do. Open System Settings, then Keyboard, Virtual Keyboard, choose LokalBot and click Apply. Plasma then starts it with your session. It sees your key presses only while a suggestion shows, and keeps none of them. Plasma runs one input method at a time, so choosing LokalBot replaces Fcitx or IBus if one was chosen there.",
    );
    if entry_installed(&entry_dirs()) {
        return InputSourceSteps {
            text: steps.into(),
            command: None,
        };
    }
    let exe = std::env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|_| "lokalbot".into());
    InputSourceSteps {
        text: format!(
            "{steps} {}",
            lokalbot_i18n::tr(
                "This copy of LokalBot is not on that list yet. Run this in a terminal once, then open the list again:",
            )
        ),
        command: Some(setup_command(&exe)),
    }
}

/// Where KDE looks for applications, the user's own folder first.
fn entry_dirs() -> Vec<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|dir| dir.is_absolute())
        .or_else(|| home.map(|home| home.join(".local/share")));
    let data_dirs = std::env::var("XDG_DATA_DIRS")
        .ok()
        .filter(|dirs| !dirs.is_empty())
        .unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    data_home
        .into_iter()
        .chain(data_dirs.split(':').map(PathBuf::from))
        .map(|dir| dir.join("applications"))
        .collect()
}

fn entry_installed(dirs: &[PathBuf]) -> bool {
    dirs.iter()
        .any(|dir| Path::new(dir).join(ENTRY_FILE).is_file())
}

fn setup_command(exe: &str) -> String {
    format!(
        "mkdir -p ~/.local/share/applications && '{exe}' --kwin-input-method-entry > ~/.local/share/applications/{ENTRY_FILE}"
    )
}

/// The entry that lists LokalBot under Virtual Keyboard, with `exe` as what
/// Plasma starts. Packages install the same file.
pub(super) fn desktop_entry(exe: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=LokalBot\nComment=Autocomplete in other apps\nExec={} --kwin-input-method\nIcon=com.lokalbot.LokalBot\nNoDisplay=true\nX-KDE-Wayland-VirtualKeyboard=true\n",
        exec_program(exe)
    )
}

/// `exe` as the program of a desktop entry's `Exec`, quoted when it needs it.
fn exec_program(exe: &str) -> String {
    if !exe
        .chars()
        .any(|c| c.is_whitespace() || "\"'\\`$;&|<>()*?#~%".contains(c))
    {
        return exe.to_string();
    }
    let mut quoted = String::from("\"");
    for c in exe.chars() {
        match c {
            '"' | '`' | '$' | '\\' => {
                quoted.push('\\');
                quoted.push(c);
            }
            '%' => quoted.push_str("%%"),
            _ => quoted.push(c),
        }
    }
    quoted.push('"');
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_entry_puts_lokalbot_on_plasmas_virtual_keyboard_list_and_nowhere_else() {
        let entry = desktop_entry("/usr/bin/lokalbot");
        assert!(entry.starts_with("[Desktop Entry]\n"));
        assert!(entry.contains("\nExec=/usr/bin/lokalbot --kwin-input-method\n"));
        assert!(entry.contains("\nX-KDE-Wayland-VirtualKeyboard=true\n"));
        // Not in the applications menu: started alone it would do nothing.
        assert!(entry.contains("\nNoDisplay=true\n"));
    }

    #[test]
    fn the_packaged_entry_matches_what_the_app_writes() {
        let packaged = include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../packaging/linux/com.lokalbot.LokalBot.InputMethod.desktop"
        ));
        assert_eq!(packaged, desktop_entry("lokalbot"));
    }

    #[test]
    fn a_program_path_with_spaces_or_specials_is_quoted_for_exec() {
        assert_eq!(
            exec_program("/opt/LokalBot/lokalbot"),
            "/opt/LokalBot/lokalbot"
        );
        assert_eq!(
            exec_program("/home/ana/My Apps/lokalbot"),
            "\"/home/ana/My Apps/lokalbot\""
        );
        assert_eq!(exec_program("/tmp/a$b/lokalbot"), "\"/tmp/a\\$b/lokalbot\"");
        assert_eq!(
            exec_program("/tmp/100%/lokalbot"),
            "\"/tmp/100%%/lokalbot\""
        );
    }

    #[test]
    fn the_entry_counts_as_installed_in_any_applications_folder() {
        let dir = tempfile::tempdir().unwrap();
        let apps = dir.path().join("applications");
        assert!(!entry_installed(std::slice::from_ref(&apps)));
        std::fs::create_dir_all(&apps).unwrap();
        std::fs::write(apps.join(ENTRY_FILE), desktop_entry("lokalbot")).unwrap();
        assert!(entry_installed(&[dir.path().join("elsewhere"), apps]));
    }

    #[test]
    fn the_setup_command_writes_the_entry_where_plasma_reads_the_users_own() {
        let command = setup_command("/home/ana/LokalBot/lokalbot");
        assert!(command.contains("'/home/ana/LokalBot/lokalbot' --kwin-input-method-entry"));
        assert!(command.ends_with(&format!("~/.local/share/applications/{ENTRY_FILE}")));
        assert!(!command.contains("sudo"));
    }
}
