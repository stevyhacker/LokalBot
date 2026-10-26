//! The ChatGPT plan (`ChatGPTPlanOAuth.swift`, `ChatGPTPlanAccount.swift`,
//! `ChatGPTPlanEngine.swift`).
//!
//! Sign-in is OpenAI's Sign in with ChatGPT for open-source apps ("token
//! sharing"): the first sign-in registers this PC's LokalBot as a client
//! (`dynamic_agent_client`), OpenAI returns the issued client id in the
//! callback, and later sign-ins and refreshes use that id. There is no client
//! secret or API key. The browser returns to a listener on 127.0.0.1 that
//! accepts only that redirect; the code is exchanged with PKCE and the ID
//! token is checked against OpenAI's published keys. Tokens, the
//! registration and a random per-PC id live only in the system credential
//! store: without one, sign-in fails before the browser opens.
//!
//! Think requests go to OpenAI's Responses API with `store: false` and
//! `stream: true`. The token-sharing route rejects sampling and output-cap
//! fields, so neither temperature nor `max_output_tokens` is ever sent.
//! Agent Mode reaches the same API through [`relay`], which holds the tokens
//! for the agent runtime.

use std::collections::{BTreeSet, HashMap};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use anyhow::Result;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};

use lokalbot_core::settings::{ReasoningLevel, SubscriptionPlan};

use super::PlanError;
use super::loopback::LoopbackListener;
use crate::error::AiError;
use crate::http;
use crate::json as model_json;
use crate::think::{ChatRequest, Completion, Dialect, ReasoningSupport, Usage, effort_value};

pub const REGISTRATION_CLIENT_ID: &str = "dynamic_agent_client";
pub const AGENT_NAME: &str = "LokalBot";
pub const SCOPE: &str =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
/// The grant that lets requests draw on the ChatGPT plan. A valid sign-in
/// without it identifies the user but authorizes no inference.
pub const PLAN_SCOPE: &str = "chatgpt.tokens.use.direct";
pub const CALLBACK_PATH: &str = "/auth/callback";
/// OpenAI's example port. Any port works; only the port may vary.
pub const PREFERRED_CALLBACK_PORT: u16 = 1455;
/// Refresh this long before the access token expires.
const REFRESH_MARGIN_SECONDS: i64 = 120;
const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(300);
/// The model list changes rarely; settings views share one fetch.
const MODEL_LIST_SECONDS: i64 = 600;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(900);

const HOST_ACCOUNT: &str = "chatgpt-plan-host-id";
const REGISTRATION_ACCOUNT: &str = "chatgpt-plan-registration";
const CREDENTIALS_ACCOUNT: &str = "chatgpt-plan-credentials";

/// OpenAI's sign-in and API addresses. Tests point them at a local server.
#[derive(Clone, Debug)]
pub struct Endpoints {
    pub issuer: String,
    pub authorize: String,
    pub token: String,
    pub discovery: String,
    /// The API root requests and the token's `resource` name.
    pub resource: String,
    /// Besides `https://*.openai.com`, an origin trusted to serve signing
    /// keys and the revocation endpoint (tests only).
    pub extra_trusted_origin: Option<String>,
}

impl Default for Endpoints {
    fn default() -> Self {
        Self {
            issuer: "https://auth.openai.com".into(),
            authorize: "https://auth.openai.com/api/accounts/authorize".into(),
            token: "https://auth.openai.com/api/accounts/oauth/token".into(),
            discovery: "https://auth.openai.com/.well-known/openid-configuration".into(),
            resource: "https://api.openai.com/v1".into(),
            extra_trusted_origin: None,
        }
    }
}

impl Endpoints {
    /// Only OpenAI's own hosts may serve its keys or revoke its tokens.
    fn trusted(&self, url: &str) -> bool {
        if let Some(origin) = &self.extra_trusted_origin
            && lokalbot_core::access::origin_of(url).as_deref() == Some(origin.as_str())
        {
            return true;
        }
        let Some(origin) = lokalbot_core::access::origin_of(url) else {
            return false;
        };
        let Some(host) = origin.strip_prefix("https://") else {
            return false;
        };
        let host = host.split(':').next().unwrap_or_default();
        host == "openai.com" || host.ends_with(".openai.com")
    }
}

pub fn redirect_uri(port: u16) -> String {
    format!("http://127.0.0.1:{port}{CALLBACK_PATH}")
}

// ------------------------------------------------------------------- OAuth

pub fn random_token(bytes: usize) -> String {
    use ring::rand::SecureRandom as _;
    let mut buffer = vec![0u8; bytes];
    ring::rand::SystemRandom::new()
        .fill(&mut buffer)
        .expect("the system random source is available");
    URL_SAFE_NO_PAD.encode(buffer)
}

fn base64url_decode(text: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text.trim_end_matches('=')).ok()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
}

impl Pkce {
    pub fn new() -> Self {
        Self::from_verifier(random_token(48))
    }

    pub fn from_verifier(verifier: String) -> Self {
        use sha2::Digest as _;
        let challenge = URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(verifier.as_bytes()));
        Self {
            verifier,
            challenge,
        }
    }
}

impl Default for Pkce {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Debug)]
pub struct AuthorizationRequest {
    /// The issued client id, or `None` for a first registration.
    pub client_id: Option<String>,
    pub host_id: String,
    pub redirect_uri: String,
    pub state: String,
    pub nonce: String,
    pub pkce: Pkce,
    /// A previous ID token skips OpenAI's account picker on return.
    pub id_token_hint: Option<String>,
    pub login_hint: Option<String>,
}

