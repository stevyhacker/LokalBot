//! Records a meeting into a folder and prints the health strip twice a second.
//!
//! `cargo run -p lokalbot-audio --example record -- <dir> <seconds> [--mic <id>] [--no-system] [--devices]`

use std::path::PathBuf;
use std::time::{Duration, Instant};

use lokalbot_audio::{Recorder, RecorderOptions, input_devices};

fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let mut dir = None;
    let mut seconds = 5.0f64;
    let mut options = RecorderOptions {
        mic_device: None,
        capture_system: true,
    };
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--mic" => options.mic_device = args.next(),
            "--no-system" => options.capture_system = false,
            "--devices" => {
                for device in input_devices() {
                    println!(
                        "{}{}\t{}",
                        if device.is_default { "* " } else { "  " },
                        device.id,
                        device.name
                    );
                }
                return Ok(());
            }
            other if dir.is_none() => dir = Some(PathBuf::from(other)),
            other => seconds = other.parse()?,
        }
    }
    let dir = dir.ok_or_else(|| anyhow::anyhow!("usage: record <dir> <seconds>"))?;
    let recorder = Recorder::start(&dir, options)?;
    println!("system attached: {}", recorder.has_system_audio());
    let started = Instant::now();
    while started.elapsed().as_secs_f64() < seconds {
        std::thread::sleep(Duration::from_millis(500));
        let levels = recorder.levels();
        let status = recorder.status();
        println!(
            "{:5.1}s  Mic · {:<18} {:.2}   System · {:<18} {:.2}",
            recorder.elapsed().as_secs_f64(),
            status.mic.to_string(),
            levels.mic,
            status.system.to_string(),
            levels.system
        );
    }
    let result = recorder.stop()?;
    println!("{result:#?}");
    Ok(())
}
