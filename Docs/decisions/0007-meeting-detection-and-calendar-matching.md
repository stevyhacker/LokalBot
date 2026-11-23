# 0007. Meeting detection and calendar matching

- Status: Accepted
- Date: 2026-11-20

## Context

LokalBot decides when a meeting starts and ends: native meeting apps by their own audio, browser calls by their accessibility tree, with the calendar as supporting evidence. The same feature area holds what runs beside a call: preparation briefs, Live Radar, screen answers and fast live text. The Mac app does this in `MeetingDetector`, `MeetingMatcher` and `BrowserMeetingSession`; the Windows and Linux app in the `meeting` module of `lokalbot-platform` and the `calendar` module of `lokalbot-core`. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Evidence for a call

### The calendar, titles and audio support a call but never prove it

The caller must verify the call itself; for a browser, that is the meeting document's in-call state. In strict mode a browser call also needs an active calendar event with a meeting link. The calendar adds evidence but never replaces it: a browser holding the microphone during an event with a conferencing link is a call even without a Meet title, a chat app starts without the sustained-audio wait while an event is on, and a native app gets extra stop grace inside its event's scheduled window.

Where: `LokalBot/Services/Calendar/MeetingMatcher.swift` (`MeetingMatcher.browserCountsAsMeeting`), `LokalBot/Services/Recording/MeetingDetector.swift`, `LinuxWindows/crates/lokalbot-core/src/calendar/mod.rs` (`browser_counts_as_meeting`), `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs` (`CalendarHint`).

### Start and continuation key off the meeting app's own audio, not the global microphone flag

The detector reads the selected meeting app's own audio input or output. A global "mic in use" flag can belong to Dictation, QuickTime or another meeting app while a known meeting app idles in the background, and once recording starts LokalBot's own mic capture keeps it true, so the meeting never read as ended and recording never stopped. Calendar-backed browsers may also start from output audio found in their helper process. Microphone evidence on Windows is the app's own WASAPI capture session, on Linux its PulseAudio/PipeWire source output.

Where: `LokalBot/Services/Calendar/MeetingMatcher.swift` (`MeetingMatcher.isMeetingOngoing`), `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.applyTick`), `LokalBotTests/Services/Calendar/CalendarDetectionTests.swift` (`MeetingMatcher.isMeetingOngoing`), `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs`.

### Watch meeting apps' audio output too, so muted-mic calls are caught

The mic-in-use signal misses meetings with a muted mic, so an audio monitor reports when a meeting app starts producing audio output; in automatic mode it records recognised meeting sources and lets other candidates expire silently. A candidate is held for up to 20 seconds and is not marked as already playing meanwhile: a muted-mic call that started in that time used to go into the "already playing" set and was never reported or recorded. On Windows, render sessions identify a muted call without turning UI Automation on for idle browsers.

Where: `LokalBot/AppState.swift` (`AppState.init`), `LokalBot/Services/Audio/AudioSourceMonitor.swift` (`AudioSourceMonitor.apply`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`AudioSourceMonitor.apply`), `LinuxWindows/crates/lokalbot-platform/src/meeting/win32.rs` (`WindowsEvidence::collect`).

### Any process in a meeting app's bundle namespace is that app's audio

Teams emits call audio from `<host>.helper` (WebView) and `<host>.modulehost`, and matching only `.helper` misses the process that is usually running; the rule mirrors the `us.zoom.xos.` prefix rule instead of enumerating every suffix Microsoft ships. Electron meeting apps (Teams, Slack, Webex) use a helper the way Chromium browsers do, so the capture lookup honours the same `<host>.helper` relationship: without it `hasOutputAudio` is false, the detector never surfaces the app, `RecordingController` skips the process tap and the meeting silently records mic-only.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.audioBundleID`, `MeetingDetector.captureTargetProcess`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`MeetingDetector.captureTargetProcess`).

### Helpers named outside their host's namespace are mapped explicitly

The map is keyed by the lowercased helper identifier (its `.`-suffixed variants match too) and points to the lowercased host. Feishu's Electron helpers keep ByteDance's `com.bytedance.lark.helper` while the app is `com.electron.lark`; DingTalk's helper is `com.alibaba.DingTalk-Helper` beside `com.alibaba.DingTalkMac`; Webex's media engine `WebexHelper`, which renders the remote participants' audio, registers with Core Audio as `Cisco-Systems.SparkHelper`, outside the `Cisco-Systems.Spark.` namespace of its host `Cisco-Systems.Spark`. Without the mapping a call carried by the helper is never seen, and for Webex the tap lands on the silent main process and the "Them" track records nothing.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.foreignHelperHosts`, `MeetingDetector.audioBundleID(_:belongsTo:)`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`MeetingDetector.audioBundleID(_:belongsTo:)`).

