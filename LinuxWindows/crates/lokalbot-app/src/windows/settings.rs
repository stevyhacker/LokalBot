//! Settings in its own window, as on the Mac (`Window("Settings", id:
//! "settings")`): Ctrl+, the sidebar's Settings row, the tray, the command
//! palette, links from pages, notifications and `lokalbot-cli open settings`
//! open it or bring it forward, so the main window stays on your work. There
//! is one at a time. It opens on `AppData::settings_category`; everything
//! reaches it through `AppData::open_settings`.

use gpui_kit::component::{TitleBar, v_flex};
use gpui_kit::{
    App, AppContext as _, Bounds, Context, Entity, IntoElement, ParentElement as _, Render, Size,
    Styled as _, Window, WindowBounds, WindowKind, WindowOptions, div, px, size,
};

use crate::pages::settings::SettingsPage;
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, UiFont as _, metric};

/// `SettingsView.defaultSize` and its minimum.
const WIDTH: f32 = 1020.;
const HEIGHT: f32 = 816.;
const MIN_WIDTH: f32 = 780.;
const MIN_HEIGHT: f32 = 520.;

/// Opens the Settings window, or brings it forward. Call
/// `AppData::open_settings` instead, which also picks the page.
pub fn open(cx: &mut App) {
    let existing = super::secondary(cx).settings;
    if super::activate(existing, cx) {
        return;
    }
    let mut window_size = size(px(WIDTH), px(HEIGHT));
    if let Some(display) = cx.primary_display() {
        let display_size = display.bounds().size;
        window_size.width = window_size.width.min(display_size.width * 0.92);
        window_size.height = window_size.height.min(display_size.height * 0.92);
    }
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
            None,
            window_size,
            cx,
        ))),
        window_min_size: Some(Size {
            width: px(MIN_WIDTH),
            height: px(MIN_HEIGHT),
        }),
        kind: WindowKind::Normal,
        app_id: Some(lokalbot_platform::APP_ID.into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..TitleBar::window_options()
    };
    let data = AppData::global(cx);
    let result = gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title(lokalbot_i18n::tr("Settings"));
        crate::apply_appearance(&data, window, cx);
        let observed = data.clone();
        window
            .observe_window_appearance(move |window, cx| {
                crate::apply_appearance(&observed, window, cx)
            })
            .detach();
        let subscribed = data.clone();
        window
            .subscribe(&data, cx, move |_, event: &AppEvent, window, cx| {
                if matches!(event, AppEvent::AppearanceChanged) {
                    crate::apply_appearance(&subscribed, window, cx);
                }
            })
            .detach();
        cx.new(|cx| SettingsWindow::new(window, cx))
    });
    match result {
        Ok((handle, _)) => {
            super::secondary(cx).settings = Some(handle);
            data.update(cx, |data, cx| {
                data.settings_window_open = true;
                cx.notify();
            });
        }
        Err(err) => log::error!("could not open the Settings window: {err:#}"),
    }
}

/// Runs `action` on the Settings window, opening it first when it is closed:
/// for a question that belongs beside a Settings page, such as a phone
/// asking to pair.
pub fn with_window(cx: &mut App, action: impl FnOnce(&mut Window, &mut App)) {
    open(cx);
    if let Some(handle) = super::secondary(cx).settings {
        let _ = handle.update(cx, |_, window, cx| action(window, cx));
    }
}

/// Runs `action` on the Settings window if it is open.
pub fn if_open(cx: &mut App, action: impl FnOnce(&mut Window, &mut App)) {
    if let Some(handle) = super::secondary(cx).settings {
        let _ = handle.update(cx, |_, window, cx| action(window, cx));
    }
}

/// The window's root: a title bar over the Settings page.
pub struct SettingsWindow {
    data: Entity<AppData>,
    page: Entity<SettingsPage>,
}

impl SettingsWindow {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        // Closing the window, by its button or the window manager, ends it.
        let closed = data.clone();
        cx.on_release(move |_, cx| {
            super::secondary(cx).settings = None;
            closed.update(cx, |data, cx| {
                data.settings_window_open = false;
                cx.notify();
            });
        })
        .detach();
        cx.observe(&data, |_, _, cx| cx.notify()).detach();
        Self {
            page: cx.new(|cx| SettingsPage::new(window, cx)),
            data,
        }
    }
}

impl Render for SettingsWindow {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let toast = crate::shell::toast(&self.data, cx);
        // The bar holds the window's controls and moves it. Like the Mac's
        // hidden title bar it has no words: the category list under it says
        // "Settings", and the window manager still gets the title.
        v_flex()
            .size_full()
            .bg(lb.window)
            .text_color(lb.text)
            .ui_font()
            .child(
                TitleBar::new()
                    .h(metric::TOOLBAR_HEIGHT)
                    .bg(lb.title_bar)
                    .border_color(lb.separator),
            )
            .child(div().flex_1().min_h_0().relative().child(self.page.clone()))
            .children(toast)
    }
}
