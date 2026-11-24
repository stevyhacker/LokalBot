import CryptoKit
import XCTest
@testable import LokalBot

@MainActor
final class CaptureReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureReplayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        CaptureEnvironment.reset()
        try? FileManager.default.removeItem(at: root)
    }

    private func replay(_ name: String) throws -> ReplayCaptureEnvironment {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/capture-traces"))
        let replay = ReplayCaptureEnvironment(trace: try CaptureTrace.load(from: url),
                                              start: Date(timeIntervalSince1970: 1_790_000_000))
        CaptureEnvironment.install(replay.environment)
        MeetingDetector.invalidateAudioProcessSnapshot()
        MeetingDetector.resetCaptureTargetMemory()
        return replay
    }

    private func store() -> ActivityStore {
        ActivityStore(databaseURL: DiagnosticsPaths.database(root: root))
    }

    func testChromeTextIsCapturedAfterATransientRead() async throws {
        let replay = try replay("chrome-focus-after-tree-read")
        let store = store()
        var settings = AppSettings()
        settings.trackingEnabled = true
        settings.screenContextCaptureMode = .accessibleText
        settings.screenshotsEnabled = false
        let service = ScreenshotService(
            store: store, storage: StorageManager(), sampler: ActivitySampler(store: store),
            now: { replay.clock.now() }, settings: { settings })
        await service.captureIfAppropriate(trigger: .appSwitch)
        let captures = store.screenshots(in: nil, includingMissingFiles: true)
        XCTAssertTrue(captures.contains { $0.app == "Google Chrome" },
                      "the transient read must be retried and the text stored")
    }

    func testCapturesGoOnWhenTextRecognitionNeverAnswers() async throws {
        let replay = try replay("window-with-little-accessible-text")
        let store = store()
        var settings = AppSettings()
        settings.trackingEnabled = true
        settings.screenContextCaptureMode = .visualContext
        let unanswered = DispatchSemaphore(value: 0)
        defer { unanswered.signal() }
        let live = ScreenshotProcessingDependencies.live
        let worker = ScreenshotProcessingWorker(
            dependencies: ScreenshotProcessingDependencies(
                contentHash: live.contentHash, heicData: live.heicData,
                recognizeText: { _ in
                    unanswered.wait()
                    return "read too late"
                },
                write: live.write),
            textRecognition: TextRecognitionQueue(stallLimit: 60),
            textRecognitionLimit: 0.1)
        let key = SymmetricKey(size: .bits256)
        let service = ScreenshotService(
            store: store, storage: StorageManager(rootURL: root), sampler: ActivitySampler(store: store),
            now: { replay.clock.now() }, processingWorker: worker, captureKey: { key }, settings: { settings })

        let finished = expectation(description: "both captures finished")
        Task {
            await service.captureIfAppropriate(trigger: .manual)
            await service.captureIfAppropriate(trigger: .manual)
            finished.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [finished], timeout: 20) == .completed else {
            return XCTFail("a capture is still waiting for text recognition, and holds every capture after it")
        }
        let captures = store.screenshots(in: nil, includingMissingFiles: true).filter { $0.app == "Notes" }
        XCTAssertEqual(captures.count, 2, "both captures are stored, with the text Accessibility read")
        XCTAssertFalse(captures.contains(where: \.hasPixels),
                       "pixels whose text nothing read are unchecked for credentials and are not kept")
    }

    func testCapturedTextIsEmbeddedWithoutASearchAfterAFailedPass() async throws {
        let replay = try replay("chrome-focus-after-tree-read")
        let databaseURL = DiagnosticsPaths.database(root: root)
        let store = ActivityStore(databaseURL: databaseURL)
        var failuresLeft = 1
        var passes = 0
        let index = EmbeddingIndex(
            databaseURL: databaseURL, storage: StorageManager(rootURL: root),
            embedder: { texts, _, _ in
                passes += 1
                if failuresLeft > 0 {
                    failuresLeft -= 1
                    throw LlamaServer.ServerError.failedToStart("port 17873 is already in use")
                }
                return texts.map { _ in [1, 0] }
            },
            screenBackfillSchedule: .init(newTextDelay: .milliseconds(20),
                                          firstRetryDelay: .milliseconds(20),
                                          maximumRetryDelay: .milliseconds(80)))
        let earlier = try store.insertScreenshot(
            ts: Date(timeIntervalSince1970: 1_789_000_000), path: "", app: "Notes",
            windowTitle: "Earlier", ocr: "Earlier screen")
        let database = try XCTUnwrap(SQLiteDatabase(url: databaseURL))
        XCTAssertTrue(database.run("""
            INSERT INTO screen_embeddings (snapshot_id, ts, app, text, vec, model_id)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            """, bind: [earlier, 1_789_000_000.0, "Notes", "Earlier screen",
                         [Float(1), 0].withUnsafeBufferPointer { Data(buffer: $0) },
                         EmbeddingIndex.indexVersion]))

        var settings = AppSettings()
        settings.trackingEnabled = true
        settings.screenContextCaptureMode = .accessibleText
        settings.screenshotsEnabled = false
        let service = ScreenshotService(
            store: store, storage: StorageManager(), sampler: ActivitySampler(store: store),
            now: { replay.clock.now() }, settings: { settings })
        service.onTextStored = { index.screenTextDidArrive() }
        await service.captureIfAppropriate(trigger: .appSwitch)
        let chrome = try XCTUnwrap(store.screenshots(in: nil, includingMissingFiles: true)
            .first { $0.app == "Google Chrome" })

        let deadline = Date().addingTimeInterval(5)
        while !database.hasRow("SELECT 1 FROM screen_embeddings WHERE snapshot_id = ?1",
                               bind: [chrome.id]) {
            guard Date() < deadline else {
                return XCTFail("the captured text never reached semantic search (\(passes) passes)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(passes, 2, "one failed pass, then its retry")
    }

    private func captureFramedPage(excludingDomains domains: String) async throws -> [ActivityStore.Screenshot] {
        let replay = try replay("chrome-page-with-framed-site")
        let store = store()
        var settings = AppSettings()
        settings.trackingEnabled = true
        settings.screenContextCaptureMode = .accessibleText
        settings.screenshotsEnabled = false
        settings.excludedScreenDomains = domains
        let service = ScreenshotService(
            store: store, storage: StorageManager(), sampler: ActivitySampler(store: store),
            now: { replay.clock.now() }, settings: { settings })
        await service.captureIfAppropriate(trigger: .appSwitch)
        return store.screenshots(in: nil, includingMissingFiles: true).filter { $0.app == "Google Chrome" }
    }

    func testFramedPageKeepsItsAddress() async throws {
        let captures = try await captureFramedPage(excludingDomains: "thr.xmpl")
        XCTAssertEqual(captures.first?.sourceURL, "https://dcs.xmpl/d/kd")
    }

    func testFramedExcludedSiteKeepsTheWindowOut() async throws {
        let captures = try await captureFramedPage(excludingDomains: "wdgts.xmpl")
        XCTAssertTrue(captures.isEmpty, "the framed site's text would be stored with the page")
    }

    func testBrowserTimeKeepsItsAppName() async throws {
        let replay = try replay("browser-web-content-without-url")
        let store = store()
        let sampler = ActivitySampler(store: store)
        await sampler.sample()
        await replay.clock.advance(by: 12)
        await sampler.sample()
        sampler.stop()
        let blocks = store.blocks(in: DateInterval(start: replay.clock.now().addingTimeInterval(-3_600),
                                                   duration: 7_200))
        XCTAssertEqual(blocks.first?.app, "Google Chrome")
        XCTAssertFalse(blocks.contains { $0.app == "Private" })
    }

    func testMeetCallSurvivesUnreadableControlsUntilItEnds() async throws {
        let replay = try replay("meet-controls-unreadable-tab-open")
        let detector = MeetingDetector()
        var started: [TimeInterval] = []
        var ended: [TimeInterval] = []
        detector.onMeetingStarted = { _ in started.append(replay.clock.elapsed) }
        detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
        for second in stride(from: 0.0, through: 720, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
        }
        XCTAssertEqual(started.count, 1, "one meeting starts")
        XCTAssertLessThan(started.first ?? .infinity, 30)
        XCTAssertEqual(ended.count, 1, "the meeting ends once")
        XCTAssertGreaterThanOrEqual(ended.first ?? 0, 630, "must not end while the tab stays open")
        XCTAssertLessThan(ended.first ?? .infinity, 720)
    }

    func testMeetCallUnderMeetPathStartsAndEnds() async throws {
        let replay = try replay("meet-room-under-meet-path")
        let detector = MeetingDetector()
        var started: [(TimeInterval, MeetingDetector.DetectedApp?)] = []
        var ended: [TimeInterval] = []
        detector.onMeetingStarted = { started.append((replay.clock.elapsed, $0.detectedApp)) }
        detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
        for second in stride(from: 0.0, through: 360, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
        }
        XCTAssertEqual(started.count, 1, "one meeting starts")
        XCTAssertLessThan(started.first?.0 ?? .infinity, 30)
        XCTAssertEqual(started.first?.1?.bundleID, "com.brave.Browser")
        XCTAssertEqual(started.first?.1?.meetingURL?.absoluteString, "https://meet.google.com/bcd-fghj-klm")
        XCTAssertEqual(ended.count, 1, "the meeting ends once")
        XCTAssertGreaterThanOrEqual(ended.first ?? 0, 300, "must not end before the call does")
    }

    func testTelemostAndMTSLinkCallsAttachSystemAudioAndEndAfterLeaving() async throws {
        for (trace, room, bundleID) in [
            ("telemost-browser-call", "https://telemost.yandex.ru/j/12345678901", "com.google.Chrome"),
            ("mts-link-browser-call", "https://my.mts-link.ru/j/1234/5678", "com.google.Chrome"),
            ("mts-link-desktop-call", "https://my.mts-link.ru/j/1234/5678", "ru.weteams.desktop"),
        ] {
            let replay = try replay(trace)
            let detector = MeetingDetector()
            var started: [(TimeInterval, MeetingDetector.DetectedApp?)] = []
            var ended: [TimeInterval] = []
            detector.onMeetingStarted = { started.append((replay.clock.elapsed, $0.detectedApp)) }
            detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
            let intent = Meeting.CaptureIntent(systemAudioRequested: true)
            XCTAssertNil(RecordingSystemAudioSource.find(for: intent), "\(trace) preview or idle client")
            for second in stride(from: 0.0, through: 24, by: 2) {
                await replay.clock.advance(to: second)
                await detector.tickForTesting()
            }
            let call = try XCTUnwrap(started.first?.1, trace)
            XCTAssertEqual(started.count, 1, trace)
            XCTAssertEqual(started.first?.0, 12, trace)
            XCTAssertEqual(call.bundleID, bundleID, trace)
            XCTAssertEqual(call.meetingURL?.absoluteString, room, trace)
            XCTAssertEqual(RecordingSystemAudioSource.find(for: intent), .verified(call), trace)
            XCTAssertEqual(MeetingDetector.currentCaptureTargetProcess(for: call)?.id, 802, trace)
            for second in stride(from: 26.0, through: 170, by: 2) {
                await replay.clock.advance(to: second)
                await detector.tickForTesting()
            }
            XCTAssertEqual(ended, [150], trace)
            XCTAssertEqual(started.count, 1, "remaining app audio cannot restart \(trace)")
            XCTAssertNil(RecordingSystemAudioSource.find(for: intent), trace)
        }
    }

    func testMicrophoneBasedDetectsNativeAndOptedInBrowserCalls() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for (bundle, additional, browserEnabled, starts) in [
            ("ru.unlimitedtech.express.desktop", "", false, true),
            ("com.example.CorporateClient", "com.example.CorporateClient", false, true),
            ("com.example.CorporateClient", "", false, false),
            ("com.google.Chrome", "", true, true),
            ("com.google.Chrome", "", false, false),
        ] {
            let trace = CaptureTrace(header: .init(schemaVersion: 1, macOSVersion: "Test",
                origin: .scripted, scenario: "microphone-based-call", recordedAt: start), events: [
                    .init(t: 0, query: .runningApps, apps: [
                        .init(processIdentifier: 801, bundleIdentifier: bundle, localizedName: "Call app")
                    ]),
                    .init(t: 0, query: .audioProcesses, processes: [
                        .init(id: 802, name: "Call helper", bundleID: bundle + ".helper",
                              objectID: 90, isRunningOutput: true)
                    ]),
                    .init(t: 0, query: .browserMicrophoneWindowsAllowed, processID: 801, flag: true),
                    .init(t: 30, query: .inputRunning, processID: 802, flag: true),
                    .init(t: 70, query: .inputRunning, processID: 802, flag: false)
                ])
            let replay = ReplayCaptureEnvironment(trace: trace, start: start)
            CaptureEnvironment.install(replay.environment)
            MeetingDetector.invalidateAudioProcessSnapshot()
            MeetingDetector.resetCaptureTargetMemory()
            let detector = MeetingDetector()
            detector.additionalCallBundleIDs = Set(AdditionalCallApp.fromLegacyList(additional).map(\.id))
            detector.detectOtherBrowserCalls = browserEnabled
            var began: [TimeInterval] = []
            var ended: [TimeInterval] = []
            detector.onMeetingStarted = {
                XCTAssertEqual($0.detectedApp?.bundleID, bundle)
                began.append(replay.clock.elapsed)
            }
            detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
            for time in stride(from: 0.0, through: 96, by: 2) {
                await replay.clock.advance(to: time)
                await detector.tickForTesting()
            }
            XCTAssertEqual(began, starts ? [42] : [], bundle)
            XCTAssertEqual(ended, starts ? [85] : [], bundle)
        }
    }

    func testBrowserMicrophoneDetectionReplaysPrivateAndUnreadableWindowChecks() async throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for (midCall, expectedEnd) in [
            (BrowserMeetingSession.MicrophoneWindows.privateWindow, [TimeInterval(105)]),
            (.unreadable, []),
        ] {
            let trace = CaptureTrace(header: .init(schemaVersion: 1, macOSVersion: "Test",
                origin: .scripted, scenario: "microphone-window-privacy", recordedAt: start), events: [
                    .init(t: 0, query: .runningApps, apps: [
                        .init(processIdentifier: 801, bundleIdentifier: "com.google.Chrome",
                              localizedName: "Google Chrome")
                    ]),
                    .init(t: 0, query: .audioProcesses, processes: [
                        .init(id: 802, name: "Google Chrome Helper", bundleID: "com.google.Chrome.helper",
                              objectID: 90, isRunningOutput: true)
                    ]),
                    .init(t: 0, query: .inputRunning, processID: 802, flag: true),
                    .init(t: 0, query: .browserMicrophoneWindowsAllowed, processID: 801, flag: false,
                          microphoneWindows: .privateWindow),
                    .init(t: 30, query: .browserMicrophoneWindowsAllowed, processID: 801, flag: false,
                          microphoneWindows: .unreadable),
                    .init(t: 60, query: .browserMicrophoneWindowsAllowed, processID: 801, flag: true,
                          microphoneWindows: .allowed),
                    .init(t: 90, query: .browserMicrophoneWindowsAllowed, processID: 801, flag: false,
                          microphoneWindows: midCall)
                ])
            let replay = ReplayCaptureEnvironment(trace: trace, start: start)
            CaptureEnvironment.install(replay.environment)
            MeetingDetector.invalidateAudioProcessSnapshot()
            MeetingDetector.resetCaptureTargetMemory()
            let detector = MeetingDetector()
            detector.detectOtherBrowserCalls = true
            var began: [TimeInterval] = []
            var ended: [TimeInterval] = []
            detector.onMeetingStarted = { _ in began.append(replay.clock.elapsed) }
            detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
            for time in stride(from: 0.0, through: 116, by: 2) {
                await replay.clock.advance(to: time)
                await detector.tickForTesting()
            }
            XCTAssertEqual(began, [72], "private and unreadable windows cannot authorize a start")
            XCTAssertEqual(ended, expectedEnd, "\(midCall) window during the call")
        }
    }

    func testNativeTelemostIgnoresShortAudioAndStopsOnceItsCallAudioEnds() async throws {
        let replay = try replay("telemost-desktop-call")
        let detector = MeetingDetector()
        var started: [(TimeInterval, MeetingDetector.DetectedApp?)] = []
        var ended: [TimeInterval] = []
        detector.onMeetingStarted = { started.append((replay.clock.elapsed, $0.detectedApp)) }
        detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
        for second in stride(from: 0.0, through: 50, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
        }
        let call = try XCTUnwrap(started.first?.1)
        XCTAssertEqual(started.count, 1)
        XCTAssertGreaterThanOrEqual(started.first?.0 ?? 0, 20 + MeetingDetector.nativeAudioMinimumConfirmationDuration)
        XCTAssertEqual(call.bundleID, "ru.yandex.desktop.telemost")
        XCTAssertEqual(RecordingSystemAudioSource.find(for: .init(systemAudioRequested: true)), .verified(call))
        for second in stride(from: 52.0, through: 120, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
        }
        XCTAssertEqual(ended.count, 1)
        XCTAssertGreaterThanOrEqual(ended.first ?? 0, 72)
    }

    func testCallInAnotherRoomReplacesAnUnverifiedCall() async throws {
        let replay = try replay("meet-room-change-after-unrecognized-end")
        let detector = MeetingDetector()
        detector.calendar = ReplayCalendar(candidates: [
            meeting("first", from: -77, to: 1_723, room: "bcd-fghj-klm", replay: replay),
            meeting("weekly", from: 1_723, to: 5_323, room: "npq-rstv-wxz", replay: replay),
        ])
        detector.calendarEnabled = true
        var started: [(at: TimeInterval, context: MeetingDetectionContext)] = []
        var ended: [TimeInterval] = []
        var verified: [TimeInterval: Bool] = [:]
        detector.onMeetingStarted = { started.append((replay.clock.elapsed, $0)) }
        detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
        for second in stride(from: 0.0, through: 1_830, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
            verified[second] = detector.verifiesActiveCall
        }
        XCTAssertEqual(started.count, 2, "the first call, then the call in the other room")
        XCTAssertLessThan(started.first?.at ?? .infinity, 10)
        XCTAssertEqual(ended.count, 1, "the stale session ends once")
        XCTAssertGreaterThanOrEqual(ended.first ?? 0, 1_807, "an unrecognized page alone never ends a call")
        XCTAssertLessThan(ended.first ?? .infinity, 1_815)
        let replacement = try XCTUnwrap(started.last)
        XCTAssertGreaterThanOrEqual(replacement.at, ended.first ?? .infinity)
        XCTAssertEqual(replacement.context.detectedApp?.meetingURL?.absoluteString,
                       "https://meet.google.com/npq-rstv-wxz")
        XCTAssertEqual(replacement.context.calendarEvent?.externalID, "weekly")
        XCTAssertEqual(verified[1_680], true)
        XCTAssertEqual(verified[1_700], false, "a manual start must not join the unverified call")
        XCTAssertEqual(verified[1_830], true)
    }

    func testManualStartDoesNotJoinAnUnverifiedCall() async throws {
        let replay = try replay("meet-room-change-after-unrecognized-end")
        let app = AppState()
        for second in stride(from: 0.0, through: 1_700, by: 2) {
            await replay.clock.advance(to: second)
            await app.detector.tickForTesting()
            guard second == 100 else { continue }
            let verified = try XCTUnwrap(app.recordingContext(for: app.detector.activeApp))
            XCTAssertEqual(verified.detectedApp?.meetingURL?.absoluteString, "https://meet.google.com/bcd-fghj-klm")
            if app.settings.autoRecordMode != .manual {
                XCTAssertEqual(verified.detectorSessionID, app.detector.activeSessionID)
            }
        }
        let context = try XCTUnwrap(app.recordingContext(for: app.detector.activeApp))
        XCTAssertNotNil(app.detector.activeSessionID, "the first call is still bound")
        XCTAssertNil(context.detectorSessionID)
        XCTAssertNil(context.detectedApp?.meetingURL)
        XCTAssertEqual(context.detectedApp?.bundleID, "com.google.Chrome", "the browser's audio is still captured")
    }

    func testNextEventInTheSameRoomSplitsTheCall() async throws {
        for (nextRoom, splits) in [("bcd-fghj-klm", true), ("npq-rstv-wxz", false)] {
            let replay = try replay("meet-same-room-back-to-back")
            let detector = MeetingDetector()
            detector.calendar = ReplayCalendar(candidates: [
                meeting("first", from: -77, to: 1_723, room: "bcd-fghj-klm", replay: replay),
                meeting("second", from: 1_723, to: 5_323, room: nextRoom, replay: replay),
            ])
            detector.calendarEnabled = true
            var sessions: [UUID?] = []
            var switched: [(at: TimeInterval, context: MeetingDetectionContext)] = []
            detector.onMeetingStarted = { sessions.append($0.detectorSessionID) }
            detector.onMeetingSwitched = { switched.append((replay.clock.elapsed, $0)) }
            detector.onMeetingEnded = { _ in XCTFail("the call never ends") }
            for second in stride(from: 0.0, through: 1_800, by: 2) {
                await replay.clock.advance(to: second)
                await detector.tickForTesting()
            }
            XCTAssertEqual(sessions.count, 1, nextRoom)
            guard splits else {
                XCTAssertTrue(switched.isEmpty, "an event in another room does not split the call")
                continue
            }
            XCTAssertEqual(switched.count, 1)
            XCTAssertEqual(switched.first?.context.reason, "calendar-handoff")
            XCTAssertEqual(switched.first?.context.calendarEvent?.externalID, "second")
            XCTAssertEqual(switched.first?.context.detectorSessionID, sessions.first ?? nil)
            XCTAssertGreaterThanOrEqual(switched.first?.at ?? 0, 1_723)
            XCTAssertLessThan(switched.first?.at ?? .infinity, 1_727)
            CaptureEnvironment.reset()
        }
    }

    private func meeting(_ id: String, from start: TimeInterval, to end: TimeInterval, room: String,
                         replay: ReplayCaptureEnvironment) -> CalendarMeetingCandidate {
        let origin = replay.clock.now().addingTimeInterval(-replay.clock.elapsed)
        return CalendarMeetingCandidate(
            provider: "eventkit", externalID: id, title: id,
            startDate: origin.addingTimeInterval(start), endDate: origin.addingTimeInterval(end),
            meetingURL: URL(string: "https://meet.google.com/\(room)?authuser=1"), sourceCalendarTitle: nil)
    }

    private final class ReplayCalendar: CalendarEventProviding {
        let authorizationStatus = CalendarAuthorizationStatus.fullAccess
        let candidates: [CalendarMeetingCandidate]
        init(candidates: [CalendarMeetingCandidate]) { self.candidates = candidates }
        func requestAccess(_ completion: @escaping (Bool) -> Void) { completion(true) }
        func meetingCandidates(now: Date) -> [CalendarMeetingCandidate] { candidates }
    }

    func testTeamsLaunchBlipDoesNotStartAMeetingButTheCallDoes() async throws {
        let replay = try replay("teams-launch-blip-then-call")
        let detector = MeetingDetector()
        var started: [TimeInterval] = []
        detector.onMeetingStarted = { _ in started.append(replay.clock.elapsed) }
        for second in stride(from: 0.0, through: 200, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
        }
        XCTAssertEqual(started.count, 1)
        XCTAssertGreaterThanOrEqual(started.first ?? 0,
                                    60 + MeetingDetector.nativeAudioMinimumConfirmationDuration - 2)
    }

    private let teams = MeetingDetector.DetectedApp(name: "Teams", bundleID: "com.microsoft.teams2", pid: 700)

    func testManualRecordingHoldsTheTeamsCallOnModuleHost() throws {
        _ = try replay("teams-call-only-on-modulehost")
        XCTAssertNil(MeetingDetector.captureCandidateApp(), "modulehost is not evidence of a call")
        let unbound = Meeting.CaptureIntent(systemAudioRequested: true)
        XCTAssertEqual(RecordingSystemAudioSource.find(for: unbound), .held(teams))
        XCTAssertEqual(MeetingDetector.currentCaptureTargetProcess(for: teams)?.id, 720, "the tap goes on modulehost")
    }

    func testAHeldTeamsStreamGivesWayToTheMeetCall() async throws {
        let replay = try replay("teams-idle-while-meet-call-unreadable")
        let room = try XCTUnwrap(URL(string: "https://meet.google.com/bcd-fghj-klm"))
        let unbound = Meeting.CaptureIntent(systemAudioRequested: true)
        XCTAssertEqual(RecordingSystemAudioSource.find(for: unbound), .held(teams))
        XCTAssertNil(RecordingSystemAudioSource.find(for: .init(systemAudioRequested: true, meetingURL: room)))

        await replay.clock.advance(to: 40)
        let call = MeetingDetector.DetectedApp(name: "Google Chrome", bundleID: "com.google.Chrome",
                                               pid: 801, meetingURL: room)
        XCTAssertEqual(RecordingSystemAudioSource.find(for: unbound), .verified(call))
    }

    func testTencentMeetingCallStartsWithoutTheChatAppWait() async throws {
        let replay = try replay("tencent-meeting-call")
        let detector = MeetingDetector()
        var started: [(at: TimeInterval, bundleID: String?)] = []
        detector.onMeetingStarted = { context in
            started.append((replay.clock.elapsed, context.detectedApp?.bundleID))
        }
        for second in stride(from: 0.0, through: 260, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
        }
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.bundleID, "com.tencent.meeting")
        XCTAssertLessThan(started.first?.at ?? .infinity,
                          30 + MeetingDetector.nativeAudioMinimumConfirmationDuration,
                          "a dedicated conferencing app does not wait out the chat-app gate")
    }

    func testManualRecordingCapturesAFeishuCallOnItsHelper() throws {
        _ = try replay("feishu-call-on-helper")
        let feishu = MeetingDetector.DetectedApp(name: "Feishu", bundleID: "com.electron.lark", pid: 900)
        let unbound = Meeting.CaptureIntent(systemAudioRequested: true)
        XCTAssertEqual(RecordingSystemAudioSource.find(for: unbound), .verified(feishu))
        XCTAssertEqual(MeetingDetector.currentCaptureTargetProcess(for: feishu)?.id, 910,
                       "the tap goes on the helper that carries the call")
    }

    func testManualRecordingCapturesAWebexCallOnItsMediaHelper() async throws {
        let replay = try replay("webex-call-on-media-helper")
        await replay.clock.advance(to: 10)
        let webex = MeetingDetector.DetectedApp(name: "Webex", bundleID: "Cisco-Systems.Spark", pid: 900)
        let unbound = Meeting.CaptureIntent(systemAudioRequested: true)
        XCTAssertEqual(RecordingSystemAudioSource.find(for: unbound), .verified(webex))
        XCTAssertEqual(MeetingDetector.currentCaptureTargetProcess(for: webex)?.id, 910,
                       "the silent host must not take the remote participants' track")
    }

    func testWebexCaptureFollowsItsMediaHelperAcrossSilenceAndRestart() async throws {
        let replay = try replay("webex-call-on-media-helper")
        let webex = MeetingDetector.DetectedApp(name: "Webex", bundleID: "Cisco-Systems.Spark", pid: 900)
        let bound = Meeting.CaptureIntent(systemAudioRequested: true, appBundleID: webex.bundleID)
        for (second, pid) in [(0.0, pid_t(910)), (10, 910), (20, 910), (30, 920), (40, 920)] {
            await replay.clock.advance(to: second)
            XCTAssertEqual(RecordingSystemAudioSource.find(for: bound), .verified(webex))
            XCTAssertEqual(MeetingDetector.currentCaptureTargetProcess(
                for: webex, excluding: second >= 30 ? [910] : [])?.id, pid,
                "capture must follow the media helper at t=\(second), even before it emits audio")
        }
    }

    func testWebexCallOnItsMediaHelperStartsDetectionOnlyWhenAudioRuns() async throws {
        let replay = try replay("webex-call-on-media-helper")
        let detector = MeetingDetector()
        var started: [MeetingDetector.DetectedApp] = []
        detector.onMeetingStarted = { context in
            if let app = context.detectedApp { started.append(app) }
        }
        await detector.tickForTesting()
        XCTAssertTrue(started.isEmpty, "a present but quiet helper is not evidence of a call")
        await replay.clock.advance(to: 10)
        await detector.tickForTesting()
        XCTAssertEqual(started, [.init(name: "Webex", bundleID: "Cisco-Systems.Spark", pid: 900)])
    }

    func testScriptedBrowserTracesReplayToACapture() async throws {
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "capture-traces", withExtension: nil, subdirectory: "Fixtures"))
        let scripted = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("scripted-") }
        guard !scripted.isEmpty else { throw XCTSkip("no scripted traces recorded yet") }
        for url in scripted {
            let replay = ReplayCaptureEnvironment(trace: try CaptureTrace.load(from: url), start: Date())
            CaptureEnvironment.install(replay.environment)
            let store = ActivityStore(databaseURL: root.appendingPathComponent("\(UUID()).sqlite"))
            var settings = AppSettings()
            settings.trackingEnabled = true
            settings.screenContextCaptureMode = .accessibleText
            let service = ScreenshotService(store: store, storage: StorageManager(),
                                            sampler: ActivitySampler(store: store),
                                            now: { replay.clock.now() }, settings: { settings })
            for second in stride(from: 5.0, through: replay.trace.events.last?.t ?? 5, by: 5) {
                await replay.clock.advance(to: second)
                await service.captureIfAppropriate(trigger: .manual)
            }
            XCTAssertFalse(store.screenshots(in: nil, includingMissingFiles: true).isEmpty, url.lastPathComponent)
        }
    }
}