### Teams' modulehost is never evidence of a call

Some bundles in a meeting app's namespace hold their Core Audio streams open for the app's whole lifetime. With Teams launched and idle, 20 samples over 20 s, `com.microsoft.teams2.modulehost` reported `isRunningOutput` and `isRunningInput` true in 20/20 while all three `com.microsoft.teams2.helper` processes reported false in 60/60, so a rule that read it would see Teams permanently in a meeting; the start decision does not read it, while capture may still tap it (a silent tap records nothing until audio starts). An idle always-open stream bridges pauses only while recent reliable evidence exists; after that the normal stop debounce begins even though modulehost still reports running output.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.alwaysOpenAudioBundles`, `MeetingDetector.carriesMeetingSignal`, `MeetingDetector.alwaysOpenAudioContinuationGrace`), `LokalBotTests/Services/Calendar/CalendarDetectionTests.swift` (`MeetingDetector.carriesMeetingSignal`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`MeetingDetector.alwaysOpenAudioContinuationGrace`).

### Browsers are never classified as media players

Browsers host web meetings (Meet, Jitsi, Whereby); treating them as media would stop browser meetings from being detected.

Where: `LokalBot/Services/Audio/AudioSourceMonitor.swift` (`AudioSourceMonitor.isMediaPlayer`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`AudioSourceMonitor.isMediaPlayer`).

## Starting and stopping native meeting apps

### Dedicated conferencing apps start at once; chat-capable apps need 12 s of sustained audio

Zoom, Webex, Tencent Meeting and VooV Meeting start at once. Teams, Slack, Discord, Feishu, Lark, DingTalk and WeCom also carry chat and voice messages, and a message ding or launch blip opens an output stream just as a call does, so their audio must sustain 12 s (inclusive) before it counts as a start. Twelve seconds leaves a 1.2 s margin above the longest observed short false start (10.8 s; the others were 0.2 s and 7.6 s, reconstructed against the 15 s stop debounce) while keeping start latency close to the previous 10 s gate. It does not try to cover the two longer false starts (21.1 s and 48.9 s): those were an output stream held open while emitting digital silence (`peakRMS=0.000000`), a detection defect no threshold separates from a real call (see the modulehost decision above).

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.nativeAudioMinimumConfirmationDuration`, `MeetingDetector.requiresSustainedAudioForStart`), `LokalBotTests/Services/Calendar/CalendarDetectionTests.swift` (`MeetingDetector.requiresSustainedAudioForStart`), `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs`.

### Start confirmation tolerates audio gaps up to 6 s

Confirmation requires current audio (`requireAudio: true`), which asks whether the remote side is making sound right now, and in a real conversation the remote side spends much of its time listening. Without a tolerance the first quiet turn dropped the candidate entirely: on 2026-08-26 six consecutive attempts on a live Teams call each failed after 4.2–12.7 s, two of them past the 12 s mark. The window now survives gaps up to 6 s, half the window on purpose, and is abandoned only once the gap itself runs past that, so a single blip followed by silence still resets; the tolerance only bridges gaps in evidence and never invents any, so an idle open app cannot confirm.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.nativeAudioConfirmationGapTolerance`), `LokalBot/Services/Calendar/MeetingMatcher.swift` (`MeetingMatcher.StartConfirmationGapOutcome`, `MeetingMatcher.startConfirmationGapOutcome`), `LokalBotTests/Services/Calendar/CalendarDetectionTests.swift` (`MeetingMatcher.startConfirmationGapOutcome`), `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs`.

### WeChat is not a known meeting app

WeChat's voice messages and videos play long enough to pass the sustained-audio gate, so listing it would start meetings that are not calls. Feishu is matched as `Lark.app` with Lark's original `com.electron.lark` identifier, and current international Lark builds as `com.larksuite.larkApp`.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.knownApps`), `LokalBotTests/Services/Audio/AudioSourceMonitorTests.swift` (`MeetingDetector.meetingAppCandidates`).

