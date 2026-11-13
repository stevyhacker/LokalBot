import XCTest
@testable import LokalBot

@MainActor
final class RecordingPromptRegistryTests: XCTestCase {
    func testDeniedDeliverySurfacesFallbackOnlyForTheCurrentUnexpiredPrompt() {
        var registry = RecordingPromptRegistry()
        var fallbacks = 0
        let now = Date()
        registry.insert(identifier: "current", expiresAt: now.addingTimeInterval(60),
                        unavailable: { fallbacks += 1 }) { XCTFail("Denial cannot authorize recording") }
        registry.deliveryFailed("current", now: now)
        registry.deliveryFailed("current", now: now)
        XCTAssertEqual(fallbacks, 1)
        registry.insert(identifier: "expired", expiresAt: now, unavailable: { fallbacks += 1 }) {}
        registry.deliveryFailed("expired", now: now)
        registry.insert(identifier: "stale", expiresAt: now.addingTimeInterval(60),
                        unavailable: { fallbacks += 1 }) {}
        _ = registry.removeAll()
        registry.deliveryFailed("stale", now: now)
        XCTAssertEqual(fallbacks, 1)
    }

    func testInvalidationRemovesStaleRecordActionBeforeReplacement() {
        var registry = RecordingPromptRegistry()
        var recorded: [String] = []
        let now = Date()

        registry.insert(identifier: "old", expiresAt: now.addingTimeInterval(120)) {
            recorded.append("old")
        }
        XCTAssertEqual(Set(registry.removeAll()), ["old"])

        registry.insert(identifier: "current", expiresAt: now.addingTimeInterval(120)) {
            recorded.append("current")
        }
        XCTAssertNil(registry.remove("old"))
        registry.remove("current")?.record()

        XCTAssertEqual(recorded, ["current"])
    }

    func testExpiredPromptIsRemovedWithoutInvalidatingCurrentPrompt() {
        var registry = RecordingPromptRegistry()
        var didRecordCurrent = false
        let now = Date()

        registry.insert(identifier: "expired", expiresAt: now.addingTimeInterval(-1)) {}
        registry.insert(identifier: "current", expiresAt: now.addingTimeInterval(60)) {
            didRecordCurrent = true
        }

        XCTAssertEqual(Set(registry.removeExpired(now: now)), ["expired"])
        XCTAssertNil(registry.remove("expired"))
        registry.remove("current")?.record()
        XCTAssertTrue(didRecordCurrent)
    }
}
