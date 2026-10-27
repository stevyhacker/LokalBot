// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 18 October 2026.
// See THIRD_PARTY_NOTICES.md.

//! Windows for autocomplete: a low-level keyboard hook that takes plain Tab
//! and Esc only while ghost text shows (`CotypingInputMonitor`'s accept
//! tap), `SendInput` Unicode keystrokes for an accepted chunk
//! (`CotypingInserter`), and the ghost window's styles and placement.
//!
//! The hook is installed when a suggestion appears and removed when it goes;
//! its callback only forwards the key, so Windows never waits on LokalBot.
//! LokalBot's own keystrokes carry [`MARKER`] and pass the hook untouched.

use std::cell::RefCell;
use std::thread::JoinHandle;

use anyhow::Context as _;
use crossbeam_channel::{Receiver, Sender, unbounded};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DWM_WINDOW_CORNER_PREFERENCE, DWMNCRENDERINGPOLICY, DWMNCRP_DISABLED, DWMWA_BORDER_COLOR,
    DWMWA_COLOR_NONE, DWMWA_NCRENDERING_POLICY, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_DONOTROUND,
    DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Gdi::{
    GetDC, GetMonitorInfoW, GetPixel, MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromPoint,
    ReleaseDC,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBD_EVENT_FLAGS, KEYBDINPUT,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_UNICODE, SendInput, VIRTUAL_KEY, VK_BACK,
    VK_CONTROL, VK_DELETE, VK_ESCAPE, VK_LWIN, VK_MENU, VK_RETURN, VK_RWIN, VK_SHIFT, VK_TAB,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, GWL_EXSTYLE, GWL_STYLE, GetForegroundWindow, GetWindowLongPtrW,
    GetWindowThreadProcessId, HC_ACTION, HHOOK, HWND_TOPMOST, KBDLLHOOKSTRUCT, LWA_ALPHA, SW_HIDE,
    SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SWP_SHOWWINDOW,
    SetLayeredWindowAttributes, SetWindowDisplayAffinity, SetWindowLongPtrW, SetWindowPos,
    SetWindowsHookExW, ShowWindow, UnhookWindowsHookEx, WDA_EXCLUDEFROMCAPTURE, WH_KEYBOARD_LL,
    WINDOW_EX_STYLE, WINDOW_STYLE, WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP, WS_BORDER,
    WS_CAPTION, WS_DLGFRAME, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
    WS_EX_TRANSPARENT, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
};

use super::geometry::Rect;
use super::{Edit, FieldSnapshot, InterceptedKey, KeyHandler};

/// `dwExtraInfo` of LokalBot's own keystrokes ("LOKA").
pub(super) const MARKER: usize = 0x4C4F_4B41;
/// Many apps take only the first 20 UTF-16 units of one burst of keys.
const CHUNK: usize = 20;

enum Command {
    Active(bool),
    PassThrough(InterceptedKey),
    Stop,
}

struct HookState {
    handler: KeyHandler,
    hook: Option<HHOOK>,
    /// Keys whose press was taken, so their release is taken too.
    taken: [bool; 2],
}

thread_local! {
    /// The hook runs on the thread that installed it, through its message loop.
    static STATE: RefCell<Option<HookState>> = const { RefCell::new(None) };
}

fn index(key: InterceptedKey) -> usize {
    match key {
        InterceptedKey::Tab => 0,
        InterceptedKey::Escape => 1,
    }
}

fn is_down(vk: VIRTUAL_KEY) -> bool {
    // SAFETY: no pointers; reads the asynchronous key state.
    (unsafe { GetAsyncKeyState(i32::from(vk.0)) } as u16 & 0x8000) != 0
}

fn modifiers_down() -> bool {
    [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN]
        .into_iter()
        .any(is_down)
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        // SAFETY: for HC_ACTION, lparam points to the event's KBDLLHOOKSTRUCT.
        let info = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let key = match VIRTUAL_KEY(info.vkCode as u16) {
            VK_TAB => Some(InterceptedKey::Tab),
            VK_ESCAPE => Some(InterceptedKey::Escape),
            _ => None,
        };
        if let Some(key) = key
            && info.dwExtraInfo != MARKER
        {
            let message = wparam.0 as u32;
            let pressed = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
            let released = message == WM_KEYUP || message == WM_SYSKEYUP;
            let take = STATE.with(|state| {
                let mut state = state.borrow_mut();
                let Some(state) = state.as_mut() else {
                    return false;
                };
                if state.hook.is_none() {
                    return false;
                }
                let slot = index(key);
                if pressed && !modifiers_down() {
                    state.taken[slot] = true;
                    (state.handler)(key);
                    true
                } else if released && state.taken[slot] {
                    state.taken[slot] = false;
                    true
                } else {
                    false
                }
            });
            if take {
                return LRESULT(1);
            }
        }
    }
    // SAFETY: passes the event on unchanged.
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

