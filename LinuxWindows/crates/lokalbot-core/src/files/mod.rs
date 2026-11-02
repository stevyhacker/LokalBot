//! Files: the folders a person chooses, searched by what is in them
//! (`Services/FileSearch`, DigUp's engine: github.com/ARahim3/DigUp, MIT).
//!
//! This module holds what the app, engine and CLI share and what the Mac's
//! index needs to stay readable: the rules for what gets read, the walk, the
//! `files-index.noindex/index.sqlite` store (schema 5), keyword and meaning
//! search, and the agents' grant. Reading files and running the model are the
//! engine's (`lokalbot_engine::files`).

pub mod access;
pub mod costs;
pub mod crawler;
pub mod index;
pub mod rules;
pub mod search;
pub mod text;

use std::path::{Path, PathBuf};

use chrono::{DateTime, NaiveDateTime, TimeZone as _, Utc};

/// The index's folder in the library (`FileSearchService.indexFolderName`).
pub const INDEX_FOLDER: &str = "files-index.noindex";
/// Vectors are 768 × float16.
pub const DIMENSION: usize = 768;

pub fn index_dir(root: &Path) -> PathBuf {
    root.join(INDEX_FOLDER)
}

/// What a file is, for indexing and for grouping results.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum FileKind {
    Screenshot,
    Image,
    Pdf,
    Doc,
    Audio,
    Video,
    /// Only in DigUp's code index, which LokalBot doesn't use.
    Code,
}

impl FileKind {
    pub const ALL: [FileKind; 7] = [
        FileKind::Screenshot,
        FileKind::Image,
        FileKind::Pdf,
        FileKind::Doc,
        FileKind::Audio,
        FileKind::Video,
        FileKind::Code,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            FileKind::Screenshot => "screenshot",
            FileKind::Image => "image",
            FileKind::Pdf => "pdf",
            FileKind::Doc => "doc",
            FileKind::Audio => "audio",
            FileKind::Video => "video",
            FileKind::Code => "code",
        }
    }

    pub fn parse(raw: &str) -> Option<FileKind> {
        Self::ALL.into_iter().find(|kind| kind.as_str() == raw)
    }
}

/// The order of the first pass: what people look for most comes first.
pub(crate) const INDEXING_ORDER_SQL: &str = "CASE kind WHEN 'screenshot' THEN 0 WHEN 'image' THEN 1 \
     WHEN 'pdf' THEN 2 WHEN 'doc' THEN 3 WHEN 'audio' THEN 4 WHEN 'video' THEN 5 ELSE 6 END";

/// One searchable piece of a file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SegmentKind {
    /// File name and folder names (keyword search only).
    Name,
    Image,
    /// Text read from a screenshot.
    Ocr,
    Page,
    PageImage,
    Chunk,
    Audio,
    Frame,
}

impl SegmentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            SegmentKind::Name => "name",
            SegmentKind::Image => "image",
            SegmentKind::Ocr => "ocr",
            SegmentKind::Page => "page",
            SegmentKind::PageImage => "page_image",
            SegmentKind::Chunk => "chunk",
            SegmentKind::Audio => "audio",
            SegmentKind::Frame => "frame",
        }
    }
}

/// What made a segment's vector. Scores are centred per modality because text
/// scores higher than images or sound for the same topic.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Modality {
    None,
    Text,
    Image,
    Audio,
}

impl Modality {
    pub fn as_str(self) -> &'static str {
        match self {
            Modality::None => "none",
            Modality::Text => "text",
            Modality::Image => "image",
            Modality::Audio => "audio",
        }
    }

    pub fn parse(raw: &str) -> Modality {
        match raw {
            "text" => Modality::Text,
            "image" => Modality::Image,
            "audio" => Modality::Audio,
            _ => Modality::None,
        }
    }
}

