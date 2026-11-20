# 0118. Android app

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `Companion/android/app/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/model/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/pairing/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/recording/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/security/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/sync/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/actions/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/adaptive/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/ask/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/common/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/components/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/format/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/meetings/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/navigation/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/onboarding/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/recording/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/settings/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/text/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/theme/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/timeline/`, `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/today/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/data/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/pairing/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/recording/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/screenshots/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/format/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/meetings/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/people/`, `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/theme/`, `Companion/android/sync/`.

## Decisions

### `Companion/android/app/build.gradle.kts`

#### Sample library is the protocol fixture, copied into APK assets at build time
The sample library ("Try it without a computer") is the protocol fixture itself;
it is copied into the APK's assets at build time instead of into git.

#### Current AndroidX needs the Android 17 SDK to compile; runtime follows targetSdk
`android.compileSdk`: Current AndroidX releases need the Android 17 SDK to compile; runtime
behavior follows targetSdk.

#### One tag ships every platform; versionCode is the Mac build number, only increasing
`defaultConfig.versionCode`: One tag ships every platform; Scripts/release/bump-version.py sets these.
versionCode is the Mac build number, which only ever goes up.

#### Rust sync core is built for arm64-v8a and x86_64 only
`defaultConfig.ndk.abiFilters`: The Rust sync core is built for these two ABIs only.

#### Robolectric for Android 16 needs JDK file descriptor internals opened
`testOptions Robolectric jvmArgs`: Robolectric for Android 16 reaches into the JDK's file descriptor internals.

#### Dependency-version lints disabled because bumps are deliberate, not weekly
`android.lint disable`: New library releases appear weekly; version bumps are deliberate.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/AppContainer.kt`

#### Recordings live beside the database, where the core keeps them (ffi.md)
`AppContainer.recordingsDir`: Where the core keeps recordings: beside the database (Companion/protocol/ffi.md).

#### Flag stays true after the Mac removed this device until the person moves on
`AppContainer.removedByMac`: True after the Mac removed this device, until the person moves on.

#### Recordings kept after Mac removal exist nowhere else; pairing again sends them
`AppContainer.heldRecordings`: Recordings kept after the Mac removed this device. They exist nowhere else,
and the welcome screen says so. Pairing again sends them.

#### Discarding held recordings also erases what is left of the store
`AppContainer.discardHeldRecordings`: Deletes the recordings the welcome screen is holding, with what's left of the store.

#### Name shown in the Mac's approval prompt: previously set, else the system's
`AppContainer.deviceName`: The name the Mac shows in its approval prompt: the one set before, else the system's.

#### Pairing blocks until the person answers on the Mac
`AppContainer.pair`: Pairs with the Mac in [link] as [deviceName]; blocks until the person answers on the Mac.

#### Refuse pairing while recording because the recorder holds the library about to close
`AppContainer.pair`: The recorder holds the current library, which pairing is about to close.

#### Cancelling cannot interrupt the wait; a late allow is saved as a full pairing
`AppContainer.pair`: Cancelling can't interrupt the wait above. If the computer allowed this device
after that, both sides are paired, so it's saved in full like any other pairing.

#### A recording found after a late allow is cut short, kept and sent
`AppContainer.pair`: Only a pairing cancelled here and allowed later can find a recording going.
Its library is about to close: what's recorded so far is kept and sent.

#### Enqueue upload to send whatever was held since the Mac removed this device
`AppContainer.pair`: Whatever was held since the Mac removed this device.

#### Stop the microphone before the core erases the file it writes to
`AppContainer.removeLibrary`: The microphone stops before the core erases the file it writes to.

#### Leaving the sample library keeps held recordings; only removing the device erases them
`AppContainer.removeLibrary`: Leaving the sample library isn't removing this device: what's held stays.

#### Finish only after waiting recordings are sent, keeping the worker process alive
`AppContainer.syncInBackground`: Finishes only when any waiting recording has gone too, which keeps a worker's process alive for it.

#### Wait for the library to load because a worker can start the process
`AppContainer.library`: The library once it's loaded: a worker can be what started this process.

#### After Mac removal the core erased its copy but not unsent recordings; return to welcome
`AppContainer.forget`: The Mac removed this device and the core erased its copy, but not what
hadn't reached the Mac: back to the welcome screen, which holds onto that.

#### Counts recordings existing only here; must not run while recording
`AppContainer.unsentRecordings`: Recordings that exist only here. Nothing can be recording while this runs.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/MainActivity.kt`

#### Extends FragmentActivity because BiometricPrompt requires one
`MainActivity`: A FragmentActivity because BiometricPrompt needs one.

#### Restored state may say unlocked for days; only a quick restart skips the lock
`MainActivity.onCreate`: Restored state says "unlocked" for as long as Android keeps it, which can be days after
it ended the process. Only a restart soon after the app was left may skip the lock.

#### Turning the app lock on asks to authenticate once, avoiding self lockout
`MainActivity.onCreate`: Turning the lock on asks once, so nobody locks themselves out.

#### Timestamp uses a clock that resets on reboot, so a future time means restart
`MainActivity.awayTooLong`: [since] is on the clock that restarts with the device, so a time ahead of it is from before a restart.

#### The recording notification opens the recording screen
`MainActivity.showRecorderIfAsked`: The recording notification opens the recording screen.

#### Hide recents screenshot on Android 13; older versions use FLAG_SECURE, blocking screenshots
`keepOutOfRecents`: With the app lock on, the recents screen shows no picture of the library: the
lock only comes down after a while in the background, and the system takes
that picture on the way out. Android 13 can leave just that picture out, so
the person's own screenshots still work, as on iOS. Earlier versions can only
mark the whole window secure, which stops screenshots too.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/ActionOrdering.kt`

#### Action ordering and filters are shared by every screen (ffi.md ActionRow)
`ActionOrdering`: Action ordering and filters shared by every screen (ffi.md, `ActionRow`).

#### Needs attention shows the user's open actions, matching the Mac
`ActionOrdering.needsAttention`: Today's "Needs attention": your open actions, as on the Mac.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/CompanionRepository.kt`

#### Mirrors the SyncClient API in ffi.md; lists are newest first
`CompanionRepository`: The phone's copy of the Mac's shared library, mirroring the `SyncClient`
API in Companion/protocol/ffi.md. Lists are newest first.

#### Library id scopes view models
`CompanionRepository.id`: Identifies this library; view models are scoped to it.

