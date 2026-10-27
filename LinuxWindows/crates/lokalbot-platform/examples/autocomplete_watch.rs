//! Prints what autocomplete's field watcher reads, and with `--tab <text>`
//! takes Tab while running and types `<text>` into the focused field, as
//! accepting a suggestion does. For checking the desktop integration by hand:
//!
//! ```text
//! cargo run -p lokalbot-platform --example autocomplete_watch -- --seconds 20 --tab " up"
//! ```

use std::time::{Duration, Instant};

use lokalbot_platform::autocomplete::{
    Edit, FieldWatcher, FocusSnapshot, InterceptedKey, KeyInterceptor, ReadPolicy, insert,
};
use parking_lot::Mutex;

fn main() -> anyhow::Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let args: Vec<String> = std::env::args().collect();
    let value = |flag: &str| {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1).cloned())
    };
    let seconds: u64 = value("--seconds")
        .and_then(|s| s.parse().ok())
        .unwrap_or(15);
    let tab_text = value("--tab");

    let latest: &'static Mutex<Option<FocusSnapshot>> = Box::leak(Box::new(Mutex::new(None)));
    let policy = ReadPolicy {
        enabled: true,
        visible_text: true,
        ..Default::default()
    };
    let watcher = FieldWatcher::start(policy, move |focus| {
        match &focus.field {
            Some(field) => println!(
                "FIELD app={:?} id={:?} title={:?} before={:?} after={:?} caret=({:.0},{:.0},{:.0}x{:.0}) exact={} frame={:?} single_line={} url={:?} visible={:?} style={:?}",
                field.app_name,
                field.app_id,
                field.window_title,
                field.before,
                field.after,
                field.caret.x,
                field.caret.y,
                field.caret.width,
                field.caret.height,
                field.caret_exact,
                field.field_frame,
                field.single_line,
                field.url,
                field.visible_text,
                field.style,
            ),
            None => println!(
                "FOCUS app={:?} id={:?} capability={:?}",
                focus.app_name, focus.app_id, focus.capability
            ),
        }
        *latest.lock() = Some(focus);
    })?;

    let keys = match &tab_text {
        Some(text) => {
            let text = text.clone();
            let interceptor: &'static Mutex<Option<KeyInterceptor>> =
                Box::leak(Box::new(Mutex::new(None)));
            let handler = move |key: InterceptedKey| {
                println!("KEY {key:?}");
                if key != InterceptedKey::Tab {
                    return;
                }
                let Some(field) = latest.lock().as_ref().and_then(|f| f.field.clone()) else {
                    if let Some(keys) = interceptor.lock().as_ref() {
                        keys.pass_through(key);
                    }
                    return;
                };
                let text = text.clone();
                std::thread::spawn(move || {
                    let edit = Edit {
                        text,
                        ..Default::default()
                    };
                    match insert(&field, &edit) {
                        Ok(()) => println!("INSERTED"),
                        Err(err) => println!("INSERT FAILED {err:#}"),
                    }
                });
            };
            let keys = KeyInterceptor::start(handler)?;
            keys.set_active(true);
            println!("GRABBED Tab and Escape");
            *interceptor.lock() = Some(keys);
            Some(interceptor)
        }
        None => None,
    };

    let deadline = Instant::now() + Duration::from_secs(seconds);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    if let Some(keys) = keys
        && let Some(keys) = keys.lock().take()
    {
        keys.set_active(false);
    }
    drop(watcher);
    Ok(())
}
