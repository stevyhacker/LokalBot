//! Bounded child processes: helpers cannot stall the capture loop indefinitely.
use anyhow::{Context, Result, ensure};
use std::{
    io::Read,
    process::{Command, Output, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

pub fn bounded_output(command: &mut Command, timeout: Duration, limit: usize) -> Result<Output> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("Could not start helper executable")?;
    let stdout = child.stdout.take().context("Missing helper stdout")?;
    let stderr = child.stderr.take().context("Missing helper stderr")?;
    let reader = |stream: Box<dyn Read + Send>| {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = stream
                .take(limit as u64 + 1)
                .read_to_end(&mut bytes)
                .map(|_| bytes);
            let _ = tx.send(result);
        });
        rx
    };
    let out = reader(Box::new(stdout));
    let err = reader(Box::new(stderr));
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if start.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            anyhow::bail!("Helper exceeded its time limit");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let stdout = out
        .recv_timeout(Duration::from_millis(200))
        .context("Helper output pipe stayed open")??;
    let stderr = err
        .recv_timeout(Duration::from_millis(200))
        .context("Helper error pipe stayed open")??;
    ensure!(
        stdout.len() <= limit && stderr.len() <= limit,
        "Helper output exceeded its limit"
    );
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

pub fn approved_command(program: &str) -> Command {
    let mut command = Command::new(program);
    command.env_clear();
    // Explicit allowlist. Provider keys, tokens and the private-library root are absent.
    for name in [
        "PATH",
        "PATHEXT",
        "SystemRoot",
        "WINDIR",
        "HOME",
        "USERPROFILE",
        "TEMP",
        "TMP",
        "TMPDIR",
        "LANG",
        "LC_ALL",
    ] {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    command
}
