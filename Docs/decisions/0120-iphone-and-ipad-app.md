# 0120. iPhone and iPad app

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `Companion/ios/App/`, `Companion/ios/App/Navigation/`, `Companion/ios/App/Platform/`, `Companion/ios/App/Screens/Ask/`, `Companion/ios/App/Screens/Recording/`, `Companion/ios/App/Screens/Settings/`, `Companion/ios/App/Screens/Shared/`, `Companion/ios/App/Screens/Timeline/`, `Companion/ios/App/Screens/Today/`, `Companion/ios/LokalBotCompanionKit/`, `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Data/`, `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/`, `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/`, `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Models/`, `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Platform/`, `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/ViewModels/`, `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/`, `Companion/ios/Scripts/`.

## Decisions

### `Companion/ios/App/LokalBotCompanionApp.swift`

#### Background task ends exactly once whichever of upload or expiry comes first
`BackgroundHold`: A background task that ends once, whichever comes first: the upload
finishing or iOS running out of patience.

#### Upload continues after lock; unfinished work resumes on next sync
`AppEnvironment.holdWhileUploading`: Sending goes on for a while after the screen locks. What doesn't
finish in that time resumes on the next sync.

#### iOS ends an app that overruns; upload resumes anyway
`AppEnvironment.holdWhileUploading`: iOS ends an app that overruns this, and the upload resumes anyway.

#### Resume recording on active; a call may have ended without auto restart
`AppEnvironment.scenePhaseChanged`: A call may have ended while recording couldn't restart by itself.

### `Companion/ios/App/Navigation/AppNavigator.swift`

#### Counters are bumped to trigger search focus or a new question
`AppNavigator.searchRequest`: Bumped to focus the meeting search (⌘F) or start a new question (⌘N).

#### In compact width chosen person or project is pushed, not selected
`AppNavigator.pushPendingUnderMore`: In compact width People and Projects are stacks under More, so a
chosen person or project is pushed rather than selected.

### `Companion/ios/App/Navigation/RootView.swift`

#### Cover stops touches not hardware keyboard, so disable the content while locked
`RootView app lock`: The cover stops touches, not a hardware keyboard: nothing under it takes focus or keys while locked.

#### Tab bar or sidebar follows size class so multitasking modes work
`MainTabs`: The tab bar on iPhone and in compact width; a sidebar like the Mac's on a
full-width iPad. Which one follows the size class, so Split View, Slide
Over, Stage Manager and rotation all work.

#### Sidebar beside content when wide; tab bar in portrait
`MainTabs.tabs`: Beside the content like the Mac's when there is room; a tab bar
in portrait, where an open sidebar would cover the page.

#### Sidebar selection is white on deep teal as on Mac; pages keep teal text
`MainTabs.tabs tint`: The sidebar's selection is white on the deep teal, as on the Mac;
pages keep the text teal (see tab(_:)).

#### Keyboard commands act through navigator, disabled while app is locked
`MainTabs.tabs navigator`: The keyboard commands act through this, so they do nothing while the app is locked.

#### Sync card sits where the Mac shows Storage: this Mac
`SidebarSyncCard`: "Synced with your computer" at the foot of the sidebar, where the Mac shows
"Storage: this Mac".

#### Sync status line refreshes every half minute
`SyncStatusLine`: The sync state as one quiet line, refreshed every half minute.

#### VoiceOver stays on the cover, not the page beneath
`LockCover`: VoiceOver stays on the cover instead of reading the page under it.

### `Companion/ios/App/Navigation/Routes.swift`

#### Links push in place; every stack registers all routes via companionDestinations
`Routes (file)`: Values pushed onto navigation stacks. Links inside a screen push in place
(an evidence pill opens the meeting right there, Back returns), so every
stack registers all of them with `companionDestinations()`.

### `Companion/ios/App/Platform/AudioRecorderCapture.swift`

#### AAC extension gives ADTS stream readable however recording ends; background audio
`AudioRecorderCapture`: The microphone, through `AVAudioRecorder`. The `.aac` extension makes it
write an ADTS stream, whose frames each carry a header, so the file is
readable however recording ends. It keeps recording with the screen locked
or the app in the background (the `audio` background mode).

#### 48 kHz mono 64 kbps gives Mac-equal AAC quality at about 29 MB an hour
`AudioRecorderCapture.settings`: Speech at this rate gives the same AAC quality the Mac records, at
about 29 MB an hour.

#### -50 dB and below reads as silence
`AudioRecorderCapture.level`: -50 dB and below reads as silence.

#### Recorder pauses on interruption; auto resumes if allowed, else person resumes
`AudioRecorderCapture.interruption`: The recorder pauses itself when interrupted. When it's allowed to, it
carries on by itself; otherwise the person resumes from the screen.

#### Only stop() ends recording on purpose and it clears the delegate
`AudioRecorderCapture.audioRecorderDidFinishRecording`: Only `stop()` ends recording on purpose, and that clears the delegate.

### `Companion/ios/App/Platform/BackgroundServices.swift`

#### iOS decides when refresh runs; each run syncs if Mac reachable
`BackgroundRefresh`: Background refresh: iOS decides when; each run syncs if the Mac is reachable.

#### Local notification for queued answers; nothing goes through a push server
`QueuedAnswerNotification`: A local notification when a question asked while the Mac was away gets
its answer. Nothing goes through a push server.

#### Call can stop recording with phone locked; iOS may block restart until app opens
`RecordingPausedNotification`: Recording can stop for a call with the phone locked and nothing on screen to
say so, and iOS may not let it restart until the app is open.

#### Cover window sits above sheets, recording screen and alerts
`AppLock.covers`: The cover above sheets, the recording screen and alerts, which the one in the view tree lies under.

#### Enabling asks once to avoid lockout; disabling requires unlocked app
`AppLock.setEnabled`: Turning the lock on asks once, so it can't lock someone out. Turning
it off needs the app unlocked: the switch is still there under the
cover, where a hardware keyboard could reach it.

### `Companion/ios/App/Platform/DemoLaunch.swift`

#### Debug launch arguments open screens with sample library as paired Mac
`DemoLaunch`: Debug-only launch arguments that open the app on a given screen with the
sample library presented as a paired Mac, for screenshots without UI
automation. For example:

-demoPaired YES -demoSection meetings -demoMeeting \<id> -demoTab transcript

#### With -demoUnreachable waiting recordings stay unchanged
`DemoLaunch recordings`: With -demoUnreachable the waiting ones stay as they are.

#### Demo capture writes few bytes so screenshots never record anyone
`DemoLaunch.capture`: The microphone, or with `-demoPaired` a stand-in that writes a few bytes
and shows a moving level, so screenshots never record anyone.

#### Debug arguments exercise real store against test host without microphone
`DemoLaunch.exercise`: Exercises the real store end to end against a test host:
`-demoPairLink <lokalbot://pair?d=…>` pairs at launch,
`-demoToggleAction <meetingID>/<actionID>` marks an action done, and
`-demoQueueRecording <path>` queues a file as if it had just been
recorded, which sends it without touching the microphone.

#### -demoWidth narrows and compacts window to approximate Split View
`DemoLaunch.Frame`: `-demoWidth 375` narrows the window's content and makes it compact,
approximating Split View and Slide Over widths in screenshots.

#### -demoSizeClass regular keeps narrow window regular like unfolded foldable
`DemoLaunch.Frame.sizeClass`: `-demoSizeClass regular` keeps a narrow window regular, like an
unfolded foldable that reports regular width.

### `Companion/ios/App/Platform/LockCoverWindows.swift`

