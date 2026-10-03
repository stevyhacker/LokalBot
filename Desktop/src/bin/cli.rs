use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand};
use lokalbot_desktop::{
    agent, audio,
    domain::*,
    fixtures, privacy, services,
    storage::{Library, default_root},
};
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, Write},
    path::PathBuf,
};

#[derive(Parser)]
#[command(
    version,
    about = "LokalBot's native desktop services and consent-gated read-only MCP"
)]
struct Args {
    #[arg(long, env = "LOKALBOT_STORAGE_ROOT")]
    root: Option<PathBuf>,
    #[command(subcommand)]
    command: CliCommand,
}
#[derive(Subcommand)]
enum CliCommand {
    Seed,
    Import {
        file: PathBuf,
        #[arg(long)]
        title: Option<String>,
    },
    ImportAudio {
        file: PathBuf,
        #[arg(long)]
        title: Option<String>,
    },
    Summarize {
        id: String,
    },
    Transcribe {
        id: String,
    },
    Ask {
        question: String,
    },
    Digest {
        #[arg(long)]
        day: Option<String>,
    },
    List,
    Get {
        id: String,
    },
    Search {
        query: String,
    },
    Screen,
    Note {
        id: String,
        text: String,
    },
    ToggleAction {
        id: String,
        action_id: String,
    },
    CorrectAction {
        id: String,
        action_id: String,
        text: String,
        #[arg(long, default_value = "Unassigned")]
        owner: String,
        #[arg(long, default_value = "")]
        due: String,
    },
    Delete {
        id: String,
    },
    Export {
        id: String,
        file: PathBuf,
    },
    Configure {
        #[arg(long)]
        openrouter: bool,
        #[arg(long)]
        local_endpoint: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        approve_origin: bool,
        #[arg(long)]
        revoke_origin: bool,
        #[arg(long)]
        meeting_access: Option<bool>,
        #[arg(long)]
        screen_access: Option<bool>,
        #[arg(long)]
        screen_text: Option<bool>,
        #[arg(long)]
        pixels: Option<bool>,
        #[arg(long)]
        remote_audio: Option<bool>,
        #[arg(long)]
        account_policy: Option<bool>,
        #[arg(long)]
        whisper: Option<String>,
        #[arg(long)]
        whisper_model: Option<String>,
        #[arg(long)]
        agent_workspace: Option<String>,
        #[arg(long)]
        agent_enabled: Option<bool>,
        #[arg(long)]
        retention_days: Option<u32>,
        #[arg(long)]
        excluded_apps: Option<String>,
        #[arg(long)]
        excluded_domains: Option<String>,
        #[arg(long)]
        screen_days: Option<u32>,
    },
    Record {
        #[arg(long, default_value = "New meeting")]
        title: String,
        #[arg(long, default_value_t = 30)]
        seconds: u64,
    },
    CaptureScreen,
    Health,
    Recover,
    Mcp,
    Agent {
        prompt: String,
    },
    Eval {
        #[arg(long)]
        live: bool,
    },
}
fn emit(value: impl serde::Serialize) -> Result<()> {
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{}", privacy::redact(&error.to_string()));
        std::process::exit(1);
    }
}
fn run() -> Result<()> {
    let args = Args::parse();
    let mut library = Library::open(args.root.map(Ok).unwrap_or_else(default_root)?)?;
    match args.command {
        CliCommand::Seed => emit(fixtures::seed(&mut library)?),
        CliCommand::Import { file, title } => {
            emit(services::import_transcript(&mut library, &file, title)?)
        }
        CliCommand::ImportAudio { file, title } => {
            emit(audio::import_audio(&mut library, &file, title)?)
        }
        CliCommand::Summarize { id } => emit(services::summarize(&mut library, &id)?),
        CliCommand::Transcribe { id } => {
            services::transcribe_meeting(&mut library, &id)?;
            emit(library.meeting(&id)?)
        }
        CliCommand::Ask { question } => emit(services::ask(&library, &question)?),
        CliCommand::Digest { day } => emit(services::digest(
            &library,
            &day.unwrap_or_else(services::today),
        )?),
        CliCommand::List => emit(public_meetings(&library)?),
        CliCommand::Get { id } => {
            ensure!(
                library.settings()?.meeting_access,
                "Meeting-library access is disabled"
            );
            emit(public_meeting(library.meeting(&id)?))
        }
        CliCommand::Search { query } => {
            ensure!(
                library.settings()?.meeting_access,
                "Meeting-library access is disabled"
            );
            emit(
                library
                    .search(&query, 30)?
                    .into_iter()
                    .filter(|e| e.meeting_id.is_some())
                    .collect::<Vec<_>>(),
            )
        }
        CliCommand::Screen => emit(library.external_moments(now())?),
        CliCommand::Note { id, text } => {
            let mut m = library.meeting(&id)?;
            m.notes = text;
            library.save_meeting(&m)?;
            emit("Notes saved")
        }
        CliCommand::ToggleAction { id, action_id } => {
            library.toggle_action(&id, &action_id)?;
            emit("Action saved")
        }
        CliCommand::CorrectAction {
            id,
            action_id,
            text,
            owner,
            due,
        } => {
            library.correct_action(&id, &action_id, text, owner, due)?;
            emit("Action correction saved")
        }
        CliCommand::Delete { id } => {
            library.delete_meeting(&id)?;
            emit("Meeting deleted")
        }
        CliCommand::Export { id, file } => {
            library.export_meeting(&id, &file)?;
            emit("Meeting exported")
        }
        CliCommand::Configure {
            openrouter,
            local_endpoint,
            model,
            approve_origin,
            revoke_origin,
            meeting_access,
            screen_access,
            screen_text,
            pixels,
            remote_audio,
            account_policy,
            whisper,
            whisper_model,
            agent_workspace,
            agent_enabled,
            retention_days,
            excluded_apps,
            excluded_domains,
            screen_days,
        } => {
            let mut s = library.settings()?;
            if openrouter {
                s.backend = Backend::OpenRouter;
                s.endpoint = "https://openrouter.ai/api/v1".into();
            }
            if let Some(endpoint) = local_endpoint {
                s.backend = Backend::Local;
                s.endpoint = endpoint;
            }
            if let Some(model) = model {
                s.model = model;
            }
            let origin = privacy::origin(&s.endpoint)?;
            if approve_origin && !s.approved_origins.contains(&origin) {
                s.approved_origins.push(origin.clone());
            }
            if revoke_origin {
                s.approved_origins.retain(|o| o != &origin);
            }
            if let Some(value) = meeting_access {
                s.meeting_access = value;
            }
            if let Some(value) = screen_access {
                s.screen_access = value;
            }
            if let Some(value) = screen_text {
                s.screen_text_enabled = value;
            }
            if let Some(value) = pixels {
                s.pixels_enabled = value;
            }
            if let Some(value) = remote_audio {
                s.remote_audio = value;
            }
            if let Some(value) = account_policy {
                s.account_data_policy = value;
            }
            if let Some(value) = whisper {
                s.whisper_executable = value;
            }
            if let Some(value) = whisper_model {
                s.whisper_model = value;
            }
            if let Some(value) = agent_workspace {
                s.agent_workspace = value;
            }
            if let Some(value) = agent_enabled {
                s.agent_enabled = value;
            }
            if let Some(days) = retention_days {
                s.retention_days = days;
            }
            if let Some(apps) = excluded_apps {
                s.excluded_apps = apps
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .collect();
            }
            if let Some(domains) = excluded_domains {
                s.excluded_domains = domains
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_owned)
                    .collect();
            }
            if let Some(days) = screen_days {
                s.screen_access_days = Some(days);
            }
            library.save_settings(&mut s)?;
            emit(s)
        }
        CliCommand::Record { title, seconds } => {
            ensure!(
                (1..=86400).contains(&seconds),
                "Recording length must be 1–86400 seconds"
            );
            let recording = audio::Recording::start(&mut library, &title)?;
            std::thread::sleep(std::time::Duration::from_secs(seconds));
            emit(recording.finish(&mut library)?)
        }
        CliCommand::CaptureScreen => {
            emit(lokalbot_desktop::platform::capture_screen(&mut library)?)
        }
        CliCommand::Health => {
            library.expire(now())?;
            emit(
                json!({"meetings":library.meetings()?.len(),"moments":library.moments()?.len(),"jobs":library.jobs()?,"generations":library.generations()?,"local_whisper_configured":!library.settings()?.whisper_model.is_empty()}),
            )
        }
        CliCommand::Recover => {
            let jobs = library.recover_jobs()?;
            let recordings = audio::recover_recordings(&mut library)?;
            emit(json!({"jobs":jobs,"recordings":recordings}))
        }
        CliCommand::Agent { prompt } => emit(agent::plan(&library, &prompt)?),
        CliCommand::Mcp => mcp(&library),
        CliCommand::Eval { live } => evaluate(&mut library, live),
    }
}
fn public_meeting(mut m: Meeting) -> Meeting {
    m.media.clear();
    m
}
fn public_meetings(library: &Library) -> Result<Vec<Meeting>> {
    Ok(library
        .external_meetings()?
        .into_iter()
        .map(public_meeting)
        .collect())
}
fn mcp(library: &Library) -> Result<()> {
    for line in io::stdin().lock().lines() {
        let request: Value = match serde_json::from_str(&line?) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let Some(id) = request.get("id") else {
            continue;
        };
        let result: Result<Value> = match request["method"].as_str() {
            Some("initialize") => Ok(
                json!({"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"lokalbot-desktop","version":env!("CARGO_PKG_VERSION")}}),
            ),
            Some("ping") => Ok(json!({})),
            Some("tools/list") => Ok(
                json!({"tools":[{"name":"list_meetings","description":"Consent-gated meeting list","inputSchema":{"type":"object","properties":{}}},{"name":"get_meeting","description":"Read a meeting without audio file paths","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}},{"name":"search_meetings","description":"Search meeting evidence","inputSchema":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}},{"name":"list_screen_memory","description":"Separately consent-gated retained text, never pixel paths","inputSchema":{"type":"object","properties":{}}}]}),
            ),
            Some("tools/call") => (|| {
                let name = request["params"]["name"]
                    .as_str()
                    .context("Tool name is missing")?;
                let args = &request["params"]["arguments"];
                let value = match name {
                    "list_meetings" => serde_json::to_value(public_meetings(library)?)?,
                    "get_meeting" => {
                        ensure!(
                            library.settings()?.meeting_access,
                            "Meeting-library access is disabled"
                        );
                        serde_json::to_value(public_meeting(
                            library.meeting(args["id"].as_str().context("ID is missing")?)?,
                        ))?
                    }
                    "search_meetings" => {
                        ensure!(
                            library.settings()?.meeting_access,
                            "Meeting-library access is disabled"
                        );
                        serde_json::to_value(
                            library
                                .search(args["query"].as_str().context("Query is missing")?, 30)?
                                .into_iter()
                                .filter(|e| e.meeting_id.is_some())
                                .collect::<Vec<_>>(),
                        )?
                    }
                    "list_screen_memory" => serde_json::to_value(library.external_moments(now())?)?,
                    _ => anyhow::bail!("Unknown read-only tool"),
                };
                Ok(json!({"content":[{"type":"text","text":serde_json::to_string(&value)?}]}))
            })(),
            _ => Err(anyhow::anyhow!("Unknown JSON-RPC method")),
        };
        let response = match result {
            Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
            Err(error) => {
                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32000,"message":privacy::redact(&error.to_string())}})
            }
        };
        println!("{response}");
        io::stdout().flush()?;
    }
    Ok(())
}
fn evaluate(library: &mut Library, live: bool) -> Result<()> {
    ensure!(
        library.root.join(".synthetic-fixture").is_file(),
        "Evaluation requires an explicitly seeded synthetic library"
    );
    let meetings = library.meetings()?;
    ensure!(
        meetings.len() == 3
            && meetings
                .iter()
                .all(|m| m.notes.contains("Synthetic test meeting")),
        "Evaluation refuses a library with non-fixture meetings"
    );
    let mut checks = vec![];
    ensure!(
        !library.search("microphone", 10)?.is_empty(),
        "Search lost fixture evidence"
    );
    checks.push("FTS search");
    let first = &meetings[0];
    let mut edited = first.clone();
    edited.notes = "Synthetic note survives restart".into();
    library.save_meeting(&edited)?;
    ensure!(
        Library::open(&library.root)?.meeting(&first.id)?.notes == edited.notes,
        "Notes failed restart persistence"
    );
    checks.push("note persistence");
    if live {
        for meeting in &meetings {
            let s = services::summarize(library, &meeting.id)?;
            ensure!(!s.overview.is_empty(), "Summary is empty");
        }
        checks.push("live structured summaries");
        let answer = services::ask(
            library,
            "Who will test microphone recording on Ubuntu, and when?",
        )?;
        ensure!(
            answer.answer.text.to_lowercase().contains("alex")
                && answer.answer.text.to_lowercase().contains("monday")
                && !answer.answer.sources.is_empty(),
            "Grounded answer missed the fixture owner/deadline"
        );
        checks.push("live grounded Ask");
        let unanswerable = services::ask(library, "What is the approved Windows release date?")?;
        ensure!(
            !unanswerable.answer.text.is_empty(),
            "Unanswerable question has no response"
        );
        checks.push("live uncertainty answer");
        let digest = services::digest(library, &services::today())?;
        ensure!(!digest.text.is_empty(), "Digest is empty");
        checks.push("live day digest");
        let m = library
            .meetings()?
            .into_iter()
            .find(|m| m.summary.as_ref().is_some_and(|s| !s.actions.is_empty()))
            .context("No generated actions")?;
        let id = m.summary.as_ref().unwrap().actions[0].id.clone();
        library.toggle_action(&m.id, &id)?;
        ensure!(
            library
                .meeting(&m.id)?
                .summary
                .unwrap()
                .actions
                .iter()
                .find(|a| a.id == id)
                .unwrap()
                .done,
            "Action failed persistence"
        );
        checks.push("generated action completion");
    }
    emit(json!({"passed":checks,"generations":library.generations()?,"synthetic_only":true}))
}
