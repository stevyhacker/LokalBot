@testable import LokalBot

/// Which LokalBot stage sent a request, recognised by a stable phrase of its
/// system prompt (every request's `response_format` is named "response").
/// `ModelServerScenarioTests` checks each phrase still appears in the real
/// prompt, so a prompt rewrite cannot silently break replay.
enum ModelRequestPurpose: String, Codable, CaseIterable {
    case digestFocus, digestAggregate, notes, notesRepair, ask

    var systemMarker: String {
        switch self {
        case .digestFocus: "You extract substantive work from noisy local activity evidence"
        case .digestAggregate: "You write a concise" // shared by the task and best-available recaps
        case .notes: "Extract factual notes AND concrete actions"
        case .notesRepair: "Repair only the requested notes/actions"
        case .ask: "You are LokalBot's assistant"
        }
    }

    static func classify(system: String) -> ModelRequestPurpose? {
        allCases.first { system.contains($0.systemMarker) }
    }
}
