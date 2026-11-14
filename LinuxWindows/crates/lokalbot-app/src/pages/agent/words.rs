//! The words the Agent page shows (`AgentPresentation.swift`): each step in
//! plain words, the steps line, where a task stands, a changed file's line,
//! the access levels and the approval card. The rules behind them (layout,
//! status, changed files) are in `lokalbot_agent::presentation`.

use std::path::Path;

use chrono::{DateTime, Local, Utc};

use lokalbot_agent::ApprovalMode;
use lokalbot_agent::policy::plain_command_words;
use lokalbot_agent::presentation::{
    Change, ChangedFile, FileTarget, SectionKind, StepArguments, TaskStatus,
};
use lokalbot_agent::transcript::{ApprovalRequest, ToolStatus, is_shell_tool};

use lokalbot_i18n::tr;
use lokalbot_i18n::{fill, interface_directional, mac};

// ------------------------------------------------------------------ steps

/// One tool call in plain words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StepLabel {
    /// "Read meeting notes"
    pub done: String,
    /// "Reading meeting notes", without the ellipsis.
    pub doing: String,
    /// What the step worked on: the search, the meeting's title, the folder.
    pub detail: Option<String>,
    /// The words begin with a file or tool name, whose capitals must stay.
    pub begins_with_name: bool,
}

impl StepLabel {
    /// The words for a step in the given state. A step still running when
    /// its task stopped never finished.
    pub fn text(&self, status: ToolStatus, task_is_working: bool) -> String {
        match status {
            ToolStatus::Succeeded => self.done.clone(),
            ToolStatus::Failed => interface_directional(&mac("%@ · failed", &[&self.doing])),
            ToolStatus::Running if task_is_working => format!("{}…", self.doing),
            ToolStatus::Running => interface_directional(&mac("%@ · not finished", &[&self.doing])),
        }
    }
}

/// What a step's words need to know about its task.
pub struct StepContext<'a> {
    pub workspace: &'a Path,
    pub workspace_name: &'a str,
    /// A meeting's title from the ID or ID prefix a lookup names.
    pub meeting_title: &'a dyn Fn(&str) -> Option<String>,
}

pub fn step_label(tool: &str, args_json: &str, context: &StepContext) -> StepLabel {
    let arguments = StepArguments::parse(args_json);
    let name = tool.to_lowercase();
    if let Some(path) = arguments.path.as_deref() {
        let verbs = match name.as_str() {
            "read" => Some((tr("Read %@"), tr("Reading %@"))),
            "write" => Some((tr("Wrote %@"), tr("Writing %@"))),
            "edit" => Some((tr("Edited %@"), tr("Editing %@"))),
            _ => None,
        };
        if let Some((done, doing)) = verbs {
            let target = FileTarget::resolve(path, context.workspace, context.workspace_name);
            return named(done, doing, &target.name, Some(target.folder));
        }
    }
    if is_shell_tool(&name) {
        return command_label(arguments.command.as_deref().unwrap_or_default(), context);
    }
    named(tr("Used %@"), tr("Using %@"), tool, None)
}

fn named(done: &str, doing: &str, name: &str, detail: Option<String>) -> StepLabel {
    StepLabel {
        // A right-to-left translation can begin with the name.
        done: interface_directional(&fill(done, &[name])),
        doing: interface_directional(&fill(doing, &[name])),
        detail,
        begins_with_name: done.starts_with('%'),
    }
}

fn phrase(done: &str, doing: &str, detail: Option<String>) -> StepLabel {
    StepLabel {
        done: done.to_string(),
        doing: doing.to_string(),
        detail,
        begins_with_name: false,
    }
}

