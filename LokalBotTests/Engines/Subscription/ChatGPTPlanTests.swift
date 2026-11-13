import CryptoKit
import Security
import XCTest
@testable import LokalBot

final class ChatGPTPlanTests: XCTestCase {
    // MARK: Fixtures

    final class MemoryStore: ChatGPTPlanStore, @unchecked Sendable {
        private let lock = NSLock()
        private var storedRegistration: ChatGPTPlanRegistration?
        private var storedCredentials: ChatGPTPlanCredentials?

        init(registration: ChatGPTPlanRegistration? = nil, credentials: ChatGPTPlanCredentials? = nil) {
            storedRegistration = registration
            storedCredentials = credentials
        }

        func hostID() -> String { "urn:uuid:00000000-0000-4000-8000-000000000001" }
        func registration() -> ChatGPTPlanRegistration? { lock.withLock { storedRegistration } }
        func setRegistration(_ registration: ChatGPTPlanRegistration?) { lock.withLock { storedRegistration = registration } }
        func credentials() -> ChatGPTPlanCredentials? { lock.withLock { storedCredentials } }
        func setCredentials(_ credentials: ChatGPTPlanCredentials?) { lock.withLock { storedCredentials = credentials } }
    }

    actor RequestLog {
        private(set) var requests: [URLRequest] = []
        func append(_ request: URLRequest) -> Int {
            requests.append(request)
            return requests.count
        }
        func count(path: String) -> Int { requests.filter { $0.url?.path == path }.count }
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static let clientID = "oaiapp_test"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func credentials(expiresAt: Date = now.addingTimeInterval(3_600),
                            scopes: Set<String> = Set(ChatGPTPlanOAuth.scope.split(separator: " ").map(String.init)),
                            refreshToken: String? = "refresh-1") -> ChatGPTPlanCredentials {
        ChatGPTPlanCredentials(clientID: clientID, subject: "user-1", email: "ana@example.com",
                               idToken: "id-token", accessToken: "access-1", refreshToken: refreshToken,
                               expiresAt: expiresAt, scopes: scopes)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func response(_ request: URLRequest, _ status: Int) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    static func form(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            fields[parts[0]] = parts.count > 1 ? parts[1].removingPercentEncoding : ""
        }
        return fields
    }

    static func query(_ url: URL) -> [String: String] {
        var items: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            items[item.name] = item.value
        }
        return items
    }

    static func idToken(key: P256.Signing.PrivateKey, kid: String = "key-1", claims: [String: Any]) throws -> String {
        let header = ChatGPTPlanOAuth.base64URL(json(["alg": "ES256", "kid": kid, "typ": "JWT"]))
        let payload = ChatGPTPlanOAuth.base64URL(json(claims))
        let signature = try key.signature(for: Data("\(header).\(payload)".utf8))
        return "\(header).\(payload).\(ChatGPTPlanOAuth.base64URL(signature.rawRepresentation))"
    }

    static func keySet(_ key: P256.Signing.PublicKey, kid: String = "key-1") -> Data {
        let raw = key.rawRepresentation
        return json(["keys": [[
            "kty": "EC", "crv": "P-256", "kid": kid, "alg": "ES256",
            "x": ChatGPTPlanOAuth.base64URL(raw.prefix(32)),
            "y": ChatGPTPlanOAuth.base64URL(raw.suffix(32)),
        ]]])
    }

    static func claims(nonce: String, audience: String = clientID, expiry: Date = now.addingTimeInterval(3_600),
                       issuer: String = ChatGPTPlanOAuth.issuer) -> [String: Any] {
        ["iss": issuer, "aud": audience, "sub": "user-1", "email": "ana@example.com",
         "exp": Int(expiry.timeIntervalSince1970), "iat": Int(now.timeIntervalSince1970), "nonce": nonce]
    }

    // MARK: Authorization request

