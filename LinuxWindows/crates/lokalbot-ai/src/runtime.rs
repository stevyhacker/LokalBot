//! The built-in llama.cpp runtime (`Engines/LlamaServer.swift`,
//! `CLISupport/LlamaServerRole.swift`, `InferenceBroker.swift`).
//!
//! macOS bundles a source build; here the pinned prebuilt release of
//! ggml-org/llama.cpp is downloaded once, verified, and unpacked into
//! `<root>/runtimes/llama-cpp/<build>-<asset tag>/`. Each role (Think,
//! embeddings, autocomplete) is its own `llama-server` subprocess on a fixed
//! loopback port with a random bearer token. A [`Lease`] keeps a server loaded;
//! after the last lease drops it lingers for the role's idle time, then stops.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, anyhow};
use parking_lot::{Condvar, Mutex};
use serde::{Deserialize, Serialize};

use lokalbot_core::{LibraryPaths, Settings};

use crate::catalog::{self, ModelEntry};
use crate::download::{self, DownloadSpec};
use crate::error::{AiError, check_cancelled};
use crate::process;

mod cuda;

/// The llama.cpp release every platform runs. macOS builds the same commit
/// from its `v0.7.0` tag.
pub const LLAMA_BUILD: &str = "b11669";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LlamaBackend {
    Cpu,
    Vulkan,
    Cuda,
}

impl LlamaBackend {
    fn preference(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "cpu" => Some(Self::Cpu),
            "vulkan" => Some(Self::Vulkan),
            "cuda" => Some(Self::Cuda),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            LlamaBackend::Cpu => "CPU",
            LlamaBackend::Vulkan => "Vulkan",
            LlamaBackend::Cuda => "CUDA",
        }
    }

    pub fn is_gpu(self) -> bool {
        self != Self::Cpu
    }
}

/// One prebuilt release archive (sizes and digests from the GitHub release API).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RuntimeAsset {
    pub backend: LlamaBackend,
    /// The release's platform tag, e.g. `win-vulkan-x64`.
    pub tag: &'static str,
    pub name: &'static str,
    pub size: u64,
    pub sha256: &'static str,
}

impl RuntimeAsset {
    pub fn url(&self) -> String {
        format!(
            "https://github.com/ggml-org/llama.cpp/releases/download/{LLAMA_BUILD}/{}",
            self.name
        )
    }

    fn folder(&self) -> String {
        format!("{LLAMA_BUILD}-{}", self.tag)
    }
}

#[cfg(windows)]
const ASSETS: &[RuntimeAsset] = &[
    cuda::SERVERS[0],
    cuda::SERVERS[1],
    RuntimeAsset {
        backend: LlamaBackend::Vulkan,
        tag: "win-vulkan-x64",
        name: "llama-b11669-bin-win-vulkan-x64.zip",
        size: 32_182_350,
        sha256: "2c07574e7bde71321cb785282b20cc821e951132149eeceeea32ddebdbf0598e",
    },
    RuntimeAsset {
        backend: LlamaBackend::Cpu,
        tag: "win-cpu-x64",
        name: "llama-b11669-bin-win-cpu-x64.zip",
        size: 19_537_886,
        sha256: "37b3efcf962847ca869745fd4ccf7f5e7e8dacfeff9fa3523b4ca8cdc66d632b",
    },
];

#[cfg(not(windows))]
const ASSETS: &[RuntimeAsset] = &[
    cuda::SERVERS[0],
    cuda::SERVERS[1],
    RuntimeAsset {
        backend: LlamaBackend::Vulkan,
        tag: "ubuntu-vulkan-x64",
        name: "llama-b11669-bin-ubuntu-vulkan-x64.tar.gz",
        size: 30_497_889,
        sha256: "e8709e5ba6c1b093dea7f3de57f4aba842f9a188fba6b465782d65d6fcfa4d9f",
    },
    RuntimeAsset {
        backend: LlamaBackend::Cpu,
        tag: "ubuntu-x64",
        name: "llama-b11669-bin-ubuntu-x64.tar.gz",
        size: 17_851_611,
        sha256: "cf07c1c112d709bd67e522017471de57ed0ec8bea031d732c5422351c07f65ac",
    },
];

/// The assets for this platform.
pub fn assets() -> &'static [RuntimeAsset] {
    ASSETS
}

pub fn asset(backend: LlamaBackend) -> Option<&'static RuntimeAsset> {
    ASSETS.iter().find(|a| a.backend == backend)
}

/// Upper bound before probing system CUDA libraries. Auto keeps its Vulkan /
/// CPU policy until native NVIDIA validation supports changing that default.
pub fn download_bytes(preference: &str) -> u64 {
    match LlamaBackend::preference(preference) {
        Some(backend) => backend_download_bytes(backend),
        None => ASSETS
            .iter()
            .filter(|a| a.backend != LlamaBackend::Cuda)
            .map(|a| a.size)
            .max()
            .unwrap_or(0),
    }
}

fn backend_download_bytes(backend: LlamaBackend) -> u64 {
    if backend == LlamaBackend::Cuda {
        return cuda::likely().download_bytes();
    }
    asset(backend).map_or(0, |a| a.size)
}

const SERVER_BINARY: &str = if cfg!(windows) {
    "llama-server.exe"
} else {
    "llama-server"
};

/// The folder beside `lokalbot.exe` that holds [`VC_RUNTIME_DLLS`]
/// (scripts/package.sh). lokalbot-update's `install.rs` names it too.
pub const VC_RUNTIME_DIR: &str = "vc-runtime";
/// The Microsoft Visual C++ runtime DLLs upstream's Windows builds import.
/// Windows without the Visual C++ Redistributable has none of them, so each
/// runtime gets the bundled copies beside its `llama-server.exe`.
const VC_RUNTIME_DLLS: [&str; 3] = ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"];
const VC_REDIST_URL: &str = "https://aka.ms/vc14/vc_redist.x64.exe";
/// STATUS_DLL_NOT_FOUND: Windows found no file for a DLL the program
/// imports. The process exits with it before printing anything.
const STATUS_DLL_NOT_FOUND: i32 = 0xC000_0135_u32 as i32;

// ------------------------------------------------------------------- roles

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    /// Think: summaries, digests, Ask.
    Main,
    Embedder,
    Autocomplete,
}

impl Role {
    pub const ALL: [Role; 3] = [Role::Main, Role::Embedder, Role::Autocomplete];

    /// The ports the CLI and MCP clients rely on; they never move.
    pub fn release_port(self) -> u16 {
        match self {
            Role::Main => 17_872,
            Role::Embedder => 17_873,
            Role::Autocomplete => 17_874,
        }
    }

    /// `release_port` plus `LOKALBOT_PORT_OFFSET`, so a development copy or a
    /// test run never fights the installed app for a port.
    pub fn port(self) -> u16 {
        self.release_port().saturating_add(port_offset())
    }

    pub fn context_tokens(self) -> u32 {
        match self {
            Role::Main => 32_768,
            Role::Embedder => 2_048,
            Role::Autocomplete => 4_096,
        }
    }

    pub fn idle_timeout(self) -> Duration {
        match self {
            Role::Main | Role::Embedder => Duration::from_secs(600),
            Role::Autocomplete => Duration::from_secs(900),
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Role::Main => "main",
            Role::Embedder => "embedder",
            Role::Autocomplete => "autocomplete",
        }
    }

    /// Whether starting this role's server may download the llama.cpp
    /// build. Autocomplete starts as you type, so it only ever uses a build
    /// that is already installed.
    fn downloads_runtime(self) -> bool {
        self != Role::Autocomplete
    }

    /// Role arguments, keeping only flags this build understands.
    fn extra_args(self, flags: &[String]) -> Vec<String> {
        let has = |flag: &str| flags.iter().any(|f| f == flag);
        let mut args: Vec<String> = Vec::new();
        match self {
            Role::Main => {
                if has("--cache-ram") {
                    args.extend(["--cache-ram".into(), "2048".into()]);
                }
                if has("--reasoning") {
                    args.extend(["--reasoning".into(), "on".into()]);
                }
            }
            // EmbeddingGemma carries its own pooling; as a bidirectional
            // encoder each input must fit one micro-batch.
            Role::Embedder => {
                args.extend(
                    [
                        "--embeddings",
                        "-b",
                        "2048",
                        "-ub",
                        "2048",
                        "--parallel",
                        "1",
                    ]
                    .map(String::from),
                );
            }
            Role::Autocomplete => {
                args.extend(["--parallel".into(), "1".into()]);
                if has("--cache-ram") {
                    args.extend(["--cache-ram".into(), "512".into()]);
                }
            }
        }
        args
    }
}

pub fn port_offset() -> u16 {
    std::env::var("LOKALBOT_PORT_OFFSET")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(0)
}

// ------------------------------------------------------------- installation

/// `install.json` inside an installed runtime folder.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct InstallRecord {
    build: String,
    asset: String,
    sha256: String,
    backend: LlamaBackend,
    /// `llama-server` relative to the runtime folder.
    server: String,
    #[serde(default)]
    version: String,
    /// The flags from `--help` that LokalBot passes conditionally.
    #[serde(default)]
    flags: Vec<String>,
    /// Which `CONDITIONAL_FLAGS` list produced `flags`.
    #[serde(default)]
    probe: u32,
    /// "system" after a successful device probe, or the companion archive's
    /// pinned digest. Absent on installations predating CUDA support.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cuda_libraries: Option<String>,
    /// Setup kept complete, verified files although its final device check
    /// failed. Background starts skip CUDA until explicit setup confirms one.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    cuda_unverified: bool,
}

/// Bump when `CONDITIONAL_FLAGS` changes so installed runtimes re-probe.
const PROBE_VERSION: u32 = 2;

/// `backend.json`: the result of the last auto-detection.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct BackendChoice {
    build: String,
    backend: LlamaBackend,
    #[serde(default)]
    device: Option<String>,
}

const CONDITIONAL_FLAGS: [&str; 5] = [
    "--reasoning",
    "--cache-ram",
    "--no-ui",
    "--no-webui",
    "--jinja",
];

const CUDA_UNAVAILABLE: &str = "CUDA could not initialize with the matching runtime libraries. Check available GPU memory and the NVIDIA driver; newer PTX or driver features may require a driver update. Choose Vulkan or CPU if unsupported.";

struct Installer {
    paths: LibraryPaths,
    preference: Mutex<String>,
    /// The backend this session runs, once known.
    active: Mutex<Option<LlamaBackend>>,
    /// Cache successes and failures until repair, a backend change, or a failed launch.
    /// Holding this lock during detection also coalesces simultaneous role starts.
    devices: Mutex<HashMap<PathBuf, std::result::Result<GpuDevice, String>>>,
    /// A backend change while a probe holds `devices` (up to 30 s) marks the
    /// cache stale instead of blocking the settings thread.
    devices_stale: AtomicBool,
    lock: Mutex<()>,
}

impl Installer {
    fn root(&self) -> PathBuf {
        self.paths.runtimes_dir().join("llama-cpp")
    }

    fn folder(&self, asset: &RuntimeAsset) -> PathBuf {
        self.root().join(asset.folder())
    }

    /// The installed build of `backend`. CUDA has one per toolkit.
    fn record(&self, backend: LlamaBackend) -> Option<(InstallRecord, PathBuf)> {
        ASSETS
            .iter()
            .filter(|asset| asset.backend == backend)
            .find_map(|asset| self.installed(asset))
    }

    fn installed(&self, asset: &RuntimeAsset) -> Option<(InstallRecord, PathBuf)> {
        let backend = asset.backend;
        let folder = self.folder(asset);
        let mut record: InstallRecord =
            serde_json::from_slice(&std::fs::read(folder.join("install.json")).ok()?).ok()?;
        if record.probe < PROBE_VERSION {
            let binary = folder.join(&record.server);
            if binary.is_file() {
                let (version, flags) = probe_capabilities(&binary);
                record.version = version;
                record.flags = flags;
                record.probe = PROBE_VERSION;
                if let Ok(bytes) = serde_json::to_vec_pretty(&record) {
                    let _ =
                        lokalbot_core::library::write_atomic(&folder.join("install.json"), &bytes);
                }
            }
        }
        let binary = folder.join(&record.server);
        let libraries_ready = backend != LlamaBackend::Cuda
            || match (
                record.cuda_libraries.as_deref(),
                cuda::build_for(asset.name),
            ) {
                (Some("system"), Some(_)) => true,
                (Some(digest), Some(build)) if digest == build.libraries.sha256 => {
                    binary.parent().is_some_and(|dir| build.complete(dir))
                }
                _ => false,
            };
        (record.sha256 == asset.sha256
            && record.build == LLAMA_BUILD
            && record.backend == backend
            && binary.is_file()
            && libraries_ready)
            .then_some((record, binary))
    }

