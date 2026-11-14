//! The rules behind what the Agent page shows (`AgentPresentation.swift`):
//! where a step's file sits, which files a turn changed, how a conversation
//! folds for reading, where a task stands, and how the task list groups.
//! The words live with the page; these rules hold no text, so they are tested
//! without a window.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Datelike as _, Local, NaiveDate, Utc};
use uuid::Uuid;

use crate::policy::{canonical_path, is_within, lexically_normalized};
use crate::session::SessionState;
use crate::transcript::{ToolStatus, TranscriptItem};

// ------------------------------------------------------------------ files

/// The fields of a tool call's arguments the page reads.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StepArguments {
    pub path: Option<String>,
    pub command: Option<String>,
    pub content: Option<String>,
}

impl StepArguments {
    pub fn parse(args_json: &str) -> StepArguments {
        let object: serde_json::Value = serde_json::from_str(args_json).unwrap_or_default();
        let text = |key: &str| object.get(key).and_then(|v| v.as_str()).map(str::to_string);
        StepArguments {
            path: text("path").or_else(|| text("file_path")),
            command: text("command"),
            content: text("content"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Place {
    WorkingFolder,
    Outside,
}

/// Where a file an agent step names sits, for the words beside it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileTarget {
    pub path: PathBuf,
    pub name: String,
    /// "Agent Workspace", "Agent Workspace/drafts" or "~/Desktop".
    pub folder: String,
    pub place: Place,
}

impl FileTarget {
    /// Resolves a path the way the agent's file tools do: a leading `@` is
    /// dropped, `~` is the home folder, and a relative path starts at the
    /// working folder. Links are followed, so a link that leaves the working
    /// folder is named for where it really points.
    pub fn resolve(path: &str, workspace: &Path, workspace_name: &str) -> FileTarget {
        let raw = resolve_tool_path(path, workspace);
        let resolved = canonical_path(&raw).unwrap_or_else(|| lexically_normalized(&raw));
        let root = canonical_path(workspace).unwrap_or_else(|| lexically_normalized(workspace));
        let name = resolved
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let parent = resolved.parent().map(Path::to_path_buf).unwrap_or_default();
        if !is_within(&parent, &root) {
            return FileTarget {
                folder: abbreviated(&parent),
                path: resolved,
                name,
                place: Place::Outside,
            };
        }
        let mut folder = vec![workspace_name.to_string()];
        if let Ok(inner) = parent.strip_prefix(&root) {
            folder.extend(
                inner
                    .components()
                    .map(|c| c.as_os_str().to_string_lossy().into_owned()),
            );
        }
        FileTarget {
            path: resolved,
            name,
            folder: folder.join("/"),
            place: Place::WorkingFolder,
        }
    }
}

/// The path a file tool would use: `@` dropped, `~` expanded, a relative
/// path taken from the working folder.
pub fn resolve_tool_path(path: &str, workspace: &Path) -> PathBuf {
    let text = path.trim();
    let text = text.strip_prefix('@').unwrap_or(text);
    let home = lokalbot_core::files::home_dir();
    let expanded = match (text, &home) {
        ("~", Some(home)) => home.clone(),
        (text, Some(home)) if text.starts_with("~/") || text.starts_with("~\\") => {
            home.join(&text[2..])
        }
        (text, _) => PathBuf::from(text),
    };
    if expanded.is_absolute() {
        expanded
    } else {
        workspace.join(expanded)
    }
}

/// A folder with the home folder shown as `~`.
fn abbreviated(folder: &Path) -> String {
    if let Some(home) = lokalbot_core::files::home_dir()
        && let Ok(inner) = folder.strip_prefix(&home)
    {
        let inner = inner.to_string_lossy();
        return if inner.is_empty() {
            "~".into()
        } else {
            format!("~{}{inner}", std::path::MAIN_SEPARATOR)
        };
    }
    folder.display().to_string()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
    /// The file did not exist before the agent wrote it.
    Created,
    /// The agent wrote over a file that was there.
    Replaced,
    /// The agent changed part of a file.
    Edited,
    /// A write restored from saved history, where the earlier state is unknown.
    Written,
}

/// A file the agent wrote or edited in one turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChangedFile {
    pub target: FileTarget,
    pub change: Change,
    /// Lines of the text a write put in the file.
    pub line_count: Option<usize>,
    /// The step that changed it last, for opening its result.
    pub step_id: String,
}

impl ChangedFile {
    /// The files changed by the succeeded write and edit steps in `items`, in
    /// the order they were first changed. `existed_before` says, for a write
    /// step seen as it started, whether its file was already there.
    pub fn list(
        items: &[TranscriptItem],
        workspace: &Path,
        workspace_name: &str,
        existed_before: impl Fn(&str) -> Option<bool>,
    ) -> Vec<ChangedFile> {
        let mut files: Vec<ChangedFile> = Vec::new();
        for item in items {
            let TranscriptItem::Tool {
                id,
                name,
                args_json,
                status: ToolStatus::Succeeded,
                ..
            } = item
            else {
                continue;
            };
            let tool = name.to_lowercase();
            if tool != "write" && tool != "edit" {
                continue;
            }
            let arguments = StepArguments::parse(args_json);
            let Some(path) = arguments.path else { continue };
            let target = FileTarget::resolve(&path, workspace, workspace_name);
            let is_write = tool == "write";
            let lines = if is_write {
                arguments.content.as_deref().map(Self::line_count)
            } else {
                None
            };
            let change = if is_write {
                match existed_before(id) {
                    Some(true) => Change::Replaced,
                    Some(false) => Change::Created,
                    None => Change::Written,
                }
            } else {
                Change::Edited
            };
            if let Some(file) = files.iter_mut().find(|f| f.target.path == target.path) {
                // A file the agent made stays new however often it is touched again.
                if file.change != Change::Created {
                    file.change = change;
                }
                if lines.is_some() {
                    file.line_count = lines;
                }
                file.step_id = id.clone();
            } else {
                files.push(ChangedFile {
                    target,
                    change,
                    line_count: lines,
                    step_id: id.clone(),
                });
            }
        }
        files
    }

    pub fn line_count(text: &str) -> usize {
        if text.is_empty() {
            return 0;
        }
        text.strip_suffix('\n').unwrap_or(text).split('\n').count()
    }
}

// ----------------------------------------------------------------- layout

/// A run of tool steps shown as one line that opens to a row per step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StepGroup {
    pub id: String,
    /// The steps and, in a finished turn, what the agent said between them.
    pub entries: Vec<TranscriptItem>,
    /// A finished turn folds all its work into one counted line.
    pub is_turn_summary: bool,
}

impl StepGroup {
    pub fn steps(&self) -> impl Iterator<Item = &TranscriptItem> {
        self.entries.iter().filter(|item| is_step(item))
    }

