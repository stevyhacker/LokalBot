use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use anyhow::{Context as _, Result, anyhow, bail};

use super::{LlamaBackend, RuntimeAsset};

#[derive(Debug)]
pub(super) struct Build {
    pub(super) version: &'static str,
    pub(super) server: RuntimeAsset,
    pub(super) libraries: RuntimeAsset,
    pub(super) library_names: [&'static str; 3],
    toolkit: i32,
    prebuilt: &'static [u32],
    oldest: u32,
}

#[cfg(windows)]
const NEWEST: Build = Build {
    version: "13.5",
    server: RuntimeAsset {
        backend: LlamaBackend::Cuda,
        tag: "win-cuda-13.5-x64",
        name: "llama-b12613-bin-win-cuda-13.5-x64.zip",
        size: 225_600_888,
        sha256: "87fbf5aab2747a0d18699d8f2894203b904b503926a1656c830ad68bcb5d3cee",
    },
    libraries: RuntimeAsset {
        backend: LlamaBackend::Cuda,
        tag: "win-cuda-13.5-x64",
        name: "cudart-llama-bin-win-cuda-13.5-x64.zip",
        size: 426_314_199,
        sha256: "c2bf4cc202bfbaaa7a0b75f5082457c3811326947bb216059b72839d844e9cba",
    },
    library_names: ["cudart64_13.dll", "cublas64_13.dll", "cublasLt64_13.dll"],
    toolkit: 13_050,
    prebuilt: &[86, 89, 120, 121],
    oldest: 75,
};

#[cfg(windows)]
const OLDER: Build = Build {
    version: "12.4",
    server: RuntimeAsset {
        backend: LlamaBackend::Cuda,
        tag: "win-cuda-12.4-x64",
        name: "llama-b12613-bin-win-cuda-12.4-x64.zip",
        size: 357_938_946,
        sha256: "41179bdab19d94eccafb5fa7391722be8be6c01ebb009313c3c98bda6c93fecc",
    },
    libraries: RuntimeAsset {
        backend: LlamaBackend::Cuda,
        tag: "win-cuda-12.4-x64",
        name: "cudart-llama-bin-win-cuda-12.4-x64.zip",
        size: 391_443_627,
        sha256: "8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6",
    },
    library_names: ["cudart64_12.dll", "cublas64_12.dll", "cublasLt64_12.dll"],
    toolkit: 12_040,
    prebuilt: &[86, 89],
    oldest: 50,
};

#[cfg(not(windows))]
const NEWEST: Build = Build {
    version: "13.5",
    server: RuntimeAsset {
        backend: LlamaBackend::Cuda,
        tag: "ubuntu-cuda-13.5-x64",
        name: "llama-b12613-bin-ubuntu-cuda-13.5-x64.tar.gz",
        size: 224_354_186,
        sha256: "2341f734e8a4a5b9ff44e132c4b32de2e7cc3b33a63f55a7a88eefafc6d824a6",
    },
    libraries: RuntimeAsset {
        backend: LlamaBackend::Cuda,
        tag: "ubuntu-cuda-13.5-x64",
        name: "cudart-llama-b12613-bin-ubuntu-cuda-13.5-x64.tar.gz",
        size: 444_077_873,
        sha256: "fe676b7a36753342af68d20e11a4d3e65eb370cf58da635f0790b7d0240df466",
    },
    library_names: ["libcudart.so.13", "libcublas.so.13", "libcublasLt.so.13"],
    toolkit: 13_050,
    prebuilt: &[86, 89, 120, 121],
    oldest: 75,
};

#[cfg(not(windows))]
const OLDER: Build = Build {
    version: "12.8",
    server: RuntimeAsset {
        backend: LlamaBackend::Cuda,
        tag: "ubuntu-cuda-12.8-x64",
        name: "llama-b12613-bin-ubuntu-cuda-12.8-x64.tar.gz",
        size: 220_056_150,
        sha256: "a481dbef80b57d19a647b1af88cd4734af52ec0c6a76b1a298185191144b9fcf",
    },
    libraries: RuntimeAsset {
        backend: LlamaBackend::Cuda,
        tag: "ubuntu-cuda-12.8-x64",
        name: "cudart-llama-b12613-bin-ubuntu-cuda-12.8-x64.tar.gz",
        size: 594_376_095,
        sha256: "b7454258a93707e36673cd6fa6a426c151d38d865ac8b8cfb1cc6d6e8ec14fb5",
    },
    library_names: ["libcudart.so.12", "libcublas.so.12", "libcublasLt.so.12"],
    toolkit: 12_080,
    prebuilt: &[86, 89, 120],
    oldest: 50,
};

pub(super) static BUILDS: [Build; 2] = [NEWEST, OLDER];

pub(super) const SERVERS: [RuntimeAsset; 2] = [NEWEST.server, OLDER.server];

static SELECTED: AtomicUsize = AtomicUsize::new(0);

const OVERRIDE: &str = "LOKALBOT_CUDA_RUNTIME";

impl Build {
    pub(super) fn download_bytes(&self) -> u64 {
        self.server.size + self.libraries.size
    }

