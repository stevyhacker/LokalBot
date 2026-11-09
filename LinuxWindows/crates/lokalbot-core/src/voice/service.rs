//! Meeting speaker identity (`MeetingSpeakerIdentityService.swift`): one
//! object per library that keeps a durable journal for each meeting, and only
//! ever lets a person's choice decide a name.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::Read as _;
use std::path::Path;
use std::sync::Arc;

use chrono::{DateTime, Duration, Utc};
use parking_lot::Mutex;
use sha2::{Digest as _, Sha256};
use uuid::Uuid;

use crate::library::Library;
use crate::model::{AttributionSource, Meeting, Transcript};

use super::evidence::MicrophoneEvidence;
use super::{
    Assignment, AudioTurn, CALL_VOICES_VERSION, Decision, DecisionAction, Failure, IdentityState,
    MatchTier, NameMatch, Origin, Store, TurnAnchor, VoiceProfile, VoiceSample, apply_candidates,
    can_enroll, eligible, legacy_source, matches, name_key, remap, union,
};

/// A track's SHA-256, hex.
pub fn audio_revision(path: &Path) -> std::io::Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    Ok(hex::encode(hash.finalize()))
}

/// `mic:<sha>|system:<sha>` for the tracks that exist, or `fallback`'s hash.
pub fn recording_revision(
    mic: Option<&Path>,
    system: Option<&Path>,
    fallback: Option<&Path>,
) -> std::io::Result<String> {
    let mut parts = Vec::new();
    for (name, track) in [("mic", mic), ("system", system)] {
        if let Some(track) = track {
            parts.push(format!("{name}:{}", audio_revision(track)?));
        }
    }
    if parts.is_empty()
        && let Some(fallback) = fallback
    {
        return audio_revision(fallback);
    }
    Ok(parts.join("|"))
}

/// Swift's `Double.description`: `1.0`, `0.5`, `1e-05`, `1e+16`.
fn swift_double(value: f64) -> String {
    let text = format!("{value:?}");
    let Some((mantissa, exponent)) = text.split_once('e') else {
        return text;
    };
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let sign = if exponent < 0 { '-' } else { '+' };
    format!("{mantissa}e{sign}{:02}", exponent.abs())
}

