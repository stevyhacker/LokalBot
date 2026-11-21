use std::ffi::{OsStr, OsString};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use parking_lot::Mutex;

use super::PlanError;
use crate::json as model_json;

pub(crate) fn executable_names(base: &str) -> Vec<String> {
    if cfg!(windows) {
        vec![format!("{base}.exe"), format!("{base}.cmd")]
    } else {
        vec![base.to_string()]
    }
}

pub(crate) fn home_dir() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
}

pub(crate) fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        path.metadata()
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    path.is_file()
}

pub(crate) fn locate_in(
    base: &str,
    path: Option<&OsStr>,
    extra_dirs: Vec<PathBuf>,
    is_file: &dyn Fn(&Path) -> bool,
) -> Option<PathBuf> {
    let names = executable_names(base);
    let on_path = path
        .map(|p| std::env::split_paths(p).collect::<Vec<_>>())
        .unwrap_or_default()
        .into_iter()
        .filter(|dir| dir.is_absolute())
        .flat_map(|dir| names.iter().cloned().map(move |name| dir.join(name)));
    let known = extra_dirs
        .into_iter()
        .flat_map(|dir| names.iter().cloned().map(move |name| dir.join(name)));
    on_path.chain(known).find(|candidate| is_file(candidate))
}

#[cfg(unix)]
pub(crate) fn locate_with_login_shell(command_name: &str) -> Option<PathBuf> {
    let shell = std::env::var_os("SHELL")
        .map(PathBuf::from)
        .filter(|s| s.is_absolute() && is_executable(s))
        .unwrap_or_else(|| PathBuf::from("/bin/sh"));
    let mut command = Command::new(shell);
    command.args(["-lc", &format!("command -v {command_name}")]);
    let output = crate::process::run_capture(command, Duration::from_secs(5)).ok()?;
    let path = PathBuf::from(output.stdout.lines().last()?.trim());
    (path.is_absolute() && is_executable(&path)).then_some(path)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Launch {
    pub program: PathBuf,
    pub prefix: Vec<OsString>,
    pub folder: PathBuf,
}

impl Launch {
    pub fn for_executable(executable: &Path) -> Self {
        let folder = executable
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_default();
        let is_shim = executable
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("cmd") || ext.eq_ignore_ascii_case("bat"));
        if is_shim && let Some(launch) = Self::from_shim(executable, &folder) {
            return launch;
        }
        Self {
            program: executable.to_path_buf(),
            prefix: Vec::new(),
            folder,
        }
    }

    fn from_shim(shim: &Path, folder: &Path) -> Option<Self> {
        let text = std::fs::read_to_string(shim).ok()?;
        let target = text
            .split('"')
            .filter_map(|part| {
                part.strip_prefix("%dp0%\\")
                    .or_else(|| part.strip_prefix("%~dp0\\"))
            })
            .map(|relative| folder.join(relative.replace('\\', "/")))
            .find(|path| {
                let is_node = path
                    .file_stem()
                    .is_some_and(|stem| stem.eq_ignore_ascii_case("node"));
                !is_node
                    && path.extension().is_some_and(|ext| {
                        ext.eq_ignore_ascii_case("js")
                            || ext.eq_ignore_ascii_case("mjs")
                            || ext.eq_ignore_ascii_case("cjs")
                            || ext.eq_ignore_ascii_case("exe")
                    })
                    && path.is_file()
            })?;
        if target
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("exe"))
        {
            return Some(Self {
                program: target,
                prefix: Vec::new(),
                folder: folder.to_path_buf(),
            });
        }
        let local_node = folder.join("node.exe");
        let node = if local_node.is_file() {
            local_node
        } else {
            PathBuf::from("node")
        };
        Some(Self {
            program: node,
            prefix: vec![target.into_os_string()],
            folder: folder.to_path_buf(),
        })
    }

    pub fn command(&self, arguments: &[String]) -> Command {
        let mut command = Command::new(&self.program);
        command.args(&self.prefix).args(arguments);
        let mut path = vec![self.folder.clone()];
        if let Some(existing) = std::env::var_os("PATH") {
            path.extend(std::env::split_paths(&existing));
        }
        if cfg!(unix) {
            path.extend(
                ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map(PathBuf::from),
            );
        }
        let mut seen = std::collections::HashSet::new();
        path.retain(|dir| !dir.as_os_str().is_empty() && seen.insert(dir.clone()));
        if let Ok(joined) = std::env::join_paths(path) {
            command.env("PATH", joined);
        }
        command
    }
}

