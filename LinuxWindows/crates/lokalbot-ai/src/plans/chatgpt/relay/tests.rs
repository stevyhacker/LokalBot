//! The relay Agent Mode's pi talks to for the ChatGPT plan, over real
//! loopback HTTP with a fake OpenAI upstream and token source
//! (`ChatGPTPlanRelayTests.swift`).

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::AtomicUsize;

use super::*;
use crate::plans::chatgpt::{Credentials, Endpoints, MemoryStore, PLAN_SCOPE};

struct FakeReply {
    status: u16,
    headers: Vec<(&'static str, &'static str)>,
    chunks: Vec<String>,
    /// Keeps the body open after the chunks, like a model still thinking.
    /// It sends SSE comments meanwhile, so it notices the relay hanging up.
    stays_open: bool,
}

impl FakeReply {
    fn events(chunks: &[&str]) -> Self {
        Self {
            status: 200,
            headers: vec![("Content-Type", "text/event-stream")],
            chunks: chunks.iter().map(|chunk| chunk.to_string()).collect(),
            stays_open: false,
        }
    }

    fn error(status: u16, body: &str) -> Self {
        Self {
            status,
            headers: vec![("Content-Type", "application/json")],
            chunks: vec![body.to_string()],
            stays_open: false,
        }
    }
}

#[derive(Clone, Debug)]
struct Recorded {
    path: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
}

impl Recorded {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap()
    }
}

/// Records upstream requests and answers them from a queue.
struct FakeOpenAi {
    port: u16,
    replies: Mutex<VecDeque<FakeReply>>,
    requests: Mutex<Vec<Recorded>>,
    /// Open bodies that ended because the relay went away.
    endings: AtomicUsize,
}

impl FakeOpenAi {
    fn start(replies: Vec<FakeReply>) -> Arc<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let fake = Arc::new(Self {
            port: listener.local_addr().unwrap().port(),
            replies: Mutex::new(replies.into()),
            requests: Mutex::new(Vec::new()),
            endings: AtomicUsize::new(0),
        });
        let serving = fake.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let fake = serving.clone();
                std::thread::spawn(move || fake.serve(stream));
            }
        });
        fake
    }

    fn url(&self) -> String {
        format!("http://127.0.0.1:{}/v1/responses", self.port)
    }

    fn requests(&self) -> Vec<Recorded> {
        self.requests.lock().clone()
    }

    fn serve(&self, mut stream: TcpStream) {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut request_line = String::new();
        if reader.read_line(&mut request_line).unwrap_or(0) == 0 {
            return;
        }
        let path = request_line
            .split_whitespace()
            .nth(1)
            .unwrap_or_default()
            .to_string();
        let mut headers = Vec::new();
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let line = line.trim_end();
            if line.is_empty() {
                break;
            }
            let (name, value) = line.split_once(':').unwrap();
            headers.push((name.trim().to_string(), value.trim().to_string()));
        }
        let length = headers
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
            .map(|(_, value)| value.parse::<usize>().unwrap())
            .unwrap_or(0);
        let mut body = vec![0u8; length];
        reader.read_exact(&mut body).unwrap();
        self.requests.lock().push(Recorded {
            path,
            headers,
            body,
        });
        let reply = self.replies.lock().pop_front().expect("an upstream reply");
        let mut head = format!("HTTP/1.1 {} Reply\r\n", reply.status);
        for (name, value) in &reply.headers {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
        head.push_str("Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
        let chunk = |text: &str| format!("{:x}\r\n{text}\r\n", text.len());
        let mut out = head;
        for text in &reply.chunks {
            out.push_str(&chunk(text));
        }
        if stream.write_all(out.as_bytes()).is_err() {
            return;
        }
        if !reply.stays_open {
            let _ = stream.write_all(b"0\r\n\r\n");
            return;
        }
        loop {
            std::thread::sleep(Duration::from_millis(50));
            if stream
                .write_all(chunk(": thinking\n\n").as_bytes())
                .is_err()
            {
                self.endings.fetch_add(1, Ordering::SeqCst);
                return;
            }
        }
    }
}

