//! Checks autocomplete's desktop path in a real app, without the engine or a
//! model: opens Notepad on Windows (the GTK test field from
//! `lokalbot-platform/scripts` on Linux), types a sentence into it, prints
//! what the field watcher reads, shows a fixed suggestion in the ghost
//! window after the caret and saves a screenshot, presses Tab, and prints
//! the field's text after the accept. Then Esc dismisses the rest.
//!
//! ```text
//! cargo run -p lokalbot-app --example autocomplete_probe -- [--out <dir>] [--keep-open]
//! ```
//!
//! Needs an interactive desktop session (not a service or SSH session).
//! Screenshots go to `<dir>` (default `autocomplete-probe`); the last line
//! is `PROBE PASS` or `PROBE FAIL: <reason>`, with exit status 0 or 1.
//! Notepad is emptied and closed at the end unless `--keep-open` is given.
//! On Windows each ghost is also checked to fill exactly the frame it was
//! placed at, with no window frame around it.
//!
//! `--overlay-only` skips the app and the keys: it shows and moves the ghost
//! for a made-up field and checks its window, which works without a desktop
//! app in front.

// The app's own layout and ghost window; `layout` reaches `overlay` as
// `super::overlay`, so both sit at the root here as they sit side by side
// in the app.
#[allow(dead_code)]
#[path = "../src/autocomplete/layout.rs"]
mod layout;
#[allow(dead_code)]
#[path = "../src/autocomplete/overlay.rs"]
mod overlay;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use gpui_kit::{App, rgb};
use lokalbot_core::settings::AcceptGranularity;
use lokalbot_platform::autocomplete::{
    self as platform, Capability, Edit, FieldSnapshot, FieldWatcher, FocusSnapshot, InterceptedKey,
    KeyInterceptor, ReadPolicy, Rect,
};
use parking_lot::{Condvar, Mutex};

const SENTENCE: &str = "Thanks for the update. I wanted to follow";
const SUGGESTION: &str = " up on the migration timeline";

/// What the script asks the UI thread to do.
enum Ui {
    Show {
        field: Box<FieldSnapshot>,
        text: String,
        reply: crossbeam_channel::Sender<Option<(Rect, String, String)>>,
    },
    Hide,
}

/// The newest focus the watcher reported.
#[derive(Default)]
struct Focus {
    latest: Mutex<Option<FocusSnapshot>>,
    changed: Condvar,
}

impl Focus {
    /// Waits until `pick` finds what it wants in a snapshot.
    fn wait<T>(
        &self,
        timeout: Duration,
        mut pick: impl FnMut(&FocusSnapshot) -> Option<T>,
    ) -> Option<T> {
        let deadline = Instant::now() + timeout;
        let mut latest = self.latest.lock();
        loop {
            if let Some(found) = latest.as_ref().and_then(&mut pick) {
                return Some(found);
            }
            if self.changed.wait_until(&mut latest, deadline).timed_out() {
                return latest.as_ref().and_then(&mut pick);
            }
        }
    }
}

struct Options {
    out: PathBuf,
    keep_open: bool,
    overlay_only: bool,
}

fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let args: Vec<String> = std::env::args().collect();
    let out = args
        .iter()
        .position(|a| a == "--out")
        .and_then(|i| args.get(i + 1))
        .map_or_else(|| PathBuf::from("autocomplete-probe"), PathBuf::from);
    let options = Options {
        out,
        keep_open: args.iter().any(|a| a == "--keep-open"),
        overlay_only: args.iter().any(|a| a == "--overlay-only"),
    };
    if let Err(err) = std::fs::create_dir_all(&options.out) {
        println!(
            "PROBE FAIL: could not create {}: {err}",
            options.out.display()
        );
        std::process::exit(1);
    }
    let (ui, commands) = smol::channel::unbounded::<Ui>();
    gpui_kit::application().run(move |cx: &mut App| {
        gpui_kit::init(cx);
        cx.spawn(async move |cx| {
            let mut ghost = overlay::Overlay::new(false);
            while let Ok(command) = commands.recv().await {
                cx.update(|cx| match command {
                    Ui::Show { field, text, reply } => {
                        let _ = reply.send(show(&mut ghost, &field, &text, cx));
                    }
                    Ui::Hide => ghost.hide(cx),
                });
            }
        })
        .detach();
        std::thread::spawn(move || {
            let mut target = None;
            let outcome = if options.overlay_only {
                overlay_script(&ui)
            } else {
                script(&options, &ui, &mut target)
            };
            if let Some(target) = target.take()
                && !options.keep_open
            {
                target.close();
            }
            match outcome {
                Ok(()) => {
                    println!("PROBE PASS");
                    std::process::exit(0);
                }
                Err(err) => {
                    println!("PROBE FAIL: {err:#}");
                    std::process::exit(1);
                }
            }
        });
    });
}

