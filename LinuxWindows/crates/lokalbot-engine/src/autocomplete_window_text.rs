use std::time::Instant;

use lokalbot_ai::autocomplete::window_text::{self, Frame, Line};
use lokalbot_ai::ocr::{self, OcrEngine};
use lokalbot_core::LibraryPaths;
use lokalbot_platform::screen::{self, WindowCapture};

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WindowRequest {
    pub key: String,
    pub pid: u32,
    pub title: String,
    pub url: Option<String>,
    pub field: Frame,
}

const MAXIMUM_DIMENSION: u32 = 3_000;

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct WindowRead {
    pub lines: Vec<Line>,
    pub window: Frame,
}

#[derive(Default)]
pub(crate) struct WindowReader {
    capture: Option<Box<dyn WindowCapture>>,
    engine: Option<OcrEngine>,
    recognized: Option<(String, [u8; 32], Vec<Line>)>,
}

impl WindowReader {
    pub fn read(&mut self, paths: &LibraryPaths, request: &WindowRequest) -> Option<WindowRead> {
        if !ocr::is_ready(paths) {
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
        if self
            .engine
            .as_ref()
            .is_none_or(|engine| !engine.is_current(paths))
        {
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

    pub fn forget(&mut self) {
        self.recognized = None;
    }

    pub fn unload(&mut self) {
        *self = Self::default();
    }
}
