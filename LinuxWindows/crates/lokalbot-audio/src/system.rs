//! System audio ("Them"): what the computer plays, captured from the default
//! output device and followed when the user switches outputs.
//!
//! - Linux: the default sink's monitor through the PulseAudio protocol (works
//!   with PulseAudio and PipeWire's pipewire-pulse), asking the server for
//!   16 kHz mono float. Falls back to `parec`, then `pw-record`.
//! - Windows: WASAPI loopback of the default render endpoint.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;

use crate::capture::StreamFlags;
use crate::track::ChunkSink;

/// How often the default output device is checked for a change.
const DEVICE_POLL: Duration = Duration::from_secs(2);

pub(crate) struct SystemCapture {
    inner: platform::Capture,
    sink: ChunkSink,
    flags: Arc<StreamFlags>,
    last_poll: Instant,
}

impl SystemCapture {
    pub fn start(sink: ChunkSink, flags: Arc<StreamFlags>) -> Result<Self> {
        let inner = platform::Capture::start(sink.clone(), Arc::clone(&flags))?;
        Ok(Self {
            inner,
            sink,
            flags,
            last_poll: Instant::now(),
        })
    }

    pub fn flags(&self) -> &Arc<StreamFlags> {
        &self.flags
    }

    /// Restarts capture on the new default output when it changed. Returns a
    /// note for the log when it switched.
    pub fn follow_default_device(&mut self) -> Option<String> {
        if self.last_poll.elapsed() < DEVICE_POLL {
            return None;
        }
        self.last_poll = Instant::now();
        if !self.inner.default_device_changed() {
            return None;
        }
        self.restart()
            .ok()
            .map(|()| format!("System audio now follows {}", self.inner.device_name()))
    }

    pub fn restart(&mut self) -> Result<()> {
        self.flags.reset();
        let replacement = platform::Capture::start(self.sink.clone(), Arc::clone(&self.flags))?;
        self.inner = replacement;
        Ok(())
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::ffi::CString;
    use std::io::Read;
    use std::process::{Child, Command, Stdio};
    use std::sync::Arc;
    use std::sync::mpsc;
    use std::time::Duration;

    use anyhow::{Context, Result, anyhow};
    use futures_executor::block_on;
    use pulseaudio::protocol;

    use crate::capture::StreamFlags;
    use crate::track::ChunkSink;
    use crate::wav::SAMPLE_RATE;

    const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
    /// 20 ms of 16 kHz mono f32.
    const FRAGMENT_BYTES: u32 = SAMPLE_RATE / 50 * 4;

    pub(super) enum Capture {
        Pulse(PulseCapture),
        Process(ProcessCapture),
    }

    impl Capture {
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
            }
        }

        pub fn default_device_changed(&self) -> bool {
            match self {
                Self::Pulse(capture) => capture.default_sink_changed(),
                // The server resolves @DEFAULT_MONITOR@ once; restart to follow.
                Self::Process(_) => false,
            }
        }
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

    use crate::capture::{StreamFlags, open_stream};
    use crate::track::ChunkSink;

    pub(super) struct Capture {
        _stream: cpal::Stream,
        key: String,
        name: String,
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
            Ok(Self {
                _stream: stream,
                key,
                name,
            })
        }

        pub fn device_name(&self) -> String {
            self.name.clone()
        }

        pub fn default_device_changed(&self) -> bool {
            default_output().is_some_and(|(_, key, _)| key != self.key)
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
mod platform {
    use std::sync::Arc;

    use anyhow::{Result, bail};

    use crate::capture::StreamFlags;
    use crate::track::ChunkSink;

    pub(super) struct Capture;

    impl Capture {
        pub fn start(_sink: ChunkSink, _flags: Arc<StreamFlags>) -> Result<Self> {
            bail!("system audio capture is not available on this platform")
        }

        pub fn device_name(&self) -> String {
            String::new()
        }

        pub fn default_device_changed(&self) -> bool {
            false
        }
    }
}
