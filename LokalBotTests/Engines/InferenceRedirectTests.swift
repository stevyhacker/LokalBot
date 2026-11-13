import Foundation
import Network
import XCTest
@testable import LokalBot

final class InferenceRedirectTests: XCTestCase {
    func testOriginBoundaryRejectsHostPortSchemeAndCredentialChanges() {
        let original = URL(string: "https://inference.example/v1/chat")!
        XCTAssertTrue(InferenceURLSession.allowsRedirect(
            from: original, to: URL(string: "https://inference.example/v2/chat")))
        for destination in [
            "https://other.example/v1/chat", "http://inference.example/v1/chat",
            "https://inference.example:8443/v1/chat", "file:///tmp/context",
            "https://user:password@inference.example/v1/chat",
        ] {
            XCTAssertFalse(InferenceURLSession.allowsRedirect(from: original, to: URL(string: destination)))
        }
        XCTAssertFalse(InferenceURLSession.allowsRedirect(from: nil, to: original))
    }

    func testBufferedAndStreamingPOSTsDoNotReplayAcrossOrigins() async throws {
        for streaming in [false, true] {
            for status in [307, 308] {
                let destination = try RedirectHTTPFixture { _ in .ok }
                try await destination.start()
                defer { destination.stop() }
                let source = try RedirectHTTPFixture { _ in
                    .redirect(status, destination.url(path: "/receive").absoluteString)
                }
                try await source.start()
                defer { source.stop() }
                let session = InferenceURLSession.make(requestTimeout: 5, resourceTimeout: 10)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: source.url(path: "/start"))
                request.httpMethod = "POST"
                request.httpBody = Data("synthetic-private-context".utf8)
                request.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
                let response: URLResponse
                if streaming {
                    let (_, received) = try await session.bytes(for: request)
                    response = received
                } else {
                    let (_, received) = try await session.data(for: request)
                    response = received
                }
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
                XCTAssertEqual(source.requests.count, 1)
                XCTAssertTrue(destination.requests.isEmpty, "No prompt or credential may reach the redirect target")
            }
        }
    }

    func testSameOriginRedirectRetainsPOSTBodyForBothTransports() async throws {
        for streaming in [false, true] {
            let server = try RedirectHTTPFixture { request in
                request.hasPrefix("POST /start ") ? .redirect(307, "/receive") : .ok
            }
            try await server.start()
            defer { server.stop() }
            let session = InferenceURLSession.make(requestTimeout: 5, resourceTimeout: 10)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: server.url(path: "/start"))
            request.httpMethod = "POST"
            request.httpBody = Data("synthetic-private-context".utf8)
            let response: URLResponse
            if streaming {
                let (_, received) = try await session.bytes(for: request)
                response = received
            } else {
                let (_, received) = try await session.data(for: request)
                response = received
            }
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(server.requests.count, 2)
            XCTAssertTrue(server.requests.last?.hasPrefix("POST /receive ") == true)
            XCTAssertTrue(server.requests.last?.hasSuffix("synthetic-private-context") == true)
        }
    }
}

/// Loopback-only HTTP fixture. It waits for the full request body before
/// replying, making 307/308 replay observable without real work data.
private final class RedirectHTTPFixture: @unchecked Sendable {
    enum Reply {
        case ok
        case redirect(Int, String)

        var bytes: Data {
            switch self {
            case .ok: return Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8)
            case .redirect(let status, let location):
                return Data("HTTP/1.1 \(status) Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "inference-redirect-fixture")
    private let reply: @Sendable (String) -> Reply
    private var received: [String] = []
    var requests: [String] { queue.sync { received } }

    init(reply: @escaping @Sendable (String) -> Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.reply = reply
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self?.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func url(path: String) -> URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            let bytes = accumulated + (data ?? Data())
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
                let length = header.components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if bytes.count - boundary.upperBound >= length {
                    let request = String(decoding: bytes, as: UTF8.self)
                    self.received.append(request)
                    connection.send(content: self.reply(request).bytes, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
            }
            if complete { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
        }
    }
}