pub(super) struct Hook {
    commands: Sender<Command>,
    thread_id: u32,
    thread: Option<JoinHandle<()>>,
}

impl Hook {
    pub(super) fn start(handler: KeyHandler) -> anyhow::Result<Self> {
        let (commands, receiver) = unbounded();
        let (ready_tx, ready_rx) = crossbeam_channel::bounded(1);
        let thread = std::thread::Builder::new()
            .name("lokalbot-autocomplete-keys".into())
            .spawn(move || run(handler, receiver, ready_tx))
            .context("could not start the key thread")?;
        let thread_id = ready_rx
            .recv()
            .context("the key thread stopped before it started")?;
        Ok(Self {
            commands,
            thread_id,
            thread: Some(thread),
        })
    }

    fn send(&self, command: Command) {
        let _ = self.commands.send(command);
        crate::win32_loop::wake(self.thread_id);
    }

    pub(super) fn set_active(&self, active: bool) {
        self.send(Command::Active(active));
    }

    pub(super) fn pass_through(&self, key: InterceptedKey) {
        self.send(Command::PassThrough(key));
    }
}

impl Drop for Hook {
    fn drop(&mut self) {
        self.send(Command::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn run(handler: KeyHandler, commands: Receiver<Command>, ready: Sender<u32>) {
    STATE.with(|state| {
        *state.borrow_mut() = Some(HookState {
            handler,
            hook: None,
            taken: [false; 2],
        })
    });
    crate::win32_loop::run(
        |thread_id| {
            let _ = ready.send(thread_id);
        },
        || {
            while let Ok(command) = commands.try_recv() {
                match command {
                    Command::Active(active) => set_hook(active),
                    Command::PassThrough(key) => {
                        let vk = match key {
                            InterceptedKey::Tab => VK_TAB,
                            InterceptedKey::Escape => VK_ESCAPE,
                        };
                        if let Err(err) = send(&[key_input(vk, false), key_input(vk, true)]) {
                            log::debug!("autocomplete: passing a key on failed: {err:#}");
                        }
                    }
                    Command::Stop => {
                        set_hook(false);
                        return false;
                    }
                }
            }
            true
        },
    );
    set_hook(false);
}

fn set_hook(active: bool) {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        let Some(state) = state.as_mut() else {
            return;
        };
        match (active, state.hook) {
            (true, None) => {
                // SAFETY: a low-level hook for this process's own procedure;
                // it is removed below before the thread ends.
                let installed = unsafe {
                    let module = GetModuleHandleW(None).ok();
                    SetWindowsHookExW(WH_KEYBOARD_LL, Some(hook_proc), module.map(Into::into), 0)
                };
                match installed {
                    Ok(hook) => state.hook = Some(hook),
                    Err(err) => log::warn!("autocomplete: the keyboard hook failed: {err}"),
                }
            }
            (false, Some(hook)) => {
                // SAFETY: `hook` came from SetWindowsHookExW on this thread.
                let _ = unsafe { UnhookWindowsHookEx(hook) };
                state.hook = None;
                state.taken = [false; 2];
            }
            _ => {}
        }
    });
}

fn key_input(vk: VIRTUAL_KEY, up: bool) -> INPUT {
    let mut flags = if up {
        KEYEVENTF_KEYUP
    } else {
        KEYBD_EVENT_FLAGS(0)
    };
    if vk == VK_DELETE {
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
                dwExtraInfo: MARKER,
            },
        },
    }
}

fn unicode_input(unit: u16, up: bool) -> INPUT {
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
                dwExtraInfo: MARKER,
            },
        },
    }
}

fn send(inputs: &[INPUT]) -> anyhow::Result<()> {
    if inputs.is_empty() {
        return Ok(());
    }
    // SAFETY: `inputs` is a valid slice of INPUT structures.
    let sent = unsafe { SendInput(inputs, size_of::<INPUT>() as i32) };
    anyhow::ensure!(
        sent as usize == inputs.len(),
        "Windows accepted {sent} of {} key events: {}",
        inputs.len(),
        std::io::Error::last_os_error()
    );
    Ok(())
}