    fn saved_choice(&self) -> Option<BackendChoice> {
        let choice: BackendChoice =
            serde_json::from_slice(&std::fs::read(self.root().join("backend.json")).ok()?).ok()?;
        (choice.build == LLAMA_BUILD).then_some(choice)
    }

    fn save_choice(&self, backend: LlamaBackend, device: Option<String>) {
        let choice = BackendChoice {
            build: LLAMA_BUILD.into(),
            backend,
            device,
        };
        if let Ok(bytes) = serde_json::to_vec_pretty(&choice) {
            let _ = lokalbot_core::library::write_atomic(&self.root().join("backend.json"), &bytes);
        }
    }

    fn preference(&self) -> String {
        self.preference.lock().trim().to_ascii_lowercase()
    }

    /// A CUDA installation background starts may use: complete, and confirmed
    /// by a device check during setup.
    fn cuda_ready(&self) -> bool {
        self.record(LlamaBackend::Cuda)
            .is_some_and(|(record, _)| !record.cuda_unverified)
    }

    /// Whether auto-detection picks the backend: `auto`, and CUDA until its
    /// setup succeeds, so selecting CUDA never stops working built-in models.
    fn automatic(&self) -> bool {
        match LlamaBackend::preference(&self.preference()) {
            None => true,
            Some(LlamaBackend::Cuda) => !self.cuda_ready(),
            Some(_) => false,
        }
    }

    fn accepts_backend(&self, backend: LlamaBackend) -> bool {
        match LlamaBackend::preference(&self.preference()) {
            Some(selected) if selected == backend => true,
            _ => backend != LlamaBackend::Cuda && self.automatic(),
        }
    }

