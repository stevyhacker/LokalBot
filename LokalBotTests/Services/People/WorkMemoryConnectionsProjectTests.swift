import XCTest
@testable import LokalBot

/// Projects read whole summaries and transcripts from the library folders.
/// 2026-10-16: summaries were cut to 4,000 characters and transcripts were
/// never read, so meetings that named a project late or only aloud dropped out.
final class WorkMemoryConnectionsProjectTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkMemoryConnectionsProjectTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func meeting(_ title: String, daysAgo: Double, files: [String: String]) throws -> Meeting {
        let folder = "meetings/\(UUID().uuidString)"
        let url = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let start = Date().addingTimeInterval(-daysAgo * 86_400)
        return Meeting(id: UUID(), title: title, appName: "Meet", startedAt: start,
                       endedAt: start.addingTimeInterval(1_800), relativePath: folder)
    }

    func testLongSummariesAndTranscriptsLinkTrackedProjects() throws {
        let filler = String(repeating: "- The synthetic vault accounting moved ahead with more checks.\n", count: 90)
        let long = try meeting("Demo Day", daysAgo: 3, files: [
            "summary.md": "# Demo Day\n## Key Points\n" + filler + "- Drafting the Larkspur rollout plan.\n",
        ])
        let spoken = try meeting("Product Standup", daysAgo: 2, files: [
            "transcript.md": "**[00:05:13] Them 3:** We finished the synthetic Larkspur checklist.\n",
        ])
        let unrelated = try meeting("Hiring loop", daysAgo: 1, files: ["summary.md": "## Key Points\n- Hiring plan."])
        var curation = ProjectCuration()
        curation.tracked = [.init(id: UUID(), name: "Larkspur", otherNames: [], createdAt: Date())]

        let projects = WorkMemoryConnections.projects(for: .init(
            meetings: [long, spoken, unrelated], projections: [], memory: nil, curation: curation,
            root: root, activityDatabaseURL: root.appendingPathComponent("missing.sqlite")))

        let larkspur = try XCTUnwrap(projects.first { $0.isTracked })
        XCTAssertEqual(larkspur.meetings.map(\.id), [spoken.id, long.id])
        XCTAssertEqual(larkspur.meetings.first?.mention?.seek, 313)
        XCTAssertEqual(larkspur.meetings.last?.mention?.text, "Drafting the Larkspur rollout plan.")
    }
}
