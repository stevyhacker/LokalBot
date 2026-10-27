import CryptoKit
import Foundation
import XCTest
@testable import LokalBot

/// An in-memory Keychain for email tests.
final class MemoryEmailSecrets: EmailSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var client: GoogleOAuthClient?
    private var stored: [UUID: EmailCredentials] = [:]
    private var credentialReads = 0
    /// Every credential read throws this, as a locked keychain would.
    var readError: Error?
    var reads: Int { lock.withLock { credentialReads } }

    init(client: GoogleOAuthClient? = GmailFixtures.client, credentials: [UUID: EmailCredentials] = [:]) {
        self.client = client
        stored = credentials
    }

    func googleClient() -> GoogleOAuthClient? { lock.withLock { client } }
    func setGoogleClient(_ client: GoogleOAuthClient?) { lock.withLock { self.client = client } }
    func credentials(for accountID: UUID) throws -> EmailCredentials? {
        try lock.withLock {
            credentialReads += 1
            if let readError { throw readError }
            return stored[accountID]
        }
    }
    func setCredentials(_ credentials: EmailCredentials?, for accountID: UUID) {
        lock.withLock { stored[accountID] = credentials }
    }
}

enum GmailFixtures {
    static let client = GoogleOAuthClient(clientID: "123-test.apps.googleusercontent.com", clientSecret: "test-secret")
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let me = "me@example.com"
    static let alias = "me@work.example"

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func response(_ request: URLRequest, _ status: Int, headers: [String: String]? = nil) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    static func query(_ url: URL?) -> [String: [String]] {
        var items: [String: [String]] = [:]
        for item in URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            items[item.name, default: []].append(item.value ?? "")
        }
        return items
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

    static func base64URL(_ text: String, encoding: String.Encoding = .utf8) -> String {
        ChatGPTPlanOAuth.base64URL(text.data(using: encoding) ?? Data())
    }

    static func key() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lokalbot-email-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One message in the fake mailbox.
struct FakeGmailMessage {
    var id: String
    var labels: [String] = ["INBOX"]
    var date: Date
    var from: String
    var to: String = GmailFixtures.me
    var cc: String?
    var subject = "Launch plan"
    var extraHeaders: [String: String] = [:]
    var plain: String? = "Hello"
    var html: String?
    var attachment: (name: String, mimeType: String, size: Int)?

    var fromAddress: String { EmailText.address(from)?.address ?? from }

    func headers() -> [[String: String]] {
        var headers = [
            ["name": "From", "value": from],
            ["name": "To", "value": to],
            ["name": "Subject", "value": subject],
            ["name": "Message-ID", "value": "<\(id)@mail.example.com>"],
        ]
        if let cc { headers.append(["name": "Cc", "value": cc]) }
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            headers.append(["name": name, "value": value])
        }
        return headers
    }

    func resource(threadID: String, format: GmailClient.ThreadFormat) -> [String: Any] {
        var payload: [String: Any] = ["mimeType": "multipart/mixed", "headers": headers()]
        if format == .metadata {
            let wanted = Set(GmailClient.metadataHeaders.map { $0.lowercased() })
            payload["headers"] = headers().filter { wanted.contains(($0["name"] ?? "").lowercased()) }
        } else {
            var parts: [[String: Any]] = []
            var alternative: [[String: Any]] = []
            if let plain {
                alternative.append(["mimeType": "text/plain", "filename": "",
                                    "headers": [["name": "Content-Type", "value": "text/plain; charset=UTF-8"]],
                                    "body": ["size": plain.utf8.count, "data": GmailFixtures.base64URL(plain)]])
            }
            if let html {
                alternative.append(["mimeType": "text/html", "filename": "",
                                    "headers": [["name": "Content-Type", "value": "text/html; charset=UTF-8"]],
                                    "body": ["size": html.utf8.count, "data": GmailFixtures.base64URL(html)]])
            }
            parts.append(["mimeType": "multipart/alternative", "parts": alternative])
            if let attachment {
                parts.append(["mimeType": attachment.mimeType, "filename": attachment.name,
                              "body": ["size": attachment.size, "attachmentId": "att-\(id)"]])
            }
            payload["parts"] = parts
        }
        return [
            "id": id, "threadId": threadID, "labelIds": labels,
            "internalDate": String(Int64(date.timeIntervalSince1970 * 1_000)), "payload": payload,
        ]
    }
}

