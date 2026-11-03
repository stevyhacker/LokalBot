//! Handing an action or a meeting to a coding agent installed on this
//! computer (`ActionAgentHandoff.swift`, `ExternalAgentHandoff.swift`). Every
//! route leaves the prompt unsent: a deep link fills the agent's input box,
//! and an agent with no link starts in a new terminal with the prompt on the
//! clipboard to paste. Nothing leaves this computer until the user sends it.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use gpui_kit::{App, AppContext as _, ClipboardItem, Entity};
use lokalbot_core::agent_handoff as prompts;
use lokalbot_core::{ActionReference, ActionThread, Library, Meeting};

use crate::state::AppData;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Target {
    ClaudeCode,
    Codex,
    /// The Claude desktop app, for a meeting's notes.
    Claude,
}

impl Target {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Target::ClaudeCode => "Claude Code",
            Target::Codex => "Codex",
            Target::Claude => "Claude",
        }
    }

    /// Documented deep links, most capable first: a scheme, what comes
    /// before the encoded prompt, and how long a prompt it can carry.
    fn links(self) -> &'static [(&'static str, &'static str, usize)] {
        const SHORT: usize = prompts::ACTION_PROMPT_LIMIT;
        const LONG: usize = prompts::MEETING_PROMPT_LIMIT;
        match self {
            Target::ClaudeCode => &[
                ("claude", "claude://code/new?q=", SHORT),
                ("claude-cli", "claude-cli://open?q=", SHORT),
            ],
            Target::Codex => &[("codex", "codex://new?prompt=", LONG)],
            Target::Claude => &[
                ("claude", "claude://claude.ai/new?q=", LONG),
                ("claude-cli", "claude-cli://open?q=", SHORT),
            ],
        }
    }

    fn command(self) -> &'static str {
        match self {
            Target::ClaudeCode | Target::Claude => "claude",
            Target::Codex => "codex",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Route {
    Link {
        prefix: &'static str,
        limit: usize,
    },
    /// The Codex CLI has no documented way to fill a prompt without sending
    /// it, and a prompt on a command line could be read as more than text.
    Terminal {
        program: PathBuf,
    },
}

impl Route {
    fn limit(&self, target: Target) -> usize {
        match self {
            Route::Link { limit, .. } => *limit,
            Route::Terminal { .. } if target == Target::Claude => prompts::MEETING_PROMPT_LIMIT,
            Route::Terminal { .. } => prompts::ACTION_PROMPT_LIMIT,
        }
    }
}

/// The first route something on this computer handles, or `None`. A deep
/// link wins over a terminal.
fn pick_route(
    target: Target,
    handles_scheme: impl Fn(&str) -> bool,
    program: impl FnOnce(&str) -> Option<PathBuf>,
) -> Option<Route> {
    target
        .links()
        .iter()
        .find(|(scheme, _, _)| handles_scheme(scheme))
        .map(|&(_, prefix, limit)| Route::Link { prefix, limit })
        .or_else(|| program(target.command()).map(|program| Route::Terminal { program }))
}

struct Cache {
    checked_at: Instant,
    routes: Vec<(Target, Route)>,
}

static CACHE: Mutex<Option<Cache>> = Mutex::new(None);
const ALL: [Target; 3] = [Target::ClaudeCode, Target::Codex, Target::Claude];

fn lock_cache() -> std::sync::MutexGuard<'static, Option<Cache>> {
    CACHE.lock().unwrap_or_else(|e| e.into_inner())
}

/// A menu has asked for agents, which is reason enough to run the login shell.
static MENU_OPENED: AtomicBool = AtomicBool::new(false);

/// Looks for agents off the UI thread, at most once a minute: menus rebuild
/// on every open, and Claude Code registers its link handler only after its
/// first interactive prompt.
pub(crate) fn refresh_in_background() {
    refresh(false);
}

fn refresh(force: bool) {
    if !force {
        let cache = lock_cache();
        if cache
            .as_ref()
            .is_some_and(|c| c.checked_at.elapsed() < Duration::from_secs(60))
        {
            return;
        }
    }
    std::thread::spawn(|| {
        let routes: Vec<(Target, Route)> = ALL
            .iter()
            .filter_map(|&target| {
                let route = pick_route(
                    target,
                    lokalbot_platform::agent_links::handles_scheme,
                    locate_command,
                )?;
                Some((target, route))
            })
            .collect();
        *lock_cache() = Some(Cache {
            checked_at: Instant::now(),
            routes,
        });
    });
}

fn route_for(target: Target) -> Option<Route> {
    // The first menu looks again, this time through the login shell too.
    refresh(!MENU_OPENED.swap(true, Ordering::Relaxed));
    lock_cache()
        .as_ref()?
        .routes
        .iter()
        .find(|(t, _)| *t == target)
        .map(|(_, route)| route.clone())
}

