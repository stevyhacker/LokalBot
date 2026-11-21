use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

const COMPLETENESS_TOLERANCE_SECONDS: f64 = 0.1;

const MAX_MP4_BOXES: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Track {
    Mic,
    System,
}

impl Track {
    pub const ALL: [Track; 2] = [Track::Mic, Track::System];

    fn name(self) -> &'static str {
        match self {
            Track::Mic => "mic",
            Track::System => "system",
        }
    }

    pub fn recovery_file(self) -> String {
        format!("{}.live.caf", self.name())
    }

    fn recovered_file(self) -> String {
        format!("{}.live.recovered.caf", self.name())
    }

    fn journal_folder(self) -> String {
        format!("{}.live.recovery", self.name())
    }

    fn receipt_file(self) -> String {
        format!("{}.live.recovered.caf.json", self.name())
    }
}

pub fn track_file(folder: &Path, track: Track) -> Option<PathBuf> {
    let name = track.name();
    let existing = |file: String| Some(folder.join(file)).filter(|path| path.is_file());
    if let Some(path) = existing(format!("{name}.wav")).or_else(|| existing(format!("{name}.flac")))
    {
        return Some(path);
    }
    let primary = existing(format!("{name}.m4a"));
    let primary_seconds = primary
        .as_deref()
        .and_then(mp4_duration)
        .filter(|seconds| *seconds > 0.0);
    let recovery = [track.recovery_file(), track.recovered_file()]
        .into_iter()
        .filter_map(|file| {
            let path = existing(file)?;
            let seconds = caf_duration(&path).filter(|seconds| *seconds > 0.0)?;
            Some((path, seconds))
        })
        .max_by(|a, b| a.1.total_cmp(&b.1));
    match (primary_seconds, recovery) {
        (Some(aac), Some((copy, seconds))) if seconds > aac + COMPLETENESS_TOLERANCE_SECONDS => {
            Some(copy)
        }
        (None, Some((copy, _))) => Some(copy),
        _ => primary,
    }
}

pub fn recovery_needs_attention(folder: &Path) -> bool {
    #[derive(serde::Deserialize)]
    struct Receipt {
        complete: bool,
    }
    Track::ALL.into_iter().any(|track| {
        folder.join(track.journal_folder()).exists()
            && std::fs::read(folder.join(track.receipt_file()))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Receipt>(&bytes).ok())
                .is_none_or(|receipt| !receipt.complete)
    })
}

fn read_exact<const N: usize>(file: &mut File) -> Option<[u8; N]> {
    let mut bytes = [0; N];
    file.read_exact(&mut bytes).ok()?;
    Some(bytes)
}

fn caf_duration(path: &Path) -> Option<f64> {
    let mut file = File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    if &read_exact::<4>(&mut file)? != b"caff" {
        return None;
    }
    read_exact::<4>(&mut file)?;
    let mut packet: Option<(f64, u64, u64)> = None;
    loop {
        let kind = read_exact::<4>(&mut file)?;
        let size = i64::from_be_bytes(read_exact::<8>(&mut file)?);
        let start = file.stream_position().ok()?;
        match &kind {
            b"desc" => {
                let rate = f64::from_be_bytes(read_exact::<8>(&mut file)?);
                read_exact::<8>(&mut file)?;
                let bytes = u32::from_be_bytes(read_exact::<4>(&mut file)?);
                let frames = u32::from_be_bytes(read_exact::<4>(&mut file)?);
                packet = Some((rate, u64::from(bytes), u64::from(frames)));
            }
            b"data" => {
                let (rate, bytes, frames) = packet?;
                if rate <= 0.0 || bytes == 0 || frames == 0 {
                    return None;
                }
                let available = length.saturating_sub(start);
                let declared = u64::try_from(size).unwrap_or(available);
                let audio = declared.min(available).saturating_sub(4);
                return Some((audio / bytes * frames) as f64 / rate);
            }
            _ => {}
        }
        let next = start.checked_add(u64::try_from(size).ok()?)?;
        file.seek(SeekFrom::Start(next)).ok()?;
    }
}

