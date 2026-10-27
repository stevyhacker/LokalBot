//! One pi subprocess (`PiProcess.swift`): spawns it from a launch plan, feeds
//! stdout through the JSONL splitter, keeps a stderr tail, writes stdin on its
//! own thread with bounded buffering, and supervises shutdown.
//!
//! Nothing it starts may outlive LokalBot:
//! - Linux: Bun leads a new session (`setsid`) and gets `SIGTERM` when
//!   LokalBot dies (`PR_SET_PDEATHSIG`, from a spawner thread that lives as
//!   long as the process, since the signal follows the forking thread). pi's
//!   own `SIGTERM` handler kills the tool commands it started in their own
//!   process groups. Stopping sends `SIGTERM` to the group, waits, then
//!   `SIGKILL`s the group and every descendant found in `/proc`. A record in
//!   `<library>/agent/processes` lets the next run stop a pi that ignored
//!   its signal.
//! - Windows: Bun starts suspended inside its own job object with
//!   `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, then resumes. Every tool command
//!   inherits the job, so stopping (or LokalBot exiting, which closes the
//!   handle) ends the whole tree.

use std::collections::VecDeque;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, anyhow};
use parking_lot::{Condvar, Mutex};

use crate::frame::FrameSplitter;
use crate::launch::LaunchPlan;

/// Stopping waits this long for an orderly exit before force-killing.
pub const STOP_GRACE: Duration = Duration::from_secs(2);
const STDERR_LINES: usize = 50;
const STDERR_LINE_CHARS: usize = 8_192;
const MAX_PENDING_WRITES: usize = 128;

#[derive(Debug, thiserror::Error, Clone, PartialEq, Eq)]
pub enum ProcessError {
    #[error("Agent executable not found: {0}")]
    ExecutableNotFound(String),
    #[error("The agent process is not running.")]
    NotRunning,
    #[error("The agent command exceeded the 4 MiB safety limit.")]
    PayloadTooLarge,
    #[error("The agent input buffer is full.")]
    InputBackpressure,
}

/// How the process ended, for the session's failure notice.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ExitReport {
    pub code: Option<i32>,
    pub stderr_tail: Vec<String>,
}

type FrameSink = Box<dyn FnMut(String) + Send>;
type ExitSink = Box<dyn FnOnce(ExitReport) + Send>;

struct Writer {
    queue: Mutex<WriterQueue>,
    ready: Condvar,
}

#[derive(Default)]
struct WriterQueue {
    lines: VecDeque<Vec<u8>>,
    buffered: usize,
    closed: bool,
}

/// A running pi. Dropping it kills the whole process tree.
pub struct PiProcess {
    pid: u32,
    /// Reaped only by [`stop`](Self::stop) or Drop, never by the waiter, so
    /// the PID (and its process group) cannot be reused while it may still
    /// be signalled.
    child: Mutex<Option<Child>>,
    writer: Arc<Writer>,
    stderr_tail: Arc<Mutex<VecDeque<String>>>,
    exited: Arc<AtomicBool>,
    marker: Option<PathBuf>,
    #[cfg(windows)]
    job: windows::Job,
}

