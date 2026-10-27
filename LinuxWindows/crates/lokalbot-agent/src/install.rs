//! Agent Mode setup (`AgentRuntimeInstaller.swift`): downloads and verifies
//! Bun, then installs pi from the public npm registry with the frozen
//! lockfile bundled in the app. Everything is assembled in a staging folder
//! and swapped into place only after every digest matched, so a failed setup
//! leaves nothing half-written.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use anyhow::{Context as _, Result};

use crate::digest;
use crate::layout::{BUN_BINARY, RuntimeLayout, VersionMarker};
use crate::manifest::{BUN_VERSION, PI_VERSION, RuntimeArtifact, RuntimeManifest};

/// What the setup card shows.
#[derive(Clone, Debug, PartialEq)]
pub enum InstallPhase {
    Checking,
    Idle,
    /// 0…1, or `None` when the size is unknown.
    Downloading {
        name: String,
        progress: Option<f32>,
    },
    Installing {
        name: String,
    },
    Installed,
    Failed(String),
}

#[derive(Debug, thiserror::Error)]
pub enum InstallError {
    #[error("Couldn't download {0} ({1}). Check your connection and try again.")]
    Download(String, String),
    #[error(
        "The downloaded {0} failed its checksum and was discarded. Try again; if it keeps failing, the release may have been tampered with."
    )]
    Checksum(String),
    #[error("Couldn't unpack {0}: {1}.")]
    Unpack(String, String),
    #[error("Agent setup couldn't find the expected files: {0}.")]
    Layout(String),
    #[error(
        "Couldn't install pi from the public package registry. Check your connection and try again.\n{0}"
    )]
    PackageInstall(String),
    #[error("Setup failed: {0}")]
    Other(String),
}

/// Downloads one pinned artifact to `dest`, verifying size and digest.
pub type Fetch = Box<
    dyn Fn(&RuntimeArtifact, &Path, &AtomicBool, &mut dyn FnMut(u64, u64)) -> Result<()>
        + Send
        + Sync,
>;
/// Installs the pi packages with `bun` into `dest` (which holds the template).
pub type PackageInstaller = Box<dyn Fn(&Path, &Path) -> Result<(), InstallError> + Send + Sync>;

pub struct Installer {
    layout: RuntimeLayout,
    manifest: RuntimeManifest,
    fetch: Fetch,
    package_installer: PackageInstaller,
}

impl Installer {
    pub fn new(layout: RuntimeLayout, manifest: RuntimeManifest) -> Self {
        Self {
            layout,
            manifest,
            fetch: Box::new(|artifact, dest, cancel, progress| {
                let spec = lokalbot_ai::DownloadSpec {
                    url: artifact.url.clone(),
                    sha256: artifact.sha256.clone(),
                    size: artifact.size,
                    dest: dest.to_path_buf(),
                };
                lokalbot_ai::download(&spec, cancel, progress)
            }),
            package_installer: Box::new(install_packages),
        }
    }

    /// For tests: local artifacts and a fake `bun install`.
    pub fn with_hooks(
        layout: RuntimeLayout,
        manifest: RuntimeManifest,
        fetch: Fetch,
        package_installer: PackageInstaller,
    ) -> Self {
        Self {
            layout,
            manifest,
            fetch,
            package_installer,
        }
    }

    pub fn layout(&self) -> &RuntimeLayout {
        &self.layout
    }

    pub fn manifest(&self) -> &RuntimeManifest {
        &self.manifest
    }

    /// The cheap receipt check used when the Agent page opens.
    pub fn initial_phase(&self) -> InstallPhase {
        if self.layout.is_installed(&self.manifest) {
            InstallPhase::Installed
        } else {
            InstallPhase::Idle
        }
    }

    /// Installs unless already installed (`force` repairs). Blocking.
    pub fn install(
        &self,
        force: bool,
        cancel: &AtomicBool,
        phase: &mut dyn FnMut(InstallPhase),
    ) -> Result<(), InstallError> {
        if !force && self.layout.is_installed(&self.manifest) {
            phase(InstallPhase::Installed);
            return Ok(());
        }
        let root = self.layout.root();
        let parent = root
            .parent()
            .ok_or_else(|| InstallError::Layout("the runtime folder has no parent".into()))?
            .to_path_buf();
        std::fs::create_dir_all(&parent).map_err(|e| InstallError::Other(e.to_string()))?;
        let staging = parent.join(format!(
            "agent-runtime.staging-{}",
            uuid::Uuid::new_v4().simple()
        ));
        let result = self.install_into(&staging, cancel, phase);
        let _ = std::fs::remove_dir_all(&staging);
        result?;
        phase(InstallPhase::Installed);
        Ok(())
    }

