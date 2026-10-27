import Foundation

/// Unix-domain socket plumbing shared by the app's control server and the
/// CLI. The socket lives in the library's 0700 `control/` folder; a root
/// whose path is too long for `sun_path` uses a per-user name in /tmp that
/// both sides derive the same way.
enum AppControlSocket {
    static let fileName = "app.sock"

    /// `sun_path` holds 104 bytes on macOS, including the terminating NUL.
    static let maximumPathBytes = 103

    static func path(controlDirectory: URL, userID: uid_t = getuid()) -> String {
        let preferred = controlDirectory.appendingPathComponent(fileName).path
        guard preferred.utf8.count > maximumPathBytes else { return preferred }
        return "/tmp/lokalbot-\(userID)-\(fnv1a(controlDirectory.standardizedFileURL.path)).sock"
    }

    static func address(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count <= maximumPathBytes else { throw POSIXError(.ENAMETOOLONG) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return address
    }

    /// Opens a connected client socket, refusing a socket another user owns.
    static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw lastError }
        guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFSOCK else {
            throw POSIXError(.EACCES)
        }
        var socketAddress = try Self.address(path: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw lastError }
        let connected = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let error = lastError
            Darwin.close(descriptor)
            throw error
        }
        configure(descriptor, timeout: timeout)
        return descriptor
    }

    /// Blocking I/O with a deadline, and no SIGPIPE when the peer is gone.
    static func configure(_ descriptor: Int32, timeout: TimeInterval) {
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let seconds = max(0.1, timeout)
        var interval = timeval(
            tv_sec: Int(seconds),
            tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    }

    /// True when the connected peer runs as this process's user.
    static func peerIsCurrentUser(_ descriptor: Int32) -> Bool {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        return getpeereid(descriptor, &userID, &groupID) == 0 && userID == getuid()
    }

    /// Reads one newline-terminated record, without the newline.
    static func readLine(_ descriptor: Int32, limit: Int = AppControlProtocol.maximumMessageBytes) throws -> Data {
        var record = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw lastError
            }
            if count == 0 { return record }
            let chunk = buffer.prefix(count)
            if let newline = chunk.firstIndex(of: 0x0A) {
                record.append(contentsOf: chunk[..<newline])
                return record
            }
            record.append(contentsOf: chunk)
            guard record.count <= limit else { throw POSIXError(.EMSGSIZE) }
        }
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw lastError
                }
                offset += written
            }
        }
    }

    static var lastError: POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
