//! Meeting tracks on disk: 16 kHz mono 16-bit PCM WAV.
//!
//! The writer rewrites the RIFF and data sizes every couple of seconds, so a
//! crash or power loss leaves a playable file missing at most that much audio;
//! [`repair_wav`] recovers the rest of an interrupted file.

use std::fs::{File, OpenOptions};
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::resample::Resampler;

/// Sample rate of every track LokalBot writes and of every buffer it hands to
/// speech models.
pub const SAMPLE_RATE: u32 = 16_000;

const HEADER_LEN: u64 = 44;
/// Header refresh interval in bytes of audio (about 2 s at 16 kHz mono 16-bit).
const HEADER_REFRESH_BYTES: u64 = 2 * SAMPLE_RATE as u64 * 2;
/// Largest data chunk a RIFF header can describe.
const MAX_DATA_BYTES: u64 = u32::MAX as u64 - 36;

/// Streaming writer for one track.
pub struct WavWriter {
    file: BufWriter<File>,
    path: PathBuf,
    data_bytes: u64,
    unsynced_bytes: u64,
}

impl WavWriter {
    pub fn create(path: &Path) -> io::Result<Self> {
        let file = File::create(path)?;
        let mut writer = Self {
            file: BufWriter::with_capacity(64 * 1024, file),
            path: path.to_path_buf(),
            data_bytes: 0,
            unsynced_bytes: 0,
        };
        writer.file.write_all(&header(SAMPLE_RATE, 0))?;
        writer.file.flush()?;
        Ok(writer)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Frames written so far.
    pub fn frames(&self) -> u64 {
        self.data_bytes / 2
    }

    pub fn seconds(&self) -> f64 {
        self.frames() as f64 / SAMPLE_RATE as f64
    }

    pub fn write_samples(&mut self, samples: &[f32]) -> io::Result<()> {
        let room = (MAX_DATA_BYTES - self.data_bytes) / 2;
        let samples = &samples[..samples.len().min(room as usize)];
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for &sample in samples {
            bytes.extend_from_slice(&to_i16(sample).to_le_bytes());
        }
        self.write_bytes(&bytes)
    }

    pub fn write_silence(&mut self, frames: u64) -> io::Result<()> {
        let frames = frames.min((MAX_DATA_BYTES - self.data_bytes) / 2);
        let zeros = [0u8; 8192];
        let mut remaining = frames * 2;
        while remaining > 0 {
            let n = remaining.min(zeros.len() as u64) as usize;
            self.write_bytes(&zeros[..n])?;
            remaining -= n as u64;
        }
        Ok(())
    }

    fn write_bytes(&mut self, bytes: &[u8]) -> io::Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        self.file.write_all(bytes)?;
        self.data_bytes += bytes.len() as u64;
        self.unsynced_bytes += bytes.len() as u64;
        if self.unsynced_bytes >= HEADER_REFRESH_BYTES {
            self.update_header()?;
        }
        Ok(())
    }

    /// Writes the current sizes into the header so the file plays as is.
    pub fn update_header(&mut self) -> io::Result<()> {
        self.file.flush()?;
        let file = self.file.get_mut();
        write_sizes(file, self.data_bytes)?;
        file.seek(SeekFrom::Start(HEADER_LEN + self.data_bytes))?;
        self.unsynced_bytes = 0;
        Ok(())
    }

    /// Final header and fsync. Returns the number of frames in the file.
    pub fn finish(mut self) -> io::Result<u64> {
        self.update_header()?;
        self.file.get_ref().sync_all()?;
        Ok(self.frames())
    }
}