    func testFirstSignInRegistersWithDynamicClientAndRequestsPlanScope() {
        let request = ChatGPTPlanOAuth.AuthorizationRequest(
            clientID: nil, hostID: "urn:uuid:host", redirectURI: ChatGPTPlanOAuth.redirectURI(port: 1455),
            state: "state-1", nonce: "nonce-1", pkce: .init(verifier: "verifier"),
            idTokenHint: "old-id-token", loginHint: nil)
        let items = Self.query(request.url)

        XCTAssertEqual(request.url.host, "auth.openai.com")
        XCTAssertEqual(request.url.path, "/api/accounts/authorize")
        XCTAssertEqual(items["client_id"], "dynamic_agent_client")
        XCTAssertEqual(items["agent_name_hint"], "LokalBot")
        XCTAssertEqual(items["ext_agent_host_id"], "urn:uuid:host")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(items["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(items["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "state-1")
        XCTAssertEqual(items["nonce"], "nonce-1")
        // A first registration has no previous session to hint.
        XCTAssertNil(items["id_token_hint"])
        XCTAssertFalse(request.url.absoluteString.contains("127.0.0.1:1455/auth"),
                       "the redirect URI must be escaped inside the query")
    }

    func testReturningSignInUsesIssuedClientAndHints() {
        let request = ChatGPTPlanOAuth.AuthorizationRequest(
            clientID: "oaiapp_1", hostID: "urn:uuid:host", redirectURI: ChatGPTPlanOAuth.redirectURI(port: 54321),
            state: "s", nonce: "n", pkce: .init(verifier: "v"), idTokenHint: "id-1", loginHint: "ana+work@example.com")
        let items = Self.query(request.url)

        XCTAssertEqual(items["client_id"], "oaiapp_1")
        XCTAssertNil(items["agent_name_hint"])
        XCTAssertEqual(items["id_token_hint"], "id-1")
        XCTAssertEqual(items["login_hint"], "ana+work@example.com")
        XCTAssertTrue(request.url.absoluteString.contains("login_hint=ana%2Bwork%40example.com"))
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:54321/auth/callback")
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        let pkce = ChatGPTPlanOAuth.PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertNotEqual(ChatGPTPlanOAuth.PKCE().verifier, ChatGPTPlanOAuth.PKCE().verifier)
    }

    // MARK: Callback

    func testCallbackRejectsWrongStateBeforeAnythingElse() {
        XCTAssertThrowsError(try ChatGPTPlanOAuth.parseCallback(
            ["state": "other", "error": "access_denied"], expectedState: "s", expectedClientID: nil))
        XCTAssertThrowsError(try ChatGPTPlanOAuth.parseCallback(
            ["code": "c", "client_id": "oaiapp_1"], expectedState: "s", expectedClientID: nil))
    }

    func testCallbackOutcomes() throws {
        XCTAssertEqual(try ChatGPTPlanOAuth.parseCallback(
            ["state": "s", "error": "access_denied"], expectedState: "s", expectedClientID: nil), .denied)
        XCTAssertEqual(try ChatGPTPlanOAuth.parseCallback(
            ["state": "s", "code": "c", "client_id": "oaiapp_1"], expectedState: "s", expectedClientID: nil),
            .code("c", clientID: "oaiapp_1"))
        // Reauthorization may omit client_id.
        XCTAssertEqual(try ChatGPTPlanOAuth.parseCallback(
            ["state": "s", "code": "c"], expectedState: "s", expectedClientID: "oaiapp_1"),
            .code("c", clientID: nil))
        // A first registration must say which client was issued.
        XCTAssertThrowsError(try ChatGPTPlanOAuth.parseCallback(
            ["state": "s", "code": "c"], expectedState: "s", expectedClientID: nil))
        // A different client than the pending request's is rejected.
        XCTAssertThrowsError(try ChatGPTPlanOAuth.parseCallback(
            ["state": "s", "code": "c", "client_id": "oaiapp_2"], expectedState: "s", expectedClientID: "oaiapp_1"))
    }

    // MARK: Token requests

    func testCodeExchangeAndRefreshForms() {
        let exchange = ChatGPTPlanOAuth.codeExchangeRequest(
            code: "code-1", clientID: "oaiapp_1", verifier: "verifier-1",
            redirectURI: ChatGPTPlanOAuth.redirectURI(port: 1455))
        XCTAssertEqual(exchange.url, ChatGPTPlanOAuth.tokenURL)
        XCTAssertEqual(exchange.httpMethod, "POST")
        XCTAssertEqual(exchange.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(Self.form(exchange), [
            "grant_type": "authorization_code", "client_id": "oaiapp_1", "code": "code-1",
            "code_verifier": "verifier-1", "redirect_uri": "http://127.0.0.1:1455/auth/callback",
            "resource": "https://api.openai.com/v1",
        ])

        let refresh = ChatGPTPlanOAuth.refreshRequest(refreshToken: "r/+=", clientID: "oaiapp_1")
        XCTAssertEqual(Self.form(refresh), [
            "grant_type": "refresh_token", "client_id": "oaiapp_1", "refresh_token": "r/+=",
            "resource": "https://api.openai.com/v1",
        ])
        XCTAssertNil(Self.form(refresh)["scope"], "omitting scope keeps the whole grant")
    }

    func testTokenResponseParsesScopes() throws {
        let tokens = try ChatGPTPlanOAuth.TokenResponse(json: Self.json([
            "access_token": "a", "refresh_token": "r", "id_token": "i", "token_type": "Bearer",
            "expires_in": 3_600, "scope": "openid chatgpt.tokens.use.direct offline_access",
        ]))
        XCTAssertEqual(tokens.scopes, ["openid", "chatgpt.tokens.use.direct", "offline_access"])
        XCTAssertEqual(tokens.expiresIn, 3_600)
        XCTAssertThrowsError(try ChatGPTPlanOAuth.TokenResponse(json: Self.json(["token_type": "Bearer"])))
    }

    // MARK: ID token

    func testES256IDTokenValidation() throws {
        let key = P256.Signing.PrivateKey()
        let keys = ChatGPTIDToken.JSONWebKey.keySet(Self.keySet(key.publicKey))
        let token = try Self.idToken(key: key, claims: Self.claims(nonce: "n-1"))

        let claims = try ChatGPTIDToken.validate(token, keys: keys, clientID: Self.clientID, nonce: "n-1", now: Self.now)
        XCTAssertEqual(claims.subject, "user-1")
        XCTAssertEqual(claims.email, "ana@example.com")

        XCTAssertThrowsError(try ChatGPTIDToken.validate(token, keys: keys, clientID: Self.clientID,
                                                         nonce: "other", now: Self.now))
        XCTAssertThrowsError(try ChatGPTIDToken.validate(token, keys: keys, clientID: "oaiapp_other",
                                                         nonce: "n-1", now: Self.now))
        XCTAssertThrowsError(try ChatGPTIDToken.validate(token, keys: keys, clientID: Self.clientID,
                                                         nonce: "n-1", now: Self.now.addingTimeInterval(7_200)))
        let otherKey = ChatGPTIDToken.JSONWebKey.keySet(Self.keySet(P256.Signing.PrivateKey().publicKey))
        XCTAssertThrowsError(try ChatGPTIDToken.validate(token, keys: otherKey, clientID: Self.clientID,
                                                         nonce: "n-1", now: Self.now))
        let wrongIssuer = try Self.idToken(key: key, claims: Self.claims(nonce: "n-1", issuer: "https://example.com"))
        XCTAssertThrowsError(try ChatGPTIDToken.validate(wrongIssuer, keys: keys, clientID: Self.clientID,
                                                         nonce: "n-1", now: Self.now))
    }

    func testRS256IDTokenValidationAndKeyEncoding() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let (modulus, exponent) = try Self.rsaComponents(der)
        XCTAssertEqual(ChatGPTIDToken.rsaPublicKeyDER(modulus: modulus, exponent: exponent), der)

        let header = ChatGPTPlanOAuth.base64URL(Self.json(["alg": "RS256", "kid": "rsa-1"]))
        let payload = ChatGPTPlanOAuth.base64URL(Self.json(Self.claims(nonce: "n-2")))
        let input = Data("\(header).\(payload)".utf8)
        let signature = try XCTUnwrap(SecKeyCreateSignature(
            privateKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil) as Data?)
        let token = "\(header).\(payload).\(ChatGPTPlanOAuth.base64URL(signature))"
        let keys = ChatGPTIDToken.JSONWebKey.keySet(Self.json(["keys": [[
            "kty": "RSA", "kid": "rsa-1",
            "n": ChatGPTPlanOAuth.base64URL(modulus), "e": ChatGPTPlanOAuth.base64URL(exponent),
        ]]]))
        XCTAssertEqual(try ChatGPTIDToken.validate(token, keys: keys, clientID: Self.clientID,
                                                   nonce: "n-2", now: Self.now).subject, "user-1")
        var tampered = Array(token)
        tampered[tampered.count - 5] = tampered[tampered.count - 5] == "A" ? "B" : "A"
        XCTAssertThrowsError(try ChatGPTIDToken.validate(String(tampered), keys: keys, clientID: Self.clientID,
                                                         nonce: "n-2", now: Self.now))
    }

    /// Reads SEQUENCE { INTEGER n, INTEGER e } from a PKCS#1 public key.
    private static func rsaComponents(_ der: Data) throws -> (Data, Data) {
        var bytes = [UInt8](der)
        func readLength() -> Int {
            let first = bytes.removeFirst()
            guard first & 0x80 != 0 else { return Int(first) }
            var length = 0
            for _ in 0..<Int(first & 0x7f) { length = (length << 8) | Int(bytes.removeFirst()) }
            return length
        }
        func readInteger() -> Data {
            XCTAssertEqual(bytes.removeFirst(), 0x02)
            let length = readLength()
            let value = Data(bytes.prefix(length))
            bytes.removeFirst(length)
            return value
        }
        XCTAssertEqual(bytes.removeFirst(), 0x30)
        _ = readLength()
        return (readInteger(), readInteger())
    }

    // MARK: Account

    func testFreshTokenIsReusedAndMissingPlanScopeStopsInference() async throws {
        let log = RequestLog()
        let store = MemoryStore(credentials: Self.credentials())
        let account = ChatGPTPlanAccount(store: store, transport: { request in
            _ = await log.append(request)
            return (Data(), Self.response(request, 500))
        }, now: { Self.now })

        let token = try await account.accessToken()
        XCTAssertEqual(token, "access-1")
        let requestCount = await log.requests.count
        XCTAssertEqual(requestCount, 0)

        store.setCredentials(Self.credentials(scopes: ["openid", "email", "offline_access"]))
        do {
            _ = try await account.accessToken()
            XCTFail("a sign-in without the plan scope must not run inference")
        } catch ChatGPTPlanError.planUsageNotGranted {}
        let status = await account.status()
        XCTAssertEqual(status, .signedIn(email: "ana@example.com", planUsage: false))
    }

    func testConcurrentCallersShareOneRotatingRefresh() async throws {
        let log = RequestLog()
        let store = MemoryStore(credentials: Self.credentials(expiresAt: Self.now.addingTimeInterval(30)))
        let account = ChatGPTPlanAccount(store: store, transport: { request in
            _ = await log.append(request)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(Self.form(request)["refresh_token"], "refresh-1")
            return (Self.json(["access_token": "access-2", "refresh_token": "refresh-2", "expires_in": 3_600,
                               "token_type": "Bearer"]), Self.response(request, 200))
        }, now: { Self.now })

        async let first = account.accessToken()
        async let second = account.accessToken()
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["access-2", "access-2"])
        let refreshes = await log.count(path: "/api/accounts/oauth/token")
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(store.credentials()?.refreshToken, "refresh-2")
        XCTAssertEqual(store.credentials()?.expiresAt, Self.now.addingTimeInterval(3_600))
        // Scopes stay when the refresh response omits them.
        XCTAssertEqual(store.credentials()?.allowsPlanUsage, true)
    }

