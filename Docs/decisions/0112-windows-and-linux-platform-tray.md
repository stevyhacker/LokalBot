# 0112. Windows and Linux: platform — tray

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-platform/src/tray.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-platform/src/tray.rs`

#### Tray menu maps Mac panel; Linux SNI vs Windows tray-icon; threading
The system tray icon and its menu, the Linux/Windows counterpart of the
macOS menu bar extra (`MenuBarView.swift`, `MenuBarStatusBlock.swift`,
`MenuBarRows.swift`, `MenuBarStatus.swift`).

A tray menu is drawn by the desktop, not by LokalBot, so the Mac's panel
becomes the closest native menu: its status block as the first rows (a
heading and its lines, which cannot be chosen, then the block's buttons as
items), then rows with an icon and their text, and the switch as a check
item. What the Mac shows at a row's far side (a shortcut, a time, a timer)
is right-aligned on Windows and follows the text on Linux.

Linux publishes a StatusNotifierItem over D-Bus (`ksni`; KDE, GNOME with
the AppIndicator extension, waybar…) whose rows name freedesktop icons, so
the host paints them in its own menu colours. Windows uses `tray-icon` on a
worker thread with its own message loop; its rows draw the pixels the app
hands to [`Tray::new`]. Create the tray from any thread (the GPUI main
thread is fine); `on_event` runs on a background thread.

#### Linux uses theme icon names, Windows draws pixels; Record/Stop drawn red
`TrayGlyph`: The symbol at the start of a menu row (`MenuBarRowIcon`, the status
block's tile). Linux hosts look it up in the icon theme by
[`TrayGlyph::icon_name`]; Windows draws the pixels given to [`Tray::new`].
[`TrayGlyph::Record`] and [`TrayGlyph::Stop`] are drawn here, in the
recording red, as the Mac's buttons draw them.

#### Record maps to circle.fill in red
`TrayGlyph::Record`: `circle.fill` in red: Record now, Record, and the recording heading.

#### Idle maps to record.circle
`TrayGlyph::Idle`: `record.circle`: Not recording.

#### Stop maps to stop.fill in red
`TrayGlyph::Stop`: `stop.fill` in red: Stop.

#### Calendar maps to calendar symbol
`TrayGlyph::Calendar`: `calendar`: a meeting about to start.

#### Pause maps to pause symbol
`TrayGlyph::Pause`: `pause`: day memory is paused, Pause day memory.

#### Resume maps to play symbol
`TrayGlyph::Resume`: `play`: Resume, Resume day memory.

#### Warning maps to exclamationmark.triangle
`TrayGlyph::Warning`: `exclamationmark.triangle`: something needs attention.

#### Approval maps to checkmark.shield
`TrayGlyph::Approval`: `checkmark.shield`: settings changes waiting for approval.

#### Microphone maps to mic symbol
`TrayGlyph::Microphone`: `mic`: dictation and the microphone.

#### StopDictation maps to stop.circle
`TrayGlyph::StopDictation`: `stop.circle`: Stop dictation.

#### Cancel maps to xmark.circle
`TrayGlyph::Cancel`: `xmark.circle`: Cancel dictation.

#### Search maps to magnifyingglass
`TrayGlyph::Search`: `magnifyingglass`: Quick Recall.

#### Copy maps to doc.on.doc
`TrayGlyph::Copy`: `doc.on.doc`: Copy last dictation.

#### History is the port's menu for the Mac context menu
`TrayGlyph::History`: Earlier dictations (the port's menu for the Mac's context menu).

#### Meeting maps to waveform
`TrayGlyph::Meeting`: `waveform`: a recent meeting.

#### Window maps to macwindow
`TrayGlyph::Window`: `macwindow`: Open LokalBot.

#### Settings maps to gearshape
`TrayGlyph::Settings`: `gearshape`: Settings….

#### Quit maps to power symbol
`TrayGlyph::Quit`: `power`: Quit LokalBot.

#### Blank symbol keeps status line words aligned with heading
`TrayGlyph::Blank`: No symbol: keeps a status line's words in line with its heading's,
as the Mac indents the block's lines past its tile.

#### Symbolic freedesktop names recolor in menus; present in major themes
`TrayGlyph::icon_name`: The freedesktop icon name, symbolic so GTK and GNOME Shell paint it in
the menu's own text colour on light and dark menus alike. Every name is
in Adwaita, Yaru, elementary and Breeze (KDE falls back to the name
without "-symbolic"). [`TrayGlyph::Blank`] has none.

#### Glyphs are 32 px, twice menu icons, to stay sharp at 200%
`GLYPH_SIZE`: Pixels on a side of a drawn glyph: twice the menus' 16 px icons, so they
stay sharp at 200 % and are scaled down elsewhere.

#### Recording red is #FF3B30, macOS system red
`RECORDING_RED`: \#FF3B30, the system red the macOS menu bar uses.

#### Attention amber is #FF9F0A, LBTokens.Palette.attention
`ATTENTION_AMBER`: \#FF9F0A, the attention amber (`LBTokens.Palette.attention`).

#### Windows right-aligns trailing text; Linux appends after a middle dot
`TrayLabel.trailing`: A shortcut, a time or a timer. Windows right-aligns it; Linux menus
have no such column, so it follows the text after a middle dot.

#### dbusmenu treats single underscore as access key, so double it
`TrayLabel::linux_text`: The dbusmenu label: a single "_" marks an access key there, so each is
doubled.

#### Win32 ampersand marks access key; tab text is right-aligned
`TrayLabel::windows_text`: The Win32 menu text: "&" marks an access key there, and text after a
tab is drawn right-aligned in the shortcut column.

#### Tray menus draw no icon beside a checkmark
`TrayItem::Toggle`: A row with a checkmark, for a switch. Tray menus draw no icon beside
a checkmark.

#### Linux says menu will open; on Windows right button down; refresh status
`TrayEvent::MenuOpening`: The menu is about to open (Linux hosts say so; on Windows the right
button went down): a chance to bring its status up to date.

#### Language is in equality so a change rebuilds the menu
`TrayMenuState.interface_language`: Included in equality so a new interface language rebuilds the menu.

#### Lists every attention item under recording or dictation, else the rest after the first
`TrayMenuState.more_attention`: Attention items listed under the block: every one while a recording
or a dictation leads, the rest when the first of them is the block.

#### A recording holds the microphone
`TrayMenuState.recording`: A meeting is being recorded: it holds the microphone.

#### Icon shows recording dot, faint when paused, dot for attention
`TrayMenuState::icon_state`: The recording dot, or the glyph: faint while day memory is paused,
with a dot while something needs attention (`MenuBarLabel`).

#### Block state priority order mirrors MenuBarStatus.Block
`TrayBlock`: The status block's one state, picked in this order: recording, dictating,
needs attention, a meeting about to start, day memory paused, just
stopped, idle (`MenuBarStatus.Block`).

#### JustStopped covers recordings made here ended within two minutes
`TrayBlock::JustStopped`: A recording made here that ended within two minutes.

#### Duration formatted like 12 min
`TrayBlock::JustStopped.duration`: "12 min".

#### Timer formatted MM:SS
`TrayRecording.timer`: "12:04".

#### Warnings come from the recorder in interface language
`TrayRecording.warnings`: What the recorder warns about, in the interface language.

#### Mirrors MenuBarAudioLine.Source: whether sound arrives from a source
`TraySource`: Whether sound is arriving from one source of the recording
(`MenuBarAudioLine.Source`).

#### Status is the recorder's own words using Mac keys
`TraySource.status`: The recorder's own words, such as "Receiving audio" (Mac keys).

#### Meeting starts within 15 minutes or is under way, not recorded
`TraySoonMeeting`: A calendar meeting that starts within 15 minutes or is under way and not
being recorded.

#### Status text such as In 5 min, Starting now
`TraySoonMeeting.status`: "In 5 min", "Starting now", "In progress".

#### Schedule format like 6:00 PM – 6:30 PM
`TraySoonMeeting.schedule`: "6:00 PM – 6:30 PM".

#### Call means other people or a link; recorded with event context
`TraySoonMeeting.is_call`: Other people or a link: a call, recorded with the event's context.

#### Mirrors MenuBarAttention on Mac
`TrayAttention`: One thing the menu asks the person to fix (`MenuBarAttention`).

#### Entries are dictations the clipboard may have lost
`TrayDictationEntry`: A dictation the clipboard may have lost.

#### Menu title format like 2:20 PM — Can you check…
`TrayDictationEntry.menu_title`: "2:20 PM — Can you check…".

#### When format examples: Just now, 11:00 AM, Yesterday, Nov 9
`TrayMeeting.when`: "Just now", "11:00 AM", "Yesterday", "Nov 9".

#### Row text mirrors Mac dictationTitle
`TrayDictation::button`: The dictation row and button (`dictationTitle`).

#### Update row mirrors Sparkle Install Update
`TrayUpdate`: The update row (Sparkle's "Install Update…").

#### Package-managed copies open Settings, which explains how to update
`TrayUpdateAction::Show`: A package manager updates this copy: opens Settings, which says how.

#### Menu rows show one line so long titles are shortened
`short_title`: A menu row shows one line, so long titles shorten (`shortMenuTitle`).

#### While paused the line says meetings still record; pausing never touches recording
`habit_text`: What makes a recording start. While day memory is paused the line says
meetings are not: pausing never touches recording (`habitText`).

#### Source row shows name while sound arrives, else recorder's words
`source_row`: One source of the recording on one row: its name while sound arrives,
otherwise the recorder's words for it (`MenuBarAudioLineRow`).

#### Status block rows keep buttons always in the same place
`block_items`: The status block's rows: what LokalBot is doing in one heading, its
lines, and its buttons, always in the same place under it
(`MenuBarStatusBlock`).

#### Dictation holds the microphone, so Record waits
`block_items`: A dictation holds the microphone: Record waits for it.

#### Solo event without link may not be a call; record without context
`block_items`: A solo event without a link may not be a call: it is recorded
like any other manual start, without the event's context.

#### Menu layout mirrors the Mac panel; Capture Screen Now is port-only
`standard_items`: The macOS menu bar panel as a menu: the status block, then Quick Recall,
dictation and the last dictation; the two most recent meetings; the
Autocomplete switch, Pause day memory and (port-only) Capture Screen Now;
then Open LokalBot, Settings…, the update on offer and Quit LokalBot.

#### Dictation row stops or cancels a running dictation; waits during recording
`standard_items`: Starts dictation; while one runs, the same row stops or cancels it. A
meeting recording holds the microphone, so the row waits for it.

#### Latest dictation row with preview, earlier ones in a submenu
`standard_items`: The way back to a dictation the clipboard lost: the newest with its
preview, earlier ones in a menu of their own (`LastDictationMenuRow`).

#### Recording dot wins over other icon states
`TrayIconState.recording`: A meeting is being recorded: the red dot, which wins over the rest.

#### Paused icon opacity matches MenuBarIcon.dimmedOpacity
`DIMMED_OPACITY`: How much of the icon is left while day memory is paused
(`MenuBarIcon.dimmedOpacity`).

#### Icon is red dot, or faint when paused, with amber attention dot top right
`icon_variant`: The icon as `state` draws it: the red recording dot, or the icon faint
while day memory is paused, with an amber dot cut into its top right
corner while something needs attention (`MenuBarIcon.image`).

#### Tooltip words mirror the Mac status item for assistive tools
`tooltip_text`: "LokalBot — Recording 12:04", "LokalBot — Needs attention, Day memory is
paused": the icon's state in words, as the Mac's status item says it to
assistive tools.

#### Dropping the Tray removes the icon
`Tray`: The tray icon. Dropping it removes the icon.

#### Glyph pixels are for Windows; Linux names icons; drawn glyphs need none
`Tray::new`: `glyphs` are the row icons' pixels for menus that draw pixels
(Windows); Linux names its icons instead. Glyphs that are
[`TrayGlyph::drawn`] here need none.

#### StatusNotifierItem expects ARGB32 in network byte order
`backend::pixmap`: ARGB32 in network byte order, as StatusNotifierItem expects.

#### dbusmenu icon is a theme name, or PNG data for red glyphs
`backend::icon_fields`: A row's icon as dbusmenu carries it: a theme name, or PNG data for the
red glyphs.

#### App answers with current menu; hosts asking before opening show fresh status
`Sni::menu_about_to_show`: The app answers with the menu as it is now; hosts that ask before
opening it show the status current.

#### tray-icon and muda allow one event handler each per process
`backend::HANDLER`: `tray-icon` and `muda` allow one event handler each per process.

#### Menu opens on right button up; app refreshes it on button down
`install_handlers`: The menu opens when the right button comes up: the app
sends it current before then.

#### Test guards removal of Tools caption, dictation switch, View all, Star
`the_menu_reads_like_the_mac_panel`: Gone with the redesign: the Tools caption, the dictation switch,
View all and Star on GitHub.

#### Test: recording holds the microphone so dictation waits
`recording_leads_with_the_meeting_its_sources_and_stop`: The recording holds the microphone: dictation waits.

#### Test: nothing is captured while day memory is paused
`day_memory_paused_offers_resume_and_still_records`: Nothing is captured while day memory is paused.

#### Test: solo event records like manual start with no Join
`a_meeting_about_to_start_offers_join_and_record`: A solo event is recorded like any manual start, and has no Join.

#### Test: under a recording an error keeps its fix row
`what_needs_attention_leads_or_is_listed_under_the_block`: Under a recording, an error keeps its fix on its own row.

#### Test: dictation holds the microphone so Record waits
`dictation_says_how_to_finish_and_offers_stop_or_cancel`: A dictation holds the microphone: a Record shown meanwhile waits.

#### Test: package-managed copy shows Show row pointing to Settings
`an_offered_update_sits_above_quit`: A package manager's copy: Settings says how to update it.

#### Test: recording wins; dot and dimming wait until it ends
`the_icon_dims_while_paused_and_gets_a_dot_for_attention`: Recording wins: the dot and the dimming wait until it ends.

#### Test: paused without day memory on is not paused
`the_icon_state_follows_the_menu_state`: Paused without day memory on is not paused.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
