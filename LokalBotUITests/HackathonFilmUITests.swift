import AppKit
import AVFoundation
import XCTest

/// Clicks through Live Radar and Follow-through end to end and films it: the
/// Meta Muse settings, Start Radar on a live meeting whose transcript arrives
/// turn by turn with fast live text, a question answered from a synthetic
/// screen capture, the floating Live Radar panel that shows the same items
/// over the meeting app, and Follow-through on the commitment it caught. The
/// runner has no meeting audio, so the transcript's words come from the script.
///
/// By default Muse replies are scripted in the host (`LOKALBOT_MUSE_UI_TEST=1`),
/// so no key or network is used and the checks name exact items. With
/// `LOKALBOT_FILM_MUSE=live` and `LOKALBOT_FILM_META_KEY_FILE` naming a file
/// that holds a Meta Model API key, the host calls Muse Spark and Muse Wonder
/// on this fixture, and the checks look for kinds of items and approve
/// whatever steps Follow-through proposes. With `LOKALBOT_FILM_FRAMES` set,
/// frames and their durations are written there for
/// `.github/workflows/meta-hackathon-film.yml` to encode.
final class HackathonFilmUITests: XCTestCase {
    private var library: URL!
    private var defaultsSuiteName: String?
    private var film: Film!

    override func setUpWithError() throws {
        continueAfterFailure = false
        library = FileManager.default.temporaryDirectory
            .appendingPathComponent("LokalBotFilm-\(UUID().uuidString)", isDirectory: true)
        try FilmFixture.plant(in: library)
        film = try Film()
    }

    override func tearDownWithError() throws {
        film?.finish(in: self)
        XCUIApplication(bundleIdentifier: "me.dotenv.LokalBot.uitesthost").terminate()
        try? FileManager.default.removeItem(at: library)
        UITestHarness.cleanUp(defaultsSuiteName: defaultsSuiteName)
    }

    /// The host's Muse mode, and the key file for live replies.
    private var muse: [String: String] {
        let env = ProcessInfo.processInfo.environment
        if env["LOKALBOT_FILM_MUSE"] == "live", let file = env["LOKALBOT_FILM_META_KEY_FILE"],
           FileManager.default.fileExists(atPath: file) {
            return ["LOKALBOT_MUSE_UI_TEST": "live", "LOKALBOT_UI_TEST_META_API_KEY_FILE": file]
        }
        return ["LOKALBOT_MUSE_UI_TEST": "1"]
    }

    private var isLive: Bool { muse["LOKALBOT_MUSE_UI_TEST"] == "live" }

