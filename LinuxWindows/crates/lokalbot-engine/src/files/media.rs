//! Pictures, sound and video for the model (`ImageExtractor`, `AudioExtractor`,
//! `VideoExtractor`, `Platform/Portable`).
//!
//! Pictures decode here (JPEG, PNG, GIF, BMP, TIFF, WebP, TGA, PNM); HEIC and AVIF
//! go through ffmpeg when it's installed. Sound decodes through Symphonia, which
//! the meeting pipeline already uses (MP3, AAC, FLAC, Ogg Vorbis, WAV, AIFF, CAF,
//! MP4, MKV), with ffmpeg as the fallback for the rest. A video's frames need
//! ffmpeg: without it a video is read for its sound and its name only, and
//! Settings says so.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use lokalbot_audio::CompressedReader;

use super::documents::ReadError;
use super::image_sizing::Rgb;

const SAMPLE_RATE: f64 = 16_000.0;
/// ≈ −50 dBFS: silence isn't worth a vector.
const SILENCE_RMS: f64 = 0.003;
/// The tail of a file must add at least this much.
const MINIMUM_SECONDS: f64 = 2.0;

/// One piece of sound, or one kept frame.
#[derive(Clone, Debug, PartialEq)]
pub struct MediaPiece {
    pub start: f64,
    pub end: f64,
    /// A WAV for sound, a PNG-ready picture's file for a frame.
    pub bytes: Vec<u8>,
}

/// `ffmpeg` beside the app or on PATH.
pub fn ffmpeg() -> Option<PathBuf> {
    find_tool("ffmpeg")
}

fn ffprobe() -> Option<PathBuf> {
    find_tool("ffprobe")
}

fn find_tool(name: &str) -> Option<PathBuf> {
    let file = if cfg!(windows) {
        format!("{name}.exe")
    } else {
        name.to_string()
    };
    if let Some(found) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join(&file)))
        .filter(|candidate| candidate.is_file())
    {
        return Some(found);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(&file))
        .find(|candidate| candidate.is_file())
}

fn tool_command(tool: &Path) -> Command {
    let mut command = Command::new(tool);
    command
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .stdout(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    command
}

fn tool_output(tool: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let output = tool_command(tool).args(args).output().ok()?;
    output.status.success().then_some(output.stdout)
}

// ----------------------------------------------------------------- pictures

/// A picture decoded and turned the way the camera held it, and its date.
pub struct DecodedImage {
    pub image: Rgb,
    /// Its size as shown.
    pub width: usize,
    pub height: usize,
    /// EXIF `DateTimeOriginal`, as written by the camera.
    pub taken: Option<String>,
}

pub enum ImageFailure {
    TooSmall(usize, usize),
    Unreadable(String),
}

impl std::fmt::Display for ImageFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ImageFailure::TooSmall(width, height) => write!(f, "small image {width}×{height}"),
            ImageFailure::Unreadable(why) => write!(f, "unreadable: {why}"),
        }
    }
}

/// RAW isn't read yet, and says so.
fn not_read_yet(ext: &str) -> Option<String> {
    matches!(ext, "cr2" | "nef" | "arw" | "dng" | "raf" | "orf" | "rw2").then(|| {
        format!(
            "RAW pictures ({}) aren't read on this system yet",
            ext.to_uppercase()
        )
    })
}

