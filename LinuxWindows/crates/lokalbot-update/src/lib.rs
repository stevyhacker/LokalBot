//! Signed automatic updates for LokalBot on Linux and Windows, the
//! counterpart of Sparkle in `AppUpdateManager.swift`.
//!
//! Each GitHub release attaches the Linux and Windows archives and one feed
//! per platform ([`feed`]). A copy reads the latest release's feed, and when
//! the user chooses to install, downloads the archive, checks its size,
//! SHA-256 and the Ed25519 signature made with the macOS app's Sparkle key
//! ([`signature`]), unpacks it, and swaps the files ([`install`]). On
//! Windows the installer's Installed apps entry then shows the new version
//! ([`installed_apps`]).

pub mod feed;
pub mod install;
pub mod installed_apps;
pub mod package;
pub mod signature;
pub mod version;

#[cfg(feature = "client")]
mod client;
#[cfg(feature = "client")]
pub use client::{
    CURRENT_VERSION_ENV, Check, FEED_URL_ENV, PUBLIC_KEY_ENV, Release, UpdateError, Updater,
};

pub use feed::Feed;
pub use signature::{PublicKey, SecretKey, SignatureError};
pub use version::Version;

/// `owner/name` of the repository whose releases carry updates.
pub const REPOSITORY: &str = "stevyhacker/lokalbot";
/// Where the latest release's assets resolve, like Sparkle's `SUFeedURL`.
pub const FEED_BASE_URL: &str = "https://github.com/stevyhacker/lokalbot/releases/latest/download";
/// `SUPublicEDKey` in `LokalBot/Info.plist`; `Scripts/release-preflight.py`
/// fails when the two differ.
pub const PUBLIC_KEY: &str = "R1A2lIfQ82UnkmUd12kwgpiS3tOlb6D0pVK8sKSrZdA=";
/// Platforms with published archives.
pub const PLATFORMS: [&str; 2] = ["linux-x86_64", "windows-x86_64"];

/// This build's platform, when releases publish archives for it.
pub fn platform() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => Some("linux-x86_64"),
        ("windows", "x86_64") => Some("windows-x86_64"),
        _ => None,
    }
}

/// `https://github.com/…/releases/latest/download/linux-x86_64.json`.
pub fn feed_url(platform: &str) -> String {
    format!("{FEED_BASE_URL}/{platform}.json")
}

/// The release page for a version, for copies that cannot replace themselves.
pub fn release_page(version: &Version) -> String {
    format!("https://github.com/{REPOSITORY}/releases/tag/v{version}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feed_urls_follow_sparkles_appcast() {
        assert_eq!(
            feed_url("windows-x86_64"),
            "https://github.com/stevyhacker/lokalbot/releases/latest/download/windows-x86_64.json"
        );
        assert_eq!(
            release_page(&Version::new(0, 10, 11)),
            "https://github.com/stevyhacker/lokalbot/releases/tag/v0.10.11"
        );
        if cfg!(all(
            any(target_os = "linux", windows),
            target_arch = "x86_64"
        )) {
            assert!(PLATFORMS.contains(&platform().unwrap()));
        }
    }
}
