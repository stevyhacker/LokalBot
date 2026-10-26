//! Agent Mode on the ChatGPT plan (`ChatGPTPlanRelay.swift`). pi speaks the
//! Responses API to this relay on 127.0.0.1 with a key issued for one task.
//! The relay checks that key, shapes the body to the plan route's rules, adds
//! the current Sign in with ChatGPT access token ([`Account`] refreshes it),
//! and streams OpenAI's reply back unchanged. Only `POST /v1/responses` is
//! relayed, so pi and the commands it runs never hold the plan's tokens.
//!
//! Blocking sockets, one thread per connection. A hang-up or [`Relay::stop`]
//! closes pi's connection at once. ureq's read of OpenAI's stream can't be
//! interrupted from another thread, so that upstream connection is dropped
//! when its next event arrives.

use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddrV4, TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use parking_lot::Mutex;
use serde_json::{Value, json};

use super::{Account, PlanError, REQUEST_TIMEOUT, error_object, plan_error_for, random_token};
use crate::http;

pub const PATH: &str = "/v1/responses";
/// Room for a full agent context with long tool results.
pub const MAXIMUM_REQUEST_BYTES: usize = 32 << 20;
pub const MAXIMUM_HEAD_BYTES: usize = 64 << 10;
/// An error reply is short JSON; anything longer is cut.
pub const MAXIMUM_ERROR_BYTES: usize = 1 << 20;
/// pi writes a request at once and reads its reply as it streams; a
/// connection stalled either way is dropped.
const STALL_TIMEOUT: Duration = Duration::from_secs(60);
/// How often an open request looks for pi hanging up.
const HANG_UP_POLL: Duration = Duration::from_millis(250);

/// The plan route's request rules (developers.openai.com/siwc/token-sharing-open-source,
/// "Preview limitations", 2026-10): fields it rejects, server-side
/// conversation state it can't use over HTTP, and pi-ai fields that have no
/// meaning on plan usage.
pub const UNSUPPORTED_FIELDS: [&str; 18] = [
    "background",
    "conversation",
    "max_output_tokens",
    "max_tool_calls",
    "metadata",
    "moderation",
    "multi_agent",
    "previous_response_id",
    "prompt",
    "prompt_cache_options",
    "prompt_cache_retention",
    "safety_identifier",
    "service_tier",
    "temperature",
    "top_logprobs",
    "top_p",
    "truncation",
    "user",
];

/// Where the relay's access tokens come from.
pub trait TokenSource: Send + Sync {
    /// The current access token, or a fresh one after `rejected` was refused.
    fn token(&self, rejected: Option<&str>) -> Result<String>;
}

impl TokenSource for Account {
    fn token(&self, rejected: Option<&str>) -> Result<String> {
        match rejected {
            Some(rejected) => self.access_token_after_rejection(rejected),
            None => self.access_token(),
        }
    }
}

/// One task's relay. Dropping it stops it.
pub struct Relay {
    port: u16,
    shared: Arc<Shared>,
}

struct Shared {
    /// The bearer key pi presents. Random per relay and never stored.
    key: String,
    upstream: String,
    agent: ureq::Agent,
    tokens: Arc<dyn TokenSource>,
    stopped: AtomicBool,
    next_id: AtomicU64,
    open: Mutex<HashMap<u64, Exchange>>,
}

/// One connection from pi, as [`Relay::stop`] needs it.
struct Exchange {
    stream: TcpStream,
    cancelled: Arc<AtomicBool>,
}

impl Relay {
    /// Listens on a free loopback port for `account`'s plan.
    pub fn start(account: Arc<Account>) -> Result<Self> {
        let upstream = format!("{}/responses", account.endpoints().resource);
        Self::start_with(account, upstream)
    }

