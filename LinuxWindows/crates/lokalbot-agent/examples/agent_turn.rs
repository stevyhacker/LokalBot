//! One Agent Mode turn against the real runtime and model, without the UI
//! (`LokalBot --agent` on macOS). Drives the same task list and session code
//! the Agent page uses, answers each approval card from the command line, and
//! checks the result.
//!
//! ```text
//! agent_turn <library> --workspace <dir> [--install] [--download-model]
//!            [--approve | --deny] [--expect-file <path> [--expect-text <text>]]
//!            [--expect-missing <path>] [--cli <dir>] [--powershell]
//!            [--timeout <seconds>] <prompt>
//! ```
//!
//! `--install` sets up Bun and pi in `<library>/runtimes/agent-runtime`;
//! `--download-model` fetches the built-in Think model and llama.cpp runtime
//! named by `<library>/settings.json` when they are missing. `--powershell`
//! gives the agent pi's PowerShell tool, as on Windows without Bash.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, bail};
use parking_lot::RwLock;

use lokalbot_agent::session::SessionState;
use lokalbot_agent::{
    AgentDirectories, AgentEnvironment, ApprovalScope, InstallPhase, Installer, PiLauncher,
    RuntimeLayout, RuntimeManifest, TaskList, TranscriptItem,
};
use lokalbot_core::{Library, LibraryPaths, Settings};

#[derive(Default)]
struct Options {
    library: PathBuf,
    workspace: Option<PathBuf>,
    install: bool,
    download_model: bool,
    approve: Option<bool>,
    expect_file: Option<PathBuf>,
    expect_text: Option<String>,
    expect_missing: Option<PathBuf>,
    cli: Option<PathBuf>,
    powershell: bool,
    timeout: u64,
    prompt: String,
}

