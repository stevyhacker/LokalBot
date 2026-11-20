# 0019. Mac app: Cotyping

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Cotyping/`.

## Decisions

### `LokalBot/Cotyping/CotypingAXGeometryResolver.swift`

#### Caret geometry and coordinate conversion are independent of focus and privacy policy
`CotypingAXGeometryResolver`: Resolves caret geometry and AX-to-Cocoa coordinate conversion independently
from focus, privacy, and text-capture policy.

#### Returns Cocoa-coordinate rect and whether exact versus frame estimate
`CotypingAXGeometryResolver.caretRect`: Returns the caret rect in global Cocoa coordinates and whether it is
exact (from a range query) vs an element-frame estimate.

#### Web engines ignore NSRange bounds; use AX text markers for caret
`CotypingAXGeometryResolver.caretRect`: Web engines (Chromium / WebKit / Electron) ignore NSRange-based
BoundsForRange and expose caret geometry only via opaque AX text
markers. This is what fixes ghost placement in Chrome/Slack/VS Code-web.

#### Use last AXStaticText run's trailing edge when Chromium returns zero-size rects
`CotypingAXGeometryResolver.caretRect`: Chromium/Electron return zero-size rects from both queries above for
a collapsed caret (measured in Chrome and Discord), but Blink still
exposes each text run as an AXStaticText child with a tight frame:
with the caret at the end of the text, the last run's trailing edge
is the caret. This is what fixes inline ghost placement in Discord.

#### Bounded walk of text runs, only after precise caret queries fail
`CotypingAXGeometryResolver.staticTextLeaves`: AXStaticText descendants of an editable in tree order — Blink's
text-run boxes. Bounded walk: web composers keep this subtree tiny,
and it only runs after both precise caret queries have failed.

#### Previous character bounds in AX coordinates; nil at text or line start
`CotypingAXGeometryResolver.previousCharacterRect`: Bounds of the character just before the caret, in AX coordinates, or
nil at the start of the text or of a line.

#### Web engines give geometry through opaque text markers, ported from Cotabby
`CotypingAXGeometryResolver.textMarkerCaretRect`: Caret rect for web engines that vend geometry via opaque AX text markers
(`AXSelectedTextMarkerRange` → `AXBoundsForTextMarkerRange`) rather than
NSRange-based `AXBoundsForRange`. Ported from Cotabby's AXHelper.

#### Flip through caret's own display so external displays do not use primary height
`CotypingAXGeometryResolver.cocoaRect(fromAX:)`: Accessibility rects are top-left-origin display coordinates. Flip through
the actual display/screen pair containing the caret so external displays do
not inherit the primary display's height.

#### Trust previous character's trailing edge; empty-range rect misplaced in TextEdit, Telegram, Chrome
`CotypingCaretGeometry`: Picks the caret from what a text field reports for the empty range at the
caret and for the character before it. TextEdit and Telegram on macOS 26
report the empty range one line above where it is drawn (measured
2026-10-04: TextEdit at y 190 for a line at y 204, above the field's own
top edge), with the right x. Chrome reports it with no size at all, so a
GitHub review box fell back to a guess at the field's top-left corner
(2026-10-05). In all three the character before the caret is reported
where it is drawn, and its trailing edge is the caret, so the ghost sits on
the line being typed.

#### Allow slack for borders and subpixel rounding inside field
`CotypingCaretGeometry.containmentTolerance`: Slack for a character inside its field (borders, subpixel rounding).

#### Reject line- or field-sized rects Chromium sometimes returns for collapsed selection
`CotypingCaretGeometry.isCollapsedCaret`: Whether a rect reported for the collapsed selection is a caret. Chromium
sometimes answers the text-marker query with the whole line's or the
field's box instead (measured 2026-10-05: 788×23, the field, for a
one-character message in the Claude app; 548×26 at the start of a
Chrome text box), and its trailing edge put the ghost on the line below.

#### Rects in AX coordinates; character trusted only inside field frame
`CotypingCaretGeometry.caret`: All rects in AX coordinates (top-left origin). Nil when neither range
gives a usable caret.

- Parameter elementFrame: the field's frame, read only when there is
  no usable empty range. The character is then trusted only when it
  lies inside the field.

#### Accept only one-glyph-sized character rects, not lines or stale frames
`CotypingCaretGeometry.caret`: One glyph, not a whole line or a stale frame.

### `LokalBot/Cotyping/CotypingAXHelper.swift`

#### AX reads use short system-wide timeout so wedged apps miss a poll, never beachball
`CotypingAXHelper`: The Accessibility boundary for cotyping. Resolves the system-wide focused
element into a value-type `CotypingField` (preceding/trailing text, caret
rect in global Cocoa coords, capability). A trimmed port of Cotabby's
`AXHelper` + `FocusSnapshotResolver` + `AXTextGeometryResolver`: caret
geometry is the zero-length `kAXBoundsForRange` query (exact) with an
element-frame estimate fallback.

All reads go through a system-wide element with a short messaging timeout so a
wedged target app degrades to a missed poll, never a beachball.

#### Canonical bounded preceding window shared with reconciliation and marker synthesis
`CotypingAXHelper.maxPrecedingCharacters`: Bounded context windows so a giant document never ships megabytes into a
prompt or across the actor boundary. `maxPrecedingCharacters` is the
canonical preceding-window limit — session reconciliation
(`CotypingSessionReconciler`) and marker-selection synthesis reference
it so capped-window comparisons can never drift from the AX read path.

#### Accept tap has tight latency budget: capped reads and wall-clock deadline
`CotypingAXHelper.acceptanceMessageTimeoutSeconds`: The accept tap has a much tighter latency budget than background focus
polling. Each individual read is capped and the whole fixed-path snapshot
stops launching new reads at its wall-clock deadline.

#### Caches are lock-boxed for snapshot queue and main-thread acceptance reads
`CotypingAXHelper.CacheState`: Mutable caches are boxed behind a lock because routine reads happen on
the snapshot queue while the event-tap acceptance check remains a
synchronous main-thread read. A field's font, document scope and the
text above it are cached per focused field, so a keystroke reads only
the field itself.

#### Code-field labels reread after two seconds because pages reuse inputs
`CotypingAXHelper.CacheState.codeFields`: Pages reuse one input for an email and then a code, so its
placeholder and label are read again after two seconds.

#### Nearby text is held for focused field only
`CotypingAXHelper.CacheState.visibleContexts`: Nearby text is held for the focused field only.

#### Window text is forgotten when leaving fields, changing app, field, window or document
`CotypingAXHelper.forgetVisibleContext`: Window text is keyed by its window. Leaving every field forgets it
here, and so does focus in another app or another field; a read
for another window or document forgets it too.

#### URL authorization is fresher than surface metadata, captured only with site exclusions
`CotypingAXHelper.domainURLCaptureMaximumAgeSeconds`: URL authorization is deliberately much fresher than prompt surface
metadata. It is captured only when site exclusions are configured.

#### Reread title and placeholder after one second; chat composers span conversations
`CotypingAXHelper.surfaceCaptureMaximumAgeSeconds`: Window title and placeholder are read again once they are a second old. Chat
apps reuse one composer across conversations, so a title kept for as
long as the field stayed focused named the conversation left behind.
A second still lets one suggestion's prediction and validation reads
share a capture.

#### Bounded identity and privacy snapshot; never reads text, geometry, URL or style
`CotypingAXHelper.resolveDictationFocusSnapshot`: A bounded-cost identity/privacy snapshot for dictation delivery. Unlike
`resolveFocus`, this never reads the field value, surrounding text,
caret geometry, window surface, URL, or style.

#### Read selection once on shortcut; web selections come as text-marker ranges
`CotypingAXHelper.selectedTextForSelectionAction`: The focused element's selected text, read once because the person
pressed the selection actions shortcut. Nil without Accessibility
access, for a secure field, or when nothing is selected. WebKit and
Chromium report a web page's selection as a text-marker range.

#### Validate frontmost app and AX element owner before selection read or copy
`CotypingAXHelper.selectionActionFocusIsAllowed`: Validate both the frontmost application and the actual AX element's
owner before a selection read or a process-bound clipboard copy.

#### Read bounded text to confirm paste; compare and drop, never store
`CotypingAXHelper.dictationTextBeforeCaret`: The bounded text before the caret in the field a dictation was pasted
into, to confirm the text arrived. Nil when another field has focus or
the field cannot be read; the caller then makes no claim either way.
The value is compared and dropped, never stored.

#### Read window title and URL only if bound field is focused and not secure
`CotypingAXHelper.dictationLearningSurface`: The window title and page address around the field a dictation was just
pasted into, for Learn from my dictation's exclusions. Same guards as
`dictationTextBeforeCaret`: the bound field must still have focus and
must not be secure. Never reads the field's text.

#### Synchronous fixed-read snapshot validates accept key without full resolveFocus traversal
`CotypingAXHelper.resolveAcceptanceSnapshot`: Captures only the focus identity, marked-text state, selection, and bounded
caret-adjacent text needed to validate one accept key. This is synchronous —
the event tap must decide whether to swallow the original key — but its
fixed read count and per-element timeout replace the old full `resolveFocus`
traversal (caret geometry, Chromium walks, context, URL, and style).

#### Routine callers isolate sync AX reads behind executor; accept uses bounded path
`CotypingAXHelper.resolveFocus`: Resolve the current focus into a cotyping snapshot. The AX reads remain
synchronous inside this implementation, but routine callers isolate them
behind `CotypingAXSnapshotExecutor`. Accept-key validation uses the bounded
`resolveAcceptanceSnapshot(cachedField:)` path instead.

#### Check all cheap metadata for secure fields before reading AXValue
`CotypingAXHelper.resolveFocus`: Secure fields: never read or suggest into them. Some hosts only
expose sensitivity through role description/title/description, so
check all cheap metadata before touching AXValue.

#### Judge verification-code fields by names before reading text
`CotypingAXHelper.resolveFocus`: Verification codes, PINs and one-time passwords: judged from the
field's names before its text is read.

#### Range-based geometry counts like selection, not value; markers place caret there
`CotypingAXHelper.resolveFocus`: Range-based geometry counts the way the selection does, not the
value; text markers place the caret there instead.

#### Surface context costs extra AX round trips; read only when building suggestion
`CotypingAXHelper.resolveFocus`: App/window context — only read when actually building a suggestion (it
costs extra AX round-trips), gated by the cotyping setting upstream.

#### Read tab URL only when domains configured; costs bounded ancestor walk
`CotypingAXHelper.resolveFocus`: Per-site rules: read the tab URL only when domains are configured (it
costs an extra bounded ancestor walk), gated by the coordinator.

#### Read field style, cached, only when style matching enabled
`CotypingAXHelper.resolveFocus`: Host field font/color — read (cached per field) only when matching is
enabled, so the overlay can mimic the field instead of a fixed style.

#### Chromium range attributed string lacks font; marker one has size and color
`CotypingAXHelper.resolveFocus`: Chromium's range-based attributed string carries no font;
its marker-based one has the size and text color.

#### Skip window capture in terminals where suggestions never come
`CotypingAXHelper.resolveFocus`: `CotypingAvailability` never suggests in a terminal app, so its
window is not captured and read for a suggestion that cannot come.

#### Whole-window text supersedes the column above the field once read
`CotypingAXHelper.resolveFocus`: The whole window, once a background read of it exists, includes
everything the column above the field would add.

#### Window walk takes tens of ms: once per field, then in background
`CotypingAXHelper.resolveFocus`: Walking the window takes tens of milliseconds, so it runs once
per field and then in the background, never per keystroke.

#### Policy revocation during cross-process read drops its result
`CotypingAXHelper.resolveFocus`: A policy revocation during a cross-process read drops its result.

#### Wake Chromium trees lazily; cache PIDs, reassert Electron editors per activation
`CotypingAXHelper.primeWebAccessibilityIfNeeded`: Wakes Chromium/Electron web accessibility trees lazily, matching
CoTabby's focus pipeline. Safe to call on every poll: successful and
unsupported PIDs are cached, while named Electron editors get one
re-assertion per activation edge.

#### Never reuse previous browser URL as authorization after returning to it
`CotypingAXHelper.primeWebAccessibilityIfNeeded`: Returning to a browser may reveal another tab or a page that
navigated while inactive. Never reuse its previous URL as an
authorization decision.

#### Turning off hands back every browser asked for enhanced accessibility
`CotypingAXHelper.configureChromiumEnhancedAccessibility`: Whether Chrome-based browsers are asked for enhanced accessibility
(Settings → Autocomplete → Advanced). Turning it off hands back every
browser this process asked.

#### Chrome needs AXEnhancedUserInterface for exact caret and font; costs speed
`CotypingAXHelper.requestChromiumEnhancedAccessibilityIfNeeded`: Chrome turns on its complete accessibility mode, where text markers
report the caret's exact bounds and text its font size, only for
`AXEnhancedUserInterface`; it ignores `AXManualAccessibility`. Without
it the caret was found on screen and the font size guessed, so Reddit
suggestions came out too large or in a popup over the text
(2026-10-21). Cotypist asks Chrome the same way. Chrome then also
behaves as if a screen reader were running, which costs it some speed
and can slow window-manager animations, so Settings can turn it off.
Chrome counts these requests: one is sent per browser process, and a
forced quit leaves the mode on until the browser restarts.

#### Marker reads are best-effort and uncached; nil keeps native-range unsupported path
`CotypingAXHelper.synthesizeMarkerSelection`: Chromium/WebKit contenteditable fields can expose caret text through the
opaque text-marker API instead of `AXSelectedTextRange`. The marker reads
are best-effort and never cached; nil means the existing native-range
unsupported path remains in force.

#### Chromium selection omits paragraph line breaks; realign counts to value
`CotypingAXHelper.paragraphAlignedSelection`: `selection` in `value`'s own count: Chromium reports a rich-text
field's selection without the line breaks its value has between
paragraphs (`CotypingParagraphBreakAlignment`). The text before the
caret, read with `AXStringForRange`, is counted the way the selection
is. Unchanged for one-line values and for hosts whose counts agree.
`skipsBreaks` when the app's range text ends short of its value, as
Chromium's does when the value has paragraph breaks; only then is the
text before the caret read and the selection moved.

#### Style read is synchronous cross-process, so cache and gate behind includeStyle
`CotypingAXHelper.resolveFieldStyle`: Reads the focused field's own font + text color (cached per element) so
the ghost overlay can match it. Best-effort: nil on any miss → overlay
defaults. The parameterized attributed-string read is a synchronous
cross-process call, so it is cached and gated behind `includeStyle`.

#### Prefer character before caret then first; clamp against off-by-one carets
`CotypingAXHelper.resolveFieldStyle`: Prefer the character just before the caret (what the user is extending),
then the first character; clamp so an off-by-one caret never reads OOB.

#### Do not re-ask apps whose marker style read missed for 30 seconds
`CotypingAXHelper.markerStyleMissInterval`: How long an app whose marker-based style read found nothing is not
asked again. Chrome sends no font without extended accessibility, and
its fields change identity on every read, so the per-field style
cache never holds that miss.

#### Record no miss when no text precedes caret
`CotypingAXHelper.markerFieldStyleUnlessMissed`: With no text before the caret there is no character to read a style from.

#### Handle AppKit font and color shapes plus AX font dict and CGColor
`CotypingAXHelper.extractFieldStyle`: Extracts a `CotypingFieldStyle` from one character's attributes, handling
both the AppKit `.font`/`.foregroundColor` shapes and the AX font-dict /
CGColor shapes AX returns from web content.

#### Web content may report fill under AXBackgroundColor not AppKit key
`CotypingAXHelper.extractFieldStyle`: Web/AX content sometimes reports the fill under an `AXBackgroundColor`
run attribute rather than the AppKit `.backgroundColor` key.

#### Verify CF type id before force-casting CGColor; conditional cast does not compile
`CotypingAXHelper.colorAttribute`: Extracts a 6-digit hex color from a run attribute, handling both the
AppKit `NSColor` shape and the `CGColor` shape AX returns from web content
(a conditional `as?` to `CGColor` does not compile against `Any`, so the CF
type id is verified before the force-cast).

#### Keystroke reads only frame and title; AX privacy walk runs with the read
`CotypingAXHelper.windowTextSnapshot`: Text recognized in the focused field's window, read in the background.
A keystroke reads only the field's frame and window title here; the
Accessibility walk for the privacy checks runs with the read itself.

#### Recheck policy for every use since grant or exclusion may change
`CotypingAXHelper.windowTextSnapshot`: Checked again for every use: the grant or an exclusion may have changed.

#### AX elements are safe to read from any thread
`CotypingAXHelper.UncheckedElement`: Accessibility elements are safe to read from any thread.

#### Best-effort bounded window title carrying subject, document, channel or page
`CotypingAXHelper.windowTitle(near:)`: Best-effort title of the window containing `element`: `kAXWindowAttribute`
→ `kAXTitleAttribute`. One bounded round-trip; nil on miss. Carries the
email subject, document name, channel, or page title.

#### Chromium leaves description empty when label names field; read other names
`CotypingAXHelper.codeFieldLabels`: The names a field carries besides its title and description: its
placeholder, help text, DOM id and the label element it points to.
Chromium leaves a field's description empty when a `<label>` names it,
so a code field is often named only here. Cached per field.

#### Detect own panel or sheet parent window, cached per field
`CotypingAXHelper.isInFileDialog`: Whether `element` is in an app's own open or save panel: its window, or
the window a sheet such as Go to Folder hangs from. Cached per field.

#### Only a web area's own URL authorizes learned text, not a link's
`CotypingAXHelper.learningDocumentURL`: A link's AXURL is not the containing document's identity. Only a web
area's own URL can authorize learned text for a browser document.

#### Reread cached title and placeholder once older than max age
`CotypingAXHelper.cachedSurfaceCapture`: The field's window title and placeholder from `store`, read again with
`read` once the cached pair is older than `surfaceCaptureMaximumAgeSeconds`.

#### Failed URL read counts as blocked for browsers when site exclusions configured
`CotypingAXHelper.webURL`: Best-effort, fail-safe read of the focused tab's URL near `element`, for
per-site rules. Browsers expose `kAXURLAttribute` on the web area or window
rather than the focused field, so walk up a bounded number of ancestors.
Nil on any miss (non-browser, attribute absent, climb exhausted). When
site exclusions are configured, availability treats that uncertainty as
blocked for browsers rather than bypassing the user's rule. Never mutates
AX state.

#### Accept URL, NSURL or string values of AXURL
`CotypingAXHelper.urlString`: Reads `kAXURLAttribute` as a string, tolerating a `URL`/`NSURL` (the usual
case) or an already-string value.

#### No Chromium hit-test fallback; pointer is not keyboard focus and climb too slow
`CotypingAXHelper.focusedElementForAcceptance`: Focus lookup for the consuming event tap. No Chromium hit-test fallback:
pointer hit-testing does not prove keyboard focus, and the normal helper's
ancestor climb is too expensive for a synchronous global event callback.

#### Nil means deadline expired; unknown means host exposes neither representation
`CotypingAXHelper.markedTextState`: Returns nil when the wall-clock acceptance budget expires between AX
reads. That is different from `.unknown`, which means the reads completed
but the host exposes neither marked-text representation.

#### Prefer native ranges, then markers; fail open unless whole value proven bounded
`CotypingAXHelper.boundedAcceptanceContent`: Reads only the text windows needed for exact accept-time reconciliation.
Native AX ranges are preferred. Marker-only web editors use index-addressed
text markers. A host that supports neither path fails open unless it first
proves that its entire value is itself bounded to the combined window.

#### Read context like resolveFocus when selection counts omit paragraph breaks
`CotypingAXHelper.paragraphAlignedAcceptanceContent`: The text around the caret read the way `resolveFocus` reads it, for a
field whose app counts its selection without the value's paragraph
breaks: `AXStringForRange` windows have no breaks there, so they never
match the snapshot the suggestion was made from, and an accept would
be refused whenever the caret has paragraphs around it.

#### Read AXValue only after character count proves it fits bounded windows
`CotypingAXHelper.boundedNativeAcceptanceContent`: Some short native controls expose AXValue + AXSelectedTextRange but
not AXStringForRange. Read AXValue only after AXNumberOfCharacters has
proven that the complete value is no larger than our bounded windows.

#### Some Chromium fields resolve only via app-scoped AX object
`CotypingAXHelper.focusedElement`: Some Chromium/Electron fields are missed by the system-wide focused
element query but still resolve through the app-scoped AX object.

#### Pin 50 ms timeout on focused element so wedged apps cannot block resolveFocus
`CotypingAXHelper.focusedElement(from:)`: Pin the timeout on the focused element too so a wedged target app can
never block the reads in `resolveFocus` past 50 ms. They run on
`CotypingAXSnapshotExecutor`'s worker queue.

#### Return nil rather than arbitrary hit-test leaf; insertion targets focused element
`CotypingAXHelper.nearestEditable`: Climb from a Chromium hit-test leaf to the nearest likely editable
container. Nil is safer than returning an arbitrary hit-test leaf: event
insertion is global and would target the actually focused element.

#### Find Paste by Cmd-V equivalent, only for dictation; cotyping never touches menus
`CotypingAXHelper.pasteMenuItem`: Locates the host app's Paste command by its Cmd-V key equivalent rather
than localized title. Used only by dictation delivery; cotyping's
consuming event tap never walks host menus or touches the pasteboard.

#### Selection is UTF-16 NSRange; length zero is a caret
`CotypingAXHelper.selectionRange`: The caret/selection as an NSRange (UTF-16). `length == 0` is a caret.

### `LokalBot/Cotyping/CotypingAXPolicies.swift`

#### Pair AX identifier with element hash since identifiers are not unique
`CotypingAXFocusIdentityKey`: Builds the focused-element key used to authorize a consuming accept. AX
identifiers are app-provided labels and are not required to be unique (for
example, repeated SwiftUI rows can expose the same identifier). Pairing that
label with the concrete AX element hash keeps two same-text fields from
authorizing each other's synthetic edit.

#### Search boxes stay quiet like Cotypist; Tab belongs to results
`CotypingSearchFieldDetector`: Search boxes stay quiet, as they do in Cotypist: a query is not prose to
continue, and Tab there belongs to the results list.

#### File dialogs stay quiet; detect panel window identifiers and parent of sheets
`CotypingFileDialogDetector`: Open and save dialogs stay quiet, as they do in Cotypist 2026.5: a file
name is not prose to continue. AppKit names the panel's window
`save-panel` or `open-panel` in every language. A sheet on the panel, such
as Go to Folder, is checked through the window it hangs from. Sandboxed
apps show these panels from another process, whose fields
`CotypingAXHelper.resolveFocus` never reads.

#### Accept reads use 4096/1024 UTF-16 windows; whole-value fallback only if proven small
`CotypingAcceptanceContentBounds`: Pure bounds for accept-time text reads. The event tap never needs the whole
host document: it only needs the same 4,096/1,024 UTF-16 windows carried by
`CotypingField`. Hosts that cannot provide bounded ranges are eligible for a
whole-value fallback only when AX first proves the entire value is no larger
than those windows combined.

#### Drop outermost grapheme of clipped range; AX can cut it
`CotypingAcceptanceContentBounds.context`: Prediction and acceptance apply this same policy to identical UTF-16
ranges. Discard the outermost grapheme of a clipped range: AX can cut a
surrogate pair, combining sequence, or joined emoji at that boundary.

#### Cap deletion bursts so event-tap watchdog cannot fire before fail-open
`CotypingSyntheticEditPolicy`: Hard ceiling for deletion bursts posted from the consuming event tap. Every
deleted grapheme creates and posts a down/up event pair, so an unbounded typo
or overlap could otherwise trigger the event-tap watchdog before the original
key can fail open.

#### Unknown differs from inactive; some editors expose no marked-text attribute
`CotypingMarkedTextState`: Whether the currently focused input reports an active marked-text range.
`unknown` is distinct from `inactive`: some third-party editors expose no
marked-text Accessibility attribute at all.

#### Omit geometry, style, window, URL, DOM reads so slow hosts cannot stall tap
`CotypingAXAcceptanceSnapshot`: Minimal live state needed by the consuming accept tap. Unlike a prediction
snapshot, this deliberately omits geometry, style, window, URL, DOM, and
ancestor-tree reads so a slow host cannot keep the global keyboard event in
the tap callback for an unbounded Accessibility walk.

#### Require live collapsed selection and ranges; mouse selection could be overwritten
`CotypingAXAcceptanceSnapshot.hasLiveContent`: True only when a live collapsed selection and bounded surrounding-text
ranges were both read at accept time. Identity-only validation is
insufficient even for continuations: a mouse selection can change without
crossing the keyboard observer, causing a synthetic Unicode insert to
overwrite newly selected text.

#### Fail closed to accept but rejection passes original key through
`CotypingAcceptanceSnapshotPolicy`: Fail-closed policy for deciding whether a bounded accept-time snapshot is
trustworthy enough to consume the user's key. Rejection itself is fail-open
for the keyboard: the original event passes through to the host unchanged.

#### Composing or unknown input source always passes Tab through for IME candidates
`CotypingAcceptanceSnapshotPolicy.canAccept`: Tab may belong to an IME's candidate UI even when the host currently
reports an inactive marked range. A composing (or unknown) input
source therefore always passes the original key through untouched.

#### Hit-test candidates must prove ownership, editability and focus
`CotypingAXHitTestFocusValidator`: Pure authorization rule for the AX hit-test fallback. Hit-testing describes
what is under the pointer, not what will receive keyboard input, so every
candidate must independently prove ownership, editability, and focus.

#### Chrome enables mode despite reported error; only timeout means not asked
`CotypingEnhancedAccessibilityRequest`: Chrome turned on enhanced accessibility in testing (2026-10-21) although
setting `AXEnhancedUserInterface` reported an error, so only a timeout
means the browser was not asked; anything else is not asked again.

### `LokalBot/Cotyping/CotypingAXSnapshotExecutor.swift`

#### Option set lets executor merge queued requests into one superset capture
`CotypingAXCaptureOptions`: Options for one Accessibility snapshot. Keeping these as an option set lets
the executor merge queued requests into one superset capture.

#### One active capture, one latest-wins pending batch, whole-snapshot deadline
`CotypingAXSnapshotExecutor`: Runs all routine AX snapshots on one background queue. There can be at most
one active capture and one latest-wins pending batch; callers that arrive
while a compatible capture is active share its result. Each caller has one
wall-clock deadline for the *whole* snapshot, rather than multiplying the AX
per-message timeout by every attribute read.

### `LokalBot/Cotyping/CotypingAcceptOptions.swift`

#### No whole case because full-accept key already takes the whole tail
`CotypingAcceptGranularity`: How much the primary accept key takes per press. The full-accept key always
takes the whole remaining tail, so this has no "whole" case (that would
duplicate it) — mirrors Cotabby's `AcceptanceGranularity`.

#### Curated safe accept keys instead of free shortcut recording
`CotypingAcceptKey`: The primary accept key (take the next word/phrase). Curated safe choices
rather than a free record-shortcut UI.

#### Escape is touched only while a suggestion is showing
`CotypingEscapeBehavior`: What Escape does while a suggestion is showing. The rest of the time
Escape is never touched.

#### Escape dismisses, is swallowed, field quiet briefly; matches Cotypist default
`CotypingEscapeBehavior.pause`: The suggestion goes away, the key stops here, and the field stays quiet
for a few seconds. Matches Cotypist's default.

#### Primary key wins when both accept keys are the same
`CotypingAcceptHint.text`: The primary key wins when both are bound to the same key.

### `LokalBot/Cotyping/CotypingAcceptanceChunker.swift`

#### Overlay highlight and accept path share one segmentation model
`CotypingAcceptanceChunker`: Pure word/phrase segmentation for suggestion acceptance: what one Tab
accepts (`nextWord` / `nextPhrase`), how the accepted chunk is adjusted for
insertion (whitespace dedupe, auto-space), and accepted-word accounting.
Extracted from the coordinator so the overlay's highlight and the accept
path share one segmentation model.

#### Space-less scripts use ICU segmentation so accept advances by word-sized unit
`CotypingAcceptanceChunker.nextWord`: First word-like acceptance chunk of `text`, preserving leading
whitespace. Space-less scripts use ICU word segmentation so one accept
advances by a word-sized unit instead of swallowing a whole CJK/Thai run.

#### Phrase ends at ASCII terminators, newlines, CJK clause marks; ASCII commas stay
`CotypingAcceptanceChunker.nextPhrase`: Text up to and including the next sentence/clause boundary (or the whole
remaining text when there is none). Mirrors Cotabby's phrase acceptance
granularity: ASCII sentence terminators, newlines, and CJK clause marks;
ASCII commas stay inside the phrase.

### `LokalBot/Cotyping/CotypingAvailability.swift`

#### Per-keystroke field eligibility only; permission gating is at subsystem start
`CotypingAvailability`: Pure per-field gating: given the settings and the current focus, should
cotyping offer a suggestion here? Mirrors the relevant subset of Cotabby's
`SuggestionAvailabilityEvaluator`. Permission gating (Accessibility / Input
Monitoring) is handled at subsystem start by `CotypingCoordinator`; this
decides only the per-keystroke "is this field eligible" question.

#### Never suggest inside LokalBot to avoid feedback into own UI
`CotypingAvailability.disabledReason`: Never suggest inside LokalBot itself (avoids feedback into our own UI).

#### Site exclusion is a privacy boundary; unverified browser host pauses suggestions
`CotypingAvailability.disabledReason`: A configured site exclusion is a privacy boundary, not a best-effort
hint. If AX cannot prove the current browser host, pause there rather
than treating a failed URL read as permission. Non-browser apps remain
usable because they do not have a meaningful tab URL to authorize.

#### Case-insensitive substring match on app name and bundle identifier
`CotypingAvailability.isExcluded`: Case-insensitive substring match against the user's exclusion list,
checked against both the app display name and bundle identifier.

#### Be conservative: false positive hides autocomplete, false negative leaks secrets
`CotypingSecureFieldDetector`: Conservative, pure classifier for sensitive focused fields. Accessibility
hosts do not always expose native password boxes as `AXSecureTextField`;
some only surface a role description or label. A false positive only hides
autocomplete, while a false negative could show a secret as ghost text.

#### Code fields stay quiet; read placeholder, label, id; match whole words
`CotypingCodeFieldDetector`: Fields for a verification code, PIN or one-time password stay quiet: a
code is not prose to continue. Web pages often name such a field only
through its placeholder, its `<label>` or its element id, which
`CotypingSecureFieldDetector` does not see, so autocomplete reads those
too. Matches whole words, so "pin" never matches "pinned". A false
positive only hides autocomplete in one field.

#### Split at non-alphanumerics and camelCase so element ids read as words
`CotypingCodeFieldDetector.words`: Lowercased words, split at anything that is not a letter or digit and
at camelCase humps, so the element ids `otpInput`, `SMSCode` and
`verification-code` read as words too.

#### Code alone names a code field; also next to context words
`CotypingCodeFieldDetector.codeWords`: "Code" alone names a code field; next to one of `codeContextWords` it
does too ("Enter the 6-digit code", "Code sent by SMS").

#### Context words include Serbian, Croatian, Bosnian in Latin and Cyrillic
`CotypingCodeFieldDetector.codeContextWords`: Serbian, Croatian and Bosnian, in Latin and Cyrillic.

#### Phrases are written as words(in:) splits them
`CotypingCodeFieldDetector.phrases`: Multi-word names, written as `words(in:)` splits them.

#### App exclusions authorize the AX read itself; unknown owners fail closed
`CotypingAppReadPolicy`: App exclusions authorize the Accessibility read itself, before field text is
available to the prediction pipeline. Unknown app owners fail closed.

### `LokalBot/Cotyping/CotypingBackgroundSampler.swift`

#### Sample via ScreenCaptureKit; cache per field and appearance, not per app
`CotypingBackgroundSampler`: Samples the average luminance of the host pixels behind the cotyping caret,
reusing the same ScreenCaptureKit engine (and Screen Recording grant) as the
screenshot pipeline. `CGWindowListCreateImage` is unavailable on current
SDKs, so this is the supported way to read what's actually on screen.

The overlay panel sets `sharingType = .none`, so a capture never includes our
own ghost. Results are cached per field and light or dark mode: a field's
background rarely changes, and a fresh capture would recolor the ghost a
moment after it appears. Not per app: one browser shows light and dark pages.

#### Fresh cached luminance colors ghost instantly without capture or flash
`CotypingBackgroundSampler.cachedLuminance`: A still-fresh luminance for the field `fieldKey` names, used to color
the ghost instantly (no capture, no flash) for repeat suggestions there.

#### Luminance 0 to 1; nil without Screen Recording so caller keeps guess
`CotypingBackgroundSampler.sampleLuminance`: Capture the strip behind `caretRect` and return its average luminance
(0…1), caching it for `fieldKey`. `nil` when Screen Recording isn't
authorized or the capture fails — the caller keeps its AX/appearance guess.

#### Capture whole points at backing scale; SCK fractional scaling leaves black columns
`CotypingBackgroundSampler.captureConfiguration`: The strip to the right of the caret, where the ghost draws, in the
display's top-left point space, captured at its own pixel size.
ScreenCaptureKit widens a fractional source to whole points, fits it
inside the output keeping its aspect, and leaves whatever lies off the
display black. Measured 2026-10-05: a 166×17 pt strip asked for at
32×3 came back with its last 2–4 columns black, pulling a white field
from 0.97 to 0.85. Whole points at the backing scale need no scaling;
`scalesToFit` makes a scale mismatch stretch rather than leave black
(without it ScreenCaptureKit only scales down). `nil` off the display.

#### Rec. 601 mean luminance via 1x1 downscale
`CotypingBackgroundSampler.averageLuminance`: Mean Rec. 601 luminance of `image`, via a 1×1 downscale that averages it.

### `LokalBot/Cotyping/CotypingBenchmark.swift`

#### Word-completion scenarios must visibly extend fragment with a word character
`CotypingBenchmarkScenario.expectsWordCompletion`: Word-completion contract (Cotypist parity): the caret sits at the end of
a word fragment and a visible suggestion MUST extend it — begin with a
word character, and (when provided) with one of
`expectedCompletionPrefixes`, the tails of every real word that fits the
fragment. Silence is safe but counts as a miss unless it is one of the
`allowedSuppressions`.

#### Mirrors coordinator spell-check verdict driving whitespace-leading rejection
`CotypingBenchmarkScenario.wordPrefixIsValidWord`: Mirrors the coordinator's spell-checker verdict for the fragment at the
caret; drives the normalizer's whitespace-leading rejection.

#### 26 scenarios in four groups with latency targets 2000/1500/1200 ms
`CotypingBenchmarkScenario.defaults`: 26 scenarios in four groups: next-word continuations, word completions
(the caret is mid-word and the suggestion must finish the word — the
Cotypist parity gap), strictly-inside-word safety, and context/format
robustness. Latency targets: 2000 ms for the cold first case, 1500 ms
steady-state, 1200 ms for short mid-word prompts.

#### Fragments no dictionary word equals must be extended (Cotypist parity)
`CotypingBenchmarkScenario.defaults`: — Word completion: caret at the end of a fragment no dictionary word
  equals, so the ghost text MUST extend it (Cotypist parity) —

#### Valid-word fragments allow extend or next word; assert only visibility
`CotypingBenchmarkScenario.defaults`: — Word fragments that are already valid words: both "extend the word"
  and "start the next word" are legitimate, so only visibility is
  asserted —

#### Strictly inside a word, continue the word or stay quiet
`CotypingBenchmarkScenario.defaults`: — Strictly inside a word (text after the caret): the suggestion must
  continue the word or stay quiet —

#### Withheld means no suggestion where one expected, e.g. confidence gate
`CotypingBenchmarkOutcome.withheld`: No suggestion where one was expected, e.g. the confidence gate held it back.

#### Unsafe means prompt leak, corrupted word or insertion where silence required
`CotypingBenchmarkOutcome.unsafe`: Text that would damage the field: a leaked prompt, a split or corrupted
word, or any insertion where silence was required.

#### Letters after caret mean any insertion lands inside an existing word
`CotypingBenchmarkCaseResult.insideWord`: Letters follow the caret, so any insertion lands inside an existing word.

#### Leading space or punctuation would split the word
`CotypingBenchmarkCaseResult.outcome`: The ghost text sits right after the fragment: a leading space or
punctuation would split the word ("follo w up").

#### Wrong tail is a miss at word end but corrupts text inside a word
`CotypingBenchmarkCaseResult.outcome`: A wrong tail is only a miss at the end of a word; inside one it
corrupts the text that follows the caret.

#### Safe means no leak, corruption, forced-silence insertion or error; quiet is safe
`CotypingBenchmarkCaseResult.passedSafety`: Nothing harmful reached the field: no prompt leak, no split or corrupted
word, no text where silence was required, and no engine error. Staying
quiet is safe; how often that happens is reported as `withheld`.

#### Word-completion hit reported separately as Cotypist-parity rate
`CotypingBenchmarkCaseResult.wordCompletionHit`: True when the suggestion completes the caret fragment into an accepted
word (word-completion scenarios only) — surfaced separately so summaries
can report the Cotypist-parity rate on its own.

#### Cotypist-parity signal counts completions extending the typed fragment
`CotypingBenchmarkSummary.wordCompletionTotal`: Cotypist-parity signal: of the scenarios that demand a word completion,
how many produced a suggestion that extends the typed fragment.

#### JSON consumed by Benchmarks/autocomplete/Cotyping/side_by_side.py
`CotypingBenchmarkSummary`: Machine-readable rendering for `LokalBot --cotyping-bench` — the scriptable
evaluation model consumed by `Benchmarks/autocomplete/Cotyping/side_by_side.py`.

#### Report splits load time and first-pass versus warm-pass latency
`CotypingEngineBenchmarkReport`: `LokalBot --cotyping-bench --model-path` output: pass 1's scenario results,
model loading on its own, and latency split into the first pass (each
prompt seen for the first time after loading) and the warm passes after it.

#### Greedy decoding means every pass should show identical output
`CotypingEngineBenchmarkReport.consistentAcrossPasses`: Decoding is greedy, so every pass should show exactly the same thing.

#### Nearest-rank percentiles match the replay scripts
`CotypingEngineBenchmarkReport.latency`: Nearest-rank percentiles, as the replay scripts compute them.

#### Reads only given model, fresh-install settings; exit 1 on unsafe or error
`CotypingBenchmarkRunner.runEngine`: Runs every scenario `passes` times against the runtime the app builds for
autocomplete, with fresh-install settings. Like `--cotyping-replay`, it
reads only the given model: no saved settings, library, learning or
window. Exit 1 when anything was unsafe or errored.

### `LokalBot/Cotyping/CotypingBrowserDomain.swift`

#### Host matching is pure; URL is read over AX elsewhere; ported from Cotabby
`CotypingBrowserDomain`: Pure host/domain matching for per-site cotyping disable. Ported from Cotabby's
`BrowserDomain`: turn a focused tab's URL into a comparable host and decide
whether it's covered by the user's disable list. The raw URL is read over
Accessibility elsewhere (`CotypingAXHelper.webURL`); this stays pure and
trivially testable.

#### Drop leading www; nil for URLs without network host
`CotypingBrowserDomain.host(fromURLString:)`: Lowercased host from a URL string, dropping a leading "www." so
"www.bank.com" and "bank.com" compare equal. Nil for URLs with no network
host (`file://`, `about:`, empty, unparseable), so non-web focus never
matches a domain rule.

