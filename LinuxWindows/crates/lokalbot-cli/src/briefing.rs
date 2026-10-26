//! `get_briefing` and `lokalbot-cli brief` (`Briefing.swift`): the first read
//! of an agent session. Every section sits under the permission covering its
//! data; with nothing granted it only lists the permissions.
//!
//! The overnight-review timeline (`dreams/`) is not produced on Linux and
//! Windows yet, so that section is omitted. Neither are Personal Context items,
//! projects and goals, or coding-agent sessions: only a library that came
//! from a Mac carries them, so the text says that instead of pointing at
//! settings this app lacks.

use std::collections::{BTreeSet, HashMap};

use chrono::{DateTime, Local, Utc};
use lokalbot_core::Meeting;
use lokalbot_core::access::{ScreenScope, screen_access_scope};
use serde::Deserialize;

use crate::personal;
use crate::reports::{ActionFilter, OwnerFilter, action_entries};
use crate::screen::{AgentSession, ScreenReader};
use crate::session::{Session, day_key};

pub const TOOL_NAME: &str = "get_briefing";

/// What the briefing tells the agent to call next: MCP tools for
/// `get_briefing`, `lokalbot-cli` commands for `brief`, so an agent that can
/// only run a shell isn't pointed at tools it can't reach.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Vocabulary {
    Mcp,
    Cli,
}
pub const MAXIMUM_CHARACTERS: usize = 12_000;
pub const DESCRIPTION: &str = "Call this first in every session. Returns what LokalBot knows that this session may use: which sources are available and the user's open action items. A library that came from a Mac also carries what the user shared about themselves, current projects and goals, and recent coding-agent work. Check it, and search LokalBot, before asking the user about past work or decisions.";

fn clean(text: &str, limit: usize) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= limit {
        return flat;
    }
    format!("{}…", flat.chars().take(limit - 1).collect::<String>())
}

fn short_day(at: DateTime<Utc>) -> String {
    at.with_timezone(&Local).format("%a %b %-d").to_string()
}