    /// `upstream` is the Responses URL requests go to.
    pub fn start_with(tokens: Arc<dyn TokenSource>, upstream: String) -> Result<Self> {
        let couldnt_listen = |err: std::io::Error| {
            anyhow::anyhow!(
                "LokalBot couldn't open its ChatGPT plan connection for Agent Mode: {err}"
            )
        };
        let listener =
            TcpListener::bind(SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0)).map_err(couldnt_listen)?;
        let port = listener.local_addr().map_err(couldnt_listen)?.port();
        let shared = Arc::new(Shared {
            key: random_token(32),
            agent: http::agent(&upstream, REQUEST_TIMEOUT),
            upstream,
            tokens,
            stopped: AtomicBool::new(false),
            next_id: AtomicU64::new(0),
            open: Mutex::new(HashMap::new()),
        });
        let accepting = shared.clone();
        std::thread::Builder::new()
            .name("lokalbot-chatgpt-relay".into())
            .spawn(move || accepting.accept(listener))
            .map_err(couldnt_listen)?;
        Ok(Self { port, shared })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// The bearer key pi must present.
    pub fn key(&self) -> &str {
        &self.shared.key
    }

    /// The base URL pi's provider uses (`…/v1`).
    pub fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}/v1", self.port)
    }

    /// Stops listening and ends every open request.
    pub fn stop(&self) {
        let open: Vec<Exchange> = {
            let mut open = self.shared.open.lock();
            if self.shared.stopped.swap(true, Ordering::SeqCst) {
                return;
            }
            open.drain().map(|(_, exchange)| exchange).collect()
        };
        // Wakes the accept loop, which then sees `stopped` and closes.
        let _ = TcpStream::connect_timeout(
            &SocketAddrV4::new(Ipv4Addr::LOCALHOST, self.port).into(),
            Duration::from_secs(1),
        );
        for exchange in open {
            exchange.cancelled.store(true, Ordering::SeqCst);
            let _ = exchange.stream.shutdown(Shutdown::Both);
        }
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.stop();
    }
}

impl std::fmt::Debug for Relay {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Relay").field("port", &self.port).finish()
    }
}

impl Shared {
    fn accept(self: Arc<Self>, listener: TcpListener) {
        for stream in listener.incoming() {
            if self.stopped.load(Ordering::SeqCst) {
                break;
            }
            let Ok(stream) = stream else {
                // Out of descriptors, say; don't spin.
                std::thread::sleep(Duration::from_millis(50));
                continue;
            };
            let shared = self.clone();
            let spawned = std::thread::Builder::new()
                .name("lokalbot-chatgpt-relay-request".into())
                .spawn(move || shared.serve(stream));
            if let Err(err) = spawned {
                log::warn!("chatgpt plan relay could not start a request thread: {err}");
            }
        }
    }

