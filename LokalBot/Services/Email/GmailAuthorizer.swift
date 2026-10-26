import Foundation

/// Signs Gmail accounts in, keeps each account's access token fresh, and
/// revokes access on disconnect. One shared instance serializes refreshes
/// per account.
actor GmailAuthorizer {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias BrowserOpener = @Sendable (URL) async -> Bool

    /// Refresh this long before the access token expires.
    static let refreshMargin: TimeInterval = 120

    struct SignIn: Equatable, Sendable {
        var address: String
        var aliases: [String]
        var credentials: EmailCredentials
    }

    private let secrets: EmailSecretStore
    private let transport: Transport
    private let now: @Sendable () -> Date
    private var refreshTasks: [UUID: Task<EmailCredentials, Error>] = [:]
    /// Tokens already read or written this launch. Gmail calls need no
    /// Keychain read each, and a failed Keychain write after a refresh
    /// doesn't send every later call back to Google's token endpoint.
    private var cache: [UUID: EmailCredentials] = [:]
    private var signInListener: LoopbackRedirectListener?

    init(secrets: EmailSecretStore = KeychainEmailSecretStore(),
         transport: @escaping Transport = { try await GmailAuthorizer.liveTransport($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.secrets = secrets
        self.transport = transport
        self.now = now
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

    /// Opens Google's consent page and completes the code exchange when the
    /// browser returns to the loopback listener. The account's address comes
    /// from Gmail itself, so the token can't be filed under the wrong one.
    func signIn(loginHint: String? = nil, openBrowser: BrowserOpener) async throws -> SignIn {
        guard let client = secrets.googleClient() else { throw GmailError.noClient }
        signInListener?.stop()
        let listener = try await LoopbackRedirectListener.start(preferredPort: 0, path: GmailOAuth.callbackPath)
        signInListener = listener
        defer {
            listener.stop()
            if signInListener === listener { signInListener = nil }
        }
        let redirectURI = GmailOAuth.redirectURI(port: listener.port)
        let request = GmailOAuth.AuthorizationRequest(
            client: client, redirectURI: redirectURI, state: ChatGPTPlanOAuth.randomToken(),
            pkce: ChatGPTPlanOAuth.PKCE(), loginHint: loginHint)
        guard await openBrowser(request.url) else {
            throw GmailError.signInFailed("LokalBot couldn't open your browser for Google sign-in.")
        }
        let query = try await listener.waitForCallback(timeout: GmailOAuth.signInTimeout)
        guard case .code(let code) = try GmailOAuth.parseCallback(query, expectedState: request.state) else {
            throw CancellationError()
        }
        let (data, response) = try await transport(GmailOAuth.codeExchangeRequest(
            code: code, client: client, verifier: request.pkce.verifier, redirectURI: redirectURI))
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
            expiresAt: now().addingTimeInterval(tokens.expiresIn))
        let gmail = GmailClient(
            accessToken: { tokens.accessToken },
            tokenRejected: { _ in throw GmailError.signInFailed("Google rejected the new sign-in. Try again.") },
            transport: transport)
        let profile = try await gmail.profile()
        let address = profile.emailAddress.lowercased()
        let aliases = ((try? await gmail.sendAsAddresses()) ?? []).filter { $0 != address }
        return SignIn(address: address, aliases: Array(Set(aliases)).sorted(), credentials: credentials)
    }

    func cancelSignIn() {
        signInListener?.stop()
        signInListener = nil
    }

    /// Files a finished sign-in under its account. A sign-in that replaces
    /// a different refresh token (a new client file, a second consent)
    /// revokes the old one, so no grant stays live at Google unused.
    func save(_ credentials: EmailCredentials, for accountID: UUID) {
        refreshTasks[accountID]?.cancel()
        refreshTasks[accountID] = nil
        let previous = cache[accountID] ?? (try? secrets.credentials(for: accountID))
        cache[accountID] = credentials
        secrets.setCredentials(credentials, for: accountID)
        if let previous, previous.refreshToken != credentials.refreshToken {
            let token = previous.refreshToken
            Task { await self.revoke(token: token) }
        }
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
        guard let client = secrets.googleClient() else { throw GmailError.noClient }
        let (data, response) = try await transport(GmailOAuth.refreshRequest(
            refreshToken: credentials.refreshToken, client: client))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let code = ChatGPTPlanOAuth.oauthErrorCode(data)
            if let code, GmailOAuth.revokedGrantErrors.contains(code) {
                lokalbotLog("email gmail refresh rejected code=\(code)")
                if cache[accountID]?.refreshToken == credentials.refreshToken {
                    cache[accountID] = nil
                    secrets.setCredentials(nil, for: accountID)
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

    /// Stops using the account at once: forgets its tokens here and returns
    /// the refresh token for `revoke(token:)`. Nil when nothing was stored.
    func forget(_ accountID: UUID) -> String? {
        refreshTasks[accountID]?.cancel()
        refreshTasks[accountID] = nil
        let token = (cache[accountID] ?? (try? secrets.credentials(for: accountID)))?.refreshToken
        cache[accountID] = nil
        secrets.setCredentials(nil, for: accountID)
        return token
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