/// Lays `text` out after the field's caret and shows it, as the app does.
fn show(
    ghost: &mut overlay::Overlay,
    field: &FieldSnapshot,
    text: &str,
    cx: &mut App,
) -> Option<(Rect, String, String)> {
    let emphasis = lokalbot_ai::autocomplete::accept_chunk(text, AcceptGranularity::Word);
    let screen = platform::screen_containing(&field.caret);
    let reported = field
        .style
        .as_ref()
        .is_some_and(|s| s.color.is_some() && s.background.is_some());
    let sampled = if reported {
        None
    } else {
        platform::sample_luminance(&field.caret)
    };
    let appearance = layout::Appearance {
        dark: false,
        ui_font: if cfg!(windows) {
            "Segoe UI".into()
        } else {
            "DejaVu Sans".into()
        },
        pill_background: rgb(0xf4f4f5).into(),
        pill_border: rgb(0xd4d4d8).into(),
        pill_text: rgb(0x52525b).into(),
        pill_emphasis: rgb(0x18181b).into(),
    };
    let mut scale = ghost.scale();
    let mut shown = None;
    for _ in 0..2 {
        let placement = layout::place(
            text,
            &emphasis,
            field,
            field.caret,
            screen,
            scale,
            sampled,
            &appearance,
            cx,
        )?;
        let now = ghost.show(placement.frame, placement.content.clone(), cx);
        shown = Some((
            placement.frame,
            format!("{:?}", placement.mode),
            placement.shown.clone(),
        ));
        if (now - scale).abs() < 0.01 {
            break;
        }
        scale = now;
    }
    shown
}