#### Cover in its own window sits above sheets, alerts and menus
`LockCoverWindows`: Shows the lock cover above everything each of the app's windows presents.
The cover in a window's own view tree lies under that window's sheets, the
recording screen, alerts and menus, which would stay readable while the app
is locked and in the app switcher. This one sits in a window of its own,
above all of them.

#### Raise cover before returning because iOS snapshots the window then
`LockCoverWindows.sceneWillDeactivate`: iOS shows a window in the app switcher from here on, and takes its
picture once it's in the background, so the cover goes up before this
returns instead of waiting for the next view update.

#### Read in-use state from windows because AppLock state lags a view update
`LockCoverWindows.refresh`: With App Lock on, covers every window while the app is locked or none
of its windows is in use, and any window that is in the background.
"In use" is read from the windows themselves as well as from `AppLock`,
whose own state arrives with the next view update. A window named here
is changing state and doesn't report it yet: `leaving` is about to stop
being active, `entering` is coming to the foreground and `active` has
just become active.

#### End editing when locked so a keyboard cannot type under the cover
`LockCoverWindows.refresh`: A keyboard left up would float above the cover and still type into the page under it.

#### VoiceOver reads only the cover window
`LockCoverWindows.cover`: VoiceOver reads this window and nothing under it.

### `Companion/ios/App/Platform/RustStore.swift`

#### Blocking core calls use separate serial queues for reads, sync, uploads, ask
`RustStore`: The device's copy of the Mac's library, kept by the Rust sync core
(Companion/protocol/ffi.md). Its calls block, so reads and local changes
run on one serial queue and pairing, sync and unpairing on another, so a
slow Mac never holds up the screens. Uploads get a queue of their own,
because sending a long recording mustn't hold up syncing or Ask. So does
Ask, which the core lets run beside a sync: an answer can take minutes, and
a new question mustn't wait for a sync or for a queued question's answer.

#### Name the Mac shows when asking to allow this device
`RustStore.deviceName`: The name the Mac shows when it asks to allow this device.

#### Unreadable records are skipped instead of failing the list
`RustStore.decode`: Decodes record JSON; a record this build can't read is skipped rather
than failing the whole list.

### `Companion/ios/App/Platform/StoreFactory.swift`

#### On open failure app still opens with welcome and sample, showing the reason
`StoreFactory.makeStore`: The app still opens (welcome screen, sample library) and says why.

#### Sync core sends name when pairing, so a changed name reopens the store
`StoreFactory.useDeviceName`: Remembers the name the Mac will show for this device. The sync core
sends it when pairing, so a changed name reopens the store first.

#### iOS exposes only the model, so the person names the device when pairing
`DeviceName`: What the Mac calls this device in its approval prompt and device list.
iOS gives apps only the model ("iPhone", "iPad"), so the person names it
when pairing.

### `Companion/ios/App/Screens/Ask/AskScreen.swift`

#### On return from lock screen pick up an answer the Mac kept writing
`AskSplit scenePhase`: Back from the lock screen or another app: pick up an answer the Mac kept writing.

### `Companion/ios/App/Screens/Ask/AskTurnView.swift`

#### Teal marks Mac's own engine; amber marks approved remote engine
`AskTurnView.origin`: Where the answer was produced: teal for the Mac's own engine, amber
for an approved remote engine.

### `Companion/ios/App/Screens/Recording/RecordingScreen.swift`

#### Ask notification permission on this screen, not at a pause when unseen
`RecordingScreen notification permission`: Asked here rather than at a pause, when nobody is looking.

#### Record only offered with a paired computer, the only destination
`RecordToolbarItem`: Starts a recording, or returns to the one that's running. Only with a
paired computer, because that is the only place it can go.

#### After removal, unsent recordings exist nowhere else; pairing again sends them
`HeldRecordingsNotice`: After the Mac removed this device: recordings it hadn't received yet, which
exist nowhere else. Pairing again sends them.

#### Device recordings stay above meetings until their meeting arrives
`DeviceRecordingsSection`: Recordings on this device, above the Mac's meetings, until their meeting
arrives from the computer.

### `Companion/ios/App/Screens/Settings/PairingScreen.swift`

#### Request camera only when there is something to scan
`PairingScreen.scan`: Ask for the camera only when there is something to scan.

#### Sync core takes the link alone, not the pasted text around it
`PairingScreen.step`: The sync core takes the link alone, not the text it was pasted in.

### `Companion/ios/App/Screens/Settings/QRScannerView.swift`

#### VisionKit scanner where supported, AVFoundation metadata reader otherwise
`QRScannerView`: Reads the pairing QR code: VisionKit's data scanner where the device
supports it, an AVFoundation metadata reader otherwise.

#### startRunning blocks so run off main; session touched only here and on stop
`MetadataScannerController.viewWillAppear`: startRunning blocks; the session is only touched here and on stop.

### `Companion/ios/App/Screens/Settings/SettingsScreen.swift`

#### Unreceived recordings exist nowhere else, so removal warns they will be lost
`SettingsScreen.removalMessage`: Recordings that haven't arrived exist nowhere else, so this says so.

### `Companion/ios/App/Screens/Shared/ActionRowView.swift`

#### Pending change shows Waiting for computer, or Not changed if it failed
`ActionRowView`: One action item wherever it appears: the round toggle, the text, then
owner, due date, meeting and evidence. A change made here shows "Waiting
for your computer" until the computer confirms it, and "Not changed on your
computer" if it didn't make it.

#### Meeting link is off inside rows that are links themselves
`ActionRowView.linksMeeting`: Off inside rows that are links themselves.

#### Pill padding is its touch target; negative inset aligns icon with text
`ActionRowView evidence pill`: The pill's own padding is its touch target; align its icon with the text.

#### Without the note a failed change silently disappears at next sync
`ActionRowView note`: Without this the change made here just disappears at the next sync.

### `Companion/ios/App/Screens/Timeline/SessionRail.swift`

#### Mark gaps of 45 minutes or more as away time
`SessionRail.awayGap`: Time with nothing recorded before a session, when it is long enough to mark.

### `Companion/ios/App/Screens/Timeline/TimelineScreen.swift`

#### From 820 pt rail sits beside day; below it sessions open in a drawer
`TimelineScreen`: Any day's activity: the day strip and calendar, the activity overview, the
digest, meetings and the work-session rail. From 820 pt the rail sits
beside the day and a session opens in place of the day; below that the
sessions follow the day and a session opens in a drawer, as on the Mac.

### `Companion/ios/App/Screens/Today/TodayScreen.swift`

#### Side-by-side layout from about 760 pt
`TodayScreen.wide`: Side by side from about 760 pt: the work on the left, the digest on the right.

### `Companion/ios/LokalBotCompanionKit/Package.swift`