/// Agents to offer on an action.
pub(crate) fn for_actions() -> Vec<Target> {
    [Target::ClaudeCode, Target::Codex]
        .into_iter()
        .filter(|t| route_for(*t).is_some())
        .collect()
}

/// Agents to offer on a meeting's notes.
pub(crate) fn for_meetings() -> Vec<Target> {
    [Target::Claude, Target::Codex]
        .into_iter()
        .filter(|t| route_for(*t).is_some())
        .collect()
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
}

fn executable_names(command: &str) -> Vec<String> {
    if cfg!(windows) {
        vec![format!("{command}.exe"), format!("{command}.cmd")]
    } else {
        vec![command.to_string()]
    }
}

fn is_program(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        path.metadata()
            .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    path.is_file()
}

/// `command` on PATH, or where Claude Code's and Codex's installers put it.
/// A desktop session from a launcher can have a minimal PATH, so once a menu
/// has asked, one under a Node version manager is found through the login
/// shell, at most once per launch.
fn locate_command(command: &str) -> Option<PathBuf> {
    let names = executable_names(command);
    let on_path: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    let known: Vec<PathBuf> = home_dir()
        .map(|home| {
            lokalbot_ai::plans::claude::candidate_paths(&home)
                .into_iter()
                .filter_map(|p| p.parent().map(Path::to_path_buf))
                .collect()
        })
        .unwrap_or_default();
    on_path
        .into_iter()
        .chain(known)
        .filter(|dir| dir.is_absolute())
        .flat_map(|dir| names.iter().map(move |name| dir.join(name)))
        .find(|candidate| is_program(candidate))
        .or_else(|| {
            if !MENU_OPENED.load(Ordering::Relaxed) {
                return None;
            }
            static LOOKED_UP: Mutex<Vec<(String, Option<PathBuf>)>> = Mutex::new(Vec::new());
            let mut looked_up = LOOKED_UP.lock().unwrap_or_else(|e| e.into_inner());
            if let Some((_, found)) = looked_up.iter().find(|(name, _)| name == command) {
                return found.clone();
            }
            let found = login_shell_lookup(command);
            looked_up.push((command.to_string(), found.clone()));
            found
        })
}

