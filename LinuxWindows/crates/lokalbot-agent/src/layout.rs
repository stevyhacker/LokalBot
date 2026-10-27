//! Where Agent Mode keeps its files (`AgentRuntimeLayout`).
//!
//! The runtime (Bun, pi and LokalBot's pi extension) is a machine-local
//! cache next to the llama.cpp runtime in `<library>/runtimes/`, not user
//! data. pi's session files, the task list and pi's own configuration live in
//! `<library>/agent/`, where macOS keeps them, so they follow
//! `LOKALBOT_STORAGE_ROOT` and stay with the rest of the library.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use lokalbot_core::LibraryPaths;

use crate::digest;
use crate::manifest::{BUN_VERSION, PI_VERSION, RuntimeManifest};

pub const BUN_BINARY: &str = if cfg!(windows) { "bun.exe" } else { "bun" };
const PI_CLI: &str = "pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js";

/// `version.json`: versions and the digests verified at install time.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionMarker {
    pub bun_version: String,
    pub pi_version: String,
    #[serde(rename = "bunArchiveSHA256")]
    pub bun_archive_sha256: String,
    #[serde(rename = "bunBinarySHA256")]
    pub bun_binary_sha256: String,
    #[serde(rename = "piCLISHA256")]
    pub pi_cli_sha256: String,
    #[serde(rename = "packageJSONSHA256")]
    pub package_json_sha256: String,
    #[serde(rename = "lockfileSHA256")]
    pub lockfile_sha256: String,
    #[serde(rename = "piRuntimeTreeSHA256")]
    pub pi_runtime_tree_sha256: String,
}

/// The installed runtime folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeLayout {
    root: PathBuf,
}

impl RuntimeLayout {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// `<library>/runtimes/agent-runtime`.
    pub fn for_library(paths: &LibraryPaths) -> Self {
        Self::new(paths.runtimes_dir().join("agent-runtime"))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn bun(&self) -> PathBuf {
        self.root.join("bun").join(BUN_BINARY)
    }

    pub fn pi_dir(&self) -> PathBuf {
        self.root.join("pi")
    }

    pub fn pi_cli(&self) -> PathBuf {
        self.root.join(PI_CLI)
    }

    pub fn version_marker(&self) -> PathBuf {
        self.root.join("version.json")
    }

    /// LokalBot's pi extension, written from the copy built into the app.
    pub fn extension_dir(&self) -> PathBuf {
        self.root.join("lokalbot-extension")
    }

    pub fn skill_dir(&self) -> PathBuf {
        self.root.join("lokalbot-cli-skill")
    }

    /// LokalBot's system prompt, written from the copy built into the app.
    pub fn system_prompt_file(&self) -> PathBuf {
        self.root.join("lokalbot-system-prompt.md")
    }

    fn read_marker(&self) -> Option<VersionMarker> {
        serde_json::from_slice(&std::fs::read(self.version_marker()).ok()?).ok()
    }

    /// Cheap receipt check for the normal launch path. Installation verifies
    /// every staged byte before the atomic swap, so routine entry only proves
    /// that the entry points and a matching receipt are present; use
    /// [`is_integrity_valid`](Self::is_integrity_valid) for a deep audit.
    pub fn is_installed(&self, manifest: &RuntimeManifest) -> bool {
        let pi = self.pi_dir();
        if !is_executable(&self.bun())
            || !self.pi_cli().is_file()
            || !pi.join("package.json").is_file()
            || !pi.join("bun.lock").is_file()
        {
            return false;
        }
        let Some(marker) = self.read_marker() else {
            return false;
        };
        marker.bun_version == BUN_VERSION
            && marker.pi_version == PI_VERSION
            && marker.bun_archive_sha256 == manifest.bun.sha256.to_lowercase()
            && receipt_matches(&marker.bun_binary_sha256, &manifest.bun_binary_sha256)
            && receipt_matches(&marker.pi_cli_sha256, &manifest.pi_cli_sha256)
            && receipt_matches(&marker.package_json_sha256, &manifest.package_json_sha256)
            && receipt_matches(&marker.lockfile_sha256, &manifest.lockfile_sha256)
            && receipt_matches(
                &marker.pi_runtime_tree_sha256,
                &manifest.pi_runtime_tree_sha256,
            )
    }

    /// Recursive audit: hashes every runtime file. Reserved for installation,
    /// launching a task, repair and the user's "Verify Agent runtime".
    pub fn is_integrity_valid(&self, manifest: &RuntimeManifest) -> bool {
        if !self.is_installed(manifest) {
            return false;
        }
        let Some(marker) = self.read_marker() else {
            return false;
        };
        let pi = self.pi_dir();
        let checks = [
            (digest::file_hex(&self.bun()), &marker.bun_binary_sha256),
            (digest::file_hex(&self.pi_cli()), &marker.pi_cli_sha256),
            (
                digest::file_hex(&pi.join("package.json")),
                &marker.package_json_sha256,
            ),
            (
                digest::file_hex(&pi.join("bun.lock")),
                &marker.lockfile_sha256,
            ),
            (digest::tree_hex(&pi), &marker.pi_runtime_tree_sha256),
        ];
        checks
            .into_iter()
            .all(|(actual, expected)| actual.is_ok_and(|actual| &actual == expected))
    }
}

fn receipt_matches(receipt: &str, expected: &Option<String>) -> bool {
    digest::is_hex_digest(receipt)
        && expected
            .as_ref()
            .is_none_or(|expected| receipt == expected.to_lowercase())
}

pub(crate) fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// `<library>/agent`: pi sessions, task metadata and pi's own configuration.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentDirectories {
    library_root: PathBuf,
}

