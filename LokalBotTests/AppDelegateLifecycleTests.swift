import AppKit
import XCTest
@testable import LokalBot

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    /// Covers the delegate's answer only. WindowLifecycleUITests closes the
    /// running SwiftUI scene and checks process survival and reopening (#248).
    func testDelegateDeclinesLastWindowTermination() {
        let delegate: NSApplicationDelegate = AppDelegate()

        XCTAssertEqual(
            delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApplication.shared),
            false)
    }
}
