//! On-device text recognition for screen context, the counterpart of the
//! Vision `VNRecognizeTextRequest` the Mac app runs on screenshots
//! (`ScreenshotImageProcessing.recognizeText`).
//!
//! Three engines, chosen by [`plan`] from what this computer has:
//!
//! - [ocrs](https://github.com/robertknight/ocrs), a pure-Rust engine that reads
//!   unaccented Latin letters. Its two models are pinned by size and SHA-256 and
//!   download only when the person asks, into `<library>/models/ocrs/`.
//! - Tesseract on Linux, a separate program that reads every other script. It
//!   uses the language data it already has, or pinned `tessdata_fast` files
//!   that download only when the person asks, into `<library>/models/tesseract/`.
//!   Pixels reach it over a pipe; see [`tesseract`].
//! - `Windows.Media.Ocr` on Windows, built in, with the languages installed there.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::AtomicBool;

use anyhow::{Context as _, Result};
use lokalbot_core::LibraryPaths;

use crate::download::{self, DownloadSpec};

pub mod languages;
pub mod plan;
#[cfg(not(windows))]
pub mod tesseract;
#[cfg(windows)]
pub mod windows_media;

use languages::Language;

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

/// Id the engine and the Models page use for Tesseract's language data.
pub const OCR_LANGUAGES_ID: &str = "tesseract-languages";
pub const OCR_LANGUAGES_DISPLAY_NAME: &str = "Screen text languages (Tesseract)";
/// The `tessdata_fast` files' license.
pub const OCR_LANGUAGES_LICENSE: &str = "Apache-2.0";

/// `<library>/models/tesseract`.
pub fn language_dir(paths: &LibraryPaths) -> PathBuf {
    paths.models_dir().join("tesseract")
}

fn language_path(paths: &LibraryPaths, language: &Language) -> PathBuf {
    language_dir(paths).join(format!("{}.traineddata", language.name))
}

/// This language's file is present with its pinned size and a matching digest.
fn has_language(paths: &LibraryPaths, language: &Language) -> bool {
    let path = language_path(paths, language);
    std::fs::metadata(&path).is_ok_and(|meta| meta.len() == language.size)
        && download::read_sidecar(&path).is_some_and(|d| d.eq_ignore_ascii_case(language.sha256))
}

fn language_spec(paths: &LibraryPaths, language: &Language) -> DownloadSpec {
    DownloadSpec {
        url: format!(
            "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/{}/{}.traineddata",
            languages::TESSDATA_REVISION,
            language.name
        ),
        sha256: language.sha256.to_string(),
        size: language.size,
        dest: language_path(paths, language),
    }
}

/// Any language data was downloaded.
pub fn has_language_data(paths: &LibraryPaths) -> bool {
    languages::LANGUAGES
        .iter()
        .any(|language| has_language(paths, language))
}

/// What the languages wanted here take. Some of it may already be downloaded.
pub fn languages_size() -> u64 {
    languages::wanted_here()
        .iter()
        .map(|language| language.size)
        .sum()
}

/// The languages wanted here that the library lacks. One Tesseract run reads
/// from one folder, so this counts what the system has as lacking too.
fn languages_to_download(paths: &LibraryPaths) -> Vec<&'static Language> {
    languages::wanted_here()
        .into_iter()
        .filter(|language| !has_language(paths, language))
        .collect()
}

