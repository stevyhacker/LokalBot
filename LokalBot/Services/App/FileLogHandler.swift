import Foundation
import Logging

/// Backing store for ``FileLogHandler``: owns the on-disk file handle, the
/// running byte count, and the lock that serializes both writes and rotation.
///
/// Why a separate reference type:
/// swift-log copies a `LogHandler` value per `Logger`, and `AppLog` hands the
/// same file destination to every category's handler. If the handle lived in
/// the struct, each category would copy it and open its own descriptor to one
/// file — interleaving writes and racing rotation. Centralizing the mutable
/// state in one shared object, guarded by a lock, is the only correct shape.
///
/// `@unchecked Sendable`: the mutable members (`handle`, `byteOffset`) are only
/// ever touched while `lock` is held, and `FileHandle` is not `Sendable`, so
/// the conformance cannot be derived automatically.
final class FileLogSink: @unchecked Sendable {
    private let fileURL: URL
    let sizeCapBytes: UInt64
    let maxRotations: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var byteOffset: UInt64 = 0

    /// `sizeCapBytes` defaults to 8 MB and five rotations are kept (`.1` is
    /// the newest), about 40 MB in total — enough for a full working day of
    /// diagnostics, which a single 2 MB backup could not hold.
    init(fileURL: URL, sizeCapBytes: UInt64 = 8 * 1024 * 1024, maxRotations: Int = 5) {
        self.fileURL = fileURL
        self.sizeCapBytes = sizeCapBytes
        self.maxRotations = max(1, maxRotations)
        // Safe to touch the locked body directly: the sink is not yet shared.
        openHandleLocked()
    }

    /// Rotated files, newest first.
    static func rotatedURLs(for fileURL: URL, maxRotations: Int) -> [URL] {
        (1...max(1, maxRotations)).map { fileURL.appendingPathExtension(String($0)) }
    }

    /// Appends one already-formatted line (the caller supplies the trailing
    /// newline). The size check runs first so the line that crosses the cap
    /// lands in the fresh file, keeping the live log's tail readable; the
    /// handle is read *after* rotation since rotation replaces it.
    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }

        if byteOffset >= sizeCapBytes {
            rotateLocked()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            byteOffset += UInt64(data.count)
        } catch {
            // A failed diagnostic write must never disrupt the app. Drop it.
        }
    }

    /// Shift `.1…(n-1)` to `.2…n` (dropping the oldest), then move the live
    /// file to `.1` and open a fresh empty file.
    private func rotateLocked() {
        try? handle?.close()
        handle = nil

        let fileManager = FileManager.default
        let rotated = Self.rotatedURLs(for: fileURL, maxRotations: maxRotations)
        try? fileManager.removeItem(at: rotated[rotated.count - 1])
        for index in stride(from: rotated.count - 1, to: 0, by: -1) {
            let source = rotated[index - 1]
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: rotated[index])
            }
        }
        let backupURL = rotated[0]

        // Only recreate an empty live file when the move actually displaced the
        // old one. If the move fails and the original is still present, writing
        // a fresh empty file over it would destroy the very history rotation is
        // meant to preserve.
        var displaced = true
        if fileManager.fileExists(atPath: fileURL.path) {
            displaced = (try? fileManager.moveItem(at: fileURL, to: backupURL)) != nil
        }
        if displaced {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        openHandleLocked()
    }

    /// Opens (and seeks to the end of) the live file, creating the containing
    /// directory and the file if absent. Callers hold `lock`, or run during
    /// `init` before the sink is shared.
    private func openHandleLocked() {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        byteOffset = (try? handle?.seekToEnd()) ?? 0
    }
}

/// A swift-log ``LogHandler`` that appends one formatted, human-readable line
/// per event to a shared ``FileLogSink``. This is LokalBot's on-disk diagnostic
/// sink — the file an operator (or an AI agent) can `tail` directly, and the
/// destination the legacy `lokalbotLog(_:)` shim is rerouted to.
///
/// Types are qualified as `Logging.*` because the module mixes logging
/// frameworks (`os.Logger` lives in other files); qualification keeps `Logger`
/// unambiguous regardless of a file's imports.
struct FileLogHandler: LogHandler {
    var logLevel: Logging.Logger.Level
    var metadata: Logging.Logger.Metadata = [:]

    private let label: String
    private let sink: FileLogSink

    init(label: String, sink: FileLogSink, logLevel: Logging.Logger.Level = .info) {
        self.label = label
        self.sink = sink
        self.logLevel = logLevel
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: Logging.LogEvent) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let category = Self.shortCategory(from: label)
        let merged = Self.merge(base: metadata, explicit: event.metadata)
        let suffix = merged.isEmpty ? "" : " " + Self.render(merged)
        sink.write(
            "\(timestamp) \(event.level.rawValue.uppercased()) "
                + "[\(category)] \(event.message)\(suffix)\n")
    }

    /// `me.dotenv.LokalBot.networking` → `networking`. The trailing dot-segment
    /// keeps each line short while still identifying the source category.
    private static func shortCategory(from label: String) -> String {
        label.split(separator: ".").last.map(String.init) ?? label
    }

    /// Merges handler-level metadata with the per-statement metadata, letting
    /// the explicit per-statement values win on key collisions.
    private static func merge(
        base: Logging.Logger.Metadata,
        explicit: Logging.Logger.Metadata?
    ) -> Logging.Logger.Metadata {
        guard let explicit, !explicit.isEmpty else { return base }
        return base.merging(explicit) { _, new in new }
    }

    private static func render(_ metadata: Logging.Logger.Metadata) -> String {
        metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    /// Shared formatter — `ISO8601DateFormatter` is thread-safe for formatting
    /// once configured, so reusing one avoids an allocation per line. Marked
    /// `nonisolated(unsafe)` because the type is not `Sendable`; concurrent use
    /// is safe per Foundation's documented formatting guarantee.
    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