    /// Downloads and unpacks one backend unless it is already installed.
    fn install(
        &self,
        backend: LlamaBackend,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<(InstallRecord, PathBuf)> {
        check_cancelled(cancel)?;
        // A busy GPU or changed driver does not make an intact installation
        // corrupt. Startup and explicit repair validate execution separately.
        if let Some(installed) = self.record(backend) {
            return Ok(installed);
        }
        let asset = if backend == LlamaBackend::Cuda {
            &cuda::select()?.server
        } else {
            asset(backend).ok_or_else(|| {
                anyhow!(
                    "llama.cpp has no {} build for this platform",
                    backend.label()
                )
            })?
        };
        self.download_and_unpack(asset, cancel, progress)
    }

    /// [`Self::install`] after it found no installation and chose `asset`.
    fn download_and_unpack(
        &self,
        asset: &RuntimeAsset,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<(InstallRecord, PathBuf)> {
        let backend = asset.backend;
        let cuda_build = cuda::build_for(asset.name);
        let downloads = self.root().join(".downloads");
        let archive = downloads.join(asset.name);
        let spec = DownloadSpec {
            url: asset.url(),
            sha256: asset.sha256.into(),
            size: asset.size,
            dest: archive.clone(),
        };
        let total = cuda_build.map_or(asset.size, cuda::Build::download_bytes);
        download::download(&spec, cancel, &mut |done, _| progress(done, total))
            .with_context(|| format!("downloading the llama.cpp {} runtime", backend.label()))?;

        let folder = self.folder(asset);
        let staging = self
            .root()
            .join(format!(".staging-{}", uuid::Uuid::new_v4().simple()));
        let result = (|| -> Result<(InstallRecord, PathBuf)> {
            download::extract_archive(&archive, &staging)?;
            check_cancelled(cancel)?;
            let server = find_file(&staging, SERVER_BINARY, 4)
                .ok_or_else(|| anyhow!("the llama.cpp archive has no {SERVER_BINARY}"))?;
            let relative = server
                .strip_prefix(&staging)?
                .to_string_lossy()
                .replace('\\', "/");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt as _;
                let mut perms = std::fs::metadata(&server)?.permissions();
                perms.set_mode(perms.mode() | 0o755);
                std::fs::set_permissions(&server, perms)?;
            }
            // Before any GPU check: a missing system library fails every one.
            check_loads(&server)?;
            let (cuda_libraries, cuda_unverified) = if let Some(build) = cuda_build {
                let (libraries, checked) = self.prepare_cuda(&server, build, cancel, progress)?;
                // A GPU filled by another app fails only the final check. Keep
                // the verified files: setup reports the failure, and a retry
                // repeats the check without downloading them again.
                if let Err(error) = &checked {
                    log::warn!("llama.cpp CUDA: keeping the downloaded runtime; {error:#}");
                }
                (Some(libraries), checked.is_err())
            } else {
                (None, false)
            };
            check_cancelled(cancel)?;
            let (version, flags) = probe_capabilities(&server);
            let record = InstallRecord {
                build: LLAMA_BUILD.into(),
                asset: asset.name.into(),
                sha256: asset.sha256.into(),
                backend,
                server: relative.clone(),
                version,
                flags,
                probe: PROBE_VERSION,
                cuda_libraries,
                cuda_unverified,
            };
            std::fs::write(
                staging.join("install.json"),
                serde_json::to_vec_pretty(&record)?,
            )?;
            if folder.exists() {
                std::fs::remove_dir_all(&folder)
                    .with_context(|| format!("replacing {}", folder.display()))?;
            }
            std::fs::rename(&staging, &folder)
                .with_context(|| format!("installing {}", folder.display()))?;
            // A successful system-library probe avoided the companion archive.
            let actual = asset.size
                + cuda_build
                    .filter(|build| {
                        record.cuda_libraries.as_deref() == Some(build.libraries.sha256)
                    })
                    .map_or(0, |build| build.libraries.size);
            progress(actual, actual);
            let installed_binary = folder.join(relative);
            let mut devices = self.devices.lock();
            if let Some(device) = devices.remove(&server) {
                devices.insert(installed_binary.clone(), device);
            }
            Ok((record, installed_binary))
        })();
        if result.is_err() {
            self.devices
                .lock()
                .retain(|binary, _| !binary.starts_with(&staging));
            let _ = std::fs::remove_dir_all(&staging);
        }
        let _ = std::fs::remove_file(&archive);
        let _ = std::fs::remove_file(download::sidecar_path(&archive));
        result
    }

    /// Reuses system CUDA libraries that pass a device check, else places the
    /// pinned companion libraries beside `server`. Returns what to record and,
    /// separately, the final device check, so callers can keep complete,
    /// verified files when only that check fails.
    fn prepare_cuda(
        &self,
        server: &Path,
        build: &cuda::Build,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<(String, Result<()>)> {
        check_cancelled(cancel)?;
        if self.device(server, LlamaBackend::Cuda).is_ok() {
            log::info!("llama.cpp CUDA: reusing system runtime libraries");
            return Ok(("system".into(), Ok(())));
        }
        check_cancelled(cancel)?;
        let companion = &build.libraries;
        let archive = self.root().join(".downloads").join(companion.name);
        let spec = DownloadSpec {
            url: companion.url(),
            sha256: companion.sha256.into(),
            size: companion.size,
            dest: archive.clone(),
        };
        download::download(&spec, cancel, &mut |done, _| {
            progress(build.server.size + done, build.download_bytes());
        })?;
        // A completed companion archive is temporary, including when extraction
        // or the final GPU probe fails. Interrupted downloads can still resume.
        let _archive = CompletedArchive(archive.clone());
        check_cancelled(cancel)?;
        let extracted = tempfile::tempdir_in(self.root())?;
        download::extract_archive(&archive, extracted.path())?;
        build.place_libraries(
            extracted.path(),
            server.parent().context("runtime has no directory")?,
        )?;
        check_cancelled(cancel)?;
        self.devices.lock().remove(server);
        let checked = self
            .device(server, LlamaBackend::Cuda)
            .map(|_| ())
            .context(CUDA_UNAVAILABLE);
        Ok((companion.sha256.into(), checked))
    }

    fn device(&self, binary: &Path, backend: LlamaBackend) -> Result<GpuDevice> {
        let mut devices = self.devices.lock();
        if self.devices_stale.swap(false, Ordering::AcqRel) {
            devices.clear();
        }
        devices
            .entry(binary.to_path_buf())
            .or_insert_with(|| probe_gpu(binary, backend).map_err(|err| format!("{err:#}")))
            .clone()
            .map_err(anyhow::Error::msg)
    }

    fn launch_failed(&self, binary: &Path) {
        // Re-detect after a previously successful probe fails to launch. Cache a
        // failed probe itself until the user retries setup or changes backend.
        let mut devices = self.devices.lock();
        if devices.get(binary).is_some_and(Result::is_ok) {
            devices.remove(binary);
        }
    }

    /// Only called by explicit setup/repair, never by a background server start.
    fn repair_cuda(
        &self,
        mut record: InstallRecord,
        binary: &Path,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<()> {
        check_cancelled(cancel)?;
        let build = cuda::build_for(&record.asset)
            .with_context(|| format!("{} is not a CUDA runtime", record.asset))?;
        let before = record.clone();
        let checked = match self.device(binary, LlamaBackend::Cuda) {
            Ok(_) => Ok(()),
            Err(error) if record.cuda_libraries.as_deref() != Some("system") => {
                Err(error.context(CUDA_UNAVAILABLE))
            }
            Err(_) => {
                cuda::driver_version()?;
                // Replace only the optional math libraries. The server folder
                // may be in use by another role, particularly on Windows.
                let prepared = self.prepare_cuda(binary, build, cancel, progress);
                if binary.parent().is_some_and(|dir| build.complete(dir)) {
                    // File completeness and GPU availability are different states.
                    // Keep newly repaired files even if this GPU is currently busy.
                    record.cuda_libraries = Some(build.libraries.sha256.into());
                }
                prepared.and_then(|(_, checked)| checked)
            }
        };
        // Only a confirmed device lets background starts switch to CUDA.
        if checked.is_ok() {
            record.cuda_unverified = false;
        }
        if record != before {
            let path = self.folder(&build.server).join("install.json");
            lokalbot_core::library::write_atomic(&path, &serde_json::to_vec_pretty(&record)?)?;
        }
        checked
    }

    /// The backend to run. `auto` takes Vulkan only when the Vulkan build
    /// lists a real GPU (a loader alone, or a software rasterizer, is not one).
    /// With `allow_download` false, only installed builds are considered.
    fn resolve(
        &self,
        allow_download: bool,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<(LlamaBackend, InstallRecord, PathBuf)> {
        let _guard = self.lock.lock();
        let get = |backend: LlamaBackend,
                   progress: &mut dyn FnMut(u64, u64)|
         -> Result<(InstallRecord, PathBuf)> {
            if allow_download {
                self.install(backend, cancel, progress)
            } else {
                self.record(backend).ok_or_else(|| {
                    AiError::Unavailable("The local model runtime isn't installed yet. Download it under Settings → Models.".into()).into()
                })
            }
        };
        let preference = self.preference();
        // Explicit setup installs CUDA. Until it succeeds, background starts
        // keep the automatic choice below instead of failing.
        if preference == "cuda" && (allow_download || self.cuda_ready()) {
            let (record, binary) = get(LlamaBackend::Cuda, progress)?;
            *self.active.lock() = Some(LlamaBackend::Cuda);
            return Ok((LlamaBackend::Cuda, record, binary));
        }
        let active = *self.active.lock();
        if let Some(active) = active
            && active != LlamaBackend::Cuda
            && self.accepts_backend(active)
        {
            let (record, binary) = get(active, progress)?;
            return Ok((active, record, binary));
        }
        let backend = match preference.as_str() {
            "cpu" => LlamaBackend::Cpu,
            "vulkan" => LlamaBackend::Vulkan,
            _ => match self.saved_choice() {
                Some(choice)
                    if choice.backend != LlamaBackend::Cuda
                        && self.record(choice.backend).is_some() =>
                {
                    choice.backend
                }
                _ if !vulkan_loader_present() => LlamaBackend::Cpu,
                _ => {
                    let vulkan = if allow_download {
                        self.install(LlamaBackend::Vulkan, cancel, progress).ok()
                    } else {
                        self.record(LlamaBackend::Vulkan)
                    };
                    check_cancelled(cancel)?;
                    match vulkan.as_ref().and_then(|(_, binary)| {
                        match self.device(binary, LlamaBackend::Vulkan) {
                            Ok(device) => Some(device),
                            Err(error) => {
                                log::warn!("llama.cpp Vulkan device detection failed: {error:#}");
                                None
                            }
                        }
                    }) {
                        Some(device) => {
                            log::info!("llama.cpp: using Vulkan on {}", device.name);
                            self.save_choice(LlamaBackend::Vulkan, Some(device.name));
                            LlamaBackend::Vulkan
                        }
                        None => {
                            if vulkan.is_some() {
                                log::info!("llama.cpp: no Vulkan GPU found; using the CPU build");
                                self.save_choice(LlamaBackend::Cpu, None);
                                // Only fetched to look for a GPU; the choice is remembered.
                                if let Some(asset) = asset(LlamaBackend::Vulkan) {
                                    let _ = std::fs::remove_dir_all(self.folder(asset));
                                }
                            }
                            LlamaBackend::Cpu
                        }
                    }
                }
            },
        };
        let (record, binary) = get(backend, progress)?;
        *self.active.lock() = Some(backend);
        Ok((backend, record, binary))
    }

    /// After a Vulkan server failed to start under `auto`.
    fn fall_back_to_cpu(&self) {
        *self.active.lock() = Some(LlamaBackend::Cpu);
        self.save_choice(LlamaBackend::Cpu, None);
    }
}

/// Removes a fully downloaded setup archive on success and on final failure.
struct CompletedArchive(PathBuf);

impl Drop for CompletedArchive {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
        let _ = std::fs::remove_file(download::sidecar_path(&self.0));
    }
}

fn find_file(dir: &Path, name: &str, depth: usize) -> Option<PathBuf> {
    let entries = std::fs::read_dir(dir).ok()?;
    let mut folders = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            folders.push(path);
        } else if path.file_name().is_some_and(|n| n == name) {
            return Some(path);
        }
    }
    if depth == 0 {
        return None;
    }
    folders.sort();
    folders
        .into_iter()
        .find_map(|folder| find_file(&folder, name, depth - 1))
}

fn server_command(binary: &Path) -> Command {
    let mut command = Command::new(binary);
    if let Some(dir) = binary.parent() {
        #[cfg(windows)]
        if let Some(bundled) = bundled_vc_runtime() {
            deploy_vc_runtime(&bundled, dir);
        }
        command.current_dir(dir);
        let extra = if cuda::is_runtime_dir(dir) {
            cuda::library_dirs()
        } else {
            Vec::new()
        };
        configure_library_path(&mut command, dir, extra);
    }
    command
}

fn configure_library_path(command: &mut Command, server_dir: &Path, extra: Vec<PathBuf>) {
    #[cfg(windows)]
    let key = "PATH";
    #[cfg(not(windows))]
    let key = "LD_LIBRARY_PATH";
    let mut paths = vec![server_dir.to_path_buf()];
    paths.extend(extra);
    if let Some(existing) = std::env::var_os(key) {
        paths.extend(std::env::split_paths(&existing).filter(|p| !p.as_os_str().is_empty()));
    }
    if let Ok(value) = std::env::join_paths(paths) {
        command.env(key, value);
    }
}

/// The Visual C++ runtime the Windows packages carry beside `lokalbot.exe`.
#[cfg(windows)]
fn bundled_vc_runtime() -> Option<PathBuf> {
    let dir = std::env::current_exe().ok()?.parent()?.join(VC_RUNTIME_DIR);
    dir.is_dir().then_some(dir)
}

/// Copies the bundled Visual C++ runtime beside the server in `server_dir`,
/// Microsoft's app-local deployment: Windows loads it before any copy in
/// System32, so the server needs no Visual C++ Redistributable and never runs
/// against an older one. A copy that differs from the bundled one (after an
/// update) is replaced; one a running server holds is replaced at a later start.
#[cfg(any(windows, test))]
fn deploy_vc_runtime(bundled: &Path, server_dir: &Path) {
    for name in VC_RUNTIME_DLLS {
        let Ok(bytes) = std::fs::read(bundled.join(name)) else {
            continue;
        };
        let target = server_dir.join(name);
        if std::fs::read(&target).is_ok_and(|current| current == bytes) {
            continue;
        }
        let staged = server_dir.join(format!("{name}.new"));
        let placed =
            std::fs::write(&staged, &bytes).and_then(|()| std::fs::rename(&staged, &target));
        if let Err(err) = placed {
            let _ = std::fs::remove_file(&staged);
            log::info!("llama.cpp: kept the current {name} beside llama-server: {err}");
        }
    }
}

/// `%SystemRoot%\System32`.
fn system32() -> PathBuf {
    std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"))
        .join("System32")
}

/// Whether Windows finds every Visual C++ runtime DLL for a server in
/// `server_dir`, beside it or installed in System32. Other systems need none.
fn vc_runtime_found(server_dir: &Path) -> bool {
    cfg!(not(windows))
        || VC_RUNTIME_DLLS
            .iter()
            .all(|name| server_dir.join(name).is_file() || system32().join(name).is_file())
}

/// What to install when the system could not load llama-server at all. The
/// Linux loader names the library on stderr; Windows only exits with
/// [`STATUS_DLL_NOT_FOUND`], and `vc_runtime_found` tells whether the Visual
/// C++ runtime, the one DLL set outside the runtime folder it needs, is there.
fn missing_library(code: Option<i32>, output: &str, vc_runtime_found: bool) -> Option<String> {
    if code == Some(STATUS_DLL_NOT_FOUND) {
        return Some(if vc_runtime_found {
            "Windows could not find a DLL that llama-server needs (error 0xC0000135). Delete the llama.cpp runtime under Settings → Models and download it again.".into()
        } else {
            format!(
                "llama-server needs the Microsoft Visual C++ Redistributable (x64), which isn't installed. Install it from {VC_REDIST_URL}, then try again."
            )
        });
    }
    // "…/llama-server: error while loading shared libraries: libgomp.so.1:
    // cannot open shared object file: No such file or directory"
    let library = output
        .lines()
        .find_map(|line| {
            let (_, rest) = line.split_once("error while loading shared libraries: ")?;
            Some(rest.split_once(':').map_or(rest, |(name, _)| name).trim())
        })
        .filter(|name| !name.is_empty())?;
    let packages = match library {
        "libgomp.so.1" => " (libgomp1 on Debian, Ubuntu and openSUSE; libgomp on Fedora and Arch)",
        "libvulkan.so.1" => {
            " (libvulkan1 on Debian and Ubuntu, vulkan-loader on Fedora, vulkan-icd-loader on Arch)"
        }
        _ => "",
    };
    Some(format!(
        "llama-server needs {library}, which isn't installed. Install the package that provides it{packages}, then try again."
    ))
}

/// [`missing_library`] for the server at `binary`.
fn missing_library_for(binary: &Path, code: Option<i32>, output: &str) -> Option<String> {
    missing_library(code, output, binary.parent().is_some_and(vc_runtime_found))
}

/// Fails with what to install when the system cannot load `binary`, so setup
/// never records a runtime that cannot start.
fn check_loads(binary: &Path) -> Result<()> {
    let mut command = server_command(binary);
    command.arg("--version");
    let out = process::run_capture(command, Duration::from_secs(20))?;
    let output = format!("{}\n{}", out.stdout, out.stderr);
    match missing_library_for(binary, out.status.and_then(|s| s.code()), &output) {
        Some(message) => Err(AiError::ServerStart(message).into()),
        None => Ok(()),
    }
}

/// `--version` and the conditional flags `--help` lists.
fn probe_capabilities(binary: &Path) -> (String, Vec<String>) {
    let version = process::run_capture(
        {
            let mut c = server_command(binary);
            c.arg("--version");
            c
        },
        Duration::from_secs(20),
    )
    .map(|out| {
        format!("{}\n{}", out.stdout, out.stderr)
            .lines()
            .find(|l| l.contains("version"))
            .unwrap_or_default()
            .trim()
            .to_string()
    })
    .unwrap_or_default();
    let help = process::run_capture(
        {
            let mut c = server_command(binary);
            c.arg("--help");
            c
        },
        Duration::from_secs(20),
    )
    .map(|out| format!("{}\n{}", out.stdout, out.stderr))
    .unwrap_or_default();
    (version, supported_flags(&help))
}

fn supported_flags(help: &str) -> Vec<String> {
    CONDITIONAL_FLAGS
        .iter()
        .filter(|flag| {
            help.match_indices(*flag).any(|(at, _)| {
                let before = help[..at].chars().next_back();
                let after = help[at + flag.len()..].chars().next();
                before.is_none_or(|c| c.is_whitespace() || c == ',')
                    && after.is_none_or(|c| c.is_whitespace() || c == ',' || c == '=')
            })
        })
        .map(|f| f.to_string())
        .collect()
}

fn vulkan_loader_present() -> bool {
    #[cfg(windows)]
    {
        system32().join("vulkan-1.dll").is_file()
    }
    #[cfg(not(windows))]
    {
        [
            "/usr/lib/x86_64-linux-gnu/libvulkan.so.1",
            "/lib/x86_64-linux-gnu/libvulkan.so.1",
            "/usr/lib64/libvulkan.so.1",
            "/usr/lib/libvulkan.so.1",
            "/usr/local/lib/libvulkan.so.1",
        ]
        .iter()
        .any(|p| Path::new(p).exists())
    }
}

#[derive(Clone, Debug, PartialEq)]
struct GpuDevice {
    id: String,
    name: String,
}

/// A real device from this backend, never a CPU-only successful exit.
fn probe_gpu(binary: &Path, backend: LlamaBackend) -> Result<GpuDevice> {
    let mut command = server_command(binary);
    command.arg("--list-devices");
    let out = process::run_capture(command, Duration::from_secs(30))?;
    if !out.status.is_some_and(|s| s.success()) {
        let output = format!("{}\n{}", out.stdout, out.stderr);
        if let Some(message) =
            missing_library_for(binary, out.status.and_then(|s| s.code()), &output)
        {
            return Err(anyhow!(message));
        }
        return Err(anyhow!(
            "{} device detection failed or timed out: {}",
            backend.label(),
            out.stderr.chars().take(1000).collect::<String>()
        ));
    }
    parse_gpu_devices(&format!("{}\n{}", out.stdout, out.stderr), backend)
        .into_iter()
        .next()
        .with_context(|| format!("llama.cpp reported no usable {} GPU. Choose another backend or check the GPU driver. {}", backend.label(), out.stderr.chars().take(1000).collect::<String>()))
}

fn parse_gpu_devices(output: &str, backend: LlamaBackend) -> Vec<GpuDevice> {
    output
        .lines()
        .map(str::trim)
        .filter_map(|line| {
            let (name, rest) = line.split_once(':')?;
            let suffix = name.strip_prefix(backend.label())?;
            let is_device = backend.is_gpu()
                && !suffix.is_empty()
                && suffix.chars().all(|c| c.is_ascii_digit());
            let lower = rest.to_ascii_lowercase();
            let software = ["llvmpipe", "lavapipe", "swiftshader", "software rasterizer"]
                .iter()
                .any(|s| lower.contains(s));
            (is_device && !software).then(|| GpuDevice {
                id: name.into(),
                name: rest.trim().into(),
            })
        })
        .collect()
}

// ------------------------------------------------------------------ servers

/// `<root>/llama-server-<port>.json`: lets a later run recognize (and stop)
/// a helper an earlier run left behind, and lets the CLI reach the app's
/// server. Written 0600 on Unix; it holds the bearer token.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ServerMarker {
    pub pid: u32,
    pub port: u16,
    pub binary_path: String,
    pub model_path: String,
    pub context_tokens: u32,
    #[serde(default)]
    pub extra_args: Vec<String>,
    pub authentication_token: String,
    #[serde(rename = "ownerPID")]
    pub owner_pid: Option<u32>,
    /// Only set after startup confirms model layers on the GPU. Older markers
    /// cannot establish that a CUDA server is really accelerated.
    #[serde(default)]
    pub gpu_offloaded: bool,
}

pub fn marker_path(paths: &LibraryPaths, port: u16) -> PathBuf {
    paths.root().join(format!("llama-server-{port}.json"))
}

/// The marker of the server on `port`, for callers that only read (CLI).
pub fn read_marker(paths: &LibraryPaths, port: u16) -> Option<ServerMarker> {
    serde_json::from_slice(&std::fs::read(marker_path(paths, port)).ok()?).ok()
}