#### Revision increases whenever the stored records change
`CompanionRepository.revision`: Increases whenever the stored records change.

#### The sample library pins its own day as now
`CompanionRepository.now`: "Now" for this library: the sample library is pinned to its own day.

#### Zone is the one the Mac's calendar days are in
`CompanionRepository.zone`: The zone the Mac's calendar days are in.

#### Return newest meetings plus whether older exist, for scroll-loading lists
`CompanionRepository.newestMeetings`: The newest [limit] meetings and whether older ones exist, for a list that loads as it's scrolled.

#### Queues the status change for the Mac and shows it locally as pending
`CompanionRepository.setActionStatus`: Queues `action.setStatus` for the Mac and shows it locally as pending.

#### Ask stream ends with a terminal event; re-asking after interruption resumes with text so far
`CompanionRepository.ask`: Streams the Mac's answer. Ends with [AskEvent.Done], [AskEvent.Failed] or
[AskEvent.Interrupted]. Asking the same request again after an
interruption picks the answer up; its first delta is the text so far.

#### Recording needs a paired computer to send to
`CompanionRepository.canRecord`: Whether recordings can start here: they need a paired computer to go to.

#### Recordings on this device or just sent, newest first
`CompanionRepository.recordings`: Recordings on this device or just sent, newest first.

#### Adds a recording and returns where to write; null when library cannot record
`CompanionRepository.beginRecording`: Adds a recording and says where the recorder writes; null when this library can't record.

#### Returns false for an empty file, which leaves no recording
`CompanionRepository.finishRecording`: The recorder stopped, so it can go. False when the file was empty, which leaves no recording.

#### Keeps what a dead app wrote; never call while recording
`CompanionRepository.recoverRecordings`: Keeps what an app that died while recording wrote. Never call it while recording. Returns how many.

#### Deletes the recording and its file in any state
`CompanionRepository.discardRecording`: Deletes the recording and its file, whatever its state.

#### A recording the computer refused goes round again on retry
`CompanionRepository.retryRecording`: A recording the computer refused goes round again.

#### Sends waiting recordings and syncs when any arrive so their meetings do too
`CompanionRepository.uploadRecordings`: Sends every waiting recording; when any arrive, syncs so their meetings do too.

#### Returns only meetings the library still shows, excluding merged ones, newest first
`meetingsById`: The meetings with these ids that the library still shows, newest first.

#### Maps RecordingInfo in ffi.md: recording on this device or just sent
`DeviceRecording`: A recording on this device or just sent (`RecordingInfo` in Companion/protocol/ffi.md).

#### Title is empty until named; the computer then picks one
`DeviceRecording.title`: Empty until the person names it; the computer then picks one.

#### Core kinds are meeting, transcript and day, where day is a Day Digest
`SearchHitKind.fromCore`: The sync core's kinds are `meeting`, `transcript` and `day`, which is a Day Digest.

#### Dropped connection after the Mac had the question: it keeps answering, question queued
`AskEvent.Interrupted`: The connection dropped after the Mac had the question; it keeps answering and the question is queued.

#### Tailscale CGNAT, ULA and MagicDNS names count as Tailscale; everything else is local
`routeForAddress`: Tailscale's CGNAT and ULA ranges and MagicDNS names; everything else is the local network.

#### Address forms accepted: host:port, [v6]:port or bare host
`hostOf`: "host:port", "[v6]:port" or a bare host.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/FixtureRepository.kt`

#### In-memory sample library; status changes stay local and show as waiting
`FixtureRepository`: The library from record envelopes held in memory: the built-in sample
library ("Try it without a computer"), previews and tests. Status changes stay
on this device and show as waiting for the Mac, since there is none.

#### Action rows carry the pending flag themselves, as in the synced store
`FixtureRepository.actions`: As in the synced store, a row carries the flag itself.

#### Sample library has no Mac to reach; sync just finishes
`FixtureRepository.sync`: The sample library has no Mac to reach; syncing just finishes.

#### Sample library does not offer recording because no computer receives it
`FixtureRepository.canRecord`: There is no computer to send a recording to, so the sample library doesn't offer it.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/LocalSearch.kt`

#### Substring search for the sample library; synced library uses Rust FTS5
`LocalSearch`: Substring search over records held in memory, for the sample library. The
synced library uses the Rust store's FTS5 index instead.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/RustRepository.kt`

#### Every core call blocks so all run on io; Bonjour results are passed per connection
`RustRepository`: The synced library: the Rust sync core's store on this device
(Companion/protocol/ffi.md). Every call into the core blocks, so they all
run on [io]. Bonjour results are passed to each connection.

#### Callback fires after Mac removal; core already erased its copy
`RustRepository.onRevoked`: The Mac removed this device; the core has already erased its copy.

#### Waiting recordings must still go if this process dies first
`RustRepository.onRecordingsWaiting`: Recordings are ready to go; they should still go if this process dies first.

#### Separate from syncLock so a long upload blocks neither sync nor Ask
`RustRepository.uploadLock`: One upload pass at a time. Apart from [syncLock], so a long upload holds up neither syncing nor Ask.

#### Separate from syncLock so a slow answer holds up no sync
`RustRepository.questionsLock`: One pass over the queued questions at a time. Apart from [syncLock], so a slow answer holds up no sync.

#### Track in-flight request ids so a queued question is not asked twice
`RustRepository.asking`: Request ids being asked right now, so a queued one isn't asked twice at once.

#### Set before the core closes so a losing racer can tell
`RustRepository.closed`: Set before the core closes, so a call that loses the race can tell.

#### Reads racing library close end quietly as cancellation
`RustRepository.alive`: A screen can be reading as the library closes, for instance when the Mac
removes this device. Whoever asked is going away with it, so it ends quietly.

#### One extra row signals more pages; counted raw, never decoded
`RustRepository.newestMeetings`: One row past the page says whether the list goes on. It's counted as the core returned it and never decoded.

#### Core sorts; the others filter is applied phone-side on top
`RustRepository.actions`: The core sorts; "others" is a phone-side filter on top.

#### Sync immediately if the Mac is reachable, else the change stays queued
`RustRepository.setActionStatus`: Send it now if the Mac is reachable; otherwise it waits in the queue.

#### Core queues interrupted question; the next ask picks up the answer
`RustRepository.ask`: The core queued the question; the next ask of it picks up the answer.

#### Deltas arrive on the core's thread while ask blocks; flow ends with event
`RustRepository.ask`: Deltas arrive on the core's thread while ask() blocks; the flow ends with this event.