    pub fn step_count(&self) -> usize {
        self.steps().count()
    }

    pub fn has_failure(&self) -> bool {
        self.entries.iter().any(|item| {
            matches!(
                item,
                TranscriptItem::Tool {
                    status: ToolStatus::Failed,
                    ..
                }
            )
        })
    }
}

/// What the conversation shows, top to bottom. It regroups the transcript
/// for reading and never reorders or drops a message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Block {
    User(TranscriptItem),
    /// What the agent says while it works, shown in full.
    Said(TranscriptItem),
    /// The last thing the agent said in a finished turn, with that turn's steps.
    Answer {
        item: TranscriptItem,
        steps: Vec<TranscriptItem>,
    },
    Notice(TranscriptItem),
    Steps(StepGroup),
    /// The step in progress.
    Live(TranscriptItem),
}

impl Block {
    pub fn id(&self) -> String {
        match self {
            Block::User(item)
            | Block::Said(item)
            | Block::Answer { item, .. }
            | Block::Notice(item)
            | Block::Live(item) => item.id().to_string(),
            Block::Steps(group) => format!("steps.{}", group.id),
        }
    }

    /// Everything a search of the task can match in this block.
    pub fn searchable_text(&self) -> String {
        match self {
            Block::User(item)
            | Block::Said(item)
            | Block::Answer { item, .. }
            | Block::Notice(item)
            | Block::Live(item) => item.searchable_text(),
            Block::Steps(group) => group
                .entries
                .iter()
                .map(TranscriptItem::searchable_text)
                .collect::<Vec<_>>()
                .join("\n"),
        }
    }
}

fn is_step(item: &TranscriptItem) -> bool {
    matches!(item, TranscriptItem::Tool { .. })
}

