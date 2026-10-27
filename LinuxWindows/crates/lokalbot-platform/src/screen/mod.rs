//! Screen context: the focused window's pixels and its visible text, the
//! Linux and Windows counterparts of ScreenCaptureKit and the Accessibility
//! reader in `ScreenshotService.swift` and `ScreenAccessibilityReader.swift`.
//!
//! - [`window_capture`] reads the pixels of the window in front: X11
//!   `GetImage`, `grim` on wlroots compositors, the xdg-desktop-portal
//!   Screenshot API elsewhere on Wayland (cropped to the focused window when
//!   the compositor reports where it is), and GDI on Windows.
//! - [`text_reader`] reads the window's visible text and secure-field state
//!   through accessibility: AT-SPI on Linux, UI Automation on Windows.
//! - [`InteractionMonitor`] turns idle-time and clipboard changes into capture
//!   hints without reading keys, pointer positions or clipboard contents.
//! - [`privacy`] holds the rules that decide whether a window may be kept.
//!
//! Only the focused window is ever captured, never the whole display or a
//! window behind it. The engine decides when to capture and what to keep.

use std::time::Duration;

pub mod privacy;

#[cfg(target_os = "linux")]
mod atspi;
mod events;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod uia;
#[cfg(target_os = "linux")]
mod wayland;
#[cfg(windows)]
mod win32;
#[cfg(target_os = "linux")]
mod x11;

pub use events::{Interaction, InteractionMonitor};

/// RGBA pixels, 8 bits per channel, rows top to bottom.
#[derive(Clone, PartialEq, Eq)]
pub struct CapturedImage {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

impl std::fmt::Debug for CapturedImage {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "CapturedImage({}×{})", self.width, self.height)
    }
}

impl CapturedImage {
    /// The image scaled down (box filter) so neither side exceeds `max`,
    /// keeping its aspect ratio (`ScreenshotCaptureDimensions.bounded`).
    pub fn bounded(&self, max: u32) -> CapturedImage {
        let (width, height) = bounded_dimensions(self.width, self.height, max);
        if (width, height) == (self.width, self.height) {
            return self.clone();
        }
        let (src_w, src_h) = (self.width as usize, self.height as usize);
        let mut rgba = vec![0u8; width as usize * height as usize * 4];
        for y in 0..height as usize {
            let y0 = y * src_h / height as usize;
            let y1 = ((y + 1) * src_h / height as usize).max(y0 + 1).min(src_h);
            for x in 0..width as usize {
                let x0 = x * src_w / width as usize;
                let x1 = ((x + 1) * src_w / width as usize).max(x0 + 1).min(src_w);
                let mut sum = [0u32; 4];
                for sy in y0..y1 {
                    let row = &self.rgba[(sy * src_w + x0) * 4..(sy * src_w + x1) * 4];
                    for pixel in row.as_chunks::<4>().0 {
                        for (total, value) in sum.iter_mut().zip(pixel) {
                            *total += u32::from(*value);
                        }
                    }
                }
                let count = ((y1 - y0) * (x1 - x0)) as u32;
                let out = &mut rgba[(y * width as usize + x) * 4..][..4];
                for (channel, total) in out.iter_mut().zip(sum) {
                    *channel = (total / count.max(1)) as u8;
                }
            }
        }
        CapturedImage {
            width,
            height,
            rgba,
        }
    }

    /// True when every pixel has the same color (a blank or black frame).
    pub fn is_uniform(&self) -> bool {
        let mut pixels = self.rgba.as_chunks::<4>().0.iter();
        let Some(first) = pixels.next() else {
            return true;
        };
        pixels.all(|pixel| pixel[..3] == first[..3])
    }
}

/// `ScreenshotCaptureDimensions.bounded`: the longest side at most `max`.
pub fn bounded_dimensions(width: u32, height: u32, max: u32) -> (u32, u32) {
    let (width, height, max) = (width.max(1), height.max(1), max.max(1));
    let longest = width.max(height);
    if longest <= max {
        return (width, height);
    }
    let scale = f64::from(max) / f64::from(longest);
    (
        ((f64::from(width) * scale).round() as u32).max(1),
        ((f64::from(height) * scale).round() as u32).max(1),
    )
}

/// Where a window is, in physical screen pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WindowRect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