    fn install_into(
        &self,
        staging: &Path,
        cancel: &AtomicBool,
        phase: &mut dyn FnMut(InstallPhase),
    ) -> Result<(), InstallError> {
        let manifest = &self.manifest;
        let bun = &manifest.bun;
        std::fs::create_dir_all(staging).map_err(|e| InstallError::Other(e.to_string()))?;

        phase(InstallPhase::Downloading {
            name: bun.name.clone(),
            progress: Some(0.0),
        });
        let archive_name = bun.url.rsplit('/').next().unwrap_or("bun.zip").to_string();
        let archive = staging.join(&archive_name);
        let mut on_progress = |done: u64, total: u64| {
            phase(InstallPhase::Downloading {
                name: bun.name.clone(),
                progress: (total > 0).then(|| done as f32 / total as f32),
            });
        };
        (self.fetch)(bun, &archive, cancel, &mut on_progress).map_err(|err| {
            let text = format!("{err:#}");
            if text.contains("integrity") || text.contains("SHA-256") {
                InstallError::Checksum(bun.name.clone())
            } else {
                InstallError::Download(bun.name.clone(), text)
            }
        })?;
        // The fetch verifies the digest; check again so a hook cannot skip it.
        if !digest::file_hex(&archive).is_ok_and(|actual| actual.eq_ignore_ascii_case(&bun.sha256))
        {
            return Err(InstallError::Checksum(bun.name.clone()));
        }

        phase(InstallPhase::Installing {
            name: bun.name.clone(),
        });
        let extract = staging.join("bun-extract");
        lokalbot_ai::extract_archive(&archive, &extract)
            .map_err(|err| InstallError::Unpack(archive_name.clone(), format!("{err:#}")))?;
        let binary = extract.join(&bun.binary_path_in_archive);
        if !binary.is_file() {
            return Err(InstallError::Layout(
                "bun binary missing from archive".into(),
            ));
        }
        make_executable(&binary)?;
        let bun_digest =
            digest::file_hex(&binary).map_err(|e| InstallError::Other(format!("{e:#}")))?;
        if manifest
            .bun_binary_sha256
            .as_ref()
            .is_some_and(|expected| !bun_digest.eq_ignore_ascii_case(expected))
        {
            return Err(InstallError::Checksum(bun.name.clone()));
        }
        verify_template(manifest)?;

        let pi_name = format!("pi {PI_VERSION}");
        phase(InstallPhase::Installing {
            name: pi_name.clone(),
        });
        let pi_stage = staging.join("pi-install");
        crate::resources::write_package_template(&pi_stage)
            .map_err(|e| InstallError::Other(format!("{e:#}")))?;
        (self.package_installer)(&binary, &pi_stage)?;
        let cli = pi_stage.join("node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js");
        if !cli.is_file() {
            return Err(InstallError::Layout("pi cli.js missing from bundle".into()));
        }
        let cli_digest =
            digest::file_hex(&cli).map_err(|e| InstallError::Other(format!("{e:#}")))?;
        if manifest
            .pi_cli_sha256
            .as_ref()
            .is_some_and(|expected| !cli_digest.eq_ignore_ascii_case(expected))
        {
            return Err(InstallError::Checksum(pi_name));
        }
        let tree_digest =
            digest::tree_hex(&pi_stage).map_err(|e| InstallError::Other(format!("{e:#}")))?;
        if manifest
            .pi_runtime_tree_sha256
            .as_ref()
            .is_some_and(|expected| !tree_digest.eq_ignore_ascii_case(expected))
        {
            log::warn!("pi runtime tree digest {tree_digest} does not match the pin");
            return Err(InstallError::Checksum(format!("{pi_name} runtime")));
        }

        let assembled = staging.join("agent-runtime");
        let assembled_layout = RuntimeLayout::new(&assembled);
        let installed_bun = assembled_layout.bun();
        std::fs::create_dir_all(installed_bun.parent().unwrap_or(&assembled))
            .map_err(|e| InstallError::Other(e.to_string()))?;
        std::fs::rename(&binary, &installed_bun).map_err(|e| InstallError::Other(e.to_string()))?;
        make_executable(&installed_bun)?;
        std::fs::rename(&pi_stage, assembled_layout.pi_dir())
            .map_err(|e| InstallError::Other(e.to_string()))?;
        let pi_dir = assembled_layout.pi_dir();
        let hex = |path: PathBuf| {
            digest::file_hex(&path).map_err(|e| InstallError::Other(format!("{e:#}")))
        };
        let marker = VersionMarker {
            bun_version: BUN_VERSION.into(),
            pi_version: PI_VERSION.into(),
            bun_archive_sha256: bun.sha256.to_lowercase(),
            bun_binary_sha256: bun_digest,
            pi_cli_sha256: cli_digest,
            package_json_sha256: hex(pi_dir.join("package.json"))?,
            lockfile_sha256: hex(pi_dir.join("bun.lock"))?,
            pi_runtime_tree_sha256: tree_digest,
        };
        let marker_path = assembled_layout.version_marker();
        let bytes = serde_json::to_vec(&marker).map_err(|e| InstallError::Other(e.to_string()))?;
        lokalbot_core::library::write_atomic(&marker_path, &bytes)
            .map_err(|e| InstallError::Other(e.to_string()))?;
        crate::fsutil::restrict_file(&marker_path);
        crate::resources::materialize(&assembled_layout)
            .map_err(|e| InstallError::Other(format!("{e:#}")))?;

        // Swap: the old runtime (if any) moves aside first, so a failed
        // rename never leaves a half-removed folder in place.
        let root = self.layout.root();
        let previous = staging.join("previous");
        if root.exists() {
            std::fs::rename(root, &previous).map_err(|e| {
                InstallError::Other(format!(
                    "the current Agent runtime is in use ({e}); stop running tasks and try again"
                ))
            })?;
        }
        if let Err(err) = std::fs::rename(&assembled, root) {
            if previous.exists() {
                let _ = std::fs::rename(&previous, root);
            }
            return Err(InstallError::Other(err.to_string()));
        }
        Ok(())
    }