#### Exact or subdomain match, case and www insensitive; entries may be full URLs
`CotypingBrowserDomain.isHostDisabled`: Whether `host` is covered by `excludedDomains`: an exact match, or a
subdomain of a listed domain ("mail.bank.com" is disabled by "bank.com").
Case- and "www."-insensitive on both sides; list entries may be pasted as
full URLs. An empty/nil host or empty list never matches.

### `LokalBot/Cotyping/CotypingClipboardContext.swift`

#### Sanitize non-field context since shell prompts, fences and ANSI get copied by small models
`CotypingPromptContextSanitizer`: Deterministic sanitizer for auxiliary context that did not come from the
focused text field. Clipboard text often carries shell prompts, Markdown
fences, ANSI color escapes, and punctuation-heavy output that small local
models can copy back into suggestions.

#### Clipboard snippets memoized in memory only, never persisted or logged
`CotypingClipboardContext`: Sanitized clipboard context folded into the cotyping prompt so the model can
"see" what was just copied — a trimmed port of Cotabby's clipboard context
(`ClipboardRelevanceFilter` + request-factory clipping). The sanitization,
bounding, relevance checks, and an "already-in-the-field" guard are pure
here; reading the pasteboard is a thin runtime wrapper
(`CotypingClipboardProvider`).

Enabled by default when cotyping runs; snippets may be memoized in memory for
one focused field/pasteboard state to keep the prompt prefix stable, but are
never persisted or logged.