#### Refresh recordings because an arrived meeting ends its recording's time in the list
`RustRepository.sync`: A meeting that just arrived ends its recording's time in the list.

#### Once the computer answers, waiting uploads run without holding this sync
`RustRepository.sync`: The computer answered, so whatever waits can go, without holding this sync up.

#### Answers can take minutes, so queued questions run outside the sync lock
`RustRepository.sync`: An answer can take minutes. Outside the lock, a change made meanwhile is sent without waiting for it.

#### Ask queued questions once at a time so duplicate syncs do not double-announce
`RustRepository.askQueuedQuestions`: Questions asked while the Mac was away, or whose connection dropped
while it answered: ask them now and announce each answer. A question
Ask is asking right now is left to it. One pass at a time, so a second
sync doesn't announce an answer the first is about to.

#### A new recording id in progress means the previous one has arrived
`RustRepository.uploadWaiting`: The one before it has arrived.

#### Skip reload on revocation because the library is about to close
`RustRepository.uploadWaiting`: On revocation the library is about to close, so nothing should reload from it.

#### Send now if the computer answers; otherwise the app's worker keeps trying
`RustRepository.sendWaitingRecordings`: Sends them now if the computer answers. If it doesn't, the app's worker keeps trying.

#### After revocation, rows left recording are finished and counted as held
`RustRepository.heldAfterRevocation`: What the core kept after revocation: the rows left recording are done now.

#### Stored Mac key may be base64url (QR form) or standard base64
`RustRepository.decodeKey`: The Mac's key as stored at pairing: base64url (the QR form) or standard base64.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/SampleAnswerer.kt`

#### Canned answers from sample records; real answers come from the Mac's Ask agent
`SampleAnswerer`: Answers questions about the sample library from its own records, so the
Ask screen can be tried without a Mac. Real answers come from the Mac's
Ask agent.

#### Sample library is English, so day labels use the English locale
`sampleDay`: "Thu 29 Oct": the sample library is in English.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/model/Records.kt`

#### Records follow schema v1; Mac omits optional fields so all have defaults
Companion records, schema version 1 (Companion/protocol/records.md).
Optional fields are omitted by the Mac, never null, so every optional
property has a default. Unknown keys and enum values are ignored.

#### Absent on older computers; false while the setting is off
`Manifest.recordingsEnabled`: Absent on a computer from before recordings; false while its setting is off.

#### Computer's answer when it did not make a status change sent from here
`SyncNote`: The computer's answer when it didn't make a status change sent from this device (ffi.md, `syncNote`).

#### Reason is shown in the computer's own words
`SyncNote.message`: Why, in the computer's words.

#### Added by this device's store when status changed here and unconfirmed
`MeetingAction.pending`: Added by this device's store, in a meeting's actions: the status was changed here and the computer hasn't confirmed it.

#### Added by this device's store when the computer did not make the last change
`MeetingAction.syncNote`: Added by this device's store, in a meeting's actions: the computer didn't make the last change.

#### Outcome is a decision or an open question
`Outcome`: A decision or an open question.

#### A decision attributed to a meeting, listed on people and projects
`MeetingNote`: A decision attributed to a meeting, as listed on people and projects.

#### Action with its meeting, as returned by SyncClient.actions (ffi.md)
`ActionRow`: An action with its meeting, as returned by `SyncClient.actions` (ffi.md).

#### Set when the computer did not make the last status change sent from here
`ActionRow.syncNote`: The computer didn't make the last status change sent from here.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/pairing/PairingLink.kt`

#### Allow 120 s past expiry like the sync core; the computer's clock decides
`EXPIRY_GRACE_SECONDS`: A code this long past its expiry on this device's clock still goes to the sync core, which
allows the same (`EXPIRY_GRACE_SECS`): the computer's clock decides, so a phone that runs
fast doesn't refuse a code the computer would take.

#### JSON inside lokalbot://pair?d= per protocol.md Pairing
`PairingPayload`: The JSON inside `lokalbot://pair?d=…` (Companion/protocol/protocol.md, Pairing).

#### Equals the k= value the Mac advertises in its Bonjour TXT record
`PairingPayload.fingerprint`: The `k=` value the Mac advertises in its Bonjour TXT record.

#### First 16 hex chars of SHA-256 of the public key, matching the Mac's TXT record
`keyFingerprint`: First 16 hex characters of SHA-256 of a static public key, as in the Mac's TXT record.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/recording/MediaRecorderCapture.kt`

#### Record raw ADTS AAC so killed processes leave readable files; never MP4/M4A
`MediaRecorderCapture`: ADTS AAC straight to the file: every frame carries its own header, so a
killed process or a dead battery leaves a readable file. An MP4 or M4A
container would need finishing on stop and must not be used here.

#### Prefer VOICE_RECOGNITION for flat response and no processing; fall back to MIC
`MediaRecorderCapture.start`: VOICE_RECOGNITION is held by the Android compatibility rules to a flat
response, with noise reduction and automatic gain off by default, so the
file keeps what the room said for the computer's transcription. What MIC
does varies by maker. Not every device offers it, so MIC is the fallback.

#### Permission is checked by RecordingService before capture starts
`MediaRecorderCapture.started`: RecordingService checks the permission before it asks for this.

