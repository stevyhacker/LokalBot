import Foundation

/// Google's OAuth 2.0 flow for installed apps
/// (developers.google.com/identity/protocols/oauth2/native-app, 2026-10):
/// the system browser, a loopback redirect, PKCE, and the read-only Gmail
/// scope only. Google refuses any change to mail made with this grant, so
/// "read-only" does not rest on LokalBot's own code.
///
/// LokalBot has no verified Google client yet. Until it does, the person
/// imports their own Desktop-app client (`GoogleOAuthClient`), which Google
/// allows for personal use by fewer than 100 people.
enum GmailOAuth {
    static let authorizeURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let revokeURL = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"
    /// Desktop clients accept any loopback port and path.
    static let callbackPath = "/"
    static let signInTimeout: Duration = .seconds(300)

    static func redirectURI(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(callbackPath)")!
    }

    struct AuthorizationRequest: Equatable, Sendable {
        var client: GoogleOAuthClient
        var redirectURI: URL
        var state: String
        var pkce: ChatGPTPlanOAuth.PKCE
        /// Preselects the account when signing in again.
        var loginHint: String?

        var url: URL {
            var fields = [
                ("client_id", client.clientID),
                ("redirect_uri", redirectURI.absoluteString),
                ("response_type", "code"),
                ("scope", GmailOAuth.scope),
                ("state", state),
                ("code_challenge", pkce.challenge),
                ("code_challenge_method", "S256"),
                // A refresh token, issued again on every consent, so a
                // second sign-in to the same account never strands one.
                ("access_type", "offline"),
                ("prompt", "consent"),
            ]
            if let loginHint, !loginHint.isEmpty {
                fields.append(("login_hint", loginHint))
            }
            let query = fields.map { "\($0.0)=\(ChatGPTPlanOAuth.formEscaped($0.1))" }.joined(separator: "&")
            return URL(string: "\(GmailOAuth.authorizeURL.absoluteString)?\(query)")!
        }
    }

    enum CallbackOutcome: Equatable, Sendable {
        case code(String)
        case denied
    }

    /// Validates `state` before anything else, so a forged request from
    /// another local process can neither complete nor cancel a sign-in.
    static func parseCallback(_ query: [String: String], expectedState: String) throws -> CallbackOutcome {
        guard let state = query["state"], state == expectedState else {
            throw GmailError.signInFailed("The sign-in response didn't match this request. Try again.")
        }
        if let error = query["error"] {
            if error == "access_denied" { return .denied }
            throw GmailError.signInFailed("Google sign-in failed: \(error.prefix(120))")
        }
        guard let code = query["code"], !code.isEmpty else {
            throw GmailError.signInFailed("Google didn't return an authorization code.")
        }
        // Google lists what the person actually granted; an unticked Gmail
        // box still returns a code.
        if let granted = query["scope"],
           !granted.split(whereSeparator: { $0 == " " || $0 == "+" }).contains(Substring(scope)) {
            throw GmailError.readAccessNotGranted
        }
        return .code(code)
    }

    static func codeExchangeRequest(code: String, client: GoogleOAuthClient, verifier: String,
                                    redirectURI: URL) -> URLRequest {
        ChatGPTPlanOAuth.formRequest(tokenURL, [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
            "code_verifier": verifier,
            "redirect_uri": redirectURI.absoluteString,
        ])
    }

    static func refreshRequest(refreshToken: String, client: GoogleOAuthClient) -> URLRequest {
        ChatGPTPlanOAuth.formRequest(tokenURL, [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": client.clientID,
            "client_secret": client.clientSecret,
        ])
    }

    /// Revoking the refresh token also ends every access token issued from it.
    static func revocationRequest(token: String) -> URLRequest {
        ChatGPTPlanOAuth.formRequest(revokeURL, ["token": token])
    }

    struct TokenResponse: Equatable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: TimeInterval
        /// Nil when Google omits the field.
        var scopes: Set<String>?

        init(json data: Data) throws {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
                throw GmailError.signInFailed("Google returned an unexpected token response.")
            }
            self.accessToken = accessToken
            refreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
            scopes = (json["scope"] as? String).map { Set($0.split(separator: " ").map(String.init)) }
        }

        var grantsReadAccess: Bool { scopes?.contains(GmailOAuth.scope) ?? true }
    }

    /// Google no longer honors the refresh token (revoked, expired, or the
    /// password changed). It is useless and can be forgotten.
    static let revokedGrantErrors: Set<String> = ["invalid_grant"]
    /// The imported client was deleted, reset, or replaced. The refresh token
    /// may still be live at Google, so it is kept until Disconnect revokes it.
    static let clientErrors: Set<String> = ["invalid_client", "unauthorized_client", "deleted_client"]
}

/// A Google Cloud OAuth client of type "Desktop app", as Google's console
/// downloads it (`{"installed": {"client_id": …, "client_secret": …}}`).
/// Google states that an installed app's secret is not confidential; LokalBot
/// still keeps it in the Keychain and never in the repository.
struct GoogleOAuthClient: Codable, Equatable, Sendable {
    var clientID: String
    var clientSecret: String

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    init(json data: Data) throws {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailError.invalidClientFile("This isn't a Google OAuth client file.")
        }
        if json["web"] != nil {
            throw GmailError.invalidClientFile(
                "This is a web application client. Create an OAuth client of type Desktop app instead.")
        }
        guard let installed = json["installed"] as? [String: Any],
              let clientID = (installed["client_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              clientID.hasSuffix(".apps.googleusercontent.com"),
              let clientSecret = (installed["client_secret"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !clientSecret.isEmpty else {
            throw GmailError.invalidClientFile(
                "This file has no Desktop app client. Download the client JSON from Google Cloud → Credentials.")
        }
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

enum GmailError: LocalizedError, Equatable, Sendable {
    case noClient
    case invalidClientFile(String)
    case signInFailed(String)
    case readAccessNotGranted
    case signInRequired(String)
    case requestFailed(status: Int, reason: String?)
    case unexpectedResponse
    case historyExpired
    case keychainUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noClient:
            "Choose your Google OAuth client file before adding a Gmail account."
        case .invalidClientFile(let detail):
            detail
        case .signInFailed(let detail):
            detail
        case .readAccessNotGranted:
            "Google didn't grant read access to Gmail. Sign in again and tick the box that lets LokalBot read your email."
        case .signInRequired(let address):
            "The sign-in for \(address) expired or was revoked. Sign in again."
        case .requestFailed(403, "accessNotConfigured"), .requestFailed(403, "SERVICE_DISABLED"):
            "The Gmail API isn't enabled in your Google Cloud project. Enable it there, then try again."
        case .requestFailed(let status, let reason):
            "Gmail returned HTTP \(status)\(reason.map { " (\($0))" } ?? "")."
        case .unexpectedResponse:
            "Gmail returned a response LokalBot couldn't read."
        case .historyExpired:
            "Gmail's change history for this account expired."
        case .keychainUnavailable(let detail):
            "LokalBot couldn't read this account's sign-in from the Keychain: \(detail)"
        }
    }
}
