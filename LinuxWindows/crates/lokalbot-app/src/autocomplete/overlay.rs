use gpui_kit::component::h_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Bounds, Context, Hsla, IntoElement, ParentElement as _, Render,
    SharedString, Styled as _, Window, WindowBackgroundAppearance, WindowBounds, WindowHandle,
    WindowKind, WindowOptions, div, point, px, size,
};
use lokalbot_platform::autocomplete::{self as platform, NativeWindow, Rect};

#[derive(Clone, Debug, PartialEq)]
pub struct GhostLine {
    pub text: String,
    pub offset: usize,
    pub x: f32,
    pub y: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Chrome {
    pub background: Hsla,
    pub border: Hsla,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GhostContent {
    pub lines: Vec<GhostLine>,
    pub font_family: SharedString,
    pub font_size: f32,
    pub line_height: f32,
    pub color: Hsla,
    pub emphasis_color: Hsla,
    pub emphasis_chars: usize,
    pub chrome: Option<Chrome>,
}

pub struct Overlay {
    window: Option<WindowHandle<GhostView>>,
    native: Option<NativeWindow>,
    visible: bool,
    exclude_from_capture: bool,
    scale: f32,
    #[cfg(windows)]
    latest_move: std::rc::Rc<std::cell::Cell<u64>>,
    #[cfg(windows)]
    prepared: bool,
}

impl Overlay {
    pub fn new(exclude_from_capture: bool) -> Self {
        Self {
            window: None,
            native: None,
            visible: false,
            exclude_from_capture,
            scale: 1.0,
            #[cfg(windows)]
            latest_move: Default::default(),
            #[cfg(windows)]
            prepared: false,
        }
    }

    pub fn is_visible(&self) -> bool {
        self.visible
    }

    pub fn scale(&self) -> f32 {
        self.scale
    }

    pub fn show(&mut self, frame: Rect, content: GhostContent, cx: &mut App) -> f32 {
        let frame = frame.integral();
        if self.window.is_none() {
            self.open(frame, content.clone(), cx);
        } else if let Some(window) = self.window {
            let updated = window.update(cx, |view, window, cx| {
                #[cfg(not(windows))]
                if view.content != content {
                    view.content = content.clone();
                    cx.notify();
                }
                #[cfg(windows)]
                let _ = (view, cx);
                window.scale_factor()
            });
            match updated {
                Ok(scale) => self.scale = scale,
                Err(_) => {
                    self.window = None;
                    self.native = None;
                    self.open(frame, content.clone(), cx);
                }
            }
        }
        self.move_native(Some((frame, content)), cx);
        self.visible = true;
        if let Some(scale) = platform::scale_at(&frame) {
            self.scale = scale;
        }
        self.scale
    }

    pub fn hide(&mut self, cx: &mut App) {
        if !self.visible {
            return;
        }
        self.visible = false;
        self.move_native(None, cx);
    }

    pub fn close(&mut self, cx: &mut App) {
        self.visible = false;
        self.native = None;
        #[cfg(windows)]
        {
            self.latest_move.set(self.latest_move.get() + 1);
            self.prepared = false;
        }
        if let Some(window) = self.window.take() {
            let _ = window.update(cx, |_, window, _| window.remove_window());
        }
    }

    fn move_native(&mut self, target: Option<(Rect, GhostContent)>, cx: &mut App) {
        let Some(native) = self.native else {
            return;
        };
        #[cfg(windows)]
        {
            let window = self.window;
            let prepare = (!self.prepared).then_some(self.exclude_from_capture);
            self.prepared = true;
            let id = self.latest_move.get() + 1;
            self.latest_move.set(id);
            let latest = self.latest_move.clone();
            cx.spawn(async move |cx| {
                if let Some(exclude) = prepare
                    && let Err(err) = platform::prepare_overlay(native, exclude)
                {
                    log::debug!("autocomplete: preparing the ghost window failed: {err:#}");
                }
                if latest.get() != id {
                    return;
                }
                let frame = target.as_ref().map(|(frame, _)| *frame);
                if let Err(err) = platform::place_overlay(native, frame) {
                    log::debug!("autocomplete: placing the ghost failed: {err:#}");
                    return;
                }
                if let (Some((_, content)), Some(window)) = (target, window)
                    && latest.get() == id
                {
                    cx.update(|cx| {
                        let _ = window.update(cx, |view, window, cx| {
                            view.content = content;
                            window.refresh();
                            cx.notify();
                        });
                    });
                }
            })
            .detach();
        }
        #[cfg(not(windows))]
        {
            let _ = cx;
            let frame = target.map(|(frame, _)| frame);
            if let Err(err) = platform::place_overlay(native, frame) {
                log::debug!("autocomplete: placing the ghost failed: {err:#}");
            }
        }
    }

    fn open(&mut self, frame: Rect, content: GhostContent, cx: &mut App) {
        let scale = self.scale.max(0.5);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds {
                origin: point(px(frame.x / scale), px(frame.y / scale)),
                size: size(
                    px((frame.width / scale).max(1.0)),
                    px((frame.height / scale).max(1.0)),
                ),
            })),
            titlebar: None,
            kind: WindowKind::PopUp,
            focus: false,
            show: !cfg!(windows),
            is_movable: false,
            is_resizable: false,
            is_minimizable: false,
            window_background: WindowBackgroundAppearance::Transparent,
            app_id: Some(lokalbot_platform::APP_ID.into()),
            ..Default::default()
        };
        let mut native = None;
        let mut window_scale = scale;
        let opened = cx.open_window(options, |window, cx| {
            native = native_window(window);
            window_scale = window.scale_factor();
            cx.new(|_| GhostView { content })
        });
        match opened {
            Ok(handle) => {
                self.window = Some(handle);
                self.scale = window_scale;
                self.native = native;
                #[cfg(windows)]
                {
                    self.prepared = false;
                }
                #[cfg(not(windows))]
                if let Some(native) = native
                    && let Err(err) = platform::prepare_overlay(native, self.exclude_from_capture)
                {
                    log::debug!("autocomplete: preparing the ghost window failed: {err:#}");
                }
            }
            Err(err) => log::warn!("autocomplete: could not open the ghost window: {err:#}"),
        }
    }
}