/// `lokalbot-cli` calls made of plain words get a name for what they look
/// up. Anything a shell could chain or redirect is a command, shown with its
/// text, so a label never hides what ran.
fn command_label(text: &str, context: &StepContext) -> StepLabel {
    let first_line = text.lines().next().unwrap_or_default();
    let shown = if first_line.chars().count() > 120 {
        format!("{}…", first_line.chars().take(119).collect::<String>())
    } else {
        first_line.to_string()
    };
    let other = || {
        phrase(
            tr("Ran a command"),
            tr("Running a command"),
            (!shown.is_empty()).then(|| shown.clone()),
        )
    };
    let Some(words) = plain_command_words(Some(text)) else {
        return other();
    };
    if words.len() < 2 || words[0] != "lokalbot-cli" {
        return other();
    }
    // The first word after the subcommand that is not an option or its value.
    let mut subject = None;
    let mut skip_value = false;
    for word in &words[2..] {
        if skip_value {
            skip_value = false;
            continue;
        }
        if word.starts_with('-') {
            skip_value = !word.contains('=') && word != "--table";
            continue;
        }
        subject = Some(word.clone());
        break;
    }
    let option = |name: &str| -> Option<String> {
        let joined = format!("{name}=");
        if let Some(word) = words.iter().find(|w| w.starts_with(&joined)) {
            return Some(word[joined.len()..].to_string());
        }
        let index = words.iter().position(|w| w == name)?;
        words.get(index + 1).cloned()
    };
    match words[1].as_str() {
        "search" => phrase(
            tr("Searched meeting library"),
            tr("Searching meeting library"),
            subject,
        ),
        "get" => phrase(
            tr("Read meeting notes"),
            tr("Reading meeting notes"),
            subject.and_then(|id| (context.meeting_title)(&id)),
        ),
        "list" => phrase(
            tr("Listed meetings"),
            tr("Listing meetings"),
            option("--query"),
        ),
        "brief" => phrase(tr("Read your briefing"), tr("Reading your briefing"), None),
        "actions" => phrase(tr("Read action items"), tr("Reading action items"), None),
        _ => other(),
    }
}

/// "Searched meeting library, read meeting notes": each different step
/// once, in order. `lowercase_following` suits languages that write a list's
/// later items without a capital; names keep theirs.
pub fn steps_summary(labels: &[(String, bool)], lowercase_following: bool) -> String {
    let mut seen = std::collections::HashSet::new();
    let mut parts: Vec<String> = Vec::new();
    for (text, begins_with_name) in labels {
        if !seen.insert(text.clone()) {
            continue;
        }
        if parts.is_empty() || !lowercase_following || *begins_with_name {
            parts.push(text.clone());
        } else {
            let mut chars = text.chars();
            let first: String = chars
                .next()
                .into_iter()
                .flat_map(char::to_lowercase)
                .collect();
            parts.push(first + chars.as_str());
        }
    }
    parts.join(", ")
}

/// English writes a list's later items without a capital.
pub fn lowercases_list_items() -> bool {
    lokalbot_i18n::current().code.starts_with("en")
}

/// "4 steps"
pub fn steps_count(steps: usize) -> String {
    if steps == 1 {
        tr("1 step").to_string()
    } else {
        interface_directional(&mac("%lld steps", &[&lokalbot_i18n::number(steps)]))
    }
}

// ----------------------------------------------------------------- status

/// The word for the toolbar. A saved task that is doing nothing shows none.
pub fn status_title(status: TaskStatus) -> Option<&'static str> {
    Some(match status {
        TaskStatus::NotStarted => tr("Not started"),
        TaskStatus::Saved => return None,
        TaskStatus::Starting => tr("Starting…"),
        TaskStatus::Working => tr("Working…"),
        TaskStatus::NeedsApproval(_) => tr("Needs approval"),
        TaskStatus::NeedsAttention => tr("Needs attention"),
        TaskStatus::Stopped => tr("Stopped"),
        TaskStatus::Done { .. } => tr("Done"),
    })
}

/// The line under a task's title in the list: "Done · 1 file changed".
pub fn status_line(status: TaskStatus) -> Option<String> {
    match status {
        TaskStatus::Done { changed_files: 1 } => Some(tr("Done · 1 file changed").to_string()),
        TaskStatus::Done { changed_files } if changed_files > 1 => {
            Some(interface_directional(&mac(
                "Done · %lld files changed",
                &[&lokalbot_i18n::number(changed_files)],
            )))
        }
        other => status_title(other).map(str::to_string),
    }
}

// ------------------------------------------------------------ changed files

/// "New file", or nothing when history does not say what the write did.
pub fn change_label(change: Change) -> Option<&'static str> {
    match change {
        Change::Created => Some(tr("New file")),
        Change::Replaced => Some(tr("Replaced")),
        Change::Edited => Some(tr("Edited")),
        Change::Written => None,
    }
}

