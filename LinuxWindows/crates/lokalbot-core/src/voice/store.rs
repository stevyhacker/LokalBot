//! One serial authority for evidence, assignment journals and profile
//! mutations (`MeetingSpeakerEvidenceStore.swift`). A durable decision is
//! committed before its public transcript projection.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use aes_gcm::aead::{Aead as _, AeadCore as _, KeyInit as _, OsRng, Payload};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use chrono::{DateTime, Duration, Utc};
use parking_lot::Mutex;
use serde::Serialize;
use serde::de::DeserializeOwned;
use uuid::Uuid;

use crate::model::{AttributionSource, Meeting};

use super::{
    Assignment, Contribution, Decision, DecisionAction, EVIDENCE_FOLDER, IDENTITY_FILE,
    IdentityState, PROFILES_FILE, ProfileDatabase, VOICE_MODEL, VoiceProfile, VoiceSample,
    can_enroll, matcher,
};

const NONCE_BYTES: usize = 12;
const MAXIMUM_FILE_BYTES: u64 = 16 * 1024 * 1024;
const MAXIMUM_DECISIONS: usize = 512;
const MAXIMUM_PROFILES: usize = 250;
const MAXIMUM_CONTRIBUTIONS: usize = 8;

#[derive(Debug, thiserror::Error)]
pub enum Failure {
    #[error("Speaker information changed. Reopen the speaker to review the current result.")]
    Stale,
    #[error("This meeting or remembered person was removed.")]
    Deleted,
    #[error("Local speaker information could not be authenticated.")]
    Corrupt,
    #[error("Speaker evidence reached its storage limit.")]
    TooLarge,
    #[error("Speaker evidence was deleted or expired while this result was being prepared.")]
    EvidenceExpired,
    /// A locked or unreachable file is unavailable, not corrupt ciphertext.
    #[error("{0}")]
    Io(#[from] std::io::Error),
    /// The credential store has no usable key, so nothing is read or written.
    #[error("The key that protects remembered voices is not available: {0}")]
    KeyUnavailable(String),
    #[error("{0}")]
    Encoding(#[from] serde_json::Error),
}

pub struct Store {
    root: PathBuf,
    key: [u8; 32],
    has_secret: fn(&str) -> bool,
    /// Serializes read-modify-write cycles. Files are replaced atomically.
    lock: Mutex<BTreeSet<Uuid>>,
}

impl Store {
    pub fn new(root: PathBuf, key: [u8; 32], has_secret: fn(&str) -> bool) -> Self {
        Self {
            root,
            key,
            has_secret,
            lock: Mutex::new(BTreeSet::new()),
        }
    }

    pub fn profiles_exist(&self) -> bool {
        self.root.join(PROFILES_FILE).is_file()
    }

    fn identity_relative(meeting: &Meeting) -> String {
        format!(
            "{}/{EVIDENCE_FOLDER}/{IDENTITY_FILE}",
            meeting.relative_path.trim_end_matches('/')
        )
    }

    /// `/`-separated on every platform, so a file's associated data never
    /// depends on the system that wrote it.
    fn seal<T: Serialize>(&self, value: &T, relative: &str) -> Result<Vec<u8>, Failure> {
        let clear = serde_json::to_vec(value)?;
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&self.key));
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let aad = format!("/{relative}");
        let sealed = cipher
            .encrypt(
                &nonce,
                Payload {
                    msg: &clear,
                    aad: aad.as_bytes(),
                },
            )
            .map_err(|_| Failure::Corrupt)?;
        let mut out = Vec::with_capacity(NONCE_BYTES + sealed.len());
        out.extend_from_slice(&nonce);
        out.extend_from_slice(&sealed);
        Ok(out)
    }

