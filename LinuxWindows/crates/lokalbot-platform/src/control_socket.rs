//! The app end of the CLI control socket (`AppControlServer.swift`). It runs
//! only while the person allows external agents to change settings and accepts
//! connections from this user only: a Unix socket (mode 0600, in a 0700 folder,
//! with the peer's user id checked) or a named pipe whose access list holds only
//! this user and which refuses remote clients.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

use interprocess::ConnectWaitMode;
use interprocess::local_socket::prelude::*;
use interprocess::local_socket::traits::Stream as StreamTrait;
use interprocess::local_socket::{ConnectOptions, GenericFilePath, ListenerOptions, Name, Stream};
use lokalbot_core::control::protocol::{ControlError, Request, Response};
use lokalbot_core::control::setup::describe_process;
use lokalbot_core::control::socket as core_socket;

const IO_TIMEOUT: Duration = Duration::from_secs(10);

/// Answers a request. The handler may keep it and answer later, on any thread.
pub type Reply = Box<dyn FnOnce(Response) + Send>;

/// Accepts requests until dropped; dropping removes the socket.
pub struct ControlServer {
    stop: Arc<AtomicBool>,
    endpoint: PathBuf,
    thread: Option<JoinHandle<()>>,
}

impl ControlServer {
    pub fn endpoint(&self) -> &Path {
        &self.endpoint
    }
}

impl Drop for ControlServer {
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

/// Listens for requests for the library at `root`. Call while holding the
/// library's instance lock; a socket left by a crashed run is replaced.
/// `on_request` runs on the connection's own thread with the caller's name.
pub fn listen_control(
    root: &Path,
    on_request: impl Fn(Request, String, Reply) + Send + Sync + 'static,
) -> std::io::Result<ControlServer> {
    let endpoint = core_socket::endpoint(root)?;
    let listener = private_options(socket_name(&endpoint)?)?.create_sync()?;
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = stop.clone();
    let on_request = Arc::new(on_request);
    let thread = std::thread::Builder::new()
        .name("lokalbot-control".into())
        .spawn(move || {
            loop {
                let accepted = listener.accept();
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                match accepted {
                    Ok(stream) => {
                        let on_request = on_request.clone();
                        let spawned = std::thread::Builder::new()
                            .name("lokalbot-control-request".into())
                            .spawn(move || serve(stream, on_request.as_ref()));
                        if let Err(err) = spawned {
                            log::warn!("control socket: could not handle a request: {err}");
                        }
                    }
                    Err(err) => {
                        log::warn!("control socket: accept failed: {err}");
                        std::thread::sleep(Duration::from_millis(200));
                    }
                }
            }
        })?;
    Ok(ControlServer {
        stop,
        endpoint,
        thread: Some(thread),
    })
}

#[cfg(unix)]
fn private_options(name: Name<'static>) -> std::io::Result<ListenerOptions<'static>> {
    use interprocess::os::unix::local_socket::ListenerOptionsExt as _;
    Ok(ListenerOptions::new()
        .name(name)
        .try_overwrite(true)
        .mode(0o600))
}

#[cfg(windows)]
fn private_options(name: Name<'static>) -> std::io::Result<ListenerOptions<'static>> {
    use interprocess::os::windows::local_socket::ListenerOptionsExt as _;
    use interprocess::os::windows::security_descriptor::SecurityDescriptor;
    let Some(sid) = core_socket::current_user_sid() else {
        return Err(std::io::Error::other("could not find this user's identity"));
    };
    // A protected list with one entry: no inherited access, and nobody but
    // this user. Named pipes refuse remote clients unless told otherwise.
    let sddl = widestring::U16CString::from_str(format!("D:P(A;;GA;;;{sid})"))
        .map_err(std::io::Error::other)?;
    let descriptor = SecurityDescriptor::deserialize(&sddl)?;
    Ok(ListenerOptions::new()
        .name(name)
        .security_descriptor(descriptor))
}

fn socket_name(endpoint: &Path) -> std::io::Result<Name<'static>> {
    Ok(endpoint
        .to_path_buf()
        .to_fs_name::<GenericFilePath>()?
        .into_owned())
}

fn connect(endpoint: &Path) -> std::io::Result<Stream> {
    ConnectOptions::new()
        .name(socket_name(endpoint)?)
        .wait_mode(ConnectWaitMode::Timeout(Duration::from_secs(2)))
        .connect_sync()
}

/// The peer's name for the audit log, or `None` when it runs as another user.
fn caller(stream: &Stream) -> Option<String> {
    let credentials = stream.peer_creds().ok();
    #[cfg(unix)]
    {
        let uid = core_socket::current_uid();
        let peer = credentials.as_ref().and_then(|c| c.euid());
        if peer != Some(uid) {
            return None;
        }
    }
    let described = credentials
        .and_then(|c| c.pid())
        .and_then(|pid| u32::try_from(pid).ok())
        .and_then(describe_process);
    Some(described.unwrap_or_else(|| "lokalbot-cli".to_string()))
}

fn serve(stream: Stream, on_request: &(dyn Fn(Request, String, Reply) + Send + Sync)) {
    let Some(caller) = caller(&stream) else {
        log::warn!("control socket: refused a connection from another user");
        return;
    };
    for result in [
        stream.set_recv_timeout(Some(IO_TIMEOUT)),
        stream.set_send_timeout(Some(IO_TIMEOUT)),
    ] {
        match result {
            Err(err) if err.kind() != std::io::ErrorKind::Unsupported => {
                log::debug!("control socket: {err}");
                return;
            }
            _ => {}
        }
    }
    let Ok(line) = core_socket::read_line(&mut &stream) else {
        return;
    };
    let (tx, rx) = crossbeam_channel::bounded(1);
    let reply: Reply = Box::new(move |response| {
        let _ = tx.send(response);
    });
    match serde_json::from_slice::<Request>(&line) {
        Ok(request) => on_request(request, caller, reply),
        Err(_) => reply(Response::failure(ControlError::invalid_request(
            "The request is not a LokalBot control request.",
        ))),
    }
    let Ok(response) = rx.recv() else {
        return;
    };
    let Ok(mut bytes) = serde_json::to_vec(&response) else {
        return;
    };
    bytes.push(b'\n');
    let mut writer = &stream;
    let _ = writer.write_all(&bytes);
    let _ = writer.flush();
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::control::protocol::{METHOD_HELLO, Response};
    use serde_json::json;

    fn hello() -> Request {
        Request::new(METHOD_HELLO, None)
    }

    #[test]
    fn answers_a_client_and_names_it() {
        let dir = tempfile::tempdir().unwrap();
        let server = listen_control(dir.path(), |request, caller, reply| {
            assert_eq!(request.method, "hello");
            reply(Response::success(json!({"caller": caller})));
        })
        .unwrap();
        let response =
            core_socket::exchange(server.endpoint(), &hello(), Duration::from_secs(5)).unwrap();
        let caller = response.result.unwrap()["caller"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(!caller.is_empty());
    }

    #[test]
    fn a_reply_can_come_later_from_another_thread() {
        let dir = tempfile::tempdir().unwrap();
        let server = listen_control(dir.path(), |_, _, reply| {
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(100));
                reply(Response::success(json!(true)));
            });
        })
        .unwrap();
        let response =
            core_socket::exchange(server.endpoint(), &hello(), Duration::from_secs(5)).unwrap();
        assert_eq!(response.result, Some(json!(true)));
    }

