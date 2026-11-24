use std::fs::File;
use std::io::Write as _;
use std::os::fd::{AsFd as _, FromRawFd as _, OwnedFd};

use cosmic_text::{
    Attrs, Buffer, Color, Family, FontSystem, Metrics, Shaping, SwashCache, SwashContent, Wrap,
};
use wayland_client::globals::GlobalList;
use wayland_client::protocol::{
    wl_buffer, wl_compositor, wl_region, wl_shm, wl_shm_pool, wl_surface,
};
use wayland_client::{Proxy as _, QueueHandle};
use wayland_protocols::wp::fractional_scale::v1::client::{
    wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1,
    wp_fractional_scale_v1::WpFractionalScaleV1,
};
use wayland_protocols::wp::input_method::zv1::client::{
    zwp_input_panel_surface_v1::ZwpInputPanelSurfaceV1, zwp_input_panel_v1::ZwpInputPanelV1,
};
use wayland_protocols::wp::viewporter::client::{
    wp_viewport::WpViewport, wp_viewporter::WpViewporter,
};
use wayland_protocols_misc::zwp_input_method_v2::client::{
    zwp_input_method_v2::ZwpInputMethodV2, zwp_input_popup_surface_v2::ZwpInputPopupSurfaceV2,
};

const FONT_PX: f32 = 14.0;
const LINE_HEIGHT_PX: f32 = 19.0;
const PAD_X: f32 = 8.0;
const PAD_Y: f32 = 4.0;
const CORNER_RADIUS: f32 = 7.0;
const MAX_TEXT_WIDTH: f32 = 420.0;
const MAX_LINES: usize = 2;
const MAX_CHARS: usize = 160;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Shown {
    text: String,
    emphasis_chars: usize,
    dark: bool,
}

pub(super) struct RenderedPill {
    pub pixels: Vec<u32>,
    pub phys_width: i32,
    pub phys_height: i32,
    pub logical_width: i32,
    pub logical_height: i32,
}

pub(super) struct Painter {
    font_system: FontSystem,
    swash_cache: SwashCache,
}

impl Painter {
    pub(super) fn new() -> Self {
        Self {
            font_system: FontSystem::new(),
            swash_cache: SwashCache::new(),
        }
    }
}

fn normalize_pill_text(text: &str, emphasis_chars: usize) -> Option<(String, usize)> {
    let leading = text.chars().take_while(|c| c.is_whitespace()).count();
    let trimmed = text.trim_start();
    if trimmed.is_empty() {
        return None;
    }
    let mut display = String::new();
    let mut count = 0usize;
    let mut prev_space = false;
    for ch in trimmed.chars() {
        if count >= MAX_CHARS {
            display.push('…');
            break;
        }
        if ch == '\n' || ch == '\r' || ch == '\t' {
            if !prev_space {
                display.push(' ');
                prev_space = true;
                count += 1;
            }
        } else {
            prev_space = ch == ' ';
            display.push(ch);
            count += 1;
        }
    }
    let adjusted = if emphasis_chars > 0 {
        emphasis_chars.saturating_sub(leading)
    } else {
        let first_word = display.chars().take_while(|c| !c.is_whitespace()).count();
        first_word.max(1)
    };
    Some((display, adjusted))
}

#[inline]
fn sd_rounded_box(px: f32, py: f32, bx: f32, by: f32, r: f32) -> f32 {
    let qx = px.abs() - bx + r;
    let qy = py.abs() - by + r;
    let outside = (qx.max(0.0).hypot(qy.max(0.0))) - r;
    let inside = qx.max(qy).min(0.0);
    outside + inside
}

