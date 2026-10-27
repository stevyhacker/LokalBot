//! Captures the window in front the way screen context does, reads its text
//! through accessibility and OCR, and saves the pixels for inspection.
//!
//! ```text
//! cargo run -p lokalbot-engine --example screen_capture -- \
//!     [--library <dir>] [--download-ocr] [--notepad "text to show"] [--delay <seconds>] [--save <file.jpg>]
//! ```
//!
//! - `--library`: where the OCR models are kept (`<dir>/models/ocrs`); default
//!   `lokalbot-screen-check` in the temporary folder.
//! - `--download-ocr`: download the pinned OCR models first (about 12 MB).
//! - `--notepad`: Windows only; opens Notepad with this text, brings it to
//!   the front and captures it.
//! - `--delay`: seconds to wait before capturing (default 3), time to bring
//!   another window to the front.
//! - `--save`: where the captured pixels go (default `<library>/screen-capture.jpg`).
//!
//! Nothing is written to a LokalBot library's database.

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, bail};
use lokalbot_core::LibraryPaths;
use lokalbot_platform::screen::{self, TextRead};

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let mut library = std::env::temp_dir().join("lokalbot-screen-check");
    let mut download = false;
    let mut notepad: Option<String> = None;
    let mut delay = 3.0f64;
    let mut save: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--library" => library = args.next().context("--library needs a folder")?.into(),
            "--download-ocr" => download = true,
            "--notepad" => notepad = Some(args.next().context("--notepad needs text")?),
            "--delay" => delay = args.next().and_then(|v| v.parse().ok()).unwrap_or(delay),
            "--save" => save = Some(args.next().context("--save needs a file")?.into()),
            other => bail!("unknown argument {other}"),
        }
    }
    let paths = LibraryPaths::new(&library);
    std::fs::create_dir_all(paths.root())?;
    if download {
        let started = Instant::now();
        lokalbot_ai::ocr::download(&paths, &AtomicBool::new(false), &mut |_, _| {})?;
        println!(
            "OCR models ready ({} bytes) in {:.1}s",
            lokalbot_ai::ocr::total_size(),
            started.elapsed().as_secs_f64()
        );
    }
    let _notepad = match notepad {
        Some(text) => Some(open_notepad(&paths, &text)?),
        None => None,
    };
    std::thread::sleep(Duration::from_secs_f64(delay));

    let mut capture = screen::window_capture();
    println!("capture backend: {}", capture.name());
    if let Some(limitation) = capture.limitation() {
        println!("limitation: {limitation}");
    }
    let Some(window) = capture.focused()? else {
        println!("no window is in front");
        return Ok(());
    };
    println!(
        "window: {:?} (pid {:?}) at {:?}",
        window.title, window.pid, window.rect
    );

    let mut reader = screen::text_reader();
    let started = Instant::now();
    match reader.read(&window, true, Duration::from_millis(400)) {
        TextRead::Read(snapshot) => {
            println!(
                "{} text in {:.0} ms ({} chars, focused secure field {:?}, secure field visible {}):",
                reader.name(),
                started.elapsed().as_secs_f64() * 1000.0,
                snapshot.text.chars().count(),
                snapshot.focused_secure_field,
                snapshot.contains_secure_field
            );
            for line in snapshot.text.lines().take(40) {
                println!("  | {line}");
            }
        }
        other => println!("{} text: {other:?}", reader.name()),
    }

    let started = Instant::now();
    let image = capture.capture(&window)?;
    println!(
        "captured {}×{} pixels in {:.0} ms",
        image.width,
        image.height,
        started.elapsed().as_secs_f64() * 1000.0
    );
    let frame = image.bounded(1_500);
    let path = save.unwrap_or_else(|| paths.root().join("screen-capture.jpg"));
    let rgb: Vec<u8> = image
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|[r, g, b, _]| [*r, *g, *b])
        .collect();
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 90).encode(
        &rgb,
        image.width,
        image.height,
        image::ExtendedColorType::Rgb8,
    )?;
    std::fs::write(&path, jpeg).with_context(|| format!("writing {}", path.display()))?;
    println!("saved the pixels to {}", path.display());

    if lokalbot_ai::ocr::is_installed(&paths) {
        let started = Instant::now();
        let engine = lokalbot_ai::ocr::OcrEngine::load(&paths)?;
        let text = engine.recognize(&frame.rgba, frame.width, frame.height)?;
        println!(
            "OCR on {}×{} in {:.1}s:",
            frame.width,
            frame.height,
            started.elapsed().as_secs_f64()
        );
        for line in text.lines() {
            println!("  > {line}");
        }
    } else {
        println!("OCR models are not downloaded (pass --download-ocr)");
    }
    Ok(())
}

/// Notepad showing `text`, closed when dropped.
struct Notepad(std::process::Child);

impl Drop for Notepad {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn open_notepad(paths: &LibraryPaths, text: &str) -> Result<Notepad> {
    if !cfg!(windows) {
        bail!("--notepad is for Windows");
    }
    let file = paths.root().join("screen-check.txt");
    std::fs::write(&file, text)?;
    let child = std::process::Command::new("notepad.exe")
        .arg(&file)
        .spawn()
        .context("starting Notepad")?;
    // A process started from a background session may not get the
    // foreground; ask the shell to activate the window by its title.
    std::thread::sleep(Duration::from_secs(2));
    let activated = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-Command",
            "(New-Object -ComObject WScript.Shell).AppActivate('screen-check')",
        ])
        .output();
    if let Ok(output) = activated {
        println!(
            "activating Notepad: {}",
            String::from_utf8_lossy(&output.stdout).trim()
        );
    }
    Ok(Notepad(child))
}
