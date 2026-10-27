//! Delivering dictated text to the focused app (`CotypingInserter.insertViaPaste`,
//! `DictationModels.swift`).
//!
//! [`InsertMethod::Paste`] puts the text on the clipboard, presses Ctrl+V
//! (Shift+Insert in terminals), and puts the previous clipboard back 300 ms
//! later if nothing else changed it. [`InsertMethod::Type`] types Unicode
//! keystrokes. On Wayland keystrokes need `wtype` (wlroots compositors) or
//! `ydotool`; without them the text is left on the clipboard and the call
//! returns [`InsertOutcome::CopiedToClipboard`] so the UI can say so.
//!
//! Call from a background thread: a paste blocks for about 300 ms.

use std::sync::LazyLock;
use std::time::Duration;

use anyhow::Context as _;
use parking_lot::Mutex;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertMethod {
    Paste,
    Type,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertOutcome {
    /// Keystrokes were sent to the focused app.
    Inserted,
    /// The text is on the clipboard instead ("Copied to the clipboard").
    CopiedToClipboard,
}

/// How long the app gets to read the clipboard before it is restored.
const RESTORE_AFTER: Duration = Duration::from_millis(300);
/// How long to wait for the user to let go of the shortcut's modifiers.
const MODIFIER_WAIT: Duration = Duration::from_millis(600);

/// One clipboard for the process. On X11 the owner serves pastes, so the
/// copied text survives only while this stays alive.
static CLIPBOARD: LazyLock<Mutex<Option<arboard::Clipboard>>> = LazyLock::new(|| Mutex::new(None));

fn with_clipboard<T>(
    action: impl FnOnce(&mut arboard::Clipboard) -> Result<T, arboard::Error>,
) -> anyhow::Result<T> {
    let mut guard = CLIPBOARD.lock();
    let clipboard = match guard.as_mut() {
        Some(clipboard) => clipboard,
        None => guard.insert(arboard::Clipboard::new().context("the clipboard is unavailable")?),
    };
    Ok(action(clipboard)?)
}

/// What was on the clipboard before a paste.
enum Saved {
    Text(String),
    Image(arboard::ImageData<'static>),
    Nothing,
}

fn save_clipboard() -> Saved {
    if let Ok(text) = with_clipboard(|c| c.get_text()) {
        return Saved::Text(text);
    }
    match with_clipboard(|c| c.get_image()) {
        Ok(image) => Saved::Image(image),
        Err(_) => Saved::Nothing,
    }
}

/// Puts `text` on the system clipboard.
pub fn copy_to_clipboard(text: &str) -> anyhow::Result<()> {
    with_clipboard(|c| c.set_text(text))
}

/// Inserts `text` into the focused app. Errors only when even the clipboard
/// fallback failed.
pub fn insert_text(text: &str, method: InsertMethod) -> anyhow::Result<InsertOutcome> {
    if text.is_empty() {
        return Ok(InsertOutcome::Inserted);
    }
    match method {
        InsertMethod::Paste => paste(text),
        InsertMethod::Type => match keys::type_text(text) {
            Ok(true) => Ok(InsertOutcome::Inserted),
            Ok(false) => fallback(text),
            Err(err) => {
                log::warn!("typing failed, copying instead: {err:#}");
                fallback(text)
            }
        },
    }
}

/// Types `text` as keystrokes, never through the clipboard (autocomplete).
/// `Ok(false)` when this session cannot type into other apps.
#[cfg(target_os = "linux")]
pub(crate) fn type_keystrokes(text: &str) -> anyhow::Result<bool> {
    keys::type_text(text)
}

fn fallback(text: &str) -> anyhow::Result<InsertOutcome> {
    copy_to_clipboard(text)?;
    Ok(InsertOutcome::CopiedToClipboard)
}

fn paste(text: &str) -> anyhow::Result<InsertOutcome> {
    let combo = paste_combo(crate::activity::focused_app_hint().as_deref());
    let saved = save_clipboard();
    copy_to_clipboard(text)?;
    #[cfg(target_os = "linux")]
    let saved_primary = (combo == PasteCombo::ShiftInsert).then(|| primary::replace(text));
    match keys::send_paste(combo) {
        Ok(true) => {}
        Ok(false) => return Ok(InsertOutcome::CopiedToClipboard),
        Err(err) => {
            log::warn!("paste keystroke failed, leaving the text on the clipboard: {err:#}");
            return Ok(InsertOutcome::CopiedToClipboard);
        }
    }
    std::thread::sleep(RESTORE_AFTER);
    // Restore only when the clipboard still holds our text: if the user or
    // the app copied something meanwhile, that wins.
    if with_clipboard(|c| c.get_text()).ok().as_deref() == Some(text) {
        let restored = match saved {
            Saved::Text(previous) => with_clipboard(|c| c.set_text(previous)),
            Saved::Image(image) => with_clipboard(|c| c.set_image(image)),
            Saved::Nothing => Ok(()),
        };
        if let Err(err) = restored {
            log::debug!("clipboard restore failed: {err:#}");
        }
    }
    #[cfg(target_os = "linux")]
    if let Some(Some(previous)) = saved_primary {
        primary::restore(text, previous);
    }
    Ok(InsertOutcome::Inserted)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PasteCombo {
    CtrlV,
    /// Terminals: Ctrl+V is a control character there.
    ShiftInsert,
}

/// Terminal emulators by executable, `WM_CLASS` or app id (lowercase).
pub(crate) const TERMINALS: &[&str] = &[
    "gnome-terminal",
    "gnome-terminal-server",
    "org.gnome.terminal",
    "ptyxis",
    "org.gnome.ptyxis",
    "kgx",
    "org.gnome.console",
    "konsole",
    "org.kde.konsole",
    "xterm",
    "uxterm",
    "urxvt",
    "rxvt",
    "alacritty",
    "kitty",
    "foot",
    "footclient",
    "wezterm",
    "wezterm-gui",
    "org.wezfurlong.wezterm",
    "tilix",
    "com.gexperts.tilix",
    "terminator",
    "xfce4-terminal",
    "lxterminal",
    "mate-terminal",
    "qterminal",
    "terminology",
    "st",
    "st-256color",
    "sakura",
    "guake",
    "yakuake",
    "tilda",
    "ghostty",
    "com.mitchellh.ghostty",
    "blackbox",
    "com.raggesilver.blackbox",
    "windowsterminal.exe",
    "openconsole.exe",
    "conhost.exe",
    "cmd.exe",
    "powershell.exe",
    "pwsh.exe",
    "mintty.exe",
    "putty.exe",
    "alacritty.exe",
    "wezterm-gui.exe",
    "tabby.exe",
    "conemu.exe",
    "conemu64.exe",
];

pub(crate) fn paste_combo(app: Option<&str>) -> PasteCombo {
    match app {
        Some(app) if TERMINALS.contains(&app.to_lowercase().as_str()) => PasteCombo::ShiftInsert,
        _ => PasteCombo::CtrlV,
    }
}

/// Why inserting into other apps cannot work here, worded for Settings.
pub fn insertion_limitation() -> Option<String> {
    keys::limitation()
}

/// Most Linux terminals paste the primary selection on Shift+Insert, so it
/// carries the text too while pasting.
#[cfg(target_os = "linux")]
mod primary {
    use arboard::{GetExtLinux, LinuxClipboardKind, SetExtLinux};

    use super::with_clipboard;

    /// Sets the primary selection, returning what it held.
    pub(super) fn replace(text: &str) -> Option<String> {
        let previous =
            with_clipboard(|c| c.get().clipboard(LinuxClipboardKind::Primary).text()).ok();
        if let Err(err) =
            with_clipboard(|c| c.set().clipboard(LinuxClipboardKind::Primary).text(text))
        {
            log::debug!("primary selection unavailable: {err:#}");
        }
        previous
    }

    pub(super) fn restore(text: &str, previous: String) {
        let current =
            with_clipboard(|c| c.get().clipboard(LinuxClipboardKind::Primary).text()).ok();
        if current.as_deref() == Some(text) {
            let _ = with_clipboard(|c| {
                c.set()
                    .clipboard(LinuxClipboardKind::Primary)
                    .text(previous)
            });
        }
    }
}

#[cfg(windows)]
mod keys {
    //! `SendInput`: virtual keys for the paste shortcut, `KEYEVENTF_UNICODE`
    //! for typing, in chunks of at most 20 UTF-16 units like macOS.

    use std::time::{Duration, Instant};

    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBD_EVENT_FLAGS, KEYBDINPUT,
        KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, SendInput, VIRTUAL_KEY,
        VK_CONTROL, VK_INSERT, VK_LWIN, VK_MENU, VK_RETURN, VK_RWIN, VK_SHIFT, VK_TAB, VK_V,
    };

    use super::{MODIFIER_WAIT, PasteCombo};

    const CHUNK: usize = 20;
    /// An unassigned key, tapped before releasing Alt or Win so the release
    /// does not open a menu or the Start menu.
    const MASK_KEY: VIRTUAL_KEY = VIRTUAL_KEY(0xE8);

    fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
        let mut flags = if up {
            KEYEVENTF_KEYUP
        } else {
            KEYBD_EVENT_FLAGS(0)
        };
        if vk == VK_INSERT {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: vk,
                    wScan: 0,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        }
    }

    fn unicode(unit: u16, up: bool) -> INPUT {
        let mut flags = KEYEVENTF_UNICODE;
        if up {
            flags |= KEYEVENTF_KEYUP;
        }
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VIRTUAL_KEY(0),
                    wScan: unit,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        }
    }

    fn send(inputs: &[INPUT]) -> anyhow::Result<()> {
        // SAFETY: `inputs` is a valid slice of INPUT structures.
        let sent = unsafe { SendInput(inputs, size_of::<INPUT>() as i32) };
        if sent as usize != inputs.len() {
            anyhow::bail!(
                "Windows accepted {sent} of {} key events: {}",
                inputs.len(),
                std::io::Error::last_os_error()
            );
        }
        Ok(())
    }

    fn is_down(vk: VIRTUAL_KEY) -> bool {
        // SAFETY: no pointers; reads the asynchronous key state.
        (unsafe { GetAsyncKeyState(i32::from(vk.0)) } as u16 & 0x8000) != 0
    }

    const MODIFIERS: [VIRTUAL_KEY; 5] = [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN];

    /// Waits for the dictation shortcut's modifiers to come up, then lifts
    /// any still held so they do not change the keystrokes.
    fn release_modifiers() -> anyhow::Result<()> {
        let deadline = Instant::now() + MODIFIER_WAIT;
        while MODIFIERS.iter().any(|&vk| is_down(vk)) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        let held: Vec<VIRTUAL_KEY> = MODIFIERS.into_iter().filter(|&vk| is_down(vk)).collect();
        if held.is_empty() {
            return Ok(());
        }
        let mut inputs = vec![key(MASK_KEY, false), key(MASK_KEY, true)];
        inputs.extend(held.into_iter().map(|vk| key(vk, true)));
        send(&inputs)
    }

    pub(super) fn send_paste(combo: PasteCombo) -> anyhow::Result<bool> {
        release_modifiers()?;
        let (modifier, letter) = match combo {
            PasteCombo::CtrlV => (VK_CONTROL, VK_V),
            PasteCombo::ShiftInsert => (VK_SHIFT, VK_INSERT),
        };
        send(&[
            key(modifier, false),
            key(letter, false),
            key(letter, true),
            key(modifier, true),
        ])?;
        Ok(true)
    }

    pub(super) fn type_text(text: &str) -> anyhow::Result<bool> {
        release_modifiers()?;
        let mut batch: Vec<INPUT> = Vec::new();
        let mut units_in_batch = 0;
        let flush = |batch: &mut Vec<INPUT>| -> anyhow::Result<()> {
            if !batch.is_empty() {
                send(batch)?;
                batch.clear();
                std::thread::sleep(Duration::from_millis(5));
            }
            Ok(())
        };
        for c in text.chars() {
            match c {
                '\r' => continue,
                '\n' => batch.extend([key(VK_RETURN, false), key(VK_RETURN, true)]),
                '\t' => batch.extend([key(VK_TAB, false), key(VK_TAB, true)]),
                c => {
                    let mut buffer = [0u16; 2];
                    for &unit in c.encode_utf16(&mut buffer).iter() {
                        batch.extend([unicode(unit, false), unicode(unit, true)]);
                    }
                }
            }
            units_in_batch += c.len_utf16();
            // Never split a surrogate pair across batches.
            if units_in_batch >= CHUNK {
                flush(&mut batch)?;
                units_in_batch = 0;
            }
        }
        flush(&mut batch)?;
        Ok(true)
    }

    pub(super) fn limitation() -> Option<String> {
        None
    }
}

