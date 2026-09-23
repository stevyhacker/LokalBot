import Foundation

/// One honest, UI-ready view of the selected model stack. Core readiness is
/// limited to Transcribe, Think, and Autocomplete; optional Voice/Embeddings
/// never make the main stack fail.
struct ModelReadinessSnapshot: Equatable, Sendable {
    struct DiskState: Sendable {
        var downloadedTranscriptionIDs: Set<String> = []
        var thinkReady = false
        var autocompleteReady = false
        var storedBytes: Int64 = 0
        var availableBytes: Int64?

        static func load(settings: AppSettings, root: URL) -> Self {
            let storage = StorageManager(rootURL: root)
            let models = root.appendingPathComponent("models", isDirectory: true)
            return Self(
                downloadedTranscriptionIDs: TranscriptionModelStore.downloadedChoices(
                    graniteConfiguration: settings.graniteSpeechModel),
                thinkReady: ModelCatalog.entry(id: settings.builtInModelID, custom: settings.customBuiltInModels)
                    .flatMap { ModelCatalog.localURL(for: $0, storage: storage) } != nil,
                autocompleteReady: ModelReadinessSnapshot.autocompleteReady(settings, storage: storage),
                storedBytes: ModelReadinessSnapshot.directoryBytes(models),
                availableBytes: DiskSpacePrecheck.availableBytes(at: models))
        }
    }
    enum Provenance: Equatable, Sendable {
        case local
        case externalThink(String)
        case blockedThink(String)
    }

    var transcriptionReady: Bool
    var thinkReady: Bool
    var autocompleteReady: Bool
    var provenance: Provenance
    var storedBytes: Int64
    var availableBytes: Int64?
    var activeDownloads: Int
    var failedDownloads: Int

    var coreReady: Bool {
        transcriptionReady && thinkReady && autocompleteReady
    }

    var meetingReady: Bool { transcriptionReady && thinkReady }

    var headline: String {
        meetingReady ? "Meeting models available" : "Prepare meeting models"
    }

    var detail: String {
        if case .blockedThink(let reason) = provenance { return reason }
        if meetingReady {
            let location: String
            switch provenance {
            case .local: location = "Transcription and Think run on this Mac."
            case .externalThink(let host): location = "Transcription runs on this Mac. Think uses \(host)."
            case .blockedThink: location = ""
            }
            return location + (autocompleteReady ? " Autocomplete is also available." : " Autocomplete can be prepared separately.")
        }
        if activeDownloads > 0 { return "Selected models are downloading. Available roles can still be used." }
        if failedDownloads > 0 { return "Review the affected role below and retry its preparation." }
        return "Prepare the missing roles below. Availability does not mean a model test has passed."
    }