fn script(
    options: &Options,
    ui: &smol::channel::Sender<Ui>,
    target: &mut Option<Target>,
) -> anyhow::Result<()> {
    println!("support: {:?}", platform::support());
    let focus = Arc::new(Focus::default());
    let watcher = {
        let focus = focus.clone();
        let policy = ReadPolicy {
            enabled: true,
            visible_text: true,
            ..Default::default()
        };
        FieldWatcher::start(policy, move |snapshot| {
            match &snapshot.field {
                Some(field) => log::info!(
                    "watcher: {} ({}) {} characters before the caret",
                    field.app_name,
                    field.app_id,
                    field.before.chars().count()
                ),
                None => log::info!(
                    "watcher: {} ({}) {:?}",
                    snapshot.app_name,
                    snapshot.app_id,
                    snapshot.capability
                ),
            }
            *focus.latest.lock() = Some(snapshot);
            focus.changed.notify_all();
        })?
    };
    if let Some(limitation) = watcher.limitation() {
        println!("watcher limitation: {limitation}");
    }

    let opened = Target::open()?;
    let app_id = opened.app_id.to_lowercase();
    // Kept before raising it, so it is closed again whatever fails next.
    let opened = target.insert(opened);
    opened.raise()?;
    let field = focus
        .wait(Duration::from_secs(25), |snapshot| {
            let app = snapshot.app_id.to_lowercase();
            (app.contains(&app_id) && snapshot.capability == Capability::Supported)
                .then(|| snapshot.field.clone())
                .flatten()
        })
        .ok_or_else(|| {
            anyhow::anyhow!(
                "the watcher never reported an editable {app_id} field (last: {:?})",
                focus
                    .latest
                    .lock()
                    .as_ref()
                    .map(|s| (&s.app_id, &s.capability))
            )
        })?;
    println!(
        "FOCUSED app={:?} id={:?} title={:?} before={:?}",
        field.app_name, field.app_id, field.window_title, field.before
    );

    // Typed the way an accept types, so the field holds exactly this.
    platform::insert(
        &field,
        &Edit {
            text: SENTENCE.into(),
            ..Default::default()
        },
    )?;
    let field = wait_for_text(&focus, SENTENCE)?;
    print_read("WATCHER READ", &field);

    let (keys_tx, keys) = crossbeam_channel::unbounded::<InterceptedKey>();
    let interceptor = KeyInterceptor::start(move |key| {
        let _ = keys_tx.send(key);
    })?;
    interceptor.set_active(true);

    let shown = show_ghost(ui, &field, SUGGESTION)?;
    println!(
        "OVERLAY {} {:?} at ({:.0},{:.0} {:.0}x{:.0})",
        shown.1, shown.2, shown.0.x, shown.0.y, shown.0.width, shown.0.height
    );
    std::thread::sleep(Duration::from_millis(700));
    check_ghost_window(shown.0)?;
    screenshot(options, "01-ghost", &field, shown.0)?;

    let before_tab = Instant::now();
    press(Key::Tab)?;
    let key = keys
        .recv_timeout(Duration::from_secs(3))
        .map_err(|_| anyhow::anyhow!("the Tab press never reached the key interceptor"))?;
    anyhow::ensure!(
        key == InterceptedKey::Tab,
        "expected Tab, the interceptor took {key:?}"
    );
    println!(
        "TAB taken by the interceptor after {} ms",
        before_tab.elapsed().as_millis()
    );
    let plan = lokalbot_ai::autocomplete::plan_acceptance(
        SUGGESTION,
        AcceptGranularity::Word,
        &field.before,
        &field.after,
    )
    .ok_or_else(|| anyhow::anyhow!("nothing to accept"))?;
    platform::insert(
        &field,
        &Edit {
            text: plan.insertion.clone(),
            backward: plan.backward_delete,
            forward: plan.forward_delete,
        },
    )?;
    let expected = format!("{SENTENCE}{}", plan.insertion);
    let accepted = wait_for_text(&focus, &expected)?;
    print_read("AFTER TAB", &accepted);
    anyhow::ensure!(
        !accepted.before.contains('\t') && !accepted.after.contains('\t'),
        "the app also got the Tab"
    );
    println!(
        "FIELD TEXT {:?}",
        format!("{}{}", accepted.before, accepted.after)
    );

    let rest = &SUGGESTION[plan.chunk.len()..];
    let moved = show_ghost(ui, &accepted, rest)?;
    std::thread::sleep(Duration::from_millis(700));
    check_ghost_window(moved.0)?;
    screenshot(options, "02-after-tab", &accepted, moved.0)?;

    press(Key::Escape)?;
    let key = keys
        .recv_timeout(Duration::from_secs(3))
        .map_err(|_| anyhow::anyhow!("the Esc press never reached the key interceptor"))?;
    anyhow::ensure!(
        key == InterceptedKey::Escape,
        "expected Esc, the interceptor took {key:?}"
    );
    let _ = ui.send_blocking(Ui::Hide);
    interceptor.set_active(false);
    std::thread::sleep(Duration::from_millis(500));
    screenshot(options, "03-after-escape", &accepted, moved.0)?;
    let after_escape = focus
        .wait(Duration::from_secs(2), |s| s.field.clone())
        .ok_or_else(|| anyhow::anyhow!("the field went away after Esc"))?;
    anyhow::ensure!(
        after_escape.before == accepted.before,
        "Esc changed the field: {:?}",
        after_escape.before
    );
    println!("ESC taken by the interceptor; the field is unchanged");
    drop(watcher);
    Ok(())
}