    /// The user's "Verify Agent runtime": hashes every runtime file.
    pub fn verify(&self) -> bool {
        self.layout.is_integrity_valid(&self.manifest)
    }
}

fn verify_template(manifest: &RuntimeManifest) -> Result<(), InstallError> {
    use sha2::{Digest as _, Sha256};
    let package = hex::encode(Sha256::digest(crate::resources::PACKAGE_JSON.as_bytes()));
    let lock = hex::encode(Sha256::digest(crate::resources::BUN_LOCK.as_bytes()));
    if manifest
        .package_json_sha256
        .as_ref()
        .is_some_and(|expected| !package.eq_ignore_ascii_case(expected))
    {
        return Err(InstallError::Checksum("pi package manifest".into()));
    }
    if manifest
        .lockfile_sha256
        .as_ref()
        .is_some_and(|expected| !lock.eq_ignore_ascii_case(expected))
    {
        return Err(InstallError::Checksum("pi lockfile".into()));
    }
    Ok(())
}

fn make_executable(path: &Path) -> Result<(), InstallError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| InstallError::Other(e.to_string()))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// The command `bun install` runs with (exposed for tests).
pub fn package_install_command(bun: &Path, destination: &Path) -> Command {
    let mut command = Command::new(bun);
    command
        .args([
            "install",
            "--production",
            "--frozen-lockfile",
            "--ignore-scripts",
            "--no-progress",
        ])
        .current_dir(destination)
        // A private cache inside staging: nothing lands in the user's
        // ~/.bun, and no stale cache entry can stand in for a download
        // (the lockfile's integrity hashes are still checked).
        .env(
            "BUN_INSTALL_CACHE_DIR",
            destination
                .parent()
                .unwrap_or(destination)
                .join("bun-cache"),
        )
        .env("BUN_NO_UPDATE_NOTIFIER", "1");
    command
}

