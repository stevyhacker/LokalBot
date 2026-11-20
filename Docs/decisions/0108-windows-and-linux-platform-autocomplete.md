# 0108. Windows and Linux: platform — autocomplete

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-platform/src/autocomplete/`, `LinuxWindows/crates/lokalbot-platform/src/autocomplete/atspi/`, `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/`, `LinuxWindows/crates/lokalbot-platform/src/autocomplete/uia/`.

## Decisions

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/atspi.rs`

#### AT-SPI watcher: coalesced reads, backoff polling, pre-text exclusions, GTK 4 window offset
Linux: the focused field through AT-SPI2, the accessibility bus GTK,
Qt, Firefox, Chromium and Electron apps publish to (`CotypingAXHelper`,
`CotypingFocusTracker`).

The watcher registers for focus, caret and text-change events, reads the
focused object when one arrives (coalesced, so a burst of typing costs one
read), and polls the last field with Cotabby's backoff for toolkits that
miss events. Exclusions are checked from the owning process before any
text is requested; secure fields are recognized from their role and
labels and never read.

Some toolkits (GTK 4) report "screen" coordinates relative to their
window; those are moved by the window's position on the X screen.

#### Every call gives up after 250 ms so a stuck app costs one read
`CALL_TIMEOUT`: Every call gives up after this, so a stuck app costs one missed read.

#### Poll cadence before backoff, from CotypingFocusTracker.defaultIntervalMs
`POLL_INTERVAL`: Poll cadence before backoff (`CotypingFocusTracker.defaultIntervalMs`).

#### Events within 8 ms are read once
`COALESCE`: Events arriving this close together are read once.

#### 120 ms budget for walk finding text above a field
`VISIBLE_BUDGET`: Time for the walk that finds the text above a field.

#### GTK 4 uses window coords plus content origin; others screen coords
`placement`: The coordinate type to ask for and how to bring the answer to the
screen: window coordinates plus the window's content origin for GTK 4,
else screen coordinates as they are.

#### AT-SPI reports a missing rect as zeros or -1s
`rect`: AT-SPI reports a missing rect as zeros or -1s.

#### Registry forwards only subscribed events; toolkits send none otherwise
`EVENTS`: Event subscriptions the registry forwards to apps: without one, toolkits
do not send the event at all.

#### Handle both siiva{sv} and Qt siiv(so) event body layouts
`parse_event`: Parses one event signal: member, sender, path and the `detail`/`detail1`
fields, whichever body layout the toolkit uses (`siiva{sv}` or Qt's
`siiv(so)`).

#### Events use their own connection so slow reads never back up signals
`AtspiWatcher::start`: Events arrive on a connection of their own so a slow read never
backs up the signal stream.

#### Close connection to end event threads blocked reading it
`AtspiWatcher::drop`: Ends the event threads, which are blocked reading this connection.

#### GTK 4 reports only window-relative coordinates; keep content origin
`Fixed.window_relative`: Where the window's content is on screen, when the toolkit can only
report coordinates within its window (GTK 4).

#### Field focused before watcher started has sent no event; discover it
`Reader::run`: A field focused before the watcher started has sent no event yet.

#### Coalesce an event burst into one read
`Reader::run`: Read once for a burst of events.

#### Adopt editing object whose focus event preceded the watcher
`Reader::handle`: An editing object whose focus event came before we did.

#### Ignore output objects in other apps such as terminals
`Reader::handle`: Output in another app, such as a terminal: not ours.

#### Forget text read around a field when focus leaves it
`Reader::set_current`: Text read from around a field is forgotten when focus leaves it.

#### Explain apps hiding text from accessibility so autocomplete does not look broken
`Reader::discover_focus`: Apps that keep their text from accessibility tools cannot get
suggestions; say which, so it does not look broken.

#### Use one Collection query when supported, else short walk of showing objects
`Reader::find_focused`: The focused descendant of an app: one `Collection` query when the
toolkit supports it, else a short walk through showing objects.

#### Collection match rule tuple field order
`Reader::find_focused`: (states, match, attributes, match, roles, match, interfaces, match, invert)

#### Own windows: practice editor feeds engine itself; nothing else of LokalBot read
`Reader::read_fixed`: LokalBot's own windows: its practice editor feeds the engine
itself, and nothing else of LokalBot is read.

#### Secure fields are judged before any text is touched and never read
`Reader::read_fixed`: Secure fields: never read, judged before any text is touched.

#### Code and PIN fields judged from names before reading text; Chromium reports DOM id
`Reader::read_fixed`: Verification codes, PINs and one-time passwords, judged from the
field's names before its text is read. Chromium reports the DOM id.

#### Chromium reports DOM class list as object attribute
`Reader::read_fixed`: Chromium reports the DOM's class list as an object attribute.

#### GTK 4 screen extents are parent-relative; use window extents from content origin
`Reader::window_origin`: GTK 4 cannot know where its window is: its "screen" extents are
relative to the parent, and only window extents are right, measured
from the window's content (inside the shadow it draws itself). Its
fields are placed from window extents and where the X window's
content is; `None` for toolkits that report screen coordinates.

#### Web content marks embedded objects with U+FFFC; strip them
`Reader::read_text`: Web content marks embedded objects with U+FFFC.

#### Estimate thin caret at field's leading edge, as macOS does
`Reader::read_text`: A thin caret at the field's leading edge, as macOS estimates.

#### Text above field read once per field and only when policy allows
`Reader::visible_text`: The text above the field, read once per field and only when allowed.

#### Offset units per toolkit as measured live; unchecked toolkits keep characters
`Counting`: What a toolkit counts in `EditableText` and `Text` calls. AT-SPI says
characters; these are what GTK 3.24, GTK 4.14, Qt 5.15 and Qt 6.4 fields
did when driven live. A toolkit not checked that way keeps characters.

#### GTK offsets in characters; InsertText length in UTF-8 bytes; GTK 4 ignores length
`Counting::Gtk`: Offsets in characters; `InsertText`'s length in UTF-8 bytes (a GTK 4
entry ignores the length).

#### Qt counts everything in UTF-16 units
`Counting::Qt`: Everything in UTF-16 units, the index of Qt's strings.

#### Too small length truncates text; too large makes Qt pad with NUL
`Counting::insert_length`: `InsertText`'s length for `text`. Too small cuts the text short; too
large makes Qt pad it with NUL characters.

#### EditableText first, else XTest keystrokes into front window of field's app
`insert`: Types an accepted chunk at the caret: `EditableText` when the field has
it, else XTest keystrokes into the window in front, which must belong to
the field's app.

#### Wait for grabbed Tab release or keystrokes loop back to us
`insert`: The grabbed Tab must be up, or the keystrokes would come back to us.

#### Replace tabs with spaces since our Tab grab would take them
`insert`: Tabs would be taken by our own grab; a suggestion never needs one.

#### Fix caret after insert: some toolkits leave it before, Qt line edit sends it to end
`insert_editable`: Some toolkits leave the caret before text inserted at it, and a Qt
line edit sends it to the end of the field.

#### GTK 3 ATK bridge reports gtk, GTK 4 reports GTK
`each_toolkit_is_counted_the_way_it_counts`: The ATK bridge of GTK 3 reports "gtk", GTK 4 "GTK".

#### Unverified toolkits left as characters
`each_toolkit_is_counted_the_way_it_counts`: Not checked against a live field, so left as they were.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/atspi/focused.rs`

#### Focused reads are one-shot, separate from the watcher, privacy first
One-shot reads of the focused object for dictation and selection actions,
separate from the watcher: identity and privacy, the selection, the text
before the caret, and the text above the field.

#### ACTIVE is ATSPI_STATE_ACTIVE, the window holding the keyboard
`ACTIVE`: `ATSPI_STATE_ACTIVE`: the window with the keyboard.

#### Bounds how far the walk looks for selection in read-only content
`SELECTION_WALK_NODES`: How far the walk looks for a selection in read-only content.

#### Silent means bus unreachable or app publishes nothing
`Located::Silent`: The bus is unreachable or the app publishes nothing.

#### Use one Collection query when supported, else a short walk
`find_focused`: The focused descendant of an app: one `Collection` query when the toolkit
supports it, else a short walk through showing objects.

#### Without a pid, pick the one app whose window is active
`locate`: Finds the focused object of `pid`, or without a pid (a Wayland desktop that
does not say what is in front) of the one app whose window is active.

#### Several apps claiming the keyboard cannot be told apart, so Silent
`locate`: Several apps claiming the keyboard cannot be told apart.

#### Identity and privacy come from metadata; only selection offsets are read
`describe`: Identity and privacy from metadata; only the selection's offsets are read.

#### Accessibility adds metadata only to an input method's view; no field text
`Surroundings`: What accessibility adds to an input method's view of a field, when the app
publishes it. Metadata only: no text of the field is read.

#### None when app says nothing, leaving only the input method's hints
`surroundings`: The focused object of `pid` and where it sits. `None` when the app says
nothing, which leaves only the input method's own hints.

#### Active-window pid via accessibility for Wayland desktops that do not report it
`active_pid`: The process whose window is active, for a Wayland desktop that does not
report it another way.

#### Selected text has embedded-object marks removed
`selection_in`: The selected text of one object, with embedded-object marks removed.

#### Read-only content keeps its selection on a text object below the focused document
`selection_below`: Read-only content keeps its selection on a text object below the document
that has focus.

#### Same object must still have focus once the text is read
`selected_text`: The same object must still have focus once the text is in hand.

#### Return the focused object only if still the bound, non-secure field
`bound_field`: The focused object, when it is still the bound field and not a secure one.

#### Text above the field uses window-relative coordinates, consistent within one window
`visible_text`: Text above the bound field, under `policy`. Coordinates are window
relative, which every toolkit reports consistently within one window.

#### Discard anything read while focus moved
`visible_text`: Nothing read while focus moved is kept.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/clipboard.rs`

#### Clipboard read checks concealment markers first, drops on change, never persists, none on Wayland
Reading the clipboard for autocomplete's prompt
(`CotypingClipboardProvider`). Markers for concealed copies are checked
before asking the clipboard's owner for any text, and a change while
reading drops the whole read. The text is held only until the next copy,
never written anywhere. On Wayland nothing is read: only LokalBot's own
practice editor runs there, and it uses no clipboard context.

#### change_count moves whenever the clipboard contents change
`ClipboardRead.change_count`: Moves when the clipboard's contents change.

#### Concealed-clipboard markers from Mac plus password manager types on Linux and Windows, compared lowercased
`SENSITIVE_TYPES`: `org.nspasteboard`'s types as the Mac checks them, plus what password
managers set on these platforms (X11's KDE hint, Windows' monitor and
history opt-outs). Compared lowercased.

#### Clipboard is read only if it holds text and nothing concealed
`allows`: Whether a list of clipboard types holds text and nothing concealed.

#### Cache last read until change count moves so reads stay rare
`ClipboardReader`: Reads the clipboard, keeping the last read until its change count moves,
so a read is rare however fast the typing.

#### None when unreadable, concealed, or the desktop cannot read the clipboard
`ClipboardReader.read`: The current clipboard, or `None` when it holds nothing readable or
something concealed, or when this desktop has no way to read it.

#### Release held clipboard text and the connection
`ClipboardReader.forget`: Lets go of the text and the connection.

#### Do not wait over 150 ms for a clipboard owner on the autocomplete worker
`backend::OWNER_TIMEOUT`: A clipboard owner that takes longer than this is not waited for: this
runs on the autocomplete worker.

#### Larger clipboard text arrives incrementally and is not followed
`backend::MAX_TEXT_WORDS`: Larger text arrives in increments, which is not worth following here.

