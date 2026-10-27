import XCTest
@testable import LokalBot

final class GmailOAuthTests: XCTestCase {
    private typealias Fixtures = GmailFixtures

    // MARK: Requests

    func testAuthorizationAsksOnlyForReadOnlyGmailWithPKCE() throws {
        let pkce = ChatGPTPlanOAuth.PKCE(verifier: "verifier")
        let request = GmailOAuth.AuthorizationRequest(
            client: Fixtures.client, redirectURI: GmailOAuth.redirectURI(port: 53_100),
            state: "state-1", pkce: pkce, loginHint: "me+work@example.com")
        let items = Fixtures.query(request.url)

        XCTAssertEqual(request.url.host, "accounts.google.com")
        XCTAssertEqual(items["scope"], ["https://www.googleapis.com/auth/gmail.readonly"])
        XCTAssertEqual(items["client_id"], [Fixtures.client.clientID])
        XCTAssertEqual(items["redirect_uri"], ["http://127.0.0.1:53100/"])
        XCTAssertEqual(items["code_challenge"], [pkce.challenge])
        XCTAssertEqual(items["code_challenge_method"], ["S256"])
        XCTAssertEqual(items["access_type"], ["offline"])
        XCTAssertEqual(items["prompt"], ["consent"])
        XCTAssertEqual(items["state"], ["state-1"])
        XCTAssertEqual(items["login_hint"], ["me+work@example.com"])
        // "+" must arrive as itself, not as a space.
        XCTAssertTrue(request.url.absoluteString.contains("login_hint=me%2Bwork%40example.com"))
        XCTAssertFalse(items.keys.contains("client_secret"))
    }

    func testTokenRequestsCarryTheDesktopClientSecret() {
        let redirect = GmailOAuth.redirectURI(port: 53_100)
        let exchange = Fixtures.form(GmailOAuth.codeExchangeRequest(
            code: "code-1", client: Fixtures.client, verifier: "verifier", redirectURI: redirect))
        XCTAssertEqual(exchange, [
            "grant_type": "authorization_code", "code": "code-1", "client_id": Fixtures.client.clientID,
            "client_secret": "test-secret", "code_verifier": "verifier", "redirect_uri": "http://127.0.0.1:53100/",
        ])
        let refresh = Fixtures.form(GmailOAuth.refreshRequest(refreshToken: "refresh-1", client: Fixtures.client))
        XCTAssertEqual(refresh, [
            "grant_type": "refresh_token", "refresh_token": "refresh-1",
            "client_id": Fixtures.client.clientID, "client_secret": "test-secret",
        ])
        let revoke = GmailOAuth.revocationRequest(token: "refresh-1")
        XCTAssertEqual(revoke.url, GmailOAuth.revokeURL)
        XCTAssertEqual(revoke.httpMethod, "POST")
        XCTAssertEqual(Fixtures.form(revoke), ["token": "refresh-1"])
    }

    // MARK: Callback

    func testCallbackChecksStateBeforeAnythingElse() {
        XCTAssertThrowsError(try GmailOAuth.parseCallback(["state": "forged", "error": "access_denied"],
                                                          expectedState: "state-1"))
        XCTAssertThrowsError(try GmailOAuth.parseCallback(["code": "code-1"], expectedState: "state-1"))
    }

    func testCallbackOutcomes() throws {
        XCTAssertEqual(try GmailOAuth.parseCallback(["state": "s", "error": "access_denied"], expectedState: "s"),
                       .denied)
        XCTAssertEqual(try GmailOAuth.parseCallback(
            ["state": "s", "code": "code-1", "scope": GmailOAuth.scope], expectedState: "s"), .code("code-1"))
        XCTAssertEqual(try GmailOAuth.parseCallback(
            ["state": "s", "code": "code-1", "scope": "openid+\(GmailOAuth.scope)"], expectedState: "s"),
                       .code("code-1"))
        XCTAssertThrowsError(try GmailOAuth.parseCallback(["state": "s", "code": ""], expectedState: "s"))
        // Google's consent screen lets the person untick Gmail and still returns a code.
        XCTAssertThrowsError(try GmailOAuth.parseCallback(
            ["state": "s", "code": "code-1", "scope": "openid email"], expectedState: "s")) { error in
            XCTAssertEqual(error as? GmailError, .readAccessNotGranted)
        }
    }

