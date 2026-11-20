# 0113. Windows and Linux: platform — other modules

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-platform/examples/`, `LinuxWindows/crates/lokalbot-platform/scripts/`, `LinuxWindows/crates/lokalbot-platform/src/access.rs`, `LinuxWindows/crates/lokalbot-platform/src/agent_links.rs`, `LinuxWindows/crates/lokalbot-platform/src/autostart.rs`, `LinuxWindows/crates/lokalbot-platform/src/chord.rs`, `LinuxWindows/crates/lokalbot-platform/src/control_socket.rs`, `LinuxWindows/crates/lokalbot-platform/src/disk.rs`, `LinuxWindows/crates/lokalbot-platform/src/focus.rs`, `LinuxWindows/crates/lokalbot-platform/src/insert.rs`, `LinuxWindows/crates/lokalbot-platform/src/instance.rs`, `LinuxWindows/crates/lokalbot-platform/src/lib.rs`, `LinuxWindows/crates/lokalbot-platform/src/media.rs`, `LinuxWindows/crates/lokalbot-platform/src/notify.rs`, `LinuxWindows/crates/lokalbot-platform/src/opener.rs`, `LinuxWindows/crates/lokalbot-platform/src/power.rs`, `LinuxWindows/crates/lokalbot-platform/src/privacy.rs`, `LinuxWindows/crates/lokalbot-platform/src/process.rs`, `LinuxWindows/crates/lokalbot-platform/src/process_usage.rs`, `LinuxWindows/crates/lokalbot-platform/src/selection.rs`, `LinuxWindows/crates/lokalbot-platform/src/session.rs`, `LinuxWindows/crates/lokalbot-platform/src/shortcuts.rs`, `LinuxWindows/crates/lokalbot-platform/src/win32_loop.rs`, `LinuxWindows/crates/lokalbot-platform/tests/`.

## Decisions

### `LinuxWindows/crates/lokalbot-platform/examples/autocomplete_watch.rs`

#### Manual desktop-integration check with --tab, --backward, --ghost, --pass-tab
Prints what autocomplete's field watcher reads, and with `--tab <text>`
takes Tab while running and types `<text>` into the focused field, as
accepting a suggestion does. `--backward <n>` first deletes that many
characters before the caret, as a correction does. For checking the
desktop integration by hand:

```text
cargo run -p lokalbot-platform --example autocomplete_watch -- --seconds 20 --tab " up"
```

On a Wayland input method, `--ghost <text>` shows `<text>` in the field
whenever one has focus: Tab takes its first word, the key left of 1 the rest,
and Esc drops it. With `--pass-tab`, Tab goes on to the field instead.

### `LinuxWindows/crates/lokalbot-platform/examples/kwin_input_method.rs`

#### KWin input method helper started with --inputmethod for live tests
The KWin input method helper on its own, for the live tests: what
`lokalbot --kwin-input-method` runs. KWin starts it with `--inputmethod`
(see `scripts/live-kwin.sh`).

### `LinuxWindows/crates/lokalbot-platform/examples/screen_text.rs`

#### Inspect screen context for front window, 3 s delay, optional PPM save
Prints what screen context sees in the window in front: its title,
process, rectangle and the accessibility snapshot, and optionally saves
its pixels as a PPM image.

```text
cargo run -p lokalbot-platform --example screen_text -- [--delay <seconds>] [--save <file.ppm>]
```

Switch to the window to inspect during the delay (3 s by default).

### `LinuxWindows/crates/lokalbot-platform/scripts/eis-keyboard.py`

#### KWin EIS RemoteDesktop takes the portal's device type values
`PORTAL_KEYBOARD`: org.kde.KWin.EIS.RemoteDesktop takes the portal's device types.

#### Variadic ctypes call ended by 0; give argument types at each call
`bind_capabilities`: Variadic, ended by 0: give the arguments' types at each call.

### `LinuxWindows/crates/lokalbot-platform/scripts/live-autocomplete.sh`

#### Live autocomplete check on private Xvfb and D-Bus; dependencies and usage
Checks autocomplete's desktop side on a private Xvfb display and D-Bus
session with the accessibility bus: the field watcher reads a GTK reply
field (text, caret, window title, the messages above it), Tab is taken
while active and types the accepted text through AT-SPI, and the password
field is never read. Needs Xvfb, xfwm4, xdotool, python3-gi with GTK 3,
at-spi2-core and dbus-run-session.
Usage: crates/lokalbot-platform/scripts/live-autocomplete.sh [display number]

### `LinuxWindows/crates/lokalbot-platform/scripts/live-kwin.sh`

#### Headless KWin live test; needs setcap removed in containers
Runs the ignored KDE Plasma live test inside a headless KWin, with the
autocomplete input method helper as KWin's input method, a private runtime
folder and a D-Bus session. Keys go in through KWin's EIS endpoint. Needs
kwin_wayland (Plasma 6), Python with GTK 3 and PyGObject, libei and
dbus-run-session. In a container, kwin_wayland needs its file capabilities
removed (`setcap -r "$(command -v kwin_wayland)"`).
Usage: crates/lokalbot-platform/scripts/live-kwin.sh

### `LinuxWindows/crates/lokalbot-platform/scripts/live-sway.sh`

#### Headless Sway Wayland live tests with private runtime and D-Bus
Runs the ignored Wayland live tests inside a headless Sway session with a
private runtime folder and D-Bus session. Needs sway, foot, wtype, Python with GTK 3 and
dbus-run-session.
Usage: crates/lokalbot-platform/scripts/live-sway.sh

### `LinuxWindows/crates/lokalbot-platform/scripts/live-x11.sh`

#### X11 live tests on private Xvfb; dependencies and usage
Runs the ignored live tests on a private Xvfb display and D-Bus session:
the X11 sampler, idle time, shortcuts (press and release), paste and typing
into GTK and terminal windows, and notification and tray round trips.
Needs Xvfb, xfwm4, xdotool, xmessage (x11-apps), zenity, xsel,
xfce4-terminal and dbus-run-session.
Usage: crates/lokalbot-platform/scripts/live-x11.sh [display number]

### `LinuxWindows/crates/lokalbot-platform/src/access.rs`

#### Setup checks only read: never prompt, capture, load scripts or change settings
What first-run setup can check about this computer before anything turns
on (`OnboardingAccess` on the Mac). Linux and Windows have no permission
prompts like macOS, so each check reads what this desktop provides
instead. Every check only reads: none prompts, opens a capture session,
loads a script, reads a window's contents or changes a setting.

#### TurnedOff means system switch is off, e.g. Windows microphone privacy
`Check::TurnedOff`: The system has it switched off (Windows' microphone privacy setting).

#### Unknown when it cannot be known before the feature first runs
`Check::Unknown`: It can't be known before the feature first runs.

#### GNOME on Wayland needs a window-information extension such as Window Calls
`Gap::GnomeWindowExtension`: GNOME on Wayland without a window-information extension ("Window Calls").

#### Screenshot key needs a Secret Service provider
`Gap::CredentialStore`: No Secret Service provider to keep the screenshot key.

#### Windows desktop-apps microphone switches; Unknown elsewhere
`microphone`: Windows' "Let desktop apps access your microphone" and the switches
above it. Elsewhere `Unknown`: there is no such switch to read.

#### Window titles check serves day memory recording
`window_titles`: Seeing the app and window title in front, which day memory records.

#### Win32 and X11 EWMH tell any app the front window
`window_titles_on`: Win32 and X11 (EWMH) tell any app which window is in front.

#### KDE is Unknown because the KWin script loads when day memory starts
`window_titles_on`: LokalBot loads its KWin script when day memory starts.

#### Windows UI Automation needs no permission
`screen_text`: UI Automation needs no permission.

#### GDI and X11 read window pixels without asking
`screenshots_on`: GDI and X11 read a window's pixels without asking.

#### Screenshot portal may ask once, so capable portal stays Unknown
`screenshots_on`: The screenshot portal may ask once, the first time.

#### Windows always has Credential Manager
`credential_store`: Windows always has its Credential Manager.

#### Check D-Bus service running or activatable without starting it; None without bus
`linux::service_available`: Whether a D-Bus service runs now or can be started on demand,
without starting it. `None` without a session bus.

#### Introspect the extension interface without reading any window
`linux::gnome_window_extension`: Whether GNOME Shell has an extension that says which window is in
front. Introspection lists its interface without reading any window.

#### Read portal property only; take no screenshot
`linux::portal_window_screenshots`: Whether the screenshot portal can capture only the window in front.
Reads the portal's property; takes no screenshot.

#### Device, user and desktop-apps switches; any Deny blocks desktop apps
`win::microphone`: The device switch, the user's switch and the desktop-apps switch, in
that order; any one set to "Deny" keeps desktop apps off the microphone.

#### Registry read asks size first, then fills exact-size buffer
`win::read`: SAFETY: the first call asks for the size; the second fills a buffer
of exactly that size.

#### Portal can ask first time, so capable portal stays Unknown
`screenshots_through_the_portal_are_never_claimed_allowed`: The portal can ask the first time, so a capable one stays unknown.

### `LinuxWindows/crates/lokalbot-platform/src/agent_links.rs`

#### App picks scheme and builds link; nothing runs text from meetings or models as a program
Reaching a coding agent installed on this computer: whether a deep-link
scheme has a handler, opening such a link, and starting a command-line
agent in a new terminal window. The app chooses the scheme and builds the
link; nothing here accepts text from meetings or models as a program.

#### URL must use accepted scheme; immediate handler failure is reported
`open_agent_link`: Opens an agent's deep link. `url` must use a scheme `handles_scheme`
accepted; a handler that fails right away is reported.

#### Run only caller-located programs; never pass prompts on a command line
`open_in_terminal`: Starts `program` in a new terminal window, in `folder`. Only a program the
caller located is run: no prompt is ever passed on a command line, where a
terminal or a shell could read it as more than text.

#### Early error exit means failure; still running after patience means handed over
`launched`: Waits briefly for a launcher: one that exits with an error failed, and one
still running after `patience` has taken over the job.

#### Terminal run flags, ordered most specific desktops first
`LINUX_TERMINALS`: How each Linux terminal runs a program, most specific desktops first.

#### User's TERMINAL choice comes first when it names a terminal
`linux open_in_terminal`: The user's own choice comes first, when it names a terminal.

#### Protocol is HKCR key with empty URL Protocol value
`win::handles_scheme`: A registered protocol is a key under `HKEY_CLASSES_ROOT` (which merges
the user's and the machine's) holding an empty `URL Protocol` value.

#### Windows Terminal else console; cmd /k runs .cmd shims and keeps failures visible
`win::open_in_terminal`: Windows Terminal when it is installed, else a console window. `cmd /k`
runs `.cmd` shims and stays open if the program fails to start, so the
failure is visible.

### `LinuxWindows/crates/lokalbot-platform/src/autostart.rs`

#### Autostart is a Linux .desktop file and a Windows HKCU Run value
"Launch at login": `~/.config/autostart/lokalbot.desktop` on Linux, the
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value on Windows.

#### Autostart argument starts the app in the tray without a window
`AUTOSTART_ARG`: Argument passed when the system starts LokalBot at login, so the app can
start in the tray without opening its window.

#### Enabled means not disabled by the user in system startup settings
`launch_at_login_enabled`: Whether LokalBot is set to start at login (and not disabled by the user
in the system's startup settings).

#### StartupApproved first byte even means enabled, odd means user disabled it
`windows_startup_approved`: `Explorer\StartupApproved\Run` entries start with an even byte when the
item is enabled and an odd one after the user disabled it in Task Manager
or Settings.

#### Clear a Task Manager disabled mark so enabling takes effect
`platform::set (Windows)`: A "disabled" mark from Task Manager would keep it off.

#### Test is read-only and never enables autostart on a test machine
`reading_the_state_does_not_fail`: Read-only: never enables anything on a test machine.

### `LinuxWindows/crates/lokalbot-platform/src/chord.rs`

#### Modifier-only chords are watched not taken; unavailable on Wayland
Dictation shortcuts made only of modifier keys, like Ctrl+Alt
(`DictationInputMonitor`'s chords). They are watched, never taken: reading the
keyboard's state consumes nothing, so other shortcuts that start with the same
modifiers keep working. X11 and Windows can both report that state. A Wayland
desktop tells an app about keys only through a shortcut with a real key, so
chords aren't offered there.

#### 30 ms poll cannot miss a deliberate two-modifier chord
`POLL`: How often the keyboard's state is read. A chord can't be missed at this rate:
nobody holds two modifiers for under 30 ms on purpose.

#### Chord held 200 ms before push to talk so Ctrl+Alt+key never opens mic
`HOLD_DELAY`: How long a chord is held before push to talk starts, so Ctrl+Alt followed
quickly by another key never opens the microphone (`chordHoldDelay`).

#### Press shorter than 300 ms keeps recording after release
`TAP_THRESHOLD`: Tap or hold: a press shorter than this keeps recording after release.

#### Cancel when the chord turns out to be part of another shortcut
`ChordAction::Cancel`: It turned out to be part of another shortcut (Ctrl+Alt then T).

#### Pressed while dictating so a clean release finishes it
`ChordTracker::finishes_on_release`: Tap or hold: pressed while dictating, so a clean release finishes.

#### active says a dictation is starting or recording
`ChordTracker::update`: One reading of the keyboard. `active` says whether a dictation is
starting or recording.

#### Extra key or modifier means another shortcut unless dictation already started
`ChordTracker::update`: Another key or another modifier: a different shortcut, unless this
hold already started a dictation and it's just a modifier joining.

#### A hold finishes on release; a tap keeps recording
`ChordTracker::release`: A hold finishes on release; a tap keeps recording.

#### Release before hold delay is a tap and starts immediately
`ChordTracker::release`: Released before the hold delay: a tap, so start now.

#### None means keyboard unreadable, which ends the watcher
`KeyState::read`: Reads the keyboard. `None` when it can't any more, which ends the watcher.

#### Keyboard layout can move modifiers at runtime; mapping refreshed every 5 s
`MAPPING_LIFETIME`: A keyboard layout can move modifiers around while LokalBot runs.

#### Caps Lock and Num Lock do not interrupt a chord
`Mapping::ignored`: Caps Lock, Num Lock and the rest, which don't interrupt a chord.

#### AltGr reports as Left Ctrl plus Right Alt; must not read as Ctrl+Alt
`WinKeys::read`: AltGr reports as Left Ctrl + Right Alt on many layouts: pressing
it alone must not read as Ctrl+Alt.

#### Scan virtual keys from 0x08 up; lock keys are not another shortcut
`WinKeys::read`: 0x08 is Backspace: below it are the mouse buttons. The lock keys
at 0x14, 0x90 and 0x91 aren't another shortcut.

#### Tap just past hold delay has started and does not stop on release
`tap_or_hold_follows_how_long_it_was_held`: A tap just past the delay has started, and doesn't stop on release.

### `LinuxWindows/crates/lokalbot-platform/src/control_socket.rs`

#### Control socket runs only when external agents allowed; this user only
The app end of the CLI control socket (`AppControlServer.swift`). It runs
only while the person allows external agents to change settings and accepts
connections from this user only: a Unix socket (mode 0600, in a 0700 folder,
with the peer's user id checked) or a named pipe whose access list holds only
this user and which refuses remote clients.

#### Handler may keep the reply and answer later on any thread
`Reply`: Answers a request. The handler may keep it and answer later, on any thread.

#### Waker connection stays open until join; Windows pipe listener skips departed clients
`ControlServer::drop`: Wake the blocking accept with a connection of our own, held open until
the thread has gone: a Windows pipe listener skips a client that has
already left, so closing this one first could leave accept waiting and
the join below waiting on it, for good.

#### Call under library instance lock; stale crash socket replaced; handler runs on connection thread
`listen_control`: Listens for requests for the library at `root`. Call while holding the
library's instance lock; a socket left by a crashed run is replaced.
`on_request` runs on the connection's own thread with the caller's name.

#### Protected single-entry ACL: this user only, no inheritance, no remote clients
`private_options`: A protected list with one entry: no inherited access, and nobody but
this user. Named pipes refuse remote clients unless told otherwise.

#### Peer name feeds audit log; None when peer is another user
`caller`: The peer's name for the audit log, or `None` when it runs as another user.

### `LinuxWindows/crates/lokalbot-platform/src/disk.rs`

#### statvfs field widths differ between architectures
`available_bytes (Linux)`: The fields' widths differ between architectures.

### `LinuxWindows/crates/lokalbot-platform/src/focus.rs`

#### Focus snapshots hold no field text; reads serialized with deadlines, fail closed
Who has focus, and whether it is still the field a dictation or a selection
action started in (`DictationFocusSnapshot`, `DictationDeliveryTarget`,
`DictationFocusSnapshotExecutor`).

A snapshot holds only identity and privacy state: never field text. Reads
are serialized on one reader with a wall-clock deadline for each caller, so
a wedged app fails closed without piling up workers. Call from a background
thread.

#### Shortcut-start focus read gets 120 ms because microphone opens alongside
`START_DEADLINE`: The shortcut's own read: the microphone opens alongside it.

#### Delivery check is off the critical path, so apps get 600 ms
`DELIVERY_DEADLINE`: Not on the shortcut's critical path, so slow apps get longer to answer.

#### app_id is the executable, WM_CLASS or Wayland app id
`FrontApp.app_id`: Executable, `WM_CLASS`, or Wayland app id.

#### window is a backend id: X11 window, HWND or compositor id
`FrontApp.window`: The backend's window id: an X11 window, an `HWND`, or a compositor id.

#### Unknown means the desktop cannot say what is in front
`Frontmost::Unknown`: This desktop does not say what is in front.

#### Nothing means desktop or lock screen is in front
`Frontmost::Nothing`: Nothing is in front: the desktop, a lock screen.

#### field_pid is set only when accessibility answered
`FocusSnapshot.field_pid`: The focused element's process, when accessibility answered.

#### identity is present only for an editable field
`FocusSnapshot.identity`: Present only for an editable field.

#### accessible true means no-selection result is meaningful
`FocusSnapshot.accessible`: Accessibility answered for this app, so "no selection" means something.

#### Never read screen or nearby text from secure field or selection
`FocusSnapshot.blocks_context_capture`: Screen and nearby-text context are never read from a secure field or
while text is selected.

#### Unknown means desktop gives no focus information at all
`FocusRead::Unknown`: This desktop gives no information at all about focus.

#### Unreadable field and app timeout both map to FieldUnreadable
`DeliveryCheck::FieldUnreadable`: The field could not be read, or the app did not answer in time.

#### Target is the app and field focused when shortcut pressed
`DeliveryTarget`: The app and field that owned focus when the shortcut was pressed.

#### Paste replaces exactly the starting selection; other selections block
`DeliveryTarget.selection`: Text selected at the start. Pasting replaces exactly that selection,
the way typing would; any other selection blocks the paste.

#### No target for secure fields so it never permits later password paste
`DeliveryTarget::captured`: `None` for a secure field: a target must never become permission to
paste into a password field later.

#### Blocked snapshot always wins over app-only fallback
`DeliveryTarget::check`: A blocked snapshot always wins over the app-only fallback.

#### Replacements need the exact selection, not a cleared caret
`DeliveryTarget::strict_check`: For replacing a selection: the exact selection, including a range
having been cleared to a caret.

#### Reader keeps desktop connections between reads
`FrontReader`: Reads what is in front. Keeps its desktop connections between reads.

#### Windows store app window belongs to frame host, use foreground pid
`FrontReader::read`: A store app's window belongs to its frame host; its fields do not.

#### Wayland without window info uses accessibility active app
`FrontReader::from_accessibility`: A Wayland desktop with no window information can still say which
app's window is active, when that app publishes accessibility.

#### One reader per process; reads queue behind each other
`READER`: One reader for the process: reads queue behind each other.

#### Work runs off-thread, caller gives up at deadline, backends bound calls
`with_deadline`: Runs `work` off this thread and gives up waiting after `deadline`; the
work itself is bounded by each backend's call timeouts.

#### Wayland cannot activate windows; desktop returns focus on panel close
`activate_window`: Brings a window forward. Wayland lets no app do this: there the desktop
returns focus by itself when LokalBot's panel closes, and the check that
follows confirms it.

#### Invalid HWND makes SetForegroundWindow fail; nothing dereferenced
`activate_window`: SAFETY: an invalid handle makes the call fail; nothing is dereferenced.

#### _NET_ACTIVE_WINDOW sent as pager request so window managers honor it
`x11_activate`: `_NET_ACTIVE_WINDOW`, marked as a request from a pager so window managers
honor it.

#### Cleared selection still allows dictation paste but not replacement
`selections_must_stay_as_they_were`: Cleared to a caret: dictation may still paste there, a replacement may not.

### `LinuxWindows/crates/lokalbot-platform/src/insert.rs`

#### Paste restores clipboard after 300 ms; Wayland typing needs wtype or ydotool
Delivering dictated text to the focused app (`CotypingInserter.insertViaPaste`,
`DictationModels.swift`).

[`InsertMethod::Paste`] puts the text on the clipboard, presses Ctrl+V
(Shift+Insert in terminals), and puts the previous clipboard back 300 ms
later if nothing else changed it. [`InsertMethod::Type`] types Unicode
keystrokes. On Wayland keystrokes need `wtype` (wlroots compositors) or
`ydotool`; without them the text is left on the clipboard and the call
returns [`InsertOutcome::CopiedToClipboard`] so the UI can say so.

Call from a background thread: a paste blocks for about 300 ms.

#### App gets 300 ms to read clipboard before restore
`RESTORE_AFTER`: How long the app gets to read the clipboard before it is restored.

#### Wait up to 600 ms for shortcut modifiers to be released
`MODIFIER_WAIT`: How long to wait for the user to let go of the shortcut's modifiers.

#### One process-wide clipboard, since X11 owner serves pastes
`CLIPBOARD`: One clipboard for the process. On X11 the owner serves pastes, so the
copied text survives only while this stays alive.

#### Restored clipboard is marked generated so clipboard managers skip it
`restore_clipboard`: Puts the clipboard back, marked as generated so clipboard managers skip it.

#### Copy keystroke refused in terminals where Ctrl+C interrupts
`send_copy`: Sends the copy keystroke to the focused app. Refuses terminals, where
Ctrl+C interrupts whatever is running. `Ok(false)` when it was not sent.

#### Errors only when the clipboard fallback also failed
`insert_text`: Inserts `text` into the focused app. Errors only when even the clipboard
fallback failed.

#### Autocomplete types keystrokes, never via clipboard; false if unsupported
`type_keystrokes`: Types `text` as keystrokes, never through the clipboard (autocomplete).
`Ok(false)` when this session cannot type into other apps.

#### Pasted text marked generated so clipboard history and sync skip it
`paste`: The text only passes through the clipboard, so it is marked as
generated, as on macOS: clipboard history and cloud sync skip it.

#### On failed keystroke, text is left on clipboard as ordinary copy
`paste`: Left there for the user to paste: an ordinary copy from here on.

#### Restore clipboard only if it still holds our text
`paste`: Restore only when the clipboard still holds our text: if the user or
the app copied something meanwhile, that wins.

#### One paste at a time across dictation and selection actions
`PASTE_QUEUE`: One paste at a time across dictation and selection actions.

#### Destination validated after earlier paste finishes (macOS revalidateAfterWaiting)
`paste_checked`: Pastes `text` after `still_valid` confirms the destination, which runs
once an earlier paste has finished (`insertViaPaste(revalidateAfterWaiting:)`).

#### Terminals use Shift+Insert because Ctrl+V is a control character
`PasteCombo::ShiftInsert`: Terminals: Ctrl+V is a control character there.

#### Caller must check who owns the primary selection
`primary_text`: The primary selection's text. The caller checks who owns it.

#### Linux terminals paste primary selection on Shift+Insert, so set it too
`primary`: Most Linux terminals paste the primary selection on Shift+Insert, so it
carries the text too while pasting.

#### Windows typing sends at most 20 UTF-16 units per batch like macOS
`keys (windows)`: `SendInput`: virtual keys for the paste shortcut, `KEYEVENTF_UNICODE`
for typing, in chunks of at most 20 UTF-16 units like macOS.

#### Tap unassigned key before releasing Alt or Win to avoid menus
`MASK_KEY`: An unassigned key, tapped before releasing Alt or Win so the release
does not open a menu or the Start menu.

#### SendInput called with a valid INPUT slice
`send`: SAFETY: `inputs` is a valid slice of INPUT structures.

#### GetAsyncKeyState takes no pointers
`is_down`: SAFETY: no pointers; reads the asynchronous key state.

#### Wait for shortcut modifiers up, then lift any still held
`release_modifiers`: Waits for the dictation shortcut's modifiers to come up, then lifts
any still held so they do not change the keystrokes.

#### Never split a surrogate pair across SendInput batches
`type_text`: Never split a surrogate pair across batches.

#### X11 uses XTest and enigo; Wayland uses wtype then ydotool
`keys (linux)`: X11: XTest for the paste shortcut and `enigo` for Unicode typing.
Wayland: `wtype`, then `ydotool`.

#### Shortcut modifiers may be held; Ctrl+Alt+C is not Copy
`COPY_MODIFIER_WAIT`: The shortcut's modifiers may still be held; Ctrl+Alt+C is not Copy.

#### Copy sent only after other modifiers released, or it is another shortcut
`send_copy`: Sent with other modifiers held, this would be some other shortcut.

#### wtype needs short pause or compositor drops first key
`WTYPE_SETTLE_MS`: wtype creates a new virtual keyboard each run; without a short pause
the compositor can drop the first key while it applies the keymap.

#### ydotool 1.x takes event codes; 0.1.x takes key names
`wayland_paste`: ydotool 1.x takes Linux input event codes (Ctrl 29, V 47,
Shift 42, Insert 110); 0.1.x, as in Ubuntu 24.04, key names.

### `LinuxWindows/crates/lokalbot-platform/src/instance.rs`

#### Single instance per library; IPC socket named by hash of library root
One LokalBot per library, and the local socket other processes use to
reach it.

`lokalbot quick-recall`, `lokalbot selection-actions`,
`lokalbot toggle-recording` and `lokalbot dictate --toggle` forward to the running app through [`send`];
that is also how Wayland users bind compositor shortcuts. The socket is a
Unix socket in the user's runtime directory (mode 0700) or a named pipe on
Windows, named after a hash of the library root so test libraries never
collide.

#### Every IPC line starts with protocol tag so future versions are refused
`PROTOCOL`: Every line starts with this, so an incompatible future protocol is refused
instead of misread.

#### OS releases the instance lock on death, so no stale lock
`InstanceGuard`: Holds the library's instance lock (`<root>/.instance.lock`) until dropped.
The OS releases it if the process dies, so a crash never leaves a stale
lock behind.

#### AlreadyRunning means send the request to the running instance and exit
`acquire_instance`: Takes the instance lock for the library at `root`, creating the folder if
needed. [`InstanceError::AlreadyRunning`] means another LokalBot holds it:
[`send`] the request there and exit.

#### PID written to lock file for diagnostics only
`acquire_instance`: Diagnostics only; the lock itself is what counts.

#### Commands delivered on a background thread, one connection at a time
`IpcServer`: Accepts requests until dropped. Commands are delivered on a background
thread, one connection at a time.

#### Waker connection held open until join to avoid Windows pipe deadlock
`IpcServer::drop`: Wake the blocking accept with a connection of our own, held open until
the thread has gone: a Windows pipe listener skips a client that has
already left, so closing this one first could leave accept waiting and
the join below waiting on it, for good.

#### Call after acquire_instance; stale socket replaced; callback on server thread
`listen`: Listens for [`IpcCommand`]s for the library at `root`. Call after
[`acquire_instance`] succeeded; a leftover socket from a crashed instance
is replaced. `on_command` runs on the server's thread.

#### Only Send required of callback, so requests take turns
`serve`: Only `Send` is required of the callback, so requests take turns.

#### Named pipes lack I/O timeouts, so each client gets its own thread
`serve`: Named pipes have no I/O timeouts, so a stalled client gets
its own thread instead of blocking the next request.

#### send waits a few seconds for acknowledgement
`send`: Delivers `command` to the LokalBot running for the library at `root` and
waits (at most a few seconds) for it to acknowledge.

#### Exchange runs on helper thread so a stuck app cannot hang caller
`send`: The exchange runs on a helper thread so a stuck app cannot hang the
caller, even where the pipe has no timeouts.

#### Loop repeats so stop sometimes lands before accept starts
`stopping_right_after_listening_returns`: Often enough that a stop lands before the accept has started waiting.

#### A crashed instance leaves its socket file behind
`a_stale_socket_is_replaced`: A crashed instance leaves its socket file behind.

### `LinuxWindows/crates/lokalbot-platform/src/lib.rs`

#### Platform crate compiles on both systems and degrades with explanation
Operating-system integration for LokalBot on Linux and Windows: activity
sampling, privacy rules, single instance and IPC, global shortcuts, text
insertion, autocomplete's field reading and key handling, the tray,
notifications, launch at login, meeting detection, calendars, screen
context capture and opening files.

Everything compiles on both systems and degrades with an explanation where
a desktop cannot provide something (for example GNOME on Wayland without a
window-information extension).

#### APP_ID matches GPUI app identity; portals and Windows notifications use it
`APP_ID`: Application id shared with the GPUI app (`cx.set_app_identity`, Wayland
`app_id`). Portals and Windows notifications use it.

### `LinuxWindows/crates/lokalbot-platform/src/media.rs`

#### Every media call is bounded so players cannot hold up push-to-talk
Pausing what is playing while dictation listens, then resuming exactly that
(`MediaPlaybackController.swift`). Linux uses MPRIS over the session bus,
Windows the System Media Transport Controls. Every call is bounded, so a
player that doesn't answer can never hold up push-to-talk.

#### Calls and conference pages are never paused
`CONFERENCE_HOSTS`: Calls and conference pages are never paused, whatever the desktop reports
about them (`pauseHTMLMediaJavaScript`).

#### Browser pages with no length are live or calls; never pause
`BROWSER_PLAYERS`: Browsers publish one player per page. A page with no known length is a live
stream or a call, which pausing would lose (`pauseHTMLMediaJavaScript`).

#### id is MPRIS bus name or Windows app id
`Player.id`: The MPRIS bus name, or Windows' app id for the session.

#### Dropping PausedMedia resumes nothing
`PausedMedia`: What one dictation paused. Dropping it resumes nothing.

#### Returns within deadline; late-answering players still count as paused
`pause_playing`: Pauses what is playing. Returns within [`PAUSE_DEADLINE`], and a player
that answers later still counts as paused by this dictation.

#### Resume only what we paused, unless the person changed it
`resume`: Resumes what [`pause_playing`] paused, unless the person changed it since.

#### MPRIS players slower than 400 ms are skipped
`mpris::CALL_TIMEOUT`: A player that doesn't answer this quickly is skipped.

#### Windows gives no page URL or end; has_length assumed true
`smtc read`: Windows doesn't say which page a browser's session is for, or
whether it has an end.

#### CoInitializeEx balanced below; runs on own or caller thread
`with_players`: SAFETY: balanced below; this runs on a thread of its own or the caller's.

#### CoUninitialize matches CoInitializeEx; manager already gone
`with_players`: SAFETY: matches the CoInitializeEx above; the manager is gone.

#### Player already paused by person stays paused
`only_what_it_paused_is_resumed`: VLC was already paused, by the person: it stays that way.

#### No length means live stream or call on unknown site
`calls_and_live_pages_are_never_paused`: No length: a live stream, or a call on a site this list doesn't know.

### `LinuxWindows/crates/lokalbot-platform/src/notify.rs`

#### Linux uses freedesktop Notifications, Windows toasts; callbacks on background thread
Desktop notifications (`RecordingNotifier.swift`): "Meeting detected /
Record \<title>?" with Record and Ignore, "Recording saved", and friends.

Linux uses `org.freedesktop.Notifications` with actions; Windows shows a
toast with buttons. Action callbacks run on a background thread, one per
notification that has actions; forward them to the app.

#### Meeting prompts withdrawn after two minutes as on macOS
`MEETING_PROMPT_LIFETIME`: "Meeting detected" prompts are withdrawn after two minutes on macOS.

#### on_action receives chosen id or default on body click
`notify`: Posts a notification. `actions` are `(id, label)` pairs; `on_action`
receives the chosen id, or "default" when the notification body is clicked.

#### Body click arrives only as registered default action; label rarely shown
`notify_with_timeout`: A click on the body reaches `on_action` only as the "default" action,
which a server sends only for a notification that registered it. Most
desktops never show its label.

#### Show runs on a thread so stuck service cannot block caller
`notify_with_timeout`: A stuck notification service must not hold up the caller.

#### Windows toast body is its own response, not wait_for_action closed
`notify_with_timeout`: A toast reports its body as a response of its own, which
`wait_for_action` would hand over as "closed".

#### Servers ignoring expiry like GNOME are asked to withdraw it
`notify_with_timeout`: Servers that ignore the expiry (GNOME keeps it in its list) are
asked to withdraw it, like the macOS prompt.

#### Check avoids waiting on D-Bus activation timeout
`server_available`: Whether something owns `org.freedesktop.Notifications` or D-Bus can start
it. Without this check, posting waits for D-Bus activation to time out.

#### Without registered app id, toasts show under Windows PowerShell
`windows_app_id`: Windows shows a toast under a registered app id (a Start menu shortcut
carrying `System.AppUserModel.ID`, created by the installer). Without one,
toasts appear under Windows PowerShell rather than not at all.

#### No server over SSH must error not hang; Linux only
`posting_without_a_desktop_fails_cleanly`: Needs a notification server; over SSH there is none, which must be an
error rather than a hang or a crash. Linux only: on Windows a toast
would reach the signed-in user's desktop.

### `LinuxWindows/crates/lokalbot-platform/src/opener.rs`

#### Only web and mail schemes so meeting or model text cannot launch handlers
`open_url`: Opens a web or mail link in the default browser or mail app. Other
schemes are refused, so text from meetings or models cannot launch
arbitrary handlers.

#### explorer /select, needs quoted path passed verbatim
`reveal`: explorer.exe parses its own command line: the path must follow
"/select," inside quotes, so the argument is passed verbatim.

### `LinuxWindows/crates/lokalbot-platform/src/power.rs`

#### Windows has no heat reading, so is_hot always false there
Whether the computer is on battery, saving power or running hot, so power-aware
features can wait (`PowerSourceMonitor`, `ProcessInfo.thermalState`).

Linux reads sysfs; Windows asks `GetSystemPowerStatus`. Windows has no heat
reading an ordinary program can make, so `is_hot` is always false there.

#### Unknown counts as plugged in and cool
`current`: The state now. Unknown counts as plugged in and cool: desktops report nothing.

#### Device-scope batteries ignored; battery runs machine only when no supply online
`battery_state`: `(has_battery, on_battery)`: peripherals' batteries (a mouse, headphones)
report `scope = Device` and don't count. A battery runs the computer only
when no mains or USB supply is online and it reads as discharging.

#### low-power or quiet profile counts as saving power
`saving_power`: The firmware's power profile, which power-profiles-daemon sets too.

#### Hot is first throttling point, or past 90 C when none
`is_hot`: A CPU zone at its first throttling point, or past 90 °C when it names none.

#### Non-processor thermal zones never count, however warm
`profiles_and_heat`: A zone that isn't the processor doesn't count, however warm.

#### Without a throttling point, hot means past 90 C
`profiles_and_heat`: No throttling point: past 90 °C.

### `LinuxWindows/crates/lokalbot-platform/src/privacy.rs`

#### Privacy rules favor false positives because stored credentials cannot be recalled
Privacy rules for day memory, ported from `ScreenContextPrivacy.swift`:
app and site exclusions, password managers, and secret redaction.

The rules favor false positives on purpose: a redacted title stays useful,
while a stored credential cannot be taken back.

#### Excluded apps and sites are stored under the app name Private
`PRIVATE_APP`: App name stored for excluded apps and sites (`activity_blocks.app`).

#### Samplers give LokalBot's own windows this id; titles never read
`SELF_APP_ID`: `app_id` the samplers give LokalBot's own windows. Their titles are never
read and [`disposition`] skips them.

#### Mirrors ScreenContextPrivacy.activityDisposition: what day memory may store per sample
`SampleDisposition`: What day memory may store for one sample
(`ScreenContextPrivacy.activityDisposition`).

#### Keep stores redacted title, empty if site exclusion uncertain, sanitized URL
`SampleDisposition::Keep`: Store the sample. The title is redacted, or empty when a configured site
exclusion cannot be ruled out; the URL is sanitized.

#### Excluded app or site stores time only: app Private, empty title, no URL
`SampleDisposition::Private`: An excluded app or site: store the time as app [`PRIVATE_APP`] with an
empty title and no URL.

#### Skip stores nothing for own windows and lock screen, leaving current block
`SampleDisposition::Skip`: Store nothing and leave the current block as it is, as when no app is
frontmost: LokalBot's own windows and the lock screen.

#### Applies user exclusions, built-in password-manager list and title redaction
`disposition`: Applies the user's exclusions, the built-in password-manager list and
title redaction to one sample.

#### Browser with unknown address keeps only its time under site exclusions
`disposition_with_rules`: A browser whose address is unknown cannot be shown to be outside a
configured site exclusion, so only its time is kept.

#### Own app and lock screens are not activity
`is_skipped`: App ids whose windows are not activity: LokalBot itself and lock screens.

#### Password managers are never captured regardless of the editable exclusion list
`PASSWORD_MANAGER_IDS`: Password managers and credential prompts are never captured, whatever the
editable list says. Ids are desktop-file ids, Wayland app ids, `WM_CLASS`
values and Windows executable names (lowercase).

#### credentialuibroker.exe is the Windows Security credential prompt
`PASSWORD_MANAGER_IDS`: The Windows credential prompt ("Windows Security").

#### Display names of password managers are matched case-insensitively
`PASSWORD_MANAGER_NAMES`: Display names of the same apps, compared case-insensitively.

#### Any app name starting with keepass counts as a password manager
`is_password_manager`: KeePass, KeePassXC, KeePassX, "KeePass Password Safe".

#### App rule matching: name substring, or dotted id equal or dotted prefix
`is_excluded_app`: A rule excludes an app when it is a case-insensitive substring of the app
name, or when it contains a dot and equals the app id or a dotted prefix of
it (`ScreenContextPrivacy.isExcluded(appName:bundleIdentifier:rules:)`).

#### Site rule forms: URL prefix, host or *.host with subdomains, host/path
`is_excluded_url`: Whether a page address matches a site rule: a URL prefix (`https://x/y`),
a host or `*.host` (subdomains included), or `host/path`
(`ScreenContextPrivacy.isExcluded(sourceURL:rules:)`).

