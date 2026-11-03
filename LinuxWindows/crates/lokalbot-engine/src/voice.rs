//! Voice memory beside the pipeline (`AppState.learnSpeakerVoices`,
//! `MeetingSpeakerIdentityService.maintainRetention`): one [`VoiceMemory`] per
//! library, evidence expiry every hour, and a background pass that learns the
//! names people already gave.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::{Arc, LazyLock};
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow};
use crossbeam_channel::{Receiver, Sender, unbounded};
use parking_lot::Mutex;

use lokalbot_core::voice::{
    AudioTurn, Choice, ChooseError, DecisionAction, Failure, MicrophoneEvidence, NameMatch,
    SavedMeetingAccess, VoiceMemory, VoiceSample, reference_clock, select_microphone_samples,
};
use lokalbot_core::{Library, Meeting, Transcript};

use crate::Shared;
use crate::pipeline::Pipeline;

/// Whether a strong voice match names a speaker without asking, as on the Mac.
/// Off until TitaNet has been measured on real calls (see
/// `lokalbot_core::voice::matcher`): a wrong name attributes words to the wrong
/// person, and until then a person confirms each one with Apply Names.
pub const NAME_SPEAKERS_AUTOMATICALLY: bool = false;

const FIRST_LEARNING_DELAY: Duration = Duration::from_secs(60);
const LEARNING_DELAY: Duration = Duration::from_secs(2);
const RETENTION_INTERVAL: Duration = Duration::from_secs(3_600);
const BUSY_WAIT: Duration = Duration::from_secs(10);
const RECENT_MEETINGS_DAYS: i64 = 14;

static MEMORIES: LazyLock<Mutex<HashMap<PathBuf, Arc<VoiceMemory>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// The library's voice memory. Nothing opens the credential store until a
/// sealed file is actually needed.
pub fn memory(library: &Library) -> Arc<VoiceMemory> {
    let root = library.paths().root().to_path_buf();
    MEMORIES
        .lock()
        .entry(root)
        .or_insert_with(|| {
            Arc::new(VoiceMemory::new(
                library.clone(),
                Box::new(|| {
                    crate::secrets::speaker_identity_key(true).map_err(|err| format!("{err:#}"))
                }),
                |text| lokalbot_ai::sanitize::redaction(text).1 > 0,
            ))
        })
        .clone()
}

/// The microphone checks, reading the call track only if a sample needs it.
pub(crate) fn microphone_evidence(
    library: &Library,
    meeting: &Meeting,
    transcript: &Transcript,
    turns: &[AudioTurn],
    samples: &[VoiceSample],
) -> MicrophoneEvidence {
    let audio = library.audio(meeting);
    let clock = reference_clock(&library.meeting_dir(meeting));
    let mut pcm: Option<Option<Vec<f32>>> = None;
    let system = audio.system.as_deref();
    let mut remote = |start: f64, end: f64| -> Option<Vec<f32>> {
        let all = pcm
            .get_or_insert_with(|| lokalbot_audio::read_mono_16k(system?).ok())
            .as_ref()?;
        let at = |seconds: f64| (seconds * 16_000.0).round() as usize;
        all.get(at(start)..at(end)).map(<[f32]>::to_vec)
    };
    select_microphone_samples(
        samples,
        transcript,
        turns,
        system.is_some(),
        &clock,
        &mut remote,
    )
}

/// The running worker; [`Self::learn_soon`] asks for a pass.
pub(crate) struct VoiceWorker {
    requests: Sender<()>,
}

impl VoiceWorker {
    pub(crate) fn start(shared: Arc<Shared>, pipeline: Pipeline) -> Self {
        let (requests, receiver) = unbounded();
        let spawned = std::thread::Builder::new()
            .name("lokalbot-voice".into())
            .spawn(move || run(shared, pipeline, receiver));
        if let Err(err) = spawned {
            log::warn!("could not start voice memory upkeep: {err}");
        }
        Self { requests }
    }

    pub fn learn_soon(&self) {
        let _ = self.requests.send(());
    }
}

fn run(shared: Arc<Shared>, pipeline: Pipeline, requests: Receiver<()>) {
    let mut next_retention = Instant::now() + FIRST_LEARNING_DELAY;
    let mut next_learning = Some(Instant::now() + FIRST_LEARNING_DELAY);
    while !shared.is_shutting_down() {
        if requests.recv_timeout(Duration::from_secs(1)).is_ok() {
            next_learning = Some(Instant::now() + LEARNING_DELAY);
        }
        if Instant::now() >= next_retention {
            next_retention = Instant::now() + RETENTION_INTERVAL;
            maintain(&shared);
        }
        if next_learning.is_some_and(|at| Instant::now() >= at) {
            next_learning = None;
            learn(&shared, &pipeline);
        }
    }
}