    fn serve(&self, mut stream: TcpStream) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let cancelled = Arc::new(AtomicBool::new(false));
        {
            let mut open = self.open.lock();
            if self.stopped.load(Ordering::SeqCst) {
                return;
            }
            let Ok(handle) = stream.try_clone() else {
                return;
            };
            open.insert(
                id,
                Exchange {
                    stream: handle,
                    cancelled: cancelled.clone(),
                },
            );
        }
        let _ = stream.set_nodelay(true);
        self.exchange(&mut stream, &cancelled);
        self.open.lock().remove(&id);
        cancelled.store(true, Ordering::SeqCst);
        let _ = stream.shutdown(Shutdown::Both);
    }

    fn exchange(&self, stream: &mut TcpStream, cancelled: &Arc<AtomicBool>) {
        let _ = stream.set_read_timeout(Some(STALL_TIMEOUT));
        let _ = stream.set_write_timeout(Some(STALL_TIMEOUT));
        let mut buffer = Vec::new();
        let mut chunk = vec![0u8; 64 * 1024];
        let body = loop {
            match read_request(&buffer, &self.key) {
                Request::Complete(body) => break body.to_vec(),
                Request::Rejected { status, message } => {
                    return reply(stream, status, &message, Some(false));
                }
                Request::Incomplete => {}
            }
            match stream.read(&mut chunk) {
                Ok(0) | Err(_) => return,
                Ok(read) => buffer.extend_from_slice(&chunk[..read]),
            }
        };
        drop(buffer);
        watch_for_hang_up(stream, cancelled.clone());
        self.forward(&body, stream, cancelled);
    }

    fn forward(&self, body: &[u8], stream: &mut TcpStream, cancelled: &AtomicBool) {
        let started = Instant::now();
        let Some(prepared) = upstream_body(body) else {
            return reply(
                stream,
                400,
                "The Agent request wasn't valid Responses JSON.",
                Some(false),
            );
        };
        let mut rejected: Option<String> = None;
        for attempt in 0..2 {
            let token = match self.tokens.token(rejected.as_deref()) {
                Ok(token) => token,
                Err(err) => {
                    if cancelled.load(Ordering::SeqCst) {
                        return;
                    }
                    let plan_error = err.downcast_ref::<PlanError>().is_some();
                    log::info!("chatgpt plan relay token unavailable plan_error={plan_error}");
                    return reply(
                        stream,
                        if plan_error { 401 } else { 502 },
                        &err.to_string(),
                        plan_error.then_some(false),
                    );
                }
            };
            if cancelled.load(Ordering::SeqCst) {
                return;
            }
            let sent = self
                .agent
                .post(&self.upstream)
                .header("Content-Type", "application/json")
                .header("Accept", "text/event-stream")
                .header("Authorization", format!("Bearer {token}"))
                .send(&prepared[..]);
            let response = match sent {
                Ok(response) => response,
                Err(err) => {
                    if cancelled.load(Ordering::SeqCst) {
                        return;
                    }
                    log::warn!(
                        "chatgpt plan relay unreachable host={} error={err}",
                        http::host_label(&self.upstream)
                    );
                    return reply(
                        stream,
                        502,
                        "LokalBot couldn't reach OpenAI for your ChatGPT plan.",
                        None,
                    );
                }
            };
            if cancelled.load(Ordering::SeqCst) {
                return;
            }
            let status = response.status().as_u16();
            // A token can be revoked or rotated early; refresh it once.
            if status == 401 && attempt == 0 {
                rejected = Some(token);
                continue;
            }
            if (200..300).contains(&status) {
                relay_stream(response, stream, cancelled, started);
            } else {
                relay_error(response, stream);
            }
            return;
        }
    }
}

/// pi closes its socket to abort a request. Notice that even while the model
/// is still thinking and nothing is being written. The socket's short read
/// timeout lets this thread end with the request on every platform.
fn watch_for_hang_up(stream: &TcpStream, cancelled: Arc<AtomicBool>) {
    let Ok(mut watched) = stream.try_clone() else {
        return;
    };
    if watched.set_read_timeout(Some(HANG_UP_POLL)).is_err() {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("lokalbot-chatgpt-relay-watch".into())
        .spawn(move || {
            let mut byte = [0u8; 1];
            while !cancelled.load(Ordering::SeqCst) {
                match watched.read(&mut byte) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(err)
                        if matches!(
                            err.kind(),
                            ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
                        ) => {}
                    Err(_) => break,
                }
            }
            if !cancelled.swap(true, Ordering::SeqCst) {
                let _ = watched.shutdown(Shutdown::Both);
            }
        });
    if let Err(err) = spawned {
        log::warn!("chatgpt plan relay could not watch for hang-ups: {err}");
    }
}

fn header(response: &ureq::http::Response<ureq::Body>, name: &str) -> Option<String> {
    response
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string)
}

