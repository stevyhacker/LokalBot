import Foundation

enum OnboardingModelOption: String, CaseIterable, Identifiable, Equatable, Sendable {
    case recommended
    case lightweight
    case appleBuiltIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: ModelStackPreset.recommended.title
        case .lightweight: ModelStackPreset.lightweight.title
        case .appleBuiltIn: "Apple on-device (0 GB)"
        }
    }

    var subtitle: String {
        switch self {
        case .recommended:
            ModelStackPreset.recommended.subtitle
        case .lightweight:
            ModelStackPreset.lightweight.subtitle
        case .appleBuiltIn:
            "Uses Apple Speech and Apple Intelligence already on this Mac. 0 GB download; switch to local open models anytime in Settings."
        }
    }

    var patch: ModelSelectionPatch {
        switch self {
        case .recommended:
            ModelStackPreset.recommended.patch
        case .lightweight:
            ModelStackPreset.lightweight.patch
        case .appleBuiltIn:
            ModelSelectionPatch(
                transcription: .appleSpeech,
                backend: .appleIntelligence,
                cotypingBackend: .onDevice)
        }
    }

    static func availableCases(appleBuiltInAvailable: Bool) -> [Self] {
        appleBuiltInAvailable ? [.recommended, .lightweight, .appleBuiltIn] : [.recommended, .lightweight]
    }

    static func matching(_ settings: AppSettings) -> Self? {
        if settings.transcriptionModel == .appleSpeech, settings.summarizerBackend == .appleIntelligence {
            return .appleBuiltIn
        }
        switch ModelStackPreset.matching(settings) {
        case .recommended: return .recommended
        case .lightweight: return .lightweight
        case nil: return nil
        }
    }

    static func defaultOption(
        for capability: HardwareCapability = HardwareCapabilityProbe.current()
    ) -> Self {
        ModelStackPreset.defaultPreset(for: capability) == .recommended ? .recommended : .lightweight
    }
}

struct OnboardingDownloadPlan: Equatable, Sendable {
    enum ModelState: Equatable, Sendable {
        case notStarted
        case downloading(Double?)
        case stopped(String)
        case ready
        case needsSetup
    }

    struct Model: Equatable, Identifiable, Sendable {
        let role: ModelRole
        let name: String
        let bytes: Int64?
        let downloads: Bool
        let state: ModelState
        var id: ModelRole { role }

        var arrivedBytes: Int64? {
            guard let bytes else { return nil }
            switch state {
            case .ready: return bytes
            case .downloading(let progress):
                return progress.map { Int64((Double(bytes) * min(1, max(0, $0))).rounded()) }
            case .notStarted, .stopped, .needsSetup: return 0
            }
        }

        var job: String {
            switch role {
            case .transcribe: "Turns speech into text"
            case .think: "Writes notes and answers questions"
            case .autocomplete: "Suggests text as you type in other apps"
            }
        }

        var title: String {
            switch role {
            case .transcribe: "Transcription"
            case .think: "Notes and answers"
            case .autocomplete: "Autocomplete"
            }
        }
    }

    enum Phase: Equatable, Sendable {
        case before
        case running
        case stopped
        case finished
    }

    var models: [Model]
    var selected: [ModelRole]
    var phase: Phase
    var isDownloading: Bool
    var availableBytes: Int64?
    var totalBytes: Int64?
    var downloadedBytes: Int64?

    init(settings: AppSettings,
         statuses: [ModelRole: ModelRoleStatus],
         includeAutocomplete: Bool,
         started: Bool,
         readyBefore: Set<ModelRole>,
         availableBytes: Int64?) {
        let autocompleteDownloads = settings.cotypingBackend == .onDevice
        var models = [
            Self.model(.transcribe, settings: settings, status: statuses[.transcribe] ?? .unavailable),
            Self.model(.think, settings: settings, status: statuses[.think] ?? .unavailable),
        ]
        var selected: [ModelRole] = [.transcribe, .think]
        if autocompleteDownloads {
            let autocomplete = Self.model(.autocomplete, settings: settings,
                                          status: statuses[.autocomplete] ?? .unavailable)
            let chosen = includeAutocomplete || autocomplete.state != .notStarted
            if chosen { selected.append(.autocomplete) }
            if chosen || !started { models.append(autocomplete) }
        }
        self.models = models
        self.selected = selected
        self.availableBytes = availableBytes

        let chosenModels = models.filter { selected.contains($0.role) }
        let pending = chosenModels.filter { $0.downloads && !readyBefore.contains($0.role) }
        totalBytes = pending.contains { $0.bytes == nil }
            ? nil : pending.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
        downloadedBytes = totalBytes == nil ? nil : pending.reduce(Int64?.some(0)) { sum, model in
            guard let sum, let arrived = model.arrivedBytes else { return nil }
            return sum + arrived
        }

        let waiting = chosenModels.contains { $0.downloads && $0.state == .notStarted }
        isDownloading = chosenModels.contains { if case .downloading = $0.state { true } else { false } }
        if chosenModels.contains(where: { if case .stopped = $0.state { true } else { false } }) {
            phase = .stopped
        } else if isDownloading {
            phase = .running
        } else if waiting {
            phase = started ? .running : .before
        } else {
            phase = .finished
        }
    }

