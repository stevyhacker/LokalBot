//! Meeting tracks in any format the library selects, read as the 16 kHz mono
//! stream the WAV tracks this app records give. A library recorded on macOS
//! keeps AAC in `mic.m4a`/`system.m4a`; FLAC tracks read the same way.
//! Symphonia decodes them. It does not trim the priming an AAC encoder adds,
//! so that happens here, from the MP4's edit list or the `iTunSMPB` tag
//! AVFoundation writes instead, as AVFoundation does on macOS: transcript
//! times then line up with the audio on both platforms.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions};
use symphonia::core::errors::Error;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::Timestamp;

use crate::resample::Resampler;
use crate::wav::{SAMPLE_RATE, WavReader};

/// Source frames decoded and dropped before a seek target. AAC frames
/// overlap, so a frame only decodes right after the one before it.
const PRE_ROLL: u64 = 2048;
/// An MP4 header larger than this is not read for its edit list.
const MAX_MOOV_BYTES: u64 = 64 << 20;

/// A meeting track as mono samples: WAV as recorded, anything else decoded
/// to 16 kHz.
pub enum TrackReader {
    Wav(WavReader),
    Compressed(Box<CompressedReader>),
}

impl TrackReader {
    /// WAV by its extension; any other file goes to the decoder.
    pub fn open(path: &Path) -> io::Result<Self> {
        let wav = path
            .extension()
            .is_some_and(|e| e.eq_ignore_ascii_case("wav"));
        if wav {
            WavReader::open(path).map(Self::Wav)
        } else {
            CompressedReader::open(path).map(|reader| Self::Compressed(Box::new(reader)))
        }
    }

    /// The rate `read_mono` returns: a WAV file's own, 16 kHz otherwise.
    pub fn sample_rate(&self) -> u32 {
        match self {
            Self::Wav(reader) => reader.info().sample_rate,
            Self::Compressed(_) => SAMPLE_RATE,
        }
    }

    pub fn frames(&self) -> u64 {
        match self {
            Self::Wav(reader) => reader.info().frames(),
            Self::Compressed(reader) => reader.frames(),
        }
    }

    pub fn duration_seconds(&self) -> f64 {
        self.frames() as f64 / self.sample_rate() as f64
    }

    pub fn seek_frame(&mut self, frame: u64) -> io::Result<()> {
        match self {
            Self::Wav(reader) => reader.seek_frame(frame),
            Self::Compressed(reader) => reader.seek_frame(frame),
        }
    }

    /// Appends up to `max_frames` samples to `out`; fewer only at the end.
    pub fn read_mono(&mut self, max_frames: usize, out: &mut Vec<f32>) -> io::Result<usize> {
        match self {
            Self::Wav(reader) => reader.read_mono(max_frames, out),
            Self::Compressed(reader) => reader.read_mono(max_frames, out),
        }
    }
}

/// An AAC or FLAC track decoded to 16 kHz mono, resampled when the file has
/// another rate.
pub struct CompressedReader {
    path: PathBuf,
    stream: Stream,
    /// Encoder priming at the start of the stream, in source frames.
    delay: u64,
    /// Source frames that play after the priming.
    playable: u64,
    /// The track's length at 16 kHz.
    frames: u64,
    /// The next frame `read_mono` returns, at 16 kHz.
    position: u64,
    /// Source frames before this one are dropped: the priming, or a seek's
    /// pre-roll.
    skip_until: u64,
    resampler: Option<Resampler>,
    /// Decoded 16 kHz samples, `taken` of them already returned.
    pending: Vec<f32>,
    taken: usize,
    ended: bool,
    interleaved: Vec<f32>,
    mono: Vec<f32>,
}

impl CompressedReader {
    pub fn open(path: &Path) -> io::Result<Self> {
        Self::open_track(path, None)
    }

    /// One audio track of a file with several, such as a screen recording's
    /// microphone and system audio; `None` is the default track.
    pub fn open_track(path: &Path, track: Option<u32>) -> io::Result<Self> {
        let stream = Stream::open(path, track)?;
        let rate = stream.rate;
        // The MP4 edit list read here describes the first audio track.
        let edit = (is_mp4(path) && (track.is_none() || stream.is_default))
            .then(|| mp4_edit(path, rate))
            .flatten();
        let delay = edit.map_or(0, |edit| edit.delay);
        let total = match stream.total {
            Some(total) => total,
            None => count_frames(path, stream.track_id)?,
        };
        let available = total.saturating_sub(delay);
        let playable = edit
            .and_then(|edit| edit.playable)
            .map_or(available, |playable| playable.min(available));
        Ok(Self {
            path: path.to_owned(),
            stream,
            delay,
            playable,
            frames: to_output(playable, rate),
            position: 0,
            skip_until: delay,
            resampler: resampler_for(rate),
            pending: Vec::new(),
            taken: 0,
            ended: false,
            interleaved: Vec::new(),
            mono: Vec::new(),
        })
    }

