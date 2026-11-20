# 0022. Platform integration

- Status: Accepted
- Date: 2026-11-20

## Context

Platform integration is how LokalBot works with the operating system under it: system-wide shortcuts, reading the selection and the focused window, delivering text into other apps, floating windows, activity and power sensing, child processes, notifications and links. The Mac app does this with Carbon hot keys, Accessibility and a synthetic ⌘C. The Windows and Linux app does it in the `lokalbot-platform` crate and the window code of `lokalbot-app`, across Windows, X11 and several Wayland compositors. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Global shortcuts

### The Mac registers its system-wide shortcuts as Carbon hot keys, not an event tap

LokalBot's opt-in, system-wide shortcuts (Quick Recall, selection actions, Hand off) are Carbon hot keys. They work while another app is focused and do not read or retain any other keyboard input.

Where: `LokalBot/Services/Search/QuickRecallHotKeyController.swift` (`QuickRecallHotKeyController`).

### Dictation accounts for Secure Input, which hides the shortcut from event taps

While another app has Secure Input on (Terminal's Secure Keyboard Entry, a password field, some password managers), macOS hides key presses from event taps, so the dictation shortcut cannot be detected.

Where: `LokalBot/Dictation/DictationMicrophone.swift` (`DictationSecureInput`).

### Windows and X11 use `global-hotkey`, Wayland the XDG portal, and desktops without either use the command line

Shortcut strings stored in settings ("Ctrl+Shift+Space", "Alt+Space") are parsed by `Shortcut` and validated with the macOS rules (`DictationShortcut.problem`, `QuickRecallHotKeyController.problem`). `GlobalShortcuts` registers them with `global-hotkey` on Windows and X11 (press and release, for push to talk) and with the XDG `GlobalShortcuts` portal on Wayland. Desktops without the portal (Sway, GNOME before 48) get a clear error; users there bind a desktop shortcut to `lokalbot dictate --toggle` / `lokalbot quick-recall`, which reach the app through `crate::instance`.

Where: `LinuxWindows/crates/lokalbot-platform/src/shortcuts.rs` (file).

### `global-hotkey` runs on its own worker thread, and the handler never blocks

On Windows the hidden window of `global-hotkey` needs a message loop on the thread that created it, so a worker thread runs one; GPUI's main-thread loop is never involved. `GlobalShortcuts` is created and used from any one thread (the GPUI main thread is fine). The handler is called on a background thread (Windows: the worker for presses and a short-lived thread for releases; X11: `global-hotkey`'s X11 thread; Wayland: the portal thread), so it must not block and only forwards the event to the app.

Where: `LinuxWindows/crates/lokalbot-platform/src/shortcuts.rs` (file, `hotkey`).

### Modifier-only shortcuts are not offered on Wayland

Modifier chords such as Ctrl+Alt alone need to read the keyboard's state, which Wayland doesn't let an app do.

Where: `LinuxWindows/crates/lokalbot-platform/src/shortcuts.rs` (`ShortcutProblem::ModifierOnlyUnsupported`).

### Shortcuts on Windows and Linux stay clear of Ctrl+Shift+W and of each other

Ctrl+Shift+W, the Mac's selection actions chord, closes tabs and windows on these platforms, so selection actions don't use it. The Ask and dictation shortcuts may not take selection actions' chord or anything the system or other apps hold.

