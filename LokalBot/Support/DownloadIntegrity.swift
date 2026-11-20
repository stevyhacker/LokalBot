import Foundation

enum DownloadIntegrity {
    enum IntegrityError: LocalizedError {
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .mismatch(let name):
                "The downloaded file \(name) failed its SHA-256 integrity check."
            }
        }
    }

    static func verifiedExisting(at url: URL, expectedBytes: Int64,
                                 expectedSHA256: String) async -> Bool {
        (try? await verifyExisting(
            at: url,
            expectedBytes: expectedBytes,
            expectedSHA256: expectedSHA256)) == true
    }

    static func verifyExisting(at url: URL, expectedBytes: Int64,
                               expectedSHA256: String) async throws -> Bool {
        try Task.checkCancellation()
        guard try checkedSize(of: url) == expectedBytes else { return false }
        let expected = expectedSHA256.lowercased()
        if (try? String(contentsOf: markerURL(for: url), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) == expected {
            return true
        }
        guard try await digest(of: url) == expected else { return false }
        try Task.checkCancellation()
        try? expected.write(to: markerURL(for: url), atomically: true, encoding: .utf8)
        return true
    }

    static func verifyDownloaded(at url: URL, expectedBytes: Int64,
                                 expectedSHA256: String) async throws {
        let expected = expectedSHA256.lowercased()
        guard exactSize(of: url) == expectedBytes,
              try await digest(of: url) == expected else {
            throw IntegrityError.mismatch(url.lastPathComponent)
        }
        try expected.write(to: markerURL(for: url), atomically: true, encoding: .utf8)
    }

    static func removeFileAndMarker(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: markerURL(for: url))
    }

    static func markInstalled(at url: URL, expectedBytes: Int64,
                              expectedSHA256: String) throws {
        guard exactSize(of: url) == expectedBytes else {
            throw IntegrityError.mismatch(url.lastPathComponent)
        }
        try expectedSHA256.lowercased().write(
            to: markerURL(for: url), atomically: true, encoding: .utf8)
    }

    private static func exactSize(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private static func checkedSize(of url: URL) throws -> Int64? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private static func digest(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try SHA256Verifier.hexDigest(of: url)
        }.value
    }

    private static func markerURL(for url: URL) -> URL {
        url.appendingPathExtension("sha256")
    }
}
