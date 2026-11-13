import XCTest
@testable import LokalBot

private actor MeetingNotePassRecorder {
    private(set) var previous: [[UUID: String]] = []

    func record(_ fingerprints: [UUID: String]) -> Int {
        previous.append(fingerprints)
        return previous.count
    }
}

@MainActor
final class MeetingNoteExportSchedulerTests: XCTestCase {
    private let meetingID = UUID()
    private var current = Date(timeIntervalSince1970: 1_790_668_800)
    private var processing = false
    private var scheduler: MeetingNoteExportScheduler!

    override func setUp() async throws {
        scheduler = MeetingNoteExportScheduler(
            now: { [unowned self] in self.current },
            canRun: { [unowned self] in !self.processing })
    }

    override func tearDown() async throws {
        scheduler.stop()
    }

    func testPassesFingerprintsFromEachPassToTheNext() async throws {
        let recorder = MeetingNotePassRecorder()
        let id = meetingID
        let first = expectation(description: "first pass")
        let second = expectation(description: "second pass")
        scheduler.configure(.init(enabled: true, destinationID: "vault")) { previous in
            let pass = await recorder.record(previous)
            (pass == 1 ? first : second).fulfill()
            return MeetingNoteExportReport(fingerprints: [id: "pass \(pass)"])
        } onError: { message in
            XCTFail(message)
        }
        await fulfillment(of: [first], timeout: 2)
        try await waitUntilIdle()

        scheduler.tick()
        XCTAssertFalse(scheduler.isRunning, "nothing changed since the last pass")
        scheduler.reconsider()
        scheduler.tick()
        await fulfillment(of: [second], timeout: 2)

        let previous = await recorder.previous
        XCTAssertEqual(previous, [[:], [id: "pass 1"]])
    }

    func testWaitsWhileProcessingIsBusy() async throws {
        processing = true
        let ran = expectation(description: "pass ran")
        scheduler.configure(.init(enabled: true, destinationID: "vault")) { _ in
            ran.fulfill()
            return MeetingNoteExportReport()
        } onError: { _ in }
        XCTAssertFalse(scheduler.isRunning)

        processing = false
        scheduler.tick()
        await fulfillment(of: [ran], timeout: 2)
    }

    func testFailedPassIsReportedAndRetriedAfterTheRetryInterval() async throws {
        let recorder = MeetingNotePassRecorder()
        let reported = expectation(description: "failure reported")
        let retried = expectation(description: "retried")
        scheduler.configure(.init(enabled: true, destinationID: "vault")) { previous in
            if await recorder.record(previous) == 1 {
                throw CocoaError(.fileWriteVolumeReadOnly)
            }
            retried.fulfill()
            return MeetingNoteExportReport()
        } onError: { message in
            XCTAssertTrue(message.hasPrefix("Meeting note export failed:"), message)
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 2)
        try await waitUntilIdle()

        scheduler.reconsider()
        scheduler.tick()
        XCTAssertFalse(scheduler.isRunning, "a failed pass waits before it is tried again")

        current += MeetingNoteExportScheduler.retryInterval
        scheduler.tick()
        await fulfillment(of: [retried], timeout: 2)
    }

    func testChangingTheDestinationExportsEveryMeetingAgain() async throws {
        let recorder = MeetingNotePassRecorder()
        let id = meetingID
        let passes = [expectation(description: "first folder"), expectation(description: "second folder")]
        let export: MeetingNoteExportScheduler.Export = { previous in
            let pass = await recorder.record(previous)
            passes[pass - 1].fulfill()
            return MeetingNoteExportReport(fingerprints: [id: "exported"])
        }
        scheduler.configure(.init(enabled: true, destinationID: "first"), export: export) { _ in }
        await fulfillment(of: [passes[0]], timeout: 2)
        try await waitUntilIdle()

        scheduler.configure(.init(enabled: true, destinationID: "second"), export: export) { _ in }
        await fulfillment(of: [passes[1]], timeout: 2)

        let previous = await recorder.previous
        XCTAssertEqual(previous, [[:], [:]])
    }

    func testDisablingCancelsTheRunningPass() async throws {
        let started = expectation(description: "pass started")
        let cancelled = expectation(description: "pass cancelled")
        scheduler.configure(.init(enabled: true, destinationID: "vault")) { _ in
            started.fulfill()
            do {
                while true { try await Task.sleep(for: .seconds(60)) }
            } catch {
                cancelled.fulfill()
                throw error
            }
        } onError: { message in
            XCTFail("Cancellation should not surface as an error: \(message)")
        }
        await fulfillment(of: [started], timeout: 2)

        scheduler.configure(.init(enabled: false, destinationID: "")) { _ in
            MeetingNoteExportReport()
        } onError: { _ in }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertFalse(scheduler.isRunning)
    }

    private func waitUntilIdle() async throws {
        for _ in 0..<200 where scheduler.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scheduler.isRunning)
    }
}
