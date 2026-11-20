# 0107. Windows and Linux: platform — activity

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-platform/src/activity/`.

## Decisions

### `LinuxWindows/crates/lokalbot-platform/src/activity/desktop_entries.rs`

#### Resolve friendly app names via StartupWMClass, desktop id or executable
Friendly app names from `.desktop` files, the Linux counterpart of an
app's `localizedName`: `StartupWMClass`, the desktop-file id or the
executable picks the entry, whose `Name` (localized) is shown.

#### First match wins in XDG precedence, user folders before system
`DesktopEntries`: Lookup tables over every visible `.desktop` file, first match wins in
XDG precedence (user folders before system ones).

#### Match short X11 class to reverse-DNS desktop ids like org.mozilla.firefox
`DesktopEntries::resolve`: "firefox" → org.mozilla.firefox.desktop

#### Skip env prefix, honor quotes, drop folder; Flatpak matched by id
`exec_basename`: The program an `Exec=` line runs: skips `env VAR=…`, honors quotes, and
drops the folder. Flatpak launchers are matched by id instead.

#### Use /proc exe name, fall back to comm
`process_name`: The executable's file name for a process: `/proc/<pid>/exe`, else `comm`.

#### Replaced binary reads name (deleted); strip suffix
`process_name`: A replaced binary reads "name (deleted)".

#### Re-read desktop folders at most once a minute when an app is missing
`AppNames`: Resolves windows to app names, re-reading the `.desktop` folders at most
once a minute when an app is not found (it may have just been installed).

#### Wayland ids like org.gnome.Nautilus use the last segment
`fallback app name`: Wayland ids like "org.gnome.Nautilus": keep the last part.

### `LinuxWindows/crates/lokalbot-platform/src/activity/idle.rs`

#### Idle backends: X11 MIT-SCREEN-SAVER, Mutter IdleMonitor, ext-idle-notify-v1, ScreenSaver
Seconds since the last input on Linux. X11 asks MIT-SCREEN-SAVER; GNOME
asks Mutter's IdleMonitor; other Wayland compositors use the
`ext-idle-notify-v1` protocol, then `org.freedesktop.ScreenSaver`.

#### Mutter GetIdletime reports milliseconds
`MutterIdle`: GNOME: `org.gnome.Mutter.IdleMonitor.GetIdletime`, in milliseconds.

#### ScreenSaver idle unit is seconds per spec but KDE uses ms; learn from growth
`ScreenSaverIdle`: `org.freedesktop.ScreenSaver.GetSessionIdleTime`. The specification says
seconds; KDE answers in milliseconds. The unit is learned from how fast
the value grows while the user is away.

#### ext-idle-notify v2 ignores inhibitors like video, matching macOS input idle
`IdleNotify`: `ext-idle-notify-v1`: the compositor says when input has been quiet for a
second and when it resumes, which gives the idle time exactly. Version 2
ignores idle inhibitors such as a playing video, like macOS input idle.

#### Dispatch thread ends with the source or session at next event
`IdleNotify dispatch thread`: Ends with the source (or the session) at the next event.

### `LinuxWindows/crates/lokalbot-platform/src/activity/linux.rs`

#### Desktop-file id comes from the compositor on KDE
`FocusedWindow.desktop_file`: A desktop-file id the compositor reported (KDE).

#### Half-second call timeout so a stuck service never stalls sampling
`session_bus`: A session-bus connection whose calls give up after half a second, so a
stuck desktop service never stalls sampling.

#### Only X11, Hyprland, Sway list windows; others rely on observed focus changes
`WindowLister`: Titles of all windows, where the desktop can list them (X11, Hyprland,
Sway). Elsewhere meeting detection relies on observed focus changes.

#### Use day memory name rules so autocomplete exclusions match Privacy names
`AppResolver`: App names and ids for other features, by day memory's rules, so
autocomplete's exclusions match the names Privacy shows.

#### Input method is told the field but not its window, so ask compositor
`FrontWindows`: Asks the compositor which window is in front, for autocomplete's input
method, which is told about a text field but not whose it is.

### `LinuxWindows/crates/lokalbot-platform/src/activity/mod.rs`

#### Backend chosen at runtime; sampled every 5 s with disposition applied; mirrors ActivitySampler
The frontmost app and window title, and how long the user has been idle
(`ActivitySampler` in `ActivityTracker.swift`).

[`activity_source`] picks the backend at runtime: Win32 on Windows; on
Linux, X11 (EWMH) or the Wayland compositor's own interface (Hyprland,
Sway, KDE Plasma, GNOME with a window-information extension). The engine
samples every 5 s from a background thread and runs [`crate::disposition`]
on each sample before storing it.

#### Implementations must not block long; calls bounded by short timeouts
`ActivitySource`: One way of reading the focused window. Implementations must not block for
long: each call is bounded by short timeouts.

#### None when nothing focused; own windows return LokalBot with no title; Err is backend failure
`ActivitySource::sample`: The frontmost window now, or `None` when nothing is focused (the
desktop, a lock screen, a headless session). LokalBot's own windows
come back as app "LokalBot" with [`crate::privacy::SELF_APP_ID`] and no
title. Errors mean the backend itself failed.

#### Backend names used in diagnostics
`ActivitySource::backend_name`: Short name for diagnostics: `win32`, `x11`, `hyprland`, `sway`, `kwin`,
`gnome-extension`, `unavailable`.

#### Cheap lowercase app hint for paste choice; None on GNOME/KDE Wayland
`focused_app_hint`: A quick, lowercase identifier for the focused app (executable, `WM_CLASS`
or app id), for choosing how to paste. `None` where the desktop cannot
tell cheaply (GNOME and KDE on Wayland).

#### Own windows sampled with app name only, no title
`own_window_sample`: The sample for LokalBot's own windows: app name only.

### `LinuxWindows/crates/lokalbot-platform/src/activity/wayland.rs`

#### No common Wayland focus API; ask each compositor through its own interface
Wayland has no common way to see the focused window, so each compositor
is asked through its own interface: Hyprland's IPC socket, Sway's i3 IPC,
a short KWin script on KDE Plasma, and on GNOME the "Window Calls" or
"Focused Window D-Bus" Shell extension when installed.

#### Socket path under XDG_RUNTIME_DIR since Hyprland 0.40, /tmp before
`Hyprland`: `j/activewindow` on `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket.sock`
(`/tmp/hypr/…` before Hyprland 0.40).

#### Empty workspace or output can hold focus; ignore non-window nodes
`Sway focused node`: An empty workspace or an output has the focus.

#### One-shot KWin script reports active window over D-Bus, like kdotool; Plasma 5 and 6
`Kwin`: Loads a one-shot KWin script that reports the active window back over
D-Bus, the way kdotool does; works with Plasma 5 and 6.

#### Try Plasma 6 script path first, then Plasma 5
`Kwin::run_script`: Plasma 6 path first, then Plasma 5.

#### Recheck for extension every minute so installing starts tracking without restart
`Gnome`: Looks for a supported extension again every minute, so installing one
starts tracking without a restart.

#### FocusedWindow errors while nothing focused; only Unknown* errors mean absent
`Gnome::detect`: Fails while nothing is focused, so only "unknown" counts.

#### FocusedWindow raises an error while nothing has focus
`Gnome::read`: Raised while nothing has focus.

#### Extension disabled or removed: forget it and look again later
`Gnome::focused`: Disabled or removed since: look again later.

### `LinuxWindows/crates/lokalbot-platform/src/activity/win32.rs`

#### App name from FileDescription, ProductName, then file name; idle via GetLastInputInfo
Windows: the foreground window (`GetForegroundWindow`), its title, the
owning process's name from its executable's version resources
(`FileDescription`, then `ProductName`, then the file name), and idle time
from `GetLastInputInfo`.

#### Store apps draw in ApplicationFrameHost; real app owns a child window
`WindowsSource::sample`: Store apps draw inside ApplicationFrameHost; their own process owns
a child window.

#### Progman and WorkerW are the desktop; clear the title
`WindowsSource::sample`: The desktop itself ("Program Manager").

#### GetTickCount and dwTime wrap together every 49.7 days
`WindowsSource::idle_seconds`: SAFETY: no arguments. Both values wrap every 49.7 days together.

#### Same name rules as day memory, used for autocomplete exclusions
`app_for_pid`: `(friendly name, lowercase executable)` of a process, by day memory's
rules, for autocomplete's exclusions.

#### Invalid window leaves pid 0
`window_pid`: SAFETY: `pid` outlives the call; an invalid window leaves it 0.

#### GetWindowText never sends WM_GETTEXT cross-process so hung apps cannot block sampler
`window_title`: SAFETY: reads the caption into a buffer of the reported length. For
other processes this never sends WM_GETTEXT, so a hung app cannot
block the sampler.

#### lparam is HostedSearch kept alive for the enumeration
`visit_child`: SAFETY: `lparam` is the address of the `HostedSearch` that
`hosted_app_pid` keeps alive for the whole enumeration.

#### Version block must outlive pointers returned by VerQueryValueW; reads within reported lengths
`version_string`: SAFETY: `data` holds the whole version block for as long as the
pointers VerQueryValueW returns into it are read; every read stays
within the lengths it reports.

#### Over SSH session 0 has no foreground window; sampling still succeeds
`sampling_never_fails_without_a_desktop`: Over SSH (session 0) there is no foreground window; that is fine.

### `LinuxWindows/crates/lokalbot-platform/src/activity/x11.rs`

#### Property reads capped at 2048 words so titles cut at 8 KiB
`MAX_PROPERTY_WORDS`: Longest property read, in 32-bit units (titles are cut at 8 KiB).

#### STRING is Latin-1 and COMPOUND_TEXT is Latin-1 with escapes
`Session::title`: STRING is Latin-1; COMPOUND_TEXT is Latin-1 with escapes.

#### Apps without _NET_WM_PID: ask X-Resource for window owner
`Session::pid`: Apps that do not set _NET_WM_PID: ask the server who owns the window.

#### Latin-1 default, UTF-8 between ESC % G and ESC % @; other sets become U+FFFD
`decode_compound_text`: Decodes ICCCM `COMPOUND_TEXT` (and plain `STRING`): Latin-1 by default,
with UTF-8 segments between `ESC % G` and `ESC % @`, as Xlib writes them.
Other character sets become U+FFFD.

#### ASCII and Latin-1 designations keep default decoding
`decode_compound_text`: ASCII or Latin-1 designations keep the default decoding.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