    pub fn frames(&self) -> u64 {
        self.frames
    }

    pub fn seek_frame(&mut self, frame: u64) -> io::Result<()> {
        let frame = frame.min(self.frames);
        let target = self.delay + to_source(frame, self.stream.rate);
        // A fresh reader every time: Symphonia's MP4 reader cannot seek once
        // it has read to the end, and the decoder starts clean.
        self.stream = Stream::open(&self.path, Some(self.stream.track_id))?;
        let from = target.saturating_sub(PRE_ROLL);
        if from > 0 {
            let to = SeekTo::Timestamp {
                ts: Timestamp::new(from as i64),
                track_id: self.stream.track_id,
            };
            if let Err(err) = self.stream.format.seek(SeekMode::Accurate, to) {
                // Decoding from the start reaches the target too, only slower.
                log::debug!(
                    "{}: seek failed ({err}), decoding from the start",
                    self.path.display()
                );
                self.stream = Stream::open(&self.path, Some(self.stream.track_id))?;
            }
        }
        self.skip_until = target;
        self.position = frame;
        self.resampler = resampler_for(self.stream.rate);
        self.pending.clear();
        self.taken = 0;
        self.ended = false;
        Ok(())
    }

    /// Appends up to `max_frames` samples to `out`; fewer only at the end.
    pub fn read_mono(&mut self, max_frames: usize, out: &mut Vec<f32>) -> io::Result<usize> {
        let wanted = (max_frames as u64).min(self.frames.saturating_sub(self.position)) as usize;
        let mut written = 0;
        while written < wanted {
            if self.taken == self.pending.len() {
                self.pending.clear();
                self.taken = 0;
                if !self.decode_more()? {
                    break;
                }
                continue;
            }
            let take = (wanted - written).min(self.pending.len() - self.taken);
            out.extend_from_slice(&self.pending[self.taken..self.taken + take]);
            self.taken += take;
            written += take;
        }
        self.position += written as u64;
        Ok(written)
    }

    /// Decodes until samples are pending; false once the track has no more.
    fn decode_more(&mut self) -> io::Result<bool> {
        let end = self.delay + self.playable;
        while !self.ended {
            let packet = match self.stream.format.next_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) => break,
                Err(Error::IoError(err)) if err.kind() == io::ErrorKind::UnexpectedEof => break,
                Err(err) => return Err(invalid(err)),
            };
            if packet.track_id != self.stream.track_id {
                continue;
            }
            let start = packet.pts.get().max(0) as u64;
            if start >= end {
                break;
            }
            self.mono.clear();
            match self.stream.decoder.decode(&packet) {
                Ok(decoded) => {
                    let channels = decoded.spec().channels().count().max(1);
                    decoded.copy_to_vec_interleaved(&mut self.interleaved);
                    self.mono.extend(
                        self.interleaved
                            .chunks_exact(channels)
                            .map(|frame| frame.iter().sum::<f32>() / channels as f32),
                    );
                }
                // A damaged packet passes as silence, so the tracks stay in step.
                Err(Error::DecodeError(reason)) => {
                    log::debug!("{}: damaged packet: {reason}", self.path.display());
                    self.mono.resize(packet.dur.get() as usize, 0.0);
                }
                Err(err) => return Err(invalid(err)),
            }
            self.keep(start, end);
            if self.taken < self.pending.len() {
                return Ok(true);
            }
        }
        if !self.ended {
            self.ended = true;
            if let Some(resampler) = self.resampler.as_mut() {
                resampler.flush(&mut self.pending);
            }
        }
        Ok(self.taken < self.pending.len())
    }

    /// Moves the decoded source frames in `skip_until..end` into `pending`.
    fn keep(&mut self, start: u64, end: u64) {
        let len = self.mono.len() as u64;
        let from = self.skip_until.saturating_sub(start).min(len) as usize;
        let to = end.saturating_sub(start).min(len) as usize;
        if from >= to {
            return;
        }
        let kept = &self.mono[from..to];
        match self.resampler.as_mut() {
            Some(resampler) => resampler.process(kept, &mut self.pending),
            None => self.pending.extend_from_slice(kept),
        }
    }
}