    /// As large as the runner's desktop allows, so the film has room for text.
    private var windowSize: [String: String] {
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1600, height: 1000)
        let width = Int(min(1_560, visible.width - 24))
        let height = Int(min(1_080, visible.height - 16))
        return ["LOKALBOT_CAPTURE_SIZE": "\(width)x\(height)"]
    }

    private func radarItems(_ kind: String = "", in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "radar.item.\(kind)"))
    }

    func testFilmLiveRadarAndFollowThrough() throws {
        XCTContext.runActivity(named: isLive ? "Muse replies: live" : "Muse replies: scripted") { _ in }
        // 1. Connect Meta Muse in Settings → Recording.
        let launch = try UITestHarness.launch(
            storageRoot: library, suitePrefix: "Film", settingsJSON: FilmFixture.settingsJSON,
            environment: ["LOKALBOT_INITIAL_SECTION": "settings",
                          "LOKALBOT_INITIAL_SETTINGS_CATEGORY": "recording",
                          "LOKALBOT_DISMISS_ONBOARDING": "1"].merging(windowSize) { _, new in new })
        defaultsSuiteName = launch.defaultsSuiteName
        var app = launch.app
        let keyField = app.secureTextFields["settings.metaMuse.key"]
        UITestHarness.scrollTo(keyField, in: app, within: app.scrollViews["settings.form"])
        XCTAssertTrue(film.wait(for: keyField, timeout: 15), "Meta Muse settings did not render")
        film.hold(1.5)
        keyField.click()
        keyField.typeText("demo-key-not-real")
        film.hold(0.8)
        app.buttons["Save key"].click()
        film.hold(1.5)
        // Fast live text and screen answers are on in this library's settings.
        let screenAnswers = app.descendants(matching: .any)["settings.metaMuse.screenAnswers"].firstMatch
        UITestHarness.scrollTo(screenAnswers, in: app, within: app.scrollViews["settings.form"])
        XCTAssertTrue(film.wait(for: screenAnswers, timeout: 5), "the screen answers switch did not render")
        film.hold(3)

        // 2. A live meeting: Start Radar, then the transcript arrives line by line.
        app = try UITestHarness.relaunch(
            storageRoot: library, defaultsSuiteName: launch.defaultsSuiteName,
            environment: ["LOKALBOT_UI_TEST_WINDOW": "live-preview",
                          "LOKALBOT_UI_TEST_LIVE_SCRIPT": FilmFixture.liveScript(in: library).path,
                          "LOKALBOT_UI_TEST_SCREENS": try FilmFixture.screens().path,
                          "LOKALBOT_DISMISS_ONBOARDING": "1"].merging(muse) { _, new in new }
                .merging(windowSize) { _, new in new })
        let start = app.buttons["live.radar.start"]
        XCTAssertTrue(film.wait(for: start, timeout: 15), "Live Radar pane did not render")
        film.hold(2)
        start.click()
        let started = Date()
        let panel = app.descendants(matching: .any)["liveRadarPanel"].firstMatch
        XCTAssertTrue(film.wait(for: panel, timeout: 10), "the floating Live Radar panel did not open")
        XCTAssertTrue(film.wait(for: UITestHarness.staticText(containing: "Muse Voice Transcribe", in: app), timeout: 10),
                      "the preview isn't using fast live text")
        let screenAnswer = app.descendants(matching: .any)["radar.screenAnswer"].firstMatch
        if isLive {
            // Real replies vary: require a contradiction with the earlier
            // meeting, an answer from a screen capture, and a few items, and
            // let the last pass after the final line (about 60 s in) finish.
            XCTAssertTrue(film.wait(for: radarItems("contradiction", in: app).firstMatch, timeout: 75),
                          "Muse found no contradiction with the earlier meeting")
            XCTAssertTrue(film.wait(for: screenAnswer, timeout: 75), "no question was answered from the screen")
            film.hold(max(0, 78 - Date().timeIntervalSince(started)))
            XCTAssertGreaterThanOrEqual(radarItems(in: app).count, 3, "Muse caught fewer than three items")
        } else {
            XCTAssertTrue(film.wait(for: screenAnswer, timeout: 40), "the conversion question was not answered from the screen")
            XCTAssertTrue(UITestHarness.staticText(containing: "4.1% in September", in: app).exists)
            let contradiction = UITestHarness.staticText(containing: "Launch moved to Friday", in: app)
            XCTAssertTrue(film.wait(for: contradiction, timeout: 60), "the launch-date contradiction never appeared")
            let decision = UITestHarness.staticText(containing: "Annual plans get 20% off", in: app)
            XCTAssertTrue(film.wait(for: decision, timeout: 60), "the annual-plan decision never appeared")
            XCTAssertTrue(UITestHarness.staticText(containing: "Free tier cut to one project", in: app).exists)
            XCTAssertTrue(UITestHarness.staticText(containing: "Send the revised pricing deck", in: app).exists)
        }
        film.hold(3)
        // The panel folds to its header and the newest item, and back.
        let collapse = app.buttons["liveRadarPanel.collapse"].firstMatch
        if collapse.exists {
            collapse.click()
            film.hold(2.5)
            collapse.click()
            film.hold(2)
        }
        // Closing it leaves the board; UI tests would otherwise check the
        // panel before every scroll.
        let closePanel = app.buttons["liveRadarPanel.close"].firstMatch
        if closePanel.exists {
            closePanel.click()
            film.hold(1)
        }
        // What needs attention leads the board; scroll to the commitments and decision.
        let radarList = app.scrollViews["radar.items"]
        if radarList.exists {
            for _ in 0..<3 {
                radarList.scroll(byDeltaX: 0, deltaY: -220)
                film.hold(1.6)
            }
        }
        film.hold(2)

        // 3. After the meeting: its page keeps what the radar caught. Follow through.
        app = try UITestHarness.relaunch(
            storageRoot: library, defaultsSuiteName: launch.defaultsSuiteName,
            environment: ["LOKALBOT_INITIAL_SECTION": "meetings",
                          "LOKALBOT_SELECT_FIRST": "1",
                          "LOKALBOT_DISMISS_ONBOARDING": "1"].merging(muse) { _, new in new }
                .merging(windowSize) { _, new in new })
        let followThrough = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'radar.followThrough.'")).firstMatch
        XCTAssertTrue(film.wait(for: app.descendants(matching: .any)["radar.items"], timeout: 20),
                      "the meeting page has no Live Radar section")
        UITestHarness.scrollTo(followThrough, in: app)
        if film.wait(for: followThrough, timeout: 10) {
            film.hold(2.5)
            followThrough.click()
        } else {
            // A live run may not attribute the commitment to the user; the
            // saved action's menu offers the same Follow-through.
            XCTAssertTrue(isLive, "no Follow Through button on the commitment")
            let menu = app.descendants(matching: .any)["meeting.action.status.film-action-0"]
            UITestHarness.scrollTo(menu, in: app, upward: true)
            XCTAssertTrue(film.wait(for: menu, timeout: 10), "no action menu to follow through from")
            menu.click()
            let item = app.menuItems["Follow Through with Muse…"]
            XCTAssertTrue(film.wait(for: item, timeout: 5))
            item.click()
        }

        // Approve every step Muse proposes, until it finishes.
        let approve = app.buttons.matching(NSPredicate(format: "identifier == 'followThrough.approve' AND isEnabled == true")).firstMatch
        let done = app.descendants(matching: .any)["followThrough.done"]
        let failure = app.descendants(matching: .any)["followThrough.error"]
        var approved: [String] = []
        for _ in 0..<5 {
            let deadline = Date().addingTimeInterval(isLive ? 120 : 30)
            while !approve.exists, !done.exists, !failure.exists, Date() < deadline { film.hold(0.4) }
            if done.exists || failure.exists || !approve.exists { break }
            film.hold(3)
            approved.append(approve.label)
            approve.click()
            film.hold(1.5)
        }
        XCTAssertFalse(failure.exists, "Follow-through failed: \(failure.exists ? failure.label : "")")
        XCTAssertTrue(film.wait(for: done, timeout: 10), "Follow-through did not finish")
        XCTAssertFalse(approved.isEmpty, "Follow-through proposed nothing")
        if !isLive {
            XCTAssertEqual(approved, ["Open in Mail", "Open in Calendar"])
            XCTAssertTrue(UITestHarness.staticText(containing: "Drafted the deck email to Marko", in: app).exists)
        }
        film.hold(4)
    }
}