fn to_i16(sample: f32) -> i16 {
    if !sample.is_finite() {
        return 0;
    }
    (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
}

fn header(sample_rate: u32, data_bytes: u32) -> [u8; HEADER_LEN as usize] {
    let mut h = [0u8; HEADER_LEN as usize];
    h[0..4].copy_from_slice(b"RIFF");
    h[4..8].copy_from_slice(&(36u32.saturating_add(data_bytes)).to_le_bytes());
    h[8..12].copy_from_slice(b"WAVE");
    h[12..16].copy_from_slice(b"fmt ");
    h[16..20].copy_from_slice(&16u32.to_le_bytes());
    h[20..22].copy_from_slice(&1u16.to_le_bytes()); // PCM
    h[22..24].copy_from_slice(&1u16.to_le_bytes()); // mono
    h[24..28].copy_from_slice(&sample_rate.to_le_bytes());
    h[28..32].copy_from_slice(&(sample_rate * 2).to_le_bytes());
    h[32..34].copy_from_slice(&2u16.to_le_bytes()); // block align
    h[34..36].copy_from_slice(&16u16.to_le_bytes());
    h[36..40].copy_from_slice(b"data");
    h[40..44].copy_from_slice(&data_bytes.to_le_bytes());
    h
}

fn write_sizes(file: &mut File, data_bytes: u64) -> io::Result<()> {
    let data = data_bytes.min(MAX_DATA_BYTES) as u32;
    file.seek(SeekFrom::Start(4))?;
    file.write_all(&(36 + data).to_le_bytes())?;
    file.seek(SeekFrom::Start(40))?;
    file.write_all(&data.to_le_bytes())?;
    Ok(())
}

/// Writes `samples` (16 kHz mono) to a new WAV file in one go.
pub fn write_wav_16k(path: &Path, samples: &[f32]) -> io::Result<()> {
    let mut writer = WavWriter::create(path)?;
    writer.write_samples(samples)?;
    writer.finish()?;
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SampleEncoding {
    Int,
    Float,
}

/// Layout of a WAV file's audio data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WavInfo {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    pub encoding: SampleEncoding,
    pub block_align: u16,
    /// Byte offset of the first sample.
    pub data_offset: u64,
    /// Bytes of audio, limited to what the file holds.
    pub data_len: u64,
    /// Data size the header declares (an interrupted file declares less).
    pub declared_data_len: u64,
}

impl WavInfo {
    pub fn frames(&self) -> u64 {
        self.data_len / self.block_align.max(1) as u64
    }

    pub fn duration_seconds(&self) -> f64 {
        if self.sample_rate == 0 {
            return 0.0;
        }
        self.frames() as f64 / self.sample_rate as f64
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

/// Parses the RIFF chunks of a WAV file. Accepts PCM (8–32 bit), IEEE float
/// (32/64 bit) and WAVE_FORMAT_EXTENSIBLE.
pub fn read_info(path: &Path) -> io::Result<WavInfo> {
    let mut file = File::open(path)?;
    let file_len = file.metadata()?.len();
    parse_info(&mut file, file_len)
}

fn parse_info<R: Read + Seek>(reader: &mut R, file_len: u64) -> io::Result<WavInfo> {
    let mut riff = [0u8; 12];
    reader.read_exact(&mut riff)?;
    if &riff[0..4] != b"RIFF" || &riff[8..12] != b"WAVE" {
        return Err(invalid("not a RIFF/WAVE file"));
    }
    let mut format: Option<(u16, u16, u32, u16, u16)> = None;
    let mut position = 12u64;
    loop {
        let mut chunk = [0u8; 8];
        if reader.read_exact(&mut chunk).is_err() {
            return Err(invalid("WAV file has no data chunk"));
        }
        let size = u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]) as u64;
        position += 8;
        match &chunk[0..4] {
            b"fmt " => {
                if size < 16 {
                    return Err(invalid("WAV fmt chunk is too short"));
                }
                let mut fmt = vec![0u8; size.min(64) as usize];
                reader.read_exact(&mut fmt)?;
                let mut tag = u16::from_le_bytes([fmt[0], fmt[1]]);
                let channels = u16::from_le_bytes([fmt[2], fmt[3]]);
                let rate = u32::from_le_bytes([fmt[4], fmt[5], fmt[6], fmt[7]]);
                let block_align = u16::from_le_bytes([fmt[12], fmt[13]]);
                let bits = u16::from_le_bytes([fmt[14], fmt[15]]);
                if tag == 0xFFFE && fmt.len() >= 26 {
                    // WAVE_FORMAT_EXTENSIBLE: the sub-format GUID starts with the real tag.
                    tag = u16::from_le_bytes([fmt[24], fmt[25]]);
                }
                format = Some((tag, channels, rate, block_align, bits));
                position += size;
                reader.seek(SeekFrom::Start(position + (size & 1)))?;
                position += size & 1;
            }
            b"data" => {
                let (tag, channels, sample_rate, block_align, bits_per_sample) =
                    format.ok_or_else(|| invalid("WAV data chunk before fmt chunk"))?;
                let encoding = match (tag, bits_per_sample) {
                    (1, 8 | 16 | 24 | 32) => SampleEncoding::Int,
                    (3, 32 | 64) => SampleEncoding::Float,
                    _ => return Err(invalid("unsupported WAV sample format")),
                };
                if channels == 0 || sample_rate == 0 {
                    return Err(invalid("WAV file has no channels or sample rate"));
                }
                let block_align = if block_align == 0 {
                    channels * bits_per_sample.div_ceil(8)
                } else {
                    block_align
                };
                let available = file_len.saturating_sub(position);
                // 0 and 0xFFFFFFFF are what streaming writers leave before they know the size.
                let declared = if size == 0 || size == u32::MAX as u64 {
                    available
                } else {
                    size
                };
                let data_len = declared.min(available);
                let data_len = data_len - data_len % block_align as u64;
                return Ok(WavInfo {
                    sample_rate,
                    channels,
                    bits_per_sample,
                    encoding,
                    block_align,
                    data_offset: position,
                    data_len,
                    declared_data_len: size,
                });
            }
            _ => {
                position += size + (size & 1);
                reader.seek(SeekFrom::Start(position))?;
            }
        }
    }
}

/// Reads frames as mono `f32` (channels averaged), in blocks.
pub struct WavReader {
    reader: BufReader<File>,
    info: WavInfo,
    frames_left: u64,
}

impl WavReader {
    pub fn open(path: &Path) -> io::Result<Self> {
        let info = read_info(path)?;
        let mut file = File::open(path)?;
        file.seek(SeekFrom::Start(info.data_offset))?;
        let frames_left = info.frames();
        Ok(Self {
            reader: BufReader::with_capacity(128 * 1024, file),
            info,
            frames_left,
        })
    }

    pub fn info(&self) -> &WavInfo {
        &self.info
    }

    /// Moves to `frame` (clamped to the end).
    pub fn seek_frame(&mut self, frame: u64) -> io::Result<()> {
        let frame = frame.min(self.info.frames());
        let offset = self.info.data_offset + frame * self.info.block_align as u64;
        self.reader.seek(SeekFrom::Start(offset))?;
        self.frames_left = self.info.frames() - frame;
        Ok(())
    }

    /// Appends up to `max_frames` mono frames to `out`; returns how many were read.
    pub fn read_mono(&mut self, max_frames: usize, out: &mut Vec<f32>) -> io::Result<usize> {
        let frames = (max_frames as u64).min(self.frames_left) as usize;
        if frames == 0 {
            return Ok(0);
        }
        let block = self.info.block_align as usize;
        let mut bytes = vec![0u8; frames * block];
        self.reader.read_exact(&mut bytes)?;
        self.frames_left -= frames as u64;
        let channels = self.info.channels as usize;
        let width = (self.info.bits_per_sample as usize).div_ceil(8);
        out.reserve(frames);
        for frame in bytes.chunks_exact(block) {
            let mut sum = 0.0f32;
            for channel in 0..channels {
                let start = channel * width;
                sum += decode_sample(&frame[start..start + width], self.info.encoding);
            }
            out.push(sum / channels as f32);
        }
        Ok(frames)
    }
}

fn decode_sample(bytes: &[u8], encoding: SampleEncoding) -> f32 {
    match (encoding, bytes.len()) {
        (SampleEncoding::Int, 1) => (bytes[0] as f32 - 128.0) / 128.0,
        (SampleEncoding::Int, 2) => i16::from_le_bytes([bytes[0], bytes[1]]) as f32 / 32768.0,
        (SampleEncoding::Int, 3) => {
            let value = i32::from_le_bytes([0, bytes[0], bytes[1], bytes[2]]) >> 8;
            value as f32 / 8_388_608.0
        }
        (SampleEncoding::Int, 4) => {
            i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f32 / 2_147_483_648.0
        }
        (SampleEncoding::Float, 4) => {
            let value = f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            if value.is_finite() { value } else { 0.0 }
        }
        (SampleEncoding::Float, 8) => {
            let mut raw = [0u8; 8];
            raw.copy_from_slice(bytes);
            let value = f64::from_le_bytes(raw) as f32;
            if value.is_finite() { value } else { 0.0 }
        }
        _ => 0.0,
    }
}

/// A whole track as 16 kHz mono `f32`, in any format the library selects,
/// resampled when the file uses another rate.
pub fn read_mono_16k(path: &Path) -> io::Result<Vec<f32>> {
    let mut reader = crate::decode::TrackReader::open(path)?;
    let rate = reader.sample_rate();
    let mut raw = Vec::with_capacity(reader.frames() as usize);
    while reader.read_mono(1 << 16, &mut raw)? > 0 {}
    if rate == SAMPLE_RATE {
        return Ok(raw);
    }
    let mut resampler = Resampler::new(rate, SAMPLE_RATE);
    let mut out = Vec::with_capacity(raw.len() * SAMPLE_RATE as usize / rate as usize + 16);
    resampler.process(&raw, &mut out);
    resampler.flush(&mut out);
    Ok(out)
}

/// Seconds of audio in a track, in any format the library selects.
pub fn duration_seconds(path: &Path) -> io::Result<f64> {
    Ok(crate::decode::TrackReader::open(path)?.duration_seconds())
}

/// Fixes the header of a WAV file whose writer stopped before updating it (a
/// crash or power loss): the data chunk is extended to the end of the file and
/// a trailing partial frame is dropped. Returns whether anything changed.
pub fn repair_wav(path: &Path) -> io::Result<bool> {
    let file_len = std::fs::metadata(path)?.len();
    let mut file = OpenOptions::new().read(true).write(true).open(path)?;
    let mut probe = file.try_clone()?;
    // Ignore the declared size: everything after the data chunk header is audio
    // for files LokalBot wrote (it never appends chunks after `data`).
    let info = parse_info(&mut probe, file_len)?;
    let block = info.block_align as u64;
    let available = file_len.saturating_sub(info.data_offset);
    let data_len = (available - available % block).min(MAX_DATA_BYTES - MAX_DATA_BYTES % block);
    let riff_len = (info.data_offset - 8 + data_len).min(u32::MAX as u64) as u32;

    let mut riff = [0u8; 4];
    file.seek(SeekFrom::Start(4))?;
    file.read_exact(&mut riff)?;
    let header_ok = info.declared_data_len == data_len && u32::from_le_bytes(riff) == riff_len;
    let length_ok = info.data_offset + data_len == file_len;
    if header_ok && length_ok {
        return Ok(false);
    }
    file.seek(SeekFrom::Start(4))?;
    file.write_all(&riff_len.to_le_bytes())?;
    file.seek(SeekFrom::Start(info.data_offset - 4))?;
    file.write_all(&(data_len as u32).to_le_bytes())?;
    file.set_len(info.data_offset + data_len)?;
    file.sync_all()?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(frames: usize, freq: f32, rate: u32) -> Vec<f32> {
        (0..frames)
            .map(|i| (i as f32 * freq * std::f32::consts::TAU / rate as f32).sin() * 0.5)
            .collect()
    }

    #[test]
    fn round_trips_samples() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.wav");
        let samples = sine(16_000, 440.0, SAMPLE_RATE);
        write_wav_16k(&path, &samples).unwrap();
        let info = read_info(&path).unwrap();
        assert_eq!(info.sample_rate, 16_000);
        assert_eq!(info.channels, 1);
        assert_eq!(info.frames(), 16_000);
        assert_eq!(std::fs::metadata(&path).unwrap().len(), 44 + 32_000);
        let back = read_mono_16k(&path).unwrap();
        assert_eq!(back.len(), samples.len());
        let max_error = back
            .iter()
            .zip(&samples)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0, f32::max);
        assert!(max_error < 1.0 / 16_000.0, "{max_error}");
    }

    #[test]
    fn header_is_refreshed_while_writing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("live.wav");
        let mut writer = WavWriter::create(&path).unwrap();
        writer.write_samples(&vec![0.1; 16_000 * 3]).unwrap();
        // Without finishing, the header already covers at least the first 2 s.
        let info = read_info(&path).unwrap();
        assert!(info.declared_data_len >= 2 * 32_000, "{info:?}");
        drop(writer);
    }

    #[test]
    fn repair_extends_an_interrupted_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("crash.wav");
        let mut bytes = header(16_000, 3200).to_vec();
        bytes.extend(std::iter::repeat_n(0x11u8, 3200 + 6401)); // more data and half a frame
        std::fs::write(&path, &bytes).unwrap();
        assert_eq!(read_info(&path).unwrap().frames(), 1600);
        assert!(repair_wav(&path).unwrap());
        let info = read_info(&path).unwrap();
        assert_eq!(info.declared_data_len, 3200 + 6400);
        assert_eq!(info.frames(), 4800);
        assert_eq!(std::fs::metadata(&path).unwrap().len(), 44 + 9600);
        assert!(!repair_wav(&path).unwrap());
    }

    #[test]
    fn reads_float_stereo_at_other_rates() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("stereo.wav");
        let frames = 48_000;
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + frames as u32 * 8).to_le_bytes());
        bytes.extend_from_slice(b"WAVEfmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes());
        bytes.extend_from_slice(&3u16.to_le_bytes());
        bytes.extend_from_slice(&2u16.to_le_bytes());
        bytes.extend_from_slice(&48_000u32.to_le_bytes());
        bytes.extend_from_slice(&(48_000u32 * 8).to_le_bytes());
        bytes.extend_from_slice(&8u16.to_le_bytes());
        bytes.extend_from_slice(&32u16.to_le_bytes());
        bytes.extend_from_slice(b"LIST");
        bytes.extend_from_slice(&3u32.to_le_bytes());
        bytes.extend_from_slice(&[1, 2, 3, 0]); // odd chunk with its pad byte
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&(frames as u32 * 8).to_le_bytes());
        for sample in sine(frames, 1000.0, 48_000) {
            bytes.extend_from_slice(&sample.to_le_bytes());
            bytes.extend_from_slice(&sample.to_le_bytes());
        }
        std::fs::write(&path, &bytes).unwrap();
        let info = read_info(&path).unwrap();
        assert_eq!(
            (info.channels, info.sample_rate, info.encoding),
            (2, 48_000, SampleEncoding::Float)
        );
        let mono = read_mono_16k(&path).unwrap();
        assert!((mono.len() as i64 - 16_000).abs() <= 1, "{}", mono.len());
        let rms = (mono[2000..14000].iter().map(|s| s * s).sum::<f32>() / 12_000.0).sqrt();
        assert!((rms - 0.5 / 2f32.sqrt()).abs() < 0.01, "{rms}");
    }
}