#### stop() throws when nothing was captured; the file is kept either way
`MediaRecorderCapture.stop`: Throws when nothing was captured yet; the file is what it is either way.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/recording/MeetingRecorder.kt`

#### Microphone state followed by both the recording screen and RecordingService
`RecorderState`: What the microphone is doing. The recording screen and [RecordingService] both follow it.

#### Recording requested but the service has not started the microphone yet
`RecorderState.Starting`: Asked to record; the service hasn't got the microphone going yet.

#### Failure stays shown until the person closes it
`RecorderState.Failed`: Shown until the person closes it.

#### Microphone would not start and no recording exists
`RecorderProblem.CouldNotStart`: The microphone wouldn't start, and there's no recording.

#### Stopped with an empty file, which leaves no recording
`RecorderProblem.NothingRecorded`: It stopped with an empty file, which leaves no recording.

#### Failed partway; written audio is kept and sent to the computer
`RecorderProblem.Interrupted`: It failed partway. What was written is kept and goes to the computer.

#### start throws when the microphone cannot start
`AudioCapture.start`: Starts writing to [path]. Throws when the microphone can't start.

#### Returns loudest sample since last call, range 0 to 32767
`AudioCapture.maxAmplitude`: The loudest sample since the last call, 0 to 32767.

#### stop never throws and releases the microphone; written data stays
`AudioCapture.stop`: Stops and lets go of the microphone. Never throws; what was written stays.

#### Single process-wide recording outlives activities; the core owns row and file location
`MeetingRecorder`: The one recording in progress, for the whole process: it outlives any
Activity, because [RecordingService] keeps the process alive, so screens read
their state from here. The core owns the row and the file's location.

#### True while the person left the app recording in the background
`MeetingRecorder.screenHidden`: True while the person has gone back to the app and left it recording.

#### Screen opens at once; returns false if already recording, showing it instead
`MeetingRecorder.requestStart`: The screen opens at once. False when a recording is already going, which it shows instead.

#### Used when the service cannot reach the foreground, so no microphone
`MeetingRecorder.failToStart`: The service couldn't get into the foreground, so the microphone can't start.

#### The service calls begin once it is in the foreground
`MeetingRecorder.begin`: Called by the service once it's in the foreground.

#### Ends with what exists and hands it to the core; problem explains unrequested stops
`MeetingRecorder.stop`: Ends the recording with what's there and hands it to the core; [problem] says why, if it wasn't asked for.

#### Any other finish failure leaves the row for the next launch to recover
`MeetingRecorder.stop`: Any other failure leaves the row as it is, for the next launch to recover.

#### Discard stops and deletes so nothing reaches the computer
`MeetingRecorder.discard`: Stops and deletes the recording: nothing reaches the computer.

#### Release the microphone only; core erases row and file on device removal, keeps them if Mac removed
`MeetingRecorder.abort`: The library is going, or has gone: lets go of the microphone and leaves
the row and the file to the core. Removing the device from here erases
them; if the Mac removed it, they stay for when it pairs again.

#### At startup, recordings cut short by a dead process become normal waiting ones
`MeetingRecorder.recoverIfIdle`: At startup: a recording cut short by a dead process goes on as a normal waiting one.

#### Meter level ranges 0 to 1
`MeetingRecorder.level`: How loud it is right now, for the meter: 0 to 1.

#### Decibel scale so quiet speech across a room still moves the meter
`meterLevel`: A sample's loudness on a decibel scale: quiet speech across a room still moves the meter.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/recording/RecordingService.kt`

#### Foreground service keeps recording alive; not restarted if killed, next launch recovers
`RecordingService`: Keeps a recording alive with the screen off or the app in the background,
and says so in an ongoing notification. [MeetingRecorder] does the recording.
Not restarted if its process dies: the next launch recovers what was written.

#### Android 10 has no microphone foreground service type
`RecordingService.onStartCommand`: Android 10 has no type for this, and doesn't ask for one.

#### If stopped externally, stop the recorder and keep what was written
`RecordingService.onDestroy`: Stopped from outside: keep what's there.

#### Notify when recording stops with screen off, since nothing else would say so
`RecordingService.notifyInterrupted`: Recording stopped with the screen off, and nothing else would say so.

#### Without notification permission the notice is silently skipped by the person's choice
`RecordingService.notifyInterrupted`: Without the notifications permission this does nothing, which is the person's choice.

#### Extra on the Activity intent that the notification opens
`RecordingService.EXTRA_SHOW_RECORDER`: On the Activity intent the notification opens.

#### Call while app is visible; Android allows microphone services to start only then
`RecordingService.start`: Call while the app is visible: Android lets a microphone service start only then.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/security/DeviceKeyVault.kt`

#### X25519 key wrapped by Keystore AES-GCM key (StrongBox if present), kept in no-backup storage
`DeviceKeyVault`: Keeps this device's long-term X25519 private key encrypted with an AES-GCM
key that never leaves the Android Keystore (StrongBox when the device has
one). The encrypted key lives in no-backup storage, so it is never copied
to another device.

#### Erasing forgets the device key; pairing again makes a new one
`DeviceKeyVault.erase`: Forgets the device key; pairing again creates a new one.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/sync/AnswerNotifier.kt`

#### Local notification when the Mac answers a question queued while away
`AnswerNotifier`: A local notification when the Mac answers a question queued while it was away.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/sync/MacDiscovery.kt`

#### NSD finds Macs; the Mac's key, not its address, proves identity
`MacDiscovery`: Finds paired Macs on the local network with NSD (Bonjour). The Rust core
takes the resolved "host:port" strings; the Mac's key, not its address,
proves it is the right Mac.

#### Prefer IPv4; link-local IPv6 needs a scope the Rust core cannot use
`MacDiscovery.toMac`: Prefer IPv4; link-local IPv6 needs a scope the Rust core can't use.

#### Paired Mac first; Macs advertising a different key are excluded
`MacDiscovery.orderedAddresses`: The paired Mac first; Macs advertising a different key are left out.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/sync/SyncWork.kt`

#### WorkManager cannot require unmetered-or-VPN, so worker filters metered non-Tailscale itself
`SyncWorker`: Background catch-up with the Mac. WorkManager can't require "unmetered or
VPN" directly, so the worker waits for any network and skips metered
connections that aren't Tailscale (a VPN on Android).

#### Retries until no recordings wait, surviving process death; refused ones wait for the person
`UploadWorker`: Sends waiting recordings, and keeps trying until none are left, so one
stopped out of range goes when the computer is back, even if this process
died in between. A recording the computer deferred waits the same way; one it
refused waits for the person.

#### Replace work so a new recording does not wait out old backoff
`UploadWorker.enqueue`: Starts the tries over, so a new recording doesn't wait out an old backoff.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/CompanionRoot.kt`

#### Device-level state the activity owns: app lock and incoming pairing link
`RootActions`: Device-level state the activity owns: app lock and an incoming pairing link.