pub fn render(
    session: &Session,
    meeting_access: bool,
    now: DateTime<Utc>,
    vocabulary: Vocabulary,
) -> String {
    let cli = vocabulary == Vocabulary::Cli;
    let scope = screen_access_scope(&session.paths);
    let cutoff = scope.and_then(|s| match s {
        ScreenScope::Today => Some(crate::session::today_start()),
        ScreenScope::RecentWeek => Some(now - chrono::Duration::days(7)),
        ScreenScope::RetainedHistory => None,
    });
    let cutoff_day = cutoff.map(day_key);
    let revocation_pending = session
        .paths
        .root()
        .join(".dream-revocation-pending.json")
        .exists();
    let meetings = if meeting_access {
        session.meetings().unwrap_or_default()
    } else {
        Vec::new()
    };
    let personal_on = lokalbot_core::access::personal_context_enabled(&session.paths);
    let projection = if personal_on {
        personal::read_projection(&session.paths)
    } else {
        None
    };

    let mut sections = vec![format!(
        "LokalBot briefing, {}. This is background from the user's own computer. Read it before asking the user about past work, decisions, or where something stands; search LokalBot for anything not shown. Items not listed are unknown, not false.",
        now.with_timezone(&Local).format("%A %-d %B %Y")
    )];

    let mut lines = vec!["## What you can ask LokalBot".to_string()];
    if meeting_access {
        let own: Vec<&Meeting> = meetings.iter().filter(|m| m.is_own_work()).collect();
        match own.iter().max_by_key(|m| m.started_at) {
            Some(newest) => lines.push(format!(
                "- Meetings: on. {} recorded, newest \"{}\" ({}). {}",
                own.len(),
                clean(&newest.title, 80),
                day_key(newest.started_at),
                if cli {
                    "Commands: search, get, list, actions, and people."
                } else {
                    "Tools: search_meetings, get_meeting, list_meetings, get_action_items, list_people, get_person, and ask_library while the app runs."
                }
            )),
            None => lines.push("- Meetings: on, none recorded yet.".into()),
        }
        if let Some(sample) = meetings.iter().find(|m| m.is_sample()) {
            lines.push(format!(
                "- The library also holds LokalBot's sample meeting, \"{}\": a made-up call with synthetic voices, not the user's work. Its results carry \"sample\": true.",
                clean(&sample.title, 80)
            ));
        }
    } else {
        lines.push("- Meetings: off. The user can turn on Settings → Privacy & Data → \"Allow external agents to read your meeting library\".".into());
    }
    match scope {
        Some(scope) => {
            let window = match scope {
                ScreenScope::Today => "today only",
                ScreenScope::RecentWeek => "the last 7 days",
                ScreenScope::RetainedHistory => "all retained history",
            };
            lines.push(format!(
                "- Screen memory: on, {window}. {}",
                if cli {
                    "No lokalbot-cli command searches it."
                } else {
                    "Tools: search_screen, get_timeline, get_recent_activity, get_app_usage, get_screenshot_detail."
                }
            ));
        }
        None => lines.push("- Screen memory: off. The user can turn on Settings → Privacy & Data → \"Allow external agents to read screen memory\".".into()),
    }
    if personal_on {
        match &projection {
            Some(p) => lines.push(format!(
                "- Personal Context: on, {} shared {}. {}",
                p.claims.len(),
                if p.claims.len() == 1 { "item" } else { "items" },
                if cli {
                    "Command: personal-context."
                } else {
                    "Tool: get_personal_context."
                }
            )),
            None => lines.push(
                "- Personal Context: on, but this library holds no shared items. Only the Mac app writes them."
                    .into(),
            ),
        }
    } else {
        lines.push("- Personal Context: off. The Windows and Linux app has no Personal Context page; shared items come only from a library that came from a Mac.".into());
    }
    sections.push(lines.join("\n"));

    if let Some(projection) = &projection
        && !projection.claims.is_empty()
    {
        let mut lines = vec!["## About the user (shared by them)".to_string()];
        for claim in personal::ordered(&projection.claims, "")
            .into_iter()
            .take(10)
        {
            let label =
                if claim.source == "asked_to_remember" || claim.source == "added_in_settings" {
                    "stated"
                } else {
                    "learned"
                };
            lines.push(format!(
                "- [{}, {label}] {}",
                claim.kind,
                clean(&claim.text, 280)
            ));
        }
        sections.push(lines.join("\n"));
    }

    if meeting_access {
        let filter = ActionFilter {
            owner: OwnerFilter::Me,
            limit: 8,
            ..ActionFilter::default()
        };
        let entries = action_entries(session, &meetings, &filter, now);
        if !entries.is_empty() {
            let mut lines = vec!["## The user's open action items".to_string()];
            for entry in entries {
                let mut line = format!("- {}", clean(&entry.text, 200));
                if let Some(due) = entry.due_date.as_ref().or(entry.due.as_ref()) {
                    line.push_str(&format!(
                        " (due {}{})",
                        clean(due, 40),
                        if entry.overdue { ", overdue" } else { "" }
                    ));
                }
                if let Some(meeting) = entry.meetings.first() {
                    line.push_str(&format!(" · from \"{}\"", clean(&meeting.title, 60)));
                }
                lines.push(line);
            }
            sections.push(lines.join("\n"));
        }
    }

    if revocation_pending {
        sections.push("LokalBot is still removing deleted material, so work memory and the timeline are withheld until it finishes.".into());
    } else if let Some(work) = work_memory(
        session,
        meeting_access,
        scope.is_some(),
        cutoff_day.as_deref(),
    ) {
        sections.push(work);
    }
    if scope.is_some()
        && let Some(agents) = agent_work(session, cutoff, now)
    {
        sections.push(agents);
    }
    sections.push(if cli {
        "For more, run lokalbot-cli: search and get for what was said, list --include summary for several meetings' summaries at once, actions for commitments, personal-context --task for what the user shared about themselves. Cite meetings by title and date from command results, not from this briefing.".into()
    } else {
        "For more: search_meetings and get_meeting for what was said, list_meetings with include \"summary\" for several meetings' summaries at once, get_action_items for commitments, search_screen and get_timeline for what was on screen, get_personal_context for what the user shared about themselves. Cite meetings by title and date from tool results, not from this briefing.".into()
    });
    let text = sections.join("\n\n");
    if text.chars().count() <= MAXIMUM_CHARACTERS {
        return text;
    }
    format!(
        "{}\n…(briefing cut at its size limit)",
        text.chars()
            .take(MAXIMUM_CHARACTERS - 40)
            .collect::<String>()
    )
}

