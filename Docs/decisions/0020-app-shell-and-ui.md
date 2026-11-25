# 0020. App shell and UI

- Status: Accepted
- Date: 2026-11-20

## Context

The app shell covers how the Mac app launches, lives in the menu bar and the Dock, and manages its main window, its window sizes and split panes, shared controls, Quick Recall, and how interface text is translated, laid out and drawn. The Windows and Linux app's matching pieces live in the `lokalbot-app` and `lokalbot-i18n` crates. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Launch, Dock and the main window

### Only a login launch starts menu-bar-only; a manual open shows the window

Only a login auto-start (the "Launch at login" item firing) comes up silent in the menu bar; a manual open from Finder, Launchpad, the Dock or `open` shows the main window. `applicationWillFinishLaunching` already set `.accessory` to avoid a window flash, so a manual open explicitly brings the window back as a regular, Dock-visible app, and `wasLaunchedAtLogin` is only reliable in `applicationDidFinishLaunching`. `lokalbot-cli` starting the app for a terminal request counts as a background launch: the person asked for a setting, not a window.

Where: `LokalBot/AppLifecycle.swift` (`AppDelegate.applicationDidFinishLaunching`).

### Window restoration is turned off before SwiftUI launches when starting menu-bar-only

The process entry point parses any headless subcommand before SwiftUI exists and, when starting menu-bar-only, disables AppKit window restoration before SwiftUI launches. `applicationWillFinishLaunching` runs after AppKit has already read the flag, so a previously open window would be restored and force the Dock icon back on; setting it pre-launch is the only reliable point.

Where: `LokalBot/LokalBotApp.swift` (`LokalBotMain`).

### Windows macOS restores after a menu-bar-only launch are evicted until the first explicit open

From a menu-bar-only launch until the first user-initiated open, any titled window on screen was restored or auto-opened by macOS and is evicted. `.accessory` and `ApplePersistenceIgnoreState` don't reliably stop that restore, so this is the deterministic backstop; `WindowAccess.open` ends it.

Where: `LokalBot/AppLifecycle.swift` (`DockPolicy.evictRestoredWindows`).

### Closing the last window leaves the app running

