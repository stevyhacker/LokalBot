//! X11: the window in `_NET_ACTIVE_WINDOW`, read with `GetImage`. The client
//! window itself is read (not the root), so overlapping windows stay out on
//! compositing desktops; only the part on screen is read.

use anyhow::{Context as _, bail};
use x11rb::connection::Connection as _;
use x11rb::errors::ReplyError;
use x11rb::protocol::xproto::{
    Atom, AtomEnum, ConnectionExt as _, ImageFormat, ImageOrder, MapState, Visualid, Window,
};
use x11rb::rust_connection::RustConnection;

use super::{CapturedImage, FocusedWindow, WindowCapture, WindowRect};

/// Longest property read, in 32-bit units.
const MAX_PROPERTY_WORDS: u32 = 2048;

struct Session {
    conn: RustConnection,
    screen: usize,
    root: Window,
    net_active_window: Atom,
    net_wm_name: Atom,
    net_wm_pid: Atom,
    utf8_string: Atom,
    gtk_frame_extents: Atom,
}

impl Session {
    fn open() -> anyhow::Result<Self> {
        let (conn, screen) = x11rb::connect(None).context("could not connect to the X server")?;
        let root = conn
            .setup()
            .roots
            .get(screen)
            .context("the X server reported no screen")?
            .root;
        let intern = |name: &[u8]| -> anyhow::Result<Atom> {
            Ok(conn.intern_atom(false, name)?.reply()?.atom)
        };
        Ok(Self {
            net_active_window: intern(b"_NET_ACTIVE_WINDOW")?,
            net_wm_name: intern(b"_NET_WM_NAME")?,
            net_wm_pid: intern(b"_NET_WM_PID")?,
            utf8_string: intern(b"UTF8_STRING")?,
            gtk_frame_extents: intern(b"_GTK_FRAME_EXTENTS")?,
            conn,
            screen,
            root,
        })
    }

    fn property(
        &self,
        window: Window,
        property: impl Into<Atom>,
        kind: impl Into<Atom>,
    ) -> anyhow::Result<Option<Vec<u8>>> {
        let reply = self
            .conn
            .get_property(false, window, property, kind, 0, MAX_PROPERTY_WORDS)?
            .reply();
        match reply {
            Ok(reply) if reply.type_ != x11rb::NONE => Ok(Some(reply.value)),
            Ok(_) | Err(ReplyError::X11Error(_)) => Ok(None),
            Err(ReplyError::ConnectionError(err)) => Err(err.into()),
        }
    }

    fn active_window(&self) -> anyhow::Result<Option<Window>> {
        Ok(self
            .property(self.root, self.net_active_window, AtomEnum::WINDOW)?
            .and_then(|value| {
                value
                    .get(..4)
                    .map(|b| u32::from_ne_bytes([b[0], b[1], b[2], b[3]]))
            })
            .filter(|window| *window != x11rb::NONE))
    }

    fn title(&self, window: Window) -> anyhow::Result<String> {
        if let Some(value) = self.property(window, self.net_wm_name, self.utf8_string)?
            && !value.is_empty()
        {
            return Ok(String::from_utf8_lossy(&value).into_owned());
        }
        Ok(self
            .property(window, AtomEnum::WM_NAME, AtomEnum::ANY)?
            .map(|value| value.iter().map(|&b| char::from(b)).collect())
            .unwrap_or_default())
    }

    fn pid(&self, window: Window) -> anyhow::Result<Option<u32>> {
        Ok(self
            .property(window, self.net_wm_pid, AtomEnum::CARDINAL)?
            .and_then(|value| {
                value
                    .get(..4)
                    .map(|b| u32::from_ne_bytes([b[0], b[1], b[2], b[3]]))
            })
            .filter(|pid| *pid != 0))
    }

    /// The window's on-screen rectangle without the invisible shadow margin
    /// client-side decorations draw (`_GTK_FRAME_EXTENTS`), or `None` when
    /// it is not mapped.
    fn rect(&self, window: Window) -> anyhow::Result<Option<WindowRect>> {
        Ok(self.rects(window)?.map(|(_, content)| content))
    }

