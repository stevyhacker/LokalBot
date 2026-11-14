//! Tool approvals (`AgentApprovalPolicy.swift`).
//!
//! The bundled extension raises an approval request for every tool call
//! except a read inside the working folder and outside the private library.
//! This decides whether a raised request is answered automatically (a
//! read-only lookup of the user's own library with a model on this computer,
//! the approval mode, "Allow for Session" choices) or shown to the user.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};

/// How the user scoped an approval on its card.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApprovalScope {
    Once,
    Session,
}

/// Approval levels, ordered from least to most permissive so the UI asks to
/// confirm only escalations. Remembered app-wide; per-tool exceptions are
/// session-only. Stored as the macOS raw values (0…3).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ApprovalMode {
    #[default]
    AskBeforeChanges,
    ApproveReads,
    ApproveReadsAndEdits,
    FullAccess,
}

impl ApprovalMode {
    pub const ALL: [ApprovalMode; 4] = [
        ApprovalMode::AskBeforeChanges,
        ApprovalMode::ApproveReads,
        ApprovalMode::ApproveReadsAndEdits,
        ApprovalMode::FullAccess,
    ];

    pub fn raw_value(self) -> u8 {
        self as u8
    }

    pub fn from_raw(value: u8) -> Option<Self> {
        Self::ALL.get(value as usize).copied()
    }

    pub fn confirmation_title(self) -> &'static str {
        match self {
            ApprovalMode::AskBeforeChanges => "Use Ask before changes?",
            ApprovalMode::ApproveReads => "Auto-approve every read?",
            ApprovalMode::ApproveReadsAndEdits => "Auto-approve every read and edit?",
            ApprovalMode::FullAccess => "Give this agent full access?",
        }
    }

    pub fn confirmation_message(self) -> &'static str {
        match self {
            ApprovalMode::AskBeforeChanges => {
                "Outside reads, file changes, and shell commands will ask first."
            }
            ApprovalMode::ApproveReads => {
                "The agent can read any file this account can access on this PC, including files outside the working folder, without showing each request. File changes and shell commands will still ask. This choice is remembered for future sessions."
            }
            ApprovalMode::ApproveReadsAndEdits => {
                "The agent can read, create, overwrite, and edit ordinary files anywhere this account can access on this PC without showing each request. File-tool changes to LokalBot’s private data and runtime will still ask, as will shell commands. This choice is remembered for future sessions."
            }
            ApprovalMode::FullAccess => {
                "The agent can read and change ordinary files anywhere, run shell commands, and use any other agent tool without asking. File-tool changes to LokalBot’s private data and runtime still ask. Shell commands and other tools may delete data, access secrets, change app files, or connect to the network. This choice is remembered for future sessions."
            }
        }
    }

    pub fn confirmation_action(self) -> &'static str {
        match self {
            ApprovalMode::AskBeforeChanges => "Keep Asking",
            ApprovalMode::ApproveReads => "Auto-approve Reads",
            ApprovalMode::ApproveReadsAndEdits => "Auto-approve Reads & Edits",
            ApprovalMode::FullAccess => "Give Full Access",
        }
    }
}

/// `approval-mode.json`: `{"mode": 0…3}`.
#[derive(Serialize, Deserialize)]
struct StoredMode {
    mode: u8,
}

pub fn load_mode(file: &Path) -> ApprovalMode {
    std::fs::read(file)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<StoredMode>(&bytes).ok())
        .and_then(|stored| ApprovalMode::from_raw(stored.mode))
        .unwrap_or_default()
}

pub fn save_mode(file: &Path, mode: ApprovalMode) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let bytes = serde_json::to_vec(&StoredMode {
        mode: mode.raw_value(),
    })
    .map_err(std::io::Error::other)?;
    lokalbot_core::library::write_atomic(file, &bytes)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    Ask,
}

/// Pure approval policy for gated tools.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ApprovalPolicy {
    pub mode: ApprovalMode,
    pub protected_write_roots: Vec<PathBuf>,
    session_allowed_tools: BTreeSet<String>,
    automation_approves_workspace_file_changes: bool,
    /// True only while the task's model is known to run on this computer. A
    /// lookup's output is fed to the model, so with a model anywhere else,
    /// or one whose place is not known, a lookup is not let through here.
    pub model_runs_on_this_computer: bool,
}

