//! Checking the feed and preparing an update: download, verify, unpack.

use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use crate::feed::{self, Feed, FeedError, MAX_FEED_BYTES, Offer};
use crate::signature::PublicKey;
use crate::version::Version;

/// Dry runs only: a feed on this computer, and the key that signed it.
pub const FEED_URL_ENV: &str = "LOKALBOT_UPDATE_FEED_URL";
pub const PUBLIC_KEY_ENV: &str = "LOKALBOT_UPDATE_PUBLIC_KEY";
/// Dry runs only: treat this process as an older version. The relaunched
/// copy reports its real version.
pub const CURRENT_VERSION_ENV: &str = "LOKALBOT_UPDATE_CURRENT_VERSION";

#[derive(Debug, thiserror::Error)]
pub enum UpdateError {
    #[error("could not reach the update feed: {0}")]
    Network(String),
    #[error(transparent)]
    Feed(#[from] FeedError),
    #[error("could not download the update: {0}")]
    Download(String),
    /// Size, SHA-256, signature or archive contents did not match.
    #[error("the update failed its integrity check and was discarded: {0}")]
    Integrity(String),
    #[error("could not unpack the update: {0}")]
    Unpack(String),
}

/// What the feed offers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Check {
    UpToDate,
    /// The latest release has no feed for this platform (yet).
    Unpublished,
    Newer(Box<Release>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Release {
    pub feed: Feed,
    pub version: Version,
    /// False when this copy is older than the feed's minimum version.
    pub installable: bool,
}

/// One copy's update source and the key it trusts.
#[derive(Clone, Debug)]
pub struct Updater {
    platform: &'static str,
    feed_url: String,
    public_key: PublicKey,
    /// A dry-run feed on this computer may use plain HTTP.
    allow_loopback_http: bool,
    current: Version,
    work_dir: PathBuf,
}

impl Updater {
    /// The updater for this build, downloading into `work_dir`. `None` in
    /// debug builds (unless a dry-run feed is set) and on platforms without
    /// published archives.
    pub fn for_this_build(work_dir: PathBuf) -> Option<Self> {
        Self::configure(
            work_dir,
            crate::platform()?,
            cfg!(debug_assertions),
            &|name| std::env::var(name).ok().filter(|v| !v.trim().is_empty()),
        )
    }

    pub(crate) fn configure(
        work_dir: PathBuf,
        platform: &'static str,
        debug_build: bool,
        env: &dyn Fn(&str) -> Option<String>,
    ) -> Option<Self> {
        let mut updater = Self::new(
            platform,
            crate::feed_url(platform),
            PublicKey::embedded(),
            Version::current(),
            work_dir,
        );
        let Some(url) = env(FEED_URL_ENV) else {
            return (!debug_build).then_some(updater);
        };
        let url = url.trim().to_string();
        if !feed::allowed_url(&url, true) {
            log::warn!("ignoring {FEED_URL_ENV}: it must use https:// or stay on this computer");
            return (!debug_build).then_some(updater);
        }
        let local = lokalbot_core::access::is_loopback_url(&url);
        log::info!("update feed overridden: {url}");
        updater.feed_url = url;
        updater.allow_loopback_http = local;
        // A different key or version is only for testing against a feed on
        // this computer, never one from the network.
        if let Some(key) = env(PUBLIC_KEY_ENV) {
            match (local, PublicKey::from_base64(&key)) {
                (true, Ok(key)) => updater.public_key = key,
                (true, Err(err)) => {
                    log::warn!("ignoring {PUBLIC_KEY_ENV}: {err}");
                }
                (false, _) => {
                    log::warn!("ignoring {PUBLIC_KEY_ENV}: the feed is not on this computer")
                }
            }
        }
        if let Some(version) = env(CURRENT_VERSION_ENV) {
            match (local, version.trim().parse()) {
                (true, Ok(version)) => updater.current = version,
                _ => log::warn!("ignoring {CURRENT_VERSION_ENV}"),
            }
        }
        Some(updater)
    }

    pub fn new(
        platform: &'static str,
        feed_url: String,
        public_key: PublicKey,
        current: Version,
        work_dir: PathBuf,
    ) -> Self {
        let allow_loopback_http = lokalbot_core::access::is_loopback_url(&feed_url);
        Self {
            platform,
            feed_url,
            public_key,
            allow_loopback_http,
            current,
            work_dir,
        }
    }

    pub fn current(&self) -> Version {
        self.current
    }

    pub fn feed_url(&self) -> &str {
        &self.feed_url
    }

    pub fn work_dir(&self) -> &Path {
        &self.work_dir
    }

    /// Fetches and validates the feed. Blocking.
    pub fn check(&self) -> Result<Check, UpdateError> {
        let agent = ureq::Agent::new_with_config(
            ureq::Agent::config_builder()
                .https_only(!self.allow_loopback_http)
                .http_status_as_error(false)
                // GitHub redirects twice to its download host; a dry-run
                // server on this computer has no reason to redirect at all.
                .max_redirects(if self.allow_loopback_http { 0 } else { 5 })
                .user_agent(concat!("LokalBot/", env!("CARGO_PKG_VERSION")))
                .timeout_connect(Some(Duration::from_secs(15)))
                .timeout_global(Some(Duration::from_secs(60)))
                .build(),
        );
        let mut response = agent
            .get(&self.feed_url)
            .call()
            .map_err(|err| UpdateError::Network(err.to_string()))?;
        let status = response.status().as_u16();
        if status == 404 {
            return Ok(Check::Unpublished);
        }
        if !(200..300).contains(&status) {
            return Err(UpdateError::Network(format!("HTTP {status}")));
        }
        let mut body = Vec::new();
        response
            .body_mut()
            .as_reader()
            .take(MAX_FEED_BYTES + 1)
            .read_to_end(&mut body)
            .map_err(|err| UpdateError::Network(err.to_string()))?;
        if body.len() as u64 > MAX_FEED_BYTES {
            return Err(FeedError::Field("size").into());
        }
        let feed = Feed::parse(&body, self.platform, self.allow_loopback_http)?;
        Ok(match feed.offer(self.current) {
            Offer::UpToDate => Check::UpToDate,
            Offer::Newer {
                version,
                installable,
            } => Check::Newer(Box::new(Release {
                feed,
                version,
                installable,
            })),
        })
    }

    /// Downloads the release's archive, checks its size, SHA-256 and
    /// signature, and only then unpacks it. Returns the unpacked
    /// `LokalBot-<version>-<platform>` folder. Blocking.
    pub fn prepare(
        &self,
        release: &Release,
        cancel: &AtomicBool,
        progress: &mut dyn FnMut(u64, u64),
    ) -> Result<PathBuf, UpdateError> {
        let feed = &release.feed;
        let dir = self.work_dir.join(&feed.version);
        let archive = dir.join(feed.archive_name());
        let spec = lokalbot_ai::DownloadSpec {
            url: feed.url.clone(),
            sha256: feed.sha256.to_ascii_lowercase(),
            size: feed.size,
            dest: archive.clone(),
        };
        let downloaded = if self.allow_loopback_http {
            lokalbot_ai::download::download_allowing_loopback_http(&spec, cancel, progress)
        } else {
            lokalbot_ai::download(&spec, cancel, progress)
        };
        downloaded.map_err(|err| UpdateError::Download(format!("{err:#}")))?;

        let discard = |reason: String| {
            let _ = std::fs::remove_file(&archive);
            let _ = std::fs::remove_file(lokalbot_ai::download::sidecar_path(&archive));
            UpdateError::Integrity(reason)
        };
        let bytes =
            std::fs::read(&archive).map_err(|err| UpdateError::Download(err.to_string()))?;
        if bytes.len() as u64 != feed.size {
            return Err(discard("the archive size changed".into()));
        }
        if let Err(err) = self.public_key.verify(&bytes, &feed.signature) {
            return Err(discard(err.to_string()));
        }
        drop(bytes);

        let unpacked = dir.join(format!("unpacked-{}", uuid::Uuid::new_v4().simple()));
        lokalbot_ai::extract_archive(&archive, &unpacked).map_err(|err| {
            let _ = std::fs::remove_dir_all(&unpacked);
            UpdateError::Unpack(format!("{err:#}"))
        })?;
        // The signed archive names its version: a feed cannot relabel an
        // older signed archive as this release.
        let folder = unpacked.join(feed.folder_name());
        let only_folder = std::fs::read_dir(&unpacked)
            .map(|entries| entries.flatten().count() == 1)
            .unwrap_or(false);
        if !folder.is_dir() || !only_folder {
            let _ = std::fs::remove_dir_all(&unpacked);
            return Err(discard(format!(
                "the archive does not hold {}",
                feed.folder_name()
            )));
        }
        Ok(folder)
    }

    /// Deletes downloads and unpacked updates (at startup, and once one is
    /// installed).
    pub fn clear_work_dir(&self) {
        match std::fs::remove_dir_all(&self.work_dir) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                log::warn!("could not remove {}: {err}", self.work_dir.display());
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signature::SecretKey;
    use base64::Engine as _;
    use sha2::Digest as _;
    use std::collections::HashMap;
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    const PLATFORM: &str = "linux-x86_64";
    const SEED: [u8; 32] = [3; 32];
    const OTHER_SEED: [u8; 32] = [4; 32];

    /// Serves files over plain HTTP on 127.0.0.1 for the life of the test.
    #[derive(Clone)]
    struct Server {
        port: u16,
        files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    }

    impl Server {
        fn start() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let server = Self {
                port: listener.local_addr().unwrap().port(),
                files: Arc::default(),
            };
            let files = server.files.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else { break };
                    let files = files.clone();
                    std::thread::spawn(move || {
                        let mut reader = BufReader::new(stream.try_clone().unwrap());
                        let mut line = String::new();
                        let _ = reader.read_line(&mut line);
                        let mut parts = line.split_whitespace();
                        let method = parts.next().unwrap_or("").to_string();
                        let path = parts.next().unwrap_or("").to_string();
                        loop {
                            let mut header = String::new();
                            if reader.read_line(&mut header).unwrap_or(0) == 0 || header == "\r\n" {
                                break;
                            }
                        }
                        let body = files.lock().unwrap().get(&path).cloned();
                        let (status, body) = match body {
                            Some(body) => ("200 OK", body),
                            None => ("404 Not Found", Vec::new()),
                        };
                        let head = format!(
                            "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = stream.write_all(head.as_bytes());
                        if method != "HEAD" {
                            let _ = stream.write_all(&body);
                        }
                    });
                }
            });
            server
        }

        fn url(&self, path: &str) -> String {
            format!("http://127.0.0.1:{}{path}", self.port)
        }

        fn put(&self, path: &str, bytes: Vec<u8>) {
            self.files.lock().unwrap().insert(path.into(), bytes);
        }
    }