#### Re-pairing yields a new library with the same id, so old view models are dropped
`LibraryScopes`: Keeps one library's view models together, and drops them when the library
changes. Pairing again with the same computer is a new library with the same
id, and view models of the old one would keep using its closed store.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/LokalBotApp.kt`

#### Destinations the nav bar omits appear in a More menu in page headers
`LocalOverflowDestinations`: Destinations the navigation bar leaves out, shown from a "More" menu in page headers.

#### Bottom bar compact, rail medium or beside a fold, Mac-like drawer expanded
`LokalBotApp`: The app shell: a bottom bar on compact widths, a rail on medium widths and
beside a fold, the Mac-like drawer on expanded widths.

#### Only a paired library records; the sample library does not offer it
`LokalBotApp`: Only a paired library can record; the sample library doesn't offer it at all.

#### Use rail beside folds and short windows because the drawer would crowd or overflow
`LokalBotApp.suiteType`: Beside a fold, and on short windows such as a phone in landscape, the drawer would
crowd the content or run off the screen.

#### Each destination keeps its scroll and pane state when switching
`LokalBotApp`: Each destination keeps its scroll and pane state while you move between them.

#### Label shrinks to one line at large font scales instead of breaking mid-word
`NavLabel`: A navigation label that shrinks to one line at large font scales instead of breaking mid-word.

#### More button plus record action; with nothing overflowing, only record shows
`OverflowDestinationsButton`: The "More" button for destinations the bottom bar leaves out, and a way to
record from any page unless [offerRecord] says the page has its own. With
nothing left out, recording is the only thing to offer.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/actions/ActionRows.kt`

#### Row shows owner, due date red when overdue, meeting, and unconfirmed or unmade changes
`ActionItemRow`: One action item: the round toggle, the text, and a quiet line with the
owner, the due date (red when overdue), the meeting and any change that
is still waiting for the Mac, or that the Mac didn't make.

#### Show a not-changed note, or the local change vanishes at next sync
`ActionItemRow`: Without this the change made here just disappears at the next sync.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/adaptive/ListDetail.kt`

#### Material 3 list-detail scaffold for four screens; selection survives rotation and folding
`ListDetailLayout`: The Material 3 list-detail scaffold used by Meetings, Actions, People and
Projects: one pane on a phone, both on wider windows and on either side of
a fold, with predictive back. Selection survives rotation and folding.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/adaptive/WindowLayout.kt`

#### Vertical fold separating the screen, as in book posture
`WindowLayout.bookHinge`: A vertical fold that separates the screen, as in book posture.

#### Horizontal fold with device half open, as in tabletop posture
`WindowLayout.tabletopHinge`: A horizontal fold with the device half open, as in tabletop posture.

#### True under 480 dp tall, such as a phone in landscape
`WindowLayout.heightCompact`: Under 480 dp tall, such as a phone in landscape.

#### Two panes from medium width, list about 40%, split exactly along a vertical hinge
`rememberPaneDirective`: A list-detail directive: two panes from medium widths, the list sized to
about 40% of the space, and, with a vertical fold, the panes split exactly
along the hinge so nothing sits under it.

#### Measure scaffold origin so a hinge can be located in its coordinates
`PaneHost`: Measures where the pane scaffold starts in the window, so a hinge can be found in its coordinates.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/ask/AskScreen.kt`

#### Mac's editorial layout; tabletop puts answer upright and composer flat
`AskScreen`: Ask: the Mac's editorial reading layout (no bubbles, the question in
semibold, numbered teal source badges) with the composer docked below.
Tabletop posture puts the answer on the upright half and the composer on
the flat half.

#### On return from lock or another app, pick up an answer the Mac kept writing
`AskScreen`: Back from the lock screen or another app: pick up an answer the Mac kept writing.

#### Teal marks the Mac's own engine, amber an approved remote one
`AnswerLocationLine`: Where the answer was produced: teal for the Mac's own engine, amber for an approved remote one.

#### Sync-core match words shown semibold, as on iPhone
`highlighted`: A search snippet with the words the sync core marked as matches in semibold, as on iPhone.

#### Hardware Enter sends; Shift+Enter inserts a newline
`AskScreen composer`: A hardware Enter sends; Shift+Enter starts a new line.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/ask/AskViewModel.kt`

#### Waiting: connection dropped while the Mac answered; answer collected later
`TurnPhase`: [Waiting]: the connection dropped while the Mac answered; it keeps answering and the turn picks the answer up later.

#### Connection dropped once while the Mac answered, so the question is queued
`AskTurnState.interrupted`: The connection dropped once while the Mac answered, so the question is queued.

#### When picking up an answer, the next delta is the whole text so far
`AskTurnState.restartText`: Picking up an answer: the next delta is the whole text so far.

#### Questions go to the Mac; offline, phone offers local search and a queue
`AskViewModel`: Questions go to the Mac, which streams the answer back with citations.
When the Mac can't be reached the phone offers its own search and a queue.

#### A background sync may deliver a waiting answer before Ask does
`AskViewModel.init`: A background sync may pick up a waiting answer before Ask does.

#### Resume dropped answers, e.g. when the phone is unlocked again
`AskViewModel.resumeWaiting`: Picks up answers whose connection dropped, e.g. when the phone is unlocked again.

#### The Mac sends the text so far as the first delta
`AskViewModel.resumeWaiting`: The Mac sends the text so far as the first delta.

#### Interrupted question is already queued, so when unreachable it keeps waiting
`AskViewModel.run`: An interrupted question is queued already: out of reach, it keeps waiting.

#### Cut-off or queued turns get their answer from a sync
`AskViewModel.awaitsAnswer`: A turn whose answer a sync brings: cut off while the Mac answered, or queued for when it's back.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/common/PageLayout.kt`

#### Phones use tighter margins; wide windows use the Mac's 28 pt
`pagePadding`: Page margins: tighter on phones, the Mac's 28 pt on wide windows.

#### Bottom bar already clears the nav bar inset; rails and drawers do not
`pageContentPadding`: A bottom bar already sits above the system navigation bar; rails and drawers don't.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/components/ActionToggle.kt`

#### Reminders-style toggle: open circle, teal check done, dash deferred; toggles open/done
`ActionToggle`: The round, Reminders-style action toggle (`ActionItemToggleStyle`): an
empty circle when open, a teal check when done, a dash when deferred.
Toggling marks an open action done and anything else open.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/components/Badges.kt`

#### White on accent fill, matching the Mac's Evidence list
`SourceBadge`: A numbered teal source badge: white on the accent fill, as on the Mac's Evidence list.

#### Tint chosen from name, matching the Mac's InitialsAvatar
`InitialsAvatar`: A person's initials on a tint chosen from their name (`InitialsAvatar`).

#### Tint chosen from name, matching the Mac's ProjectMonogram
`ProjectMonogram`: A project's first letter on a tint chosen from its name (`ProjectMonogram`).

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/components/MarkdownText.kt`

#### Mac Markdown rendered as editorial reading column without chat bubbles
`MarkdownText`: Renders the Mac's Markdown with LokalBot type: no bubbles, an editorial reading column.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/components/ProportionBar.kt`