/// `bun install --production --frozen-lockfile --ignore-scripts` in
/// `destination`, which already holds the package template.
pub fn install_packages(bun: &Path, destination: &Path) -> Result<(), InstallError> {
    let log_path = destination.join("install.log");
    let log = std::fs::File::create(&log_path).map_err(|e| InstallError::Other(e.to_string()))?;
    let mut command = package_install_command(bun, destination);
    command
        .stdout(
            log.try_clone()
                .map_err(|e| InstallError::Other(e.to_string()))?,
        )
        .stderr(log);
    let status =
        crate::process::run_tree(command, Duration::from_secs(600)).context("running bun install");
    let detail = std::fs::read_to_string(&log_path)
        .map(|text| {
            let trimmed = text.trim();
            let start = trimmed
                .char_indices()
                .rev()
                .nth(1999)
                .map(|(at, _)| at)
                .unwrap_or(0);
            trimmed[start..].to_string()
        })
        .unwrap_or_default();
    let _ = std::fs::remove_file(&log_path);
    match status {
        Ok(Some(0)) => Ok(()),
        Ok(code) => Err(InstallError::PackageInstall(if detail.is_empty() {
            format!("exit {}", code.map_or("signal".into(), |c| c.to_string()))
        } else {
            detail
        })),
        Err(err) => Err(InstallError::PackageInstall(format!("{err:#}"))),
    }
}