fn write_marker(paths: &LibraryPaths, marker: &ServerMarker) {
    let path = marker_path(paths, marker.port);
    let Ok(bytes) = serde_json::to_vec_pretty(marker) else {
        return;
    };
    let written = lokalbot_core::library::write_atomic(&path, &bytes);
    if written.is_err() {
        log::warn!(
            "llama-server: could not record the helper marker for port {}",
            marker.port
        );
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        if written.is_ok() {
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
    }
}

fn remove_marker_if(paths: &LibraryPaths, port: u16, pid: u32) {
    if read_marker(paths, port).is_some_and(|m| m.pid == pid) {
        let _ = std::fs::remove_file(marker_path(paths, port));
    }
}

/// 64 lowercase hex characters from two random UUIDs, as on macOS.
fn new_token() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

/// The tail of llama-server's stderr (`LlamaServerOutputTail`). Before the
/// first healthy check every line is kept so a failed start can say why;
/// afterwards only crash lines, since request errors can echo private text.
#[derive(Default)]
struct OutputTail {
    lines: Vec<String>,
    ready: bool,
    finished: bool,
    gpu_offloaded: bool,
}

const TAIL_LINES: usize = 12;
const TAIL_LINE_CHARS: usize = 300;
const CRASH_MARKERS: [&str; 8] = [
    "ggml_assert",
    "ggml_vulkan",
    "out of memory",
    "insufficient memory",
    "failed to allocate",
    "terminating",
    "abort",
    "segmentation fault",
];

impl OutputTail {
    fn keep(&mut self, raw: &str) {
        if !self.ready && confirms_gpu_offload(raw) {
            self.gpu_offloaded = true;
        }
        let mut line = raw.trim();
        // "0.00.077.284 E gguf_init_from_reader: …": drop the time and level.
        if let Some((stamp, rest)) = line.split_once(' ')
            && !stamp.is_empty()
            && stamp.chars().all(|c| c.is_ascii_digit() || c == '.')
            && rest.len() > 2
            && rest.as_bytes()[0].is_ascii_uppercase()
            && rest.as_bytes()[1] == b' '
        {
            line = rest[2..].trim();
        }
        if line.is_empty() {
            return;
        }
        if self.ready {
            let lower = line.to_lowercase();
            if !CRASH_MARKERS.iter().any(|m| lower.contains(m)) || lower.contains("last read") {
                return;
            }
        }
        self.lines
            .push(line.chars().take(TAIL_LINE_CHARS).collect());
        if self.lines.len() > TAIL_LINES {
            let excess = self.lines.len() - TAIL_LINES;
            self.lines.drain(..excess);
        }
    }

    /// The first line reporting an error, else the last line.
    fn reason(&self) -> Option<String> {
        self.lines
            .iter()
            .find(|l| {
                let lower = l.to_lowercase();
                ["error", "failed", "ggml_assert"]
                    .iter()
                    .any(|k| lower.contains(k))
            })
            .or_else(|| self.lines.last())
            .cloned()
    }
}

fn confirms_gpu_offload(line: &str) -> bool {
    line.split_once("offloaded ")
        .and_then(|(_, rest)| rest.split_once('/'))
        .is_some_and(|(count, rest)| {
            count.trim().parse::<u32>().is_ok_and(|n| n > 0) && rest.contains(" layers to GPU")
        })
}

struct Running {
    pid: u32,
    /// `None` for a helper adopted from an earlier run or borrowed from a live one.
    child: Option<Child>,
    /// A live LokalBot elsewhere owns it: never stopped from here.
    borrowed: bool,
    model_path: PathBuf,
    model_id: String,
    binary: PathBuf,
    token: String,
    tail: Arc<Mutex<OutputTail>>,
    backend: LlamaBackend,
}

enum Phase {
    Stopped,
    Starting,
    Running(Box<Running>),
}

struct ServerState {
    phase: Phase,
    leases: usize,
    idle_since: Option<Instant>,
    /// The model `lease()` starts when nothing is loaded.
    desired: Option<(String, PathBuf)>,
}

struct ServerInner {
    role: Role,
    port: u16,
    installer: Arc<Installer>,
    state: Mutex<ServerState>,
    changed: Condvar,
}

/// What a resource view shows for one role.
#[derive(Clone, Debug, PartialEq)]
pub struct ServerStatus {
    pub role: Role,
    pub port: u16,
    pub running: bool,
    pub model_id: Option<String>,
    pub leases: usize,
    pub pid: Option<u32>,
    pub backend: Option<LlamaBackend>,
}

/// One role's `llama-server`.
#[derive(Clone)]
pub struct LlamaServer {
    inner: Arc<ServerInner>,
}

/// Keeps a server loaded; dropping the last lease starts the idle timer.
pub struct Lease {
    server: Arc<ServerInner>,
    port: u16,
    token: String,
    model_id: String,
    model_path: PathBuf,
}

impl Lease {
    /// `http://127.0.0.1:<port>/v1`
    pub fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}/v1", self.port)
    }

    /// `http://127.0.0.1:<port>`, for `/health`, `/tokenize` and `/props`.
    pub fn root_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    pub fn model_id(&self) -> &str {
        &self.model_id
    }

    pub fn model_path(&self) -> &Path {
        &self.model_path
    }

    /// A request could not reach the server: if it has died, forget it so
    /// the next lease starts a fresh one.
    pub fn mark_unreachable(&self) {
        let mut state = self.server.state.lock();
        let dead = match &mut state.phase {
            Phase::Running(running) => {
                let exited = match running.child.as_mut() {
                    Some(child) => !matches!(child.try_wait(), Ok(None)),
                    None => !process::pid_alive(running.pid),
                };
                exited || !health(self.port, &running.token)
            }
            _ => false,
        };
        if !dead {
            return;
        }
        log::warn!(
            "llama-server {} stopped answering; it will be restarted",
            self.server.role.label()
        );
        let phase = std::mem::replace(&mut state.phase, Phase::Stopped);
        drop(state);
        if let Phase::Running(running) = phase {
            self.server.stop_running(*running);
        }
        self.server.changed.notify_all();
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        let mut state = self.server.state.lock();
        state.leases = state.leases.saturating_sub(1);
        if state.leases == 0 {
            state.idle_since = Some(Instant::now());
        }
        drop(state);
        self.server.changed.notify_all();
    }
}

fn health(port: u16, token: &str) -> bool {
    let agent = crate::http::agent("http://127.0.0.1", Duration::from_secs(2));
    crate::http::get(
        &agent,
        &format!("http://127.0.0.1:{port}/health"),
        Some(token),
    )
    .is_ok_and(|r| r.status == 200)
}

impl LlamaServer {
    pub fn role(&self) -> Role {
        self.inner.role
    }

    pub fn port(&self) -> u16 {
        self.inner.port
    }

    /// `http://127.0.0.1:<port>/v1`
    pub fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}/v1", self.inner.port)
    }

    /// Sets the model [`lease`](Self::lease) loads when none is running.
    pub fn set_model(&self, entry: &ModelEntry) {
        let path = catalog::model_path(&self.inner.installer.paths, entry);
        self.inner.state.lock().desired = Some((entry.id.to_string(), path));
    }

    /// Leases the running model, or starts the one from [`set_model`](Self::set_model).
    pub fn lease(&self) -> Result<Lease> {
        let desired = {
            let state = self.inner.state.lock();
            match &state.phase {
                Phase::Running(running) => {
                    Some((running.model_id.clone(), running.model_path.clone()))
                }
                _ => state.desired.clone(),
            }
        };
        let (id, path) = desired.ok_or(AiError::NoModel)?;
        self.inner.lease_path(&id, &path)
    }

    /// Leases `entry`, starting (or switching to) it as needed. A switch waits
    /// until every lease on the current model is released.
    pub fn lease_model(&self, entry: &ModelEntry) -> Result<Lease> {
        let paths = &self.inner.installer.paths;
        // Hashes once when the file has no digest sidecar yet.
        if !catalog::verify_downloaded(paths, entry)? {
            return Err(AiError::ModelMissing(entry.display_name.into()).into());
        }
        let path = catalog::model_path(paths, entry);
        self.inner.state.lock().desired = Some((entry.id.to_string(), path.clone()));
        self.inner.lease_path(entry.id, &path)
    }

    /// Stops the server now (leases still held will see it restart).
    pub fn stop(&self) {
        let phase = std::mem::replace(&mut self.inner.state.lock().phase, Phase::Stopped);
        if let Phase::Running(running) = phase {
            self.inner.stop_running(*running);
        }
        self.inner.changed.notify_all();
    }

    pub fn status(&self) -> ServerStatus {
        let state = self.inner.state.lock();
        let running = match &state.phase {
            Phase::Running(r) => Some(r),
            _ => None,
        };
        ServerStatus {
            role: self.inner.role,
            port: self.inner.port,
            running: running.is_some(),
            model_id: running.map(|r| r.model_id.clone()),
            leases: state.leases,
            pid: running.map(|r| r.pid),
            backend: running.map(|r| r.backend),
        }
    }
}

impl ServerInner {
    fn lease_path(self: &Arc<Self>, model_id: &str, model_path: &Path) -> Result<Lease> {
        enum Next {
            Lease,
            Forget,
            Wait,
            Start,
        }
        let mut state = self.state.lock();
        loop {
            let busy = state.leases > 0;
            let next = match &mut state.phase {
                Phase::Running(running)
                    if running.model_path == model_path
                        && self.installer.accepts_backend(running.backend) =>
                {
                    // Existing leases finish before a preference change starts
                    // another backend; no active generation is interrupted.
                    let alive = match running.child.as_mut() {
                        Some(child) => matches!(child.try_wait(), Ok(None)),
                        None => process::pid_alive(running.pid),
                    };
                    if alive { Next::Lease } else { Next::Forget }
                }
                Phase::Starting => Next::Wait,
                // Another model is in use; switch once its cohort finishes.
                Phase::Running(_) if busy => Next::Wait,
                _ => Next::Start,
            };
            match next {
                Next::Lease => {
                    state.leases += 1;
                    state.idle_since = None;
                    let Phase::Running(running) = &state.phase else {
                        unreachable!()
                    };
                    return Ok(Lease {
                        server: self.clone(),
                        port: self.port,
                        token: running.token.clone(),
                        model_id: running.model_id.clone(),
                        model_path: running.model_path.clone(),
                    });
                }
                Next::Forget => {
                    log::warn!("llama-server {} exited; restarting", self.role.label());
                    if let Phase::Running(running) =
                        std::mem::replace(&mut state.phase, Phase::Stopped)
                    {
                        remove_marker_if(&self.installer.paths, self.port, running.pid);
                    }
                }
                Next::Wait => {
                    self.changed.wait_for(&mut state, Duration::from_secs(1));
                }
                Next::Start => {
                    let previous = std::mem::replace(&mut state.phase, Phase::Starting);
                    drop(state);
                    if let Phase::Running(running) = previous {
                        self.stop_running(*running);
                    }
                    let started = self.start(model_id, model_path);
                    state = self.state.lock();
                    let result = match started {
                        Ok(running) => {
                            state.leases += 1;
                            state.idle_since = None;
                            let lease = Lease {
                                server: self.clone(),
                                port: self.port,
                                token: running.token.clone(),
                                model_id: running.model_id.clone(),
                                model_path: running.model_path.clone(),
                            };
                            state.phase = Phase::Running(Box::new(running));
                            Ok(lease)
                        }
                        Err(err) => {
                            state.phase = Phase::Stopped;
                            Err(err)
                        }
                    };
                    drop(state);
                    self.changed.notify_all();
                    return result;
                }
            }
        }
    }

    fn start(&self, model_id: &str, model_path: &Path) -> Result<Running> {
        let installer = &self.installer;
        let never = AtomicBool::new(false);
        let allow_download = self.role.downloads_runtime() && installer.preference() != "cuda";
        let (backend, record, binary) =
            installer.resolve(allow_download, &never, &mut |_, _| {})?;
        match self.launch(model_id, model_path, backend, &record, &binary) {
            Ok(running) => Ok(running),
            Err(err) if backend == LlamaBackend::Vulkan && installer.automatic() => {
                log::warn!(
                    "llama-server {} failed on Vulkan ({err:#}); falling back to the CPU build",
                    self.role.label()
                );
                installer.fall_back_to_cpu();
                let (backend, record, binary) =
                    installer.resolve(allow_download, &never, &mut |_, _| {})?;
                self.launch(model_id, model_path, backend, &record, &binary)
            }
            Err(err) => {
                if backend == LlamaBackend::Cuda {
                    installer.launch_failed(&binary);
                }
                Err(err)
            }
        }
    }

