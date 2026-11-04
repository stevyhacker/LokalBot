//! Recordings made on the phone, on their way to the Mac (protocol.md, Flow
//! for `purpose: "upload"`). The platform's recorder writes an ADTS AAC file
//! here, which is readable however it ends, so a crash or a dead battery
//! loses only the last moments. The file goes once the Mac confirms it has it.

use std::fs::{self, File};
use std::io::{Read as _, Seek as _, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use super::SyncClient;
use super::store::{RECORDING_ACTIVE, RECORDING_FAILED, RECORDING_WAITING, RecordingRow};
use crate::error::{Result, SyncError};
use crate::messages::Message;
use crate::records::now_iso;
use crate::wire::{Channel, Inbox, Tuning};

pub(super) const DIRECTORY: &str = "recordings";

/// What `format` says in an upload. Only this exists so far.
const FORMAT: &str = "aac-adts";
/// How long a recording that reached the Mac stays listed when its meeting
/// never comes back, as when the Mac doesn't share meetings.
const UPLOADED_LISTED_FOR: Duration = Duration::from_secs(7 * 24 * 60 * 60);

/// A recording this device holds or just sent.
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct RecordingInfo {
    /// A UUID; the meeting it becomes on the Mac has the same id.
    pub id: String,
    /// Empty until the person names it; the Mac then picks one.
    pub title: String,
    /// `recording`, `waiting`, `failed` or `uploaded`.
    pub state: String,
    /// ISO 8601 UTC.
    pub started_at: String,
    pub duration_seconds: Option<f64>,
    pub byte_count: u64,
    pub sent_bytes: u64,
    /// Why it hasn't reached the Mac, or what went wrong.
    pub message: Option<String>,
    /// Where the recorder writes. Gone once the Mac has it.
    pub file_path: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct UploadReport {
    /// Recordings the Mac confirmed during this pass.
    pub uploaded: u32,
    /// Recordings still to go, whatever kept them.
    pub waiting: u32,
    /// Recordings the Mac refused; they stay until retried or discarded.
    pub failed: u32,
}

/// Hears how far an upload got.
#[uniffi::export(callback_interface)]
pub trait UploadListener: Send + Sync {
    fn on_progress(&self, recording_id: String, sent_bytes: u64, total_bytes: u64);
}

fn recording_path(directory: &Path, id: &str) -> PathBuf {
    directory.join(format!("{id}.aac"))
}

pub(super) fn delete_all_files(directory: &Path) {
    let _ = fs::remove_dir_all(directory);
}

fn file_sha256(path: &Path) -> std::io::Result<String> {
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

/// The description the Mac gets with the audio.
fn description(row: &RecordingRow) -> Value {
    let mut recording = Map::new();
    recording.insert("format".into(), FORMAT.into());
    recording.insert("startedAt".into(), row.started_at.clone().into());
    if !row.title.trim().is_empty() {
        recording.insert("title".into(), row.title.trim().into());
    }
    if let Some(duration) = row.duration_seconds {
        recording.insert("durationSeconds".into(), duration.into());
    }
    Value::Object(recording)
}

/// How one recording's trip ended.
enum Trip {
    Uploaded,
    /// The Mac can't take it now; `message` says why.
    Deferred(Option<String>),
    Refused(Option<String>),
    /// This device no longer has the audio.
    Missing,
    /// The person deleted it on the way, so the rest stays here.
    Withdrawn,
}

#[uniffi::export]
impl SyncClient {
    /// Starts a recording: returns where the recorder writes. It needs a
    /// paired Mac, because that is the only place it can go.
    pub fn begin_recording(&self, title: Option<String>) -> Result<RecordingInfo> {
        let store = self.store.lock();
        if store.pairing()?.is_none() {
            return Err(SyncError::not_paired());
        }
        fs::create_dir_all(&self.recordings_dir)?;
        let id = uuid::Uuid::new_v4().to_string();
        store.insert_recording(&id, title.unwrap_or_default().trim(), &now_iso())?;
        let row = store
            .recording(&id)?
            .ok_or_else(|| SyncError::Storage("The recording wasn't saved.".into()))?;
        Ok(self.info(row))
    }

    /// The recorder stopped: the recording can go to the Mac. A file with
    /// nothing in it leaves no recording and fails with `InvalidInput`.
    pub fn finish_recording(&self, id: String, duration_seconds: f64) -> Result<RecordingInfo> {
        let store = self.store.lock();
        let Some(row) = store.recording(&id)? else {
            return Err(SyncError::invalid("There is no such recording."));
        };
        let path = recording_path(&self.recordings_dir, &id);
        let byte_count = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        if byte_count == 0 {
            store.delete_recording(&id)?;
            let _ = fs::remove_file(&path);
            return Err(SyncError::invalid("Nothing was recorded."));
        }
        if row.state == RECORDING_ACTIVE {
            let duration = (duration_seconds.is_finite() && duration_seconds > 0.0)
                .then_some(duration_seconds);
            store.finish_recording(&id, duration, byte_count)?;
        }
        let row = store
            .recording(&id)?
            .ok_or_else(|| SyncError::Storage("The recording wasn't saved.".into()))?;
        Ok(self.info(row))
    }

    /// Recordings left `recording` by an app that stopped without finishing
    /// them: the file holds everything up to then, so they go to the Mac like
    /// any other. Call at launch, never while a recorder runs. Returns how
    /// many were kept.
    pub fn recover_recordings(&self) -> Result<u32> {
        let store = self.store.lock();
        let mut kept = 0;
        for row in store.recordings_active()? {
            let path = recording_path(&self.recordings_dir, &row.id);
            let byte_count = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            if byte_count == 0 {
                store.delete_recording(&row.id)?;
                let _ = fs::remove_file(&path);
            } else {
                store.finish_recording(&row.id, None, byte_count)?;
                kept += 1;
            }
        }
        Ok(kept)
    }

    /// Deletes a recording and its file, whatever its state.
    pub fn discard_recording(&self, id: String) -> Result<()> {
        self.store.lock().delete_recording(&id)?;
        let _ = fs::remove_file(recording_path(&self.recordings_dir, &id));
        Ok(())
    }

    /// Empty leaves the name to the Mac.
    pub fn set_recording_title(&self, id: String, title: String) -> Result<()> {
        self.store.lock().set_recording_title(&id, title.trim())
    }

    /// A recording the Mac refused goes round again.
    pub fn retry_recording(&self, id: String) -> Result<()> {
        self.store.lock().retry_recording(&id)
    }

    /// Recordings on this device or just sent, newest first. One that reached
    /// the Mac stays listed until its meeting arrives here.
    pub fn recordings(&self) -> Result<Vec<RecordingInfo>> {
        let cutoff = Utc::now()
            - chrono::Duration::from_std(UPLOADED_LISTED_FOR).unwrap_or(chrono::Duration::zero());
        let rows = self
            .store
            .lock()
            .recordings(&crate::records::iso_from_unix(cutoff.timestamp()))?;
        Ok(rows.into_iter().map(|row| self.info(row)).collect())
    }

    /// Sends every waiting recording, oldest first, picking up where an
    /// earlier attempt stopped. Blocks for as long as that takes and returns
    /// at once when another pass is running or nothing waits. Whatever
    /// doesn't get through stays waiting; a dropped connection fails with
    /// `Io`, an absent Mac with `Unreachable`. Call `sync` afterwards to fetch
    /// the new meetings.
    pub fn upload_recordings(
        &self,
        extra_addresses: Vec<String>,
        listener: Box<dyn UploadListener>,
    ) -> Result<UploadReport> {
        let Some(_upload) = self.upload_lock.try_lock() else {
            return self.upload_report(0);
        };
        let (waiting, pairing) = {
            let store = self.store.lock();
            (store.recordings_waiting()?, store.pairing()?)
        };
        if waiting.is_empty() {
            return self.upload_report(0);
        }
        let pairing = pairing.ok_or_else(SyncError::not_paired)?;
        let tuning = self.tuning();
        let (channel, mut inbox, _) = self.connect(&pairing, &extra_addresses, &tuning)?;
        let result = self.run_uploads(&channel, &mut inbox, &tuning, &waiting, &*listener);
        if result.is_ok() {
            let _ = channel.send(&Message::Bye);
        }
        channel.close();
        let uploaded = self.finish(result)?;
        self.upload_report(uploaded)
    }
}

impl SyncClient {
    fn info(&self, row: RecordingRow) -> RecordingInfo {
        RecordingInfo {
            file_path: recording_path(&self.recordings_dir, &row.id)
                .to_string_lossy()
                .into_owned(),
            id: row.id,
            title: row.title,
            state: row.state,
            started_at: row.started_at,
            duration_seconds: row.duration_seconds,
            byte_count: row.byte_count,
            sent_bytes: row.sent_bytes,
            message: row.message,
        }
    }

    fn is_waiting(&self, id: &str) -> Result<bool> {
        let row = self.store.lock().recording(id)?;
        Ok(row.is_some_and(|row| row.state == RECORDING_WAITING))
    }

    fn upload_report(&self, uploaded: u32) -> Result<UploadReport> {
        let rows = self.recordings()?;
        let count = |state: &str| rows.iter().filter(|row| row.state == state).count() as u32;
        Ok(UploadReport {
            uploaded,
            waiting: count(RECORDING_WAITING),
            failed: count(RECORDING_FAILED),
        })
    }

    fn run_uploads(
        &self,
        channel: &Channel,
        inbox: &mut Inbox,
        tuning: &Tuning,
        waiting: &[RecordingRow],
        listener: &dyn UploadListener,
    ) -> Result<u32> {
        // A Mac from before uploads says `welcome`, then refuses the purpose.
        let result = self
            .hello(channel, inbox, tuning, 0, "upload")
            .and_then(|_| self.upload_each(channel, inbox, tuning, waiting, listener));
        if matches!(&result, Err(SyncError::Protocol(m)) if m.starts_with("unsupported_purpose")) {
            let message = "Update LokalBot on your computer to send it recordings.";
            let store = self.store.lock();
            for row in waiting {
                store.set_recording_message(&row.id, Some(message))?;
            }
            return Err(SyncError::protocol(message));
        }
        result
    }

    fn upload_each(
        &self,
        channel: &Channel,
        inbox: &mut Inbox,
        tuning: &Tuning,
        waiting: &[RecordingRow],
        listener: &dyn UploadListener,
    ) -> Result<u32> {
        let mut uploaded = 0;
        for row in waiting {
            // A title set since this pass began goes along.
            let row = self.store.lock().recording(&row.id)?;
            let Some(row) = row.filter(|row| row.state == RECORDING_WAITING) else {
                continue;
            };
            let trip = self.upload_one(channel, inbox, tuning, &row, listener)?;
            let store = self.store.lock();
            match trip {
                Trip::Uploaded => {
                    store.mark_recording_uploaded(&row.id, &now_iso())?;
                    drop(store);
                    let _ = fs::remove_file(recording_path(&self.recordings_dir, &row.id));
                    uploaded += 1;
                }
                Trip::Deferred(message) => {
                    store.set_recording_message(&row.id, message.as_deref())?;
                }
                Trip::Refused(message) => store.fail_recording(&row.id, message.as_deref())?,
                Trip::Missing => store.fail_recording(
                    &row.id,
                    Some("This recording's audio is no longer on this device."),
                )?,
                Trip::Withdrawn => {}
            }
        }
        Ok(uploaded)
    }

    fn upload_one(
        &self,
        channel: &Channel,
        inbox: &mut Inbox,
        tuning: &Tuning,
        row: &RecordingRow,
        listener: &dyn UploadListener,
    ) -> Result<Trip> {
        let path = recording_path(&self.recordings_dir, &row.id);
        let Ok(mut file) = File::open(&path) else {
            return Ok(Trip::Missing);
        };
        let byte_count = file.metadata()?.len();
        if byte_count == 0 {
            return Ok(Trip::Missing);
        }
        channel.send(&Message::UploadBegin {
            upload_id: row.id.clone(),
            byte_count,
            sha256: file_sha256(&path)?,
            recording: description(row),
        })?;
        let mut sent = match await_reply(channel, inbox, tuning, &row.id, None)? {
            Reply::Position(offset) => offset,
            Reply::Done(trip) => return Ok(trip),
        };
        let mut buffer = vec![0u8; tuning.upload_chunk_bytes];
        loop {
            // Deleted here means deleted: the Mac makes no meeting of what's left.
            if !self.is_waiting(&row.id)? {
                return Ok(Trip::Withdrawn);
            }
            if sent >= byte_count {
                channel.send(&Message::UploadFinish {
                    upload_id: row.id.clone(),
                })?;
                let deadline = Instant::now() + tuning.upload_finish_timeout;
                match await_reply(channel, inbox, tuning, &row.id, Some(deadline))? {
                    Reply::Position(offset) => sent = offset,
                    Reply::Done(trip) => return Ok(trip),
                }
                continue;
            }
            file.seek(SeekFrom::Start(sent))?;
            let read = file.read(&mut buffer)?;
            if read == 0 {
                // The file got shorter under us; it can't be sent as described.
                return Ok(Trip::Missing);
            }
            channel.send(&Message::UploadChunk {
                upload_id: row.id.clone(),
                offset: sent,
                data: STANDARD.encode(&buffer[..read]),
            })?;
            match await_reply(channel, inbox, tuning, &row.id, None)? {
                Reply::Position(offset) => sent = offset,
                Reply::Done(trip) => return Ok(trip),
            }
            self.store
                .lock()
                .set_recording_progress(&row.id, sent, byte_count)?;
            listener.on_progress(row.id.clone(), sent, byte_count);
        }
    }
}

enum Reply {
    /// Carry on from this byte.
    Position(u64),
    Done(Trip),
}

/// The Mac's next word about this recording. `inbox.recv` itself closes after
/// the idle timeout, which is the only limit while chunks are moving.
fn await_reply(
    channel: &Channel,
    inbox: &mut Inbox,
    tuning: &Tuning,
    id: &str,
    deadline: Option<Instant>,
) -> Result<Reply> {
    loop {
        match inbox.recv(channel, tuning, deadline)? {
            Message::UploadReady { upload_id, offset }
            | Message::UploadAck { upload_id, offset }
                if upload_id == id =>
            {
                return Ok(Reply::Position(offset));
            }
            Message::UploadDone {
                upload_id,
                status,
                message,
                ..
            } if upload_id == id => {
                return Ok(Reply::Done(match status.as_str() {
                    "accepted" => Trip::Uploaded,
                    "rejected" => Trip::Refused(message),
                    _ => Trip::Deferred(message),
                }));
            }
            Message::Revoked => return Err(SyncError::revoked()),
            Message::Error { code, message } => {
                return Err(SyncError::protocol(format!("{code}: {message}")));
            }
            _ => {}
        }
    }
}
