import XCTest
@testable import LokalBot

/// The bundled sample meeting (`SampleMeeting`): it imports like a recording,
/// is marked, and stays out of the day and the action lists.
final class SampleMeetingTests: XCTestCase {
    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRecordingFollowsTheInterfaceLanguageThenEnglish() {
        XCTAssertEqual(SampleMeeting.recording(for: "en"), SampleMeeting.english)
        XCTAssertEqual(SampleMeeting.recording(for: "de").id, "orders-api/de")
        XCTAssertEqual(SampleMeeting.recording(for: "de-CH").id, "orders-api/de")
        XCTAssertEqual(SampleMeeting.recording(for: "zh-Hans").id, "orders-api/zh")
        // Traditional Chinese gets the Mandarin recording too, titled in Simplified Chinese.
        XCTAssertEqual(SampleMeeting.recording(for: "zh-Hant").id, "orders-api/zh")
        XCTAssertEqual(SampleMeeting.recording(for: "sr-Latn").id, "orders-api/sr-Latn")
        XCTAssertEqual(SampleMeeting.recording(for: "fr"), SampleMeeting.english)
        XCTAssertEqual(SampleMeeting.recording(for: "ja"), SampleMeeting.english)
    }

    func testEveryRecordingIsBundledAndImportsWithItsTitle() async throws {
        for recording in SampleMeeting.recordings {
            let storage = StorageManager(rootURL: try temporaryDirectory("SampleLibrary"))
            let url = try XCTUnwrap(SampleMeeting.audioURL(for: recording), "\(recording.fileName) is bundled")
            let meeting = try await MeetingImportService.importRecording(from: url, storage: storage, sample: recording)
            XCTAssertEqual(meeting.title, recording.title)
            XCTAssertEqual(meeting.sampleID, recording.id)
            let duration = try XCTUnwrap(meeting.recordedDuration)
            XCTAssertTrue((180...300).contains(duration), "\(recording.id) runs \(duration) s")
        }
    }

    func testBundledSampleImportsAsTheMarkedSampleDatedNow() async throws {
        let storage = StorageManager(rootURL: try temporaryDirectory("SampleLibrary"))
        let url = try XCTUnwrap(SampleMeeting.audioURL(for: SampleMeeting.english), "the app bundles the sample recording")
        let now = Date()

        let meeting = try await MeetingImportService.importRecording(
            from: url, storage: storage, now: now, sample: SampleMeeting.english)

        XCTAssertEqual(meeting.title, "Sample: Orders API delivery window")
        XCTAssertEqual(meeting.sampleID, "orders-api/en")
        XCTAssertTrue(meeting.isSample)
        XCTAssertFalse(meeting.isOwnWork)
        XCTAssertTrue(meeting.isImported)
        let duration = try XCTUnwrap(meeting.recordedDuration)
        XCTAssertGreaterThan(duration, 200)
        XCTAssertLessThan(duration, 240)
        XCTAssertEqual(try XCTUnwrap(meeting.endedAt).timeIntervalSince(now), 0, accuracy: 1)
        let meta = try JSONSerialization.jsonObject(with: Data(
            contentsOf: meeting.folderURL(in: storage).appendingPathComponent("meta.json"))) as? [String: Any]
        XCTAssertEqual(meta?["sampleID"] as? String, "orders-api/en")
    }

    func testDayEvidenceAndActionListsLeaveTheSampleOut() throws {
        let root = try temporaryDirectory("SampleEvidence")
        let storage = StorageManager(rootURL: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_784_376_000) // 2026-07-18 12:00 UTC
        var own = Meeting(id: UUID(), title: "Design review", appName: "Zoom",
                          startedAt: now.addingTimeInterval(-3_600), endedAt: now.addingTimeInterval(-1_800),
                          relativePath: try storage.reserveMeetingFolder(
                              title: "Design review", startedAt: now.addingTimeInterval(-3_600)))
        own.hasSystemTrack = true
        var sample = Meeting(id: UUID(), title: SampleMeeting.english.title, appName: MeetingImportService.appName,
                             startedAt: now.addingTimeInterval(-600), endedAt: now.addingTimeInterval(-390),
                             relativePath: try storage.reserveMeetingFolder(
                                 title: SampleMeeting.english.title, startedAt: now.addingTimeInterval(-600)))
        sample.sampleID = SampleMeeting.english.id
        for meeting in [own, sample] {
            try storage.saveMeta(meeting)
            try MeetingOutcomes(
                actionItems: [.init(text: "Update the API spec for \(meeting.title)", owner: "Me")],
                decisions: []).write(to: meeting.folderURL(in: storage))
        }

        let snapshot = try FileDailyEvidenceSource(root: root, calendar: calendar).snapshot(
            for: now, meetings: [own, sample], includeDetailedActivity: false)
        XCTAssertEqual(snapshot.meetings.map(\.meeting.id), [own.id])

        let entries = ActionItemsReport.entries(
            meetings: [own, sample], root: root, filter: ActionItemsReport.Filter(), now: now, calendar: calendar)
        XCTAssertEqual(entries.flatMap(\.meetings).map(\.title), [own.title])
        // Asked for by id, the sample's own actions are still there.
        var bySample = ActionItemsReport.Filter()
        bySample.meetingID = sample.id
        XCTAssertEqual(ActionItemsReport.entries(
            meetings: [own, sample], root: root, filter: bySample, now: now, calendar: calendar).count, 1)
    }
}
