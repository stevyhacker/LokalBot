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

        XCTAssertEqual(context.moments.map(\.snapshotID), [1, 2, 4, 5, 6])
        XCTAssertEqual(context.moments.filter(\.isCall).map(\.snapshotID), [1, 5])
        XCTAssertEqual(context.materials.map(\.title), ["Q3 pricing.key", "Pricing sheet"])
        XCTAssertEqual(context.materials.first?.secondsOnScreen, 240 + 1_200,
                       "each stretch lasts until the next one, the call included")
        XCTAssertEqual(context.materials.last?.site, "Google Sheets")
        XCTAssertEqual(context.materials.last?.pageURL?.absoluteString, "https://docs.google.com/spreadsheets/d/abc")
        XCTAssertNil(context.materials.first?.pageURL)
        XCTAssertEqual(context.materials.last?.secondsOnScreen, 100)
        XCTAssertEqual(context.materials.first?.firstOffset, 60)
        XCTAssertEqual(context.materialTitles, ["Q3 pricing.key (Keynote)", "Pricing sheet (Google Sheets)"])
    }

    /// Shaped like a real Google Meet call whose Chrome captures carried no
    /// URL: the list showed URL fragments ("#inbox", a Gmail message id, the
    /// Meet code) and the call's own tab, five times.
    func testBrowserCapturesWithoutURLsReadAsPagesAndHideTheCallTab() {
        var meeting = meeting
        meeting.appName = "Google Chrome"
        meeting.endedAt = start.addingTimeInterval(3_000)
        meeting.recordedDuration = 3_000
        // A stale link from an earlier call must not matter.
        meeting.meetingURL = URL(string: "https://meet.google.com/old-call-xyz")
        let suffix = " - Google Chrome - Alex"
        let context = MeetingScreenContext.build(meeting: meeting, screenshots: [
            shot(1, at: 6, app: "ChatGPT", title: "ChatGPT", url: "app://-/index.html"),
            shot(2, at: 66, app: "Google Chrome",
                 title: "Size chat requests per model · Pull Request #193 · acme/app" + suffix, document: "changes"),
            shot(3, at: 157, app: "Google Chrome",
                 title: "Meet - Weekly sync - Camera and microphone recording - High memory usage - 906 MB" + suffix,
                 document: "abc-defg-hij?authuser=1&pageId=none"),
            shot(4, at: 217, app: "Google Chrome",
                 title: "Conference week plans - you@example.com - Gmail - Pinned - High memory usage - 1.0 GB" + suffix,
                 document: "FMfcgzQhWnnWSnWBBxHCnVCsZTFQcXvg"),
            shot(5, at: 280, app: "Google Chrome", title: "Meet - Weekly sync" + suffix,
                 document: "abc-defg-hij?authuser=1&pageId=none"),
            shot(6, at: 720, app: "Google Chrome", title: "Inbox (6) - you@example.com - Gmail - Pinned" + suffix,
                 document: "#inbox"),
            shot(7, at: 780, app: "Google Chrome", title: "New Tab" + suffix, document: "newtab"),
            shot(8, at: 800, app: "Google Chrome", title: "Inbox (7) - you@example.com - Gmail - Pinned" + suffix,
                 document: "#inbox"),
            shot(9, at: 900, app: "Google Chrome",
                 title: "Meet - Weekly sync - Microphone recording" + suffix, document: "abc-defg-hij"),
            shot(10, at: 2_640, app: "Google Chrome",
                 title: "Size chat requests per model · Pull Request #193 · acme/app" + suffix,
                 document: "changes#diff-b1205fdf140b3884f2f5d7ecf"),
        ])

        XCTAssertEqual(context.materials.map(\.title), [
            "ChatGPT",
            "Size chat requests per model · Pull Request #193 · acme/app",
            "Conference week plans",
            "Inbox",
        ])
        XCTAssertEqual(context.materials.map(\.site), [nil, nil, "Gmail", "Gmail"],
                       "an app:// address has no site to show")
        XCTAssertEqual(context.materials[1].secondsOnScreen, 91 + 360, "the pull request counts both visits")
        XCTAssertEqual(context.materials[3].secondsOnScreen, 60 + 100)
        XCTAssertEqual(context.moments.filter(\.isCall).map(\.snapshotID), [3, 5, 9])
        XCTAssertEqual(context.moment(at: 600)?.isCall, true)
        XCTAssertEqual(context.moment(at: 230)?.title, "Conference week plans")
        XCTAssertEqual(MeetingScreenMaterialsSection.detail(context.materials[0]), "1 min on screen")
        XCTAssertEqual(MeetingScreenMaterialsSection.detail(context.materials[2]), "Gmail · 1 min on screen")
        XCTAssertEqual(MeetingScreenMaterialsSection.detail(context.materials[3]), "Gmail · 3 min on screen")
    }

    func testCallTabMatchesTheMeetingsOwnLinkWithoutAStatusMarker() {
        var meeting = meeting
        meeting.appName = "Google Chrome"
        meeting.meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")
        let context = MeetingScreenContext.build(meeting: meeting, screenshots: [
            shot(1, at: 10, app: "Google Chrome", title: "Weekly sync - Google Chrome", document: "abc-defg-hij?authuser=1"),
            shot(2, at: 60, app: "Google Chrome", title: "Roadmap - Google Docs - Google Chrome", document: "edit"),
        ])
        XCTAssertEqual(context.materials.map(\.title), ["Roadmap"])
    }

    func testLongCallsKeepTheWindowsInFrontLongestInFirstAppearanceOrder() {
        // Every third window stays in front for five minutes; the rest are glances.
        var shots: [ActivityStore.Screenshot] = []
        var at: TimeInterval = 0
        for index in 0..<15 {
            shots.append(shot(Int64(index + 1), at: at, app: "Preview", title: "Doc \(index)"))
            at += index % 3 == 0 ? 300 : 20
        }
        let context = MeetingScreenContext.build(meeting: meeting, screenshots: shots)
        XCTAssertEqual(context.materials.count, MeetingScreenContext.maximumMaterials)
        XCTAssertEqual(context.materials.map(\.firstOffset), context.materials.map(\.firstOffset).sorted())
        for long in [0, 3, 6, 9, 12] {
            XCTAssertTrue(context.materials.contains { $0.title == "Doc \(long)" }, "Doc \(long) was dropped")
        }
    }

    func testOnlyAddressesThatIdentifyThePageCanBeReopened() {
        XCTAssertNotNil(MeetingScreenContext.reopenableURL("https://github.com/acme/app/pull/193/changes"))
        XCTAssertNotNil(MeetingScreenContext.reopenableURL("https://www.notion.so/acme/Roadmap-4f2a"))
        // Captures keep no query or fragment, so these would open the wrong page.
        XCTAssertNil(MeetingScreenContext.reopenableURL("https://mail.google.com/mail/u/0/"))
        XCTAssertNil(MeetingScreenContext.reopenableURL("https://www.youtube.com/watch"))
        XCTAssertNil(MeetingScreenContext.reopenableURL("https://github.com/search"))
        XCTAssertNil(MeetingScreenContext.reopenableURL("https://example.com/"))
        XCTAssertNil(MeetingScreenContext.reopenableURL("app://-/index.html"))
        XCTAssertNil(MeetingScreenContext.reopenableURL(""))
    }

    func testBrowserTitlesSplitTheSiteAndDropAccountsAndCounts() {
        func page(_ title: String) -> MeetingScreenContext.Page { MeetingScreenContext.splittingSite(from: title) }
        XCTAssertEqual(page("bittensor - Google Search"), .init(title: "bittensor", site: "Google Search"))
        XCTAssertEqual(page("Cloud Run – Localhost – Google Cloud console"),
                       .init(title: "Cloud Run – Localhost", site: "Google Cloud console"))
        XCTAssertEqual(page("Demo Day - 25 Sept - you@example.com - Team Mail"),
                       .init(title: "Demo Day - 25 Sept", site: "Team Mail"))
        XCTAssertEqual(page("(1) Home / X"), .init(title: "Home / X", site: nil))
        XCTAssertEqual(page("LokalBot — Find what you said or saw on your Mac"),
                       .init(title: "LokalBot — Find what you said or saw on your Mac", site: nil),
                       "a long trailing phrase is part of the title, not a site")
        XCTAssertEqual(page("Gmail"), .init(title: "Gmail", site: nil))
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
