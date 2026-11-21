import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    func testClosingTheLastWindowKeepsTheAppRunning() {
        let delegate: NSApplicationDelegate = AppDelegate()

        XCTAssertEqual(
            delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApplication.shared),
            false)
    }
}
