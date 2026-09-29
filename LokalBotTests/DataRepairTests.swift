import AVFoundation
import XCTest
@testable import LokalBot

final class DataRepairTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("data-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func writeAudio(in folder: URL, seconds: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let count = AVAudioFrameCount(seconds * 8_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        let file = try AVAudioFile(
            forWriting: MeetingAudioFiles.recoveryURL(for: .mic, in: folder), settings: format.settings)
        try file.write(from: buffer)
    }

    private func meeting(seconds: TimeInterval) -> Meeting {
        var meeting = Meeting(
            id: UUID(), title: "Standup", appName: "Meet",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            relativePath: "meetings/standup")
        meeting.recordedDuration = seconds
        return meeting
    }

    private func writeTranscript(_ spans: [(TimeInterval, TimeInterval)], in folder: URL) throws {
        let transcript = Transcript(
            segments: spans.map { .init(start: $0.0, end: $0.1, speaker: "them", text: "words") },
            engine: "test")
        try JSONEncoder().encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
    }

    private func writeManifest(durations: [TimeInterval], in folder: URL) throws {
        let sources = durations.map { ["id": UUID().uuidString, "duration": $0] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["sources": sources, "version": 2])
            .write(to: folder.appendingPathComponent("merge-manifest.json"))
    }

    // MARK: - Missing transcripts

    func testFinishedRecordingWithoutTranscriptNeedsTranscription() throws {
        let folder = try temporaryFolder()
        try writeAudio(in: folder, seconds: 6)
        XCTAssertEqual(MissingTranscription.reason(for: meeting(seconds: 60), folder: folder), .neverTranscribed)

        var recording = meeting(seconds: 60)
        recording.endedAt = nil
        XCTAssertNil(MissingTranscription.reason(for: recording, folder: folder), "Active recordings wait")
        XCTAssertNil(MissingTranscription.reason(for: meeting(seconds: 3), folder: folder),
                     "Near-empty recordings are not worth a model run")
        var source = meeting(seconds: 60)
        source.mergedIntoMeetingID = UUID()
        XCTAssertNil(MissingTranscription.reason(for: source, folder: folder), "Merged sources are covered by the merge")
        XCTAssertNil(MissingTranscription.reason(for: meeting(seconds: 60), folder: try temporaryFolder()),
                     "No readable audio, nothing to transcribe")
    }

    func testMergedTranscriptThatSkipsASourceIsRepairedOnce() throws {
        let folder = try temporaryFolder()
        try writeAudio(in: folder, seconds: 6)
        try writeManifest(durations: [40, 20, 0.3], in: folder)
        try writeTranscript([(41, 45), (50, 58)], in: folder)
        XCTAssertEqual(MissingTranscription.reason(for: meeting(seconds: 60), folder: folder), .mergedGap)

        try MissingTranscription.markGapRepairRequested(in: folder)
        XCTAssertNil(MissingTranscription.reason(for: meeting(seconds: 60), folder: folder),
                     "A span that stays empty after one repair is not retried every launch")
    }

    func testMergedTranscriptCoveringEverySourceNeedsNothing() throws {
        let folder = try temporaryFolder()
        try writeAudio(in: folder, seconds: 6)
        try writeManifest(durations: [40, 20], in: folder)
        try writeTranscript([(5, 9), (45, 50)], in: folder)
        XCTAssertNil(MissingTranscription.reason(for: meeting(seconds: 60), folder: folder))
    }

    // MARK: - Search tombstones

    func testStaleTombstonesAreClearedOnlyForLiveMeetings() throws {
        let root = try temporaryFolder()
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        let index = SearchIndex(databaseURL: databaseURL)
        let live = UUID(), deleted = UUID()
        XCTAssertTrue(index.remove(live))
        XCTAssertTrue(index.remove(deleted))

        let cleared = SearchIndex.clearStaleTombstones(liveMeetingIDs: [live], databaseURL: databaseURL)
        XCTAssertEqual(cleared, [live])
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertFalse(database.hasRow("SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1", bind: [live.uuidString]))
        XCTAssertTrue(database.hasRow("SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1", bind: [deleted.uuidString]))
        XCTAssertEqual(SearchIndex.clearStaleTombstones(liveMeetingIDs: [live], databaseURL: databaseURL), [])
    }

    @MainActor
    func testClearingVectorsForABoundaryReviewDoesNotTombstoneTheMeeting() throws {
        let root = try temporaryFolder()
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        _ = SearchIndex(databaseURL: databaseURL)
        let index = EmbeddingIndex(databaseURL: databaseURL, storage: StorageManager(rootURL: root))
        let meetingID = UUID()
        XCTAssertTrue(index.clearVectors(for: meetingID))
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertFalse(database.hasRow("SELECT 1 FROM deleted_meetings WHERE meeting_id = ?1",
                                       bind: [meetingID.uuidString]))
    }

    // MARK: - One app per library

    func testLibraryLockAdmitsOneHolderAtATime() throws {
        let root = try temporaryFolder()
        var first = LibraryInstanceLock.acquire(root: root, timeout: 0)
        XCTAssertNotNil(first)
        XCTAssertNil(LibraryInstanceLock.acquire(root: root, timeout: 0))
        first = nil
        XCTAssertNotNil(LibraryInstanceLock.acquire(root: root, timeout: 0), "Released when the holder goes away")
        XCTAssertNotNil(LibraryInstanceLock.acquire(root: try temporaryFolder(), timeout: 0),
                        "Different libraries do not contend")
        _ = first
    }

    func testCopiesRunFromBuildProductsAreRecognized() {
        XCTAssertTrue(UITestRuntime.isBuildProductsPath(
            "/Users/me/Library/Developer/Xcode/DerivedData/LokalBot-abc/Build/Products/Debug/LokalBot.app/Contents/MacOS/LokalBot"))
        XCTAssertTrue(UITestRuntime.isBuildProductsPath(
            "/tmp/wt/.build/dd/Build/Products/Debug/LokalBot.app/Contents/MacOS/LokalBot"))
        XCTAssertFalse(UITestRuntime.isBuildProductsPath("/Applications/LokalBot.app/Contents/MacOS/LokalBot"))
    }
}
