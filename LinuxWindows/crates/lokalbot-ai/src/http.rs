//! Blocking HTTP shared by the clients and the runtime's health checks.

use std::io::{BufRead, BufReader};
use std::time::Duration;

use anyhow::Result;
use serde_json::Value;

use crate::error::AiError;

/// An agent for one server. Loopback servers bypass any proxy from the
/// environment; remote ones honour it. Status codes are returned, not raised.
pub(crate) fn agent(base_url: &str, timeout: Duration) -> ureq::Agent {
    let mut builder = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .max_redirects(0)
        .user_agent(concat!("LokalBot/", env!("CARGO_PKG_VERSION")))
        .timeout_connect(Some(Duration::from_secs(10)))
        .timeout_global(Some(timeout));
    if lokalbot_core::access::is_loopback_url(base_url) {
        builder = builder.proxy(None);
    }
    ureq::Agent::new_with_config(builder.build())
}

pub(crate) struct Reply {
    pub status: u16,
    pub body: Vec<u8>,
    pub retry_after: Option<Duration>,
    pub request_id: Option<String>,
}

impl Reply {
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub fn json(&self) -> Result<Value> {
        serde_json::from_slice(&self.body)
            .map_err(|_| AiError::BadResponse("the server returned invalid JSON".into()).into())
    }

    /// `TextEngineError.fromHTTPResponse`: the server's own message, clipped.
    pub fn status_error(&self) -> AiError {
        let detail = serde_json::from_slice::<Value>(&self.body)
            .ok()
            .and_then(|json| {
                json.get("error").and_then(|e| {
                    e.get("message")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .or_else(|| e.as_str().map(str::to_string))
                })
            })
            .unwrap_or_else(|| {
                let text = String::from_utf8_lossy(&self.body).trim().to_string();
                if text.is_empty() {
                    "empty error response".into()
                } else {
                    text
                }
            });
        let detail: String = detail.chars().take(600).collect();
        let detail = match &self.request_id {
            Some(id) => format!("{detail} (request ID: {id})"),
            None => detail,
        };
        AiError::HttpStatus {
            code: self.status,
            detail,
            retry_after: self.retry_after,
        }
    }
}

fn unreachable(base: &str, err: ureq::Error) -> anyhow::Error {
    log::warn!(
        "text engine transport failure host={} error={err}",
        host_label(base)
    );
    AiError::ServerUnreachable(base.to_string()).into()
}

/// The host of a URL for logs; never the path or query.
pub(crate) fn host_label(url: &str) -> String {
    lokalbot_core::access::origin_of(url)
        .and_then(|o| o.split_once("://").map(|(_, h)| h.to_string()))
        .unwrap_or_else(|| "unknown".into())
}

fn finish(
    base: &str,
    result: std::result::Result<ureq::http::Response<ureq::Body>, ureq::Error>,
) -> Result<Reply> {
    let mut response = result.map_err(|err| unreachable(base, err))?;
    let status = response.status().as_u16();
    let header = |name: &str| {
        response
            .headers()
            .get(name)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string)
    };
    let retry_after = header("retry-after")
        .and_then(|v| v.trim().parse::<f64>().ok())
        .map(|s| Duration::from_secs_f64(s.max(0.0)));
    let request_id = header("x-request-id").or_else(|| header("request-id"));
    let body = response
        .body_mut()
        .with_config()
        .limit(64 * 1024 * 1024)
        .read_to_vec()
        .map_err(|err| unreachable(base, err))?;
    Ok(Reply {
        status,
        body,
        retry_after,
        request_id,
    })
}

pub(crate) fn post_json(
    agent: &ureq::Agent,
    url: &str,
    bearer: Option<&str>,
    body: &Value,
) -> Result<Reply> {
    let bytes = serde_json::to_vec(body)?;
    let mut request = agent.post(url).header("Content-Type", "application/json");
    if let Some(token) = bearer.filter(|t| !t.is_empty()) {
        request = request.header("Authorization", format!("Bearer {token}"));
    }
    finish(url, request.send(&bytes[..]))
}

pub(crate) fn get(agent: &ureq::Agent, url: &str, bearer: Option<&str>) -> Result<Reply> {
    let mut request = agent.get(url);
    if let Some(token) = bearer.filter(|t| !t.is_empty()) {
        request = request.header("Authorization", format!("Bearer {token}"));
    }
    finish(url, request.call())
}

/// A JSON POST with explicit headers (Anthropic's `x-api-key`, a plan's
/// bearer token). Header values are never logged.
pub(crate) fn post_json_with(
    agent: &ureq::Agent,
    url: &str,
    headers: &[(&str, String)],
    body: &Value,
) -> Result<Reply> {
    let bytes = serde_json::to_vec(body)?;
    let mut request = agent.post(url).header("Content-Type", "application/json");
    for (name, value) in headers {
        request = request.header(*name, value.as_str());
    }
    finish(url, request.send(&bytes[..]))
}

