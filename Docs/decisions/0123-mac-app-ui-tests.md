# 0123. Mac app UI tests

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBotUITests/`.

## Decisions

### `LokalBotUITests/AgentModeUITests.swift`

#### Hosted-only; fixture disables warm-up, subprocesses, tools and network
`AgentModeUITests`: Runs only on the hosted UI runner. The fixture opts out of model warm-up,
subprocesses, capabilities, real tool execution, and network requests.

#### Copy, retry and more actions exist only on a finished turn's answer
`testFindAndResultsKeyboardCommands`: Copy, retry and more belong to the answer a turn ends with, so end the turn first.

#### Default center click can land on fixed approval dock for long text views
`testResponseSelectionCopiesAcrossHeadingsListsAndCode`: A long text view can extend beyond its scroll viewport. XCTest's
default center click can otherwise land on the fixed approval dock.

#### Real edge drag needed; startup capture misses content-driven window minimums
`testLongSavedConversationCanShrinkWithoutClippingActions`: Exercise an actual edge drag after opening long history. A startup
capture at a small size misses content-driven native window minimums.

#### Agent window floor is about 751 pt on macOS 15, 767-775 on 26
`testLongSavedConversationCanShrinkWithoutClippingActions`: With the sidebar shown, Agent's floor is the sidebar (216 pt, about
8 pt more on macOS 26.6) + task column 200 + conversation 350 +
divider: about 751 pt on macOS 15, 767-775 pt on macOS 26 and later.

#### Query toolbar's direct child to avoid nested AX wrapper
`testLongSavedConversationCanShrinkWithoutClippingActions`: Query the toolbar's direct child to avoid its nested AX wrapper.

#### macOS reports a static text's words as value, not label
`AgentModeUITests.taskRowText`: What VoiceOver reads for the first task row: its title and its status.
The row is one static text, and macOS reports a static text's words
as its value, not its label.

### `LokalBotUITests/AutocompleteRehearsalUITests.swift`

#### Rehearsal sheet uses demo mode fixed suggestions, no model involved
`AutocompleteRehearsalUITests`: Hosted regression checks for the Autocomplete rehearsal, which is the
page header's "Try it…" sheet: it must accept, keep, and discard a
suggestion the way autocomplete does in another app. The host's demo
mode supplies fixed suggestions, so no model is involved.

#### With One word selected, Tab once inserted the whole suggestion
`testTabTakesOneWordAndKeepsTheRest`: With "One word" selected, one Tab used to insert the whole suggestion.

#### Visible text is on for new installs only; older settings keep it off
`testRehearsalShowsItsSampleConversationAndContextSources`: Every optional source is off, and the rehearsal says so. Visible text
is on for new installs only; these saved settings predate the key,
like an existing install's, so it stays off.

#### Ghost suggestion is painted, so read from the Insert control
`AutocompleteRehearsalUITests.waitForGhost`: The suggestion is painted, not typed, so it is read from the control
that would insert it.

### `LokalBotUITests/BackgroundFlowUITests.swift`

#### Stub serves committed GLM recordings from scenario.json made by day-in-the-life script
`BackgroundFlowUITests.startModelStub`: Starts the Bun stub with the committed GLM notes/digest recordings
(`Fixtures/background/scenario.json`, produced by
`Scripts/test/day-in-the-life/scenario.py`) and returns its base URL.

### `LokalBotUITests/ChatHistoryUITests.swift`

#### App expects a meetings directory; chat history lives under chats
`ChatHistoryUITests.setUpWithError`: The app expects a `meetings/` dir; chat history lives under `chats/`.

### `LokalBotUITests/CotypingSettingsUITests.swift`

#### Legacy cotyping keys stay internal; user-facing language is Autocomplete
`CotypingSettingsUITests`: Hosted coverage for autocomplete inside Settings → Autocomplete.
The legacy cotyping keys remain internal; user-facing language and routes
are Autocomplete throughout.

### `LokalBotUITests/DictationSettingsUITests.swift`

#### Fixture GGUF runs real digest checks without loading a model
`DictationSettingsUITests.setUpWithError`: Exercise the real preparation and digest checks without loading a
model or downloading weights. This fixture is only used for selection.

#### Dictation header shows one line per missing need; permissions live in Privacy
`testEnablingGlobalShortcutRevealsPermissionRepairRows`: The page header says where Dictation stands: "Off" while the switch
is off, and once it is on, one line for each thing it still needs,
with the button that asks for it. The page has no permission list
of its own any more; Privacy & permissions is the one home for those.

### `LokalBotUITests/HostedDisplay.swift`

#### Mouse-driven tests need real hosted desktop; native self-captures can rasterize off-screen
`HostedDisplay`: Interactive layout checks need their windows on the real hosted desktop.
Native self-captures can rasterize off-screen; mouse-driven tests cannot.

#### CI configures desktop before XCTest; XCTest does not inherit shell env vars
`HostedDisplay.prepareForModelLayouts`: CI configures the desktop before XCTest starts. XCTest does not
inherit ordinary shell environment variables such as GITHUB_ACTIONS.

### `LokalBotUITests/MainWindowUITests.swift`

#### UI tests run in a host that skips side-effectful startup and a synthetic library
`MainWindowUITests`: End-to-end UI tests that drive the dedicated `LokalBot UI Test Host`
against a synthetic meetings library planted on disk before launch.

The app sees `LOKALBOT_UI_TEST=1` and skips every side-effectful
startup path (Core Audio polling, accessibility-trusted detector,
Sparkle, screenshots), so the suite needs no TCC permissions and
never touches the user's real library.

#### Wait for Today header so tests start from a known surface
`MainWindowUITests.setUpWithError`: Wait until the main window has rendered Today's header —
every test starts from a known surface, otherwise XCUITest races
the initial `loadMeetings()` + reindex sweep. (Today is the
default section, so the meeting list is NOT on screen yet.)

#### Today shows digest highlights; tasks, sessions, export stay on Timeline; Record in toolbar
`MainWindowUITests.testTodayUsesCompactDigestHierarchy`: Today's sections are panels. So far today shows the digest's
highlights and, in its footer, one line about when it was written.
Tasks, sessions, digest export and the activity log stay on Timeline,
and Record is in the toolbar instead of a bar on the page.

#### Quick Recall field must update query once per printable key
`MainWindowUITests.testCommandPaletteDoesNotDuplicateTypedCharacters`: ⌘K opens Quick Recall, which took over the command palette. Its field
uses one AppKit field-editor path, as the palette's did: a printable
key must update the query exactly once rather than also travelling
through the list's navigation-key handler.

#### Toolbar toggle must really drive NavigationSplitView column visibility
`MainWindowUITests.testToolbarToggleHidesAndRestoresSidebar`: The native toolbar item must do real work in both directions. This
guards the recent split-view stabilization against a control that is
present but detached from NavigationSplitView's column visibility.

#### Sidebar content must stay at window edge despite oversized restored column
`MainWindowUITests.testSidebarStaysAtLeadingEdgeAfterColumnResizeAndToggle`: The sidebar content must stay attached to the window edge even when
AppKit restores or accepts an oversized first split column. A fixed-
width child centered in that column creates the blank gutters this
test is intended to prevent.

#### Footer inset is 10pt on macOS 15, 18pt on macOS 26.6
`MainWindowUITests.assertFooterAtLeadingEdge`: The sidebar footer's inset from the window edge: 10 pt on macOS 15,
18 pt on macOS 26.6, whose floating sidebar sits 8 pt further in. An
empty leading column, or a sidebar centered in an oversized one, moves
it by roughly the sidebar's width or more.

#### Query direct toolbar children so nested accessibility wrappers do not inflate count
`MainWindowUITests.toolbarSidebarButtons`: Query the native sidebar control among direct toolbar children so nested
accessibility wrappers cannot inflate the count.

#### System-generated sidebar toggle has only a Hide/Show Sidebar label, no identifier
`MainWindowUITests.anySidebarToggleButtons`: Any sidebar toggle among direct toolbar children, app-owned or
system-generated (the generated item has no app identifier, only a
"Hide/Show Sidebar" label).

#### Checks loadMeetings reads the on-disk shape across several meetings
`MainWindowUITests.testMeetingListRendersAllSyntheticMeetings`: Every planted fixture surfaces in the sidebar, grouped by day with
the right headers — confirms `StorageManager.loadMeetings()` reads
our on-disk shape, not just a happy-path single meeting.

#### Never click Record in tests; it reaches real audio devices
`MainWindowUITests.testMeetingListRendersAllSyntheticMeetings`: The Record toolbar button is always present; assert it exists but
never click it — recording reaches for real audio devices.

#### Settings row opens its own window; main window stays on current section
`MainWindowUITests.testSidebarNavigationSwitchesSections`: Sidebar selection swaps the content column. Settings is the exception:
its row opens the Settings window, and the main window stays on what
it was showing, ready to go to another destination.

#### All-local models share one storage/AI line; remote server splits and names host
`MainWindowUITests.testSidebarUsesApprovedRememberAndAssistantHierarchy`: With every model local, storage and AI share one line. A remote
server splits them again and names its host.

#### Find headings by identifier; static-text query missed them on hosted runner
`MainWindowUITests.testModelsSectionRendersRoleCards`: A heading's words reach XCUITest as its label, and a static-text
query did not match it on the hosted runner; its identifier does.

#### Digest cites a never-kept screen moment; source link appears only with a source
`MainWindowUITests.testTimelineRendersTrackAndOverview`: The fixture's digest cites a screen moment that was never kept. A
source link appears only when there is a source.

#### Heading not matched by static-text query on runner; use the list identifier
`MainWindowUITests.testTimelineSelectionOnlyReplacesBoundedContext`: "What was open" is a heading, which a static-text query does not
match on the runner; the list under it carries the same name.

#### Date change is one transition clearing preview and swapping track, brief, digest
`MainWindowUITests.testTimelineDateChangeRefreshesOverviewAndDigest`: A date change is one state transition for the whole day workspace: it
clears an old meeting preview and swaps the cached track, brief, and
persisted digest to the newly selected local calendar day.

#### Toolbar button appears twice with same identifier; use firstMatch
`MainWindowUITests.testTimelineDateChangeRefreshesOverviewAndDigest`: A toolbar button is exposed twice, as the toolbar's item and as
the button inside it, both with the identifier.

#### Native slider AXValue is numeric, not the formatted description
`MainWindowUITests.testMeetingWaveformExposesSliderAndSupportsKeyboardSeeking`: macOS exposes a native slider's AXValue as a number. The
formatted accessibility description is not its numeric value.

#### Scope button queries to windows; Touch Bar controls cannot be clicked
`MainWindowUITests.testMultiMeetingThreadCompletionRequiresConfirmation`: App-wide queries also include Touch Bar controls, which cannot be
clicked through the normal macOS event path.

#### Meeting detail panels fill pane beside pinned player, not a centred column
`MainWindowUITests.testMeetingDetailLeadsWithActionsAndHasFullSummaryTab`: Full detail leads with actions and keeps the full summary and transcript
in their own tabs. Each part of a tab is a panel, and the panels fill
the pane beside the pinned player instead of a centred reading column.

#### Player and panels share both edges, 24pt from pane leading edge
`MainWindowUITests.testMeetingDetailLeadsWithActionsAndHasFullSummaryTab`: The pinned player and the scrolling panels share both edges, 24
points from the pane's leading edge, whatever the scroll bar takes.

#### Calendar attendees are explicit diarization choices; email disambiguates but never becomes alias
`MainWindowUITests.testSpeakerRenameOffersCalendarAttendeeIdentities`: Calendar attendees are explicit choices for remote diarization labels;
email disambiguates the local choice but never becomes the alias.

#### Speaker name field searches suggestions: Return fills top match, second saves
`MainWindowUITests.testSpeakerRenameReturnFillsInTopSuggestion`: The name field also searches the suggestions: Return fills in the top
match, and a second Return saves it.

#### Hover opens Reprocess submenu; clicking it closes the menu
`MainWindowUITests.testMeetingProcessingActionsAreDirectToolbarButtons`: The three ways to process a meeting again sit one level down.
Pointing at the item opens its submenu; a click on it closes the menu.

#### FTS5 search reindexes on every launch; hit deep-links to meeting
`MainWindowUITests.testSearchFindsTranscriptHitAndDeepLinks`: FTS5-backed search reindexes on every launch — typing a term that
only appears in the synthetic transcripts surfaces the matching
meeting, and clicking the hit deep-links to that meeting's detail.

#### Ask test stops short of sending to avoid starting the real local LLM
`MainWindowUITests.testAskSectionRendersAndAcceptsInput`: The Ask section is reachable from the sidebar and renders its one
field with the two scope menus and the Ask button, which is enabled
once something is typed.
Stops short of sending (that would spin up the real local LLM).

#### Page heading found by identifier and read from label or value on runner
`MainWindowUITests.testAskSectionRendersAndAcceptsInput`: The page's heading is not matched by a static-text query on the
runner; it is found by its identifier and read from label or value.

#### Restored split widths must not let conversation list consume Ask workspace
`MainWindowUITests.testAskDetailResistsConversationListSqueeze`: Restored split widths from Timeline or Meetings must not let the
conversation list consume the Ask workspace. Push the detail divider
toward the window edge and verify both column constraints hold.

#### Return asks even for one word; model reply not awaited, no local LLM
`MainWindowUITests.testAskEscalationShowsConversationWithUserTurn`: ↵ asks, whether a question or a single word was typed: the page
becomes the conversation with the typed text as the user turn. A full
question is answered from the chosen sources; a keyword from its matches. The model reply itself is not awaited (no local LLM in the
test host) — the transition and the persisted user turn are the
contract under test.

#### Slow real loading path to inspect outgoing document; no audio checks player geometry
`MainWindowUITests.testMeetingSwitchKeepsReadingAnchorsAndSelectionStable`: Exercise the real loading path slowly enough to inspect the outgoing
document. No audio on the second meeting also checks player geometry.

#### Superseded in-flight selection must not replace final meeting or flash unloaded content
`MainWindowUITests.testMeetingSwitchKeepsReadingAnchorsAndSelectionStable`: Supersede the in-flight selection. Its completion must not replace
the final meeting, or flash its unloaded content in the meantime.

#### Guards selectedMeeting returning non-nil for multi-selection
`MainWindowUITests.testMultiSelectShowsAggregateState`: Cmd-clicking a second row enters the multi-select state — the detail
pane swaps to the "N meetings selected" affordance with the deletion
button and the hint copy. Guards against `selectedMeeting` accidentally
returning non-nil for sets larger than one.

#### Confirmation dialog is the only protection for recordings; this test is load-bearing
`MainWindowUITests.testDeleteConfirmationCancelsCleanly`: Cancelling the confirmation dialog leaves both the list rows and the
on-disk folders untouched — the dialog is the only friction protecting
recordings from a stray click, so this regression test is load-bearing.

#### confirmationDialog is a sheet; scope Cancel to it to avoid Touch Bar button
`MainWindowUITests.testDeleteConfirmationCancelsCleanly`: `.confirmationDialog` renders as a Sheet labelled "alert"; scope
the Cancel query to that sheet so we don't ambiguously match the
TouchBar's own Cancel button when one is present.

#### Confirm runs full delete path; safe because fixture is in throwaway tmp root
`MainWindowUITests.testDeleteConfirmedRemovesMeetingsFromListAndDisk`: Confirming runs the full destructive path — MainWindowView →
`AppState.deleteMeetings` → `StorageManager.deleteMeeting` — removing
both the list rows and the on-disk folders. Safe to actually delete:
the fixture lives in a throwaway tmp root.

#### Harness seeds legacy settings without model-selection key, so default is Pyannote
`MainWindowUITests.testNemotronSpeakerModelSelectionPersistsAndRespectsDiarizationToggle`: The harness seeds legacy saved settings without a model-selection key.

#### Sidebar identifier sits on inner Label; each item has unique sidebar.\<section> id
`MainWindowUITests.clickSidebar`: Click a sidebar entry by accessibility identifier. The identifier
lives on the inner `Label`; descend-by-id is unambiguous because
each sidebar item carries a unique identifier (`sidebar.<section>`).

#### Confirm first selection before command-click or it lands as a plain click
`MainWindowUITests.selectTwo`: Confirm the first selection committed before extending it: the
modifier-held ⌘-click can otherwise race an unsettled selection and
land as a plain click (leaving a single selection, so the aggregate
"Delete 2 meetings" button never appears).

#### Row identifier surfaces on merged StaticText; several children share it, take first
`MainWindowUITests.meetingRow`: SwiftUI surfaces the row's accessibility identifier on the merged
StaticText element after `.accessibilityElement(children: .combine)`.
Multiple children may carry the same identifier; take the first.

#### Check label and value; SwiftUI may route header text through either
`MainWindowUITests.hasDayHeader`: True when the meeting list shows a day-group header beginning with
`prefix` (e.g. "TODAY", "YESTERDAY"). Checks both `label` and `value`
since SwiftUI may route the header text through either axis.

#### Scope to staticTexts; descendants(.any) predicates are too slow for routine queries
`MainWindowUITests.textWithContent`: Match a StaticText whose visible text (`label` or `value`) contains
the fragment, case-insensitively. Scoped to `staticTexts` because
`descendants(matching: .any)` evaluates predicates against every
element type — too slow to use as a routine query.

### `LokalBotUITests/ModelsSettingsUITests.swift`

#### Hosted-only model editor tests use synthetic settings, no credentials, inference or downloads
`ModelsSettingsUITests`: Hosted-only coverage of the model role editors. Uses synthetic settings;
no credentials are saved and no inference or downloads are requested.

#### Combined picker row exposes its text through value on macOS
`ModelsSettingsUITests.testGraniteSpeech5IsOfferedAndCancelKeepsTheCurrentModel`: The combined picker row exposes its text through value on macOS.

#### SwiftUI static text is exposed through value on some SDKs
`ModelsSettingsUITests.testUnsupportedModelPreservesUkrainianAndExplainsHowToRecover`: macOS exposes SwiftUI static text through value on some SDKs.

### `LokalBotUITests/OnboardingUITests.swift`

#### Pins permission contract for default-selected day-memory layers in real wizard
`OnboardingUITests`: Drives the real first-run wizard (Choose, Allow access, Download) and pins
down the permission contract for the day-memory layers selected by default.

#### Language switch restyles open wizard in place, keeping choice and first step
`OnboardingUITests.testLanguageSwitchKeepsTheOpenWizardOnItsCurrentStep`: The language menu is on the first step only. Switching it must restyle
the open window in place: the choice made before the switch is still
there, and setup is still on its first step.

#### Stepper shows finished steps as buttons, others as labels, so names are not pages
`OnboardingUITests.assertPage`: Each step has one title, `onboarding.title`. The stepper shows finished
steps as buttons that go back; the current and later steps are plain
labels, so a step's name in the stepper does not count as its page.

#### Switch value is 1 or 0, as number or text depending on system
`OnboardingUITests.isOn`: A switch reports 1 or 0, as a number or as text depending on the system.

#### Find heading by identifier; read title only when it is the sole one during transitions
`OnboardingUITests.heading`: Whether the heading with this identifier comes to say these words. A
heading's words reach XCUITest as its label, and a static-text query
did not match one on the hosted runner, so it is found by identifier
among all elements. While one step replaces another both titles exist
for a moment; a title is read only once it is the only one.

### `LokalBotUITests/RecallInteractionUITests.swift`

#### Delete screen moments is a toggle button keeping its name, reading on when open
`RecallInteractionUITests.testRawCaptureOffersReviewedTimeRangeDeletion`: "Delete screen moments…" is a toggle button: it keeps its name and
reads as on while the range controls are open.

#### Row identifier and value are inherited by metadata; only question text has this label
`RecallInteractionUITests.testQuestionReturnWaitsForSourcesAndSubmitsOnce`: The row identifier and scoped value are inherited by its metadata;
only the question text has this label.

#### Invalid inference destination exercises saved turn and scope without model download
`RecallInteractionUITests.launch`: Invalid inference destination exercises the saved user turn and
source scope without downloading a model or contacting a server.

### `LokalBotUITests/RedesignUITests.swift`

#### Hosted-only redesign review on synthetic evidence; screenshots stay in result bundle
`RedesignUITests`: Hosted-only review of the integrated redesign against synthetic evidence.
Screenshots remain in the test result bundle; no private library is used.

#### Filmed 2026-11-05 bug: no row highlighted and selection widened list column
`RedesignUITests.testProjectsHighlightsTheOpenProjectAndSelectionKeepsTheColumnWidth`: Filmed on 2026-11-05: opening Projects showed the first project with no
row highlighted, and selecting a row widened the list column to its maximum.
Also covers a project nothing names yet: one message and the names sheet.

#### Name the other row once; the query stops matching once selected
`RedesignUITests.testProjectsHighlightsTheOpenProjectAndSelectionKeepsTheColumnWidth`: Named once: the query above stops matching a row as soon as it's selected.

#### Collect all route assertion failures; any failure still fails test and release gate
`RedesignUITests.testWorkspaceVisualMatrix`: Collect route assertion failures across the matrix for review. Any
failed assertion still fails this test and the aggregate release gate.

#### Replant fixture when matrix crosses midnight, keeping old attachment files until serialized
`RedesignUITests.testWorkspaceVisualMatrix`: A complete matrix can cross midnight. Keep Today and
Timeline populated on the new civil day, while retaining
earlier attachment files until XCTest serializes them.

#### Autocomplete opens on its settings; rehearsal is its Try it sheet
`RedesignUITests.captureRoute`: Autocomplete opens on its settings; the rehearsal is its "Try it…" sheet.

#### Return asks even for one word; keyword answer limited to listed matches
`RedesignUITests.testSearchReturnIsSilentAndExplicitAskReviewsScope`: In the field, Return asks, even for a single word. A keyword's
answer is limited to the matches that were listed, and the sources
menu names them. (A full question would read the chosen sources.)

#### Blocked model connection fails the answer with fix path and keeps matches listed
`RedesignUITests.testSearchReturnIsSilentAndExplicitAskReviewsScope`: The model connection is blocked here: the answer fails with the way
to fix it, and the matches stay listed under it.

#### Review tab jobs moved in place; test name kept so measured duration plans shards
`RedesignUITests.testMeetingReviewConnectsSpeakersOwnersEvidenceAndRefresh`: The removed Review tab's three jobs, in place: one sheet names the
unnamed voices, an action's owner is a menu on its row, and a refresh
of the summary is offered only once speaker names have changed. A ▶
time plays where it is, and the player leads to the transcript.
The test keeps its name so its measured duration still plans the shards.

#### Session page found by title; its wrapper is not an accessibility element
`RedesignUITests.testTimelineOpensDetailsOnlyForASelection`: A session's page is known by its title: the page's wrapper is not
an accessibility element of its own.

#### Command-F field searches all tabs, pinned above content; panel field makes way
`RedesignUITests.testTranscriptSearchIsPersistentAndCommandFStillFindsAcrossMeeting`: Command-F searches every tab, so its one field is pinned above the
scrolling content and the panel's field makes way for it.

#### Test name predates Review tab removal; timing plans the shards
`RedesignUITests.testMeetingCorrectionKeepsReviewWithPageSearchOpenAndClearsReturnOrigin`: An owner chosen from the row's menu keeps the reader on the summary
while page search is open, and a cited time plays in place. (The name
predates the removal of the Review tab; its timing plans the shards.)

#### Audit sheet contrast alone; window behind a sheet is dimmed until it closes
`RedesignUITests.testReviewAndSearchAccessibilityInBothAppearances`: This launch opens the sheet that names speakers. The window
behind a sheet is dimmed and cannot be used, so its contrast is
audited once the sheet has closed, a few lines down.

#### Timeline rail is not a split pane; width follows window, ideal when roomy
`RedesignUITests.testTimelineRailResizesBesideThePage`: The rail is not a split pane: its width follows the window. In a
roomy window it is its ideal width, on the trailing side of the page.

#### Rail ideal width is 352pt at smallest text size, larger by default
`RedesignUITests.testTimelineRailResizesBesideThePage`: 352 points at the smallest text size; the default is a step larger.

#### Divider positions persist in host defaults; restore opening width for next launch
`RedesignUITests.testTimelineRailResizesBesideThePage`: Divider positions persist in the host's defaults; leave the next
launch at the opening width.

#### XCTest audit checks exposed actions, not a manual VoiceOver listening test
`RedesignUITests.testMeetingMenusHaveAccessibleActionsAndOpen`: XCTest audits the exposed actions through its authorized automation
service; menu interaction below separately verifies the callbacks.
This is not a manual VoiceOver listening test.

#### Action completion and failed-save retry are covered by other named tests
`RedesignUITests.testActionSearchPreservesSelectionAndCommandClickSelectsSeveral`: Completing an action is covered by
`MainWindowUITests.testMultiMeetingThreadCompletionRequiresConfirmation`,
and a failed save and its retry by `ActionThreadRevisionTests`.

#### Large-list persistence in RedesignContractTests; dated action lists first, never default selected
`RedesignUITests.testActionSearchPreservesSelectionAndCommandClickSelectsSeveral`: Large-list persistence belongs to RedesignContractTests, which
covers 0, 40 and 400 actions without an accessibility snapshot of every row.
Two distinct actions exercise filtering and selection here. The
dated one lists ahead of the other, which is therefore never the
row the page selects by default.

#### Failure messages and details pane repeat the title; inspect only the list row
`RedesignUITests.testActionSearchPreservesSelectionAndCommandClickSelectsSeveral`: Failure messages and the details pane repeat the action title; inspect only its list row.

#### Approval question is a heading with a label; read label and value
`RedesignUITests.testAgentApprovalDescribesEffectAndDenialAndStopReachTheController`: The card asks a question that names the file. The fixture's file is
inside the library, so the card says so and shows the full path.
The question is a heading, which macOS reports with a label; plain
text reports a value. Read both, as VoiceOver reads either.

#### Deliberately invalid destination avoids model download and server contact
`RedesignUITests.launch`: Deliberately invalid destination: exercise submission and saved
scope without downloading a model or contacting a server.

#### Hover help tag obscures measured text; hover titlebar to dismiss without losing focus
`RedesignUITests.dismissHoverHelpBeforeAuditing`: Scrolling can leave the pointer over an evidence link. Its native
help tag obscures the text being measured and has no audit label.
Hovering over the titlebar preserves the current focus and menus.

#### contrastScope limits contrast audit to a sheet or popover in front of dimmed content
`RedesignUITests.auditWorkspaceAccessibility`: `contrastScope` limits the contrast audit to that element's own
descendants, for a sheet or popover in front of dimmed content.

#### Hosted Mac exposes system Touch Bar and Emoji picker outside app; ignore them
`RedesignUITests.auditWorkspaceAccessibility`: Report every app issue. The hosted virtual Mac also exposes a
system-generated Touch Bar and its Emoji picker outside our window;
neither is an app-owned control or a usable hosted input surface.

#### macOS audit samples offscreen and popover-hidden text; audit only painted unclipped text
`RedesignUITests.auditWorkspaceAccessibility`: The macOS audit also samples offscreen text and content
behind popovers. Audit only painted, unclipped text here;
each scroll region and open popover is audited separately.

#### Sheet text shares bounds with text behind it; tell apart by exact frame
`RedesignUITests.auditWorkspaceAccessibility`: Text behind a sheet can share its bounds; tell the sheet's
own text apart by its exact frame.

#### macOS 15 audit flags labels at 14:1 contrast; suppress only after pixel check
`RedesignUITests.auditWorkspaceAccessibility`: macOS 15's audit flags these labels even at measured 14:1
contrast. Suppress only after checking their rendered pixels
in this appearance; a faint or empty label still fails.

#### WCAG 1.4.3 exempts inactive controls such as Ask before typing
`RedesignUITests.auditWorkspaceAccessibility`: WCAG 1.4.3 exempts inactive controls, such as Ask before a
question is typed.

#### Accept contrast flag only if all rendered text measures at least 4.5:1
`RedesignUITests.auditWorkspaceAccessibility`: The audit also flags native sidebar rows and supporting copy
that render well above 4.5:1. Accept a flag only when every
text inside the flagged element measures at least 4.5:1 in
its own rendered pixels; faint text still fails.

#### Native menu items carry actions; the menu container has none
`RedesignUITests.auditWorkspaceAccessibility`: A native menu's items carry the actions; its container has none.

#### Scrolled content can report frame under pinned header; skip those pixels
`RedesignUITests.verifyRecallExplanationContrast`: Scrolled meeting content can report a frame under the pinned
header; its pixels there belong to the header, not this text.

#### Measure each static text or the element itself; unmeasurable capture never passes
`RedesignUITests.renderedTextPassesContrast`: Measures each static text in a flagged element, or the element itself
when it has none (combined rows). An unmeasurable capture never passes.

### `LokalBotUITests/RenderedTextContrast.swift`

#### Measures text contrast in element captures for labels the system audit flags
`RenderedTextContrast`: Measures the contrast of text in a capture of one accessibility element, for
the labels the system's contrast audit flags.

#### Dominant color is background; glyph color is top tenth contrast; halos and rules excluded
`RenderedTextContrast.ratio`: The dominant color is the background. Anti-aliasing spreads thin glyphs
over many edge shades, so the glyph color is the contrast reached by the
most contrasting tenth of glyph pixels rather than one repeated color.
Returns nil without a uniform background or enough glyph pixels, which
rejects blank captures and isolated dark pixels.

Two things in a capture are neither background nor glyph. Text drawn
over a material leaves a faint halo one or two levels off the
background (macOS 26 does this to small captions), which still counts
as background when deciding whether it is uniform. And an element such
as a toolbar title can span its whole bar, so the capture includes the
window's edge highlight and the bar's separator: a line of one color
across the capture is a rule, not text, and is left out.

#### Pixels with contrast under 1.25 against background are edge shades, not glyph
`RenderedTextContrast.ratio`: Edge shades barely distinct from the background are not glyph.

#### Small captures need a tenth of pixels as glyph, never fewer than ten
`RenderedTextContrast.ratio`: A lone digit at 1x is a few pixels wide: the "1" beside a section
title has 16 glyph pixels in an 8 by 15 capture. A small capture
needs a tenth of its pixels to be glyph, and never fewer than ten.

#### Halo pixel may differ from background by 4 per 8-bit channel
`RenderedTextContrast.haloTolerance`: How far, per 8-bit channel, a halo pixel may sit from the background.

### `LokalBotUITests/SettingsAndTimelineUITests.swift`

#### Wait on Today header, which renders unconditionally, not the meeting list
`SettingsUITests.setUpWithError`: Today is the default section; its header renders unconditionally,
so wait on it rather than the meeting list.

#### Settings Overview is a status page with no switches; rows open the setting page
`SettingsUITests.testOverviewShowsStatusAndOpensThePagesThatFixIt`: Settings opens on Overview, a status page: what needs you, where your
data is, and the shortcuts. It has no switches of its own; its rows
open the page where each thing is set.

#### Gate on Microphone row; Form section headers never match predicate queries on macOS
`SettingsUITests.testPermissionRepairPaneRendersCorePermissions`: Gate on the Microphone row, not the "Permissions" section header:
Form section headers surface as label-only StaticTexts that live
predicate queries never match on macOS, even though failure-time
AX hierarchies show them. Row texts are value-carrying and match.

#### Metrics are a lazy grid; second row may start below the fold
`SettingsUITests.testResourceMonitorRendersUsageAndModelState`: The metrics are a lazy grid; its second row may start below the fold.

#### Hosted-only test; no live capture or enrollment, isolated synthetic library
`SettingsUITests.testRememberingSpeakersIsAlwaysOnWithoutMeetNaming`: Hosted/remote Mac only, like the rest of this suite. No live capture or
enrollment is performed; the app uses an isolated synthetic library.

#### Calendar access is asked on Privacy and in Meetings header status, not its own row
`SettingsUITests.testCalendarDependentOptionsRenderWhenSeededOn`: Calendar access is asked for on Privacy & permissions, and by the
header's status line while it is missing ("Calendar access is off,
so…"). Meetings no longer has a row of its own for it: no row
titled "Calendar access" and no grant button under Calendar.

#### Timeline with no activity blocks still lists meetings
`TimelineWithoutActivityUITests`: Timeline against a fixture with no activity blocks — meetings still
populate the day's list.

#### App lands on Today; step onto Timeline explicitly before each test
`TimelineWithoutActivityUITests.setUpWithError`: This class pins Timeline behavior; the app now lands on Today, so
step onto the Timeline explicitly before each test begins.

### `LokalBotUITests/SyntheticFixture.swift`

#### Fixture mirrors StorageManager disk layout without importing app; deterministic UUIDs, text, midday dates
`SyntheticFixture`: Plants a self-contained LokalBot storage root on disk for one UI test run.
Mirrors `StorageManager`'s on-disk layout
(`meetings/YYYY/MM/dd-slug/{meta.json, transcript.json, transcript.md, summary.md}`)
without `@testable`-importing the app — the UI test bundle runs out-of-process,
so it stays decoupled and only the file shape matters.

Every meeting is deterministic: stable UUIDs, stable text, and dates anchored
to local midday so the grouping headers always read "TODAY" / "YESTERDAY".

#### Synthetic transcripts have only engine and plain segments; canonical encoding is sorted JSON
`SyntheticFixture.makeNotesPartial`: These synthetic transcripts contain only engine and plain segments,
so their canonical encoding is the sorted persisted JSON object.

#### Mirrors Meeting.folderURL(in:) so tests can assert deletes reached disk
`SyntheticFixture.Library.folder`: On-disk folder for a planted meeting, mirroring
`Meeting.folderURL(in:)` (`root/relativePath`). Lets a test assert
that a delete actually reached the filesystem, not just the list.

#### Speaker values are me or them
`SyntheticFixture.Meeting.TranscriptSegment.speaker`: "me" | "them"

#### Seed activity_blocks via SQLite C API; app creates table IF NOT EXISTS so compatible
`SyntheticFixture.seedActivity`: Seed a few `activity_blocks` for *today* straight into the shared
SQLite db so the Timeline screen has real data to render. The app
creates this table `IF NOT EXISTS` at launch, so a pre-created one is
compatible. Uses the SQLite C API directly — the bundle stays
decoupled from the app target, mirroring how the rest of the fixture
writes raw on-disk shape.

#### Adjacent days get distinct digests to prove the journal document refreshed
`SyntheticFixture.seedDayDigests`: Give adjacent Timeline days unmistakably different persisted digests.
The date-change UI test can then prove that the detail column refreshed
the journal document, not merely the track or its date picker.

#### meta.json must round-trip through StorageManager.loadMeetings
`SyntheticFixture.write`: meta.json — must round-trip through StorageManager.loadMeetings()

#### transcript.json is consumed by SearchIndex.reindex and the meeting workspace
`SyntheticFixture.write`: transcript.json — consumed by SearchIndex.reindex and the meeting workspace.

#### transcript.md must mirror ProcessingPipeline.write format
`SyntheticFixture.write`: Human-readable transcript.md (mirrors ProcessingPipeline.write).

#### Short readable recovery track exercises real player without mic or system audio
`SyntheticFixture.write`: A short readable recovery track makes the real meeting player part
of the UI fixture without reaching for microphone or system audio.

### `LokalBotUITests/UITestHarness.swift`

#### Fresh launch resets autosaved split divider positions; relaunch keeps them for persistence tests
`UITestHarness.launch`: Split views autosave divider positions in the host's own defaults,
which every test shares. A fresh launch asks the host to start from
each pane's opening width; relaunches keep positions so persistence
tests still observe them.

#### First launch on fresh runner is slow; allow 20 s for system to list host
`UITestHarness.launchAndVerify`: The first launch on a fresh runner is slow, and so is the system's
answer about it: a hosted run failed here with the host open and
drawn four seconds after it started.

#### Activate app first; click unique text coordinate, firstMatch avoids symbol identifier
`UITestHarness.clickSidebar`: A background browser or notification can briefly make otherwise
visible sidebar labels non-hittable. Bring the tested app forward,
then click the unique text coordinate. `firstMatch` also avoids the
identifier propagated to the Label's SF Symbol on newer macOS.

#### Settings row brings open window forward; other destinations close it first
`UITestHarness.clickSidebar`: Settings has its own window, which opens over the main one. Its
row brings an open Settings window forward, so there is nothing to
click then; any other destination is reached after closing it.

#### Segmented picker items are buttons on newer SDKs, radio buttons on older
`UITestHarness.selectSegment`: Select a SwiftUI segmented-picker item across the two accessibility
mappings macOS currently emits (button on newer SDKs, radio button on
older ones). Keeping this in one place makes tab tests less brittle.

#### Earlier settings page names still work; Overview opens from LokalBot row
`UITestHarness.selectSettingsCategory`: Earlier names of the pages keep working here. Overview is opened
from the LokalBot row at the top of the list.

#### Off-screen Form rows exist in AX tree but are non-hittable; scroll until clickable
`UITestHarness.scrollTo`: Scroll a lazy SwiftUI Form/ScrollView until an element can be clicked.
`exists` alone is insufficient because off-screen Form rows are often
present in the AX tree while remaining non-hittable.

#### Scroll widest scroll view, or Settings' when open, so sidebar stays put
`UITestHarness.scrollTo`: Fallback for lazily-created rows that are not yet in the AX tree.
Prefer the widest scroll view so a split-view sidebar is not moved
while the content Form remains stationary.
While Settings is open it is the window being used, in front of
the main window and its larger scroll views.

#### Clipped SwiftUI row can report hittable while click lands on fixed footer
`UITestHarness.scrollTo`: macOS can report a clipped SwiftUI row as hittable even
when its click lands on the fixed footer below its viewport.

#### Pin English so label assertions do not depend on runner language
`UITestHarness.launchAndVerify`: Follow System is the default; pin English so label assertions
don't depend on the runner's macOS language.

#### Look up host by process and bundle id, and once past deadline
`UITestHarness.waitForRunningApp`: The host once the system lists it as an application. It is looked up
through the process just started as well as by bundle identifier, and
once more after the deadline, so one slow answer does not end the wait.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
