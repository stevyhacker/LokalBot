import XCTest

/// Pins down Today's first-day steps: on an empty library they are the page,
/// hiding them must leave a useful home, and the choice must survive a fresh
/// app process.
final class GettingStartedUITests: XCTestCase {
    private var root: URL!
    private var app: XCUIApplication!
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GettingStartedUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings"),
            withIntermediateDirectories: true)

        let launch = try UITestHarness.launch(
            storageRoot: root,
            suitePrefix: "GettingStarted",
            environment: ["LOKALBOT_SHOW_GETTING_STARTED": "1"])
        app = launch.app
        defaultsSuiteName = launch.defaultsSuiteName
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: root)
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    func testDismissedCardStaysDismissedAcrossRelaunch() throws {
        let dismiss = app.buttons["welcome.dismiss"]
        UITestHarness.scrollTo(dismiss, in: app, attempts: 10)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 8),
                      "getting-started card did not appear on the Today home")
        XCTAssertTrue(app.descendants(matching: .any)["today.gettingStarted"].exists)
        dismiss.click()
        XCTAssertFalse(dismiss.exists, "getting-started card remained visible after dismissal")
        XCTAssertTrue(app.descendants(matching: .any)["today.empty"].waitForExistence(timeout: 4),
                      "an empty Today says what will show up there")

        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "No meetings yet", in: app)
            .waitForExistence(timeout: 4), "Meetings empty state missing after dismissal")

        app = try UITestHarness.relaunch(
            storageRoot: root,
            defaultsSuiteName: try XCTUnwrap(defaultsSuiteName))
        XCTAssertTrue(app.descendants(matching: .any)["today.header"]
            .waitForExistence(timeout: 8), "main window did not return after relaunch")
        XCTAssertFalse(app.buttons["welcome.dismiss"].exists,
                       "getting-started card returned after relaunch")
    }
}
