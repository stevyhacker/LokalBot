import Combine
import Foundation

@MainActor
final class PersonalModelController: ObservableObject {
    @Published private(set) var claims: [PersonalClaim] = []
    @Published private(set) var loadError: String?

    private let store: PersonalModelStore
    private let now: () -> Date
    private let evidenceCheck: () -> ((DreamEvidenceProvenance) -> Bool)?
    private let sourceStillQuotes: (PersonalClaim) -> Bool
    private let currentRevision: () -> UInt64?
    private var model = PersonalModel()
    private var loaded = false
    private var writable = false
    var onChange: ((_ claims: [PersonalClaim]?) -> Void)?

    init(store: PersonalModelStore, now: @escaping () -> Date = Date.init,
         evidenceCheck: @escaping () -> ((DreamEvidenceProvenance) -> Bool)? = { { _ in false } },
         sourceStillQuotes: @escaping (PersonalClaim) -> Bool = { _ in false },
         currentRevision: @escaping () -> UInt64? = { nil }) {
        self.store = store
        self.now = now
        self.evidenceCheck = evidenceCheck
        self.sourceStillQuotes = sourceStillQuotes
        self.currentRevision = currentRevision
    }

    var orderedClaims: [PersonalClaim] {
        loadIfNeeded()
        return claims.sorted { $0.updatedAt > $1.updatedAt }
    }

    func currentClaims() -> [PersonalClaim] {
        loadIfNeeded()
        return claims
    }

    var suggestions: [PersonalClaim] {
        loadIfNeeded()
        return claims.filter { $0.status == .proposed }.sorted { $0.createdAt > $1.createdAt }
    }

    func usableClaims(includeEvidenceBacked: Bool = true) -> [PersonalClaim] {
        loadIfNeeded()
        let evidenceUsable = includeEvidenceBacked && retractInvalidated()
        return model.claims.filter { claim in
            guard claim.status == .confirmed else { return false }
            if includeEvidenceBacked { return claim.evidence == nil || evidenceUsable }
            return claim.evidence == nil && claim.authority == .stated
        }
    }

    func readableClaims() -> [PersonalClaim]? {
        loadIfNeeded()
        guard writable else { return nil }
        retractInvalidated()
        return agentEligibleClaims()
    }

    @discardableResult
    func retractInvalidated() -> Bool {
        loadIfNeeded()
        guard model.claims.contains(where: { $0.evidence != nil }) else { return true }
        guard let check = evidenceCheck() else { return false }
        let changed = model.claims.filter { claim in claim.evidence.map(check) ?? false }
        guard !changed.isEmpty else { return true }
        let revision = currentRevision()
        var kept: Set<UUID> = []
        var stale: Set<UUID> = []
        for claim in changed {
            if revision != nil, sourceStillQuotes(claim) { kept.insert(claim.id) } else { stale.insert(claim.id) }
        }
        let result: Result<Void, PersonalModel.EditError> = mutate { model, _ in
            if let revision { model.refreshEvidence(ids: kept, revision: revision) }
            model.retract(ids: stale)
            return .success(())
        }
        if case .failure = result { return false }
        return true
    }

    func retractIfLoaded() {
        guard loaded else { return }
        retractInvalidated()
    }

    private func agentEligibleClaims() -> [PersonalClaim]? {
        guard writable else { return nil }
        let check = model.claims.contains { $0.evidence != nil } ? evidenceCheck() : nil
        return model.claims.filter { claim in
            guard claim.status == .confirmed else { return false }
            guard let evidence = claim.evidence else { return true }
            guard let check else { return false }
            return !check(evidence)
        }
    }

    func claim(id: UUID) -> PersonalClaim? {
        loadIfNeeded()
        return claims.first { $0.id == id }
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        reload()
    }

    func reload() {
        loaded = true
        do {
            model = try store.load()
            writable = true
            loadError = nil
        } catch {
            model = PersonalModel()
            writable = false
            loadError = Self.message(for: error)
            lokalbotLog("personal model load failed: \(error)")
        }
        claims = model.claims
        onChange?(agentEligibleClaims())
    }

    @discardableResult
    func remember(_ text: String, kind: PersonalClaim.Kind? = nil,
                  origin: PersonalClaim.Origin) -> Result<PersonalClaim, PersonalModel.EditError> {
        mutate { model, date in
            model.add(text, kind: kind ?? PersonalClaim.Kind.suggested(for: text), origin: origin, now: date)
        }
    }

