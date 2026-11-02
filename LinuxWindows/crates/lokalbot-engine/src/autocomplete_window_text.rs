//! Reading the focused window for autocomplete (`CotypingWindowTextCapture`):
//! captures only that window, recognizes its text with the on-device OCR
//! model, and drops the image at once. Never downloads: without the model
//! there is no window text. An image unchanged outside the field reuses the
//! last lines. Logs carry counts and times only, never text.

use std::time::Instant;

use lokalbot_ai::autocomplete::window_text::{self, Frame, Line};
use lokalbot_ai::ocr::{self, OcrEngine};
use lokalbot_core::LibraryPaths;
use lokalbot_platform::screen::{self, WindowCapture};

/// Everything a read needs, from the field read that asked for it.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WindowRequest {
    pub key: String,
    pub pid: u32,
    pub title: String,
    pub url: Option<String>,
    pub field: Frame,
}

/// The longest side of a captured window, as on macOS.
const MAXIMUM_DIMENSION: u32 = 3_000;

/// Lines recognized in one window, in screen pixels.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WindowRead {
    pub lines: Vec<Line>,
    pub window: Frame,
}

#[derive(Default)]
pub(crate) struct WindowReader {
    capture: Option<Box<dyn WindowCapture>>,
    engine: Option<OcrEngine>,
    /// The last lines read for the field in use, outside the field, with the
    /// fingerprint of the image they came from.
    recognized: Option<(String, [u8; 32], Vec<Line>)>,
}

impl WindowReader {
    /// `None` when the model is not installed, or the window in front is not
    /// the one asked about.
    pub fn read(&mut self, paths: &LibraryPaths, request: &WindowRequest) -> Option<WindowRead> {
        if !ocr::is_installed(paths) {
            return None;
        }
        let capture = self.capture.get_or_insert_with(screen::window_capture);
        let window = capture.focused().ok()??;
        if window.pid != Some(request.pid) || window.title != request.title {
            log::debug!("autocomplete window text: the focused window is another one");
            return None;
        }
        let rect = window.rect.filter(|rect| !rect.is_empty())?;
        let frame = Frame::new(
            f64::from(rect.x),
            f64::from(rect.y),
            f64::from(rect.width),
            f64::from(rect.height),
        );
        let image = capture
            .capture(&window)
            .map_err(|err| log::debug!("autocomplete window text: capture failed: {err:#}"))
            .ok()?
            .bounded(MAXIMUM_DIMENSION);
        let fingerprint = window_text::fingerprint(
            &image.rgba,
            image.width as usize,
            image.height as usize,
            frame,
            request.field,
        );
        if let (Some(print), Some((key, known, lines))) = (fingerprint, &self.recognized)
            && *key == request.key
            && *known == print
        {
            log::debug!("autocomplete window text: unchanged outside the field");
            return Some(WindowRead {
                lines: lines.clone(),
                window: frame,
            });
        }
        if self.engine.is_none() {
            self.engine = OcrEngine::load(paths)
                .map_err(|err| log::warn!("autocomplete window text: {err:#}"))
                .ok();
        }
        let engine = self.engine.as_ref()?;
        let started = Instant::now();
        let recognized = engine
            .recognize_lines(&image.rgba, image.width, image.height)
            .map_err(|err| log::debug!("autocomplete window text: {err:#}"))
            .ok()?;
        let (scale_x, scale_y) = (
            frame.width / f64::from(image.width.max(1)),
            frame.height / f64::from(image.height.max(1)),
        );
        let lines: Vec<Line> = recognized
            .into_iter()
            .map(|line| Line {
                frame: Frame::new(
                    frame.x + f64::from(line.x) * scale_x,
                    frame.y + f64::from(line.y) * scale_y,
                    f64::from(line.width) * scale_x,
                    f64::from(line.height) * scale_y,
                ),
                text: line.text,
            })
            .collect();
        log::debug!(
            "autocomplete window text: read {} lines from {}×{} in {} ms",
            lines.len(),
            image.width,
            image.height,
            started.elapsed().as_millis()
        );
        if let Some(print) = fingerprint {
            // The draft is never prompt context, so it is not kept either.
            self.recognized = Some((
                request.key.clone(),
                print,
                window_text::outside_field(lines.clone(), request.field),
            ));
        }
        Some(WindowRead {
            lines,
            window: frame,
        })
    }

    /// Forgets the text held for reuse.
    pub fn forget(&mut self) {
        self.recognized = None;
    }

    /// Autocomplete stopped: the model need not stay loaded.
    pub fn unload(&mut self) {
        *self = Self::default();
    }
}
