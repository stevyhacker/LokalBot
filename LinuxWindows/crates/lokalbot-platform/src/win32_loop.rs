use windows::Win32::Foundation::{LPARAM, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, GetMessageW, MSG, PM_NOREMOVE, PeekMessageW, PostThreadMessageW,
    TranslateMessage, WM_APP, WM_USER,
};

const WM_WAKE: u32 = WM_APP + 0x4C42;

pub(crate) fn wake(thread_id: u32) {
    let _ = unsafe { PostThreadMessageW(thread_id, WM_WAKE, WPARAM(0), LPARAM(0)) };
}

pub(crate) fn run(ready: impl FnOnce(u32), mut on_wake: impl FnMut() -> bool) {
    let mut msg = MSG::default();
    unsafe {
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
