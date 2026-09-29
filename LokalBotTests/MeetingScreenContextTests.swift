import XCTest
@testable import LokalBot

final class MeetingScreenContextTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func shot(_ id: Int64, at seconds: TimeInterval, app: String, title: String,
                      url: String = "", document: String = "", meetingID: String = "") -> ActivityStore.Screenshot {
        ActivityStore.Screenshot(
            id: id, ts: start.addingTimeInterval(seconds), path: "", app: app,
            windowTitle: title, sourceURL: url, documentName: document, meetingID: meetingID)
    }

    private var meeting: Meeting {
        var meeting = Meeting(id: UUID(), title: "Pricing review", appName: "zoom.us",
                              startedAt: start, endedAt: start.addingTimeInterval(1_800),
                              relativePath: "meetings/pricing")
        meeting.recordedDuration = 1_800
        return meeting
    }

    func testBuildsMaterialsInFirstAppearanceOrderWithoutTheCallItself() {
        let context = MeetingScreenContext.build(meeting: meeting, screenshots: [
            shot(1, at: 5, app: "zoom.us", title: "Zoom Meeting"),
            shot(2, at: 60, app: "Keynote", title: "Q3 pricing.key", document: "Q3 pricing.key"),
            shot(3, at: 90, app: "Keynote", title: "Q3 pricing.key", document: "Q3 pricing.key"),
            shot(4, at: 300, app: "Google Chrome", title: "Pricing sheet - Google Sheets - Google Chrome",
                 url: "https://docs.google.com/spreadsheets/d/abc"),
            shot(5, at: 400, app: "Google Chrome", title: "Meet - Pricing review",
                 url: "https://meet.google.com/abc-defg-hij"),
            shot(6, at: 600, app: "Keynote", title: "Q3 pricing.key", document: "Q3 pricing.key"),
            shot(7, at: 5_000, app: "Notes", title: "After the call"),
        ])

        XCTAssertEqual(context.moments.map(\.snapshotID), [2, 4, 6])
        XCTAssertEqual(context.materials.map(\.title), ["Q3 pricing.key", "Pricing sheet - Google Sheets"])
        XCTAssertEqual(context.materials.first?.captureCount, 2)
        XCTAssertEqual(context.materials.last?.host, "docs.google.com")
        XCTAssertEqual(context.materials.first?.firstOffset, 60)
        XCTAssertEqual(context.materialTitles.first, "Q3 pricing.key (Keynote)")
    }

    func testMomentAtPlayheadUsesTheLatestPrecedingCapture() {
        let context = MeetingScreenContext.build(meeting: meeting, screenshots: [
            shot(1, at: 60, app: "Keynote", title: "Deck"),
            shot(2, at: 300, app: "Safari", title: "Docs"),
        ])
        XCTAssertNil(context.moment(at: 10))
        XCTAssertEqual(context.moment(at: 60)?.snapshotID, 1)
        XCTAssertEqual(context.moment(at: 299)?.snapshotID, 1)
        XCTAssertEqual(context.moment(at: 1_000)?.snapshotID, 2)
        XCTAssertTrue(MeetingScreenContext.build(meeting: meeting, screenshots: []).isEmpty)
    }

    func testStoreReturnsStampedAndLegacyCapturesInsideTheMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screen-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ActivityStore(databaseURL: root.appendingPathComponent("activity.sqlite"))
        let meeting = meeting
        let other = UUID()
        try store.insertScreenshot(ts: start.addingTimeInterval(30), path: "", app: "Keynote",
                                   windowTitle: "Stamped", ocr: "", meetingID: meeting.id.uuidString)
        try store.insertScreenshot(ts: start.addingTimeInterval(60), path: "", app: "Safari",
                                   windowTitle: "Legacy", ocr: "")
        try store.insertScreenshot(ts: start.addingTimeInterval(90), path: "", app: "Mail",
                                   windowTitle: "Other meeting", ocr: "", meetingID: other.uuidString)
        try store.insertScreenshot(ts: start.addingTimeInterval(3_600), path: "", app: "Notes",
                                   windowTitle: "Later", ocr: "", meetingID: meeting.id.uuidString)

        let shots = store.screenshots(forMeeting: meeting.id, from: start, to: start.addingTimeInterval(1_800))
        XCTAssertEqual(shots.map(\.windowTitle), ["Stamped", "Legacy"])
    }
}
