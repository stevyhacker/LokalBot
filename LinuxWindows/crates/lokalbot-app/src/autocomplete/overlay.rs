//! The ghost window (`CotypingOverlayController.swift`, `CotypingGhostView.swift`):
//! one transparent, focus-less pop-up that is moved to the caret, sized to
//! the suggestion, and hidden rather than closed between suggestions. It
//! never takes focus or clicks, so the app being typed in keeps the keyboard.
//!
//! Inline, it draws the suggestion in the field's font right after the
//! caret, the part the next Tab takes a little stronger; as a pill it draws
//! it under the caret's line with its own background.
//!
//! Kept free of the rest of the app so `examples/autocomplete_probe.rs` can
//! show the same window.

use gpui_kit::component::h_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Bounds, Context, Hsla, IntoElement, ParentElement as _, Render,
    SharedString, Styled as _, Window, WindowBackgroundAppearance, WindowBounds, WindowHandle,
    WindowKind, WindowOptions, div, point, px, size,
};
use lokalbot_platform::autocomplete::{self as platform, NativeWindow, Rect};

/// One line of ghost text, positioned in the window (logical pixels).
#[derive(Clone, Debug, PartialEq)]
pub struct GhostLine {
    pub text: String,
    /// Where `text` starts in the suggestion, in characters.
    pub offset: usize,
    pub x: f32,
    pub y: f32,
}

/// The pill's own background and border.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Chrome {
    pub background: Hsla,
    pub border: Hsla,
}

/// What the ghost window shows.
#[derive(Clone, Debug, PartialEq)]
pub struct GhostContent {
    pub lines: Vec<GhostLine>,
    pub font_family: SharedString,
    /// Logical pixels.
    pub font_size: f32,
    pub line_height: f32,
    pub color: Hsla,
    pub emphasis_color: Hsla,
    /// Characters from the start the next Tab takes.
    pub emphasis_chars: usize,
    pub chrome: Option<Chrome>,
}

/// The ghost window, created on first use.
pub struct Overlay {
    window: Option<WindowHandle<GhostView>>,
    native: Option<NativeWindow>,
    visible: bool,
    exclude_from_capture: bool,
    /// The scale factor GPUI reported for the window last time.
    scale: f32,
    /// Windows: the newest native move asked for; an older one still
    /// waiting is skipped (see [`Overlay::move_native`]).
    #[cfg(windows)]
    latest_move: std::rc::Rc<std::cell::Cell<u64>>,
    /// Windows: the window has been given its styles.
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

    /// Device pixels per logical pixel where the window last was.
    pub fn scale(&self) -> f32 {
        self.scale
    }

    /// Shows `content` in `frame` (screen pixels). Returns the window's
    /// scale factor afterwards, which may differ on another monitor; the
    /// caller then lays the suggestion out again.
    pub fn show(&mut self, frame: Rect, content: GhostContent, cx: &mut App) -> f32 {
        let frame = frame.integral();
        if self.window.is_none() {
            self.open(frame, content.clone(), cx);
        } else if let Some(window) = self.window {
            let updated = window.update(cx, |view, window, cx| {
                if view.content != content {
                    view.content = content.clone();
                    cx.notify();
                }
                window.scale_factor()
            });
            match updated {
                Ok(scale) => self.scale = scale,
                Err(_) => {
                    // Closed underneath us (display change): open again.
                    self.window = None;
                    self.native = None;
                    self.open(frame, content, cx);
                }
            }
        }
        self.move_native(Some(frame), cx);
        self.visible = true;
        // Windows keeps a scale per monitor: the one the ghost moves to.
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

    /// Closes the window, when autocomplete stops.
    pub fn close(&mut self, cx: &mut App) {
        self.visible = false;
        self.native = None;
        #[cfg(windows)]
        {
            // A move still waiting must not touch the closing window.
            self.latest_move.set(self.latest_move.get() + 1);
            self.prepared = false;
        }
        if let Some(window) = self.window.take() {
            let _ = window.update(cx, |_, window, _| window.remove_window());
        }
    }

    /// Moves and sizes the native window to `frame` and shows it, or hides
    /// it with `None`.
    ///
    /// Windows answers `SetWindowPos` and style changes with messages GPUI
    /// handles on the spot, and those handlers need the app, which is busy
    /// with the update that called this: GPUI logged "RefCell already
    /// borrowed" and missed the window's new size, so the ghost kept drawing
    /// at its old size. There the native calls wait for the next turn of the
    /// event loop, and only the newest one runs. X11 requests go out on a
    /// connection of their own and GPUI reads the results later, so they are
    /// made at once.
    fn move_native(&mut self, frame: Option<Rect>, cx: &mut App) {
        let Some(native) = self.native else {
            return;
        };
        #[cfg(windows)]
        {
            let prepare = (!self.prepared).then_some(self.exclude_from_capture);
            self.prepared = true;
            let id = self.latest_move.get() + 1;
            self.latest_move.set(id);
            let latest = self.latest_move.clone();
            cx.spawn(async move |_| {
                if let Some(exclude) = prepare
                    && let Err(err) = platform::prepare_overlay(native, exclude)
                {
                    log::debug!("autocomplete: preparing the ghost window failed: {err:#}");
                }
                if latest.get() == id
                    && let Err(err) = platform::place_overlay(native, frame)
                {
                    log::debug!("autocomplete: placing the ghost failed: {err:#}");
                }
            })
            .detach();
        }
        #[cfg(not(windows))]
        {
            let _ = cx;
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
            // On Windows the first move shows it, once it has lost the frame
            // Windows gives it (see `move_native`).
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
                // Windows prepares it with its first move.
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
            // A text run's leading space is not drawn; the ghost's first
            // space separates it from the word at the caret.
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