/// Downloads the language data wanted here. `progress(done, total)` covers it all.
pub fn download_languages(
    paths: &LibraryPaths,
    cancel: &AtomicBool,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<()> {
    let needed = languages_to_download(paths);
    let total: u64 = needed.iter().map(|language| language.size).sum();
    let mut finished = 0u64;
    for language in needed {
        download::download(&language_spec(paths, language), cancel, &mut |done, _| {
            progress(finished + done, total)
        })?;
        finished += language.size;
    }
    if total > 0 {
        progress(total, total);
    }
    Ok(())
}

/// Removes every downloaded language.
pub fn delete_languages(paths: &LibraryPaths) -> std::io::Result<()> {
    match std::fs::remove_dir_all(language_dir(paths)) {
        Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(err),
        _ => Ok(()),
    }
}

/// The plan for this computer as it is now.
#[cfg(not(windows))]
fn current_plan(paths: &LibraryPaths) -> plan::Plan {
    let wanted = languages::wanted_here();
    let probe = tesseract::probe();
    let library: Vec<&'static str> = wanted
        .iter()
        .filter(|language| has_language(paths, language))
        .map(|language| language.name)
        .collect();
    plan::with_tesseract(plan::TesseractSetup {
        wanted: &wanted,
        program: probe.program.is_some(),
        system: &probe.languages,
        library: &library,
        ocrs: is_installed(paths),
    })
}

/// The plan for this computer as it is now.
#[cfg(windows)]
fn current_plan(paths: &LibraryPaths) -> plan::Plan {
    plan::with_windows(
        &languages::wanted_here(),
        &windows_media::recognizer_languages(),
        is_installed(paths),
    )
}

/// The engine reading now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum OcrBackend {
    #[default]
    None,
    Ocrs,
    Tesseract,
    Windows,
}

/// A download that would help, for the person to start.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OcrDownload {
    pub id: &'static str,
    pub bytes: u64,
}

/// What recognition can do on this computer, and what would make it do more.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OcrStatus {
    pub backend: OcrBackend,
    /// What the engine reads, by the languages' own names.
    pub reading: Vec<String>,
    /// What this app and system want that nothing here reads yet.
    pub missing: Vec<String>,
    pub download: Option<OcrDownload>,
    /// Reading `missing` needs the Tesseract program.
    pub needs_program: bool,
}

impl OcrStatus {
    /// Some engine can read now.
    pub fn is_ready(&self) -> bool {
        self.backend != OcrBackend::None
    }
}

/// What recognition can do here now. Cheap enough to ask often.
pub fn status(paths: &LibraryPaths) -> OcrStatus {
    let plan = current_plan(paths);
    let autonyms = |languages: &[&'static Language]| -> Vec<String> {
        languages.iter().map(|l| l.autonym.to_string()).collect()
    };
    let bytes = |id: &str| {
        if id == OCR_MODEL_ID {
            total_size()
        } else {
            languages_to_download(paths).iter().map(|l| l.size).sum()
        }
    };
    let mut reading = autonyms(&plan.reading);
    // A recognizer outside the pinned languages is still worth naming.
    if let (plan::Reader::Windows { tag }, true) = (&plan.reader, reading.is_empty()) {
        reading.push(tag.clone());
    }
    OcrStatus {
        backend: match plan.reader {
            plan::Reader::None => OcrBackend::None,
            plan::Reader::Ocrs => OcrBackend::Ocrs,
            plan::Reader::Tesseract { .. } => OcrBackend::Tesseract,
            plan::Reader::Windows { .. } => OcrBackend::Windows,
        },
        reading,
        missing: autonyms(&plan.missing),
        download: plan.download.map(|id| OcrDownload {
            id,
            bytes: bytes(id),
        }),
        needs_program: plan.needs_program,
    }
}

/// Some engine can read now.
pub fn is_ready(paths: &LibraryPaths) -> bool {
    current_plan(paths).reader != plan::Reader::None
}

/// Spaces between words of Chinese, Japanese or Thai, which are written without
/// them. Tesseract and Windows both put them there; the Mac's Vision doesn't, and
/// search needs the words whole. Korean does use spaces, and keeps them.
fn collapse_cjk_spaces(text: &str) -> String {
    let unspaced = |c: char| {
        matches!(c,
            '\u{0E00}'..='\u{0E7F}'   // Thai
            | '\u{3000}'..='\u{30FF}' // CJK punctuation, kana
            | '\u{3400}'..='\u{4DBF}'
            | '\u{4E00}'..='\u{9FFF}'
            | '\u{F900}'..='\u{FAFF}'
            | '\u{FF00}'..='\u{FFEF}' // Full-width forms
            | '\u{20000}'..='\u{2FFFF}')
    };
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    for (index, c) in chars.iter().enumerate() {
        if *c == ' ' {
            let before = chars[..index].iter().rev().find(|c| **c != ' ');
            let after = chars[index + 1..].iter().find(|c| **c != ' ');
            if before.is_some_and(|c| unspaced(*c)) && after.is_some_and(|c| unspaced(*c)) {
                continue;
            }
        }
        out.push(*c);
    }
    out
}