#### Keep a copy of the fixture because SwiftPM may bundle symlinks dangling; test checks equality
`Package.swift sample-library resource`: A copy of Companion/protocol/fixtures/sample-library.json: some
SwiftPM versions bundle a symlink as a dangling link. A test
fails when the two differ.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Data/CompanionSession.swift`

#### Session holds pairing mode, sync state and a screen-reload revision
`CompanionSession`: The app's link to its store: whether it is paired, sample or neither, the
sync state the status pill shows, and a revision every screen reloads on.

#### Unpaired means neither paired nor sample: show the welcome screen
`CompanionSession.Mode.unpaired`: Neither paired nor showing the sample library: the welcome screen.

#### Revision is bumped after anything that can change what screens show
`CompanionSession.revision`: Bumped after anything that can change what screens show.

#### Set when the last sync failed because no address answered
`CompanionSession.macUnreachable`: The last sync failed because no address answered.

#### One-off user messages, such as being removed by the Mac
`CompanionSession.notice`: One-off messages for the user, such as being removed by the Mac.

#### Recordings on this device or just sent, newest first
`CompanionSession.recordings`: Recordings on this device or just sent, newest first.

#### Per-recording upload progress as a fraction from 0 to 1
`CompanionSession.uploadProgress`: How far each recording being sent has got, from 0 to 1.

#### Track request ids being asked so a queued one is not asked twice
`CompanionSession.askingIDs`: Request ids being asked right now, so a queued one isn't asked twice at once.

#### One queued-question pass at a time so a second sync does not announce early
`CompanionSession.answeringQueued`: One pass over the queued questions at a time, so a second sync doesn't
announce an answer the first is about to.

#### Bonjour results as host:port preferring the paired Mac, set by the app
`CompanionSession.discoverAddresses`: Bonjour results as `host:port`, preferring the paired Mac. Set by the app.

#### Called when a queued question is answered after the Mac returns
`CompanionSession.onQueuedAnswer`: Called when a queued question is answered after the Mac comes back.

#### Requests system time to finish an upload; the result releases it
`CompanionSession.holdWhileUploading`: Asks the system for time to finish an upload; the result gives it back.

#### Sample library keeps its creation day as today so it reads the same
`CompanionSession.referenceDate`: "Today" for every screen. The sample library keeps the day it was made,
so it reads the same whenever it is opened.

#### Pins today for previews and screenshots
`CompanionSession.referenceDateOverride`: Pins "today" for previews and screenshots.

#### Reads pairing and sample state; call at launch
`CompanionSession.start`: Reads pairing and sample state; call at launch.

#### At launch nothing is recording, so recordings marked so were cut short
`CompanionSession.start`: Nothing can be recording yet, so anything marked so was cut short.

#### Switch to a reopened store, e.g. with a new device name before pairing
`CompanionSession.replaceStore`: Switches to a store opened again, for example with a new device name
before pairing.

#### Sync connects, sends queued changes, catches up, answers queued questions
`CompanionSession.syncNow`: Connects, sends queued changes, catches up and answers queued questions.

#### Answers take minutes, so changes made meanwhile are sent at once after sync
`CompanionSession.syncNow`: An answer can take minutes. The sync is over by now, so a change made
meanwhile is sent at once instead of waiting for it.

#### Queued questions from away or dropped connections; skip ones Ask is handling
`CompanionSession.answerQueuedQuestions`: Questions asked while the Mac was away, or whose connection dropped
while it answered. A question Ask is asking right now is left to it.

#### Failed uploads stay waiting for the next sync, so no extra message
`CompanionSession.uploadRecordings`: Sends what's waiting. Whatever doesn't get through stays waiting for
the next sync, so failing here needs no message beyond the row's own.

#### Progress reports can land after the sending pass has ended
`CompanionSession.uploadRecordings`: A report can land after the pass that sent it has ended.

#### Unreachable or dropped upload is resumed by the next sync
`CompanionSession.uploadRecordings`: Unreachable, or the connection dropped: the next sync resumes it.

#### After upload the Mac makes a meeting, so sync immediately to fetch it
`CompanionSession.uploadRecordings`: The Mac makes a meeting of it; fetch that as soon as it's published.

#### Reload the list after changes the store cannot announce
`CompanionSession.recordingsDidChange`: Reloads the list after a change the store can't announce.

#### Unpair is local only, so the device must also be removed on the Mac
`CompanionSession.removeThisDevice`: Erases the local copy, recordings that haven't arrived and the pairing.
This is local only (ffi.md `unpair`), so the device also needs removing
from the Mac's list.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Data/CompanionStore.swift`

#### Store mirrors the Rust SyncClient API; FixtureStore serves samples and tests; newest first
`CompanionStore`: The phone's copy of the Mac's shared library and its link to the Mac. It
mirrors the `SyncClient` API in Companion/protocol/ffi.md: the app uses the
Rust-backed store, and `FixtureStore` serves the sample library and tests.
Lists are newest first unless a method says otherwise.

#### Newest limit meetings plus whether older exist, for incremental scrolling
`CompanionStore.newestMeetings`: The newest `limit` meetings and whether older ones exist, for a list
that loads as it's scrolled.

#### Actions come back in ActionOrdering.sorted order
`CompanionStore.actions`: In `ActionOrdering.sorted` order.

#### Status applies at once, marked pending until the Mac confirms
`CompanionStore.setActionStatus`: Applies the status at once, marked pending until the Mac confirms it.

#### Starting a recording returns where the recorder writes
`CompanionStore.beginRecording`: Starts a recording; the result says where the recorder writes.

#### An empty recording file leaves no recording and throws
`CompanionStore.finishRecording`: The recorder stopped. An empty file leaves no recording and throws.

#### Keep what a mid-recording app stop wrote; never call while recording
`CompanionStore.recoverRecordings`: Keeps what an app that stopped mid-recording wrote. Never while recording.

#### Upload resumes earlier attempts, blocks until done, leaves failures waiting
`CompanionStore.uploadRecordings`: Sends what's waiting, resuming earlier attempts, and blocks until done.
What doesn't get through stays waiting.

#### Unpair erases the local copy and the pairing
`CompanionStore.unpair`: Erases the local copy and the pairing.

#### Replaces the local copy with the bundled sample library
`CompanionStore.loadSampleLibrary`: Replaces the local copy with the bundled sample library.

#### No address answered; the phone offers to search its own copy
`CompanionStoreError.unreachable`: No address answered. The phone offers to search its own copy instead.

#### Dropped connection: Mac keeps answering, asking again returns text so far
`CompanionStoreError.interrupted`: The connection dropped after the Mac had the question. The Mac keeps
answering and the question is queued; asking it again picks up the
answer, whose first delta is the text so far.

#### Mac removed this device and its copy has been erased
`CompanionStoreError.revoked`: The Mac removed this device; its copy has been erased.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Data/FixtureStore.swift`

#### In-memory store follows the Rust store's upsert, tombstone and merge rules
`FixtureStore`: An in-memory store over record envelopes. It serves the bundled sample
library ("Try it without a computer"), previews and tests, and follows the same
rules as the Rust store: upsert by (kind, key) keeping the higher version,
tombstones remove, merged meetings are hidden.

#### Today for overdue actions and the Ask demo
`FixtureStore.Configuration.now`: "Today" for overdue actions and the Ask demo.

#### Status changes stay waiting for the computer instead of applying
`FixtureStore.Configuration.keepsChangesPending`: Status changes stay "waiting for your computer" instead of applying at once.

#### Presents a paired Mac for previews; otherwise reports sample library
`FixtureStore.Configuration.pairedStatus`: Present a paired Mac (previews and screenshots); otherwise the
store reports itself as the sample library.

#### Whether Ask reaches the pretend Mac
`FixtureStore.Configuration.macReachable`: Whether Ask reaches the (pretend) Mac.

#### First N answers drop after first word like a lock screen, queueing the question
`FixtureStore.Configuration.droppedAnswers`: The first this many answers drop after their first word, as on a
lock screen: the question is queued and asking again picks it up.

#### Sample library comes from Companion/protocol/fixtures/sample-library.json
`FixtureStore.sampleLibrary`: The bundled sample library: Companion/protocol/fixtures/sample-library.json.

#### Adds envelopes as a sync batch would
`FixtureStore.importRecords`: Adds envelopes as a sync batch would.

#### A meeting's own actions carry pending state as the Rust store's do
`FixtureStore.markingPending`: A meeting's own actions say which ones wait for the computer, as the
Rust store's do.

#### People and projects rebuild on the Mac; reflect local status changes meanwhile
`FixtureStore.currentOpenWork`: People and projects are rebuilt on the Mac; until then, reflect status
changes made here.

#### Sample answers cite the library's decisions and actions without a Mac
`FixtureStore.sampleAnswer`: A short answer built from the library's own decisions and actions, so
the sample shows cited answers without a Mac.

#### Sets the recording list directly for previews and screenshots
`FixtureStore.setRecordings`: Sets the list directly, for previews and screenshots.

#### Mirrors the core when the Mac removes the device: recordings stay
`FixtureStore.forgetPairingKeepingRecordings`: What the core does when the Mac removes this device.

#### Sample's today is its manifest generatedAt so it reads the same
`SampleLibrary.referenceDate`: When the sample library was made (its manifest's `generatedAt`): the
sample's "today", so it reads the same whenever it is opened.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/ActionItemToggleStyle.swift`