/// Hands out `plan-token-1`, then `plan-token-2` after a rejection.
#[derive(Default)]
struct FakeTokens {
    requests: Mutex<Vec<Option<String>>>,
    signed_out: bool,
}

impl TokenSource for FakeTokens {
    fn token(&self, rejected: Option<&str>) -> Result<String> {
        self.requests.lock().push(rejected.map(str::to_string));
        if self.signed_out {
            return Err(PlanError::SignedOut.into());
        }
        Ok(if rejected.is_none() {
            "plan-token-1"
        } else {
            "plan-token-2"
        }
        .into())
    }
}

fn pi_body() -> Value {
    json!({
        "model": "gpt-6.1-sol",
        "input": [
            {"role": "system", "content": "Synthetic instructions."},
            {"role": "user", "content": [{"type": "input_text", "text": "synthetic-private-context"}]},
        ],
        "stream": false,
        "store": true,
        "prompt_cache_key": "session-1",
        "prompt_cache_retention": "24h",
        "max_output_tokens": 4096,
        "temperature": 0.2,
        "tools": [{"type": "function", "name": "read", "parameters": {"type": "object"}}],
        "reasoning": {"effort": "medium", "summary": "auto"},
        "include": ["reasoning.encrypted_content"],
    })
}

struct Answer {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

impl Answer {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    fn json(&self) -> Value {
        serde_json::from_str(&self.body).unwrap()
    }
}

/// One request as pi's fetch sends it.
fn post(relay: &Relay, key: &str) -> Answer {
    let url = format!("{}/responses", relay.base_url());
    let agent = http::agent(&url, Duration::from_secs(10));
    let mut response = agent
        .post(&url)
        .header("Content-Type", "application/json")
        .header("Authorization", format!("Bearer {key}"))
        .send(pi_body().to_string().as_bytes())
        .unwrap();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| (name.to_string(), value.to_str().unwrap().to_string()))
        .collect();
    Answer {
        status: response.status().as_u16(),
        headers,
        body: response.body_mut().read_to_string().unwrap(),
    }
}

/// A raw connection with the request written, for hanging up mid-reply.
fn open(relay: &Relay) -> TcpStream {
    let body = pi_body().to_string();
    let mut stream = TcpStream::connect(("127.0.0.1", relay.port())).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write!(
        stream,
        "POST /v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {}\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
        relay.key(),
        body.len()
    )
    .unwrap();
    stream
}

