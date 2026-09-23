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
                owner: userState.ownerOverride ?? action.owner,
                due: userState.dueOverride ?? action.due,
                stateUpdatedAt: userState.userEdited ? userState.updatedAt : meeting.startedAt,
                textWasCorrected: userState.textCorrection != nil,
                ownerWasCorrected: userState.ownerOverride != nil,
                dueWasCorrected: userState.dueOverride != nil,
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

    /// One loader for UI surfaces and background routines. Keeping the merge
    /// here prevents exports from silently falling back to immutable extraction
    /// after the user has completed or corrected an action in the app.
    static func load(for meeting: Meeting, storage: StorageManager) -> Self? {
        load(for: meeting, root: storage.rootURL)
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

/// Read model shared by Today, Timeline, Meetings, Ask, and Agent. Every
/// mutation is persisted atomically in the relevant meeting folder before the
/// published projection is replaced.
@MainActor
final class OutcomeIndex: ObservableObject {
    private var loadGeneration = 0
    private var projectionRevisions: [UUID: Int] = [:]
    @Published private(set) var projections: [Meeting.ID: MeetingOutcomeProjection] = [:]
    @Published private(set) var userActionThreads: [ActionThread] = []

    private let storage: StorageManager
    private let onEvidenceChanged: ([Meeting]) -> Void
    @Published private(set) var lastError: String?
    struct StatusChange {
        let meetingID: UUID
        let actionID: String
        let previous: OutcomeStatus
        let applied: OutcomeStatus
    }
    @Published private(set) var statusUndo: [StatusChange] = []

    init(
        storage: StorageManager,
        onEvidenceChanged: @escaping ([Meeting]) -> Void = { _ in }
    ) {
        self.storage = storage
        self.onEvidenceChanged = onEvidenceChanged
    }

    var all: [MeetingOutcomeProjection] {
        projections.values.sorted { $0.meeting.startedAt > $1.meeting.startedAt }
    }

    var openUserActions: [OutcomeActionReference] {
        all.flatMap(\.actionReferences)
            .filter { $0.isForUser && $0.status == .open }
            .sorted {
                let first = ActionDuePresentation.date($0.due) ?? .distantFuture
                let second = ActionDuePresentation.date($1.due) ?? .distantFuture
                return first == second ? $0.meetingStartedAt > $1.meetingStartedAt : first < second
            }
    }

    var openUserActionThreads: [ActionThread] {
        userActionThreads.filter { $0.status == .open }
    }

    func projection(for meetingID: Meeting.ID) -> MeetingOutcomeProjection? {
        projections[meetingID]
    }

    func refresh(meetings: [Meeting]) {
        loadGeneration &+= 1
        var next: [Meeting.ID: MeetingOutcomeProjection] = [:]
        for meeting in meetings {
            if let projection = loadProjection(for: meeting) {
                next[meeting.id] = projection
            }
        }
        projections = next
        rebuildActionThreads()
    }

    func refresh(meeting: Meeting) {
        replaceProjection(loadProjection(for: meeting), for: meeting.id)
    }

    func refreshInBackground(meetings: [Meeting]) async {
        loadGeneration &+= 1
        let generation = loadGeneration, revisions = projectionRevisions, root = storage.rootURL
        let loaded = await Task.detached(priority: .utility) {
            meetings.compactMap { MeetingOutcomeProjection.load(for: $0, root: root) }
        }.value
        guard !Task.isCancelled, generation == loadGeneration else { return }
        var next = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        // Preserve edits/refreshes made while file validation was running.
        for id in Set(projectionRevisions.keys).union(revisions.keys)
            where projectionRevisions[id] != revisions[id] {
            next[id] = projections[id]
        }
        guard next != projections else { return }
        projections = next
        rebuildActionThreads()
    }

    func refreshInBackground(meeting: Meeting) async {
        projectionRevisions[meeting.id, default: 0] &+= 1
        let generation = loadGeneration, revision = projectionRevisions[meeting.id], root = storage.rootURL
        let loaded = await Task.detached(priority: .userInitiated) {
            MeetingOutcomeProjection.load(for: meeting, root: root)
        }.value
        guard !Task.isCancelled, generation == loadGeneration,
              revision == projectionRevisions[meeting.id] else { return }
        replaceProjection(loaded, for: meeting.id)
    }

    private func replaceProjection(_ projection: MeetingOutcomeProjection?, for id: UUID) {
        projectionRevisions[id, default: 0] &+= 1
        guard projections[id] != projection else { return }
        projections[id] = projection
        rebuildActionThreads()
    }

    @discardableResult
    func setStatus(_ status: OutcomeStatus, actionID: String,
                   meetingID: Meeting.ID) -> Bool {
        guard let previous = projection(for: meetingID)?.actionReferences.first(where: { $0.action.id == actionID })?.status else { return false }
        let success = mutateAction(actionID: actionID, meetingID: meetingID) { state in
            state.status = status
            state.userEdited = true
        }
        if success {
            statusUndo = [StatusChange(meetingID: meetingID, actionID: actionID, previous: previous, applied: status)]
        }
        return success
    }

    @discardableResult
    func setStatus(_ status: OutcomeStatus, for references: [OutcomeActionReference]) -> [String] {
        var changes: [StatusChange] = []
        var failed: [String] = []
        for reference in references {
            if setStatus(status, actionID: reference.action.id, meetingID: reference.meetingID) {
                changes += statusUndo
            } else { failed.append(reference.text) }
        }
        statusUndo = changes
        if !failed.isEmpty { lastError = "Could not update: " + failed.joined(separator: "; ") }
        return failed
    }

    func dismissUndo() { statusUndo = [] }

    func undoStatusChange() {
        var remaining: [StatusChange] = []
        var failures: [String] = []
        for change in statusUndo {
            guard let current = projection(for: change.meetingID)?.actionReferences.first(where: { $0.action.id == change.actionID }),
                  current.status == change.applied else { continue }
            if !mutateAction(actionID: change.actionID, meetingID: change.meetingID, change: { $0.status = change.previous }) {
                remaining.append(change)
                failures.append(current.text)
            }
        }
        statusUndo = remaining
        // A later successful restore must not hide an earlier write failure.
        lastError = failures.isEmpty ? nil : "Could not undo: " + failures.joined(separator: "; ")
    }

    @discardableResult
    func setStatus(_ status: OutcomeStatus, thread: ActionThread) -> Bool {
        guard let current = userActionThreads.first(where: { $0.id == thread.id }),
              current == thread else {
            lastError = "The action thread changed. Review its sources and try again."
            return false
        }
        var changedMeetings: [Meeting] = []
        var changes: [StatusChange] = []
        defer {
            if !changes.isEmpty { statusUndo = changes }
        }
        for reference in thread.references where reference.status != status {
            guard mutateAction(
                actionID: reference.action.id,
                meetingID: reference.meetingID,
                notify: false,
                rebuildThreads: false,
                change: { state in
                    state.status = status
                    state.userEdited = true
                })
            else {
                rebuildActionThreads()
                notifyEvidenceChanged(changedMeetings)
                return false
            }
            changes.append(StatusChange(meetingID: reference.meetingID, actionID: reference.action.id,
                                        previous: reference.status, applied: status))
            if let meeting = projections[reference.meetingID]?.meeting {
                changedMeetings.append(meeting)
            }
        }
        rebuildActionThreads()
        notifyEvidenceChanged(changedMeetings)
        lastError = nil
        return true
    }

    @discardableResult
    func correctAction(actionID: String, meetingID: Meeting.ID,
                       text: String?, owner: String?, due: String?, reviewing meeting: Meeting? = nil) -> Bool {
        mutateAction(actionID: actionID, meetingID: meetingID, reviewing: meeting) { state in
            let now = Date().outcomePersistedTimestamp
            let text = Self.nilIfBlank(text)
            let owner = Self.nilIfBlank(owner)
            let due = Self.nilIfBlank(due)
            if state.textCorrection != text {
                state.textCorrection = text
                state.textCorrectedAt = text == nil ? nil : now
            }
            if state.ownerOverride != owner {
                state.ownerOverride = owner
                state.ownerCorrectedAt = owner == nil ? nil : now
            }
            if state.dueOverride != due {
                state.dueOverride = due
                state.dueCorrectedAt = due == nil ? nil : now
            }
            state.userEdited = true
        }
    }

    @discardableResult
    func setThreadExcluded(_ excluded: Bool, actionID: String, meetingID: Meeting.ID) -> Bool {
        mutateAction(actionID: actionID, meetingID: meetingID) { state in
            state.isThreadExcluded = excluded
            state.userEdited = true
        }
    }

    @discardableResult
    func saveFollowUp(_ draft: FollowUpDraft, meetingID: Meeting.ID) -> Bool {
        guard var projection = projections[meetingID] else { return false }
        var next = draft
        next.updatedAt = Date().outcomePersistedTimestamp
        next.seeded = false
        next.sourceMeetingID = meetingID
        do {
            try MeetingOutcomeStore.writeFollowUp(
                next, to: projection.meeting.folderURL(in: storage))
            projection.followUp = next
            projections[meetingID] = projection
            projectionRevisions[meetingID, default: 0] &+= 1
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func mutateAction(
        actionID: String,
        meetingID: Meeting.ID,
        reviewing meeting: Meeting? = nil,
        notify: Bool = true,
        rebuildThreads: Bool = true,
        change: (inout MeetingOutcomeState.ActionState) -> Void
    ) -> Bool {
        guard meeting == nil || meeting?.id == meetingID else {
            lastError = "This action belongs to a different meeting. Reopen it and try again."
            return false
        }
        let current = projections[meetingID]
        guard var projection = current ?? meeting.flatMap({ projectionForReview(of: $0) }),
              projection.outcomes.actionItems.contains(where: { $0.id == actionID })
        else {
            lastError = "This action is no longer available. Reopen the meeting's actions and try again."
            return false
        }
        var actionState = projection.state.actions[actionID] ?? .init()
        let previous = actionState
        change(&actionState)
        actionState.updatedAt = Date().outcomePersistedTimestamp
        projection.state.actions[actionID] = actionState
        do {
            try MeetingOutcomeStore.writeState(
                projection.state, to: projection.meeting.folderURL(in: storage))
            if !projection.isArchived,
               previous.ownerOverride != actionState.ownerOverride || previous.textCorrection != actionState.textCorrection {
                try MeetingAttributionArtifacts.invalidate(in: projection.meeting.folderURL(in: storage), preservingOutcomes: true)
            }
            // Archived extraction stays out of Today, Ask, and action threads.
            // Review can still persist corrections for the explicit refresh.
            if current != nil { projections[meetingID] = projection }
            projectionRevisions[meetingID, default: 0] &+= 1
            if rebuildThreads && !projection.isArchived { rebuildActionThreads() }
            lastError = nil
            if notify && !projection.isArchived { onEvidenceChanged([projection.meeting]) }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func loadProjection(for meeting: Meeting) -> MeetingOutcomeProjection? {
        MeetingOutcomeProjection.load(for: meeting, storage: storage)
    }

    func projectionForReview(of meeting: Meeting) -> MeetingOutcomeProjection? {
        projections[meeting.id] ?? MeetingOutcomeProjection.load(
            for: meeting, root: storage.rootURL, includingPrevious: true)
    }

    private func notifyEvidenceChanged(_ meetings: [Meeting]) {
        var notified: Set<Meeting.ID> = []
        let changed = meetings.filter { notified.insert($0.id).inserted }
        if !changed.isEmpty { onEvidenceChanged(changed) }
    }

    private func rebuildActionThreads() {
        userActionThreads = ActionThreadClusterer.cluster(
            all.flatMap(\.actionReferences)).filter(\.isForUser)
    }

    private static func nilIfBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
