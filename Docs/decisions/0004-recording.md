# 0004. Recording

- Status: Accepted
- Date: 2026-11-20

## Context

Recording captures a meeting as two tracks, the user's microphone and the call's other side, and keeps them safe through device changes, crashes and quits. The Mac app records with `AVAudioEngine` and a Core Audio process tap into AAC files with append-only CAF copies; the Windows and Linux app records with WASAPI and PulseAudio into WAV files. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Starting, stopping and quitting

### Only the instance holding the library lock closes crash-left recordings, before its engine starts

A crash or power loss leaves `meta.json` without `endedAt`, so the meeting would stay "recording" for good: processing skips live meetings and the player refuses them. At launch, as the macOS app does when it loads a library, each one ends at its audio's last write, or where its longest track ends if that is later, once the WAV headers are repaired, and is queued the way a stopped recording is. Only the instance that holds the library's single-instance lock may do this, and only before its engine starts processing, so a recording that is still running is never closed.

Where: `LinuxWindows/crates/lokalbot-app/src/main.rs` (`main`), `LinuxWindows/crates/lokalbot-engine/src/recording.rs` (`recover_unfinished_recordings`).

### Every exit saves the recording before the app quits

Quitting follows the macOS `applicationShouldTerminate` behaviour: a recording stops and its audio and details are saved before the app goes, with its processing left for the next launch. If something could not be saved, LokalBot stays open and says what to fix, and a later quit tries again. Everything that ends the app goes through `quit.rs`, never straight to `cx.quit()`; an update's relaunch asks the engine itself (`updates::prepare_to_quit`), because the new copy has to start between saving and quitting.

Where: `LinuxWindows/crates/lokalbot-app/src/quit.rs`.

### A meeting cannot be deleted while it is being recorded

The recorder is still writing into that meeting's folder; it can be deleted once the recording has stopped.

Where: `LinuxWindows/crates/lokalbot-app/src/state.rs` (`AppData::delete_meeting`).

### Refuse to start on a nearly full volume

A recording that dies mid-meeting from `ENOSPC` loses the meeting; a clear refusal up front does not.

Where: `LokalBot/Services/Recording/RecordingController.swift` (`RecordingController.start`).

### An interrupted start is deleted only when it holds no audio payload

A damaged file may still have salvageable bytes, so only a start with no audio payload is deleted, never an unreadable recovery journal.

Where: `LokalBot/Services/Recording/RecordingController.swift` (`RecordingController.preserveAudioFromInterruptedStart`).

## Watching a running recording

### Unreadable call state never ends a recording

A missing host or document, or call controls that cannot be read, do not prove the call ended. The authorized capture and its binding stay alive until positive end evidence or the user's Stop, however long observation takes.

Where: `LokalBot/Services/Recording/BrowserMeetingSession.swift` (`BrowserMeetingSession.lifecycleDecision`).

### A silence watch ends recordings nobody is talking in, whatever the call detector knows

The detector reads a call whose state it cannot see as still running. On 2026-11-17 a Meet call ended at 18:52 with its tab left open, the detector got no observation after 18:51, when the app's Swift task pool appears to have stalled, and the recording ran until 10:30 the next morning: 16 hours and 6 GB for 21 minutes of conversation. The watch reads only what the recorders wrote, from the main run loop, so it ends such a recording, a call left open in an empty room, and a manual recording someone forgot.

Where: `LokalBot/Services/Recording/RecordingSilenceWatch.swift` (`RecordingSilenceWatch`).

### Talking means above about -50 dBFS RMS

Speech at a laptop microphone and remote speech in a call sit around -35 to -20 dBFS. An unattended MacBook's microphone, measured overnight on 2026-11-17, stayed between -60 and -100 dBFS and passed -50 dBFS for at most half a second in any minute.

Where: `LokalBot/Services/Recording/RecordingSilenceWatch.swift` (`RecordingSoundMeter.soundRMSThreshold`).