#### Stored addresses drop credentials, query and fragment, capped at 800 characters
`sanitized_url`: Removes credentials, query and fragment before an address is stored, at
most 800 characters (`ScreenContextPrivacy.sanitizedURL`).

#### Mirrors ScreenContextPrivacy.isPrivateWindow for private or incognito titles
`is_private_window`: Private or incognito window titles (`ScreenContextPrivacy.isPrivateWindow`).

#### Stands in for Swift lookahead: capture must not already be a marker
`Guard::NotRedacted`: Stands in for the Swift `(?!\[REDACTED)` lookahead: the capture group
must not already be a redaction marker.

#### Card and IBAN candidates must pass their checksum
`Guard::Checksum`: Card and IBAN candidates must pass their checksum.

#### Built-in redaction patterns failing to compile is a programming error caught by tests
`Rule::new`: Built-in patterns; a failure is a programming error caught by tests.

#### A rejected match is retried one character later, like Swift lookahead
`Rule::apply`: Replaces every accepted match. A rejected match is retried one
character later, which is how the Swift lookahead behaves.

#### Secret names may carry a prefix such as DB_PASSWORD
`RULES`: The name may carry a prefix ("DB_PASSWORD", "aws_secret_access_key").

#### URL credentials redact only the password, keeping user and host
`RULES`: "postgres://admin:hunter22@db:5432" keeps its user and host.

