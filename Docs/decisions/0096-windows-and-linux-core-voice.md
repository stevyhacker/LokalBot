# 0096. Windows and Linux: core — voice

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/voice/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/voice/evidence.rs`

#### A microphone counts as voice evidence only when no call audio could reach it
Which voice samples may count (`AttributedTrackTranscriber.turns/samples`,
`SpeakerMicrophoneEvidence.swift`). A microphone is an audio source, not a
person: its samples count only when nothing from the call could have
reached it.

#### Label backed only by one speaker-separation label covering enough of range
`supported_speaker`: A transcript label backing `range`: one label, all of it from speaker
separation, covering at least `coverage` of the range.

#### Diarizer turns overlapped by another voice are left out
`label_turns`: Raw diarizer turns as turns of transcript labels. A turn another voice
overlaps is left out.

#### Call speech pauses are not another person; model hears only own frames
`label_samples`: Samples renamed to the transcript's labels. Call speech pauses between
sentences, and the voice model hears only the speaker's own frames, so a
pause is not another person.

#### Records kept samples and the reason each was kept or not
`MicrophoneEvidence`: What `select_microphone_samples` kept, and why each microphone sample
was or was not kept.

#### Microphone samples pass echo checks; call samples pass through; remote_pcm is 16 kHz
`select_microphone_samples`: Microphone samples pass the echo checks; call samples pass through.
`remote_pcm` reads the call track's 16 kHz samples for a range.

#### Padding allows playback delay; diarizer miss is not silence, so check waveform
`select_microphone_samples`: The padding includes plausible playback-to-microphone delay. A
diarizer miss is not silence; verify the actual waveform too.

#### Test short windows and peak so brief remote syllable is not averaged away
`reference_is_quiet`: Tests short windows as well as the peak, so a brief remote syllable cannot
disappear in the mean of a long silent interval.

### `LinuxWindows/crates/lokalbot-core/src/voice/matcher.rs`

#### Scores are Mac's; TitaNet checked but uncalibrated on real calls, so matches only suggested
Voice comparison and enrollment rules (`SpeakerVoiceMatcher.swift`).

The scores are the Mac's, measured there on pyannote vectors from real
calls. On TitaNet they were checked with `voice_calibration` and
`voice_meeting_check` (LibriSpeech dev-clean, 40 speakers, through Opus and
varied channels): no wrong automatic decision, but different people reached
0.72 through one narrow noisy channel, and no real call has been measured.
So the engine shows strong matches for a person to apply; see
`NAME_SPEAKERS_AUTOMATICALLY` in `lokalbot-engine`.

#### Codec-compressed call chunks vary; speaker average over many turns is stable
`call`: Call audio arrives codec-compressed, so a single 3–10 s chunk varies too
much to compare on its own; a speaker's average over many turns is stable.

#### Median sample-to-average similarity; mixed-voice labels fall below
`call::MINIMUM_CONSISTENCY`: Median sample-to-average similarity. A label that mixes voices falls below it.

#### Margin over best remembered person with a different name
`call::AUTOMATIC_MARGIN`: Over the best remembered person with a different name.

#### Each confirmed meeting counts once toward a person's call voice
`call_voiceprint`: A remembered person's call voice: each confirmed meeting counts once.

#### One disjoint chunk per independent uncontaminated turn; overlapping windows never extra votes
`eligible`: At most one disjoint chunk from each independent, uncontaminated speaking
turn. Overlapping diarizer windows are never extra votes.

#### A mixed cluster is unsafe to enroll even if some samples agree
`eligible`: A mixed cluster is unsafe to enroll, even if some of its samples agree.

#### Longest disjoint non-overlapped chunks; average checked for mixed voice
`call_eligible`: Call speakers: the longest disjoint chunks no other speaker overlaps,
wherever they fall. Their average is checked for a mixed voice instead of
every pair.

#### Enrollment needs three separate turns, 15 seconds, one voice
`can_enroll`: Three separate turns of clear speech totaling 15 seconds, from one voice.

#### Microphone recognition requires its own held-out calibration
`matches`: Microphone recognition requires its own held-out calibration.

#### One average per call speaker; same-name people never block each other
`call_matches`: One average per call speaker against each remembered person's average.
Remembered people who share a name never block each other.

### `LinuxWindows/crates/lokalbot-core/src/voice/mod.rs`

#### Voice memory file format, per-install key, private scope and TitaNet vs pyannote spaces
Voice memory (`MeetingSpeakerEvidence.swift`, `SpeakerVoiceProfile.swift`,
`SpeakerVoiceMatcher.swift`, `SpeakerIdentityResolver.swift`,
`MeetingSpeakerEvidenceStore.swift`, `MeetingSpeakerIdentityService.swift`).

Naming a speaker teaches an encrypted voice profile; later meetings offer
or apply the name. Everything here is private: it stays out of the
transcript model, search, exports, the CLI and prompts.

\# Files

`speaker-profiles/profiles.sealed` under the library root and
`speaker-evidence/identity.sealed` in a meeting's folder, as on macOS: the
`Codable` JSON sealed with AES-256-GCM as `nonce ‖ ciphertext ‖ tag`, with
the file's path under the root as associated data. The key is per install
and lives in the system credential store, so a Mac's files don't open here.
That reads as an error, never as empty, so they are not overwritten.

\# Models

Every sample and profile names the voice model that made it. This port uses
TitaNet where the Mac uses pyannote; the two spaces are not comparable, so
only vectors of [`VOICE_MODEL`] are ever scored or added to.

#### Changed model or preprocessing needs new value, leaving old profiles unmatched
`VOICE_MODEL`: The voice model this app's vectors come from. A changed model or
preprocessing needs a new value, which leaves older profiles unmatched.

#### TitaNet vectors are 192 long; Mac pyannote vectors are 256
`VOICE_DIMENSION`: TitaNet's vector length. The Mac's pyannote vectors have 256.

#### Bump when call voice analysis changes so meetings are revisited once
`CALL_VOICES_VERSION`: Bumped when call voices start being analyzed differently, so saved
meetings are revisited once (`callVoicesVersion`).

#### A span of a track, in seconds
`TurnAnchor`: A span of a track, in seconds (`SpeakerTurnAnchor`).

#### Merge same-speaker neighbours within 0.5 seconds, as VisualSpeakerMatcher
`merged_turns`: `VisualSpeakerMatcher.mergedTurns`: same-speaker neighbours within 0.5 s.

#### Safe speaker names: 2-80 characters, no address, URL, control or secret
`safe_name`: A speaker's display name is safe to keep and teach (`safeName`): 2–80
characters with no address, URL, control character or a secret that
`has_secret` finds, and not a word meeting apps show for people.

#### Case- and accent-insensitive name key, as ParticipantObservation.nameKey
`name_key`: Case- and accent-insensitive key for names (`ParticipantObservation.nameKey`).

#### Retired Google Meet naming still decoded from saved meetings
`MatchSource::Visual`: The retired Google Meet naming; saved meetings still decode it.

#### A person's name is never replaced by automatic work
`Origin.is_protected`: A name from a person: automatic work never replaces it.

#### Local-user flag independent of display alias, even one spelled Me
`Assignment.is_local_user`: Independent of a display alias, including an alias spelled "Me".

#### Set once call voices analyzed; earlier meetings revisited once
`IdentityState.call_voices_analyzed`: Set once call voices were analyzed; meetings processed before that are
revisited once.

#### Drives the Notes need a refresh notice
`IdentityState.latest_attribution_change`: When the speakers last changed, for "Notes need a refresh".

#### Call voices store the average of eligible chunks instead of chunks
`Contribution.voiceprint`: Call voices keep the average of every eligible chunk instead of the chunks.

#### Swift Set of UUID encodes as array of uppercase strings
`uuid_set`: A Swift `Set<UUID>`: an array of uppercase strings.

### `LinuxWindows/crates/lokalbot-core/src/voice/resolver.rs`

#### Clean split inherits names; merge of people or ambiguous overlap cannot
`remap`: Match by retained turns in the same audio revision. A clean split can
inherit; a merge of different people or any ambiguous overlap cannot.

#### A different name is withdrawn into review, never silently replaced
`apply`: Applies voice matches to an unprotected assignment and returns the ones to
offer. A different name is withdrawn into review, never silently replaced.

### `LinuxWindows/crates/lokalbot-core/src/voice/service.rs`

#### Journal per meeting; only a person's choice decides a name
Meeting speaker identity (`MeetingSpeakerIdentityService.swift`): one
object per library that keeps a durable journal for each meeting, and only
ever lets a person's choice decide a name.

#### Revision format mic:sha|system:sha, else fallback hash
`recording_revision`: `mic:<sha>|system:<sha>` for the tracks that exist, or `fallback`'s hash.

#### Match Swift Double.description formatting for revision strings
`swift_double`: Swift's `Double.description`: `1.0`, `0.5`, `1e-05`, `1e+16`.

#### Signature ties a state's labels to a speaker timeline
`transcript_signature`: Identifies the speaker timeline a state's labels were made for.

#### User-given or legacy transcript call name counts as saved
`is_saved_call_name`: A name the user gave a call voice, or a legacy name the transcript still carries.

#### Unnamed call voice that automatic naming may still fill
`awaits_call_name`: An unnamed call voice that automatic naming may still fill.

#### Only clear single-person voice matches count as recognized
`recognized_speakers`: Unnamed call speakers whose voice clearly matches one remembered person.

#### Same name and agreeing voice reuse person so naming never splits them
`same_person`: The remembered person a newly named voice belongs to: same name and an
agreeing voice, so naming someone again never splits them in two. A person
known only from the other source has nothing to compare and is reused.

#### Earlier names carry over when no journal exists yet
`ProcessRequest.previous`: What was saved before: its names carry over when no journal exists yet.

#### False keeps matches as suggestions for saved meetings with notes from current names
`ProcessRequest.name_automatically`: `false` keeps automatic matches as suggestions, for saved meetings
whose notes were written from the current names.

#### Err means analysis cannot run now
`SavedMeetingAccess.call_samples`: Analyzes a meeting's call track; `Err` means analysis can't run now.

#### Errors never fail transcription; caller keeps transcript and shows notice
`VoiceMemory`: `MeetingSpeakerIdentityService`. Errors never fail audio transcription: a
caller keeps its transcript and shows [`Self::notice`].

#### Profile database revision each recent meeting was last matched against
`VoiceMemory.matched_revision`: Profile database revision each recent meeting was last matched against.

#### Name saved onto transcript without teaching a voice
`VoiceMemory.note_not_remembered`: A name went on the transcript without teaching a voice.

#### Reapply human decision before write so automatic results cannot overwrite it
`VoiceMemory.applying_latest_decision`: The final projection immediately before a transcript write: an
automatic result finishing after a human correction cannot overwrite it.

#### Recover interrupted sidecar pair without stale ordinal mapping to another transcription
`VoiceMemory.recover`: Recovers an interrupted sidecar/transcript pair without applying a
stale ordinal mapping to a different transcription.

#### Names transcription from remembered voices, carrying over earlier decisions
`VoiceMemory.process`: Names a finished transcription from remembered voices, carrying over
what people decided before. Returns the transcript to save.

#### Sample meeting's synthetic voices are never remembered or matched
`VoiceMemory.process`: The sample meeting's synthetic voices are never remembered or matched.

#### Legacy aliases have human authority but only carry across retranscription
`VoiceMemory.process`: Legacy aliases have human authority, but only use their old
turns to carry them across retranscription.

#### Calendar names are a fallback; reliable disagreement is reviewable
`VoiceMemory.process`: Calendar is a fallback only; reliable disagreement is reviewable.

#### Keep detached decisions for manual reassignment when merge blocks safe remap
`VoiceMemory.process`: Preserve detached decisions for manual reassignment when a merge
prevents a safe remap. They cannot project onto a current label.

#### Pipeline reapplies this cache right before writing
`VoiceMemory.process`: The pipeline reapplies this cache right before writing.

#### Keep human choices if deletion races processing; discard pending evidence
`VoiceMemory.process`: Keep durable human choices and historical aliases when a
deletion races processing, but discard all pending evidence.

#### Choosing a suggested profile is explicit confirmation, even of local user
`VoiceMemory.choose`: Choosing a suggested profile is an explicit confirmation
of that person, including a confirmed local user.

#### Human distinction between split labels is preserved on remapping
`VoiceMemory.choose`: A human distinguished two labels previously inferred to be a
clean split. Preserve that distinction on subsequent remapping.

#### Revoke old confirmation before correction; failure leaves visible pending state
`VoiceMemory.choose`: Revoke an old confirmation before recording a correction. A failure
leaves a visible pending state instead of training on the wrong person.

#### Every name the user gives teaches that voice
`VoiceMemory.choose`: Every name the user gives teaches LokalBot that voice.

#### Another correction could arrive during enrollment
`VoiceMemory.choose`: Another correction could arrive while enrollment ran.

#### Deleted meeting contributions leave profiles once they can be opened
`VoiceMemory.revoke_removed_meetings`: A meeting can be deleted while remembered voices can't be opened (the
credential store was out of reach, say). Its contributions leave them
the next time they can.

#### Evidence expires by screen retention window even with capture off
`VoiceMemory.expire`: Expires evidence by the screen retention window, even with capture off.

#### Meetings named before speaker review keep names only in transcript
`has_saved_call_names`: Meetings named before speaker review existed keep their names only
in the transcript.

#### Re-identify offers suggestions only; nothing saved to transcript
`VoiceMemory.reidentify`: Re-runs identification for a saved transcript, analyzing its call
track first when needed. Matches become suggestions; nothing is saved
to the transcript.

#### Saved names follow turns of the same recording only
`VoiceMemory.reidentify`: Saved names follow audio turns of the same recording only.

#### Saved transcripts never change here because it would mark notes for refresh
`VoiceMemory.learn_from_saved_meetings`: Names given before call voices were remembered teach those voices
once, then recent meetings get suggestions from every remembered voice.
Saved transcripts never change here: a new name would mark their notes
for refresh, so the meeting offers the names to apply instead.

#### Skip per-meeting store checks when the key is unavailable
`VoiceMemory.learn_from_saved_meetings`: Without the key nothing can open; don't ask the store per meeting.

#### One failed analysis stops analysis for this pass
`VoiceMemory.learn_from_saved_meetings`: One failed analysis (no voice model yet) stops analysis for this pass.

### `LinuxWindows/crates/lokalbot-core/src/voice/store.rs`

#### Serial authority; durable decision commits before its transcript projection
One serial authority for evidence, assignment journals and profile
mutations (`MeetingSpeakerEvidenceStore.swift`). A durable decision is
committed before its public transcript projection.

#### Locked or unreachable file is unavailable, not corrupt ciphertext
`Failure::Io`: A locked or unreachable file is unavailable, not corrupt ciphertext.

#### Serializes read-modify-write; files replaced atomically
`Store.lock`: Serializes read-modify-write cycles. Files are replaced atomically.

#### Associated data path uses slash separators on every platform
`Store.seal`: `/`-separated on every platform, so a file's associated data never
depends on the system that wrote it.

#### write_atomic keeps files owner-only; bytes are ciphertext
`Store.write`: `write_atomic` keeps these owner-only, and the bytes are ciphertext.

#### Keep bounded recent decisions; assignments hold durable authority
`Store.commit_inner`: Retain only bounded recent event metadata; assignments hold durable authority.

#### Everything beside identity journal is retired speaker observation
`Store.remove_retired_observations`: Everything beside the identity journal is retired speaker observation.

#### Erase samples, suggestions, timelines; keep names, corrections, suppressions
`Store.erase_evidence`: Deletes samples, suggestions and timelines, keeping applied names,
corrections, suppression choices and the turns that hold them.

#### Old evidence goes; recent voice samples stay for remembering
`Store.expire`: Evidence older than the retention window goes; recent voice samples
stay available for remembering.

#### Foreign-key files stay and must not block later meetings
`Store.expire`: Another computer's file can't be opened here and stays as it
is; it must not hold back every meeting after it.

#### Legacy names use assignment ID as decision so correction revokes it
`Store.enroll_saved_name`: A name the user gave before call voices were remembered. Legacy names
have no decision, so the assignment ID stands in for one: a later
correction revokes it like any other contribution.

#### Every named call participant is remembered, leave room for a company
`Store.enroll_saved_name`: Every named call participant is remembered, so leave room for a whole company.

#### Revoking removes meeting contributions; profile left with none is forgotten
`Store.revoke`: Takes a meeting's contributions out of every profile; a profile left
with none is forgotten.

#### Call voices store average plus one chunk to stay within file limit
`contribution`: Call voices store their average and one chunk for provenance, which keeps
a busy team's profiles well inside the file limit.

### `LinuxWindows/crates/lokalbot-core/src/voice/tests.rs`

#### Swift Codable: dates seconds since 2001, UUIDs uppercase, sets arrays
`reads_the_macs_state_and_profile_json`: Derived from the Swift `Codable` types: dates are seconds since 2001,
UUIDs are uppercase and sets are arrays.

#### Keys the Mac decoder requires are always written
`reads_the_macs_state_and_profile_json`: Keys the Mac's decoder requires are always written.

#### Sealed layout nonce, ciphertext, tag with path as AAD
`sealed_files_use_the_macs_layout_and_a_foreign_key_is_never_overwritten`: nonce ‖ ciphertext ‖ tag, with the file's path under the root as AAD.

#### Files sealed with another install's key error and stay untouched
`sealed_files_use_the_macs_layout_and_a_foreign_key_is_never_overwritten`: Files sealed with another install's key read as an error and stay as they are.

#### Foreign-key database blocks every profile change
`sealed_files_use_the_macs_layout_and_a_foreign_key_is_never_overwritten`: A database from another key blocks every profile change the same way.

#### Undo clears name and keeps automatic naming away from speaker
`naming_teaches_a_voice_and_a_later_meeting_is_named_with_undo`: Undo clears it and keeps automatic naming away from this speaker.

#### Mac-made samples are unusable here whatever their length
`profiles_of_another_voice_model_are_never_compared_or_added_to`: Samples the Mac made are not ours to use, whatever their length.

#### Applying a suggestion is confirmation and teaches the voice
`suggesting_only_leaves_names_to_a_person_and_a_strong_match_is_recognized`: Applying it is a person's confirmation, and teaches the voice.

### `LinuxWindows/crates/lokalbot-core/src/voice/timing.rs`

#### Mac anchors tracks by clock; this app pads both on one shared timeline
How the microphone and call tracks line up (`RecordingAudioTiming`).

A Mac keeps `audio-timing.json` with clock anchors. This app writes both
tracks on one shared meeting timeline, padding any gap with silence, so a
`.wav` recording needs no anchors: the same second is the same second.

#### Map bounds through one continuous span; never extrapolate across gaps
`RecordingAudioTiming.reference_range`: Maps both bounds through one continuous span on each track. Padding
and device gaps have no anchors, so this never extrapolates across them.

#### WAV tracks padded to one timeline, no anchors, or quiet-call check always fails
`reference_clock`: This app pads both WAV tracks to one timeline and writes no anchors.
Without this, a microphone voice could never pass the quiet-call check.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
