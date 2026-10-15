import Foundation
import Network
import XCTest
@testable import LokalBot

/// Autocomplete through a chat endpoint, against a loopback server that answers
/// the way OpenRouter does when a reply reaches `max_tokens`.
final class ChatContinuationEngineTests: XCTestCase {
    func testAReplyCutOffAtItsLimitKeepsItsText() async throws {
        let server = try ChatReplyFixture { _ in Self.reply("up on the migration timeline we", finish: "length") }
        try await server.start()
        defer { server.stop() }

        let text = try await engine(server).complete(Self.request())

        XCTAssertEqual(text, "up on the migration timeline we", "the normalizer trims it to a phrase")
        XCTAssertEqual(server.bodies.count, 1)
        XCTAssertEqual(server.bodies.first?["max_tokens"] as? Int, 32)
    }

    /// `z-ai/glm-5.3-flash` always reasons: on 2026-10-15 its 32-token reply
    /// ended inside the reasoning, and autocomplete showed only an error.
    func testAModelThatAlwaysReasonsIsAskedWithRoomForItFromThenOn() async throws {
        let server = try ChatReplyFixture { index in
            index == 0 ? Self.reply(nil, finish: "length") : Self.reply("up on the migration timeline.", finish: "stop")
        }
        try await server.start()
        defer { server.stop() }
        let engine = engine(server, model: "z-ai/glm-5.3-flash:nitro", dialect: .openRouter)

        let first = try await engine.complete(Self.request())
        XCTAssertEqual(first, "up on the migration timeline.")
        let budgets = server.bodies.map { $0["max_tokens"] as? Int }
        XCTAssertEqual(budgets, [32, 32 + ChatContinuationEngine.reasoningRoomTokens])
        let reasoning = server.bodies.first?["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "low", "this model cannot turn reasoning off")
        XCTAssertEqual(reasoning?["exclude"] as? Bool, true)

        _ = try await engine.complete(Self.request())
        XCTAssertEqual(server.bodies.count, 3, "the short budget is not tried again")
        XCTAssertEqual(server.bodies.last?["max_tokens"] as? Int, 32 + ChatContinuationEngine.reasoningRoomTokens)
    }

    func testReasoningThatNeverClosesIsNotASuggestion() async throws {
        let server = try ChatReplyFixture { index in
            index == 0 ? Self.reply("<think>The user is writing to Sarah about", finish: "length")
                : Self.reply("up on the cutover.", finish: "stop")
        }
        try await server.start()
        defer { server.stop() }

        let text = try await engine(server).complete(Self.request())

        XCTAssertEqual(text, "up on the cutover.")
        XCTAssertEqual(server.bodies.count, 2)
    }

    func testAModelThatOnlyReasonsSaysSo() async throws {
        let server = try ChatReplyFixture { _ in Self.reply("", finish: "length") }
        try await server.start()
        defer { server.stop() }

        do {
            _ = try await engine(server, model: "always-thinking").complete(Self.request())
            XCTFail("expected an error")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.hasPrefix("always-thinking reasoned until its reply ran out"), message)
        }
        XCTAssertEqual(server.bodies.count, 2)
    }

    func testAnEmptyReplyIsAnEmptySuggestion() async throws {
        let server = try ChatReplyFixture { _ in Self.reply(nil, finish: "stop") }
        try await server.start()
        defer { server.stop() }

        let text = try await engine(server).complete(Self.request())

        XCTAssertEqual(text, "")
        XCTAssertEqual(server.bodies.count, 1)
    }

    func testOtherTasksStillFailWhenCutOff() throws {
        let payload = Self.reply("half a summ", finish: "length")
        XCTAssertThrowsError(try OpenAICompatibleEngine.parseChatCompletion(Data(payload.utf8)))
        XCTAssertEqual(TextGenerationOptions(maxTokens: 10).keepsTruncatedReply, false)
    }

    private func engine(_ server: ChatReplyFixture, model: String = "m",
                        dialect: ChatCompletionDialect = .generic) -> ChatContinuationEngine {
        ChatContinuationEngine(base: OpenAICompatibleEngine(
            baseURL: server.url(path: "/v1"), model: model, apiKey: nil, chatDialect: dialect))
    }

    private static func request() -> CompletionRequest {
        CompletionRequest(prompt: "Hi Sarah, thanks for the update. I wanted to follow", maxTokens: 26,
                          temperature: 0.2, topP: 0.9, topK: 40, minP: 0.05, repeatPenalty: 1,
                          seed: 7, stop: ["\n"])
    }

    private static func reply(_ content: String?, finish: String) -> String {
        let message: [String: Any] = ["role": "assistant", "content": content ?? NSNull()]
        let body: [String: Any] = ["choices": [["message": message, "finish_reason": finish]]]
        let data = try? JSONSerialization.data(withJSONObject: body)
        return String(decoding: data ?? Data(), as: UTF8.self)
    }
}

/// Loopback-only chat server. Each request gets the JSON `reply` returns for
/// its position, and its body is kept for the test to read.
private final class ChatReplyFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "chat-reply-fixture")
    private let reply: @Sendable (Int) -> String
    private var received: [[String: Any]] = []
    var bodies: [[String: Any]] { queue.sync { received } }

    init(reply: @escaping @Sendable (Int) -> String) throws {
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
                    let body = bytes[boundary.upperBound...]
                    let index = self.received.count
                    self.received.append((try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:])
                    let json = Data(self.reply(index).utf8)
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(json.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
            }
            if complete { connection.cancel() } else { self.receive(connection, accumulated: bytes) }
        }
    }
}