    func testTokenResponseKnowsWhetherReadAccessWasGranted() throws {
        let granted = try GmailOAuth.TokenResponse(json: Fixtures.json([
            "access_token": "a", "refresh_token": "r", "expires_in": 3_599, "scope": GmailOAuth.scope,
        ]))
        XCTAssertTrue(granted.grantsReadAccess)
        XCTAssertEqual(granted.expiresIn, 3_599)
        let other = try GmailOAuth.TokenResponse(json: Fixtures.json(["access_token": "a", "scope": "openid"]))
        XCTAssertFalse(other.grantsReadAccess)
        XCTAssertNil(other.refreshToken)
        XCTAssertThrowsError(try GmailOAuth.TokenResponse(json: Fixtures.json(["error": "invalid_grant"])))
    }

    // MARK: LokalBot's own client

    static let builtIn = GoogleOAuthClient.builtIn(id: "123456789-lokalbot.apps.googleusercontent.com")!

    func testLokalBotsClientHasNoSecretAndReturnsThroughItsOwnScheme() {
        let client = Self.builtIn
        XCTAssertNil(client.clientSecret)
        XCTAssertTrue(client.returnsToApp)
        XCTAssertEqual(client.appURLScheme, "com.googleusercontent.apps.123456789-lokalbot")
        XCTAssertEqual(client.appRedirectURI.absoluteString, "com.googleusercontent.apps.123456789-lokalbot:/oauth2redirect")
        let refresh = Fixtures.form(GmailOAuth.refreshRequest(refreshToken: "r", client: client))
        XCTAssertEqual(refresh, ["grant_type": "refresh_token", "refresh_token": "r",
                                 "client_id": "123456789-lokalbot.apps.googleusercontent.com"])
        XCTAssertFalse(Fixtures.client.returnsToApp, "an imported Desktop client keeps the loopback redirect")
    }

    func testOnlyARealClientIDCountsAsBuiltIn() {
        XCTAssertNil(GoogleOAuthClient.builtIn(id: nil))
        XCTAssertNil(GoogleOAuthClient.builtIn(id: ""))
        XCTAssertNil(GoogleOAuthClient.builtIn(id: ".apps.googleusercontent.com"))
        XCTAssertNil(GoogleOAuthClient.builtIn(id: "$(LOKALBOT_GOOGLE_CLIENT_ID)"))
        XCTAssertNil(GoogleOAuthClient.builtIn(id: "evil.example.com"))
        XCTAssertNotNil(GoogleOAuthClient.builtIn(id: " 1-a.apps.googleusercontent.com "))
    }

    func testSignInWithLokalBotsClientReturnsThroughTheSheet() async throws {
        let client = Self.builtIn
        let server = FakeGmailServer()
        let authorizer = GmailAuthorizer(
            secrets: MemoryEmailSecrets(client: nil), builtInClient: client,
            presentAppRedirect: { url, scheme in
                XCTAssertEqual(scheme, client.appURLScheme)
                let items = Fixtures.query(url)
                XCTAssertEqual(url.host, "accounts.google.com")
                XCTAssertEqual(items["client_id"], [client.clientID])
                XCTAssertEqual(items["redirect_uri"], [client.appRedirectURI.absoluteString])
                XCTAssertEqual(items["scope"], [GmailOAuth.scope])
                let state = items["state"]?.first ?? ""
                return URL(string: "\(client.appRedirectURI.absoluteString)?state=\(state)&code=code-1&scope="
                           + ChatGPTPlanOAuth.formEscaped(GmailOAuth.scope))!
            },
            transport: { request in
                if request.url == GmailOAuth.tokenURL {
                    let form = Fixtures.form(request)
                    XCTAssertNil(form["client_secret"])
                    XCTAssertEqual(form["client_id"], client.clientID)
                    XCTAssertEqual(form["redirect_uri"], client.appRedirectURI.absoluteString)
                    return (Fixtures.json(["access_token": "access-1", "refresh_token": "refresh-1",
                                           "expires_in": 3_600, "scope": GmailOAuth.scope]),
                            Fixtures.response(request, 200))
                }
                return try await server.transport(request)
            })

        let signIn = try await authorizer.signIn { _ in
            XCTFail("LokalBot's client never opens the browser through a loopback listener")
            return false
        }

        XCTAssertEqual(signIn.address, Fixtures.me)
        XCTAssertEqual(signIn.credentials.clientID, client.clientID)
    }

