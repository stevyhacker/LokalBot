import XCTest
@testable import LokalBot

final class ActionDueResolverTests: XCTestCase {
    private var calendar: Calendar!
    /// Tuesday, 22 September 2026, mid-morning.
    private var tuesday: Date!

    override func setUpWithError() throws {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Belgrade") ?? .current
        tuesday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 22, hour: 10, minute: 30)))
    }

    private func resolved(_ phrase: String, from date: Date? = nil) -> String? {
        ActionDueResolver.resolve(phrase, spokenAt: date ?? tuesday, calendar: calendar)
            .map { AskDayScope.key(for: $0, calendar: calendar) }
    }

    func testExplicitISODatesResolveExactly() {
        XCTAssertEqual(resolved("2026-10-01"), "2026-10-01")
        XCTAssertEqual(resolved("by 2026-10-01"), "2026-10-01")
        XCTAssertNil(resolved("2026-02-30"))
    }

    func testDayRelativePhrases() {
        XCTAssertEqual(resolved("today"), "2026-09-22")
        XCTAssertEqual(resolved("by end of day"), "2026-09-22")
        XCTAssertEqual(resolved("EOD"), "2026-09-22")
        XCTAssertEqual(resolved("Tomorrow"), "2026-09-23")
        XCTAssertEqual(resolved("by tomorrow morning"), "2026-09-23")
        XCTAssertEqual(resolved("sutra"), "2026-09-23")
    }

    func testWeekdaysResolveToTheNextOccurrence() {
        XCTAssertEqual(resolved("Friday"), "2026-09-25")
        XCTAssertEqual(resolved("by Friday."), "2026-09-25")
        XCTAssertEqual(resolved("on Monday"), "2026-09-28")
        // The same weekday means the following week, never the day it was said.
        XCTAssertEqual(resolved("Tuesday"), "2026-09-29")
        XCTAssertEqual(resolved("do petka"), "2026-09-25")
    }

    func testNextWeekdayMeansTheFollowingWeek() {
        XCTAssertEqual(resolved("next Friday"), "2026-10-02")
        // Said on a Saturday, the next Monday is already in the following week.
        let saturday = calendar.date(byAdding: .day, value: 4, to: tuesday)
        XCTAssertEqual(resolved("next Monday", from: saturday), "2026-09-28")
    }

    func testRangesResolveToTheirLastWorkingDay() {
        XCTAssertEqual(resolved("end of the week"), "2026-09-25")
        XCTAssertEqual(resolved("EOW"), "2026-09-25")
        XCTAssertEqual(resolved("this week"), "2026-09-25")
        XCTAssertEqual(resolved("next week"), "2026-10-02")
        XCTAssertEqual(resolved("by end of month"), "2026-09-30")
        XCTAssertEqual(resolved("next month"), "2026-10-31")
        XCTAssertEqual(resolved("end of Q3"), "2026-09-30")
        XCTAssertEqual(resolved("Q4"), "2026-12-31")
        // A quarter that already ended refers to next year's quarter.
        XCTAssertEqual(resolved("Q1"), "2027-03-31")
        XCTAssertEqual(resolved("Q1 2026"), "2026-03-31")
    }

    func testRelativeOffsets() {
        XCTAssertEqual(resolved("in 3 days"), "2026-09-25")
        XCTAssertEqual(resolved("in two weeks"), "2026-10-06")
        XCTAssertEqual(resolved("within a week"), "2026-09-29")
        // Business days skip the weekend.
        XCTAssertEqual(resolved("in 5 business days"), "2026-09-29")
    }

    func testMonthAndDayPhrases() {
        XCTAssertEqual(resolved("Oct 5"), "2026-10-05")
        XCTAssertEqual(resolved("by October 5th"), "2026-10-05")
        XCTAssertEqual(resolved("5 October"), "2026-10-05")
        XCTAssertEqual(resolved("the 5th of October"), "2026-10-05")
        XCTAssertEqual(resolved("Sep 20"), "2026-09-20")
        // Far in the past without a year means next year.
        XCTAssertEqual(resolved("January 10"), "2027-01-10")
        XCTAssertEqual(resolved("January 10, 2026"), "2026-01-10")
        XCTAssertNil(resolved("February 30"))
    }

    func testUnsupportedPhrasesStayUnresolved() {
        XCTAssertNil(resolved("once the budget lands"))
        XCTAssertNil(resolved("soon"))
        XCTAssertNil(resolved("before the next release"))
        XCTAssertNil(resolved(""))
        XCTAssertNil(ActionDueResolver.resolve(nil, spokenAt: tuesday, calendar: calendar))
    }

    func testLabelsKeepTheOriginalPhraseBesideTheResolvedDate() {
        let label = ActionDuePresentation.label("Friday", spokenAt: tuesday)
        XCTAssertTrue(label.hasPrefix("Due "), label)
        XCTAssertTrue(label.contains("said “Friday”"), label)
        XCTAssertFalse(ActionDuePresentation.label("2026-10-01", spokenAt: tuesday).contains("said"))
        XCTAssertTrue(ActionDuePresentation.label("when ready", spokenAt: tuesday).contains("said on"))
    }

    func testAttentionOrderPutsOverdueThenDueSoonFirst() throws {
        let meetingID = UUID()
        func reference(_ text: String, due: String?, spoken: Date) -> OutcomeActionReference {
            let action = MeetingOutcomes.ActionItem(text: text, owner: "Me", due: due)
            return OutcomeActionReference(
                meetingID: meetingID, meetingTitle: "Sync", meetingStartedAt: spoken,
                action: action, status: .open, text: action.text, owner: "Me", due: due,
                stateUpdatedAt: spoken, textWasCorrected: false, ownerWasCorrected: false,
                dueWasCorrected: false)
        }
        let lastWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: tuesday))
        let threads = ActionThreadClusterer.cluster([
            reference("Undated synthetic follow-up task", due: nil, spoken: tuesday),
            reference("Due soon synthetic review work", due: "Friday", spoken: tuesday),
            reference("Overdue synthetic budget draft", due: "Thursday", spoken: lastWeek),
            reference("Far future synthetic planning memo", due: "next month", spoken: tuesday),
        ])
        let ordered = ActionAttentionOrder.sorted(threads, now: tuesday, calendar: calendar)
        XCTAssertEqual(ordered.map(\.text).prefix(2), [
            "Overdue synthetic budget draft", "Due soon synthetic review work",
        ])
        XCTAssertEqual(ordered.count, 4)
    }
}