/// An open demuxer and decoder for one file's audio track.
struct Stream {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn AudioDecoder>,
    track_id: u32,
    /// The container's default audio track.
    is_default: bool,
    rate: u32,
    /// Frames in the stream, priming included, when the container says.
    total: Option<u64>,
}

fn probe(path: &Path) -> io::Result<Box<dyn FormatReader>> {
    let source = MediaSourceStream::new(Box::new(File::open(path)?), Default::default());
    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(extension);
    }
    symphonia::default::get_probe()
        .probe(
            &hint,
            source,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(invalid)
}

/// The IDs of a file's audio tracks that can be decoded, the default first.
/// Commentary and described-video tracks are left out.
pub fn audio_track_ids(path: &Path) -> io::Result<Vec<u32>> {
    use symphonia::core::formats::TrackFlags;
    let format = probe(path)?;
    let default = format.default_track(TrackType::Audio).map(|t| t.id);
    let codecs = symphonia::default::get_codecs();
    let mut ids: Vec<u32> = format
        .tracks()
        .iter()
        .filter(|track| {
            !track.flags.intersects(
                TrackFlags::COMMENTARY
                    | TrackFlags::VISUALLY_IMPAIRED
                    | TrackFlags::TEXT_DESCRIPTIONS,
            )
        })
        .filter(|track| {
            track
                .codec_params
                .as_ref()
                .and_then(|params| params.audio())
                .is_some_and(|params| {
                    params.sample_rate.is_some_and(|rate| rate > 0)
                        && codecs
                            .make_audio_decoder(params, &AudioDecoderOptions::default())
                            .is_ok()
                })
        })
        .map(|track| track.id)
        .collect();
    ids.sort_by_key(|id| Some(*id) != default);
    Ok(ids)
}

impl Stream {
    fn open(path: &Path, track: Option<u32>) -> io::Result<Self> {
        let format = probe(path)?;
        let default = format.default_track(TrackType::Audio).map(|t| t.id);
        let (track_id, rate, total, decoder) = {
            let track = match track {
                Some(id) => format.tracks().iter().find(|t| t.id == id),
                None => format.default_track(TrackType::Audio),
            }
            .ok_or_else(|| invalid("no audio track"))?;
            let params = track
                .codec_params
                .as_ref()
                .and_then(|params| params.audio())
                .ok_or_else(|| invalid("not an audio track"))?;
            let rate = params
                .sample_rate
                .filter(|rate| *rate > 0)
                .ok_or_else(|| invalid("no sample rate"))?;
            let decoder = symphonia::default::get_codecs()
                .make_audio_decoder(params, &AudioDecoderOptions::default())
                .map_err(invalid)?;
            (track.id, rate, track.num_frames, decoder)
        };
        Ok(Self {
            format,
            decoder,
            track_id,
            is_default: Some(track_id) == default,
            rate,
            total,
        })
    }
}

/// Frames in a stream whose container doesn't say, from its packets.
fn count_frames(path: &Path, track: u32) -> io::Result<u64> {
    let mut stream = Stream::open(path, Some(track))?;
    let mut frames = 0;
    loop {
        match stream.format.next_packet() {
            Ok(Some(packet)) if packet.track_id == stream.track_id => {
                frames = frames.max(packet.pts.get().max(0) as u64 + packet.dur.get());
            }
            Ok(Some(_)) => {}
            Ok(None) => return Ok(frames),
            Err(Error::IoError(err)) if err.kind() == io::ErrorKind::UnexpectedEof => {
                return Ok(frames);
            }
            Err(err) => return Err(invalid(err)),
        }
    }
}

fn resampler_for(rate: u32) -> Option<Resampler> {
    (rate != SAMPLE_RATE).then(|| Resampler::new(rate, SAMPLE_RATE))
}

fn to_output(source_frames: u64, rate: u32) -> u64 {
    scale(source_frames, rate, SAMPLE_RATE)
}

fn to_source(frames: u64, rate: u32) -> u64 {
    scale(frames, SAMPLE_RATE, rate)
}

fn scale(value: u64, from: u32, to: u32) -> u64 {
    if from == to || from == 0 {
        return value;
    }
    (value as u128 * to as u128 / from as u128) as u64
}

fn invalid(err: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, err.to_string())
}

// ------------------------------------------------------------ MP4 gapless info

