use std::sync::LazyLock;

use chrono::{DateTime, Utc};
use lokalbot_ai::sanitize;
use lokalbot_core::coding_agents::CodingAgentAction;
use regex::Regex;

pub const PROMPT_CHARACTERS: usize = 280;
pub const REPLY_CHARACTERS: usize = 600;
pub const TITLE_CHARACTERS: usize = 160;

fn regex(pattern: &str) -> Regex {
    Regex::new(pattern).expect("built-in coding-agent pattern")
}

const IGNORED_PROMPT_PREFIXES: &[&str] = &[
    "<local-command",
    "Caveat:",
    "[Request interrupted",
    "# AGENTS.md instructions",
    "<permissions",
    "<image",
    "</image>",
    "<collaboration_mode",
];

static BLOCK_OPENING: LazyLock<Regex> =
    LazyLock::new(|| regex(r"<([a-z]+(?:[-_][a-z0-9]+)+|skill|attachments?)\b[^>]*>"));
static HARNESS_TAG_OPENING: LazyLock<Regex> =
    LazyLock::new(|| regex(r"^(<[a-z]+(?:[-_][a-z0-9]+)+)\b"));
static PASTED_CONTENT: LazyLock<Regex> =
    LazyLock::new(|| regex(r"<pasted_content\b[^>]*>[\s\S]*?</pasted_content[^>]*>"));
static COMMAND_NAME: LazyLock<Regex> =
    LazyLock::new(|| regex(r"<command-name>\s*(/[^<\s]+)\s*</command-name>"));
static COMMAND_ARGUMENTS: LazyLock<Regex> =
    LazyLock::new(|| regex(r"<command-args>([\s\S]*?)</command-args>"));
static BASH_INPUT: LazyLock<Regex> =
    LazyLock::new(|| regex(r"<bash-input>([\s\S]*?)</bash-input>"));
static AUTOMATION_ID: LazyLock<Regex> =
    LazyLock::new(|| regex(r"^<heartbeat>[\s\S]*?<automation_id>\s*([^<]+?)\s*</automation_id>"));
static SCHEDULED_TASK_NAME: LazyLock<Regex> =
    LazyLock::new(|| regex(r#"^<scheduled-task\b[^>]*\bname="([^"]+)""#));

const HOUSEKEEPING_COMMANDS: &[&str] = &[
    "/clear",
    "/compact",
    "/model",
    "/resume",
    "/exit",
    "/config",
    "/login",
    "/logout",
    "/cost",
    "/status",
    "/help",
    "/context",
    "/mcp",
    "/permissions",
    "/hooks",
    "/memory",
    "/doctor",
    "/usage",
    "/fast",
    "/effort",
    "/rename",
    "/export",
];

static COMMIT_MESSAGE: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r#"\bgit\s+(?:-C\s+\S+\s+)?commit\b[^\n]*?\s-[a-zA-Z]*m\s*(?:"\$\(cat\s+<<-?\s*'?\w+'?\s*\n\s*([^\n]{3,200})|"((?:[^"\\\n]|\\.){3,200})|'([^'\n]{3,200})')"#,
    )
});
static PULL_REQUEST_TITLE: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r#"\bgh\s+pr\s+create\b[^\n]*?\s(?:--title|-t)(?:\s+|=)(?:"((?:[^"\\\n]|\\.){3,200})"|'([^'\n]{3,200})')"#,
    )
});
static PULL_REQUEST_MERGE: LazyLock<Regex> = LazyLock::new(|| {
    regex(r"\bgh\s+pr\s+merge\b(?:\s+(?:https://github\.com/[\w.-]+/[\w.-]+/pull/)?(\d+))?")
});
static RELEASE_TAG: LazyLock<Regex> =
    LazyLock::new(|| regex(r#"\bgh\s+release\s+create\s+([^\s"';&|]+)"#));
static GIT_PUSH: LazyLock<Regex> = LazyLock::new(|| regex(r"\bgit\s+(?:-C\s+\S+\s+)?push\b"));
static TEST_RUN: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"\bxcodebuild\b[^\n;&|]*\btest(?:-without-building)?\b|\b(?:swift|cargo|go|forge|bun|deno)\s+test\b|\b(?:npm|pnpm|yarn)\s+(?:run\s+)?test\b|\bpytest\b|Scripts/(?:test/)?ui-tests\.sh",
    )
});
static PULL_REQUEST_URL: LazyLock<Regex> =
    LazyLock::new(|| regex(r"(https://github\.com/[\w.-]+/[\w.-]+/pull/\d+)"));
