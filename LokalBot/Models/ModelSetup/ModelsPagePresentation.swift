import Foundation

/// One of the three rows under "What each model does" on Settings › Models:
/// the job in plain words, which model does it, where it runs, what it
/// weighs and whether it can be used.
struct ModelRoleRow: Equatable, Identifiable, Sendable {
    enum Place: Equatable, Sendable {
        case thisMac
        /// A server or subscription that receives what the model reads.
        case online(String)
        /// A server or plan that is chosen and not usable yet.
        case notSetUp
    }

    enum Chip: Equatable, Sendable {
        case ready
        case notDownloaded
        /// Nil while the download has not said how far it is.
        case downloading(Double?)
        /// A check of the downloaded model is running.
        case checking
        /// The model is here and did not answer its check.
        case checkFailed
        /// A download stopped, or a server refused.
        case stopped
        case notSetUp

        enum Tone: Equatable, Sendable { case good, attention, quiet }

        var tone: Tone {
            switch self {
            case .ready: .good
            case .notDownloaded, .checkFailed, .stopped, .notSetUp: .attention
            case .downloading, .checking: .quiet
            }
        }

        var text: SettingsText {
            switch self {
            case .ready: return SettingsText("Ready")
            case .notDownloaded: return SettingsText("Not downloaded")
            case .downloading(let progress):
                guard let progress else { return SettingsText("Downloading…") }
                return SettingsText("Downloading · %lld%%", .count(Int((min(1, max(0, progress)) * 100).rounded())))
            case .checking: return SettingsText("Checking…")
            case .checkFailed: return SettingsText("Check failed")
            case .stopped: return SettingsText("Stopped")
            case .notSetUp: return SettingsText("Not set up")
            }
        }
    }

    let role: ModelRole
    /// The selected model's own name.
    let name: String
    let place: Place
    /// What the model weighs on disk. Nil when nothing downloads for it or
    /// the size is not known.
    let bytes: Int64?
    /// Speech models have no exact size in the catalog, only an estimate.
    let sizeIsEstimate: Bool
    let chip: Chip
    /// False for Autocomplete's model while Autocomplete is off: nothing
    /// waits for it, so its missing download is not a warning.
    let needed: Bool
    /// Why a download stopped or a check failed, in the downloader's or the
    /// model's own words.
    let problem: String?

    var id: ModelRole { role }

    var chipTone: Chip.Tone {
        chip == .notDownloaded && !needed ? .quiet : chip.tone
    }

    /// What the model does, in plain words.
    var job: String {
        switch role {
        case .transcribe: "Turns meeting audio and dictation into text"
        case .think: "Writes summaries and answers questions"
        case .autocomplete: "Suggests the next words as you type"
        }
    }

    /// "On this Mac · 2.74 GB" or "Online · example.com". A choice that is
    /// not set up yet is an online one; its chip says the rest.
    var placeText: SettingsText {
        switch place {
        case .online(let host):
            return SettingsText("%@ · %@", .key("Online"), .verbatim(host))
        case .notSetUp:
            return SettingsText("Online")
        case .thisMac:
            guard let bytes, bytes > 0 else { return SettingsText("On this Mac") }
            let size = SettingsStatus.size(bytes)
            return sizeIsEstimate
                ? SettingsText("On this Mac · about %@", .verbatim(size))
                : SettingsText("%@ · %@", .key("On this Mac"), .verbatim(size))
        }
    }
}

/// What a model check found, as far as the Models page shows it.
struct ModelCheckSummary: Equatable, Sendable {
    var testing: ModelRole?
    /// The reason each failed check gave.
    var failures: [ModelRole: String] = [:]
}

/// Settings › Models, derived from the settings and the role statuses: the
/// three role rows and the model set they belong to.
struct ModelsPagePresentation: Equatable {
    let rows: [ModelRoleRow]
    /// The preset the three choices match. Nil for any other combination.
    let modelSet: ModelStackPreset?
    /// One line about the model set: what it is for and what it weighs.
    let modelSetHelp: SettingsText

    init(settings: AppSettings, statuses: [ModelRole: ModelRoleStatus], checks: ModelCheckSummary = .init()) {
        let plan = OnboardingDownloadPlan(settings: settings, statuses: statuses, includeAutocomplete: true,
                                          started: true, readyBefore: [], availableBytes: nil)
        rows = ModelRole.allCases.map { role in
            let status = statuses[role] ?? .unavailable
            let planned = plan.models.first { $0.role == role }
            let place = Self.place(of: role, settings: settings)
            let downloads = planned?.downloads ?? false
            return ModelRoleRow(
                role: role,
                name: Self.name(of: role, settings: settings),
                place: place,
                bytes: place == .thisMac ? planned?.bytes : nil,
                sizeIsEstimate: role == .transcribe,
                chip: Self.chip(status: status, downloads: downloads, role: role, checks: checks),
                needed: role != .autocomplete || settings.cotypingEnabled,
                problem: status.errorMessage ?? (status.isReady ? checks.failures[role] : nil))
        }
        modelSet = ModelStackPreset.matching(settings)
        if let modelSet {
            if let bytes = Self.bytes(of: modelSet, settings: settings) {
                modelSetHelp = SettingsText("%@ %@ in all.", .key(modelSet.subtitle), .verbatim(SettingsStatus.size(bytes)))
            } else {
                modelSetHelp = SettingsText(modelSet.subtitle)
            }
        } else {
            modelSetHelp = SettingsText("You picked your own models. Choose a set to go back to one that was tested together.")
        }
    }

    func row(_ role: ModelRole) -> ModelRoleRow? { rows.first { $0.role == role } }

