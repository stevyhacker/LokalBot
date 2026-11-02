import Foundation

/// Finds the action a phone's op names. Action ids are content hashes, so
/// reprocessing a meeting can change them while the phone still holds the
/// old one; the op's text snapshot then finds the action when exactly one
/// matches. Anything else is reported back as unmatched, never guessed.
enum CompanionOpMatcher {
    enum Match: Equatable {
        case byID(String)
        case byText(String)
        case unmatched
    }

    static func match(actionID: String, actionText: String?,
                      in references: [OutcomeActionReference]) -> Match {
        if references.contains(where: { $0.action.id == actionID }) { return .byID(actionID) }
        let wanted = normalized(actionText ?? "")
        guard !wanted.isEmpty else { return .unmatched }
        let candidates = references.filter { reference in
            [reference.text, reference.action.text, reference.action.displayText]
                .contains { normalized($0) == wanted }
        }
        let ids = Set(candidates.map(\.action.id))
        guard ids.count == 1, let id = ids.first else { return .unmatched }
        return .byText(id)
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Applies `action.setStatus` ops from paired devices through the same
/// `OutcomeIndex` path as the Actions list, so the outcome state, the action
/// threads, and every derived surface update exactly as for a click on the
/// Mac.
@MainActor
final class CompanionOpApplier {
    private let outcomes: OutcomeIndex
    private let meetings: () -> [Meeting]

    init(outcomes: OutcomeIndex, meetings: @escaping () -> [Meeting]) {
        self.outcomes = outcomes
        self.meetings = meetings
    }

    /// The op's meeting when it parsed, for the republish that follows.
    struct Outcome: Equatable {
        var result: CompanionOpResult
        var meetingID: UUID?
    }

    func apply(_ json: String) -> Outcome {
        guard let op = try? JSONDecoder().decode(CompanionSetStatusOp.self, from: Data(json.utf8)) else {
            return Outcome(result: .init(status: .rejected, message: "The change could not be read."))
        }
        guard op.type == CompanionSetStatusOp.typeName else {
            return Outcome(result: .init(status: .rejected, message: "This Mac does not support “\(op.type)” changes."))
        }
        guard let status = OutcomeStatus(rawValue: op.status) else {
            return Outcome(result: .init(status: .rejected, message: "“\(op.status)” is not an action status."))
        }
        guard let meetingID = UUID(uuidString: op.meetingId) else {
            return Outcome(result: .init(status: .rejected, message: "The change names no meeting."))
        }
        guard let meeting = meetings().first(where: { $0.id == meetingID }), meeting.isOwnWork else {
            return Outcome(result: .init(status: .unmatched, message: "This meeting is no longer on your Mac."),
                           meetingID: meetingID)
        }
        if outcomes.projection(for: meetingID) == nil { outcomes.refresh(meeting: meeting) }
        guard let projection = outcomes.projection(for: meetingID) else {
            return Outcome(result: .init(status: .unmatched, message: "This meeting has no action items on your Mac."),
                           meetingID: meetingID)
        }
        let references = projection.actionReferences
        let actionID: String
        switch CompanionOpMatcher.match(actionID: op.actionId, actionText: op.actionText, in: references) {
        case .byID(let id), .byText(let id): actionID = id
        case .unmatched:
            return Outcome(result: .init(status: .unmatched,
                                         message: "This action changed on your Mac. Open the meeting to update it."),
                           meetingID: meetingID)
        }
        if references.first(where: { $0.action.id == actionID })?.status == status {
            return Outcome(result: .init(status: .applied), meetingID: meetingID)
        }
        guard outcomes.setStatus(status, actionID: actionID, meetingID: meetingID) else {
            return Outcome(result: .init(status: .rejected,
                                         message: outcomes.lastError ?? "Your Mac could not save the change."),
                           meetingID: meetingID)
        }
        return Outcome(result: .init(status: .applied), meetingID: meetingID)
    }
}