/// Shows and moves the ghost for a made-up field and checks its window.
fn overlay_script(ui: &smol::channel::Sender<Ui>) -> anyhow::Result<()> {
    let style = platform::FieldStyle {
        font_family: Some(String::from(if cfg!(windows) {
            "Consolas"
        } else {
            "DejaVu Sans Mono"
        })),
        font_points: Some(11.0),
        color: Some(platform::Rgb { r: 0, g: 0, b: 0 }),
        background: Some(platform::Rgb {
            r: 255,
            g: 255,
            b: 255,
        }),
    };
    let mut field = FieldSnapshot {
        app_name: "Probe".into(),
        app_id: "probe".into(),
        before: SENTENCE.into(),
        caret: Rect::new(366.0, 77.0, 0.0, 15.0),
        caret_exact: true,
        field_frame: Some(Rect::new(34.0, 77.0, 1424.0, 671.0)),
        style: Some(style),
        ..Default::default()
    };
    let shown = show_ghost(ui, &field, SUGGESTION)?;
    println!(
        "OVERLAY {} {:?} at ({:.0},{:.0} {:.0}x{:.0})",
        shown.1, shown.2, shown.0.x, shown.0.y, shown.0.width, shown.0.height
    );
    std::thread::sleep(Duration::from_millis(700));
    check_ghost_window(shown.0)?;
    field.before.push_str(" up");
    field.caret.x += 24.0;
    let moved = show_ghost(ui, &field, " on the migration timeline")?;
    println!(
        "MOVED {} {:?} at ({:.0},{:.0} {:.0}x{:.0})",
        moved.1, moved.2, moved.0.x, moved.0.y, moved.0.width, moved.0.height
    );
    std::thread::sleep(Duration::from_millis(700));
    check_ghost_window(moved.0)?;
    let _ = ui.send_blocking(Ui::Hide);
    Ok(())
}

/// On Windows, that the ghost's window is exactly `frame` with nothing
/// around it: no caption or border, its client area its whole window.
fn check_ghost_window(frame: Rect) -> anyhow::Result<()> {
    #[cfg(windows)]
    {
        let (window, client, frameless) =
            win::ghost_window().ok_or_else(|| anyhow::anyhow!("no visible ghost window"))?;
        println!(
            "GHOST WINDOW at ({:.0},{:.0} {:.0}x{:.0}), client {:.0}x{:.0}, frameless {frameless}",
            window.x, window.y, window.width, window.height, client.width, client.height
        );
        let close = |a: f32, b: f32| (a - b).abs() <= 1.0;
        anyhow::ensure!(frameless, "the ghost window has a frame");
        anyhow::ensure!(
            close(client.width, window.width) && close(client.height, window.height),
            "the ghost's client area is smaller than its window"
        );
        anyhow::ensure!(
            close(window.x, frame.x)
                && close(window.y, frame.y)
                && close(window.width, frame.width)
                && close(window.height, frame.height),
            "the ghost window is not where it was placed"
        );
    }
    #[cfg(not(windows))]
    let _ = frame;
    Ok(())
}

fn wait_for_text(focus: &Focus, before: &str) -> anyhow::Result<FieldSnapshot> {
    focus
        .wait(Duration::from_secs(8), |snapshot| {
            snapshot
                .field
                .clone()
                .filter(|field| field.before.ends_with(before))
        })
        .ok_or_else(|| {
            anyhow::anyhow!(
                "the field never read {before:?} (last: {:?})",
                focus
                    .latest
                    .lock()
                    .as_ref()
                    .and_then(|s| s.field.as_ref().map(|f| f.before.clone()))
            )
        })
}

fn show_ghost(
    ui: &smol::channel::Sender<Ui>,
    field: &FieldSnapshot,
    text: &str,
) -> anyhow::Result<(Rect, String, String)> {
    let (reply, shown) = crossbeam_channel::bounded(1);
    ui.send_blocking(Ui::Show {
        field: Box::new(field.clone()),
        text: text.into(),
        reply,
    })
    .map_err(|_| anyhow::anyhow!("the UI thread is gone"))?;
    shown
        .recv_timeout(Duration::from_secs(5))
        .map_err(|_| anyhow::anyhow!("the UI thread did not answer"))?
        .ok_or_else(|| anyhow::anyhow!("the ghost found no place on screen"))
}