fn native_window(window: &Window) -> Option<NativeWindow> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let handle = HasWindowHandle::window_handle(window).ok()?;
    match handle.as_raw() {
        #[cfg(target_os = "linux")]
        RawWindowHandle::Xcb(handle) => Some(NativeWindow::X11(handle.window.get())),
        #[cfg(target_os = "linux")]
        RawWindowHandle::Xlib(handle) => u32::try_from(handle.window).ok().map(NativeWindow::X11),
        #[cfg(windows)]
        RawWindowHandle::Win32(handle) => Some(NativeWindow::Win32(handle.hwnd.get())),
        _ => None,
    }
}

pub struct GhostView {
    content: GhostContent,
}

impl Render for GhostView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let content = &self.content;
        let lines = content.lines.iter().map(|line| {
            let emphasized = content
                .emphasis_chars
                .saturating_sub(line.offset)
                .min(line.text.chars().count());
            let split = line
                .text
                .char_indices()
                .nth(emphasized)
                .map_or(line.text.len(), |(index, _)| index);
            let (strong, rest) = line.text.split_at(split);
            let visible = |text: &str| SharedString::from(text.replace(' ', "\u{a0}"));
            h_flex()
                .absolute()
                .left(px(line.x))
                .top(px(line.y))
                .h(px(content.line_height))
                .items_center()
                .whitespace_nowrap()
                .when(!strong.is_empty(), |this| {
                    this.child(
                        div()
                            .text_color(content.emphasis_color)
                            .child(visible(strong)),
                    )
                })
                .when(!rest.is_empty(), |this| {
                    this.child(div().text_color(content.color).child(visible(rest)))
                })
        });
        div()
            .size_full()
            .relative()
            .font_family(content.font_family.clone())
            .text_size(px(content.font_size))
            .line_height(px(content.line_height))
            .when_some(content.chrome, |this, chrome| {
                this.bg(chrome.background)
                    .border_1()
                    .border_color(chrome.border)
                    .rounded(px(7.))
            })
            .children(lines)
    }
}