    /// The window's whole rectangle and its content (see [`Self::rect`]).
    fn rects(&self, window: Window) -> anyhow::Result<Option<(WindowRect, WindowRect)>> {
        let attributes = match self.conn.get_window_attributes(window)?.reply() {
            Ok(attributes) => attributes,
            Err(ReplyError::X11Error(_)) => return Ok(None),
            Err(err) => return Err(err.into()),
        };
        if attributes.map_state != MapState::VIEWABLE {
            return Ok(None);
        }
        let geometry = self.conn.get_geometry(window)?.reply()?;
        let origin = self
            .conn
            .translate_coordinates(window, self.root, 0, 0)?
            .reply()?;
        let outer = WindowRect {
            x: i32::from(origin.dst_x),
            y: i32::from(origin.dst_y),
            width: u32::from(geometry.width),
            height: u32::from(geometry.height),
        };
        let extents = self
            .property(window, self.gtk_frame_extents, AtomEnum::CARDINAL)?
            .map(|value| {
                value
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|bytes| u32::from_ne_bytes(*bytes))
                    .collect::<Vec<_>>()
            });
        let content = match extents.as_deref() {
            Some([left, right, top, bottom]) => without_margin(outer, *left, *right, *top, *bottom),
            _ => outer,
        };
        Ok(Some((outer, content)))
    }

    fn screen_rect(&self) -> WindowRect {
        let screen = &self.conn.setup().roots[self.screen];
        WindowRect {
            x: 0,
            y: 0,
            width: u32::from(screen.width_in_pixels),
            height: u32::from(screen.height_in_pixels),
        }
    }

    /// Red, green and blue masks of a visual.
    fn masks(&self, visual: Visualid) -> Option<(u32, u32, u32)> {
        self.conn
            .setup()
            .roots
            .iter()
            .flat_map(|screen| &screen.allowed_depths)
            .flat_map(|depth| &depth.visuals)
            .find(|candidate| candidate.visual_id == visual)
            .map(|v| (v.red_mask, v.green_mask, v.blue_mask))
    }

    fn capture(&self, window: Window) -> anyhow::Result<CapturedImage> {
        let (outer, content) = self
            .rects(window)?
            .context("the window is no longer on screen")?;
        let visible = content
            .intersection(&self.screen_rect())
            .context("the window is outside the screen")?;
        // GetImage takes coordinates inside the whole window.
        let reply = self
            .conn
            .get_image(
                ImageFormat::Z_PIXMAP,
                window,
                (visible.x - outer.x) as i16,
                (visible.y - outer.y) as i16,
                visible.width as u16,
                visible.height as u16,
                !0,
            )?
            .reply()
            .context("the X server did not return the window's pixels")?;
        let visual = if reply.visual == 0 {
            self.conn.setup().roots[self.screen].root_visual
        } else {
            reply.visual
        };
        let masks = self
            .masks(visual)
            .context("the window uses an unknown visual")?;
        let setup = self.conn.setup();
        let format = setup
            .pixmap_formats
            .iter()
            .find(|format| format.depth == reply.depth)
            .context("the X server reported no pixmap format for the window")?;
        convert(
            &reply.data,
            visible.width,
            visible.height,
            format.bits_per_pixel,
            format.scanline_pad,
            setup.image_byte_order == ImageOrder::MSB_FIRST,
            masks,
        )
    }
}

/// `rect` without a margin of `left`/`right`/`top`/`bottom` pixels; the
/// whole rectangle when the margin would leave nothing.
fn without_margin(rect: WindowRect, left: u32, right: u32, top: u32, bottom: u32) -> WindowRect {
    let width = rect.width.saturating_sub(left.saturating_add(right));
    let height = rect.height.saturating_sub(top.saturating_add(bottom));
    if width == 0 || height == 0 {
        return rect;
    }
    WindowRect {
        x: rect.x + left as i32,
        y: rect.y + top as i32,
        width,
        height,
    }
}

/// Z-pixmap data in the server's layout to RGBA.
fn convert(
    data: &[u8],
    width: u32,
    height: u32,
    bits_per_pixel: u8,
    scanline_pad: u8,
    big_endian: bool,
    (red, green, blue): (u32, u32, u32),
) -> anyhow::Result<CapturedImage> {
    let bytes_per_pixel = match bits_per_pixel {
        32 => 4,
        24 => 3,
        16 => 2,
        other => bail!("{other}-bit pixels are not supported"),
    };
    let pad = usize::from(scanline_pad.max(8) / 8);
    let stride = (width as usize * bytes_per_pixel).div_ceil(pad) * pad;
    if data.len() < stride * height as usize {
        bail!("the X server returned a short image");
    }
    let channel = |pixel: u32, mask: u32| -> u8 {
        if mask == 0 {
            return 0;
        }
        let value = (pixel & mask) >> mask.trailing_zeros();
        let max = mask >> mask.trailing_zeros();
        ((value * 255 + max / 2) / max) as u8
    };
    let mut rgba = Vec::with_capacity(width as usize * height as usize * 4);
    for row in data.chunks(stride).take(height as usize) {
        for bytes in row[..width as usize * bytes_per_pixel].chunks_exact(bytes_per_pixel) {
            let mut word = [0u8; 4];
            if big_endian {
                word[4 - bytes_per_pixel..].copy_from_slice(bytes);
            } else {
                word[..bytes_per_pixel].copy_from_slice(bytes);
            }
            let pixel = if big_endian {
                u32::from_be_bytes(word)
            } else {
                u32::from_le_bytes(word)
            };
            rgba.extend_from_slice(&[
                channel(pixel, red),
                channel(pixel, green),
                channel(pixel, blue),
                255,
            ]);
        }
    }
    Ok(CapturedImage {
        width,
        height,
        rgba,
    })
}

