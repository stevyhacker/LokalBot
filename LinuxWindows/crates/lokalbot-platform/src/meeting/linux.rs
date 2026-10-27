//! Linux evidence: recording streams from PulseAudio or PipeWire
//! (`pactl -f json list source-outputs`, falling back to the text listing),
//! and window titles from X11's client list or the Hyprland/Sway IPC. Other
//! Wayland desktops get titles through `MeetingDetector::observe_window`.

use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use anyhow::{Context as _, bail};
use serde_json::Value;

use super::{CaptureStream, Evidence, EvidenceSource, WindowTitle, browser_family};
use crate::process::{find_program, output_with_timeout};

const PACTL_TIMEOUT: Duration = Duration::from_secs(3);

pub(super) struct PulseEvidence {
    pactl: Option<PathBuf>,
    json: bool,
    windows: crate::activity::WindowLister,
}

impl PulseEvidence {
    pub(super) fn new() -> Self {
        Self {
            pactl: find_program("pactl"),
            json: true,
            windows: crate::activity::WindowLister::new(),
        }
    }

    fn streams(&mut self) -> anyhow::Result<Vec<CaptureStream>> {
        let Some(pactl) = &self.pactl else {
            bail!("pactl is not installed");
        };
        if self.json {
            let mut command = Command::new(pactl);
            command
                .args(["-f", "json", "list", "source-outputs"])
                .env("LC_ALL", "C");
            let output = output_with_timeout(command, PACTL_TIMEOUT)?;
            if output.status.success()
                && let Ok(streams) = parse_json(&output.stdout)
            {
                return Ok(streams);
            }
            // pactl before PulseAudio 16 has no JSON output.
            log::info!("meeting detection: pactl JSON unavailable, using the text listing");
            self.json = false;
        }
        let mut command = Command::new(pactl);
        command.args(["list", "source-outputs"]).env("LC_ALL", "C");
        let output = output_with_timeout(command, PACTL_TIMEOUT)?;
        if !output.status.success() {
            bail!(
                "pactl failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(parse_text(&String::from_utf8_lossy(&output.stdout)))
    }
}

impl EvidenceSource for PulseEvidence {
    fn collect(&mut self) -> anyhow::Result<Evidence> {
        let capturing = self.streams()?;
        // Window titles matter only while a browser holds the microphone.
        let windows = if capturing
            .iter()
            .any(|stream| browser_family(&stream.process_name).is_some())
        {
            self.windows
                .list()
                .into_iter()
                .map(|(app, title)| WindowTitle { app, title })
                .collect()
        } else {
            Vec::new()
        };
        Ok(Evidence { capturing, windows })
    }

    fn limitation(&self) -> Option<String> {
        self.pactl.is_none().then(|| {
            "Meeting detection needs the “pactl” command. Install the pulseaudio-utils package (it works with PipeWire too).".to_string()
        })
    }
}

fn stream_from(properties: impl Fn(&str) -> Option<String>, corked: bool) -> Option<CaptureStream> {
    if corked {
        return None;
    }
    let pid = properties("application.process.id")?.parse::<u32>().ok()?;
    let binary = properties("application.process.binary").unwrap_or_default();
    Some(CaptureStream {
        pid,
        process_name: binary,
        app_name: properties("application.name"),
        ancestors: Vec::new(),
    })
}

fn parse_json(bytes: &[u8]) -> anyhow::Result<Vec<CaptureStream>> {
    let value: Value = serde_json::from_slice(bytes).context("unexpected pactl JSON")?;
    let Some(outputs) = value.as_array() else {
        bail!("unexpected pactl JSON");
    };
    Ok(outputs
        .iter()
        .filter_map(|output| {
            let properties = output.get("properties")?;
            let corked = output
                .get("corked")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            stream_from(
                |key| {
                    properties.get(key).and_then(|v| match v {
                        Value::String(s) => Some(s.clone()),
                        Value::Number(n) => Some(n.to_string()),
                        _ => None,
                    })
                },
                corked,
            )
        })
        .collect())
}

/// `pactl list source-outputs` in the C locale.
fn parse_text(text: &str) -> Vec<CaptureStream> {
    let mut streams = Vec::new();
    for block in text.split("Source Output #").skip(1) {
        let mut corked = false;
        let mut properties: Vec<(String, String)> = Vec::new();
        for line in block.lines() {
            let line = line.trim();
            if let Some(value) = line.strip_prefix("Corked:") {
                corked = value.trim() == "yes";
            } else if let Some((key, value)) = line.split_once(" = ") {
                properties.push((
                    key.trim().to_string(),
                    value.trim().trim_matches('"').to_string(),
                ));
            }
        }
        let lookup = |key: &str| {
            properties
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| v.clone())
        };
        streams.extend(stream_from(lookup, corked));
    }
    streams
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pactl_json() {
        let json = br#"[
          {"index":51,"driver":"PipeWire","corked":false,"properties":{"application.name":"ZOOM VoiceEngine","application.process.id":"4242","application.process.binary":"zoom","media.name":"RecordStream"}},
          {"index":52,"corked":true,"properties":{"application.process.id":"77","application.process.binary":"chrome"}},
          {"index":53,"corked":false,"properties":{"application.name":"no pid"}}
        ]"#;
        let streams = parse_json(json).unwrap();
        assert_eq!(
            streams,
            vec![CaptureStream {
                pid: 4242,
                process_name: "zoom".into(),
                app_name: Some("ZOOM VoiceEngine".into()),
                ancestors: Vec::new(),
            }]
        );
        assert!(parse_json(b"not json").is_err());
    }

    #[test]
    fn pactl_text() {
        let text = "Source Output #51\n\tDriver: PipeWire\n\tCorked: no\n\tProperties:\n\t\tapplication.name = \"Slack\"\n\t\tapplication.process.id = \"901\"\n\t\tapplication.process.binary = \"slack\"\n\nSource Output #52\n\tCorked: yes\n\tProperties:\n\t\tapplication.process.id = \"5\"\n\t\tapplication.process.binary = \"firefox\"\n";
        let streams = parse_text(text);
        assert_eq!(streams.len(), 1);
        assert_eq!(streams[0].pid, 901);
        assert_eq!(streams[0].process_name, "slack");
        assert_eq!(streams[0].app_name.as_deref(), Some("Slack"));
    }
}