fn parse() -> Result<Options> {
    let mut args = std::env::args().skip(1);
    let mut options = Options {
        timeout: 900,
        ..Default::default()
    };
    let mut positional = Vec::new();
    while let Some(arg) = args.next() {
        let mut value = || args.next().context("missing value");
        match arg.as_str() {
            "--workspace" => options.workspace = Some(value()?.into()),
            "--install" => options.install = true,
            "--download-model" => options.download_model = true,
            "--approve" => options.approve = Some(true),
            "--deny" => options.approve = Some(false),
            "--expect-file" => options.expect_file = Some(value()?.into()),
            "--expect-text" => options.expect_text = Some(value()?),
            "--expect-missing" => options.expect_missing = Some(value()?.into()),
            "--cli" => options.cli = Some(value()?.into()),
            "--powershell" => options.powershell = true,
            "--timeout" => options.timeout = value()?.parse()?,
            _ => positional.push(arg),
        }
    }
    if positional.len() != 2 {
        bail!("usage: agent_turn <library> --workspace <dir> [options] <prompt>");
    }
    options.library = positional.remove(0).into();
    options.prompt = positional.remove(0);
    Ok(options)
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let options = parse()?;
    let paths = LibraryPaths::new(&options.library);
    let library = Library::open(paths.clone())?;
    let settings = Settings::load(&paths.settings_file());
    let layout = RuntimeLayout::for_library(&paths);
    let manifest = RuntimeManifest::current();
    let cancel = AtomicBool::new(false);

    if options.install {
        let installer = Installer::new(layout.clone(), manifest.clone());
        let started = Instant::now();
        let mut last = String::new();
        installer.install(false, &cancel, &mut |phase| {
            let line = match &phase {
                InstallPhase::Downloading { name, progress } => format!(
                    "downloading {name} {}%",
                    progress
                        .map(|p| (p * 10.0).floor() as u32 * 10)
                        .unwrap_or(0)
                ),
                other => format!("{other:?}"),
            };
            if line != last {
                println!("setup: {line}");
                last = line;
            }
        })?;
        println!("setup: done in {:.1} s", started.elapsed().as_secs_f64());
    }
    anyhow::ensure!(
        layout.is_integrity_valid(&manifest),
        "the Agent runtime is not installed (pass --install)"
    );

    let runtime = lokalbot_ai::RuntimeManager::new(paths.clone(), &settings);
    if options.download_model {
        let entry = lokalbot_ai::catalog::entry(&settings.built_in_model_id)
            .context("unknown built-in model")?;
        if !lokalbot_ai::catalog::is_downloaded(&paths, entry) {
            println!("model: downloading {}", entry.display_name);
            let mut tenth = 0;
            lokalbot_ai::download(
                &lokalbot_ai::catalog::download_spec(&paths, entry),
                &cancel,
                &mut |done, total| {
                    let now = (done * 10).checked_div(total).unwrap_or(0);
                    if now != tenth {
                        tenth = now;
                        println!("model: {}%", now * 10);
                    }
                },
            )?;
        }
        runtime.ensure_runtime(&settings, &cancel, &mut |_, _| {})?;
    }

    let dirs = AgentDirectories::new(&paths);
    let launcher = PiLauncher {
        paths: paths.clone(),
        dirs: dirs.clone(),
        layout: layout.clone(),
        manifest: manifest.clone(),
        runtime: Some(runtime.clone()),
        api_key: Arc::new(|| None),
        // Without the app's credential store, a plan task reports that the
        // sign-in can't be read.
        chatgpt_account: lokalbot_ai::plans::chatgpt::shared(),
        helpers_dir: options.cli.clone().or_else(PiLauncher::bundled_helpers_dir),
        shell: options
            .powershell
            .then_some(lokalbot_agent::shell::ShellChoice::PowerShell),
    };
    lokalbot_agent::process::stop_leftovers(&dirs.process_markers());
    let env = Arc::new(AgentEnvironment {
        library,
        dirs,
        layout,
        settings: Arc::new(RwLock::new(settings)),
        launcher: Arc::new(launcher),
    });
    let (tx, rx) = async_channel::bounded(4096);
    let mut list = TaskList::new(env, tx);
    let id = list.add_session();
    {
        let session = list.session_mut(id).context("new task")?;
        if let Some(workspace) = &options.workspace {
            std::fs::create_dir_all(workspace)?;
            session.workspace = dunce::canonicalize(workspace)?;
        }
        println!("workspace: {}", session.workspace.display());
        session.draft = options.prompt.clone();
    }
    let started = Instant::now();
    list.submit(id, false);
    if let Some(error) = list.error.take() {
        bail!("could not start: {error}");
    }

    let deadline = Instant::now() + Duration::from_secs(options.timeout);
    let mut printed: HashMap<String, String> = HashMap::new();
    let mut saw_running = false;
    let mut approvals = 0usize;
    let outcome = loop {
        if Instant::now() > deadline {
            break Err(anyhow::anyhow!("timed out after {} s", options.timeout));
        }
        let mut handled = false;
        while let Ok(input) = rx.try_recv() {
            list.handle(input);
            handled = true;
        }
        if !handled {
            std::thread::sleep(Duration::from_millis(20));
            continue;
        }
        let tab = list.tab(id).context("task")?;
        let session = &tab.session;
        for item in session.items() {
            report(item, &mut printed);
        }
        let pending: Vec<_> = session
            .pending_approvals()
            .into_iter()
            .map(|r| (*r).clone())
            .collect();
        if let Some(request) = pending.first() {
            approvals += 1;
            println!(
                "approval: {} path={} command={} content={:?}",
                request.tool,
                request.path.as_deref().unwrap_or("-"),
                request.command.as_deref().unwrap_or("-"),
                request
                    .content
                    .as_deref()
                    .map(|c| c.chars().take(80).collect::<String>())
            );
            let approve = options.approve.unwrap_or(false);
            if let Some(path) = &options.expect_file
                && path.exists()
            {
                bail!("{} exists before the approval was answered", path.display());
            }
            println!("approval: {}", if approve { "Allow Once" } else { "Deny" });
            let session = list.session_mut(id).context("task")?;
            session.respond_to_approval(&request.id, approve, ApprovalScope::Once);
            continue;
        }
        if session.items().iter().any(|i| {
            matches!(
                i,
                TranscriptItem::Assistant { .. } | TranscriptItem::Tool { .. }
            )
        }) {
            saw_running = true;
        }
        match &session.state {
            SessionState::Running => saw_running = true,
            SessionState::Ready if saw_running && !session.is_sending => break Ok(()),
            SessionState::Failed(message) => break Err(anyhow::anyhow!("task failed: {message}")),
            _ => {}
        }
    };
    let elapsed = started.elapsed().as_secs_f64();
    let session_file = list
        .tab(id)
        .and_then(|t| t.session.active_session_file.clone());
    list.persist();
    list.shutdown_all(lokalbot_agent::process::STOP_GRACE);
    drop(list);
    runtime.shutdown();
    outcome?;

    println!("turn: settled in {elapsed:.1} s with {approvals} approval card(s)");
    if let Some(file) = &session_file {
        println!("session file: {}", file.display());
        anyhow::ensure!(file.is_file(), "pi did not save the session");
    }
    if let Some(path) = &options.expect_file {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("{} was not created", path.display()))?;
        if let Some(expected) = &options.expect_text {
            anyhow::ensure!(
                text.contains(expected.as_str()),
                "{} does not contain {expected:?}: {text:?}",
                path.display()
            );
        }
        println!("check: {} exists ({} bytes)", path.display(), text.len());
    }
    if let Some(path) = &options.expect_missing {
        anyhow::ensure!(
            !path.exists(),
            "{} exists although it was denied",
            path.display()
        );
        println!("check: {} does not exist", path.display());
    }
    println!("result: ok");
    Ok(())
}

/// Prints each item once it reaches a final state.
fn report(item: &TranscriptItem, printed: &mut HashMap<String, String>) {
    let line = match item {
        TranscriptItem::User { text, .. } => format!("user: {text}"),
        TranscriptItem::Assistant {
            text,
            is_streaming: false,
            ..
        } => format!("assistant: {}", text.trim()),
        TranscriptItem::Tool {
            name,
            args_json,
            output,
            status,
            ..
        } => format!(
            "tool {name} {status:?}: {} → {}",
            args_json.chars().take(160).collect::<String>(),
            output
                .lines()
                .next()
                .unwrap_or("")
                .chars()
                .take(160)
                .collect::<String>()
        ),
        TranscriptItem::Notice { text, is_error, .. } => {
            format!("{}: {text}", if *is_error { "error" } else { "notice" })
        }
        _ => return,
    };
    if printed.get(item.id()) != Some(&line) {
        println!("{line}");
        printed.insert(item.id().to_string(), line);
    }
}
