//! A Win32 message loop on a worker thread. Hidden windows created by
//! `global-hotkey` and `tray-icon` receive their messages on the thread that
//! created them, so each runs one of these instead of relying on GPUI's
//! main-thread loop.

use windows::Win32::Foundation::{LPARAM, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, GetMessageW, MSG, PM_NOREMOVE, PeekMessageW, PostThreadMessageW,
    TranslateMessage, WM_APP, WM_USER,
};

const WM_WAKE: u32 = WM_APP + 0x4C42;

/// Asks the loop on `thread_id` to run its `on_wake` callback.
pub(crate) fn wake(thread_id: u32) {
    // SAFETY: posting a message without pointers to a thread id is always
    // memory-safe; a thread that has exited only makes the call fail.
    let _ = unsafe { PostThreadMessageW(thread_id, WM_WAKE, WPARAM(0), LPARAM(0)) };
}

/// Runs the loop on the calling thread until `on_wake` returns false.
/// `ready` receives this thread's id once others may post to it.
pub(crate) fn run(ready: impl FnOnce(u32), mut on_wake: impl FnMut() -> bool) {
    let mut msg = MSG::default();
    // SAFETY: `msg` is a valid, writable MSG for each call; these functions
    // only touch this thread's message queue.
    unsafe {
        // Creates the thread's message queue before anyone posts to it.
        let _ = PeekMessageW(&mut msg, None, WM_USER, WM_USER, PM_NOREMOVE);
        ready(GetCurrentThreadId());
        loop {
            let result = GetMessageW(&mut msg, None, 0, 0);
            if result.0 == 0 || result.0 == -1 {
                break;
            }
            if msg.message == WM_WAKE && msg.hwnd.0.is_null() {
                if !on_wake() {
                    break;
                }
                continue;
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}
