import AppKit
import XCTest
@testable import LokalBot

// MARK: - Quality benchmark

@MainActor
private final class StaticCotypingEngine: CotypingCompleting {
    var output: String
    var partial: String?

    init(output: String, partial: String? = nil) {
        self.output = output
        self.partial = partial
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        CotypingNormalizationResult(text: output, suppression: nil)
    }

    func generateStreaming(_ request: CotypingRequest,
                           onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void) async throws -> CotypingNormalizationResult {
        if let partial {
            onPartial(CotypingNormalizationResult(text: partial, suppression: nil))
        }
        return CotypingNormalizationResult(text: output, suppression: nil)
    }
}

final class CotypingBenchmarkTests: XCTestCase {
    @MainActor
    func testEvaluatorTracksSafetyLatencyAndKeywordHints() {
        let scenario = CotypingBenchmarkScenario.defaults[0]
        let result = CotypingBenchmarkRunner.evaluate(
            scenario: scenario,
            text: " up with the final numbers today",
            suppression: nil,
            latencyMs: 220,
            firstVisibleLatencyMs: 120)

        XCTAssertTrue(result.passedSafety)
        XCTAssertTrue(result.metLatencyTarget)
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.latencyForTargetMs, 120)
        XCTAssertGreaterThan(result.expectedTermHits, 0)
    }

    @MainActor
    func testEvaluatorAllowsExpectedSuppressionForSafetyScenario() {
        let scenario = CotypingBenchmarkScenario.defaults.first { $0.id == "mid-word" }!
        let result = CotypingBenchmarkRunner.evaluate(
            scenario: scenario,
            text: "",
            suppression: .unsafeToInsert,
            latencyMs: 90)

        XCTAssertTrue(result.passedSafety)
        XCTAssertTrue(result.metLatencyTarget)
        XCTAssertTrue(result.passed)
        // Mid-word is a word-completion scenario since the Cotypist-parity
        // work: an allowed suppression still passes safety, but does not
        // count as a completion hit.
        XCTAssertTrue(result.expectedWordCompletion)
        XCTAssertFalse(result.wordCompletionHit)
        XCTAssertTrue(result.allowedSuppression)
    }

    @MainActor
    func testRunnerMatchesCotypistDefaultByNotRecordingPartialLatency() async {
        let summary = await CotypingBenchmarkRunner.run(
            scenarios: Array(CotypingBenchmarkScenario.defaults.prefix(3)),
            engine: StaticCotypingEngine(output: " up today", partial: " up"),
            config: .standard,
            personalization: .none)

        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.safetyPassed, summary.total)
        XCTAssertNotNil(summary.averageLatencyMs)
        XCTAssertNil(summary.averageFirstVisibleLatencyMs)
        XCTAssertNotNil(summary.p95LatencyMs)
        XCTAssertNil(summary.p95FirstVisibleLatencyMs)
    }

    @MainActor
    func testRunnerRecordsFirstVisibleLatencyWhenStreamingEnabled() async {
        let summary = await CotypingBenchmarkRunner.run(
            scenarios: Array(CotypingBenchmarkScenario.defaults.prefix(3)),
            engine: StaticCotypingEngine(output: " up today", partial: " up"),
            config: .standard,
            personalization: .none,
            streamPartials: true)

        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.safetyPassed, summary.total)
        XCTAssertNotNil(summary.averageLatencyMs)
        XCTAssertNotNil(summary.averageFirstVisibleLatencyMs)
        XCTAssertNotNil(summary.p95LatencyMs)
        XCTAssertNotNil(summary.p95FirstVisibleLatencyMs)
    }
}
