//! Wayland has no common way to read another window's pixels:
//!
//! - wlroots compositors (Sway, Hyprland) with `grim` installed: the focused
//!   window's rectangle from the compositor's IPC, read with `grim -g`
//!   straight into memory.
//! - Elsewhere, the xdg-desktop-portal Screenshot API without a dialog
//!   (`interactive: false`). Portals that can target the active window
//!   (version 3) capture just that window. The picture the portal writes is
//!   read, then deleted at once.

use std::io::{Read as _, Write as _};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context as _, bail};
use serde_json::Value;

use super::{CapturedImage, FocusedWindow, WindowCapture, WindowRect};
use crate::session::Desktop;

const IPC_TIMEOUT: Duration = Duration::from_millis(500);
const GRIM_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a portal request may take, including a first permission prompt.
const PORTAL_TIMEOUT: Duration = Duration::from_secs(20);

// ------------------------------------------------------------------- grim

pub(super) struct Grim {
    desktop: Desktop,
    program: PathBuf,
}

impl Grim {
    pub(super) fn new(desktop: Desktop) -> Option<Self> {
        let program = find_program("grim")?;
        Some(Self { desktop, program })
    }
}

impl WindowCapture for Grim {
    fn limitation(&self) -> Option<String> {
        None
    }

    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        match self.desktop {
            Desktop::Sway => sway_focused(),
            Desktop::Hyprland => hyprland_focused(),
            _ => Ok(None),
        }
    }

    fn capture(&mut self, window: &FocusedWindow) -> anyhow::Result<CapturedImage> {
        let current = self.focused()?;
        let Some(current) = current.filter(|c| c.id == window.id) else {
            bail!("another window came to the front");
        };
        let rect = current
            .rect
            .context("the compositor did not say where the window is")?;
        let geometry = format!("{},{} {}x{}", rect.x, rect.y, rect.width, rect.height);
        let output = run_with_timeout(
            Command::new(&self.program).args(["-g", &geometry, "-t", "ppm", "-"]),
            GRIM_TIMEOUT,
        )?;
        parse_ppm(&output)
    }

    fn name(&self) -> &'static str {
        "grim"
    }
}

fn find_program(name: &str) -> Option<PathBuf> {
    std::env::var_os("PATH")?
        .to_str()?
        .split(':')
        .map(|dir| PathBuf::from(dir).join(name))
        .find(|path| path.is_file())
}

