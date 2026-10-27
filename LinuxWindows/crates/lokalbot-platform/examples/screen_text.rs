//! Prints what screen context sees in the window in front: its title,
//! process, rectangle and the accessibility snapshot, and optionally saves
//! its pixels as a PPM image.
//!
//! ```text
//! cargo run -p lokalbot-platform --example screen_text -- [--delay <seconds>] [--save <file.ppm>]
//! ```
//!
//! Switch to the window to inspect during the delay (3 s by default).

use std::time::Duration;

use lokalbot_platform::screen;

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let mut delay = 3.0f64;
    let mut save: Option<String> = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--delay" => delay = args.next().and_then(|v| v.parse().ok()).unwrap_or(delay),
            "--save" => save = args.next(),
            other => anyhow::bail!("unknown argument {other}"),
        }
    }
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
    println!("window: {window:?}");
    let mut reader = screen::text_reader();
    let started = std::time::Instant::now();
    let read = reader.read(&window, true, Duration::from_millis(400));
    println!("{} read in {:?}:", reader.name(), started.elapsed());
    match read {
        screen::TextRead::Read(snapshot) => {
            println!("  title: {:?}", snapshot.window_title);
            println!("  url: {:?}", snapshot.source_url);
            println!("  document: {:?}", snapshot.document_name);
            println!(
                "  focused secure field: {:?}, secure field visible: {}",
                snapshot.focused_secure_field, snapshot.contains_secure_field
            );
            println!(
                "  web content: {}, framed: {:?}, unattributed: {}",
                snapshot.has_web_content,
                snapshot.framed_urls,
                snapshot.has_unattributed_web_content
            );
            println!("  text ({} chars):", snapshot.text.chars().count());
            for line in snapshot.text.lines().take(60) {
                println!("    {line}");
            }
        }
        other => println!("  {other:?}"),
    }
    if let Some(path) = save {
        let image = capture.capture(&window)?;
        let mut ppm = format!("P6\n{} {}\n255\n", image.width, image.height).into_bytes();
        ppm.extend(
            image
                .rgba
                .as_chunks::<4>()
                .0
                .iter()
                .flat_map(|[r, g, b, _]| [*r, *g, *b]),
        );
        std::fs::write(&path, ppm)?;
        println!("saved {}×{} pixels to {path}", image.width, image.height);
    }
    Ok(())
}
