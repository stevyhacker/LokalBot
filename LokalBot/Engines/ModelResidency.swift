import Foundation

/// App-wide ledger of which model weights are resident in memory, with a RAM
/// budget and least-recently-used eviction. The llama runtimes (`LlamaServer`
/// instances and the in-process cotyping runtime) register on load, touch on
/// reuse, and consult `willLoad` before pulling new weights in so the app
/// never silently stacks a summarizer, an embedder, and a cotyping model past
/// what the machine can hold.
///
/// GGUF rows include weights plus a role-specific cache/KV allowance. Retained
/// CoreML/MLX reservations are supplied as non-evictable bytes by
/// `ModelRuntimeRegistry`, so every local model load consults one RAM budget.
/// Eviction choices live in `ModelResidencyPolicy` (pure, unit-tested); this
/// class owns the mutable GGUF ledger and the `@Published` UI mirror.
@MainActor
final class ModelResidency: ObservableObject {

    static let shared = ModelResidency()

    struct Resident: Identifiable, Equatable {
        let id: String
        var label: String
        var bytes: Int64
        /// Present for out-of-process runtimes so diagnostics can report the
        /// helper's live footprint. In-process models leave this nil because the
        /// app footprint cannot be attributed to one model accurately.
        var processIdentifier: pid_t?
        /// Paired with the PID so a stale row can never be mistaken for an
        /// unrelated process after macOS reuses that identifier.
        var processStartTime: UInt64?
        var lastUsed: Date
    }

    struct LoadReservation: Identifiable, Equatable, Sendable {
        let id: UUID
        let residencyID: String
        let bytes: Int64
    }

    @Published private(set) var residents: [Resident] = []
    /// Residency ids currently pinned by open inference leases (pushed by
    /// `InferenceBroker`). Pinned rows are never eviction victims; they still
    /// count toward the budget. Descriptions are dashboard strings per id,
    /// e.g. "chat (interactive)".
    @Published private(set) var pinnedIDs: Set<String> = []
    @Published private(set) var leaseDescriptions: [String: [String]] = [:]
    /// Unload hooks by resident id, kept out of `Resident` so it stays a
    /// plain Equatable value for the UI.
    private var unloaders: [String: () async -> Void] = [:]
    /// A runtime can stop and restart while an older shutdown task is still
    /// finishing. Generations keep that stale task from unregistering the
    /// replacement model that now occupies the same logical residency id.
    private var registrationGenerations: [String: UUID] = [:]
    private var loadReservations: [UUID: LoadReservation] = [:]
    private var reservationExpiryTasks: [UUID: Task<Void, Never>] = [:]
    private var directPins: [UUID: String] = [:]
    private var brokerPins: Set<String> = []
    private var evictingIDs: Set<String> = []
    private var evictionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Weights budget: half of physical RAM by default, leaving the other
    /// half for the app, transcription engines, and everything else.
    var budgetBytes: Int64