#### Capsule split by tracked-time share, mirroring the Mac's ProportionBar
`ProportionBar`: The activity overview bar: a capsule split by share of tracked time (`ProportionBar`).

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/components/Surfaces.kt`

#### Mirrors the Mac's lbGroupedSurface: quiet fill, hairline stroke, or tinted status
`groupedSurface`: The Mac's grouped surface (`lbGroupedSurface`): a quiet fill with a
hairline stroke, or a tinted status surface when [tint] is set.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/components/SyncPill.kt`

#### Pill reads 'Synced with your computer, age, route' showing when copy was current
`SyncPill`: "Synced with your computer · 2 min ago · Wi-Fi": when this copy was last current, and how.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/components/ToolbarTabs.kt`

#### Hidden semibold copy of each title reserves width so control never resizes
`ToolbarTabs`: Equal-width capsule tabs with a sliding teal knob (`ToolbarTabs`). The
selected tab is white on the accent fill; a hidden semibold copy of each
title reserves its width so the control never changes size.

#### Tab titles shrink rather than clip in narrow panes or large font scale
`ToolbarTabs`: Shrinks rather than clips when the pane is narrow or the font scale large.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/format/Formats.kt`

#### Language-dependent words come from string resources
`RelativeWords`: Words that depend on the app's language, from string resources.

#### Dates, times and durations follow the Mac's style in the person's locale
`Formats`: Dates, times and durations the way the Mac shows them, in the person's locale.

#### Meeting times use the Mac's offset at the time of the meeting
`Formats.meetingTime`: Meeting times use the Mac's offset at the time of the meeting.

#### Recording times use this device's zone, not the Mac's
`Formats.recordingMeta`: "Today · 10:30 · 42 min", in this device's time.

#### Must match the Mac's CaptureStyle.hm format
`Formats.duration`: The Mac's `CaptureStyle.hm`: "\<1m", "42m", "1h 5m".

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/meetings/MeetingRow.kt`

#### Row layout matches the Mac's meeting list
`MeetingRow`: Title over "Zoom · 10:30 · 42 min", as in the Mac's meeting list.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/meetings/MeetingsScreen.kt`

#### A link with a moment stays until the transcript has scrolled to it
`MeetingsScreen`: A link with a moment stays until the transcript has scrolled to it.

#### Until the list reaches its end, subtitle shows only the listed count
`MeetingsScreen`: Until the list has reached its end, only how many are listed is known.

#### Focus only on press on touchscreens so pane focus does not open the keyboard
`SearchField`: The quiet search field used above lists. On a touchscreen it takes focus only
when pressed: the pane scaffold gives its pane focus on arrival, which would
otherwise land here and open the keyboard, including on the way back from
recording. Accessibility services and keyboards don't press, so they can always.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/meetings/MeetingsViewModel.kt`

#### Total is library size, or count listed so far while hasMore
`MeetingsState.total`: How many meetings the library holds, or how many are listed so far while [hasMore].

#### Count grows by a page as the list is scrolled to its end
`MeetingsViewModel.listed`: How many meetings the list has asked for so far; it grows as the list is scrolled to its end.

#### Cache stripped meetings during search so each keystroke filters in memory
`MeetingsViewModel.searched`: Every meeting without its long texts, kept while a search is open so each keystroke filters in memory.

#### Manifest may be stale, so it only explains and never blocks recording
`MeetingsViewModel.recordings`: "From this device". The manifest can be stale, so it only explains; it never blocks recording.

#### Search covers whole library; drop summaries and notes since rows need only title, time, app
`MeetingsViewModel.load`: A search looks through the whole library, not just the part the list has loaded.
A row shows a title, a time and an app, so the summaries, notes and action items needn't stay in memory.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/navigation/AppNavigator.kt`

#### Follows Mac sidebar order, with Actions promoted for phones
`Destination`: Top-level destinations, in the Mac sidebar's order, with Actions promoted for phones.

#### One-shot cross-screen links; destination survives rotation, scaffolds save pane selection
`AppNavigator`: The selected destination plus one-shot links between screens (a citation
opening a meeting, a person opening Ask). The destination survives
rotation and folding; pane selections are saved by each scaffold.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/onboarding/OnboardingScreens.kt`

#### Recordings kept after Mac removed this device; pairing again sends them
`HeldRecordings`: Recordings kept after the Mac removed this device. Pairing again sends them.

#### Scan or paste link, confirm, then wait for approval on the Mac
`PairingScreen`: Pairing: scan the QR code the Mac shows (or paste its link), confirm, then
wait while the person approves this device on the Mac.

#### View model outlives the screen, so restart it for re-pairing
`PairingScreen`: The view model outlives this screen, and pairing again starts over.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/onboarding/PairingViewModel.kt`

#### The Mac is asking the person to allow this device
`PairingStep.Waiting`: The Mac is asking the person whether to allow this device.

#### Name is what the Mac shows when asking to allow this device
`PairingViewModel.deviceName`: The name the Mac shows when it asks whether to allow this device.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/onboarding/QrScanner.kt`

#### QR read on-device with ML Kit bundled model; nothing is sent anywhere
`QrScanner`: A camera preview that reads QR codes on the device with ML Kit's bundled
model; nothing is sent anywhere. Calls [onCode] with each QR payload seen.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/recording/DeviceRecordings.kt`

#### Computer has it; row stays until the meeting arrives
`RecordingStatus.Processing`: The computer has it; the row stays until the meeting arrives.

#### Deleting destroys the only copy, so confirmation is required
`DeleteRecordingDialog`: Deleting destroys the only copy, so it asks.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/recording/RecordingHost.kt`

#### Record action is null when the library cannot record
`LocalRecordAction`: Starts a recording, or returns to the one going. Null when this library can't record.

#### After permanent denial Android offers only system settings
`promptAfterDenial`: What follows a denied microphone. Android stops offering its own prompt
after "don't ask again", which leaves only system settings.

#### Ask for microphone plus notification; recording proceeds without notification
`permissionsToAsk`: The microphone, plus the notification on recent Android. Recording goes ahead without the notification.

#### Save app scroll and pane state while recording screen covers it
`RecordingHost`: Keeps the app's scroll and pane state while the screen covers it.

#### Provides LocalRecordAction and walks through microphone permission flow
`RecordingAccess`: Provides [LocalRecordAction] to [content], and walks the person through the microphone permission.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/recording/RecordingScreen.kt`

