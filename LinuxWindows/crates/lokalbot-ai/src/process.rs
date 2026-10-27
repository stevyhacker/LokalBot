//! Child processes that cannot outlive LokalBot, plus liveness checks for
//! PID markers left by an earlier run.
//!
//! Linux: `PR_SET_PDEATHSIG` fires when the *thread* that forked the child
//! exits, so every helper is spawned from one thread that lives as long as
//! the process. Windows: helpers join a job object that kills them when the
//! last handle to it (ours) closes.

use std::io::{self, Read};
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

/// Spawns `command` so the child dies with this process.
pub(crate) fn spawn_tied(command: Command) -> io::Result<Child> {
    #[cfg(target_os = "linux")]
    {
        linux::spawn(command)
    }
    #[cfg(windows)]
    {
        let mut command = command;
        use std::os::windows::process::CommandExt as _;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
        let child = command.spawn()?;
        windows::assign_to_job(&child);
        Ok(child)
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        let mut command = command;
        command.spawn()
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use std::io;
    use std::os::unix::process::CommandExt as _;
    use std::process::{Child, Command};
    use std::sync::OnceLock;
    use std::sync::mpsc;

    use parking_lot::Mutex;

    struct Job {
        command: Command,
        reply: mpsc::Sender<io::Result<Child>>,
    }

    static SPAWNER: OnceLock<Mutex<mpsc::Sender<Job>>> = OnceLock::new();

    pub fn spawn(mut command: Command) -> io::Result<Child> {
        let parent = std::process::id() as libc::pid_t;
        // SAFETY: the hook runs between fork and exec and only calls the
        // async-signal-safe prctl/getppid; it allocates nothing.
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(
                    libc::PR_SET_PDEATHSIG,
                    libc::SIGTERM as libc::c_ulong,
                    0,
                    0,
                    0,
                ) != 0
                {
                    return Err(io::Error::last_os_error());
                }
                // The parent may have died before prctl took effect.
                if libc::getppid() != parent {
                    return Err(io::Error::from_raw_os_error(libc::ESRCH));
                }
                Ok(())
            });
        }
        let sender = SPAWNER.get_or_init(|| {
            let (tx, rx) = mpsc::channel::<Job>();
            let spawned = std::thread::Builder::new()
                .name("lokalbot-helper-spawner".into())
                .spawn(move || {
                    for mut job in rx {
                        let _ = job.reply.send(job.command.spawn());
                    }
                });
            if let Err(err) = spawned {
                log::error!("could not start the helper spawner thread: {err}");
            }
            Mutex::new(tx)
        });
        let (reply, result) = mpsc::channel();
        sender
            .lock()
            .send(Job { command, reply })
            .map_err(|_| io::Error::other("the helper spawner thread is gone"))?;
        result
            .recv()
            .map_err(|_| io::Error::other("the helper spawner thread is gone"))?
    }
}

#[cfg(windows)]
mod windows {
    use std::os::windows::io::AsRawHandle as _;
    use std::process::Child;
    use std::sync::OnceLock;

    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject,
    };

    struct Job(HANDLE);
    // SAFETY: a job handle is a process-wide kernel handle; it is only passed
    // to thread-safe Win32 calls and never closed while the process runs.
    unsafe impl Send for Job {}
    unsafe impl Sync for Job {}

    static JOB: OnceLock<Option<Job>> = OnceLock::new();

    fn job() -> Option<HANDLE> {
        JOB.get_or_init(|| {
            // SAFETY: plain Win32 calls with valid arguments; the info struct
            // is zero-initialized as the API allows and sized exactly.
            unsafe {
                let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if handle.is_null() {
                    log::warn!("could not create a job object for helper processes");
                    return None;
                }
                let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let ok = SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    &info as *const _ as *const core::ffi::c_void,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                );
                if ok == 0 {
                    log::warn!("could not configure the helper job object");
                }
                Some(Job(handle))
            }
        })
        .as_ref()
        .map(|job| job.0)
    }

    pub fn assign_to_job(child: &Child) {
        if let Some(job) = job() {
            // SAFETY: both handles are valid for the duration of the call.
            let ok = unsafe { AssignProcessToJobObject(job, child.as_raw_handle() as HANDLE) };
            if ok == 0 {
                log::warn!(
                    "could not tie llama-server pid={} to LokalBot's lifetime",
                    child.id()
                );
            }
        }
    }
}

/// Whether a process with this PID exists (it may belong to another user).
pub(crate) fn pid_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    #[cfg(unix)]
    {
        // SAFETY: signal 0 only checks for existence and permission.
        let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
        rc == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{
            GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
        };
        const STILL_ACTIVE: u32 = 259;
        // SAFETY: the handle is checked and closed; `code` is a valid out-pointer.
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return false;
            }
            let mut code = 0u32;
            let ok = GetExitCodeProcess(handle, &mut code);
            CloseHandle(handle);
            ok != 0 && code == STILL_ACTIVE
        }
    }
}

