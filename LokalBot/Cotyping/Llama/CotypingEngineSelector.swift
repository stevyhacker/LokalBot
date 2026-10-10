import Foundation

/// Per-completion router between the in-process `LocalLlamaCotypingEngine`
/// (built-in GGUF on Apple Silicon, flag on) and the existing HTTP
/// `CotypingEngine` (non-GGUF backends, flag off, or in-process load failure).
/// Conforms to `CotypingCompleting`, so `CotypingCoordinator` is unchanged.
@MainActor
final class CotypingEngineSelector: CotypingCompleting {
    typealias ModelVerifier = (ModelCatalog.Entry, StorageManager) async -> URL?

    /// How long completions stay on HTTP after an in-process failure before
    /// the local engine is rebuilt and retried. Long enough that a persistent
    /// failure doesn't reload the selected model's weights on every keystroke, short
    /// enough that a transient one (memory pressure passing) recovers soon.
    static let localRetryCooldown: TimeInterval = 60

    private let http: CotypingCompleting
    private let makeLocal: (String, Bool) -> CotypingCompleting
    private let settings: () -> AppSettings
    private let storage: StorageManager
    private let now: () -> Date
    private let verifyModel: ModelVerifier
    private var local: CotypingCompleting?
    private var localModelPath: String?
    private var localIdentity: LocalRouteIdentity?
    /// Set after the first in-process failure so the HTTP fallback is logged
    /// once per failure episode (spec §13), not on every keystroke. Reset on a
    /// successful local generation or a model-path change.
    private var didLogLocalFailure = false
    /// Non-nil while a failure cooldown is active: `localIfEligible()` routes
    /// to HTTP (without rebuilding the local engine) until this instant.
    private var retryLocalAt: Date?

    /// Invalidates work that crossed an actor suspension under an older route.
    /// `@MainActor` prevents simultaneous mutation, but async model verification
    /// and unloads are re-entrant: an explicit `unload()` can run while an older
    /// generate/prewarm is awaiting verification. Without a generation check,
    /// that older operation could resume and recreate the local runtime after
    /// shutdown completed.
    private var lifecycleGeneration: UInt64 = 0
    /// Keeps new route resolution out until every overlapping explicit unload
    /// has stopped both runtimes.
    private var unloadOperationsInFlight = 0
    /// Coalesces local teardown across re-entrant route changes so a second
    /// completion cannot start HTTP while the first is still freeing weights.
    private var localUnloadTask: Task<Void, Never>?
    private var localUnloadOperation: UInt64 = 0

    /// The setting and catalog entry together identify the route being
    /// resolved. Including the requested ID matters because an unknown ID
    /// falls back to the recommended entry; changing between two bad IDs must
    /// still invalidate an already-suspended lookup.
    private struct LocalRouteIdentity: Equatable {
        let requestedModelID: String
        let entry: ModelCatalog.Entry
        let selectiveOneWordHybrid: Bool
    }

    /// The actual resolved route, not merely the user's preferred setting.
    /// A local failure clears `local` and starts a cooldown before HTTP runs,
    /// which immediately restores the conservative model-server debounce.
    var debounceProfile: CotypingDebouncePolicy.RuntimeProfile {
        local != nil && retryLocalAt == nil ? .inProcess : .modelServer
    }

    init(
        http: CotypingCompleting,
        makeLocal: @escaping (String, Bool) -> CotypingCompleting,
        settings: @escaping () -> AppSettings,
        storage: StorageManager,
        now: @escaping () -> Date = { Date() },
        verifyModel: @escaping ModelVerifier = { entry, storage in
            await ModelDownloadManager.shared.verifiedExistingURL(entry, storage: storage)
        }
    ) {
        self.http = http
        self.makeLocal = makeLocal
        self.settings = settings
        self.storage = storage
        self.now = now
        self.verifyModel = verifyModel
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    nonisolated static func shouldUseLocal(settings: AppSettings, modelURL: URL?, isAppleSilicon: Bool) -> Bool {
        settings.cotypingInProcessRuntime && isAppleSilicon && modelURL != nil
    }

    private func localRouteIdentity(for settings: AppSettings) -> LocalRouteIdentity? {
        guard let entry = ModelCatalog.entry(
            id: settings.cotypingBuiltInModelID,
            custom: settings.customBuiltInModels
        ) ?? ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID) else { return nil }
        return LocalRouteIdentity(requestedModelID: settings.cotypingBuiltInModelID, entry: entry,
                                  selectiveOneWordHybrid: settings.cotypingSelectiveOneWordHybrid)
    }