    func testTerminalRefreshErrorEndsSessionButKeepsRegistration() async throws {
        let registration = ChatGPTPlanRegistration(clientID: Self.clientID, subject: "user-1", email: "ana@example.com")
        let store = MemoryStore(registration: registration,
                                credentials: Self.credentials(expiresAt: Self.now.addingTimeInterval(-10)))
        let account = ChatGPTPlanAccount(store: store, transport: { request in
            (Self.json(["error": "refresh_token_reused"]), Self.response(request, 400))
        }, now: { Self.now })

        do {
            _ = try await account.accessToken()
            XCTFail("a reused refresh token must require a new sign-in")
        } catch ChatGPTPlanError.signInRequired {}
        XCTAssertNil(store.credentials())
        XCTAssertEqual(store.registration(), registration)
        let status = await account.status()
        XCTAssertEqual(status, .signedOut(previousEmail: "ana@example.com"))
    }

    func testTransientRefreshFailureKeepsCredentials() async throws {
        let store = MemoryStore(credentials: Self.credentials(expiresAt: Self.now.addingTimeInterval(-10)))
        let account = ChatGPTPlanAccount(store: store, transport: { request in
            (Data("{}".utf8), Self.response(request, 503))
        }, now: { Self.now })

        do {
            _ = try await account.accessToken()
            XCTFail("expected the 503 to surface")
        } catch let error as TextEngineError {
            XCTAssertTrue(error.isRetryable)
        }
        XCTAssertNotNil(store.credentials(), "temporary failures must not erase credentials")
    }

