import Foundation
import Network

final class ChatGPTPlanRelay: @unchecked Sendable {
    typealias TokenSource = @Sendable (_ rejected: String?) async throws -> String
    typealias Upstream = @Sendable (URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)

    enum RelayError: LocalizedError {
        case couldNotListen(String)

        var errorDescription: String? {
            switch self {
            case .couldNotListen(let detail):
                "LokalBot couldn't open its ChatGPT plan connection for Agent Mode: \(detail)"
            }
        }
    }

    static let path = "/v1/responses"
    static let maximumRequestBytes = 32 << 20
    static let maximumHeadBytes = 64 << 10
    static let maximumErrorBytes = 1 << 20

    let port: UInt16
    let key: String
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    private let listener: NWListener
    private let tokens: TokenSource
    private let upstream: Upstream
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.chatgpt-plan-relay")
    private let lock = NSLock()
    private var exchanges: [ObjectIdentifier: Exchange] = [:]
    private var stopped = false

    private final class Exchange {
        let connection: NWConnection
        var buffer = Data()
        var task: Task<Void, Never>?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private init(listener: NWListener, port: UInt16, key: String, tokens: @escaping TokenSource,
                 upstream: @escaping Upstream) {
        self.listener = listener
        self.port = port
        self.key = key
        self.tokens = tokens
        self.upstream = upstream
    }

    static func start(tokens: @escaping TokenSource = accountTokens,
                      upstream: @escaping Upstream = liveUpstream) async throws -> ChatGPTPlanRelay {
        let listener: NWListener
        let port: UInt16
        do {
            (listener, port) = try await LoopbackListener.bind(port: 0)
        } catch let error as LoopbackListener.BindError {
            throw RelayError.couldNotListen(error.detail)
        }
        let relay = ChatGPTPlanRelay(listener: listener, port: port, key: ChatGPTPlanOAuth.randomToken(),
                                     tokens: tokens, upstream: upstream)
        listener.newConnectionHandler = { [weak relay] connection in
            guard let relay else { return connection.cancel() }
            relay.accept(connection)
        }
        return relay
    }

    func stop() {
        lock.lock()
        stopped = true
        let open = Array(exchanges.values)
        exchanges.removeAll()
        lock.unlock()
        listener.cancel()
        for exchange in open {
            exchange.task?.cancel()
            exchange.connection.cancel()
        }
    }

    static let accountTokens: TokenSource = { rejected in
        if let rejected { return try await ChatGPTPlanAccount.shared.accessTokenAfterRejection(of: rejected) }
        return try await ChatGPTPlanAccount.shared.accessToken()
    }

    static let liveUpstream: Upstream = { request in
        let (bytes, response) = try await llmSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let reader = Task {
                var chunk = Data()
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == UInt8(ascii: "\n") || chunk.count >= 16_384 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        return (http, body)
    }

    private func accept(_ connection: NWConnection) {
        let exchange = Exchange(connection: connection)
        let id = ObjectIdentifier(exchange)
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return connection.cancel()
        }
        exchanges[id] = exchange
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(exchange, id: id)
    }

    private func close(_ id: ObjectIdentifier) {
        lock.lock()
        let exchange = exchanges.removeValue(forKey: id)
        lock.unlock()
        exchange?.task?.cancel()
        exchange?.connection.cancel()
    }