impl PiProcess {
    /// Starts `plan`. `on_frame` receives every stdout record in order;
    /// `on_exit` runs once after stdout closes and the process has exited.
    /// `markers` is the folder for leftover-process records (Linux).
    pub fn spawn(
        plan: &LaunchPlan,
        markers: Option<&Path>,
        on_frame: impl FnMut(String) + Send + 'static,
        on_exit: impl FnOnce(ExitReport) + Send + 'static,
    ) -> Result<PiProcess> {
        if !crate::layout::is_executable(&plan.executable) {
            return Err(
                ProcessError::ExecutableNotFound(plan.executable.display().to_string()).into(),
            );
        }
        let mut command = Command::new(&plan.executable);
        command
            .args(&plan.arguments)
            .env_clear()
            .envs(&plan.environment)
            .current_dir(&plan.working_directory)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let spawned = spawn_tree(command)
            .with_context(|| format!("starting {}", plan.executable.display()))?;
        let mut child = spawned.child;
        let pid = child.id();
        let stdin = child.stdin.take();
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        let marker = markers.and_then(|dir| write_marker(dir, pid, &plan.executable));
        let writer = Arc::new(Writer {
            queue: Mutex::new(WriterQueue::default()),
            ready: Condvar::new(),
        });
        if let Some(stdin) = stdin {
            let writer = writer.clone();
            std::thread::Builder::new()
                .name("lokalbot-pi-stdin".into())
                .spawn(move || write_loop(stdin, &writer))?;
        }
        let stderr_tail = Arc::new(Mutex::new(VecDeque::new()));
        let stderr_done = Arc::new((Mutex::new(false), Condvar::new()));
        if let Some(stderr) = stderr {
            let tail = stderr_tail.clone();
            let done = stderr_done.clone();
            std::thread::Builder::new()
                .name("lokalbot-pi-stderr".into())
                .spawn(move || {
                    read_stderr(stderr, &tail);
                    *done.0.lock() = true;
                    done.1.notify_all();
                })?;
        } else {
            *stderr_done.0.lock() = true;
        }

        let process = PiProcess {
            pid,
            child: Mutex::new(Some(child)),
            writer,
            stderr_tail,
            exited: Arc::new(AtomicBool::new(false)),
            marker,
            #[cfg(windows)]
            job: spawned.job,
        };
        let mut on_frame: FrameSink = Box::new(on_frame);
        let on_exit: ExitSink = Box::new(on_exit);
        let exited = process.exited.clone();
        let tail = process.stderr_tail.clone();
        std::thread::Builder::new()
            .name("lokalbot-pi-stdout".into())
            .spawn(move || {
                if let Some(stdout) = stdout {
                    read_frames(stdout, &mut on_frame);
                }
                let code = wait_without_reaping(pid);
                exited.store(true, Ordering::SeqCst);
                // Let the stderr reader catch the last lines of a crash.
                let (lock, ready) = &*stderr_done;
                let mut done = lock.lock();
                if !*done {
                    ready.wait_for(&mut done, Duration::from_millis(500));
                }
                drop(done);
                let stderr_tail = tail.lock().iter().cloned().collect();
                on_exit(ExitReport { code, stderr_tail });
            })?;
        log::info!("pi started pid={pid}");
        Ok(process)
    }

    pub fn pid(&self) -> u32 {
        self.pid
    }

    pub fn is_running(&self) -> bool {
        !self.exited.load(Ordering::SeqCst)
    }

    pub fn stderr_tail(&self) -> Vec<String> {
        self.stderr_tail.lock().iter().cloned().collect()
    }

    /// Queues one JSONL record. Never blocks on a full pipe.
    pub fn send_line(&self, line: &str) -> Result<(), ProcessError> {
        let mut payload = line.as_bytes().to_vec();
        payload.push(b'\n');
        if payload.len() > crate::frame::MAX_FRAME_BYTES {
            return Err(ProcessError::PayloadTooLarge);
        }
        if !self.is_running() {
            return Err(ProcessError::NotRunning);
        }
        let mut queue = self.writer.queue.lock();
        if queue.closed {
            return Err(ProcessError::NotRunning);
        }
        if queue.lines.len() >= MAX_PENDING_WRITES
            || queue.buffered + payload.len() > crate::frame::MAX_FRAME_BYTES
        {
            return Err(ProcessError::InputBackpressure);
        }
        queue.buffered += payload.len();
        queue.lines.push_back(payload);
        drop(queue);
        self.writer.ready.notify_all();
        Ok(())
    }

