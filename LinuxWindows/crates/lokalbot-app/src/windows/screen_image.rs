//! A captured screen at full size (`ScreenImageViewer.swift`). The decrypted
//! pixels live only in this window's memory: nothing is exported or written
//! to disk, and closing the window releases them.

use std::sync::Arc;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Icon, Sizable as _, TitleBar, v_flex};
use gpui_kit::{
    AppContext as _, Bounds, Context, FontWeight, InteractiveElement as _, IntoElement, ObjectFit,
    ParentElement as _, Render, RenderImage, SharedString, Styled as _, StyledImage as _, Window,
    WindowBounds, WindowKind, WindowOptions, div, img, px, size,
};
use lokalbot_core::{Library, ScreenMoment};

use crate::state::AppData;
use crate::theme::{FONT_FAMILY, LbThemeExt as _, ty};
use crate::ui::{self, Ico};

/// What a moment's image file gave.
#[derive(Clone)]
pub enum ScreenImage {
    Ready(Arc<RenderImage>),
    /// Why there is no image, for the placeholder.
    Unavailable(&'static str),
}

pub const MISSING: &str =
    "Pixels may have expired or could not be read. Retained text remains in the moment inspector.";
pub const OTHER_KEY: &str = "This image was captured on another computer or by another LokalBot install, so the key that opens it is not on this PC. Its text is still here.";

/// Decrypts and decodes a moment's image, at most `max` pixels on its
/// longest side (0 keeps the full size). Runs off the UI thread.
pub fn load(library: &Library, moment: &ScreenMoment, max: u32) -> ScreenImage {
    let Some(path) = library.screen_image_file(&moment.path) else {
        return ScreenImage::Unavailable(MISSING);
    };
    let Ok(key) = lokalbot_engine::secrets::screen_image_key(false) else {
        return ScreenImage::Unavailable(OTHER_KEY);
    };
    let bytes = match lokalbot_core::screen::read_image(&key, &path) {
        Ok(bytes) => bytes,
        Err(lokalbot_core::screen::ImageError::OtherKey) => {
            return ScreenImage::Unavailable(OTHER_KEY);
        }
        Err(err) => {
            log::debug!("screen image {}: {err}", moment.id);
            return ScreenImage::Unavailable(MISSING);
        }
    };
    let Ok(decoded) = image::load_from_memory(&bytes) else {
        return ScreenImage::Unavailable(MISSING);
    };
    let decoded = if max > 0 && (decoded.width() > max || decoded.height() > max) {
        decoded.thumbnail(max, max)
    } else {
        decoded
    };
    let mut rgba = decoded.into_rgba8();
    // GPUI draws BGRA.
    for pixel in rgba.as_chunks_mut::<4>().0 {
        pixel.swap(0, 2);
    }
    ScreenImage::Ready(Arc::new(RenderImage::new(vec![image::Frame::new(rgba)])))
}

/// Opens the viewer for `moment`, replacing an earlier one.
pub fn open(moment: ScreenMoment, cx: &mut gpui_kit::App) {
    if let Some(handle) = super::secondary(cx).screen_image.take() {
        let _ = handle.update(cx, |_, window, _| window.remove_window());
    }
    let bounds = Bounds::centered(None, size(px(960.), px(680.)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(720.), px(500.))),
        kind: WindowKind::Normal,
        app_id: Some("com.lokalbot.LokalBot".into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..TitleBar::window_options()
    };
    let title = viewer_title(&moment);
    match gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title(&title);
        cx.new(|cx| ScreenImageViewer::new(moment, cx))
    }) {
        Ok((handle, _)) => super::secondary(cx).screen_image = Some(handle),
        Err(err) => log::error!("could not open the screen image: {err:#}"),
    }
}

fn viewer_title(moment: &ScreenMoment) -> String {
    if moment.window_title.trim().is_empty() {
        moment.app.clone()
    } else {
        moment.window_title.clone()
    }
}

pub struct ScreenImageViewer {
    moment: ScreenMoment,
    image: Option<ScreenImage>,
    fit: bool,
    zoom: f32,
}

