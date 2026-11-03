//! Prints what autocomplete's field watcher reads, and with `--tab <text>`
//! takes Tab while running and types `<text>` into the focused field, as
//! accepting a suggestion does. For checking the desktop integration by hand:
//!
//! ```text
//! cargo run -p lokalbot-platform --example autocomplete_watch -- --seconds 20 --tab " up"
//! ```
//!
//! On a Wayland input method, `--ghost <text>` shows `<text>` in the field
//! whenever one has focus: Tab takes its first word, the key left of 1 the rest,
//! and Esc drops it. With `--pass-tab`, Tab goes on to the field instead.

use std::time::{Duration, Instant};

use lokalbot_platform::autocomplete::{
    Edit, FieldSnapshot, FieldWatcher, FocusSnapshot, InlineGhost, InterceptedKey, KeyInterceptor,
    ReadPolicy, insert,
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
    if let Some(ghost) = value("--ghost") {
        return run_ghost(seconds, ghost, args.iter().any(|a| a == "--pass-tab"));
    }

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

/// What `--ghost` has on show.
struct Shown {
    field: FieldSnapshot,
    rest: String,
}

fn run_ghost(seconds: u64, text: String, pass_tab: bool) -> anyhow::Result<()> {
    let shown: &'static Mutex<Option<Shown>> = Box::leak(Box::new(Mutex::new(None)));
    let inline: &'static Mutex<Option<InlineGhost>> = Box::leak(Box::new(Mutex::new(None)));
    let keys: &'static Mutex<Option<KeyInterceptor>> = Box::leak(Box::new(Mutex::new(None)));
    let policy = ReadPolicy {
        enabled: true,
        visible_text: true,
        ..Default::default()
    };
    let suggestion = text.clone();
    let watcher = FieldWatcher::start(policy, move |focus| {
        let Some(field) = focus.field.clone() else {
            println!(
                "FOCUS app={:?} id={:?} capability={:?}",
                focus.app_name, focus.app_id, focus.capability
            );
            *shown.lock() = None;
            if let Some(keys) = keys.lock().as_ref() {
                keys.set_active(false);
            }
            return;
        };
        println!(
            "FIELD app={:?} id={:?} title={:?} before={:?} after={:?} single_line={} visible={:?} url={:?}",
            field.app_name,
            field.app_id,
            field.window_title,
            field.before,
            field.after,
            field.single_line,
            field.visible_text,
            field.url,
        );
        let mut current = shown.lock();
        if let Some(shown) = current.as_mut() {
            shown.field = field;
            return;
        }
        if let (Some(inline), Some(keys)) = (inline.lock().as_ref(), keys.lock().as_ref()) {
            inline.show(&field, &suggestion);
            keys.set_active(true);
            println!("GHOST shown");
        }
        *current = Some(Shown {
            field,
            rest: suggestion.clone(),
        });
    })?;
    *inline.lock() = watcher.inline_ghost();
    let handler = move |key: InterceptedKey| {
        println!("KEY {key:?}");
        let mut current = shown.lock();
        let inline = inline.lock();
        let keys = keys.lock();
        let (Some(state), Some(inline), Some(keys)) =
            (current.as_mut(), inline.as_ref(), keys.as_ref())
        else {
            return;
        };
        match key {
            InterceptedKey::Escape => {
                inline.show(&state.field, "");
                keys.set_active(false);
                state.rest.clear();
                println!("GHOST dropped");
            }
            InterceptedKey::Tab | InterceptedKey::Backtick
                if !state.rest.is_empty() && !(pass_tab && key == InterceptedKey::Tab) =>
            {
                let whole = key == InterceptedKey::Backtick;
                let cut = if whole {
                    state.rest.len()
                } else {
                    let word = state.rest.trim_start();
                    let start = state.rest.len() - word.len();
                    start + word.find(' ').unwrap_or(word.len())
                };
                let (taken, rest) = state.rest.split_at(cut);
                let edit = Edit {
                    text: taken.to_string(),
                    ..Default::default()
                };
                inline.accept(
                    &state.field,
                    &state.field.before,
                    &state.field.after,
                    &edit,
                    rest,
                );
                state.rest = rest.to_string();
                if state.rest.is_empty() {
                    keys.set_active(false);
                }
                println!("ACCEPTED {:?}", edit.text);
            }
            other => {
                keys.pass_through(other);
                println!("PASSED {other:?}");
            }
        }
    };
    *keys.lock() = Some(KeyInterceptor::start(handler)?);
    println!("READY limitation={:?}", watcher.limitation());
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut said = None;
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
        let limitation = watcher.limitation();
        if limitation != said {
            println!("LIMITATION {limitation:?}");
            said = limitation;
        }
    }
    *keys.lock() = None;
    drop(watcher);
    Ok(())
}