/// Recordings and video, by extension, for when the person turns them off
/// (`FileSearchService.mediaExtensions`).
pub const MEDIA_EXTENSIONS: &[&str] = &[
    "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga",
    "opus", "wma", "amr", "mka", "ape", "ac3", "eac3", "mp4", "m4v", "mov", "qt", "avi", "mkv",
    "webm", "wmv", "flv", "mpg", "mpeg", "m2v", "mts", "m2ts", "3gp", "3g2", "ogv", "mxf", "dv",
    "vob",
];

/// Indexing settings. Anything that changes vectors is part of `fingerprint`;
/// an index never mixes settings (`IndexOptions`).
#[derive(Clone, Debug, PartialEq)]
pub struct IndexOptions {
    pub include_datasets: bool,
    pub min_image_side: u32,
    /// PDFs up to this many pages are read whole at once.
    pub big_pdf_pages: usize,
    /// Pages of a long PDF read per step.
    pub pdf_step: usize,
    /// Chunks of a long document read per step (about 64,000 characters).
    pub doc_step: usize,
    pub max_pages: usize,
    pub max_chunks: usize,
    /// Fewer characters than this: a page is embedded as a picture on the Mac.
    pub min_page_text: usize,
    pub photo_budget: u32,
    pub screenshot_budget: u32,
    pub page_budget: u32,
    pub frame_budget: u32,
    pub frame_interval: f64,
    /// The model silently ignores sound past 30 s of one input.
    pub audio_window: f64,
    pub audio_hop: f64,
    pub excluded_extensions: Vec<String>,
}

impl Default for IndexOptions {
    fn default() -> Self {
        Self {
            include_datasets: false,
            min_image_side: 256,
            big_pdf_pages: 50,
            pdf_step: 30,
            doc_step: 40,
            max_pages: 5_000,
            max_chunks: 5_000,
            min_page_text: 200,
            photo_budget: 140,
            screenshot_budget: 280,
            page_budget: 280,
            frame_budget: 70,
            frame_interval: 3.0,
            audio_window: 30.0,
            audio_hop: 25.0,
            excluded_extensions: Vec::new(),
        }
    }
}

impl IndexOptions {
    /// Turning recordings and video off excludes them by extension; the next
    /// sync then drops those already indexed.
    pub fn for_settings(includes_media: bool) -> Self {
        let mut options = Self::default();
        if !includes_media {
            options.excluded_extensions = MEDIA_EXTENSIONS.iter().map(|e| e.to_string()).collect();
        }
        options
    }

    pub fn fingerprint(&self) -> String {
        format!(
            "photo{} shot{} page{} frame{}/{:?}s audio{:?}/{:?}s",
            self.photo_budget,
            self.screenshot_budget,
            self.page_budget,
            self.frame_budget,
            self.frame_interval,
            self.audio_window,
            self.audio_hop
        )
    }
}

/// EmbeddingGemma 2's task prompts. Media inputs take no prompt.
pub fn document_prompt(title: Option<&str>, text: &str) -> String {
    let title = title.filter(|t| !t.is_empty()).unwrap_or("none");
    format!("title: {title} | text: {text}")
}

/// A file the walk decided to index.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub path: String,
    pub kind: FileKind,
    pub size: i64,
    pub mtime: f64,
    pub inode: u64,
    pub device: u64,
}

/// A file that matched a search: what Ask, Quick Recall and the agent show
/// (`FileSearchHit`).
#[derive(Clone, Debug, PartialEq)]
pub struct FileHit {
    /// The matching passage's id in the index; `[file:<id>]` cites it.
    pub id: i64,
    pub path: String,
    pub kind: FileKind,
    /// A PDF page, from 1.
    pub page: Option<i64>,
    /// Seconds into a recording or video.
    pub seconds: Option<f64>,
    /// The matched words in «», or the passage's start.
    pub excerpt: Option<String>,
    pub modified: DateTime<Utc>,
    /// When a photo was taken (EXIF), if it says.
    pub taken: Option<DateTime<Utc>>,
    pub size: i64,
    /// Found by what it means or shows, without the query's words.
    pub is_semantic: bool,
}