/// One recognized line and where it is in the image, in pixels.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OcrLine {
    pub text: String,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

enum Loaded {
    Ocrs(ocrs::OcrEngine),
    #[cfg(not(windows))]
    Tesseract(tesseract::Tesseract),
    #[cfg(windows)]
    Windows(windows_media::Recognizer),
}

/// A loaded recognizer, whichever engine it is. ocrs loads about 12 MB of model
/// weights, so keep one and reuse it, and ask [`Self::is_current`] whether what
/// this computer has still leads to it.
pub struct OcrEngine {
    loaded: Loaded,
    choice: plan::Reader,
    paths: LibraryPaths,
    /// ocrs, when another engine can't read this time and it is installed.
    stand_in: OnceLock<Option<ocrs::OcrEngine>>,
}

impl OcrEngine {
    /// Loads what the plan chooses, or fails when nothing here can read.
    pub fn load(paths: &LibraryPaths) -> Result<Self> {
        let choice = current_plan(paths).reader;
        let loaded = match &choice {
            plan::Reader::None => {
                anyhow::bail!("The screen text recognition model is not downloaded.")
            }
            plan::Reader::Ocrs => Loaded::Ocrs(load_ocrs(paths)?),
            #[cfg(not(windows))]
            plan::Reader::Tesseract { library, languages } => {
                let program = tesseract::probe()
                    .program
                    .context("The Tesseract program is not installed.")?;
                let tessdata = library.then(|| language_dir(paths));
                Loaded::Tesseract(tesseract::Tesseract::new(program, tessdata, languages))
            }
            #[cfg(windows)]
            plan::Reader::Windows { tag } => match windows_media::Recognizer::new(tag) {
                Ok(recognizer) => Loaded::Windows(recognizer),
                Err(err) if is_installed(paths) => {
                    log::warn!("screen text recognition: {err:#}");
                    Loaded::Ocrs(load_ocrs(paths)?)
                }
                Err(err) => return Err(err),
            },
            other => anyhow::bail!("{other:?} doesn't run on this system"),
        };
        Ok(Self {
            loaded,
            choice,
            paths: paths.clone(),
            stand_in: OnceLock::new(),
        })
    }

    /// What this computer has still leads to this engine. A download, a removal
    /// or a new language in Settings can change that.
    pub fn is_current(&self, paths: &LibraryPaths) -> bool {
        current_plan(paths).reader == self.choice
    }

    /// The text in an RGBA image, one recognized line per line, top to bottom.
    pub fn recognize(&self, rgba: &[u8], width: u32, height: u32) -> Result<String> {
        check_image(rgba, width, height)?;
        if let Some(lines) = self.read_without_ocrs(rgba, width, height)? {
            let lines: Vec<String> = lines.into_iter().map(|line| line.text).collect();
            return Ok(lines.join("\n"));
        }
        ocrs_text(
            self.ocrs().context("no engine to read with")?,
            rgba,
            width,
            height,
        )
    }

    /// The lines in an RGBA image with their places, for telling what is near
    /// a text field.
    pub fn recognize_lines(&self, rgba: &[u8], width: u32, height: u32) -> Result<Vec<OcrLine>> {
        check_image(rgba, width, height)?;
        if let Some(lines) = self.read_without_ocrs(rgba, width, height)? {
            return Ok(lines);
        }
        ocrs_lines(
            self.ocrs().context("no engine to read with")?,
            rgba,
            width,
            height,
        )
    }

    /// What Tesseract or Windows read. `None` means ocrs is to read: it is the
    /// engine, or it stands in because the engine failed.
    fn read_without_ocrs(
        &self,
        rgba: &[u8],
        width: u32,
        height: u32,
    ) -> Result<Option<Vec<OcrLine>>> {
        let read = match &self.loaded {
            Loaded::Ocrs(_) => return Ok(None),
            #[cfg(not(windows))]
            Loaded::Tesseract(engine) => engine.read(rgba, width, height),
            #[cfg(windows)]
            Loaded::Windows(engine) => engine.read(rgba, width, height),
        };
        match read {
            Ok(lines) => Ok(Some(lines)),
            Err(err) if self.ocrs().is_some() => {
                log::debug!("screen text recognition: ocrs stands in: {err:#}");
                Ok(None)
            }
            Err(err) => Err(err),
        }
    }