    /// Closes stdin (pi's orderly shutdown), asks the tree to exit, waits up
    /// to `grace`, then kills everything that is left. Blocking; idempotent.
    pub fn stop(&self, grace: Duration) {
        self.close_stdin();
        if self.is_running() {
            self.signal_terminate();
            let deadline = Instant::now() + grace;
            while self.is_running() && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(25));
            }
        }
        self.kill_tree();
    }

    /// Asks the tree to exit without waiting (app quit: several sessions stop
    /// in parallel, then [`kill_tree`](Self::kill_tree) cleans up).
    pub fn begin_stop(&self) {
        self.close_stdin();
        if self.is_running() {
            self.signal_terminate();
        }
    }

    fn close_stdin(&self) {
        self.writer.queue.lock().closed = true;
        self.writer.ready.notify_all();
    }

    fn signal_terminate(&self) {
        let reaped = self.child.lock().is_none();
        #[cfg(unix)]
        if !reaped {
            // SAFETY: signal delivery to the process group Bun leads; the
            // unreaped child keeps that ID reserved.
            unsafe {
                libc::kill(-(self.pid as libc::pid_t), libc::SIGTERM);
            }
        }
        // Windows has no SIGTERM; closing stdin is pi's shutdown request.
        let _ = reaped;
    }

    /// Kills Bun, pi and every command they started, then reaps Bun.
    pub fn kill_tree(&self) {
        let mut child = self.child.lock();
        let Some(mut owned) = child.take() else {
            return;
        };
        #[cfg(unix)]
        {
            let descendants = unix::descendants(self.pid);
            // SAFETY: Bun is not reaped yet, so its PID and group ID are still
            // ours; the descendants were found under it a moment ago.
            unsafe {
                libc::kill(-(self.pid as libc::pid_t), libc::SIGKILL);
                for pid in descendants {
                    libc::kill(pid as libc::pid_t, libc::SIGKILL);
                }
            }
        }
        #[cfg(windows)]
        self.job.terminate();
        let _ = owned.kill();
        let _ = owned.wait();
        drop(child);
        if let Some(marker) = &self.marker {
            let _ = std::fs::remove_file(marker);
        }
        self.exited.store(true, Ordering::SeqCst);
    }
}

impl Drop for PiProcess {
    fn drop(&mut self) {
        self.close_stdin();
        self.kill_tree();
    }
}

/// Blocks until `pid` exits, leaving it unreaped (Unix `WNOWAIT`), and
/// returns its exit code when it exited normally.
fn wait_without_reaping(pid: u32) -> Option<i32> {
    #[cfg(unix)]
    {
        loop {
            // SAFETY: waits on our own child; `info` is a valid out-pointer and
            // zeroed as the API allows.
            let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
            let rc = unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid as libc::id_t,
                    &mut info,
                    libc::WEXITED | libc::WNOWAIT,
                )
            };
            if rc == 0 {
                // SAFETY: waitid filled `info` for an exited child.
                let status = unsafe { info.si_status() };
                return (info.si_code == libc::CLD_EXITED).then_some(status);
            }
            if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
                return None;
            }
        }
    }
    #[cfg(windows)]
    {
        windows::wait_for_exit(pid)
    }
}

fn write_loop(mut stdin: ChildStdin, writer: &Writer) {
    loop {
        let line = {
            let mut queue = writer.queue.lock();
            loop {
                if let Some(line) = queue.lines.pop_front() {
                    queue.buffered = queue.buffered.saturating_sub(line.len());
                    break Some(line);
                }
                if queue.closed {
                    break None;
                }
                writer.ready.wait(&mut queue);
            }
        };
        let Some(line) = line else {
            return; // Dropping stdin closes the pipe.
        };
        if stdin.write_all(&line).and_then(|()| stdin.flush()).is_err() {
            let mut queue = writer.queue.lock();
            queue.closed = true;
            queue.lines.clear();
            queue.buffered = 0;
            return;
        }
    }
}

fn read_frames(mut stdout: impl std::io::Read, on_frame: &mut FrameSink) {
    let mut splitter = FrameSplitter::default();
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        match stdout.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                for frame in splitter.append(&buffer[..read]) {
                    on_frame(frame);
                }
            }
            Err(err) if err.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    if let Some(frame) = splitter.flush() {
        on_frame(frame);
    }
}