#[cfg(target_os = "linux")]
mod keys {
    //! X11: XTest for the paste shortcut and `enigo` for Unicode typing.
    //! Wayland: `wtype`, then `ydotool`.

    use std::process::Command;
    use std::time::{Duration, Instant};

    use anyhow::Context as _;
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt as _, KeyButMask};
    use x11rb::protocol::xtest::ConnectionExt as _;
    use x11rb::wrapper::ConnectionExt as _;

    use super::{MODIFIER_WAIT, PasteCombo};
    use crate::process::{find_program, output_with_timeout};

    const XK_SHIFT_L: u32 = 0xffe1;
    const XK_CONTROL_L: u32 = 0xffe3;
    const XK_INSERT: u32 = 0xff63;
    const XK_V: u32 = 0x0076;

    pub(super) fn send_paste(combo: PasteCombo) -> anyhow::Result<bool> {
        if crate::session::is_wayland() {
            return Ok(wayland_paste(combo));
        }
        let (modifier, key) = match combo {
            PasteCombo::CtrlV => (XK_CONTROL_L, XK_V),
            PasteCombo::ShiftInsert => (XK_SHIFT_L, XK_INSERT),
        };
        x11_combo(modifier, key)?;
        Ok(true)
    }

    pub(super) fn type_text(text: &str) -> anyhow::Result<bool> {
        if crate::session::is_wayland() {
            return Ok(wayland_type(text));
        }
        wait_for_x11_modifiers();
        use enigo::{Keyboard as _, Settings};
        let mut enigo = enigo::Enigo::new(&Settings::default()).context("no X11 keyboard")?;
        enigo.text(text).context("typing failed")?;
        Ok(true)
    }

    fn x11_combo(modifier: u32, key: u32) -> anyhow::Result<()> {
        let (conn, screen) = x11rb::connect(None).context("no X11 display")?;
        let root = conn
            .setup()
            .roots
            .get(screen)
            .context("no X11 screen")?
            .root;
        wait_for_modifiers(&conn, root);
        let modifier =
            keycode(&conn, modifier)?.context("no Control/Shift key on this keyboard")?;
        let key = keycode(&conn, key)?.context("the paste key is not on this keyboard")?;
        const PRESS: u8 = x11rb::protocol::xproto::KEY_PRESS_EVENT;
        const RELEASE: u8 = x11rb::protocol::xproto::KEY_RELEASE_EVENT;
        for (kind, code) in [
            (PRESS, modifier),
            (PRESS, key),
            (RELEASE, key),
            (RELEASE, modifier),
        ] {
            conn.xtest_fake_input(kind, code, x11rb::CURRENT_TIME, root, 0, 0, 0)?;
        }
        conn.sync()?;
        Ok(())
    }

    fn keycode(conn: &impl Connection, keysym: u32) -> anyhow::Result<Option<u8>> {
        let setup = conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let mapping = conn.get_keyboard_mapping(min, max - min + 1)?.reply()?;
        let per = usize::from(mapping.keysyms_per_keycode).max(1);
        Ok(mapping
            .keysyms
            .chunks(per)
            .position(|syms| syms.contains(&keysym))
            .and_then(|index| u8::try_from(usize::from(min) + index).ok()))
    }

    fn wait_for_modifiers(conn: &impl Connection, root: u32) {
        let held = KeyButMask::SHIFT | KeyButMask::CONTROL | KeyButMask::MOD1 | KeyButMask::MOD4;
        let deadline = Instant::now() + MODIFIER_WAIT;
        while Instant::now() < deadline {
            let Ok(Ok(pointer)) = conn.query_pointer(root).map(|cookie| cookie.reply()) else {
                return;
            };
            if (pointer.mask & held).bits() == 0 {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_for_x11_modifiers() {
        if let Ok((conn, screen)) = x11rb::connect(None)
            && let Some(root) = conn.setup().roots.get(screen).map(|s| s.root)
        {
            wait_for_modifiers(&conn, root);
        }
    }

    fn run(program: &std::path::Path, args: &[&str], timeout: Duration) -> bool {
        let mut command = Command::new(program);
        command.args(args);
        match output_with_timeout(command, timeout) {
            Ok(output) if output.status.success() => true,
            Ok(output) => {
                log::debug!(
                    "{} failed: {}",
                    program.display(),
                    String::from_utf8_lossy(&output.stderr).trim()
                );
                false
            }
            Err(err) => {
                log::debug!("{} failed: {err}", program.display());
                false
            }
        }
    }

    /// wtype creates a new virtual keyboard each run; without a short pause
    /// the compositor can drop the first key while it applies the keymap.
    const WTYPE_SETTLE_MS: &str = "50";

    fn wayland_paste(combo: PasteCombo) -> bool {
        let timeout = Duration::from_secs(3);
        if let Some(wtype) = find_program("wtype") {
            let args: &[&str] = match combo {
                PasteCombo::CtrlV => &["-s", WTYPE_SETTLE_MS, "-M", "ctrl", "v", "-m", "ctrl"],
                PasteCombo::ShiftInsert => &[
                    "-s",
                    WTYPE_SETTLE_MS,
                    "-M",
                    "shift",
                    "-k",
                    "Insert",
                    "-m",
                    "shift",
                ],
            };
            if run(&wtype, args, timeout) {
                return true;
            }
        }
        if let Some(ydotool) = find_program("ydotool") {
            // ydotool 1.x takes Linux input event codes (Ctrl 29, V 47,
            // Shift 42, Insert 110); 0.1.x, as in Ubuntu 24.04, key names.
            let (codes, names): (&[&str], &[&str]) = match combo {
                PasteCombo::CtrlV => (&["key", "29:1", "47:1", "47:0", "29:0"], &["key", "ctrl+v"]),
                PasteCombo::ShiftInsert => (
                    &["key", "42:1", "110:1", "110:0", "42:0"],
                    &["key", "shift+Insert"],
                ),
            };
            if run(&ydotool, codes, timeout) || run(&ydotool, names, timeout) {
                return true;
            }
        }
        false
    }

    fn wayland_type(text: &str) -> bool {
        let timeout =
            Duration::from_secs(5) + Duration::from_millis(20) * text.chars().count() as u32;
        if let Some(wtype) = find_program("wtype")
            && run(&wtype, &["-s", WTYPE_SETTLE_MS, "--", text], timeout)
        {
            return true;
        }
        if let Some(ydotool) = find_program("ydotool")
            && (run(&ydotool, &["type", "--", text], timeout)
                || (!text.starts_with('-') && run(&ydotool, &["type", text], timeout)))
        {
            return true;
        }
        false
    }

    pub(super) fn limitation() -> Option<String> {
        if !crate::session::is_wayland() {
            return None;
        }
        if find_program("wtype").is_some() || find_program("ydotool").is_some() {
            return None;
        }
        Some("On Wayland, LokalBot needs “wtype” (Sway, Hyprland) or “ydotool” to type into other apps. Until one is installed, dictated text is copied to the clipboard.".into())
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod keys {
    use super::PasteCombo;

    pub(super) fn send_paste(_: PasteCombo) -> anyhow::Result<bool> {
        Ok(false)
    }

    pub(super) fn type_text(_: &str) -> anyhow::Result<bool> {
        Ok(false)
    }

    pub(super) fn limitation() -> Option<String> {
        Some("Typing into other apps is not available on this system.".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminals_paste_with_shift_insert() {
        assert_eq!(
            paste_combo(Some("gnome-terminal-server")),
            PasteCombo::ShiftInsert
        );
        assert_eq!(
            paste_combo(Some("WindowsTerminal.exe")),
            PasteCombo::ShiftInsert
        );
        assert_eq!(
            paste_combo(Some("org.wezfurlong.wezterm")),
            PasteCombo::ShiftInsert
        );
        assert_eq!(paste_combo(Some("firefox")), PasteCombo::CtrlV);
        assert_eq!(paste_combo(None), PasteCombo::CtrlV);
    }

    #[test]
    fn empty_text_is_a_no_op() {
        assert_eq!(
            insert_text("", InsertMethod::Paste).unwrap(),
            InsertOutcome::Inserted
        );
    }
}