#### Recording state lives in recorder so it survives Activity recreation
`RecordingScreen`: The recording in progress. All of its state lives in [recorder], so it survives a recreated Activity.

#### Meter level falls slowly so it reads as a level
`RecordingScreen level meter`: Falls slowly, so it reads as a level instead of a flicker.

#### Phone on its side lays out side by side to keep Stop visible
`RecordingContent layout`: A phone on its side: side by side, so Stop and the caption stay on screen.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/settings/SettingsScreen.kt`

#### Unsent recordings are the ones removing the device deletes
`SettingsViewModel.unsentRecordings`: Recordings that haven't reached the computer, which removing this device deletes.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/text/Markdown.kt`

#### Markdown handles only the small subset the Mac writes
`Markdown`: The small Markdown subset the Mac writes into summaries, digests, notes and
answers: headings, bullet and numbered lists, paragraphs, **bold**,
*italic*, `code` and `[n]` citation markers.

#### Section runs to next heading at same or higher level
`Markdown.section`: The Markdown under the heading [title] (any level), up to the next heading at that level or above.

#### [n] becomes a citation only when n is in the citation set
`Markdown.inline`: Inline runs; `[n]` becomes a citation only when [citations] contains n.

#### Normalise [1, 2] and convert Mac meeting markers into numbered citations
`Citations`: Normalises an answer's citation markers: `[1, 2]` becomes `[1][2]`, and
the Mac's `[meeting:ID@HH:MM:SS]` markers become numbered citations that
open the meeting at that moment.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/text/SearchSnippet.kt`

#### Sync core marks matches with « »; sample library marks none
`SearchSnippet`: A search snippet split into plain text and matched words. The sync core's
full-text search marks each match with `«` and `»`; the sample library's
search marks nothing, so its snippets come back as one plain part.

#### Unterminated match mark from a cut excerpt is dropped, words kept
`SearchSnippet.parts`: A mark the excerpt cut short: drop it and keep the words.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/theme/BrandColors.kt`

#### Name-derived colors are identical on every platform
`BrandColors`: Colors derived from names, identical on every platform.

#### Hue is djb2 over UTF-8 with 64-bit wrapping, matching Mac CaptureStyle
`BrandColors.nameHue`: The Mac's `CaptureStyle.color` hue in degrees: djb2 over the UTF-8
bytes with 64-bit unsigned wrapping arithmetic (tokens.json "nameColor").

#### Other is drawn in a quiet grey
`BrandColors.nameColor`: App and project colours on the Timeline. "Other" is quiet grey.

#### Index -1 (grouped or unknown) uses supporting grey
`BrandColors.speakerColor`: Speaker colour for a transcript `colorIndex`; -1 (grouped or unknown) is supporting grey.

#### Mirrors Mac InitialsAvatar.color: speaker color from folded name
`BrandColors.avatarIndex`: The Mac's `InitialsAvatar.color(for:)`: a speaker colour picked from the folded name.

#### Mirrors PeopleDirectory.normalized: fold case and diacritics, single spaces
`BrandColors.normalizedName`: `PeopleDirectory.normalized`: case and diacritics folded, words joined by single spaces.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/theme/LokalBotTokens.kt`

#### Generated from tokens.json by generate.mjs; do not edit
`LokalBotTokens.kt (file)`: Generated by Companion/design/generate.mjs from Companion/design/tokens.json. Do not edit.

#### Animation durations are in milliseconds
`LokalBotTokens.Motion`: Animation durations in milliseconds.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/theme/Motion.kt`

#### Under Remove animations every LokalBot animation is off
`LocalReduceMotion`: True under "Remove animations"; every LokalBot animation is then off.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/theme/Theme.kt`

#### Increase Contrast (Android 14+) strengthens strokes and supporting text
`LocalIncreasedContrast`: Increase Contrast (Android 14+ contrast setting) strengthens strokes and supporting text.

#### Supporting text becomes primary text under Increase Contrast
`LokalBotTheme.supportingText`: Metadata lines: readable grey, primary text under Increase Contrast.

#### Dynamic color off so teal brand holds; colors from tokens.json; Inter type
`LokalBotTheme`: LokalBot's Material 3 theme: dynamic color stays off so the teal brand
holds, colors come from Companion/design/tokens.json, type is Inter.

#### Provide content color so text outside Surface is not black on dark
`LokalBotTheme LocalContentColor`: Text outside a Surface or Scaffold otherwise falls back to
black, unreadable on the dark window.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/theme/Type.kt`

#### Inter font shared with Linux/Windows app, OFL-1.1 licensed
`Inter`: Inter, the interface font the Linux/Windows app also bundles (OFL-1.1).

#### Material 3 sizes in Inter with Mac's heavier title weights
`LokalBotTypography`: Material 3's scalable sizes in Inter, with the Mac's heavier title weights.

#### Text roles mirror Mac tokens.json type on Material styles
`LokalBotType`: The Mac's text roles (tokens.json "type") on Material 3 styles.

#### Tabular figures so time columns line up
`LokalBotType.timestamp`: Times and durations: tabular figures so columns line up.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/timeline/DayViews.kt`

#### Digest sections follow Mac order with Blockers on amber surface
`DigestView`: A Day Digest in the Mac's order: Blockers on an amber surface, then
Highlights, Decisions, Tasks and Follow-ups.

#### Day overview mirrors the Mac DayActivityOverview
`DayOverview`: "Day so far": tracked time, the overview bar by project and its legend
(`DayActivityOverview`).

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/timeline/TimelineScreen.kt`

#### Narrow windows show the rail on demand like Mac's drawer below 820 pt
`TimelineScreen`: The Timeline: a day pane (strip, overview bar, digest, meetings, saved
moments) beside the work-session rail. Narrow windows show the rail on
demand, like the Mac's drawer below 820 pt.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/timeline/TimelineViewModel.kt`

#### Recorded days are those the Mac shared, newest first
`TimelineState.recordedDays`: Days the Mac shared a record for, newest first.

#### Earliest recorded day bounds how far back the day strip goes
`TimelineViewModel.state`: Every recorded day: the earliest one is as far back as the day strip goes.

### `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/today/TodayViewModel.kt`

#### Show yesterday's digest until today's is written
`TodayState.digestDay`: Today's digest, or yesterday's until today's is written.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/AppLockTest.kt`

