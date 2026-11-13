import XCTest
@testable import LokalBot

final class DreamBriefPresentationTests: XCTestCase {
    private let demo = Meeting(
        id: UUID(uuidString: "41d1e338-0000-4000-8000-000000000001")!,
        title: "Demo Day", appName: "Meet", startedAt: Date(timeIntervalSince1970: 0),
        relativePath: "meetings/demo")
    private let standup = Meeting(
        id: UUID(uuidString: "5458e613-0000-4000-8000-000000000002")!,
        title: "Product Standup", appName: "Meet", startedAt: Date(timeIntervalSince1970: 0),
        relativePath: "meetings/standup")

    func testSavedPrioritiesResolveTitlesAndOwnershipWithoutDuplicateTitle() {
        let source = "1. Follow up from Demo Day `41d1e338`.\n2. Chase the four owner:me actions from `5458e613`."
        let rendered = render(source, meetings: [demo, standup])
        XCTAssertEqual(String(rendered.characters),
                       "1. Follow up from Demo Day.\n2. Chase the four actions assigned to you from Product Standup.")
        XCTAssertEqual(rendered.runs.compactMap(\.link).compactMap {
            DreamBriefPresentation.meetingID(for: $0, meetings: [demo, standup])
        }, [demo.id, standup.id])
    }

    func testNarrativeAndRetrospectiveKeepMarkdownAndResolveRepeatedReferences() {
        let rendered = render("Yesterday, `41D1E338` set the plan.\n### Needs attention\n- Follow up `41d1e338` and `5458e613`.",
                              meetings: [demo, standup])
        XCTAssertEqual(String(rendered.characters),
                       "Yesterday, Demo Day set the plan.\nNeeds attention\n• Follow up Demo Day and Product Standup.")
        XCTAssertEqual(rendered.runs.compactMap(\.link).count, 3)
    }

    func testFullUUIDAndUnicodeTitleAreSupported() {
        var meeting = demo
        meeting.title = "Équipe [Q3] *planning*"
        let rendered = render("Discuss `\(meeting.id.uuidString)`.", meetings: [meeting])
        XCTAssertEqual(String(rendered.characters), "Discuss Équipe [Q3] *planning*.")
        XCTAssertEqual(rendered.runs.compactMap(\.link).count, 1)
    }

    func testUnicodeTitleAlreadyPresentBecomesOneLink() {
        var meeting = demo
        meeting.title = "Démo 👋"
        let rendered = render("From Démo 👋 `41d1e338`.", meetings: [meeting])
        XCTAssertEqual(String(rendered.characters), "From Démo 👋.")
        XCTAssertEqual(rendered.runs.compactMap(\.link).count, 1)
    }

    func testUnknownMeetingIsUnavailableWithoutInventedLink() {
        let rendered = render("Follow up from `deadbeef`.", meetings: [demo])
        XCTAssertEqual(String(rendered.characters), "Follow up from Unavailable meeting.")
        XCTAssertTrue(rendered.runs.compactMap(\.link).isEmpty)
    }

    func testAmbiguousShortIDDoesNotSelectFirstMeeting() {
        var collision = standup
        collision = Meeting(id: UUID(uuidString: "41d1e338-0000-4000-8000-000000000099")!,
                            title: collision.title, appName: collision.appName,
                            startedAt: collision.startedAt, relativePath: collision.relativePath)
        let rendered = render("See `41d1e338`.", meetings: [demo, collision])
        XCTAssertEqual(String(rendered.characters), "See Ambiguous meeting reference.")
        XCTAssertTrue(rendered.runs.compactMap(\.link).isEmpty)
        let exact = render("See `\(demo.id.uuidString)`.", meetings: [demo, collision])
        XCTAssertEqual(exact.runs.compactMap(\.link).count, 1)
    }

    func testOtherCodeDatesAndPRNumbersArePreserved() {
        let source = "Retry PR #74's `npm install` from 2026-09-03; address ETIMEDOUT."
        XCTAssertEqual(DreamBriefPresentation.markdown(source, meetings: [demo]), source)
    }

    func testOwnershipCleanupHandlesQuotedTokensAndDoesNotAlterMeetingTitles() {
        var meeting = demo
        meeting.title = "owner:me review"
        let rendered = render("Check `owner:me` tasks from `41d1e338` (owner: me).", meetings: [meeting])
        XCTAssertEqual(String(rendered.characters), "Check tasks assigned to you from owner:me review (assigned to you).")
    }

    func testNavigationOnlyResolvesAnExistingMeetingOnTheInternalRoute() {
        let urls = [
            "https://meeting/\(demo.id)",
            "lokalbot-dream://other/\(demo.id)",
            "lokalbot-dream://meeting/\(standup.id)",
            "lokalbot-dream://meeting/\(demo.id)?unexpected=1",
        ]
        for string in urls {
            XCTAssertNil(DreamBriefPresentation.meetingID(for: URL(string: string)!, meetings: [demo]))
        }
    }

    private func render(_ source: String, meetings: [Meeting]) -> AttributedString {
        SelectableDigestText.attributedText(
            from: DreamBriefPresentation.markdown(source, meetings: meetings))
    }
}