impl AuthorizationRequest {
    pub fn url(&self, endpoints: &Endpoints) -> String {
        let mut items: Vec<(&str, &str)> = vec![(
            "client_id",
            self.client_id.as_deref().unwrap_or(REGISTRATION_CLIENT_ID),
        )];
        if self.client_id.is_none() {
            items.push(("agent_name_hint", AGENT_NAME));
        }
        items.extend([
            ("ext_agent_host_id", self.host_id.as_str()),
            ("response_type", "code"),
            ("redirect_uri", self.redirect_uri.as_str()),
            ("scope", SCOPE),
            ("resource", endpoints.resource.as_str()),
            ("state", self.state.as_str()),
            ("nonce", self.nonce.as_str()),
            ("code_challenge_method", "S256"),
            ("code_challenge", self.pkce.challenge.as_str()),
        ]);
        if self.client_id.is_some()
            && let Some(hint) = &self.id_token_hint
        {
            items.push(("id_token_hint", hint));
        }
        if let Some(hint) = self.login_hint.as_deref().filter(|h| !h.is_empty()) {
            items.push(("login_hint", hint));
        }
        let query = items
            .iter()
            .map(|(name, value)| format!("{name}={}", http::form_escaped(value)))
            .collect::<Vec<_>>()
            .join("&");
        format!("{}?{query}", endpoints.authorize)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CallbackOutcome {
    /// `client_id` is the issued id when the callback names one.
    Code {
        code: String,
        client_id: Option<String>,
    },
    Denied,
}

/// Validates `state` before anything else, so a forged request from another
/// local process can neither complete nor cancel a sign-in.
pub fn parse_callback(
    query: &HashMap<String, String>,
    expected_state: &str,
    expected_client_id: Option<&str>,
) -> std::result::Result<CallbackOutcome, PlanError> {
    if query.get("state").map(String::as_str) != Some(expected_state) {
        return Err(PlanError::SignInFailed(
            "The sign-in response didn't match this request. Try again.".into(),
        ));
    }
    if let Some(error) = query.get("error") {
        if error == "access_denied" {
            return Ok(CallbackOutcome::Denied);
        }
        let detail: String = query
            .get("error_description")
            .unwrap_or(error)
            .chars()
            .take(300)
            .collect();
        return Err(PlanError::SignInFailed(format!(
            "ChatGPT sign-in failed: {detail}"
        )));
    }
    let Some(code) = query.get("code").filter(|c| !c.is_empty()) else {
        return Err(PlanError::SignInFailed(
            "ChatGPT didn't return an authorization code.".into(),
        ));
    };
    let client_id = query.get("client_id").filter(|c| !c.is_empty()).cloned();
    if let (Some(expected), Some(returned)) = (expected_client_id, &client_id)
        && expected != returned
    {
        return Err(PlanError::SignInFailed(
            "ChatGPT returned a different app registration. Try again.".into(),
        ));
    }
    if expected_client_id.is_none() && client_id.is_none() {
        return Err(PlanError::SignInFailed(
            "ChatGPT didn't return this app's registration. Try again.".into(),
        ));
    }
    Ok(CallbackOutcome::Code {
        code: code.clone(),
        client_id,
    })
}

#[derive(Clone, Debug, PartialEq)]
pub struct TokenResponse {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub id_token: Option<String>,
    pub expires_in: i64,
    pub scopes: BTreeSet<String>,
}

impl TokenResponse {
    pub fn parse(body: &[u8]) -> std::result::Result<Self, PlanError> {
        let unexpected =
            || PlanError::SignInFailed("ChatGPT returned an unexpected token response.".into());
        let json: Value = serde_json::from_slice(body).map_err(|_| unexpected())?;
        let text = |key: &str| {
            json.get(key)
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty())
                .map(str::to_string)
        };
        let access_token = text("access_token").ok_or_else(unexpected)?;
        Ok(Self {
            access_token,
            refresh_token: text("refresh_token"),
            id_token: text("id_token"),
            expires_in: json
                .get("expires_in")
                .and_then(Value::as_f64)
                .map(|s| s as i64)
                .unwrap_or(3_600),
            scopes: json
                .get("scope")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .split(' ')
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect(),
        })
    }
}

/// Refresh errors after which the refresh token is unusable and the user
/// must sign in again with the saved registration.
pub const TERMINAL_REFRESH_ERRORS: [&str; 6] = [
    "invalid_grant",
    "invalid_refresh_token",
    "token_expired",
    "refresh_token_expired",
    "refresh_token_invalidated",
    "refresh_token_reused",
];

/// The OAuth `error` code from a token-endpoint failure body.
pub fn oauth_error_code(body: &[u8]) -> Option<String> {
    let json: Value = serde_json::from_slice(body).ok()?;
    match json.get("error") {
        Some(Value::String(code)) => Some(code.clone()),
        Some(error) => error
            .get("code")
            .and_then(Value::as_str)
            .map(str::to_string),
        None => None,
    }
}

// ---------------------------------------------------------------- ID token

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Claims {
    pub subject: String,
    pub email: Option<String>,
    pub expires_at: i64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct JsonWebKey {
    pub key_id: Option<String>,
    pub key_type: String,
    pub modulus: Option<Vec<u8>>,
    pub exponent: Option<Vec<u8>>,
    pub x: Option<Vec<u8>>,
    pub y: Option<Vec<u8>>,
}

impl JsonWebKey {
    pub fn key_set(body: &[u8]) -> Vec<JsonWebKey> {
        let Ok(json) = serde_json::from_slice::<Value>(body) else {
            return Vec::new();
        };
        json.get("keys")
            .and_then(Value::as_array)
            .map(|keys| keys.iter().filter_map(Self::from_json).collect())
            .unwrap_or_default()
    }

    fn from_json(json: &Value) -> Option<Self> {
        let field = |key: &str| {
            json.get(key)
                .and_then(Value::as_str)
                .and_then(base64url_decode)
        };
        Some(Self {
            key_type: json.get("kty")?.as_str()?.to_string(),
            key_id: json.get("kid").and_then(Value::as_str).map(str::to_string),
            modulus: field("n"),
            exponent: field("e"),
            x: field("x"),
            y: field("y"),
        })
    }

    fn verify_rs256(&self, input: &[u8], signature: &[u8]) -> bool {
        let (Some(n), Some(e)) = (&self.modulus, &self.exponent) else {
            return false;
        };
        let trim = |bytes: &[u8]| {
            let start = bytes.iter().position(|b| *b != 0).unwrap_or(bytes.len());
            bytes[start..].to_vec()
        };
        ring::signature::RsaPublicKeyComponents {
            n: trim(n),
            e: trim(e),
        }
        .verify(
            &ring::signature::RSA_PKCS1_2048_8192_SHA256,
            input,
            signature,
        )
        .is_ok()
    }

    fn verify_es256(&self, input: &[u8], signature: &[u8]) -> bool {
        let (Some(x), Some(y)) = (&self.x, &self.y) else {
            return false;
        };
        if x.len() != 32 || y.len() != 32 {
            return false;
        }
        let mut point = Vec::with_capacity(65);
        point.push(0x04);
        point.extend_from_slice(x);
        point.extend_from_slice(y);
        ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, point)
            .verify(input, signature)
            .is_ok()
    }
}

fn invalid_token(reason: &str) -> PlanError {
    PlanError::SignInFailed(format!(
        "ChatGPT's sign-in token couldn't be verified ({reason}). Try again."
    ))
}

/// Validates an OpenID Connect ID token from OpenAI: the signature against
/// the issuer's published keys (RS256 or ES256), then issuer, audience,
/// expiry and nonce.
pub fn validate_id_token(
    token: &str,
    keys: &[JsonWebKey],
    issuer: &str,
    client_id: &str,
    nonce: &str,
    now: i64,
) -> std::result::Result<Claims, PlanError> {
    let parts: Vec<&str> = token.split('.').collect();
    let decoded = (parts.len() == 3)
        .then(|| {
            Some((
                base64url_decode(parts[0])?,
                base64url_decode(parts[1])?,
                base64url_decode(parts[2])?,
            ))
        })
        .flatten();
    let Some((header, payload, signature)) = decoded else {
        return Err(invalid_token("malformed ID token"));
    };
    let (Ok(header), Ok(payload)) = (
        serde_json::from_slice::<Value>(&header),
        serde_json::from_slice::<Value>(&payload),
    ) else {
        return Err(invalid_token("malformed ID token"));
    };
    let input = format!("{}.{}", parts[0], parts[1]);
    let key_id = header.get("kid").and_then(Value::as_str);
    let candidates = keys
        .iter()
        .filter(|key| key_id.is_none() || key.key_id.as_deref() == key_id);
    let verified = match header.get("alg").and_then(Value::as_str) {
        Some("RS256") => candidates
            .filter(|key| key.key_type == "RSA")
            .any(|key| key.verify_rs256(input.as_bytes(), &signature)),
        Some("ES256") => candidates
            .filter(|key| key.key_type == "EC")
            .any(|key| key.verify_es256(input.as_bytes(), &signature)),
        _ => return Err(invalid_token("unsupported signing algorithm")),
    };
    if !verified {
        return Err(invalid_token("signature check failed"));
    }
    claims(&payload, issuer, client_id, nonce, now)
}

fn claims(
    payload: &Value,
    issuer: &str,
    client_id: &str,
    nonce: &str,
    now: i64,
) -> std::result::Result<Claims, PlanError> {
    if payload.get("iss").and_then(Value::as_str) != Some(issuer) {
        return Err(invalid_token("wrong issuer"));
    }
    let audiences: Vec<&str> = match payload.get("aud") {
        Some(Value::String(one)) => vec![one.as_str()],
        Some(Value::Array(many)) => many.iter().filter_map(Value::as_str).collect(),
        _ => Vec::new(),
    };
    if !audiences.contains(&client_id) {
        return Err(invalid_token("wrong audience"));
    }
    let Some(expiry) = payload.get("exp").and_then(Value::as_f64).map(|e| e as i64) else {
        return Err(invalid_token("expired"));
    };
    if expiry <= now - 60 {
        return Err(invalid_token("expired"));
    }
    if payload.get("nonce").and_then(Value::as_str) != Some(nonce) {
        return Err(invalid_token("nonce mismatch"));
    }
    let Some(subject) = payload
        .get("sub")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    else {
        return Err(invalid_token("no subject"));
    };
    Ok(Claims {
        subject: subject.to_string(),
        email: payload
            .get("email")
            .and_then(Value::as_str)
            .map(str::to_string),
        expires_at: expiry,
    })
}

// ------------------------------------------------------------------- store

/// Where the sign-in lives: the system credential store in the app
/// (`lokalbot_engine::secrets`), memory in tests.
pub trait Store: Send + Sync {
    /// `Ok(None)` when nothing is stored; `Err` when the store can't be reached.
    fn get(&self, account: &str) -> Result<Option<String>>;
    /// Stores, or with `None` removes, one item.
    fn set(&self, account: &str, value: Option<&str>) -> Result<()>;
}

static INSTALLED_STORE: OnceLock<Arc<dyn Store>> = OnceLock::new();

/// Sets the store the shared account uses. The first call wins.
pub fn install_store(store: Arc<dyn Store>) {
    let _ = INSTALLED_STORE.set(store);
}

/// A store kept in memory (tests and previews).
#[derive(Default)]
pub struct MemoryStore {
    items: Mutex<HashMap<String, String>>,
}

impl MemoryStore {
    /// A store holding one signed-in session.
    pub fn signed_in(credentials: &Credentials) -> Self {
        let store = Self::default();
        let text = serde_json::to_string(credentials).expect("credentials serialize");
        store.items.lock().insert(CREDENTIALS_ACCOUNT.into(), text);
        store
    }
}

impl Store for MemoryStore {
    fn get(&self, account: &str) -> Result<Option<String>> {
        Ok(self.items.lock().get(account).cloned())
    }