/// Runs a program and returns its standard output, killing it after `timeout`.
fn run_with_timeout(command: &mut Command, timeout: Duration) -> anyhow::Result<Vec<u8>> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("could not start the screenshot tool")?;
    let mut stdout = child.stdout.take().context("no output")?;
    let reader = std::thread::spawn(move || {
        let mut bytes = Vec::new();
        stdout.read_to_end(&mut bytes).map(|_| bytes)
    });
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let bytes = reader
                .join()
                .map_err(|_| anyhow::anyhow!("the screenshot reader failed"))??;
            if !status.success() {
                bail!("the screenshot tool failed ({status})");
            }
            return Ok(bytes);
        }
        if started.elapsed() > timeout {
            let _ = child.kill();
            let _ = child.wait();
            bail!("the screenshot tool did not finish");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A binary PPM (`P6`, 8-bit) to RGBA.
fn parse_ppm(bytes: &[u8]) -> anyhow::Result<CapturedImage> {
    let mut fields = Vec::with_capacity(4);
    let mut position = 0;
    while fields.len() < 4 {
        // Skip whitespace and comments between header fields.
        while position < bytes.len() {
            match bytes[position] {
                b'#' => {
                    while position < bytes.len() && bytes[position] != b'\n' {
                        position += 1;
                    }
                }
                byte if byte.is_ascii_whitespace() => position += 1,
                _ => break,
            }
        }
        let start = position;
        while position < bytes.len() && !bytes[position].is_ascii_whitespace() {
            position += 1;
        }
        if start == position {
            bail!("the screenshot is not a PPM image");
        }
        fields.push(std::str::from_utf8(&bytes[start..position])?.to_string());
    }
    position += 1; // the single whitespace byte before the pixels
    if fields[0] != "P6" || fields[3] != "255" {
        bail!("unsupported PPM image ({} {})", fields[0], fields[3]);
    }
    let width: u32 = fields[1].parse()?;
    let height: u32 = fields[2].parse()?;
    let expected = width as usize * height as usize * 3;
    let pixels = bytes
        .get(position..position + expected)
        .context("the screenshot is shorter than its header says")?;
    let rgba = pixels
        .as_chunks::<3>()
        .0
        .iter()
        .flat_map(|[r, g, b]| [*r, *g, *b, 255])
        .collect();
    Ok(CapturedImage {
        width,
        height,
        rgba,
    })
}

// ------------------------------------------------------------ compositor IPC

fn sway_focused() -> anyhow::Result<Option<FocusedWindow>> {
    const MAGIC: &[u8; 6] = b"i3-ipc";
    const GET_TREE: u32 = 4;
    let socket = std::env::var_os("SWAYSOCK").context("SWAYSOCK is not set")?;
    let mut stream = UnixStream::connect(&socket).context("could not reach Sway")?;
    stream.set_read_timeout(Some(IPC_TIMEOUT))?;
    stream.set_write_timeout(Some(IPC_TIMEOUT))?;
    let mut request = MAGIC.to_vec();
    request.extend_from_slice(&0u32.to_ne_bytes());
    request.extend_from_slice(&GET_TREE.to_ne_bytes());
    stream.write_all(&request)?;
    let mut header = [0u8; 14];
    stream.read_exact(&mut header)?;
    if &header[..6] != MAGIC {
        bail!("unexpected Sway reply");
    }
    let length = u32::from_ne_bytes([header[6], header[7], header[8], header[9]]) as usize;
    let mut payload = vec![0u8; length];
    stream.read_exact(&mut payload)?;
    let tree: Value = serde_json::from_slice(&payload)?;
    Ok(find_sway_focused(&tree))
}

fn find_sway_focused(node: &Value) -> Option<FocusedWindow> {
    if node.get("focused").and_then(Value::as_bool) == Some(true)
        && matches!(
            node.get("type").and_then(Value::as_str),
            Some("con" | "floating_con")
        )
    {
        let rect = |key: &str| -> Option<WindowRect> {
            let value = node.get(key)?;
            Some(WindowRect {
                x: value.get("x")?.as_i64()? as i32,
                y: value.get("y")?.as_i64()? as i32,
                width: value.get("width")?.as_u64()? as u32,
                height: value.get("height")?.as_u64()? as u32,
            })
        };
        // The content area: the container's position plus the window's
        // offset inside it, without the title bar.
        let outer = rect("rect")?;
        let content = rect("window_rect")
            .filter(|inner| !inner.is_empty())
            .map(|inner| WindowRect {
                x: outer.x + inner.x,
                y: outer.y + inner.y,
                ..inner
            })
            .unwrap_or(outer);
        return Some(FocusedWindow {
            id: node.get("id").and_then(Value::as_u64)?,
            pid: node
                .get("pid")
                .and_then(Value::as_u64)
                .and_then(|pid| u32::try_from(pid).ok()),
            title: node
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            rect: Some(content),
        });
    }
    ["nodes", "floating_nodes"]
        .iter()
        .filter_map(|key| node.get(*key).and_then(Value::as_array))
        .flatten()
        .find_map(find_sway_focused)
}

fn hyprland_focused() -> anyhow::Result<Option<FocusedWindow>> {
    let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
        .context("HYPRLAND_INSTANCE_SIGNATURE is not set")?;
    let mut candidates = Vec::new();
    if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") {
        candidates.push(
            PathBuf::from(runtime)
                .join("hypr")
                .join(&signature)
                .join(".socket.sock"),
        );
    }
    candidates.push(
        PathBuf::from("/tmp/hypr")
            .join(&signature)
            .join(".socket.sock"),
    );
    let socket = candidates
        .into_iter()
        .find(|path| path.exists())
        .context("Hyprland's IPC socket was not found")?;
    let mut stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(IPC_TIMEOUT))?;
    stream.set_write_timeout(Some(IPC_TIMEOUT))?;
    stream.write_all(b"j/activewindow")?;
    let mut reply = String::new();
    stream.read_to_string(&mut reply)?;
    Ok(parse_hyprland(&reply))
}