static LOKALBOT_COMMAND: LazyLock<Regex> = LazyLock::new(|| {
    regex(
        r"(?im)\blokalbot-cli\b|(?:^|[\s/;&|(])lokalbot\s+(?:list|get|search|path|mcp|people|actions|screen)\b",
    )
});
static CLAUDE_SCRATCHPAD: LazyLock<Regex> =
    LazyLock::new(|| regex(r"^/(?:private/)?tmp/claude-\d+/[^/]+/[0-9a-f-]{36}/scratchpad/"));
static WORKTREE_ROOT: LazyLock<Regex> =
    LazyLock::new(|| regex(r"^.*/\.claude/worktrees/[^/]+/|^.*/\.codex/worktrees/[^/]+/[^/]+/"));

fn first_capture(expression: &Regex, text: &str) -> Option<String> {
    expression
        .captures(text)?
        .get(1)
        .map(|m| m.as_str().to_string())
}

fn closing_tag_end(rest: &str, name: &str) -> Option<usize> {
    let marker = format!("</{name}");
    let mut from = 0;
    while let Some(found) = rest[from..].find(&marker) {
        let after = from + found + marker.len();
        let tail = &rest[after..];
        let spaces = tail.len() - tail.trim_start().len();
        if tail[spaces..].starts_with('>') {
            return Some(after + spaces + 1);
        }
        from = after;
    }
    None
}

fn removing_blocks(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let (mut copied, mut search) = (0, 0);
    while let Some(captures) = BLOCK_OPENING.captures_at(text, search) {
        let (Some(whole), Some(name)) = (captures.get(0), captures.get(1)) else {
            break;
        };
        match closing_tag_end(&text[whole.end()..], name.as_str()) {
            Some(length) => {
                output.push_str(&text[copied..whole.start()]);
                output.push(' ');
                copied = whole.end() + length;
                search = copied;
            }
            None => search = whole.start() + 1,
        }
    }
    output.push_str(&text[copied..]);
    output
}

pub fn sanitized(text: &str, max_characters: usize) -> String {
    let redacted = sanitize::redact(text);
    let line = redacted.split_whitespace().collect::<Vec<_>>().join(" ");
    sanitize::sanitize(&line, Some(max_characters))
}

pub fn truncated(text: &str, max_characters: usize) -> String {
    sanitize::sanitize(text, Some(max_characters))
}

pub fn prompt(raw: &str) -> Option<String> {
    let text = ["## My request for Codex:", "## My request:"]
        .iter()
        .find_map(|marker| raw.find(marker).map(|index| &raw[index + marker.len()..]))
        .unwrap_or(raw);
    let trimmed = text.trim();
    if let Some(automation) = scheduled_run(trimmed) {
        return Some(automation);
    }
    if let Some(command) = first_capture(&COMMAND_NAME, trimmed) {
        return slash_command(&command, trimmed);
    }
    if let Some(command) = terminal_command(trimmed) {
        return Some(sanitized(
            &format!("Ran in terminal: {command}"),
            PROMPT_CHARACTERS,
        ));
    }
    if IGNORED_PROMPT_PREFIXES
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
    {
        return None;
    }
    let text = PASTED_CONTENT.replace_all(trimmed, "[pasted text]");
    let clean = sanitized(&removing_blocks(&text), PROMPT_CHARACTERS);
    (!clean.is_empty() && !HARNESS_TAG_OPENING.is_match(&clean)).then_some(clean)
}