    fn set(&self, account: &str, value: Option<&str>) -> Result<()> {
        let mut items = self.items.lock();
        match value {
            Some(value) => items.insert(account.to_string(), value.to_string()),
            None => items.remove(account),
        };
        Ok(())
    }
}

/// Splits long values across several items, for stores with a small item
/// size: Windows Credential Manager keeps at most 1,280 characters, less than
/// one session's tokens. The first item names how many parts follow.
pub struct Chunked<S> {
    inner: S,
    chunk_chars: usize,
}

const CHUNK_HEADER: &str = "lokalbot-chunks:";

impl<S> Chunked<S> {
    pub fn new(inner: S) -> Self {
        Self {
            inner,
            chunk_chars: 1_000,
        }
    }

    fn part(account: &str, index: usize) -> String {
        format!("{account}.{index}")
    }
}

impl<S: Store> Chunked<S> {
    fn parts(&self, account: &str) -> Result<usize> {
        Ok(self
            .inner
            .get(account)?
            .and_then(|head| head.strip_prefix(CHUNK_HEADER)?.parse().ok())
            .unwrap_or(0))
    }
}

impl<S: Store> Store for Chunked<S> {
    fn get(&self, account: &str) -> Result<Option<String>> {
        let Some(head) = self.inner.get(account)? else {
            return Ok(None);
        };
        let Some(count) = head
            .strip_prefix(CHUNK_HEADER)
            .and_then(|n| n.parse::<usize>().ok())
        else {
            return Ok(Some(head));
        };
        let mut value = String::new();
        for index in 1..=count {
            match self.inner.get(&Self::part(account, index))? {
                Some(part) => value.push_str(&part),
                // An interrupted write: as good as nothing stored.
                None => return Ok(None),
            }
        }
        Ok(Some(value))
    }

    fn set(&self, account: &str, value: Option<&str>) -> Result<()> {
        let previous = self.parts(account)?;
        let written = match value {
            Some(value) if value.chars().count() > self.chunk_chars => {
                let characters: Vec<char> = value.chars().collect();
                let parts: Vec<String> = characters
                    .chunks(self.chunk_chars)
                    .map(|chunk| chunk.iter().collect())
                    .collect();
                for (index, part) in parts.iter().enumerate() {
                    self.inner
                        .set(&Self::part(account, index + 1), Some(part))?;
                }
                self.inner
                    .set(account, Some(&format!("{CHUNK_HEADER}{}", parts.len())))?;
                parts.len()
            }
            other => {
                self.inner.set(account, other)?;
                0
            }
        };
        for index in written + 1..=previous {
            self.inner.set(&Self::part(account, index), None)?;
        }
        Ok(())
    }
}

/// This PC's registration with OpenAI. It survives sign-out so the next
/// sign-in reuses the issued client id instead of registering again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Registration {
    #[serde(rename = "clientID")]
    pub client_id: String,
    pub subject: String,
    pub email: Option<String>,
}