### Only a confident end stops a recording, and rejoining after one records at once

Neither automatic nor explicit recordings are stopped by uncertainty. A meeting ends `stop_debounce` after its evidence disappears, and an explicit end in the browser's accessibility tree stops it immediately. After a confident end, rejoining the same calendar event is a new call and records at once; the repeat cooldown applies only to a recording the user stopped.

Where: `LokalBot/Services/Calendar/MeetingMatcher.swift` (`MeetingDetectionEnd.action`), `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs`.

### A user-started recording joins the detector's call only while the detector can verify it

A recording the user starts for the call the detector is tracking joins that session, so the call's end stops it. A call the detector can no longer verify may already be over, so a recording never joins it. Manual mode leaves every stop to the user.

Where: `LokalBot/AppState.swift` (`AppState.detectorSession(following:)`).

## Calendar matching

### Calendar events are keyed per occurrence

The key is `<uid>#<epoch seconds>` (`occurrenceID`), because the event id alone is shared by every occurrence of a recurring series.

Where: `LinuxWindows/crates/lokalbot-core/src/calendar/mod.rs` (`CalendarEvent::occurrence_id`).

### A calendar-backed recording splits when the active event changes

A recording backed by one calendar event splits as soon as the active event changes, so back-to-back meetings are not merged during the stop debounce.

Where: `LinuxWindows/crates/lokalbot-core/src/calendar/mod.rs` (`should_split_for_calendar_handoff`).

## Browser calls

### Browser calls are detected from accessibility call controls only

Only a supported meeting document and its call controls count, and no pixels, participant names or page text are kept. The older Google Meet title-and-microphone fallback remains available.

Where: `LokalBot/Services/Recording/BrowserMeetingSession.swift`, `LinuxWindows/crates/lokalbot-platform/src/meeting/browser.rs`.

### A call binds to its room's canonical URL, without query or fragment

The canonical address is that of a room whose accessibility controls the app can verify; query and fragment are dropped because they may contain invitations or guest tokens. Meet rooms shown under `/meet/` (such as `/meet/abc-defg-hij`) count as call documents: in #372 they did not, so no meeting started and system audio never attached.

Where: `LinuxWindows/crates/lokalbot-core/src/calendar/conference.rs` (`meeting_room`), `LokalBotTests/Integration/CaptureReplayTests.swift` (`testMeetCallUnderMeetPathStartsAndEnds`).

### Telemost and MTS Link calls need a verified room

Telemost and MTS Link must prove a room before a call counts. Only a nested Telemost document that belongs to the verified room can prove the user joined; other iframe controls cannot. The MTS Link desktop app also plays chat notifications and voice messages, so its conference web view is verified instead of treating its audio as a meeting. On Windows these calls start from a verified room and its joined-call controls and continue on the bound tab or window.

Where: `LokalBot/Services/Recording/BrowserMeetingSession.swift` (`BrowserMeetingSession.nativeWebClients`), `LinuxWindows/crates/lokalbot-platform/src/meeting/browser.rs` (`telemost_room_frame`), `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs`.

### A Join screen ends a call only in the call's own window

A device dialog can hide an existing call's controls without ending it, while a visible Join action shows the participant is back in the lobby. That counts only in the bound call's own window: the same room's lobby elsewhere, such as a reopened invite link while the user is still in the call, is not an end.

Where: `LokalBot/Services/Recording/BrowserMeetingSession.swift` (`BrowserMeetingSession.waitingRoomState`), `LinuxWindows/crates/lokalbot-platform/src/meeting/browser.rs` (`CallState::in_bound_window`), `LokalBotTests/Models/Meetings/MeetingIntegrityTests.swift` (`testJoinScreenEndsOnlyTheCallInItsOwnWindow`).

### Meet's rejoin-or-home pair without call controls is end evidence

Meet's page after a call offers to rejoin it or go home, whatever its heading says (left, removed, ended by the host). With the call controls gone, that button pair is end evidence; the wording is not.

Where: `LokalBot/Services/Recording/BrowserMeetingSession.swift` (`BrowserMeetingSession.CallState.state`), `LinuxWindows/crates/lokalbot-platform/src/meeting/browser.rs` (`call_state`).

