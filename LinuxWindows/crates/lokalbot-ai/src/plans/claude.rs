//! The Claude plan through the user's own Claude Code (`ClaudeCodeCLI.swift`,
//! `ClaudePlanEngine.swift`).
//!
//! The user signs in to Claude Code through Anthropic's own flow (`claude`,
//! then `/login`); LokalBot never reads, stores, or forwards Claude
//! credentials and never offers a Claude login of its own. Every request
//! runs `claude -p` in an empty private folder with tools, MCP servers,
//! slash commands, settings files and customizations off, and without
//! session persistence, so the prompt is never written to
//! `~/.claude/projects`, which LokalBot itself reads as coding-agent
//! evidence. Content goes over stdin and a private file, never the command
//! line. `--bare` is never used: it ignores the subscription sign-in.

use std::ffi::OsString;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use anyhow::Result;
use parking_lot::Mutex;
use serde_json::Value;

use lokalbot_core::settings::ReasoningLevel;

use super::PlanError;
use crate::anthropic::ModelTraits;
use crate::error::AiError;
use crate::json as model_json;
use crate::think::{ChatRequest, Completion, ReasoningSupport, Usage, ceiling_for_budget};

pub const SYSTEM_PROMPT_FILE: &str = "system-prompt.txt";
/// Claude Code's own coding-agent prompt would otherwise apply.
const FALLBACK_SYSTEM_PROMPT: &str = "You are a helpful assistant.";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(900);
const STATUS_TIMEOUT: Duration = Duration::from_secs(20);
/// Where Claude Code's installers put it; the page Settings links to.
pub const SETUP_URL: &str = "https://code.claude.com/docs/en/setup";

/// The names `claude` has on this platform. npm installs a `.cmd` shim on
/// Windows; the native installer an `.exe`.
fn executable_names() -> &'static [&'static str] {
    if cfg!(windows) {
        &["claude.exe", "claude.cmd"]
    } else {
        &["claude"]
    }
}

/// Where Claude Code's installers put `claude`, checked after PATH.
pub fn candidate_paths(home: &Path) -> Vec<PathBuf> {
    let mut dirs = vec![
        home.join(".local/bin"),
        home.join(".claude/local"),
        home.join(".npm-global/bin"),
        home.join(".bun/bin"),
        home.join(".volta/bin"),
    ];
    if cfg!(windows) {
        if let Some(app_data) = std::env::var_os("APPDATA") {
            dirs.push(PathBuf::from(app_data).join("npm"));
        }
        dirs.push(home.join("AppData/Roaming/npm"));
    } else {
        dirs.push(PathBuf::from("/usr/local/bin"));
        dirs.push(PathBuf::from("/opt/homebrew/bin"));
    }
    dirs.into_iter()
        .flat_map(|dir| executable_names().iter().map(move |name| dir.join(name)))
        .collect()
}

/// The first `claude` on `path` or in a known install location.
pub fn locate_in(
    path: Option<&std::ffi::OsStr>,
    home: Option<&Path>,
    is_file: &dyn Fn(&Path) -> bool,
) -> Option<PathBuf> {
    let on_path = path
        .map(|p| std::env::split_paths(p).collect::<Vec<_>>())
        .unwrap_or_default()
        .into_iter()
        .filter(|dir| dir.is_absolute())
        .flat_map(|dir| executable_names().iter().map(move |name| dir.join(name)));
    let known = home.map(candidate_paths).unwrap_or_default();
    on_path.chain(known).find(|candidate| is_file(candidate))
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        path.metadata()
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    path.is_file()
}

/// A desktop session started from a launcher can have a minimal PATH, so a
/// Claude Code under a Node version manager is only found through the
/// user's login shell.
#[cfg(unix)]
fn locate_with_login_shell() -> Option<PathBuf> {
    let shell = std::env::var_os("SHELL")
        .map(PathBuf::from)
        .filter(|s| s.is_absolute() && is_executable(s))
        .unwrap_or_else(|| PathBuf::from("/bin/sh"));
    let mut command = Command::new(shell);
    command.args(["-lc", "command -v claude"]);
    let output = crate::process::run_capture(command, Duration::from_secs(5)).ok()?;
    let path = PathBuf::from(output.stdout.lines().last()?.trim());
    (path.is_absolute() && is_executable(&path)).then_some(path)
}

