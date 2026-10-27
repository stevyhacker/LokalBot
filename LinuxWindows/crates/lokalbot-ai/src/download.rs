//! Verified downloads (`ModelDownloadManager.swift`, `ParallelRangeDownloader.swift`,
//! `DownloadIntegrity.swift`) and archive extraction.
//!
//! A download streams into `<dest>.part`, is checked against its pinned size
//! and SHA-256 (and GGUF magic for `.gguf`), then renamed into place with a
//! `<dest>.sha256` sidecar so later launches skip re-hashing. Files of 256 MiB
//! and more arrive as 64 MiB ranges over up to six connections, each written
//! at its own offset; a `<dest>.part.json` manifest of finished ranges lets a
//! failed or cancelled download resume.

use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc;
use std::time::Duration;

use anyhow::{Context as _, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use crate::error::AiError;

/// One file to fetch: an HTTPS URL, its pinned SHA-256 and exact size.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DownloadSpec {
    pub url: String,
    pub sha256: String,
    pub size: u64,
    pub dest: PathBuf,
}

const MINIMUM_RANGED_BYTES: u64 = 256 * 1024 * 1024;
const PART_BYTES: u64 = 64 * 1024 * 1024;
const MAX_CONCURRENT_PARTS: usize = 6;
const CHUNK: usize = 256 * 1024;

pub const UNPINNED_HUGGING_FACE_MESSAGE: &str = "For safety, Hugging Face models must use an immutable revision and an advertised SHA-256 digest. Remove this model, then add it again from Browse Hugging Face.";

#[derive(Clone, Debug)]
pub(crate) struct Options {
    pub minimum_ranged_bytes: u64,
    pub part_bytes: u64,
    pub max_concurrent_parts: usize,
    /// Tests serve files from a plain-HTTP loopback stub.
    pub allow_loopback_http: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            minimum_ranged_bytes: MINIMUM_RANGED_BYTES,
            part_bytes: PART_BYTES,
            max_concurrent_parts: MAX_CONCURRENT_PARTS,
            allow_loopback_http: false,
        }
    }
}

