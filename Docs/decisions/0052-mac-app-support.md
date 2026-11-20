# 0052. Mac app: Support

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Support/`, `LokalBotTests/Support/`.

## Decisions

### `LokalBot/Support/ActionAgentHandoff.swift`

#### Handoff only fills the agent's input box; nothing leaves Mac until sent
`ActionAgentHandoff`: Hands one meeting action to a coding agent installed on this Mac, with a
prompt already typed into its input box. Every route only fills the box:
nothing leaves this Mac until the user sends the prompt there.

#### 5,000 chars is Claude Code's deep-link q limit; Codex gets same
`ActionAgentHandoff.promptCharacterLimit`: Claude Code's limit for a deep link's `q`. Codex documents no limit;
it gets the same budget.

#### claude-cli://open is registered by Claude Code after first interactive prompt
`ActionAgentHandoff.Route.claudeCodeTerminal`: `claude-cli://open`: Claude Code in a new window of the terminal
it last ran in. Claude Code registers this handler itself after
the first prompt of an interactive session.

#### Codex CLI cannot prefill a prompt without sending, so only the app
`ActionAgentHandoff.Route.codexApp`: `codex://new`: a new chat in the Codex app. The Codex CLI has no
documented way to fill a prompt without sending it.

#### Links set no working folder so agent starts where it normally does
`ActionAgentHandoff.Route.url`: Each route's documented link. None sets a working folder, so the
agent starts where it normally does rather than in the library.

#### Desktop app route wins over terminal; handler resolves registered app
`ActionAgentHandoff.route`: The first route something on this Mac handles, or nil. A desktop app
wins over the terminal. `handler` returns the app registered for a link.

#### Cache installed-agent lookup a minute: menus rebuild often, handler registers late
`ActionAgentAvailability`: Installed targets, looked up at most once a minute: workspace menus
rebuild their items on every playback update, and Claude Code registers
its link handler only after its first interactive prompt.

#### Offset is where the action's first cited passage starts in recording
`ActionHandoffBrief.Source.evidenceAt`: Where the action's first cited passage starts in the recording.

#### Sources are ordered latest first
`ActionHandoffBrief.sources`: Latest first.

#### One source per meeting, latest first; files not yet existing are omitted
`ActionHandoffBrief.sources`: One source per meeting, latest first. `folder` resolves a meeting's
folder, and files that don't exist yet are left out.

#### Drop older meetings first when prompt would exceed limit
`ActionAgentHandoff.prompt`: A prompt the user can send as is. Older meetings are left out first
when the prompt would pass `limit`.

#### Handoff covers one action or every meeting an action thread appeared in
`AppState.handOff`: Opens `target` with a prompt for one action, or for every meeting an
action thread came up in. `owner` is the name the row shows.

#### Rows show You only for owner named Me on user's own work
`AppState.isUserOwner`: Rows show "You" only for an owner named "Me" on the user's own work.

### `LokalBot/Support/AppAppearance.swift`

#### macOS text styles ignore Dynamic Type; app scales own; Default is 1 pt above body
`AppTextSize`: App-wide text size. macOS text styles ignore SwiftUI's Dynamic Type, so
LokalBot scales its own text styles. Default reads one point larger than
macOS body text (14 pt); Small is the unscaled system size.

#### Menu bar panel keeps macOS sizes at Default/Small, scales relative to Default
`AppTextSize.menuBarScale`: The menu bar panel is a compact surface beside the system's own menu
bar extras, which use the macOS sizes. Default and Small keep those
sizes; larger settings grow relative to Default, so the panel no longer
reads a point larger than every other menu bar item.

#### Global scale is for AppKit-drawn text; SwiftUI reads environment instead
`AppTextScale`: The current scale for AppKit-drawn text and code that has no SwiftUI
environment. SwiftUI text reads `\.appTextScale` instead.

#### Window roots set scale; AppFont reads at render so changes redraw without rebuilding windows
`EnvironmentValues.appTextScale`: The user's text size. Window roots set it; `AppFont` reads it when a
view renders, so a change redraws text without rebuilding windows.

#### Fonts resolve against environment scale at render; unscaled maps to system style
`AppFont`: A font description resolved against the environment's text scale at
render time. The unscaled size resolves to the system text style itself.

#### For code without SwiftUI environment: AppKit bridges, attributed text
`AppFont.currentFont`: For code without a SwiftUI environment (AppKit bridges, attributed text).

#### Skip unchanged appearance to avoid re-resolving colors; capture builds keep pinned one
`AppAppearance.apply(theme:)`: Applies the theme app-wide. Capture builds that pin an appearance
through the environment keep it. Reassigning an unchanged appearance
would make every window re-resolve its colors, so it is skipped.

#### Sets global scale for AppKit text; SwiftUI follows environment
`AppAppearance.apply(textSize:)`: Keeps AppKit-drawn text in step; SwiftUI text follows the environment.

#### Every hosting root observes language, including once-created AppKit panels; preserve identity
`View.appLanguageRoot`: Every hosting root observes the same preference, including AppKit panels
whose content is created only once. Preserve child identity on changes.

#### Window roots publish text size so only text redraws
`View.appTextSizeRoot`: Window roots publish the text size; only text redraws when it changes.

#### Resolve locale once; layout direction derives from same locale
`AppLanguageRoot.body`: Resolve the preference once; the direction comes from the same locale.

#### User content keeps its own text direction regardless of interface direction
`ContentTextDirection`: User content keeps the direction of its own text rather than the
interface's, so an English transcript stays left-aligned in an Arabic or
Urdu interface and an Arabic one stays right-aligned in English.

#### First strong letter decides (Unicode bidi P2); no letters returns nil
`ContentTextDirection.layoutDirection`: The first strong letter decides, as in Unicode bidi rule P2. Text with
no letters returns nil and keeps the surrounding direction.

#### Apply after content frame so leading alignment follows text
`View.contentLayoutDirection`: Apply after the content's frame so its leading alignment follows the text.

### `LokalBot/Support/AppSceneState.swift`

#### App observes scene values, not AppState, to avoid rebuilding menus and scenes
`AppSceneState`: The AppState values `LokalBotApp` reads: window titles, the root text size,
the menu commands' titles and enablement, and the status item's glyph
(recording, day memory paused, something needs attention). The App
observes this instead of AppState. Observing AppState there re-ran the App
body, rebuilt every menu and re-evaluated every scene on each AppState
change, background ones such as processing progress included. The values
are read again after each AppState change and published only when one of
them differs.

#### Day memory on but paused dims status item
`AppSceneState.Values.dayMemoryPaused`: Day memory is on and paused for now: the status item dims.

#### Pending items from MenuBarAttention put a dot on status item
`AppSceneState.Values.needsAttention`: Something waits for the person (`MenuBarAttention`): the status
item carries a dot.

#### Nil in unit tests, which read mic as granted regardless of host
`AppSceneState.permissions`: Nil in unit tests, which then read the microphone as granted whatever
the test host was granted.

#### Subscribe synchronously; receive(on:) subscription delivers a turn late and misses changes
`AppSceneState.init`: Subscribed synchronously: `receive(on:)` delivers its subscription
a turn late and would miss changes made in between.

#### AppState does not republish approvals or permissions that the attention dot reads
`AppSceneState.init`: AppState does not republish these two, and the attention dot reads both.

#### objectWillChange fires early; read next main-queue turn, once per burst
`AppSceneState.scheduleRefresh`: objectWillChange fires before the change lands, so read on the next
main-queue turn, once for a whole burst of changes.

#### Attention items listed in the order the panel shows them
`AppState.menuBarAttention`: Everything the menu bar asks the person to fix right now, in the
order the panel lists it.

### `LokalBot/Support/AudioLevelMeter.swift`

#### One level per captured buffer; bars stay flat while mic silent or reconnecting
`AudioLevelMeter`: Recent microphone loudness for the recording HUD. The writer records one
value per captured buffer; the HUD reads the latest few at display rate.
The bars therefore move with the voice and stay flat while the microphone
is silent or reconnecting.

#### Levels older than 500 ms read as silence so stalls flatten bars
`AudioLevelMeter.maximumAgeNanoseconds`: A level older than this reads as silence, so a microphone that stops
delivering (a stall, a reconnect) flattens the bars instead of
freezing them at the last loudness.

#### Returns newest levels oldest first, padded with silence, stale as silence
`AudioLevelMeter.recent`: The newest `count` levels, oldest first, padded with silence; levels
older than `maximumAgeNanoseconds` read as silence.

#### Maps -55 dBFS to 0 and -10 dBFS to 1
`AudioLevelMeter.normalized`: 0 at -55 dBFS (room noise), 1 at -10 dBFS (loud speech).

### `LokalBot/Support/Brand.swift`

#### Brand derives from icon; app teal deeper for contrast on light materials
`Brand`: Brand identity derived from the app icon and marketing site. The icon is an
L-shaped robot on a dark slate plate, drawn in a mint→teal gradient with a
single amber antenna. The app uses a deeper primary teal than the icon so
tinted text and controls keep sufficient contrast on light materials.

#### Deep teal light, mint dark so accent text meets WCAG AA
`Brand.tealNSColor`: Primary app accent for text, icons, strokes, selection washes, and
tinted controls. Deep teal on light surfaces and a lighter mint on dark
ones, so accent text meets WCAG AA in both appearances
(`BrandContrastTests`).

#### Dark-appearance mint #6EF2DC also covers tinted dark surfaces
`Brand.tealNSColor`: \#6EF2DC; includes tinted dark surfaces

#### Light-appearance teal #075F55 for text on grouped or tinted surfaces
`Brand.tealNSColor`: \#075F55; text on grouped/tinted surfaces

#### Accent fill behind white foregrounds stays deep in both appearances
`Brand.tealFillNSColor`: Accent fill behind white foregrounds — filled buttons, badges, icon
tiles, and meeting blocks. Stays deep in both appearances.

