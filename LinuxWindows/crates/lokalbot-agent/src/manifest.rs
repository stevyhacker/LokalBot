//! Pinned runtime components (`AgentRuntimeManifest` in `AgentRuntime.swift`).
//!
//! Bun is a checksum-verified release archive; pi is installed from the
//! public npm registry with the frozen lockfile bundled in this crate.
//!
//! Sources, recorded 2026-11-14: the Bun archives are the `bun-v1.4.4` assets
//! of <https://github.com/oven-sh/bun/releases/tag/bun-v1.4.4>; each was
//! downloaded once and hashed, and the digest matches the `digest` GitHub
//! publishes for the asset. The binary digests are of the file inside each
//! archive. The x64 and x64-baseline archives of this release hold the same
//! binary, so one pin per OS serves every x86-64 CPU. The pi digests, recorded
//! 2026-11-14 for pi 1.5.2, come from
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

pub const BUN_VERSION: &str = "1.4.4";
pub const PI_VERSION: &str = "1.5.2";

pub const PACKAGE_JSON_SHA256: &str =
    "493e0f739297dd7e1906cfdc394aeb3e89ec4aa3a1910fe48a4e615952490665";
pub const LOCKFILE_SHA256: &str =
    "82710b2df114f1a091d5f04b8f7a2d6e711d79ca8c4085e7c89cc9e8776ce230";
pub const PI_CLI_SHA256: &str = "e79626f2dd6f94aa45d30f3fa63cd84319a6eefcd150b353cfaf274366926774";

/// The Bun build for this OS, by its release name.
#[cfg(windows)]
mod platform {
    pub const ASSET: &str = "bun-windows-x64";
    pub const ARCHIVE_SHA256: &str =
        "cd2c0fccc78f3ede1f50ca827a15f063eda13d4d150a3d0674f4f6e323d864a5";
    pub const ARCHIVE_SIZE: u64 = 54_731_706;
    pub const BINARY: &str = "bun-windows-x64/bun.exe";
    pub const BINARY_SHA256: &str =
        "cb1d8e6564e655e49d30cead359750a1cbbd12f42651caa4b62244d7bd93c244";
    /// win32-x64 install of the bundled lockfile.
    pub const PI_TREE_SHA256: &str =
        "a4630c4e76e6adeaa9eb8fbce0df7f4b46ea7a87701e447199c793613723221f";
    /// 54.7 MB archive + 25.3 MB of npm packages.
    pub const DOWNLOAD_BYTES: u64 = 80_000_000;
    /// 115.3 MB Bun + 116.0 MB pi tree.
    pub const INSTALLED_BYTES: u64 = 231_000_000;
}

#[cfg(not(windows))]
mod platform {
    pub const ASSET: &str = "bun-linux-x64";
    pub const ARCHIVE_SHA256: &str =
        "bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c";
    pub const ARCHIVE_SIZE: u64 = 51_794_595;
    pub const BINARY: &str = "bun-linux-x64/bun";
    pub const BINARY_SHA256: &str =
        "10702245766b225e70bbf6235fd6b47214fd94b4760d00ffaed8ab0df57ac235";
    /// linux-x64 install of the bundled lockfile (125 packages).
    pub const PI_TREE_SHA256: &str =
        "1b3ef0bd494367a8465762f22a6dd90bd5e02196cac51acf1ce279a421e690c5";
    /// 51.8 MB archive + 25.3 MB of npm packages.
    pub const DOWNLOAD_BYTES: u64 = 77_000_000;
    /// 107.3 MB Bun + 116.0 MB pi tree.
    pub const INSTALLED_BYTES: u64 = 223_000_000;
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
        assert_eq!(BUN_VERSION, "1.4.4");
        assert_eq!(PI_VERSION, "1.5.2");
        assert!(manifest.bun.url.contains("bun-v1.4.4/bun-"));
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
