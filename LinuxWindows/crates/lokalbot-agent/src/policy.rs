//! Tool approvals (`AgentApprovalPolicy.swift`).
//!
//! The bundled extension raises an approval request for every tool call
//! except a read inside the working folder and outside the private library.
//! This decides whether a raised request is answered automatically (the
//! approval mode, "Allow for Session" choices) or shown to the user.

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

    pub fn title(self) -> &'static str {
        match self {
            ApprovalMode::AskBeforeChanges => "Ask before changes",
            ApprovalMode::ApproveReads => "Auto-approve reads",
            ApprovalMode::ApproveReadsAndEdits => "Auto-approve reads & edits",
            ApprovalMode::FullAccess => "Full access",
        }
    }

    pub fn detail(self) -> &'static str {
        match self {
            ApprovalMode::AskBeforeChanges => {
                "Reads in the working folder run automatically. Outside reads, file changes, and shell commands ask first."
            }
            ApprovalMode::ApproveReads => {
                "All reads run automatically, including outside the working folder. File changes and shell commands ask first."
            }
            ApprovalMode::ApproveReadsAndEdits => {
                "Reads and ordinary file edits run automatically, including outside the working folder. File-tool changes to LokalBot’s private data and shell commands ask first."
            }
            ApprovalMode::FullAccess => {
                "Reads, ordinary file edits, shell calls, and every other agent tool run automatically. File-tool changes to LokalBot’s private data still ask; shell commands remain unrestricted."
            }
        }
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
fn lexically_normalized(path: &Path) -> PathBuf {
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
            policy.verdict("write", Some(&file), Some(&ws), &f.workspace),
            Verdict::Ask
        );
        assert_eq!(
            policy.verdict("bash", None, Some(&ws), &f.workspace),
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
            policy.verdict("read", Some(&outside_file), Some(&ws), &f.workspace),
            Verdict::Allow
        );
        assert_eq!(
            policy.verdict("write", Some(&outside_file), Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // A read from another working folder never inherits the mode.
        let other = s(&f.outside);
        assert_eq!(
            policy.verdict("read", Some(&outside_file), Some(&other), &f.workspace),
            Verdict::Ask
        );

        policy.mode = ApprovalMode::ApproveReadsAndEdits;
        assert_eq!(
            policy.verdict("edit", Some(&outside_file), Some(&ws), &f.workspace),
            Verdict::Allow
        );
        assert_eq!(
            policy.verdict("bash", None, Some(&ws), &f.workspace),
            Verdict::Ask
        );

        policy.mode = ApprovalMode::FullAccess;
        assert_eq!(
            policy.verdict("bash", None, Some(&ws), &f.workspace),
            Verdict::Allow
        );
        assert_eq!(
            policy.verdict("mcp__x__y", None, Some(&ws), &f.workspace),
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
            policy.verdict("write", Some(&private_file), Some(&ws), &f.workspace),
            Verdict::Ask
        );
        policy.allow_for_session("write", Some(&private_file), Some(&ws), &f.workspace);
        policy.mode = ApprovalMode::AskBeforeChanges;
        assert_eq!(
            policy.verdict("write", Some(&private_file), Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // Missing paths are protected too.
        policy.mode = ApprovalMode::FullAccess;
        assert_eq!(
            policy.verdict("edit", None, Some(&ws), &f.workspace),
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
            policy.verdict("write", Some(&file), Some(&ws), &f.workspace),
            Verdict::Allow
        );
        assert_eq!(
            policy.verdict("edit", Some(&file), Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // Outside the working folder a session grant does not apply.
        let outside = s(&f.outside.join("o.txt"));
        assert_eq!(
            policy.verdict("write", Some(&outside), Some(&ws), &f.workspace),
            Verdict::Ask
        );
        policy.reset_session();
        assert_eq!(
            policy.verdict("write", Some(&file), Some(&ws), &f.workspace),
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
            policy.verdict("write", Some(&inside), Some(&ws), &f.workspace),
            Verdict::Allow
        );
        let outside = s(&f.outside.join("o.txt"));
        assert_eq!(
            policy.verdict("write", Some(&outside), Some(&ws), &f.workspace),
            Verdict::Ask
        );
        assert_eq!(
            policy.verdict("bash", None, Some(&ws), &f.workspace),
            Verdict::Ask
        );
        assert_eq!(
            policy.verdict("write", None, Some(&ws), &f.workspace),
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
            policy.verdict("write", Some(&escaped), Some(&ws), &f.workspace),
            Verdict::Ask
        );
        // A dangling link fails closed as well.
        std::os::unix::fs::symlink(f.outside.join("missing"), f.workspace.join("dangling"))
            .unwrap();
        let dangling = s(&f.workspace.join("dangling/new.txt"));
        assert_eq!(
            policy.verdict("write", Some(&dangling), Some(&ws), &f.workspace),
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