#### Hard 1,200-character snippet cap mirrors Cotabby
`CotypingClipboardContext.maxSnippetCharacters`: Hard cap on the snippet included in the prompt (mirrors Cotabby's 1_200).

#### Nil for empty, whitespace-only or punctuation-only clipboard text
`CotypingClipboardContext.sanitize`: Sanitizes raw clipboard text: strips prompt-shaped noise, collapses
inline whitespace, keeps meaningful line boundaries, and caps the length.
Nil for empty, whitespace-only, or punctuation-only input.

#### Skip snippets already present in the field, e.g. after pasting
`CotypingClipboardContext.shouldInclude`: Whether a clipboard snippet is worth including: false when it is empty, or
when it is already present in the text the user is typing (no point
re-injecting what is already in the field — e.g. right after pasting it).

#### Short snippets pass; long unrelated copies fall back to small head sample
`CotypingClipboardContext.distill`: Keep only the clipboard lines that share meaningful tokens with the
current prefix. Short snippets pass through unchanged; long unrelated
copies fall back to a small head sample rather than crowding the prompt.

#### First pasteboard observation is unknown-age baseline; only later fresh related copies enter
`CotypingClipboardRelevanceFilter`: CoTabby-style gate for clipboard context. The first pasteboard observation is
treated as an unknown-age baseline, not a fresh copy. Only later copies made
during this app session can enter the prompt, and then only while fresh and
related to the typed prefix.

#### Nil verdicts not memoized so they re-evaluate as user types
`CotypingClipboardPrefaceMemo`: One pinned, non-empty clipboard-context verdict for a focused field and a
pasteboard state. Nil verdicts are intentionally not represented: they add
nothing to the prompt and should re-evaluate as the user types more context.

#### Check sensitivity markers before reading text; concurrent change invalidates observation
`CotypingClipboardProvider`: Checks sensitivity markers before asking a pasteboard owner for any text.
A concurrent pasteboard change invalidates the entire observation.

### `LokalBot/Cotyping/CotypingCompositionInputMode.swift`

#### Layouts commit directly; other input methods compose except known direct-ASCII modes
`CotypingCompositionInputModeClassifier`: Pure rule for deciding whether the active keyboard input source composes
through marked text. Plain keyboard layouts commit directly; non-layout
input methods are treated as composing except known direct-ASCII modes.

#### Cache composition state so accept tap avoids Carbon at event time
`CotypingKeyboardInputSourceMonitor`: Caches the current Text Input Source composition state so the accept tap can
pass IME-owned keys through without touching Carbon at event time.

#### Fail closed when Carbon cannot prove direct layout so Tab stays with host
`CotypingKeyboardInputSourceMonitor.refresh`: Carbon could not prove a direct-input keyboard layout. Fail
closed for suggestion ownership so Tab remains with the host.

### `LokalBot/Cotyping/CotypingContextReport.swift`

#### Settings shows each context source's availability beside its switch
`CotypingContextAvailability`: What each optional context source can contribute right now. Settings shows
this beside its switch, so a grant that is on but cannot take effect says
why instead of looking active.

#### Counts only finished meetings recent enough to supply a fact
`CotypingContextAvailability.Inventory.recentMeetings`: Finished meetings recent enough to supply a fact.

#### Mixed meeting-and-screen facts need both grants
`CotypingContextAvailability.Inventory.mixedFacts`: Facts combining meeting and screen sources; they need both grants.

#### Overnight review flag only changes wording of the status
`CotypingContextAvailability.Inventory.overnightReviewOn`: Only affects wording: whether new work memory is still being added.

#### Available means on with something usable when relevant
`CotypingContextAvailability.State.available`: On, and there is something it can use when it is relevant.

#### Unavailable means on but a dependency is off or missing
`CotypingContextAvailability.State.unavailable`: On, but something it depends on is off or missing.

#### Facts built from meetings and screen need both grants
`CotypingContextAvailability.screenMemoryState`: A fact built from meetings and screen activity needs both grants.

#### Source titles are grouped by the grant that admitted them
`CotypingContextUse.meetingSources`: Titles of the saved sources used, by the grant that admitted them.

#### Searched flag is set whether or not the lookup found anything
`CotypingContextUse.searchedMemory`: A saved-memory lookup ran, whether or not it found anything.

#### Ready means source is on and working but added nothing this time
`CotypingContextStatus.Tone.ready`: The source is on and working; it had nothing to add this time.

#### Three sources listed in Settings order; use is nil before first suggestion
`CotypingContextStatus.rehearsal`: The three optional sources, in the order Settings lists them. `use` is
nil until a suggestion has been generated.

#### Rehearsal reads its own sample, so status reports both facts
`CotypingContextStatus.visibleText`: The rehearsal still reads its own sample, so say both things.

#### Synthetic exchange is offered like nearby text when the visible-text grant is on
`CotypingRehearsalConversation`: The synthetic exchange above the rehearsal's reply field. When the
visible-text grant is on it is offered to the model the way nearby text is
in another app, so the setting can be judged without leaving Settings.

#### Line format matches how a chat app exposes text to the model
`CotypingRehearsalConversation.Message.line`: How the line reads to the model, as a chat app exposes it.

#### Synthetic layout goes through live capture rules; nothing on screen is read
`CotypingRehearsalConversation.snapshot`: The messages as a live capture would select them: the same bounded
traversal, limits and text filters, run over a synthetic layout. Nothing
on screen is read.

### `LokalBot/Cotyping/CotypingContinuationAcceptance.swift`

#### Live accept tap and Settings rehearsal share one acceptance plan
`CotypingContinuationAcceptance`: What one accept keypress does to a continuation: how much of the suggestion
it consumes and the exact text to put at the caret. The live accept tap and
the Settings rehearsal both plan here, so a rehearsed Tab takes the same
word or phrase, with the same spacing and punctuation, as Tab in another app.

#### Insertion text dedupes whitespace, adds sentence space and optional trailing space
`CotypingContinuationAcceptance.insertionText`: Text to insert: the chunk with duplicate whitespace removed, a sentence
space added, and the optional trailing space applied.

#### Completing a mid-word suggestion replaces characters after the caret
`CotypingContinuationAcceptance.forwardDeleteCount`: Characters after the caret that the insertion replaces when the
suggestion completes a word the user is in the middle of.

#### Rehearsal suggestion advances by the same rules as a live field
`CotypingRehearsal`: The rehearsal editor's suggestion, advanced by the same rules as a live
field: an accept takes the configured amount and keeps the rest, typing the
suggested characters walks through it, and any other edit discards it.

#### An edit caused by the accept itself leaves the remaining ghost valid
`CotypingRehearsal.Change.unchanged`: The edit was the accept itself; the remaining ghost still applies.

#### wordLimit lets a limit-cut suggestion be topped up as in a live field
`CotypingRehearsal.present`: `wordLimit` is the length limit the suggestion was generated under.
With it, a suggestion the limit cut short can be topped up as it is
accepted, as in a live field.

#### Top-up prefix is nil while enough ghost remains or thought is finished
`CotypingRehearsal.topUpPrefix`: The text a top-up continues from, once the remaining ghost is running
short; nil while there is enough left or the thought is finished.

#### Model output is appended only if it still continues the same suggestion
`CotypingRehearsal.topUp`: Appends model output to the ghost when it still continues the same
suggestion. Returns whether the ghost grew.

#### Accept returns new editor text, or nil when nothing was accepted
`CotypingRehearsal.accept`: One accept keypress with the caret at the end of `text`. Returns the
text the editor should hold afterwards, or nil when nothing was accepted.

#### Must be called for every editor change, including accept-produced ones
`CotypingRehearsal.textChanged`: The editor text changed. Call for every change, including the one an
accept produces.

### `LokalBot/Cotyping/CotypingCoordinator+Acceptance.swift`

#### Mismatched overlay text means stale ghost; accepting would insert the wrong text
`CotypingCoordinator.acceptFromTap`: The visible ghost must match the session tail — a mismatch means the
overlay is showing stale text and accepting would insert the wrong thing.

#### Replacements share exact-field and exact-trigger validation; same PID is not enough
`CotypingCoordinator.acceptFromTap`: Replacements delete existing host text, so they share one exact-field
and exact-trigger validation path. A same-PID match is not sufficient.

#### One shared plan decides keypress amount and spacing, as in rehearsal
`CotypingCoordinator.acceptFromTap`: Shared with the Settings rehearsal: one plan decides how much a
keypress takes and how it is spaced.

#### Event tap stays constant-time: no pasteboard, no AX menu walk, one synthetic Unicode pair
`CotypingCoordinator.acceptFromTap`: The consuming event tap must remain constant-time and must never
touch the pasteboard or walk an app's AX menu tree. Composing
input sources fail open above; direct-input continuations use one
synthetic Unicode event pair regardless of text length or lines.

#### Re-anchor the ghost after the host commits the insert because of AX lag
`CotypingCoordinator.acceptFromTap`: Re-anchor the ghost after the host commits the insert (AX lag).

#### Inline ghost cleared because accepted-text end is unknown until app shows it
`CotypingCoordinator.acceptFromTap`: Where the accepted text ends is known only once the app
shows it. Drawn at the caret read before the accept, the
rest would cover that text; it comes back from the anchor
cache at the new caret instead.

#### Two delayed reads move ghost to the app's real caret and correct font measure
`CotypingCoordinator.refreshCaretSoon`: Reads the field shortly, and once more if the app has not shown the
text yet. The focus change a read publishes moves the ghost to the
app's own caret (`reanchorVisibleSuggestion`), which corrects what the
ghost's font measured, such as a page zoom it does not know about. A
caret found on screen is measured again once typing has moved it a
fair way along its line.

#### Escape clears suggestion, is swallowed by default, and pauses the field briefly
`CotypingCoordinator.dismissFromTap`: Escape while a suggestion is showing. The suggestion goes away and,
unless the user chose otherwise, the key stops here, so it does not
also close a dialog or leave a mode in the app, and the field stays
quiet for a few seconds. Called synchronously from the accept tap.

#### A composing input method keeps its own Escape
`CotypingCoordinator.dismissFromTap`: A composing input method needs its own Escape.

#### Escape hold expires on its own and never follows to another field
`CotypingCoordinator.isPausedByEscape`: Whether Escape put this field on hold. The hold ends on its own, and it
never follows the user to another field.

#### Session, overlay, ready state and accept tap are established together only here
`CotypingCoordinator.present`: Atomically presents a suggestion. The invariant *session exists ⟺
overlay visible ⟺ state == .ready ⟺ accept tap armed* is established
here (and torn down in `clearSuggestion`) — never by hand at call sites.
A suggestion with no place on screen that covers no text is dropped.

#### Session is kept to what is drawn; with nowhere to draw, suggestion is dropped
`CotypingCoordinator.showSuggestion`: Shows the rest of the live session at `field`'s caret, keeping the
session to what is drawn. With nowhere to draw it, the suggestion goes.

#### Session holds only visible text so accept never inserts unseen words
`CotypingCoordinator.keepSessionToShownText`: The session keeps only what the ghost shows, so an accept never
inserts words the user could not see. The rest may come back as a
top-up once there is room.

#### Shared published tail of present, also used by the advance paths
`CotypingCoordinator.markReady`: The published tail of `present` — also used by the advance paths, which
keep the existing overlay window and only re-arm interception + state.

#### Every key advances or clears suggestion, so a quiet minute means no typing
`CotypingCoordinator.noteSuggestionActivity`: Restarts the idle clock of the suggestion on screen. Every key either
advances the suggestion or clears it, so a minute without a call means
a minute without typing in the field.

#### Continuous clock keeps counting while the Mac sleeps
`CotypingCoordinator.expireIdleSuggestion`: The continuous clock keeps counting while the Mac sleeps.

### `LokalBot/Cotyping/CotypingCoordinator+Extension.swift`

#### Top-up start must be cheap and non-blocking; called inside the accept tap
`CotypingCoordinator.extendSuggestionIfNeeded`: Starts a top-up when the visible suggestion is running short. Cheap and
non-blocking: the accept tap calls it from inside its event callback.

#### Only a top-up that landed is followed up, so a refused one cannot loop
`CotypingCoordinator.extendSuggestionIfNeeded`: More words may have been accepted while the model ran. Only a
top-up that landed is followed up, so a refused one cannot loop.

#### Continuation uses same context the suggestion was made from
`CotypingCoordinator.suggestionExtension`: Asks the model to continue from the end of `session`'s suggestion, with
the same context the suggestion was made from. Nil when nothing usable
came back.

#### Session and ghost change together or not at all, only by words with room
`CotypingCoordinator.applySuggestionExtension`: Appends `addition` to the visible suggestion if it is still the one the
model continued. The session and the ghost change together or not at all,
and only by the words the ghost has room to show.

#### Popup or wrapped ghost is laid out at live caret after app shows accepted words
`CotypingCoordinator.applySuggestionExtension`: A popup or a wrapped ghost is laid out afresh, at the live caret,
and only once the app shows the words accepted so far.

### `LokalBot/Cotyping/CotypingCoordinator+Input.swift`

#### Accept tap owns Escape; the suggestion still goes if the tap misses it
`CotypingCoordinator.handleKey`: The accept tap takes this Escape and decides whether the app
sees it. Should the tap miss the key, the suggestion still goes.

#### The accept itself is owned by the accept tap
`CotypingCoordinator.handleKey`: The accept itself is owned by the accept tap.

#### Typing through an on-screen ghost has no wait to measure
`CotypingCoordinator.handleKey`: Typing through a ghost that is already on screen has no wait to
measure; scheduling the next suggestion starts a new one.

#### Ghost is cleared at once because the app draws letters where it starts
`CotypingCoordinator.handleKey`: The key leaves the suggestion behind. The app draws its letters
where the ghost starts, so the ghost goes now rather than when
the app publishes them, which in a browser can take a while.

#### Text read from screen is forgotten when focus leaves its field
`CotypingCoordinator.handleFocusChange`: Text read from the screen is forgotten as soon as focus leaves the
field it was read for.

#### State must leave ready without a session or new field is not read ahead
`CotypingCoordinator.handleFocusChange`: Without a session the state is no longer "ready"; left there, it
keeps the new field from being read ahead of its first key.

#### Disabled reason shown while idle; recording pause label persists until recording ends
`CotypingCoordinator.handleFocusChange`: Surface a disabled reason in the UI while idle (no live suggestion).
A recording's pause label stays until the recording ends.

#### Only hard not-a-text-field states are reflected, to avoid label flapping
`CotypingCoordinator.handleFocusChange`: Only reflect hard "not a text field" states passively; avoid
flapping the label on every transient focus change.

#### Ghost moves to app caret only once app shows all accepted text
`CotypingCoordinator.reanchorVisibleSuggestion`: Moves the visible ghost to the caret the app reports, once the app
shows everything accepted or typed through so far. Until then the
ghost stays where the keys moved it. Called for every focus change,
so the ghost also follows a field that scrolls or moves.

#### A ghost that would cover typed text always moves
`CotypingCoordinator.reanchor`: Lays out the rest of `current` at `liveField`'s caret unless it is
already there; a ghost that would cover typed text always moves.

#### Quick reads omit field font, so suggestion keeps its original font
`CotypingCoordinator.reanchor`: A quick read leaves out the field's font; the suggestion keeps the
one it was drawn in.

#### Inline ghost cleared because typed-text end is known only after app shows it
`CotypingCoordinator.advanceActiveSessionIfTypedCharactersMatch`: Where the typed letters end is known only once the app shows
them, and the caret read for this suggestion is behind them.
The rest comes back from the anchor cache at the app's caret.

#### Popup sits under the caret's line, clear of text
`CotypingCoordinator.advanceActiveSessionIfTypedCharactersMatch`: A popup sits under the caret's line, clear of the text.

### `LokalBot/Cotyping/CotypingCoordinator+Lifecycle.swift`

#### applySettings is idempotent; call on launch and on every settings change
`CotypingCoordinator.applySettings`: Start or stop to match the current settings + permissions. Idempotent —
call on launch and whenever the cotyping settings change.

#### Restart focus tracker to drop old-boundary snapshots and in-flight AX reads
`CotypingCoordinator.applySettings`: Drop any field snapshot captured under the previous boundary and
invalidate an AX read that may still be in flight.

#### Drop visible and cached text before deletion, correction or revocation
`CotypingCoordinator.invalidateMemoryContext`: Drop both visible and cached text before source deletion/correction or
permission revocation. Accepted facts are not copied into local learning.

#### Read focus shortly after click or app switch, once the app moved it
`CotypingCoordinator.refreshFocusSoon`: Reads focus shortly after a click or an app switch, once the app has
moved it.

#### Recording pause drops ghost now; per-generation gate blocks new suggestions
`CotypingCoordinator.meetingRecordingStateChanged`: Called by AppState when a meeting recording starts or stops. Pausing
drops any live ghost text immediately; the per-generation gate in
`generate(work:)` keeps new suggestions from appearing while active.

### `LokalBot/Cotyping/CotypingCoordinator+Measurement.swift`

#### Local measurements are counts and timings only, no text
`CotypingCoordinator+Measurement`: Local measurements of how autocomplete behaves while typing in other apps:
how long a suggestion takes to appear after the last keystroke, whether an
accepted suggestion arrived in the field, and whether it was taken straight
back. Counts and timings only; see `CotypingLiveMeasure`.

#### A deletion or undo within 5 s of an accept counts as correcting it
`CotypingCoordinator.correctionWindowMilliseconds`: A deletion or undo this soon after an accept counts as correcting it.

#### Waits over 10 s are a restored suggestion, not typing latency
`CotypingCoordinator.maxMeasuredVisibleMilliseconds`: Longer waits are a suggestion restored later, not typing latency.

#### Latency recorded once per keystroke; each shown continuation is counted
`CotypingCoordinator.noteSuggestionShown`: A continuation became visible. Counts it for the statistics, and
records the wait since the keystroke that asked for it, once per
keystroke.

#### First accept marks a suggestion used; unseen suggestions never count as used
`CotypingCoordinator.noteAcceptance`: The first accept from a suggestion makes it a used one. Without a
shown suggestion nothing is marked used, so the share used never
counts a suggestion it did not see.

#### Unpublished previous accept is checked together with the new one
`CotypingCoordinator.noteAcceptance`: The app has not published the previous accept yet; check both together.

#### expired forces the wait to be over regardless of the clock
`CotypingCoordinator.resolveInsertionCheck`: Compares the pending accept with what the host field now holds.
`expired` treats the wait as over whatever the clock says.

#### Expiry closes checks when an ignoring app publishes nothing and bounds kept text
`CotypingCoordinator.scheduleInsertionCheckExpiry`: An app that ignores an insertion publishes nothing, and typing may stop
there, so no key or focus change would ever close the check. This does,
which also bounds how long the compared text is kept.

#### One last read so late publishers are not counted as silent
`CotypingCoordinator.scheduleInsertionCheckExpiry`: One last read, so an app that published late is not counted as silent.

#### Taking text back or moving caret makes unread accepts unconfirmable; typing on does not
`CotypingCoordinator.noteKey`: A key that takes text back or moves the caret changes what is before
the caret, so an accept that is still unread can no longer be read
back. Typing on leaves it readable: the inserted text is still there.

#### First key after an accept shows whether accepted text was kept
`CotypingCoordinator.noteKeyAfterAcceptance`: The first key after an accept shows whether the accepted text was kept.

#### Typing speed counts own characters; other keys break the run
`CotypingCoordinator.noteTyping`: Counts characters you type yourself, and the short gaps between them
for your typing speed, where autocomplete could suggest. Any other key
breaks the run, so a deletion or an accept is not timed as typing.

#### Typing counts only where autocomplete could suggest; password fields never
`CotypingCoordinator.typingCounts`: Whether autocomplete could suggest in `focus`, so typing there is part
of the text it could have helped with. Password fields never count.

### `LokalBot/Cotyping/CotypingCoordinator+ModelWarmth.swift`

#### Warm idle in-process model: llama.cpp releases weights after 3 min; cold start 1.9 s vs 62 ms
`CotypingCoordinator+ModelWarmth`: Keeps the first suggestion after a pause about as quick as one while
typing. A loaded in-process model that sits unused goes cold: llama.cpp
stops holding its weights resident three minutes after the last decode,
and the system then pages or compresses them. On 2026-10-06 the first
suggestion after half an hour took 1.9 s against 62 ms while typing.

Any key or click the input monitor sees, and the screen waking or
unlocking, asks the engine to run one throwaway token if the model has not
run for a while (`LocalLlamaCotypingEngine.warmAfterIdle`). While the person
keeps using the Mac this also renews llama.cpp's keep-alive, so the weights
stay ready until they step away; a click or an unlock on their return
readies them before the first key.

#### Activity asks the engine at most every 5 s; engine decides idleness
`CotypingCoordinator.modelWarmRequestInterval`: How often activity may ask the engine at all. The engine then decides
whether the model has been idle long enough to need a token, so a key
while typing costs one clock read here.

### `LokalBot/Cotyping/CotypingCoordinator+Prediction.swift`

#### withSuggestionShown prewarms during a visible suggestion when the prompt changed
`CotypingCoordinator.scheduleFocusPrewarm`: `withSuggestionShown` also prewarms while a suggestion is on screen and
nothing is being generated, for a prompt that changed under it.

#### Prewarm reads the field like the first keystroke so first suggestion adds only typed text
`CotypingCoordinator.scheduleFocusPrewarm`: Read the field as the first keystroke will, which also caches its
font and the text above it, and have the model read that prompt
now, so the first suggestion only adds what was typed.

#### Window text change after typing pauses re-primes the prompt, even with ghost shown
`CotypingCoordinator.windowTextDidChange`: A background read of the focused window changed the text the prompt
starts with, which happens once typing pauses. While nothing is being
generated, including with a suggestion on screen, the model reads the
new prompt now, so the next keystroke does not wait for it.

#### Explicit emoji shortcode intent wins over autocorrect and the LLM
`CotypingCoordinator.generate`: Emoji: an explicit `:shortcode` intent wins over autocorrect and the LLM.

#### Explicit slash macro intent also wins over autocorrect and the LLM
`CotypingCoordinator.generate`: Macros: an explicit `/expr` (math, date, unit, currency, random) wins too.

#### Re-run memory lookup when a source changed or was withdrawn
`CotypingCoordinator.generate`: A source changed or was withdrawn since the lookup: look again.

#### Whole suggestion appears at once, matching Cotypist
`CotypingCoordinator.generate`: The whole suggestion appears at once, as in Cotypist.

#### Skip caret wait when caret is exact; a running find only re-measures
`CotypingCoordinator.completeGeneration`: A caret already placed needs no wait: a find still running only
measures it again, and the suggestion is ready now.

#### Cancellation is expected when newer input supersedes a request
`CotypingCoordinator.handleGenerationFailure`: Cancellation is expected when newer input supersedes this request.

#### Rank learned examples on finished words so half-typed words do not change the prompt
`CotypingCoordinator.buildRequest`: Ranked on finished words only: a half-typed word reordering the
examples would change the prompt, and the model would read it again.

#### One quick read before painting; show only if continued text still matches
`CotypingCoordinator.validatedLiveFieldForGeneratedResult`: One quick read of the field before painting: the suggestion is shown
only if the text it continues is still exactly what is there. The
field's font and the text above it come from the request's own read.

#### Valid-word signal lets normalizer accept whitespace-leading continuation after a fragment
`CotypingCoordinator.wordPrefixIsValidWord`: Whether the word fragment at the caret is a valid standalone word — the
normalizer's signal for accepting a whitespace-leading continuation
after a fragment ("the" may be complete; "follo" must be extended).

#### Corrections, emoji and calculations are shown whole or not at all
`CotypingCoordinator.showOverlay`: A correction, emoji or calculation is shown whole or not at all.

#### Suggestion keeps first-drawn font because quick re-reads omit it
`CotypingCoordinator.sessionStyle`: A quick re-read of the field leaves out its font. The suggestion keeps
the font it was first drawn in, so it does not change size mid-line.

#### Emphasis covers the next accept's characters; nil when one accept takes all
`CotypingCoordinator.acceptEmphasisLength`: Characters of `text` the next accept keypress takes, which the ghost
draws a little stronger. Nil when one accept takes the whole suggestion.

#### Use newest finished lookup since library read takes tens of ms; refresh in background
`CotypingCoordinator.latestSavedContext`: Saved facts for a live keystroke. Looking them up reads the library,
which takes tens of milliseconds, so the suggestion uses the newest
lookup that has finished for this field. Another starts in the
background when the finished words before the caret could name
something new, and the following keystroke picks it up.

#### Preview runs the real pipeline on synthetic text without Accessibility permissions
`CotypingCoordinator.previewSuggestion`: Runs the real pipeline (prompt + model + normalizer) on synthetic text for
the in-app preview playground. No Accessibility / Input Monitoring needed.

#### Visible-text grant uses a conversation stand-in; screen is never read
`CotypingCoordinator.preview`: The same pipeline, also reporting which optional sources shaped the
result. With the visible-text grant on, `conversation` stands in for the
text above a live field; the screen is never read.

### `LokalBot/Cotyping/CotypingCoordinator.swift`

#### Coordinator state is module-visible and protected by convention; port of Cotabby
File overview:
Declares the shared state and dependency graph for LokalBot's inline-completion orchestrator.
Behavior lives in `CotypingCoordinator+*.swift` files so each state-machine concern can be
reviewed independently.

Swift has no type-private access level spanning multiple files. Coordinator-owned state
therefore uses module visibility and is protected by convention: other types may observe it
but must not mutate it.
Orchestrates cotyping: focus polling → debounce → generation → ghost overlay
→ accept-on-Tab. Trimmed port of Cotabby's `SuggestionCoordinator`, adapted
to LokalBot's completion engines (`CotypingCompleting`: in-process or
HTTP). Owns the session and the work-id (`generation`) that drops
superseded results.

Started/stopped by `AppState` from the cotyping setting + permission state.

#### Set when last suggestion looked for saved facts, used or not
`CotypingCoordinator.memoryContextSearched`: The last suggestion looked for saved facts, whether or not it used any.

#### Stats store is injected so tests never write the installed app's counters
`CotypingCoordinator.stats`: Usage counters and typing measurements. Injected so tests never write
the installed app's saved counters.

#### Autocomplete stays quiet while a meeting records
`CotypingCoordinator.isMeetingRecordingActive`: Live flag from AppState — cotyping stays quiet while a meeting records.

#### Rehearsal checks contextEpoch, not generation, which every key moves
`CotypingCoordinator.contextEpoch`: Moves when context may have been taken back or autocomplete stopped.
A rehearsal checks this rather than `generation`, which every key moves,
including keys typed into the rehearsal itself.

#### Focus read after click or app switch prepares new field before first key
`CotypingCoordinator.focusRefreshTask`: A focus read right after a click or an app switch, so a newly focused
field is prepared before the first keystroke instead of at the next
(possibly backed-off) poll.

#### Accept read-back wait is shortened by tests
`CotypingCoordinator.insertionCheckExpiryMilliseconds`: How long an accept may wait to be read back. Tests shorten it.

#### Shown suggestion tracks surface, model and whether any was accepted, for statistics
`CotypingCoordinator.shownSuggestion`: The suggestion on screen, for the statistics: where it was shown, by
which model, and whether any of it has been accepted yet.

#### Gap between typed characters measures typing speed
`CotypingCoordinator.lastTypedKeyUptime`: When the last character was typed where autocomplete works, so the
gap to the next one measures typing speed.

#### Re-read after accept or typed letter so ghost follows app's own caret
`CotypingCoordinator.caretRefreshTask`: Reads the field again just after an accept or a typed-through letter,
so the ghost moves to the app's own caret as soon as the app shows them.

#### Expire an untouched suggestion so a late Tab reaches the app
`CotypingCoordinator.suggestionExpiryTask`: Takes down a suggestion left alone, so a Tab pressed long afterwards
reaches the app instead of the ghost.

#### Suggestion lifetime is 60 s untouched, as in Cotypist; tests shorten it
`CotypingCoordinator.idleSuggestionLifetimeMilliseconds`: How long a suggestion may sit untouched, as in Cotypist. Tests shorten it.

#### Record cache entries against in-flight request fingerprint, not later settings
`CotypingCoordinator.activeSuggestionRequestFingerprint`: Fingerprint captured from the exact request currently in flight. Cache
entries are recorded against this snapshot, not settings read after the
model returns, so a mid-generation settings change cannot bless stale
output for reuse under the new configuration.

#### Wait up to 150 ms for on-screen caret before showing beside field
`CotypingCoordinator.visualCaretWaitMilliseconds`: How long a finished suggestion waits for its caret to be found on
screen before it is shown beside the field instead.

### `LokalBot/Cotyping/CotypingDebouncePolicy.swift`

#### In-process uses short tiers; model server keeps conservative latency backoff
`CotypingDebouncePolicy`: Chooses the prediction debounce from the last generation's latency.
In-process inference can use Cotabby-style short tiers because cancellation
stops local work directly. Model-server requests retain the conservative
latency backoff: cancelling the client does not guarantee the server stops.

#### Model-server backoff is capped at 600 ms
`CotypingDebouncePolicy.maxBackoffMilliseconds`: Largest model-server backoff regardless of how slow the request is.

### `LokalBot/Cotyping/CotypingDecodeStopPolicy.swift`

#### One stop policy for both routes; HTTP streaming applies boundary rule client-side
`CotypingDecodeStopPolicy`: Stop policy for cotyping completions, shared by both routes.

Cotypist/Cotabby can stop inside the native decode loop once the accumulated
text reaches a natural suggestion boundary. LokalBot's in-process engine
asks this policy from its decode loop (`LocalLlamaCotypingEngine`). The
HTTP llama-server path cannot run that native hook, so its streaming client
applies the same visible boundary rule and returns early. This does not
improve first-token latency, but it prevents useful streamed suggestions
from being replaced by later rambling or control-token scaffolding.

### `LokalBot/Cotyping/CotypingEmoji.swift`

#### Emoji trigger rules and curated catalog ported from Cotabby; colon opens only at word boundary
`CotypingEmoji`: Inline `:shortcode:` emoji autocomplete. A trimmed port of Cotabby's emoji
subsystem: instead of a bundled gemoji JSON + a separate picker panel, this
uses a curated in-source catalog and reuses cotyping's ghost overlay (the top
match shows inline; the accept key replaces the typed `:query` with the glyph).

Detection mirrors Cotabby's trigger rules: a `:` only opens a query at a word
boundary (start of field or after whitespace), so `http://`, `12:30`, and
`foo::bar` never trigger. Both `:roc` (open, prefix match) and `:rocket:`
(closed, exact match) are supported.

#### Open queries need two characters to avoid noise; closed may be exact
`CotypingEmoji.match`: Open queries need ≥2 chars to avoid noise; closed `:q:` may be exact.

#### Token length is used to delete the query on accept, matched or not
`CotypingEmoji.trailingTokenLength`: Length of the trailing `:query[:]` token at the caret (regardless of
whether it matches an emoji) — used to delete it on accept.

#### Alias characters follow gemoji: plus, minus, underscore
`CotypingEmoji.isNameCharacter`: Alias characters gemoji allows (`+1`, `-1`, `e-mail`-style underscores).

#### Synonyms map intent words to a canonical shortcode, exact match only
`CotypingEmoji.bestMatch`: Synonyms (intent words) map to a canonical shortcode, exact only.

#### Prefix match follows popularity order of the catalog
`CotypingEmoji.bestMatch`: Prefix match in popularity order (catalog is ordered most-common first).

#### Catalog is curated, popularity-ordered, not exhaustive
`CotypingEmoji.catalog`: Curated catalog, ordered roughly by popularity so the first prefix match
is the most likely intent. Not exhaustive — covers the common long tail.

### `LokalBot/Cotyping/CotypingEngine.swift`

#### Request assembly is pure, separate from I/O so it is testable
`CotypingRequestBuilder`: Pure assembly of a `CotypingRequest` from a focused field. Separated from the
I/O engine so request construction is unit-testable without a model.

#### Blank fields get no suggestion but their prompt can be prefilled
`CotypingRequestBuilder.build`: A blank field gets no suggestion; its prompt can still be prefilled.

#### Test hook logs prompts so the autocomplete film can chart model choices
`CotypingRequestBuilder.build`: The autocomplete film replays these prompts to chart the model's choices.

#### Protocol seam lets coordinator and preview run against a fake in tests
`CotypingCompleting`: The I/O seam: turn a built request into normalized ghost text. Behind a
protocol so the coordinator and the in-app preview can run against a fake in
tests without a live server.

#### Selectors override debounce profile as routes move between local and server
`CotypingCompleting.debounceProfile`: Debounce behavior for the route currently serving completions.
Selectors override this as they move between local and model-server paths.

#### Only in-process engine has a model to prewarm; HTTP boots lazily
`CotypingCompleting.prewarm`: Loads + primes any in-process model so the first completion isn't cold.
Default is a no-op: only the in-process `LocalLlamaCotypingEngine` has a
model to prewarm; the HTTP engine boots its server lazily.

#### Focus-time prefill lets first keystroke reuse prompt KV
`CotypingCompleting.prewarm(for:)`: Best-effort focus-time prompt prefill for in-process engines. This lets
the first real keystroke reuse prompt KV when the user pauses after focus.

#### Warms an already loaded model after a pause; never loads one
`CotypingCompleting.warmAfterPause`: After a pause, readies an in-process model that is already loaded, so
the first suggestion is not slower than the rest. Never loads one.
Default is a no-op: only the in-process engine keeps a model in this
process.

#### Selectors await unload before route changes so two model copies never coexist
`CotypingCompleting.unload`: Frees resources owned by the engine. The in-process engine releases its
model/context; the HTTP engine stops its dedicated `llama-server`.
Selectors await this hook before changing routes so two copies of the
cotyping model cannot remain resident at once.

#### HTTP route serves built-in model on its own llama-server when in-process does not apply
`CotypingEngine`: The HTTP route: runs one raw completion over a `TextEngine` and through the
shared normalizer. It serves the built-in autocomplete model on its own
`LlamaServer.cotyping` instance when the in-process engine does not apply
(`CotypingEngineSelector`), and a server the user chose
(`CotypingServerRoute`).

#### Production engine comes from ThinkExecution and boots built-in llama-server lazily
`CotypingEngine.makeEngine`: Resolves the active `TextEngine`. In production this is
`ThinkExecution.makeTextEngine(settings)`, which also boots the
built-in llama-server with the selected model on first use.

#### HTTP token healing cuts prompt to word boundary and requires cut text re-typed
`CotypingEngine.healsCaretBoundary`: Applies the in-process engine's token healing over plain HTTP: the prompt
is sent cut back to the word boundary, and only output that re-types the
cut text counts. A server cannot be constrained to that prefix, so other
output is suppressed. Off for llama-server, whose prompt stays byte-for-byte.

#### Chat replies lack a caret token, so the missing word space is restored
`CotypingEngine.restoresWordSpace`: For chat replies, which have no token at the caret: puts back the space
a chat model leaves out before a new word (`restoringWordSpace`).

#### Built-in server is process-wide, so owner needs an awaitable release
`CotypingEngine.unload`: The resolved `TextEngine` is intentionally short-lived, but its
dedicated built-in server is process-wide. Give the lifecycle owner an
explicit, awaitable way to release that server.

#### Healing allows extra tokens: none after a space, four after a cut fragment
`CotypingEngine.completionRequest`: A space joins the first word's token; a cut word fragment needs a few more.

#### Single-line mode stops server at first newline; normalizer still collapses defensively
`CotypingEngine.completionRequest`: Single-line mode stops the server at the first newline; the
normalizer still collapses defensively.

#### Restore missing word space only after whole words, not fragments or restated words
`CotypingEngine.restoringWordSpace`: Chat models often leave out the space before a new word: "at a" +
"higher level" would show as "ahigher level", or not at all once the seam
guard sees the misspelling. After a whole word, a reply that starts with a
letter or digit starts a new word, so it gets the space back. Inside a
word, after a fragment the spell checker does not know ("follo"), when the
reply restates the word at the caret (the normalizer drops it), and in
scripts written without spaces, the reply is left as it is.

#### Scripts written without spaces (Han, kana, Thai, etc.) are excluded
`CotypingEngine.isSpacedWordCharacter`: A letter or digit of a script that puts spaces between words, so not Han,
kana, Hangul, Thai, Lao, Myanmar or Khmer.

### `LokalBot/Cotyping/CotypingFieldContextCache.swift`

#### Stale values returned while background refresh runs; keystrokes never wait
`CotypingFieldContextCache`: Per-field cache for Accessibility reads that rarely change while one field
keeps focus: its font, its document scope, and the text above it. A value
past its age is still returned while a fresh read runs in the background,
so a keystroke never waits for one. Only a field seen for the first time is
read on the spot.

#### Failed reads are not remembered and keep the cached value
`CotypingFieldContextCache.valueIfReadable`: Like `value(forKey:read:)`, for a value a read may fail to find, such
as the font of an empty field. A failed read is not remembered, and a
failed background read keeps the value already cached.

#### Reads already running cannot put their value back after removeAll
`CotypingFieldContextCache.removeAll`: Forgets every value. Reads already running cannot put theirs back.

### `LokalBot/Cotyping/CotypingFieldIdentity.swift`

#### All field-identity schemes live in one place so they cannot drift
`CotypingFieldIdentity`: Derives the string keys that identify "the same field" across focus
snapshots. All field-identity derivations live here so the schemes cannot
drift apart between the anchor cache, prewarm dedupe, and reconciliation.

#### Anchor prefers AX identity, then frame, then metadata; content excluded
`CotypingFieldIdentity.suggestionAnchor`: Identity for anchoring a suggestion to one concrete focused field across
host publishes. The AX identity is the strongest signal; apps that do not
expose one fall back to the field frame, then surface metadata. Content is
deliberately excluded so typing through a suggestion keeps the anchor.

#### Background key uses app, role, title, frame; not app alone nor element
`CotypingFieldIdentity.background`: Identity for reusing the background sampled behind a field's ghost:
the app, kind of field, window title and frame. Not the app alone: a
browser shows light and dark pages, and a reading from a light page drew
black ghosts on dark ones. Not the element: Chrome hands out a new one
on every read, which would sample again for every suggestion.

### `LokalBot/Cotyping/CotypingFieldStyle.swift`

#### Style uses plain value types to stay Equatable and Sendable; nil falls back to defaults
`CotypingFieldStyle`: The focused field's own font/color, resolved once per field session from AX
and carried as plain value types (no `NSFont`/`NSColor`) so the snapshot
stays `Equatable`/`Sendable` and cheap across async boundaries. Ported from
Cotabby's `ResolvedFieldStyle`. Empty / nil falls back to the overlay defaults.

#### Host point size is clamped so the ghost matches field scale
`CotypingFieldStyle.fontPointSize`: Host-reported point size; used (clamped) so the ghost matches the field's scale.

#### Background colour lets the ghost stay legible on dark fields without foreground colour
`CotypingFieldStyle.backgroundColorHex`: Background (fill) color of the field as a 6-digit hex string, when the
host exposes it. Lets the ghost pick a legible hint on dark fields even
when no foreground color is reported.

#### Chromium reports size without font name, which still counts as a style
`CotypingFieldStyle.isEmpty`: Chromium reports a size with no font name, which is still a style.

#### Ghost font and colour derive from host field style, with explicit fallbacks
`CotypingGhostStyle`: Derives the ghost text's font/color from the host field's resolved style, so
the suggestion reads as a continuation of what the user is typing instead of
always using the system font + a fixed gray. Ported in spirit from Cotabby's
overlay styling. Pure given AppKit; all fallbacks are explicit and testable.

#### Ghost opacity 0.4 of host colour makes it read as suggestion
`CotypingGhostStyle.ghostOpacity`: Ghost opacity relative to the host text color — reads as a suggestion, not typed text.