fn read_stderr(mut stderr: impl std::io::Read, tail: &Mutex<VecDeque<String>>) {
    let mut pending = Vec::new();
    let mut buffer = vec![0u8; 16 * 1024];
    let keep = |bytes: &[u8]| {
        let text = String::from_utf8_lossy(bytes);
        let line: String = text.trim_end().chars().take(STDERR_LINE_CHARS).collect();
        if line.is_empty() {
            return;
        }
        let mut tail = tail.lock();
        tail.push_back(line);
        while tail.len() > STDERR_LINES {
            tail.pop_front();
        }
    };
    loop {
        match stderr.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(read) => {
                pending.extend_from_slice(&buffer[..read]);
                while let Some(newline) = pending.iter().position(|b| *b == b'\n') {
                    keep(&pending[..newline]);
                    pending.drain(..=newline);
                }
                if pending.len() > STDERR_LINE_CHARS * 4 {
                    keep(&pending);
                    pending.clear();
                }
            }
        }
    }
    if !pending.is_empty() {
        keep(&pending);
    }
}

/// A child plus, on Windows, the job that holds its tree.
pub(crate) struct Spawned {
    pub child: Child,
    #[cfg(windows)]
    pub job: windows::Job,
}

/// Spawns `command` as the root of a process tree tied to LokalBot.
pub(crate) fn spawn_tree(command: Command) -> std::io::Result<Spawned> {
    #[cfg(unix)]
    {
        Ok(Spawned {
            child: unix::spawn(command)?,
        })
    }
    #[cfg(windows)]
    {
        windows::spawn(command)
    }
}