#### Checksummed numbers are payment cards or IBANs; Swift backreferences spelled out per separator
`CHECKED_RULES`: Numbers whose checksum makes them almost certainly a payment card or an
IBAN. The Swift card pattern's `\1`/`\2` backreferences are spelled out
per separator.

#### Redaction replaces secrets, cards, IBANs with markers and returns replacement count
`redact`: Replaces credentials, tokens, private keys, payment cards and IBANs with
markers. Returns the text and how many replacements were made
(`ScreenContextPrivacy.redact`).

#### Card needs a known issuer prefix and a valid Luhn checksum
`is_payment_card_number`: A known issuer prefix and a valid Luhn checksum
(`ScreenContextPrivacy.isPaymentCardNumber`).

#### Recognized issuers: Visa, Mastercard, Amex, Diners, Discover, JCB, UnionPay
`is_payment_card_number`: Visa, Mastercard, Amex, Diners, Discover, JCB, UnionPay.

#### IBAN validity uses the mod-97 check, as in Swift isIBAN
`is_iban`: The IBAN mod-97 check (`ScreenContextPrivacy.isIBAN`).

#### Too-short values are not treated as secrets
`key_value_secrets_keep_their_names`: Too short to be a secret.

#### Opening quote is consumed, matching the Swift template
`key_value_secrets_keep_their_names`: The opening quote is consumed, as in the Swift template.

