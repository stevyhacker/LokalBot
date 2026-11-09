//! Linux evidence: recording streams from PulseAudio or PipeWire
//! (`pactl -f json list source-outputs`, falling back to the text listing),
//! and window titles from X11's client list or the Hyprland/Sway IPC. Other
//! Wayland desktops get titles through `MeetingDetector::observe_window`.

use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use anyhow::{Context as _, bail};
use serde_json::Value;

use super::browser::BrowserDocument;
use super::{CaptureStream, Evidence, EvidenceSource, WindowTitle, browser_family};
use crate::process::{find_program, output_with_timeout};

const PACTL_TIMEOUT: Duration = Duration::from_secs(3);
/// A browser's tree answers one question per call, so it is read less often
/// than the poll. `BROWSER_GAP` tolerates the wait.
const CALL_READ_INTERVAL: Duration = Duration::from_secs(4);

pub(super) struct PulseEvidence {
    pactl: Option<PathBuf>,
    json: bool,
    windows: crate::activity::WindowLister,
    calls: crate::screen::BrowserCallReader,
    last_call_read: Option<(std::time::Instant, Vec<BrowserDocument>)>,
}

impl PulseEvidence {
    pub(super) fn new() -> Self {
        Self {
            pactl: find_program("pactl"),
            json: true,
            windows: crate::activity::WindowLister::new(),
            calls: crate::screen::BrowserCallReader::new(),
            last_call_read: None,
        }
    }

    /// Meet documents in the browsers holding a microphone, read at most
    /// every [`CALL_READ_INTERVAL`].
    fn documents(&mut self, capturing: &[CaptureStream]) -> Vec<BrowserDocument> {
        let families: Vec<&'static str> = capturing
            .iter()
            .filter_map(|stream| browser_family(&stream.process_name))
            .collect();
        if families.is_empty() {
            self.last_call_read = None;
            return Vec::new();
        }
        if let Some((at, documents)) = &self.last_call_read
            && at.elapsed() < CALL_READ_INTERVAL
        {
            return documents.clone();
        }
        let documents = self.calls.read(&families, process_family);
        self.last_call_read = Some((std::time::Instant::now(), documents.clone()));
        documents
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
        let documents = self.documents(&capturing);
        Ok(Evidence {
            capturing,
            windows,
            documents,
        })
    }

    fn limitation(&self) -> Option<String> {
        self.pactl.is_none().then(|| {
            "Meeting detection needs the “pactl” command. Install the pulseaudio-utils package (it works with PipeWire too).".to_string()
        })
    }
}

/// Which browser a process on the accessibility bus is, from its executable.
fn process_family(pid: u32) -> Option<&'static str> {
    let exe = std::fs::read_link(format!("/proc/{pid}/exe")).ok();
    exe.as_deref()
        .and_then(|path| path.file_name())
        .and_then(|name| browser_family(&name.to_string_lossy()))
        .or_else(|| {
            let comm = std::fs::read_to_string(format!("/proc/{pid}/comm")).ok()?;
            browser_family(comm.trim())
        })
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
        ancestor_pids: Vec::new(),
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
                ancestor_pids: Vec::new(),
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