/// "New file · 12 lines · Agent Workspace"
pub fn changed_file_detail(file: &ChangedFile) -> String {
    let mut parts: Vec<String> = change_label(file.change)
        .map(str::to_string)
        .into_iter()
        .collect();
    if let Some(lines) = file.line_count {
        parts.push(if lines == 1 {
            tr("1 line").to_string()
        } else {
            mac("%lld lines", &[&lokalbot_i18n::number(lines)])
        });
    }
    parts.push(file.target.folder.clone());
    interface_directional(&parts.join(" · "))
}

// --------------------------------------------------------------- task list

pub fn section_title(kind: SectionKind) -> String {
    match kind {
        SectionKind::Pinned => tr("Pinned").to_string(),
        SectionKind::Today => tr("Today").to_string(),
        SectionKind::Yesterday => tr("Yesterday").to_string(),
        SectionKind::Day(day) => day
            .format_localized(
                lokalbot_i18n::date_pattern("%b %-d, %Y"),
                lokalbot_i18n::date_locale(),
            )
            .to_string(),
        SectionKind::Earlier => tr("Earlier").to_string(),
    }
}

/// A day group already names the day, so its rows show the time. A pinned
/// task from another day shows the date.
pub fn row_time(modified_at: DateTime<Utc>, pinned: bool, now: DateTime<Local>) -> Option<String> {
    if modified_at == DateTime::<Utc>::MIN_UTC {
        return None;
    }
    let local = modified_at.with_timezone(&Local);
    let pattern = if pinned && local.date_naive() != now.date_naive() {
        "%b %-d, %Y"
    } else {
        "%-I:%M %p"
    };
    Some(
        local
            .format_localized(
                lokalbot_i18n::date_pattern(pattern),
                lokalbot_i18n::date_locale(),
            )
            .to_string(),
    )
}

// ---------------------------------------------------------- access levels

/// On the composer's chip: what the agent does on its own.
pub fn chip_title(mode: ApprovalMode) -> &'static str {
    match mode {
        ApprovalMode::AskBeforeChanges => tr("Asks first"),
        ApprovalMode::ApproveReads => tr("Reads any file"),
        ApprovalMode::ApproveReadsAndEdits => tr("Edits any file"),
        ApprovalMode::FullAccess => tr("Full access"),
    }
}

/// The level's name in the access list.
pub fn level_title(mode: ApprovalMode) -> &'static str {
    match mode {
        ApprovalMode::AskBeforeChanges => tr("Ask first"),
        ApprovalMode::ApproveReads => tr("Read any file"),
        ApprovalMode::ApproveReadsAndEdits => tr("Edit any file"),
        ApprovalMode::FullAccess => tr("Full access"),
    }
}

/// Full access runs commands unasked, so it is drawn in the caution colour.
pub fn needs_caution(mode: ApprovalMode) -> bool {
    mode == ApprovalMode::FullAccess
}

/// One line per level: what runs on its own, and what still asks.
pub fn level_detail(mode: ApprovalMode, workspace_name: &str) -> String {
    let detail = match mode {
        // Lookups skip approval only with a model on this computer (policy.rs).
        ApprovalMode::AskBeforeChanges => lokalbot_i18n::format(
            "Reads files in {folder} without asking, and looks things up in your LokalBot library when the model runs on this PC. Asks before anything else.",
            &[("folder", workspace_name.to_string())],
        ),
        ApprovalMode::ApproveReads => tr(
            "Reads any file without asking. Asks before changing files or running commands.",
        )
        .to_string(),
        ApprovalMode::ApproveReadsAndEdits => {
            tr("Reads and edits files without asking. Asks before running commands.").to_string()
        }
        ApprovalMode::FullAccess => tr(
            "Runs commands and every other tool without asking. Commands can delete files, change LokalBot’s data or use the network.",
        )
        .to_string(),
    };
    interface_directional(&detail)
}

/// The line under the heading of a new task.
pub fn capability(mode: ApprovalMode) -> &'static str {
    match mode {
        ApprovalMode::AskBeforeChanges => tr(
            "It can read your meetings, work in a folder you choose, and asks before changing anything.",
        ),
        ApprovalMode::ApproveReads => tr(
            "It can read your meetings and any file on this PC, and asks before changing anything.",
        ),
        ApprovalMode::ApproveReadsAndEdits => {
            tr("It can read and edit any file on this PC, and asks before running commands.")
        }
        ApprovalMode::FullAccess => {
            tr("It can read and edit any file and run commands on this PC without asking.")
        }
    }
}

// ----------------------------------------------------------- approval card

