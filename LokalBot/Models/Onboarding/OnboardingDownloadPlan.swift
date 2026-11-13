import Foundation

/// Setup's download step: each model's job, its size, and how far along it
/// is, read from the same role statuses Settings shows.
struct OnboardingDownloadPlan: Equatable, Sendable {
    enum ModelState: Equatable, Sendable {
        case notStarted
        /// Nil while the download has not reported how far it is.
        case downloading(Double?)
        case stopped(String)
        case ready
        /// Nothing downloads for this role (a server or Apple Intelligence),
        /// and it is not usable yet.
        case needsSetup
    }

    struct Model: Equatable, Identifiable, Sendable {
        let role: ModelRole
        /// The selected model's own name.
        let name: String
        /// What the download weighs. Nil when nothing downloads here or the
        /// size is not known in advance.
        let bytes: Int64?
        /// False for a server or Apple Intelligence.
        let downloads: Bool
        let state: ModelState
        var id: ModelRole { role }

        /// How much of this model is here. Nil while a running download has
        /// not said, or when the size is unknown; a stopped one counts as none.
        var arrivedBytes: Int64? {
            guard let bytes else { return nil }
            switch state {
            case .ready: return bytes
            case .downloading(let progress):
                return progress.map { Int64((Double(bytes) * min(1, max(0, $0))).rounded()) }
            case .notStarted, .stopped, .needsSetup: return 0
            }
        }

        /// Plain words for what the model does.
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
        /// Nothing has been asked for yet.
        case before
        case running
        /// At least one download failed; others may still be running.
        case stopped
        /// Nothing is left to download.
        case finished
    }

    /// The rows, in order. Autocomplete is listed while it can still be
    /// chosen and once it is part of the download.
    var models: [Model]
    /// The roles this download covers.
    var selected: [ModelRole]
    var phase: Phase
    /// A download is running now, also beside one that stopped.
    var isDownloading: Bool
    /// Free space on the volume that holds the models.
    var availableBytes: Int64?
    /// Bytes of the selected models that were not on this Mac when the
    /// download began. Nil when one of them has no known size.
    var totalBytes: Int64?
    /// Of `totalBytes`, how much has arrived. Nil when a running download
    /// has not reported its progress.
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
            // Once the download is under way the option is no longer offered.
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
            // Between the button and the first status the download has no state yet.
            phase = started ? .running : .before
        } else {
            phase = .finished
        }
    }

    /// Every selected model can be used now.
    var allReady: Bool {
        models.filter { selected.contains($0.role) }.allSatisfy { $0.state == .ready }
    }

    /// What Download will fetch: the selected models that are not here yet.
    /// Nil when one of them has no known size.
    var remainingBytes: Int64? {
        let missing = models.filter { selected.contains($0.role) && $0.downloads && $0.state != .ready }
        guard !missing.contains(where: { $0.bytes == nil }) else { return nil }
        return missing.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
    }

    /// 0…1 across the whole download, when sizes and progress are known.
    var fraction: Double? {
        guard let totalBytes, totalBytes > 0, let downloadedBytes else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    /// Whether the download and the headroom it needs fit in the free space.
    /// True when either number is unknown.
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
            // Fun-ASR-Nano reads a folder the person already has.
            downloads = !settings.transcriptionModel.isRemote && settings.transcriptionModel != .funASRNano
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

/// Time left for a download, from how fast the bytes have been arriving over
/// the last half minute. It says nothing until it has watched for a few
/// seconds, and nothing while no bytes arrive.
struct DownloadTimeEstimator: Equatable, Sendable {
    static let window: TimeInterval = 30
    static let minimumSpan: TimeInterval = 5

    private struct Sample: Equatable, Sendable {
        var date: Date
        var bytes: Int64
    }

    private var samples: [Sample] = []

    mutating func record(downloadedBytes: Int64, at date: Date) {
        // A retried download starts over, so earlier speeds no longer apply.
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

    /// Whole minutes, never less than one.
    func minutesLeft(totalBytes: Int64) -> Int? {
        secondsLeft(totalBytes: totalBytes).map { max(1, Int(($0 / 60).rounded())) }
    }
}
