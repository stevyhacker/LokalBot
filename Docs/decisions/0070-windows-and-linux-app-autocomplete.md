# 0070. Windows and Linux: app — autocomplete

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/autocomplete/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/autocomplete/layout.rs`

#### Ghost is inline after exact line-ending caret, else a pill under the caret line
From a suggestion and the field it is for to the ghost window's frame and
lines (`CotypingOverlayController.show`): inline right after the caret in
the field's own font when the caret is exact and ends its line, else a
pill under the caret's line. Geometry is the platform crate's pure math;
this adds GPUI text measurement and colors.

#### Padding keeps antialiased glyph edges from being clipped
`INLINE_PADDING`: Room around the glyphs so antialiased edges are never clipped.

#### Pill font range matches 11-17 pt on macOS
`PILL_FONT_PX`: The pill's font, 11–17 pt on macOS.

#### Frame is in screen pixels
`Placement.frame`: Screen pixels.

#### Inline ghost shows only what fits; accepts never take unseen words
`Placement.shown`: The part of the suggestion on screen: an inline ghost leaves out what
has no room, and an accept never takes words the user could not see.

#### Caret override for ghost moved after accept; None drops suggestions with no uncovering place
`place`: Lays out `text` for `field`. `caret` overrides the field's caret, for a
ghost moved ahead of the app after an accept. `None` when it has no
place on screen that covers no text; the suggestion is then dropped.

#### Slack past measured end prevents clipping wider glyphs or rounding at other scales
`place`: Room past the measured end, so a glyph wider than measured (or
rounding at another scale) is never cut off; the window is
transparent there.

#### Width from font advances, avoiding cache growth, with fallback-font widths for missing glyphs
`measurer`: A string's width in `family` at `size` logical pixels, from GPUI's text
system: the font's advances (so no layout cache grows with every
suggestion), and for a character the font lacks (an emoji, another
script) the width it is drawn at from a fallback font.

### `LinuxWindows/crates/lokalbot-app/src/autocomplete/mod.rs`

#### A ghost session exists exactly while ghost text is on screen
Autocomplete in other apps (`CotypingCoordinator*.swift`): the field
watcher's snapshots go to the engine as [`FieldContext`]s, the engine's
suggestions come back as ghost text after the caret, the accept keys type
the next word or phrase or the rest (Tab and the key left of 1 unless
changed), and Esc dismisses.

Invariant, as on macOS: a session exists exactly while ghost text is on
screen, and only then are those keys taken from other apps. Typing the
ghost's next characters, or the app showing what an accept typed, shortens
it at once; anything else leaves it behind.

On a Wayland input method the field draws the ghost itself, in preedit, and
an accept goes in together with what is left of it; LokalBot's overlay stays
closed.

Autocomplete stays quiet while dictation runs or a meeting records, in a
field for ten seconds after Esc, in LokalBot's own windows (the practice
editor in Settings → Autocomplete feeds the engine itself), and whenever
`cotyping_enabled` is off. `LOKALBOT_FAKE_AUTOCOMPLETE=<text>` makes the
app suggest `<text>` itself instead of asking the engine, for checking the
desktop side without a model; it is a development switch, off unless set.

#### Practice editor uses u64::MAX; real field ids count up from 1
`PRACTICE_FIELD_ID`: The practice editor's field id. Real fields count up from 1.

#### Wait 500 ms after a taken key, since X11 key grabs cause brief focus loss
`KEY_FOCUS_GRACE`: How long after a taken key a loss of focus waits before the ghost goes.
An X11 key grab gives the focused app a short focus loss, which GTK 4
reports as no focused field until the key is released.

#### Mirrors CotypingRehearsalConversation.sample as text above the practice field
`PRACTICE_CONVERSATION`: The sample exchange above the practice editor
(`CotypingRehearsalConversation.sample`), offered as the text above the
field.

#### What one accept press types and deletes, mirroring plan_acceptance
`Acceptance`: What one accept key press does: the chunk the suggestion gives up, what is
typed, and what is deleted around the caret first (the engine's
`plan_acceptance`, `CotypingContinuationAcceptance`): a space the field
already has is not typed twice, a new sentence gets its space, the rest of
a word the caret is inside of is replaced, and an emoji, a `/macro` or a
misspelled word is replaced whole.

#### Emoji, calculation and correction draw specially and go in one press
`drawn_ghost`: The text to draw for a session and the part of it the next accept takes:
an emoji shows with its shortcode ("🚀 :rocket:"), a calculation as "= 10",
and those and a correction go in one press.

#### Mirrors CotypingRehearsal, the practice editor's suggestion state
`Practice`: The practice editor's suggestion (`CotypingRehearsal`).

#### Insert on its own thread so quick Tabs land in order
`Inserter`: Inserts accepted chunks one after another on a thread of their own, so
two quick Tabs land in order and the UI never waits on the other app.

#### Set only where the field draws the ghost instead of the overlay
`Autocomplete.inline`: Set where the field draws the ghost instead of the overlay.

#### Saved facts are rechecked before accept (discardRevokedMemoryContext)
`Autocomplete.session_guard`: The saved facts behind the session's suggestion, checked again before
an accept (`discardRevokedMemoryContext`).

#### A change in text after the caret leaves the suggestion behind
`Autocomplete.session_after`: The text after the caret when the suggestion was shown; a change
there leaves the suggestion behind.

#### Caret predicted for where the app will show an accept
`Autocomplete.predicted_caret`: Where the caret will be once the app shows an accept.

#### Bumped per focus report so a deferred leave knows it is stale
`Autocomplete.focus_generation`: Bumped by every focus report, so a deferred leave knows it is stale.

#### Background pixels sampled once per app when no colors are reported
`Autocomplete.luminance`: Pixels behind the ghost, sampled once per app with no colors reported.

#### Practice request context kept until its text changes
`Autocomplete.rehearsal`: What the practice editor's last request drew on, until its text changes.

#### Apply engine updates deferred so app state can be read
`engine_update`: An engine update, from `bridge.rs`. Applied after the current update so
the app state can be read.

#### Keep the ghost when focus leaves right after a taken key
`Autocomplete focus handling`: Probably the grab of the key just taken: the ghost
stays unless the field is still gone after a moment.

#### Only a continuation is typed through; other kinds are dropped
`Autocomplete.reconcile_session`: Only a continuation is typed through; anything else goes.

#### Once every accept is in the field, follow the app's own caret
`Autocomplete.reconcile_session`: Every accept is in the field: follow the app's own caret.

#### Development stand-in for the engine after the suggestion pause
`Autocomplete.fake_suggestion`: The development stand-in for the engine: after the pause before
suggesting, the configured text, unless a ghost already shows.

#### Growing suggestion keeps its anchor; others restart from current field
`Autocomplete.on_engine`: A suggestion that grows the visible one keeps its anchor;
anything else starts from the field as it is now.

#### Replacements are checked against live text at accept, so not refitted
`Autocomplete.fitted`: `text` fitted to a field that typing has moved on from. A replacement
is checked against the live text when accepted, so it stays as it is.

#### Corrections, emoji and calculations show whole or not at all
`Autocomplete.present`: A correction, emoji or calculation shows whole or not at all.

#### Accept never takes words the user could not see
`Autocomplete.present`: Accept never takes words the user could not see.

#### Accept never takes words the user could not see
`Autocomplete.present`: Accept never takes words the user could not see.

#### Lay out again when the window lands on a monitor with another scale
`Autocomplete.present`: The window landed on a monitor with another scale.

#### Tray-only runs have no theme set yet, so fall back
`Autocomplete.appearance`: Running in the tray, no window has set the theme yet.

#### Colorless fields are read from the screen once per app (CotypingBackgroundSampler)
`Autocomplete.background_luminance`: Fields that report no colors are read from the screen once per app,
before the ghost covers the spot (`CotypingBackgroundSampler`).

#### Withdrawn or edited saved facts drop the suggestion and pass the key
`Autocomplete.on_accept_key`: Saved facts withdrawn or edited since the suggestion was made: it
goes, and the app gets its key.

#### Reject accept unless field matches the ghost anchor or an accept is pending
`Autocomplete.on_accept_key`: The field must read as the ghost expects, or an accept is on its way.

#### Fail open: the app gets its key
`Autocomplete.on_accept_key`: Fail open: the app gets its key.

#### Inline accept sends the remainder with it so accepted words never show twice
`Autocomplete.on_accept_key`: What is left goes in with the accept, so the field never shows
the accepted words twice.

#### Move the ghost past accepted text before the app shows it
`Autocomplete.on_accept_key`: Move the ghost past the accepted text before the app shows it.

#### Caret measured in ghost font; None when only the app can tell
`Autocomplete.caret_after`: Where the caret will be once `typed` is in the field, measured in the
ghost's font, or `None` when only the app can tell.

#### Esc stops here and pauses the field by default; otherwise app gets it too
`Autocomplete.on_escape`: By default Esc stops here, so it does not also close a dialog in the
app, and the field stays quiet for a while
(`CotypingEscapeBehavior.pause`). Otherwise the app gets it too.

#### Practice context has no window title, as on macOS, to avoid settings talk
`Autocomplete.practice_changed`: No window title, as on macOS: "Settings" would steer the
model toward settings talk.

#### Arrow key drops the practice ghost even with caret at end
`Autocomplete.practice_drop`: An arrow key in the practice editor drops the ghost, even with the
caret at the end of the text.

### `LinuxWindows/crates/lokalbot-app/src/autocomplete/overlay.rs`

#### Ghost window is one transparent focus-less pop-up hidden between suggestions
The ghost window (`CotypingOverlayController.swift`, `CotypingGhostView.swift`):
one transparent, focus-less pop-up that is moved to the caret, sized to
the suggestion, and hidden rather than closed between suggestions. It
never takes focus or clicks, so the app being typed in keeps the keyboard.

Inline, it draws the suggestion in the field's font right after the
caret, the part the next Tab takes a little stronger; as a pill it draws
it under the caret's line with its own background.

Kept free of the rest of the app so `examples/autocomplete_probe.rs` can
show the same window.

#### Offset where text starts in the suggestion, in characters
`GhostLine.offset`: Where `text` starts in the suggestion, in characters.

#### Font size is in logical pixels
`GhostContent.font_size`: Logical pixels.

#### Characters from the start that the next Tab takes
`GhostContent.emphasis_chars`: Characters from the start the next Tab takes.

#### Ghost window is created on first use
`Overlay`: The ghost window, created on first use.

#### Scale factor GPUI reported for the window last time
`Overlay.scale`: The scale factor GPUI reported for the window last time.

#### Windows: only the newest native move runs; older pending ones skip
`Overlay.latest_move`: Windows: the newest native move asked for; an older one still
waiting is skipped (see [`Overlay::move_native`]).

#### Device pixels per logical pixel where the window last was
`Overlay.scale`: Device pixels per logical pixel where the window last was.

#### Returns scale after showing; caller re-lays out if monitor differs
`Overlay.show`: Shows `content` in `frame` (screen pixels). Returns the window's
scale factor afterwards, which may differ on another monitor; the
caller then lays the suggestion out again.

#### Reopen the window when a display change closed it
`Overlay.show`: Closed underneath us (display change): open again.

#### Windows keeps a scale per monitor; use the one moved to
`Overlay.show`: Windows keeps a scale per monitor: the one the ghost moves to.

#### A pending move must not touch the closing window
`Overlay.close`: A move still waiting must not touch the closing window.

#### Defer native window calls on Windows to avoid GPUI RefCell reborrow
`Overlay.move_native`: Moves and sizes the native window to `frame` and shows it, or hides
it with `None`.

Windows answers `SetWindowPos` and style changes with messages GPUI
handles on the spot, and those handlers need the app, which is busy
with the update that called this: GPUI logged "RefCell already
borrowed" and missed the window's new size, so the ghost kept drawing
at its old size. There the native calls wait for the next turn of the
event loop, and only the newest one runs. X11 requests go out on a
connection of their own and GPUI reads the results later, so they are
made at once.

#### On Windows the first move shows the window after it loses its frame
`Overlay.open`: On Windows the first move shows it, once it has lost the frame
Windows gives it (see `move_native`).

#### Windows prepares the overlay with its first move
`Overlay.open`: Windows prepares it with its first move.

#### Replace spaces with nbsp since a text run's leading space is not drawn
`GhostView.render`: A text run's leading space is not drawn; the ghost's first
space separates it from the word at the caret.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