#[inline]
fn blend_over(dst: u32, sr: u8, sg: u8, sb: u8, sa: u8) -> u32 {
    if sa == 0 {
        return dst;
    }
    let sa32 = u32::from(sa);
    let sp_r = (u32::from(sr) * sa32 + 127) / 255;
    let sp_g = (u32::from(sg) * sa32 + 127) / 255;
    let sp_b = (u32::from(sb) * sa32 + 127) / 255;
    if sa == 255 || dst == 0 {
        return (sa32 << 24) | (sp_r << 16) | (sp_g << 8) | sp_b;
    }
    let da = (dst >> 24) & 0xFF;
    let dr = (dst >> 16) & 0xFF;
    let dg = (dst >> 8) & 0xFF;
    let db = dst & 0xFF;
    let inv = 255 - sa32;
    let oa = sa32 + (da * inv + 127) / 255;
    let or = (sp_r + (dr * inv + 127) / 255).min(255);
    let og = (sp_g + (dg * inv + 127) / 255).min(255);
    let ob = (sp_b + (db * inv + 127) / 255).min(255);
    (oa << 24) | (or << 16) | (og << 8) | ob
}

pub(super) fn render_pill_pixels(
    painter: &mut Painter,
    text: &str,
    emphasis_chars: usize,
    dark: bool,
    scale: f32,
) -> Option<RenderedPill> {
    let (display, emphasis) = normalize_pill_text(text, emphasis_chars)?;
    let scale = scale.clamp(0.5, 4.0);

    let (bg, border, strong_c, rest_c) = if dark {
        (
            (0x2A, 0x2A, 0x2C, 246u8),
            (0xFF, 0xFF, 0xFF, 38u8),
            Color::rgba(0xFF, 0xFF, 0xFF, 0xE0),
            Color::rgba(0xFF, 0xFF, 0xFF, 0x8C),
        )
    } else {
        (
            (0xFF, 0xFF, 0xFF, 246u8),
            (0x00, 0x00, 0x00, 32u8),
            Color::rgba(0x1D, 0x1D, 0x1F, 0xFF),
            Color::rgba(0x00, 0x00, 0x00, 0x8C),
        )
    };

    let split = display
        .char_indices()
        .nth(emphasis)
        .map_or(display.len(), |(idx, _)| idx);
    let (strong, rest) = display.split_at(split);

    let font_px = FONT_PX * scale;
    let line_h = (LINE_HEIGHT_PX * scale).ceil();
    let max_w = MAX_TEXT_WIDTH * scale;

    let mut buffer = Buffer::new_empty(Metrics::new(font_px, line_h));
    buffer.set_wrap(Wrap::WordOrGlyph);
    buffer.set_size(Some(max_w), None);

    let base_attrs = Attrs::new().family(Family::SansSerif);
    let mut spans = Vec::with_capacity(2);
    if !strong.is_empty() {
        spans.push((strong, base_attrs.clone().color(strong_c)));
    }
    if !rest.is_empty() {
        spans.push((rest, base_attrs.clone().color(rest_c)));
    }
    buffer.set_rich_text(spans, &base_attrs, Shaping::Advanced, None);
    buffer.shape_until_scroll(&mut painter.font_system, false);

    let mut widest = 0.0f32;
    let mut line_count = 0usize;
    for run in buffer.layout_runs().take(MAX_LINES) {
        widest = widest.max(run.line_w);
        line_count += 1;
    }
    if line_count == 0 || widest <= 0.0 {
        return None;
    }

    let logical_w = ((widest / scale).ceil() + PAD_X * 2.0 + 2.0)
        .ceil()
        .max(16.0) as i32;
    let logical_h = (((line_count as f32 * line_h) / scale).ceil() + PAD_Y * 2.0)
        .ceil()
        .max(16.0) as i32;
    let phys_w = ((logical_w as f32) * scale).round().max(1.0) as i32;
    let phys_h = ((logical_h as f32) * scale).round().max(1.0) as i32;

    let mut pixels = vec![0u32; (phys_w * phys_h) as usize];

    let half_w = phys_w as f32 * 0.5;
    let half_h = phys_h as f32 * 0.5;
    let radius = (CORNER_RADIUS * scale).min(half_w.min(half_h));
    let border_px = scale.max(1.0);
    for y in 0..phys_h {
        let py = (y as f32 + 0.5) - half_h;
        let row = (y * phys_w) as usize;
        for x in 0..phys_w {
            let px = (x as f32 + 0.5) - half_w;
            let dist = sd_rounded_box(px, py, half_w - 0.5, half_h - 0.5, radius);
            let outer_cov = (0.5 - dist).clamp(0.0, 1.0);
            if outer_cov <= 0.0 {
                continue;
            }
            let inner_cov = (0.5 - (dist + border_px)).clamp(0.0, 1.0);
            let bg_a = (f32::from(bg.3) * inner_cov).round() as u8;
            let mut out = blend_over(0, bg.0, bg.1, bg.2, bg_a);
            let border_ring = (outer_cov - inner_cov).clamp(0.0, 1.0);
            if border_ring > 0.0 {
                let ba = (f32::from(border.3) * border_ring).round() as u8;
                out = blend_over(out, border.0, border.1, border.2, ba);
            }
            pixels[row + x as usize] = out;
        }
    }

    let text_origin_x = (PAD_X * scale).round();
    let text_origin_y = (PAD_Y * scale).round();
    for run in buffer.layout_runs().take(MAX_LINES) {
        for glyph in run.glyphs {
            let physical = glyph.physical((text_origin_x, text_origin_y + run.line_y), 1.0);
            let color = glyph.color_opt.unwrap_or(rest_c);
            let Some(image) = painter
                .swash_cache
                .get_image(&mut painter.font_system, physical.cache_key)
            else {
                continue;
            };
            let gx = physical.x + image.placement.left;
            let gy = physical.y - image.placement.top;
            let gw = image.placement.width as i32;
            let gh = image.placement.height as i32;
            match image.content {
                SwashContent::Mask => {
                    let base_a = u32::from(color.a());
                    for oy in 0..gh {
                        let py = gy + oy;
                        if py < 0 || py >= phys_h {
                            continue;
                        }
                        let row = (py * phys_w) as usize;
                        let src_row = (oy * gw) as usize;
                        for ox in 0..gw {
                            let px = gx + ox;
                            if px < 0 || px >= phys_w {
                                continue;
                            }
                            let mask = u32::from(image.data[src_row + ox as usize]);
                            if mask == 0 {
                                continue;
                            }
                            let a = ((mask * base_a + 127) / 255) as u8;
                            let idx = row + px as usize;
                            pixels[idx] =
                                blend_over(pixels[idx], color.r(), color.g(), color.b(), a);
                        }
                    }
                }
                SwashContent::Color => {
                    for oy in 0..gh {
                        let py = gy + oy;
                        if py < 0 || py >= phys_h {
                            continue;
                        }
                        let row = (py * phys_w) as usize;
                        let src_row = (oy * gw * 4) as usize;
                        for ox in 0..gw {
                            let px = gx + ox;
                            if px < 0 || px >= phys_w {
                                continue;
                            }
                            let s = src_row + (ox as usize) * 4;
                            let idx = row + px as usize;
                            pixels[idx] = blend_over(
                                pixels[idx],
                                image.data[s],
                                image.data[s + 1],
                                image.data[s + 2],
                                image.data[s + 3],
                            );
                        }
                    }
                }
                SwashContent::SubpixelMask => {}
            }
        }
    }

    Some(RenderedPill {
        pixels,
        phys_width: phys_w,
        phys_height: phys_h,
        logical_width: logical_w,
        logical_height: logical_h,
    })
}