### A verified call in another room replaces a stale unverified one

On 2026-10-03 Meet's page after a call was not recognized as an end, so that call stayed bound but unverified and the next meeting, in another room, was never detected. A verified call in another room ends the stale session and starts its own, with its calendar event.

Where: `LokalBotTests/Integration/CaptureReplayTests.swift` (`testCallInAnotherRoomReplacesAnUnverifiedCall`).

### Optional browser microphone calls start only with readable, non-private windows

A browser's microphone identifies a whole process family, not a tab, so "Detect other browser calls" starts only when no window of that browser marks a private window (on the Mac every window must also have a readable Accessibility title; Windows reads only titled top-level windows), in English or a localized form such as "Инкогнито" or Safari's "Частный доступ". During a call, a window that becomes private ends it, while a merely unreadable one (picture-in-picture, an untitled popup, a slow Accessibility reply) does not, because untitled windows used to stop legitimate recordings. Capture traces store only this decision (`allowed`, `unreadable`, `privateWindow`), never the titles. On Windows, Yandex Browser ships as a generic `browser.exe`, so it is recognised by its `Yandex\YandexBrowser` install folder rather than by that name. Safari is not covered on the Mac: its page audio, microphone included, runs in the shared `com.apple.WebKit.GPU` process, which neither carries Safari's identifier nor its `.helper` prefix, so Safari calls start only from the supported meeting hosts.

### On Windows a title is not enough: the browser's own interface decides privacy

A Windows test with Chrome 157 showed that an Incognito window showing a page with an ordinary title has no private marker in its window caption, so a title-only gate auto-recorded a private call; an empty Incognito tab was caught only because the page itself is called "New Incognito tab". Each titled browser window of the family holding the microphone is therefore also classified once by UI Automation of the browser's own interface (buttons and menus outside the web document and tab items, such as Chrome's "Incognito" profile button or Edge's "InPrivate" badge): `Private` when any element name carries a private marker, `Public` when the walk completes and found at least three controls, otherwise `Unknown`. A Chromium window keeps its profile for its whole life, so the answer is cached per window handle; `Unknown` is retried after 10 s. Any `Private` window blocks a start and ends a running call. An `Unknown` window never auto-records: in Automatic mode the call is offered as in Ask mode, and a running call continues. Page text, URLs and tab titles are not read, and only counts are logged. `examples/meeting_probe.rs` prints the same decision per window, with titles only on request, to check new browser versions. The scan runs only while "Detect other browser calls" is on: Meet and the other supported hosts do not use its result, so with the setting off no browser window is read beyond its title.

Where: `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs` (`WindowPrivacy`, `WindowCensus`, `Core::microphone_browser_gate`), `LinuxWindows/crates/lokalbot-platform/src/meeting/win32.rs` (`WindowPrivacyCache`), `LinuxWindows/crates/lokalbot-platform/src/screen/uia.rs` (`BrowserInterfaceReader`), `LinuxWindows/crates/lokalbot-engine/src/detector.rs` (`start_mode`).

Where: `LokalBot/Services/Recording/BrowserMeetingSession.swift` (`MicrophoneWindows`, `microphoneWindows`), `LokalBot/Services/Recording/MeetingDetector.swift` (`browserMicrophoneCandidates`, `browserMicrophoneRetained`), `LokalBot/Services/ScreenMemory/ScreenContextPrivacy.swift` (`isPrivateWindow`), `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs` (`Core::microphone_browser_gate`, `canonical_executable`), `LinuxWindows/crates/lokalbot-platform/src/privacy.rs` (`is_private_window`).

### A chosen call app matches its own helpers, so launchers cannot be chosen

Additional call apps on Windows match the process holding the microphone or any of its ancestors, because call clients often capture audio in a helper they start; the recording then follows the ancestor's process tree. That would let a shell or host such as File Explorer, `cmd.exe` or a terminal turn every microphone app started from it into a call, so `AdditionalCallApp::detector_key` refuses a list of shells, terminals and system hosts, the picker explains why, and such entries already in the settings are dropped. A launcher missing from the list still matches what it starts; choosing the call app itself avoids that.

Where: `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`starts_other_apps`, `AdditionalCallApp::detector_key`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/meetings.rs` (`call_app_from_file`).

