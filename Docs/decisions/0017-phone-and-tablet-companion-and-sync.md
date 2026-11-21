# 0017. Phone and tablet companion and sync

- Status: Accepted
- Date: 2026-11-20

## Context

The Android and iOS companion apps pair with the Mac app or the Windows and Linux app, keep a copy of what the person shares, ask questions about it and send recordings back to become meetings. On the computer, the Mac's `LokalBot/Services/Companion/` and the engine's `companion` module decide what is shared, while the Rust `lokalbot-sync` crate holds the listener, Noise sessions and pairing, and the sync core the phones run. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Turning sharing on

### Nothing listens, is announced or is built while sharing is off

Everything for paired devices exists only while Settings → Phones & tablets is on. Turning it on starts a listener for paired devices on the local network and Tailscale; with it off nothing listens, nothing is announced and no record is built. `lokalbot-sync` holds the listener, Noise sessions and pairing, and the `companion` module decides what is shared (`builder`, `publisher`, `ask`, `ops`, `recordings`, with `host` running the lifecycle).

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/devices.rs`, `LinuxWindows/crates/lokalbot-engine/src/companion/mod.rs`.

### Only the interactive app shares with devices

Only the app itself follows the sharing setting. Tools and examples that start the engine never listen.

Where: `LinuxWindows/crates/lokalbot-app/src/bridge.rs` (`bridge::start`), `LinuxWindows/crates/lokalbot-engine/src/companion/mod.rs` (`CompanionCommand::Enable`).

## Network and discovery

### The computer advertises a neutral name, never its owner

The listener is advertised as `_lokalbot._tcp` with the neutral instance name `LokalBot-XXXX` and the key fingerprint in its TXT record, so paired devices recognize the computer without learning who owns it. Phones browse with Bonjour and NSD and read the Windows and Linux advertisement as they read the Mac's. The Mac uses the DNS-SD API directly, because the listener itself lives in the sync host.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/advertise.rs`, `LokalBot/Services/Companion/CompanionPairing.swift` (`CompanionBonjourAdvertiser`).

### Only loopback, private, link-local and Tailscale addresses may connect

