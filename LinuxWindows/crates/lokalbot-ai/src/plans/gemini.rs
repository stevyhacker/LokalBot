use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::Result;
use parking_lot::Mutex;
use serde_json::Value;

use super::PlanError;
use super::cli::{self, Launch, Output};
use crate::error::AiError;
use crate::json as model_json;
use crate::think::{ChatRequest, Completion, Usage};

pub const SETUP_URL: &str = "https://geminicli.com/docs/get-started/installation/";
pub const SYSTEM_PROMPT_FILE: &str = "system-prompt.md";
pub const SYSTEM_SETTINGS_FILE: &str = "system-settings.json";
pub const ADMIN_POLICY_FILE: &str = "deny-all.toml";
const FALLBACK_SYSTEM_PROMPT: &str = "You are a helpful assistant.";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(900);
const STATUS_TIMEOUT: Duration = Duration::from_secs(20);

pub const ADMIN_POLICY_TOML: &str = r#"[[rule]]
toolName = "*"
decision = "deny"
priority = 999
"#;

pub const SYSTEM_SETTINGS_JSON: &str = r#"{
  "tools": {
    "core": [],
    "exclude": ["*"]
  },
  "mcp": {
    "allowed": [],
    "excluded": ["*"]
  },
  "hooksConfig": {
    "enabled": false
  },
  "skills": {
    "enabled": false
  },
  "general": {
    "defaultApprovalMode": "plan"
  },
  "privacy": {
    "usageStatisticsEnabled": false
  }
}"#;

