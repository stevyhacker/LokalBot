import Foundation

enum ModelsSettingsPage: String, CaseIterable, Identifiable {
    case active, downloaded, connections

    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: "Active models"
        case .downloaded: "Downloaded"
        case .connections: "Connections"
        }
    }
}

enum ModelPickerRole: String, Identifiable {
    case transcription, assistant, autocomplete, dictation

    var id: String { rawValue }
    var title: String {
        switch self {
        case .transcription: "Transcription"
        case .assistant: "Think"
        case .autocomplete: "Autocomplete"
        case .dictation: "Dictation composition"
        }
    }
    var detail: String {
        switch self {
        case .transcription: "Turn meeting audio into text on this Mac."
        case .assistant: "Power summaries, Ask, and Agent."
        case .autocomplete: "Complete text as you type, using a model on this Mac."
        case .dictation: "Compose and rewrite spoken requests before insertion."
        }
    }
}

enum ModelsSettingsSheet: String, Identifiable {
    case transcription, assistant, autocomplete, dictation, speech, search, presets, checks, transcriptionOptions
    var id: String { rawValue }
    var pickerRole: ModelPickerRole? { ModelPickerRole(rawValue: rawValue) }
}

/// A deliberately narrow patch: applying or undoing a model switch must never
/// overwrite privacy choices, credentials, or unrelated edits made during a download.
struct ModelSelectionPatch: Equatable {
    var transcription: TranscriptionModelChoice?
    var granite: GraniteSpeechModelConfiguration?
    var language: TranscriptionLanguage?
    var backend: AppSettings.SummarizerBackend?
    var assistantModelID: String?
    var ollamaModel: String?
    var remoteModel: String?
    var autocompleteModelID: String?
    var dictationModelID: String?

    func applying(to settings: AppSettings) -> AppSettings {
        var next = settings
        if let transcription { next.transcriptionModel = transcription }
        if let granite { next.graniteSpeechModel = granite }
        if let language { next.transcriptionLanguage = language }
        if let backend { next.summarizerBackend = backend }
        if let assistantModelID { next.builtInModelID = assistantModelID }
        if let ollamaModel { next.ollamaModel = ollamaModel }
        if let remoteModel { next.openAIModel = remoteModel }
        if let autocompleteModelID { next.cotypingBuiltInModelID = autocompleteModelID }
        if let dictationModelID { next.dictationCompositionBuiltInModelID = dictationModelID }
        return next
    }

    func inverse(in settings: AppSettings) -> Self {
        Self(
            transcription: transcription.map { _ in settings.transcriptionModel },
            granite: granite.map { _ in settings.graniteSpeechModel },
            language: language.map { _ in settings.transcriptionLanguage },
            backend: backend.map { _ in settings.summarizerBackend },
            assistantModelID: assistantModelID.map { _ in settings.builtInModelID },
            ollamaModel: ollamaModel.map { _ in settings.ollamaModel },
            remoteModel: remoteModel.map { _ in settings.openAIModel },
            autocompleteModelID: autocompleteModelID.map { _ in settings.cotypingBuiltInModelID },
            dictationModelID: dictationModelID.map { _ in settings.dictationCompositionBuiltInModelID })
    }

    func matches(_ settings: AppSettings) -> Bool { inverse(in: settings) == self }

    /// IDs alone do not identify imported files or a remote destination.
    /// Refuse activation if either changed while the replacement was preparing.
    func preparationContextMatches(_ latest: AppSettings, original: AppSettings) -> Bool {
        for id in localModelIDs(in: original) {
            guard ModelCatalog.entry(id: id, custom: original.customBuiltInModels)
                == ModelCatalog.entry(id: id, custom: latest.customBuiltInModels) else { return false }
        }
        let target = applying(to: original)
        if transcription == .graniteSpeech,
           original.graniteSpeechModel != latest.graniteSpeechModel { return false }
        if backend != nil || remoteModel != nil || ollamaModel != nil {
            switch target.summarizerBackend {
            case .openAICompatible: return original.openAIBaseURL == latest.openAIBaseURL
            case .ollama: return original.ollamaBaseURL == latest.ollamaBaseURL
            case .builtIn, .appleIntelligence: break
            }
        }
        return true
    }

    func localModelIDs(in settings: AppSettings) -> [String] {
        let target = applying(to: settings)
        var ids: [String] = []
        if backend != nil || assistantModelID != nil, target.summarizerBackend == .builtIn {
            ids.append(target.builtInModelID)
        }
        if let autocompleteModelID { ids.append(autocompleteModelID) }
        if let dictationModelID, !dictationModelID.isEmpty { ids.append(dictationModelID) }
        return Array(Set(ids)).sorted()
    }
}

