//! One LokalBot per library, and the local socket other processes use to
//! reach it.
//!
//! `lokalbot quick-recall`, `lokalbot toggle-recording` and
//! `lokalbot dictate --toggle` forward to the running app through [`send`];
//! that is also how Wayland users bind compositor shortcuts. The socket is a
//! Unix socket in the user's runtime directory (mode 0700) or a named pipe on
//! Windows, named after a hash of the library root so test libraries never
//! collide.

use std::fs::{File, OpenOptions, TryLockError};
use std::io::{BufRead, BufReader, Read as _, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

use interprocess::ConnectWaitMode;
use interprocess::local_socket::prelude::*;
use interprocess::local_socket::{
    ConnectOptions, GenericFilePath, ListenerOptions, Name, Stream, traits::Stream as StreamTrait,
};
use lokalbot_core::LibraryPaths;
use sha2::{Digest, Sha256};

/// A request from another process (the CLI or a compositor shortcut).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IpcCommand {
    /// Bring the main window forward.
    Show,
    /// Open the Ask panel (`quick-recall` window).
    QuickRecall,
    ToggleRecording,
    StartDictation,
    StopDictation,
    ToggleDictation,
    /// Show a meeting by id.
    OpenMeeting(String),
    /// `lokalbot install-update`: install the offered update and relaunch.
    InstallUpdate,
}

impl IpcCommand {
    fn encode(&self) -> String {
        match self {
            Self::Show => "show".into(),
            Self::QuickRecall => "quick-recall".into(),
            Self::ToggleRecording => "toggle-recording".into(),
            Self::StartDictation => "dictation-start".into(),
            Self::StopDictation => "dictation-stop".into(),
            Self::ToggleDictation => "dictation-toggle".into(),
            Self::OpenMeeting(id) => format!("open-meeting {id}"),
            Self::InstallUpdate => "install-update".into(),
        }
    }

    fn decode(text: &str) -> Option<Self> {
        let (verb, argument) = match text.split_once(' ') {
            Some((verb, argument)) => (verb, Some(argument.trim())),
            None => (text, None),
        };
        Some(match (verb, argument) {
            ("show", None) => Self::Show,
            ("quick-recall", None) => Self::QuickRecall,
            ("toggle-recording", None) => Self::ToggleRecording,
            ("dictation-start", None) => Self::StartDictation,
            ("dictation-stop", None) => Self::StopDictation,
            ("dictation-toggle", None) => Self::ToggleDictation,
            ("open-meeting", Some(id)) if !id.is_empty() => Self::OpenMeeting(id.to_string()),
            ("install-update", None) => Self::InstallUpdate,
            _ => return None,
        })
    }
}

/// Every line starts with this, so an incompatible future protocol is refused
/// instead of misread.
const PROTOCOL: &str = "LOKALBOT/1";
const MAX_LINE: usize = 4096;
const IO_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, thiserror::Error)]
pub enum InstanceError {
    #[error("LokalBot is already running for this library")]
    AlreadyRunning,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

#[derive(Debug, thiserror::Error)]
pub enum IpcError {
    /// No LokalBot is listening for this library.
    #[error("LokalBot is not running")]
    NotRunning,
    #[error("LokalBot refused the request: {0}")]
    Refused(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

/// Holds the library's instance lock (`<root>/.instance.lock`) until dropped.
/// The OS releases it if the process dies, so a crash never leaves a stale
/// lock behind.
#[derive(Debug)]
pub struct InstanceGuard {
    _file: File,
    path: PathBuf,
}

impl InstanceGuard {
    pub fn lock_path(&self) -> &Path {
        &self.path
    }
}

/// Takes the instance lock for the library at `root`, creating the folder if
/// needed. [`InstanceError::AlreadyRunning`] means another LokalBot holds it:
/// [`send`] the request there and exit.
pub fn acquire_instance(root: &Path) -> Result<InstanceGuard, InstanceError> {
    std::fs::create_dir_all(root)?;
    let path = LibraryPaths::new(root).instance_lock();
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&path)?;
    match file.try_lock() {
        Ok(()) => {
            let mut file = file;
            // Diagnostics only; the lock itself is what counts.
            let _ = file.set_len(0);
            let _ = writeln!(file, "{}", std::process::id());
            Ok(InstanceGuard { _file: file, path })
        }
        Err(TryLockError::WouldBlock) => Err(InstanceError::AlreadyRunning),
        Err(TryLockError::Error(err)) => Err(InstanceError::Io(err)),
    }
}

/// Accepts requests until dropped. Commands are delivered on a background
/// thread, one connection at a time.
pub struct IpcServer {
    stop: Arc<AtomicBool>,
    endpoint: PathBuf,
    thread: Option<JoinHandle<()>>,
}

impl IpcServer {
    /// The socket path (Unix) or pipe path (Windows) this server listens on.
    pub fn endpoint(&self) -> &Path {
        &self.endpoint
    }
}

impl Drop for IpcServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Wake the blocking accept with a connection of our own.
        let woke = connect(&self.endpoint).is_ok();
        if let Some(thread) = self.thread.take()
            && woke
        {
            let _ = thread.join();
        }
    }
}