### A mute that releases the microphone splits a microphone-detected call

eXpress, additional call apps and optional browser calls are recognised only while they hold the microphone. If an app closes its microphone stream on mute, the call reads as ended: recording stops after the stop delay (15 seconds by default), and unmuting starts a new recording, so one call becomes two meetings with a gap. Whether eXpress's native mute closes the stream has not been tested with a live call; this is accepted as a known limitation.

### Additional call apps keep their own executable key

Users pick additional call apps by file, and several can share a display name, so detection, start confirmation and handoff compare the normalized executable (Windows) or bundle identifier (Mac), never the name. The desktop MTS Link client keeps its room evidence even when one of its helpers is on the list.

Where: `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs` (`Candidate::configured_executable`), `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`AdditionalCallApp::detector_key`), `LokalBot/Models/Settings/AppSettings.swift` (`AdditionalCallApp`).

### Prime web accessibility with `AXManualAccessibility`, once per browser process

Chromium and Firefox expose page content to accessibility clients only once asked. Chromium honours `AXManualAccessibility`, the switch for assistive tools that are not screen readers (cotyping already uses it); `AXEnhancedUserInterface` puts the whole app into VoiceOver mode, which slows Chrome and breaks window-manager animations, and it used to be set on every 2-second poll, so only Firefox still gets it. Safari exposes its pages.

Where: `LokalBot/Services/Recording/BrowserMeetingSession.swift` (`BrowserMeetingSession.webAccessibilityPrimingAttribute`).

## Detector cost and stalls

### Cache NSWorkspace's running applications

Each property read on an `NSRunningApplication` is a synchronous LaunchServices round trip, and NSWorkspace returns fresh objects on every call for the ~100 processes without a bundle id. The detector mapped all ~200 apps twice per 2-second tick on the main thread, which a live profile on 2026-10-01 showed as 40–70 ms stalls every tick (about 5% of the main thread while idle). The list is now read once and kept until an app launches or quits, or at most `maximumAge`, and values are kept per application object (retained while cached so an identifier is never reused), so a refresh reads only apps it has not seen; every caller looks apps up by bundle id, and the processes that churn have none.

Where: `LokalBot/Services/Capture/LiveCaptureEnvironment.swift` (`RunningApplicationCache`), `LokalBotTests/Services/Recording/RunningApplicationCacheTests.swift` (`RunningApplicationCache`).

### Re-walk a quiet browser window only on title change or age

Meet detection polls every 2 s. A browser window whose complete read found no Meet document is walked again only when its title changes or its entry ages out: 2 walks a minute instead of 30.

Where: `LokalBotTests/Integration/PerformanceReadPathTests.swift` (`testQuietBrowserWindowIsWalkedAgainOnlyOnTitleChangeOrAge`).

### The Windows and Linux detector polls from one background thread

`MeetingDetector::poll` runs every ~2 s from one background thread.

Where: `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs` (`MeetingDetector::poll`).

### Install the default-device listener once

Re-adding it on every re-arm multiplied Core Audio callbacks, so each mic open or close fanned out into a tick storm.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.deviceChangeListener`).

### Log a browser observation that never returns, without acting on it

Every tick waits for the browser observation in flight, so one that never finishes stops the detector silently. On 2026-11-17 no observation of a Meet call came back after 18:51, when the app's Swift task pool appears to have stalled; the call's end went unseen and the recording ran all night. A log line now dates such a stall but changes no decision; the recording's own silence watch ends that recording.

Where: `LokalBot/Services/Recording/MeetingDetector.swift` (`MeetingDetector.noteBrowserPollStillRunning`).

## Meeting preparation and Live Radar

### Code picks meeting-prep evidence; the model only rewrites it, and the brief is never saved

Code selects prior meetings by attendees and recurring title, their decisions, open commitments and related projects. The local Think model only rewrites that packet into a short brief, which is kept in memory and never saved.

Where: `LokalBot/Services/Calendar/UpcomingMeetingPreparation.swift`, `LinuxWindows/crates/lokalbot-ai/src/upcoming.rs`.

### Live Radar sends nothing until the person presses Start Radar

Live Radar sits beside the transcript and notes in the live meeting view, and nothing is sent until the person presses Start Radar for this meeting.

Where: `LokalBot/Views/LiveRadar/MeetingRadarPanel.swift` (`MeetingRadarPanel`).

