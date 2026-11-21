import Foundation
import Logging

final class FileLogSink: @unchecked Sendable {
    private let fileURL: URL
    let sizeCapBytes: UInt64
    let maxRotations: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var byteOffset: UInt64 = 0

    init(fileURL: URL, sizeCapBytes: UInt64 = 8 * 1024 * 1024, maxRotations: Int = 5) {
        self.fileURL = fileURL
        self.sizeCapBytes = sizeCapBytes
        self.maxRotations = max(1, maxRotations)
        openHandleLocked()
    }

    static func rotatedURLs(for fileURL: URL, maxRotations: Int) -> [URL] {
        (1...max(1, maxRotations)).map { fileURL.appendingPathExtension(String($0)) }
    }

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
        }
    }

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

        var displaced = true
        if fileManager.fileExists(atPath: fileURL.path) {
            displaced = (try? fileManager.moveItem(at: fileURL, to: backupURL)) != nil
        }
        if displaced {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        openHandleLocked()
    }

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

    private static func shortCategory(from label: String) -> String {
        label.split(separator: ".").last.map(String.init) ?? label
    }

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

    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
