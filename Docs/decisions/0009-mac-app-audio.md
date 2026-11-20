# 0009. Mac app: Audio

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Audio/`, `LokalBotTests/Services/Audio/`.

## Decisions

### `LokalBot/Services/Audio/AudioBufferSource.swift`

#### Only microphone input is swappable; writer, tee, journal and health stay real
`MicrophoneInput`: Where microphone PCM comes from. Only the input is swappable; the
recorder's writer, preview tee, recovery journal, and health stay real.

#### Let AVAudioEngine choose the current hardware format by passing nil
`EngineMicrophoneInput.installTap`: Let AVAudioEngine choose the current hardware format (see MicRecorder).

#### Test hook plays a file in real time divided by speed, then silence
`FileMicrophoneInput`: Plays an audio file into the recorder in real time ÷ `speed`, then
silence until stopped.

#### System audio is delivered like an IOProc: buffer list valid only during the call
`SystemAudioTap`: Where system-audio PCM comes from, delivered exactly like a Core Audio
IOProc (a buffer list valid only during the call, and its timestamp).

#### Check PID resolves before tearing down a running tap so a vanished PID leaves capture untouched
`SystemAudioTap.resolves`: Whether `attach(processID:)` can find the process. Checked before a
running tap is torn down, so a vanished PID leaves capture untouched.

#### Process tap on one PID (macOS 14.4+) read through a private aggregate device IOProc
`CoreAudioProcessTap`: Today's system audio: a Core Audio process tap on one PID (macOS 14.4+),
read through a private aggregate device's IOProc.

#### Tap is unmuted so the user still hears the meeting
`CoreAudioProcessTap.attach`: user still hears the meeting

#### Test tap converts any file to Float32 stereo 48 kHz like a process tap
`FileSystemAudioTap`: Plays an audio file as a process's output in real time ÷ `speed`, then
silence until stopped. Any file format is converted to what a process tap
delivers — a Float32 stereo mixdown at 48 kHz.

#### After stopDelivery returns no delivery runs, like AudioDeviceStop
`FileSystemAudioTap.stopDelivery`: Like `AudioDeviceStop`: no delivery runs after this returns.

### `LokalBot/Services/Audio/AudioFileInspector.swift`

#### Retire recovery copies only after decoding every frame, since headers can't prove completeness
`AudioFileInspector.fullyDecodedDuration`: Reading a container header alone cannot establish that the payload is
complete. Recovery copies are retired only after decoding every frame.

### `LokalBot/Services/Audio/AudioPreviewTee.swift`

#### Write gaps via one bounded buffer on writer queue; account per chunk so retries don't duplicate silence
`AudioTimelinePadding`: Writes arbitrarily long timeline gaps with one bounded, reusable buffer.
Call only when real audio is ready to follow the gap, on the recorder's
writer queue. Account for each successful chunk so a failed disk write can
retry the remaining gap without duplicating silence already persisted.

#### Separate 16 kHz mono PCM recovery copy (~230 MB/hour), failures isolated, writer queue only
`AudioPreviewTee`: Independent 16 kHz mono PCM recovery beside the AAC track (~230 MB/hour
per PCM copy). The growing CAF serves live transcription; closed checkpoints
survive a damaged/unfinalized container. Failures reach capture health, and
one sink failing cannot disable the other. Called only on the writer queue.

#### Disable converter after failure rather than spam audio thread with retries
`AudioPreviewTee.write`: Disable rather than spam the audio thread with retries.

#### Never resume a file after a failed write left missing frames
`AudioPreviewTee.writePCM`: never resume this file with missing frames

#### Flush resampler tail so finalized preview keeps the primary track's timeline
`AudioPreviewTee.close`: Resampling can retain a short tail. Flush it before closing so a
finalized preview/recovery file keeps the primary track's timeline,
including the final speech after a long padded interval.

### `LokalBot/Services/Audio/AudioRecoveryJournal.swift`

#### Independently closed checkpoints; only writer calls append; manifest failure keeps chunks
`AudioRecoveryJournal`: Independently closed PCM checkpoints. Only the serial audio writer calls
append/close. Manifest failure never removes the surviving chunks.

#### Never overwrite an earlier attempt's journal
`AudioRecoveryJournal.init`: Never overwrite an earlier attempt's journal.

#### Partial write cannot resume at a guessed frame offset
`AudioRecoveryJournal.append`: A partial write cannot be resumed at a guessed frame offset.

#### Recover contiguous prefix; corruption never hides verified audio or compresses gaps
`AudioRecoveryJournal.recover`: Decode the contiguous prefix, including an unmanifested last chunk left
by process death. Corruption never hides an earlier verified interval or
compresses a gap. Incomplete recovery retains every original chunk.

#### Failed re-reconstruction marks cached receipt incomplete since it may be the only copy
`AudioRecoveryJournal.recover`: A previous reconstruction can now be the only surviving copy.

#### Index chunks by name once; manifest searching per checkpoint stalled library loading (2026-11-18)
`AudioRecoveryJournal.reconstruct`: Look chunks and segments up by name once. A sixteen-hour recording
has about 29,000 checkpoints per track; searching the manifest for
each one kept the library from loading for longer than anyone waited
(2026-11-18).

#### Never replace a verified full reconstruction with a shorter prefix
`AudioRecoveryJournal.reconstruct`: Never replace a previously verified full reconstruction with a
shorter prefix after a chunk is damaged or goes missing.

#### Primary encoder failure cannot suppress the PCM recovery copy
`AudioWriteSafety.write`: Failure of the primary encoder cannot suppress the PCM copy.

### `LokalBot/Services/Audio/AudioSourceMonitor.swift`

#### Poll audio processes as second detection signal beside mic-in-use, adapted from Seminarly
`AudioSourceMonitor`: Polls Core Audio's process list for new audio-producing apps and publishes
them as candidates for automatic recording. A second detection signal next
to `MeetingDetector`'s "is the mic in use" — catches the cases the mic
signal misses (Zoom call with mic muted, a meeting in a browser tab the
user opened *before* unmuting). Pattern from Seminarly's
`AudioSourceMonitor`, adapted to LokalBot's coordinator.

#### AppState observes the candidate and decides whether recording is safe
`AudioSourceMonitor.detectedProcess`: The most recently detected new audio source. `AppState` observes this
candidate and decides whether it is safe to start recording.

#### Suppress detections while recording since the recorded app produces output
`AudioSourceMonitor.isRecordingActive`: Set by `AppState` while a recording is in flight. Suppresses new
detections because the app being recorded is itself producing output.

#### Meeting apps outrank generic audio sources; list mirrors MeetingDetector.knownApps plus browsers
`AudioSourceMonitor.meetingBundleIDs`: Bundle IDs of conferencing/meeting apps prioritized over generic audio
sources (so a Spotify track that started 200 ms before Zoom didn't win
the race). The native list mirrors `MeetingDetector.knownApps` plus
the browser set, augmented with a few extras from Seminarly's list.

#### Ignore own app and system processes emitting short blips reported as running
`AudioSourceMonitor.ignoredBundleIDs`: Bundle IDs whose audio is uninteresting — our own app and a few system
processes that emit short blips Core Audio still reports as "running".

#### Pure media players never become candidates; browsers absent so Meet stays recordable
`AudioSourceMonitor.mediaBundleIDs`: Pure media/music players. They emit continuous output but are never
meetings, so — unlike an unknown app — they must not become recording
candidates. Browsers are intentionally absent: a Google Meet call
runs inside one, so it stays recordable.

#### Detection fires only on not-running to running transition
`AudioSourceMonitor.knownActiveObjectIDs`: AudioObjectIDs already running output the last time we polled. A new
detection fires only on a not-running → running transition.

#### Reseed after recording so apps that started mid-meeting aren't fresh candidates
`AudioSourceMonitor.reseed`: Re-seed against the *current* audio state after a recording ends so
apps that started playing audio mid-meeting do not become fresh
automatic-recording candidates.

#### Core Audio query runs on utility thread, only result applied on main
`AudioSourceMonitor.poll`: The Core Audio query reads several properties of every audio process
from coreaudiod and LaunchServices; it ran on the main thread every
three seconds. It now runs on a utility thread and only the result is
applied here.

#### Meeting app replaces a held non-meeting candidate; others stay unknown until slot frees
`AudioSourceMonitor.poll`: One candidate is held for up to 20 seconds. A call that starts
meanwhile must not be lost behind it: a meeting app takes the
place of a held sound from some other app at once, and anything
else stays unknown, so it is reported when the slot is free.

### `LokalBot/Services/Audio/CaptureSessionMicrophoneInput.swift`

#### Dictation uses AVCaptureSession so Bluetooth format switches don't stop capture
`CaptureSessionMicrophoneInput`: Dictation's microphone: an `AVCaptureSession` on the default input device.

`AVAudioEngine` stops itself whenever the I/O hardware format changes, and
a Bluetooth headset changes format as soon as its microphone opens (AirPods
switch from music to headset mode). The engine therefore stopped right after
it started; rebuilding it a second later had already released the
microphone, so the headset fell back to music mode and the next start
repeated the cycle. Dictation kept recording fragments while the microphone
indicator flickered. A capture session keeps the device open across those
format changes and converts every buffer to one fixed client format, so a
headset switch never reaches the writer.

Starting and stopping run on a private serial queue: opening a Bluetooth
microphone can take a second, and the main thread also services the global
dictation shortcut's keyboard event tap.

#### One shared queue so a new session cannot open the device while old one closes
`CaptureSessionMicrophoneInput.sessionQueue`: Every instance starts and stops on this one queue, so a new session
cannot open the device while an earlier one is still closing.

#### Dictation records 16 kHz mono because speech recognition runs at that rate
`CaptureSessionMicrophoneInput.clientFormat`: Speech recognition runs at 16 kHz mono, so dictation records exactly that.

#### Opening session counts as running so health checks spare mid-switch Bluetooth mic
`CaptureSessionMicrophoneInput.isRunning`: True from `start()` until the session fails or is stopped. A session
that is still opening counts as running so health checks do not tear
down a Bluetooth microphone that is mid-switch.

### `LokalBot/Services/Audio/CoreAudioUtils.swift`

#### Hash and equality on objectID only so Pickers keep matching after refresh
`AudioProcess`: Anything Core Audio knows about a running process that owns audio.
Hashable / Equatable on `objectID` only so SwiftUI Pickers keep matching
after a refresh that flips `isRunningOutput`.

#### Take +1 CFString as Unmanaged for explicit ownership; &CFString pointer is unsafe
`CoreAudioUtils.getProcessBundleID`: Core Audio returns the CFString +1 (Create Rule); take it as
`Unmanaged` so ownership is explicit — passing `&CFString` is flagged
unsafe because it forms a raw pointer to an ARC-managed reference.

#### Returns nil when the PID opened no audio devices
`CoreAudioUtils.translatePIDToProcessObject`: PID → process AudioObjectID. Returns nil when no Core Audio object is
associated with the PID (the process opened no audio devices).

### `LokalBot/Services/Audio/EchoCancelledTrack.swift`

#### Echo-cancel from recorded files into a sidecar; mic.m4a untouched; works on old meetings
`EchoCancelledTrack`: Produces a copy of the microphone track with the remote side cancelled out,
for transcription only.

The original `mic.m4a` is never touched: it stays the recording the user can
play back, and this writes a 16 kHz mono sidecar that the ASR engines
consume (they resample to exactly that anyway). Working on the recorded
files rather than inside the capture path costs a codec generation — both
tracks are AAC by now — but it means meetings already in the library can be
cleaned by re-running transcription, which a capture-time canceller can
never do.

#### Delay is how far the microphone lagged the system track
`EchoCancelledTrack.Report.delaySeconds`: How far the microphone lagged the system track.

#### Near-zero dB means no echo found, expected on headphones
`EchoCancelledTrack.Report.echoReturnLossDB`: Energy removed, in dB. Near zero means there was no echo to find —
the expected outcome on headphones.

#### Stream 30 s windows so long meetings never hold both tracks in memory
`EchoCancelledTrack.chunkSeconds`: Streamed in windows so a long meeting never has both tracks resident:
an hour of 16 kHz mono is 230 MB per track decoded whole.

#### 6 dB threshold sits between Voice Isolation 2.6-3.1 dB and Standard 12.9 dB
`EchoCancelledTrack.minimumAcceptedEchoReturnLossDB`: Voice Isolation produced only 2.6-3.1 dB on the recordings used to
validate this stage, while Standard mode produced at least 12.9 dB.
Keep a deliberate gap between those ranges: a marginal result is more
safely transcribed from the untouched microphone track.

#### Decode and DSP on utility executor; cancellation removes partial output
`EchoCancelledTrack.write`: Runs decode and DSP on a utility executor rather than the caller's
actor. Cancelling the awaiting task also cancels the worker, whose
cooperative checks remove any partial destination before returning.

#### Fail open to original mic when score is uncertain or in degraded range
`EchoCancelledTrack.shouldUse`: Fail open to the original microphone whenever the score is uncertain or
falls in the known Voice Isolation degradation range.

#### Known capture gap outranks acoustic guess; older recordings use local acoustic alignment
`EchoCancelledTrack.writeSynchronously`: A known capture gap is stronger evidence than an acoustic guess.
Older recordings can use local acoustic alignment, with uncertainty.

#### Skip alignment when reference is truncated rather than stretching it over speech
`EchoCancelledTrack.writeSynchronously`: Do not stretch a missing tail or truncated reference over speech.

#### Correct small clock-rate difference per chunk; missing reference stays silence
`EchoCancelledTrack.resampled`: Correct the small measured clock-rate difference without holding either
full recording in memory. Empty or missing reference remains silence.

#### Streaming WAV with placeholder sizes patched on finish, so long tracks never sit in memory
`WavWriter`: Minimal streaming 16-bit PCM WAV writer. The header's two size fields are
only known at the end, so they are written as placeholders and patched on
`finish()` — which is what lets a 50-minute track be written without ever
holding it in memory.

### `LokalBot/Services/Audio/EchoCanceller.swift`

#### Adaptive NLMS filter subtracts system audio from mic because raw device records speaker echo
`EchoCanceller`: Subtracts the meeting's remote audio from the microphone recording.

LokalBot records the raw input device, so the meeting app's own echo
cancellation never touches our mic track: with the user on speakers, the
remote voice travels through the room back into the microphone and is
transcribed a second time as the user. Measured on a real 49-minute call,
the user's own voice sat only 8.2 dB above that echo — loud enough that VAD
and ASR treat it as a second speaker, which is how a quarter of the mic
transcript ended up being the other side repeated back.

The system-audio process tap hands us the very signal the echo was made
from, so the echo is predictable where the user's voice is not: an adaptive
FIR filter learns the path from the speakers through the room into the
microphone, and what its prediction does not explain is the user.

Normalized LMS rather than a fixed filter, because the path is not fixed:
the two capture clocks drift (measured: 10 ms over 45 minutes) and the room
changes whenever the laptop moves.

#### 1536 taps (96 ms at 16 kHz) cover echo tail plus residual clock drift
`EchoCanceller.Configuration.taps`: Filter length. Covers the room's echo tail plus whatever clock
drift the bulk alignment leaves behind — 96 ms at 16 kHz.

#### Freeze adaptation when mic is louder than reference explains, preventing divergence
`EchoCanceller.Configuration.doubleTalkMargin`: Double-talk threshold. Adaptation freezes when the microphone is
louder than the reference could explain — that is the user talking,
and left running the filter would learn to cancel *them*. This is
the guard whose absence made a first attempt diverge to -17 dB.

#### Decay window of reference peak used by double-talk detector
`EchoCanceller.Configuration.referencePeakWindow`: Decay window of the reference peak the detector compares against.

#### Frame counts as pure echo when predicted echo exceeds leftover by this ratio
`EchoCanceller.Configuration.suppressionRatio`: How much louder the predicted echo must be than what is left over
before a frame counts as echo and nothing else.

#### Filter leaves echo ~13 dB down so frames are pushed to 0.03 gain
`EchoCanceller.Configuration.suppressionGain`: Gain such a frame is pushed down to. Subtracting the echo is not
enough on its own: the adaptive filter leaves it ~13 dB down and
ASR transcribes that without complaint.

#### Smooth gain per frame so suppression fades instead of clicking
`EchoCanceller.Configuration.suppressionAttack`: Gain smoothing per frame, so suppression fades rather than clicks.

#### Digital-silence gating and comfort-noise fill measured worse than -30 dB gain
`EchoCanceller.Configuration`: Two alternatives to this gain were measured on a real meeting and
both came out worse. Gating echo-only frames to digital silence made
ASR hallucinate *more* (40 invented English segments against 27):
the abrupt edges read as speech onsets, and the release clipped real
word beginnings. Filling them with comfort noise at the room's own
floor cut the residual echo further but masked quiet speech, costing
a third of the user's real words. -30 dB and no fill it is.

#### Double-stored delay line keeps recent taps contiguous for one vDSP call
`EchoCanceller.history`: Delay line of length `2 * taps`: every sample is stored twice so the
most recent `taps` samples are always one contiguous slice, which keeps
the per-sample dot product a single vDSP call and needs no shifting.

#### Carry smoothed gain across chunks so boundaries never step the level
`EchoCanceller.suppressionGain`: Smoothed suppressor gain, carried across chunks so a boundary never
steps the level.

#### Window energy equals reference RMS ~0.01 (-40 dBFS), the audible-remote threshold
`EchoCanceller.referenceActivityFloor`: Window energy standing for a reference RMS of about 0.01 (-40 dBFS),
above which the remote side is audibly playing.

#### Energies from last process call feed ERLE reporting
`EchoCanceller.microphoneEnergy`: Energy the last `process` call removed, for reporting ERLE.

#### Inputs must be aligned and equal length; EchoCancelledTrack uses a fresh canceller per chunk
`EchoCanceller.process`: Cancels `reference` out of `microphone`, sample for sample. The two must
already be aligned (see `EchoDelayEstimator`) and equally long. Filter
state carries across calls on one canceller. `EchoCancelledTrack`
starts a new one for each chunk instead: every chunk gets its own
alignment and is kept or dropped on its own result.

#### Overwritten slot holds leaving sample, making window energy an O(1) update
`EchoCanceller.process`: The slot being overwritten holds the sample leaving the
window, which keeps the window energy an O(1) update.

#### Mark remote-audible from filter state now; score after suppression
`EchoCanceller.process`: Scoring waits until after suppression, which is part of
the cancellation; only the mark of "the remote side was
audible here" is taken now, from the filter's own state.

#### Periodic exact energy sum stops accumulated rounding error in the normalizer
`EchoCanceller.process`: Rounding accumulates over tens of millions of
samples; a periodic exact sum keeps the normalizer
honest without paying for it every sample.

#### Score only where echo was present so number reflects filter, not who talked
`EchoCanceller.process`: Only score where there was echo to remove. Averaged over silence and
the user's own turns instead, the number would say more about who
talked than about the filter.

#### Silence frames that are mostly echo, since ASR transcribes -42 dBFS residual
`EchoCanceller.suppressResidual`: Pushes the frames that were nothing but echo down to the noise floor.

The adaptive filter alone leaves the echo about 13 dB down, measured on
a real call — quieter, but an ASR engine transcribes a -42 dBFS voice
without complaint, so subtraction on its own moved the problem rather
than solving it. Where the filter's own prediction says a frame was
mostly echo and little survived it, what is left is residual echo and
is silenced; where a lot survived, the user was talking and the frame
passes untouched.

#### ERLE in dB; zero means nothing to cancel, correct for headphones
`EchoCanceller.echoReturnLossDB`: Echo return loss enhancement in dB: how much of the microphone's energy
the filter removed. Zero means it found nothing to cancel — which is
the correct answer when the user wears headphones.

#### Correlate loudness envelopes to find bulk mic lag (about 146 ms) before adaptive filtering
`EchoDelayEstimator`: Finds how far the microphone lags the system-audio track.

The two are captured by different Core Audio paths with their own buffering,
and the sound additionally has to travel from the speakers to the mic: on a
real call the microphone ran about 146 ms behind. An adaptive filter can
only look backwards, so the reference has to be shifted into rough
alignment first — the filter then covers what is left.

Correlating loudness envelopes rather than waveforms: the bulk delay is a
property of the energy contour, which survives AAC encoding and room
colouring intact, and 10 ms frames make the search cheap enough to run on
probes from across the whole track.

#### Nudge estimate one frame early because a causal filter cannot reach forwards
`EchoDelayEstimator.safetyFrames`: Alignment must not land *later* than the true delay — a causal filter
cannot reach forwards — so the estimate is nudged early by a frame.

#### Delay in samples is positive when mic lags reference
`EchoDelayEstimator.delay`: Delay in samples, positive when the microphone lags the reference.

### `LokalBot/Services/Audio/EchoWaveformEvidence.swift`

#### Narrow fallback for near-identical digital echo; lexical similarity cannot authorize deleting speech
`EchoWaveformEvidence`: A narrow fallback for near-identical digital echoes. Normal room echoes
are handled by AEC; lexical similarity cannot authorize deleting speech.

#### Acoustic suspicion needs no identical ASR words and never deletes speech
`EchoWaveformEvidence.analyze`: Acoustic suspicion does not require ASR to choose identical
words (or even the same language). It never deletes speech.

#### Loudness contour tolerates coloration and delay; uncalibrated flag means uncertainty only
`EchoWaveformEvidence.suspectedEcho`: The loudness contour tolerates room coloration and playback delay.
This uncalibrated conservative flag means uncertainty, never identity.

#### Decimated 0.999 correlation accepts only near-exact copies, not same words by two people
`EchoWaveformEvidence.nearIdentical`: Decimated waveform comparison keeps the bounded fallback inexpensive.
The threshold deliberately accepts only near-exact copies, not two
people speaking the same words, or a mixture containing a quiet reply.

### `LokalBot/Services/Audio/MediaPlaybackController.swift`

#### Resume only media this dictation paused; AppleScript runs in bounded helper processes
`MediaPlaybackController`: Pauses media that was actively playing when dictation begins and resumes
exactly that media when the dictation capture ends. AppleScript work runs in
short-lived helper processes off the main actor and is forcibly bounded so
an unresponsive media app can never delay push-to-talk indefinitely.

#### Resume token is document names for QuickTime, DOM marker for browsers
`MediaPlaybackController.PausedTarget.resumeToken`: Opaque state returned by the pause script. QuickTime uses document
names; browsers use a per-dictation DOM marker token.

#### Cut-off scripts may have paused part of the way
`MediaPlaybackController.ScriptOutcome.cutOff`: Stopped at the time limit, possibly part of the way through.

#### Browsers paused tab by tab with a token so only those resume
`MediaPlaybackController.markerBrowserBundleIDs`: Browsers whose tabs are paused one by one and marked with the
dictation's token, so only what this dictation paused plays again.

#### Cut-off browser script still records a target; resume by token is safe if unmarked
`MediaPlaybackController.pausedTarget`: What to resume after a pause script, or nil when it paused nothing.
A browser script that ran out of time may already have paused some
tabs: with many tabs open it used to be stopped after pausing the
video, nothing was recorded, and the video stayed paused after the
dictation. Resuming by the token is safe when nothing carries it.

#### Pause delays dictation start so gets a short 1.5 s limit
`MediaPlaybackController.pauseTimeoutSeconds`: Pausing delays the start of a dictation, so it gets little time.

#### Resume delays nothing and must reach every paused tab, so 5 s
`MediaPlaybackController.resumeTimeoutSeconds`: Resuming delays nothing, and has to reach every tab the pause reached.

#### SIGTERM, grace, then PID-identity-checked SIGKILL so reader and waitUntilExit unblock
`ScriptProcessController`: Bridges the AppleScript timeout/cancellation path to its blocking helper.
SIGTERM gets a brief grace period before a PID-identity-checked SIGKILL so
the stdout reader and `waitUntilExit()` cannot remain blocked forever.

### `LokalBot/Services/Audio/MicRecorder.swift`

#### Commit recovery silence only after rebuilt graph delivers audio; testable without hardware
`AudioRecoverySilenceCommitGate`: Gates recovery-gap silence until a rebuilt capture graph delivers audio.
Starting an engine is not enough evidence: a graph can report success and
still never produce a buffer. Keeping this state separate also makes failed
retry behavior testable without requiring microphone hardware.

#### Borrowed on real-time thread, returned on writer queue
`MicAudioBufferPool.ring`: Borrowed on the real-time thread, returned on the writer queue.

#### Borrow is real-time thread only
`MicAudioBufferPool.borrow`: Real-time thread only.

#### Return is writer queue only
`MicAudioBufferPool.returnBuffer`: Writer queue only.

#### Nil-format tap needs broker to rebuild pool off-thread on format mismatch instead of dropping audio
`MicAudioBufferPoolBroker`: Atomically routes real-time tap buffers to a pool matching the format Core
Audio actually negotiated. A `format: nil` tap is required during device
changes because `outputFormat(forBus:)` can be stale; this broker lets the
first mismatched callback request an off-thread pool rebuild instead of
silently dropping every subsequent buffer.

#### Count recoveries in sliding window so flapping devices stop cycling; opt-in for dictation
`MicRecoveryFlapDetector`: Counts microphone recoveries in a sliding window. A recovery that "succeeds"
and is followed by another configuration change a moment later is not
recovered: each rebuild used to reset the retry budget, so a flapping device
cycled forever while the recording kept only fragments. Opt-in, because a
meeting would rather keep fragments than stop.

#### Mic is a separate Me track for speaker attribution; meetings AAC, dictation PCM CAF
`MicRecorder`: Records the default input device (your voice). Meeting recordings use AAC
`.m4a`; short-lived dictation scratch files can use PCM `.caf` to avoid
AAC container startup failures on some devices.
This is the "Me" track — kept separate from system audio on purpose
so M2 gets speaker attribution for free (design doc §2.2).

#### Dictation uses capture session for Bluetooth; meetings keep engine input for speaker-clock anchoring
`MicRecorder.dictationInputFactory`: Dictation records through a capture session, which keeps a Bluetooth
headset's microphone open while it switches to headset mode. Meetings
keep the engine input (and its speaker-clock anchoring) above.

#### Nil policy retries as long as the device keeps changing
`MicRecorder.flapPolicy`: Nil keeps retrying for as long as the device keeps changing.

#### Recreate engine per session; reused one holds stale graph and fails with '!dev'
`MicRecorder.input`: Recreated per session — a reused engine can hold a stale graph after
device changes and then fails with kAudioDeviceUnsupportedFormat ('!dev').

#### Accessed only on ioQueue; nil for standalone dictation capture
`MicRecorder.timeline`: Accessed only on `ioQueue`. Nil for standalone dictation capture.

#### Accessed only on ioQueue
`MicRecorder.recoverySilenceCommitGate`: Accessed only on `ioQueue`.

#### Observe engine config change to rebuild tap in place, otherwise mic.m4a truncates
`MicRecorder.configChangeObserver`: Observes `AVAudioEngineConfigurationChange` so we can rebuild the
tap graph in place when the audio device changes mid-recording
(AirPods plug/unplug, default-input switch, sample-rate renegotiation).
Without this, the engine silently stops itself and `mic.m4a` truncates.

#### Real-time callback does one bounded copy; conversion, encoding and writes serialize on queue
`MicRecorder.speakerAudioClock`: Audio taps run on a real-time Core Audio thread. Keep that callback to
one bounded PCM copy, then serialize conversion, AAC encoding, preview
resampling, and filesystem writes here.

#### Set before capture and cleared after, shared with meeting-audio recorder
`MicRecorder.soundMeter`: Set before capture starts and cleared after it stops, like
`speakerAudioClock`. Shared with the meeting-audio recorder.

#### Open nothing until start so capture-session input doesn't touch mic at launch
`MicRecorder.init`: Nothing is opened until `start`: dictation's capture-session input
would otherwise touch the microphone when the app launches.

#### Per-install token stops late callbacks of an old graph from writing into replacement
`MicRecorder.activeCaptureGraphID`: Accessed only on `ioQueue`. A per-install token prevents a late callback
from an old input graph from mutating or writing into its replacement.

#### Fires once per start on main queue; Bluetooth mic may take a second
`MicRecorder.onFirstAudio`: Called once per `start`, on the main queue, when the first captured
audio is written. A Bluetooth microphone can take a second to deliver.

#### Accessed only on ioQueue
`MicRecorder.hasDeliveredFirstAudio`: Accessed only on `ioQueue`.

#### About -90 dBFS: below any working mic's floor; closed lid gives digital silence (#373)
`MicRecorder.signalRMSThreshold`: About -90 dBFS: below the noise floor of any working microphone, even
in a quiet room, so only a muted or switched-off input stays under it
(a closed MacBook lid delivers digital silence, #373).

#### File-input test hook needs no microphone permission
`MicRecorder.requestPermission`: file input needs no microphone

#### Preview tee mirrors capture to PCM CAF for live transcript, best-effort
`MicRecorder.start`: `previewTee` mirrors the capture into a snapshot-safe PCM `.caf` for
the live meeting transcript — best-effort, never fails the recording.

#### Drain queue first for callback order, flush converter tail before closing
`MicRecorder.stop`: Draining the queue first preserves callback order. Then flush the
converter's tail before closing either output.

#### Rebuild after backoff off caller thread; synchronous reopen blocks main thread
`MicRecorder.recoverCapture`: Rebuilds the input after the backoff delay instead of on the caller's
thread. A stopped input is usually mid-reconfiguration, and reopening a
device synchronously blocks the main thread for as long as it takes.

#### Reconnect listener outlives failed graphs and rearms bounded recovery
`MicRecorder.observeDeviceReconnections`: This listener outlives failed engine graphs. Reconnecting an input
rearms the bounded recovery owner even after its fast retries expired.

#### Build a fresh graph because reused engine stays pinned to previous hardware rate
`MicRecorder.rebuildCaptureGraph`: Reconfiguration can leave `AVAudioEngine`'s input node pinned to the
previous hardware rate. Reusing that graph makes every retry request the
stale tap format. Build a completely new graph, while retaining the
session's output file and recording format so capture can continue in
the same artifact.

#### Shared by start and config-change reinstall; converter only when formats differ
`MicRecorder.installTapAndStart`: Builds the converter (only when input ≠ recording format), installs
the tap, and starts the engine. Shared by `start()` and the
configuration-change reinstall.

#### Tap with nil format because outputFormat can be stale during device switch
`MicRecorder.installTapAndStart`: Let AVAudioEngine choose the current hardware format. During a live
device switch, `outputFormat(forBus:)` can briefly report a stale
client format while the input unit has already moved to the new
hardware rate, and passing that stale format makes installTap raise.

#### Capture fallback host time in callback; invalid anchors fail closed for speaker proof
`MicRecorder.installTapAndStart`: Capture the fallback on the callback, never after queue/encoder
delay. Invalid host anchors still fail closed for speaker proof.

#### Step down bitrate ladder when encoder refuses instead of failing the meeting
`MicRecorder.makeRecordingFile`: Opens the capture file, stepping down the bitrate ladder if the encoder
refuses. A rejected bitrate used to surface as "Could not start
recording" with a raw Core Audio code, which told the user nothing and
cost them the meeting.

#### AAC bitrate tiers chosen from measured encoder acceptance per sample rate
`MicRecorder.aacBitRate`: AAC bitrates the encoder will accept, by sample rate.

The rate is not ours to choose: it is whatever the input device runs at,
and a Bluetooth headset in HFP mode runs at 16 kHz. A fixed 64 kbit/s is
out of range there, so `AVAudioFile(forWriting:)` threw `!dat`
(560226676) and the meeting did not record at all. Measured against the
encoder, mono:

rate     64k  48k  32k  24k
8000     ✗    ✗    ✗    ✓
16000     ✗    ✓    ✓    ✓
22050     ✓    ✓    ✓    ✓
44100     ✓    ✓    ✓    ✗
48000     ✓    ✓    ✓    ✗

So the constraint runs both ways and no single value covers the range.
These tiers sit inside every accepted row, leaving headroom above the
minimum rather than hugging the edge — speech at 16 kHz has nothing to
gain from the last few kbit anyway.

#### Ladder strictly descends because failures are one-directional at each end
`MicRecorder.aacBitRateLadder`: Bitrates to try, best first, descending. The tiers above are measured,
but only on the rates a Mac actually offers; a device that lands between
them should still record at a lower bitrate rather than not at all.

Strictly descending, because the failures are one-directional at each
end: at 8 kHz everything above 24 kbit/s is refused, so retrying upwards
would trade one rejection for another.

#### Remove tap and retry after Core Audio settles to avoid config-change-pending state
`MicRecorder.handleConfigurationChange`: Posted asynchronously when the audio device changes. The engine has
already stopped itself; remove the old tap and let the retry loop rebuild
the graph after Core Audio has settled. Reinstalling immediately can hit
AVAudioEngine's transient "config change pending" state.

#### Flush converter on stop or the last few hundred ms are dropped
`MicRecorder.drainAndResetConverter`: Flush the converter's internal buffer on stop. Without this, the tail
(the last few hundred ms — more with resampling) is dropped because
the streaming write loop only ever signals `.noDataNow`, never EOS.

#### Copy via AudioBufferList to handle interleaved and planar buffers
`MicRecorder.copyBuffer`: Makes the tap buffer safe to retain after the callback returns. Copying
through `AudioBufferList` handles both interleaved and planar layouts.

#### Preserve recovery gap only after rebuilt graph delivers a real buffer
`MicRecorder.appendPendingRecoverySilence`: Preserve a recovery gap only after the rebuilt graph delivers a real
buffer. Failed starts and nominally-running graphs that never capture
audio therefore cannot inflate the file or its reported duration.
Called only on `ioQueue` immediately before the recovered buffer write.

### `LokalBot/Services/Audio/RealtimeBufferRing.swift`

#### Lock-free SPSC ring avoids real-time drops seen on 2026-10-01
`RealtimeBufferRing`: Preallocated audio buffers handed between Core Audio's real-time thread,
the only borrower, and the writer queue, the only returner, without a lock.

The pools used a lock the real-time side could only `try()`: whenever the
writer happened to be returning a buffer at that instant, the callback
dropped audio although buffers were free. One such drop flagged a
33-minute recording as interrupted on 2026-10-01.

A single-producer/single-consumer ring of buffer indices: only the
borrower advances `head`, only the returner advances `tail`.

#### Real-time thread only; never blocks or allocates
`RealtimeBufferRing.borrow`: Real-time thread only. Never blocks or allocates.

#### Writer queue only; buffers from other rings ignored
`RealtimeBufferRing.giveBack`: Writer queue only. A buffer from another ring is ignored.

#### Full ring means double return; never overwrite a slot
`RealtimeBufferRing.giveBack`: Full only if a buffer was returned twice; never overwrite a slot.

### `LokalBot/Services/Audio/RecordingAudioClock.swift`

#### Files use elapsed meeting time padded to one origin; jitter under 20 ms tolerated
`RecordingAudioTimeline`: Meeting files use elapsed meeting time, including periods with no captured
audio. Each recorder fills to the same monotonic origin before writing a
buffer; late attachments and recovered devices therefore cannot move later
speech to the beginning of a file. Small clock/resampler jitter is tolerated
without repeatedly inserting sub-buffer silence.

#### Host time pauses in sleep; combine continuous clock with buffer age on callback
`RecordingAudioTimeline.hostTimeOnTimeline`: Core Audio host time can pause during sleep. The continuous meeting
clock retains that gap, while the buffer's age on the host clock keeps
callback/queue latency out of the placement. Capture both observations
together in the callback and perform this work on the writer queue.

#### Anchors recorded on writer queue after successful writes; real-time callback stays lean
`RecordingAudioClock`: Receives anchors on the audio writer queue, only AFTER successful writes.
No locks, allocations, conversion or I/O are added to the real-time callback.

#### Mismatched sample rate never reinterprets old file frames
`RecordingAudioClock.record`: The recorder rejects incompatible reattachments. If a caller
nevertheless supplies one, never reinterpret old file frames.

#### Backwards clock keeps history but never reuses it for live observation
`RecordingAudioClock.record`: Retain historical file anchors for offline alignment, but a
backwards clock must never reuse them for a live observation.

#### Keep compact span map up to 65,536; fragmented captures fail closed
`RecordingAudioClock.record`: Retain the compact map for post-recording alignment. On an
excessively fragmented capture, missing coverage fails closed.

#### Both bounds in one contiguous span; never extrapolate
`RecordingAudioClock.map`: Both bounds must lie within a single contiguous span. Never extrapolate.

#### Version 2 pads to origin; version 1 files must not be reinterpreted as padded
`RecordingAudioTiming.timelineOriginHostTime`: Version 2 captures pad both primary audio and preview CAFs to this
origin. Version 1 remains decodable: its spans still map raw file time
for echo/identity evidence. Never reinterpret those existing files or
their saved transcripts as padded audio merely by loading the sidecar.

#### Map through one continuous span per track; padding and gaps have no anchors
`RecordingAudioTiming.referenceRange`: Map both bounds through one continuous span on each track. Padding and
device gaps have no anchors, so this never extrapolates across them.

### `LokalBot/Services/Audio/SystemAudioRecorder.swift`

#### Core Audio process tap pipeline; needs System Audio Recording permission and no sandbox
`SystemAudioRecorder`: Records the audio *output* of one process (the meeting app) using
Core Audio process taps (macOS 14.4+) — the "Them" track.

Pipeline: PID → process AudioObject → CATapDescription → process tap
→ private aggregate device containing the tap → IOProc → AAC `.m4a`.
Pattern follows Apple's "Capturing system audio with Core Audio taps"
and insidegui/AudioCap. Requires the "System Audio Recording" TCC
permission (NSAudioCaptureUsageDescription) and no App Sandbox.

#### Tests and UI background host may replace the tap factory before recorders exist
`SystemAudioRecorder.defaultTapFactory`: Tests and the UI background host may replace this before any recorder exists.

#### Writer-queue access, preserved across process handoffs
`SystemAudioRecorder.timeline`: Accessed on the writer queue and preserved across process handoffs.

#### Set before starting a tap, cleared only after writer drains
`SystemAudioRecorder.speakerAudioClock`: Set before starting a tap, cleared only after the writer drains.

#### Shared with mic recorder, set and cleared with speakerAudioClock, kept across handoffs
`SystemAudioRecorder.soundMeter`: Set and cleared with `speakerAudioClock`. Shared with the microphone
recorder and kept across process handoffs.

#### Counts current tap frames only; zero identifies a dead attachment
`SystemAudioRecorder.framesSinceAttach`: Frames delivered by the current tap only. Recovery padding deliberately
does not advance this counter, so zero identifies a dead attachment.

#### IOProc writes hop to serial queue so real-time thread never blocks on I/O
`SystemAudioRecorder.ioQueue`: IOProc writes hop here so the Core Audio real-time thread never
blocks on AAC encoding or filesystem I/O. Serial → ordered writes.

#### Fixed lock-free pool; set before first tap, cleared after last stops
`SystemAudioRecorder.bufferRing`: The tap callback borrows from this fixed lock-free pool. It never
allocates an AVAudioPCMBuffer or waits for the writer queue. Set before
the first tap starts and cleared after the last one stops.

#### Track PID to stop instead of recording a blank track when process dies
`SystemAudioRecorder.capturedPID`: Captured app's PID, so we can detect the process terminating and
stop instead of silently recording a blank track.

#### Fires on main thread when captured process exits before stop
`SystemAudioRecorder.onCapturedProcessTerminated`: Fired on the main thread when the captured process exits before
`stop()` was called (crash, user-quit, browser tab close).

#### Preview tee mirrors capture to PCM CAF for live transcript, best-effort
`SystemAudioRecorder.start`: `previewTee` mirrors the capture into a snapshot-safe PCM `.caf` for
the live meeting transcript — best-effort, never fails the recording.

#### Tap must find the process before any state changes
`SystemAudioRecorder.start`

1. The tap must find the process before any state changes.

#### Latch PID only after successful build so partial start leaves no stale watcher
`SystemAudioRecorder.start`: Latch the PID only after a successful build so cleanup() on a
partial start doesn't leave a stale watcher running.

#### Reattach keeps writer open since browser meetings move output between helper processes
`SystemAudioRecorder.reattach`: Switches the Core Audio process tap to a new PID while keeping the
existing `system.m4a` writer open. Browser meetings often move output
between helper processes; closing/reopening the file would discard the
audio already captured before that handoff.

#### Queue behind writes without making main thread wait
`SystemAudioRecorder.captureHealthInBackground`: Queue behind writes without making the caller wait on the main thread.

#### Reattaches keep the writer open so earlier samples stay in the same M4A
`SystemAudioRecorder.attachTap`

5. Output file (PCM → AAC handled by AVAudioFile). Reattaches keep
this writer open so samples already captured remain in the same M4A.

#### Buffer list valid only in callback; copy then hop to serial queue, no AAC on real-time thread
`SystemAudioRecorder.attachTap`

6. Tap buffers arrive on the real-time thread. The buffer list is
   only valid for the duration of this callback, and the AAC encoder
   must not run on the real-time audio thread — copy the samples,
   then hop to a serial queue.

#### Only the writer queue returns buffers to the ring
`SystemAudioRecorder.attachTap`: Only the writer queue returns buffers to the ring.

#### Real-time callback does one bounded copy; RMS, encoding and I/O stay on writer queue
`SystemAudioRecorder.attachTap`: The real-time callback only performs one bounded copy.
RMS traversal, AAC encoding, preview conversion, and I/O
all stay on this serial writer queue.

#### Notify upstream if captured process dies so meeting ends cleanly
`SystemAudioRecorder.installTerminationObserver`: Watch the captured process: if it dies mid-meeting, the tap goes
silent. Notify upstream so the meeting can end cleanly instead of
producing a `system.m4a` that's half audio, half blank.

#### Stop tap without closing file for browser helper handoffs
`SystemAudioRecorder.teardownTap`: Stop the tap/aggregate without closing the file. Used for browser
helper handoffs where the M4A should keep accumulating samples.

#### Drain dispatched IOProc writes to preserve order before reattach or close
`SystemAudioRecorder.teardownTap`: Drain any IOProc writes that were already dispatched before we
stopped, preserving sample order before a reattach or file close.

#### Close order: stop IOProc, drain queue, release file, then dismantle Core Audio objects
`SystemAudioRecorder.cleanup`: One canonical close path, used by both `stop()` and startup failures.
Order matters: stop the IOProc (so no new buffers are dispatched), drain
the write queue (so in-flight writes finish), release the file ref
(flushes the AAC encoder), then dismantle Core Audio objects.

#### Commit missing time only when a tap delivers a buffer, so dead reattaches don't inflate health
`SystemAudioRecorder.appendTimelineSilence`: Commit missing meeting time only when a tap actually delivers a buffer.
This includes initial late attachment, handoffs, and dropped callbacks;
unsuccessful/dead reattachments cannot inflate capture health.

#### Drop accounting is best-effort; never wait or log in realtime callback
`SystemAudioRecorder.noteDroppedBuffer`: Capture-health accounting is best-effort. Never wait behind its reader
or emit a log from Core Audio's realtime callback.

#### Empty ring means writer far behind and counts as dropped buffer; never blocks
`SystemAudioRecorder.borrowBuffer`: Runs on Core Audio's real-time callback. Nothing here blocks: an empty
ring (the writer is far behind) is a dropped-buffer event.

#### Never per-channel memcpy interleaved tap buffers; it halved frames and caused robotic buzz
`SystemAudioRecorder.copyAndMeasureRMS`: Copies `source`'s samples into `destination` buffer-by-buffer via the
`AudioBufferList` (layout-agnostic) and returns the RMS across all
channels. `destination.frameLength` must already equal
`source.frameLength` so its buffer byte sizes are final.

Do NOT rewrite this as per-channel `memcpy`s over `floatChannelData`:
the process tap delivers *interleaved* stereo, where the channel
pointers overlap (`data`, `data+1`, stride 2). A contiguous
`frameLength * 4`-byte copy per channel then moves only the first half
of each buffer's frames and leaves the second half silent — chopping
the track at sampleRate/frames Hz (93.75 Hz for 512-frame buffers),
which plays back as a robotic buzz. Shipped twice; measured on real
recordings as a 40× level drop in the back half of every 512 frames.

### `LokalBot/Services/Audio/WaveformAnalysis.swift`

#### Peak envelopes are an activity overview, not a phase-accurate mix
`WaveformAnalysis`: Peak envelopes for all audible tracks on the player's shared timeline.
This is an activity overview, not a phase-accurate mix of the source signals.

#### Don't cache or publish an envelope if a source changed mid-read
`WaveformAnalysis.peaks`: Do not save or publish an envelope if a source changed mid-read.

#### Disk cache lives with recording so deleting meeting removes peaks; 1,024 floats
`WaveformAnalysis.DiskEntry`: The disk cache lives with the recording, so deleting a meeting removes
its derived peaks too. It stores only 1,024 floats and source identities.

#### Read-only folder must never block playback or waveform loading
`WaveformAnalysis.writeDiskCache`: A read-only folder must never prevent playback or waveform loading.

#### Key includes mtime and size so replaced recordings don't reuse stale waveform
`WaveformAnalysis.cacheKey`: File identity includes modification time and size so replacing a recording
at the same path does not reuse its old waveform on the next load.

#### Foundation caches URL resource values, so ask filesystem afresh each load
`WaveformAnalysis.cacheKey`: URL resource values can be cached by Foundation for this URL
instance; ask the filesystem afresh on every load.

#### Bounded buffers; sample time picks the bin so shorter tracks don't stretch
`WaveformAnalysis.decode`: Bounded PCM buffers keep long recordings off the main actor without
allocating a full decoded file. Sample time, rather than each track's
length, determines the bin, so shorter tracks never stretch to fill it.

#### Malformed non-finite PCM must not poison the whole envelope
`WaveformAnalysis.decode`: Malformed PCM must not poison the entire envelope.

#### Pool peaks to width so brief sounds aren't dropped or overflow narrow players
`WaveformAnalysis.resample`: Pool peaks to the available width instead of overflowing a narrow player
or dropping brief sounds between sampled points.

### `LokalBotTests/Services/Audio/AudioPreviewTeeTests.swift`

#### A mid-write CAF copy must decode for the live transcript; AAC m4a tracks fail this
`AudioPreviewTee`: The property the live transcript depends on: a mid-write copy of the
CAF must decode even though the writer is still open (the AAC .m4a
tracks fail exactly this).

### `LokalBotTests/Services/Audio/AudioRecoveryJournalTests.swift`

#### Rebuild looks up each checkpoint; searching the whole manifest per checkpoint hung library load
`AudioRecoveryJournal.recover`: The recording of 2026-11-17 left 28,712 checkpoints on one track and
18,016 on the other. The rebuild searched the whole manifest for each
checkpoint, so every launch spent itself on that meeting and the library
never finished loading. A few thousand checkpoints tell a rebuild that
looks each one up from that one.

#### Rebuild measured 0.49 s with lookups, 10.8 s with search; 5 s limit
`AudioRecoveryJournalTests.testThousandsOfCheckpointsRebuildWithoutSearchingTheManifestForEach`: Measured in a Debug build on 2026-11-18: 0.49 s with lookups, 10.8 s
with a search per checkpoint. The limit leaves room for slower Macs.

### `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift`

#### Media players are excluded as recording candidates; meeting apps and browsers stay eligible
`AudioSourceMonitor.isMediaPlayer`: `AudioSourceMonitor` detects when an app newly starts producing audio.
Pure media/music players (Spotify, Apple Music, …) must be excluded so
playing music never becomes a recording candidate, while meeting apps and
the browsers that host web meetings stay eligible.

#### Browsers host web meetings and must never be treated as media
`AudioSourceMonitor.isMediaPlayer`: Browsers host web meetings (Meet/Jitsi/Whereby), so they must NEVER be
treated as media — otherwise a browser meeting would stop being detected.

#### Electron meeting apps emit call audio from a host.helper process; capture must honour it
`MeetingDetector.captureTargetProcess`: Electron meeting apps (Teams, Slack, Webex) emit call audio from a
helper process exactly as Chromium browsers do, and ``audioBundleID``
already models that `<host>.helper` relationship for every host — not
just the browser/Zoom special cases. The capture lookup must honour it
outside those branches too: when it does not, `hasOutputAudio` is false,
the detector never surfaces the app, and `RecordingController` skips the
process tap entirely — the meeting silently records mic-only.

#### Teams modulehost stays open while idle: capture target but not call evidence
`MeetingDetector.carriesMeetingSignal`: Teams' modulehost keeps its stream open even while Teams is idle. That
makes it a useful tap target but unusable as evidence that a call exists.

#### Capture accepts a silent-but-present namespace process when Teams host has no audio object
`MeetingDetector.captureTargetProcess`: Measured on a real Teams call: `translatePIDToProcessObject` fails for
the Teams host PID because that process owns no Core Audio object. When
the meeting is momentarily quiet no sibling is `isRunningOutput` either,
so a capture lookup that requires current output resolves to nothing and
the tap is refused. Capture must therefore accept a silent-but-present
process in the namespace — the tap records once audio starts.

#### A process with a real meeting signal wins over an always-open sibling
`MeetingDetector.captureTargetProcess`: A process carrying a real meeting signal still wins over an always-open
sibling that is valid for capture but ignored by detection.

#### Capture must not attach to an unrelated app when the meeting app is absent
`MeetingDetector.captureTargetProcess`: Capture must not attach to an unrelated app just because nothing of the
meeting app is running.

#### A tap that delivered zero buffers is excluded on the recovery pass
`MeetingDetector.captureTargetProcess`: A tap that delivered zero buffers must not be selected again on the
recovery pass; another process in the namespace gets a chance instead.

#### Every tap that delivered nothing stays excluded within one recording
`MeetingDetector.captureTargetProcess`: More than one process can be ruled out within a single recording:
every tap that delivered nothing stays excluded, not just the last.

#### Namespace match must not swallow a different app with a shared bundle id prefix
`MeetingDetector.audioBundleID(_:belongsTo:)`: The namespace rule must not swallow a *different* app whose bundle id
merely starts with the same characters.

#### Feishu and DingTalk helpers sit outside the host namespace and need explicit mapping
`MeetingDetector.audioBundleID(_:belongsTo:)`: Feishu is `com.electron.lark` but its Electron helpers keep ByteDance's
`com.bytedance.lark.helper`, and DingTalk's helper is
`com.alibaba.DingTalk-Helper`. Neither sits in its host's namespace, so
without an explicit mapping a call carried by the helper is never seen.

#### Webex call audio is in Cisco-Systems.SparkHelper outside the host namespace
`MeetingDetector.audioBundleID(_:belongsTo:)`: Webex renders call audio in `WebexHelper`, which Core Audio lists as
`Cisco-Systems.SparkHelper` — outside the host's `Cisco-Systems.Spark.`
namespace. Without the mapping the tap lands on the silent main process
and the "Them" track records nothing.

#### WeChat is excluded: voice messages pass the sustained-audio gate and are not calls
`MeetingDetector.meetingAppCandidates`: WeChat stays out: its voice messages and videos play long enough to
pass the sustained-audio gate and would start meetings that are not
calls.

#### Helper fallback stays a fallback; a producing host remains the capture target
`MeetingDetector.captureTargetProcess`: The helper fallback must stay a *fallback*: when the host process itself
is producing output it remains the capture target, so apps that work
today are unaffected.

#### Unknown apps stay eligible so new meeting tools surface via fallback candidate path
`AudioSourceMonitor.isMediaPlayer`: Unknown apps stay eligible so a genuinely-new meeting tool is still
surfaced via the monitor's fallback candidate path.

#### Every LokalBot build bundle ID is ignored; a dev build playing back was its own candidate
`AudioSourceMonitor`: A development build playing a meeting back was its own candidate:
only the release bundle ID was on the ignore list.

#### A call starting during the 20-second candidate hold must still be reported
`AudioSourceMonitor.apply`: A candidate is held for up to 20 seconds. A muted-microphone call that
started in that time went into the "already playing" set and was never
reported, so it was not recorded.

#### Remember which sibling emitted; that moment is the only time call audio carrier is known
`MeetingDetector.captureTargetProcess`: The moment a process emits is the only time we learn which sibling
actually carries call audio, so that choice must survive the quiet
stretch that follows rather than being re-guessed from list order.

#### With nothing emitting or remembered, choice must not depend on Core Audio list order
`MeetingDetector.captureTargetProcess`: With nothing emitting and nothing remembered, the choice must not
depend on the order Core Audio happened to return the processes in.

#### A hand-started recording needs a tap target; a running silent meeting app qualifies
`MeetingDetector.meetingAppCandidates`: A hand-started recording has no detected app, but the tap still needs a
target; a running meeting app qualifies even while it is silent.

#### Modulehost is useful context in a call but not reliable evidence itself
`MeetingDetector.bestAlwaysOpenAudioProcess`: Teams' modulehost is useful context during a call, but it remains open
while Teams is idle and therefore cannot be reliable evidence itself.

#### After reliable call audio, the always-open stream bridges a speech pause without starting stop debounce
`MeetingContinuationLease`: Once reliable call audio has been seen, the always-open stream bridges an
ordinary speech pause without starting the stop debounce.

#### Idle modulehost must not keep a finished call alive; grace expires
`MeetingDetector.alwaysOpenAudioContinuationGrace`: The same idle modulehost must not keep a finished call alive forever.
Once recent reliable evidence expires, the detector can begin its normal
stop debounce even though modulehost still reports running output.

#### Recovery can exclude the silent current tap PID and find another emitting helper
`MeetingDetector.bestOutputAudioProcess`: Capture health can prove the current tap silent while Core Audio still
reports its stream open. Recovery must be able to exclude that current
PID and discover a different helper that is actively emitting.

### `LokalBotTests/Services/Audio/EchoCancellerTests.swift`

#### Canceller learns the speaker-to-mic path and subtracts it; tests use a synthetic room
`EchoCanceller`: The echo canceller learns the path from the Mac's speakers back into its
microphone and subtracts it, so the user's own voice is what is left.
Synthetic room here — a delay plus a decaying tail — because a real room's
impulse response is exactly what the filter is supposed to discover.

#### Noise is deterministic and zero-mean; a DC offset would look like eating the voice
`EchoCancellerTests.noise`: Deterministic noise: `Float.random` would make a convergence assertion
flaky for no benefit. Zero-mean matters — a shared DC offset is a real
component the canceller would correctly subtract, which looks exactly
like it eating the user's voice.

#### With headphones the filter must leave the user's voice alone rather than fit noise
`EchoCanceller`: Headphones: nothing of the remote audio is in the microphone, and the
filter must leave the user's voice alone rather than fit noise.

#### Double-talk guard needed; an unguarded filter learns to cancel the user and diverged to -17 dB
`EchoCanceller`: The user talking over the remote side. Without a double-talk guard the
filter learns to cancel *them*, which is worse than no cancellation —
a first attempt diverged to -17 dB exactly here.

#### Envelope resolution is 10 ms frames, biased early so the causal filter reaches the echo
`EchoDelayEstimator.delay`: Envelope resolution is one 10 ms frame, deliberately biased early so
the causal filter can still reach the echo.

#### Cleaned sidecar keeps the microphone's full timeline when the reference ends first
`EchoCancelledTrack.write`: Capture paths do not always stop on the same frame. The reference may
end first, but the cleaned sidecar must retain the microphone's full
timeline so ASR does not lose the user's closing words.

#### Runs the stage on a real meeting folder only when LOKALBOT_AEC_FIXTURE is set
`EchoCancellerTests.testRealMeetingFolderIfProvided`: Runs the whole stage over a real meeting folder when one is pointed at,
so the numbers in the log come from actual audio rather than a model of
it. Skips by default — no fixture, no network, no fixed path.

#### Keep the cleaned track when a path is given, to measure beyond the filter's ERLE
`EchoCancellerTests.testRealMeetingFolderIfProvided`: Keep the result when a path is given, so the cleaned track can be
measured against the original instead of only being scored by the
filter's own ERLE.

### `LokalBotTests/Services/Audio/MediaPlaybackPauseTests.swift`

#### A browser pause script cut off by its time limit is still resumed
`MediaPlaybackController.pausedTarget`: With sixty tabs open the browser script paused the video in tab 3 and
was stopped at its time limit before it could report. Nothing was
recorded, so the video stayed paused after the dictation.

#### A player's script is one command, so cut off means it did not run
`MediaPlaybackController.pausedTarget`: A player's script is one command: cut off means it did not run.

#### A script that cannot run, such as without Automation permission, resumes nothing
`MediaPlaybackController.pausedTarget`: The script could not run at all, for example without Automation permission.

### `LokalBotTests/Services/Audio/MicRecorderFileInputTests.swift`

#### File input feeds the real writer, tee and health path for UI background host and CI
`MicRecorder`: The real writer, preview tee, and health path, fed from a file instead of
the microphone — what the UI background host and CI use.

#### Closed MacBook lid yields digital silence (#373) that must not count as signal; -69 dBFS does
`MicRecorder`: \#373: a closed MacBook lid leaves the default input writing digital
silence. Those writes must not count as signal, while a room-noise
level input (about -69 dBFS) still does.

### `LokalBotTests/Services/Audio/MicRecordingFileTests.swift`

#### AAC bitrate must be accepted at any input rate; Bluetooth HFP exposed the bug
`MicRecorder.makeRecordingFile`: The capture file is opened with a bitrate the AAC encoder has to accept at
whatever rate the input device runs. These tests need no microphone — only
the encoder — which is why the original defect went unnoticed: nothing
exercised the combination a Bluetooth headset produces.

#### Bluetooth HFP at 16 kHz makes the encoder refuse 64 kbit/s, failing recording
`MicRecorder.makeRecordingFile`: A Bluetooth headset in HFP mode runs at 16 kHz, where the encoder
refuses 64 kbit/s. That threw '!dat' (560226676) out of
`AVAudioFile(forWriting:)`, so the meeting did not record at all.

#### The chosen bitrate is the ladder's start so healthy devices skip the fallback
`MicRecorder.aacBitRate(forSampleRate:)`: The chosen bitrate is the one the ladder starts from, so a healthy
device never pays for the fallback.

#### The bitrate ladder descends only; retrying upwards swaps one rejection for another
`MicRecorder.aacBitRateLadder`: Descending only: at 8 kHz everything above 24 kbit/s is refused, so
retrying upwards would swap one rejection for another.

#### Dictation scratch files are PCM with no bitrate to negotiate
`MicRecorder.makeRecordingFile`: Dictation scratch files are PCM and carry no bitrate to negotiate.

### `LokalBotTests/Services/Audio/SystemAudioRecorderCopyTests.swift`

#### Interleaved tap buffers need layout-agnostic copy; per-channel memcpy silenced half of each buffer
`SystemAudioRecorder.copyAndMeasureRMS`: Regression tests for the capture callback's raw-buffer copy and RMS path.

The Core Audio process tap delivers *interleaved* stereo. An earlier
implementation copied per-channel with contiguous `memcpy`s over
`floatChannelData`; for interleaved buffers the channel pointers overlap
(`data`, `data + 1`, stride 2), so only the first half of each buffer's
frames were copied and the back half stayed silent — chopping every
recording at sampleRate/frames Hz (93.75 Hz for 512-frame buffers).
These tests pin the layout-agnostic contract: every sample survives the
copy in BOTH layouts, and the returned RMS covers ALL samples.

#### frameLength is set up front, the documented precondition of copyAndMeasureRMS
`SystemAudioRecorderCopyTests.makeBuffer`: Allocates a buffer and sets `frameLength` up front — the documented
precondition of `copyAndMeasureRMS` (destination byte sizes are final).

#### Test helpers walk AudioBufferList since floatChannelData stride semantics caused the bug
`SystemAudioRecorderCopyTests.forEachRawFloat`: Walks the raw floats of every underlying `AudioBuffer` (honest about
the actual memory layout, interleaved or not) and hands each index/
pointer to `body`. `floatChannelData` stride semantics are exactly
what bit the old implementation, so the fill/read helpers deliberately
go through the `AudioBufferList` instead.

#### Nonzero sign-alternating ramp makes any dropped or misplaced sample detectable
`SystemAudioRecorderCopyTests.fillDeterministicRamp`: Fills every raw float (all frames, all channels) with a distinct-ish,
strictly nonzero, sign-alternating ramp so that any dropped, zeroed,
or misplaced sample is detectable.

#### Destination is zeroed explicitly so uncopied samples are provably silent
`SystemAudioRecorderCopyTests.zero`: Zero the destination explicitly so the test does not depend on the
allocator handing back cleared memory: with the old bug, un-copied
samples are then *provably* silent, exactly as recorded in the field.

#### A constant fill cannot catch half-traversal, so tests compare to an independent RMS oracle
`SystemAudioRecorderCopyTests.referenceRMS`: Independent RMS oracle over ALL raw samples of `buffer`. A constant
fill cannot catch a traversal that visits only half the samples (RMS
of half the constants is the same constant), so the pattern tests
compare against this instead.

#### Sample read uses channel offset and stride: 2 interleaved, 1 deinterleaved
`SystemAudioRecorderCopyTests.sample`: Frame/channel-addressed sample read, valid for both layouts:
`floatChannelData[channel]` is offset by the channel and consecutive
frames of one channel are `stride` floats apart (2 when interleaved,
1 when deinterleaved).

#### Lossless copy asserts byte equality, back-half frames survive, and RMS covers all samples
`SystemAudioRecorderCopyTests.assertLosslessCopy`: Copies `source` into a fresh zeroed destination and asserts the full
contract: byte-for-byte equality of every underlying `AudioBuffer`,
per-frame survival of the back half (frames >= 256 — the half the old
code silenced), and an RMS computed over ALL samples.

#### Old copy silenced frames 256 and up of a 512-frame interleaved buffer
`SystemAudioRecorderCopyTests.assertLosslessCopy`: The regression's signature: the old per-channel contiguous memcpy
copied only the first half of an interleaved buffer, so frames
>= 256 of a 512-frame buffer came out silent. Assert specifically
that every back-half sample survives, on both channels.

#### RMS must cover all samples; half-traversal RMS differs for the ramp
`SystemAudioRecorderCopyTests.assertLosslessCopy`: RMS must cover ALL samples, not just the ones a broken traversal
happens to visit. The ramp's full-buffer RMS differs from its
first-half RMS, so a half-traversal fails here.

### `LokalBotTests/Services/Audio/SystemAudioRecorderFileTapTests.swift`

#### Keeps its old target when a reattach throws, so an unresolvable process leaves capture untouched
`RecordingController`: RecordingController keeps its old target when a reattach throws, so a
process the tap cannot find must leave the running capture untouched.

### `LokalBotTests/Services/Audio/WaveformAnalysisTests.swift`

#### Each source keeps its own timing and is not stretched
`WaveformAnalysis.decode`: Mic at 0.25s, not stretched to 0.5s.

#### Different file size ensures changed identity on coarse timestamp filesystems
`WaveformAnalysisTests.testReplacingAudioAtSamePathInvalidatesCache`: Different size guarantees a changed identity even on coarse timestamp filesystems.

#### In stereo only the second channel carries audio to guard channel coverage
`WaveformAnalysisTests.writeAudio`: In stereo only the second channel has audio, guarding channel coverage.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