#### Round Reminders-like toggle everywhere; done is a teal check
`ActionItemToggleStyle`: The round, Reminders-like toggle used for action items everywhere they
appear. Done is a filled teal check; open is an empty circle.

#### 44 pt tap target; amber ring marks a change waiting for the Mac
`ActionCheck`: The circle itself, with a 44 pt target. A change waiting for the Mac
shows an amber ring.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/Components.swift`

#### Title sits above the grouped surface, as on the Mac
`WorkspaceSection`: A titled group on a grouped surface: Recap, Action Items, Decisions,
Open Work. The title sits above the surface, as on the Mac.

#### Caption header for list groupings such as day labels and action groups
`SectionHeader`: The caption header for list groupings: day labels in Meetings, groups in
Actions.

#### Pulse ring is off under Reduce Motion; color alone carries state
`StatusDot`: A small state-colored dot; `pulses` adds an expanding ring, off under
Reduce Motion (the color alone still carries the state).

#### Teal timestamp that jumps to the transcript line when tapped
`EvidencePill`: The quoted moment behind an outcome, as a teal timestamp. Tapping it
jumps to that line of the transcript.

#### Tint is chosen from the name using the Mac's speaker palette
`InitialsAvatar`: A person's initials on a tint chosen from their name, from the speaker
palette as on the Mac.

#### Must match the Mac's InitialsAvatar.color(for:)
`InitialsAvatar.colorIndex`: The Mac's `InitialsAvatar.color(for:)`.

#### Must match the Mac's PeopleDirectory.normalized
`InitialsAvatar.normalized`: The Mac's `PeopleDirectory.normalized`.

#### Value uses monospaced digits
`StatTile`: Icon, value and label in a chip; the value keeps monospaced digits.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/LBColor.swift`

#### Mirrors the Mac palette; prefer system colors, these fill gaps
`LBTokens.Palette`: The Mac's `LBTokens.Palette`, from the generated tokens. Prefer system
semantic colors (`.primary`, `.secondary`) and backgrounds; these cover
only what the system doesn't provide.

#### Filled buttons, knob, badges; white text meets 4.5:1
`LBTokens.Palette.accentFill`: Filled buttons, selection knob, citation badges. White text on it meets 4.5:1.

#### Accent text role: links, timestamps, icons, done checks, evidence pills
`LBTokens.Palette.accentText`: Links, timestamps, icons, done checks, evidence pills.

#### Wash used for selected rows and the cited transcript line
`LBTokens.Palette.accentWash`: Selected rows, the cited transcript line.

#### Attention dots and fills for remote engine and pending changes
`LBTokens.Palette.attention`: Dots and fills for attention: remote engine, pending changes.

#### Attention text for owner unclear, blockers, waiting for computer
`LBTokens.Palette.attentionText`: "Owner unclear", blockers, "Waiting for your computer".

#### Recording color is for destructive fills
`LBTokens.Palette.recording`: Destructive fills.

#### Recording text color for overdue dates and destructive text
`LBTokens.Palette.recordingText`: Overdue dates, destructive text.

#### Metadata color stays above 4.5:1 on grouped fills unlike secondary
`LBTokens.Palette.supporting`: Metadata lines; stays above 4.5:1 on grouped fills, unlike `.secondary`.

#### Status surfaces use tint at 10% with a 28% stroke
`LBTokens.Palette.statusFillOpacity`: Status surfaces: the tint at 10% with a 28% stroke.

#### Index 0 is the user; always show the name beside the color
`LBTokens.Palette.speakers`: Speakers; index 0 is the person themselves. Always show the name
next to the color.

#### Index -1 (grouped or unknown voices) uses the supporting color
`LBTokens.Palette.speaker`: A transcript `colorIndex`: -1 (grouped or unknown voices) uses the
supporting color.

#### Brand roles keep their Mac names
`Brand`: Brand roles by their Mac names.

#### Deep teal on light surfaces, mint on dark
`Brand.teal`: Deep teal on light surfaces, mint on dark ones.

#### Fill behind white foregrounds, deep in both appearances
`Brand.tealFill`: Behind white foregrounds; deep in both appearances.

#### Amber for attention, remote inference, saved moments
`Brand.amber`: Attention, remote inference, saved moments.

#### Failure and warning text and icons
`Brand.error`: Failure and warning text and icons.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/LBTypography.swift`

#### Mac type roles mapped to Dynamic Type styles per tokens.json
`LBTokens.Typography`: The Mac's type roles mapped to Dynamic Type styles, as tokens.json
"type" says. The Mac's sizes are desktop sizes; the roles carry over.

#### Maps to Mac largeTitle bold
`LBTokens.Typography.pageTitle`: Mac largeTitle bold.

#### Ask question font maps to Mac title2 semibold
`LBTokens.Typography.question`: The question in Ask. Mac title2 semibold.

#### Column and detail titles map to Mac title3 bold
`LBTokens.Typography.columnTitle`: Column and detail titles. Mac title3 bold.

#### Section headers map to Mac headline
`LBTokens.Typography.section`: Section headers. Mac headline.

#### Reading font for transcript lines, digests and answers with line spacing
`LBTokens.Typography.reading`: Transcript lines, digests and answers, with `readingLineSpacing`.

#### Metadata font maps to Mac callout
`LBTokens.Typography.secondary`: Metadata. Mac callout.

#### Caption maps to Mac subheadline
`LBTokens.Typography.caption`: Mac subheadline.

#### Long-form text uses reading font with the Mac's line spacing
`View.readingText`: Long-form text: the reading font with the Mac's line spacing.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/NameColor.swift`

#### Name colors match Mac CaptureStyle: djb2 hue, saturation 0.55, brightness 0.78
`NameColor`: Stable colors for apps and projects on the Timeline, identical to the Mac's
`CaptureStyle.color(for:)`: hue = djb2(name) % 360, saturation 0.55,
brightness 0.78.

#### djb2 over UTF-8 bytes, wrapping in 64 bits like the Mac
`NameColor.djb2`: djb2 over the UTF-8 bytes, wrapping in 64 bits like the Mac.

