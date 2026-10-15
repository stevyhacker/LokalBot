import AppKit
import XCTest

/// Uses LokalBotApp's actual SwiftUI scenes and adapted AppDelegate. The usual
/// UI host's manually-created MeetingFindWindow cannot catch scene termination.
/// Only capture/inference and real user storage remain replaced by test fixtures.
final class WindowLifecycleUITests: XCTestCase {
    private var fixture: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = try SyntheticFixture.plant()
        app = XCUIApplication(bundleIdentifier: "me.dotenv.LokalBot.uitesthost")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let root = fixture?.root,
           let trace = try? String(contentsOf: root.appendingPathComponent("window-lifecycle.log"), encoding: .utf8) {
            let attachment = XCTAttachment(string: trace)
            attachment.name = "SwiftUI window lifecycle"
            attachment.lifetime = .keepAlways
            add(attachment)
            print(trace)
        }
        fixture?.cleanUp()
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testRedCloseButtonKeepsMenuBarOnlyProcessAlive() throws {
        try closeAndReopen(menuBarOnly: true, commandW: false)
    }

    func testCommandWKeepsMenuBarOnlyProcessAlive() throws {
        try closeAndReopen(menuBarOnly: true, commandW: true)
    }

    func testRedCloseButtonKeepsDockProcessAlive() throws {
        try closeAndReopen(menuBarOnly: false, commandW: false)
    }

    func testCommandWKeepsDockProcessAlive() throws {
        try closeAndReopen(menuBarOnly: false, commandW: true)
    }

    private func closeAndReopen(menuBarOnly: Bool, commandW: Bool) throws {
        let launch = try UITestHarness.launch(
            storageRoot: fixture.root,
            suitePrefix: "WindowLifecycle",
            settingsJSON: """
            {"menuBarOnly": \(menuBarOnly), "trackingEnabled": false,
             "screenshotsEnabled": false, "calendarDetectionEnabled": false,
             "semanticSearchEnabled": false, "cotypingEnabled": false}
            """,
            environment: [
                "LOKALBOT_UI_TEST_WINDOW_LIFECYCLE": "1",
                "LOKALBOT_UI_TEST_DIAGNOSTICS": "1",
                "LOKALBOT_UI_TEST_DIAGNOSTICS_FILE": fixture.root.appendingPathComponent("window-lifecycle.log").path,
            ])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
        XCTAssertTrue(app.descendants(matching: .any)["today.header"].waitForExistence(timeout: 10))
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: "me.dotenv.LokalBot.uitesthost").first)
        let originalPID = running.processIdentifier
        XCTAssertEqual(running.activationPolicy, .regular, "An open workspace needs the app menu")
        XCTAssertEqual(app.windows.count, 1, "Close the last content window, not one of several")

        if commandW {
            app.typeKey("w", modifierFlags: .command)
        } else {
            app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        }

        // Observe the original process continuously. app.activate()/launch()
        // here would hide a crash or quit by silently starting another process.
        let terminated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in running.isTerminated }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [terminated], timeout: 3), .timedOut,
                       "Closing the SwiftUI main window terminated PID \(originalPID)")
        XCTAssertTrue(UITestHarness.waitUntil {
            running.activationPolicy == (menuBarOnly ? .accessory : .regular)
        }, "Wrong activation policy after closing the last window")
        XCTAssertEqual(app.windows.count, 0, "The close action must actually remove the window")

        // Exercise the actual Finder/Dock reopen route, not a test-only opener.
        // A replacement process must fail even if it shows an identical window.
        try UITestHarness.reopen(running)
        XCTAssertFalse(running.isTerminated)
        XCTAssertTrue(app.descendants(matching: .any)["today.header"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertTrue(UITestHarness.waitUntil { running.activationPolicy == .regular })

        // Explicit Quit still works; keeping the process alive must not be a
        // blanket veto of termination (or an extra invisible test window).
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 10) { running.isTerminated },
                      "Command-Q must terminate the original process")
    }
}