impl ApprovalPolicy {
    pub fn new(mode: ApprovalMode, protected_write_roots: Vec<PathBuf>) -> Self {
        Self {
            mode,
            protected_write_roots,
            ..Self::default()
        }
    }

    pub fn verdict(
        &self,
        tool: &str,
        path: Option<&str>,
        command: Option<&str>,
        request_workspace: Option<&str>,
        selected_workspace: &Path,
    ) -> Verdict {
        let tool = tool.to_lowercase();
        if is_file_change(&tool) && is_protected(path, &self.protected_write_roots) {
            return Verdict::Ask;
        }
        // Automatic modes only apply to structured approvals from the process
        // for this working folder; stale or malformed requests fail closed.
        if request_matches_selected_workspace(request_workspace, selected_workspace) {
            // A lone read-only lookup of the user's own library runs in every
            // mode, the default included, when the model runs on this
            // computer. With a model elsewhere it asks. Anything
            // `is_library_lookup` cannot prove to be a lookup falls through
            // and follows the mode.
            if tool == "bash" && self.model_runs_on_this_computer && is_library_lookup(command) {
                return Verdict::Allow;
            }
            match self.mode {
                ApprovalMode::AskBeforeChanges => {}
                ApprovalMode::ApproveReads => {
                    if tool == "read" {
                        return Verdict::Allow;
                    }
                }
                ApprovalMode::ApproveReadsAndEdits => {
                    if tool == "read" || is_file_change(&tool) {
                        return Verdict::Allow;
                    }
                }
                // Every tool, including MCP tools and tools later pi releases
                // add. Protected file changes already asked above.
                ApprovalMode::FullAccess => return Verdict::Allow,
            }
        }
        // "Allow for Session" stays narrower than the modes: only canonical
        // write/edit paths inside the matching workspace inherit it.
        if !Self::can_persist_approval(
            &tool,
            path,
            request_workspace,
            selected_workspace,
            &self.protected_write_roots,
        ) {
            return Verdict::Ask;
        }
        if self.automation_approves_workspace_file_changes
            || self.session_allowed_tools.contains(&tool)
        {
            return Verdict::Allow;
        }
        Verdict::Ask
    }

    pub fn allow_for_session(
        &mut self,
        tool: &str,
        path: Option<&str>,
        request_workspace: Option<&str>,
        selected_workspace: &Path,
    ) {
        if Self::can_persist_approval(
            tool,
            path,
            request_workspace,
            selected_workspace,
            &self.protected_write_roots,
        ) {
            self.session_allowed_tools.insert(tool.to_lowercase());
        }
    }

    /// The headless harness has nobody to click file-change cards. It may
    /// opt into workspace-contained write/edit calls only.
    pub fn approve_workspace_file_changes_for_automation(&mut self) {
        self.automation_approves_workspace_file_changes = true;
    }

    /// Keeps the mode and where the model runs, which belong to the task.
    pub fn reset_session(&mut self) {
        self.session_allowed_tools.clear();
        self.automation_approves_workspace_file_changes = false;
    }

    pub fn can_persist_approval(
        tool: &str,
        path: Option<&str>,
        request_workspace: Option<&str>,
        selected_workspace: &Path,
        protected_write_roots: &[PathBuf],
    ) -> bool {
        if !is_file_change(&tool.to_lowercase()) || is_protected(path, protected_write_roots) {
            return false;
        }
        let (Some(path), Some(request_workspace)) = (path, request_workspace) else {
            return false;
        };
        let (Some(requested_root), Some(selected_root), Some(file)) = (
            canonical_path(Path::new(request_workspace)),
            canonical_path(selected_workspace),
            canonical_path(Path::new(path)),
        ) else {
            return false;
        };
        same_path(&requested_root, &selected_root) && is_within(&file, &selected_root)
    }
}

/// The options `lokalbot-cli brief`, `list`, `get` and `search` take. None
/// of them writes a file or reaches the network. A word that starts with `-`
/// and is not listed here keeps the command from counting as a lookup, so an
/// option a later release adds asks until it is added.
const LOOKUP_OPTIONS: [(&str, &[&str]); 4] = [
    ("brief", &[]),
    (
        "list",
        &[
            "--since",
            "--until",
            "--query",
            "--limit",
            "--include",
            "--table",
        ],
    ),
    ("get", &["--include", "--format"]),
    ("search", &["--limit", "--table"]),
];

