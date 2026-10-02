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
    let result = Command::new("ffmpeg")
        .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
        .arg(path)
        .args(["-vn", "-ac", "1", "-ar", "16000", "-y"])
        .arg(&output)
        .output()
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
    let status = Command::new("ffmpeg")
        .args(["-nostdin", "-hide_banner", "-loglevel", "error", "-i"])
        .arg(path)
        .args(["-vn", "-ac", "1", "-ar", "16000", "-y"])
        .arg(&wav)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("FFmpeg is needed for transcription")?;
    ensure!(
        status.success(),
        "Could not convert the audio for local transcription"
    );
    let output = temporary.path().join("transcript");
    let status = Command::new(&settings.whisper_executable)
        .arg("-m")
        .arg(model)
        .arg("-f")
        .arg(&wav)
        .args(["-oj", "-of"])
        .arg(&output)
        .args(["-t", "4", "-ng", "-l", "auto"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("Could not start whisper-cli; configure its executable path")?;
    ensure!(status.success(), "Local Whisper transcription failed");
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
        fs::File::open(&temporary)?.sync_all()?;
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
        self.manifest.complete = true;
        self.manifest.dropped_buffers = dropped;
        atomic_write(
            &self.directory.join("manifest.json"),
            &serde_json::to_vec_pretty(&self.manifest)?,
        )?;
        recover_chunks(&self.directory, output)
    }
}
pub fn recover_chunks(directory: &Path, output: &Path) -> Result<f64> {
    let manifest: Manifest = serde_json::from_slice(&fs::read(directory.join("manifest.json"))?)?;
    ensure!(!manifest.chunks.is_empty(), "No complete audio checkpoints");
    let temporary = output.with_extension("recovery.wav");
    let mut writer = hound::WavWriter::create(
        &temporary,
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
    if output.exists() {
        let existing = hound::WavReader::open(output)?;
        ensure!(
            existing.duration() as u64 <= frames,
            "Existing audio is longer; refusing a shorter recovery"
        );
    }
    fs::rename(temporary, output)?;
    Ok(frames as f64 / f64::from(manifest.rate))
}

/// Repairs closed checkpoints after a process exit without authorizing a new capture.
pub fn recover_recordings(library: &mut Library) -> Result<Vec<String>> {
    let mut recovered = vec![];
    for mut meeting in library.meetings()? {
        let directory = library
            .root
            .join("meetings")
            .join(&meeting.id)
            .join("mic-chunks");
        let manifest_path = directory.join("manifest.json");
        if !manifest_path.is_file() || meeting.duration > 0. {
            continue;
        }
        let manifest: Manifest = serde_json::from_slice(&fs::read(&manifest_path)?)?;
        if manifest.chunks.is_empty() {
            continue;
        }
        let output = directory
            .parent()
            .context("Missing meeting directory")?
            .join("mic.wav");
        meeting.duration = recover_chunks(&directory, &output)?;
        meeting.media = vec![Media {
            track: "mic".into(),
            path: format!("meetings/{}/mic.wav", meeting.id),
        }];
        if !manifest.complete {
            meeting.warnings.push("Recovered verified microphone checkpoints after an interrupted recording; the uncommitted tail may be missing. Recording was not restarted.".into());
        }
        library.save_meeting(&meeting)?;
        recovered.push(meeting.id);
    }
    Ok(recovered)
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
        let stop_clone = stop.clone();
        let dropped_clone = dropped.clone();
        let thread = std::thread::spawn(move || {
            let mut writer = writer;
            loop {
                match rx.recv_timeout(std::time::Duration::from_millis(100)) {
                    Ok(samples) => writer.append(&samples)?,
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                        if stop_clone.load(Ordering::Acquire) {
                            break;
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
            writer.finish(dropped_clone.load(Ordering::Relaxed), &output)
        });
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
    pub fn finish(mut self, library: &mut Library) -> Result<String> {
        self.stop.store(true, Ordering::Release);
        #[cfg(feature = "audio")]
        {
            self.stream.take();
        }
        let duration = self
            .thread
            .take()
            .context("Recording is already stopped")?
            .join()
            .map_err(|_| anyhow::anyhow!("Audio writer stopped unexpectedly"))??;
        let mut meeting = library.meeting(&self.meeting_id)?;
        meeting.duration = duration;
        let dropped = self.dropped.load(Ordering::Relaxed);
        if dropped > 0 {
            meeting.warnings.push(format!("{dropped} audio buffers were dropped; check the recording before relying on its transcript."));
        }
        if let Some(error) = self.stream_error.lock().ok().and_then(|s| s.clone()) {
            meeting.warnings.push(error);
        }
        library.save_meeting(&meeting)?;
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
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
