import Foundation
import SQLite3

enum DiagnosticsPaths {
    static func healthReports(root: URL) -> URL {
        root.appendingPathComponent("diagnostics/health", isDirectory: true)
    }

    static func captureTraces(root: URL) -> URL {
        root.appendingPathComponent("diagnostics/capture-traces", isDirectory: true)
    }

    static func database(root: URL) -> URL {
        root.appendingPathComponent("lokalbotv3.sqlite", isDirectory: false)
    }
}

/// Builds the Export Diagnostics archive: recent logs, health reports,
/// settings without secrets, library row counts, and capture traces (already
/// scrubbed when written). It never reads the meetings folder, screenshots, or
/// OCR text, so meeting audio, transcripts, notes, and screen content cannot
/// end up in the archive.
enum DiagnosticsExporter {
    struct Sources: Sendable {
        var logURLs: [URL]
        var healthReportsDirectory: URL
        var captureTracesDirectory: URL
        var databaseURL: URL
        var settingsJSON: Data?
    }

    struct Manifest: Codable, Equatable {
        var createdAt: Date
        var appVersion: String
        var build: String
        var missing: [String]
    }

    enum ExportError: LocalizedError {
        case archiveFailed(Int32)
        case destinationIsFolder(String)

        var errorDescription: String? {
            switch self {
            case .archiveFailed(let status): "Could not create the diagnostics archive (ditto exit \(status))."
            case .destinationIsFolder(let path): "\(path) is a folder. Choose a file name for the diagnostics archive."
            }
        }
    }

    static let maximumHealthReportDays = 14

    @discardableResult
    static func export(_ sources: Sources, to destination: URL, now: Date = Date()) throws -> Manifest {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        if fileManager.fileExists(atPath: destination.path, isDirectory: &isFolder), isFolder.boolValue {
            throw ExportError.destinationIsFolder(destination.path)
        }
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("lokalbot-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let staging = parent.appendingPathComponent("LokalBot Diagnostics", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: parent) }
        var missing: [String] = []

        let copiedLogs = try copy(sources.logURLs.filter { fileManager.fileExists(atPath: $0.path) },
                                  into: staging.appendingPathComponent("logs", isDirectory: true))
        if copiedLogs == 0 { missing.append("logs") }

        let reports = files(in: sources.healthReportsDirectory, extensions: ["json", "md"])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(maximumHealthReportDays * 2)
        if try copy(Array(reports), into: staging.appendingPathComponent("health", isDirectory: true)) == 0 {
            missing.append("health reports")
        }

        let traces = files(in: sources.captureTracesDirectory, extensions: ["json"])
        if try copy(traces, into: staging.appendingPathComponent("capture-traces", isDirectory: true)) == 0 {
            missing.append("capture traces")
        }

        if let settings = sources.settingsJSON,
           let sanitized = try? DiagnosticsSettingsSanitizer.sanitize(settings) {
            try sanitized.write(to: staging.appendingPathComponent("settings.json"), options: .atomic)
        } else {
            missing.append("settings")
        }

        if let counts = libraryCounts(databaseURL: sources.databaseURL) {
            let data = try JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: staging.appendingPathComponent("counts.json"), options: .atomic)
        } else {
            missing.append("library counts")
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let manifest = Manifest(
            createdAt: now,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            missing: missing)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        // Build the archive beside the staging folder, then swap it in: an
        // earlier archive is replaced only once the new one exists.
        let archive = parent.appendingPathComponent("diagnostics.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.path, archive.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.archiveFailed(process.terminationStatus) }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: archive)
        } else {
            try fileManager.moveItem(at: archive, to: destination)
        }
        return manifest
    }

    private static func files(in directory: URL, extensions: Set<String>) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { extensions.contains($0.pathExtension) }
    }

    private static func copy(_ urls: [URL], into directory: URL) throws -> Int {
        guard !urls.isEmpty else { return 0 }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in urls {
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(url.lastPathComponent))
        }
        return urls.count
    }

    /// Row counts only; never row contents.
    static func libraryCounts(databaseURL: URL) -> [String: Int]? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var counts: [String: Int] = [:]
        for table in ["activity_blocks", "screenshots", "pipeline_jobs", "indexed_meetings", "deleted_meetings"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                continue
            }
            if sqlite3_step(statement) == SQLITE_ROW {
                counts[table] = Int(sqlite3_column_int64(statement, 0))
            }
            sqlite3_finalize(statement)
        }
        return counts.isEmpty ? nil : counts
    }
}
