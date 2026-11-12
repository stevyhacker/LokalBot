import XCTest
@testable import LokalBot

/// Actions is its own sidebar destination, so routes to Today and to Actions
/// each land on their own section.
@MainActor
final class AppStateNavigationTests: XCTestCase {
    func testActionsAndTodayAreSeparateDestinations() {
        let app = AppState()
        app.openActions()
        XCTAssertEqual(app.navSection, .actions)

        app.openToday()

        XCTAssertEqual(app.navSection, .today)
    }

    func testActionsHasACaptureAndDeepLinkName() {
        XCTAssertEqual(AppState.NavSection(captureName: "actions"), .actions)
        XCTAssertEqual(AppState.NavSection(captureName: "Actions"), .actions)
    }

    /// Today's digest and the overnight review are shown on Today. Opening
    /// their background activity lands there from any section, Actions
    /// included.
    func testBackgroundActivityForTodayOpensToday() {
        for destination in [BackgroundActivity.Destination.day(Date()), .dream] {
            for start in [AppState.NavSection.actions, .agent] {
                let app = AppState()
                app.navSection = start

                app.openBackgroundActivity(destination)

                XCTAssertEqual(app.navSection, .today, "\(destination) from \(start)")
            }
        }
    }
}
