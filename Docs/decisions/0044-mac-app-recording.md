# 0044. Mac app: Recording

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Recording/`, `LokalBotTests/Services/Recording/`.

## Decisions

### `LokalBot/Services/Recording/BrowserMeetingSession.swift`

#### Call lifecycle evidence is independent of audio; only supported call documents count
`BrowserMeetingSession`: Call lifecycle evidence is independent of audio. Only a supported meeting
document and its call controls count.

#### Present means window holds call tab with unreadable controls; gone means closed
`BrowserMeetingSession.State`: `present`: the verified window still holds the call's tab, but its call
controls cannot be read (a large page, a slow tree, another tab in front).
`gone`: that window was closed or no longer holds the call's tab.

#### MTS Link desktop app is verified by its web view because it plays chat audio
`BrowserMeetingSession.nativeWebClients`: The MTS Link desktop app also plays chat notifications and voice messages.
Verify its conference web view instead of treating audio as a meeting.

#### Window title at verification is the call tab's title
`BrowserMeetingSession.Window.title`: The window title when its call was verified, i.e. the call tab's title.

#### Join screen ends the call only in the bound window, not another lobby
`BrowserMeetingSession.waitingRoomState`: A Join screen ends the bound call only in the call's own window. The
same room's lobby elsewhere, such as a reopened invite link, is not it.

#### Only a previously verified window can suspend observations or hold a binding
`BrowserMeetingSession.WindowBindings`: Only a previously verified window can suspend lifecycle observations.
Another browser window or unrelated audio cannot acquire this binding.

#### Read issue is diagnostics only
`BrowserMeetingSession.lastReadIssue`: Diagnostics only: why the latest read of this browser found no call.

#### Per-window AX budget stops a pathological page starving the meeting document
`BrowserMeetingSession.TraversalBudget`: AX is a best-effort source. A pathological background page must be
isolated to its own window so it cannot consume the budget for the
meeting document we are trying to verify.

#### Missing AX snapshot is not evidence of an ended call
`BrowserMeetingSession.LifecycleDecision`: Lifecycle observations are allowed to be temporarily unavailable. A
missing Accessibility snapshot is not the same evidence as a call that
explicitly ended or a browser process that disappeared.

#### Unreadable host or controls cannot prove an end; keep capture alive
`BrowserMeetingSession.lifecycleDecision`: A missing host/document or unreadable controls cannot prove an end.
Keep the authorized capture and its binding alive until positive end
evidence or the user's Stop action, however long observation takes.

#### Minimized or unreadable window suspends but keeps recording, cannot start a session
`BrowserMeetingSession.lifecycleDecision`: A minimized window, or a call tab whose controls are unreadable,
cannot expose call controls, so it is not fresh call evidence. It
is, however, positive evidence that the exact previously verified
window still holds the call. Keep that recording until the
controls return, the tab/window/host disappears, or an explicit
ended state is seen. Neither can pass StartGate and begin a session.

#### Uncertainty never expires recording; only verified closure starts end grace
`BrowserMeetingSession.LifecycleTracker`: One bound call's lifecycle. Uncertainty never expires the authorization
to keep recording. Only continuously verified closure starts end grace.

#### Evidence is in-call controls or the verified window still holding the call
`BrowserMeetingSession.LifecycleTracker.lastEvidenceAt`: In-call controls, or the verified window still holding the call.

#### Suspended window restarts the grace clock for later uncertainty
`BrowserMeetingSession.LifecycleTracker.observe`: The window still holds the call, so the grace clock restarts
and a later uncertain period gets its full grace.

#### Match real mic toggles, not menu labels like Включить микрофон Меню
`BrowserMeetingSession.CallState.state`: Match the actual toggles, not menu labels such as "Включить микрофон Меню".

#### MTS Link Join action vetoes in-call even with device preview Leave button
`BrowserMeetingSession.CallState.state`: Its device preview renders behind a dialog, with the room's
own Leave button. The Join action is a veto, even in that tree.

#### Meet rejoin plus return-home pair is end evidence when controls are gone
`BrowserMeetingSession.CallState.state`: Meet's page after a call offers to rejoin it or go home, whatever its
heading says (left, removed, ended by the host). With the call
controls gone, that pair is end evidence where the wording is not.

#### Same room's lobby in another window doesn't decide; bound window does
`BrowserMeetingSession.liveSnapshot`: The same room's lobby in another window is not the call's
document, so the bound window and its tabs still decide.

#### Nil keeps uncertainty when window list, tab strip or controls unreadable
`BrowserMeetingSession.boundWindowState`: What the exact verified window shows when its call controls were not
read. Nil keeps today's uncertainty: the window list or tab strip could
not be read, or the call document itself was readable without controls.

#### Moved tabs can replace the window, so inspect all windows before closing
`BrowserMeetingSession.boundWindowState`: A moved tab can replace its original window. Inspect every window
before calling the bound call closed; unreadable strips abstain.

#### Call a tab closed only when its title was recognisable
`BrowserMeetingSession.boundWindowState`: Only call a tab closed when its title was recognisable to begin with.

#### Meet titles carry room code; other services use the verified title
`BrowserMeetingSession.closureState`: Meet has a room code in its tab title. The other services can show
just the call title, so use the exact title we verified in the room.

#### Title matches by room code or verified title, tolerating Chrome tab suffixes
`BrowserMeetingSession.titleNamesCall`: Whether a window or tab title still names the verified call. Meet puts
the room code in its title; the title seen at verification also counts,
including Chrome's appended tab states such as "- Audio playing".

#### Loose title match only keeps an existing binding, never starts one
`BrowserMeetingSession.titleNamesCall`: Chrome can prefix the localized tab label and quote the title,
then append a group name or a microphone/audio indicator. This
comparison only keeps an existing binding; it cannot start one.

#### Nil when tab strip not found or not fully read
`BrowserMeetingSession.tabStripContains`: Searches the window's tab strip (the first tab group outside page
content). Nil when the strip is not found or not read completely.

#### Scan a few levels because tabs may sit in named tab groups
`BrowserMeetingSession.tabStripContains`: Tabs may sit inside named tab groups, so scan a few levels down.

#### Enumerate all windows; retain no pixels, names or page text
`BrowserMeetingSession.window`: Enumerate browser windows, never just the focused window. Background
documents unavailable through Accessibility safely abstain. No pixels,
participant names, or page text are retained by lifecycle detection.

#### Native closure checks read minimized windows so a chat window doesn't keep the call open
`BrowserMeetingSession.observeWindow`: A native client's closure check must read its other windows even
when minimized, or one minimized chat window keeps the call open.
The bound window's own minimized state is reported separately.

#### Never look for conferencing iframes on unrelated browser sites
`BrowserMeetingSession.observeWindow`: Never look for a conferencing iframe on an unrelated
browser site. A known desktop client may embed its own web view.

#### Meet post-call actions may be links rather than buttons
`BrowserMeetingSession.observeWindow`: Meet's post-call actions may be links rather than buttons.

#### Only a complete read without a meeting document is remembered as quiet
`BrowserMeetingSession.observeWindow`: Only a complete read without any meeting document is remembered.

#### Return an in-call match for an expected URL immediately to bound latency
`BrowserMeetingSession.observeWindow`: An expected URL is already the caller's binding. Return a
positive call-control match immediately so unrelated heavy
windows later in the AX list cannot add latency or fail the
bound meeting lookup.

#### Multiple unrelated call windows must not silently pick the first
`BrowserMeetingSession.observeWindow`: Multiple unrelated meeting windows cannot silently pick the first call.

#### Find Telemost's call toolbar before walking deep chat lists
`BrowserMeetingSession.readTelemostCall`: Telemost keeps the entire chat application in the meeting page. Find
the call toolbar before walking deep chat lists; those lists can use
the full window budget even when the call controls are easy to reach.

#### Cache quiet windows by title for 30 s to avoid per-tick cross-process AX walks
`BrowserMeetingSession.QuietWindowCache`: Browser windows whose last complete read found no meeting document. A meeting
tab coming to the front or loading replaces the window's title, so a
window keeping its title is not walked again until `maximumAge` passes.
Each walk visits the browser's own toolbar, tab strip, and bookmarks
with one cross-process call per node, which every 2-second detector
tick used to repeat for every window, in LokalBot and in the browser.

#### Prime Chromium with AXManualAccessibility; AXEnhancedUserInterface only for Firefox
`BrowserMeetingSession.webAccessibilityPrimingAttribute`: Chromium and Firefox expose page content to accessibility clients only
once asked. Ask once per browser process. Chromium honours
`AXManualAccessibility`, the switch meant for assistive tools that are
not screen readers (cotyping already uses it). `AXEnhancedUserInterface`
also puts the whole app into VoiceOver mode, which slows Chrome and
breaks window-manager animations, and it used to be set on every
2-second poll; only Firefox still needs it. Safari exposes its pages.

#### Busy browser timeout is retried on the next poll
`BrowserMeetingSession.primeWebAccessibility`: A busy browser timed out; ask again on the next poll.

### `LokalBot/Services/Recording/MeetingDetector.swift`

#### Always-open process can bridge gaps but never be evidence itself
`MeetingContinuationLease`: A permanently-open process may bridge a brief gap in otherwise reliable
meeting audio, but it may not become evidence by itself. The detector owns
one lease per active session and renews it only when app audio that can
actually stop is observed.

#### Start needs app plus mic; end is debounced; listeners plus slow safety poll
`MeetingDetector`: Detects meeting start/end by combining two signals (design doc §2.1):
  1. A known meeting app is running.
  2. The default input device (mic) is in use system-wide.
Start fires immediately; end fires after a debounce so brief mic drops
(e.g. switching AirPods) don't split a meeting in two.

Reacts instantly via Core Audio property listeners (mic in use, default
device change) and NSWorkspace launch/quit notifications; a slow safety
poll covers what has no notification — browser call state.

#### Feishu bundle ids; WeChat omitted because voice messages pass the audio gate
`MeetingDetector.knownApps`: Known native meeting apps.

Feishu ships as `Lark.app` with Lark's original `com.electron.lark`
identifier; current international Lark builds use
`com.larksuite.larkApp`. WeChat is deliberately absent: its voice
messages and videos play long enough to pass the sustained-audio gate,
so listing it would start meetings that are not calls.

#### Only dedicated conferencing apps auto-record on audio; broad chat apps need calendar or sustained audio
`MeetingDetector.highConfidenceNativeAudioBundles`: Native bundles whose newly-started output is a strong meeting signal on
its own. Broader communication apps (Slack/Teams/FaceTime, and Feishu,
Lark, DingTalk and WeCom, which also carry chat and voice messages) can
make non-meeting sounds, so the audio monitor only auto-records those when
an active calendar meeting backs the signal; the detector still picks them
up on its own, but only once their audio has lasted
`nativeAudioMinimumConfirmationDuration` (see
`requiresSustainedAudioForStart`). Tencent Meeting and VooV Meeting are
dedicated conferencing apps, like Zoom.

#### Twelve second confirmation sits above measured 10.8 s false start
`MeetingDetector.nativeAudioMinimumConfirmationDuration`: Minimum duration a broad communication app's audio must sustain before
it counts as a meeting start. Confirmation is inclusive at exactly this
duration; shorter candidates are rejected. A message ding or launch blip
opens an output stream just as a call does, so the value must sit above
the measured transient range.

Twelve seconds leaves a 1.2 s margin above the longest observed short
false start (10.8 s) while keeping real-call start latency bounded close
to the previous ten-second gate. The other short samples were 0.2 s and
7.6 s, reconstructed against the 15 s stop debounce.
It deliberately does not try to cover the two longer ones (21.1 s and
48.9 s) — those were an output stream held open while emitting digital
silence (`peakRMS=0.000000` throughout), which no threshold separates
from a real call without also refusing to record one. That case is a
detection-side defect rather than a timing one; see the note on
`alwaysOpenAudioBundles`.

#### Six second gap tolerance keeps conversations from resetting confirmation
`MeetingDetector.nativeAudioConfirmationGapTolerance`: How long the confirmation window survives a candidate producing no
output audio at all, before `nativeAudioMinimumConfirmationDuration`
has elapsed.

`detectRunningMeetingApp` requires current audio (`requireAudio: true`)
so the confirmation window is watching a signal that is not "is a call
happening" but "is the remote side making sound right now" — and in a
real conversation the remote side spends much of its time listening.
Without this, the very first quiet turn dropped the candidate entirely
(not merely the elapsed time — the app stopped being detected as
running at all), and a live 12-second window essentially never
completed: six consecutive real attempts on 2026-08-26 each failed
after 4.2–12.7 s, two of them past the 12 s mark itself.

Six seconds is half the confirmation window on purpose: a single blip
followed by silence past this tolerance still resets — the case
`nativeAudioMinimumConfirmationDuration` exists to guard against — while
audio recurring at least this often lets a real conversation complete
the window. It only ever bridges a gap in evidence; it never invents
evidence on its own, so this cannot make an idle-but-open app confirm.

#### Teams modulehost holds streams open always, measured 20/20 idle; detection only
`MeetingDetector.alwaysOpenAudioBundles`: Bundles inside a meeting app's namespace that hold their Core Audio
streams open for the app's whole lifetime, so their state carries no
information about whether a call is running.

Measured with Teams launched and idle, 20 samples over 20 s:
`com.microsoft.teams2.modulehost` reported `isRunningOutput` *and*
`isRunningInput` true in 20/20, while all three
`com.microsoft.teams2.helper` processes reported false in 60/60. Any
detection rule that matches the whole namespace therefore sees Teams as
permanently in a meeting, and neither a longer window nor the microphone
can tell the two apart. Capture must still be free to tap these — a tap
on a silent process simply records nothing until audio starts — so this
belongs to the detection question alone.

#### Dedicated and calendar-backed starts stay instant; browsers have own gates
`MeetingDetector.requiresSustainedAudioForStart`: Whether this app's audio must survive
`nativeAudioMinimumConfirmationDuration` before a recording starts.
Dedicated conferencing bundles and
calendar-backed starts stay instant, and browsers are gated by their own
title/calendar rules, so they never wait here.

#### Browsers verified via Accessibility; unreadable controls abstain
`MeetingDetector.browsers`: Browsers whose supported meeting documents can be verified through
Accessibility. Unsupported or unreadable call controls abstain.

#### Document hosts must prove an in-call document before recording or tapping
`MeetingDetector.documentCallHosts`: Browsers and trusted desktop web clients that must prove an in-call
document before they can start recording or select a system audio tap.

#### Calendar-backed meetings get 180 s extra stop grace
`MeetingDetector.calendarBackedGrace`: Extra grace before stopping while a calendar-backed meeting is still in
its scheduled window — brief audio drops mid-meeting shouldn't end it.

#### Keep recording 120 s through brief AX failures, separate from audio debounce
`MeetingDetector.browserObservationGrace`: Accessibility can briefly fail while Chrome rebuilds its WebArea or
another bounded reader is using the same tree. Keep the recording alive
through that uncertainty. This is separate from the user's short audio
debounce because it protects the lifecycle signal itself.

#### Always-open audio bridges pauses 45 s; about a minute with default debounce
`MeetingDetector.alwaysOpenAudioContinuationGrace`: Teams keeps `modulehost` open while idle, so it can bridge a pause only
while backed by recent audio from a process whose signal can disappear.
With the default 15-second stop debounce, the detector remains tolerant
for about one minute after the last reliable sample, then ends normally.

#### Calendar settings are synced from AppSettings by AppState
`MeetingDetector.calendar`: Calendar-assisted detection, synced from `AppSettings` by `AppState`.

#### Matched event drives extended stop grace and recording metadata
`MeetingDetector.activeCalendarEvent`: The calendar event matched when the current session started — drives the
extended stop grace and is carried into the recording's metadata.

#### Track first and last audio seen so conversational gaps don't restart confirmation
`MeetingDetector.startConfirmation`: The start candidate still waiting out
`nativeAudioMinimumConfirmationDuration`: when its audio was first seen,
and when it was last seen — the second lets a normal conversational gap
(the remote side listening rather than talking) survive without
restarting the window. See `nativeAudioConfirmationGapTolerance`.

#### Log start state once per change; diagnostics only
`MeetingDetector.lastLoggedStartState`: Last logged start-decision state, so the safety poll does not
repeat the same line forever. Diagnostics only.

#### Poll start time is diagnostics only
`MeetingDetector.browserPollStartedAt`: Diagnostics only. See `noteBrowserPollStillRunning`.

#### Other-room calls read only while the bound call cannot be verified
`MeetingDetector.otherRoomSnapshots`: Calls in rooms other than the bound one, read only while the bound
call cannot be verified. See `handOffIfAnotherRoomIsInCall`.

#### Manual recording joins only a proven session
`MeetingDetector.verifiesActiveCall`: Whether the active session's call is still proven: always for a native
app session, and for a browser call until its observation is lost. A
manual recording joins only a proven session.

#### Add device-change listener once; re-adding multiplies Core Audio callbacks
`MeetingDetector.deviceChangeListener`: Added once — re-adding on every re-arm multiplies Core Audio
callbacks (each mic open/close then fans out into a tick storm).

#### Share a 0.35 s process snapshot because Core Audio enumeration is expensive
`MeetingDetector.processSnapshot`: Core Audio process enumeration is comparatively expensive and several
meeting subsystems ask for the same answer in one detector/poller turn.
Keep a very short-lived snapshot so detection, helper handoff, and media
pausing share one system query without making process state feel stale.

#### Two second safety poll because browser call state has no notification
`MeetingDetector.start`: Safety-net poll (browser call state has no change notification).

#### Instant signals: mic state, default device change, app launch and quit
`MeetingDetector.start`: Instant signals: mic state, default-device change, app launch/quit.

#### A call starting or ending forces every browser window to be read again
`MeetingDetector.armMicListener`: A call starting or ending reads every browser window again.

#### Only stop tears down the device-change listener; re-arm keeps it
`MeetingDetector.disarmAll`: Full teardown including the default-device listener; only called
from `stop()`. `armMicListener()` calls `disarmMicListener()` (not
this) to keep the device-change listener installed across re-arms.

#### Coalesce tick bursts while cross-process AX runs
`MeetingDetector.tick`: Coalesce mic/device/timer bursts while cross-process AX is running.

#### Inspect idle native chat only when its audio family is active or bound
`MeetingDetector.tick`: Native chat stays open idle. Only inspect it when its audio
family is active, or while following a previously bound call.

#### Once bound, unrelated browsers can't delay the call's evidence
`MeetingDetector.tick`: Once bound, unrelated browsers cannot delay the call's evidence
or make a valid observation expire before it reaches the detector.

#### Unproven bound call must not hide a verified call in another room
`MeetingDetector.tick`: A bound call that stopped proving itself must not hide a verified
call in another room, so these reads look past the binding.

#### Slow browser observation is treated as uncertainty, not call evidence
`MeetingDetector.tick`: A slow/unresponsive browser is uncertainty, never fresh call evidence.

#### Log stalled browser poll; 2026-11-17 task pool stall ran recording all night
`MeetingDetector.noteBrowserPollStillRunning`: Every tick waits for the browser observation in flight, so one that
never finishes stops the detector without a word. On 2026-11-17 no
observation of a Meet call came back after 18:51, when the app's Swift
task pool appears to have stalled; the call's end went unseen and the
recording ran all night. This line dates such a stall. It changes no
decision: the recording's own silence watch ends that recording.

#### Calendar handoff reads only the differing room; links can carry query parameters
`MeetingDetector.otherRoom`: The calendar event's room when it differs from the bound one, so a
calendar-backed handoff reads only that room. Nil reads any single
verified call. Calendar links can carry query parameters.

#### Start and continuation use the app's own audio, not the global mic flag
`MeetingDetector.applyTick`: Both start and continuation hinge on the selected app's OWN audio
(input or output), not the global mic flag. A global mic check can
belong to Dictation/QuickTime/another meeting app while a known meeting
app is merely idle in the background.

#### Silence inside a confirmation window gets grace before reading as ended
`MeetingDetector.applyTick`: No fresh output audio this instant. `detectRunningMeetingApp`
requires it, so this branch also covers the remote side simply
listening rather than talking — the app itself may still be mid-call.
A candidate already inside its confirmation window gets a grace
period before that silence is read as the call having ended.

#### Native audio monitor shares lifecycle identity so its own end event stops it
`MeetingDetector.acceptNativeAudioStart`: The complementary native audio monitor uses the same lifecycle identity
as normal detection, so its recording can be stopped by its own end event.

#### Called only with fresh output audio; tick decides whether a gap keeps the window
`MeetingDetector.startConfirmed`: Tracks how long the start candidate's audio has been continuously
present and answers whether it may start a recording yet. Candidates
that need no confirmation answer true on their first tick.
Called only when `app` has fresh output audio this tick. Advances the
window's evidence clock; `tick()` separately decides whether a gap
since the last call may still keep this same window alive.

#### Schedule a recheck so confirmation fires at the minimum duration, not next poll
`MeetingDetector.startConfirmed`: Ticks are event-driven plus a slow safety poll, so a real meeting
would otherwise wait for the next poll boundary instead of starting
the moment the minimum duration elapses.

#### Handoff lease only for the fresh-audio candidate within its gap
`MeetingDetector.keepsActiveSessionForPendingHandoff`: Keep one recording alive while a specific running meeting app earns its
sustained-audio handoff confirmation. The lease exists only for the
candidate that supplied fresh meeting-app audio and only through its
bounded conversational gap; unrelated system audio cannot extend it.

#### Browser replacements use browserStart; don't reset it without native window
`MeetingDetector.keepsActiveSessionForPendingHandoff`: Browser replacements use `browserStart`; do not reset that separate
gate merely because there is no native-audio confirmation window.

#### Replace the start recheck so a one-frame candidate can't hold the old recording
`MeetingDetector.keepsActiveSessionForPendingHandoff`: Replace the ordinary start recheck with the earlier handoff boundary.
Otherwise a callback queued for the 12-second confirmation point can
let a one-frame candidate hold the old recording past its 6-second
audio-gap lease.

#### Log start-decision changes so a missed start has evidence
`MeetingDetector.logStartState`: Logs a start-decision state once per change. The detector otherwise
says nothing at all unless it starts a recording, so "it did not fire"
has no evidence behind it.

#### Clearing after a successful start must not log as lost audio
`MeetingDetector.clearPendingStart`: `loggingLoss` is false when the candidate is being cleared because it
just started a meeting — that clears the same state but is a success,
not a loss, and must not log as one.

#### Calendar grace applies to native apps only, never to browser calls
`MeetingDetector.scheduleStopIfNeeded`: Native app audio gaps may use calendar grace. A browser call uses
only its bound document state and never receives that extension.

#### Browser-wide audio isn't call evidence; last observation is diagnostic, never a cutoff
`MeetingDetector.tickBrowser`: A browser-wide audio stream is never evidence that the bound call is
still running. A verified window that still holds the call keeps it,
even when its call controls cannot be read. Otherwise a missing
snapshot remains uncertainty until positive end evidence or user Stop.
The last verified observation is diagnostic, never a content cutoff.

#### Pending end stays only while an uncertainty window is open
`MeetingDetector.tickBrowser`: Only an open uncertainty window may leave a pending end in place.

#### Back-to-back events in one room split; events in another room don't
`MeetingDetector.splitAtCalendarHandoff`: Back-to-back events can share one room. While the bound call still
holds its window, the next event on that room's link starts a new
meeting, as it does for a native app. An event in another room does
not: the current call is running over.

#### Verified call in another room starts a new meeting; old evidence stays diagnostic
`MeetingDetector.handOffIfAnotherRoomIsInCall`: A bound call that stopped proving itself cannot hide a verified call in
another room: the user has moved on, and the new room is a new meeting
with the same start rules as any other. The old room's last evidence
stays diagnostic, so nothing is trimmed from its recording.

#### Audio-monitor events must pass the same sustained call-state gate
`MeetingDetector.checkNow`: Audio-monitor events must pass the same sustained call-state gate.

#### Split from NSRunningApplication so candidate priority is testable
`MeetingDetector.meetingAppCandidates`: Which running bundles count as native meeting apps, in priority order.
Split out from `NSRunningApplication` so the choice is testable.

#### Lookup has no audio requirement so silent candidates survive bridged gaps
`MeetingDetector.nativeApp`: A specific native app by bundle id, with no audio requirement at all —
used to check whether a confirmation candidate is still open during a
bridged gap, where the point is exactly that it may be silent right now.

#### Browser call without calendar requirement; capture is a process tap
`MeetingDetector.visibleBrowserMeeting`: A verified supported browser call without calendar requirements.
Audio capture remains a process tap; call evidence supplies lifecycle.

#### Browser meeting needs verified in-call document; unrelated output never starts one
`MeetingDetector.browserMeeting`: A browser with a verified in-call document, optionally restricted to
the calendar event URL. Unrelated browser output never starts a call.

#### Helpers outside host namespace (Feishu, DingTalk, Webex) map to their hosts
`MeetingDetector.foreignHelperHosts`: Helper processes named outside their host's bundle namespace, keyed by
the lowercased helper identifier (its own `.`-suffixed variants match
too) and mapped to the lowercased host. Feishu's Electron helpers keep
ByteDance's identifier while the app itself is `com.electron.lark`, and
DingTalk's helper is `com.alibaba.DingTalk-Helper` beside
`com.alibaba.DingTalkMac`. Webex's media engine (`WebexHelper`, which
renders the remote participants' audio) registers with Core Audio as
`Cisco-Systems.SparkHelper`, with no dot after `Spark`, so it is not in
the `Cisco-Systems.Spark.` namespace of its host `Cisco-Systems.Spark`.

#### Audio process family includes Zoom CptHost and Chromium helper bundles
`MeetingDetector.audioBundleID`: Whether an audio process belongs to the detected meeting application's
process family. Zoom routes call audio through `us.zoom.CptHost`, while
Chromium-family browsers use `.helper` bundle identifiers.

#### Match any bundle in host namespace because Teams uses helper and modulehost
`MeetingDetector.audioBundleID`: Any bundle inside the host's own namespace is that app's audio.
Teams alone emits call audio from `<host>.helper` (WebView) *and*
`<host>.modulehost`, so matching only `.helper` misses the process
that is usually the one running. This mirrors the `us.zoom.xos.`
prefix rule above rather than enumerating every suffix Microsoft ships.

#### Detection supplies signal-carrying processes; capture adds fallbacks separately
`MeetingDetector.rankedOutputAudioProcess`: Ranks an already-vetted set of output processes inside an app family.
Detection supplies only processes that carry meeting signal; capture
adds its broader open-stream and silent-process fallbacks separately.

#### Prefer browser helpers because the host tap may deliver silence
`MeetingDetector.rankedOutputAudioProcess`: Chrome/Edge/Safari often emit meeting audio from helper processes,
while the browser host can still expose a tap that only delivers
silence. Prefer a helper unless the detected PID is already one.

#### Honour Electron helper processes or the tap is skipped and meeting is mic-only
`MeetingDetector.rankedOutputAudioProcess`: Electron meeting apps (Teams, Slack, Webex) route call audio through
helper processes just as Chromium browsers do. `audioBundleID` already
models that `<host>.helper` relationship for every host, so honour it
here as a fallback — without it `hasOutputAudio` stays false, the
detector never surfaces the app, and the process tap is skipped
entirely, leaving the meeting recorded mic-only. The host keeps
precedence so apps whose main process emits audio are unaffected.

#### Detection-only ranking; capture must use bestCaptureAudioProcess
`MeetingDetector.bestOutputAudioProcess`: Best output process that is evidence of a live meeting. Detection-only:
capture must use ``bestCaptureAudioProcess(for:in:)`` so bundles with
always-open streams remain tappable.

#### Keep aligned with captureTargetProcess so detection ranking doesn't leak into capture
`MeetingDetector.bestCaptureAudioProcess`: Canonical capture selection, including always-open streams plus the
remembered and stable silent-process fallbacks. Keeping this entry point
aligned with ``captureTargetProcess`` prevents detection-only ranking
from leaking back into capture callers.

#### Always-open stream is ambiguous context, usable only under a backed lease
`MeetingDetector.bestAlwaysOpenAudioProcess`: Best permanently-open stream inside this app's process family. This is
ambiguous context, never standalone meeting evidence: the active
detector may use it only while ``MeetingContinuationLease`` is backed by
recent reliable audio.

#### Capture needs a process that can emit; host PID fails for Teams; excluded is a set
`MeetingDetector.captureTargetProcess`: The process to attach the capture tap to.

Detection asks whether the app is producing output *right now*; capture
only needs a process that *can* produce it — a tap on a momentarily
silent process simply records nothing until audio starts. Falling back
to the host PID is not an option: Teams' main process owns no Core Audio
object at all, so `AudioHardwarePropertyTranslatePIDToProcessObject`
fails and the tap is refused with `processNotFound` whenever the meeting
happens to be quiet at the moment recording starts.

`excluding` is a set rather than one PID because a recording can rule out
more than one process: a tap that delivered nothing stays ruled out for
the rest of the session, and with several siblings alive the watchdog
otherwise hands back a process it already found empty.

#### Emitting process is the answer and is remembered as audio carrier
`MeetingDetector.captureTargetProcess`: A process emitting right now is the answer, and worth remembering:
it is the only moment we learn which sibling of this app actually
carries call audio.

#### Always-open stream beats a streamless helper for capture
`MeetingDetector.captureTargetProcess`: An always-open stream is intentionally excluded from meeting
detection, but it is preferable to a streamless helper for capture:
Core Audio will deliver silent buffers now and call audio later.

#### Core Audio list order is undefined, so prefer last-emitting process
`MeetingDetector.captureTargetProcess`: Nothing is emitting. Core Audio specifies no order for the process
list, so picking the first sibling would tap a different one from
one call to the next — and with several Teams or browser helpers
alive, usually one that never carries call audio. Prefer the process
this app was last seen emitting from.

#### Prefer siblings over host and lowest PID for stable retries
`MeetingDetector.captureTargetProcess`: Still nothing known: siblings before the host, for the same reason
the browser branch prefers helpers — the host is the process least
likely to own audio, and for Teams it owns no Core Audio object at
all. Lowest PID within each group so the choice is at least stable
across the retries the watchdog makes.

#### Remember last-emitting PID per bundle between a quiet start and watchdog
`MeetingDetector.lastEmittingCaptureTargets`: The PID each app was last seen emitting from. Small and per-bundle: it
only has to survive between a quiet start and the watchdog's next look.

#### Reset capture memory for tests so cases don't leak
`MeetingDetector.resetCaptureTargetMemory`: Clears what capture learned about which sibling carries audio. For
tests, so one case cannot leak its choice into the next.

#### Manual capture doesn't require output; browsers need one provable in-call document
`MeetingDetector.captureCandidateApp`: A running meeting app to capture from when nothing was detected.
Deliberately does *not* require current output: a recording started by
hand routinely begins before the remote side says anything, and a tap on
a silent process records nothing until audio arrives rather than
failing. A browser is eligible only when its Accessibility tree proves
one unambiguous in-call meeting document, so a manual recording does not
silently widen its capture scope to arbitrary browser media.

#### Prefer emitting native apps, then verified browser call over idle apps
`MeetingDetector.captureCandidateApp`: Prefer native apps that are actually emitting, then a verified
browser call. An idle Teams/Zoom process must not shadow the Chrome
call the user is recording just because it happens to be open.

#### Idle native target only for recordings already bound to it
`MeetingDetector.captureCandidateApp`: An idle native target is useful only when the recording is already
bound to it. An unrelated idle Zoom/Teams window must not seize an
unbound manual recording while its intended browser call is hidden.

#### Teams modulehost idle capture tapped unbound; any verified source may replace it
`MeetingDetector.alwaysOpenCaptureCandidate`: A meeting app whose process family holds an always-open output stream,
for an unbound recording to hold while nothing verified is available.

New Teams plays call audio only through `modulehost`, which is open
whether or not a call is running (#179). ``captureCandidateApp`` can
never return it: emitting evidence skips always-open streams, and an
idle app needs a binding. Because an idle app looks the same, the caller
taps this without binding the recording, and any verified source may
replace it until the tap has carried the call itself. When several
apps qualify, only a frontmost one is chosen.

#### Start question reads only streams that are call evidence
`MeetingDetector.hasAudio`: The meeting app's own audio activity — output, or (native apps only)
input. Reflects the app rather than our recorder's hold on the default
input device.

This is the *start* question, so it reads only streams that are evidence
of a call. Deciding whether one is still running is
``hasContinuingAudio(for:now:)``.

#### Reliable audio renews the lease; always-open streams bridge only while recent
`MeetingDetector.hasContinuingAudio`: Reliable app audio renews the active session's lease. A permanently-open
stream may bridge a normal speech pause while that lease is recent, but
once the lease expires it cannot prevent the ordinary stop debounce from
ending a Teams call whose app remains open.

#### Web calls use document not mic; native input flag is the app's own
`MeetingDetector.hasInputAudio`: A web-based call uses its verified document, never mic activity.
For other native apps the input flag is the app's own microphone
use — never our recorder's.

### `LokalBot/Services/Recording/RecordingController.swift`

#### Claim the retry before reattaching so failed setup cannot retry forever
`SystemAudioSamePIDRetryBudget.beginRetry`: Claims one retry before the reattach is attempted, so failed Core Audio
setup cannot bypass the bound and retry forever on every watchdog tick.

#### Source choice is static so replay can check it without audio device
`RecordingSystemAudioSource`: Where system audio comes from when no detected app started the recording.
Static, so a replayed capture environment can check the choice without an
audio device.

#### Verified means call evidence; attaching binds the recording to the app
`RecordingSystemAudioSource.verified`: Evidence of the call: an emitting meeting app, a verified browser call,
or the idle app the recording is already bound to. Attaching binds.

#### Held tap covers always-open streams without binding the recording
`RecordingSystemAudioSource.held`: An always-open stream, which an idle app holds too. Tapped without
binding the recording; see `MeetingDetector.alwaysOpenCaptureCandidate`.

#### Held tap needs call-grade audible audio before binding to its app
`RecordingSystemAudioSource.bindingAudibleDuration`: Audible audio a held tap must carry before the recording binds to its
app. The detector sets the same bar before a communication app's sound
counts as a call rather than a notification or a launch blip.

#### Ledger remembers proven and empty taps to stop watchdog tap swapping churn
`SystemAudioTapLedger`: What the watchdog has learned about the processes it tapped during one
recording. Two facts, both earned rather than assumed.

A tap that has written audible audio *of its own* is pointed at the process
the call comes out of, and is worth being patient with. A tap that has not
delivered one buffer since it attached is pointed at a process with no open
output stream; no amount of waiting turns that into audio, and nothing
should send the tap back there.

Excluding only the tap in hand is not enough, because the exclusion lasts
one tick. Measured on a real call (log, 2026-08-25 10:36–10:57) the watchdog
alternated between two Teams siblings every 10–15 s for 21 minutes: an
ordinary pause moved the tap off the process carrying audio onto a helper
that delivered nothing, the empty helper moved it straight back, and the
audible total grew 28 s in those 21 minutes because each swap discards the
audio in flight.

#### Retired PIDs are taps that delivered no buffer while attached
`SystemAudioTapLedger.retiredPIDs`: Taps that delivered nothing at all while attached.

#### Only audible growth past attach mark counts toward this tap's proof
`SystemAudioTapLedger.audibleAtAttach`: The session's audible total when the current tap attached. `CaptureHealth`
counts the whole file, so only growth past this mark belongs to this
attachment — without the mark, a tap inherits its predecessor's proof.

#### Teams reuses processes, so re-attachment clears the retired flag
`SystemAudioTapLedger.attached`: Teams reuses its processes; a fresh attachment gets a fresh hearing.

#### Retiring a silent tap also revokes its earlier proven standing
`SystemAudioTapLedger.retire`: Retires a tap that delivered nothing. A PID that had proved itself on an
earlier attachment loses that standing: whatever it carried then, it is
carrying nothing now.

#### Proven tap keeps long grace unless another process actively emits
`SystemAudioTapLedger.silenceGrace`: How long this tap may stay quiet before the watchdog goes looking. A
proven tap keeps the long grace through ordinary silence, but a different
process that is actively emitting is direct evidence that the call moved
and restores the ordinary recovery threshold.

#### Transitions return Bool so UI updates fire once and stay testable
`SilentSystemAudioWarningState`: Tracks whether the silent-system-audio advisory is currently presented.
Returning a Bool from each transition lets the controller emit UI updates
exactly once while keeping the state machine independently testable.

#### Health reflects recent writes per source; digital silence is not audio (#373)
`RecordingMemoryHealthSnapshot.recording`: Presentation follows recent writes from each source independently.
A source that produced sound earlier can subsequently become silent;
historical audible data is not evidence that it is audible now.
A microphone that writes only digital silence is "Receiving silence",
not "Receiving audio": a quiet speaker still has a noise floor (#373).

#### Controller owns recording lifecycle; AppState republishes and folds finished meetings
`RecordingController`: Owns the meeting-recording lifecycle: the two recorders (mic + system tap),
the start/stop state machine, the capture-health watchdog, the menu-bar
timer tick, and capture recovery. `AppState` keeps a reference,
republishes changes, and folds finished meetings into the library via
`onMeetingFinished`.

#### Live recording is shown at top of library while running
`RecordingController.currentMeeting`: The live recording (shown at the top of the library while running).

#### Only this detector session's lifecycle events own the recording
`RecordingController.detectorSessionID`: Only lifecycle events from this detector session own the recording.
A recording the user started joins the session of the call it records.

#### True for explicit starts; never changes on stop; matcher treats kinds alike
`RecordingController.startedByUser`: True for explicit starts (menu bar, Record now, notifications). It no
longer changes when a recording stops: `MeetingMatcher.action` takes
it and treats both kinds alike, neither is stopped by an uncertain end.

#### Drives elapsed; bumped each second by recordingTick
`RecordingController.now`: Drives `elapsed`; bumped each second by `recordingTick`.

#### True only around the synchronous stop/start of a calendar split
`RecordingController.isSplittingForCalendarHandoff`: True only around the synchronous stop/start boundary of a calendar split.

#### Message is exposed so presenter withdraws exactly it, never a newer error
`RecordingController.silentSystemAudioMessage`: Surfaces user-facing problems (feeds `AppState.lastError`).
Exposed so the presenter can withdraw exactly this message and never a
newer, unrelated one.

#### nil withdraws the silent-audio message if it is still showing
`RecordingController.onError`: `nil` withdraws ``silentSystemAudioMessage`` if it is still showing.

#### Finished meeting leaves controller here; app inserts it into library
`RecordingController.onMeetingFinished`: A finished meeting leaves the controller here; the app inserts it into
the library list.

#### Notifications only on real interactive launch, not headless or UI tests
`RecordingController.isInteractive`: Gates notifications to the real interactive launch
(not headless / UI tests).

#### One sound meter per recording, fed by both writers
`RecordingController.soundMeter`: One per recording, fed by both writers. See `RecordingSilenceWatch`.

#### Held target does not bind recording; any verified source may replace it
`RecordingController.SystemAudioTarget.isHeld`: Held without binding the recording; any verified source may still
replace it. See `RecordingSystemAudioSource.held`.

#### No tap or only a held tap means a verified source should attach
`RecordingController.awaitsVerifiedSystemAudio`: No tap yet, or only a held one: a verified source should still attach.

#### Keep retrying microphone every 30 s after fast retries stop
`RecordingController.degradedMicRetryInterval`: The microphone's own fast retries stop after about ten seconds. Keep
trying at this pace for the rest of the recording, as system audio
does, so an input that settles later still records the user's voice.

#### Proven tap waits 90 s, a judgement tolerating pauses and screen sharing
`RecordingController.provenSystemAudioSilentGrace`: The same wait, for a tap that has already written audible audio of its
own. Eight seconds is a pause between two sentences, so on a proven tap
that threshold measures the conversation rather than the capture.

Ninety seconds is a judgement, not a measurement: comfortably longer
than a meeting goes quiet while someone reads or shares a screen, and
short enough to still find the audio inside a couple of minutes if it
really did move. `retiredPIDs` is what stops the churn; this only keeps
a working tap from being disturbed for nothing. The microphone keeps
recording throughout either way.

#### Remember stopped calendar event so detection cannot instantly restart it
`RecordingController.lastCalendarEventID`: Calendar event id + stop time of the last calendar-backed recording the
user stopped, so detection cannot immediately restart a meeting they
ended. A call that ended on its own clears it; brief drops and helper
churn are absorbed by the detector's stop debounce and handoff. See
`MeetingMatcher.shouldSuppressRepeat`.

#### One-second tick keeps menu bar timer live with no window; nil when idle
`RecordingController.recordingTick`: Ticks once a second while recording so the menu bar timer (and popover)
stay live even with no window open. Nil when idle.

#### Persistent retry attaches system tap once browser meeting document is visible
`RecordingController.systemAudioRecovery`: Manual capture can begin during a transient Accessibility gap. Keep a
persistent retry alive until the browser's verified meeting document is
visible, then attach the system tap to the same meeting folder.

#### Only automatic starts are suppressed; explicit user starts always honored
`RecordingController.shouldSuppressCalendarRepeat`: Only automatic detector starts are protected from immediately
re-recording the same calendar event. Explicit user actions such as
Record now must always honor the user's request.

#### Automatic retries must not re-record an ended scheduled event
`RecordingController.start`: Automatic detector retries must not immediately re-record the same
scheduled event after one ended; explicit user starts bypass this.

#### Refuse start on nearly full volume rather than die mid-meeting
`RecordingController.start`: Refuse up front on a nearly-full volume: a recording that dies
mid-meeting from ENOSPC loses the meeting; a clear refusal doesn't.

#### Match meeting start once, then monotonic timestamps keep one audio origin
`RecordingController.start`: Match meeting.startedAt once, then use monotonic capture
timestamps. The same origin survives late system attachment
and every microphone/process-tap recovery.

#### Meeting intents fall back to verified app or held always-open stream (#179)
`RecordingController.start`: Meeting-intent callers may fall back to a running meeting app
before it emits audio, giving the watchdog a target to repair.
The fallback verifies a browser's in-call document first, so
manual recovery can capture Chrome without widening scope to
an arbitrary browser tab. Mic-only callers never evaluate it.
With nothing verified, an unbound recording holds an
always-open stream such as Teams' modulehost (#179).

#### stopNotice replaces the saved-recording notification title
`RecordingController.stop`: `stopNotice` replaces the title of the saved-recording notification.

#### Withdraw silent-audio advisory before watchdog stops, or it stays stale
`RecordingController.stop`: Before the watchdog goes away: it is the only thing that notices
recovery, so a meeting ending between the arrival of audio and the
next tick would leave the advisory standing over a recording that
does have a system track.

#### Discard preview tee only once finalized AAC is known to decode
`RecordingController.stop`: Only discard a preview tee after its finalized AAC track is known to
decode. If finalization failed, the CAF may be the sole recovery copy.

#### Store longest track as recorded duration; wall clock can exceed audio
`RecordingController.stop`: The wall-clock span can outlast the captured audio (e.g. a device
disruption truncates the tracks while the session stays live), so
store the actual playable length — the longest track — for the UI.

#### Call ending on its own lets rejoining the same event record again
`RecordingController.stop`: The call ended on its own; rejoining the same event records again.

#### Ownerless recording joins the verified call it captures so call end stops it
`RecordingController.joinDetectorSession`: A recording without a detector owner joins the verified call it is
capturing, so that call's end can stop it. Returns whether it joined.

#### Detector verifying same call in a replacement host retargets the tap
`RecordingController.considerDetectedSource`: The detector has just verified the same call in a replacement host.

#### Compare room URLs because calendar links carry query parameters
`RecordingController.recordsSameCall`: Calendar links can carry query parameters such as ?authuser=0.

#### Finalization is separate from device shutdown so it is testable without capture
`RecordingController.finalize`: Finalization is separate from device shutdown so persistence failures
and deferred work can be verified without opening a capture device.

#### Pipeline parks jobs with missing models; notification says so up front
`RecordingController.persistFinalization`: The pipeline parks automatic jobs whose models are missing instead
of ambush-downloading them; the notification says so up front.

#### Trimmed recordings report the content's length in the notification
`RecordingController.persistFinalization`: A recording trimmed to its content reports the content's length.

#### Reload meeting before each retry; retained value may be stale
`RecordingController.currentMetadata`: Reload the exact meeting before every retry. The retained value contains
stop-time facts, but its title, boundaries, and relationship metadata may
be older than edits made after the first persistence attempt failed.

#### Durable user-edited fields win; finalization fills only capture facts
`RecordingController.mergingFinalization`: Latest durable metadata wins for user-editable fields. Finalization fills
only capture facts that an older in-progress `meta.json` cannot know yet.

#### Tap start and target update are atomic; held tap stays unbound until verified
`RecordingController.startSystemAudioCapture`: Starts the system tap and records the target in the same place for both
the normal start path and a late manual attachment. Keeping this update
atomic prevents metadata from claiming a system track when Core Audio
never accepted the tap.

A `held` tap leaves the recording unbound. A verified source replaces a
held tap on the same writer, so what the held tap wrote stays in place;
one from the held tap's own app binds it where it is.

#### Verified held app binds without moving tap; Teams modulehost carries call (#179)
`RecordingController.startSystemAudioCapture`: The held tap's own app was verified: bind without moving the
tap. Teams helpers emit short bursts during a call, which count
as verification, while the call itself comes out of the held
modulehost (#179). If the held process stays silent while a
sibling emits, the watchdog still moves the tap.

#### Tap failure degrades to mic-only; late retry stays active
`RecordingController.startSystemAudioCapture`: Degrade gracefully: the microphone remains authoritative. A
meeting that began during an AX gap keeps its late retry active;
a detected start still receives the existing actionable error.

#### Retry after transient Accessibility gap instead of freezing mic-only meeting
`RecordingController.scheduleLateSystemAudioCapture`: Accessibility snapshots are occasionally unavailable exactly when the
user presses Record. Do not freeze that first miss into a mic-only
meeting: look again for a verified browser call while the recording is
already active, with bounded backoff and no broader browser tabs.
Meanwhile an unbound recording holds an always-open stream when one
appears, and keeps looking until the held tap binds.

#### Verified source replaces none or held tap; held attaches only with no tap
`RecordingController.attachLateSystemAudio`: Attaches a verified source in place of no tap or a held one. A held
source attaches only when there is no tap at all.

#### Held tap that carried call binds recording so other apps cannot claim it
`RecordingController.bindHeldSystemAudio`: A held tap that has carried the call binds the recording to its app,
so later sounds from other apps can no longer claim it.

#### Cancelled start can race first buffers; delete only empty folders
`RecordingController.preserveAudioFromInterruptedStart`: Startup cancellation/failure can race the first successful microphone
buffers. Remove empty folders only; retain every playable start attempt.

#### Never delete a start with an unreadable recovery journal or audio bytes
`RecordingController.preserveAudioFromInterruptedStart`: A damaged file may still have salvageable bytes. Only delete a
start with no audio payload, never an unreadable recovery journal.

#### Silence stop runs on main run loop, immune to stalled Swift task pool
`RecordingController.stopIfNobodyIsTalking`: Ends a recording that has gone `RecordingSilenceWatch.quietLimit`
without anyone talking, its content cut where the talking stopped. It
runs on the main run loop with the timer and reads the meter under a
lock, never on a Swift task: on 2026-11-17 the detector and the
capture-health watchdog both went quiet when the task pool appears to
have stalled, and this is what still has to work then.

#### Lifecycle boundaries need authoritative synchronous health; sampling uses async path
`RecordingController.updateCaptureWarnings`: Lifecycle boundaries need authoritative writes, especially the final
report at Stop. Periodic sampling uses the asynchronous path.

#### MicRecorder owns device recovery; watchdog must not race it with rebuild
`RecordingController.checkMicrophoneCapture`: MicRecorder owns the bounded device-reconfiguration recovery.
Avoid racing it with a second graph rebuild from this watchdog.

#### Skip enumerating process siblings during sub-threshold fluctuations
`RecordingController.checkSystemAudioCapture`: Do not enumerate process siblings during sub-threshold fluctuations.

#### Exclude current and retired taps so alternative is a real alternative
`RecordingController.checkSystemAudioCapture`: A proven tap ordinarily stays put for the long grace, but it should
not wait while Core Audio already shows a different process in the
same app family actively emitting. Excluding both the current tap and
session-retired taps makes this a real alternative, not another
selection of the process whose file is currently silent.

#### Silence is ambiguous; proven tap sits out pauses unless sibling emits
`RecordingController.checkSystemAudioCapture`: Silence is the question this watchdog cannot answer on its own: a
meeting between two sentences and a tap on the wrong process look
identical from here. A proven tap sits out an ordinary pause unless a
currently-emitting sibling answers the question directly.

#### Flowing zero samples are valid silence; only emitting sibling justifies switching
`RecordingController.checkSystemAudioCapture`: Flowing zero samples are valid silence. Only an emitting sibling
can justify switching a healthy silent tap.

#### Bufferless tap is retired, and all retired taps are skipped
`RecordingController.checkSystemAudioCapture`: A tap that has not delivered a single buffer since it attached is not
quiet: it is pointed at a process with no open output stream. Retire
it — and look past everything retired earlier in this recording, not
just the tap in hand, or the watchdog keeps rediscovering the same
empty sibling and swapping back onto it.

#### Same-PID rebuild still useful when it is the only process left
`RecordingController.checkSystemAudioCapture`: Rebuilding a tap on the same PID is still useful when that is the
only process left: the process may have opened its stream after the
original tap was created. Same-PID retries remain budgeted below.

#### Same-PID retry only if never delivered audio; else need different process
`RecordingController.checkSystemAudioCapture`: If the tap has never delivered audio, retry even on the same PID.
Once samples exist, reattach only when Core Audio reports a different
active process for the same meeting app/browser family.

#### Helpers may move within live host; new browser host must be verified first
`RecordingController.mayRecoverSource`: Helpers within a live authorized host may move. A new browser host must
first be verified against the same room, then offered by the detector.

#### Emitting sibling is strong evidence; never returns always-open fallback
`RecordingController.currentEmittingSystemAudioCandidate`: A currently-emitting sibling is stronger recovery evidence than a quiet
capture target. Unlike the broader capture lookup, this never returns an
always-open or merely-present fallback.

#### Helper exits are routine; short window to reattach, detector owns meeting end
`RecordingController.handleCapturedProcessTermination`: Helper processes routinely exit during a live browser/Zoom meeting.
Give Core Audio a short window to publish the replacement and reattach
the existing writer; the detector, not helper churn, owns whole-meeting
termination. Microphone recording continues throughout.

#### Withdraw silent advisory once system track audible; rule kept pure for tests
`RecordingController.shouldWithdrawSilentSystemAudioWarning`: Takes back the silent-capture advisory once a system track has in fact
been written. Without it the banner latches for the whole recording and
keeps claiming the capture is silent — indistinguishable from the
genuine "tap attached to a process that never emits" case the warning
exists for. Only a capture that stayed silent keeps its warning.
The rule itself, kept pure so it is testable without a live capture.

#### Successful reattach withdraws advisory; fresh warning after grace if still silent
`RecordingController.withdrawSilentSystemAudioWarning`: A successful reattach starts a new capture attempt. Withdraw the
advisory for the failed target now; if the replacement is also silent,
the watchdog can present a fresh warning after its grace period.

### `LokalBot/Services/Recording/RecordingHealthSampler.swift`

#### One outstanding read pair; views never touch audio writer queues
`RecordingHealthSampler`: One outstanding pair of reads even when a writer stalls or recording changes.
Views consume the last sample and never touch an audio writer queue.

#### Keep slot occupied until queued reads finish; cancellation cannot remove them
`RecordingHealthSampler.invalidate`: Keep the slot occupied until the queued reads finish. Cancellation
cannot remove a read already waiting behind filesystem I/O.

### `LokalBot/Services/Recording/RecordingNotifier.swift`

#### Notification authorization requested lazily on first recording start
`RecordingNotifier`: Local notifications that announce recording start/stop, so the user knows a
meeting is being captured without keeping the window open. This is the
"push" half of the menu-bar-only experience; the always-visible menu bar
timer is the "pull" half.

Authorization is requested lazily the first time a recording actually
starts — a new user is never hit with a notification prompt before they've
done anything, and if they decline, the menu bar timer still covers the
"is it recording?" question.

#### Delegate installed once at launch, interactive path only
`RecordingNotifier.bootstrap`: Install the foreground-presentation delegate. Called once at launch from
the interactive (non-headless, non-UI-test) path.

#### Posted only when health check fails; click opens report
`RecordingNotifier.healthCheckFailed`: Posted only when a health check fails; clicking opens the report.

#### Notifications off opens approval window immediately; only the person can answer
`RecordingNotifier.settingsApprovalRequested`: A terminal request waiting for the person. Clicking the notification
opens the approval window; with notifications off, the window opens
right away, because only the person can answer.

#### Prompt action expires so old clicks cannot start unrelated captures
`RecordingNotifier.meetingDetected`: Posts a real, actionable prompt for `.ask` recording mode. The action
expires so clicking an old notification cannot begin capturing an
unrelated meeting hours later.

#### System notifications stay off in every UI test
`RecordingNotifier.post`: System notifications stay off in every UI test, background mode included.

#### Fresh identifier each time so start and stop don't coalesce
`RecordingNotifier.post`: `trigger: nil` delivers immediately. A fresh identifier each time so a
start and a stop don't coalesce into one another.

#### Clean up request added after meeting ended while add suspended
`RecordingNotifier.post`: `add` suspends. A meeting can end while the notification center
is accepting the request, after invalidation already tried to
remove it. Clean up the newly added request on resume as well.

#### Show banner even when LokalBot is the active app
`RecordingNotifier.userNotificationCenter(willPresent)`: Show the banner even when LokalBot happens to be the active app (e.g. the
window is open), instead of silently dropping it.

### `LokalBot/Services/Recording/RecordingSilenceWatch.swift`

#### Per-recording meter read lock-free of writers so stalled pool cannot block
`RecordingSoundMeter`: Adds up how long a recording has carried sound loud enough to be someone
talking. The microphone and meeting-audio writers record into one meter
per recording from their own queues. The main thread reads the total
without waiting on either writer, so a busy encoder or a stalled Swift
task pool cannot hold up the silence check.

#### About -50 dBFS, measured against speech and an unattended microphone
`RecordingSoundMeter.soundRMSThreshold`: About -50 dBFS RMS. Speech at a laptop microphone and remote speech in
a call sit around -35 to -20 dBFS. An unattended MacBook's microphone,
measured overnight on 2026-11-17, stayed between -60 and -100 dBFS and
passed this level for at most half a second in any minute.

#### Called from writer queue for each buffer written to disk
`RecordingSoundMeter.record`: Called from a writer queue for each buffer written to disk.

#### Ends silent recordings from recorder output alone; 2026-11-17 16-hour incident
`RecordingSilenceWatch`: Ends a recording nobody is talking in.

The call detector keeps a recording going until it sees the call end, and
it reads a call whose state it cannot see as still running (see
`BrowserMeetingSession.lifecycleDecision`). On 2026-11-17 a Meet call
ended at 18:52 with its tab left open. The detector got no observation
after 18:51, when the app's Swift task pool appears to have stalled, and
the recording ran until 10:30 the next morning: 16 hours and 6 GB for 21
minutes of conversation. This watch reads only what the recorders wrote, from the
main run loop, so it ends that recording whatever the detector knows. It
also ends a call left open in an empty room and a manual recording
someone forgot.

#### Two seconds of sound per window counts as talking, from measured call
`RecordingSilenceWatch.minimumSound`: Sound within `activityWindow` that counts as talking. A cough, a door
or a notification chime stays below it. During that call every minute
had at least 2 s of microphone sound, with the meeting audio on top;
from a minute after it ended, no minute had more than half a second.

#### Stopped recording ends its content at last heard talking
`RecordingSilenceWatch.lastActivityAt`: When someone was last heard talking. A recording this watch stops ends
its content here.

#### Replaced meter or clock set back restarts counting
`RecordingSilenceWatch.observe`: A replaced meter or a clock set back: start counting again.

#### Keep last sample at or before window start so difference spans window
`RecordingSilenceWatch.observe`: The oldest sample kept is the last one at or before the window's
start, so the difference below spans the whole window.

### `LokalBotTests/Services/Recording/RecordingControllerTests.swift`

#### Closed MacBook lid left input writing digital silence yet showed Receiving audio (#373)
`RecordingControllerTests.testHealthReportsAMicrophoneThatWritesOnlySilence`: \#373: a closed MacBook lid left the default input writing digital
silence for a whole meeting while the strip said "Receiving audio".

#### A stray stop racing a finished meeting must be a no-op
`RecordingControllerTests.testStopWhileIdleIsANoOp`: A stray stop (menu bar action racing a finished meeting) must be a
no-op, not a crash or a phantom meeting.

#### Zero-buffer attachment's PID exclusion must outlive the tick that made it
`SystemAudioTapLedger`: A zero-buffer attachment still takes the current PID out of the running.
`SystemAudioTapLedger` now holds that decision, because the exclusion has
to outlive the tick that made it — see the ledger tests below.

#### Silent capture keeps its advisory; usable track withdraws it, including at stop()
`RecordingController.shouldWithdrawSilentSystemAudioWarning`: The advisory exists for a tap attached to a process that never emits,
so a capture that stayed silent must keep it. Anything that did deliver
a usable track takes it back — including at `stop()`, since the watchdog
tick that would otherwise notice may never come.

#### Reattach withdraws warning but replacement may warn again
`SilentSystemAudioWarningState`: A reattach withdraws the warning for the failed target and leaves the
replacement eligible to warn again if it also stays silent.

#### Genuine silent warning survives stop; next capture start withdraws it
`SilentSystemAudioWarningState`: A genuinely silent capture keeps its advisory after stop, but the next
capture start must withdraw it so an old banner cannot outlive the state
that originally presented it.

#### Whole-file audible total must not give a new tap proven standing
`SystemAudioTapLedger.observe`: `CaptureHealth.audibleDuration` counts the whole file, so a tap that
inherits a healthy total must not inherit the standing that goes with
it — otherwise the first process the watchdog moves to counts as proven
before it has written a sample, and earns the long grace for nothing.

#### Only audio the tap wrote itself transfers proven standing
`SystemAudioTapLedger.observe`: Only audio this tap wrote itself transfers the standing.

#### Eight-second silence is a pause; proven tap stays, unproven moves
`SystemAudioTapLedger.silenceGrace`: Eight seconds of silence is a pause between two sentences. A tap that has
written audible audio is not the reason for it and stays put; one that
has proved nothing is still worth moving that quickly.

#### Long grace yields to a sibling helper actively emitting
`SystemAudioTapLedger.silenceGrace`: The long grace protects a proven tap only while there is no better
evidence. If a different helper is actively emitting, recovery should
use the ordinary threshold and follow the call there.

#### Retired taps persist; 2026-08-25 watchdog flapped between modulehost and empty helper
`SystemAudioTapLedger.retire`: Replays the flap in the log of 2026-08-25 10:36–10:57: modulehost carried
the call, a helper delivered nothing, and the watchdog swapped between
them every 10–15 s because each lookup was free to hand back the empty
one. Excluding only the tap in hand cannot stop that; the exclusion has
to persist.

#### Standing follows evidence both ways; a PID that stops delivering loses it
`SystemAudioTapLedger.retire`: A PID that proved itself earlier and now delivers nothing has stopped
being the answer; standing follows the evidence in both directions.

#### Teams reuses processes, so a fresh attachment gets a fresh hearing
`SystemAudioTapLedger.attached`: Teams reuses the process; a fresh attachment gets a fresh hearing.

### `LokalBotTests/Services/Recording/RecordingHealthNotificationTests.swift`

#### 2026-10-01 Meet recording raised spurious attention notifications and interrupted mark
`CaptureWarningNotifications`: On 2026-10-01 a 33-minute Meet recording raised two "Recording needs
attention" notifications mid-call (a 1.9-second accessibility hiccup and
one dropped buffer) and was then marked "Audio capture was interrupted"
although every frame was saved.

### `LokalBotTests/Services/Recording/RecordingSilenceWatchTests.swift`

#### Replay feeds sound seconds once a second like the recording tick
`RecordingSilenceWatchTests.replay`: Seconds of sound per minute, spread evenly over the minute and fed once
a second, as the recording tick does. Returns the second the watch first
answered true, if it did.

#### 2026-11-17 overnight 16 h recording reconstructed; watch stops about 19:08
`RecordingSilenceWatch`: Reconstructed from the recording of 2026-11-17 (18:31–10:30 local):
the microphone's seconds above -50 dBFS in each minute of the call and
the minutes after it, measured from mic.m4a, plus meeting audio sized
from the system track's per-minute level (digital silence from 18:53 to
the end). The call ended at 18:52; the recording ran until the next
morning, 16 hours. With the watch it stops at about 19:08 and keeps the
call.

#### Post-call microphone passed level half a second in thirteen minutes
`RecordingSilenceWatchTests.testTheNightOfNovember17`: After the call the microphone passed the level for half a second in
thirteen minutes of the night and was otherwise quiet.

### `LokalBotTests/Services/Recording/RunningApplicationCacheTests.swift`

#### Meeting detector read every app via LaunchServices twice per tick on main thread
`RunningApplicationCache`: A live profile on 2026-10-01 showed the meeting detector reading every
running app's pid, bundle id, and name through LaunchServices twice per
2-second tick on the main thread (40–70 ms stalls, about 5% of the main
thread while idle). Each app is now read once.

#### NSWorkspace returns fresh objects for bundle-less processes, so list is kept
`RunningApplicationCache`: NSWorkspace returns fresh objects for processes without a bundle id on
every call, so the list itself is kept until an app launches or quits.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