    /// Resolves the built-in cotyping model path the same way `makeTextEngine` does.
    private func resolvedModelURL(_ identity: LocalRouteIdentity) async -> URL? {
        await verifyModel(identity.entry, storage)
    }

    @discardableResult
    private func invalidateLifecycle() -> UInt64 {
        lifecycleGeneration += 1
        return lifecycleGeneration
    }

    private func requireCurrentLocalRoute(
        generation: UInt64,
        identity: LocalRouteIdentity
    ) throws {
        guard !Task.isCancelled,
              unloadOperationsInFlight == 0,
              lifecycleGeneration == generation else {
            throw CancellationError()
        }
        let currentSettings = settings()
        guard currentSettings.cotypingInProcessRuntime,
              Self.isAppleSilicon,
              localRouteIdentity(for: currentSettings) == identity else {
            throw CancellationError()
        }
    }

    private func requireCurrentDisabledRoute(generation: UInt64) throws {
        guard !Task.isCancelled,
              unloadOperationsInFlight == 0,
              lifecycleGeneration == generation else {
            throw CancellationError()
        }
        guard !settings().cotypingInProcessRuntime || !Self.isAppleSilicon else {
            throw CancellationError()
        }
    }

    private func requireCurrentMissingIdentityRoute(generation: UInt64) throws {
        guard !Task.isCancelled,
              unloadOperationsInFlight == 0,
              lifecycleGeneration == generation,
              localRouteIdentity(for: settings()) == nil else { throw CancellationError() }
    }

    /// Returns the local engine if eligible, lazily (re)building it when the
    /// resolved model path changes; nil → use HTTP.
    private func localIfEligible() async throws -> CotypingCompleting? {
        guard unloadOperationsInFlight == 0 else { throw CancellationError() }
        let s = settings()
        // Short-circuit the cheap gating conditions before resolving and, for a
        // legacy download, hashing the GGUF. Users with local cotyping disabled
        // should not pay that integrity-check cost.
        guard s.cotypingInProcessRuntime, Self.isAppleSilicon else {
            let invalidation = invalidateLifecycle()
            await dropLocalEngine()
            try requireCurrentDisabledRoute(generation: invalidation)
            return nil
        }
        // Failure cooldown: the engine was already dropped (weights freed) in
        // handleLocalFailure, so just route to HTTP until the retry instant.
        if let retryLocalAt, now() < retryLocalAt { return nil }
        guard let identity = localRouteIdentity(for: s) else {
            let invalidation = invalidateLifecycle()
            await dropLocalEngine()
            try requireCurrentMissingIdentityRoute(generation: invalidation)
            return nil
        }

        var generation = lifecycleGeneration
        guard let url = await resolvedModelURL(identity) else {
            try requireCurrentLocalRoute(generation: generation, identity: identity)
            let invalidation = invalidateLifecycle()
            await dropLocalEngine()
            try requireCurrentLocalRoute(generation: invalidation, identity: identity)
            return nil
        }
        try requireCurrentLocalRoute(generation: generation, identity: identity)
        guard
              Self.shouldUseLocal(settings: s, modelURL: url, isAppleSilicon: Self.isAppleSilicon)
        else {
            let invalidation = invalidateLifecycle()
            await dropLocalEngine()
            try requireCurrentLocalRoute(generation: invalidation, identity: identity)
            return nil
        }
        if let local, localModelPath == url.path, localIdentity == identity { return local }
        if local == nil || localModelPath != url.path || localIdentity != identity {
            // A model change must release the old in-process weights before a
            // replacement is built. The old implementation overwrote `local`
            // and leaked its runtime until deinit happened to run.
            if local != nil || localModelPath != nil {
                generation = invalidateLifecycle()
            }
            // Also joins an unload started by another re-entrant route change.
            // `local == nil` only means ownership was taken, not that the old
            // model has finished releasing its weights.
            await dropLocalEngine()
            try requireCurrentLocalRoute(generation: generation, identity: identity)
            // The HTTP fallback may still hold the same model from a prior
            // failure, a previous setting, or an adopted server from an older
            // app process. Stop it before the local runtime starts loading.
            await http.unload()
            try requireCurrentLocalRoute(generation: generation, identity: identity)
            // A concurrent lookup may have installed this exact route while
            // this operation was suspended in `http.unload()`. Reuse it rather
            // than overwriting a live engine and orphaning its loaded weights.
            if let local {
                guard localModelPath == url.path, localIdentity == identity else { throw CancellationError() }
                return local
            }
            local = makeLocal(url.path, identity.selectiveOneWordHybrid)
            localModelPath = url.path
            localIdentity = identity
            didLogLocalFailure = false
        }
        return local
    }