/// One `lokalbot-cli brief`, `list`, `get` or `search` call made of plain and
/// quoted words, so nothing can chain, redirect, substitute or expand into
/// another command. Those four only read the library and print, and only with
/// the options in [`LOOKUP_OPTIONS`]. A trailing `2>&1` and `| head` or
/// `| tail` with a line count are allowed.
pub fn is_library_lookup(command: Option<&str>) -> bool {
    let Some(words) = plain_command_words(command) else {
        return false;
    };
    if words.len() < 2 || words[0] != "lokalbot-cli" {
        return false;
    }
    let Some((_, options)) = LOOKUP_OPTIONS.iter().find(|(name, _)| *name == words[1]) else {
        return false;
    };
    words[2..].iter().all(|word| {
        !word.starts_with('-') || {
            let name = word.split('=').next().unwrap_or_default();
            options.contains(&name)
        }
    })
}

/// The words of a command that is a single call made of plain and quoted
/// words, after an optional `2>&1` and `| head` or `| tail` with a line
/// count. `None` when the text holds anything a shell could use to chain,
/// redirect, substitute or expand.
pub fn plain_command_words(command: Option<&str>) -> Option<Vec<String>> {
    let command = strip_allowed_suffix(command?);
    let allowed = |c: char| c.is_alphanumeric() || " -_.,:=\"'".contains(c);
    if !command.chars().all(allowed) {
        return None;
    }
    // With `$`, backticks and backslashes excluded, quotes only group words.
    let mut words = Vec::new();
    let mut word: Option<String> = None;
    let mut quote: Option<char> = None;
    for c in command.chars() {
        if let Some(open) = quote {
            if c == open {
                quote = None;
            } else {
                word.get_or_insert_with(String::new).push(c);
            }
        } else if c == '"' || c == '\'' {
            quote = Some(c);
            word.get_or_insert_with(String::new);
        } else if c == ' ' {
            words.extend(word.take());
        } else {
            word.get_or_insert_with(String::new).push(c);
        }
    }
    if quote.is_some() {
        return None;
    }
    words.extend(word);
    Some(words)
}

/// Removes what `(\s+2>&1)?(\s*\|\s*(head|tail)(\s+-n\s+[0-9]+|\s+-[0-9]+))?\s*$`
/// matches, as the macOS app does with that expression.
fn strip_allowed_suffix(command: &str) -> &str {
    let mut rest = command.trim_end();
    if let Some(before) = strip_line_limit(rest) {
        rest = before;
    }
    if let Some(before) = rest.strip_suffix("2>&1")
        && before.ends_with(char::is_whitespace)
    {
        rest = before.trim_end();
    }
    rest
}

/// `| head -n 20`, `|tail -5` and the like at the end, with the space before.
fn strip_line_limit(text: &str) -> Option<&str> {
    let digits = text.trim_end_matches(|c: char| c.is_ascii_digit());
    if digits.len() == text.len() {
        return None;
    }
    let before_count = if let Some(dash) = digits.strip_suffix('-') {
        // `-5`, after at least one space.
        dash.ends_with(char::is_whitespace).then_some(dash)?
    } else {
        // `-n 5`: spaces, `-n`, at least one space.
        let spaced = digits.trim_end();
        if spaced.len() == digits.len() {
            return None;
        }
        let flag = spaced.strip_suffix("-n")?;
        flag.ends_with(char::is_whitespace).then_some(flag)?
    };
    let program = before_count.trim_end();
    let pipe = program
        .strip_suffix("head")
        .or_else(|| program.strip_suffix("tail"))?
        .trim_end()
        .strip_suffix('|')?;
    Some(pipe.trim_end())
}

fn request_matches_selected_workspace(request_workspace: Option<&str>, selected: &Path) -> bool {
    let Some(request_workspace) = request_workspace else {
        return false;
    };
    match (
        canonical_path(Path::new(request_workspace)),
        canonical_path(selected),
    ) {
        (Some(requested), Some(selected)) => same_path(&requested, &selected),
        _ => false,
    }
}

fn is_file_change(tool: &str) -> bool {
    tool == "write" || tool == "edit"
}

