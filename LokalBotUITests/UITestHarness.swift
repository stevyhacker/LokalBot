import Foundation
import AppKit
import CoreGraphics
import XCTest

enum UITestHarness {
    private static let defaultsKey = "lokalbotv3.settings"
    private static let appBundleIdentifier = "me.dotenv.LokalBot.uitesthost"
    private static let uiTestEnabledKey = "lokalbot.uiTest.enabled"
    private static let uiTestStorageRootKey = "lokalbot.uiTest.storageRoot"
    private static let uiTestDefaultsSuiteKey = "lokalbot.uiTest.defaultsSuite"
    private static let gettingStartedDismissedKey = "lokalbotv3.gettingStartedDismissed"

    struct Launch {
        let app: XCUIApplication
        let defaultsSuiteName: String
    }

    static func launch(
        storageRoot: URL,
        suitePrefix: String,
        settingsJSON: String = defaultSettingsJSON,
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Launch {
        let suiteName = "me.dotenv.LokalBotUITests.\(suitePrefix).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data(settingsJSON.utf8), forKey: defaultsKey)
        _ = CFPreferencesAppSynchronize(suiteName as CFString)
        seedAppLaunchDefaults(storageRoot: storageRoot, defaultsSuiteName: suiteName)

        let app = try launchAndVerify(
            storageRoot: storageRoot,
            defaultsSuiteName: suiteName,
            environment: ["LOKALBOT_RESET_SPLIT_VIEWS": "1"].merging(environment) { _, new in new },
            file: file,
            line: line)

        return Launch(app: app, defaultsSuiteName: suiteName)
    }

    static func relaunch(
        storageRoot: URL,
        defaultsSuiteName: String,
        environment: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIApplication {
        seedAppLaunchDefaults(storageRoot: storageRoot, defaultsSuiteName: defaultsSuiteName)
        return try launchAndVerify(
            storageRoot: storageRoot,
            defaultsSuiteName: defaultsSuiteName,
            environment: environment,
            file: file,
            line: line)
    }

    private static func launchAndVerify(
        storageRoot: URL,
        defaultsSuiteName: String,
        environment: [String: String],
        file: StaticString,
        line: UInt
    ) throws -> XCUIApplication {
        terminateRunningApp()

        let (app, process) = try launchApplication(
            storageRoot: storageRoot,
            defaultsSuiteName: defaultsSuiteName,
            environment: environment,
            file: file,
            line: line)

        let found = waitForRunningApp(process: process, timeout: 20)
        let runningApp = try XCTUnwrap(
            found,
            "LokalBot UI Test Host did not appear in NSRunningApplication"
                + " (its process is \(process.isRunning ? "still running" : "gone"))",
            file: file,
            line: line)
        XCTAssertEqual(runningApp.bundleIdentifier, appBundleIdentifier,
                       "Launched unexpected application bundle",
                       file: file, line: line)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 8)
                || app.wait(for: .runningBackground, timeout: 12),
            "LokalBot UI Test Host did not launch", file: file, line: line)
        XCTAssertTrue(
            waitForVisibleWindow(processIdentifier: runningApp.processIdentifier, timeout: 8),
            "LokalBot UI Test Host did not create a visible native window",
            file: file,
            line: line)
        return app
    }

    static func cleanUp(defaultsSuiteName: String?) {
        if let defaultsSuiteName {
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        }
        let appID = appBundleIdentifier as CFString
        CFPreferencesSetAppValue(uiTestEnabledKey as CFString, nil, appID)
        CFPreferencesSetAppValue(uiTestStorageRootKey as CFString, nil, appID)
        CFPreferencesSetAppValue(uiTestDefaultsSuiteKey as CFString, nil, appID)
        CFPreferencesSetAppValue(gettingStartedDismissedKey as CFString, nil, appID)
        _ = CFPreferencesAppSynchronize(appID)
    }

