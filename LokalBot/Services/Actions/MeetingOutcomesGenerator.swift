import Foundation

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
        let leftDue = normalized(lhs.due ?? "")
        let rightDue = normalized(rhs.due ?? "")
        guard leftDue.isEmpty || rightDue.isEmpty || leftDue == rightDue else { return false }
        if normalized(lhs.text) == normalized(rhs.text) { return true }
        guard let anchor = lhs.citations.first, anchor.segmentID == rhs.citations.first?.segmentID else { return false }
        let leftQuote = normalized(lhs.attribution?.quote ?? "")
        let rightQuote = normalized(rhs.attribution?.quote ?? "")
        guard leftQuote.isEmpty || rightQuote.isEmpty || leftQuote == rightQuote else { return false }
        if duplicateText(lhs.text, rhs.text, threshold: 0.65) { return true }
        guard !leftQuote.isEmpty, leftQuote == rightQuote else { return false }
        return echoesTask(lhs, rhs) || echoesTask(rhs, lhs)
    }

    private static func echoesTask(_ echo: MeetingOutcomes.ActionItem, _ task: MeetingOutcomes.ActionItem) -> Bool {
        guard repeatsItsSource(echo) else { return false }
        let match = SpokenUndertaking.alignment(task: task.text, clause: SpokenUndertaking.words([echo.text]))
        return match.leads && match.matches >= 2
    }

    private static func repeatsItsSource(_ action: MeetingOutcomes.ActionItem) -> Bool {
        let text = normalized(action.text)
        let source = action.attribution?.quote ?? action.citations.first?.excerpt ?? ""
        return text.split(separator: " ").count >= 4 && normalized(source).contains(text)
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
        let primary = preferredAction(lhs, rhs)
        return .init(
            text: primary.text,
            owner: primary.owner,
            due: primary.due,
            isForUser: primary.isForUser,
            importance: max(lhs.importance, rhs.importance),
            citations: mergedCitations(primary.citations, lhs.citations + rhs.citations, anchor: primary.citations.first?.segmentID),
            attribution: primary.attribution)
    }

    private static func preferredAction(
        _ lhs: MeetingOutcomes.ActionItem,
        _ rhs: MeetingOutcomes.ActionItem
    ) -> MeetingOutcomes.ActionItem {
        let leftHasDue = !normalized(lhs.due ?? "").isEmpty
        let rightHasDue = !normalized(rhs.due ?? "").isEmpty
        if leftHasDue != rightHasDue { return leftHasDue ? lhs : rhs }
        let leftEcho = repeatsItsSource(lhs)
        let rightEcho = repeatsItsSource(rhs)
        if leftEcho != rightEcho { return leftEcho ? rhs : lhs }
        return rhs.text.count > lhs.text.count ? rhs : lhs
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
