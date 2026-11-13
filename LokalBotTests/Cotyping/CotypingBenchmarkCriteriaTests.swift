import AppKit
import XCTest
@testable import LokalBot

// MARK: - Benchmark word-completion pass criteria (Cotypist parity)

final class CotypingBenchmarkCriteriaTests: XCTestCase {
    private func scenario(
        allowedSuppressions: [CotypingSuppressionReason] = [],
        expectedCompletionPrefixes: [String] = [],
        trailing: String = ""
    ) -> CotypingBenchmarkScenario {
        CotypingBenchmarkScenario(
            id: "wc-test", name: "Complete: follo→w",
            field: CotypingField(
                appName: "Notes", bundleID: "com.apple.Notes", processID: 1, role: "AXTextArea",
                precedingText: "I wanted to follo", trailingText: trailing, selectionLength: 0,
                caretRect: .zero, isSecure: false, caretIsExact: true),
            expectedTerms: [],
            latencyTargetMs: 2000,
            allowedSuppressions: allowedSuppressions,
            expectsWordCompletion: true,
            expectedCompletionPrefixes: expectedCompletionPrefixes,
            wordPrefixIsValidWord: false)
    }

    @MainActor
    private func evaluate(
        _ scenario: CotypingBenchmarkScenario,
        text: String,
        suppression: CotypingSuppressionReason? = nil
    ) -> CotypingBenchmarkCaseResult {
        CotypingBenchmarkRunner.evaluate(
            scenario: scenario, text: text, suppression: suppression, latencyMs: 100)
    }

    @MainActor
    func testFragmentExtendingTextPassesAndCountsAsWordCompletionHit() {
        let result = evaluate(scenario(), text: "w up")
        XCTAssertTrue(result.passedSafety)
        XCTAssertTrue(result.wordCompletionHit)
    }

    @MainActor
    func testWhitespaceLeadingTextFailsWordCompletion() {
        // " up" after "follo" would insert "follo up" — the exact bug class the
        // criterion exists to catch.
        let result = evaluate(scenario(), text: " up")
        XCTAssertFalse(result.passedSafety)
        XCTAssertFalse(result.wordCompletionHit)
    }

    @MainActor
    func testSilenceIsSafeButOnlyAllowedSilenceIsNotWithheld() {
        let allowed = evaluate(
            scenario(allowedSuppressions: [.wordCompletionMismatch]),
            text: "", suppression: .wordCompletionMismatch)
        XCTAssertEqual(allowed.outcome, .allowedSilence)
        XCTAssertTrue(allowed.passedSafety)
        XCTAssertFalse(allowed.wordCompletionHit)

        // The confidence gate staying quiet is a missed suggestion, not harm.
        let gated = evaluate(scenario(), text: "", suppression: .lowConfidence)
        XCTAssertEqual(gated.outcome, .withheld)
        XCTAssertTrue(gated.passedSafety)
        XCTAssertFalse(gated.wordCompletionHit)
    }

    @MainActor
    func testExpectedCompletionPrefixesConstrainTheTail() {
        let accepted = evaluate(scenario(expectedCompletionPrefixes: ["w", "wing"]), text: "w up")
        XCTAssertEqual(accepted.outcome, .shown)
        XCTAssertTrue(accepted.wordCompletionHit)

        // A word tail the scenario does not accept is a miss at the end of a word...
        let wrong = evaluate(scenario(expectedCompletionPrefixes: ["w"]), text: "xup")
        XCTAssertEqual(wrong.outcome, .wrongCompletion)
        XCTAssertTrue(wrong.passedSafety)
        XCTAssertFalse(wrong.wordCompletionHit)

        // ...but corrupts the word when letters follow the caret.
        let inside = evaluate(scenario(expectedCompletionPrefixes: ["w"], trailing: "w up"), text: "xup")
        XCTAssertEqual(inside.outcome, .unsafe)
        XCTAssertFalse(inside.passedSafety)
    }

    @MainActor
    func testPromptScaffoldingAlwaysFailsSafety() {
        XCTAssertFalse(evaluate(
            scenario(),
            text: "On the clipboard: secret release plan").passedSafety)
        XCTAssertFalse(evaluate(
            scenario(),
            text: "Previously accepted completion: send it tomorrow").passedSafety)
    }

    @MainActor
    func testJSONReportCarriesWordCompletionCounters() throws {
        // side_by_side.py parses these keys; renaming or dropping them breaks
        // the scriptable A/B evaluation.
        let summary = CotypingBenchmarkSummary(results: [
            evaluate(scenario(), text: "w up"),
            evaluate(scenario(), text: " up"),
        ])
        let object = try JSONSerialization.jsonObject(with: Data(summary.jsonReport().utf8))
        let report = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(report["wordCompletionPassed"] as? Int, 1)
        XCTAssertEqual(report["wordCompletionTotal"] as? Int, 2)
        XCTAssertEqual(report["outcomes"] as? [String: Int], ["shown": 1, "unsafe": 1])
        let scenarios = try XCTUnwrap(report["scenarios"] as? [[String: Any]])
        XCTAssertEqual(scenarios.count, 2)
    }

    @MainActor
    func testEngineReportSeparatesFirstPassFromWarmPassesAndChecksConsistency() throws {
        let first = CotypingBenchmarkSummary(results: [
            CotypingBenchmarkRunner.evaluate(scenario: scenario(), text: "w up", suppression: nil, latencyMs: 900),
        ])
        var warm = first
        warm.results[0].latencyMs = 40
        let report = CotypingEngineBenchmarkReport(loadMs: 500, maxWords: 4, summaries: [first, warm, warm])
        XCTAssertTrue(report.consistentAcrossPasses)
        XCTAssertEqual(report.unsafe, 0)
        let object = try JSONSerialization.jsonObject(with: Data(report.json().utf8))
        let json = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual((json["firstPassLatency"] as? [String: Any])?["maxMs"] as? Int, 900)
        XCTAssertEqual((json["warmLatency"] as? [String: Any])?["count"] as? Int, 2)
        XCTAssertEqual((json["warmLatency"] as? [String: Any])?["p95Ms"] as? Int, 40)

        var changed = warm
        changed.results[0].text = "wing"
        XCTAssertFalse(CotypingEngineBenchmarkReport(loadMs: 0, maxWords: 4, summaries: [first, changed])
            .consistentAcrossPasses)
    }

    func testLatencyPercentilesUseNearestRank() throws {
        let stats = try XCTUnwrap(CotypingEngineBenchmarkReport.latency(Array(1...20)))
        XCTAssertEqual(stats.medianMs, 10)
        XCTAssertEqual(stats.p90Ms, 18)
        XCTAssertEqual(stats.p95Ms, 19)
        XCTAssertEqual(stats.maxMs, 20)
        XCTAssertNil(CotypingEngineBenchmarkReport.latency([]))
    }

    func testDefaultScenariosKeepCotypistParityIds() {
        // External tooling filters on these ids; the parity suite must retain a
        // word-completion scenario and the mid-word safety scenario.
        let ids = Set(CotypingBenchmarkScenario.defaults.map(\.id))
        XCTAssertTrue(ids.contains("wc-follow"))
        XCTAssertTrue(ids.contains("mid-word"))
        XCTAssertTrue(CotypingBenchmarkScenario.defaults.contains(where: \.expectsWordCompletion))
    }
}