#### Selection conversion returns None when owner does not answer in time
`Backend.convert`: Asks the owner to convert the clipboard to `target` and reads the
result. `None` when there is no answer in time.

#### Mirror CotypingClipboardProvider: types, text, types again, count unmoved
`Backend.snapshot`: `CotypingClipboardProvider.snapshot`: types, text, then the types
again, with the change count unmoved throughout.

#### UNICODE_TEXT is the Windows CF_UNICODETEXT format id
`backend::UNICODE_TEXT`: `CF_UNICODETEXT`.

#### Registered Windows clipboard format names used by password managers and Windows
`backend::SENSITIVE_FORMATS`: Their registered names, as password managers and Windows spell them.

#### These calls do not open the clipboard, so owner is not asked for text
`holds_text_and_nothing_concealed`: SAFETY: no pointers beyond the strings that outlive each call; these
calls do not open the clipboard, so its owner is not asked for text.

#### Sequence number call needs no arguments and no clipboard access
`Backend.change_count`: SAFETY: no arguments; returns 0 without clipboard access.

#### Test needs an X display, such as xvfb-run
`reads_an_x11_owner_and_refuses_a_password_manager`: Reads a real selection owner: runs only with an X display, such as
under `xvfb-run`.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/focused.rs`

#### Dictation and selection reads run only on shortcut, name only what is read, blocking
Reads of the focused field for dictation and selection actions
(`CotypingAXHelper.resolveDictationFocusSnapshot`,
`selectedTextForSelectionAction`, `dictationTextBeforeCaret`). Unlike
[`super::FieldWatcher`], nothing runs until a shortcut asks, and only what a
call names is read. Blocking: call them from a background thread.

#### Field carries accessibility metadata and no field text
`Field`: What accessibility says about the focused element. Carries no field text.

#### Secure field: nothing else about it was read
`Field.secure`: A password or other secure field; nothing else about it was read.

#### Selection offsets present only when selection is not empty
`Field.selection`: The selection's start and end offsets, when it is not empty.

#### Silent means bus down or app publishes nothing
`FieldRead::Silent`: No accessibility answer: the bus is down or the app publishes nothing.

#### NoFocus means the app answers but nothing in it has focus
`FieldRead::NoFocus`: The app answers, and nothing in it has focus.

#### Empty means an editable field with nothing selected
`SelectionRead::Empty`: An editable field with nothing selected.

#### Without a pid, read the app whose window is active
`read_field`: The focused element of `pid`; without a pid, of the app whose window is
active.

#### Selected text is read once
`selected_text`: The selected text in `pid`'s focused element, read once.

#### Text only while bound field has focus and is not secure; None makes no claim
`text_before_caret`: The bounded text before the caret, only while the bound field has focus
and is not secure. `None` makes no claim either way.

#### Text above the field only when policy allows, read and validated once
`visible_text`: The text shown just above the bound field, when `policy` allows it, read
and validated once.

#### Active pid comes only from accessibility on such desktops
`active_pid`: The process whose window is active, where only accessibility can say.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/geometry.rs`

#### Pure ghost geometry in top-left screen pixels, mirroring Swift files, flipped vertical sense
Where the ghost text goes and how it looks, as pure math so it is
deterministic and testable (`CotypingOverlayGeometry.swift`,
`CotypingInlineGhostLayout.swift`, `CotypingGhostTextLayout.swift`,
`CotypingGhostSizing.swift`, `CotypingRenderMode.swift`,
`CotypingFieldStyle.swift`).

Rects use screen pixels with the origin at the top left, as AT-SPI and UI
Automation report them (macOS works bottom-up, so "below" there is
"above" in the Swift code). Text is measured through a closure, so tests
need no fonts.

#### Rect is in screen pixels with origin at top left
`Rect`: A rectangle in screen pixels, origin at the top left.

#### Negative inset grows, positive shrinks, on every edge
`Rect::inset`: Grows (negative) or shrinks (positive) every edge.

#### Accepted formats: hex, AT-SPI comma triplet, rgb() form
`Rgb::parse`: "#1a2b3c", "1a2b3c", or the toolkit forms "26,43,60" (AT-SPI) and
"rgb(26,43,60)".

#### AT-SPI reports 16-bit channels, scaled down to 8-bit
`Rgb::parse`: AT-SPI reports 16-bit channels ("65535,65535,65535").

#### Luminance in 0 to 1 using Rec. 601 weights, matching Swift
`Rgb::luminance`: Perceived luminance (0–1), Rec. 601 weights
(`CotypingGhostStyle.relativeLuminance`).

#### Field's own font and colors, only when its toolkit reports them
`FieldStyle`: The field's own font and colors, when its toolkit reports them
(`CotypingFieldStyle`).

#### Font size is in points
`FieldStyle.font_points`: Font size in points.

#### Ghost opacity is 0.4 relative to the field's text color
`GHOST_OPACITY`: Opacity of ghost text relative to the field's text color.

#### The part the next Tab takes is drawn stronger at 0.62
`EMPHASIS_OPACITY`: The part the next Tab takes is drawn a little stronger.

#### Dim field text unless unreadable; sampled background beats toolkit-reported one
`ghost_paint`: The ghost's color: the field's text color dimmed, unless it would be
hard to read against the field, then a light or dark hint. A sampled
background luminance beats anything the toolkit reported
(`CotypingGhostStyle.resolvedGhostColor`).

#### Ghost font bounds in logical pixels, 8 to 48 pt on macOS
`MIN_FONT_PX`: Font size bounds for the ghost, in logical pixels (8–48 pt on macOS).

#### Caret estimated from field frame says little about text, so cap font
`MAX_ESTIMATED_FONT_PX`: A caret estimated from the field frame says little about the text.

#### Glyph box is about 1.2 times font size; toolkits report caret that tall
`GLYPH_BOX_PER_SIZE`: A font's glyph box is about 1.2 times its size, and toolkits report a
caret about that tall.

#### Points to logical pixels at 96 per inch, convention of GPUI and toolkits
`points_to_px`: Points to logical pixels (96 per inch, the convention of GPUI and both
toolkits).

#### Use reported size, correct for page zoom from caret, else estimate from caret
`ghost_font_px`: The ghost's font size in the same pixels as `caret_height`: the field's
own size when reported, corrected for page zoom when the caret is far off
its glyph box, else estimated from the caret (`CotypingGhostFontSizing`).

#### Pill used when text follows caret on its line or caret is estimated
`RenderMode::Pill`: A small pill under the caret's line: text follows the caret on its
line, or the caret position is only estimated.

#### Inline only at line end with exact caret; ghost over trailing text is unreadable
`render_mode`: Inline only at the end of a line with an exact caret; ghost text over
the characters after the caret would be unreadable
(`CotypingRenderModePolicy.mode`).

#### offset is where text starts in the displayed suggestion, in characters
`InlineLine.offset`: Where `text` starts in the displayed suggestion, in characters.

#### Line box x is the leading end (right for RTL); text centered vertically
`InlineLine.x`: The line's box: its leading end (the right end for right-to-left
text), its top and its height. Text is centered vertically in it.

#### Inline wrap goes only to empty in-field lines at text edge; never over text
`InlineLayout`: Where each line of an inline suggestion goes. The first continues the
caret's line from the caret; what does not fit before the field's edge
wraps onto the lines below, at the field's text edge, but only onto
lines that hold no text and lie inside the field. Nothing is ever drawn
over text (`CotypingInlineGhostLayout`).

#### complete false means lines hold only the start, or nothing
`InlineLayout.complete`: Every character has a place. When false the lines hold only the
start, or nothing.

#### Keep clear inside field edges, where most fields pad their text
`FIELD_INSET`: Kept clear inside the field's edges, where most fields pad their text.

#### Paragraph to the caret reveals where field text starts if it fits one line
`InlineInput.preceding_line`: The field's paragraph up to the caret. When it fits on one line it
shows where the field's text starts, which wrapped lines line up with.

#### Lines below are free only when nothing follows the caret
`InlineInput.lines_below_free`: Nothing follows the caret, so the lines below it are free.

#### measure gives string width in the ghost font
`InlineLayout::make`: Lays out `text` at the caret. `measure` gives a string's width in the
ghost font.

#### Wrapped lines stay inside the field; below it is other interface
`InlineLayout::make`: Wrapped lines stay inside the field: below it is other interface.

#### If word remainder does not fit, app moves the word; no place known
`InlineLayout::make`: The rest of the word at the caret does not fit, so the app
moves the whole word to the next line: no place on screen
shows where this text will go.

#### A line break or wrap space is not drawn
`InlineLayout::make`: A line break or the space the app wraps at is not drawn.

#### Longest word-ended prefix drawable whole; None if impossible or partial disallowed
`InlineLayout::longest_drawable`: The longest start of `text`, ending after a word, that can be drawn
whole. `None` when nothing can, or when `allow_partial` is off and the
whole cannot (`CotypingInlineGhostLayout.longestDrawable`).

#### Caret after typing is laid out from caret by same wrap rule; None if unknowable
`InlineLayout::caret_after_typing`: Where the caret will be once `typed` is in the field: at the end of
`typed` laid out from the caret, since the app wraps it by the same
rule. `None` when that is only known once the app shows it
(`CotypingInlineGhostLayout.caretRect(afterTyping:)`).

#### Trailing spaces are not drawn at line end but caret passes them
`InlineLayout::caret_after_typing`: Spaces are never drawn at a line's end, but the caret goes past them.

#### Every word-ended prefix of text, shortest first
`word_prefixes`: Every start of `text` that ends after a word, shortest first.

#### Whitespace runs draw as one space, keeping leading space and line breaks
`display_text`: Whitespace runs drawn as one space, keeping a leading space and line
breaks (`CotypingInlineGhostLayout.displayText`).

#### Horizontal room is inside field if its frame fits a line, always on screen
`text_span`: Horizontal room for text: inside the field when it reports a frame wide
enough to hold a line, and always on screen.

#### A one-line paragraph ends at caret, so its width back finds text edge
`wrap_edge`: Where wrapped lines start. A paragraph that fits on one line ends at the
caret, so its width back from the caret finds the field's text edge.

#### Longest run of whole words fitting; overlong word split only if required
`fitting_prefix`: The longest run of whole words from the start of `text` that fits in
`available`, stopping at a line break. A word wider than a whole line is
split between characters when `must_take_something` is set.

#### Gap between caret and pill, and pill and screen edges
`PILL_GAP`: Gap between the caret and the pill, and the pill and screen edges.

#### Movement too small to see, or rounding between two reads
`REANCHOR_TOLERANCE`: Movement too small to see, or rounding between two reads.

#### Pill goes under caret line, above it when no room below
`pill_frame_at_caret`: The pill under the caret's line, above it when there is no room below
(`CotypingOverlayGeometry.mirrorFrame`).

#### Estimated caret puts pill outside field, never over text; None without room
`pill_frame`: Where the pill goes. An exact caret gets [`pill_frame_at_caret`]. A caret
estimated from the field says nothing about where the text is, so the
pill goes just outside the field, below it or else above it, never over
its text; `None` without such room (`CotypingOverlayGeometry.popupFrame`).

#### Hold ghost reanchor only for small moves or briefly after accept
`should_hold_reanchor`: Whether an inline ghost stays put when the caret is read again: it moves
to any other line, and whenever the caret is further along than the ghost
starts (the ghost would cover typed text). A ghost ahead of the caret is
held only just after an accept, since apps often show inserted text
before they move the caret (`CotypingOverlayGeometry.shouldHoldInlineReanchor`).

#### Pill text maximum width and line count, mirroring CotypingGhostTextLayout
`PILL_MAX_TEXT_WIDTH`: The widest a pill's text may be, and how many lines it shows
(`CotypingGhostTextLayout`).