#### Lookahead port retries after a rejected match, so later secrets are redacted
`a_skipped_marker_does_not_hide_a_later_secret`: The lookahead port retries after a rejected match.

#### Failing Luhn keeps an order number readable
`cards_and_ibans_need_a_valid_checksum`: Luhn fails: an order number stays readable.

#### Mixed separators are not treated as a card
`cards_and_ibans_need_a_valid_checksum`: Mixed separators are not a card.

#### Built-in password-manager list applies even when the user cleared theirs
`excluded_apps_and_password_managers_become_private`: Built-in list even when the user cleared theirs.

### `LinuxWindows/crates/lokalbot-platform/src/process.rs`

#### Desktop tool helpers must never hang the caller
Small helpers for running desktop tools (`pactl`, `wtype`, `ydotool`,
`gdbus`) without ever hanging the caller.

#### Read both pipes on own threads so chatty tools cannot block on a full pipe
`output_with_timeout`: Read both pipes on their own threads so a chatty tool cannot block
on a full pipe while we wait for it.

### `LinuxWindows/crates/lokalbot-platform/src/process_usage.rs`

#### Per-process CPU time and resident memory for SystemResourceSampler, from /proc or Windows APIs
What one process has used so far (`SystemResourceSampler`): CPU time and
resident memory, from `/proc` on Linux and the process APIs on Windows.

