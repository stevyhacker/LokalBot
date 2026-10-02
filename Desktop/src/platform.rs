//! OS integration lives here; an unavailable focus/permission probe always refuses screen capture.
use crate::process::bounded_output;
use crate::{
    domain::*,
    privacy::{self, Observation},
    storage::{Library, atomic_write},
};
use anyhow::{Context, Result, ensure};
use std::{process::Command, time::Duration};

#[derive(Clone, serde::Deserialize)]
pub struct Probe {
    pub observation: Observation,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub bounds: [i32; 4],
}
pub fn probe(library: &Library, capture_text: bool) -> Result<Probe> {
    #[cfg(target_os = "linux")]
    {
        let path = library.root.join("helpers/focus_probe.py");
        atomic_write(&path, include_bytes!("../helpers/focus_probe.py"))?;
        let mut command = Command::new("python3");
        command
            .arg(path)
            .arg(if capture_text { "--text" } else { "--metadata" });
        let output = bounded_output(&mut command, Duration::from_secs(4), 128 * 1024)
            .context("Python 3 and python3-pyatspi are needed for Linux accessibility")?;
        ensure!(
            output.status.success(),
            "Desktop accessibility is unavailable; capture was skipped"
        );
        ensure!(
            output.stdout.len() < 128 * 1024,
            "Accessibility response is too large"
        );
        serde_json::from_slice(&output.stdout).context("Desktop focus could not be verified")
    }
    #[cfg(target_os = "windows")]
    {
        let path = library.root.join("helpers/focus_probe.ps1");
        atomic_write(&path, include_bytes!("../helpers/focus_probe.ps1"))?;
        let mut command = Command::new("powershell.exe");
        command
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
            ])
            .arg(path);
        if capture_text {
            command.arg("-CaptureText");
        }
        let output = bounded_output(&mut command, Duration::from_secs(4), 128 * 1024)
            .context("Windows UI Automation is unavailable")?;
        ensure!(
            output.status.success() && output.stdout.len() < 128 * 1024,
            "Windows focus could not be verified"
        );
        serde_json::from_slice(&output.stdout).context("Invalid Windows accessibility result")
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        let _ = (library, capture_text);
        anyhow::bail!(
            "This desktop port targets Linux and Windows; use the native macOS app on macOS"
        )
    }
}
pub fn sample_activity(library: &Library) -> Result<Option<Activity>> {
    let settings = library.settings()?;
    if !settings.activity_enabled || settings.paused {
        return Ok(None);
    }
    let p = probe(library, false)?;
    let private = privacy::excluded(&p.observation, &settings)
        || p.observation.secure != Some(false)
        || !p.observation.focus_verified;
    let a = Activity {
        id: new_id(),
        app: if private {
            "Private".into()
        } else {
            p.observation.app
        },
        title: if private {
            String::new()
        } else {
            privacy::redact(&p.observation.title)
        },
        start: now() - 5,
        end: now(),
        private,
    };
    library.guarded_write(settings.revision, |library| library.save_activity(&a))?;
    Ok(Some(a))
}
pub fn capture_screen(library: &mut Library) -> Result<String> {
    let settings = library.settings()?;
    let before = probe(library, true)?;
    ensure!(
        privacy::allow_screen(&before.observation, &settings),
        "Screen capture is disabled, excluded, secure, or cannot verify the focused field"
    );
    let text = privacy::redact(&before.text);
    ensure!(
        !text.trim().is_empty(),
        "This window exposes no visible accessible text"
    );
    let sensitive = text != before.text;
    let id = new_id();
    let temporary = tempfile::tempdir_in(&library.root)?;
    let pixels = temporary.path().join("capture.png");
    let mut pixel_bytes = None;
    if settings.pixels_enabled && !sensitive {
        let [x, y, w, h] = before.bounds;
        ensure!(
            w > 0 && h > 0 && w <= 16384 && h <= 16384,
            "Invalid focused-window bounds"
        );
        #[cfg(target_os = "linux")]
        {
            let status = if std::env::var_os("WAYLAND_DISPLAY").is_some() {
                bounded_output(
                    Command::new("grim")
                        .arg("-g")
                        .arg(format!("{x},{y} {w}x{h}"))
                        .arg(&pixels),
                    Duration::from_secs(4),
                    4096,
                )
            } else {
                bounded_output(
                    Command::new("ffmpeg")
                        .args([
                            "-nostdin",
                            "-hide_banner",
                            "-loglevel",
                            "error",
                            "-f",
                            "x11grab",
                            "-video_size",
                        ])
                        .arg(format!("{w}x{h}"))
                        .arg("-i")
                        .arg(format!(
                            "{}+{x},{y}",
                            std::env::var("DISPLAY").context("No display")?
                        ))
                        .args(["-frames:v", "1", "-y"])
                        .arg(&pixels),
                    Duration::from_secs(4),
                    4096,
                )
            }
            .context("A focused-window capture tool is unavailable")?;
            ensure!(
                status.status.success(),
                "Focused-window pixel capture failed"
            );
        }
        #[cfg(target_os = "windows")]
        {
            let status = bounded_output(
                Command::new("powershell.exe")
                    .args([
                        "-NoProfile",
                        "-NonInteractive",
                        "-ExecutionPolicy",
                        "Bypass",
                        "-File",
                    ])
                    .arg(library.root.join("helpers/focus_probe.ps1"))
                    .arg("-ScreenshotPath")
                    .arg(&pixels),
                Duration::from_secs(4),
                4096,
            )?;
            ensure!(
                status.status.success(),
                "Focused-window pixel capture failed"
            );
        }
        if pixels.exists() {
            pixel_bytes = Some(std::fs::read(&pixels)?);
        }
    }
    let after = probe(library, true)?;
    ensure!(
        before.text == after.text
            && privacy::capture_still_valid(
                &before.observation,
                &after.observation,
                &library.settings()?,
                settings.revision
            ),
        "Focus or capture permissions changed; the capture was discarded"
    );
    let pixel_path = pixel_bytes.as_ref().map(|_| format!("pixels/{id}.enc"));
    let result = library.guarded_write_mut(settings.revision, |library| {
        ensure!(
            privacy::allow_screen(&after.observation, &library.settings()?),
            "Capture permission was revoked"
        );
        if let (Some(bytes), Some(path)) = (&pixel_bytes, &pixel_path) {
            atomic_write(
                &library.root.join(path),
                &privacy::encrypt_pixels(&library.root, bytes)?,
            )?;
        }
        library.save_moment(&Moment {
            id: id.clone(),
            app: before.observation.app,
            title: privacy::redact(&before.observation.title),
            text,
            created_at: now(),
            saved: false,
            pixels: pixel_path.clone(),
        })?;
        Ok(id)
    });
    if result.is_err()
        && let Some(path) = pixel_path
    {
        let _ = std::fs::remove_file(library.root.join(path));
    }
    result
}

pub fn insert_text(text: &str) -> Result<()> {
    ensure!(text.len() <= 16000, "Text is too large to insert");
    #[cfg(target_os = "linux")]
    {
        ensure!(
            std::env::var_os("WAYLAND_DISPLAY").is_none(),
            "System-wide insertion on Wayland requires a compositor integration; copy text explicitly instead"
        );
        let status = Command::new("xdotool")
            .args(["type", "--clearmodifiers", "--delay", "1", "--"])
            .arg(text)
            .status()?;
        ensure!(status.success(), "Text insertion failed");
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        anyhow::bail!("Use Copy for this platform; system-wide insertion is not yet verified")
    }
}
