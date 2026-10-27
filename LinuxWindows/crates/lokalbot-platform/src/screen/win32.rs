//! Windows: the foreground window's visible bounds (DWM's extended frame,
//! without the drop shadow) copied from the screen with GDI `BitBlt`. The
//! copy is what the user sees, it never waits on the target app (unlike
//! `PrintWindow`, which a hung app can block), and it works for DirectX and
//! browser windows. Coordinates are physical pixels: the capturing thread
//! is per-monitor DPI aware for the duration of each call.

use std::ffi::c_void;

use anyhow::{Context as _, bail};
use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::Graphics::Dwm::{
    DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS, DwmGetWindowAttribute,
};
use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CAPTUREBLT, CreateCompatibleBitmap,
    CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, GetDIBits, HGDIOBJ,
    ReleaseDC, SRCCOPY, SelectObject,
};
use windows::Win32::System::RemoteDesktop::{
    WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION, WTS_SESSIONSTATE_LOCK, WTSFreeMemory,
    WTSINFOEXW, WTSQuerySessionInformationW, WTSSessionInfoEx,
};
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetThreadDpiAwarenessContext,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetSystemMetrics, GetWindowRect, GetWindowTextLengthW, GetWindowTextW,
    GetWindowThreadProcessId, IsIconic, IsWindowVisible, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
    SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};
use windows::core::PWSTR;

use super::{CapturedImage, FocusedWindow, WindowCapture, WindowRect};

pub(super) struct GdiCapture;

impl GdiCapture {
    pub(super) fn new() -> Self {
        Self
    }
}

/// Per-monitor DPI awareness for the current thread until dropped, so
/// window rectangles and screen pixels agree on every monitor.
struct DpiScope(DPI_AWARENESS_CONTEXT);

impl DpiScope {
    fn enter() -> Self {
        // SAFETY: changes only this thread's DPI awareness; restored in `drop`.
        Self(unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) })
    }
}

impl Drop for DpiScope {
    fn drop(&mut self) {
        if !self.0.0.is_null() {
            // SAFETY: restores the context returned by the matching call.
            unsafe { SetThreadDpiAwarenessContext(self.0) };
        }
    }
}

fn hwnd(id: u64) -> HWND {
    HWND(id as usize as *mut c_void)
}

fn window_pid(window: HWND) -> Option<u32> {
    let mut pid = 0u32;
    // SAFETY: `pid` outlives the call; an invalid window leaves it 0.
    unsafe { GetWindowThreadProcessId(window, Some(&mut pid)) };
    (pid != 0).then_some(pid)
}

fn window_title(window: HWND) -> String {
    // SAFETY: reads the caption into a buffer of the reported length. For
    // other processes this never sends WM_GETTEXT, so a hung app cannot block.
    unsafe {
        let length = GetWindowTextLengthW(window);
        if length <= 0 {
            return String::new();
        }
        let mut buffer = vec![0u16; length as usize + 1];
        let copied = GetWindowTextW(window, &mut buffer);
        String::from_utf16_lossy(&buffer[..copied.max(0) as usize])
    }
}

/// The visible frame (no drop shadow), in physical pixels; `None` when the
/// window is minimized, hidden or cloaked (another virtual desktop).
fn visible_rect(window: HWND) -> Option<WindowRect> {
    // SAFETY: plain queries on a window handle; the out-parameters are
    // properly sized locals.
    unsafe {
        if IsIconic(window).as_bool() || !IsWindowVisible(window).as_bool() {
            return None;
        }
        let mut cloaked = 0u32;
        if DwmGetWindowAttribute(
            window,
            DWMWA_CLOAKED,
            (&mut cloaked as *mut u32).cast(),
            size_of::<u32>() as u32,
        )
        .is_ok()
            && cloaked != 0
        {
            return None;
        }
        let mut rect = RECT::default();
        if DwmGetWindowAttribute(
            window,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            (&mut rect as *mut RECT).cast(),
            size_of::<RECT>() as u32,
        )
        .is_err()
        {
            GetWindowRect(window, &mut rect).ok()?;
        }
        let rect = WindowRect {
            x: rect.left,
            y: rect.top,
            width: (rect.right - rect.left).max(0) as u32,
            height: (rect.bottom - rect.top).max(0) as u32,
        };
        (!rect.is_empty()).then_some(rect)
    }
}

fn virtual_screen() -> WindowRect {
    // SAFETY: metrics queries without side effects.
    unsafe {
        WindowRect {
            x: GetSystemMetrics(SM_XVIRTUALSCREEN),
            y: GetSystemMetrics(SM_YVIRTUALSCREEN),
            width: GetSystemMetrics(SM_CXVIRTUALSCREEN).max(0) as u32,
            height: GetSystemMetrics(SM_CYVIRTUALSCREEN).max(0) as u32,
        }
    }
}