/// The binary name inside the runtime, for messages.
pub fn bun_binary_name() -> &'static str {
    BUN_BINARY
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::ArchiveKind;
    use std::sync::Arc;

    /// A zip holding `<folder>/bun` with `content`.
    fn bun_zip(dir: &Path, folder: &str, content: &[u8]) -> PathBuf {
        let path = dir.join("bun-test.zip");
        let file = std::fs::File::create(&path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        zip.start_file(format!("{folder}/{BUN_BINARY}"), options)
            .unwrap();
        std::io::Write::write_all(&mut zip, content).unwrap();
        zip.finish().unwrap();
        path
    }

    fn sha(bytes: &[u8]) -> String {
        use sha2::{Digest as _, Sha256};
        hex::encode(Sha256::digest(bytes))
    }

    struct Fixture {
        _dir: tempfile::TempDir,
        root: PathBuf,
        archive: PathBuf,
        manifest: RuntimeManifest,
    }

    fn fixture(binary: &[u8]) -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let archive = bun_zip(dir.path(), "bun-test", binary);
        let manifest = RuntimeManifest {
            bun: RuntimeArtifact {
                name: "Bun test".into(),
                url: "https://example.invalid/bun-test.zip".into(),
                sha256: crate::digest::file_hex(&archive).unwrap(),
                size: std::fs::metadata(&archive).unwrap().len(),
                archive_kind: ArchiveKind::Zip,
                binary_path_in_archive: format!("bun-test/{BUN_BINARY}"),
            },
            bun_binary_sha256: Some(sha(binary)),
            pi_cli_sha256: None,
            package_json_sha256: Some(crate::manifest::PACKAGE_JSON_SHA256.into()),
            lockfile_sha256: Some(crate::manifest::LOCKFILE_SHA256.into()),
            pi_runtime_tree_sha256: None,
            approximate_download_bytes: 0,
            approximate_installed_bytes: 0,
        };
        Fixture {
            root: dir.path().join("runtimes/agent-runtime"),
            archive,
            manifest,
            _dir: dir,
        }
    }

    fn installer(fixture: &Fixture, calls: Arc<parking_lot::Mutex<usize>>) -> Installer {
        let archive = fixture.archive.clone();
        Installer::with_hooks(
            RuntimeLayout::new(&fixture.root),
            fixture.manifest.clone(),
            Box::new(move |_artifact, dest, _cancel, progress| {
                std::fs::copy(&archive, dest)?;
                progress(1, 1);
                Ok(())
            }),
            Box::new(move |_bun, dest| {
                *calls.lock() += 1;
                let cli = dest.join("node_modules/@earendil-works/pi-coding-agent/dist/bundle");
                std::fs::create_dir_all(&cli).unwrap();
                std::fs::write(cli.join("cli.js"), "console.log('pi')").unwrap();
                Ok(())
            }),
        )
    }

    #[test]
    fn installs_verified_artifacts_into_the_layout() {
        let fixture = fixture(b"#!/bin/sh\necho bun\n");
        let calls = Arc::new(parking_lot::Mutex::new(0));
        let installer = installer(&fixture, calls.clone());
        assert_eq!(installer.initial_phase(), InstallPhase::Idle);
        let mut phases = Vec::new();
        installer
            .install(false, &AtomicBool::new(false), &mut |p| phases.push(p))
            .unwrap();
        let layout = RuntimeLayout::new(&fixture.root);
        assert!(layout.is_installed(&fixture.manifest));
        assert!(layout.is_integrity_valid(&fixture.manifest));
        assert!(layout.extension_dir().join("index.ts").is_file());
        assert!(
            phases
                .iter()
                .any(|p| matches!(p, InstallPhase::Downloading { .. }))
        );
        assert_eq!(phases.last(), Some(&InstallPhase::Installed));
        // No staging folder is left behind.
        let leftovers: Vec<_> = std::fs::read_dir(fixture.root.parent().unwrap())
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains("staging"))
            .collect();
        assert!(leftovers.is_empty());
        // Installed: a second install short-circuits; repair reinstalls.
        installer
            .install(false, &AtomicBool::new(false), &mut |_| {})
            .unwrap();
        assert_eq!(*calls.lock(), 1);
        installer
            .install(true, &AtomicBool::new(false), &mut |_| {})
            .unwrap();
        assert_eq!(*calls.lock(), 2);
    }

    #[test]
    fn binary_checksum_mismatch_installs_nothing() {
        let mut fixture = fixture(b"bun");
        fixture.manifest.bun_binary_sha256 = Some("0".repeat(64));
        let installer = installer(&fixture, Arc::new(parking_lot::Mutex::new(0)));
        let error = installer
            .install(false, &AtomicBool::new(false), &mut |_| {})
            .unwrap_err();
        assert!(matches!(error, InstallError::Checksum(_)), "{error}");
        assert!(!fixture.root.exists());
    }

    #[test]
    fn runtime_tree_checksum_mismatch_installs_nothing_and_keeps_the_old_runtime() {
        let mut fixture = fixture(b"bun");
        let installer_ok = installer(&fixture, Arc::new(parking_lot::Mutex::new(0)));
        installer_ok
            .install(false, &AtomicBool::new(false), &mut |_| {})
            .unwrap();
        fixture.manifest.pi_runtime_tree_sha256 = Some("1".repeat(64));
        let installer = installer(&fixture, Arc::new(parking_lot::Mutex::new(0)));
        let error = installer
            .install(true, &AtomicBool::new(false), &mut |_| {})
            .unwrap_err();
        assert!(matches!(error, InstallError::Checksum(name) if name.contains("runtime")));
        assert!(
            RuntimeLayout::new(&fixture.root).bun().is_file(),
            "the old runtime stays"
        );
    }

    #[test]
    fn deep_audit_detects_runtime_tampering() {
        let fixture = fixture(b"bun");
        installer(&fixture, Arc::new(parking_lot::Mutex::new(0)))
            .install(false, &AtomicBool::new(false), &mut |_| {})
            .unwrap();
        let layout = RuntimeLayout::new(&fixture.root);
        std::fs::write(layout.pi_dir().join("node_modules/extra.js"), "tampered").unwrap();
        assert!(
            layout.is_installed(&fixture.manifest),
            "the receipt check stays cheap"
        );
        assert!(!layout.is_integrity_valid(&fixture.manifest));
    }

    #[test]
    fn frozen_package_install_uses_the_expected_command() {
        let command = package_install_command(Path::new("/rt/bun"), Path::new("/stage/pi-install"));
        let args: Vec<String> = command
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            args,
            vec![
                "install",
                "--production",
                "--frozen-lockfile",
                "--ignore-scripts",
                "--no-progress"
            ]
        );
        assert_eq!(
            command.get_current_dir(),
            Some(Path::new("/stage/pi-install"))
        );
        let cache = command
            .get_envs()
            .find(|(k, _)| *k == "BUN_INSTALL_CACHE_DIR")
            .and_then(|(_, v)| v)
            .unwrap();
        assert_eq!(Path::new(cache), Path::new("/stage/bun-cache"));
    }
}