/// Finds Claude Code once per launch; `refresh` looks again.
pub fn locate(refresh: bool) -> Option<PathBuf> {
    static CACHED: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();
    let cache = CACHED.get_or_init(|| Mutex::new(None));
    if !refresh
        && let Some(found) = cache.lock().clone()
        && is_executable(&found)
    {
        return Some(found);
    }
    let path = std::env::var_os("PATH");
    let mut found = locate_in(path.as_deref(), home_dir().as_deref(), &is_executable);
    #[cfg(unix)]
    if found.is_none() {
        found = locate_with_login_shell();
    }
    *cache.lock() = found.clone();
    found
}

/// How to start Claude Code. An npm `.cmd` shim is resolved to the script it
/// runs, so arguments never pass through `cmd.exe`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Launch {
    pub program: PathBuf,
    pub prefix: Vec<OsString>,
    /// Put first on the child's PATH, so an npm-installed `claude` finds its
    /// `node`.
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

    /// npm's cmd-shim names its target as `"%dp0%\…"`: a `.js` entry run by
    /// `node` (next to the shim, else on PATH) or a native `.exe`.
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
                // The shim also names the `node.exe` it may run the script with.
                let is_node = path
                    .file_stem()
                    .is_some_and(|stem| stem.eq_ignore_ascii_case("node"));
                !is_node
                    && path.extension().is_some_and(|ext| {
                        ext.eq_ignore_ascii_case("js") || ext.eq_ignore_ascii_case("exe")
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

    /// The command, with LokalBot's environment minus `CLAUDECODE` (started
    /// from inside a Claude Code session the child would otherwise refuse to
    /// run as a nested session) and the executable's folder first on PATH.
    pub fn command(&self, arguments: &[String]) -> Command {
        let mut command = Command::new(&self.program);
        command.args(&self.prefix).args(arguments);
        command.env_remove("CLAUDECODE");
        let mut path = vec![self.folder.clone()];
        if let Some(existing) = std::env::var_os("PATH") {
            path.extend(std::env::split_paths(&existing));
        }
        if cfg!(unix) {
            path.extend(["/usr/local/bin", "/usr/bin", "/bin"].map(PathBuf::from));
        }
        let mut seen = std::collections::HashSet::new();
        path.retain(|dir| !dir.as_os_str().is_empty() && seen.insert(dir.clone()));
        if let Ok(joined) = std::env::join_paths(path) {
            command.env("PATH", joined);
        }
        command
    }
}

/// `claude auth status`: the sign-in without credentials.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AuthStatus {
    pub logged_in: bool,
    pub auth_method: Option<String>,
    pub email: Option<String>,
    pub subscription_type: Option<String>,
}

impl AuthStatus {
    pub fn parse(text: &str) -> Option<Self> {
        let json: Value = serde_json::from_str(text.trim()).ok()?;
        let text = |key: &str| json.get(key).and_then(Value::as_str).map(str::to_string);
        Some(Self {
            logged_in: json.get("loggedIn")?.as_bool()?,
            auth_method: text("authMethod"),
            email: text("email"),
            subscription_type: text("subscriptionType"),
        })
    }

    /// True when requests draw on a Claude subscription rather than an API
    /// key or cloud provider configured for Claude Code.
    pub fn uses_subscription(&self) -> bool {
        self.auth_method.as_deref() == Some("claude.ai")
    }

    /// "Max", "Pro".
    pub fn plan_name(&self) -> Option<String> {
        let kind = self
            .subscription_type
            .as_deref()
            .filter(|k| !k.is_empty())?;
        let mut chars = kind.chars();
        let first = chars.next()?;
        Some(first.to_uppercase().chain(chars).collect())
    }
}

fn run_short(executable: &Path, arguments: &[&str]) -> Result<crate::process::Captured> {
    let launch = Launch::for_executable(executable);
    let command = launch.command(&arguments.iter().map(|a| a.to_string()).collect::<Vec<_>>());
    crate::process::run_capture(command, STATUS_TIMEOUT)
        .map_err(|err| PlanError::ClaudeFailed(format!("Claude Code couldn't start: {err}")).into())
}

/// Whether Claude Code is signed in, from `claude auth status`.
pub fn auth_status(executable: &Path) -> Result<AuthStatus> {
    let output = run_short(executable, &["auth", "status"])?;
    AuthStatus::parse(&output.stdout).ok_or_else(|| {
        PlanError::ClaudeFailed(
            "Claude Code didn't report its sign-in status. Update Claude Code and try again."
                .into(),
        )
        .into()
    })
}

pub fn version(executable: &Path) -> Option<String> {
    let output = run_short(executable, &["--version"]).ok()?;
    let text = output.stdout.trim();
    (!text.is_empty()).then(|| text.chars().take(80).collect())
}