/// `is_working` says the last turn is still going: its words stay in full
/// and each run of steps folds on its own. Every earlier turn, and the last
/// one once it ends, folds its work into one line above its answer.
pub fn layout(items: &[TranscriptItem], is_working: bool) -> Vec<Block> {
    let mut turns: Vec<Vec<TranscriptItem>> = Vec::new();
    for item in items {
        match item {
            // The approval card above the composer owns these.
            TranscriptItem::Approval(_) => {}
            TranscriptItem::User { .. } => turns.push(vec![item.clone()]),
            _ => match turns.last_mut() {
                Some(turn) => turn.push(item.clone()),
                None => turns.push(vec![item.clone()]),
            },
        }
    }
    let count = turns.len();
    turns
        .into_iter()
        .enumerate()
        .flat_map(|(index, turn)| layout_turn(turn, !(is_working && index + 1 == count)))
        .collect()
}

fn layout_turn(turn: Vec<TranscriptItem>, finished: bool) -> Vec<Block> {
    let mut blocks = Vec::new();
    let mut body = turn.as_slice();
    if let Some((first @ TranscriptItem::User { .. }, rest)) = body.split_first() {
        blocks.push(Block::User(first.clone()));
        body = rest;
    }
    // The answer is the last thing the agent said, when no step follows it.
    let last_said = body
        .iter()
        .rposition(|item| matches!(item, TranscriptItem::Assistant { .. }));
    if finished
        && let Some(last_said) = last_said
        && !body[last_said + 1..].iter().any(is_step)
    {
        let mut pending: Vec<TranscriptItem> = Vec::new();
        let fold = |pending: &mut Vec<TranscriptItem>, blocks: &mut Vec<Block>| {
            if pending.iter().any(is_step) {
                blocks.push(Block::Steps(StepGroup {
                    id: pending[0].id().to_string(),
                    entries: std::mem::take(pending),
                    is_turn_summary: true,
                }));
            } else {
                blocks.extend(pending.drain(..).map(Block::Said));
            }
        };
        // A notice (a denial, an error) is never folded away.
        for item in &body[..last_said] {
            if matches!(item, TranscriptItem::Notice { .. }) {
                fold(&mut pending, &mut blocks);
                blocks.push(Block::Notice(item.clone()));
            } else {
                pending.push(item.clone());
            }
        }
        fold(&mut pending, &mut blocks);
        blocks.push(Block::Answer {
            item: body[last_said].clone(),
            steps: body.iter().filter(|item| is_step(item)).cloned().collect(),
        });
        blocks.extend(body[last_said + 1..].iter().cloned().map(Block::Notice));
        return blocks;
    }
    let mut run: Vec<TranscriptItem> = Vec::new();
    let fold = |run: &mut Vec<TranscriptItem>, blocks: &mut Vec<Block>| {
        let live = (!finished
            && matches!(
                run.last(),
                Some(TranscriptItem::Tool {
                    status: ToolStatus::Running,
                    ..
                })
            ))
        .then(|| run.pop())
        .flatten();
        if let Some(first) = run.first() {
            blocks.push(Block::Steps(StepGroup {
                id: first.id().to_string(),
                entries: std::mem::take(run),
                is_turn_summary: false,
            }));
        }
        blocks.extend(live.map(Block::Live));
    };
    for item in body {
        match item {
            TranscriptItem::Tool { .. } => run.push(item.clone()),
            TranscriptItem::Assistant { .. } => {
                fold(&mut run, &mut blocks);
                blocks.push(Block::Said(item.clone()));
            }
            TranscriptItem::Notice { .. } => {
                fold(&mut run, &mut blocks);
                blocks.push(Block::Notice(item.clone()));
            }
            TranscriptItem::User { .. } | TranscriptItem::Approval(_) => {}
        }
    }
    fold(&mut run, &mut blocks);
    blocks
}

// ----------------------------------------------------------------- status

/// Where a task stands, for its list row and the toolbar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskStatus {
    NotStarted,
    /// A saved conversation with nothing going on.
    Saved,
    Starting,
    Working,
    NeedsApproval(usize),
    NeedsAttention,
    Stopped,
    Done {
        changed_files: usize,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    Quiet,
    Working,
    Attention,
    Done,
}