#### Wrap pill text to max lines and width, ending with ellipsis when cut
`pill_lines`: Wraps pill text into at most `max_lines` lines no wider than
`max_width`, ending with "..." when cut (`CotypingGhostTextLayout.wrappedLines`).

#### Test setup: paragraph Hi ends at caret so text edge is 108
`long_text_wraps_at_the_field_text_edge_onto_free_lines`: The paragraph "Hi" (16 px) ends at the caret: the field's text
starts at 108, which wrapped lines line up with.

#### Zoomed page reports unzoomed size; the caret shows the zoom
`font_size_follows_the_field_or_the_caret`: A zoomed page reports the unzoomed size; the caret shows the zoom.

#### Black text on a dark field is a flattened dynamic color
`ghost_color_stays_legible`: Black text reported on a dark field is a flattened dynamic color.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method.rs`

#### Wayland autocomplete runs as the desktop's input method; routes per desktop, privacy in PRIVACY.md
Autocomplete in other apps on Wayland, as the desktop's input method.

Wayland lets no ordinary app take a key from another app, place a window
at its caret or type into it. An input method is the supported way in: the
desktop tells it when a text field has focus, what kind of field it is and
the text around the caret, shows its text inline in the field (preedit),
and commits text without the clipboard.

The field's owner is asked for separately, because the protocol does not
say: the compositor names the window in front (see [`surface`]), and
accessibility adds what it knows about the field where the app publishes
it. Nothing is delivered until that answer is in, so an excluded app, a
terminal or a password field never reaches the engine.

- [`wlroots`] is the route on Sway and Hyprland (`zwp_input_method_v2`). The
  keyboard is grabbed only while a suggestion shows, and every key but the
  accept keys and Esc goes straight back through a virtual keyboard.
- [`ibus`] is the route on GNOME: an IBus engine over D-Bus, which the user
  chooses as an input source. While it is chosen the desktop asks it about
  every key, and it answers without keeping them.
- [`kwin`] is the route on KDE Plasma (`zwp_input_method_v1`). Plasma talks
  to the input method it starts itself, so [`kwin_helper`] holds that
  connection for the session and passes the field to the app. As on Sway,
  the keyboard is grabbed only while a suggestion shows.

[`Core`] is what the routes share: the field, the ghost and what may be read.

What this route sees, what it keeps and how it treats other input methods
is written down in `PRIVACY.md`. Typed text is never logged here, and never
kept past the field's next state.

#### Focus key embeds activation so nothing lands in a later field
`KEY_PREFIX`: Prefix of [`FieldSnapshot::focus_key`] on this route; the rest is the
activation the field belongs to, so nothing lands in a later field.

#### Content type gates fields; only prose is suggested in
`Content`: What an input method's content type says about a field. Only prose is
suggested in.

#### Field kind refusal is judged before any text is used
`Content::refusal`: Why this kind of field gets no suggestion, judged before any text.

#### Digits, phone, address and date fields keep Tab for the field
`Content::refusal`: Digits, numbers, phone numbers, addresses and dates, whose Tab
belongs to the field.

#### Surrounding text offsets are in bytes
`Surrounding`: The surrounding text as the desktop gave it; offsets are in bytes.

#### zwp_input_method_v2 carries 4000 bytes; apps clip longer text
`SURROUNDING_LIMIT`: The longest surrounding text `zwp_input_method_v2` carries. An app clips
longer text to about this, so a window this full may have been clipped.

#### Windows above this size are treated as clipped
`CLIPPED_AT`: Above this a window is treated as clipped.

#### None when offsets are not on character boundaries
`Surrounding::split`: The text on either side of the caret, or `None` when the offsets do
not fall on character boundaries of this text.

#### Firefox counts preedit in surrounding text; strip the ghost, not user text
`Surrounding::without_preedit`: This text without a ghost the app counted in it. Most apps leave
preedit out of the surrounding text, as the protocol says; Firefox
reports it, with the caret at or inside it. A ghost is not the user's
text and must not read as what follows the caret.

#### Field with only mask characters is a password field without a hint
`Surrounding::is_masked`: Characters a toolkit draws in place of a password's. A field holding
only these is a password field that gave no hint.

#### Owner-based refusal is decided before the field's text is used
`Refusal`: Why a field's owner rules it out, decided before its text is used.

#### Surface holds field owner and accessibility data, no field text
`Surface`: Who owns the active field and what accessibility adds about it: everything
the input method's own events leave out. Holds no text of the field.

#### Answer is tagged with the activation it belongs to
`Surface.activation`: The activation this answer belongs to.

#### None when accessibility silent; content hint decides single-line
`Surface.single_line`: `None` when accessibility said nothing: the content hint decides.

#### Checks run in protection order; no text read until they pass
`snapshot`: The focus to report for one state of a field. The checks run in the
order of what they protect, and no text is read until they have passed.

#### Field draws ghost itself, so caret geometry is unneeded
`snapshot`: The field draws the ghost itself, so nothing needs the caret.

#### Sending to route thread never blocks app threads
`Command`: The work a route's thread gets. Sending never blocks, so the app's threads
never wait on the desktop.

#### One accept is a single commit applying edit and showing what is left
`Handle::accept`: One accept, in a single commit: makes `edit` at the caret and shows
`next` as what is left. `before` and `after` are the text around the
caret it applies to.

#### Running route is reachable by parts that attach after the watcher
`CURRENT`: The running route, for the parts of the app that attach after the watcher.

#### Watcher must start before accept keys attach
`attach_keys`: Connects the accept keys to the running route; the watcher starts first.

#### Typing through the route serves callers that have no ghost
`insert`: Types into a field through the running route, for callers with no ghost.

#### Route availability may change anytime, so the running route reports it
`support`: Whether this desktop has a route for autocomplete in other apps, and why
not when it has none. Whether another input method is in the way can change
at any moment, so the running route watches for that and says so itself.

#### GNOME/KDE input-method choice can change in Settings, route reports it itself
`support`: Whether LokalBot is the chosen input method can change while
Settings is open, so the route says that itself.

#### Settings row steps per desktop; None outside a route
`input_source_steps`: What the user does to use autocomplete on this desktop, worded for the
Settings row. `None` outside a route.

#### Plasma starts the helper once chosen under Virtual Keyboard; returns exit code
`run_kwin_helper`: Runs the input method KDE Plasma starts for LokalBot once it is chosen
under Virtual Keyboard (`lokalbot --kwin-input-method`), until Plasma stops
it. Returns the process's exit code.

#### Entry lists LokalBot under Virtual Keyboard; packages install the same file
`kwin_desktop_entry`: The desktop entry that lists LokalBot under Plasma's Virtual Keyboard, with
this copy's path in it. Packages install the same file.

#### IBus component file makes LokalBot an input source; packages install same file
`ibus_component`: The IBus component file, which makes LokalBot one of the desktop's input
sources, with this copy's path in it. Packages install the same file.

#### Ghost removed for a key waits 150 ms; unchanged field keeps suggestion
`GHOST_BACK_AFTER`: How long a ghost taken out of the field for a key waits for the field's
next state. If the key changed nothing, the suggestion still stands.

#### Owner re-read every 2 s while typing for title or page changes
`SURFACE_REFRESH`: How often the owner is read again while typing, for a title or page that
changed within the same field.

#### Chromium/Electron report surrounding only on commit, so quiet fields are asked periodically
`ASK_WHILE_TYPING`: Chromium and Electron report the text around the caret only in answer to an
input method's commit, not as the user types, so a field that has gone quiet
is sent an empty one now and then. Their first report after a pause comes
within [`ASK_WHEN_IDLE`], and within [`ASK_WHILE_TYPING`] from then on.

#### User counts as typing for 5 s after last text change
`TYPING_LASTS`: How long after the text last changed the user counts as typing.

#### Changes 120 ms after asking mean the field reports itself, as GTK and Firefox
`UNPROMPTED_AFTER`: A change this long after the last asking was not an answer to it. A few of
those mean the field reports by itself, as GTK and Firefox do, and needs no asking.

#### Preedit shows ghost before the caret; empty text shows nothing
`Output::preedit`: Shows `text` as preedit, in front of the caret's way. Empty shows nothing.

#### An edit and its following preedit happen as one step
`Output::commit`: One edit and the preedit that follows it, as one step.

#### Stop taking keys when field is gone or nothing shows
`Output::release_keys`: The field is gone or nothing is on show: stop taking keys.

#### Core holds active field and ghost state shared by both routes
`Core`: The active field and the ghost in it, the same for both routes.

#### Drop field text as soon as the field is not ours to read
`Core.surrounding`: Dropped as soon as a field turns out not to be ours to read.

#### Keep previous ghost since an app's next report may still count it
`Core.previous_ghost`: The one before it, which an app's next report may still count.

#### Records when a key given back removed the ghost temporarily
`Core.blanked_at`: When a key given back took the ghost out of the field for now.

#### Text read around a field is forgotten when focus leaves
`Core::forget_surroundings`: Text read from around a field is forgotten when focus leaves it.

#### Refused fields' text must not even be held
`Core::refuses_text`: Whether a field's text must not even be held.

#### New focus invalidates everything known about the previous field
`Core::activate`: A text field has focus: whatever was known before is about another one.

#### Fields not ours to read keep none of their text
`Core::update`: Not ours to read: nothing of its text stays.

#### Handles commands common to routes; returns the route-specific ones
`Core::command`: Applies a command both routes treat alike. The others come back.

#### Command applies only if its field is the active one that may receive text
`Core::is_current`: The field a command names is the active one, and text may go to it.

#### Toolkits may commit preedit on a key; ghost leaves first, returns if valid
`Core::blank_for_key`: A key is going to the field. Toolkits may commit preedit when one
arrives, so the ghost leaves first and comes back if it still applies.

#### Ask only readable quiet fields without a ghost; ghost commits ask too
`Core::next_ask`: When to ask a quiet field for its text next. Only a field that may be
read gets asked, and only while no ghost shows: a ghost's commits ask too.

#### GTK/QT_IM_MODULE settings send apps around the input method; read at startup
`module_override`: The session's own settings that send apps around the desktop's input
method, worded for Settings. Toolkits read these when they start.

#### Toolkit password mask alone blocks a field lacking any hint
`secure_fields_are_refused_on_every_signal_and_carry_no_text`: No hint at all, but the toolkit gave us its mask.

#### Firefox reports the ghost after the caret, then with caret inside it
`a_ghost_counted_in_the_text_is_taken_out_and_real_text_is_not`: Firefox: the ghost after the caret, then with the caret inside it.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/ibus.rs`

#### GNOME runs IBus; LokalBot is an optional engine seeing keys only while chosen, never logged
The input method on GNOME: an IBus engine, spoken to over IBus's own D-Bus.

GNOME has no input method protocol for ordinary apps. GNOME Shell runs IBus
itself and hands it every text field, so LokalBot takes part as one of its
engines, which the user chooses as an input source next to their layouts.
Their other input sources keep working, and nothing reaches this engine
unless it is the chosen one.

While it is chosen the desktop asks it about every key press in a text field.
All it does with one is compare it to the accept keys while a suggestion
shows, and answer whether it was taken. Keys are neither kept nor logged.

IBus finds engines through a component file read when it starts: packages
install one, and `lokalbot --ibus-component` prints it for other installs.

#### Look for IBus and check it is alive every 3 s
`CHECK_EVERY`: How often to look for IBus, and check it is still there.

#### IBusModifierType bit marking a key release
`RELEASE_MASK`: `IBusModifierType`: the bit on a release.

#### Shift, Ctrl, Alt, Super, AltGr, virtual mods count; locks leave a key plain
`HELD_MODIFIERS`: Shift, Control, Alt, Super, AltGr and the virtual Super, Hyper and Meta. Caps
Lock and Num Lock leave a key plain.