// ----------------------------------------------------------------- engine

/// Aliases and the default follow the newest models, which take effort low
/// through max and think by default.
pub(crate) fn traits(model: &str) -> (ReasoningSupport, bool) {
    use ReasoningLevel::*;
    let name = model.trim().to_lowercase();
    let alias = [
        "default", "opus", "sonnet", "haiku", "fable", "best", "opusplan",
    ]
    .contains(&name.as_str());
    if name.is_empty() || alias || (name.ends_with("[1m]") && !name.starts_with("claude-")) {
        return (
            ReasoningSupport::new(&[Low, Medium, High, Xhigh, Max], None),
            true,
        );
    }
    let traits = ModelTraits::new(&name.replace("[1m]", ""));
    (traits.reasoning_support(), traits.thinks_by_default)
}

/// As for Anthropic's API: a chosen level, capped by the task's budget; on
/// Automatic a model that thinks by default gets the level its task budget
/// implies, so notes and digests don't spend minutes thinking.
fn effort(model: &str, level: ReasoningLevel, task_budget: Option<u32>) -> Option<ReasoningLevel> {
    let (support, thinks_by_default) = traits(model);
    if let Some(level) = support.request_level(level, task_budget) {
        return Some(level);
    }
    let budget = task_budget.filter(|_| thinks_by_default)?;
    support.clamp(ceiling_for_budget(budget))
}

/// The isolation flags, copied from the Mac. Claude Code accepts LokalBot's
/// schemas unchanged (`maxItems`, `minimum` included).
pub fn arguments(
    model: &str,
    level: ReasoningLevel,
    request: &ChatRequest,
    streaming: bool,
) -> Vec<String> {
    let mut arguments: Vec<String> = vec![
        "-p".into(),
        "--output-format".into(),
        if streaming { "stream-json" } else { "json" }.into(),
    ];
    if streaming {
        arguments.extend(["--verbose".into(), "--include-partial-messages".into()]);
    }
    arguments.extend(
        [
            "--no-session-persistence",
            "--safe-mode",
            "--tools",
            "",
            "--strict-mcp-config",
            "--mcp-config",
            r#"{"mcpServers":{}}"#,
            "--disable-slash-commands",
            "--setting-sources",
            "",
            "--system-prompt-file",
            SYSTEM_PROMPT_FILE,
        ]
        .map(String::from),
    );
    let model = model.trim();
    if !model.is_empty() {
        arguments.extend(["--model".into(), model.to_string()]);
    }
    if let Some(effort) = effort(model, level, request.reasoning_budget) {
        arguments.extend([
            "--effort".into(),
            crate::think::effort_value(effort).to_string(),
        ]);
    }
    if let Some(schema) = &request.json_schema {
        let schema = model_json::sort_keys(schema.clone());
        arguments.extend(["--json-schema".into(), schema.to_string()]);
    }
    arguments
}