    pub(super) fn complete(&self, dir: &Path) -> bool {
        self.library_names.iter().all(|name| {
            dir.join(name)
                .metadata()
                .is_ok_and(|m| m.is_file() && m.len() > 0)
        })
    }

    pub(super) fn place_libraries(&self, extracted: &Path, server_dir: &Path) -> Result<()> {
        let files: Vec<_> = self
            .library_names
            .iter()
            .map(|name| {
                super::find_file(extracted, name, 4)
                    .with_context(|| format!("the CUDA runtime archive has no {name}"))
            })
            .collect::<Result<_>>()?;
        for (source, name) in files.iter().zip(self.library_names) {
            std::fs::rename(source, server_dir.join(name))?;
        }
        Ok(())
    }

    fn runs(&self, driver: i32, capability: u32) -> bool {
        driver >= self.toolkit / 1000 * 1000
            && (self.prebuilt.contains(&capability)
                || (capability >= self.oldest && driver >= self.toolkit))
    }
}

pub(super) fn build_for(asset: &str) -> Option<&'static Build> {
    BUILDS.iter().find(|build| build.server.name == asset)
}

pub(super) fn likely() -> &'static Build {
    &BUILDS[SELECTED.load(Ordering::Relaxed).min(BUILDS.len() - 1)]
}

pub(super) fn is_runtime_dir(dir: &Path) -> bool {
    dir.join(if cfg!(windows) {
        "ggml-cuda.dll"
    } else {
        "libggml-cuda.so"
    })
    .is_file()
}

pub(super) fn select() -> Result<&'static Build> {
    let driver = driver_version()?;
    if let Some(wanted) = std::env::var(OVERRIDE)
        .ok()
        .filter(|v| !v.trim().is_empty())
    {
        let build = BUILDS
            .iter()
            .find(|build| build.version == wanted.trim())
            .ok_or_else(|| {
                anyhow!("{OVERRIDE}={wanted} names no CUDA runtime for this platform")
            })?;
        log::info!(
            "llama.cpp CUDA: using the {} build ({OVERRIDE})",
            build.version
        );
        return Ok(build);
    }
    let capabilities = compute_capabilities();
    let build = choose(driver, capabilities.as_deref())?;
    log::info!(
        "llama.cpp CUDA: driver supports {}, GPUs {:?}; using the {} build",
        cuda_version(driver),
        capabilities,
        build.version
    );
    let index = BUILDS.iter().position(|b| std::ptr::eq(b, build));
    SELECTED.store(index.unwrap_or(0), Ordering::Relaxed);
    Ok(build)
}

fn choose(driver: i32, capabilities: Option<&[u32]>) -> Result<&'static Build> {
    if let Some(build) = BUILDS.iter().find(|build| match capabilities {
        Some(capabilities) => capabilities.iter().all(|c| build.runs(driver, *c)),
        None => driver >= build.toolkit,
    }) {
        return Ok(build);
    }
    let gpus = capabilities.map_or("this GPU".to_string(), |capabilities| {
        let list: Vec<String> = capabilities
            .iter()
            .map(|c| format!("{}.{}", c / 10, c % 10))
            .collect();
        format!("a GPU with compute capability {}", list.join(", "))
    });
    let versions: Vec<&str> = BUILDS.iter().map(|build| build.version).collect();
    bail!(
        "LokalBot's CUDA runtimes ({}) cannot run on {gpus} with this driver (CUDA {}). Update the NVIDIA driver, or choose Auto, Vulkan or CPU.",
        versions.join(", "),
        cuda_version(driver)
    )
}

fn cuda_version(driver: i32) -> String {
    format!("{}.{}", driver / 1000, (driver % 1000) / 10)
}

