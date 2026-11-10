import CryptoKit
import Foundation
import Security

/// OpenAI's Sign in with ChatGPT for open-source apps ("token sharing"),
/// documented at developers.openai.com/siwc/token-sharing-open-source
/// (2026-10). The first sign-in registers this Mac's LokalBot as a client
/// (`dynamic_agent_client`); OpenAI returns the issued client id in the
/// callback, and later sign-ins and refreshes use that id. No client secret
/// or API key exists in this flow.
enum ChatGPTPlanOAuth {
    static let issuer = "https://auth.openai.com"
    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    /// Only the entry point of a first registration. Never stored, never sent
    /// to the token endpoint.
    static let registrationClientID = "dynamic_agent_client"
    static let agentName = "LokalBot"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// The grant that lets requests draw on the ChatGPT plan. A valid sign-in
    /// without it identifies the user but authorizes no inference.
    static let planScope = "chatgpt.tokens.use.direct"
    static let resource = "https://api.openai.com/v1"
    static let callbackPath = "/auth/callback"
    /// OpenAI's example port. Any port works; only the port may vary.
    static let preferredCallbackPort: UInt16 = 1455

    static func redirectURI(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(callbackPath)")!
    }

    struct PKCE: Equatable, Sendable {
        let verifier: String
        let challenge: String

        init(verifier: String = ChatGPTPlanOAuth.randomToken(byteCount: 48)) {
            self.verifier = verifier
            challenge = ChatGPTPlanOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        }
    }

    struct AuthorizationRequest: Equatable, Sendable {
        /// The issued client id, or nil for a first registration.
        var clientID: String?
        var hostID: String
        var redirectURI: URL
        var state: String
        var nonce: String
        var pkce: PKCE
        /// A previous ID token skips OpenAI's account picker on return.
        var idTokenHint: String?
        var loginHint: String?

        var url: URL {
            var items = [
                URLQueryItem(name: "client_id", value: clientID ?? ChatGPTPlanOAuth.registrationClientID),
            ]
            if clientID == nil {
                items.append(URLQueryItem(name: "agent_name_hint", value: ChatGPTPlanOAuth.agentName))
            }
            items += [
                URLQueryItem(name: "ext_agent_host_id", value: hostID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "scope", value: ChatGPTPlanOAuth.scope),
                URLQueryItem(name: "resource", value: ChatGPTPlanOAuth.resource),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "nonce", value: nonce),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
            ]
            if let idTokenHint, clientID != nil {
                items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint))
            }
            if let loginHint, !loginHint.isEmpty {
                items.append(URLQueryItem(name: "login_hint", value: loginHint))
            }
            // Strict escaping: URLComponents leaves "@", "+", ":" and "/"
            // as-is in a query, and OpenAI's examples escape the hints.
            let query = items.map { item in
                "\(item.name)=\(ChatGPTPlanOAuth.formEscaped(item.value ?? ""))"
            }.joined(separator: "&")
            return URL(string: "\(ChatGPTPlanOAuth.authorizeURL.absoluteString)?\(query)")!
        }
    }

    enum CallbackOutcome: Equatable, Sendable {
        /// `clientID` is the issued id when the callback names one.
        case code(String, clientID: String?)
        case denied
    }

    /// Validates `state` before anything else, so a forged request from
    /// another local process can neither complete nor cancel a sign-in.
    static func parseCallback(_ query: [String: String], expectedState: String,
                              expectedClientID: String?) throws -> CallbackOutcome {
        guard let state = query["state"], state == expectedState else {
            throw ChatGPTPlanError.signInFailed("The sign-in response didn't match this request. Try again.")
        }
        if let error = query["error"] {
            if error == "access_denied" { return .denied }
            let detail = query["error_description"] ?? error
            throw ChatGPTPlanError.signInFailed("ChatGPT sign-in failed: \(detail.prefix(300))")
        }
        guard let code = query["code"], !code.isEmpty else {
            throw ChatGPTPlanError.signInFailed("ChatGPT didn't return an authorization code.")
        }
        let clientID = query["client_id"].flatMap { $0.isEmpty ? nil : $0 }
        if let expectedClientID, let clientID, clientID != expectedClientID {
            throw ChatGPTPlanError.signInFailed("ChatGPT returned a different app registration. Try again.")
        }
        if expectedClientID == nil, clientID == nil {
            throw ChatGPTPlanError.signInFailed("ChatGPT didn't return this app's registration. Try again.")
        }
        return .code(code, clientID: clientID)
    }

    static func codeExchangeRequest(code: String, clientID: String, verifier: String,
                                    redirectURI: URL) -> URLRequest {
        formRequest(tokenURL, [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI.absoluteString,
            "resource": resource,
        ])
    }

    /// `scope` is omitted so the refresh keeps the whole grant.
    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        formRequest(tokenURL, [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
            "resource": resource,
        ])
    }

    static func revocationRequest(endpoint: URL, refreshToken: String, clientID: String) -> URLRequest {
        formRequest(endpoint, [
            "token": refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": clientID,
        ])
    }

    static func formRequest(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.keys.sorted().map { key in
            "\(key)=\(formEscaped(fields[key]!))"
        }.joined(separator: "&").utf8)
        return request
    }

    /// Percent-encodes everything outside RFC 3986's unreserved characters.
    static func formEscaped(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    struct TokenResponse: Equatable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresIn: TimeInterval
        var scopes: Set<String>

        init(json data: Data) throws {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
                throw ChatGPTPlanError.signInFailed("ChatGPT returned an unexpected token response.")
            }
            self.accessToken = accessToken
            refreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            idToken = (json["id_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600
            scopes = Set((json["scope"] as? String ?? "").split(separator: " ").map(String.init))
        }
    }

    /// Refresh errors after which the refresh token is unusable and the user
    /// must sign in again with the saved registration.
    static let terminalRefreshErrors: Set<String> = [
        "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
        "refresh_token_invalidated", "refresh_token_reused",
    ]

    /// The OAuth `error` code from a token-endpoint failure body.
    static func oauthErrorCode(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let code = json["error"] as? String { return code }
        return (json["error"] as? [String: Any])?["code"] as? String
    }

    static func randomToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: Substring) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }
}

