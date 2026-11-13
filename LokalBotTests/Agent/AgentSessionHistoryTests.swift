import XCTest
@testable import LokalBot

final class AgentSessionHistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    func testLoadsMetadataAndSortsByLatestConversationActivity() throws {
        let olderWorkspace = root.appendingPathComponent("Older Project", isDirectory: true)
        let newerWorkspace = root.appendingPathComponent("Newer Project", isDirectory: true)
        let older = root.appendingPathComponent("older.jsonl")
        let newer = root.appendingPathComponent("newer.jsonl")

        try write([
            session(id: "older", timestamp: "2026-07-10T09:55:17.265Z", cwd: olderWorkspace),
            message(
                role: "user",
                content: [["type": "text", "text": "Review the launch checklist"]],
                timestamp: 1_783_677_336_124),
            message(role: "assistant", content: "Ready.", timestamp: 1_783_677_337_124),
            ["type": "session_info", "name": "Launch review"],
        ], to: older)
        try write([
            session(id: "newer", timestamp: "2026-08-05T20:52:04.304Z", cwd: newerWorkspace),
            message(role: "user", content: "Summarize the latest plan", timestamp: 1_785_963_156_269),
        ], to: newer)

        let loaded = try AgentSessionHistory.load(from: root)

        XCTAssertEqual(loaded.map(\.sessionID), ["newer", "older"])
        XCTAssertEqual(loaded[0].title, "Summarize the latest plan")
        XCTAssertEqual(loaded[0].messageCount, 1)
        XCTAssertEqual(loaded[0].workspace.path, newerWorkspace.standardizedFileURL.path)
        XCTAssertEqual(loaded[0].createdAt.timeIntervalSince1970, 1_785_963_124.304, accuracy: 0.001)
        XCTAssertEqual(loaded[1].title, "Launch review")
        XCTAssertEqual(loaded[1].messageCount, 2)
        XCTAssertTrue(loaded[1].searchableText.contains("Older Project"))
    }

    func testIgnoresMalformedEmptyAndSymlinkedFiles() throws {
        let valid = root.appendingPathComponent("valid.jsonl")
        try write([
            session(id: "valid", timestamp: "2026-08-05T20:52:04Z", cwd: root),
            message(role: "user", content: "Keep me", timestamp: 1_785_963_156_269),
        ], to: valid)
        try Data("not json\n".utf8).write(to: root.appendingPathComponent("malformed.jsonl"))
        try write([
            session(id: "empty", timestamp: "2026-08-05T20:52:04Z", cwd: root),
        ], to: root.appendingPathComponent("empty.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.jsonl"),
            withDestinationURL: valid)

        let loaded = try AgentSessionHistory.load(from: root)

        XCTAssertEqual(loaded.map(\.sessionID), ["valid"])
    }

    func testValidationRejectsAReplacedSession() throws {
        let file = root.appendingPathComponent("saved.jsonl")
        try write([
            session(id: "original", timestamp: "2026-08-05T20:52:04Z", cwd: root),
            message(role: "user", content: "Original", timestamp: 1_785_963_156_269),
        ], to: file)
        let original = try XCTUnwrap(AgentSessionHistory.load(from: root).first)
        XCTAssertNotNil(AgentSessionHistory.validated(original, in: root))

        try write([
            session(id: "replacement", timestamp: "2026-08-05T20:52:04Z", cwd: root),
            message(role: "user", content: "Replacement", timestamp: 1_785_963_156_270),
        ], to: file)

        XCTAssertNil(AgentSessionHistory.validated(original, in: root))
    }

    private func session(id: String, timestamp: String, cwd: URL) -> [String: Any] {
        ["type": "session", "id": id, "timestamp": timestamp, "cwd": cwd.path]
    }

    private func message(role: String, content: Any, timestamp: Int64) -> [String: Any] {
        [
            "type": "message",
            "message": ["role": role, "content": content, "timestamp": timestamp],
        ]
    }

    private func write(_ records: [[String: Any]], to file: URL) throws {
        let lines = try records.map { record in
            String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }
}
