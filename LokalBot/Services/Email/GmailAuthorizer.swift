import Foundation

/// Signs Gmail accounts in, keeps each account's access token fresh, and
/// revokes access on disconnect. One shared instance serializes refreshes
/// per account.
actor GmailAuthorizer {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias BrowserOpener = @Sendable (URL) async -> Bool
    /// Shows Google's consent page and returns the URL Google redirected to
    /// in the client's own scheme (`ASWebAuthenticationSession` in the app).
    typealias AppRedirectPresenter = @Sendable (_ url: URL, _ callbackScheme: String) async throws -> URL

    /// Refresh this long before the access token expires.
    static let refreshMargin: TimeInterval = 120

    struct SignIn: Equatable, Sendable {
        var address: String
        var aliases: [String]
        var credentials: EmailCredentials
    }

    private let secrets: EmailSecretStore
    private let builtInClient: GoogleOAuthClient?
    private let presentAppRedirect: AppRedirectPresenter
    private let transport: Transport
    private let now: @Sendable () -> Date
    private var refreshTasks: [UUID: Task<EmailCredentials, Error>] = [:]
    /// Tokens already read or written this launch. Gmail calls need no
    /// Keychain read each, and a failed Keychain write after a refresh
    /// doesn't send every later call back to Google's token endpoint.
    private var cache: [UUID: EmailCredentials] = [:]
    private var signInListener: LoopbackRedirectListener?

    init(secrets: EmailSecretStore = KeychainEmailSecretStore(),
         builtInClient: GoogleOAuthClient? = .builtIn(),
         presentAppRedirect: @escaping AppRedirectPresenter = { try await GoogleSignInSheet.present($0, callbackScheme: $1) },
         transport: @escaping Transport = { try await GmailAuthorizer.liveTransport($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.secrets = secrets
        self.builtInClient = builtInClient
        self.presentAppRedirect = presentAppRedirect
        self.transport = transport
        self.now = now
    }

    /// The client new sign-ins use: the person's own when they imported one,
    /// otherwise LokalBot's.
    nonisolated func signInClient() -> GoogleOAuthClient? {
        secrets.googleClient() ?? builtInClient
    }

    /// The client that issued an account's tokens. Refreshing needs that same
    /// client; if it's gone (the imported file was removed or replaced), the
    /// account signs in again.
    private func issuingClient(_ credentials: EmailCredentials) -> GoogleOAuthClient? {
        let imported = secrets.googleClient()
        guard let id = credentials.clientID else { return imported ?? builtInClient }
        if let imported, imported.clientID == id { return imported }
        if let builtInClient, builtInClient.clientID == id { return builtInClient }
        return nil
    }

    /// Google's fixed hosts; never follow a redirect away from them.
    static func liveTransport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }

    private static let session = InferenceURLSession.make(requestTimeout: 30, resourceTimeout: 120)

    // MARK: Sign-in

    /// Shows Google's consent page and completes the code exchange when
    /// Google returns. LokalBot's own client returns to the app's sign-in
    /// sheet; an imported Desktop client returns to a loopback listener in
    /// the browser. The account's address comes from Gmail itself, so the
    /// token can't be filed under the wrong one.
    func signIn(loginHint: String? = nil, openBrowser: BrowserOpener) async throws -> SignIn {
        guard let client = signInClient() else { throw GmailError.noClient }
        let state = ChatGPTPlanOAuth.randomToken()
        let pkce = ChatGPTPlanOAuth.PKCE()
        let redirectURI: URL
        let query: [String: String]
        if client.returnsToApp {
            redirectURI = client.appRedirectURI
            let request = GmailOAuth.AuthorizationRequest(
                client: client, redirectURI: redirectURI, state: state, pkce: pkce, loginHint: loginHint)
            let returned = try await presentAppRedirect(request.url, client.appURLScheme)
            query = Self.query(of: returned, scheme: client.appURLScheme)
        } else {
            signInListener?.stop()
            let listener = try await LoopbackRedirectListener.start(preferredPort: 0, path: GmailOAuth.callbackPath)
            signInListener = listener
            defer {
                listener.stop()
                if signInListener === listener { signInListener = nil }
            }
            redirectURI = GmailOAuth.redirectURI(port: listener.port)
            let request = GmailOAuth.AuthorizationRequest(
                client: client, redirectURI: redirectURI, state: state, pkce: pkce, loginHint: loginHint)
            guard await openBrowser(request.url) else {
                throw GmailError.signInFailed("LokalBot couldn't open your browser for Google sign-in.")
            }
            query = try await listener.waitForCallback(timeout: GmailOAuth.signInTimeout)
        }
        guard case .code(let code) = try GmailOAuth.parseCallback(query, expectedState: state) else {
            throw CancellationError()
        }
        let (data, response) = try await transport(GmailOAuth.codeExchangeRequest(
            code: code, client: client, verifier: pkce.verifier, redirectURI: redirectURI))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let code = ChatGPTPlanOAuth.oauthErrorCode(data) ?? "HTTP \(status)"
            throw GmailError.signInFailed("Google sign-in couldn't be completed (\(code)). Try again.")
        }
        let tokens = try GmailOAuth.TokenResponse(json: data)
        guard tokens.grantsReadAccess else { throw GmailError.readAccessNotGranted }
        guard let refreshToken = tokens.refreshToken else {
            throw GmailError.signInFailed("Google didn't return a lasting sign-in. Try again.")
        }
        let credentials = EmailCredentials(
            accessToken: tokens.accessToken, refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(tokens.expiresIn), clientID: client.clientID)
        let gmail = GmailClient(
            accessToken: { tokens.accessToken },
            tokenRejected: { _ in throw GmailError.signInFailed("Google rejected the new sign-in. Try again.") },
            transport: transport)
        let profile = try await gmail.profile()
        let address = profile.emailAddress.lowercased()
        let aliases = ((try? await gmail.sendAsAddresses()) ?? []).filter { $0 != address }
        return SignIn(address: address, aliases: Array(Set(aliases)).sorted(), credentials: credentials)
    }

    /// The query of a redirect in the app's own scheme; anything else is empty,
    /// which the state check then rejects.
    static func query(of url: URL, scheme: String) -> [String: String] {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        return query
    }

    func cancelSignIn() {
        signInListener?.stop()
        signInListener = nil
    }

    /// Files a finished sign-in under its account. Google revocation affects
    /// the whole project's grant, including a newly issued token. Keep replaced
    /// tokens in the Keychain for Disconnect instead of revoking on reconnect.
    func save(_ credentials: EmailCredentials, for accountID: UUID) {
        refreshTasks[accountID]?.cancel()
        refreshTasks[accountID] = nil
        let previous = cache[accountID] ?? (try? secrets.credentials(for: accountID))
        var next = credentials
        var pending = Set(credentials.pendingRevocationTokens ?? [])
        if let previous {
            pending.formUnion(previous.pendingRevocationTokens ?? [])
            pending.insert(previous.refreshToken)
        }
        pending.remove(credentials.refreshToken)
        next.pendingRevocationTokens = pending.isEmpty ? nil : pending.sorted()
        cache[accountID] = next
        secrets.setCredentials(next, for: accountID)
    }

    // MARK: Tokens

    /// The account's tokens, read from the Keychain once per launch.
    private func credentials(_ accountID: UUID, address: String) throws -> EmailCredentials {
        if let cached = cache[accountID] { return cached }
        let stored: EmailCredentials?
        do {
            stored = try secrets.credentials(for: accountID)
        } catch {
            throw GmailError.keychainUnavailable(error.localizedDescription)
        }
        guard let stored else { throw GmailError.signInRequired(address) }
        cache[accountID] = stored
        return stored
    }

    func accessToken(for accountID: UUID, address: String) async throws -> String {
        let credentials = try credentials(accountID, address: address)
        if credentials.expiresAt > now().addingTimeInterval(Self.refreshMargin) {
            return credentials.accessToken
        }
        return try await refreshed(accountID, address: address, from: credentials).accessToken
    }

    /// Gmail rejected `rejected`; refresh once unless another caller already did.
    func accessToken(for accountID: UUID, address: String, afterRejecting rejected: String) async throws -> String {
        let credentials = try credentials(accountID, address: address)
        if credentials.accessToken != rejected { return credentials.accessToken }
        return try await refreshed(accountID, address: address, from: credentials).accessToken
    }

    private func refreshed(_ accountID: UUID, address: String,
                           from credentials: EmailCredentials) async throws -> EmailCredentials {
        if let running = refreshTasks[accountID] { return try await running.value }
        let task = Task { try await self.performRefresh(accountID, address: address, credentials) }
        refreshTasks[accountID] = task
        defer { if refreshTasks[accountID] == task { refreshTasks[accountID] = nil } }
        return try await task.value
    }

    private func performRefresh(_ accountID: UUID, address: String,
                                _ credentials: EmailCredentials) async throws -> EmailCredentials {
        guard let client = issuingClient(credentials) else {
            lokalbotLog("email gmail refresh has no client for these tokens")
            throw GmailError.signInRequired(address)
        }
        let (data, response) = try await transport(GmailOAuth.refreshRequest(
            refreshToken: credentials.refreshToken, client: client))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let code = ChatGPTPlanOAuth.oauthErrorCode(data)
            if let code, GmailOAuth.revokedGrantErrors.contains(code) {
                lokalbotLog("email gmail refresh rejected code=\(code)")
                if cache[accountID]?.refreshToken == credentials.refreshToken {
                    // Older clients may belong to another Cloud project. Keep
                    // their tokens available for Disconnect even if this grant expired.
                    if credentials.pendingRevocationTokens?.isEmpty ?? true {
                        cache[accountID] = nil
                        secrets.setCredentials(nil, for: accountID)
                    }
                }
                throw GmailError.signInRequired(address)
            }
            if let code, GmailOAuth.clientErrors.contains(code) {
                // The token is kept: Disconnect can still revoke it.
                lokalbotLog("email gmail refresh rejected the client code=\(code)")
                throw GmailError.signInRequired(address)
            }
            throw GmailError.requestFailed(status: status, reason: code)
        }
        let tokens = try GmailOAuth.TokenResponse(json: data)
        var next = credentials
        next.accessToken = tokens.accessToken
        if let refreshToken = tokens.refreshToken { next.refreshToken = refreshToken }
        next.expiresAt = now().addingTimeInterval(tokens.expiresIn)
        // A disconnect or new sign-in during the refresh wins over its result.
        guard cache[accountID]?.refreshToken == credentials.refreshToken else {
            throw GmailError.signInRequired(address)
        }
        // The cache keeps the session working even if this write fails.
        cache[accountID] = next
        secrets.setCredentials(next, for: accountID)
        return next
    }

    /// A read-only client for one account.
    nonisolated func client(for account: EmailAccount) -> GmailClient {
        let id = account.id
        let address = account.address
        return GmailClient(
            accessToken: { try await self.accessToken(for: id, address: address) },
            tokenRejected: { try await self.accessToken(for: id, address: address, afterRejecting: $0) },
            transport: transport)
    }

    // MARK: Disconnect

    /// Stops using the account at once and returns every retained refresh
    /// token for revocation, including grants from previously used clients.
    func forget(_ accountID: UUID) -> [String] {
        refreshTasks[accountID]?.cancel()
        refreshTasks[accountID] = nil
        let credentials = cache[accountID] ?? (try? secrets.credentials(for: accountID))
        cache[accountID] = nil
        secrets.setCredentials(nil, for: accountID)
        guard let credentials else { return [] }
        return Array(Set([credentials.refreshToken] + (credentials.pendingRevocationTokens ?? []))).sorted()
    }

    /// Asks Google to revoke a refresh token, which also ends every access
    /// token issued from it. Returns false when Google didn't confirm.
    @discardableResult
    func revoke(token: String) async -> Bool {
        for attempt in 0..<3 {
            do {
                let (_, response) = try await transport(GmailOAuth.revocationRequest(token: token))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(status) { return true }
                // 400 means Google no longer knows the token: already revoked.
                if status == 400 { return true }
                if status < 500 { return false }
            } catch {
                if error is CancellationError { return false }
            }
            try? await Task.sleep(for: .seconds(Double(1 << attempt)))
        }
        return false
    }
}
