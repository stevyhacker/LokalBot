import XCTest
@testable import LokalBot

@MainActor
final class RecordingMicrophoneSourceTests: XCTestCase {
    override func tearDown() {
        CaptureEnvironment.reset()
        MeetingDetector.invalidateAudioProcessSnapshot()
        MeetingDetector.resetCaptureTargetMemory()
    }

    func testLateOutputHelperAttachesToTheExistingMicrophoneCall() async throws {
        for bundle in ["com.example.CorporateCalls", "com.google.Chrome"] {
            let start = Date(timeIntervalSince1970: 1_790_000_000)
            let trace = CaptureTrace(header: .init(schemaVersion: 1, macOSVersion: "Test",
                origin: .scripted, scenario: "microphone-call-late-output", recordedAt: start), events: [
                    .init(t: 0, query: .runningApps, apps: [
                        .init(processIdentifier: 801, bundleIdentifier: bundle, localizedName: "Call app")
                    ]),
                    .init(t: 0, query: .audioProcesses, processes: []),
                    .init(t: 0, query: .inputRunning, processID: 801, flag: true),
                    .init(t: 20, query: .audioProcesses, processes: [
                        .init(id: 802, name: "Remote audio", bundleID: bundle + ".helper",
                              objectID: 90, isRunningOutput: true)
                    ]),
                    .init(t: 40, query: .inputRunning, processID: 801, flag: false)
                ])
            let replay = ReplayCaptureEnvironment(trace: trace, start: start)
            CaptureEnvironment.install(replay.environment)
            MeetingDetector.invalidateAudioProcessSnapshot()
            MeetingDetector.resetCaptureTargetMemory()
            let detector = MeetingDetector(microphoneWindowsAllowed: { Set($0) })
            detector.additionalCallBundleIDs = [bundle.lowercased()]
            detector.detectOtherBrowserCalls = true
            let recovery = MeetingAudioRecovery()
            defer { recovery.cancel() }
            let recordingID = UUID()
            var starts = 0
            var attached: [pid_t] = []
            detector.onMeetingStarted = { context in
                starts += 1
                guard let app = context.detectedApp else { return }
                XCTAssertNil(MeetingDetector.currentCaptureTargetProcess(for: app))
                recovery.start(recordingID: recordingID,
                    intent: .init(systemAudioRequested: true, appBundleID: app.bundleID),
                    find: { _ in nil }, attach: { candidate in
                        guard let process = MeetingDetector.currentCaptureTargetProcess(for: candidate) else {
                            return false
                        }
                        attached.append(process.id)
                        return true
                    }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
            }
            detector.onVerifiedSourceAvailable = { context in
                if let app = context.detectedApp { recovery.offer(app, recordingID: recordingID) }
            }
            for time in stride(from: 0.0, through: 36, by: 2) {
                await replay.clock.advance(to: time)
                await detector.tickForTesting()
            }
            XCTAssertEqual(starts, 1, bundle)
            XCTAssertEqual(attached, [802], bundle)
            XCTAssertNil(recovery.recordingID)
        }
    }
}
