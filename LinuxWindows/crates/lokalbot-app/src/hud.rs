//! The floating dictation status: a pill at the bottom of the screen while
//! listening, transcribing or composing, then a short notice
//! (`DictationOverlayView.swift`). It never takes focus, so text still lands
//! in the app the user is typing in. On Wayland it is a layer surface, which
//! tiling compositors leave out of their layout.

use std::time::Duration;

use crate::i18n::h_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyWindowHandle, App, AppContext as _, Bounds, Context, Entity, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Pixels, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, WindowBackgroundAppearance,
    WindowBounds, WindowKind, WindowOptions, div, point, px, size,
};

use crate::state::{AppData, DictationHud};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

const PILL: (f32, f32) = (196., 40.);
const STATUS: (f32, f32) = (320., 40.);
const NOTICE: (f32, f32) = (400., 40.);
/// Space between the pill and the bottom of the screen.
const BOTTOM_MARGIN: f32 = 64.;

/// Opens, resizes or closes the overlay to match `AppData.dictation`.
pub fn sync(cx: &mut App) {
    let data = AppData::global(cx);
    let state = data.read(cx).dictation.clone();
    let existing = cx.try_global::<HudWindow>().map(|w| w.0);
    match (state, existing) {
        (DictationHud::Idle, Some(window)) => {
            let _ = window.update(cx, |_, window, _| window.remove_window());
            cx.remove_global::<HudWindow>();
        }
        (DictationHud::Idle, None) => {}
        (_, Some(_)) => {}
        (state, None) => {
            if !data.read(cx).settings.dictation_show_overlay {
                return;
            }
            if let Some(handle) = open(&state, cx) {
                cx.set_global(HudWindow(handle));
            }
        }
    }
}

struct HudWindow(AnyWindowHandle);

impl gpui_kit::Global for HudWindow {}

fn open(state: &DictationHud, cx: &mut App) -> Option<AnyWindowHandle> {
    let (width, height) = dimensions(state);
    let size = size(px(width), px(height));
    // On Wayland the pill is a layer surface on the bottom edge: a tiling
    // compositor would otherwise tile it and give it the keyboard, and the
    // dictated text would land in the pill.
    #[cfg(target_os = "linux")]
    if let Some(kind) = crate::windows::layer_surface(
        "lokalbot-dictation",
        gpui_kit::layer_shell::Anchor::BOTTOM,
        Some((px(0.), px(0.), px(BOTTOM_MARGIN), px(0.))),
        gpui_kit::layer_shell::KeyboardInteractivity::None,
    ) {
        let bounds = Bounds {
            origin: point(px(0.), px(0.)),
            size,
        };
        match cx.open_window(options(bounds, kind), |_, cx| cx.new(Hud::new)) {
            Ok(handle) => return Some(handle.into()),
            Err(err) => log::debug!("dictation pill: no layer shell, opening a window: {err:#}"),
        }
    }
    let visible = cx.primary_display()?.bounds();
    let origin = point(
        visible.origin.x + (visible.size.width - size.width) / 2.,
        visible.origin.y + visible.size.height - size.height - px(BOTTOM_MARGIN),
    );
    cx.open_window(
        options(Bounds { origin, size }, WindowKind::PopUp),
        |_, cx| cx.new(Hud::new),
    )
    .ok()
    .map(Into::into)
}

fn options(bounds: Bounds<Pixels>, kind: WindowKind) -> WindowOptions {
    WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        kind,
        focus: false,
        show: true,
        is_movable: false,
        is_resizable: false,
        window_background: WindowBackgroundAppearance::Transparent,
        app_id: Some(lokalbot_platform::APP_ID.into()),
        ..Default::default()
    }
}

fn dimensions(state: &DictationHud) -> (f32, f32) {
    match state {
        DictationHud::Notice(_) | DictationHud::Failed(_) => NOTICE,
        DictationHud::Transcribing | DictationHud::Composing => STATUS,
        _ => PILL,
    }
}

struct Hud {
    data: Entity<AppData>,
    _subscription: Subscription,
}

impl Hud {
    fn new(cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let subscription = cx.observe(&data, |_, _, cx| cx.notify());
        // Keep the level bars moving even if no new state arrives.
        cx.spawn(async move |this, cx| {
            loop {
                smol::Timer::after(Duration::from_millis(80)).await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        })
        .detach();
        Self {
            data,
            _subscription: subscription,
        }
    }
}

impl Render for Hud {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let state = self.data.read(cx).dictation.clone();
        let data = self.data.clone();
        let (label, level): (Option<SharedString>, f32) = match &state {
            DictationHud::Starting => (
                Some(lokalbot_i18n::tr("Starting the microphone…").into()),
                0.0,
            ),
            DictationHud::Listening { level, .. } => (None, *level),
            DictationHud::Transcribing => (Some(lokalbot_i18n::tr("Transcribing").into()), 0.0),
            DictationHud::Composing => (Some(lokalbot_i18n::tr("Composing").into()), 0.0),
            DictationHud::Notice(text) | DictationHud::Failed(text) => (Some(text.clone()), 0.0),
            DictationHud::Idle => (None, 0.0),
        };
        let listening = matches!(state, DictationHud::Listening { .. });
        let failed = matches!(state, DictationHud::Failed(_));
        let bars = 11;
        h_flex()
            .size_full()
            .px(px(14.))
            .gap(px(10.))
            .items_center()
            .rounded(px(20.))
            .bg(lb.elevated)
            .border_1()
            .border_color(lb.separator)
            .font_family(crate::theme::FONT_FAMILY)
            .child(if listening {
                ui::status_dot(lb.recording, px(9.))
            } else if failed {
                ui::status_dot(lb.attention, px(9.))
            } else {
                ui::status_dot(lb.accent_fill, px(9.))
            })
            .when(listening, |this| {
                this.child(
                    h_flex()
                        .flex_1()
                        .h(px(18.))
                        .gap(px(3.))
                        .items_center()
                        .children((0..bars).map(|i| {
                            // A gentle shape so the middle bars move more than the edges.
                            let center = 1.0
                                - ((i as f32 - (bars as f32 - 1.0) / 2.0).abs()
                                    / (bars as f32 / 2.0));
                            let height =
                                3.0 + 15.0 * (level * (0.45 + 0.55 * center)).clamp(0.0, 1.0);
                            div()
                                .w(px(3.))
                                .h(px(height))
                                .rounded_full()
                                .bg(lb.accent_text)
                        })),
                )
            })
            .when_some(label, |this, label| {
                this.child(
                    div()
                        .flex_1()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(if failed { lb.attention_text } else { lb.text })
                        .child(label),
                )
            })
            .child(
                div()
                    .id("hud-close")
                    .size(px(22.))
                    .flex_none()
                    .rounded_full()
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .hover(|s| s.bg(lb.hover))
                    .child(ui::icon(Ico::X, px(12.), lb.text_secondary))
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| {
                            data.request(crate::state::AppEvent::CancelDictation, cx)
                        })
                    }),
            )
    }
}