fn parse_hyprland(reply: &str) -> Option<FocusedWindow> {
    let value: Value = serde_json::from_str(reply).ok()?;
    let address = value.get("address").and_then(Value::as_str)?;
    let id = u64::from_str_radix(address.trim_start_matches("0x"), 16).ok()?;
    let pair = |key: &str| -> Option<(i64, i64)> {
        let array = value.get(key)?.as_array()?;
        Some((array.first()?.as_i64()?, array.get(1)?.as_i64()?))
    };
    let (x, y) = pair("at")?;
    let (width, height) = pair("size")?;
    Some(FocusedWindow {
        id,
        pid: value
            .get("pid")
            .and_then(Value::as_i64)
            .and_then(|pid| u32::try_from(pid).ok()),
        title: value
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        rect: Some(WindowRect {
            x: x as i32,
            y: y as i32,
            width: width.max(0) as u32,
            height: height.max(0) as u32,
        }),
    })
}

// ----------------------------------------------------------------- portal

/// The portal can target only the active window from version 3 on.
pub(super) struct Portal {
    desktop: Desktop,
    active_window: Option<bool>,
}

impl Portal {
    pub(super) fn new(desktop: Desktop) -> Self {
        Self {
            desktop,
            active_window: None,
        }
    }

    fn supports_active_window(&mut self) -> bool {
        *self.active_window.get_or_insert_with(|| {
            futures_lite::future::block_on(async {
                let proxy = ashpd::desktop::screenshot::ScreenshotProxy::new()
                    .await
                    .ok()?;
                let targets = proxy.available_targets().await.ok()?;
                Some(targets.contains(ashpd::desktop::screenshot::AvailableTargets::ActiveWindow))
            })
            .unwrap_or(false)
        })
    }
}

impl WindowCapture for Portal {
    fn limitation(&self) -> Option<String> {
        if self.active_window == Some(false) {
            return Some(format!(
                "{}'s screenshot portal cannot capture only the window in front, so LokalBot keeps text from accessibility only.",
                self.desktop.label()
            ));
        }
        None
    }

    /// The portal captures "the active window" without naming it; the
    /// engine checks that the same app and title stayed in front.
    fn focused(&mut self) -> anyhow::Result<Option<FocusedWindow>> {
        if !self.supports_active_window() {
            return Ok(None);
        }
        Ok(Some(FocusedWindow::default()))
    }

    fn capture(&mut self, _window: &FocusedWindow) -> anyhow::Result<CapturedImage> {
        if !self.supports_active_window() {
            bail!("the screenshot portal cannot capture only the window in front");
        }
        let uri = futures_lite::future::block_on(futures_lite::future::or(
            async {
                let request = ashpd::desktop::screenshot::Screenshot::request()
                    .interactive(false)
                    .modal(false)
                    .target(ashpd::desktop::screenshot::AvailableTargets::ActiveWindow)
                    .send()
                    .await
                    .context("the screenshot portal refused the request")?;
                let response = request.response().context("the screenshot was not taken")?;
                anyhow::Ok(response.uri().to_string())
            },
            async {
                async_io::Timer::after(PORTAL_TIMEOUT).await;
                Err(anyhow::anyhow!("the screenshot portal did not answer"))
            },
        ))?;
        let path = url::Url::parse(&uri)
            .ok()
            .filter(|url| url.scheme() == "file")
            .and_then(|url| url.to_file_path().ok())
            .context("the screenshot portal returned no file")?;
        let bytes = std::fs::read(&path);
        // The portal saved a copy (often in ~/Pictures); it must not outlive this read.
        if let Err(err) = std::fs::remove_file(&path) {
            log::warn!("could not delete the portal's screenshot file: {err}");
        }
        decode_png(&bytes.context("could not read the portal's screenshot")?)
    }

