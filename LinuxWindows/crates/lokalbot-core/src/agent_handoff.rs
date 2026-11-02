//! Prompts for handing work to a coding agent (`ActionAgentHandoff.swift`,
//! `ExternalAgentHandoff.swift`). Nothing here sends anything: every route
//! only fills the agent's input, and the user sends it there.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, NaiveDate, Utc};

use crate::library::{Library, NOTES_FILE, SUMMARY_FILE, TRANSCRIPT_MD_FILE};
use crate::model::{ActionReference, ActionThread, Meeting};

/// Claude Code's limit for a deep link's `q`. Codex documents no limit; it
/// gets the same budget.
pub const ACTION_PROMPT_LIMIT: usize = 5_000;
/// Claude cuts `q` at about 14,000 characters; both apps open with the same notes.
pub const MEETING_PROMPT_LIMIT: usize = 12_000;
const MAXIMUM_SOURCES: usize = 5;
const MAXIMUM_TEXT_CHARACTERS: usize = 1_000;
const CUT_SHORT: &str = "\n\n[Cut short to fit.]";

/// A file an agent can read, labeled as the prompt names it.
#[derive(Clone, Debug, PartialEq)]
pub struct SourceFile {
    pub label: &'static str,
    pub path: PathBuf,
}

/// One meeting an action came up in.
#[derive(Clone, Debug, PartialEq)]
pub struct Source {
    pub title: String,
    pub started_at: DateTime<Utc>,
    /// The short ID the CLI and MCP tools accept.
    pub meeting_id: String,
    /// Where the action's first cited passage starts in the recording.
    pub evidence_at: Option<f64>,
    pub folder: PathBuf,
    pub files: Vec<SourceFile>,
}

/// What a handoff prompt says about one action (`ActionHandoffBrief`).
#[derive(Clone, Debug, PartialEq)]
pub struct ActionBrief {
    pub text: String,
    pub owner: Option<String>,
    pub owner_is_user: bool,
    pub due: Option<String>,
    pub due_date: Option<NaiveDate>,
    pub due_said_on: Option<DateTime<Utc>>,
    pub status: String,
    /// Latest first.
    pub sources: Vec<Source>,
}

/// Rows show "You" only for an owner named "Me" on the user's own work.
fn is_user_owner(owner: Option<&str>, is_for_user: bool) -> bool {
    is_for_user && owner.is_some_and(|o| o.trim().eq_ignore_ascii_case("me"))
}

/// A speaker label as a person reads it. Prompts stay in English, like the
/// Mac's, whatever language the app shows.
fn owner_label(owner: &str) -> String {
    let trimmed = owner.trim();
    match trimmed.to_lowercase().as_str() {
        "me" => "Me".to_string(),
        "them" => "Other speaker".to_string(),
        _ => trimmed.to_string(),
    }
}

impl ActionBrief {
    pub fn for_reference(library: &Library, meetings: &[Meeting], r: &ActionReference) -> Self {
        Self {
            text: r.text.clone(),
            owner: r.owner.as_deref().map(owner_label),
            owner_is_user: is_user_owner(r.owner.as_deref(), r.is_for_user),
            due: r.due.clone(),
            due_date: r.resolved_due_date,
            due_said_on: Some(r.due_reference_date()),
            status: r.status.label().to_string(),
            sources: sources(library, meetings, std::slice::from_ref(r)),
        }
    }

    pub fn for_thread(library: &Library, meetings: &[Meeting], thread: &ActionThread) -> Self {
        Self {
            text: thread.text.clone(),
            owner: thread.owner.as_deref().map(owner_label),
            owner_is_user: is_user_owner(thread.owner.as_deref(), thread.is_for_user()),
            due: thread.due.clone(),
            due_date: thread.resolved_due_date,
            due_said_on: thread.due_reference_date,
            status: thread.status_label().to_string(),
            sources: sources(library, meetings, &thread.references),
        }
    }
}

/// One source per meeting, latest first; files that don't exist yet are left out.
pub fn sources(
    library: &Library,
    meetings: &[Meeting],
    references: &[ActionReference],
) -> Vec<Source> {
    let folder = |id: uuid::Uuid| -> Option<PathBuf> {
        meetings
            .iter()
            .find(|m| m.id == id)
            .map(|m| library.meeting_dir(m))
    };
    sources_in(references, folder, |path| path.is_file())
}