impl WindowRect {
    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0
    }

    pub fn intersection(&self, other: &WindowRect) -> Option<WindowRect> {
        let left = self.x.max(other.x);
        let top = self.y.max(other.y);
        let right = (self.x + self.width as i32).min(other.x + other.width as i32);
        let bottom = (self.y + self.height as i32).min(other.y + other.height as i32);
        (right > left && bottom > top).then(|| WindowRect {
            x: left,
            y: top,
            width: (right - left) as u32,
            height: (bottom - top) as u32,
        })
    }

    pub fn contains(&self, other: &WindowRect) -> bool {
        other.x >= self.x
            && other.y >= self.y
            && other.x + other.width as i32 <= self.x + self.width as i32
            && other.y + other.height as i32 <= self.y + self.height as i32
    }
}

/// The window in front as the capture backend sees it. `id` is the X11
/// window, the `HWND`, or the compositor's window id; it only has meaning to
/// the backend that produced it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FocusedWindow {
    pub id: u64,
    pub pid: Option<u32>,
    pub title: String,
    pub rect: Option<WindowRect>,
}

/// Reads the pixels of the focused window. Calls are bounded by short
/// timeouts; none of them prompts the user except the Wayland portal, which
/// may ask once whether LokalBot may take screenshots.
pub trait WindowCapture: Send {
    /// What this desktop cannot capture, worded for Settings, or `None`.
    fn limitation(&self) -> Option<String>;
    /// The window in front now, or `None` (the desktop, a lock screen, no session).
    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>>;
    /// The pixels of `window`, which must still be in front. Fails rather
    /// than return any other window or the whole display.
    fn capture(&mut self, window: &FocusedWindow) -> anyhow::Result<CapturedImage>;
    /// Short name for logs: `x11`, `grim`, `portal`, `gdi`, `unavailable`.
    fn name(&self) -> &'static str;
}

/// The best capture backend for this session.
pub fn window_capture() -> Box<dyn WindowCapture> {
    #[cfg(windows)]
    {
        Box::new(win32::GdiCapture::new())
    }
    #[cfg(target_os = "linux")]
    {
        linux::window_capture()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Box::new(Unavailable(
            "Screen capture is not available on this system.".into(),
        ))
    }
}

/// What accessibility reports about the focused window
/// (`ScreenAccessibilitySnapshot`). Text is visible text only: visible
/// character ranges of text views and labels that are fully on screen.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AccessibleWindow {
    /// Visible text, one element per line, at most about 24 000 characters.
    pub text: String,
    /// The page address of a browser window (its outermost web document).
    pub source_url: Option<String>,
    /// File name of the open document, when the app reports one.
    pub document_name: Option<String>,
    /// Whether the focused element is a password field; `None` when unknown.
    pub focused_secure_field: Option<bool>,
    pub window_title: Option<String>,
    pub has_web_content: bool,
    /// Some inspected text input is a password field.
    pub contains_secure_field: bool,
    /// Other sites' pages framed inside the window, sanitized.
    pub framed_urls: Vec<String>,
    /// Some web content's address could not be read.
    pub has_unattributed_web_content: bool,
}

/// The result of one accessibility read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TextRead {
    Read(AccessibleWindow),
    /// Accessibility is off, the app exposes nothing, or the window could
    /// not be matched. The capture proceeds with OCR and unknown focus.
    Unavailable(String),
    /// The window, its title or its focus changed while it was read (a tab
    /// switch, a page load); reading again a moment later can succeed.
    Changed(String),
    /// The read ran past its deadline.
    TimedOut,
}

/// Reads the focused window through accessibility. LokalBot's own windows
/// are never read.
pub trait TextReader: Send {
    /// Reads `window` within `deadline`. With `include_text` false only the
    /// privacy metadata (title, address, secure fields) is read.
    fn read(&mut self, window: &FocusedWindow, include_text: bool, deadline: Duration) -> TextRead;
    /// Short name for logs: `uia`, `atspi`, `unavailable`.
    fn name(&self) -> &'static str;
}

/// The accessibility reader for this system.
pub fn text_reader() -> Box<dyn TextReader> {
    #[cfg(windows)]
    {
        Box::new(uia::UiaReader::new())
    }
    #[cfg(target_os = "linux")]
    {
        Box::new(atspi::AtspiReader::new())
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        Box::new(Unavailable("Accessibility is not available.".into()))
    }
}