/// Copies a screen rectangle into RGBA.
fn copy_screen(area: WindowRect) -> anyhow::Result<CapturedImage> {
    let (width, height) = (area.width as i32, area.height as i32);
    // SAFETY: every GDI object created here is selected out and deleted
    // before returning; `pixels` is sized for the 32-bit top-down DIB that
    // GetDIBits writes.
    unsafe {
        let screen = GetDC(None);
        if screen.is_invalid() {
            bail!("no screen device context");
        }
        let memory = CreateCompatibleDC(Some(screen));
        let bitmap = CreateCompatibleBitmap(screen, width, height);
        let previous = SelectObject(memory, HGDIOBJ(bitmap.0));
        let copied = BitBlt(
            memory,
            0,
            0,
            width,
            height,
            Some(screen),
            area.x,
            area.y,
            SRCCOPY | CAPTUREBLT,
        );
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width,
                // Negative: rows top to bottom.
                biHeight: -height,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut pixels = vec![0u8; area.width as usize * area.height as usize * 4];
        let lines = if copied.is_ok() {
            GetDIBits(
                memory,
                bitmap,
                0,
                area.height,
                Some(pixels.as_mut_ptr().cast()),
                &mut info,
                DIB_RGB_COLORS,
            )
        } else {
            0
        };
        SelectObject(memory, previous);
        let _ = DeleteObject(HGDIOBJ(bitmap.0));
        let _ = DeleteDC(memory);
        ReleaseDC(None, screen);
        copied.context("copying the window from the screen failed")?;
        if lines != height {
            bail!("reading the copied pixels failed");
        }
        // BGRA to RGBA; the screen has no alpha.
        for pixel in pixels.as_chunks_mut::<4>().0 {
            pixel.swap(0, 2);
            pixel[3] = 255;
        }
        Ok(CapturedImage {
            width: area.width,
            height: area.height,
            rgba: pixels,
        })
    }
}

impl WindowCapture for GdiCapture {
    fn limitation(&self) -> Option<String> {
        None
    }

    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        let _dpi = DpiScope::enter();
        // SAFETY: no arguments; returns a possibly null window handle.
        let window = unsafe { GetForegroundWindow() };
        if window.0.is_null() {
            return Ok(None);
        }
        let Some(rect) = visible_rect(window) else {
            return Ok(None);
        };
        Ok(Some(FocusedWindow {
            id: window.0 as usize as u64,
            pid: window_pid(window),
            title: window_title(window),
            rect: Some(rect),
        }))
    }

    fn capture(&mut self, window: &FocusedWindow) -> anyhow::Result<CapturedImage> {
        let _dpi = DpiScope::enter();
        let handle = hwnd(window.id);
        // SAFETY: no arguments; returns a possibly null window handle.
        if unsafe { GetForegroundWindow() } != handle {
            bail!("another window came to the front");
        }
        let rect = visible_rect(handle).context("the window is no longer visible")?;
        let area = rect
            .intersection(&virtual_screen())
            .context("the window is outside the screen")?;
        let image = copy_screen(area)?;
        // A secure desktop (UAC, the lock screen) or protected content reads back black.
        if image.is_uniform() {
            bail!("the window's pixels could not be read");
        }
        Ok(image)
    }

    fn name(&self) -> &'static str {
        "gdi"
    }
}

/// `WTSSessionInfoEx` reports the lock state of this session (Windows 10 and later).
pub(super) fn session_locked() -> bool {
    let mut buffer = PWSTR::null();
    let mut bytes = 0u32;
    // SAFETY: WTS allocates `buffer`, which is read as the documented
    // WTSINFOEXW when large enough and freed with WTSFreeMemory.
    unsafe {
        if WTSQuerySessionInformationW(
            Some(WTS_CURRENT_SERVER_HANDLE),
            WTS_CURRENT_SESSION,
            WTSSessionInfoEx,
            &mut buffer,
            &mut bytes,
        )
        .is_err()
            || buffer.is_null()
        {
            return false;
        }
        let locked = (bytes as usize >= size_of::<WTSINFOEXW>()).then(|| {
            let info = &*(buffer.0 as *const WTSINFOEXW);
            info.Level == 1
                && info.Data.WTSInfoExLevel1.SessionFlags as u32 == WTS_SESSIONSTATE_LOCK
        });
        WTSFreeMemory(buffer.0.cast());
        locked.unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn works_without_a_desktop() {
        // Over SSH (session 0) there is no foreground window; nothing fails.
        let mut capture = GdiCapture::new();
        let focused = capture.focused().unwrap();
        eprintln!("focused window: {focused:?}");
        let _ = session_locked();
        assert!(capture.capture(&FocusedWindow::default()).is_err());
    }
}