#[cfg(unix)]
fn login_shell_lookup(command: &str) -> Option<PathBuf> {
    use std::process::{Command, Stdio};
    let shell = std::env::var_os("SHELL")
        .map(PathBuf::from)
        .filter(|s| s.is_absolute() && is_program(s))
        .unwrap_or_else(|| PathBuf::from("/bin/sh"));
    let mut child = Command::new(shell)
        .args(["-lc", &format!("command -v {command}")])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if start.elapsed() < Duration::from_secs(5) => {
                std::thread::sleep(Duration::from_millis(50))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
    let output = child.wait_with_output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let path = PathBuf::from(text.lines().last()?.trim());
    (path.is_absolute() && is_program(&path)).then_some(path)
}

#[cfg(not(unix))]
fn login_shell_lookup(_: &str) -> Option<PathBuf> {
    None
}

/// Opens `target` with the prompt `build` writes for its length limit, and
/// says so whichever way it goes.
fn hand_off(
    data: &Entity<AppData>,
    target: Target,
    build: impl FnOnce(&Library, usize) -> String + Send + 'static,
    cx: &mut App,
) {
    let name = target.name();
    let could_not =
        || lokalbot_i18n::format("Couldn't open {target}.", &[("target", name.to_string())]);
    let Some(route) = route_for(target) else {
        let message = could_not();
        data.update(cx, |data, cx| data.show_error(message, cx));
        return;
    };
    let library = data.read(cx).library.clone();
    let data = data.clone();
    cx.spawn(async move |cx| {
        let (prompt, result) = cx
            .background_spawn(async move {
                let prompt = build(&library, route.limit(target));
                let result = match &route {
                    Route::Link { prefix, .. } => {
                        let url = format!("{prefix}{}", prompts::encode_query_value(&prompt));
                        lokalbot_platform::agent_links::open_agent_link(&url).map(|()| false)
                    }
                    Route::Terminal { program } => {
                        let folder = home_dir().unwrap_or_else(std::env::temp_dir);
                        lokalbot_platform::agent_links::open_in_terminal(program, &folder)
                            .map(|()| true)
                    }
                };
                (prompt, result)
            })
            .await;
        cx.update(|cx| match result {
            Ok(false) => {}
            Ok(true) => {
                cx.write_to_clipboard(ClipboardItem::new_string(prompt));
                let message = lokalbot_i18n::format(
                    "{target} is opening in a terminal. Its prompt is on the clipboard: paste it there, then send it when you are ready.",
                    &[("target", name.to_string())],
                );
                data.update(cx, |data, cx| data.show_message(message, cx));
            }
            Err(err) => {
                log::warn!("handoff to {name} failed: {err:#}");
                // The prompt stays available.
                cx.write_to_clipboard(ClipboardItem::new_string(prompt));
                let message = lokalbot_i18n::format(
                    "Couldn't open {target}: {err}. Its prompt is on the clipboard.",
                    &[
                        ("target", name.to_string()),
                        ("err", format!("{err:#}")),
                    ],
                );
                data.update(cx, |data, cx| data.show_error(message, cx));
            }
        });
    })
    .detach();
}

/// "Open in Claude Code" and "Open in Codex" on one action.
pub(crate) fn hand_off_reference(
    data: &Entity<AppData>,
    reference: &ActionReference,
    target: Target,
    cx: &mut App,
) {
    let meetings = data.read(cx).meetings.clone();
    let reference = reference.clone();
    hand_off(
        data,
        target,
        move |library, limit| {
            let brief = prompts::ActionBrief::for_reference(library, &meetings, &reference);
            prompts::action_prompt(&brief, limit)
        },
        cx,
    );
}

/// The same from a meeting's page, which has the action's id.
pub(crate) fn hand_off_meeting_action(
    data: &Entity<AppData>,
    meeting: &Meeting,
    action_id: String,
    target: Target,
    cx: &mut App,
) {
    let meetings = data.read(cx).meetings.clone();
    let meeting = meeting.clone();
    hand_off(
        data,
        target,
        move |library, limit| {
            let references = library.meeting_actions(&meeting).unwrap_or_default();
            let brief = references
                .iter()
                .find(|r| r.action_id == action_id)
                .map(|r| prompts::ActionBrief::for_reference(library, &meetings, r));
            brief.map_or_else(String::new, |b| prompts::action_prompt(&b, limit))
        },
        cx,
    );
}

/// The same for an action thread, with every meeting it came up in.
pub(crate) fn hand_off_thread(
    data: &Entity<AppData>,
    thread: &ActionThread,
    target: Target,
    cx: &mut App,
) {
    let meetings = data.read(cx).meetings.clone();
    let thread = thread.clone();
    hand_off(
        data,
        target,
        move |library, limit| {
            let brief = prompts::ActionBrief::for_thread(library, &meetings, &thread);
            prompts::action_prompt(&brief, limit)
        },
        cx,
    );
}

/// "Open in Claude" and "Open in Codex" on a meeting's notes.
pub(crate) fn hand_off_meeting(
    data: &Entity<AppData>,
    meeting: &Meeting,
    target: Target,
    cx: &mut App,
) {
    let meeting = meeting.clone();
    hand_off(
        data,
        target,
        move |library, limit| {
            let session = lokalbot_cli::session::Session::open(library.paths().clone());
            let id = meeting.short_id();
            let Ok(session) = session else {
                return prompts::meeting_prompt(&id, limit, |_| meeting.display_title());
            };
            prompts::meeting_prompt(&id, limit, |characters| {
                lokalbot_cli::session::get_markdown(
                    &session,
                    &meeting,
                    &lokalbot_cli::session::GetOptions {
                        include_summary: true,
                        include_transcript: characters.is_some(),
                        include_metadata: true,
                        transcript_characters: characters,
                        transcript_from: None,
                    },
                )
            })
        },
        cx,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_wins_over_the_terminal() {
        let route = pick_route(
            Target::ClaudeCode,
            |scheme| scheme == "claude-cli",
            |_| Some(PathBuf::from("/usr/bin/claude")),
        );
        assert_eq!(
            route,
            Some(Route::Link {
                prefix: "claude-cli://open?q=",
                limit: prompts::ACTION_PROMPT_LIMIT
            })
        );
        let route = pick_route(Target::ClaudeCode, |_| true, |_| None);
        assert!(matches!(
            route,
            Some(Route::Link {
                prefix: "claude://code/new?q=",
                ..
            })
        ));
    }

    #[test]
    fn without_a_link_the_command_runs_in_a_terminal() {
        let route = pick_route(
            Target::Codex,
            |_| false,
            |command| Some(PathBuf::from(format!("/opt/{command}"))),
        );
        assert_eq!(
            route,
            Some(Route::Terminal {
                program: PathBuf::from("/opt/codex")
            })
        );
    }

    #[test]
    fn nothing_installed_offers_nothing() {
        assert_eq!(pick_route(Target::Codex, |_| false, |_| None), None);
    }

    #[test]
    fn a_meetings_notes_keep_their_length_only_where_the_link_can_carry_it() {
        let long = pick_route(Target::Claude, |s| s == "claude", |_| None).unwrap();
        assert_eq!(long.limit(Target::Claude), prompts::MEETING_PROMPT_LIMIT);
        let short = pick_route(Target::Claude, |s| s == "claude-cli", |_| None).unwrap();
        assert_eq!(short.limit(Target::Claude), prompts::ACTION_PROMPT_LIMIT);
    }
}
