//! Pinned runtime components (`AgentRuntimeManifest` in `AgentRuntime.swift`).
//!
//! Bun is a checksum-verified release archive; pi is installed from the
//! public npm registry with the frozen lockfile bundled in this crate.
//!
//! Sources, recorded 2026-10-18: the Bun archives are the `bun-v1.4.2` assets
//! of <https://github.com/oven-sh/bun/releases/tag/bun-v1.4.2>; each was
//! downloaded once and hashed, and the digest matches the `digest` GitHub
//! publishes for the asset. The binary digests are of the file inside each
//! archive. The x64 and x64-baseline archives of this release hold the same
//! binary, so one pin per OS serves every x86-64 CPU. The pi digests, recorded
//! 2026-10-21 for pi 1.3.0, come from
//! `bun install --production --frozen-lockfile --ignore-scripts` of the bundled
//! `package.json` + `bun.lock` on each OS; `cli.js`, `package.json` and
//! `bun.lock` match the macOS pins byte for byte, and so does the Linux tree.

/// How a release archive is packed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArchiveKind {
    Zip,
}

/// One downloadable, checksum-pinned artifact.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeArtifact {
    pub name: String,
    pub url: String,
    /// Lowercase hex.
    pub sha256: String,
    pub size: u64,
    pub archive_kind: ArchiveKind,
    /// The executable inside the archive, `/`-separated.
    pub binary_path_in_archive: String,
}

/// Everything an install is checked against. `None` digests are not checked
/// (tests); the shipped manifest pins every one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeManifest {
    pub bun: RuntimeArtifact,
    pub bun_binary_sha256: Option<String>,
    pub pi_cli_sha256: Option<String>,
    pub package_json_sha256: Option<String>,
    pub lockfile_sha256: Option<String>,
    pub pi_runtime_tree_sha256: Option<String>,
    /// Network bytes for setup (Bun archive plus pi's npm packages), for copy.
    pub approximate_download_bytes: u64,
    /// Bytes on disk after setup, for copy.
    pub approximate_installed_bytes: u64,
}

pub const BUN_VERSION: &str = "1.4.2";
pub const PI_VERSION: &str = "1.3.0";

pub const PACKAGE_JSON_SHA256: &str =
    "bdc29089f9460b2fda49be93cc4a804fb852bdcc88ff6915fb9bea85ce01a40b";
pub const LOCKFILE_SHA256: &str =
    "7acf67d8ff01a8118e447d5494fcd17a23d8d8ec90f2836385e99bb7f7e474ff";
pub const PI_CLI_SHA256: &str = "e79626f2dd6f94aa45d30f3fa63cd84319a6eefcd150b353cfaf274366926774";

/// The Bun build for this OS, by its release name.
#[cfg(windows)]
mod platform {
    pub const ASSET: &str = "bun-windows-x64";
    pub const ARCHIVE_SHA256: &str =
        "ce4c17497b2f29712a99d3d53f028de28cd42e3bacb8589599e7f000e49b6405";
    pub const ARCHIVE_SIZE: u64 = 39_807_510;
    pub const BINARY: &str = "bun-windows-x64/bun.exe";
    pub const BINARY_SHA256: &str =
        "15277c59ccd6c6c20f8dc9716c2b59c1776320d606b6a8658f70be8799519ca4";
    /// win32-x64 install of the bundled lockfile.
    pub const PI_TREE_SHA256: &str =
        "b08b18bf247139aeba1abac52baaea03ba7733a9877140440fce536ead545e27";
    pub const DOWNLOAD_BYTES: u64 = 65_000_000;
    pub const INSTALLED_BYTES: u64 = 198_000_000;
}