    /// The preset's three models together, from the same sizes the download
    /// plan uses. Nil when one of them has no known size.
    static func bytes(of preset: ModelStackPreset, settings: AppSettings) -> Int64? {
        let target = preset.patch.applying(to: settings)
        let plan = OnboardingDownloadPlan(settings: target, statuses: [:], includeAutocomplete: true,
                                          started: false, readyBefore: [], availableBytes: nil)
        guard plan.models.count == ModelRole.allCases.count,
              !plan.models.contains(where: { $0.bytes == nil }) else { return nil }
        return plan.models.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
    }

    static func name(of role: ModelRole, settings: AppSettings) -> String {
        switch role {
        case .transcribe: settings.transcriptionModelDisplayName
        case .think: ModelSettingsPresentation.assistantName(settings)
        case .autocomplete: settings.cotypingModelDisplayName
        }
    }

    /// Where a role's model runs. A server on this Mac's own address counts
    /// as this Mac: nothing leaves it.
    static func place(of role: ModelRole, settings: AppSettings) -> ModelRoleRow.Place {
        let presentation: InferencePresentation
        switch role {
        case .transcribe:
            presentation = settings.transcriptionPresentation
        case .think:
            presentation = InferencePresentation(settings: settings)
        case .autocomplete:
            switch settings.cotypingRoute(includingCredentials: false) {
            case .onDevice: return .thisMac
            case .unavailable: return .notSetUp
            case .server(let endpoint):
                return InferenceEndpointPolicy.isLoopback(endpoint.baseURL)
                    ? .thisMac : .online(endpoint.baseURL.host ?? endpoint.origin)
            }
        }
        switch presentation {
        case .onDevice: return .thisMac
        case .remote(let host): return .online(host)
        case .blocked: return .notSetUp
        }
    }

    private static func chip(status: ModelRoleStatus, downloads: Bool, role: ModelRole,
                             checks: ModelCheckSummary) -> ModelRoleRow.Chip {
        switch status {
        case .ready:
            if checks.testing == role { return .checking }
            return checks.failures[role] == nil ? .ready : .checkFailed
        case .downloading(let progress), .preparing(let progress, _):
            return .downloading(progress)
        case .needsAttention:
            return downloads ? .stopped : .notSetUp
        case .unavailable:
            return downloads ? .notDownloaded : .notSetUp
        }
    }
}

/// Decides which downloaded models are checked without being asked. A check
/// loads the model and runs a short built-in sample through it, so it runs
/// once, when a download made in this launch finishes, and only for a model
/// that runs on this Mac. A model on a server or a subscription is checked
/// only from the sheet that says what the check sends there.
struct ModelAutoCheckTracker: Equatable {
    /// The roles whose download is under way, with the model each is for.
    private(set) var awaiting: [ModelRole: String] = [:]

    /// The model a role's check would exercise. Nil when it runs elsewhere,
    /// or is not in use.
    static func localModelID(_ role: ModelRole, settings: AppSettings) -> String? {
        switch role {
        case .transcribe:
            return settings.transcriptionModel.isRemote ? nil : settings.transcriptionModel.id
        case .think:
            return settings.summarizerBackend == .builtIn ? settings.builtInModelID : nil
        case .autocomplete:
            return settings.cotypingEnabled && settings.cotypingBackend == .onDevice
                ? settings.cotypingBuiltInModelID : nil
        }
    }

    /// Takes the latest role statuses and returns the roles to check now:
    /// those that were downloading the same model and are ready.
    mutating func observe(_ statuses: [ModelRole: ModelRoleStatus], settings: AppSettings) -> [ModelRole] {
        var finished: [ModelRole] = []
        for role in ModelRole.allCases {
            let status = statuses[role] ?? .unavailable
            guard let id = Self.localModelID(role, settings: settings) else {
                awaiting[role] = nil
                continue
            }
            if status.isWorking {
                awaiting[role] = id
            } else if status.isReady, let expected = awaiting.removeValue(forKey: role), expected == id {
                finished.append(role)
            } else if awaiting[role] != nil, awaiting[role] != id {
                // Another model was chosen while this one downloaded.
                awaiting[role] = nil
            }
        }
        return finished
    }
}

/// Where dictated words are turned into the text that is pasted.
struct DictationWriterPresentation: Equatable {
    /// The picker that changes it.
    let pickerRole: ModelPickerRole
    let text: SettingsText
    /// True when what is dictated leaves this Mac to be written.
    let online: Bool

    init(settings: AppSettings) {
        guard settings.dictationIntent == .compose else {
            pickerRole = .transcription
            let name = settings.transcriptionModelDisplayName
            switch settings.transcriptionPresentation {
            case .onDevice:
                text = SettingsText("The Transcribe model, %@, on this Mac", .verbatim(name))
                online = false
            case .remote(let host):
                text = SettingsText("The Transcribe model, online at %@. What you say is sent there.", .verbatim(host))
                online = true
            case .blocked:
                text = SettingsText("The Transcribe model isn’t set up yet.")
                online = false
            }
            return
        }
        pickerRole = .dictation
        let effective = settings.dictationCompositionTextEngineSettings
        // A dedicated Compose model is always one on this Mac.
        let usesThink = effective == settings
        let name = ModelSettingsPresentation.assistantName(effective)
        switch InferencePresentation(settings: effective) {
        case .onDevice:
            text = usesThink
                ? SettingsText("The Think model, %@, on this Mac", .verbatim(name))
                : SettingsText("%@, on this Mac", .verbatim(name))
            online = false
        case .remote(let host):
            text = SettingsText("The Think model, online at %@. What you dictate is sent there.", .verbatim(host))
            online = true
        case .blocked:
            text = SettingsText("The Think model isn’t set up yet.")
            online = false
        }
    }
}