fn print_read(label: &str, field: &FieldSnapshot) {
    println!(
        "{label} app={:?} id={:?} pid={} title={:?}\n  before={:?}\n  after={:?}\n  caret=({:.0},{:.0} {:.0}x{:.0}) exact={} frame={:?}\n  single_line={} style={:?}\n  visible_text={:?}",
        field.app_name,
        field.app_id,
        field.pid,
        field.window_title,
        field.before,
        field.after,
        field.caret.x,
        field.caret.y,
        field.caret.width,
        field.caret.height,
        field.caret_exact,
        field.field_frame,
        field.single_line,
        field.style,
        field.visible_text,
    );
}

/// The whole screen with the ghost, and a close-up around the caret.
fn screenshot(
    options: &Options,
    name: &str,
    field: &FieldSnapshot,
    ghost: Rect,
) -> anyhow::Result<()> {
    let full = options.out.join(format!("{name}.png"));
    capture_screen(&full)?;
    let area = field
        .field_frame
        .unwrap_or(field.caret)
        .union(&ghost)
        .union(&field.caret);
    let image = image::open(&full)?;
    let (width, height) = (image.width() as f32, image.height() as f32);
    let (left, top) = screen_origin();
    let x = (area.x - left - 40.0).clamp(0.0, width - 1.0);
    let y = (area.y - top - 40.0).clamp(0.0, height - 1.0);
    let w = (area.width + 80.0).min(width - x);
    let h = (area.height + 80.0).min(height - y);
    let crop = image.crop_imm(x as u32, y as u32, w.max(1.0) as u32, h.max(1.0) as u32);
    let close = options.out.join(format!("{name}-crop.png"));
    crop.save(&close)?;
    println!("SCREENSHOT {} and {}", full.display(), close.display());
    Ok(())
}

enum Key {
    Tab,
    Escape,
}

/// The app the probe types into, closed again at the end.
struct Target {
    app_id: String,
    #[cfg(windows)]
    pid: u32,
    #[cfg(windows)]
    hwnd: isize,
    /// What was started: the field app on Linux; on Windows 11 a launcher
    /// that hands over to the Notepad owning the window.
    child: std::process::Child,
}