/// Expires evidence by the retention window, with screen capture on or off.
fn maintain(shared: &Shared) {
    let library = &shared.library;
    let meetings = match library.list_all_meetings() {
        Ok(meetings) => meetings,
        Err(err) => {
            log::warn!("speaker evidence cleanup: {err:#}");
            return;
        }
    };
    let memory = memory(library);
    memory.expire(
        &meetings,
        shared.settings().retention_days,
        chrono::Utc::now(),
    );
    memory.revoke_removed_meetings(&meetings);
}

fn learn(shared: &Arc<Shared>, pipeline: &Pipeline) {
    let library = &shared.library;
    let meetings = match library.list_meetings() {
        Ok(meetings) => meetings,
        Err(err) => {
            log::warn!("speaker voices: {err:#}");
            return;
        }
    };
    let now = chrono::Utc::now();
    let access = SavedMeetings {
        shared: shared.clone(),
        pipeline: pipeline.clone(),
    };
    memory(library).learn_from_saved_meetings(&meetings, now, RECENT_MEETINGS_DAYS, &access);
    shared.emit(crate::EngineEvent::LibraryChanged);
}

struct SavedMeetings {
    shared: Arc<Shared>,
    pipeline: Pipeline,
}

impl SavedMeetings {
    fn capturing(&self) -> bool {
        self.shared.capture_active.load(Ordering::Relaxed)
    }
}

impl SavedMeetingAccess for SavedMeetings {
    fn transcript(&self, meeting: &Meeting) -> Option<Transcript> {
        self.shared.library.transcript(meeting).ok().flatten()
    }

    fn call_samples(&self, meeting: &Meeting, transcript: &Transcript) -> Result<Vec<VoiceSample>> {
        let library = &self.shared.library;
        let Some(track) = library.audio(meeting).system else {
            return Ok(Vec::new());
        };
        // Unavailable is not "no voices": the meeting is revisited later.
        let [_, voice_model] = lokalbot_speech::models::diarization_models() else {
            return Err(anyhow!("no voice model"));
        };
        if !self.shared.settings().multi_speaker_diarization
            || !lokalbot_speech::models::is_installed(library.paths(), voice_model)
        {
            return Err(anyhow!(
                "the voice model is not installed or speaker separation is off"
            ));
        }
        while self.capturing() || !self.pipeline.is_idle() {
            if self.cancelled() {
                return Err(anyhow!("shutting down"));
            }
            std::thread::sleep(BUSY_WAIT);
        }
        let threads = std::thread::available_parallelism()
            .map(|n| n.get().clamp(2, 8))
            .unwrap_or(4);
        lokalbot_speech::analyze_call_voices(library.paths(), &track, transcript, threads, &|| {
            self.cancelled() || self.capturing()
        })
    }

    fn is_busy(&self, meeting: &Meeting) -> bool {
        self.capturing() || self.pipeline.is_processing(meeting.id)
    }

    fn cancelled(&self) -> bool {
        self.shared.is_shutting_down()
    }

    fn select(
        &self,
        meeting: &Meeting,
        transcript: &Transcript,
        turns: &[AudioTurn],
        samples: Vec<VoiceSample>,
    ) -> MicrophoneEvidence {
        microphone_evidence(&self.shared.library, meeting, transcript, turns, &samples)
    }
}

/// Applies a person's choice and saves the transcript (`saveSpeakerAlias`,
/// `AppState.saveTranscript`). A name still counts when voices can't be
/// remembered here, say with no credential store or a library whose sealed
/// files came from another computer: it goes on the transcript alone.
pub fn save_choice(
    library: &Library,
    choice: &Choice,
    meeting: &Meeting,
    transcript: &Transcript,
) -> Result<Transcript> {
    save_choice_with(&memory(library), library, choice, meeting, transcript)
}

fn save_choice_with(
    memory: &VoiceMemory,
    library: &Library,
    choice: &Choice,
    meeting: &Meeting,
    transcript: &Transcript,
) -> Result<Transcript> {
    let names_a_speaker = matches!(
        choice.action,
        DecisionAction::Assign | DecisionAction::Reset
    );
    let updated = match memory.choose(choice, meeting, transcript) {
        Ok(updated) => updated,
        Err(ChooseError::Store(failure))
            if names_a_speaker
                && (matches!(failure, Failure::KeyUnavailable(_) | Failure::Corrupt)
                    || (matches!(failure, Failure::Stale)
                        && !memory.matches_transcript(meeting, transcript))) =>
        {
            log::info!("speaker name saved without voice memory: {failure}");
            memory.note_not_remembered(meeting.id, &failure);
            let mut plain = transcript.clone();
            plain.set_speaker_alias(
                choice.name.as_deref(),
                &choice.label,
                choice.calendar_identity_id.as_deref(),
            );
            plain
        }
        Err(err) => return Err(err.into()),
    };
    let updated = memory.applying_latest_decision(&updated, meeting.id);
    library.save_new_transcript(meeting, &updated)?;
    Ok(updated)
}