/// Downloads `spec` unless it is already installed and verified.
/// `progress(bytes_done, bytes_total)` runs on the calling thread.
pub fn download(
    spec: &DownloadSpec,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<()> {
    download_with(spec, cancel, progress, &Options::default())
}

/// [`download`] that also accepts plain `http://` from this computer, for
/// dry-run update feeds served locally. Size and SHA-256 are still checked.
pub fn download_allowing_loopback_http(
    spec: &DownloadSpec,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<()> {
    let options = Options {
        allow_loopback_http: true,
        ..Options::default()
    };
    download_with(spec, cancel, progress, &options)
}

pub(crate) fn download_with(
    spec: &DownloadSpec,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
    options: &Options,
) -> Result<()> {
    if let Some(refusal) = source_refusal(&spec.url, &spec.sha256, options.allow_loopback_http) {
        bail!(refusal);
    }
    if installed(&spec.dest, spec.size, &spec.sha256) {
        progress(spec.size, spec.size);
        return Ok(());
    }
    let dir = spec
        .dest
        .parent()
        .ok_or_else(|| anyhow!("download destination has no folder"))?;
    fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    let part = with_suffix(&spec.dest, ".part");
    let manifest = with_suffix(&spec.dest, ".part.json");

    // Credit bytes an interrupted attempt already holds.
    let stashed = fs::metadata(&part)
        .map(|m| m.len().min(spec.size))
        .unwrap_or(0);
    if let Some(available) = free_space(dir) {
        let needed = spec.size.saturating_sub(stashed);
        if available < needed {
            bail!(
                "Not enough free disk space: {} needed, {} available.",
                gigabytes(needed),
                gigabytes(available)
            );
        }
    }

    let agent = download_agent(options);
    let probe = probe(&agent, &spec.url)?;
    if let Some(total) = probe.total_bytes
        && total != spec.size
    {
        bail!(
            "Download failed: the server reported {total} bytes for a {}-byte file.",
            spec.size
        );
    }
    let ranged = probe.supports_ranges
        && probe.total_bytes.is_some()
        && spec.size >= options.minimum_ranged_bytes;
    if ranged {
        download_ranged(
            &agent,
            spec,
            &part,
            &manifest,
            probe.validator.as_deref(),
            options,
            cancel,
            progress,
        )?;
    } else {
        let _ = fs::remove_file(&manifest);
        download_single(&agent, spec, &part, probe.supports_ranges, cancel, progress)?;
    }

    let actual = fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    if actual != spec.size {
        let _ = fs::remove_file(&part);
        let _ = fs::remove_file(&manifest);
        bail!(
            "Download failed: assembled {actual} bytes for a {}-byte file.",
            spec.size
        );
    }
    if is_gguf_name(&spec.dest) && !crate::catalog::looks_like_gguf(&part) {
        let _ = fs::remove_file(&part);
        let _ = fs::remove_file(&manifest);
        bail!("The downloaded file is not a GGUF model.");
    }
    let digest = sha256_file(&part, Some(cancel))?;
    if !digest.eq_ignore_ascii_case(&spec.sha256) {
        let _ = fs::remove_file(&part);
        let _ = fs::remove_file(&manifest);
        bail!(
            "The downloaded file {} failed its SHA-256 integrity check.",
            file_name(&spec.dest)
        );
    }
    let _ = fs::remove_file(sidecar_path(&spec.dest));
    fs::rename(&part, &spec.dest).with_context(|| format!("installing {}", spec.dest.display()))?;
    write_sidecar(&spec.dest, &digest)?;
    let _ = fs::remove_file(&manifest);
    progress(spec.size, spec.size);
    Ok(())
}

/// Why a source may not be downloaded, or `None` (`ModelDownloadManager.sourceRefusal`).
pub fn source_refusal(url: &str, sha256: &str, allow_loopback_http: bool) -> Option<String> {
    let lower = url.trim().to_ascii_lowercase();
    let https = lower.starts_with("https://");
    if !https && !(allow_loopback_http && lokalbot_core::access::is_loopback_url(url)) {
        return Some("Model downloads must use an https:// URL.".into());
    }
    if sha256.len() != 64 || !sha256.chars().all(|c| c.is_ascii_hexdigit()) {
        return Some("The download has no valid SHA-256 digest to check it against.".into());
    }
    if lower.starts_with("https://huggingface.co/") && !is_pinned_hugging_face(&lower) {
        return Some(UNPINNED_HUGGING_FACE_MESSAGE.into());
    }
    None
}

fn is_pinned_hugging_face(url: &str) -> bool {
    let mut parts = url.split('/');
    parts.by_ref().find(|p| *p == "resolve");
    parts
        .next()
        .is_some_and(|rev| rev.len() == 40 && rev.chars().all(|c| c.is_ascii_hexdigit()))
}

fn installed(dest: &Path, size: u64, sha256: &str) -> bool {
    fs::metadata(dest).is_ok_and(|m| m.len() == size)
        && read_sidecar(dest).is_some_and(|digest| digest.eq_ignore_ascii_case(sha256))
}

fn download_agent(options: &Options) -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .https_only(!options.allow_loopback_http)
        .http_status_as_error(false)
        .max_redirects(10)
        // A new connection for every request. ureq would send the GET down
        // the connection that answered the HEAD probe even when an HTTP/1.0
        // server (`python -m http.server` for a dry-run update feed) closes
        // it after one response, failing the download with "Peer
        // disconnected".
        .max_idle_connections(0)
        .user_agent(concat!("LokalBot/", env!("CARGO_PKG_VERSION")))
        .timeout_connect(Some(Duration::from_secs(30)))
        .timeout_recv_response(Some(Duration::from_secs(60)))
        .build();
    ureq::Agent::new_with_config(config)
}

struct Probe {
    total_bytes: Option<u64>,
    supports_ranges: bool,
    validator: Option<String>,
}

fn probe(agent: &ureq::Agent, url: &str) -> Result<Probe> {
    let response = match agent.head(url).call() {
        Ok(response) => response,
        Err(err) => return Err(transport_error(err)),
    };
    let status = response.status().as_u16();
    if status == 405 || status == 501 {
        return Ok(Probe {
            total_bytes: None,
            supports_ranges: false,
            validator: None,
        });
    }
    if !(200..300).contains(&status) {
        bail!("Download failed (HTTP {status}).");
    }
    let header = |name: &str| {
        response
            .headers()
            .get(name)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string)
    };
    let total_bytes = header("content-length")
        .and_then(|v| v.parse::<u64>().ok())
        .filter(|n| *n > 0)
        .or_else(|| header("x-linked-size").and_then(|v| v.parse().ok()));
    let supports_ranges =
        header("accept-ranges").is_some_and(|v| v.to_ascii_lowercase().contains("bytes"));
    let validator = header("x-linked-etag")
        .or_else(|| header("etag"))
        .or_else(|| header("x-repo-commit"))
        .or_else(|| header("last-modified"));
    Ok(Probe {
        total_bytes,
        supports_ranges,
        validator,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ByteRange {
    pub index: usize,
    pub start: u64,
    pub end: u64,
}

impl ByteRange {
    fn len(&self) -> u64 {
        self.end - self.start + 1
    }
}

pub(crate) fn ranges(total: u64, part: u64) -> Vec<ByteRange> {
    let mut out = Vec::new();
    if total == 0 || part == 0 {
        return out;
    }
    let mut start = 0;
    while start < total {
        let end = (start + part - 1).min(total - 1);
        out.push(ByteRange {
            index: out.len(),
            start,
            end,
        });
        start = end + 1;
    }
    out
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct ResumeState {
    url: String,
    total_bytes: u64,
    part_size: u64,
    validator: Option<String>,
    completed_parts: Vec<usize>,
}

enum PartEvent {
    Done(usize),
    Failed(anyhow::Error),
}

#[allow(clippy::too_many_arguments)]
fn download_ranged(
    agent: &ureq::Agent,
    spec: &DownloadSpec,
    part: &Path,
    manifest: &Path,
    validator: Option<&str>,
    options: &Options,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<()> {
    let total = spec.size;
    let byte_ranges = ranges(total, options.part_bytes);
    // A stash is reused only for the same URL, size, part size and server
    // validator: a changed upstream file is never stitched from two versions.
    let mut completed: BTreeSet<usize> = fs::read(manifest)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<ResumeState>(&bytes).ok())
        .filter(|state| {
            state.url == spec.url
                && state.total_bytes == total
                && state.part_size == options.part_bytes
                && validator.is_some()
                && state.validator.as_deref() == validator
                && part.is_file()
        })
        .map(|state| {
            state
                .completed_parts
                .into_iter()
                .filter(|i| *i < byte_ranges.len())
                .collect()
        })
        .unwrap_or_default();
    if completed.is_empty() {
        let _ = fs::remove_file(part);
        let _ = fs::remove_file(manifest);
    }
    {
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(part)?;
        file.set_len(total)?;
    }
    let remaining: Vec<ByteRange> = byte_ranges
        .iter()
        .copied()
        .filter(|r| !completed.contains(&r.index))
        .collect();
    let done = AtomicU64::new(
        byte_ranges
            .iter()
            .filter(|r| completed.contains(&r.index))
            .map(ByteRange::len)
            .sum(),
    );
    let next = AtomicUsize::new(0);
    let stop = AtomicBool::new(false);
    let mut first_error: Option<anyhow::Error> = None;
    let save = |completed: &BTreeSet<usize>| {
        let state = ResumeState {
            url: spec.url.clone(),
            total_bytes: total,
            part_size: options.part_bytes,
            validator: validator.map(str::to_string),
            completed_parts: completed.iter().copied().collect(),
        };
        if let Ok(bytes) = serde_json::to_vec(&state) {
            let _ = lokalbot_core::library::write_atomic(manifest, &bytes);
        }
    };

    std::thread::scope(|scope| {
        let (tx, rx) = mpsc::channel::<PartEvent>();
        let workers = options.max_concurrent_parts.max(1).min(remaining.len());
        for _ in 0..workers {
            let tx = tx.clone();
            let (remaining, next, stop, done) = (&remaining, &next, &stop, &done);
            scope.spawn(move || {
                loop {
                    if stop.load(Ordering::Relaxed) || cancel.load(Ordering::Relaxed) {
                        return;
                    }
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    let Some(range) = remaining.get(i).copied() else {
                        return;
                    };
                    let mut attempt = 0;
                    let outcome = loop {
                        match fetch_part(agent, &spec.url, range, total, part, done, cancel) {
                            Ok(()) => break Ok(()),
                            Err(err)
                                if attempt == 0
                                    && part_error_is_transient(&err)
                                    && !cancel.load(Ordering::Relaxed) =>
                            {
                                attempt += 1;
                                std::thread::sleep(Duration::from_millis(500));
                            }
                            Err(err) => break Err(err),
                        }
                    };
                    match outcome {
                        Ok(()) => {
                            let _ = tx.send(PartEvent::Done(range.index));
                        }
                        Err(err) => {
                            stop.store(true, Ordering::Relaxed);
                            let _ = tx.send(PartEvent::Failed(err));
                            return;
                        }
                    }
                }
            });
        }
        drop(tx);
        progress(done.load(Ordering::Relaxed), total);
        loop {
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(PartEvent::Done(index)) => {
                    completed.insert(index);
                    save(&completed);
                }
                Ok(PartEvent::Failed(err)) => {
                    if first_error.is_none() {
                        first_error = Some(err);
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
            progress(done.load(Ordering::Relaxed).min(total), total);
        }
    });

    if let Some(err) = first_error {
        if crate::error::is_cancelled(&err) {
            return Err(AiError::Cancelled.into());
        }
        return Err(err);
    }
    crate::error::check_cancelled(cancel)?;
    if completed.len() != byte_ranges.len() {
        bail!(
            "Download failed: assembled {} bytes for a {total}-byte file.",
            done.load(Ordering::Relaxed)
        );
    }
    let _ = fs::remove_file(manifest);
    Ok(())
}

fn part_error_is_transient(err: &anyhow::Error) -> bool {
    matches!(
        err.downcast_ref::<AiError>(),
        Some(AiError::ServerUnreachable(_))
    ) || err.downcast_ref::<io::Error>().is_some()
}

/// One range, written at its offset as it arrives. A server that ignores
/// `Range` answers 200 with the whole file; that must never be written here.
fn fetch_part(
    agent: &ureq::Agent,
    url: &str,
    range: ByteRange,
    total: u64,
    part: &Path,
    done: &AtomicU64,
    cancel: &AtomicBool,
) -> Result<()> {
    let mut response = agent
        .get(url)
        .header("Range", format!("bytes={}-{}", range.start, range.end))
        .config()
        .timeout_recv_body(Some(Duration::from_secs(20 * 60)))
        .build()
        .call()
        .map_err(transport_error)?;
    let status = response.status().as_u16();
    if status != 206 {
        bail!("Download failed: server did not honor byte ranges (HTTP {status}).");
    }
    let expected = format!("bytes {}-{}/{}", range.start, range.end, total);
    let content_range = response
        .headers()
        .get("content-range")
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    if !content_range.eq_ignore_ascii_case(&expected) {
        bail!("Download failed: invalid server response.");
    }
    let mut file = OpenOptions::new().write(true).open(part)?;
    file.seek(SeekFrom::Start(range.start))?;
    let mut reader = response.body_mut().as_reader();
    let mut buffer = vec![0u8; CHUNK];
    let mut received = 0u64;
    let result = (|| -> Result<()> {
        loop {
            crate::error::check_cancelled(cancel)?;
            let n = match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => n,
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err.into()),
            };
            if received + n as u64 > range.len() {
                bail!(
                    "Download failed: received {} bytes for a {}-byte chunk.",
                    received + n as u64,
                    range.len()
                );
            }
            file.write_all(&buffer[..n])?;
            received += n as u64;
            done.fetch_add(n as u64, Ordering::Relaxed);
        }
        if received != range.len() {
            bail!(
                "Download failed: received {received} bytes for a {}-byte chunk.",
                range.len()
            );
        }
        Ok(())
    })();
    if result.is_err() {
        done.fetch_sub(received, Ordering::Relaxed);
    }
    result
}

/// One streamed GET, resuming an earlier `.part` with `Range: bytes=N-`
/// when the server supports it.
fn download_single(
    agent: &ureq::Agent,
    spec: &DownloadSpec,
    part: &Path,
    supports_ranges: bool,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<()> {
    let existing = fs::metadata(part).map(|m| m.len()).unwrap_or(0);
    let mut offset = if supports_ranges && existing > 0 && existing < spec.size {
        existing
    } else {
        0
    };
    let mut request = agent.get(&spec.url);
    if offset > 0 {
        request = request.header("Range", format!("bytes={offset}-"));
    }
    let mut response = request
        .config()
        .timeout_recv_body(Some(Duration::from_secs(60 * 60)))
        .build()
        .call()
        .map_err(transport_error)?;
    let status = response.status().as_u16();
    match status {
        206 if offset > 0 => {
            let content_range = response
                .headers()
                .get("content-range")
                .and_then(|v| v.to_str().ok())
                .unwrap_or_default();
            if !content_range
                .to_ascii_lowercase()
                .starts_with(&format!("bytes {offset}-"))
            {
                bail!("Download failed: invalid server response.");
            }
        }
        200..=299 => offset = 0,
        _ => bail!("Download failed (HTTP {status})."),
    }
    let mut file = if offset > 0 {
        OpenOptions::new().append(true).open(part)?
    } else {
        File::create(part)?
    };
    let mut written = offset;
    progress(written, spec.size);
    let mut reader = response.body_mut().as_reader();
    let mut buffer = vec![0u8; CHUNK];
    loop {
        crate::error::check_cancelled(cancel)?;
        let n = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => n,
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(anyhow::Error::new(err).context("Download failed")),
        };
        if written + n as u64 > spec.size {
            bail!(
                "Download failed: the server sent more than the expected {} bytes.",
                spec.size
            );
        }
        file.write_all(&buffer[..n])?;
        written += n as u64;
        progress(written, spec.size);
    }
    file.sync_all()?;
    Ok(())
}

fn transport_error(err: ureq::Error) -> anyhow::Error {
    match err {
        ureq::Error::RequireHttpsOnly(_) => anyhow!("Model downloads must use an https:// URL."),
        ureq::Error::Io(io) => anyhow::Error::new(io).context("Download failed"),
        other => AiError::ServerUnreachable(format!("the download server ({other})")).into(),
    }
}

/// Streaming SHA-256 as lowercase hex.
pub fn sha256_file(path: &Path, cancel: Option<&AtomicBool>) -> Result<String> {
    let mut file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    loop {
        if let Some(cancel) = cancel {
            crate::error::check_cancelled(cancel)?;
        }
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn sidecar_path(path: &Path) -> PathBuf {
    with_suffix(path, ".sha256")
}

pub fn read_sidecar(path: &Path) -> Option<String> {
    let text = fs::read_to_string(sidecar_path(path)).ok()?;
    let digest = text.trim().to_ascii_lowercase();
    (digest.len() == 64 && digest.chars().all(|c| c.is_ascii_hexdigit())).then_some(digest)
}

pub fn write_sidecar(path: &Path, digest: &str) -> Result<()> {
    lokalbot_core::library::write_atomic(
        &sidecar_path(path),
        digest.to_ascii_lowercase().as_bytes(),
    )
    .with_context(|| format!("recording the digest of {}", path.display()))
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(suffix);
    path.with_file_name(name)
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn is_gguf_name(path: &Path) -> bool {
    path.extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("gguf"))
}

fn gigabytes(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

/// Bytes available to this user on the volume holding `dir`.
pub fn free_space(dir: &Path) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt as _;
        let c_path = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
        let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        // SAFETY: `c_path` is a valid NUL-terminated path and `stat` is a
        // properly sized out-parameter that statvfs fully initializes on success.
        let rc = unsafe { libc::statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
        if rc != 0 {
            return None;
        }
        // SAFETY: statvfs returned 0, so the struct is initialized.
        let stat = unsafe { stat.assume_init() };
        // The field types vary across Unix targets.
        #[allow(clippy::useless_conversion)]
        let (available, block) = (u64::from(stat.f_bavail), u64::from(stat.f_frsize));
        Some(available.saturating_mul(block))
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt as _;
        let wide: Vec<u16> = dir
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut available = 0u64;
        // SAFETY: `wide` is NUL-terminated; the out-pointer is a valid u64 and
        // the other out-parameters are optional (null).
        let ok = unsafe {
            windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(
                wide.as_ptr(),
                &mut available,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        (ok != 0).then_some(available)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = dir;
        None
    }
}

// ---------------------------------------------------------------- archives

/// Extraction stops past this many bytes or entries (archive bombs).
const MAX_EXTRACTED_BYTES: u64 = 16 * 1024 * 1024 * 1024;
const MAX_ENTRIES: usize = 200_000;

/// Extracts a `.zip`, `.tar.gz`/`.tgz`, `.tar.bz2`/`.tbz2` or `.tar` into
/// `dest`. Entries that would land outside `dest` (absolute paths, `..`, links
/// pointing out) fail the whole extraction.
pub fn extract_archive(archive: &Path, dest: &Path) -> Result<()> {
    let name = file_name(archive).to_ascii_lowercase();
    fs::create_dir_all(dest).with_context(|| format!("creating {}", dest.display()))?;
    let file = File::open(archive).with_context(|| format!("opening {}", archive.display()))?;
    if name.ends_with(".zip") {
        extract_zip(file, dest)
    } else if name.ends_with(".tar.gz") || name.ends_with(".tgz") {
        extract_tar(flate2::read::GzDecoder::new(io::BufReader::new(file)), dest)
    } else if name.ends_with(".tar.bz2") || name.ends_with(".tbz2") || name.ends_with(".tbz") {
        extract_tar(bzip2::read::BzDecoder::new(io::BufReader::new(file)), dest)
    } else if name.ends_with(".tar") {
        extract_tar(io::BufReader::new(file), dest)
    } else {
        bail!("Unsupported archive format: {name}")
    }
}

/// A relative path made only of normal components, or `None`.
fn safe_relative(path: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => out.push(part),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    (!out.as_os_str().is_empty()).then_some(out)
}

/// Resolves a link target written relative to `entry`'s folder, lexically,
/// and returns it relative to the archive root when it stays inside.
fn link_inside(entry: &Path, target: &Path) -> Option<PathBuf> {
    if target.is_absolute() {
        return None;
    }
    let mut parts: Vec<std::ffi::OsString> = entry
        .parent()
        .map(|p| p.iter().map(|c| c.to_os_string()).collect())
        .unwrap_or_default();
    for component in target.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_os_string()),
            Component::CurDir => {}
            Component::ParentDir => {
                parts.pop()?;
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    let out: PathBuf = parts.iter().collect();
    (!out.as_os_str().is_empty()).then_some(out)
}

struct Budget {
    bytes: u64,
    entries: usize,
}

impl Budget {
    fn charge(&mut self, bytes: u64) -> Result<()> {
        self.entries += 1;
        self.bytes = self.bytes.saturating_add(bytes);
        if self.entries > MAX_ENTRIES || self.bytes > MAX_EXTRACTED_BYTES {
            bail!("The archive expands beyond the allowed size.");
        }
        Ok(())
    }
}

fn copy_limited(
    reader: &mut dyn Read,
    target: &Path,
    budget: &mut Budget,
    declared: u64,
) -> Result<()> {
    budget.charge(declared)?;
    let mut out = File::create(target).with_context(|| format!("creating {}", target.display()))?;
    let copied = io::copy(&mut reader.take(declared.saturating_add(1)), &mut out)?;
    if copied > declared {
        bail!("An archive entry is larger than it declares.");
    }
    Ok(())
}

fn extract_tar<R: Read>(reader: R, dest: &Path) -> Result<()> {
    let mut archive = tar::Archive::new(reader);
    let mut budget = Budget {
        bytes: 0,
        entries: 0,
    };
    // Hard links and (on Windows) symlinks become copies once their target exists.
    let mut deferred_copies: Vec<(PathBuf, PathBuf)> = Vec::new();
    for entry in archive.entries()? {
        let mut entry = entry?;
        let raw = entry.path()?.into_owned();
        let Some(relative) = safe_relative(&raw) else {
            bail!("The archive contains an unsafe path: {}", raw.display());
        };
        let target = dest.join(&relative);
        let kind = entry.header().entry_type();
        if kind.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        if kind.is_symlink() || kind.is_hard_link() {
            let link = entry
                .link_name()?
                .ok_or_else(|| anyhow!("a link in the archive has no target"))?
                .into_owned();
            let inside = if kind.is_hard_link() {
                safe_relative(&link)
            } else {
                link_inside(&relative, &link)
            };
            let Some(inside) = inside else {
                bail!(
                    "The archive contains a link that points outside it: {}",
                    raw.display()
                );
            };
            budget.charge(0)?;
            #[cfg(unix)]
            if kind.is_symlink() {
                let _ = fs::remove_file(&target);
                std::os::unix::fs::symlink(&link, &target)
                    .with_context(|| format!("linking {}", target.display()))?;
                continue;
            }
            deferred_copies.push((dest.join(inside), target));
            continue;
        }
        if !(kind.is_file()
            || kind == tar::EntryType::Continuous
            || kind == tar::EntryType::GNUSparse)
        {
            continue;
        }
        let size = entry.header().size()?;
        let mode = entry.header().mode().ok();
        let _ = fs::remove_file(&target);
        copy_limited(&mut entry, &target, &mut budget, size)?;
        #[cfg(unix)]
        if let Some(mode) = mode {
            use std::os::unix::fs::PermissionsExt as _;
            fs::set_permissions(&target, fs::Permissions::from_mode(mode & 0o777))?;
        }
        #[cfg(not(unix))]
        let _ = mode;
    }
    for (source, target) in deferred_copies {
        if source.is_file() {
            fs::copy(&source, &target).with_context(|| format!("copying {}", target.display()))?;
        }
    }
    Ok(())
}

fn extract_zip(file: File, dest: &Path) -> Result<()> {
    let mut archive =
        zip::ZipArchive::new(io::BufReader::new(file)).context("reading the zip archive")?;
    let mut budget = Budget {
        bytes: 0,
        entries: 0,
    };
    for index in 0..archive.len() {
        let mut entry = archive.by_index(index)?;
        let name = entry.name().map(|n| n.into_owned()).unwrap_or_default();
        let Some(relative) = entry.enclosed_name().and_then(|p| safe_relative(&p)) else {
            bail!("The archive contains an unsafe path: {name}");
        };
        let target = dest.join(&relative);
        if entry.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        if entry.is_symlink() {
            let mut link = String::new();
            entry.read_to_string(&mut link)?;
            if link_inside(&relative, Path::new(&link)).is_none() {
                bail!("The archive contains a link that points outside it: {name}");
            }
            budget.charge(0)?;
            #[cfg(unix)]
            {
                let _ = fs::remove_file(&target);
                std::os::unix::fs::symlink(&link, &target)?;
            }
            continue;
        }
        let size = entry.size();
        let mode = entry.unix_mode();
        copy_limited(&mut entry, &target, &mut budget, size)?;
        #[cfg(unix)]
        if let Some(mode) = mode {
            use std::os::unix::fs::PermissionsExt as _;
            fs::set_permissions(&target, fs::Permissions::from_mode(mode & 0o777))?;
        }
        #[cfg(not(unix))]
        let _ = mode;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::testing::{StubResponse, StubServer};

    fn options() -> Options {
        Options {
            minimum_ranged_bytes: 1000,
            part_bytes: 300,
            max_concurrent_parts: 3,
            allow_loopback_http: true,
        }
    }

    fn payload(len: usize) -> Vec<u8> {
        let mut bytes = b"GGUF".to_vec();
        bytes.extend((0..len - 4).map(|i| (i * 31 % 251) as u8));
        bytes
    }

    fn spec(server: &StubServer, path: &str, bytes: &[u8], dest: PathBuf) -> DownloadSpec {
        DownloadSpec {
            url: server.url(path),
            sha256: hex::encode(Sha256::digest(bytes)),
            size: bytes.len() as u64,
            dest,
        }
    }

    #[test]
    fn refuses_unsafe_sources() {
        let sha = "a".repeat(64);
        assert!(
            source_refusal("http://example.com/x.gguf", &sha, false)
                .unwrap()
                .contains("https://")
        );
        assert!(source_refusal("http://127.0.0.1:9/x.gguf", &sha, false).is_some());
        assert_eq!(
            source_refusal("http://127.0.0.1:9/x.gguf", &sha, true),
            None
        );
        assert_eq!(
            source_refusal(
                "https://huggingface.co/a/b/resolve/main/x.gguf",
                &sha,
                false
            )
            .as_deref(),
            Some(UNPINNED_HUGGING_FACE_MESSAGE)
        );
        let pinned = format!(
            "https://huggingface.co/a/b/resolve/{}/x.gguf",
            "0".repeat(40)
        );
        assert_eq!(source_refusal(&pinned, &sha, false), None);
        assert!(source_refusal(&pinned, "abc", false).is_some());
    }

    #[test]
    fn ranges_cover_the_file_exactly() {
        let parts = ranges(1000, 300);
        assert_eq!(parts.len(), 4);
        assert_eq!(
            parts[3],
            ByteRange {
                index: 3,
                start: 900,
                end: 999
            }
        );
        assert_eq!(parts.iter().map(ByteRange::len).sum::<u64>(), 1000);
        assert!(ranges(0, 300).is_empty());
    }

    #[test]
    fn parallel_ranged_download_verifies_and_installs() {
        let bytes = payload(2_000);
        let server = StubServer::start(StubResponse::file_route("/model.gguf", bytes.clone()));
        let dir = tempfile::tempdir().unwrap();
        let spec = spec(
            &server,
            "/model.gguf",
            &bytes,
            dir.path().join("models/model.gguf"),
        );
        let mut last = (0, 0);
        download_with(
            &spec,
            &AtomicBool::new(false),
            &mut |d, t| last = (d, t),
            &options(),
        )
        .unwrap();
        assert_eq!(fs::read(&spec.dest).unwrap(), bytes);
        assert_eq!(read_sidecar(&spec.dest).unwrap(), spec.sha256);
        assert_eq!(last, (2_000, 2_000));
        assert!(
            server
                .requests()
                .iter()
                .filter(|r| r.header("range").is_some())
                .count()
                >= 7
        );
        // Installed and verified: nothing is fetched again.
        let before = server.requests().len();
        download_with(&spec, &AtomicBool::new(false), &mut |_, _| {}, &options()).unwrap();
        assert_eq!(server.requests().len(), before);
    }

    #[test]
    fn small_files_stream_in_one_request_and_resume() {
        let bytes = payload(500);
        let server = StubServer::start(StubResponse::file_route("/small.gguf", bytes.clone()));
        let dir = tempfile::tempdir().unwrap();
        let spec = spec(
            &server,
            "/small.gguf",
            &bytes,
            dir.path().join("small.gguf"),
        );
        fs::write(with_suffix(&spec.dest, ".part"), &bytes[..120]).unwrap();
        download_with(&spec, &AtomicBool::new(false), &mut |_, _| {}, &options()).unwrap();
        assert_eq!(fs::read(&spec.dest).unwrap(), bytes);
        let gets: Vec<_> = server
            .requests()
            .into_iter()
            .filter(|r| r.method == "GET")
            .collect();
        assert_eq!(gets.len(), 1);
        assert_eq!(gets[0].header("range").as_deref(), Some("bytes=120-"));
    }

    /// An HTTP/1.0 server, like the `python -m http.server` that serves the
    /// update checks' dry-run feed, answers one request per connection and
    /// then closes it. A request sent down that connection again gets no
    /// answer, so the GET must not reuse the connection of the HEAD probe.
    #[test]
    fn requests_do_not_reuse_a_connection_an_http_1_0_server_closes() {
        use std::io::{BufRead as _, BufReader};
        use std::net::TcpListener;

        let bytes = payload(500);
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let file = std::sync::Arc::new(bytes.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let file = file.clone();
                std::thread::spawn(move || {
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut request = String::new();
                    loop {
                        let mut line = String::new();
                        if reader.read_line(&mut line).unwrap_or(0) == 0 {
                            return;
                        }
                        if line == "\r\n" {
                            break;
                        }
                        request.push_str(&line);
                    }
                    let mut out = stream;
                    let _ = write!(
                        out,
                        "HTTP/1.0 200 OK\r\nContent-Length: {}\r\n\r\n",
                        file.len()
                    );
                    if request.starts_with("GET ") {
                        let _ = out.write_all(&file);
                    }
                    let _ = out.flush();
                    // Close only once the client has sent more on this
                    // connection (or after a while), so the outcome does not
                    // depend on timing.
                    let _ = reader
                        .get_ref()
                        .set_read_timeout(Some(Duration::from_secs(2)));
                    let _ = reader.read(&mut [0u8; 1]);
                });
            }
        });
        let dir = tempfile::tempdir().unwrap();
        let spec = DownloadSpec {
            url: format!("http://127.0.0.1:{port}/update.zip"),
            sha256: hex::encode(Sha256::digest(&bytes)),
            size: bytes.len() as u64,
            dest: dir.path().join("update.zip"),
        };
        download_with(&spec, &AtomicBool::new(false), &mut |_, _| {}, &options()).unwrap();
        assert_eq!(fs::read(&spec.dest).unwrap(), bytes);
    }

    #[test]
    fn digest_mismatch_is_rejected_and_cleaned_up() {
        let bytes = payload(500);
        let server = StubServer::start(StubResponse::file_route("/bad.gguf", bytes.clone()));
        let dir = tempfile::tempdir().unwrap();
        let mut spec = spec(&server, "/bad.gguf", &bytes, dir.path().join("bad.gguf"));
        spec.sha256 = "0".repeat(64);
        let err =
            download_with(&spec, &AtomicBool::new(false), &mut |_, _| {}, &options()).unwrap_err();
        assert!(err.to_string().contains("SHA-256"), "{err}");
        assert!(!spec.dest.exists());
        assert!(!with_suffix(&spec.dest, ".part").exists());
    }

    #[test]
    fn size_mismatch_and_non_gguf_are_rejected() {
        let bytes = b"NOPE-not-a-model".to_vec();
        let server = StubServer::start(StubResponse::file_route("/x.gguf", bytes.clone()));
        let dir = tempfile::tempdir().unwrap();
        let spec1 = spec(&server, "/x.gguf", &bytes, dir.path().join("x.gguf"));
        let err =
            download_with(&spec1, &AtomicBool::new(false), &mut |_, _| {}, &options()).unwrap_err();
        assert!(err.to_string().contains("not a GGUF"), "{err}");
        let mut spec2 = spec1.clone();
        spec2.size += 5;
        let err =
            download_with(&spec2, &AtomicBool::new(false), &mut |_, _| {}, &options()).unwrap_err();
        assert!(err.to_string().contains("bytes"), "{err}");
    }

    #[test]
    fn cancelled_download_keeps_its_resume_state() {
        let bytes = payload(2_000);
        let server = StubServer::start(StubResponse::file_route("/c.gguf", bytes.clone()));
        let dir = tempfile::tempdir().unwrap();
        let spec = spec(&server, "/c.gguf", &bytes, dir.path().join("c.gguf"));
        let cancel = AtomicBool::new(true);
        let err = download_with(&spec, &cancel, &mut |_, _| {}, &options()).unwrap_err();
        assert!(matches!(
            err.downcast_ref::<AiError>(),
            Some(AiError::Cancelled)
        ));
        assert!(!spec.dest.exists());
    }

    fn tar_gz(entries: &[(&str, &[u8])], links: &[(&str, &str)]) -> Vec<u8> {
        let mut builder = tar::Builder::new(flate2::write::GzEncoder::new(
            Vec::new(),
            flate2::Compression::fast(),
        ));
        for (path, data) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o755);
            header.set_cksum();
            builder.append_data(&mut header, path, *data).unwrap();
        }
        for (path, target) in links {
            let mut header = tar::Header::new_gnu();
            header.set_entry_type(tar::EntryType::Symlink);
            header.set_size(0);
            builder.append_link(&mut header, path, target).unwrap();
        }
        builder.into_inner().unwrap().finish().unwrap()
    }

    #[test]
    fn extracts_tar_gz_with_inside_links() {
        let dir = tempfile::tempdir().unwrap();
        let archive = dir.path().join("rt.tar.gz");
        fs::write(
            &archive,
            tar_gz(
                &[
                    ("build/bin/llama-server", b"bin"),
                    ("build/bin/libllama.so.0", b"lib"),
                ],
                &[("build/bin/libllama.so", "libllama.so.0")],
            ),
        )
        .unwrap();
        let out = dir.path().join("out");
        extract_archive(&archive, &out).unwrap();
        assert_eq!(
            fs::read(out.join("build/bin/llama-server")).unwrap(),
            b"bin"
        );
        assert_eq!(fs::read(out.join("build/bin/libllama.so")).unwrap(), b"lib");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            assert_eq!(
                fs::metadata(out.join("build/bin/llama-server"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o111,
                0o111
            );
        }
    }

    #[test]
    fn rejects_traversal_in_tar_links() {
        let dir = tempfile::tempdir().unwrap();
        let archive = dir.path().join("evil.tar.gz");
        fs::write(
            &archive,
            tar_gz(&[("ok.txt", b"x")], &[("link", "../../etc/passwd")]),
        )
        .unwrap();
        let err = extract_archive(&archive, &dir.path().join("out")).unwrap_err();
        assert!(err.to_string().contains("outside"), "{err}");
    }

    #[test]
    fn extracts_zip_and_rejects_traversal() {
        let dir = tempfile::tempdir().unwrap();
        let archive = dir.path().join("rt.zip");
        {
            let mut zip = zip::ZipWriter::new(File::create(&archive).unwrap());
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            zip.start_file("llama-server.exe", options).unwrap();
            zip.write_all(b"exe").unwrap();
            zip.start_file("ggml/ggml.dll", options).unwrap();
            zip.write_all(b"dll").unwrap();
            zip.finish().unwrap();
        }
        let out = dir.path().join("out");
        extract_archive(&archive, &out).unwrap();
        assert_eq!(fs::read(out.join("llama-server.exe")).unwrap(), b"exe");
        assert_eq!(fs::read(out.join("ggml/ggml.dll")).unwrap(), b"dll");

        let evil = dir.path().join("evil.zip");
        {
            let mut zip = zip::ZipWriter::new(File::create(&evil).unwrap());
            zip.start_file("../escape.txt", zip::write::SimpleFileOptions::default())
                .unwrap();
            zip.write_all(b"x").unwrap();
            zip.finish().unwrap();
        }
        assert!(extract_archive(&evil, &dir.path().join("out2")).is_err());
        assert!(!dir.path().join("escape.txt").exists());
    }

    #[test]
    fn link_resolution_stays_lexical() {
        assert_eq!(
            link_inside(Path::new("a/b/link"), Path::new("../c")),
            Some(PathBuf::from("a/c"))
        );
        assert_eq!(link_inside(Path::new("a/link"), Path::new("../../x")), None);
        assert_eq!(
            link_inside(Path::new("link"), Path::new("/etc/passwd")),
            None
        );
        assert_eq!(safe_relative(Path::new("./a/../b")), None);
        assert_eq!(
            safe_relative(Path::new("./a/b")),
            Some(PathBuf::from("a/b"))
        );
    }
}