/// Where an MP4 audio track's sound starts and how long it plays, in source
/// frames.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Edit {
    /// Encoder priming to skip.
    delay: u64,
    playable: Option<u64>,
}

fn is_mp4(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| {
        ["m4a", "mp4", "m4b", "mov"]
            .iter()
            .any(|x| e.eq_ignore_ascii_case(x))
    })
}

/// The audio track's gapless info: its edit list, or Apple's `iTunSMPB` tag.
/// `None` leaves the stream untrimmed.
fn mp4_edit(path: &Path, rate: u32) -> Option<Edit> {
    let moov = read_moov(path)?;
    edit_list(&moov, rate).or_else(|| itunes_gapless(&moov))
}

/// The first audio track's edit list (`moov/trak/edts/elst`).
fn edit_list(moov: &[u8], rate: u32) -> Option<Edit> {
    let movie_scale = timescale(child(moov, b"mvhd")?)?;
    for (kind, trak) in boxes(moov) {
        if &kind != b"trak" {
            continue;
        }
        let Some(mdia) = child(trak, b"mdia") else {
            continue;
        };
        if child(mdia, b"hdlr").and_then(|hdlr| hdlr.get(8..12)) != Some(b"soun".as_slice()) {
            continue;
        }
        let media_scale = timescale(child(mdia, b"mdhd")?)?;
        let (segment, media_time) = first_edit(child(child(trak, b"edts")?, b"elst")?)?;
        return Some(Edit {
            delay: scale(media_time, media_scale, rate),
            playable: (segment > 0).then(|| scale(segment, movie_scale, rate)),
        });
    }
    None
}

/// Apple's gapless tag, which AVFoundation writes for AAC in place of an edit
/// list: a `----` item named `iTunSMPB` under `moov/udta/meta/ilst`, holding
/// hex fields (reserved, priming, padding, frames that play, ...).
fn itunes_gapless(moov: &[u8]) -> Option<Edit> {
    let meta = child(moov, b"udta")
        .and_then(|udta| child(udta, b"meta"))
        .or_else(|| child(moov, b"meta"))?;
    // `meta` is a full box: its version and flags come before the children.
    let ilst = child(meta.get(4..)?, b"ilst").or_else(|| child(meta, b"ilst"))?;
    for (kind, item) in boxes(ilst) {
        if &kind != b"----"
            || child(item, b"name").and_then(|name| name.get(4..)) != Some(b"iTunSMPB".as_slice())
        {
            continue;
        }
        // The value follows a type indicator and a locale.
        let text = std::str::from_utf8(child(item, b"data")?.get(8..)?).ok()?;
        let fields = text
            .split_whitespace()
            .map(|field| u64::from_str_radix(field, 16).ok())
            .collect::<Option<Vec<u64>>>()?;
        let valid = *fields.get(3)?;
        return Some(Edit {
            delay: *fields.get(1)?,
            playable: (valid > 0).then_some(valid),
        });
    }
    None
}

/// The body of the top-level `moov` box, wherever it sits in the file.
/// When an MP4 or QuickTime file says it was recorded: the movie header's
/// creation time, which `AVAsset.creationDate` reports on macOS. Zero
/// means unset.
pub fn mp4_creation_time(path: &Path) -> Option<std::time::SystemTime> {
    if !is_mp4(path) {
        return None;
    }
    let moov = read_moov(path)?;
    let mvhd = child(&moov, b"mvhd")?;
    let version = *mvhd.first()?;
    let seconds = if version == 1 {
        u64::from_be_bytes(mvhd.get(4..12)?.try_into().ok()?)
    } else {
        u64::from(u32::from_be_bytes(mvhd.get(4..8)?.try_into().ok()?))
    };
    // Seconds since 1904-01-01 UTC.
    let unix = seconds.checked_sub(2_082_844_800).filter(|_| seconds > 0)?;
    Some(std::time::UNIX_EPOCH + std::time::Duration::from_secs(unix))
}

fn read_moov(path: &Path) -> Option<Vec<u8>> {
    let mut file = File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let mut at = 0u64;
    while at + 8 <= len {
        file.seek(SeekFrom::Start(at)).ok()?;
        let mut header = [0u8; 16];
        file.read_exact(&mut header[..8]).ok()?;
        let (head, size) = match u32::from_be_bytes(header[..4].try_into().ok()?) {
            0 => (8, len - at),
            1 => {
                file.read_exact(&mut header[8..]).ok()?;
                (16, u64::from_be_bytes(header[8..].try_into().ok()?))
            }
            size => (8, size as u64),
        };
        if size < head || at + size > len {
            return None;
        }
        if &header[4..8] == b"moov" {
            if size - head > MAX_MOOV_BYTES {
                return None;
            }
            let mut body = vec![0u8; (size - head) as usize];
            file.read_exact(&mut body).ok()?;
            return Some(body);
        }
        at += size;
    }
    None
}