impl TaskStatus {
    pub fn resolve(
        state: &SessionState,
        pending_approvals: usize,
        has_turn_error: bool,
        was_stopped: bool,
        items: &[TranscriptItem],
        has_saved_conversation: bool,
        changed_files: usize,
    ) -> TaskStatus {
        if pending_approvals > 0 {
            return TaskStatus::NeedsApproval(pending_approvals);
        }
        if has_turn_error {
            return TaskStatus::NeedsAttention;
        }
        match state {
            SessionState::Failed(_) => TaskStatus::NeedsAttention,
            SessionState::Starting => TaskStatus::Starting,
            SessionState::Running => TaskStatus::Working,
            SessionState::Idle | SessionState::Ready => {
                if items.is_empty() {
                    return if has_saved_conversation {
                        TaskStatus::Saved
                    } else {
                        TaskStatus::NotStarted
                    };
                }
                if was_stopped {
                    return TaskStatus::Stopped;
                }
                // A task is done while its agent is still open and its last
                // turn ended with an answer.
                let last = items
                    .iter()
                    .rev()
                    .find(|item| !matches!(item, TranscriptItem::Notice { .. }));
                if *state == SessionState::Ready
                    && matches!(
                        last,
                        Some(TranscriptItem::Assistant {
                            is_streaming: false,
                            ..
                        })
                    )
                {
                    return TaskStatus::Done { changed_files };
                }
                TaskStatus::Saved
            }
        }
    }

    pub fn tone(self) -> Tone {
        match self {
            TaskStatus::NotStarted | TaskStatus::Saved | TaskStatus::Stopped => Tone::Quiet,
            TaskStatus::Starting | TaskStatus::Working => Tone::Working,
            TaskStatus::NeedsApproval(_) | TaskStatus::NeedsAttention => Tone::Attention,
            TaskStatus::Done { .. } => Tone::Done,
        }
    }
}

/// The steps of the last turn: everything from the last message the user sent.
pub fn last_turn(items: &[TranscriptItem]) -> &[TranscriptItem] {
    let start = items
        .iter()
        .rposition(|item| matches!(item, TranscriptItem::User { .. }))
        .unwrap_or(0);
    &items[start..]
}

// -------------------------------------------------------------- task list

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SectionKind {
    Pinned,
    Today,
    Yesterday,
    Day(NaiveDate),
    /// Tasks from before task times were saved.
    Earlier,
}

/// One task as the list groups it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ListEntry {
    pub id: Uuid,
    pub modified_at: DateTime<Utc>,
    pub is_pinned: bool,
}

/// The task list's groups: pinned tasks, then one group per day, newest first.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TaskListSection {
    pub kind: SectionKind,
    pub ids: Vec<Uuid>,
}