#### Focus leaving drops the ghost via PREEDIT_CLEAR, never types it
`PREEDIT_CLEAR`: `IBUS_ENGINE_PREEDIT_CLEAR`: focus leaving drops the ghost, never types it.

#### IBus purposes differing from text_input_v3 are mapped, plus private hint
`content_from_ibus`: The IBus content purposes that differ from `zwp_text_input_v3`'s, which
[`Content`] speaks, and its private hint.

#### IBus counts characters; convert to bytes since accept deletes around caret
`surrounding_from_ibus`: IBus counts in characters, and an accept deletes around the caret.

#### Taken keys still down, by keycode, with what passing one on needs
`Keys.taken`: Keys taken and still down, by keycode, with what passing one on needs.

#### Key mapping follows other routes: keymap result, except physical key left of 1
`intercepted`: The key a press means, by the rules the other routes follow: what the
keymap makes of it, except the physical key left of 1.

#### Decide press or release from keys alone; true keeps it from the field
`decide`: One press or release, answered from `keys` alone. `true` keeps it from the
field.

#### Key goes to field and the ghost steps out first
`Decision::PassBlanking`: It goes to the field, and the ghost steps out of the way first.

#### IBus makes one engine per input context; GNOME Shell keeps one for desktop
`Engine`: One engine. IBus makes one per input context; GNOME Shell keeps a single
context for the whole desktop.

#### GNOME Shell swaps engines around password fields; old engine may hear late
`Engine::lost_focus`: GNOME Shell swaps the engine around password fields, so an old engine
can hear this after a new one has focus.

#### Clear ghost before answering so field never gets key with ghost in it
`Engine::process_key_event`: Before the answer, so the field never gets the key with the
ghost still in it.

#### IBus ends an engine through org.freedesktop.IBus.Service destroy
`Service`: `org.freedesktop.IBus.Service`: IBus ends an engine with this.

#### IBusText wire shape: type name, attachments, string, attribute list
`text_value`: An `IBusText` as IBus sends it: type name, attachments, the string and an
attribute list.

#### IBus sends field kind only on change, maybe before focus, so keep across fields
`Emitter.content`: IBus says a field's kind only when it differs from the last one, and
may say it before the focus event, so it outlives each field.

#### Empty field reports nothing, nor does unchanged text; text comes with next change
`on_engine`: An empty field reports nothing, and neither does one whose text
is what was last reported. Text comes with the next change.

#### IBus reads component files from IBUS_COMPONENT_PATH, default /usr/share/ibus/component
`component_dirs`: Where IBus reads component files from, in the order it reads them.

#### exe is what IBus starts when source is chosen and LokalBot is not running
`component_xml`: The component file with `exe` as what IBus starts when the source is chosen
and LokalBot is not running.

#### Right Arrow is not an accept key by default
`a_suggestion_takes_plain_accept_keys_and_their_releases`: Right Arrow is not bound by default.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/kwin.rs`

#### Plasma runs one input method via helper; app connects to helper, runs Core; no blocking work
The route on KDE Plasma, the app's side of the KWin input method.

Plasma runs one input method at a time, the one chosen under System Settings
→ Keyboard → Virtual Keyboard, and talks to it over `zwp_input_method_v1`.
Choosing LokalBot there starts [`super::kwin_helper`], which holds that
connection for the session. This route connects to the helper and runs
[`Core`] here, like the other routes; the compositor names the window in
front through a KWin script (see [`super::surface`]). Until the helper is
running, Settings says how to choose it.

This thread does no blocking work beyond a local socket's.

#### Retry after 30 s when helper is another release; match arrives next session
`RETRY_MISMATCHED`: After a helper from another release answered: one that matches arrives
only with the next session.

#### KWin enforces a single input method, so no conflict watch needed
`start`: KWin enforces one input method itself, so there is nothing to look out for.

#### poll fd array stays valid for the whole call
`run`: SAFETY: `fds` is a valid array for its length, for the whole call.

#### Returns false to stop the route
`Route::command`: False to stop.

#### After helper loss, retry soon; KWin restarts it if it crashed
`Route::lost`: The helper went away: say so, and look for it again soon. KWin starts it
again if it crashed.

#### Text of an already ruled-out field is not even held
`Route::event`: A field already ruled out: its text is not even held.

#### KDE looks for applications in the user's folder first
`entry_dirs`: Where KDE looks for applications, the user's own folder first.

#### Entry lists LokalBot under Virtual Keyboard; packages install same file
`desktop_entry`: The entry that lists LokalBot under Virtual Keyboard, with `exe` as what
Plasma starts. Packages install the same file.

#### Quote exe in Exec when it contains special characters
`exec_program`: `exe` as the program of a desktop entry's `Exec`, quoted when it needs it.

#### NoDisplay keeps it out of the menu; started alone it does nothing
`the_entry_puts_lokalbot_on_plasmas_virtual_keyboard_list_and_nowhere_else`: Not in the applications menu: started alone it would do nothing.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/kwin_helper.rs`

#### KWin gives its input method only to the process it starts; helper holds it and takes keys only while suggestion shows
The input method KWin starts for LokalBot (`lokalbot --kwin-input-method`),
once the user chooses LokalBot under System Settings → Keyboard → Virtual
Keyboard.

KWin offers `zwp_input_method_v1` only to the program it started, over the
connection it handed it, and starts it again only if it crashes. So this
small process holds that connection for the whole session and passes the
active field to the app over the socket in [`super::kwin_wire`]. The app's
route ([`super::kwin`]) does everything else.

The keyboard is taken only while the app shows a suggestion. Then every key
but the accept keys and Esc goes straight back to KWin, and nothing keeps
it. With no app connected this holds no text, takes no keys and shows
nothing, so typing is as it is without an input method. Typed text is never
logged.

#### Exit code is never a crash's so KWin does not restart in a loop
`run`: Runs the helper until KWin closes its connection. The exit code is never
a crash's, so KWin does not start it again in a loop.

#### poll fd array stays valid for the whole call
`run`: SAFETY: `fds` is a valid array for its length, for the whole call.

#### Replace a stale socket; never touch anything else in the way
`listen`: Listens where the app looks. A socket left by a helper that is gone is
replaced; anything else in the way is not touched.

#### Only peers running as this user may connect to the helper socket
`same_user`: Whether the other end of `stream` runs as this user.

#### getsockopt cred and len valid for writes of given sizes
`same_user`: SAFETY: `cred` and `len` are valid for writes of the sizes given.

#### Map text_input_v1 purposes to v3 numbering; hint bits are identical
`content_v3`: `zwp_text_input_v1`'s content purpose, as KWin sends it to an input
method, in `zwp_text_input_v3`'s numbering, which the rest of the route
uses. The hint bits are the same in both.

#### v1 date through terminal shift by one because v3 inserted pin at 9
`content_v3`: date, time, datetime, terminal: v3 has `pin` at 9

#### Unknown purpose is never prose
`content_v3`: Unknown: never prose.

#### A field has focus, or the focused one may now be another
`Pending.field`: A field has focus, or the one in focus may be another now.

#### Serial of the field's last committed state, quoted by requests
`Helper.serial`: The serial of the field's last committed state, which requests quote.

#### Active field content type kept for an app that connects later
`Helper.content`: The active field's content type, for an app that connects later.

#### Taken keys still down: their release and repeats go nowhere
`Helper.taken`: Keys taken and still down: their release and repeats go nowhere.

#### Serial and time of last key used for keys typed on app's behalf
`Helper.last_key`: The serial and time of the last key, for keys typed on the app's behalf.

#### One app at a time; the newest is the one still running
`Helper::accept`: One app at a time: the newest is the one still running.

#### Without an app, typing behaves as with no input method
`Helper::drop_app`: Back to typing as if there were no input method.

#### KWin applies deletion of index to index plus length around caret at once
`Helper commit handling`: KWin applies a deletion of [index, index + length]
around the caret at once.

#### Preedit before caret; empty clears and prompts quiet field to report text
`Helper::show`: Shows `text` in the field, in front of the caret's way. Empty clears it,
which also prompts a quiet field to report its text.

#### Preedit cursor stays before the suggestion where the user types
`Helper::show`: The caret stays where the user is typing, before the suggestion.

#### Preedit empty style so losing focus commits nothing; suggestion is not text
`Helper::show`: Nothing to commit if the field loses focus: a suggestion is not text.

#### Toolkits may commit preedit on a key; clear suggestion first, app restores
`Helper key handling`: Toolkits may commit preedit when a key arrives, so the
suggestion leaves first. The app puts it back if it
still applies.

#### A field that came and went before being passed on never existed
`Helper::event`: A field that came and went before it was passed on never was.

#### Debug log names event kind only, never text
`Helper::event`: The kind of event only: never the text.

#### Surrounding text held only until passed on, only for reading apps
`Helper::event`: Held only until passed on, and only for an app that reads.

#### Reset may mean another field, so app re-asks; content type says nothing
`Helper::event`: Moving to another field or window deactivates and activates the
context. A text input enabled again resets it, which may also be
another field, so the app asks again whose it is. The content
type comes with most keystrokes and says nothing about that.

#### v1 password equals v3 password; v3 inserted pin at 9
`content_purposes_from_text_input_v1_land_on_v3s_numbers`: v1 password (8) is v3 password (8); v3 inserted `pin` at 9.

#### Socket file outlives the helper that made it
`a_stale_socket_is_replaced_and_anything_else_is_left_alone`: The socket file outlives the helper that made it.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/kwin_wire.rs`

#### KWin helper holds the input method; app talks to it over a socket
What LokalBot and its KWin input method helper say to each other.

KWin talks `zwp_input_method_v1` only to a program it starts itself and
keeps that connection for as long as the program runs. So a small helper
(`lokalbot --kwin-input-method`) holds it for the whole session, and the app
connects to the helper over a socket in its private runtime folder. Quitting
and reopening LokalBot then leaves the desktop's input method in place.

One JSON object per line. The helper sends text from around the caret only
while the app has asked for it ([`Request::Reading`]), and keeps none of it
once sent.

#### Bump version when message meaning changes; mismatched releases do not talk
`VERSION`: Changes whenever a message changes meaning. An app and a helper from
different releases (one updated while the other kept running) do not talk.

#### Line cap is far above the longest message, about 4,000 bytes escaped
`MAX_LINE`: No message comes close: the longest carries the 4,000 bytes or so of text
an app reports around the caret, escaped.

#### Unsent bytes beyond this mean the peer stopped reading
`MAX_OUTBOX`: Unsent messages beyond this mean the other side stopped reading.

#### Events flow from the KWin helper to the app
`Event`: From the helper to the app.

#### Field also means the focused field may now be a different one
`Event::Field`: A text field has focus, or the one in focus may be another now.

#### Content type uses zwp_text_input_v3 numbering; offsets are bytes
`Event::State`: The field's next state. The content type uses `zwp_text_input_v3`'s
numbering; offsets are in bytes.

#### Only accept keys or Esc are taken, and only while a suggestion shows
`Event::Key`: An accept key or Esc, taken while a suggestion showed.

#### Helper removes the suggestion from the field before passing another key on
`Event::Passed`: Another key went on to the field while a suggestion showed. The helper
took the suggestion out of the field first.

#### Requests flow from the app to the KWin helper
`Request`: From the app to the helper.

#### Caret text is sent only while the app has asked for it
`Request::Reading`: Whether text around the caret may be sent at all.

#### Keyboard is grabbed only while a suggestion shows
`Request::Grab`: Take the keyboard while a suggestion shows; give it back after.

#### Empty preedit text shows no suggestion
`Request::Preedit`: Shows `text` as the suggestion, or nothing when empty.

#### One accept deletes around the caret, types text, then shows preedit
`Request::Commit`: One accept: removes bytes around the caret, types `text`, then shows
`preedit`.

#### A taken key that accepted nothing is typed after all
`Request::PassThrough`: Types a taken key after all, because it accepted nothing.

#### fill returns Ok(false) once the other side has closed
`Inbox::fill`: Reads what is waiting. `Ok(false)` once the other side has closed.

#### A flush error means the link is gone
`Outbox::flush`: Writes what the stream takes now. An error means the link is gone.

#### Test checks tag and round trip, not serde key order
`requests_name_their_kind`: Key order is serde's business; what matters is the tag and the trip.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/surface.rs`