    @discardableResult
    func update(_ id: UUID, text: String? = nil, kind: PersonalClaim.Kind? = nil,
                alwaysUse: Bool? = nil,
                sharing: PersonalClaim.Sharing? = nil) -> Result<PersonalClaim, PersonalModel.EditError> {
        mutate { model, date in
            model.update(id: id, text: text, kind: kind, alwaysUse: alwaysUse, sharing: sharing, now: date)
        }
    }

    @discardableResult
    func forget(_ ids: Set<UUID>) -> Result<Void, PersonalModel.EditError> {
        mutate { model, date in
            model.remove(ids: ids, now: date)
            return .success(())
        }
    }

    @discardableResult
    func learn(_ candidates: [PersonalModel.LearningCandidate], dayKey: String? = nil,
               fingerprint: String? = nil) -> PersonalModel.LearningOutcome {
        var outcome = PersonalModel.LearningOutcome()
        _ = mutate { model, date in
            model.prune(now: date)
            outcome = model.learn(candidates, now: date)
            if let dayKey, let fingerprint { model.recordLearned(dayKey: dayKey, fingerprint: fingerprint, at: date) }
            return .success(())
        }
        return outcome
    }

    func hasLearned(dayKey: String, fingerprint: String) -> Bool {
        loadIfNeeded()
        return model.hasLearned(dayKey: dayKey, fingerprint: fingerprint)
    }

    @discardableResult
    func promoteWorkMemory(_ memory: DreamMemory, dayKey: String,
                           calendar: Calendar = .current) -> PersonalModel.LearningOutcome {
        var outcome = PersonalModel.LearningOutcome()
        _ = mutate { model, date in
            let result = WorkMemoryPromotion.evaluate(
                memory: memory, sightings: model.workSightings, dayKey: dayKey, calendar: calendar)
            model.workSightings = result.sightings
            outcome = model.learn(result.candidates, now: date)
            return .success(())
        }
        return outcome
    }

    func retractLearned(fromConversation conversationID: UUID) {
        _ = mutate { model, _ in
            model.retract(learnedFromConversation: conversationID)
            return .success(())
        }
    }

    @discardableResult
    func confirm(_ id: UUID) -> Result<PersonalClaim, PersonalModel.EditError> {
        mutate { model, date in model.confirm(id: id, now: date) }
    }

    @discardableResult
    func confirm(_ ids: Set<UUID>) -> Result<Void, PersonalModel.EditError> {
        mutate { model, date in
            for id in ids {
                if case .failure(let failure) = model.confirm(id: id, now: date) { return .failure(failure) }
            }
            return .success(())
        }
    }

    @discardableResult
    func dismiss(_ id: UUID) -> Result<Void, PersonalModel.EditError> {
        mutate { model, date in
            model.dismiss(id: id, now: date)
            return .success(())
        }
    }

    @discardableResult
    func keepAsStatement(_ id: UUID) -> Result<PersonalClaim, PersonalModel.EditError> {
        mutate { model, date in model.keepAsStatement(id: id, now: date) }
    }

    @discardableResult
    func forgetAll() -> Result<Void, PersonalModel.EditError> {
        loadIfNeeded()
        do {
            try store.deleteAll()
        } catch {
            lokalbotLog("personal model delete failed: \(error)")
            return .failure(.unavailable)
        }
        model = PersonalModel()
        claims = []
        writable = true
        loadError = nil
        onChange?(claims)
        return .success(())
    }

    func markUsed(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        _ = mutate { model, date in
            model.markUsed(ids: ids, at: date)
            return .success(())
        }
    }

    private func mutate<T>(
        _ body: (inout PersonalModel, Date) -> Result<T, PersonalModel.EditError>
    ) -> Result<T, PersonalModel.EditError> {
        loadIfNeeded()
        guard writable else { return .failure(.unavailable) }
        var updated = model
        let result = body(&updated, now())
        guard case .success = result, updated != model else { return result }
        do {
            try store.save(updated)
        } catch {
            lokalbotLog("personal model save failed: \(error)")
            return .failure(.unavailable)
        }
        model = updated
        claims = updated.claims
        onChange?(agentEligibleClaims())
        return result
    }

    private static func message(for error: Error) -> String {
        switch error as? PersonalModelStore.LoadError {
        case .keyUnavailable:
            "LokalBot couldn't unlock what it remembers about you. It's kept as is and nothing new is saved until it can."
        case .newerVersion:
            "What LokalBot remembers about you was saved by a newer version. Update LokalBot to change it."
        case .unreadable, nil:
            "LokalBot couldn't read what it remembers about you. The file is kept as is and nothing new is saved."
        }
    }
}
