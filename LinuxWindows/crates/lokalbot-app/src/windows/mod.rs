pub mod agent_setup;
pub mod onboarding;
pub mod quick_recall;
pub mod screen_image;
pub mod selection_actions;
pub mod settings;
pub mod settings_approval;

use gpui_kit::{AnyWindowHandle, App, Global, WeakEntity};

#[derive(Default)]
struct SecondaryWindows {
    quick_recall: Option<AnyWindowHandle>,
    quick_recall_view: Option<WeakEntity<quick_recall::QuickRecall>>,
    selection_actions: Option<AnyWindowHandle>,
    selection_actions_view: Option<WeakEntity<selection_actions::SelectionActions>>,
    onboarding: Option<AnyWindowHandle>,
    screen_image: Option<AnyWindowHandle>,
    settings: Option<AnyWindowHandle>,
    settings_approval: Option<AnyWindowHandle>,
    agent_setup: Option<AnyWindowHandle>,
}

impl Global for SecondaryWindows {}

fn secondary(cx: &mut App) -> &mut SecondaryWindows {
    cx.default_global::<SecondaryWindows>()
}

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

#[cfg(target_os = "linux")]
const FOCUS_WAIT: std::time::Duration = std::time::Duration::from_secs(3);

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

fn activate(handle: Option<AnyWindowHandle>, cx: &mut App) -> bool {
    handle.is_some_and(|handle| {
        handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    })
}

pub fn close_onboarding(cx: &mut App) {
    if let Some(handle) = secondary(cx).onboarding.take() {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
}

pub fn activate_main(cx: &mut App) {
    crate::desktop::show_main_window(cx);
}