/// Screen frames with their display durations, for ffmpeg's concat demuxer.
/// Frames are downscaled JPEGs so a two-minute take stays small.
private final class Film {
    private let folder: URL
    private var frames: [(name: String, at: Date)] = []
    private var attached = 0

    init() throws {
        let path = ProcessInfo.processInfo.environment["LOKALBOT_FILM_FRAMES"]
        folder = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("LokalBotFilm-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func snap() {
        let image = XCUIScreen.main.screenshot().image
        let width: CGFloat = 1_440
        let scale = min(1, width / max(image.size.width, 1))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        let name = String(format: "%05d.jpg", frames.count)
        try? data.write(to: folder.appendingPathComponent(name))
        frames.append((name, Date()))
    }

    /// Films while waiting, about twice a second.
    func wait(for element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            snap()
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 0.35)
        } while Date() < deadline
        snap()
        return element.exists
    }

    func hold(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            snap()
            Thread.sleep(forTimeInterval: 0.35)
        } while Date() < deadline
    }

    func finish(in test: XCTestCase) {
        snap()
        var list = ""
        for (index, frame) in frames.enumerated() {
            let next = index + 1 < frames.count ? frames[index + 1].at : frame.at.addingTimeInterval(1)
            list += "file '\(frame.name)'\nduration \(String(format: "%.3f", max(0.04, next.timeIntervalSince(frame.at))))\n"
        }
        if let last = frames.last { list += "file '\(last.name)'\n" }
        try? list.write(to: folder.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        // A few stills travel with the result bundle even without the film.
        for index in stride(from: 0, to: frames.count, by: max(1, frames.count / 6)) {
            guard let image = NSImage(contentsOf: folder.appendingPathComponent(frames[index].name)) else { continue }
            let attachment = XCTAttachment(image: image)
            attachment.name = "film-\(frames[index].name)"
            attachment.lifetime = .keepAlways
            test.add(attachment)
        }
    }
}