/// Context blocks, then the instruction, over stdin.
pub fn input(request: &ChatRequest) -> String {
    request
        .context
        .iter()
        .chain(std::iter::once(&request.user))
        .filter(|text| !text.trim().is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// The final `result` object of `--output-format json` or `stream-json`.
pub(crate) fn parse_result(json: &Value, wants_structured: bool) -> Result<Completion> {
    let message = json
        .get("result")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    let is_error = json.get("is_error").and_then(Value::as_bool) == Some(true)
        || json
            .get("subtype")
            .and_then(Value::as_str)
            .is_some_and(|s| s.starts_with("error"));
    if is_error {
        return Err(failure(
            &message,
            json.get("api_error_status").and_then(Value::as_u64),
        ));
    }
    let stop_reason = json.get("stop_reason").and_then(Value::as_str);
    if stop_reason == Some("refusal") {
        return Err(
            AiError::BadResponse("model refusal: Claude declined this request".into()).into(),
        );
    }
    let mut text = message;
    if wants_structured
        && let Some(structured) = json
            .get("structured_output")
            .filter(|v| v.is_object() || v.is_array())
    {
        text = model_json::sort_keys(structured.clone()).to_string();
    }
    let truncated = matches!(
        stop_reason,
        Some("max_tokens" | "model_context_window_exceeded")
    );
    if !truncated && text.is_empty() {
        return Err(AiError::BadResponse("Claude returned no text".into()).into());
    }
    let usage = json.get("usage").map(|usage| {
        let read = |key: &str| usage.get(key).and_then(Value::as_u64);
        Usage {
            prompt_tokens: read("input_tokens").map(|uncached| {
                uncached
                    + read("cache_creation_input_tokens").unwrap_or(0)
                    + read("cache_read_input_tokens").unwrap_or(0)
            }),
            completion_tokens: read("output_tokens"),
        }
    });
    Ok(Completion {
        text: if truncated {
            model_json::visible_text_of_truncated(&text)
        } else {
            model_json::strip_reasoning(&text)
        },
        truncated,
        cancelled: false,
        usage,
    })
}

/// Plan limits and a missing sign-in stop without retrying; overloads and
/// server errors keep a status the caller may retry.
pub(crate) fn failure(message: &str, api_status: Option<u64>) -> anyhow::Error {
    let lowered = message.to_lowercase();
    if lowered.contains("not logged in")
        || lowered.contains("/login")
        || lowered.contains("invalid api key")
        || lowered.contains("oauth token")
        || api_status == Some(401)
    {
        return PlanError::ClaudeSignInRequired.into();
    }
    if api_status == Some(429)
        || lowered.contains("usage limit")
        || lowered.contains("limit reached")
    {
        return PlanError::ClaudeUsageLimitReached(message.chars().take(300).collect()).into();
    }
    if let Some(status) = api_status.filter(|s| *s >= 500 || *s == 408) {
        return AiError::HttpStatus {
            code: status as u16,
            detail: message.chars().take(600).collect(),
            retry_after: None,
        }
        .into();
    }
    let detail = if message.is_empty() {
        "the request failed".to_string()
    } else {
        message.chars().take(600).collect()
    };
    AiError::BadResponse(format!("Claude Code: {detail}")).into()
}

/// One `stream-json` line: a text delta, the final result, or neither.
pub(crate) fn parse_stream_line(line: &str) -> (Option<String>, Option<Value>) {
    let Ok(json) = serde_json::from_str::<Value>(line.trim()) else {
        return (None, None);
    };
    match json.get("type").and_then(Value::as_str) {
        Some("stream_event") => {
            let delta = json
                .get("event")
                .filter(|e| e.get("type").and_then(Value::as_str) == Some("content_block_delta"))
                .and_then(|e| e.get("delta"))
                .filter(|d| d.get("type").and_then(Value::as_str) == Some("text_delta"))
                .and_then(|d| d.get("text"))
                .and_then(Value::as_str)
                .map(str::to_string);
            (delta, None)
        }
        Some("result") => (None, Some(json)),
        _ => (None, None),
    }
}

/// What a finished run left behind.
#[derive(Debug, Default)]
pub struct Output {
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr_tail: String,
    pub cancelled: bool,
}

/// Runs one `claude -p`. Tests replace the child process.
pub trait Runner: Send + Sync {
    /// `files` are written into a fresh private working directory, which
    /// `arguments` may name by relative path; it is removed afterwards.
    fn run(
        &self,
        arguments: &[String],
        input: &str,
        files: &[(&str, &str)],
        cancel: Option<&AtomicBool>,
        on_line: &mut dyn FnMut(&str),
    ) -> Result<Output>;
}

/// The installed Claude Code, or one at a fixed path (tests).
#[derive(Default)]
pub struct LiveRunner {
    pub executable: Option<PathBuf>,
}

impl Runner for LiveRunner {
    fn run(
        &self,
        arguments: &[String],
        input: &str,
        files: &[(&str, &str)],
        cancel: Option<&AtomicBool>,
        on_line: &mut dyn FnMut(&str),
    ) -> Result<Output> {
        let Some(executable) = self.executable.clone().or_else(|| locate(false)) else {
            return Err(PlanError::ClaudeNotInstalled.into());
        };
        // An empty folder of its own: no project instructions or settings to
        // pick up, and the system prompt never appears in a process list.
        let directory = tempfile::Builder::new()
            .prefix("LokalBot-claude-")
            .tempdir()
            .map_err(|_| {
                PlanError::ClaudeFailed("LokalBot couldn't prepare the Claude Code request.".into())
            })?;
        for (name, contents) in files {
            write_private(&directory.path().join(name), contents).map_err(|_| {
                PlanError::ClaudeFailed("LokalBot couldn't prepare the Claude Code request.".into())
            })?;
        }
        let mut command = Launch::for_executable(&executable).command(arguments);
        command
            .current_dir(directory.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let output = run_child(command, input, cancel, REQUEST_TIMEOUT, on_line);
        drop(directory);
        output
    }
}

fn write_private(path: &Path, contents: &str) -> std::io::Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    options.open(path)?.write_all(contents.as_bytes())
}

/// Writes stdin, hands stdout over line by line, keeps a bounded stderr
/// tail, and stops the child (with anything it started) on cancel or
/// timeout. The child dies with LokalBot.
fn run_child(
    mut command: Command,
    input: &str,
    cancel: Option<&AtomicBool>,
    timeout: Duration,
    on_line: &mut dyn FnMut(&str),
) -> Result<Output> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        // Its own process group, so stopping it also stops its helpers.
        command.process_group(0);
    }
    let mut child = crate::process::spawn_tied(command).map_err(|err| {
        if err.kind() == std::io::ErrorKind::NotFound {
            anyhow::Error::from(PlanError::ClaudeNotInstalled)
        } else {
            PlanError::ClaudeFailed(format!("Claude Code couldn't start: {err}")).into()
        }
    })?;
    let stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let input = input.to_string();
    // A child that exits early closes its end; the write then fails quietly.
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
    // Lines arrive through a channel, so a stopped run returns at once even
    // if something it started still holds the pipe open.
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
    let deadline = Instant::now() + timeout;
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
        Some("timed out") => Err(PlanError::ClaudeFailed(format!(
            "Claude Code didn't finish within {} minutes.",
            timeout.as_secs() / 60
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

/// SIGTERM to the child's process group, then SIGKILL; on Windows the child
/// is terminated.
fn stop(child: &mut std::process::Child) {
    #[cfg(unix)]
    {
        let group = child.id() as libc::pid_t;
        // SAFETY: signal delivery to the process group we created for our
        // own, not yet reaped, child.
        unsafe { libc::kill(-group, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if matches!(child.try_wait(), Ok(Some(_))) {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        // SAFETY: as above; helpers that ignored SIGTERM end here.
        unsafe { libc::kill(-group, libc::SIGKILL) };
    }
    crate::process::stop_child(child, Duration::ZERO);
}

/// Think on the Claude plan, through the user's signed-in Claude Code.
#[derive(Clone)]
pub(crate) struct Engine {
    pub model: String,
    pub level: ReasoningLevel,
    pub runner: Arc<dyn Runner>,
}

impl Engine {
    pub fn respond(
        &self,
        request: &ChatRequest,
        cancel: Option<&AtomicBool>,
        on_delta: Option<&mut dyn FnMut(&str)>,
    ) -> Result<Completion> {
        let streaming = on_delta.is_some();
        let arguments = arguments(&self.model, self.level, request, streaming);
        let system = if request.system.trim().is_empty() {
            FALLBACK_SYSTEM_PROMPT
        } else {
            request.system.as_str()
        };
        let mut on_delta = on_delta;
        let mut streamed = String::new();
        let output = self.runner.run(
            &arguments,
            &input(request),
            &[(SYSTEM_PROMPT_FILE, system)],
            cancel,
            &mut |line| {
                if let Some(on_delta) = on_delta.as_mut()
                    && let (Some(delta), _) = parse_stream_line(line)
                {
                    streamed.push_str(&delta);
                    on_delta(&delta);
                }
            },
        )?;
        if output.cancelled {
            return Ok(Completion {
                text: model_json::strip_reasoning(&streamed),
                truncated: false,
                cancelled: true,
                usage: None,
            });
        }
        reply(&output, streaming, request.json_schema.is_some())
    }
}

pub(crate) fn reply(
    output: &Output,
    streaming: bool,
    wants_structured: bool,
) -> Result<Completion> {
    let result = if streaming {
        output
            .stdout
            .lines()
            .rev()
            .find_map(|line| parse_stream_line(line).1)
    } else {
        serde_json::from_str::<Value>(output.stdout.trim()).ok()
    };
    let Some(result) = result else {
        let stderr = output.stderr_tail.trim().to_lowercase();
        log::warn!(
            "claude plan run failed status={:?} stderrBytes={}",
            output.status,
            stderr.len()
        );
        if stderr.contains("not logged in") || stderr.contains("/login") {
            return Err(PlanError::ClaudeSignInRequired.into());
        }
        return Err(PlanError::ClaudeFailed(format!(
            "Claude Code exited without a result (status {}). Update Claude Code and try again.",
            output
                .status
                .map(|s| s.to_string())
                .unwrap_or_else(|| "unknown".into())
        ))
        .into());
    };
    parse_result(&result, wants_structured)
}

#[cfg(test)]
mod tests;