pub(super) trait PillState:
    wayland_client::Dispatch<wl_compositor::WlCompositor, ()>
    + wayland_client::Dispatch<wl_surface::WlSurface, ()>
    + wayland_client::Dispatch<wl_region::WlRegion, ()>
    + wayland_client::Dispatch<wl_shm::WlShm, ()>
    + wayland_client::Dispatch<wl_shm_pool::WlShmPool, ()>
    + wayland_client::Dispatch<wl_buffer::WlBuffer, ()>
    + wayland_client::Dispatch<WpViewporter, ()>
    + wayland_client::Dispatch<WpViewport, ()>
    + wayland_client::Dispatch<WpFractionalScaleManagerV1, ()>
    + wayland_client::Dispatch<WpFractionalScaleV1, ()>
    + 'static
{
}

impl<S> PillState for S where
    S: wayland_client::Dispatch<wl_compositor::WlCompositor, ()>
        + wayland_client::Dispatch<wl_surface::WlSurface, ()>
        + wayland_client::Dispatch<wl_region::WlRegion, ()>
        + wayland_client::Dispatch<wl_shm::WlShm, ()>
        + wayland_client::Dispatch<wl_shm_pool::WlShmPool, ()>
        + wayland_client::Dispatch<wl_buffer::WlBuffer, ()>
        + wayland_client::Dispatch<WpViewporter, ()>
        + wayland_client::Dispatch<WpViewport, ()>
        + wayland_client::Dispatch<WpFractionalScaleManagerV1, ()>
        + wayland_client::Dispatch<WpFractionalScaleV1, ()>
        + 'static
{
}