pub(super) fn driver_version() -> Result<i32> {
    #[cfg(windows)]
    let driver = system32().join("nvcuda.dll");
    #[cfg(not(windows))]
    let driver = PathBuf::from("libcuda.so.1");
    let version = unsafe {
        let library = libloading::Library::new(&driver)
            .context("CUDA needs an NVIDIA driver. Install a current NVIDIA driver or choose Auto, Vulkan or CPU in Settings → Models.")?;
        let query: libloading::Symbol<'_, unsafe extern "system" fn(*mut i32) -> i32> =
            library.get(b"cuDriverGetVersion\0")?;
        let mut version = 0;
        if query(&mut version) != 0 {
            bail!(
                "The NVIDIA driver could not report its CUDA version. Choose Vulkan or CPU, or update the driver."
            );
        }
        version
    };
    validate_driver_version(version)?;
    Ok(version)
}

fn validate_driver_version(version: i32) -> Result<()> {
    if version
        < BUILDS
            .iter()
            .map(|b| b.toolkit / 1000 * 1000)
            .min()
            .unwrap_or(0)
    {
        bail!(
            "CUDA needs an NVIDIA driver supporting CUDA 12.0 or newer (driver reports {}). Update the driver or choose Auto, Vulkan or CPU.",
            cuda_version(version)
        );
    }
    Ok(())
}

#[cfg(windows)]
fn system32() -> PathBuf {
    PathBuf::from(std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into()))
        .join("System32")
}

fn compute_capabilities() -> Option<Vec<u32>> {
    #[cfg(windows)]
    let candidates = [
        system32().join("nvidia-smi.exe"),
        PathBuf::from("C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe"),
        PathBuf::from("nvidia-smi.exe"),
    ];
    #[cfg(not(windows))]
    let candidates = [PathBuf::from("nvidia-smi")];
    candidates.iter().find_map(|program| {
        let mut command = std::process::Command::new(program);
        command.args(["--query-gpu=compute_cap", "--format=csv,noheader"]);
        let out = crate::process::run_capture(command, Duration::from_secs(10)).ok()?;
        if !out.status.is_some_and(|s| s.success()) {
            return None;
        }
        parse_compute_capabilities(&out.stdout)
    })
}

fn parse_compute_capabilities(text: &str) -> Option<Vec<u32>> {
    let capabilities = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(|line| {
            let (major, minor) = line.split_once('.')?;
            Some(major.parse::<u32>().ok()? * 10 + minor.parse::<u32>().ok()?)
        })
        .collect::<Option<Vec<u32>>>()?;
    (!capabilities.is_empty()).then_some(capabilities)
}

pub(super) fn library_dirs() -> Vec<PathBuf> {
    let versioned: Vec<String> = BUILDS
        .iter()
        .map(|build| format!("CUDA_PATH_V{}", build.version.replace('.', "_")))
        .collect();
    let mut roots: Vec<PathBuf> = versioned
        .iter()
        .map(String::as_str)
        .chain(["CUDA_PATH", "CUDA_HOME"])
        .filter_map(|key| {
            std::env::var_os(key)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        })
        .collect();
    #[cfg(target_os = "linux")]
    roots.extend(
        BUILDS
            .iter()
            .map(|build| PathBuf::from(format!("/usr/local/cuda-{}", build.version)))
            .chain([PathBuf::from("/usr/local/cuda")]),
    );
    let mut dirs = Vec::new();
    for root in roots.drain(..) {
        #[cfg(windows)]
        let suffixes = ["bin/x64", "bin"];
        #[cfg(not(windows))]
        let suffixes = ["lib64", "targets/x86_64-linux/lib"];
        for suffix in suffixes {
            let path = root.join(suffix);
            if path.is_dir() && !dirs.contains(&path) {
                dirs.push(path);
            }
        }
    }
    dirs
}

#[cfg(test)]
mod tests {
    use super::*;

