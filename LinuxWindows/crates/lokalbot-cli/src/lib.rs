//! `lokalbot-cli`: read-only access to the LokalBot library, a stdio MCP server
//! and settings through the running app, with the commands, output and errors
//! of the macOS helper (`CLI/`, `LokalBot/CLISupport/`). It opens the library
//! read-only and never writes into `meetings/`.

pub mod ask;
pub mod briefing;
pub mod control;
pub mod files;
pub mod install;
pub mod json;
pub mod mcp;
pub mod notes;
pub mod personal;
pub mod reports;
pub mod screen;
pub mod search;
pub mod session;

use clap::{Parser, Subcommand};
use lokalbot_core::{LibraryPaths, access};

use crate::session::{GetOptions, Session};

pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const MAXIMUM_MEETING_COUNT: usize = 1000;

#[derive(Parser, Debug)]
#[command(
    name = "lokalbot-cli",
    version,
    about = "Read your local LokalBot meeting library and inspect app settings.",
    long_about = "Read your local LokalBot meeting library and inspect app settings.\n\nIntended for coding agents (Claude Code, Codex CLI, Cursor, Gemini) and humans alike. `install-skill` links the CLI into your PATH. Output defaults to JSON; pass --table for plain text. Library commands need meeting access, search-files needs file access, search-notes needs agent-notes access, and personal-context its own access. config, secret, models, permissions, status, doctor, restart, and open need the separate settings access in Settings → Privacy & Data. setup start asks the person for it."
)]
pub struct Cli {
    /// Read another library (same as LOKALBOT_STORAGE_ROOT).
    #[arg(long = "lokalbot-storage-root", global = true, hide = true)]
    pub storage_root: Option<std::path::PathBuf>,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Start here: what LokalBot knows that this session may use.
    Brief,
    /// List meetings, newest first.
    List {
        /// Only include meetings on or after this local day (YYYY-MM-DD).
        #[arg(long)]
        since: Option<String>,
        /// Only include meetings on or before this local day (YYYY-MM-DD).
        #[arg(long)]
        until: Option<String>,
        /// Substring match against the title (case-insensitive).
        #[arg(long)]
        query: Option<String>,
        /// Maximum number of meetings to return.
        #[arg(long)]
        limit: Option<i64>,
        /// Add each meeting's summary: --include summary. The summaries share
        /// 20,000 characters, and --limit then defaults to 10 (at most 50).
        /// Read transcripts one meeting at a time with `get <id> --include
        /// transcript`.
        #[arg(long, default_value = "metadata")]
        include: String,
        /// Plain-text table instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// Print one meeting as Markdown (default) or JSON.
    Get {
        /// Meeting ID from `list`, or 'latest' for the most recent.
        id: String,
        /// Comma-separated parts to include: metadata, summary, transcript.
        #[arg(long, default_value = "metadata,summary,transcript")]
        include: String,
        /// Output format: md (default) or json.
        #[arg(long, default_value = "md")]
        format: String,
    },
    /// Word search across titles, summaries, and transcripts.
    Search {
        /// Words to find in any order; quote for an exact phrase.
        query: String,
        /// Maximum number of hits to return.
        #[arg(long, default_value_t = 50)]
        limit: i64,
        /// Plain-text table instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// Answer a question from the meeting library with LokalBot's local model.
    ///
    /// The same answer as the ask_library MCP tool: the local model reads the
    /// meetings that match the question and answers, citing the meetings it
    /// used. Needs the LokalBot app running; the first question after a cold
    /// start can take up to a minute while the model loads. JSON by default:
    /// {"status", "text", "sources"}, where status is answered, not_found, or
    /// error (with "code"). Errors exit with status 1 after printing.
    Ask {
        /// The question to answer.
        question: String,
        /// Plain text instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// Draft a reply to a message from what your meetings say.
    ///
    /// The local model reads the meetings that match the message and drafts the
    /// user's reply from them, without inventing facts the meetings do not
    /// support. A message no meeting matches gets no draft (status not_found).
    /// Output and errors work as in `ask`; in JSON, "text" is the draft alone
    /// and "sources" lists the meetings it drew on.
    Reply {
        /// The message to reply to. Omit it to read standard input.
        message: Option<String>,
        /// Extra direction for the draft, such as "decline politely".
        #[arg(long)]
        instruction: Option<String>,
        /// Plain text instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// List meeting action items with saved corrections and status.
    Actions {
        /// active (default), open, deferred, done, or all.
        #[arg(long, default_value = "active")]
        status: String,
        /// me, others, or a participant name substring.
        #[arg(long)]
        owner: Option<String>,
        /// Meetings from the last N days (maximum 365).
        #[arg(long, default_value_t = 30)]
        days: i64,
        /// Limit to one meeting (short id or full UUID).
        #[arg(long)]
        meeting: Option<String>,
        /// Maximum number of action threads.
        #[arg(long, default_value_t = 50)]
        limit: i64,
        /// Plain-text table instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// List people from meetings, or show one person's open work and decisions.
    People {
        /// Optional person id or name.
        person: Option<String>,
        /// Filter the list by a name substring.
        #[arg(long)]
        query: Option<String>,
        /// Maximum number of people to list.
        #[arg(long, default_value_t = 50)]
        limit: i64,
        /// Plain-text table instead of JSON (list only).
        #[arg(long)]
        table: bool,
    },
    /// Word search across the folders the user chose under Files: the text
    /// LokalBot read from documents, PDF pages and screenshots, and file names,
    /// best match first, with the passage that matched. Works without launching
    /// the app. Search by meaning stays in LokalBot's Ask.
    #[command(name = "search-files")]
    SearchFiles {
        /// Words to find.
        query: String,
        /// Only this kind: screenshot, image, pdf, doc, audio, or video. Repeatable.
        #[arg(long)]
        kind: Vec<String>,
        /// Only files dated on or after this local day (YYYY-MM-DD).
        #[arg(long)]
        after: Option<String>,
        /// Only files dated before this local day (YYYY-MM-DD).
        #[arg(long)]
        before: Option<String>,
        /// Maximum files (1–50).
        #[arg(long, default_value_t = files::DEFAULT_LIMIT)]
        limit: i64,
        /// Plain-text table instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// Word search across the notes the user's coding agents (Claude Code and
    /// Codex) saved for their own later sessions: project decisions, how-tos,
    /// preferences and pointers, best match first, with each note's text. Use
    /// it to find what another agent or an earlier session already learned. A
    /// note is an agent's record, not a verified fact. Works without launching
    /// the app.
    #[command(name = "search-notes")]
    SearchNotes {
        /// Words to find.
        query: String,
        /// Only this agent's notes: claude-code or codex.
        #[arg(long)]
        agent: Option<String>,
        /// Maximum notes (1–30).
        #[arg(long, default_value_t = notes::DEFAULT_LIMIT)]
        limit: i64,
        /// Plain-text table instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// Show what the user shared about themselves that is relevant to a task
    /// (chosen in the Personal Context settings).
    #[command(name = "personal-context")]
    PersonalContext {
        /// What you are helping with, in a sentence.
        #[arg(long)]
        task: String,
        /// Only this kind: fact, preference, goal, or principle. Repeatable.
        #[arg(long)]
        kind: Vec<String>,
        /// Maximum items (1–12).
        #[arg(long, default_value_t = 8)]
        limit: i64,
        /// Plain text instead of JSON.
        #[arg(long)]
        table: bool,
    },
    /// Print the on-disk path for a meeting or the library root.
    Path {
        /// Optional meeting ID. Omit to print the library root.
        id: Option<String>,
    },
    /// Set LokalBot up for the person, with their approval in the app.
    ///
    /// `setup start` asks the person, in LokalBot, to let this agent change
    /// settings; it is the only way to ask. The rest needs that access.
    Setup {
        #[command(subcommand)]
        command: control::SetupCommand,
    },
    /// Inspect and change LokalBot settings.
    ///
    /// schema, describe, and search read the built-in settings list and need no
    /// permission. list, get, set, reset, export, and import use the running
    /// app and need "Allow external agents to change LokalBot settings" in
    /// LokalBot → Settings → Privacy & Data. They start LokalBot in the
    /// background when it is not running; pass --no-launch to fail instead.
    /// Values use the tokens shown by describe. JSON by default. Changes that
    /// widen capture or sharing wait for the person's approval in LokalBot;
    /// request reports the answer.
    Config {
        #[command(subcommand)]
        command: control::ConfigCommand,
    },
    /// Save or remove API keys in the system credential store.
    ///
    /// Keys are never read back. Setting a key always waits for the person's
    /// approval in LokalBot, because a key decides whose account receives what
    /// LokalBot sends. Removing one applies right away.
    Secret {
        #[command(subcommand)]
        command: control::SecretCommand,
    },
    /// Check, choose, and download LokalBot's local models.
    ///
    /// Downloads take minutes: start one, then poll status until meetingReady
    /// is true.
    Models {
        #[command(subcommand)]
        command: Option<control::ModelsCommand>,
        #[command(flatten)]
        launch: control::LaunchOptions,
    },
    /// List what LokalBot needs from this computer and ask the person for it.
    Permissions {
        #[command(subcommand)]
        command: Option<control::PermissionsCommand>,
        #[command(flatten)]
        launch: control::LaunchOptions,
    },
    /// Show the running app's version, recording state, permissions, and agent access.
    ///
    /// Needs "Allow external agents to change LokalBot settings".
    Status {
        #[command(flatten)]
        launch: control::LaunchOptions,
    },
    /// Check whether LokalBot is ready, and list the next steps.
    ///
    /// Exits 1 while anything blocks a feature the person turned on.
    Doctor {
        #[command(flatten)]
        launch: control::LaunchOptions,
    },
    /// Restart LokalBot.
    ///
    /// Refused while LokalBot is recording. Waits up to 30 seconds for LokalBot
    /// to answer again.
    Restart {
        #[command(flatten)]
        launch: control::LaunchOptions,
    },
    /// Open LokalBot's Settings, optionally at one setting or section, for what
    /// only the person can do in the app, or a change they want to make
    /// themselves.
    Open {
        /// What to open. Only settings is supported.
        target: String,
        /// Optional setting key or section to show.
        key: Option<String>,
        #[command(flatten)]
        launch: control::LaunchOptions,
    },
    /// Serve the meeting library, and optionally screen memory, shared Personal Context, Files, and agent notes, over MCP.
    Mcp,
    /// Install the LokalBot skill and CLI link for coding agents.
    #[command(name = "install-skill")]
    InstallSkill {
        /// Copy the skill directories instead of symlinking.
        #[arg(long)]
        copy: bool,
        /// Remove everything install-skill created.
        #[arg(long)]
        uninstall: bool,
    },
}

/// A failure printed as `Error: <message>`: validation errors exit 64
/// (ArgumentParser's `ValidationError`), others 1.
#[derive(Debug)]
pub enum CliError {
    Validation(String),
    Failure(String),
    /// A stable error from the running app, printed as `[code] message`.
    Control(lokalbot_core::control::protocol::ControlError),
    /// Prints `stdout` and exits with `code`, for replies a script reads.
    Exit {
        code: i32,
        stdout: String,
    },
}

impl CliError {
    pub fn exit_code(&self) -> i32 {
        match self {
            CliError::Validation(_) => 64,
            CliError::Failure(_) | CliError::Control(_) => 1,
            CliError::Exit { code, .. } => *code,
        }
    }

    pub fn message(&self) -> String {
        match self {
            CliError::Validation(m) | CliError::Failure(m) => m.clone(),
            CliError::Control(error) => error.to_string(),
            CliError::Exit { .. } => String::new(),
        }
    }
}

impl From<anyhow::Error> for CliError {
    fn from(err: anyhow::Error) -> Self {
        CliError::Failure(format!("{err:#}"))
    }
}

fn validation(message: impl Into<String>) -> CliError {
    CliError::Validation(message.into())
}

/// A failure agents are told to recognise by its code: `[code] message`, as
/// the MCP tools, `ask` and the settings commands print it.
fn coded(code: mcp::ToolErrorCode, message: &str) -> CliError {
    CliError::Failure(format!("[{}] {message}", code.raw()))
}

fn require_meeting_access(paths: &LibraryPaths) -> Result<(), CliError> {
    if access::meetings_access_authorized(paths) {
        Ok(())
    } else {
        Err(coded(
            mcp::ToolErrorCode::AccessDisabled,
            access::MEETINGS_DISABLED_MESSAGE,
        ))
    }
}

fn day_or_error(value: &str, option: &str) -> Result<chrono::NaiveDate, CliError> {
    session::local_day(value).ok_or_else(|| {
        validation(format!(
            "{option} must be a real local day formatted YYYY-MM-DD, got '{value}'."
        ))
    })
}

/// Runs one command and returns what it prints on stdout.
pub fn run(cli: Cli) -> Result<String, CliError> {
    let paths = LibraryPaths::resolve(cli.storage_root.as_deref());
    let client = || control::Client::new(paths.clone(), cli.storage_root.clone());
    // Transcripts label microphone speech as the app does. A Mac library has
    // no settings file here, so it keeps the default.
    lokalbot_core::SpeakerAttribution::set_microphone_is_user(
        lokalbot_core::Settings::load(&paths.settings_file()).microphone_is_user,
    );
    match cli.command {
        Command::Brief => {
            let session = Session::open(paths)?;
            let authorized = access::meetings_access_authorized(&session.paths);
            Ok(briefing::render(
                &session,
                authorized,
                chrono::Utc::now(),
                briefing::Vocabulary::Cli,
            ))
        }
        Command::List {
            since,
            until,
            query,
            limit,
            include,
            table,
        } => {
            require_meeting_access(&paths)?;
            let since = since.map(|v| day_or_error(&v, "--since")).transpose()?;
            let until = until.map(|v| day_or_error(&v, "--until")).transpose()?;
            let include_summary = session::list_includes_summary(&include).map_err(|err| {
                validation(match err {
                    session::ListIncludeError::Transcript => "list doesn't include transcripts. Read one meeting's with `get <id> --include transcript`.".to_string(),
                    session::ListIncludeError::Unknown(values) => format!(
                        "Unknown --include value(s): {}. list takes summary.",
                        values.join(", ")
                    ),
                })
            })?;
            let maximum = if include_summary {
                session::MAXIMUM_SUMMARY_LIST_COUNT
            } else {
                MAXIMUM_MEETING_COUNT
            };
            if let Some(limit) = limit
                && !(1..=maximum as i64).contains(&limit)
            {
                return Err(validation(if include_summary {
                    format!("--limit must be between 1 and {maximum} with --include summary.")
                } else {
                    format!("--limit must be between 1 and {maximum}.")
                }));
            }
            let session = Session::open(paths)?;
            let mut meetings = session.meetings()?;
            if let Some(day) = since {
                let start = session::start_of_local_day(day);
                meetings.retain(|m| m.started_at >= start);
            }
            if let Some(day) = until {
                let end = session::day_bounds(day).1;
                meetings.retain(|m| m.started_at < end);
            }
            if let Some(query) = query {
                let needle = query.to_lowercase();
                meetings.retain(|m| m.title.to_lowercase().contains(&needle));
            }
            let limit = limit
                .map(|l| l as usize)
                .or(include_summary.then_some(session::DEFAULT_SUMMARY_LIST_COUNT));
            if let Some(limit) = limit {
                meetings.truncate(limit);
            }
            Ok(if table {
                session::list_table(&session, &meetings, include_summary)
            } else {
                session::list_json(&session, &meetings, include_summary)
            })
        }
        Command::Get {
            id,
            include,
            format,
        } => {
            require_meeting_access(&paths)?;
            let parts: Vec<String> = include
                .split(',')
                .map(|p| p.trim().to_lowercase())
                .filter(|p| !p.is_empty())
                .collect();
            let unknown: std::collections::BTreeSet<&String> = parts
                .iter()
                .filter(|p| !["metadata", "summary", "transcript"].contains(&p.as_str()))
                .collect();
            if parts.is_empty() || !unknown.is_empty() {
                let detail = unknown.into_iter().cloned().collect::<Vec<_>>().join(", ");
                return Err(validation(if detail.is_empty() {
                    "--include must contain metadata, summary, or transcript.".to_string()
                } else {
                    format!("Unknown --include value(s): {detail}.")
                }));
            }
            let options = GetOptions {
                include_summary: parts.iter().any(|p| p == "summary"),
                include_transcript: parts.iter().any(|p| p == "transcript"),
                include_metadata: parts.iter().any(|p| p == "metadata"),
                transcript_characters: None,
                transcript_from: None,
            };
            let format = format.to_lowercase();
            if format != "md" && format != "json" {
                return Err(validation(format!(
                    "Unknown format '{format}'. Use 'md' or 'json'."
                )));
            }
            let session = Session::open(paths)?;
            let meetings = session.meetings()?;
            let Some(meeting) = session.find(&id, &meetings) else {
                return Err(validation(format!(
                    "No meeting with id '{id}'. Run `list` to see available IDs."
                )));
            };
            Ok(if format == "md" {
                session::get_markdown(&session, &meeting, &options)
            } else {
                session::get_json(&session, &meeting, &options)
            })
        }
        Command::Search {
            query,
            limit,
            table,
        } => {
            require_meeting_access(&paths)?;
            let query = query.trim().to_string();
            if query.is_empty() {
                return Err(validation("Query must not be empty."));
            }
            if query.chars().count() > search::MAXIMUM_QUERY_CHARACTERS {
                return Err(validation(format!(
                    "Query must be at most {} characters.",
                    search::MAXIMUM_QUERY_CHARACTERS
                )));
            }
            if !(1..=search::MAXIMUM_SEARCH_HITS as i64).contains(&limit) {
                return Err(validation(format!(
                    "--limit must be between 1 and {}.",
                    search::MAXIMUM_SEARCH_HITS
                )));
            }
            let session = Session::open(paths)?;
            let meetings = session.meetings()?;
            let hits = search::hits(
                &session,
                &query,
                limit as usize,
                &meetings,
                Some(search::MAXIMUM_TRANSCRIPT_HITS_PER_MEETING),
                true,
            );
            Ok(if table {
                session::search_table(&hits)
            } else {
                session::search_json(&hits)
            })
        }
        Command::Ask { question, table } => {
            let session = Session::open(paths)?;
            print_ask_outcome(&ask::answer(&session, &question), table)
        }
        Command::Reply {
            message,
            instruction,
            table,
        } => {
            let text = match message {
                Some(message) => message,
                None => read_message_from_stdin()?,
            };
            let session = Session::open(paths)?;
            print_ask_outcome(
                &ask::draft_reply(&session, &text, instruction.as_deref()),
                table,
            )
        }
        Command::Setup { command } => control::run_setup(command, &client()),
        Command::Config { command } => control::run_config(command, &client()),
        Command::Secret { command } => control::run_secret(command, &client()),
        Command::Models { command, launch } => control::run_models(command, launch, &client()),
        Command::Permissions { command, launch } => {
            control::run_permissions(command, launch, &client())
        }
        Command::Status { launch } => control::run_status(&launch, &client()),
        Command::Doctor { launch } => control::run_doctor(&launch, &client()),
        Command::Restart { launch } => control::run_restart(&launch, &client()),
        Command::Open {
            target,
            key,
            launch,
        } => control::run_open(&target, key, &launch, &client()),
        Command::Actions {
            status,
            owner,
            days,
            meeting,
            limit,
            table,
        } => {
            require_meeting_access(&paths)?;
            let status = reports::StatusFilter::parse(&status).ok_or_else(|| {
                validation("--status must be one of all, active, open, deferred, or done.")
            })?;
            if !(1..=i64::from(reports::MAXIMUM_DAYS)).contains(&days) {
                return Err(validation(format!(
                    "--days must be between 1 and {}.",
                    reports::MAXIMUM_DAYS
                )));
            }
            if !(1..=reports::MAXIMUM_ENTRIES as i64).contains(&limit) {
                return Err(validation(format!(
                    "--limit must be between 1 and {}.",
                    reports::MAXIMUM_ENTRIES
                )));
            }
            let session = Session::open(paths)?;
            let meetings = session.meetings()?;
            let mut filter = reports::ActionFilter {
                status,
                days: days as u32,
                owner: reports::OwnerFilter::parse(owner.as_deref()),
                meeting_id: None,
                limit: limit as usize,
            };
            if let Some(reference) = meeting {
                let Some(found) = session.find(&reference, &meetings) else {
                    return Err(validation(format!("No meeting matches \"{reference}\".")));
                };
                filter.meeting_id = Some(found.id);
            }
            let entries = reports::action_entries(&session, &meetings, &filter, chrono::Utc::now());
            Ok(if table {
                reports::actions_table(&entries)
            } else {
                reports::actions_json(&entries)
            })
        }
        Command::People {
            person,
            query,
            limit,
            table,
        } => {
            require_meeting_access(&paths)?;
            if !(1..=reports::MAXIMUM_ENTRIES as i64).contains(&limit) {
                return Err(validation(format!(
                    "--limit must be between 1 and {}.",
                    reports::MAXIMUM_ENTRIES
                )));
            }
            let session = Session::open(paths)?;
            let people = session.library.people()?;
            if let Some(person) = person {
                let Some(found) = reports::find_person(&person, &people) else {
                    return Err(validation(format!(
                        "No single person matches \"{person}\". Run `people --query` to list candidates."
                    )));
                };
                return Ok(json::pretty(
                    &reports::person_detail(found, chrono::Utc::now()),
                    true,
                ));
            }
            let summaries = reports::person_summaries(&people, query.as_deref(), limit as usize);
            Ok(if table {
                reports::people_table(&summaries)
            } else {
                json::pretty(&summaries, true)
            })
        }
        Command::SearchFiles {
            query,
            kind,
            after,
            before,
            limit,
            table,
        } => {
            let kinds = (!kind.is_empty()).then_some(kind);
            match files::report(
                &paths,
                &query,
                kinds.as_deref(),
                after.as_deref(),
                before.as_deref(),
                Some(limit),
            ) {
                Ok(report) if table => Ok(files::table(&report)),
                Ok(report) => Ok(json::pretty(&report, false)),
                Err(files::Failure::Invalid(message)) => Err(validation(message)),
                Err(failure @ files::Failure::Disabled) => Err(coded(
                    mcp::ToolErrorCode::FilesAccessDisabled,
                    &failure.message(),
                )),
                Err(failure @ files::Failure::Unavailable) => Err(coded(
                    mcp::ToolErrorCode::FilesUnavailable,
                    &failure.message(),
                )),
            }
        }
        Command::SearchNotes {
            query,
            agent,
            limit,
            table,
        } => match notes::report(&paths, &query, agent.as_deref(), Some(limit)) {
            Ok(report) if table => Ok(notes::table(&report)),
            Ok(report) => Ok(json::pretty(&report, false)),
            Err(notes::Failure::Invalid(message)) => Err(validation(message)),
            // A switch that is off prints its code, as the MCP tools do.
            Err(failure @ notes::Failure::Disabled) => Err(coded(
                mcp::ToolErrorCode::AgentNotesAccessDisabled,
                &failure.message(),
            )),
            Err(failure @ notes::Failure::Unavailable) => Err(coded(
                mcp::ToolErrorCode::AgentNotesUnavailable,
                &failure.message(),
            )),
        },
        Command::PersonalContext {
            task,
            kind,
            limit,
            table,
        } => {
            let kinds = (!kind.is_empty()).then_some(kind);
            match personal::report(&paths, &task, kinds.as_deref(), Some(limit)) {
                Ok(report) if table => {
                    if report.items.is_empty() {
                        return Ok(
                            "Nothing shared matches. Items not listed are unknown, not false."
                                .into(),
                        );
                    }
                    Ok(report
                        .items
                        .iter()
                        .map(|i| format!("{}\t{}\t{}", i.kind, i.as_of, i.text))
                        .collect::<Vec<_>>()
                        .join("\n"))
                }
                Ok(report) => Ok(json::pretty(&report, false)),
                Err(personal::Failure::Invalid(message)) => Err(validation(message)),
                Err(failure @ personal::Failure::Disabled) => Err(coded(
                    mcp::ToolErrorCode::PersonalContextDisabled,
                    &failure.message(),
                )),
                Err(failure @ personal::Failure::Unavailable) => Err(coded(
                    mcp::ToolErrorCode::PersonalContextUnavailable,
                    &failure.message(),
                )),
            }
        }
        Command::Path { id } => {
            require_meeting_access(&paths)?;
            let Some(id) = id else {
                return Ok(paths.root().display().to_string());
            };
            let session = Session::open(paths)?;
            let meetings = session.meetings()?;
            let meeting = session
                .find(&id, &meetings)
                .ok_or_else(|| validation(format!("No meeting with id '{id}'.")))?;
            Ok(session.folder(&meeting).display().to_string())
        }
        Command::Mcp => {
            let provider = mcp::Provider {
                session: Session::open(paths)?,
                now: None,
            };
            mcp::serve(&provider, SERVER_VERSION)?;
            Ok(String::new())
        }
        Command::InstallSkill { copy, uninstall } => {
            let installer = install::Installer::for_current_user()?;
            if uninstall {
                installer.uninstall()?;
                return Ok("Removed the lokalbot-cli symlinks and skill installs.".into());
            }
            installer.install(copy)?;
            Ok(installer.installed_message())
        }
    }
}

/// Prints JSON or text on standard output; failures exit with status 1 so
/// scripts notice, after the JSON that says why.
fn print_ask_outcome(outcome: &ask::Outcome, table: bool) -> Result<String, CliError> {
    if table {
        let text = outcome.tool_result().text;
        if outcome.is_failure() {
            return Err(CliError::Failure(text));
        }
        return Ok(text);
    }
    let json = outcome.json();
    if outcome.is_failure() {
        return Err(CliError::Exit {
            code: 1,
            stdout: json,
        });
    }
    Ok(json)
}

fn read_message_from_stdin() -> Result<String, CliError> {
    use std::io::Read as _;
    // The engine checks the character limit; this only bounds memory.
    let limit = ask::MAXIMUM_QUESTION_CHARACTERS * 4;
    let mut data = Vec::new();
    std::io::stdin()
        .take(limit as u64 + 1)
        .read_to_end(&mut data)
        .map_err(|err| CliError::Failure(err.to_string()))?;
    if data.len() > limit {
        return Err(validation(format!(
            "The message is limited to {} characters.",
            ask::MAXIMUM_QUESTION_CHARACTERS
        )));
    }
    Ok(String::from_utf8_lossy(&data).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::error::ErrorKind;

    #[test]
    fn control_commands_parse_like_the_mac() {
        for args in [
            vec!["config", "schema"],
            vec!["config", "describe", "autoRecordMode"],
            vec!["config", "search", "dark", "mode", "--table"],
            vec![
                "config",
                "list",
                "--category",
                "general",
                "--changed",
                "--no-launch",
            ],
            vec!["config", "get", "appTheme", "--value"],
            vec![
                "config",
                "set",
                "appTheme=dark",
                "--dry-run",
                "--wait",
                "120",
            ],
            vec!["config", "reset", "appTheme", "--launch-timeout", "5"],
            vec!["config", "export", "--changed"],
            vec!["config", "import", "settings.json", "--dry-run"],
            vec!["config", "request", "ID", "--wait", "120"],
            vec!["secret", "list"],
            vec!["secret", "set", "openai-compatible", "--wait", "120"],
            vec!["secret", "clear", "openai-compatible"],
            vec![
                "setup",
                "start",
                "--meeting-library",
                "--screen-memory",
                "--wait",
                "300",
            ],
            vec!["setup", "plan", "--preset", "lightweight"],
            vec!["setup", "apply", "plan.json", "--wait", "300"],
            vec!["setup", "finish"],
            vec!["setup", "launch-at-login", "on"],
            vec!["models"],
            vec!["models", "--no-launch"],
            vec!["permissions", "--no-launch"],
            vec!["models", "status"],
            vec!["models", "preset", "recommended"],
            vec!["models", "download"],
            vec!["models", "cancel"],
            vec!["permissions"],
            vec!["permissions", "list"],
            vec!["permissions", "request", "microphone"],
            vec!["status"],
            vec!["doctor"],
            vec!["restart"],
            vec!["open", "settings", "dictationShortcut"],
            vec!["ask", "what did we decide?", "--table"],
            vec!["reply", "--instruction", "decline politely"],
        ] {
            let mut full = vec!["lokalbot-cli"];
            full.extend(args.iter().copied());
            Cli::try_parse_from(&full).unwrap_or_else(|err| panic!("{args:?}: {err}"));
        }
        // A key is never an argument.
        assert!(
            Cli::try_parse_from([
                "lokalbot-cli",
                "secret",
                "set",
                "openai-compatible",
                "sk-key"
            ])
            .is_err()
        );
    }

    #[test]
    fn schema_needs_no_permission() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_str().unwrap();
        let parse = |args: &[&str]| {
            let mut full = vec!["lokalbot-cli", "--lokalbot-storage-root", root];
            full.extend_from_slice(args);
            Cli::try_parse_from(full).unwrap()
        };
        assert!(
            run(parse(&["config", "schema"]))
                .unwrap()
                .contains("autoRecordMode")
        );
        let err = run(parse(&["config", "get", "appTheme"])).unwrap_err();
        assert_eq!(err.exit_code(), 1);
        assert!(
            err.message().starts_with("[settings_access_disabled]"),
            "{}",
            err.message()
        );
        // An unknown key suggests a real one before reaching the app.
        let err = run(parse(&["config", "describe", "theme"])).unwrap_err();
        assert_eq!(err.exit_code(), 64);
        assert!(err.message().contains("appTheme"), "{}", err.message());
    }

    #[test]
    fn version_flags_print_the_version_and_a_command_stays_required() {
        for flag in ["--version", "-V"] {
            let err = Cli::try_parse_from(["lokalbot-cli", flag]).unwrap_err();
            assert_eq!(err.kind(), ErrorKind::DisplayVersion);
            assert_eq!(err.exit_code(), 0);
            assert_eq!(err.to_string(), format!("lokalbot-cli {SERVER_VERSION}\n"));
        }
        let err = Cli::try_parse_from(["lokalbot-cli"]).unwrap_err();
        assert_eq!(
            err.kind(),
            ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand
        );
        assert_eq!(err.exit_code(), 2);
        let err = Cli::try_parse_from(["lokalbot-cli", "--lokalbot-storage-root", "/tmp/library"])
            .unwrap_err();
        assert_eq!(err.kind(), ErrorKind::MissingSubcommand);
        assert!(Cli::try_parse_from(["lokalbot-cli", "list", "--version"]).is_err());
    }
}