fn mp4_duration(path: &Path) -> Option<f64> {
    let mut file = File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    let mut position = 0;
    let mut seconds = None;
    let mut boxes = 0;
    while position < length {
        boxes += 1;
        if boxes > MAX_MP4_BOXES {
            return seconds;
        }
        let (kind, body, end) = mp4_box(&mut file, position, length)?;
        if end > length {
            return None;
        }
        if &kind == b"moov" {
            seconds = mvhd_duration(&mut file, body, end);
        }
        position = end;
    }
    seconds
}

fn mp4_box(file: &mut File, position: u64, length: u64) -> Option<([u8; 4], u64, u64)> {
    file.seek(SeekFrom::Start(position)).ok()?;
    let size = u32::from_be_bytes(read_exact::<4>(file)?);
    let kind = read_exact::<4>(file)?;
    let (body, end) = match size {
        0 => (position + 8, length),
        1 => (
            position + 16,
            position.checked_add(u64::from_be_bytes(read_exact::<8>(file)?))?,
        ),
        size => (position + 8, position + u64::from(size)),
    };
    (end >= body).then_some((kind, body, end))
}

fn mvhd_duration(file: &mut File, start: u64, end: u64) -> Option<f64> {
    let mut position = start;
    while position < end {
        let (kind, body, next) = mp4_box(file, position, end)?;
        if &kind == b"mvhd" {
            file.seek(SeekFrom::Start(body)).ok()?;
            let version = read_exact::<4>(file)?[0];
            let (scale, duration) = if version == 1 {
                read_exact::<16>(file)?;
                (
                    u32::from_be_bytes(read_exact::<4>(file)?),
                    u64::from_be_bytes(read_exact::<8>(file)?),
                )
            } else {
                read_exact::<8>(file)?;
                (
                    u32::from_be_bytes(read_exact::<4>(file)?),
                    u64::from(u32::from_be_bytes(read_exact::<4>(file)?)),
                )
            };
            return (scale > 0).then(|| duration as f64 / f64::from(scale));
        }
        position = next;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caf_header(data_size: i64) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(b"caff");
        bytes.extend_from_slice(&1u16.to_be_bytes());
        bytes.extend_from_slice(&0u16.to_be_bytes());
        bytes.extend_from_slice(b"desc");
        bytes.extend_from_slice(&32i64.to_be_bytes());
        bytes.extend_from_slice(&16_000f64.to_be_bytes());
        bytes.extend_from_slice(b"lpcm");
        bytes.extend_from_slice(&3u32.to_be_bytes());
        bytes.extend_from_slice(&4u32.to_be_bytes());
        bytes.extend_from_slice(&1u32.to_be_bytes());
        bytes.extend_from_slice(&1u32.to_be_bytes());
        bytes.extend_from_slice(&32u32.to_be_bytes());
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_size.to_be_bytes());
        bytes.extend_from_slice(&0u32.to_be_bytes());
        bytes
    }

    fn growing_caf(path: &Path, seconds: f64) {
        let mut bytes = caf_header(-1);
        bytes.resize(bytes.len() + (seconds * 16_000.0) as usize * 4, 0);
        std::fs::write(path, bytes).unwrap();
    }

    fn mp4_box_bytes(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut bytes = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        bytes.extend_from_slice(kind);
        bytes.extend_from_slice(body);
        bytes
    }

    fn m4a(path: &Path, seconds: Option<u32>) {
        let mut bytes = mp4_box_bytes(b"ftyp", b"M4A \0\0\0\0");
        bytes.extend(mp4_box_bytes(b"mdat", &[0; 64]));
        if let Some(seconds) = seconds {
            let mut mvhd = vec![0; 12];
            mvhd.extend_from_slice(&1_000u32.to_be_bytes());
            mvhd.extend_from_slice(&(seconds * 1_000).to_be_bytes());
            bytes.extend(mp4_box_bytes(b"moov", &mp4_box_bytes(b"mvhd", &mvhd)));
        }
        std::fs::write(path, bytes).unwrap();
    }

    fn folder() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    fn file(dir: &tempfile::TempDir, name: &str) -> PathBuf {
        dir.path().join(name)
    }

    #[test]
    fn a_crash_tee_is_the_track_when_the_aac_never_finished() {
        let dir = folder();
        m4a(&file(&dir, "mic.m4a"), None);
        growing_caf(&file(&dir, "mic.live.caf"), 12.0);
        assert_eq!(
            track_file(dir.path(), Track::Mic),
            Some(file(&dir, "mic.live.caf"))
        );
        assert_eq!(track_file(dir.path(), Track::System), None);
    }

    #[test]
    fn a_crash_tee_alone_is_the_track() {
        let dir = folder();
        growing_caf(&file(&dir, "system.live.caf"), 3.0);
        assert_eq!(
            track_file(dir.path(), Track::System),
            Some(file(&dir, "system.live.caf"))
        );
    }

    #[test]
    fn a_finished_aac_wins_unless_the_tee_is_materially_longer() {
        let dir = folder();
        m4a(&file(&dir, "mic.m4a"), Some(10));
        growing_caf(&file(&dir, "mic.live.caf"), 10.05);
        assert_eq!(
            track_file(dir.path(), Track::Mic),
            Some(file(&dir, "mic.m4a"))
        );
        growing_caf(&file(&dir, "mic.live.caf"), 11.0);
        assert_eq!(
            track_file(dir.path(), Track::Mic),
            Some(file(&dir, "mic.live.caf"))
        );
    }

    #[test]
    fn the_longer_of_the_tee_and_the_rebuilt_copy_counts() {
        let dir = folder();
        m4a(&file(&dir, "mic.m4a"), Some(10));
        growing_caf(&file(&dir, "mic.live.caf"), 9.0);
        growing_caf(&file(&dir, "mic.live.recovered.caf"), 20.0);
        assert_eq!(
            track_file(dir.path(), Track::Mic),
            Some(file(&dir, "mic.live.recovered.caf"))
        );
    }

    #[test]
    fn this_apps_tracks_and_an_unreadable_aac_stay_as_they_were() {
        let dir = folder();
        std::fs::write(file(&dir, "mic.m4a"), b"not an mp4").unwrap();
        assert_eq!(
            track_file(dir.path(), Track::Mic),
            Some(file(&dir, "mic.m4a"))
        );
        std::fs::write(file(&dir, "mic.wav"), b"audio").unwrap();
        assert_eq!(
            track_file(dir.path(), Track::Mic),
            Some(file(&dir, "mic.wav"))
        );
    }

    #[test]
    fn an_empty_tee_is_not_a_recording() {
        let dir = folder();
        growing_caf(&file(&dir, "mic.live.caf"), 0.0);
        assert_eq!(track_file(dir.path(), Track::Mic), None);
    }

    #[test]
    fn a_box_past_the_end_of_the_file_means_the_aac_is_not_whole() {
        let dir = folder();
        let path = file(&dir, "mic.m4a");
        m4a(&path, Some(10));
        assert_eq!(mp4_duration(&path), Some(10.0));
        let bytes = std::fs::read(&path).unwrap();
        std::fs::write(&path, &bytes[..bytes.len() - 4]).unwrap();
        assert_eq!(mp4_duration(&path), None);
    }

    #[test]
    fn a_closed_caf_reports_its_declared_length() {
        let dir = folder();
        let path = file(&dir, "mic.live.caf");
        let mut bytes = caf_header(8_000 * 4 + 4);
        bytes.resize(bytes.len() + 8_000 * 4 + 100, 0);
        std::fs::write(&path, bytes).unwrap();
        assert_eq!(caf_duration(&path), Some(0.5));
    }

    #[test]
    fn unverified_checkpoints_need_attention() {
        let dir = folder();
        assert!(!recovery_needs_attention(dir.path()));
        std::fs::create_dir(file(&dir, "system.live.recovery")).unwrap();
        assert!(recovery_needs_attention(dir.path()));
        std::fs::write(
            file(&dir, "system.live.recovered.caf.json"),
            r#"{"complete":false,"frames":10}"#,
        )
        .unwrap();
        assert!(recovery_needs_attention(dir.path()));
        std::fs::write(
            file(&dir, "system.live.recovered.caf.json"),
            r#"{"complete":true,"frames":10}"#,
        )
        .unwrap();
        assert!(!recovery_needs_attention(dir.path()));
    }
}
