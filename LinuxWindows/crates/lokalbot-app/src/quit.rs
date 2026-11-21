use std::time::Duration;

use gpui_kit::{App, AppContext as _, Global};

use crate::bridge::EngineHandle;

const FORCED_QUIT_WAIT: Duration = Duration::from_secs(10);

#[derive(Default)]
struct Preparing(bool);

impl Global for Preparing {}

pub fn request(cx: &mut App) {
    prepare(cx, |cx| cx.quit());
}

fn prepare(cx: &mut App, then: impl FnOnce(&mut App) + 'static) {
    let Some(engine) = cx.try_global::<EngineHandle>().map(|e| e.0.clone()) else {
        then(cx);
        return;
    };
    if cx.try_global::<Preparing>().is_some_and(|p| p.0) {
        return;
    }
    cx.set_global(Preparing(true));
    cx.spawn(async move |cx| {
        let saved = cx
            .background_spawn(async move { engine.prepare_for_quit() })
            .await;
        cx.update(|cx| {
            cx.set_global(Preparing(false));
            if saved {
                then(cx);
            } else {
                log::warn!("not quitting: a recording could not be saved");
                crate::desktop::show_main_window(cx);
            }
        });
    })
    .detach();
}

pub fn finish_recording_on_exit(cx: &mut App) {
    cx.on_app_quit(|cx| {
        if let Some(engine) = cx.try_global::<EngineHandle>()
            && !engine.0.prepare_for_quit_within(FORCED_QUIT_WAIT)
        {
            log::error!("quitting with a recording that could not be saved");
        }
        async {}
    })
    .detach();
}

#[cfg(test)]
mod tests {
    #[test]
    fn closing_the_last_window_does_not_quit_by_itself() {
        let main = include_str!("main.rs");
        assert!(main.contains("cx.set_quit_mode(gpui_kit::QuitMode::Explicit);"));
    }

    #[test]
    fn nothing_quits_without_saving_a_recording() {
        fn sources(folder: &std::path::Path, found: &mut Vec<std::path::PathBuf>) {
            for entry in std::fs::read_dir(folder).unwrap().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    sources(&path, found);
                } else if path.extension().is_some_and(|e| e == "rs") {
                    found.push(path);
                }
            }
        }
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        sources(&src, &mut files);
        assert!(files.len() > 20);
        let call = ["cx", ".quit()"].concat();
        for file in files {
            let name = file
                .strip_prefix(&src)
                .unwrap()
                .to_string_lossy()
                .to_string();
            let count = std::fs::read_to_string(&file)
                .unwrap()
                .lines()
                .filter(|line| !line.trim_start().starts_with("//"))
                .filter(|line| line.contains(&call))
                .count();
            let allowed = match name.replace('\\', "/").as_str() {
                "quit.rs" => 1,
                "updates.rs" => 2,
                _ => 0,
            };
            assert_eq!(count, allowed, "{name} calls {call}");
        }
    }
}
