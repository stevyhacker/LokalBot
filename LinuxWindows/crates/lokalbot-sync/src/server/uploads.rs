//! Recordings arriving from paired devices (protocol.md, Flow for
//! `purpose: "upload"`). A partial file's length is how far it got, so a
//! dropped connection resumes where it stopped; nothing else about an upload
//! is kept until it is whole.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::store::DeviceRow;
use super::{ServerInner, UploadOutcome};
use crate::records::now_iso;

pub(super) const DIRECTORY: &str = "uploads";
pub(super) const NOT_BEGUN: &str = "This computer lost its place in the recording.";

/// Far more than a day of the apps' 64 kbit/s audio.
const MAX_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// Base64 of a chunk may not decode to more than this.
const MAX_CHUNK_BYTES: usize = 1024 * 1024;
/// A partial file nobody came back for.
const STALE_AFTER: Duration = Duration::from_secs(14 * 24 * 60 * 60);
/// How often a running host looks for those.
pub(super) const SWEEP_EVERY: Duration = Duration::from_secs(60 * 60);
/// Recordings arriving or being imported at once, which keeps one device from
/// stacking up imports by reconnecting. Nobody has this many devices recording.
const MAX_ACTIVE: usize = 8;
/// Unfinished files one device may hold here.
const MAX_PARTIALS_PER_DEVICE: usize = 16;

impl UploadOutcome {
    pub(crate) fn accepted(meeting_id: Option<String>) -> Self {
        Self {
            status: "accepted".into(),
            meeting_id,
            message: None,
        }
    }

    pub(crate) fn deferred(message: impl Into<String>) -> Self {
        Self {
            status: "deferred".into(),
            meeting_id: None,
            message: Some(message.into()),
        }
    }

    pub(crate) fn rejected(message: impl Into<String>) -> Self {
        Self {
            status: "rejected".into(),
            meeting_id: None,
            message: Some(message.into()),
        }
    }
}

/// The folder of one device's partial files. Device ids come from the device,
/// so its name is a hash of the id.
fn device_directory(root: &Path, device_id: &str) -> PathBuf {
    let hash = Sha256::digest(device_id.as_bytes());
    root.join(hex::encode(&hash[..8]))
}

pub(super) fn forget_device(root: &Path, device_id: &str) {
    let _ = fs::remove_dir_all(device_directory(root, device_id));
}

/// Removes partial files older than [`STALE_AFTER`].
pub(super) fn remove_stale(root: &Path) {
    let Ok(devices) = fs::read_dir(root) else {
        return;
    };
    let now = SystemTime::now();
    for device in devices.flatten() {
        let Ok(files) = fs::read_dir(device.path()) else {
            continue;
        };
        for file in files.flatten() {
            let age = file
                .metadata()
                .and_then(|m| m.modified())
                .ok()
                .and_then(|modified| now.duration_since(modified).ok());
            if age.is_some_and(|age| age >= STALE_AFTER) {
                let _ = fs::remove_file(file.path());
            }
        }
        // Fails while the folder still holds something, which is fine.
        let _ = fs::remove_dir(device.path());
    }
}

/// Holds an upload id for one session or import, so a phone that reconnected
/// can't write to the same file at once. Dropping it lets go.
pub(super) struct Claim {
    inner: Arc<ServerInner>,
    id: String,
}

impl Drop for Claim {
    fn drop(&mut self) {
        self.inner.active_uploads.lock().remove(&self.id);
    }
}

/// A recording being received.
pub(super) struct Incoming {
    id: String,
    byte_count: u64,
    sha256: String,
    recording: Value,
    path: PathBuf,
    file: File,
    offset: u64,
    _claim: Claim,
}

pub(super) enum Begin {
    /// Nothing to send: the outcome is already known.
    Done(UploadOutcome),
    Ready(Incoming),
}

pub(super) enum Append {
    Written(u64),
    /// The chunk wasn't for this position; the phone should seek here.
    Elsewhere(u64),
    Failed(UploadOutcome),
}

fn canonical_id(id: &str) -> Option<String> {
    uuid::Uuid::parse_str(id).ok().map(|id| id.to_string())
}

fn is_sha256(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|b| b.is_ascii_hexdigit())
}

pub(super) fn begin(
    inner: &Arc<ServerInner>,
    device_id: &str,
    upload_id: &str,
    byte_count: u64,
    sha256: &str,
    recording: Value,
) -> Begin {
    // The id names a file and becomes the meeting's id: only a UUID will do.
    let Some(id) = canonical_id(upload_id) else {
        return Begin::Done(UploadOutcome::rejected("The recording has no valid id."));
    };
    if !is_sha256(sha256) || byte_count == 0 || !recording.is_object() {
        return Begin::Done(UploadOutcome::rejected(
            "The recording's description can't be read.",
        ));
    }
    if byte_count > MAX_BYTES {
        return Begin::Done(UploadOutcome::rejected(
            "This recording is too large to send.",
        ));
    }
    match inner.store.lock().received_upload(&id) {
        Ok(Some(meeting_id)) => return Begin::Done(UploadOutcome::accepted(meeting_id)),
        Ok(None) => {}
        Err(error) => {
            log::warn!("companion upload: reading the received list failed: {error}");
            return Begin::Done(UploadOutcome::deferred(
                "This computer couldn't check the recording. It will try again.",
            ));
        }
    }
    if !inner.delegate.accepts_recordings() {
        return Begin::Done(UploadOutcome::deferred(
            "This computer isn't accepting recordings. Turn on \"Accept recordings from my devices\" in its settings.",
        ));
    }
    {
        let mut active = inner.active_uploads.lock();
        if active.contains(&id) {
            return Begin::Done(UploadOutcome::deferred(
                "This computer is already receiving this recording.",
            ));
        }
        if active.len() >= MAX_ACTIVE {
            return Begin::Done(UploadOutcome::deferred(
                "This computer is busy with other recordings. It will try again.",
            ));
        }
        active.insert(id.clone());
    }
    let claim = Claim {
        inner: Arc::clone(inner),
        id: id.clone(),
    };
    let sha256 = sha256.to_ascii_lowercase();
    match open_partial(&inner.uploads_dir, device_id, &id, &sha256, byte_count) {
        Ok((path, file, offset)) => Begin::Ready(Incoming {
            id,
            byte_count,
            sha256,
            recording,
            path,
            file,
            offset,
            _claim: claim,
        }),
        Err(error) => {
            log::warn!("companion upload: opening the partial file failed: {error}");
            Begin::Done(UploadOutcome::deferred(format!(
                "This computer couldn't save the recording: {error}"
            )))
        }
    }
}