    func testSignOutRevokesRefreshTokenAndKeepsRegistration() async throws {
        let log = RequestLog()
        let registration = ChatGPTPlanRegistration(clientID: Self.clientID, subject: "user-1", email: "ana@example.com")
        let store = MemoryStore(registration: registration, credentials: Self.credentials())
        let account = ChatGPTPlanAccount(store: store, transport: { request in
            _ = await log.append(request)
            if request.url == ChatGPTPlanOAuth.discoveryURL {
                return (Self.json(["revocation_endpoint": "https://auth.openai.com/oauth/revoke",
                                   "jwks_uri": "https://auth.openai.com/.well-known/jwks.json"]),
                        Self.response(request, 200))
            }
            XCTAssertEqual(request.url?.absoluteString, "https://auth.openai.com/oauth/revoke")
            XCTAssertEqual(Self.form(request), ["token": "refresh-1", "token_type_hint": "refresh_token",
                                                "client_id": Self.clientID])
            return (Data(), Self.response(request, 200))
        }, now: { Self.now })

        let confirmed = await account.signOut()
        XCTAssertTrue(confirmed)
        XCTAssertNil(store.credentials())
        XCTAssertEqual(store.registration(), registration)
        let revocations = await log.count(path: "/oauth/revoke")
        XCTAssertEqual(revocations, 1)
    }