impl FileHit {
    pub fn name(&self) -> String {
        Path::new(&self.path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| self.path.clone())
    }

    /// The folder it lives in, with `~` for the home folder.
    pub fn folder(&self) -> String {
        let folder = Path::new(&self.path)
            .parent()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        abbreviate_home(&folder)
    }

    /// The date Ask's time scope filters on.
    pub fn date(&self) -> DateTime<Utc> {
        self.taken.unwrap_or(self.modified)
    }

    pub fn is_moment(&self) -> bool {
        matches!(self.kind, FileKind::Audio | FileKind::Video)
    }

    /// "PDF · page 3", "Recording · 00:01:15", in English for the model; the
    /// interface builds its own from the same facts.
    pub fn kind_label(&self) -> String {
        let stamp = |seconds: f64| crate::time::stamp(seconds).to_string();
        match self.kind {
            FileKind::Screenshot => "Screenshot".into(),
            FileKind::Image => "Picture".into(),
            FileKind::Pdf => match self.page {
                Some(page) => format!("PDF · page {page}"),
                None => "PDF".into(),
            },
            FileKind::Doc => "Document".into(),
            FileKind::Audio => match self.seconds {
                Some(seconds) => format!("Recording · {}", stamp(seconds)),
                None => "Recording".into(),
            },
            FileKind::Video => match self.seconds {
                Some(seconds) => format!("Video · {}", stamp(seconds)),
                None => "Video".into(),
            },
            FileKind::Code => "Code".into(),
        }
    }
}

/// `~/Documents` for a folder under the home folder.
pub fn abbreviate_home(path: &str) -> String {
    let Some(home) = home_dir() else {
        return path.to_string();
    };
    let home = home.to_string_lossy();
    match path.strip_prefix(home.as_ref()) {
        Some(rest) if rest.is_empty() || rest.starts_with(std::path::MAIN_SEPARATOR) => {
            format!("~{rest}")
        }
        _ => path.to_string(),
    }
}

pub(crate) fn home_dir() -> Option<PathBuf> {
    directories::BaseDirs::new().map(|dirs| dirs.home_dir().to_path_buf())
}

/// Whether `path` is inside `folder` (`FolderSelection.isInside`).
pub fn is_inside(path: &str, folder: &str) -> bool {
    Path::new(path).starts_with(folder)
        && path.trim_end_matches(std::path::is_separator).len()
            > folder.trim_end_matches(std::path::is_separator).len()
}

/// The path as a walk of the folder reports it, links resolved
/// (`FolderSelection.realPath`). Windows' `\\?\` prefix is left off.
pub fn real_path(path: &str) -> String {
    match std::fs::canonicalize(path) {
        Ok(real) => plain_path(&real),
        Err(_) => path.to_string(),
    }
}

/// `path` as text, without Windows' `\\?\` verbatim prefix.
pub fn plain_path(path: &Path) -> String {
    let text = path.to_string_lossy();
    match text.strip_prefix(r"\\?\") {
        Some(rest) if !rest.starts_with("UNC") => rest.to_string(),
        _ => text.into_owned(),
    }
}

/// EXIF `DateTimeOriginal`: "2026:05:14 18:02:11", in the camera's local time.
pub fn exif_date(text: &str) -> Option<DateTime<Utc>> {
    let naive = NaiveDateTime::parse_from_str(text, "%Y:%m:%d %H:%M:%S").ok()?;
    chrono::Local
        .from_local_datetime(&naive)
        .earliest()
        .map(|at| at.with_timezone(&Utc))
}

// ------------------------------------------------------------------ float16