    fn launch(
        &self,
        model_id: &str,
        model_path: &Path,
        backend: LlamaBackend,
        record: &InstallRecord,
        binary: &Path,
    ) -> Result<Running> {
        let paths = &self.installer.paths;
        let mut extra_args = self.role.extra_args(&record.flags);
        let context = self.role.context_tokens();
        if backend == LlamaBackend::Cuda {
            // Reuse a healthy, already-offloaded helper before creating another
            // CUDA context. Its GPU may have no free VRAM for a new probe.
            if let Some(marker) = read_marker(paths, self.port)
                && marker.gpu_offloaded
                && let Some(device) = marker
                    .extra_args
                    .windows(2)
                    .find(|pair| pair[0] == "--device")
                    .map(|pair| pair[1].clone())
                && valid_cuda_device_id(&device)
            {
                let mut expected = extra_args.clone();
                expected.extend(cuda_launch_args(&device));
                if let Some(running) =
                    self.reclaim(model_id, model_path, binary, context, &expected, backend)?
                {
                    return Ok(running);
                }
            }
            let device = self.installer.device(binary, backend).context(
                "CUDA found no usable GPU. Press Check again under Settings → Models → llama.cpp, or choose Automatic, Vulkan or CPU.",
            )?;
            extra_args.extend(cuda_launch_args(&device.id));
        }
        if let Some(running) =
            self.reclaim(model_id, model_path, binary, context, &extra_args, backend)?
        {
            return Ok(running);
        }
        if std::net::TcpListener::bind(("127.0.0.1", self.port)).is_err() {
            return Err(AiError::ServerStart(format!(
                "port {} is already in use. Close the other LokalBot instance or local server and try again",
                self.port
            ))
            .into());
        }
        let token = new_token();
        let mut args: Vec<String> = vec![
            "-m".into(),
            model_path.to_string_lossy().into_owned(),
            "--host".into(),
            "127.0.0.1".into(),
            "--port".into(),
            self.port.to_string(),
            "-c".into(),
            context.to_string(),
            "-ngl".into(),
            "99".into(),
        ];
        if record.flags.iter().any(|f| f == "--jinja") || record.flags.is_empty() {
            args.push("--jinja".into());
        }
        // b11474 renamed `--no-webui` to `--no-ui` and keeps the old name as an alias.
        if record.flags.iter().any(|f| f == "--no-ui") {
            args.push("--no-ui".into());
        } else if record.flags.iter().any(|f| f == "--no-webui") {
            args.push("--no-webui".into());
        }
        args.extend(["--api-key".into(), token.clone()]);
        args.extend(extra_args.iter().cloned());

        let mut command = server_command(binary);
        command
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        let mut child = process::spawn_tied(command).map_err(|err| {
            AiError::ServerStart(format!("could not run {}: {err}", binary.display()))
        })?;
        let pid = child.id();
        let tail = Arc::new(Mutex::new(OutputTail::default()));
        if let Some(stderr) = child.stderr.take() {
            let tail = tail.clone();
            let name = format!("llama-server-{}-stderr", self.role.label());
            let _ = std::thread::Builder::new().name(name).spawn(move || {
                use std::io::BufRead as _;
                let mut reader = std::io::BufReader::new(stderr);
                let mut line = Vec::new();
                loop {
                    line.clear();
                    match reader.read_until(b'\n', &mut line) {
                        Ok(0) | Err(_) => break,
                        Ok(_) => tail.lock().keep(&String::from_utf8_lossy(&line)),
                    }
                }
                tail.lock().finished = true;
            });
        }
        write_marker(
            paths,
            &ServerMarker {
                pid,
                port: self.port,
                binary_path: binary.to_string_lossy().into_owned(),
                model_path: model_path.to_string_lossy().into_owned(),
                context_tokens: context,
                extra_args: extra_args.clone(),
                authentication_token: token.clone(),
                owner_pid: Some(std::process::id()),
                gpu_offloaded: false,
            },
        );
        log::info!(
            "llama-server {} starting pid={pid} port={} model={} backend={}",
            self.role.label(),
            self.port,
            model_path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            backend.label()
        );

        // `code`: the exit code of a server that exited during startup.
        let failure = |summary: &str, code: Option<i32>, tail: &Mutex<OutputTail>| {
            // Let the reader catch the last lines of an exited process.
            for _ in 0..10 {
                if tail.lock().finished {
                    break;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            let tail = tail.lock();
            if !tail.lines.is_empty() {
                log::warn!(
                    "llama-server startup output port={}: {}",
                    self.port,
                    tail.lines.join(" | ")
                );
            }
            let message = match missing_library_for(binary, code, &tail.lines.join("\n")) {
                Some(missing) => missing,
                None => match tail.reason() {
                    Some(reason) => format!("{summary}: {reason}"),
                    None => summary.to_string(),
                },
            };
            anyhow::Error::from(AiError::ServerStart(message))
        };
        // Loading a large model can take a while. On GPUs without prebuilt
        // CUDA kernels the driver first compiles PTX, ~50 s on a Titan Xp;
        // later starts reuse its cache.
        let attempts = if backend == LlamaBackend::Cuda {
            1200
        } else {
            240
        };
        for _ in 0..attempts {
            std::thread::sleep(Duration::from_millis(500));
            match child.try_wait() {
                Ok(None) => {}
                exited => {
                    remove_marker_if(paths, self.port, pid);
                    let code = exited.ok().flatten().and_then(|status| status.code());
                    return Err(failure("llama-server exited during startup", code, &tail));
                }
            }
            if health(self.port, &token) {
                if backend == LlamaBackend::Cuda {
                    // The stderr reader may trail the health response briefly.
                    for _ in 0..20 {
                        if tail.lock().gpu_offloaded {
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(25));
                    }
                    if !tail.lock().gpu_offloaded {
                        process::stop_child(&mut child, Duration::from_secs(2));
                        remove_marker_if(paths, self.port, pid);
                        return Err(failure(
                            "CUDA server did not confirm any model layers on the GPU",
                            None,
                            &tail,
                        ));
                    }
                    if let Some(mut marker) = read_marker(paths, self.port)
                        && marker.pid == pid
                    {
                        marker.gpu_offloaded = true;
                        write_marker(paths, &marker);
                    }
                }
                // Startup lines only explain a failed start.
                let mut output = tail.lock();
                output.ready = true;
                output.lines.clear();
                drop(output);
                return Ok(Running {
                    pid,
                    child: Some(child),
                    borrowed: false,
                    model_path: model_path.to_path_buf(),
                    model_id: model_id.to_string(),
                    binary: binary.to_path_buf(),
                    token,
                    tail,
                    backend,
                });
            }
        }
        process::stop_child(&mut child, Duration::from_secs(2));
        remove_marker_if(paths, self.port, pid);
        Err(failure(
            "server did not become healthy in time",
            None,
            &tail,
        ))
    }

    /// Deals with a helper recorded on this port. A healthy one with the same
    /// configuration is reused: adopted when its LokalBot is gone, borrowed
    /// when that LokalBot still runs. A mismatched orphan is stopped.
    fn reclaim(
        &self,
        model_id: &str,
        model_path: &Path,
        binary: &Path,
        context: u32,
        extra_args: &[String],
        backend: LlamaBackend,
    ) -> Result<Option<Running>> {
        let paths = &self.installer.paths;
        let Some(mut marker) = read_marker(paths, self.port) else {
            return Ok(None);
        };
        let me = std::process::id();
        let helper_alive = process::pid_alive(marker.pid)
            && process::exe_path(marker.pid)
                .is_some_and(|exe| same_file(&exe, Path::new(&marker.binary_path)));
        if !helper_alive {
            let _ = std::fs::remove_file(marker_path(paths, self.port));
            return Ok(None);
        }
        let owner_alive = marker
            .owner_pid
            .is_some_and(|owner| owner != me && process::pid_alive(owner));
        let matches = same_file(Path::new(&marker.binary_path), binary)
            && (backend != LlamaBackend::Cuda || marker.gpu_offloaded)
            && Path::new(&marker.model_path) == model_path
            && marker.context_tokens == context
            && marker.extra_args == extra_args
            && health(self.port, &marker.authentication_token);
        if matches {
            if !owner_alive {
                marker.owner_pid = Some(me);
                write_marker(paths, &marker);
            }
            log::info!(
                "llama-server {} reusing pid={} ({})",
                self.role.label(),
                marker.pid,
                if owner_alive {
                    "owned by another LokalBot"
                } else {
                    "left by an earlier run"
                }
            );
            let tail = Arc::new(Mutex::new(OutputTail {
                ready: true,
                ..Default::default()
            }));
            return Ok(Some(Running {
                pid: marker.pid,
                child: None,
                borrowed: owner_alive,
                model_path: model_path.to_path_buf(),
                model_id: model_id.to_string(),
                binary: binary.to_path_buf(),
                token: marker.authentication_token,
                tail,
                backend,
            }));
        }
        if owner_alive {
            return Err(AiError::ServerStart(format!(
                "another LokalBot instance is using port {} with a different model",
                self.port
            ))
            .into());
        }
        log::info!(
            "llama-server {}: stopping an orphaned helper pid={}",
            self.role.label(),
            marker.pid
        );
        process::terminate(marker.pid, Duration::from_secs(2));
        let _ = std::fs::remove_file(marker_path(paths, self.port));
        Ok(None)
    }

    fn stop_running(&self, mut running: Running) {
        let paths = &self.installer.paths;
        if running.borrowed {
            return;
        }
        match running.child.as_mut() {
            Some(child) => process::stop_child(child, Duration::from_secs(2)),
            None => {
                if process::exe_path(running.pid)
                    .is_some_and(|exe| same_file(&exe, &running.binary))
                {
                    process::terminate(running.pid, Duration::from_secs(2));
                }
            }
        }
        let crash = running.tail.lock().lines.clone();
        if !crash.is_empty() {
            log::warn!(
                "llama-server {} output before stop: {}",
                self.role.label(),
                crash.join(" | ")
            );
        }
        remove_marker_if(paths, self.port, running.pid);
        log::info!(
            "llama-server {} stopped pid={}",
            self.role.label(),
            running.pid
        );
    }

    /// Stops the server when it has been idle past its role's timeout.
    fn reap_if_idle(&self) {
        let mut state = self.state.lock();
        let idle = state.leases == 0
            && matches!(state.phase, Phase::Running(_))
            && state
                .idle_since
                .is_some_and(|since| since.elapsed() >= self.role.idle_timeout());
        if !idle {
            return;
        }
        let phase = std::mem::replace(&mut state.phase, Phase::Stopped);
        state.idle_since = None;
        drop(state);
        if let Phase::Running(running) = phase {
            log::info!("llama-server {} idle; unloading", self.role.label());
            self.stop_running(*running);
        }
        self.changed.notify_all();
    }
}

fn valid_cuda_device_id(id: &str) -> bool {
    id.strip_prefix("CUDA")
        .is_some_and(|suffix| !suffix.is_empty() && suffix.bytes().all(|c| c.is_ascii_digit()))
}

fn cuda_launch_args(device: &str) -> Vec<String> {
    // b11669 hides offload evidence at verbosity 3. Preserve plain startup logs.
    [
        "--device",
        device,
        "--log-verbosity",
        "4",
        "--log-colors",
        "off",
        "--no-log-jsonl",
    ]
    .map(String::from)
    .into()
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.canonicalize(), b.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

// ------------------------------------------------------------------ manager

struct Shared {
    installer: Arc<Installer>,
    servers: [LlamaServer; 3],
    reaper: std::sync::Once,
}

impl Drop for Shared {
    fn drop(&mut self) {
        for server in &self.servers {
            server.stop();
        }
    }
}

/// Runtime storage remains visible even when another backend is selected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeStorage {
    pub name: String,
    pub path: PathBuf,
    pub bytes: u64,
}

fn directory_bytes(path: &Path) -> u64 {
    std::fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|entry| match entry.file_type() {
            Ok(kind) if kind.is_dir() => directory_bytes(&entry.path()),
            Ok(kind) if kind.is_file() => entry.metadata().map_or(0, |m| m.len()),
            _ => 0,
        })
        .sum()
}

/// The three role servers and the runtime they share. Cheap to clone and
/// `Send + Sync`; every clone controls the same servers.
#[derive(Clone)]
pub struct RuntimeManager {
    shared: Arc<Shared>,
}

impl RuntimeManager {
    /// Cheap: no download, no process start.
    pub fn new(paths: LibraryPaths, settings: &Settings) -> Self {
        let installer = Arc::new(Installer {
            paths,
            preference: Mutex::new(settings.llama_backend.clone()),
            active: Mutex::new(None),
            devices: Mutex::new(HashMap::new()),
            devices_stale: AtomicBool::new(false),
            lock: Mutex::new(()),
        });
        let server = |role: Role| LlamaServer {
            inner: Arc::new(ServerInner {
                role,
                port: role.port(),
                installer: installer.clone(),
                state: Mutex::new(ServerState {
                    phase: Phase::Stopped,
                    leases: 0,
                    idle_since: None,
                    desired: None,
                }),
                changed: Condvar::new(),
            }),
        };
        let servers = [
            server(Role::Main),
            server(Role::Embedder),
            server(Role::Autocomplete),
        ];
        Self {
            shared: Arc::new(Shared {
                installer,
                servers,
                reaper: std::sync::Once::new(),
            }),
        }
    }