/// A GET with explicit headers.
pub(crate) fn get_with(
    agent: &ureq::Agent,
    url: &str,
    headers: &[(&str, String)],
) -> Result<Reply> {
    let mut request = agent.get(url);
    for (name, value) in headers {
        request = request.header(*name, value.as_str());
    }
    finish(url, request.call())
}

/// An `application/x-www-form-urlencoded` POST (OAuth token endpoints).
/// Fields are sent in key order, every value percent-encoded.
pub(crate) fn post_form(agent: &ureq::Agent, url: &str, fields: &[(&str, &str)]) -> Result<Reply> {
    let mut sorted = fields.to_vec();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    let body = sorted
        .iter()
        .map(|(key, value)| format!("{key}={}", form_escaped(value)))
        .collect::<Vec<_>>()
        .join("&");
    let request = agent
        .post(url)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .header("Accept", "application/json");
    finish(url, request.send(body.as_bytes()))
}

/// Percent-encodes everything outside RFC 3986's unreserved characters.
pub(crate) fn form_escaped(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// A response whose body is read line by line (SSE, NDJSON).
pub(crate) struct LineStream {
    pub status: u16,
    reader: Option<BufReader<ureq::BodyReader<'static>>>,
    pub error: Option<Reply>,
}

impl LineStream {
    /// The next line without its terminator; `None` at the end of the body.
    pub fn next_line(&mut self, base: &str) -> Result<Option<String>> {
        let Some(reader) = self.reader.as_mut() else {
            return Ok(None);
        };
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => Ok(None),
            Ok(_) => {
                while line.ends_with('\n') || line.ends_with('\r') {
                    line.pop();
                }
                Ok(Some(line))
            }
            Err(err) => {
                log::warn!(
                    "text engine stream failure host={} error={err}",
                    host_label(base)
                );
                Err(AiError::ServerUnreachable(base.to_string()).into())
            }
        }
    }
}

pub(crate) fn post_stream(
    agent: &ureq::Agent,
    url: &str,
    bearer: Option<&str>,
    body: &Value,
) -> Result<LineStream> {
    let headers: Vec<(&str, String)> = bearer
        .filter(|t| !t.is_empty())
        .map(|token| ("Authorization", format!("Bearer {token}")))
        .into_iter()
        .collect();
    post_stream_with(agent, url, &headers, body)
}

/// [`post_stream`] with explicit headers.
pub(crate) fn post_stream_with(
    agent: &ureq::Agent,
    url: &str,
    headers: &[(&str, String)],
    body: &Value,
) -> Result<LineStream> {
    let bytes = serde_json::to_vec(body)?;
    let mut request = agent
        .post(url)
        .header("Content-Type", "application/json")
        .header("Accept", "text/event-stream");
    for (name, value) in headers {
        request = request.header(*name, value.as_str());
    }
    let response = request
        .send(&bytes[..])
        .map_err(|err| unreachable(url, err))?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        let reply = finish(url, Ok(response))?;
        return Ok(LineStream {
            status,
            reader: None,
            error: Some(reply),
        });
    }
    let reader = Some(BufReader::new(response.into_body().into_reader()));
    Ok(LineStream {
        status,
        reader,
        error: None,
    })
}

#[cfg(test)]
pub(crate) mod testing {
    //! A tiny in-process HTTP/1.1 server that plays llama-server, Ollama,
    //! OpenAI-style APIs and file hosts in tests.

    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::Arc;
    use std::time::Duration;

    use parking_lot::Mutex;
    use serde_json::Value;

    #[derive(Clone, Debug)]
    pub struct StubRequest {
        pub method: String,
        pub path: String,
        pub headers: Vec<(String, String)>,
        pub body: Vec<u8>,
    }

    impl StubRequest {
        pub fn header(&self, name: &str) -> Option<String> {
            self.headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .map(|(_, v)| v.clone())
        }

        pub fn json(&self) -> Value {
            serde_json::from_slice(&self.body).unwrap_or(Value::Null)
        }
    }

    pub enum Reply {
        Json(u16, Value),
        Text(u16, String),
        /// Server-sent events: each item is written as `data: <item>\n\n`.
        Sse(Vec<String>),
        /// A raw `text/event-stream` body, written as given.
        RawSse(String),
        /// Newline-delimited JSON, one value per line.
        Lines(Vec<String>),
        /// A file honouring HEAD and `Range: bytes=a-b` / `bytes=a-`.
        File(Arc<Vec<u8>>),
    }

    type Handler = Arc<dyn Fn(&StubRequest) -> Reply + Send + Sync>;

    pub struct StubServer {
        port: u16,
        requests: Arc<Mutex<Vec<StubRequest>>>,
    }

    pub struct StubResponse;