/// One signed-in session.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credentials {
    #[serde(rename = "clientID")]
    pub client_id: String,
    pub subject: String,
    pub email: Option<String>,
    pub id_token: String,
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix seconds.
    pub expires_at: i64,
    pub scopes: BTreeSet<String>,
}

impl Credentials {
    pub fn allows_plan_usage(&self) -> bool {
        self.scopes.contains(PLAN_SCOPE)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlanStatus {
    SignedOut {
        previous_email: Option<String>,
    },
    SignedIn {
        email: Option<String>,
        plan_usage: bool,
    },
}

impl PlanStatus {
    pub fn is_signed_in(&self) -> bool {
        matches!(self, PlanStatus::SignedIn { .. })
    }

    pub fn allows_plan_usage(&self) -> bool {
        matches!(
            self,
            PlanStatus::SignedIn {
                plan_usage: true,
                ..
            }
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlanModel {
    pub slug: String,
    pub display_name: String,
}

impl PlanModel {
    /// The token-sharing model list (`models` with `slug`, `display_name` and
    /// `visibility`), or the classic `data` list of ids.
    pub fn parse_list(body: &[u8]) -> Vec<PlanModel> {
        let Ok(json) = serde_json::from_slice::<Value>(body) else {
            return Vec::new();
        };
        if let Some(models) = json.get("models").and_then(Value::as_array) {
            return models
                .iter()
                .filter_map(|model| {
                    let slug = model.get("slug")?.as_str().filter(|s| !s.is_empty())?;
                    let visibility = model
                        .get("visibility")
                        .and_then(Value::as_str)
                        .unwrap_or("list");
                    (visibility == "list").then(|| PlanModel {
                        slug: slug.to_string(),
                        display_name: model
                            .get("display_name")
                            .and_then(Value::as_str)
                            .unwrap_or(slug)
                            .to_string(),
                    })
                })
                .collect();
        }
        json.get("data")
            .and_then(Value::as_array)
            .map(|entries| {
                entries
                    .iter()
                    .filter_map(|entry| entry.get("id").and_then(Value::as_str))
                    .map(|id| PlanModel {
                        slug: id.to_string(),
                        display_name: id.to_string(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}

// ----------------------------------------------------------------- account

#[derive(Clone, Debug, Default)]
struct Discovery {
    jwks: Option<String>,
    revocation: Option<String>,
}

/// Signs in with ChatGPT, keeps the session's tokens fresh, and signs out.
/// One shared instance serializes refreshes, so two requests never race a
/// rotating refresh token.
pub struct Account {
    /// `None`: the store the app installed ([`install_store`]).
    store: Option<Arc<dyn Store>>,
    endpoints: Endpoints,
    clock: fn() -> i64,
    refresh: Mutex<()>,
    discovery: Mutex<Option<Discovery>>,
    models: Mutex<Option<(String, Vec<PlanModel>, i64)>>,
    sign_in: Mutex<Option<Arc<AtomicBool>>>,
}

fn unix_now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// The account Think and Settings share.
pub fn shared() -> Arc<Account> {
    static SHARED: OnceLock<Arc<Account>> = OnceLock::new();
    SHARED
        .get_or_init(|| {
            Arc::new(Account {
                store: None,
                endpoints: Endpoints::default(),
                clock: unix_now,
                refresh: Mutex::new(()),
                discovery: Mutex::new(None),
                models: Mutex::new(None),
                sign_in: Mutex::new(None),
            })
        })
        .clone()
}

fn store_error(err: impl std::fmt::Display) -> anyhow::Error {
    PlanError::CredentialStoreUnavailable(err.to_string()).into()
}

impl Account {
    pub fn new(store: Arc<dyn Store>, endpoints: Endpoints) -> Self {
        Self::with_clock(store, endpoints, unix_now)
    }

    pub fn with_clock(store: Arc<dyn Store>, endpoints: Endpoints, clock: fn() -> i64) -> Self {
        Self {
            store: Some(store),
            endpoints,
            clock,
            refresh: Mutex::new(()),
            discovery: Mutex::new(None),
            models: Mutex::new(None),
            sign_in: Mutex::new(None),
        }
    }

    pub fn endpoints(&self) -> &Endpoints {
        &self.endpoints
    }

    fn store(&self) -> Result<Arc<dyn Store>> {
        self.store
            .clone()
            .or_else(|| INSTALLED_STORE.get().cloned())
            .ok_or_else(|| store_error("no credential store is set up"))
    }

    fn read<T: DeserializeOwned>(&self, account: &str) -> Result<Option<T>> {
        let stored = self.store()?.get(account).map_err(store_error)?;
        Ok(stored.and_then(|text| serde_json::from_str(&text).ok()))
    }

    /// Writes and reads back: a store that silently drops secrets must not
    /// look signed in.
    fn write<T: Serialize>(&self, account: &str, value: Option<&T>) -> Result<()> {
        let store = self.store()?;
        let text = value.map(serde_json::to_string).transpose()?;
        store.set(account, text.as_deref()).map_err(store_error)?;
        let kept = store.get(account).map_err(store_error)?;
        if kept != text {
            return Err(store_error("the credential store did not keep the sign-in"));
        }
        Ok(())
    }

    fn credentials(&self) -> Result<Option<Credentials>> {
        self.read(CREDENTIALS_ACCOUNT)
    }

    fn registration(&self) -> Result<Option<Registration>> {
        self.read(REGISTRATION_ACCOUNT)
    }

    /// An opaque per-PC id OpenAI uses to tell this host's sessions apart.
    /// Random, never derived from the account. Creating it also proves the
    /// credential store works before anything is signed in.
    pub fn host_id(&self) -> Result<String> {
        let store = self.store()?;
        if let Some(existing) = store
            .get(HOST_ACCOUNT)
            .map_err(store_error)?
            .filter(|id| !id.is_empty())
        {
            return Ok(existing);
        }
        let created = format!("urn:uuid:{}", uuid::Uuid::new_v4().hyphenated());
        store
            .set(HOST_ACCOUNT, Some(&created))
            .map_err(store_error)?;
        match store.get(HOST_ACCOUNT).map_err(store_error)? {
            Some(kept) if kept == created => Ok(created),
            _ => Err(store_error(
                "the credential store did not keep LokalBot's id",
            )),
        }
    }

    pub fn status(&self) -> Result<PlanStatus> {
        if let Some(credentials) = self.credentials()? {
            return Ok(PlanStatus::SignedIn {
                plan_usage: credentials.allows_plan_usage(),
                email: credentials.email,
            });
        }
        Ok(PlanStatus::SignedOut {
            previous_email: self.registration()?.and_then(|r| r.email),
        })
    }

    fn agent(&self, url: &str) -> ureq::Agent {
        http::agent(url, Duration::from_secs(60))
    }

    // ------------------------------------------------------------ sign-in

    /// Opens OpenAI's sign-in page and completes the authorization code
    /// exchange when the browser returns to the loopback listener. Blocks
    /// until then (at most five minutes) or [`cancel_sign_in`](Self::cancel_sign_in).
    /// `new_registration` registers again, for signing in to another account.
    pub fn sign_in(
        &self,
        new_registration: bool,
        open_browser: &dyn Fn(&str) -> Result<()>,
    ) -> Result<PlanStatus> {
        // Fail closed before the browser opens: no credential store, no sign-in.
        let host_id = self.host_id()?;
        let cancel = Arc::new(AtomicBool::new(false));
        if let Some(previous) = self.sign_in.lock().replace(cancel.clone()) {
            previous.store(true, Ordering::Relaxed);
        }
        let result = self.sign_in_with(new_registration, &host_id, open_browser, &cancel);
        let mut active = self.sign_in.lock();
        if active.as_ref().is_some_and(|a| Arc::ptr_eq(a, &cancel)) {
            *active = None;
        }
        result
    }

    fn sign_in_with(
        &self,
        new_registration: bool,
        host_id: &str,
        open_browser: &dyn Fn(&str) -> Result<()>,
        cancel: &AtomicBool,
    ) -> Result<PlanStatus> {
        let listener = LoopbackListener::start(PREFERRED_CALLBACK_PORT, CALLBACK_PATH)?;
        let registration = if new_registration {
            None
        } else {
            self.registration()?
        };
        let previous = self.credentials()?;
        let redirect = redirect_uri(listener.port());
        let request = AuthorizationRequest {
            client_id: registration.as_ref().map(|r| r.client_id.clone()),
            host_id: host_id.to_string(),
            redirect_uri: redirect.clone(),
            state: random_token(32),
            nonce: random_token(32),
            pkce: Pkce::new(),
            id_token_hint: previous
                .as_ref()
                .filter(|p| Some(&p.client_id) == registration.as_ref().map(|r| &r.client_id))
                .map(|p| p.id_token.clone()),
            login_hint: registration.as_ref().and_then(|r| r.email.clone()),
        };
        open_browser(&request.url(&self.endpoints)).map_err(|_| {
            PlanError::SignInFailed(
                "LokalBot couldn't open your browser for ChatGPT sign-in.".into(),
            )
        })?;
        let query = listener.wait_for_callback(SIGN_IN_TIMEOUT, cancel)?;
        let expected_client = registration.as_ref().map(|r| r.client_id.as_str());
        let CallbackOutcome::Code {
            code,
            client_id: returned,
        } = parse_callback(&query, &request.state, expected_client)?
        else {
            return Err(PlanError::SignInCancelled.into());
        };
        let Some(client_id) = registration
            .as_ref()
            .map(|r| r.client_id.clone())
            .or(returned.clone())
        else {
            return Err(PlanError::SignInFailed(
                "ChatGPT didn't return this app's registration. Try again.".into(),
            )
            .into());
        };
        // The registration is recorded before the exchange, so a failed
        // exchange never strands a client OpenAI already issued.
        if registration.is_none()
            && let Some(returned) = &returned
        {
            self.write(
                REGISTRATION_ACCOUNT,
                Some(&Registration {
                    client_id: returned.clone(),
                    subject: String::new(),
                    email: None,
                }),
            )?;
        }
        let reply = http::post_form(
            &self.agent(&self.endpoints.token),
            &self.endpoints.token,
            &[
                ("grant_type", "authorization_code"),
                ("client_id", &client_id),
                ("code", &code),
                ("code_verifier", &request.pkce.verifier),
                ("redirect_uri", &redirect),
                ("resource", &self.endpoints.resource),
            ],
        )?;
        if !reply.ok() {
            let code =
                oauth_error_code(&reply.body).unwrap_or_else(|| format!("HTTP {}", reply.status));
            return Err(PlanError::SignInFailed(format!(
                "ChatGPT sign-in couldn't be completed ({code}). Try again."
            ))
            .into());
        }
        let tokens = TokenResponse::parse(&reply.body)?;
        let Some(id_token) = tokens.id_token.clone() else {
            return Err(
                PlanError::SignInFailed("ChatGPT didn't return an ID token.".into()).into(),
            );
        };
        let keys = self.signing_keys()?;
        let now = (self.clock)();
        let claims = validate_id_token(
            &id_token,
            &keys,
            &self.endpoints.issuer,
            &client_id,
            &request.nonce,
            now,
        )?;
        if let Some(registration) = &registration
            && !registration.subject.is_empty()
            && registration.subject != claims.subject
        {
            return Err(PlanError::SignInFailed(
                "You signed in to a different ChatGPT account than this registration. Choose \"Use a different account\" to switch accounts.".into(),
            )
            .into());
        }
        let email = claims
            .email
            .clone()
            .or_else(|| registration.as_ref().and_then(|r| r.email.clone()));
        self.write(
            REGISTRATION_ACCOUNT,
            Some(&Registration {
                client_id: client_id.clone(),
                subject: claims.subject.clone(),
                email: email.clone(),
            }),
        )?;
        let credentials = Credentials {
            client_id,
            subject: claims.subject,
            email,
            id_token,
            access_token: tokens.access_token,
            refresh_token: tokens.refresh_token,
            expires_at: now + tokens.expires_in,
            scopes: tokens.scopes,
        };
        *self.models.lock() = None;
        self.write(CREDENTIALS_ACCOUNT, Some(&credentials))?;
        log::info!(
            "chatgpt plan signed in planUsage={}",
            credentials.allows_plan_usage()
        );
        self.status()
    }

    /// Stops a sign-in waiting for the browser.
    pub fn cancel_sign_in(&self) {
        if let Some(active) = self.sign_in.lock().take() {
            active.store(true, Ordering::Relaxed);
        }
    }

    /// Stops using the session, asks OpenAI to revoke it, and clears its
    /// tokens. The registration and host id stay for the next sign-in.
    /// Returns false when revocation could not be confirmed.
    pub fn sign_out(&self) -> bool {
        let _refresh = self.refresh.lock();
        *self.models.lock() = None;
        let Ok(Some(credentials)) = self.credentials() else {
            return true;
        };
        if self
            .write::<Credentials>(CREDENTIALS_ACCOUNT, None)
            .is_err()
        {
            return false;
        }
        let Some(refresh_token) = credentials.refresh_token else {
            return true;
        };
        for attempt in 0..3u32 {
            let Ok(discovery) = self.discovery() else {
                return false;
            };
            let Some(endpoint) = discovery.revocation else {
                return false;
            };
            match http::post_form(
                &self.agent(&endpoint),
                &endpoint,
                &[
                    ("token", &refresh_token),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", &credentials.client_id),
                ],
            ) {
                Ok(reply) if reply.ok() => return true,
                Ok(reply) if reply.status < 500 => return false,
                _ => {}
            }
            std::thread::sleep(Duration::from_secs(1 << attempt));
        }
        false
    }

    /// Forgets this PC's registration so the next sign-in registers anew.
    pub fn forget_registration(&self) -> bool {
        let confirmed = self.sign_out();
        let _ = self.write::<Registration>(REGISTRATION_ACCOUNT, None);
        confirmed
    }

    // ------------------------------------------------------------- tokens

    /// A current access token that may draw on the ChatGPT plan.
    pub fn access_token(&self) -> Result<String> {
        let Some(credentials) = self.credentials()? else {
            return Err(PlanError::SignedOut.into());
        };
        if !credentials.allows_plan_usage() {
            return Err(PlanError::PlanUsageNotGranted.into());
        }
        if credentials.expires_at > (self.clock)() + REFRESH_MARGIN_SECONDS {
            return Ok(credentials.access_token);
        }
        Ok(self.refreshed(&credentials.access_token)?.access_token)
    }

    /// A token the API rejected may have been revoked or rotated early.
    /// Refreshes once unless another caller already replaced it.
    pub fn access_token_after_rejection(&self, rejected: &str) -> Result<String> {
        Ok(self.refreshed(rejected)?.access_token)
    }

    /// Refreshes the session whose access token is `stale`. Refreshes are
    /// serialized; one that finds the token already replaced uses that.
    fn refreshed(&self, stale: &str) -> Result<Credentials> {
        let _refresh = self.refresh.lock();
        let Some(credentials) = self.credentials()? else {
            return Err(PlanError::SignedOut.into());
        };
        if credentials.access_token != stale {
            return Ok(credentials);
        }
        let Some(refresh_token) = credentials.refresh_token.clone() else {
            self.write::<Credentials>(CREDENTIALS_ACCOUNT, None)?;
            return Err(PlanError::SignInRequired.into());
        };
        let reply = http::post_form(
            &self.agent(&self.endpoints.token),
            &self.endpoints.token,
            &[
                ("grant_type", "refresh_token"),
                ("client_id", &credentials.client_id),
                ("refresh_token", &refresh_token),
                ("resource", &self.endpoints.resource),
            ],
        )?;
        if !reply.ok() {
            let code = oauth_error_code(&reply.body);
            if let Some(code) = code
                .as_deref()
                .filter(|c| TERMINAL_REFRESH_ERRORS.contains(c))
            {
                log::info!("chatgpt plan refresh rejected code={code}");
                // The session is over; the registration stays for sign-in.
                self.write::<Credentials>(CREDENTIALS_ACCOUNT, None)?;
                return Err(PlanError::SignInRequired.into());
            }
            if code.as_deref() == Some("invalid_client") {
                return Err(PlanError::Misconfigured(
                    "OpenAI rejected this app's registration (invalid_client).".into(),
                )
                .into());
            }
            return Err(reply.status_error().into());
        }
        let tokens = TokenResponse::parse(&reply.body)?;
        let mut next = credentials;
        next.access_token = tokens.access_token;
        // A rotating refresh token is replaced together with the access token.
        if let Some(refresh) = tokens.refresh_token {
            next.refresh_token = Some(refresh);
        }
        if let Some(id_token) = tokens.id_token {
            next.id_token = id_token;
        }
        if !tokens.scopes.is_empty() {
            next.scopes = tokens.scopes;
        }
        next.expires_at = (self.clock)() + tokens.expires_in;
        self.write(CREDENTIALS_ACCOUNT, Some(&next))?;
        Ok(next)
    }

    // ------------------------------------------------------------- models

    /// The signed-in account's models, fetched at most every ten minutes.
    pub fn models(&self, refresh: bool) -> Result<Vec<PlanModel>> {
        let Some(subject) = self.credentials()?.map(|c| c.subject) else {
            return Err(PlanError::SignedOut.into());
        };
        let now = (self.clock)();
        if !refresh
            && let Some((cached_subject, models, fetched)) = self.models.lock().as_ref()
            && *cached_subject == subject
            && now - fetched < MODEL_LIST_SECONDS
        {
            return Ok(models.clone());
        }
        let models = self.list_models()?;
        log::info!("chatgpt plan models count={}", models.len());
        *self.models.lock() = Some((subject, models.clone(), now));
        Ok(models)
    }

    fn list_models(&self) -> Result<Vec<PlanModel>> {
        let mut token = self.access_token()?;
        let url = format!("{}/models", self.endpoints.resource);
        for attempt in 0..2 {
            let reply = http::get(&self.agent(&url), &url, Some(&token))?;
            if reply.status == 401 && attempt == 0 {
                token = self.access_token_after_rejection(&token)?;
                continue;
            }
            if !reply.ok() {
                return Err(plan_failure(&reply));
            }
            return Ok(PlanModel::parse_list(&reply.body));
        }
        Err(PlanError::SignInRequired.into())
    }

    // ---------------------------------------------------------- discovery

    fn discovery(&self) -> Result<Discovery> {
        if let Some(cached) = self.discovery.lock().clone() {
            return Ok(cached);
        }
        let failed = || {
            anyhow::Error::from(PlanError::SignInFailed(
                "Couldn't read OpenAI's sign-in configuration. Try again.".into(),
            ))
        };
        let url = &self.endpoints.discovery;
        let reply = http::get(&self.agent(url), url, None).map_err(|_| failed())?;
        if !reply.ok() {
            return Err(failed());
        }
        let json = reply.json().map_err(|_| failed())?;
        let trusted = |key: &str| {
            json.get(key)
                .and_then(Value::as_str)
                .filter(|url| self.endpoints.trusted(url))
                .map(str::to_string)
        };
        let discovery = Discovery {
            jwks: trusted("jwks_uri"),
            revocation: trusted("revocation_endpoint"),
        };
        *self.discovery.lock() = Some(discovery.clone());
        Ok(discovery)
    }

    fn signing_keys(&self) -> Result<Vec<JsonWebKey>> {
        let Some(url) = self.discovery()?.jwks else {
            return Err(PlanError::SignInFailed(
                "OpenAI's sign-in configuration has no signing keys.".into(),
            )
            .into());
        };
        let reply = http::get(&self.agent(&url), &url, None)?;
        if !reply.ok() {
            return Err(PlanError::SignInFailed(
                "Couldn't read OpenAI's signing keys. Try again.".into(),
            )
            .into());
        }
        Ok(JsonWebKey::key_set(&reply.body))
    }
}

// ------------------------------------------------------------------ errors

fn error_object(body: &[u8]) -> (Option<String>, Option<String>, Option<String>) {
    let Ok(json) = serde_json::from_slice::<Value>(body) else {
        return (None, None, None);
    };
    let error = json.get("error").filter(|e| e.is_object()).unwrap_or(&json);
    let text = |value: Option<&Value>| value.and_then(Value::as_str).map(str::to_string);
    (
        text(error.get("code")),
        text(error.get("message")).or_else(|| text(json.get("detail"))),
        text(error.get("param")),
    )
}

/// The documented recovery for one plan error code: limits and eligibility
/// stop without retrying, temporary unavailability is retryable.
fn plan_error_for(
    code: Option<&str>,
    message: Option<&str>,
    param: Option<&str>,
) -> Option<anyhow::Error> {
    let detail: String = message
        .or(code)
        .unwrap_or_default()
        .chars()
        .take(300)
        .collect();
    Some(match code? {
        "subscription_sharing_usage_limit_exceeded" => PlanError::UsageLimitReached.into(),
        "subscription_sharing_user_not_eligible" => PlanError::NotEligible(detail).into(),
        "subscription_sharing_unsupported_capability" => {
            PlanError::UnsupportedRequest(param.map(str::to_string).unwrap_or(detail)).into()
        }
        "subscription_sharing_route_not_supported"
        | "chatpass_v2_scope_not_authorized"
        | "chatpass_v2_invalid_authorization_context" => PlanError::Misconfigured(detail).into(),
        "subscription_sharing_invalid_user" => PlanError::SignInRequired.into(),
        "subscription_sharing_usage_unavailable" | "subscription_sharing_user_unavailable" => {
            AiError::HttpStatus {
                code: 503,
                detail: "ChatGPT plan usage is temporarily unavailable".into(),
                retry_after: None,
            }
            .into()
        }
        _ => return None,
    })
}

fn plan_failure(reply: &http::Reply) -> anyhow::Error {
    let (code, message, param) = error_object(&reply.body);
    if let Some(mapped) = plan_error_for(code.as_deref(), message.as_deref(), param.as_deref()) {
        return mapped;
    }
    if reply.status == 401 {
        return PlanError::SignInRequired.into();
    }
    reply.status_error().into()
}

fn stream_failure(code: Option<&str>, message: Option<&str>, param: Option<&str>) -> anyhow::Error {
    plan_error_for(code, message, param).unwrap_or_else(|| {
        AiError::BadResponse(format!(
            "ChatGPT request failed: {}",
            message
                .or(code)
                .unwrap_or("unknown error")
                .chars()
                .take(600)
                .collect::<String>()
        ))
        .into()
    })
}

// ------------------------------------------------------------------ engine

/// Accumulates one Responses stream. Success requires `response.completed`;
/// an incomplete, failed, or cut-off stream fails.
#[derive(Default)]
pub(crate) struct StreamAccumulator {
    pub text: String,
    refusal: String,
    usage: Option<Usage>,
    /// `Some(false)` completed, `Some(true)` cut off at the output limit.
    pub outcome: Option<bool>,
}

impl StreamAccumulator {
    /// Feeds one SSE line; the new text, if any.
    pub fn consume(&mut self, line: &str) -> Result<Option<String>> {
        let Some(payload) = line.strip_prefix("data:").map(str::trim) else {
            return Ok(None);
        };
        if payload == "[DONE]" {
            return Ok(None);
        }
        let Ok(event) = serde_json::from_str::<Value>(payload) else {
            return Ok(None);
        };
        let usage_of = |response: Option<&Value>| {
            let usage = response.and_then(|r| r.get("usage"))?;
            Some(Usage {
                prompt_tokens: usage.get("input_tokens").and_then(Value::as_u64),
                completion_tokens: usage.get("output_tokens").and_then(Value::as_u64),
            })
        };
        match event.get("type").and_then(Value::as_str) {
            Some("response.output_text.delta") => {
                let delta = event
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if delta.is_empty() {
                    return Ok(None);
                }
                self.text.push_str(delta);
                return Ok(Some(delta.to_string()));
            }
            Some("response.refusal.delta") => {
                self.refusal.push_str(
                    event
                        .get("delta")
                        .and_then(Value::as_str)
                        .unwrap_or_default(),
                );
            }
            Some("response.completed") => {
                let response = event.get("response");
                self.usage = usage_of(response);
                if self.text.is_empty()
                    && let Some(output) = response
                        .and_then(|r| r.get("output"))
                        .and_then(Value::as_array)
                {
                    self.text = output_text(output);
                }
                self.outcome = Some(false);
            }
            Some("response.incomplete") => {
                let response = event.get("response");
                self.usage = usage_of(response);
                let reason = response
                    .and_then(|r| r.pointer("/incomplete_details/reason"))
                    .and_then(Value::as_str);
                if reason == Some("max_output_tokens") {
                    self.outcome = Some(true);
                } else {
                    return Err(AiError::BadResponse(format!(
                        "ChatGPT stopped early ({})",
                        reason.unwrap_or("incomplete")
                    ))
                    .into());
                }
            }
            Some("response.failed") => {
                let error = event.pointer("/response/error");
                let text = |key: &str| error.and_then(|e| e.get(key)).and_then(Value::as_str);
                return Err(stream_failure(text("code"), text("message"), text("param")));
            }
            Some("error") => {
                let error = event.get("error").unwrap_or(&event);
                let text = |key: &str| error.get(key).and_then(Value::as_str);
                return Err(stream_failure(text("code"), text("message"), text("param")));
            }
            _ => {}
        }
        Ok(None)
    }

    pub fn finish(self) -> Result<Completion> {
        if !self.refusal.is_empty() && self.text.is_empty() {
            return Err(AiError::BadResponse(format!(
                "model refusal: {}",
                self.refusal.chars().take(600).collect::<String>()
            ))
            .into());
        }
        match self.outcome {
            Some(false) if self.text.is_empty() => {
                Err(AiError::BadResponse("ChatGPT returned no text".into()).into())
            }
            Some(truncated) => Ok(Completion {
                text: if truncated {
                    model_json::visible_text_of_truncated(&self.text)
                } else {
                    model_json::strip_reasoning(&self.text)
                },
                truncated,
                cancelled: false,
                usage: self.usage,
            }),
            None => {
                Err(AiError::BadResponse("ChatGPT's stream ended before completion".into()).into())
            }
        }
    }
}

fn output_text(output: &[Value]) -> String {
    output
        .iter()
        .filter(|item| item.get("type").and_then(Value::as_str) == Some("message"))
        .filter_map(|item| item.get("content").and_then(Value::as_array))
        .flatten()
        .filter(|part| part.get("type").and_then(Value::as_str) == Some("output_text"))
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .collect()
}

/// Request fields a model or account may not accept. A rejection naming one
/// retries once without it; generation never started.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum OptionalField {
    Reasoning,
    TextFormat,
}

/// Think on the ChatGPT plan through the Responses API.
#[derive(Clone)]
pub(crate) struct Engine {
    pub model: String,
    pub level: ReasoningLevel,
    pub account: Arc<Account>,
}

impl Engine {
    pub fn reasoning_support(model: &str) -> ReasoningSupport {
        ReasoningSupport::known(Dialect::OpenAi, "", model)
    }

    fn effort(&self, request: &ChatRequest) -> Option<ReasoningLevel> {
        Self::reasoning_support(&self.model).request_level(self.level, request.reasoning_budget)
    }

    fn optional_fields(&self, request: &ChatRequest) -> BTreeSet<OptionalField> {
        let mut fields = BTreeSet::new();
        if self.effort(request).is_some() {
            fields.insert(OptionalField::Reasoning);
        }
        if request.json_schema.is_some() {
            fields.insert(OptionalField::TextFormat);
        }
        fields
    }

    /// Pure request construction, covered offline without a sign-in.
    fn body(&self, request: &ChatRequest, omitted: &BTreeSet<OptionalField>) -> Value {
        let mut content: Vec<Value> = request
            .context
            .iter()
            .filter(|text| !text.trim().is_empty())
            .map(|text| json!({"type": "input_text", "text": text}))
            .collect();
        if content.is_empty() || !request.user.trim().is_empty() {
            content.push(json!({"type": "input_text", "text": request.user}));
        }
        let mut body = json!({
            "model": self.model.trim(),
            "input": [{"type": "message", "role": "user", "content": content}],
            "store": false,
            "stream": true,
        });
        // System messages are rejected on this route; `instructions` is the
        // documented replacement.
        if !request.system.is_empty() {
            body["instructions"] = json!(request.system);
        }
        if let Some(schema) = &request.json_schema
            && !omitted.contains(&OptionalField::TextFormat)
        {
            body["text"] = json!({"format": {
                "type": "json_schema", "name": "response", "strict": true, "schema": schema,
            }});
        }
        if let Some(level) = self.effort(request)
            && !omitted.contains(&OptionalField::Reasoning)
        {
            body["reasoning"] = json!({"effort": effort_value(level)});
        }
        model_json::sort_keys(body)
    }

    /// One request, streamed. A revoked or early-rotated token gets one
    /// refresh; a rejected optional field one retry without it.
    pub fn respond(
        &self,
        request: &ChatRequest,
        cancel: Option<&AtomicBool>,
        on_delta: &mut dyn FnMut(&str),
    ) -> Result<Completion> {
        if self.model.trim().is_empty() {
            return Err(PlanError::NoModel(SubscriptionPlan::ChatGpt).into());
        }
        let mut omitted = BTreeSet::new();
        let mut token = self.account.access_token()?;
        let mut refreshed = false;
        loop {
            let body = self.body(request, &omitted);
            match self.stream_once(&body, &token, cancel, on_delta) {
                Err(err)
                    if !refreshed
                        && matches!(
                            err.downcast_ref::<PlanError>(),
                            Some(PlanError::SignInRequired)
                        ) =>
                {
                    refreshed = true;
                    token = self.account.access_token_after_rejection(&token)?;
                }
                Err(err) => {
                    let sent: BTreeSet<OptionalField> = self
                        .optional_fields(request)
                        .difference(&omitted)
                        .copied()
                        .collect();
                    let rejected = rejected_fields(&err, &sent);
                    if rejected.is_empty() {
                        return Err(err);
                    }
                    log::info!(
                        "chatgpt plan retry without={rejected:?} model={}",
                        self.model
                    );
                    omitted.extend(rejected);
                }
                ok => return ok,
            }
        }
    }

    fn stream_once(
        &self,
        body: &Value,
        token: &str,
        cancel: Option<&AtomicBool>,
        on_delta: &mut dyn FnMut(&str),
    ) -> Result<Completion> {
        let url = format!("{}/responses", self.account.endpoints.resource);
        let agent = http::agent(&url, REQUEST_TIMEOUT);
        let mut stream = http::post_stream(&agent, &url, Some(token), body)?;
        if let Some(error) = stream.error.take() {
            return Err(plan_failure(&error));
        }
        let mut accumulator = StreamAccumulator::default();
        while let Some(line) = stream.next_line(&url)? {
            if cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
                return Ok(Completion {
                    text: model_json::strip_reasoning(&accumulator.text),
                    truncated: false,
                    cancelled: true,
                    usage: None,
                });
            }
            if let Some(delta) = accumulator.consume(&line)? {
                on_delta(&delta);
            }
            if accumulator.outcome.is_some() {
                break;
            }
        }
        accumulator.finish()
    }
}

/// The optional fields a rejection names, limited to those the request sent.
fn rejected_fields(err: &anyhow::Error, sent: &BTreeSet<OptionalField>) -> BTreeSet<OptionalField> {
    let Some(PlanError::UnsupportedRequest(detail)) = err.downcast_ref::<PlanError>() else {
        return BTreeSet::new();
    };
    let detail = detail.to_lowercase();
    let mut rejected = BTreeSet::new();
    if detail.contains("reasoning") {
        rejected.insert(OptionalField::Reasoning);
    }
    if detail.contains("text") || detail.contains("format") {
        rejected.insert(OptionalField::TextFormat);
    }
    rejected.intersection(sent).copied().collect()
}

/// OpenAI's documented windows by model family; every model a ChatGPT plan
/// offers has at least 128K.
pub fn context_tokens(model: &str) -> u32 {
    let name = model.to_lowercase();
    if name.starts_with("gpt-4.1") {
        1_000_000
    } else {
        128_000
    }
}

pub mod relay;

#[cfg(test)]
mod tests;