fn relay_stream(
    response: ureq::http::Response<ureq::Body>,
    stream: &mut TcpStream,
    cancelled: &AtomicBool,
    started: Instant,
) {
    let status = response.status().as_u16();
    let content_type =
        header(&response, "content-type").unwrap_or_else(|| "text/event-stream".into());
    let head = format!(
        "HTTP/1.1 {status} OK\r\nContent-Type: {content_type}\r\nCache-Control: no-store\r\n\
         Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    );
    let mut reader = response.into_body().into_reader();
    let mut chunk = vec![0u8; 16 * 1024];
    let mut bytes = 0usize;
    let relayed = (|| -> std::io::Result<()> {
        stream.write_all(head.as_bytes())?;
        loop {
            if cancelled.load(Ordering::SeqCst) {
                return Err(ErrorKind::ConnectionAborted.into());
            }
            // Returns as soon as OpenAI sends anything, so events pass at once.
            let read = reader.read(&mut chunk)?;
            if read == 0 {
                break;
            }
            if cancelled.load(Ordering::SeqCst) {
                return Err(ErrorKind::ConnectionAborted.into());
            }
            bytes += read;
            let mut framed = format!("{read:x}\r\n").into_bytes();
            framed.extend_from_slice(&chunk[..read]);
            framed.extend_from_slice(b"\r\n");
            stream.write_all(&framed)?;
        }
        stream.write_all(b"0\r\n\r\n")?;
        stream.flush()
    })();
    match relayed {
        Ok(()) => log::info!(
            "chatgpt plan relay status={status} bytes={bytes} seconds={:.1}",
            started.elapsed().as_secs_f64()
        ),
        // pi hung up, or OpenAI's stream broke; pi sees the cut stream.
        Err(_) => log::info!(
            "chatgpt plan relay stream ended early bytes={bytes} cancelled={}",
            cancelled.load(Ordering::SeqCst)
        ),
    }
}

fn relay_error(response: ureq::http::Response<ureq::Body>, stream: &mut TcpStream) {
    let status = response.status().as_u16();
    let mut headers = vec![(
        "Content-Type",
        header(&response, "content-type").unwrap_or_else(|| "application/json".into()),
    )];
    for name in ["Retry-After", "Retry-After-Ms"] {
        if let Some(value) = header(&response, name) {
            headers.push((name, value));
        }
    }
    let mut body = Vec::new();
    let _ = response
        .into_body()
        .into_reader()
        .take(MAXIMUM_ERROR_BYTES as u64)
        .read_to_end(&mut body);
    let (code, message, param) = error_object(&body);
    log::info!(
        "chatgpt plan relay status={status} code={}",
        code.as_deref().unwrap_or("-")
    );
    if let Some(retry) = should_retry(code.as_deref(), message.as_deref(), param.as_deref()) {
        headers.push(("X-Should-Retry", retry.to_string()));
    }
    send(stream, status, headers, &body);
}

/// An error the relay itself answers, shaped like OpenAI's so pi shows the
/// message. `retry` `None` keeps pi's own retry rules for the status.
fn reply(stream: &mut TcpStream, status: u16, message: &str, retry: Option<bool>) {
    let body = json!({"error": {"message": message, "type": "lokalbot_chatgpt_plan_relay"}});
    let mut headers = vec![("Content-Type", "application/json".to_string())];
    if let Some(retry) = retry {
        headers.push(("X-Should-Retry", retry.to_string()));
    }
    send(stream, status, headers, body.to_string().as_bytes());
}

fn send(stream: &mut TcpStream, status: u16, mut headers: Vec<(&str, String)>, body: &[u8]) {
    headers.sort();
    let mut head = format!(
        "HTTP/1.1 {status} {}\r\n",
        if status < 400 { "OK" } else { "Error" }
    );
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str(&format!(
        "Content-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
        body.len()
    ));
    let mut bytes = head.into_bytes();
    bytes.extend_from_slice(body);
    let _ = stream.write_all(&bytes);
    let _ = stream.flush();
}

/// The relay's reading of one HTTP/1.1 request from pi. The key is checked
/// as soon as the head arrives, before a body is buffered.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Request<'a> {
    Incomplete,
    Rejected { status: u16, message: String },
    Complete(&'a [u8]),
}

pub(crate) fn read_request<'a>(buffer: &'a [u8], key: &str) -> Request<'a> {
    let too_large = || Request::Rejected {
        status: 431,
        message: "The request head is too large.".into(),
    };
    let malformed = || Request::Rejected {
        status: 400,
        message: "Malformed request.".into(),
    };
    let Some(head_end) = buffer.windows(4).position(|window| window == b"\r\n\r\n") else {
        return if buffer.len() > MAXIMUM_HEAD_BYTES {
            too_large()
        } else {
            Request::Incomplete
        };
    };
    if head_end > MAXIMUM_HEAD_BYTES {
        return too_large();
    }
    let Ok(head) = std::str::from_utf8(&buffer[..head_end]) else {
        return too_large();
    };
    let mut lines = head.split("\r\n");
    let request_line: Vec<&str> = lines
        .next()
        .unwrap_or_default()
        .split(' ')
        .filter(|part| !part.is_empty())
        .collect();
    let [method, target, _version] = request_line[..] else {
        return malformed();
    };
    let mut headers: HashMap<String, &str> = HashMap::new();
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            return malformed();
        };
        let name = name.trim().to_ascii_lowercase();
        if headers.contains_key(&name) {
            return Request::Rejected {
                status: 400,
                message: format!("Repeated {name} header."),
            };
        }
        headers.insert(name, value.trim());
    }
    let path = target.split('?').next().unwrap_or_default();
    if method != "POST" || path != PATH {
        return Request::Rejected {
            status: 404,
            message: "Only POST /v1/responses is relayed.".into(),
        };
    }
    // Browsers always send Origin; pi never does.
    if headers.contains_key("origin") {
        return Request::Rejected {
            status: 403,
            message: "Browser requests are refused.".into(),
        };
    }
    let presented = headers.get("authorization").copied().unwrap_or_default();
    if !constant_time_eq(presented.as_bytes(), format!("Bearer {key}").as_bytes()) {
        return Request::Rejected {
            status: 401,
            message: "This Agent session's relay key was not presented.".into(),
        };
    }
    let length = match (
        headers.get("transfer-encoding"),
        headers.get("content-length"),
    ) {
        (None, Some(declared)) => declared.parse::<usize>().ok(),
        _ => None,
    };
    let Some(length) = length else {
        return Request::Rejected {
            status: 411,
            message: "A Content-Length is required.".into(),
        };
    };
    if length > MAXIMUM_REQUEST_BYTES {
        return Request::Rejected {
            status: 413,
            message: "The Agent request is too large for the ChatGPT plan relay.".into(),
        };
    }
    let body_start = head_end + 4;
    if buffer.len() - body_start < length {
        return Request::Incomplete;
    }
    Request::Complete(&buffer[body_start..body_start + length])
}

