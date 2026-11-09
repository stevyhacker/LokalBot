import Foundation

/// Read-only Gmail API calls for one account. Every request is a `GET` to
/// `gmail.googleapis.com`; the client has no way to change mail, and Google
/// would refuse it under the `gmail.readonly` grant anyway.
struct GmailClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let host = "gmail.googleapis.com"
    static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    /// Retries after rate limits and server errors, with exponential backoff.
    static let maxAttempts = 4

    enum ThreadFormat: String, Sendable {
        /// Headers and labels only, for deciding whether a thread qualifies.
        case metadata
        /// Bodies too, for threads that qualified.
        case full
    }

    /// Headers a `metadata` fetch returns.
    static let metadataHeaders = [
        "From", "To", "Cc", "Subject", "Date", "Message-ID", "List-Unsubscribe", "List-Id",
        "Precedence", "Auto-Submitted",
    ]

    /// A current access token for this account.
    let accessToken: @Sendable () async throws -> String
    /// A fresh token after Gmail rejected `rejected` with HTTP 401.
    let tokenRejected: @Sendable (_ rejected: String) async throws -> String
    let transport: Transport
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func profile() async throws -> GmailProfile {
        try await get("profile")
    }

    /// Verified "Send mail as" addresses, the account's own included.
    func sendAsAddresses() async throws -> [String] {
        let list: GmailSendAsList = try await get("settings/sendAs")
        return list.addresses
    }

    /// Thread ids matching a Gmail search, newest first, up to `limit`.
    func threadIDs(query: String, limit: Int) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        repeat {
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxResults", value: String(min(500, max(1, limit - ids.count)))),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GmailThreadList = try await get("threads", query: items)
            ids.append(contentsOf: (page.threads ?? []).map(\.id))
            pageToken = page.nextPageToken
        } while pageToken != nil && ids.count < limit
        return Array(ids.prefix(limit))
    }

    /// One thread, or nil when Gmail no longer has it.
    func thread(id: String, format: ThreadFormat) async throws -> GmailThreadResource? {
        var items = [URLQueryItem(name: "format", value: format.rawValue)]
        if format == .metadata {
            items += Self.metadataHeaders.map { URLQueryItem(name: "metadataHeaders", value: $0) }
        }
        do {
            return try await get("threads/\(Self.pathSafe(id))", query: items)
        } catch GmailError.requestFailed(let status, _) where status == 404 {
            return nil
        }
    }

    struct Changes: Equatable, Sendable {
        var threadIDs: Set<String>
        var historyID: String
    }

    /// Threads changed since `historyID`. Throws `GmailError.historyExpired`
    /// when Gmail no longer keeps history that old.
    func changes(since historyID: String) async throws -> Changes {
        var threadIDs: Set<String> = []
        var latest = historyID
        var pageToken: String?
        repeat {
            var items = [
                URLQueryItem(name: "startHistoryId", value: historyID),
                URLQueryItem(name: "maxResults", value: "500"),
            ]
            for type in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] {
                items.append(URLQueryItem(name: "historyTypes", value: type))
            }
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: GmailHistoryList
            do {
                page = try await get("history", query: items)
            } catch GmailError.requestFailed(let status, _) where status == 404 {
                throw GmailError.historyExpired
            }
            for change in page.history ?? [] { threadIDs.formUnion(change.threadIDs) }
            if let next = page.historyId { latest = next }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return Changes(threadIDs: threadIDs, historyID: latest)
    }

    // MARK: Requests

    static func request(_ path: String, query: [URLQueryItem] = [], token: String) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        // URLComponents leaves "+" alone, which Google reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Gmail ids are hex; anything else is refused rather than escaped.
    static func pathSafe(_ id: String) -> String {
        id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } ? id : "invalid"
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var token = try await accessToken()
        var refreshed = false
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await transport(Self.request(path, query: query, token: token))
            } catch let error as URLError where Self.isTransient(error.code) && attempt + 1 < Self.maxAttempts {
                // A dropped connection or a Mac waking up: wait and try again.
                attempt += 1
                try await sleep(Self.backoff(attempt: attempt, retryAfter: nil))
                continue
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200...299).contains(status) {
                guard let value = try? JSONDecoder().decode(T.self, from: data) else {
                    throw GmailError.unexpectedResponse
                }
                return value
            }
            if status == 401, !refreshed {
                token = try await tokenRejected(token)
                refreshed = true
                continue
            }
            let reason = Self.errorReason(data)
            attempt += 1
            if Self.isRetryable(status: status, reason: reason), attempt < Self.maxAttempts {
                try await sleep(Self.backoff(attempt: attempt, retryAfter: http?.value(forHTTPHeaderField: "Retry-After")))
                continue
            }
            throw GmailError.requestFailed(status: status, reason: reason)
        }
    }

    static func isTransient(_ code: URLError.Code) -> Bool {
        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
         .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .dataNotAllowed,
         .internationalRoamingOff].contains(code)
    }

    static func isRetryable(status: Int, reason: String?) -> Bool {
        if status == 429 || (500...599).contains(status) { return true }
        // Gmail reports per-user rate limits as 403 with a reason.
        return status == 403 && ["rateLimitExceeded", "userRateLimitExceeded"].contains(reason ?? "")
    }

    static func backoff(attempt: Int, retryAfter: String?) -> Duration {
        if let retryAfter, let seconds = Double(retryAfter), seconds > 0 {
            return .seconds(min(seconds, 60))
        }
        return .seconds(Double(1 << min(attempt, 5)))
    }

    /// Google's `error.errors[0].reason`, else `error.status`.
    static func errorReason(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        if let errors = error["errors"] as? [[String: Any]], let reason = errors.first?["reason"] as? String {
            return reason
        }
        return error["status"] as? String
    }
}