/// The partial file, named so AVFoundation and Symphonia can tell its type,
/// and how much of it is already here. The checksum is in the name, so bytes
/// of a different file can never continue this one.
fn open_partial(
    root: &Path,
    device_id: &str,
    id: &str,
    sha256: &str,
    byte_count: u64,
) -> io::Result<(PathBuf, File, u64)> {
    let directory = device_directory(root, device_id);
    fs::create_dir_all(&directory)?;
    let path = directory.join(format!("{id}-{}.aac", &sha256[..16]));
    if !path.exists() && fs::read_dir(&directory)?.count() >= MAX_PARTIALS_PER_DEVICE {
        return Err(io::Error::other(
            "it holds too many unfinished recordings from this device",
        ));
    }
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .append(true)
        .open(&path)?;
    let mut offset = file.metadata()?.len();
    if offset > byte_count {
        file.set_len(0)?;
        offset = 0;
    }
    Ok((path, file, offset))
}

impl Incoming {
    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn offset(&self) -> u64 {
        self.offset
    }

    pub fn matches(&self, upload_id: &str) -> bool {
        canonical_id(upload_id).as_deref() == Some(self.id.as_str())
    }

    pub fn is_whole(&self) -> bool {
        self.offset == self.byte_count
    }

    pub fn append(&mut self, offset: u64, data: &str) -> Append {
        if offset != self.offset {
            return Append::Elsewhere(self.offset);
        }
        let Ok(bytes) = STANDARD.decode(data) else {
            return Append::Failed(UploadOutcome::deferred(
                "Part of the recording was unreadable.",
            ));
        };
        if bytes.is_empty()
            || bytes.len() > MAX_CHUNK_BYTES
            || self.offset + bytes.len() as u64 > self.byte_count
        {
            return Append::Failed(UploadOutcome::deferred(
                "Part of the recording had the wrong size.",
            ));
        }
        if let Err(error) = self.file.write_all(&bytes) {
            log::warn!("companion upload: writing failed: {error}");
            // A partial write leaves the file's length as the true position.
            return Append::Failed(UploadOutcome::deferred(format!(
                "This computer couldn't save the recording: {error}"
            )));
        }
        self.offset += bytes.len() as u64;
        Append::Written(self.offset)
    }
}

fn file_sha256(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            return Ok(hex::encode(hasher.finalize()));
        }
        hasher.update(&buffer[..read]);
    }
}

/// Checks the finished file, hands it to the Mac and records the outcome.
pub(super) fn complete(
    inner: &Arc<ServerInner>,
    incoming: Incoming,
    device: &DeviceRow,
) -> UploadOutcome {
    let path = incoming.path.clone();
    let synced = incoming.file.sync_all();
    let matches = synced
        .and_then(|()| file_sha256(&path))
        .map(|sha256| sha256 == incoming.sha256);
    match matches {
        Ok(true) => {}
        Ok(false) => {
            // Damaged somewhere along the way: the next attempt starts over.
            let _ = fs::remove_file(&path);
            return UploadOutcome::deferred(
                "The recording arrived damaged. It will be sent again.",
            );
        }
        Err(error) => {
            log::warn!("companion upload: checking the file failed: {error}");
            return UploadOutcome::deferred(format!(
                "This computer couldn't read the recording: {error}"
            ));
        }
    }
    let mut recording = incoming.recording.clone();
    recording["id"] = Value::String(incoming.id.clone());
    recording["byteCount"] = Value::from(incoming.byte_count);
    recording["deviceId"] = Value::String(device.device_id.clone());
    recording["deviceName"] = Value::String(device.name.clone());
    recording["platform"] = Value::String(device.platform.clone());
    let outcome = inner
        .delegate
        .receive_recording(recording.to_string(), path.to_string_lossy().into_owned());
    match outcome.status.as_str() {
        "accepted" => {
            let recorded = inner.store.lock().record_received_upload(
                &incoming.id,
                &device.device_id,
                outcome.meeting_id.as_deref(),
                &now_iso(),
            );
            if let Err(error) = recorded {
                // The Mac's import is idempotent by id, so a resend is safe.
                log::warn!("companion upload: recording the arrival failed: {error}");
            }
            let _ = fs::remove_file(&path);
            outcome
        }
        "rejected" => {
            let _ = fs::remove_file(&path);
            outcome
        }
        // Whole and checked: the next attempt needs no audio sent again.
        "deferred" => outcome,
        other => {
            log::warn!("companion upload: unknown outcome \"{other}\"");
            UploadOutcome::deferred("This computer couldn't take the recording.")
        }
    }
}