/// Decodes a picture in full, no matter its size, then applies its orientation.
/// Pictures smaller than `min_side` on both sides aren't worth a vector.
pub fn decode_image(path: &Path, min_side: u32) -> Result<DecodedImage, ImageFailure> {
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if let Some(note) = not_read_yet(&ext) {
        return Err(ImageFailure::Unreadable(note));
    }
    let exif = read_exif(path);
    let decoded = match image::ImageReader::open(path)
        .map_err(|err| ImageFailure::Unreadable(err.to_string()))?
        .with_guessed_format()
    {
        Ok(reader) if reader.format().is_some() => reader
            .decode()
            .map_err(|err| ImageFailure::Unreadable(err.to_string()))
            .map(|image| image.to_rgb8()),
        _ => decode_with_ffmpeg(path, &ext),
    };
    let decoded = match decoded {
        Ok(image) => image,
        Err(_) if matches!(ext.as_str(), "heic" | "heif" | "avif" | "psd") => {
            decode_with_ffmpeg(path, &ext)?
        }
        Err(err) => return Err(err),
    };
    let (width, height) = (decoded.width() as usize, decoded.height() as usize);
    if (width.max(height) as u32) < min_side {
        return Err(ImageFailure::TooSmall(width, height));
    }
    let image = Rgb {
        width,
        height,
        pixels: decoded.into_raw(),
    };
    let image = oriented(image, exif.as_ref().map_or(1, |e| e.orientation));
    Ok(DecodedImage {
        width: image.width,
        height: image.height,
        taken: exif.and_then(|e| e.date_time_original),
        image,
    })
}

fn decode_with_ffmpeg(path: &Path, ext: &str) -> Result<image::RgbImage, ImageFailure> {
    let Some(tool) = ffmpeg() else {
        return Err(ImageFailure::Unreadable(format!(
            "ffmpeg isn't installed ({} pictures need it)",
            ext.to_uppercase()
        )));
    };
    let file = path.to_string_lossy();
    let bytes = tool_output(
        &tool,
        &[
            "-v",
            "error",
            "-nostdin",
            "-i",
            &file,
            "-frames:v",
            "1",
            "-pix_fmt",
            "rgb24",
            "-f",
            "image2pipe",
            "-c:v",
            "ppm",
            "-",
        ],
    )
    .ok_or_else(|| ImageFailure::Unreadable("can't decode image".into()))?;
    image::load_from_memory_with_format(&bytes, image::ImageFormat::Pnm)
        .map(|image| image.to_rgb8())
        .map_err(|_| ImageFailure::Unreadable("can't decode image".into()))
}

/// Turned the way the camera held it (EXIF orientation 1–8).
fn oriented(image: Rgb, orientation: u16) -> Rgb {
    if !(2..=8).contains(&orientation) {
        return image;
    }
    let (width, height) = (image.width, image.height);
    let swaps = orientation >= 5;
    let (w, h) = if swaps {
        (height, width)
    } else {
        (width, height)
    };
    let mut out = vec![0u8; image.pixels.len()];
    for y in 0..h {
        for x in 0..w {
            let (sx, sy) = match orientation {
                2 => (width - 1 - x, y),
                3 => (width - 1 - x, height - 1 - y),
                4 => (x, height - 1 - y),
                5 => (y, x),
                6 => (y, height - 1 - x),
                7 => (width - 1 - y, height - 1 - x),
                _ => (width - 1 - y, x),
            };
            let (s, d) = ((sy * width + sx) * 3, (y * w + x) * 3);
            out[d..d + 3].copy_from_slice(&image.pixels[s..s + 3]);
        }
    }
    Rgb {
        width: w,
        height: h,
        pixels: out,
    }
}

// --------------------------------------------------------------------- exif

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Exif {
    pub orientation: u16,
    pub date_time_original: Option<String>,
}

/// The two EXIF facts the indexer wants (`EXIF`), from a JPEG's APP1 segment, a
/// TIFF's own tags or a WebP's EXIF chunk. HEIF files are left to ffmpeg, which
/// turns them itself.
pub fn read_exif(path: &Path) -> Option<Exif> {
    use std::io::Read as _;
    let file = std::fs::File::open(path).ok()?;
    let mut head = Vec::new();
    // Headers come first in JPEG and most TIFFs; WebP's chunk may trail, but a
    // photo's vector doesn't depend on it.
    file.take(1 << 20).read_to_end(&mut head).ok()?;
    exif_from_bytes(&head)
}