    func testRevocationEndpointMustBeOpenAIHost() async throws {
        let store = MemoryStore(credentials: Self.credentials())
        let log = RequestLog()
        let account = ChatGPTPlanAccount(store: store, transport: { request in
            _ = await log.append(request)
            return (Self.json(["revocation_endpoint": "https://example.com/revoke"]), Self.response(request, 200))
        }, now: { Self.now })

        let confirmed = await account.signOut()
        XCTAssertFalse(confirmed)
        XCTAssertNil(store.credentials())
        let hosts = await log.requests.compactMap { $0.url?.host }
        XCTAssertEqual(hosts, ["auth.openai.com"], "the refresh token must never reach another host")
    }

    func testModelListParsesTokenSharingShape() {
        let models = ChatGPTPlanModel.parseList(Self.json(["models": [
            ["slug": "gpt-6.1-sol", "display_name": "GPT-6.1 Sol", "visibility": "list"],
            ["slug": "hidden-model", "display_name": "Hidden", "visibility": "hide"],
        ]]))
        XCTAssertEqual(models, [ChatGPTPlanModel(slug: "gpt-6.1-sol", displayName: "GPT-6.1 Sol")])
        XCTAssertEqual(ChatGPTPlanModel.parseList(Self.json(["data": [["id": "gpt-5.2"]]])).map(\.slug), ["gpt-5.2"])
    }

    func testModelListIsSharedUntilItExpiresOrTheAccountChanges() async throws {
        let log = RequestLog()
        let clock = Box<Date>()
        clock.value = Self.now
        let store = MemoryStore(credentials: Self.credentials(expiresAt: Self.now.addingTimeInterval(86_400)))
        let account = ChatGPTPlanAccount(store: store, transport: { request in
            _ = await log.append(request)
            return (Self.json(["models": [["slug": "gpt-5.2", "display_name": "GPT-5.2"]]]), Self.response(request, 200))
        }, now: { clock.value ?? Self.now })

        _ = try await account.models()
        _ = try await account.models()
        var fetches = await log.count(path: "/v1/models")
        XCTAssertEqual(fetches, 1, "settings views share one fetch")

        clock.value = Self.now.addingTimeInterval(ChatGPTPlanAccount.modelListLifetime + 1)
        _ = try await account.models()
        _ = try await account.models(refresh: true)
        fetches = await log.count(path: "/v1/models")
        XCTAssertEqual(fetches, 3)

        store.setCredentials(nil)
        do {
            _ = try await account.models()
            XCTFail("a signed-out account has no models")
        } catch ChatGPTPlanError.signedOut {}
    }