    static func clickSidebar(
        _ id: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.activate()
        _ = app.wait(for: .runningForeground, timeout: 3)
        if id == "sidebar.settings" {
            if settingsWindow(in: app).exists { return }
        } else {
            closeSettings(in: app)
        }
        let label = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@", id)).firstMatch
        if label.waitForExistence(timeout: 3) {
            label.click()
            return
        }
        let fallback = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", id)).firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 4),
                      "sidebar item \(id) not found", file: file, line: line)
        fallback.click()
    }

    static func staticText(containing fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                        fragment, fragment))
            .firstMatch
    }

    static func selectSegment(
        _ name: String,
        pickerIdentifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if pickerIdentifier == "settings.tab" {
            selectSettingsCategory(name, in: app, file: file, line: line)
            return
        }
        let picker = app.descendants(matching: .any)[pickerIdentifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 8),
                      "segmented picker \(pickerIdentifier) missing", file: file, line: line)
        let compactPicker = app.popUpButtons[pickerIdentifier]
        if compactPicker.exists {
            compactPicker.click()
            let item = app.menuItems[name]
            XCTAssertTrue(item.waitForExistence(timeout: 3), file: file, line: line)
            item.click()
            return
        }
        let segment = segment(name, pickerIdentifier: pickerIdentifier, in: app)
        XCTAssertTrue(segment.waitForExistence(timeout: 4),
                      "segment \(name) missing", file: file, line: line)
        segment.click()
    }

    static func toggle(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
            XCUIElement.ElementType.checkBox.rawValue, XCUIElement.ElementType.switch.rawValue)).firstMatch
    }

    static func settingsWindow(in app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier == %@ OR identifier == %@",
                                         "settings.window", "settings")).firstMatch
    }

    static func closeSettings(in app: XCUIApplication) {
        let window = settingsWindow(in: app)
        guard window.exists else { return }
        window.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
        waitUntil(timeout: 3) { !window.exists }
    }

    static func selectSettingsCategory(_ name: String, in app: XCUIApplication,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let renamed = ["Recording": "Meetings", "Privacy": "Privacy & permissions", "Privacy & Data": "Privacy & permissions",
                       "Privacy & Permissions": "Privacy & permissions",
                       "Writing": "Autocomplete", "Advanced": "Diagnostics", "Day Memory": "Screen & activity",
                       "Screen & Activity": "Screen & activity", "Daily Review": "Daily review",
                       "Personal Context": "About you", "External Agents": "AI agents", "Overview": "LokalBot"]
        let title = renamed[name] ?? name
        let list = app.descendants(matching: .any)["settings.categories"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 6), file: file, line: line)
        let row = list.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 4), "Settings category missing: \(title)", file: file, line: line)
        row.click()
    }

    static func segment(
        _ name: String,
        pickerIdentifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let picker = app.descendants(matching: .any)[pickerIdentifier]
        return picker.buttons[name].exists ? picker.buttons[name] : picker.radioButtons[name]
    }

    static func scrollTo(
        _ element: XCUIElement,
        in app: XCUIApplication,
        within viewport: XCUIElement? = nil,
        upward: Bool = false,
        attempts: Int = 12
    ) {
        let settings = settingsWindow(in: app)
        let candidates = (settings.exists ? settings.scrollViews : app.scrollViews).allElementsBoundByIndex
        let scrollArea = viewport ?? candidates.max {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        } ?? app.groups.firstMatch
        for _ in 0..<attempts {
            var scrollUp = upward
            if element.exists {
                let frame = element.frame
                let visible = scrollArea.frame.insetBy(dx: 0, dy: 4)
                if element.isHittable && (viewport == nil || visible.contains(frame)) { return }
                if viewport != nil { scrollUp = frame.minY < visible.minY }
            }
            scrollArea.scroll(byDeltaX: 0, deltaY: scrollUp ? 300 : -300)
            usleep(120_000)
        }
    }

    @discardableResult
    static func waitUntil(
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.1,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline
        return condition()
    }

    private static let defaultSettingsJSON = """
    {
      "menuBarOnly": false,
      "trackingEnabled": true,
      "screenshotsEnabled": false,
      "calendarDetectionEnabled": false,
      "semanticSearchEnabled": false,
      "cotypingEnabled": false
    }
    """

    private static func launchApplication(
        storageRoot: URL,
        defaultsSuiteName: String,
        environment: [String: String],
        file: StaticString,
        line: UInt
    ) throws -> (app: XCUIApplication, process: Process) {
        let appURL = try hostAppURL(file: file, line: line)
        let executableURL = appURL
            .appendingPathComponent("Contents/MacOS/LokalBot UI Test Host")
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: executableURL.path),
            "LokalBot UI Test Host executable missing at \(executableURL.path)",
            file: file,
            line: line)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "--lokalbot-ui-test",
            "--lokalbot-storage-root", storageRoot.path,
            "--lokalbot-defaults-suite", defaultsSuiteName,
        ]
        process.environment = appHostEnvironment().merging([
            "LOKALBOT_UI_TEST": "1",
            "LOKALBOT_STORAGE_ROOT": storageRoot.path,
            "LOKALBOT_DEFAULTS_SUITE": defaultsSuiteName,
        ]) { _, new in new }.merging(environment) { _, new in new }
        try process.run()

        return (XCUIApplication(bundleIdentifier: appBundleIdentifier), process)
    }

    private static func appHostEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "PATH", "USER", "LOGNAME", "LANG", "SHELL"] {
            if let value = source[key], !value.isEmpty {
                environment[key] = value
            }
        }
        return environment
    }

    private static func hostAppURL(file: StaticString, line: UInt) throws -> URL {
        let productsDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
        let appURL = productsDirectory.appendingPathComponent("LokalBot UI Test Host.app")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appURL.path),
            "LokalBot UI Test Host app missing at \(appURL.path)",
            file: file,
            line: line)
        return appURL
    }

    private static func seedAppLaunchDefaults(storageRoot: URL, defaultsSuiteName: String) {
        let appID = appBundleIdentifier as CFString
        CFPreferencesSetAppValue(uiTestEnabledKey as CFString, kCFBooleanTrue, appID)
        CFPreferencesSetAppValue(uiTestStorageRootKey as CFString, storageRoot.path as CFString, appID)
        CFPreferencesSetAppValue(uiTestDefaultsSuiteKey as CFString, defaultsSuiteName as CFString, appID)
        _ = CFPreferencesAppSynchronize(appID)
    }

    private static func waitForVisibleWindow(
        processIdentifier: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasVisibleWindow(processIdentifier: processIdentifier) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private static func hasVisibleWindow(processIdentifier: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else {
                return false
            }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            guard alpha > 0 else { return false }

            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
            return width >= 200 && height >= 200
        }
    }

    private static func waitForRunningApp(process: Process, timeout: TimeInterval) -> NSRunningApplication? {
        let deadline = Date().addingTimeInterval(timeout)
        var pastDeadline = false
        while true {
            if let app = runningHost(process: process) { return app }
            if pastDeadline || !process.isRunning { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            pastDeadline = Date() >= deadline
        }
    }

    private static func runningHost(process: Process) -> NSRunningApplication? {
        if process.isRunning,
           let app = NSRunningApplication(processIdentifier: process.processIdentifier),
           !app.isTerminated, app.bundleIdentifier == appBundleIdentifier {
            return app
        }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: appBundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private static func terminateRunningApp() {
        for runningApp in NSRunningApplication
            .runningApplications(withBundleIdentifier: appBundleIdentifier) {
            runningApp.terminate()
            let deadline = Date().addingTimeInterval(4)
            while !runningApp.isTerminated, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if !runningApp.isTerminated {
                runningApp.forceTerminate()
            }
        }
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let stillRunning = NSRunningApplication
                .runningApplications(withBundleIdentifier: appBundleIdentifier)
                .contains { !$0.isTerminated }
            if !stillRunning { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
