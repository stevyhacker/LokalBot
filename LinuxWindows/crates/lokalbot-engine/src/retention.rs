//! Applies the retention window from Privacy settings: at startup, then every
//! six hours (`ScreenshotService.performRetentionPrune`). Window titles older
//! than the window are cleared; meetings are never touched.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::{EngineEvent, Shared};

const FIRST_PASS_DELAY: Duration = Duration::from_secs(30);
const INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);

pub fn start(shared: Arc<Shared>) {
    let spawned = std::thread::Builder::new()
        .name("lokalbot-retention".into())
        .spawn(move || {
            let mut next = Instant::now() + FIRST_PASS_DELAY;
            while !shared.is_shutting_down() {
                std::thread::sleep(Duration::from_secs(1));
                if Instant::now() < next {
                    continue;
                }
                next = Instant::now() + INTERVAL;
                let settings = shared.settings();
                match shared
                    .library
                    .apply_retention(&settings, chrono::Utc::now())
                {
                    Ok(report) => {
                        log::info!("retention pass: {report:?}");
                        if report != Default::default() {
                            shared.emit(EngineEvent::LibraryChanged);
                        }
                    }
                    Err(err) => log::warn!("retention pass failed: {err:#}"),
                }
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start retention: {err}");
    }
}