#### Next-accept word is drawn stronger at 0.62 opacity
`CotypingGhostStyle.emphasisOpacity`: The word the next accept takes is drawn a little stronger than the rest.

#### Luminance uses Rec. 601 weights, ignores alpha, buckets light vs dark
`CotypingGhostStyle.relativeLuminance`: Perceived luminance (0…1) of a color in sRGB, for bucketing a field as
light or dark. Rec. 601 weights; alpha is ignored.

#### Contrast below 2.0 means a dynamic colour flattened wrongly; synthesize a hint
`CotypingGhostStyle.unreliableContrast`: Below this fg/bg contrast the host text color is almost always a dynamic
color flattened against the wrong appearance, so we synthesize a hint.

#### With sampled background, host colour needs contrast of at least 3.0
`CotypingGhostStyle.minLegibleContrast`: With a real (sampled) background luminance we hold the host color to a
genuinely-legible contrast (WCAG ~AA, large text) before trusting it.

#### Dim hint is a concrete colour, never dynamic, so it stays legible
`CotypingGhostStyle.dimHint`: A concrete dim hint — light on a dark field, dark on a light one — never a
dynamic catalog color, so it stays legible regardless of the overlay
panel's resolved appearance.

#### Measured luminance is authoritative; host colour kept only if legible
`CotypingGhostStyle.resolvedGhostColor`: The color actually painted for the ghost, as a concrete sRGB color
(independent of the overlay panel's resolved appearance). `measuredLuminance`
(real pixels sampled behind the ghost) is authoritative when present; the
host color is kept only when legible against the background, otherwise a
contrasting hint is synthesized.

#### Real pixels beat AX or appearance guesses for ghost colour
`CotypingGhostStyle.resolvedGhostColor`: Real pixels behind the ghost beat any AX/appearance guess: keep the
host color only if it's legible against them, else synthesize.

### `LokalBot/Cotyping/CotypingFocusCapabilityFlickerGate.swift`

#### Suppress one supported-blocked-supported poll flicker from caret redraw selections
`CotypingFocusCapabilityFlickerGate`: Suppresses a single `supported -> blocked -> supported` focus poll on the
same editable element. Some host apps briefly publish a non-empty selection
while redrawing the caret; without this, the ghost overlay tears down and
rebuilds even though focus did not really leave the field.

#### Never smooth secure-field blocks; only selected text is smoothed
`CotypingFocusCapabilityFlickerGate.isSmoothableBlockedReason`: Never smooth secure-field blocks: privacy beats visual stability. Today
the only editable blocked state that is safe to smooth is selected text.

### `LokalBot/Cotyping/CotypingFocusPollBackoff.swift`

#### Focus poll stays fast after activity and stretches when idle
`CotypingFocusPollBackoff`: Cotabby-style idle backoff for the focus poll timer.

Recent activity keeps the Accessibility poll at full cadence so suggestions
react quickly after typing. Sustained no-change captures stretch the timer,
reducing idle main-thread wakeups and AX reads without adding latency while
the user is actively editing.

### `LokalBot/Cotyping/CotypingFocusTracker.swift`

#### Timer polling instead of AXObserver, which is inconsistent across hosts
`CotypingFocusTracker`: Polls the Accessibility-focused field on a timer and publishes a value-type
snapshot. Trimmed port of Cotabby's `FocusTracker`/`FocusTrackingModel`: no
AXObserver (inconsistent across hosts), just a main-runloop timer plus an
out-of-band `refreshNow()` the coordinator calls after a keystroke settles.
The timer uses Cotabby's idle backoff: fast after activity, slower after
repeated no-change captures.

#### Latest-wins polling prevents unbounded timer tasks behind slow AX executor
`CotypingFocusTracker.requestTimerCapture`: Latest-wins timer polling. A slow target app can never build an unbounded
stack of timer tasks while the serialized AX executor is still working.

#### Validation fails closed on timeout; never trust cached field for display
`CotypingFocusTracker.refreshForValidation`: A validation capture fails closed on a whole-snapshot timeout. Callers
that are about to display generated text must not validate against a
cached field after the live target becomes unresponsive.

### `LokalBot/Cotyping/CotypingGhostSizing.swift`

#### Ghost uses field's own font and size when AX reports them
`CotypingGhostFontSizing`: Picks the font a suggestion is drawn in: the field's own font at its own
size when Accessibility reports one, so the ghost reads as the next
characters of the line, and otherwise the system font sized from the caret.

#### Size guessed from an estimated caret stays at most 16 pt
`CotypingGhostFontSizing.maximumEstimatedPointSize`: An estimated caret comes from the field frame and says little about the
text, so a size guessed from it stays modest.

#### Glyph box is about 1.2 times point size; web carets match it
`CotypingGhostFontSizing.pointSizePerCaretHeight`: The system font's glyph box is about 1.2 times its point size, and web
engines report a caret about as tall as that box.

#### Zoomed pages report unzoomed size; only far-off caret heights are read as zoom
`CotypingGhostFontSizing.pointSize`: Zoomed pages and documents report the unzoomed size. Only a caret far
outside the font's own glyph box, beyond what line spacing explains,
is read as zoom.

### `LokalBot/Cotyping/CotypingGhostTextLayout.swift`

#### Popup/mirror text is pre-wrapped; inline uses a separate layout
`CotypingGhostTextLayout`: Pre-wraps popup/mirror ghost text so multi-line suggestions do not collapse
into a single truncated row. Inline uses `CotypingInlineGhostLayout`; popup
has its own chrome and independently bounded rows.

### `LokalBot/Cotyping/CotypingGhostView.swift`

#### Plain AppKit drawing keeps baseline exact and avoids SwiftUI layout per keystroke
`CotypingGhostTextView`: Draws a suggestion's lines at exact baselines. Plain AppKit drawing keeps
the ghost on the field's own baseline and avoids a SwiftUI layout pass on
every keystroke. The word the next accept takes is drawn a little stronger
than the rest, so it is clear what Tab will insert.

#### Origin is baseline leading end; right end for right-to-left text
`CotypingGhostTextView.Line.origin`: The baseline's leading end in view coordinates (its right end for
right-to-left text).

### `LokalBot/Cotyping/CotypingInlineGhostLayout.swift`

#### Inline lines start at caret, wrap at field text edge, only onto empty in-field lines
`CotypingInlineGhostLayout`: Where each line of an inline suggestion is drawn. The first line continues
the caret's line on the field's own baseline, starting exactly at the caret,
so the suggestion reads as the next characters of the text. What does not
fit before the field's trailing edge wraps onto the following lines at the
field's text edge, where the host will put it once accepted, but only onto
lines that hold no text and lie inside the field. Coordinates are global
Cocoa points (bottom-left origin).

#### False means leftover text had nowhere to go without covering text
`CotypingInlineGhostLayout.isComplete`: Every character of the text has a place. When false, the lines hold
only its start, or nothing: what is left over had nowhere to go that
covers no text.

#### 8 pt kept clear inside field edges where fields pad text
`CotypingInlineGhostLayout.fieldInset`: Kept clear inside the field's edges, where most fields pad their text.

#### Parameter meanings: preceding line, free lines below, known wrap edge
`CotypingInlineGhostLayout.make`

- Parameters:
  - precedingLine: the field's text from the start of the caret's
paragraph to the caret. When it fits on one line it shows where the
field's text starts, which wrapped lines then line up with.
  - linesBelowAreFree: no text follows the caret, so the lines under
it are empty. Otherwise nothing wraps onto them.
  - knownWrapEdge: where wrapped lines start, when an earlier layout
for the same paragraph already found it.

#### Wrapped glyphs stay inside field; below it is other interface
`CotypingInlineGhostLayout.make`: A wrapped line's glyphs stay inside the field: below it is other
interface, such as a toolbar under a chat box that grows.

#### Text continuing the caret word moves with that word when it wraps
`CotypingInlineGhostLayout.make`: Text that goes on with the word at the caret moves with that word
when it wraps.

#### If word rest does not fit, app wraps whole word and position is unknowable
`CotypingInlineGhostLayout.make`: The rest of the word at the caret does not fit after it, so
the app will move the whole word to the next line, and no
place on screen shows where this text will go.

#### Line break or wrap space is not drawn
`CotypingInlineGhostLayout.make`: A line break or the space the host wraps at is not drawn.

#### Longest word-ended prefix drawable; nil if nothing or whole text cannot be drawn
`CotypingInlineGhostLayout.longestDrawable`: The longest start of `text` that can be drawn whole, ending after a
word, with its layout. `layout` lays out a candidate at the caret.
Nil when nothing can be drawn, or when `allowsPartial` is off and the
whole of `text` cannot.

#### Caret after typing is laid out like app wraps; nil when only known once shown
`CotypingInlineGhostLayout.caretRect`: Where the caret is once `typed` is in the field: at the end of
`typed` laid out from the caret, which is where the app puts it, since
the app wraps it by the same rule. Nil when that is only known once
the app shows it: text with a line break, or the rest of a word that
does not fit on the caret's line, which the app moves to the next line
together with the start of the word.

The arguments are those the ghost on screen was laid out with.

#### Trailing spaces are not drawn at line end but the app caret follows them
`CotypingInlineGhostLayout.caretRect`: Spaces are never drawn at the end of a line, but the app puts the
caret after every one typed.

#### AppKit caret is one line tall with fixed baseline; web caret is centered
`CotypingInlineGhostLayout.firstBaseline`: The baseline of the caret's line. AppKit text reports a caret exactly
one default line tall, with the baseline a fixed distance below its top;
web engines report about the glyph box, which is centered instead.

#### Line pitch is caret's own height when spanning a line, else font default
`CotypingInlineGhostLayout.linePitch`: Distance between wrapped lines: the caret's own line when it spans one,
else the font's default line.

#### Text stays inside field only if frame can hold a line, and always on screen
`CotypingInlineGhostLayout.textSpan`: Horizontal room for text: inside the field when it reports a frame wide
enough to hold a line, and always on screen.

#### One-line paragraph width back from caret finds the field's text edge
`CotypingInlineGhostLayout.wrapEdge`: Where wrapped lines start. A paragraph that fits on one line ends at
the caret, so its width back from the caret finds the field's text edge.

#### Whole words fit up to a break; oversized word splits by character when forced
`CotypingInlineGhostLayout.fittingPrefix`: The longest run of whole words from the start of `text` that fits in
`width`, stopping at a line break. A word wider than a whole line is
split between characters when `mustTakeSomething` is set.

### `LokalBot/Cotyping/CotypingInputMonitor.swift`

#### Plain Tab is consumed by the accept tap but reported
`CotypingKeyKind.acceptance`: plain Tab — consumed by the accept tap, reported for awareness

#### Printable characters, Backspace and Forward Delete count as text mutation
`CotypingKeyKind.textMutation`: printable character, Backspace, or Forward Delete

#### Command-Z is reported so an immediately undone accept is counted
`CotypingInputEvent.isUndo`: Command-Z. Reported so an accept that is undone at once can be counted.

#### Plain Escape may be taken by the accept tap while a suggestion shows
`CotypingInputEvent.isEscape`: Plain Escape, which the accept tap may take while a suggestion shows.

#### Listen-only observer tap always on; consuming accept tap only while suggestion visible
`CotypingInputMonitor`: Global keyboard watcher for cotyping. Ported from Cotabby's `InputMonitor`:

 • an always-on **observer** tap (`.listenOnly`, head-insert) that classifies
   keystrokes so the coordinator can schedule/dismiss — it can never drop
   events, so it cannot stall other apps; and
 • an **accept** tap (`.defaultTap`, tail-append) installed only while a
   suggestion is visible, which returns `nil` to swallow the accept key (Tab)
   so it lands in the suggestion instead of moving focus.

Requires the Input Monitoring grant. Cotyping's own synthetic inserts are
tagged (`CotypingSyntheticMarker`) and skipped.

#### onKey fires for every observed keyDown but not accept-key consumption
`CotypingInputMonitor.onKey`: Fired for every observed keyDown (not the accept key consumption itself).

#### Every left click may move focus or caret; event itself is not read
`CotypingInputMonitor.onPointerDown`: Fired on every left mouse button press: a click may move focus or the
caret. The event itself is not read.

#### Accept callback returns true if it acted and swallowed the key
`CotypingInputMonitor.onAcceptKey`: Invoked by the accept tap with the scope of the key that fired (next
chunk vs whole). Returns `true` if it acted (key swallowed); else passthrough.

#### Accept tap takes plain Escape while a suggestion is visible
`CotypingInputMonitor.onDismissKey`: Invoked by the accept tap for plain Escape while a suggestion is
visible. Returns `true` when the key was taken (swallowed).

#### Accept gate is consulted at event time
`CotypingInputMonitor.acceptGate`: Consulted at event time: should the accept tap even consider this key?

#### Configured accept keys are read live at event time
`CotypingInputMonitor.acceptKeyCodeProvider`: The configured accept keys, read live at event time.

#### Keep accept tap alive briefly so synthetic key events drain into host
`CotypingInputMonitor.acceptTapTeardownDelaySeconds`: Keep the accepting tap alive briefly after a final accept. The inserter
posts synthetic key events from inside the accept tap callback; invalidating
the tap immediately can pull it from the event chain before those events
drain into the host app.

#### Start fails when Input Monitoring is not granted
`CotypingInputMonitor.start`: Installs the listen-only observer tap. Returns false if the OS refuses
(Input Monitoring not granted).

#### Consuming tap installed only while suggestion visible to minimize keystroke path exposure
`CotypingInputMonitor.setAcceptActive`: Installs/removes the consuming accept tap. The coordinator turns it on
only while a suggestion is visible, so cotyping sits in the synchronous
keystroke path for the briefest possible window.

#### Returning true swallows the key
`CotypingInputMonitor.handleAccept`: Returns `true` to swallow the key.

#### Undo is matched by produced character so it holds on any layout
`CotypingInputMonitor.classify`: Matched by the character it produces, so it holds on any layout.

#### Plain keypress only; primary accept key wins when both share a code
`CotypingInputMonitor.acceptScope`: The accept scope for a plain (unmodified) keypress, or nil if it isn't an
accept key. The primary key wins if both map to the same code.

### `LokalBot/Cotyping/CotypingInserter.swift`

#### Tag own synthetic keystrokes so input taps never re-observe them
`CotypingSyntheticMarker`: Tags Cotyping's own synthetic keystrokes so the input taps ignore them and
never re-observe an insert as user typing. Ported from Cotabby's
`InputSuppressionController` (identity field only).

#### Arbitrary ASCII 'Lokal' sentinel on event source user data
`CotypingSyntheticMarker.userData`: "Lokal" in ASCII — an arbitrary sentinel on the event's source user data.

#### Insert via synthesized Unicode keystrokes because AX value-set is dropped by Chromium
`CotypingInserter`: Inserts accepted ghost text into the focused host app by synthesizing Unicode
keystrokes (Cotabby's approach — AX value-set is silently dropped by Chromium
and others). Each event is marked synthetic so the input monitor skips it.

#### Overlapping pastes coalesce onto one saved clipboard, never re-snapshotting own text
`CotypingInserter.pendingPasteboardRestore`: Pending restore of the user's clipboard after a paste insert, so overlapping
pastes coalesce onto the single saved clipboard rather than re-snapshotting
our own completion back into it.

#### Handoff kept alive while promised text may still be read
`CotypingInserter.activeHandoff`: Kept alive while its promised text may still be read.

#### Pastes run serially so a second does not snapshot dictated text as clipboard
`CotypingInserter.pasteQueue`: Pastes run one at a time. A second paste waits for the first; otherwise
it would snapshot the first one's dictated text as the user's clipboard.

#### Backspace n graphemes then type text in one suppressed burst
`CotypingInserter.replace`: Deletes `deletingCharacters` graphemes (one Backspace each) then types
`text`, in one suppressed synthetic burst. Used to swap a typo for its
correction. Backspace is virtual key 51.

#### Forward Delete for mid-word accepts where model's first characters already follow caret
`CotypingInserter.replaceForward`: Deletes `deletingCharacters` graphemes to the right of the caret (Forward
Delete, virtual key 117) and then types `text`. Used for mid-word accepts
where the model's first characters are already present after the caret.

#### Many apps accept only first 20 UTF-16 units per synthetic key event
`CotypingInserter.typeInChunks`: Types `text` in short Unicode keystrokes. Many apps take only the first
20 UTF-16 units of a single synthetic key event, so the whole string in
one event could silently lose the rest. Dictation's fallback when paste
cannot be set up.

#### Split at character boundaries; oversized single character stays whole
`CotypingInserter.typingChunks`: Splits `text` at character boundaries into runs of at most
`maximumUTF16` code units. A single longer character (a long emoji
sequence) stays whole in its own run.

#### Unconfirmed paste leaves text on clipboard so it is not lost
`CotypingInserter.PasteOutcome.unconfirmed`: The paste command was sent but no app read the text in time. The
text is left on the clipboard so it is not lost.

#### Failed paste setup restores the clipboard
`CotypingInserter.PasteOutcome.failed`: The pasteboard or paste command could not be set up; the clipboard
has been restored.

#### Skipped when caller cancelled or destination became invalid while waiting
`CotypingInserter.PasteOutcome.skipped`: Nothing was pasted: the caller was cancelled, or after waiting for
an earlier paste its destination was no longer valid.

#### Time an app has to read pasted text before text is left on clipboard
`CotypingInserter.pasteReadTimeout`: How long an app has to read the pasted text before LokalBot stops
waiting and leaves the text on the clipboard.

#### Lazy pasteboard text signals the read; fixed delay restored clipboard too early
`CotypingInserter.insertViaPaste`: Inserts `text` by placing it on the pasteboard and sending Paste, then
restoring the user's clipboard once the focused app has read it. The
text is provided lazily so LokalBot learns when the read happens; a
fixed delay used to restore the old clipboard before a busy app read it,
and that app pasted the previous clipboard instead. A trimmed port of
Cotabby's `insertViaPaste`, used by dictation commits.

`revalidateAfterWaiting` runs only when this paste had to wait for an
earlier one; focus may have moved meanwhile, so the caller re-checks
its destination. Cancelling the caller cancels a paste that has not
started.

#### Reads before paste command (clipboard managers) do not confirm the paste
`CotypingInserter.pasteAndConfirm`: Reads before the paste command (clipboard managers that ignore the
transient marker) do not confirm anything.

#### Cmd via flags without modifier event; marked synthetic for the accept tap
`CotypingInserter.postCommandV`: Cmd via flags (no separate modifier key event). Marked synthetic so the
consuming input tap ignores it.

#### Press paste menu item on background queue because pasteboard read needs main thread
`CotypingInserter.pressPasteMenuItem`: Finds the menu item on the main actor but presses it on a background
queue: the app answers the press by reading the pasteboard, and that
read is served from LokalBot's main thread.

#### Restore delay long enough for host Cmd-V, short for user's clipboard
`CotypingInserter.pasteboardRestoreDelay`: How long the completion stays on the pasteboard before the user's clipboard
is restored — long enough for the host to service Cmd-V, short enough that
the user's clipboard is theirs again almost immediately.

#### Snapshot every representation of every item for exact clipboard restore
`CotypingInserter.snapshotPasteboard`: Captures every representation of every pasteboard item so the user's
clipboard can be restored exactly, not just its plain-text form.