    init(budgetBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory / 2)) {
        self.budgetBytes = budgetBytes
    }

    var totalBytes: Int64 { residents.reduce(0) { $0 + $1.bytes } }
    var pendingLoadBytes: Int64 {
        loadReservations.values.reduce(0) { Self.saturatingAdd($0, $1.bytes) }
    }

    func register(id: String, label: String, bytes: Int64,
                  processIdentifier: pid_t? = nil,
                  processStartTime: UInt64? = nil,
                  generation: UUID = UUID(),
                  unload: @escaping () async -> Void) {
        finishReservations(for: id)
        unloaders[id] = unload
        registrationGenerations[id] = generation
        let entry = Resident(
            id: id,
            label: label,
            bytes: bytes,
            processIdentifier: processIdentifier,
            processStartTime: processStartTime,
            lastUsed: Date()
        )
        if let index = residents.firstIndex(where: { $0.id == id }) {
            residents[index] = entry
        } else {
            residents.append(entry)
        }
    }

    func touch(id: String) {
        guard let index = residents.firstIndex(where: { $0.id == id }) else { return }
        residents[index].lastUsed = Date()
    }

    func setLeaseState(pinned: Set<String>, descriptions: [String: [String]]) {
        brokerPins = pinned
        pinnedIDs = pinned.union(directPins.values)
        leaseDescriptions = descriptions
    }

    /// Private runtimes participate in the same governor without requiring a
    /// broker role. Publish the pin before preparing or using their weights.
    func pin(id: String) async -> UUID {
        let token = UUID()
        directPins[token] = id
        pinnedIDs = brokerPins.union(directPins.values)
        await waitForEvictions(of: [id])
        return token
    }

    func waitForEvictions(of ids: Set<String>) async {
        for id in ids {
            while evictingIDs.contains(id) {
                await withCheckedContinuation { evictionWaiters[id, default: []].append($0) }
            }
        }
    }

    func unpin(_ token: UUID) {
        directPins[token] = nil
        pinnedIDs = brokerPins.union(directPins.values)
    }

    func unregister(id: String) {
        unloaders[id] = nil
        registrationGenerations[id] = nil
        residents.removeAll { $0.id == id }
    }

    /// Removes a row only if it is still the registration created by the
    /// caller. Used by subprocess shutdown paths, which can finish after a
    /// replacement process has already registered under the same id.
    func unregister(id: String, ifGenerationMatches generation: UUID) {
        guard registrationGenerations[id] == generation else { return }
        unregister(id: id)
    }

    /// Evict least-recently-used residents (never `id` itself — a model swap
    /// on the same runtime replaces in place) until `bytes` fits the budget.
    /// Call right before loading new weights.
    @discardableResult
    func willLoad(id: String, bytes: Int64, reservedBytes: Int64 = 0,
                  currentReservedBytes: (@MainActor () -> Int64)? = nil) async
        -> LoadReservation {
        let reservation = LoadReservation(
            id: UUID(), residencyID: id, bytes: max(0, bytes))
        loadReservations[reservation.id] = reservation
        scheduleReservationExpiry(reservation.id)
        while !Task.isCancelled {
            await waitForEvictions(of: evictingIDs)
            guard !Task.isCancelled else { break }
            // Every unload suspends. Rebuild the plan so a new pin, a smaller
            // replacement, or another admission cannot leave stale victims.
            let otherPendingBytes = loadReservations.values
                .filter { $0.id != reservation.id }
                .reduce(Int64(0)) { Self.saturatingAdd($0, $1.bytes) }
            let allReservedBytes = Self.saturatingAdd(
                max(0, currentReservedBytes?() ?? reservedBytes), otherPendingBytes)
            guard let victim = ModelResidencyPolicy.evictions(
                residents: residents.map { .init(id: $0.id, bytes: $0.bytes, lastUsed: $0.lastUsed) },
                incomingID: id, incomingBytes: bytes, reservedBytes: allReservedBytes,
                pinned: pinnedIDs, budgetBytes: budgetBytes).first else { break }
            let unload = unloaders[victim]
            let label = residents.first { $0.id == victim }?.label ?? victim
            lokalbotLog("model residency: evicting \(label) to fit incoming load")
            // Drop the ledger row first so the victim's own unregister call
            // (from its unload path) is a harmless no-op.
            evictingIDs.insert(victim)
            unregister(id: victim)
            await unload?()
            evictingIDs.remove(victim)
            let waiters = evictionWaiters.removeValue(forKey: victim) ?? []
            waiters.forEach { $0.resume() }
        }
        return reservation
    }

    func cancelLoad(_ reservation: LoadReservation) {
        reservationExpiryTasks[reservation.id]?.cancel()
        reservationExpiryTasks[reservation.id] = nil
        loadReservations[reservation.id] = nil
    }

    private func finishReservations(for residencyID: String) {
        let ids = loadReservations.values
            .filter { $0.residencyID == residencyID }
            .map(\.id)
        for id in ids {
            reservationExpiryTasks[id]?.cancel()
            reservationExpiryTasks[id] = nil
            loadReservations[id] = nil
        }
    }

    private func scheduleReservationExpiry(_ id: UUID) {
        reservationExpiryTasks[id]?.cancel()
        reservationExpiryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.loadReservations[id] = nil
            self?.reservationExpiryTasks[id] = nil
        }
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    /// File size of the weights at `url` (0 if unreadable) — the bytes every
    /// caller registers with, so ledger entries stay comparable.
    nonisolated static func weightBytes(at url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    }
}

/// The eviction decision, kept pure for unit tests.
enum ModelResidencyPolicy {

    struct Entry: Equatable {
        let id: String
        let bytes: Int64
        let lastUsed: Date
    }

    /// IDs to evict, least-recently-used first, so the surviving residents
    /// plus the incoming load fit `budgetBytes`. The incoming id is never a
    /// victim, and neither is any pinned id — an open inference lease means a
    /// request is running against those weights right now. Pinned bytes still
    /// count toward the total, so admission stays honest. When the newcomer
    /// alone exceeds the budget, everything unpinned is evicted and the load
    /// proceeds best-effort — refusing to load would break the feature the
    /// user just asked for.
    static func evictions(residents: [Entry], incomingID: String,
                          incomingBytes: Int64, reservedBytes: Int64 = 0,
                          pinned: Set<String> = [],
                          budgetBytes: Int64) -> [String] {
        let kept = residents.filter { $0.id != incomingID }
        var total = kept.reduce(0) { $0 + $1.bytes }
        total = total.addingReportingOverflow(max(0, incomingBytes)).overflow
            ? .max : total + max(0, incomingBytes)
        total = total.addingReportingOverflow(max(0, reservedBytes)).overflow
            ? .max : total + max(0, reservedBytes)
        guard total > budgetBytes else { return [] }
        var victims: [String] = []
        for entry in kept.sorted(by: { $0.lastUsed < $1.lastUsed })
        where !pinned.contains(entry.id) {
            guard total > budgetBytes else { break }
            victims.append(entry.id)
            total -= entry.bytes
        }
        return victims
    }
}
