import XCTest
@testable import LokalBot

final class MemoryHealthToneTests: XCTestCase {
    func testListedStatusesMapToTheirTone() {
        XCTAssertEqual(MemoryHealthTone.status("Healthy", good: ["Healthy"], idle: ["Off"]), .good)
        XCTAssertEqual(MemoryHealthTone.status("Off", good: ["Healthy"], idle: ["Off"]), .idle)
    }

    func testUnlistedStatusAsksForAttention() {
        XCTAssertEqual(MemoryHealthTone.status("Permission needed", good: ["Healthy"], idle: ["Off"]), .attention)
    }

    func testMeetingAudioIsGoodOnlyWhileReceiving() {
        XCTAssertEqual(MemoryHealthTone.audio("Receiving audio"), .good)
        for quiet in ["Idle", "Silent", "Waiting for audio"] {
            XCTAssertEqual(MemoryHealthTone.audio(quiet), .idle, quiet)
        }
        for fault in ["Stopped", "No recent audio", "Receiving silence", "Not attached", "Recovering (attempt 2)",
                      "Degraded: tap lost"] {
            XCTAssertEqual(MemoryHealthTone.audio(fault), .attention, fault)
        }
    }

    func testTextSourcesReadAsStatusWords() {
        XCTAssertEqual(MemoryHealthSection.textSourceLabel("hybrid"), "Hybrid")
        XCTAssertEqual(MemoryHealthSection.textSourceLabel("ocr_redacted"), "OCR, redacted")
        XCTAssertEqual(MemoryHealthSection.textSourceLabel("accessibility"), "Accessibility")
        XCTAssertEqual(MemoryHealthSection.textSourceLabel("future_source"), "Future_source")
    }
}