/// Reconnects when the X server connection breaks.
pub(super) struct X11Capture {
    session: Option<Session>,
}

impl X11Capture {
    pub(super) fn connect() -> anyhow::Result<Self> {
        Ok(Self {
            session: Some(Session::open()?),
        })
    }

    fn session(&mut self) -> anyhow::Result<&Session> {
        if self.session.is_none() {
            self.session = Some(Session::open()?);
        }
        self.session.as_ref().context("no X server connection")
    }

    fn reset_on_error<T>(&mut self, result: anyhow::Result<T>) -> anyhow::Result<T> {
        if let Err(err) = &result
            && (err
                .downcast_ref::<x11rb::errors::ConnectionError>()
                .is_some()
                || matches!(
                    err.downcast_ref::<ReplyError>(),
                    Some(ReplyError::ConnectionError(_))
                ))
        {
            self.session = None;
        }
        result
    }
}

impl WindowCapture for X11Capture {
    fn limitation(&self) -> Option<String> {
        None
    }

    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        let result = (|| {
            let session = self.session()?;
            let Some(window) = session.active_window()? else {
                return Ok(None);
            };
            let Some(rect) = session.rect(window)? else {
                return Ok(None);
            };
            Ok(Some(FocusedWindow {
                id: u64::from(window),
                pid: session.pid(window)?,
                title: session.title(window)?,
                rect: Some(rect),
            }))
        })();
        self.reset_on_error(result)
    }

    fn capture(&mut self, window: &FocusedWindow) -> anyhow::Result<CapturedImage> {
        let result = (|| {
            let session = self.session()?;
            let id = u32::try_from(window.id).context("not an X11 window")?;
            if session.active_window()? != Some(id) {
                bail!("another window came to the front");
            }
            session.capture(id)
        })();
        self.reset_on_error(result)
    }

    fn name(&self) -> &'static str {
        "x11"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_little_endian_bgrx() {
        // Two pixels per 8-byte row plus padding to 32 bits: blue, then red.
        let data = [255, 0, 0, 0, 0, 0, 255, 0, 10, 20, 30, 0, 1, 2, 3, 0];
        let image = convert(&data, 2, 2, 32, 32, false, (0xff0000, 0xff00, 0xff)).unwrap();
        assert_eq!(&image.rgba[..8], &[0, 0, 255, 255, 255, 0, 0, 255]);
        assert_eq!(&image.rgba[8..12], &[30, 20, 10, 255]);
    }

    #[test]
    fn converts_16_bit_rgb565_with_padding() {
        // One 5-6-5 white pixel; each row padded to 4 bytes.
        let data = [0xff, 0xff, 0, 0];
        let image = convert(&data, 1, 1, 16, 32, false, (0xf800, 0x07e0, 0x001f)).unwrap();
        assert_eq!(image.rgba, [255, 255, 255, 255]);
        assert!(convert(&data[..1], 1, 1, 16, 32, false, (0xf800, 0x07e0, 0x001f)).is_err());
    }

    #[test]
    fn shadow_margins_are_left_out() {
        let rect = WindowRect {
            x: 100,
            y: 50,
            width: 900,
            height: 600,
        };
        assert_eq!(
            without_margin(rect, 26, 26, 23, 29),
            WindowRect {
                x: 126,
                y: 73,
                width: 848,
                height: 548
            }
        );
        assert_eq!(without_margin(rect, 500, 500, 0, 0), rect);
    }

    #[test]
    fn converts_big_endian_xrgb() {
        let data = [0, 1, 2, 3];
        let image = convert(&data, 1, 1, 32, 32, true, (0xff0000, 0xff00, 0xff)).unwrap();
        assert_eq!(image.rgba, [1, 2, 3, 255]);
    }
}