#### CPU seconds are user plus kernel time since process start
`ProcessUsage.cpu_seconds`: User and kernel time since it started.

#### Installed memory is used to choose a model preset
`total_memory_bytes`: Installed memory, for choosing a model preset.

#### Memory status struct must be initialized with its length field set
`total_memory_bytes`: SAFETY: the struct is initialized and its length field set, as the API requires.

#### Returns None when the process is gone or unreadable
`process_usage`: `None` when the process is gone or can't be read.

#### Process handle is checked, used only here and closed before returning
`process_usage`: SAFETY: the handle is checked, used only here and closed before returning,
and the out-parameters are valid for the calls.

#### /proc stat counts in USER_HZ, 100 on shipped platforms
`parse_proc`: `/proc/<pid>/stat` counts in `USER_HZ`, which is 100 on the platforms we ship.

#### Process name may hold spaces and parentheses; fields resume after last parenthesis
`parse_proc`: The process name can hold spaces and parentheses; fields resume after the last `)`.

#### utime and stime are fields 14 and 15; rest starts at field 3
`parse_proc`: utime and stime are fields 14 and 15; `rest` starts at field 3.

### `LinuxWindows/crates/lokalbot-platform/src/selection.rs`

#### Selection read order, X11 primary rules, no Wayland primary, memory only
Reads the text selected in the frontmost app, once, on an explicit shortcut
press (`SelectionCapture.swift`). Accessibility comes first. On X11 the
primary selection follows, only when its owner is the frontmost app. Apps
that share neither get a synthetic Ctrl+C whose result is read and the
previous clipboard put back, never in a terminal, where Ctrl+C is an
interrupt.

