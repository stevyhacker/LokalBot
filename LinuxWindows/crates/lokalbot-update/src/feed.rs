//! The per-platform update feed (`linux-x86_64.json`, `windows-x86_64.json`),
//! the counterpart of Sparkle's `appcast.xml`. Each release attaches one per
//! platform; installed copies read the one attached to the latest release.
//!
//! ```json
//! {
//!   "platform": "linux-x86_64",
//!   "version": "0.10.11",
//!   "minimumVersion": "0.10.10",
//!   "url": "https://github.com/stevyhacker/lokalbot/releases/download/v0.10.11/LokalBot-0.10.11-linux-x86_64.tar.gz",
//!   "size": 41234567,
//!   "sha256": "…64 hex digits…",
//!   "signature": "…base64 Ed25519 signature of the archive bytes…",
//!   "releaseNotesUrl": "https://github.com/stevyhacker/lokalbot/releases/tag/v0.10.11"
//! }
//! ```
//!
//! `minimumVersion` is the oldest installed version that may install this
//! update itself (Sparkle's `minimumAutoupdateVersion`); older copies are
//! sent to the release page instead. The signature covers the archive, and
//! the archive's top folder names its version, so a feed cannot pass an old
//! signed archive off as a newer one.

use serde::{Deserialize, Serialize};

use crate::signature;
use crate::version::Version;

/// Feeds are small; anything larger is not a feed.
pub const MAX_FEED_BYTES: u64 = 64 * 1024;
/// Archives are tens of megabytes.
pub const MAX_ARCHIVE_BYTES: u64 = 1024 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Feed {
    pub platform: String,
    pub version: String,
    pub minimum_version: String,
    pub url: String,
    pub size: u64,
    pub sha256: String,
    pub signature: String,
    pub release_notes_url: String,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum FeedError {
    #[error("the update feed is not valid JSON: {0}")]
    Json(String),
    #[error("the update feed is for {found}, not {expected}")]
    Platform { expected: String, found: String },
    #[error("the update feed has an invalid {0}")]
    Field(&'static str),
}

/// What a valid feed offers this copy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Offer {
    UpToDate,
    /// `installable` is false when this copy is older than the feed's
    /// minimum version and must be replaced by hand.
    Newer {
        version: Version,
        installable: bool,
    },
}

impl Feed {
    /// Parses and validates a feed for `platform`. Plain `http://` URLs are
    /// accepted only when `allow_loopback_http` is set and they stay on this
    /// computer (a dry-run feed).
    pub fn parse(
        json: &[u8],
        platform: &str,
        allow_loopback_http: bool,
    ) -> Result<Feed, FeedError> {
        let feed: Feed =
            serde_json::from_slice(json).map_err(|err| FeedError::Json(err.to_string()))?;
        feed.validate(platform, allow_loopback_http)?;
        Ok(feed)
    }

    pub fn validate(&self, platform: &str, allow_loopback_http: bool) -> Result<(), FeedError> {
        if self.platform != platform {
            return Err(FeedError::Platform {
                expected: platform.into(),
                found: self.platform.clone(),
            });
        }
        let version: Version = self
            .version
            .parse()
            .map_err(|_| FeedError::Field("version"))?;
        let minimum: Version = self
            .minimum_version
            .parse()
            .map_err(|_| FeedError::Field("minimumVersion"))?;
        if minimum > version {
            return Err(FeedError::Field("minimumVersion"));
        }
        if !allowed_url(&self.url, allow_loopback_http) {
            return Err(FeedError::Field("url"));
        }
        if !self.url.ends_with(&format!("/{}", self.archive_name())) {
            return Err(FeedError::Field("url"));
        }
        if !allowed_url(&self.release_notes_url, allow_loopback_http) {
            return Err(FeedError::Field("releaseNotesUrl"));
        }
        if self.size == 0 || self.size > MAX_ARCHIVE_BYTES {
            return Err(FeedError::Field("size"));
        }
        if self.sha256.len() != 64 || !self.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(FeedError::Field("sha256"));
        }
        signature::decode_signature(&self.signature).map_err(|_| FeedError::Field("signature"))?;
        Ok(())
    }

    /// The validated version. Call only on a parsed feed.
    pub fn version(&self) -> Version {
        self.version.parse().expect("validated feed")
    }

    pub fn minimum_version(&self) -> Version {
        self.minimum_version.parse().expect("validated feed")
    }

    /// `LokalBot-0.10.11-linux-x86_64`: the archive's top folder.
    pub fn folder_name(&self) -> String {
        folder_name(&self.version, &self.platform)
    }

    /// `LokalBot-0.10.11-linux-x86_64.tar.gz` (`.zip` on Windows).
    pub fn archive_name(&self) -> String {
        archive_name(&self.version, &self.platform)
    }

    pub fn offer(&self, current: Version) -> Offer {
        let version = self.version();
        if version <= current {
            Offer::UpToDate
        } else {
            Offer::Newer {
                version,
                installable: current >= self.minimum_version(),
            }
        }
    }
}

