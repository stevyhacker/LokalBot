use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::Result;
use parking_lot::Mutex;
use serde_json::{Value, json};

use lokalbot_core::settings::ReasoningLevel;

use super::PlanError;
use super::cli::{self, Launch, Output};
use crate::error::AiError;
use crate::json as model_json;
use crate::think::{ChatRequest, Completion, ReasoningSupport, Usage, ceiling_for_budget};

pub const SETUP_URL: &str = "https://antigravity.google/download";
pub const AGENT_NAME: &str = "lokalbot-think";
pub const AGENT_FILE_PATH: &str = ".agents/agents/lokalbot-think.md";
pub const HOOKS_FILE_PATH: &str = ".agents/hooks.json";
pub const SETTINGS_FILE_PATH: &str = "settings.json";
pub const SCHEMA_FILE_PATH: &str = "schema.json";
pub const LOG_FILE_PATH: &str = "agy.log";
const FALLBACK_SYSTEM_PROMPT: &str = "You are a helpful assistant.";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(900);
const STATUS_TIMEOUT: Duration = Duration::from_secs(20);

pub const DENY_NON_FINISH_MATCHER: &str =
    "^([^f].*|f([^i].*|$)|fi([^n].*|$)|fin([^i].*|$)|fini([^s].*|$)|finis([^h].*|$)|finish.+)$";

pub const SESSION_SETTINGS_JSON: &str = r#"{
  "toolPermission": "strict",
  "allowNonWorkspaceAccess": false,
  "disableSlashCommands": true,
  "permissions": {
    "allow": [],
    "ask": [],
    "deny": [
      "command(*)",
      "read_file(*)",
      "write_file(*)",
      "read_url(*)",
      "execute_url(*)",
      "mcp(*)",
      "unsandboxed(*)"
    ]
  }
}"#;

pub fn hooks_json() -> String {
    let command = if cfg!(windows) {
        r#"cmd /c echo {"decision":"deny","reason":"Tools are disabled for LokalBot Think requests."}"#
    } else {
        r#"printf '{"decision":"deny","reason":"Tools are disabled for LokalBot Think requests."}\n'"#
    };
    json!({
        "lokalbot-deny-tools": {
            "PreToolUse": [
                {
                    "matcher": DENY_NON_FINISH_MATCHER,
                    "hooks": [
                        {
                            "type": "command",
                            "command": command,
                            "timeout": 5
                        }
                    ]
                }
            ]
        }
    })
    .to_string()
}

pub fn candidate_dirs(home: &Path) -> Vec<PathBuf> {
    let mut dirs = vec![
        home.join(".local/bin"),
        home.join(".antigravity/bin"),
        home.join(".npm-global/bin"),
        home.join(".bun/bin"),
        home.join(".volta/bin"),
    ];
    if cfg!(windows) {
        if let Some(app_data) = std::env::var_os("APPDATA") {
            dirs.push(PathBuf::from(app_data).join("npm"));
        }
        if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
            dirs.push(PathBuf::from(local_app_data).join("Programs/Antigravity/bin"));
        }
        dirs.push(home.join("AppData/Roaming/npm"));
    } else {
        dirs.push(PathBuf::from("/opt/homebrew/bin"));
        dirs.push(PathBuf::from("/usr/local/bin"));
    }
    dirs
}

pub fn locate_in(
    path: Option<&std::ffi::OsStr>,
    home: Option<&Path>,
    is_file: &dyn Fn(&Path) -> bool,
) -> Option<PathBuf> {
    let dirs = home.map(candidate_dirs).unwrap_or_default();
    cli::locate_in("agy", path, dirs, is_file)
}

pub fn locate(refresh: bool) -> Option<PathBuf> {
    static CACHED: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();
    let cache = CACHED.get_or_init(|| Mutex::new(None));
    if !refresh
        && let Some(found) = cache.lock().clone()
        && cli::is_executable(&found)
    {
        return Some(found);
    }
    let path = std::env::var_os("PATH");
    let found = locate_in(
        path.as_deref(),
        cli::home_dir().as_deref(),
        &cli::is_executable,
    );
    #[cfg(unix)]
    let found = found.or_else(|| cli::locate_with_login_shell("agy"));
    *cache.lock() = found.clone();
    found
}

