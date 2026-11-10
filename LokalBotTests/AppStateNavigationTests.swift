import XCTest
@testable import LokalBot

/// Today shares its section with the Actions review (`showingActions`), so a
/// route to Today has to leave that review.
@MainActor
final class AppStateNavigationTests: XCTestCase {
    func testGoingToTodayLeavesTheActionsReview() {
        let app = AppState()
        app.openActions()
        XCTAssertTrue(app.showingActions)

        app.openToday()

        XCTAssertFalse(app.showingActions)
        XCTAssertEqual(app.navSection, .today)
    }

    /// Today's digest and the overnight review are shown on Today. Opening
    /// their background activity used to land on Actions when it was open.
    func testBackgroundActivityForTodayOpensTodayNotTheActionsReview() {
        for destination in [BackgroundActivity.Destination.day(Date()), .dream] {
            let app = AppState()
            app.openActions()
            app.navSection = .agent

            app.openBackgroundActivity(destination)

            XCTAssertEqual(app.navSection, .today, "\(destination)")
            XCTAssertFalse(app.showingActions, "\(destination)")
        }
    }
}