### A microphone writing digital silence is reported, not counted as signal

In #373 a closed MacBook lid left the default input writing digital silence for a whole meeting while the strip said "Receiving audio". Those writes do not count as signal and recording health reports them, while a room-noise input (about -69 dBFS) still counts.

Where: `LokalBotTests/Services/Audio/MicRecorderFileInputTests.swift` (`MicRecorder`), `LokalBotTests/Services/Recording/RecordingControllerTests.swift` (`testHealthReportsAMicrophoneThatWritesOnlySilence`).

### Capture warnings become notifications only when they last

The meeting view shows every warning as it happens; a macOS notification interrupts the call itself, so it is kept for conditions that lasted long enough to matter. On 2026-10-01 a 1.9-second accessibility hiccup and one dropped buffer each raised "Recording needs attention" mid-meeting.

Where: `LokalBot/Services/Meetings/MeetingAudioRecovery.swift` (`CaptureWarningNotifications`).

## Microphone capture on macOS

### A new `AVAudioEngine` for every recording session

A reused engine can hold a stale graph after device changes and then fails with `kAudioDeviceUnsupportedFormat` (`'!dev'`).

Where: `LokalBot/Services/Audio/MicRecorder.swift` (`MicRecorder.input`).

### After a device change, rebuild the whole capture graph and keep the file

Reconfiguration can leave the input node pinned to the previous hardware rate, and reusing that graph makes every retry request the stale tap format. A completely new graph is built, keeping the session's output file and recording format so capture continues in the same file.

Where: `LokalBot/Services/Audio/MicRecorder.swift` (`MicRecorder.rebuildCaptureGraph`).

### `AVAudioEngine` chooses the tap format

During a live device switch, `outputFormat(forBus:)` can briefly report a stale client format while the input unit has already moved to the new hardware rate, and passing that format makes `installTap` raise.

Where: `LokalBot/Services/Audio/MicRecorder.swift` (`MicRecorder.installTapAndStart`).

### Recovery-gap silence is committed only after the rebuilt graph delivers a buffer

A graph can report a successful start and still never produce a buffer, so starting an engine is not evidence. The gate is kept as separate state so failed-retry behaviour is testable without microphone hardware.

Where: `LokalBot/Services/Audio/MicRecorder.swift` (`AudioRecoverySilenceCommitGate`).

### Microphone recoveries can be capped in a sliding window, opt-in

A recovery followed by another configuration change a moment later is not recovered: each rebuild used to reset the retry budget, so a flapping device cycled forever while the recording kept only fragments. The cap is opt-in because a meeting would rather keep fragments than stop.

Where: `LokalBot/Services/Audio/MicRecorder.swift` (`MicRecoveryFlapDetector`).

### The AAC bitrate follows the input's sample rate

The sample rate is whatever the input device runs at, and a Bluetooth headset in HFP mode runs at 16 kHz, where the encoder refuses 64 kbit/s: `AVAudioFile(forWriting:)` threw `!dat` (560226676) and the meeting did not record at all. Measured against the mono encoder, 8 kHz accepts only 24k, 16 kHz accepts 48k/32k/24k, 22.05 kHz accepts 64k to 24k, and 44.1 and 48 kHz accept 64k/48k/32k but not 24k, so no single value covers the range. The tiers sit inside every accepted row with headroom above the minimum; speech at 16 kHz gains nothing from the last few kbit.

Where: `LokalBot/Services/Audio/MicRecorder.swift` (`MicRecorder.aacBitRate`), `LokalBotTests/Services/Audio/MicRecordingFileTests.swift` (`MicRecorder.makeRecordingFile`).

### Real-time buffers move through a lock-free ring

