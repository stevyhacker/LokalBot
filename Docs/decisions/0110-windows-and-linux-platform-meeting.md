# 0110. Windows and Linux: platform — meeting

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-platform/src/meeting/`.

## Decisions

### `LinuxWindows/crates/lokalbot-platform/src/meeting/browser.rs`

#### Only supported meeting documents and controls count; nothing else kept
What a browser's accessibility tree says about a call
(`BrowserMeetingSession.swift`). Only a supported meeting document and its
call controls count, and no pixels, participant names or page text are kept.

The older Google Meet title and microphone fallback remains available.
Telemost and MTS Link must prove a room, including from the desktop MTS
Link web view.

#### All windows in one poll give up after one second
`READ_DEADLINE`: All of a poll's windows give up after this long.

#### Labels longer than 160 are page text, not control names
`MAX_LABEL`: Longer labels are page text, not a control's name.

#### Windows without Meet document skipped 30 s unless title changes
`QUIET_MAX_AGE`: How long a window without a Meet document isn't walked again, unless a
new title says a tab came to the front (`QuietWindowCache.maximumAge`).

#### Device dialog hides controls; visible Join means back in lobby
`CallState::in_bound_window`: A device dialog can hide the controls of an existing call. A visible
Join action instead shows that the participant is back in the lobby.

#### Window owner pid used for loopback when identifiable
`BrowserDocument.host_pid`: Window owner when the operating system can identify it for loopback.

#### Nothing read, so title and microphone decide
`Verdict::Unknown`: Nothing was read: the title and microphone decide.

#### Room remains in bound window but controls are hidden
`Verdict::Present`: The room is still in its bound window, but its controls are hidden.

#### Only exact Meet room documents; /meet/ form normalized to short form
`meet_url`: The canonical meeting-room URL, or `None` for anything that is not an exact
`https://meet.google.com/abc-defg-hij` document. Meet also serves the room
as `/meet/abc-defg-hij`; both give the short form calendar links use.

#### Rejoin plus return-home offer is end evidence when wording is not
`call_state`: Meet's page after a call offers to rejoin it or go home, whatever its
heading says. With the call controls gone, that pair is end evidence
where the wording is not.

#### Only room-frame iframe controls may prove user joined
`telemost_room_frame`: Whether a nested Telemost document belongs to the verified room; other
iframe controls must not be used to prove that the user joined.

#### Landing page consulted only for verified window after call tab gone
`is_post_call_page`: The landing page reached when leaving a supported room. This is only
consulted for its previously verified window once its call tab is gone.

#### Expected room binds a call; other rooms' documents say nothing
`verdict`: What `documents` say about `family`'s call. `expected` is the room a call
already in progress is bound to: another room's document says nothing about it.

#### Meet keeps legacy behavior; other providers must identify one room
`verdict`: Keep the existing Google Meet behavior. Other providers must
identify one room before they can authorize a new recording.

#### UIA delivers window controls in document order
`WindowCall`: The controls of a Windows window arrive in document order from UIA.

#### Cache windows with no Meet document to avoid walking every poll
`QuietWindows`: Browser windows whose last complete read found no Meet document, so a
window keeping its title isn't walked on every poll (`QuietWindowCache`).

#### Label matching must not accept lookalike prefixes
`call_controls_decide_the_state`: A word that only starts the same doesn't offer the action.

#### Call controls beside rejoin offer are not the end
`the_end_is_read_from_the_page`: Call controls beside a rejoin offer are not the end.

### `LinuxWindows/crates/lokalbot-platform/src/meeting/linux.rs`

#### Linux evidence from pactl JSON, X11/Hyprland/Sway titles; other Wayland via observe_window
Linux evidence: recording streams from PulseAudio or PipeWire
(`pactl -f json list source-outputs`, falling back to the text listing),
and window titles from X11's client list or the Hyprland/Sway IPC. Other
Wayland desktops get titles through `MeetingDetector::observe_window`.

#### Browser tree read every 4 s; BROWSER_GAP tolerates the wait
`CALL_READ_INTERVAL`: A browser's tree answers one question per call, so it is read less often
than the poll. `BROWSER_GAP` tolerates the wait.

#### pactl before PulseAudio 16 has no JSON output
`PulseEvidence::streams`: pactl before PulseAudio 16 has no JSON output.

#### Window titles read only while a browser holds the microphone
`PulseEvidence::collect`: Window titles matter only while a browser holds the microphone.

### `LinuxWindows/crates/lokalbot-platform/src/meeting/mod.rs`

#### Detector start rules: immediate apps, 12 s sustained apps, calendar and browser evidence
Meeting detection (`MeetingDetector.swift`, `MeetingMatcher.swift`,
`BrowserMeetingSession.StartGate`).

Microphone evidence comes from the meeting app's own WASAPI capture session
on Windows or its PulseAudio/PipeWire source output on Linux. Zoom, Webex, Tencent Meeting and VooV Meeting
start at once; Teams, Slack, Discord, Feishu, Lark, DingTalk and WeCom need
12 s of sustained evidence (gaps up to 6 s tolerated). A meeting ends
`stop_debounce` after its evidence disappears.