#### Amber marks attention, remote inference and bookmarks
`Brand.amber`: Attention indicators, remote inference, and bookmarks.

#### Single semantic hook for failure and warning color, currently orange
`Brand.error`: Failure and warning text, icons, and borders. One semantic hook —
currently the system orange — so the error presentation can evolve in
one place instead of dozens of hardcoded `.orange`s.

#### Me speaker is the mic track, the user's own voice
`Brand.me`: "Me" speaker (mic track) — the user's own voice.

#### Them speaker is the system track, other participants
`Brand.them`: "Them" speaker (system track) — other participants.

### `LokalBot/Support/ContentFingerprint.swift`

#### Length prefixes prevent field-separator collisions in fingerprints
`ContentFingerprint.fields`: Length prefixes keep arbitrary source text from colliding with field separators.

### `LokalBot/Support/DesignSystem.swift`

#### Recording state uses the same red on every capture surface
`Brand.recording`: Recording state uses the same red role on every capture surface.

#### Chips are capsules; rectangles snap to shared radii
`Brand.Radius`: Shared corner radii. Chips are capsules; everything rectangular snaps
to one of these instead of a per-view magic number.

#### Compact tabs use 7 pt because height cannot fit control radius
`Brand.Radius.tab`: Compact desktop tabs whose height cannot accommodate `control`.

#### Row radius for selectable rows and compact inline cards
`Brand.Radius.row`: Selectable rows and compact inline cards.

#### Control radius for inline wells and small controls
`Brand.Radius.control`: Inline wells and small controls (text areas, thumbnails).

#### Panel radius for panels, cards, toasts and chat bubbles
`Brand.Radius.panel`: Panels, cards, toasts, and chat bubbles.

#### Card radius for hero surfaces and onboarding cards
`Brand.Radius.card`: Hero surfaces (getting-started card, onboarding cards).

#### Compact hierarchy from weight and spacing, not oversized type
`WorkspaceMetric`: A compact native-macOS hierarchy shared by every workspace surface.
Hierarchy comes primarily from weight and spacing rather than oversized
type, keeping dense meeting and evidence views comfortable by default.

#### Small rounded cards pad one step tighter than panels
`WorkspaceMetric.cardPadding`: Inner padding of small rounded cards (morning brief, outcome card) —
one step tighter than `panelPadding` panels.

#### 1360 gives compact gutter at approved 1584-point window, broad tables
`WorkspaceMetric.contentMaxWidth`: At the approved 1584-point window this leaves a compact outer gutter
while allowing the outcome tables to use the same broad working area
as the reference instead of collapsing into a narrow centered column.

#### Long-form answers stay within a comfortable reading line
`WorkspaceMetric.readingMaxWidth`: Long-form answers and summaries stay within a comfortable reading line.

#### Today's widest layout is two panel columns including side padding
`WorkspaceMetric.todayMaxWidth`: Today at its widest, side padding included: two columns of panels
under the cards that span them (`TodayColumns`).

#### Single-column Today is about a reading line plus padding
`WorkspaceMetric.todayReadingMaxWidth`: Today when its panels can only form one column: about a reading line
wide inside its side padding.

#### 52 pt is the main window titlebar and unified toolbar
`WorkspaceMetric.toolbarHeight`: The main window's titlebar and unified toolbar.

#### Metadata may be quiet; privacy and recovery text must stay readable
`WorkspaceTextRole`: Text importance is independent from layout hierarchy. Metadata may be
visually quiet; privacy, permissions, egress, and recovery explanations
must remain readable in every appearance and Increase Contrast.

#### Opaque supporting color keeps 4.5:1 where system secondary does not
`WorkspaceSupportingForegroundModifier`: Opaque supporting text stays legible on both window and inset surfaces.
Unlike tertiary/opacity-based labels, it does not fade with nested styling.
The supporting color without the role's type size, for captions and
metadata. The system secondary label drops below 4.5:1 on grouped fills
and unfocused list selections; this color stays above it.

#### One honest local/remote disclosure; callers supply copy, view owns type and color
`InferenceDisclosure`: One honest local/remote inference disclosure. Callers provide copy tailored
to the surface while this view owns readable type and semantic icon color.

#### Rare setup moments are infrequent enough to afford a spring
`WorkspaceMotionKind.milestone`: Rare setup moments: a permission granted, a model ready, an
onboarding step. Infrequent enough to afford a little spring.

#### Bottom-pinned feedback enters and leaves through the bottom edge
`WorkspaceMotion.bottomEdgeTransition`: Feedback pinned to the window's bottom edge enters and leaves through
that same edge.

#### Paged steps arrive a short distance from direction of travel
`WorkspaceMotion.stepTransition`: Paged setup steps arrive a short distance from the direction of travel.

#### Only inset controls supply fill; window and sidebar keep native materials
`WorkspaceControlModifier`: Only inset control surfaces supply their own fill. The window and sidebar
retain the platform's native background and materials.

#### Subtract toolbar height because NavigationSplitView and hosting view both count it
`View.workspaceMinimumHeight`: A main-window workspace's minimum height. NavigationSplitView counts the
52 pt titlebar and toolbar in its own minimum, and the full-size-content
window's root hosting view adds it again, so a 600 pt minimum kept the
window at least 704 pt tall. Subtracting the second count makes the
window's minimum the workspace plus one toolbar.

#### Quiet chrome for search and shell-level fields
`View.workspaceControl`: Quiet control chrome for search and other shell-level fields.

#### Docked composer surface shared by Agent and Ask
`View.composerChrome`: The docked composer surface used by Agent and Ask.

#### Applies semantic foreground and minimum readable size
`View.workspaceTextRole`: Applies a semantic foreground and minimum readable type size.

#### Supporting foreground keeps the caller's font
`View.workspaceSupportingForeground`: Readable supporting foreground that keeps the caller's font.

#### Caps prose width without constraining tables, evidence or controls
`View.workspaceReadingWidth`: Caps narrative prose without constraining tables, evidence, or controls.

#### Shared panel chrome for outcome groups and disclosures
`View.workspacePanel`: Shared quiet panel chrome for outcome groups and disclosure sections.

#### Custom disclosure because native DisclosureGroup activation is unreliable
`WorkspaceDisclosure`: An explicit workspace disclosure with a full-width hit target. SwiftUI's
native macOS DisclosureGroup can expose a large accessibility frame whose
activation point does not toggle reliably; this component keeps the same
visual hierarchy while making mouse, keyboard, and UI-test activation
deterministic.

#### Single capsule chip chrome; use BrandChip for plain icon and text
`View.chipChrome`: The one capsule-chip chrome (padding + quiet fill) shared by metadata
badges, stat pills, kind chips, and activity labels. Apply to composite
content; use `BrandChip` for the plain icon+text case.

#### Pulse ring respects Reduce Motion; color alone conveys live state
`StatusDot`: A small state-colored dot; `pulses` adds the expanding ring used by live
recording indicators. The ring respects Reduce Motion — the dot's color
alone still communicates the live state.

#### Spinner with message is the loading vocabulary; determinate uses ProgressView value
`LoadingStateLabel`: The one in-flow loading vocabulary: a compact spinner beside a quiet
description of what's happening. Determinate progress keeps using
`ProgressView(value:)`; bare spinners with no message stay bare.

#### Transient errors use toast; persistent item failures stay inline
`ErrorToast`: The one transient-error presentation: a dismissible material capsule pinned
to a window edge via `.overlay(alignment: .bottom)`. Persistent per-item
failures stay inline next to their rows; conversational errors stay in
their bubbles.

#### One caption header treatment for list groupings everywhere
`SectionHeader`: Native caption header for list groupings (meeting-list day labels,
menu-bar Recent, inspector headings) — one treatment everywhere.

#### Value uses monospaced digits so rows align
`StatTile`: Icon + value + label stat chip (timeline header stats, Type stats,
Settings metrics). The value keeps monospaced digits so rows align.

#### Search scrolls to the control and highlights it until another selection
`View.settingTarget`: Search scrolls to the exact editable control, then leaves a visible
highlight until another setting/category is chosen.

#### Custom tabs because segmented picker drew square selection and uneven segments
`ToolbarTabs`: Equal-width tabs with a sliding accent capsule, for a toolbar's principal
item. A segmented picker there drew a square selection inside the
toolbar's capsule and spread its segments unevenly at a fixed width. From
macOS 26 the toolbar's own glass is the track; earlier systems draw one.

#### Hidden semibold copy reserves width so control never resizes
`ToolbarTabs`: The hidden semibold copy reserves the selected width, so the
control never changes size as the selection moves.

#### White on deep accent when active (4.7:1); inactive uses unemphasized selection
`ToolbarTabs.knob`: White on the deep accent while the window is active (4.7:1); an
inactive window gets AppKit's unemphasized selection, like list rows.

#### Three button weights: primary filled, bordered secondary, workspaceLink quiet
`View.primaryActionButton`: Three button weights: `primaryActionButton()` for the one filled call to
action on a surface, `.bordered` for secondary actions, and
`.workspaceLink` for quiet inline actions.

#### One filled call to action per surface, white on deep accent
`View.primaryActionButton`: The one filled call to action on a surface: white on the deep accent
fill in both appearances.

#### Replaces .link whose system blue ignores app accent
`WorkspaceLinkButtonStyle`: Inline navigation and utility actions rendered as accent text. Replaces
`.link`, whose system-blue color ignores the app accent.

### `LokalBot/Support/DesignTokens.swift`

#### Prefer system semantic colors and styles; tokens cover only gaps (DESIGN-SPEC section 3)
`LBTokens`: Tokens for the macOS-native UI refresh. See DESIGN-SPEC.md, section 3.

