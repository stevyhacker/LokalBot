//! Wayland checks inside a headless Sway session, ignored by default. Run
//! them with `crates/lokalbot-platform/scripts/live-sway.sh`.

#![cfg(target_os = "linux")]

use std::process::Command;
use std::time::{Duration, Instant};

use lokalbot_platform::{
    GlobalShortcuts, InsertMethod, InsertOutcome, ShortcutError, activity_source, insert_text,
};

#[test]
#[ignore]
fn sway_sampler_idle_typing_and_paste() {
    let out = std::env::temp_dir().join(format!("lokalbot-wayland-{}", std::process::id()));
    let _ = std::fs::remove_file(&out);
    let script = format!("cat > '{}'", out.display());
    let mut foot = Command::new("foot")
        .args([
            "--title",
            "LokalBot wayland",
            "--app-id",
            "foot",
            "sh",
            "-c",
            &script,
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();

    let mut source = activity_source();
    assert_eq!(source.backend_name(), "sway", "{:?}", source.limitation());
    let deadline = Instant::now() + Duration::from_secs(10);
    let sample = loop {
        if let Some(sample) = source.sample().unwrap()
            && sample.title == "LokalBot wayland"
        {
            break sample;
        }
        assert!(Instant::now() < deadline, "foot never got the focus");
        std::thread::sleep(Duration::from_millis(200));
    };
    println!("sample: {sample:?}");
    // Named from foot's desktop entry (org.codeberg.dnkl.foot.desktop).
    assert!(sample.app_id.contains("foot"), "{}", sample.app_id);
    assert_eq!(sample.app, "Foot");

    // ext-idle-notify: quiet time counts up…
    std::thread::sleep(Duration::from_millis(2500));
    let quiet = source.idle_seconds().expect("idle time on Sway");
    println!("idle after 2.5 s: {quiet:.2}");
    assert!(quiet >= 1.0, "{quiet}");

    // …and typing (wtype's virtual keyboard) resets it.
    let typed = insert_text("typed on wayland ✓\n", InsertMethod::Type).unwrap();
    assert_eq!(typed, InsertOutcome::Inserted);
    std::thread::sleep(Duration::from_millis(300));
    let active = source.idle_seconds().unwrap();
    println!("idle after typing: {active:.2}");
    assert!(active < quiet, "{active} vs {quiet}");

    // foot is a terminal: Shift+Insert with the primary selection set.
    let pasted = insert_text("pasted on wayland", InsertMethod::Paste).unwrap();
    assert_eq!(pasted, InsertOutcome::Inserted);
    std::thread::sleep(Duration::from_millis(500));
    let status = Command::new("wtype")
        .args([
            "-s", "50", "-k", "Return", "-s", "50", "-M", "ctrl", "d", "-m", "ctrl",
        ])
        .status()
        .unwrap();
    assert!(status.success());
    let deadline = Instant::now() + Duration::from_secs(10);
    while foot.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "foot did not exit");
        std::thread::sleep(Duration::from_millis(100));
    }
    let written = std::fs::read_to_string(&out).unwrap();
    let _ = std::fs::remove_file(&out);
    println!("terminal received: {written:?}");
    assert_eq!(written, "typed on wayland ✓\npasted on wayland\n");
}

#[test]
#[ignore]
fn sway_has_no_shortcuts_portal() {
    let started = Instant::now();
    let result = GlobalShortcuts::new(|_| {});
    println!("shortcuts on sway: {:?}", result.as_ref().err());
    match result {
        Err(ShortcutError::Unsupported(message)) => {
            assert!(message.contains("lokalbot dictate --toggle"), "{message}");
        }
        Ok(shortcuts) => println!("a shortcuts portal answered: {}", shortcuts.backend_name()),
        Err(other) => panic!("{other}"),
    }
    assert!(started.elapsed() < Duration::from_secs(8));
}