Google Meet can also use the browser's title and microphone. On Windows,
Telemost and MTS Link browser calls use a verified room and its joined-call
controls for start, and its bound tab or window for continuation. An
explicit end in the accessibility tree ([`browser`]) stops immediately.

The calendar ([`CalendarHint`], `MeetingDetector.swift`) adds evidence but
never replaces it: a browser holding the microphone during an event with
a conferencing link is a call even without a Meet title, a chat app starts
without the sustained wait while an event is on, and a native app gets
extra stop grace inside its event's scheduled window.

Poll [`MeetingDetector::poll`] every ~2 s from one background thread.

#### audio_pid is the app's top process whose tree plays call sound
`DetectedMeeting.audio_pid`: The top process of the app, whose tree plays the call's sound.

#### title_hint comes from browser tab title, when present
`DetectedMeeting.title_hint`: The meeting's name from a browser tab title ("Meet – Weekly sync"),
when it has one.

#### Browser calls count only with meeting_url (requireCalendarForBrowser)
`CalendarHint.require_for_browser`: Browser calls count only with `meeting_url` (`requireCalendarForBrowser`).

#### Stop grace only for native apps inside event window; browsers never
`CalendarHint.grace`: Stop grace for a native app while its event is in its scheduled window
(`calendarBackedGrace`). Browser calls never get it.

#### ancestors are parent executable names, nearest first, Windows only
`CaptureStream.ancestors`: Executable names of the parent processes, nearest first (Windows).

#### app is executable name or Linux app id or WM_CLASS
`WindowTitle.app`: Executable name, or a Linux app id / `WM_CLASS`.

#### Stop debounce default and range mirror macOS stopDebounceSeconds
`DEFAULT_STOP_DEBOUNCE`: The macOS stop debounce default and range (`stopDebounceSeconds`).

#### 12 s mirrors nativeAudioMinimumConfirmationDuration
`SUSTAINED_START`: `nativeAudioMinimumConfirmationDuration`.

#### 6 s mirrors nativeAudioConfirmationGapTolerance
`SUSTAINED_GAP`: `nativeAudioConfirmationGapTolerance`.

#### Browser start gate: in call 2 s, gaps up to 4 s
`BROWSER_START`: `BrowserMeetingSession.StartGate`: in call for 2 s, gaps up to 4 s.

#### Observed Meet title counts 10 minutes after tab loses focus
`OBSERVED_TITLE_LIFETIME`: A Meet title reported through [`MeetingDetector::observe_window`] counts
for this long after the tab lost focus.

#### Non-Meet browser call known from calendar event link
`AppKind::WebCall`: A browser call on a conferencing site other than Meet, known from the
calendar event's link ("Zoom", "Teams", …).

#### Chat apps make short sounds so need sustained audio to start
`AppKind::needs_sustained_evidence`: Dedicated conferencing apps start at once; chat apps make short sounds
and need sustained evidence (`requiresSustainedAudioForStart`).

#### Browser helper processes grouped into one family
`browser_family`: Browser executables, grouped so that helper processes share a family.

#### Native MTS Link client shares its web client's room UI
`document_family`: The native MTS Link client uses the same room UI as its web client.

#### Meet tab title yields meeting name; bare code gives none
`meet_title`: Whether a window title belongs to a Google Meet tab, and the meeting name
it shows ("Meet – Weekly sync" → "Weekly sync"; a bare meeting code gives
no name).

#### Strip browser's own title suffix
`meet_title`: Drop the browser's own suffix (" - Google Chrome", " — Mozilla Firefox").

#### Meet family keeps a call with its browser
`Candidate.family`: Browser family for Meet, so a call stays with its browser.

#### Combines macOS StartConfirmationState and StartGate for evidence duration
`Confirmation`: `MeetingMatcher.StartConfirmationState` and `StartGate` in one: how long
a candidate's evidence has lasted.

#### Decision logic separated from OS for fake-clock testing
`Core`: The decision logic, separate from the OS so it can be tested with a fake
clock and fake evidence.

#### current ties active call to room or browser microphone
`Core::candidates`: Meeting candidates in priority order, one per app.
`current` keeps an active call tied to its room, or to the browser's
microphone for services that don't require room evidence.

#### Verified-room path owns authorization and loopback for room-required services
`Core::candidates`: The verified-room path above owns authorization and
loopback selection for these services.

#### Legacy microphone fallback kept for non-room-required calls
`Core::candidates`: Keep the legacy microphone fallback for other calls.

#### Browser microphone during event with conferencing link counts as call
`Core::candidates`: The calendar's link check: the browser holds the
microphone during an event with a conferencing link.

#### PulseAudio app names like ZOOM VoiceEngine identify Zoom
`Core::candidates`: PulseAudio names such as "ZOOM VoiceEngine".

#### Calendar-backed start skips the sustained wait
`Core::confirm`: A calendar-backed start skips the wait (`requiresSustainedAudioForStart`).

#### Page saying call is over ends it with no debounce
`Core::step`: The page says the call is over: no debounce (`browser-ended`).