Prefer system semantic colors (.primary, .secondary, .separator) and text
styles (.body, .headline); these tokens cover only what the system does not
provide. Shared by all app surfaces in both system appearances.

#### AccentColor asset must equal this; white text meets 4.5:1
`LBTokens.Palette.accentFill`: Set the AccentColor asset to this value in both appearances. White
text on it meets 4.5:1, so it is safe for selected rows in a focused
list, prominent buttons, switches and checkboxes.

#### Accent for links, timestamps, symbols; bright teal only on dark
`LBTokens.Palette.accentText`: Accent for links, timestamps, sidebar symbols and evidence chips.
The bright teal only appears on dark backgrounds.

#### Attention for fills, tints, dots; use attentionText for words
`LBTokens.Palette.attention`: Needs attention (speakers banner, remote dot, approvals): fills,
tints and dots. Use `attentionText` for words.

#### Darker orange in light appearance because system orange is too light for text
`LBTokens.Palette.attentionText`: "Owner unclear", "Download required". The system orange is too
light for text on white, so light appearance uses a darker orange.

#### Red marks recording, destructive actions and overdue dates
`LBTokens.Palette.recording`: Recording, destructive actions and overdue dates.

#### Grouped sections: gray well on light, faint white lift on dark
`LBTokens.Palette.groupFill`: Fill and stroke for grouped sections (10 pt rounded rectangles):
a light gray well on white, a faint white lift on dark.

#### Count pills and empty bar parts stay visible in both appearances
`LBTokens.Palette.quietFill`: Count pills and the empty part of a bar on a raised card: quiet,
and still a visible shape in both appearances.

#### Speakers by first appearance, index 0 is You; always show name too
`LBTokens.Palette.speakers`: Speakers in order of first appearance. Index 0 is always "You".
Always show the name next to the color.

#### Question font used in Ask
`LBTokens.Typography.question`: 17 semibold, Ask

#### Column title font for toolbar column titles
`LBTokens.Typography.columnTitle`: 15 bold, toolbar column titles

#### 14 pt reading font for transcript lines
`LBTokens.Typography.reading`: transcript lines

#### Minimums apply to list-and-detail splits: Meetings, Ask, People, Projects
`LBTokens.Metric.contentColumnMinWidth`: Minimums of a list-and-detail split (Meetings, Ask, People, Projects).

#### Grouped surface behind Recap, Action Items, Decisions, Evidence, details panes
`View.lbGroupedSurface`: The grouped section surface behind Recap, Action Items, Decisions,
Evidence and details panes.

#### Glass on macOS 26 with opaque fallback for Reduce Transparency
`View.lbFloatingComposer`: Glass on macOS 26, with an opaque fallback for Reduce Transparency.

#### Status surfaces keep visible boundary under Increase Contrast
`View.lbStatusSurface`: Status surfaces retain a visible boundary with Increase Contrast.

#### Switches keep filled accent while nearby buttons use brighter dark text accent
`LBAccentSwitchStyle`: Native switches keep the filled accent even when nearby bordered buttons
use the brighter text accent in dark appearance.

#### Round Reminders-style toggle used for action items everywhere
`ActionItemToggleStyle`: Round Reminders-style toggle used for action items everywhere they appear.

### `LokalBot/Support/DeviceInfo.swift`

#### Pure namespace in Support: no lifecycle, only bundle and sysctl reads
`DeviceInfo`: Snapshots host details for the Settings diagnostics readout: app version,
macOS version, Mac model identifier, CPU/chip brand, and installed memory.

Lives in `Support/` because it owns no lifecycle or actor state — every field
is read from bundle metadata or a `sysctlbyname` value with no side effects,
so the type is just a namespace of pure functions.

#### Optional fields drop out of summary instead of showing unknown
`DeviceInfo.Snapshot`: One host snapshot. Each field is optional so a missing sysctl key (Rosetta
translation, a future macOS rename) drops out of `summaryLine` rather than
surfacing a literal "unknown" to the user.

#### Joins only resolved fields, no dangling separators
`DeviceInfo.Snapshot.summaryLine`: Compact, human-readable one-liner for a Settings → Diagnostics row.
Joins only the fields we actually resolved, so the line never carries a
dangling separator or an empty value.

#### machdep.cpu.brand_string reports chip on Apple Silicon and Intel
`DeviceInfo.snapshot`: `machdep.cpu.brand_string` reports the chip on both Apple Silicon
("Apple M3 Pro") and Intel ("Intel(R) Core(TM)…") across every macOS
we support, so the field is populated on all hosts we run on.

#### Falls back to build number when marketing version missing
`DeviceInfo.bundleVersion`: User-visible version (CFBundleShortVersionString), falling back to the build
number so a developer build without a marketing version still reads something.

#### Short version avoids Version prefix and build number
`DeviceInfo.macosVersionString`: Short "14.6" / "14.6.1" rather than `operatingSystemVersionString`, which
carries a "Version " prefix and the build number we don't want in the row.

#### Trims NUL and whitespace; nil when key missing
`DeviceInfo.sysctlString`: Reads a C-string sysctl key and trims trailing NUL/whitespace. Returns nil
when the key is missing so the caller can omit the field cleanly.

#### RAM rounded to whole GB; nil only if kernel reports 0
`DeviceInfo.physicalMemoryGB`: Installed RAM rounded to whole GB. Returns nil only if the kernel reports 0.

### `LokalBot/Support/DiskSpacePrecheck.swift`

#### Refuse downloads that cannot fit before transfer; pure function of byte counts
`DiskSpacePrecheck`: Refuses model downloads that can't fit on disk *before* gigabytes move,
instead of failing at install time with a cryptic write error. The
decision is a pure function of two byte counts so it unit-tests without a
filesystem; only `availableBytes(at:)` touches the volume.

#### 2 GB slack so downloads cannot run boot volume dry
`DiskSpacePrecheck.headroomBytes`: Slack required beyond the file itself: install headroom plus a margin
so the download can't be the thing that runs the boot volume dry.

#### Refuse recording under 1 GB free to avoid truncated m4a files
`DiskSpacePrecheck.recordingFloorBytes`: Meeting audio is small next to models, but recording onto a nearly-full
volume risks truncated m4a files and failed processing. Refuse to start
below this floor so the failure is a clear sentence, not a corrupt take.

#### Important-usage capacity counts purgeable space, matching Finder
`DiskSpacePrecheck.availableBytes`: Free capacity of the volume holding `url`, using the "important usage"
figure so purgeable space (local Time Machine snapshots, caches) counts
as available — matching what Finder reports and what the OS will
actually reclaim for a user-initiated download.

### `LokalBot/Support/DownloadFileRescuer.swift`

#### replaceItemAt so half-written model never observable; plain move for first install
`DownloadFileRescuer.install`: Atomically replaces `destination` with the stashed file, creating the
parent directory if needed. Uses `replaceItemAt` when a file already
occupies `destination` so a half-written model is never observable;
falls back to a plain move for a first install. Consumes `stashed`
either way.

#### Cleanup errors swallowed; leaked temp files are reaped by OS
`DownloadFileRescuer.cleanup`: Best-effort removal of a stash that will not be installed (rejected as
non-GGUF, superseded, etc.). Errors are swallowed: by the time cleanup
runs the caller already has the real outcome to report, and a leaked
temp file is reaped by the OS.

### `LokalBot/Support/DownloadIntegrity.swift`

#### Sidecar records verified hash; legacy downloads hashed once before trust
`DownloadIntegrity`: Integrity gate for large, pinned runtime assets. A sidecar records a
successful full-file hash so later launches can validate the exact byte
count without re-hashing gigabytes. A legacy download with no sidecar is
hashed once before it is trusted.

#### Throwing variant distinguishes unreadable file from digest mismatch before deleting
`DownloadIntegrity.verifyExisting`: Throwing variant used by callers that must distinguish an unreadable
file from a verified digest mismatch before deciding whether to delete it.

#### Skip rehash after same-volume move; recheck exact size only
`DownloadIntegrity.markInstalled`: Record a destination immediately after an already-verified file was
atomically moved there. Exact size is rechecked; the digest need not be
recomputed because a same-volume move preserves the verified bytes.

#### Preserve filesystem errors so unreadable models are not treated as corrupt
`DownloadIntegrity.checkedSize`: Preserve filesystem errors so callers do not classify an unreadable
model as corrupt and attempt to delete it.

### `LokalBot/Support/DownloadOutcomeClassifier.swift`

#### Separate user cancel from failure to restore state silently; pure logic
`DownloadOutcome`: The terminal state of a model download, reduced to the few cases the UI
needs to react to. Crucially this separates "the user pressed Cancel" from
a genuine failure so the app can restore prior state silently instead of
surfacing an alarming error for a deliberate action.

Kept free of any `URLSession`/`Task` machinery so the decision is a pure
function of plain values and is unit-testable without the network.

#### Success is 2xx and staged bytes start with GGUF magic
`DownloadOutcome.success`: HTTP 2xx (or no response error) and the staged bytes begin with the
GGUF magic — the file is a usable model.

#### Not-GGUF is typically an HTML page served with 200
`DownloadOutcome.notGGUF`: The transfer finished but the bytes are not a GGUF file — typically an
HTML error/landing page served with a 200.

#### Cancellation rolls back quietly, never alerts
`DownloadOutcome.cancelled`: The user cancelled. Callers should quietly roll back, not alert.

#### Single source of user-facing download copy for consistent wording
`DownloadOutcome.userMessage`: The single source of truth for user-facing copy. Every download surface
binds to this so error wording stays consistent.

#### Priority: cancel, non-2xx status, transport error, then payload check
`DownloadOutcomeClassifier.classify`: Folds the three independent signals a finished download produces — the
HTTP status (if any response arrived), a terminal error (if the transfer
aborted), and whether the staged bytes start with the GGUF magic — into
one outcome.