The address filter accepts loopback, private LAN, link-local, IPv6 ULA (Tailscale's `fd7a:115c:a1e0::/48` included) and Tailscale/CGNAT `100.64.0.0/10`. IPv4-mapped IPv6 addresses are unwrapped before the check.

Where: `LinuxWindows/crates/lokalbot-sync/src/net.rs` (`is_allowed_peer`).

### A loopback host always serves 127.0.0.1

Every loopback host (the tests, the engine's development host, the example host) hands out 127.0.0.1, so IPv4 must be served: a host on `[::1]` alone would send phones to whatever else holds 127.0.0.1 on that port, and pairing would fail as if the code were wrong. `[::1]` is extra, for clients that resolve `localhost`, and may be missing. IPv4 and IPv6 ephemeral ports are handed out separately, so with port 0 another port is tried when the one `[::1]` got is taken on 127.0.0.1; a fixed port taken on 127.0.0.1 is an error.

Where: `LinuxWindows/crates/lokalbot-sync/src/server/mod.rs` (`bind_loopback`).

### Discovery hands the sync core addresses only, IPv4 first; the key proves the Mac

Android finds paired Macs with NSD (Bonjour) and passes the resolved "host:port" strings to the Rust core; the Mac's key, not its address, proves it is the right Mac. IPv4 is preferred because link-local IPv6 needs a scope the Rust core can't use.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/sync/MacDiscovery.kt` (`MacDiscovery`, `MacDiscovery.toMac`).

### Android background sync skips metered networks unless they are Tailscale

WorkManager can't require "unmetered or VPN", so the background worker waits for any network and skips metered connections that aren't Tailscale (a VPN on Android).

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/sync/SyncWork.kt` (`SyncWorker`).

## Pairing, keys and removal

### The device checks the Mac's key before revealing its own

In pairing, the client verifies the Mac's key before it sends its own key in the last message.

Where: `LinuxWindows/crates/lokalbot-sync/src/client/mod.rs` (`SyncClient::pair_over`).

### A key the computer never paired learns nothing

A session from a key the computer never paired learns nothing, not even that it reached LokalBot.

Where: `LinuxWindows/crates/lokalbot-sync/src/server/session.rs` (`serve_session`).

### A pairing code still goes to the computer up to 120 s past its expiry

The sync core allows 120 s (`EXPIRY_GRACE_SECS`) past the expiry on the device's clock and leaves the rest to the computer, whose clock decides. The Android and iOS checks before it allow the same, so a phone that runs fast doesn't refuse a code the computer would take.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/pairing/PairingLink.kt` (`EXPIRY_GRACE_SECONDS`), `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/PairingAndMarkdownTests.swift` (`PairingPayloadTests.aCodeJustPastItsExpiryStillGoesToTheComputer`).

### A pairing code never reaches a log

An open pairing offer's code holds a one-time secret, so it is never logged.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/mod.rs` (`CompanionPairing`).

### Android wraps its device key with a Keystore key and keeps it out of backups

The long-term X25519 private key is encrypted with an AES-GCM key that never leaves the Android Keystore (StrongBox when the device has one). The encrypted key lives in no-backup storage, so it is never copied to another device.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/security/DeviceKeyVault.kt` (`DeviceKeyVault`).

### Removing a device revokes its key; the device erases its copy but keeps unsent recordings

Removing a device forgets it and remembers its key as revoked, so a later session from it is told to erase its copy. The device then wipes its local copy, but recordings that haven't reached the computer stay: they exist nowhere else, and removing a device is often the first step of pairing it again. On Android the welcome screen says so, and pairing again sends them.

Where: `LinuxWindows/crates/lokalbot-sync/src/server/store.rs` (`HostStore.remove_device`), `LinuxWindows/crates/lokalbot-sync/src/client/mod.rs` (`SyncClient::finish`), `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/AppContainer.kt` (`AppContainer.heldRecordings`).

## What reaches a device

### Records carry only declared, display-ready fields

The record types are the allowlist: a field reaches a phone only if it is declared there, and the builder picks every field with pure reads from display-ready sources. No record carries attendee emails, speaker evidence, calendar identity links, screenshot paths, OCR or screen text, agenda or meeting links, Dream memory or Personal Context, and a test fails if any one leaks. Dream memory is not even read, so its projects and review notes stay on the Mac and only tracked projects and recurring topics remain. On the Mac the builder runs off the main actor, with `activity` a read-only connection owned by the calling thread.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/builder.rs`, `LinuxWindows/crates/lokalbot-engine/src/companion/records.rs`, `LokalBot/Services/Companion/CompanionRecordBuilder.swift` (`CompanionRecordBuilder`), `LokalBot/Services/Companion/CompanionLibrary.swift` (`CompanionLibrary.load`), `LokalBotTests/Services/Companion/CompanionRecordBuilderTests.swift` (`testNoRecordContainsExcludedData`).

### Record JSON follows one set of conventions

Records are schema version 1 (`Companion/protocol/records.md`, `CompanionRecords.swift`). Optional fields are omitted, never `null`; instants are ISO 8601 UTC strings with milliseconds; calendar days are `YYYY-MM-DD` in the computer's time zone; offsets inside a meeting are seconds from the start of its audio.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/records.rs`.

### Day Digests reach phones without the evidence log or screen citations

The raw evidence log, which quotes screen text and window titles, stays on the computer, and screen citations become the time of the moment they point at.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/builder.rs` (`shareable_digest`), `LokalBot/Services/Companion/CompanionRecordBuilder.swift` (`CompanionDigestText`).

### People and projects for a device come only from meetings it may see

What is shared with a paired device reaches no further than the meetings it may see, so its people and projects are built from only those.

Where: `LinuxWindows/crates/lokalbot-core/src/projects.rs` (`build_people_and_projects_from`).

## Ask from a device

### Device questions use only the classes the person shares

Questions from paired devices use the same Ask agent, Think engine and remote-inference approvals as Ask on the computer. Tools are limited to meetings, plus the Timeline's activity summary only when window titles are shared too, because it names windows. Screen search, Files, Dream memory and Personal Context are never used, whatever Ask on the Mac allows.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/ask.rs`, `LokalBot/Services/Companion/CompanionAskResponder.swift` (`CompanionAskResponder`), `LokalBotTests/Services/Companion/CompanionAskResponderTests.swift` (`CompanionAskResponder.scopes`).

### An empty shared set means no meetings, never no limit

To Ask an empty list means "all meetings", so when nothing is shared the tools get an id no meeting has. A new install's library holds only the sample meeting, so nothing is shared; the empty set once reached the tools as "no limit", and a phone's question was answered from the sample.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/ask.rs` (`AskResponder::answer`), `LokalBotTests/Services/Companion/CompanionAskResponderTests.swift` (`testALibraryWithNothingSharedAnswersFromNoMeeting`).

### Device questions read only the meetings and days the device was sent

The shared copy leaves out the sample meeting and a meeting still being recorded, so questions from a device don't read them either, even with all history shared. The Timeline tool takes any day the model names, so with a history window a day before it comes back empty-handed: that activity was never sent to the device.

Where: `LokalBotTests/Services/Companion/CompanionAskResponderTests.swift` (`testToolsReachOnlySharedMeetingsWithAllHistory`, `testActivityBeforeTheSharedWindowIsNotRead`).

### The day or meeting a question is about is where the answer starts, not a limit

Only the shared window limits a device question. When the day limited it, "Ask About Today" on a tablet once answered "the library has only one meeting".

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/ask.rs` (`AskResponder::answer`).

### An answer outlives the connection that asked for it

A device that disconnects doesn't stop its answer: the computer keeps it in memory for the device to collect (`lokalbot-sync`'s `answers`), and only turning sharing off, or quitting, cancels it. On the device, a drop after the Mac has the question queues the question and fails with `Interrupted`; asking the same request again picks up the answer, with the text so far as the first delta.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/ask.rs`, `LinuxWindows/crates/lokalbot-sync/src/client/mod.rs` (`SyncClient::ask`), `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Data/CompanionStore.swift` (`CompanionStoreError.interrupted`).

## Recordings from devices

### Phones record ADTS AAC, never MP4 or M4A

Every ADTS frame carries its own header, so a killed process, a crash or a dead battery leaves a readable file that loses only the last moments; an MP4 or M4A container would need finishing on stop. On iOS, `AVAudioRecorder` writes ADTS because of the `.aac` extension and keeps recording with the screen locked or the app in the background (the `audio` background mode). The file stays on the phone until the Mac confirms it has it.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/recording/MediaRecorderCapture.kt` (`MediaRecorderCapture`), `Companion/ios/App/Platform/AudioRecorderCapture.swift` (`AudioRecorderCapture`), `LinuxWindows/crates/lokalbot-sync/src/client/recordings.rs`.

### ADTS is decoded to the end, not to the guessed length

ADTS doesn't say how long it is. Symphonia's length is a guess from a few hundred frames and reading stops there, which would cut phone uploads short, so the stream is read to its end.

Where: `LinuxWindows/crates/lokalbot-audio/src/decode.rs` (`Stream::open`).

### Android records from `VOICE_RECOGNITION`, falling back to `MIC`

The Android compatibility rules hold `VOICE_RECOGNITION` to a flat response with noise reduction and automatic gain off by default, so the file keeps what the room said for the computer's transcription. What `MIC` does varies by maker; it is the fallback because not every device offers `VOICE_RECOGNITION`.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/recording/MediaRecorderCapture.kt` (`MediaRecorderCapture.start`).

### Android starts the microphone service only while the app is visible

Android lets a microphone service start only while the app is visible.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/recording/RecordingService.kt` (`RecordingService.start`).

### Cut-short recordings are recovered only at startup

Android keeps what an app that died while recording wrote, and returns how many. Recovery is never run while recording.

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/CompanionRepository.kt` (`CompanionRepository.recoverRecordings`).

### Uploads resume from the partial file's length

A partial file's length is how far an upload got, so a dropped connection resumes where it stopped. Nothing else about an upload is kept until it is whole.

Where: `LinuxWindows/crates/lokalbot-sync/src/server/uploads.rs`.

### Device-supplied ids never name files as they are

Device ids come from the device, so a device's folder of partial files is named by a hash of its id. An upload's id names a file and becomes the meeting's id, so only a UUID is accepted.

Where: `LinuxWindows/crates/lokalbot-sync/src/server/uploads.rs` (`device_directory`, `begin`).

### `accepted` is sent only once the whole meeting is on disk

A device deletes its copy once it hears `accepted`, so that answer waits until the meeting is stored on disk, not just in the cache, and all of the recording is there (a recording that starts loud and goes quiet imports whole). `rejected` is for what no retry can fix, and everything else is `deferred`.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/recordings.rs`, `LokalBot/Services/Companion/CompanionRecordingReceiver.swift` (`CompanionRecordingReceiver`), `LokalBot/Services/Meetings/MeetingImportService.swift` (`MeetingImportService.Plan.isOnlyCopy`), `LokalBotTests/Services/Meetings/MeetingImportServiceTests.swift` (`testARecordingThatStartsLoudAndGoesQuietImportsWhole`).

### A device recording becomes the microphone track, with no screen context

A recording whose id already has a meeting returns that meeting untouched. The device's microphone is the person's own, so it becomes the microphone track: their speech counts as theirs (on the Mac under "My microphone is me"), and other voices in the room are treated as the computer's microphone treats them, not as call participants. Like any import it takes no screen context, because the person wasn't at the computer.

Where: `LinuxWindows/crates/lokalbot-engine/src/library_ops.rs` (`import_device_recording`), `LokalBot/Services/Meetings/MeetingImportService.swift` (`MeetingImportService.importDeviceRecording`).

### Recording titles stay out of logs

The message for a received recording names it, so the title is kept out of the log.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/recordings.rs` (`receive`).

## Changes and the connection

### Changed records reach the device before an op's result

When a device's op is applied, the records it changed are sent before the op's result.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/host.rs` (`Delegate::apply_op`).

### A phone's action op is matched by its text snapshot, never guessed

Action ids are content hashes, so reprocessing a meeting can change them while the phone still holds the old one. The op's text snapshot then finds the action when exactly one matches; anything else is reported back as unmatched.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/ops.rs` (`match_action`), `LokalBot/Services/Companion/CompanionOpApplier.swift` (`CompanionOpMatcher`).

### The publisher polls file stamps for writes no hook sees

Writes from other pages (notes, a new title, people and project choices) reach no change hook, so one stat per file finds them.

Where: `LinuxWindows/crates/lokalbot-engine/src/companion/publisher.rs` (`Publisher.check_for_changes`).

### A packet read gives up at an overall deadline

A peer that keeps sending a few bytes inside every read timeout cannot hold the caller past the deadline: the read returns `None` once it passes without a whole packet.

Where: `LinuxWindows/crates/lokalbot-sync/src/wire.rs` (`PacketReader.read_until`).

### A message's frames are written under one lock

Every thread that writes to an encrypted connection shares its sending half, and a message's frames are written under one lock so messages from different threads never interleave.

Where: `LinuxWindows/crates/lokalbot-sync/src/wire.rs` (`Channel`).

## Phone and tablet apps

### Slow sync work never holds up the screens, uploads or Ask

The Rust sync core's calls block, so on iOS reads and local changes run on one serial queue and pairing, sync and unpairing on another, and a slow Mac never holds up the screens. Uploads get their own queue, because sending a long recording mustn't hold up syncing or Ask, and so does Ask, which the core lets run beside a sync: an answer can take minutes, and a new question mustn't wait for a sync or for a queued question's answer. For the same reason Android sends queued changes outside the sync lock, so a change made during an answer goes without waiting for it.

Where: `Companion/ios/App/Platform/RustStore.swift` (`RustStore`), `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/data/RustRepository.kt` (`RustRepository.sync`).

### Whether more meetings exist is counted in returned rows

A page asks the store for `limit + 1` rows. A meeting this build can't read is left out and must not look like the end of the list, so whether more exist is counted in rows returned, not in rows decoded.

Where: `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Models/StoreTypes.swift` (`MeetingsPage.init(rows:limit:)`).

### Name colours use the Mac's hue formula

Android's name hue is the Mac's `CaptureStyle.color` hue in degrees: djb2 over the UTF-8 bytes with 64-bit unsigned wrapping arithmetic (tokens.json `nameColor`).

Where: `Companion/android/app/src/main/java/me/dotenv/lokalbot/companion/ui/theme/BrandColors.kt` (`BrandColors.nameHue`).

## Consequences

- What a device receives or can ask about is decided only on the computer, by the declared record types and the shared classes; a new field, tool or Ask scope reaches a device only if it is added there, and the exclusion and empty-set tests must keep failing on a leak.
- A device deletes a recording as soon as it hears `accepted`, and keeps unsent recordings even after it is removed; any change to the receive or import path must keep the meeting whole and on disk before that answer.
- Rules shared across platforms (the 120 s pairing grace, the ADTS format, op matching, the name hue, the advertised name) must change on the Mac, in the Rust crates and in the phone apps together.
