# 0056. Mac app: Window

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Views/Window/`, `LokalBotTests/Views/Window/`.

## Decisions

### `LokalBot/Views/Window/MainWindowView.swift`

#### Native sidebar toggle and restored visibility share one binding
`MainWindowView.sidebarVisible`: Native sidebar toggle and restored visibility share the same binding.

#### Timeline's day is kept across visits to other pages
`MainWindowView.capture`: Timeline's day, kept across visits to other pages.

#### Register window opener so non-View code can open windows; onboarding triggers from AppState
`MainWindowView.body`: Let non-View code (menu bar, AppDelegate reopen) open windows.
First-run permission onboarding is now triggered from AppState.

#### Each workspace keeps its own list-and-page split rather than global navigation columns
`MainWindowView.navigation`: Every workspace keeps its own list-and-page split inside the detail
column, rather than adding global navigation columns.

#### Animate on error values so the bar enters from the bottom as the workspace yields space
`MainWindowView.navigation`: Model code sets this feedback, so animate on its values: the
bar enters from the bottom edge while the workspace above
yields its space in the same motion.

#### Reserve space so recovery feedback cannot cover composer or transport controls
`MainWindowView.errorFeedback`: Reserve space for recovery feedback so it cannot cover a workspace's
composer, transport, or other bottom controls.

#### Native selection gives one destination per row; scripted exports leave it empty
`MainWindowView.sidebarSelection`: Native source-list selection gives VoiceOver and keyboard navigation
one semantic destination per row. Section headings remain static text.
Scripted exports leave it empty; `sidebarRowBackground` marks the row.

#### cacheDisplay paints vibrancy text and highlight black; use resolved colours for scripted exports only
`MainWindowView.sidebarDestination`: `cacheDisplay` does not flatten the sidebar's vibrancy text correctly:
AppKit gives the offscreen bitmap the mask color (black) instead of the
composited label color. The selection highlight gets the same mask, a
solid black bar. Use resolved colors only for scripted exports;
normal app and UI-test windows keep the native sidebar rendering.

#### Scripted exports draw the unemphasized selection colour instead of the masked highlight
`MainWindowView.sidebarRowBackground`: Scripted exports draw AppKit's unemphasized selection color in place of
the masked native highlight.

#### Read prominence inside the row so native selection supplies its foreground
`SidebarDestinationLabel`: Read prominence inside the row so native selection supplies its foreground.

#### Observes the outcome index itself so a status change redraws only the number
`SidebarOpenActionCount`: The number of open actions that are yours. It observes the outcome index
itself, so a status change redraws this number and not the whole sidebar.

#### Settings sits at the foot as a rarely visited row and never shows selected
`SidebarSettingsRow`: Settings is a place you visit rarely, so it sits at the foot and not among
the destinations. It looks like a sidebar row and opens the Settings
window, so it never shows as selected: the main window stays where it was.

#### Reflect actual privacy posture; list each remote host once since meeting and workday text goes there
`SidebarPrivacyLine`: Reflects the *actual* privacy posture instead of a hardcoded claim. With
everything local it is one line. With a remote Think, transcription or
autocomplete server it names storage and AI separately and lists each
host once, because meeting and workday text goes to those origins.

#### While sharing is on, say the library has copies on paired phones and tablets
`SidebarCompanionLine`: While sharing is on, the storage line says the library also has copies
on the person's paired phones and tablets.

### `LokalBot/Views/Window/MenuBarRows.swift`

#### 312 points at default text size; widens with larger text
`MenuBarMetric.panelWidth`: The panel at the default text size. It widens with larger text.

#### Reset hover when a row turns disabled under the pointer, which gets no exit event
`MenuBarRowChrome`: A row that turns disabled under the pointer gets no exit event.

#### Switch row is not a button, so the pointer does not highlight it
`MenuBarSwitchRow`: A row holding a switch. It is not a button, so the pointer does not
highlight it; the switch is the control.

#### Use the window's occlusion state; the menu bar extra keeps views mounted after closing
`WindowVisibilityReader`: Reports whether the window this view sits in is on screen. The menu bar
extra keeps its panel's views after the panel closes, so appearing and
disappearing do not say whether it is open; the window's own state does.

#### Report on the next turn; it can run inside the view update that moved the view
`WindowVisibilityReader.Probe.reportCurrent`: On the next turn, with the state the window has by then: this
can run inside the view update that moved the view.

### `LokalBot/Views/Window/MenuBarStatusBlock.swift`

#### MenuBarStatus picks the state; block draws one line and colour, buttons fixed
`MenuBarStatusBlock`: The top of the menu bar panel: what LokalBot is doing, in one line and one
colour, with its buttons always in the same place under it.
`MenuBarStatus` picks the state; this draws it.

#### Timer and sound levels read the recorder itself, not AppState
`MenuBarStatusBlock.recording`: The timer and the sound levels read the recorder itself, not AppState.

#### A browser-tab call captured by process (callObservationUnavailable)
`MenuBarStatusBlock.capturesBrowserProcess`: The call is a browser tab captured by process (`callObservationUnavailable`).

#### Sound levels tick only while the panel is on screen
`MenuBarStatusBlock.isOpen`: The panel is on screen, so the sound levels may tick.

#### Record waits while a recording starts or dictation holds the microphone
`MenuBarStatusBlock.recordWaits`: A recording is starting or dictation holds the microphone: Record waits.

#### A solo event without a link may not be a call; record without its context
`MenuBarStatusBlock.content`: A solo event without a link may not be a call: it is recorded
like any other manual start, without the event's context.

#### Record the calendar event if given, else whatever call the detector sees
`MenuBarStatusBlock.recordButton`: Records the calendar event when one is given, otherwise whatever call
the detector sees, as Record now always has.

#### Narrow panel shows one participant name plus a count
`MenuBarStatusBlock.schedule`: "6:00 – 6:30 PM · Maya Chen +2": the panel is narrow, so one name
and a count stand for the people Today lists.

#### While day memory is paused the line says meetings still record; pausing never touches recording
`MenuBarStatusBlock.habitText`: What makes a recording start. While day memory is paused the line
says meetings are not: pausing never touches recording.

#### Line under another block; an error is its own message
`MenuBarAttentionWords.strip`: The one line under another block: an error is its own message.

#### Keep the settings approval row's old accessibility identifier
`MenuBarAttentionWords.init`: The name the row had before the status block took it in.

#### Levels tick only while the panel is on screen; the menu extra stays mounted after closing
`MenuBarRecordingLevels`: Whether the microphone and the call are producing sound right now, from
the health snapshot the recording strip reads, on one line. It ticks only
while the panel is on screen: the menu extra stays mounted after it closes.

### `LokalBot/Views/Window/MenuBarView.swift`

#### Status item shows record dot and MM:SS timer while recording; dims when paused
`MenuBarLabel`: The status-bar item itself. When recording it shows a record dot plus a live
MM:SS timer so a glance at the menu bar confirms a meeting is being captured
— no window required. Idle, it's the app glyph: dimmed while day memory is
paused, with a dot when something needs attention.

#### Observe AppSceneState, not AppState, so the status item redraws only when its glyph changes
`MenuBarLabel.scene`: Not AppState: the status item redraws only when its glyph can change.

#### Register window opener on the status item, the only view alive at launch
`MenuBarLabel.body`: The status item is the one view guaranteed to exist at launch in
pure menu-bar mode, so register the window opener here — otherwise
a Finder/Dock reopen (or first-run onboarding) would queue a
request with nothing alive to service it.

#### Attention dot overlays the image that already carries a template dot
`MenuBarLabel.glyph`: The image already carries the dot, in the menu bar's own
ink. Where the status item draws SwiftUI shapes, this lays
the attention colour over it.

#### Force left-to-right layout so the dot sits on the right edge in every language
`MenuBarLabel.glyph`: The dot is drawn on the right edge in every language.

#### Draw the brand glyph in code as a template image so states keep template tinting
`MenuBarIcon`: The LokalBot brand mark for the status item: a minimal robot head whose
face is a three-bar waveform — "bot" and "listens locally" in one glyph.
Drawn in code as a template image so it stays crisp at any backing scale
and picks up the menu bar's light/dark/highlight tinting for free. Its
states stay template images too: dimming is the glyph's own alpha, and
the attention dot is cut into the corner.

#### Dimmed variant means day memory is paused
`MenuBarIcon.Variant.dimmed`: Day memory is paused: the glyph is drawn faint.

#### Attention variant puts a dot on the top right corner
`MenuBarIcon.Variant.attention`: Something needs attention: a dot sits on the top right corner.

#### Fraction of glyph ink left while day memory is paused
`MenuBarIcon.dimmedOpacity`: How much of the glyph's ink is left while day memory is paused.

#### Clear ring separates the attention dot from the glyph beneath
`MenuBarIcon.badgeGap`: The clear ring that separates the dot from the glyph under it.

#### Dot box is in bottom-left image coordinates at the top right corner
`MenuBarIcon.badgeRect`: The dot's box, in the image's bottom-left coordinates: the top right corner.

#### Draw glyph in one transparency layer so crossing strokes do not darken
`MenuBarIcon.draw`: One layer, so overlapping strokes do not darken where they cross.

#### Antenna stem long enough that the knob clearly separates from the head
`MenuBarIcon.drawGlyph`: Antenna — stem long enough that the knob clearly separates from the head

#### Waveform bars are pixel-aligned so 1x rasterization keeps the gaps
`MenuBarIcon.drawGlyph`: Waveform face — bars pixel-aligned so 1x rasterization keeps the gaps

#### Menu bar dropdown is the primary surface for running LokalBot without the main window
`MenuBarView`: The dropdown shown when the menu bar item is clicked: one status block,
then rows, like a system status menu. The primary surface for running
LokalBot without ever opening the main window.

#### AppState does not republish SettingsApprovals, which the status block lists
`MenuBarPanel.approvals`: AppState does not republish these; the status block lists them.

#### nil until the window has reported visibility once
`MenuBarPanel.windowVisible`: Whether the panel's window is on screen; nil until it has been seen
there once, which shows the window reports it at all.

#### Open panel re-reads time and calendar every 15 seconds
`MenuBarPanel.refreshInterval`: How often the open panel re-reads the time and the calendar.

#### Read clock, calendar and levels only while open, since the menu extra stays mounted
`MenuBarPanel.isOpen`: The panel is on screen. The menu extra can stay mounted after it
closes, so the clock, the calendar and the sound levels are read only
while this holds: by the window's own visibility once it reports one,
by appearing and disappearing until then.

#### Register window opener so non-View code can open windows with none on screen
`MenuBarPanel.body`: Register so non-View code (AppDelegate reopen, AppState first-run
onboarding) can open windows even when none are on screen.

#### Set the clock before first frame; read calendar in a task, not during view update
`MenuBarPanel.body`: The clock before the first frame, so a recording saved long ago
is not named again. The calendar is read by the task below:
reading it can publish, which a view update must not do.

#### Recording start or save refreshes the clock so the block moves at once
`MenuBarPanel.body`: A recording that starts or is saved moves the block at once.

#### With Calendar off in Settings or macOS no meeting leads the menu
`MenuBarPanel.refresh`: The time, and today's meetings as Today reads them. With Calendar off
in Settings or in macOS there are none, and no meeting leads the menu.

#### Dictation row stops or cancels a running dictation; waits while a meeting holds the mic
`MenuBarPanel.dictationRow`: Starts dictation; while one runs, the same row stops or cancels it, as
the status block does. A meeting recording holds the microphone, so
the row waits for it.

#### Bind Cmd-comma and Cmd-Q in the panel since it is the key window while open
`MenuBarPanel.appRows`: ⌘, and ⌘Q are bound here as well as in the app menu: the panel is the
key window while it is open, also when LokalBot has no other window.

#### Observe the recording clock below AppState so the 1 Hz tick updates only this label
`MeetingRecordingTimerText`: The recording clock is intentionally observed below AppState so its 1 Hz
tick updates only this tiny label instead of every app surface.

### `LokalBot/Views/Window/WindowHandoffView.swift`

#### Note says whether anything leaves the Mac before the person presses Send
`WindowHandoffContent.targetNote`: Whether anything leaves the Mac before the person presses Send there.

### `LokalBotTests/Views/Window/HeldPaneWidthTests.swift`

#### Split pane keeps opening width until user drags divider despite SwiftUI re-division
`HeldPaneWidthTests`: A split pane with an opening width keeps it until the user drags its
divider, even when SwiftUI re-divides the split after the sibling pane's
content changes (the Timeline swapping its day column for a selection).

#### Late-landing restore must not excuse next re-division; project list stuck at maximum
`testReachingTheHeldWidthForgetsAnEarlierClampedWidth`: A restore can read as missed while SwiftUI is still applying its own
division, and land later. The width it seemed clamped to must not
excuse the next re-division: selecting a project then left its list
at the column's maximum (CI, 2026-11-16).

### `LokalBotTests/Views/Window/MainWindowMinimumSizeTests.swift`

#### macOS 26 HSplitView counts sidebar twice and titlebar plus toolbar twice
`MainWindowMinimumSizeTests`: Hosts the main window's NavigationSplitView structure in an off-screen
full-size-content window, with no autosaved split, and checks how far the
window shrinks. From macOS 26 an `HSplitView` in the detail counted the
sidebar twice in the minimum width, and the titlebar and toolbar are counted
twice in the minimum height.

#### macOS 26.6 settles 8 pt wider than 27; double-counting adds sidebar width
`testMainWindowSplitShrinksToSidebarPlusPanes`: macOS 26.6 settles about 8 pt wider than macOS 27 (885 vs 877);
counting the sidebar twice added its whole 216 pt width.

### `LokalBotTests/Views/Window/NavSectionMappingTests.swift`

#### Capture names and deep links map to sections; legacy names map to merged pillars
`NavSectionMappingTests`: The NavSection migration mapping (spec §2.1): capture names from the
UI-test host env and deep links resolve to sections, with legacy
pre-merge names mapping onto the merged pillars.

#### Settings has its own window; its names open Settings, not sections
`testSettingsNamesOpenTheSettingsWindow`: Settings has its own window, so its names are no longer sections of
the main window: they open Settings instead.

#### Renames change display names only; raw values stay for CLI and deep links
`testRenamedPagesKeepTheirIdentifiers`: Renames are display names only: raw values, which the CLI, deep links
and the saved selection use, stay as they were.

#### Settings search still matches former page names
`testSearchFindsSettingsByFormerPageNames`: Search still finds a page's settings by the name the page had before.

#### Pages renamed in feature reorganization keep old capture names
`testSettingsTabCaptureNamesSelectTheTab`: Pages renamed when Settings was organized by feature keep their
old names, and the new pages have their own.

#### Pre-split merged capture section name lands on Timeline
`testLegacyCaptureNameMapsToTimeline`: The pre-split merged "capture" section name lands on Timeline.

#### Fresh state opens on glanceable Today, not forensic Timeline
`TodayLandingTests`: The ruling's landing surface: a fresh state opens on Today, the
glanceable summary — not on the forensic Timeline.

### `LokalBotTests/Views/Window/SplitPaneBesideSidebarTests.swift`

#### macOS 26 detail runs under sidebar; list pane frame exceeds list width
`SplitPaneBesideSidebarTests`: The list-and-detail workspaces sit in the main window's detail column. From
macOS 26 that column runs under the sidebar, so the list pane's frame is
wider than the list by the sidebar's width. On hosted macOS 26 the Projects
list therefore opened at its minimum width, and selecting a project widened
it to its maximum. No divider position is saved, so nothing is written to
the preferences.

#### macOS 26 cannot lay out right-to-left split; hosted tests use splitStructureDirection
`assertListKeepsItsOpeningWidth`: As in the main window: macOS 26 cannot lay out a right-to-left split
here, and hosted unit tests run on it.

### `LokalBotTests/Views/Window/SplitPaneHoldTests.swift`

#### Selecting a row must not move the divider; SwiftUI re-divides from ideal widths
`SplitPaneHoldTests`: A real `HSplitView` in an off-screen window, laid out like the list-and-detail
workspaces. Selecting a row swaps the detail's content, which must not move
the divider: SwiftUI re-divides from the panes' ideal widths when it does.

#### Split must stay at rest or audits and tooltips never settle
`testSelectingARowKeepsTheColumnWidth`: At rest the split stays at rest, or audits and tooltips never settle.

### `LokalBotTests/Views/Window/SplitStructureDirectionTests.swift`

#### RTL split in NavigationSplitView detail crashed Settings open; hold splits left-to-right
`SplitStructureDirectionTests`: On hosted macOS 26, opening Settings after launching in Urdu or Egyptian
Arabic quit the app: a split view appearing in a right-to-left
NavigationSplitView's detail never finished updating its constraints. There
the splits are built left-to-right and their panes keep the interface's
direction.

#### Unheld arrangement is never hosted since it fails on macOS 26
`SplitStructureDirectionTests.host`: The main window's shape: a sidebar and, in the detail, a list beside a
page, in a right-to-left interface with the splits held left-to-right.
The arrangement without the hold is never hosted: hosted unit tests run
on macOS 26, where it is the one that fails.

### `LokalBotTests/Views/Window/WorkspacePresentationTests.swift`

#### Timeline page and rail fit the smallest captured 1000 pt window
`testReadingAndTimelineWidthsStayWithinApprovedPolicy`: Timeline is the day's page beside a rail. Both fit the smallest
captured window, 1000 pt, next to the sidebar, with the divider
between them, and the window can be as narrow as any other
list-and-detail page lets it.

#### Rail maximum must leave page minimum in default 1180 pt window
`testReadingAndTimelineWidthsStayWithinApprovedPolicy`: The divider can widen the rail past its opening width, but not so
far that the page loses its minimum in the default 1,180 pt window.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