fn foreground_pid() -> Option<u32> {
    // SAFETY: no arguments; returns a possibly null window handle.
    let window = unsafe { GetForegroundWindow() };
    if window.0.is_null() {
        return None;
    }
    let mut pid = 0u32;
    // SAFETY: `pid` outlives the call.
    unsafe { GetWindowThreadProcessId(window, Some(&mut pid)) };
    (pid != 0).then_some(pid)
}

/// Types an accepted chunk into the window in front, which must belong to
/// the field's app: deletions first, then the text as Unicode keystrokes in
/// bursts of at most 20 UTF-16 units.
pub(super) fn insert(field: &FieldSnapshot, edit: &Edit) -> anyhow::Result<()> {
    anyhow::ensure!(
        foreground_pid() == Some(field.target.pid),
        "the field's app is no longer in front"
    );
    let mut deletions = Vec::new();
    for _ in 0..edit.backward {
        deletions.extend([key_input(VK_BACK, false), key_input(VK_BACK, true)]);
    }
    for _ in 0..edit.forward {
        deletions.extend([key_input(VK_DELETE, false), key_input(VK_DELETE, true)]);
    }
    send(&deletions)?;
    let mut batch: Vec<INPUT> = Vec::new();
    let mut units = 0;
    for c in edit.text.chars() {
        match c {
            '\r' => continue,
            '\n' => batch.extend([key_input(VK_RETURN, false), key_input(VK_RETURN, true)]),
            // Tab would come back to our own hook as an accept.
            '\t' => batch.extend([
                unicode_input(u16::from(b' '), false),
                unicode_input(u16::from(b' '), true),
            ]),
            c => {
                let mut buffer = [0u16; 2];
                for &unit in c.encode_utf16(&mut buffer).iter() {
                    batch.extend([unicode_input(unit, false), unicode_input(unit, true)]);
                }
            }
        }
        units += c.len_utf16();
        // Never split a surrogate pair between bursts.
        if units >= CHUNK {
            send(&batch)?;
            batch.clear();
            units = 0;
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }
    send(&batch)
}

/// No frame or border, no activation on click, clicks pass through, never
/// in the taskbar or Alt+Tab, and (when asked) left out of screenshots and
/// recordings.
///
/// GPUI creates pop-up windows as overlapped windows, which Windows gives a
/// caption and a border: the client area then sits inside the frame the
/// ghost is placed at, so its text was shifted and clipped, and DWM drew a
/// thin border around it. A plain `WS_POPUP` without DWM's frame, rounded
/// corners and border is exactly the ghost's frame. Call it outside a GPUI
/// update: the frame change reaches GPUI as a new client size.
pub(super) fn prepare_overlay(hwnd: isize, exclude_from_capture: bool) -> anyhow::Result<()> {
    let window = HWND(hwnd as *mut core::ffi::c_void);
    let frame = WS_CAPTION
        | WS_BORDER
        | WS_DLGFRAME
        | WS_THICKFRAME
        | WS_SYSMENU
        | WS_MINIMIZEBOX
        | WS_MAXIMIZEBOX;
    // SAFETY: `window` is LokalBot's own ghost window; these calls only
    // change its styles and DWM attributes, each value passed by pointer
    // with its size.
    unsafe {
        let style = WINDOW_STYLE(GetWindowLongPtrW(window, GWL_STYLE) as u32);
        SetWindowLongPtrW(window, GWL_STYLE, ((style & !frame) | WS_POPUP).0 as isize);
        let style = WINDOW_EX_STYLE(GetWindowLongPtrW(window, GWL_EXSTYLE) as u32);
        let style = style
            | WS_EX_NOACTIVATE
            | WS_EX_TRANSPARENT
            | WS_EX_LAYERED
            | WS_EX_TOOLWINDOW
            | WS_EX_TOPMOST;
        SetWindowLongPtrW(window, GWL_EXSTYLE, style.0 as isize);
        // Older Windows lacks some of these; the window still works.
        let policy = DWMNCRP_DISABLED;
        let _ = DwmSetWindowAttribute(
            window,
            DWMWA_NCRENDERING_POLICY,
            (&raw const policy).cast(),
            size_of::<DWMNCRENDERINGPOLICY>() as u32,
        );
        let corners = DWMWCP_DONOTROUND;
        let _ = DwmSetWindowAttribute(
            window,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            (&raw const corners).cast(),
            size_of::<DWM_WINDOW_CORNER_PREFERENCE>() as u32,
        );
        let border = DWMWA_COLOR_NONE;
        let _ = DwmSetWindowAttribute(
            window,
            DWMWA_BORDER_COLOR,
            (&raw const border).cast(),
            size_of::<u32>() as u32,
        );
        SetLayeredWindowAttributes(window, Default::default(), 255, LWA_ALPHA)
            .context("SetLayeredWindowAttributes")?;
        // The new styles take effect with the next frame calculation.
        SetWindowPos(
            window,
            None,
            0,
            0,
            0,
            0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
        )
        .context("SetWindowPos")?;
        if exclude_from_capture
            && let Err(err) = SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE)
        {
            log::debug!("autocomplete: could not keep the ghost out of captures: {err}");
        }
    }
    Ok(())
}