enum Role {
    Panel(ZwpInputPanelSurfaceV1),
    Popup(ZwpInputPopupSurfaceV2),
}

struct Target {
    surface: wl_surface::WlSurface,
    viewport: Option<WpViewport>,
    fractional: Option<WpFractionalScaleV1>,
    role: Role,
}

impl Target {
    fn destroy(self) {
        match self.role {
            Role::Panel(panel_surface) => drop(panel_surface),
            Role::Popup(popup) => popup.destroy(),
        }
        if let Some(fractional) = self.fractional {
            fractional.destroy();
        }
        if let Some(viewport) = self.viewport {
            viewport.destroy();
        }
        self.surface.destroy();
    }
}

enum Fonts {
    Loading(std::thread::JoinHandle<Painter>),
    Ready(Box<Painter>),
    Missing,
}

impl Fonts {
    fn start() -> Self {
        std::thread::Builder::new()
            .name("lokalbot-pill-fonts".into())
            .spawn(Painter::new)
            .map_or(Self::Missing, Self::Loading)
    }

    fn painter(&mut self) -> &mut Painter {
        if !matches!(self, Self::Ready(_)) {
            let painter = match std::mem::replace(self, Self::Missing) {
                Self::Loading(handle) => handle.join().unwrap_or_else(|_| Painter::new()),
                _ => Painter::new(),
            };
            *self = Self::Ready(Box::new(painter));
        }
        match self {
            Self::Ready(painter) => painter,
            _ => unreachable!(),
        }
    }
}

pub(super) struct OverlayPill {
    compositor: wl_compositor::WlCompositor,
    shm: wl_shm::WlShm,
    _panel: Option<ZwpInputPanelV1>,
    viewporter: Option<WpViewporter>,
    fractional_mgr: Option<WpFractionalScaleManagerV1>,
    target: Option<Target>,
    fractional_120: Option<u32>,
    integer_scale: i32,
    fonts: Fonts,
    shown: Option<Shown>,
    mapped: bool,
    in_flight: Vec<wl_buffer::WlBuffer>,
}

impl OverlayPill {
    pub(super) fn bind<S: PillState>(globals: &GlobalList, qh: &QueueHandle<S>) -> Option<Self> {
        let compositor: wl_compositor::WlCompositor = globals.bind(qh, 1..=6, ()).ok()?;
        let shm: wl_shm::WlShm = globals.bind(qh, 1..=1, ()).ok()?;
        Some(Self {
            compositor,
            shm,
            _panel: None,
            viewporter: globals.bind(qh, 1..=1, ()).ok(),
            fractional_mgr: globals.bind(qh, 1..=1, ()).ok(),
            target: None,
            fractional_120: None,
            integer_scale: 1,
            fonts: Fonts::start(),
            shown: None,
            mapped: false,
            in_flight: Vec::new(),
        })
    }

    pub(super) fn bind_panel<S>(globals: &GlobalList, qh: &QueueHandle<S>) -> Option<Self>
    where
        S: PillState
            + wayland_client::Dispatch<ZwpInputPanelV1, ()>
            + wayland_client::Dispatch<ZwpInputPanelSurfaceV1, ()>,
    {
        let panel: ZwpInputPanelV1 = globals.bind(qh, 1..=1, ()).ok()?;
        let mut pill = Self::bind(globals, qh)?;
        let surface = pill.new_surface(qh);
        let panel_surface = panel.get_input_panel_surface(&surface, qh, ());
        panel_surface.set_overlay_panel();
        pill.adopt(surface, Role::Panel(panel_surface), qh);
        pill._panel = Some(panel);
        Some(pill)
    }