Where: `LinuxWindows/crates/lokalbot-core/src/settings.rs` (`Settings.selection_actions_shortcut`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/mod.rs` (`other_shortcut_problem`).

### A Mac shortcut that breaks this platform's rules changes no shared settings

A library from a Mac may carry a shortcut that is fine there and not here. The Mac reads the same settings, so they stay as they are.

Where: `LinuxWindows/crates/lokalbot-app/src/desktop.rs` (`breaking_this_platforms_rules_changes_no_settings`).

### Shortcuts are re-registered only when they changed

Most settings changes leave the shortcuts alone, and taking them down to put the same ones back would lose a press made in between.

Where: `LinuxWindows/crates/lokalbot-app/src/desktop.rs` (`ShortcutSyncs`).

### Closing Settings while a shortcut field records restores the global shortcuts

A window closed while a shortcut field records never hears the field stop, and the global shortcuts would stay paused.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/mod.rs` (`SettingsPage::new`).

## Reading other apps' text

### The selection is read through accessibility first, then X11's primary selection, then a synthetic copy

The text selected in the frontmost app is read once, on an explicit shortcut press, as the Mac's `SelectionCapture.swift` does. Accessibility comes first; on X11 the primary selection follows, only when its owner is the frontmost app; apps that share neither get a synthetic Ctrl+C whose result is read and the previous clipboard put back, never in a terminal, where Ctrl+C is an interrupt. The primary selection is not read on Wayland because its owner cannot be checked there, so a stale one could come from an excluded app. The text lives only in memory for the panel's lifetime.

Where: `LinuxWindows/crates/lokalbot-platform/src/selection.rs` (file).

### Accessibility and focus reads run off the main thread with a deadline and fail closed

On the Mac the selection is read through Accessibility off the main thread with a wall-clock deadline, so a wedged app costs a short wait instead of a beachball. On Windows and Linux focus reads are serialized on one reader with a wall-clock deadline for each caller, so a wedged app fails closed without piling up workers; callers use a background thread. A focus snapshot (`DictationFocusSnapshot`, `DictationDeliveryTarget`) holds only identity and privacy state, never field text.

Where: `LokalBot/Services/SelectionActions/SelectionCapture.swift` (`SelectionCapture.readThroughAccessibility`), `LinuxWindows/crates/lokalbot-platform/src/focus.rs` (file).

### The ⌘C fallback puts the previous clipboard back, marked as generated

The copy comes from the source app, so clipboard managers may record it like any copy the person makes. The previous clipboard is restored right after, marked as generated.

Where: `LokalBot/Services/SelectionActions/SelectionCapture.swift` (`SelectionClipboardCopy`).

### The synthetic ⌘C waits for the shortcut's modifiers and is marked as LokalBot's own

The shortcut's own modifiers may still be held, and ⌃⇧⌘C is not Copy, so the copy waits for them to be released. The posted ⌘C is marked so Autocomplete's and Dictation's input taps ignore it.

Where: `LokalBot/Services/SelectionActions/SelectionCapture.swift` (`SelectionClipboardCopy.copySelection`, `SelectionClipboardCopy.postCommandC`).

### A clipboard item marked concealed is never read

A password manager's copy carries a marker, and such an item is never read.

Where: `LinuxWindows/crates/lokalbot-platform/src/selection.rs` (`clipboard_is_concealed`).

### The selection is read before the panel opens

Opening the panel moves focus away from the selection, so the shortcut reads it first.

Where: `LinuxWindows/crates/lokalbot-engine/src/selection.rs` (`Controller::invoke`).

### Selection action errors are never logged

An error can quote the prompt, which holds the selection.

Where: `LinuxWindows/crates/lokalbot-engine/src/selection.rs` (`Controller::run`).

### Selection actions read nothing while the setting is off

While the setting is off, the selection actions shortcut or command reads nothing and opens the setting instead.

Where: `LinuxWindows/crates/lokalbot-app/src/desktop.rs` (`invoke_selection_actions`).

### Hand off follows screen memory's exclusions and drops a screenshot that had anything redacted

Hand off reads the focused window once, on an explicit Hand off press. The same exclusions and secure-field checks as screen memory apply, and the read is never stored in screen memory. The window's PNG is dropped when anything was redacted, because the pixels would still show it.

Where: `LokalBot/Services/Handoff/WindowHandoffCapture.swift` (`WindowHandoffCapturer`, `WindowHandoffCapture.screenshot`).

## Delivering text

### Paste goes through the clipboard and restores the previous one after 300 ms, only if it still holds our text

`InsertMethod::Paste` puts the text on the clipboard, presses Ctrl+V and puts the previous clipboard back 300 ms later. If the user or the app copied something meanwhile, that wins and nothing is restored. A paste blocks for about 300 ms, so it is called from a background thread. `InsertMethod::Type` types Unicode keystrokes instead.

Where: `LinuxWindows/crates/lokalbot-platform/src/insert.rs` (file, `paste`).

### Terminals get Shift+Insert, and the primary selection carries the text too

In terminals the paste key is Shift+Insert. Most Linux terminals paste the primary selection on Shift+Insert, so it carries the text too while pasting.

Where: `LinuxWindows/crates/lokalbot-platform/src/insert.rs` (file, `primary`).

### On Wayland keystrokes go through `wtype` or `ydotool`, and without them the text stays on the clipboard

Keystrokes on Wayland need `wtype` (wlroots compositors) or `ydotool`; without them the text is left on the clipboard and the call returns `InsertOutcome::CopiedToClipboard` so the UI can say so. `wtype` creates a new virtual keyboard each run, so each run is followed by a short pause; without it the compositor can drop the first key while it applies the keymap. `ydotool` 1.x takes Linux input event codes (Ctrl 29, V 47, Shift 42, Insert 110); 0.1.x, as in Ubuntu 24.04, takes key names.

Where: `LinuxWindows/crates/lokalbot-platform/src/insert.rs` (file, `WTYPE_SETTLE_MS`, `wayland_paste`).

### The process keeps one clipboard for its whole life

On X11 the clipboard's owner serves pastes, so the copied text survives only while that clipboard object stays alive.

Where: `LinuxWindows/crates/lokalbot-platform/src/insert.rs` (`CLIPBOARD`).

### An unassigned key is tapped before releasing Alt or Win

The tap keeps the release from opening a menu or the Start menu.

Where: `LinuxWindows/crates/lokalbot-platform/src/insert.rs` (`MASK_KEY`).

## Windows and focus on Windows and Linux

### On Windows the overlay's native moves wait for the next event-loop turn; on X11 they run at once

Windows answers `SetWindowPos` and style changes with messages GPUI handles on the spot, and those handlers need the app, which is busy with the update that made the call: GPUI logged "RefCell already borrowed" and missed the window's new size, so the ghost kept drawing at its old size. On Windows the native calls therefore wait for the next turn of the event loop, and only the newest one runs. X11 requests go out on a connection of their own and GPUI reads the results later, so they are made at once.

Where: `LinuxWindows/crates/lokalbot-app/src/autocomplete/overlay.rs` (`Overlay.move_native`).

### Popups float as Wayland layer surfaces, with an ordinary window on GNOME

Wayland compositors place ordinary windows themselves, and tiling ones (Hyprland, Sway, Omarchy) would put a popup in the layout, so a window that floats above the others is a layer surface. GNOME has no layer shell, so opening one fails there and the caller falls back to an ordinary window. Outside Wayland no layer surface is used.

Where: `LinuxWindows/crates/lokalbot-app/src/windows/mod.rs` (`layer_surface`).

### Floating windows open once a LokalBot window has the keyboard, so they get a parent

GPUI parents a `WindowKind::Floating` window to the focused window, and Hyprland (Omarchy) and Sway, which tile every ordinary window, float a window that has a parent, as they do dialogs. So `open` runs once one of LokalBot's windows has the keyboard; a main window that has only just opened gets it a moment later. It runs at once when no window is open, and after `FOCUS_WAIT` without a parent.

Where: `LinuxWindows/crates/lokalbot-app/src/windows/mod.rs` (`when_focused`), `LinuxWindows/crates/lokalbot-platform/src/session.rs` (`Desktop::tiles_windows`).

### Quick Recall is a topmost tool window on Windows and a normal window on Linux

Windows takes a borderless, topmost tool window. X11 only gives keyboard focus to managed windows, so Linux uses a normal one.

Where: `LinuxWindows/crates/lokalbot-app/src/windows/quick_recall.rs` (`open_from`).

### On Wayland the desktop returns focus, and LokalBot only checks it

Wayland lets no app bring a window forward. There the desktop returns focus by itself when LokalBot's panel closes, and the check that follows confirms it.

Where: `LinuxWindows/crates/lokalbot-platform/src/focus.rs` (`activate_window`).

### Closing the last window does not quit

GPUI's default on Linux and Windows is to quit when the last window closes, which would skip saving a recording and end a copy running in the tray.

Where: `LinuxWindows/crates/lokalbot-app/src/quit.rs` (`tests::closing_the_last_window_does_not_quit_by_itself`).

## Activity, idle and power on Linux

### Wayland idle time comes from `ext-idle-notify-v1` version 2

The compositor says when input has been quiet for a second and when it resumes, which gives the idle time exactly. Version 2 ignores idle inhibitors such as a playing video, like macOS input idle.

Where: `LinuxWindows/crates/lokalbot-platform/src/activity/idle.rs` (`IdleNotify`).

### The unit of the ScreenSaver idle time is learned from how fast it grows

`org.freedesktop.ScreenSaver.GetSessionIdleTime` is specified in seconds, but KDE answers in milliseconds, so the unit is learned from how fast the value grows while the user is away.

Where: `LinuxWindows/crates/lokalbot-platform/src/activity/idle.rs` (`ScreenSaverIdle`).

### Session-bus calls give up after half a second

A stuck desktop service never stalls sampling.

Where: `LinuxWindows/crates/lokalbot-platform/src/activity/linux.rs` (`session_bus`).

### Each Wayland compositor is asked for the focused window through its own interface

Wayland has no common way to see the focused window. LokalBot uses Hyprland's IPC socket, Sway's i3 IPC, a short KWin script on KDE Plasma, and on GNOME the "Window Calls" or "Focused Window D-Bus" Shell extension when installed.

Where: `LinuxWindows/crates/lokalbot-platform/src/activity/wayland.rs` (file).

### Only a battery that runs the computer counts

Peripherals' batteries (a mouse, headphones) report `scope = Device` and don't count. The computer is on battery only when no mains or USB supply is online and the battery reads as discharging.

Where: `LinuxWindows/crates/lokalbot-platform/src/power.rs` (`battery_state`).

## Processes and the single instance

### Helper processes cannot outlive LokalBot

On Linux `PR_SET_PDEATHSIG` fires when the thread that forked the child exits, so every helper is spawned from one thread that lives as long as the process. On Windows helpers join a job object that kills them when the last handle to it, LokalBot's, closes.

Where: `LinuxWindows/crates/lokalbot-ai/src/process.rs` (file).

### A child's two output pipes are read on their own threads

A chatty tool cannot block on a full pipe while LokalBot waits for it.

Where: `LinuxWindows/crates/lokalbot-platform/src/process.rs` (`output_with_timeout`).

### The Mac waits for a child process with its termination handler, never `waitUntilExit()`

`waitUntilExit()` returns only after Foundation finishes the exit on the run loop of the thread that called `run()`. After any `await`, Swift concurrency may resume the task on another thread and nothing turns the launching thread's run loop again, so the wait can block forever after the child has exited and been reaped. The termination handler runs on Foundation's own queue and has no such dependency.

Where: `LokalBot/Support/ProcessExitSignal.swift` (`ProcessExitSignal`).

### The single-instance lock is an OS lock

The library's instance lock (`<root>/.instance.lock`) is held until dropped, and the OS releases it if the process dies, so a crash never leaves a stale lock behind.

Where: `LinuxWindows/crates/lokalbot-platform/src/instance.rs` (`InstanceGuard`).

### Each instance pipe client is served on its own thread

Named pipes have no I/O timeouts, so a stalled client gets its own thread instead of blocking the next request.

Where: `LinuxWindows/crates/lokalbot-platform/src/instance.rs` (`serve`).

### Speech synthesizes one text at a time

The Mac runs a process for each synthesis, and espeak's state inside sherpa-onnx is shared.

Where: `LinuxWindows/crates/lokalbot-engine/src/speak.rs` (`Inner.synthesis`).

## Notifications and links

### A notification is posted only when a notification server exists

LokalBot first checks that something owns `org.freedesktop.Notifications` or that D-Bus can start it. Without this check, posting waits for D-Bus activation to time out.

Where: `LinuxWindows/crates/lokalbot-platform/src/notify.rs` (`server_available`).

### Body clicks come through the registered "default" action

A click on a notification's body reaches `on_action` only as the "default" action, which a server sends only for a notification that registered it. Most desktops never show its label.

Where: `LinuxWindows/crates/lokalbot-platform/src/notify.rs` (`notify_with_timeout`).

### Windows toasts use the app id the installer registers

Windows shows a toast under a registered app id: a Start menu shortcut carrying `System.AppUserModel.ID`, created by the installer. Without one, toasts appear under Windows PowerShell rather than not at all.

Where: `LinuxWindows/crates/lokalbot-platform/src/notify.rs` (`windows_app_id`).

### Only web and mail links are opened

Other schemes are refused, so text from meetings or models cannot launch arbitrary handlers.

Where: `LinuxWindows/crates/lokalbot-platform/src/opener.rs` (`open_url`).

### Explorer's `/select,` path is passed verbatim

explorer.exe parses its own command line: the path must follow "/select," inside quotes, so the argument is passed verbatim.

Where: `LinuxWindows/crates/lokalbot-platform/src/opener.rs` (`reveal`).

## Consequences

- Every read of another app (selection, focus, Hand off) happens once on an explicit press, off the main thread with a deadline, keeps text only in memory and never logs it; a new read path has to do the same, and clipboard use has to stay temporary (restore only what is still ours, never read concealed items).
- Behaviour differs per desktop: Windows, X11, wlroots compositors, KDE and GNOME each need their own path for shortcuts, focus, floating windows and typing, so a change here needs checking on each, not only the one at hand.
- Settings, including shortcuts, are shared with the Mac, so the Windows and Linux app validates against them but does not rewrite them.