    /// The whole browser round trip: the authorize URL opens, the "browser"
    /// returns to the loopback listener, the code is exchanged, and the ID
    /// token is checked against OpenAI's published key before anything is
    /// stored.
    func testSignInCompletesThroughLoopbackRedirect() async throws {
        let key = P256.Signing.PrivateKey()
        let store = MemoryStore()
        let nonce = Box<String>()
        let redirect = Box<String>()
        let account = ChatGPTPlanAccount(store: store, transport: { request in
            switch request.url?.absoluteString {
            case ChatGPTPlanOAuth.discoveryURL.absoluteString:
                return (Self.json(["jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
                                   "revocation_endpoint": "https://auth.openai.com/oauth/revoke"]),
                        Self.response(request, 200))
            case "https://auth.openai.com/.well-known/jwks.json":
                return (Self.keySet(key.publicKey), Self.response(request, 200))
            case ChatGPTPlanOAuth.tokenURL.absoluteString:
                let form = Self.form(request)
                XCTAssertEqual(form["client_id"], Self.clientID)
                XCTAssertEqual(form["code"], "code-1")
                XCTAssertEqual(form["redirect_uri"], redirect.value)
                XCTAssertNotNil(form["code_verifier"])
                let idToken = try Self.idToken(key: key, claims: Self.claims(
                    nonce: nonce.value ?? "", expiry: Date().addingTimeInterval(3_600)))
                return (Self.json(["access_token": "access-1", "refresh_token": "refresh-1", "id_token": idToken,
                                   "token_type": "Bearer", "expires_in": 3_600,
                                   "scope": ChatGPTPlanOAuth.scope]), Self.response(request, 200))
            default:
                XCTFail("unexpected request \(request.url?.absoluteString ?? "")")
                return (Data(), Self.response(request, 404))
            }
        })

        let status = try await account.signIn { url in
            let items = Self.query(url)
            nonce.value = items["nonce"]
            redirect.value = items["redirect_uri"]
            guard let redirectURI = items["redirect_uri"], let state = items["state"],
                  let callback = URL(string: "\(redirectURI)?code=code-1&state=\(state)&client_id=\(Self.clientID)")
            else { return false }
            Task.detached {
                // A stray request first, as a browser's favicon fetch would be.
                if let favicon = URL(string: redirectURI.replacingOccurrences(of: "/auth/callback", with: "/favicon.ico")) {
                    _ = try? await URLSession.shared.data(from: favicon)
                }
                _ = try? await URLSession.shared.data(from: callback)
            }
            return true
        }

        XCTAssertEqual(status, .signedIn(email: "ana@example.com", planUsage: true))
        XCTAssertEqual(store.registration(),
                       ChatGPTPlanRegistration(clientID: Self.clientID, subject: "user-1", email: "ana@example.com"))
        XCTAssertEqual(store.credentials()?.accessToken, "access-1")
        XCTAssertEqual(store.credentials()?.refreshToken, "refresh-1")
        XCTAssertTrue(redirect.value?.hasPrefix("http://127.0.0.1:") == true)
    }

    // MARK: Engine

    private func engine(level: ThinkReasoningLevel = .automatic, model: String = "gpt-5.2",
                        store: MemoryStore = MemoryStore(credentials: credentials()),
                        accountTransport: @escaping ChatGPTPlanAccount.Transport = { request in
                            (Data(), ChatGPTPlanTests.response(request, 500))
                        },
                        transport: ChatGPTPlanEngine.Transport? = nil) -> ChatGPTPlanEngine {
        let account = ChatGPTPlanAccount(store: store, transport: accountTransport, now: { Self.now })
        return ChatGPTPlanEngine(model: model, account: account, reasoningLevel: level, transport: transport)
    }

    private static func sse(_ events: [[String: Any]]) -> Data {
        Data(events.map { "event: \($0["type"] as? String ?? "")\ndata: \(String(decoding: json($0), as: UTF8.self))\n\n" }
            .joined().utf8)
    }