#### Restore marked auto-generated; concealed items are not restored
`CotypingInserter.restorePasteboard`: Puts the user's clipboard back, marked as generated so clipboard
managers do not record it as a second copy. A concealed item (a password
manager's copy) is not put back: its owner clears it on a timer only
while the pasteboard is unchanged, so a restored copy would linger.

#### Promised text so first read after paste confirms it; nspasteboard.org markers
`DictationPasteboardHandoff`: Dictated text on its way to the focused app. The string is promised rather
than written, so the first read after the paste command tells LokalBot the
paste happened. Marked with the nspasteboard.org conventions so clipboard
managers skip it.

#### AppKit calls data providers on the main thread
`DictationPasteboardHandoff.pasteboard(_:item:provideDataForType:)`: AppKit calls providers on the main thread.

#### Waiting operations dropped when cancelled or no longer wanted
`SerialTaskQueue`: Runs main-actor operations one after another. An operation that had to
wait is dropped when its caller was cancelled meanwhile or `stillWanted`
says no, so queued work never acts on a decision that went stale.

### `LokalBot/Cotyping/CotypingLearningStore.swift`

#### Learning confined to identified document; no recipient boundary otherwise
`CotypingLearningScope`: Learning is confined to an identified document. Generic windows, messaging
surfaces, and unknown websites cannot establish a recipient boundary.

#### Batch accepted chunks so learning stores one example with one write
`CotypingAcceptedSuggestionBatch`: Accumulates one visible suggestion's accepted chunks until the coordinator
closes that suggestion. Stats can still count each accept gesture, while
encrypted learning stores one coherent example and performs one write.

#### Discard private text but keep accept count for stats
`CotypingAcceptedSuggestionBatch.discardLearningRecord`: Forgets the private text accumulated for the current suggestion while
preserving its accept count so stats can still close on the normal
suggestion boundary.

#### complete returns one persistence unit and is a no-op when repeated
`CotypingAcceptedSuggestionBatch.complete`: Returns one completed persistence unit and resets the accumulator.
Calling it repeatedly without another accepted chunk is a no-op.

#### Persistence off main actor; tests inject recorder to avoid Keychain
`CotypingLearningPersisting`: Async persistence seam. The production actor keeps JSON encoding,
encryption, and atomic file replacement off the main actor; tests inject a
recorder without touching the user's Keychain.

#### Learning writes are best-effort, never block typing or surface private content
`EncryptedCotypingLearningPersistence.persist`: Learning is opportunistic. Match the previous best-effort write
behavior without blocking typing or surfacing private content.

#### Clear memory, delete after queued writes, pause learning during deletion
`CotypingLearningStore.forgetAll`: Clear memory immediately, then delete after every older queued write.
New learning is paused while deletion is in flight, so forgotten text
cannot be restored by an asynchronous write completing later.

#### Flush at termination; ordinary typing never awaits IO
`CotypingLearningStore.flushPersistence`: Forces any dirty in-memory snapshot into the background queue, then
waits for it. Used at app termination; ordinary typing never awaits IO.

#### Internal for deterministic tests of batching boundary
`CotypingLearningStore.waitForPendingPersistence`: Waits only for already-enqueued work. Kept internal for deterministic
tests of the completed-suggestion batching boundary.

### `LokalBot/Cotyping/CotypingLiveMeasure.swift`

#### Measurements keep counts and timings only, no text or app names
`CotypingLiveMeasure`: How autocomplete behaved while typing in one kind of app. Counts and
timings only: no text, app name or window title is kept.

#### Keystroke-to-visible latency includes publish wait, pause, lookup and validation
`CotypingLiveMeasure.visibleLatenciesMs`: Rolling window of the time from the last keystroke to a visible
suggestion, newest last. Unlike generation latency this includes the
wait for the app to publish the keystroke, the pause before
suggesting, context lookup and validation.

#### Confirmed means field held the inserted text after accept
`CotypingLiveMeasure.insertionsConfirmed`: Accepts after which the field held the inserted text.

#### Mismatched means field held something else after accept
`CotypingLiveMeasure.insertionsMismatched`: Accepts after which the field held something else.

#### Unconfirmed means app never published result in time
`CotypingLiveMeasure.insertionsUnconfirmed`: Accepts whose result the app never published in time to check.

#### Corrected means deletion or undo immediately followed accept
`CotypingLiveMeasure.acceptsCorrected`: Accepts followed at once by a deletion or an undo.

#### Unconfirmed insertions say nothing, so excluded from checked count
`CotypingLiveMeasure.insertionsChecked`: Insertions with a known outcome; unconfirmed ones say nothing either way.

#### Nearest-rank percentile matching CotypingStats
`CotypingLiveMeasure.percentile`: Nearest-rank percentile, matching `CotypingStats`.

#### Accept tap only posts keys; compare published field text with what was sent
`CotypingInsertionCheck`: Whether an accepted suggestion really arrived in the host field. The accept
tap only posts the keystrokes; this compares what the app publishes
afterwards with what was sent.

#### Pending: app has not yet published the change
`CotypingInsertionCheck.Outcome.pending`: The app has not published the change yet.

#### Confirmed: text before caret followed by insertion
`CotypingInsertionCheck.Outcome.confirmed`: The field holds the text before the caret followed by the insertion.

#### Mismatched: field changed but not to inserted text
`CotypingInsertionCheck.Outcome.mismatched`: The field changed, but not to the inserted text.

#### Unconfirmed: no change published or focus left first
`CotypingInsertionCheck.Outcome.unconfirmed`: The field never published a change, or focus left before it did.

#### Tail is end of text before caret when first accept was sent
`CotypingInsertionCheck.tail`: The end of the text before the caret when the first accept was sent.

#### A second accept before publish is checked together with the first
`CotypingInsertionCheck.count`: Accepts this check stands for. A second accept sent before the app
published the first is checked together with it.

#### live is focused field now, nil when nothing editable has focus
`CotypingInsertionCheck.outcome`: `live` is the focused field now, or nil when nothing editable has focus.

#### Typing may already have continued past the insertion
`CotypingInsertionCheck.outcome`: Typing may already have continued past the insertion.

#### Partial insertion never counts as success before timeout; truncation is the failure to find
`CotypingInsertionCheck.outcome`: Until the timeout, anything less may only mean the app is still
publishing. Part of the insertion is never counted as success: a
field that drops the end of a long insertion is the failure to find.

#### Unconfirmed when preceding text is no longer before the caret
`CotypingInsertionCheck.outcome`: The text that preceded the caret is no longer before it, so
nothing can be said about what followed.

#### Nothing after tail means no change published; anything else is a mismatch
`CotypingInsertionCheck.outcome`: Nothing after it means the app published no change; anything else
means the insertion did not arrive as sent.

#### Browsers publish trailing space as non-breaking space; not a visible difference
`CotypingInsertionCheck.normalized`: Browsers publish a trailing space as a non-breaking space. That is not
a visible difference, so it is not counted as one.

#### Report is plain-text comparison table with counts and timings only
`CotypingStats.report`: A plain-text table for comparing runs, for example the same typing
with two models. Holds counts and timings only.

### `LokalBot/Cotyping/CotypingMacro.swift`

#### Macro opens only at word boundary and shows only when query evaluates
`CotypingMacro`: Inline `/macro` autocomplete. A faithful port of Cotabby's macro subsystem
(`MacroEngine` + the arithmetic / date / random / unit / currency families),
folded into one self-contained file and driven from the focused field's AX
text instead of Cotabby's stateful capture.

Trigger: a `/` only opens a query at a word boundary (start of field or after
whitespace), so `http://`, `and/or`, and file paths typed mid-sentence never
fire. Crucially the macro is **evaluate-or-nothing**: the ghost only shows
when the typed `/query` actually computes to a result, so a stale `/` run or
arbitrary text never surfaces junk. Examples:
`/5+5` → `= 10`, `/10km->mi` → `6.214 mi`, `/today` → `Jun 23, 2026`,
`/100usd to eur` → `€92.00`, `/d20` → a roll, `/uuid` → a UUID.

#### Preview and insertion differ for arithmetic
`CotypingMacro.Result`: A computed result: what to preview under the caret, and what to insert on
accept. The two differ for arithmetic (`= 10` preview, `10` insertion).

#### Uses live clock and RNG by default; tests inject deterministic Engine
`CotypingMacro.match`: Best macro for the trailing `/query` at the caret, or nil. Uses the live
clock/RNG by default; tests inject a deterministic `Engine`.

#### Token length regardless of evaluation, used to delete it on accept
`CotypingMacro.trailingTokenLength`: Length of the trailing `/query` run (`/` + query), regardless of whether it
evaluates — used to delete it on accept.

#### Internal slash after non-space stays in query; newline or over-long run aborts
`CotypingMacro.scanToken`: Walks back from the caret collecting the query until a boundary `/` (the
sigil). An internal `/` preceded by a non-space (division, `5/2`) stays in
the query; a newline or an over-long run aborts.

#### Macro families tried in priority order; clock, RNG and rates injected
`CotypingMacro.Engine`: Aggregates the macro families and tries them in priority order (date and
random are keyword-specific; unit and currency both key off the conversion
separator but reject each other's tokens; arithmetic is the catch-all).
The clock, RNG, and rate table are injected so the engine is deterministic.

#### Supported relative offset forms: +3d, -5d, +2w, +1mo, +1y
`CotypingMacro.Engine.relativeDate`: Relative offsets like `+3d`, `-5d`, `+2w`, `+1mo`, `+1y`.

#### next is strictly after today, this includes today, last strictly before
`CotypingMacro.Engine.weekdayDate`: `next-<weekday>` (strictly after today), `this-<weekday>` (incl. today),
`last-<weekday>` (strictly before today).

#### Weekday prefix with space or no separator rewritten to dash form
`CotypingMacro.Engine.canonicalBase`: Applies `baseAliases`, then rewrites a `next`/`this`/`last` weekday prefix
written with a space or no separator into the dash form (`next-fri`).

#### Currency uses bundled offline rates, never the network
`CotypingMacro.Engine.evaluateCurrency`: MARK: Currency (bundled offline rates — never touches the network)

#### Hand-written parser avoids NSExpression injection risk
`CotypingMacro.Engine.evaluateArithmetic`: MARK: Arithmetic (hand-written parser — no NSExpression injection risk)

#### Integers print without point; others up to 10 significant digits
`CotypingMacro.Engine.formatNumber`: Integers print without a point; others print up to 10 significant digits.

#### Conversion split on ->, arrow or ' to ', shared by unit and currency
`CotypingMacro.Engine.splitConversion`: Splits a conversion query (`<value><from> <sep> <to>`) on `->`, `→`, or
` to `. Shared by the unit and currency families.

#### Bundled approximate rates per USD; never reaches network, local-only posture
`CotypingMacro.CurrencyRateTable`: Bundled, offline, approximate exchange rates (units per USD). Never reaches
the network — in keeping with LokalBot's strictly-local posture.

### `LokalBot/Cotyping/CotypingMarkerSelection.swift`

#### Text windowed around caret; selection indexes the same text
`CotypingMarkerSelection`: A selection synthesized from WebKit/Chromium AX text markers.

`text` is already windowed around the caret, and `selection` indexes into
that same text. Keeping those two values in the same coordinate space lets
the normal cotyping context split run without knowing whether the host used
native ranges or opaque text markers.

#### Chromium counts selection without paragraph breaks; realign caret to AXValue
`CotypingParagraphBreakAlignment`: Moves a caret counted without paragraph breaks into a value that has them.

Chromium counts a rich-text field's selection, and the text it returns for
`AXStringForRange`, over the field's text without the line breaks it puts
between paragraphs, while the field's `AXValue` has them. Split at the
reported offset, the value put the caret one character early for every
paragraph above it: in a Reddit post on 2026-10-21, a suggestion after
"elabor" began "rate", and the "r" left after the caret made it look
mid-line, so the suggestion showed in a popup over the text.

#### Returns nil when value and caret counts do not line up
`CotypingParagraphBreakAlignment.caretLocation`: Where the caret is in `value`, given the text before it in the count
the selection uses, or nil when the two do not line up that way.

### `LokalBot/Cotyping/CotypingMeetingPause.swift`

#### Pause cotyping during recording: machine busy and ghost text unwelcome mid-call
`CotypingMeetingPause`: Policy for pausing cotyping while a meeting records, kept pure for unit
tests. Two things happen during a recording: the machine is busy with
capture + transcription prewarm, and ghost text popping up mid-call (often
while screen-sharing) is exactly when suggestions are least welcome. The
coordinator checks the live flag before every generation; this type owns
the state transition when the flag flips.

#### Pausing wins; resuming clears only own pause reason
`CotypingMeetingPause.transition`: The state to move to when the recording flag flips, or nil to leave
the current state alone. Pausing always wins; resuming only clears the
pause label itself (never a disabled reason someone else set).

### `LokalBot/Cotyping/CotypingMemoryContext.swift`

#### Retrieval policy over enabled saved sources, not a second model call
`CotypingMemoryContext`: Small, relevant facts from explicitly enabled saved sources. This is a
retrieval policy, not a second language-model call or a persistent profile.

#### Writing tool's grants alone permit reading saved facts; overnight scheduling not consulted
`CotypingMemoryContext.Policy`: The writing tool's own grants are the whole permission to read saved
facts. Whether new overnight reviews are scheduled is a separate choice
and is deliberately not consulted here.

#### Only user's own words show a saved sentence is on the same topic
`CotypingMemoryContext.Query`: What the writing is about, kept apart by where each word came from. The
conversation above the field may name a saved topic, but only the
user's own words can show that a saved sentence is about the same thing.

#### Named words are capitalized or digits not merely opening a sentence
`CotypingMemoryContext.Query.named`: Words the draft or title writes as a name: a capital letter or digit
that does not merely open a sentence.

#### Sentence openers count as names only when fact capitalizes same word
`CotypingMemoryContext.Query.capitalized`: `named` plus capitalized sentence openers, which count as names only
when the saved fact capitalizes the same word.

#### Window title ends with app name, which is not a topic
`CotypingMemoryContext.Query.init`: A window title usually ends with its app's name, which is not a topic.

#### Titles are not prose; every capitalized title word may be a name
`CotypingMemoryContext.Query.init`: Titles are not prose: every capitalized title word may be a name.

#### Higher score first; named-source facts displace wording-only matches
`CotypingMemoryContext.Relevance`: Why a fact was kept: a higher score ranks first, and facts from a named
source displace ones that only share wording.

#### Generic language must not pull unrelated private facts into a draft
`CotypingMemoryContext.genericTerms`: Generic writing/meeting language must not pull an unrelated private fact
into a draft merely because both contain "project", "owner" or "today".

#### Distinctive term can show shared topic; see everydayTerms
`CotypingMemoryContext.isDistinctive`: A term that can show two texts share a topic. See `everydayTerms`.

#### Sentence-opening capitals alone do not make a word a name
`CotypingMemoryContext.capitalizedTerms`: Distinctive words written with a capital letter or a digit. `opening`
holds the ones that start a sentence or line, where the capital alone
does not make the word a name.

#### Lookup searches only nearest 600 characters of nearby text
`CotypingMemoryContext.maxVisibleQueryCharacters`: The part of the nearby text a lookup may search, nearest the field.

#### Only authorized live excerpts add search terms; whole-window text would name too much
`CotypingMemoryContext.query`: Only the already-authorized, spatially selected live excerpts can add
search terms. This connects a short reply to a project named above it.
Whole-window text ends with the lines nearest the field; the rest of
the window (sidebars, lists) would name far too much.

#### Source named when half its distinctive title words appear in context
`CotypingMemoryContext.names`: A source is named when at least half of its title's distinctive words
appear in the draft, window title or visible conversation. One shared
word of a long title is too little to pull in everything filed under it.

#### Heading judged against title only, never the draft
`CotypingMemoryContext.isHeading`: A line from notes that adds no word to its source's title: a heading or
the title itself. Judged against the title and never against the draft,
so a fact stays a fact when the draft already mentions its answer.

#### Fact needs named source or shared distinctive words; everyday wording never counts
`CotypingMemoryContext.relevance`: Whether a saved fact has earned a place in the prompt, and how firmly.

- A notes line must not be a heading (see `isHeading`). Work-memory
  entries are statements already, even when one is its own title.
- Its source is named (see `names`), or
- the fact shares two distinctive words with the user's own draft or
  window title, one of them written as a name, or three when none is.

Everyday wording never counts as shared: two common words in a generic
sentence used to be enough to borrow a date from an unrelated meeting.

#### Prefer short facts to keep prompt budget independent of source size
`CotypingMemoryContext.select`: Prefer short facts; keep the prompt budget independent of source size.

#### Recognized named topic excludes other projects' overlapping facts
`CotypingMemoryContext.select`: If a named topic is recognized, generic sentence overlap in another
project's facts must not add a second, conflicting name or deadline.

#### Older version of same named topic must not contradict current one
`CotypingMemoryContext.select`: An older version of the same named topic must not contradict the
current one. Multiple snippets from the current source remain useful.

### `LokalBot/Cotyping/CotypingMemoryContextProvider.swift`

#### Read current files off UI thread; FTS only finds candidates, no cached private facts
`CotypingMemoryContextProvider`: Reads current local sources off the UI thread. No private facts are cached
or copied into a new store. FTS is only a candidate finder: prompts use the
current files, so an old index row cannot resurrect edited/deleted text.

#### Writing naming nothing distinctive is answered without opening the library
`CotypingMemoryContextProvider.load`: Writing that names nothing distinctive cannot match a saved topic, so
it is answered without opening the library.

#### Work memory read under writing grants alone; overnight scheduling separate
`CotypingMemoryContextProvider.load`: Saved work memory is read under the writing grants alone; scheduling
new overnight reviews is a separate setting.

#### A digest can mix meetings with activity and coding-agent history
`CotypingMemoryContextProvider.memoryItems`: A digest can mix meetings with activity/coding-agent history.

#### Only distinctive words reach index so named meeting is not crowded out
`CotypingMemoryContextProvider.meetingItems`: Only distinctive words reach the index: everyday wording matches
nearly every transcript and would crowd out the meeting that is named.

#### Projection applies saved corrections and omits archived outcomes
`CotypingMemoryContextProvider.meetingItems`: Projection applies saved corrections and omits archived outcomes.

#### Shared projection checks transcript revision and follow-up draft; bound and watch them
`CotypingMemoryContextProvider.meetingItems`: The shared projection also checks the transcript revision and
loads a follow-up draft. Bound and watch those dependencies too.

### `LokalBot/Cotyping/CotypingMemoryLookup.swift`

#### Keystroke never waits for lookup; new lookup only when finished words change
`CotypingMemoryLookup`: The newest saved-memory lookup for one field. A keystroke never waits for
a lookup: it takes the newest finished one, and a new lookup runs only when
the field or the finished words before the caret change what could match.

#### Different field forgets previous field's facts at once
`CotypingMemoryLookup.begin`: Starts a lookup, replacing one still running. A different field
forgets the previous field's facts at once.

#### Finished lookup kept only if still the one asked for last
`CotypingMemoryLookup.finish`: Keeps a finished lookup only if it is still the one asked for last.

#### Half-typed word neither starts lookup nor changes facts mid-word
`CotypingMemoryLookup.finishedWords`: The text before the caret without a word still being typed, so a
half-typed word neither starts a lookup nor changes the facts mid-word.

### `LokalBot/Cotyping/CotypingMemoryVocabulary.swift`

#### Everyday terms may be detail but never prove shared topic; first names excluded
`CotypingMemoryContext.everydayTerms`: Everyday wording, calendar words and app names. A saved fact may supply
one of these as its detail ("in November", "on Zoom"), but sharing them
never shows that a draft is about the same topic: "I'll get back to" is
not about a note that happens to say so too.

Folded like `terms`: lowercase, no diacritics, apostrophes split. Words
that double as common first names (Sam, Ali, Jan) are left out so a
person can still be looked up by name.

### `LokalBot/Cotyping/CotypingMidWord.swift`

#### HTTP route cannot mask first token, so normalizer enforces mid-word continuation
`CotypingMidWord`: Mid-word continuation rules. Ports Cotabby's `MidWordContinuationPolicy`.

When the caret sits strictly inside a word (a word character on BOTH sides),
the suggestion must continue that word, not start a new one. Cotabby enforces
this in-process by masking the first sampled token so it carries no leading
whitespace. LokalBot's HTTP route can't mask a token mid-generation, so
`CotypingTextNormalizer` reproduces the same outcome at the output layer
for both routes using these pure helpers: never re-type the current
partial word, and (strictly inside) never begin with whitespace or an
incompatible word tail.

#### Force continuation only strictly inside a word; word end keeps next-word prediction
`CotypingMidWord.shouldForceContinuation`: True only when the caret is strictly inside a word — a letter/digit
immediately before AND after it. At a word end (nothing or punctuation
after the caret) this is false, so ordinary next-word prediction (which
wants a leading space) is left untouched — exactly Cotabby's policy.

#### Overlap counts only when prefix completes either fragment; weak one-character prefixes ignored
`CotypingMidWord.acceptedTrailingOverlapCount`: How much already-present text to the right of the caret should be removed
before accepting a forced mid-word suggestion. This only treats a prefix as
an overlap when it completes either the accepted word fragment or the
existing right-side word fragment, so a weak one-character common prefix
like "operate" vs "ord" is left alone.

### `LokalBot/Cotyping/CotypingModels.swift`

#### Cotyping overview: built-in model in-process, others via HTTP; value types stay Sendable
Cotyping — LokalBot's third major feature: inline AI autocomplete in (almost)
any macOS text field. Modeled on Cotabby's suggestion pipeline. The built-in
model runs in-process (`Llama/`); other backends go through LokalBot's HTTP
`llama-server` (`/v1/completions`) or a server the user chose.
`CotypingEngineSelector` picks the route for each completion.

This file holds the value types shared across the cotyping subsystem. They
are deliberately `Sendable` value types so they can cross the async /
main-actor boundaries the pipeline runs over (focus poll → debounce →
generation → overlay → acceptance) without aliasing live AX handles.

#### Editable but withheld for secure field or non-empty selection
`CotypingCapability.blocked`: Editable, but a suggestion is intentionally withheld (secure field, or a
non-empty selection). The string is a short human-readable reason.

#### Value-type snapshot from one synchronous AX read carried unaliased through pipeline
`CotypingField`: A value-type snapshot of the focused editable field. Produced by
`CotypingAXHelper`/`CotypingFocusTracker` from a synchronous Accessibility
read and then carried, unaliased, through the rest of the pipeline.

#### Focus identity excluded from content signature because hosts recycle AX handles
`CotypingField.focusIdentityKey`: Stable-enough identity for short-lived focus smoothing. This is not part
of the content signature because host apps may recycle AX element handles.

#### Caret rect in global Cocoa coordinates, Y-flipped against primary display
`CotypingField.caretRect`: Caret rectangle in global Cocoa coordinates (bottom-left origin, already
Y-flipped against the primary display in `CotypingAXHelper`).

#### Field bounds in Cocoa coordinates used as inline ghost wrapping budget
`CotypingField.inputFrameRect`: Focused editable element bounds in global Cocoa coordinates, when AX
exposes them. Inline ghost layout uses this as the wrapping budget.

#### Secure fields are never read or suggested into
`CotypingField.isSecure`: True for password / secure-entry fields — never read or suggested into.

#### True for xterm.js terminals embedded in non-terminal hosts
`CotypingField.isIntegratedTerminal`: True when the focused web text field is an xterm.js terminal surface
embedded inside a non-terminal host like VS Code, Cursor, or a browser.

#### Exact AX caret versus estimated from field frame (lower confidence)
`CotypingField.caretIsExact`: `true` when the caret rect came from an exact AX range query; `false`
when it was estimated from the field frame (lower placement confidence).

#### Window title is strongest topic cue, read only when app-context enabled
`CotypingField.windowTitle`: The focused window's title (email subject, doc name, chat channel, page
title) when app-context is enabled — the strongest topic cue we get.

#### Field font and color resolved from AX and cached when host-style matching enabled
`CotypingField.fieldStyle`: The field's own font/color (resolved from AX, cached per element) when
host-style matching is enabled, so the ghost can mimic the field.

#### Hash of positively identified document, never inferred; nil means learning abstains
`CotypingField.learningScopeKey`: Hash of a positively identified document, never inferred from a recipient
name or generic window title. Nil means local learning must abstain.

#### Filled only by explicitly requested background context capture
`CotypingField.visibleContext`: Only filled by an explicitly requested background context capture.

#### Chromium rich text counts selection without breaks; accept re-reads same way
`CotypingField.selectionSkipsParagraphBreaks`: The app counts the selection without line breaks its value has
(Chromium rich text), so an accept re-reads the text the way this
snapshot was read, not through `AXStringForRange` windows.

#### Content-only fingerprint excludes AX identity because web engines recycle handles
`CotypingField.contentSignature`: Content-only fingerprint used to detect "did the field actually change"
across keystrokes and to drop stale async generations. Excludes the AX
element identity on purpose: web engines recycle element handles.

#### Identity readable without exposing text, for capability smoothing of blocked snapshots
`CotypingFocus.focusIdentityKey`: Identity of the focused editable element when it can be read without
exposing text. Used for transient capability smoothing while blocked
snapshots intentionally omit a full field payload.

#### Browser tab host read over AX only when per-domain rules exist; site gating only
`CotypingFocus.host`: Normalized host of the focused tab's URL (browsers only), read over AX when
per-domain rules are configured. Nil otherwise. Used only for site gating.

#### Defaults mirror Cotabby standard: low temperature, fixed seed for reproducibility
`CotypingConfiguration`: Sampling + windowing knobs for one generation. Defaults mirror Cotabby's
shipped `SuggestionConfiguration.standard` (low temperature for stable inline
completions); the fixed seed keeps identical context reproducible.

#### Fixed sampler seed so same context yields same ghost text
`CotypingConfiguration.standard.seed`: 0x00C0FFEE — Cotabby's "coffee" sampler seed; stable so the same
context yields the same ghost text.

#### Request carries everything so normalizer stays a pure function of it
`CotypingRequest`: One generation request handed to `CotypingCompleting`. Carries everything the
engine needs to call the model AND everything `CotypingTextNormalizer` needs
to clean the result, so the normalizer stays a pure function of the request.

#### Windowed caret prefix alone, used to strip prefix echoes
`CotypingRequest.prefixText`: The windowed caret prefix alone (used to strip prefix echoes from output).

#### Word ceiling enforced after output so token drift cannot make setting lie
`CotypingRequest.maxWords`: User-facing word ceiling for one suggestion. The normalizer enforces this
after model output so token-budget drift cannot make the setting lie.

#### Coordinator drops results whose generation no longer matches live focus
`CotypingRequest.generation`: Monotonic freshness token — the coordinator drops results whose
generation no longer matches the live focus.

#### Caret strictly inside a word forces continuation, enforced by normalizer
`CotypingRequest.forceWordContinuation`: True when the caret is strictly inside a word (Cotabby's
`forceWordContinuation`): the completion must continue the current word.
Enforced at the output layer by `CotypingTextNormalizer`.

#### Mid-word prefix drives prompt healing, required decode prefix and rejection
`CotypingRequest.wordPrefixAtCaret`: The run of word characters immediately before the caret ("" at a word
boundary). When non-empty the user is mid-word and the completion should
extend this fragment: the in-process runtime heals the prompt at the
word boundary and decodes with this as a required prefix; the normalizer
uses it to reject continuations that ignore the fragment.

#### Valid word may be followed by space; invalid fragment must be extended
`CotypingRequest.wordPrefixIsValidWord`: Whether `wordPrefixAtCaret` is itself a valid standalone word (per the
native spell checker). A valid word ("the") may legitimately be followed
by a space; an invalid fragment ("follo") must be extended, so a
whitespace-leading completion is rejected. Defaults permissive.

#### Hidden preface kept only to suppress prompt-context echoes
`CotypingRequest.conditioningPreface`: Exact hidden conditioning preface included in `prompt`, after renderer
truncation. This never reaches the UI; the normalizer uses it solely to
recognize and suppress prompt-context echoes, including streamed prefixes.

#### Normalizer drops leading space when prefix ends on whitespace
`CotypingRequest.precedingEndsWithWhitespace`: `true` when the caret prefix ends on whitespace, so the normalizer drops
a leading space the model may add (deterministic space management).

#### Keep exact query so stale session cannot act on other macro or re-roll random
`CotypingSuggestionKind.macro`: Replace the trailing `/query` run with the already-previewed macro result
(`fullText`). Keeping the exact query prevents a stale session from acting
on a different macro and avoids re-rolling random macros during accept.

#### consumedCount advances in Characters; overlay shows only remaining text
`CotypingSession`: An active suggestion: the field it was generated against, the full completion,
and how much of it the user has already accepted (in Characters). Accepting a
word advances `consumedCount`; the overlay then shows only `remainingText`.

#### Only length-cut suggestions are topped up while accepted
`CotypingSession.isOpenEnded`: The model's latest output was cut by the length limit, so there is more
to say. Only such a suggestion is topped up while it is accepted.

#### Own accept key only with visible suggestion and live session; never while generating
`CotypingAcceptanceOwnershipPolicy`: The consuming event tap may own an accept key only while there is a visible
suggestion backed by a live session. In particular, generation in flight is
never enough: swallowing Tab while no suggestion is visible breaks ordinary
keyboard navigation and can accept output the user has not reviewed.

### `LokalBot/Cotyping/CotypingOverlayController.swift`

#### Click-through non-key panel; inline ghost never drawn over text
`CotypingOverlayController`: The floating ghost text. One borderless, non-activating, click-through
`NSPanel` at the caret in global Cocoa coordinates. It never becomes key or
main, so the host app keeps keyboard focus while a suggestion shows.

Inline suggestions are drawn in the field's own font, starting at the caret
on the field's baseline. Accepting or topping up an inline suggestion moves
it from the layout already on screen, without waiting for another
Accessibility read. An inline suggestion is never drawn over text: what does
not fit after the caret, or on free lines inside the field, is left out,
and `acceptanceText` says what is shown.

#### Accept takes the suggestion on screen, possibly only its start
`CotypingOverlayController.acceptanceText`: What an accept can take: the suggestion on screen, which may be only
the start of the text it was given.

#### Parameter semantics: acceptance text, partial display, trailing text, emphasis, background key
`CotypingOverlayController.show`

- Parameters:
  - acceptanceText: what an accept inserts, when it differs from what
is drawn.
  - mayShowPart: an inline suggestion may be cut short after any word
that fits, as a continuation can; `acceptanceText` is then what is
drawn. Otherwise it is drawn whole or not at all.
  - trailingText: the field's text after the caret. Wrapped lines are
never drawn over it.
  - emphasisLength: characters of `text` the next accept takes; nil
when one accept takes all of it.
  - backgroundKey: the field, for reusing the background measured
behind it (`CotypingFieldIdentity.background(for:)`).

#### Advance ghost past accepted text without waiting for host; false if unknown
`CotypingOverlayController.advanceInline`: Moves a visible inline ghost past text that was just accepted or typed,
to where the host will show the caret, without waiting for it. False
when that place is only known once the host shows the text; the ghost
is then left as it was.

#### Measure inserted text as typed: host draws every space, ghost collapses runs
`CotypingOverlayController.advanceInline`: Measured as typed: the host draws every space, while the ghost
draws a run of them as one.

#### Extension adds words that fit; existing words keep places
`CotypingOverlayController.extendInline`: Adds words to the end of a visible inline ghost, as many as fit where
it may be drawn. Words already on screen keep their places, and
`acceptanceText` grows by the words added.

#### Hosts publish insertion before caret moves, so short backward jump held after accept
`CotypingOverlayController.shouldHoldInlineReanchor`: Whether a re-read caret is close enough to the visible ghost to leave it
where it is. Hosts often publish an insertion before its caret moves,
so a short backward jump right after an accept is held too.

#### Wrap onto lines below only when they hold no text
`CotypingOverlayController.linesBelowAreFree`: Whether the lines under the caret hold no text, so a suggestion may
wrap onto them.

#### Popup below caret for mid-line carets or carets without exact geometry
`CotypingOverlayController.presentMirror`: A popup one line below the caret, for carets with text after them on
the line, or outside the field for carets without exact geometry.

#### First suggestion uses reported colors, then samples real pixels once to fix contrast
`CotypingOverlayController.sampleBackground`: The first suggestion in a field is drawn against its reported
colors; the real pixels behind it are then sampled once and the color
corrected if it would be hard to read.

#### Panel appearance can lag active app, so use AppKit effective appearance
`CotypingOverlayController.prefersDarkEnvironment`: Whether the system is in dark mode. The overlay panel's appearance can
lag the active app, so consult AppKit's effective appearance.

#### sharingType none keeps ghost out of screenshots, recordings and sampling
`CotypingOverlayController.ensurePanel`: Keep the ghost out of screenshots, recordings, and background sampling.

#### Panel never becomes key so it never steals focus from typed-into app
`CotypingOverlayPanel`: A panel that never steals keyboard focus from the app being typed into.

### `LokalBot/Cotyping/CotypingOverlayGeometry.swift`

#### Pure placement math in global Cocoa coordinates, unit-testable
`CotypingOverlayGeometry`: Pure placement math for the ghost overlay, split out from `show()` so the
frame geometry is deterministic and unit-testable. All rects are in global
Cocoa (bottom-left origin) coordinates.

#### 1.5 pt: movement too small to see or just rounding between reads
`CotypingOverlayGeometry.reanchorDriftTolerance`: Movement too small to see, or to be more than rounding between reads.

#### Hold ghost unless other line or caret past ghost start; ahead held only after accept
`CotypingOverlayGeometry.shouldHoldInlineReanchor`: Whether an inline ghost stays where it is when the caret is read
again. It moves to any other line, and whenever the caret is further
along the line than the ghost starts, because then the ghost covers
text just typed. A ghost ahead of the caret is held only right after
an accept: hosts often publish inserted text before its caret moves.

#### Popup one line below caret, flipped above if no room, for mid-line carets
`CotypingOverlayGeometry.mirrorFrame`: Mirror (popup) frame: a chrome pill one line below the caret, flipped
above when there is no room below. Used for mid-line carets where inline
text would paint over the host's trailing characters.

#### Estimated caret puts popup outside field, never covering text; nil if no room
`CotypingOverlayGeometry.popupFrame`: Popup frame for a suggestion. An exact caret gets `mirrorFrame`. A caret
estimated from the field's frame says nothing about where the text is,
so the popup goes just outside the field, below it or else above it,
and never covers the field's text. Nil when there is no such room.

### `LokalBot/Cotyping/CotypingPrefixWindow.swift`

#### Generation and truncation rules ported from Cotabby
`CotypingPrefixWindow`: Pure rules for "should we generate, and on how much context." Ported from
Cotabby's `SuggestionRequestFactory.shouldGenerateSuggestion` +
`truncatedPromptPrefix`.

#### No suggestions on blank field or numbers-only text; a word restores them
`CotypingPrefixWindow.shouldGenerate`: Generate only when there is at least one non-whitespace character before
the caret (no suggestions on a blank field), and not while everything
before it is numbers without a single letter: a verification code, a
phone number or an amount has no prose to continue. A word brings
suggestions back.

#### Numbers-only means digits with no letters, e.g. codes, phones, amounts
`CotypingPrefixWindow.isNumbersOnly`: Digits with no letters, such as `482 913`, `+382 67 123 456` or `12.50`.

#### Window starts at stable sentence boundary so model keeps its prompt cache
`CotypingPrefixWindow.truncatedPrefix`: Bound the latest text without rewriting paragraph breaks, list indentation,
or the exact whitespace at the caret. These are prediction inputs.

A window cut from longer text starts at a sentence or paragraph
boundary near its front. The model keeps what it has read for the
unchanged start of the prompt, and a window that moved by one character
per keystroke would make it read the whole window again every time.

#### Full stop after a letter ends sentence; numbered list '1. ' does not
`CotypingPrefixWindow.stableStart`: A full stop after a letter ends a sentence; "1. " numbers a list.

### `LokalBot/Cotyping/CotypingPromptRenderer.swift`

#### Model is text continuer; preface conditions by description; prefix last with exact whitespace
`CotypingPromptRenderer`: Builds the completion prompt for cotyping. Ported from Cotabby's
`BaseCompletionPromptRenderer`: the model is treated as a pure *text
continuer*, not an instruction-follower. Persona / style / language are
folded into a short conditioning preface (a model conditions on a
description, it does not obey a command in this mode), and the caret prefix
is the LAST thing in the prompt, with its exact whitespace intact. Native
token healing retokenizes the caret boundary without changing the user's text.

The recommended Gemma model is a base text continuer. Instruction-tuned
alternatives also continue this prompt through raw `/v1/completions`. The renderer
therefore returns the exact conditioning preface separately as well, so the
output boundary can suppress a partial or complete preface echo.

#### Cap preface at 900 characters so style note cannot crowd prompt
`CotypingPromptRenderer.maxPrefaceCharacters`: Upper bound on the conditioning preface so a long style note can never
crowd the prompt; the caret prefix arrives pre-windowed by
`CotypingPrefixWindow`.

#### Return exact post-truncation preface so output filtering compares real prompt
`CotypingPromptRenderer.render`: Returns both the wire prompt and the exact (post-truncation) hidden
preface. Keeping that boundary explicit lets output filtering compare
against what the model really saw instead of duplicating prompt labels.

#### Window text has own budget and comes first to preserve unchanged prompt start
`CotypingPromptRenderer.render`: Window text has its own budget, so a full window never crowds out
the lines below it. It comes first: it changes least while typing,
and the model keeps what it has read of an unchanged prompt start.

#### Blank line separates preface without echoable label; prefix stays final bytes
`CotypingPromptRenderer.render`: Blank line separates the conditioning preface from the live text
without a label the model could echo. Prefix stays the final bytes.

#### End prompt at word boundary for base-style continuation
`CotypingPromptRenderer.trimmingTrailingWhitespace`: Drops trailing spaces, tabs, and newlines so the prompt ends at a word
boundary (matters for a base-style continuation).

### `LokalBot/Cotyping/CotypingQualityReplay.swift`

#### Headless replay uses production construction; model sees only typed text and permitted context
`CotypingQualityReplay`: Explicit, headless replay of synthetic writing. References/scoring stay in the
caller: the model receives only the already-typed text and permitted context.
Uses production request construction, token healing, decoding and normalization.

#### Remote runs only compare hosted models; app never sends autocomplete text out
`CotypingQualityReplay.Engine`: Which model serves the replay. Remote runs exist only to compare hosted
models against the local one; the app itself never sends autocomplete text out.

#### Hosted raw completions; key from environment; chat mode for hosts lacking raw endpoint
`CotypingQualityReplay.Engine.remote`: A hosted raw `/v1/completions` endpoint behind the HTTP `CotypingEngine`.
The key comes from `LOKALBOT_REPLAY_API_KEY`, never the command line.
`extraBodyJSON` is a JSON object merged into every request body.
`chat` asks through `/chat/completions` instead, for hosts whose raw
endpoint cannot serve the model: the prompt is the user message.

#### Retry rate limits so they do not score as misses; time only answering attempt
`CotypingQualityReplay.remoteRetryLimit`: A rate limit or provider hiccup is retried so it does not score as a miss;
only the attempt that answered is timed.

#### Replay-only control; app autocomplete always enables the hybrid
`CotypingQualityReplay.Input.selectiveOneWordHybrid`: Replay-only comparison control; app autocomplete always enables the hybrid.

#### Reject archived research modes this integration does not implement
`CotypingQualityReplay.Input`: Reject archived research modes this integration does not implement.

#### Experiment control recorded in output; omit for product replay
`CotypingQualityReplay.Case.promptOverride`: Explicit experiment control, recorded in output. Omit for product replay.

#### Monotonic relative timestamps include cleanup when measuring cancellation
`CotypingQualityReplay.Observation.generationStartedAtMs`: Monotonic replay-relative timestamps include inter-request cleanup
and preparation when measuring cancellation through its replacement.

#### Keep research JSON key for confidence-trace reconstruction
`CotypingQualityReplay.Observation.cache`: Keep the research JSON key for confidence-trace reconstruction.

#### Chat messages have no caret token boundary: not healed, word space restored
`CotypingQualityReplay.run`: A chat message has no token boundary at the caret: it is not healed, and
the space a chat model leaves out before a new word is put back.

#### Confidence gate reads local token probabilities; hosted engines have none
`CotypingQualityReplay.run`: The gate reads the local model's token probabilities; hosted engines have none.

#### Loading and Metal priming excluded from warm prediction latency
`CotypingQualityReplay.run`: Loading/Metal priming is outside warm prediction latency.

#### Warm connection outside timed cases and fail fast on bad key or model
`CotypingQualityReplay.run`: Opens the connection outside the timed cases, and stops a bad key,
model ID or rejected field before it fails every case.

#### Retry only failures retrying can help; nil for bad key or unknown model
`CotypingQualityReplay.retryDelay`: Seconds to wait before retrying a remote failure, or nil when retrying
cannot help (bad key, unknown model, rejected request field).

### `LokalBot/Cotyping/CotypingRenderMode.swift`

#### Inline, mirror and withheld ghost render modes and when each applies
`CotypingRenderMode`: How the ghost overlay presents a suggestion. Ported from Cotabby's
`CompletionRenderMode`. Inline draws next to the caret; mirror draws the
suggestion as a popup below the caret, used when caret geometry is
unreliable or the caret sits mid-line (inline would paint over the trailing
characters the host still shows). Withheld draws nothing, for a caret that
is still being found on screen.

#### Withhold popup until on-screen caret found, to avoid popup jumping
`CotypingRenderMode.withheld`: The caret is found from the field's text on screen, and has not been
yet. A popup outside the field until then would jump between there
and the caret from one suggestion to the next.

#### Estimated caret rect drifts while typing, so popup goes outside field
`CotypingRenderMode.MirrorReason.caretGeometryEstimated`: Caret rect was estimated from the field frame, so inline ghost text
would drift as the user types. The popup goes outside the field.

#### Mid-line caret uses popup because inline ghost would cover trailing text
`CotypingRenderMode.MirrorReason.caretMidLine`: Real characters follow the caret before the next line break; inline
ghost text would draw on top of them.

#### Auto defers to caret geometry quality; pins override when auto misfires
`CotypingMirrorPreference`: User-facing render preference. Ported from Cotabby's `MirrorPreference`.
`auto` defers to caret-geometry quality; the two pins let a user override
when the auto rule misfires for their host mix.

#### Render decision is one pure struct; new triggers edit only it
`CotypingRenderModePolicy`: Pure rule that translates caret-geometry quality + the mid-line signal + the
user preference into a `CotypingRenderMode`. Ported from Cotabby's
`CompletionRenderModePolicy`. Pulling the decision into a value type keeps the
overlay focused on AppKit layout and makes the rule unit-testable; adding a
trigger means editing this one struct, not threading conditionals through the
controller.

#### End-of-line rule shared by policy and coordinator so they agree
`CotypingRenderModePolicy.isCaretAtEndOfLine`: Whether the caret is at the end of its line: when there is no text after
it, or that text begins with a newline. Pure derivation from the field's
trailing text — shared by the policy and the coordinator so they agree.

#### Estimated caret will be found from on-screen text once enough exists
`CotypingRenderModePolicy.mode`

- Parameter caretIsFoundOnScreen: an estimated caret will be found from
  the field's text on screen (`CotypingVisualCaret`) once there is
  enough of it.

#### Mid-line caret overrides alwaysInline pin because inline cannot render there
`CotypingRenderModePolicy.mode`: A mid-line caret has no inline home: ghost text would paint over the
trailing characters. This overrides an explicit `.alwaysInline` pin
too, because inline cannot render mid-line at all.

#### Exact geometry renders inline; estimated goes to popup unless found on screen
`CotypingRenderModePolicy.preferenceMode`: Exact (boundsForRange / text-marker) geometry lands close enough to
the real caret to render inline; an estimated caret can drift as
the user types, so route it to the popup, unless the caret will
be found on screen: then the suggestion waits for it, in the text.

#### Default placement keeps old inline, end-of-line, exact-caret rendering
`CotypingOverlayPlacement.inlineDefault`: Inline-safe default so call sites that don't supply a placement render
exactly as before (inline, end of line, exact caret).

### `LokalBot/Cotyping/CotypingSeamGuard.swift`

#### Show nothing rather than junk punctuation run or mid-word misspelling splice
`CotypingSeamGuard`: Final guard for visible failures at the caret seam. Ported from Cotabby's
`CompletionSeamGuard`: showing no suggestion is better than showing a junk
punctuation run or a mid-word splice that misspells the word being typed.

### `LokalBot/Cotyping/CotypingServerRoute.swift`

#### Built-in model runs in process or on its own llama-server
`CotypingBackend.onDevice`: The built-in autocomplete model, in process or on its own llama-server.

#### Reuse Think's Ollama/OpenAI-compatible server, with its model or another
`CotypingBackend.thinkServer`: The Ollama or OpenAI-compatible server Think uses, with Think's model
or another one on the same server.

#### Separate OpenAI-compatible server: cloud API, this Mac or user network
`CotypingBackend.server`: A separate OpenAI-compatible server: a cloud API, or a model server on
this Mac or another device on the user's network.

#### Automatic: raw completion for self-run servers, chat for hosted, chat fallback
`CotypingServerRequestStyle.automatic`: Raw text completion for servers people run themselves, chat for hosted
chat APIs, and chat after a server answers that it has no raw route.

#### Chat style sends autocomplete instruction with thinking turned off
`CotypingServerRequestStyle.chat`: `/v1/chat/completions` with the autocomplete instruction, thinking off.

#### Endpoint rebuilt from settings per request so changes apply next keystroke
`CotypingServerEndpoint`: One resolved autocomplete server. Built from settings for every request,
so a settings change applies to the next keystroke.

#### Loopback means the prompt never leaves this Mac
`CotypingServerEndpoint.isOnThisMac`: Loopback: the prompt never leaves this Mac.

#### Only self-hosted servers get llama.cpp sampling fields; hosted APIs may reject them
`CotypingServerEndpoint.isSelfHosted`: A server the user runs on this Mac or their own network, which accepts
llama.cpp's sampling fields. Hosted APIs may reject unknown fields.

#### OpenAI, Anthropic, OpenRouter start with chat; raw route unavailable or gibberish
`CotypingServerEndpoint.startsWithChat`: OpenAI and Anthropic offer no raw completions for current models, and
OpenRouter's raw route continues text as gibberish on many hosts
(Benchmarks/autocomplete/Cotyping/README.md). Servers people run themselves,
such as llama-server, LM Studio and Ollama, offer raw completions.

#### Server identity is origin, path and model, excluding the API key
`CotypingServerEndpoint.identity`: The server and model, without the key.

#### Unavailable carries a reason telling the user what to change
`CotypingRoute.unavailable`: A server is selected but cannot be used; the reason says what to change.

#### Key is for .server only; Think's server uses Think's key
`AppSettings.cotypingServerAPIKey`: API key for `.server`. Think's server uses Think's key.

#### Configured URL is before approval checks; nil for on-device or unset
`AppSettings.cotypingConfiguredServerURL`: The selected server's base URL as configured, before approval checks.
Nil for the on-device route and for a server that is not set up.

#### includingCredentials false skips Keychain read for presentation and context decisions
`AppSettings.cotypingRoute`: Where the next completion goes. `includingCredentials: false` skips the
Keychain read, for presentation and for decisions about context.

#### Prompt leaves Mac unless on-device or loopback; unset server counts as leaving
`AppSettings.cotypingLeavesThisMac`: True unless autocomplete's prompt stays on this Mac: the on-device
model, or a server on a loopback address. A server that is not set up
yet counts as off this Mac.

#### Remote host is nil when autocomplete is off, local, or unset
`AppSettings.cotypingRemoteHost`: The server autocomplete sends typing to: nil while autocomplete is
off, runs on this Mac, or has no server set up yet.

#### Fingerprint covers everything shaping completions for caches, excluding the key
`AppSettings.cotypingRouteFingerprint`: Everything about the route that changes what a completion can be,
for caches and setup checks. The key is left out.

#### Draft applied only with Use model so Cancel changes nothing
`CotypingServerDraft`: Where autocomplete runs, as edited in the Models picker. Applied with Use
model, so Cancel changes nothing.

#### Typed key saved to Keychain on Use model; empty keeps saved key
`CotypingServerDraft.apiKey`: A typed key for `.server`, saved to Keychain with Use model. Empty
keeps the saved one.

#### On-device model assigned only for on-device backend, so servers need no download
`CotypingServerDraft.patch`: The settings change Use model makes. The on-device model is assigned
only when autocomplete runs on this Mac, so a server needs no download.

#### Approval belongs to origin; loopback needs none since nothing leaves the Mac
`CotypingServerDraft.origin`: The origin the approval belongs to. Nil on this Mac, where nothing
leaves it and nothing needs approving.

#### Approved origins reflect the draft checkbox state
`CotypingServerDraft.approvedOrigins`: Approved origins with the draft's approval as the checkbox stands.

#### Preview route with draft applied without reading the Keychain key
`CotypingServerDraft.route`: Where completions would go with this draft applied. The key is not read.

#### Gate slots per origin like Think; failed requests never replayed
`RemoteCotypingEngine`: Autocomplete on a server: raw text completion where the server offers it,
chat continuation otherwise. Each request takes a slot on the origin's
`RemoteInferenceGate` like Think's requests do, and a failed one is never
replayed: a newer keystroke supersedes it anyway.

#### 15 s deadline matches raw-completion session limit, which chat lacks
`RemoteCotypingEngine.deadlineSeconds`: A completion slower than this is no longer worth showing. Matches the
raw-completion session's own limit, which chat requests do not have.

#### Servers rejecting raw route are asked via chat until LokalBot quits
`RemoteCotypingEngine.chatOnlyServers`: Servers whose raw route answered as unsupported. With the automatic
style they are asked through chat from then on, until LokalBot quits.

#### Problem kept until a suggestion arrives; Settings shows it since typing elsewhere shows no error
`RemoteCotypingEngine.problem`: The last request's failure or empty reply, until a request brings a
suggestion. Writing shows it, since typing elsewhere shows no error.

#### Publish only changes so working server does not redraw Settings
`RemoteCotypingEngine.report`: Publishes only a change, so a working server does not redraw Settings
on every suggestion.

#### Raw route unsupported on 404, 405, 501 or 400/422 mentioning chat
`RemoteCotypingEngine.rejectsTextCompletion`: A server without a raw completion route: missing, not allowed, or not
implemented, or a model the server serves through chat only.

#### Anthropic chat uses /v1 root whichever URL form was entered
`RemoteCotypingEngine.defaultEngine`: Anthropic serves chat completions under /v1 whichever form of its URL was entered.

#### Chat replies are not boundary-healed; missing word space is restored
`RemoteCotypingEngine.defaultEngine`: A chat reply has no token boundary at the caret: it is not healed, and the
space a chat model leaves out before a new word is put back.

#### Chat autocomplete: system instruction, 32-token minimum, empty reply is empty suggestion
`ChatContinuationEngine`: Autocomplete through a chat endpoint: the app's autocomplete instruction as the
system message and the rendered prompt as the user message, with thinking off.
The reply budget is at least 32 tokens; a reply cut off there keeps the text it
has, which the normalizer trims to a phrase. An empty reply means the model had
nothing to add, which is an empty suggestion rather than an error.

#### Extra 2048 tokens for always-reasoning models like glm-5.3-flash
`ChatContinuationEngine.reasoningRoomTokens`: Room for reasoning a model cannot turn off, on top of the phrase. On
OpenRouter `z-ai/glm-5.3-flash` always reasons, and on 2026-10-15 a
32-token reply ended inside that reasoning with no suggestion.

#### Models that spent a short reply on reasoning get room until quit
`ChatContinuationEngine.reasoningModels`: Models that spent a whole short reply on reasoning, by server and model.
Asked with reasoning room from then on, until LokalBot quits.

### `LokalBot/Cotyping/CotypingSessionReconciler.swift`

#### Pure reconciliation of session with live field and slow host publishing
`CotypingSessionReconciler`: Pure session-vs-live-field reconciliation: is the live field still the one
a session/generation was built against, did the host publish typing that
advances the session, and when should the coordinator wait for a slow host
to publish an insertion instead of tearing the session down. All functions
are pure over value types; the coordinator supplies the live state.

#### A changed published field state signals the keystroke landed
`CotypingSessionReconciler.hostPublishDidMove`: True when the host published a field state different from `baseline` —
the signal that a keystroke landed and generation may proceed.

#### Reject stale suggestion after focus moved to another field in same app
`CotypingSessionReconciler.isContinuation`: True when `liveField` is plausibly the same editable field `session` was
generated against: same process/role, compatible focused-field identity
when AX exposes one, and live text still anchored to the session prefix
(which only grows as we accept words). Guards against accepting a stale
suggestion after focus moved to another field in the same app, where the
PID alone would still match.

#### Destructive replacements need exact field snapshot, no growth tolerance
`CotypingSessionReconciler.isExactAcceptanceTarget`: Destructive replacement suggestions (correction, emoji, macro) require
the exact field snapshot that produced the visible ghost. Unlike a normal
continuation, they must not tolerate text growth or a best-effort
same-process fallback because they delete existing host text.

#### Typing through keeps session state, including top-up eligibility, like accept
`CotypingSessionReconciler.sessionReconciledByPublishedTyping`: Advances a continuation against the original field baseline. Handles
both plain typing that matches the suggestion tail (advancing the
consumed prefix) and the host catching up to an already-optimistically-
advanced session (typed is empty). Typing through keeps the rest of the
session, including whether it may be topped up, exactly as an accept does.

#### Do not show regeneration that re-suggests just-accepted chunk
`CotypingSessionReconciler.isStaleAcceptanceEcho`: A regenerated suggestion that merely re-suggests the chunk the user just
accepted (host hasn't published the insert yet) must not be shown.

#### Destructive edit built only after exact validation; pure for testing
`CotypingReplacementAcceptancePlanner`: Builds the destructive edit for a visible non-continuation suggestion only
after exact field and trigger validation. Keeping this pure makes the safety
boundary testable without an Accessibility element or a global event tap.

### `LokalBot/Cotyping/CotypingSpellChecker.swift`

#### NSSpellChecker flags non-words only; unique tag isolates session
`CotypingSpellChecker`: NSSpellChecker-backed typo detection + correction for cotyping autocorrect.
Ports Cotabby's `CurrentWordSpellChecker`: native, instant, offline,
multilingual, and the same engine the system underlines with. Flags
non-words only — real-word errors (their/there) are out of scope. A unique
spell-document tag isolates our session from other text-checking state.

#### Cache language verdict because each keystroke asks several times
`CotypingSpellChecker.lastVerdict`: Each keystroke asks several times about the same text; the language
is recognized once.

#### Spell-gated policies stand down for languages macOS lacks dictionaries for
`CotypingSpellChecker.verdictsApply`: Whether typo/known-word verdicts are meaningful for the text at the
caret. False when the context is confidently in a language macOS has no
dictionary for (Serbian, Croatian, Montenegrin, …) — every spell-gated
policy must stand down instead of flagging the whole language.

#### Unknown dictionary coverage must not make Serbian fragments spelling errors
`CotypingSpellChecker.wordPrefixIsValidWord`: Shared by live prediction and headless replay. Unknown dictionary
coverage must not turn every Serbian fragment into a spelling error.

#### Typo only if range spans whole word from 0, so I'm does not misfire
`CotypingSpellChecker.isTypo`: True when the whole word is misspelled (range must start at 0 and span the
entire word, so partly-flagged tokens like `I'm` don't misfire).

#### Completions distinguish unfinished word from typo; mirrors Cotypist mid-word
`CotypingSpellChecker.isCompletableWordPrefix`: True when the partial word the caret sits in can still become a real
word (native word-completion list is non-empty). Distinguishes an
unfinished word ("follo" → follow…) from a genuine typo ("recieve"),
which has no completions. Mirrors Cotypist's mid-word behavior: keep
completing while the fragment is a live word prefix.

### `LokalBot/Cotyping/CotypingSpellLanguageGate.swift`

#### Spell verdicts stand down when language has no installed dictionary
`CotypingSpellLanguageGate`: Decides whether native spell-check verdicts apply to the text at the caret.
macOS ships dictionaries for a fixed language set; text in any other
language (Serbian, Croatian, Montenegrin, …) is flagged word-by-word as
"misspelled" by whichever dictionary is active, and every spell-gated
policy — the typo gate, the seam guard, the word-prefix validity signal —
would silently suppress cotyping for the entire language. When the caret
context is confidently in a language with no installed dictionary, spell
verdicts stand down and the continuation pipeline runs ungated.

#### 200-character window: enough for recognizer, cheap per keystroke
`CotypingSpellLanguageGate.contextWindowCharacters`: Caret-preceding window used for identification: large enough for the
recognizer to be reliable, small enough to stay cheap per keystroke.

#### Below 0.5 confidence the recognizer guesses, so spell checking stays on
`CotypingSpellLanguageGate.minimumConfidence`: Below this the recognizer is guessing (a lone short fragment), so spell
checking stays on — identical behavior to before this gate existed.

#### Single token never enough evidence; recognizer confidence varies across macOS
`CotypingSpellLanguageGate.minimumWordCount`: Language-recognizer confidence varies between macOS releases for a
single token, which is never enough evidence to disable spell checks.

#### Dictionary match by base language; Serbian/Croatian/Bosnian match nothing
`CotypingSpellLanguageGate.hasDictionary`: Dictionary coverage by base language code: "en" covers "en_GB", "pt"
covers "pt_BR". Serbian/Croatian/Bosnian match nothing on a stock system.

### `LokalBot/Cotyping/CotypingStats.swift`

#### Metrics trimmed from Cotabby to those recorded at unambiguous pipeline points
`CotypingStats`: Cotyping usage + latency metrics. A pure, `Codable` value type (the counters
and their derivation) wrapped by `CotypingStatsStore` for persistence.
Inspired by Cotabby's `PerformanceMetricsStore`, trimmed to the metrics that
matter for a local continuer and that record cleanly at unambiguous pipeline
points (an LLM generation completing, an accept tap succeeding).

#### Live measures keyed by CotypingSurfaceClass raw value
`CotypingStats.live`: What happened in other apps, by kind of writing surface (a
`CotypingSurfaceClass` raw value). See `CotypingLiveMeasure`.

#### Missing fields decode to defaults so saved counters survive upgrades
`CotypingStats.init(from:)`: Counters saved before a field existed keep their values instead of
resetting the whole record.

#### Ratio can exceed 1.0 with phrase accepts; signals how much is kept
`CotypingStats.acceptsPerGeneration`: Accepts per generation. Phrase acceptance can push this above 1.0 (one
generation accepted in multiple word chunks), which is itself a useful
"how much of each suggestion do I keep" signal.

#### Persistence is async so JSON and UserDefaults writes stay off UI actor
`CotypingStatsPersisting`: Async persistence seam so JSON encoding and UserDefaults writes never run
on the UI actor. Actor implementations also give queued snapshots a single
deterministic writer.

#### Stats stored locally as two UserDefaults JSON blobs, written by an actor
`CotypingStatsStore`: Owns the persisted `CotypingStats` and `CotypingUsageHistory` and records
into them from the coordinator. `@MainActor` + `ObservableObject` keeps UI
state immediately observable, but persistence is delegated to an actor.
Local only — written to UserDefaults as two small JSON blobs; never leaves
the device.

#### Usage not Published: per-keystroke typed counts must not redraw Settings
`CotypingStatsStore.usage`: Day-by-day use for the statistics. Not `@Published`: typed characters
arrive with every keystroke in other apps, and an open Settings window
need not redraw for each. Other changes announce themselves, and the
next generation or accept shows the typing.

#### Accept counters live in UI; disk written when suggestion completes
`CotypingStatsStore.recordAccept`: Accept counters stay live in the UI for every chunk, but disk remains
dirty until the coordinator closes that suggestion.

#### Live measurements persist with next generation or completed suggestion
`CotypingStatsStore.recordShown`: Live measurements share the accept counters' persistence boundary: they
are written with the next generation or completed suggestion.

#### Usage accepts saved with the suggestion like accept counters
`CotypingStatsStore.recordSuggestionAccept`: Saved with the suggestion, like the accept counters.

#### Per-key typed recording neither redraws nor writes
`CotypingStatsStore.recordTyped`: Called for each key typed where autocomplete works, so it neither
redraws nor writes; see `usage`.

#### One persistence boundary for all chunks of one suggestion
`CotypingStatsStore.suggestionCompleted`: One persistence boundary for all chunks accepted from one suggestion.

#### Flush dirty counters at termination for partially accepted sessions
`CotypingStatsStore.flushPersistence`: Persists any dirty counters and awaits all background writes. This is
the termination safety net for an in-flight/partially accepted session.

#### Usage history written only when it changed
`CotypingStatsStore.enqueuePersistence`: Writes the counters, and the usage history only when it changed.

#### --cotyping-measurements prints saved stats as JSON for driven-app scripts
`CotypingStatsStore.printSaved`: `--cotyping-measurements`: print what is saved, as JSON, so a script
that drove real apps can check how suggestions and accepts went.

### `LokalBot/Cotyping/CotypingSuggestionAnchorCache.swift`

#### Bounded cache re-shows valid tails for focus bounce, backspace, type-through
`CotypingSuggestionAnchorCache`: Bounded memory of recently shown continuation suggestions. It lets common
editing paths re-show the still-valid tail instantly, without debounce or a
model call: focus bounce, backspace rollback, and typing through a suggestion
after the active session was cleared.

#### Restoration carries whether suggestion may still be topped up
`CotypingSuggestionAnchorCache.Restoration`: A still-valid tail, and whether the suggestion it came from may be
topped up as it is accepted or typed through.

#### Fingerprint excludes live caret prefix since type-through is what cache speeds
`CotypingSuggestionCacheFingerprint`: Stable, deterministic identity for the parts of a generation request that
are allowed to outlive the active session in `CotypingSuggestionAnchorCache`.
The live caret prefix is intentionally excluded: typing through a displayed
suggestion is exactly what the cache accelerates. Everything else that can
change the model or its output is included.

#### Length-prefix components so embedded separators cannot collide
`CotypingSuggestionCacheFingerprint.make`: Length-prefix every component so embedded separators cannot collide.

### `LokalBot/Cotyping/CotypingSuggestionExtension.swift`

#### Top up suggestion at two words left, stop at sentence end, like Cotypist
`CotypingSuggestionExtension`: Rules for topping up a suggestion while it is accepted or typed through, so
the ghost stays a few words ahead instead of running out and reappearing.
Cotypist does the same: once two words are left it appends the next few,
and it stops at the end of the sentence. Pure; the coordinator runs the model.

#### One-word limit never tops up; user wants one word at a time
`CotypingSuggestionExtension.threshold`: Words left at which a top-up starts under `wordLimit`. A one-word limit
never tops up: the user asked for one word at a time.

#### Top-up asks one word fewer so ghost never exceeds limit plus one
`CotypingSuggestionExtension.topUpWordLimit`: Words asked for in one top-up. One fewer than a fresh suggestion, so
the ghost never grows past the limit plus one.

#### Only length-limited output is continued; one word short counts because tokens run out
`CotypingSuggestionExtension.isOpenEnded`: Whether model output stopped because it reached the length limit rather
than because the thought was finished. Only such output is continued;
a sentence that ended, or a short answer the model chose to stop at, is
left alone. One word short of the limit still counts, because the token
budget can run out before the last word is whole.

#### Model continues from preceding text plus the whole suggestion
`CotypingSuggestionExtension.continuationPrefix`: The text the model continues from: what stood before the caret when the
suggestion was made, followed by the whole suggestion.

#### Addition must start new word and not repeat; on-screen words stay unchanged
`CotypingSuggestionExtension.addition`: The part of `output` that may be appended to `suggestion`, or nil when
nothing may. Words already on screen must not change, so the addition
has to start a new word (or attach punctuation) rather than lengthen the
last one, and it must not repeat what the suggestion just said.

### `LokalBot/Cotyping/CotypingSurfaceCaptureSingleFlight.swift`

#### Resolver runs outside lock; one capture at a time; same-key callers share result
`CotypingSurfaceCaptureSingleFlight`: Thread-safe one-entry surface cache with one active resolver. The resolver
runs outside the cache lock, so a slow cross-process AX call cannot block
unrelated cache/state readers. Same-key callers share the active result;
different-key callers wait outside the lock and retry against the one-entry
cache, keeping capture concurrency bounded to one.

#### Invalidation bumps generation so in-flight reads cannot repopulate cache
`CotypingSurfaceCaptureSingleFlight.removeAll`: Clears cached authorization context without blocking an in-flight AX
read. A read that began before invalidation may finish its original
caller, but its result cannot repopulate the cache or satisfy a newer
caller.

### `LokalBot/Cotyping/CotypingSurfaceContext.swift`

#### Window title conditions suggestions; suppressed for code editors and terminals
`CotypingSurfaceClass`: "What am I writing in?" context that conditions cotyping's suggestions on the
focused app + window. Ported from Cotabby's `AppSurfaceClassifier` +
`SurfaceContextComposer`: the window title carries the email subject, doc
name, chat channel, or page title — the single strongest situational cue a
small local model gets. Suppressed for code editors and terminals, where app
metadata biases the model toward code/numbers over prose.

Pure value logic — no AX, no I/O — so it is unit-testable.

#### Bundle IDs classified by case-folded prefix match
`CotypingSurfaceClassifier`: Bundle-identifier → surface classification. Prefix-matched, case-folded.

#### Surface capture refreshed after 1 s since chat composers reuse conversation titles
`CotypingSurfaceCapture`: AX-derived app/window metadata for the focused field.

CoTabby freezes this context while focus remains in one field. LokalBot
reads it again once it is a second old
(`CotypingAXHelper.surfaceCaptureMaximumAgeSeconds`): chat apps reuse one
composer across conversations, so a frozen title named the conversation
left behind. A second still keeps one suggestion's reads on one capture.

#### App uses single-flight cache with max age; non-expiring cache is test-only
`CotypingSurfaceCaptureCache`: The key for a field's surface capture. The app caches captures in
`CotypingSurfaceCaptureSingleFlight` with a maximum age; the one-entry
cache below, which never expires, is exercised only by tests.

#### Nil for code editors, terminals and bare generic apps as unsafe or useless
`CotypingSurfaceComposer.compose`: Builds a surface description, or `nil` when there's nothing useful (or
safe) to say — code editors, terminals, and bare generic apps.

#### Condition on topic, not UI descriptions that pull small models off prose
`CotypingSurfaceComposer.prefaceLines`: Condition on the writing topic. Descriptions of the UI ("text being
typed", "the window is titled") pull small models toward talking about
buttons and fields instead of continuing the passage.

#### Chat channel name used when no title; generic labels carry no topic
`CotypingSurfaceComposer.prefaceLines`: A channel name can still be useful when the host supplies no title.
Generic labels such as Message, Reply and Search carry no topic.

#### Strip app suffix and quotes that would corrupt the quoted line
`CotypingSurfaceComposer.sanitizedTitle`: Strips the app-name suffix apps append (`Inbox - Gmail`, `Doc — Pages`),
drops control chars and quotes (they'd corrupt the quoted line), caps length.

### `LokalBot/Cotyping/CotypingSystemInlinePredictions.swift`

#### macOS inline predictions compete with autocomplete; ask user to turn off
`CotypingSystemInlinePredictions`: macOS can draw its own grey inline prediction at the caret. With LokalBot's
autocomplete on as well, two suggestions compete in the same place.
Cotypist checks this setting and asks for the macOS one to be turned off;
the Autocomplete settings do the same.

#### Unset NSAutomaticInlinePredictionEnabled means on until user changes it
`CotypingSystemInlinePredictions.defaultsKey`: The global default behind Keyboard → Text Input → Edit… →
"Show inline predictive text". macOS leaves it unset until the user
changes it, and unset means on.

### `LokalBot/Cotyping/CotypingTextDirectionDetector.swift`

#### Walk backwards since nearest characters best signal direction for ghost placement
`CotypingTextDirectionDetector`: Detects the strong writing direction near the caret. We walk backwards
because the characters closest to the caret are the best signal for ghost
placement and post-accept drift direction.

### `LokalBot/Cotyping/CotypingTextLeafCaret.swift`

#### Chromium/Electron zero-size caret rects; derive caret from last text run edge
`CotypingTextLeafCaret`: Derives an exact caret rect from an editable's text-run descendants when
both range- and marker-based caret geometry fail.

Chromium and Electron (measured in Chrome and Discord) return zero-size
rects for a collapsed caret from `AXBoundsForRange` *and* from
`AXBoundsForTextMarkerRange` on the selection, and they do not implement
the marker-extraction attributes that would let us widen the range. But
Blink still exposes every laid-out text run as an `AXStaticText` child
with a tight pixel frame — so when the caret sits at the end of the text,
the last run's trailing edge *is* the caret. Pure geometry over plain
values so it is unit-testable without AX.

#### Leaf frames use top-left-origin AX display coordinates
`CotypingTextLeafCaret.Leaf.frame`: Top-left-origin AX display coordinates, like all raw AX frames.

#### Sane single run box height is 4 to 64 points
`CotypingTextLeafCaret.lineHeightBand`: Sanity band for a single text-run box height (points).

#### 4-point slack for borders and subpixel rounding in containment
`CotypingTextLeafCaret.containmentTolerance`: Slack for leaf-inside-element containment (borders, subpixel rounding).

#### Run boxes are 1.2-1.5 times font size; size from tall end
`CotypingTextLeafCaret.runHeightPerPointSize`: A run's box is about 1.2 to 1.5 times its font size tall. Sizing the
system font from the tall end keeps one line of text no wider than
its box, give or take the page font's own widths.

#### Text wider than 1.4 times its box is wrapped, so edge is not caret
`CotypingTextLeafCaret.wrappedRunWidthRatio`: Text set that way and wider than this many times its box cannot be one
line: the run wraps, its box spans several lines, and its trailing
edge is the end of its widest line rather than the caret.

#### Tolerate trailing newline editors keep; cheap pre-check avoids AX walk
`CotypingTextLeafCaret.caretIsAtTextEnd`: Whether the caret sits at the end of the field's text, tolerating the
trailing newline contenteditable editors keep in an "empty" tail
(Discord's empty composer value is "\n"). A caret after that newline
is on a new line, which no text run reaches. Cheap pre-check so
callers can skip the AX subtree walk entirely for mid-text carets.

#### Refuse unless caret at end and last run matches text; guesses are wrong
`CotypingTextLeafCaret.caretRect`: The caret rect in AX coordinates, or nil whenever the derivation would
be a guess: the caret must be at the end of the text, and the last
text run must be one line inside the element and match the tail of
the text the field reports (a trailing emoji/mention run the field
counts but the runs don't cover means the edge would be wrong —
refuse instead). A run may stop short of spaces typed at the end of
the text; the caret then sits that many spaces past the run.

#### Space width scaled from run's own measured width
`CotypingTextLeafCaret.spaceWidth`: One space in the run's font, scaled from the run's own width.

#### Web editors use no-break spaces where typed spaces would collapse
`CotypingTextLeafCaret.runText`: The text without trailing line breaks, with no-break spaces (which
web editors put where a typed space would collapse) as plain spaces.

### `LokalBot/Cotyping/CotypingTextNormalizer.swift`

#### Backend-agnostic pure cleanup ported from Cotabby making completions safe to show
`CotypingTextNormalizer`: Turns raw model output into clean inline ghost text. Ported from Cotabby's
`SuggestionTextNormalizer` + `TrailingDuplicationFilter` + `ControlTokenMarkers`
+ `InsertionSafetyGate` — the backend-agnostic, load-bearing cleanup that
makes a small local model's completion safe to show and insert.

Pure: the same `(raw, request)` always yields the same result, which makes it
directly unit-testable without a model.

#### Suppress echoes of hidden preface before visible or learnable
`CotypingSuppressionReason.promptContextLeak`: The model began echoing the hidden conditioning preface or one of its
structural labels. Suppressed before it can become visible or learnable.

#### Whitespace-leading completion after non-word fragment is suppressed
`CotypingSuppressionReason.wordCompletionMismatch`: Caret sits at the end of a non-word fragment and the completion began
with whitespace instead of extending it ("follo" + " up on that").

#### Pipeline step order mirrors Cotabby exactly
`CotypingTextNormalizer.normalizeDetailed`: Full pipeline. Mirrors Cotabby's ordering exactly: control-token strip →
think-block strip → prompt/prefix echo strip → leading scaffolding-label
strip → single/multi-line collapse → trailing-duplication → echo-prefix
strip → deterministic space management → safety gate.

#### Remember model line break; replace it with one space later
`CotypingTextNormalizer.normalizeDetailed`: The model put a line break between the typed text and its completion.
The break is dropped below; one space takes its place further down.

#### Trim leading newlines before collapsing so first line is not empty
`CotypingTextNormalizer.normalizeDetailed`: Drop leading formatting-only newlines before collapsing to one line, so
"\ndelicious" is not misread as an empty first line.

#### Instruct models restart from prompt head; detect leak before line collapsing
`CotypingTextNormalizer.normalizeDetailed`: Instruction-tuned models used as raw continuers occasionally restart
from the hidden prompt head. Compare with the exact rendered preface
before line collapsing so both full echoes and streaming prefixes are
suppressed. A valid continuation following an exact whole-prompt echo
has already had that prompt removed above and remains eligible.

#### Mid-word: drop re-typed partial word; HTTP backend cannot mask first token
`CotypingTextNormalizer.normalizeDetailed`: Mid-word: don't re-type the partial word the caret sits in, and (when
strictly inside a word — Cotabby's forceWordContinuation) don't begin
with whitespace, so the suggestion continues the current word instead
of restarting or space-breaking it. The HTTP backend can't mask the
first token like Cotabby's in-process runtime, so it's reproduced here.

#### Reject whitespace-leading continuation after invalid partial word at caret
`CotypingTextNormalizer.normalizeDetailed`: Caret at the end of a partial word (nothing word-like after it): when
the fragment is not a valid standalone word, a whitespace-leading
continuation would leave broken text ("follo" + " up on that") — reject
it. The in-process runtime's required-prefix decode can't produce this;
the HTTP fallback and misbehaving models can.

#### Space management after echo stripping, which can expose leading space
`CotypingTextNormalizer.normalizeDetailed`: Space management AFTER echo stripping (which can expose a leading space).

#### Add space when model's line break removed to avoid glued text
`CotypingTextNormalizer.normalizeDetailed`: Without its line break the completion would be glued to the typed
text: two words run together, or a comma loses its space
("Hi team," + "I'm working").

#### Exact preface authoritative; marker stems only when that line existed
`CotypingPromptLeakGuard`: Structural output guard for cotyping's hidden conditioning preface.

Matching is punctuation-, case-, and diacritic-insensitive. The exact
preface carried by the request is authoritative; marker stems are activated
only when that kind of line was really present, which catches paraphrased
values without maintaining a second copy of the full prompt.

#### Older prompt layouts can survive in examples; specific phrases rejected
`CotypingPromptLeakGuard.legacyMarkerStems`: Older prompt layouts can survive in a learned example or model prior.
These phrases are specific enough to reject as scaffolding, unlike broad
labels such as "Task" or "Application".

#### Catch altered labels only when active in this request's preface
`CotypingPromptLeakGuard.detectsLeak`: Catch a renderer label whose value was altered or omitted by the
model, but only when that label is active in this request's preface.

#### Partial markers need 8 characters so words like the are not scaffolding
`CotypingPromptLeakGuard.looksLikePromptScaffolding`: Context-free defense for persisted learning examples and benchmark
assertions. Partial markers require enough material to avoid classifying
ordinary one-word completions such as "the" as prompt scaffolding.

#### Window lines may be repeated; only their label stays protected
`CotypingPromptLeakGuard.protectedPrefaceLines`: Preface lines a suggestion must not repeat. The focused window's own
lines are left out: continuing with a name or phrase that is on screen
is what that context is for. Its label stays protected, and the block
ends at the blank line the renderer puts after it.

#### \</s> excluded as stop marker because it is also an HTML closing tag
`CotypingControlTokens.stopMarkers`: `</s>` is excluded on purpose (it is also the HTML `<s>` closing tag).

### `LokalBot/Cotyping/CotypingTypo.swift`

#### Typo rules pure; detection comes from NSSpellChecker, ported from Cotabby
Pure typo / autocorrect rules. Ports Cotabby's `CurrentWordExtractor` +
`TypoCaseTransfer` + `TypoGate` + `TypoCorrectionReplacementPlanner`.
Detection and correction themselves come from `NSSpellChecker`
(`CotypingSpellChecker`); these stay pure and testable.

#### Character count equals backspace count since one Delete removes one grapheme
`CotypingWord`: The trailing word at the caret plus its grapheme length (one Delete keypress
removes one grapheme, so this is the backspace count to erase the word).

#### Tolerate one trailing space so correction survives pressing Space
`CotypingWord.extractTrailingWord`: Tolerates exactly one trailing space so a just-finished word stays
actionable (the correction survives pressing Space).

#### Skip code, URLs, numbers, acronyms; misses fine, code false positives not
`CotypingWord.isPlausibleNaturalWord`: Skip non-natural-language tokens (code, URLs, numbers, all-caps acronyms)
so they're never flagged as typos. Conservative: misses are fine, false
positives on code are not.

#### Live word prefix mid-word is not a typo; only non-prefix fragments are
`CotypingTypoGate.resolve`: `isTypo` / `bestCorrection` / `isCompletableWordPrefix` are injected
(production: `CotypingSpellChecker`; tests: stubs) so this stays pure.

A word still being typed (no trailing space yet) that is a live prefix
of a real word ("follo" → follow) is NOT a typo — it is an unfinished
word, and the LLM continuation must run so it can complete it inline
(Cotypist's core mid-word behavior). Only a fragment that no dictionary
word starts with ("recieve") is treated as a typo mid-word. Once the
word is finished (trailing space), completability no longer applies.

#### Correction edit recomputed from live text at accept time
`CotypingCorrectionPlan`: The synthetic edit to replace a verified trailing typo, recomputed from the
live text at accept time (the field may have changed since the offer).

### `LokalBot/Cotyping/CotypingUsageHistory.swift`

#### Suggestion re-shown at a new caret counts again
`CotypingUsageCounts.shown`: Suggestions that appeared at the caret. A suggestion shown again at a
new caret, for example after an accept the app drew late, counts again.

#### Taken back means deleted or undone with the very next key
`CotypingUsageCounts.takenBack`: Accepts deleted or undone with the very next key.

#### Zero counts omitted to keep a quiet day to few bytes
`CotypingUsageCounts.encode`: Zero counts are left out, which keeps a quiet day to a few bytes.

#### Used capped at shown since midnight accepts can land on later day
`CotypingUsageCounts.acceptanceRate`: Share of shown suggestions you took part of. An accept just after
midnight can land on a later day than its suggestion, so `used` is
capped at `shown`.

#### Saved keystrokes are inserted characters minus accept presses
`CotypingUsageCounts.keystrokesSaved`: Key presses you did not make: every inserted character, less the
accept presses that inserted them.

#### Bucket stores no text, app name or window title; counts only
`CotypingUsageBucket`: One day or month of autocomplete use, with how much you typed yourself
where autocomplete could suggest. No text, app name or window title.

#### Typing speed from gaps up to max gap; sum and count
`CotypingUsageBucket.typingMilliseconds`: Gaps between consecutive typed characters, up to
`CotypingUsageHistory.maxTypingGapMilliseconds`: their sum and count
give your typing speed.

#### Speed reported only after minimum number of gaps measured
`CotypingUsageBucket.millisecondsPerKeystroke`: Average time per typed character, once there are enough gaps to say.

#### Daily rows kept 92 days for charts; monthly rows kept forever, cheap
`CotypingUsageHistory`: Autocomplete use by local calendar day and month. Daily rows are kept for
`retainedDays`, for the week and month charts; monthly rows are kept, so
longer ranges still add up and cost a few hundred bytes a month.

#### Day keys are yyyy-MM-dd strings
`CotypingUsageHistory.days`: "2026-10-14" → that day's counts.

#### Month keys are yyyy-MM strings
`CotypingUsageHistory.months`: "2026-10" → that month's counts.

#### Gaps over 1000 ms are pauses, not typing speed
`CotypingUsageHistory.maxTypingGapMilliseconds`: A longer gap between two typed characters is a pause, not typing speed.

#### Typing speed shown after 200 measured gaps
`CotypingUsageHistory.minimumTypingGaps`: Typing speed is shown once this many gaps have been measured.

#### Fallback 300 ms per key is 40 wpm at five characters a word
`CotypingUsageHistory.fallbackMillisecondsPerKeystroke`: Used for time saved until your own speed is known: 40 words a minute
at five characters a word.

#### firstOfSuggestion marks the suggestion as used
`CotypingUsageHistory.recordAccept`: One accept press. `firstOfSuggestion` marks the suggestion as used.

#### Gap recorded only when short enough to count as typing
`CotypingUsageHistory.recordTyped`: Characters you typed. `gapMilliseconds` is the time since the previous
typed character, when it was short enough to be typing.

#### Pruned daily rows keep their totals in months
`CotypingUsageHistory.prune`: Drops daily rows older than `retainedDays`; their months keep the totals.

#### Zero-padded day keys sort in date order
`CotypingUsageHistory.prune`: Zero-padded keys sort in date order.

#### Empty periods included so chart keeps even time axis
`CotypingUsageSummary`: One range of the history, ready to show: its total and one bar per day or
month, empty periods included so the chart keeps an even time axis.

#### Typing speed is a habit; short ranges borrow longer measurement
`CotypingUsageSummary.millisecondsPerKeystroke`: Time per keystroke from everything recorded, or nil while too little
typing has been measured. Typing speed is a habit, not a property of
the range, so a short range borrows the longer measurement.

#### Words per minute assumes five characters a word
`CotypingUsageSummary.wordsPerMinute`: Your measured typing speed in words a minute, at five characters a word.

#### Time saved uses user's typing speed or the fallback
`CotypingUsageSummary.timeSavedSeconds`: Keystrokes saved, at your typing speed or the fallback.

### `LokalBot/Cotyping/CotypingVisibleContext.swift`

#### Same bounded traversal for AX and replay; metadata before text, rejected branches unread
`CotypingVisibleContextSource`: The same bounded traversal runs over AX in production and a synthetic tree in
replay. Metadata is inspected before text; rejected branches are never read.

#### Window text is read from pixels on device
`CotypingVisibleContext.Policy.windowText`: The whole focused window, read from its pixels on device.

#### Snapshot reuse checked against the grant it was read under
`CotypingVisibleContext.Policy.permits`: Whether `snapshot` may still be used, by the grant it was read under.

#### Missing browser origin always abstains, unlike activity tracking
`CotypingVisibleContext.Policy.permits`: Unlike activity tracking, a missing browser origin always abstains.

#### Never read nearby text from private windows, per PRIVACY.md
`CotypingVisibleContext.Policy.permits`: Nearby text never comes from a private or incognito window, as
PRIVACY.md promises; activity tracking keeps its own rule.

#### Rectangles use AX global coordinates, origin top left
`CotypingVisibleContext.Target`: All rectangles use AX global coordinates (origin at the top left).

#### Each text source needs its own grant
`CotypingVisibleContext.Source`: How the text was read; each needs its own grant.

#### Window text keeps line breaks since conversations read line by line
`CotypingVisibleContext.Snapshot.text`: Window text keeps its line breaks: a conversation reads line by line.

#### Even metadata reads require the separate visible-context opt-in
`CotypingVisibleContext.capture`: Even metadata reads require the separate visible-context opt-in.

#### Read nearest messages first, never reading rejected text
`CotypingVisibleContext.capture`: Read the nearest messages first, without ever reading rejected text.

#### Omit credential-like snippets so model does not learn redaction markers
`CotypingVisibleContext.capture`: Omit credential-bearing snippets instead of teaching the model to
complete a redaction marker. Prompt control characters are stripped.

#### Re-sort excerpts into reading order after proximity selection
`CotypingVisibleContext.capture`: Preserve reading order in the prompt after selecting by proximity.

### `LokalBot/Cotyping/CotypingVisibleContextAXSource.swift`

#### Background focus worker only; no pixels, OCR, history, document values, or Tab-path reads
`CotypingVisibleContextAXSource`: Used only on the serialized background focus worker. No pixels, OCR, saved
screen history, whole document values, or reads on the consuming Tab path.
Window text (`CotypingWindowTextCapture`) uses only its `target`.

#### Window text needs no pane above field and climbs further in web apps
`CotypingVisibleContextAXSource.target`: The focused field's window and the privacy facts about it. Window text
reads the whole window, so it does not need a pane with room above the
field and falls back to the window itself. It also climbs further:
fields in web apps often sit more than 16 levels below their window.

#### Only static labels read as AXValue after visibility and editable exclusion
`CotypingVisibleContextAXSource.text`: The traversal has already proved full visibility and excluded editable
elements. A static label is the only AXValue read by this feature.

### `LokalBot/Cotyping/CotypingVisibleContextReplay.swift`

#### Synthetic OS boundary for evals; no answers or scoring in schema
`CotypingVisibleContextReplay`: Synthetic OS boundary for headless model evals and non-UI capture tests.
Answers/scoring are deliberately absent from this schema. The Settings
rehearsal also uses it, to pass its sample conversation through the same
selection as live nearby text.

### `LokalBot/Cotyping/CotypingVisualCaret.swift`

#### Find caret from on-screen text for fields reporting no AX caret
`CotypingVisualCaretLocator`: Finds the caret from the field's own text as it appears on screen, for
fields whose app reports no caret position through Accessibility.

Chrome's text areas are the case that needs it. In a GitHub comment box
every range and text-marker query answered an empty box at the page's
corner, with Chrome's text metrics and screen-reader mode on or off
(measured 2026-10-05), so a suggestion could only be shown beside the
field. Recognizing the line that ends at the caret puts it back on the
line being typed. Pure geometry over plain values, so it is unit-testable
without the screen.

#### Recognized lines are in global Cocoa coordinates
`CotypingVisualCaretLocator.RecognizedLine`: One line of text recognized on screen. Global Cocoa coordinates.

#### Baseline comes only from letters sitting on it, else nil
`RecognizedLine.baseline`: Bottom of its letters that sit on the baseline, or nil when it has none.

#### Last character edges kept because it may be the app's caret
`RecognizedLine.lastCharacterMinX`: Edges of its last character, and the trailing edge of the one
before, when recognition gave them: the last one may be the
app's caret, read as a letter.

#### Third character edge measures font when line start is garbled
`RecognizedLine.tailMinX`: Leading edge of its third character after any spaces. Recognition
garbles the start of a line more than the rest of it, so what
follows still measures the font when the first letters are lost.

#### Edges measured from pixels hold however letters were read
`RecognizedLine.edgesAreMeasured`: Its edges were measured from the image's pixels rather than from
what recognition read, so they hold however its letters were read.

#### Ink with more words than read means typed text is drawn
`RecognizedLine.inkHasMoreWords`: Its ink has more words than were read. Recognition lost one ("Видимо
се у" for "Видимо се у г"), so the typed text it lacks is drawn, not
missing from the frame.

#### Point size is the system font width-matched to the recognized line
`Calibration.pointSize`: Size of the system font whose width matches the recognized line.

#### Deleting into a line's first word may pull it up a line
`Calibration.firstWordEndX`: The end of the line's first word, when the line is not the first
of its paragraph. Deleting back into that word can let the word
return to the line above.

#### Size trusted only when a long line was fully read
`Calibration.sizeIsReliable`: Recognition read as many characters as were typed on a line long
enough to measure, so this size holds for the whole field. A line
missing its first letters gave sizes from 11 to 15 pt for one 13.5 pt
field (2026-11-02), and the ghost changed size from one find to the next.

#### First line start places later text typed there
`Calibration.textStartX`: Where the field's first line starts, when this is that line. Text
typed there later starts here too, whatever it is.

#### Typing this far from found caret triggers re-measurement
`CotypingVisualCaretLocator.maximumDrift`: Typing this far from where the caret was found is measured again.

#### Re-find in background after 12 characters while old caret stays in use
`CotypingVisualCaretLocator.refindAfterCharacters`: Typing this far starts measuring it again in the background, while the
caret already found stays in use.

#### Re-measure every 4 characters when font unmeasured or Cyrillic
`CotypingVisualCaretLocator.remeasureAfterCharacters`: The same while the field's font has not been measured from a whole
line: a size fitted to a few letters can be far off, and the caret
moves by it. And always on a Cyrillic line, where the system font follows
the field's own font worst: every 12 letters there left the caret up to
5.2 pt off, against 2.9 pt (replayed 2026-11-02).

#### Recognition never finds lines under three typed characters
`CotypingVisualCaretLocator.minimumLineCharacters`: Recognition found no line shorter than this (one to three typed
characters were never found, measured 2026-10-05).

#### Eight characters needed before fitted size holds for the field
`CotypingVisualCaretLocator.minimumMeasuringCharacters`: Characters a line needs before the size fitted to it holds for the field.

#### Eight characters needed for tail after first two to measure font
`CotypingVisualCaretLocator.minimumTailCharacters`: Characters a line needs for what follows its first two to measure the font.

#### Field text is rarely smaller than 10 pt
`CotypingVisualCaretLocator.smallestLikelyPointSize`: Text in a field is rarely smaller than this.

#### Empty finds on under 8 characters are not counted as misses
`CotypingVisualCaretLocator.minimumCharactersToCountAMiss`: A find on less typed text than this comes back empty too often to say
anything about the field: at 1x, 3 to 7 characters often gave no line.

#### Recognized line may lack up to 8 trailing typed characters
`CotypingVisualCaretLocator.maximumMissingCharacters`: Characters at the end of the typed text that a recognized line may
lack: the capture can be a frame behind the typing, and recognition
can miss a final full stop or a short last word (in Viber, " te" after
"Ima i dalje preklapanja", 2026-10-09).

#### Three consecutive empty finds mark field as caret-unfindable
`CotypingVisualCaretLocator.maximumFailedFinds`: After this many finds in a row came back empty, the field is treated
as one whose caret cannot be found on screen.

#### Fast recognition cannot read Cyrillic, so use accurate path
`CotypingVisualCaretLocator.caretLineIsCyrillic`: Whether the caret's line is in Cyrillic, which fast recognition cannot
read at all (its languages are Latin ones).

#### Accented Latin letters are unreadable to fast recognition; whole scripts excluded
`CotypingVisualCaretLocator.isUnreadable`: A Latin letter with an accent fast recognition has no way to read. It
knows English, French, Italian, German, Spanish and Portuguese, without
their accents in practice, so on a non-Retina display "Č" came back as
"&", "Ž" as "2", "Đ" as "E)" and "Š" not at all (2026-11-02). What it
reads there says nothing about whether the line is the typed one. Not
whole scripts: a line of them would match any text, and the caret went
up to 24 pt astray when all of Cyrillic was treated this way.

#### Recognition models only Russian and Ukrainian Cyrillic letters
`CotypingVisualCaretLocator.isCyrillicWithoutAModel`: The Cyrillic letters recognition has no model for: it reads Russian and
Ukrainian only, so "ђ" comes back as "h" and "њ" as "н" or "нь". The
rest of a Cyrillic line is compared as usual, which is what keeps a line
of about the right length from matching.

#### Spaces ignored because recognition runs words together
`CotypingVisualCaretLocator.recognizedCharacters`: The characters to compare: spaces say nothing, since recognition often
runs words together ("Zaomij" for "Žao mi j").

#### Align line end with typed text; text past it is drawn but unrecognized
`CotypingVisualCaretLocator.locate`: The end of a recognized line is aligned with the typed text: where
the two match best is where the line ends, and the typed text past
that point is drawn but was not recognized.

#### Count drawn characters back from line end, less lost first letters
`CotypingVisualCaretLocator.locate`: The typed characters drawn on this line, counted back from where it
ends without spaces: all of a paragraph that fits on it, less any
first letters recognition lost.

#### Letter without a model can read as none, one or two characters
`CotypingVisualCaretLocator.locate`: A letter without a model can read as none, one or two ("ль" for "љ").

#### With fewer characters read, line start is unreliable so measure from tail
`CotypingVisualCaretLocator.locate`: With fewer characters than were typed, the first one read may stand
for two ("&" for "Če") or some may be lost before it ("a" for the "a"
of "Šta"), so the line's start says little. Past it, the line and
the typed text still agree.

#### Implausibly small fitted size means width was shared over absent letters
`CotypingVisualCaretLocator.locate`: Smaller than text in a field usually is: the width was shared out
over letters that are not in it ("ao" for "Ćao", 7.8 pt). It is the
rest that is drawn there.

#### Captured caret is already after spaces; only frame lag moves it
`CotypingVisualCaretLocator.locate`: The app's caret was captured, read as a "|" or an "l": it is
where it is drawn, after any spaces typed. Adding those spaces
again put the ghost a space too far right in Viber. Only what
the frame predates moves it on: letters it lacks, or spaces when
the caret still touches the last letter.

#### Caret follows last letter's advance, slightly past its ink
`CotypingVisualCaretLocator.locate`: What the capture lacks is drawn after the line's last letter,
and the caret follows that letter's advance, a little past its
ink (0.6–0.8 pt at 13 pt, measured 2026-10-09).

#### Unseen letters near the wrap point may be on the next line
`CotypingVisualCaretLocator.locate`: Unseen letters close to where the line wraps may be on the next line.

#### Without caret glyph line must end exactly at typed end; plain reading wins ties
`CotypingVisualCaretLocator.alignment`: The best way the end of `line` matches the end of the typed text:
over how many typed characters the line lacks, and whether its last
character is the caret, read as a "|" or an "l". Without that caret
the line has to end exactly where the typed text does, since the
caret follows all of it; between equals, the plain reading wins.

#### Overlong recognized line holds other text beyond reading slack
`CotypingVisualCaretLocator.alignment`: A line longer than the paragraph holds other text too, past what
two characters read for one letter can explain.

#### Line ends before a space because spaces are not compared
`CotypingVisualCaretLocator.alignment`: Spaces are not compared, so a line ends before one, not after.

#### Caret from an older frame stays where drawn; later text follows it
`CotypingVisualCaretLocator.alignment`: A caret measured in a frame from before the last key is still
where it was drawn, and what it lacks follows it.

#### Measure advance after preceding last letter to include kerning
`CotypingVisualCaretLocator.advance`: How far `text` moves the caret when it follows `preceding`: measured
after the last letter of `preceding`, so the pair's kerning counts
("w." is a point narrower than "w" and "." apart).

#### Tie-break by lowest line, or longer piece on one row
`CotypingVisualCaretLocator.isBetter`: The better of two lines that both match the typed text: the closer
match; between equals, the lowest line, which is where a paragraph's
last line is drawn, or on one row (recognition can split a line into
pieces) the longer piece, whose width sizes the font better.

#### Tracked caret is nil when line break, wrap or word move possible
`CotypingVisualCaretLocator.caretX`: The caret's x for `precedingText`, moved along the line from where it
was found by the width of what was typed or deleted since. Nil when
that leaves the line, crosses a line break, strays too far, or may
have moved a word to another line: letters typed close to where the
line wraps, whose exact place is not known, or letters deleted from
the first word of a line that is not its paragraph's first.

#### Place caret from first-line start for new messages recognition misses
`CotypingVisualCaretLocator.caretXFromLineStart`: The caret's x for text that took the place of what the caret was found
after, such as the next message once one was sent: `calibration` knows
where the field's first line starts. Nil once the text would leave that
line. Recognition finds nothing in the first few letters of a message,
so without this each one began with no suggestion, or a popup.

#### Caret rect is one default system-font line on found baseline
`CotypingVisualCaretLocator.caretRect`: A caret rect the inline ghost places on the found baseline: one
default line of the system font at the fitted size, which the overlay
reads as AppKit text, baseline a fixed distance below the top.

#### Never capture secure fields or excluded apps and sites
`CotypingVisualCaretLocator.permitsCapture`: Whether the field may be captured: never a secure field, an app
excluded from screen capture or autocomplete, or, while any site is
excluded, a browser page whose address is unknown or excluded.

#### System font spacing varies with size, so iterate fit from line height
`CotypingVisualCaretLocator.fittedPointSize`: The system font size at which `text` is `width` wide. The system font
changes its spacing with size, so the width is compared near the size
found, starting from the line's `height`.

#### Reject fits where line height is far from font size
`CotypingVisualCaretLocator.fittedPointSize`: Recognized lines are about as tall as the font's size.

#### Windowed texts are aligned on the shorter one's end
`CotypingVisualCaretLocator.change`: What was typed after `old` to make `new`, or deleted from its end.
Both may be windows that keep only the newest text, so they are
aligned on the end of the shorter one when neither starts the other.

#### Normalize text so recognition's small liberties do not count
`CotypingVisualCaretLocator.normalized`: Lowercased, without accents, with typographic quotes and dashes plain
and whitespace runs as one space, so recognition's small liberties do
not count. Fast recognition often reads "š" as "s".

#### Recognition mixes Cyrillic and Latin lookalike letters within words
`CotypingVisualCaretLocator.latinLookalikes`: Cyrillic letters drawn like Latin ones, in either case. Recognition
mixes the two within a word ("рекаo", "Бophe" for "Ђорђе"), and what it
chose says nothing about which letter was typed.

#### Align typed text to line end; equal-length compare shifted on lost letters
`CotypingVisualCaretLocator.similarityToTheEnd`: `similarity` for a line whose reading may have lost a letter anywhere:
the typed text may start earlier than the line, and has to end where it
does. Comparing equal lengths from the end instead counted one lost letter
as every letter before it shifted, and taking the typed text as ending a
word later looked better (13 pt astray, measured 2026-11-02).

#### Unreadable typed letters cost nothing in similarity
`CotypingVisualCaretLocator.similarity`: 1 minus the edit distance per character. A typed letter recognition
cannot read costs nothing, whether it was read as something else or lost.

#### Capture is held in memory only; keep just caret position
`CotypingVisualCaret`: Keeps the caret found on screen for the focused field, and finds it again
when typing leaves the line it was found on. The capture is the field's
own frame, held in memory only while its text is recognized; nothing but
the caret's position is kept.

#### Keep last whole-line measurement for size and new messages
`CotypingVisualCaret.measured`: The last find for the field that measured a whole line. Its font size
outlasts finds that could not measure one, and it places a new message.

#### Leave very large fields alone since caret could be anywhere
`CotypingVisualCaret.maximumFieldSize`: Larger fields are left alone: the caret could be anywhere in them.

#### Ghost uses on-screen measured size when app gives no font
`CotypingVisualCaret.resolve`: Without a font from the app, the ghost uses the size measured on
screen, which is also what moves the caret along the line.

#### Caller checks privacy rules before a find
`CotypingVisualCaret.notePermission`: Records whether `field` may be captured, which the caller decides from
the privacy rules before asking for a find.

#### Estimated caret from line start is still measured
`CotypingVisualCaret.refreshIfNeeded`: Starts finding the caret on screen when `field` reports none and no
earlier find still follows it. A caret worked out from where the line
starts is only an estimate, so it is measured all the same. The caller
has checked the privacy rules.

#### Re-find after drift so font differences never accumulate
`CotypingVisualCaret.refreshIfDrifted`: Starts finding the caret again once typing has moved it a fair way
along its line from where it was found, so small differences between
the app's font and the measured one never add up. The caret found
earlier stays in use until the new one is in. Only for a field already
cleared for capture (`notePermission`).

#### One find at a time per field so one finishes
`CotypingVisualCaret.find`: One at a time per field: a find for text a little behind the typing
still places the caret, and restarting on each key could mean none
ever finished.

#### Findable fields hold a line, not a page, caret at line end, LTR
`CotypingVisualCaret.isFindable`: A field whose caret a find can place: a size that holds a line but
not a whole page, the caret at the end of its line, left-to-right.

#### Slow finds keep running and serve the next suggestion
`CotypingVisualCaret.waitForPending`: Waits for a find in progress, for at most `milliseconds`. A find that
takes longer keeps running and is kept for the next suggestion.

#### Key by app and role since Chrome returns new elements per read
`CotypingVisualCaret.key`: The app and kind of field. Not the element's identity: Chrome hands
out a new element on every read, which would find the caret again
for every suggestion. The field's frame and its text pin it instead.

#### Capture larger than point size to keep small text legible on 1x
`CotypingVisualCaret.recognizeLines`: The field's frame captured larger than its point size, which keeps
small text legible on a non-Retina display, with its lines recognized.

#### Run recognition on the queue, not detached, to avoid pool starvation
`CotypingVisualCaret.recognizeLines`: Not a detached task: recognition that never answered left each find
holding a Swift concurrency thread, until none was free (2026-11-09).

#### Find waits 5 s; lines take 5-60 ms; timeout is no miss
`CotypingVisualCaret.recognitionLimit`: How long a find waits for its lines; they take 5 to 60 ms. A find
without them places no caret and is not counted as a miss.

#### Ghost panel is never shared so absent from capture
`CotypingVisualCaret.capture`: The ghost panel is never shared, so it is not in the capture.

#### Set scalesToFit or 1x captures land in quarter of image
`CotypingVisualCaret.captureConfiguration`: The field's frame at `captureScale` times its point size. Without
`scalesToFit` a non-Retina display's pixels land unscaled in the
image's top-left quarter (measured 2026-10-05 on a 1x display), and
every recognized box comes out at half its size and place.

#### Capture at 3x on small non-Retina fields for fewer misreads
`CotypingVisualCaret.captureScale`: Pixels per point to capture at. A Retina display's own scale; on a
non-Retina one, three times the points for a field small enough:
recognition misread twice as many letters of rendered chat text at
two times (9 of 371 against 5, measured 2026-10-09; Viber's "je" as
"Je" throughout), in the same 6 ms per line.

#### Fast recognition gives character boxes; accurate gives only words and is slower
`CotypingVisualCaret.recognize`: Fast recognition gives character boxes within half a point; the
accurate one gives only word boxes and takes several times longer.

#### Use accurate recognition for Cyrillic; edges and caret from pixels
`CotypingVisualCaret.recognizeCyrillic`: Recognized lines for a field whose caret line is in Cyrillic. Accurate
recognition reads it where fast recognition reads none of it (20 to 60 ms
on a field's frame on an M4 Max, against 5), so that decides whether a
line is the typed one. It gives only word boxes, so the line's edges,
baseline and the app's caret come from its pixels.

#### Trust pixel-detected caret over its misread glyph
`CotypingVisualCaret.recognizeCyrillic`: What it read of the app's caret, the pixels say better. Only when
they show one: a last "г" can read as "/", and without it the
typed text looks a word longer than the line.

#### Task groups cannot bound a wait; only the wait ends
`CotypingBoundedWait`: Waits for a task to finish, for at most a deadline. A task group cannot do
this: leaving one waits for every child, and a child awaiting another task's
value is not stopped by cancellation, so the wait lasted as long as the
slowest find (a 150 ms budget waited for a 400 ms capture). The task is
never cancelled here; only the wait ends.

#### Resume once; cancellation may precede waiter installation
`CotypingBoundedWait.FirstSignal`: Resumes the waiter once, for whichever of the task, the deadline or
the waiter's cancellation comes first. A cancellation can arrive
before the waiter is installed.

### `LokalBot/Cotyping/CotypingVisualCaretInk.swift`

#### Measure line edges from pixels because recognition boxes are unreliable
`CotypingVisualCaretInk`: Measures a recognized line from the image's own pixels. The recognition that
reads Cyrillic gives only word boxes, which ran up to 6 pt past the text, and
the one with character boxes cannot read it and lost whole words from either
end (16 pt, measured 2026-11-02). A field's text sits on a flat background,
so its ink says where the text starts and ends, whatever the letters are.

#### Thin letters mimic the caret; only descent distinguishes it
`CotypingVisualCaretInk.caretLikeLetters`: Letters as thin and straight as a caret: at the end of the line, only
reaching below the baseline tells the caret from one of them.

#### Carets are 1-2 pt; 3.5 pt limit allows 1x upscale blur
`CotypingVisualCaretInk.widestCaret`: Wider than this is not a caret, in points. Carets seen are 1 to 2 pt, and
a capture scaled up from a 1x display blurs them by half a point a side.

#### Caret reaches at least 1.2 pt below baseline
`CotypingVisualCaretInk.caretDescent`: How far below the baseline a caret reaches at least, in points.

#### Ignore image-edge pixels as possible field border
`CotypingVisualCaretInk.edgeMargin`: Pixels at the edge of the image are the field's border, if it has one.

#### Gap over 0.3 capital height separates words
`CotypingVisualCaretInk.wordGap`: A gap wider than this share of the capitals' height is between words. At
14 pt, letters leave up to 2 pt and a space 4 pt or more.

#### Measure ink only on flat backgrounds, normalized y-up boxes
`CotypingVisualCaretInk.measure`: The ink of the line recognition boxed as `line`. Boxes are normalized,
with y up, as recognition gives them. Nil when the line is not on a flat
background, so that its ink cannot be told from what is behind it.

#### Scan below box too since caret reaches lower than boxes
`CotypingVisualCaretInk.measure`: Below the box too, where a caret reaches: boxes follow the letters.

#### Scan past last word as far as caret after typed spaces
`CotypingVisualCaretInk.measure`: Past the last word, as far as a caret after a few typed spaces.

#### Ink past word box is not text but may be caret
`CotypingVisualCaretInk.measure`: Ink past the word's box is not its text. It can still be the caret.

#### Text ends before caret, or on same run if touching
`CotypingVisualCaretInk.measure`: The text ends before the caret, on the same run when it touches the last letter.

#### Text covers under half its line; more means a picture
`CotypingVisualCaretInk.Band.init`: Text covers well under half of its line; more than that is a picture.

#### Ink threshold well below full contrast; 1x thin strokes not solid
`CotypingVisualCaretInk.Band.init`: Well below full contrast: at 1x a thin stroke is never drawn solid.

#### Baseline is where ink falls off most below midline
`CotypingVisualCaretInk.Band.baselineRow`: Most letters end on the baseline, so ink falls off most just below it.

#### Caret is thin straight bar capital-tall reaching below baseline
`CotypingVisualCaretInk.Band.isCaretShaped`: A run on its own that looks like the app's caret: a thin, straight bar
as tall as the capitals. It reaches below the baseline as a letter that
shape does not, unless it could not be one of the letters typed.

#### Require dense ink to tell caret from brackets and slashes
`CotypingVisualCaretInk.Band.isCaretShaped`: Most of its box is ink, unlike a bracket or a slash, which reach as far.

#### Detect touching caret by full-height ink columns on run's right edge
`CotypingVisualCaretInk.Band.caretOnTheEnd`: The app's caret touching the last letter, so one run with it: columns
on the run's right edge with ink all the way from the top of the
capitals to below the baseline. No letter ends that way on its right,
and of what else is typed only "]" does.

### `LokalBot/Cotyping/CotypingWindowText.swift`

#### OCR focused window pixels where Accessibility exposes little
`CotypingWindowText`: Text read from the focused window's pixels for the "Use the focused window
as context" grant. Accessibility exposes little of what browsers, Electron
and Qt apps show; on-device text recognition sees every line. This is the
pure half: which recognized lines enter the prompt, in what order, and when
a newer read replaces the one in use. `CotypingWindowTextCapture` reads.

#### Lines use AX global coordinates, origin top-left
`CotypingWindowText.Line`: One recognized line in AX global coordinates (origin at the top left).

#### Cap window text at 2000 characters, about 500-700 tokens
`CotypingWindowText.maximumCharacters`: About 500–700 prompt tokens: a typical chat or mail pane whole. The
model reads it once when the window changes and reuses it while typing.

#### Lines near the field are its border, label or placeholder
`CotypingWindowText.fieldMargin`: Lines this close to the field are its border, label or placeholder.

#### Message bubbles sit slightly off the field's edges
`CotypingWindowText.columnSlack`: Message bubbles sit a little inside or outside the field's edges.

#### Scrolled-out text stays in use for at most 60 s
`CotypingWindowText.maximumHeldAge`: How long text that scrolled out of view may stay in use.

#### Short new text must not replace text in use and force reread
`CotypingWindowText.minimumAddedCharacters`: New text shorter than this (a timestamp, a typing indicator) does not
replace the text in use, which would make the model read it all again.

#### Fingerprint window excluding field so rereads reuse recognized lines
`CotypingWindowText.fingerprint`: Identifies what text recognition would read from a window image apart
from the field being typed in (its draft and blinking caret), whose
lines a prompt never uses. Equal fingerprints let a reread reuse the
last lines instead of recognizing the same window again (150–250 ms).
The frames are part of it because they place the lines.

#### Downscale to 512 px wide; changed words still change pixels
`CotypingWindowText.fingerprint`: Area-averaged to 512 pixels wide, a changed word still changes pixels.

#### Rows stored top first to match global frame coordinates
`CotypingWindowText.fingerprint`: Rows are stored top first, like the global coordinates of both frames.

#### Order lines nearest field first; draft excluded; conversation ends at draft
`CotypingWindowText.excerpts`: The lines a prompt gets, in reading order. The draft itself never
enters: it is already the text before the caret. Lines in the field's
column above it come first, nearest the field first, so a long
conversation keeps its newest messages; the rest of the window (titles,
sidebars, panes beside or below the field) fills what is left and is
placed before them, so the conversation ends right where the draft begins.

#### Stop at first line that does not fit to avoid holes
`CotypingWindowText.excerpts`: Stop at the first line that does not fit, so the kept part has no holes.

#### Keep unchanged or scrolled text so prompt reading survives typing
`CotypingWindowText.shouldReplace`: Whether a newer read should replace the window text in use. Rereading
an unchanged window changes nothing, and lines that only scrolled out
of view stay for a while, so the model's reading of the prompt survives
typing; new text (a reply arriving) replaces it at once.

#### Match window by process and frame, title as tiebreak, else nil
`CotypingWindowText.windowIndex`: The window a capture reads: the focused one's process and frame, and
its title when the frame alone is ambiguous. Nil rather than a guess.

#### Vision boxes are normalized bottom-left; convert to AX coordinates
`CotypingWindowText.frame`: A Vision bounding box (normalized, origin at the bottom left) in the
AX coordinates of the window the image shows.

#### Key excludes field height and position; title change means new document
`CotypingWindowText.key`: Identifies one field's window between reads. Field height and position
are left out because a reply box grows as you type; a different title
is another document, tab or conversation, whose text is not reused.

#### Key match without title may be another document; next read settles
`CotypingWindowText.key`: Whether `key` can be for a field at this place: the same process,
role and column. The window title takes another Accessibility read,
so a match may still be another document; the next read settles that.

#### Drop credential lines instead of teaching model to complete redactions
`CotypingWindowText.cleaned`: Drops credential-bearing lines rather than teaching the model to
complete a redaction marker, and lines with no letters or digits.

#### Bottom-most line above field is the newest message
`CotypingWindowText.nearestFirst`: Bottom-most first: the line just above the field is the newest message.

### `LokalBot/Cotyping/CotypingWindowTextCapture.swift`

#### Window reads stay off keystroke path; image dropped, text held per field
`CotypingWindowTextCapture`: Captures the focused window and reads its text on device for
`CotypingWindowText`. Never on the keystroke path: the first request in a
field starts a read and goes without it; later requests use the result,
which is reread in the background every few seconds while the field keeps
focus. A reread with new text waits for a pause in typing before it is
used, because the text starts the prompt and changing it makes the model
read the whole prompt again. One read runs at a time. The image is dropped
as soon as it is read, and the text is held for the focused field only.

#### Window read costs 150-250 ms background work
`CotypingWindowTextCapture.refreshInterval`: A read costs about 150–250 ms of background work on a full window.

#### Adopt new text after 1 s pause; mid-typing reread costs 268 vs 41 ms
`CotypingWindowTextCapture.typingPause`: New text from a reread is used once typing has stopped this long. Used
mid-typing, it made the next keystroke reread a ~500-token prompt:
268 ms instead of 41 (measured 2026-10-16).

#### Notify after text change so model prefills before next keystroke
`CotypingWindowTextCapture.setUpdateHandler`: Called after a read changes the text in use, so the model can read the
new prompt before the next keystroke needs it.

#### Reads start in background; request closure never runs on keystroke
`CotypingWindowTextCapture.snapshot`: The window text for `key`, or nil until the first read finishes. A
missing or old read starts one in the background; `request` runs there
too, never on the keystroke, and returning nil (not permitted, no
window) skips the read.

#### Count refresh from read start so failures are not retried per keystroke
`CotypingWindowTextCapture.snapshot`: Counted from the start, so a read that fails is not retried per keystroke.

#### Runs by itself after pause; tests call it to step clock
`CotypingWindowTextCapture.adoptPendingIfQuiet`: Uses the held text if typing has paused long enough. Runs on its own
once the pause comes; tests call it to step the clock.

#### In-flight read cannot put its result back after forget
`CotypingWindowTextCapture.removeAll`: Forgets the text in use. A read already running cannot put its result back.

#### Forget old window text on focus change without typing
`CotypingWindowTextCapture.forget`: Forgets the text in use unless it can be for the field that now has
focus. Asking for a read is what forgets another field's text, and
focus that moves on without typing never asks, so the window just
left stayed in memory.

#### Filter lines outside the lock a keystroke takes
`CotypingWindowTextCapture.finish`: Filtering runs a few expressions per line; keep it outside the lock
that a keystroke takes.

#### Log counts only; window text never reaches the log
`CotypingWindowTextCapture.log`: One debug-log line per change of outcome, with counts only: window
text never reaches the log.

#### Read waits 10 s; 99.9% of reads finish under 5 s
`CotypingWindowTextCapture.recognitionLimit`: How long a read waits for its lines. Of 22,000 reads in one Mac's log,
99.9% took under 5 s with the capture included.

#### Cache recognized lines outside field, cleared with text in use
`CotypingWindowTextCapture.RecognizedLines`: The last lines recognized for the field in use, outside the field, with
the fingerprint of the image they came from. Held and cleared with the
text in use, so it keeps no text the field's prompt could not.

#### Capture only focused window; never ask for Screen Recording
`CotypingWindowTextCapture.read`: Captures only the focused window, while its app is still in front.
Never asks for Screen Recording: without it there is no window text.

#### Draft lines are never kept as prompt context
`CotypingWindowTextCapture.read`: The draft is never prompt context, so it is not kept either.

#### Use accurate recognizer; fast drops accents and Cyrillic, en-US misses CJK
`CotypingWindowTextCapture.recognize`: The same recognizer as screen memory and Compose: `.fast` drops every
accent and all Cyrillic, and the en-US default cannot read CJK.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