pub(crate) fn scrubbed_command(executable: &Path, arguments: &[String]) -> Command {
    let mut command = Launch::for_executable(executable).command(arguments);
    for (key, _) in std::env::vars_os() {
        let Some(name) = key.to_str() else { continue };
        if name == "GEMINI_HOME" || name.starts_with("ANTIGRAVITY_") || name.starts_with("AGY_") {
            command.env_remove(&key);
        }
    }
    command
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelEntry {
    pub slug: String,
    pub display_name: String,
    pub effort_levels: Vec<ReasoningLevel>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AuthStatus {
    pub logged_in: bool,
    pub models: Vec<ModelEntry>,
}

const EFFORT_SUFFIXES: [(&str, ReasoningLevel, &str); 5] = [
    ("-low", ReasoningLevel::Low, "(Low)"),
    ("-medium", ReasoningLevel::Medium, "(Medium)"),
    ("-high", ReasoningLevel::High, "(High)"),
    ("-xhigh", ReasoningLevel::Xhigh, "(XHigh)"),
    ("-max", ReasoningLevel::Max, "(Max)"),
];

pub fn has_explicit_effort_suffix(model: &str) -> bool {
    let lowered = model.trim().to_ascii_lowercase();
    EFFORT_SUFFIXES
        .iter()
        .any(|(suffix, _, _)| lowered.ends_with(suffix))
}

fn level_order(level: ReasoningLevel) -> u8 {
    match level {
        ReasoningLevel::Low => 1,
        ReasoningLevel::Medium => 2,
        ReasoningLevel::High => 3,
        ReasoningLevel::Xhigh => 4,
        ReasoningLevel::Max => 5,
        _ => 0,
    }
}

pub fn parse_models_output(text: &str) -> Vec<ModelEntry> {
    let clean = cli::strip_ansi(text);
    let mut raw: Vec<(String, String)> = Vec::new();
    for raw_line in clean.lines() {
        let line = raw_line.rsplit('\r').next().unwrap_or(raw_line).trim();
        if line.is_empty()
            || line
                .to_ascii_lowercase()
                .contains("fetching available models")
        {
            continue;
        }
        let bytes = line.as_bytes();
        let mut split_at = None;
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'\t' {
                let mut end = i + 1;
                while end < bytes.len() && (bytes[end] == b'\t' || bytes[end] == b' ') {
                    end += 1;
                }
                split_at = Some((i, end));
                break;
            }
            if i + 1 < bytes.len() && bytes[i] == b' ' && bytes[i + 1] == b' ' {
                let mut end = i + 2;
                while end < bytes.len() && (bytes[end] == b' ' || bytes[end] == b'\t') {
                    end += 1;
                }
                split_at = Some((i, end));
                break;
            }
            i += 1;
        }
        let Some((left_end, right_start)) = split_at else {
            continue;
        };
        let slug = line[..left_end].trim();
        let display_name = line[right_start..].trim();
        if slug.is_empty() || display_name.is_empty() || slug.contains(' ') {
            continue;
        }
        raw.push((slug.to_string(), display_name.to_string()));
    }

    struct Bucket {
        base_slug: String,
        base_name: String,
        variants: Vec<(String, String, Option<ReasoningLevel>)>,
    }

    let mut order: Vec<String> = Vec::new();
    let mut buckets: HashMap<String, Bucket> = HashMap::new();

    for (slug, display_name) in raw {
        let lowered = slug.to_ascii_lowercase();
        if let Some((suffix, level, label)) = EFFORT_SUFFIXES
            .iter()
            .find(|(suffix, _, _)| lowered.ends_with(suffix))
        {
            let base_slug = slug[..slug.len() - suffix.len()].to_string();
            let suffix_label = format!(" {label}");
            let base_name = display_name
                .strip_suffix(&suffix_label)
                .unwrap_or(&display_name)
                .to_string();
            let bucket = buckets.entry(base_slug.clone()).or_insert_with(|| {
                order.push(base_slug.clone());
                Bucket {
                    base_slug,
                    base_name,
                    variants: Vec::new(),
                }
            });
            bucket.variants.push((slug, display_name, Some(*level)));
        } else {
            let bucket = buckets.entry(slug.clone()).or_insert_with(|| {
                order.push(slug.clone());
                Bucket {
                    base_slug: slug.clone(),
                    base_name: display_name.clone(),
                    variants: Vec::new(),
                }
            });
            bucket.variants.push((slug, display_name, None));
        }
    }

    order
        .into_iter()
        .filter_map(|key| {
            let bucket = buckets.remove(&key)?;
            let mut levels: BTreeSet<u8> = BTreeSet::new();
            let mut collected: Vec<ReasoningLevel> = Vec::new();
            for (_, _, lvl) in &bucket.variants {
                if let Some(lvl) = lvl
                    && levels.insert(level_order(*lvl))
                {
                    collected.push(*lvl);
                }
            }
            collected.sort_by_key(|l| level_order(*l));
            if collected.len() > 1 {
                Some(ModelEntry {
                    slug: bucket.base_slug,
                    display_name: bucket.base_name,
                    effort_levels: collected,
                })
            } else {
                let (slug, display_name, _) = bucket.variants.into_iter().next()?;
                Some(ModelEntry {
                    slug,
                    display_name,
                    effort_levels: Vec::new(),
                })
            }
        })
        .collect()
}

fn run_short(executable: &Path, arguments: &[&str]) -> Result<crate::process::Captured> {
    let args: Vec<String> = arguments.iter().map(|a| a.to_string()).collect();
    let command = scrubbed_command(executable, &args);
    crate::process::run_capture(command, STATUS_TIMEOUT).map_err(|err| {
        PlanError::AntigravityFailed(format!("Antigravity CLI couldn't start: {err}")).into()
    })
}

pub fn auth_status(executable: &Path) -> Result<AuthStatus> {
    let output = run_short(executable, &["models"])?;
    let combined = format!("{}\n{}", output.stdout, output.stderr).to_ascii_lowercase();
    if !output.status.is_some_and(|s| s.success()) {
        if combined.contains("please sign in")
            || combined.contains("authentication")
            || combined.contains("not signed in")
            || combined.contains("launch the cli without arguments")
        {
            return Ok(AuthStatus {
                logged_in: false,
                models: Vec::new(),
            });
        }
        let detail = cli::strip_ansi(&output.stderr).trim().to_string();
        return Err(PlanError::AntigravityFailed(if detail.is_empty() {
            "Antigravity CLI didn't report its available models. Update agy and try again.".into()
        } else {
            detail.chars().take(300).collect()
        })
        .into());
    }
    Ok(AuthStatus {
        logged_in: true,
        models: parse_models_output(&output.stdout),
    })
}

pub fn version(executable: &Path) -> Option<String> {
    let output = run_short(executable, &["--version"]).ok()?;
    let text = output.stdout.trim();
    (!text.is_empty()).then(|| text.chars().take(80).collect())
}

pub(crate) fn context_tokens(model: &str) -> u32 {
    if model.trim().to_ascii_lowercase().contains("gpt-oss") {
        128_000
    } else {
        200_000
    }
}

pub(crate) fn traits(model: &str) -> (ReasoningSupport, bool) {
    use ReasoningLevel::*;
    let name = model.trim().to_ascii_lowercase();
    if has_explicit_effort_suffix(&name) || name.contains("orchestrator") {
        return (ReasoningSupport::new(&[], None), true);
    }
    if name.is_empty() || name.contains("neon") || name.contains("hydrogen") {
        return (
            ReasoningSupport::new(&[Low, Medium, High, Xhigh], None),
            true,
        );
    }
    (ReasoningSupport::new(&[Low, Medium, High], None), true)
}

fn effort(model: &str, level: ReasoningLevel, task_budget: Option<u32>) -> Option<ReasoningLevel> {
    let (support, thinks_by_default) = traits(model);
    if support.levels.is_empty() {
        return None;
    }
    if let Some(level) = support.request_level(level, task_budget) {
        return Some(level);
    }
    let budget = task_budget.filter(|_| thinks_by_default)?;
    support.clamp(ceiling_for_budget(budget))
}

pub fn arguments(model: &str, level: ReasoningLevel, request: &ChatRequest) -> Vec<String> {
    let mut arguments: Vec<String> = [
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--disable-slash-commands",
        "--agent",
        AGENT_NAME,
        "--settings",
        SETTINGS_FILE_PATH,
        "--log-file",
        LOG_FILE_PATH,
    ]
    .into_iter()
    .map(String::from)
    .collect();
    if request.json_schema.is_some() {
        arguments.extend(["--json-schema".into(), SCHEMA_FILE_PATH.into()]);
    }
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
    arguments
}

pub fn agent_markdown(system_prompt: &str) -> String {
    let body = if system_prompt.trim().is_empty() {
        FALLBACK_SYSTEM_PROMPT
    } else {
        system_prompt
    };
    format!(
        "---\nname: {AGENT_NAME}\ndescription: Text-only response assistant for LokalBot Think\ntools:\n  - finish\nmcpServers: []\nskills: []\nplugins: []\ncommandExecutionPolicy: \"off\"\n---\n{body}"
    )
}

pub fn stream_input(request: &ChatRequest) -> String {
    let content = request
        .context
        .iter()
        .chain(std::iter::once(&request.user))
        .filter(|text| !text.trim().is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join("\n\n");
    let message = model_json::sort_keys(json!({
        "event": "user",
        "message": { "content": content },
    }));
    format!("{message}\n")
}

pub(crate) fn parse_stream_line(line: &str) -> (Option<String>, Option<Value>) {
    let Ok(json) = serde_json::from_str::<Value>(line.trim()) else {
        return (None, None);
    };
    match json.get("event").and_then(Value::as_str) {
        Some("step_update") => {
            let delta = json
                .get("step_update")
                .filter(|s| s.get("step_type").and_then(Value::as_str) == Some("agent_response"))
                .and_then(|s| s.get("text_delta"))
                .and_then(Value::as_str)
                .filter(|d| !d.is_empty())
                .map(str::to_string);
            (delta, None)
        }
        Some("result") => (None, json.get("result").cloned()),
        _ => (None, None),
    }
}

pub(crate) fn parse_result(json: &Value, wants_structured: bool) -> Result<Completion> {
    let status = json
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_uppercase();
    let error_message = json
        .get("error")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if status != "SUCCESS" {
        let fallback = format!("status {status}");
        return Err(failure(if error_message.is_empty() {
            &fallback
        } else {
            &error_message
        }));
    }
    let finished_reason = json
        .get("finished_reason")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let mut text = json
        .get("response")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    let mut is_structured = false;
    if wants_structured
        && let Some(structured) = json
            .get("structured_output")
            .filter(|v| v.is_object() || v.is_array())
    {
        text = model_json::sort_keys(structured.clone()).to_string();
        is_structured = true;
    }
    let truncated = matches!(finished_reason.as_str(), "max_tokens" | "length");
    if !truncated && text.is_empty() {
        return Err(AiError::BadResponse("Antigravity returned no text".into()).into());
    }
    if wants_structured && !is_structured && !truncated {
        let Some(object) = cli::extract_json_text(&text) else {
            return Err(
                AiError::BadResponse("Antigravity returned no structured output".into()).into(),
            );
        };
        text = object;
    }
    let usage = json.get("usage").map(|u| Usage {
        prompt_tokens: u.get("input_tokens").and_then(Value::as_u64),
        completion_tokens: u.get("output_tokens").and_then(Value::as_u64),
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

pub(crate) fn failure(message: &str) -> anyhow::Error {
    let lowered = message.to_ascii_lowercase();
    if lowered.contains("authentication")
        || lowered.contains("please sign in")
        || lowered.contains("not signed in")
        || lowered.contains("unauthenticated")
        || lowered.contains("login")
        || lowered.contains("401")
    {
        return PlanError::AntigravitySignInRequired.into();
    }
    if lowered.contains("quota")
        || lowered.contains("usage limit")
        || lowered.contains("rate limit")
        || lowered.contains("limit reached")
        || lowered.contains("resource_exhausted")
        || lowered.contains("exhausted")
        || lowered.contains("429")
    {
        return PlanError::AntigravityUsageLimitReached(message.chars().take(300).collect()).into();
    }
    if lowered.contains("503")
        || lowered.contains("502")
        || lowered.contains("504")
        || lowered.contains("500")
        || lowered.contains("529")
        || lowered.contains("overloaded")
        || lowered.contains("temporarily unavailable")
    {
        let code = if lowered.contains("503") {
            503
        } else if lowered.contains("529") {
            529
        } else {
            500
        };
        return AiError::HttpStatus {
            code,
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
    AiError::BadResponse(format!("Antigravity CLI: {detail}")).into()
}

pub(crate) fn reply(output: &Output, wants_structured: bool) -> Result<Completion> {
    let result = output
        .stdout
        .lines()
        .rev()
        .find_map(|line| parse_stream_line(line).1);
    let Some(result) = result else {
        let stderr = cli::strip_ansi(&output.stderr_tail).trim().to_string();
        log::warn!(
            "antigravity plan run failed status={:?} stderrBytes={}",
            output.status,
            stderr.len()
        );
        let lowered = stderr.to_ascii_lowercase();
        if lowered.contains("authentication")
            || lowered.contains("please sign in")
            || lowered.contains("not signed in")
            || lowered.contains("log in")
        {
            return Err(PlanError::AntigravitySignInRequired.into());
        }
        if lowered.contains("quota")
            || lowered.contains("rate limit")
            || lowered.contains("usage limit")
        {
            return Err(PlanError::AntigravityUsageLimitReached(
                stderr.chars().take(300).collect(),
            )
            .into());
        }
        return Err(PlanError::AntigravityFailed(format!(
            "Antigravity CLI exited without a result (status {}). Update agy and try again.",
            output
                .status
                .map(|s| s.to_string())
                .unwrap_or_else(|| "unknown".into())
        ))
        .into());
    };
    parse_result(&result, wants_structured)
}

pub trait Runner: Send + Sync {
    fn run(
        &self,
        arguments: &[String],
        input: &str,
        files: &[(&str, String)],
        cancel: Option<&AtomicBool>,
        on_line: &mut dyn FnMut(&str),
    ) -> Result<Output>;
}

#[derive(Default)]
pub struct LiveRunner {
    pub executable: Option<PathBuf>,
}

impl Runner for LiveRunner {
    fn run(
        &self,
        arguments: &[String],
        input: &str,
        files: &[(&str, String)],
        cancel: Option<&AtomicBool>,
        on_line: &mut dyn FnMut(&str),
    ) -> Result<Output> {
        let Some(executable) = self.executable.clone().or_else(|| locate(false)) else {
            return Err(PlanError::AntigravityNotInstalled.into());
        };
        let directory = tempfile::Builder::new()
            .prefix("LokalBot-agy-")
            .tempdir()
            .map_err(|_| {
                PlanError::AntigravityFailed(
                    "LokalBot couldn't prepare the Antigravity CLI request.".into(),
                )
            })?;
        for (relative, contents) in files {
            cli::write_private(directory.path(), relative, contents).map_err(|_| {
                PlanError::AntigravityFailed(
                    "LokalBot couldn't prepare the Antigravity CLI request.".into(),
                )
            })?;
        }
        let mut command = scrubbed_command(&executable, arguments);
        command.current_dir(directory.path());
        let output = cli::run_child(
            command,
            input,
            cancel,
            cli::ChildSpec {
                program_name: "Antigravity CLI",
                timeout: REQUEST_TIMEOUT,
                not_installed: || PlanError::AntigravityNotInstalled,
                failed: PlanError::AntigravityFailed,
            },
            on_line,
        );
        drop(directory);
        output
    }
}

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
        let arguments = arguments(&self.model, self.level, request);
        let mut files = vec![
            (AGENT_FILE_PATH, agent_markdown(&request.system)),
            (HOOKS_FILE_PATH, hooks_json()),
            (SETTINGS_FILE_PATH, SESSION_SETTINGS_JSON.to_string()),
        ];
        if let Some(schema) = &request.json_schema {
            files.push((
                SCHEMA_FILE_PATH,
                model_json::sort_keys(schema.clone()).to_string(),
            ));
        }
        let mut on_delta = on_delta;
        let mut streamed = String::new();
        let output = self.runner.run(
            &arguments,
            &stream_input(request),
            &files,
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
        reply(&output, request.json_schema.is_some())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plans::plan_error;
    use parking_lot::Mutex;

    #[allow(dead_code)]
    struct CapturedCall {
        arguments: Vec<String>,
        input: String,
        files: Vec<(String, String)>,
    }

    struct FakeRunner {
        stdout: String,
        stderr: String,
        status: Option<i32>,
        captured: Mutex<Option<CapturedCall>>,
    }

    impl FakeRunner {
        fn ok(stdout: impl Into<String>) -> Arc<Self> {
            Arc::new(Self {
                stdout: stdout.into(),
                stderr: String::new(),
                status: Some(0),
                captured: Mutex::new(None),
            })
        }
    }

    impl Runner for FakeRunner {
        fn run(
            &self,
            arguments: &[String],
            input: &str,
            files: &[(&str, String)],
            _cancel: Option<&AtomicBool>,
            on_line: &mut dyn FnMut(&str),
        ) -> Result<Output> {
            *self.captured.lock() = Some(CapturedCall {
                arguments: arguments.to_vec(),
                input: input.to_string(),
                files: files
                    .iter()
                    .map(|(k, v)| ((*k).to_string(), v.clone()))
                    .collect(),
            });
            for line in self.stdout.lines() {
                on_line(line);
            }
            Ok(Output {
                status: self.status,
                stdout: self.stdout.clone(),
                stderr_tail: self.stderr.clone(),
                cancelled: false,
            })
        }
    }

    #[test]
    fn parse_models_groups_effort_variants_and_strips_spinner() {
        let raw = "\r\x1b[2K⠋ Fetching available models...\r\x1b[2K\n\
gemini-4-neon-low\tGemini 4 Neon (Low)\n\
gemini-4-neon-medium\tGemini 4 Neon (Medium)\n\
gemini-4-neon-high    Gemini 4 Neon (High)\n\
gemini-4-neon-xhigh   Gemini 4 Neon (XHigh)\n\
gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n\
gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n\
gpt-oss-120b-medium   GPT-OSS 120B (Medium)\n";
        let models = parse_models_output(raw);
        assert_eq!(
            models,
            vec![
                ModelEntry {
                    slug: "gemini-4-neon".into(),
                    display_name: "Gemini 4 Neon".into(),
                    effort_levels: vec![
                        ReasoningLevel::Low,
                        ReasoningLevel::Medium,
                        ReasoningLevel::High,
                        ReasoningLevel::Xhigh,
                    ],
                },
                ModelEntry {
                    slug: "gemini-3.8-flash".into(),
                    display_name: "Gemini 3.8 Flash".into(),
                    effort_levels: vec![ReasoningLevel::Low, ReasoningLevel::High],
                },
                ModelEntry {
                    slug: "gpt-oss-120b-medium".into(),
                    display_name: "GPT-OSS 120B (Medium)".into(),
                    effort_levels: vec![],
                },
            ]
        );
    }

    #[test]
    fn hook_matcher_denies_every_tool_except_finish() {
        let re = regex::Regex::new(DENY_NON_FINISH_MATCHER).unwrap();
        assert!(!re.is_match("finish"));
        for tool in [
            "run_command",
            "search_web",
            "view_file",
            "list_resources",
            "fin",
            "finishing",
            "f",
            "Finish",
        ] {
            assert!(re.is_match(tool), "matcher should deny {tool}");
        }
    }

    #[test]
    fn settings_and_hooks_are_valid_json() {
        let settings: Value = serde_json::from_str(SESSION_SETTINGS_JSON).unwrap();
        assert_eq!(settings["toolPermission"], "strict");
        assert_eq!(settings["allowNonWorkspaceAccess"], false);
        assert_eq!(settings["disableSlashCommands"], true);
        let hooks: Value = serde_json::from_str(&hooks_json()).unwrap();
        assert!(hooks["lokalbot-deny-tools"]["PreToolUse"].is_array());
    }

    #[test]
    fn arguments_keep_content_and_schema_off_argv_and_avoid_effort_conflict() {
        let req = ChatRequest::new("Secret system", "Secret prompt")
            .json_schema(json!({"type": "object", "properties": {"a": {"type": "string"}}}))
            .reasoning_budget(512);
        let args = arguments("gemini-4-neon", ReasoningLevel::High, &req);
        assert!(
            args.windows(2)
                .any(|w| w == ["--input-format", "stream-json"])
        );
        assert!(
            args.windows(2)
                .any(|w| w == ["--output-format", "stream-json"])
        );
        assert!(args.windows(2).any(|w| w == ["--agent", AGENT_NAME]));
        assert!(
            args.windows(2)
                .any(|w| w == ["--settings", SETTINGS_FILE_PATH])
        );
        assert!(
            args.windows(2)
                .any(|w| w == ["--json-schema", SCHEMA_FILE_PATH])
        );
        assert!(args.windows(2).any(|w| w == ["--model", "gemini-4-neon"]));
        assert!(args.windows(2).any(|w| w == ["--effort", "low"]));
        assert!(!args.iter().any(|a| a.contains("Secret")));

        let fixed = arguments("gemini-4-neon-high", ReasoningLevel::Low, &req);
        assert!(!fixed.iter().any(|a| a == "--effort"));
    }

    #[test]
    fn respond_streams_deltas_and_returns_structured_output() {
        let stdout = concat!(
            r#"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"Hel"}}"#,
            "\n",
            r#"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"lo"}}"#,
            "\n",
            r#"{"event":"result","result":{"status":"SUCCESS","response":"Hello","usage":{"input_tokens":10,"output_tokens":2}}}"#,
            "\n"
        );
        let runner = FakeRunner::ok(stdout);
        let engine = Engine {
            model: "gemini-4-neon".into(),
            level: ReasoningLevel::Automatic,
            runner: runner.clone(),
        };
        let mut deltas = String::new();
        let completion = engine
            .respond(
                &ChatRequest::new("Sys", "Hi"),
                None,
                Some(&mut |d| deltas.push_str(d)),
            )
            .unwrap();
        assert_eq!(deltas, "Hello");
        assert_eq!(completion.text, "Hello");
        assert_eq!(completion.usage.unwrap().prompt_tokens, Some(10));

        let structured_stdout = r#"{"event":"result","result":{"status":"SUCCESS","response":"","structured_output":{"b":2,"a":1}}}"#;
        let engine = Engine {
            model: "gemini-4-neon".into(),
            level: ReasoningLevel::Automatic,
            runner: FakeRunner::ok(structured_stdout),
        };
        let completion = engine
            .respond(
                &ChatRequest::new("Sys", "Hi").json_schema(json!({"type": "object"})),
                None,
                None,
            )
            .unwrap();
        assert_eq!(completion.text, r#"{"a":1,"b":2}"#);
    }

    #[test]
    fn errors_classify_without_retrying_plan_limits() {
        assert_eq!(
            plan_error(&failure("Authentication failed. Please sign in.")),
            Some(&PlanError::AntigravitySignInRequired)
        );
        assert!(matches!(
            plan_error(&failure("RESOURCE_EXHAUSTED: quota exceeded")),
            Some(PlanError::AntigravityUsageLimitReached(_))
        ));
        let transient = failure("503 service temporarily unavailable");
        assert!(
            transient
                .downcast_ref::<AiError>()
                .is_some_and(AiError::is_retryable)
        );
    }
}