    var allReady: Bool {
        models.filter { selected.contains($0.role) }.allSatisfy { $0.state == .ready }
    }

    var remainingBytes: Int64? {
        let missing = models.filter { selected.contains($0.role) && $0.downloads && $0.state != .ready }
        guard !missing.contains(where: { $0.bytes == nil }) else { return nil }
        return missing.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
    }

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0, let downloadedBytes else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var fitsOnDisk: Bool {
        DiskSpacePrecheck.advisory(expectedBytes: remainingBytes, availableBytes: availableBytes) == nil
    }

    var stoppedModels: [Model] {
        models.filter { if case .stopped = $0.state { selected.contains($0.role) } else { false } }
    }

    private static func model(_ role: ModelRole, settings: AppSettings, status: ModelRoleStatus) -> Model {
        let name: String
        let bytes: Int64?
        let downloads: Bool
        switch role {
        case .transcribe:
            name = settings.transcriptionModelDisplayName
            downloads = !settings.transcriptionModel.isRemote
                && settings.transcriptionModel != .funASRNano
                && !settings.transcriptionModel.isBuiltInSystem
            bytes = downloads ? ModelSettingsPresentation.estimatedTranscriptionBytes(
                settings.transcriptionModel, granite: settings.graniteSpeechModel) : nil
        case .think:
            name = settings.thinkModelDisplayName
            downloads = settings.summarizerBackend == .builtIn
            bytes = downloads ? catalogBytes(settings.builtInModelID, settings: settings) : nil
        case .autocomplete:
            let entry = ModelCatalog.entry(id: settings.cotypingBuiltInModelID, custom: settings.customBuiltInModels)
            name = entry?.displayName ?? settings.cotypingBuiltInModelID
            downloads = settings.cotypingBackend == .onDevice
            bytes = downloads ? catalogBytes(settings.cotypingBuiltInModelID, settings: settings) : nil
        }
        let state: ModelState
        switch status {
        case .ready:
            state = .ready
        case .downloading(let progress), .preparing(let progress, _):
            state = .downloading(progress)
        case .needsAttention(let message):
            state = downloads ? .stopped(message) : .needsSetup
        case .unavailable:
            state = downloads ? .notStarted : .needsSetup
        }
        return Model(role: role, name: name, bytes: bytes, downloads: downloads, state: state)
    }

    private static func catalogBytes(_ id: String, settings: AppSettings) -> Int64? {
        guard let entry = ModelCatalog.entry(id: id, custom: settings.customBuiltInModels) else { return nil }
        if let exact = entry.sizeBytes, exact > 0 { return exact }
        let estimate = entry.sizeGB * 1_000_000_000
        guard estimate.isFinite, estimate > 0, estimate < Double(Int64.max) else { return nil }
        return Int64(estimate)
    }
}

struct DownloadTimeEstimator: Equatable, Sendable {
    static let window: TimeInterval = 30
    static let minimumSpan: TimeInterval = 5

    private struct Sample: Equatable, Sendable {
        var date: Date
        var bytes: Int64
    }

    private var samples: [Sample] = []

    mutating func record(downloadedBytes: Int64, at date: Date) {
        if let last = samples.last, downloadedBytes < last.bytes || date < last.date { samples.removeAll() }
        samples.append(Sample(date: date, bytes: downloadedBytes))
        samples.removeAll { date.timeIntervalSince($0.date) > Self.window }
    }

    mutating func reset() { samples.removeAll() }

    func secondsLeft(totalBytes: Int64) -> TimeInterval? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        let arrived = last.bytes - first.bytes
        guard span >= Self.minimumSpan, arrived > 0, totalBytes > last.bytes else { return nil }
        return Double(totalBytes - last.bytes) / (Double(arrived) / span)
    }

    func minutesLeft(totalBytes: Int64) -> Int? {
        secondsLeft(totalBytes: totalBytes).map { max(1, Int(($0 / 60).rounded())) }
    }
}
