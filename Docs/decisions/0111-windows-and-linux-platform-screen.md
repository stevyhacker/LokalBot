# 0111. Windows and Linux: platform — screen

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-platform/src/screen/`.

## Decisions

### `LinuxWindows/crates/lokalbot-platform/src/screen/atspi.rs`

#### AT-SPI reader never changes accessibility settings, so Chromium and Qt often report nothing
Linux: visible text and secure-field state through AT-SPI, the counterpart
of `ScreenAccessibilityReader.resolve`.

The reader asks the session bus where the accessibility bus is
(`org.a11y.Bus.GetAddress`), finds the app that owns the focused window by
its process and walks that window breadth-first. It never changes
accessibility settings (`org.a11y.Status`), so apps that build their tree
only for a running screen reader (Chromium, Qt) usually report nothing.

#### Each AT-SPI call times out so a wedged app costs one timeout
`CALL_TIMEOUT`: Each call gives up after this long, so a wedged app costs one timeout.

#### Whole text read only from small fully visible elements without computable range
`MAX_WHOLE_TEXT`: Whole text is read only from small, fully visible elements whose visible
range cannot be computed.

#### Visible range capped at 24000 characters, as ScreenAccessibilityReader.visibleText
`MAX_RANGE`: `ScreenAccessibilityReader.visibleText` caps a visible range.

#### Role values come from at-spi2-core atspi-constants.h version 2.52
`role`: `AtspiRole` values from at-spi2-core's `atspi-constants.h` (2.52).

#### State bits come from atspi-constants.h; GetState returns two 32-bit words
`state`: `AtspiStateType` bits from `atspi-constants.h`; `GetState` returns them as
two 32-bit words.

#### Text views have visible range read; password fields never read
`is_text_view`: Text views and fields whose visible character range is read
(`kAXVisibleCharacterRangeAttribute`). Password fields are never read.

#### Labels and controls showing their name are read only when fully visible
`is_label`: Labels and controls that show their name, read only when fully visible
(`ScreenVisibleTextPolicy` labels).

#### Only an input can hold a secret, as ScreenAccessibilityReader.isTextEntry
`is_text_entry`: `ScreenAccessibilityReader.isTextEntry`: only an input can hold a secret.

#### Containers that clip descendants, mirroring clipsChildren
`clips_children`: Containers that clip their descendants (`clipsChildren`).

#### Secret-named labels are treated as secure; only text entries mark window secure
`is_secure`: `CotypingSecureFieldDetector.isSecure`: a password field, or an element
whose name or description names a secret. Labels such as "Password" match
too, which keeps their text out; only text entries make the window count
as showing a secure field.

#### Whether Text.GetOffsetAtPoint is worth asking depends on toolkit
`Toolkit.offsets`: Whether `Text.GetOffsetAtPoint` is worth asking.

#### GtkEntry without visibility still reports text, so no entry is known non-password
`Toolkit.reveals_hidden_entries`: Entries that hide their text (a `GtkEntry` without visibility) still
report it in full and as plain text, so no entry is known not to be a
password field.

#### GTK 4 read in window coordinates; offset support and hidden-entry text depend on version
`toolkit_for`: GTK 4 places every element at the origin in screen coordinates, never
answers `GetOffsetAtPoint` before 4.16 and returns hidden entry text
before 4.20; Chromium answers `GetOffsetAtPoint` only in screen
coordinates. So GTK 4 is read in window coordinates, the rest in screen
coordinates.

#### Any secure focused element makes focus secure, any unknown makes it unknown
`combined_focus`: The focus state of the focused elements: any secure one makes it secure,
any unknown one unknown.

#### GTK G_MININT coordinates and -1 sizes mean not shown
`rect`: Extents as a rectangle, when they describe one: GTK reports `G_MININT`
coordinates for widgets that are not shown, applications report -1 sizes.

#### Clipping containers narrow viewport; unknown extents leave nothing visible below
`child_viewport`: The part of the window a container's children can show: clipping
containers narrow it to their own extents (`clipsChildren`). Unknown
extents leave nothing visible below them.

#### Toolkits answer -1 where no character exists; a single answer is no range
`visible_range`: The characters between the offsets found at the corners of the visible
rectangle. Toolkits answer -1 where there is no character (GTK past the
end of a line, Chromium in padding); a single answer is no range.

#### Embedded objects appear as U+FFFC and are read as children instead
`without_objects`: Text from the Text interface: embedded objects (links, images, frames)
appear as U+FFFC and are read as children instead.

#### Failed means element is gone or lacks the interface
`CallError::Failed`: The element is gone or does not support the call.

#### Failed only means the element lacks what was asked, not a read error
`optional`: A failure that only means the element lacks what was asked.

#### Containers managing descendants build children on demand, so only first ones are asked
`Node::children`: Children to visit, at most `MAX_CHILDREN`. Containers that manage
their descendants (large tables) build children on demand, so only
the first ones are asked for.

#### Viewport is the part of the window the element can show; None means unknown
`Pending.viewport`: The part of the window this element can show, `None` when unknown.

#### Parent text via Text interface already holds static-text children (Chromium)
`Pending.parent_text`: The parent's text was read through the Text interface, which already
holds the text of its static-text children (Chromium).

#### Web document addresses are kept in walk order, outermost first
`Walk.web_urls`: Web documents' addresses in walk order, outermost first.

#### Focused elements record secure state; None when it cannot be known
`Walk.focused`: Elements with keyboard focus, and whether each is secure (`None` when
that cannot be known).

#### The window root is its own viewport and always entered
`Walk::visit`: Reads one element and returns its children. The window itself (`root`)
is its own viewport and is always entered.

#### Nothing below an element outside the visible window can show text
`Walk::visit`: Nothing below an element outside the visible part of the window
can show text.

#### Text is read only from elements known not to be secure
`Walk::visit`: `secureFieldStatus`: text is read only from elements known not to
be secure.

#### Possibly-hidden-password entry counts as secure; unknown focus blocks capture
`Walk::visit`: An entry that may be hiding a password counts as one: with the
focus unknown, such a window is not captured (`focusPermitsCapture`).

#### Menu items are not walked to save node budget on hidden entries
`Walk::visit`: A menu's items open in a popup of their own; walking them would
spend the node budget on hidden entries (LibreOffice has hundreds).

#### Web documents give page address and frames; local file gives document name
`Walk::document`: Web documents give the page address and frames; a document's local
file gives the document name.

#### Reads corner range else whole text of small visible element; whole values can hide documents
`Walk::visible_text`: `ScreenAccessibilityReader.visibleText`: the characters between the
corners of the element's visible part, else the whole text of a small
element that is fully visible. Whole values can hold hidden documents.

#### An app that never answers offset queries is not asked again
`Walk::visible_text`: An app that never answers is not asked again.

#### Fully visible labels with empty name give text, as Chromium list items and cells
`Walk::whole_text`: The text of a fully visible label whose name is empty (Chromium list
items and table cells).

#### Focus becomes unknown once a previously focused element lost focus
`Walk::focus_now`: The focus state now: unknown once an element the walk saw focused has
lost focus.

#### Unique bus names are never reused, so cached pid stays right until app leaves
`AtspiReader.pids`: The process of each app on the accessibility bus. Unique bus names
are never reused, so an entry stays right until its app leaves.

#### Accessibility bus connects on first use and reconnects after errors
`AtspiReader::bus`: The accessibility bus, connected on first use and again after errors.

#### Front window is the ACTIVE one, else the only one titled like focus; GTK 4 marks none active
`AtspiReader::find_window`: The top-level window that is in front: the one with the ACTIVE state,
else the only one titled like the focused window (GTK 4 marks no
window active).

#### Calls race the app, so never attach one window's text to another window or focus
`AtspiReader::read_window`: Calls race the app: never attach one window's text to another
window or to a different focus (`resolve`'s final checks).

#### Ask GetAddress only while launcher is running; unowned name would start it
`accessibility_bus_address`: `org.a11y.Bus.GetAddress`, asked only while the bus launcher runs: asking
an unowned name would start it.

#### LokalBot never records its own windows
`AtspiReader::read`: LokalBot never records its own windows.

#### Per-window budget 750 ms keeps pathological pages from costing the Meet document
`CALL_WINDOW_BUDGET`: A pathological background page must not cost the Meet document its budget.
macOS gives a window 250 ms, but fetches a node's attributes at once where
AT-SPI asks one question per call.

#### Meet detection never turns accessibility on; without a tree the title decides
`BrowserCallReader`: Meet documents in browsers' windows, for meeting detection
(`BrowserMeetingSession.window`). This never turns accessibility on; a
browser with no tree answers nothing and the window title decides.

#### An incomplete read of a window says nothing about it
`BrowserCallReader::read`: Reads the windows of `families`' apps. `family_of` names a process's
browser. An incomplete read of a window says nothing about it.

#### Returns None when the window could not be read completely
`walk_call_window`: The Meet documents of one window with their labels, or `None` when the
window couldn't be read completely.

#### Depth-first reading order; flag marks nodes inside a Meet document
`walk_call_window`: Depth first, in reading order. The bool says a Meet document holds it.

#### Post-call actions may be links rather than buttons
`walk_call_window`: Post-call actions may be links rather than buttons.

#### DocURL is read first (Firefox, WebKitGTK), else URI (Chromium)
`document_url`: `DocURL` (Firefox, WebKitGTK), else `URI` (Chromium).

#### Fixture is the state words of a focused read-only GTK 4 text view
`state_bits_span_both_words`: GTK 4's focused, read-only text view: [1124210688, 3072].

#### Row cut by the pane is not fully visible, so its label is excluded
`clipping_containers_narrow_the_viewport`: A row cut by the pane is not fully visible, so its label stays out.

#### Fixture is a scrolled GTK 3 text view showing lines 1 to 8
`visible_ranges_come_from_the_corners`: A scrolled GTK 3 text view: lines 1 to 8 of 200.

#### GTK 3 entries and labels answer -1 right of text, giving no range
`visible_ranges_come_from_the_corners`: A GTK 3 entry or label answers -1 right of its text: no range.

#### Fixture is a Chromium static text with every corner on a glyph
`visible_ranges_come_from_the_corners`: A Chromium static text, every corner on a glyph.

#### Ignored manual test; run with LOKALBOT_ATSPI_EXPECT or LOKALBOT_ATSPI_SECRET
`reads_the_window_in_front`: Reads the window in front of a desktop session, for example a GTK
window with known text, or a password dialog with a typed password:

```text
LOKALBOT_ATSPI_EXPECT="Visible label alpha" \
  cargo test -p lokalbot-platform atspi -- --ignored --nocapture