The primary selection is not read on Wayland: its owner cannot be checked
there, so a stale one could come from an excluded app. The text lives only
in memory for the panel's lifetime.

#### Longest selection kept in memory; prompt uses less
`MAX_CHARACTERS`: Longest selection kept in memory; the prompt uses less.

#### Unverifiable or changed focus means no selection is accepted
`SelectionIssue::FocusChanged`: Focus changed or could not be verified; no selection is accepted.

#### Target is the editable field; None for read-only or no accessibility
`SelectionCapture.target`: The editable field the selection sits in, where a result can replace
it or go in at the caret. `None` for read-only text, or when the app
shares no accessibility.

#### Host trait lets the order of checks be tested without a desktop
`CaptureHost`: What the capture needs from the desktop, so its order of checks can be
tested without one.

#### Primary selection is read only when its owner is the source app (X11)
`CaptureHost::primary`: The primary selection, when its owner is `source` (X11).

#### Re-read the source after every step that can take time
`capture_with`: The order of checks in `SelectionCapture.capture`. The source is re-read
after every step that can take time.

#### Only editable fields have an identity; read-only text cannot be replaced
`capture_with`: Only an editable field has an identity; read-only text cannot take a
replacement.

#### Wayland may not name the process; accessibility knows which one has the field
`capture_with`: A Wayland desktop may name the app but not its process; accessibility
knows which one has the field.

#### Empty selection in an editable field makes older primary selection stale
`capture_with`: An editable field with nothing selected: an older selection in the
same app would be stale.

#### Capture blocks; call from a background thread
`capture`: The capture on this desktop. Blocking: call from a background thread.

#### When LokalBot is frontmost a shortcut press keeps its panel
`lokalbot_is_frontmost`: True when LokalBot itself is the frontmost app, so a press keeps its panel.

#### Copy allowed only if app is in front and field not secure
`CopyHost::is_allowed`: The app is in front and its focused field is not a secure one.