    pub fn paths(&self) -> &LibraryPaths {
        &self.shared.installer.paths
    }

    pub fn server(&self, role: Role) -> &LlamaServer {
        let index = Role::ALL.iter().position(|r| *r == role).unwrap_or(0);
        &self.shared.servers[index]
    }

    /// Applies a changed `llamaBackend` setting (`auto`, `cuda`, `vulkan`, `cpu`).
    /// Running servers keep their backend until they restart.
    pub fn set_backend_preference(&self, preference: &str) {
        let installer = &self.shared.installer;
        let mut current = installer.preference.lock();
        if current.trim() != preference.trim() {
            *current = preference.to_string();
            *installer.active.lock() = None;
            match installer.devices.try_lock() {
                Some(mut devices) => devices.clear(),
                None => installer.devices_stale.store(true, Ordering::Release),
            }
        }
    }

    /// Downloads and installs the runtime the setting asks for (`auto` may
    /// fetch the Vulkan build to look for a GPU, then the CPU build).
    pub fn ensure_runtime(
        &self,
        settings: &Settings,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<()> {
        self.set_backend_preference(&settings.llama_backend);
        let installer = &self.shared.installer;
        check_cancelled(cancel)?;
        if installer.preference() == "cuda" {
            installer.devices.lock().clear();
        }
        let (backend, record, binary) = installer.resolve(true, cancel, progress)?;
        if backend == LlamaBackend::Cuda {
            let _guard = installer.lock.lock();
            installer.repair_cuda(record, &binary, cancel, progress)?;
        }
        Ok(())
    }

    /// The selected backend when installed. Auto considers Vulkan and CPU;
    /// an explicit choice must have its own complete installation, and CUDA
    /// a setup whose device check succeeded.
    pub fn installed_backend(&self) -> Option<String> {
        let installer = &self.shared.installer;
        match LlamaBackend::preference(&installer.preference()) {
            Some(LlamaBackend::Cuda) => installer.cuda_ready().then(|| "CUDA".into()),
            Some(backend) => installer.record(backend).map(|_| backend.label().into()),
            None => self.automatic_backend(),
        }
    }

    /// CUDA is selected and downloaded, but its setup GPU check has not passed.
    pub fn runtime_needs_check(&self) -> bool {
        let installer = &self.shared.installer;
        LlamaBackend::preference(&installer.preference()) == Some(LlamaBackend::Cuda)
            && installer
                .record(LlamaBackend::Cuda)
                .is_some_and(|(record, _)| record.cuda_unverified)
    }

    /// The backend built-in models can run on now without a download. CUDA
    /// keeps the automatic choice until its setup succeeds.
    pub fn usable_backend(&self) -> Option<String> {
        if self.shared.installer.automatic() {
            self.automatic_backend()
        } else {
            self.installed_backend()
        }
    }

    fn automatic_backend(&self) -> Option<String> {
        let installer = &self.shared.installer;
        let candidates = [
            *installer.active.lock(),
            installer.saved_choice().map(|c| c.backend),
        ];
        candidates
            .into_iter()
            .flatten()
            .chain([LlamaBackend::Vulkan, LlamaBackend::Cpu])
            .filter(|backend| *backend != LlamaBackend::Cuda)
            .find(|backend| installer.record(*backend).is_some())
            .map(|backend| backend.label().to_string())
    }

    /// The backend this session's servers use, once one has been resolved.
    pub fn active_backend(&self) -> Option<LlamaBackend> {
        self.server(Role::Main)
            .status()
            .backend
            .or(*self.shared.installer.active.lock())
    }

    /// The installed `llama-server --version` line, if any.
    pub fn installed_version(&self) -> Option<String> {
        let installer = &self.shared.installer;
        let backend = self.installed_backend()?;
        installer
            .record(LlamaBackend::preference(&backend)?)
            .map(|(r, _)| r.version)
    }

    pub fn storage(&self) -> Vec<RuntimeStorage> {
        let installer = &self.shared.installer;
        let mut stored = Vec::new();
        for asset in ASSETS {
            let path = installer.folder(asset);
            if path.is_dir() {
                stored.push(RuntimeStorage {
                    name: cuda::build_for(asset.name).map_or_else(
                        || asset.backend.label().into(),
                        |build| format!("CUDA {}", build.version),
                    ),
                    bytes: directory_bytes(&path),
                    path,
                });
            }
        }
        let path = installer.root().join(".downloads");
        let bytes = directory_bytes(&path);
        if bytes > 0 {
            stored.push(RuntimeStorage {
                name: "Downloads".into(),
                path,
                bytes,
            });
        }
        stored
    }

    /// Stops every server and removes the downloaded runtimes.
    pub fn uninstall(&self) -> Result<()> {
        self.shutdown();
        let installer = &self.shared.installer;
        let _guard = installer.lock.lock();
        *installer.active.lock() = None;
        installer.devices.lock().clear();
        let root = installer.root();
        match std::fs::remove_dir_all(&root) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                Err(err).with_context(|| format!("removing {}", root.display()))
            }
            _ => Ok(()),
        }
    }

    /// Stops all servers (app quit).
    pub fn shutdown(&self) {
        for server in &self.shared.servers {
            server.stop();
        }
    }

    pub fn statuses(&self) -> Vec<ServerStatus> {
        self.shared
            .servers
            .iter()
            .map(LlamaServer::status)
            .collect()
    }

    fn start_reaper(&self) {
        let weak: Weak<Shared> = Arc::downgrade(&self.shared);
        self.shared.reaper.call_once(|| {
            let spawned = std::thread::Builder::new()
                .name("lokalbot-llama-idle".into())
                .spawn(move || {
                    loop {
                        std::thread::sleep(Duration::from_secs(5));
                        let Some(shared) = weak.upgrade() else { return };
                        for server in &shared.servers {
                            server.inner.reap_if_idle();
                        }
                    }
                });
            if let Err(err) = spawned {
                log::warn!("could not start the idle-unload thread: {err}");
            }
        });
    }

    /// Leases the Think server with `model`.
    pub fn main_server(&self, model: &ModelEntry) -> Result<Lease> {
        self.lease(Role::Main, model)
    }

    /// Leases the embedder (EmbeddingGemma 2).
    pub fn embedder_server(&self) -> Result<Lease> {
        self.lease(Role::Embedder, catalog::embedding_entry())
    }

    pub fn autocomplete_server(&self, model: &ModelEntry) -> Result<Lease> {
        self.lease(Role::Autocomplete, model)
    }

    pub fn lease(&self, role: Role, model: &ModelEntry) -> Result<Lease> {
        self.start_reaper();
        self.server(role).lease_model(model)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ports_and_arguments_follow_the_roles() {
        assert_eq!(Role::Main.release_port(), 17_872);
        assert_eq!(Role::Embedder.release_port(), 17_873);
        assert_eq!(Role::Autocomplete.release_port(), 17_874);
        let all: Vec<String> = CONDITIONAL_FLAGS.iter().map(|f| f.to_string()).collect();
        assert_eq!(
            Role::Main.extra_args(&all),
            ["--cache-ram", "2048", "--reasoning", "on"]
        );
        assert_eq!(Role::Main.extra_args(&[]), Vec::<String>::new());
        assert_eq!(
            Role::Embedder.extra_args(&[]),
            [
                "--embeddings",
                "-b",
                "2048",
                "-ub",
                "2048",
                "--parallel",
                "1"
            ]
        );
        assert_eq!(
            Role::Autocomplete.extra_args(&all),
            ["--parallel", "1", "--cache-ram", "512"]
        );
    }

    #[test]
    fn only_autocomplete_never_downloads_the_runtime() {
        assert!(Role::Main.downloads_runtime());
        assert!(Role::Embedder.downloads_runtime());
        assert!(!Role::Autocomplete.downloads_runtime());
    }

    #[test]
    fn pinned_assets_exist_for_this_platform() {
        assert_eq!(assets().len(), 4);
        for asset in assets() {
            assert_eq!(asset.sha256.len(), 64);
            assert!(
                asset
                    .url()
                    .starts_with("https://github.com/ggml-org/llama.cpp/releases/download/b11669/")
            );
            assert!(asset.name.contains(asset.tag));
        }
    }

    #[test]
    fn help_flags_match_whole_options_only() {
        let help = "-rea,   --reasoning [on|off|auto]  use reasoning\n  --reasoning-budget N\n --cache-ram, -cram N\n --jinja\n";
        assert_eq!(
            supported_flags(help),
            ["--reasoning", "--cache-ram", "--jinja"]
        );
        assert_eq!(
            supported_flags("--reasoning-budget N\n--no-webui-x"),
            Vec::<String>::new()
        );
    }

    #[test]
    fn software_vulkan_devices_are_not_gpus() {
        let output = "Available devices:\n  Vulkan0: llvmpipe (LLVM 17.0.6, 256 bits) (64000 MiB, 64000 MiB free)\n  Vulkan1: AMD Radeon RX 6600 XT (RADV NAVI23) (8176 MiB, 7900 MiB free)\n";
        assert_eq!(
            parse_gpu_devices(output, LlamaBackend::Vulkan),
            [GpuDevice {
                id: "Vulkan1".into(),
                name: "AMD Radeon RX 6600 XT (RADV NAVI23) (8176 MiB, 7900 MiB free)".into()
            }]
        );
        assert!(parse_gpu_devices("Available devices:\n", LlamaBackend::Vulkan).is_empty());
    }

    #[test]
    fn cuda_device_detection_does_not_accept_cpu_or_vulkan_success() {
        let output = "ggml_cuda_init: found 1 CUDA devices\nAvailable devices:\n  CPU0: CPU\n  Vulkan0: NVIDIA RTX 4090\n  CUDA0: NVIDIA RTX 4090 (24000 MiB, 23000 MiB free)\n  CUDA: malformed\n  CUDAx: malformed\n";
        assert_eq!(
            parse_gpu_devices(output, LlamaBackend::Cuda),
            vec![GpuDevice {
                id: "CUDA0".into(),
                name: "NVIDIA RTX 4090 (24000 MiB, 23000 MiB free)".into(),
            }]
        );
        assert!(
            parse_gpu_devices(
                "Available devices:\n  Vulkan0: NVIDIA RTX 4090\n",
                LlamaBackend::Cuda
            )
            .is_empty()
        );
    }

    #[test]
    fn cuda_download_size_includes_libraries_without_inflating_auto() {
        assert_eq!(
            download_bytes("cuda"),
            cuda::BUILDS[0].server.size + cuda::BUILDS[0].libraries.size
        );
        assert_eq!(
            download_bytes("auto"),
            asset(LlamaBackend::Vulkan).unwrap().size
        );
        assert_eq!(
            download_bytes("cpu"),
            asset(LlamaBackend::Cpu).unwrap().size
        );
        assert_eq!(
            serde_json::to_string(&LlamaBackend::Cuda).unwrap(),
            "\"cuda\""
        );
        assert!(LlamaBackend::Cuda.is_gpu());
        assert!(!LlamaBackend::Cpu.is_gpu());
    }

    fn fixture_record(
        installer: &Installer,
        backend: LlamaBackend,
        libraries: Option<&str>,
    ) -> PathBuf {
        let asset = asset(backend).unwrap();
        let folder = installer.folder(asset);
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(folder.join(SERVER_BINARY), b"fixture, never executed").unwrap();
        let record = InstallRecord {
            build: LLAMA_BUILD.into(),
            asset: asset.name.into(),
            sha256: asset.sha256.into(),
            backend,
            server: SERVER_BINARY.into(),
            version: "fixture version".into(),
            flags: vec![],
            probe: PROBE_VERSION,
            cuda_libraries: libraries.map(String::from),
            cuda_unverified: false,
        };
        std::fs::write(
            folder.join("install.json"),
            serde_json::to_vec(&record).unwrap(),
        )
        .unwrap();
        folder
    }

    fn set_cuda_unverified(folder: &Path, unverified: bool) {
        let path = folder.join("install.json");
        let mut record: InstallRecord =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        record.cuda_unverified = unverified;
        std::fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
    }

    #[test]
    fn cuda_selection_keeps_the_automatic_backend_until_setup_succeeds() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        let installer = &manager.shared.installer;
        fixture_record(installer, LlamaBackend::Cpu, None);
        installer.save_choice(LlamaBackend::Cpu, None);
        let never = AtomicBool::new(false);
        let background = || {
            installer
                .resolve(false, &never, &mut |_, _| panic!("background download"))
                .unwrap()
                .0
        };
        manager.set_backend_preference("cuda");
        assert_eq!(background(), LlamaBackend::Cpu);
        assert!(
            installer.accepts_backend(LlamaBackend::Cpu),
            "running servers stay"
        );
        assert_eq!(manager.usable_backend().as_deref(), Some("CPU"));
        assert_eq!(
            manager.installed_backend(),
            None,
            "Settings still offers CUDA setup"
        );

        // Files kept after a failed final device check do not switch roles.
        let folder = fixture_record(installer, LlamaBackend::Cuda, Some("system"));
        set_cuda_unverified(&folder, true);
        assert_eq!(background(), LlamaBackend::Cpu);
        assert!(installer.accepts_backend(LlamaBackend::Cpu));
        assert_eq!(manager.usable_backend().as_deref(), Some("CPU"));
        assert_eq!(manager.installed_backend(), None);

        // A confirmed CUDA setup takes over when servers next restart.
        set_cuda_unverified(&folder, false);
        assert!(!installer.accepts_backend(LlamaBackend::Cpu));
        assert!(installer.accepts_backend(LlamaBackend::Cuda));
        assert_eq!(background(), LlamaBackend::Cuda);
        assert_eq!(manager.usable_backend().as_deref(), Some("CUDA"));
        assert_eq!(manager.installed_backend().as_deref(), Some("CUDA"));
    }