enum ChatGPTPlanError: LocalizedError, Equatable, Sendable {
    case signedOut
    case signInRequired
    case planUsageNotGranted
    case signInFailed(String)
    case usageLimitReached
    case notEligible(String)
    case unsupportedRequest(String)
    case misconfigured(String)

    var errorDescription: String? {
        switch self {
        case .signedOut:
            "Sign in with ChatGPT under Settings → Models → Think to use your ChatGPT plan."
        case .signInRequired:
            "Your ChatGPT sign-in expired or was disconnected. Sign in again under Settings → Models → Think."
        case .planUsageNotGranted:
            "This ChatGPT sign-in doesn't allow requests on your plan. Sign in again and allow plan usage, or use another provider."
        case .signInFailed(let detail):
            detail
        case .usageLimitReached:
            "Your ChatGPT plan's usage limit for LokalBot was reached. Check usage at chatgpt.com/settings/usage."
        case .notEligible(let detail):
            "This ChatGPT account can't use its plan in LokalBot: \(detail)"
        case .unsupportedRequest(let detail):
            "ChatGPT plan requests don't support this option: \(detail)"
        case .misconfigured(let detail):
            "ChatGPT plan configuration error: \(detail)"
        }
    }
}

// MARK: - ID token

/// Validates an OpenID Connect ID token from OpenAI: signature against the
/// issuer's published keys (RS256 or ES256), then issuer, audience, expiry
/// and nonce.
enum ChatGPTIDToken {
    struct Claims: Equatable, Sendable {
        var subject: String
        var email: String?
        var expiresAt: Date
    }

    struct JSONWebKey: Equatable, Sendable {
        var keyID: String?
        var keyType: String
        var modulus: Data?
        var exponent: Data?
        var x: Data?
        var y: Data?