/// Listens for [`IpcCommand`]s for the library at `root`. Call after
/// [`acquire_instance`] succeeded; a leftover socket from a crashed instance
/// is replaced. `on_command` runs on the server's thread.
pub fn listen(
    root: &Path,
    on_command: impl Fn(IpcCommand) + Send + 'static,
) -> std::io::Result<IpcServer> {
    let endpoint = endpoint_path(root)?;
    let name = socket_name(&endpoint)?;
    let listener = ListenerOptions::new()
        .name(name)
        .try_overwrite(true)
        .create_sync()?;
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let thread = std::thread::Builder::new()
        .name("lokalbot-ipc".into())
        .spawn(move || serve(listener, thread_stop, on_command))?;
    Ok(IpcServer {
        stop,
        endpoint,
        thread: Some(thread),
    })
}

fn serve(
    listener: interprocess::local_socket::Listener,
    stop: Arc<AtomicBool>,
    on_command: impl Fn(IpcCommand) + Send + 'static,
) {
    // Only `Send` is required of the callback, so requests take turns.
    let on_command = Arc::new(parking_lot::Mutex::new(on_command));
    loop {
        let accepted = listener.accept();
        if stop.load(Ordering::SeqCst) {
            break;
        }
        match accepted {
            Ok(stream) => {
                // Named pipes have no I/O timeouts, so a stalled client gets
                // its own thread instead of blocking the next request.
                let on_command = on_command.clone();
                let spawned = std::thread::Builder::new()
                    .name("lokalbot-ipc-request".into())
                    .spawn(move || {
                        let deliver = |command| (on_command.lock())(command);
                        if let Err(err) = handle(stream, &deliver) {
                            log::debug!("ipc: dropped a request: {err}");
                        }
                    });
                if let Err(err) = spawned {
                    log::warn!("ipc: could not handle a request: {err}");
                }
            }
            Err(err) => {
                log::warn!("ipc: accept failed: {err}");
                std::thread::sleep(Duration::from_millis(200));
            }
        }
    }
}

/// Sets I/O timeouts where the platform supports them (Unix sockets).
fn set_timeouts(stream: &Stream) -> std::io::Result<()> {
    for result in [
        stream.set_recv_timeout(Some(IO_TIMEOUT)),
        stream.set_send_timeout(Some(IO_TIMEOUT)),
    ] {
        match result {
            Err(err) if err.kind() != std::io::ErrorKind::Unsupported => return Err(err),
            _ => {}
        }
    }
    Ok(())
}

fn handle(stream: Stream, on_command: &dyn Fn(IpcCommand)) -> std::io::Result<()> {
    set_timeouts(&stream)?;
    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    (&mut reader).take(MAX_LINE as u64).read_line(&mut line)?;
    let request = line.trim_end_matches(['\r', '\n']);
    let reply = match request
        .strip_prefix(PROTOCOL)
        .and_then(|rest| rest.strip_prefix(' '))
        .map(IpcCommand::decode)
    {
        Some(Some(command)) => {
            on_command(command);
            "ok".to_string()
        }
        Some(None) => "error unknown command".to_string(),
        None => "error unsupported protocol".to_string(),
    };
    (&stream).write_all(format!("{reply}\n").as_bytes())?;
    (&stream).flush()
}