    pub(super) fn attach_popup<S>(&mut self, input_method: &ZwpInputMethodV2, qh: &QueueHandle<S>)
    where
        S: PillState + wayland_client::Dispatch<ZwpInputPopupSurfaceV2, ()>,
    {
        self.detach();
        let surface = self.new_surface(qh);
        let popup = input_method.get_input_popup_surface(&surface, qh, ());
        self.adopt(surface, Role::Popup(popup), qh);
    }

    pub(super) fn detach(&mut self) {
        self.shown = None;
        self.mapped = false;
        for buffer in self.in_flight.drain(..) {
            buffer.destroy();
        }
        if let Some(target) = self.target.take() {
            target.destroy();
        }
    }

    fn new_surface<S: PillState>(&self, qh: &QueueHandle<S>) -> wl_surface::WlSurface {
        let surface = self.compositor.create_surface(qh, ());
        let empty = self.compositor.create_region(qh, ());
        surface.set_input_region(Some(&empty));
        empty.destroy();
        surface
    }

    fn adopt<S: PillState>(
        &mut self,
        surface: wl_surface::WlSurface,
        role: Role,
        qh: &QueueHandle<S>,
    ) {
        let (viewport, fractional) = match (&self.viewporter, &self.fractional_mgr) {
            (Some(vp), Some(fm)) => (
                Some(vp.get_viewport(&surface, qh, ())),
                Some(fm.get_fractional_scale(&surface, qh, ())),
            ),
            _ => (None, None),
        };
        self.target = Some(Target {
            surface,
            viewport,
            fractional,
            role,
        });
    }

    fn effective_scale(&self) -> f32 {
        if self.target.as_ref().is_some_and(|t| t.viewport.is_some())
            && let Some(scale_120) = self.fractional_120
        {
            return (scale_120 as f32 / 120.0).clamp(0.5, 4.0);
        }
        self.integer_scale.clamp(1, 4) as f32
    }

    pub(super) fn show<S>(
        &mut self,
        text: &str,
        emphasis_chars: usize,
        dark: bool,
        qh: &QueueHandle<S>,
    ) where
        S: wayland_client::Dispatch<wl_shm_pool::WlShmPool, ()>
            + wayland_client::Dispatch<wl_buffer::WlBuffer, ()>
            + 'static,
    {
        if text.trim().is_empty() {
            self.hide();
            return;
        }
        let target = Shown {
            text: text.to_string(),
            emphasis_chars,
            dark,
        };
        if self.shown.as_ref() == Some(&target) && self.mapped {
            return;
        }
        self.shown = Some(target);
        self.redraw(qh);
    }

    pub(super) fn hide(&mut self) {
        self.shown = None;
        if !self.mapped {
            return;
        }
        self.mapped = false;
        let Some(target) = &self.target else {
            return;
        };
        if let Some(viewport) = &target.viewport {
            viewport.set_destination(-1, -1);
        }
        target.surface.attach(None, 0, 0);
        target.surface.commit();
    }

    pub(super) fn on_preferred_buffer_scale<S>(&mut self, factor: i32, qh: &QueueHandle<S>)
    where
        S: wayland_client::Dispatch<wl_shm_pool::WlShmPool, ()>
            + wayland_client::Dispatch<wl_buffer::WlBuffer, ()>
            + 'static,
    {
        let factor = factor.clamp(1, 4);
        if self.integer_scale != factor {
            self.integer_scale = factor;
            if self.mapped {
                self.redraw(qh);
            }
        }
    }

    pub(super) fn on_fractional_scale<S>(&mut self, scale_120: u32, qh: &QueueHandle<S>)
    where
        S: wayland_client::Dispatch<wl_shm_pool::WlShmPool, ()>
            + wayland_client::Dispatch<wl_buffer::WlBuffer, ()>
            + 'static,
    {
        if self.fractional_120 != Some(scale_120) {
            self.fractional_120 = Some(scale_120);
            if self.mapped {
                self.redraw(qh);
            }
        }
    }

    pub(super) fn on_buffer_release(&mut self, released: &wl_buffer::WlBuffer) {
        if let Some(pos) = self.in_flight.iter().position(|b| b == released) {
            let buf = self.in_flight.swap_remove(pos);
            buf.destroy();
        }
    }

