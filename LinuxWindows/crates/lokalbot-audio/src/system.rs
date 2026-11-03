//! System audio ("Them"): the meeting app's sound when it can be separated
//! (`app_audio`), otherwise what the computer plays, captured from the default
//! output device and followed when the user switches outputs.
//!
//! - Linux: the default sink's monitor through the PulseAudio protocol (works
//!   with PulseAudio and PipeWire's pipewire-pulse), asking the server for
//!   16 kHz mono float. Falls back to `parec`, then `pw-record`. An app's own
//!   sound is a monitor of each of its sink inputs.
//! - Windows: WASAPI loopback of the default render endpoint. An app's own
//!   sound is WASAPI process loopback of its process tree.

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use anyhow::Result;

use crate::app_audio::{AppAudioTarget, AppStream, Scope, ScopeChooser};
use crate::capture::StreamFlags;
use crate::track::ChunkSink;

/// How often the default output device and the app's streams are checked.
const DEVICE_POLL: Duration = Duration::from_secs(2);

pub(crate) struct SystemCapture {
    /// Empty only for the moment a capture is being replaced.
    inner: Option<platform::Capture>,
    sink: ChunkSink,
    flags: Arc<StreamFlags>,
    last_poll: Instant,
    target: Option<AppAudioTarget>,
    chooser: ScopeChooser,
    scope: Scope,
    /// The app whose sound couldn't be separated, for the recording's warnings.
    tap_problem: Option<String>,
}

impl SystemCapture {
    /// Starts on the app's sound when it can be separated, else on the whole
    /// output. Only a failure of the whole output is an error.
    pub fn start(
        sink: ChunkSink,
        flags: Arc<StreamFlags>,
        target: Option<AppAudioTarget>,
    ) -> Result<Self> {
        let mut capture = Self {
            inner: None,
            sink,
            flags,
            last_poll: Instant::now(),
            chooser: ScopeChooser::new(target.is_some() && platform::tap_supported()),
            target,
            scope: Scope::WholeOutput,
            tap_problem: None,
        };
        let streams = capture.app_streams();
        let wanted = capture
            .chooser
            .observe(streams.as_ref().map(|s| !s.is_empty()), Instant::now());
        capture.open(wanted, streams.as_deref())?;
        Ok(capture)
    }

    pub fn flags(&self) -> &Arc<StreamFlags> {
        &self.flags
    }

    /// The app's output streams, or `None` when they can't be read.
    fn app_streams(&self) -> Option<Vec<AppStream>> {
        self.target.as_ref().and_then(platform::app_streams)
    }

    /// Replaces the running capture. The old one stops first, so no buffer is
    /// written twice; the track's timeline fills the moment between them. A
    /// tap that won't open falls back to the whole output.
    fn open(&mut self, scope: Scope, streams: Option<&[AppStream]>) -> Result<()> {
        self.inner = None;
        self.flags.reset();
        if scope == Scope::App
            && let Some(target) = &self.target
        {
            match platform::Capture::start_app(
                target,
                streams.unwrap_or_default(),
                self.sink.clone(),
                Arc::clone(&self.flags),
            ) {
                Ok(capture) => {
                    log::info!("audio: capturing system audio from {}", target.app_name);
                    // A tapped app delivers nothing while it plays nothing.
                    self.sink
                        .state()
                        .silent_without_packets
                        .store(true, Ordering::Relaxed);
                    self.inner = Some(capture);
                    self.scope = Scope::App;
                    return Ok(());
                }
                Err(error) => {
                    log::warn!(
                        "audio: could not capture {} alone ({error:#}); recording the whole output",
                        target.app_name
                    );
                    self.tap_problem = Some(target.app_name.clone());
                    self.chooser.tap_failed(Instant::now());
                }
            }
        }
        // The default output's monitor delivers silence continuously on Linux;
        // Windows loopback sets this for itself.
        self.sink
            .state()
            .silent_without_packets
            .store(false, Ordering::Relaxed);
        self.scope = Scope::WholeOutput;
        self.inner = Some(platform::Capture::start(
            self.sink.clone(),
            Arc::clone(&self.flags),
        )?);
        Ok(())
    }

