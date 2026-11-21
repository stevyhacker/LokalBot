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

const FORMAT: &str = "aac-adts";
const UPLOADED_LISTED_FOR: Duration = Duration::from_secs(7 * 24 * 60 * 60);

#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct RecordingInfo {
    pub id: String,
    pub title: String,
    pub state: String,
    pub started_at: String,
    pub duration_seconds: Option<f64>,
    pub byte_count: u64,
    pub sent_bytes: u64,
    pub message: Option<String>,
    pub file_path: String,
}

#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct UploadReport {
    pub uploaded: u32,
    pub waiting: u32,
    pub failed: u32,
}

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

enum Trip {
    Uploaded,
    Deferred(Option<String>),
    Refused(Option<String>),
    Missing,
    Withdrawn,
}

#[uniffi::export]
impl SyncClient {
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

    pub fn discard_recording(&self, id: String) -> Result<()> {
        self.store.lock().delete_recording(&id)?;
        let _ = fs::remove_file(recording_path(&self.recordings_dir, &id));
        Ok(())
    }

    pub fn set_recording_title(&self, id: String, title: String) -> Result<()> {
        self.store.lock().set_recording_title(&id, title.trim())
    }

    pub fn retry_recording(&self, id: String) -> Result<()> {
        self.store.lock().retry_recording(&id)
    }

    pub fn recordings(&self) -> Result<Vec<RecordingInfo>> {
        let cutoff = Utc::now()
            - chrono::Duration::from_std(UPLOADED_LISTED_FOR).unwrap_or(chrono::Duration::zero());
        let rows = self
            .store
            .lock()
            .recordings(&crate::records::iso_from_unix(cutoff.timestamp()))?;
        Ok(rows.into_iter().map(|row| self.info(row)).collect())
    }

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
    Position(u64),
    Done(Trip),
}

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