    func testARedirectInAnyOtherSchemeIsRejected() async {
        let authorizer = GmailAuthorizer(
            secrets: MemoryEmailSecrets(client: nil), builtInClient: Self.builtIn,
            presentAppRedirect: { url, _ in
                let state = Fixtures.query(url)["state"]?.first ?? ""
                return URL(string: "https://attacker.example/?state=\(state)&code=stolen")!
            },
            transport: { request in
                XCTFail("no token request for a foreign redirect")
                return (Data(), Fixtures.response(request, 500))
            })
        do {
            _ = try await authorizer.signIn { _ in false }
            XCTFail("expected the redirect to be rejected")
        } catch {
            XCTAssertEqual(error as? GmailError,
                           .signInFailed("The sign-in response didn't match this request. Try again."))
        }
    }

    func testAnImportedClientTakesOverNewSignIns() {
        let withBoth = GmailAuthorizer(secrets: MemoryEmailSecrets(client: Fixtures.client), builtInClient: Self.builtIn)
        XCTAssertEqual(withBoth.signInClient(), Fixtures.client)
        let builtInOnly = GmailAuthorizer(secrets: MemoryEmailSecrets(client: nil), builtInClient: Self.builtIn)
        XCTAssertEqual(builtInOnly.signInClient(), Self.builtIn)
        XCTAssertNil(GmailAuthorizer(secrets: MemoryEmailSecrets(client: nil), builtInClient: nil).signInClient())
    }

    func testTokensRefreshWithTheClientThatIssuedThem() async throws {
        let accountID = UUID()
        let secrets = MemoryEmailSecrets(client: Fixtures.client, credentials: [accountID: EmailCredentials(
            accessToken: "old", refreshToken: "refresh-1", expiresAt: Fixtures.now, clientID: Self.builtIn.clientID)])
        let seen = RequestBox()
        let authorizer = GmailAuthorizer(secrets: secrets, builtInClient: Self.builtIn, transport: { request in
            seen.append(request)
            return (Fixtures.json(["access_token": "new", "expires_in": 3_600]), Fixtures.response(request, 200))
        }, now: { Fixtures.now })

        let token = try await authorizer.accessToken(for: accountID, address: Fixtures.me)

        XCTAssertEqual(token, "new")
        let form = Fixtures.form(try XCTUnwrap(seen.requests.first))
        XCTAssertEqual(form["client_id"], Self.builtIn.clientID)
        XCTAssertNil(form["client_secret"], "LokalBot's tokens never travel with the imported client's secret")
    }

    func testTokensWhoseClientIsGoneNeedANewSignIn() async {
        let accountID = UUID()
        let secrets = MemoryEmailSecrets(client: nil, credentials: [accountID: EmailCredentials(
            accessToken: "old", refreshToken: "refresh-1", expiresAt: Fixtures.now, clientID: Fixtures.client.clientID)])
        let authorizer = GmailAuthorizer(secrets: secrets, builtInClient: Self.builtIn, transport: { request in
            XCTFail("no refresh with a client that didn't issue the token")
            return (Data(), Fixtures.response(request, 500))
        }, now: { Fixtures.now })
        do {
            _ = try await authorizer.accessToken(for: accountID, address: Fixtures.me)
            XCTFail("expected sign-in required")
        } catch {
            XCTAssertEqual(error as? GmailError, .signInRequired(Fixtures.me))
        }
    }

    // MARK: Client file