fn exif_from_bytes(bytes: &[u8]) -> Option<Exif> {
    if bytes.len() < 12 {
        return None;
    }
    if bytes[0] == 0xFF && bytes[1] == 0xD8 {
        return jpeg_exif(bytes);
    }
    if bytes.starts_with(&[0x49, 0x49, 0x2A, 0x00]) || bytes.starts_with(&[0x4D, 0x4D, 0x00, 0x2A])
    {
        return parse_tiff(bytes);
    }
    if bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
        return webp_exif(bytes);
    }
    None
}

fn jpeg_exif(bytes: &[u8]) -> Option<Exif> {
    let mut i = 2;
    while i + 4 <= bytes.len() && bytes[i] == 0xFF {
        let marker = bytes[i + 1];
        if marker == 0xD8 || marker == 0x01 || (0xD0..=0xD7).contains(&marker) {
            i += 2;
            continue;
        }
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        let length = u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        if length < 2 {
            return None;
        }
        if marker == 0xE1 && bytes.get(i + 4..i + 10) == Some(b"Exif\0\0") {
            let end = (i + 2 + length).min(bytes.len());
            return parse_tiff(&bytes[i + 10..end]);
        }
        i += 2 + length;
    }
    None
}

fn webp_exif(bytes: &[u8]) -> Option<Exif> {
    let mut i = 12;
    while i + 8 <= bytes.len() {
        let size = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().ok()?) as usize;
        let start = i + 8;
        let end = start.checked_add(size)?;
        if &bytes[i..i + 4] == b"EXIF" {
            let chunk = bytes.get(start..end.min(bytes.len()))?;
            let chunk = chunk.strip_prefix(b"Exif\0\0").unwrap_or(chunk);
            return parse_tiff(chunk);
        }
        i = end + (size & 1);
    }
    None
}

fn parse_tiff(tiff: &[u8]) -> Option<Exif> {
    let little = match tiff.get(0..2)? {
        [0x49, 0x49] => true,
        [0x4D, 0x4D] => false,
        _ => return None,
    };
    let u16_at = |at: usize| -> Option<usize> {
        let b = tiff.get(at..at + 2)?;
        Some(if little {
            u16::from_le_bytes([b[0], b[1]]) as usize
        } else {
            u16::from_be_bytes([b[0], b[1]]) as usize
        })
    };
    let u32_at = |at: usize| -> Option<usize> {
        let b = tiff.get(at..at + 4)?;
        Some(if little {
            u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize
        } else {
            u32::from_be_bytes([b[0], b[1], b[2], b[3]]) as usize
        })
    };
    let entries = |at: usize| -> Vec<(usize, usize, usize, usize)> {
        let count = u16_at(at).unwrap_or(0).min(500);
        (0..count)
            .map_while(|n| {
                let entry = at + 2 + n * 12;
                Some((
                    u16_at(entry)?,
                    u16_at(entry + 2)?,
                    u32_at(entry + 4)?,
                    entry + 8,
                ))
            })
            .collect()
    };
    let mut exif = Exif {
        orientation: 1,
        date_time_original: None,
    };
    let mut exif_ifd = None;
    for (tag, kind, _, at) in entries(u32_at(4)?) {
        if tag == 0x0112 && kind == 3 {
            exif.orientation = u16_at(at).unwrap_or(1) as u16;
        }
        if tag == 0x8769 && kind == 4 {
            exif_ifd = u32_at(at);
        }
    }
    if let Some(ifd) = exif_ifd {
        for (tag, kind, count, at) in entries(ifd) {
            if tag == 0x9003 && kind == 2 && count >= 19 {
                exif.date_time_original = u32_at(at)
                    .and_then(|offset| tiff.get(offset..offset + 19))
                    .map(|text| String::from_utf8_lossy(text).into_owned());
            }
        }
    }
    Some(exif)
}

// -------------------------------------------------------------------- sound