/// Device pixels per logical pixel on the monitor showing `rect`.
pub(super) fn scale_at(rect: &Rect) -> Option<f32> {
    let point = POINT {
        x: (rect.x + rect.width / 2.0) as i32,
        y: rect.mid_y() as i32,
    };
    let (mut dpi_x, mut dpi_y) = (0u32, 0u32);
    // SAFETY: both out-parameters outlive the call.
    unsafe {
        let monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y).ok()?;
    }
    (dpi_x > 0).then(|| dpi_x as f32 / 96.0)
}

pub(super) fn place_overlay(hwnd: isize, frame: Option<Rect>) -> anyhow::Result<()> {
    let window = HWND(hwnd as *mut core::ffi::c_void);
    // SAFETY: `window` is LokalBot's own ghost window.
    unsafe {
        match frame {
            Some(frame) => {
                let frame = frame.integral();
                SetWindowPos(
                    window,
                    Some(HWND_TOPMOST),
                    frame.x as i32,
                    frame.y as i32,
                    frame.width.max(1.0) as i32,
                    frame.height.max(1.0) as i32,
                    SWP_NOACTIVATE | SWP_SHOWWINDOW,
                )
                .context("SetWindowPos")?;
            }
            None => {
                let _ = ShowWindow(window, SW_HIDE);
            }
        }
    }
    Ok(())
}

/// The work area of the monitor showing `rect`.
pub(super) fn screen_containing(rect: &Rect) -> Option<Rect> {
    let point = POINT {
        x: rect.x as i32,
        y: rect.mid_y() as i32,
    };
    // SAFETY: `info` is a valid MONITORINFO with cbSize set.
    unsafe {
        let monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO {
            cbSize: size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if !GetMonitorInfoW(monitor, &mut info).as_bool() {
            return None;
        }
        let work = info.rcWork;
        Some(Rect::new(
            work.left as f32,
            work.top as f32,
            (work.right - work.left) as f32,
            (work.bottom - work.top) as f32,
        ))
    }
}

/// Mean luminance of a few pixels just right of `rect`.
pub(super) fn sample_luminance(rect: &Rect) -> Option<f32> {
    // SAFETY: the screen DC is released before returning.
    unsafe {
        let dc = GetDC(None);
        if dc.is_invalid() {
            return None;
        }
        let y = rect.mid_y() as i32;
        let mut total = 0.0;
        let mut count = 0.0;
        for dx in [2, 4, 6] {
            let color = GetPixel(dc, rect.right() as i32 + dx, y);
            if color.0 == u32::MAX {
                continue;
            }
            let (r, g, b) = (
                color.0 & 0xff,
                (color.0 >> 8) & 0xff,
                (color.0 >> 16) & 0xff,
            );
            total += (0.299 * r as f32 + 0.587 * g as f32 + 0.114 * b as f32) / 255.0;
            count += 1.0;
        }
        ReleaseDC(None, dc);
        (count > 0.0).then(|| total / count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keystrokes_carry_the_marker() {
        let down = key_input(VK_TAB, false);
        // SAFETY: reading the keyboard member of an INPUT built as one.
        let ki = unsafe { down.Anonymous.ki };
        assert_eq!(ki.dwExtraInfo, MARKER);
        assert_eq!(ki.wVk, VK_TAB);
        let text = unicode_input(0x41, true);
        // SAFETY: as above.
        let ki = unsafe { text.Anonymous.ki };
        assert_eq!(ki.dwExtraInfo, MARKER);
        assert!(ki.dwFlags.contains(KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
    }

    #[test]
    fn the_hook_installs_and_removes_without_a_desktop() {
        // Over SSH (session 0) installing may fail; it must not panic or hang.
        let hook = Hook::start(std::sync::Arc::new(|_| {})).unwrap();
        hook.set_active(true);
        std::thread::sleep(std::time::Duration::from_millis(100));
        hook.set_active(false);
        drop(hook);
    }
}
