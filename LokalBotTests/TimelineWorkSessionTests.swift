import XCTest
@testable import LokalBot

final class TimelineWorkSessionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_760_000_000)

    private func block(
        _ id: Int64,
        app: String,
        title: String,
        start: TimeInterval,
        end: TimeInterval
    ) -> ActivityBlock {
        ActivityBlock(
            id: id,
            app: app,
            title: title,
            start: base.addingTimeInterval(start),
            end: base.addingTimeInterval(end))
    }

    func testShortGapsCollapseIntoOneWorkSession() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "CaptureView.swift", start: 0, end: 60),
            block(2, app: "Safari", title: "Pull request #42", start: 120, end: 180),
            block(3, app: "Slack", title: "#engineering", start: 600, end: 660),
        ])

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].blocks.map(\.id), [1, 2])
        XCTAssertEqual(sessions[0].activeDuration, 120)
        XCTAssertEqual(sessions[0].contextSwitchCount, 1)
        XCTAssertEqual(sessions[1].blocks.map(\.id), [3])
    }

    func testSystemOnlyActivityDoesNotBecomeAWorkSession() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "loginwindow", title: "Login Window", start: 0, end: 600),
            block(2, app: "WindowServer", title: "WindowServer", start: 600, end: 660),
            block(3, app: "Xcode", title: "TimelineWorkSession.swift", start: 900, end: 1_500),
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].blocks.map(\.id), [3])
        XCTAssertEqual(sessions[0].title, "TimelineWorkSession.swift")
    }

    func testOverlappingBlocksDoNotDoubleCountActiveTime() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "Timeline", start: 0, end: 600),
            block(2, app: "Safari", title: "Design reference", start: 300, end: 900),
        ])

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].activeDuration, 900)
        XCTAssertEqual(sessions[0].apps, ["Xcode", "Safari"])
    }

    func testPrimaryAppAndTitleUseGroundedDuration() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Safari", title: "New Tab", start: 0, end: 60),
            block(2, app: "Xcode", title: "CaptureView.swift", start: 60, end: 660),
            block(3, app: "Xcode", title: "Tests", start: 660, end: 780),
        ])

        XCTAssertEqual(sessions.first?.primaryApp, "Xcode")
        XCTAssertEqual(sessions.first?.title, "CaptureView.swift")
        XCTAssertEqual(sessions.first?.notableTitles, ["CaptureView.swift", "Tests"])
        XCTAssertEqual(sessions.first?.notableTitles.first, "CaptureView.swift")
    }

    func testSessionTitleStripsBrowserChromeSuffixes() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Google Chrome",
                  title: "Kaya beach Ulcinj bilježi odličnu posjećenost - YouTube - Audio playing - Google Chrome - Stevan",
                  start: 0, end: 600),
        ])

        XCTAssertEqual(sessions.first?.title,
                       "Kaya beach Ulcinj bilježi odličnu posjećenost - YouTube")
    }

    func testBriefTitleRemainsEvidenceWithoutNamingWholeSession() throws {
        let session = try XCTUnwrap(TimelineWorkSession.sessions(from: [
            block(1, app: "Terminal", title: "Terminal", start: 0, end: 2_400),
            block(2, app: "Safari", title: "Sign in", start: 2_400, end: 2_408),
        ]).first)
        // Eight seconds of Safari stay evidence without joining the title.
        XCTAssertEqual(session.title, "Terminal")
        XCTAssertTrue(session.titleNamesApps)
        XCTAssertEqual(session.activeDuration, 2_408)
        XCTAssertEqual(session.titleEvidence.map(\.title), ["Sign in"])
        XCTAssertEqual(session.titleEvidence.first?.duration, 8)
        XCTAssertEqual(session.titleEvidence.first?.blocks.map(\.id), [2])
    }

    func testTitleCoverageUsesActiveTimeAndIncludesTwentyPercentBoundary() throws {
        let session = try XCTUnwrap(TimelineWorkSession.sessions(from: [
            block(1, app: "Terminal", title: "Terminal", start: 0, end: 80),
            block(2, app: "Preview", title: "Plan.pdf", start: 380, end: 400),
        ]).first)
        XCTAssertEqual(session.title, "Plan.pdf")
        XCTAssertFalse(session.titleNamesApps)
        XCTAssertEqual(session.activeDuration, 100)
    }

    func testStrippingBrowserChromeHandlesFirefoxAndPlainTitles() {
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome("Docs — Mozilla Firefox"),
            "Docs")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome("Home / X - Google Chrome - Stevan"),
            "Home / X")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome(
                "Weekly sync - you@example.com - Gmail - Pinned - High memory usage - 1.0 GB - Google Chrome - Alex"),
            "Weekly sync - you@example.com - Gmail")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome(
                "Meet - Weekly sync - Camera and microphone recording - Google Chrome - Alex"),
            "Meet - Weekly sync")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome(
                "IAM & Admin – Google Cloud console - Part of group Work - Google Chrome - Alex"),
            "IAM & Admin – Google Cloud console")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome("Meeting notes - draft two"),
            "Meeting notes - draft two",
            "titles without marker segments pass through untouched")
        XCTAssertEqual(
            TimelineWorkSession.strippingBrowserChrome("Google Chrome"),
            "Google Chrome",
            "a bare browser name is left for the generic-title filter")
    }

    func testDayItemsInterleaveSessionsAndMeetings() {
        let session = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "CaptureView.swift", start: 0, end: 600),
        ]).first!
        let meeting = Meeting(
            id: UUID(),
            title: "Design review",
            appName: "Zoom",
            startedAt: base.addingTimeInterval(900),
            endedAt: base.addingTimeInterval(1_500),
            relativePath: "meetings/design-review")

        let items = TimelineDayItem.items(
            sessions: [session], meetings: [meeting], now: base.addingTimeInterval(2_000))

        XCTAssertEqual(items.count, 2)
        if case .work = items[0] {} else { XCTFail("work session should be first") }
        if case .meeting = items[1] {} else { XCTFail("meeting should be second") }
    }

    func testSustainedNewDocumentStartsANewSegmentWithoutLosingEvidence() {
        let input = [
            block(1, app: "Xcode", title: "Vault.swift", start: 0, end: 900),
            block(2, app: "Slack", title: "#team", start: 900, end: 960),
            block(3, app: "Preview", title: "Resume.pdf", start: 960, end: 1_560),
        ]
        let sessions = TimelineWorkSession.sessions(from: input)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].blocks.map(\.id), [1, 2])
        XCTAssertEqual(sessions[1].title, "Resume.pdf")
        XCTAssertEqual(sessions.flatMap(\.blocks).map(\.id), input.map(\.id))
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.activeDuration }, 1_560)
    }

    func testBriefInterruptionsDoNotFragmentDocumentWork() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "Vault.swift", start: 0, end: 900),
            block(2, app: "Slack", title: "#team", start: 900, end: 960),
            block(3, app: "Xcode", title: "Vault.swift", start: 960, end: 1_800),
        ])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].titleEvidence[0].title, "Vault.swift")
        XCTAssertEqual(sessions[0].titleEvidence[0].blocks.map(\.id), [1, 3])
        XCTAssertEqual(sessions[0].titleEvidence[0].duration, 1_740)
    }

    func testContinuousFourHourDayUsesBoundedSegmentsAtSourceBoundaries() {
        let input: [ActivityBlock] = (0..<240).map { (minute: Int) -> ActivityBlock in
            let start = TimeInterval(minute) * 60
            return block(Int64(minute), app: "Xcode", title: "Vault.swift", start: start, end: start + 60)
        }
        let sessions = TimelineWorkSession.sessions(from: input)
        XCTAssertEqual(sessions.count, 6)
        XCTAssertTrue(sessions.allSatisfy { $0.end.timeIntervalSince($0.start) <= 45 * 60 })
        XCTAssertEqual(sessions.flatMap(\.blocks).map(\.id), input.map(\.id))
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.activeDuration }, 4 * 60 * 60)
    }

    func testOverlappingEvidenceIsNotSplitOrDoubleCountedAtDurationBoundary() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "Vault.swift", start: 0, end: 3_600),
            block(2, app: "Preview", title: "Resume.pdf", start: 2_800, end: 4_000),
            block(3, app: "Safari", title: "Docs", start: 4_000, end: 4_300),
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].blocks.map(\.id), [1, 2])
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.activeDuration }, 4_300)
    }

    func testTitleEvidencePreservesDistinctLongTitlesAndOriginalWindowNames() {
        let prefix = String(repeating: "Document ", count: 15)
        let first = prefix + "A", second = prefix + "B"
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Google Chrome", title: first + " - Google Chrome", start: 0, end: 60),
            block(2, app: "Google Chrome", title: second + " - Google Chrome", start: 60, end: 120),
        ])
        XCTAssertEqual(sessions[0].titleEvidence.map(\.title), [first, second])
        XCTAssertEqual(sessions[0].titleEvidence[0].blocks[0].title, first + " - Google Chrome")
    }

    func testTitleRankingUsesUniqueObservedTimeForOverlappingEvidence() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Preview", title: "Resume.pdf", start: 0, end: 300),
            block(2, app: "Preview", title: "Resume.pdf", start: 10, end: 300),
            block(3, app: "Xcode", title: "Vault.swift", start: 300, end: 800),
        ])
        XCTAssertEqual(sessions[0].title, "Vault.swift · Resume.pdf")
        XCTAssertEqual(sessions[0].titleEvidence.map(\.duration), [500, 300])
    }

    func testUntitledSessionNamesItsTwoBusiestAppsAndCountsTheRest() throws {
        let session = try XCTUnwrap(TimelineWorkSession.sessions(from: [
            block(1, app: "Claude", title: "", start: 0, end: 600),
            block(2, app: "Google Chrome", title: "", start: 600, end: 1_000),
            block(3, app: "Discord", title: "", start: 1_000, end: 1_100),
            block(4, app: "Spotify", title: "", start: 1_100, end: 1_150),
        ]).first)
        // Spotify's 50 seconds don't count toward "+1".
        XCTAssertEqual(session.title, "Claude, Google Chrome +1")
        XCTAssertEqual(session.apps.count, 4)
        XCTAssertTrue(session.titleNamesApps)
        XCTAssertEqual(TimelineWorkSession.appSummary(["Claude"]), "Claude")
    }

    /// The rail marks a long stretch with nothing recorded. A meeting that
    /// runs past the next session must not open a gap that never happened.
    func testRailMarksLongGapsFromTheLatestEndSoFar() {
        let sessions = TimelineWorkSession.sessions(from: [
            block(1, app: "Xcode", title: "A.swift", start: 0, end: 600),
            block(2, app: "Xcode", title: "B.swift", start: 3_000, end: 3_300),
            block(3, app: "Xcode", title: "C.swift", start: 6_000, end: 6_300),
            block(4, app: "Xcode", title: "D.swift", start: 9_000, end: 9_600),
        ])
        XCTAssertEqual(sessions.count, 4)
        let meeting = Meeting(
            id: UUID(),
            title: "Planning",
            appName: "Zoom",
            startedAt: base.addingTimeInterval(4_000),
            endedAt: base.addingTimeInterval(8_000),
            relativePath: "meetings/planning")
        let items = TimelineDayItem.items(
            sessions: sessions, meetings: [meeting], now: base.addingTimeInterval(10_000))

        let rows = TimelineRailRow.rows(items: items)

        let gaps: [(TimeInterval, TimeInterval)] = rows.compactMap { row in
            guard case .away(let start, let end) = row else { return nil }
            return (start.timeIntervalSince(base), end.timeIntervalSince(base))
        }
        // 600 → 3,000 is 40 minutes away. 3,300 → 4,000 is under 30 minutes,
        // and the meeting covers C.swift and ends 1,000 s before D.swift.
        XCTAssertEqual(gaps.map(\.0), [600])
        XCTAssertEqual(gaps.map(\.1), [3_000])
        XCTAssertEqual(rows.count, items.count + 1)
    }
}