    fn name(&self) -> &'static str {
        "portal"
    }
}

fn decode_png(bytes: &[u8]) -> anyhow::Result<CapturedImage> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info()?;
    let mut buffer = vec![
        0u8;
        reader
            .output_buffer_size()
            .context("the image is too large")?
    ];
    let info = reader.next_frame(&mut buffer)?;
    let pixels = &buffer[..info.buffer_size()];
    let rgba: Vec<u8> = match info.color_type {
        png::ColorType::Rgba => pixels.to_vec(),
        png::ColorType::Rgb => pixels
            .as_chunks::<3>()
            .0
            .iter()
            .flat_map(|[r, g, b]| [*r, *g, *b, 255])
            .collect(),
        png::ColorType::GrayscaleAlpha => pixels
            .as_chunks::<2>()
            .0
            .iter()
            .flat_map(|[v, a]| [*v, *v, *v, *a])
            .collect(),
        png::ColorType::Grayscale => pixels.iter().flat_map(|&v| [v, v, v, 255]).collect(),
        png::ColorType::Indexed => bail!("unexpected indexed PNG"),
    };
    Ok(CapturedImage {
        width: info.width,
        height: info.height,
        rgba,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ppm_images_are_read() {
        let mut bytes = b"P6\n# grim\n2 1\n255\n".to_vec();
        bytes.extend_from_slice(&[255, 0, 0, 0, 0, 255]);
        let image = parse_ppm(&bytes).unwrap();
        assert_eq!((image.width, image.height), (2, 1));
        assert_eq!(image.rgba, [255, 0, 0, 255, 0, 0, 255, 255]);
        assert!(parse_ppm(b"P6\n2 1\n255\n\x00").is_err());
        assert!(parse_ppm(b"P5\n1 1\n255\n\x00").is_err());
    }

    #[test]
    fn sway_focus_uses_the_content_rectangle() {
        let tree: Value = serde_json::from_str(
            r#"{"type":"root","nodes":[{"type":"output","nodes":[{"type":"workspace","focused":false,
               "nodes":[{"type":"con","focused":false,"id":4,"name":"a","rect":{"x":0,"y":0,"width":10,"height":10}}],
               "floating_nodes":[{"type":"floating_con","focused":true,"id":7,"pid":42,"name":"Notes",
               "rect":{"x":100,"y":50,"width":640,"height":480},
               "window_rect":{"x":2,"y":26,"width":636,"height":452}}]}]}]}"#,
        )
        .unwrap();
        let focused = find_sway_focused(&tree).unwrap();
        assert_eq!(focused.id, 7);
        assert_eq!(focused.pid, Some(42));
        assert_eq!(focused.title, "Notes");
        assert_eq!(
            focused.rect,
            Some(WindowRect {
                x: 102,
                y: 76,
                width: 636,
                height: 452
            })
        );
    }

    #[test]
    fn hyprland_active_window_is_parsed() {
        let focused = parse_hyprland(
            r#"{"address":"0x55d1a2b3c4d0","at":[12,40],"size":[800,600],"pid":99,"title":"Docs"}"#,
        )
        .unwrap();
        assert_eq!(focused.id, 0x55d1a2b3c4d0);
        assert_eq!(focused.rect.unwrap().width, 800);
        assert!(parse_hyprland("{}").is_none());
    }
}