    var storageSummary: String {
        let stored = storedBytes == 0 ? "none downloaded yet"
            : ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file) + " on this Mac"
        guard let availableBytes else { return stored }
        let free = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        return "\(stored) · \(free) free"
    }

    // MARK: Role readiness (shared by automation gates)

    /// True when the selected meeting-transcription model is fully on disk.
    /// Automation (auto-processing, prewarm) must consult this before running:
    /// a missing model means a multi-gigabyte download the user never asked
    /// for at that moment.
    static func transcriptionReady(_ settings: AppSettings) -> Bool {
        TranscriptionModelStore.isDownloaded(
            settings.transcriptionModel,
            graniteConfiguration: settings.graniteSpeechModel)
    }

    /// True when the Think role can run without triggering a model download.
    /// External endpoints must be approved; Apple Intelligence must be available.
    @MainActor
    static func thinkReady(_ settings: AppSettings, storage: StorageManager) -> Bool {
        guard !InferencePresentation(settings: settings).isBlocked else { return false }
        if settings.summarizerBackend == .appleIntelligence { return FoundationModelAvailability.current().isAvailable }
        guard settings.summarizerBackend == .builtIn else { return true }
        guard let entry = ModelCatalog.entry(
            id: settings.builtInModelID,
            custom: settings.customBuiltInModels) else { return false }
        return ModelCatalog.localURL(for: entry, storage: storage) != nil
    }

    static func autocompleteReady(_ settings: AppSettings, storage: StorageManager) -> Bool {
        guard let entry = ModelCatalog.entry(
            id: settings.cotypingBuiltInModelID,
            custom: settings.customBuiltInModels) else { return false }
        return ModelCatalog.localURL(for: entry, storage: storage) != nil
    }

    /// Settings that can change whether a parked meeting may transcribe or
    /// summarize without downloading anything. AppState uses this to re-check
    /// parked work immediately after a selection change.
    static func processingReadinessChanged(from old: AppSettings,
                                           to new: AppSettings) -> Bool {
        old.transcriptionModel != new.transcriptionModel
            || old.graniteSpeechModel != new.graniteSpeechModel
            || old.summarizerBackend != new.summarizerBackend
            || old.builtInModelID != new.builtInModelID
            || old.customBuiltInModels != new.customBuiltInModels
            || old.approvedRemoteInferenceOrigins != new.approvedRemoteInferenceOrigins
            || old.openAIBaseURL != new.openAIBaseURL || old.ollamaBaseURL != new.ollamaBaseURL
    }

    /// Total bytes of the core GGUF models (Think when built-in, Autocomplete)
    /// still missing on disk. The Transcribe model downloads through its
    /// engine-specific path and is not included — callers name it separately.
    static func missingCoreModelBytes(_ settings: AppSettings, storage: StorageManager) -> Int64 {
        var ids = [settings.cotypingBuiltInModelID]
        if settings.summarizerBackend == .builtIn { ids.append(settings.builtInModelID) }
        return ids.compactMap {
            ModelCatalog.entry(id: $0, custom: settings.customBuiltInModels)
        }.filter {
            ModelCatalog.localURL(for: $0, storage: storage) == nil
        }.reduce(Int64(0)) { $0 + Int64($1.sizeBytes ?? 0) }
    }

    @MainActor
    static func make(
        settings: AppSettings,
        storage: StorageManager,
        activeDownloads: Int,
        failedDownloads: Int,
        storageInfo: (storedBytes: Int64, availableBytes: Int64?)? = nil,
        diskState: DiskState? = nil
    ) -> Self {
        let transcriptionReady = diskState.map { $0.downloadedTranscriptionIDs.contains(settings.transcriptionModel.id) }
            ?? transcriptionReady(settings)
        let thinkReady = settings.summarizerBackend == .builtIn
            ? (diskState?.thinkReady ?? thinkReady(settings, storage: storage))
            : thinkReady(settings, storage: storage)
        let autocompleteReady = diskState?.autocompleteReady ?? autocompleteReady(settings, storage: storage)
        var provenance: Provenance
        switch InferencePresentation(settings: settings) {
        case .onDevice: provenance = .local
        case .remote(let host): provenance = .externalThink(host)
        case .blocked(let reason): provenance = .blockedThink(reason)
        }
        if settings.summarizerBackend == .appleIntelligence, !thinkReady {
            provenance = .blockedThink(FoundationModelAvailability.current().reason ?? "Apple Intelligence is unavailable.")
        }
        let modelsFolder = storage.rootURL.appendingPathComponent("models", isDirectory: true)
        return Self(
            transcriptionReady: transcriptionReady,
            thinkReady: thinkReady,
            autocompleteReady: autocompleteReady,
            provenance: provenance,
            storedBytes: diskState?.storedBytes ?? storageInfo?.storedBytes ?? directoryBytes(modelsFolder),
            availableBytes: diskState.map(\.availableBytes) ?? storageInfo?.availableBytes ?? DiskSpacePrecheck.availableBytes(at: modelsFolder),
            activeDownloads: activeDownloads,
            failedDownloads: failedDownloads)
    }

    private static func directoryBytes(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