Priority order is deliberate:
  1. User cancellation wins over everything. `Task` cancellation and an
in-flight `URLSessionDownloadTask.cancel()` surface as two distinct
error shapes (`CancellationError` vs the bridged `URLError.cancelled`);
both must read as `.cancelled`, never as a transport failure, or the
user gets a scary message for an action they took on purpose.
  2. A non-2xx status is the authoritative failure when a response came
back at all — a concrete code is a clearer message than a generic
transport string, and clearer than "not a GGUF".
  3. Any remaining error is a transport-level failure.
  4. Only once the transfer is known-clean do we judge the payload.

#### Cancel appears as CancellationError or NSURLErrorCancelled; both count
`DownloadOutcomeClassifier.isUserCancellation`: `true` when the error represents a deliberate cancellation rather than a
fault. Covers both the pre-flight `CancellationError` and the
`NSURLErrorCancelled` an aborted in-flight transfer reports (which is the
bridged form of `URLError(.cancelled)`).

### `LokalBot/Support/EventTapAudit.swift`

#### Leaked event taps slow keystrokes and blame autocomplete; --event-taps prints JSON
`EventTapAudit`: Keyboard and mouse hooks (event taps) on this Mac, grouped by the process
that holds them. An app that leaves an old tap behind each time it restarts
part of itself slows every keystroke once enough pile up, and autocomplete,
which draws while you type, takes the blame; Cotypist 2026.4 traced such
reports to Karabiner-Elements and Mos. `LokalBot --event-taps` prints this
as JSON while the app runs, so a leak, LokalBot's own or another app's, can
be checked from a script.

#### Likely leaking when taps exceed what one app needs
`EventTapAudit.Holder.likelyLeaking`: More taps than one app plausibly needs, so most were likely left behind.

#### Max 3 taps: key listener, Tab tap, dictation shortcut
`EventTapAudit.lokalBotMaximum`: Autocomplete's key listener, its Tab tap while a suggestion shows, and
dictation's shortcut.

### `LokalBot/Support/ExternalAgentHandoff.swift`

#### Apps only prefill composer; nothing leaves Mac until Send
`ExternalAgentHandoff`: Starts a new conversation in another assistant app with a meeting's notes
already in its composer. Both apps only prefill the composer: nothing
leaves this Mac until the user presses Send there.

#### 12,000 chars under Claude's 14,000 q cut; Codex shares budget
`ExternalAgentHandoff.promptCharacterLimit`: Claude cuts `q` at about 14,000 characters. Codex documents no limit;
it gets the same budget so both apps open with the same notes.

#### Installed targets looked up once because menus rebuild every playback update
`ExternalAgentHandoff.installed`: Targets with an installed app, looked up once: workspace menus
rebuild their items on every playback update.

#### Deep-link formats claude://claude.ai/new?q= and codex://new?prompt= as documented
`ExternalAgentHandoff.url`: `claude://claude.ai/new?q=` and `codex://new?prompt=`, as each app
documents them.

#### Percent-encode plus, ampersand, equals so URLSearchParams parses correctly
`ExternalAgentHandoff.encodeQueryValue`: URLComponents leaves `+`, `&`, and `=` bare, which URLSearchParams
parsing in both apps would turn into a space or a new parameter.

#### Transcript fills remaining room and ends with MCP pointer using meeting ID
`ExternalAgentHandoff.prompt`: `notes(nil)` renders the notes without a transcript and `notes(n)`
adds up to n characters of it. The transcript gets whatever room the
notes leave, and its window ends with a pointer that an agent with
LokalBot's MCP tools can follow using the meeting ID.

#### Reserve 200 chars for transcript heading and continues pointer
`ExternalAgentHandoff.prompt`: Leave room for the transcript heading and its "continues" pointer.

### `LokalBot/Support/FilmDirector.swift`

#### Debug-only scripted film runs, env vars, and outputs for recorder
`FilmDirector`: Films a scripted run of the real app for demo videos (Debug builds only;
see Scripts/media/agent-handoff-demo). `LOKALBOT_TEST_FILM_SCRIPT` picks the run:

- `install-agent` installs Agent Mode's runtime, prints the result and quits.
- `agent-handoff` opens the meeting `LOKALBOT_TEST_FILM_MEETING` while it is
  transcribed and summarized, then Agent Mode once its actions are handed
  off, moving between their tasks until the agents finish, then each
  task's report and the last one's results. A tool request that still
  asks is allowed once after two seconds, as a person would.