    private func receive(_ exchange: Exchange, id: ObjectIdentifier) {
        exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return exchange.connection.cancel() }
            if let data { exchange.buffer.append(data) }
            switch ChatGPTPlanRelayRequest.read(exchange.buffer, key: self.key) {
            case .incomplete:
                if error != nil || complete {
                    self.close(id)
                } else {
                    self.receive(exchange, id: id)
                }
            case .rejected(let status, let message):
                exchange.buffer = Data()
                self.run(exchange, id: id) { [self] in
                    await self.reply(status: status, message: message, retry: false, on: exchange.connection)
                }
            case .complete(let body):
                exchange.buffer = Data()
                self.watchForHangUp(exchange, id: id)
                self.run(exchange, id: id) { [self] in await self.forward(body, on: exchange.connection) }
            }
        }
    }

    private func watchForHangUp(_ exchange: Exchange, id: ObjectIdentifier) {
        exchange.connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            if complete || error != nil { self?.close(id) }
        }
    }

    private func run(_ exchange: Exchange, id: ObjectIdentifier, _ work: @escaping @Sendable () async -> Void) {
        let task = Task { [weak self] in
            await work()
            self?.close(id)
        }
        lock.lock()
        if exchanges[id] == nil {
            lock.unlock()
            task.cancel()
            return
        }
        exchange.task = task
        lock.unlock()
    }

    private func forward(_ body: Data, on connection: NWConnection) async {
        let started = Date()
        let prepared: Data
        do {
            prepared = try ChatGPTPlanRelayPolicy.upstreamBody(body)
        } catch {
            return await reply(status: 400, message: "The Agent request wasn't valid Responses JSON.", retry: false,
                               on: connection)
        }
        var rejected: String?
        for attempt in 0..<2 {
            let token: String
            do {
                token = try await tokens(rejected)
            } catch {
                guard !Task.isCancelled else { return }
                let planError = error is ChatGPTPlanError
                lokalbotLog("chatgpt plan relay token unavailable plan_error=\(planError)")
                return await reply(status: planError ? 401 : 502, message: error.localizedDescription,
                                   retry: planError ? false : nil, on: connection)
            }
            var request = URLRequest(url: ChatGPTPlanEngine.responsesURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = prepared
            let response: HTTPURLResponse
            let stream: AsyncThrowingStream<Data, Error>
            do {
                (response, stream) = try await upstream(request)
            } catch {
                guard !Task.isCancelled else { return }
                lokalbotLog("chatgpt plan relay unreachable code=\((error as NSError).code)")
                return await reply(status: 502, message: "LokalBot couldn't reach OpenAI for your ChatGPT plan.",
                                   retry: nil, on: connection)
            }
            if response.statusCode == 401, attempt == 0 {
                rejected = token
                continue
            }
            if (200...299).contains(response.statusCode) {
                await relayStream(response, body: stream, on: connection, started: started)
            } else {
                await relayError(response, body: stream, on: connection)
            }
            return
        }
    }

    private func relayStream(_ response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>,
                             on connection: NWConnection, started: Date) async {
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "text/event-stream"
        let head = "HTTP/1.1 \(response.statusCode) OK\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\n"
            + "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        var bytes = 0
        do {
            try await send(Data(head.utf8), on: connection)
            for try await chunk in body where !chunk.isEmpty {
                bytes += chunk.count
                try await send(Data(String(chunk.count, radix: 16).utf8) + Data("\r\n".utf8) + chunk + Data("\r\n".utf8),
                               on: connection)
            }
            try await send(Data("0\r\n\r\n".utf8), on: connection, final: true)
            lokalbotLog("chatgpt plan relay status=\(response.statusCode) bytes=\(bytes) "
                        + "seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
        } catch {
            lokalbotLog("chatgpt plan relay stream ended early bytes=\(bytes) cancelled=\(Task.isCancelled)")
        }
    }

    private func relayError(_ response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>,
                            on connection: NWConnection) async {
        var data = Data()
        do {
            for try await chunk in body {
                data.append(chunk.prefix(Self.maximumErrorBytes - data.count))
                if data.count >= Self.maximumErrorBytes { break }
            }
        } catch {
            guard !Task.isCancelled else { return }
        }
        let error = ChatGPTPlanEngine.errorObject(data)
        lokalbotLog("chatgpt plan relay status=\(response.statusCode) code=\(error.code ?? "-")")
        var headers = ["Content-Type": response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"]
        for name in ["Retry-After", "Retry-After-Ms"] {
            if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
        }
        if let retry = ChatGPTPlanRelayPolicy.shouldRetry(code: error.code, message: error.message, param: error.param) {
            headers["X-Should-Retry"] = retry ? "true" : "false"
        }
        await send(status: response.statusCode, headers: headers, body: data, on: connection)
    }

    private func reply(status: Int, message: String, retry: Bool?, on connection: NWConnection) async {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "error": ["message": message, "type": "lokalbot_chatgpt_plan_relay"],
        ])) ?? Data()
        var headers = ["Content-Type": "application/json"]
        if let retry { headers["X-Should-Retry"] = retry ? "true" : "false" }
        await send(status: status, headers: headers, body: body, on: connection)
    }

    private func send(status: Int, headers: [String: String], body: Data, on connection: NWConnection) async {
        var head = "HTTP/1.1 \(status) \(status < 400 ? "OK" : "Error")\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        try? await send(Data(head.utf8) + body, on: connection, final: true)
    }

    private func send(_ data: Data, on connection: NWConnection, final: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: final ? .finalMessage : .defaultMessage,
                            isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

extension ChatGPTPlanRelay: Equatable {
    static func == (lhs: ChatGPTPlanRelay, rhs: ChatGPTPlanRelay) -> Bool { lhs === rhs }
}

enum ChatGPTPlanRelayRequest: Equatable {
    case incomplete
    case rejected(status: Int, message: String)
    case complete(body: Data)

    static func read(_ buffer: Data, key: String) -> Self {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > ChatGPTPlanRelay.maximumHeadBytes
                ? .rejected(status: 431, message: "The request head is too large.") : .incomplete
        }
        guard headEnd.lowerBound - buffer.startIndex <= ChatGPTPlanRelay.maximumHeadBytes,
              let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            return .rejected(status: 431, message: "The request head is too large.")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return .rejected(status: 400, message: "Malformed request.") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(status: 400, message: "Malformed request.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard headers[name] == nil else { return .rejected(status: 400, message: "Repeated \(name) header.") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = requestLine[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard requestLine[0] == "POST", path == ChatGPTPlanRelay.path else {
            return .rejected(status: 404, message: "Only POST \(ChatGPTPlanRelay.path) is relayed.")
        }
        guard headers["origin"] == nil else { return .rejected(status: 403, message: "Browser requests are refused.") }
        guard let authorization = headers["authorization"],
              constantTimeEqual(authorization, "Bearer \(key)") else {
            return .rejected(status: 401, message: "This Agent session's relay key was not presented.")
        }
        guard headers["transfer-encoding"] == nil, let declared = headers["content-length"],
              let length = Int(declared), length >= 0 else {
            return .rejected(status: 411, message: "A Content-Length is required.")
        }
        guard length <= ChatGPTPlanRelay.maximumRequestBytes else {
            return .rejected(status: 413, message: "The Agent request is too large for the ChatGPT plan relay.")
        }
        let bodyStart = headEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        return .complete(body: Data(buffer[bodyStart..<bodyStart + length]))
    }

    static func constantTimeEqual(_ presented: String, _ expected: String) -> Bool {
        let presented = Array(presented.utf8)
        let expected = Array(expected.utf8)
        guard presented.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= presented[index] ^ expected[index] }
        return difference == 0
    }
}

enum ChatGPTPlanRelayPolicy {
    static let unsupportedFields: Set<String> = [
        "background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation",
        "multi_agent", "previous_response_id", "prompt", "prompt_cache_options", "prompt_cache_retention",
        "safety_identifier", "service_tier", "temperature", "top_logprobs", "top_p", "truncation", "user",
    ]

    enum PolicyError: Error {
        case invalidBody
    }

    static func upstreamBody(_ data: Data) throws -> Data {
        guard var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["model"] is String, let input = body["input"] as? [Any] else {
            throw PolicyError.invalidBody
        }
        for field in unsupportedFields { body.removeValue(forKey: field) }
        body["store"] = false
        body["stream"] = true
        body["input"] = input.map { item -> Any in
            guard var message = item as? [String: Any], message["role"] as? String == "system" else { return item }
            message["role"] = "developer"
            return message
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func shouldRetry(code: String?, message: String?, param: String?) -> Bool? {
        guard let error = ChatGPTPlanEngine.planError(code: code, message: message, param: param) else { return nil }
        return !(error is ChatGPTPlanError)
    }
}
