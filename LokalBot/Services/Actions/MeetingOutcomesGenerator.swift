import Foundation

/// Deterministic deduplication shared by the unified notes extraction pass.
enum MeetingOutcomesGenerator {
    static func removeCheckpoint(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("outcomes.parts.partial.json"))
    }

    static func merge(_ parts: [MeetingOutcomes]) -> MeetingOutcomes {
        var actions: [MeetingOutcomes.ActionItem] = []
        var decisions: [MeetingOutcomes.Decision] = []
        var openQuestions: [String] = []

        for part in parts {
            for action in part.actionItems {
                if let index = actions.firstIndex(where: { duplicateAction($0, action) }) {
                    actions[index] = mergedAction(actions[index], action)
                } else {
                    actions.append(rebuiltAction(action))
                }
            }
            for decision in part.decisionRecords {
                if let index = decisions.firstIndex(where: { duplicateDecision($0, decision) }) {
                    decisions[index] = mergedDecision(decisions[index], decision)
                } else {
                    decisions.append(rebuiltDecision(decision))
                }
            }
            for question in part.openQuestions where !question.isEmpty {
                if !openQuestions.contains(where: { duplicateText($0, question, threshold: 0.85) }) {
                    openQuestions.append(question)
                }
            }
        }

        decisions.removeAll { decision in
            actions.contains { action in
                guard sharesEvidence(action.citations, decision.citations) else { return false }
                if let statement = decision.attribution,
                   statement.speakerID == action.attribution?.speakerID,
                   OutcomeEvidencePolicy.isBareAcceptance(statement.quote) { return true }
                return duplicateText(action.text, decision.text, threshold: 0.65)
            }
        }
        actions.sort(by: actionOrder)
        decisions.sort(by: decisionOrder)

        var outcomes = MeetingOutcomes()
        outcomes.actionItems = actions
        outcomes.decisionRecords = decisions
        outcomes.openQuestions = openQuestions
        return outcomes
    }

    private static func duplicateAction(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> Bool {
        guard compatibleOwners(lhs, rhs) else { return false }
        if normalized(lhs.text) == normalized(rhs.text) { return true }
        guard sharesEvidence(lhs.citations, rhs.citations) else { return false }
        // Asked again about a row, a small model can hand back the row's
        // own words as a second task.
        return duplicateText(lhs.text, rhs.text, threshold: 0.65) || repeatsItsSource(lhs) || repeatsItsSource(rhs)
    }

    /// The task text is just what its cited speaker said ("I'll ping Mira
    /// to get that resolved"), not a task written from it.
    private static func repeatsItsSource(_ action: MeetingOutcomes.ActionItem) -> Bool {
        let text = normalized(action.text)
        return text.split(separator: " ").count >= 4
            && action.citations.contains { normalized($0.excerpt).contains(text) }
    }

    private static func duplicateDecision(
        _ lhs: MeetingOutcomes.Decision,
        _ rhs: MeetingOutcomes.Decision
    ) -> Bool {
        guard lhs.attribution?.speakerID == rhs.attribution?.speakerID else { return false }
        return normalized(lhs.text) == normalized(rhs.text)
            || (sharesEvidence(lhs.citations, rhs.citations)
                && duplicateText(lhs.text, rhs.text, threshold: 0.65))
    }

    private static func compatibleOwners(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> Bool {
        guard lhs.isForUser == rhs.isForUser,
              lhs.ownershipIsUnclear == rhs.ownershipIsUnclear,
              lhs.attribution?.speakerID == rhs.attribution?.speakerID,
              lhs.attribution?.basis == rhs.attribution?.basis else { return false }
        if lhs.isForUser { return true }
        let left = normalized(lhs.owner ?? "")
        let right = normalized(rhs.owner ?? "")
        return left.isEmpty || right.isEmpty || left == right
    }

    private static func mergedAction(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> MeetingOutcomes.ActionItem {
        let isForUser = lhs.isForUser || rhs.isForUser
        let text = repeatsItsSource(lhs) != repeatsItsSource(rhs)
            ? (repeatsItsSource(lhs) ? rhs.text : lhs.text) : preferredText(lhs.text, rhs.text)
        return .init(
            text: text,
            owner: isForUser ? "Me" : lhs.owner ?? rhs.owner,
            due: lhs.due ?? rhs.due,
            isForUser: isForUser,
            importance: max(lhs.importance, rhs.importance),
            citations: mergedCitations(lhs.citations, rhs.citations, anchor: lhs.citations.first?.segmentID), attribution: lhs.attribution)
    }

    private static func rebuiltAction(
        _ action: MeetingOutcomes.ActionItem
    ) -> MeetingOutcomes.ActionItem {
        .init(
            text: action.text,
            owner: action.isForUser ? "Me" : action.owner,
            due: action.due,
            isForUser: action.isForUser,
            importance: action.importance,
            citations: mergedCitations(action.citations, [], anchor: action.citations.first?.segmentID), attribution: action.attribution)
    }

    private static func mergedDecision(
        _ lhs: MeetingOutcomes.Decision,
        _ rhs: MeetingOutcomes.Decision
    ) -> MeetingOutcomes.Decision {
        .init(
            text: preferredText(lhs.text, rhs.text),
            citations: mergedCitations(lhs.citations, rhs.citations), attribution: lhs.attribution)
    }

    private static func rebuiltDecision(
        _ decision: MeetingOutcomes.Decision
    ) -> MeetingOutcomes.Decision {
        .init(
            text: decision.text,
            citations: mergedCitations(decision.citations, []), attribution: decision.attribution)
    }

    private static func preferredText(_ lhs: String, _ rhs: String) -> String {
        rhs.count > lhs.count ? rhs : lhs
    }

    private static func mergedCitations(
        _ lhs: [OutcomeSourceCitation],
        _ rhs: [OutcomeSourceCitation],
        anchor: String? = nil
    ) -> [OutcomeSourceCitation] {
        var byID: [String: OutcomeSourceCitation] = [:]
        for citation in lhs + rhs where byID[citation.segmentID] == nil {
            byID[citation.segmentID] = citation
        }
        return byID.values.sorted {
            if ($0.segmentID == anchor) != ($1.segmentID == anchor) { return $0.segmentID == anchor }
            if $0.start == $1.start { return $0.segmentID < $1.segmentID }
            return $0.start < $1.start
        }
    }

    private static func sharesEvidence(
        _ lhs: [OutcomeSourceCitation],
        _ rhs: [OutcomeSourceCitation]
    ) -> Bool {
        let left = Set(lhs.map(\.segmentID))
        return !left.isDisjoint(with: rhs.map(\.segmentID))
    }

    private static func duplicateText(
        _ lhs: String,
        _ rhs: String,
        threshold: Double
    ) -> Bool {
        OutcomeTextSimilarity.isSimilar(lhs, rhs, threshold: threshold)
    }

    private static func normalized(_ text: String) -> String {
        OutcomeTextSimilarity.normalized(text)
    }

    private static func actionOrder(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> Bool {
        if lhs.isForUser != rhs.isForUser { return lhs.isForUser }
        let left = lhs.citations.first?.start ?? .infinity
        let right = rhs.citations.first?.start ?? .infinity
        if left == right { return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending }
        return left < right
    }

    private static func decisionOrder(
        _ lhs: MeetingOutcomes.Decision,
        _ rhs: MeetingOutcomes.Decision
    ) -> Bool {
        let left = lhs.citations.first?.start ?? .infinity
        let right = rhs.citations.first?.start ?? .infinity
        if left == right { return lhs.text.localizedCaseInsensitiveCompare(rhs.text) == .orderedAscending }
        return left < right
    }

}
