//! Windows besides the main one: Quick Recall, onboarding and the
//! full-size screen image.

pub mod onboarding;
pub mod quick_recall;
pub mod screen_image;

use gpui_kit::{AnyWindowHandle, App, Global, WeakEntity};

/// Handles of the secondary windows, so they are reused instead of stacked.
#[derive(Default)]
struct SecondaryWindows {
    quick_recall: Option<AnyWindowHandle>,
    quick_recall_view: Option<WeakEntity<quick_recall::QuickRecall>>,
    onboarding: Option<AnyWindowHandle>,
    screen_image: Option<AnyWindowHandle>,
}

impl Global for SecondaryWindows {}

fn secondary(cx: &mut App) -> &mut SecondaryWindows {
    cx.default_global::<SecondaryWindows>()
}

/// A Wayland layer surface for a window that floats above the others.
/// Wayland compositors place ordinary windows themselves, and tiling ones
/// (Hyprland, Sway, Omarchy) would put a popup in the layout. `None` outside
/// Wayland. GNOME has no layer shell, so opening one fails there and the
/// caller falls back to an ordinary window.
#[cfg(target_os = "linux")]
pub(crate) fn layer_surface(
    namespace: &str,
    anchor: gpui_kit::layer_shell::Anchor,
    margin: Option<(
        gpui_kit::Pixels,
        gpui_kit::Pixels,
        gpui_kit::Pixels,
        gpui_kit::Pixels,
    )>,
    keyboard: gpui_kit::layer_shell::KeyboardInteractivity,
) -> Option<gpui_kit::WindowKind> {
    use gpui_kit::layer_shell::{Layer, LayerShellOptions};
    lokalbot_platform::session::is_wayland().then(|| {
        gpui_kit::WindowKind::LayerShell(LayerShellOptions {
            namespace: namespace.into(),
            layer: Layer::Overlay,
            anchor,
            exclusive_zone: None,
            exclusive_edge: None,
            margin,
            keyboard_interactivity: keyboard,
        })
    })
}

/// How long [`when_focused`] waits for one of LokalBot's windows to take the
/// keyboard.
#[cfg(target_os = "linux")]
const FOCUS_WAIT: std::time::Duration = std::time::Duration::from_secs(3);

/// Runs `open` once one of LokalBot's windows has the keyboard, so a window
/// opened as `WindowKind::Floating` gets it as its parent: GPUI parents such
/// a window to the focused one. A main window that has only just opened gets
/// the keyboard a moment later. Runs at once when no window is open, and
/// after [`FOCUS_WAIT`] without a parent.
#[cfg(target_os = "linux")]
pub(crate) fn when_focused(cx: &mut App, open: impl FnOnce(&mut App) + 'static) {
    if cx.active_window().is_some() || cx.windows().is_empty() {
        open(cx);
        return;
    }
    cx.spawn(async move |cx| {
        let started = std::time::Instant::now();
        while started.elapsed() < FOCUS_WAIT && cx.update(|cx| cx.active_window().is_none()) {
            smol::Timer::after(std::time::Duration::from_millis(50)).await;
        }
        cx.update(open);
    })
    .detach();
}

/// Brings a still-open window forward; `false` when it was closed.
fn activate(handle: Option<AnyWindowHandle>, cx: &mut App) -> bool {
    handle.is_some_and(|handle| {
        handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    })
}

/// Brings the main window forward (the first window that is not a secondary one).
pub fn activate_main(cx: &mut App) {
    let skip: Vec<_> = {
        let windows = secondary(cx);
        [
            windows.quick_recall,
            windows.onboarding,
            windows.screen_image,
        ]
        .into_iter()
        .flatten()
        .map(|h| h.window_id())
        .collect()
    };
    for handle in cx.windows() {
        if skip.contains(&handle.window_id()) {
            continue;
        }
        if handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
        {
            return;
        }
    }
}