/// Missing or unresolvable paths count as protected (fail closed).
fn is_protected(path: Option<&str>, roots: &[PathBuf]) -> bool {
    if roots.is_empty() {
        return false;
    }
    let Some(file) = path.and_then(|p| canonical_path(Path::new(p))) else {
        return true;
    };
    roots.iter().any(|root| match canonical_path(root) {
        Some(root) => is_within(&file, &root),
        None => true,
    })
}

/// Resolves symlinks through the nearest existing ancestor, then appends the
/// not-yet-created rest, matching the extension's rule: a symlinked parent
/// cannot turn an apparently local write into an outside one. A dangling
/// link fails closed.
pub fn canonical_path(path: &Path) -> Option<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().ok()?.join(path)
    };
    let normalized = lexically_normalized(&absolute);
    let mut ancestor = normalized.clone();
    let mut suffix: Vec<std::ffi::OsString> = Vec::new();
    while std::fs::symlink_metadata(&ancestor).is_err() {
        let name = ancestor.file_name()?.to_os_string();
        suffix.push(name);
        if !ancestor.pop() {
            return None;
        }
    }
    let mut resolved = dunce::canonicalize(&ancestor).ok()?;
    for component in suffix.into_iter().rev() {
        resolved.push(component);
    }
    Some(resolved)
}

/// `.` and `..` removed without touching the disk (`standardizedFileURL`).
pub(crate) fn lexically_normalized(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    out.push(component);
                }
            }
            other => out.push(other),
        }
    }
    out
}

/// Component-wise; Windows paths compare case-insensitively.
pub fn is_within(path: &Path, root: &Path) -> bool {
    let path: Vec<String> = comparable_components(path);
    let root: Vec<String> = comparable_components(root);
    path.len() >= root.len() && path[..root.len()] == root[..]
}

pub fn same_path(a: &Path, b: &Path) -> bool {
    comparable_components(a) == comparable_components(b)
}

fn comparable_components(path: &Path) -> Vec<String> {
    path.components()
        .filter(|c| !matches!(c, Component::CurDir))
        .map(|c| {
            let text = c.as_os_str().to_string_lossy().into_owned();
            if cfg!(windows) {
                text.to_lowercase()
            } else {
                text
            }
        })
        .collect()
}

/// Private app data is never an implicit working folder
/// (`AgentWorkspacePolicy`). File tools may still request individual reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspacePolicy {
    pub private_roots: Vec<PathBuf>,
}

pub const PRIVATE_WORKSPACE_NOTICE: &str = "This task uses an older working folder inside LokalBot’s private data. Its saved history is still available, but it cannot run here. Choose a folder outside LokalBot’s private data to start a new task; attach specific sources or use the scoped library tools.";