### The floating Live Radar panel is left out of screen sharing by default

The panel is a small always-on-top window, for checking Live Radar from the meeting app, that floats over other apps and full-screen calls and never takes focus from them. By default it is excluded from screen sharing and screen recordings. It opens when a recording starts (if Live Radar is on, with Start Radar in it) and when the radar starts.

Where: `LokalBot/Views/LiveRadar/LiveRadarFloatingPanel.swift` (`LiveRadarPanelController`).

### Radar items must quote one of the new lines

A pass sends the lines that arrived since the previous pass, a little of the conversation before them, what is already on the radar, and passages from earlier meetings that local search found for the new lines. Whatever comes back must quote one of the new lines, and a contradiction must also name a passage it was shown; anything else is dropped, never shown. The request and checks are pure, so the prompt, schema and grounding rules are tested without a model or network.

Where: `LokalBot/Services/MeetingRadar/MeetingRadarAnalyzer.swift` (`MeetingRadarAnalyzer`).

### Screen answers send only crop text, and the quote must be in it

When Live Radar catches a question, local screen search finds earlier captures that mention it, Vision on this Mac crops each one to the rows that do, and the Think model reads only the crops' text with each crop's app, window title and time; no pixels leave the Mac. An answer counts only when its quote is in the crop's own text, so the model cannot invent one. The feature is off by default.

Where: `LokalBot/Services/MeetingRadar/RadarScreenAnswers.swift` (`RadarScreenAnswers`), `LokalBotTests/Services/MeetingRadar/RadarScreenAnswersTests.swift` (`testRadarAnswersACaughtQuestionFromTheScreenAndSavesTheCrop`).

### Live-answer tools stay inside approved folders and never read hidden or secret files

The tools over the person's folders and repositories are read-only, and every path stays inside an approved folder. Hidden files and folders, `node_modules` and secret-looking files are never read, even when git tracks them (`search_code` and `read_file` used to return them), and in a repository only files git tracks are read. A tracked symlink is read through, and its target is held to the same rules as the requested path. Commands run with a short timeout and capped output.

Where: `LokalBot/Services/MeetingRadar/LiveAnswerTools.swift` (`LiveAnswerTools`, `LiveAnswerTools.readFile`), `LokalBotTests/Services/MeetingRadar/LiveAnswersTests.swift` (`testCodeToolsLeaveOutHiddenVendoredAndSecretFilesGitTracks`).

### Fast live text streams to Muse only when turned on, and speakers come from the track

The live transcript preview can stream each recorded track to Muse Voice Transcribe's realtime endpoint and get each turn's text about 0.7 s after the speaker stops, instead of transcribing 12-second chunks on this Mac. It is off by default, because turning it on sends meeting audio to api.meta.ai while the preview runs. Speaker identity still comes from the track (the microphone is the person), because Muse's own speaker labels measured less accurate than local diarization. It was built for the Meta Global AI Developer Hackathon (2026).

Where: `LokalBot/Services/MeetingRadar/MuseLiveText.swift` (`MuseLiveText`).

### Keep the Muse stream at real time

The server rejects a stream more than 5 s ahead of real time, so a fresh session starts at most 5 s back in the recording. Audio goes out as it is recorded; when the file stops growing (a silent or missing source) the session is padded with silence so the server never sees below-real-time ingress, and the padded stretch of the file is skipped when it arrives.

Where: `LokalBot/Services/MeetingRadar/MuseLiveText.swift` (`MuseLiveText.backlogSeconds`, `MuseLiveTextPacer`).

### Send the Muse key in the handshake frame, not a header

The key travels in the first frame of a session rather than in a request header.

Where: `LokalBot/Services/MeetingRadar/MuseLiveText.swift` (`MuseLiveText.handshake`).

## Consequences

- A new start or end signal must be verified evidence of the call itself; the calendar, titles, the global mic flag and always-open streams such as Teams' modulehost can only support it.
- The timing values (12 s confirmation, 6 s gap tolerance, 15 s stop debounce, 2 s poll) come from measured false starts, failed live calls and profiles; change them only against new measurements, in both the Swift and Rust detectors.
- Live Radar, screen answers and fast live text send nothing by default; anything sent off the Mac stays opt-in, and model output stays grounded in quoted text.
