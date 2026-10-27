use std::io::{Read as _, Write as _};

use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};

use super::*;
use crate::http::testing::{Reply, StubServer};

/// Generated with `openssl genrsa 2048` and `openssl dgst -sha256 -sign`
/// (iss https://auth.openai.com, aud app_test, nonce nonce-rsa, exp 2100).
const RSA_N: &str = "x3wSp_UiRSf3C1M7THXy6A7ywi9kAVnVwbyd9lUFlfssxhfKX2JVLFDv50cArcM-rtXFb-ag4LrVIf4WItbEYyjAMUQcYnQ60GSId5h1e4DyEf8i8-IAjb1eBCHSurYG-DnigjQSMREZPgfXut_IphbCPSvwrNdIXz3k2f8v19nvWm1u2A9qspADXvisugzuUkEtLHzBKrT200Up3np-Ohqv1AeKUFhx4q582KpHmoeEobM2b3WTQ3B3L_mDZ79Q9cfW9S3aNt9kb71FcrzGSAu772XdEO2_ldhsrB6rFB-QaHR-egNsubT5YbY72eDOWA7Nrq5K17lt-T_oP4gK_w";
const RSA_TOKEN: &str = "eyJhbGciOiJSUzI1NiIsImtpZCI6InJzYS10ZXN0IiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2F1dGgub3BlbmFpLmNvbSIsImF1ZCI6WyJhcHBfdGVzdCJdLCJzdWIiOiJ1c2VyLXJzYSIsImVtYWlsIjoicnNhQGV4YW1wbGUuY29tIiwiZXhwIjo0MTAyNDQ0ODAwLCJub25jZSI6Im5vbmNlLXJzYSJ9.iNkEda91Th16MbXRnsJQetXG6QB_Px9fWhFqqlBcSmFjs5ExtN7rk4ArO0hjc5i8MQNLwJDooYlQ95R9fXD55WL6fJSKb6yucSbkTHgiZsWrw0q-qJJXhCutp1ySXeeQXcOvRgZ29uAfNCnC__ydDeRKLOMiT-qxtepQ98CbCnQ33rkGOmMOodFVaDS2UGTv1cYfzuMz9NfADBqbykPUt0_ADpqDqwQ14p0cZBYavY1H6KbJmS0RWEttb16AFe3-lBBWp5HUaEBrvwu3de6G6dlL1thj0uEulTZMh--kL8izq3SH-FP0Xa4JZ0eB4TTQursRPoPhk6aWV3i-UuxXTw";

const NOW: i64 = 1_800_000_000;

fn fixed_now() -> i64 {
    NOW
}

struct Signer {
    pair: EcdsaKeyPair,
}

impl Signer {
    fn new() -> Self {
        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        Self {
            pair: EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng)
                .unwrap(),
        }
    }

    fn jwks(&self) -> Value {
        let point = self.pair.public_key().as_ref();
        json!({"keys": [{
            "kty": "EC", "kid": "ec-test", "crv": "P-256",
            "x": URL_SAFE_NO_PAD.encode(&point[1..33]),
            "y": URL_SAFE_NO_PAD.encode(&point[33..65]),
        }]})
    }

    fn token(&self, payload: &Value) -> String {
        let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"ES256","kid":"ec-test"}"#);
        let body = URL_SAFE_NO_PAD.encode(payload.to_string());
        let input = format!("{header}.{body}");
        let rng = ring::rand::SystemRandom::new();
        let signature = self.pair.sign(&rng, input.as_bytes()).unwrap();
        format!("{input}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()))
    }
}

fn keys(signer: &Signer) -> Vec<JsonWebKey> {
    JsonWebKey::key_set(signer.jwks().to_string().as_bytes())
}

#[test]
fn pkce_matches_rfc_7636() {
    let pkce = Pkce::from_verifier("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk".into());
    assert_eq!(
        pkce.challenge,
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    );
    let fresh = Pkce::new();
    assert_eq!(fresh.verifier.len(), 64);
    assert_ne!(fresh.verifier, Pkce::new().verifier);
}