/// The executable of a running process.
pub(crate) fn exe_path(pid: u32) -> Option<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_link(format!("/proc/{pid}/exe")).ok()
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStringExt as _;
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{
            OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
        };
        // SAFETY: the handle is checked and closed; the buffer length is passed in and out.
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return None;
            }
            let mut buffer = vec![0u16; 32_768];
            let mut size = buffer.len() as u32;
            let ok = QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut size);
            CloseHandle(handle);
            (ok != 0)
                .then(|| PathBuf::from(std::ffi::OsString::from_wide(&buffer[..size as usize])))
        }
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        let _ = pid;
        None
    }
}

/// SIGTERM, then SIGKILL after `grace` (Windows terminates at once).
/// Returns whether the process is gone.
pub(crate) fn terminate(pid: u32, grace: Duration) -> bool {
    if !pid_alive(pid) {
        return true;
    }
    #[cfg(unix)]
    {
        // SAFETY: plain signal delivery to a PID we verified belongs to a helper.
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
        let deadline = Instant::now() + grace;
        while Instant::now() < deadline {
            if !pid_alive(pid) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        // SAFETY: as above.
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::{
            OpenProcess, PROCESS_TERMINATE, TerminateProcess,
        };
        // SAFETY: the handle is checked and closed.
        unsafe {
            let handle = OpenProcess(PROCESS_TERMINATE, 0, pid);
            if !handle.is_null() {
                TerminateProcess(handle, 1);
                CloseHandle(handle);
            }
        }
        let _ = grace;
    }
    let deadline = Instant::now() + Duration::from_secs(1);
    while Instant::now() < deadline {
        if !pid_alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    !pid_alive(pid)
}

/// Stops our own child: SIGTERM and up to `grace` to exit, then a hard kill.
pub(crate) fn stop_child(child: &mut Child, grace: Duration) {
    if matches!(child.try_wait(), Ok(Some(_))) {
        return;
    }
    #[cfg(unix)]
    {
        // SAFETY: signal delivery to our own, not yet reaped, child.
        unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) };
        let deadline = Instant::now() + grace;
        while Instant::now() < deadline {
            if matches!(child.try_wait(), Ok(Some(_))) {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    #[cfg(not(unix))]
    let _ = grace;
    let _ = child.kill();
    let _ = child.wait();
}

pub(crate) struct Captured {
    pub status: Option<ExitStatus>,
    pub stdout: String,
    pub stderr: String,
}

/// Runs a short command with both pipes drained concurrently (a full pipe
/// would block the child), killing it after `timeout`.
pub(crate) fn run_capture(mut command: Command, timeout: Duration) -> io::Result<Captured> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        command.creation_flags(0x0800_0000);
    }
    let mut child = command.spawn()?;
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut text = Vec::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_end(&mut text);
            }
            String::from_utf8_lossy(&text).into_owned()
        })
    };
    let out = drain(
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let err = drain(
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break Some(status);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    Ok(Captured {
        status,
        stdout: out.join().unwrap_or_default(),
        stderr: err.join().unwrap_or_default(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn this_process_is_alive_and_a_bogus_pid_is_not() {
        assert!(pid_alive(std::process::id()));
        assert!(!pid_alive(0));
        assert!(!pid_alive(4_000_000_000));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn exe_path_names_this_test_binary() {
        let exe = exe_path(std::process::id()).unwrap();
        assert_eq!(
            exe,
            std::env::current_exe().unwrap().canonicalize().unwrap()
        );
    }

    #[cfg(unix)]
    #[test]
    fn tied_children_can_be_stopped() {
        let mut command = Command::new("sleep");
        command.arg("30");
        let mut child = spawn_tied(command).unwrap();
        let pid = child.id();
        assert!(pid_alive(pid));
        stop_child(&mut child, Duration::from_secs(2));
        assert!(matches!(child.try_wait(), Ok(Some(_))));
    }

    #[cfg(unix)]
    #[test]
    fn capture_reads_both_pipes_and_times_out() {
        let mut command = Command::new("sh");
        command.args(["-c", "echo out; echo err 1>&2"]);
        let captured = run_capture(command, Duration::from_secs(5)).unwrap();
        assert_eq!(captured.stdout.trim(), "out");
        assert_eq!(captured.stderr.trim(), "err");
        let mut slow = Command::new("sleep");
        slow.arg("5");
        assert!(
            run_capture(slow, Duration::from_millis(200))
                .unwrap()
                .status
                .is_none()
        );
    }
}