#### Only best candidate may start; other pending window replaced like macOS
`Core::step`: Only the best candidate may start; a pending window for another
app is replaced, like the single `startConfirmation` on macOS.

#### Another app's confirmed call takes over (meeting-app-handoff)
`Core::step`: Another app's call took over (`meeting-app-handoff`).

#### Run on own thread and poll about every 2 s
`MeetingDetector`: Watches for calls. `Send`: run it on its own thread and [`poll`] every
~2 s.

[`poll`]: MeetingDetector::poll

#### Stop debounce clamped to 5 to 120 s like macOS
`MeetingDetector::set_stop_debounce`: How long a meeting may lose its evidence before it ends, clamped to
5–120 s like `stopDebounceSeconds`.

#### Failed evidence read counts as no evidence, logged once
`MeetingDetector::poll`: Reads the current evidence and returns what changed since the last
poll. A failed read counts as no evidence (and is logged once).

#### On Wayland this is the only source of Meet tab titles
`MeetingDetector::observe_window`: Feeds a window the user focused (for example each activity sample's
`app_id` and `title`). On Wayland this is the only way the detector
sees Google Meet tab titles.

#### Unreadable tree with title and microphone still starts, as before
`a_readable_waiting_room_never_starts_a_call`: The same title and microphone with no readable tree is today's start.

#### Ends even while browser holds microphone and tab keeps title
`a_page_that_says_the_call_is_over_ends_it_at_once`: The browser still holds the microphone and the tab keeps its title.

#### WeChat excluded: voice messages pass the sustained wait
`the_macs_native_meeting_apps_are_known_on_both_platforms`: Too broad to call a meeting, as on the Mac: its voice messages and
videos sound long enough to pass the wait.

#### Chat-carrying apps need sustained wait; dedicated apps start at once
`only_the_dedicated_conferencing_apps_start_at_once`: Dedicated conferencing apps start at once; the ones that also carry
chat and voice messages need the sustained wait (`knownApps`).

#### Evidence gone at 12 s ends at first poll after 27 s
`zoom_starts_at_once_and_ends_after_the_debounce`: Evidence gone at 12 s; the 15 s debounce ends it at the first poll
after 27 s.

#### Silence past 6 s gap restarts the start window
`a_ding_is_not_a_meeting`: Silent past the 6 s gap tolerance: the window starts over.

#### Microphone without Meet tab is some other site
`browsers_need_a_meet_title_and_two_seconds`: Microphone without a Meet tab: some other site.

#### Switching tabs keeps call while browser holds microphone
`browsers_need_a_meet_title_and_two_seconds`: Switching tabs keeps the call while the browser holds the mic.

#### Call continues on microphone after the event ends
`a_calendar_link_makes_a_browser_microphone_a_call`: The call continues on the microphone after the event ends.

#### Teams 12 s confirm beats Zoom 15 s debounce, so handoff
`a_new_app_takes_over_after_confirming`: Zoom quits and Teams starts: Teams needs 12 s, before Zoom's 15 s
debounce, so the meeting hands off.

### `LinuxWindows/crates/lokalbot-platform/src/meeting/win32.rs`

#### Windows evidence: WASAPI capture sessions, ToolHelp names, browser titles
Windows evidence: processes with an active WASAPI capture session on any
active microphone (`IAudioSessionManager2`), their executable and parent
names from a ToolHelp snapshot, and browser window titles.

#### Render sessions identify muted call without enabling UIA on idle browsers
`WindowsEvidence::collect`: Render sessions can identify a muted call without turning UI
Automation on for idle browsers.

#### Thread already in another apartment keeps it; COM still works
`ComScope`: Balances `CoInitializeEx` on this thread. A thread already in another
apartment keeps it; COM works there too.

#### CoInitializeEx balanced in drop when it succeeded
`ComScope::enter`: SAFETY: plain COM initialization for the calling thread; balanced
in `drop` when it succeeded.

#### Snapshot handle closed; dwSize set as Process32FirstW requires
`process_table`: SAFETY: the snapshot handle is closed below; `entry` has dwSize set as
Process32FirstW requires.

#### WebView2 and Electron helpers sit several levels below app
`stream_for`: WebView2 and Electron helpers sit a few levels below the app.

#### Only active sessions count, excluding system-sounds session
`active_session_pids`: Processes with an active (not merely open) session on any active
endpoint of `flow`, excluding the system-sounds session.

#### COM interfaces owned here; caller's ComScope initializes COM
`active_session_pids`: SAFETY: COM calls on interfaces this function owns; COM is initialized
by the caller's `ComScope`.

#### lparam is the WindowSearch kept alive during enumeration
`visit_window`: SAFETY: `lparam` is the `WindowSearch` that `browser_windows` keeps
alive for the whole enumeration.

#### EnumWindows callback runs only during call while search lives
`browser_windows`: SAFETY: the callback only runs during this call, while `search` lives.

#### Test only reports; over SSH no audio session is fine
`enumerates_audio_sessions`: Reports what this machine's audio stack shows; over SSH there may be
no audio session at all, which is fine.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