#[derive(Debug, Default)]
pub struct Output {
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr_tail: String,
    pub cancelled: bool,
}

pub(crate) fn write_private(root: &Path, relative: &str, contents: &str) -> std::io::Result<()> {
    let path = root.join(relative);
    if let Some(parent) = path.parent()
        && parent != root
    {
        std::fs::create_dir_all(parent)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let _ = std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700));
        }
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    options.open(&path)?.write_all(contents.as_bytes())
}

pub(crate) struct ChildSpec {
    pub program_name: &'static str,
    pub timeout: Duration,
    pub not_installed: fn() -> PlanError,
    pub failed: fn(String) -> PlanError,
}

pub(crate) fn run_child(
    #[cfg_attr(not(unix), allow(unused_mut))] mut command: Command,
    input: &str,
    cancel: Option<&AtomicBool>,
    spec: ChildSpec,
    on_line: &mut dyn FnMut(&str),
) -> Result<Output> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        command.process_group(0);
    }
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = crate::process::spawn_tied(command).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            anyhow::Error::from((spec.not_installed)())
        } else {
            (spec.failed)(format!("{} couldn't start: {err}", spec.program_name)).into()
        }
    })?;
    let stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let input = input.to_string();
    std::thread::spawn(move || {
        if let Some(mut stdin) = stdin {
            let _ = stdin.write_all(input.as_bytes());
        }
    });
    let tail = Arc::new(Mutex::new(Vec::<u8>::new()));
    let tail_writer = tail.clone();
    let errors = std::thread::spawn(move || {
        let Some(mut stderr) = stderr else { return };
        let mut chunk = [0u8; 4096];
        while let Ok(read) = stderr.read(&mut chunk) {
            if read == 0 {
                break;
            }
            let mut tail = tail_writer.lock();
            tail.extend_from_slice(&chunk[..read]);
            let excess = tail.len().saturating_sub(16_384);
            tail.drain(..excess);
        }
    });
    let (lines, received) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        let Some(stdout) = stdout else { return };
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap_or(0) > 0 {
            if lines.send(std::mem::take(&mut line)).is_err() {
                return;
            }
        }
    });
    let deadline = Instant::now() + spec.timeout;
    let mut out = String::new();
    let mut stopped: Option<&'static str> = None;
    loop {
        match received.recv_timeout(Duration::from_millis(50)) {
            Ok(line) => {
                out.push_str(&line);
                on_line(line.trim_end_matches(['\n', '\r']));
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
        }
        if cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
            stopped = Some("cancelled");
        } else if Instant::now() >= deadline {
            stopped = Some("timed out");
        }
        if stopped.is_some() {
            stop(&mut child);
            break;
        }
    }
    let status = child.wait().ok().and_then(|s| s.code());
    if stopped.is_none() {
        let _ = errors.join();
    }
    match stopped {
        Some("timed out") => Err((spec.failed)(format!(
            "{} didn't finish within {} minutes.",
            spec.program_name,
            spec.timeout.as_secs() / 60
        ))
        .into()),
        _ => Ok(Output {
            status,
            stdout: out,
            stderr_tail: String::from_utf8_lossy(&tail.lock()).into_owned(),
            cancelled: stopped.is_some(),
        }),
    }
}

fn stop(child: &mut std::process::Child) {
    #[cfg(unix)]
    {
        let group = child.id() as libc::pid_t;
        unsafe { libc::kill(-group, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if matches!(child.try_wait(), Ok(Some(_))) {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        unsafe { libc::kill(-group, libc::SIGKILL) };
    }
    crate::process::stop_child(child, Duration::ZERO);
}

pub(crate) fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' && chars.peek() == Some(&'[') {
            chars.next();
            for next in chars.by_ref() {
                if next.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(ch);
        }
    }
    out
}

pub(crate) fn extract_json_text(text: &str) -> Option<String> {
    let cleaned = model_json::strip_reasoning(text);
    let trimmed = cleaned.trim();
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed)
        && (value.is_object() || value.is_array())
    {
        return Some(model_json::sort_keys(value).to_string());
    }
    if let Some(object) = model_json::extract_json_object(trimmed)
        && let Ok(value) = serde_json::from_str::<serde_json::Value>(object)
        && value.is_object()
    {
        return Some(model_json::sort_keys(value).to_string());
    }
    None
}
