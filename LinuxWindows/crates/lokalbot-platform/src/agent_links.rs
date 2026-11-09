//! Reaching a coding agent installed on this computer: whether a deep-link
//! scheme has a handler, opening such a link, and starting a command-line
//! agent in a new terminal window. The app chooses the scheme and builds the
//! link; nothing here accepts text from meetings or models as a program.

use std::path::Path;
#[cfg(target_os = "linux")]
use std::process::{Child, Command, Stdio};
#[cfg(target_os = "linux")]
use std::time::{Duration, Instant};

use anyhow::{Context as _, bail};

/// Whether something on this computer handles `scheme://` links.
pub fn handles_scheme(scheme: &str) -> bool {
    platform::handles_scheme(scheme)
}

/// Opens an agent's deep link. `url` must use a scheme `handles_scheme`
/// accepted; a handler that fails right away is reported.
pub fn open_agent_link(url: &str) -> anyhow::Result<()> {
    let parsed = url::Url::parse(url).context("not a link")?;
    if matches!(parsed.scheme(), "file" | "javascript" | "data") {
        bail!("LokalBot only opens agent links");
    }
    platform::open_link(url)
}

/// Starts `program` in a new terminal window, in `folder`. Only a program the
/// caller located is run: no prompt is ever passed on a command line, where a
/// terminal or a shell could read it as more than text.
pub fn open_in_terminal(program: &Path, folder: &Path) -> anyhow::Result<()> {
    platform::open_in_terminal(program, folder)
}

/// Waits briefly for a launcher: one that exits with an error failed, and one
/// still running after `patience` has taken over the job.
#[cfg(target_os = "linux")]
fn launched(mut child: Child, patience: Duration) -> anyhow::Result<()> {
    let start = Instant::now();
    while start.elapsed() < patience {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => bail!("it exited with {status}"),
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(err) => return Err(err.into()),
        }
    }
    // Reap it whenever it finishes.
    std::thread::spawn(move || child.wait());
    Ok(())
}

/// How each Linux terminal runs a program, most specific desktops first.
#[cfg(target_os = "linux")]
const LINUX_TERMINALS: &[(&str, &[&str])] = &[
    ("xdg-terminal-exec", &[]),
    ("x-terminal-emulator", &["-e"]),
    ("gnome-terminal", &["--"]),
    ("kgx", &["--"]),
    ("konsole", &["-e"]),
    ("xfce4-terminal", &["-x"]),
    ("mate-terminal", &["-x"]),
    ("lxterminal", &["-e"]),
    ("tilix", &["-e"]),
    ("alacritty", &["-e"]),
    ("kitty", &[]),
    ("foot", &[]),
    ("ghostty", &["-e"]),
    ("wezterm", &["start", "--"]),
    ("xterm", &["-e"]),
];

#[cfg(target_os = "linux")]
mod platform {
    use super::*;
    use crate::process::{find_program, output_with_timeout};

    pub(super) fn handles_scheme(scheme: &str) -> bool {
        let mime = format!("x-scheme-handler/{scheme}");
        if let Some(xdg) = find_program("xdg-mime") {
            let mut command = Command::new(xdg);
            command.args(["query", "default", &mime]);
            if let Ok(output) = output_with_timeout(command, Duration::from_secs(3)) {
                return handler_named(&String::from_utf8_lossy(&output.stdout));
            }
        }
        if let Some(gio) = find_program("gio") {
            let mut command = Command::new(gio);
            command.args(["mime", &mime]);
            if let Ok(output) = output_with_timeout(command, Duration::from_secs(3)) {
                return output.status.success()
                    && String::from_utf8_lossy(&output.stdout).contains(".desktop");
            }
        }
        false
    }

    pub(super) fn handler_named(output: &str) -> bool {
        output.trim().ends_with(".desktop")
    }

    pub(super) fn open_link(url: &str) -> anyhow::Result<()> {
        let opener = find_program("xdg-open")
            .or_else(|| find_program("gio"))
            .context("neither xdg-open nor gio is installed")?;
        let mut command = Command::new(&opener);
        if opener.ends_with("gio") {
            command.arg("open");
        }
        let child = command
            .arg(url)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("could not start the opener")?;
        super::launched(child, Duration::from_secs(2))
    }