The main scene is a single SwiftUI `Window`, and SwiftUI quits the app when it closes unless the app delegate answers otherwise; closing the main window used to quit LokalBot, menu-bar-only included (issue #248). LokalBot keeps capturing in the background, so it keeps running: `DockPolicy.sync()` drops to the menu bar when menu-bar-only, and a Dock click reopens the window otherwise.

Where: `LokalBot/AppLifecycle.swift` (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed`), `LokalBotTests/AppDelegateLifecycleTests.swift` (`AppDelegateLifecycleTests.testClosingTheLastWindowKeepsTheAppRunning`).

### The main window is found by its scene identifier, not its title

`navigationTitle` retitles the window per tab (for example "Timeline"), so matching on the title silently stops finding it. Window scenes are closed by identifier too.

Where: `LokalBot/AppLifecycle.swift` (`WindowAccess.visibleMainWindow`).

### Whether the menu bar panel is open comes from its window's visibility

The menu bar extra keeps its panel's views after the panel closes, so appearing and disappearing do not say whether it is open; the window's own on-screen state does.

Where: `LokalBot/Views/Window/MenuBarRows.swift` (`WindowVisibilityReader`).

### Menu bar rows fix their vertical size after `frame(minHeight:)`

SwiftUI's `.frame(minHeight:)` reports `minHeight` as the view's minimum height even when its child is taller, and a `.window`-style `MenuBarExtra` sizes its panel to its minimum height. Without `.fixedSize(horizontal: false, vertical: true)` outside `.frame(minHeight:)` on the rows and panel, a two-line row such as **Copy last dictation** (or a single-line row at larger text sizes) shrinks to `MenuBarMetric.rowHeight` (26 pt) and clips its text against the highlight pill.

Where: `LokalBot/Views/Window/MenuBarRows.swift` (`MenuBarRowChrome`, `MenuBarSwitchRow`), `LokalBot/Views/Window/MenuBarView.swift` (`MenuBarPanel`), `LokalBotTests/Views/Window/MenuBarRowLayoutTests.swift` (`MenuBarRowLayoutTests`).

## Redraws and observation

### Published state is assigned only when it changes

Every `@Published` assignment re-renders all `AppState` observers, equal value or not, so a Settings category click assigns only what changes.

Where: `LokalBot/AppState.swift` (`AppState.selectSettingsTab`).

### `AppState` forwards recording lifecycle changes but not the one-second tick

`AppState` forwards `RecordingController`'s lifecycle changes but not its one-second `now` tick; timer labels observe the controller directly. Rebroadcasting that tick through `AppState` invalidated the entire window hierarchy.

Where: `LokalBot/AppState.swift` (`AppState.init`).

### The App observes `AppSceneState`, not `AppState`

`LokalBotApp` reads window titles, the root text size, the menu commands' titles and enablement, and the status item's glyph (recording, day memory paused, something needs attention) from `AppSceneState`. Observing `AppState` there re-ran the App body, rebuilt every menu and re-evaluated every scene on each `AppState` change, background ones such as processing progress included. The values are read again after each `AppState` change and published only when one of them differs.

Where: `LokalBot/Support/AppSceneState.swift` (`AppSceneState`).

### Settings reads health data outside drawing

The Windows and Linux Settings page redraws on every engine event, several times a second while recording, so what it shows from the database is read in `refresh_health`, not while drawing.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/health.rs` (`SettingsPage::refresh_health`).

## Window sizes and split panes on macOS 26

### The workspace minimum height subtracts the doubled toolbar

`NavigationSplitView` counts the 52 pt titlebar and toolbar in its own minimum, and the full-size-content window's root hosting view adds it again, so a 600 pt minimum kept the window at least 704 pt tall. Subtracting the second count makes the window's minimum the workspace plus one toolbar.

Where: `LokalBot/Support/DesignSystem.swift` (`View.workspaceMinimumHeight`), `LokalBotTests/Views/Window/MainWindowMinimumSizeTests.swift` (`MainWindowMinimumSizeTests`).

### A detail split states its panes' real minimum width

The minimum width of an `HSplitView` in the main window's detail column is its visible panes' minimums plus their 1 pt dividers. From macOS 26 the detail column runs under the sidebar, an AppKit split adds the sidebar's width to its own minimum, and `NavigationSplitView` adds the sidebar again, so Meetings could not shrink below about 1,100 pt. Stating the real minimum keeps the window resizable down to sidebar plus panes; `MainWindowMinimumSizeTests` checks both minimums by hosting the split structure in an off-screen full-size-content window with no autosaved split.

Where: `LokalBot/Support/SplitPaneAccessibility.swift` (`View.detailSplitMinimumWidth`), `LokalBotTests/Views/Window/MainWindowMinimumSizeTests.swift` (`MainWindowMinimumSizeTests`).

### Agent has no nested `NavigationSplitView`

The main window already owns navigation. A second, nested `NavigationSplitView` lets its inferred detail minimum grow with the transcript and can prevent the window shrinking.

Where: `LokalBot/Views/Agent/AgentView.swift` (`AgentView.body`).

### Pane widths are measured without the part under the sidebar

From macOS 26 the detail column runs under the sidebar, so the pane beside it is wider than what shows, and AppKit reports the hidden part as the pane's safe-area inset; widths are chosen, held and compared as the person sees them. Without this, on hosted macOS 26 the Projects list opened at its minimum width and selecting a project widened it to its maximum. The test saves no divider position, so it writes nothing to the preferences.

Where: `LokalBot/Support/SplitPaneAccessibility.swift` (`PaneAnchor.coveredWidth`), `LokalBotTests/Views/Window/SplitPaneBesideSidebarTests.swift` (`SplitPaneBesideSidebarTests`).

### Only a divider drag changes a split pane's width

SwiftUI can re-divide an `HSplitView` when the sibling pane's content changes: the Timeline swapping its day column for a selection's details widened the sessions rail to its maximum, so a settled pane keeps its width and any other resize is put back. A drag is told apart by the mouse event being handled, not by the resize notification, which from macOS 26 at least names a divider on plain layout passes too. A click is not a drag, so selecting a row never counts, and the drag's last step can land on its mouse-up.

Where: `LokalBot/Support/SplitPaneAccessibility.swift` (`HeldPaneWidth`, `DividerDragDetector`).

### On macOS 26 splits stay left-to-right and their panes take the interface's direction

macOS 26 mirrors the main window's `NavigationSplitView` for a right-to-left interface with the detail's toolbar squeezed into the sidebar's strip, and a split view that then appears in the detail never finishes updating its constraints: AppKit throws, and on hosted macOS 26 opening Settings after launching in Arabic, Egyptian Arabic or Urdu quit the app. A split built left-to-right has neither problem and is what changing the language in a running app leaves, so on macOS 26 the splits stay left-to-right and every pane's content takes the interface's direction back.

Where: `LokalBot/Support/SplitPaneAccessibility.swift` (`SplitStructureDirection`), `LokalBotTests/Views/Window/SplitStructureDirectionTests.swift` (`SplitStructureDirectionTests`).

## Controls, focus and input

### Workspace disclosures are a custom control with a full-width hit target

SwiftUI's native macOS `DisclosureGroup` can expose a large accessibility frame whose activation point does not toggle reliably. `WorkspaceDisclosure` keeps the same visual hierarchy and makes mouse, keyboard and UI-test activation deterministic.

Where: `LokalBot/Support/DesignSystem.swift` (`WorkspaceDisclosure`).

### Timeline's day picker keeps its relative-day label inside the toolbar button

Putting a bare `Text` (`Today` / `Yesterday`) beside the day-picker `Button` inside a single `.navigation` `ToolbarItem` `HStack` lets AppKit wrap the stack in a Liquid Glass pill with zero trailing inset, pushing the relative-day label flush against the pill edge while the leading side gets the button's native inset. Hosting the relative-day label inside the `Button` label itself gives the pill symmetric toolbar-button padding and one full-pill hit target aligned with the other toolbar items in the row.

Where: `LokalBot/Views/ScreenMemory/CaptureView.swift` (`TimelineContentView.toolbar`), `LokalBotTests/Views/Window/TimelineToolbarLayoutTests.swift` (`TimelineToolbarLayoutTests`).

### Workspace menus are native pull-down menus with explicit accessibility actions

SwiftUI's macOS 15 `Menu` proxy omits Press/Show Menu on these workspace controls.

Where: `LokalBot/Support/WorkspaceMenu.swift` (`WorkspaceMenu`).

### Focus on appear waits one turn of the main queue

From macOS 26 a focus request made inside `onAppear` is dropped while the window's content is first being installed, so `focusOnAppear`, used for windows that open ready for typing, makes its request one main-queue turn later.

Where: `LokalBot/Support/FocusOnAppear.swift` (`View.focusOnAppear`).

### Onboarding reads the title bar inset from AppKit

The geometry SwiftUI reported for the title bar was zero on macOS 26, which left the stepper in a bar of its own below the traffic lights and the window a title bar too tall. AppKit knows the inset on every system.

Where: `LokalBot/Views/Onboarding/OnboardingView.swift` (`WindowTitleBarReader`).

### A settings switch moved into the header keeps the old switch's confirmations

On Windows and Linux a header switch runs on every flip and does exactly what the page's own switch did before, confirmations included: moving a control never skips one.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/header.rs` (`HeaderSwitch.on_change`).

### Long pickers are built with `with_menu_items()`

The language list is taller than onboarding's window, and GPUI only enables scrolling automatically for `with_menu_items()`.

Where: `LinuxWindows/crates/lokalbot-app/src/ui/settings_row.rs` (`picker`).

## Quick Recall

### One AppKit responder owns the Quick Recall field's typing and list keys

Combining SwiftUI's text-field bridge with ancestor `onKeyPress` handlers can deliver the same printable key through two input paths on macOS, so a typed character arrived twice. One AppKit responder owns both text insertion and the keys that move through the list, as the ⌘K palette's field did.

Where: `LokalBot/Views/Ask/QuickRecallTextField.swift` (`QuickRecallTextField`).

### Return never runs a command that matches only inside a word

Commands that hold the typed words only inside a word come last and are never preselected; when nothing else is listed, no row is selected, so Return never runs one ("cord" must not start a recording). The arrow keys still reach them.

Where: `LinuxWindows/crates/lokalbot-app/src/windows/quick_recall/model.rs` (`selectable_rows`).

## Languages, text and fonts

### Translation applies to interface copy only

Translation lookup is never applied to user content, model prompts, serialized values, paths or protocol identifiers.

Where: `LinuxWindows/crates/lokalbot-i18n/src/lib.rs`.

### Arguments are substituted once, after translation

Named and numbered fields are replaced once, after translation; argument text is never looked up or interpreted as another template, braces included.

Where: `LinuxWindows/crates/lokalbot-i18n/src/lib.rs` (`format_in`).

### Right-to-left phrases start with the right-to-left mark

GPUI drops a number that starts a right-to-left shaped line ("39م" shows as "م", "3ح 57م" as "ح 57م"); an invisible right-to-left mark at the start keeps it. Phrases whose own text reads left to right, which is all of them in a left-to-right interface, are returned unchanged.

Where: `LinuxWindows/crates/lokalbot-i18n/src/lib.rs` (`directional`).

### Interface paragraphs break lines in logical order before shaping

GPUI 0.3.9 wraps an already-shaped line in glyph order, which is not logical text order for Arabic and Urdu and can produce overflowing, reversed rows. Plain interface paragraphs break at Unicode opportunities before shaping each display line; the source string, input editors and dependency pins are left intact, and single-line or truncated controls keep GPUI's native text element.

Where: `LinuxWindows/crates/lokalbot-app/src/ui/text.rs`.

### The interface font is Geist, with Inter for Hausa

Geist (Vercel with basement.studio, SIL OFL 1.1) is the open family that Claude Desktop's Anthropic Sans credits ("BSPK x Geist x Anthropic"); Anthropic's own fonts have no license to ship. Geist draws the letters of every interface language except Hausa's hooked ɓ ɗ ƙ, so a Hausa interface stays on Inter.

Where: `LinuxWindows/crates/lokalbot-app/src/theme.rs` (`FONT_FAMILY`).

### String tables are bundled as binary

SwiftUI resolves every label through the injected app-language locale, and Foundation re-reads the table on each such lookup; UTF-16 text tables made switching Settings categories take seconds.

Where: `LokalBotTests/Models/App/AppLanguageTests.swift` (`AppLanguageTests.testBundledStringTablesAreBinary`).

### Timeline list times use a hand-built 12-hour pattern

A Timeline list row shows "9:10" on a 12-hour clock, without AM or PM (the list sits under Morning, Afternoon and Evening) and without a leading zero; a 24-hour clock keeps its locale's own form. The pattern is built by hand because `Date.FormatStyle` with the day period omitted pads the hour ("09:10") on macOS 15 and 26.

Where: `LokalBot/Models/Timeline/TimelineDayList.swift` (`TimelineListClock`).

## Consequences

- A menu-bar-only launch must show no window and closing the window must not quit; changes to the launch path have to keep window restoration off before SwiftUI starts and the eviction backstop in place.
- Changing the main window's split structure needs checking on macOS 26 for minimum sizes, pane widths and right-to-left layouts; `MainWindowMinimumSizeTests`, `SplitPaneBesideSidebarTests` and `SplitStructureDirectionTests` cover the known failures.
- Observation is expensive: assign `@Published` values only on change, keep fast ticks off `AppState`, give the App scene its values through `AppSceneState`, and on Windows and Linux keep database reads out of drawing.