/// `Float16(value)`: the nearest half, ties to even.
pub fn half_from_f32(value: f32) -> u16 {
    let bits = value.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exponent = ((bits >> 23) & 0xff) as i32;
    let mantissa = bits & 0x007f_ffff;
    if exponent == 0xff {
        let payload = if mantissa != 0 {
            0x0200 | (mantissa >> 13) as u16
        } else {
            0
        };
        return sign | 0x7c00 | payload;
    }
    let half_exponent = exponent - 127 + 15;
    if half_exponent >= 31 {
        return sign | 0x7c00;
    }
    if half_exponent <= 0 {
        if half_exponent < -10 {
            return sign;
        }
        let full = mantissa | 0x0080_0000;
        let shift = (14 - half_exponent) as u32;
        let round = 1u32 << (shift - 1);
        let mut out = full >> shift;
        if full & round != 0 && full & (3 * round - 1) != 0 {
            out += 1;
        }
        return sign | out as u16;
    }
    let round = 0x1000u32;
    let mut out = ((half_exponent as u32) << 10) | (mantissa >> 13);
    if mantissa & round != 0 && mantissa & (3 * round - 1) != 0 {
        out += 1;
    }
    sign | out as u16
}

pub fn f32_from_half(half: u16) -> f32 {
    let sign = ((half as u32) & 0x8000) << 16;
    let exponent = (half as u32) & 0x7c00;
    let mantissa = (half as u32) & 0x03ff;
    if exponent == 0x7c00 {
        return f32::from_bits(sign | 0x7f80_0000 | (mantissa << 13));
    }
    if exponent == 0 {
        let magnitude = mantissa as f32 * f32::from_bits(0x3380_0000);
        return if sign != 0 { -magnitude } else { magnitude };
    }
    f32::from_bits(sign | (((exponent >> 10) + 127 - 15) << 23) | (mantissa << 13))
}

/// A vector as the index stores it: little-endian float16s.
pub fn vector_blob(vector: &[f32]) -> Vec<u8> {
    vector
        .iter()
        .flat_map(|v| half_from_f32(*v).to_le_bytes())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn halves_round_like_float16() {
        for (value, bits) in [
            (0.0f32, 0x0000u16),
            (-0.0, 0x8000),
            (1.0, 0x3c00),
            (-2.0, 0xc000),
            (0.5, 0x3800),
            (65504.0, 0x7bff),
            (1e6, 0x7c00),
            (6.1035156e-5, 0x0400),
            (5.9604645e-8, 0x0001),
            (1e-9, 0x0000),
            // Ties to even: 1 + 2^-11 lies halfway between 1 and the next half.
            (1.000_488_3, 0x3c00),
        ] {
            assert_eq!(half_from_f32(value), bits, "{value}");
        }
        for value in [0.0f32, 1.0, -2.0, 0.5, 0.25, -0.125, 6.1035156e-5] {
            assert_eq!(f32_from_half(half_from_f32(value)), value);
        }
        assert_eq!(f32_from_half(0x0001), 5.9604645e-8);
        assert!(f32_from_half(0x7c00).is_infinite());
    }

    #[test]
    fn the_fingerprint_is_the_macs() {
        assert_eq!(
            IndexOptions::default().fingerprint(),
            "photo140 shot280 page280 frame70/3.0s audio30.0/25.0s"
        );
    }

    #[test]
    fn inside_means_below() {
        assert!(is_inside("/a/b/c.txt", "/a/b"));
        assert!(is_inside("/a/b/c.txt", "/a/b/"));
        assert!(!is_inside("/a/b", "/a/b"));
        assert!(!is_inside("/a/bc/d.txt", "/a/b"));
    }

    #[test]
    fn prompts_match_the_model_card() {
        assert_eq!(document_prompt(None, "y"), "title: none | text: y");
        assert_eq!(document_prompt(Some(""), "y"), "title: none | text: y");
        assert_eq!(document_prompt(Some("Doc"), "y"), "title: Doc | text: y");
    }
}