    func testClientFileMustBeADesktopClient() throws {
        let desktop = try GoogleOAuthClient(json: Fixtures.json(["installed": [
            "client_id": " 123-abc.apps.googleusercontent.com ", "client_secret": "GOCSPX-test",
            "redirect_uris": ["http://localhost"],
        ]]))
        XCTAssertEqual(desktop, GoogleOAuthClient(clientID: "123-abc.apps.googleusercontent.com",
                                                  clientSecret: "GOCSPX-test"))
        XCTAssertThrowsError(try GoogleOAuthClient(json: Fixtures.json(["web": [
            "client_id": "123-abc.apps.googleusercontent.com", "client_secret": "s",
        ]])))
        XCTAssertThrowsError(try GoogleOAuthClient(json: Fixtures.json(["installed": [
            "client_id": "not-a-google-client", "client_secret": "s",
        ]])))
        XCTAssertThrowsError(try GoogleOAuthClient(json: Data("not json".utf8)))
    }

    // MARK: Tokens

    func testFreshTokenIsReusedAndConcurrentCallersShareOneRefresh() async throws {
        let accountID = UUID()
        let secrets = MemoryEmailSecrets(credentials: [accountID: EmailCredentials(
            accessToken: "old", refreshToken: "refresh-1", expiresAt: Fixtures.now.addingTimeInterval(60))])
        let refreshes = Counter()
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            XCTAssertEqual(request.url, GmailOAuth.tokenURL)
            await refreshes.increment()
            try await Task.sleep(for: .milliseconds(50))
            return (Fixtures.json(["access_token": "new", "expires_in": 3_600]), Fixtures.response(request, 200))
        }, now: { Fixtures.now })

        async let first = authorizer.accessToken(for: accountID, address: Fixtures.me)
        async let second = authorizer.accessToken(for: accountID, address: Fixtures.me)
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["new", "new"])
        let refreshCount = await refreshes.value
        XCTAssertEqual(refreshCount, 1)
        // Google doesn't rotate the refresh token; the old one stays.
        XCTAssertEqual(try secrets.credentials(for: accountID)?.refreshToken, "refresh-1")
        let reused = try await authorizer.accessToken(for: accountID, address: Fixtures.me)
        XCTAssertEqual(reused, "new")
        let finalCount = await refreshes.value
        XCTAssertEqual(finalCount, 1)
    }

    func testRevokedRefreshTokenEndsTheSession() async throws {
        let accountID = UUID()
        let secrets = MemoryEmailSecrets(credentials: [accountID: EmailCredentials(
            accessToken: "old", refreshToken: "refresh-1", expiresAt: Fixtures.now)])
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            (Fixtures.json(["error": "invalid_grant"]), Fixtures.response(request, 400))
        }, now: { Fixtures.now })

        do {
            _ = try await authorizer.accessToken(for: accountID, address: Fixtures.me)
            XCTFail("expected sign-in required")
        } catch {
            XCTAssertEqual(error as? GmailError, .signInRequired(Fixtures.me))
        }
        XCTAssertNil(try secrets.credentials(for: accountID))
    }

    func testTransientRefreshFailureKeepsTheSession() async throws {
        let accountID = UUID()
        let credentials = EmailCredentials(accessToken: "old", refreshToken: "refresh-1", expiresAt: Fixtures.now)
        let secrets = MemoryEmailSecrets(credentials: [accountID: credentials])
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            (Data(), Fixtures.response(request, 503))
        }, now: { Fixtures.now })

        do {
            _ = try await authorizer.accessToken(for: accountID, address: Fixtures.me)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? GmailError, .requestFailed(status: 503, reason: nil))
        }
        XCTAssertEqual(try secrets.credentials(for: accountID), credentials)
    }

    func testDisconnectForgetsTokensBeforeAskingGoogle() async throws {
        let accountID = UUID()
        let secrets = MemoryEmailSecrets(credentials: [accountID: EmailCredentials(
            accessToken: "a", refreshToken: "refresh-1", expiresAt: Fixtures.now)])
        let seen = RequestBox()
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            seen.append(request)
            return (Data(), Fixtures.response(request, 200))
        })

        let token = await authorizer.forget(accountID)
        XCTAssertEqual(token, ["refresh-1"])
        XCTAssertNil(try secrets.credentials(for: accountID))
        XCTAssertTrue(seen.requests.isEmpty)
        let confirmed = await authorizer.revoke(token: "refresh-1")

        XCTAssertTrue(confirmed)
        XCTAssertEqual(seen.requests.map(\.url), [GmailOAuth.revokeURL])
        XCTAssertEqual(Fixtures.form(seen.requests[0]), ["token": "refresh-1"])
    }

    func testARejectedClientKeepsTheTokenSoDisconnectCanRevokeIt() async throws {
        let accountID = UUID()
        let credentials = EmailCredentials(accessToken: "old", refreshToken: "refresh-1", expiresAt: Fixtures.now)
        let secrets = MemoryEmailSecrets(credentials: [accountID: credentials])
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            (Fixtures.json(["error": "unauthorized_client"]), Fixtures.response(request, 401))
        }, now: { Fixtures.now })

        do {
            _ = try await authorizer.accessToken(for: accountID, address: Fixtures.me)
            XCTFail("expected sign-in required")
        } catch {
            XCTAssertEqual(error as? GmailError, .signInRequired(Fixtures.me))
        }
        XCTAssertEqual(try secrets.credentials(for: accountID), credentials)
        let token = await authorizer.forget(accountID)
        XCTAssertEqual(token, ["refresh-1"])
    }

    func testALockedKeychainIsNotASignOut() async {
        let secrets = MemoryEmailSecrets()
        secrets.readError = KeychainSecrets.EncryptionKeyFailure.operation("read", account: "x", status: -25_308)
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            XCTFail("no request without credentials")
            return (Data(), Fixtures.response(request, 500))
        })
        do {
            _ = try await authorizer.accessToken(for: UUID(), address: Fixtures.me)
            XCTFail("expected a Keychain error")
        } catch {
            guard case .keychainUnavailable? = error as? GmailError else {
                return XCTFail("expected keychainUnavailable, got \(error)")
            }
        }
    }

    func testTokensAreReadFromTheKeychainOnce() async throws {
        let accountID = UUID()
        let secrets = MemoryEmailSecrets(credentials: [accountID: EmailCredentials(
            accessToken: "a", refreshToken: "r", expiresAt: Fixtures.now.addingTimeInterval(3_600))])
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            (Data(), Fixtures.response(request, 500))
        }, now: { Fixtures.now })
        for _ in 0..<5 {
            _ = try await authorizer.accessToken(for: accountID, address: Fixtures.me)
        }
        XCTAssertEqual(secrets.reads, 1)
    }

    func testReconnectKeepsTheNewGrantAndRetainsOldTokensUntilDisconnect() async throws {
        let accountID = UUID()
        let secrets = MemoryEmailSecrets(credentials: [accountID: EmailCredentials(
            accessToken: "a", refreshToken: "old-refresh", expiresAt: Fixtures.now,
            clientID: Self.builtIn.clientID, pendingRevocationTokens: ["older-client-refresh"])])
        let seen = RequestBox()
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            seen.append(request)
            XCTAssertEqual(request.url, GmailOAuth.tokenURL, "reconnect must never revoke the new project's grant")
            XCTAssertEqual(Fixtures.form(request)["refresh_token"], "new-refresh")
            return (Fixtures.json(["access_token": "refreshed", "expires_in": 3_600]), Fixtures.response(request, 200))
        }, now: { Fixtures.now })

        await authorizer.save(EmailCredentials(accessToken: "b", refreshToken: "new-refresh", expiresAt: Fixtures.now,
                                              clientID: Self.builtIn.clientID),
                              for: accountID)
        let refreshed = try await authorizer.accessToken(for: accountID, address: Fixtures.me)
        XCTAssertEqual(refreshed, "refreshed")
        XCTAssertEqual(seen.requests.count, 1)

        // The pending revocations survive serialization and a fresh authorizer.
        let saved = try XCTUnwrap(secrets.credentials(for: accountID))
        let restored = try JSONDecoder().decode(EmailCredentials.self, from: JSONEncoder().encode(saved))
        let restarted = GmailAuthorizer(secrets: MemoryEmailSecrets(credentials: [accountID: restored]))
        let tokens = await restarted.forget(accountID)
        XCTAssertEqual(tokens, ["new-refresh", "old-refresh", "older-client-refresh"])
    }

    func testExpiredCurrentGrantStillRetainsPreviousClientsForDisconnect() async throws {
        let accountID = UUID()
        let secrets = MemoryEmailSecrets(credentials: [accountID: EmailCredentials(
            accessToken: "a", refreshToken: "expired", expiresAt: Fixtures.now,
            pendingRevocationTokens: ["previous-project-refresh"])])
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            (Fixtures.json(["error": "invalid_grant"]), Fixtures.response(request, 400))
        }, now: { Fixtures.now })
        do {
            _ = try await authorizer.accessToken(for: accountID, address: Fixtures.me)
            XCTFail("expected sign-in required")
        } catch {
            XCTAssertEqual(error as? GmailError, .signInRequired(Fixtures.me))
        }
        let tokens = await authorizer.forget(accountID)
        XCTAssertEqual(tokens, ["expired", "previous-project-refresh"])
        XCTAssertNil(try secrets.credentials(for: accountID))
    }

    func testCredentialsFromBeforePendingRevocationsStillDecode() throws {
        let data = try JSONEncoder().encode(EmailCredentials(
            accessToken: "a", refreshToken: "r", expiresAt: Fixtures.now))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["pendingRevocationTokens"])
        XCTAssertNil(try JSONDecoder().decode(EmailCredentials.self, from: data).pendingRevocationTokens)
    }

    // MARK: Sign-in

    func testSignInCompletesThroughLoopbackRedirect() async throws {
        let secrets = MemoryEmailSecrets()
        let redirect = Box<String>()
        let server = FakeGmailServer()
        let authorizer = GmailAuthorizer(secrets: secrets, transport: { request in
            if request.url == GmailOAuth.tokenURL {
                let form = Fixtures.form(request)
                XCTAssertEqual(form["code"], "code-1")
                XCTAssertEqual(form["client_secret"], "test-secret")
                XCTAssertEqual(form["redirect_uri"], redirect.value)
                XCTAssertNotNil(form["code_verifier"])
                return (Fixtures.json(["access_token": "access-1", "refresh_token": "refresh-1",
                                       "expires_in": 3_600, "scope": GmailOAuth.scope]),
                        Fixtures.response(request, 200))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
            return try await server.transport(request)
        })

        let signIn = try await authorizer.signIn { url in
            let items = Fixtures.query(url)
            redirect.value = items["redirect_uri"]?.first
            guard let redirectURI = items["redirect_uri"]?.first, let state = items["state"]?.first,
                  let callback = URL(string: "\(redirectURI)?state=\(state)&code=code-1&scope="
                                     + ChatGPTPlanOAuth.formEscaped(GmailOAuth.scope)) else { return false }
            Task.detached {
                // A stray request first, as a browser's favicon fetch would be.
                if let favicon = URL(string: redirectURI + "favicon.ico") {
                    _ = try? await URLSession.shared.data(from: favicon)
                }
                _ = try? await URLSession.shared.data(from: callback)
            }
            return true
        }

        XCTAssertEqual(signIn.address, Fixtures.me)
        XCTAssertEqual(signIn.aliases, [Fixtures.alias])
        XCTAssertEqual(signIn.credentials.accessToken, "access-1")
        XCTAssertEqual(signIn.credentials.refreshToken, "refresh-1")
        XCTAssertTrue(redirect.value?.hasPrefix("http://127.0.0.1:") == true)
    }

    func testSignInNeedsABuiltInOrImportedClient() async {
        let authorizer = GmailAuthorizer(secrets: MemoryEmailSecrets(client: nil), builtInClient: nil, transport: { request in
            XCTFail("no request without a client")
            return (Data(), Fixtures.response(request, 500))
        })
        do {
            _ = try await authorizer.signIn { _ in true }
            XCTFail("expected noClient")
        } catch {
            XCTAssertEqual(error as? GmailError, .noClient)
        }
    }

    // MARK: Helpers

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { stored } }
        func append(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    }
}