    /// The call this recording belongs to was found. Takes effect at the next poll.
    pub fn set_target(&mut self, target: AppAudioTarget) {
        self.chooser = ScopeChooser::new(platform::tap_supported());
        self.target = Some(target);
        self.last_poll = Instant::now() - DEVICE_POLL;
    }

    /// The app whose sound couldn't be separated, once.
    pub fn take_tap_problem(&mut self) -> Option<String> {
        self.tap_problem.take()
    }

    /// Follows the app's streams and the default output. Returns a note for
    /// the log when the capture moved.
    pub fn follow(&mut self) -> Option<String> {
        if self.last_poll.elapsed() < DEVICE_POLL {
            return None;
        }
        self.last_poll = Instant::now();
        let streams = self.app_streams();
        let wanted = self
            .chooser
            .observe(streams.as_ref().map(|s| !s.is_empty()), Instant::now());
        if wanted != self.scope {
            return match self.open(wanted, streams.as_deref()) {
                Ok(()) => Some(match self.scope {
                    Scope::App => "System audio now follows the meeting app".to_string(),
                    Scope::WholeOutput => "System audio now records the whole output".to_string(),
                }),
                Err(error) => {
                    self.flags.fail(format!("{error:#}"));
                    None
                }
            };
        }
        let capture = self.inner.as_mut()?;
        if self.scope == Scope::App {
            if let Some(streams) = streams.as_deref()
                && let Err(error) = capture.sync_app(streams)
            {
                log::warn!("audio: the meeting app's streams could not be followed: {error:#}");
            }
            return None;
        }
        if !capture.default_device_changed() {
            return None;
        }
        self.restart().ok()?;
        let name = self.inner.as_ref()?.device_name();
        Some(format!("System audio now follows {name}"))
    }