impl WorkspacePolicy {
    pub fn contains_private_workspace(&self, workspace: &Path) -> bool {
        let Some(workspace) = canonical_path(workspace) else {
            return true;
        };
        self.private_roots
            .iter()
            .any(|root| canonical_path(root).is_none_or(|root| is_within(&workspace, &root)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture {
        _dir: tempfile::TempDir,
        workspace: PathBuf,
        outside: PathBuf,
        protected: PathBuf,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let root = dunce::canonicalize(dir.path()).unwrap();
        let workspace = root.join("workspace");
        let outside = root.join("outside");
        let protected = root.join("library");
        for folder in [&workspace, &outside, &protected] {
            std::fs::create_dir_all(folder).unwrap();
        }
        Fixture {
            _dir: dir,
            workspace,
            outside,
            protected,
        }
    }

    fn s(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }

    #[test]
    fn gated_tool_asks_by_default() {
        let f = fixture();
        let policy = ApprovalPolicy::default();
        let file = s(&f.workspace.join("a.txt"));
        let ws = s(&f.workspace);
        assert_eq!(
            policy.verdict("write", Some(&file), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        assert_eq!(
            policy.verdict("bash", None, None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
    }

    #[test]
    fn modes_widen_in_order() {
        let f = fixture();
        let ws = s(&f.workspace);
        let outside_file = s(&f.outside.join("o.txt"));
        let mut policy = ApprovalPolicy::new(ApprovalMode::ApproveReads, vec![f.protected.clone()]);
        assert_eq!(
            policy.verdict("read", Some(&outside_file), None, Some(&ws), &f.workspace),
            Verdict::Allow
        );
        assert_eq!(
            policy.verdict("write", Some(&outside_file), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // A read from another working folder never inherits the mode.
        let other = s(&f.outside);
        assert_eq!(
            policy.verdict(
                "read",
                Some(&outside_file),
                None,
                Some(&other),
                &f.workspace
            ),
            Verdict::Ask
        );

        policy.mode = ApprovalMode::ApproveReadsAndEdits;
        assert_eq!(
            policy.verdict("edit", Some(&outside_file), None, Some(&ws), &f.workspace),
            Verdict::Allow
        );
        assert_eq!(
            policy.verdict("bash", None, None, Some(&ws), &f.workspace),
            Verdict::Ask
        );

        policy.mode = ApprovalMode::FullAccess;
        assert_eq!(
            policy.verdict("bash", None, None, Some(&ws), &f.workspace),
            Verdict::Allow
        );
        assert_eq!(
            policy.verdict("mcp__x__y", None, None, Some(&ws), &f.workspace),
            Verdict::Allow
        );
    }

    #[test]
    fn protected_writes_never_inherit_broad_or_session_grants() {
        let f = fixture();
        let ws = s(&f.workspace);
        let private_file = s(&f.protected.join("meetings/x/summary.md"));
        let mut policy = ApprovalPolicy::new(ApprovalMode::FullAccess, vec![f.protected.clone()]);
        assert_eq!(
            policy.verdict("write", Some(&private_file), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        policy.allow_for_session("write", Some(&private_file), Some(&ws), &f.workspace);
        policy.mode = ApprovalMode::AskBeforeChanges;
        assert_eq!(
            policy.verdict("write", Some(&private_file), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // Missing paths are protected too.
        policy.mode = ApprovalMode::FullAccess;
        assert_eq!(
            policy.verdict("edit", None, None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
    }

    #[test]
    fn session_allowance_is_per_tool_and_reset_keeps_mode() {
        let f = fixture();
        let ws = s(&f.workspace);
        let file = s(&f.workspace.join("a.txt"));
        let mut policy = ApprovalPolicy::new(ApprovalMode::ApproveReads, Vec::new());
        policy.allow_for_session("write", Some(&file), Some(&ws), &f.workspace);
        assert_eq!(
            policy.verdict("write", Some(&file), None, Some(&ws), &f.workspace),
            Verdict::Allow
        );
        assert_eq!(
            policy.verdict("edit", Some(&file), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // Outside the working folder a session grant does not apply.
        let outside = s(&f.outside.join("o.txt"));
        assert_eq!(
            policy.verdict("write", Some(&outside), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        policy.reset_session();
        assert_eq!(
            policy.verdict("write", Some(&file), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        assert_eq!(policy.mode, ApprovalMode::ApproveReads);
    }

    #[test]
    fn automation_allows_only_workspace_file_changes() {
        let f = fixture();
        let ws = s(&f.workspace);
        let mut policy = ApprovalPolicy::default();
        policy.approve_workspace_file_changes_for_automation();
        let inside = s(&f.workspace.join("new/dir/file.txt"));
        assert_eq!(
            policy.verdict("write", Some(&inside), None, Some(&ws), &f.workspace),
            Verdict::Allow
        );
        let outside = s(&f.outside.join("o.txt"));
        assert_eq!(
            policy.verdict("write", Some(&outside), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        assert_eq!(
            policy.verdict("bash", None, None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        assert_eq!(
            policy.verdict("write", None, None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
    }

    #[cfg(unix)]
    #[test]
    fn symlink_escaped_write_never_inherits_approval() {
        let f = fixture();
        std::os::unix::fs::symlink(&f.outside, f.workspace.join("escape")).unwrap();
        let ws = s(&f.workspace);
        let escaped = s(&f.workspace.join("escape/new.txt"));
        let mut policy = ApprovalPolicy::default();
        policy.approve_workspace_file_changes_for_automation();
        assert_eq!(
            policy.verdict("write", Some(&escaped), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // A dangling link fails closed as well.
        std::os::unix::fs::symlink(f.outside.join("missing"), f.workspace.join("dangling"))
            .unwrap();
        let dangling = s(&f.workspace.join("dangling/new.txt"));
        assert_eq!(
            policy.verdict("write", Some(&dangling), None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
    }

    #[test]
    fn private_library_workspace_is_rejected_including_descendants() {
        let f = fixture();
        let policy = WorkspacePolicy {
            private_roots: vec![f.protected.clone()],
        };
        assert!(policy.contains_private_workspace(&f.protected));
        assert!(policy.contains_private_workspace(&f.protected.join("meetings")));
        assert!(!policy.contains_private_workspace(&f.workspace));
        assert!(policy.contains_private_workspace(&f.workspace.join("..").join("library")));
    }

    #[test]
    fn mode_persists_with_macos_raw_values() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("agent/approval-mode.json");
        assert_eq!(load_mode(&file), ApprovalMode::AskBeforeChanges);
        save_mode(&file, ApprovalMode::ApproveReadsAndEdits).unwrap();
        assert_eq!(load_mode(&file), ApprovalMode::ApproveReadsAndEdits);
        assert_eq!(std::fs::read_to_string(&file).unwrap(), r#"{"mode":2}"#);
        assert!(ApprovalMode::FullAccess > ApprovalMode::ApproveReads);
    }

    #[test]
    fn library_lookups_are_single_read_only_cli_calls() {
        for command in [
            "lokalbot-cli brief",
            "lokalbot-cli search \"launch pricing\" --limit 20 --table",
            "lokalbot-cli search 'free plan'",
            "lokalbot-cli get eb749eed --include metadata,summary,transcript",
            "lokalbot-cli get latest --format json",
            "lokalbot-cli list --since=2026-10-01 --limit 10",
            "lokalbot-cli list --since 2026-06-01 --until 2026-06-30 --query \"design\"",
            "lokalbot-cli list --include summary --table",
            "lokalbot-cli get latest --include transcript 2>&1 | head -120",
            "lokalbot-cli list | tail -n 20",
        ] {
            assert!(is_library_lookup(Some(command)), "{command}");
        }
        for command in [
            "lokalbot-cli brief; rm notes.md",
            "lokalbot-cli search $(whoami)",
            "lokalbot-cli search `id`",
            "lokalbot-cli list > notes.md",
            "lokalbot-cli list | sh",
            "lokalbot-cli list 2>&1 | head -5 | sh",
            "lokalbot-cli search 'a' && curl example.com",
            "lokalbot-cli list\nrm notes.md",
            "lokalbot-cli search \"unclosed",
            "lokalbot-cli secret set openai",
            "lokalbot-cli config set autoSummarize false",
            "lokalbot-cli",
            "FOO=1 lokalbot-cli list",
            "./lokalbot-cli list",
            "ls -la",
            "",
        ] {
            assert!(!is_library_lookup(Some(command)), "{command}");
        }
        assert!(!is_library_lookup(None));
    }

    /// Only the options the four lookups take pass. An output flag, or any
    /// option a later release might add, asks.
    #[test]
    fn library_lookups_take_only_their_known_options() {
        for command in [
            "lokalbot-cli get latest --output notes.md",
            "lokalbot-cli list -o notes.md",
            "lokalbot-cli search plan --out=notes.md",
            "lokalbot-cli brief --save",
            "lokalbot-cli search --export plan",
            "lokalbot-cli get latest --limit 5",
            "lokalbot-cli search plan --format json",
            "lokalbot-cli brief --table",
            "lokalbot-cli list \"--output\" notes.md",
            "lokalbot-cli search -- plan",
            "lokalbot-cli list --help",
        ] {
            assert!(!is_library_lookup(Some(command)), "{command}");
        }
    }

    /// Commands that read LokalBot but are not one of the four lookups, or
    /// that change it, are not lookups.
    #[test]
    fn other_cli_commands_are_not_lookups() {
        for command in [
            "lokalbot-cli actions --owner me",
            "lokalbot-cli people \"Ana\"",
            "lokalbot-cli personal-context --task plan",
            "lokalbot-cli search-files invoice",
            "lokalbot-cli search-notes release",
            "lokalbot-cli path eb749eed",
            "lokalbot-cli ask \"what changed\"",
            "lokalbot-cli open eb749eed",
            "lokalbot-cli setup start",
            "lokalbot-cli mcp",
            "lokalbot-cli restart",
            "lokalbot-cli models download whisper",
            "lokalbot-cli install-skill",
        ] {
            assert!(!is_library_lookup(Some(command)), "{command}");
        }
    }

    #[test]
    fn the_allowed_tail_is_stripped_exactly() {
        let words = |c: &str| plain_command_words(Some(c));
        assert_eq!(
            words("lokalbot-cli search 'design review'  2>&1|tail  -n 5 "),
            Some(vec![
                "lokalbot-cli".to_string(),
                "search".into(),
                "design review".into()
            ])
        );
        // A count must follow its flag after a space; the redirect needs one before.
        for command in [
            "lokalbot-cli list | head -n5",
            "lokalbot-cli list | head - 5",
            "lokalbot-cli list | head",
            "lokalbot-cli list2>&1",
            "lokalbot-cli list | head -5 2>&1",
            "lokalbot-cli list | | head -5",
            "lokalbot-cli list\t| head -5\t2>&1",
        ] {
            assert_eq!(words(command), None, "{command}");
        }
        assert_eq!(words("lokalbot-cli list\t2>&1").map(|w| w.len()), Some(2));
    }

    fn command(policy: &ApprovalPolicy, f: &Fixture, command: &str) -> Verdict {
        lookup_from(policy, f, command, &s(&f.workspace))
    }

    fn lookup_from(policy: &ApprovalPolicy, f: &Fixture, command: &str, from: &str) -> Verdict {
        policy.verdict("bash", None, Some(command), Some(from), &f.workspace)
    }

    fn local_model_policy(mode: ApprovalMode) -> ApprovalPolicy {
        let mut policy = ApprovalPolicy::new(mode, Vec::new());
        policy.model_runs_on_this_computer = true;
        policy
    }

    const LOOKUPS: [&str; 5] = [
        "lokalbot-cli brief",
        "lokalbot-cli list --limit 10",
        "lokalbot-cli get latest --include metadata,summary",
        "lokalbot-cli search \"design review\" --limit 20",
        "lokalbot-cli get eb749eed --include transcript 2>&1 | head -200",
    ];

    /// The owner's decision: a read-only lookup of the user's own library
    /// runs without a request at the default level, and so at every level,
    /// when the task's model runs on this computer.
    #[test]
    fn each_library_lookup_runs_without_asking_at_the_default_level_with_a_local_model() {
        let f = fixture();
        let policy = local_model_policy(ApprovalMode::default());
        assert_eq!(policy.mode, ApprovalMode::AskBeforeChanges);
        for lookup in LOOKUPS {
            assert_eq!(command(&policy, &f, lookup), Verdict::Allow, "{lookup}");
            for mode in ApprovalMode::ALL {
                assert_eq!(
                    command(&local_model_policy(mode), &f, lookup),
                    Verdict::Allow,
                    "{mode:?} {lookup}"
                );
            }
        }
    }

    /// A lookup's output goes to the model. With a model on a server or a
    /// subscription plan, or one whose place is not known, the same lookups
    /// ask wherever they asked before lookups could skip approval.
    #[test]
    fn the_same_lookups_ask_when_the_model_is_not_on_this_computer() {
        let f = fixture();
        assert!(
            !ApprovalPolicy::default().model_runs_on_this_computer,
            "not known means not on this computer"
        );
        for lookup in LOOKUPS {
            for mode in [
                ApprovalMode::AskBeforeChanges,
                ApprovalMode::ApproveReads,
                ApprovalMode::ApproveReadsAndEdits,
            ] {
                let policy = ApprovalPolicy::new(mode, Vec::new());
                assert_eq!(
                    command(&policy, &f, lookup),
                    Verdict::Ask,
                    "{mode:?} {lookup}"
                );
            }
            // Full access runs every command, as it did before.
            let full = ApprovalPolicy::new(ApprovalMode::FullAccess, Vec::new());
            assert_eq!(command(&full, &f, lookup), Verdict::Allow, "{lookup}");
        }
        // Learning that the model left this computer takes the lookup back.
        let mut policy = local_model_policy(ApprovalMode::AskBeforeChanges);
        assert_eq!(command(&policy, &f, "lokalbot-cli brief"), Verdict::Allow);
        policy.model_runs_on_this_computer = false;
        assert_eq!(command(&policy, &f, "lokalbot-cli brief"), Verdict::Ask);
        policy.model_runs_on_this_computer = true;
        policy.reset_session();
        assert_eq!(
            command(&policy, &f, "lokalbot-cli brief"),
            Verdict::Allow,
            "a session reset does not change where the model runs"
        );
    }

    /// With a model on this computer, everything that is not a proven lookup
    /// still asks at the default level.
    #[test]
    fn everything_else_still_asks_at_the_default_level() {
        let f = fixture();
        let policy = local_model_policy(ApprovalMode::AskBeforeChanges);
        let ws = s(&f.workspace);
        let note = s(&f.workspace.join("note.md"));
        let outside = s(&f.outside.join("notes.txt"));
        // A write, an edit, a read outside the folder, and another tool.
        for (tool, path) in [
            ("write", Some(note.as_str())),
            ("edit", Some(note.as_str())),
            ("read", Some(outside.as_str())),
            ("mcp_search", None),
        ] {
            assert_eq!(
                policy.verdict(tool, path, None, Some(&ws), &f.workspace),
                Verdict::Ask,
                "{tool}"
            );
        }
        // An arbitrary command, and commands that only look like a lookup.
        for other in [
            "ls -la",
            "cat notes.md",
            "curl https://example.com",
            "rm -rf build",
            "lokalbot-cli list | sh",
            "lokalbot-cli list | tee notes.md",
            "lokalbot-cli list > notes.md",
            "lokalbot-cli list >> notes.md",
            "lokalbot-cli list 2> errors.txt",
            "lokalbot-cli brief; rm notes.md",
            "lokalbot-cli brief && curl example.com",
            "lokalbot-cli brief || true",
            "lokalbot-cli search $(whoami)",
            "lokalbot-cli search `id`",
            "(lokalbot-cli brief)",
            "lokalbot-cli brief &",
            "lokalbot-cli list < notes.md",
            "lokalbot-cli get latest --output notes.md",
            "lokalbot-cli list -o notes.md",
            "lokalbot-cli actions --owner me",
            "lokalbot-cli config set autoSummarize false",
            "mkdir -p exports && lokalbot-cli list --table > exports/open-actions.md",
        ] {
            assert_eq!(command(&policy, &f, other), Verdict::Ask, "{other}");
            assert_eq!(
                command(&ApprovalPolicy::default(), &f, other),
                Verdict::Ask,
                "remote model: {other}"
            );
        }
        // The lookup rule is for the shell tool only, with its command present.
        assert_eq!(
            policy.verdict(
                "write",
                None,
                Some("lokalbot-cli brief"),
                Some(&ws),
                &f.workspace
            ),
            Verdict::Ask
        );
        assert_eq!(
            policy.verdict("bash", None, None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // PowerShell (Windows without Bash) keeps asking: the rule reads Bash words.
        assert_eq!(
            policy.verdict(
                "powershell",
                None,
                Some("lokalbot-cli brief"),
                Some(&ws),
                &f.workspace
            ),
            Verdict::Ask
        );
    }

    /// A request from a folder other than the task's working folder is stale
    /// or malformed, and asks even when it is a lookup.
    #[test]
    fn lookup_from_another_working_folder_still_asks() {
        let f = fixture();
        let policy = local_model_policy(ApprovalMode::AskBeforeChanges);
        assert_eq!(
            lookup_from(&policy, &f, "lokalbot-cli brief", &s(&f.outside)),
            Verdict::Ask
        );
        assert_eq!(
            policy.verdict("bash", None, Some("lokalbot-cli brief"), None, &f.workspace),
            Verdict::Ask
        );
    }

    #[test]
    fn lookups_do_not_loosen_the_levels_for_other_commands() {
        let f = fixture();
        for mode in [
            ApprovalMode::AskBeforeChanges,
            ApprovalMode::ApproveReads,
            ApprovalMode::ApproveReadsAndEdits,
        ] {
            let mut policy = local_model_policy(mode);
            assert_eq!(
                command(&policy, &f, "lokalbot-cli list > notes.md"),
                Verdict::Ask,
                "{mode:?}"
            );
            policy.reset_session();
            assert_eq!(
                command(&policy, &f, "lokalbot-cli brief"),
                Verdict::Allow,
                "{mode:?}"
            );
        }
        assert_eq!(
            command(
                &local_model_policy(ApprovalMode::FullAccess),
                &f,
                "lokalbot-cli list > notes.md"
            ),
            Verdict::Allow
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_paths_compare_without_case() {
        assert!(is_within(
            Path::new(r"C:\Users\X\Work\a.txt"),
            Path::new(r"c:\users\x\work")
        ));
        assert!(same_path(Path::new(r"C:\A"), Path::new(r"c:\a")));
    }
}
