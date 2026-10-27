//! Checks against a real desktop session, ignored by default. Run them with a
//! display, for example `scripts/live-x11.sh` style: Xvfb, a window manager
//! and a titled window, then
//! `LOKALBOT_EXPECT_TITLE=… cargo test -p lokalbot-platform --test live_desktop -- --ignored`.

#![cfg(target_os = "linux")]

use std::process::Command;
use std::time::Duration;

use lokalbot_platform::{
    GlobalShortcuts, SampleDisposition, Shortcut, ShortcutError, activity_source, disposition,
};

#[test]
#[ignore]
fn x11_sampler_reads_the_active_window_and_idle_time() {
    let expected = std::env::var("LOKALBOT_EXPECT_TITLE").expect("LOKALBOT_EXPECT_TITLE");
    let mut source = activity_source();
    assert_eq!(source.backend_name(), "x11", "{:?}", source.limitation());
    assert_eq!(source.limitation(), None);
    let sample = source.sample().unwrap().expect("a focused window");
    println!("sample: {sample:?}");
    assert_eq!(sample.title, expected);
    assert!(!sample.app.is_empty() && !sample.app_id.is_empty());

    let stored = disposition(&sample, &lokalbot_core::Settings::default());
    println!("stored: {stored:?}");
    let SampleDisposition::Keep(kept) = stored else {
        panic!("an ordinary window is kept");
    };
    assert!(!kept.title.contains("abcdef123456"), "secrets are redacted");

    // Input resets the idle clock; quiet time grows it.
    Command::new("xdotool")
        .args(["mousemove", "10", "10"])
        .status()
        .unwrap();
    std::thread::sleep(Duration::from_millis(200));
    let fresh = source.idle_seconds().expect("idle time");
    std::thread::sleep(Duration::from_secs(2));
    let later = source.idle_seconds().expect("idle time");
    println!("idle: {fresh:.2}s then {later:.2}s");
    assert!(fresh < 1.5, "{fresh}");
    assert!(later >= fresh + 1.5, "{fresh} → {later}");
}

#[test]
#[ignore]
fn x11_shortcuts_report_press_and_release() {
    let (tx, rx) = crossbeam_channel::unbounded();
    let mut shortcuts = GlobalShortcuts::new(move |event| {
        let _ = tx.send(event);
    })
    .unwrap();
    assert_eq!(shortcuts.backend_name(), "x11");
    let chord = Shortcut::parse("Ctrl+Alt+K").unwrap();
    shortcuts.register("dictation", &chord).unwrap();
    assert!(matches!(
        shortcuts.register("ask", &chord),
        Err(ShortcutError::InUse)
    ));

    Command::new("xdotool")
        .args(["keydown", "ctrl+alt+k"])
        .status()
        .unwrap();
    let down = rx.recv_timeout(Duration::from_secs(3)).expect("press");
    std::thread::sleep(Duration::from_millis(300));
    Command::new("xdotool")
        .args(["keyup", "ctrl+alt+k"])
        .status()
        .unwrap();
    let up = rx.recv_timeout(Duration::from_secs(3)).expect("release");
    println!("events: {down:?} {up:?}");
    assert_eq!((down.id.as_str(), down.pressed), ("dictation", true));
    assert_eq!((up.id.as_str(), up.pressed), ("dictation", false));

    shortcuts.unregister("dictation").unwrap();
    Command::new("xdotool")
        .args(["key", "ctrl+alt+k"])
        .status()
        .unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(700)).is_err());
}

fn xdotool(args: &[&str]) -> String {
    let output = Command::new("xdotool").args(args).output().unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// Waits for a window titled `title` and gives it the focus.
fn focus_window(title: &str) {
    let window = xdotool(&["search", "--sync", "--name", title]);
    let window = window
        .lines()
        .next()
        .expect("the window appeared")
        .to_string();
    xdotool(&["windowactivate", "--sync", &window]);
    std::thread::sleep(Duration::from_millis(400));
}

fn wait_with_timeout(child: &mut std::process::Child, timeout: Duration) {
    let deadline = std::time::Instant::now() + timeout;
    while child.try_wait().unwrap().is_none() {
        if std::time::Instant::now() > deadline {
            let _ = child.kill();
            panic!("the target app did not exit");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Opens a GTK text entry, runs `insert`, confirms the entry and returns
/// what it contained.
fn into_gtk_entry(insert: impl FnOnce() -> lokalbot_platform::InsertOutcome) -> String {
    let mut zenity = Command::new("zenity")
        .args([
            "--entry",
            "--title",
            "LokalBot target",
            "--text",
            "Dictation target",
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    focus_window("LokalBot target");
    assert_eq!(insert(), lokalbot_platform::InsertOutcome::Inserted);
    std::thread::sleep(Duration::from_millis(500));
    xdotool(&["key", "Return"]);
    wait_with_timeout(&mut zenity, Duration::from_secs(10));
    let mut out = String::new();
    std::io::Read::read_to_string(&mut zenity.stdout.take().unwrap(), &mut out).unwrap();
    out.trim_end_matches('\n').to_string()
}

fn clipboard_via_xsel() -> String {
    let output = Command::new("xsel")
        .args(["--clipboard", "--output"])
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).into_owned()
}

#[test]
#[ignore]
fn x11_paste_and_type_into_a_gtk_entry() {
    use lokalbot_platform::{InsertMethod, copy_to_clipboard, insert_text};

    copy_to_clipboard("previous clipboard").unwrap();
    assert_eq!(clipboard_via_xsel(), "previous clipboard");

    let dictated = "Dictated — with ünïcödé ✓ and 42";
    let pasted = into_gtk_entry(|| insert_text(dictated, InsertMethod::Paste).unwrap());
    println!("pasted: {pasted:?}");
    assert_eq!(pasted, dictated);
    // The clipboard is put back once the app has read it.
    assert_eq!(clipboard_via_xsel(), "previous clipboard");

    let typed = "Typed ünï — 7";
    let echoed = into_gtk_entry(|| insert_text(typed, InsertMethod::Type).unwrap());
    println!("typed: {echoed:?}");
    assert_eq!(echoed, typed);
}

#[test]
#[ignore]
fn x11_terminals_get_shift_insert() {
    use lokalbot_platform::{InsertMethod, InsertOutcome, insert_text};

    let out = std::env::temp_dir().join(format!("lokalbot-terminal-{}", std::process::id()));
    let _ = std::fs::remove_file(&out);
    let script = format!("cat > '{}'", out.display());
    let mut terminal = Command::new("xfce4-terminal")
        .args([
            "--disable-server",
            "--title",
            "LokalBot terminal",
            "-x",
            "sh",
            "-c",
            &script,
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    focus_window("LokalBot terminal");
    let outcome = insert_text("pasted into a terminal", InsertMethod::Paste).unwrap();
    assert_eq!(outcome, InsertOutcome::Inserted);
    std::thread::sleep(Duration::from_millis(500));
    xdotool(&["key", "Return", "ctrl+d"]);
    wait_with_timeout(&mut terminal, Duration::from_secs(10));
    let written = std::fs::read_to_string(&out).unwrap();
    let _ = std::fs::remove_file(&out);
    println!("terminal received: {written:?}");
    assert_eq!(written.trim_end(), "pasted into a terminal");
}
