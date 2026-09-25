import Foundation
import CryptoKit

/// Identifies just the configuration exercised by a role's check. Unrelated
/// writing or appearance changes must not invalidate transcription results.
struct ModelCheckIdentity: Equatable {
    let parts: [String]

    init(role: ModelRole, settings: AppSettings, apiKey: String = "") {
        func entryIdentity(_ id: String) -> String {
            guard let entry = ModelCatalog.entry(id: id, custom: settings.customBuiltInModels) else { return id }
            return [id, entry.fileName, entry.url, entry.expectedSHA256 ?? ""].joined(separator: "\n")
        }
        switch role {
        case .transcribe:
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let granite = settings.transcriptionModel == .graniteSpeech
                ? (try? encoder.encode(settings.graniteSpeechModel))?.base64EncodedString() ?? "" : ""
            parts = [settings.transcriptionModel.id, granite, settings.transcriptionLanguage.rawValue,
                     settings.transcriptionPrompt]
        case .think:
            switch settings.summarizerBackend {
            case .builtIn: parts = [settings.summarizerBackend.rawValue, entryIdentity(settings.builtInModelID)]
            case .appleIntelligence: parts = [settings.summarizerBackend.rawValue]
            case .ollama:
                parts = [settings.summarizerBackend.rawValue, settings.ollamaBaseURL, settings.ollamaModel,
                         InferencePresentation(settings: settings).label]
            case .openAICompatible:
                let digest = SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
                parts = [settings.summarizerBackend.rawValue, settings.openAIBaseURL, settings.openAIModel,
                         settings.openRouterDataPolicy.rawValue, InferencePresentation(settings: settings).label, digest]
            }
        case .autocomplete:
            parts = [entryIdentity(settings.cotypingBuiltInModelID), String(settings.cotypingInProcessRuntime),
                     String(settings.cotypingMaxWords)]
        }
    }
}

struct ModelCheckResult {
    let identity: ModelCheckIdentity
    let checkedAt: Date
    let elapsed: TimeInterval
    let failure: String?

    var label: String {
        if let failure { return "Check failed: \(failure)" }
        return "Check passed · " + checkedAt.formatted(date: .omitted, time: .shortened)
    }
}

@MainActor
final class ModelCheckController: ObservableObject {
    @Published private(set) var results: [ModelRole: ModelCheckResult] = [:]
    @Published private(set) var testingRole: ModelRole?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var isTesting: Bool { task != nil }

    func invalidate(_ roles: Set<ModelRole>) {
        if let testingRole, roles.contains(testingRole) { cancel() }
        for role in roles { results[role] = nil }
    }

    func invalidate(for settings: AppSettings) {
        let key = settings.summarizerBackend == .openAICompatible ? settings.openAIAPIKey : ""
        results = results.filter { role, result in
            result.identity == ModelCheckIdentity(role: role, settings: settings, apiKey: key)
        }
        // A running check compares its own identity again before publishing.
    }

    func run(_ roles: [ModelRole], app: AppState) {
        guard !isTesting else { return }
        let token = UUID()
        generation = token
        task = Task { [weak self, weak app] in
            guard let self, let app else { return }
            for role in roles {
                guard !Task.isCancelled, generation == token else { break }
                guard app.modelRoles.snapshot[role].isReady else { continue }
                let config = app.settings
                let key = config.summarizerBackend == .openAICompatible ? config.openAIAPIKey : ""
                let identity = ModelCheckIdentity(role: role, settings: config, apiKey: key)
                testingRole = role
                results[role] = nil
                let started = Date()
                let failure: String?
                do {
                    try await Self.check(role, app: app, configuration: config)
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
                guard !Task.isCancelled, generation == token else { break }
                let currentKey = app.settings.summarizerBackend == .openAICompatible ? app.settings.openAIAPIKey : ""
                guard app.modelRoles.snapshot[role].isReady,
                      identity == ModelCheckIdentity(role: role, settings: app.settings, apiKey: currentKey) else { continue }
                results[role] = ModelCheckResult(
                    identity: identity, checkedAt: Date(), elapsed: Date().timeIntervalSince(started), failure: failure)
            }
            guard generation == token else { return }
            testingRole = nil
            task = nil
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        testingRole = nil
    }

    private static func check(_ role: ModelRole, app: AppState, configuration: AppSettings) async throws {
        switch role {
        case .transcribe:
            guard let fixture = Bundle.main.url(forResource: "speech", withExtension: "wav", subdirectory: "ModelChecks") else {
                throw ModelDownloadManager.PreparationError.failed("The spoken model-check fixture is missing from the app.")
            }
            try await checkTranscription(engine: configuration.transcriptionEngine(),
                                         fixture: fixture, configuration: configuration)
        case .think:
            let engine = try await app.thinkExecution.makeTextEngine(
                configuration, priority: .interactive, purpose: "model setup check")
            try Task.checkCancellation()
            let response = try await engine.generate(
                system: PromptTemplates.connectivityTestSystem,
                prompt: PromptTemplates.connectivityTestPrompt, context: [])
            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelDownloadManager.PreparationError.failed("The model returned an empty response. Try another check.")
            }
        case .autocomplete:
            _ = try await app.cotyping.previewSuggestion(precedingText: "The local model setup is", sampleOnly: true)
        }
    }

    static func checkTranscription(engine: any TranscriptionEngine, fixture: URL,
                                   configuration: AppSettings) async throws {
        try await engine.prepare()
        try Task.checkCancellation()
        let transcript = try await engine.transcribe(
            audio: fixture, language: configuration.transcriptionLanguage.code,
            prompt: configuration.transcriptionPrompt)
        try Task.checkCancellation()
        guard transcript.segments.contains(where: { segment in
            segment.text.unicodeScalars.contains(where: CharacterSet.letters.contains)
        }) else {
            throw ModelDownloadManager.PreparationError.failed(
                "The model returned no words for the spoken sample. Check the selected language and try again.")
        }
    }
}

extension ModelRole {
    var settingsTitle: String {
        switch self {
        case .transcribe: "Transcribe"
        case .think: "Think"
        case .autocomplete: "Autocomplete"
        }
    }
    var settingsIcon: String {
        switch self {
        case .transcribe: "waveform"
        case .think: "brain"
        case .autocomplete: "text.cursor"
        }
    }
}
