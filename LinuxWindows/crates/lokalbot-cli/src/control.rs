//! `config`, `secret`, `setup`, `models`, `permissions`, `status`, `doctor`,
//! `restart` and `open` (`CLI/Commands/*`, `AppControlClient.swift`). Every read
//! and write of a setting goes through the running app, so its decoding and
//! coupling rules apply once. Nothing here can approve a request: that happens
//! only in the app, with the person looking at it.

use std::io::{IsTerminal as _, Read as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use clap::{Args, Subcommand};
use lokalbot_core::control::protocol::{
    self as protocol, AppSecret, BACKGROUND_LAUNCH_ARGUMENT, ControlError, MODEL_PRESETS,
    PERMISSION_NAMES, Request, RequestState, SETTINGS_DESTINATIONS,
};
use lokalbot_core::control::registry::{self, SettingCategory, SettingSpec, SettingTier};
use lokalbot_core::control::setup::{self, Grant, SetupAnswer, SetupPlan, SetupRequest};
use lokalbot_core::control::{change::ChangeRequest, socket};
use lokalbot_core::{LibraryPaths, access};
use serde_json::{Map, Value, json};

use crate::session::render_table;
use crate::{CliError, json as output, validation};

/// Exit codes for requests that need the person, so a script can tell a request
/// still waiting from one they declined or nobody answered.
pub const EXIT_WAITING: i32 = 3;
pub const EXIT_DENIED: i32 = 4;
pub const EXIT_EXPIRED: i32 = 5;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

/// How commands that need the running app reach it.
#[derive(Args, Debug, Clone)]
pub struct LaunchOptions {
    /// Fail instead of starting LokalBot when it is not running.
    #[arg(long)]
    pub no_launch: bool,
    /// Seconds to wait for LokalBot to start and answer.
    #[arg(long, default_value_t = 30.0)]
    pub launch_timeout: f64,
}

#[derive(Args, Debug, Clone)]
pub struct WaitOptions {
    /// Seconds to wait for the person to answer in LokalBot (at most 300).
    #[arg(long, value_name = "seconds")]
    pub wait: Option<f64>,
}

#[derive(Subcommand, Debug)]
pub enum ConfigCommand {
    /// Print a JSON Schema of every setting (no values).
    Schema,
    /// Describe one setting: type, allowed values, range, category, and tier.
    ///
    /// tier is preference (changes nothing about what is captured or sent),
    /// consent (widening it needs approval in LokalBot), or readOnly (never
    /// changed from the terminal).
    Describe {
        /// Setting key, e.g. autoRecordMode.
        key: String,
    },
    /// Find settings by words in their key, title, or description.
    Search {
        /// Words to match, e.g. dark mode.
        #[arg(required = true)]
        words: Vec<String>,
        /// Plain-text table instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// List current values from the running app.
    List {
        /// Only one category.
        #[arg(long)]
        category: Option<String>,
        /// Only settings that differ from their defaults.
        #[arg(long)]
        changed: bool,
        /// Plain-text table instead of JSON.
        #[arg(long)]
        table: bool,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Read settings from the running app.
    ///
    /// One key prints that setting's entry; several keys print an array.
    /// --value prints only the value, for scripts.
    Get {
        /// One or more setting keys.
        #[arg(required = true)]
        keys: Vec<String>,
        /// Print only the value of each key, one per line.
        #[arg(long)]
        value: bool,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Change settings in the running app.
    ///
    /// Pass key=value pairs; values use the tokens from describe. Lists take
    /// commas or JSON. All pairs apply or none do. Preferences, and changes
    /// that narrow what LokalBot captures or sends, apply right away. Turning
    /// on capture, a data source, or sharing (tier consent) sends the whole
    /// request to the person in LokalBot and returns needs_approval with a
    /// request id (exit 3). --wait follows it: exit 0 approved, 4 declined, 5
    /// expired.
    Set {
        /// key=value pairs.
        #[arg(required = true)]
        assignments: Vec<String>,
        /// Report what would change without changing anything.
        #[arg(long)]
        dry_run: bool,
        #[command(flatten)]
        approval: WaitOptions,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Put settings back to their defaults.
    ///
    /// Follows the same rules as set: a reset that would widen capture or
    /// sharing waits for the person.
    Reset {
        /// One or more setting keys.
        #[arg(required = true)]
        keys: Vec<String>,
        /// Report what would change without changing anything.
        #[arg(long)]
        dry_run: bool,
        #[command(flatten)]
        approval: WaitOptions,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Print settings as a JSON object that import accepts.
    ///
    /// URLs are shown without user names, passwords, or query strings;
    /// importing them back keeps those parts.
    Export {
        /// Only settings that differ from their defaults.
        #[arg(long)]
        changed: bool,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Apply a JSON object of settings, as export prints it.
    ///
    /// Keys whose values already match are left alone. Follows the same rules
    /// as set, all or nothing. Read the file with - for stdin.
    Import {
        /// A JSON file, or - for stdin.
        file: String,
        /// Report what would change without changing anything.
        #[arg(long)]
        dry_run: bool,
        #[command(flatten)]
        approval: WaitOptions,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Show whether the person answered a request that needed approval.
    ///
    /// Exits 0 when approved, 3 while waiting, 4 when the person declined, and
    /// 5 when nobody answered in time. LokalBot forgets answers after 30
    /// minutes.
    Request {
        /// The request id from a needs_approval reply.
        id: String,
        #[command(flatten)]
        approval: WaitOptions,
        /// Seconds to wait for LokalBot to answer.
        #[arg(long, default_value_t = 30.0)]
        launch_timeout: f64,
    },
}

#[derive(Subcommand, Debug)]
pub enum SecretCommand {
    /// List the API keys and whether each is saved.
    List {
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Save an API key, after the person approves it in LokalBot.
    ///
    /// Reads the key from standard input, so it stays out of shell history and
    /// process lists. The approval card shows only its last four characters.
    Set {
        /// Which key: openai-compatible, remote-transcription, or autocomplete-server.
        name: String,
        #[command(flatten)]
        approval: WaitOptions,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Remove a saved API key.
    Clear {
        /// Which key.
        name: String,
        #[command(flatten)]
        launch: LaunchOptions,
    },
}

#[derive(Subcommand, Debug)]
pub enum SetupCommand {
    /// Ask the person to let this agent set up LokalBot.
    ///
    /// Leaves a request that LokalBot shows the person, starting LokalBot if
    /// needed. Read access to the meeting library, screen memory, or Files
    /// appears as separate boxes, off unless the person ticks them. Exits 0 when
    /// allowed, 3 while waiting, 4 when declined, and 5 when nobody answered in
    /// time.
    Start {
        /// Also ask for read access to the meeting library.
        #[arg(long)]
        meeting_library: bool,
        /// Also ask for read access to screen memory.
        #[arg(long)]
        screen_memory: bool,
        /// Also ask to search the folders the person chose under Files.
        #[arg(long)]
        files: bool,
        /// Seconds to wait for the person to answer (at most 300).
        #[arg(long, value_name = "seconds")]
        wait: Option<f64>,
    },
    /// Print a setup plan to agree with the person: the settings a setup covers, with their current values, the model preset suited to this computer, and launch at login.
    ///
    /// Edit the values to the person's answers, then pass the file to setup
    /// apply. notes lists the settings whose change needs approval.
    Plan {
        /// Model preset: recommended or lightweight.
        ///
        /// Defaults to the one suited to this computer.
        #[arg(long)]
        preset: Option<String>,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Apply an agreed setup plan: starts the model preset, sets launch at login, and applies preferences right away.
    ///
    /// Changes that widen what LokalBot captures or sends go to one approval
    /// card in LokalBot. Exits 0 when everything applied, 3 while the card
    /// waits, 4 when the person declined it, and 5 when nobody answered in
    /// time.
    Apply {
        /// A plan from setup plan, or - for stdin.
        file: String,
        #[command(flatten)]
        approval: WaitOptions,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Close onboarding; LokalBot runs in the tray from now on.
    Finish {
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Turn starting LokalBot at login on or off.
    #[command(name = "launch-at-login")]
    LaunchAtLogin {
        /// on or off.
        state: String,
        #[command(flatten)]
        launch: LaunchOptions,
    },
}

#[derive(Subcommand, Debug)]
pub enum ModelsCommand {
    /// Readiness and download progress for each model role, and the preset
    /// suited to this computer.
    Status {
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Download and switch to a model preset: recommended or lightweight.
    ///
    /// The current models stay in use until the new ones are ready.
    Preset {
        /// recommended or lightweight.
        preset: String,
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Download the models the current selection needs.
    Download {
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Stop switching to a preset; the current models stay.
    Cancel {
        #[command(flatten)]
        launch: LaunchOptions,
    },
}

#[derive(Subcommand, Debug)]
pub enum PermissionsCommand {
    /// List what LokalBot needs from this computer.
    List {
        #[command(flatten)]
        launch: LaunchOptions,
    },
    /// Ask the person for a permission.
    ///
    /// Opens the system's settings where it has any; the person decides.
    Request {
        /// microphone, window-titles, accessibility, screen-recording,
        /// credential-store, input-monitoring, or calendar.
        name: String,
        #[command(flatten)]
        launch: LaunchOptions,
    },
}

/// Sends one request to the running app, starting the app in the background
/// when no copy is running for this library.
pub struct Client {
    paths: LibraryPaths,
    explicit_root: Option<PathBuf>,
}

impl Client {
    pub fn new(paths: LibraryPaths, explicit_root: Option<PathBuf>) -> Self {
        Self {
            paths,
            explicit_root,
        }
    }

    fn send(&self, request: &Request) -> std::io::Result<protocol::Response> {
        let endpoint = socket::endpoint(self.paths.root())?;
        socket::exchange(&endpoint, request, REQUEST_TIMEOUT)
    }

    fn unwrap(response: protocol::Response) -> Result<Value, ControlError> {
        if let Some(error) = response.error {
            return Err(error);
        }
        Ok(response.result.unwrap_or(Value::Null))
    }

    /// The result of `method`, or the app's error.
    pub fn request(
        &self,
        method: &str,
        params: Option<Map<String, Value>>,
        launch: bool,
        launch_timeout: f64,
    ) -> Result<Value, ControlError> {
        // Never start the app for an agent the person has not allowed.
        if !access::settings_control_enabled(&self.paths) {
            return Err(ControlError::settings_access_disabled());
        }
        let request = Request::new(method, params);
        if let Ok(response) = self.send(&request) {
            return Self::unwrap(response);
        }
        if !socket::is_app_running(&self.paths) {
            if !launch {
                return Err(ControlError::app_not_running(
                    "LokalBot is not running, and --no-launch was given.",
                ));
            }
            self.launch_app(BACKGROUND_LAUNCH_ARGUMENT)?;
        }
        let deadline = Instant::now() + Duration::from_secs_f64(launch_timeout.max(1.0));
        while Instant::now() < deadline {
            if let Ok(response) = self.send(&request) {
                return Self::unwrap(response);
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        Err(ControlError::app_not_responding())
    }

    /// The LokalBot beside this CLI, resolved through the installed link.
    /// Launching by path, never by name, keeps a CLI from starting a different
    /// copy with another library.
    fn enclosing_app() -> Option<PathBuf> {
        let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
        app_beside(&exe)
    }

    fn launch_app(&self, argument: &str) -> Result<(), ControlError> {
        let Some(app) = Self::enclosing_app() else {
            return Err(ControlError::app_not_running(
                "LokalBot is not running, and this lokalbot-cli is not installed next to LokalBot, so it cannot start it.",
            ));
        };
        let mut command = std::process::Command::new(&app);
        command
            .arg(argument)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        if let Some(root) = &self.explicit_root {
            command
                .arg(lokalbot_core::paths::STORAGE_ROOT_FLAG)
                .arg(root);
        }
        detach(&mut command);
        command.spawn().map(drop).map_err(|err| {
            ControlError::app_not_running(format!("Could not start LokalBot: {err}"))
        })
    }
}

/// `lokalbot` beside `cli`, or one folder up: Windows keeps the command in
/// `Programs\LokalBot\bin` and the app in `Programs\LokalBot`.
fn app_beside(cli: &Path) -> Option<PathBuf> {
    let name = if cfg!(windows) {
        "lokalbot.exe"
    } else {
        "lokalbot"
    };
    let folder = cli.parent()?;
    [Some(folder), folder.parent()]
        .into_iter()
        .flatten()
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

#[cfg(unix)]
fn detach(command: &mut std::process::Command) {
    use std::os::unix::process::CommandExt as _;
    command.process_group(0);
}

#[cfg(windows)]
fn detach(command: &mut std::process::Command) {
    use std::os::windows::process::CommandExt as _;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
}

fn pretty(value: &Value) -> String {
    output::pretty(value, false)
}

/// A value on one line: strings bare, everything else as compact JSON.
fn plain(value: Option<&Value>) -> String {
    match value {
        None => String::new(),
        Some(Value::String(text)) => text.clone(),
        Some(Value::Null) => "—".to_string(),
        Some(other) => output::compact(other),
    }
}

fn require_spec(key: &str) -> Result<&'static SettingSpec, CliError> {
    if let Some(spec) = registry::spec(key) {
        return Ok(spec);
    }
    let suggestions: Vec<&str> = registry::search(key)
        .into_iter()
        .take(5)
        .map(|spec| spec.key)
        .collect();
    let hint = if suggestions.is_empty() {
        "Run `lokalbot-cli config search <words>` to find one.".to_string()
    } else {
        format!("Did you mean: {}?", suggestions.join(", "))
    };
    Err(validation(format!("No setting is named {key}. {hint}")))
}

fn stderr(line: &str) {
    eprintln!("{line}");
}

fn exit(code: i32, stdout: String) -> CliError {
    CliError::Exit { code, stdout }
}

impl LaunchOptions {
    fn request(
        &self,
        client: &Client,
        method: &str,
        params: Option<Map<String, Value>>,
    ) -> Result<Value, CliError> {
        if self.launch_timeout <= 0.0 {
            return Err(validation("--launch-timeout must be positive."));
        }
        client
            .request(method, params, !self.no_launch, self.launch_timeout)
            .map_err(CliError::Control)
    }
}

/// Exit code and reason for a request's state, or `None` once it was approved.
fn exit_code_for(state: Option<&str>) -> Option<i32> {
    match state.and_then(RequestState::parse) {
        Some(RequestState::Approved) => None,
        Some(RequestState::Denied) => {
            stderr(&ControlError::denied().to_string());
            Some(EXIT_DENIED)
        }
        Some(RequestState::Expired) => {
            stderr(&ControlError::expired().to_string());
            Some(EXIT_EXPIRED)
        }
        _ => {
            stderr("[needs_approval] Still waiting for the person in LokalBot.");
            Some(EXIT_WAITING)
        }
    }
}

/// Polls the running app until the request is answered or `seconds` pass. Never
/// starts LokalBot: a request lives only in the copy that took it.
fn poll(client: &Client, id: &str, seconds: f64, launch_timeout: f64) -> Result<Value, CliError> {
    let deadline = Instant::now() + Duration::from_secs_f64(seconds.clamp(0.0, 300.0));
    let mut params = Map::new();
    params.insert("id".into(), json!(id));
    loop {
        let request = client
            .request(
                protocol::METHOD_SETTINGS_REQUEST,
                Some(params.clone()),
                false,
                launch_timeout,
            )
            .map_err(CliError::Control)?;
        let waiting = request["state"].as_str() == Some(RequestState::Pending.raw_value());
        if !waiting || Instant::now() >= deadline {
            return Ok(request);
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

/// Prints a request and exits with the code its state maps to.
fn report(request: Value) -> Result<String, CliError> {
    match exit_code_for(request["state"].as_str()) {
        Some(code) => Err(exit(code, pretty(&request))),
        None => Ok(pretty(&request)),
    }
}

/// Sends a request that may need the person and prints the reply. A request left
/// waiting prints as JSON and exits 3, or, with --wait, is followed until the
/// person answers: 0 approved, 4 denied, 5 expired.
fn send_for_approval(
    client: &Client,
    method: &str,
    params: Map<String, Value>,
    launch: &LaunchOptions,
    wait: Option<f64>,
) -> Result<String, CliError> {
    let error_json = |error: &ControlError| {
        pretty(&json!({
            "error": error.code,
            "message": error.message,
            "details": error.details.clone().unwrap_or(Value::Null),
        }))
    };
    match launch.request(client, method, Some(params)) {
        Ok(value) => Ok(pretty(&value)),
        Err(CliError::Control(error)) if error.code == "needs_approval" => {
            let Some(id) = error
                .details
                .as_ref()
                .and_then(|details| details["id"].as_str())
                .map(str::to_string)
            else {
                return Err(CliError::Control(error));
            };
            let Some(wait) = wait.filter(|wait| *wait > 0.0) else {
                return Err(exit(EXIT_WAITING, error_json(&error)));
            };
            stderr("Waiting for the person to answer in LokalBot…");
            report(poll(client, &id, wait, launch.launch_timeout)?)
        }
        Err(CliError::Control(error)) if error.details.is_some() => {
            Err(exit(1, error_json(&error)))
        }
        Err(other) => Err(other),
    }
}

fn read_json_file(file: &str) -> Result<Value, CliError> {
    let data = if file == "-" {
        let mut data = Vec::new();
        std::io::stdin()
            .read_to_end(&mut data)
            .map_err(|err| CliError::Failure(err.to_string()))?;
        data
    } else {
        std::fs::read(expand_home(file))
            .map_err(|err| CliError::Failure(format!("{file}: {err}")))?
    };
    serde_json::from_slice(&data).map_err(|_| validation(format!("{file} is not JSON.")))
}

fn expand_home(path: &str) -> PathBuf {
    if let Some(rest) = path.strip_prefix("~/")
        && let Some(dirs) = directories::BaseDirs::new()
    {
        return dirs.home_dir().join(rest);
    }
    PathBuf::from(path)
}

fn change_request(changes: Map<String, Value>, reset: Vec<String>, dry_run: bool) -> ChangeRequest {
    ChangeRequest {
        changes,
        reset,
        dry_run,
    }
}

pub fn run_config(command: ConfigCommand, client: &Client) -> Result<String, CliError> {
    match command {
        ConfigCommand::Schema => Ok(pretty(&registry::json_schema())),
        ConfigCommand::Describe { key } => Ok(pretty(&require_spec(&key)?.description_json())),
        ConfigCommand::Search { words, table } => {
            let matches = registry::search(&words.join(" "));
            if table {
                if matches.is_empty() {
                    return Ok("(no settings)".into());
                }
                let rows = matches
                    .iter()
                    .map(|spec| {
                        vec![
                            spec.key.to_string(),
                            spec.title.to_string(),
                            spec.category.raw_value().to_string(),
                            spec.tier.raw_value().to_string(),
                        ]
                    })
                    .collect::<Vec<_>>();
                return Ok(render_table(&["Key", "Title", "Category", "Tier"], &rows));
            }
            let entries: Vec<Value> = matches
                .iter()
                .map(|spec| {
                    json!({
                        "key": spec.key,
                        "title": spec.title,
                        "category": spec.category.raw_value(),
                        "tier": spec.tier.raw_value(),
                        "summary": spec.summary,
                    })
                })
                .collect();
            Ok(pretty(&json!(entries)))
        }
        ConfigCommand::List {
            category,
            changed,
            table,
            launch,
        } => {
            let mut params = Map::new();
            if let Some(category) = &category {
                if SettingCategory::parse(category).is_none() {
                    return Err(validation(format!("Unknown category {category}.")));
                }
                params.insert("category".into(), json!(category));
            }
            let reply = launch.request(client, protocol::METHOD_SETTINGS_LIST, Some(params))?;
            let Value::Array(mut entries) = reply else {
                return Err(CliError::Control(ControlError::invalid_request(
                    "LokalBot returned an unexpected settings list.",
                )));
            };
            if changed {
                entries.retain(|entry| entry["changed"] == json!(true));
            }
            if !table {
                return Ok(pretty(&Value::Array(entries)));
            }
            if entries.is_empty() {
                return Ok("(no settings)".into());
            }
            let rows = entries
                .iter()
                .map(|entry| {
                    vec![
                        plain(entry.get("key")),
                        plain(entry.get("value")).chars().take(60).collect(),
                        plain(entry.get("default")).chars().take(40).collect(),
                        plain(entry.get("tier")),
                    ]
                })
                .collect::<Vec<_>>();
            Ok(render_table(&["Key", "Value", "Default", "Tier"], &rows))
        }
        ConfigCommand::Get {
            keys,
            value,
            launch,
        } => {
            for key in &keys {
                require_spec(key)?;
            }
            let mut params = Map::new();
            params.insert("keys".into(), json!(keys));
            let reply = launch.request(client, protocol::METHOD_SETTINGS_GET, Some(params))?;
            let Value::Array(entries) = reply else {
                return Err(CliError::Control(ControlError::invalid_request(
                    "LokalBot returned an unexpected settings reply.",
                )));
            };
            if value {
                Ok(entries
                    .iter()
                    .map(|entry| plain(entry.get("value")))
                    .collect::<Vec<_>>()
                    .join("\n"))
            } else if entries.len() == 1 {
                Ok(pretty(&entries[0]))
            } else {
                Ok(pretty(&Value::Array(entries)))
            }
        }
        ConfigCommand::Set {
            assignments,
            dry_run,
            approval,
            launch,
        } => {
            let mut changes = Map::new();
            for assignment in &assignments {
                let Some((key, value)) = assignment.split_once('=').filter(|(k, _)| !k.is_empty())
                else {
                    return Err(validation(format!("{assignment} is not key=value.")));
                };
                if changes.contains_key(key) {
                    return Err(validation(format!("{key} is given twice.")));
                }
                let parsed = require_spec(key)?.parse(value).map_err(CliError::Control)?;
                changes.insert(key.to_string(), parsed);
            }
            send_for_approval(
                client,
                protocol::METHOD_SETTINGS_SET,
                change_request(changes, Vec::new(), dry_run).params(),
                &launch,
                approval.wait,
            )
        }
        ConfigCommand::Reset {
            keys,
            dry_run,
            approval,
            launch,
        } => {
            for key in &keys {
                require_spec(key)?;
            }
            let unique: std::collections::HashSet<&String> = keys.iter().collect();
            if unique.len() != keys.len() {
                return Err(validation("A key is given twice."));
            }
            send_for_approval(
                client,
                protocol::METHOD_SETTINGS_SET,
                change_request(Map::new(), keys, dry_run).params(),
                &launch,
                approval.wait,
            )
        }
        ConfigCommand::Export { changed, launch } => {
            let Value::Array(entries) =
                launch.request(client, protocol::METHOD_SETTINGS_LIST, None)?
            else {
                return Err(CliError::Control(ControlError::invalid_request(
                    "LokalBot returned an unexpected settings list.",
                )));
            };
            let mut object = Map::new();
            for entry in entries {
                let Some(key) = entry["key"].as_str() else {
                    continue;
                };
                if entry["tier"].as_str() == Some(SettingTier::ReadOnly.raw_value())
                    || (changed && entry["changed"] != json!(true))
                    || entry["value"].is_null()
                {
                    continue;
                }
                object.insert(key.to_string(), entry["value"].clone());
            }
            Ok(pretty(&Value::Object(object)))
        }
        ConfigCommand::Import {
            file,
            dry_run,
            approval,
            launch,
        } => {
            let Some(object) = read_json_file(&file)?
                .as_object()
                .filter(|object| !object.is_empty())
                .cloned()
            else {
                return Err(validation(format!(
                    "{file} must hold a JSON object of setting keys and values."
                )));
            };
            for key in object.keys() {
                require_spec(key)?;
            }
            send_for_approval(
                client,
                protocol::METHOD_SETTINGS_SET,
                change_request(object, Vec::new(), dry_run).params(),
                &launch,
                approval.wait,
            )
        }
        ConfigCommand::Request {
            id,
            approval,
            launch_timeout,
        } => {
            if let Some(wait) = approval.wait.filter(|wait| *wait > 0.0) {
                return report(poll(client, &id, wait, launch_timeout)?);
            }
            let mut params = Map::new();
            params.insert("id".into(), json!(id));
            let request = client
                .request(
                    protocol::METHOD_SETTINGS_REQUEST,
                    Some(params),
                    false,
                    launch_timeout,
                )
                .map_err(CliError::Control)?;
            report(request)
        }
    }
}

pub fn run_secret(command: SecretCommand, client: &Client) -> Result<String, CliError> {
    let known = |name: &str| {
        AppSecret::parse(name)
            .map(drop)
            .ok_or_else(|| validation(ControlError::unknown_secret(name).message))
    };
    match command {
        SecretCommand::List { launch } => Ok(pretty(&launch.request(
            client,
            protocol::METHOD_SECRET_LIST,
            None,
        )?)),
        SecretCommand::Set {
            name,
            approval,
            launch,
        } => {
            known(&name)?;
            if std::io::stdin().is_terminal() {
                return Err(validation(format!(
                    "Pipe the key on standard input, for example: printf %s \"$KEY\" | lokalbot-cli secret set {name}"
                )));
            }
            let mut text = String::new();
            std::io::stdin()
                .take(64 * 1024)
                .read_to_string(&mut text)
                .map_err(|err| CliError::Failure(err.to_string()))?;
            let Some(value) = protocol::validated_secret_value(&text) else {
                return Err(validation("Standard input must hold the key on one line."));
            };
            let mut params = Map::new();
            params.insert("name".into(), json!(name));
            params.insert("value".into(), json!(value));
            send_for_approval(
                client,
                protocol::METHOD_SECRET_SET,
                params,
                &launch,
                approval.wait,
            )
        }
        SecretCommand::Clear { name, launch } => {
            known(&name)?;
            let mut params = Map::new();
            params.insert("name".into(), json!(name));
            Ok(pretty(&launch.request(
                client,
                protocol::METHOD_SECRET_CLEAR,
                Some(params),
            )?))
        }
    }
}

fn check_preset(preset: &str) -> Result<(), CliError> {
    if MODEL_PRESETS.contains(&preset) {
        Ok(())
    } else {
        Err(validation(format!(
            "Choose a preset: {}.",
            MODEL_PRESETS.join(", ")
        )))
    }
}

pub fn run_setup(command: SetupCommand, client: &Client) -> Result<String, CliError> {
    match command {
        SetupCommand::Start {
            meeting_library,
            screen_memory,
            files,
            wait,
        } => setup_start(client, meeting_library, screen_memory, files, wait),
        SetupCommand::Plan { preset, launch } => {
            let params = match preset {
                Some(preset) => {
                    check_preset(&preset)?;
                    let mut params = Map::new();
                    params.insert("preset".into(), json!(preset));
                    Some(params)
                }
                None => None,
            };
            Ok(pretty(&launch.request(
                client,
                protocol::METHOD_SETUP_PLAN,
                params,
            )?))
        }
        SetupCommand::Apply {
            file,
            approval,
            launch,
        } => setup_apply(client, &file, approval.wait, &launch),
        SetupCommand::Finish { launch } => Ok(pretty(&launch.request(
            client,
            protocol::METHOD_SETUP_FINISH,
            None,
        )?)),
        SetupCommand::LaunchAtLogin { state, launch } => {
            if state != "on" && state != "off" {
                return Err(validation("Say on or off."));
            }
            let mut params = Map::new();
            params.insert("enabled".into(), json!(state == "on"));
            Ok(pretty(&launch.request(
                client,
                protocol::METHOD_LAUNCH_AT_LOGIN,
                Some(params),
            )?))
        }
    }
}

fn setup_start(
    client: &Client,
    meeting_library: bool,
    screen_memory: bool,
    files: bool,
    wait: Option<f64>,
) -> Result<String, CliError> {
    let paths = &client.paths;
    let mut grants = vec![Grant::Settings];
    if meeting_library && !access::meetings_access_enabled(paths) {
        grants.push(Grant::MeetingLibrary);
    }
    if screen_memory && access::screen_access_scope(paths).is_none() {
        grants.push(Grant::ScreenMemory);
    }
    if files && !lokalbot_core::files::access::is_enabled(paths) {
        grants.push(Grant::Files);
    }
    if access::settings_control_enabled(paths) && grants == [Grant::Settings] {
        return Ok(pretty(
            &json!({"state": "approved", "alreadyAllowed": true}),
        ));
    }
    let control = paths.control_dir();
    let now = chrono::Utc::now();
    let request = SetupRequest {
        created_at: now,
        expires_at: now + chrono::Duration::seconds(setup::LIFETIME_SECONDS),
        grants,
        nonce: uuid::Uuid::new_v4().to_string().to_uppercase(),
        requester: setup::describe_process(std::process::id())
            .unwrap_or_else(|| "lokalbot-cli".to_string()),
        version: 1,
    };
    let _ = std::fs::remove_file(setup::answer_path(&control));
    setup::write(&request, &setup::request_path(&control))
        .map_err(|err| CliError::Failure(err.to_string()))?;
    let hint = show_setup_request(client)?;

    let Some(wait) = wait.filter(|wait| *wait > 0.0) else {
        return Err(exit(
            EXIT_WAITING,
            pretty(&json!({
                "state": "pending",
                "expiresAt": lokalbot_core::control::iso8601::text(&request.expires_at),
                "message": hint.unwrap_or_else(|| "Ask the person to answer the request in LokalBot. Run with --wait to wait for it.".to_string()),
            })),
        ));
    };
    stderr(
        hint.as_deref()
            .unwrap_or("Waiting for the person to answer in LokalBot…"),
    );
    let answer = wait_for_answer(&request, &control, wait.min(300.0));
    let state = answer
        .as_ref()
        .map_or(RequestState::Pending, |answer| answer.state);
    let mut result = Map::new();
    result.insert("state".into(), json!(state.raw_value()));
    if let Some(answer) = &answer {
        let grants: Vec<&str> = answer.grants.iter().map(|g| g.raw_value()).collect();
        result.insert("grants".into(), json!(grants));
    }
    if state == RequestState::Approved {
        // The socket opens right after the person allows it.
        result.insert(
            "appResponding".into(),
            json!(
                client
                    .request(protocol::METHOD_HELLO, None, false, 10.0)
                    .is_ok()
            ),
        );
    }
    let text = pretty(&Value::Object(result));
    match exit_code_for(Some(state.raw_value())) {
        Some(code) => Err(exit(code, text)),
        None => Ok(text),
    }
}

/// Opens LokalBot on the request. A running copy finds the file itself within a
/// second. Returns a hint when this CLI can't start LokalBot.
fn show_setup_request(client: &Client) -> Result<Option<String>, CliError> {
    if socket::is_app_running(&client.paths) {
        return Ok(None);
    }
    if Client::enclosing_app().is_none() {
        return Ok(Some(
            "This lokalbot-cli is not installed next to LokalBot, so it can't open LokalBot. Ask the person to open LokalBot; it shows the request at launch.".to_string(),
        ));
    }
    client
        .launch_app(setup::LAUNCH_ARGUMENT)
        .map_err(CliError::Control)?;
    Ok(None)
}

fn wait_for_answer(request: &SetupRequest, control: &Path, seconds: f64) -> Option<SetupAnswer> {
    let deadline = Instant::now() + Duration::from_secs_f64(seconds);
    let path = setup::answer_path(control);
    while Instant::now() < deadline {
        if let Some(answer) = setup::read::<SetupAnswer>(&path)
            && answer.nonce == request.nonce
        {
            return Some(answer);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    None
}

fn setup_apply(
    client: &Client,
    file: &str,
    wait: Option<f64>,
    launch: &LaunchOptions,
) -> Result<String, CliError> {
    let plan = SetupPlan::from_json(&read_json_file(file)?).map_err(CliError::Control)?;
    for key in plan.settings.keys() {
        require_spec(key)?;
    }
    let mut report = Map::new();
    let mut code = None;
    if let Some(models) = &plan.models {
        let mut params = Map::new();
        params.insert("preset".into(), json!(models));
        report.insert(
            "models".into(),
            launch.request(client, protocol::METHOD_MODELS_PRESET, Some(params))?,
        );
    }
    if let Some(launch_at_login) = plan.launch_at_login {
        let mut params = Map::new();
        params.insert("enabled".into(), json!(launch_at_login));
        report.insert(
            "launchAtLogin".into(),
            launch.request(client, protocol::METHOD_LAUNCH_AT_LOGIN, Some(params))?,
        );
    }
    if !plan.settings.is_empty() {
        let preview = launch.request(
            client,
            protocol::METHOD_SETTINGS_SET,
            Some(change_request(plan.settings.clone(), Vec::new(), true).params()),
        )?;
        let class_of = |key: &str| -> Option<String> {
            preview["changes"].as_array()?.iter().find_map(|entry| {
                (entry["key"].as_str() == Some(key))
                    .then(|| entry["change"].as_str().map(str::to_string))
                    .flatten()
            })
        };
        let mut read_only: Vec<&str> = plan
            .settings
            .keys()
            .filter(|key| class_of(key).as_deref() == Some("readOnly"))
            .map(String::as_str)
            .collect();
        read_only.sort_unstable();
        if !read_only.is_empty() {
            return Err(CliError::Control(ControlError::read_only(&read_only)));
        }
        let pick = |wanted: &[&str]| -> Map<String, Value> {
            plan.settings
                .iter()
                .filter(|(key, _)| {
                    class_of(key)
                        .as_deref()
                        .is_some_and(|class| wanted.contains(&class))
                })
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect()
        };
        let direct = pick(&["preference", "narrowing"]);
        let consent = pick(&["widening"]);
        if !direct.is_empty() {
            report.insert(
                "applied".into(),
                launch.request(
                    client,
                    protocol::METHOD_SETTINGS_SET,
                    Some(change_request(direct, Vec::new(), false).params()),
                )?,
            );
        }
        if !consent.is_empty() {
            match launch.request(
                client,
                protocol::METHOD_SETTINGS_SET,
                Some(change_request(consent, Vec::new(), false).params()),
            ) {
                Ok(value) => {
                    report.insert("approval".into(), value);
                }
                Err(CliError::Control(error)) if error.code == "needs_approval" => {
                    let mut request = error.details.clone().unwrap_or(Value::Null);
                    if let (Some(wait), Some(id)) = (
                        wait.filter(|wait| *wait > 0.0),
                        request["id"].as_str().map(str::to_string),
                    ) {
                        stderr("Waiting for the person to review the consent changes in LokalBot…");
                        request = poll(client, &id, wait, launch.launch_timeout)?;
                    }
                    code = exit_code_for(request["state"].as_str());
                    report.insert("approval".into(), request);
                }
                Err(other) => return Err(other),
            }
        }
    }
    let text = pretty(&Value::Object(report));
    match code {
        Some(code) => Err(exit(code, text)),
        None => Ok(text),
    }
}

pub fn run_models(
    command: Option<ModelsCommand>,
    default: LaunchOptions,
    client: &Client,
) -> Result<String, CliError> {
    let (method, params, launch) = match command {
        None => (protocol::METHOD_MODELS_STATUS, None, default),
        Some(ModelsCommand::Status { launch }) => (protocol::METHOD_MODELS_STATUS, None, launch),
        Some(ModelsCommand::Preset { preset, launch }) => {
            check_preset(&preset)?;
            let mut params = Map::new();
            params.insert("preset".into(), json!(preset));
            (protocol::METHOD_MODELS_PRESET, Some(params), launch)
        }
        Some(ModelsCommand::Download { launch }) => {
            (protocol::METHOD_MODELS_DOWNLOAD, None, launch)
        }
        Some(ModelsCommand::Cancel { launch }) => (protocol::METHOD_MODELS_CANCEL, None, launch),
    };
    Ok(pretty(&launch.request(client, method, params)?))
}

pub fn run_permissions(
    command: Option<PermissionsCommand>,
    default: LaunchOptions,
    client: &Client,
) -> Result<String, CliError> {
    let (method, params, launch) = match command {
        None => (protocol::METHOD_PERMISSIONS_LIST, None, default),
        Some(PermissionsCommand::List { launch }) => {
            (protocol::METHOD_PERMISSIONS_LIST, None, launch)
        }
        Some(PermissionsCommand::Request { name, launch }) => {
            if !PERMISSION_NAMES.contains(&name.as_str()) {
                return Err(validation(format!(
                    "Name a permission: {}.",
                    PERMISSION_NAMES.join(", ")
                )));
            }
            let mut params = Map::new();
            params.insert("name".into(), json!(name));
            (protocol::METHOD_PERMISSIONS_REQUEST, Some(params), launch)
        }
    };
    Ok(pretty(&launch.request(client, method, params)?))
}

pub fn run_status(launch: &LaunchOptions, client: &Client) -> Result<String, CliError> {
    Ok(pretty(&launch.request(
        client,
        protocol::METHOD_STATUS,
        None,
    )?))
}

pub fn run_restart(launch: &LaunchOptions, client: &Client) -> Result<String, CliError> {
    launch.request(client, protocol::METHOD_RESTART, None)?;
    std::thread::sleep(Duration::from_secs(2));
    let back = client
        .request(protocol::METHOD_HELLO, None, false, 30.0)
        .is_ok();
    let text = pretty(&json!({"restarted": back}));
    if back { Ok(text) } else { Err(exit(1, text)) }
}

pub fn run_doctor(launch: &LaunchOptions, client: &Client) -> Result<String, CliError> {
    let mut report = match launch.request(client, protocol::METHOD_DOCTOR, None) {
        Ok(Value::Object(report)) => report,
        Ok(_) => Map::new(),
        Err(CliError::Control(error))
            if error.code == ControlError::settings_access_disabled().code =>
        {
            json!({
                "ready": false,
                "checks": [{"name": "settingsAccess", "ok": false, "detail": error.message}],
                "nextSteps": ["Run `lokalbot-cli setup start --wait 300` and ask the person to allow it in LokalBot."],
            })
            .as_object()
            .cloned()
            .unwrap_or_default()
        }
        Err(other) => return Err(other),
    };
    let on_path = cli_on_path();
    let detail = if on_path {
        "lokalbot-cli is on PATH."
    } else {
        "lokalbot-cli is not on PATH. Settings → AI agents → Agent CLI installs it."
    };
    let mut checks = report
        .get("checks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    checks.push(json!({"name": "cliOnPath", "ok": on_path, "detail": detail}));
    report.insert("checks".into(), Value::Array(checks));
    let ready = report.get("ready") == Some(&json!(true));
    let text = pretty(&Value::Object(report));
    if ready { Ok(text) } else { Err(exit(1, text)) }
}

fn cli_on_path() -> bool {
    let name = if cfg!(windows) {
        "lokalbot-cli.exe"
    } else {
        "lokalbot-cli"
    };
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|directory| directory.join(name).is_file())
    })
}

pub fn run_open(
    target: &str,
    key: Option<String>,
    launch: &LaunchOptions,
    client: &Client,
) -> Result<String, CliError> {
    if target != "settings" {
        return Err(validation("open supports only `settings`."));
    }
    let mut params = Map::new();
    params.insert("target".into(), json!("settings"));
    if let Some(key) = key {
        if !SETTINGS_DESTINATIONS.contains(&key.as_str()) {
            require_spec(&key)?;
        }
        params.insert("key".into(), json!(key));
    }
    Ok(pretty(&launch.request(
        client,
        protocol::METHOD_OPEN,
        Some(params),
    )?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_client_refuses_before_connecting_while_settings_access_is_off() {
        let dir = tempfile::tempdir().unwrap();
        let client = Client::new(LibraryPaths::new(dir.path()), None);
        let error = client
            .request(protocol::METHOD_HELLO, None, true, 1.0)
            .unwrap_err();
        assert_eq!(error.code, "settings_access_disabled");
    }

    #[test]
    fn no_launch_reports_that_the_app_is_not_running() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        access::set_settings_control(&paths, true).unwrap();
        let client = Client::new(paths, None);
        let error = client
            .request(protocol::METHOD_HELLO, None, false, 1.0)
            .unwrap_err();
        assert_eq!(error.code, "app_not_running");
    }

    #[test]
    fn the_app_is_found_beside_the_cli_or_one_folder_up() {
        let dir = tempfile::tempdir().unwrap();
        let name = if cfg!(windows) {
            "lokalbot.exe"
        } else {
            "lokalbot"
        };
        let bin = dir.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        assert_eq!(app_beside(&bin.join("lokalbot-cli")), None);
        std::fs::write(dir.path().join(name), b"").unwrap();
        assert_eq!(
            app_beside(&bin.join("lokalbot-cli")),
            Some(dir.path().join(name))
        );
        std::fs::write(bin.join(name), b"").unwrap();
        assert_eq!(app_beside(&bin.join("lokalbot-cli")), Some(bin.join(name)));
    }

    #[test]
    fn exits_map_request_states() {
        assert_eq!(exit_code_for(Some("approved")), None);
        assert_eq!(exit_code_for(Some("denied")), Some(EXIT_DENIED));
        assert_eq!(exit_code_for(Some("expired")), Some(EXIT_EXPIRED));
        assert_eq!(exit_code_for(Some("pending")), Some(EXIT_WAITING));
        assert_eq!(exit_code_for(None), Some(EXIT_WAITING));
    }

    #[test]
    fn plain_values_print_on_one_line() {
        assert_eq!(plain(Some(&json!("x"))), "x");
        assert_eq!(plain(Some(&Value::Null)), "—");
        assert_eq!(plain(Some(&json!(["a"]))), "[\"a\"]");
    }
}
