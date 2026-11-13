import AppKit
import XCTest
@testable import LokalBot

final class CaptureEnvironmentTests: XCTestCase {
    override func tearDown() {
        CaptureEnvironment.reset()
    }

    func testRunningAppCopiesTheIdentifyingFields() {
        let current = NSRunningApplication.current
        let app = RunningApp(current)
        XCTAssertEqual(app.processIdentifier, current.processIdentifier)
        XCTAssertEqual(app.bundleIdentifier, current.bundleIdentifier)
        XCTAssertEqual(app.localizedName, current.localizedName)
    }

    func testInstallReplacesTheProcessWideEnvironmentAndResetRestoresLive() {
        struct Fixed: WorkspaceSource {
            func frontmostApplication() -> RunningApp? {
                RunningApp(processIdentifier: 42, bundleIdentifier: "com.example.fixed", localizedName: "Fixed")
            }
            func runningApplications() -> [RunningApp] { [] }
            func isRunning(processID: pid_t) -> Bool { processID == 42 }
            func secondsSinceLastInput() -> TimeInterval { 0 }
        }
        var environment = CaptureEnvironment.live
        environment.workspace = Fixed()
        CaptureEnvironment.install(environment)
        XCTAssertEqual(CaptureEnvironment.current.workspace.frontmostApplication()?.processIdentifier, 42)
        CaptureEnvironment.reset()
        XCTAssertNotEqual(CaptureEnvironment.current.workspace.frontmostApplication()?.processIdentifier, 42)
    }

    @MainActor
    func testLiveClockRunsScheduledWorkOnTheMainActor() async {
        let fired = expectation(description: "fired")
        let timer = CaptureEnvironment.live.clock.schedule(after: 0.05) { fired.fulfill() }
        await fulfillment(of: [fired], timeout: 2)
        timer.cancel()
    }

    func testTraceValueTypesRoundTripThroughJSON() throws {
        let read = AccessibilityRead(
            snapshot: ScreenAccessibilitySnapshot(text: "t", sourceURL: nil, documentName: nil,
                                                  focusedSecureField: nil, windowTitle: "w",
                                                  windowFrame: CGRect(x: 1, y: 2, width: 3, height: 4)),
            failure: .init(reason: "r", isTransient: true))
        XCTAssertEqual(try JSONDecoder().decode(AccessibilityRead.self, from: JSONEncoder().encode(read)), read)
        let snapshot = BrowserMeetingSession.Snapshot(url: URL(string: "https://meet.google.com/bcd-fghj-klm")!,
                                                      state: .present)
        XCTAssertEqual(try JSONDecoder().decode(BrowserMeetingSession.Snapshot.self,
                                                from: JSONEncoder().encode(snapshot)), snapshot)
    }

    @MainActor
    func testSamplerReadsFrontmostAppAndIdleTimeFromTheEnvironment() async throws {
        struct Workspace: WorkspaceSource {
            func frontmostApplication() -> RunningApp? {
                RunningApp(processIdentifier: 77, bundleIdentifier: "com.example.editor", localizedName: "Editor")
            }
            func runningApplications() -> [RunningApp] { [frontmostApplication()!] }
            func isRunning(processID: pid_t) -> Bool { processID == 77 }
            func secondsSinceLastInput() -> TimeInterval { 1 }
        }
        struct Accessibility: AccessibilitySource {
            func isTrusted() -> Bool { true }
            func read(processID: pid_t, includeText: Bool) -> AccessibilityRead {
                AccessibilityRead(snapshot: ScreenAccessibilitySnapshot(
                    text: "", sourceURL: nil, documentName: nil, focusedSecureField: false,
                    windowTitle: "Plan", windowFrame: nil), failure: nil)
            }
            func focusedWindowTitle(processID: pid_t) -> String? { "Plan" }
            func browserMeetingSnapshot(processID: pid_t, expectedURL: URL?) -> BrowserMeetingSession.Snapshot? { nil }
            func browserReadIssue(processID: pid_t) -> BrowserMeetingSession.ReadIssue? { nil }
        }
        var environment = CaptureEnvironment.live
        environment.workspace = Workspace()
        environment.accessibility = Accessibility()
        CaptureEnvironment.install(environment)

        let database = FileManager.default.temporaryDirectory.appendingPathComponent("sampler-\(UUID()).sqlite")
        let sampler = ActivitySampler(store: ActivityStore(databaseURL: database),
                                      accessibilityReader: ScreenAccessibilityReader(resolver: { pid in
                                          CaptureEnvironment.current.accessibility
                                              .read(processID: pid, includeText: false).snapshot
                                      }))
        await sampler.sample()
        XCTAssertEqual(sampler.currentApp, "Editor")
    }
}