pub fn folder_name(version: &str, platform: &str) -> String {
    format!("LokalBot-{version}-{platform}")
}

pub fn archive_name(version: &str, platform: &str) -> String {
    let extension = if platform.starts_with("windows-") {
        "zip"
    } else {
        "tar.gz"
    };
    format!("{}.{extension}", folder_name(version, platform))
}

/// HTTPS anywhere, or plain HTTP to this computer for a dry run.
pub fn allowed_url(url: &str, allow_loopback_http: bool) -> bool {
    let lower = url.to_ascii_lowercase();
    if let Some(rest) = lower.strip_prefix("https://") {
        return !rest.is_empty() && !rest.starts_with('/');
    }
    allow_loopback_http
        && lower
            .strip_prefix("http://")
            .is_some_and(|rest| is_loopback_authority(rest.split(['/', '?', '#']).next()))
}

fn is_loopback_authority(authority: Option<&str>) -> bool {
    let Some(authority) = authority else {
        return false;
    };
    if authority.contains('@') {
        return false;
    }
    let host = match authority.strip_prefix('[') {
        Some(rest) => rest.split(']').next().unwrap_or(""),
        None => authority.split(':').next().unwrap_or(""),
    };
    host == "localhost"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIGNATURE: &str =
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==";

    fn feed() -> Feed {
        Feed {
            platform: "linux-x86_64".into(),
            version: "0.10.11".into(),
            minimum_version: "0.10.10".into(),
            url: "https://github.com/stevyhacker/lokalbot/releases/download/v0.10.11/LokalBot-0.10.11-linux-x86_64.tar.gz".into(),
            size: 41_234_567,
            sha256: "ab".repeat(32),
            signature: SIGNATURE.into(),
            release_notes_url: "https://github.com/stevyhacker/lokalbot/releases/tag/v0.10.11".into(),
        }
    }

    fn json(feed: &Feed) -> Vec<u8> {
        serde_json::to_vec(feed).unwrap()
    }

    #[test]
    fn parses_the_published_format() {
        let text = br#"{
            "platform": "linux-x86_64", "version": "0.10.11", "minimumVersion": "0.10.10",
            "url": "https://github.com/stevyhacker/lokalbot/releases/download/v0.10.11/LokalBot-0.10.11-linux-x86_64.tar.gz",
            "size": 41234567, "sha256": "abababababababababababababababababababababababababababababababab",
            "signature": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
            "releaseNotesUrl": "https://github.com/stevyhacker/lokalbot/releases/tag/v0.10.11",
            "publishedAt": "ignored: later releases may add fields"
        }"#;
        assert_eq!(Feed::parse(text, "linux-x86_64", false), Ok(feed()));
        assert_eq!(feed().folder_name(), "LokalBot-0.10.11-linux-x86_64");
    }

    #[test]
    fn compares_against_the_running_version() {
        let feed = feed();
        assert_eq!(feed.offer(Version::new(0, 10, 11)), Offer::UpToDate);
        assert_eq!(feed.offer(Version::new(0, 11, 0)), Offer::UpToDate);
        assert_eq!(
            feed.offer(Version::new(0, 10, 10)),
            Offer::Newer {
                version: Version::new(0, 10, 11),
                installable: true
            }
        );
        assert_eq!(
            feed.offer(Version::new(0, 9, 6)),
            Offer::Newer {
                version: Version::new(0, 10, 11),
                installable: false
            }
        );
    }

    #[test]
    fn rejects_feeds_for_another_platform() {
        assert!(matches!(
            Feed::parse(&json(&feed()), "windows-x86_64", false),
            Err(FeedError::Platform { .. })
        ));
    }

    #[test]
    fn rejects_invalid_fields() {
        type Change = Box<dyn Fn(&mut Feed)>;
        let cases: Vec<(&str, Change)> = vec![
            ("version", Box::new(|f| f.version = "0.10".into())),
            ("version", Box::new(|f| f.version = "v0.10.11".into())),
            (
                "minimumVersion",
                Box::new(|f| f.minimum_version = "".into()),
            ),
            (
                "minimumVersion",
                Box::new(|f| f.minimum_version = "0.10.12".into()),
            ),
            (
                "url",
                Box::new(|f| f.url = f.url.replace("https://", "http://")),
            ),
            (
                "url",
                Box::new(|f| f.url = "file:///tmp/LokalBot-0.10.11-linux-x86_64.tar.gz".into()),
            ),
            // The URL must name this version's archive.
            (
                "url",
                Box::new(|f| f.url = f.url.replace("0.10.11-linux", "0.10.10-linux")),
            ),
            (
                "releaseNotesUrl",
                Box::new(|f| f.release_notes_url = "javascript:alert(1)".into()),
            ),
            ("size", Box::new(|f| f.size = 0)),
            ("size", Box::new(|f| f.size = MAX_ARCHIVE_BYTES + 1)),
            ("sha256", Box::new(|f| f.sha256 = "ab".repeat(31))),
            ("sha256", Box::new(|f| f.sha256 = "zz".repeat(32))),
            ("signature", Box::new(|f| f.signature = "AAAA".into())),
        ];
        for (field, change) in cases {
            let mut bad = feed();
            change(&mut bad);
            assert_eq!(
                Feed::parse(&json(&bad), "linux-x86_64", false),
                Err(FeedError::Field(field)),
                "{bad:?}"
            );
        }
        assert!(matches!(
            Feed::parse(b"<appcast/>", "linux-x86_64", false),
            Err(FeedError::Json(_))
        ));
        assert!(matches!(
            Feed::parse(br#"{"version": "0.10.11"}"#, "linux-x86_64", false),
            Err(FeedError::Json(_))
        ));
    }

    #[test]
    fn plain_http_only_for_a_loopback_dry_run() {
        let mut local = feed();
        local.url = "http://127.0.0.1:8765/LokalBot-0.10.11-linux-x86_64.tar.gz".into();
        local.release_notes_url = "http://localhost:8765/notes".into();
        assert_eq!(
            Feed::parse(&json(&local), "linux-x86_64", false),
            Err(FeedError::Field("url"))
        );
        assert_eq!(Feed::parse(&json(&local), "linux-x86_64", true), Ok(local));
        for url in [
            "http://192.168.1.5/x",
            "http://example.com/x",
            "http://127.0.0.1.example.com/x",
            "http://user@127.0.0.1/x",
            "http://[::1]:80/x",
        ] {
            assert_eq!(allowed_url(url, true), url == "http://[::1]:80/x", "{url}");
        }
    }

    #[test]
    fn archive_names_follow_package_sh() {
        assert_eq!(
            archive_name("0.10.11", "windows-x86_64"),
            "LokalBot-0.10.11-windows-x86_64.zip"
        );
        assert_eq!(
            archive_name("0.10.11", "linux-x86_64"),
            "LokalBot-0.10.11-linux-x86_64.tar.gz"
        );
    }
}
