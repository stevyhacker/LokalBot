import AppKit
import XCTest
@testable import LokalBot

final class CotypingDebounceTests: XCTestCase {
    func testMinimumStillAllowsExplicitLowLatencyTuning() {
        XCTAssertEqual(CotypingDebouncePolicy.minimumMilliseconds, 20)
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 20), 20)
    }

    func testConfiguredBelowFloorIsClamped() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 5), 20)
    }

    func testNoLatencyUsesConfigured() {
        XCTAssertEqual(CotypingDebouncePolicy.milliseconds(lastLatencyMilliseconds: nil, configured: 150), 150)
    }

    func testInProcessUsesConfiguredUntilFirstLatencySample() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: nil,
                configured: 150,
                profile: .inProcess),
            150)
    }

    func testInProcessFastTierHonorsMinimum() {
        for latency in [1, 45, 70] {
            XCTAssertEqual(
                CotypingDebouncePolicy.milliseconds(
                    lastLatencyMilliseconds: latency,
                    configured: 150,
                    profile: .inProcess),
                20)
        }
    }

    func testInProcessMediumTier() {
        for latency in [71, 140] {
            XCTAssertEqual(
                CotypingDebouncePolicy.milliseconds(
                    lastLatencyMilliseconds: latency,
                    configured: 150,
                    profile: .inProcess),
                25)
        }
    }

    func testInProcessSlowTier() {
        for latency in [141, 900, 4_000] {
            XCTAssertEqual(
                CotypingDebouncePolicy.milliseconds(
                    lastLatencyMilliseconds: latency,
                    configured: 150,
                    profile: .inProcess),
                55)
        }
    }

    func testInProcessAdaptiveTierReplacesConfiguredFallbackAfterSample() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: 45,
                configured: 1_000,
                profile: .inProcess),
            20)
    }

    func testModelServerKeepsConfiguredFloorForFastRequests() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: 120,
                configured: 150,
                profile: .modelServer),
            150)
    }

    func testModelServerBacksOffWithLatency() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: 800,
                configured: 150,
                profile: .modelServer),
            400)
    }

    func testModelServerBackoffIsCapped() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: 4_000,
                configured: 150,
                profile: .modelServer),
            600)
    }
    func testHostPublishWaitConsumesDebounceWindow() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: nil,
                configured: 150,
                consumedDelayMilliseconds: 40),
            110)
    }
    func testHostPublishWaitCanExhaustDebounceWindow() {
        XCTAssertEqual(
            CotypingDebouncePolicy.milliseconds(
                lastLatencyMilliseconds: 200,
                configured: 150,
                profile: .inProcess,
                consumedDelayMilliseconds: 55),
            0)
    }
}
