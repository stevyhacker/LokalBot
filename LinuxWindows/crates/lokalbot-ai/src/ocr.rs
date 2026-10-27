//! On-device text recognition for screen context, the counterpart of the
//! Vision `VNRecognizeTextRequest` the Mac app runs on screenshots
//! (`ScreenshotImageProcessing.recognizeText`).
//!
//! Recognition uses [ocrs](https://github.com/robertknight/ocrs), a pure-Rust
//! engine, with its text detection and text recognition models. Both files
//! are pinned by size and SHA-256 and are downloaded only when the user asks
//! (Settings → Day Memory or Models), into `<library>/models/ocrs/`. The
//! models read Latin script: letters, digits and common punctuation.

use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

use anyhow::{Context as _, Result};
use lokalbot_core::LibraryPaths;

use crate::download::{self, DownloadSpec};

/// Id the engine and the Models page use for the pair of files.
pub const OCR_MODEL_ID: &str = "ocrs-text";
pub const OCR_DISPLAY_NAME: &str = "Screen text recognition (ocrs)";
/// The models' license (the engine is MIT or Apache 2.0).
pub const OCR_MODEL_LICENSE: &str = "CC BY-SA 4.0";

/// One pinned model file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OcrFile {
    pub name: &'static str,
    pub url: &'static str,
    pub size: u64,
    pub sha256: &'static str,
}

/// Detection first, then recognition. These are the files `ocrs-cli` 0.13
/// loads by default.
pub const OCR_FILES: [OcrFile; 2] = [
    OcrFile {
        name: "text-detection.onnx",
        url: "https://ocrs-models.s3-accelerate.amazonaws.com/text-detection.onnx",
        size: 2_499_479,
        sha256: "a917b23dbd9524b465df7e922641b3ff2981623df4ded5a0234004ef2fee7cfe",
    },
    OcrFile {
        name: "text-recognition.onnx",
        url: "https://ocrs-models.s3-accelerate.amazonaws.com/text-recognition.onnx",
        size: 9_713_177,
        sha256: "86c145c2edb96c8caed5b1ebb8f44d706408922211451c309c625157dd6061c5",
    },
];

/// Both files together.
pub fn total_size() -> u64 {
    OCR_FILES.iter().map(|file| file.size).sum()
}

/// `<library>/models/ocrs`.
pub fn model_dir(paths: &LibraryPaths) -> PathBuf {
    paths.models_dir().join("ocrs")
}

pub fn file_path(paths: &LibraryPaths, file: &OcrFile) -> PathBuf {
    model_dir(paths).join(file.name)
}

/// Both files are present with their pinned size and a matching sidecar
/// digest (written by the verified download).
pub fn is_installed(paths: &LibraryPaths) -> bool {
    OCR_FILES.iter().all(|file| {
        let path = file_path(paths, file);
        std::fs::metadata(&path).is_ok_and(|meta| meta.len() == file.size)
            && download::read_sidecar(&path).is_some_and(|d| d.eq_ignore_ascii_case(file.sha256))
    })
}

/// The verified downloads of both files.
pub fn download_specs(paths: &LibraryPaths) -> Vec<DownloadSpec> {
    OCR_FILES
        .iter()
        .map(|file| DownloadSpec {
            url: file.url.to_string(),
            sha256: file.sha256.to_string(),
            size: file.size,
            dest: file_path(paths, file),
        })
        .collect()
}