#[test]
fn authorization_urls_register_once_then_reuse_the_client() {
    let endpoints = Endpoints::default();
    let mut request = AuthorizationRequest {
        client_id: None,
        host_id: "urn:uuid:1234".into(),
        redirect_uri: redirect_uri(1455),
        state: "state-1".into(),
        nonce: "nonce-1".into(),
        pkce: Pkce::from_verifier("verifier".into()),
        id_token_hint: Some("old.id.token".into()),
        login_hint: None,
    };
    let first = request.url(&endpoints);
    assert!(first.starts_with("https://auth.openai.com/api/accounts/authorize?client_id=dynamic_agent_client&agent_name_hint=LokalBot&"));
    assert!(first.contains("&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&"));
    assert!(first.contains("&scope=openid%20profile%20email%20offline_access%20resource.invoke%20chatgpt.tokens.use.direct&"));
    assert!(first.contains("&resource=https%3A%2F%2Fapi.openai.com%2Fv1&"));
    assert!(first.contains("&ext_agent_host_id=urn%3Auuid%3A1234&"));
    assert!(first.contains("&code_challenge_method=S256&code_challenge="));
    // A first registration has no previous client to hint at.
    assert!(!first.contains("id_token_hint"));

    request.client_id = Some("app_issued".into());
    request.login_hint = Some("me+work@example.com".into());
    let again = request.url(&endpoints);
    assert!(again.contains("client_id=app_issued&ext_agent_host_id="));
    assert!(!again.contains("agent_name_hint"));
    assert!(again.contains("&id_token_hint=old.id.token"));
    assert!(again.ends_with("&login_hint=me%2Bwork%40example.com"));
}

#[test]
fn callbacks_check_state_first() {
    let query = |pairs: &[(&str, &str)]| -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    };
    // A forged request can neither complete nor cancel a sign-in.
    let forged = parse_callback(
        &query(&[("state", "x"), ("error", "access_denied")]),
        "s",
        None,
    );
    assert!(matches!(forged, Err(PlanError::SignInFailed(_))));
    assert_eq!(
        parse_callback(
            &query(&[("state", "s"), ("error", "access_denied")]),
            "s",
            None
        ),
        Ok(CallbackOutcome::Denied)
    );
    assert!(
        parse_callback(
            &query(&[
                ("state", "s"),
                ("error", "server_error"),
                ("error_description", "boom")
            ]),
            "s",
            None
        )
        .unwrap_err()
        .to_string()
        .contains("boom")
    );
    assert!(parse_callback(&query(&[("state", "s")]), "s", Some("app")).is_err());
    // A first registration needs the issued client id back.
    assert!(parse_callback(&query(&[("state", "s"), ("code", "c")]), "s", None).is_err());
    assert_eq!(
        parse_callback(
            &query(&[("state", "s"), ("code", "c"), ("client_id", "app_new")]),
            "s",
            None
        ),
        Ok(CallbackOutcome::Code {
            code: "c".into(),
            client_id: Some("app_new".into())
        })
    );
    assert!(
        parse_callback(
            &query(&[("state", "s"), ("code", "c"), ("client_id", "other")]),
            "s",
            Some("app")
        )
        .is_err()
    );
    assert_eq!(
        parse_callback(&query(&[("state", "s"), ("code", "c")]), "s", Some("app")),
        Ok(CallbackOutcome::Code {
            code: "c".into(),
            client_id: None
        })
    );
}