pub fn terminal_command(raw: &str) -> Option<String> {
    first_capture(&BASH_INPUT, raw).map(|command| command.trim().to_string())
}

pub fn reply(raw: &str) -> Option<String> {
    let clean = sanitized(&removing_blocks(raw), REPLY_CHARACTERS);
    (!clean.is_empty()).then_some(clean)
}

pub fn title(raw: &str) -> Option<String> {
    let clean = sanitized(raw, TITLE_CHARACTERS);
    (!clean.is_empty()).then_some(clean)
}

fn slash_command(name: &str, text: &str) -> Option<String> {
    if HOUSEKEEPING_COMMANDS.contains(&name.to_lowercase().as_str()) {
        return None;
    }
    let arguments = first_capture(&COMMAND_ARGUMENTS, text).unwrap_or_default();
    Some(sanitized(&format!("{name} {arguments}"), PROMPT_CHARACTERS))
}

fn scheduled_run(text: &str) -> Option<String> {
    if text.starts_with("<heartbeat>") {
        let id = first_capture(&AUTOMATION_ID, text).unwrap_or_else(|| "unnamed".into());
        return Some(format!("Scheduled automation: {}", sanitized(&id, 80)));
    }
    first_capture(&SCHEDULED_TASK_NAME, text)
        .map(|name| format!("Scheduled task: {}", sanitized(&name, 80)))
}

fn message(captures: &regex::Captures) -> Option<String> {
    captures
        .iter()
        .skip(1)
        .flatten()
        .next()
        .map(|m| m.as_str().replace("\\\"", "\""))
}

pub fn actions_in_command(command: &str) -> Vec<CodingAgentAction> {
    let command = unwrapped_shell_command(command);
    let mut actions: Vec<CodingAgentAction> = Vec::new();
    let mut append = |action: CodingAgentAction| {
        if !actions.contains(&action) {
            actions.push(action);
        }
    };
    for captures in COMMIT_MESSAGE.captures_iter(&command) {
        if let Some(clean) = message(&captures).as_deref().and_then(title) {
            append(CodingAgentAction::Commit { message: clean });
        }
    }
    for captures in PULL_REQUEST_TITLE.captures_iter(&command) {
        if let Some(clean) = message(&captures).as_deref().and_then(title) {
            append(CodingAgentAction::OpenedPullRequest { title: clean });
        }
    }
    for captures in PULL_REQUEST_MERGE.captures_iter(&command) {
        append(CodingAgentAction::MergedPullRequest {
            number: captures.get(1).and_then(|m| m.as_str().parse().ok()),
        });
    }
    for captures in RELEASE_TAG.captures_iter(&command) {
        if let Some(tag) = captures.get(1) {
            append(CodingAgentAction::Release {
                tag: tag.as_str().to_string(),
            });
        }
    }
    if GIT_PUSH.is_match(&command) {
        append(CodingAgentAction::Pushed {});
    }
    if TEST_RUN.is_match(&command) {
        append(CodingAgentAction::RanTests {});
    }
    actions
}

pub fn pull_request_urls(text: &str) -> Vec<String> {
    let mut urls: Vec<String> = Vec::new();
    for captures in PULL_REQUEST_URL.captures_iter(text) {
        if let Some(url) = captures.get(1).map(|m| m.as_str().to_string())
            && !urls.contains(&url)
        {
            urls.push(url);
        }
    }
    urls
}

pub fn reads_lokalbot_command(command: &str) -> bool {
    LOKALBOT_COMMAND.is_match(command)
}

pub fn reads_lokalbot_tool(name: &str) -> bool {
    name.to_lowercase().contains("lokalbot")
}

pub fn unwrapped_shell_command(command: &str) -> String {
    if command.starts_with('[')
        && let Ok(argv) = serde_json::from_str::<Vec<String>>(command)
        && let Some(script) = argv.last()
    {
        return script.clone();
    }
    command.to_string()
}