/// Where an approval request's file sits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApprovalPlace {
    WorkingFolder,
    Outside,
    /// Inside LokalBot's library, runtime, saved tasks or app.
    LokalbotData,
    /// The request names no file.
    None,
}

/// The words of one approval request: a question that names its target,
/// what will happen and where, and the text to review.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApprovalCard {
    pub is_command: bool,
    pub title: String,
    pub effect: String,
    /// The full path, shown with a caution when the file is not in the
    /// working folder.
    pub caution: Option<String>,
    /// Where the result goes when the model is not on this computer.
    pub destination: Option<String>,
    pub preview: String,
    /// "Allow writes for this task", when the policy lets this request be
    /// allowed that way.
    pub task_answer: Option<&'static str>,
}

/// A preview shows this many lines until "Show all".
pub const COLLAPSED_PREVIEW_LINES: usize = 4;

impl ApprovalCard {
    pub fn new(
        request: &ApprovalRequest,
        place: ApprovalPlace,
        target_exists: bool,
        workspace_name: &str,
        remote_host: Option<&str>,
        can_allow_for_task: bool,
    ) -> ApprovalCard {
        let tool = request.tool.to_lowercase();
        let name = request
            .path
            .as_deref()
            .and_then(|p| Path::new(p).file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty());
        // A file tool always names its file; one that does not is shown as the tool it is.
        let named = |template: &str| match &name {
            Some(name) => fill(template, &[name]),
            None => mac("Use %@?", &[&request.tool]),
        };
        // The question says what happens to the file; this line where it is.
        let located = |inside: String| match place {
            ApprovalPlace::LokalbotData => {
                tr("This file is part of LokalBot’s own data.").to_string()
            }
            ApprovalPlace::Outside => mac("This file is outside %@.", &[workspace_name]),
            ApprovalPlace::WorkingFolder | ApprovalPlace::None => inside,
        };
        let mut sends_result = false;
        let mut is_command = false;
        let (title, effect, preview) = match tool.as_str() {
            "write" => (
                named(if target_exists {
                    tr("Replace %@?")
                } else {
                    tr("Create %@?")
                }),
                located(if target_exists {
                    mac("Replaces the file in %@.", &[workspace_name])
                } else {
                    mac("Adds a new file to %@.", &[workspace_name])
                }),
                request
                    .content
                    .clone()
                    .or_else(|| request.summary.clone())
                    .unwrap_or_default(),
            ),
            "edit" => (
                named(tr("Edit %@?")),
                located(mac("Changes the file in %@.", &[workspace_name])),
                request
                    .edits
                    .iter()
                    .map(|edit| {
                        let old = edit.old_text.split('\n').map(|l| format!("- {l}"));
                        let new = edit.new_text.split('\n').map(|l| format!("+ {l}"));
                        old.chain(new).collect::<Vec<_>>().join("\n")
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n"),
            ),
            "read" => {
                sends_result = true;
                (
                    named(tr("Read %@?")),
                    located(mac("Reads the file in %@.", &[workspace_name])),
                    String::new(),
                )
            }
            shell if is_shell_tool(shell) => {
                sends_result = true;
                is_command = true;
                (
                    tr("Run a command?").to_string(),
                    lokalbot_i18n::format(
                        "Runs in {folder} with your account’s access on this PC, so it can change files or use the network.",
                        &[("folder", workspace_name.to_string())],
                    ),
                    request
                        .command
                        .clone()
                        .or_else(|| request.summary.clone())
                        .unwrap_or_default(),
                )
            }
            _ => {
                sends_result = true;
                (
                    mac("Use %@?", &[&request.tool]),
                    tr("Runs this tool with the details below.").to_string(),
                    request
                        .arguments
                        .clone()
                        .or_else(|| request.summary.clone())
                        .unwrap_or_default(),
                )
            }
        };
        let caution = matches!(place, ApprovalPlace::Outside | ApprovalPlace::LokalbotData)
            .then(|| request.path.clone())
            .flatten();
        let destination = sends_result
            .then(|| remote_host.map(|host| mac("The result goes to the model at %@.", &[host])))
            .flatten();
        let task_answer = can_allow_for_task.then(|| {
            if tool == "edit" {
                tr("Allow edits for this task")
            } else {
                tr("Allow writes for this task")
            }
        });
        // A right-to-left translation can begin with the file's or folder's name.
        ApprovalCard {
            is_command,
            title: interface_directional(&title),
            effect: interface_directional(&effect),
            caution,
            destination,
            preview,
            task_answer,
        }
    }

    pub fn preview_lines(&self) -> usize {
        self.preview.split('\n').count()
    }
}

/// "Show all 12 lines"
pub fn show_all(lines: usize) -> String {
    interface_directional(&mac(
        "Show all %lld lines",
        &[&lokalbot_i18n::number(lines)],
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_agent::presentation::Place;
    use lokalbot_agent::transcript::Edit;

    struct Fixture {
        _dir: tempfile::TempDir,
        workspace: std::path::PathBuf,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let workspace = dir.path().join("Agent Workspace");
        std::fs::create_dir_all(&workspace).unwrap();
        Fixture {
            _dir: dir,
            workspace,
        }
    }

    fn meeting(id: &str) -> Option<String> {
        (id == "eb749eed").then(|| "Design review meeting".to_string())
    }

    fn label(f: &Fixture, tool: &str, args: serde_json::Value) -> StepLabel {
        let context = StepContext {
            workspace: &f.workspace,
            workspace_name: "Agent Workspace",
            meeting_title: &meeting,
        };
        step_label(tool, &args.to_string(), &context)
    }

    fn command(f: &Fixture, command: &str) -> StepLabel {
        label(f, "bash", serde_json::json!({ "command": command }))
    }

    #[test]
    fn file_steps_name_the_file_and_its_folder() {
        let f = fixture();
        let read = label(&f, "read", serde_json::json!({"path": "notes/plan.md"}));
        assert_eq!(read.done, "Read plan.md");
        assert_eq!(read.doing, "Reading plan.md");
        assert_eq!(read.detail.as_deref(), Some("Agent Workspace/notes"));
        assert!(!read.begins_with_name);
        let write = serde_json::json!({"path": "reviewed-note.md", "content": "a"});
        assert_eq!(label(&f, "write", write).done, "Wrote reviewed-note.md");
        let path = f.workspace.join("a.rs");
        let edit = serde_json::json!({"file_path": path.to_string_lossy()});
        assert_eq!(label(&f, "Edit", edit).done, "Edited a.rs");
        // A file outside the workspace shows its full folder. The path must be
        // absolute on each system: on Windows "/etc/hosts" is on the current drive.
        let (hosts, folder) = if cfg!(windows) {
            (
                r"C:\Windows\System32\drivers\etc\hosts",
                r"C:\Windows\System32\drivers\etc",
            )
        } else {
            ("/etc/hosts", "/etc")
        };
        let outside = label(&f, "read", serde_json::json!({ "path": hosts }));
        assert_eq!(outside.done, "Read hosts");
        assert_eq!(outside.detail.as_deref(), Some(folder));
    }

    #[test]
    fn library_lookups_say_what_they_looked_up() {
        let f = fixture();
        let search = command(&f, "lokalbot-cli search \"design review\" --limit 20");
        assert_eq!(search.done, "Searched meeting library");
        assert_eq!(search.doing, "Searching meeting library");
        assert_eq!(search.detail.as_deref(), Some("design review"));
        let get = command(&f, "lokalbot-cli get eb749eed --include metadata,summary");
        assert_eq!(get.done, "Read meeting notes");
        assert_eq!(get.detail.as_deref(), Some("Design review meeting"));
        assert_eq!(command(&f, "lokalbot-cli get latest").detail, None);
        let list = command(&f, "lokalbot-cli list --limit 10 --query=atlas");
        assert_eq!(list.done, "Listed meetings");
        assert_eq!(list.detail.as_deref(), Some("atlas"));
        assert_eq!(command(&f, "lokalbot-cli brief").done, "Read your briefing");
        assert_eq!(
            command(&f, "lokalbot-cli actions --owner me --table").done,
            "Read action items"
        );
        assert_eq!(
            command(&f, "lokalbot-cli search --limit 5 release")
                .detail
                .as_deref(),
            Some("release")
        );
        // A command without a name of its own shows its text.
        let people = command(&f, "lokalbot-cli people \"Ana Petrović\"");
        assert_eq!(people.done, "Ran a command");
        assert_eq!(
            people.detail.as_deref(),
            Some("lokalbot-cli people \"Ana Petrović\"")
        );
    }

    /// A label never hides what ran: anything a shell could chain or redirect
    /// is a command, shown with its text.
    #[test]
    fn other_commands_show_their_text() {
        let f = fixture();
        for text in [
            "ls -la",
            "lokalbot-cli list > notes.md",
            "lokalbot-cli brief && rm -rf build",
            "mkdir -p exports && lokalbot-cli list --table > exports/open-actions.md",
            "lokalbot-cli config set autoSummarize false",
            "lokalbot-cli",
        ] {
            let label = command(&f, text);
            assert_eq!(label.done, "Ran a command", "{text}");
            assert_eq!(label.doing, "Running a command", "{text}");
            assert_eq!(label.detail.as_deref(), Some(text));
        }
        assert_eq!(
            command(&f, "echo one\necho two").detail.as_deref(),
            Some("echo one")
        );
        let long = "a".repeat(300);
        assert_eq!(
            command(&f, &long).detail.map(|d| d.chars().count()),
            Some(120)
        );
        assert_eq!(label(&f, "bash", serde_json::json!({})).detail, None);
        // PowerShell commands read the same way.
        let shell = label(
            &f,
            "powershell",
            serde_json::json!({"command": "Get-ChildItem"}),
        );
        assert_eq!(shell.done, "Ran a command");
    }

    #[test]
    fn other_tools_are_named() {
        let f = fixture();
        let tool = label(&f, "mcp_search", serde_json::json!({"q": "x"}));
        assert_eq!(tool.done, "Used mcp_search");
        assert_eq!(tool.doing, "Using mcp_search");
        // A file tool without a path has nothing to name.
        assert_eq!(label(&f, "read", serde_json::json!({})).done, "Used read");
    }

    #[test]
    fn step_text_follows_its_state() {
        let f = fixture();
        let label = label(&f, "write", serde_json::json!({"path": "note.md"}));
        assert_eq!(label.text(ToolStatus::Succeeded, true), "Wrote note.md");
        assert_eq!(label.text(ToolStatus::Running, true), "Writing note.md…");
        assert_eq!(
            label.text(ToolStatus::Failed, false),
            "Writing note.md · failed"
        );
        // Still running when its task stopped: it never finished.
        assert_eq!(
            label.text(ToolStatus::Running, false),
            "Writing note.md · not finished"
        );
    }

    #[test]
    fn the_summary_names_each_different_step_once() {
        let labels: Vec<(String, bool)> = [
            "Searched meeting library",
            "Read meeting notes",
            "Read meeting notes",
            "Wrote README.md",
        ]
        .iter()
        .map(|t| (t.to_string(), false))
        .collect();
        assert_eq!(
            steps_summary(&labels, true),
            "Searched meeting library, read meeting notes, wrote README.md"
        );
        assert_eq!(
            steps_summary(&labels, false),
            "Searched meeting library, Read meeting notes, Wrote README.md"
        );
        // Where a translation puts the file name first, its capitals stay.
        let german = [
            ("Gelesen".to_string(), false),
            ("README.md geschrieben".to_string(), true),
        ];
        assert_eq!(
            steps_summary(&german, true),
            "Gelesen, README.md geschrieben"
        );
        assert_eq!(steps_summary(&[], true), "");
        assert_eq!(steps_count(1), "1 step");
        assert_eq!(steps_count(4), "4 steps");
    }

    #[test]
    fn status_words() {
        assert_eq!(status_title(TaskStatus::NotStarted), Some("Not started"));
        assert_eq!(status_title(TaskStatus::Saved), None);
        assert_eq!(status_title(TaskStatus::Working), Some("Working…"));
        assert_eq!(
            status_title(TaskStatus::NeedsApproval(1)),
            Some("Needs approval")
        );
        assert_eq!(status_line(TaskStatus::Stopped).as_deref(), Some("Stopped"));
        let done = |changed_files| TaskStatus::Done { changed_files };
        assert_eq!(status_line(done(0)).as_deref(), Some("Done"));
        assert_eq!(
            status_line(done(1)).as_deref(),
            Some("Done · 1 file changed")
        );
        assert_eq!(
            status_line(done(3)).as_deref(),
            Some("Done · 3 files changed")
        );
        assert_eq!(status_title(done(3)), Some("Done"));
    }

    #[test]
    fn a_changed_file_says_what_happened_how_long_and_where() {
        let f = fixture();
        let target = FileTarget::resolve("reviewed-note.md", &f.workspace, "Agent Workspace");
        let file = |change, line_count| ChangedFile {
            target: target.clone(),
            change,
            line_count,
            step_id: "s".into(),
        };
        assert_eq!(
            changed_file_detail(&file(Change::Created, Some(3))),
            "New file · 3 lines · Agent Workspace"
        );
        assert_eq!(
            changed_file_detail(&file(Change::Edited, Some(1))),
            "Edited · 1 line · Agent Workspace"
        );
        assert_eq!(
            changed_file_detail(&file(Change::Replaced, None)),
            "Replaced · Agent Workspace"
        );
        // History does not say whether a written file was there before.
        assert_eq!(
            changed_file_detail(&file(Change::Written, Some(2))),
            "2 lines · Agent Workspace"
        );
        assert_eq!(target.place, Place::WorkingFolder);
    }

    #[test]
    fn task_list_words() {
        use chrono::TimeZone as _;
        assert_eq!(section_title(SectionKind::Today), "Today");
        assert_eq!(section_title(SectionKind::Earlier), "Earlier");
        let day = chrono::NaiveDate::from_ymd_opt(2026, 11, 7).unwrap();
        assert_eq!(section_title(SectionKind::Day(day)), "Nov 7, 2026");
        let now = Local
            .with_ymd_and_hms(2026, 11, 11, 12, 0, 0)
            .single()
            .unwrap();
        let morning = Local
            .with_ymd_and_hms(2026, 11, 11, 9, 5, 0)
            .single()
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(row_time(morning, false, now).as_deref(), Some("9:05 AM"));
        let earlier = Local
            .with_ymd_and_hms(2026, 11, 3, 9, 5, 0)
            .single()
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(row_time(earlier, true, now).as_deref(), Some("Nov 3, 2026"));
        assert_eq!(row_time(DateTime::<Utc>::MIN_UTC, false, now), None);
    }

    fn request(f: &Fixture, tool: &str, path: Option<&str>) -> ApprovalRequest {
        ApprovalRequest {
            id: "r".into(),
            tool: tool.into(),
            workspace: Some(f.workspace.to_string_lossy().into_owned()),
            path: path.map(str::to_string),
            command: None,
            content: None,
            edits: Vec::new(),
            summary: None,
            is_truncated: false,
            arguments: None,
        }
    }

    fn card(
        request: &ApprovalRequest,
        place: ApprovalPlace,
        exists: bool,
        remote: Option<&str>,
        task: bool,
    ) -> ApprovalCard {
        ApprovalCard::new(request, place, exists, "Agent Workspace", remote, task)
    }

    #[test]
    fn a_write_asks_to_create_or_replace_and_names_the_file() {
        let f = fixture();
        let path = f.workspace.join("reviewed-note.md");
        let mut write = request(&f, "write", Some(&path.to_string_lossy()));
        write.content = Some("one\ntwo\nthree\nfour\nfive".into());
        let create = card(&write, ApprovalPlace::WorkingFolder, false, None, true);
        assert_eq!(create.title, "Create reviewed-note.md?");
        assert_eq!(create.effect, "Adds a new file to Agent Workspace.");
        assert_eq!(create.caution, None);
        assert_eq!(create.destination, None);
        assert_eq!(create.preview_lines(), 5);
        assert_eq!(create.task_answer, Some("Allow writes for this task"));
        let replace = card(&write, ApprovalPlace::WorkingFolder, true, None, false);
        assert_eq!(replace.title, "Replace reviewed-note.md?");
        assert_eq!(replace.effect, "Replaces the file in Agent Workspace.");
        assert_eq!(
            replace.task_answer, None,
            "only offered when the policy allows it for this request"
        );
        let mut nameless = request(&f, "write", None);
        nameless.content = Some("x".into());
        assert_eq!(
            card(&nameless, ApprovalPlace::None, false, None, false).title,
            "Use write?"
        );
        assert_eq!(show_all(12), "Show all 12 lines");
    }

    #[test]
    fn a_file_outside_the_working_folder_shows_its_full_path_as_a_caution() {
        let f = fixture();
        let mut write = request(&f, "write", Some("/home/someone/Desktop/note.md"));
        write.content = Some("x".into());
        let outside = card(&write, ApprovalPlace::Outside, false, None, false);
        assert_eq!(outside.title, "Create note.md?");
        assert_eq!(outside.effect, "This file is outside Agent Workspace.");
        assert_eq!(
            outside.caution.as_deref(),
            Some("/home/someone/Desktop/note.md")
        );
        let data = card(
            &request(&f, "edit", Some("/lib/LokalBot/meta.json")),
            ApprovalPlace::LokalbotData,
            false,
            None,
            false,
        );
        assert_eq!(data.title, "Edit meta.json?");
        assert_eq!(data.effect, "This file is part of LokalBot’s own data.");
        assert_eq!(data.caution.as_deref(), Some("/lib/LokalBot/meta.json"));
        let read = card(
            &request(&f, "read", Some("/etc/hosts")),
            ApprovalPlace::Outside,
            false,
            Some("api.example.com"),
            false,
        );
        assert_eq!(read.title, "Read hosts?");
        assert_eq!(
            read.destination.as_deref(),
            Some("The result goes to the model at api.example.com.")
        );
    }

    #[test]
    fn an_edit_shows_what_leaves_and_what_arrives() {
        let f = fixture();
        let path = f.workspace.join("a.md");
        let mut edit = request(&f, "edit", Some(&path.to_string_lossy()));
        edit.edits = vec![Edit {
            old_text: "old\nline".into(),
            new_text: "new".into(),
        }];
        let card = card(&edit, ApprovalPlace::WorkingFolder, false, None, true);
        assert_eq!(card.title, "Edit a.md?");
        assert_eq!(card.effect, "Changes the file in Agent Workspace.");
        assert_eq!(card.preview, "- old\n- line\n+ new");
        assert_eq!(card.task_answer, Some("Allow edits for this task"));
    }

    #[test]
    fn a_command_and_other_tools_show_exactly_what_will_run() {
        let f = fixture();
        let mut bash = request(&f, "bash", None);
        bash.command = Some("mkdir -p exports && lokalbot-cli list > exports/a.md".into());
        let command = card(&bash, ApprovalPlace::None, false, None, false);
        assert_eq!(command.title, "Run a command?");
        assert!(command.is_command);
        assert_eq!(
            command.effect,
            "Runs in Agent Workspace with your account’s access on this PC, so it can change files or use the network."
        );
        assert_eq!(
            command.preview,
            "mkdir -p exports && lokalbot-cli list > exports/a.md"
        );
        assert_eq!(command.task_answer, None);
        assert_eq!(
            command.destination, None,
            "nothing leaves with a local model"
        );
        assert_eq!(
            card(
                &bash,
                ApprovalPlace::None,
                false,
                Some("ChatGPT plan"),
                false
            )
            .destination
            .as_deref(),
            Some("The result goes to the model at ChatGPT plan.")
        );
        let mut tool = request(&f, "mcp_search", None);
        tool.arguments = Some("{\"q\":\"x\"}".into());
        let tool = card(&tool, ApprovalPlace::None, false, None, false);
        assert_eq!(tool.title, "Use mcp_search?");
        assert_eq!(tool.preview, "{\"q\":\"x\"}");
        // A write's text stays here until the agent reads something back.
        let mut write = request(&f, "write", Some("/a/b.md"));
        write.content = Some("x".into());
        assert_eq!(
            card(
                &write,
                ApprovalPlace::Outside,
                false,
                Some("api.example.com"),
                false
            )
            .destination,
            None
        );
    }

    #[test]
    fn each_level_says_what_runs_on_its_own_and_what_still_asks() {
        assert_eq!(
            level_detail(ApprovalMode::AskBeforeChanges, "Agent Workspace"),
            "Reads files in Agent Workspace without asking, and looks things up in your LokalBot library when the model runs on this PC. Asks before anything else."
        );
        let chips: Vec<&str> = ApprovalMode::ALL.iter().map(|m| chip_title(*m)).collect();
        assert_eq!(
            chips,
            [
                "Asks first",
                "Reads any file",
                "Edits any file",
                "Full access"
            ]
        );
        let levels: Vec<&str> = ApprovalMode::ALL.iter().map(|m| level_title(*m)).collect();
        assert_eq!(
            levels,
            ["Ask first", "Read any file", "Edit any file", "Full access"]
        );
        let cautious: Vec<ApprovalMode> = ApprovalMode::ALL
            .into_iter()
            .filter(|m| needs_caution(*m))
            .collect();
        assert_eq!(cautious, [ApprovalMode::FullAccess]);
        assert!(level_detail(ApprovalMode::FullAccess, "W").contains("without asking"));
    }
}