fn sources_in(
    references: &[ActionReference],
    folder: impl Fn(uuid::Uuid) -> Option<PathBuf>,
    file_exists: impl Fn(&Path) -> bool,
) -> Vec<Source> {
    let mut sorted: Vec<&ActionReference> = references.iter().collect();
    sorted.sort_by_key(|r| std::cmp::Reverse(r.meeting_started_at));
    let mut seen = Vec::new();
    sorted
        .into_iter()
        .filter_map(|reference| {
            if seen.contains(&reference.meeting_id) {
                return None;
            }
            seen.push(reference.meeting_id);
            let folder = folder(reference.meeting_id)?;
            let files = [
                ("Summary", SUMMARY_FILE),
                ("My notes", NOTES_FILE),
                ("Transcript", TRANSCRIPT_MD_FILE),
            ]
            .into_iter()
            .filter_map(|(label, name)| {
                let path = folder.join(name);
                file_exists(&path).then_some(SourceFile { label, path })
            })
            .collect();
            Some(Source {
                title: reference.meeting_title.clone(),
                started_at: reference.meeting_started_at,
                meeting_id: crate::ids::short_id(&reference.meeting_id),
                evidence_at: reference.first_citation().map(|c| c.start),
                folder,
                files,
            })
        })
        .collect()
}

/// A prompt the user can send as is. Older meetings are left out first when
/// the prompt would pass `limit` (`ActionAgentHandoff.prompt`).
pub fn action_prompt(brief: &ActionBrief, limit: usize) -> String {
    let mut count = brief.sources.len().min(MAXIMUM_SOURCES);
    loop {
        let text = render(brief, &brief.sources[..count]);
        if text.chars().count() <= limit {
            return text;
        }
        if count > 1 {
            count -= 1;
            continue;
        }
        return cut_short(&text, limit);
    }
}

fn cut_short(text: &str, limit: usize) -> String {
    let keep = limit.saturating_sub(CUT_SHORT.chars().count());
    let head: String = text.chars().take(keep).collect();
    head + CUT_SHORT
}

fn render(brief: &ActionBrief, sources: &[Source]) -> String {
    let local =
        |at: DateTime<Utc>, format: &str| at.with_timezone(&Local).format(format).to_string();
    let mut text = brief.text.trim().to_string();
    if text.chars().count() > MAXIMUM_TEXT_CHARACTERS {
        text = text
            .chars()
            .take(MAXIMUM_TEXT_CHARACTERS - 1)
            .collect::<String>()
            + "…";
    }
    let owner = if brief.owner_is_user {
        Some("me".to_string())
    } else {
        brief.owner.as_deref().map(|o| o.trim().to_string())
    };
    let owner = owner.filter(|o| !o.is_empty());
    let mut lines = vec![
        "Help me with this action item from a meeting I recorded in LokalBot.".to_string(),
        String::new(),
        format!("Action: {text}"),
        format!("Owner: {}", owner.as_deref().unwrap_or("not clear")),
    ];
    if let Some(due) = brief
        .due
        .as_deref()
        .map(str::trim)
        .filter(|d| !d.is_empty())
    {
        match brief.due_date {
            Some(date) => {
                let resolved = date.format("%Y-%m-%d").to_string();
                lines.push(if resolved == due {
                    format!("Due: {resolved}")
                } else {
                    format!("Due: {resolved} (said “{due}”)")
                });
            }
            None => {
                let said = brief
                    .due_said_on
                    .map(|at| format!(" (said on {})", local(at, "%Y-%m-%d")))
                    .unwrap_or_default();
                lines.push(format!("Due: “{due}”{said}"));
            }
        }
    }
    lines.push(format!("Status: {}", brief.status));
    if brief.sources.len() > 1 {
        lines.push(String::new());
        lines.push(if sources.len() == brief.sources.len() {
            format!("It came up in {} meetings, newest first:", sources.len())
        } else {
            format!(
                "It came up in {} meetings. Here are the latest {}:",
                brief.sources.len(),
                sources.len()
            )
        });
    }
    for source in sources {
        let mut heading = format!(
            "Meeting: {}, {} (LokalBot meeting ID {}).",
            source.title,
            local(source.started_at, "%a %Y-%m-%d %H:%M"),
            source.meeting_id
        );
        if let Some(at) = source.evidence_at
            && source
                .files
                .iter()
                .any(|f| f.path.ends_with(TRANSCRIPT_MD_FILE))
        {
            heading.push_str(&format!(
                " It comes up at [{}] in the transcript.",
                crate::time::stamp(at)
            ));
        }
        lines.push(String::new());
        lines.push(heading);
        if source.files.is_empty() {
            lines.push(format!("- Folder: `{}`", source.folder.display()));
        } else {
            lines.extend(
                source
                    .files
                    .iter()
                    .map(|f| format!("- {}: `{}`", f.label, f.path.display())),
            );
        }
    }
    if !sources.is_empty() {
        lines.push(String::new());
        lines.push(
            "These files are LokalBot's records of the meeting. Read them for the full context, but don't edit them."
                .to_string(),
        );
    }
    lines.join("\n")
}