impl ScreenImageViewer {
    fn new(moment: ScreenMoment, cx: &mut Context<Self>) -> Self {
        let library = AppData::global(cx).read(cx).library.clone();
        let loading = moment.clone();
        cx.spawn(async move |this, cx| {
            let image = cx
                .background_spawn(async move { load(&library, &loading, 0) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.image = Some(image);
                cx.notify();
            });
        })
        .detach();
        Self {
            moment,
            image: None,
            fit: true,
            zoom: 1.0,
        }
    }

    fn set_zoom(&mut self, zoom: f32, cx: &mut Context<Self>) {
        self.fit = false;
        self.zoom = zoom.clamp(0.25, 3.0);
        cx.notify();
    }

    fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(ScreenImage::Ready(image)) = self.image.take() {
            cx.drop_image(image, Some(window));
        }
        window.remove_window();
    }
}

impl Render for ScreenImageViewer {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let title: SharedString = viewer_title(&self.moment).into();
        let zoom = self.zoom;
        let toolbar = h_flex()
            .gap(px(8.))
            .items_center()
            .px(px(12.))
            .py(px(10.))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(ty::BODY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(title),
            )
            .child(
                Button::new("screen-image-fit")
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Fit"))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.fit = true;
                        cx.notify();
                    })),
            )
            .child(
                Button::new("screen-image-actual")
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Actual size"))
                    .on_click(cx.listener(|this, _, _, cx| this.set_zoom(1.0, cx))),
            )
            .child(
                Button::new("screen-image-zoom-out")
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::ZoomOut))
                    .tooltip(lokalbot_i18n::tr("Zoom out"))
                    .on_click(cx.listener(move |this, _, _, cx| this.set_zoom(zoom / 1.25, cx))),
            )
            .child(
                Button::new("screen-image-zoom-in")
                    .ghost()
                    .small()
                    .icon(Icon::new(Ico::ZoomIn))
                    .tooltip(lokalbot_i18n::tr("Zoom in"))
                    .on_click(cx.listener(move |this, _, _, cx| this.set_zoom(zoom * 1.25, cx))),
            )
            .child(
                Button::new("screen-image-done")
                    .primary()
                    .small()
                    .label(lokalbot_i18n::tr("Done"))
                    .on_click(cx.listener(|this, _, window, cx| this.close(window, cx))),
            );
        let body = match &self.image {
            None => v_flex()
                .size_full()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .child(Spinner::new())
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Opening image…",
                        ))),
                )
                .into_any_element(),
            Some(ScreenImage::Unavailable(reason)) => v_flex()
                .size_full()
                .items_center()
                .justify_center()
                .gap(px(10.))
                .px(px(40.))
                .child(ui::icon(Ico::ImageOff, px(28.), lb.text_secondary))
                .child(
                    div()
                        .text_size(ty::SECTION)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Image unavailable",
                        ))),
                )
                .child(
                    div()
                        .max_w(px(460.))
                        .text_center()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(reason))),
                )
                .into_any_element(),
            Some(ScreenImage::Ready(image)) if self.fit => div()
                .size_full()
                .p(px(8.))
                .child(
                    img(image.clone())
                        .size_full()
                        .object_fit(ObjectFit::Contain),
                )
                .into_any_element(),
            Some(ScreenImage::Ready(image)) => {
                let pixels = image.size(0);
                let (width, height) = (
                    i32::from(pixels.width) as f32 * self.zoom,
                    i32::from(pixels.height) as f32 * self.zoom,
                );
                div()
                    .id("screen-image-scroll")
                    .size_full()
                    .overflow_scrollbar()
                    .child(img(image.clone()).w(px(width)).h(px(height)))
                    .into_any_element()
            }
        };
        v_flex()
            .size_full()
            .font_family(FONT_FAMILY)
            .bg(lb.window)
            .text_color(lb.text)
            .child(
                TitleBar::new()
                    .bg(lb.title_bar)
                    .border_color(lb.separator)
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .justify_center()
                            .text_size(ty::SECONDARY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Captured screen",
                            ))),
                    ),
            )
            .child(toolbar)
            .child(div().h(px(1.)).bg(lb.separator))
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .bg(gpui_kit::black().opacity(0.82))
                    .child(body),
            )
    }
}