/// Applies every recognized name as if the user named each speaker.
pub fn apply_recognized_names(
    library: &Library,
    meeting: &Meeting,
    transcript: &Transcript,
    recognized: &[(String, NameMatch)],
) -> Result<Transcript> {
    let memory = memory(library);
    let mut current = transcript.clone();
    for (label, found) in recognized {
        current = memory.choose(
            &Choice::new(label, Some(found.name.clone()), DecisionAction::Assign),
            meeting,
            &current,
        )?;
    }
    let current = memory.applying_latest_decision(&current, meeting.id);
    library.save_new_transcript(meeting, &current)?;
    Ok(current)
}

/// Repairs a transcript when a name was recorded but the save was interrupted.
pub fn recover_saved_names(library: &Library, meeting: &Meeting) -> Result<bool> {
    let Some(transcript) = library.transcript(meeting)? else {
        return Ok(false);
    };
    let memory = memory(library);
    let recovered =
        memory.applying_latest_decision(&memory.recover(meeting, &transcript)?, meeting.id);
    if recovered.segments == transcript.segments
        && recovered.speaker_aliases == transcript.speaker_aliases
        && recovered.speaker_calendar_identity_ids == transcript.speaker_calendar_identity_ids
    {
        return Ok(false);
    }
    library.save_new_transcript(meeting, &recovered)?;
    Ok(true)
}

/// Deletes a meeting and takes it and its merged sources out of remembered
/// voices first. The delete goes ahead when voices can't be opened: it is what
/// the person asked for, the upkeep pass finishes the cleanup once they can,
/// and the returned text says so rather than claiming it happened.
pub fn delete_meeting(library: &Library, meeting: &Meeting) -> Result<Option<String>> {
    let memory = memory(library);
    let mut pending = None;
    for item in library.deletion_order(meeting)? {
        if let Err(err) = memory.prepare_deletion(&item) {
            log::warn!("speaker voice not forgotten meeting={}: {err}", item.id);
            pending = Some(lokalbot_i18n::format(
                "The meeting was deleted, but its voices could not be removed from remembered people yet: {err}",
                &[("err", err.to_string())],
            ));
        }
    }
    library.delete_meeting(meeting)?;
    Ok(pending)
}

#[cfg(test)]
mod tests {
    use lokalbot_core::model::{
        AttributionMethod, AttributionSource, Segment, SpeakerAttribution, SpeakerIdentity,
    };
    use lokalbot_core::voice::Decision;
    use lokalbot_core::{LibraryPaths, library::REFRESH_MARKER};

    use super::*;

    fn fixture() -> (tempfile::TempDir, Library, Meeting, Transcript) {
        let dir = tempfile::tempdir().unwrap();
        let library = Library::open(LibraryPaths::new(dir.path().to_path_buf())).unwrap();
        let mut meeting = library
            .create_meeting("Call", "Zoom", lokalbot_core::time::now_seconds())
            .unwrap();
        meeting.ended_at = Some(lokalbot_core::time::now_seconds());
        library.save_meeting(&meeting).unwrap();
        let transcript = Transcript {
            segments: vec![Segment {
                start: 0.0,
                end: 6.0,
                speaker: "them 1".into(),
                text: "Words said here".into(),
                confidence: None,
                timing_precision: None,
                attribution: Some(SpeakerAttribution {
                    source: AttributionSource::System,
                    identity: SpeakerIdentity::Other,
                    method: AttributionMethod::Diarization,
                }),
            }],
            engine: "test".into(),
            ..Default::default()
        };
        library.save_new_transcript(&meeting, &transcript).unwrap();
        (dir, library, meeting, transcript)
    }

    fn sealed(library: &Library, key: [u8; 32]) -> VoiceMemory {
        VoiceMemory::new(library.clone(), Box::new(move || Ok(key)), |_| false)
    }

    fn write_notes(library: &Library, meeting: &Meeting) {
        library.save_summary(meeting, "# Notes").unwrap();
    }