/// A meeting's notes for "Open in Claude" and "Open in Codex"
/// (`ExternalAgentHandoff.prompt`). `notes(None)` renders the notes without a
/// transcript and `notes(Some(n))` adds up to n characters of it; the
/// transcript gets whatever room the notes leave.
pub fn meeting_prompt(
    meeting_id: &str,
    limit: usize,
    notes: impl Fn(Option<usize>) -> String,
) -> String {
    let intro = format!(
        "Here are my notes from a meeting recorded in LokalBot (meeting ID {meeting_id}).\n\n"
    );
    let without_transcript = notes(None);
    // Leave room for the transcript heading and its "continues" pointer.
    let room = limit as i64
        - intro.chars().count() as i64
        - without_transcript.chars().count() as i64
        - 200;
    let body = if room >= 1_000 {
        notes(Some(room as usize))
    } else {
        without_transcript
    };
    let text = intro + body.trim();
    if text.chars().count() <= limit {
        text
    } else {
        cut_short(&text, limit)
    }
}

/// Keeps every character the apps would otherwise read as a space or a new
/// parameter out of a link's query (`encodeQueryValue`).
pub fn encode_query_value(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// "Open in Agent" for one action.
pub fn agent_prompt_for_action(reference: &ActionReference) -> String {
    agent_prompt_from_meeting(&reference.meeting_title, &reference.text)
}

/// "Open in Agent" for an action of a meeting.
pub fn agent_prompt_from_meeting(meeting_title: &str, text: &str) -> String {
    format!("Help me complete this action from {meeting_title}: {text}")
}

/// "Open in Agent" for an action thread.
pub fn agent_prompt_for_thread(thread: &ActionThread) -> String {
    let source_note = if thread.meeting_count() == 1 {
        thread.latest().meeting_title.clone()
    } else {
        format!("{} source meetings", thread.meeting_count())
    };
    format!(
        "Help me complete this action thread from {source_note}: {}",
        thread.text
    )
}

/// Today's "Plan in Agent…": at most eight open threads.
pub fn agent_prompt_for_plan(threads: &[ActionThread]) -> String {
    let lines: Vec<String> = threads
        .iter()
        .take(8)
        .map(|thread| {
            let sources = if thread.meeting_count() == 1 {
                String::new()
            } else {
                format!(" (mentioned in {} meetings)", thread.meeting_count())
            };
            format!("- {}{sources}", thread.text)
        })
        .collect();
    format!(
        "Help me plan today's open meeting action threads:\n{}",
        lines.join("\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn source(title: &str, path: &str) -> Source {
        Source {
            title: title.to_string(),
            started_at: Utc.with_ymd_and_hms(2026, 10, 8, 12, 0, 0).unwrap(),
            meeting_id: "AB12CD34".to_string(),
            evidence_at: Some(94.0),
            folder: PathBuf::from(path),
            files: vec![
                SourceFile {
                    label: "Summary",
                    path: PathBuf::from(path).join(SUMMARY_FILE),
                },
                SourceFile {
                    label: "Transcript",
                    path: PathBuf::from(path).join(TRANSCRIPT_MD_FILE),
                },
            ],
        }
    }

    fn brief(sources: Vec<Source>) -> ActionBrief {
        ActionBrief {
            text: "Send the deck".to_string(),
            owner: Some("Me".to_string()),
            owner_is_user: true,
            due: Some("Friday".to_string()),
            due_date: NaiveDate::from_ymd_opt(2026, 10, 9),
            due_said_on: None,
            status: "Open".to_string(),
            sources,
        }
    }

    #[test]
    fn action_prompt_matches_the_mac() {
        let at = Utc
            .with_ymd_and_hms(2026, 10, 8, 12, 0, 0)
            .unwrap()
            .with_timezone(&Local)
            .format("%a %Y-%m-%d %H:%M");
        let prompt = action_prompt(&brief(vec![source("Sync", "/lib/a")]), ACTION_PROMPT_LIMIT);
        assert_eq!(
            prompt,
            format!(
                "Help me with this action item from a meeting I recorded in LokalBot.\n\nAction: Send the deck\nOwner: me\nDue: 2026-10-09 (said “Friday”)\nStatus: Open\n\nMeeting: Sync, {at} (LokalBot meeting ID AB12CD34). It comes up at [00:01:34] in the transcript.\n- Summary: `/lib/a/summary.md`\n- Transcript: `/lib/a/transcript.md`\n\nThese files are LokalBot's records of the meeting. Read them for the full context, but don't edit them."
            )
        );
    }

    #[test]
    fn older_meetings_go_first_and_long_prompts_are_cut() {
        let sources: Vec<Source> = (0..7)
            .map(|i| source(&format!("Sync {i}"), &format!("/lib/{i}")))
            .collect();
        let full = action_prompt(&brief(sources.clone()), ACTION_PROMPT_LIMIT);
        assert!(full.contains("It came up in 7 meetings. Here are the latest 5:"));
        assert!(!full.contains("Sync 5"));
        let tight = action_prompt(&brief(sources), 600);
        assert!(tight.chars().count() <= 600);
        assert!(tight.contains("Sync 0"));
        assert!(!tight.contains("Sync 4"), "{tight}");

        let one = action_prompt(&brief(vec![source("Sync", "/lib/a")]), 120);
        assert_eq!(one.chars().count(), 120);
        assert!(one.ends_with("[Cut short to fit.]"));
    }

    #[test]
    fn no_owner_says_so_and_a_folder_stands_in_for_missing_files() {
        let mut b = brief(vec![]);
        b.owner = None;
        b.owner_is_user = false;
        b.due = None;
        let prompt = action_prompt(&b, ACTION_PROMPT_LIMIT);
        assert!(prompt.contains("Owner: not clear"));
        assert!(!prompt.contains("Due:"));
        assert!(!prompt.contains("These files"));

        let mut s = source("Sync", "/lib/a");
        s.files.clear();
        let prompt = action_prompt(&brief(vec![s]), ACTION_PROMPT_LIMIT);
        assert!(prompt.contains("- Folder: `/lib/a`"));
        assert!(!prompt.contains("comes up at"), "no transcript to point at");
    }

    #[test]
    fn meeting_prompt_gives_the_transcript_what_the_notes_leave() {
        let notes = |limit: Option<usize>| match limit {
            None => "# Sync\n\n## Summary\nNotes".to_string(),
            Some(n) => format!("# Sync\n\n## Summary\nNotes\n{}", "t".repeat(n)),
        };
        let prompt = meeting_prompt("AB12", 2_000, notes);
        assert!(prompt.starts_with(
            "Here are my notes from a meeting recorded in LokalBot (meeting ID AB12).\n\n# Sync"
        ));
        assert!(prompt.contains("ttt"));
        assert!(prompt.chars().count() <= 2_000);
        // Too little room leaves the transcript out.
        let small = meeting_prompt("AB12", 1_000, notes);
        assert!(!small.contains("ttt"));
        // Notes alone over the limit are cut.
        let cut = meeting_prompt("AB12", 40, notes);
        assert_eq!(cut.chars().count(), 40);
        assert!(cut.ends_with("[Cut short to fit.]"));
    }

    #[test]
    fn query_values_leave_nothing_bare() {
        assert_eq!(
            encode_query_value("a b+c&d=e/ü"),
            "a%20b%2Bc%26d%3De%2F%C3%BC"
        );
        assert_eq!(encode_query_value("AZaz09-._~"), "AZaz09-._~");
    }
}