    /// Reopens what is being recorded. A tap that won't reopen becomes the
    /// whole output here, so only a failure of the whole output is an error.
    pub fn restart(&mut self) -> Result<()> {
        let streams = self.app_streams();
        self.open(self.scope, streams.as_deref())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::collections::HashMap;
    use std::ffi::CString;
    use std::io::Read;
    use std::process::{Child, Command, Stdio};
    use std::sync::Arc;
    use std::sync::mpsc;
    use std::time::Duration;

    use anyhow::{Context, Result, anyhow};
    use futures_executor::block_on;
    use parking_lot::Mutex;
    use pulseaudio::protocol;

    use crate::app_audio::{AppAudioTarget, AppStream, StreamMixer, normalized};
    use crate::capture::StreamFlags;
    use crate::track::ChunkSink;
    use crate::wav::SAMPLE_RATE;

    const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
    const PACTL_TIMEOUT: Duration = Duration::from_secs(2);
    /// 20 ms of 16 kHz mono f32.
    const FRAGMENT_BYTES: u32 = SAMPLE_RATE / 50 * 4;

    pub(super) enum Capture {
        Pulse(PulseCapture),
        Process(ProcessCapture),
        App(AppCapture),
    }

    /// An app's sound can be told apart when `pactl` can list it.
    pub fn tap_supported() -> bool {
        Command::new("pactl")
            .arg("--version")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    /// The target's open, playing sink inputs. `None` when `pactl` can't say.
    pub fn app_streams(target: &AppAudioTarget) -> Option<Vec<AppStream>> {
        let inputs = sink_inputs()?;
        Some(matching_streams(&inputs, target, std::process::id()))
    }

    impl Capture {
        pub fn start_app(
            _target: &AppAudioTarget,
            streams: &[AppStream],
            sink: ChunkSink,
            _flags: Arc<StreamFlags>,
        ) -> Result<Self> {
            AppCapture::start(streams, sink).map(Self::App)
        }

        pub fn sync_app(&mut self, streams: &[AppStream]) -> Result<()> {
            match self {
                Self::App(capture) => capture.sync(streams),
                _ => Ok(()),
            }
        }

        pub fn start(sink: ChunkSink, flags: Arc<StreamFlags>) -> Result<Self> {
            let pulse_error = match PulseCapture::start(sink.clone(), Arc::clone(&flags)) {
                Ok(capture) => return Ok(Self::Pulse(capture)),
                Err(error) => error,
            };
            log::warn!("audio: PulseAudio monitor capture failed ({pulse_error:#}); trying parec");
            let parec = [
                "--device=@DEFAULT_MONITOR@",
                "--format=float32le",
                "--rate=16000",
                "--channels=1",
                "--raw",
                "--latency-msec=20",
                "--client-name=LokalBot",
                "--stream-name=System audio",
            ];
            match ProcessCapture::start("parec", &parec, sink.clone(), Arc::clone(&flags)) {
                Ok(capture) => return Ok(Self::Process(capture)),
                Err(error) => log::warn!("audio: parec failed ({error:#}); trying pw-record"),
            }
            let pw_record = [
                "--rate",
                "16000",
                "--channels",
                "1",
                "--format",
                "f32",
                "-P",
                "{ stream.capture.sink = true }",
                "-",
            ];
            ProcessCapture::start("pw-record", &pw_record, sink, flags)
                .map(Self::Process)
                .map_err(|_| pulse_error)
        }

        pub fn device_name(&self) -> String {
            match self {
                Self::Pulse(capture) => capture.sink_description.clone(),
                Self::Process(capture) => capture.program.to_string(),
                Self::App(_) => String::new(),
            }
        }

        pub fn default_device_changed(&self) -> bool {
            match self {
                Self::Pulse(capture) => capture.default_sink_changed(),
                // The server resolves @DEFAULT_MONITOR@ once; restart to follow.
                Self::Process(_) => false,
                // Each stream is reopened when it moves to another device.
                Self::App(_) => false,
            }
        }
    }

    /// An app's sound: one monitor of each of its sink inputs, mixed. Nothing
    /// else on the output reaches these streams, and the app's own routing and
    /// volume are left alone.
    pub(super) struct AppCapture {
        client: pulseaudio::Client,
        lanes: HashMap<u32, (u32, pulseaudio::RecordStream)>,
        mixer: Arc<Mutex<StreamMixer>>,
        sink: ChunkSink,
    }

    impl AppCapture {
        fn start(streams: &[AppStream], sink: ChunkSink) -> Result<Self> {
            if streams.is_empty() {
                return Err(anyhow!("the app has no open output stream"));
            }
            let mut capture = Self {
                client: connect()?,
                lanes: HashMap::new(),
                mixer: Arc::new(Mutex::new(StreamMixer::default())),
                sink,
            };
            capture.sync(streams)?;
            Ok(capture)
        }

        /// Opens monitors for new streams and closes those of finished ones.
        /// A stream that moved to another device is reopened there: the server
        /// ends a monitor when its sink input moves.
        fn sync(&mut self, streams: &[AppStream]) -> Result<()> {
            let gone: Vec<u32> = self
                .lanes
                .iter()
                .filter(|(id, (device, _))| {
                    !streams.contains(&AppStream {
                        id: **id,
                        device: *device,
                    })
                })
                .map(|(id, _)| *id)
                .collect();
            for id in gone {
                self.lanes.remove(&id);
                self.mixer.lock().remove(id);
            }
            let mut first_error = None;
            for stream in streams {
                if self.lanes.contains_key(&stream.id) {
                    continue;
                }
                if let Err(error) = self.open_lane(*stream) {
                    log::debug!("audio: no monitor for sink input {}: {error:#}", stream.id);
                    first_error.get_or_insert(error);
                }
            }
            // Nothing to record from at all is a failed tap; one stream that
            // won't open while others record is not.
            match first_error {
                Some(error) if self.lanes.is_empty() => Err(error),
                _ => Ok(()),
            }
        }

        fn open_lane(&mut self, stream: AppStream) -> Result<()> {
            let info = block_on(self.client.sink_info(stream.device))
                .context("the app's output device is gone")?;
            let monitor = info
                .monitor_source_index
                .ok_or_else(|| anyhow!("the output device has no monitor"))?;
            let params = protocol::RecordStreamParams {
                sample_spec: protocol::SampleSpec {
                    format: protocol::SampleFormat::Float32Le,
                    channels: 1,
                    sample_rate: SAMPLE_RATE,
                },
                channel_map: protocol::ChannelMap::mono(),
                source_index: Some(monitor),
                direct_on_input_index: Some(stream.id),
                buffer_attr: protocol::stream::BufferAttr {
                    fragment_size: FRAGMENT_BYTES,
                    ..Default::default()
                },
                flags: protocol::stream::StreamFlags {
                    adjust_latency: true,
                    no_move: true,
                    ..Default::default()
                },
                ..Default::default()
            };
            let (mixer, sink, lane) = (Arc::clone(&self.mixer), self.sink.clone(), stream.id);
            mixer.lock().add(lane);
            let opened = block_on(self.client.create_record_stream(
                params,
                move |bytes: &[u8]| {
                    let samples: Vec<f32> = bytes
                        .as_chunks::<4>()
                        .0
                        .iter()
                        .map(|b| f32::from_le_bytes(*b))
                        .collect();
                    let mixed = mixer.lock().push(lane, &samples);
                    sink.push(mixed, SAMPLE_RATE);
                },
            ));
            match opened {
                Ok(record) => {
                    self.lanes.insert(lane, (stream.device, record));
                    Ok(())
                }
                Err(error) => {
                    self.mixer.lock().remove(lane);
                    Err(error).context("could not monitor the stream")
                }
            }
        }
    }

    /// One entry of `pactl list sink-inputs`.
    #[derive(Clone, Debug, Default, PartialEq, Eq)]
    pub(super) struct SinkInput {
        pub index: u32,
        pub sink: u32,
        pub corked: bool,
        pub pid: Option<u32>,
        pub binary: String,
        pub name: String,
    }

    fn sink_inputs() -> Option<Vec<SinkInput>> {
        if let Some(bytes) = pactl(&["-f", "json", "list", "sink-inputs"])
            && let Some(inputs) = parse_sink_inputs_json(&bytes)
        {
            return Some(inputs);
        }
        // pactl before PulseAudio 16 has no JSON output.
        let bytes = pactl(&["list", "sink-inputs"])?;
        Some(parse_sink_inputs_text(&String::from_utf8_lossy(&bytes)))
    }

    /// Runs `pactl` in the C locale, and gives up on a hung server.
    fn pactl(args: &[&str]) -> Option<Vec<u8>> {
        let mut child = Command::new("pactl")
            .args(args)
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let mut stdout = child.stdout.take()?;
        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            stdout.read_to_end(&mut bytes).ok().map(|_| bytes)
        });
        let deadline = std::time::Instant::now() + PACTL_TIMEOUT;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => {
                    let bytes = reader.join().ok().flatten();
                    return bytes.filter(|_| status.success());
                }
                Ok(None) if std::time::Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return None;
                }
            }
        }
    }

    pub(super) fn parse_sink_inputs_json(bytes: &[u8]) -> Option<Vec<SinkInput>> {
        let value: serde_json::Value = serde_json::from_slice(bytes).ok()?;
        Some(
            value
                .as_array()?
                .iter()
                .filter_map(|input| {
                    let properties = input.get("properties")?;
                    let text = |key: &str| {
                        properties.get(key).and_then(|v| match v {
                            serde_json::Value::String(s) => Some(s.clone()),
                            serde_json::Value::Number(n) => Some(n.to_string()),
                            _ => None,
                        })
                    };
                    Some(SinkInput {
                        index: input.get("index")?.as_u64()? as u32,
                        sink: input.get("sink")?.as_u64()? as u32,
                        corked: input
                            .get("corked")
                            .and_then(serde_json::Value::as_bool)
                            .unwrap_or(false),
                        pid: text("application.process.id").and_then(|p| p.parse().ok()),
                        binary: text("application.process.binary").unwrap_or_default(),
                        name: text("application.name").unwrap_or_default(),
                    })
                })
                .collect(),
        )
    }

    pub(super) fn parse_sink_inputs_text(text: &str) -> Vec<SinkInput> {
        let mut inputs = Vec::new();
        for block in text.split("Sink Input #").skip(1) {
            let mut lines = block.lines();
            let Some(index) = lines.next().and_then(|l| l.trim().parse().ok()) else {
                continue;
            };
            let mut input = SinkInput {
                index,
                ..Default::default()
            };
            let mut has_sink = false;
            for line in lines {
                let line = line.trim();
                let value = |raw: &str| raw.trim().trim_matches('"').to_string();
                if let Some(rest) = line.strip_prefix("Sink:") {
                    if let Ok(sink) = rest.trim().parse() {
                        input.sink = sink;
                        has_sink = true;
                    }
                } else if let Some(rest) = line.strip_prefix("Corked:") {
                    input.corked = rest.trim() == "yes";
                } else if let Some(rest) = line.strip_prefix("application.process.id =") {
                    input.pid = value(rest).parse().ok();
                } else if let Some(rest) = line.strip_prefix("application.process.binary =") {
                    input.binary = value(rest);
                } else if let Some(rest) = line.strip_prefix("application.name =") {
                    input.name = value(rest);
                }
            }
            if has_sink {
                inputs.push(input);
            }
        }
        inputs
    }

    /// The target's playing sink inputs, in a steady order. A stream counts by
    /// its process or by the same executable, since a call's sound can come
    /// from another process of the app. LokalBot's own never does.
    pub(super) fn matching_streams(
        inputs: &[SinkInput],
        target: &AppAudioTarget,
        own_pid: u32,
    ) -> Vec<AppStream> {
        let wanted = normalized(&target.process_name);
        let mut streams: Vec<AppStream> = inputs
            .iter()
            .filter(|input| !input.corked && input.pid != Some(own_pid))
            .filter(|input| {
                input.pid == Some(target.pid)
                    || (!wanted.is_empty() && normalized(&input.binary) == wanted)
            })
            .map(|input| AppStream {
                id: input.index,
                device: input.sink,
            })
            .collect();
        streams.sort();
        streams
    }

    pub(super) struct PulseCapture {
        client: pulseaudio::Client,
        _stream: pulseaudio::RecordStream,
        sink_name: CString,
        sink_description: String,
    }

    fn connect() -> Result<pulseaudio::Client> {
        // The handshake has no socket timeout; never let a hung server block recording.
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(pulseaudio::Client::from_env(c"LokalBot"));
        });
        rx.recv_timeout(CONNECT_TIMEOUT)
            .map_err(|_| anyhow!("the sound server did not answer"))?
            .context("could not connect to the sound server")
    }

    impl PulseCapture {
        fn start(sink: ChunkSink, flags: Arc<StreamFlags>) -> Result<Self> {
            let client = connect()?;
            let info = block_on(client.sink_info_by_name(protocol::DEFAULT_SINK.to_owned()))
                .context("no default output device")?;
            let monitor = info
                .monitor_source_index
                .ok_or_else(|| anyhow!("the output device has no monitor"))?;
            let params = protocol::RecordStreamParams {
                sample_spec: protocol::SampleSpec {
                    format: protocol::SampleFormat::Float32Le,
                    channels: 1,
                    sample_rate: SAMPLE_RATE,
                },
                channel_map: protocol::ChannelMap::mono(),
                source_index: Some(monitor),
                buffer_attr: protocol::stream::BufferAttr {
                    fragment_size: FRAGMENT_BYTES,
                    ..Default::default()
                },
                flags: protocol::stream::StreamFlags {
                    adjust_latency: true,
                    ..Default::default()
                },
                ..Default::default()
            };
            let stream = block_on(client.create_record_stream(params, move |bytes: &[u8]| {
                let samples = bytes
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|b| f32::from_le_bytes(*b))
                    .collect::<Vec<_>>();
                sink.push(samples, SAMPLE_RATE);
            }))
            .context("could not record the output device's monitor")?;
            let description = info
                .description
                .as_ref()
                .unwrap_or(&info.name)
                .to_string_lossy()
                .into_owned();
            log::info!("audio: capturing system audio from {description}");
            let _ = flags;
            Ok(Self {
                client,
                _stream: stream,
                sink_name: info.name,
                sink_description: description,
            })
        }

        fn default_sink_changed(&self) -> bool {
            match block_on(self.client.server_info()) {
                Ok(info) => info
                    .default_sink_name
                    .as_ref()
                    .is_some_and(|name| *name != self.sink_name),
                Err(error) => {
                    log::debug!("audio: server info failed: {error}");
                    false
                }
            }
        }
    }

    pub(super) struct ProcessCapture {
        child: Child,
        program: &'static str,
    }

    impl ProcessCapture {
        fn start(
            program: &'static str,
            args: &[&str],
            sink: ChunkSink,
            flags: Arc<StreamFlags>,
        ) -> Result<Self> {
            let mut child = Command::new(program)
                .args(args)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .with_context(|| format!("could not start {program}"))?;
            let mut stdout = child
                .stdout
                .take()
                .ok_or_else(|| anyhow!("{program} has no output"))?;
            // Fail fast when the tool exits at once (no server, unknown device).
            std::thread::sleep(Duration::from_millis(150));
            if let Ok(Some(status)) = child.try_wait() {
                return Err(anyhow!("{program} exited ({status})"));
            }
            std::thread::Builder::new()
                .name(format!("lokalbot-{program}"))
                .spawn(move || {
                    let mut buffer = vec![0u8; FRAGMENT_BYTES as usize];
                    let mut carry = Vec::new();
                    loop {
                        match stdout.read(&mut buffer) {
                            Ok(0) => {
                                flags.fail(format!("{program} stopped"));
                                break;
                            }
                            Ok(n) => {
                                carry.extend_from_slice(&buffer[..n]);
                                let whole = carry.len() / 4 * 4;
                                let samples = carry[..whole]
                                    .as_chunks::<4>()
                                    .0
                                    .iter()
                                    .map(|b| f32::from_le_bytes(*b))
                                    .collect();
                                carry.drain(..whole);
                                sink.push(samples, SAMPLE_RATE);
                            }
                            Err(error) => {
                                flags.fail(format!("{program}: {error}"));
                                break;
                            }
                        }
                    }
                })?;
            log::info!("audio: capturing system audio with {program}");
            Ok(Self { child, program })
        }
    }

    impl Drop for ProcessCapture {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

#[cfg(target_os = "windows")]
mod platform {
    use std::sync::Arc;
    use std::sync::atomic::Ordering;

    use anyhow::{Result, anyhow};
    use cpal::traits::{DeviceTrait, HostTrait};

    use crate::app_audio::{AppAudioTarget, AppStream};
    use crate::capture::{StreamFlags, open_stream};
    use crate::process_loopback::ProcessLoopback;
    use crate::track::ChunkSink;

    pub(super) enum Capture {
        Output {
            _stream: cpal::Stream,
            key: String,
            name: String,
        },
        App {
            _tap: ProcessLoopback,
        },
    }

    pub fn tap_supported() -> bool {
        crate::process_loopback::supported()
    }

    /// The target's process tree's playing sessions. `None` when they can't be read.
    pub fn app_streams(target: &AppAudioTarget) -> Option<Vec<AppStream>> {
        crate::process_loopback::playing_processes(target.pid)
    }

    fn default_output() -> Option<(cpal::Device, String, String)> {
        let device = crate::capture::host().default_output_device()?;
        let name = device
            .description()
            .map(|d| d.name().to_string())
            .unwrap_or_default();
        let id = device.id().map(|id| id.to_string()).unwrap_or_default();
        Some((device, format!("{id}|{name}"), name))
    }

    impl Capture {
        pub fn start(sink: ChunkSink, flags: Arc<StreamFlags>) -> Result<Self> {
            let (device, key, name) =
                default_output().ok_or_else(|| anyhow!("no output device"))?;
            // Loopback delivers nothing while nothing plays.
            sink.state()
                .silent_without_packets
                .store(true, Ordering::Relaxed);
            let stream = open_stream(&device, true, sink, flags)?;
            log::info!("audio: capturing system audio from {name}");
            Ok(Self::Output {
                _stream: stream,
                key,
                name,
            })
        }

        pub fn start_app(
            target: &AppAudioTarget,
            _streams: &[AppStream],
            sink: ChunkSink,
            flags: Arc<StreamFlags>,
        ) -> Result<Self> {
            let _tap = ProcessLoopback::start(target.pid, sink, flags)?;
            Ok(Self::App { _tap })
        }

        /// The process tree follows its own streams.
        pub fn sync_app(&mut self, _streams: &[AppStream]) -> Result<()> {
            Ok(())
        }

        pub fn device_name(&self) -> String {
            match self {
                Self::Output { name, .. } => name.clone(),
                Self::App { .. } => String::new(),
            }
        }

        pub fn default_device_changed(&self) -> bool {
            match self {
                Self::Output { key, .. } => {
                    default_output().is_some_and(|(_, current, _)| current != *key)
                }
                // Process loopback isn't tied to an output device.
                Self::App { .. } => false,
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
mod platform {
    use std::sync::Arc;

    use anyhow::{Result, bail};

    use crate::app_audio::{AppAudioTarget, AppStream};
    use crate::capture::StreamFlags;
    use crate::track::ChunkSink;

    pub(super) struct Capture;

    pub fn tap_supported() -> bool {
        false
    }

    pub fn app_streams(_target: &AppAudioTarget) -> Option<Vec<AppStream>> {
        None
    }

    impl Capture {
        pub fn start(_sink: ChunkSink, _flags: Arc<StreamFlags>) -> Result<Self> {
            bail!("system audio capture is not available on this platform")
        }

        pub fn start_app(
            _target: &AppAudioTarget,
            _streams: &[AppStream],
            _sink: ChunkSink,
            _flags: Arc<StreamFlags>,
        ) -> Result<Self> {
            bail!("system audio capture is not available on this platform")
        }

        pub fn sync_app(&mut self, _streams: &[AppStream]) -> Result<()> {
            Ok(())
        }

        pub fn device_name(&self) -> String {
            String::new()
        }

        pub fn default_device_changed(&self) -> bool {
            false
        }
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::platform::{
        SinkInput, matching_streams, parse_sink_inputs_json, parse_sink_inputs_text,
    };
    use crate::app_audio::{AppAudioTarget, AppStream};

    fn target(pid: u32, name: &str) -> AppAudioTarget {
        AppAudioTarget {
            pid,
            process_name: name.into(),
            app_name: name.into(),
        }
    }

    #[test]
    fn pactl_json_lists_sink_inputs() {
        let json = br#"[
          {"index":51,"sink":3,"corked":false,"properties":{"application.name":"ZOOM VoiceEngine","application.process.id":"4242","application.process.binary":"zoom"}},
          {"index":52,"sink":3,"corked":true,"properties":{"application.process.id":"77","application.process.binary":"chrome"}},
          {"index":53,"properties":{}}
        ]"#;
        let inputs = parse_sink_inputs_json(json).unwrap();
        assert_eq!(inputs.len(), 2);
        assert_eq!(
            inputs[0],
            SinkInput {
                index: 51,
                sink: 3,
                corked: false,
                pid: Some(4242),
                binary: "zoom".into(),
                name: "ZOOM VoiceEngine".into(),
            }
        );
        assert!(inputs[1].corked);
        assert!(parse_sink_inputs_json(b"not json").is_none());
    }

    #[test]
    fn pactl_text_lists_sink_inputs() {
        let text = "Sink Input #51\n\tDriver: PipeWire\n\tSink: 3\n\tCorked: no\n\tProperties:\n\t\tapplication.name = \"Slack\"\n\t\tapplication.process.id = \"901\"\n\t\tapplication.process.binary = \"slack\"\n\nSink Input #52\n\tSink: 4\n\tCorked: yes\n\tProperties:\n\t\tapplication.process.binary = \"firefox\"\n";
        let inputs = parse_sink_inputs_text(text);
        assert_eq!(inputs.len(), 2);
        assert_eq!(inputs[0].index, 51);
        assert_eq!(inputs[0].sink, 3);
        assert_eq!(inputs[0].pid, Some(901));
        assert_eq!(inputs[0].binary, "slack");
        assert!(inputs[1].corked);
    }

    #[test]
    fn only_the_apps_playing_streams_are_recorded() {
        let input = |index, sink, corked, pid, binary: &str| SinkInput {
            index,
            sink,
            corked,
            pid: Some(pid),
            binary: binary.into(),
            name: String::new(),
        };
        let inputs = vec![
            input(9, 1, false, 500, "spotify"),
            input(8, 1, false, 400, "chrome"),
            input(7, 2, false, 401, "CHROME"),
            input(6, 1, true, 400, "chrome"),
            input(5, 1, false, 999, "lokalbot"),
        ];
        // Another process of the same browser counts; music and a paused
        // stream don't.
        assert_eq!(
            matching_streams(&inputs, &target(400, "chrome"), 999),
            vec![
                AppStream { id: 7, device: 2 },
                AppStream { id: 8, device: 1 }
            ]
        );
        assert!(matching_streams(&inputs, &target(1, "zoom"), 999).is_empty());
        // A renamed process still counts by its pid.
        assert_eq!(
            matching_streams(&inputs, &target(500, "spotify-launcher"), 999),
            vec![AppStream { id: 9, device: 1 }]
        );
        // LokalBot's own playback never counts, whatever it's called.
        assert!(matching_streams(&inputs, &target(999, "lokalbot"), 999).is_empty());
    }
}