LOKALBOT_ATSPI_SECRET="hunter2" \
  cargo test -p lokalbot-platform atspi -- --ignored --nocapture
```

#### Typed password must never appear in text; window shows secure field or unknown focus
`reads_the_window_in_front`: A password typed into the window: never in the text, and the window
shows a secure field or its focus is not known to be plain.

### `LinuxWindows/crates/lokalbot-platform/src/screen/events.rs`

#### Idle timer replaces Mac click/key/scroll monitor; no key, pointer or clipboard content read
Interaction boundaries as capture hints (`ScreenContextEventMonitor`).

The Mac app watches clicks, key presses and scrolls through a global
event monitor and reports when they settle. Here the idle timer stands in
for all three: input that stops for a moment is one "typing pause"
boundary. A clipboard change is noticed from its sequence number (Windows)
or a selection-owner event (X11). No key, pointer position, event type or
clipboard content is ever read.

#### Input within one second counts as ongoing
`ACTIVE_SECONDS`: Input this recent counts as ongoing.

#### Input is settled after 0.8 s idle, matching the Mac
`SETTLED_SECONDS`: Input settled once it has been idle this long (the Mac waits 0.8 s after
the last key).

#### Capture worker polls it about once a second
`InteractionMonitor`: Polled about once a second by the capture worker.

#### Sequence number returns 0 when the station has no clipboard access
`ClipboardWatch::current`: SAFETY: no arguments; returns 0 when the station has no clipboard access.

#### XFixes reports new CLIPBOARD owners; events drained without reading the selection
`ClipboardWatch (X11)`: X11: XFixes reports every new owner of the CLIPBOARD selection; the
events are drained without reading the selection itself.

### `LinuxWindows/crates/lokalbot-platform/src/screen/linux.rs`

#### Locked means logind LockedHint or an active screen saver
`session_locked`: The lock screen is up: logind's `LockedHint` for this session, or an
active screen saver.

#### Asking an unowned name could start a screen saver service
`screensaver_active`: Asking an unowned name could start a screen saver service.

### `LinuxWindows/crates/lokalbot-platform/src/screen/mod.rs`

#### Only the focused window is ever captured; backends differ per platform
Screen context: the focused window's pixels and its visible text, the
Linux and Windows counterparts of ScreenCaptureKit and the Accessibility
reader in `ScreenshotService.swift` and `ScreenAccessibilityReader.swift`.

- [`window_capture`] reads the pixels of the window in front: X11
  `GetImage`, `grim` on wlroots compositors, the xdg-desktop-portal
  Screenshot API elsewhere on Wayland (cropped to the focused window when
  the compositor reports where it is), and GDI on Windows.
- [`text_reader`] reads the window's visible text and secure-field state
  through accessibility: AT-SPI on Linux, UI Automation on Windows.
- [`InteractionMonitor`] turns idle-time and clipboard changes into capture
  hints without reading keys, pointer positions or clipboard contents.
- [`privacy`] holds the rules that decide whether a window may be kept.

Only the focused window is ever captured, never the whole display or a
window behind it. The engine decides when to capture and what to keep.

#### Pixels are RGBA, 8 bits per channel, rows top to bottom
`CapturedImage`: RGBA pixels, 8 bits per channel, rows top to bottom.

#### Box-filter downscale so neither side exceeds max, as ScreenshotCaptureDimensions.bounded
`CapturedImage::bounded`: The image scaled down (box filter) so neither side exceeds `max`,
keeping its aspect ratio (`ScreenshotCaptureDimensions.bounded`).

#### Uniform color means a blank or black frame
`CapturedImage::is_uniform`: True when every pixel has the same color (a blank or black frame).

#### Longest side at most max, as ScreenshotCaptureDimensions.bounded
`bounded_dimensions`: `ScreenshotCaptureDimensions.bounded`: the longest side at most `max`.

#### Window rectangles are in physical screen pixels
`WindowRect`: Where a window is, in physical screen pixels.

#### Window id is only meaningful to the backend that produced it
`FocusedWindow`: The window in front as the capture backend sees it. `id` is the X11
window, the `HWND`, or the compositor's window id; it only has meaning to
the backend that produced it.

#### Calls are time-bounded; only the Wayland portal may prompt once
`WindowCapture`: Reads the pixels of the focused window. Calls are bounded by short
timeouts; none of them prompts the user except the Wayland portal, which
may ask once whether LokalBot may take screenshots.

#### Limitation text is worded for Settings, or None
`WindowCapture::limitation`: What this desktop cannot capture, worded for Settings, or `None`.

#### None means desktop, lock screen or no session
`WindowCapture::focused`: The window in front now, or `None` (the desktop, a lock screen, no session).

#### Capture must fail rather than return another window or the whole display
`WindowCapture::capture`: The pixels of `window`, which must still be in front. Fails rather
than return any other window or the whole display.

#### Backend names for logs: x11, grim, portal, gdi, unavailable
`WindowCapture::name`: Short name for logs: `x11`, `grim`, `portal`, `gdi`, `unavailable`.

#### Text is visible text only: visible ranges and fully visible labels
`AccessibleWindow`: What accessibility reports about the focused window
(`ScreenAccessibilitySnapshot`). Text is visible text only: visible
character ranges of text views and labels that are fully on screen.

#### One element per line, at most about 24000 characters
`AccessibleWindow.text`: Visible text, one element per line, at most about 24 000 characters.

#### Page address is the outermost web document of a browser window
`AccessibleWindow.source_url`: The page address of a browser window (its outermost web document).

#### File name of the open document when the app reports one
`AccessibleWindow.document_name`: File name of the open document, when the app reports one.

#### None means focused element's password status is unknown
`AccessibleWindow.focused_secure_field`: Whether the focused element is a password field; `None` when unknown.

#### Other sites' pages framed in the window are kept sanitized
`AccessibleWindow.framed_urls`: Other sites' pages framed inside the window, sanitized.

#### Set when some web content's address could not be read
`AccessibleWindow.has_unattributed_web_content`: Some web content's address could not be read.

#### Unavailable capture proceeds with OCR and unknown focus
`TextRead::Unavailable`: Accessibility is off, the app exposes nothing, or the window could
not be matched. The capture proceeds with OCR and unknown focus.

#### Window, title or focus changed during read; retrying shortly may succeed
`TextRead::Changed`: The window, its title or its focus changed while it was read (a tab
switch, a page load); reading again a moment later can succeed.

#### LokalBot's own windows are never read
`TextReader`: Reads the focused window through accessibility. LokalBot's own windows
are never read.

#### With include_text false only privacy metadata is read
`TextReader::read`: Reads `window` within `deadline`. With `include_text` false only the
privacy metadata (title, address, secure fields) is read.

#### Reader names for logs: uia, atspi, unavailable
`TextReader::name`: Short name for logs: `uia`, `atspi`, `unavailable`.

#### Captures pause while the session is locked
`session_locked`: Whether the session is locked (the lock screen is up), when the system
can tell. Captures pause while it is.

#### Text appending strips NULs, trims, caps 8000 chars per element, dedupes, caps total
`append_text`: Appends a visible string the way `ScreenAccessibilityReader.append` does:
NULs removed, trimmed, at most 8 000 characters per element, each string
once, and no more than `max_chars` in total. Returns false once full.

#### Bounds shared by readers mirror ScreenAccessibilityReader.resolve
`MAX_NODES`: Bounds shared by the accessibility readers (`ScreenAccessibilityReader.resolve`).

### `LinuxWindows/crates/lokalbot-platform/src/screen/privacy.rs`

#### Window keep rules mirror Swift; app, site and redaction rules shared with activity tracking
Which windows screen context may keep (`ScreenContextPrivacy.permitsContent`,
`ScreenAccessibilityReader.pageAddress`/`settledFocus`). App and site rules,
password managers and redaction are shared with activity tracking in
[`crate::privacy`].

#### Facts about focused window used to decide keeping, mirroring Swift Observation
`Observation`: What is known about the focused window when deciding whether to keep it
(`ScreenContextPrivacy.Observation`).

#### App id is executable or desktop id for app rules and browser check
`Observation.app_id`: Executable or desktop id, for app rules and the browser check.

#### None means the focused element is unknown
`Observation.focused_secure_field`: `None` when the focused element is unknown.

#### Marker list mirrors CotypingSecureFieldDetector.sensitiveMarkers
`SENSITIVE_MARKERS`: `CotypingSecureFieldDetector.sensitiveMarkers`.

#### Elements named after a secret are secure fields and never read
`names_a_secret`: Whether an element's name, description or help text names a secret
(`CotypingSecureFieldDetector.isSecure`): such an element is treated as
a secure field and its text is never read.

#### Apps never reporting focus (Chrome) captured only while no password field visible
`focus_permits_capture`: Whether the focus state allows a capture. Apps that never report keyboard
focus (Chrome) are captured only while no password field is visible.

#### Unknown focus allowed only for screen capture; focused-field consumers need known plain focus
`permits_content`: Whether the window's text and pixels may be kept. `allows_unknown_focus`
is for screen capture only; consumers that act on the focused field
require a known, non-secure focus.

#### Excluded site anywhere, even framed, keeps the whole window out
`permits_content`: Framed pages are captured with the window, so an excluded site keeps
the whole window out wherever it appears.

#### Browser with unreadable address cannot be shown outside site exclusion
`permits_content`: A browser whose address (or a framed page's) cannot be read cannot be
shown to be outside a configured site exclusion.

#### Unknown focus turning plain keeps the read; other changes discard it
`settled_focus`: The focus state across one read (`ScreenAccessibilityReader.settledFocus`).
An unknown focus that turns out to be a plain field keeps the read; any
other change discards it. Returns whether the read stands and its focus.

#### 80 visible characters is enough that OCR adds little
`has_rich_accessible_text`: At least 80 visible characters: enough that OCR adds little
(`ScreenContextPrivacy.hasRichAccessibleText`).

#### Only a file name is kept, never its folder; web addresses are not names
`sanitized_document_name`: The file name of a document, never its folder; web addresses are not
document names (`ScreenContextPrivacy.sanitizedDocumentName`).

#### Page address plus framed pages, mirroring ScreenAccessibilityReader.PageAddress
`PageAddress`: A window's page address and the other pages framed in it
(`ScreenAccessibilityReader.PageAddress`).

#### Window document else outermost web area is the page; others kept for site rules
`page_address`: Browsers expose every frame as its own web document: the page,
`about:blank` editors and other sites' embeds. The window's document,
else the outermost web area, is the page; other addresses are kept for
site rules. `web_area_urls` lists web areas outermost first.

#### about: pages take embedder's origin and data: holds embedder content, so skipped
`page_address`: about:blank/about:srcdoc take their embedder's origin; data: holds
content the embedder supplied.

#### A blob: address carries the origin that created it
`page_address`: A blob: address carries the origin that created it.

### `LinuxWindows/crates/lokalbot-platform/src/screen/uia.rs`

#### UIA reader walks breadth-first with cached properties, reads visible text only, drops secure lines
Windows: visible text and secure-field state through UI Automation, the
counterpart of `ScreenAccessibilityReader.resolve`. The window is walked
breadth-first through the control view, and every element arrives with
the properties in [`CACHED_PROPERTIES`] in the same cross-process call.
Text is visible text only (`ScreenVisibleTextPolicy`): the visible ranges
of text controls and the names of labels that lie fully inside their
viewport. Secure fields are never read, and the lines of a page that
overlap one are dropped.

#### UIA waits 20 s by default; 500 ms bounds a hung app
`CALL_TIMEOUT_MS`: How long one call may wait on the target app (UIA waits 20 s by
default), so a hung app holds a read for about this long.

#### UIA would answer from LokalBot's own UI thread, which may be waiting; own windows skipped
`UiaReader::read`: UI Automation would answer from LokalBot's own UI thread, which may
be waiting on this one; its windows are never recorded anyway.

#### Client lives in the MTA, which stays up while it exists
`Client`: The UI Automation client, kept between reads. It lives in the MTA, which
stays up while the client exists even when no thread is inside it.

#### MTA usage is returned on drop after the client is released
`Client::create`: SAFETY: COM bookkeeping and an in-process object; the MTA usage is
returned when `MtaUsage` drops, after the client is released.

#### Cookie is an opaque token CoDecrementMTAUsage accepts from any thread
`MtaUsage`: SAFETY: the cookie is an opaque token that CoDecrementMTAUsage accepts
from any thread.

#### A thread already in another apartment keeps it; agile client works there
`ComScope`: Balances `CoInitializeEx` on this thread. A thread already in another
apartment keeps it; the agile client works there too.

#### Walk leaves a quarter of the deadline for checks; Mac walks 140 of 180 ms
`read_window`: The walk leaves a quarter of the deadline for the checks below (the
Mac walks for 140 of its 180 ms).

#### UIA answers asynchronously, so never attach text to a different window, title or focus
`read_window`: UI Automation answers asynchronously to the app. Never attach one
window's text to a different window, title or focus.
SAFETY: no arguments; returns a possibly null handle.

#### UIA refuses requests while another thread is setting it up, so retry briefly
`cache_request`: UI Automation refuses requests for a moment while another thread of the
process is still setting it up, so this tries for a few milliseconds.

#### Raw view filter so every handed element gets its properties
`new_cache_request`: Every element we are handed gets its properties, whatever its view.

#### Focus secure state is known only for the window's own process
`focus_state`: Whether the focused element is secure, when it belongs to the window's
process; `None` when that is unknown.

#### Web document addresses in walk order, outermost first
`Findings.web_area_urls`: Web documents' addresses in walk order, outermost first.

#### Page ranges hold input values, so lines stay removable until secure fields are known
`RangeSource`: The lines read from one element's visible ranges. A page's ranges hold
the values of its inputs, so the lines stay removable until the walk
knows which secure fields show inside it.

#### Each line records its index in Text parts and its range
`RangeSource.lines`: Each line kept in [`Text::parts`]: its index there and its range.

#### Secure non-password entries show bullets but their values may be in lines
`RangeSource.secure_fields`: Secure text entries inside the element that are not password fields
(those show bullets), whose values may be in the lines.

#### Ancestor whose visible ranges already hold this element's text, as sources index
`Pending.covered`: The ancestor whose visible ranges already hold this element's text,
as an index into [`Findings::sources`].

#### A link's address is not the page origin; only a document's own value is
`walk`: A link's address is not the page's origin; only a document's
own value (its URL in Chromium and Gecko) establishes it.

#### Children beyond MAX_NODES are never visited, so not fetched
`walk`: Children past MAX_NODES would never be visited; do not fetch them.

#### Lines overlapping a secure field are removed; Mac never reads such fields, ranges hold values
`remove_secure_lines`: Removes the lines that overlap a secure field: the Mac never reads such
a field, but a page's ranges hold its value. The field's own text is not
read; lines whose place cannot be compared go too.

#### Range comparisons return no text
`remove_secure_lines`: SAFETY: COM calls on interfaces the walk holds; they compare
range ends and return no text.

#### IsPassword is None when the provider did not say
`Node.password`: `IsPassword`; `None` when the provider did not say.

#### Secure means password field or field named after a secret
`Node.secure`: A password field or a field named after a secret ([`secure_status`]).

#### Text read only for known non-secure on-screen elements; whole values never read
`Node::reads`: `ScreenVisibleTextPolicy.text`: nothing unless the element is known
not to be secure, is on screen and meets the viewport; a label's name
when it lies fully inside the viewport; otherwise the visible ranges
of a text control. Whole values are never read: they can hold a
complete hidden document.

#### A frame's document is not part of its parent document's ranges
`Node::reads`: A frame's document is not part of its parent document's ranges.

#### Windows, documents and scrolling containers clip content, mirroring clipsChildren
`Node::child_viewport`: Windows, documents and scrolling containers clip what they hold
(`clipsChildren`).

#### Offscreen subtrees, password fields and window furniture are skipped
`Node::walks_children`: Offscreen subtrees, password fields and window furniture are skipped.

#### Label controls mirror Mac label roles plus items UIA names after their text
`is_label`: Controls whose name is their visible text: the Mac's label roles (static
text, buttons, check boxes, radio buttons, menu items, links, the window)
and the items and headers UI Automation names after their text.

#### Secret-named labels match but only text entries mark window secure; document names exempt
`secure_status`: `secureFieldStatus`: a password field, or an element whose name or help
text names a secret (`CotypingSecureFieldDetector.isSecure`). Labels such
as "Password" match too, which keeps their text out; only text entries
make the window count as showing a secure field. A document's name is
the title of a whole page or file, not a field's label.

#### Title bars and scroll bars have fixed names and no content
`is_furniture`: Title bars (caption buttons, system menu) and scroll bars: fixed names,
no content.

#### Native documents like Word are not web content and have no page address
`is_web_engine`: Browser engines: Chromium (Chrome, Edge, Electron, WebView2), Gecko,
Trident and EdgeHTML. Word, Notepad and other native documents are not
web content and have no page address.

#### Some providers report garbage bounds for hidden elements, so implausible rects are None
`window_rect`: A UI Automation rectangle; `None` when empty or implausibly large (some
providers report garbage bounds for hidden elements).

#### Boolean property is false unless the provider reported true
`cached_flag`: A cached boolean property; false unless the provider reported true.

#### VARIANT union read only as its type; VariantClear releases it
`cached_flag`: SAFETY: the VARIANT is owned here; its union is read only as the type
`vt` names, and VariantClear releases what it holds.

#### BSTR is copied before VariantClear frees it
`current_string`: SAFETY: as in `cached_flag`; the BSTR is copied before VariantClear
frees it.

#### Reads windows with audio evidence and windows with a bound call
`BrowserCallReader::read`: Reads windows with audio evidence and windows with a bound call.

#### One cross-process call returns every control the check needs
`BrowserCallReader::read`: One cross-process call returns every control the check needs.
SAFETY: the condition and request are this function's own.

#### Process id check guards against reused window handles
`BrowserCallReader::read`: SAFETY: queries only, and the process id guards reused handles.

#### lparam is the list top_level_windows keeps alive for the whole enumeration
`visit_top_level`: SAFETY: `lparam` is the list `top_level_windows` keeps alive for the
whole enumeration; the rest are plain queries on a handle it supplied.

#### Over SSH session 0 nothing is in front; readers work across threads and after creators end
`works_without_a_desktop`: Over SSH (session 0) nothing is in front: the desktop window can be
walked but is never the foreground window. Readers set up on
several threads at once work, and keep working on another thread
after the ones that created them have ended.
SAFETY: no arguments.

### `LinuxWindows/crates/lokalbot-platform/src/screen/wayland.rs`

#### Wayland capture: grim on wlroots, else portal without dialog, active-window on portal v3
Wayland has no common way to read another window's pixels:

- wlroots compositors (Sway, Hyprland) with `grim` installed: the focused
  window's rectangle from the compositor's IPC, read with `grim -g`
  straight into memory.
- Elsewhere, the xdg-desktop-portal Screenshot API without a dialog
  (`interactive: false`). Portals that can target the active window
  (version 3) capture just that window. The picture the portal writes is
  read, then deleted at once.

#### Portal requests get 20 s to allow a first permission prompt
`PORTAL_TIMEOUT`: How long a portal request may take, including a first permission prompt.

#### Content area is container position plus window offset, excluding title bar
`find_sway_focused`: The content area: the container's position plus the window's
offset inside it, without the title bar.

#### Portal can target only the active window from version 3
`Portal`: The portal can target only the active window from version 3 on.

#### Portal captures the active window unnamed; engine checks app and title stayed
`Portal::focused`: The portal captures "the active window" without naming it; the
engine checks that the same app and title stayed in front.

#### Portal's saved screenshot copy is deleted right after reading
`Portal::capture`: The portal saved a copy (often in ~/Pictures); it must not outlive this read.

### `LinuxWindows/crates/lokalbot-platform/src/screen/win32.rs`

#### GDI BitBlt of DWM visible bounds never waits on a hung app, unlike PrintWindow
Windows: the foreground window's visible bounds (DWM's extended frame,
without the drop shadow) copied from the screen with GDI `BitBlt`. The
copy is what the user sees, it never waits on the target app (unlike
`PrintWindow`, which a hung app can block), and it works for DirectX and
browser windows. Coordinates are physical pixels: the capturing thread
is per-monitor DPI aware for the duration of each call.

#### Per-monitor DPI awareness keeps rectangles and pixels consistent across monitors
`DpiScope`: Per-monitor DPI awareness for the current thread until dropped, so
window rectangles and screen pixels agree on every monitor.

#### Changes only this thread's DPI awareness, restored on drop
`DpiScope::enter`: SAFETY: changes only this thread's DPI awareness; restored in `drop`.

#### GetWindowText never sends WM_GETTEXT to other processes, so hung apps cannot block
`window_title`: SAFETY: reads the caption into a buffer of the reported length. For
other processes this never sends WM_GETTEXT, so a hung app cannot block.

#### None when window is minimized, hidden or cloaked on another virtual desktop
`visible_rect`: The visible frame (no drop shadow), in physical pixels; `None` when the
window is minimized, hidden or cloaked (another virtual desktop).

#### Every GDI object is deleted before return; buffer sized for 32-bit top-down DIB
`copy_screen`: SAFETY: every GDI object created here is selected out and deleted
before returning; `pixels` is sized for the 32-bit top-down DIB that
GetDIBits writes.

#### Screen has no alpha, so BGRA converts to opaque RGBA
`copy_screen`: BGRA to RGBA; the screen has no alpha.

#### Secure desktop or protected content reads black, so uniform frames fail
`GdiCapture::capture`: A secure desktop (UAC, the lock screen) or protected content reads back black.

#### WTSSessionInfoEx reports lock state on Windows 10 and later
`session_locked`: `WTSSessionInfoEx` reports the lock state of this session (Windows 10 and later).

#### WTS buffer is read as WTSINFOEXW when large enough and freed with WTSFreeMemory
`session_locked`: SAFETY: WTS allocates `buffer`, which is read as the documented
WTSINFOEXW when large enough and freed with WTSFreeMemory.

#### Over SSH session 0 there is no foreground window and nothing fails
`works_without_a_desktop`: Over SSH (session 0) there is no foreground window; nothing fails.

### `LinuxWindows/crates/lokalbot-platform/src/screen/x11.rs`

#### Read the client window, not root, so overlaps stay out
X11: the window in `_NET_ACTIVE_WINDOW`, read with `GetImage`. The client
window itself is read (not the root), so overlapping windows stay out on
compositing desktops; only the part on screen is read.

#### Property reads are capped at 2048 32-bit words
`MAX_PROPERTY_WORDS`: Longest property read, in 32-bit units.

#### Window rect excludes GTK client-side shadow margin; None if unmapped
`Session::rect`: The window's on-screen rectangle without the invisible shadow margin
client-side decorations draw (`_GTK_FRAME_EXTENTS`), or `None` when
it is not mapped.

#### GetImage coordinates are relative to the whole window
`Session::capture`: GetImage takes coordinates inside the whole window.

#### Margin removal falls back to whole rect if nothing remains
`without_margin`: `rect` without a margin of `left`/`right`/`top`/`bottom` pixels; the
whole rectangle when the margin would leave nothing.

#### Capture reconnects when the X server connection breaks
`X11Capture`: Reconnects when the X server connection breaks.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
