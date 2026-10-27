//! `lokalbot --version` against the real binary.

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[test]
fn version_exits_before_opening_the_library() {
    let root = std::env::temp_dir().join(format!("lokalbot-version-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    for flag in ["--version", "-V"] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_lokalbot"))
            .arg(flag)
            .env("LOKALBOT_STORAGE_ROOT", &root)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        // If the flag were ignored the app would start; don't wait for it.
        let deadline = Instant::now() + Duration::from_secs(30);
        while child.try_wait().unwrap().is_none() {
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = std::fs::remove_dir_all(&root);
                panic!("lokalbot {flag} did not exit");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            format!("LokalBot {}\n", env!("CARGO_PKG_VERSION"))
        );
    }
    assert!(!root.exists(), "--version must not create the library");
}