#### Other (no app or project) uses supporting color at 55%
`NameColor.color`: "Other" (time without an app or project) is the supporting color at 55%.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/Surfaces.swift`

#### Grouped section surface is a 10 pt rounded well with a hairline
`View.lbGroupedSurface`: The grouped section surface behind Recap, Action Items, Decisions and
details: a 10 pt rounded well with a hairline.

#### Tinted status surface keeps a boundary under Increase Contrast
`View.lbStatusSurface`: A tinted status surface; keeps a visible boundary with Increase Contrast.

#### Liquid Glass on iOS 26, material before, opaque under Reduce Transparency
`View.lbFloatingComposer`: Liquid Glass on iOS 26, a material before it, and an opaque fill with
Reduce Transparency, like the Mac's composer.

#### Docked Ask composer shows a teal ring while focused
`View.composerChrome`: The docked composer used by Ask, with a teal ring while focused.

#### Trust and warning text must stay readable in every appearance and contrast
`WorkspaceTextRole`: Text importance independent of layout: metadata may be quiet, but trust and
warning text stays readable in every appearance and with Increase Contrast.

#### Supporting color keeping caller's font; primary with Increase Contrast
`View.workspaceSupportingForeground`: The supporting color, keeping the caller's font; primary with Increase Contrast.

#### One filled call to action per surface, white on deep accent
`View.primaryActionButton`: The one filled call to action on a surface: white on the deep accent.

#### Pointer hover only on iPad
`View.lbHoverEffect`: Pointer hover on iPad; nothing elsewhere.

#### Accent-text link style replaces the system .link style
`WorkspaceLinkButtonStyle`: Inline navigation and utility actions as accent text, replacing `.link`.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/SyncStatusPill.swift`

#### Teal while fresh, amber when the Mac was unreachable
`SyncStatusPill`: "Synced with your computer · 2 min ago · Wi-Fi". Teal while fresh, amber when
the Mac couldn't be reached.

#### Pins now for sample library, previews and screenshots
`SyncStatusPill.pinnedNow`: Pins "now" for the sample library, previews and screenshots.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/ToolbarTabs.swift`

#### Equal-width tabs with sliding teal capsule like the Mac's meeting tabs
`ToolbarTabs`: Equal-width tabs with a sliding teal capsule, the Mac's meeting tabs.

#### Capsule tabs where they fit, a menu at large text sizes
`ToolbarTabs.body`: The capsule tabs where they fit; a menu at large text sizes.

#### Hidden semibold copy reserves selected width so size never changes
`ToolbarTabs`: The hidden semibold copy reserves the selected width, so the
control never changes size as the selection moves.

#### White on deep accent gives 4.7:1 contrast
`ToolbarTabs.knob`: White on the deep accent (4.7:1).

#### Widest child's width, or equal share of offered width if smaller
`EqualWidthHStack`: Places children side by side at the widest child's width, or shares the
offered width equally when that is smaller.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Design/WorkspaceMotion.swift`

#### Milestone motion is for rare moments like pairing and first sync
`WorkspaceMotionKind.milestone`: Rare moments: paired with a Mac, the first sync done.

#### Mac motion policy with tokens.json durations; all off under Reduce Motion
`WorkspaceMotion`: The Mac's motion policy, with durations from tokens.json. Everything is off
under Reduce Motion.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/ActionOrdering.swift`

#### Order per ffi.md: overdue, then due date (none last), then newest meeting
`ActionOrdering`: The order ffi.md gives `actions()`: overdue first, then by due date (none
last), then the newest meeting first.

#### Groups apply to a list already in sorted order
`ActionOrdering.Group`: Groups for a list already in `sorted` order.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/AskCitationParser.swift`

#### [n] markers map to AskResult citations and render as teal badges
`AskCitationParser`: `[n]` markers in an Ask answer refer to `AskResult.citations[].index`.
They become links the answer view styles as teal source badges, the way the
Mac's editorial transcript does.

#### Marker regex matches [3] or [1, 2] but not Markdown link labels
`AskCitationParser.marker`: `[3]` or `[1, 2]`, not the label of a Markdown link `[text](url)`.

#### Matches an unfinished marker at the end of streamed text
`AskCitationParser.partialTail`: An unfinished marker at the end of streamed text: `[`, `[1`, `[1, `.

#### Citation numbers in first-appearance order
`AskCitationParser.markers`: Citation numbers in the order they first appear.

#### Known markers become links, unknown stay text, partial tail held while streaming
`AskCitationParser.linkedMarkdown`: The answer as Markdown in which each known `[n]` links to
`lokalbot-citation://source/n`. Unknown numbers stay plain text. While
streaming, a marker cut off at the end is held back until it completes.

#### Marker-free answer text for copying and VoiceOver
`AskCitationParser.plainText`: The answer without markers, for copying and for VoiceOver.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/DayKey.swift`

#### Day is YYYY-MM-DD in the Mac's local zone; string order is date order
`DayKey`: A calendar day as records carry it: `YYYY-MM-DD` in the Mac's local time
zone. Comparing keys as strings orders them by date.

#### Use noon to avoid crossing a day boundary when formatting
`DayKey.date`: Noon on this day in `calendar`'s time zone: safe for formatting the
weekday and date without crossing a day boundary.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/LBFormat.swift`

#### Formats take locale and calendar so tests can pin them
`LBFormat`: Text formats shared by every screen. Each takes its locale and calendar so
tests can pin them.

#### Transcript offset formatted as the Mac shows it, 00:12:01
`LBFormat.stamp`: A transcript offset as the Mac shows it: `00:12:01`.

#### Meeting length formatted like the Mac list: 42 min, 1 hr 5 min
`LBFormat.meetingDuration`: A meeting's length as the Mac's meeting list shows it: "42 min", "1 hr 5 min".

#### Tracked time formatted like Mac Timeline: \<1m, 42m, 1h 5m
`LBFormat.hm`: Tracked time as the Mac's Timeline shows it: "\<1m", "42m", "1h 5m".