    #[test]
    fn choosing_cuda_requires_its_own_complete_installation() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        let installer = &manager.shared.installer;
        fixture_record(installer, LlamaBackend::Cpu, None);
        installer.save_choice(LlamaBackend::Cpu, None);
        assert_eq!(manager.installed_backend().as_deref(), Some("CPU"));
        manager.set_backend_preference("cuda");
        assert_eq!(manager.installed_backend(), None);
        fixture_record(installer, LlamaBackend::Cuda, None);
        assert_eq!(manager.installed_backend(), None);
        fixture_record(
            installer,
            LlamaBackend::Cuda,
            Some(cuda::BUILDS[0].libraries.sha256),
        );
        assert_eq!(
            manager.installed_backend(),
            None,
            "missing companion files must not count as installed"
        );
        fixture_record(installer, LlamaBackend::Cuda, Some("system"));
        assert_eq!(manager.installed_backend().as_deref(), Some("CUDA"));
        manager.set_backend_preference("auto");
        assert_eq!(
            manager.installed_backend().as_deref(),
            Some("CPU"),
            "Auto does not promote unvalidated CUDA"
        );
    }

    #[test]
    fn cuda_is_a_gpu_for_ask_and_notes() {
        let dir = tempfile::tempdir().unwrap();
        let settings = Settings::default();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &settings);
        let think = crate::ThinkClient::new(&manager, &settings).unwrap();
        assert!(think.runs_on_cpu());
        *manager.shared.installer.active.lock() = Some(LlamaBackend::Cuda);
        assert!(!think.runs_on_cpu());
        *manager.shared.installer.active.lock() = Some(LlamaBackend::Cpu);
        assert!(think.runs_on_cpu());
    }

    #[test]
    fn changing_backend_invalidates_resolution_and_requires_next_lease_to_switch() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        *manager.shared.installer.active.lock() = Some(LlamaBackend::Cpu);
        manager.set_backend_preference("cuda");
        assert_eq!(*manager.shared.installer.active.lock(), None);
        // CUDA is not set up yet, so a running CPU server keeps serving.
        assert!(manager.shared.installer.accepts_backend(LlamaBackend::Cpu));
        assert!(manager.shared.installer.accepts_backend(LlamaBackend::Cuda));
        fixture_record(
            &manager.shared.installer,
            LlamaBackend::Cuda,
            Some("system"),
        );
        assert!(!manager.shared.installer.accepts_backend(LlamaBackend::Cpu));
        manager.set_backend_preference("vulkan");
        assert!(!manager.shared.installer.accepts_backend(LlamaBackend::Cpu));
        assert!(!manager.shared.installer.accepts_backend(LlamaBackend::Cuda));
        manager.set_backend_preference("auto");
        assert!(!manager.shared.installer.accepts_backend(LlamaBackend::Cuda));
        assert!(
            manager
                .shared
                .installer
                .accepts_backend(LlamaBackend::Vulkan)
        );
    }

    #[test]
    fn offload_confirmation_survives_startup_log_truncation() {
        let mut tail = OutputTail::default();
        tail.keep("load_tensors: offloaded 0/33 layers to GPU");
        assert!(!tail.gpu_offloaded);
        // Captured from b11669 on an NVIDIA L4 with --log-verbosity 4.
        tail.keep("0.02.021.855 I load_tensors: offloaded 25/25 layers to GPU");
        for _ in 0..100 {
            tail.keep("other startup line");
        }
        assert!(tail.gpu_offloaded);
        assert!(!confirms_gpu_offload("offloaded nope/33 layers to GPU"));
        assert!(!confirms_gpu_offload("offloaded 33/33 layers to CPU"));
    }

    #[cfg(unix)]
    fn probe_script(exit: u8) -> String {
        format!(
            "#!/bin/sh\nprintf 'Available devices:\\n  CUDA0: Test NVIDIA GPU (8192 MiB, 8000 MiB free)\\n'\nexit {exit}\n"
        )
    }

    #[cfg(unix)]
    fn fake_gpu_server(dir: &Path, exit: u8) -> PathBuf {
        use std::os::unix::fs::PermissionsExt as _;
        let binary = dir.join("probe-server");
        std::fs::write(&binary, probe_script(exit)).unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
        binary
    }

    /// Stands in for a downloaded release archive: `download` accepts a file
    /// of the pinned size whose digest sidecar matches, and nothing reads the
    /// sparse padding after the gzip stream.
    #[cfg(unix)]
    fn seed_archive(dir: &Path, asset: &RuntimeAsset, files: &[(&str, &[u8])]) {
        std::fs::create_dir_all(dir).unwrap();
        let path = dir.join(asset.name);
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
            std::fs::File::create(&path).unwrap(),
            flate2::Compression::fast(),
        ));
        for (name, contents) in files {
            let mut header = tar::Header::new_gnu();
            header.set_size(contents.len() as u64);
            header.set_mode(0o755);
            builder
                .append_data(&mut header, format!("upstream/{name}"), *contents)
                .unwrap();
        }
        let file = builder.into_inner().unwrap().finish().unwrap();
        file.set_len(asset.size).unwrap();
        download::write_sidecar(&path, asset.sha256).unwrap();
    }

    #[test]
    #[cfg(unix)]
    fn fresh_cuda_files_survive_a_failed_final_probe() {
        let dir = tempfile::tempdir().unwrap();
        let settings = Settings {
            llama_backend: "cuda".into(),
            ..Settings::default()
        };
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &settings);
        let installer = &manager.shared.installer;
        let downloads = installer.root().join(".downloads");
        // The CUDA 12 build, which older GPUs and drivers select.
        let build = &cuda::BUILDS[1];
        // Exits with an error, like a GPU with no memory free for a new context.
        let busy = probe_script(1);
        seed_archive(
            &downloads,
            &build.server,
            &[
                (SERVER_BINARY, busy.as_bytes()),
                ("libggml-cuda.so", b"fixture"),
            ],
        );
        let libraries: Vec<(&str, &[u8])> = build
            .library_names
            .iter()
            .map(|name| (*name, b"fixture library".as_slice()))
            .collect();
        seed_archive(&downloads, &build.libraries, &libraries);

        // `install` checks the NVIDIA driver first; no test machine has one.
        let (record, binary) = installer
            .download_and_unpack(&build.server, &AtomicBool::new(false), &mut |_, _| {})
            .unwrap();
        assert!(record.cuda_unverified);
        assert_eq!(
            record.cuda_libraries.as_deref(),
            Some(build.libraries.sha256)
        );
        assert!(binary.parent().is_some_and(|dir| build.complete(dir)));
        assert_eq!(
            std::fs::read_dir(&downloads).unwrap().count(),
            0,
            "completed archives are removed"
        );
        assert!(!installer.cuda_ready());
        assert_eq!(manager.installed_backend(), None);

        // Retrying setup repeats only the device check.
        let retry = |manager: &RuntimeManager| {
            manager.ensure_runtime(&settings, &AtomicBool::new(false), &mut |_, _| {
                panic!("downloaded again")
            })
        };
        let error = retry(&manager).unwrap_err();
        assert!(
            format!("{error:#}").contains("CUDA could not initialize"),
            "{error:#}"
        );
        assert!(!installer.cuda_ready());
        std::fs::write(&binary, probe_script(0)).unwrap();
        retry(&manager).unwrap();
        assert!(installer.cuda_ready());
        assert_eq!(manager.installed_backend().as_deref(), Some("CUDA"));
        assert_eq!(manager.usable_backend().as_deref(), Some("CUDA"));
    }

    #[test]
    #[cfg(unix)]
    fn working_system_cuda_skips_the_companion_download() {
        let dir = tempfile::tempdir().unwrap();
        let binary = fake_gpu_server(dir.path(), 0);
        let manager = RuntimeManager::new(
            LibraryPaths::new(dir.path().join("library")),
            &Settings::default(),
        );
        let mut progress_called = false;
        let (libraries, checked) = manager
            .shared
            .installer
            .prepare_cuda(
                &binary,
                &cuda::BUILDS[0],
                &AtomicBool::new(false),
                &mut |_, _| progress_called = true,
            )
            .unwrap();
        assert_eq!(libraries, "system");
        assert!(checked.is_ok());
        assert!(!progress_called);
        assert!(
            !manager.shared.installer.root().exists(),
            "system reuse must not create downloads"
        );
    }

    #[test]
    #[cfg(unix)]
    fn unsuccessful_gpu_probe_is_rejected_even_if_it_prints_a_device() {
        let dir = tempfile::tempdir().unwrap();
        let binary = fake_gpu_server(dir.path(), 1);
        assert!(probe_gpu(&binary, LlamaBackend::Cuda).is_err());
    }

    const MISSING_GOMP: &str = "llama-server needs libgomp.so.1, which isn't installed. Install the package that provides it (libgomp1 on Debian, Ubuntu and openSUSE; libgomp on Fedora and Arch), then try again.";

    /// What the dynamic loader prints for llama-server without libgomp1.
    #[cfg(unix)]
    const MISSING_GOMP_SERVER: &str = "#!/bin/sh\necho \"$0: error while loading shared libraries: libgomp.so.1: cannot open shared object file: No such file or directory\" >&2\nexit 127\n";

    #[test]
    fn missing_system_libraries_say_what_to_install() {
        assert_eq!(STATUS_DLL_NOT_FOUND, -1_073_741_515);
        let redist = missing_library(Some(STATUS_DLL_NOT_FOUND), "", false).unwrap();
        assert_eq!(
            redist,
            "llama-server needs the Microsoft Visual C++ Redistributable (x64), which isn't installed. Install it from https://aka.ms/vc14/vc_redist.x64.exe, then try again."
        );
        // With the Visual C++ runtime in place, a DLL of the runtime folder is gone.
        let other = missing_library(Some(STATUS_DLL_NOT_FOUND), "", true).unwrap();
        assert!(
            other.contains("0xC0000135") && other.contains("download it again"),
            "{other}"
        );

        // From b11669 in an ubuntu:24.04 container without libgomp1.
        let loader = "/root/.local/share/LokalBot/runtimes/llama-cpp/b11669-ubuntu-x64/llama-b11669/llama-server: error while loading shared libraries: libgomp.so.1: cannot open shared object file: No such file or directory";
        assert_eq!(
            missing_library(Some(127), loader, true).as_deref(),
            Some(MISSING_GOMP)
        );
        assert_eq!(
            missing_library(
                Some(127),
                "x: error while loading shared libraries: libfoo.so.3: cannot open shared object file",
                true
            )
            .as_deref(),
            Some(
                "llama-server needs libfoo.so.3, which isn't installed. Install the package that provides it, then try again."
            )
        );
        assert!(
            missing_library(
                None,
                "a: error while loading shared libraries: libvulkan.so.1: x",
                true
            )
            .unwrap()
            .contains("vulkan-icd-loader on Arch")
        );

        // Other failures keep llama-server's own reason.
        assert_eq!(
            missing_library(Some(1), "error: failed to load model 'x.gguf'", false),
            None
        );
        assert_eq!(missing_library(None, "", false), None);
    }

    #[test]
    fn bundled_vc_runtime_is_placed_and_refreshed_beside_the_server() {
        let dir = tempfile::tempdir().unwrap();
        let bundled = dir.path().join(VC_RUNTIME_DIR);
        let server = dir.path().join("runtime");
        std::fs::create_dir_all(&bundled).unwrap();
        std::fs::create_dir_all(&server).unwrap();
        for name in VC_RUNTIME_DLLS {
            std::fs::write(bundled.join(name), format!("{name} 14.44")).unwrap();
        }
        let read = |name: &str| std::fs::read_to_string(server.join(name)).unwrap();

        deploy_vc_runtime(&bundled, &server);
        for name in VC_RUNTIME_DLLS {
            assert_eq!(read(name), format!("{name} 14.44"));
        }
        // An update brings a newer runtime.
        std::fs::write(bundled.join("msvcp140.dll"), "msvcp140.dll 14.51").unwrap();
        deploy_vc_runtime(&bundled, &server);
        assert_eq!(read("msvcp140.dll"), "msvcp140.dll 14.51");
        assert_eq!(read("vcruntime140.dll"), "vcruntime140.dll 14.44");
        let mut names: Vec<String> = std::fs::read_dir(&server)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        assert_eq!(names, VC_RUNTIME_DLLS);
    }

    #[test]
    #[cfg(unix)]
    fn setup_names_a_missing_system_library_and_installs_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        let installer = &manager.shared.installer;
        let asset = asset(LlamaBackend::Cpu).unwrap();
        seed_archive(
            &installer.root().join(".downloads"),
            asset,
            &[(SERVER_BINARY, MISSING_GOMP_SERVER.as_bytes())],
        );
        let error = installer
            .download_and_unpack(asset, &AtomicBool::new(false), &mut |_, _| {})
            .unwrap_err();
        assert_eq!(
            error.to_string(),
            format!("Local LLM server failed to start: {MISSING_GOMP}")
        );
        assert!(installer.record(LlamaBackend::Cpu).is_none());
        assert!(!installer.folder(asset).exists());
    }

    #[test]
    #[cfg(unix)]
    fn startup_failure_names_a_missing_system_library() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        // A free port, so this test never binds a release port.
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let server = ServerInner {
            role: Role::Main,
            port,
            installer: manager.shared.installer.clone(),
            state: Mutex::new(ServerState {
                phase: Phase::Stopped,
                leases: 0,
                idle_since: None,
                desired: None,
            }),
            changed: Condvar::new(),
        };
        let binary = dir.path().join(SERVER_BINARY);
        std::fs::write(&binary, MISSING_GOMP_SERVER).unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
        let record = InstallRecord {
            build: LLAMA_BUILD.into(),
            asset: "test".into(),
            sha256: String::new(),
            backend: LlamaBackend::Cpu,
            server: SERVER_BINARY.into(),
            version: String::new(),
            flags: Vec::new(),
            probe: PROBE_VERSION,
            cuda_libraries: None,
            cuda_unverified: false,
        };
        let Err(error) = server.launch(
            "test",
            Path::new("test.gguf"),
            LlamaBackend::Cpu,
            &record,
            &binary,
        ) else {
            panic!("a server without libgomp started");
        };
        assert_eq!(
            error.to_string(),
            format!("Local LLM server failed to start: {MISSING_GOMP}")
        );
    }

    #[test]
    fn cancelled_cuda_setup_does_not_probe_or_download() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        let error = manager
            .shared
            .installer
            .prepare_cuda(
                Path::new("nonexistent"),
                &cuda::BUILDS[0],
                &AtomicBool::new(true),
                &mut |_, _| panic!("download after cancellation"),
            )
            .unwrap_err();
        assert!(crate::error::is_cancelled(&error));
        assert!(!manager.shared.installer.root().exists());
    }

    #[test]
    fn intact_cuda_install_is_reused_without_probing_or_downloading() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        let installer = &manager.shared.installer;
        let folder = fixture_record(installer, LlamaBackend::Cuda, Some("system"));
        let before = std::fs::read(folder.join("install.json")).unwrap();
        // The fixture binary cannot execute. GPU availability is deliberately irrelevant.
        for _ in 0..2 {
            installer
                .install(LlamaBackend::Cuda, &AtomicBool::new(false), &mut |_, _| {
                    panic!("unexpected download")
                })
                .unwrap();
        }
        assert_eq!(std::fs::read(folder.join("install.json")).unwrap(), before);
        assert!(!installer.root().join(".downloads").exists());
    }

    #[test]
    fn all_cuda_roles_require_explicit_setup_without_hidden_downloads() {
        let dir = tempfile::tempdir().unwrap();
        let settings = Settings {
            llama_backend: "cuda".into(),
            ..Settings::default()
        };
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &settings);
        for role in Role::ALL {
            let error = manager
                .server(role)
                .inner
                .start("test", Path::new("missing.gguf"))
                .err()
                .unwrap();
            assert!(
                error.to_string().contains("Download it under Settings"),
                "{error:#}"
            );
        }
        assert!(!manager.shared.installer.root().exists());
    }

    #[test]
    #[cfg(unix)]
    fn gpu_probe_success_and_failure_are_cached_until_explicit_retry() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(
            LibraryPaths::new(dir.path().join("library")),
            &Settings::default(),
        );
        let binary = fake_gpu_server(dir.path(), 0);
        let first = manager
            .shared
            .installer
            .device(&binary, LlamaBackend::Cuda)
            .unwrap();
        fake_gpu_server(dir.path(), 1);
        assert_eq!(
            manager
                .shared
                .installer
                .device(&binary, LlamaBackend::Cuda)
                .unwrap(),
            first
        );
        manager.shared.installer.launch_failed(&binary);
        assert!(
            manager
                .shared
                .installer
                .device(&binary, LlamaBackend::Cuda)
                .is_err()
        );
        fake_gpu_server(dir.path(), 0);
        manager.shared.installer.launch_failed(&binary);
        assert!(
            manager
                .shared
                .installer
                .device(&binary, LlamaBackend::Cuda)
                .is_err(),
            "failed probes remain cached"
        );
        manager.shared.installer.devices.lock().clear();
        assert!(
            manager
                .shared
                .installer
                .device(&binary, LlamaBackend::Cuda)
                .is_ok()
        );
    }

    #[test]
    fn healthy_cuda_helper_is_reclaimed_before_a_failed_probe() {
        use std::io::{Read as _, Write as _};
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let inner = manager.server(Role::Autocomplete).inner.clone();
        // Build a separate inner so this test never binds a release port.
        let server = ServerInner {
            role: Role::Autocomplete,
            port,
            installer: inner.installer.clone(),
            state: Mutex::new(ServerState {
                phase: Phase::Stopped,
                leases: 0,
                idle_since: None,
                desired: None,
            }),
            changed: Condvar::new(),
        };
        let thread = std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            for _ in 0..100 {
                if let Ok((mut stream, _)) = listener.accept() {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(1)))
                        .unwrap();
                    let mut request = [0; 4096];
                    let _ = stream.read(&mut request);
                    stream
                        .write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
                        )
                        .unwrap();
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let binary = std::env::current_exe().unwrap();
        let folder = fixture_record(&inner.installer, LlamaBackend::Cuda, Some("system"));
        let record: InstallRecord =
            serde_json::from_slice(&std::fs::read(folder.join("install.json")).unwrap()).unwrap();
        let mut args = Role::Autocomplete.extra_args(&record.flags);
        args.extend(cuda_launch_args("CUDA0"));
        write_marker(
            manager.paths(),
            &ServerMarker {
                pid: std::process::id(),
                port,
                binary_path: binary.to_string_lossy().into(),
                model_path: "test.gguf".into(),
                context_tokens: 4096,
                extra_args: args,
                authentication_token: "test-token".into(),
                owner_pid: Some(1),
                gpu_offloaded: true,
            },
        );
        inner
            .installer
            .devices
            .lock()
            .insert(binary.clone(), Err("GPU is busy".into()));
        let result = server.launch(
            "test",
            Path::new("test.gguf"),
            LlamaBackend::Cuda,
            &record,
            &binary,
        );
        thread.join().unwrap();
        let running = result.unwrap();
        assert_eq!(running.pid, std::process::id());
        assert!(running.child.is_none());
        // No server was added to the manager or stopped by this fixture.
        assert!(inner.installer.devices.lock()[&binary].is_err());
    }

    #[test]
    fn completed_archive_is_cleaned_after_final_failure() {
        let dir = tempfile::tempdir().unwrap();
        let archive = dir.path().join("cuda.tar.gz");
        std::fs::write(&archive, b"archive").unwrap();
        let sidecar = download::sidecar_path(&archive);
        std::fs::write(&sidecar, b"digest").unwrap();
        let fail = || -> Result<()> {
            let _cleanup = CompletedArchive(archive.clone());
            Err(anyhow!("final probe failed"))
        };
        assert!(fail().is_err());
        assert!(!archive.exists() && !sidecar.exists());
    }

    #[test]
    fn storage_includes_unselected_and_incomplete_cuda_files() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        fixture_record(&manager.shared.installer, LlamaBackend::Cuda, None);
        assert_eq!(manager.installed_backend(), None);
        let stored = manager.storage();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].name, "CUDA 13.4");
        assert!(stored[0].bytes > 0);
        manager.uninstall().unwrap();
        assert!(manager.storage().is_empty());
    }

    #[test]
    fn output_tail_keeps_startup_lines_then_only_crashes() {
        let mut tail = OutputTail::default();
        tail.keep("0.00.077.284 E gguf_init_from_reader: failed to read magic\n");
        tail.keep("main: exiting");
        assert_eq!(
            tail.reason().as_deref(),
            Some("gguf_init_from_reader: failed to read magic")
        );
        tail.ready = true;
        tail.keep("request: {\"prompt\": \"private words\"}");
        tail.keep("ggml_assert failed");
        assert!(!tail.lines.iter().any(|l| l.contains("private")));
        assert_eq!(
            tail.lines.last().map(String::as_str),
            Some("ggml_assert failed")
        );
        for i in 0..20 {
            tail.keep(&format!("abort {i}"));
        }
        assert_eq!(tail.lines.len(), TAIL_LINES);
    }

    #[test]
    fn tokens_are_64_hex() {
        let token = new_token();
        assert_eq!(token.len(), 64);
        assert!(
            token
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        );
        assert_ne!(token, new_token());
    }

    #[test]
    fn markers_round_trip_and_stale_ones_are_ignored() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        let manager = RuntimeManager::new(paths.clone(), &Settings::default());
        let inner = &manager.server(Role::Main).inner;
        let marker = ServerMarker {
            pid: 4_000_000_000,
            port: inner.port,
            binary_path: "/nonexistent/llama-server".into(),
            model_path: "/nonexistent/m.gguf".into(),
            context_tokens: 32_768,
            extra_args: vec![],
            authentication_token: new_token(),
            owner_pid: Some(1),
            gpu_offloaded: false,
        };
        write_marker(&paths, &marker);
        assert_eq!(read_marker(&paths, inner.port), Some(marker.clone()));
        let json = std::fs::read_to_string(marker_path(&paths, inner.port)).unwrap();
        assert!(json.contains("\"ownerPID\"") && json.contains("\"authenticationToken\""));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            let mode = std::fs::metadata(marker_path(&paths, inner.port))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        // A dead helper's marker is discarded before binding.
        let reclaimed = inner
            .reclaim(
                "m",
                Path::new("/nonexistent/m.gguf"),
                Path::new("/nonexistent/llama-server"),
                32_768,
                &[],
                LlamaBackend::Cpu,
            )
            .unwrap();
        assert!(reclaimed.is_none());
        assert!(read_marker(&paths, inner.port).is_none());
    }

    #[test]
    fn leasing_a_missing_model_fails_without_downloading() {
        let dir = tempfile::tempdir().unwrap();
        let manager = RuntimeManager::new(LibraryPaths::new(dir.path()), &Settings::default());
        let err = manager
            .main_server(catalog::entry("qwen3.5-0.8b").unwrap())
            .err()
            .unwrap();
        assert!(
            matches!(
                err.downcast_ref::<AiError>(),
                Some(AiError::ModelMissing(_))
            ),
            "{err}"
        );
        assert!(!dir.path().join("runtimes").exists());
        assert_eq!(manager.installed_backend(), None);
        assert!(manager.statuses().iter().all(|s| !s.running));
    }
}