/// A Gmail API that answers from an in-memory mailbox and records every
/// request. It understands the two kinds of search LokalBot sends.
final class FakeGmailServer: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [String: [FakeGmailMessage]] = [:]
    private var changedThreads: Set<String> = []
    private(set) var historyID = 100
    var historyExpired = false
    var aliases: [String] = [GmailFixtures.alias]
    /// Answer this many thread fetches, then keep answering rate limits.
    var failThreadFetchesAfter: Int?
    /// These threads always answer HTTP 500.
    var failingThreads: Set<String> = []
    /// The next request loses its connection.
    var dropNextConnection = false
    private var threadFetches = 0
    private(set) var requests: [URLRequest] = []

    func put(_ threadID: String, _ messages: [FakeGmailMessage]) {
        lock.withLock {
            threads[threadID] = messages
            changedThreads.insert(threadID)
            historyID += 1
        }
    }

    func remove(_ threadID: String) {
        lock.withLock {
            threads[threadID] = nil
            changedThreads.insert(threadID)
            historyID += 1
        }
    }

    /// Forget changes so far, as if a sync had read them.
    func markRead() { lock.withLock { changedThreads.removeAll() } }

    var queries: [String] {
        lock.withLock {
            requests.compactMap { request in
                request.url?.path.hasSuffix("/threads") == true ? GmailFixtures.query(request.url)["q"]?.first : nil
            }
        }
    }

    func requestCount(pathSuffix: String) -> Int {
        lock.withLock { requests.filter { $0.url?.path.hasSuffix(pathSuffix) == true }.count }
    }

    var transport: GmailClient.Transport {
        { [self] request in try handle(request) }
    }

    private func handle(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        if dropNextConnection {
            dropNextConnection = false
            throw URLError(.networkConnectionLost)
        }
        guard let url = request.url, url.host == GmailClient.host else {
            return (Data(), GmailFixtures.response(request, 404))
        }
        let path = url.path.replacingOccurrences(of: "/gmail/v1/users/me/", with: "")
        let query = GmailFixtures.query(url)
        switch path {
        case "profile":
            return ok(request, ["emailAddress": "Me@Example.com", "historyId": String(historyID)])
        case "settings/sendAs":
            let entries = [["sendAsEmail": GmailFixtures.me, "isPrimary": true] as [String: Any]]
                + aliases.map { ["sendAsEmail": $0, "verificationStatus": "accepted"] }
            return ok(request, ["sendAs": entries])
        case "threads":
            let ids = search(query["q"]?.first ?? "")
            return ok(request, ["threads": ids.map { ["id": $0] }, "resultSizeEstimate": ids.count])
        case "history":
            if historyExpired { return (Data(), GmailFixtures.response(request, 404)) }
            let changes = changedThreads.sorted().map { id in
                ["messagesAdded": [["message": ["id": "m-\(id)", "threadId": id]]]]
            }
            return ok(request, ["history": changes, "historyId": String(historyID)])
        default:
            guard path.hasPrefix("threads/") else { return (Data(), GmailFixtures.response(request, 404)) }
            threadFetches += 1
            if let limit = failThreadFetchesAfter, threadFetches > limit {
                return (GmailFixtures.json(["error": ["code": 429, "status": "RESOURCE_EXHAUSTED"]]),
                        GmailFixtures.response(request, 429))
            }
            let id = String(path.dropFirst("threads/".count))
            if failingThreads.contains(id) { return (Data(), GmailFixtures.response(request, 500)) }
            guard let messages = threads[id] else { return (Data(), GmailFixtures.response(request, 404)) }
            let format = GmailClient.ThreadFormat(rawValue: query["format"]?.first ?? "full") ?? .full
            return ok(request, ["id": id, "messages": messages.map { $0.resource(threadID: id, format: format) }])
        }
    }

    private func ok(_ request: URLRequest, _ object: Any) -> (Data, URLResponse) {
        (GmailFixtures.json(object), GmailFixtures.response(request, 200))
    }

    private func after(_ q: String) -> Date {
        guard let range = q.range(of: #"after:(\d+)"#, options: .regularExpression) else { return .distantPast }
        return Date(timeIntervalSince1970: Double(q[range].dropFirst("after:".count)) ?? 0)
    }

    private func search(_ q: String) -> [String] {
        let start = after(q)
        let hidden: Set<String> = ["SPAM", "TRASH"]
        if q.hasPrefix("in:sent") {
            return threads.keys.sorted().filter { id in
                threads[id]!.contains { $0.labels.contains("SENT") && hidden.isDisjoint(with: $0.labels) && $0.date >= start }
            }
        }
        let addresses = Set(q.matches(of: #/(?:from|to|cc):([^\s}]+)/#).map { String($0.output.1) })
        return threads.keys.sorted().filter { id in
            threads[id]!.contains { message in
                guard hidden.isDisjoint(with: message.labels), message.date >= start,
                      message.labels.allSatisfy({ !EmailScope.bulkCategories.contains($0) }) else { return false }
                var people = Set([message.fromAddress])
                for header in [message.to, message.cc ?? ""] {
                    for address in EmailText.addresses(header) { people.insert(address.address) }
                }
                return !people.isDisjoint(with: addresses)
            }
        }
    }
}