/// A stream of 16 kHz mono samples.
enum SoundSource {
    Decoder(Box<CompressedReader>),
    Pipe(std::process::Child),
}

impl SoundSource {
    /// Symphonia first; ffmpeg for what it doesn't read (Opus, AVI, WMA).
    fn open(path: &Path) -> Result<Self, ReadError> {
        if let Ok(reader) = CompressedReader::open(path) {
            return Ok(Self::Decoder(Box::new(reader)));
        }
        let Some(tool) = ffmpeg() else {
            return Err(ReadError::Unreadable(
                "this kind of recording needs ffmpeg, which isn't installed".into(),
            ));
        };
        let child = tool_command(&tool)
            .args(["-v", "error", "-nostdin", "-i"])
            .arg(path)
            .args(["-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "-"])
            .spawn()
            .map_err(|err| ReadError::Unreadable(err.to_string()))?;
        Ok(Self::Pipe(child))
    }

    /// Up to `max` samples; 0 at the end.
    fn read(&mut self, max: usize, out: &mut Vec<f32>) -> Result<usize, ReadError> {
        match self {
            Self::Decoder(reader) => reader
                .read_mono(max, out)
                .map_err(|err| ReadError::Unreadable(err.to_string())),
            Self::Pipe(child) => {
                use std::io::Read as _;
                let Some(stdout) = child.stdout.as_mut() else {
                    return Ok(0);
                };
                let mut bytes = vec![0u8; max * 2];
                let mut filled = 0;
                while filled < bytes.len() {
                    match stdout.read(&mut bytes[filled..]) {
                        Ok(0) => break,
                        Ok(read) => filled += read,
                        Err(err) => return Err(ReadError::Unreadable(err.to_string())),
                    }
                }
                filled -= filled % 2;
                out.extend(
                    bytes[..filled]
                        .as_chunks::<2>()
                        .0
                        .iter()
                        .map(|b| i16::from_le_bytes(*b) as f32 / 32768.0),
                );
                Ok(filled / 2)
            }
        }
    }

    fn finish(self) {
        if let Self::Pipe(mut child) = self {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn rms(samples: &[f32]) -> f64 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples.iter().map(|s| (*s as f64) * (*s as f64)).sum();
    (sum / samples.len() as f64).sqrt()
}

/// Sound cut into `window`-second pieces `hop` seconds apart, skipping silent
/// ones; one model input ignores anything past 30 s. Memory stays at one window
/// plus the pieces that are ready, and `on_piece` takes each away as it comes.
pub fn sound_windows(
    path: &Path,
    window: f64,
    hop: f64,
    on_piece: &mut dyn FnMut(MediaPiece) -> bool,
) -> Result<f64, ReadError> {
    let mut source = SoundSource::open(path)?;
    let window_samples = (window * SAMPLE_RATE) as usize;
    let hop_samples = (hop * SAMPLE_RATE) as usize;
    let mut buffer: Vec<f32> = Vec::with_capacity(window_samples * 2);
    let mut offset = 0usize;
    let mut emit = |samples: &[f32], offset: usize| -> bool {
        if rms(samples) <= SILENCE_RMS {
            return true;
        }
        on_piece(MediaPiece {
            start: offset as f64 / SAMPLE_RATE,
            end: (offset + samples.len()) as f64 / SAMPLE_RATE,
            bytes: lokalbot_audio::wav_bytes(samples, SAMPLE_RATE as u32),
        })
    };
    let result = loop {
        let read = match source.read(hop_samples.max(1 << 14), &mut buffer) {
            Ok(read) => read,
            Err(err) => break Err(err),
        };
        if read == 0 {
            break Ok(());
        }
        let mut wanted = true;
        while buffer.len() >= window_samples {
            wanted = emit(&buffer[..window_samples], offset);
            buffer.drain(..hop_samples);
            offset += hop_samples;
            if !wanted {
                break;
            }
        }
        if !wanted {
            source.finish();
            return Ok((offset + buffer.len()) as f64 / SAMPLE_RATE);
        }
    };
    source.finish();
    result?;
    // The tail: new sound beyond the previous window's overlap, or the whole
    // file if it was shorter than a window.
    let covered = if offset == 0 {
        0
    } else {
        window_samples - hop_samples
    };
    if buffer.len().saturating_sub(covered) >= (MINIMUM_SECONDS * SAMPLE_RATE) as usize {
        emit(&buffer, offset);
    }
    Ok((offset + buffer.len()) as f64 / SAMPLE_RATE)
}

/// `seconds` of sound from `start`, as a WAV: the moment a search found, for the
/// assistant to hear (`FileMomentTranscriber.exportClip`). Nothing is written.
pub fn sound_clip(path: &Path, start: f64, seconds: f64) -> Option<Vec<f32>> {
    let mut source = SoundSource::open(path).ok()?;
    if let SoundSource::Decoder(reader) = &mut source {
        reader
            .seek_frame((start.max(0.0) * SAMPLE_RATE) as u64)
            .ok()?;
    } else {
        let mut skipped = Vec::new();
        let mut left = (start.max(0.0) * SAMPLE_RATE) as usize;
        while left > 0 {
            skipped.clear();
            let read = source.read(left.min(1 << 16), &mut skipped).ok()?;
            if read == 0 {
                break;
            }
            left -= read;
        }
    }
    let wanted = (seconds * SAMPLE_RATE) as usize;
    let mut out = Vec::with_capacity(wanted);
    while out.len() < wanted {
        let read = source.read(wanted - out.len(), &mut out).ok()?;
        if read == 0 {
            break;
        }
    }
    source.finish();
    (!out.is_empty()).then_some(out)
}

/// How long a recording or video plays, from its header (`MediaInfo.duration`).
pub fn duration(path: &Path) -> f64 {
    if let Ok(reader) = CompressedReader::open(path) {
        return reader.frames() as f64 / SAMPLE_RATE;
    }
    let Some(tool) = ffprobe() else {
        return 0.0;
    };
    let file = path.to_string_lossy();
    tool_output(
        &tool,
        &[
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            &file,
        ],
    )
    .and_then(|bytes| String::from_utf8_lossy(&bytes).trim().parse::<f64>().ok())
    .filter(|seconds| seconds.is_finite() && *seconds > 0.0)
    .unwrap_or(0.0)
}

// -------------------------------------------------------------------- video

/// 8×8 average hash: gray cells brighter than the mean are 1.
pub fn average_hash(image: &Rgb) -> u64 {
    const SIDE: usize = 8;
    let (width, height) = (image.width, image.height);
    let mut cells = [0usize; SIDE * SIDE];
    for cy in 0..SIDE {
        let y0 = cy * height / SIDE;
        let y1 = height.min((y0 + 1).max((cy + 1) * height / SIDE));
        for cx in 0..SIDE {
            let x0 = cx * width / SIDE;
            let x1 = width.min((x0 + 1).max((cx + 1) * width / SIDE));
            let (mut sum, mut count) = (0usize, 0usize);
            for y in y0..y1 {
                for x in x0..x1 {
                    let p = (y * width + x) * 3;
                    sum += (image.pixels[p] as usize * 299
                        + image.pixels[p + 1] as usize * 587
                        + image.pixels[p + 2] as usize * 114)
                        / 1000;
                    count += 1;
                }
            }
            cells[cy * SIDE + cx] = sum.checked_div(count).unwrap_or(0);
        }
    }
    let mean = cells.iter().sum::<usize>() / cells.len();
    cells
        .iter()
        .enumerate()
        .filter(|(_, cell)| **cell > mean)
        .fold(0u64, |hash, (index, _)| hash | (1 << index))
}

const MAX_FRAMES: f64 = 1200.0;
const FRAME_PIXELS: u32 = 1024;

/// A frame per shot, through ffmpeg: a frame every `interval` seconds, and one
/// that looks like the previous kept one (8×8 average hash within 4 bits) only
/// extends it. Frames reach `on_frame` one at a time with the second they show;
/// it returns false to stop. Nothing happens without ffmpeg.
pub fn keyframes(
    path: &Path,
    interval: f64,
    video_seconds: f64,
    scratch: &Path,
    on_frame: &mut dyn FnMut(f64, &Rgb) -> bool,
) {
    let Some(tool) = ffmpeg() else {
        return;
    };
    if video_seconds <= 0.0 || std::fs::create_dir_all(scratch).is_err() {
        return;
    }
    let step = interval.max(video_seconds / MAX_FRAMES);
    let first = 0.5f64.min(video_seconds / 2.0);
    let pattern = scratch.join("frame-%06d.jpg");
    let filter = format!(
        "fps=fps={}:start_time={first}:round=up,scale={FRAME_PIXELS}:{FRAME_PIXELS}:force_original_aspect_ratio=decrease",
        1.0 / step
    );
    let finished = tool_command(&tool)
        .args(["-v", "error", "-nostdin", "-i"])
        .arg(path)
        .args(["-an", "-vf", &filter, "-q:v", "3", "-f", "image2"])
        .arg(&pattern)
        .stdout(Stdio::null())
        .status();
    if finished.is_ok_and(|status| status.success()) {
        let mut names: Vec<PathBuf> = std::fs::read_dir(scratch)
            .map(|entries| entries.flatten().map(|entry| entry.path()).collect())
            .unwrap_or_default();
        names.sort();
        let mut last_hash = None;
        for (index, name) in names.iter().enumerate() {
            let start = first + index as f64 * step;
            if start >= video_seconds {
                break;
            }
            let Ok(image) = image::open(name).map(|image| image.to_rgb8()) else {
                continue;
            };
            let frame = Rgb {
                width: image.width() as usize,
                height: image.height() as usize,
                pixels: image.into_raw(),
            };
            let hash = average_hash(&frame);
            if last_hash.is_some_and(|last: u64| (hash ^ last).count_ones() <= 4) {
                continue;
            }
            last_hash = Some(hash);
            if !on_frame(start, &frame) {
                break;
            }
        }
    }
    let _ = std::fs::remove_dir_all(scratch);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exif_comes_from_a_jpeg_header() {
        // A little-endian TIFF block: orientation 6, and DateTimeOriginal in a
        // separate IFD.
        let mut tiff: Vec<u8> = vec![0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0];
        tiff.extend([2, 0]);
        tiff.extend([0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0]);
        tiff.extend([0x69, 0x87, 4, 0, 1, 0, 0, 0, 38, 0, 0, 0]);
        tiff.extend([0, 0, 0, 0]);
        assert_eq!(tiff.len(), 38);
        tiff.extend([1, 0]);
        tiff.extend([0x03, 0x90, 2, 0, 20, 0, 0, 0, 56, 0, 0, 0]);
        tiff.extend([0, 0, 0, 0]);
        assert_eq!(tiff.len(), 56);
        tiff.extend(b"2026:05:14 18:02:11\0");
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE1];
        let length = (tiff.len() + 8) as u16;
        jpeg.extend(length.to_be_bytes());
        jpeg.extend(b"Exif\0\0");
        jpeg.extend(&tiff);
        jpeg.extend([0xFF, 0xD9]);
        let exif = exif_from_bytes(&jpeg).unwrap();
        assert_eq!(exif.orientation, 6);
        assert_eq!(
            exif.date_time_original.as_deref(),
            Some("2026:05:14 18:02:11")
        );
        assert_eq!(exif_from_bytes(&tiff).unwrap().orientation, 6);
        assert_eq!(exif_from_bytes(b"not an image at all"), None);
    }

    #[test]
    fn orientation_turns_the_picture() {
        // 2×1: red, blue.
        let image = Rgb {
            width: 2,
            height: 1,
            pixels: vec![255, 0, 0, 0, 0, 255],
        };
        let turned = oriented(image.clone(), 6);
        assert_eq!((turned.width, turned.height), (1, 2));
        assert_eq!(&turned.pixels[..3], &[255, 0, 0]);
        assert_eq!(&turned.pixels[3..6], &[0, 0, 255]);
        let upside = oriented(image.clone(), 3);
        assert_eq!(&upside.pixels[..3], &[0, 0, 255]);
        assert_eq!(oriented(image.clone(), 1), image);
    }

    #[test]
    fn small_and_broken_pictures_say_why() {
        let dir = tempfile::tempdir().unwrap();
        let small = dir.path().join("small.png");
        image::RgbImage::new(10, 10).save(&small).unwrap();
        assert!(matches!(
            decode_image(&small, 256),
            Err(ImageFailure::TooSmall(10, 10))
        ));
        assert!(decode_image(&small, 8).is_ok());
        let raw = dir.path().join("a.cr2");
        std::fs::write(&raw, b"raw").unwrap();
        let Err(ImageFailure::Unreadable(note)) = decode_image(&raw, 8) else {
            panic!("RAW isn't read");
        };
        assert!(note.contains("RAW"));
    }

    fn write_tone(path: &Path, seconds: usize, amplitude: f32) {
        let samples: Vec<f32> = (0..seconds * 16_000)
            .map(|i| (i as f32 * 0.05).sin() * amplitude)
            .collect();
        std::fs::write(path, lokalbot_audio::wav_bytes(&samples, 16_000)).unwrap();
    }

    fn windows(path: &Path) -> (Vec<MediaPiece>, f64) {
        let mut pieces = Vec::new();
        let duration = sound_windows(path, 30.0, 25.0, &mut |piece| {
            pieces.push(piece);
            true
        })
        .unwrap();
        (pieces, duration)
    }

    #[test]
    fn sound_comes_in_overlapping_windows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.wav");
        write_tone(&path, 80, 0.5);
        let (pieces, duration) = windows(&path);
        let spans: Vec<(f64, f64)> = pieces.iter().map(|p| (p.start, p.end)).collect();
        assert_eq!(
            spans,
            [(0.0, 30.0), (25.0, 55.0), (50.0, 80.0)],
            "the tail adds nothing past the last window's overlap"
        );
        assert_eq!(duration, 80.0);
        assert!(pieces[0].bytes.starts_with(b"RIFF"));
    }

    #[test]
    fn silence_and_a_short_tail_are_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let silent = dir.path().join("silent.wav");
        write_tone(&silent, 40, 0.0);
        assert!(windows(&silent).0.is_empty());
        let short = dir.path().join("short.wav");
        write_tone(&short, 1, 0.5);
        assert!(windows(&short).0.is_empty(), "under two seconds");
        let whole = dir.path().join("whole.wav");
        write_tone(&whole, 10, 0.5);
        let (pieces, _) = windows(&whole);
        assert_eq!(pieces.len(), 1);
        assert_eq!((pieces[0].start, pieces[0].end), (0.0, 10.0));
    }

    #[test]
    fn a_clip_starts_where_it_was_asked() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.wav");
        write_tone(&path, 10, 0.5);
        let clip = sound_clip(&path, 8.0, 30.0).unwrap();
        assert_eq!(clip.len(), 2 * 16_000);
    }

    #[test]
    fn hashes_tell_a_new_shot_from_the_same_one() {
        let flat = |value: u8| Rgb {
            width: 16,
            height: 16,
            pixels: vec![value; 16 * 16 * 3],
        };
        assert_eq!(average_hash(&flat(10)), average_hash(&flat(200)));
        let mut half = flat(0);
        half.pixels[16 * 8 * 3..].fill(255);
        assert_ne!(average_hash(&half), average_hash(&flat(10)));
    }
}