#### Field owner is asked on its own thread and judged before field text is used
Who owns the active field, asked for on a thread of its own so a slow app
or compositor never holds up the keyboard: the compositor names the window
in front, and accessibility adds what it knows about the field. Also looks
out for other input methods, since a desktop runs one at a time.

The owner is judged before the field's text is used. An app that cannot be
named is ruled out.

#### Session bus names owned by input-method daemons keep the check within this session
`OTHER_INPUT_METHODS`: Session bus names of input methods. Their daemons own these for as long as
they run, and looking here stays within this desktop session.

#### With scan, keep looking for other input methods where only one can run
`surface::run`: Answers questions until told to stop. With `scan`, it also keeps looking for
other input methods, for a route where only one can run.

#### Only the newest queued question is answered
`surface::run`: Only the newest question matters.

#### Text above the field is read once per field and page
`Reader.visible`: Text above the field, read once per field and page.

#### GNOME names the front window only via an extension; accessible apps still self-report
`Reader::front_window`: GNOME names the window in front only through an extension. Apps that
publish accessibility can still say for themselves.

#### A later activation drops the previous field's cached text
`Reader::read`: A later activation means this field is gone, and its text with it.

#### Judge identity first, then field kind, in the X11 watcher's order
`judge`: Decides what the owner and accessibility say about a field, in the order
the X11 watcher does: identity first, then the field's kind.

#### LokalBot's own pid is refused because the practice editor feeds the engine itself
`judge`: The practice editor feeds the engine itself.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/input_method/wlroots.rs`

#### Grab keyboard only while a suggestion shows; yield seat to other input methods
The input method on Sway and Hyprland: `zwp_input_method_v2`, plus
`zwp_virtual_keyboard_v1` for giving keys back.

The keyboard is grabbed only while a suggestion shows. While it is, every
key but the accept keys and Esc goes straight on through the virtual
keyboard and nothing keeps it.

A known input method starting later makes this route let go of the seat at
once and say why, as does the compositor reporting that someone else holds
it. It takes the seat again only when that other one has been gone for a
while. A session that has only just started gets a moment first, so that one
starting alongside LokalBot does not lose the seat to it.

This thread does no blocking work: while the keyboard is grabbed, the
user's typing goes through it.

#### Grab waits up to 3 s for keys still down after the ghost goes
`GRAB_RELEASE_LIMIT`: How long the grab waits for keys still down once the ghost has gone.

#### Settle period is measured from the compositor socket's age
`SESSION_SETTLE`: Measured from the compositor's socket.

#### Retake the seat only after this many scans with no other input method
`QUIET_SCANS_BEFORE_RETAKING`: Scans with no other input method before taking the seat back.

#### Retry delay after the compositor says someone unknown holds the seat
`UNAVAILABLE_RETRY`: How long before asking again after the compositor said someone else holds
the seat, without knowing who.

#### zwp_input_method_v2 strings must stay below 4000 bytes
`MAX_STRING`: `zwp_input_method_v2` carries strings below 4000 bytes.

#### Keymaps over 8 MiB are rejected as implausible
`MAX_KEYMAP`: Keymaps larger than this are not keymaps.

#### XKB keycodes are evdev scancodes plus 8
`XKB_OFFSET`: XKB keycodes are evdev scancodes plus this.

#### Full-accept key is KEY_GRAVE, the physical key left of 1
`EVDEV_GRAVE`: `KEY_GRAVE`, the physical key left of 1.

#### Compositor support cannot change in a session, so it is asked once
`offered_by_compositor`: Whether this compositor offers what the route needs. It cannot change
within a session, so it is asked once.

#### libc::poll fds array stays valid for the whole call
`run`: SAFETY: `fds` is a valid array for its length, for the whole call.

#### Caps Lock and Num Lock are locks, not held modifiers
`Modifiers::plain`: Caps Lock and Num Lock are locks, not held: a plain key stays plain.

#### Key identities come from the keymap; full-accept is the physical key left of 1
`Keymap::read`: Reads a keymap the compositor shared. Which keys are which depends on
it (Caps Lock can be Escape), except the full-accept key, which is the
physical key left of 1 whatever it types, like the Mac's key code 50.

#### Event state is applied only at the next done event
`Pending`: State set by events until the next `done`.

#### App wants the keys while a suggestion is on show
`Wayland.wants_grab`: The app wants the keys, so a suggestion is on show.

#### Tracks keys given back and still held, by scancode
`Wayland.down`: Keys given back and still down, by scancode.

#### Release of a taken key goes nowhere
`Wayland.taken`: Keys taken and still down: their release goes nowhere.

#### Each commit quotes the count of done events
`Wayland.serial`: Count of `done` events, which each commit quotes.

#### Preedit caret stays where the user types, in front of the ghost
`Wayland::preedit`: The caret stays where the user is typing, in front of the ghost.

#### Preedit does not persist between commits, so it is set again
`Wayland::commit`: Preedit does not last from one commit to the next.

#### Keys still down keep repeating, so release waits up to a limit
`Wayland::set_grab`: Keys still down keep repeating until they come up.

#### Returns false to stop the loop
`State::command`: False to stop.

#### Timeout in milliseconds until tick has work, -1 for none
`State::poll_timeout`: Milliseconds until `tick` has work, or -1 for none.

#### When someone else holds the seat, nothing of ours stays on it
`State::let_go_of_seat`: Someone else holds the seat, or will: nothing of ours stays on it.

#### New sessions get a grace period before the seat is taken
`session_settle_left`: How much longer to wait before taking the seat, while the session is new.

#### Text of an already ruled-out field is not even held
`event`: A field already ruled out: its text is not even held.

#### Test keymap is a US layout with Caps Lock remapped to Escape
`tests::KEYMAP`: The core of what `xkbcomp` writes for a US layout, with Caps Lock as
Escape, as `caps:escape` does.

#### Scancodes are keymap keycodes minus eight
`keys_are_read_from_the_keymap`: Scancodes are the keycodes above minus eight.

#### Full-accept key is the physical key left of 1 whatever it types
`keys_are_read_from_the_keymap`: The physical key left of 1, though it types no backtick here.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/mod.rs`

#### Autocomplete desktop side: watcher, key interceptor, insert, privacy and Wayland rules
Autocomplete's desktop side (`LokalBot/Cotyping`): reading the text field
the user types in, taking Tab and Esc while ghost text shows, and typing
an accepted suggestion into the field. Prediction lives in the engine.

- [`FieldWatcher`] follows the focused field on its own thread: AT-SPI2
  events on Linux, UI Automation events on Windows, each with a polled
  fallback that backs off while nothing changes. Every snapshot holds the
  app, the window title, the bounded text around the caret, the caret on
  screen, and whether the field is secure or single-line.
- [`KeyInterceptor`] takes the plain accept keys and Esc only while it is
  active, which the app keeps true exactly while a suggestion is visible:
  `XGrabKey` on X11, a low-level keyboard hook on Windows.
- [`insert`] types an accepted chunk at the caret: AT-SPI `EditableText`
  when the field supports it, else XTest; `SendInput` Unicode keystrokes on
  Windows. Never through the clipboard.

- [`clipboard`] and [`spell`] read the clipboard for prompt context and
  check words against the system's dictionaries.

Privacy (`PRIVACY.md`): nothing is read while autocomplete is off, secure
fields and excluded apps are never read (the check runs before any text
is), LokalBot's own windows are skipped, and nothing read is kept on disk.

Wayland lets no app take a key from another app or place a window at
another app's caret, so there autocomplete takes part as the desktop's
input method where it can (`input_method`), and the field draws the ghost
itself ([`InlineGhost`]). Where it cannot, [`support`] says so; LokalBot's
own practice editor still works.

#### Blocked means editable but withheld: secure field or selected text
`Capability::Blocked`: Editable, but withheld: a secure field or selected text.

#### Snapshot never contains text from secure fields or excluded apps
`FieldSnapshot`: The focused field, read once (`CotypingField`). Never contains text from
a secure field or an excluded app.

#### Toolkit element identity; empty when it has none
`FieldSnapshot.focus_key`: The toolkit's identity for the element (bus name and object path, or
UI Automation runtime id). Empty when it has none.

#### App id is a desktop id, WM_CLASS or executable name
`FieldSnapshot.app_id`: Desktop id, `WM_CLASS` or executable: "org.gnome.TextEditor", "notepad.exe".

#### Text before the caret is capped at MAX_BEFORE_UTF16 units
`FieldSnapshot.before`: Text before the caret, at most [`policy::MAX_BEFORE_UTF16`] units.

#### Text after the caret is capped at MAX_AFTER_UTF16 units
`FieldSnapshot.after`: Text after the caret, at most [`policy::MAX_AFTER_UTF16`] units.

#### Caret is in screen pixels, top-left origin, zero width
`FieldSnapshot.caret`: The caret in screen pixels (top-left origin). Zero width.

#### False when the caret was estimated from the field frame
`FieldSnapshot.caret_exact`: False when the caret was estimated from the field's frame.

#### Single-line input where Enter usually sends
`FieldSnapshot.single_line`: A one-line input, where Enter usually sends.

#### xterm.js surface detected by a DOM class starting with xterm
`FieldSnapshot.is_integrated_terminal`: An xterm.js surface in an editor or a browser: a DOM class starting
with "xterm" (`CotypingSurfaceClassifier.isIntegratedTerminal`).

#### Page address set only when the app is a browser and it could be read
`FieldSnapshot.url`: The page address when the app is a browser and it could be read.

#### Text just above the field is read once per field when allowed
`FieldSnapshot.visible_text`: Text shown just above the field, read once per field when allowed.

#### AT-SPI bus name and path, set when field supports EditableText
`InsertTarget.editable`: AT-SPI bus name and object path, when the field supports `EditableText`.

#### Watcher's focus view, counterpart of the Mac CotypingFocus
`FocusSnapshot`: The watcher's view of focus (`CotypingFocus`).

#### Field is set only for Capability::Supported
`FocusSnapshot.field`: Set only for [`Capability::Supported`].

#### Element identity is kept even when its text is withheld
`FocusSnapshot.focus_key`: The element's identity even when its text is withheld.

#### Reason string is worded for Settings
`Support::Unavailable`: Why not, worded for Settings.

#### Cheap to call; intended for when Settings opens
`support`: What this desktop allows. Cheap; call it when Settings opens.

#### Makes LokalBot a GNOME input source for installs no package set up
`ibus_component`: The file that makes LokalBot one of GNOME's input sources, for installs
that no package put it in place for (`lokalbot --ibus-component`).

#### Plasma starts the helper once the user picks LokalBot as Virtual Keyboard
`run_kwin_input_method`: Runs the input method KDE Plasma starts for LokalBot (`lokalbot
--kwin-input-method`) until Plasma stops it, and returns the exit code.
Plasma starts it once the user chooses LokalBot under System Settings →
Keyboard → Virtual Keyboard.