#[cfg(windows)]
mod win {
    use super::*;
    use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM, RECT};
    use windows::Win32::Graphics::Gdi::{
        BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CAPTUREBLT, CreateCompatibleBitmap,
        CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC,
        SRCCOPY, SelectObject,
    };
    use windows::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW,
        TH32CS_SNAPPROCESS,
    };
    use windows::Win32::System::Threading::{OpenProcess, PROCESS_TERMINATE, TerminateProcess};
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        INPUT, INPUT_0, INPUT_KEYBOARD, KEYBD_EVENT_FLAGS, KEYBDINPUT, KEYEVENTF_EXTENDEDKEY,
        KEYEVENTF_KEYUP, SendInput, VIRTUAL_KEY, VK_A, VK_CONTROL, VK_DELETE, VK_ESCAPE, VK_MENU,
        VK_TAB,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, FindWindowW, GWL_EXSTYLE, GWL_STYLE, GetClientRect, GetForegroundWindow,
        GetSystemMetrics, GetWindowLongPtrW, GetWindowRect, GetWindowThreadProcessId,
        IsWindowVisible, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
        SM_YVIRTUALSCREEN, SetForegroundWindow, WS_CAPTION, WS_EX_TRANSPARENT, WS_POPUP,
    };
    use windows::core::{BOOL, PCWSTR, w};

    fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
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
                    // Unmarked, so the interceptor treats it as the user's.
                    dwExtraInfo: 0,
                },
            },
        }
    }

    pub(super) fn send(keys: &[(VIRTUAL_KEY, bool)]) -> anyhow::Result<()> {
        let inputs: Vec<INPUT> = keys.iter().map(|&(vk, up)| key(vk, up)).collect();
        // SAFETY: a valid slice of INPUT structures.
        let sent = unsafe { SendInput(&inputs, size_of::<INPUT>() as i32) };
        anyhow::ensure!(
            sent as usize == inputs.len(),
            "SendInput took {sent} of {} events: {}",
            inputs.len(),
            std::io::Error::last_os_error()
        );
        Ok(())
    }

    pub(super) fn press(which: &Key) -> anyhow::Result<()> {
        let vk = match which {
            Key::Tab => VK_TAB,
            Key::Escape => VK_ESCAPE,
        };
        send(&[(vk, false)])?;
        std::thread::sleep(Duration::from_millis(40));
        send(&[(vk, true)])
    }

    fn notepad() -> Option<HWND> {
        // SAFETY: plain window lookup.
        unsafe { FindWindowW(w!("Notepad"), PCWSTR::null()) }
            .ok()
            .filter(|hwnd| !hwnd.is_invalid())
    }

    fn window_pid(hwnd: HWND) -> u32 {
        let mut pid = 0;
        // SAFETY: `pid` outlives the call; a stale window gives 0.
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
        pid
    }

    fn in_front(target: &Target) -> bool {
        // SAFETY: no arguments.
        let front = unsafe { GetForegroundWindow() };
        !front.is_invalid() && window_pid(front) == target.pid
    }

    pub(super) fn open() -> anyhow::Result<Target> {
        // Never touch a Notepad the user has open.
        anyhow::ensure!(
            notepad().is_none(),
            "a Notepad window is already open; close it first"
        );
        let mut launcher = std::process::Command::new("notepad.exe").spawn()?;
        let deadline = Instant::now() + Duration::from_secs(15);
        let hwnd = loop {
            if let Some(hwnd) = notepad() {
                break hwnd;
            }
            if Instant::now() >= deadline {
                let _ = launcher.kill();
                anyhow::bail!("Notepad did not open a window");
            }
            std::thread::sleep(Duration::from_millis(100));
        };
        let pid = window_pid(hwnd);
        println!(
            "NOTEPAD hwnd={:?} pid={pid} (started pid {})",
            hwnd.0,
            launcher.id()
        );
        Ok(Target {
            app_id: "notepad".into(),
            pid,
            hwnd: hwnd.0 as isize,
            child: launcher,
        })
    }

    pub(super) fn raise(target: &Target) -> anyhow::Result<()> {
        std::thread::sleep(Duration::from_millis(800));
        if !in_front(target) {
            // A tap of Alt lets this process bring another window forward.
            send(&[(VK_MENU, false), (VK_MENU, true)])?;
            // SAFETY: a top-level window handle; a stale one is refused.
            let _ = unsafe { SetForegroundWindow(HWND(target.hwnd as *mut _)) };
            std::thread::sleep(Duration::from_millis(300));
        }
        anyhow::ensure!(
            in_front(target),
            "Notepad could not be brought to the front"
        );
        Ok(())
    }

    pub(super) fn close(mut target: Target) {
        // Empty it first, so a Notepad that restores its last session
        // brings nothing back; only while it is in front, so the keys never
        // reach another app.
        if in_front(&target) {
            let _ = send(&[
                (VK_CONTROL, false),
                (VK_A, false),
                (VK_A, true),
                (VK_CONTROL, true),
                (VK_DELETE, false),
                (VK_DELETE, true),
            ]);
            std::thread::sleep(Duration::from_millis(300));
        }
        // Notepad, the helper processes it started, and the launcher.
        let mut pids = vec![target.pid];
        pids.extend(children_of(&[target.pid, target.child.id()]));
        for pid in pids {
            // SAFETY: the handle is closed before moving on.
            unsafe {
                if let Ok(process) = OpenProcess(PROCESS_TERMINATE, false, pid) {
                    let _ = TerminateProcess(process, 0);
                    let _ = CloseHandle(process);
                }
            }
        }
        let _ = target.child.kill();
        let _ = target.child.wait();
        println!("NOTEPAD closed");
    }

    /// Processes whose parent is one of `parents`.
    fn children_of(parents: &[u32]) -> Vec<u32> {
        let mut found = Vec::new();
        // SAFETY: the snapshot handle is closed before returning; `entry`
        // carries its size as the API requires.
        unsafe {
            let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
                return found;
            };
            let mut entry = PROCESSENTRY32W {
                dwSize: size_of::<PROCESSENTRY32W>() as u32,
                ..Default::default()
            };
            let mut more = Process32FirstW(snapshot, &mut entry).is_ok();
            while more {
                if parents.contains(&entry.th32ParentProcessID) {
                    found.push(entry.th32ProcessID);
                }
                more = Process32NextW(snapshot, &mut entry).is_ok();
            }
            let _ = CloseHandle(snapshot);
        }
        found
    }

    /// This process's visible click-through window (the ghost): its window
    /// rect, its client size, and whether it has no caption or border.
    pub(super) fn ghost_window() -> Option<(Rect, Rect, bool)> {
        unsafe extern "system" fn visit(window: HWND, lparam: LPARAM) -> BOOL {
            // SAFETY: `lparam` is the vector `ghost_window` keeps alive for
            // the whole enumeration; the rest are plain queries.
            unsafe {
                let found = &mut *(lparam.0 as *mut Vec<HWND>);
                let mut pid = 0u32;
                GetWindowThreadProcessId(window, Some(&mut pid));
                let ex = GetWindowLongPtrW(window, GWL_EXSTYLE) as u32;
                if pid == std::process::id()
                    && IsWindowVisible(window).as_bool()
                    && ex & WS_EX_TRANSPARENT.0 != 0
                {
                    found.push(window);
                }
            }
            BOOL(1)
        }
        let mut found: Vec<HWND> = Vec::new();
        // SAFETY: the callback only runs during this call, while `found`
        // lives; the rects outlive their calls.
        unsafe {
            let _ = EnumWindows(Some(visit), LPARAM(&mut found as *mut Vec<HWND> as isize));
            let window = *found.first()?;
            let (mut outer, mut inner) = (RECT::default(), RECT::default());
            GetWindowRect(window, &mut outer).ok()?;
            GetClientRect(window, &mut inner).ok()?;
            let style = GetWindowLongPtrW(window, GWL_STYLE) as u32;
            let frameless = style & WS_POPUP.0 != 0 && style & WS_CAPTION.0 == 0;
            let rect = |r: RECT| {
                Rect::new(
                    r.left as f32,
                    r.top as f32,
                    (r.right - r.left) as f32,
                    (r.bottom - r.top) as f32,
                )
            };
            Some((rect(outer), rect(inner), frameless))
        }
    }

    pub(super) fn origin() -> (f32, f32) {
        // SAFETY: no arguments.
        unsafe {
            (
                GetSystemMetrics(SM_XVIRTUALSCREEN) as f32,
                GetSystemMetrics(SM_YVIRTUALSCREEN) as f32,
            )
        }
    }

    /// The virtual screen through GDI, layered windows included.
    pub(super) fn capture(path: &Path) -> anyhow::Result<()> {
        // SAFETY: every GDI object made here is released before returning.
        unsafe {
            let x = GetSystemMetrics(SM_XVIRTUALSCREEN);
            let y = GetSystemMetrics(SM_YVIRTUALSCREEN);
            let width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            let height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            anyhow::ensure!(width > 0 && height > 0, "no screen to capture");
            let screen = GetDC(None);
            let memory = CreateCompatibleDC(Some(screen));
            let bitmap = CreateCompatibleBitmap(screen, width, height);
            let previous = SelectObject(memory, bitmap.into());
            let copied = BitBlt(
                memory,
                0,
                0,
                width,
                height,
                Some(screen),
                x,
                y,
                SRCCOPY | CAPTUREBLT,
            );
            let mut info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: width,
                    biHeight: -height,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut pixels = vec![0u8; width as usize * height as usize * 4];
            let lines = GetDIBits(
                memory,
                bitmap,
                0,
                height as u32,
                Some(pixels.as_mut_ptr().cast()),
                &mut info,
                DIB_RGB_COLORS,
            );
            SelectObject(memory, previous);
            let _ = DeleteObject(bitmap.into());
            let _ = DeleteDC(memory);
            ReleaseDC(None, screen);
            copied?;
            anyhow::ensure!(lines == height, "GetDIBits read {lines} of {height} lines");
            for pixel in pixels.as_chunks_mut::<4>().0 {
                pixel.swap(0, 2);
                pixel[3] = 255;
            }
            image::save_buffer(
                path,
                &pixels,
                width as u32,
                height as u32,
                image::ColorType::Rgba8,
            )?;
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;

    fn xdotool(args: &[&str]) -> anyhow::Result<()> {
        let status = std::process::Command::new("xdotool").args(args).status()?;
        anyhow::ensure!(status.success(), "xdotool {args:?} failed");
        Ok(())
    }

    pub(super) fn press(which: &Key) -> anyhow::Result<()> {
        let key = match which {
            Key::Tab => "Tab",
            Key::Escape => "Escape",
        };
        xdotool(&["keydown", key])?;
        std::thread::sleep(Duration::from_millis(50));
        xdotool(&["keyup", key])
    }

    pub(super) fn open() -> anyhow::Result<Target> {
        let script = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../lokalbot-platform/scripts/autocomplete-field.py");
        let child = std::process::Command::new("python3")
            .arg(&script)
            .arg("Autocomplete probe")
            .stdout(std::process::Stdio::null())
            .spawn()?;
        println!("FIELD APP pid={}", child.id());
        Ok(Target {
            app_id: "python".into(),
            child,
        })
    }

    pub(super) fn raise(_target: &Target) -> anyhow::Result<()> {
        xdotool(&[
            "search",
            "--sync",
            "--name",
            "^Autocomplete probe$",
            "windowactivate",
            "--sync",
        ])
    }

    pub(super) fn close(mut target: Target) {
        let _ = target.child.kill();
        let _ = target.child.wait();
    }

    pub(super) fn capture(path: &Path) -> anyhow::Result<()> {
        let screen = platform::screen_containing(&Rect::new(1.0, 1.0, 1.0, 1.0))
            .ok_or_else(|| anyhow::anyhow!("no screen"))?;
        let display = std::env::var("DISPLAY").unwrap_or_else(|_| ":0".into());
        let status = std::process::Command::new("ffmpeg")
            .args([
                "-nostdin",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "x11grab",
                "-draw_mouse",
                "0",
            ])
            .args([
                "-video_size",
                &format!("{}x{}", screen.width, screen.height),
            ])
            .args(["-i", &display, "-frames:v", "1"])
            .arg(path)
            .status()?;
        anyhow::ensure!(status.success(), "ffmpeg could not grab the screen");
        Ok(())
    }
}

impl Target {
    fn open() -> anyhow::Result<Self> {
        #[cfg(windows)]
        {
            win::open()
        }
        #[cfg(target_os = "linux")]
        {
            linux::open()
        }
    }

    fn raise(&self) -> anyhow::Result<()> {
        #[cfg(windows)]
        {
            win::raise(self)
        }
        #[cfg(target_os = "linux")]
        {
            linux::raise(self)
        }
    }

    fn close(self) {
        #[cfg(windows)]
        win::close(self);
        #[cfg(target_os = "linux")]
        linux::close(self);
    }
}

fn press(key: Key) -> anyhow::Result<()> {
    #[cfg(windows)]
    {
        win::press(&key)
    }
    #[cfg(target_os = "linux")]
    {
        linux::press(&key)
    }
}

fn capture_screen(path: &Path) -> anyhow::Result<()> {
    #[cfg(windows)]
    {
        win::capture(path)
    }
    #[cfg(target_os = "linux")]
    {
        linux::capture(path)
    }
}

fn screen_origin() -> (f32, f32) {
    #[cfg(windows)]
    {
        win::origin()
    }
    #[cfg(target_os = "linux")]
    {
        (0.0, 0.0)
    }
}