impl TaskListSection {
    /// Pinned entries keep the order they come in; the rest go newest first.
    pub fn make(entries: &[ListEntry], now: DateTime<Local>) -> Vec<TaskListSection> {
        let mut sections: Vec<TaskListSection> = Vec::new();
        let mut add =
            |id: Uuid, kind: SectionKind| match sections.iter_mut().find(|s| s.kind == kind) {
                Some(section) => section.ids.push(id),
                None => sections.push(TaskListSection {
                    kind,
                    ids: vec![id],
                }),
            };
        for entry in entries.iter().filter(|e| e.is_pinned) {
            add(entry.id, SectionKind::Pinned);
        }
        let mut rest: Vec<&ListEntry> = entries.iter().filter(|e| !e.is_pinned).collect();
        rest.sort_by_key(|entry| std::cmp::Reverse(entry.modified_at));
        let today = now.date_naive();
        for entry in rest {
            if entry.modified_at == DateTime::<Utc>::MIN_UTC {
                add(entry.id, SectionKind::Earlier);
                continue;
            }
            let day = entry.modified_at.with_timezone(&Local).date_naive();
            let age = today.num_days_from_ce() - day.num_days_from_ce();
            let kind = match age {
                ..=0 => SectionKind::Today,
                1 => SectionKind::Yesterday,
                _ => SectionKind::Day(day),
            };
            add(entry.id, kind);
        }
        sections
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;
    use std::collections::HashMap;

    struct Fixture {
        _dir: tempfile::TempDir,
        root: PathBuf,
        workspace: PathBuf,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = dunce::canonicalize(dir.path()).unwrap();
        let workspace = root.join("Agent Workspace");
        std::fs::create_dir_all(&workspace).unwrap();
        Fixture {
            _dir: dir,
            root,
            workspace,
        }
    }

    fn step(id: &str, tool: &str, args: serde_json::Value, status: ToolStatus) -> TranscriptItem {
        TranscriptItem::Tool {
            id: id.into(),
            name: tool.into(),
            args_json: args.to_string(),
            output: String::new(),
            status,
        }
    }

    fn done(id: &str, tool: &str, args: serde_json::Value) -> TranscriptItem {
        step(id, tool, args, ToolStatus::Succeeded)
    }

    fn read(id: &str, path: &str) -> TranscriptItem {
        done(id, "read", serde_json::json!({ "path": path }))
    }

    fn said(id: &str, text: &str) -> TranscriptItem {
        TranscriptItem::Assistant {
            id: id.into(),
            text: text.into(),
            is_streaming: false,
        }
    }

    fn notice(id: &str, text: &str, is_error: bool) -> TranscriptItem {
        TranscriptItem::Notice {
            id: id.into(),
            text: text.into(),
            is_error,
        }
    }

    fn question() -> TranscriptItem {
        TranscriptItem::User {
            id: "u1".into(),
            text: "Draft a follow-up".into(),
        }
    }

    fn ids(blocks: &[Block]) -> Vec<String> {
        blocks.iter().map(Block::id).collect()
    }

    fn step_ids(group: &StepGroup) -> Vec<&str> {
        group.steps().map(TranscriptItem::id).collect()
    }

    #[test]
    fn a_working_turn_shows_words_in_full_and_folds_each_run_of_steps() {
        let items = [
            question(),
            done(
                "t1",
                "bash",
                serde_json::json!({"command": "lokalbot-cli search design"}),
            ),
            done(
                "t2",
                "bash",
                serde_json::json!({"command": "lokalbot-cli get eb749eed"}),
            ),
            said("a1", "Found it."),
            step(
                "t3",
                "bash",
                serde_json::json!({"command": "lokalbot-cli actions"}),
                ToolStatus::Running,
            ),
        ];
        let blocks = layout(&items, true);
        assert_eq!(ids(&blocks), ["u1", "steps.t1", "a1", "t3"]);
        let (Block::Steps(run), Block::Said(_), Block::Live(live)) =
            (&blocks[1], &blocks[2], &blocks[3])
        else {
            panic!("{blocks:?}")
        };
        assert_eq!(step_ids(run), ["t1", "t2"]);
        assert!(!run.is_turn_summary);
        assert_eq!(live.id(), "t3");
    }

    #[test]
    fn a_step_in_progress_leaves_its_run_and_rejoins_when_done() {
        let running = layout(
            &[
                question(),
                read("t1", "a"),
                step(
                    "t2",
                    "read",
                    serde_json::json!({"path": "b"}),
                    ToolStatus::Running,
                ),
            ],
            true,
        );
        assert_eq!(ids(&running), ["u1", "steps.t1", "t2"]);
        let finished = layout(&[question(), read("t1", "a"), read("t2", "b")], true);
        assert_eq!(ids(&finished), ["u1", "steps.t1"]);
        // The only step of a run shows live with no folded line above it.
        let alone = layout(
            &[
                question(),
                step(
                    "t1",
                    "read",
                    serde_json::json!({"path": "a"}),
                    ToolStatus::Running,
                ),
            ],
            true,
        );
        assert_eq!(ids(&alone), ["u1", "t1"]);
    }

    #[test]
    fn a_finished_turn_folds_its_work_into_one_line_above_the_answer() {
        let items = [
            question(),
            done(
                "t1",
                "bash",
                serde_json::json!({"command": "lokalbot-cli search design"}),
            ),
            said("a1", "Found it."),
            done(
                "t2",
                "bash",
                serde_json::json!({"command": "lokalbot-cli actions"}),
            ),
            done(
                "t3",
                "write",
                serde_json::json!({"path": "reviewed-note.md", "content": "x"}),
            ),
            said("a2", "Here's the follow-up."),
        ];
        let blocks = layout(&items, false);
        assert_eq!(ids(&blocks), ["u1", "steps.t1", "a2"]);
        let (Block::Steps(work), Block::Answer { item, steps }) = (&blocks[1], &blocks[2]) else {
            panic!("{blocks:?}")
        };
        assert!(work.is_turn_summary);
        assert_eq!(step_ids(work), ["t1", "t2", "t3"]);
        // What the agent said between steps stays inside the fold, in order.
        let entries: Vec<&str> = work.entries.iter().map(TranscriptItem::id).collect();
        assert_eq!(entries, ["t1", "a1", "t2", "t3"]);
        assert_eq!(item.id(), "a2");
        let answered: Vec<&str> = steps.iter().map(TranscriptItem::id).collect();
        assert_eq!(answered, ["t1", "t2", "t3"]);
        // Nothing is dropped: every message is in exactly one block.
        assert!(
            blocks
                .iter()
                .any(|b| b.searchable_text().contains("Found it."))
        );
    }

    #[test]
    fn earlier_turns_fold_while_the_last_one_works() {
        let items = [
            question(),
            read("t1", "a"),
            said("a1", "Done."),
            TranscriptItem::User {
                id: "u2".into(),
                text: "Shorter".into(),
            },
            read("t2", "b"),
            TranscriptItem::Assistant {
                id: "a2".into(),
                text: "Working on it".into(),
                is_streaming: true,
            },
        ];
        let blocks = layout(&items, true);
        assert_eq!(
            ids(&blocks),
            ["u1", "steps.t1", "a1", "u2", "steps.t2", "a2"]
        );
        assert!(matches!(blocks[2], Block::Answer { .. }));
        assert!(matches!(blocks[5], Block::Said(_)));
    }

    #[test]
    fn an_answer_without_steps_has_no_folded_line() {
        let blocks = layout(&[question(), said("a1", "Hello.")], false);
        assert_eq!(ids(&blocks), ["u1", "a1"]);
        let Block::Answer { steps, .. } = &blocks[1] else {
            panic!("{blocks:?}")
        };
        assert!(steps.is_empty());
    }

    #[test]
    fn notices_are_never_folded_away() {
        let items = [
            question(),
            read("t1", "a"),
            notice(
                "n1",
                "You denied this write request. Nothing changed.",
                false,
            ),
            read("t2", "b"),
            said("a1", "I left the file alone."),
            notice("n2", "401", true),
        ];
        let blocks = layout(&items, false);
        assert_eq!(
            ids(&blocks),
            ["u1", "steps.t1", "n1", "steps.t2", "a1", "n2"]
        );
    }

    #[test]
    fn a_stopped_turn_without_an_answer_keeps_its_words_and_shows_no_live_step() {
        let items = [
            question(),
            said("a1", "Looking."),
            read("t1", "a"),
            step(
                "t2",
                "read",
                serde_json::json!({"path": "b"}),
                ToolStatus::Running,
            ),
        ];
        let blocks = layout(&items, false);
        assert_eq!(ids(&blocks), ["u1", "a1", "steps.t1"]);
        let Block::Steps(run) = &blocks[2] else {
            panic!("{blocks:?}")
        };
        assert_eq!(run.step_count(), 2);
        assert!(!run.is_turn_summary);
    }

    #[test]
    fn restored_history_without_a_leading_question_still_lays_out() {
        let blocks = layout(&[notice("n1", "Resumed", false), said("a1", "Hi")], false);
        assert_eq!(ids(&blocks), ["n1", "a1"]);
        assert!(layout(&[], true).is_empty());
    }

    #[test]
    fn a_failed_step_marks_its_run() {
        let blocks = layout(
            &[
                question(),
                step(
                    "t1",
                    "read",
                    serde_json::json!({"path": "a"}),
                    ToolStatus::Failed,
                ),
            ],
            true,
        );
        let Block::Steps(run) = &blocks[1] else {
            panic!("{blocks:?}")
        };
        assert!(run.has_failure());
    }

    #[test]
    fn approvals_stay_out_of_the_conversation() {
        let approval = TranscriptItem::Approval(crate::transcript::ApprovalRequest {
            id: "r".into(),
            tool: "write".into(),
            workspace: None,
            path: None,
            command: None,
            content: None,
            edits: Vec::new(),
            summary: None,
            is_truncated: false,
            arguments: None,
        });
        let blocks = layout(&[question(), approval, said("a1", "Hi")], true);
        assert_eq!(ids(&blocks), ["u1", "a1"]);
    }

    fn status(
        state: SessionState,
        approvals: usize,
        error: bool,
        stopped: bool,
        items: &[TranscriptItem],
        saved: bool,
        changed: usize,
    ) -> TaskStatus {
        TaskStatus::resolve(&state, approvals, error, stopped, items, saved, changed)
    }

    #[test]
    fn status_follows_what_the_task_is_doing() {
        use SessionState::*;
        let answered = [question(), said("a", "Done.")];
        let q = [question()];
        assert_eq!(
            status(Idle, 0, false, false, &[], false, 0),
            TaskStatus::NotStarted
        );
        assert_eq!(
            status(Ready, 0, false, false, &[], false, 0),
            TaskStatus::NotStarted
        );
        assert_eq!(
            status(Idle, 0, false, false, &[], true, 0),
            TaskStatus::Saved
        );
        assert_eq!(
            status(Starting, 0, false, false, &[], false, 0),
            TaskStatus::Starting
        );
        assert_eq!(
            status(Running, 0, false, false, &q, false, 0),
            TaskStatus::Working
        );
        assert_eq!(
            status(Running, 2, false, false, &q, false, 0),
            TaskStatus::NeedsApproval(2)
        );
        assert_eq!(
            status(Ready, 0, true, false, &answered, false, 0),
            TaskStatus::NeedsAttention
        );
        assert_eq!(
            status(Failed("x".into()), 0, false, false, &answered, false, 0),
            TaskStatus::NeedsAttention
        );
        assert_eq!(
            status(Ready, 0, false, true, &answered, false, 0),
            TaskStatus::Stopped
        );
        assert_eq!(
            status(Ready, 0, false, false, &answered, false, 1),
            TaskStatus::Done { changed_files: 1 }
        );
        // A notice after the answer does not undo it.
        let with_notice = [
            question(),
            said("a", "Done."),
            notice("n", "Resumed", false),
        ];
        assert_eq!(
            status(Ready, 0, false, false, &with_notice, false, 0),
            TaskStatus::Done { changed_files: 0 }
        );
        // A saved conversation that is only being read is not "done" again.
        assert_eq!(
            status(Idle, 0, false, false, &answered, true, 0),
            TaskStatus::Saved
        );
        assert_eq!(
            status(
                Ready,
                0,
                false,
                false,
                &[question(), read("t", "a")],
                false,
                0
            ),
            TaskStatus::Saved
        );
    }

    #[test]
    fn status_tones() {
        assert_eq!(TaskStatus::NeedsApproval(1).tone(), Tone::Attention);
        assert_eq!(TaskStatus::NeedsAttention.tone(), Tone::Attention);
        assert_eq!(TaskStatus::Working.tone(), Tone::Working);
        assert_eq!(TaskStatus::Starting.tone(), Tone::Working);
        assert_eq!(TaskStatus::Done { changed_files: 0 }.tone(), Tone::Done);
        assert_eq!(TaskStatus::Stopped.tone(), Tone::Quiet);
    }

    #[test]
    fn the_last_turn_starts_at_the_last_question() {
        let items = [question(), said("a", "x"), read("t1", "a"), said("b", "y")];
        assert_eq!(last_turn(&items).len(), 4);
        let mut more = items.to_vec();
        more.push(TranscriptItem::User {
            id: "u2".into(),
            text: "again".into(),
        });
        more.push(read("t2", "b"));
        let last: Vec<&str> = last_turn(&more).iter().map(TranscriptItem::id).collect();
        assert_eq!(last, ["u2", "t2"]);
        assert!(last_turn(&[]).is_empty());
    }

    #[test]
    fn tasks_group_by_day_with_pinned_first() {
        let at = |day: u32, hour: u32| {
            Local
                .with_ymd_and_hms(2026, 11, day, hour, 0, 0)
                .single()
                .unwrap()
                .with_timezone(&Utc)
        };
        let now = Local
            .with_ymd_and_hms(2026, 11, 11, 12, 0, 0)
            .single()
            .unwrap();
        let ids: Vec<Uuid> = (0..7).map(|_| Uuid::new_v4()).collect();
        let entry = |i: usize, modified_at: DateTime<Utc>, is_pinned: bool| ListEntry {
            id: ids[i],
            modified_at,
            is_pinned,
        };
        let entries = [
            entry(0, at(11, 9), false),
            entry(1, at(10, 16), false),
            entry(2, at(11, 10), false),
            entry(3, at(3, 8), true),
            entry(4, at(7, 8), false),
            entry(5, DateTime::<Utc>::MIN_UTC, false),
            entry(6, at(10, 23), false),
        ];
        let sections = TaskListSection::make(&entries, now);
        let kinds: Vec<SectionKind> = sections.iter().map(|s| s.kind).collect();
        assert_eq!(
            kinds,
            [
                SectionKind::Pinned,
                SectionKind::Today,
                SectionKind::Yesterday,
                SectionKind::Day(NaiveDate::from_ymd_opt(2026, 11, 7).unwrap()),
                SectionKind::Earlier,
            ]
        );
        assert_eq!(sections[0].ids, [ids[3]]);
        assert_eq!(
            sections[1].ids,
            [ids[2], ids[0]],
            "newest first within a day"
        );
        assert_eq!(sections[2].ids, [ids[6], ids[1]]);
        assert_eq!(sections[3].ids, [ids[4]]);
        assert_eq!(sections[4].ids, [ids[5]]);
        assert!(TaskListSection::make(&[], now).is_empty());
    }

    #[test]
    fn changed_files_come_from_succeeded_writes_and_edits() {
        let f = fixture();
        let outside = f.root.join("elsewhere.txt");
        let write = |id: &str, path: &str, content: &str| {
            done(
                id,
                "write",
                serde_json::json!({"path": path, "content": content}),
            )
        };
        let items = [
            read("r", "reviewed-note.md"),
            write("w1", "reviewed-note.md", "one\ntwo\nthree\n"),
            write("w2", "old.md", "x"),
            done(
                "e1",
                "edit",
                serde_json::json!({"path": "old.md", "oldText": "x", "newText": "y"}),
            ),
            step(
                "w3",
                "write",
                serde_json::json!({"path": "failed.md", "content": "x"}),
                ToolStatus::Failed,
            ),
            step(
                "w4",
                "write",
                serde_json::json!({"path": "pending.md", "content": "x"}),
                ToolStatus::Running,
            ),
            done(
                "e2",
                "edit",
                serde_json::json!({"path": outside.to_string_lossy()}),
            ),
            done(
                "b",
                "bash",
                serde_json::json!({"command": "touch made-by-command.md"}),
            ),
            write("w5", "history.md", "a\nb"),
            done(
                "e3",
                "edit",
                serde_json::json!({"path": "reviewed-note.md"}),
            ),
        ];
        let existed = HashMap::from([("w1", false), ("w2", true)]);
        let files = ChangedFile::list(&items, &f.workspace, "Agent Workspace", |id| {
            existed.get(id).copied()
        });
        let names: Vec<&str> = files.iter().map(|f| f.target.name.as_str()).collect();
        assert_eq!(
            names,
            ["reviewed-note.md", "old.md", "elsewhere.txt", "history.md"]
        );
        assert_eq!(
            files[0].change,
            Change::Created,
            "a file the agent made stays new after it edits it"
        );
        assert_eq!(files[0].line_count, Some(3));
        assert_eq!(files[0].step_id, "e3");
        assert_eq!(files[0].target.folder, "Agent Workspace");
        assert_eq!(files[1].change, Change::Edited);
        assert_eq!(files[1].line_count, Some(1));
        assert_eq!(files[2].target.place, Place::Outside);
        // History does not say whether a written file was there before.
        assert_eq!(files[3].change, Change::Written);
        assert_eq!(files[3].line_count, Some(2));
        assert_eq!(ChangedFile::line_count(""), 0);
        assert_eq!(ChangedFile::line_count("a"), 1);
        assert_eq!(ChangedFile::line_count("a\nb\n"), 2);
    }

    #[test]
    fn a_file_target_follows_a_link_out_of_the_working_folder() {
        let f = fixture();
        #[cfg(unix)]
        {
            let outside = f.root.join("outside");
            std::fs::create_dir_all(&outside).unwrap();
            std::os::unix::fs::symlink(&outside, f.workspace.join("escape")).unwrap();
            let linked = FileTarget::resolve("escape/secret.txt", &f.workspace, "Agent Workspace");
            assert_eq!(linked.place, Place::Outside);
            assert_eq!(linked.name, "secret.txt");
        }
        let inside = FileTarget::resolve("@drafts/a.md", &f.workspace, "Agent Workspace");
        assert_eq!(inside.place, Place::WorkingFolder);
        assert_eq!(inside.folder, "Agent Workspace/drafts");
        assert_eq!(
            FileTarget::resolve("../up.md", &f.workspace, "W").place,
            Place::Outside
        );
        assert_eq!(
            FileTarget::resolve("~/x.md", &f.workspace, "W").place,
            Place::Outside
        );
        let absolute = f.workspace.join("notes").join("plan.md");
        let named = FileTarget::resolve(&absolute.to_string_lossy(), &f.workspace, "W");
        assert_eq!(
            (named.name.as_str(), named.folder.as_str()),
            ("plan.md", "W/notes")
        );
    }

    #[test]
    fn step_arguments_read_both_path_keys() {
        let parsed = StepArguments::parse(r#"{"file_path":"a.md","content":"x"}"#);
        assert_eq!(parsed.path.as_deref(), Some("a.md"));
        assert_eq!(parsed.content.as_deref(), Some("x"));
        assert_eq!(StepArguments::parse("not json"), StepArguments::default());
    }
}