fn wait_for(what: &str, condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn head(lines: &[&str], body: &str) -> Vec<u8> {
    format!("{}\r\n\r\n{body}", lines.join("\r\n")).into_bytes()
}

// ------------------------------------------------------------ request reading

#[test]
fn the_key_is_checked_before_the_body_is_buffered() {
    let partial = head(
        &[
            "POST /v1/responses HTTP/1.1",
            "Authorization: Bearer wrong",
            "Content-Length: 900",
        ],
        "",
    );
    assert!(
        matches!(
            read_request(&partial, "right"),
            Request::Rejected { status: 401, .. }
        ),
        "a wrong key must be refused as soon as the head arrives"
    );
    let good = [
        "POST /v1/responses HTTP/1.1",
        "Authorization: Bearer right",
        "Content-Length: 4",
    ];
    assert_eq!(
        read_request(&head(&good, "{}"), "right"),
        Request::Incomplete
    );
    assert_eq!(
        read_request(&head(&good, "{ }\n"), "right"),
        Request::Complete(b"{ }\n")
    );
    assert_eq!(read_request(b"POST /v1/resp", "right"), Request::Incomplete);
    assert!(matches!(
        read_request(&vec![b'a'; MAXIMUM_HEAD_BYTES + 1], "right"),
        Request::Rejected { status: 431, .. }
    ));
}

#[test]
fn only_pi_shaped_requests_are_relayed() {
    let status = |lines: &[&str]| match read_request(&head(lines, ""), "k") {
        Request::Rejected { status, .. } => Some(status),
        _ => None,
    };
    let auth = "Authorization: Bearer k";
    assert_eq!(
        status(&["GET /v1/responses HTTP/1.1", auth, "Content-Length: 0"]),
        Some(404)
    );
    assert_eq!(
        status(&[
            "POST /v1/chat/completions HTTP/1.1",
            auth,
            "Content-Length: 0"
        ]),
        Some(404)
    );
    assert_eq!(
        status(&[
            "POST /v1/responses HTTP/1.1",
            auth,
            "Origin: https://example.com",
            "Content-Length: 0"
        ]),
        Some(403)
    );
    assert_eq!(
        status(&["POST /v1/responses HTTP/1.1", "Content-Length: 0"]),
        Some(401)
    );
    assert_eq!(
        status(&[
            "POST /v1/responses HTTP/1.1",
            "Authorization: bearer k",
            "Content-Length: 0"
        ]),
        Some(401),
        "the key is compared exactly"
    );
    assert_eq!(
        status(&[
            "POST /v1/responses HTTP/1.1",
            auth,
            auth,
            "Content-Length: 0"
        ]),
        Some(400)
    );
    assert_eq!(
        status(&[
            "POST /v1/responses HTTP/1.1",
            auth,
            "Transfer-Encoding: chunked"
        ]),
        Some(411)
    );
    assert_eq!(
        status(&["POST /v1/responses HTTP/1.1", auth, "Content-Length: -1"]),
        Some(411)
    );
    let too_long = format!("Content-Length: {}", MAXIMUM_REQUEST_BYTES + 1);
    assert_eq!(
        status(&["POST /v1/responses HTTP/1.1", auth, &too_long]),
        Some(413)
    );
    assert_eq!(status(&["POST /v1/responses", auth]), Some(400));
    assert_eq!(
        status(&["POST /v1/responses?x=1 HTTP/1.1", auth, "Content-Length: 0"]),
        None
    );
    assert!(constant_time_eq(b"Bearer k", b"Bearer k"));
    assert!(!constant_time_eq(b"Bearer k", b"Bearer kk"));
}

// ----------------------------------------------------------------- plan rules

#[test]
fn the_body_follows_the_plan_routes_rules() {
    let body: Value =
        serde_json::from_slice(&upstream_body(pi_body().to_string().as_bytes()).unwrap()).unwrap();
    assert_eq!(body["store"], false);
    assert_eq!(body["stream"], true);
    for field in ["max_output_tokens", "temperature", "prompt_cache_retention"] {
        assert!(body.get(field).is_none(), "{field}");
    }
    let input = body["input"].as_array().unwrap();
    assert_eq!(
        input[0]["role"], "developer",
        "the route rejects system messages"
    );
    assert_eq!(input[1]["role"], "user");
    assert_eq!(body["prompt_cache_key"], "session-1");
    assert_eq!(body["tools"][0]["name"], "read");
    assert_eq!(body["include"], json!(["reasoning.encrypted_content"]));
    assert_eq!(upstream_body(b"[1]"), None);
    assert_eq!(upstream_body(br#"{"model": "m"}"#), None);
}

#[test]
fn plan_limits_are_not_retried_but_outages_are() {
    assert_eq!(
        should_retry(
            Some("subscription_sharing_usage_limit_exceeded"),
            None,
            None
        ),
        Some(false)
    );
    assert_eq!(
        should_retry(
            Some("subscription_sharing_unsupported_capability"),
            None,
            Some("tools")
        ),
        Some(false)
    );
    assert_eq!(
        should_retry(Some("subscription_sharing_usage_unavailable"), None, None),
        Some(true)
    );
    assert_eq!(should_retry(Some("rate_limit_exceeded"), None, None), None);
    assert_eq!(should_retry(None, Some("anything"), None), None);
}

// ------------------------------------------------------------------- relaying

#[test]
fn streams_openais_reply_with_the_plan_token_not_pis_key() {
    let events = [
        "data: {\"type\":\"response.created\"}\n\n",
        "data: {\"type\":\"response.completed\"}\n\n",
    ];
    let openai = FakeOpenAi::start(vec![FakeReply::events(&events)]);
    let tokens = Arc::new(FakeTokens::default());
    let relay = Relay::start_with(tokens.clone(), openai.url()).unwrap();
    assert!(relay.base_url().starts_with("http://127.0.0.1:"));
    let answer = post(&relay, relay.key());
    assert_eq!(answer.status, 200);
    assert_eq!(answer.body, events.concat());
    assert_eq!(answer.header("cache-control"), Some("no-store"));
    let upstream = &openai.requests()[0];
    assert_eq!(upstream.path, "/v1/responses");
    assert_eq!(
        upstream.header("authorization"),
        Some("Bearer plan-token-1")
    );
    assert_eq!(upstream.header("accept"), Some("text/event-stream"));
    assert!(
        upstream
            .headers
            .iter()
            .all(|(_, value)| !value.contains(relay.key())),
        "pi's key stays on this computer"
    );
    assert_eq!(upstream.json()["store"], false);
    assert_eq!(upstream.json()["input"][0]["role"], "developer");
    assert_eq!(*tokens.requests.lock(), vec![None]);
}

#[test]
fn a_rejected_token_is_refreshed_once() {
    let openai = FakeOpenAi::start(vec![
        FakeReply::error(401, "{}"),
        FakeReply::events(&["data: {}\n\n"]),
    ]);
    let tokens = Arc::new(FakeTokens::default());
    let relay = Relay::start_with(tokens.clone(), openai.url()).unwrap();
    assert_eq!(post(&relay, relay.key()).status, 200);
    assert_eq!(
        *tokens.requests.lock(),
        vec![None, Some("plan-token-1".to_string())]
    );
    let sent: Vec<_> = openai
        .requests()
        .iter()
        .map(|request| request.header("authorization").unwrap().to_string())
        .collect();
    assert_eq!(sent, ["Bearer plan-token-1", "Bearer plan-token-2"]);
}

#[test]
fn a_second_rejection_reaches_pi() {
    let openai = FakeOpenAi::start(vec![
        FakeReply::error(401, "{}"),
        FakeReply::error(401, r#"{"error":{"message":"expired"}}"#),
    ]);
    let tokens = Arc::new(FakeTokens::default());
    let relay = Relay::start_with(tokens.clone(), openai.url()).unwrap();
    let answer = post(&relay, relay.key());
    assert_eq!(answer.status, 401);
    assert_eq!(answer.json()["error"]["message"], "expired");
    assert_eq!(openai.requests().len(), 2, "one refresh, no loop");
}

#[test]
fn a_wrong_key_never_reaches_openai() {
    let openai = FakeOpenAi::start(Vec::new());
    let tokens = Arc::new(FakeTokens::default());
    let relay = Relay::start_with(tokens.clone(), openai.url()).unwrap();
    let answer = post(&relay, "not-the-key");
    assert_eq!(answer.status, 401);
    assert_eq!(answer.header("x-should-retry"), Some("false"));
    assert!(openai.requests().is_empty());
    assert!(tokens.requests.lock().is_empty());
}

#[test]
fn a_usage_limit_tells_pi_not_to_retry() {
    let error =
        r#"{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}"#;
    let mut reply = FakeReply::error(429, error);
    reply.headers.push(("Retry-After", "60"));
    let openai = FakeOpenAi::start(vec![reply]);
    let relay = Relay::start_with(Arc::new(FakeTokens::default()), openai.url()).unwrap();
    let answer = post(&relay, relay.key());
    assert_eq!(answer.status, 429);
    assert_eq!(answer.header("x-should-retry"), Some("false"));
    assert_eq!(answer.header("retry-after"), Some("60"));
    assert_eq!(answer.body, error, "pi links the usage page from the code");
}

#[test]
fn a_temporary_outage_may_be_retried() {
    let error = r#"{"error":{"code":"subscription_sharing_usage_unavailable"}}"#;
    let openai = FakeOpenAi::start(vec![FakeReply::error(503, error)]);
    let relay = Relay::start_with(Arc::new(FakeTokens::default()), openai.url()).unwrap();
    let answer = post(&relay, relay.key());
    assert_eq!(answer.status, 503);
    assert_eq!(answer.header("x-should-retry"), Some("true"));
}

#[test]
fn a_signed_out_plan_asks_to_sign_in() {
    let openai = FakeOpenAi::start(Vec::new());
    let tokens = Arc::new(FakeTokens {
        signed_out: true,
        ..FakeTokens::default()
    });
    let relay = Relay::start_with(tokens, openai.url()).unwrap();
    let answer = post(&relay, relay.key());
    assert_eq!(answer.status, 401);
    assert_eq!(answer.header("x-should-retry"), Some("false"));
    assert_eq!(
        answer.json()["error"]["message"],
        PlanError::SignedOut.to_string()
    );
    assert!(openai.requests().is_empty(), "no token, no request");
}

#[test]
fn an_unreachable_openai_keeps_pis_own_retry_rules() {
    // A port that was free a moment ago.
    let closed = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!(
        "http://127.0.0.1:{}/v1/responses",
        closed.local_addr().unwrap().port()
    );
    drop(closed);
    let relay = Relay::start_with(Arc::new(FakeTokens::default()), url).unwrap();
    let answer = post(&relay, relay.key());
    assert_eq!(answer.status, 502);
    assert_eq!(answer.header("x-should-retry"), None);
}

#[test]
fn pi_hanging_up_stops_the_upstream_request() {
    let mut reply = FakeReply::events(&["data: {\"type\":\"response.created\"}\n\n"]);
    reply.stays_open = true;
    let openai = FakeOpenAi::start(vec![reply]);
    let relay = Relay::start_with(Arc::new(FakeTokens::default()), openai.url()).unwrap();
    let stream = open(&relay);
    let mut reader = BufReader::new(stream);
    let mut received = String::new();
    while !received.contains("response.created") {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "{received}");
        received.push_str(&line);
    }
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(
        openai.endings.load(Ordering::SeqCst),
        0,
        "the relay must keep a thinking model's stream open"
    );
    drop(reader);
    wait_for("the upstream body to end", || {
        openai.endings.load(Ordering::SeqCst) == 1
    });
}

#[test]
fn a_hang_up_is_noticed_while_nothing_is_being_written() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let pi = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    let (relay_side, _) = listener.accept().unwrap();
    let cancelled = Arc::new(AtomicBool::new(false));
    watch_for_hang_up(&relay_side, cancelled.clone());
    std::thread::sleep(HANG_UP_POLL * 3);
    assert!(
        !cancelled.load(Ordering::SeqCst),
        "an open connection is not a hang-up"
    );
    drop(pi);
    wait_for("the hang-up", || cancelled.load(Ordering::SeqCst));
}

#[test]
fn stopping_ends_open_requests_and_listening() {
    let mut reply = FakeReply::events(&[]);
    reply.stays_open = true;
    let openai = FakeOpenAi::start(vec![reply]);
    let relay = Relay::start_with(Arc::new(FakeTokens::default()), openai.url()).unwrap();
    let mut stream = open(&relay);
    wait_for("the upstream request", || !openai.requests().is_empty());
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(openai.endings.load(Ordering::SeqCst), 0);
    relay.stop();
    wait_for("the upstream body to end", || {
        openai.endings.load(Ordering::SeqCst) == 1
    });
    // pi's connection was closed, not left hanging.
    let mut rest = Vec::new();
    let _ = stream.read_to_end(&mut rest);
    let port = relay.port();
    drop(relay);
    wait_for("the listener to close", || {
        TcpStream::connect(("127.0.0.1", port)).is_err()
    });
}

#[test]
fn the_account_supplies_the_token_for_its_resource() {
    let openai = FakeOpenAi::start(vec![FakeReply::events(&["data: {}\n\n"])]);
    let credentials = Credentials {
        client_id: "app_issued".into(),
        subject: "user-1".into(),
        email: None,
        id_token: "id".into(),
        access_token: "access-1".into(),
        refresh_token: Some("refresh-1".into()),
        expires_at: chrono::Utc::now().timestamp() + 3_600,
        scopes: [PLAN_SCOPE.to_string()].into_iter().collect(),
    };
    let store = Arc::new(MemoryStore::signed_in(&credentials));
    let endpoints = Endpoints {
        resource: format!("http://127.0.0.1:{}/v1", openai.port),
        ..Endpoints::default()
    };
    let relay = Relay::start(Arc::new(Account::new(store, endpoints))).unwrap();
    assert_eq!(post(&relay, relay.key()).status, 200);
    assert_eq!(
        openai.requests()[0].header("authorization"),
        Some("Bearer access-1")
    );
}