#### Desktop entry lists LokalBot under Virtual Keyboard for installs without a package
`kwin_input_method_entry`: The desktop entry that lists LokalBot under Plasma's Virtual Keyboard, for
installs that no package put it in place for (`lokalbot
--kwin-input-method-entry`).

#### Command to run once in a terminal first, to copy
`InputSourceSteps.command`: A command to run once in a terminal first, to copy.

#### Steps exist only where autocomplete uses the input method; None elsewhere
`input_source_steps`: The steps where autocomplete goes through the desktop's input method.
`None` elsewhere: nothing to do beyond turning it on.

#### Handler runs on the watcher thread; forward to UI thread
`FieldWatcher`: Follows the focused field on a background thread until dropped. The
handler runs on that thread whenever the snapshot changes; forward it to
the UI thread.

#### New exclusions apply at once; next snapshot follows them
`FieldWatcher::set_policy`: Applies new exclusions at once; the next snapshot follows them.

#### Limitation text is worded for Settings
`FieldWatcher::limitation`: What the backend cannot do on this desktop, worded for Settings.

#### Field draws the ghost itself on Wayland input method; None with own overlay
`FieldWatcher::inline_ghost`: The way to draw the ghost where the field draws it itself, as on a
Wayland input method. `None` where LokalBot's own overlay does.

#### Non-blocking inline suggestion that accepts with what remains
`InlineGhost`: A suggestion the field draws itself, and accepts that go in with what
remains of it. Non-blocking.

#### Edit and next remainder are applied in one step against given context
`InlineGhost::accept`: Makes `edit` at the caret and shows `next` as what is left, in one
step. `before` and `after` are the field's text around the caret as
the edit expects it.

#### Physical key left of 1 whatever it types, like Mac key code 50
`InterceptedKey::Backtick`: The physical key left of 1, whatever it types on this layout, like the
Mac's key code 50.

#### Primary key wins when both accept keys are the same
`AcceptKeys`: What the accept keys are bound to. The primary key wins when both are the
same key (`CotypingAcceptHint`, `acceptScope`).

#### Escape is always one of the taken keys
`AcceptKeys::taken`: Every key to take while a suggestion shows. Escape is always one.

#### Some(true) for full accept, Some(false) for chunk, None when it accepts nothing
`AcceptKeys::is_full`: Whether `key` takes the rest of the suggestion rather than the next
chunk; `None` when it accepts nothing.

#### Inactive interceptor holds no grab or hook
`KeyInterceptor`: Takes the plain accept keys and Esc away from the focused app while
active. Inactive it holds no grab or hook, so the keyboard is untouched.

#### Key changes apply at once even while active
`KeyInterceptor::set_keys`: Which keys accept, applied at once even while active.

#### Deactivating releases the keys at once
`KeyInterceptor::set_active`: Takes the keys while `true`; releases them at once when `false`.

#### Unused taken keys go on to the app so Tab still moves focus
`KeyInterceptor::pass_through`: Sends a key that was taken but not used on to the focused app, so a
Tab pressed as a suggestion went away still moves focus (macOS fails
open the same way).

#### Deletions count grapheme clusters around the caret
`Edit`: One edit at the caret: delete `backward` characters (grapheme clusters)
before it and `forward` after it, then type `text`.

#### Blocks briefly, needs a background thread, refuses other apps' focus
`insert`: Applies `edit` to `field`, which must still have focus. Blocks for the
few milliseconds the app takes; call from a background thread. Refuses
rather than typing into another app.

#### Accept deletions capped at 64 characters, as on macOS
`insert`: A burst of deletions from one accept stays small, as on macOS
(`CotypingSyntheticEditPolicy`).

#### Ghost window is click-through, never activated, hidden from capture on Windows
`prepare_overlay`: Makes the ghost window click-through, never activated by a click, and
(on Windows, when `exclude_from_capture`) left out of screenshots and
recordings, as macOS does with `sharingType = .none`.

#### Places and shows or hides the ghost without activating it
`place_overlay`: Moves and sizes the ghost window to `frame` (screen pixels) and shows or
hides it, without activating it.

#### Per-monitor scale only on Windows; X11 has one screen-wide scale
`scale_at`: Device pixels per logical pixel on the monitor showing `rect`, where the
system keeps a scale per monitor (Windows). `None` elsewhere: X11 has one
scale for the whole screen, which the ghost window already reports.

#### Work area keeps ghost text and pills on screen
`screen_containing`: The work area of the monitor showing `rect`, in screen pixels, so ghost
text and pills stay on screen.

#### Luminance 0-1 behind the ghost keeps it legible; None if unreadable
`sample_luminance`: The luminance (0–1) of the screen just behind where ghost text would go,
to keep it legible on fields whose colors the toolkit does not report.
`None` when the screen cannot be read.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/policy.rs`

#### Pure policy module mirroring several Swift Cotyping policy files
What autocomplete may read and where it may suggest, kept pure so it is
testable without a desktop: the app read policy, secure and search field
detection, the bounded text windows around the caret, site exclusions,
focus smoothing and the field identity that suggestions are anchored to
(`CotypingAXPolicies.swift`, `CotypingAvailability.swift`,
`CotypingBrowserDomain.swift`, `CotypingFieldIdentity.swift`,
`CotypingFocusPollBackoff.swift`, `CotypingFocusCapabilityFlickerGate.swift`).

#### Preceding text cap of 4096 UTF-16 units matches macOS
`MAX_BEFORE_UTF16`: Text before the caret, in UTF-16 units, as on macOS
(`CotypingAcceptanceContentBounds.maximumPrecedingUTF16Length`).

#### A field stays quiet 10 s after Escape, as on macOS
`ESCAPE_PAUSE`: How long a field stays quiet after Escape (`CotypingEscapeBehavior.pauseSeconds`).

#### Reason strings use the Mac status line wording
`reasons`: Why a field gets no suggestion, as macOS words it in its status line.

#### App exclusions authorize the read before any text exists
`ReadPolicy`: Who may be read at all. App exclusions authorize the read itself, before
any field text exists (`CotypingAppReadPolicy`): an excluded app's fields
are never read, not read and then dropped.

#### Never-suggest app list maps to cotyping_excluded_apps
`ReadPolicy.excluded_apps`: "Never suggest in these apps" (`cotyping_excluded_apps`).

#### Never-suggest site list maps to cotyping_excluded_domains
`ReadPolicy.excluded_domains`: "Never suggest on these sites" (`cotyping_excluded_domains`).

#### Day memory's never-capture apps also keep surrounding text out of suggestions
`ReadPolicy.capture_excluded_apps`: Day memory's "Never capture these apps", which also keeps the text
around a field out of a suggestion (`CotypingVisibleContext.Policy`).

#### Day memory's never-capture sites list
`ReadPolicy.capture_excluded_domains`: Day memory's "Never capture these sites".

#### Text above the field is read for context, never on the Tab path
`ReadPolicy.visible_text`: Read the text shown above the field, such as the conversation being
answered. Never on the Tab path.

#### Whole focused window may be read from pixels; the engine does the reading
`ReadPolicy.window_text`: The whole focused window may be read from its pixels
(`cotyping_use_window_text`); the engine does the reading.

#### Reads field font and colors per cotyping_match_host_style
`ReadPolicy.match_host_style`: Read the field's font and colors (`cotyping_match_host_style`).

#### Allows suggestions in xterm.js surfaces per its setting
`ReadPolicy.suggest_in_integrated_terminals`: Suggest in xterm.js surfaces (`cotyping_suggest_in_integrated_terminals`).

#### Unknown owners fail closed
`ReadPolicy::allows_app`: Whether `app_name`/`app_id` may be read. Unknown owners fail closed.

#### Surrounding text needs field rules plus capture exclusions, private windows and unreadable browsers out
`ReadPolicy::allows_visible_text`: Whether the text around the field may join a suggestion: the field's
own rules plus day memory's capture exclusions, with private windows
and browsers whose page cannot be read left out
(`CotypingVisibleContext.Policy.permits`).

#### Window pixel text follows the same rule but needs its own grant
`ReadPolicy::allows_window_text`: The same rule for text read from the focused window's pixels. Each
source needs its own grant.

#### Exclusion is a case-insensitive substring of app name or id
`is_excluded`: Case-insensitive substring of the app name or id
(`CotypingAvailability.isExcluded`).

#### A DOM class starting with xterm marks an xterm.js surface
`is_integrated_terminal`: Whether a DOM class list marks an xterm.js surface
(`CotypingSurfaceClassifier.isIntegratedTerminal`).

#### Terminal emulators are excluded because history and completions fight ghost text
`is_terminal_app`: Terminal emulators: their history and completions fight ghost text
(`CotypingSurfaceClassifier` `.terminal`).

#### Secure check errs toward hiding; a false negative could show a secret
`is_secure_field`: Conservative secure-field check over every label a toolkit exposes. A
false positive only hides autocomplete; a false negative could show a
secret as ghost text (`CotypingSecureFieldDetector`).

#### Verification code fields stay quiet; whole-word match so pin never matches pinned
`is_code_field`: Fields for a verification code, PIN or one-time password stay quiet: a
code is not prose to continue. Pages often name such a field only through
its placeholder, label or element id, so callers pass those too. Matches
whole words, so "pin" never matches "pinned". A false positive only hides
autocomplete in one field (`CotypingCodeFieldDetector`).

#### Serbian, Croatian and Bosnian code words in Latin and Cyrillic
`is_code_field`: Serbian, Croatian and Bosnian, in Latin and Cyrillic.

#### Split labels at non-alphanumerics and camelCase humps so element ids read as words
`label_words`: Lowercased words, split at anything that is not a letter or digit and at
camelCase humps, so the element ids `otpInput`, `SMSCode` and
`verification-code` read as words too (`CotypingCodeFieldDetector.words`).

#### Search boxes stay quiet; Tab there belongs to the results
`is_search_field`: Search boxes stay quiet: a query is not prose to continue, and Tab there
belongs to the results (`CotypingSearchFieldDetector`). `roles` are the
toolkit's role names, ARIA roles and input types.

#### Clipped window drops its outermost grapheme because the cut may split it
`bounded_before`: The bounded text before the caret. `read_truncated` says the reader
already left out text before what it returned. A clipped window drops its
outermost grapheme, which the cut may have split
(`CotypingAcceptanceContentBounds.context`).

#### Caret at line end when nothing follows or a line break follows
`caret_at_end_of_line`: Whether the caret is at the end of its line: nothing follows it, or what
follows starts with a line break (`CotypingRenderModePolicy.isCaretAtEndOfLine`).

#### Lowercased host without www; None for addresses with no network host
`host_from_url`: Lowercased host of a page address without a leading `www.`; `None` for
addresses without a network host (`CotypingBrowserDomain.host`).

#### Site rule covers the host and subdomains; rules may be pasted URLs
`is_host_disabled`: Whether a host is covered by a site rule: the same host or a subdomain of
it. Rules may be pasted as full URLs (`CotypingBrowserDomain.isHostDisabled`).

#### Returns why focus gets no suggestion, or None when allowed
`disabled_reason`: Why `focus` gets no suggestion, or `None` when it may
(`CotypingAvailability.disabledReason`).

#### Site rules are a privacy boundary: unreadable browser page pauses, never allows
`disabled_reason`: A site rule is a privacy boundary: a browser whose page cannot be read
is paused, never treated as allowed.

#### Field identity uses element id, else frame, else title, never content
`field_identity`: Identity of "the same field" across snapshots: the toolkit's own element
identity, else the field frame, else the window title. Content is left
out so typing through a suggestion keeps it (`CotypingFieldIdentity`).

#### Poll fallback slows after repeated captures that changed nothing
`PollBackoff`: Cotabby's idle backoff for the poll fallback: full speed after activity,
slower after repeated captures that changed nothing
(`CotypingFocusPollBackoff`).

#### Smooth one supported-selected-supported blip; never smooth secure fields
`FlickerGate`: Smooths one `supported → selected → supported` blip on the same element:
some apps briefly report a selection while redrawing the caret, which
would tear the ghost down and rebuild it. Secure fields are never
smoothed (`CotypingFocusCapabilityFlickerGate`).

#### True delivers the focus; false keeps the previous one for now
`FlickerGate::apply`: True to deliver `focus`, false to keep the previous one for now.

#### Prefer the previous character's trailing edge because apps misreport the empty range
`choose_caret`: Picks the caret from what a field reports for the empty range at the
caret and for the character before it: that character's trailing edge
when it is one glyph inside the field, else the empty range. Several apps
report the empty range a line off or with no size, while the character
before the caret is where it is drawn (`CotypingCaretGeometry.caret`).

#### A collapsed caret rect is narrow, not a whole line or field
`is_collapsed_caret`: Whether a rect reported for the collapsed selection is a caret rather
than a whole line or field (`CotypingCaretGeometry.isCollapsedCaret`).

#### Escape pauses one field and never follows the user to another
`EscapePause`: Escape keeps one field quiet for a while; it never follows the user to
another field (`CotypingCoordinator.isPausedByEscape`).

#### Duplicates the engine's RTL check because this crate does not depend on it
`is_right_to_left`: Right-to-left when the last strong character is Hebrew or Arabic
(`CotypingTextDirectionDetector`), for choosing the caret's edge. The
engine's `lokalbot_ai::autocomplete::is_right_to_left` does the same for
placing the ghost; this crate does not depend on that one.

#### Browser with unreadable page abstains from window text
`window_text_has_its_own_grant_and_the_same_exclusions`: A browser whose page cannot be read abstains.

#### Built-in exclusions hold even when the user cleared the list
`excluded_apps_password_managers_terminals_and_self_are_never_read`: Built in even when the user cleared the list.

#### Exclusion matching is case-insensitive substring of name or id, as on macOS
`excluded_apps_password_managers_terminals_and_self_are_never_read`: Substring of the name or the id, case-insensitive, as on macOS.

#### Policy off or unknown owner reads nothing
`excluded_apps_password_managers_terminals_and_self_are_never_read`: Off, or an unknown owner, reads nothing.

#### Over-long text keeps last 4096 units minus outer grapheme
`context_windows_are_bounded_like_macos`: Too long: the last 4096 units, minus the outer grapheme.

#### A reader that already clipped may have split the first grapheme
`context_windows_are_bounded_like_macos`: A reader that clipped already: the first grapheme may be split.

#### Counting is UTF-16; astral characters take two units
`context_windows_are_bounded_like_macos`: UTF-16 counting: astral characters take two units.

#### A site rule pauses a browser whose page cannot be read
`availability_follows_macos`: A site rule pauses a browser whose page it cannot read.

#### Private windows and browsers with unreadable pages abstain
`visible_text_needs_its_own_grant_and_a_readable_page`: Private windows and browsers without a readable page abstain.

#### Day memory's capture exclusions also apply to visible text
`visible_text_needs_its_own_grant_and_a_readable_page`: Day memory's capture exclusions apply too.

#### Field frame stands in when there is no toolkit identity
`identity_ignores_content`: Without a toolkit identity the frame stands in.

#### Previous character's trailing edge beats a misplaced empty range
`caret_prefers_the_character_before_it`: The previous character's trailing edge wins over a misplaced range.

#### Whole-line or outside-field characters are not trusted without a confirming range
`caret_prefers_the_character_before_it`: A whole line is not one glyph; a character outside the field with no
range to confirm it is not trusted.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/session.rs`