#[cfg(not(windows))]
mod platform {
    pub const ASSET: &str = "bun-linux-x64";
    pub const ARCHIVE_SHA256: &str =
        "36368faef7527875d5ffa52e53cd48021741f2a83eb6208a8dd64068d422a913";
    pub const ARCHIVE_SIZE: u64 = 36_646_985;
    pub const BINARY: &str = "bun-linux-x64/bun";
    pub const BINARY_SHA256: &str =
        "a83d263767d839e4d2649ca8e35d07159c7afc99afdc96d731ced29e056dda0c";
    /// linux-x64 install of the bundled lockfile (123 packages).
    pub const PI_TREE_SHA256: &str =
        "c9ee7086e5c6b38f6362f095704519b9a91d27200415382d0d733342f2b974be";
    /// 36.6 MB archive + 24.4 MB of npm packages.
    pub const DOWNLOAD_BYTES: u64 = 61_000_000;
    /// 79.5 MB Bun + 112.6 MB pi tree.
    pub const INSTALLED_BYTES: u64 = 192_000_000;
}

impl RuntimeManifest {
    /// The pins for this OS.
    pub fn current() -> Self {
        Self {
            bun: RuntimeArtifact {
                name: format!("Bun {BUN_VERSION}"),
                url: format!(
                    "https://github.com/oven-sh/bun/releases/download/bun-v{BUN_VERSION}/{}.zip",
                    platform::ASSET
                ),
                sha256: platform::ARCHIVE_SHA256.into(),
                size: platform::ARCHIVE_SIZE,
                archive_kind: ArchiveKind::Zip,
                binary_path_in_archive: platform::BINARY.into(),
            },
            bun_binary_sha256: Some(platform::BINARY_SHA256.into()),
            pi_cli_sha256: Some(PI_CLI_SHA256.into()),
            package_json_sha256: Some(PACKAGE_JSON_SHA256.into()),
            lockfile_sha256: Some(LOCKFILE_SHA256.into()),
            pi_runtime_tree_sha256: Some(platform::PI_TREE_SHA256.into()),
            approximate_download_bytes: platform::DOWNLOAD_BYTES,
            approximate_installed_bytes: platform::INSTALLED_BYTES,
        }
    }

    /// "about 60 MB", for the setup card.
    pub fn download_label(&self) -> String {
        megabytes(self.approximate_download_bytes)
    }

    pub fn installed_label(&self) -> String {
        megabytes(self.approximate_installed_bytes)
    }
}

fn megabytes(bytes: u64) -> String {
    let mb = (bytes as f64 / 1_000_000.0 / 5.0).round() * 5.0;
    format!("{mb:.0} MB")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_pins_expected_versions() {
        let manifest = RuntimeManifest::current();
        assert_eq!(BUN_VERSION, "1.4.2");
        assert_eq!(PI_VERSION, "1.3.0");
        assert!(manifest.bun.url.contains("bun-v1.4.2/bun-"));
        assert!(manifest.bun.url.ends_with("-x64.zip"));
        for digest in [
            Some(manifest.bun.sha256.clone()),
            manifest.bun_binary_sha256.clone(),
            manifest.pi_cli_sha256.clone(),
            manifest.package_json_sha256.clone(),
            manifest.lockfile_sha256.clone(),
            manifest.pi_runtime_tree_sha256.clone(),
        ] {
            assert!(crate::digest::is_hex_digest(&digest.unwrap()));
        }
    }

    #[test]
    fn bundled_package_files_match_their_pins() {
        use sha2::{Digest as _, Sha256};
        assert_eq!(
            hex::encode(Sha256::digest(crate::resources::PACKAGE_JSON.as_bytes())),
            PACKAGE_JSON_SHA256
        );
        assert_eq!(
            hex::encode(Sha256::digest(crate::resources::BUN_LOCK.as_bytes())),
            LOCKFILE_SHA256
        );
    }

    #[test]
    fn size_labels_round_to_five_megabytes() {
        assert_eq!(megabytes(66_000_000), "65 MB");
        assert_eq!(megabytes(204_000_000), "205 MB");
    }
}