/// An earlier planning meeting the radar can contradict, and the meeting that
/// is filmed live and then followed through.
private enum FilmFixture {
    static let settingsJSON = """
    {
      "menuBarOnly": false,
      "trackingEnabled": true,
      "screenshotsEnabled": false,
      "calendarDetectionEnabled": false,
      "semanticSearchEnabled": false,
      "cotypingEnabled": false,
      "cotypingUserName": "Jordan Lee",
      "museLiveTextEnabled": true,
      "museScreenAnswersEnabled": true,
      "approvedRemoteInferenceOrigins": ["https://api.meta.ai"]
    }
    """

    static let live: [(TimeInterval, String, String)] = [
        (2, "them", "Hi! Okay, launch checklist. The pricing page is almost done, I just need the final numbers."),
        (7, "local", "I'll send the revised pricing deck to Marko by Friday."),
        (12, "them", "Great. What was our trial-to-paid conversion last month, by the way?"),
        (17, "local", "Let me think, I saw it on the dashboard."),
        (23, "them", "Also, the launch is Friday the seventh now, right? Marketing told me Friday."),
        (28, "local", "Hm, I thought it was the Monday. Let me check."),
        (33, "them", "And sales wants the free tier limited to one project."),
        (38, "local", "Okay, let's decide that with Ana tomorrow."),
        (43, "them", "Marko will review the onboarding emails before Wednesday."),
        (48, "local", "Perfect. Let's go with twenty percent off for annual plans."),
        (53, "them", "Agreed, twenty percent. Talk tomorrow!"),
    ]

