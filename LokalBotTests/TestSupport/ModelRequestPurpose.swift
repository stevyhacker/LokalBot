@testable import LokalBot

enum ModelRequestPurpose: String, Codable, CaseIterable {
    case digestFocus, digestAggregate, notes, notesRepair, ask

    var systemMarker: String {
        switch self {
        case .digestFocus: "You extract substantive work from noisy local activity evidence"
        case .digestAggregate: "You write a concise"
        case .notes: "Extract factual notes AND concrete actions"
        case .notesRepair: "Repair only the requested notes/actions"
        case .ask: "You are LokalBot's assistant"
        }
    }

    static func classify(system: String) -> ModelRequestPurpose? {
        allCases.first { system.contains($0.systemMarker) }
    }
}
