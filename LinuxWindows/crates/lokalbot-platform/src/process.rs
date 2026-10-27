//! Small helpers for running desktop tools (`pactl`, `wtype`, `ydotool`,
//! `gdbus`) without ever hanging the caller.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

/// Finds an executable on `PATH`.
pub(crate) fn find_program(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

/// Runs `command` with no stdin, collecting stdout and stderr, and kills it
/// after `timeout`.
pub(crate) fn output_with_timeout(
    mut command: Command,
    timeout: Duration,
) -> std::io::Result<Output> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    // Read both pipes on their own threads so a chatty tool cannot block
    // on a full pipe while we wait for it.
    let mut stdout = child.stdout.take();
    let mut stderr = child.stderr.take();
    let out = std::thread::spawn(move || {
        let mut buffer = Vec::new();
        if let Some(pipe) = stdout.as_mut() {
            let _ = pipe.read_to_end(&mut buffer);
        }
        buffer
    });
    let err = std::thread::spawn(move || {
        let mut buffer = Vec::new();
        if let Some(pipe) = stderr.as_mut() {
            let _ = pipe.read_to_end(&mut buffer);
        }
        buffer
    });
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                format!("{:?} did not finish in time", command.get_program()),
            ));
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    Ok(Output {
        status,
        stdout: out.join().unwrap_or_default(),
        stderr: err.join().unwrap_or_default(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_and_timeouts() {
        let mut echo = Command::new("sh");
        echo.args(["-c", "echo hello; echo oops >&2"]);
        let output = output_with_timeout(echo, Duration::from_secs(5)).unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello\n");
        assert_eq!(output.stderr, b"oops\n");
        let mut sleep = Command::new("sleep");
        sleep.arg("5");
        let started = Instant::now();
        let err = output_with_timeout(sleep, Duration::from_millis(200)).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(find_program("sh").is_some());
        assert!(find_program("surely-not-a-program-name").is_none());
    }
}
