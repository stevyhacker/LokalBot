import SQLite3
import XCTest
@testable import LokalBot

final class DiagnosticsExporterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSanitizerRemovesSecretsAndURLCredentials() throws {
        let input = Data("""
            {"openAIBaseURL":"https://user:pw@example.com/v1?key=abc","remoteToken":"t0k",
             "nested":{"apiKey":"k","retentionDays":14},"urls":["https://a.example/x?q=1"]}
            """.utf8)
        let output = try XCTUnwrap(String(data: DiagnosticsSettingsSanitizer.sanitize(input), encoding: .utf8))
        XCTAssertFalse(output.contains("pw"))
        XCTAssertFalse(output.contains("abc"))
        XCTAssertFalse(output.contains("t0k"))
        XCTAssertFalse(output.contains("\"k\""))
        XCTAssertFalse(output.contains("q=1"))
        XCTAssertTrue(output.contains("https:\\/\\/example.com\\/v1") || output.contains("https://example.com/v1"))
        XCTAssertTrue(output.contains("\"retentionDays\" : 14"))
    }

    func testExportContainsDiagnosticsButNeverMeetingContent() throws {
        let log = root.appendingPathComponent("debug.log")
        try Data("log line\n".utf8).write(to: log)
        let health = DiagnosticsPaths.healthReports(root: root)
        try FileManager.default.createDirectory(at: health, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: health.appendingPathComponent("2026-09-29.json"))
        let meeting = root.appendingPathComponent("meetings/2026/09/29-standup", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try Data("secret transcript".utf8).write(to: meeting.appendingPathComponent("transcript.json"))
        try makeDatabase(at: DiagnosticsPaths.database(root: root))

        let destination = root.appendingPathComponent("out.zip")
        let manifest = try DiagnosticsExporter.export(sources(logs: [log]), to: destination)

        XCTAssertEqual(manifest.missing, ["capture traces"])
        let files = try unzippedFiles(destination)
        XCTAssertTrue(files.contains { $0.hasSuffix("logs/debug.log") })
        XCTAssertTrue(files.contains { $0.hasSuffix("health/2026-09-29.json") })
        XCTAssertTrue(files.contains { $0.hasSuffix("settings.json") })
        XCTAssertTrue(files.contains { $0.hasSuffix("counts.json") })
        XCTAssertFalse(files.contains { $0.contains("meetings") || $0.contains("transcript") })
    }

    func testExportSucceedsWithMissingPartsAndRecordsThem() throws {
        let destination = root.appendingPathComponent("out.zip")
        var sources = sources(logs: [root.appendingPathComponent("missing.log")])
        sources.databaseURL = root.appendingPathComponent("absent.sqlite")
        sources.settingsJSON = nil
        let manifest = try DiagnosticsExporter.export(sources, to: destination)
        XCTAssertEqual(Set(manifest.missing),
                       ["logs", "health reports", "capture traces", "settings", "library counts"])
        XCTAssertTrue(try unzippedFiles(destination).contains { $0.hasSuffix("manifest.json") })
    }

    /// `--export-diagnostics ~/Desktop` must never delete the Desktop.
    func testExportRefusesAnExistingFolderAndLeavesItIntact() throws {
        let folder = root.appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keep = folder.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: keep)
        XCTAssertThrowsError(try DiagnosticsExporter.export(sources(logs: []), to: folder))
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "mine")
    }

    /// Replacing an earlier archive happens only once the new one exists.
    func testExportReplacesAnEarlierArchiveFile() throws {
        let destination = root.appendingPathComponent("out.zip")
        try Data("old".utf8).write(to: destination)
        _ = try DiagnosticsExporter.export(sources(logs: []), to: destination)
        XCTAssertTrue(try unzippedFiles(destination).contains { $0.hasSuffix("manifest.json") })
    }

    private func sources(logs: [URL]) -> DiagnosticsExporter.Sources {
        DiagnosticsExporter.Sources(
            logURLs: logs,
            healthReportsDirectory: DiagnosticsPaths.healthReports(root: root),
            captureTracesDirectory: DiagnosticsPaths.captureTraces(root: root),
            databaseURL: DiagnosticsPaths.database(root: root),
            settingsJSON: Data(#"{"retentionDays":14}"#.utf8))
    }

    private func makeDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        sqlite3_exec(handle, """
            CREATE TABLE activity_blocks (id INTEGER PRIMARY KEY, app TEXT, title TEXT, start REAL, end REAL);
            CREATE TABLE screenshots (id INTEGER PRIMARY KEY, ts REAL, path TEXT, app TEXT);
            INSERT INTO activity_blocks (app, title, start, end) VALUES ('Xcode', 't', 0, 60);
            """, nil, nil, nil)
    }

    private func unzippedFiles(_ archive: URL) throws -> [String] {
        let out = root.appendingPathComponent("unzipped-\(UUID().uuidString)", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, out.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let enumerator = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).map(\.path)
    }
}
