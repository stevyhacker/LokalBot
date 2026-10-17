use crate::{
    domain::*,
    storage::{Library, atomic_write, private_directory},
};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Instant,
};

pub fn owned_media(library: &Library, path: &str) -> Result<PathBuf> {
    let root = library.root.join("meetings").canonicalize()?;
    let target = library.root.join(path).canonicalize()?;
    ensure!(
        target.starts_with(root) && target.is_file(),
        "Audio is outside this library"
    );
    Ok(target)
}
pub fn envelope(library: &Library, meeting: &Meeting) -> Result<Vec<f32>> {
    let media = meeting.media.first().context("No audio")?;
    let path = owned_media(library, &media.path)?;
    let mut reader = hound::WavReader::open(path)?;
    let frames = reader.duration();
    let channels = usize::from(reader.spec().channels);
    let mut levels = vec![];
    for index in 0..100 {
        reader.seek(frames / 100 * index)?;
        let level = reader
            .samples::<i16>()
            .take(128 * channels)
            .filter_map(Result::ok)
            .map(|s| (f32::from(s) / 32768.).abs())
            .fold(0., f32::max);
        levels.push(level);
    }
    let max = levels.iter().copied().fold(0., f32::max);
    if max > 0. {
        for level in &mut levels {
            *level /= max;
        }
    }
    Ok(levels)
}
pub fn import_audio(library: &mut Library, path: &Path, title: Option<String>) -> Result<String> {
    ensure!(
        path.is_file() && fs::metadata(path)?.len() <= 2 * 1024 * 1024 * 1024,
        "Audio is missing or larger than 2 GiB"
    );
    let mut meeting = Meeting::empty(title.unwrap_or_else(|| {
        path.file_stem()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned()
    }));
    meeting.app = "Imported audio".into();
    let directory = library.root.join("meetings").join(&meeting.id);
    private_directory(&directory)?;
    let output = directory.join("import.wav");
    let result = crate::process::bounded_output(
        Command::new("ffmpeg")
            .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
            .arg(path)
            .args(["-vn", "-ac", "1", "-ar", "16000", "-y"])
            .arg(&output),
        std::time::Duration::from_secs(600),
        64 * 1024,
    )
    .context("FFmpeg is needed to import audio")?;
    ensure!(
        result.status.success(),
        "FFmpeg could not decode this audio file"
    );
    let reader = hound::WavReader::open(&output)?;
    meeting.duration = reader.duration() as f64 / f64::from(reader.spec().sample_rate);
    meeting.media.push(Media {
        track: "import".into(),
        path: format!("meetings/{}/import.wav", meeting.id),
    });
    let id = meeting.id.clone();
    library.save_meeting(&meeting)?;
    Ok(id)
}

pub fn whisper(settings: &Settings, path: &Path) -> Result<Vec<Segment>> {
    ensure!(
        !settings.whisper_model.is_empty(),
        "Configure a local Whisper GGML model in Settings, or explicitly opt into remote audio transcription"
    );
    let model = Path::new(&settings.whisper_model);
    ensure!(model.is_file(), "The local Whisper model is missing");
    let temporary = tempfile::tempdir()?;
    let wav = temporary.path().join("input.wav");
    let status = crate::process::bounded_output(
        Command::new("ffmpeg")
            .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
            .arg(path)
            .args(["-vn", "-ac", "1", "-ar", "16000", "-y"])
            .arg(&wav),
        std::time::Duration::from_secs(600),
        64 * 1024,
    )
    .context("FFmpeg is needed for transcription")?;
    ensure!(
        status.status.success(),
        "Could not convert the audio for local transcription"
    );
    let output = temporary.path().join("transcript");
    let status = crate::process::bounded_output(
        Command::new(&settings.whisper_executable)
            .arg("-m")
            .arg(model)
            .arg("-f")
            .arg(&wav)
            .args(["-oj", "-of"])
            .arg(&output)
            .args(["-t", "4", "-ng", "-l", "auto", "-np"]),
        std::time::Duration::from_secs(7200),
        256 * 1024,
    )
    .context("Could not start whisper-cli; configure its executable path")?;
    ensure!(
        status.status.success(),
        "Local Whisper transcription failed"
    );
    let value: serde_json::Value =
        serde_json::from_slice(&fs::read(output.with_extension("json"))?)?;
    let rows = value["transcription"]
        .as_array()
        .context("Whisper returned no transcript")?;
    Ok(rows
        .iter()
        .map(|s| Segment {
            id: new_id(),
            start: s["offsets"]["from"].as_f64().unwrap_or(0.) / 1000.,
            end: s["offsets"]["to"].as_f64().unwrap_or(0.) / 1000.,
            speaker: "Unidentified".into(),
            text: s["text"].as_str().unwrap_or("").trim().into(),
        })
        .filter(|s| !s.text.is_empty())
        .collect())
}