Preallocated buffers pass between Core Audio's real-time thread, the only borrower, and the writer queue, the only returner, through a single-producer/single-consumer ring of buffer indices: only the borrower advances `head`, only the returner advances `tail`. The previous pools used a lock the real-time side could only `try()`, so whenever the writer was returning a buffer at that instant the callback dropped audio although buffers were free; one such drop flagged a 33-minute recording as interrupted on 2026-10-01.

Where: `LokalBot/Services/Audio/RealtimeBufferRing.swift` (`RealtimeBufferRing`).

## Call audio on macOS

### Reattaching the process tap keeps `system.m4a` open

Browser meetings often move output between helper processes, and closing and reopening the file would discard the audio captured before the handoff. The Core Audio process tap switches to the new PID while the existing `system.m4a` writer stays open.

Where: `LokalBot/Services/Audio/SystemAudioRecorder.swift` (`SystemAudioRecorder.reattach`).

### Tap buffers are copied through the `AudioBufferList`, never per channel

The process tap delivers interleaved stereo, where the `floatChannelData` pointers overlap (`data`, `data+1`, stride 2), so a contiguous `frameLength * 4`-byte `memcpy` per channel copies only the first half of each buffer's frames and leaves the rest silent. That chops the track at sampleRate/frames Hz (93.75 Hz for 512-frame buffers), heard as a robotic buzz; it shipped twice and measured on real recordings as a 40× level drop in the back half of every 512 frames. The copy goes buffer by buffer through the `AudioBufferList`, with `destination.frameLength` already equal to `source.frameLength`, every sample survives in both layouts, and the RMS covers all samples and channels.

Where: `LokalBot/Services/Audio/SystemAudioRecorder.swift` (`SystemAudioRecorder.copyAndMeasureRMS`), `LokalBotTests/Services/Audio/SystemAudioRecorderCopyTests.swift` (`SystemAudioRecorder.copyAndMeasureRMS`).

### Electron meeting apps fall back to their `.helper` audio process

Teams, Slack and Webex route call audio through helper processes, as Chromium browsers do, and `audioBundleID` already models that `<host>.helper` relationship for every host. Without the fallback `hasOutputAudio` stays false, the detector never surfaces the app and the process tap is skipped, leaving the meeting recorded mic-only. The host keeps precedence, so apps whose main process emits audio are unaffected.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.rankedOutputAudioProcess`).

### The tap goes on any process that can produce output, never the host PID

Detection asks whether the app is producing output right now; capture only needs a process that can, because a tap on a momentarily silent process records nothing until audio starts. Measured on a real Teams call, the host process owns no Core Audio object, so `AudioHardwarePropertyTranslatePIDToProcessObject` fails for its PID, no sibling is `isRunningOutput` while the meeting is quiet, and a lookup that required current output had the tap refused with `processNotFound`.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.captureTargetProcess`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`MeetingDetector.captureTargetProcess`).

### A tap that delivered nothing is ruled out for the rest of the recording

A tap with no buffer since it attached points at a process with no open output stream, and no waiting turns that into audio. Excluding only the tap in hand lasted one tick: on a real call (log, 2026-08-25 10:36–10:57) the watchdog alternated every 10–15 s for 21 minutes between `modulehost`, which carried the call, and a Teams helper that delivered nothing, and the audible total grew 28 s because each swap discards the audio in flight. `SystemAudioTapLedger` keeps retired processes for the whole recording and `captureTargetProcess` takes an `excluding` set, so another process in the namespace gets a chance instead of one already found empty.

Where: `LokalBot/Services/Recording/RecordingController.swift` (`SystemAudioTapLedger`), `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.captureTargetProcess`), `LokalBotTests/Services/Recording/RecordingControllerTests.swift` (`SystemAudioTapLedger.retire`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`MeetingDetector.captureTargetProcess`).

### Proven standing belongs to a tap, not to the file

A tap that has written audible audio of its own points at the process the call comes out of and is worth the watchdog's long grace. `CaptureHealth.audibleDuration` counts the whole file, so a tap that inherits a healthy total does not inherit that standing; otherwise the first process the watchdog moves to would count as proven before writing a sample.

