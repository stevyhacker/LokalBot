import XCTest

final class BackgroundFlowUITests: XCTestCase {
    private var library: SyntheticFixture.Library!
    private var app: XCUIApplication!
    private var suite: String?
    private var stub: Process?

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = try SyntheticFixture.plant(includeActivity: true)
    }

    override func tearDown() {
        app?.terminate()
        stub?.terminate()
        UITestHarness.cleanUp(defaultsSuiteName: suite)
        library?.cleanUp()
    }

    private func fixture(_ name: String, in directory: String = "Fixtures/background") throws -> String {
        try XCTUnwrap(Bundle(for: Self.self).path(forResource: name, ofType: nil, inDirectory: directory),
                      "missing UI test fixture \(directory)/\(name)")
    }

    private func startModelStub() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard let bun = environment["LOKALBOT_TEST_BUN"], let script = environment["LOKALBOT_STUB_SCRIPT"] else {
            XCTFail("ui-shards.py sets LOKALBOT_TEST_BUN and LOKALBOT_STUB_SCRIPT for the background phase")
            throw NSError(domain: "BackgroundFlowUITests", code: 1)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bun)
        process.arguments = ["run", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        stub = process
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) {
            line.append(byte)
        }
        let port = try XCTUnwrap(Int(String(decoding: line, as: UTF8.self)), "stub did not print its port")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/__scenario")!)
        request.httpMethod = "POST"
        request.httpBody = try Data(contentsOf: URL(fileURLWithPath: try fixture("scenario.json")))
        let loaded = expectation(description: "scenario loaded")
        URLSession.shared.dataTask(with: request) { _, _, _ in loaded.fulfill() }.resume()
        wait(for: [loaded], timeout: 5)
        return "http://127.0.0.1:\(port)/v1"
    }

    private func launch(extra: [String: String] = [:]) throws {
        let base = try startModelStub()
        let settings = """
            {"menuBarOnly": false, "trackingEnabled": true, "screenshotsEnabled": false,
             "screenContextCaptureMode": "Text context", "calendarDetectionEnabled": false,
             "autoRecordMode": "Record automatically", "summarizerBackend": "OpenAI-compatible server",
             "openAIBaseURL": "\(base)", "openAIModel": "z-ai/glm-5.3-flash",
             "dictationEnabled": false, "cotypingEnabled": false, "dayDigestAutoEnabled": true,
             "dayDigestHour": 0, "dreamingEnabled": false, "semanticSearchEnabled": false,
             "multiSpeakerDiarization": false}
            """
        CFPreferencesSetAppValue("lokalbotv3.onboarding.shown" as CFString, kCFBooleanTrue,
                                 "me.dotenv.LokalBot.uitesthost" as CFString)
        let launch = try UITestHarness.launch(
            storageRoot: library.root, suitePrefix: "background", settingsJSON: settings,
            environment: ["LOKALBOT_UI_TEST_BACKGROUND": "1",
                          "LOKALBOT_UI_TEST_TRACE": try fixture("meet-call.json", in: "Fixtures/background/capture-traces"),
                          "LOKALBOT_UI_TEST_AUDIO": (try fixture("mic.wav") as NSString).deletingLastPathComponent,
                          "LOKALBOT_TEST_GOLDEN_TRANSCRIPTS": try fixture("golden-transcripts")].merging(extra) { $1 })
        app = launch.app
        suite = launch.defaultsSuiteName
    }

    func testRecordToSearchableAfterBoundaryReview() throws {
        let seededIDs = Set([library.designReview.id, library.standup.id, library.planning.id].map(\.uuidString))
        try launch()
        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        app.buttons["toolbar.record"].click()
        sleep(8)
        app.buttons["toolbar.record"].click()
        var recordedID: String?
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 30) {
            let rows = self.app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "meeting.row."))
            for index in 0..<rows.count {
                let identifier = rows.element(boundBy: index).identifier
                let id = String(identifier.dropFirst("meeting.row.".count))
                if !id.isEmpty, !seededIDs.contains(id) {
                    recordedID = id
                    return true
                }
            }
            return false
        }, "the newly recorded meeting row should appear")
        let meetingID = try XCTUnwrap(recordedID)
        let newRow = app.descendants(matching: .any)["meeting.row.\(meetingID)"]
        newRow.click()
        XCTAssertTrue(UITestHarness.staticText(containing: "shard-quorum", in: app).waitForExistence(timeout: 90),
                      "transcript and notes should appear for the newly recorded meeting")
        UITestHarness.clickSidebar("sidebar.today", in: app)
        XCTAssertTrue(UITestHarness.staticText(containing: "shard-quorum", in: app).waitForExistence(timeout: 20),
                      "the action owned by me appears in Needs Attention")
        search("shard-quorum", expectingMeetingID: meetingID)

        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        newRow.click()
        app.descendants(matching: .any)["toolbar.meetingActions"].click()
        app.menuItems["toolbar.meetingBoundaries"].click()
        replace(app.textFields["boundaries.start"], with: "0")
        replace(app.textFields["boundaries.end"], with: "5")
        app.buttons["boundaries.save"].click()
        search("shard-quorum", expectingMeetingID: meetingID)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func search(_ query: String, expectingMeetingID meetingID: String) {
        UITestHarness.clickSidebar("sidebar.ask", in: app)
        replace(app.textFields["search.field"], with: query)
        let hit = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "search.hit.\(meetingID).")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 60), "the recorded meeting must stay searchable")
    }

    func testSelectingAnotherMeetingWhileRecordingDoesNotCrash() throws {
        try launch()
        UITestHarness.clickSidebar("sidebar.meetings", in: app)
        app.buttons["toolbar.record"].click()
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "meeting.row."))
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 10))
        rows.element(boundBy: 1).click()
        sleep(3)
        app.buttons["toolbar.record"].click()
        XCTAssertEqual(app.state, .runningForeground, "the 0.9.0 crash (#97) happened here")
    }

    func testDetectedMeetCallStartsAndStopsRecording() throws {
        try launch()
        let recording = app.descendants(matching: .any)["sidebar.recording"]
        XCTAssertTrue(recording.waitForExistence(timeout: 30), "the detected call starts a recording")
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 90) { !recording.exists },
                      "the recording stops when the call ends")
    }

    func testScheduledDigestRunsOnAnExistingLibrary() throws {
        let journal = library.root.appendingPathComponent("journal", isDirectory: true)
        if FileManager.default.fileExists(atPath: journal.path) {
            try FileManager.default.removeItem(at: journal)
        }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let todayKey = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        let digestURL = journal.appendingPathComponent("\(todayKey).md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: digestURL.path))
        try launch()
        XCTAssertTrue(UITestHarness.waitUntil(timeout: 120) {
            guard let text = try? String(contentsOf: digestURL, encoding: .utf8) else { return false }
            return text.contains("Implement LRU eviction policy")
        }, "the scheduler must generate the day's digest through the model stub (#113)")
        UITestHarness.clickSidebar("sidebar.timeline", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["dayDigest.tasks"].waitForExistence(timeout: 20),
                      "the generated digest must render on Timeline (#113)")
    }
}
