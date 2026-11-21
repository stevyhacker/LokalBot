import XCTest
@testable import LokalBot

final class ModelBudgetGuardTests: XCTestCase {
    static let reasoningHeavyTokens = 1_400
    static let typicalFocusAnswerTokens = 300
    static let headroom = 1.25

    func testDigestFocusBudgetsFitAReasoningHeavyModel() {
        let need = Double(Self.reasoningHeavyTokens + Self.typicalFocusAnswerTokens) * Self.headroom
        XCTAssertLessThanOrEqual(need, Double(DayDigestOverviewGenerator.focusRetryTokens))
        XCTAssertGreaterThanOrEqual(DayDigestOverviewGenerator.focusTokens,
                                    Self.reasoningHeavyTokens + Self.typicalFocusAnswerTokens,
                                    "the first attempt should already fit, avoiding a retry per segment")
    }

    func testRecordedModelsFitOurRetryBudgets() throws {
        let recordings = try ModelRecording.committed()
        for recording in recordings {
            for call in recording.calls {
                let answer = max(0, (call.completionTokens ?? 0) - (call.reasoningTokens ?? 0))
                let need = Double((call.reasoningTokens ?? 0) + max(answer, call.content.count / 4))
                let budget = retryBudget(for: call)
                XCTAssertLessThanOrEqual(
                    need * Self.headroom, Double(budget),
                    "\(recording.model) \(recording.caseName) \(call.purpose) needs \(Int(need)) tokens; budget \(budget)")
            }
        }
    }

    private func retryBudget(for call: ModelRecording.Call) -> Int {
        switch call.purpose {
        case .digestFocus: DayDigestOverviewGenerator.focusRetryTokens
        case .digestAggregate: DayDigestOverviewGenerator.aggregationRetryTokens
        case .notes:
            MeetingNotesGenerator.expandedStructuredOutputTokens(
                from: call.maxTokens ?? 4_096, input: 0, contextTokens: 32_768) ?? (call.maxTokens ?? 4_096)
        case .notesRepair: 4_096
        case .ask: ChatAgent.answerTokens
        }
    }
}
