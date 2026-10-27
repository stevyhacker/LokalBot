//! Microphone devices and cpal input streams.
//!
//! On Linux cpal talks to PulseAudio (or PipeWire through pipewire-pulse) when a
//! server is running, which gives readable device names, and falls back to ALSA.
//! On Windows it uses WASAPI.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample, SampleFormat, SizedSample};
use parking_lot::Mutex;

use crate::track::ChunkSink;

const STREAM_TIMEOUT: Duration = Duration::from_secs(5);

/// A microphone the user can pick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AudioDevice {
    /// Stable identifier to store in settings (`host:device`).
    pub id: String,
    /// Name to show.
    pub name: String,
    pub is_default: bool,
}

pub(crate) fn host() -> cpal::Host {
    cpal::default_host()
}

/// Inputs worth offering: monitor sources (loopback of speakers) and ALSA
/// plumbing devices are left out.
fn is_offered_input(id: &str, name: &str) -> bool {
    let lower = id.to_lowercase();
    if lower.ends_with(".monitor") {
        return false;
    }
    if let Some(device) = lower.strip_prefix("alsa:") {
        const PLUMBING: &[&str] = &[
            "null",
            "surround",
            "front:",
            "rear:",
            "center_lfe",
            "side:",
            "iec958",
            "spdif",
            "hdmi",
            "dmix",
            "dsnoop",
            "lavrate",
            "samplerate",
            "speexrate",
            "upmix",
            "vdownmix",
            "jack",
            "oss",
        ];
        if PLUMBING.iter().any(|p| device.starts_with(p)) {
            return false;
        }
    }
    !name.is_empty()
}

fn device_id(device: &cpal::Device) -> Option<String> {
    device.id().ok().map(|id| id.to_string())
}

fn device_name(device: &cpal::Device) -> String {
    device
        .description()
        .map(|d| d.name().to_string())
        .unwrap_or_default()
}

/// Microphones on this computer, the system default first.
pub fn input_devices() -> Vec<AudioDevice> {
    let host = host();
    let default_id = host.default_input_device().as_ref().and_then(device_id);
    let mut devices: Vec<AudioDevice> = match host.input_devices() {
        Ok(devices) => devices
            .filter_map(|device| {
                let id = device_id(&device)?;
                let name = device_name(&device);
                is_offered_input(&id, &name).then(|| AudioDevice {
                    is_default: Some(&id) == default_id.as_ref(),
                    id,
                    name,
                })
            })
            .collect(),
        Err(error) => {
            log::warn!("audio: could not list input devices: {error}");
            Vec::new()
        }
    };
    devices.sort_by_key(|d| !d.is_default);
    devices.dedup_by(|a, b| a.id == b.id);
    devices
}

/// The microphone to record from: the stored id, then a device with that name,
/// then the system default. The second value explains a fallback.
pub(crate) fn resolve_input_device(
    preferred: Option<&str>,
) -> Result<(cpal::Device, Option<String>)> {
    let host = host();
    let preferred = preferred.map(str::trim).filter(|p| !p.is_empty());
    if let Some(wanted) = preferred {
        if let Ok(id) = wanted.parse::<cpal::DeviceId>()
            && let Some(device) = host.device_by_id(&id)
            && device.supports_input()
        {
            return Ok((device, None));
        }
        if let Ok(mut devices) = host.input_devices()
            && let Some(device) = devices
                .find(|d| device_name(d) == wanted || device_id(d).as_deref() == Some(wanted))
        {
            return Ok((device, None));
        }
    }
    let device = host
        .default_input_device()
        .ok_or_else(|| anyhow!("No microphone is available"))?;
    let warning = preferred.map(|wanted| {
        format!(
            "Microphone “{wanted}” is unavailable — recording from the default microphone ({}).",
            device_name(&device)
        )
    });
    Ok((device, warning))
}

/// Errors reported by a stream's error callback. Xruns and automatic reroutes
/// are counted, not treated as failures.
#[derive(Default)]
pub(crate) struct StreamFlags {
    failed: AtomicBool,
    xruns: AtomicU64,
    last_error: Mutex<Option<String>>,
}

impl StreamFlags {
    pub fn report(&self, error: &cpal::Error) {
        use cpal::ErrorKind;
        match error.kind() {
            ErrorKind::Xrun => {
                self.xruns.fetch_add(1, Ordering::Relaxed);
            }
            ErrorKind::DeviceChanged => {
                log::info!("audio: stream rerouted: {error}");
            }
            _ => self.fail(error.to_string()),
        }
    }

    pub fn fail(&self, message: String) {
        log::warn!("audio: stream failed: {message}");
        *self.last_error.lock() = Some(message);
        self.failed.store(true, Ordering::Release);
    }

    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }

    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().clone()
    }

    pub fn reset(&self) {
        self.failed.store(false, Ordering::Release);
    }
}

