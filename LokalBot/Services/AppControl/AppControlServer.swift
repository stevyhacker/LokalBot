import Foundation

/// The app end of the CLI control socket. Runs only while the person allows
/// external agents to change settings; accepts connections from this user
/// only and hands each request to the main actor.
final class AppControlServer {
    typealias Handler = @MainActor (AppControlRequest) async -> AppControlResponse

    let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.app-control", attributes: .concurrent)
    private var source: DispatchSourceRead?

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit {
        stop()
    }

    var isRunning: Bool { source != nil }

    func start() throws {
        guard source == nil else { return }
        // A socket left by a crashed run would make bind fail. The library
        // instance lock guarantees no other app serves this path.
        unlink(path)
        var address = try AppControlSocket.address(path: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AppControlSocket.lastError }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else {
            let error = AppControlSocket.lastError
            close(descriptor)
            unlink(path)
            throw error
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(descriptor) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        unlink(path)
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // Accepted sockets inherit O_NONBLOCK; requests use blocking I/O
            // bounded by the socket timeouts instead.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        guard AppControlSocket.peerIsCurrentUser(client) else {
            close(client)
            return
        }
        AppControlSocket.configure(client, timeout: 10)
        guard let line = try? AppControlSocket.readLine(client) else {
            close(client)
            return
        }
        let request = try? JSONDecoder().decode(AppControlRequest.self, from: line)
        let handler = self.handler
        Task { @MainActor in
            let response: AppControlResponse
            if let request {
                response = await handler(request)
            } else {
                response = .failure(.invalidRequest("The request is not a LokalBot control request."))
            }
            var line = (try? JSONEncoder().encode(response)) ?? Data()
            line.append(0x0A)
            let reply = line
            DispatchQueue.global(qos: .userInitiated).async {
                try? AppControlSocket.writeAll(client, reply)
                close(client)
            }
        }
    }
}