    impl StubResponse {
        /// Serves `bytes` at `path`; everything else is 404.
        pub fn file_route(
            path: &'static str,
            bytes: Vec<u8>,
        ) -> impl Fn(&StubRequest) -> Reply + Send + Sync + 'static {
            let bytes = Arc::new(bytes);
            move |request| {
                if request.path == path {
                    Reply::File(bytes.clone())
                } else {
                    Reply::Text(404, "not found".into())
                }
            }
        }
    }

    impl StubServer {
        pub fn start(handler: impl Fn(&StubRequest) -> Reply + Send + Sync + 'static) -> Self {
            Self::start_on(TcpListener::bind("127.0.0.1:0").expect("bind"), handler)
        }

        pub fn start_on(
            listener: TcpListener,
            handler: impl Fn(&StubRequest) -> Reply + Send + Sync + 'static,
        ) -> Self {
            let port = listener.local_addr().unwrap().port();
            let requests = Arc::new(Mutex::new(Vec::new()));
            let handler: Handler = Arc::new(handler);
            let log = requests.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let handler = handler.clone();
                    let log = log.clone();
                    std::thread::spawn(move || {
                        let _ = serve(stream, &handler, &log);
                    });
                }
            });
            Self { port, requests }
        }

        pub fn url(&self, path: &str) -> String {
            format!("http://127.0.0.1:{}{path}", self.port)
        }

        pub fn requests(&self) -> Vec<StubRequest> {
            self.requests.lock().clone()
        }

        pub fn last_json(&self, path: &str) -> Value {
            self.requests()
                .into_iter()
                .rev()
                .find(|r| r.path == path)
                .map(|r| r.json())
                .unwrap_or(Value::Null)
        }
    }

    fn serve(
        stream: TcpStream,
        handler: &Handler,
        log: &Mutex<Vec<StubRequest>>,
    ) -> std::io::Result<()> {
        stream.set_read_timeout(Some(Duration::from_secs(10)))?;
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut request_line = String::new();
        reader.read_line(&mut request_line)?;
        let mut parts = request_line.split_whitespace();
        let method = parts.next().unwrap_or_default().to_string();
        let path = parts.next().unwrap_or_default().to_string();
        let mut headers = Vec::new();
        loop {
            let mut line = String::new();
            reader.read_line(&mut line)?;
            let line = line.trim_end();
            if line.is_empty() {
                break;
            }
            if let Some((k, v)) = line.split_once(':') {
                headers.push((k.trim().to_string(), v.trim().to_string()));
            }
        }
        let length = headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, v)| v.parse::<usize>().ok())
            .unwrap_or(0);
        let mut body = vec![0u8; length];
        reader.read_exact(&mut body)?;
        let request = StubRequest {
            method: method.clone(),
            path,
            headers,
            body,
        };
        log.lock().push(request.clone());
        let reply = handler(&request);
        let mut out = stream;
        match reply {
            Reply::Json(status, value) => write(
                &mut out,
                status,
                "application/json",
                value.to_string().as_bytes(),
                &[],
            ),
            Reply::Text(status, text) => {
                write(&mut out, status, "text/plain", text.as_bytes(), &[])
            }
            Reply::Lines(lines) => {
                out.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n")?;
                for line in lines {
                    out.write_all(line.as_bytes())?;
                    out.write_all(b"\n")?;
                    out.flush()?;
                }
                Ok(())
            }
            Reply::Sse(events) => {
                out.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")?;
                for event in events {
                    out.write_all(format!("data: {event}\n\n").as_bytes())?;
                    out.flush()?;
                    std::thread::sleep(Duration::from_millis(2));
                }
                Ok(())
            }
            Reply::RawSse(body) => {
                out.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")?;
                out.write_all(body.as_bytes())?;
                out.flush()
            }
            Reply::File(bytes) => {
                let total = bytes.len() as u64;
                let range = request.header("range").and_then(|r| {
                    let spec = r.strip_prefix("bytes=")?;
                    let (a, b) = spec.split_once('-')?;
                    let start: u64 = a.parse().ok()?;
                    let end: u64 = if b.is_empty() {
                        total - 1
                    } else {
                        b.parse().ok()?
                    };
                    Some((start, end.min(total - 1)))
                });
                let extra = [
                    ("Accept-Ranges", "bytes".to_string()),
                    ("ETag", "\"stub\"".to_string()),
                ];
                if method == "HEAD" {
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\nETag: \"stub\"\r\nConnection: close\r\n\r\n"
                    );
                    return out.write_all(head.as_bytes());
                }
                match range {
                    Some((start, end)) => {
                        let slice = &bytes[start as usize..=end as usize];
                        let content_range =
                            ("Content-Range", format!("bytes {start}-{end}/{total}"));
                        write(
                            &mut out,
                            206,
                            "application/octet-stream",
                            slice,
                            &[extra[0].clone(), extra[1].clone(), content_range],
                        )
                    }
                    None => write(&mut out, 200, "application/octet-stream", &bytes, &extra),
                }
            }
        }
    }

    fn write(
        out: &mut TcpStream,
        status: u16,
        content_type: &str,
        body: &[u8],
        extra: &[(&str, String)],
    ) -> std::io::Result<()> {
        let reason = match status {
            200 => "OK",
            206 => "Partial Content",
            404 => "Not Found",
            _ => "Status",
        };
        let mut head = format!(
            "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n",
            body.len()
        );
        for (k, v) in extra {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        head.push_str("\r\n");
        out.write_all(head.as_bytes())?;
        out.write_all(body)?;
        out.flush()
    }
}