/// Identifies the speaker timeline a state's labels were made for.
pub fn transcript_signature(transcript: &Transcript) -> String {
    let turns = transcript
        .segments
        .iter()
        .map(|s| {
            format!(
                "{}|{}|{}",
                swift_double(s.start),
                swift_double(s.end),
                Transcript::canonical_speaker_key(&s.speaker)
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
    hex::encode(Sha256::digest(turns.as_bytes()))
}

fn timeline(transcript: &Transcript) -> Vec<AudioTurn> {
    transcript
        .segments
        .iter()
        .map(|segment| {
            let source = Transcript::resolved_attribution(segment).source;
            AudioTurn {
                speaker: Transcript::canonical_speaker_key(&segment.speaker),
                range: TurnAnchor {
                    start: segment.start,
                    end: segment.end,
                },
                source: Some(if source == AttributionSource::Unknown {
                    legacy_source(&segment.speaker)
                } else {
                    source
                }),
            }
        })
        .collect()
}

fn projection(state: &IdentityState, transcript: &Transcript) -> Transcript {
    let mut result = transcript.clone();
    let labels: HashSet<String> = transcript
        .segments
        .iter()
        .map(|s| Transcript::canonical_speaker_key(&s.speaker))
        .collect();
    for assignment in state
        .assignments
        .iter()
        .filter(|a| labels.contains(&a.label))
    {
        result.set_speaker_alias(
            assignment.name.as_deref(),
            &assignment.label,
            assignment.calendar_identity_id.as_deref(),
        );
        if let Some(is_user) = assignment.is_local_user {
            result.confirm_speaker(&assignment.label, Some(is_user));
        } else if assignment.automatic_disabled {
            result.confirm_speaker(&assignment.label, None);
        }
    }
    result
}

/// A name the user gave a call voice, or a legacy name the transcript still carries.
fn is_saved_call_name(assignment: &Assignment) -> bool {
    assignment.origin.is_protected()
        && assignment.name.is_some()
        && !assignment.automatic_disabled
        && assignment.is_local_user != Some(true)
        && !assignment.is_unresolved_label()
        && assignment.resolved_source() == AttributionSource::System
}

/// An unnamed call voice that automatic naming may still fill.
fn awaits_call_name(assignment: &Assignment) -> bool {
    assignment.name.is_none()
        && !assignment.origin.is_protected()
        && !assignment.automatic_disabled
        && !assignment.is_unresolved_label()
        && assignment.resolved_source() == AttributionSource::System
}

/// Unnamed call speakers whose voice clearly matches one remembered person.
pub fn recognized_speakers(
    state: Option<&IdentityState>,
    transcript: &Transcript,
) -> Vec<(String, NameMatch)> {
    let Some(state) = state else {
        return Vec::new();
    };
    let mut waiting: Vec<&Assignment> = state
        .assignments
        .iter()
        .filter(|a| awaits_call_name(a))
        .collect();
    waiting.sort_by(|a, b| a.label.cmp(&b.label));
    waiting
        .into_iter()
        .filter_map(|assignment| {
            if transcript.speaker_aliases.contains_key(&assignment.label) {
                return None;
            }
            let found = state
                .suggestions
                .get(&assignment.label)?
                .iter()
                .find(|m| m.tier == MatchTier::Automatic)?;
            Some((assignment.label.clone(), found.clone()))
        })
        .collect()
}

/// The remembered person a newly named voice belongs to: same name and an
/// agreeing voice, so naming someone again never splits them in two. A person
/// known only from the other source has nothing to compare and is reused.
pub fn same_person(name: &str, samples: &[VoiceSample], profiles: &[VoiceProfile]) -> Option<Uuid> {
    let key = name_key(name);
    let named: Vec<VoiceProfile> = profiles
        .iter()
        .filter(|profile| {
            profile.model == super::VOICE_MODEL
                && (name_key(&profile.name) == key
                    || profile.confirmed_names.iter().any(|n| name_key(n) == key))
        })
        .cloned()
        .collect();
    if let Some(agreeing) = matches(samples, &named).first().and_then(|m| m.profile_id) {
        return Some(agreeing);
    }
    let domain = samples
        .first()
        .map_or(AttributionSource::System, VoiceSample::resolved_source);
    named
        .iter()
        .find(|profile| {
            !profile.contributions.iter().any(|c| {
                c.samples
                    .first()
                    .map_or(AttributionSource::System, VoiceSample::resolved_source)
                    == domain
            })
        })
        .map(|p| p.id)
}

/// A speaker change is newer than the notes (`speakerSummaryNeedsRefresh`).
pub fn summary_needs_refresh(
    state: &IdentityState,
    summary_modified: Option<DateTime<Utc>>,
) -> bool {
    match (state.latest_attribution_change(), summary_modified) {
        (Some(change), Some(summary)) => summary < change,
        _ => false,
    }
}

/// A person's decision about one speaker (`MeetingSpeakerIdentityService.Choice`).
#[derive(Clone, Debug)]
pub struct Choice {
    pub id: Uuid,
    pub label: String,
    pub name: Option<String>,
    pub calendar_identity_id: Option<String>,
    pub action: DecisionAction,
    pub profile_id: Option<Uuid>,
    pub expected_revision: Option<u64>,
}

impl Choice {
    pub fn new(label: &str, name: Option<String>, action: DecisionAction) -> Self {
        Self {
            id: Uuid::new_v4(),
            label: label.to_string(),
            name,
            calendar_identity_id: None,
            action,
            profile_id: None,
            expected_revision: None,
        }
    }
}

/// One finished transcription to identify.
pub struct ProcessRequest<'a> {
    pub transcript: &'a Transcript,
    pub meeting: &'a Meeting,
    pub turns: &'a [AudioTurn],
    /// Labeled samples after the microphone checks.
    pub evidence: MicrophoneEvidence,
    pub mic: Option<&'a Path>,
    pub system: Option<&'a Path>,
    /// What was saved before: its names carry over when no journal exists yet.
    pub previous: Option<&'a Transcript>,
    /// `false` keeps automatic matches as suggestions, for saved meetings
    /// whose notes were written from the current names.
    pub name_automatically: bool,
}

/// What learning from saved meetings needs from the engine.
pub trait SavedMeetingAccess {
    fn transcript(&self, meeting: &Meeting) -> Option<Transcript>;
    /// Analyzes a meeting's call track; `Err` means analysis can't run now.
    fn call_samples(
        &self,
        meeting: &Meeting,
        transcript: &Transcript,
    ) -> anyhow::Result<Vec<VoiceSample>>;
    fn is_busy(&self, meeting: &Meeting) -> bool;
    fn cancelled(&self) -> bool;
    /// The microphone checks for samples kept from an earlier analysis.
    fn select(
        &self,
        meeting: &Meeting,
        transcript: &Transcript,
        turns: &[AudioTurn],
        samples: Vec<VoiceSample>,
    ) -> MicrophoneEvidence;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Revisit {
    Done,
    Skipped,
    AnalysisFailed,
}

/// `MeetingSpeakerIdentityService`. Errors never fail audio transcription: a
/// caller keeps its transcript and shows [`Self::notice`].
pub struct VoiceMemory {
    library: Library,
    key: Box<dyn Fn() -> Result<[u8; 32], String> + Send + Sync>,
    has_secret: fn(&str) -> bool,
    store: Mutex<Option<Arc<Store>>>,
    notice: Mutex<Option<(Option<Uuid>, String)>>,
    deleted: Mutex<HashSet<Uuid>>,
    latest: Mutex<HashMap<Uuid, IdentityState>>,
    unverified: Mutex<HashSet<Uuid>>,
    /// Profile database revision each recent meeting was last matched against.
    matched_revision: Mutex<HashMap<Uuid, u64>>,
}

impl VoiceMemory {
    pub fn new(
        library: Library,
        key: Box<dyn Fn() -> Result<[u8; 32], String> + Send + Sync>,
        has_secret: fn(&str) -> bool,
    ) -> Self {
        Self {
            library,
            key,
            has_secret,
            store: Mutex::new(None),
            notice: Mutex::new(None),
            deleted: Mutex::new(HashSet::new()),
            latest: Mutex::new(HashMap::new()),
            unverified: Mutex::new(HashSet::new()),
            matched_revision: Mutex::new(HashMap::new()),
        }
    }

    pub fn store(&self) -> Result<Arc<Store>, Failure> {
        let mut slot = self.store.lock();
        if let Some(store) = slot.as_ref() {
            return Ok(store.clone());
        }
        let key = (self.key)().map_err(Failure::KeyUnavailable)?;
        let store = Arc::new(Store::new(
            self.library.paths().root().to_path_buf(),
            key,
            self.has_secret,
        ));
        *slot = Some(store.clone());
        Ok(store)
    }

    /// The latest problem, if any.
    pub fn notice(&self) -> Option<String> {
        self.notice.lock().as_ref().map(|(_, text)| text.clone())
    }

    /// The latest problem to show beside this meeting's speakers.
    pub fn notice_for(&self, meeting_id: Uuid) -> Option<String> {
        self.notice
            .lock()
            .as_ref()
            .filter(|(meeting, _)| *meeting == Some(meeting_id))
            .map(|(_, text)| text.clone())
    }

    fn set_notice(&self, meeting_id: Uuid, notice: Option<String>) {
        *self.notice.lock() = notice.map(|text| (Some(meeting_id), text));
    }

    /// Why this meeting's speakers weren't identified.
    pub fn note_unavailable(&self, meeting_id: Uuid, failure: &Failure) {
        self.set_notice(
            meeting_id,
            Some(format!("Speaker identification unavailable: {failure}")),
        );
    }

    /// A name went on the transcript without teaching a voice.
    pub fn note_not_remembered(&self, meeting_id: Uuid, failure: &Failure) {
        self.set_notice(
            meeting_id,
            Some(format!(
                "Name saved. Voice profile update pending: {failure}"
            )),
        );
    }

    /// Whether the saved speaker journal was made for this transcript.
    pub fn matches_transcript(&self, meeting: &Meeting, transcript: &Transcript) -> bool {
        self.state(meeting).is_ok_and(|state| {
            state
                .transcript_signature
                .is_none_or(|s| s == transcript_signature(transcript))
        })
    }

    pub fn state(&self, meeting: &Meeting) -> Result<IdentityState, Failure> {
        self.store()?.state(meeting)
    }

    fn remember_state(&self, state: &IdentityState) {
        let mut latest = self.latest.lock();
        let newer = latest
            .get(&state.meeting_id)
            .is_none_or(|known| state.revision >= known.revision);
        if newer {
            latest.insert(state.meeting_id, state.clone());
        }
    }

    /// The final projection immediately before a transcript write: an
    /// automatic result finishing after a human correction cannot overwrite it.
    pub fn applying_latest_decision(
        &self,
        transcript: &Transcript,
        meeting_id: Uuid,
    ) -> Transcript {
        if self.unverified.lock().contains(&meeting_id) {
            return transcript.clone();
        }
        let latest = self.latest.lock();
        match latest.get(&meeting_id) {
            Some(state)
                if state
                    .transcript_signature
                    .as_ref()
                    .is_none_or(|s| *s == transcript_signature(transcript)) =>
            {
                projection(state, transcript)
            }
            _ => transcript.clone(),
        }
    }

    fn track_paths(&self, meeting: &Meeting) -> crate::library::MeetingAudio {
        self.library.audio(meeting)
    }

    /// Recovers an interrupted sidecar/transcript pair without applying a
    /// stale ordinal mapping to a different transcription.
    pub fn recover(
        &self,
        meeting: &Meeting,
        transcript: &Transcript,
    ) -> Result<Transcript, Failure> {
        let saved = self.state(meeting)?;
        if saved.audio_revision.is_empty() {
            return Ok(transcript.clone());
        }
        let audio = self.track_paths(meeting);
        let current = recording_revision(audio.mic.as_deref(), audio.system.as_deref(), None)?;
        if current != saved.audio_revision {
            return Ok(transcript.clone());
        }
        let mut recovery = saved.clone();
        recovery.assignments = remap(
            &saved.assignments,
            &timeline(transcript),
            &saved.audio_revision,
        );
        Ok(projection(&recovery, transcript))
    }

    /// Names a finished transcription from remembered voices, carrying over
    /// what people decided before. Returns the transcript to save.
    pub fn process(&self, request: ProcessRequest<'_>) -> Result<Transcript, Failure> {
        let meeting = request.meeting;
        let transcript = request.transcript;
        self.unverified.lock().insert(meeting.id);
        let store = self.store()?;
        let audio_rev =
            recording_revision(request.mic, request.system, request.mic.or(request.system))?;
        let usable = timeline(transcript);
        let mut evidence_revision = store.state(meeting)?.evidence_revision;
        // The sample meeting's synthetic voices are never remembered or matched.
        let mut remembered = !meeting.is_sample();
        let mut database = if remembered {
            store.profiles()?
        } else {
            Default::default()
        };
        let mut compatible = if remembered {
            request.evidence.samples.clone()
        } else {
            Vec::new()
        };
        for _ in 0..3 {
            if self.deleted.lock().contains(&meeting.id) {
                return Ok(transcript.clone());
            }
            let previous = store.state(meeting)?;
            let mut next = previous.clone();
            next.assignments = remap(&previous.assignments, &usable, &audio_rev);
            next.audio_revision = audio_rev.clone();
            next.transcript_signature = Some(transcript_signature(transcript));
            next.timeline = usable.clone();
            next.acoustic_timeline = Some(request.turns.to_vec());
            next.microphone_sample_diagnostics =
                remembered.then(|| request.evidence.counts.clone());
            next.voice_samples = if remembered {
                let mut labels: Vec<&str> = usable.iter().map(|t| t.speaker.as_str()).collect();
                labels.sort_unstable();
                labels.dedup();
                labels
                    .into_iter()
                    .take(60)
                    .flat_map(|label| eligible(&compatible, request.turns, label))
                    .collect()
            } else {
                Vec::new()
            };
            next.call_voices_analyzed = Some(CALL_VOICES_VERSION);
            next.suggestions = BTreeMap::new();
            next.analyzed_at = Utc::now();
            // Legacy aliases have human authority, but only use their old
            // turns to carry them across retranscription.
            if previous.revision == 0
                && let Some(old) = request.previous
            {
                let old_turns = timeline(old);
                let mut labels: Vec<String> = old
                    .segments
                    .iter()
                    .map(|s| Transcript::canonical_speaker_key(&s.speaker))
                    .collect();
                labels.sort();
                labels.dedup();
                let legacy: Vec<Assignment> = labels
                    .iter()
                    .map(|label| {
                        let alias = old.speaker_aliases.get(label);
                        let mut assignment = Assignment::new(
                            label,
                            if alias.is_none() {
                                Origin::CalendarAutomatic
                            } else {
                                Origin::Legacy
                            },
                            &audio_rev,
                            old_turns
                                .iter()
                                .filter(|t| t.speaker == *label)
                                .map(|t| t.range)
                                .collect(),
                        );
                        assignment.name = alias.cloned();
                        assignment.calendar_identity_id =
                            old.speaker_calendar_identity_ids.get(label).cloned();
                        assignment
                    })
                    .collect();
                next.assignments.extend(remap(&legacy, &usable, &audio_rev));
            }
            let mut groups: BTreeMap<&str, Vec<&AudioTurn>> = BTreeMap::new();
            for turn in &usable {
                groups.entry(turn.speaker.as_str()).or_default().push(turn);
            }
            for (label, speaker_turns) in groups {
                if !next.assignments.iter().any(|a| a.label == label) {
                    next.assignments.push(Assignment::new(
                        label,
                        Origin::CalendarAutomatic,
                        &audio_rev,
                        union(speaker_turns.iter().map(|t| t.range)),
                    ));
                }
                let Some(index) = next.assignments.iter().position(|a| a.label == label) else {
                    continue;
                };
                next.assignments[index].source = speaker_turns.first().map(|t| t.resolved_source());
                let candidates = if remembered {
                    matches(
                        &eligible(&next.voice_samples, &usable, label),
                        &database.profiles,
                    )
                } else {
                    Vec::new()
                };
                let offered = if request.name_automatically {
                    apply_candidates(
                        &candidates,
                        &mut next.assignments[index],
                        &database.profiles,
                    )
                } else {
                    let mut preview = next.assignments[index].clone();
                    apply_candidates(&candidates, &mut preview, &database.profiles)
                };
                next.suggestions.insert(label.to_string(), offered);
                // Calendar is a fallback only; reliable disagreement is reviewable.
                let assignment = &mut next.assignments[index];
                if assignment.name.is_none()
                    && !assignment.origin.is_protected()
                    && !assignment.automatic_disabled
                    && candidates.is_empty()
                    && let Some(name) = transcript.speaker_aliases.get(label)
                    && !assignment.suppressed_names.contains(&name_key(name))
                {
                    assignment.name = Some(name.clone());
                    assignment.calendar_identity_id =
                        transcript.speaker_calendar_identity_ids.get(label).cloned();
                    assignment.origin = Origin::CalendarAutomatic;
                }
            }
            // Preserve detached decisions for manual reassignment when a merge
            // prevents a safe remap. They cannot project onto a current label.
            let retained: HashSet<Uuid> = next.assignments.iter().map(|a| a.id).collect();
            let mut detached: BTreeMap<Uuid, Vec<&Assignment>> = BTreeMap::new();
            for assignment in previous
                .assignments
                .iter()
                .filter(|a| a.origin.is_protected())
            {
                if !retained.contains(&assignment.id) {
                    detached.entry(assignment.id).or_default().push(assignment);
                }
            }
            for (id, prior) in detached {
                let mut item = prior[0].clone();
                item.anchors = union(prior.iter().flat_map(|a| a.anchors.iter().copied()));
                item.label = format!("unresolved-{}", crate::ids::uuid_upper(&id));
                next.assignments.push(item);
            }
            match store.commit(
                next,
                meeting,
                previous.revision,
                remembered.then_some(database.revision),
                Some(evidence_revision),
            ) {
                Ok(committed) => {
                    // The pipeline reapplies this cache right before writing.
                    self.remember_state(&committed);
                    self.unverified.lock().remove(&meeting.id);
                    log::info!(
                        "speaker identity processed speakers={} named={} automatic={} suggestions={} callSamples={}",
                        committed.assignments.len(),
                        committed
                            .assignments
                            .iter()
                            .filter(|a| a.name.is_some())
                            .count(),
                        committed
                            .assignments
                            .iter()
                            .filter(|a| a.origin == Origin::ProfileAutomatic && a.name.is_some())
                            .count(),
                        committed.suggestions.values().map(Vec::len).sum::<usize>(),
                        committed
                            .voice_samples
                            .iter()
                            .filter(|s| s.resolved_source() == AttributionSource::System)
                            .count(),
                    );
                    return Ok(self.applying_latest_decision(transcript, meeting.id));
                }
                // Keep durable human choices and historical aliases when a
                // deletion races processing, but discard all pending evidence.
                Err(Failure::EvidenceExpired) => {
                    compatible.clear();
                    remembered = false;
                    evidence_revision = store.state(meeting)?.evidence_revision;
                }
                Err(Failure::Stale) => {
                    if remembered {
                        database = store.profiles()?;
                    }
                }
                Err(other) => return Err(other),
            }
        }
        self.set_notice(
            meeting.id,
            Some(
                "Speaker names changed during processing. Reopen this meeting to review them."
                    .into(),
            ),
        );
        Ok(transcript.clone())
    }

    /// Applies a person's choice and teaches the voice. The returned
    /// transcript is the one to save.
    pub fn choose(
        &self,
        choice: &Choice,
        meeting: &Meeting,
        transcript: &Transcript,
    ) -> Result<Transcript, ChooseError> {
        let store = self.store()?;
        let mut current = store.state(meeting)?;
        let signature = transcript_signature(transcript);
        if current
            .transcript_signature
            .as_ref()
            .is_some_and(|s| *s != signature)
        {
            return Err(Failure::Stale.into());
        }
        if current.decisions.iter().any(|d| d.id == choice.id) {
            self.remember_state(&current);
            return Ok(projection(&current, transcript));
        }
        if choice
            .expected_revision
            .is_some_and(|expected| expected != current.revision)
        {
            return Err(Failure::Stale.into());
        }
        current.transcript_signature = Some(signature);
        let label = Transcript::canonical_speaker_key(&choice.label);
        let audio = self.track_paths(meeting);
        if current.audio_revision.is_empty() {
            current.audio_revision =
                recording_revision(audio.mic.as_deref(), audio.system.as_deref(), None)
                    .map_err(Failure::from)?;
        }
        if current.timeline.is_empty() {
            current.timeline = timeline(transcript);
        }
        let original = current.assignment(&label).cloned();
        let mut assignment = original.clone().unwrap_or_else(|| {
            Assignment::new(
                &label,
                Origin::Legacy,
                &current.audio_revision,
                current
                    .timeline
                    .iter()
                    .filter(|t| t.speaker == label)
                    .map(|t| t.range)
                    .collect(),
            )
        });
        assignment.source = current
            .timeline
            .iter()
            .find(|t| t.speaker == label)
            .map(|t| t.resolved_source());
        let needs_clean_audio = choice.action.confirms_identity()
            || (choice.action == DecisionAction::Assign && choice.profile_id.is_some());
        if needs_clean_audio && !transcript.can_confirm_speaker(&label) {
            return Err(ChooseError::UnseparatedAudio);
        }
        let enrollment_speaker = assignment.id;
        let rejected = if choice.action == DecisionAction::Dismiss {
            choice.name.clone()
        } else {
            assignment
                .name
                .clone()
                .or_else(|| transcript.speaker_aliases.get(&label).cloned())
        };
        if let Some(rejected) = rejected
            && (choice.action != DecisionAction::Assign
                || choice.name.as_deref() != Some(rejected.as_str()))
        {
            let key = name_key(&rejected);
            if !assignment.suppressed_names.contains(&key) {
                assignment.suppressed_names.push(key);
            }
        }
        match choice.action {
            DecisionAction::Assign | DecisionAction::ConfirmUser | DecisionAction::ConfirmOther => {
                assignment.name = choice.name.as_deref().and_then(|n| store.safe_name(n));
                assignment.calendar_identity_id = choice.calendar_identity_id.clone();
                assignment.origin = if original.as_ref().is_none_or(|o| o.name.is_none()) {
                    Origin::UserConfirmed
                } else {
                    Origin::UserCorrected
                };
                assignment.automatic_disabled = false;
                if choice.action.confirms_identity() {
                    let is_user = choice.action == DecisionAction::ConfirmUser;
                    assignment.is_local_user = Some(is_user);
                    if assignment.name.is_none() {
                        assignment.name = Some(if is_user {
                            "Me".to_string()
                        } else {
                            transcript.speaker_name(&label)
                        });
                    }
                } else if let Some(profile_id) = choice.profile_id {
                    // Choosing a suggested profile is an explicit confirmation
                    // of that person, including a confirmed local user.
                    let database = store.profiles()?;
                    let wanted = name_key(choice.name.as_deref().unwrap_or(""));
                    let Some(profile) = database.profiles.iter().find(|p| {
                        p.id == profile_id
                            && p.confirmed_names.iter().any(|n| name_key(n) == wanted)
                    }) else {
                        return Err(Failure::Stale.into());
                    };
                    assignment.is_local_user = profile.is_local_user;
                }
            }
            DecisionAction::Reset | DecisionAction::Undo => {
                assignment.name = None;
                assignment.calendar_identity_id = None;
                assignment.origin = Origin::UserCorrected;
                assignment.automatic_disabled = true;
                assignment.is_local_user = None;
            }
            DecisionAction::Resume => {
                assignment.automatic_disabled = false;
                assignment.origin = Origin::CalendarAutomatic;
                assignment.suppressed_names.clear();
            }
            DecisionAction::Dismiss => {
                if !assignment.origin.is_protected() && choice.name == assignment.name {
                    assignment.name = None;
                    assignment.calendar_identity_id = None;
                    assignment.matched = None;
                    assignment.supporting_matches = None;
                }
            }
        }
        if choice.action != DecisionAction::Dismiss {
            assignment.matched = None;
            assignment.supporting_matches = None;
            assignment.profile_id = None;
        }
        if current.assignments.iter().any(|a| {
            a.id == assignment.id
                && a.label != label
                && (a.name != assignment.name
                    || a.automatic_disabled != assignment.automatic_disabled
                    || a.is_local_user != assignment.is_local_user)
        }) {
            // A human distinguished two labels previously inferred to be a
            // clean split. Preserve that distinction on subsequent remapping.
            assignment.id = Uuid::new_v4();
        }
        if choice.action == DecisionAction::Resume {
            let acoustic = current.acoustic_timeline.clone().unwrap_or_default();
            let profiles = if meeting.is_sample() {
                Vec::new()
            } else {
                store.profiles()?.profiles
            };
            let candidates = matches(
                &eligible(&current.voice_samples, &acoustic, &label),
                &profiles,
            );
            let offered = apply_candidates(&candidates, &mut assignment, &profiles);
            current.suggestions.insert(label.clone(), offered);
        }
        let decision = Decision {
            id: choice.id,
            speaker_id: assignment.id,
            action: choice.action,
            source_revision: current.audio_revision.clone(),
            name: choice.name.clone(),
            confirmed_at: Utc::now(),
        };
        // Revoke an old confirmation before recording a correction. A failure
        // leaves a visible pending state instead of training on the wrong person.
        if choice.action != DecisionAction::Dismiss && store.profiles_exist() {
            store.revoke(meeting.id, Some(enrollment_speaker), false)?;
        }
        current.assignments.retain(|a| a.label != label);
        current.assignments.push(assignment.clone());
        current.decisions.push(decision.clone());
        if let Some(offered) = current.suggestions.get_mut(&label) {
            offered.retain(|m| !assignment.suppressed_names.contains(&name_key(&m.name)));
        }
        let revision = current.revision;
        let committed = store.commit(current, meeting, revision, None, None)?;
        self.remember_state(&committed);
        self.unverified.lock().remove(&meeting.id);
        self.set_notice(meeting.id, None);
        // Every name the user gives teaches LokalBot that voice.
        if (choice.action == DecisionAction::Assign || choice.action.confirms_identity())
            && !meeting.is_sample()
            && let Some(name) = assignment.name.as_deref()
        {
            let samples = eligible(&committed.voice_samples, &committed.timeline, &label);
            if can_enroll(&samples) {
                let enrolled = store.profiles().and_then(|database| {
                    let target = choice
                        .profile_id
                        .or_else(|| same_person(name, &samples, &database.profiles));
                    store.enroll(
                        meeting,
                        &assignment,
                        &decision,
                        &samples,
                        target,
                        database.revision,
                    )
                });
                if let Err(err) = enrolled {
                    self.note_not_remembered(meeting.id, &err);
                }
            } else if !samples.is_empty()
                || assignment.source == Some(AttributionSource::Microphone)
            {
                self.set_notice(
                    meeting.id,
                    Some(
                        "Name saved. Remembering this voice needs three separate clear turns totaling 15 seconds."
                            .into(),
                    ),
                );
            }
        }
        // Another correction could arrive while enrollment ran.
        let latest = store.state(meeting)?;
        self.remember_state(&latest);
        Ok(self.applying_latest_decision(transcript, meeting.id))
    }

    /// A meeting can be deleted while remembered voices can't be opened (the
    /// credential store was out of reach, say). Its contributions leave them
    /// the next time they can.
    pub fn revoke_removed_meetings(&self, meetings: &[Meeting]) {
        if !self
            .library
            .paths()
            .root()
            .join(super::PROFILES_FILE)
            .is_file()
        {
            return;
        }
        let Ok(store) = self.store() else { return };
        let Ok(database) = store.profiles() else {
            return;
        };
        let kept: HashSet<Uuid> = meetings.iter().map(|m| m.id).collect();
        let removed: HashSet<Uuid> = database
            .profiles
            .iter()
            .flat_map(|p| p.contributions.iter().map(|c| c.meeting_id))
            .filter(|id| !kept.contains(id))
            .collect();
        for meeting_id in removed {
            if let Err(err) = store.revoke(meeting_id, None, true) {
                log::warn!("speaker voice not forgotten meeting={meeting_id}: {err}");
            }
        }
    }

    /// Expires evidence by the screen retention window, even with capture off.
    pub fn expire(&self, meetings: &[Meeting], retention_days: u32, now: DateTime<Utc>) {
        let root = self.library.paths().root();
        if !meetings.iter().any(|m| {
            root.join(&m.relative_path)
                .join(super::EVIDENCE_FOLDER)
                .is_dir()
        }) {
            return;
        }
        let result = self
            .store()
            .and_then(|store| store.expire(meetings, retention_days, now));
        if let Err(err) = result {
            *self.notice.lock() = Some((None, format!("Speaker evidence cleanup pending: {err}")));
        }
    }

    pub fn delete_evidence(&self, meeting: &Meeting) -> Result<(), Failure> {
        self.store()?.erase_evidence(meeting)?;
        self.latest.lock().remove(&meeting.id);
        Ok(())
    }

    /// Before a meeting is deleted: its contributions leave every profile.
    pub fn prepare_deletion(&self, meeting: &Meeting) -> Result<(), Failure> {
        self.deleted.lock().insert(meeting.id);
        self.latest.lock().remove(&meeting.id);
        let has_profiles = self
            .library
            .paths()
            .root()
            .join(super::PROFILES_FILE)
            .is_file();
        if self.store.lock().is_some() || has_profiles {
            self.store()?.revoke(meeting.id, None, true)?;
        }
        Ok(())
    }

    pub fn profiles(&self) -> Result<Vec<VoiceProfile>, Failure> {
        Ok(self.store()?.profiles()?.profiles)
    }

    pub fn forget_profile(&self, id: Option<Uuid>) -> Result<(), Failure> {
        self.store()?.forget_profile(id)
    }

    pub fn rename_profile(&self, id: Uuid, name: &str) -> Result<(), Failure> {
        self.store()?.rename_profile(id, name)
    }

    fn has_saved_call_names(
        &self,
        saved: &IdentityState,
        meeting: &Meeting,
        access: &dyn SavedMeetingAccess,
    ) -> bool {
        if saved.revision > 0 {
            return saved.assignments.iter().any(is_saved_call_name);
        }
        // Meetings named before speaker review existed keep their names only
        // in the transcript.
        access.transcript(meeting).is_some_and(|transcript| {
            transcript
                .speaker_aliases
                .keys()
                .any(|key| legacy_source(key) == AttributionSource::System)
        })
    }

    /// Re-runs identification for a saved transcript, analyzing its call
    /// track first when needed. Matches become suggestions; nothing is saved
    /// to the transcript.
    fn reidentify(
        &self,
        meeting: &Meeting,
        analyzing: bool,
        access: &dyn SavedMeetingAccess,
    ) -> Revisit {
        let audio = self.track_paths(meeting);
        let (false, Some(transcript), Some(_), Ok(saved)) = (
            access.is_busy(meeting),
            access.transcript(meeting),
            audio.system.as_ref(),
            self.state(meeting),
        ) else {
            return Revisit::Skipped;
        };
        // Saved names follow audio turns of the same recording only.
        if saved.revision > 0 {
            let current = recording_revision(audio.mic.as_deref(), audio.system.as_deref(), None);
            if current.ok().as_deref() != Some(saved.audio_revision.as_str()) {
                return Revisit::Skipped;
            }
        }
        let mut samples = saved.voice_samples.clone();
        if analyzing {
            match access.call_samples(meeting, &transcript) {
                Ok(call) => {
                    samples.retain(|s| s.source == Some(AttributionSource::Microphone));
                    samples.extend(call);
                }
                Err(err) => {
                    log::info!("speaker voices not analyzed: {err:#}");
                    return Revisit::AnalysisFailed;
                }
            }
            if access.is_busy(meeting) {
                return Revisit::Skipped;
            }
        }
        let turns = saved
            .acoustic_timeline
            .clone()
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| timeline(&transcript));
        let evidence = access.select(meeting, &transcript, &turns, samples);
        let result = self.process(ProcessRequest {
            transcript: &transcript,
            meeting,
            turns: &turns,
            evidence,
            mic: audio.mic.as_deref(),
            system: audio.system.as_deref(),
            previous: Some(&transcript),
            name_automatically: false,
        });
        if let Err(err) = result {
            log::info!("speaker identity not refreshed: {err}");
            return Revisit::Skipped;
        }
        Revisit::Done
    }

    /// Enrolls the call voices the user named in one meeting; returns how many.
    fn enroll_saved_names(&self, meeting: &Meeting) -> usize {
        let Ok(store) = self.store() else { return 0 };
        let Ok(saved) = store.state(meeting) else {
            return 0;
        };
        let mut enrolled = 0;
        for assignment in saved.assignments.iter().filter(|a| is_saved_call_name(a)) {
            let samples = eligible(&saved.voice_samples, &saved.timeline, &assignment.label);
            let (Some(name), true, Ok(database)) = (
                assignment.name.as_deref(),
                can_enroll(&samples),
                store.profiles(),
            ) else {
                continue;
            };
            let known = database.profiles.iter().any(|p| {
                p.contributions
                    .iter()
                    .any(|c| c.meeting_id == meeting.id && c.speaker_id == assignment.id)
            });
            if known {
                continue;
            }
            match store.enroll_saved_name(
                meeting,
                assignment.id,
                &samples,
                same_person(name, &samples, &database.profiles),
                database.revision,
            ) {
                Ok(_) => enrolled += 1,
                Err(err) => {
                    log::info!("speaker voice not remembered meeting={}: {err}", meeting.id)
                }
            }
        }
        enrolled
    }

    /// Names given before call voices were remembered teach those voices
    /// once, then recent meetings get suggestions from every remembered voice.
    /// Saved transcripts never change here: a new name would mark their notes
    /// for refresh, so the meeting offers the names to apply instead.
    pub fn learn_from_saved_meetings(
        &self,
        meetings: &[Meeting],
        now: DateTime<Utc>,
        recent_days: i64,
        access: &dyn SavedMeetingAccess,
    ) {
        let recent_since = now - Duration::days(recent_days);
        let candidates: Vec<&Meeting> = meetings
            .iter()
            .filter(|m| !m.is_sample() && !m.is_live() && self.track_paths(m).system.is_some())
            .collect();
        // Without the key nothing can open; don't ask the store per meeting.
        if candidates.is_empty() || self.store().is_err() {
            return;
        }
        let (mut analyzed, mut named, mut renamed) = (0, 0, 0);
        // One failed analysis (no voice model yet) stops analysis for this pass.
        let mut can_analyze = true;
        for meeting in &candidates {
            if !can_analyze || access.cancelled() {
                break;
            }
            let Ok(saved) = self.state(meeting) else {
                continue;
            };
            if saved.call_voices_analyzed.is_some()
                || !self.has_saved_call_names(&saved, meeting, access)
            {
                continue;
            }
            match self.reidentify(meeting, true, access) {
                Revisit::Done => analyzed += 1,
                Revisit::Skipped => {}
                Revisit::AnalysisFailed => can_analyze = false,
            }
            named += self.enroll_saved_names(meeting);
        }
        for meeting in candidates.iter().filter(|m| m.started_at >= recent_since) {
            if access.cancelled() {
                return;
            }
            let Some(profiles) = self
                .store()
                .ok()
                .and_then(|s| s.profiles().ok())
                .map(|d| d.revision)
            else {
                continue;
            };
            if self.matched_revision.lock().get(&meeting.id) == Some(&profiles) {
                continue;
            }
            let Ok(saved) = self.state(meeting) else {
                continue;
            };
            let unanalyzed = saved.call_voices_analyzed.is_none();
            if !(unanalyzed && can_analyze) && !saved.assignments.iter().any(awaits_call_name) {
                continue;
            }
            match self.reidentify(meeting, unanalyzed, access) {
                Revisit::Done => {
                    self.matched_revision.lock().insert(meeting.id, profiles);
                    renamed += 1;
                }
                Revisit::Skipped => {}
                Revisit::AnalysisFailed => can_analyze = false,
            }
        }
        if analyzed + named + renamed > 0 {
            log::info!(
                "speaker voices learned meetingsAnalyzed={analyzed} savedNames={named} recentMeetingsChecked={renamed}"
            );
        }
    }
}

/// Why a choice was not applied.
#[derive(Debug, thiserror::Error)]
pub enum ChooseError {
    #[error(
        "This audio has not been separated into a reliable speaker. Reprocess transcription before confirming who spoke."
    )]
    UnseparatedAudio,
    #[error(transparent)]
    Store(#[from] Failure),
}