/// Whether the session is locked (the lock screen is up), when the system
/// can tell. Captures pause while it is.
pub fn session_locked() -> bool {
    #[cfg(windows)]
    {
        win32::session_locked()
    }
    #[cfg(target_os = "linux")]
    {
        linux::session_locked()
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        false
    }
}

/// A backend that never captures, with the reason why.
pub struct Unavailable(pub String);

impl WindowCapture for Unavailable {
    fn limitation(&self) -> Option<String> {
        Some(self.0.clone())
    }

    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        Ok(None)
    }

    fn capture(&mut self, _window: &FocusedWindow) -> anyhow::Result<CapturedImage> {
        anyhow::bail!("{}", self.0)
    }

    fn name(&self) -> &'static str {
        "unavailable"
    }
}

impl TextReader for Unavailable {
    fn read(&mut self, _: &FocusedWindow, _: bool, _: Duration) -> TextRead {
        TextRead::Unavailable(self.0.clone())
    }

    fn name(&self) -> &'static str {
        "unavailable"
    }
}

/// Appends a visible string the way `ScreenAccessibilityReader.append` does:
/// NULs removed, trimmed, at most 8 000 characters per element, each string
/// once, and no more than `max_chars` in total. Returns false once full.
pub(crate) fn append_text(
    raw: &str,
    parts: &mut Vec<String>,
    seen: &mut std::collections::HashSet<String>,
    total: &mut usize,
    max_chars: usize,
) -> bool {
    if *total >= max_chars {
        return false;
    }
    let value = raw.replace('\u{0}', "");
    let value = value.trim();
    if value.is_empty() || value.chars().count() > 8_000 || !seen.insert(value.to_string()) {
        return true;
    }
    let clipped: String = value.chars().take(max_chars - *total).collect();
    *total += clipped.chars().count();
    parts.push(clipped);
    *total < max_chars
}

/// Bounds shared by the accessibility readers (`ScreenAccessibilityReader.resolve`).
pub(crate) const MAX_NODES: usize = 320;
pub(crate) const MAX_CHARACTERS: usize = 24_000;
pub(crate) const MAX_CHILDREN: usize = 80;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dimensions_are_bounded_like_the_mac() {
        assert_eq!(bounded_dimensions(3000, 1500, 1500), (1500, 750));
        assert_eq!(bounded_dimensions(800, 600, 1500), (800, 600));
        assert_eq!(bounded_dimensions(1, 5000, 1500), (1, 1500));
        assert_eq!(bounded_dimensions(0, 0, 1500), (1, 1));
    }

    #[test]
    fn bounded_images_average_their_pixels() {
        let image = CapturedImage {
            width: 4,
            height: 2,
            rgba: [[0u8, 0, 0, 255], [255, 255, 255, 255]]
                .iter()
                .cycle()
                .take(8)
                .flatten()
                .copied()
                .collect(),
        };
        let small = image.bounded(2);
        assert_eq!((small.width, small.height), (2, 1));
        assert!(small.rgba.chunks(4).all(|p| p[0] == 127 && p[3] == 255));
        assert!(!image.is_uniform());
        assert!(small.is_uniform());
    }

    #[test]
    fn rectangles_intersect() {
        let screen = WindowRect {
            x: 0,
            y: 0,
            width: 100,
            height: 100,
        };
        let window = WindowRect {
            x: -20,
            y: 50,
            width: 50,
            height: 80,
        };
        assert_eq!(
            screen.intersection(&window),
            Some(WindowRect {
                x: 0,
                y: 50,
                width: 30,
                height: 50
            })
        );
        assert!(!screen.contains(&window));
        assert_eq!(screen.intersection(&WindowRect { x: 200, ..window }), None);
    }

    #[test]
    fn appended_text_is_deduplicated_and_capped() {
        let mut parts = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut total = 0;
        assert!(append_text(
            "  Hello\u{0} ",
            &mut parts,
            &mut seen,
            &mut total,
            10
        ));
        assert!(append_text("Hello", &mut parts, &mut seen, &mut total, 10));
        assert!(!append_text(
            "World wide",
            &mut parts,
            &mut seen,
            &mut total,
            10
        ));
        assert_eq!(parts, ["Hello", "World"]);
        assert!(!append_text("more", &mut parts, &mut seen, &mut total, 10));
    }
}