pub fn home_directory() -> Option<String> {
    std::env::home_dir()
        .and_then(|home| home.to_str().map(str::to_string))
        .map(|home| normalized_separators(&home))
}

pub fn is_windows_path(path: &str) -> bool {
    let bytes = path.as_bytes();
    (bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':')
        || path.starts_with("\\\\")
}

fn normalized_separators(path: &str) -> String {
    if is_windows_path(path) {
        path.replace('\\', "/")
    } else {
        path.to_string()
    }
}

pub fn standardized_path(path: &str, home: Option<&str>) -> String {
    let path = normalized_separators(path);
    let home = home.map(normalized_separators);
    let expanded = match (path.strip_prefix('~'), home) {
        (Some(""), Some(home)) => home,
        (Some(rest), Some(home)) if is_windows_path(&home) && rest.starts_with(['/', '\\']) => {
            format!("{home}{}", rest.replace('\\', "/"))
        }
        (Some(rest), Some(home)) if rest.starts_with('/') => format!("{home}{rest}"),
        _ => path,
    };
    let absolute = expanded.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in expanded.split('/') {
        match part {
            "" | "." => {}
            ".." if parts.last().is_some_and(|last| *last != "..") => {
                parts.pop();
            }
            ".." if absolute => {}
            part => parts.push(part),
        }
    }
    let joined = parts.join("/");
    if absolute {
        format!("/{joined}")
    } else {
        joined
    }
}

pub fn display_path(path: &str, working_directory: Option<&str>) -> String {
    display_path_in(path, working_directory, home_directory().as_deref())
}

pub fn display_path_in(path: &str, working_directory: Option<&str>, home: Option<&str>) -> String {
    let value = standardized_path(path, home);
    if let Some(found) = CLAUDE_SCRATCHPAD.find(&value) {
        return format!("scratchpad/{}", &value[found.end()..]);
    }
    if let Some(found) = WORKTREE_ROOT.find(&value) {
        return value[found.end()..].to_string();
    }
    if let Some(directory) = working_directory {
        let root = standardized_path(directory, home);
        if let Some(rest) = strip_folder(&value, &root) {
            return rest.to_string();
        }
    }
    if let Some(home) = home
        && let Some(rest) = strip_folder(&value, home)
    {
        return format!("~/{rest}");
    }
    value
}

fn strip_folder<'a>(path: &'a str, folder: &str) -> Option<&'a str> {
    if is_windows_path(path) {
        let prefix = path.get(..folder.len())?;
        if prefix.eq_ignore_ascii_case(folder) {
            return path[folder.len()..].strip_prefix('/');
        }
        return None;
    }
    path.strip_prefix(folder)?.strip_prefix('/')
}

pub fn is_inside(path: &str, folder: &str) -> bool {
    if is_windows_path(path) {
        path.eq_ignore_ascii_case(folder) || strip_folder(path, folder).is_some()
    } else {
        path == folder || strip_folder(path, folder).is_some()
    }
}

pub fn timestamp(value: &str) -> Option<DateTime<Utc>> {
    lokalbot_core::time::parse_iso(value)
}

#[derive(Clone, Copy)]
pub struct Line<'a>(pub &'a [u8]);

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

impl Line<'_> {
    pub fn prefix_contains(&self, limit: usize, needle: &str) -> bool {
        find(&self.0[..limit.min(self.0.len())], needle.as_bytes()).is_some()
    }

    pub fn string_value(&self, key: &str) -> Option<String> {
        let marker = format!("\"{key}\":\"");
        let start = find(self.0, marker.as_bytes())? + marker.len();
        let length = self.0[start..].iter().position(|byte| *byte == b'"')?;
        String::from_utf8(self.0[start..start + length].to_vec()).ok()
    }

    pub fn object(&self) -> Option<serde_json::Value> {
        serde_json::from_slice::<serde_json::Value>(self.0)
            .ok()
            .filter(serde_json::Value::is_object)
    }
}