    /// The radar replay's synthetic captures: a metrics dashboard and a
    /// launch plan, read from the checkout the tests were built from.
    static func screens(file: StaticString = #filePath) throws -> URL {
        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/MuseRadar/fixtures/screens", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("screens.json").path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
        }
        return folder
    }

    static func liveScript(in library: URL) throws -> URL {
        let url = library.appendingPathComponent("live-script.json")
        let rows = live.map { ["time": $0.0, "speaker": $0.1, "text": $0.2] as [String: Any] }
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
        return url
    }

    static func plant(in root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        let calendar = Calendar.current
        let today = calendar.date(byAdding: .hour, value: 11, to: calendar.startOfDay(for: Date())) ?? Date()
        let planning = today.addingTimeInterval(-8 * 86_400)
        try write(id: "44444444-4444-4444-8444-444444444444", title: "Launch planning", start: planning, minutes: 20,
                  slug: "launch-planning", root: root,
                  transcript: [
                      (0, "them", "So we agreed: the launch is Monday, November 3rd, and the pricing page ships the Friday before."),
                      (14, "me", "And the free tier keeps three projects, that's settled."),
                      (26, "them", "Marko can review the onboarding emails once the copy is final."),
                  ],
                  summary: "## TL;DR\nThe launch is Monday, November 3rd; the pricing page ships the Friday before. "
                      + "The free tier keeps three projects.",
                  decisions: ["The launch is Monday, November 3rd; the pricing page ships the Friday before",
                              "The free tier keeps three projects"],
                  actions: [])
        try write(id: "55555555-5555-4555-8555-555555555555", title: "Launch sync", start: today, minutes: 15,
                  slug: "launch-sync", root: root,
                  transcript: live.map { ($0.0, $0.1 == "local" ? "me" : "them", $0.2) },
                  summary: "## TL;DR\nLaunch checklist. Annual plans get twenty percent off. The launch date and the "
                      + "free tier limit are open until a talk with Ana tomorrow.",
                  decisions: ["Annual plans get twenty percent off"],
                  actions: [("Send the revised pricing deck to Marko", "Me", "by Friday", 1)],
                  participants: [("Marko Ilić", "marko@example.com"), ("Ana Petrović", "ana@example.com")])
    }

    // swiftlint:disable:next function_parameter_count
    private static func write(id: String, title: String, start: Date, minutes: Double, slug: String, root: URL,
                              transcript: [(TimeInterval, String, String)], summary: String, decisions: [String],
                              actions: [(String, String, String, Int)],
                              participants: [(String, String)] = []) throws {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: start)
        let relative = String(format: "meetings/%04d/%02d/%02d-%@", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, slug)
        let folder = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        var meta: [String: Any] = [
            "id": id, "title": title, "appName": "Google Meet", "relativePath": relative, "hasSystemTrack": true,
            "startedAt": iso.string(from: start), "endedAt": iso.string(from: start.addingTimeInterval(minutes * 60)),
        ]
        if !participants.isEmpty {
            meta["participantNameHints"] = participants.map(\.0)
            meta["calendarParticipantIdentities"] = participants.enumerated().map {
                ["id": "film-\($0.offset)", "name": $0.element.0, "emailAddress": $0.element.1]
            }
        }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("meta.json"))
        let segments = transcript.map { ["start": $0.0, "end": $0.0 + 4.5, "speaker": $0.1, "text": $0.2] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["engine": "synthetic-fixture", "segments": segments])
            .write(to: folder.appendingPathComponent("transcript.json"))
        try transcript.map { "**[\(stamp($0.0))] \($0.1.capitalized):** \($0.2)" }.joined(separator: "\n\n")
            .write(to: folder.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
        try summary.write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        func citation(_ index: Int) -> [String: Any] {
            let segment = transcript[index]
            return ["meetingID": id,
                    "segmentID": String(format: "segment-%04d-%010lld-%010lld", index,
                                        Int64(segment.0 * 1_000), Int64((segment.0 + 4.5) * 1_000)),
                    "start": segment.0, "end": segment.0 + 4.5, "speaker": segment.1 == "me" ? "me" : "them",
                    "excerpt": segment.2]
        }
        let outcomes: [String: Any] = [
            "schemaVersion": 2,
            "actionItems": actions.enumerated().map { index, action in
                ["id": "film-action-\(index)", "schemaVersion": 2, "text": action.0, "owner": action.1,
                 "isForUser": action.1 == "Me", "due": action.2, "citations": [citation(action.3)]] as [String: Any]
            },
            "decisionRecords": decisions.enumerated().map { index, text in
                ["id": "film-decision-\(index)", "schemaVersion": 2, "text": text,
                 "citations": [citation(min(index, transcript.count - 1))]] as [String: Any]
            },
            "openQuestions": [String](),
        ]
        try JSONSerialization.data(withJSONObject: outcomes, options: [.prettyPrinted])
            .write(to: folder.appendingPathComponent("outcomes.json"))
        for track in ["mic.live.caf", "system.live.caf"] {
            try silence(to: folder.appendingPathComponent(track))
        }
    }

    private static func silence(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000 * 30) else { return }
        buffer.frameLength = buffer.frameCapacity
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
    }

    private static func stamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
    }
}
