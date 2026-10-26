import Foundation
import Network

/// A one-shot HTTP listener on 127.0.0.1 that receives an OAuth redirect.
/// It binds to the loopback address only, answers the first request for
/// `path` with a short page, and hands its query to the waiting sign-in.
/// Other paths (a browser's favicon request) get a 404 and are ignored.
final class LoopbackRedirectListener: @unchecked Sendable {
    enum ListenerError: LocalizedError {
        case couldNotListen(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .couldNotListen(let detail):
                "LokalBot couldn't start its sign-in listener on this Mac: \(detail)"
            case .timedOut:
                "Sign-in timed out. Start it again when you're ready."
            }
        }
    }

    let port: UInt16
    let path: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.oauth-loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    private init(listener: NWListener, port: UInt16, path: String) {
        self.listener = listener
        self.port = port
        self.path = path
    }

    /// Listens on `preferredPort`, or on any free port when it is taken.
    static func start(preferredPort: UInt16, path: String) async throws -> LoopbackRedirectListener {
        if preferredPort != 0, let listener = try? await start(port: preferredPort, path: path) {
            return listener
        }
        return try await start(port: 0, path: path)
    }

    private static func start(port: UInt16, path: String) async throws -> LoopbackRedirectListener {
        let listener: NWListener
        let boundPort: UInt16
        do {
            (listener, boundPort) = try await LoopbackListener.bind(port: port)
        } catch let error as LoopbackListener.BindError {
            throw ListenerError.couldNotListen(error.detail)
        }
        let redirect = LoopbackRedirectListener(listener: listener, port: boundPort, path: path)
        listener.stateUpdateHandler = { [weak redirect] state in
            if case .failed(let error) = state {
                redirect?.finish(.failure(ListenerError.couldNotListen(error.localizedDescription)))
            }
        }
        listener.newConnectionHandler = { [weak redirect] connection in
            redirect?.handle(connection)
        }
        return redirect
    }

    /// The redirect's query items. Throws on timeout or cancellation.
    func waitForCallback(timeout: Duration) async throws -> [String: String] {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.finish(.failure(ListenerError.timedOut))
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let header = Self.requestTarget(buffer) {
                self.respond(to: header, on: connection)
            } else if error != nil || complete || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// The request-target of a complete `GET` request head, or nil.
    static func requestTarget(_ buffer: Data) -> String? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8),
              let line = head.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" else { return "" }
        return String(parts[1])
    }

    static func query(fromTarget target: String) -> [String: String] {
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return [:] }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        return query
    }

    private func respond(to target: String, on connection: NWConnection) {
        let targetPath = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard targetPath == path else {
            send("404 Not Found", body: "Not found.", on: connection)
            return
        }
        let query = Self.query(fromTarget: target)
        let denied = query["error"] != nil
        send("200 OK", body: denied
             ? "Sign-in was cancelled. You can close this tab and return to LokalBot."
             : "You can close this tab and return to LokalBot.",
             on: connection)
        finish(.success(query))
    }

    private func send(_ status: String, body: String, on connection: NWConnection) {
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><title>LokalBot</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;margin:15vh auto;max-width:28em;\
        padding:0 1em;color:#1d1d1f}@media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}</style>
        </head><body><p>\(body)</p></body></html>
        """
        let bytes = Data(page.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// A TCP listener bound to 127.0.0.1 only, so nothing off this Mac can reach
/// it. Shared by the sign-in redirect and Agent Mode's ChatGPT plan relay.
enum LoopbackListener {
    struct BindError: Error {
        let detail: String
    }

    /// A started listener on `port`, or on any free port when it is 0. It
    /// refuses connections until the caller installs its own handler.
    static func bind(port: UInt16) async throws -> (listener: NWListener, port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw BindError(detail: error.localizedDescription)
        }
        let queue = DispatchQueue(label: "me.dotenv.LokalBot.loopback.start")
        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: listener.port?.rawValue ?? port) }
                case .failed(let error), .waiting(let error):
                    listener.cancel()
                    if once.claim() { continuation.resume(throwing: BindError(detail: error.localizedDescription)) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: BindError(detail: "cancelled")) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        return (listener, boundPort)
    }
}

/// Resumes a continuation at most once from concurrent callbacks.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