    fn unseal<T: DeserializeOwned>(&self, data: &[u8], relative: &str) -> Result<T, Failure> {
        if data.len() < NONCE_BYTES {
            return Err(Failure::Corrupt);
        }
        let (nonce, body) = data.split_at(NONCE_BYTES);
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&self.key));
        let aad = format!("/{relative}");
        let clear = cipher
            .decrypt(
                Nonce::from_slice(nonce),
                Payload {
                    msg: body,
                    aad: aad.as_bytes(),
                },
            )
            .map_err(|_| Failure::Corrupt)?;
        serde_json::from_slice(&clear).map_err(|_| Failure::Corrupt)
    }

    fn read<T: DeserializeOwned>(&self, relative: &str) -> Result<Option<T>, Failure> {
        let path = self.root.join(relative);
        let size = match fs::metadata(&path) {
            Ok(meta) => meta.len(),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(err.into()),
        };
        if size > MAXIMUM_FILE_BYTES {
            return Err(Failure::TooLarge);
        }
        let data = fs::read(&path)?;
        self.unseal(&data, relative).map(Some)
    }

    fn write<T: Serialize>(&self, value: &T, relative: &str) -> Result<(), Failure> {
        let sealed = self.seal(value, relative)?;
        // `write_atomic` keeps these owner-only, and the bytes are ciphertext.
        crate::library::write_atomic(&self.root.join(relative), &sealed)?;
        Ok(())
    }

    fn check_meeting(&self, meeting: &Meeting, deleted: &BTreeSet<Uuid>) -> Result<(), Failure> {
        let meta = self
            .root
            .join(&meeting.relative_path)
            .join(crate::library::META_FILE);
        if deleted.contains(&meeting.id) || !meta.is_file() {
            return Err(Failure::Deleted);
        }
        Ok(())
    }

    fn state_inner(
        &self,
        meeting: &Meeting,
        deleted: &BTreeSet<Uuid>,
    ) -> Result<IdentityState, Failure> {
        self.check_meeting(meeting, deleted)?;
        let value: IdentityState = self
            .read(&Self::identity_relative(meeting))?
            .unwrap_or_else(|| IdentityState::new(meeting.id));
        if value.schema_version != 1 || value.meeting_id != meeting.id {
            return Err(Failure::Corrupt);
        }
        Ok(value)
    }

    pub fn state(&self, meeting: &Meeting) -> Result<IdentityState, Failure> {
        let deleted = self.lock.lock();
        self.state_inner(meeting, &deleted)
    }

    pub fn commit(
        &self,
        proposed: IdentityState,
        meeting: &Meeting,
        expected_revision: u64,
        expected_profile_revision: Option<u64>,
        expected_evidence_revision: Option<u64>,
    ) -> Result<IdentityState, Failure> {
        let deleted = self.lock.lock();
        self.commit_inner(
            proposed,
            meeting,
            expected_revision,
            expected_profile_revision,
            expected_evidence_revision,
            &deleted,
        )
    }

    fn commit_inner(
        &self,
        proposed: IdentityState,
        meeting: &Meeting,
        expected_revision: u64,
        expected_profile_revision: Option<u64>,
        expected_evidence_revision: Option<u64>,
        deleted: &BTreeSet<Uuid>,
    ) -> Result<IdentityState, Failure> {
        let current = self.state_inner(meeting, deleted)?;
        if expected_evidence_revision.is_some_and(|e| current.evidence_revision != e) {
            return Err(Failure::EvidenceExpired);
        }
        if current.revision != expected_revision {
            return Err(Failure::Stale);
        }
        if let Some(expected) = expected_profile_revision
            && self.profiles_inner()?.revision != expected
        {
            return Err(Failure::Stale);
        }
        let mut next = proposed;
        next.revision = current.revision + 1;
        // Retain only bounded recent event metadata; assignments hold durable authority.
        if next.decisions.len() > MAXIMUM_DECISIONS {
            next.decisions
                .drain(..next.decisions.len() - MAXIMUM_DECISIONS);
        }
        self.write(&next, &Self::identity_relative(meeting))?;
        Ok(next)
    }

    /// Everything beside the identity journal is retired speaker observation.
    fn remove_retired_observations(&self, meeting: &Meeting) -> Result<(), Failure> {
        let folder = self.root.join(&meeting.relative_path).join(EVIDENCE_FOLDER);
        let entries = match fs::read_dir(&folder) {
            Ok(entries) => entries,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(err) => return Err(err.into()),
        };
        for entry in entries {
            let entry = entry?;
            if entry.file_name() == IDENTITY_FILE {
                continue;
            }
            let path = entry.path();
            if path.is_dir() {
                fs::remove_dir_all(path)?;
            } else {
                fs::remove_file(path)?;
            }
        }
        Ok(())
    }

    /// Deletes samples, suggestions and timelines, keeping applied names,
    /// corrections, suppression choices and the turns that hold them.
    pub fn erase_evidence(&self, meeting: &Meeting) -> Result<(), Failure> {
        let deleted = self.lock.lock();
        self.erase_inner(meeting, &deleted)
    }

    fn erase_inner(&self, meeting: &Meeting, deleted: &BTreeSet<Uuid>) -> Result<(), Failure> {
        self.check_meeting(meeting, deleted)?;
        self.remove_retired_observations(meeting)?;
        let mut saved = self.state_inner(meeting, deleted)?;
        saved.evidence_revision += 1;
        saved.suggestions.clear();
        saved.voice_samples.clear();
        saved.microphone_sample_diagnostics = None;
        saved.timeline.clear();
        saved.acoustic_timeline = Some(Vec::new());
        for assignment in &mut saved.assignments {
            assignment.matched = None;
            assignment.supporting_matches = None;
        }
        let revision = saved.revision;
        self.commit_inner(saved, meeting, revision, None, None, deleted)?;
        Ok(())
    }

    /// Evidence older than the retention window goes; recent voice samples
    /// stay available for remembering.
    pub fn expire(
        &self,
        meetings: &[Meeting],
        retention_days: u32,
        now: DateTime<Utc>,
    ) -> Result<(), Failure> {
        let cutoff = now - Duration::days(i64::from(retention_days));
        let deleted = self.lock.lock();
        for meeting in meetings {
            let folder = self.root.join(&meeting.relative_path).join(EVIDENCE_FOLDER);
            if !folder.is_dir() {
                continue;
            }
            if meeting.started_at < cutoff {
                // Another computer's file can't be opened here and stays as it
                // is; it must not hold back every meeting after it.
                match self.erase_inner(meeting, &deleted) {
                    Err(Failure::Corrupt) => log::info!(
                        "speaker evidence not expired meeting={}: can't be opened here",
                        meeting.id
                    ),
                    other => other?,
                }
            } else {
                self.remove_retired_observations(meeting)?;
            }
        }
        Ok(())
    }

    fn profiles_inner(&self) -> Result<ProfileDatabase, Failure> {
        let database: ProfileDatabase = self.read(PROFILES_FILE)?.unwrap_or_default();
        if database.schema_version != 1 {
            return Err(Failure::Corrupt);
        }
        Ok(database)
    }

    pub fn profiles(&self) -> Result<ProfileDatabase, Failure> {
        let _guard = self.lock.lock();
        self.profiles_inner()
    }

    pub fn enroll(
        &self,
        meeting: &Meeting,
        assignment: &Assignment,
        decision: &Decision,
        samples: &[VoiceSample],
        profile_id: Option<Uuid>,
        expected_database_revision: u64,
    ) -> Result<Uuid, Failure> {
        let deleted = self.lock.lock();
        self.check_meeting(meeting, &deleted)?;
        let mut database = self.profiles_inner()?;
        if let Some(existing) = database
            .profiles
            .iter()
            .find(|p| p.contributions.iter().any(|c| c.decision_id == decision.id))
        {
            return Ok(existing.id);
        }
        let allowed =
            decision.action == DecisionAction::Assign || decision.action.confirms_identity();
        let name = match assignment.name.clone() {
            Some(name)
                if database.revision == expected_database_revision
                    && !database.deleted_meetings.contains(&meeting.id)
                    && !database.revoked_decision_ids.contains(&decision.id)
                    && assignment.origin.is_protected()
                    && allowed
                    && can_enroll(samples) =>
            {
                name
            }
            _ => return Err(Failure::Stale),
        };
        let durable = self.state_inner(meeting, &deleted)?;
        let latest = durable
            .decisions
            .iter()
            .rev()
            .find(|d| d.speaker_id == assignment.id)
            .map(|d| d.id);
        let still_named = durable
            .assignments
            .iter()
            .any(|a| a.id == assignment.id && a.name == assignment.name && a.origin.is_protected());
        if latest != Some(decision.id) || !still_named {
            return Err(Failure::Stale);
        }
        self.add(
            contribution(
                meeting,
                assignment,
                decision.id,
                decision.confirmed_at,
                samples,
            ),
            &name,
            assignment.is_local_user,
            profile_id,
            &mut database,
        )
    }

    /// A name the user gave before call voices were remembered. Legacy names
    /// have no decision, so the assignment ID stands in for one: a later
    /// correction revokes it like any other contribution.
    pub fn enroll_saved_name(
        &self,
        meeting: &Meeting,
        assignment_id: Uuid,
        samples: &[VoiceSample],
        profile_id: Option<Uuid>,
        expected_database_revision: u64,
    ) -> Result<Uuid, Failure> {
        let deleted = self.lock.lock();
        self.check_meeting(meeting, &deleted)?;
        let mut database = self.profiles_inner()?;
        let durable = self.state_inner(meeting, &deleted)?;
        let Some(assignment) = durable.assignments.iter().find(|a| a.id == assignment_id) else {
            return Err(Failure::Stale);
        };
        let Some(name) = assignment
            .name
            .clone()
            .filter(|_| assignment.origin.is_protected() && !assignment.automatic_disabled)
        else {
            return Err(Failure::Stale);
        };
        let decision = durable
            .decisions
            .iter()
            .rev()
            .find(|d| d.speaker_id == assignment_id && d.action.changes_attribution());
        if decision
            .is_some_and(|d| d.action != DecisionAction::Assign && !d.action.confirms_identity())
        {
            return Err(Failure::Stale);
        }
        let decision_id = decision.map_or(assignment_id, |d| d.id);
        if let Some(existing) = database.profiles.iter().find(|p| {
            p.contributions.iter().any(|c| {
                c.decision_id == decision_id
                    || (c.meeting_id == meeting.id && c.speaker_id == assignment_id)
            })
        }) {
            return Ok(existing.id);
        }
        if database.revision != expected_database_revision
            || database.deleted_meetings.contains(&meeting.id)
            || database.revoked_decision_ids.contains(&decision_id)
            || !can_enroll(samples)
        {
            return Err(Failure::Stale);
        }
        let confirmed = decision.map_or_else(Utc::now, |d| d.confirmed_at);
        let local_user = assignment.is_local_user;
        let contribution = contribution(meeting, assignment, decision_id, confirmed, samples);
        self.add(contribution, &name, local_user, profile_id, &mut database)
    }

    fn add(
        &self,
        contribution: Contribution,
        name: &str,
        is_local_user: Option<bool>,
        profile_id: Option<Uuid>,
        database: &mut ProfileDatabase,
    ) -> Result<Uuid, Failure> {
        let target = profile_id.unwrap_or_else(Uuid::new_v4);
        if database.forgotten_profiles.contains(&target) {
            return Err(Failure::Deleted);
        }
        if let Some(profile) = database.profiles.iter_mut().find(|p| p.id == target) {
            if profile.model != VOICE_MODEL {
                return Err(Failure::Stale);
            }
            if let (Some(existing), Some(new)) = (profile.is_local_user, is_local_user)
                && existing != new
            {
                return Err(Failure::Stale);
            }
            if is_local_user.is_some() {
                profile.is_local_user = is_local_user;
            }
            profile.contributions.retain(|c| {
                c.meeting_id != contribution.meeting_id || c.speaker_id != contribution.speaker_id
            });
            profile.contributions.push(contribution);
            if profile.contributions.len() > MAXIMUM_CONTRIBUTIONS {
                let extra = profile.contributions.len() - MAXIMUM_CONTRIBUTIONS;
                profile.contributions.drain(..extra);
            }
            if !profile.confirmed_names.iter().any(|n| n == name) {
                profile.confirmed_names.push(name.to_string());
            }
            profile.revision += 1;
        } else {
            if profile_id.is_some() {
                return Err(Failure::Deleted);
            }
            // Every named call participant is remembered, so leave room for a whole company.
            if database.profiles.len() >= MAXIMUM_PROFILES {
                return Err(Failure::TooLarge);
            }
            database.profiles.push(VoiceProfile {
                id: target,
                name: name.to_string(),
                is_local_user,
                confirmed_names: vec![name.to_string()],
                revision: 1,
                contributions: vec![contribution],
                model: VOICE_MODEL.to_string(),
            });
        }
        database.revision += 1;
        self.write(&*database, PROFILES_FILE)?;
        Ok(target)
    }

    /// Takes a meeting's contributions out of every profile; a profile left
    /// with none is forgotten.
    pub fn revoke(
        &self,
        meeting_id: Uuid,
        speaker_id: Option<Uuid>,
        deleting_meeting: bool,
    ) -> Result<(), Failure> {
        let mut deleted = self.lock.lock();
        let mut database = self.profiles_inner()?;
        if deleting_meeting {
            database.deleted_meetings.insert(meeting_id);
            deleted.insert(meeting_id);
        }
        let is_target = |c: &Contribution| {
            c.meeting_id == meeting_id && speaker_id.is_none_or(|s| s == c.speaker_id)
        };
        for profile in &mut database.profiles {
            let before = profile.contributions.len();
            database.revoked_decision_ids.extend(
                profile
                    .contributions
                    .iter()
                    .filter(|c| is_target(c))
                    .map(|c| c.decision_id),
            );
            profile.contributions.retain(|c| !is_target(c));
            if before != profile.contributions.len() {
                profile.revision += 1;
            }
        }
        let empty: Vec<Uuid> = database
            .profiles
            .iter()
            .filter(|p| p.contributions.is_empty())
            .map(|p| p.id)
            .collect();
        database.profiles.retain(|p| !p.contributions.is_empty());
        database.forgotten_profiles.extend(empty);
        database.revision += 1;
        self.write(&database, PROFILES_FILE)
    }

    /// Forgets one person, or everyone with `None`.
    pub fn forget_profile(&self, id: Option<Uuid>) -> Result<(), Failure> {
        let _guard = self.lock.lock();
        let mut database = self.profiles_inner()?;
        let ids: Vec<Uuid> = match id {
            Some(id) => vec![id],
            None => database.profiles.iter().map(|p| p.id).collect(),
        };
        let revoked: Vec<Uuid> = database
            .profiles
            .iter()
            .filter(|p| ids.contains(&p.id))
            .flat_map(|p| p.contributions.iter().map(|c| c.decision_id))
            .collect();
        database.revoked_decision_ids.extend(revoked);
        database.forgotten_profiles.extend(ids.iter().copied());
        database.profiles.retain(|p| !ids.contains(&p.id));
        database.revision += 1;
        self.write(&database, PROFILES_FILE)
    }

    pub fn rename_profile(&self, id: Uuid, name: &str) -> Result<(), Failure> {
        let _guard = self.lock.lock();
        let mut database = self.profiles_inner()?;
        let Some(name) = super::safe_name(name, &self.has_secret) else {
            return Err(Failure::Stale);
        };
        let Some(profile) = database.profiles.iter_mut().find(|p| p.id == id) else {
            return Err(Failure::Stale);
        };
        profile.name = name.clone();
        profile.confirmed_names.push(name);
        profile.revision += 1;
        database.revision += 1;
        self.write(&database, PROFILES_FILE)
    }

    pub(super) fn safe_name(&self, raw: &str) -> Option<String> {
        super::safe_name(raw, &self.has_secret)
    }
}

/// Call voices store their average and one chunk for provenance, which keeps
/// a busy team's profiles well inside the file limit.
fn contribution(
    meeting: &Meeting,
    assignment: &Assignment,
    decision_id: Uuid,
    confirmed_at: DateTime<Utc>,
    samples: &[VoiceSample],
) -> Contribution {
    let is_call = samples
        .first()
        .is_none_or(|s| s.resolved_source() == AttributionSource::System);
    Contribution {
        meeting_id: meeting.id,
        audio_revision: assignment.audio_revision.clone(),
        speaker_id: assignment.id,
        decision_id,
        confirmed_at,
        samples: samples
            .iter()
            .take(if is_call { 1 } else { 8 })
            .cloned()
            .collect(),
        voiceprint: if is_call {
            matcher::sample_voiceprint(samples).map(|p| p.vector)
        } else {
            None
        },
    }
}