pub struct AudioPart {
    pub path: PathBuf,
    pub offset: f64,
    pub duration: f64,
}
pub struct AudioParts {
    _directory: tempfile::TempDir,
    pub parts: Vec<AudioPart>,
}
/// Decode once, then stream bounded PCM pieces. No full-recording allocation.
pub fn remote_audio_parts(path: &Path) -> Result<AudioParts> {
    let directory = tempfile::tempdir()?;
    let mut source = path.to_path_buf();
    let canonical = hound::WavReader::open(path).ok().is_some_and(|r| {
        let spec = r.spec();
        spec.channels == 1
            && spec.bits_per_sample == 16
            && spec.sample_format == hound::SampleFormat::Int
    });
    if !canonical {
        source = directory.path().join("normalized.wav");
        let output = crate::process::bounded_output(
            Command::new("ffmpeg")
                .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
                .arg(path)
                .args(["-vn", "-ac", "1", "-ar", "16000", "-y"])
                .arg(&source),
            std::time::Duration::from_secs(600),
            64 * 1024,
        )?;
        ensure!(
            output.status.success(),
            "Could not decode audio for remote transcription"
        );
    }
    let mut reader = hound::WavReader::open(source)?;
    let spec = reader.spec();
    ensure!(spec.sample_rate > 0, "Invalid audio sample rate");
    // A five-minute cap preserves progress; 20 MiB leaves headroom below the
    // provider limit even for a high-rate microphone and its WAV header.
    let frames = (u64::from(spec.sample_rate) * 300).min((20 * 1024 * 1024 - 44) / 2) as usize;
    let mut samples = reader.samples::<i16>().peekable();
    let mut total = 0usize;
    let mut parts = vec![];
    while samples.peek().is_some() {
        let output = directory
            .path()
            .join(format!("part-{:06}.wav", parts.len()));
        let mut writer = hound::WavWriter::create(&output, spec)?;
        let mut count = 0;
        for sample in samples.by_ref().take(frames) {
            writer.write_sample(sample?)?;
            count += 1;
        }
        writer.finalize()?;
        parts.push(AudioPart {
            path: output,
            offset: total as f64 / f64::from(spec.sample_rate),
            duration: count as f64 / f64::from(spec.sample_rate),
        });
        total += count;
    }
    ensure!(!parts.is_empty(), "Audio contains no samples");
    Ok(AudioParts {
        _directory: directory,
        parts,
    })
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Chunk {
    pub name: String,
    pub frames: u64,
    pub sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Manifest {
    pub rate: u32,
    pub chunks: Vec<Chunk>,
    pub dropped_buffers: u64,
    pub complete: bool,
    #[serde(default)]
    pub output_sha256: Option<String>,
}
pub struct ChunkWriter {
    directory: PathBuf,
    pub manifest: Manifest,
    samples: Vec<i16>,
}
impl ChunkWriter {
    pub fn new(directory: &Path, rate: u32) -> Result<Self> {
        ensure!(rate > 0, "Invalid audio sample rate");
        private_directory(directory)?;
        Ok(Self {
            directory: directory.into(),
            manifest: Manifest {
                rate,
                chunks: vec![],
                dropped_buffers: 0,
                complete: false,
                output_sha256: None,
            },
            samples: vec![],
        })
    }
    pub fn append(&mut self, samples: &[i16]) -> Result<()> {
        self.samples.extend_from_slice(samples);
        let size = self.manifest.rate as usize * 2;
        while self.samples.len() >= size {
            let chunk = self.samples.drain(..size).collect::<Vec<_>>();
            self.flush_chunk(&chunk)?;
        }
        Ok(())
    }
    fn flush_chunk(&mut self, samples: &[i16]) -> Result<()> {
        let name = format!("{:06}.wav", self.manifest.chunks.len());
        let path = self.directory.join(&name);
        let temporary = self.directory.join(format!("{name}.part"));
        let mut writer = hound::WavWriter::create(
            &temporary,
            hound::WavSpec {
                channels: 1,
                sample_rate: self.manifest.rate,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )?;
        for s in samples {
            writer.write_sample(*s)?;
        }
        writer.finalize()?;
        // Windows FlushFileBuffers requires a write-capable file handle.
        fs::OpenOptions::new()
            .write(true)
            .open(&temporary)?
            .sync_all()?;
        fs::rename(&temporary, &path)?;
        let chunk = Chunk {
            name,
            frames: samples.len() as u64,
            sha256: format!("{:x}", Sha256::digest(fs::read(path)?)),
        };
        self.manifest.chunks.push(chunk);
        atomic_write(
            &self.directory.join("manifest.json"),
            &serde_json::to_vec_pretty(&self.manifest)?,
        )?;
        Ok(())
    }
    pub fn finish(mut self, dropped: u64, output: &Path) -> Result<f64> {
        let remaining = std::mem::take(&mut self.samples);
        if !remaining.is_empty() {
            self.flush_chunk(&remaining)?;
        }
        self.manifest.dropped_buffers = dropped;
        let duration = recover_chunks(&self.directory, output)?;
        self.manifest.output_sha256 = Some(file_sha256(output)?);
        self.manifest.complete = true;
        atomic_write(
            &self.directory.join("manifest.json"),
            &serde_json::to_vec_pretty(&self.manifest)?,
        )?;
        Ok(duration)
    }
}
pub fn recover_chunks(directory: &Path, output: &Path) -> Result<f64> {
    let manifest: Manifest = serde_json::from_slice(&fs::read(directory.join("manifest.json"))?)?;
    ensure!(manifest.rate > 0, "Invalid checkpoint sample rate");
    ensure!(!manifest.chunks.is_empty(), "No complete audio checkpoints");
    let temporary = tempfile::Builder::new()
        .prefix("audio-finalizing-")
        .suffix(".wav")
        .tempfile_in(output.parent().context("Missing audio directory")?)?;
    let mut writer = hound::WavWriter::create(
        temporary.path(),
        hound::WavSpec {
            channels: 1,
            sample_rate: manifest.rate,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        },
    )?;
    let mut frames = 0;
    for chunk in &manifest.chunks {
        ensure!(
            chunk
                .name
                .chars()
                .all(|c| c.is_ascii_digit() || ".wav".contains(c))
                && !chunk.name.contains(".."),
            "Invalid checkpoint name"
        );
        let path = directory.join(&chunk.name);
        ensure!(
            format!("{:x}", Sha256::digest(fs::read(&path)?)) == chunk.sha256,
            "Audio checkpoint failed its checksum; originals were retained"
        );
        let mut reader = hound::WavReader::open(path)?;
        ensure!(
            reader.spec().channels == 1
                && reader.spec().sample_rate == manifest.rate
                && u64::from(reader.duration()) == chunk.frames,
            "Checkpoint format or coverage mismatch"
        );
        for sample in reader.samples::<i16>() {
            writer.write_sample(sample?)?;
            frames += 1;
        }
    }
    writer.finalize()?;
    temporary.as_file().sync_all()?;
    if output.exists() {
        let existing = hound::WavReader::open(output)?;
        ensure!(
            existing.duration() as u64 <= frames,
            "Existing audio is longer; refusing a shorter recovery"
        );
    }
    temporary.persist(output).map_err(|e| e.error)?;
    Ok(frames as f64 / f64::from(manifest.rate))
}
fn file_sha256(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut file = fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut bytes = [0; 65536];
    loop {
        let length = file.read(&mut bytes)?;
        if length == 0 {
            break;
        }
        hash.update(&bytes[..length]);
    }
    Ok(format!("{:x}", hash.finalize()))
}

/// Repairs closed checkpoints after a process exit without authorizing a new capture.
pub fn recover_recordings(library: &mut Library) -> Result<Vec<String>> {
    let mut recovered = vec![];
    for preview in library.meeting_previews()? {
        let id = preview.metadata.id;
        // Each recording is independent. A corrupt manifest or lost piece must
        // leave its originals available and cannot prevent other recovery.
        let result = recover_recording(library, &id);
        match result {
            Ok(true) => recovered.push(id),
            Ok(false) => {}
            Err(error) => {
                let warning = format!(
                    "Audio recovery failed: {}. Original checkpoints were retained; other meetings remain available.",
                    crate::privacy::redact(&error.to_string())
                );
                if let Ok(mut meeting) = library.meeting(&id) {
                    if !meeting.warnings.contains(&warning) {
                        meeting.warnings.push(warning.clone());
                        library.save_meeting(&meeting)?;
                    }
                    library.save_job(&Job {
                        id: format!("recovery-{id}"),
                        meeting_id: Some(id),
                        kind: "recording recovery".into(),
                        status: "failed".into(),
                        error: Some(warning),
                        updated_at: now(),
                    })?;
                }
            }
        }
    }
    Ok(recovered)
}
fn recover_recording(library: &mut Library, id: &str) -> Result<bool> {
    crate::storage::valid_id(id)?;
    let directory = library.root.join("meetings").join(id).join("mic-chunks");
    let manifest_path = directory.join("manifest.json");
    if !manifest_path.is_file() {
        return Ok(false);
    }
    let mut meeting = library.meeting(id)?;
    let manifest: Manifest = serde_json::from_slice(&fs::read(&manifest_path)?)?;
    if manifest.chunks.is_empty() {
        return Ok(false);
    }
    let output = directory
        .parent()
        .context("Missing meeting directory")?
        .join("mic.wav");
    if let Some(checksum) = &manifest.output_sha256
        && output.is_file()
        && file_sha256(&output)? == *checksum
        && meeting.duration > 0.
    {
        fs::remove_dir_all(directory)?;
        cleanup_audio_temporary_files(output.parent().unwrap())?;
        return Ok(false);
    }
    meeting.duration = recover_chunks(&directory, &output)?;
    meeting.media = vec![Media {
        track: "mic".into(),
        path: format!("meetings/{}/mic.wav", meeting.id),
    }];
    if !manifest.complete {
        meeting.warnings.push("Recovered verified microphone checkpoints after an interrupted recording; the uncommitted tail may be missing. Recording was not restarted.".into());
    }
    library.save_meeting(&meeting)?;
    fs::remove_dir_all(directory)?;
    cleanup_audio_temporary_files(output.parent().unwrap())?;
    Ok(true)
}
fn cleanup_audio_temporary_files(directory: &Path) -> Result<()> {
    if !directory.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if entry.file_type()?.is_file()
            && (name == "mic.recovery.wav"
                || (name.starts_with("audio-finalizing-") && name.ends_with(".wav")))
        {
            fs::remove_file(entry.path())?;
        }
    }
    Ok(())
}

pub struct Playback {
    child: Child,
}
impl Drop for Playback {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Playback {
    pub fn start(library: &Library, meeting: &Meeting, seconds: f64) -> Result<Self> {
        ensure!(!meeting.media.is_empty(), "This meeting has no audio");
        let path = owned_media(library, &meeting.media[0].path)?;
        let child = Command::new("ffplay")
            .args(["-nodisp", "-autoexit", "-loglevel", "error", "-ss"])
            .arg(seconds.max(0.).to_string())
            .arg(path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("Install FFmpeg (ffplay) for audio playback")?;
        Ok(Self { child })
    }
    pub fn finished(&mut self) -> bool {
        self.child.try_wait().ok().flatten().is_some()
    }
}

pub struct Recording {
    pub meeting_id: String,
    pub started: Instant,
    pub dropped: Arc<AtomicU64>,
    pub stream_error: Arc<Mutex<Option<String>>>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<Result<f64>>>,
    #[cfg(feature = "audio")]
    stream: Option<cpal::Stream>,
}
impl Recording {
    #[cfg(feature = "audio")]
    pub fn start(library: &mut Library, title: &str) -> Result<Self> {
        use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
        let device = cpal::default_host()
            .default_input_device()
            .context("No microphone is available. Import an audio file or transcript instead.")?;
        let supported = device.default_input_config()?;
        let config: cpal::StreamConfig = supported.clone().into();
        let rate = config.sample_rate.0;
        let channels = usize::from(config.channels);
        let mut meeting = Meeting::empty(title);
        meeting.app = "Microphone".into();
        let directory = library
            .root
            .join("meetings")
            .join(&meeting.id)
            .join("mic-chunks");
        let output = directory.parent().unwrap().join("mic.wav");
        let writer = ChunkWriter::new(&directory, rate)?;
        let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<i16>>(128);
        let stop = Arc::new(AtomicBool::new(false));
        let dropped = Arc::new(AtomicU64::new(0));
        let dropped_clone = dropped.clone();
        let send = move |data: Vec<i16>| {
            if tx.try_send(data).is_err() {
                dropped_clone.fetch_add(1, Ordering::Relaxed);
            }
        };
        let stream_error = Arc::new(Mutex::new(None));
        let error_state = stream_error.clone();
        let error = move |_error| {
            if let Ok(mut state) = error_state.lock() {
                *state = Some(
                    "Microphone stream failed; review the recorded audio before relying on it"
                        .into(),
                );
            }
        };
        let stream = match supported.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(
                &config,
                move |data: &[f32], _| {
                    send(
                        data.chunks(channels)
                            .map(|frame| {
                                (frame.iter().copied().sum::<f32>() / channels as f32 * 32767.)
                                    .clamp(-32768., 32767.) as i16
                            })
                            .collect(),
                    )
                },
                error,
                None,
            )?,
            cpal::SampleFormat::I16 => device.build_input_stream(
                &config,
                move |data: &[i16], _| {
                    send(
                        data.chunks(channels)
                            .map(|frame| {
                                (frame.iter().map(|s| i64::from(*s)).sum::<i64>() / channels as i64)
                                    as i16
                            })
                            .collect(),
                    )
                },
                error,
                None,
            )?,
            cpal::SampleFormat::U16 => device.build_input_stream(
                &config,
                move |data: &[u16], _| {
                    send(
                        data.chunks(channels)
                            .map(|frame| {
                                (frame.iter().map(|s| i64::from(*s) - 32768).sum::<i64>()
                                    / channels as i64) as i16
                            })
                            .collect(),
                    )
                },
                error,
                None,
            )?,
            _ => bail!("The microphone uses an unsupported sample format"),
        };
        stream.play()?;
        meeting.media.push(Media {
            track: "mic".into(),
            path: format!("meetings/{}/mic.wav", meeting.id),
        });
        library.save_meeting(&meeting)?;
        let thread = spawn_recording_writer(
            writer,
            rx,
            stop.clone(),
            dropped.clone(),
            stream_error.clone(),
            output,
        );
        Ok(Self {
            meeting_id: meeting.id,
            started: Instant::now(),
            dropped,
            stream_error,
            stop,
            thread: Some(thread),
            stream: Some(stream),
        })
    }
    #[cfg(not(feature = "audio"))]
    pub fn start(_library: &mut Library, _title: &str) -> Result<Self> {
        bail!("This build has no microphone backend")
    }
    /// Drop the non-Send device stream on its owner thread, then move only the
    /// writer's join handle to a worker for WAV assembly and database writes.
    pub fn stop(mut self) -> FinalizingRecording {
        self.stop.store(true, Ordering::Release);
        #[cfg(feature = "audio")]
        {
            self.stream.take();
        }
        FinalizingRecording {
            meeting_id: self.meeting_id.clone(),
            dropped: self.dropped.clone(),
            stream_error: self.stream_error.clone(),
            thread: self.thread.take(),
        }
    }
    pub fn finish(self, library: &mut Library) -> Result<String> {
        self.stop().finish(library)
    }
}
#[cfg(any(feature = "audio", test))]
fn spawn_recording_writer(
    mut writer: ChunkWriter,
    rx: std::sync::mpsc::Receiver<Vec<i16>>,
    stop: Arc<AtomicBool>,
    dropped: Arc<AtomicU64>,
    error_state: Arc<Mutex<Option<String>>>,
    output: PathBuf,
) -> std::thread::JoinHandle<Result<f64>> {
    std::thread::spawn(move || {
        let result = (|| {
            loop {
                match rx.recv_timeout(std::time::Duration::from_millis(100)) {
                    Ok(samples) => writer.append(&samples)?,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        if stop.load(Ordering::Acquire) {
                            break;
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
            writer.finish(dropped.load(Ordering::Relaxed), &output)
        })();
        if let Err(error) = &result {
            if let Ok(mut state) = error_state.lock() {
                *state = Some(format!(
                    "Recording stopped because audio could not be saved: {error}"
                ));
            }
            stop.store(true, Ordering::Release);
        }
        result
    })
}
pub struct FinalizingRecording {
    meeting_id: String,
    dropped: Arc<AtomicU64>,
    stream_error: Arc<Mutex<Option<String>>>,
    thread: Option<std::thread::JoinHandle<Result<f64>>>,
}
impl FinalizingRecording {
    pub fn finish(mut self, library: &mut Library) -> Result<String> {
        let result = self
            .thread
            .take()
            .context("Recording is already stopped")?
            .join()
            .map_err(|_| anyhow::anyhow!("Audio writer stopped unexpectedly"))?;
        let mut meeting = library.meeting(&self.meeting_id)?;
        if let Ok(duration) = result.as_ref() {
            meeting.duration = *duration;
        } else if let Err(error) = &result {
            meeting.warnings.push(format!("Recording stopped before it could be saved: {error}. Closed checkpoints will be checked on next launch."));
        }
        let dropped = self.dropped.load(Ordering::Relaxed);
        if dropped > 0 {
            meeting.warnings.push(format!("{dropped} audio buffers were dropped; check the recording before relying on its transcript."));
        }
        if let Some(error) = self.stream_error.lock().ok().and_then(|s| s.clone()) {
            meeting.warnings.push(error);
        }
        library.save_meeting(&meeting)?;
        result?;
        let chunks = library
            .root
            .join("meetings")
            .join(&meeting.id)
            .join("mic-chunks");
        if chunks.is_dir() {
            fs::remove_dir_all(chunks)?;
        }
        cleanup_audio_temporary_files(&library.root.join("meetings").join(&meeting.id))?;
        Ok(meeting.id)
    }
}
impl Drop for Recording {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        #[cfg(feature = "audio")]
        {
            self.stream.take();
        }
        // The writer finishes independently; relaunch repairs its metadata.
        // Joining here would freeze the UI when a window closes.
        self.thread.take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stopping_transfers_finalization_without_waiting_on_the_owner_thread() {
        let directory = tempfile::tempdir().unwrap();
        let mut lib = Library::open(directory.path()).unwrap();
        let meeting = Meeting::empty("Synthetic slow finalization");
        lib.save_meeting(&meeting).unwrap();
        let (release, gate) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            gate.recv_timeout(std::time::Duration::from_secs(3))?;
            Ok(10.)
        });
        let recording = Recording {
            meeting_id: meeting.id,
            started: Instant::now(),
            dropped: Arc::new(AtomicU64::new(0)),
            stream_error: Arc::new(Mutex::new(None)),
            stop: Arc::new(AtomicBool::new(false)),
            thread: Some(thread),
            #[cfg(feature = "audio")]
            stream: None,
        };
        let start = Instant::now();
        let finalizing = recording.stop();
        assert!(start.elapsed() < std::time::Duration::from_millis(100));
        release.send(()).unwrap();
        std::thread::spawn(move || {
            finalizing.finish(&mut lib).unwrap();
        })
        .join()
        .unwrap();
    }
    #[test]
    fn disk_write_failure_stops_recording_and_persists_a_visible_warning() {
        let directory = tempfile::tempdir().unwrap();
        let mut lib = Library::open(directory.path()).unwrap();
        let meeting = Meeting::empty("Synthetic disk failure");
        lib.save_meeting(&meeting).unwrap();
        let chunks = directory
            .path()
            .join("meetings")
            .join(&meeting.id)
            .join("mic-chunks");
        let writer = ChunkWriter::new(&chunks, 16000).unwrap();
        fs::remove_dir(&chunks).unwrap();
        fs::write(&chunks, b"synthetic unwritable directory").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        let stop = Arc::new(AtomicBool::new(false));
        let dropped = Arc::new(AtomicU64::new(0));
        let error = Arc::new(Mutex::new(None));
        let thread = spawn_recording_writer(
            writer,
            rx,
            stop.clone(),
            dropped.clone(),
            error.clone(),
            chunks.parent().unwrap().join("mic.wav"),
        );
        tx.send(vec![3; 32000]).unwrap();
        drop(tx);
        let deadline = Instant::now() + std::time::Duration::from_secs(2);
        while !thread.is_finished() && Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(stop.load(Ordering::Acquire));
        assert!(
            error
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .contains("could not be saved")
        );
        let recording = Recording {
            meeting_id: meeting.id.clone(),
            started: Instant::now(),
            dropped,
            stream_error: error,
            stop,
            thread: Some(thread),
            #[cfg(feature = "audio")]
            stream: None,
        };
        assert!(recording.stop().finish(&mut lib).is_err());
        assert!(
            lib.meeting(&meeting.id)
                .unwrap()
                .warnings
                .iter()
                .any(|w| w.contains("stopped before it could be saved"))
        );
    }
}