#### Typing or showing the ghost's start shortens it at once; else it is left behind
The suggestion on screen and how the field's next state moves it, kept
pure (`CotypingSession`, `CotypingSessionReconciler.swift`,
`CotypingRehearsal` in `CotypingContinuationAcceptance.swift`).

Typing the next characters of the ghost, or the app showing text an accept
inserted, shortens the ghost at once; anything else leaves it behind.

#### Reads from before an accept arrives are not treated as a change
`GhostSession.awaiting`: The text before the caret when the oldest accept the app has not
shown yet was made. Reads from before it arrives are not a change
(`shouldAwaitPostInsertionSync`).

#### Advanced covers the user typing or the app showing the ghost start
`Reconcile::Advanced`: The user typed, or the app showed, the start of the ghost.

#### Reconcile against the field's new text before the caret
`GhostSession::reconcile`: Moves the suggestion to `before`, the field's new text before the
caret (`sessionReconciledByPublishedTyping`).

#### An accept the app has shown only partly or not at all is unchanged
`GhostSession::reconcile`: An accept the app has shown only part of, or none of, yet.

#### Ghost advances before the app shows text so a quick second Tab takes the next chunk
`GhostSession::accept`: An accept took `chunk` (the start of `remaining`) and typed
`insertion` after deleting `backward` user-perceived characters
before the caret (an emoji's `:shortcode`). The ghost moves on before
the app shows the text, so a quick second Tab takes the next chunk.
Returns false when `chunk` is not the start.

#### After stopping the wait, the next read not showing the accept leaves the ghost behind
`GhostSession::stop_awaiting`: Stops waiting for an accept to arrive in the field: the next read
that does not show it leaves the suggestion behind.

#### Clipped windows move, so the anchor tail is searched in the new text
`typed_since`: The text typed after `anchor` to reach `before`. For clipped windows,
whose start moves as the text grows, the anchor's tail is found in
`before` instead (`hasCappedPrefixWindowOverlap`).

#### Drops graphemes from text after caret once an accept replaced the rest of a word
`drop_graphemes`: `text` without its first `count` user-perceived characters: the text
after the caret once an accept replaced the rest of a word.

#### Inline preedit shows only the first line within the protocol limit; whole suggestions must fit entirely
`inline_text`: The part of a suggestion a field can draw inline, in preedit: its first
line, up to what an input method's protocol carries. `None` when `whole`
suggestions (which show entire or not at all) do not fit.

#### Limit stays below zwp_input_method_v2's 4000 bytes on a char boundary
`inline_text`: Below the 4000 bytes of `zwp_input_method_v2`, on a character boundary.

#### Recent contexts per field let late suggestions fit the current text
`SentContexts`: Contexts recently sent for one field, newest last, so a suggestion that
arrives after more typing can be fitted to the field's current text.

#### A late suggestion starts with text already typed, which is dropped
`SentContexts::fit`: `suggestion` as it continues `latest`. A suggestion made for an
earlier context that the user has since typed into starts with what
was typed; that part is already in the field.

#### Reads from before the insert or partial ones keep waiting for the app
`accepting_moves_the_anchor_before_the_app_shows_it`: A read from before the insert arrived, then a partial one: still
waiting for the app.

#### Typed text may differ from the chunk, such as a space the field had
`accepting_moves_the_anchor_before_the_app_shows_it`: The typed text may differ from the chunk (a space the field had).

#### A clipped window shifts one character per typed character
`clipped_windows_still_follow_typing`: The window moved by one character as one was typed.

#### A suggestion made for older text drops the space typed since
`late_suggestions_fit_the_text_typed_since`: Made for "Hello" and arriving after the space: the space is typed.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/spell.rs`

#### Dictionaries load in the background; until then no word is a typo
Spell checking for autocomplete's typo offers and seam guard, the
counterpart of `NSSpellChecker`: the system's Hunspell dictionaries through
spellbook on Linux, `ISpellChecker` on Windows. Only non-words are flagged.

Dictionaries load in the background. Until they have, and without any, no
word is a typo and [`SpellChecker::languages`] is empty, so every rule that
depends on a verdict stands down.

#### Check at most four languages; a typo needs every one to flag it
`MAX_LANGUAGES`: At most this many languages are checked, the user's own first: a word is a
typo only if every one of them flags it.

#### One dictionary per language, preferred first, then the most usual variant
`choose_languages`: Which installed dictionaries to use: at most one per language, the
`preferred` ones first, then the most usual variant of each other language.

#### Prefer a language's own country variant, then US English
`choose_languages`: "en_US" before "en_AU": a language's own country first, then US English.

#### Only whole words are checked because NSSpellChecker does not flag tokens like wrld,
`is_checkable`: Words a checker can judge whole. `NSSpellChecker` finds the misspelled word
inside a token, so "wrld," or "foo-bar" is not flagged whole there; a
checker asked about the token would call it a typo.

#### Handle is cheap and calls never block for long
`SpellChecker`: A cheap handle on the system's spell checker. Calls never block for long.

#### Languages list is empty while loading or without a dictionary
`SpellChecker::languages`: The languages in use, as `en_US` or `en-US`. Empty while loading and
when this computer has no dictionary.

#### Result is cached because Settings asks on every redraw
`has_dictionaries`: Settings asks on every redraw, so the folders are looked at once.

#### Dictionaries are UTF-8 unless their SET line says otherwise
`decode`: Dictionaries are UTF-8 or say otherwise on their `SET` line.

#### A slow answer counts as not a typo because this runs on the worker
`REPLY_TIMEOUT`: A slow answer counts as "not a typo": this runs on the worker.

#### Windows ships its own dictionaries
`has_dictionaries`: Windows brings its own dictionaries.

#### COM objects stay on one thread behind this handle
`Backend`: COM objects stay on one thread behind this handle.

#### CoInitializeEx is paired with CoUninitialize at thread end
`Backend::start`: SAFETY: paired with CoUninitialize at the end of this thread.

#### CoUninitialize matches the earlier CoInitializeEx
`Backend::start`: SAFETY: matches the CoInitializeEx above.

#### Buffer holds the one element asked for
`enumerate`: SAFETY: the buffer holds the one element asked for.

#### Next returned a valid string that the caller must free
`enumerate`: SAFETY: Next returned a valid string, ours to free.

#### Buffer outlives the locale call
`preferred_language`: SAFETY: the buffer outlives the call.

#### COM calls run on the thread that initialized COM
`checkers`: SAFETY: COM calls on this thread, which initialized COM.

#### COM calls run on the thread that made the checker
`flags_whole_word`: SAFETY: COM calls on the thread that made the checker.

#### COM calls run on the thread that made the checker
`suggestions`: SAFETY: COM calls on the thread that made the checker.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/uia.rs`

#### UIA watcher follows focus via events, polls, checks privacy before text, caret fallbacks
Windows: the focused field through UI Automation (`CotypingAXHelper`,
`CotypingFocusTracker`).

A focus-changed handler follows focus, and the focused element gets
text-changed and text-selection-changed handlers while it has focus.
Reads run on the watcher's own thread, coalesced, and the last field is
polled with Cotabby's backoff for providers that raise no events.
Exclusions are checked from the owning process, and secure fields from
`IsPassword` and their labels, before any text is requested.

The caret comes from the text pattern: the character before the caret,
else the collapsed selection, else the system caret (`GetGUIThreadInfo`),
else an estimate at the field's leading edge.

#### Poll cadence 200 ms before backoff, matching macOS focus tracker
`POLL_INTERVAL`: Poll cadence before backoff (`CotypingFocusTracker.defaultIntervalMs`).

#### Events within 8 ms of each other are read once
`COALESCE`: Events arriving this close together are read once.

#### UI Automation gives up on a stuck app after 1 s
`PROVIDER_TIMEOUT_MS`: UI Automation gives up on a stuck app after this.

#### Watcher thread joins the multi-threaded COM apartment for its whole life
`Watcher::start thread`: SAFETY: this thread joins the multi-threaded apartment for
its whole life and leaves it at the end.

#### Fixed holds what is read once per focused element
`Fixed`: What is read once per focused element.

#### Text read from around a field is forgotten when focus leaves it
`Reader::follow_focus`: Text read from around a field is forgotten when focus leaves it.

#### Handlers are removed from the same element they were added to
`Reader::watch_text`: SAFETY: COM calls on this thread's objects; handlers are removed
from the element they were added to.

#### Identity, privacy and field kind are read from metadata only
`Reader::read_fixed`: Identity, privacy and the field's kind, from metadata only.

#### Secure fields are judged before any text is touched
`Reader::read_fixed`: Secure fields: never read, judged before any text is touched.

#### Code and PIN fields judged by name before text; Chromium reports DOM id as automation id
`Reader::read_fixed`: Verification codes, PINs and one-time passwords, judged from
the field's names before its text is read. Chromium reports
the DOM id as the automation id.

#### Chromium reports the DOM class list as the class name
`Reader::read_fixed`: Chromium reports the DOM's class list as the class name.

#### Chromium and Firefox report page address as the document's value
`Reader::document_url`: The page address of a browser: Chromium and Firefox report it as the
value of the document around the field.

#### Estimate a thin caret at the field's leading edge, as macOS does
`Reader::read_text`: A thin caret at the field's leading edge, as macOS estimates.

#### COLORREF is laid out 0x00BBGGRR
`colorref`: `COLORREF` is 0x00BBGGRR.

#### Win32 edits without ES_MULTILINE are single-line; documents multi-line; others by height
`single_line`: Single-line for Win32 edit controls without `ES_MULTILINE`; documents
are multi-line; other edits are decided from their height later.

#### System caret comes from GetGUIThreadInfo in screen pixels, only for the owning process
`system_caret`: The system caret of the foreground window's thread, in screen pixels,
when it belongs to `pid` (`GetGUIThreadInfo`).

#### GetBoundingRectangles returns x, y, width, height quadruples of doubles
`first_rect`: The first rect of a `GetBoundingRectangles` array (x, y, width, height
quadruples of doubles).

#### SAFEARRAY access is bracketed by Access/Unaccess and destroyed exactly once
`read_array`: SAFETY: the array came from UI Automation with elements of type `T`;
access is bracketed by Access/Unaccess and the array is destroyed once.

#### Over SSH session 0 there is no focused field; watcher must not hang
`the_watcher_starts_and_stops_without_a_desktop`: Over SSH (session 0) there is no focused field; it must not hang.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/uia/focused.rs`

#### One-shot focused reads run on their own thread joining COM only for that call
One-shot reads of the focused element for dictation and selection actions,
separate from the watcher: identity and privacy, the selection, the text
before the caret, and the text above the field. Each call runs on a thread
of its own, which joins the COM apartment only for that call.

#### One-shot reads use a 400 ms timeout; a stuck app costs one missed read
`PROVIDER_TIMEOUT_MS`: A stuck app costs one missed read.

#### Counting characters to a selection's ends stops at this limit
`MAX_OFFSET`: Counting characters to a selection's ends stops here.

#### Selection offsets are counted without reading any text
`selection_offsets`: A range's start and end as characters from the document's start, counted
without reading any text.

#### Web content keeps its selection on the document around the focus
`read_selection`: Web content keeps its selection on the document around the focus.

#### Return the focused element only if still the bound, non-secure field
`bound_field`: The focused element, when it is still the bound field and not a secure one.

#### Chromium and Firefox report page address as the document's value
`document_url`: The page address of a browser: Chromium and Firefox report it as the value
of the document around the field.

#### Discard text read while focus moved to another field
`visible_text`: Nothing read while focus moved is kept.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/visible.rs`

#### One bounded background walk per field; metadata before text; nothing kept after focus leaves
The text shown just above the focused field, such as the conversation
being answered (`CotypingVisibleContext.swift`). One bounded walk over
the window's accessibility tree runs in the background once per field:
metadata is checked before text, rejected branches are never read, and
only static labels and links in a column above the field count. Nothing
is kept once focus leaves the field.

#### Context column above the field is 600 tall with 24 side margin
`CORRIDOR_HEIGHT`: The column above the field: this tall, and this much wider on each side.

#### Clipping containers include scroll areas, web documents and windows
`NodeKind::ClippingContainer`: A container that clips its children to its frame (scroll areas,
web documents, windows).

#### Toolbars, menus, trees and editable or secure fields are never entered
`NodeKind::Excluded`: Never entered: toolbars, menus, trees, and any editable or secure
field (another field's draft is not context).

#### Walk scope is a container with room above the field, usually its pane
`Target::scope`: A container with room above the field, usually the pane holding it.

#### Up to three excerpts, nearest selected first, shown in reading order joined by pipe
`capture`: Up to three excerpts from just above the field, nearest first in
selection and in reading order in the result, joined by " | ".

#### Reject credentials and instruction-like text; strip control chars; cut at word boundary
`sanitize_excerpt`: An excerpt fit for a prompt, or `None` when it carries a credential or
reads like an instruction to the model (`CotypingMemoryContext.sanitized`,
`PromptContextSanitizer`). Control characters become spaces, whitespace
collapses, and the text is cut at a word boundary with an ellipsis.

#### Chat fixture covers toolbar text, far-side text and another field's draft
`tests::chat`: A chat window: two messages above the reply box, one in a toolbar,
one far to the side, and another field's draft.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/win32.rs`

#### Keyboard hook installed only while ghost shows; callback forwards keys; own keys carry MARKER
Windows for autocomplete: a low-level keyboard hook that takes the plain
accept keys and Esc only while ghost text shows (`CotypingInputMonitor`'s
accept tap), `SendInput` Unicode keystrokes for an accepted chunk
(`CotypingInserter`), and the ghost window's styles and placement.

The hook is installed when a suggestion appears and removed when it goes;
its callback only forwards the key, so Windows never waits on LokalBot.
LokalBot's own keystrokes carry [`MARKER`] and pass the hook untouched.

#### LokalBot's own keystrokes carry dwExtraInfo LOKA to pass the hook
`MARKER`: `dwExtraInfo` of LokalBot's own keystrokes ("LOKA").

#### Many apps take only the first 20 UTF-16 units of a key burst
`CHUNK`: Many apps take only the first 20 UTF-16 units of one burst of keys.

#### Scan code 0x29 is the key left of 1 on any layout
`BACKTICK_SCAN_CODE`: The scan code of the key left of 1, whatever it types on this layout.

#### Keys whose press was taken also have their release taken
`HookState::taken`: Keys whose press was taken, so their release is taken too.

#### Hook state is thread-local; the hook runs on the installing thread's message loop
`STATE`: The hook runs on the thread that installed it, through its message loop.

#### Insert only when field's app is in front: deletions first, then Unicode keystroke bursts
`insert`: Types an accepted chunk into the window in front, which must belong to
the field's app: deletions first, then the text as Unicode keystrokes in
bursts of at most 20 UTF-16 units.

#### Type Tab as a space because Tab would trigger our own accept hook
`insert`: Tab would come back to our own hook as an accept.

#### Never split a surrogate pair between key bursts
`insert`: Never split a surrogate pair between bursts.

#### GPUI pop-ups get caption and border; convert to plain WS_POPUP outside a GPUI update
`prepare_overlay`: No frame or border, no activation on click, clicks pass through, never
in the taskbar or Alt+Tab, and (when asked) left out of screenshots and
recordings.

GPUI creates pop-up windows as overlapped windows, which Windows gives a
caption and a border: the client area then sits inside the frame the
ghost is placed at, so its text was shifted and clipped, and DWM drew a
thin border around it. A plain `WS_POPUP` without DWM's frame, rounded
corners and border is exactly the ghost's frame. Call it outside a GPUI
update: the frame change reaches GPUI as a new client size.

#### DWM attributes missing on older Windows are ignored; window still works
`prepare_overlay`: Older Windows lacks some of these; the window still works.

#### New window styles apply only after a frame recalculation
`prepare_overlay`: The new styles take effect with the next frame calculation.

#### Scale is device pixels per logical pixel on the rect's monitor
`scale_at`: Device pixels per logical pixel on the monitor showing `rect`.

#### Over SSH session 0 hook install may fail; must not panic or hang
`the_hook_installs_and_removes_without_a_desktop`: Over SSH (session 0) installing may fail; it must not panic or hang.

### `LinuxWindows/crates/lokalbot-platform/src/autocomplete/x11.rs`

#### XGrab accept keys with lock-key variants, released when overlay hides; idle thread holds no grab
X11 for autocomplete: `XGrabKey` on the accept keys and Escape while ghost
text shows (`CotypingInputMonitor`'s consuming tap), the active window for matching a
focused field to its window, and moving LokalBot's ghost window.

The grabs cover the Caps Lock and Num Lock variants, so the key is taken
whatever those locks say, and are released the moment the overlay hides.
While inactive the thread holds no grab and only waits for commands.

#### Key left of 1 is keycode 49 under the evdev keymap
`EVDEV_TILDE_KEY`: The key left of 1 under the evdev keymap every current X server uses (TLDE).

#### Grab thread checks key events every 5 ms while holding a grab
`ACTIVE_POLL`: How often the grab thread looks for key events while it holds a grab.

#### XTest typing while a grabbed key is held returns to LokalBot; inserter waits for release
`KeyHeld`: Whether a grabbed key is still held. While it is, the keyboard is
grabbed by LokalBot, so XTest typing would come back to LokalBot instead
of reaching the app; the inserter waits for the release.

#### Plain key press may carry none, Caps Lock, Num Lock or both
`Keys::lock_variants`: The modifier states a plain key press can come with: none, Caps Lock,
Num Lock, or both.

#### Match the physical key left of 1, not the backtick keysym; fall back to level-0 backtick
`backtick_keycode`: The physical key left of 1. Matching the keysym instead would, on other
layouts, take a letter key that types a backtick on a shifted level. An
X server without the evdev keymap falls back to the key whose first level
is a backtick.

#### Num Lock is usually mapped to Mod2
`num_lock_mask`: The modifier bit Num Lock is mapped to (usually Mod2).

#### Grab fails when another app already holds a bound key
`grab_all`: Takes every key `bindings` names; false when another app holds one.

#### Ungrab before replaying the key or it comes back to us
`grab thread pass-through`: Out of the way first, or the replayed key would come back here.

#### Delete via XTest where the field cannot edit through AT-SPI
`tap_keys`: Sends `keysym` presses through XTest, for deleting around the caret
where the field cannot edit through AT-SPI.

#### Active window comes from _NET_ACTIVE_WINDOW
`ActiveWindow`: The active window (`_NET_ACTIVE_WINDOW`) and what autocomplete needs of it.

#### Frame excludes the GTK client-side shadow from _GTK_FRAME_EXTENTS
`ActiveWindow::frame`: Its content in root coordinates, without the shadow a client-side
decorated window (GTK) draws around itself (`_GTK_FRAME_EXTENTS`).

#### One X connection for watcher reads, reopened after errors
`Display`: One X connection for the watcher's reads, reopened after errors.

#### Empty input shape lets clicks pass through the ghost
`prepare_overlay`: An empty input shape: clicks go to whatever is under the ghost.

#### Use the RandR monitor holding the rect, else the whole screen
`screen_containing`: The monitor holding `rect` (RandR), else the whole screen.

#### Screen image is 32 bits per pixel, blue first
`sample_luminance`: 32 bits per pixel, blue first.

#### Grab test needs an X display such as xvfb-run
`tests`: Runs only with an X display, such as under `xvfb-run`.

#### Default accept keys are Tab, physical key left of 1, Esc
`the_bound_keys_are_taken_only_while_active_and_can_change`: The defaults: Tab, the physical key left of 1, Esc.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