impl AgentDirectories {
    pub fn new(paths: &LibraryPaths) -> Self {
        Self {
            library_root: paths.root().to_path_buf(),
        }
    }

    pub fn library_root(&self) -> &Path {
        &self.library_root
    }

    /// pi session JSONL files and `tasks.json` (`AgentRuntimeLayout.sessionsDirectory`).
    pub fn sessions(&self) -> PathBuf {
        self.library_root.join("agent").join("sessions")
    }

    /// `PI_CODING_AGENT_DIR`: pi's settings and state, isolated from `~/.pi`.
    pub fn pi_config(&self) -> PathBuf {
        self.library_root.join("agent").join("pi-config")
    }

    /// The remembered approval mode, kept out of `settings.json` like the
    /// macOS `lokalbotv3.agent.approvalMode` default.
    pub fn approval_mode_file(&self) -> PathBuf {
        self.library_root.join("agent").join("approval-mode.json")
    }

    /// Records of running pi processes, so a later run can stop leftovers.
    pub fn process_markers(&self) -> PathBuf {
        self.library_root.join("agent").join("processes")
    }

    /// The default working folder, a sibling of the library
    /// (`AppDirectories.agentWorkspace(forLibraryRoot:)`), so the private
    /// library is never an implicit working folder.
    pub fn default_workspace(&self) -> PathBuf {
        let resolved =
            dunce::canonicalize(&self.library_root).unwrap_or_else(|_| self.library_root.clone());
        let name = resolved
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "LokalBot".into());
        resolved
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| resolved.clone())
            .join(format!("{name}.agent-workspace"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_paths() {
        let layout = RuntimeLayout::new("/rt");
        assert_eq!(layout.bun(), Path::new("/rt").join("bun").join(BUN_BINARY));
        assert!(
            layout
                .pi_cli()
                .ends_with("pi/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js")
        );
        assert_eq!(layout.version_marker(), Path::new("/rt/version.json"));
    }

    #[test]
    fn runtime_lives_with_the_other_runtimes_and_sessions_with_the_library() {
        let paths = LibraryPaths::new("/data/LokalBot");
        assert_eq!(
            RuntimeLayout::for_library(&paths).root(),
            Path::new("/data/LokalBot/runtimes/agent-runtime")
        );
        let dirs = AgentDirectories::new(&paths);
        assert_eq!(dirs.sessions(), Path::new("/data/LokalBot/agent/sessions"));
        assert_eq!(
            dirs.pi_config(),
            Path::new("/data/LokalBot/agent/pi-config")
        );
        assert_eq!(
            dirs.default_workspace(),
            Path::new("/data/LokalBot.agent-workspace")
        );
    }

    #[test]
    fn marker_uses_the_macos_keys() {
        let marker = VersionMarker {
            bun_version: "1".into(),
            pi_version: "2".into(),
            bun_archive_sha256: "a".into(),
            bun_binary_sha256: "b".into(),
            pi_cli_sha256: "c".into(),
            package_json_sha256: "d".into(),
            lockfile_sha256: "e".into(),
            pi_runtime_tree_sha256: "f".into(),
        };
        let json = serde_json::to_string(&marker).unwrap();
        for key in [
            "bunVersion",
            "piVersion",
            "bunArchiveSHA256",
            "bunBinarySHA256",
            "piCLISHA256",
            "packageJSONSHA256",
            "lockfileSHA256",
            "piRuntimeTreeSHA256",
        ] {
            assert!(json.contains(&format!("\"{key}\"")), "{key} in {json}");
        }
    }
}