    pub(super) fn open_in_terminal(program: &Path, folder: &Path) -> anyhow::Result<()> {
        let mut last_failure = None;
        // The user's own choice comes first, when it names a terminal.
        let chosen = std::env::var("TERMINAL").ok();
        let chosen = chosen
            .as_deref()
            .map(str::trim)
            .filter(|t| !t.is_empty() && !t.contains(char::is_whitespace));
        let candidates = chosen
            .map(|t| (t, &["-e"][..]))
            .into_iter()
            .chain(LINUX_TERMINALS.iter().copied());
        for (terminal, flags) in candidates {
            let Some(path) = find_program(terminal) else {
                continue;
            };
            let started = Command::new(path)
                .args(flags)
                .arg(program)
                .current_dir(folder)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn();
            match started
                .map_err(anyhow::Error::from)
                .and_then(|child| super::launched(child, Duration::from_millis(800)))
            {
                Ok(()) => return Ok(()),
                Err(err) => {
                    log::warn!("terminal {terminal} did not start: {err:#}");
                    last_failure = Some(terminal);
                }
            }
        }
        match last_failure {
            Some(terminal) => bail!("{terminal} did not start"),
            None => bail!("no terminal app was found"),
        }
    }
}

#[cfg(windows)]
mod platform {
    use std::os::windows::process::CommandExt as _;
    use std::process::{Command, Stdio};

    use windows::Win32::System::Registry::{
        HKEY, HKEY_CLASSES_ROOT, KEY_READ, RegCloseKey, RegOpenKeyExW, RegQueryValueExW,
    };
    use windows::core::{HSTRING, w};

    use super::*;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    /// A registered protocol is a key under `HKEY_CLASSES_ROOT` (which merges
    /// the user's and the machine's) holding an empty `URL Protocol` value.
    pub(super) fn handles_scheme(scheme: &str) -> bool {
        let mut key = HKEY::default();
        // SAFETY: `key` is a valid out-pointer and is closed below.
        let opened = unsafe {
            RegOpenKeyExW(
                HKEY_CLASSES_ROOT,
                &HSTRING::from(scheme),
                None,
                KEY_READ,
                &mut key,
            )
        };
        if opened.is_err() {
            return false;
        }
        // SAFETY: only asks whether the value exists; nothing is written.
        let found = unsafe { RegQueryValueExW(key, w!("URL Protocol"), None, None, None, None) };
        // SAFETY: `key` was opened above.
        let _ = unsafe { RegCloseKey(key) };
        found.is_ok()
    }

    pub(super) fn open_link(url: &str) -> anyhow::Result<()> {
        open::that_detached(url).context("could not open the link")
    }

    /// Windows Terminal when it is installed, else a console window. `cmd /k`
    /// runs `.cmd` shims and stays open if the program fails to start, so the
    /// failure is visible.
    pub(super) fn open_in_terminal(program: &Path, folder: &Path) -> anyhow::Result<()> {
        let path = program.display().to_string();
        if path.contains('"') {
            bail!("the program's path cannot be quoted");
        }
        let terminal = Command::new("wt.exe")
            .raw_arg(format!("new-tab -d . cmd /k \"{path}\""))
            .current_dir(folder)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .spawn();
        if terminal.is_ok() {
            return Ok(());
        }
        Command::new("cmd")
            .raw_arg(format!("/c start \"LokalBot\" cmd /k \"{path}\""))
            .current_dir(folder)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .context("could not start a console window")?;
        Ok(())
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod platform {
    use super::*;

    pub(super) fn handles_scheme(_: &str) -> bool {
        false
    }

    pub(super) fn open_link(url: &str) -> anyhow::Result<()> {
        open::that_detached(url).context("could not open the link")
    }

    pub(super) fn open_in_terminal(_: &Path, _: &Path) -> anyhow::Result<()> {
        bail!("not supported on this platform")
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;

    #[test]
    fn a_handler_is_a_desktop_file() {
        assert!(platform::handler_named("claude-code-url-handler.desktop\n"));
        assert!(!platform::handler_named("\n"));
        assert!(!platform::handler_named("No default"));
    }

    #[test]
    fn dangerous_schemes_are_refused() {
        assert!(open_agent_link("file:///etc/passwd").is_err());
        assert!(open_agent_link("javascript:alert(1)").is_err());
        assert!(open_agent_link("not a link").is_err());
    }

    #[test]
    fn a_launcher_that_fails_is_reported() {
        let failing = Command::new("sh").args(["-c", "exit 3"]).spawn().unwrap();
        assert!(launched(failing, Duration::from_secs(5)).is_err());
        let working = Command::new("sh").args(["-c", "exit 0"]).spawn().unwrap();
        assert!(launched(working, Duration::from_secs(5)).is_ok());
        let slow = Command::new("sh").args(["-c", "sleep 2"]).spawn().unwrap();
        assert!(launched(slow, Duration::from_millis(100)).is_ok());
    }

    /// Every terminal gets the program as one argument, after its flags.
    #[test]
    fn terminals_take_the_program_after_their_flags() {
        for (name, flags) in LINUX_TERMINALS {
            assert!(!name.is_empty());
            assert!(flags.iter().all(|f| f.starts_with('-') || *f == "start"));
        }
    }
}