/// Runs a short helper (`bun install`) tied to LokalBot and waits for it,
/// killing its tree after `timeout`. Returns the exit code (`None` when
/// killed by a signal or the timeout).
pub(crate) fn run_tree(mut command: Command, timeout: Duration) -> Result<Option<i32>> {
    command.stdin(Stdio::null());
    let spawned = spawn_tree(command)?;
    let mut child = spawned.child;
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait()? {
            #[cfg(windows)]
            spawned.job.terminate();
            return Ok(status.code());
        }
        if Instant::now() >= deadline {
            #[cfg(unix)]
            // SAFETY: kills the process group our child leads.
            unsafe {
                libc::kill(-(child.id() as libc::pid_t), libc::SIGKILL);
            }
            #[cfg(windows)]
            spawned.job.terminate();
            let _ = child.kill();
            let _ = child.wait();
            return Err(anyhow!("timed out after {} s", timeout.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

// ------------------------------------------------------------------ markers

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Marker {
    pid: u32,
    executable: String,
    #[serde(rename = "ownerPID")]
    owner_pid: u32,
}

fn write_marker(dir: &Path, pid: u32, executable: &Path) -> Option<PathBuf> {
    if !cfg!(unix) {
        return None; // The job object already covers a crashed LokalBot.
    }
    std::fs::create_dir_all(dir).ok()?;
    let path = dir.join(format!("pi-{pid}.json"));
    let marker = Marker {
        pid,
        executable: executable.to_string_lossy().into_owned(),
        owner_pid: std::process::id(),
    };
    let bytes = serde_json::to_vec(&marker).ok()?;
    lokalbot_core::library::write_atomic(&path, &bytes).ok()?;
    Some(path)
}

/// Stops pi processes an earlier, crashed LokalBot left behind. Only a
/// process still running the recorded Bun binary, whose LokalBot is gone, is
/// touched.
pub fn stop_leftovers(markers: &Path) {
    let Ok(entries) = std::fs::read_dir(markers) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let marker: Option<Marker> = std::fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        let Some(marker) = marker else {
            let _ = std::fs::remove_file(&path);
            continue;
        };
        if marker.owner_pid == std::process::id() {
            continue;
        }
        #[cfg(unix)]
        {
            if unix::alive(marker.owner_pid) {
                continue; // Another LokalBot's live session.
            }
            if unix::exe_is(marker.pid, Path::new(&marker.executable)) {
                log::info!("stopping a pi left by an earlier run pid={}", marker.pid);
                let descendants = unix::descendants(marker.pid);
                // SAFETY: the PID runs our recorded Bun binary and the LokalBot
                // that started it is gone.
                unsafe {
                    libc::kill(-(marker.pid as libc::pid_t), libc::SIGKILL);
                    libc::kill(marker.pid as libc::pid_t, libc::SIGKILL);
                    for pid in descendants {
                        libc::kill(pid as libc::pid_t, libc::SIGKILL);
                    }
                }
            }
        }
        let _ = std::fs::remove_file(&path);
    }
}

// --------------------------------------------------------------------- unix

#[cfg(unix)]
mod unix {
    use std::io;
    use std::os::unix::process::CommandExt as _;
    use std::path::Path;
    use std::process::{Child, Command};
    use std::sync::OnceLock;
    use std::sync::mpsc;

    use parking_lot::Mutex;

    struct Job {
        command: Command,
        reply: mpsc::Sender<io::Result<Child>>,
    }

    static SPAWNER: OnceLock<Mutex<mpsc::Sender<Job>>> = OnceLock::new();

    /// `PR_SET_PDEATHSIG` fires when the forking *thread* exits, so every
    /// pi is forked from one thread that lives as long as LokalBot.
    pub fn spawn(mut command: Command) -> io::Result<Child> {
        let parent = std::process::id() as libc::pid_t;
        // SAFETY: runs between fork and exec and only calls async-signal-safe
        // functions (setsid, prctl, getppid); it allocates nothing.
        unsafe {
            command.pre_exec(move || {
                if libc::setsid() == -1 {
                    return Err(io::Error::last_os_error());
                }
                #[cfg(target_os = "linux")]
                {
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
                    // LokalBot may have died before prctl took effect.
                    if libc::getppid() != parent {
                        return Err(io::Error::from_raw_os_error(libc::ESRCH));
                    }
                }
                #[cfg(not(target_os = "linux"))]
                let _ = parent;
                Ok(())
            });
        }
        let sender = SPAWNER.get_or_init(|| {
            let (tx, rx) = mpsc::channel::<Job>();
            let spawned = std::thread::Builder::new()
                .name("lokalbot-agent-spawner".into())
                .spawn(move || {
                    for mut job in rx {
                        let _ = job.reply.send(job.command.spawn());
                    }
                });
            if let Err(err) = spawned {
                log::error!("could not start the agent spawner thread: {err}");
            }
            Mutex::new(tx)
        });
        let (reply, result) = mpsc::channel();
        sender
            .lock()
            .send(Job { command, reply })
            .map_err(|_| io::Error::other("the agent spawner thread is gone"))?;
        result
            .recv()
            .map_err(|_| io::Error::other("the agent spawner thread is gone"))?
    }

    pub fn alive(pid: u32) -> bool {
        if pid == 0 {
            return false;
        }
        // SAFETY: signal 0 only checks for existence and permission.
        let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
        rc == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }

    pub fn exe_is(pid: u32, expected: &Path) -> bool {
        let Ok(exe) = std::fs::read_link(format!("/proc/{pid}/exe")) else {
            return false;
        };
        match (exe.canonicalize(), expected.canonicalize()) {
            (Ok(a), Ok(b)) => a == b,
            _ => exe == expected,
        }
    }

    /// Every process whose parent chain leads to `root`, from `/proc`.
    pub fn descendants(root: u32) -> Vec<u32> {
        let Ok(entries) = std::fs::read_dir("/proc") else {
            return Vec::new();
        };
        let mut parents: Vec<(u32, u32)> = Vec::new();
        for entry in entries.flatten() {
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|s| s.parse::<u32>().ok())
            else {
                continue;
            };
            let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
                continue;
            };
            // `pid (comm) state ppid …`; comm may contain spaces and parens.
            let Some(rest) = stat.rfind(')').map(|at| &stat[at + 1..]) else {
                continue;
            };
            let ppid = rest
                .split_whitespace()
                .nth(1)
                .and_then(|s| s.parse::<u32>().ok());
            if let Some(ppid) = ppid {
                parents.push((pid, ppid));
            }
        }
        let mut found = vec![root];
        let mut index = 0;
        while index < found.len() {
            let parent = found[index];
            for (pid, ppid) in &parents {
                if *ppid == parent && !found.contains(pid) {
                    found.push(*pid);
                }
            }
            index += 1;
        }
        found.remove(0);
        found
    }
}

// ------------------------------------------------------------------ windows

#[cfg(windows)]
pub(crate) mod windows {
    use std::os::windows::io::AsRawHandle as _;
    use std::os::windows::process::CommandExt as _;
    use std::process::{Child, Command};

    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
    };
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject,
    };
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, INFINITE, OpenProcess, OpenThread, PROCESS_QUERY_LIMITED_INFORMATION,
        PROCESS_SYNCHRONIZE, ResumeThread, THREAD_SUSPEND_RESUME, WaitForSingleObject,
    };

    use super::Spawned;

    const CREATE_SUSPENDED: u32 = 0x0000_0004;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    /// A job object that kills its processes when the last handle closes.
    pub struct Job(HANDLE);

    // SAFETY: a job handle is a process-wide kernel handle, only passed to
    // thread-safe Win32 calls and closed once, in Drop.
    unsafe impl Send for Job {}
    unsafe impl Sync for Job {}

    impl Job {
        fn new() -> std::io::Result<Job> {
            // SAFETY: plain Win32 calls with valid arguments; the info struct
            // is zero-initialized as the API allows and sized exactly.
            unsafe {
                let handle = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if handle.is_null() {
                    return Err(std::io::Error::last_os_error());
                }
                let job = Job(handle);
                let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let ok = SetInformationJobObject(
                    handle,
                    JobObjectExtendedLimitInformation,
                    &info as *const _ as *const core::ffi::c_void,
                    std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                );
                if ok == 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(job)
            }
        }

        pub fn terminate(&self) {
            // SAFETY: the handle is valid until Drop.
            unsafe {
                TerminateJobObject(self.0, 1);
            }
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            // SAFETY: closing our own handle; with KILL_ON_JOB_CLOSE this ends
            // any process still in the job.
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    /// Starts the process suspended, puts it in a fresh job, then resumes it,
    /// so not even its first child can start outside the job.
    pub fn spawn(mut command: Command) -> std::io::Result<Spawned> {
        let job = Job::new()?;
        command.creation_flags(CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
        let mut child: Child = command.spawn()?;
        // SAFETY: both handles are valid for the duration of the call.
        let assigned =
            unsafe { AssignProcessToJobObject(job.0, child.as_raw_handle() as HANDLE) } != 0;
        if !assigned {
            let err = std::io::Error::last_os_error();
            let _ = child.kill();
            let _ = child.wait();
            return Err(err);
        }
        if !resume_threads(child.id()) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::other("could not resume the agent process"));
        }
        Ok(Spawned { child, job })
    }

    fn resume_threads(pid: u32) -> bool {
        // SAFETY: the snapshot handle is checked and closed; THREADENTRY32 is
        // sized as the API requires; thread handles are checked and closed.
        unsafe {
            let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if snapshot == INVALID_HANDLE_VALUE {
                return false;
            }
            let mut entry: THREADENTRY32 = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<THREADENTRY32>() as u32;
            let mut resumed = false;
            let mut more = Thread32First(snapshot, &mut entry) != 0;
            while more {
                if entry.th32OwnerProcessID == pid {
                    let thread = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID);
                    if !thread.is_null() {
                        resumed |= ResumeThread(thread) != u32::MAX;
                        CloseHandle(thread);
                    }
                }
                more = Thread32Next(snapshot, &mut entry) != 0;
            }
            CloseHandle(snapshot);
            resumed
        }
    }

    pub fn wait_for_exit(pid: u32) -> Option<i32> {
        // SAFETY: the handle is checked and closed; `code` is a valid out-pointer.
        unsafe {
            let handle = OpenProcess(
                PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                0,
                pid,
            );
            if handle.is_null() {
                return None;
            }
            WaitForSingleObject(handle, INFINITE);
            let mut code = 0u32;
            let ok = GetExitCodeProcess(handle, &mut code);
            CloseHandle(handle);
            (ok != 0).then_some(code as i32)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn plan(script: &str) -> LaunchPlan {
        let environment: BTreeMap<String, String> = std::env::vars().collect();
        #[cfg(unix)]
        let (executable, arguments) = (
            PathBuf::from("/bin/sh"),
            vec!["-c".to_string(), script.to_string()],
        );
        #[cfg(windows)]
        let (executable, arguments) = (
            PathBuf::from(std::env::var("ComSpec").unwrap_or_else(|_| "cmd.exe".into())),
            vec!["/C".to_string(), script.to_string()],
        );
        LaunchPlan {
            executable,
            arguments,
            environment,
            working_directory: std::env::temp_dir(),
        }
    }

    fn collect(
        script: &str,
    ) -> (
        PiProcess,
        async_channel::Receiver<String>,
        async_channel::Receiver<ExitReport>,
    ) {
        let (frames_tx, frames) = async_channel::unbounded();
        let (exit_tx, exit) = async_channel::unbounded();
        let process = PiProcess::spawn(
            &plan(script),
            None,
            move |frame| {
                let _ = frames_tx.send_blocking(frame);
            },
            move |report| {
                let _ = exit_tx.send_blocking(report);
            },
        )
        .unwrap();
        (process, frames, exit)
    }

    #[cfg(unix)]
    #[test]
    fn round_trips_lines_through_cat() {
        let (process, frames, _exit) = collect("cat");
        process.send_line(r#"{"a":1}"#).unwrap();
        process.send_line(r#"{"b":"x y"}"#).unwrap();
        assert_eq!(frames.recv_blocking().unwrap(), r#"{"a":1}"#);
        assert_eq!(frames.recv_blocking().unwrap(), r#"{"b":"x y"}"#);
        process.stop(STOP_GRACE);
    }

    #[test]
    fn frames_finish_on_exit_and_stderr_is_kept() {
        #[cfg(unix)]
        let script = r#"echo '{"done":true}'; echo oops 1>&2"#;
        #[cfg(windows)]
        let script = r#"echo {"done":true}& echo oops 1>&2"#;
        let (process, frames, exit) = collect(script);
        assert!(frames.recv_blocking().unwrap().contains("done"));
        let report = exit.recv_blocking().unwrap();
        assert!(
            report.stderr_tail.iter().any(|l| l.contains("oops")),
            "{report:?}"
        );
        assert!(!process.is_running());
        assert_eq!(process.send_line("{}"), Err(ProcessError::NotRunning));
    }

    #[test]
    fn missing_executable_is_reported() {
        let mut plan = plan("true");
        plan.executable = PathBuf::from("/definitely/not/here/bun");
        let error = PiProcess::spawn(&plan, None, |_| {}, |_| {}).err().unwrap();
        assert!(error.to_string().contains("not found"), "{error}");
    }

    /// pi's tool commands run detached in their own groups; stopping must
    /// still end them, and stop is bounded when nothing drains stdin.
    #[cfg(unix)]
    #[test]
    fn stop_kills_detached_grandchildren_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("grandchild.pid");
        let script = format!(
            "setsid sh -c 'trap \"\" TERM; sleep 60' & echo $! > {}; trap '' TERM; sleep 60",
            pidfile.display()
        );
        let (process, _frames, exit) = collect(&script);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !pidfile.is_file() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        std::thread::sleep(Duration::from_millis(200));
        let grandchild: u32 = std::fs::read_to_string(&pidfile)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(unix::alive(grandchild));
        let started = Instant::now();
        process.stop(Duration::from_millis(300));
        assert!(started.elapsed() < Duration::from_secs(3));
        exit.recv_blocking().unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while unix::alive(grandchild) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!unix::alive(grandchild), "grandchild {grandchild} survived");
        process.stop(Duration::from_millis(10));
    }

    #[cfg(windows)]
    #[test]
    fn stop_ends_the_whole_job() {
        let (process, _frames, exit) = collect("ping -n 60 127.0.0.1 > NUL");
        std::thread::sleep(Duration::from_millis(300));
        assert!(process.is_running());
        process.stop(Duration::from_millis(300));
        exit.recv_blocking().unwrap();
        assert!(!process.is_running());
    }

    #[cfg(unix)]
    #[test]
    fn leftover_markers_of_live_owners_are_kept() {
        let dir = tempfile::tempdir().unwrap();
        let marker = write_marker(dir.path(), 4_000_000_000, Path::new("/bin/false")).unwrap();
        // The owner is this test process, which is alive.
        stop_leftovers(dir.path());
        assert!(marker.is_file());
        std::fs::write(&marker, b"not json").unwrap();
        stop_leftovers(dir.path());
        assert!(!marker.is_file());
    }
}