    private static func completedStream(_ text: String) -> Data {
        sse([
            ["type": "response.created", "response": ["id": "resp_1"]],
            ["type": "response.output_text.delta", "delta": String(text.prefix(3))],
            ["type": "response.output_text.delta", "delta": String(text.dropFirst(3))],
            ["type": "response.completed", "response": [
                "status": "completed",
                "usage": ["input_tokens": 120, "output_tokens": 8,
                          "input_tokens_details": ["cached_tokens": 64],
                          "output_tokens_details": ["reasoning_tokens": 0]],
            ]],
        ])
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testRequestFollowsTokenSharingRules() throws {
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["title"],
            "properties": ["title": ["type": "string"]],
        ]
        let request = try engine().makeRequest(
            system: "Write notes.", prompt: "Summarize.", context: ["Transcript A", "  "],
            schema: schema, options: .init(maxTokens: 900, reasoningBudgetTokens: 0, temperature: 0.2),
            accessToken: "access-1")
        let body = try body(request)

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["instructions"] as? String, "Write notes.")
        XCTAssertEqual(body["model"] as? String, "gpt-5.2")
        for unsupported in ["temperature", "top_p", "max_output_tokens", "previous_response_id", "metadata",
                            "user", "truncation", "background", "prompt_cache_retention"] {
            XCTAssertNil(body[unsupported], "\(unsupported) is rejected on the plan route")
        }
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user", "system messages are rejected; use instructions")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.compactMap { $0["text"] as? String }, ["Transcript A", "Summarize."])
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        // A task tuned for no reasoning stays at the model's lowest level.
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
    }

    func testAutomaticLeavesReasoningToTheModelForOpenTasks() throws {
        let body = try body(engine().makeRequest(system: "", prompt: "Hi", context: [], schema: nil,
                                                 options: nil, accessToken: "t"))
        XCTAssertNil(body["reasoning"])
        XCTAssertNil(body["instructions"])
        XCTAssertNil(body["text"])
    }

    /// GPT-6.1 Sol used to have no known levels, so the High the user chose
    /// was dropped and every plan request ran at the model's default.
    func testGPT6RequestsCarryTheChosenLevel() throws {
        func effort(_ model: String, _ level: ThinkReasoningLevel, taskBudget: Int? = nil) throws -> String? {
            let request = try engine(level: level, model: model).makeRequest(
                system: "", prompt: "Hi", context: [], schema: nil,
                options: taskBudget.map { .init(reasoningBudgetTokens: $0) }, accessToken: "t")
            return (try body(request)["reasoning"] as? [String: Any])?["effort"] as? String
        }
        XCTAssertEqual(try effort("gpt-6.1-sol", .high), "high")
        XCTAssertEqual(try effort("gpt-6.1-sol", .max), "max")
        XCTAssertEqual(try effort("gpt-6.1-sol", .high, taskBudget: 0), "low", "6.1 Sol rejects none")
        XCTAssertEqual(try effort("gpt-6-luna", .high, taskBudget: 0), "none")
        XCTAssertNil(try effort("gpt-6.1-sol", .automatic))
        XCTAssertEqual(engine(model: "gpt-6.1-sol").minimumStructuredOutputTokens, 2_048,
                       "reasoning cannot be switched off")
    }

    func testRejectsNonStrictSchemaBeforeSpendingPlanUsage() {
        XCTAssertThrowsError(try engine().makeRequest(
            system: "", prompt: "Hi", context: [], schema: ["type": "object", "properties": ["a": ["type": "string"]]],
            options: nil, accessToken: "t"))
    }

    func testStreamedReplyAndUsage() async throws {
        let reply = try await engine(transport: { request in
            (Self.completedStream("Hello there"), Self.response(request, 200))
        }).generate(system: "s", prompt: "p", context: [])
        XCTAssertEqual(reply, "Hello there")
    }

    func testCompletedResponseWithoutDeltasUsesOutputItems() throws {
        var accumulator = ChatGPTPlanEngine.StreamAccumulator()
        let line = "data: " + String(decoding: Self.json(["type": "response.completed", "response": [
            "output": [["type": "message", "content": [["type": "output_text", "text": "{\"a\":1}"]]]],
        ]]), as: UTF8.self)
        _ = try accumulator.consume(line)
        XCTAssertEqual(try accumulator.finish().text, "{\"a\":1}")
    }

    func testStreamCutBeforeCompletionFails() async throws {
        let partial = Self.sse([["type": "response.output_text.delta", "delta": "Hel"]])
        do {
            _ = try await engine(transport: { request in (partial, Self.response(request, 200)) })
                .generate(system: "", prompt: "p", context: [])
            XCTFail("a stream without response.completed is not a success")
        } catch let error as TextEngineError {
            guard case .badResponse = error else { return XCTFail("\(error)") }
        }
    }

    func testIncompleteAtOutputLimitIsTruncation() async throws {
        let stream = Self.sse([
            ["type": "response.output_text.delta", "delta": "{\"a\":"],
            ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]],
        ])
        do {
            _ = try await engine(transport: { request in (stream, Self.response(request, 200)) })
                .generate(system: "", prompt: "p", context: [])
            XCTFail("expected truncation")
        } catch TextEngineError.outputTruncated {}
    }

    func testUsageLimitStopsWithoutRetryOrFallback() async throws {
        let log = RequestLog()
        let failedMidStream = Self.sse([
            ["type": "response.output_text.delta", "delta": "Par"],
            ["type": "response.failed", "response": ["error": [
                "code": "subscription_sharing_usage_limit_exceeded", "message": "limit"]]],
        ])
        let base = engine(transport: { request in
            _ = await log.append(request)
            return (failedMidStream, Self.response(request, 200))
        })
        let gated = GatedTextEngine(base: base, origin: SubscriptionPlan.chatGPT.consentKey,
                                    priority: .pipeline, purpose: "test", gate: RemoteInferenceGate(),
                                    sleep: { _ in })
        do {
            _ = try await gated.generate(system: "", prompt: "p", context: [])
            XCTFail("expected the usage limit")
        } catch ChatGPTPlanError.usageLimitReached {}
        let attempts = await log.requests.count
        XCTAssertEqual(attempts, 1, "a plan limit must not be replayed")

        let status429 = ChatGPTPlanEngine.planError(
            status: 429, data: Self.json(["error": ["code": "subscription_sharing_usage_limit_exceeded"]]),
            response: nil)
        XCTAssertEqual(status429 as? ChatGPTPlanError, .usageLimitReached)
    }

    func testTemporaryUnavailabilityIsRetryable() {
        let error = ChatGPTPlanEngine.planError(
            status: 503, data: Self.json(["error": ["code": "subscription_sharing_usage_unavailable"]]), response: nil)
        XCTAssertEqual((error as? TextEngineError)?.isRetryable, true)
        let notEligible = ChatGPTPlanEngine.planError(
            status: 403, data: Self.json(["error": ["code": "subscription_sharing_user_not_eligible",
                                                    "message": "region"]]), response: nil)
        guard case .notEligible? = notEligible as? ChatGPTPlanError else { return XCTFail("\(notEligible)") }
    }

    func testUnsupportedReasoningRetriesOnceWithoutIt() async throws {
        let log = RequestLog()
        let reply = try await engine(level: .high, transport: { request in
            let count = await log.append(request)
            if count == 1 {
                return (Self.json(["error": ["code": "subscription_sharing_unsupported_capability",
                                             "param": "reasoning.effort"]]), Self.response(request, 400))
            }
            return (Self.completedStream("Answer"), Self.response(request, 200))
        }).generate(system: "", prompt: "p", context: [])
        XCTAssertEqual(reply, "Answer")
        let requests = await log.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(try body(requests[0])["reasoning"])
        XCTAssertNil(try body(requests[1])["reasoning"])
    }

    func testRejectedTokenRefreshesOnceThenRetries() async throws {
        let log = RequestLog()
        let store = MemoryStore(credentials: Self.credentials())
        let reply = try await engine(store: store, accountTransport: { request in
            (Self.json(["access_token": "access-2", "refresh_token": "refresh-2", "expires_in": 3_600]),
             Self.response(request, 200))
        }, transport: { request in
            let count = await log.append(request)
            if count == 1 { return (Self.json(["detail": "expired"]), Self.response(request, 401)) }
            return (Self.completedStream("Fresh"), Self.response(request, 200))
        }).generate(system: "", prompt: "p", context: [])
        XCTAssertEqual(reply, "Fresh")
        let tokens = await log.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(tokens, ["Bearer access-1", "Bearer access-2"])
    }

    func testSignedOutEngineNeverSendsARequest() async throws {
        let log = RequestLog()
        do {
            _ = try await engine(store: MemoryStore(), transport: { request in
                _ = await log.append(request)
                return (Data(), Self.response(request, 200))
            }).generate(system: "", prompt: "p", context: [])
            XCTFail("expected sign-in error")
        } catch ChatGPTPlanError.signedOut {}
        let count = await log.requests.count
        XCTAssertEqual(count, 0)
    }
}
