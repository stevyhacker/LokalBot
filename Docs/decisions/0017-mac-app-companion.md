# 0017. Mac app: Companion

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Companion/`, `LokalBotTests/Services/Companion/`.

## Decisions

### `LokalBot/Services/Companion/CompanionAskResponder.swift`

#### Meeting markers map to records.md references; screen and file citations stay text only
`CompanionAskCitations`: Turns the agent's `[meeting:ID@HH:MM:SS]` markers into records.md's
`[n]` references and citation list. Screen and file citations stay text
only and never name what they point at.

#### Files are never searched for a device so a stray marker names no file
`CompanionAskCitations.map`: Files are never searched for a device; a stray marker names no file.

#### Agent notes are never searched for a device either
`CompanionAskCitations.map`: Agent notes are never searched for a device either.

#### Agent cites short ids or full UUIDs; only unambiguous match names a meeting
`CompanionAskCitations.resolve`: The agent cites short ids (`SessionLookup.shortID`); a full UUID works
too. Only an unambiguous match names a meeting.

#### Non-extending partials send nothing since the final result replaces streamed text
`CompanionAnswerStream`: Converts the agent's growing answer into the next piece for the phone,
with citation markers already numbered. A partial that is not an
extension of what was sent (the agent restarted its answer) sends
nothing; the final result replaces the streamed text anyway.

#### Device Ask uses shared tools only; window titles gated, no screen, Dream or Personal Context
`CompanionAskResponder`: Answers questions from paired devices with the same Ask agent, Think
engine and remote-inference approvals as Ask on the Mac. Tools are limited
to the classes the person shares: meetings, and the Timeline's activity
summary only when window titles are shared too, because it names windows.
Screen search, Dream memory and Personal Context are never used.

#### Tools read only own finished meetings inside the history window, excluding the sample
`CompanionAskResponder.answer`: The tools read what the Mac shares and nothing else: the person's
own finished meetings inside the history window, which leaves out
the sample meeting, and no Timeline day before that window.

#### Asked-about day or meeting is a starting point, never a limit
`CompanionAskResponder.answer`: The day or meeting a question was asked about is where the answer
starts, never a limit: "Ask About Today" on a tablet once answered
"the library has only one meeting".

### `LokalBot/Services/Companion/CompanionHost.swift`

#### Host exists only while sharing is on; off means nothing listens
`CompanionHost`: Owns the sync host while Settings → Phones & tablets is on: the Mac's
static key, the listener, the Bonjour advertisement, the publisher that
keeps records current, and the device list Settings shows. With sharing
off none of it exists and nothing listens.

#### Blocking host calls run on a dedicated queue, never the main thread
`CompanionHost.serverQueue`: Every blocking call into the host runs here, never on the main thread.

#### With sharing off, in-flight uploads are discarded since devices keep copies
`CompanionHost.discardUploads`: With sharing off nothing can finish arriving, so audio on its way has no
reason to stay. The devices still have their copies.

#### Refresh today while active; reconcile fully daily to withdraw out-of-window records
`CompanionHost.periodicRefresh`: Today's record while there is activity, and a full reconcile once a
day, which also withdraws records that left the history window.

#### Host callbacks arrive on its threads, hop to main actor and block only where protocol waits
`CompanionHost.EventsBridge`: The host's callbacks arrive on its own threads. Each one hops to the
main actor for app state and blocks only where the protocol waits.

#### Crate calls on its own thread and waits, so blocking holds up only this recording
`CompanionHost.EventsBridge.receiveRecording`: The crate calls this on a thread of its own and waits, so blocking
here holds up nothing but this recording.

### `LokalBot/Services/Companion/CompanionLibrary.swift`

#### Library is read-only off main actor and never repairs metadata or recovers pending writes
`CompanionLibrary`: What one companion build reads from the library, loaded off the main
actor straight from the library files, the way the CLI reads them. Nothing
here writes: a build never repairs metadata or recovers pending writes.

#### Shared meetings are own finished ones in window; merged sources, sample and live excluded
`CompanionLibrary.meetings`: The person's own finished meetings inside the history window, newest
first. Merged sources, the sample meeting, and a meeting still being
recorded are left out.

#### Only tracked projects are shared; their UUIDs are record keys
`CompanionLibrary.projects`: Tracked projects only: their UUIDs are the record keys.

#### Preloaded meetings and projections are reused; missing projections are still loaded
`CompanionLibrary.load`: `meetings` and `projections`, when given, are used instead of reading
them again; projections are still loaded for meetings they lack.

#### Dream memory is never read; its projects and review notes stay on the Mac
`CompanionLibrary.load`: Dream memory is never read: its projects and review notes stay
on the Mac, so only tracked projects and recurring topics remain.

### `LokalBot/Services/Companion/CompanionOpApplier.swift`

#### Action ids are content hashes; fall back to unique text match, never guess
`CompanionOpMatcher`: Finds the action a phone's op names. Action ids are content hashes, so
reprocessing a meeting can change them while the phone still holds the
old one; the op's text snapshot then finds the action when exactly one
matches. Anything else is reported back as unmatched, never guessed.

#### Device ops use the same OutcomeIndex path as the Actions list
`CompanionOpApplier`: Applies `action.setStatus` ops from paired devices through the same
`OutcomeIndex` path as the Actions list, so the outcome state, the action
threads, and every derived surface update exactly as for a click on the
Mac.

### `LokalBot/Services/Companion/CompanionPairing.swift`

#### Pairing confirmation blocks the host thread, runs on main, and expires after timeout
`CompanionPairingPrompt`: The confirmation the person answers before a device that scanned the QR
code is paired. The sync host calls in from a background thread and waits;
the alert runs on the main thread and gives up after `timeout`.

#### Blocks the calling thread; must never be called on the main thread
`CompanionPairingPrompt.ask`: Blocks the calling thread. Never call it on the main thread.

#### Unanswered prompt expires with the device's pairing request
`CompanionPairingPrompt.runAlert`: An unanswered prompt expires with the device's pairing request.

#### Neutral instance name plus key fingerprint in TXT so devices recognize the Mac without revealing owner
`CompanionBonjourAdvertiser`: Advertises the listener as `_lokalbot._tcp` on the local network with a
neutral instance name, `LokalBot-XXXX`, and the key fingerprint in its TXT
record, so paired devices recognize this Mac without learning who owns it.
Uses the DNS-SD API directly: the listener itself lives in the sync host.

#### Tailscale addresses are 100.64.0.0/10 and fd7a:115c:a1e0::/48
`CompanionNetwork.classify`: Tailscale hands out `100.64.0.0/10` and `fd7a:115c:a1e0::/48`.

### `LokalBot/Services/Companion/CompanionPublisher.swift`

#### Sink calls block, run on publisher queue; unchanged bodies are no-ops
`CompanionRecordSink`: Where built records go: the sync host while sharing is on, an in-memory
store in tests. Calls block and are made from the publisher's queue.
Publishing an unchanged body is a no-op on the host.

#### Reconcile publishes everything and withdraws gone keys; hooks coalesce narrower rebuilds on a serial queue
`CompanionPublisher`: Keeps the host's records equal to what the library shares. A full
reconcile builds every record, publishes it, and withdraws keys that no
longer exist (deleted, merged, out of the history window, or a class
turned off). Change hooks queue narrower rebuilds, coalesced on a serial
queue, so a burst of edits costs one pass.

#### Changed record scope rebuilds everything; manifest always refreshes
`CompanionPublisher.update`: Replace the settings the records depend on. A different record scope
rebuilds everything; the manifest is always refreshed.

#### Days are passed so deleted or merged meetings still invalidate their day
`CompanionPublisher.meetingsChanged`: Meeting evidence changed: outcomes, notes, processing, deletion or a
merge. `days` names the days the meetings were on, which still matters
for a meeting that no longer exists.

#### Triggered by people or project curation or a project's status note
`CompanionPublisher.connectionsChanged`: People or project curation, or a project's "Where it stands" note.

#### Rebuild today's record when activity was recorded within the window
`CompanionPublisher.refreshTodayIfActive`: Today's Timeline grows while the person works; rebuild today's record
when anything was recorded within `window`.

#### Synchronous rebuild for ops devices wait on; false on timeout
`CompanionPublisher.republishNow`: Rebuild one meeting and what depends on it before returning, for ops
the device waits on. Returns false when the pass did not finish in time.

#### Meeting list is cheap to reread; outcomes reload only for changed meetings
`CompanionPublisher.apply`: The meeting list is cheap to read again; outcomes are reloaded only
for the meetings that changed.

#### Reload meetings, reuse cached projections, rebuild people and projects only when asked
`CompanionLibrary.reloading`: The library again after a change: meetings re-read, outcomes reused
from `cachedProjections` where present, people and projects rebuilt
only when asked.

### `LokalBot/Services/Companion/CompanionRecordBuilder.swift`

#### Record fields are chosen from display-ready sources so emails, speaker evidence, paths and OCR never enter
`CompanionRecordBuilder`: Turns a `CompanionLibrary` into companion records. Pure reads: every field
a record carries is chosen here, from display-ready sources, so attendee
emails, speaker evidence, screenshot paths and OCR text never enter one.
Run off the main actor; `activity` is a read-only connection owned by the
calling thread.

#### Summary drops provenance line and title heading, which the phone draws itself
`CompanionRecordBuilder.shareableSummary`: The summary as the Meetings page shows it: no provenance line and no
title heading, which the phone draws from the record itself.

#### Transcript shares display text only, never attribution, identity evidence or calendar links
`CompanionRecordBuilder.transcriptBody`: Display text, times, display names and a stable color per speaker;
never attribution, identity evidence or calendar identity links.

#### Color 0 is self, 1-7 palette by first appearance, -1 unclear voice
`CompanionRecordBuilder.colorIndex`: 0 is the person themselves, 1–7 the speaker palette in order of first
appearance, -1 a voice that could not be told apart.

#### Day keys cover digests, activity or shared meetings in window, newest first
`CompanionRecordBuilder.dayKeys`: Days that have a digest, recorded activity, or a shared meeting,
inside the history window, newest first.

#### Without window titles class, titles built from window titles fall back to project or apps
`CompanionRecordBuilder.workSession`: A work session as the Timeline rail shows it. Without the window
titles class, a title made from window titles falls back to the
session's project or apps.

#### Overnight review notes stay on the Mac; only meeting-derived points are shared
`CompanionRecordBuilder.whereItStands`: The note's overview and the points taken from meetings. Points from
overnight review notes stay on the Mac with the rest of Dream memory.

#### Raw evidence log stays on the Mac; screen citations become times
`CompanionDigestText`: Day Digest Markdown made fit for a phone: the raw evidence log, which
quotes screen text and window titles, stays on the Mac, and screen
citations become the time of the moment they point at.

#### Screen markers become times; markers with missing captures or bare ones are dropped
`CompanionDigestText.rewritingScreenCitations`: `[screen:42]` becomes "(screen moment at 14:32)"; a marker whose
capture is gone, and a bare `[screen]`, are dropped.

### `LokalBot/Services/Companion/CompanionRecordingReceiver.swift`

#### Matches receive_recording in ffi.md; device name from pairing, rest from device
`CompanionDeviceRecording`: A recording as `receive_recording` describes it (Companion/protocol/ffi.md).
The device name comes from the pairing, the rest from the device.

#### ADTS AAC stays readable if the recorder dies
`CompanionDeviceRecording.supportedFormat`: ADTS AAC, which a recorder that dies leaves readable.

#### Accepted only after meeting is stored since device then deletes its copy; rejected for unfixable, else deferred
`CompanionRecordingReceiver`: Makes meetings of the recordings paired devices send. A device deletes its
copy once it hears `accepted`, so that answer waits until the meeting is
stored; `rejected` is for what no retry can fix, and everything else is
`deferred`.

#### Check whole library including merged sources since ids can't repeat on disk
`CompanionRecordingReceiver.Dependencies.meetingExists`: Anywhere in the library, merged sources included: an id can't be
used twice on disk.

#### Receiver outlives the host, which restarts mid-import when sharing toggles
`CompanionRecordingReceiver.importing`: Outlives the host, which restarts when sharing is switched off and on
while an import goes on.

#### If stored but device never heard, answer accepted again without a duplicate meeting
`CompanionRecordingReceiver.receive`: The Mac stored it but the crash or disconnect came before the device
heard: answer again without making a second meeting.

### `LokalBot/Services/Companion/CompanionRecords.swift`

#### Record types are the allowlist; optionals omitted; instants UTC ISO; days in Mac zone; offsets in audio seconds
`CompanionRecords`: Companion records, schema version 1 (`Companion/protocol/records.md`).

These types are the allowlist: a field reaches a phone only if it is
declared here. Optional fields are omitted from the JSON, never `null`.
Instants are ISO 8601 UTC strings with milliseconds; calendar days are
`YYYY-MM-DD` in the Mac's time zone; offsets inside a meeting are seconds
from the start of its audio.

#### Manifest is a single record set via setManifest, not reconciled
`CompanionRecordKind.reconciled`: Kinds whose keys the publisher reconciles. The manifest is a single
record set through `setManifest`.

#### Host adds the envelope version, seq, sortKey and deleted
`CompanionRecord`: One built record: what the Mac publishes. The host adds the envelope
(`version`, `seq`, `sortKey`, `deleted`).

#### Sorted keys and unescaped slashes make equal content byte-identical so host skips unchanged
`CompanionJSON.encode`: Sorted keys and unescaped slashes, so equal content always serializes
to the same bytes and the host can skip unchanged bodies.

#### UUIDs travel lower case, matching fixtures
`CompanionJSON.id`: Meeting and project UUIDs travel in lower case, as in the fixtures.

#### action.setStatus is the only op in schema version 1
`CompanionSetStatusOp`: `action.setStatus`, the only op in schema version 1.

### `LokalBot/Services/Companion/CompanionServer.swift`

#### CompanionSyncServer adapts lokalbot-sync; calls block so callers stay off main thread
`CompanionServer`: The sync host as the Mac app uses it. `CompanionSyncServer` adapts the
`lokalbot-sync` crate's `SyncServer`; every call blocks, so callers stay
off the main thread.

#### Blocks until the person answers or the prompt expires
`CompanionServerEvents.approvePairing`: Blocks until the person answers or the prompt expires.

#### Republish changed records before returning
`CompanionServerEvents.applyOp`: Applies the op and republishes the records it changed before returning.

#### May return before the answer finishes; output outlives the call
`CompanionServerEvents.ask`: May return before the answer is finished; the output outlives the call.

#### While false devices keep recordings and send no audio
`CompanionServerEvents.acceptsRecordings`: While false a device keeps its recordings and sends no audio.

#### Blocks until meeting stored or impossible; host owns the file, read only
`CompanionServerEvents.receiveRecording`: Blocks until the recording is a stored meeting or can't become one.
The file belongs to the host and is only read.

#### Accepted means the Mac keeps it and the device deletes its copy
`CompanionUploadOutcome.Status.accepted`: The Mac keeps it; the device deletes its copy.

#### Deferred means not now; device keeps it and retries
`CompanionUploadOutcome.Status.deferred`: Not now; the device keeps it and tries again.

#### Rejected means unusable; device keeps it until the person decides
`CompanionUploadOutcome.Status.rejected`: It can't be used; the device keeps it until the person decides.

#### Bundles crate dependencies so controller and publisher test without a listener
`CompanionServerFactory`: Everything the host needs from the crate besides the server itself, so the
controller and the publisher can be exercised without a listener.

#### Key is a non-synchronized Keychain generic password; only private half stored
`CompanionKeyStore`: The Mac's companion key lives in the Keychain beside LokalBot's other
per-install keys: generic password, this app identity's service, never
synchronized. Only the private half is stored; the public half is derived.

### `LokalBot/Services/Companion/CompanionSettings.swift`

#### Raw value is days of history, 0 for all, matching historyDays
`CompanionHistoryWindow`: How far back the copy on paired phones and tablets reaches. The raw value
is the number of days, 0 for all history, as records.md's `historyDays`.

#### Data classes follow records.md manifest order
`CompanionSharing.DataClasses`: The data classes in records.md's manifest, in its order.

#### Transcripts need the meeting record or a phone cannot open them
`CompanionSharing.DataClasses.sharesTranscripts`: A transcript belongs to its meeting: without the meeting record a
phone has nothing to open it from.

#### Window titles are part of the Timeline
`CompanionSharing.DataClasses.sharesWindowTitles`: Window titles are part of the Timeline.

#### Effective classes are what devices receive and the manifest reports
`CompanionSharing.DataClasses.effective`: What devices actually receive, as the manifest reports it.

#### Scope changes rebuild the library; port and Bonjour changes restart the listener
`CompanionSharing.recordScope`: What decides which records exist. Changing only these rebuilds the
library; the port and Bonjour restart the listener instead.

### `LokalBot/Services/Companion/CompanionSyncServer.swift`

#### Uses Vendor/lokalbot-sync built by build-sync-xcframework.sh
`CompanionServerFactory.live`: The `lokalbot-sync` crate: the local package `Vendor/lokalbot-sync`,
built by `Scripts/build/build-sync-xcframework.sh`.

#### Crate calls are blocking and thread-safe; host calls from its own queue
`CompanionSyncServer`: `SyncServer` behind the app's `CompanionServer`. The crate's calls are
blocking and thread-safe; the host calls them from its own queue.

#### loopbackOnly keeps the firewall out of tests
`CompanionSyncServer.init`: `loopbackOnly` is for tests, where it keeps the firewall out of it.

#### Crate writes ISO 8601 UTC with or without fractional seconds
`CompanionSyncServer.date`: The crate writes ISO 8601 UTC, with or without fractional seconds.

#### AskSink works from any thread and ignores calls after the answer ends
`CompanionAskSinkOutput`: `AskSink` works from any thread and ignores calls after the answer ends.

### `LokalBotTests/Services/Companion/CompanionAskResponderTests.swift`

#### A restarted answer sends nothing; the final result replaces it
`CompanionAskCitations stream`: A restarted answer sends nothing; the final result replaces it.

#### Screen memory and Files are never searched for a device
`CompanionAskResponder.scopes`: Screen memory and Files are never searched for a device, whatever Ask on the Mac allows.

#### A device's day is where the answer starts, not a limit on tools
`testDayFromADeviceIsAStartingPointNotALimit`: "Ask About Today" on an iPad once held the question to that day, and
the answer said "the library has only one meeting". The day is now
where the answer starts: the tools still read everything shared.

#### Device questions must not read the sample meeting or one still recording
`testToolsReachOnlySharedMeetingsWithAllHistory`: The shared copy leaves out the sample meeting and a meeting still being
recorded, so questions from a device must not read them either, even
with all history shared.

#### Empty shared set once meant no limit, so a phone was answered from the sample
`testALibraryWithNothingSharedAnswersFromNoMeeting`: A new install's library holds only the sample meeting, so nothing is
shared. The empty shared set once reached the tools as "no limit", and
a phone's question was answered from the sample.

#### Timeline tool must return nothing before the shared window; it was never sent
`testActivityBeforeTheSharedWindowIsNotRead`: The Timeline tool takes any day the model names. With a history
window, a day before it must come back empty-handed: that activity was
never sent to the device.

### `LokalBotTests/Services/Companion/CompanionFixtureLibrary.swift`

#### Fixture holds every private data kind that must never reach a phone
`CompanionFixtureLibrary`: A small synthetic library for companion-record tests. It deliberately
holds every kind of private data that must never reach a phone, each
marked with a distinctive string listed in `secrets`.

#### Private speaker evidence beside a meeting is never read by builders
`CompanionFixtureLibrary.make`: Private speaker evidence beside the meeting; never read by builders.

#### The bundled sample meeting is made up and never shared
`CompanionFixtureLibrary.make`: LokalBot's bundled sample meeting is made up and never shared.

#### Overnight review notes stay on the Mac, not in project status
`CompanionFixtureLibrary.make`: Tracked project with a "Where it stands" note; one point came from
overnight review notes, which stay on the Mac.

#### Dream memory and Personal Context files are never read for records
`CompanionFixtureLibrary.make`: Dream memory and Personal Context files: never read.

### `LokalBotTests/Services/Companion/CompanionOpApplierTests.swift`

#### Phone action.setStatus goes through OutcomeIndex by id, then text snapshot
`CompanionOpApplierTests`: `action.setStatus` from a phone goes through `OutcomeIndex` like a click
in Actions: by id, by the text snapshot when reprocessing changed the id,
and otherwise reported as unmatched.

### `LokalBotTests/Services/Companion/CompanionRecordBuilderTests.swift`

#### Records.md promises privacy exclusions, data classes and a history window
`CompanionRecordBuilderTests`: Companion records built from a synthetic library: their shape, the data
classes and history window, and the privacy exclusions records.md
promises.

#### No record may carry emails, speaker evidence, paths, OCR, agenda, links, Dream, Personal Context
`testNoRecordContainsExcludedData`: The exclusion contract: no record carries attendee emails, speaker
evidence, calendar identity links, screenshot paths, OCR text, agenda
or meeting links, Dream memory, or Personal Context. Deliberately
leaking any one of them fails this test.

#### Transcripts class is off when meetings class is off
`testManifestReportsWhatDevicesReceive`: A transcript needs its meeting.

#### Every released library since 0.6.2 must build schema v1 records
`testEveryReleaseFixtureBuildsSchemaRecords`: Every committed release's library (0.6.2 … current) builds records
that decode as schema v1, one meeting record per own finished meeting.

### `LokalBotTests/Services/Companion/CompanionSettingsTests.swift`

#### Other device controls appear only once sharing is on
`testPhonesAndTabletsTab`: The other controls appear only once sharing is on.

### `LokalBotTests/Services/Companion/CompanionSyncHostTests.swift`

#### Listener is never started so the test binds no port
`CompanionSyncHostTests`: The app's adapter over the `lokalbot-sync` crate: keys, records, and a
pairing offer through the real host store. The listener is never started,
so the test binds no port.

#### The sync crate blocks and the receiver needs the main actor, so hop off it
`testARecordingFromAPairedDeviceBecomesAMeeting`: The crate blocks, and the receiver needs this actor, so hop off it.

#### Fixture is two seconds of tone because import measures real audio
`CompanionTripEvents.writeSpeechlessADTS`: Two seconds of tone, because the import measures real audio.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