    fn ocrs(&self) -> Option<&ocrs::OcrEngine> {
        if let Loaded::Ocrs(engine) = &self.loaded {
            return Some(engine);
        }
        self.stand_in
            .get_or_init(|| load_ocrs(&self.paths).ok())
            .as_ref()
    }
}

/// Loads the installed ocrs models, or fails when they are not downloaded.
fn load_ocrs(paths: &LibraryPaths) -> Result<ocrs::OcrEngine> {
    anyhow::ensure!(
        is_installed(paths),
        "The screen text recognition model is not downloaded."
    );
    let load = |file: &OcrFile| -> Result<rten::Model> {
        let path = file_path(paths, file);
        rten::Model::load_file(&path).with_context(|| format!("loading {}", display_name(&path)))
    };
    ocrs::OcrEngine::new(ocrs::OcrEngineParams {
        detection_model: Some(load(&OCR_FILES[0])?),
        recognition_model: Some(load(&OCR_FILES[1])?),
        ..Default::default()
    })
}

fn check_image(rgba: &[u8], width: u32, height: u32) -> Result<()> {
    anyhow::ensure!(
        width > 0 && height > 0 && rgba.len() == width as usize * height as usize * 4,
        "the image has no pixels"
    );
    Ok(())
}

fn ocrs_text(engine: &ocrs::OcrEngine, rgba: &[u8], width: u32, height: u32) -> Result<String> {
    let source = ocrs::ImageSource::from_bytes(rgba, (width, height))?;
    let input = engine.prepare_input(source)?;
    let text = engine.get_text(&input)?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join("\n"))
}

