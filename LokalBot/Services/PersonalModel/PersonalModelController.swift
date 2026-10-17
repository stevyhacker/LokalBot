import Combine
import Foundation

/// The app's single owner of the personal model. Ask reads and adds claims
/// through it; Settings → Day Memory → About you edits them; the overnight
/// review adds learned ones. Loads lazily on first use so launch never
/// touches the Keychain for it. If the saved file can't be read, every edit
/// is refused instead of overwriting it. Learned claims are checked against
/// the Dream evidence revisions on every use: a deleted or corrected meeting
/// retracts them, and while a revocation is pending they are withheld.
@MainActor
final class PersonalModelController: ObservableObject {
    @Published private(set) var claims: [PersonalClaim] = []
    @Published private(set) var loadError: String?

    private let store: PersonalModelStore
    private let now: () -> Date
    private let evidenceCheck: () -> ((DreamEvidenceProvenance) -> Bool)?
    private var model = PersonalModel()
    private var loaded = false
    private var writable = false
    /// Called after every saved change, forget-all and reload, so the
    /// agent-facing projection never lags behind (nil claims: unreadable).
    var onChange: ((_ claims: [PersonalClaim]?) -> Void)?

    init(store: PersonalModelStore, now: @escaping () -> Date = Date.init,
         evidenceCheck: @escaping () -> ((DreamEvidenceProvenance) -> Bool)? = { { _ in false } }) {
        self.store = store
        self.now = now
        self.evidenceCheck = evidenceCheck
    }

    /// Newest first, the order Settings shows.
    var orderedClaims: [PersonalClaim] {
        loadIfNeeded()
        return claims.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Everything stored, suggestions included.
    func currentClaims() -> [PersonalClaim] {
        loadIfNeeded()
        return claims
    }

    /// Learned suggestions waiting for review, newest first.
    var suggestions: [PersonalClaim] {
        loadIfNeeded()
        return claims.filter { $0.status == .proposed }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Confirmed claims safe to put in a prompt now. Scoped Ask questions pass
    /// `includeEvidenceBacked: false`: like work memory, learned claims would
    /// carry meeting content past the question's source boundary.
    func usableClaims(includeEvidenceBacked: Bool = true) -> [PersonalClaim] {
        loadIfNeeded()
        let evidenceUsable = includeEvidenceBacked && retractInvalidated()
        return model.claims.filter { claim in
            claim.status == .confirmed && (claim.evidence == nil || evidenceUsable)
        }
    }

    /// The claims agents may be offered, or nil when the saved file couldn't
    /// be read. Agent access fails closed on nil instead of "nothing shared".
    func readableClaims() -> [PersonalClaim]? {
        loadIfNeeded()
        guard writable else { return nil }
        retractInvalidated()
        return agentEligibleClaims()
    }

    /// Removes learned claims whose meeting was deleted or corrected since.
    /// False when evidence can't be checked (a revocation is pending), so
    /// callers withhold evidence-backed claims meanwhile.
    @discardableResult
    func retractInvalidated() -> Bool {
        loadIfNeeded()
        guard model.claims.contains(where: { $0.evidence != nil }) else { return true }
        guard let check = evidenceCheck() else { return false }
        var stale: Set<UUID> = []
        for claim in model.claims {
            if let evidence = claim.evidence, check(evidence) { stale.insert(claim.id) }
        }
        guard !stale.isEmpty else { return true }
        let result: Result<Void, PersonalModel.EditError> = mutate { model, _ in
            model.retract(ids: stale)
            return .success(())
        }
        if case .failure = result { return false }
        return true
    }

    /// After a meeting is deleted or corrected. Skips an unloaded model:
    /// every read checks evidence anyway, so there is nothing to clean yet.
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

    /// The overnight review's findings: facts and goals are saved, preferences
    /// become suggestions. Expired suggestions and tombstones are pruned.
    @discardableResult
    func learn(_ candidates: [PersonalModel.LearningCandidate]) -> PersonalModel.LearningOutcome {
        var outcome = PersonalModel.LearningOutcome()
        _ = mutate { model, date in
            model.prune(now: date)
            outcome = model.learn(candidates, now: date)
            return .success(())
        }
        return outcome
    }

    /// Suggests goals and projects the overnight review has kept for weeks.
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

    /// Deleting an Ask conversation takes back what was learned from it.
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

    /// Stamps claims that went into an answer. Best effort: a failed write
    /// only loses the timestamp.
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