    #[test]
    fn garbage_gets_invalid_request() {
        let dir = tempfile::tempdir().unwrap();
        let server = listen_control(dir.path(), |_, _, _| panic!("must not run")).unwrap();
        let stream = connect(server.endpoint()).unwrap();
        let mut writer = &stream;
        writer.write_all(b"not json\n").unwrap();
        let line = core_socket::read_line(&mut &stream).unwrap();
        let response: Response = serde_json::from_slice(&line).unwrap();
        assert_eq!(response.error.unwrap().code, "invalid_request");
    }

    #[test]
    fn stopping_removes_the_socket_and_clients_see_it_is_gone() {
        let dir = tempfile::tempdir().unwrap();
        let server = listen_control(dir.path(), |_, _, reply| {
            reply(Response::success(json!(true)));
        })
        .unwrap();
        let endpoint = server.endpoint().to_path_buf();
        drop(server);
        #[cfg(unix)]
        assert!(!endpoint.exists());
        assert!(core_socket::exchange(&endpoint, &hello(), Duration::from_secs(1)).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn the_socket_is_private_to_this_user() {
        use std::os::unix::fs::PermissionsExt as _;
        let dir = tempfile::tempdir().unwrap();
        let server = listen_control(dir.path(), |_, _, _| {}).unwrap();
        let mode = std::fs::metadata(server.endpoint())
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o077, 0, "{mode:o}");
        let folder = std::fs::metadata(server.endpoint().parent().unwrap())
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(folder & 0o077, 0, "{folder:o}");
    }

    #[cfg(unix)]
    #[test]
    fn a_stale_socket_is_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let endpoint = core_socket::endpoint(dir.path()).unwrap();
        drop(std::os::unix::net::UnixListener::bind(&endpoint).unwrap());
        assert!(endpoint.exists());
        let server = listen_control(dir.path(), |_, _, reply| {
            reply(Response::success(json!(1)));
        })
        .unwrap();
        let response =
            core_socket::exchange(server.endpoint(), &hello(), Duration::from_secs(5)).unwrap();
        assert_eq!(response.result, Some(json!(1)));
    }
}