enum ModelStackPreset: String, CaseIterable, Identifiable {
    case recommended, lightweight
    var id: String { rawValue }
    var title: String { self == .recommended ? "Balanced local" : "Lightweight local" }
    var subtitle: String {
        self == .recommended
            ? "Balanced local models for everyday work."
            : "Smaller downloads and a lighter memory footprint."
    }
    var transcription: TranscriptionModelChoice {
        self == .recommended ? .recommended : .qwenASR06B
    }
    var mainModelID: String {
        self == .recommended ? ModelCatalog.defaultSummarizationID : ModelCatalog.compactFallbackID
    }
    var autocompleteModelID: String { ModelCatalog.recommendedCotypingID }
    var patch: ModelSelectionPatch {
        ModelSelectionPatch(
            transcription: transcription,
            backend: .builtIn,
            assistantModelID: mainModelID,
            autocompleteModelID: autocompleteModelID)
    }
    static func matching(_ settings: AppSettings) -> Self? {
        allCases.first { $0.patch.matches(settings) }
    }
}

enum ModelSettingsPresentation {
    static func assistantName(_ settings: AppSettings) -> String {
        if settings.summarizerBackend == .openAICompatible {
            switch settings.openAIModel.lowercased() {
            case "z-ai/glm-5.3-flash": return "GLM 5.3 Flash"
            default: break
            }
        }
        return settings.thinkModelDisplayName
    }

    static func destination(_ settings: AppSettings) -> String {
        switch InferencePresentation(settings: settings) {
        case .onDevice: "On this Mac"
        case .remote(let host): host == "openrouter.ai" ? "OpenRouter · Remote" : "\(host) · Remote"
        case .blocked: "Connection needs attention"
        }
    }

    static func setupLocation(_ settings: AppSettings) -> String {
        switch InferencePresentation(settings: settings) {
        case .onDevice: "On this Mac"
        case .remote: "On-device + remote"
        case .blocked: "Connection needs attention"
        }
    }

    static func dictationLabel(_ settings: AppSettings) -> String {
        let effective = settings.dictationCompositionTextEngineSettings
        if effective.dictationCompositionBuiltInModelID.isEmpty
            || ModelCatalog.entry(id: effective.dictationCompositionBuiltInModelID,
                                  custom: settings.customBuiltInModels) == nil {
            switch InferencePresentation(settings: effective) {
            case .onDevice: return "Uses Think · On this Mac"
            case .remote(let host): return "Uses Think · \(host == "openrouter.ai" ? "OpenRouter" : host)"
            case .blocked: return "Uses Think · Connection blocked"
            }
        }
        return assistantName(effective) + " · On this Mac"
    }

    static func uses(of entryID: String, in settings: AppSettings) -> [String] {
        var uses: [String] = []
        if settings.summarizerBackend == .builtIn, settings.builtInModelID == entryID { uses.append("Think") }
        if settings.cotypingBuiltInModelID == entryID { uses.append("Autocomplete") }
        let composition = settings.dictationCompositionTextEngineSettings
        if composition.summarizerBackend == .builtIn, composition.builtInModelID == entryID {
            uses.append("Dictation composition")
        }
        return uses
    }

    static func estimatedTranscriptionBytes(
        _ choice: TranscriptionModelChoice,
        granite: GraniteSpeechModelConfiguration
    ) -> Int64? {
        switch choice {
        case .qwenASR17B: 3_200_000_000
        case .qwenASR06B: 700_000_000
        case .parakeetV2, .parakeetV3: 600_000_000
        case .graniteTurbo: 950_000_000
        case .whisperLarge: 1_600_000_000
        case .graniteSpeech:
            safeCombinedBytes(granite.model.sizeBytes, granite.projector.sizeBytes)
        case .cohere, .senseVoice, .gigaamRussian: nil
        }
    }

    static func sizeLabel(_ entry: ModelCatalog.Entry) -> String {
        let estimate = entry.sizeGB * 1_000_000_000
        let estimatedBytes = estimate.isFinite && estimate > 0 && estimate < Double(Int64.max) ? Int64(estimate) : 0
        let bytes = entry.sizeBytes ?? estimatedBytes
        return bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "Size varies"
    }

    private static func safeCombinedBytes(_ first: Int64, _ second: Int64) -> Int64? {
        let total = first.addingReportingOverflow(second)
        return total.overflow || total.partialValue <= 0 ? nil : total.partialValue
    }
}