Where: `LokalBot/Services/Recording/RecordingController.swift` (`SystemAudioTapLedger`), `LokalBotTests/Services/Recording/RecordingControllerTests.swift` (`SystemAudioTapLedger.observe`).

### An unbound recording may hold only an always-open stream

New Teams plays call audio only through `modulehost`, which is open whether or not a call is running (#179), and `captureCandidateApp` can never return it: emitting evidence skips always-open streams, and an idle app needs a binding. The caller taps such a stream without binding the recording, and any verified source may replace it until the tap has carried the call itself; when several apps qualify, only a frontmost one is chosen. A stream that is call evidence (Zoom's) goes through the verified path, and a closed `modulehost` leaves nothing to hold.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.alwaysOpenCaptureCandidate`), `LokalBotTests/Services/Meetings/MeetingAudioRecoveryTests.swift` (`testOnlyAnAlwaysOpenStreamCanBeHeld`).

### Teams' call stream outranks an emitting helper

Because Teams plays the call only through `modulehost`, capture taps it whenever it is open, even while a `.helper` is emitting, and the watchdog never leaves a `modulehost` tap for an emitting helper. A helper's output during a call is a chime or a WebView sound, and one such sound used to win: a scheduled start (issue #596, 2026-11-23) tapped `.helper` for a 701 s call and got one transcript segment (system track mean -54.6 dB), while a manual start the same morning tapped `modulehost` and got 45; on 2026-11-20 the watchdog moved a `modulehost` tap that had already carried 60 s of call audio to the helper after 9 s of silence. A `modulehost` tap that delivers no buffers is still retired, so a closed or empty call stream gives way to the helper.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.captureTargetProcess`, `MeetingDetector.emittingCaptureAlternative`), `LokalBotTests/Integration/CaptureReplayTests.swift` (`testTeamsCaptureStaysOnModuleHostWhileAHelperPlaysSound`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`MeetingDetector.emittingCaptureAlternative`).

## Call audio on Windows and Linux

### Record the meeting app's audio when it can be separated, otherwise the whole output

The "Them" track records the meeting app's sound when it can be separated, so other sounds stay out, and otherwise everything the computer plays, as `SystemAudioRecorder.swift` and `RecordingController.swift` do. The whole output contains the app's sound, so it is always the safe fallback: a tap that cannot open, or an app with no open output stream, never costs the recording its other side. Windows process loopback exists from Windows 10 build 20348.

Where: `LinuxWindows/crates/lokalbot-audio/src/app_audio.rs`, `LinuxWindows/crates/lokalbot-audio/src/app_audio.rs` (`build_has_process_loopback`).

### A call found only by its microphone keeps its app's audio through silence

eXpress, user-chosen call apps and optional browser calls are detected by sustained microphone use, so they can stay active while their app plays nothing. The 10-second no-output fallback would then record every other sound on the computer for the rest of the call, so these targets stay on Windows process loopback, which follows the whole process tree with or without open streams. Only a loopback that is unavailable or fails to open falls back to the whole output.

Where: `LinuxWindows/crates/lokalbot-audio/src/app_audio.rs` (`AppAudioTarget::keep_app_scope`, `ScopeChooser`), `LinuxWindows/crates/lokalbot-engine/src/recording.rs` (`audio_target`), `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs` (`DetectedMeeting::microphone_detected`).

### The process-loopback activation PROPVARIANT never runs its destructor

`ActivateAudioInterfaceAsync` takes a `VT_BLOB` PROPVARIANT whose blob points at `AUDIOCLIENT_ACTIVATION_PARAMS` on the caller's stack, and copies it during the call. In windows-rs, `PROPVARIANT::drop` calls `PropVariantClear`, which frees a `VT_BLOB` with `CoTaskMemFree`; the `ManuallyDrop` inside the union does not stop the outer destructor. Freeing that stack pointer crashed the app with 0xc0000409 on Windows 11 ARM64 (November 2026), so the whole variant is wrapped in `ManuallyDrop` and only borrowed for the call, on success and error alike.

Where: `LinuxWindows/crates/lokalbot-audio/src/process_loopback.rs` (`with_activation_blob`, `activate`).

### A system-audio failure records the microphone alone

The microphone must open unless system audio does; if system audio fails, the microphone records alone with a warning, as on macOS.

Where: `LinuxWindows/crates/lokalbot-audio/src/recorder.rs` (`Recorder::start`).

### A stalled app stream counts as silence in the mix

`StreamMixer` mixes a tap's streams into one track. A stream that stops delivering (it paused, or the app is about to close it) counts as silence once it is `MAX_SKEW` frames behind, so it never holds up the others.

Where: `LinuxWindows/crates/lokalbot-audio/src/app_audio.rs` (`StreamMixer`).

### Quiet WASAPI loopback is silent, not stalled

WASAPI loopback delivers no packets while nothing plays, so a quiet but healthy stream reads as silent rather than stalled.

Where: `LinuxWindows/crates/lokalbot-audio/src/track.rs` (`TrackState.silent_without_packets`).

### Ask for ~30 ms capture buffers

PulseAudio otherwise delivers 2 s fragments, which delays meters and stream start. If the request fails, the device default is used.

Where: `LinuxWindows/crates/lokalbot-audio/src/capture.rs` (`open_stream`).

### Reopen PulseAudio monitors when routing changes

The server resolves `@DEFAULT_MONITOR@` once, so capture restarts when the default output changes. The server also ends a monitor when its sink input moves, so a stream that moved to another device is reopened there.

Where: `LinuxWindows/crates/lokalbot-audio/src/system.rs` (`Capture::default_device_changed`, `AppCapture::sync`).

### App streams match by process or executable, never LokalBot's own

A call's sound can come from another process of the app, so a playing sink input counts if it belongs to the target process or the same executable, in a steady order. LokalBot's own playback never counts.

Where: `LinuxWindows/crates/lokalbot-audio/src/system.rs` (`matching_streams`).

### The PulseAudio handshake is time-boxed

The handshake has no socket timeout, and a hung server must never block recording.

Where: `LinuxWindows/crates/lokalbot-audio/src/system.rs` (`connect`).

## One meeting timeline

### Both tracks are written on one meeting timeline padded with silence

Meeting files use elapsed meeting time, including periods with no captured audio: `meeting.startedAt` is matched once, then monotonic capture timestamps place each buffer against the same origin. Each recorder fills any gap longer than the jitter tolerance with silence before writing, so a late start or system attachment, a reconnect, a microphone or process-tap recovery, or a quiet loopback never shifts later speech earlier, while small clock and resampler jitter does not insert sub-buffer silence. Every reader uses ordinary file time: no consumer may compensate with another offset or skip a newly attached live CAF.

Where: `LinuxWindows/crates/lokalbot-audio/src/track.rs` (`Timeline`), `LokalBot/Services/Audio/RecordingAudioClock.swift` (`RecordingAudioTimeline`), `LokalBot/Services/Recording/RecordingController.swift` (`RecordingController.start`), `LokalBotTests/Services/Meetings/MeetingAudioAssetTests.swift` (`testLateSystemAttachmentPreservesMeetingTime`).

### Windows and Linux recordings need no clock anchors

A Mac keeps `audio-timing.json` with clock anchors (`RecordingAudioTiming`). The Windows and Linux app writes both tracks on the shared timeline, so a `.wav` recording needs no anchors: the same second is the same second.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/timing.rs`.

### Buffers are placed by continuous meeting time and their host-clock age

Core Audio host time can pause during sleep; the continuous meeting clock keeps that gap, while the buffer's age on the host clock keeps callback and queue latency out of its placement. Both observations are captured together in the callback and the placement runs on the writer queue. The test passes 90 seconds of sleep on the continuous clock while the host clock pauses, with the resumed callback arriving 0.1 s after its data.

Where: `LokalBot/Services/Audio/RecordingAudioClock.swift` (`RecordingAudioTimeline.hostTimeOnTimeline`), `LokalBotTests/Services/Meetings/MeetingAudioAssetTests.swift` (`testMeetingClockPreservesSleepTimeAndExcludesCallbackLatency`).

### Version-1 timing sidecars are never read as padded audio

Version 2 captures pad both primary audio and preview CAFs to the timeline origin. Version 1 stays decodable and its spans still map raw file time for echo and identity evidence; loading the sidecar must never reinterpret those files or their saved transcripts as padded audio.

Where: `LokalBot/Services/Audio/RecordingAudioClock.swift` (`RecordingAudioTiming.timelineOriginHostTime`).

## Crash-safe files and recovery

### WAV headers are rewritten every couple of seconds

Windows and Linux meeting tracks are 16 kHz mono 16-bit PCM WAV. The writer rewrites the RIFF and data sizes every couple of seconds, so a crash or power loss leaves a playable file missing at most that much audio, and `repair_wav` recovers the rest of an interrupted file.

Where: `LinuxWindows/crates/lokalbot-audio/src/wav.rs`.

### Each Mac track has an append-only CAF copy that decodes mid-write

A process crash can leave `mic.m4a` / `system.m4a` unreadable because their MP4 containers were never finalized, while the append-only `mic.live.caf` / `system.live.caf` tees stay readable for transcription and playback. The live transcript depends on a mid-write copy of the CAF decoding while the writer is still open, which the AAC `.m4a` tracks fail.

Where: `LokalBot/Services/Meetings/MeetingAudioFiles.swift` (`MeetingAudioFiles`), `LokalBotTests/Services/Audio/AudioPreviewTeeTests.swift` (`AudioPreviewTee`).

### Both apps pick the readable file for each track

When a crash leaves the AAC unreadable or short while the PCM copy stays readable, the copy is the recording. The Mac decodes the AAC to prove it whole; the Windows and Linux app has no decoder and reads structure instead, so an MP4 without a complete `moov`, or with a box that runs past the end of the file, is not readable. On the Mac, the 16 kHz `mic.wav` / `system.wav` tracks of meetings recorded, imported or merged by the Windows and Linux app are read only when a folder has neither an AAC track nor a recovery tee.

Where: `LinuxWindows/crates/lokalbot-core/src/audio_files.rs`, `LokalBot/Services/Meetings/MeetingAudioFiles.swift` (`MeetingAudioFiles`).

### A recovery copy is removed only after its primary track decodes in full

Reading a container header cannot establish that the payload is complete, so recovery copies are retired only after every frame of the primary decodes. After a normal stop the duplicate CAF can go; if finalization failed or the primary is unreadable, the CAF may be the user's only recoverable recording and stays the source for playback and transcription until the user deletes the meeting.

Where: `LokalBot/Services/Audio/AudioFileInspector.swift` (`AudioFileInspector.fullyDecodedDuration`), `LokalBot/Services/Meetings/MeetingAudioFiles.swift` (`MeetingAudioFiles.removeRedundantRecoveryFiles`), `LokalBot/Services/Recording/RecordingController.swift` (`RecordingController.stop`), `LokalBotTests/Services/Meetings/MeetingAudioAssetTests.swift` (`testUnreadablePrimaryFallsBackToCrashSafeCAFWithoutDeletingIt`).

### A crash-left CAF is read as the closed file it would have been

A CAF whose writer never closed it, as a Mac's crash audio (`mic.live.caf`) is, has a data chunk size of -1 for "to the end of the file" and may stop inside a sample. Symphonia's reader takes that -1 and reads the audio as if it were more chunks, so the reader presents the file as closed.

Where: `LinuxWindows/crates/lokalbot-audio/src/decode.rs` (`UnfinishedCaf`).

### Journal recovery rebuilds the contiguous prefix and never shrinks

Recovery decodes the contiguous prefix of chunks, including an unmanifested last chunk left by process death. Corruption never hides an earlier verified interval or compresses a gap, a verified full reconstruction is never replaced by a shorter prefix after a chunk is damaged or goes missing, and an incomplete recovery keeps every original chunk.

Where: `LokalBot/Services/Audio/AudioRecoveryJournal.swift` (`AudioRecoveryJournal.recover`, `AudioRecoveryJournal.reconstruct`).

### Journal chunks are looked up by name

A sixteen-hour recording has about 29,000 checkpoints per track; the recording of 2026-11-17 left 28,712 on one track and 18,016 on the other. Searching the whole manifest for each checkpoint made every launch spend itself on that meeting, and the library never finished loading (2026-11-18), so chunks and segments are indexed by name once.

Where: `LokalBot/Services/Audio/AudioRecoveryJournal.swift` (`AudioRecoveryJournal.reconstruct`), `LokalBotTests/Services/Audio/AudioRecoveryJournalTests.swift` (`AudioRecoveryJournal.recover`).

## Echo cancellation and playback

### Echo cancellation is off by default and needs the Standard microphone mode

An adaptive filter subtracts the system-audio track from the microphone track before transcription; it works on meetings already recorded at the cost of a codec generation, since both tracks are AAC by then, and with headphones it converges to silence and the original track is used. It needs the recording app's microphone mode set to Standard (Control Center → microphone icon → the app's own row): macOS Voice Isolation processes the input nonlinearly, and measured echo return loss drops from ~17 dB to ~3 dB, indistinguishable from noise. The mode is set per capturing app, so the meeting app can keep Voice Isolation for the call while this app stays on Standard. It is off by default while the filter is new, because it rewrites the microphone track every transcription takes as input and the user cannot see that a pass went wrong.

Where: `LokalBot/Models/Settings/AppSettings.swift` (`AppSettings.echoCancellation`).

### The echo canceller has a double-talk guard

Without one, the filter learns to cancel the user when they talk over the remote side, which is worse than no cancellation; a first attempt diverged to -17 dB exactly there.

Where: `LokalBotTests/Services/Audio/EchoCancellerTests.swift` (`EchoCanceller`).

### The cleaned microphone track keeps the microphone's full timeline

Capture paths do not always stop on the same frame and the reference may end first, but the cleaned sidecar keeps the microphone's full timeline so ASR does not lose the user's closing words.

Where: `LokalBotTests/Services/Audio/EchoCancellerTests.swift` (`EchoCancelledTrack.write`).

### The player uses one engine per file

The mic and system files routinely differ in sample rate and channel count; the player loads both and reports the longer duration. The previous composition-based player garbled mismatched tracks during real-time playback.

Where: `LokalBotTests/Services/Meetings/MeetingAudioAssetTests.swift` (`testPlayerLoadsMismatchedFormatTracks`).

### Compressed audio seeks with a fresh reader

Symphonia's MP4 reader cannot seek once it has read to the end, so every seek opens a new reader, and the decoder starts clean.

Where: `LinuxWindows/crates/lokalbot-audio/src/decode.rs` (`CompressedReader::seek_frame`).

## Consequences

- Never delete or shorten a recovery copy (CAF tee, journal chunk, interrupted WAV) until its replacement is proven to decode in full; after a crash it may be the only copy of the meeting.
- Both tracks share one padded timeline and every reader uses plain file time; adding an offset anywhere, or reading a version-1 sidecar as padded, misplaces speech.
- Capture fallbacks keep the recording going (microphone alone, whole output, a held always-open stream, unreadable call state), and silence from a tap or stream is not a failure; only positive end evidence, the silence watch or the user's Stop ends a recording.
