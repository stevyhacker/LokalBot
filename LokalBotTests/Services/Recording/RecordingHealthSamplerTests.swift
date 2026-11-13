import XCTest
@testable import LokalBot

@MainActor
final class RecordingHealthSamplerTests: XCTestCase {
    func testBusyAudioWritersDoNotBlockMainActorAndRequestsAreCoalesced() async {
        let micQueue = DispatchQueue(label: "test.mic.writer")
        let systemQueue = DispatchQueue(label: "test.system.writer")
        let micGate = DispatchSemaphore(value: 0), systemGate = DispatchSemaphore(value: 0)
        let writersEntered = expectation(description: "Both writers busy")
        writersEntered.expectedFulfillmentCount = 2
        for (queue, gate) in [(micQueue, micGate), (systemQueue, systemGate)] {
            queue.async {
                writersEntered.fulfill()
                _ = gate.wait(timeout: .now() + 3)
            }
        }
        defer { micGate.signal(); systemGate.signal() }
        await fulfillment(of: [writersEntered], timeout: 1)
        let mic = MicRecorder(writerQueue: micQueue)
        let system = SystemAudioRecorder(writerQueue: systemQueue)
        let sampler = RecordingHealthSampler()
        var micReads = 0, systemReads = 0, deliveries = 0
        let readsEntered = expectation(description: "Both reads queued")
        readsEntered.expectedFulfillmentCount = 2
        let started = Date()
        for _ in 0..<20 {
            sampler.request(microphone: {
                micReads += 1
                readsEntered.fulfill()
                return await mic.captureHealthInBackground()
            }, system: {
                systemReads += 1
                readsEntered.fulfill()
                return await system.captureHealthInBackground()
            }, receive: { _ in deliveries += 1 })
        }
        await fulfillment(of: [readsEntered], timeout: 1)
        let mainResponsive = expectation(description: "Main actor remains responsive")
        Task { @MainActor in mainResponsive.fulfill() }
        await fulfillment(of: [mainResponsive], timeout: 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertNil(sampler.latest)
        XCTAssertEqual(deliveries, 0)
        micGate.signal(); systemGate.signal()
        await sampler.waitForPendingSample()
        XCTAssertEqual(micReads, 1)
        XCTAssertEqual(systemReads, 1)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(sampler.latest?.microphone.duration, 0)
        XCTAssertEqual(sampler.latest?.system.duration, 0)
    }

    func testStopRejectsPendingSampleAndKeepsItBoundedAcrossNewRecording() async {
        let sampler = RecordingHealthSampler()
        let entered = expectation(description: "Old read queued")
        var continuation: CheckedContinuation<MicRecorder.CaptureHealth, Never>?
        var oldDeliveries = 0, newReads = 0
        let microphone = MicRecorder.CaptureHealth(duration: 12, lastAudioWriteAt: nil, lastSignalAt: nil,
            isEngineRunning: true, droppedBufferCount: 0, recoveryState: .healthy)
        let system = SystemAudioRecorder.CaptureHealth(duration: 12, audibleDuration: 3,
            framesSinceAttach: 10, lastAudioWriteAt: nil, lastAudibleWriteAt: nil,
            capturedPID: 0, lastRMSLevel: 0, peakRMSLevel: 0, droppedBufferCount: 0)
        sampler.request(microphone: {
            await withCheckedContinuation { continuation = $0; entered.fulfill() }
        }, system: { system }, receive: { _ in oldDeliveries += 1 })
        await fulfillment(of: [entered], timeout: 1)
        sampler.invalidate()
        sampler.request(microphone: { newReads += 1; return microphone },
                        system: { system }, receive: { _ in XCTFail("Queued duplicate") })
        continuation?.resume(returning: microphone)
        await sampler.waitForPendingSample()
        XCTAssertNil(sampler.latest)
        XCTAssertEqual(oldDeliveries, 0)
        XCTAssertEqual(newReads, 0)

        sampler.request(microphone: { newReads += 1; return microphone },
                        system: { system }, receive: { _ in })
        await sampler.waitForPendingSample()
        XCTAssertEqual(newReads, 1)
        XCTAssertEqual(sampler.latest?.microphone.duration, 12)
        sampler.invalidate()
        XCTAssertNil(sampler.latest)
    }
}