fn ocrs_lines(
    engine: &ocrs::OcrEngine,
    rgba: &[u8],
    width: u32,
    height: u32,
) -> Result<Vec<OcrLine>> {
    use ocrs::TextItem as _;
    let source = ocrs::ImageSource::from_bytes(rgba, (width, height))?;
    let input = engine.prepare_input(source)?;
    let words = engine.detect_words(&input)?;
    let lines = engine.find_text_lines(&input, &words);
    let recognized = engine.recognize_text(&input, &lines)?;
    Ok(recognized
        .into_iter()
        .flatten()
        .filter_map(|line| {
            let text = line.to_string();
            let text = text.trim();
            if text.is_empty() {
                return None;
            }
            let rect = line.bounding_rect();
            Some(OcrLine {
                text: text.to_string(),
                x: rect.left(),
                y: rect.top(),
                width: rect.width(),
                height: rect.height(),
            })
        })
        .collect())
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// How long one window takes, for judging autocomplete's window text.
    /// `LOKALBOT_OCR_ROOT` is a scratch library the models download into;
    /// `LOKALBOT_OCR_IMAGE` is raw RGBA named `<name>-<width>x<height>.rgba`.
    #[test]
    #[ignore = "downloads the models; run by hand"]
    fn recognize_lines_timing() {
        let root = std::env::var("LOKALBOT_OCR_ROOT").unwrap();
        let image = std::path::PathBuf::from(std::env::var("LOKALBOT_OCR_IMAGE").unwrap());
        let paths = LibraryPaths::new(root);
        download(&paths, &AtomicBool::new(false), &mut |_, _| {}).unwrap();
        let started = std::time::Instant::now();
        let engine = load_ocrs(&paths).unwrap();
        println!("load: {} ms", started.elapsed().as_millis());
        let rgba = std::fs::read(&image).unwrap();
        let name = image.file_stem().unwrap().to_string_lossy().into_owned();
        let size = name.rsplit('-').next().unwrap();
        let (width, height) = size.split_once('x').unwrap();
        let (width, height): (u32, u32) = (width.parse().unwrap(), height.parse().unwrap());
        for run in 0..3 {
            let started = std::time::Instant::now();
            let lines = ocrs_lines(&engine, &rgba, width, height).unwrap();
            println!(
                "run {run}: {width}x{height}, {} lines in {} ms",
                lines.len(),
                started.elapsed().as_millis()
            );
            if run == 0 {
                for line in lines.iter().take(6) {
                    println!("  ({}, {}) {}", line.x, line.y, line.text);
                }
            }
        }
    }

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
        assert!(load_ocrs(&paths).is_err());
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

    #[test]
    fn language_pins_download_from_a_pinned_revision() {
        let paths = LibraryPaths::new("/library");
        for language in &languages::LANGUAGES {
            let spec = language_spec(&paths, language);
            assert!(download::source_refusal(&spec.url, &spec.sha256, false).is_none());
            assert!(
                spec.url.contains(languages::TESSDATA_REVISION),
                "{}",
                spec.url
            );
            assert!(
                spec.url
                    .ends_with(&format!("/{}.traineddata", language.name))
            );
            assert_eq!(
                spec.dest,
                language_dir(&paths).join(format!("{}.traineddata", language.name))
            );
        }
    }

    #[test]
    fn language_data_counts_only_with_its_pinned_size_and_digest() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        let chinese = languages::for_locale("zh-Hans").unwrap();
        assert!(!has_language_data(&paths));
        assert!(!has_language(&paths, chinese));
        std::fs::create_dir_all(language_dir(&paths)).unwrap();
        let path = language_path(&paths, chinese);
        let handle = std::fs::File::create(&path).unwrap();
        handle.set_len(chinese.size).unwrap();
        // No digest yet.
        assert!(!has_language(&paths, chinese));
        download::write_sidecar(&path, chinese.sha256).unwrap();
        assert!(has_language(&paths, chinese));
        assert!(has_language_data(&paths));
        // Another size.
        handle.set_len(chinese.size - 1).unwrap();
        assert!(!has_language(&paths, chinese));
        delete_languages(&paths).unwrap();
        assert!(!language_dir(&paths).exists());
        // Nothing left to remove is not a failure.
        delete_languages(&paths).unwrap();
    }

    #[test]
    fn asking_what_can_read_downloads_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        let status = status(&paths);
        assert_eq!(status.is_ready(), is_ready(&paths));
        // An offer at most; nothing was fetched or created to make it.
        assert!(!paths.models_dir().exists());
        assert!(!is_installed(&paths));
        assert!(!has_language_data(&paths));
    }

    #[test]
    fn an_image_of_the_wrong_size_is_refused() {
        assert!(check_image(&[0; 4], 1, 1).is_ok());
        assert!(check_image(&[0; 4], 2, 1).is_err());
        assert!(check_image(&[], 0, 0).is_err());
    }

    #[test]
    fn spaces_go_only_between_unspaced_scripts() {
        for (spaced, joined) in [
            ("项 目 笔 记", "项目笔记"),
            ("季度 审查 ， 改到", "季度审查，改到"),
            ("受信 トレイ", "受信トレイ"),
            ("ไทย ภาษา", "ไทยภาษา"),
            // Latin next to Han keeps its space, as does Korean.
            ("使用 Rust 编写", "使用 Rust 编写"),
            ("한국어 문서", "한국어 문서"),
            ("plain english text", "plain english text"),
            ("项目  笔记", "项目笔记"),
            ("", ""),
        ] {
            assert_eq!(collapse_cjk_spaces(spaced), joined);
        }
    }

    /// Downloads the real models (about 12 MB) and reads rendered text.
    #[test]
    #[ignore = "downloads the OCR models"]
    fn reads_rendered_text() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        download(&paths, &AtomicBool::new(false), &mut |_, _| {}).unwrap();
        let engine = load_ocrs(&paths).unwrap();
        let (width, height, rgba) = banner();
        let text = ocrs_text(&engine, &rgba, width, height)
            .unwrap()
            .to_uppercase();
        // The blocky test font's K can read as E.
        assert!(text.starts_with("LO") && text.ends_with("ALBOT"), "{text}");
    }

    /// "LOKALBOT" in a 5×7 bitmap font, scaled up, black on white.
    pub(crate) fn banner() -> (u32, u32, Vec<u8>) {
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
