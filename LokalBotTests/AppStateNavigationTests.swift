import XCTest
@testable import LokalBot

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
