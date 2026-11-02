//! How the microphone and call tracks line up (`RecordingAudioTiming`).
//!
//! A Mac keeps `audio-timing.json` with clock anchors. This app writes both
//! tracks on one shared meeting timeline, padding any gap with silence, so a
//! `.wav` recording needs no anchors: the same second is the same second.

use std::path::Path;

use serde::{Deserialize, Serialize};

use super::TurnAnchor;

pub const TIMING_FILE: &str = "audio-timing.json";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioClockSpan {
    pub host_start: f64,
    pub host_end: f64,
    pub start_frame: i64,
    pub end_frame: i64,
    pub sample_rate: f64,
    pub generation: i64,
}

impl AudioClockSpan {
    fn covers(&self, start: f64, end: f64) -> bool {
        self.sample_rate > 0.0
            && self.sample_rate.is_finite()
            && self.host_start.is_finite()
            && self.host_end.is_finite()
            && self.start_frame as f64 / self.sample_rate <= start
            && self.end_frame as f64 / self.sample_rate >= end
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingAudioTiming {
    #[serde(default = "version_one")]
    pub version: u32,
    pub microphone: Vec<AudioClockSpan>,
    pub system: Vec<AudioClockSpan>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeline_origin_host_time: Option<f64>,
}

fn version_one() -> u32 {
    1
}

impl RecordingAudioTiming {
    /// Maps both bounds through one continuous span on each track. Padding
    /// and device gaps have no anchors, so this never extrapolates across them.
    pub fn reference_range(&self, start: f64, end: f64) -> Option<TurnAnchor> {
        if !start.is_finite() || !end.is_finite() || end <= start {
            return None;
        }
        let mic = self.microphone.iter().find(|s| s.covers(start, end))?;
        let mic_start = mic.start_frame as f64 / mic.sample_rate;
        let mic_duration = (mic.end_frame - mic.start_frame) as f64 / mic.sample_rate;
        if mic_duration <= 0.0 || mic.host_end <= mic.host_start {
            return None;
        }
        let span = mic.host_end - mic.host_start;
        let host_start = mic.host_start + (start - mic_start) / mic_duration * span;
        let host_end = mic.host_start + (end - mic_start) / mic_duration * span;
        let remote = self.system.iter().find(|s| {
            s.host_start <= host_start
                && s.host_end >= host_end
                && s.sample_rate > 0.0
                && s.host_end > s.host_start
        })?;
        let scale = (remote.end_frame - remote.start_frame) as f64
            / remote.sample_rate
            / (remote.host_end - remote.host_start);
        let origin = remote.start_frame as f64 / remote.sample_rate;
        let range = TurnAnchor {
            start: origin + (host_start - remote.host_start) * scale,
            end: origin + (host_end - remote.host_start) * scale,
        };
        (range.is_valid() && (range.duration() / (end - start) - 1.0).abs() < 0.002)
            .then_some(range)
    }

    /// The next point where a continuous span starts or ends.
    pub fn next_boundary(&self, position: f64) -> Option<f64> {
        const EPSILON: f64 = 0.000_01;
        let mut boundary = f64::INFINITY;
        let mut containing = None;
        for span in self.microphone.iter().filter(|s| s.sample_rate > 0.0) {
            let start = span.start_frame as f64 / span.sample_rate;
            let end = span.end_frame as f64 / span.sample_rate;
            for value in [start, end] {
                if value.is_finite() && value > position + EPSILON {
                    boundary = boundary.min(value);
                }
            }
            if start <= position + EPSILON && end > position + EPSILON {
                containing = Some(span);
            }
        }
        if let Some(mic) = containing.filter(|m| m.host_end > m.host_start) {
            let origin = mic.start_frame as f64 / mic.sample_rate;
            let duration = (mic.end_frame - mic.start_frame) as f64 / mic.sample_rate;
            for remote in &self.system {
                for host in [remote.host_start, remote.host_end] {
                    if host >= mic.host_start && host <= mic.host_end {
                        let value = origin
                            + (host - mic.host_start) / (mic.host_end - mic.host_start) * duration;
                        if value > position + EPSILON {
                            boundary = boundary.min(value);
                        }
                    }
                }
            }
        }
        boundary.is_finite().then_some(boundary)
    }
}

/// What is known about how a meeting's two tracks line up.
#[derive(Clone, Debug, PartialEq)]
pub enum TrackClock {
    /// A Mac's clock anchors.
    Anchored(RecordingAudioTiming),
    /// This app's WAV tracks, already on one timeline.
    SharedTimeline,
    /// An older recording with neither.
    Unknown,
}

impl TrackClock {
    /// The range of the call track played during `start..end` on the microphone.
    pub fn reference_range(&self, start: f64, end: f64) -> Option<TurnAnchor> {
        match self {
            Self::Anchored(timing) => timing.reference_range(start, end),
            Self::SharedTimeline => {
                let range = TurnAnchor { start, end };
                range.is_valid().then_some(range)
            }
            Self::Unknown => None,
        }
    }

    pub fn next_boundary(&self, position: f64) -> Option<f64> {
        match self {
            Self::Anchored(timing) => timing.next_boundary(position),
            _ => None,
        }
    }

    pub fn is_known(&self) -> bool {
        !matches!(self, Self::Unknown)
    }
}

/// The clock of the tracks in a meeting folder.
pub fn reference_clock(folder: &Path) -> TrackClock {
    if let Some(timing) = std::fs::read(folder.join(TIMING_FILE))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<RecordingAudioTiming>(&bytes).ok())
    {
        return TrackClock::Anchored(timing);
    }
    // This app pads both WAV tracks to one timeline and writes no anchors.
    // Without this, a microphone voice could never pass the quiet-call check.
    if folder.join(crate::library::MIC_TRACK).is_file() {
        TrackClock::SharedTimeline
    } else {
        TrackClock::Unknown
    }
}