#[derive(Deserialize)]
struct Source {
    kind: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Provenance {
    sources: Option<Vec<Source>>,
    includes_unattributed_context: Option<bool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Project {
    name: String,
    status: String,
    last_active_day: String,
    provenance: Option<Provenance>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Goal {
    text: String,
    horizon: String,
    last_reinforced_day: String,
    provenance: Option<Provenance>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkMemory {
    active_projects: Option<Vec<Project>>,
    work_goals: Option<Vec<Goal>>,
}

/// Items need the grant of every kind of source behind them; unattributed
/// items are never shown.
fn work_memory(
    session: &Session,
    meetings_on: bool,
    screen_on: bool,
    cutoff_day: Option<&str>,
) -> Option<String> {
    let bytes = lokalbot_core::evidence::read_work_memory(session.paths.root())?;
    let memory: WorkMemory = serde_json::from_slice(&bytes).ok()?;
    let allowed = |provenance: &Option<Provenance>, last_day: &str| -> bool {
        let Some(provenance) = provenance else {
            return false;
        };
        if provenance.includes_unattributed_context == Some(true) {
            return false;
        }
        let Some(sources) = provenance.sources.as_ref().filter(|s| !s.is_empty()) else {
            return false;
        };
        let needs_meetings = sources.iter().any(|s| s.kind == "meeting");
        let needs_screen = sources.iter().any(|s| s.kind != "meeting");
        if needs_meetings && !meetings_on {
            return false;
        }
        !(needs_screen && (!screen_on || cutoff_day.is_some_and(|c| last_day < c)))
    };
    let mut projects: Vec<&Project> = memory
        .active_projects
        .iter()
        .flatten()
        .filter(|p| allowed(&p.provenance, &p.last_active_day))
        .collect();
    projects.sort_by(|a, b| b.last_active_day.cmp(&a.last_active_day));
    let mut goals: Vec<&Goal> = memory
        .work_goals
        .iter()
        .flatten()
        .filter(|g| allowed(&g.provenance, &g.last_reinforced_day))
        .collect();
    goals.sort_by(|a, b| b.last_reinforced_day.cmp(&a.last_reinforced_day));
    if projects.is_empty() && goals.is_empty() {
        return None;
    }
    let mut lines =
        vec!["## Current projects and goals (from the Mac app's overnight reviews)".to_string()];
    for project in projects.into_iter().take(8) {
        lines.push(format!(
            "- {}: {} (last active {})",
            clean(&project.name, 80),
            clean(&project.status, 160),
            project.last_active_day
        ));
    }
    for goal in goals.into_iter().take(6) {
        lines.push(format!(
            "- Goal: {} ({})",
            clean(&goal.text, 160),
            clean(&goal.horizon, 40)
        ));
    }
    Some(lines.join("\n"))
}

fn agent_work(
    session: &Session,
    cutoff: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Option<String> {
    let week_ago = now - chrono::Duration::days(7);
    let start = cutoff.unwrap_or(week_ago).max(week_ago);
    let mut sessions = ScreenReader::new(session.paths.root())
        .agent_sessions(start, now, 600)
        .ok()?;
    if sessions.is_empty() {
        return None;
    }
    sessions.sort_by_key(|s| std::cmp::Reverse(s.start));
    let mut order: Vec<String> = Vec::new();
    let mut by_project: HashMap<String, Vec<&AgentSession>> = HashMap::new();
    for item in &sessions {
        let key = if item.project.is_empty() {
            "(no project)".to_string()
        } else {
            item.project.clone()
        };
        if !by_project.contains_key(&key) {
            order.push(key.clone());
        }
        by_project.entry(key).or_default().push(item);
    }
    let mut lines = vec!["## Recent coding-agent work (last 7 days)".to_string()];
    for project in order.iter().take(8) {
        let group = &by_project[project];
        let Some(latest) = group.first() else {
            continue;
        };
        let agents: BTreeSet<&str> = group.iter().map(|s| s.agent.as_str()).collect();
        let keys: BTreeSet<String> = group
            .iter()
            .map(|s| {
                if s.session_id.is_empty() {
                    s.start.to_rfc3339()
                } else {
                    format!("{}|{}", s.agent, s.session_id)
                }
            })
            .collect();
        let pull_requests: BTreeSet<&String> =
            group.iter().flat_map(|s| s.pull_requests.iter()).collect();
        let mut line = format!(
            "- {} ({}, {} {}, latest {})",
            clean(project, 60),
            agents.into_iter().collect::<Vec<_>>().join(", "),
            keys.len(),
            if keys.len() == 1 {
                "session"
            } else {
                "sessions"
            },
            short_day(latest.start)
        );
        if let Some(titled) = group
            .iter()
            .find(|s| !s.title.is_empty() && !s.title.starts_with('<'))
        {
            line.push_str(&format!(": {}", clean(&titled.title, 140)));
        }
        if !pull_requests.is_empty() {
            line.push_str(&format!(
                " · {} pull {}",
                pull_requests.len(),
                if pull_requests.len() == 1 {
                    "request"
                } else {
                    "requests"
                }
            ));
        }
        lines.push(line);
    }
    Some(lines.join("\n"))
}