#### Time of day in a given zone, the Mac's offset for a meeting
`LBFormat.time`: A time of day, in `timeZone` (the Mac's offset for a meeting).

#### Local time of a meeting moment as it was on the Mac
`LBFormat.time(in:at:)`: The local time of a moment in a meeting, as it was on the Mac.

#### Today, Yesterday, weekday within a week, otherwise a date
`LBFormat.dayTitle`: "Today", "Yesterday", the weekday within the last week, otherwise a date.

#### Long day format used for page subtitles
`LBFormat.longDay`: "Friday, 31 October" for page subtitles.

#### Abbreviated weekday format used for the day strip
`LBFormat.weekday`: "Thu 30" for the day strip.

#### Due text formats; only open actions can be overdue
`LBFormat.due`: "Overdue · Thu", "Due today", "Due Mon", "Due Wed, 12 Nov". Only open
actions can be overdue.

#### Relative time tiers: just now, min, hr, yesterday, date
`LBFormat.ago`: "just now", "2 min ago", "3 hr ago", "yesterday", "28 Oct".

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/MarkdownDocument.swift`

#### Block-level parse of Mac Markdown; inline styling left to AttributedString
`MarkdownDocument`: The block structure of the Markdown the Mac sends (summaries, notes,
digests, answers): headings, paragraphs, lists and quotes. Inline styling
is left to `AttributedString(markdown:)`.

#### Section runs to next heading of same or higher level
`MarkdownDocument.section`: The blocks under the first heading named one of `titles`, up to the
next heading of the same or a higher level.

#### Recap shown from summary; structured sections come from meeting fields
`SummaryPresentation`: What the Summary tab shows as Recap: the summary's Recap section. Action
items, decisions and open questions come from the meeting's structured
fields, so those sections are left out of a summary without one.

#### Inline Markdown styled, falling back to plain text on parse failure
`MarkdownInline.attributed`: Inline Markdown (bold, italics, code, links) as styled text; plain text
when it doesn't parse.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/NetworkRoute.swift`

#### Route inferred from last sync address: Tailscale ranges and MagicDNS, else local
`NetworkRoute`: How the phone reached the Mac, from the address the last sync used:
Tailscale's ranges and MagicDNS names, otherwise the local network.

#### Address may be host, host:port or [v6]:port
`NetworkRoute.init(address:)`: `address` is `host`, `host:port` or `[v6]:port`.

#### Tailscale IPv4 range is 100.64.0.0/10
`NetworkRoute.isTailscale`: 100.64.0.0/10

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/QueuedAnswerBanner.swift`

#### With App Lock on, the banner names the question but hides the answer
`QueuedAnswerBanner`: What the notification says when the computer answers a question that was
queued while it was away. A banner shows on the lock screen and over other
apps, where App Lock doesn't reach, so with the lock on it names the
question and leaves the answer for inside the app, as the Android app does.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Formatting/SearchSnippet.swift`

#### Core marks matches with guillemets; otherwise match searched terms
`SearchSnippet`: A search snippet split into plain text and matched words. The sync core's
full-text search marks matches with `«` and `»`; without markers the
searched terms themselves are matched.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Models/Ask.swift`

#### Question for the Mac as defined in records.md Ask
`AskRequest`: A question for the Mac (records.md, Ask).

#### Teal for Mac engine, amber for approved remote engine
`AnswerLocation`: Where an answer was produced: teal for the Mac's own engine, amber for an
approved remote engine.

#### Unknown location is treated as remote so never shown as private
`AnswerLocation.init(from:)`: An unknown location is treated as remote, so it is never presented as
private when it may not be.

#### [n] refers to index; without meetingId the citation is text only
`AskCitation`: `[n]` in an answer refers to `index`. Without a `meetingId` (a screen
moment) the citation is text only.

#### Seconds from the start of the meeting
`AskCitation.at`: Seconds from the start of the meeting.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Models/CompanionJSON.swift`

#### camelCase keys, ISO 8601 instants with milliseconds, unknown keys ignored
`CompanionJSON`: JSON coding for companion records: camelCase keys, ISO 8601 instants with
milliseconds (`2026-10-30T09:30:00.000Z`), unknown keys ignored.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Models/PairingPayload.swift`

#### Pairing link parsed only for display; sync core rechecks before connecting
`PairingPayload`: The Mac's pairing code: `lokalbot://pair?d=<base64url(JSON)>` (protocol.md,
Pairing). Parsed here only to show what the phone is about to pair with;
the sync core checks it again before it connects.

#### Pairing link prefix matches the sync core's check
`PairingPayload.linkPrefix`: What every pairing link starts with, as the sync core checks it.

#### 120 s expiry grace matches core so fast phone clocks do not refuse
`PairingPayload.expiryGrace`: A code this long past its expiry on this device's clock still goes to
the sync core, which allows the same (`EXPIRY_GRACE_SECS`): the
computer's clock decides, so a phone that runs fast doesn't refuse a
code the computer would take.

#### Extracts the lone link with lowercase scheme, the form the core takes
`PairingPayload.link`: The pairing link inside `text`, alone and with its scheme in lowercase:
the form the sync core takes. Nil when the text holds no link.

#### Accepts the link or text containing it, as pasted
`PairingPayload.parse`: Accepts the link itself or text that contains it, as pasted from a
message or a note.

#### Fingerprint is first 16 hex chars of SHA-256 of the static key
`KeyFingerprint`: The short key hash the Mac advertises in its Bonjour TXT record (`k=`):
the first 16 hex characters of SHA-256 of its static public key.

#### Accepts base64 or base64url keys from pairing code or PairedMac
`KeyFingerprint.fingerprint(base64Key:)`: For a key as the pairing code or `PairedMac` carries it, in base64 or base64url.

#### Decodes base64url or standard base64, padded or not
`Base64URL.decode`: Decodes base64url or standard base64, with or without padding.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Models/Records.swift`

#### Record bodies follow records.md schema 1; optional fields omitted, never null
Record bodies from Companion/protocol/records.md, schema version 1.
Optional fields are omitted on the wire, never null.

#### A tombstone has an empty body
`RecordEnvelope`: One record as it travels and is stored. A tombstone (`deleted`) has an
empty body.

#### Kinds from newer schemas are ignored by clients
`RecordBody.unknown`: A kind from a newer schema; clients ignore it.

#### 0 means all history; otherwise 30, 90 or 365
`Manifest.historyDays`: 0 is all history; otherwise 30, 90 or 365.

#### Whether Mac accepts device recordings; absent on older Macs
`Manifest.recordingsEnabled`: Whether the Mac takes recordings from this device now. Absent from a
Mac that predates them.

#### Local day of startedAt on the Mac
`Meeting.day`: Local day of `startedAt` on the Mac, `YYYY-MM-DD`.

#### Mac's offset at startedAt so times show as they were
`Meeting.timeZoneOffsetMinutes`: The Mac's offset at `startedAt`, for showing times as they were.

#### Unknown newer status reads as open so the action stays visible
`ActionStatus.init(from:)`: A status from a newer schema reads as open, so the action stays visible.

#### Due date resolved on the Mac as YYYY-MM-DD
`ActionItem.dueDate`: Resolved on the Mac, `YYYY-MM-DD`.

#### Due phrase as spoken, e.g. by Thursday
`ActionItem.dueText`: The phrase as spoken ("by Thursday").

#### Importance ranges 1 to 5
`ActionItem.importance`: 1–5.

#### Added locally: status changed here, computer has not confirmed
`ActionItem.pending`: Added by this device's store, in a meeting's actions: the status was
changed here and the computer hasn't confirmed it.

#### Added locally: records that the computer did not make the last change
`ActionItem.syncNote`: Added by this device's store, in a meeting's actions: the computer
didn't make the last change.

#### Computer never sends pending, so absent means false
`ActionItem.init(from:)`: The computer never sends `pending`, so its absence means false.

#### Computer's answer when it did not apply a status change from this device
`ActionSyncNote`: The computer's answer when it didn't make a status change sent from this
device (ffi.md, `syncNote`).

#### Offset range in seconds from meeting audio start, with quoted words
`Citation`: An offset range in seconds from the start of the meeting's audio, and the
quoted words.

#### Segment containing offset, else last starting before it
`Transcript.segmentIndex`: The segment holding `offset`, or the last one that starts before it.

#### 0 is the user, 1-7 speaker palette, -1 grouped or unknown
`TranscriptSegment.colorIndex`: 0 is the person themselves; 1–7 the speaker palette; -1 grouped or unknown.

#### YYYY-MM-DD in the Mac's local time zone
`DayRecord.date`: `YYYY-MM-DD` in the Mac's local time zone.

#### Sorted by seconds descending; no project counts as Other
`DayTimeline.byProject`: Sorted by seconds, descending; no project counts under "Other".

#### Present only while window titles are shared
`WorkSession.windowTitles`: Present only while window titles are shared.

#### Falls back to busiest apps when the Mac sent no title
`WorkSession.displayTitle`: The session's title, or its busiest apps when the Mac sent none.

#### True when the person owns it, false when the LokalBot user does
`OpenWork.theirs`: True when the person owns it, false when the LokalBot user does.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Models/StoreTypes.swift`

#### Action with its meeting as listed by store per ffi.md
`ActionRow`: An action with its meeting, as the store lists it (ffi.md, ActionRow).

#### Status change made here that the Mac has not confirmed
`ActionRow.pending`: A status change made here that the Mac hasn't confirmed yet.

#### Computer did not make the last status change sent from here
`ActionRow.syncNote`: The computer didn't make the last status change sent from here.

#### A meeting's own actions carry the same pending and note fields
`ActionRow.init(meeting:action:)`: The row for one of a meeting's own actions, which carry what a row does.

