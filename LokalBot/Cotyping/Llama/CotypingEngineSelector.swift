import Foundation

@MainActor
final class CotypingEngineSelector: CotypingCompleting {
    typealias ModelVerifier = (ModelCatalog.Entry, StorageManager) async -> URL?

    static let localRetryCooldown: TimeInterval = 60

    private let http: CotypingCompleting
    private let server: CotypingCompleting?
    private let makeLocal: (String) -> CotypingCompleting
    private let settings: () -> AppSettings
    private let storage: StorageManager
    private let now: () -> Date
    private let verifyModel: ModelVerifier
    private var local: CotypingCompleting?
    private var localModelPath: String?
    private var localIdentity: LocalRouteIdentity?
    private var didLogLocalFailure = false
    private var retryLocalAt: Date?
    private var releasedForServer = false

    private var lifecycleGeneration: UInt64 = 0
    private var unloadOperationsInFlight = 0
    private var localUnloadTask: Task<Void, Never>?
    private var localUnloadOperation: UInt64 = 0

    private struct LocalRouteIdentity: Equatable {
        let requestedModelID: String
        let entry: ModelCatalog.Entry
    }

    var debounceProfile: CotypingDebouncePolicy.RuntimeProfile {
        guard !Self.usesServer(settings()) else { return .modelServer }
        return local != nil && retryLocalAt == nil ? .inProcess : .modelServer
    }

    init(
        http: CotypingCompleting,
        server: CotypingCompleting? = nil,
        makeLocal: @escaping (String) -> CotypingCompleting,
        settings: @escaping () -> AppSettings,
        storage: StorageManager,
        now: @escaping () -> Date = { Date() },
        verifyModel: @escaping ModelVerifier = { entry, storage in
            await ModelDownloadManager.shared.verifiedExistingURL(entry, storage: storage)
        }
    ) {
        self.http = http
        self.server = server
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

    nonisolated static func usesServer(_ settings: AppSettings) -> Bool {
        settings.cotypingBackend != .onDevice
    }

    private func serverIfSelected() async throws -> CotypingCompleting? {
        guard unloadOperationsInFlight == 0 else { throw CancellationError() }
        guard Self.usesServer(settings()) else {
            releasedForServer = false
            return nil
        }
        guard let server else {
            throw TextEngineError.unavailable("Autocomplete can't use a server in this build.")
        }
        if !releasedForServer || local != nil {
            let invalidation = invalidateLifecycle()
            await dropLocalEngine()
            await http.unload()
            guard !Task.isCancelled,
                  unloadOperationsInFlight == 0,
                  lifecycleGeneration == invalidation,
                  Self.usesServer(settings()) else { throw CancellationError() }
            releasedForServer = true
            retryLocalAt = nil
            didLogLocalFailure = false
        }
        return server
    }

    private func localRouteIdentity(for settings: AppSettings) -> LocalRouteIdentity? {
        guard let entry = ModelCatalog.entry(
            id: settings.cotypingBuiltInModelID,
            custom: settings.customBuiltInModels
        ) ?? ModelCatalog.entry(id: ModelCatalog.recommendedCotypingID) else { return nil }
        return LocalRouteIdentity(requestedModelID: settings.cotypingBuiltInModelID, entry: entry)
    }

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

    private func localIfEligible() async throws -> CotypingCompleting? {
        guard unloadOperationsInFlight == 0 else { throw CancellationError() }
        let s = settings()
        guard s.cotypingInProcessRuntime, Self.isAppleSilicon else {
            let invalidation = invalidateLifecycle()
            await dropLocalEngine()
            try requireCurrentDisabledRoute(generation: invalidation)
            return nil
        }
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
            if local != nil || localModelPath != nil {
                generation = invalidateLifecycle()
            }
            await dropLocalEngine()
            try requireCurrentLocalRoute(generation: generation, identity: identity)
            await http.unload()
            try requireCurrentLocalRoute(generation: generation, identity: identity)
            if let local {
                guard localModelPath == url.path, localIdentity == identity else { throw CancellationError() }
                return local
            }
            local = makeLocal(url.path)
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
        if Self.usesServer(settings()) {
            _ = try? await serverIfSelected()
            return
        }
        guard let engine = try? await localIfEligible() else { return }
        try? await engine.prewarm()
    }

    func prewarm(for request: CotypingRequest) async {
        guard !Self.usesServer(settings()) else { return }
        guard let engine = try? await localIfEligible() else { return }
        try? await engine.prewarm(for: request)
    }

    func warmAfterPause() async {
        guard !Self.usesServer(settings()), retryLocalAt == nil, let local else { return }
        await local.warmAfterPause()
    }

    func unload() async {
        unloadOperationsInFlight += 1
        defer { unloadOperationsInFlight -= 1 }
        invalidateLifecycle()
        await dropLocalEngine()
        await http.unload()
        await server?.unload()
        retryLocalAt = nil
        didLogLocalFailure = false
        releasedForServer = false
    }

    func generate(_ request: CotypingRequest) async throws -> CotypingNormalizationResult {
        if let server = try await serverIfSelected() {
            return try await server.generate(request)
        }
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
        if let server = try await serverIfSelected() {
            return try await server.generateStreaming(request, onPartial: onPartial)
        }
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
        await dropLocalEngine()
    }
}
