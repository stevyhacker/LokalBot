//! `lokalbot-cli`: read-only access to the LokalBot library and a stdio MCP
//! server, with the commands, output and errors of the macOS helper
//! (`CLI/`, `LokalBot/CLISupport/`). It opens the library read-only and never
//! writes into `meetings/`.

pub mod ask;
pub mod briefing;
pub mod install;
pub mod json;
pub mod mcp;
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
    about = "Read-only access to your local LokalBot meeting library.",
    long_about = "Read-only access to your local LokalBot meeting library.\n\nIntended for coding agents (Claude Code, Codex CLI, Cursor, Gemini) and humans alike. `install-skill` links the CLI into your PATH. Output defaults to JSON; pass --table for plain text."
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
    /// Show what the user shared about themselves that is relevant to a task
    /// (written in the Mac app; read from a library that came from a Mac).
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
    /// Serve the meeting library and optional screen memory over MCP.
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
}

impl CliError {
    pub fn exit_code(&self) -> i32 {
        match self {
            CliError::Validation(_) => 64,
            CliError::Failure(_) => 1,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            CliError::Validation(m) | CliError::Failure(m) => m,
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

fn require_meeting_access(paths: &LibraryPaths) -> Result<(), CliError> {
    if access::meetings_access_authorized(paths) {
        Ok(())
    } else {
        Err(CliError::Failure(access::MEETINGS_DISABLED_MESSAGE.into()))
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
                Err(failure) => Err(CliError::Failure(failure.message())),
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

#[cfg(test)]
mod tests {
    use super::*;
    use clap::error::ErrorKind;

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
