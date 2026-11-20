# 0050. Mac app: Speakers

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Speakers/`, `LokalBot/Services/Speakers/`, `LokalBotTests/Models/Speakers/`, `LokalBotTests/Services/Speakers/`.

## Decisions

### `LokalBot/Models/Speakers/DiarizationModel.swift`

#### Identity invalidates partial transcripts when model, weights or turn policy change
`DiarizationModel.checkpointIdentity`: Invalidate partial transcripts when the model, weights, or turn policy changes.

### `LokalBot/Models/Speakers/MeetingSpeakerEvidence.swift`

#### Speaker sidecar models are private, excluded from Transcript and CLI
Private sidecar models. Deliberately excluded from Transcript and the CLI.

#### Display-name rules shared by assignments, profiles and suppression
`ParticipantObservation`: Speaker display-name rules shared by assignments, profiles and suppression.

#### visual source is from retired Google Meet naming; saved meetings still decode
`SpeakerNameMatch.Source`: `visual` came from the retired Google Meet naming; saved meetings still decode it.

#### Local-user flag is independent of display alias, even Me
`SpeakerIdentityAssignment.isLocalUser`: Independent of a display alias, including an alias spelled "Me".

#### Set once call voices analyzed; earlier meetings revisited once
`MeetingSpeakerIdentityState.callVoicesAnalyzed`: Set once call voices were analyzed; meetings processed before that are revisited once.

### `LokalBot/Models/Speakers/MeetingSpeakerNaming.swift`

#### ID is the transcript's canonical speaker key
`MeetingSpeakerNamingVoice.id`: The transcript's canonical speaker key.

#### Recognized name offered preselected but still needs saving
`MeetingSpeakerNamingVoice.recognizedName`: A name this voice matched from earlier meetings. It is offered already
picked, and still needs saving.

#### Distinguishes voice-recognized names from names the reader chose
`MeetingSpeakerNamingKnown.wasRecognized`: Named by voice recognition, not by the person reading the meeting.

#### Voices with actions first; user's own voice in neither list
`MeetingSpeakerNaming.lists`: Voices to name, those with actions first, and the speakers already
named. The user's own voice is in neither list.

#### One person is one voice; picking a name moves it from the first voice
`MeetingSpeakerNamingDraft`: What has been picked in the naming sheet before it is saved. One person is
one voice: picking a name for a second voice takes it from the first.

#### Pick ID identifies the chip: guest, suggestion or recognized name
`MeetingSpeakerNamingDraft.Pick.id`: Identifies the chip: an invited guest, a suggested name, or the
recognized name.

#### Two voices cannot start as the same guest
`MeetingSpeakerNamingDraft.init`: Two voices cannot both start as the same guest.

#### Recognized name matching a guest reuses that pick to keep calendar identity
`MeetingSpeakerNamingDraft.recognizedPick`: The pick for a name recognized by voice. When that name is one of the
suggestions (an invited guest), it is that suggestion's pick, so the
guest's calendar identity is kept.

#### Choices follow sheet order; untouched voices are skipped
`MeetingSpeakerNamingDraft.choices`: The names to save, in the sheet's order. Voices left alone are skipped.

### `LokalBot/Models/Speakers/MeetingSpeakerReviewItem.swift`

#### Review items are local projections, never identity guesses or inference input
`MeetingSpeakerReviewItem`: A local review projection, never an identity guess or an inference input.

#### Sample favors enough speech to recognize voice, caps long monologues
`MeetingSpeakerReviewItem.sampleScore`: Prefer enough speech to recognize a voice, without rewarding long monologues.

### `LokalBot/Models/Speakers/MeetingSpeakerSuggestion.swift`

#### Combines picker choices only, never attribution or persisted identities
`MeetingSpeakerSuggestion`: Combines picker choices, never speaker attribution or persisted identities.

#### Same-named guests stay separate with own calendar identity
`MeetingSpeakerSuggestion.choices`: Same-named guests stay separate: each keeps its own calendar identity.

#### Every query word must match name or email, ignoring case and accents
`MeetingSpeakerSuggestion.matches`: Every query word must appear in the name or email address, ignoring
case and accents, so "petrovic ana" finds "Ana Petrović".

#### d with stroke has no decomposition; people type d or dj
`MeetingSpeakerSuggestion.matches`: "đ" has no accent-free decomposition; people type it as "d" or "dj".

### `LokalBot/Models/Speakers/SpeakerAttribution.swift`

#### Public meeting-local provenance; voice vectors stay in encrypted identity store
`SpeakerAttribution`: Public, meeting-local provenance. Voice vectors and cross-meeting profile
identifiers remain in the encrypted identity store.

#### My microphone is me defaults on; shared rooms can disable it
`SpeakerAttribution.microphoneIsUser`: Settings → “My microphone is me”. On by default: the personal
microphone belongs to this Mac's user. Shared-room recordings can turn
it off so microphone voices stay unidentified until confirmed.

#### Only track, diarization and legacy mic speech follows the preference
`SpeakerAttribution.applyingMicrophoneDefault`: Microphone track/diarization/legacy speech follows the preference above,
including older persisted defaults. Confirmations, voice profiles,
overlapping voices, and suspected echo keep their own identity.

#### Content-free reason retained even when ownership cannot be applied
`OutcomeAttribution.rejectionReason`: Content-free explanation retained even when ownership cannot be applied.

### `LokalBot/Models/Speakers/SpeakerBleedFilter.swift`

#### Remove mic segments only for whole, precisely timed remote matches; keep ambiguous ones
`SpeakerBleedFilter`: Removes a microphone segment only when a complete, precisely timed remote
segment carries the same utterance at the same time.

This is intentionally conservative. Segment overlap cannot localize a phrase
within a long ASR block, and partially trimming text without word timestamps
would leave the surviving words attached to false evidence timestamps. An
ambiguous segment therefore survives unchanged; the raw system track remains
the clean source when a whole mic span is proven to be speaker bleed.

#### Mic default identity must not hide candidates for audio echo check
`SpeakerBleedFilter.Result.acousticCandidateIndices`: Whole-span lexical matches eligible for an independent audio check.
A microphone's default user identity must not hide these candidates.

#### No destructive decisions on blocks over 15 s, possibly fallback windows
`SpeakerBleedFilter.maximumComparableSpanDuration`: Longer blocks may be whole-track or fixed-window fallbacks even when
their outer timestamps are known. Do not make destructive decisions on
text whose words could be far apart inside the block.

#### Allow 0.75 s boundary drift between independent ASR passes
`SpeakerBleedFilter.maximumBoundaryDrift`: Independent ASR passes can place the same utterance boundary slightly
differently, but both edges must still describe the same short span.

#### Few generic words are plausible simultaneous speech, not echo proof
`SpeakerBleedFilter.minimumWordTokenCount`: A few generic words are plausible simultaneous speech, not proof of echo.

#### Ideographic characters carry less evidence than words, so need more
`SpeakerBleedFilter.minimumIdeographicTokenCount`: Ideographic tokens are characters and carry less evidence than words.

#### Hard bounds keep the main-actor step linear on malformed content
`SpeakerBleedFilter.maximumComparableTextBytes`: Hard bounds keep this synchronous pipeline step linear and predictable on
the main actor, including for malformed or legacy transcript content.

#### Keep genuine repetitions unless waveform supports removal; mic default is not confirmation
`SpeakerBleedFilter.filter`: A genuine repetition can have identical words and timing.
Preserve it unless the waveform independently supports removal.
A microphone default is not an explicit speaker confirmation
and must not prevent independently proven echo removal.

#### 0.8 word coverage of overlapping remote utterance marks possible echo
`SpeakerBleedFilter.minimumEchoWordCoverage`: Share of a microphone utterance's words that must appear in one
time-overlapping remote utterance for ownership evidence to treat it as
possible speaker echo.

#### Independent ASR passes may cut echoed utterance differently, allow 2 s gap
`SpeakerBleedFilter.maximumEchoTimeGap`: Independent ASR passes may cut the same echoed utterance differently.

#### Near-duplicate echo only withholds mic default identity, never deletes text
`SpeakerBleedFilter.nearDuplicateEchoIndices`: Microphone segments that mostly repeat simultaneous remote speech.
Unlike `filter`, this needs no exact span or token equality and never
deletes text; callers only withhold the microphone's default identity,
so a remote participant's words cannot become the user's evidence.

#### Generous look-back plus candidate cap keeps echo scan linear
`SpeakerBleedFilter.nearDuplicateEchoIndices`: Remote spans are bounded by fixed transcription windows, so a
generous look-back plus a candidate cap keeps this linear.

#### Crowded or same-timestamp candidate sets are ambiguous; stop to bound work
`SpeakerBleedFilter.filter`: Crowded or pathological timing is ambiguous. Stop before work can
grow with an unbounded same-timestamp segment set.

#### Keep apostrophes inside words so contractions cannot bypass generic-utterance guard
`SpeakerBleedFilter.comparisonTokens`: Case- and punctuation-insensitive lexical tokens for whole-span equality.
Apostrophes inside a word stay inside it, so short contractions cannot
manufacture enough tokens to bypass the generic-utterance guard.

#### Suspected echo keeps words and IDs but loses mic default identity
`Transcript.markingSuspectedEcho`: Ownership-evidence snapshot: likely microphone echo keeps its words and
segment IDs but loses the microphone's default identity.

### `LokalBot/Models/Speakers/SpeakerVoiceProfile.swift`

#### Fingerprint is a compatibility identifier; vectors verified across FluidAudio versions
`SpeakerVoiceSample.fingerprint`: Compatibility identifier, not the current library version. FluidAudio
0.17.5 keeps the pinned Pyannote weights/preprocessing and 256-D space;
NemotronRuntimeTests verifies cross-version vectors on public AMI audio.

#### Call voices keep average of eligible chunks, not the chunks
`SpeakerVoiceProfile.Contribution.voiceprint`: Call voices keep the average of every eligible chunk instead of the chunks.

### `LokalBot/Services/Speakers/MeetingSpeakerEvidenceStore.swift`

#### Single serial authority; durable decision committed before transcript projection
`MeetingSpeakerEvidenceStore`: One serial authority for evidence, assignment journals and profile mutations.
A durable decision is committed before its public transcript projection.

#### Locked file is unavailable, not corrupt; preserve I/O failure
`MeetingSpeakerEvidenceStore.read`: A locked/protected file is unavailable, not corrupt ciphertext.
Preserve the I/O failure so diagnostics distinguish it from a bad key.

#### Skip file protection option; use atomic write and 0600 permissions
`MeetingSpeakerEvidenceStore.write`: The payload is already authenticated AES-GCM ciphertext. Foundation's
file-protection option can create unreadable files on macOS when the
process has no Data Protection entitlement, so keep the atomic write
and enforce a user-only POSIX boundary instead.

#### Keep only last 512 decisions; assignments hold durable authority
`MeetingSpeakerEvidenceStore.commit`: Retain only bounded recent event metadata; assignments hold durable authority.

#### Files besides identity journal are retired Meet speaker observations
`MeetingSpeakerEvidenceStore.removeRetiredObservations`: Everything beside the identity journal is retired Google Meet speaker
observation (participant names and speaking intervals).

#### Applied names keep minimal turns, not underlying matches
`MeetingSpeakerEvidenceStore.eraseEvidence`: Durable applied names retain minimal turns, not the underlying matches.

#### Erased journal stays for names so hourly pass checks emptiness
`MeetingSpeakerEvidenceStore.holdsExpirableEvidence`: Whether erasing would remove anything. An erased journal stays on disk
for its names, so the hourly pass meets it again on every run.

#### Skip erase when nothing expirable, since rewriting fails concurrent corrections
`MeetingSpeakerEvidenceStore.expire`: Erasing rewrites the journal and advances its revisions,
which would fail a correction made at the same moment.

#### Recent voice samples stay available for remembering
`MeetingSpeakerEvidenceStore.expire`: Recent voice samples stay available for remembering.

#### Legacy names use assignment ID as decision so correction revokes
`MeetingSpeakerEvidenceStore.enrollSavedName`: A name the user gave before call voices were remembered. Legacy names
have no decision, so the assignment ID stands in for one: a later
correction revokes it like any other contribution.

#### Call voices store average plus one chunk to stay under file limit
`MeetingSpeakerEvidenceStore.contribution`: Call voices store their average and one chunk for provenance, which
keeps a busy team's profiles well inside the file limit.

#### Profile cap 250 leaves room for a whole company
`MeetingSpeakerEvidenceStore.profiles`: Every named call participant is remembered, so leave room for a whole company.

### `LokalBot/Services/Speakers/MeetingSpeakerIdentityService.swift`

#### Tracks profile database revision each meeting was matched against
`MeetingSpeakerIdentityService.matchedProfileRevision`: Profile database revision each recent meeting was last matched against.

#### Reapply latest decision just before write so human corrections win
`MeetingSpeakerIdentityService.applyingLatestDecision`: Synchronous final projection immediately before the transcript write.
An automatic task resumed after a human correction cannot overwrite it.

#### Recover interrupted sidecar pair without stale ordinal mapping
`MeetingSpeakerIdentityService.recover`: Recover an interrupted sidecar/transcript pair without applying a stale
ordinal mapping to a different transcription.

#### Bump when call-voice analysis changes so saved meetings revisit once
`MeetingSpeakerIdentityService.callVoicesVersion`: Bumped when call voices start being analyzed differently, so saved meetings are revisited once.

#### nameAutomatically false keeps matches as suggestions for saved notes
`MeetingSpeakerIdentityService.process`: `nameAutomatically: false` keeps automatic matches as suggestions, for
saved meetings whose notes were written from the current names.

#### Sample meeting's synthetic voices are never remembered or matched
`MeetingSpeakerIdentityService.process`: The sample meeting's synthetic voices are never remembered or matched.

#### Mic samples pass echo checks; call samples pass unchanged
`MeetingSpeakerIdentityService.process`: Microphone samples pass the echo checks; call samples pass through unchanged.

#### Legacy aliases have human authority; old turns only carry them across retranscription
`MeetingSpeakerIdentityService.process`: Legacy aliases have human authority, but only use their old
turns to carry them across retranscription.

#### Calendar names are fallback only; reliable disagreement is reviewable
`MeetingSpeakerIdentityService.process`: Calendar is a fallback only; reliable disagreement is reviewable.

#### Keep detached decisions as unresolved for manual reassignment after merges
`MeetingSpeakerIdentityService.process`: Preserve detached decisions for manual reassignment when a merge
prevents a safe remap. They cannot project onto a current label.

#### Cache committed state because pipeline reapplies it before writing
`MeetingSpeakerIdentityService.process`: The pipeline reapplies this cache synchronously before writing.

#### On deletion race keep human choices but discard pending evidence
`MeetingSpeakerIdentityService.process`: Keep durable human choices and historical aliases when a
deletion races processing, but discard all pending evidence.

#### Identity errors never fail audio transcription
`MeetingSpeakerIdentityService.process`: Identity errors never fail audio transcription.

#### Choosing suggested profile explicitly confirms that person
`MeetingSpeakerIdentityService.choose`: Choosing a suggested profile is an explicit confirmation of
that person, including a previously confirmed local user.

#### New ID preserves human split of two labels across remapping
`MeetingSpeakerIdentityService.choose`: A human distinguished two labels previously inferred to be a
clean split. Preserve that distinction on subsequent remapping.

#### Revoke old confirmation first so failure leaves visible pending state
`MeetingSpeakerIdentityService.choose`: Revoke an old confirmation before recording a correction. A failure
leaves a visible pending state instead of training on the wrong person.

#### Every name the user gives teaches LokalBot that voice
`MeetingSpeakerIdentityService.choose`: Every name the user gives teaches LokalBot that voice.

#### Reread state since another correction may arrive during enrollment
`MeetingSpeakerIdentityService.choose`: Another correction could arrive while enrollment was suspended.

#### Merged sources keep evidence on disk, so retention reads them
`MeetingSpeakerIdentityService.expire`: A merge folds its sources out of the library list but keeps their
folders, speaker evidence included, so retention reads them from disk.

#### Reuse same-name agreeing profile so renaming never splits a person
`MeetingSpeakerIdentityService.samePerson`: The remembered person a newly named voice belongs to: same name and an
agreeing voice, so naming someone again never splits them in two. A
person known only from the other source has nothing to compare and is reused.

#### Call analysis waits while LokalBot records or processes
`MeetingSpeakerIdentityService.SavedMeetings.callSamples`: Analyzes a meeting's call track; waits while LokalBot records or processes.

#### Saved transcripts never change; new names are offered as suggestions
`MeetingSpeakerIdentityService.learnFromSavedMeetings`: Names given before call voices were remembered teach LokalBot those
voices once, then recent meetings get suggestions from every remembered
voice. Saved transcripts never change here: a new name would mark their
notes for refresh, so the meeting offers the names to apply instead.

#### One failed analysis stops analysis for the pass
`MeetingSpeakerIdentityService.learnFromSavedMeetings`: One failed analysis (no voice model yet) stops analysis for this pass.

#### Saved call name includes legacy names still in transcript
`MeetingSpeakerIdentityService.isSavedCallName`: A name the user gave a call voice, or a legacy name the transcript still carries.

#### Pre-review meetings keep names only in transcript
`MeetingSpeakerIdentityService.hasSavedCallNames`: Meetings named before speaker review existed keep their names only in the transcript.

#### Re-identify analyzes call track if needed; matches become suggestions, transcript unsaved
`MeetingSpeakerIdentityService.reidentify`: Re-runs identification for a saved transcript, analyzing its call track
first when needed. Matches become suggestions; the transcript is not saved.

#### Saved names follow audio turns of same recording only
`MeetingSpeakerIdentityService.reidentify`: Saved names follow audio turns of the same recording only.

#### Only unnamed speakers with automatic-tier single match count as recognized
`MeetingSpeakerIdentityService.recognizedSpeakers`: Unnamed call speakers whose voice clearly matches one remembered person.

### `LokalBot/Services/Speakers/SpeakerAutoNamer.swift`

#### Calendar attendance gives suggestions only, never voice identity
`SpeakerAutoNamer`: Calendar attendance supplies manual name suggestions, never voice identity.
Even one invitee and one mixed remote track do not prove who spoke.

### `LokalBot/Services/Speakers/SpeakerIdentityResolver.swift`

#### Remap by retained turns in same audio revision; merges cannot inherit
`SpeakerIdentityResolver.remap`: Match by retained turns in the SAME audio revision. A clean split can
inherit; a merge of different people or any ambiguous overlap cannot.

#### Conflicting winner withdraws into review, never silently replaces a name
`SpeakerIdentityResolver.apply`: Withdraw into review; never silently replace one displayed person with another.

### `LokalBot/Services/Speakers/SpeakerMicrophoneEvidence.swift`

#### Mic is a source not a person; quiet references can support suggestions
`SpeakerMicrophoneEvidence`: A microphone is an audio source, not a person. Echo removal is optional:
independently verified quiet reference windows can also support a voice
suggestion or a later, explicit enrollment.

#### Padding covers playback delay; verify waveform since diarizer miss isn't silence
`SpeakerMicrophoneEvidence.select`: The padding includes plausible playback-to-microphone delay.
A diarizer miss is not silence; verify the actual waveform too.

#### Test short windows too so brief remote syllable isn't averaged away
`SpeakerMicrophoneEvidence.referenceIsQuiet`: Test short windows as well as the peak so a brief remote syllable
cannot disappear in the mean of a long silent interval.

### `LokalBot/Services/Speakers/SpeakerVoiceMatcher.swift`

#### Use per-speaker average; same person 0.77-0.94, different at most 0.57
`SpeakerVoiceMatcher.Call`: Call audio arrives codec-compressed, so a single 3–10 s chunk varies too
much to compare on its own. A speaker's average over many turns is
stable: on real Google Meet standups the same person scored 0.77–0.94
across meetings and different people at most 0.57.

#### Median sample-to-average similarity below 0.75 means mixed voices
`SpeakerVoiceMatcher.Call.minimumConsistency`: Median sample-to-average similarity. A label that mixes voices falls below it.

#### Automatic match must lead best differently named person by 0.15
`SpeakerVoiceMatcher.Call.automaticMargin`: Over the best remembered person with a different name.

#### Each confirmed meeting counts once in a remembered voice
`SpeakerVoiceMatcher.callVoiceprint`: A remembered person's call voice: each confirmed meeting counts once.

#### One disjoint chunk per independent clean turn; overlaps aren't extra votes
`SpeakerVoiceMatcher.eligible`: Select at most one disjoint chunk from each independent, uncontaminated
speaking turn. Overlapping diarizer windows are never extra votes.

#### Mixed cluster is unsafe to enroll even if some samples agree
`SpeakerVoiceMatcher.eligible`: A mixed cluster is unsafe to enroll, even if some of its samples agree.

#### Take longest non-overlapped chunks; check average since turns are short
`SpeakerVoiceMatcher.callEligible`: Call speakers: the longest disjoint chunks that no other speaker
overlaps, wherever they fall. The diarizer splits call speech into short
turns, so one chunk per turn left most people with a single sample.
Their average is checked for a mixed voice instead of every pair.

#### Mean 0.72 and minimum 0.65 floor; unknown includes single-profile case
`SpeakerVoiceMatcher.matches`: unknown, including the single-profile case

#### Microphone recognition needs its own held-out calibration
`SpeakerVoiceMatcher.matches`: Microphone recognition requires its own held-out calibration.

#### Compare one average per speaker; same-name people never block each other
`SpeakerVoiceMatcher.callMatches`: One average per call speaker against each remembered person's average.
Remembered people who share a name never block each other.

### `LokalBotTests/Models/Speakers/AttributionSafetyTests.swift`

#### Unresolved identity covers transcripts persisted while the default was off
`AttributionSafetyTests.testMicrophoneCommitmentDefaultsToUserAcrossEchoModesAndPersistence`: `.unresolved` covers transcripts persisted while the default was off.

#### User identity covers defaults persisted while the setting was on
`AttributionSafetyTests.testSharedMicrophoneSettingKeepsMicrophoneVoicesUnidentified`: `.user` covers defaults persisted while the setting was on.

### `LokalBotTests/Services/Speakers/MeetingSpeakerEvidenceStoreTests.swift`

#### Hourly pass must not rewrite an already erased journal; revisions would advance forever
`MeetingSpeakerEvidenceStore.expire`: The hourly pass meets every old meeting again; one it already emptied
must not be rewritten, or its revisions would advance forever.

#### A writer refreshed to latest revision cannot reintroduce deleted evidence
`MeetingSpeakerEvidenceStore`: Even a writer refreshed to the latest assignment revision cannot
reintroduce deleted evidence from its original snapshot.

### `LokalBotTests/Services/Speakers/MeetingSpeakerIdentityServiceTests.swift`

#### Fixture is a digest fixture, not an accuracy test or real capture
`MeetingSpeakerIdentityServiceTests.fixture`: Digest fixture only. No synthetic vector/byte fixture is presented as
an audio-recognition accuracy test or a real provider capture.

#### Merged sources stay on disk but their voice samples expire with retention
`MeetingSpeakerIdentityService`: A merge keeps its sources on disk and out of the library list. Their
voice samples expire with the screen retention period all the same.

#### Saved transcript keeps its names; the meeting offers the recognized name
`MeetingSpeakerIdentityService.recognizedSpeakers`: A saved transcript keeps its names, so its notes stay current; the
meeting offers the recognized name instead.

### `LokalBotTests/Services/Speakers/SpeakerVoiceReplayTests.swift`

#### Opt-in replay calibrates SpeakerVoiceMatcher.Call; saved names stand in for remembered people; nothing leaves Mac
`SpeakerVoiceReplayTests`: Opt-in replay of call-voice naming on real recordings, for calibrating
`SpeakerVoiceMatcher.Call`. Names saved in each transcript act as the
people LokalBot remembers from the other meetings; every call voice is then
matched the way processing would. Nothing leaves this Mac.

#### Report folder must stay outside the repository
`SpeakerVoiceReplayTests.Manifest.output`: Report folder; keep it outside the repository.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