/// Delivers `command` to the LokalBot running for the library at `root` and
/// waits (at most a few seconds) for it to acknowledge.
pub fn send(root: &Path, command: IpcCommand) -> Result<(), IpcError> {
    let endpoint = endpoint_path(root)?;
    let stream = connect(&endpoint).map_err(|err| match err.kind() {
        std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused => {
            IpcError::NotRunning
        }
        _ => IpcError::Io(err),
    })?;
    let (tx, rx) = crossbeam_channel::bounded(1);
    // The exchange runs on a helper thread so a stuck app cannot hang the
    // caller, even where the pipe has no timeouts.
    std::thread::Builder::new()
        .name("lokalbot-ipc-send".into())
        .spawn(move || {
            let _ = tx.send(exchange(&stream, &command));
        })?;
    match rx.recv_timeout(IO_TIMEOUT * 2) {
        Ok(result) => result,
        Err(_) => Err(IpcError::Io(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "LokalBot did not answer",
        ))),
    }
}

fn exchange(stream: &Stream, command: &IpcCommand) -> Result<(), IpcError> {
    set_timeouts(stream)?;
    let mut writer = stream;
    writer.write_all(format!("{PROTOCOL} {}\n", command.encode()).as_bytes())?;
    writer.flush()?;
    let mut reply = String::new();
    BufReader::new(stream)
        .take(MAX_LINE as u64)
        .read_line(&mut reply)?;
    match reply.trim_end() {
        "ok" => Ok(()),
        "" => Err(IpcError::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "LokalBot closed the connection",
        ))),
        other => Err(IpcError::Refused(
            other.strip_prefix("error ").unwrap_or(other).to_string(),
        )),
    }
}

fn connect(endpoint: &Path) -> std::io::Result<Stream> {
    let name = socket_name(endpoint)?;
    ConnectOptions::new()
        .name(name)
        .wait_mode(ConnectWaitMode::Timeout(IO_TIMEOUT))
        .connect_sync()
}

fn socket_name(endpoint: &Path) -> std::io::Result<Name<'static>> {
    Ok(endpoint
        .to_path_buf()
        .to_fs_name::<GenericFilePath>()?
        .into_owned())
}

/// Short, stable key for a library root and the current user.
pub(crate) fn endpoint_key(root: &Path) -> String {
    let resolved = std::fs::canonicalize(root)
        .or_else(|_| std::path::absolute(root))
        .unwrap_or_else(|_| root.to_path_buf());
    let mut text = resolved.to_string_lossy().into_owned();
    if cfg!(windows) {
        text = text.to_lowercase();
    }
    let user = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_default();
    let digest = Sha256::digest(format!("{text}\0{user}").as_bytes());
    hex::encode(&digest[..12])
}

/// Where the socket for `root` lives.
pub fn endpoint_path(root: &Path) -> std::io::Result<PathBuf> {
    let key = endpoint_key(root);
    #[cfg(windows)]
    {
        Ok(PathBuf::from(format!(r"\\.\pipe\lokalbot-{key}")))
    }
    #[cfg(unix)]
    {
        Ok(private_runtime_dir()?.join(format!("{key}.sock")))
    }
}

