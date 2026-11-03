//! `Windows.Media.Ocr`, the recognizer built into Windows. It has no model to
//! download and reads the languages whose packs are installed on this PC.

use std::time::{Duration, Instant};

use anyhow::{Context as _, Result};
use parking_lot::Mutex;
use windows::Globalization::Language;
use windows::Graphics::Imaging::{BitmapPixelFormat, SoftwareBitmap};
use windows::Media::Ocr::OcrEngine;
use windows::Storage::Streams::DataWriter;
use windows::core::HSTRING;

use super::OcrLine;

/// How long the installed languages are trusted before asking Windows again.
const LANGUAGES_LIFETIME: Duration = Duration::from_secs(30);

/// The language tags Windows can read here, such as `en-US` or `zh-Hans-CN`.
pub fn recognizer_languages() -> Vec<String> {
    static CACHE: Mutex<Option<(Instant, Vec<String>)>> = Mutex::new(None);
    let mut cache = CACHE.lock();
    if let Some((at, languages)) = cache.as_ref()
        && at.elapsed() < LANGUAGES_LIFETIME
    {
        return languages.clone();
    }
    let ask = || -> windows::core::Result<Vec<String>> {
        OcrEngine::AvailableRecognizerLanguages()?
            .into_iter()
            .map(|language| Ok(language.LanguageTag()?.to_string()))
            .collect()
    };
    let languages = ask().unwrap_or_else(|err| {
        log::debug!("screen text recognition: no recognizer languages: {err}");
        Vec::new()
    });
    *cache = Some((Instant::now(), languages.clone()));
    languages
}

/// One recognizer, for one language.
pub(super) struct Recognizer {
    engine: OcrEngine,
    max_dimension: u32,
}

impl Recognizer {
    pub(super) fn new(tag: &str) -> Result<Self> {
        let language = Language::CreateLanguage(&HSTRING::from(tag))
            .with_context(|| format!("the language {tag}"))?;
        Ok(Self {
            engine: OcrEngine::TryCreateFromLanguage(&language)
                .with_context(|| format!("the recognizer for {tag}"))?,
            max_dimension: OcrEngine::MaxImageDimension()?,
        })
    }

    /// The lines in an RGBA image, in the image's pixels.
    pub(super) fn read(&self, rgba: &[u8], width: u32, height: u32) -> Result<Vec<OcrLine>> {
        anyhow::ensure!(
            width.max(height) <= self.max_dimension,
            "the image is larger than the recognizer reads"
        );
        let writer = DataWriter::new()?;
        writer.WriteBytes(&bgra(rgba))?;
        let bitmap = SoftwareBitmap::CreateCopyFromBuffer(
            &writer.DetachBuffer()?,
            BitmapPixelFormat::Bgra8,
            width as i32,
            height as i32,
        )?;
        let result = self.engine.RecognizeAsync(&bitmap)?.join()?;
        let mut lines = Vec::new();
        for line in result.Lines()? {
            let text = super::collapse_cjk_spaces(&line.Text()?.to_string());
            let text = text.trim();
            if text.is_empty() {
                continue;
            }
            let (mut left, mut top, mut right, mut bottom) = (f32::MAX, f32::MAX, 0f32, 0f32);
            for word in line.Words()? {
                let rect = word.BoundingRect()?;
                left = left.min(rect.X);
                top = top.min(rect.Y);
                right = right.max(rect.X + rect.Width);
                bottom = bottom.max(rect.Y + rect.Height);
            }
            if right > 0.0 && bottom > 0.0 {
                lines.push(OcrLine {
                    text: text.to_string(),
                    x: left as i32,
                    y: top as i32,
                    width: (right - left) as i32,
                    height: (bottom - top) as i32,
                });
            }
        }
        Ok(lines)
    }
}

/// RGBA as opaque BGRA, the format the recognizer's own samples hand it.
fn bgra(rgba: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(rgba.len());
    for pixel in rgba.as_chunks::<4>().0 {
        out.extend_from_slice(&[pixel[2], pixel[1], pixel[0], 255]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pixels_are_swapped_and_opaque() {
        assert_eq!(
            bgra(&[1, 2, 3, 0, 4, 5, 6, 200]),
            [3, 2, 1, 255, 6, 5, 4, 255]
        );
    }

    /// Runs on the Windows CI job against the real recognizer. Images without an
    /// OCR language pack have nothing to read with, and that is reported as such.
    #[test]
    fn the_real_recognizer_reads_a_rendered_banner() {
        let languages = recognizer_languages();
        println!("recognizer languages: {languages:?}");
        let Some(tag) = languages.first() else {
            println!("this Windows has no recognizer language; nothing more to check");
            return;
        };
        let recognizer = Recognizer::new(tag).unwrap();
        let (width, height, rgba) = crate::ocr::tests::banner();
        let lines = recognizer.read(&rgba, width, height).unwrap();
        println!("read with {tag}: {lines:?}");
        let text: String = lines.iter().map(|line| line.text.as_str()).collect();
        // The blocky test font can be misread a letter at a time.
        let found = "LOKABT"
            .chars()
            .filter(|letter| text.to_uppercase().contains(*letter))
            .count();
        assert!(found >= 3, "{text}");
        assert!(lines[0].width > 0 && lines[0].height > 0, "{lines:?}");
    }

    /// The image is checked before anything reaches Windows.
    #[test]
    fn an_image_beyond_the_limit_is_refused() {
        let Some(tag) = recognizer_languages().into_iter().next() else {
            return;
        };
        let recognizer = Recognizer::new(&tag).unwrap();
        let side = recognizer.max_dimension + 1;
        assert!(recognizer.read(&[], side, 1).is_err());
    }
}