    fn version_of(driver: i32, capabilities: Option<&[u32]>) -> Option<&'static str> {
        choose(driver, capabilities).ok().map(|build| build.version)
    }

    #[test]
    fn driver_needs_cuda_12_for_any_build() {
        assert!(validate_driver_version(12_000).is_ok());
        assert!(validate_driver_version(13_020).is_ok());
        assert!(validate_driver_version(11_080).is_err());
    }

    #[test]
    fn prebuilt_kernels_need_only_the_major_driver_version() {
        let (newest, older) = (&BUILDS[0], &BUILDS[1]);
        for capability in [86, 89, 120] {
            assert_eq!(
                version_of(13_000, Some(&[capability])),
                Some(newest.version)
            );
        }
        assert_eq!(version_of(12_060, Some(&[86])), Some(older.version));
    }

    #[test]
    fn ptx_needs_a_driver_as_new_as_the_toolkit() {
        let (newest, older) = (&BUILDS[0], &BUILDS[1]);
        for capability in [75, 80, 90] {
            assert_eq!(version_of(13_040, Some(&[capability])), Some(older.version));
            assert_eq!(
                version_of(13_050, Some(&[capability])),
                Some(newest.version)
            );
        }
        for capability in [52, 61, 70] {
            assert_eq!(version_of(13_050, Some(&[capability])), Some(older.version));
            assert_eq!(
                version_of(older.toolkit, Some(&[capability])),
                Some(older.version)
            );
            assert!(version_of(older.toolkit - 10, Some(&[capability])).is_none());
        }
        assert!(version_of(13_050, Some(&[35])).is_none(), "Kepler");
    }

    #[test]
    fn every_gpu_must_run_the_chosen_build() {
        assert_eq!(version_of(13_020, Some(&[89, 61])), Some(BUILDS[1].version));
        let error = choose(12_000, Some(&[86, 61])).unwrap_err().to_string();
        assert!(
            error.contains("8.6, 6.1") && error.contains("CUDA 12.0"),
            "{error}"
        );
    }

    #[test]
    fn unknown_gpus_get_a_build_whose_ptx_the_driver_compiles() {
        assert_eq!(version_of(13_040, None), Some(BUILDS[1].version));
        assert_eq!(version_of(13_050, None), Some(BUILDS[0].version));
        assert!(version_of(12_000, None).is_none());
    }

    #[test]
    fn nvidia_smi_capabilities_are_parsed_strictly() {
        assert_eq!(
            parse_compute_capabilities("8.6\n 6.1 \n\n"),
            Some(vec![86, 61])
        );
        assert_eq!(parse_compute_capabilities("12.0\n"), Some(vec![120]));
        assert_eq!(parse_compute_capabilities(""), None);
        assert_eq!(parse_compute_capabilities("[N/A]\n"), None);
        assert_eq!(
            parse_compute_capabilities("8.6\nField \"compute_cap\" is not a valid field\n"),
            None
        );
    }

    #[test]
    fn builds_are_distinct_and_installed_ones_are_found_by_name() {
        assert_ne!(BUILDS[0].server.tag, BUILDS[1].server.tag);
        for build in &BUILDS {
            assert_eq!(build.server.tag, build.libraries.tag);
            assert!(build.server.name.contains(build.version));
            assert!(build.libraries.name.contains(build.version));
            assert!(std::ptr::eq(build_for(build.server.name).unwrap(), build));
            let major = build.version.split('.').next().unwrap();
            assert!(build.library_names.iter().all(|name| name.contains(major)));
        }
        assert!(build_for(BUILDS[0].libraries.name).is_none());
        assert!(std::ptr::eq(likely(), &BUILDS[0]));
    }

    #[test]
    fn companion_layout_is_flattened_beside_the_server() {
        let build = &BUILDS[0];
        let root = tempfile::tempdir().unwrap();
        let extracted = root.path().join("extracted");
        let nested = extracted.join("cudart-upstream-root");
        let server_dir = root.path().join("llama-upstream-root");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::create_dir_all(&server_dir).unwrap();
        for name in build.library_names {
            std::fs::write(nested.join(name), b"test-library").unwrap();
        }
        build.place_libraries(&extracted, &server_dir).unwrap();
        assert!(build.complete(&server_dir));
        assert!(!BUILDS[1].complete(&server_dir), "another build's names");
        assert!(
            build
                .library_names
                .iter()
                .all(|name| !nested.join(name).exists())
        );
        std::fs::remove_file(server_dir.join(build.library_names[0])).unwrap();
        assert!(!build.complete(&server_dir));
    }

    #[test]
    fn incomplete_companion_does_not_install_any_libraries() {
        let build = &BUILDS[1];
        let root = tempfile::tempdir().unwrap();
        let extracted = root.path().join("extracted");
        let server_dir = root.path().join("server");
        std::fs::create_dir_all(&extracted).unwrap();
        std::fs::create_dir_all(&server_dir).unwrap();
        std::fs::write(extracted.join(build.library_names[0]), b"partial").unwrap();
        assert!(build.place_libraries(&extracted, &server_dir).is_err());
        assert_eq!(std::fs::read_dir(server_dir).unwrap().count(), 0);
    }
}