        init?(json: [String: Any]) {
            guard let keyType = json["kty"] as? String else { return nil }
            self.keyType = keyType
            keyID = json["kid"] as? String
            modulus = (json["n"] as? String).flatMap { ChatGPTPlanOAuth.base64URLDecode(Substring($0)) }
            exponent = (json["e"] as? String).flatMap { ChatGPTPlanOAuth.base64URLDecode(Substring($0)) }
            x = (json["x"] as? String).flatMap { ChatGPTPlanOAuth.base64URLDecode(Substring($0)) }
            y = (json["y"] as? String).flatMap { ChatGPTPlanOAuth.base64URLDecode(Substring($0)) }
        }

        static func keySet(_ data: Data) -> [JSONWebKey] {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let keys = json["keys"] as? [[String: Any]] else { return [] }
            return keys.compactMap(JSONWebKey.init(json:))
        }
    }

    static func validate(_ token: String, keys: [JSONWebKey], clientID: String, nonce: String,
                         now: Date = Date()) throws -> Claims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = ChatGPTPlanOAuth.base64URLDecode(parts[0]),
              let payloadData = ChatGPTPlanOAuth.base64URLDecode(parts[1]),
              let signature = ChatGPTPlanOAuth.base64URLDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw invalid("malformed ID token")
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        let keyID = header["kid"] as? String
        let candidates = keys.filter { keyID == nil || $0.keyID == keyID }
        let verified: Bool
        switch header["alg"] as? String {
        case "RS256":
            verified = candidates.contains { $0.keyType == "RSA" && verifyRS256(signingInput, signature, key: $0) }
        case "ES256":
            verified = candidates.contains { $0.keyType == "EC" && verifyES256(signingInput, signature, key: $0) }
        default:
            throw invalid("unsupported signing algorithm")
        }
        guard verified else { throw invalid("signature check failed") }
        return try claims(payload, clientID: clientID, nonce: nonce, now: now)
    }

    static func claims(_ payload: [String: Any], clientID: String, nonce: String,
                       now: Date) throws -> Claims {
        guard payload["iss"] as? String == ChatGPTPlanOAuth.issuer else { throw invalid("wrong issuer") }
        let audiences = (payload["aud"] as? [String]) ?? (payload["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID) else { throw invalid("wrong audience") }
        guard let expiry = (payload["exp"] as? NSNumber)?.doubleValue,
              Date(timeIntervalSince1970: expiry) > now.addingTimeInterval(-60) else {
            throw invalid("expired")
        }
        guard payload["nonce"] as? String == nonce else { throw invalid("nonce mismatch") }
        guard let subject = payload["sub"] as? String, !subject.isEmpty else { throw invalid("no subject") }
        return Claims(subject: subject, email: payload["email"] as? String,
                      expiresAt: Date(timeIntervalSince1970: expiry))
    }

    private static func invalid(_ reason: String) -> ChatGPTPlanError {
        .signInFailed("ChatGPT's sign-in token couldn't be verified (\(reason)). Try again.")
    }

    static func verifyRS256(_ input: Data, _ signature: Data, key: JSONWebKey) -> Bool {
        guard let modulus = key.modulus, let exponent = key.exponent,
              let publicKey = rsaPublicKey(modulus: modulus, exponent: exponent) else { return false }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                     input as CFData, signature as CFData, nil)
    }

    static func verifyES256(_ input: Data, _ signature: Data, key: JSONWebKey) -> Bool {
        guard let x = key.x, let y = key.y,
              let publicKey = try? P256.Signing.PublicKey(rawRepresentation: x + y),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return publicKey.isValidSignature(ecdsa, for: input)
    }

    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(rsaPublicKeyDER(modulus: modulus, exponent: exponent) as CFData,
                                    attributes as CFDictionary, nil)
    }

    /// PKCS#1 RSAPublicKey: SEQUENCE { INTEGER modulus, INTEGER exponent }.
    static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xff), at: 0)
                remaining >>= 8
            }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ value: Data) -> Data {
            var bytes = Data(value.drop { $0 == 0 })
            if bytes.isEmpty { bytes = Data([0]) }
            if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02]) + length(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }
}