    fn redraw<S>(&mut self, qh: &QueueHandle<S>)
    where
        S: wayland_client::Dispatch<wl_shm_pool::WlShmPool, ()>
            + wayland_client::Dispatch<wl_buffer::WlBuffer, ()>
            + 'static,
    {
        let Some(shown) = self.shown.clone() else {
            return;
        };
        if self.target.is_none() {
            return;
        }
        let scale = self.effective_scale();
        let painter = self.fonts.painter();
        let Some(rendered) = render_pill_pixels(
            painter,
            &shown.text,
            shown.emphasis_chars,
            shown.dark,
            scale,
        ) else {
            self.hide();
            return;
        };
        let byte_len = rendered.pixels.len() * std::mem::size_of::<u32>();
        let Some(mut file) = create_shm_file() else {
            return;
        };
        let raw_bytes =
            unsafe { std::slice::from_raw_parts(rendered.pixels.as_ptr().cast::<u8>(), byte_len) };
        if file.write_all(raw_bytes).is_err() || file.flush().is_err() {
            return;
        }
        let Ok(pool_size) = i32::try_from(byte_len) else {
            return;
        };
        let stride = rendered.phys_width * 4;
        let pool = self.shm.create_pool(file.as_fd(), pool_size, qh, ());
        let buffer = pool.create_buffer(
            0,
            rendered.phys_width,
            rendered.phys_height,
            stride,
            wl_shm::Format::Argb8888,
            qh,
            (),
        );
        pool.destroy();

        let Some(target) = &self.target else {
            buffer.destroy();
            return;
        };
        let surface = &target.surface;
        if let Some(viewport) = &target.viewport
            && self.fractional_120.is_some()
        {
            if surface.version() >= 3 {
                surface.set_buffer_scale(1);
            }
            viewport.set_destination(rendered.logical_width, rendered.logical_height);
        } else if surface.version() >= 3 {
            surface.set_buffer_scale(self.integer_scale.clamp(1, 4));
        }

        surface.attach(Some(&buffer), 0, 0);
        if surface.version() >= 4 {
            surface.damage_buffer(0, 0, rendered.phys_width, rendered.phys_height);
        } else {
            surface.damage(0, 0, rendered.logical_width, rendered.logical_height);
        }
        surface.commit();
        self.in_flight.push(buffer);
        self.mapped = true;
    }
}

fn create_shm_file() -> Option<File> {
    let fd = unsafe { libc::memfd_create(c"lokalbot-pill".as_ptr(), libc::MFD_CLOEXEC) };
    if fd < 0 {
        return None;
    }
    Some(File::from(unsafe { OwnedFd::from_raw_fd(fd) }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_or_whitespace_renders_nothing_and_leading_space_trims_cleanly() {
        let mut painter = Painter::new();
        assert!(render_pill_pixels(&mut painter, "", 0, false, 1.0).is_none());
        assert!(render_pill_pixels(&mut painter, "   \n\t ", 3, true, 1.0).is_none());

        let (display, emphasis) = normalize_pill_text(" world on Thursday", 6).unwrap();
        assert_eq!(display, "world on Thursday");
        assert_eq!(emphasis, 5, "leading space was subtracted from emphasis");
    }

    #[test]
    fn pill_renders_visible_opaque_glyphs_in_both_themes_and_scales() {
        let mut painter = Painter::new();
        for (dark, scale) in [(false, 1.0), (true, 1.5), (false, 2.0)] {
            let Some(pill) = render_pill_pixels(&mut painter, " world today", 6, dark, scale)
            else {
                return;
            };
            assert!(pill.logical_width >= 40);
            assert!(pill.logical_height >= 20);
            assert_eq!(
                pill.pixels.len(),
                (pill.phys_width * pill.phys_height) as usize
            );
            assert_eq!(pill.pixels[0] >> 24, 0);
            let mid = ((pill.phys_height / 2) * pill.phys_width + (pill.phys_width / 2)) as usize;
            assert!((pill.pixels[mid] >> 24) >= 240);
        }
    }
}
