import Foundation

final class LibraryInstanceLock {
    static let fileName = ".instance.lock"

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func acquire(root: URL, timeout: TimeInterval = 10) -> LibraryInstanceLock? {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(fileName).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return LibraryInstanceLock(descriptor: -1) }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            guard error == EWOULDBLOCK || error == EINTR else {
                return LibraryInstanceLock(descriptor: descriptor)
            }
            guard Date() < deadline else {
                close(descriptor)
                return nil
            }
            usleep(250_000)
        }
        return LibraryInstanceLock(descriptor: descriptor)
    }
}