    #[test]
    fn renaming_marks_the_notes_stale() {
        let (_dir, library, meeting, transcript) = fixture();
        write_notes(&library, &meeting);
        let memory = sealed(&library, [3; 32]);
        let saved = save_choice_with(
            &memory,
            &library,
            &Choice::new("them 1", Some("Ana".into()), DecisionAction::Assign),
            &meeting,
            &transcript,
        )
        .unwrap();
        assert_eq!(saved.speaker_aliases["them 1"], "Ana");
        assert_eq!(library.transcript(&meeting).unwrap().unwrap(), saved);
        let folder = library.meeting_dir(&meeting);
        assert!(folder.join(REFRESH_MARKER).is_file());
        assert!(!folder.join(lokalbot_core::library::SUMMARY_FILE).exists());
        assert!(folder.join("summary.previous.md").is_file());
        assert!(library.notes_marked_stale(&meeting));
        let state = memory.state(&meeting).unwrap();
        let decision: &Decision = state.decisions.last().unwrap();
        assert_eq!(decision.action, DecisionAction::Assign);
    }

    #[test]
    fn a_name_still_saves_when_voices_cant_be_remembered() {
        let (_dir, library, meeting, transcript) = fixture();
        write_notes(&library, &meeting);
        let memory = VoiceMemory::new(
            library.clone(),
            Box::new(|| Err("no credential store".to_string())),
            |_| false,
        );
        let saved = save_choice_with(
            &memory,
            &library,
            &Choice::new("them 1", Some("Ana".into()), DecisionAction::Assign),
            &meeting,
            &transcript,
        )
        .unwrap();
        assert_eq!(saved.speaker_aliases["them 1"], "Ana");
        assert!(
            library.notes_marked_stale(&meeting),
            "still invalidates notes"
        );
        assert!(
            memory
                .notice_for(meeting.id)
                .unwrap()
                .contains("Name saved")
        );
        let folder = library.meeting_dir(&meeting);
        assert!(!folder.join(lokalbot_core::voice::EVIDENCE_FOLDER).exists());
        // Resetting works the same way.
        let reset = save_choice_with(
            &memory,
            &library,
            &Choice::new("them 1", None, DecisionAction::Reset),
            &meeting,
            &saved,
        )
        .unwrap();
        assert!(reset.speaker_aliases.is_empty());
    }

    #[test]
    fn another_computers_sealed_files_survive_a_rename_untouched() {
        let (dir, library, meeting, transcript) = fixture();
        // Files a Mac sealed with its own key.
        let mac = sealed(&library, [9; 32]);
        let named = mac
            .choose(
                &Choice::new("them 1", Some("Ana".into()), DecisionAction::Assign),
                &meeting,
                &transcript,
            )
            .unwrap();
        mac.store().unwrap().forget_profile(None).unwrap();
        let identity = library
            .meeting_dir(&meeting)
            .join(lokalbot_core::voice::EVIDENCE_FOLDER)
            .join(lokalbot_core::voice::IDENTITY_FILE);
        let profiles = dir.path().join(lokalbot_core::voice::PROFILES_FILE);
        let before = (
            std::fs::read(&identity).unwrap(),
            std::fs::read(&profiles).unwrap(),
        );

        let here = sealed(&library, [1; 32]);
        let saved = save_choice_with(
            &here,
            &library,
            &Choice::new("them 1", Some("Marko".into()), DecisionAction::Assign),
            &meeting,
            &named,
        )
        .unwrap();
        assert_eq!(saved.speaker_aliases["them 1"], "Marko");
        assert_eq!(
            before,
            (
                std::fs::read(&identity).unwrap(),
                std::fs::read(&profiles).unwrap()
            )
        );
        // Processing and expiry leave them alone too.
        assert!(here.state(&meeting).is_err());
        here.expire(
            std::slice::from_ref(&meeting),
            1,
            chrono::Utc::now() + chrono::Duration::days(30),
        );
        assert_eq!(std::fs::read(&identity).unwrap(), before.0);
        assert_eq!(std::fs::read(&profiles).unwrap(), before.1);
    }

    #[test]
    fn a_stale_journal_doesnt_block_a_name_for_a_newer_transcript() {
        let (_dir, library, meeting, transcript) = fixture();
        let memory = sealed(&library, [3; 32]);
        let named = save_choice_with(
            &memory,
            &library,
            &Choice::new("them 1", Some("Ana".into()), DecisionAction::Assign),
            &meeting,
            &transcript,
        )
        .unwrap();
        // Transcript-only sources were added after the journal was written.
        let mut changed = named.clone();
        changed.segments[0].end = 9.0;
        let saved = save_choice_with(
            &memory,
            &library,
            &Choice::new("them 1", Some("Marko".into()), DecisionAction::Assign),
            &meeting,
            &changed,
        )
        .unwrap();
        assert_eq!(saved.speaker_aliases["them 1"], "Marko");
    }
}
