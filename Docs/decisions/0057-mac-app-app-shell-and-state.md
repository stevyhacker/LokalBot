# 0057. Mac app: app shell and state

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/`.

## Decisions

### `LokalBot/AppLifecycle.swift`

#### UI-test diagnostics compile out in production and need explicit env opt-in
`uiTestDiagnosticLog`: Opt-in diagnostics for the dedicated hosted UI-test process. Production
targets compile this to a no-op, and the UI-test host emits nothing unless
the launch explicitly sets `LOKALBOT_UI_TEST_DIAGNOSTICS=1`.

#### Menu-bar-only launch computed identically in entry point and delegate; established means onboarded or permissions granted
`lokalbotLaunchesMenuBarOnly`: Whether this launch should come up menu-bar-only (accessory: no Dock icon,
no window). Computed identically in the pre-launch entry point (to disable
window restoration before AppKit reads the flag) and in the app delegate (to
set the activation policy). "Established" = has seen onboarding OR already
granted every permission, so upgrades that predate the onboarding flag still
go menu-bar-only; only a genuinely-new user (and UI tests) stays windowed.

#### SwiftUI alone cannot suppress the launch window on macOS 14
`AppDelegate`: Bridges AppKit launch + window lifecycle into the menu-bar-only experience.
SwiftUI alone can't suppress the launch window on macOS 14, so the Dock /
activation policy is driven from here.

#### Early accessory policy hides Dock icon and stops SwiftUI auto-opening launch window
`AppDelegate.applicationWillFinishLaunching`: Hides the Dock icon for a menu-bar-only start. Setting `.accessory` this
early also stops SwiftUI from auto-opening the launch window; restoration
was already disabled in `LokalBotMain`. UI tests and not-yet-onboarded
users stay windowed — see `lokalbotLaunchesMenuBarOnly()`.

#### Dock icon follows whether a titled window is on screen
`AppDelegate.applicationDidFinishLaunching`: Keep the Dock icon in sync with what's on screen: a real (titled) window
→ show the Dock icon + app menu for full window UX; nothing open → fall
back to a pure menu-bar accessory.

#### UI-test host builds later Settings windows the same way beside launch window
`AppDelegate.applicationDidFinishLaunching`: Settings opened later (the sidebar row, ⌘, or a deep link) gets a
window built the same way, beside the launch window.

#### Unit-test host shares release folders so retired model removal is skipped
`AppDelegate.applicationDidFinishLaunching`: The unit-test host shares the release app's folders; never touch them there.

#### Menu-bar-only start only for login or background launches; manual open shows window
`AppDelegate.applicationDidFinishLaunching`: Menu-bar-only *start* is gated on HOW we launched. Only a login
auto-start (the "Launch at login" item firing) should come up silent
in the menu bar; a manual open (Finder/Launchpad/Dock/`open`) must
show the main window. `willFinishLaunching` already set `.accessory`
to avoid a window-flash, so for a manual open we explicitly bring the
window back up as a regular, Dock-visible app. `wasLaunchedAtLogin`
is only reliable here in `applicationDidFinishLaunching`.
`lokalbot-cli` starting the app for a terminal request counts as a
background launch too: the person asked for a setting, not a window.

#### Agent setup launch opens only its request window
`AppDelegate.applicationDidFinishLaunching`: An agent's setup launch opens only its request window.

#### Launch-at-login state read off main thread so General toggle shows real value
`AppDelegate.applicationDidFinishLaunching`: Read off the main thread now so General's toggle opens on the real value.

#### willClose fires while window still visible, so re-evaluate next tick
`AppDelegate.applicationDidFinishLaunching`: `willClose` fires while the window still reports visible —
re-evaluate on the next tick once it's actually gone.

#### GitHub star active day counts on activation, not menu-bar-only login launch
`AppDelegate.applicationDidBecomeActive`: A day counts toward the GitHub star request when LokalBot becomes the
active app, not when it only runs in the menu bar after a login launch.

#### Reopen opens main window if none visible, raises if buried
`AppDelegate.applicationShouldHandleReopen`: Reopening the app (Finder/Launchpad relaunch, Dock click) brings the main
window back: nothing on screen → open it; visible but buried behind other
apps' windows → raise it. Returning true keeps AppKit's default
un-miniaturize behavior.

#### Closing last window must not quit; capture continues in background
`AppDelegate.applicationShouldTerminateAfterLastWindowClosed`: The main scene is a single SwiftUI `Window`, and SwiftUI quits the app
when that window closes unless the delegate answers here. LokalBot keeps
capturing in the background, so closing the window must leave it running:
`DockPolicy.sync()` drops to the menu bar when menu-bar-only, and a Dock
click reopens the window otherwise.

#### Delay termination so llama runtime shuts down before C++ destructors trip ggml-metal assertion
`AppDelegate.applicationShouldTerminate`: Give the in-process llama runtime a real shutdown window before AppKit
calls exit(). Letting C++ static destructors run while Metal buffers are
still resident trips ggml-metal's residency-set assertion on quit.

#### Launch window versus secondary Settings window; captures follow launch window
`AppDelegate.openUITestWindow`: The launch window, or with `secondary` a Settings window opened beside
it. Captures and the readiness handshake follow the launch window.

#### Hosted macOS desktop is narrow; keep synthetic window inside visible frame for hittable controls
`AppDelegate.openUITestWindow`: GitHub's hosted macOS desktop is narrower than the production
default. Keep the synthetic host inside the visible frame so
right-edge controls remain genuinely hittable by XCUITest.

#### Match SwiftUI titlebar safe area; macOS 26 compact sidebar draws toolbar inside content
`AppDelegate.openUITestWindow`: Match a SwiftUI window's titlebar safe area. In particular, the
native compact sidebar on macOS 26 draws its toolbar background
inside the full-size content view.

#### Defer meeting find publish past key-equivalent dispatch or macOS 15 loses state invalidation
`AppDelegate.openUITestWindow`: AppKit invokes key-equivalent handling inside its event dispatch.
Let that dispatch unwind before publishing the SwiftUI request;
otherwise the host can consume Command-F without invalidating the
meeting detail's state on macOS 15.

#### Quick Recall, setup and Settings have no title bar of their own
`AppDelegate.openUITestWindow`: Quick Recall has no title bar; setup's stepper and Settings' page
title are their own top bars.

#### Toolbar style matches main window scene's unified toolbar height
`AppDelegate.openUITestWindow`: The same toolbar height as the app's main window scene
(`.windowToolbarStyle(.unified)`), whether or not a section
removes the system title.

#### Apply capture size before content exists; macOS 15 grows split panes proportionally otherwise
`AppDelegate.openUITestWindow`: A capture size is an outer-window size. Apply it before the content
exists so the first layout happens at the final size; macOS 15 grows
split panes proportionally when a window is widened afterwards.

#### Drop content minimum size from window so capture size stays authoritative
`AppDelegate.openUITestWindow`: This full-size-content window counts the 52 pt titlebar and toolbar
twice when the SwiftUI minimum becomes a window minimum, so Settings'
600 pt minimum grew 1000x700 captures to 704 pt. A requested capture
size is authoritative; keep the content minimum out of the window.

#### Compact host registers opener so handoff creates main host before dismissing
`AppDelegate.openUITestWindow`: The compact host has no menu-bar scene to register the normal
window opener. Its explicit handoff must still create a main
host before the compact window dismisses.

#### Launching on a Settings page makes Settings the launch window
`AppDelegate.launchWindowKind`: Launching on a Settings page ("settings", "models", "dictation", …)
makes Settings the launch window, as those names once made it the
main window's section.

#### Menu-bar capture is synthetic; production menu extra owns its own presentation
`AppDelegate.uiTestRootView`: Synthetic in-process documentation capture; the production
menu extra continues to own its normal presentation.

#### Env vars drive screenshot hook without Accessibility; no-op unless set, compiled out of non-host builds
`AppDelegate.applyCaptureEnvironment`: Screenshot/scripting hook for the UI-test host: a few env vars let an
external capture script land the window on a specific section with a
meeting preselected, without synthetic input (no Accessibility needed).
A no-op unless the vars are set, so the XCUITest suite is unaffected, and
compiled out of every non-host build.

#### Pin app appearance before capture window so marketing captures are reproducible
`AppDelegate.applyCaptureEnvironment`: Marketing captures must not depend on the host machine's
appearance: the committed README set is dark, and the scripted
sidebar colors resolve per scheme. Pin the app-level appearance
before the capture window exists so exports are reproducible.

#### Settings is launch window so only its page and setting are chosen
`AppDelegate.applyCaptureEnvironment`: Settings is the launch window here (`launchWindowKind`), so
only its page and highlighted setting are chosen.

#### Select the Type page itself, not its Try it sheet
`AppDelegate.applyCaptureEnvironment`: The page itself, not its "Try it…" sheet, which the
Autocomplete and Dictation commands open (`openType`).

#### Reset autosaved split view frames so each test starts from opening widths
`AppDelegate.applyCaptureEnvironment`: Native split views autosave divider positions in this host's own
defaults, shared by every test. A fresh test launch starts from each
pane's opening width; windows are created after this point.

#### Capture size is outer-window dimensions including native titlebar
`AppDelegate.applyCaptureEnvironment`: These are outer-window dimensions, matching the frame
view exported below (including its native titlebar).

#### Self-capture renders in-process, needs no Screen Recording grant, fixed 2x Retina
`AppDelegate.applyCaptureEnvironment`: Self-capture: render the window to a PNG in-process and quit.
Needs no Screen Recording grant, and renders at a fixed 2x so
README assets are Retina-crisp regardless of the display.

#### Re-key window before rasterization so selections and titlebar controls look active
`AppDelegate.applyCaptureEnvironment`: Repeated background launches can lose key status even after
the normal UI-test activation retries. Re-key immediately
before rasterization so active selections and titlebar
controls match what a person sees while using the app.

#### Harness acknowledges route content after geometry; keep material settle after activation
`AppDelegate.awaitCaptureReadiness`: The harness acknowledges populated route content after the window reaches
its requested geometry. Keep the existing material settle after activation.

#### LOKALBOT_CAPTURE_SCALE clamped 1 to 4, README default 2x
`AppDelegate.captureScale`: LOKALBOT_CAPTURE_SCALE, clamped to 1...4. README captures default to 2x.

#### Re-keying hands focus to clear button and draws ring; refocus search field
`AppDelegate.focusQuickRecallField`: Quick Recall opens with its search field focused. Re-keying the window
for a capture can hand focus to the first key view, the clear button,
which then draws a focus ring, so return focus to the field.

#### Focusing selects the query; place caret at end like typing
`AppDelegate.focusQuickRecallField`: Focusing selects the query; a person typing it has the caret at the end.

#### cacheDisplay uses display backing scale; redraw self-drawing layers at requested density
`AppDelegate.raiseCaptureDensity`: `cacheDisplay` copies each layer's backing store, which AppKit sizes for
the display's backing scale. Above that scale it would only enlarge the
2x pixels, so first redraw the layers that draw their own content (text,
shapes) at the requested density. Layers whose contents are assigned,
such as icons and thumbnails, are left as they are.

#### Redraw inside drawing appearance or controls use default colors
`AppDelegate.raiseCaptureDensity`: Outside AppKit's display pass no drawing appearance is current, and
controls would redraw in their default colors.

#### Sheet is its own window; draw it over dimmed parent in capture
`AppDelegate.drawAttachedSheet`: A sheet is a window of its own, so the parent's capture leaves it out.
Draw it where it sits, over a dimmed parent, as a person sees it.

#### Render frame view at configurable density via cacheDisplay, up to 4x
`AppDelegate.writeWindowCapture`: Render the window's frame view (titlebar + content) into a configurable
high-density PNG via `cacheDisplay`, independent of the display's
backing scale. README captures default to 2x; website and video
captures can ask for up to 4x through LOKALBOT_CAPTURE_SCALE.

#### Convert to sRGB before tagging so P3 captures are not mislabeled
`AppDelegate.writeWindowCapture`: cacheDisplay renders through the current display profile. Convert the
samples before tagging the web asset so P3 captures are not mislabeled.

#### Readers treat destination appearance as completion, so write atomically
`AppDelegate.writeWindowCapture`: Readers treat the destination's appearance as completion.

#### UI-test host has no scene commands; handle meeting find key equivalent at window level
`MeetingFindWindow`: The UI-test host owns an explicit AppKit window rather than a SwiftUI
`Window` scene, so scene commands are intentionally absent there. Handle
the meeting-local key equivalent at the same window boundary AppKit uses
for synthesized and physical keyboard events. Production keeps its visible
Edit-menu command in `LokalBotApp`.

#### Self-captures skip screen clipping to preserve requested layout
`MeetingFindWindow.constrainFrameRect`: Self-captures rasterize the native frame view, including portions
beyond the hosted desktop. Preserve the requested layout instead of
silently clipping every large-window fixture to the runner's screen.
Interactive UI tests retain ordinary on-screen window constraints.

#### NSWindow does not route every key-down through performKeyEquivalent
`MeetingFindWindow.sendEvent`: `XCUIApplication.typeKey` and physical keyboard input arrive here as
key-down events. `performKeyEquivalent` is still needed for AppKit's
menu/responder traversal, but NSWindow does not route every key-down
through that method before dispatching it to the first responder.

#### Activation policy follows setting and open windows; evicts restored windows after menu-bar start
`DockPolicy`: Drives the Dock/menu-bar activation policy from the current setting and the
windows on screen: accessory (menu-bar-only) unless the user opted into a
Dock icon or a real window is open. Also the launch-time backstop that evicts
windows macOS restores behind a menu-bar-only start.

#### Evict restored windows until first user open since accessory and ignore-state are unreliable
`DockPolicy.evictRestoredWindows`: True from a menu-bar-only launch until the first explicit user-initiated
open. While set, any titled window on screen was restored or auto-opened
by macOS (the user hasn't asked for one yet) and is evicted — `.accessory`
and `ApplePersistenceIgnoreState` don't reliably stop that restore, so
this is the deterministic backstop. Cleared by `WindowAccess.open`.

#### Sweep several times to catch asynchronously restored windows; flag persists until real open
`DockPolicy.beginLaunchSuppression`: Start evicting restored/auto windows after a menu-bar-only launch. Sweeps
a few times to catch windows SwiftUI restores asynchronously (or without
firing a key notification); the flag itself persists until the first real
open, so even a late restore is caught.

#### Menu bar popover is borderless; only titled normal-level windows count
`DockPolicy.sync`: The menu bar popover is a borderless, non-normal-level panel; only
titled, normal-level windows (main / onboarding / settings) count.

#### openWindow exists only in View tree; views register it and early requests queue
`WindowAccess`: Opens SwiftUI windows from non-View code (AppDelegate, AppState). SwiftUI's
`openWindow` only exists inside the View tree, so views register it here and
requests made before a view is alive are queued and flushed on registration.

#### Registered by first live view; flushes requests queued before then
`WindowAccess.register`: Called from the first view that comes alive (the menu bar label at
launch, then the popover/window). Flushes anything queued before now.

#### UI-test host answers true for identifiers it opens itself, bypassing SwiftUI scenes
`WindowAccess.hostOpener`: The UI-test host builds its windows by hand. It answers true for the
identifiers it opens itself, so those never reach the SwiftUI scenes.

#### Explicit open cancels eviction and switches to regular policy for standard chrome
`WindowAccess.open`: An explicit, user-initiated open: cancel any launch-time window
eviction, then switch to a regular, Dock-visible app so the window
gets standard chrome and the app menu. `willClose` drops back to
accessory afterwards when menu-bar-only.

#### Match main window by scene identifier because navigationTitle retitles it per tab
`WindowAccess.visibleMainWindow`: The visible main SwiftUI window, matched by its scene identifier —
`navigationTitle` retitles the window per tab (e.g. "Timeline"), so
matching on the title silently stops finding it.
Closes a window scene by its identifier when it is open.

#### UI-test host names hand-built windows id.window
`WindowAccess.visibleWindow`: The visible window of a single-window scene. The UI-test host names
the windows it builds by hand "\<id>.window".

### `LokalBot/AppState+GlobalShortcuts.swift`

#### Remember source app so recording or dictation commands can hand focus back
`AppState.openQuickRecall`: Opens Quick Recall, remembering the app the person was in so a
recording or dictation command run from it can hand focus back. The
system-wide shortcut, ⌘K and the View menu all come through here.

#### Repeated command-K inside the window keeps what it was opened from
`AppState.openQuickRecall`: Pressing ⌘K again inside the window keeps what it was opened from.

#### Ask shows Quick Recall conversation with sources scoped to last question
`AppState.continueQuickRecallConversationInAsk`: Shows in the Ask screen the conversation Quick Recall holds, with the
sources menu saying what its last question was limited to, as when a
saved conversation is opened there.

#### Run action once source app is frontmost again, or immediately if LokalBot
`AppState.returnFocusToShortcutSource`: Runs `action` once the app Quick Recall was opened from is frontmost
again, or right away when it was opened from LokalBot itself.

#### Refused new shortcut falls back to previous, else disables selection actions
`AppState.applySelectionActionsSetting`: `previous` is the shortcut to fall back to when a newly chosen one is
refused; without one, a refused shortcut turns selection actions off.

#### Selection actions use meeting search plus dream-maintained work memory
`AppState.selectionMemoryContext`: Meetings that match the selection, plus the dream-maintained work
memory, for actions that write with the person's own context. Uses the
same search as Ask's meeting tool.

### `LokalBot/AppState+SampleMeeting.swift`

#### Setup sample choice opens now or when models ready, even after setup closes
`AppState.openSampleMeetingWhenReady`: Setup's "open the sample meeting" choice: now when its models are on
this Mac, otherwise as soon as they are, also after the setup window
has closed.

#### Called whenever model readiness changes
`AppState.openWaitingSampleMeeting`: Called whenever model readiness changes.

#### Sample removal asks no confirmation because it can be re-added
`AppState.removeSampleMeeting`: The sample can be added again at any time, so removing it doesn't ask first.

### `LokalBot/AppState+WindowHandoff.swift`

#### Agent Mode and Copy always available; Claude Code and Codex only when installed
`WindowHandoffTarget.availableOnThisMac`: Agent Mode and Copy always; Claude Code and Codex when installed.

#### Refused new shortcut falls back to previous, else disables Hand off
`AppState.applyWindowHandoffSetting`: `previous` is the shortcut to fall back to when a newly chosen one is
refused; without one, a refused shortcut turns Hand off off.

#### New Agent Mode task gets brief and package copy; auto-start sends immediately
`AppState.handOffWindowToAgentMode`: A new Agent Mode task with the brief in its composer and a copy of the
package in its working folder, so the agent reads it without asking.
"Start handoffs automatically" sends it right away.

#### Start task only after copy and attachment exist since prompt points at them
`AppState.handOffWindowToAgentMode`: The task starts only after the copy and the attachment are in
place: its prompt points at them.

#### Archive task when copy fails because its prompt names missing files
`AppState.handOffWindowToAgentMode`: Its prompt names files that are not there. Put the task away
instead of leaving it among the tasks waiting to be sent.

### `LokalBot/AppState.swift`

#### AppState wires dependencies; recording lifecycle, headless commands, launch plumbing live elsewhere
`AppState`: Central app state (the "coordinator" from the design doc §6): dependency
wiring, the meeting library, navigation, and the detection→recording glue.
The recording lifecycle itself lives in `RecordingController`; headless
subcommands in `HeadlessCommandRunner`; AppKit launch plumbing in
`AppLifecycle.swift`.

#### Sidebar symbol is reused by Today panels leading to the section
`AppState.NavSection.symbol`: The symbol beside the section in the sidebar. Today's panels show
the same one for the section they lead to.

#### Legacy capture/deep-link names map to sections; settings names are not sections
`AppState.NavSection.init(captureName:)`: Section names accepted from the UI-test capture environment and
deep links. Legacy names keep working: "capture" (the pre-split
merged section) lands on Timeline and "search"/"chat" on Ask
(spec §2.1). Settings has its own window, so its names ("settings",
"models", "dictation", …) are not sections: see
`SettingsTab.init(sectionName:)`.

#### Type tab is session-sticky across navigation
`AppState.TypeTab`: Which tool the Type section shows. Session-sticky: preserved while
navigating away so returning lands on the last-used tab.

#### Settings raw values stay stable for CLI, AppControl and saved selections
`AppState.SettingsTab`: A Settings page. Each feature has one page with everything that sets it
up, in the order the Settings window lists them. Raw values stay stable
for the CLI, AppControl and saved selections, so a renamed page keeps
its old identifier.

#### Which pages sit above, under, and below the Settings headings
`AppState.SettingsTab.group`: The heading the page sits under in the Settings window's list.
Overview (the LokalBot row), General, Models and Privacy &
permissions come first, above the headings; Diagnostics comes last,
below them.

#### Former page names kept so settings search still finds them
`AppState.SettingsTab.formerNames`: What the page was called before, so settings search still finds it
by the old name.

#### Overview has no header summary; it opens with what needs attention
`AppState.SettingsTab.summary`: One line under the page's name in its header. Overview has no
header: it opens with what needs you.

#### Old main-window section names open Settings; plain settings opens last page
`AppState.SettingsTab.opensSettings(sectionName:)`: The Settings page a launch or capture section name opens, for the
names that used to be main-window sections: "settings" itself opens
the page last shown.

#### Capture and launch names include pre-feature-organization page names
`AppState.SettingsTab.init(captureName:)`: Capture and launch names, including the names pages had before
Settings was organized by feature.

#### UI-test launch gates side-effectful startup so UI renders on synthetic data
`AppState.isUITesting`: True when launched by an XCUITest harness — gates the side-effectful
startup paths (Core Audio polling, accessibility-trusted detector,
Sparkle, periodic screenshots) so the UI renders against synthetic
data without touching real audio, TCC, or the network.

#### UI Test Host background mode replays capture trace and file audio, Debug only
`AppState.runsBackgroundWorkInUITests`: The UI Test Host's background mode runs the interactive start against
a replayed capture trace and file audio (Debug test hooks only).

#### Hosted XCTest returns early before touching library, indexes, permissions, network
`AppState.isUnitTesting`: Hosted XCTest executes the real app entry point. It needs neither UI
fixtures nor any interactive service, so return before touching the
meeting library, indexes, permissions, audio, Sparkle, or the network.

#### Onboarding-shown flag is read by AppDelegate and the coding-agent reader
`AppState.onboardingShownKey`: UserDefaults flag: the permission onboarding has been shown once. Also
read by `AppDelegate` to keep the first run windowed, and by the
coding-agent reader, which waits for it.

#### Stalled text recognition keeps unreadable windows without pixels or drops them
`AppState.textRecognitionStalled`: Text recognition has stopped answering (`TextRecognitionQueue`). Until
it answers or the app restarts, a window whose text Accessibility
cannot read is kept without its pixels, or not at all. Cleared when it
answers, or when the user dismisses it.

#### Set when mic denied at system level; cleared on opening Settings or dismiss
`AppState.micRecoveryNeeded`: A recording or dictation start was refused because microphone access
is denied at the system level. Cleared when the user opens System
Settings from the recovery toast or dismisses it.

#### Mirror of sampler pause state; per-launch, never a saved setting
`AppState.dayMemoryPaused`: Day memory is paused for now (`ActivitySampler.isPaused`), mirrored
here so the menu bar icon and panel follow it without observing the
sampler's every sample. A state of this launch, never a saved setting.

#### Always-alive settings owner; services capture it, never AppState
`AppState.settingsStore`: The always-alive settings owner; services capture this, never AppState.

#### UI settings surface writes through to store and fans out to subsystems
`AppState.settings`: UI-facing settings surface (views bind `$app.settings.x`). Writes flow
through to `settingsStore` (which persists) and fan out to the
subsystems that apply settings live.

#### Retention reductions are reviewed explicitly; preference changes never trigger cleanup
`AppState.settings`: UI retention reductions are reviewed and executed explicitly.
Changing a preference must not trigger an unreviewed cleanup.

#### Custom prompt excluded so editing it never resets the scheduler
`AppState.dayDigestChanged`: The custom prompt is deliberately absent: it is read fresh from
`settings` at generation time, so editing it never resets the scheduler.

#### Retention bounds days read, so it restarts ingestion
`AppState.codingAgentEvidenceChanged`: Retention bounds which days are read, so it restarts ingestion too.

#### Drafts are unpublished: publishing re-rendered every observer per keystroke
`AppState.meetingNoteDrafts`: Unsaved note text, so a remounted editor resumes it. Editors read it
only when they appear; publishing it re-rendered every AppState
observer on each keystroke.

#### Ask query and scope live on own object so typing does not re-render all observers
`AppState.recall`: Ask's query and scope live on their own object, observed by Ask alone,
so typing a query does not re-render every AppState observer.

#### People and Projects share one derived read model
`AppState.selectedPersonID`: People and Projects share one derived read model.

#### Follow-through: Think model plans one action; each step awaits approval
`AppState.followThroughSession`: The open Follow-through run (the Think model plans one action; each step waits for approval).

#### Sample meeting added when models arrive; forgotten on quit
`AppState.sampleMeetingWaitsForModels`: Setup asked for the sample meeting before its models were here; it is
added when they are. Forgotten when LokalBot quits.

#### Completion hints are suggestions only; status changes stay the user's
`AppState.refreshActionCompletionHints`: "Looks done?" suggestions for open actions from later retained screen
text. Suggestions only; status changes stay the user's.

#### Automatic project notes need scheduled-digest approval and never download models
`AppState.writeProjectSummary`: Writes a tracked project's "Where it stands" note with the Think model.
An automatic write (opening a project whose note is missing or out of
date) runs only under the same approval as scheduled digests and
Dream runs, and never starts a model download.

#### Key renamed so everyone opens new Overview once
`AppState.settingsTabDefaultsKey`: Renamed when Settings was organized by feature, so everyone opens the
new Overview once; the page chosen after that is remembered.

#### Ask mode survives remounts; handoffs and conversation selections switch back to Ask
`AppState.askMode`: Ask's retrieval choice survives NavigationSplitView remounts while the
app is running. Explicit handoffs and conversation selections still
switch back to Ask before presenting their content.

#### Find-bar presentation in shared state gives menu/AppKit and split view one source of truth
`AppState.presentedMeetingSearchID`: The meeting whose page-level find bar is visible. Keeping presentation
in shared observable state makes menu/AppKit requests and the rendered
NavigationSplitView consume one source of truth.

#### One date boundary for Ask; single-day adapter keeps Timeline handoffs working
`AppState.askDateScope`: One date boundary for Ask search, answer tools and restored questions.
The single-day adapter keeps Timeline navigation handoffs compatible.

#### Legacy writing commands route to corresponding Settings section
`AppState.openType`: Keep legacy writing commands routed to the corresponding Settings section.

#### Settings opens in its own window; main window stays put
`AppState.openSettings`: Open Settings in its own window, or bring that window forward, on the
given page. The main window stays on what it was showing.

#### Assign only changed values: every @Published assignment re-renders all observers
`AppState.selectSettingsTab`: A Settings category click. Every `@Published` assignment re-renders all
AppState observers, equal value or not, so assign only what changes.

#### Deep-link target for search hits, menu-bar recents, Quick Recall
`AppState.openMeeting`: Open one meeting in the Meetings section — the deep-link target
for search hits, menu-bar recents, and Quick Recall's recent meetings.

#### In-progress recording selected resolves to currentMeeting, routed to live view
`AppState.selectedMeeting`: The meeting shown in the detail pane (single selection only). The
in-progress recording is a first-class citizen here: selecting its
row resolves to `currentMeeting`, which `CaptureDetailView` routes
to the live view.

#### External-agent access is Privacy marker plus local-model wake watcher
`AppState.agentAccess`: External-agent access: Privacy marker plus the local-model wake watcher.

#### Screen-memory access is separate from meeting-library access; one never grants other
`AppState.screenMemoryAccess`: Screen-memory access is intentionally separate from meeting-library
access: enabling one capability never grants the other.

#### Third independent grant: agents read only shared Personal Context items from synced copy
`AppState.personalContextAccess`: A third independent grant: agents read only the Personal Context items the
person marked as shared, from a copy kept in step with every edit.

#### Fourth read grant; chosen folders kept in CLI-readable copy while Files is on
`AppState.filesAccess`: File search for agents: a fourth read grant, with the chosen folders
kept in a copy the CLI reads while Files is on.

#### Fifth read grant; agent notes exist in library only while being read
`AppState.agentNotesAccess`: A fifth read grant: searching the notes coding agents saved for
themselves, which exist in the library only while they are being read.

#### One switch over the five read grants, one box each
`AppState.agentReadAccess`: The one switch over the five read grants, with a box for each.

#### Terminal settings access is a separate grant; control socket exists only while on
`AppState.settingsControl`: Terminal settings access is another separate grant. Its control
socket exists only while the grant is on.

#### Terminal settings changes recorded for audit log and Undo
`AppState.agentSettingsChanges`: Settings changed from the terminal, for the audit log and Undo.

#### Terminal requests awaiting the person: widening changes and API keys
`AppState.settingsApprovals`: Terminal requests waiting for the person: widening changes and API keys.

#### Agent setup start request is the only way the terminal asks for access
`AppState.agentSetup`: An agent's `setup start` request, the one way the terminal asks for access.

#### Remember app in front at shortcut so in-place commands return focus
`AppState.shortcutSourceApplication`: The app in front when a system-wide shortcut opened a LokalBot panel,
so a command that acts in place can hand focus back to it.

#### Quick Recall from main window also offers the current page's commands
`AppState.quickRecallOpenedFromMainWindow`: Quick Recall was opened from the main window (⌘K or the View menu), so
it also offers the commands of the page that window is showing.

#### Selection actions run on Think model keeping remote per-origin approval
`AppState.selectionActions`: AI actions on text selected in other apps. Runs on the Think model,
so remote inference keeps its per-origin approval.

#### Window handoff brief runs on Think model keeping remote per-origin approval
`AppState.windowHandoff`: Hand off: reads the focused window on a press and hands its task to
another agent. The brief runs on the Think model, so remote inference
keeps its per-origin approval.

#### Notes written only while processing idle to avoid half-finished rewrites
`AppState.meetingNoteExport`: Notes are written while processing is idle, so a meeting's note is not
written half-finished and rewritten moments later.

#### People and Projects choices change the names notes link to
`AppState.meetingNoteCurationObserver`: People and Projects choices change the names notes link to.

#### Dream scheduler observed by Settings, store read by Today, latest report refreshes open Today
`AppState.latestDreamReport`: Overnight dreaming: the scheduler is observed by Settings (progress /
last-run), the store is read by Today, and `latestDreamReport` lets an
open Today window pick up a dream that finishes while it's visible.

#### Pins: store is source of truth; reload before saving to avoid stale writes
`AppState.dreamMemory`: Settings' user-managed pin controls. The store remains the source of
truth; mutations reload it before saving to avoid stale-view writes.

#### Calendar is read-only EventKit, concrete type so settings UI observes permission
`AppState.calendar`: Read-only calendar access (EventKit): confirms meetings and titles
recordings. Concrete type so the settings UI observes its permission
state; handed to the detector as the `CalendarEventProviding` seam.

#### Mail is read-only; nothing read until the person connects an account
`AppState.email`: Connected mail accounts, read-only. Nothing is read until the person
connects an account; checks then run in the app like every schedule.

#### Email sync waits for library since recorded-meeting attendees count
`AppState.email`: Recorded meetings' attendees count too, so wait for the library.

#### Nothing read until Files is on and a folder is chosen
`AppState.fileSearch`: Files: the folders the person chose, searched by what is in them.
Nothing is read until Files is turned on and a folder is chosen.

#### Transcribe matched 30 s only with on-Mac model and never while recording
`AppState.fileMoments`: Transcribes a recording's or video's matched 30 seconds for the
assistant, with the person's transcription model, only if it is on
this Mac, and never while a meeting records.

#### Screen image vectors only with semantic search and visual context; never headless or tests
`AppState.screenImages`: Picture vectors for retained screen captures, made on the media
embedder Files uses. Wanted only with search by meaning and Text +
visual context; headless runs and test hosts never make them.

#### ThinkExecution owns backend choice, privacy policy, leases, recovery for all Think features
`AppState.thinkExecution`: Backend selection, preparation, privacy policy, leases, and recovery
for every feature that uses LokalBot's Think role.

#### GitHub star request lives in Settings General About and menu bar, not Today
`AppState.githubStar`: The GitHub star request: Settings › General › About and the menu bar
link. Today no longer shows a card for it.

#### ModelRoles is the canonical state machine for Transcribe, Think, Autocomplete
`AppState.modelRoles`: Canonical state machine for Transcribe, Think, and Autocomplete.

#### One Day Digest lifecycle for manual, scheduled, headless callers
`AppState.dayDigest`: One Day Digest lifecycle for manual, scheduled, and headless callers.
It owns evidence collection, journal state, freshness, and repair policy.

#### Coding-agent work read only after opt-in and after setup finished
`AppState.codingAgentEvidence`: Settled Claude Code and Codex work, read into the activity store while
the person has opted in, and never before setup is finished.

#### Agent notes indexed only while the person has turned it on
`AppState.agentNotes`: The notes Claude Code and Codex keep for themselves, read into a
searchable index only while the person has turned that on.

#### Agent-notes search is empty while the feature is off
`AppState.agentNotesIndex`: Search over those saved notes; empty while the feature is off.

#### Withdraw only the silent-capture advisory, never a newer error
`AppState.recording onError`: Withdraw only the silent-capture advisory, never a newer error.

#### Every dictation is a writing request: local ASR, composition LLM, focus-safe insertion
`AppState.dictation`: Press-and-speak composition. Every dictation is treated as a writing
request: local ASR captures the instruction, the configured composition
LLM writes against ephemeral focused-window context, and focus-safe
delivery inserts it.

#### Autocomplete on chosen server; Writing reads its last problem
`AppState.cotypingServer`: Autocomplete on a chosen server. Writing reads its last problem.

#### Local cotyping uses dedicated LlamaServer.cotyping; resolved per completion
`AppState.cotypingEngine`: Cotyping (inline AI autocomplete). On this Mac it runs its own model on
the dedicated `LlamaServer.cotyping` instance so it never thrashes the
shared summarizer server; a chosen server is reached through
`cotypingServer`. Resolved per-completion, so changes apply live.

#### Live transcript is preview only; post-meeting transcript stays authoritative
`AppState.liveTranscriber`: Rolling live transcript of the recording in progress (preview only —
the pipeline's post-meeting transcript stays authoritative).

#### Live Radar uses Think model while recording and runs only after person starts it
`AppState.meetingRadar`: Live Radar reads the live transcript with the Think model while
recording; it runs only after the person starts it for that meeting.

#### UI-test host film uses scripted or Meta models, both Meta wire format
`AppState.meetingRadar`: The hosted film of Live Radar runs on scripted replies, or on
Meta's models with the film's key. Both speak Meta's wire format.

#### UI-test host can use synthetic capture folder via LOKALBOT_UI_TEST_SCREENS
`AppState.radarScreenSource`: Screen memory for screen answers. The UI-test host can use a folder of
synthetic captures instead (`LOKALBOT_UI_TEST_SCREENS`), as the radar
replay's `--screens` does.

#### Read-only tools shared by Ask and selection actions memory lookup
`AppState.libraryTools`: Read-only tools over the live meeting list and search indexes, shared
by Ask and selection actions' memory lookup.

#### Companion created lazily and starts nothing until sharing is on
`AppState.companionHost`: Phones and tablets (Settings → Phones & tablets). Created on first use,
such as Settings → Overview showing its card; it starts nothing until
sharing is on, so with sharing off nothing listens and no record is built.

#### Sharing waits for library so device ops find their meetings
`AppState.applyCompanionSetting`: Starts, reconfigures, or stops sharing to match Settings. Waits for the
library so ops from devices find their meetings.

#### Dictated words wait for overnight learning pass while learn-from-dictation is on
`AppState.dictationLearningLog`: What the person told LokalBot about themselves: Ask and Quick Recall
read and add to it, Settings → Personal Context edits it.
Dictated words waiting for the overnight learning pass, while Learn
from my dictation is on.

#### Agent Mode installer cheap; each tab spawns own controller lazily
`AppState.agentInstaller`: Agent Mode (pi). Installer and tab manager are cheap; each tab lazily
spawns its own controller/process when AgentView mounts it.

#### True only on real interactive launch; gates notifications and onboarding
`AppState.interactive`: True only on the real interactive launch path (not headless / UI test) —
gates recording notifications and first-run onboarding.

#### Serialize cotyping model transitions so unload finishes before re-enable prewarm
`AppState.cotypingRuntimeTask`: Serializes cotyping model lifecycle transitions. A disable must finish
unloading both runtimes before a rapid re-enable can prewarm a fresh
model, otherwise the old and new routes can overlap in memory.

#### Deleted and merge-folded meetings excluded from search for the session
`AppState.excludedMeetingIDs`: Meeting IDs excluded from search for this session. This includes
physically deleted meetings and source rows folded into a merge.

#### Radar keeps own copy of live lines so last pass runs after preview clears
`AppState.meetingRecordingStateDidChange`: The radar keeps its own copy of the live lines, so its last pass can
run after the preview is cleared.

#### With Live Radar on, panel offers Start Radar over the call
`AppState.meetingRecordingStateDidChange`: With Live Radar on, the panel offers Start Radar over the call.

#### Film's stand-in call covers window; closing it is the way back
`AppState.showLiveMeeting`: The film's stand-in call covers the LokalBot window; closing it is the way back.

#### AppKit-drawn text reads text size before any window exists
`AppState.init`: AppKit-drawn text reads this before any window exists.

#### Settings corruption is a privacy event; report exactly what fell back
`AppState.init`: Settings corruption is a privacy event, not a cosmetic one: a field
like screenshot capture silently resetting to its default changes
what the app records. Say exactly what fell back.

#### Views observe AppState only; forward sub-object change notifications
`AppState.init`: Views observe AppState only; forward pipeline / recording /
audio-monitor / calendar change notifications so MainWindowView
refreshes when those sub-ObservableObjects publish.

#### Do not forward recording one-second tick; it invalidated whole window hierarchy
`AppState.init`: Forward lifecycle changes, but not RecordingController's one-second
`now` tick. Timer labels observe the controller directly; rebroadcasting
that tick through AppState invalidated the entire window hierarchy.

#### Model readiness forwarded, not download progress; model views observe ModelRoles
`AppState.init`: Not download progress: the model views observe ModelRoles directly.

#### Readiness publisher fires before roles hold new state, so defer
`AppState.init`: The publisher fires before the roles hold their new state.

#### Sample meeting notes do not count toward GitHub star prompt
`AppState.init`: The sample's notes don't count toward asking for a GitHub star.

#### Sampler exists only in windowed launches; headless returns earlier
`AppState.init`: The sampler exists in every windowed launch; headless commands
returned above and never create it.

#### UI tests bail before subsystems touch mic, process list, or network
`AppState.init`: UI tests render against pre-seeded fixtures, not a real audio/Sparkle
session — bail out before any subsystem reaches for the mic, the
process list, or the network.

#### Recording already capturing this call follows its end
`AppState.init detector.onMeetingStarted`: A recording already capturing this call follows its end from now on.

#### Audio monitor covers muted-mic meetings missed by mic-in-use signal
`AppState.init`: The mic-in-use signal misses meetings with a muted mic. The audio
monitor is the complementary "a meeting app just started producing
audio output" signal. In automatic mode it records recognised
meeting sources; other candidates expire silently.

#### Sparkle silent check is no-op on dev builds until appcast and key configured
`AppState.init`: Start Sparkle (silent background check). No-op on dev builds and
until the appcast feed URL + public key are configured (RELEASING.md).

#### CLI setup start leaves request and launches app or notifies running copy
`AppState.init`: `lokalbot-cli setup start` leaves a request and launches the app,
or tells a running copy to look for it.

#### Headless runs and UI test host never read mail
`AppState.init`: Headless runs and the UI test host never read mail.

#### First-run onboarding flag persists only on finish or defer; resume after permission restart
`AppState.init`: First-run check. A genuinely-new user with missing permissions gets
onboarding (windowed — see AppDelegate); the flag persists only when
they explicitly finish or defer the wizard (OnboardingView footer),
so quitting mid-wizard re-opens it next launch. Fully-permissioned
installs that predate the flag are recognised as established right
away and start menu-bar-only next launch.
A setup interrupted by the restart a permission grant needs
reopens where it was (`OnboardingResumeStore`).

#### Agent setup request replaces wizard; declining opens onboarding
`AppState.init`: An agent's setup request replaces the wizard; declining it
opens onboarding instead.

#### New installs read no coding-agent session until setup finished
`AppState.init`: After the first-run check: until setup is finished, a new install
reads no coding-agent session (`finishOnboarding` starts it).

#### System-wide automation starts only if enabled and granted; otherwise parks
`AppState.init`: Bring optional system-wide automation up if the user left it enabled
and the grants are in place; otherwise it parks itself.

#### Load large library on utility executor and publish one sorted snapshot
`AppState.loadLibraryInBackground`: Large meeting libraries can take seconds to enumerate, repair, duration-
probe, and FTS-index. Do that work on a utility executor and publish one
sorted snapshot when ready instead of blocking the first app window.

#### Clear stale tombstones from earlier boundary reviews before reindex
`AppState.loadLibraryInBackground`: Earlier boundary reviews tombstoned live meetings, hiding
them from search; clear those before the reindex below.

#### Preserve meetings created while background scan ran
`AppState.loadLibraryInBackground`: Preserve meetings created while the background scan was running.

#### Dreaming gated during launch recovery; re-check after library loads
`AppState.loadLibraryInBackground`: Dreaming was deliberately gated while launch recovery rebuilt
the library and durable processing queue. Re-check immediately;
pending pipeline work will keep the downtime gate closed until a
later timer tick.

#### Re-embedding notes is expensive so wait 20 s for typing to settle
`AppState.meetingNotesDidChange`: The user's own notes are keyword- and meaning-searchable. Re-embedding
a whole meeting is expensive, so it waits for typing to settle.

#### Notes saved outside evidence path; notify paired devices explicitly
`AppState.meetingNotesDidChange`: Notes are saved outside the evidence path; paired devices show them.

#### Processing and external imports both refresh outcomes, search, day memory here
`AppState.meetingArtifactsWritten`: A meeting's transcript or notes changed on disk: refresh its outcomes
and search, and let the day's memory know. Processing and imports
from other apps both end here.

#### Screens keyword-searchable at once; semantic join at next batched backfill
`AppState.screenTextDidArrive`: A capture stored text. Screens are searchable by keyword at once and
join semantic search with the next batched backfill pass.

#### Retry failed index cleanup with bounded backoff; tombstones cover exit
`AppState.scheduleIndexCleanup`: Index rows are reconstructible, but a failed SQLite cleanup must not
become permanent once the meeting folder disappears. Retry both stores
with bounded backoff for the rest of the session; durable tombstones and
each index's startup reconciliation cover interruption or app exit.

#### Queue lifecycle changes; unload runs even if cancelled, later ops await it
`AppState.scheduleCotypingRuntimeOperation`: Queue lifecycle changes instead of launching independent tasks. An
unload intentionally runs even if a later operation cancels its task:
the later operation awaits it before loading another model.

#### Stay usable if stopped recording has unsaved metadata; later Quit retries
`AppState.terminate`: Keep the application usable when a stopped recording still has
unsaved metadata or processing intent. A later Quit retries it.

#### Manual start folds in active calendar event for titling
`AppState.recordingContext(for:)`: Builds a detection context for a user-initiated recording on `detectedApp`
(nil → manual), folding in the active calendar event when calendar
detection is enabled and authorized — so menu and command entry points
get calendar titling too.

#### Recording joins tracked call only if verifiable; manual mode leaves stops to user
`AppState.detectorSession(following:)`: A recording the user starts for the call the detector is tracking joins
that session, so the call's end stops it. A call the detector can no
longer verify may already be over, so a recording never joins it.
Manual mode leaves every stop to the user.

#### Unverified detector browser call drops its meeting URL on manual start
`AppState.manualSource`: The detector's browser call keeps its app (and its audio) for a manual
start, but not its room while that call is unverified: the user may
already be in another one, which the calendar link names better.

#### Calendar event start attaches metadata; system audio only if meeting app visible
`AppState.recordingContext(for:calendarEvent)`: A user can explicitly start the scheduled event from Today's upcoming
meeting card before automatic detection fires. Attach the calendar
metadata immediately; capture system audio too when a matching meeting
app is already visible, otherwise RecordingController safely records
the microphone when no meeting app is visible yet.

#### Auto-record only high-confidence native output or verified browser meeting
`AppState.audioMonitorDetected`: `AudioSourceMonitor` saw an app newly start producing output. Auto-record
in automatic mode only for high-confidence native meeting output or a
verified browser meeting; ignore broader candidates so notification
sounds cannot start recordings.

#### Merge creates provenance-linked meeting; source folders untouched, rows folded out
`AppState.mergeMeetings`: Creates a new, provenance-linked meeting from completed sources. The
source folders remain untouched, but their rows are folded out of the
library after the merge succeeds.

#### Folding can partially write before rollback fails; reopen derived consumers
`AppState.mergeMeetings`: Folding can partially write before rollback fails. Reopen derived
consumers even when merge cannot return a complete result.

#### Tombstone both indexes before publishing folded library projection
`AppState.mergeMeetings`: Tombstone both indexes before publishing the folded library
projection. The retry loop remains available for a transient
SQLite failure, but a normal merge cannot leave searchable
source rows behind if the app exits immediately afterward.

#### Partial merged transcript must not satisfy summary; re-transcribe merged audio
`AppState.mergeMeetings`: A partial merged transcript must never satisfy the summary
request. Re-transcribe the concatenated audio so every source
range is represented; this also handles two audio-only sources.

#### Import one file at a time; missing speech model downloads; failures reported together
`AppState.importRecordings`: Imports audio or video files as meetings, one file at a time, and
queues each for transcription and, when enabled, a summary. Choosing a
file is an explicit request, so a missing speech model downloads as it
does for Retry. Failures are reported together once the batch ends.

#### Keep user file names out of import-failure log
`AppState.importRecordings`: The message names the file; keep user file names out of the log.

#### Device recordings wait for missing models, never download, open nothing, show no error
`AppState.addDeviceRecording`: A recording from a paired device arrived as a meeting. It joins the
list and the processing queue like a recording finished on this Mac,
which waits for missing models rather than downloading them with nobody
here to see it. The person may be doing something else, so nothing opens
and no error shows.

#### Sample meeting transcribed and noted even with auto notes off; models downloaded first
`AppState.importSampleMeeting`: Adds LokalBot's sample meeting through the same import as a chosen
file, then transcribes it and writes its notes (even with automatic
notes off). The models it needs are downloaded first, as their own
step, by `SampleMeetingSetupSheet`.

#### Undo restores source rows; clear merge markers and tombstones before indexing
`AppState.undoMerge`: Removes a generated merged record and restores its original source
rows. Source folders are retained; their durable merge markers and
search tombstones are cleared before the restored evidence is indexed.

#### Live-session enumeration must never run startup orphan repair
`AppState.undoMerge`: Enumeration during a live session must never run startup orphan repair.

#### Failed source restores keep on-disk marker and retry next launch
`AppState.undoMerge`: Other sources can still recover. Failed ones retain
their on-disk marker and are retried at next launch.

#### Invalidate derived claims even when no complete segment survives
`AppState.setMeetingBoundaries`: Invalidate derived claims even when no complete segment survives.

#### Retry resumes from latest artifact; transcribed meetings only re-summarize
`AppState.retryProcessing`: Resume from the latest durable artifact. If transcription already
succeeded, Retry fixes only summarization; missing transcripts still run
the complete pipeline. User-initiated work may download missing models.

#### Parked jobs re-enter queue and re-park; nothing downloads from here
`AppState.processMeetingsWaitingForModels`: Meetings parked because a model was missing re-enter the queue; jobs
whose models are still missing simply park again — nothing downloads
from this path.

#### Voice learning serialized, waits during record/process, never downloads voice model
`AppState.learnSpeakerVoices`: Remembers the voices named in saved meetings and suggests names for
speakers in recent meetings. Runs after any earlier pass, waits while
LokalBot records or processes, and never downloads the voice model.

#### Dictation gets recent attendee and project names as vocabulary prompt
`AppState.dictationTranscriptionSettings`: Dictation has no meeting of its own, so prompt-capable speech models
receive recent attendee and project names beside the manual vocabulary.

#### One invalidation route for every meeting-evidence write
`AppState.primaryEvidenceDidChange`: One invalidation route for every meeting-evidence write. Processing and
user outcome edits both reach this path, so derived Digest, Dream,
export, and routine surfaces cannot silently diverge.

#### Only meeting changes widen Dream comparison window; screen change discarded two weeks of reports
`AppState.primaryEvidenceDidChange`: Meetings feed later days' comparison windows; screen, activity, and
coding-agent evidence is read only for its own day. Treating a
screen change as a meeting change made every retention pass
discard two weeks of Dream reports.

#### Learned facts and goals go with the meeting they came from
`AppState.primaryEvidenceDidChange`: Learned facts and goals go with the meeting they came from.

#### Reprocessing revises digest, marks stale instead of deleting (2026-10-07 incident)
`AppState.meetingArtifactsWillChange`: Reprocessing revises a meeting; it does not delete it. On 2026-10-07 a
summary rerun started 17 s after a manual digest and removed it before
any new notes existed. The digest now stays, marked out of date, until
it is regenerated.

#### Revisions keep digest marked out of date until regenerated
`AppState.EvidenceChange.revision`: Reprocessing, corrections, outcome edits, saved moments, and
re-read agent sessions. The digest stays, marked out of date,
until it is regenerated.

#### Deleting source withdraws its unedited generated digest (PRIVACY.md)
`AppState.EvidenceChange.removal`: The person deleted the source. Its unedited generated digest is
withdrawn with it (PRIVACY.md).

#### Retention expiry does not invalidate long-term digests, Dream reports, work memory
`AppState.withScheduledRetention`: Scheduled retention expires screen text, titles, and agent sessions on
their own clock; nobody deleted or corrected them. Day digests, Dream
reports, and work memory are long-term memory: they outlive the screen
window and go only when a source is deleted, or the memory is cleared.
Before, every pass wiped nearly all Dream memory, because each memory
change inherits the sources of every other item, and each expiring day
lost its digest.

#### Do not reconsider digest after retention; rebuilt one would replace fuller
`AppState.scheduledRetentionDidRemoveEvidence`: The digest is not reconsidered: rebuilt from what retention left, it
would replace the fuller one.

#### Titles cleared by retention disappear from paired devices
`AppState.scheduledRetentionDidRemoveEvidence`: Titles retention cleared disappear from paired devices too.

#### Deleted meeting withdraws every project note citing it
`AppState.withPrimaryEvidenceChange`: A deleted meeting withdraws every project note that used it.

#### Deleted or corrected evidence must not survive in reused digest answers
`AppState.purgeDigestSegmentAnswers`: Deleted or corrected evidence must not survive in reused digest answers.

#### Rewrite past day's note only while whole day retained
`AppState.dayDigestChanged`: Export may have run while the replacement digest was still awaiting
a model. Reopen consumers after the journal and provenance are saved.
A past day's note is rewritten only while all of that day is still
retained: a digest rebuilt from what retention left would replace
a fuller note.

#### Dream reads finished days only; past-day digest regeneration revokes that day's report
`AppState.dayDigestDidChange`: A dream only reads finished days' digests. Today's digest is
refreshed many times a day and no report depends on it yet; a past
day's regenerated digest revokes exactly that day's report.

#### In-flight dream self-checks at commit; only dreamed-day changes stop it early
`AppState.invalidateDreams`: An in-flight dream is checked against its own sources when it
commits, so only a change to the day being dreamed stops it early.

#### mutateEvidence hook is for scheduled retention only; explicit deletions use primary path
`AppState.applyTrackingSetting`: Only the scheduled retention pass calls this hook; explicit
deletions go through `withPrimaryEvidenceChange` directly.

#### When recognition answers again, Files re-reads skipped screenshots immediately
`AppState.textRecognitionDidChange`: While it was stalled, Files left the screenshots and scans it could
not read (`FileTextRecognition`). It answers again: read them now,
not at the next change in a folder.

#### Refused new shortcut falls back to previous, else turns Ask shortcut off
`AppState.applyQuickRecallSetting`: `previous` is the shortcut to fall back to when a newly chosen one is
refused; without one, a refused shortcut turns Ask's shortcut off.

#### Pause global shortcuts while recording one so every combination reaches recorder
`AppState.setShortcutRecording`: Settings is recording a new shortcut. Pause the global ones so every
combination reaches the recorder, including one that is already taken.

#### Ask and selection hot keys registered only on interactive launch
`AppState.setShortcutRecording`: Ask's and selection actions' hot keys are only registered on the
interactive launch path.

#### Past day's file is user's; stays untouched and unreported
`AppState.applyDailyMemoryExportSetting`: A past day's file is the user's: their own note in that
folder, or one they edited. It stays as it is, and no later
export touches it, so there is nothing to report.

#### Turning off keeps saved evidence; deletion is explicit
`AppState.applyCodingAgentEvidenceSetting`: Starts or stops transcript reading. Turning it off keeps what was
already saved, like the other capture sources; deletion is explicit.

#### Turning off deletes saved copies since they only mirror agents' files
`AppState.applyCodingAgentNotesSetting`: Starts, restarts or stops note reading. Turning it off deletes the
saved copies: they only mirror the agents' own files.

#### Headless runs and test hosts never read agents' folders
`AppState.applyCodingAgentNotesSetting`: Headless runs and test hosts never read the agents' folders.

#### Reader gets settings choice only after setup finished, nothing before
`AppState.codingAgentConfiguration`: What the coding-agent reader may read: the settings' choice once setup
is finished, and nothing on a new install before then.

#### Reading starts at finish since new install read nothing before
`AppState.finishOnboarding`: Setup's final step: applies its choices and marks setup finished. A
new install has read no coding-agent session until now, so reading
starts here if the person kept it on.

#### Setup may finish via CLI; first finish starts reading now, not next launch
`AppState.markSetupFinished`: Setup is finished, here or by an agent through `lokalbot-cli setup
finish`. Coding-agent sessions are not read before this, and the
first time, reading starts now rather than at the next launch.

#### Unit tests share real preferences, so skip clearing resume store
`AppState.markSetupFinished`: Nothing is left to resume. Unit tests share the real preferences.

#### Late agent work reopens yesterday's digest; new work lands today
`AppState.codingAgentEvidenceDidChange`: New settled work usually lands today, before the evening digest.
Yesterday may already be final, so late work reopens it.

#### Delete saved bursts only; agents' own transcripts never touched
`AppState.deleteCodingAgentEvidence`: Stops reading coding-agent sessions and deletes every saved burst.
The agents' own transcripts are never touched.

#### Scheduled background digest never triggers model download
`AppState.applyDayDigestSetting`: Scheduled background work never triggers a model download —
the digest waits until the Think model is actually on disk
(or a remote backend is configured).

#### Debug capture trace is scrubbed and written to diagnostics/capture-traces
`AppState.startCaptureTraceRecording`: Debug menu: records the live capture environment for `seconds`, then
writes a scrubbed trace to diagnostics/capture-traces and reveals it.

#### Mail download scope: attendees in email window plus two weeks ahead
`AppState.emailAttendeeAddresses`: People whose mail threads qualify for download: attendees of meetings
in the email window and the next two weeks, from the calendar (when
calendar use is on) and from recorded meetings.

#### Headless runs and UI test host never read chosen folders
`AppState.applyFileSearchSetting`: Starts, re-reads or stops Files. Headless runs and the UI test host
never read the chosen folders.

#### Agent-searchable folders follow the folders Files reads
`AppState.applyFileSearchSetting`: The folders agents may search follow the folders Files reads.

#### Persist opt-in start so catch-up never backfills all history
`AppState.applyDreamingSetting`: Persist the beginning of each opt-in period. This keeps catch-up
bounded instead of interpreting a first launch as permission to
backfill every historical workday.

#### Overnight dreaming never triggers model download on fresh install
`AppState.applyDreamingSetting`: Overnight dreaming is background automation: never let it
trigger a model download on a fresh install.

#### Learn up to three items after review; best effort, failure never affects review
`AppState.learnAboutPerson`: After the overnight review: learn up to three facts, goals, or
suggested preferences from what the person said in that day's
meetings. Best effort; a failure never affects the review itself.

#### Goals and projects kept for weeks promoted without a model call
`AppState.learnAboutPerson`: Goals and projects kept for weeks need no model call.

#### Skip re-reading unchanged lines since rebuilds would only reword same items
`AppState.learnAboutPerson`: The review rebuilds a day whenever one of its sources changes.
Reading the same lines again would only reword the same items.

#### Local embedder verifies translated items; without semantic search they are dropped
`AppState.learnAboutPerson`: The local embedder checks items the model translated (a Serbian
line, an English item); without semantic search those are dropped.

#### Day's dictation is removed after its pass and never kept
`AppState.learnAboutPerson`: Read once, then gone: the day's dictation is never kept past its pass.

#### Check claim's quoted line still exists in source as person's own words
`AppState.learnedClaimSourceStillQuotes`: For a learned claim whose source changed: does the source still have
the line the claim quotes, as the person's own words? Reads only that
one meeting's transcript, that day's agent requests, or work memory.

#### Week/month summaries: stale removed always, new written only with full screen history, once nightly
`AppState.rollUpReviews`: After the overnight review: refresh the one-line week and month
summaries the agent briefing shows below recent days. Stale lines are
always removed; new ones cost a model call, so they are written only
while agents may read all retained screen history, which the
briefing's older timeline needs, and at most once a night. Best effort.

#### Rollup lines only show to agents with full retained screen history
`AppState.rollUpReviews`: The briefing shows week and month lines only to agents allowed all
retained screen history; for a shorter window they would never show.

#### Off deletes all kept dictation; on prunes expired
`AppState.applyDictationLearningSetting`: Off deletes every kept dictation at once; on drops expired ones.

#### Forget everything also drops unread dictation
`AppState.forgetDictationForLearning`: Personal Context → Forget everything also drops dictation not yet read.

#### Dreaming starts at yesterday so opt-in never backfills older days
`AppState.dreamingFirstEligibleDayKey`: Turning dreaming on starts at yesterday, so a new opt-in never
backfills older days; turning it off clears the boundary. Shared with
changes made from the terminal.

#### Assign only on change to avoid re-rendering all AppState observers
`AppState.refreshDreamMemory`: Evidence changes and every Settings visit reload this; an unchanged
memory must not re-render every AppState observer.

#### Clear work memory restarts dreaming from today so prior week is not re-dreamed
`AppState.clearDreamMemory`: Settings' "Clear work memory": stops a dream in progress, deletes every
report and the work memory, and dreams only from today on, so the week
before the clear is not re-dreamed straight back into memory.

#### Settings assignment reapplies schedule via observer
`AppState.clearDreamMemory`: reapplies the schedule through the settings observer

#### Revoke every source's speaker contributions; delete parent last for partial failure
`AppState.deleteMeetings`: Revoke every retained source's profile contributions,
not just those of the generated parent. Delete the
parent last so partial failure cannot restore sources.

### `LokalBot/HeadlessCommands.swift`

#### Parse headless flags before SwiftUI; commands run in normal launch then exit
`HeadlessCommand`: A `LokalBot --flag` subcommand. Parsed once, in `LokalBotMain.main()`,
before SwiftUI launches — so argument handling never lives inside
`AppState`, and the parse itself is a pure, testable function.

The commands still execute inside the normal app launch (they need the
main run loop for audio, timers, and screen capture); each schedules its
work and calls `exit()` when done.

#### Benchmark production autocomplete runtime before SwiftUI, no settings or library
`HeadlessCommand.cotypingEngineBench`: `--cotyping-bench --model-path <gguf> [--passes N]`: the benchmark on the
production autocomplete runtime and that model. Runs before SwiftUI
launches, with no settings, library or window.

#### Print saved autocomplete counters before SwiftUI from one preference
`HeadlessCommand.cotypingMeasurements`: Print the saved autocomplete counters and typing measurements and exit.
Runs before SwiftUI launches and reads one preferences value.

#### Print installed keyboard and mouse hooks before SwiftUI, no library
`HeadlessCommand.eventTaps`: Print the keyboard and mouse hooks installed on this Mac, by app, and
exit. Runs before SwiftUI launches and reads no library.

#### Reads transcripts only, so needs no window, lock, or subsystem
`HeadlessCommand.agentSessions`: Print a day's coding-agent evidence and exit. Runs before SwiftUI
launches: it reads transcripts only, so it needs no window, library
lock, or app subsystem.

#### Set by LokalBotMain.main and consumed by AppState.init
`HeadlessCommand.requested`: Set by `LokalBotMain.main()`; consumed by `AppState.init`.

#### Require canonical past day so dream watermark never passes future days
`HeadlessCommand.validatedDreamTarget`: Resolve the CLI's optional day without allowing a current/future day
to advance the durable memory watermark past days that have not yet
happened. Requiring the canonical key also rejects normalized dates
such as 2026-02-30 and ambiguous shorthand such as 2026-7-2.

#### Read-only view of day digest agent evidence for inspecting readers
`CodingAgentSessionsCLI`: `LokalBot --agent-sessions [yyyy-MM-dd]`: the evidence the day digest
would receive from local Claude Code and Codex sessions, for inspecting
the transcript readers against real data. Read-only; nothing is stored.

#### Headless test hooks for CI and e2e share UI code paths
`HeadlessCommandRunner`: Executes headless subcommands against the app's real subsystems (pipeline,
indexes, recorder). Test hooks for CI and `Scripts/test/e2e.sh` — the same code
paths as the UI, no window required.

#### Agent sessions, cotyping measurements, event taps normally handled before launch
`HeadlessCommandRunner.run`: Normally handled before launch by `LokalBotMain`.

#### --summary-only keeps transcript; lets pipeline run in CI without UI
`HeadlessCommandRunner.runProcess`: `LokalBot --process <meeting folder>`: run the pipeline headless and
exit. Add `--summary-only` to keep the current transcript, matching the
Re-summarize button. Lets the pipeline be exercised (and CI-tested)
without the UI.

#### Poll pipeline until job leaves stage table; exit 0 done, 1 failed
`HeadlessCommandRunner.waitForPipeline`: Polls the pipeline until the job leaves the stage table, then exits
0 when it finished or 1 when it failed.

#### Test hook applies boundaries as review UI does, awaits reprocessing
`HeadlessCommandRunner.runSetBoundaries`: Test hook: apply a reviewed meeting boundary exactly as the review UI
does, then wait for the re-transcription and summary to finish.

#### Health defaults to yesterday; exit 0 pass/warn, 1 fail, 2 bad day
`HeadlessCommandRunner.runHealth`: `LokalBot --health [--day yyyy-MM-dd] [--json]`: evaluate one day
(default: yesterday), write the report, print it. Exit 0 pass/warn,
1 fail, 2 invalid day.

#### Debug-only capture trace; use throwaway LOKALBOT_STORAGE_ROOT
`HeadlessCommandRunner.runRecordCapture`: `LokalBot --record-capture <seconds> [--scenario name]` (Debug only):
runs tracking, screen capture, and meeting detection with the
recording environment, then writes a scrubbed trace. Use a throwaway
`LOKALBOT_STORAGE_ROOT`: captures land in that library.

#### Shot test exit codes: 0 ok, 3 skip, 1 fail
`HeadlessCommandRunner.runShotTest`: `LokalBot --shot-test`: one screenshot capture, exit 0 ok / 3 skip / 1 fail.

#### LOKALBOT_DIGEST_MODEL_ID is headless-only; never changes saved model
`HeadlessCommandRunner.runDigest`: `LokalBot --digest [yyyy-MM-dd]`: generate a journal digest and exit.
`LOKALBOT_DIGEST_MODEL_ID` is a headless-only evaluation override; it
never changes the persisted model selection.

#### Headless dream bypasses scheduler gates like Dream now
`HeadlessCommandRunner.runDream`: `LokalBot --dream [yyyy-MM-dd]`: dream one day (default: yesterday) and
exit. Bypasses the scheduler's hour/downtime/power gates like "Dream
now" — the caller explicitly asked. Test hook for the dreaming
pipeline, same spirit as --digest.

#### Test hook runs meeting chat agent once against real engine and tools
`HeadlessCommandRunner.runChat`: `LokalBot --chat "<question>"`: run the meeting chat agent once against
the real engine + tools and print the answer. Test hook for the chat
assistant, same spirit as --search / --digest.

#### Agent test hook auto-approves file changes, declines sensitive requests; exit codes 0/3/1
`HeadlessCommandRunner.runAgent`: `LokalBot --agent "<prompt>"`: one Agent Mode turn against the real
runtime + Main LLM engine, auto-approving file changes (read-only
library lookups run unasked with a model on this Mac, as in every task) and declining other
privacy-sensitive shell/external-read requests, then printing each transcript
item. Exit 0 ok / 3 skip (runtime not installed) / 1 fail. Test hook
for Agent Mode, same spirit as --chat.

#### Scriptable cotyping check without learned history or Keychain; exit 0 on pass
`HeadlessCommandRunner.runCotypingBench`: `LokalBot --cotyping-bench`: run the cotyping quality benchmark headless
against the real engine and print one JSON document — the scriptable
face of the in-app "Run cotyping check" (same scenarios, same criteria),
excluding learned writing history so fixture runs need no Keychain access.
Exit 0 when every scenario passes its safety contract, 1 otherwise.

#### Synthetic measurements must not init learning store or ask Keychain
`HeadlessCommandRunner.runCotypingBench`: Synthetic engine measurements must not initialize the live
coordinator's learning store (or ask for its Keychain key).

#### Test hook prints Recall FTS screen hits; exit 1 when none
`HeadlessCommandRunner.runSearchScreen`: Test hook: `LokalBot --search-screen <query>` prints screen-text hits
from the FTS search the Recall view uses; exit 1 when there are none.

### `LokalBot/LokalBotApp.swift`

#### Disable window restoration pre-launch for menu-bar-only start
`LokalBotMain`: Process entry point. Parses any headless subcommand before SwiftUI exists,
and disables AppKit window restoration *before* SwiftUI launches when
starting menu-bar-only — `applicationWillFinishLaunching` runs after AppKit
has already read the flag, so a previously-open window would be restored
and force the Dock icon back on. Setting it pre-launch is the only
reliable point.

#### Library lock held for the process lifetime
`LokalBotMain.libraryLock`: Held for the process lifetime; see `LibraryInstanceLock`.

#### Synthetic cotyping replay runs before migration; remote replay sends prompts out
`LokalBotMain.main`: Explicit synthetic replay runs before migration, AppState, permissions,
learning, or capture. Only the supplied fixture and model are read; a
remote replay sends the fixture's prompts to the endpoint it names.

#### Radar replay uses public or synthetic transcripts, no library or Keychain
`LokalBotMain.main`: Public or synthetic transcripts only; reads no library and no Keychain.

#### Cotyping measurements read one preference; no library, lock, or window
`LokalBotMain.main`: Reads one saved preferences value; needs no library, lock or window.

#### Filter FluidAudio logs because they can contain recognized words
`LokalBotMain.configureDependencyLogging`: FluidAudio debug/notice lines can contain recognized words. Filter them
from both unified logging and stderr, including headless commands.

#### Never build AppState after incomplete migration; avoids persistent library conflict
`LokalBotMain.routeStartup`: Never construct `AppState` after an incomplete migration: its stored
`StorageManager` creates the destination library and turns a transient
failure into a persistent old/new conflict on the next launch.

#### Minimal recovery mode with no AppState, storage, indexes, capture, or workers
`MigrationRecoveryApp`: A minimal process mode for retained migration failures. It deliberately has
no `AppState`, storage, indexes, capture services, or background workers.

#### AppState held not observed; windows observe it themselves, created once
`LokalBotApp.app`: Held, not observed: the scenes and menus read `scene`, and each window
root observes AppState itself. Created once, as the App is.

#### Unified toolbar style keeps one height when sections remove system title
`LokalBotApp.body`: Meetings, Timeline, People, Projects and Agent remove the system
title to put their own in the toolbar. Left to itself the toolbar
then turns compact (38 pt, not 52), so the sidebar and content
jumped 14 pt when switching sections. One style keeps one height.

#### Cmd+K opens Quick Recall, registered app-level for every window
`LokalBotApp.body`: ⌘K opens Quick Recall, the window the system-wide shortcut opens:
search, commands and Ask in one place. Registered at the app
level so it works from any LokalBot window.

#### Settings item and Cmd+, open LokalBot's own Settings window
`LokalBotApp.body`: The standard Settings item and ⌘, open LokalBot's own Settings
window; `openSettings` also lands deep links on a page of it.

#### Settings is an id Window opened by id, including menu-bar-only mode
`LokalBotApp.body`: Settings has its own window, so the main window stays on your work.
A `Window` with an id, not a `Settings` scene: `WindowAccess` opens
it by id from the menu bar extra, deep links and the app delegate,
also while LokalBot runs with only its menu bar icon.

#### One worker owns FTS connection; latest snapshot per meeting; serialized writes
`SearchIndexWorkQueue`: One long-lived utility worker owns the background FTS connection. A
dictionary keeps only the latest pending snapshot for each meeting, while
the actor serializes SQLite writes across the entire queue.

#### Restore serialized with late cleanup from the original merge
`SearchIndexWorkQueue.restore`: Reopens a source folded into a merged meeting and queues its existing
evidence for indexing again. The actor serializes this with any late
cleanup request from the original merge.

#### Yield between meetings so enqueues coalesce without concurrent SQLite writers
`SearchIndexWorkQueue.drain`: Let enqueues, deletions, and shutdown coalesce or cancel work
between meetings without allowing concurrent SQLite writers.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
