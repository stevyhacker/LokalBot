import XCTest
@testable import LokalBot

@MainActor
final class DictationAudioHandoffTests: XCTestCase {
    func testCancelRemovesAudioBeforeSuspendedHandoffResumes() async throws {
        let url = try scratchAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let handoff = DictationAudioHandoff(audioURL: url)
        var resume: CheckedContinuation<Void, Never>?
        let waiting = expectation(description: "Media restoration is suspended")
        let task = Task {
            await withCheckedContinuation { continuation in
                resume = continuation
                waiting.fulfill()
            }
            XCTAssertNil(handoff.take(), "Cancelled audio must not reach transcription")
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        handoff.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        resume?.resume()
        await task.value
    }

    func testSuccessfulTransferKeepsAudioForTranscriptionAndTransfersOnlyOnce() throws {
        let url = try scratchAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        var handoff: DictationAudioHandoff? = DictationAudioHandoff(audioURL: url)
        XCTAssertEqual(handoff?.take(), url)
        XCTAssertNil(handoff?.take())
        handoff?.discard()
        handoff = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAbandonedOwnerDeletesUnclaimedAudio() throws {
        let url = try scratchAudio()
        var handoff: DictationAudioHandoff? = DictationAudioHandoff(audioURL: url)
        XCTAssertNotNil(handoff)
        handoff = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func scratchAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-handoff-\(UUID().uuidString).caf")
        try Data("synthetic scratch audio".utf8).write(to: url)
        return url
    }
}
