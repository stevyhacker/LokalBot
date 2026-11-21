import Foundation

struct MeetingOutcomeProjection: Identifiable, Equatable, Sendable {
    let meeting: Meeting
    var outcomes: MeetingOutcomes
    var state: MeetingOutcomeState
    var followUp: FollowUpDraft
    var isArchived = false

    var id: Meeting.ID { meeting.id }

    var actionReferences: [OutcomeActionReference] {
        outcomes.actionItems.map { action in
            let userState = state.state(for: action)
            return OutcomeActionReference(
                meetingID: meeting.id,
                meetingTitle: meeting.displayTitle,
                meetingStartedAt: meeting.startedAt,
                action: action,
                status: userState.status,
                text: userState.textCorrection ?? action.displayText,
                owner: userState.ownerWasCleared ? nil : (userState.ownerOverride ?? action.owner),
                due: userState.dueWasCleared ? nil : (userState.dueOverride ?? action.due),
                stateUpdatedAt: userState.userEdited ? userState.updatedAt : meeting.startedAt,
                textWasCorrected: userState.textCorrection != nil,
                ownerWasCorrected: userState.ownerOverride != nil || userState.ownerWasCleared,
                dueWasCorrected: userState.dueOverride != nil || userState.dueWasCleared,
                textCorrectedAt: userState.textCorrectedAt,
                ownerCorrectedAt: userState.ownerCorrectedAt,
                dueCorrectedAt: userState.dueCorrectedAt,
                isThreadExcluded: userState.isThreadExcluded)
        }
    }

    var activeOutcomes: MeetingOutcomes {
        var result = outcomes
        result.actionItems = actionReferences
            .filter { $0.status != .done }
            .map(\.effectiveAction)
        return result
    }

    var correctedOutcomes: MeetingOutcomes {
        var result = outcomes
        result.actionItems = actionReferences.map(\.effectiveAction)
        return result
    }

    static func load(for meeting: Meeting, root: URL, includingPrevious: Bool = false) -> Self? {
        let folder = root.appendingPathComponent(meeting.relativePath, isDirectory: true)
        let current = MeetingOutcomes.load(from: folder)
        let previous = current == nil && includingPrevious && MeetingAttributionArtifacts.needsRefresh(in: folder)
            ? MeetingAttributionArtifacts.previous(in: folder) : nil
        guard let outcomes = current ?? previous else { return nil }
        let state = MeetingOutcomeStore.loadState(from: folder)
        let followUp = MeetingOutcomeStore.loadFollowUp(from: folder)
            ?? FollowUpDraft.seeded(for: meeting, outcomes: outcomes)
        return Self(meeting: meeting, outcomes: outcomes, state: state, followUp: followUp, isArchived: current == nil)
    }
}

struct OutcomeActionReference: Identifiable, Equatable, Sendable {
    let meetingID: Meeting.ID
    let meetingTitle: String
    let meetingStartedAt: Date
    let action: MeetingOutcomes.ActionItem
    var status: OutcomeStatus
    var text: String
    var owner: String?
    var due: String?
    var stateUpdatedAt: Date
    var textWasCorrected: Bool
    var ownerWasCorrected: Bool
    var dueWasCorrected: Bool
    var textCorrectedAt: Date?
    var ownerCorrectedAt: Date?
    var dueCorrectedAt: Date?
    var isThreadExcluded = false

    var id: String { "\(meetingID.uuidString):\(action.id)" }
    var dueReferenceDate: Date {
        dueWasCorrected ? (dueCorrectedAt ?? stateUpdatedAt) : meetingStartedAt
    }
    var resolvedDueDate: Date? {
        ActionDuePresentation.date(due, spokenAt: dueReferenceDate)
    }
    var isForUser: Bool {
        if ownerWasCorrected {
            return owner?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Me") == .orderedSame
        }
        return action.isForUser && !action.ownershipIsUnclear
    }

    var effectiveAction: MeetingOutcomes.ActionItem {
        var result = action
        result.text = text
        result.owner = owner
        result.due = due
        result.isForUser = isForUser
        if ownerWasCorrected {
            result.attribution = OutcomeAttribution(resolution: isForUser ? .user : .other,
                basis: action.attribution?.basis ?? .assignment)
        }
        return result
    }
}