    fn tar_gz(folder: &str, files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
            Vec::new(),
            flate2::Compression::fast(),
        ));
        for (name, bytes) in files {
            let mut header = tar::Header::new_gnu();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o755);
            header.set_cksum();
            builder
                .append_data(&mut header, format!("{folder}/{name}"), *bytes)
                .unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap()
    }

    fn key(seed: [u8; 32]) -> SecretKey {
        SecretKey::from_sparkle(&base64::engine::general_purpose::STANDARD.encode(seed)).unwrap()
    }

    fn release_archive(version: &str) -> Vec<u8> {
        tar_gz(
            &feed::folder_name(version, PLATFORM),
            &[("lokalbot", b"app"), ("lokalbot-cli", b"cli")],
        )
    }

    /// Publishes `archive` as `version` and returns the feed the server serves.
    fn publish(server: &Server, version: &str, archive: &[u8], signer: &SecretKey) -> Feed {
        let name = feed::archive_name(version, PLATFORM);
        server.put(&format!("/download/{name}"), archive.to_vec());
        let feed = Feed {
            platform: PLATFORM.into(),
            version: version.into(),
            minimum_version: "0.10.0".into(),
            url: server.url(&format!("/download/{name}")),
            size: archive.len() as u64,
            sha256: hex::encode(sha2::Sha256::digest(archive)),
            signature: signer.sign(archive),
            release_notes_url: server.url("/notes"),
        };
        server.put("/feed.json", serde_json::to_vec(&feed).unwrap());
        feed
    }

    fn updater(server: &Server, current: &str, work: &Path) -> Updater {
        Updater::new(
            PLATFORM,
            server.url("/feed.json"),
            key(SEED).public_key(),
            current.parse().unwrap(),
            work.to_path_buf(),
        )
    }

    fn newer(updater: &Updater) -> Release {
        match updater.check().unwrap() {
            Check::Newer(release) => *release,
            other => panic!("expected an update, got {other:?}"),
        }
    }

    #[test]
    fn checks_downloads_verifies_and_unpacks() {
        let server = Server::start();
        let work = tempfile::tempdir().unwrap();
        publish(&server, "0.10.11", &release_archive("0.10.11"), &key(SEED));
        let updater = updater(&server, "0.10.10", work.path());
        let release = newer(&updater);
        assert_eq!(release.version, Version::new(0, 10, 11));
        assert!(release.installable);
        let mut last = (0, 0);
        let folder = updater
            .prepare(&release, &AtomicBool::new(false), &mut |done, total| {
                last = (done, total)
            })
            .unwrap();
        assert_eq!(last.0, last.1);
        assert_eq!(folder.file_name().unwrap(), "LokalBot-0.10.11-linux-x86_64");
        assert_eq!(std::fs::read(folder.join("lokalbot")).unwrap(), b"app");
        assert!(folder.starts_with(work.path()));
        updater.clear_work_dir();
        assert!(!work.path().exists());
    }

    #[test]
    fn up_to_date_older_and_unpublished_feeds() {
        let server = Server::start();
        let work = tempfile::tempdir().unwrap();
        assert_eq!(
            updater(&server, "0.10.10", work.path()).check().unwrap(),
            Check::Unpublished
        );
        publish(&server, "0.10.10", &release_archive("0.10.10"), &key(SEED));
        assert_eq!(
            updater(&server, "0.10.10", work.path()).check().unwrap(),
            Check::UpToDate
        );
        assert_eq!(
            updater(&server, "0.11.0", work.path()).check().unwrap(),
            Check::UpToDate
        );
        // Below the minimum version: offered, but not installable here.
        let release = newer(&updater(&server, "0.9.6", work.path()));
        assert!(!release.installable);
        server.put("/feed.json", b"not json".to_vec());
        assert!(matches!(
            updater(&server, "0.10.9", work.path()).check(),
            Err(UpdateError::Feed(FeedError::Json(_)))
        ));
    }

    #[test]
    fn rejects_a_tampered_archive_before_unpacking() {
        let server = Server::start();
        let work = tempfile::tempdir().unwrap();
        let archive = release_archive("0.10.11");
        let mut feed = publish(&server, "0.10.11", &archive, &key(SEED));
        // The file served is not the one that was signed; size and digest
        // are updated to match it, so only the signature can catch it.
        let mut tampered = archive.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 0xff;
        server.put(
            &format!("/download/{}", feed.archive_name()),
            tampered.clone(),
        );
        feed.sha256 = hex::encode(sha2::Sha256::digest(&tampered));
        server.put("/feed.json", serde_json::to_vec(&feed).unwrap());
        let updater = updater(&server, "0.10.10", work.path());
        let release = newer(&updater);
        let error = updater
            .prepare(&release, &AtomicBool::new(false), &mut |_, _| {})
            .unwrap_err();
        assert!(matches!(error, UpdateError::Integrity(_)), "{error}");
        let dir = work.path().join("0.10.11");
        assert_eq!(
            std::fs::read_dir(&dir).map(|d| d.count()).unwrap_or(0),
            0,
            "nothing kept or unpacked"
        );
    }

    #[test]
    fn rejects_an_archive_signed_with_another_key() {
        let server = Server::start();
        let work = tempfile::tempdir().unwrap();
        publish(
            &server,
            "0.10.11",
            &release_archive("0.10.11"),
            &key(OTHER_SEED),
        );
        let updater = updater(&server, "0.10.10", work.path());
        let release = newer(&updater);
        assert!(matches!(
            updater.prepare(&release, &AtomicBool::new(false), &mut |_, _| {}),
            Err(UpdateError::Integrity(_))
        ));
    }

    #[test]
    fn rejects_a_mismatched_digest() {
        let server = Server::start();
        let work = tempfile::tempdir().unwrap();
        let mut feed = publish(&server, "0.10.11", &release_archive("0.10.11"), &key(SEED));
        feed.sha256 = "00".repeat(32);
        server.put("/feed.json", serde_json::to_vec(&feed).unwrap());
        let updater = updater(&server, "0.10.10", work.path());
        let release = newer(&updater);
        let error = updater
            .prepare(&release, &AtomicBool::new(false), &mut |_, _| {})
            .unwrap_err();
        assert!(
            matches!(error, UpdateError::Download(ref m) if m.contains("SHA-256")),
            "{error}"
        );
    }

    #[test]
    fn rejects_an_older_signed_archive_relabelled_as_newer() {
        let server = Server::start();
        let work = tempfile::tempdir().unwrap();
        // A genuinely signed 0.10.9 archive published under 0.10.11.
        publish(&server, "0.10.11", &release_archive("0.10.9"), &key(SEED));
        let updater = updater(&server, "0.10.10", work.path());
        let release = newer(&updater);
        let error = updater
            .prepare(&release, &AtomicBool::new(false), &mut |_, _| {})
            .unwrap_err();
        assert!(
            matches!(error, UpdateError::Integrity(ref m) if m.contains("LokalBot-0.10.11")),
            "{error}"
        );
    }

    fn env(vars: &[(&'static str, &str)]) -> impl Fn(&str) -> Option<String> {
        let vars: HashMap<&'static str, String> =
            vars.iter().map(|(k, v)| (*k, v.to_string())).collect();
        move |name: &str| vars.get(name).cloned()
    }

    #[test]
    fn plain_http_feeds_must_be_local() {
        let work = tempfile::tempdir().unwrap();
        let configure = |debug: bool, vars: &[(&'static str, &str)]| {
            Updater::configure(work.path().into(), PLATFORM, debug, &env(vars))
        };
        // Release builds use GitHub and the embedded key.
        let release = configure(false, &[]).unwrap();
        assert_eq!(release.feed_url(), crate::feed_url(PLATFORM));
        assert_eq!(release.public_key, PublicKey::embedded());
        assert!(!release.allow_loopback_http);
        // Debug builds stay off unless a dry-run feed is set.
        assert!(configure(true, &[]).is_none());
        let other = key(OTHER_SEED).public_key().to_base64();
        let local = configure(
            true,
            &[
                (FEED_URL_ENV, "http://127.0.0.1:8765/linux-x86_64.json"),
                (PUBLIC_KEY_ENV, &other),
                (CURRENT_VERSION_ENV, "0.9.0"),
            ],
        )
        .unwrap();
        assert!(local.allow_loopback_http);
        assert_eq!(local.public_key.to_base64(), other);
        assert_eq!(local.current(), Version::new(0, 9, 0));
        // A key or version override never applies to a feed off this computer.
        let remote = configure(
            false,
            &[
                (FEED_URL_ENV, "https://example.com/linux-x86_64.json"),
                (PUBLIC_KEY_ENV, &other),
                (CURRENT_VERSION_ENV, "0.9.0"),
            ],
        )
        .unwrap();
        assert_eq!(remote.feed_url(), "https://example.com/linux-x86_64.json");
        assert_eq!(remote.public_key, PublicKey::embedded());
        assert_eq!(remote.current(), Version::current());
        assert!(!remote.allow_loopback_http);
        // Plain HTTP elsewhere is refused outright.
        let refused = configure(false, &[(FEED_URL_ENV, "http://example.com/feed.json")]).unwrap();
        assert_eq!(refused.feed_url(), crate::feed_url(PLATFORM));
    }
}
