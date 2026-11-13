import Foundation

/// Shared ownership contract for exports and routines. A marker identifies a
/// generated file; only the recorded hash grants permission to replace it.
enum GeneratedFileWriter {
    enum WriteError: Error {
        case collision, modified, unsafeDestination
    }

    static let sidecarSuffix = ".lokalbot-generated.sha256"

    static func sidecarURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)\(sidecarSuffix)")
    }

    /// Returns false when identical bytes were already present. Legacy files
    /// can be adopted only in that case, without replacing their content.
    static func write(_ data: Data, to url: URL, marker: String) throws -> Bool {
        let manager = FileManager.default
        let sidecar = sidecarURL(for: url)
        try rejectSymlink(url)
        try rejectSymlink(sidecar)
        let newDigest = ContentFingerprint.digest(data)
        try Task.checkCancellation()
        if manager.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            guard String(decoding: existing, as: UTF8.self).contains(marker) else {
                throw WriteError.collision
            }
            if existing == data {
                try setPrivatePermissions(url)
                try record(newDigest, at: sidecar)
                return false
            }
            let recorded = try? String(contentsOf: sidecar, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard recorded == "v1:\(ContentFingerprint.digest(existing))" else {
                throw WriteError.modified
            }
            try Task.checkCancellation()
            guard try Data(contentsOf: url) == existing else { throw WriteError.modified }
        }
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        // Complete permissions/ownership after committing bytes, even if the
        // calling task was cancelled immediately after the write.
        try setPrivatePermissions(url)
        try record(newDigest, at: sidecar)
        return true
    }

    private static func rejectSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw WriteError.unsafeDestination
        }
    }

    private static func record(_ digest: String, at url: URL) throws {
        let data = Data("v1:\(digest)\n".utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        try setPrivatePermissions(url)
    }

    private static func setPrivatePermissions(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