#### Clipboard text is skipped when marked concealed
`CopyHost::read_text`: The clipboard's text, unless it is marked concealed.

#### Clipboard managers may record the copy; newer clipboard changes are not restored over
`copy_selection`: The copy from `SelectionClipboardCopy`. The app's own copy may be recorded
by a clipboard manager, as any copy the person makes would be. A newer
clipboard change is not ours to restore.

#### No clipboard change means nothing selected and clipboard untouched
`copy_selection`: Nothing selected: the app copied nothing and the clipboard is untouched.

#### Re-check app and secure field after Copy; never read if changed
`copy_selection`: Re-checked after the app handled Copy: a changed app or secure field is
never read.

#### One copy at a time; a second press waits for restore
`COPY_QUEUE`: One copy at a time: a second press waits for the first to restore.

#### Without a clipboard watch (Wayland), compare against prior text
`LiveCopy.before`: Without a watch (Wayland): the text the clipboard held before.

#### Password manager copies carry a marker and are never read
`clipboard_is_concealed`: A password manager's copy carries a marker; such an item is never read.

#### Safety: constant NUL-terminated format name, clipboard not opened
`clipboard_is_concealed`: SAFETY: a constant, NUL-terminated format name; no clipboard is opened.

#### Primary selection read only when pid owns it; X11 only
`primary_owned_by`: The primary selection, when `pid` owns it. X11 only.

#### KeePassXC and others mark copies with this target
`linux::CONCEALED`: KeePassXC and others mark what they copy with this target.

#### An owner that does not answer in time is treated as not concealed
`linux::offers_concealed`: Whether a selection's owner offers the concealed target. An owner that
does not answer in time offers nothing we know of.

#### Re-verify selection ownership after reading the text
`linux::primary_owned_by`: It must still be that app's selection once the text is in hand.

#### On Wayland, wl-paste lists what the source offers
`linux::clipboard_is_concealed`: Wayland: wl-clipboard can list what the source offers.

#### Terminal widgets inside non-terminal apps also never get a copy keystroke
`terminals_never_get_a_copy_keystroke`: A terminal widget in an app that is not itself a terminal.

### `LinuxWindows/crates/lokalbot-platform/src/session.rs`

#### Desktop session is decided at runtime so one Linux build serves all
Which desktop session LokalBot runs in, decided at runtime so one Linux
build serves X11 and every Wayland desktop.

#### Hyprland and Sway tile windows but float ones with a parent
`Desktop::tiles_windows`: Hyprland (Omarchy) and Sway tile every ordinary window. Both float a
window that has a parent window, as they do dialogs.

#### In Wayland sessions X11 only sees XWayland windows
`is_wayland`: True in a Wayland session, where X11 only sees XWayland windows.

#### Run once on SIGTERM/SIGHUP/SIGINT to save recording; second signal ends process
`on_termination`: Runs `then` once when the system asks this process to end (SIGTERM on
logout or a `kill`, SIGHUP, or Ctrl+C in a terminal), so a recording can be
saved first. A second signal ends the process right away.

#### Safety: signal is async-signal-safe, restores default handler
`on_termination`: SAFETY: `signal` is async-signal-safe, and this restores the default.

#### Safety: handler only touches an atomic and signal
`on_termination`: SAFETY: the handler only touches an atomic and `signal`.

### `LinuxWindows/crates/lokalbot-platform/src/shortcuts.rs`

#### Shortcut backends per platform, portal gaps, threading rules for handler
System-wide shortcuts for dictation and Ask.

[`Shortcut`] parses the strings stored in settings ("Ctrl+Shift+Space",
"Alt+Space") and validates them with the macOS rules
(`DictationShortcut.problem`, `QuickRecallHotKeyController.problem`).
[`GlobalShortcuts`] registers them: `global-hotkey` on Windows and X11
(press and release, for push to talk), and the XDG `GlobalShortcuts`
portal on Wayland. Desktops without the portal (Sway, GNOME before 48)
get a clear error; users there bind a desktop shortcut to the
`lokalbot dictate --toggle` / `lokalbot quick-recall` commands, which reach
the app through [`crate::instance`].

Threading: create and use [`GlobalShortcuts`] from any one thread (the GPUI
main thread is fine); it runs its own worker thread. The handler is called
on a background thread (Windows: the worker for presses and a short-lived
thread for releases; X11: `global-hotkey`'s X11 thread; Wayland: the portal
thread), so it must not block: forward the event to the app.

#### Char keys are A-Z, 0-9 or listed punctuation
`Key::Char`: `A`–`Z`, `0`–`9`, or one of `` -=[]\;',./` ``.

#### Function keys span F1 to F24
`Key::Function`: F1–F24.

#### Named keys mirror DictationShortcutKeyNames.isNamedKey on Mac
`Key::is_named`: Keys that do not type a character (`DictationShortcutKeyNames.isNamedKey`).

#### Portal expects xkb keysym names
`Key::keysym_name`: The xkb keysym name the shortcuts portal expects.

#### Shortcut mirrors DictationShortcut on Mac
`Shortcut`: A key with modifiers, or modifiers alone (`DictationShortcut`).

#### None means a modifier-only chord
`Shortcut.key`: `None` for a modifier-only chord such as Ctrl+Alt.

#### Ctrl+Shift+Space is the default Ask shortcut
`Shortcut::QUICK_RECALL_DEFAULT`: Ctrl+Shift+Space opens Ask (`quickRecallShortcut`).

#### Alt+Space is the default dictation shortcut
`Shortcut::DICTATION_DEFAULT`: Alt+Space starts dictation (`dictationShortcut`).

#### Accepted formats include names, modifier-only chords and Mac symbols
`Shortcut::parse`: Parses "Ctrl+Shift+Space", "alt+space", "Super+D", "F5", "Ctrl+Alt",
and the macOS symbols ("⌃⇧ Space").

#### Dictation validation follows Mac rules; ask is the Ask shortcut if enabled
`Shortcut::dictation_problem`: Why this cannot be the dictation shortcut, or `None`
(`DictationShortcut.problem`). `ask` is the Ask shortcut, if enabled.

#### Selection actions need a key and differ from other enabled shortcuts
`Shortcut::selection_actions_problem`: Why this cannot open selection actions, or `None`. Like Ask it needs a
key, and it must differ from the other two shortcuts when they are on.

#### Cancel is Escape with the shortcut's modifiers possibly still held
`Shortcut::cancel_key`: Plain Escape, or Escape with this shortcut's modifiers still held, the
keys that cancel a dictation (`isEscape(allowing:)`).

#### Ask shortcut always needs a key; follows Mac controller
`Shortcut::quick_recall_problem`: Why this cannot open Ask, or `None`
(`QuickRecallHotKeyController.problem`). Ask always needs a key.

#### A single modifier alone fires for any other use
`Shortcut::typing_problem_where`: One modifier alone fires whenever it is used for anything else.

#### Ctrl plus character conflicts with Copy, Save, Undo
`Shortcut::typing_problem_where`: Ctrl plus a character is how apps here spell Copy, Save, Undo….

#### Portal trigger uses XDG format like CTRL+SHIFT+space
`Shortcut::portal_trigger`: The XDG shortcuts trigger ("CTRL+SHIFT+space") for the portal.

#### Reserved combos are taken by system; Ctrl+Shift+W closes tabs
`RESERVED`: Combinations the system takes before any app sees them, and Ctrl+Shift+W,
which closes tabs and windows in most apps here (the Mac's default for
selection actions).

#### Alt+Shift alone switches input language
`RESERVED`: Switching the input language, held alone.

#### Problems mirror DictationShortcut.Problem on Mac
`ShortcutProblem`: Why a combination cannot be used (`DictationShortcut.Problem`).

#### Modifier chords need keyboard state that Wayland denies apps
`ShortcutProblem::ModifierOnlyUnsupported`: Modifier chords (Ctrl+Alt alone) need to read the keyboard's state, which
Wayland doesn't let an app do.