`LOKALBOT_TEST_FILM_DIR` receives `director.log`, a `done` marker,
`scenes.jsonl` (each scene and when it began, in seconds since 1970) and
`window.json` (the main window's number and top-left frame), which the
script recording the screen reads.

#### Automatic jobs never download models; enqueue as user request
`FilmDirector`: Automatic jobs never download models; ask the way Download & process does.

#### First handed-off task is reviewed last with results open
`FilmDirector.followAgents`: The first task handed off is reviewed last, with its results open.

#### Cycle tasks in turn, skipping ones still waiting for an agent
`FilmDirector.followAgents`: Each task in turn, skipping ones still waiting for a free agent.

### `LokalBot/Support/FocusOnAppear.swift`

#### macOS 26 drops onAppear focus requests, so wait one main-queue turn
`View.focusOnAppear`: Moves keyboard focus here when the view first appears, for a window
that opens ready for typing. From macOS 26 a focus request made inside
`onAppear` is dropped while the window's content is first being
installed, so the request waits one turn of the main queue.

### `LokalBot/Support/FocusReturn.swift`

#### Return focus to previous app so paste or dictation lands there
`FocusReturn`: Hands keyboard focus back to the app a person was using before a LokalBot
panel took it, so pasting or dictating lands where they were working.

#### Waits until frontmost; false if app quit or timed out
`FocusReturn.activate`: Activates `application` and waits until it is frontmost. False when it
quit or did not come forward in time.

#### macOS 14+ activation is cooperative: active app yields first
`FocusReturn.activate`: macOS 14+ activation is cooperative: the active app yields first.

### `LokalBot/Support/HardwareCapabilityProbe.swift`

#### Read RAM and architecture once so model-fit logic stays pure and testable
`HardwareCapability`: Installed memory + CPU architecture, read once so model-fit messaging in
onboarding/Settings can recommend or warn about a model before the user
downloads gigabytes. Split from the view as a tiny seam: `ModelFit.evaluate`
stays a pure function of a `HardwareCapability` value and is unit-testable
with synthetic hardware (no device required).

#### Compile-time arch suffices; Rosetta misread is conservatively acceptable
`HardwareCapabilityProbe.isAppleSilicon`: Compile-time architecture is enough: we ship a universal binary and only
need to tell Apple Silicon from Intel for advisory copy. A Rosetta run
reporting x86_64 is an acceptably conservative misread for that purpose.

#### Pure fit logic depends only on arguments, testable across RAM range
`ModelFit`: How well a model of a given on-disk size fits the host's installed RAM.
Pure value logic: `evaluate` depends only on its arguments, so it can be
exercised across the whole RAM range in tests without touching hardware.

#### Budget model size times 1.3; comfortable at 60% RAM, tooLarge above 80%
`ModelFit.evaluate`: Heuristic fit. A local LLM needs roughly its file size plus ~30% headroom
(KV cache, context, runtime) resident, so we budget `modelSizeGB * 1.3` and
compare that requirement against installed RAM:
  - ≤ 60% of RAM → comfortable
  - 60%–80% of RAM → tight (works, but crowds everything else)
  - > 80% of RAM → tooLarge (likely to swap hard or fail to load)

### `LokalBot/Support/HiddenWindowButtons.swift`

#### Quick Recall is a transient Escape-dismissed panel, so hide window controls
`HiddenWindowButtons`: Hides the traffic-light buttons of the hosting window. Quick Recall is a
transient search panel dismissed with Escape, so window controls read as
clutter there.

### `LokalBot/Support/HourLabel.swift`

#### Hour labels follow the Mac's 12 or 24-hour preference
`HourLabel`: Clock label for an hour-of-day setting, following the Mac's 12- or 24-hour
preference so settings read like times elsewhere in the app.

### `LokalBot/Support/LibraryInstanceLock.swift`

#### One app process per library; second copy double-counts time; kernel frees lock on exit
`LibraryInstanceLock`: One app process per library. A second copy writing the same activity
database, journals, and schedules double-counts tracked time and races
scheduled model runs. The kernel releases the lock when the holder exits,
including after a crash.

#### Wait up to timeout for quitting instance; unopenable lock file never blocks launch
`LibraryInstanceLock.acquire`: Takes the lock for `root`, waiting up to `timeout` for a quitting
instance. Returns nil while another process holds it. A lock file
that cannot be opened never blocks launch.

### `LokalBot/Support/LiveWaveform.swift`

#### Pure waveform math testable without TimelineView; same curve as old dictation HUD
`LiveWaveformMath`: Pure math behind the animated capture waveform, extracted so bar heights
are unit-testable without driving SwiftUI's TimelineView. Same curve as
the original dictation-HUD waveform.

#### Animation capped below refresh rate because height changes cause layout
`LiveWaveform`: The one "audio is flowing" motion signature: tinted animated bars shared
by the dictation HUD and recording surfaces. Animation is intentionally
capped well below display refresh rate; changing bar heights causes layout,
and a 60/120 Hz timeline needlessly competes with input handling.
Freezes at its time-zero shape under Reduce Motion or when `animated` is false.

### `LokalBot/Support/MeetingPageSearch.swift`

#### Locations are stable scroll targets; source list defines Previous/Next order
`MeetingPageSearchMatch`: One searchable occurrence on a meeting detail page. Locations are stable
scroll targets; the source list supplied by the workspace defines reading
order for Previous/Next navigation.

#### Location beside exact rendered text keeps matching, highlighting, scrolling consistent
`MeetingPageSearchSource`: One visible text node on the meeting page. Keeping the location beside the
exact rendered text makes matching, highlighting, and scrolling agree.

### `LokalBot/Support/OutcomeEvidencePolicy.swift`

#### Owner evidence rules for handed-off work; own undertakings live in SpokenUndertaking
`OutcomeEvidencePolicy`: Evidence rules shared by every path that assigns an action's owner.
A speaker's own undertaking is recognized by `SpokenUndertaking`; this
file keeps the rules for work handed to someone by name, or by a request
the user answered.

#### Only speaker-local preambles may precede bare acceptance or conversation remark
`OutcomeEvidencePolicy.commitmentPreamble`: Only speaker-local preambles may precede a bare acceptance or a remark
about the conversation itself.

#### I can do that names no task; needs the request it answers
`OutcomeEvidencePolicy.isBareAcceptance`: "I can do that" names no task of its own; it needs the request it answers.

#### Without a quote, multi-task rows cannot say which task was meant
`OutcomeEvidencePolicy.resolveTarget`: A request or assignment read from its own source row. With no quote,
a row stating more than one task cannot say which one was meant.

#### addressedToUser can make unnamed you the user's, never another participant's
`OutcomeEvidencePolicy.resolve`: `addressedToUser` is transcript evidence supplied by the caller: the
user spoke the next turn after this request. It can make an unnamed
"you" request the user's, never another participant's.

#### Commitment identity comes from cited voice; words must show undertaking
`OutcomeEvidencePolicy.resolve`: Identity comes from the cited voice. The words only have to
show that voice undertaking something itself.

#### User answering another participant's you-request takes the task
`OutcomeEvidencePolicy.resolve`: Another participant asked "you", and the user answered next.

#### First-person undertaking excludes questions, negation, reported speech, collective we
`OutcomeEvidencePolicy.isCommitment`: A first-person undertaking anywhere in the text: a promise, a plan, an
obligation or an offer. Not a question, a negation, reported speech,
or a collective "we".

#### Row of only negated or questioned forward-looking sentences cannot become a task
`OutcomeEvidencePolicy.undertakingIsNegatedOrQuestioned`: Every sentence of the row that looks forward is a question or a
negation ("We should not deploy on Friday."). Such a row cannot become
a task merely because no undertaking was recognized in it. A stray
"not" or "?" elsewhere in the row decides nothing.

#### Ownerless task kept only if cited speech looks forward
`OutcomeEvidencePolicy.expressesUndertaking`: Forward-looking wording ("we should", "I need to", "we can try to"). A
task with no recognized owner is kept only when the speech it cites
still looks forward; a status report cannot manufacture one.

#### Direct requests to one listener count; group and hypothetical excluded; polite if you could counts
`OutcomeEvidencePolicy.isSecondPersonRequest`: A direct second-person request to one listener ("Could you send…",
"You need to…"). Group addresses and hypotheticals are excluded; a
polite "if you could" is still a request.

#### First names usable only when identifying one named speaker
`OutcomeEvidencePolicy.uniqueTargetNames`: First names are usable only when they identify one named speaker.

### `LokalBot/Support/OutcomeProse.swift`

#### Me stays stable owner identity; prose uses first person
`OutcomeProse`: Converts LokalBot's internal `Me` ownership label into grammatical prose.
`Me` remains the stable owner identity; sentences about the user are written
in first person instead of treating that label as a subject pronoun.

### `LokalBot/Support/PaletteCommands.swift`

#### Command key and system shortcut open the same window, one command list
`PaletteCommand`: One command the Quick Recall window can run. ⌘K and the system-wide
shortcut open the same window, so there is one list of commands.

#### Background commands act in place, so Quick Recall returns focus first
`PaletteCommand.Placement`: Where a command's result appears. Workspace commands show something in
the main window. Background commands (recording, dictation) act in
place, so Quick Recall hands focus back to the app the person was
using before running them.

#### Subtitle is matched by typed words but not shown on the row
`PaletteCommand.subtitle`: The area the command belongs to ("Library", "Recording"). Typed words
match it; the row does not show it.

#### English aliases still find translated commands
`PaletteCommand.searchAliases`: English words that still find a translated command.

#### Word-prefix matches first, loose matches after, keeping catalog order
`PaletteCommandFilter.ranked`: The commands typed words find in Quick Recall: those where each word
starts a word of the command first, then those that only hold the
words somewhere, as the ⌘K palette matched. Each part keeps the
catalog's order.

#### Leading matches run on Return; loose matches are findable but never run by Return alone
`PaletteCommandFilter.split`: The same commands in two parts. `leading` are those where each typed
word starts a word of the command; Quick Recall lists them first, so
Return runs the top one. `loose` only hold the words somewhere ("ion"
in "Start dictation"); Quick Recall lists them under the search
results, where they can be found but Return alone never runs one.

#### Idle order puts in-place commands first, then catalog order
`PaletteCommandFilter.idleOrder`: The order before anything is typed: what acts in place (recording,
dictation) first, then the rest as the catalog lists them.

#### Matches all query words in title, subtitle, aliases; empty query matches nothing
`PaletteCommandFilter.filter`: Commands whose title, subtitle, and aliases contain every query word.
An empty query matches nothing; callers decide what idle shows.

#### Chinese titles lack spaces, so non-ASCII tokens match anywhere
`PaletteCommandFilter.filter`: Chinese titles have no spaces between words; match those
anywhere instead.

#### Commands computed live so titles follow recording and dictation status
`PaletteCommandCatalog`: The app-wide commands, computed live from app state so titles follow
recording and dictation status.

#### inWorkspace adds section commands; source labels starts in log
`PaletteCommandCatalog.commands`: `inWorkspace` adds commands that act on the main window's current
section (Agent tasks), which only make sense when Quick Recall was
opened from it. `source` labels recording and dictation starts in the
log.

#### Translate app commands before adding user-owned task titles
`PaletteCommandCatalog.commands`: Translate app commands before adding user-owned task titles.

#### Dictation shortcut registered only while Dictation is on
`PaletteCommandCatalog.appCommands`: The dictation shortcut is registered only while Dictation is on.

#### From system-wide window, copy last dictation hands focus back ready to paste
`PaletteCommandCatalog.appCommands`: From the system-wide window this hands focus back, ready to paste.

### `LokalBot/Support/PermissionOverlayTracker.swift`

#### Unchanged state collapses to none so frequent polling does not flicker panel
`PermissionOverlayTracker`: Pure transition rule for the permission helper floating over System Settings.
The controller polls often, so unchanged state must collapse to `.none` to
avoid repeatedly ordering the panel and making it flicker.

#### End walkthrough when Settings closed or never opened, else overlay reappears
`PermissionOverlayTracker.shouldEnd`: The walkthrough is over without a grant: System Settings was closed
after the overlay had been shown, or never opened. Without this the
tracking timer ran for the rest of the session, and the overlay came
back whenever System Settings was next opened for any reason.

### `LokalBot/Support/ProcessExitSignal.swift`

#### waitUntilExit can hang after await; use termination handler instead
`ProcessExitSignal`: Waits for a `Process` to exit without `waitUntilExit()`.

`waitUntilExit()` returns only after Foundation finishes the exit on the
run loop of the thread that called `run()`. After any `await`, Swift
concurrency may resume the task on another thread, and nothing turns the
launching thread's run loop again, so that wait can block forever after
the child has exited and been reaped. The termination handler runs on
Foundation's own queue and has no such dependency.

#### Install handler before run so instant exit is not missed
`ProcessExitSignal.init`: Install before `run()` so an instant exit cannot be missed.

#### Cancellation does not end wait; callers stop the process
`ProcessExitSignal.wait`: Returns once the process has exited. Cancellation does not end the
wait; callers stop the process instead, which ends it.

### `LokalBot/Support/PromptContextSanitizer.swift`

#### Tidy noise before prompts but keep punctuation needed by transcripts
`PromptContextSanitizer`: Normalises free-form text before it is spliced into an LLM prompt.

Transcript and context text arrives with stray control bytes, ragged spacing,
and stacked blank lines that waste the model's context budget without adding
meaning. This keeps the real content — letters, digits, punctuation, normal
spacing — and only tidies the noise, so the policy stays pure, shared, and
easy to test. Unlike a terminal/clipboard sanitiser it does NOT strip
punctuation: a meeting transcript needs its commas and question marks.

#### Ellipsis is one Character, costing one unit of maxCharacters
`PromptContextSanitizer.ellipsis`: Ellipsis is a single Swift `Character`, so it costs one unit against `maxCharacters`.

#### Cap at maxCharacters with ellipsis at last word boundary, counted within cap
`PromptContextSanitizer.sanitize`: Returns prompt-ready text: control characters removed, runs of whitespace
and blank lines collapsed, edges trimmed, and — when `maxCharacters` is
given — hard-capped to that length with a trailing ellipsis at the last
word boundary (the ellipsis is counted within the cap).

#### Replace control scalars with spaces to keep word boundaries
`PromptContextSanitizer.sanitize`: Single scalar pass: fold every newline variant (U+2028/2029, CRLF, …)
to "\n", and turn control/format scalars into spaces. Replacing rather
than deleting keeps a boundary so "raw\u{0007}output" reads as two
words, not one. Everything else passes through untouched.

### `LokalBot/Support/ProportionBar.swift`

#### Overview promotes meaningful apps; short and long-tail fold into Other; journal keeps totals
`AppTimePresentation`: Human-facing rows for the app-time list. The complete totals remain in the
journal, while the overview promotes only meaningful apps and folds short
or long-tail activity into one honest `Other` row.

### `LokalBot/Support/QuickRecallPresentation.swift`

#### Exclusion rules can name apps by bundle identifier
`QuickRecallIcon.icon`: Exclusion rules can name an app by bundle identifier.

#### Date label formats: Today, Yesterday, weekday within week, then day with year if not current
`QuickRecallDateLabel`: When a row happened, short enough for the end of its first line:
"Today 10:43 AM", "Yesterday 4:00 PM", "Wed 11:47 AM" within the week,
then the day alone ("Sep 25", with the year once it is not this year).

### `LokalBot/Support/RecallPassage.swift`

#### Excerpts are for reading only; stored transcripts and exports stay lossless
`RecallPassage`: Reading excerpts only; stored transcripts, summaries and export text remain lossless.

#### Generated provenance lines are excluded from search passages
`RecallPassage.excerpt`: Generated provenance is never useful as a search passage.

### `LokalBot/Support/RehearsalTextEditor.swift`

#### Native text system owns editing; ghost text is painted, not inserted until accepted
`RehearsalTextEditor`: The native text system owns selection, focus and marked text. SwiftUI owns
the committed string and suggestion. Ghost text is painted, never inserted
into the editable value until a deliberate acceptance.

#### Accept key takes next chunk; full-accept key takes everything left, as live
`RehearsalTextEditor.onAccept`: The accept key takes the next word or phrase; the full-accept key takes
everything that is left, exactly as in another app.

#### Expose painted ghost text to assistive technology as accessibility placeholder
`RehearsalTextEditor.updateNSView`: Ghost text is painted, not part of the value, so assistive
technology would otherwise never learn what is being offered.

#### Flag stops programmatic selection changes being mistaken for the user's caret
`RehearsalTextEditor.Coordinator.isApplyingText`: Set while SwiftUI's text is being written into the editor, so the
selection it passes through is not mistaken for the user's caret.

#### Suggestion continues end of text; selecting or moving the caret rejects it
`RehearsalTextEditor.Coordinator.textViewDidChangeSelection`: A suggestion continues the end of the text. Selecting text or
moving the caret elsewhere leaves it behind, as in another app.

#### Primary accept key wins over full-accept key when both are the same key
`RehearsalTextEditor keyDown`: Same precedence as the live accept tap: the primary key wins when
both are set to the same key.

#### Tab follows key-view loop without ghost; Shift-Tab goes back; IME keeps its keys
`RehearsalTextEditor keyDown`: Once there is no acceptable ghost, this short rehearsal follows
the window's key-view loop instead of inserting indentation.
Shift-Tab always navigates back; IME composition keeps its keys.

#### Arrow keys drop the suggestion even at the end of text, like live monitor
`RehearsalTextEditor keyDown`: Arrow keys navigate; like the live monitor, they drop the suggestion
even when the caret has nowhere further to go.

#### Lay out whole sentence so wrapped ghost lines return to left margin
`RehearsalTextEditor.draw`: Layout the complete sentence so wrapped ghost lines return to the
editor's left margin. Drawing into a caret-width rectangle indents
every continuation line beneath the insertion point.

### `LokalBot/Support/ResultRow.swift`

#### Unmatched opening marker is dropped and the tail emitted as plain text
`SnippetHighlighter.segments`: Unmatched « — drop the marker, emit the tail as plain text.

#### Drop leading snippet lines that echo the row title; keep match markers
`SnippetCleaner`: Screen OCR usually re-captures the window chrome, so an FTS snippet's
leading line often just repeats the row title shown directly above it.
Drops those echo lines and collapses whitespace; «» markers survive so
`SnippetHighlighter` still finds the matches. Pure; unit-tested.

#### Containment counts as echo only above 12 characters; short lines must match exactly
`SnippetCleaner.echoes`: Containment counts as an echo only above a length floor; short lines
like an app name must match the title exactly before they're dropped.

### `LokalBot/Support/SearchableNotesEditor.swift`

#### Native text selection makes cross-tab Find land in editable notes
`SearchableNotesEditor`: Native text selection makes cross-tab Find land in the editable notes.

### `LokalBot/Support/SettingsAppearance.swift`

#### Writing Statistics and Resource Monitor share this tile so rows read alike
`SettingsMetricTile`: One headline number in a settings readout: what it measures, the value,
and a line of context. Writing → Statistics and Advanced → Resource
Monitor share it, so their rows read alike.

#### Tiles in one row if each gets minimumWidth, else rows of two, equal heights
`SettingsTileLayout`: Lays tiles out in equal columns: all in one row when each gets at least
`minimumWidth`, otherwise in rows of two. Tiles in a row share its height.

### `LokalBot/Support/SettingsSearchRanker.swift`

#### Section matches when every query token appears in title plus keywords; empty matches all
`SettingsSearchRanker`: Pure matcher backing the Settings search field. A section is shown when every
whitespace-separated token of the query appears somewhere in the section's
searchable text (title + keywords). Empty query matches everything.

Kept tiny and `nonisolated` so it is unit-testable off the main actor and the
view layer stays free of search logic.

### `LokalBot/Support/SpeakerNameHintExtractor.swift`

#### Trust calendar names; accept OCR names only from roster regions or role markers
`SpeakerNameHintExtractor`: Conservative extraction for speaker rename suggestions. Calendar attendee
names are trusted directly; OCR text is noisy, so names are accepted only
from likely participant/people roster regions or lines with role markers.

### `LokalBot/Support/SplitPaneAccessibility.swift`

#### Split pane keeps settled width; only a divider drag chooses a new one
`HeldPaneWidth`: The width a split pane keeps once it has settled. SwiftUI can re-divide an
HSplitView when the sibling pane's content changes — the Timeline swapping
its day column for a selection's details did, widening the sessions rail to
its maximum. Only a divider drag chooses a new width; any other resize is
put back.

#### Remember clamped restore width to avoid retry loops in narrow windows
`HeldPaneWidth.unreachableWidth`: A width the split clamped a restore to (the window is too narrow).
Retrying at that same width would loop.

#### Reaching held width clears the remembered unreachable width
`HeldPaneWidth.resized`: The split reached the held width after all, so a width it once
clamped a restore to says nothing about the next re-division.

#### Detect divider drags by current mouse event, since resize notifications also fire on layout
`DividerDragDetector`: Tells a divider drag from every other resize by the mouse event being
handled. The resize notification can't: from macOS 26 at least, plain layout
passes name a divider too, so a re-division looked like a drag and the pane
kept the width SwiftUI gave it. A click is not a drag, so selecting a row
never counts, and the drag's own last step can land on its mouse-up.

#### Label the split item's hosting-view group without replacing the native split view
`SplitPaneAccessibility`: SwiftUI labels a column's content, but macOS also exposes the native split
item's hosting view as a separate group. Name that boundary without
replacing the native split view, its children, or its keyboard behavior.

#### Cleared once opening width is applied or a saved divider position is restored
`PaneAnchor.initialWidthPending`: Cleared once the pane has its opening width, or once a divider
position the user saved earlier has been restored instead.

#### Retry initial placement a bounded number of times so it never fights a user drag
`PaneAnchor.initialWidthAttempts`: SwiftUI can even out the split after the first placement, for
example when a window is resized right after opening. Placement is
retried until the pane measures its opening width, a bounded number
of times so it never fights a divider the user is dragging.

#### Missed restores are retried on later run-loop turns before width counts as unreachable
`PaneAnchor.maximumRestoreRetries`: Later run-loop turns a missed restore is retried on before the
width counts as one the split cannot reach.

#### Keep retrying as the pane lays out until the opening width lands
`PaneAnchor.setFrameSize`: The split can attach before it has its final width. Keep retrying
as the pane lays out until the opening width lands, instead of
leaving (and saving) HSplitView's even split.

#### Defer until SwiftUI attaches the hosting view; modify only the nearest pane
`PaneAnchor.updatePaneLabel`: Defer until SwiftUI has attached the hosting view to its split
item. Only this anchor's nearest pane is ever modified.

#### Give each workspace its own native divider storage; never borrow a sibling's position
`PaneAnchor.updatePaneLabel`: HSplitView's idealWidth is only a layout proposal.
Give each workspace its own native divider storage;
never borrow a sibling workspace's split position.

#### Check saved frames before naming the split so a saved position wins over default
`PaneAnchor.updatePaneLabel`: Check before naming: assigning the name restores
a saved position, which must win over the default.

#### Label the NSSplitView pane proxy, which is the group VoiceOver enters
`PaneAnchor.updatePaneLabel`: NSSplitView exposes pane proxies separately from
its arranged NSViews. The proxy, rather than the
child hosting view, is the group VoiceOver enters.

#### HSplitView splits evenly; pane gets opening width once then holds it on window resize
`PaneAnchor.applyInitialWidth`: HSplitView splits two flexible panes evenly. A pane with an opening
width gets it once, and then holds its width while the window
resizes so the sibling pane absorbs the change instead.

#### Set holding priority through the split view controller's items when one exists
`PaneAnchor.applyInitialWidth`: HSplitView's split view belongs to a split view controller, which
owns holding priorities through its items.

#### A restored divider position counts as settled
`PaneAnchor.applyInitialWidth`: A restored divider position counts as settled too.

#### Out of attempts: hold the placement reached rather than a later re-division
`PaneAnchor.applyInitialWidth`: Out of attempts: hold what this placement reached. Waiting for
the next layout pass would hold whatever a re-division left.

#### From macOS 26 the detail pane runs under the sidebar; widths are compared as shown
`PaneAnchor.coveredWidth`: The part of a pane that lies under the main window's sidebar. From
macOS 26 the detail column runs under the sidebar, so the pane beside
it is wider than what shows; AppKit reports the hidden part as the
pane's safe-area inset. Widths are chosen, held and compared as the
person sees them.

#### Divider positions run from the first pane's outer edge in both directions
`PaneAnchor.dividerPosition`: The divider position that shows `width` of `pane`. Positions run
from the first pane's outer edge in both layout directions.

#### Only a divider drag chooses a width; other resizes are re-divisions to undo
`PaneAnchor.observeResizes`: Only a divider drag chooses a width; every other resize is a
re-division to undo.

#### SwiftUI may re-divide in the same update; give up only after a later-turn restore misses
`PaneAnchor.restore`: SwiftUI can re-divide the split again in the same update that
reported the first re-division, overriding the position just set:
selecting a project left its list at the column's maximum. A width
is only given up on, as one the split cannot reach, once a restore
on a later turn of the run loop, after that update, still misses it.

#### Skip retry if a divider drag in between chose a new width
`PaneAnchor.restore`: A divider drag in between chose a new width.

#### On macOS 26 keep splits left-to-right; pane content takes interface direction back
`SplitStructureDirection`: macOS 26 mirrors the main window's NavigationSplitView for a right-to-left
interface with the detail's toolbar squeezed into the sidebar's strip, and
a split view that then appears in the detail never finishes updating its
constraints: AppKit throws, and opening Settings in Arabic or Urdu quit the
app. A split built left-to-right has neither problem, and is what changing
the language in a running app leaves. So on macOS 26 the splits stay
left-to-right and every pane's content takes the interface's direction back.

#### Tests set it to check either arrangement on any macOS
`EnvironmentValues.holdsSplitStructureLeftToRight`: Whether split views are built left-to-right whatever the interface's
direction. Tests set it to check either arrangement on any macOS.

#### Interface direction is passed past a held left-to-right split to its panes
`EnvironmentValues.splitPaneContentDirection`: The interface's direction, handed past a split that is held
left-to-right to the panes inside it.

#### Label pane for VoiceOver; autosaveName and initialWidth semantics; content follows interface direction
`View.splitPaneAccessibilityLabel`: Names a split pane for VoiceOver. `autosaveName` gives the split its own
saved divider position; `initialWidth` sets this pane's width the first
time the split appears without one. The pane's content follows the
interface's direction even where the split itself is held left-to-right.

#### Apply to every split view in the main window, NavigationSplitView included
`View.splitStructureDirection`: Apply to every split view in the main window, the NavigationSplitView
included. See `SplitStructureDirection`.

#### State panes' real minimum so macOS 26 detail splits do not double-count the sidebar
`View.detailSplitMinimumWidth`: The minimum width of an `HSplitView` in the main window's detail column:
its visible panes' minimums plus their 1 pt dividers. From macOS 26 the
detail column runs under the sidebar, an AppKit split adds the sidebar's
width to its own minimum, and NavigationSplitView then adds the sidebar
again, so Meetings could not shrink below about 1,100 pt. Stating the
panes' real minimum keeps the window resizable down to sidebar + panes.

### `LokalBot/Support/SpokenUndertaking.swift`

#### Recognise first-person undertakings across a speaker's rows, refusing only contradictions
`SpokenUndertaking`: Finds a speaker's own undertaking in transcribed speech: "I'll ping Alex",
"the extraction PR is something I I have to update", "My side, I'll." /
"Try to." / "update the tickets".

Transcripts are not sentences. A commitment can sit anywhere in a run-on
clause, repeat or stumble over words, and be cut across rows by the
diarizer. Recognition therefore reads one speaker's consecutive rows as a
stream of words and looks for a first-person subject bound to an
undertaking verb, wherever it appears. It refuses only what contradicts an
undertaking: negation, a question, reported or habitual speech, and work
handed to someone else. A condition ("if approved, I'll ship it") changes
when the task happens, never whose it is.

#### Words are lowercased, straight apostrophes, no surrounding punctuation
`SpokenUndertaking.Word.text`: Lowercased, straight apostrophes, no surrounding punctuation.

#### Range in the row's own text, for quoting the source verbatim
`SpokenUndertaking.Word.range`: Position in the row's own text, for quoting the source verbatim.

#### Acceptances like 'Will do' take the task from what was asked just before
`SpokenUndertaking.Cue.namesNoTask`: "I can do that", "I'll send it tomorrow", "Will do": the task is
whatever was asked just before.

#### Another party's task in the same speech, with examples
`SpokenUndertaking.Actor`: Another party's task in the same speech: "you will send it", "Alice
will review", "could you check".

#### Drop fillers and immediate repeats so tidied quotes still match speech
`SpokenUndertaking.words`: Words of one speaker's consecutive rows. Fillers and immediately
repeated words are dropped, so "I I have to" reads as "I have to" and a
tidied quote still matches what was said.

#### Free-standing punctuation still closes the preceding sentence
`SpokenUndertaking.words`: Free-standing punctuation still closes the sentence before it.

#### A cut after a dangling word is not a sentence end; keep later copy
`SpokenUndertaking.words`: "but I'll." / "I'll share it": the cut after a dangling
word is not a sentence end, so the repeat is one stumble.
The later copy stays; it is the one the sentence goes on from.

#### A dropped filler passes its sentence or comma boundary to the previous word
`SpokenUndertaking.words`: Keep the boundary a dropped word carried.

#### Other languages keep the forms recognised before this policy
`SpokenUndertaking.cuePatterns`: Other languages keep the forms recognized before this policy.

#### 'I have X to do' is an obligation, unlike 'nothing to add'
`SpokenUndertaking.cuePatterns`: "I have some comments from you to resolve": an obligation, unlike
"I have nothing to add" or "I have a question to ask".

#### Words a sentence does not end on; cuts at a pause are not sentence ends
`SpokenUndertaking.dangling`: Words a sentence does not end on: "I'll.", "Try to." and "update the."
are cuts made at a pause, not sentence ends.

#### Detect a dropped subject at sentence start, e.g. 'Will do'
`SpokenUndertaking.cues`: A dropped subject at the start of a sentence: "Still have to go
through your app", "Will do".

#### An adverb or dangling word closes a cut, not the undertaking
`SpokenUndertaking.judged`: "I will mostly." / "Keeping up the PRs": an adverb or a dangling
word closes a cut, not the undertaking.

#### 'do that' refers to an earlier task; 'handle that migration' names its own
`SpokenUndertaking.pointsAtAnEarlierTask`: "…do that", "…take it, but after lunch". "…handle that migration"
names its own task.

#### A tag question after a commitment, like 'okay?', still commits
`SpokenUndertaking.endsInQuestion`: "I'll send it tomorrow, okay?" still commits.

#### 'I'll need you to' delegates work; 'need some time' does not
`SpokenUndertaking.isDelegation`: "I'll need you to send it" hands the work to someone else. "I'll need
some time to think" does not.

#### Remarks about the conversation itself after 'I'll' are never follow-up tasks
`SpokenUndertaking.conversationRemark`: What a speaker says about the conversation itself, after "I'll" or
"I'm going to": never a follow-up task.

#### Length of obligation or plan phrase; passives name no actor
`SpokenUndertaking.modalLength`: Length of an obligation or plan at `index` ("will", "needs to", "is
going to"), or nil. A passive ("can be simplified") names no actor.

#### Requests like 'Could you send it' assign the task to 'you'
`SpokenUndertaking.otherActors`: "Could you send it", "I'd like you to own it", "make sure you file it".

#### Purpose and question clauses with other subjects hand out no task
`SpokenUndertaking.otherActors`: "so you can introduce us" states a purpose and "what do we
need to change" asks a question; neither hands out a task.

#### Counts distinct task words the clause shares
`SpokenUndertaking.Alignment.matches`: Distinct task words the clause shares.

#### Clause carries the task's leading verb
`SpokenUndertaking.Alignment.leads`: The clause carries the task's leading verb ("Ping …").

#### More than one stray shared word counts as about the task
`SpokenUndertaking.Alignment.isAboutTask`: More than one stray word in common.

#### Find model quotes in words tolerating tidied stumbles, casing and punctuation
`SpokenUndertaking.occurrences`: Where a model's quote occurs in `words`, tolerating tidied stumbles,
casing and punctuation.

### `LokalBot/Support/SystemResourceSampler.swift`

#### Stateless readings of the process family; caller owns the sampling cadence
`SystemResourceSampler`: Stateless CPU and memory readings for the LokalBot process family from
Mach/libproc. Every call answers "what is true right now" and the caller
owns the cadence.

#### CPU time is cumulative; compare two snapshots; percentage may exceed 100
`SystemResourceSampler.ProcessUsage`: One process reading used to build a whole-app sample. CPU time is
cumulative, so callers compare two snapshots to get Activity Monitor's
multi-core percentage (which may legitimately exceed 100%).

#### Sample descendants plus adopted llama-server PIDs no longer descendants
`SystemResourceSampler.usageSnapshot`: Samples LokalBot plus every descendant process (llama-server, Agent
Mode, transient native helpers). Extra PIDs cover a healthy llama-server
adopted from a prior app process, which is no longer our descendant.

#### Adopted servers must match PID and start time so stale markers cannot count
`SystemResourceSampler.usageSnapshot`: Adopted llama servers are no longer descendants. Match both PID and
start time before adding one so a stale marker cannot make an
unrelated process part of LokalBot's headline CPU/RAM totals.

#### Identity includes start time so reused PIDs cannot create bogus deltas
`SystemResourceSampler.cpuUsagePercent`: Combined CPU percentage between two whole-app samples. Identity includes
the process start time so a rapidly reused PID never creates a huge,
bogus delta. New and exited helpers begin/leave contributing cleanly.

#### Leave buffer slack because the process tree can grow between calls
`SystemResourceSampler.directChildProcessIdentifiers`: The nil-buffer call returns a PID-count estimate. Leave slack because
the process tree can grow between the sizing and population calls.

### `LokalBot/Support/TestHooks.swift`

#### Debug-only switches replacing external dependencies with recorded fakes; release never compiles effects
`TestHooks`: Switches that exist only in Debug builds (`LOKALBOT_TEST_HOOKS`). Each
replaces one external dependency with a recorded fake for CI and the UI
background host; release builds never compile this file's effects.

#### Golden transcripts live at \<slug>/\<track>.json
`TestHooks.goldenTranscriptsDirectory`: Directory of golden transcripts: `<slug>/<track>.json`.

#### Film mode keeps ghost visible to capture; set by env var or launch argument
`TestHooks.filmsAutocomplete`: Filming the autocomplete demo (`Scripts/media/autocomplete-demo`): the ghost
panel stays visible to screen capture and autocomplete logs its states.
Set by `LOKALBOT_TEST_FILM_GHOST=1` or the `--lokalbot-film-ghost`
launch argument, which `open --args` can pass.

#### Track and span a sliced region file was cut from; boundary reviews name no meeting
`GoldenTranscriptionEngine.Region`: The track and time span a sliced region file was cut from. Boundary
reviews transcribe `<temp>/<index>.wav` slices, which name no meeting.

#### Manual recording folder names are generated, so fall back to default/
`GoldenTranscriptionEngine.transcribe`: A manual recording's folder name is generated; it reads `default/`.

#### A slice's timestamps start at the region's start
`GoldenTranscriptionEngine.transcribe`: A slice's timestamps start at the region's start.

### `LokalBot/Support/TokenCountEstimator.swift`

#### Cheap word-aware estimate (about 4 chars per token) for relative budgeting only
`TokenCountEstimator`: Cheap, allocation-light estimate of how many model tokens a string occupies.

`ProcessingPipeline` budgets transcript chunks against a model's context
window, and paying for a real tokenizer on that path is wasteful. A
word-aware heuristic — roughly four characters per token within a word, every
word at least one token — tracks real subword tokenization more closely than
a single global chars-per-token ratio, especially for code or short function
words. It is deliberately an *estimate*: use it for relative budgeting, never
to assert a hard token limit.

#### Split on punctuation too, or code and punctuation-heavy prose is undercounted
`TokenCountEstimator.estimate`: Estimated token count for `text`; `0` for empty or whitespace-only input.

Splits on punctuation as well as whitespace because real tokenizers break
"can't", "end.", and "func()" into several tokens — gluing punctuation to
a word would systematically undercount code and punctuation-heavy prose.

### `LokalBot/Support/WordCountFormatter.swift`

#### Hand-grouped digits keep output locale-independent and deterministic for tests
`WordCountFormatter`: Formats a word count for display, e.g. `1` -> "1 word", `1234` -> "1,234 words".

Grouping is done by hand rather than via `NumberFormatter` so the output is
locale-independent and deterministic for tests — a formatter would render
"1.234" or "1 234" depending on the user's region.

#### Negative counts become 0; unit singular only for exactly one
`WordCountFormatter.format`: "\<grouped count> word(s)". Negative input is treated as `0`; the unit is
singular only for exactly one word.

#### Comma every three digits; count assumed non-negative
`WordCountFormatter.grouped`: Inserts a comma every three digits from the right ("1234" -> "1,234").
`count` is assumed non-negative, so there is no sign to preserve.

### `LokalBot/Support/WorkspaceMenu.swift`

#### Native pull-down with explicit Press and Show Menu actions missing from SwiftUI Menu on macOS 15
`WorkspaceMenu`: A native pull-down menu with explicit accessibility actions. SwiftUI's
macOS 15 Menu proxy omits Press/Show Menu on these workspace controls.

#### Composer rows match neighbouring SwiftUI controls' type
`WorkspaceMenu.font`: Composer rows match their neighboring SwiftUI controls' type.

#### False overlays an undrawn menu on caller's label; clicks and assistive tools still work
`WorkspaceMenu.drawsButton`: False lays the menu, undrawn, over a label the caller draws itself (a
colored chip, say). Clicks and assistive tools still reach the native
button, which then fills whatever space it is given.

#### Menu takes its button's font; symbol buttons keep standard menu size
`WorkspaceMenu.buttonFont`: AppKit gives the menu its button's font. A symbol button shows no
text, so its menu keeps the standard menu size.

#### Keep an open menu intact when only closures change, but use latest callbacks
`WorkspaceMenu.updateNSView`: Playback updates frequently. Keep an open menu intact when only
closure captures changed, while always using the latest callbacks.

#### Skip only drawing so clicks and assistive tools meet the same control
`WorkspaceMenu.PopUpButton.drawsNothing`: Skips the button's own drawing and changes nothing else, so clicks
and assistive tools meet the same control as a drawn menu.

#### Menu tracking is synchronous; return to the accessibility client first
`WorkspaceMenu.PopUpButton.accessibilityPerformPress`: Menu tracking is synchronous. Return to the accessibility
client before starting it so that client can choose an item.

### `LokalBotTests/Support/AppAppearanceTests.swift`

#### Menu bar panel keeps macOS sizes until a larger text setting
`testMenuBarPanelUsesSystemSizesAtDefault`: The menu bar panel at Default read a point larger than the system's
own menu bar extras. It keeps macOS sizes until a larger setting.

### `LokalBotTests/Support/BrandContrastTests.swift`

#### Accent text and fills meet WCAG AA 4.5:1 on all surfaces
`BrandContrastTests`: Accent text and filled accent controls must meet WCAG AA (4.5:1) on every
workspace surface in both appearances, including the translucent accent
wash behind tinted buttons and selected rows.

#### Panel text on own fills holds 4.5:1 in four appearances
`testTodayPanelTextMeetsAAInEveryAppearance`: Panels (Today's, and a meeting's) put small text on fills of their
own: the count pill, the red overdue badge, the footer strip with its
link, and the band over a group of rows. Each holds 4.5:1 on the
raised card in light, dark and both Increase Contrast appearances,
where supporting text is drawn in the label colour.

#### Timeline rail and panel small text holds 4.5:1 in four appearances
`testTimelineRailAndPanelTextMeetsAAInEveryAppearance`: Timeline's rail is drawn on the content background, with its chosen
row on the list's unfocused selection; the day's page adds the "All
done" badge and the Done line to the panels. Small text in each holds
4.5:1 in light, dark and both Increase Contrast appearances.

#### Keep macOS 15 window gray reference since native colors vary by release
`BrandContrastTests.surfaces`: Native colors differ by macOS release. Keep a conservative reference
for macOS 15's window gray even when tests run on a newer system.

### `LokalBotTests/Support/DownloadIntegrityTests.swift`

#### Custom models saved before HF pinning fail as not retryable
`testEnsureAvailableReportsUnpinnedSourceAsNotRetryable`: A custom model saved before Hugging Face pinning can never download, so
preparation must fail as not retryable instead of offering a Retry
that repeats the same refusal.

### `LokalBotTests/Support/ExternalAgentHandoffTests.swift`

#### URLSearchParams reads bare plus as space and ampersand as separator; percent-encode
`testPromptSurvivesQueryParsing`: URLSearchParams reads a bare `+` as a space and `&` as a new
parameter, so both must arrive percent-encoded.

### `LokalBotTests/Support/FocusOnAppearTests.swift`

#### Quick Recall must open focused on hosted macOS 26 even when window is not key
`FocusOnAppearTests`: The Quick Recall window opens ready for typing. On hosted macOS 26 it
opened with no field focused, so Return did nothing until the field was
clicked. The window here is off-screen and never key, as a window is while
the app is still coming forward.

#### One AppKit responder handles typing and list navigation keys
`QuickRecallWindow`: Quick Recall's own field: one AppKit responder for typing and for the
keys that move through the list.

#### Typed character reaches text once; list keys reach the list
`testQuickRecallFieldTypesOnceAndSendsListKeysToTheList`: The ⌘K palette's guarantee, kept for this field: a typed character
reaches the text once, and the list's keys reach the list, not the text.

### `LokalBotTests/Support/OutcomeEvidencePolicyTests.swift`

#### Neighboring-clause if once cost speaker a plain I'll (2026-10-05)
`testAConditionOrAHedgeDoesNotChangeWhoseTaskItIs`: A condition says when a task happens, not whose it is. In run-on
speech an "if" from a neighboring clause used to cost the speaker a
plain "I'll" (2026-10-05).

#### Model tidies quotes; tidied quote must still locate spoken words
`testATidiedQuoteStillFindsTheSpokenCommitment`: The model tidies what it copies. A quote without the stumble still
points at the words that were said.

### `LokalBotTests/Support/PaletteCommandFilterTests.swift`

#### Quick Recall matches typed words at least as loosely as palette
`PaletteCommandFilterTests`: Quick Recall lists the commands the ⌘K palette ran, and matches typed
words at least as loosely as the palette did.

#### Word-start matches rank first so Return runs the likeliest command
`testQuickRecallRanksWordStartsBeforeOtherMatches`: Quick Recall finds every command the palette found. Commands whose
words start with what was typed come first, so Return runs the
likeliest one.

### `LokalBotTests/Support/PermissionOverlayTrackerTests.swift`

#### CLI-enabled permission walkthrough left a 3 Hz timer running after Settings closed
`testWalkthroughEndsWhenSystemSettingsIsClosedOrNeverOpens`: Turning a permission on from the command line started a walkthrough
nothing dismissed: after System Settings was closed, a timer ran three
times a second for the rest of the session.

### `LokalBotTests/Support/SystemResourceSamplerTests.swift`

#### Port-keyed ids get a generic label independent of app copy ports
`testEveryServerRoleHasItsMonitorLabel`: A port-keyed id names no role: labels must not depend on which app
copy's ports are in use.

### `LokalBotTests/Support/TestHooksTests.swift`

#### Golden engine answers boundary-review slices relative to the slice start
`testGoldenEngineAnswersARegionSliceRelativeToItsStart`: Boundary reviews re-transcribe sliced regions of a track; the golden
engine answers a slice with that region's segments, relative to it.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