    private func takeLocalEngine() -> CotypingCompleting? {
        guard let engine = local else { return nil }
        local = nil
        localModelPath = nil
        localIdentity = nil
        return engine
    }

    /// Drops the cached in-process engine and frees its loaded model when the
    /// selector routes away from local (flag toggled off, Intel, or the model
    /// stops resolving). Self-limiting: a no-op once already dropped, so it's
    /// safe to call on every ineligible `localIfEligible()` pass. Setting
    /// `local = nil` alone is NOT enough — the runtime actor's deinit is async
    /// and may not run promptly, so we explicitly unload and await completion.
    /// When the flag flips back on and the model resolves,
    /// `localIfEligible()` rebuilds a fresh engine via `makeLocal` (cold reload
    /// on the next generate).
    private func dropLocalEngine() async {
        if let localUnloadTask {
            let operation = localUnloadOperation
            await localUnloadTask.value
            if localUnloadOperation == operation {
                self.localUnloadTask = nil
            }
            return
        }
        guard let engine = takeLocalEngine() else { return }

        localUnloadOperation += 1
        let operation = localUnloadOperation
        let task = Task { @MainActor in await engine.unload() }
        localUnloadTask = task
        await task.value
        if localUnloadOperation == operation {
            localUnloadTask = nil
        }
    }

    func prewarm() async {
        guard let engine = try? await localIfEligible() else { return }
        try? await engine.prewarm()
    }

    func prewarm(for request: CotypingRequest) async {
        guard let engine = try? await localIfEligible() else { return }
        try? await engine.prewarm(for: request)
    }

    func unload() async {
        unloadOperationsInFlight += 1
        defer { unloadOperationsInFlight -= 1 }
        // Invalidate before the first suspension so a verifier already in
        // flight cannot recreate the local engine after this method returns.
        invalidateLifecycle()
        // Always release both paths. The HTTP server may have been adopted
        // from an earlier app process and therefore need not have generated in
        // this selector instance to be resident.
        await dropLocalEngine()
        await http.unload()
        retryLocalAt = nil
        didLogLocalFailure = false
    }

    /// The model server is streamed even here: its client stops reading at
    /// the same decode boundary as the in-process runtime.
    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        guard let engine = try await localIfEligible() else {
            return try await http.generateStreaming(request) { _ in }
        }
        do {
            let result = try await engine.generate(request)
            noteLocalSuccess()
            return result
        } catch let error as LlamaRuntimeError {
            await handleLocalFailure(error)
            return try await http.generateStreaming(request) { _ in }
        }
    }

    func generateStreaming(
        _ request: CotypingRequest,
        onPartial: @escaping @Sendable (CotypingNormalizationResult) -> Void
    ) async throws -> CotypingNormalizationResult {
        guard let engine = try await localIfEligible() else {
            return try await http.generateStreaming(request, onPartial: onPartial)
        }
        do {
            let result = try await engine.generateStreaming(request, onPartial: onPartial)
            noteLocalSuccess()
            return result
        } catch let error as LlamaRuntimeError {
            await handleLocalFailure(error)
            return try await http.generateStreaming(request, onPartial: onPartial)
        }
    }

    private func noteLocalSuccess() {
        didLogLocalFailure = false
        retryLocalAt = nil
    }

    /// In-process→HTTP fallback. The HTTP path runs the same GGUF in its own
    /// `llama-server` process, so keeping the failed local engine loaded would
    /// leave two copies of the selected model's weights resident. A failure here is
    /// likely memory pressure, so the unload is AWAITED — the caller must not
    /// start the HTTP fallback (which may cold-load the server's copy) until
    /// the local weights are actually freed. Then route to HTTP for
    /// `localRetryCooldown` and rebuild + retry local (a cold reload, but at
    /// most once per cooldown — never per keystroke). Logged once per failure
    /// episode (spec §13).
    private func handleLocalFailure(_ error: LlamaRuntimeError) async {
        invalidateLifecycle()
        if !didLogLocalFailure {
            didLogLocalFailure = true
            NSLog("""
            Cotyping: in-process runtime failed (\(error)); freeing the local model and using \
            the HTTP fallback for \(Int(Self.localRetryCooldown))s before retrying.
            """)
        }
        retryLocalAt = now().addingTimeInterval(Self.localRetryCooldown)
        // Join a teardown already started by a re-entrant route change. Seeing
        // `local == nil` does not prove its weights are gone: another task may
        // have taken ownership and still be awaiting `engine.unload()`.
        await dropLocalEngine()
    }
}