pub fn candidate_dirs(home: &Path) -> Vec<PathBuf> {
    let mut dirs = vec![
        home.join(".local/bin"),
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
    cli::locate_in("gemini", path, dirs, is_file)
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
    let found = found.or_else(|| cli::locate_with_login_shell("gemini"));
    *cache.lock() = found.clone();
    found
}

fn gemini_command(
    executable: &Path,
    arguments: &[String],
    system_prompt_path: Option<&Path>,
    system_settings_path: Option<&Path>,
) -> Command {
    let mut command = Launch::for_executable(executable).command(arguments);
    command.env_remove("GEMINI_HOME");
    command.env("NO_COLOR", "1");
    if let Some(path) = system_prompt_path {
        command.env("GEMINI_SYSTEM_MD", path);
    }
    if let Some(path) = system_settings_path {
        command.env("GEMINI_CLI_SYSTEM_SETTINGS_PATH", path);
        command.env("GEMINI_CLI_TRUST_WORKSPACE", "true");
    }
    command
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelEntry {
    pub slug: String,
    pub display_name: String,
    pub input_tokens: Option<u32>,
}

pub fn fallback_models() -> Vec<ModelEntry> {
    vec![
        ModelEntry {
            slug: String::new(),
            display_name: "Gemini CLI default".into(),
            input_tokens: Some(1_048_576),
        },
        ModelEntry {
            slug: "gemini-2.5-pro".into(),
            display_name: "gemini-2.5-pro".into(),
            input_tokens: Some(1_048_576),
        },
        ModelEntry {
            slug: "gemini-3.5-flash".into(),
            display_name: "gemini-3.5-flash".into(),
            input_tokens: Some(1_048_576),
        },
        ModelEntry {
            slug: "gemini-3.1-flash-lite".into(),
            display_name: "gemini-3.1-flash-lite".into(),
            input_tokens: Some(1_048_576),
        },
    ]
}

pub fn parse_models_json(text: &str) -> Vec<ModelEntry> {
    let Ok(Value::Array(list)) = serde_json::from_str::<Value>(text.trim()) else {
        return Vec::new();
    };
    let mut seen = HashSet::new();
    let mut entries = Vec::new();
    for item in list {
        let raw_slug = item
            .get("modelId")
            .or_else(|| item.get("id"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        if raw_slug.is_empty() {
            continue;
        }
        let slug = if raw_slug == "auto" {
            String::new()
        } else {
            raw_slug.to_string()
        };
        if !seen.insert(slug.clone()) {
            continue;
        }
        let raw_name = item
            .get("displayName")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
            .unwrap_or(raw_slug)
            .trim();
        let display_name = if raw_slug == "auto" {
            "Gemini CLI default (Auto)".to_string()
        } else if raw_name.is_empty() {
            raw_slug.to_string()
        } else {
            raw_name.to_string()
        };
        let input_tokens = item
            .get("contextLimits")
            .and_then(|c| c.get("inputTokens"))
            .and_then(Value::as_u64)
            .and_then(|n| u32::try_from(n).ok());
        entries.push(ModelEntry {
            slug,
            display_name,
            input_tokens,
        });
    }
    entries
}

fn run_short(executable: &Path, arguments: &[&str]) -> Result<crate::process::Captured> {
    let args: Vec<String> = arguments.iter().map(|a| a.to_string()).collect();
    let command = gemini_command(executable, &args, None, None);
    crate::process::run_capture(command, STATUS_TIMEOUT)
        .map_err(|err| PlanError::GeminiFailed(format!("Gemini CLI couldn't start: {err}")).into())
}

pub fn models(executable: &Path) -> Vec<ModelEntry> {
    let Ok(output) = run_short(executable, &["models", "-o", "json"]) else {
        return fallback_models();
    };
    if !output.status.is_some_and(|s| s.success()) {
        return fallback_models();
    }
    let parsed = parse_models_json(&output.stdout);
    if parsed.is_empty() {
        fallback_models()
    } else {
        parsed
    }
}

pub fn version(executable: &Path) -> Option<String> {
    let output = run_short(executable, &["--version"]).ok()?;
    let text = output.stdout.trim();
    (!text.is_empty()).then(|| text.chars().take(80).collect())
}

pub fn arguments(model: &str, streaming: bool) -> Vec<String> {
    let mut arguments: Vec<String> = vec![
        "-p".into(),
        String::new(),
        "--output-format".into(),
        if streaming { "stream-json" } else { "json" }.into(),
        "--skip-trust".into(),
        "--admin-policy".into(),
        ADMIN_POLICY_FILE.into(),
        "--extensions".into(),
        "none".into(),
    ];
    let trimmed = model.trim();
    if !trimmed.is_empty() && !trimmed.eq_ignore_ascii_case("auto") {
        arguments.extend(["--model".into(), trimmed.to_string()]);
    }
    arguments
}

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

pub fn system_prompt_content(system: &str, schema: Option<&Value>) -> String {
    let base = if system.trim().is_empty() {
        FALLBACK_SYSTEM_PROMPT
    } else {
        system
    };
    let Some(schema) = schema else {
        return base.to_string();
    };
    let schema_text = model_json::sort_keys(schema.clone()).to_string();
    format!(
        "{base}\n\nRespond with exactly one valid JSON object matching this JSON Schema and nothing else (no markdown fences, no commentary):\n{schema_text}"
    )
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum StreamEvent {
    Delta(String),
    Error(String),
    Result {
        status: String,
        error_message: Option<String>,
        input_tokens: Option<u64>,
        output_tokens: Option<u64>,
    },
    Ignored,
}

pub(crate) fn parse_stream_line(line: &str) -> StreamEvent {
    let Ok(json) = serde_json::from_str::<Value>(line.trim()) else {
        return StreamEvent::Ignored;
    };
    match json.get("type").and_then(Value::as_str) {
        Some("message") => {
            if json.get("role").and_then(Value::as_str) == Some("assistant")
                && let Some(content) = json.get("content").and_then(Value::as_str)
                && !content.is_empty()
            {
                StreamEvent::Delta(content.to_string())
            } else {
                StreamEvent::Ignored
            }
        }
        Some("error") => {
            if json.get("severity").and_then(Value::as_str) == Some("error")
                && let Some(message) = json.get("message").and_then(Value::as_str)
                && !message.is_empty()
            {
                StreamEvent::Error(message.to_string())
            } else {
                StreamEvent::Ignored
            }
        }
        Some("result") => {
            let status = json
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_ascii_lowercase();
            let error_message = json
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(Value::as_str)
                .map(str::to_string);
            let stats = json.get("stats");
            StreamEvent::Result {
                status,
                error_message,
                input_tokens: stats
                    .and_then(|s| s.get("input_tokens"))
                    .and_then(Value::as_u64),
                output_tokens: stats
                    .and_then(|s| s.get("output_tokens"))
                    .and_then(Value::as_u64),
            }
        }
        _ => StreamEvent::Ignored,
    }
}

pub(crate) fn parse_json_object(json: &Value, wants_structured: bool) -> Result<Completion> {
    if let Some(error_obj) = json.get("error").filter(|v| v.is_object()) {
        let message = error_obj
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let code = error_obj.get("code").and_then(Value::as_u64);
        return Err(failure(message, code));
    }
    let mut text = json
        .get("response")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if text.is_empty() {
        return Err(AiError::BadResponse("Gemini returned no text".into()).into());
    }
    if wants_structured {
        let Some(object) = cli::extract_json_text(&text) else {
            return Err(AiError::BadResponse("Gemini returned no structured output".into()).into());
        };
        text = object;
    }
    let usage = extract_json_usage(json.get("stats"));
    Ok(Completion {
        text: model_json::strip_reasoning(&text),
        truncated: false,
        cancelled: false,
        usage,
        attempts: 1,
    })
}

fn extract_json_usage(stats: Option<&Value>) -> Option<Usage> {
    let models = stats?.get("models")?.as_object()?;
    if models.is_empty() {
        return None;
    }
    let mut input = 0u64;
    let mut output = 0u64;
    let mut found = false;
    for value in models.values() {
        let Some(tokens) = value.get("tokens") else {
            continue;
        };
        found = true;
        input += tokens
            .get("prompt")
            .or_else(|| tokens.get("input"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        output += tokens
            .get("candidates")
            .and_then(Value::as_u64)
            .unwrap_or(0);
    }
    found.then_some(Usage {
        prompt_tokens: Some(input),
        completion_tokens: Some(output),
    })
}

pub(crate) fn failure(message: &str, status_code: Option<u64>) -> anyhow::Error {
    let lowered = message.to_ascii_lowercase();
    if lowered.contains("cloudaicompanion.licenses.selfassign")
        || (lowered.contains("permission_denied") && lowered.contains("cloudcode-pa"))
    {
        return PlanError::GeminiFailed(
            "Gemini CLI couldn't onboard this Google Cloud project (permission denied). Run gemini in a terminal to choose a Google account or project with Gemini CLI access."
                .into(),
        )
        .into();
    }
    if status_code == Some(401)
        || lowered.contains("api_key_invalid")
        || lowered.contains("api key not valid")
        || lowered.contains("not authenticated")
        || lowered.contains("unauthenticated")
        || lowered.contains("please login")
        || lowered.contains("please sign in")
        || lowered.contains("invalid_grant")
        || lowered.contains("error authenticating")
    {
        return PlanError::GeminiSignInRequired.into();
    }
    if status_code == Some(429)
        || lowered.contains("resource_exhausted")
        || lowered.contains("quota")
        || lowered.contains("rate limit")
        || lowered.contains("usage limit")
        || lowered.contains("limit reached")
    {
        return PlanError::GeminiUsageLimitReached(message.chars().take(300).collect()).into();
    }
    if let Some(code) = status_code.filter(|c| *c >= 500 || *c == 408) {
        return AiError::HttpStatus {
            code: code as u16,
            detail: message.chars().take(600).collect(),
            retry_after: None,
        }
        .into();
    }
    if lowered.contains("503")
        || lowered.contains("502")
        || lowered.contains("504")
        || lowered.contains("500")
        || lowered.contains("overloaded")
        || lowered.contains("unavailable")
    {
        let code = if lowered.contains("503") { 503 } else { 500 };
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
    AiError::BadResponse(format!("Gemini CLI: {detail}")).into()
}

pub(crate) fn reply(
    output: &Output,
    streaming: bool,
    wants_structured: bool,
) -> Result<Completion> {
    if streaming {
        let mut accumulated = String::new();
        let mut fatal_error: Option<String> = None;
        let mut result_seen = false;
        let mut result_status = String::new();
        let mut result_error: Option<String> = None;
        let mut input_tokens = None;
        let mut output_tokens = None;

        for line in output.stdout.lines() {
            match parse_stream_line(line) {
                StreamEvent::Delta(chunk) => accumulated.push_str(&chunk),
                StreamEvent::Error(msg) => fatal_error = Some(msg),
                StreamEvent::Result {
                    status,
                    error_message,
                    input_tokens: input,
                    output_tokens: out,
                } => {
                    result_seen = true;
                    result_status = status;
                    result_error = error_message;
                    input_tokens = input;
                    output_tokens = out;
                }
                StreamEvent::Ignored => {}
            }
        }
        if result_seen {
            if result_status != "success" {
                let message = result_error
                    .or(fatal_error)
                    .unwrap_or_else(|| output.stderr_tail.clone());
                return Err(failure(&message, None));
            }
            let mut text = accumulated.trim().to_string();
            if text.is_empty() {
                return Err(AiError::BadResponse("Gemini returned no text".into()).into());
            }
            if wants_structured {
                let Some(object) = cli::extract_json_text(&text) else {
                    return Err(AiError::BadResponse(
                        "Gemini returned no structured output".into(),
                    )
                    .into());
                };
                text = object;
            }
            let usage = (input_tokens.is_some() || output_tokens.is_some()).then_some(Usage {
                prompt_tokens: input_tokens,
                completion_tokens: output_tokens,
            });
            return Ok(Completion {
                text: model_json::strip_reasoning(&text),
                truncated: false,
                cancelled: false,
                usage,
                attempts: 1,
            });
        }
        if let Some(err) = fatal_error {
            return Err(failure(&err, None));
        }
        return Err(missing_result(output));
    }

    if let Ok(json) = serde_json::from_str::<Value>(output.stdout.trim())
        && json.is_object()
    {
        return parse_json_object(&json, wants_structured);
    }
    if let Some(extracted) = model_json::extract_json_object(&output.stdout)
        && let Ok(json) = serde_json::from_str::<Value>(extracted)
        && json.is_object()
    {
        return parse_json_object(&json, wants_structured);
    }
    Err(missing_result(output))
}

fn missing_result(output: &Output) -> anyhow::Error {
    let stderr = cli::strip_ansi(&output.stderr_tail).trim().to_string();
    log::warn!(
        "gemini plan run failed status={:?} stderrBytes={}",
        output.status,
        stderr.len()
    );
    if !stderr.is_empty() {
        let classified = failure(&stderr, None);
        if classified.downcast_ref::<PlanError>().is_some() {
            return classified;
        }
        if classified
            .downcast_ref::<AiError>()
            .is_some_and(AiError::is_retryable)
        {
            return classified;
        }
    }
    PlanError::GeminiFailed(format!(
        "Gemini CLI exited without a result (status {}). Sign in with gemini in a terminal or update Gemini CLI and try again.",
        output
            .status
            .map(|s| s.to_string())
            .unwrap_or_else(|| "unknown".into())
    ))
    .into()
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
            return Err(PlanError::GeminiNotInstalled.into());
        };
        let directory = tempfile::Builder::new()
            .prefix("LokalBot-gemini-")
            .tempdir()
            .map_err(|_| {
                PlanError::GeminiFailed("LokalBot couldn't prepare the Gemini CLI request.".into())
            })?;
        for (relative, contents) in files {
            cli::write_private(directory.path(), relative, contents).map_err(|_| {
                PlanError::GeminiFailed("LokalBot couldn't prepare the Gemini CLI request.".into())
            })?;
        }
        let system_prompt_path = directory.path().join(SYSTEM_PROMPT_FILE);
        let system_settings_path = directory.path().join(SYSTEM_SETTINGS_FILE);
        let mut command = gemini_command(
            &executable,
            arguments,
            Some(&system_prompt_path),
            Some(&system_settings_path),
        );
        command.current_dir(directory.path());
        let output = cli::run_child(
            command,
            input,
            cancel,
            cli::ChildSpec {
                program_name: "Gemini CLI",
                timeout: REQUEST_TIMEOUT,
                not_installed: || PlanError::GeminiNotInstalled,
                failed: PlanError::GeminiFailed,
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
        let arguments = arguments(&self.model, streaming);
        let files = vec![
            (
                SYSTEM_PROMPT_FILE,
                system_prompt_content(&request.system, request.json_schema.as_ref()),
            ),
            (SYSTEM_SETTINGS_FILE, SYSTEM_SETTINGS_JSON.to_string()),
            (ADMIN_POLICY_FILE, ADMIN_POLICY_TOML.to_string()),
        ];
        let mut on_delta = on_delta;
        let mut streamed = String::new();
        let output = self
            .runner
            .run(&arguments, &input(request), &files, cancel, &mut |line| {
                if let Some(on_delta) = on_delta.as_mut()
                    && let StreamEvent::Delta(delta) = parse_stream_line(line)
                {
                    streamed.push_str(&delta);
                    on_delta(&delta);
                }
            })?;
        if output.cancelled {
            return Ok(Completion {
                text: model_json::strip_reasoning(&streamed),
                truncated: false,
                cancelled: true,
                usage: None,
                attempts: 1,
            });
        }
        reply(&output, streaming, request.json_schema.is_some())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plans::plan_error;
    use serde_json::json;

    struct FakeRunner {
        stdout: String,
        stderr: String,
        status: Option<i32>,
    }

    impl FakeRunner {
        fn ok(stdout: impl Into<String>) -> Arc<Self> {
            Arc::new(Self {
                stdout: stdout.into(),
                stderr: String::new(),
                status: Some(0),
            })
        }
    }

    impl Runner for FakeRunner {
        fn run(
            &self,
            _arguments: &[String],
            _input: &str,
            _files: &[(&str, String)],
            _cancel: Option<&AtomicBool>,
            on_line: &mut dyn FnMut(&str),
        ) -> Result<Output> {
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
    fn parse_models_json_maps_auto_to_default() {
        let raw = r#"[
            {"modelId": "auto", "displayName": "Auto", "contextLimits": {"inputTokens": 1048576}},
            {"modelId": "gemini-2.5-pro", "displayName": "Gemini 2.5 Pro", "contextLimits": {"inputTokens": 1048576}}
        ]"#;
        let entries = parse_models_json(raw);
        assert_eq!(
            entries,
            vec![
                ModelEntry {
                    slug: String::new(),
                    display_name: "Gemini CLI default (Auto)".into(),
                    input_tokens: Some(1_048_576),
                },
                ModelEntry {
                    slug: "gemini-2.5-pro".into(),
                    display_name: "Gemini 2.5 Pro".into(),
                    input_tokens: Some(1_048_576),
                },
            ]
        );
    }

    #[test]
    fn arguments_enforce_isolation_and_extensions_none() {
        let args = arguments("gemini-2.5-pro", false);
        assert!(args.windows(2).any(|w| w == ["-p", ""]));
        assert!(args.windows(2).any(|w| w == ["--output-format", "json"]));
        assert!(args.iter().any(|a| a == "--skip-trust"));
        assert!(
            args.windows(2)
                .any(|w| w == ["--admin-policy", ADMIN_POLICY_FILE])
        );
        assert!(args.windows(2).any(|w| w == ["--extensions", "none"]));
        assert!(args.windows(2).any(|w| w == ["--model", "gemini-2.5-pro"]));

        let auto_args = arguments("auto", true);
        assert!(
            auto_args
                .windows(2)
                .any(|w| w == ["--output-format", "stream-json"])
        );
        assert!(!auto_args.iter().any(|a| a == "--model"));
    }

    #[test]
    fn system_settings_is_valid_json() {
        let settings: Value = serde_json::from_str(SYSTEM_SETTINGS_JSON).unwrap();
        assert_eq!(settings["tools"]["exclude"], json!(["*"]));
        assert_eq!(settings["mcp"]["excluded"], json!(["*"]));
        assert_eq!(settings["hooksConfig"]["enabled"], false);
        assert_eq!(settings["skills"]["enabled"], false);
        assert_eq!(settings["privacy"]["usageStatisticsEnabled"], false);
    }

    #[test]
    fn respond_parses_json_structured_and_streaming() {
        let json_out = r#"{"session_id":"s1","response":"```json\n{\"b\":2,\"a\":1}\n```","stats":{"models":{"gemini-2.5-pro":{"tokens":{"prompt":12,"candidates":5}}}}}"#;
        let engine = Engine {
            model: "gemini-2.5-pro".into(),
            runner: FakeRunner::ok(json_out),
        };
        let completion = engine
            .respond(
                &ChatRequest::new("Sys", "Hi").json_schema(json!({"type": "object"})),
                None,
                None,
            )
            .unwrap();
        assert_eq!(completion.text, r#"{"a":1,"b":2}"#);
        assert_eq!(completion.usage.unwrap().prompt_tokens, Some(12));

        let stream_out = concat!(
            r#"{"type":"init","model":"gemini-2.5-pro"}"#,
            "\n",
            r#"{"type":"message","role":"assistant","content":"Hel","delta":true}"#,
            "\n",
            r#"{"type":"message","role":"assistant","content":"lo","delta":true}"#,
            "\n",
            r#"{"type":"result","status":"success","stats":{"input_tokens":8,"output_tokens":2}}"#,
            "\n"
        );
        let engine = Engine {
            model: "gemini-2.5-pro".into(),
            runner: FakeRunner::ok(stream_out),
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
        assert_eq!(completion.usage.unwrap().completion_tokens, Some(2));
    }

    #[test]
    fn prose_reply_to_schema_request_fails() {
        let json_out = r#"{"response":"Sure, here is an explanation."}"#;
        let engine = Engine {
            model: String::new(),
            runner: FakeRunner::ok(json_out),
        };
        let err = engine
            .respond(
                &ChatRequest::new("Sys", "Hi").json_schema(json!({"type": "object"})),
                None,
                None,
            )
            .unwrap_err();
        assert!(err.to_string().contains("structured output"));
    }

    #[test]
    fn errors_classify_without_retrying_plan_limits() {
        assert_eq!(
            plan_error(&failure("UNAUTHENTICATED: please sign in", Some(401))),
            Some(&PlanError::GeminiSignInRequired)
        );
        assert!(matches!(
            plan_error(&failure("RESOURCE_EXHAUSTED: quota exceeded", Some(429))),
            Some(PlanError::GeminiUsageLimitReached(_))
        ));
        assert!(matches!(
            plan_error(&failure(
                "Permission 'cloudaicompanion.licenses.selfAssign' denied on resource",
                Some(403)
            )),
            Some(PlanError::GeminiFailed(msg)) if msg.contains("onboard")
        ));
        let transient = failure("503 Service Unavailable", Some(503));
        assert!(
            transient
                .downcast_ref::<AiError>()
                .is_some_and(AiError::is_retryable)
        );
    }
}
