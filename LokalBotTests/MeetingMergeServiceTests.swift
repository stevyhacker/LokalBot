import XCTest
@testable import LokalBot

final class MeetingMergeServiceTests: XCTestCase {
    func testMergeCreatesScopedTranscriptAndKeepsSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeService-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstDate = Date(timeIntervalSince1970: 1_752_000_000)
        try MeetingFixture.write([
            .init(title: "Design review", startedAt: firstDate,
                  summary: "## Decisions\n\nKeep the new flow.",
                  transcriptLines: ["I will update the flow.", "The team agrees."]),
            .init(title: "Launch check", startedAt: firstDate.addingTimeInterval(3_600),
                  summary: "## Actions\n\nShip the checklist.",
                  transcriptLines: ["I will ship the checklist.", "Please review it."])
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }

        let result = try await MeetingMergeService.merge(
            meetings: sources,
            title: "Release working session",
            storage: storage)

        XCTAssertTrue(result.meeting.isMergedMeeting)
        XCTAssertEqual(result.meeting.mergedSourceMeetingIDs, sources.map(\.id))
        XCTAssertTrue(result.sourceMeetings.allSatisfy(\.isMergedSource))
        XCTAssertEqual(result.transcriptSegmentCount, 4)
        XCTAssertEqual(result.meeting.recordedDuration ?? 0, 3_600, accuracy: 0.01)

        let folder = result.meeting.folderURL(in: storage)
        let transcript = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertGreaterThanOrEqual(transcript.segments[2].start, 1_800)
        XCTAssertTrue(transcript.speakerAliases.keys.contains("source1:me"))
        XCTAssertTrue(transcript.speakerAliases.values.contains { $0.contains("source 2") })

        let summary = try String(contentsOf: folder.appendingPathComponent("summary.md"), encoding: .utf8)
        XCTAssertTrue(summary.contains("Design review"))
        XCTAssertTrue(summary.contains("Launch check"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("merge-manifest.json").path))

        let visibleMeetings = storage.loadMeetings()
        XCTAssertEqual(visibleMeetings.map(\.id), [result.meeting.id])
        let allMeetings = storage.loadMeetings(includeMergedSources: true)
        XCTAssertEqual(allMeetings.count, 3)
        for source in sources {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.folderURL(in: storage).path))
            let persisted = try XCTUnwrap(allMeetings.first { $0.id == source.id })
            XCTAssertEqual(persisted.mergedIntoMeetingID, result.meeting.id)
            XCTAssertNil(persisted.mergedSourceMeetingIDs)
        }
    }

    func testLoadMeetingsRepairsOrphanedMergeSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeOrphan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let start = Date(timeIntervalSince1970: 1_752_050_000)
        try MeetingFixture.write([
            .init(title: "First part", startedAt: start,
                  transcriptLines: ["First source."]),
            .init(title: "Second part", startedAt: start.addingTimeInterval(300),
                  transcriptLines: ["Second source."])
        ], under: root)
        let storage = StorageManager(rootURL: root)
        let sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }
        let result = try await MeetingMergeService.merge(
            meetings: sources,
            title: "Temporary merged meeting",
            storage: storage)

        try storage.deleteMeeting(result.meeting)

        let repaired = storage.loadMeetings()
        XCTAssertEqual(Set(repaired.map(\.id)), Set(sources.map(\.id)))
        XCTAssertTrue(repaired.allSatisfy { $0.mergedIntoMeetingID == nil })
    }

    func testMergeHonorsSourceContentRanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeRange-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstID = UUID()
        let secondID = UUID()
        let start = Date(timeIntervalSince1970: 1_752_100_000)
        try MeetingFixture.write([
            .init(id: firstID, title: "Part one", startedAt: start,
                  transcriptLines: ["First opening.", "First close."]),
            .init(id: secondID, title: "Part two", startedAt: start.addingTimeInterval(100),
                  transcriptLines: ["Second opening.", "Second close."])
        ], under: root)
        let storage = StorageManager(rootURL: root)
        var sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }
        sources[0].contentRange = .init(start: 0, end: 20)
        try storage.saveMeta(sources[0])
        sources = storage.loadMeetings().sorted { $0.startedAt < $1.startedAt }

        let result = try await MeetingMergeService.merge(
            meetings: sources,
            title: "Bounded merge",
            storage: storage)
        XCTAssertEqual(result.meeting.recordedDuration ?? 0, 1_820, accuracy: 0.01)

        let transcript = try JSONDecoder().decode(
            Transcript.self,
            from: Data(contentsOf: result.meeting.folderURL(in: storage)
                .appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertGreaterThanOrEqual(transcript.segments[2].start, 20)
    }

    func testMergeRequiresTwoCompletedMeetings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingMergeValidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageManager(rootURL: root)
        let meeting = try storage.createMeetingFolder(title: "Only one", appName: "Tests")
        var finished = meeting
        finished.endedAt = finished.startedAt.addingTimeInterval(60)
        finished.recordedDuration = 60
        try storage.saveMeta(finished)

        do {
            _ = try await MeetingMergeService.merge(
                meetings: [finished], title: "Invalid", storage: storage)
            XCTFail("Expected a validation error")
        } catch let error as MeetingMergeService.MergeError {
            guard case .needsAtLeastTwo = error else {
                return XCTFail("Unexpected merge error: \(error)")
            }
        }
    }
}
