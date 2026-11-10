import Foundation

enum MeetingOutcomeStore {
    static func loadState(from folder: URL) -> MeetingOutcomeState {
        decode(MeetingOutcomeState.self, at: folder.appendingPathComponent(MeetingOutcomeState.fileName))
            ?? MeetingOutcomeState()
    }

    static func writeState(_ state: MeetingOutcomeState, to folder: URL) throws {
        try write(state, to: folder.appendingPathComponent(MeetingOutcomeState.fileName))
    }

    static func loadFollowUp(from folder: URL) -> FollowUpDraft? {
        decode(FollowUpDraft.self, at: folder.appendingPathComponent(FollowUpDraft.fileName))
    }

    static func writeFollowUp(_ draft: FollowUpDraft, to folder: URL) throws {
        try write(draft, to: folder.appendingPathComponent(FollowUpDraft.fileName))
    }

    /// Carry user-owned workflow state across a safe re-extraction. A transfer requires
    /// an unambiguous match in both directions and compatible source evidence.
    /// Unmatched edits remain available for review.
    static func reconcileState(
        _ state: MeetingOutcomeState,
        from previous: MeetingOutcomes,
        to next: MeetingOutcomes
    ) -> MeetingOutcomeState {
        var reconciled = MeetingOutcomeState()
        var consumed: Set<String> = []
        let oldActions = previous.actionItems.filter { state.actions[$0.id] != nil }
        // An action's ID is a hash of its text, owner, due date and sources,
        // so one the model returned twice arrives here under one ID.
        let matches = Dictionary(next.actionItems.map { action in
            (action.id, oldActions.filter { matchScore($0, action) >= 0.8 })
        }, uniquingKeysWith: { first, _ in first })
        for action in next.actionItems {
            let candidates = matches[action.id] ?? []
            guard candidates.count == 1, let old = candidates.first,
                  matches.values.filter({ $0.contains { $0.id == old.id } }).count == 1,
                  let saved = state.actions[old.id] else { continue }
            reconciled.actions[action.id] = saved
            consumed.insert(old.id)
        }
        var unmatched = state.unmatchedActions ?? [:]
        var texts = state.unmatchedActionText ?? [:]
        for (id, saved) in state.actions where !consumed.contains(id) {
            unmatched[id] = saved
            texts[id] = previous.actionItems.first { $0.id == id }?.text
        }
        reconciled.unmatchedActions = unmatched.isEmpty ? nil : unmatched
        reconciled.unmatchedActionText = texts.isEmpty ? nil : texts
        return reconciled
    }

    private static func decode<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalISO8601.date(from: value)
                ?? legacyISO8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return try? decoder.decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalISO8601.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Preserve sub-second edits while continuing to read the second-precision
    /// ISO-8601 dates written by LokalBot before the outcome-state overlay.
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let legacyISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func matchScore(_ lhs: MeetingOutcomes.ActionItem,
                                   _ rhs: MeetingOutcomes.ActionItem) -> Double {
        let leftCitations = Set(lhs.citations.map(\.segmentID))
        let rightCitations = Set(rhs.citations.map(\.segmentID))
        let sharesEvidence = !leftCitations.isDisjoint(with: rightCitations)
        let leftTokens = tokens(lhs.text)
        let rightTokens = tokens(rhs.text)
        let union = leftTokens.union(rightTokens)
        let textScore = union.isEmpty ? 0
            : Double(leftTokens.intersection(rightTokens).count) / Double(union.count)
        if lhs.id == rhs.id { return 1 }
        if sharesEvidence && normalized(lhs.text) == normalized(rhs.text) { return 1 }
        return sharesEvidence && textScore >= 0.6 ? max(0.85, textScore) : 0
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(normalized(text).split(separator: " ").map(String.init))
    }
}
