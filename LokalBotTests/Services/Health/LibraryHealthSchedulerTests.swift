import XCTest
@testable import LokalBot

final class LibraryHealthSchedulerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    func testFirstRunHappensImmediately() {
        XCTAssertTrue(LibraryHealthScheduler.shouldRun(at: date(30, 8), lastRun: nil, hour: 9, calendar: calendar))
    }

    func testRunsOncePerDayAfterTheHour() {
        XCTAssertFalse(LibraryHealthScheduler.shouldRun(at: date(30, 8), lastRun: date(29, 9), hour: 9, calendar: calendar))
        XCTAssertTrue(LibraryHealthScheduler.shouldRun(at: date(30, 9), lastRun: date(29, 9), hour: 9, calendar: calendar))
        XCTAssertFalse(LibraryHealthScheduler.shouldRun(at: date(30, 15), lastRun: date(30, 9), hour: 9, calendar: calendar))
    }

    func testCatchesUpAtLaunchWhenTheLastRunIsOlderThanADay() {
        XCTAssertTrue(LibraryHealthScheduler.shouldRun(at: date(30, 7), lastRun: date(28, 9), hour: 9, calendar: calendar))
    }
}