#### hasMore counts rows not decoded meetings so unreadable ones do not end list
`MeetingsPage.init(rows:limit:)`: From the rows a store returned when asked for `limit + 1`. A meeting
this build can't read is left out, and must not look like the end of
the list: whether more exist is counted in rows, not in what decoded.

#### Mirrors ffi.md ActionFilter
`ActionFilter`: Mirrors ffi.md `ActionFilter`.

#### YYYY-MM-DD, exclusive
`ActionFilter.dueBefore`: `YYYY-MM-DD`, exclusive.

#### Mirrors ffi.md SearchHit
`SearchHit`: Mirrors ffi.md `SearchHit`.

#### Segment start for transcript hits
`SearchHit.at`: Segment start, for transcript hits.

#### YYYY-MM-DD for day hits
`SearchHit.date`: `YYYY-MM-DD`, for day hits.

#### Mirrors ffi.md SyncStatus
`SyncStatus`: Mirrors ffi.md `SyncStatus`.

#### Mirrors ffi.md SyncReport
`SyncReport`: Mirrors ffi.md `SyncReport`.

#### Mirrors ffi.md RecordingInfo: recording held or just sent
`RecordingItem`: Mirrors ffi.md `RecordingInfo`: a recording this device holds or just sent.

#### A recorder is writing it, or was when the app last stopped
`RecordingItem.State.recording`: A recorder is writing it, or was when the app last stopped.

#### Waiting to upload as soon as the Mac is reachable
`RecordingItem.State.waiting`: On its way to the Mac as soon as it can be reached.

#### Mac refused it; stays until retried or discarded
`RecordingItem.State.failed`: The Mac refused it; it stays until retried or discarded.

#### Mac has it; audio left this device
`RecordingItem.State.uploaded`: The Mac has it; the audio left this device.

#### UUID shared with the Mac's meeting id
`RecordingItem.id`: A UUID; the Mac's meeting has the same id.

#### Empty until the person names it
`RecordingItem.title`: Empty until the person names it.

#### Why it has not reached the Mac, or what failed
`RecordingItem.message`: Why it hasn't reached the Mac, or what went wrong.

#### Where the recorder writes
`RecordingItem.filePath`: Where the recorder writes.

#### Not yet uploaded means deleting loses the only copy
`RecordingItem.isOnlyCopy`: Still only on this device, so deleting it loses it.

#### Mirrors ffi.md UploadReport
`UploadReport`: Mirrors ffi.md `UploadReport`.

#### Mirrors ffi.md PairedMac
`PairedMac`: Mirrors ffi.md `PairedMac`.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Platform/DeviceIdentity.swift`

#### Keychain key available after first unlock, this device only, never synced
`DeviceIdentity`: This device's long-term X25519 private key and its device id, kept in the
Keychain for this device only: available after first unlock (so background
refresh can sync) and never synchronized to other devices.

#### Generate via core and save before returning a new key
`DeviceIdentity.privateKey`: The stored private key, or a new one from `generate` (the sync core's
`generateStaticKey()`), saved before it is returned.

#### Copy in Application Support, protected until first unlock, excluded from backups
`CompanionStorage`: Where the phone keeps its copy: Application Support, protected until the
first unlock after a restart, and left out of device backups because the
Mac can always send it again.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Platform/MacDiscovery.swift`

#### Bonjour browse resolves IPv4 host:port; TXT k picks paired Mac, key proves it
`MacDiscovery`: Finds LokalBot Macs on the current network: Bonjour `_lokalbot._tcp`,
each instance resolved to an IPv4 `host:port` for the sync core. The TXT
record's `k` (a short hash of the Mac's key) picks out the paired Mac;
the key itself proves it during the handshake.

#### TXT k record value
`MacDiscovery.Instance.fingerprint`: TXT `k`.

#### Local Network off; Tailscale and stored addresses still work
`MacDiscovery.Outcome.localNetworkDenied`: Local Network access is off for the app; Tailscale and stored
addresses still work.

#### Paired Mac's addresses first then unlabeled instances; other Macs excluded
`MacDiscovery.addresses`: Addresses of the paired Mac first, then any instance without a `k`.
Other Macs are left out.

#### One browse with all callbacks on the queue
`BrowseRun`: One browse; every callback runs on `queue`.

#### DNS error -65570 PolicyDenied means Local Network permission is off
`BrowseRun.start`: kDNSServiceErr_PolicyDenied: the Local Network permission is off.

#### Handlers retain the run, so clear them when finishing
`BrowseRun.finish`: The handlers keep this run alive while it browses; drop them now.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/ViewModels/AskModel.swift`

#### Unreachable Mac offers phone-local search and the question queue
`AskModel.Turn.State.macUnreachable`: The Mac didn't answer; the phone offers its own search and the queue.

#### Dropped connection leaves Mac answering; turn picks answer up on return
`AskModel.Turn.State.waiting`: The connection dropped while the Mac answered. It keeps
answering, and the turn picks the answer up on return.

#### Interrupted turn marks that the question was queued after a drop
`AskModel.Turn.interrupted`: The connection dropped once while the Mac answered, so the
question is queued.

#### When resuming, first delta carries the whole text so far
`AskModel.Turn.restartText`: Picking up an answer: the next delta is the whole text so far.

#### Scope answers from a day or meeting but shows no chip
`AskModel.scope`: The day or meeting "Ask About…" started from. The computer answers
from there but still reads everything shared, so it shows no chip.

#### Sample mode suggests questions grounded in bundled library; paired stays general
`AskModel.suggestions`: The sample answerer reads meeting decisions and actions, so offer
questions grounded in its bundled library. Paired suggestions stay general.

#### Reload keeps memory-only turns: answering, unreachable, failed
`AskModel.load`: Ask history and queued questions from the store, keeping turns that
exist only in memory (answering, unreachable, failed).

#### Interrupted turn keeps its partial answer and state across reload
`AskModel.load`: An interrupted turn keeps its partial answer and its state.

#### Resume a dropped answer when the phone is unlocked again
`AskModel.resumeWaiting`: Picks up an answer whose connection dropped, e.g. when the phone is
unlocked again.

#### Mac resends the text so far as the first delta
`AskModel.resumeWaiting`: The Mac sends the text so far as the first delta.

#### Sample answers on-device so skip network discovery
`AskModel.send`: The sample is answered on this device and needs no network discovery.

#### Interrupted question already queued stays waiting when out of reach
`AskModel.send`: An interrupted question is queued already: out of reach, it keeps waiting.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/ViewModels/LibraryModels.swift`

#### Attention list shows open actions with overdue first
`TodayModel.attention`: The person's open actions, overdue first.

#### Show latest earlier digest until today's digest is written
`TodayModel.digestRecord`: Today's digest, or the latest earlier one until today's is written.

#### Requested meeting count grows as list scrolls to its end
`MeetingsModel.listed`: How many meetings the list has asked for so far; it grows as the list
is scrolled to its end.

#### Search covers titles, summaries, notes, actions, decisions, transcripts, digests
`MeetingsModel.search`: Searches the device's copy: titles, summaries, notes, actions,
decisions, transcripts and digests.

#### Show quoted excerpt when transcript is not on this device
`MeetingDetailModel.focusedExcerpt`: The excerpt to show when the transcript isn't on this device.

#### Fall back to quoted words when transcript is not shared
`MeetingDetailModel.focus`: Opens the transcript at `offset`, or shows the quoted words when the
transcript isn't shared.

#### Recorded days are ordered newest first
`TimelineModel.recordedDays`: Days that have a record, newest first.

#### Session times use Mac's zone when a meeting reveals it
`TimelineModel.timeZone`: Session times show in the Mac's zone that day when a meeting tells us
what it was; otherwise in this device's zone.