/// The boxes directly inside `data`, as (type, body).
fn boxes(data: &[u8]) -> impl Iterator<Item = ([u8; 4], &[u8])> {
    let mut rest = data;
    std::iter::from_fn(move || {
        let kind: [u8; 4] = rest.get(4..8)?.try_into().ok()?;
        let (head, size) = match u32::from_be_bytes(rest.get(..4)?.try_into().ok()?) {
            0 => (8, rest.len()),
            1 => (
                16,
                usize::try_from(u64::from_be_bytes(rest.get(8..16)?.try_into().ok()?)).ok()?,
            ),
            size => (8, size as usize),
        };
        if size < head || size > rest.len() {
            return None;
        }
        let body = &rest[head..size];
        rest = &rest[size..];
        Some((kind, body))
    })
}

fn child<'a>(data: &'a [u8], kind: &[u8; 4]) -> Option<&'a [u8]> {
    boxes(data).find(|(k, _)| k == kind).map(|(_, body)| body)
}

/// The timescale of an `mvhd` or `mdhd` box.
fn timescale(body: &[u8]) -> Option<u32> {
    let at = if *body.first()? == 1 { 20 } else { 12 };
    Some(u32::from_be_bytes(body.get(at..at + 4)?.try_into().ok()?)).filter(|scale| *scale > 0)
}

