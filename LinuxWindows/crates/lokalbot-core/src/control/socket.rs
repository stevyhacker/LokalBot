use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use sha2::{Digest as _, Sha256};

use super::protocol::{MAXIMUM_MESSAGE_BYTES, Request, Response};
use crate::paths::LibraryPaths;

pub fn endpoint_key(root: &Path) -> String {
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

#[cfg(unix)]
pub fn private_runtime_dir() -> std::io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _, PermissionsExt as _};

    let uid = current_uid();
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

#[cfg(unix)]
pub fn current_uid() -> u32 {
    use std::os::unix::fs::MetadataExt as _;
    std::fs::metadata("/proc/self")
        .map(|meta| meta.uid())
        .unwrap_or(u32::MAX)
}

pub fn endpoint(root: &Path) -> std::io::Result<PathBuf> {
    let key = endpoint_key(root);
    #[cfg(windows)]
    {
        Ok(PathBuf::from(format!(r"\\.\pipe\lokalbot-control-{key}")))
    }
    #[cfg(unix)]
    {
        Ok(private_runtime_dir()?.join(format!("{key}-control.sock")))
    }
}

pub fn is_app_running(paths: &LibraryPaths) -> bool {
    let Ok(file) = std::fs::OpenOptions::new()
        .read(true)
        .open(paths.instance_lock())
    else {
        return false;
    };
    match file.try_lock() {
        Ok(()) => {
            let _ = file.unlock();
            false
        }
        Err(std::fs::TryLockError::WouldBlock) => true,
        Err(std::fs::TryLockError::Error(_)) => false,
    }
}

#[cfg(unix)]
fn connect(path: &Path, timeout: Duration) -> std::io::Result<std::os::unix::net::UnixStream> {
    use std::os::unix::fs::{FileTypeExt as _, MetadataExt as _};
    let meta = std::fs::symlink_metadata(path)?;
    let uid = current_uid();
    if !meta.file_type().is_socket() || (uid != u32::MAX && meta.uid() != uid) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "the control socket does not belong to this user",
        ));
    }
    let stream = std::os::unix::net::UnixStream::connect(path)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    Ok(stream)
}

#[cfg(windows)]
fn connect(path: &Path, _: Duration) -> std::io::Result<std::fs::File> {
    use std::os::windows::fs::OpenOptionsExt as _;
    use std::os::windows::io::AsRawHandle as _;
    use windows_sys::Win32::Storage::FileSystem::{SECURITY_IDENTIFICATION, SECURITY_SQOS_PRESENT};
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .security_qos_flags(SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION)
        .open(path)?;
    if !windows_owner::server_is_this_user(file.as_raw_handle()) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "the control pipe does not belong to this user",
        ));
    }
    Ok(file)
}

#[cfg(windows)]
mod windows_owner {
    use std::ffi::c_void;

    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::{
        EqualSid, GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser,
    };
    use windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId;
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    unsafe fn token_user(process: HANDLE) -> Option<Vec<u8>> {
        unsafe {
            let mut token: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(process, TOKEN_QUERY, &mut token) == 0 {
                return None;
            }
            let mut length = 0u32;
            GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut length);
            let mut buffer = vec![0u8; length as usize];
            let ok = GetTokenInformation(
                token,
                TokenUser,
                buffer.as_mut_ptr() as *mut c_void,
                length,
                &mut length,
            );
            CloseHandle(token);
            (ok != 0).then_some(buffer)
        }
    }

    pub(super) fn current_user_sid() -> Option<String> {
        use windows_sys::Win32::Foundation::LocalFree;
        use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
        unsafe {
            let user = token_user(GetCurrentProcess())?;
            let user = user.as_ptr() as *const TOKEN_USER;
            let mut text: *mut u16 = std::ptr::null_mut();
            if ConvertSidToStringSidW((*user).User.Sid, &mut text) == 0 || text.is_null() {
                return None;
            }
            let mut length = 0usize;
            while *text.add(length) != 0 {
                length += 1;
            }
            let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
            LocalFree(text as *mut c_void);
            Some(sid)
        }
    }

    pub(super) fn server_is_this_user(pipe: *mut c_void) -> bool {
        unsafe {
            let mut server = 0u32;
            if GetNamedPipeServerProcessId(pipe as HANDLE, &mut server) == 0 {
                return false;
            }
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, server);
            if process.is_null() {
                return false;
            }
            let theirs = token_user(process);
            CloseHandle(process);
            let ours = token_user(GetCurrentProcess());
            match (theirs, ours) {
                (Some(theirs), Some(ours)) => {
                    let theirs = theirs.as_ptr() as *const TOKEN_USER;
                    let ours = ours.as_ptr() as *const TOKEN_USER;
                    EqualSid((*theirs).User.Sid, (*ours).User.Sid) != 0
                }
                _ => false,
            }
        }
    }
}

#[cfg(windows)]
pub fn current_user_sid() -> Option<String> {
    windows_owner::current_user_sid()
}

pub fn exchange(
    endpoint: &Path,
    request: &Request,
    timeout: Duration,
) -> std::io::Result<Response> {
    let mut stream = connect(endpoint, timeout)?;
    let mut line = serde_json::to_vec(request).map_err(std::io::Error::other)?;
    line.push(b'\n');
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("lokalbot-control-client".into())
        .spawn(move || {
            let result = (|| -> std::io::Result<Vec<u8>> {
                stream.write_all(&line)?;
                stream.flush()?;
                read_line(&mut stream)
            })();
            let _ = tx.send(result);
        })?;
    let reply = rx
        .recv_timeout(timeout + Duration::from_secs(1))
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "LokalBot did not answer")
        })??;
    serde_json::from_slice(&reply).map_err(std::io::Error::other)
}

pub fn read_line(reader: &mut impl std::io::Read) -> std::io::Result<Vec<u8>> {
    let mut record = Vec::new();
    let mut buffer = [0u8; 16 * 1024];
    loop {
        let count = match reader.read(&mut buffer) {
            Ok(count) => count,
            Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        };
        if count == 0 {
            return Ok(record);
        }
        let chunk = &buffer[..count];
        if let Some(newline) = chunk.iter().position(|byte| *byte == b'\n') {
            record.extend_from_slice(&chunk[..newline]);
            return Ok(record);
        }
        record.extend_from_slice(chunk);
        if record.len() > MAXIMUM_MESSAGE_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "the message is too long",
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_differ_per_library() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        assert_ne!(endpoint_key(a.path()), endpoint_key(b.path()));
        assert_eq!(endpoint_key(a.path()).len(), 24);
    }

    #[test]
    fn reads_one_line_and_refuses_an_endless_one() {
        let mut one = &b"{\"a\":1}\nrest"[..];
        assert_eq!(read_line(&mut one).unwrap(), b"{\"a\":1}");
        let long = vec![b'x'; MAXIMUM_MESSAGE_BYTES + 32 * 1024];
        assert!(read_line(&mut &long[..]).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn a_plain_file_at_the_socket_path_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.sock");
        std::fs::write(&path, b"").unwrap();
        let error = connect(&path, Duration::from_secs(1)).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn the_instance_lock_means_the_app_is_running() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path());
        assert!(!is_app_running(&paths));
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(paths.instance_lock())
            .unwrap();
        assert!(!is_app_running(&paths));
        lock.lock().unwrap();
        assert!(is_app_running(&paths));
        lock.unlock().unwrap();
        assert!(!is_app_running(&paths));
    }
}