/// `$XDG_RUNTIME_DIR/lokalbot`, or `/tmp/lokalbot-<uid>` without a runtime
/// directory. Either is created 0700 and must belong to this user.
#[cfg(unix)]
pub(crate) fn private_runtime_dir() -> std::io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};

    let uid = std::fs::metadata("/proc/self")
        .map(|meta| meta.uid())
        .unwrap_or(u32::MAX);
    let dir = match std::env::var_os("XDG_RUNTIME_DIR").filter(|v| !v.is_empty()) {
        Some(runtime) => PathBuf::from(runtime).join("lokalbot"),
        None => std::env::temp_dir().join(format!("lokalbot-{uid}")),
    };
    match std::fs::DirBuilder::new().mode(0o700).create(&dir) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(err) => return Err(err),
    }
    let meta = std::fs::symlink_metadata(&dir)?;
    if !meta.is_dir() || (uid != u32::MAX && meta.uid() != uid) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            format!("{} is not a private folder of this user", dir.display()),
        ));
    }
    if meta.permissions().mode() & 0o077 != 0 {
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_round_trip() {
        let all = [
            IpcCommand::Show,
            IpcCommand::QuickRecall,
            IpcCommand::ToggleRecording,
            IpcCommand::StartDictation,
            IpcCommand::StopDictation,
            IpcCommand::ToggleDictation,
            IpcCommand::OpenMeeting("4F1A-22".into()),
            IpcCommand::InstallUpdate,
        ];
        for command in all {
            assert_eq!(IpcCommand::decode(&command.encode()), Some(command));
        }
        assert_eq!(IpcCommand::decode("open-meeting"), None);
        assert_eq!(IpcCommand::decode("show extra"), None);
        assert_eq!(IpcCommand::decode("format-disk"), None);
    }

    #[test]
    fn keys_differ_per_library() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        assert_ne!(endpoint_key(a.path()), endpoint_key(b.path()));
        assert_eq!(endpoint_key(a.path()), endpoint_key(a.path()));
        assert_eq!(endpoint_key(a.path()).len(), 24);
    }

    #[test]
    fn second_instance_is_refused_until_the_first_exits() {
        let dir = tempfile::tempdir().unwrap();
        let first = acquire_instance(dir.path()).unwrap();
        assert!(matches!(
            acquire_instance(dir.path()),
            Err(InstanceError::AlreadyRunning)
        ));
        drop(first);
        acquire_instance(dir.path()).unwrap();
    }

    #[test]
    fn commands_reach_the_running_instance() {
        let dir = tempfile::tempdir().unwrap();
        assert!(matches!(
            send(dir.path(), IpcCommand::Show),
            Err(IpcError::NotRunning)
        ));
        let _guard = acquire_instance(dir.path()).unwrap();
        let (tx, rx) = crossbeam_channel::unbounded();
        let server = listen(dir.path(), move |command| {
            let _ = tx.send(command);
        })
        .unwrap();
        send(dir.path(), IpcCommand::QuickRecall).unwrap();
        send(dir.path(), IpcCommand::OpenMeeting("abc".into())).unwrap();
        assert_eq!(
            rx.recv_timeout(IO_TIMEOUT).unwrap(),
            IpcCommand::QuickRecall
        );
        assert_eq!(
            rx.recv_timeout(IO_TIMEOUT).unwrap(),
            IpcCommand::OpenMeeting("abc".into())
        );
        let endpoint = server.endpoint().to_path_buf();
        drop(server);
        assert!(matches!(
            send(dir.path(), IpcCommand::Show),
            Err(IpcError::NotRunning)
        ));
        #[cfg(unix)]
        assert!(!endpoint.exists());
        let _ = endpoint;
    }

    #[cfg(unix)]
    #[test]
    fn a_stale_socket_is_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let endpoint = endpoint_path(dir.path()).unwrap();
        // A crashed instance leaves its socket file behind.
        drop(std::os::unix::net::UnixListener::bind(&endpoint).unwrap());
        assert!(endpoint.exists());
        assert!(matches!(
            send(dir.path(), IpcCommand::Show),
            Err(IpcError::NotRunning)
        ));
        let (tx, rx) = crossbeam_channel::unbounded();
        let _server = listen(dir.path(), move |command| {
            let _ = tx.send(command);
        })
        .unwrap();
        send(dir.path(), IpcCommand::Show).unwrap();
        assert_eq!(rx.recv_timeout(IO_TIMEOUT).unwrap(), IpcCommand::Show);
    }

    #[test]
    fn foreign_protocols_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let _server = listen(dir.path(), |_| panic!("must not run")).unwrap();
        let stream = connect(&endpoint_path(dir.path()).unwrap()).unwrap();
        (&stream).write_all(b"HELLO show\n").unwrap();
        let mut reply = String::new();
        BufReader::new(&stream).read_line(&mut reply).unwrap();
        assert_eq!(reply, "error unsupported protocol\n");
    }
}