### `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/ViewModels/RecordingModel.swift`

#### Recorder writes ADTS AAC straight to url so partial files stay readable
`AudioCapture`: What the recording screen needs from the device's microphone. The app's
implementation wraps `AVAudioRecorder`, writing ADTS AAC straight to `url`,
so whatever has been written stays readable if the app dies.

#### Elapsed seconds exclude interruptions
`AudioCapture.currentTime`: Seconds recorded so far, not counting interruptions.

#### Input level ranges from 0 to 1
`AudioCapture.level`: Input level from 0 to 1.

#### stop returns seconds recorded and leaves a complete file
`AudioCapture.stop`: Returns the seconds recorded. The file is complete afterwards.

#### A call or another app taking the mic pauses recording
`AudioCaptureEvent.interrupted`: A phone call or another app took the microphone; recording is paused.

#### After recorder failure, what was already written stays usable
`AudioCaptureEvent.failed`: The recorder can't go on. What it wrote is still good.

#### Recording model lives as long as the app, outliving screens
`RecordingModel`: One recording from the button to the queue: asks for the microphone, runs
the recorder, and hands the finished file to the store to send. It lives as
long as the app, so recording carries on whatever the screens do.

#### Interrupted by call or app; resume() carries on
`RecordingModel.Phase.interrupted`: Paused by a call or another app; `resume()` carries on.

#### Refused permission means only Settings can fix it
`RecordingModel.microphoneDenied`: The microphone permission was refused, so Settings is the only way on.

#### App announces interruption if unseen, since recording may not auto-resume
`RecordingModel.onInterrupted`: A call or another app took the microphone. The app says so if nobody
is looking, because recording may not carry on by itself.

#### Recording stays if Mac removed device; removal from phone already erased it
`RecordingModel.sessionModeChanged`: There's no Mac to send to any more. What was recorded stays if the Mac
removed this device, ready for when it pairs again, and removing the
device from here has already erased it, which makes this a no-op.

#### Keep screen presented after failure so the message is seen
`RecordingModel.stopAfterFailure`: Stays on the screen so the message is seen.

### `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/ActionTests.swift`

#### Test dates come from fixture; today is manifest generatedAt
`ActionTests`: Dates come from the fixture: "today" is its manifest's generatedAt.

#### People and projects reflect a change before the Mac rebuilds them
`ActionTests.statusChangesStayPendingUntilSynced`: People and projects reflect the change before the Mac rebuilds them.

### `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/AskTests.swift`

#### Cut-off question waits in queue and reload keeps the turn
`AskTests.picksUpAnAnswerCutOffByTheLockScreen`: The question waits in the queue, and a reload keeps the turn as it was.

### `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/DesignTests.swift`

#### Hash copied verbatim from Mac CaptureStyle.color(for:)
`DesignTests.macHue`: The Mac's `CaptureStyle.color(for:)` hash, copied verbatim
(LokalBot/Views/ScreenMemory/CaptureView.swift).

#### Long names wrap in 64 bits as on the Mac
`DesignTests.djb2KnownValues`: Long names wrap in 64 bits, as on the Mac.

#### Mirrors Mac InitialsAvatar index and PeopleDirectory.normalized
`DesignTests.avatarColorMatchesTheMac`: The Mac's `InitialsAvatar.color(for:)` index, with
`PeopleDirectory.normalized` (LokalBot/Views/People/PeopleWorkspaceView.swift).

### `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/FormattingTests.swift`

#### ICU puts a narrow no-break space before AM/PM
`FormattingTests.plain`: ICU puts a narrow no-break space before AM/PM.

#### Meeting times use Mac offset regardless of device zone
`FormattingTests.meetingTimesUseTheMacsOffset`: 09:30Z at +60 min is 10:30 on the Mac, whatever this device's zone.

### `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/LibraryModelTests.swift`

#### Fixture has more meetings than list loads at once; index 0 oldest
`LibraryModelTests.longHistory`: A library with more meetings than the Meetings list loads at once;
index 0 is the oldest.

#### Reload keeps reached list depth with nothing more to ask
`LibraryModelTests.theMeetingsListGoesOnPastWhatItLoadsFirst`: A reload after a sync keeps what the list had reached, and there is nothing more to ask for.

#### Unreadable-schema row in a page must not end the list
`LibraryModelTests.aMeetingThisBuildCantReadDoesNotEndTheList`: Three rows for a page of two, the middle one from a schema this build doesn't know.

#### Action row carries its own flag; sync note message is optional
`LibraryModelTests.whatTheStoreAddsToAnActionDecodes`: A row carries both itself; a note needn't have a message.

#### Rows carry the pending flag themselves as the sync core's rows do
`LibraryModelTests.aMeetingsOwnActionsSayWhichWaitForTheComputer`: A row carries the flag itself, as the sync core's rows do.

#### Sync ends while the Mac writes its answer so the next can start
`LibraryModelTests.aChangeMadeWhileAQueuedQuestionIsAnsweredDoesNotWaitForTheAnswer`: The sync is over while the computer writes its answer, so the next one can start.

### `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/PairingAndMarkdownTests.swift`

#### Sync core needs the bare lokalbot://pair? link
`PairingPayloadTests.theLinkIsLiftedOutOfPastedText`: The sync core takes the link alone, starting `lokalbot://pair?` exactly,
so that is what goes to it, whatever was pasted around the link.

#### Allow 120 s past expiry, matching the sync core
`PairingPayloadTests.aCodeJustPastItsExpiryStillGoesToTheComputer`: The sync core allows 120 s past the expiry on this device's clock and
leaves the rest to the computer, so the check before it allows the same.

### `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/RecordDecodingTests.swift`

#### day is Mac-local day of startedAt; meeting ends after it begins
`RecordDecodingTests.meetingFields`: `day` is the Mac-local day of `startedAt`, and the meeting ended after it began.

#### Design review day is the fixture day with digest and full timeline
`RecordDecodingTests.transcriptDayPersonProject`: The day of the design review, which has a digest and a full timeline.

#### Sample's today has no digest yet
`RecordDecodingTests.transcriptDayPersonProject`: The sample's "today" (its manifest's generatedAt) has no digest yet.

#### Older version never replaces a newer one
`RecordDecodingTests.tombstonesAndVersionsApplyLikeTheSyncCore`: An older version never replaces a newer one.

### `Companion/ios/LokalBotCompanionKit/Tests/LokalBotCompanionKitTests/RecordingTests.swift`

#### Revoked pairing goes but recording stays
`RecordingTests.beingRemovedByTheMacKeepsWhatWasRecorded`: As if a sync heard `revoked`: the pairing goes, the recording stays.

### `Companion/ios/Scripts/render-app-icon.mjs`

#### iOS icon is full-bleed; macOS plate becomes whole canvas, robot rescaled
Renders the iPhone and iPad app icon from Assets/lokalbot-icon.svg.
iOS icons are full-bleed squares the system masks itself, so the macOS
plate (inset 64 pt with rounded corners) becomes the whole canvas and the
robot is scaled to keep its place on it. Needs macOS (`sips`).
Usage: node Companion/ios/Scripts/render-app-icon.mjs

#### Scale robot by 1024/896 about centre to fill full-bleed square
`render-app-icon.mjs`: Everything after the plate is the robot; scale it about the centre by
1024/896 so it fills the full-bleed square as it fills the plate.

#### App Store icons must be opaque so JPEG pass drops alpha
`render-app-icon.mjs`: App Store icons must be opaque: a lossless-quality JPEG pass drops alpha.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
