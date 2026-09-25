import Foundation

/// One actor owns when the shared llama-server runtimes start and stop.
/// Consumers take leases instead of calling `ensureRunning` directly: a
/// lease boots on demand, pins the model during use, and makes the server
/// eligible for an idle unload after the final release.
actor InferenceBroker {

    /// Start/stop hooks for one role. Tests inject recorders rather than
    /// launching real llama-server processes.
    struct RuntimeHooks {
        let ensure: (URL) async throws -> Void
        let stop: () async -> Void
    }

    static let shared = InferenceBroker()

    private let hooks: [InferenceRole: RuntimeHooks]
    private let lingerSeconds: [InferenceRole: TimeInterval]
    private let leaseStateSink: @MainActor (Set<String>, [String: [String]]) async -> Void

    private var book = LeaseBook()
    private var generations: [InferenceRole: UInt64] = [:]
    private var lingerTasks: [InferenceRole: Task<Void, Never>] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]
    private struct ModelWaiter {
        let id: UUID
        let modelPath: String
        let priority: InferencePriority
        let order: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    private var modelWaiters: [InferenceRole: [ModelWaiter]] = [:]
    private var nextWaiterOrder: UInt64 = 0
    /// Claims the role for a model before the first lease record is inserted,
    /// closing the actor-reentrancy gap between waking a cohort and acquisition.
    private var selectedModelPaths: [InferenceRole: String] = [:]

    init(hooks: [InferenceRole: RuntimeHooks]? = nil,
         lingerSeconds: [InferenceRole: TimeInterval] = [:],
         leaseStateSink: (@MainActor (Set<String>, [String: [String]]) async -> Void)? = nil) {
        self.hooks = hooks ?? [
            .mainLLM: RuntimeHooks(
                ensure: { try await LlamaServer.shared.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.shared.stop() }),
            .embedder: RuntimeHooks(
                ensure: { try await LlamaServer.embedder.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.embedder.stop() }),
            .cotypingServer: RuntimeHooks(
                ensure: { try await LlamaServer.cotyping.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.cotyping.stop() }),
        ]
        self.lingerSeconds = lingerSeconds
        self.leaseStateSink = leaseStateSink ?? { pinned, descriptions in
            ModelResidency.shared.setLeaseState(pinned: pinned, descriptions: descriptions)
            await ModelResidency.shared.waitForEvictions(of: pinned)
        }
    }

    /// Records and publishes the pin before ensuring the runtime. If ensure
    /// fails, the record is removed and the original runtime error propagates.
    func lease(_ role: InferenceRole, model: URL, priority: InferencePriority,
               purpose: String,
               expiresAfter ttl: TimeInterval? = nil) async throws -> InferenceLease {
        let modelPath = Self.canonicalModelPath(model)
        let queued = ProcessInfo.processInfo.systemUptime
        try await waitUntilCompatible(role: role, modelPath: modelPath, priority: priority)
        let queueSeconds = ProcessInfo.processInfo.systemUptime - queued
        do {
            try Task.checkCancellation()
        } catch {
            releaseModelTurnIfUnused(role)
            throw error
        }
        generations[role, default: 0] += 1
        lingerTasks[role]?.cancel()
        lingerTasks[role] = nil
        let expiresAt = ttl.map { Date().addingTimeInterval($0) }
        let lease = book.acquire(role: role, modelPath: modelPath,
                                 priority: priority, purpose: purpose,
                                 expiresAt: expiresAt)
        await MeetingGenerationBudget.current?.recordPhase("runtimeQueue", seconds: queueSeconds)
        await pushLeaseState()
        let preparationStarted = ProcessInfo.processInfo.systemUptime
        do {
            try await runtimeHooks(for: role).ensure(model)
            try Task.checkCancellation()
            await MeetingGenerationBudget.current?.recordPhase("runtimePreparation", seconds: ProcessInfo.processInfo.systemUptime - preparationStarted)
        } catch {
            await MeetingGenerationBudget.current?.recordPhase("runtimePreparation", seconds: ProcessInfo.processInfo.systemUptime - preparationStarted)
            book.release(id: lease.id)
            await pushLeaseState()
            if book.activeCount(for: role) == 0 {
                // ensure may already have started the runtime before the task
                // was cancelled. Treat rollback like the final release so a
                // zero-lease server cannot remain resident indefinitely.
                scheduleLinger(for: role)
                releaseModelTurnIfUnused(role)
            }
            throw error
        }
        if let ttl { scheduleExpiry(for: lease, after: ttl) }
        return lease
    }

    func release(_ lease: InferenceLease) async {
        expiryTasks[lease.id]?.cancel()
        expiryTasks[lease.id] = nil
        guard book.release(id: lease.id) else { return }
        await pushLeaseState()
        if book.activeCount(for: lease.role) == 0 {
            scheduleLinger(for: lease.role)
            releaseModelTurnIfUnused(lease.role)
        }
    }

    /// Acquires one scoped lease and releases it on success or error.
    nonisolated func withLease<T>(_ role: InferenceRole, model: URL,
                                  priority: InferencePriority, purpose: String,
                                  _ body: () async throws -> T) async throws -> T {
        let acquired = try await lease(role, model: model, priority: priority,
                                       purpose: purpose)
        do {
            let value = try await body()
            await release(acquired)
            return value
        } catch {
            await release(acquired)
            throw error
        }
    }

    func activeLeaseCount(_ role: InferenceRole) -> Int {
        book.activeCount(for: role)
    }

    func activeModelPath(_ role: InferenceRole) -> String? {
        selectedModelPaths[role]
    }

    private func waitUntilCompatible(
        role: InferenceRole,
        modelPath: String,
        priority: InferencePriority
    ) async throws {
        while let active = selectedModelPaths[role], active != modelPath {
            let waiterID = UUID()
            nextWaiterOrder &+= 1
            let order = nextWaiterOrder
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    modelWaiters[role, default: []].append(ModelWaiter(
                        id: waiterID,
                        modelPath: modelPath,
                        priority: priority,
                        order: order,
                        continuation: continuation))
                }
            } onCancel: {
                Task { [weak self] in await self?.cancelWaiter(id: waiterID, role: role) }
            }
        }
        if selectedModelPaths[role] == nil {
            selectedModelPaths[role] = modelPath
        }
    }

    private func cancelWaiter(id: UUID, role: InferenceRole) {
        guard let index = modelWaiters[role]?.firstIndex(where: { $0.id == id }),
              let waiter = modelWaiters[role]?.remove(at: index) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if modelWaiters[role]?.isEmpty == true { modelWaiters[role] = nil }
    }

    /// When a role becomes free, admit one model cohort. All callers waiting
    /// for those same weights can share the server; different weights remain
    /// queued until the cohort releases every lease.
    private func resumeEligibleWaiters(for role: InferenceRole) {
        guard selectedModelPaths[role] == nil,
              book.activeCount(for: role) == 0,
              let waiting = modelWaiters[role], !waiting.isEmpty else { return }
        let selected = waiting.min {
            ($0.priority.rawValue, $0.order) < ($1.priority.rawValue, $1.order)
        }!
        let admitted = waiting.filter { $0.modelPath == selected.modelPath }
        selectedModelPaths[role] = selected.modelPath
        modelWaiters[role] = waiting.filter { $0.modelPath != selected.modelPath }
        if modelWaiters[role]?.isEmpty == true { modelWaiters[role] = nil }
        for waiter in admitted { waiter.continuation.resume() }
    }

    private func releaseModelTurnIfUnused(_ role: InferenceRole) {
        guard book.activeCount(for: role) == 0 else { return }
        selectedModelPaths[role] = nil
        resumeEligibleWaiters(for: role)
    }

    private nonisolated static func canonicalModelPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func scheduleLinger(for role: InferenceRole) {
        let generation = generations[role, default: 0]
        let delay = lingerSeconds[role] ?? role.defaultLingerSeconds
        lingerTasks[role] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.lingerFired(role: role, generation: generation)
        }
    }

    private func lingerFired(role: InferenceRole, generation: UInt64) async {
        guard generations[role, default: 0] == generation,
              book.activeCount(for: role) == 0 else { return }
        lingerTasks[role] = nil
        lokalbotLog("inference broker: stopping idle \(role.rawValue) after linger")
        await runtimeHooks(for: role).stop()
    }

    private func scheduleExpiry(for lease: InferenceLease, after ttl: TimeInterval) {
        expiryTasks[lease.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expiryFired(leaseID: lease.id)
        }
    }

    private func expiryFired(leaseID: UUID) async {
        guard let record = book.record(id: leaseID),
              let expiresAt = record.expiresAt, expiresAt <= Date() else { return }
        await release(record.lease)
    }

    private func runtimeHooks(for role: InferenceRole) -> RuntimeHooks {
        guard let roleHooks = hooks[role] else {
            preconditionFailure("no runtime hooks for \(role.rawValue)")
        }
        return roleHooks
    }

    private func pushLeaseState() async {
        let pinned = book.pinnedResidencyIDs
        let descriptions = book.descriptionsByResidencyID
        await leaseStateSink(pinned, descriptions)
    }
}