pub(crate) fn constant_time_eq(presented: &[u8], expected: &[u8]) -> bool {
    if presented.len() != expected.len() {
        return false;
    }
    presented
        .iter()
        .zip(expected)
        .fold(0u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

/// pi's body with [`UNSUPPORTED_FIELDS`] removed, `store: false` and
/// `stream: true` set, and system messages sent as developer messages.
/// `None` for anything that isn't a Responses request.
pub(crate) fn upstream_body(data: &[u8]) -> Option<Vec<u8>> {
    let Ok(Value::Object(mut body)) = serde_json::from_slice::<Value>(data) else {
        return None;
    };
    if !body.get("model").is_some_and(Value::is_string)
        || !body.get("input").is_some_and(Value::is_array)
    {
        return None;
    }
    for field in UNSUPPORTED_FIELDS {
        body.remove(field);
    }
    body.insert("store".into(), Value::Bool(false));
    body.insert("stream".into(), Value::Bool(true));
    if let Some(Value::Array(input)) = body.get_mut("input") {
        for item in input {
            if let Some(message) = item.as_object_mut()
                && message.get("role").and_then(Value::as_str) == Some("system")
            {
                message.insert("role".into(), Value::String("developer".into()));
            }
        }
    }
    serde_json::to_vec(&body).ok()
}

/// pi retries 408, 409, 429 and 5xx by default. Plan limits, eligibility and
/// request errors don't change on a retry; temporary plan outages do. `None`
/// leaves pi's default for the status.
pub(crate) fn should_retry(
    code: Option<&str>,
    message: Option<&str>,
    param: Option<&str>,
) -> Option<bool> {
    plan_error_for(code, message, param).map(|err| err.downcast_ref::<PlanError>().is_none())
}

#[cfg(test)]
mod tests;