#### Message mirrors QuickRecallHotKeyController failure text
`ask_registration_failed_message`: Shown when Ask's shortcut fails to register (`QuickRecallHotKeyController`).

#### Message mirrors applySelectionActionsSetting failure text
`selection_actions_registration_failed_message`: Shown when selection actions' shortcut fails to register
(`applySelectionActionsSetting`).

#### Page then shows Shortcut inactive
`dictation_registration_failed_message`: Shown when dictation's shortcut fails to register. The page then says
"Shortcut inactive."

#### Modifier-only chords decide for themselves what a press means
`ShortcutEvent.chord`: A chord of modifiers alone decides for itself what the press means.

#### Create only one GlobalShortcuts per process
`GlobalShortcuts`: Registers global shortcuts until dropped. Create one per process.

#### Chords take nothing from other apps; only keyboard-reading limits refuse
`GlobalShortcuts::register_chord`: Starts watching a chord of modifiers alone under `id`. Nothing is taken
from other apps, so nothing can refuse it except a desktop that doesn't
let an app read the keyboard. `active` says whether a dictation is
starting or recording.

#### On Wayland register returns after request sent or few seconds; binding completes later
`GlobalShortcuts::register`: Registers `shortcut` under `id`, replacing what `id` had. On Wayland
the desktop may ask the user to confirm the shortcut; the call returns
once the request is sent (or after a few seconds) and the binding then
completes in the background.

#### Hotkey worker runs its own Win32 message loop, not GPUI's
`hotkey`: `global-hotkey` behind a worker thread. On Windows its hidden window
needs a message loop on the thread that created it, so the worker runs
one; GPUI's main-thread loop is never involved.

#### global-hotkey allows one handler per process; forward to current worker
`hotkey::Dispatch`: `global-hotkey` allows one event handler per process; it forwards
here, to whichever [`Worker`] is current.

#### Error 1459 means a service or SSH session
`hotkey::NO_INTERACTIVE_DESKTOP`: `ERROR_REQUIRES_INTERACTIVE_WINDOWSTATION`: a service or SSH session.

#### Portal runs on own thread and connection under app id to remember choices
`portal`: The XDG `GlobalShortcuts` portal (KDE Plasma, Hyprland, GNOME 48+).
Runs on its own thread and D-Bus connection, registered under the
app id so the desktop can remember the user's choices.

#### register waits at most 3 seconds for the desktop
`portal::REPLY_WAIT`: How long `register` waits for the desktop before returning.

#### Timeout is treated as success; desktop is likely showing confirmation
`portal::Worker`: The desktop is probably showing its confirmation dialog.

#### Older portals lack a registry and identify the app themselves
`portal run`: Older portals have no registry; they identify the app themselves.

#### A session serializes as its object path
`portal::session_path`: A session serializes as its object path.

#### Over SSH keys cannot be pressed but registration must work
`windows_registration_round_trip`: Exercises the worker thread and its message loop. Over SSH (session 0)
the keys can never be pressed, but registration must still work.

#### SSH runs in session 0 without an interactive desktop
`windows_registration_round_trip`: SSH runs in session 0, which has no interactive desktop.

### `LinuxWindows/crates/lokalbot-platform/src/win32_loop.rs`

#### Hidden windows receive messages on creating thread, so each runs own loop
A Win32 message loop on a worker thread. Hidden windows created by
`global-hotkey` and `tray-icon` receive their messages on the thread that
created them, so each runs one of these instead of relying on GPUI's
main-thread loop.

#### Safety: posting pointer-free message is memory-safe; exited thread just fails
`wake`: SAFETY: posting a message without pointers to a thread id is always
memory-safe; a thread that has exited only makes the call fail.

#### Safety: msg is valid and calls touch only this thread's queue
`run`: SAFETY: `msg` is a valid, writable MSG for each call; these functions
only touch this thread's message queue.

#### Create the thread's message queue before anyone posts to it
`run`: Creates the thread's message queue before anyone posts to it.

### `LinuxWindows/crates/lokalbot-platform/tests/live_dbus.rs`

#### D-Bus round trips are ignored by default; run on private bus
Notification and tray round trips against fake D-Bus servers, ignored by
default. Run on a private bus: `dbus-run-session -- cargo test -p
lokalbot-platform --test live_dbus -- --ignored --test-threads=1`.

#### Update and approval notifications have only a body click to report
`a_click_on_a_notification_without_buttons_reaches_the_callback`: The update and settings-approval notifications have no buttons: a click on
the body is all they can report, and nothing listened for it.

#### Notifications without a callback offer no action
`a_notification_without_a_callback_offers_no_action`: Nothing is listening for a click that nobody asked to hear about.

#### Tooltip tuple is icon name, pixmaps, title, description
`ToolTip`: Icon name, pixmaps, title and description.

#### Item announces changes by signals, so read properties fresh not cached
`tray_menu_items_reach_the_callback`: The item announces changes with its own signals, so read properties
fresh instead of from zbus's cache.

### `LinuxWindows/crates/lokalbot-platform/tests/live_desktop.rs`

#### Live desktop checks ignored by default; need Xvfb, window manager, titled window
Checks against a real desktop session, ignored by default. Run them with a
display, for example `scripts/live-x11.sh` style: Xvfb, a window manager
and a titled window, then
`LOKALBOT_EXPECT_TITLE=… cargo test -p lokalbot-platform --test live_desktop -- --ignored`.

### `LinuxWindows/crates/lokalbot-platform/tests/live_input_method.rs`

#### Live input-method test uses one virtual US-keymap keyboard for whole run
Autocomplete's input method against a real compositor and real GTK fields,
ignored by default. Run it with `crates/lokalbot-platform/scripts/live-sway.sh`,
which also needs Python with GTK 3 (`gi`).

The keyboard here is one virtual keyboard with a US keymap for the whole
run, so keys arrive with a physical keyboard's scancodes and without the new
device, and the focus events that go with it, that each `wtype` run makes.

#### Remove LD_LIBRARY_PATH because GTK must not load Cargo's build output
`GtkField::start`: Cargo points this at its build output, which GTK must not load from.

#### Sway focuses a text field only once the seat has a keyboard
`sway_input_method_shows_accepts_and_stays_out_of_passwords`: Sway focuses a text field only once the seat has a keyboard.

#### Wait up to 40 s for the young session to settle before taking the seat
`sway_input_method_shows_accepts_and_stays_out_of_passwords`: The seat is taken once the young session has settled.

#### KWin has no virtual keyboard protocol; keys go through its EIS endpoint like remote desktop
`EisKeyboard`: A keyboard under KWin, which offers no virtual keyboard protocol: keys go
in through its EIS endpoint, as a remote desktop session's do, so they take
the same path through KWin as a real keyboard's.

#### KWin names the app so an excluded app is refused before its text is used
`kwin_input_method_shows_accepts_and_stays_out_of_passwords`: KWin names the app, so an excluded one is refused before its text is used.

#### Quitting with a suggestion showing leaves the field intact and typing continues
`kwin_input_method_shows_accepts_and_stays_out_of_passwords`: Quitting LokalBot with a suggestion on show leaves the field as it was,
and typing goes on as without an input method.

### `LinuxWindows/crates/lokalbot-platform/tests/live_wayland.rs`

#### Wayland checks run in headless Sway, ignored by default, via live-sway.sh
Wayland checks inside a headless Sway session, ignored by default. Run
them with `crates/lokalbot-platform/scripts/live-sway.sh`.

#### App name comes from foot's desktop entry
`sway_sampler_idle_typing_and_paste`: Named from foot's desktop entry (org.codeberg.dnkl.foot.desktop).

#### Paste into foot terminal uses Shift+Insert with primary selection set
`sway_sampler_idle_typing_and_paste`: foot is a terminal: Shift+Insert with the primary selection set.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