#### Lock tested on restore from saved state, immediate and after process death
`AppLockTest`: The app lock when the activity comes back from its saved state: at once, as
on rotation, and long after, as when Android ended the process meanwhile.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/TestLibrary.kt`

#### Fixture pinned to Mac generation moment; dates come from fixture
`TestLibrary`: Companion/protocol/fixtures/sample-library.json, pinned to the moment the
Mac generated it. Dates come from the fixture so tests follow it when it
moves.

#### Sample library's now is the manifest generatedAt
`TestLibrary.now`: The manifest's `generatedAt`: "now" for the sample library.

#### Zone is the Mac's offset taken from newest meeting
`TestLibrary.zone`: The Mac's offset, from the newest meeting.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/data/SampleLibraryTest.kt`

#### A row carries the pending flag itself as sync core rows do
`SampleLibraryTest pending actions`: A row carries the flag itself, as the sync core's rows do.

#### Store adds pending and sync note fields per ffi.md
`SampleLibraryTest action decoding`: The store adds these to a meeting's actions (Companion/protocol/ffi.md).

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/pairing/PairingLinkTest.kt`

#### Sync core allows 120 s past expiry on device clock; computer decides rest
`PairingLinkTest`: The sync core allows 120 s past the expiry on this device's clock and leaves the rest to the computer.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/recording/RecordingTest.kt`

#### Large byte counts must not overflow percent calculation
`RecordingTest percentages`: A long recording's bytes don't overflow.

#### Retry when computer deferred or a pass left one behind
`UploadWorker.shouldRetry test`: A computer that deferred it, or a pass that left one behind.

#### Older computer says update; next try may find it updated, so retry
`UploadWorker.shouldRetry test`: An older computer: the rows say to update it, and the next try may find it updated.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/recording/RecordingUiTest.kt`

#### Pairing again is how held recordings after removal get sent
`RecordingUiTest pairing again`: Pairing again is how recordings held after a removal get sent.

#### Robolectric window is not in touch mode, unlike a phone
`RecordingUiTest.show`: Robolectric's window isn't in touch mode, as a phone's is.

#### Search must not take focus returning from recording, opening keyboard
`RecordingUiTest search focus`: Nor on the way back from recording, where it would open the keyboard.

#### Computer's last message wins over a possibly stale manifest
`RecordingStatus.Waiting detail`: What the computer said last wins over a manifest that can be stale.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/screenshots/ScreenshotTest.kt`

#### Record screenshots with recordRoborazziDebug; CI runs verifyRoborazziDebug
`ScreenshotTest`: The app at phone, unfolded-foldable and tablet widths, in light and dark,
plus a foldable in book and tabletop postures. Record with
`./gradlew :app:recordRoborazziDebug`; CI runs `verifyRoborazziDebug`.

#### Welcome text outside Surface once fell back to black on dark
`ScreenshotTest.phoneWelcomeDark`: The welcome screen sits outside any Surface, where text without its own
colour once fell back to black on the dark window.

#### Digits past an hour at large text must not wrap
`ScreenshotTest.phoneRecordingLargeText`: A recording past the hour at large text: the digits must not wrap.

#### Foldable postures use Pixel Fold inner display 841 by 701 dp
`ScreenshotTest foldable postures`: Foldable postures (Pixel Fold inner display, 841 × 701 dp)

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/ViewModelTest.kt`

#### Meeting reads its own actions; scanning the library got slower per meeting
`ViewModelTest waiting changes`: Reading the whole library's actions for this got slower with every meeting.

#### On pickup the first delta is the whole text so far
`AskViewModel resume test`: Picking up: the first delta is the whole text so far.

#### While Mac is out of reach the question stays queued and keeps waiting
`AskViewModel.resumeWaiting`: Still out of reach: the question stays queued, so it keeps waiting.

#### Later sync asks the Mac, which saves the answer, then library signals change
`AskViewModel queued answer`: A later sync asks the Mac, which saves the answer; the library then says it changed.

#### Sync core allows two minutes for a fast clock; older codes expire
`PairingViewModel expiry`: Well past the two minutes the sync core allows for a clock that runs fast.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/format/FormatsTest.kt`

#### Runs on Robolectric for Android's locale-aware date patterns
`FormatsTest`: Runs on Robolectric for Android's locale-aware date patterns.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/meetings/LongHistoryTest.kt`

#### Header says More than 1000 meetings until the end is reached
`MeetingsViewModel hasMore`: The header says "More than 1000 meetings" until the end is reached.

#### Store decides whether older meetings exist from rows read, not usable count
`MeetingsViewModel.hasMore`: Whether older meetings exist is the store's to say, from the rows it read, not from how many it could use.

#### Summary-only matches come from the search index
`MeetingsViewModel search`: In the summary only, so it comes from the search index.

#### Search rows in memory omit long texts
`MeetingsViewModel search rows`: The rows a search keeps in memory carry what a row shows, not the long texts.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/people/PeopleScreenTest.kt`

#### A bare day date that Instant.parse refuses must not break the list
`PeopleScreen lastMetAt`: A bare day, which Instant.parse refuses.

### `Companion/android/app/src/test/java/me/dotenv/lokalbot/companion/ui/theme/BrandColorsTest.kt`

#### Reference hue from Mac CaptureStyle.color, djb2 with UInt64 wrapping
`BrandColorsTest.macHue`: The Mac's `CaptureStyle.color` (LokalBot/Views/CaptureView.swift):
`var hash: UInt64 = 5381; hash = hash &* 33 &+ UInt64(byte)`, hue = hash % 360.

#### Mac folds case and diacritics then hashes scalars h*31+v masked 16 bits
`BrandColorsTest avatar`: The Mac folds case and diacritics, then hashes Unicode scalars with h * 31 + v, masked to 16 bits.

### `Companion/android/sync/build.gradle.kts`

#### Module packages Rust libs built by script; clean deletes them
`sync/build.gradle.kts`: Wraps the lokalbot-sync Rust crate for Android. `Scripts/build/build-sync-android.sh`
writes the shared libraries and the UniFFI Kotlin bindings into build/rust;
this module only packages them. Running `clean` deletes them, so run the
script again afterwards.

#### AndroidX needs Android 17 SDK to compile; runtime follows targetSdk
`sync/build.gradle.kts compileSdk`: Current AndroidX releases need the Android 17 SDK to compile; runtime
behavior follows targetSdk.

#### The JNA AAR carries Android native libraries
`sync/build.gradle.kts jna`: The AAR carries JNA's Android native libraries.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
