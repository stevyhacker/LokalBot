# 0084. Windows and Linux: app — other modules

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/`, `LinuxWindows/crates/lokalbot-app/examples/`, `LinuxWindows/crates/lokalbot-app/src/access.rs`, `LinuxWindows/crates/lokalbot-app/src/agent_handoff.rs`, `LinuxWindows/crates/lokalbot-app/src/assets.rs`, `LinuxWindows/crates/lokalbot-app/src/bridge.rs`, `LinuxWindows/crates/lokalbot-app/src/component_i18n.rs`, `LinuxWindows/crates/lokalbot-app/src/desktop.rs`, `LinuxWindows/crates/lokalbot-app/src/headless.rs`, `LinuxWindows/crates/lokalbot-app/src/hud.rs`, `LinuxWindows/crates/lokalbot-app/src/i18n.rs`, `LinuxWindows/crates/lokalbot-app/src/main.rs`, `LinuxWindows/crates/lokalbot-app/src/palette.rs`, `LinuxWindows/crates/lokalbot-app/src/quit.rs`, `LinuxWindows/crates/lokalbot-app/src/sample.rs`, `LinuxWindows/crates/lokalbot-app/src/shell.rs`, `LinuxWindows/crates/lokalbot-app/src/test_support.rs`, `LinuxWindows/crates/lokalbot-app/src/theme.rs`, `LinuxWindows/crates/lokalbot-app/src/tray_status.rs`, `LinuxWindows/crates/lokalbot-app/src/updates.rs`, `LinuxWindows/crates/lokalbot-app/tests/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/build.rs`

#### GPUI embeds the manifest, so build.rs adds only icon and version resources
Embeds the app icon and version details into the Windows executable.
GPUI already embeds the application manifest (per-monitor DPI awareness,
common controls v6), so this adds no manifest of its own.

### `LinuxWindows/crates/lokalbot-app/examples/autocomplete_probe.rs`

#### Probe checks autocomplete desktop path in a real app; needs interactive session; PROBE PASS/FAIL
Checks autocomplete's desktop path in a real app, without the engine or a
model: opens Notepad on Windows (the GTK test field from
`lokalbot-platform/scripts` on Linux), types a sentence into it, prints
what the field watcher reads, shows a fixed suggestion in the ghost
window after the caret and saves a screenshot, presses Tab, and prints
the field's text after the accept. Then Esc dismisses the rest.

```text
cargo run -p lokalbot-app --example autocomplete_probe -- [--out <dir>] [--keep-open]
```

Needs an interactive desktop session (not a service or SSH session).
Screenshots go to `<dir>` (default `autocomplete-probe`); the last line
is `PROBE PASS` or `PROBE FAIL: <reason>`, with exit status 0 or 1.
Notepad is emptied and closed at the end unless `--keep-open` is given.
On Windows each ghost is also checked to fill exactly the frame it was
placed at, with no window frame around it.

`--overlay-only` skips the app and the keys: it shows and moves the ghost
for a made-up field and checks its window, which works without a desktop
app in front.

#### Include app layout and overlay at root so super::overlay resolves as in the app
`layout and overlay modules`: The app's own layout and ghost window; `layout` reaches `overlay` as
`super::overlay`, so both sit at the root here as they sit side by side
in the app.

#### Keep the target before raising it so it is closed whatever fails
`script`: Kept before raising it, so it is closed again whatever fails next.

#### Type the sentence as an accept does so the field holds exactly it
`script`: Typed the way an accept types, so the field holds exactly this.

#### On Windows the ghost window must equal its frame, with no caption or border
`check_ghost_window`: On Windows, that the ghost's window is exactly `frame` with nothing
around it: no caption or border, its client area its whole window.

#### On Windows 11 the child is a launcher handing over to the real Notepad
`Target.child`: What was started: the field app on Linux; on Windows 11 a launcher
that hands over to the Notepad owning the window.

#### Synthetic keys are unmarked so the interceptor treats them as the user's
`win::key`: Unmarked, so the interceptor treats it as the user's.

#### A stale window handle yields pid 0
`win::window_pid`: SAFETY: `pid` outlives the call; a stale window gives 0.

#### Never touch a Notepad the user already has open
`win::open`: Never touch a Notepad the user has open.

#### An Alt tap lets this process bring another window forward
`win::raise`: A tap of Alt lets this process bring another window forward.

#### SetForegroundWindow refuses stale handles
`win::raise`: SAFETY: a top-level window handle; a stale one is refused.

#### Empty Notepad first so session restore brings nothing back, only while in front
`win::close`: Empty it first, so a Notepad that restores its last session
brings nothing back; only while it is in front, so the keys never
reach another app.

#### Process entry must carry its size; snapshot handle closed before returning
`win::children_of`: SAFETY: the snapshot handle is closed before returning; `entry`
carries its size as the API requires.

#### Finds this process's visible click-through window and checks it is frameless
`win::ghost_window`: This process's visible click-through window (the ghost): its window
rect, its client size, and whether it has no caption or border.

#### lparam points to the vector kept alive for the whole enumeration
`win::ghost_window`: SAFETY: `lparam` is the vector `ghost_window` keeps alive for
the whole enumeration; the rest are plain queries.

#### Enum callback runs only during the call while the vector lives
`win::ghost_window`: SAFETY: the callback only runs during this call, while `found`
lives; the rects outlive their calls.

#### Capture the virtual screen through GDI so layered windows are included
`win::capture`: The virtual screen through GDI, layered windows included.

### `LinuxWindows/crates/lokalbot-app/examples/seed_demo.rs`

#### seed_demo builds the synthetic demo library for screenshots and UI checks
Seeds the synthetic demo library used for screenshots and UI checks:
`cargo run -p lokalbot-app --example seed_demo -- <library dir>`.

### `LinuxWindows/crates/lokalbot-app/src/access.rs`

#### Access states come from one shared Probe so Setup and Settings never disagree
Where each thing LokalBot needs from this computer stands, worked out once
for setup's access step and for Settings (Privacy & permissions, the
status lines, the list's badges, Overview) and `lokalbot-cli permissions`.
Linux and Windows have no permission prompts like macOS: a state is what
this computer can be seen to allow (`lokalbot_platform::access`), read
into one [`Probe`] that `AppData` keeps, plus what the running app has
found out for itself (a microphone listed, capture or the screenshot key
failing). Both places map that same reading through [`Permission::state`],
so they never disagree, and a state that can't be known before the
feature runs claims none.

#### Blocks for seconds; call off the UI thread
`Probe::read`: Reads every check. Blocks for up to a few seconds; call it off the
UI thread.

#### On Linux, with no switch, a listed microphone is the only check
`Observed.microphone_found`: A microphone shows up at all. On Linux, where no switch guards it,
that is what can be checked.

#### System switched it off; only system settings can turn it on
`State::TurnedOff`: The system has it switched off; only its settings can turn it on.

#### State unknowable before the feature runs, so none is claimed
`State::Unchecked`: Can't be known before the feature runs: no state is claimed.

#### Names match lokalbot-cli permissions request arguments
`Permission::name`: As `lokalbot-cli permissions request` takes it.

#### Only on Linux does a listed microphone mean it is usable
`Permission::state`: Where it stands, from `probe` and what the app has `observed`.
`linux` because only there does a listed microphone mean it can be used.

#### Windows lists microphones its privacy switch keeps apps away from
`a_found_microphone_counts_as_allowed_only_on_linux`: Windows lists microphones its privacy switch keeps apps away from.

#### A portal that may ask stays unknown until capture says otherwise
`what_capture_found_out_outranks_the_probe`: A portal that may ask stays unknown until capture says otherwise.

### `LinuxWindows/crates/lokalbot-app/src/agent_handoff.rs`

#### Agent handoff never sends: deep link fills input, or terminal plus clipboard prompt
Handing an action or a meeting to a coding agent installed on this
computer (`ActionAgentHandoff.swift`, `ExternalAgentHandoff.swift`). Every
route leaves the prompt unsent: a deep link fills the agent's input box,
and an agent with no link starts in a new terminal with the prompt on the
clipboard to paste. Nothing leaves this computer until the user sends it.

#### Documented deep links ordered by capability, with scheme, prefix and prompt limit
`Target::links`: Documented deep links, most capable first: a scheme, what comes
before the encoded prompt, and how long a prompt it can carry.

#### Codex CLI cannot prefill without sending; command-line prompts could be read as more than text
`Route::Terminal`: The Codex CLI has no documented way to fill a prompt without sending
it, and a prompt on a command line could be read as more than text.

#### A deep link route wins over a terminal route
`pick_route`: The first route something on this computer handles, or `None`. A deep
link wins over a terminal.

#### A menu asking for agents justifies running the login shell
`MENU_OPENED`: A menu has asked for agents, which is reason enough to run the login shell.

#### Look for agents at most once a minute; Claude Code registers its link late
`refresh_in_background`: Looks for agents off the UI thread, at most once a minute: menus rebuild
on every open, and Claude Code registers its link handler only after its
first interactive prompt.

#### The first menu looks again through the login shell too
`route_for`: The first menu looks again, this time through the login shell too.

#### Launcher sessions have minimal PATH; find Node-manager installs via login shell once per launch
`locate_command`: `command` on PATH, or where Claude Code's and Codex's installers put it.
A desktop session from a launcher can have a minimal PATH, so once a menu
has asked, one under a Node version manager is found through the login
shell, at most once per launch.

### `LinuxWindows/crates/lokalbot-app/src/assets.rs`

#### Add icon names here before use; unknown names render as nothing
`ExtraIcons`: Lucide icons beyond GPUI Kit's default component set. Add a name here before
using `Icon::new(LbIcon::…)` with it; unknown names render as nothing.

#### Asset lookup order: LokalBot files, extra icons, then GPUI Kit defaults
`Assets`: Serves LokalBot's own files first, then the extra icons, then GPUI Kit's defaults.

#### Bundle fonts on every platform so layouts and screenshots match
`load_fonts`: Registers the bundled Inter faces. The UI uses Inter on every platform so
layouts and screenshots look the same on Linux and Windows.

#### Bundled Geist and Inter versions are SIL OFL 1.1; see theme::FONT_FAMILY
`load_fonts`: Geist and Geist Mono 1.900 and Inter 4.001, all SIL OFL 1.1. See `theme::FONT_FAMILY`.

### `LinuxWindows/crates/lokalbot-app/src/bridge.rs`

#### Only the app itself shares with phones and tablets
`bridge::start`: Only the app itself shares with phones and tablets.

#### Reading aloud ends when its page is left, as on macOS
`stop_reading_off_page`: Reading aloud ends when the page it belongs to is left, as on macOS.

#### Sample meeting notes don't count toward the GitHub star prompt
`bridge::apply`: The sample's notes don't count toward asking for a GitHub star.

#### Cancelled downloads are not failures and leave nothing running
`bridge::apply`: Cancelling is not a failure, and nothing is left running.

#### Answers and voice sample show their failure in place
`bridge::apply`: Answers and the voice sample show their own failure in place.

#### Delivery notice lasts 12 s, or 2 s after Copy
`bridge::apply`: Lasts long enough to act on; goes soon after Copy.

### `LinuxWindows/crates/lokalbot-app/src/component_i18n.rs`

#### Extend pinned GPUI component translations without vendoring the dependency
Extend the pinned GPUI component backend with the app's catalogs. This
covers the controls we use without vendoring or changing the UI dependency.

#### A dependency update must not silently add an untranslated control
`framework_controls_use_app_translations`: A dependency update must not silently add an untranslated control.

### `LinuxWindows/crates/lokalbot-app/src/desktop.rs`

#### Platform callbacks arrive on own threads and forward via one channel
Desktop integration: the tray icon, global shortcuts, commands from a
second `lokalbot` process, and notifications. Platform callbacks arrive on
their own threads and are forwarded to the UI thread through one channel.

#### Esc is taken only while dictation is starting or recording
`DICTATION_CANCEL_ID`: Esc while dictating, plain and with the dictation shortcut's modifiers
still held. Taken only while starting or recording.

#### A press under 300 ms keeps recording until the next tap
`TAP_THRESHOLD`: A dictation press shorter than this keeps recording until the next tap
("Tap or hold").

#### System asked LokalBot to end, e.g. logout or kill
`DesktopEvent::Terminate`: The system asked LokalBot to end: logging out, say, or a `kill`.

#### Rule breaks come from Mac libraries; don't change settings the Mac reads
`Refusal::Rule`: Against this platform's rules, as a library from a Mac can be: not
something to change in the settings the Mac reads too.

#### Mac's answer is to restore the working shortcut or turn the feature off
`Refusal::Taken`: Another app holds it. The Mac's answer is to go back to the shortcut
that worked, or turn the feature off.

#### Mirrors applyQuickRecallSetting and applySelectionActionsSetting
`RefusalAnswer`: What a refused Ask or selection actions shortcut leads to
(`applyQuickRecallSetting`, `applySelectionActionsSetting`).

#### Restore the previous working shortcut unless it was the refused one; else off
`refusal_answer`: The previous shortcut when one worked and it isn't the refused one; else off.

#### Skip no-op syncs; re-registering would lose a press made in between
`ShortcutSyncs`: Which [`sync_shortcuts_later`] call may register, and what is registered.
Most settings changes leave the shortcuts alone, and taking them down
to put the same ones back would lose a press made in between.

#### Set only when all accepted and no later call began changing it
`ShortcutSyncs.registered`: What the last call registered, when all of it was accepted and no
later call has begun to change it.

#### Returns call number or None if registered; waiting calls give up
`ShortcutSyncs.request`: A call for `wanted`. Its number, or `None` when that is registered
already. Either way, calls still waiting to register give up.

#### Nothing counts as registered from begin until finish
`ShortcutSyncs.begin`: Whether call `number` is still the newest, at the moment it starts to
register. From here until [`Self::finish`] nothing counts as registered.

#### A refused shortcut is retried by the next call
`ShortcutSyncs.finish`: Call `number` registered `wanted`; `accepted` when nothing was refused.
A refused shortcut is tried again by the next call.

#### Handles must live as long as the app
`Desktop`: Handles that must live as long as the app.

#### Only the newest waiting sync applies; no-op ones don't start
`Desktop.shortcut_syncs`: Of several [`sync_shortcuts_later`] calls waiting to apply, only the
newest does, and one that would change nothing does not start.

#### Esc wanted for cancelling while dictation starts or records
`Desktop.dictation_cancel_keys`: Esc is wanted for cancelling: dictation is starting or recording.

#### Remember last report so a settings change doesn't repeat it
`Desktop.reported_shortcuts`: What was last said about a refused shortcut, so a settings change doesn't
repeat it.

#### Only Windows menus draw row icons from pixels; Linux names theme icons
`desktop::start`: Only Windows' menus draw row icons from pixels; Linux names
theme icons.

#### Create shortcut manager off UI thread; Wayland can block for seconds
`desktop::start`: Shortcuts can block for seconds on Wayland while the desktop asks the
user, so they are created off the UI thread.

#### opening forces a send so a Windows menu open during a change applies
`refresh_tray`: Sends the tray what changed since the last call; `opening` sends the menu
even when nothing did, for the tray to apply anything still waiting (a
Windows menu that was open when the last change came).

#### Linux gets changed labels; Windows takes the new menu on next open
`refresh_tray`: The timers are in the menu too: Linux hosts get only the changed
labels; Windows takes the new menu the next time it opens.

#### Mac libraries may carry combinations that mean something else here
`sync_shortcuts_later`: A library from a Mac may carry a combination that means something else
here, such as Ctrl+Shift+W, which closes tabs.

#### A late older call must not overwrite newer settings
`sync_shortcuts_later`: A later call carries newer settings and applies all of them, so an
older one that got here late must not put its own back.

#### Nothing registered while a shortcut is being recorded, on purpose
`sync_shortcuts_later`: While a shortcut is being recorded nothing is registered on purpose.

#### Report unregistered shortcuts and take the Mac's way out for Ask and selection actions
`shortcuts_applied`: Tells the person about shortcuts that didn't register and takes the Mac's
way out for Ask and selection actions.

#### Esc taken only during dictation; Wayland can't, so the overlay X cancels
`sync_dictation_cancel_keys`: Takes Esc only while dictation is starting or recording, and gives it back
at once. Wayland lets no app take a key, so there the overlay's X cancels.

#### Latest wish decides so Esc is never left taken after dictation
`sync_dictation_cancel_keys`: Quick presses queue here: the latest wish decides, so Esc is never
left taken after dictation ended.

#### With the setting off nothing is read; command opens the setting
`invoke_selection_actions`: The selection actions shortcut or command. While the setting is off nothing
is read: the command opens the setting instead.

#### Push to talk, Toggle and Tap or hold trigger semantics
`dictation_shortcut`: Push to talk records while held; Toggle starts and stops on presses;
Tap or hold keeps recording after a short tap until the next press.

#### Say transcribing only when that happens next
`notify_recording_saved`: "Recording saved · \<title> · N min", like the macOS notification. It says
"transcribing…" only when that is what happens next.

#### Only warnings lasting long enough interrupt the call
`notify_capture_needs_attention`: A capture warning that lasted long enough to interrupt the call for.

#### Notify once per version found by automatic check; click opens Settings
`notify_update_available`: "LokalBot \<version> is available", once per version found by an
automatic check (Sparkle shows its update alert then), with `body` saying
how to get it. Clicking it opens Settings → General, where it is offered.

#### Unrelated setting changes ask for the same shortcuts
`a_sync_that_would_change_nothing_does_not_start`: Some other setting changed: the same shortcuts are asked for.

#### Going back mid-registration must re-register the first shortcut
`going_back_while_a_change_registers_puts_the_first_back`: The other shortcut is being registered now, so the first one no
longer counts as registered and has to be asked for again.

#### Mac-library rule breaks leave settings alone since the Mac reads them
`breaking_this_platforms_rules_changes_no_settings`: A library from a Mac may carry what's fine there and not here. The Mac
reads the same settings, so they stay as they are.

### `LinuxWindows/crates/lokalbot-app/src/headless.rs`

#### Headless commands mirror HeadlessCommands.swift and exit without a window
Commands that do their work and exit, without opening a window
(`HeadlessCommands.swift`): `lokalbot --health [--day YYYY-MM-DD] [--json]`,
`lokalbot --dream [YYYY-MM-DD]` and `lokalbot --export-diagnostics <zip>`.

### `LinuxWindows/crates/lokalbot-app/src/hud.rs`

#### Dictation HUD never takes focus; Wayland uses a layer surface
The floating dictation status: a pill at the bottom of the screen while
listening, transcribing or composing, or a panel with the live transcript,
then a short notice (`DictationOverlayView.swift`,
`DictationOverlayContent.swift`). It never takes focus, so text still lands
in the app the user is typing in. On Wayland it is a layer surface, which
tiling compositors leave out of their layout.

#### Layer surfaces and popups keep opened size, so resize by reopening
`hud::sync`: Layer surfaces and popups keep the size they opened with.

#### Retry panel and Copy notice show even with floating status off
`hud::sync`: The panel with Retry and the notice with Copy are the only way
to those, so they show even with the floating status off.

#### Wayland pill is a layer surface so tiling compositors don't tile or focus it
`hud::open`: On Wayland the pill is a layer surface on the bottom edge: a tiling
compositor would otherwise tile it and give it the keyboard, and the
dictated text would land in the pill.

#### Starting shares recording's shape so the overlay doesn't jump
`hud::dimensions`: The shape for this state. Starting already has the shape recording keeps,
so the overlay does not jump when the microphone comes up.

#### Offer undelivered pasted text again instead of losing it
`Hud.undelivered_row`: Pasted text the field did not show: offer it again instead of losing it.

#### A mic problem replaces bars with words so the overlay doesn't look healthy
`Hud.render`: A microphone problem replaces the bars with words: the overlay must
not look healthy while no audio arrives.

### `LinuxWindows/crates/lokalbot-app/src/i18n.rs`

#### Locale change redraws views and updates hints in place, retaining state
GPUI integration. A locale change redraws existing views and updates input
hints in place, retaining focus, drafts, selection and undo history.

#### Hausa's letters need another font
`i18n::apply`: Hausa's letters need another font.

#### Mirror interface rows in RTL; playback and charts opt out
`i18n::h_flex`: Mirror interface rows, while playback, charts and content retain their own
ordering. These controls opt out by using GPUI's original h_flex.

#### Arabic durations carry the RTL mark to keep their leading number
`compact_duration`: "3h 57m", "39m", "\<1m": every compact duration in the app (Today's bars,
Timeline's rail and sessions, Projects, People). Arabic writes them with
its own letters ("3ح 57م"), so they carry the right-to-left mark that keeps
their leading number in GPUI (`lokalbot_i18n::directional`).

### `LinuxWindows/crates/lokalbot-app/src/main.rs`

#### Command-line options exist for tests, screenshots and a second library
`Options`: Command-line options. Most users never pass any; they exist for tests,
screenshots and a second library.

#### --page opens Settings alone on a page, as the Mac does
`Options.settings_category`: `--page settings` or `settings-<page>`: open the Settings window alone
on that page, as the Mac launches on a Settings page.

#### --window quick-recall or onboarding opens that window at startup
`Options.window`: `--window quick-recall|onboarding` opens that window at startup.

#### --moment opens Timeline on that screen moment
`Options.moment`: `--moment <id>` opens Timeline on that screen moment.

#### Login start stays in the tray without a main window
`Options.autostart`: Started at login: stay in the tray without opening the main window.

#### setup start launches only its request window
`Options.agent_setup`: Started by `lokalbot-cli setup start`: open only its request window.

#### Subcommands forward to a running LokalBot; how Wayland users bind shortcuts
`Options.command`: `lokalbot quick-recall`, `selection-actions`, `toggle-recording`, `dictate --toggle|--start|--stop`,
`show`, `install-update`: forwarded to a running LokalBot, or run after
startup. This is how Wayland users bind compositor shortcuts.

#### The replaced copy is still quitting after an update
`Options.after_update`: Started by an update: the copy it replaced is still quitting.

#### Subcommand is the first argument that is neither option nor option value
`parse_options`: The subcommand is the first argument that is neither an option nor an
option's value, so `lokalbot --lokalbot-storage-root <dir> show` works too.

#### Logs go to library log file and terminal; Windows release has no console
`init_logging`: Logs go to `<library>/logs/lokalbot.log` (Settings → Diagnostics → Logs) and,
when there is one, the terminal. Release builds on Windows have no console.

#### --version is checked first so it never opens the library or wakes an instance
`wants_version`: `lokalbot --version` (or `-V`) wherever it appears. `main` checks it before
anything else, so it never opens the library or wakes a running LokalBot.

#### KDE starts the input-method process with its own Wayland socket; no window or library
`main`: KDE Plasma starts this for autocomplete, with its own Wayland connection
in WAYLAND_SOCKET. It opens no window and never touches the library.

#### --seed-demo writes the fictional demo library for screenshots, then exits
`main`: Writes the fictional demo library used for screenshots, then exits.

#### One LokalBot per library; a second launch hands off its request
`main`: One LokalBot per library: a second launch hands its request to the first.

#### A background launch finding LokalBot running has nothing to ask
`main`: A background launch that finds LokalBot up has nothing to ask of it.

#### Only the library's owning instance may close abandoned recordings, before engine start
`main`: Only the instance that owns the library may decide a recording was
abandoned, and before its engine starts processing.

#### Explicit quit mode because the tray keeps LokalBot running without windows
`main`: The tray keeps LokalBot running with no windows, so nothing here
quits on its own when the last one closes. See `close_last_window`.

#### Handle requests app-wide so tray-only copies still reach the engine
`main`: Requests are handled here, not in the window: a tray-only copy and
one whose window was closed still have to reach the engine.

#### An agent's setup request replaces the wizard; declining opens it
`main`: An agent's setup request replaces the wizard; declining it
opens the wizard instead.

#### Keep the instance lock for the life of the process
`main`: Keep the instance lock for the life of the process.

#### After an update wait for the old copy to release the lock
`acquire_instance`: The instance lock. After an update, the copy that started this one holds
it until it has quit, so wait for it instead of handing over.

#### Ctrl+K opens Quick Recall, same as the system-wide shortcut
`bind_actions`: Ctrl+K opens Quick Recall, the window the system-wide shortcut opens:
search, commands and Ask in one place, from any LokalBot window.

#### Closing keeps tray if on and icon exists; else quit saves recording and may refuse
`open_main_window`: Closing the window keeps LokalBot in the tray when that is on and a
tray icon exists; otherwise it quits, which saves a recording first
and may refuse, so the window stays until it really does.

#### Only login or agent starts, with tray chosen, onboarded and a tray icon, open no window
`stays_in_tray`: Whether this launch opens no window (`lokalbotLaunchesMenuBarOnly`): only a
login start or a command-line agent's, and only for someone who chose to run
in the tray and has finished onboarding. A person opening LokalBot gets its
window, and so does a login start with no tray icon to come back through.

#### With no tray icon, no window left means no way back
`close_last_window`: With no tray icon, no window left means no way back into the app.

#### Argument order: autostart, agent setup, run in tray, onboarded, tray icon
`only_a_login_start_with_a_tray_stays_out_of_sight`: autostart, agent setup, run in tray, onboarded, tray icon

### `LinuxWindows/crates/lokalbot-app/src/palette.rs`

#### Palette commands computed live; Ctrl+K and global shortcut share one list
The commands Quick Recall can run (`PaletteCommands.swift`), computed live
from app state so titles follow recording and dictation status. Ctrl+K and
the system-wide shortcut open the same window, so there is one list.

#### Workspace commands show in main window; Background act in place
`Placement`: Where a command's result appears. Workspace commands show something in the
main window. Background commands (recording, dictation) act in place.

#### Import Recording is a port-only command usable anywhere
`CommandAction::ImportRecording`: "Import Recording…", from anywhere (the port's own command).

#### Subtitle is searchable area name but not displayed
`PaletteCommand.subtitle`: The area the command belongs to ("Library", "Recording"). Typed words
match it; the row does not show it.

#### English aliases let translated commands still be found
`PaletteCommand.search_aliases`: English words that still find a translated command.

#### Word-prefix matches first so Return runs top; substring-only matches never run by Return
`split`: The commands typed words find, in two parts (`PaletteCommandFilter.split`).
`leading` are those where each typed word starts a word of the command;
Quick Recall lists them first, so Return runs the top one. `loose` only
hold the words somewhere ("ion" in "Start dictation"); Quick Recall lists
them under the search results, where they can be found but Return alone
never runs one. Each part keeps the catalog's order.

#### Idle order lists in-place commands first, then catalog order
`idle_order`: The order before anything is typed: what acts in place (recording,
dictation) first, then the rest as the catalog lists them.

#### Empty query matches nothing; caller decides idle display
`filter`: Commands whose title, subtitle, and aliases contain every query word. An
empty query matches nothing; callers decide what idle shows.

#### Non-ASCII query words match anywhere because Chinese lacks spaces
`filter`: Chinese titles have no spaces between words; match those
anywhere instead.

#### Agent task commands only when Quick Recall opened from workspace
`commands`: `in_workspace` adds commands that act on the main window's current section
(Agent tasks), which only make sense when Quick Recall was opened from it.

#### Dictation shortcut registered only while Dictation is on
`commands`: The dictation shortcut is registered only while Dictation is on.

#### Copy last dictation hands focus back, ready to paste
`commands`: From Quick Recall this hands focus back, ready to paste.

#### Import Recording is port's own; Mac imports from File menu
`commands`: The port's own: the Mac imports from its File menu.

#### User-owned agent task titles added untranslated
`commands`: User-owned titles are added after translation, as they are.

#### Workspace commands bring main window forward
`run`: Runs a command. Workspace commands bring the main window forward.

#### Settings has own window; others use main window
`run`: Settings has its own window; everything else is in the main one.

#### Mid-word matches are findable but never run under Return
`commands_matching_only_inside_a_word_come_last`: "ion" sits inside "dictation": findable, but never under Return.

### `LinuxWindows/crates/lokalbot-app/src/quit.rs`

#### Quit saves recording first, defers processing; failure keeps app open and retryable
Quitting, the macOS way (`applicationShouldTerminate`): a recording stops and
its audio and details are saved before the app goes, with its processing left
for the next launch. If something could not be saved LokalBot stays open and
says what to fix, and a later quit tries again.

Everything that ends the app comes here first, not straight to `cx.quit()`.
An update's relaunch asks the engine itself (`updates::prepare_to_quit`), since
the new copy has to start between saving and quitting.

#### Forced quit waits ten seconds max for saving a recording
`FORCED_QUIT_WAIT`: `on_app_quit` runs when the app is already going: the system is ending the
session, say, and Windows may end the process right after it. This is as
long as saving a recording can hold that up.

#### Failed save never runs continuation; window returns; concurrent quits ignored
`prepare`: Runs `then` once any recording is safely saved. When it couldn't be, `then`
never runs: the engine has already reported why, and the main window comes
back so the person can see that and fix it. Another quit while one is
waiting does nothing.

#### Unrefusable exit path only waits for recording save
`finish_recording_on_exit`: The last word for anything that ends the app without asking, such as the
session ending. It can't be refused at this point, so it only waits.

#### GPUI quits on last window by default, skipping save and killing tray copy
`tests::closing_the_last_window_does_not_quit_by_itself`: GPUI's default on Linux and Windows is to quit when the last window closes,
which would skip saving a recording and end a copy running in the tray.

#### Only quit path and update relaunch may call cx.quit
`tests::nothing_quits_without_saving_a_recording`: `cx.quit()` skips saving a recording. Only the quit path and an update's
relaunch, which saves first, may call it.

#### updates.rs quit calls come after prepare_to_quit
`tests::nothing_quits_without_saving_a_recording`: Both after `prepare_to_quit`.

### `LinuxWindows/crates/lokalbot-app/src/sample.rs`

#### Sample meeting downloads models on request, then imports and processes it
"Try a sample meeting": LokalBot's bundled sample (`lokalbot_engine::sample`)
for a library with nothing in it yet. The models it needs download first,
as their own step and only when asked; then the sample is imported like
any recording, transcribed, and summarized, and its banner suggests one
question for Ask. Nothing about trying it is recorded anywhere else.

#### Sample answer lives where decision changes in expected.en.json
`QUESTION`: The question the sample's banner suggests. Its answer is in the passage
where the decision changes (`SampleMeeting/expected.en.json`).

#### Sample needs transcribe models and built-in Think plus runtime
`needs`: Model ids the sample needs: Transcribe with voice detection and speaker
separation, and the built-in Think model with its runtime (nothing for
Think on a model server).

#### Opens sample now if models present, else download step first
`AppData::try_sample`: Opens the sample, or starts adding it: straight away when its models
are here, otherwise after the download step in Meetings.

#### Sample always gets notes even when automatic notes are off
`AppData::import_sample`: Notes are part of the sample even with automatic notes off.

#### Sample question uses the sample as the only source
`AppData::ask_sample_question`: Asks the suggested question about the sample, with the sample as the only source.

### `LinuxWindows/crates/lokalbot-app/src/shell.rs`

#### Main window mirrors MainWindowView.swift; Settings opens its own window
The main window: sidebar, toolbar (which doubles as the title bar) and the
current page. Mirrors `MainWindowView.swift`: Today and Actions lead,
Remember and Assistant group the rest, and Settings with the privacy line
sits in the sidebar's foot. Settings opens its own window.

#### Sidebar grouping; Settings and privacy line in footer outside destinations
`Workspace::render_sidebar`: Today and Actions lead; Remember holds what was captured; Assistant
holds the two places you ask for work. Settings and the privacy line
sit in the footer, outside the destinations (`MainWindowView.sidebar`).

#### Brand doubles as drag handle; Mac has window buttons here
`Workspace::render_brand`: The app mark at the top of the sidebar; also a window drag handle.
The Mac has its window buttons here instead.

#### Footer order: running work, Settings, privacy line
`Workspace::render_sidebar_footer`: The sidebar's foot: what is running now, then Settings, then where
the library and the AI are (`SidebarFooter`).

#### Settings sits at foot, opens window, is never selected
`Workspace::render_sidebar_footer`: Settings is a place you visit rarely, so it sits at the
foot and not among the destinations. It opens the
Settings window and is never selected: the main window
stays where it was (`SidebarSettingsRow`).

#### Title control takes clicks while rest of bar drags window
`Workspace::render`: The control takes clicks; the rest of the bar still drags the window.

#### Privacy line shows library and AI location plus paired devices when sharing
`privacy_line`: Where the library and the AI are, under Settings (`SidebarPrivacyLine`),
with the paired devices line while sharing is on.

#### Latest message or error shown in both main and Settings windows
`toast`: The latest message or error, at the foot of a window (`ErrorToast`). The
main window and the Settings window both show it.

#### Clicking background work opens the screen that owns it
`background_row`: One piece of background work; a click opens the screen that owns it
(`BackgroundActivityButton`).

#### Maps background work to owning screen; mirrors BackgroundActivity.destination
`background_destination`: The screen that owns a piece of work (`BackgroundActivity.destination`).

#### Privacy line wording for paired devices; mirrors SidebarCompanionLine
`companion_line`: What the privacy line says about paired phones and tablets
(`SidebarCompanionLine`).

### `LinuxWindows/crates/lokalbot-app/src/test_support.rs`

#### Test thread orders references newest first, due when newest is
`thread`: A thread of `references`, newest first, due when its newest is.

### `LinuxWindows/crates/lokalbot-app/src/theme.rs`

#### Design tokens translate the macOS DesignTokens; kit themed from same palette
LokalBot design tokens, translated from the macOS app
(`LokalBot/Support/DesignTokens.swift`, `Brand.swift`).

Views read colors with `cx.lb()` and sizes from [`ty`] and [`metric`].
GPUI Kit components (buttons, inputs, switches, menus) are themed from the
same palette in [`apply`], so both layers agree.

#### Palette names follow the macOS tokens
`Palette`: Colors for one appearance. Names follow the macOS tokens.

#### Elevated surface for popovers, Quick Recall panel and composer
`Palette.elevated`: Elevated surfaces: popovers, the Quick Recall panel, the composer.

#### Grey used for metadata lines
`Palette.supporting`: Grey used for metadata lines ("FaceTime · 10:57 AM · 2 min").

#### Wells and faint strips of a section panel
`Palette.group_fill`: Wells and the faint strips of a section panel: its footer and bands
(`groupFill`).

#### Edge of grouped wells and section panels
`Palette.group_stroke`: The edge of grouped wells and section panels (`groupStroke`).

#### Chips and quiet wells use quaternary fill at about 50%
`Palette.chip_fill`: Chips and quiet wells (quaternary fill at about 50%).

#### Count pills and empty bar parts stay visible in both appearances
`Palette.quiet_fill`: Count pills and the empty part of a bar on a panel: quiet, and still a
visible shape in both appearances (`quietFill`).

#### Page behind panels so each panel reads as raised
`Palette.page`: The page behind section panels (`windowBackgroundColor`), so each
panel reads as its own raised surface.

#### Raised surface of a section panel
`Palette.panel`: A section panel's raised surface (`controlBackgroundColor`).

#### Accent fill carries white text
`Palette.accent_fill`: Filled buttons, selected rows in a focused list, switches. White text on it.

#### Accent text for links, timestamps, sidebar symbols, evidence pills
`Palette.accent_text`: Links, timestamps, sidebar symbols and evidence pills.

#### Overdue text uses recording red with at least 4.5:1 contrast
`Palette.overdue_text`: Due text of open work whose day has passed: the recording red's text
colour. At least 4.5:1 on panels and pages in both appearances.

#### Due-soon text uses attention amber with at least 4.5:1 contrast
`Palette.due_soon_text`: Due text of open work due within the week: the attention amber's text
colour. At least 4.5:1 on panels and pages in both appearances.

#### Speakers colored by first appearance; index 0 is You
`Palette::speaker`: Speakers in order of first appearance; index 0 is always "You".

#### App color is djb2 hue, saturation 0.55, brightness 0.78
`Palette::app_color`: A stable color per app name: djb2 hue, saturation 0.55, brightness 0.78.

#### Status surfaces use tint at 10% fill and 28% stroke
`Palette::status_fill`: Status surfaces: the tint at 10% with a 28% stroke.

#### Type scale is the macOS sizes scaled by 14/13
`ty`: Type scale in logical pixels: the macOS sizes scaled by 14/13 for the
larger default text on Linux and Windows.

#### Panel title is one step above section heading
`ty::PANEL_TITLE`: A section panel's title: one step above the section heading.

#### Pill size covers count pills, status pills, band and group labels
`ty::PILL`: Count and status pills, band and group labels inside a panel.

#### Layout metrics mirror the Mac LBTokens.Metric
`metric`: Layout metrics (`LBTokens.Metric`).

#### Panel metrics mirror SectionPanelMetric: inset and strip heights
`metric::PANEL_INSET`: Section panels (`SectionPanelMetric`): the inset between a panel's
edge and its text, and the heights of its strips.

#### Action row padding matches Mac rowVerticalPadding
`metric::ROW_VERTICAL_PADDING`: An action row's padding above and below (`rowVerticalPadding`).

#### Geist chosen for licence; Hausa letters missing so Hausa uses Inter
`FONT_FAMILY`: The interface font: Geist (Vercel with basement.studio, SIL OFL 1.1), the
open family that Claude Desktop's Anthropic Sans credits ("BSPK x Geist x
Anthropic"). Anthropic's own fonts have no license to ship.
Geist draws the letters of every interface language but Hausa's hooked
ɓ ɗ ƙ, so a Hausa interface stays on Inter.

#### Inter covers Hausa letters and key symbols Geist lacks
`FALLBACK_FONT_FAMILY`: What Geist lacks, such as Hausa's letters and the ⌘ ⌥ ⌃ key symbols.

#### Mono font is for code, paths, logs and commands
`MONO_FONT_FAMILY`: Code, paths, logs and commands.

#### Set the font at the window root; children inherit with fallback
`UiFont::ui_font`: Sets a window's root to the interface font, with Inter for what it lacks.
Everything inside inherits both.

#### Use Theme::update so component tokens stay in sync with colors
`apply`: `Theme::update` reconciles the component tokens (buttons, tabs, sidebar)
with these colors; editing through `global_mut` alone leaves them stale.

#### Panel, footer and page text must meet 4.5:1 contrast
`tests::panel_text_colours_meet_four_and_a_half_to_one`: Text on panels, their footer strips and the page stays readable.

#### Panel must differ from page so it reads as raised
`tests::panels_stand_apart_from_the_page`: The page and its panels differ, so a panel reads as raised.

### `LinuxWindows/crates/lokalbot-app/src/tray_status.rs`

#### Tray status is display-only and mirrors the Mac MenuBarStatus
What the tray menu says LokalBot is doing, and the meetings listed under
it (`MenuBarStatus.swift`, `MenuBarView.swift`). Display-only: nothing
here is stored or sent. `desktop.rs` hands the result to the tray.

#### Menu leads with a meeting 15 minutes ahead, shorter than Today's hour
`SOON_WINDOW_SECONDS`: A calendar meeting leads the menu once it starts within this long, and
keeps the block while under way and not being recorded. Shorter than
Today's hour: the menu is a glance (`MenuBarStatus.soonWindow`).

#### A just-saved recording is named for two minutes
`JUST_STOPPED_SECONDS`: How long a recording that has just been saved is named in the block
(`MenuBarStatus.justStoppedWindow`).

#### Recording in progress claims its event before the library lists it
`menu_state`: The recording in progress claims its event before the library lists it.

#### Track states use the Mac's words; levels stand in until first report
`recording`: The recording in progress: its meeting, timer, warnings, and whether
sound arrives from each source. The engine reports each track's state in
the Mac's words; levels stand in until its first report.

#### Sound counts as arriving only when recorder reports Receiving audio
`source`: Sound is arriving only while the recorder says so (`MemoryHealthTone.audio`).

#### Attention order: latest error then approvals; no microphone permission on port
`attention`: Everything waiting, most blocking first: the latest error, then
approvals (`MenuBarAttention.items`). The port has no microphone
permission to lose.

#### Paused means day memory runs and is paused
`Inputs.paused`: Day memory runs and is paused.

#### Recording or dictation leads so Stop is never hidden
`block`: The block in this order: recording, dictating, needs attention, a
meeting about to start, day memory paused, just stopped, idle. A
recording or a dictation leads even when something needs attention, so
Stop is never hidden; the waiting items are listed under it.

#### Leading meeting skips recorded and currently recorded events
`soon_meeting`: The calendar meeting that leads the menu: the one under way, or the next
once it starts within 15 minutes. Events already recorded, and the one
being recorded now, are passed over (`TodayAgenda.nextMeeting`).

#### Tray omits attendees because its words reach every session bus app
`schedule_line`: "6:00 PM – 6:30 PM". The Mac adds the first attendee and a count
(`MenuBarStatusBlock.schedule`); here the menu's words reach every app on
the session bus (Linux), and the tray has never shown attendee names, so
it leaves them out.

#### Imported files never count as just recorded
`just_stopped`: The recording made here that ended within two minutes. An imported file
was not just recorded, whenever its audio ends.

#### Recent list excludes merged sources and the recording in progress
`recent_meetings`: The first meetings of the library, which lists the newest first, with the
one just saved in front, and whether each is that one. Sources folded into
a merged meeting and the recording in progress are not listed.

#### When label wording matches Mac MenuBarPanelWhen
`when_label`: "Just now", today's start time, "Yesterday", or the day
(`MenuBarPanelWhen`).

#### Windows tray menus draw pixel icons; Record, Stop, blank drawn by tray
`lucide`: The Lucide icon each menu row draws where the tray menu draws pixels
(Windows), as the app draws it elsewhere. Record, Stop and the blank are
drawn by the tray itself.

#### Row icons are 32 px; Windows scales them to 16 px menus
`GLYPH_PIXELS`: Pixels on a side of a row icon; Windows scales them to its 16 px menus.

#### Icon grey matches Mac secondary ink, 6.7:1 on white
`GLYPH_INK`: The icons' grey on Windows' light tray menus: the Mac rows' secondary ink,
6.7:1 on white.

#### Only Windows menus draw pixels, so only Windows requests glyphs
`glyph_pixels`: Every row icon the tray cannot draw itself, rasterized from the bundled
Lucide icons in [`GLYPH_INK`]. Only Windows' menus draw pixels, so only
Windows asks for them.

#### Keep only alpha coverage from BGRA pixels, in one ink
`glyph_pixels`: BGRA, premultiplied: only the coverage is kept, in one ink.

#### A recording leads and lists waiting items under it
`tests::the_block_follows_the_mac_order`: A recording leads and lists everything waiting under it.

#### First waiting item leads and the rest are listed
`tests::the_block_follows_the_mac_order`: The first item waiting leads; the rest are listed.

#### Imported, merged-source and still-recording meetings are not just stopped
`tests::a_recording_is_just_stopped_for_two_minutes`: An imported file, a merged source or one still recording is not.

#### The meeting that ended last wins
`tests::a_recording_is_just_stopped_for_two_minutes`: The one that ended last wins.

#### Recording in progress is not a recent meeting
`tests::recent_meetings_keep_two_with_the_saved_one_first`: The recording in progress is not a recent meeting.

#### Unrecorded meeting under way keeps the block
`tests::a_meeting_leads_the_menu_from_fifteen_minutes_before`: Under way and not recorded: it keeps the block.

#### Recorded or finished meetings do not lead the menu
`tests::a_meeting_leads_the_menu_from_fifteen_minutes_before`: Recorded already, or over: it does not.

#### Glyphs have ink, one grey, and clear surroundings
`tests::glyphs_are_drawn_in_one_grey`: Some ink, in the one grey, and clear around it.

### `LinuxWindows/crates/lokalbot-app/src/updates.rs`

#### Update flow: consent-only install, verification, package-manager routing, download fallback
Automatic updates (`AppUpdateManager.swift`, Sparkle's standard driver).

While "Check for updates automatically" is on, LokalBot reads the latest
release's feed shortly after launch and once a day. "Check for Updates…"
in Settings checks at any time. As with Sparkle's defaults, nothing is
downloaded or installed until the user chooses Install and Relaunch in
Settings → General or the tray menu; a newly found version is announced
once with a notification. Installing downloads the archive, verifies it
(size, SHA-256, Ed25519 signature) before unpacking, swaps the files,
stops the llama.cpp servers, starts the new copy and quits; Agent Mode
stops its processes as LokalBot quits. When this copy cannot replace its
own files (`/opt`, Program Files, a source build), the update is offered
as a download from GitHub instead. A copy a package manager installed is
told to update through it: the AUR's `lokalbot-bin` with `yay -Syu`, the
release's .deb and .rpm with `apt upgrade` and `dnf upgrade` once they
added LokalBot's repository, and otherwise (the Arch package, or a .deb
or .rpm from before the repository) by installing the new package.

#### First automatic check waits for startup work to settle
`FIRST_CHECK_DELAY`: The first automatic check waits for startup work to settle.

#### Daily check interval matches Sparkle's SUScheduledCheckInterval
`CHECK_INTERVAL`: Sparkle's `SUScheduledCheckInterval`.

#### Failed automatic check retries after an hour
`RETRY_INTERVAL`: After a failed automatic check (offline at login, say).

#### Message when update installed but a stopped recording could not be saved
`REFUSED_RELAUNCH`: An update installed while a stopped recording's details can't be saved yet.

#### Download route is for copies that cannot replace themselves or release packages without repository
`Route::Download`: The release page: a copy that cannot replace itself, or the
release's own package, which has no repository to update from.

#### Package lookup happens with first check; inner None means no package lists it
`Updates.package`: The package that installed this copy, looked up with the first check
(the inner `None`: no package lists it).

#### lokalbot install-update installs as soon as a check finds a release
`Updates.install_when_found`: `lokalbot install-update`: install as soon as a check finds one.

#### Leftovers of an earlier update are removed before scheduling
`start`: Creates the updater and its daily schedule. Leftovers of an earlier
update (`.old` binaries, downloads) are removed first.

#### Clear work dir before anything can start a download into it
`start`: Before anything can start a download into it.

#### Record installed version because the installing copy may predate this call
`start`: The copy that installed this update may predate this call.

#### Only managed copies that cannot replace themselves look up their package
`Updates::check`: Only a copy that cannot replace itself needs to know its package.

#### Failed automatic check keeps showing the known available release
`checked`: A failed automatic check keeps showing what was known.

#### install-update checks first when needed; user asked so no further consent
`install_from_command`: `lokalbot install-update`: installs the offered update, checking first
when none is known yet. The user asked for it, so no further consent.

#### Relaunch stops llama.cpp servers, starts new copy, quits; Agent Mode stops on quit
`relaunch`: The files are in place: stop the llama.cpp servers, start the new
copy, quit (Agent Mode stops its processes on quit).

#### If quit is refused, new files are in place but this copy stays
`relaunch`: The new files are in place; this copy just can't go yet.

#### Write installed version to Windows Installed apps; failures only log
`record_installed_version`: Shows `version` in the installer's Installed apps entry (Windows), which an
update LokalBot installs itself would otherwise leave at the installer's
version. Failures only log: the update itself is in place.

#### Save recording then stop servers; false means save failed and this copy stays
`prepare_to_quit`: Saves any recording, then stops the llama.cpp servers, before a new copy
starts. False when the recording could not be saved: the engine has said why,
and this copy has to stay.

#### Pass this copy's library root to the new copy
`relaunch_args`: The library this copy uses, passed on to the new copy.

#### Package-manager route applies even when copy is too old to self-update
`package_manager_copies_are_told_to_update_through_it`: Even when the copy is too old to update itself.

### `LinuxWindows/crates/lokalbot-app/tests/version.rs`

#### Test must not wait for an app that started because the flag was ignored
`version_exits_before_opening_the_library`: If the flag were ignored the app would start; don't wait for it.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