/// Downloads whatever is missing. `progress(done, total)` covers both files.
pub fn download(
    paths: &LibraryPaths,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<()> {
    let total = total_size();
    let mut finished = 0u64;
    for spec in download_specs(paths) {
        let size = spec.size;
        download::download(&spec, cancel, &mut |done, _| {
            progress(finished + done, total)
        })?;
        finished += size;
    }
    progress(total, total);
    Ok(())
}

/// Removes both files, their sidecars and the folder.
pub fn delete(paths: &LibraryPaths) -> std::io::Result<()> {
    for file in &OCR_FILES {
        let path = file_path(paths, file);
        for path in [download::sidecar_path(&path), path] {
            match std::fs::remove_file(&path) {
                Err(err) if err.kind() != std::io::ErrorKind::NotFound => return Err(err),
                _ => {}
            }
        }
    }
    let _ = std::fs::remove_dir(model_dir(paths));
    Ok(())
}

/// A loaded recognizer. Loading reads about 12 MB of model weights, so keep
/// one and reuse it.
pub struct OcrEngine {
    engine: ocrs::OcrEngine,
}

impl OcrEngine {
    /// Loads the installed models, or fails when they are not downloaded.
    pub fn load(paths: &LibraryPaths) -> Result<Self> {
        anyhow::ensure!(
            is_installed(paths),
            "The screen text recognition model is not downloaded."
        );
        let load = |file: &OcrFile| -> Result<rten::Model> {
            let path = file_path(paths, file);
            rten::Model::load_file(&path)
                .with_context(|| format!("loading {}", display_name(&path)))
        };
        let engine = ocrs::OcrEngine::new(ocrs::OcrEngineParams {
            detection_model: Some(load(&OCR_FILES[0])?),
            recognition_model: Some(load(&OCR_FILES[1])?),
            ..Default::default()
        })?;
        Ok(Self { engine })
    }

    /// The text in an RGBA image, one recognized line per line, top to bottom.
    pub fn recognize(&self, rgba: &[u8], width: u32, height: u32) -> Result<String> {
        anyhow::ensure!(
            width > 0 && height > 0 && rgba.len() == width as usize * height as usize * 4,
            "the image has no pixels"
        );
        let source = ocrs::ImageSource::from_bytes(rgba, (width, height))?;
        let input = self.engine.prepare_input(source)?;
        let text = self.engine.get_text(&input)?;
        Ok(text
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>()
            .join("\n"))
    }
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_are_well_formed() {
        for file in &OCR_FILES {
            assert!(file.url.starts_with("https://"), "{}", file.name);
            assert!(file.url.ends_with(file.name));
            assert_eq!(file.sha256.len(), 64);
            assert!(download::source_refusal(file.url, file.sha256, false).is_none());
        }
        assert_eq!(total_size(), 12_212_656);
    }

    #[test]
    fn installed_needs_both_files_with_their_digests() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        assert!(!is_installed(&paths));
        assert!(OcrEngine::load(&paths).is_err());
        std::fs::create_dir_all(model_dir(&paths)).unwrap();
        for file in &OCR_FILES {
            let path = file_path(&paths, file);
            let handle = std::fs::File::create(&path).unwrap();
            handle.set_len(file.size).unwrap();
            download::write_sidecar(&path, file.sha256).unwrap();
        }
        assert!(is_installed(&paths));
        download::write_sidecar(&file_path(&paths, &OCR_FILES[1]), &"0".repeat(64)).unwrap();
        assert!(!is_installed(&paths));
        delete(&paths).unwrap();
        assert!(!model_dir(&paths).exists());
    }

    /// Downloads the real models (about 12 MB) and reads rendered text.
    #[test]
    #[ignore = "downloads the OCR models"]
    fn reads_rendered_text() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        download(&paths, &AtomicBool::new(false), &mut |_, _| {}).unwrap();
        let engine = OcrEngine::load(&paths).unwrap();
        let (width, height, rgba) = banner();
        let text = engine
            .recognize(&rgba, width, height)
            .unwrap()
            .to_uppercase();
        // The blocky test font's K can read as E.
        assert!(text.starts_with("LO") && text.ends_with("ALBOT"), "{text}");
    }

    /// "LOKALBOT" in a 5×7 bitmap font, scaled up, black on white.
    pub(super) fn banner() -> (u32, u32, Vec<u8>) {
        const GLYPHS: [[&str; 7]; 8] = [
            [
                "X....", "X....", "X....", "X....", "X....", "X....", "XXXXX",
            ],
            [
                ".XXX.", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX.",
            ],
            [
                "X...X", "X..X.", "X.X..", "XX...", "X.X..", "X..X.", "X...X",
            ],
            [
                ".XXX.", "X...X", "X...X", "XXXXX", "X...X", "X...X", "X...X",
            ],
            [
                "X....", "X....", "X....", "X....", "X....", "X....", "XXXXX",
            ],
            [
                "XXXX.", "X...X", "X...X", "XXXX.", "X...X", "X...X", "XXXX.",
            ],
            [
                ".XXX.", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX.",
            ],
            [
                "XXXXX", "..X..", "..X..", "..X..", "..X..", "..X..", "..X..",
            ],
        ];
        let scale = 6u32;
        let (width, height) = (8 * 6 * scale + 40, 7 * scale + 40);
        let mut rgba = vec![255u8; (width * height * 4) as usize];
        for (index, glyph) in GLYPHS.iter().enumerate() {
            for (row, line) in glyph.iter().enumerate() {
                for (column, cell) in line.chars().enumerate() {
                    if cell != 'X' {
                        continue;
                    }
                    for dy in 0..scale {
                        for dx in 0..scale {
                            let x = 20 + (index as u32 * 6 + column as u32) * scale + dx;
                            let y = 20 + row as u32 * scale + dy;
                            let i = ((y * width + x) * 4) as usize;
                            rgba[i..i + 3].copy_from_slice(&[0, 0, 0]);
                        }
                    }
                }
            }
        }
        (width, height, rgba)
    }
}
