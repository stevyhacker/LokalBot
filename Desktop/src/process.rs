//! Bounded child processes: helpers cannot stall the capture loop indefinitely.
use anyhow::{Context, Result, ensure};
use std::{
    io::Read,
    process::{Command, Output, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

pub fn bounded_output(command: &mut Command, timeout: Duration, limit: usize) -> Result<Output> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    #[cfg(windows)]
    let job = windows_job::Job::prepare(command)?;
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("Could not start helper executable")?;
    #[cfg(unix)]
    let tree = ProcessGroup(child.id());
    #[cfg(windows)]
    let tree = job.attach(&mut child)?;
    let stdout = child.stdout.take().context("Missing helper stdout")?;
    let stderr = child.stderr.take().context("Missing helper stderr")?;
    let exceeded = Arc::new(AtomicBool::new(false));
    let reader = |mut stream: Box<dyn Read + Send>| {
        let (tx, rx) = mpsc::channel();
        let exceeded = exceeded.clone();
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let result = (|| {
                let mut buffer = [0; 8192];
                loop {
                    let size = stream.read(&mut buffer)?;
                    if size == 0 {
                        break;
                    }
                    let remaining = (limit + 1).saturating_sub(bytes.len());
                    bytes.extend_from_slice(&buffer[..size.min(remaining)]);
                    if bytes.len() > limit {
                        exceeded.store(true, Ordering::Release);
                    }
                }
                Ok::<_, std::io::Error>(bytes)
            })();
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
        if start.elapsed() >= timeout || exceeded.load(Ordering::Acquire) {
            drop(tree);
            let _ = child.kill();
            let _ = child.wait();
            if exceeded.load(Ordering::Acquire) {
                anyhow::bail!("Helper output exceeded its limit");
            }
            anyhow::bail!("Helper exceeded its time limit");
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    // Also clean up descendants when their parent exits successfully. Otherwise
    // they could keep pipes or tasks alive beyond the approved invocation.
    drop(tree);
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

#[cfg(unix)]
struct ProcessGroup(u32);
#[cfg(unix)]
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        // SAFETY: a negative PID addresses only the new child's process group.
        unsafe {
            libc::kill(-(self.0 as i32), libc::SIGKILL);
        }
    }
}

#[cfg(windows)]
mod windows_job {
    use super::*;
    use std::{
        mem::{size_of, zeroed},
        os::windows::{io::AsRawHandle, process::CommandExt},
    };
    use windows_sys::Win32::{
        Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE},
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First,
                Thread32Next,
            },
            JobObjects::{
                AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
                SetInformationJobObject,
            },
            Threading::{CREATE_SUSPENDED, OpenThread, ResumeThread, THREAD_SUSPEND_RESUME},
        },
    };
    pub struct Job(HANDLE);
    impl Drop for Job {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
    impl Job {
        pub fn prepare(command: &mut Command) -> Result<Self> {
            // Suspend before assigning to the job so a fast child cannot launch
            // descendants outside it. Job membership is inherited by children.
            command.creation_flags(CREATE_SUSPENDED);
            unsafe {
                let job = Self(CreateJobObjectW(std::ptr::null(), std::ptr::null()));
                ensure!(!job.0.is_null(), "Could not create helper process job");
                let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = zeroed();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                ensure!(
                    SetInformationJobObject(
                        job.0,
                        JobObjectExtendedLimitInformation,
                        &info as *const _ as _,
                        size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32
                    ) != 0,
                    "Could not bound helper process job"
                );
                Ok(job)
            }
        }
        pub fn attach(self, child: &mut std::process::Child) -> Result<Self> {
            let result = unsafe {
                (|| {
                    ensure!(
                        AssignProcessToJobObject(self.0, child.as_raw_handle() as HANDLE) != 0,
                        "Could not contain helper process tree"
                    );
                    let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
                    ensure!(
                        snapshot != INVALID_HANDLE_VALUE,
                        "Could not inspect helper thread"
                    );
                    let snapshot = Job(snapshot);
                    let mut entry: THREADENTRY32 = zeroed();
                    entry.dwSize = size_of::<THREADENTRY32>() as u32;
                    let mut found = Thread32First(snapshot.0, &mut entry) != 0;
                    while found {
                        if entry.th32OwnerProcessID == child.id() {
                            let thread =
                                Job(OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID));
                            ensure!(
                                !thread.0.is_null() && ResumeThread(thread.0) != u32::MAX,
                                "Could not resume contained helper"
                            );
                            return Ok(());
                        }
                        found = Thread32Next(snapshot.0, &mut entry) != 0;
                    }
                    anyhow::bail!("Helper's suspended thread was not found")
                })()
            };
            if result.is_err() {
                let _ = child.kill();
                let _ = child.wait();
            }
            result?;
            Ok(self)
        }
    }
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