#[test]
fn id_tokens_need_a_good_signature_issuer_audience_expiry_and_nonce() {
    let rsa = JsonWebKey::key_set(
        json!({"keys": [{"kty": "RSA", "kid": "rsa-test", "n": RSA_N, "e": "AQAB"}]})
            .to_string()
            .as_bytes(),
    );
    let claims = validate_id_token(
        RSA_TOKEN,
        &rsa,
        "https://auth.openai.com",
        "app_test",
        "nonce-rsa",
        NOW,
    )
    .unwrap();
    assert_eq!(claims.subject, "user-rsa");
    assert_eq!(claims.email.as_deref(), Some("rsa@example.com"));
    // One flipped signature byte.
    let mut tampered = RSA_TOKEN.to_string();
    let last = tampered.pop().unwrap();
    tampered.push(if last == 'A' { 'B' } else { 'A' });
    assert!(
        validate_id_token(
            &tampered,
            &rsa,
            "https://auth.openai.com",
            "app_test",
            "nonce-rsa",
            NOW
        )
        .unwrap_err()
        .to_string()
        .contains("signature")
    );

    let signer = Signer::new();
    let payload = json!({
        "iss": "https://auth.openai.com", "aud": "app_ec", "sub": "user-ec",
        "exp": NOW + 3_600, "nonce": "n1", "email": "ec@example.com",
    });
    let token = signer.token(&payload);
    let keys = keys(&signer);
    let check = |token: &str, client: &str, nonce: &str, now: i64| {
        validate_id_token(token, &keys, "https://auth.openai.com", client, nonce, now)
    };
    assert_eq!(
        check(&token, "app_ec", "n1", NOW).unwrap().subject,
        "user-ec"
    );
    assert!(
        check(&token, "app_other", "n1", NOW)
            .unwrap_err()
            .to_string()
            .contains("audience")
    );
    assert!(
        check(&token, "app_ec", "n2", NOW)
            .unwrap_err()
            .to_string()
            .contains("nonce")
    );
    assert!(
        check(&token, "app_ec", "n1", NOW + 7_200)
            .unwrap_err()
            .to_string()
            .contains("expired")
    );
    let mut wrong_issuer = payload.clone();
    wrong_issuer["iss"] = json!("https://evil.example");
    assert!(
        check(&signer.token(&wrong_issuer), "app_ec", "n1", NOW)
            .unwrap_err()
            .to_string()
            .contains("issuer")
    );
    // Another key cannot vouch for it.
    let stranger = Signer::new();
    assert!(
        validate_id_token(
            &token,
            &self::keys(&stranger),
            "https://auth.openai.com",
            "app_ec",
            "n1",
            NOW
        )
        .is_err()
    );
    let none = format!(
        "{}.{}.",
        URL_SAFE_NO_PAD.encode(br#"{"alg":"none"}"#),
        URL_SAFE_NO_PAD.encode(payload.to_string())
    );
    assert!(
        check(&none, "app_ec", "n1", NOW)
            .unwrap_err()
            .to_string()
            .contains("algorithm")
    );
    assert!(check("not-a-token", "app_ec", "n1", NOW).is_err());
}

#[test]
fn token_responses_and_model_lists_parse() {
    let tokens = TokenResponse::parse(
        br#"{"access_token":"a","refresh_token":"r","id_token":"i","expires_in":120,"scope":"openid chatgpt.tokens.use.direct"}"#,
    )
    .unwrap();
    assert_eq!(tokens.expires_in, 120);
    assert!(tokens.scopes.contains(PLAN_SCOPE));
    assert!(TokenResponse::parse(br#"{"access_token":""}"#).is_err());
    assert_eq!(
        oauth_error_code(br#"{"error":"invalid_grant"}"#).as_deref(),
        Some("invalid_grant")
    );
    assert_eq!(
        oauth_error_code(br#"{"error":{"code":"x"}}"#).as_deref(),
        Some("x")
    );
    let models = PlanModel::parse_list(
        br#"{"models":[{"slug":"gpt-5.5","display_name":"GPT-5.5"},{"slug":"hidden","visibility":"hide"},{"slug":"gpt-5.4-mini"}]}"#,
    );
    assert_eq!(
        models,
        vec![
            PlanModel {
                slug: "gpt-5.5".into(),
                display_name: "GPT-5.5".into()
            },
            PlanModel {
                slug: "gpt-5.4-mini".into(),
                display_name: "gpt-5.4-mini".into()
            },
        ]
    );
    assert_eq!(
        PlanModel::parse_list(br#"{"data":[{"id":"gpt-5"}]}"#)[0].slug,
        "gpt-5"
    );
}

/// A store that cannot be reached, like a Linux session without a Secret
/// Service.
struct BrokenStore;

impl Store for BrokenStore {
    fn get(&self, _: &str) -> Result<Option<String>> {
        anyhow::bail!("no Secret Service answered")
    }

    fn set(&self, _: &str, _: Option<&str>) -> Result<()> {
        anyhow::bail!("no Secret Service answered")
    }
}

#[test]
fn sign_in_fails_closed_without_a_credential_store() {
    let account = Account::new(Arc::new(BrokenStore), Endpoints::default());
    let opened = AtomicBool::new(false);
    let err = account
        .sign_in(false, &|_| {
            opened.store(true, Ordering::SeqCst);
            Ok(())
        })
        .unwrap_err();
    assert!(matches!(
        err.downcast_ref::<PlanError>(),
        Some(PlanError::CredentialStoreUnavailable(_))
    ));
    assert!(!opened.load(Ordering::SeqCst), "the browser never opens");
    assert!(account.access_token().is_err());
    assert!(account.status().is_err());
}

struct Fixture {
    server: StubServer,
    account: Arc<Account>,
    store: Arc<MemoryStore>,
}

/// OpenAI's sign-in and API played by one local server. `token_reply`
/// answers the token endpoint; `api` answers `/v1/*`.
fn fixture(
    signer: Arc<Signer>,
    nonce: Arc<Mutex<String>>,
    api: impl Fn(&crate::http::testing::StubRequest) -> Reply + Send + Sync + 'static,
) -> Fixture {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let discovery_origin = origin.clone();
    let token_signer = signer.clone();
    let token_nonce = nonce.clone();
    let server = StubServer::start_on(listener, move |request| match request.path.as_str() {
        "/.well-known/openid-configuration" => Reply::Json(
            200,
            json!({
                "jwks_uri": format!("{discovery_origin}/jwks"),
                "revocation_endpoint": format!("{discovery_origin}/revoke"),
            }),
        ),
        "/jwks" => Reply::Json(200, token_signer.jwks()),
        "/token" => {
            let body = String::from_utf8_lossy(&request.body).to_string();
            if body.contains("grant_type=authorization_code") {
                let id_token = token_signer.token(&json!({
                    "iss": discovery_origin, "aud": "app_issued", "sub": "user-1",
                    "email": "me@example.com", "exp": NOW + 3_600,
                    "nonce": token_nonce.lock().clone(),
                }));
                Reply::Json(
                    200,
                    json!({
                        "access_token": "access-1", "refresh_token": "refresh-1",
                        "id_token": id_token, "expires_in": 3_600,
                        "scope": "openid email chatgpt.tokens.use.direct",
                    }),
                )
            } else if body.contains("refresh_token=refresh-1") {
                Reply::Json(
                    200,
                    json!({
                        "access_token": "access-2", "refresh_token": "refresh-2", "expires_in": 3_600,
                    }),
                )
            } else {
                Reply::Json(400, json!({"error": "invalid_grant"}))
            }
        }
        "/revoke" => Reply::Json(200, json!({})),
        _ => api(request),
    });
    let store = Arc::new(MemoryStore::default());
    let endpoints = Endpoints {
        issuer: origin.clone(),
        authorize: format!("{origin}/authorize"),
        token: format!("{origin}/token"),
        discovery: format!("{origin}/.well-known/openid-configuration"),
        resource: format!("{origin}/v1"),
        extra_trusted_origin: Some(origin.clone()),
    };
    let account = Arc::new(Account::with_clock(store.clone(), endpoints, fixed_now));
    Fixture {
        server,
        account,
        store,
    }
}

/// Plays the browser: reads the authorize URL, then calls the loopback
/// redirect the way OpenAI would after a successful sign-in.
fn browser(nonce: Arc<Mutex<String>>) -> impl Fn(&str) -> Result<()> {
    move |url: &str| {
        let query = super::super::loopback::query_of(&url[url.find('?').unwrap()..]);
        *nonce.lock() = query["nonce"].clone();
        let redirect = query["redirect_uri"].clone();
        let state = query["state"].clone();
        std::thread::spawn(move || {
            let authority = redirect
                .trim_start_matches("http://")
                .split('/')
                .next()
                .unwrap()
                .to_string();
            let mut stream = std::net::TcpStream::connect(authority).unwrap();
            write!(
                stream,
                "GET /auth/callback?code=code-1&state={state}&client_id=app_issued HTTP/1.1\r\nHost: x\r\n\r\n"
            )
            .unwrap();
            let mut reply = String::new();
            let _ = stream.read_to_string(&mut reply);
        });
        Ok(())
    }
}

#[test]
fn sign_in_registers_exchanges_with_pkce_and_keeps_tokens_in_the_store() {
    let signer = Arc::new(Signer::new());
    let nonce = Arc::new(Mutex::new(String::new()));
    let fx = fixture(signer, nonce.clone(), |_| Reply::Text(404, String::new()));
    let status = fx.account.sign_in(false, &browser(nonce)).unwrap();
    assert_eq!(
        status,
        PlanStatus::SignedIn {
            email: Some("me@example.com".into()),
            plan_usage: true
        }
    );
    let exchange = fx
        .server
        .requests()
        .into_iter()
        .find(|r| r.path == "/token")
        .unwrap();
    let form = String::from_utf8(exchange.body.clone()).unwrap();
    assert!(form.starts_with("client_id=app_issued&code=code-1&code_verifier="));
    assert!(form.contains("&grant_type=authorization_code&redirect_uri=http%3A%2F%2F127.0.0.1%3A"));
    assert_eq!(
        exchange.header("content-type").as_deref(),
        Some("application/x-www-form-urlencoded")
    );
    // Everything lives in the credential store, under the Mac's names.
    let saved: Credentials =
        serde_json::from_str(&fx.store.get(CREDENTIALS_ACCOUNT).unwrap().unwrap()).unwrap();
    assert_eq!(saved.access_token, "access-1");
    assert_eq!(saved.expires_at, NOW + 3_600);
    let registration: Registration =
        serde_json::from_str(&fx.store.get(REGISTRATION_ACCOUNT).unwrap().unwrap()).unwrap();
    assert_eq!(registration.client_id, "app_issued");
    assert_eq!(registration.subject, "user-1");
    assert!(
        fx.store
            .get(HOST_ACCOUNT)
            .unwrap()
            .unwrap()
            .starts_with("urn:uuid:")
    );
    assert_eq!(fx.account.access_token().unwrap(), "access-1");

    // Sign-out revokes the refresh token and keeps the registration.
    assert!(fx.account.sign_out());
    let revoke = fx
        .server
        .requests()
        .into_iter()
        .find(|r| r.path == "/revoke")
        .unwrap();
    assert!(
        String::from_utf8(revoke.body)
            .unwrap()
            .contains("token=refresh-1")
    );
    assert_eq!(
        fx.account.status().unwrap(),
        PlanStatus::SignedOut {
            previous_email: Some("me@example.com".into())
        }
    );
    assert!(matches!(
        fx.account
            .access_token()
            .unwrap_err()
            .downcast_ref::<PlanError>(),
        Some(PlanError::SignedOut)
    ));
}

fn signed_in(store: &MemoryStore, expires_at: i64, refresh: &str) {
    let credentials = Credentials {
        client_id: "app_issued".into(),
        subject: "user-1".into(),
        email: Some("me@example.com".into()),
        id_token: "id".into(),
        access_token: "access-1".into(),
        refresh_token: Some(refresh.into()),
        expires_at,
        scopes: [PLAN_SCOPE.to_string()].into_iter().collect(),
    };
    store
        .set(
            CREDENTIALS_ACCOUNT,
            Some(&serde_json::to_string(&credentials).unwrap()),
        )
        .unwrap();
}

#[test]
fn expiring_tokens_refresh_and_a_dead_refresh_token_signs_out() {
    let signer = Arc::new(Signer::new());
    let fx = fixture(signer, Arc::new(Mutex::new(String::new())), |_| {
        Reply::Text(404, String::new())
    });
    signed_in(&fx.store, NOW + 60, "refresh-1");
    assert_eq!(fx.account.access_token().unwrap(), "access-2");
    let saved: Credentials =
        serde_json::from_str(&fx.store.get(CREDENTIALS_ACCOUNT).unwrap().unwrap()).unwrap();
    assert_eq!(saved.refresh_token.as_deref(), Some("refresh-2"));
    // The rotated session keeps its plan grant.
    assert!(saved.allows_plan_usage());

    signed_in(&fx.store, NOW - 10, "refresh-dead");
    assert!(matches!(
        fx.account
            .access_token()
            .unwrap_err()
            .downcast_ref::<PlanError>(),
        Some(PlanError::SignInRequired)
    ));
    assert_eq!(fx.store.get(CREDENTIALS_ACCOUNT).unwrap(), None);
}

fn completed(text: &str) -> Vec<String> {
    vec![
        json!({"type": "response.created"}).to_string(),
        json!({"type": "response.output_text.delta", "delta": &text[..2]}).to_string(),
        json!({"type": "response.output_text.delta", "delta": &text[2..]}).to_string(),
        json!({"type": "response.completed", "response": {"usage": {"input_tokens": 12, "output_tokens": 3}}}).to_string(),
    ]
}

#[test]
fn responses_requests_stream_without_storage_or_sampling() {
    let signer = Arc::new(Signer::new());
    let fx = fixture(
        signer,
        Arc::new(Mutex::new(String::new())),
        |request| match request.path.as_str() {
            "/v1/responses" => Reply::Sse(completed("{\"ok\": true}")),
            "/v1/models" => Reply::Json(200, json!({"models": [{"slug": "gpt-5.5"}]})),
            _ => Reply::Text(404, String::new()),
        },
    );
    signed_in(&fx.store, NOW + 3_600, "refresh-1");
    let engine = Engine {
        model: "gpt-5.5".into(),
        level: ReasoningLevel::High,
        account: fx.account.clone(),
    };
    let mut request = ChatRequest::new("Be brief.", "Summarize.")
        .max_tokens(500)
        .temperature(0.2)
        .reasoning_budget(256)
        .json_schema(json!({"type": "object", "properties": {"ok": {"type": "boolean"}}, "required": ["ok"], "additionalProperties": false}));
    request.context = vec!["Transcript".into(), "  ".into()];
    let mut deltas = String::new();
    let completion = engine
        .respond(&request, None, &mut |d| deltas.push_str(d))
        .unwrap();
    assert_eq!(completion.text, "{\"ok\": true}");
    assert_eq!(deltas, "{\"ok\": true}");
    assert_eq!(completion.usage.unwrap().prompt_tokens, Some(12));
    let sent = fx
        .server
        .requests()
        .into_iter()
        .find(|r| r.path == "/v1/responses")
        .unwrap();
    assert_eq!(
        sent.header("authorization").as_deref(),
        Some("Bearer access-1")
    );
    let body = sent.json();
    assert_eq!(body["store"], false);
    assert_eq!(body["stream"], true);
    assert_eq!(body["instructions"], "Be brief.");
    assert_eq!(body["text"]["format"]["type"], "json_schema");
    assert_eq!(body["text"]["format"]["strict"], true);
    // The task budget caps the chosen level.
    assert_eq!(body["reasoning"]["effort"], "low");
    let content = body["input"][0]["content"].as_array().unwrap();
    assert_eq!(content.len(), 2, "blank context blocks are dropped");
    assert_eq!(content[0]["text"], "Transcript");
    assert_eq!(content[1]["text"], "Summarize.");
    for field in ["temperature", "max_output_tokens", "max_tokens"] {
        assert!(body.get(field).is_none(), "{field} is never sent");
    }
    assert_eq!(fx.account.models(false).unwrap()[0].slug, "gpt-5.5");
}

#[test]
fn rejected_tokens_refresh_once_and_unsupported_fields_are_dropped() {
    let signer = Arc::new(Signer::new());
    let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = calls.clone();
    let fx = fixture(
        signer,
        Arc::new(Mutex::new(String::new())),
        move |request| {
            if request.path != "/v1/responses" {
                return Reply::Text(404, String::new());
            }
            counter.fetch_add(1, Ordering::SeqCst);
            if request.header("authorization").as_deref() == Some("Bearer access-1") {
                return Reply::Json(401, json!({"error": {"message": "expired"}}));
            }
            if request.json().get("reasoning").is_some() {
                return Reply::Json(
                    400,
                    json!({"error": {"code": "subscription_sharing_unsupported_capability", "param": "reasoning.effort", "message": "nope"}}),
                );
            }
            Reply::Sse(completed("Hello"))
        },
    );
    signed_in(&fx.store, NOW + 3_600, "refresh-1");
    let engine = Engine {
        model: "gpt-5.5".into(),
        level: ReasoningLevel::Medium,
        account: fx.account.clone(),
    };
    let completion = engine
        .respond(&ChatRequest::new("s", "u"), None, &mut |_| {})
        .unwrap();
    assert_eq!(completion.text, "Hello");
    assert_eq!(calls.load(Ordering::SeqCst), 3);
}

#[test]
fn plan_limits_stop_without_another_provider() {
    let signer = Arc::new(Signer::new());
    let fx = fixture(signer, Arc::new(Mutex::new(String::new())), |request| {
        if request.path == "/v1/responses" {
            Reply::Json(
                429,
                json!({"error": {"code": "subscription_sharing_usage_limit_exceeded"}}),
            )
        } else {
            Reply::Text(404, String::new())
        }
    });
    signed_in(&fx.store, NOW + 3_600, "refresh-1");
    let engine = Engine {
        model: "gpt-5.5".into(),
        level: ReasoningLevel::Automatic,
        account: fx.account.clone(),
    };
    let err = engine
        .respond(&ChatRequest::new("s", "u"), None, &mut |_| {})
        .unwrap_err();
    assert!(matches!(
        err.downcast_ref::<PlanError>(),
        Some(PlanError::UsageLimitReached)
    ));
    let no_model = Engine {
        model: " ".into(),
        ..engine
    };
    assert!(matches!(
        no_model
            .respond(&ChatRequest::new("s", "u"), None, &mut |_| {})
            .unwrap_err()
            .downcast_ref::<PlanError>(),
        Some(PlanError::NoModel(SubscriptionPlan::ChatGpt))
    ));
}

#[test]
fn stream_accumulator_requires_completion() {
    let mut cut = StreamAccumulator::default();
    cut.consume(r#"data: {"type":"response.output_text.delta","delta":"par"}"#)
        .unwrap();
    assert!(
        cut.finish()
            .unwrap_err()
            .to_string()
            .contains("ended before completion")
    );
    let mut truncated = StreamAccumulator::default();
    truncated
        .consume(r#"data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#)
        .unwrap();
    assert!(truncated.finish().unwrap().truncated);
    let mut refused = StreamAccumulator::default();
    refused
        .consume(r#"data: {"type":"response.refusal.delta","delta":"No."}"#)
        .unwrap();
    refused
        .consume(r#"data: {"type":"response.completed","response":{}}"#)
        .unwrap();
    assert!(
        refused
            .finish()
            .unwrap_err()
            .to_string()
            .contains("refusal")
    );
    let mut whole = StreamAccumulator::default();
    whole
        .consume(r#"data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"All"}]}]}}"#)
        .unwrap();
    assert_eq!(whole.finish().unwrap().text, "All");
    let mut failed = StreamAccumulator::default();
    let err = failed
        .consume(r#"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_user_not_eligible","message":"Free plan"}}}"#)
        .unwrap_err();
    assert!(err.to_string().contains("Free plan"));
}

/// A store with Windows Credential Manager's item limit.
#[derive(Default)]
struct SmallItems(MemoryStore);

impl Store for SmallItems {
    fn get(&self, account: &str) -> Result<Option<String>> {
        self.0.get(account)
    }

    fn set(&self, account: &str, value: Option<&str>) -> Result<()> {
        if value.is_some_and(|v| v.encode_utf16().count() > 1_280) {
            anyhow::bail!("TooLong");
        }
        self.0.set(account, value)
    }
}

#[test]
fn long_sessions_are_split_for_small_credential_stores() {
    let store = Chunked::new(SmallItems::default());
    let long: String = "é".repeat(1_500) + &"x".repeat(1_700);
    store.set("creds", Some(&long)).unwrap();
    assert_eq!(store.get("creds").unwrap().as_deref(), Some(long.as_str()));
    assert_eq!(
        store.inner.get("creds").unwrap().as_deref(),
        Some("lokalbot-chunks:4")
    );
    // A shorter value replaces it and leaves no parts behind.
    store.set("creds", Some("short")).unwrap();
    assert_eq!(store.get("creds").unwrap().as_deref(), Some("short"));
    assert_eq!(store.inner.get("creds.1").unwrap(), None);
    store.set("creds", Some(&long)).unwrap();
    store.set("creds", None).unwrap();
    assert_eq!(store.get("creds").unwrap(), None);
    assert!((1..=4).all(|i| store.inner.get(&format!("creds.{i}")).unwrap().is_none()));
    // A missing part reads as nothing stored.
    store.set("creds", Some(&long)).unwrap();
    store.inner.set("creds.2", None).unwrap();
    assert_eq!(store.get("creds").unwrap(), None);

    // A whole signed-in session fits through it.
    let account = Account::with_clock(
        Arc::new(Chunked::new(SmallItems::default())),
        Endpoints::default(),
        fixed_now,
    );
    let credentials = Credentials {
        client_id: "app".into(),
        subject: "user".into(),
        email: None,
        id_token: "i".repeat(1_800),
        access_token: "a".repeat(2_400),
        refresh_token: Some("r".repeat(600)),
        expires_at: NOW + 3_600,
        scopes: [PLAN_SCOPE.to_string()].into_iter().collect(),
    };
    account
        .write(CREDENTIALS_ACCOUNT, Some(&credentials))
        .unwrap();
    assert_eq!(account.access_token().unwrap(), "a".repeat(2_400));
}