/// Opens `device` for capture in its preferred format and feeds mono buffers to
/// `sink`. On Windows, an output device yields a WASAPI loopback stream.
pub(crate) fn open_stream(
    device: &cpal::Device,
    loopback: bool,
    sink: ChunkSink,
    flags: Arc<StreamFlags>,
) -> Result<cpal::Stream> {
    let supported = if loopback {
        device.default_output_config()
    } else {
        device.default_input_config()
    }
    .with_context(|| format!("no usable format for “{}”", device_name(device)))?;
    let format = supported.sample_format();
    let mut config: cpal::StreamConfig = supported.config();
    // Ask for ~30 ms buffers: PulseAudio otherwise delivers 2 s fragments,
    // which delays meters and stream start. Fall back to the device default.
    let wanted = (config.sample_rate * 30 / 1000).max(64);
    if let cpal::SupportedBufferSize::Range { min, max } = supported.buffer_size()
        && (*min..=*max).contains(&wanted)
    {
        config.buffer_size = cpal::BufferSize::Fixed(wanted);
    }
    let stream = match build_any(format, device, &config, &sink, &flags) {
        Ok(stream) => stream,
        Err(error) if config.buffer_size != cpal::BufferSize::Default => {
            log::info!(
                "audio: {}: fixed buffer refused ({error:#}); using the default",
                device_name(device)
            );
            config.buffer_size = cpal::BufferSize::Default;
            build_any(format, device, &config, &sink, &flags)?
        }
        Err(error) => return Err(error),
    };
    stream.play().context("could not start audio capture")?;
    Ok(stream)
}

fn build_any(
    format: SampleFormat,
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    sink: &ChunkSink,
    flags: &Arc<StreamFlags>,
) -> Result<cpal::Stream> {
    let (sink, flags) = (sink.clone(), Arc::clone(flags));
    match format {
        SampleFormat::F32 => build::<f32>(device, config, sink, flags),
        SampleFormat::I16 => build::<i16>(device, config, sink, flags),
        SampleFormat::I32 => build::<i32>(device, config, sink, flags),
        SampleFormat::U16 => build::<u16>(device, config, sink, flags),
        SampleFormat::U8 => build::<u8>(device, config, sink, flags),
        SampleFormat::I8 => build::<i8>(device, config, sink, flags),
        SampleFormat::F64 => build::<f64>(device, config, sink, flags),
        SampleFormat::I24 => build::<cpal::I24>(device, config, sink, flags),
        SampleFormat::U32 => build::<u32>(device, config, sink, flags),
        other => Err(anyhow!("unsupported sample format {other}")),
    }
}

fn build<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    sink: ChunkSink,
    flags: Arc<StreamFlags>,
) -> Result<cpal::Stream>
where
    T: SizedSample + Send + 'static,
    f32: FromSample<T>,
{
    let channels = config.channels.max(1) as usize;
    let rate = config.sample_rate;
    let error_flags = Arc::clone(&flags);
    let stream = device.build_input_stream::<T, _, _>(
        *config,
        move |data: &[T], info: &cpal::InputCallbackInfo| {
            // Place the buffer by when it was captured, not when it arrived.
            let stamp = info.timestamp();
            let latency = stamp.callback.checked_duration_since(stamp.capture);
            sink.push_captured(mix_to_mono(data, channels), rate, latency);
        },
        move |error| error_flags.report(&error),
        Some(STREAM_TIMEOUT),
    )?;
    Ok(stream)
}

pub(crate) fn mix_to_mono<T>(data: &[T], channels: usize) -> Vec<f32>
where
    T: Sample,
    f32: FromSample<T>,
{
    if channels <= 1 {
        return data.iter().map(|s| f32::from_sample_(*s)).collect();
    }
    let scale = 1.0 / channels as f32;
    data.chunks_exact(channels)
        .map(|frame| frame.iter().map(|s| f32::from_sample_(*s)).sum::<f32>() * scale)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hides_monitors_and_alsa_plumbing() {
        assert!(!is_offered_input(
            "pulseaudio:alsa_output.pci.analog-stereo.monitor",
            "Monitor of Speakers"
        ));
        assert!(is_offered_input(
            "pulseaudio:alsa_input.usb-headset.mono",
            "USB Headset"
        ));
        assert!(!is_offered_input("alsa:surround51:CARD=PCH", "surround51"));
        assert!(is_offered_input("alsa:default", "default"));
        assert!(is_offered_input(
            "wasapi:{0.0.1.00000000}.{abc}",
            "Microphone (Realtek)"
        ));
    }

    #[test]
    fn mixes_channels() {
        let stereo = [0.5f32, -0.5, 1.0, 0.0];
        assert_eq!(mix_to_mono(&stereo, 2), vec![0.0, 0.5]);
        let ints = [i16::MAX, i16::MAX];
        assert!((mix_to_mono(&ints, 1)[0] - 1.0).abs() < 1e-3);
    }
}
