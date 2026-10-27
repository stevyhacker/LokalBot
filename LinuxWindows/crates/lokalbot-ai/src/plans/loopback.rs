//! A one-shot HTTP listener on 127.0.0.1 that receives an OAuth redirect
//! (`LoopbackRedirectListener.swift`). It binds to the loopback address only,
//! answers the first request for its path with a short page, and hands the
//! query to the waiting sign-in. Other paths (a browser's favicon request)
//! get a 404 and are ignored.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;

use super::PlanError;

pub(crate) struct LoopbackListener {
    listener: TcpListener,
    port: u16,
    path: String,
}

impl LoopbackListener {
    /// Listens on `preferred_port`, or on any free port when it is taken.
    pub fn start(preferred_port: u16, path: &str) -> Result<Self> {
        let bind = |port: u16| TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port));
        let listener = match bind(preferred_port) {
            Ok(listener) => listener,
            Err(_) => bind(0).map_err(|err| {
                PlanError::SignInFailed(format!(
                    "LokalBot couldn't start its sign-in listener on this PC: {err}"
                ))
            })?,
        };
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        Ok(Self {
            listener,
            port,
            path: path.to_string(),
        })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// The redirect's query items. Fails on timeout or when `cancel` is set.
    pub fn wait_for_callback(
        &self,
        timeout: Duration,
        cancel: &AtomicBool,
    ) -> Result<HashMap<String, String>> {
        let deadline = Instant::now() + timeout;
        loop {
            if cancel.load(Ordering::Relaxed) {
                return Err(PlanError::SignInCancelled.into());
            }
            if Instant::now() >= deadline {
                return Err(PlanError::SignInFailed(
                    "Sign-in timed out. Start it again when you're ready.".into(),
                )
                .into());
            }
            match self.listener.accept() {
                Ok((stream, _)) => {
                    if let Some(query) = self.handle(stream) {
                        return Ok(query);
                    }
                }
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(50));
                }
                Err(err) => {
                    return Err(PlanError::SignInFailed(format!(
                        "LokalBot's sign-in listener stopped: {err}"
                    ))
                    .into());
                }
            }
        }
    }

    /// Answers one connection; the query when it was the redirect.
    fn handle(&self, mut stream: TcpStream) -> Option<HashMap<String, String>> {
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 4096];
        let target = loop {
            if let Some(target) = request_target(&buffer) {
                break target;
            }
            match stream.read(&mut chunk) {
                Ok(0) | Err(_) => return None,
                Ok(read) => buffer.extend_from_slice(&chunk[..read]),
            }
            if buffer.len() > 65_536 {
                return None;
            }
        };
        let path = target.split('?').next().unwrap_or_default();
        if path != self.path {
            respond(&mut stream, "404 Not Found", "Not found.");
            return None;
        }
        let query = query_of(&target);
        respond(
            &mut stream,
            "200 OK",
            if query.contains_key("error") {
                "Sign-in was cancelled. You can close this tab and return to LokalBot."
            } else {
                "You can close this tab and return to LokalBot."
            },
        );
        Some(query)
    }
}

/// The request-target of a complete `GET` request head; empty for another
/// method; `None` until the head is complete.
pub(crate) fn request_target(buffer: &[u8]) -> Option<String> {
    let end = buffer.windows(4).position(|w| w == b"\r\n\r\n")?;
    let head = String::from_utf8_lossy(&buffer[..end]);
    let line = head.split("\r\n").next().unwrap_or_default();
    let parts: Vec<&str> = line.split(' ').collect();
    if parts.len() != 3 || parts[0] != "GET" {
        return Some(String::new());
    }
    Some(parts[1].to_string())
}

/// Query items of a request-target, percent-decoded; the first value of a
/// repeated name wins.
pub(crate) fn query_of(target: &str) -> HashMap<String, String> {
    let mut query = HashMap::new();
    let Some((_, raw)) = target.split_once('?') else {
        return query;
    };
    for pair in raw.split('&').filter(|p| !p.is_empty()) {
        let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
        query
            .entry(percent_decode(name))
            .or_insert_with(|| percent_decode(value));
    }
    query
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' => out.push(b' '),
            b'%' if index + 2 < bytes.len() => {
                match u8::from_str_radix(
                    std::str::from_utf8(&bytes[index + 1..index + 3]).unwrap_or("zz"),
                    16,
                ) {
                    Ok(byte) => {
                        out.push(byte);
                        index += 2;
                    }
                    Err(_) => out.push(b'%'),
                }
            }
            byte => out.push(byte),
        }
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let page = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>LokalBot</title>\
<style>body{{font:16px system-ui,sans-serif;margin:15vh auto;max-width:28em;padding:0 1em;color:#1d1d1f}}\
@media(prefers-color-scheme:dark){{body{{background:#1d1d1f;color:#f5f5f7}}}}</style>\
</head><body><p>{body}</p></body></html>"
    );
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        page.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(page.as_bytes());
    let _ = stream.flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn get(port: u16, target: &str) -> String {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        write!(stream, "GET {target} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").unwrap();
        let mut reply = String::new();
        stream.read_to_string(&mut reply).unwrap();
        reply
    }

    #[test]
    fn answers_only_the_redirect_path_and_decodes_its_query() {
        let listener = LoopbackListener::start(0, "/auth/callback").unwrap();
        let port = listener.port();
        let client = std::thread::spawn(move || {
            let favicon = get(port, "/favicon.ico");
            let callback = get(port, "/auth/callback?code=a%2Bb&state=s+1&code=ignored");
            (favicon, callback)
        });
        let cancel = AtomicBool::new(false);
        let query = listener
            .wait_for_callback(Duration::from_secs(10), &cancel)
            .unwrap();
        let (favicon, callback) = client.join().unwrap();
        assert!(favicon.starts_with("HTTP/1.1 404"));
        assert!(callback.starts_with("HTTP/1.1 200"));
        assert!(callback.contains("return to LokalBot"));
        assert_eq!(query["code"], "a+b");
        assert_eq!(query["state"], "s 1");
        assert_eq!(
            request_target(b"POST /auth/callback HTTP/1.1\r\n\r\n"),
            Some(String::new())
        );
        assert_eq!(request_target(b"GET /x HTTP/1.1\r\n"), None);
    }

    #[test]
    fn a_taken_port_falls_back_and_cancel_stops_waiting() {
        let first = LoopbackListener::start(0, "/cb").unwrap();
        let second = LoopbackListener::start(first.port(), "/cb").unwrap();
        assert_ne!(first.port(), second.port());
        let cancel = AtomicBool::new(true);
        let err = second
            .wait_for_callback(Duration::from_secs(10), &cancel)
            .unwrap_err();
        assert!(matches!(
            err.downcast_ref::<PlanError>(),
            Some(PlanError::SignInCancelled)
        ));
        let err = first
            .wait_for_callback(Duration::from_millis(100), &AtomicBool::new(false))
            .unwrap_err();
        assert!(err.to_string().contains("timed out"));
    }
}