/// The first edit that plays media, as (segment duration in the movie's
/// timescale, media time in the track's). An empty edit (media time -1) only
/// delays the presentation, so it is passed over.
fn first_edit(elst: &[u8]) -> Option<(u64, u64)> {
    let version = *elst.first()?;
    let count = u32::from_be_bytes(elst.get(4..8)?.try_into().ok()?) as usize;
    let entry = if version == 1 { 20 } else { 12 };
    for index in 0..count {
        let at = 8 + index * entry;
        let bytes = elst.get(at..at + entry)?;
        let (segment, media_time) = if version == 1 {
            (
                u64::from_be_bytes(bytes[..8].try_into().ok()?),
                i64::from_be_bytes(bytes[8..16].try_into().ok()?),
            )
        } else {
            (
                u32::from_be_bytes(bytes[..4].try_into().ok()?) as u64,
                i32::from_be_bytes(bytes[4..8].try_into().ok()?) as i64,
            )
        };
        if media_time >= 0 {
            return Some((segment, media_time as u64));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A track the macOS app recorded: AAC-LC, mono, 16 kHz, 140 s, with
    /// 2112 frames of encoder priming and 448 of padding around it.
    fn macos_track() -> Option<PathBuf> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(
            "../../../LokalBotTests/Fixtures/upgrade/0.10.9/library/meetings/2026/10/17-design-review/mic.m4a",
        );
        if path.is_file() {
            Some(path)
        } else {
            eprintln!("fixture missing at {}", path.display());
            None
        }
    }

    fn read_all(reader: &mut TrackReader) -> Vec<f32> {
        let mut samples = Vec::new();
        while reader.read_mono(10_000, &mut samples).unwrap() > 0 {}
        samples
    }

    #[test]
    fn reads_the_gapless_tag_of_a_macos_recording() {
        let Some(path) = macos_track() else { return };
        assert_eq!(
            mp4_edit(&path, 16_000),
            Some(Edit {
                delay: 2112,
                playable: Some(2_240_000)
            })
        );
    }

    fn mp4_box(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut out = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        out.extend_from_slice(kind);
        out.extend_from_slice(body);
        out
    }

    /// A version 0 `mvhd`/`mdhd` body with the given timescale.
    fn header_box(timescale: u32) -> Vec<u8> {
        let mut body = vec![0u8; 12];
        body.extend_from_slice(&timescale.to_be_bytes());
        body.extend_from_slice(&[0u8; 8]);
        body
    }

    #[test]
    fn reads_an_edit_list_in_the_movie_and_track_timescales() {
        let hdlr = [&[0u8; 8][..], b"soun", &[0u8; 12]].concat();
        let mut elst = vec![0, 0, 0, 0, 0, 0, 0, 2];
        // An empty edit first, then 140 s (ms timescale) from frame 2112.
        elst.extend_from_slice(&1_000u32.to_be_bytes());
        elst.extend_from_slice(&(-1i32).to_be_bytes());
        elst.extend_from_slice(&[0, 1, 0, 0]);
        elst.extend_from_slice(&140_000u32.to_be_bytes());
        elst.extend_from_slice(&2112i32.to_be_bytes());
        elst.extend_from_slice(&[0, 1, 0, 0]);
        let mdia = mp4_box(
            b"mdia",
            &[
                mp4_box(b"hdlr", &hdlr),
                mp4_box(b"mdhd", &header_box(16_000)),
            ]
            .concat(),
        );
        let edts = mp4_box(b"edts", &mp4_box(b"elst", &elst));
        let moov = [
            mp4_box(b"mvhd", &header_box(1_000)),
            mp4_box(b"trak", &[mdia, edts].concat()),
        ]
        .concat();
        assert_eq!(
            edit_list(&moov, 16_000),
            Some(Edit {
                delay: 2112,
                playable: Some(2_240_000)
            })
        );
        // At 48 kHz the same edit is three times as many frames.
        assert_eq!(edit_list(&moov, 48_000).unwrap().playable, Some(6_720_000));
    }

    #[test]
    fn decodes_a_macos_recording_without_its_priming() {
        let Some(path) = macos_track() else { return };
        let mut reader = TrackReader::open(&path).unwrap();
        assert_eq!(reader.sample_rate(), 16_000);
        assert_eq!(reader.frames(), 2_240_000);
        assert!((reader.duration_seconds() - 140.0).abs() < 1e-9);
        let samples = read_all(&mut reader);
        assert_eq!(samples.len(), 2_240_000);
        assert!(samples.iter().all(|s| s.is_finite()));
        let peak = samples.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.01, "the recording decoded as silence");
        assert_eq!(reader.read_mono(100, &mut Vec::new()).unwrap(), 0);
    }

    #[test]
    fn seeking_reads_the_same_samples_as_reading_through() {
        let Some(path) = macos_track() else { return };
        let all = read_all(&mut TrackReader::open(&path).unwrap());
        let mut reader = TrackReader::open(&path).unwrap();
        // Out of order, after the end, and back to the start.
        for at in [1_120_123u64, 37, 2_239_000, 2_000_000, 0, 5_000] {
            reader.seek_frame(at).unwrap();
            let mut got = Vec::new();
            let read = reader.read_mono(4_000, &mut got).unwrap();
            let expected = &all[at as usize..(at as usize + 4_000).min(all.len())];
            assert_eq!(read, expected.len(), "at {at}");
            let worst = got
                .iter()
                .zip(expected)
                .map(|(a, b)| (a - b).abs())
                .fold(0.0f32, f32::max);
            assert!(worst < 1e-4, "at {at}: samples differ by {worst}");
        }
        reader.seek_frame(5_000_000).unwrap();
        assert_eq!(reader.read_mono(100, &mut Vec::new()).unwrap(), 0);
    }

    #[test]
    fn reads_flac_at_another_rate_as_16_khz_mono() {
        // 0.5 s of a 440 Hz tone, 44.1 kHz stereo.
        let path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/data/tone-44100-stereo.flac");
        let mut reader = TrackReader::open(&path).unwrap();
        assert_eq!(reader.sample_rate(), 16_000);
        assert_eq!(reader.frames(), 8_000);
        let samples = read_all(&mut reader);
        assert!(
            (7_990..=8_000).contains(&samples.len()),
            "{} samples",
            samples.len()
        );
        // A 440 Hz tone crosses zero about 880 times a second.
        let crossings = samples
            .windows(2)
            .filter(|pair| (pair[0] < 0.0) != (pair[1] < 0.0))
            .count();
        assert!(
            (420..=460).contains(&crossings),
            "{crossings} zero crossings"
        );
        reader.seek_frame(4_000).unwrap();
        let mut rest = Vec::new();
        while reader.read_mono(1_000, &mut rest).unwrap() > 0 {}
        assert!(
            (3_990..=4_000).contains(&rest.len()),
            "{} after the seek",
            rest.len()
        );
    }

    #[test]
    fn whole_tracks_and_lengths_read_through_any_format() {
        let Some(path) = macos_track() else { return };
        assert_eq!(crate::read_mono_16k(&path).unwrap().len(), 2_240_000);
        assert!((crate::duration_seconds(&path).unwrap() - 140.0).abs() < 1e-9);
    }
}
