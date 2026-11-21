import Foundation

enum OpenRouterDataPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case privateOnly
    case accountPolicy

    var id: String { rawValue }

    var providerDataCollectionValue: String {
        switch self {
        case .privateOnly: "deny"
        case .accountPolicy: "allow"
        }
    }
}

struct AppSettings: Codable, Equatable {
    enum AutoRecordMode: String, Codable, CaseIterable, Identifiable {
        case automatic = "Record automatically"
        case ask = "Ask via notification"
        case manual = "Never auto-record"
        var id: String { rawValue }
    }

    enum SummarizerBackend: String, Codable, CaseIterable, Identifiable {
        case builtIn = "Built-in (no setup)"
        case appleIntelligence = "Apple Intelligence"
        case ollama = "Ollama"
        case openAICompatible = "OpenAI-compatible server"
        case chatGPTPlan = "ChatGPT plan"
        case claudePlan = "Claude plan"
        case antigravityPlan = "Antigravity plan"
        case geminiPlan = "Gemini plan"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .builtIn: "Built-in (on-device)"
            case .appleIntelligence, .ollama, .openAICompatible,
                    .chatGPTPlan, .claudePlan, .antigravityPlan, .geminiPlan: rawValue
            }
        }
    }

    enum ScreenContextCaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case activityOnly = "Activity only"
        case accessibleText = "Text context"
        case visualContext = "Text + visual context"

        var id: String { rawValue }
        var capturesText: Bool { self != .activityOnly }
        var capturesPixels: Bool { self == .visualContext }

        var detail: String {
            switch self {
            case .activityOnly:
                "Records the active app and window title only."
            case .accessibleText:
                "Reads visible interface text through Accessibility; no screenshots are stored."
            case .visualContext:
                "Pairs accessible text with an encrypted screenshot, using local OCR only when needed."
            }
        }
    }

    enum MemoryRoutineKind: String, Codable, CaseIterable, Identifiable, Sendable {
        case postMeetingFollowUp
        case dailyStandup
        case weeklyWorkLog
        case unfinishedActions
        case localJournal

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .postMeetingFollowUp: "Post-meeting follow-up"
            case .dailyStandup: "Daily stand-up"
            case .weeklyWorkLog: "Weekly work log"
            case .unfinishedActions: "Unfinished actions"
            case .localJournal: "Local journal"
            }
        }

        var detail: String {
            switch self {
            case .postMeetingFollowUp:
                "After processing, drafts a local follow-up from that meeting's summary and outcomes."
            case .dailyStandup:
                "Builds a morning brief from yesterday's meetings, activity totals, and open action candidates."
            case .weeklyWorkLog:
                "Collects the last seven days of meetings, decisions, actions, and app-time totals."
            case .unfinishedActions:
                "Rolls up extracted action items from the last fourteen days without sending or assigning them."
            case .localJournal:
                "Writes a private daily note from the local digest, meetings, app usage, and saved moments."
            }
        }

        var isEventDriven: Bool { self == .postMeetingFollowUp }
        var isWeekly: Bool { self == .weeklyWorkLog }
    }

    var autoRecordMode: AutoRecordMode = .ask
    var stopDebounceSeconds: TimeInterval = Self.defaultStopDebounceSeconds

    var calendarDetectionEnabled: Bool = false
    var useCalendarTitles: Bool = true
    var requireCalendarForBrowser: Bool = false

    var menuBarOnly: Bool = true
    var appTheme: AppTheme = .system
    var appLanguage: AppLanguage = .system
    var textSize: AppTextSize = .standard

    var transcriptionModel: TranscriptionModelChoice = TranscriptionModelChoice.recommended
    var graniteSpeechModel = GraniteSpeechModelConfiguration.defaultModel
    var funASRNanoModelDirectory: String = ""
    var remoteTranscriptionBaseURL: String = ""
    var remoteTranscriptionModel: String = ""
    var approvedRemoteTranscriptionOrigins: [String] = []
    var transcriptionLanguage: TranscriptionLanguage = .auto
    var transcriptionPrompt: String = ""
    var autoTranscriptionVocabulary: Bool = true
    var suggestActionCompletion: Bool = true
    var liveRadarEnabled: Bool = false
    var museLiveTextEnabled: Bool = false
    var turnByTurnLiveTextEnabled: Bool = false
    var museScreenAnswersEnabled: Bool = false
    var liveRadarPanelEnabled: Bool = true
    var liveRadarPanelHiddenFromCapture: Bool = true
    var liveAnswersEnabled: Bool = false
    var liveAnswerFolders: [String] = []
    var meetingNotesUseCalendarContext: Bool = true
    var meetingNotesUseScreenTitles: Bool = true
    var useCalendarAgenda: Bool = false
    var autoTranscribe: Bool = true
    var autoSummarize: Bool = true
    var handOffActionsAfterSummary: Bool = false
    var startHandoffsAutomatically: Bool = false
    var speechVoice: KokoroVoice = .heart
    var speechSpeed: Double = 1.0

    var transcriptionModelDisplayName: String {
        switch transcriptionModel {
        case .graniteSpeech: graniteSpeechModel.displayName
        case .remoteServer: remoteTranscription.displayName
        default: transcriptionModel.displayName
        }
    }

    var remoteTranscription: RemoteTranscriptionConfiguration {
        RemoteTranscriptionConfiguration(
            baseURL: remoteTranscriptionBaseURL,
            model: remoteTranscriptionModel,
            approvedOrigins: approvedRemoteTranscriptionOrigins)
    }

    var transcriptionPresentation: InferencePresentation {
        transcriptionModel.isRemote ? remoteTranscription.presentation : .onDevice
    }

    var remoteTranscriptionAPIKey: String {
        get { KeychainSecrets.string(account: Self.remoteTranscriptionAPIKeyAccount) ?? "" }
        set { KeychainSecrets.setString(newValue, account: Self.remoteTranscriptionAPIKeyAccount) }
    }

    static let remoteTranscriptionAPIKeyAccount = "remote-transcription-api-key"

    static func remoteTranscriptionRequestKey(transcriptionBaseURL: String,
                                              thinkBaseURL: String,
                                              ownKey: String,
                                              thinkKey: () -> String) -> String {
        guard ownKey.isEmpty else { return ownKey }
        let transcription = RemoteTranscriptionConfiguration(
            baseURL: transcriptionBaseURL, model: "", approvedOrigins: []).origin
        let think = URL(string: thinkBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap(InferenceEndpointPolicy.origin(for:))
        guard let transcription, transcription == think else { return "" }
        return thinkKey()
    }

    func transcriptionEngine(
        for choice: TranscriptionModelChoice? = nil
    ) -> any TranscriptionEngine {
        let choice = choice ?? transcriptionModel
        if choice == .graniteSpeech {
            return GraniteSpeechEngine.configured(graniteSpeechModel)
        }
        if choice == .remoteServer {
            let transcriptionBaseURL = remoteTranscriptionBaseURL
            let thinkBaseURL = openAIBaseURL
            var engine = RemoteTranscriptionEngine(configuration: remoteTranscription, apiKey: {
                Self.remoteTranscriptionRequestKey(
                    transcriptionBaseURL: transcriptionBaseURL,
                    thinkBaseURL: thinkBaseURL,
                    ownKey: KeychainSecrets.string(account: Self.remoteTranscriptionAPIKeyAccount) ?? "",
                    thinkKey: { KeychainSecrets.string(account: "openai-compatible-api-key") ?? "" })
            })
            engine.stillAllowed = { try RemoteTranscriptionConsent.check($0) }
            return engine
        }
        if choice == .funASRNano { return FunASRNanoEngine(directory: funASRNanoModelDirectory) }
        if choice == .appleSpeech { return AppleSpeechEngine.configured(language: transcriptionLanguage.code) }
        return choice.engine
    }

    var dictationEnabled: Bool = false
    var dictationIntent: DictationIntent = .transcribe
    var dictationUseScreenContext = false
    var dictationUseVisibleContext = false
    var dictationUseMeetingMemory = false
    var dictationUseScreenMemory = false
    var dictationTriggerMode: DictationTriggerMode = .pushToTalk
    var dictationShortcut: DictationShortcut = .handyDefault
    var dictationOutputMode: DictationOutputMode = .pasteIntoFocusedApp
    var dictationShowOverlay: Bool = true
    var dictationPlaysStartSound: Bool = true
    var dictationMicrophoneID: String = ""
    var dictationLivePreview: Bool = true
    var dictationRetainAudio: Bool = false
    var dictationCompositionBuiltInModelID: String = ""

    var trackingEnabled: Bool = true

    var semanticSearchEnabled: Bool = true

    var screenContextCaptureMode: ScreenContextCaptureMode = .activityOnly
    var screenshotsEnabled: Bool = false
    var effectiveScreenContextCaptureMode: ScreenContextCaptureMode {
        if screenContextCaptureMode == .activityOnly, screenshotsEnabled {
            return .visualContext
        }
        return screenContextCaptureMode
    }
    var screenshotIntervalMinutes: Double = 3
    var meetingVisualContextEnabled: Bool = false
    var excludedScreenDomains: String = ""
    var excludedScreenDomainList: [String] {
        excludedScreenDomains
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    var retentionDays: Int = 14
    var keepOCRTextForever: Bool = false
    var quickRecallEnabled: Bool = false
    var quickRecallShortcut: DictationShortcut = .quickRecallDefault
    var selectionActionsEnabled: Bool = false
    var selectionActionsShortcut: DictationShortcut = .selectionActionsDefault
    var windowHandoffEnabled: Bool = false
    var windowHandoffShortcut: DictationShortcut = .windowHandoffDefault

    var dayDigestAutoEnabled: Bool = true
    var dayDigestHour: Int = 18
    var dayDigestCustomPrompt: String = ""

    var codingAgentEvidenceEnabled: Bool = true
    var codingAgentReadsClaudeCode: Bool = true
    var codingAgentReadsCodex: Bool = true
    var codingAgentReadsAntigravity: Bool = true
    var codingAgentReadsT3Code: Bool = true
    var codingAgentExcludedFolders: String = ""
    var codingAgentExcludedFolderList: [String] {
        codingAgentExcludedFolders
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    var enabledCodingAgents: Set<CodingAgentKind> {
        guard codingAgentEvidenceEnabled else { return [] }
        var agents: Set<CodingAgentKind> = []
        if codingAgentReadsClaudeCode { agents.insert(.claudeCode) }
        if codingAgentReadsCodex { agents.insert(.codex) }
        if codingAgentReadsAntigravity { agents.insert(.antigravity) }
        if codingAgentReadsT3Code { agents.insert(.t3Code) }
        return agents
    }

    var codingAgentNotesEnabled: Bool = false
    var codingAgentNoteAgents: Set<CodingAgentKind> {
        guard codingAgentNotesEnabled else { return [] }
        var agents: Set<CodingAgentKind> = []
        if codingAgentReadsClaudeCode { agents.insert(.claudeCode) }
        if codingAgentReadsCodex { agents.insert(.codex) }
        return agents
    }

    enum DailyMemoryExportFormat: String, Codable, CaseIterable, Identifiable {
        case markdown = "Markdown"
        case obsidian = "Obsidian"
        case logseq = "Logseq"

        var id: String { rawValue }
    }

    var dailyMemoryExportEnabled: Bool = false
    var dailyMemoryExportFolder: String = ""
    var dailyMemoryExportFormat: DailyMemoryExportFormat = .markdown
    var dailyMemoryExportHour: Int = 18

    var meetingNoteExportEnabled: Bool = false
    var meetingNoteExportFolder: String = ""
    var meetingNoteExportFormat: DailyMemoryExportFormat = .markdown
    var meetingNoteExportIncludesTranscript: Bool = true

    var dreamingEnabled: Bool = true
    var dreamingHour: Int = 4

    var companionSharingEnabled: Bool = false
    var companionShareMeetings: Bool = true
    var companionShareTranscripts: Bool = true
    var companionShareDigests: Bool = true
    var companionShareTimeline: Bool = true
    var companionShareWindowTitles: Bool = true
    var companionSharePeople: Bool = true
    var companionShareProjects: Bool = true
    var companionHistory: CompanionHistoryWindow = .all
    var companionAnswersQuestions: Bool = true
    var companionAcceptsRecordings: Bool = true
    var companionPort: Int = CompanionSharing.defaultPort
    var companionAdvertisesOnBonjour: Bool = true
    var dreamingFirstEligibleDayKey: String?
    var askMemoryEnabled: Bool = true
    var fileSearchEnabled: Bool = false
    var fileSearchFolders: [String] = []
    var fileSearchIncludesMedia: Bool = true
    var fileSearchReadsOnBattery: Bool = false
    var personalLearningEnabled: Bool = true
    var personalLearningFromDictation: Bool = false

    var learnsFromDictation: Bool {
        askMemoryEnabled && personalLearningEnabled && personalLearningFromDictation
    }

    var memoryRoutinesEnabled: Bool = false
    var memoryRoutineFolder: String = ""
    var enabledMemoryRoutines: [MemoryRoutineKind] = MemoryRoutineKind.allCases
    var memoryRoutineHour: Int = 8
    var memoryRoutineWeekday: Int = 6
    var excludedApps: String = "1Password, Keychain Access, Bitwarden, KeePassXC"
    var excludedAppList: [String] {
        excludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var summarizerBackend: SummarizerBackend = .builtIn
    var builtInModelID: String = ModelCatalog.defaultSummarizationID
    var customBuiltInModels: [ModelCatalog.Entry] = []
    var ollamaBaseURL: String = "http://localhost:11434"
    var ollamaModel: String = ""
    var openAIBaseURL: String = "http://localhost:1234/v1"
    var openAIModel: String = ""
    var openRouterDataPolicy: OpenRouterDataPolicy = .privateOnly
    var modelDownloadSource: ModelDownloadSource = .huggingFace
    var approvedRemoteInferenceOrigins: [String] = []
    var chatGPTPlanModel: String = ""
    var claudePlanModel: String = ""
    var antigravityPlanModel: String = ""
    var geminiPlanModel: String = ""
    var chatGPTPlanNoticeAcknowledged: Bool = false
    var generationBudgetPreset: GenerationBudgetPreset = .standard
    var thinkReasoningLevel: ThinkReasoningLevel = .automatic
    var agentReasoningLevel: ThinkReasoningLevel?

    var effectiveAgentReasoningLevel: ThinkReasoningLevel {
        agentReasoningLevel ?? thinkReasoningLevel
    }

    var usesRemoteMainLLM: Bool {
        let base: String
        switch summarizerBackend {
        case .builtIn, .appleIntelligence: return false
        case .chatGPTPlan, .claudePlan, .antigravityPlan, .geminiPlan:
            return SubscriptionPlan(backend: summarizerBackend)?.isApproved(in: self) == true
        case .ollama: base = ollamaBaseURL
        case .openAICompatible: base = openAIBaseURL
        }
        guard let url = URL(string: base) else { return false }
        return InferenceEndpointPolicy.requiresApproval(url)
            && InferenceEndpointPolicy.isAllowed(
                url, approvedOrigins: approvedRemoteInferenceOrigins)
    }

    var allowsAutomaticMainInference: Bool {
        let base: String
        switch summarizerBackend {
        case .builtIn, .appleIntelligence: return true
        case .chatGPTPlan, .claudePlan, .antigravityPlan, .geminiPlan:
            return SubscriptionPlan(backend: summarizerBackend)?.isApproved(in: self) == true
        case .ollama: base = ollamaBaseURL
        case .openAICompatible: base = openAIBaseURL
        }
        guard let url = URL(string: base) else { return false }
        return InferenceEndpointPolicy.isAllowed(url, approvedOrigins: approvedRemoteInferenceOrigins)
    }

    var thinkModelDisplayName: String {
        switch summarizerBackend {
        case .builtIn:
            return ModelCatalog.entry(
                id: builtInModelID,
                custom: customBuiltInModels)?.displayName
                ?? summarizerBackend.displayName
        case .appleIntelligence:
            return summarizerBackend.displayName
        case .ollama:
            let model = ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? summarizerBackend.displayName : model
        case .openAICompatible:
            let model = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? summarizerBackend.displayName : model
        case .chatGPTPlan:
            let model = chatGPTPlanModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? summarizerBackend.displayName : "\(model) · ChatGPT plan"
        case .claudePlan:
            let model = claudePlanModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? summarizerBackend.displayName : "\(model) · Claude plan"
        case .antigravityPlan:
            let model = antigravityPlanModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? summarizerBackend.displayName : "\(model) · Antigravity plan"
        case .geminiPlan:
            let model = geminiPlanModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? summarizerBackend.displayName : "\(model) · Gemini plan"
        }
    }
    var openAIAPIKey: String {
        get {
            KeychainSecrets.string(account: "openai-compatible-api-key") ?? ""
        }
        set {
            KeychainSecrets.setString(newValue, account: "openai-compatible-api-key")
        }
    }

    var metaModelAPIKey: String {
        get { KeychainSecrets.string(account: MetaModelAPI.apiKeyAccount) ?? "" }
        set { KeychainSecrets.setString(newValue, account: MetaModelAPI.apiKeyAccount) }
    }

    var effectiveMetaModelAPIKey: String {
#if LOKALBOT_UI_TEST_HOST
        if let key = MuseUITestTransport.apiKey { return key }
#endif
        let own = metaModelAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        guard let think = URL(string: openAIBaseURL),
              RemoteInferenceGate.origin(for: think) == MetaModelAPI.origin else { return "" }
        return openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var metaModelAPIApproved: Bool {
        InferenceEndpointPolicy.isAllowed(MetaModelAPI.baseURL, approvedOrigins: approvedRemoteInferenceOrigins)
    }

    var noteTemplate: NoteTemplate = .meeting
    var summaryLanguage: SummaryLanguage = .matchTranscript
    var multiSpeakerDiarization: Bool = true
    var diarizationModel: DiarizationModel = .nemotron3
    var microphoneIsUser: Bool = true

    var cotypingEnabled: Bool = false
    var cotypingUserName: String = ""
    var cotypingStyleNote: String = ""
    var cotypingMultiLine: Bool = false
    var cotypingMaxWords: Int = 4
    var cotypingDebounceMs: Int = Self.defaultCotypingDebounceMs
    var cotypingAcceptGranularity: CotypingAcceptGranularity = .word
    var cotypingAcceptKey: CotypingAcceptKey = .tab
    var cotypingFullAcceptKey: CotypingFullAcceptKey = .backtick
    var cotypingAutoAcceptTrailingPunctuation: Bool = false
    var cotypingEscapeBehavior: CotypingEscapeBehavior = .pause
    var cotypingAddSpaceAfterAccept: Bool = false
    var cotypingExcludedApps: String = "1Password, Keychain Access, Bitwarden, KeePassXC, Terminal, iTerm"
    var cotypingExcludedDomains: String = ""
    var cotypingSuggestInIntegratedTerminals: Bool = false
    var cotypingUseAppContext: Bool = true
    var cotypingUseClipboard: Bool = true
    var cotypingUseVisibleContext: Bool = true
    var cotypingUseWindowText: Bool = true
    var cotypingUseMeetingMemory: Bool = false
    var cotypingUseScreenMemory: Bool = false
    var cotypingMatchHostStyle: Bool = true
    var cotypingChromiumEnhancedAccessibility: Bool = true
    var cotypingMirrorPreference: CotypingMirrorPreference = .auto
    var cotypingAutocorrect: Bool = true
    var cotypingEmoji: Bool = true
    var cotypingMacros: Bool = true
    var cotypingLanguages: String = ""
    var cotypingExtendedContext: String = ""
    var cotypingBuiltInModelID: String = ModelCatalog.recommendedCotypingID
    var cotypingInProcessRuntime: Bool = true
    var cotypingBackend: CotypingBackend = .onDevice
    var cotypingServerBaseURL: String = ""
    var cotypingServerModel: String = ""
    var cotypingThinkServerModel: String = ""
    var cotypingServerRequestStyle: CotypingServerRequestStyle = .automatic
    var approvedRemoteAutocompleteOrigins: [String] = []
    var cotypingUseLocalLearning: Bool = true
    var cotypingLearningExamplesInPrompt: Int = 3

    static let currentMeetingSettingsVersion: Int = 1
    static let defaultStopDebounceSeconds: TimeInterval = 15
    static let legacyDefaultStopDebounceSeconds: TimeInterval = 60
    static let minimumStopDebounceSeconds: TimeInterval = 5
    static let maximumStopDebounceSeconds: TimeInterval = 120
    static let currentCotypingSettingsVersion: Int = 4
    static let cotypistDefaultsCotypingSettingsVersion: Int = 4
    static let previousDefaultCotypingMaxWords: Int = 3
    static let legacyPreviewCotypingSettingsVersion: Int = 0
    static let legacyPreviewCotypingMaxWords: Int = 2
    static let legacyPreviewCotypingDebounceMs: Int = 150
    static let lowLatencyCotypingDebounceMs: Int = 20
    static let defaultCotypingDebounceMs: Int = 100
    static let legacyDefaultCotypingDebounceMs: Int = 350
    static let maximumCotypingDebounceMs: Int = 1_000
    static let minimumSpeechSpeed: Double = 0.5
    static let maximumSpeechSpeed: Double = 2.0

    static func migratedCotypingMaxWords(_ words: Int, decodedSettingsVersion: Int) -> Int {
        if decodedSettingsVersion == legacyPreviewCotypingSettingsVersion,
           words == legacyPreviewCotypingMaxWords {
            return AppSettings().cotypingMaxWords
        }
        if decodedSettingsVersion < cotypistDefaultsCotypingSettingsVersion,
           words == previousDefaultCotypingMaxWords {
            return AppSettings().cotypingMaxWords
        }
        return words
    }

    static func migratedCotypingAutoAcceptTrailingPunctuation(
        _ attached: Bool, decodedSettingsVersion: Int
    ) -> Bool {
        decodedSettingsVersion < cotypistDefaultsCotypingSettingsVersion
            ? AppSettings().cotypingAutoAcceptTrailingPunctuation
            : attached
    }

    static func migratedCotypingDebounceMs(_ milliseconds: Int, decodedSettingsVersion: Int) -> Int {
        let clamped = min(
            maximumCotypingDebounceMs,
            max(CotypingDebouncePolicy.minimumMilliseconds, milliseconds))
        if decodedSettingsVersion == legacyPreviewCotypingSettingsVersion,
           clamped == legacyPreviewCotypingDebounceMs {
            return defaultCotypingDebounceMs
        }
        if decodedSettingsVersion < currentCotypingSettingsVersion,
           clamped == legacyDefaultCotypingDebounceMs {
            return defaultCotypingDebounceMs
        }
        if decodedSettingsVersion < currentCotypingSettingsVersion,
           milliseconds == lowLatencyCotypingDebounceMs {
            return defaultCotypingDebounceMs
        }
        return clamped
    }

    static func migratedStopDebounceSeconds(_ seconds: TimeInterval,
                                            decodedSettingsVersion: Int) -> TimeInterval {
        guard seconds.isFinite else { return defaultStopDebounceSeconds }
        let clamped = min(maximumStopDebounceSeconds, max(minimumStopDebounceSeconds, seconds))
        if decodedSettingsVersion < currentMeetingSettingsVersion,
           clamped == legacyDefaultStopDebounceSeconds {
            return defaultStopDebounceSeconds
        }
        return clamped
    }

    static func clampedSpeechSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return AppSettings().speechSpeed }
        return min(maximumSpeechSpeed, max(minimumSpeechSpeed, speed))
    }

    var cotypingExcludedAppList: [String] {
        cotypingExcludedApps
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var cotypingExcludedDomainList: [String] {
        cotypingExcludedDomains
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var cotypingPersonalization: CotypingPersonalization {
        let langs = cotypingLanguages.trimmingCharacters(in: .whitespaces)
        let notes = cotypingExtendedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return CotypingPersonalization(
            userName: cotypingUserName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cotypingUserName,
            styleNote: cotypingStyleNote.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cotypingStyleNote,
            languageHint: langs.isEmpty ? nil : "The text is usually written in \(langs).",
            isMultiLine: cotypingMultiLine,
            appContextEnabled: cotypingUseAppContext,
            extendedContext: notes.isEmpty ? nil : notes)
    }

    var cotypingMaxResponseTokens: Int {
        let languageAware = (cotypingMaxWords * 13 + 9) / 10
        let base = max(5, languageAware)
        return cotypingMultiLine ? min(base * 2, 120) : min(base, 120)
    }

    var cotypingTextEngineSettings: AppSettings {
        var s = self
        s.summarizerBackend = .builtIn
        s.builtInModelID = cotypingBuiltInModelID
        return s
    }

    var dictationCompositionTextEngineSettings: AppSettings {
        guard !dictationCompositionBuiltInModelID.isEmpty,
              ModelCatalog.entry(
                id: dictationCompositionBuiltInModelID,
                custom: customBuiltInModels) != nil else {
            return self
        }
        var s = self
        s.summarizerBackend = .builtIn
        s.builtInModelID = dictationCompositionBuiltInModelID
        s.thinkReasoningLevel = .automatic
        return s
    }

    var echoCancellation: Bool = false

    static let key = "lokalbotv3.settings"

    private static var defaults: UserDefaults {
        if let suite = UITestRuntime.defaultsSuiteName,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }

    private enum CodingKeys: String, CodingKey {
        case meetingSettingsVersion
        case echoCancellation
        case autoRecordMode
        case stopDebounceSeconds
        case calendarDetectionEnabled
        case useCalendarTitles
        case requireCalendarForBrowser
        case menuBarOnly
        case appTheme
        case appLanguage
        case textSize
        case transcriptionModel
        case funASRNanoModelDirectory
        case remoteTranscriptionBaseURL
        case remoteTranscriptionModel
        case approvedRemoteTranscriptionOrigins
        case graniteSpeechModel
        case transcriptionLanguage
        case languageHint
        case transcriptionPrompt
        case autoTranscriptionVocabulary
        case suggestActionCompletion
        case liveRadarEnabled
        case museLiveTextEnabled
        case turnByTurnLiveTextEnabled
        case museScreenAnswersEnabled
        case liveRadarPanelEnabled
        case liveRadarPanelHiddenFromCapture
        case liveAnswersEnabled
        case liveAnswerFolders
        case meetingNotesUseCalendarContext
        case meetingNotesUseScreenTitles
        case useCalendarAgenda
        case autoTranscribe
        case autoSummarize
        case handOffActionsAfterSummary
        case startHandoffsAutomatically
        case speechVoice
        case speechSpeed
        case dictationEnabled
        case dictationIntent, dictationUseScreenContext
        case dictationUseVisibleContext, dictationUseMeetingMemory, dictationUseScreenMemory
        case dictationTriggerMode
        case dictationShortcut
        case dictationOutputMode
        case dictationShowOverlay
        case dictationPlaysStartSound
        case dictationMicrophoneID
        case dictationLivePreview
        case dictationRetainAudio
        case dictationCompositionBuiltInModelID
        case trackingEnabled
        case semanticSearchEnabled
        case screenContextCaptureMode
        case screenshotsEnabled
        case screenshotIntervalMinutes
        case meetingVisualContextEnabled
        case excludedScreenDomains
        case retentionDays
        case keepOCRTextForever
        case quickRecallEnabled
        case quickRecallShortcut
        case selectionActionsEnabled
        case selectionActionsShortcut
        case windowHandoffEnabled
        case windowHandoffShortcut
        case dayDigestAutoEnabled
        case dayDigestHour
        case dayDigestCustomPrompt
        case codingAgentEvidenceEnabled
        case codingAgentReadsClaudeCode
        case codingAgentReadsCodex
        case codingAgentReadsAntigravity
        case codingAgentReadsT3Code
        case codingAgentExcludedFolders
        case codingAgentNotesEnabled
        case dailyMemoryExportEnabled
        case dailyMemoryExportFolder
        case dailyMemoryExportFormat
        case dailyMemoryExportHour
        case meetingNoteExportEnabled
        case meetingNoteExportFolder
        case meetingNoteExportFormat
        case meetingNoteExportIncludesTranscript
        case dreamingEnabled
        case dreamingHour
        case dreamingFirstEligibleDayKey
        case companionSharingEnabled
        case companionShareMeetings
        case companionShareTranscripts
        case companionShareDigests
        case companionShareTimeline
        case companionShareWindowTitles
        case companionSharePeople
        case companionShareProjects
        case companionHistory
        case companionAnswersQuestions
        case companionAcceptsRecordings
        case companionPort
        case companionAdvertisesOnBonjour
        case askMemoryEnabled
        case fileSearchEnabled
        case fileSearchFolders
        case fileSearchIncludesMedia
        case fileSearchReadsOnBattery
        case personalLearningEnabled
        case personalLearningFromDictation
        case memoryRoutinesEnabled
        case memoryRoutineFolder
        case enabledMemoryRoutines
        case memoryRoutineHour
        case memoryRoutineWeekday
        case excludedApps
        case summarizerBackend
        case builtInModelID
        case customBuiltInModels
        case ollamaBaseURL
        case ollamaModel
        case openAIBaseURL
        case openAIModel
        case openRouterDataPolicy
        case modelDownloadSource
        case approvedRemoteInferenceOrigins
        case chatGPTPlanModel
        case claudePlanModel
        case antigravityPlanModel
        case geminiPlanModel
        case chatGPTPlanNoticeAcknowledged
        case generationBudgetPreset
        case thinkReasoningLevel
        case agentReasoningLevel
        case noteTemplate
        case summaryLanguage
        case microphoneIsUser
        case multiSpeakerDiarization
        case diarizationModel
        case cotypingEnabled
        case cotypingUserName
        case cotypingStyleNote
        case cotypingMultiLine
        case cotypingSettingsVersion
        case cotypingMaxWords
        case cotypingDebounceMs
        case cotypingAcceptGranularity
        case cotypingAcceptKey
        case cotypingFullAcceptKey
        case cotypingAutoAcceptTrailingPunctuation
        case cotypingEscapeBehavior
        case cotypingAddSpaceAfterAccept
        case cotypingExcludedApps
        case cotypingExcludedDomains
        case cotypingSuggestInIntegratedTerminals
        case cotypingUseAppContext
        case cotypingUseClipboard
        case cotypingUseVisibleContext
        case cotypingUseWindowText
        case cotypingUseMeetingMemory
        case cotypingUseScreenMemory
        case cotypingMatchHostStyle
        case cotypingChromiumEnhancedAccessibility
        case cotypingMirrorPreference
        case cotypingAutocorrect
        case cotypingEmoji
        case cotypingMacros
        case cotypingLanguages
        case cotypingExtendedContext
        case cotypingBuiltInModelID
        case cotypingInProcessRuntime
        case cotypingBackend
        case cotypingServerBaseURL
        case cotypingServerModel
        case cotypingThinkServerModel
        case cotypingServerRequestStyle
        case approvedRemoteAutocompleteOrigins
        case cotypingUseLocalLearning
        case cotypingLearningExamplesInPrompt
    }

    var corruptedSettingsKeys: [String] = []

    static let wholeStoreCorruptionMarker = "all settings"

    static func load(from defaults: UserDefaults = Self.defaults) -> AppSettings {
        let loaded: AppSettings
        if let data = defaults.data(forKey: key) {
            do {
                loaded = try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                var reset = AppSettings()
                reset.corruptedSettingsKeys = [wholeStoreCorruptionMarker]
                loaded = reset
            }
        } else {
            loaded = AppSettings()
        }
#if LOKALBOT_UI_TEST_HOST
        var staged = loaded
        let env = ProcessInfo.processInfo.environment
        if env["LOKALBOT_COTYPING_DEMO"] == "1" { staged.cotypingEnabled = true }
        if env["LOKALBOT_DICTATION_DEMO"] == "1" { staged.dictationEnabled = true }
        return staged
#else
        return loaded
#endif
    }

    func save(to defaults: UserDefaults = Self.defaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    init() {}

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentMeetingSettingsVersion, forKey: .meetingSettingsVersion)
        try c.encode(echoCancellation, forKey: .echoCancellation)
        try c.encode(autoRecordMode, forKey: .autoRecordMode)
        try c.encode(
            Self.migratedStopDebounceSeconds(
                stopDebounceSeconds,
                decodedSettingsVersion: Self.currentMeetingSettingsVersion),
            forKey: .stopDebounceSeconds)
        try c.encode(calendarDetectionEnabled, forKey: .calendarDetectionEnabled)
        try c.encode(useCalendarTitles, forKey: .useCalendarTitles)
        try c.encode(requireCalendarForBrowser, forKey: .requireCalendarForBrowser)
        try c.encode(menuBarOnly, forKey: .menuBarOnly)
        try c.encode(appTheme, forKey: .appTheme)
        try c.encode(appLanguage, forKey: .appLanguage)
        try c.encode(textSize, forKey: .textSize)
        try c.encode(transcriptionModel, forKey: .transcriptionModel)
        try c.encode(funASRNanoModelDirectory, forKey: .funASRNanoModelDirectory)
        try c.encode(remoteTranscriptionBaseURL, forKey: .remoteTranscriptionBaseURL)
        try c.encode(remoteTranscriptionModel, forKey: .remoteTranscriptionModel)
        try c.encode(approvedRemoteTranscriptionOrigins, forKey: .approvedRemoteTranscriptionOrigins)
        try c.encode(graniteSpeechModel, forKey: .graniteSpeechModel)
        try c.encode(transcriptionLanguage, forKey: .transcriptionLanguage)
        try c.encode(transcriptionPrompt, forKey: .transcriptionPrompt)
        try c.encode(autoTranscriptionVocabulary, forKey: .autoTranscriptionVocabulary)
        try c.encode(suggestActionCompletion, forKey: .suggestActionCompletion)
        try c.encode(liveRadarEnabled, forKey: .liveRadarEnabled)
        try c.encode(museLiveTextEnabled, forKey: .museLiveTextEnabled)
        try c.encode(turnByTurnLiveTextEnabled, forKey: .turnByTurnLiveTextEnabled)
        try c.encode(museScreenAnswersEnabled, forKey: .museScreenAnswersEnabled)
        try c.encode(liveRadarPanelEnabled, forKey: .liveRadarPanelEnabled)
        try c.encode(liveRadarPanelHiddenFromCapture, forKey: .liveRadarPanelHiddenFromCapture)
        try c.encode(liveAnswersEnabled, forKey: .liveAnswersEnabled)
        try c.encode(liveAnswerFolders, forKey: .liveAnswerFolders)
        try c.encode(meetingNotesUseCalendarContext, forKey: .meetingNotesUseCalendarContext)
        try c.encode(meetingNotesUseScreenTitles, forKey: .meetingNotesUseScreenTitles)
        try c.encode(useCalendarAgenda, forKey: .useCalendarAgenda)
        try c.encode(autoTranscribe, forKey: .autoTranscribe)
        try c.encode(autoSummarize, forKey: .autoSummarize)
        try c.encode(handOffActionsAfterSummary, forKey: .handOffActionsAfterSummary)
        try c.encode(startHandoffsAutomatically, forKey: .startHandoffsAutomatically)
        try c.encode(speechVoice, forKey: .speechVoice)
        try c.encode(Self.clampedSpeechSpeed(speechSpeed), forKey: .speechSpeed)
        try c.encode(dictationEnabled, forKey: .dictationEnabled)
        try c.encode(dictationIntent, forKey: .dictationIntent)
        try c.encode(dictationUseScreenContext, forKey: .dictationUseScreenContext)
        try c.encode(dictationUseVisibleContext, forKey: .dictationUseVisibleContext)
        try c.encode(dictationUseMeetingMemory, forKey: .dictationUseMeetingMemory)
        try c.encode(dictationUseScreenMemory, forKey: .dictationUseScreenMemory)
        try c.encode(dictationTriggerMode, forKey: .dictationTriggerMode)
        try c.encode(dictationShortcut, forKey: .dictationShortcut)
        try c.encode(dictationOutputMode, forKey: .dictationOutputMode)
        try c.encode(dictationShowOverlay, forKey: .dictationShowOverlay)
        try c.encode(dictationPlaysStartSound, forKey: .dictationPlaysStartSound)
        try c.encode(dictationMicrophoneID, forKey: .dictationMicrophoneID)
        try c.encode(dictationLivePreview, forKey: .dictationLivePreview)
        try c.encode(dictationRetainAudio, forKey: .dictationRetainAudio)
        try c.encode(
            dictationCompositionBuiltInModelID,
            forKey: .dictationCompositionBuiltInModelID)
        try c.encode(trackingEnabled, forKey: .trackingEnabled)
        try c.encode(semanticSearchEnabled, forKey: .semanticSearchEnabled)
        try c.encode(effectiveScreenContextCaptureMode, forKey: .screenContextCaptureMode)
        try c.encode(effectiveScreenContextCaptureMode.capturesPixels, forKey: .screenshotsEnabled)
        try c.encode(screenshotIntervalMinutes, forKey: .screenshotIntervalMinutes)
        try c.encode(meetingVisualContextEnabled, forKey: .meetingVisualContextEnabled)
        try c.encode(excludedScreenDomains, forKey: .excludedScreenDomains)
        try c.encode(retentionDays, forKey: .retentionDays)
        try c.encode(keepOCRTextForever, forKey: .keepOCRTextForever)
        try c.encode(quickRecallEnabled, forKey: .quickRecallEnabled)
        try c.encode(quickRecallShortcut, forKey: .quickRecallShortcut)
        try c.encode(selectionActionsEnabled, forKey: .selectionActionsEnabled)
        try c.encode(selectionActionsShortcut, forKey: .selectionActionsShortcut)
        try c.encode(windowHandoffEnabled, forKey: .windowHandoffEnabled)
        try c.encode(windowHandoffShortcut, forKey: .windowHandoffShortcut)
        try c.encode(dayDigestAutoEnabled, forKey: .dayDigestAutoEnabled)
        try c.encode(min(23, max(0, dayDigestHour)), forKey: .dayDigestHour)
        try c.encode(dayDigestCustomPrompt, forKey: .dayDigestCustomPrompt)
        try c.encode(codingAgentEvidenceEnabled, forKey: .codingAgentEvidenceEnabled)
        try c.encode(codingAgentReadsClaudeCode, forKey: .codingAgentReadsClaudeCode)
        try c.encode(codingAgentReadsCodex, forKey: .codingAgentReadsCodex)
        try c.encode(codingAgentReadsAntigravity, forKey: .codingAgentReadsAntigravity)
        try c.encode(codingAgentReadsT3Code, forKey: .codingAgentReadsT3Code)
        try c.encode(codingAgentExcludedFolders, forKey: .codingAgentExcludedFolders)
        try c.encode(codingAgentNotesEnabled, forKey: .codingAgentNotesEnabled)
        try c.encode(dailyMemoryExportEnabled, forKey: .dailyMemoryExportEnabled)
        try c.encode(dailyMemoryExportFolder, forKey: .dailyMemoryExportFolder)
        try c.encode(dailyMemoryExportFormat, forKey: .dailyMemoryExportFormat)
        try c.encode(min(23, max(0, dailyMemoryExportHour)), forKey: .dailyMemoryExportHour)
        try c.encode(meetingNoteExportEnabled, forKey: .meetingNoteExportEnabled)
        try c.encode(meetingNoteExportFolder, forKey: .meetingNoteExportFolder)
        try c.encode(meetingNoteExportFormat, forKey: .meetingNoteExportFormat)
        try c.encode(meetingNoteExportIncludesTranscript, forKey: .meetingNoteExportIncludesTranscript)
        try c.encode(dreamingEnabled, forKey: .dreamingEnabled)
        try c.encode(min(23, max(0, dreamingHour)), forKey: .dreamingHour)
        try c.encodeIfPresent(
            dreamingFirstEligibleDayKey,
            forKey: .dreamingFirstEligibleDayKey)
        try c.encode(companionSharingEnabled, forKey: .companionSharingEnabled)
        try c.encode(companionShareMeetings, forKey: .companionShareMeetings)
        try c.encode(companionShareTranscripts, forKey: .companionShareTranscripts)
        try c.encode(companionShareDigests, forKey: .companionShareDigests)
        try c.encode(companionShareTimeline, forKey: .companionShareTimeline)
        try c.encode(companionShareWindowTitles, forKey: .companionShareWindowTitles)
        try c.encode(companionSharePeople, forKey: .companionSharePeople)
        try c.encode(companionShareProjects, forKey: .companionShareProjects)
        try c.encode(companionHistory, forKey: .companionHistory)
        try c.encode(companionAnswersQuestions, forKey: .companionAnswersQuestions)
        try c.encode(companionAcceptsRecordings, forKey: .companionAcceptsRecordings)
        try c.encode(CompanionSharing.clampedPort(companionPort), forKey: .companionPort)
        try c.encode(companionAdvertisesOnBonjour, forKey: .companionAdvertisesOnBonjour)
        try c.encode(askMemoryEnabled, forKey: .askMemoryEnabled)
        try c.encode(fileSearchEnabled, forKey: .fileSearchEnabled)
        try c.encode(fileSearchFolders, forKey: .fileSearchFolders)
        try c.encode(fileSearchIncludesMedia, forKey: .fileSearchIncludesMedia)
        try c.encode(fileSearchReadsOnBattery, forKey: .fileSearchReadsOnBattery)
        try c.encode(personalLearningEnabled, forKey: .personalLearningEnabled)
        try c.encode(personalLearningFromDictation, forKey: .personalLearningFromDictation)
        try c.encode(memoryRoutinesEnabled, forKey: .memoryRoutinesEnabled)
        try c.encode(memoryRoutineFolder, forKey: .memoryRoutineFolder)
        try c.encode(enabledMemoryRoutines, forKey: .enabledMemoryRoutines)
        try c.encode(min(23, max(0, memoryRoutineHour)), forKey: .memoryRoutineHour)
        try c.encode(min(7, max(1, memoryRoutineWeekday)), forKey: .memoryRoutineWeekday)
        try c.encode(excludedApps, forKey: .excludedApps)
        try c.encode(summarizerBackend, forKey: .summarizerBackend)
        try c.encode(builtInModelID, forKey: .builtInModelID)
        try c.encode(customBuiltInModels, forKey: .customBuiltInModels)
        try c.encode(ollamaBaseURL, forKey: .ollamaBaseURL)
        try c.encode(ollamaModel, forKey: .ollamaModel)
        try c.encode(openAIBaseURL, forKey: .openAIBaseURL)
        try c.encode(openAIModel, forKey: .openAIModel)
        try c.encode(openRouterDataPolicy, forKey: .openRouterDataPolicy)
        try c.encode(modelDownloadSource, forKey: .modelDownloadSource)
        try c.encode(approvedRemoteInferenceOrigins, forKey: .approvedRemoteInferenceOrigins)
        try c.encode(chatGPTPlanModel, forKey: .chatGPTPlanModel)
        try c.encode(claudePlanModel, forKey: .claudePlanModel)
        try c.encode(antigravityPlanModel, forKey: .antigravityPlanModel)
        try c.encode(geminiPlanModel, forKey: .geminiPlanModel)
        try c.encode(chatGPTPlanNoticeAcknowledged, forKey: .chatGPTPlanNoticeAcknowledged)
        try c.encode(generationBudgetPreset, forKey: .generationBudgetPreset)
        try c.encode(thinkReasoningLevel, forKey: .thinkReasoningLevel)
        try c.encodeIfPresent(agentReasoningLevel, forKey: .agentReasoningLevel)
        try c.encode(noteTemplate, forKey: .noteTemplate)
        try c.encode(summaryLanguage, forKey: .summaryLanguage)
        try c.encode(multiSpeakerDiarization, forKey: .multiSpeakerDiarization)
        try c.encode(diarizationModel, forKey: .diarizationModel)
        try c.encode(microphoneIsUser, forKey: .microphoneIsUser)
        try c.encode(cotypingEnabled, forKey: .cotypingEnabled)
        try c.encode(cotypingUserName, forKey: .cotypingUserName)
        try c.encode(cotypingStyleNote, forKey: .cotypingStyleNote)
        try c.encode(cotypingMultiLine, forKey: .cotypingMultiLine)
        try c.encode(Self.currentCotypingSettingsVersion, forKey: .cotypingSettingsVersion)
        try c.encode(cotypingMaxWords, forKey: .cotypingMaxWords)
        try c.encode(
            Self.migratedCotypingDebounceMs(
                cotypingDebounceMs,
                decodedSettingsVersion: Self.currentCotypingSettingsVersion),
            forKey: .cotypingDebounceMs)
        try c.encode(cotypingAcceptGranularity, forKey: .cotypingAcceptGranularity)
        try c.encode(cotypingAcceptKey, forKey: .cotypingAcceptKey)
        try c.encode(cotypingFullAcceptKey, forKey: .cotypingFullAcceptKey)
        try c.encode(cotypingAutoAcceptTrailingPunctuation, forKey: .cotypingAutoAcceptTrailingPunctuation)
        try c.encode(cotypingEscapeBehavior, forKey: .cotypingEscapeBehavior)
        try c.encode(cotypingAddSpaceAfterAccept, forKey: .cotypingAddSpaceAfterAccept)
        try c.encode(cotypingExcludedApps, forKey: .cotypingExcludedApps)
        try c.encode(cotypingExcludedDomains, forKey: .cotypingExcludedDomains)
        try c.encode(cotypingSuggestInIntegratedTerminals, forKey: .cotypingSuggestInIntegratedTerminals)
        try c.encode(cotypingUseAppContext, forKey: .cotypingUseAppContext)
        try c.encode(cotypingUseClipboard, forKey: .cotypingUseClipboard)
        try c.encode(cotypingUseVisibleContext, forKey: .cotypingUseVisibleContext)
        try c.encode(cotypingUseWindowText, forKey: .cotypingUseWindowText)
        try c.encode(cotypingUseMeetingMemory, forKey: .cotypingUseMeetingMemory)
        try c.encode(cotypingUseScreenMemory, forKey: .cotypingUseScreenMemory)
        try c.encode(cotypingMatchHostStyle, forKey: .cotypingMatchHostStyle)
        try c.encode(cotypingChromiumEnhancedAccessibility, forKey: .cotypingChromiumEnhancedAccessibility)
        try c.encode(cotypingMirrorPreference, forKey: .cotypingMirrorPreference)
        try c.encode(cotypingAutocorrect, forKey: .cotypingAutocorrect)
        try c.encode(cotypingEmoji, forKey: .cotypingEmoji)
        try c.encode(cotypingMacros, forKey: .cotypingMacros)
        try c.encode(cotypingLanguages, forKey: .cotypingLanguages)
        try c.encode(cotypingExtendedContext, forKey: .cotypingExtendedContext)
        try c.encode(cotypingBuiltInModelID, forKey: .cotypingBuiltInModelID)
        try c.encode(cotypingInProcessRuntime, forKey: .cotypingInProcessRuntime)
        try c.encode(cotypingBackend, forKey: .cotypingBackend)
        try c.encode(cotypingServerBaseURL, forKey: .cotypingServerBaseURL)
        try c.encode(cotypingServerModel, forKey: .cotypingServerModel)
        try c.encode(cotypingThinkServerModel, forKey: .cotypingThinkServerModel)
        try c.encode(cotypingServerRequestStyle, forKey: .cotypingServerRequestStyle)
        try c.encode(approvedRemoteAutocompleteOrigins, forKey: .approvedRemoteAutocompleteOrigins)
        try c.encode(cotypingUseLocalLearning, forKey: .cotypingUseLocalLearning)
        try c.encode(cotypingLearningExamplesInPrompt, forKey: .cotypingLearningExamplesInPrompt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        var corrupted: [String] = []
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            guard c.contains(key) else { return fallback }
            do {
                return try c.decode(T.self, forKey: key)
            } catch {
                corrupted.append(key.stringValue)
                return fallback
            }
        }
        let meetingSettingsVersion = decode(.meetingSettingsVersion, 0)
        echoCancellation = decode(.echoCancellation, defaults.echoCancellation)
        autoRecordMode = decode(.autoRecordMode, c.contains(.autoRecordMode) ? defaults.autoRecordMode : .automatic)
        stopDebounceSeconds = Self.migratedStopDebounceSeconds(
            decode(.stopDebounceSeconds, defaults.stopDebounceSeconds),
            decodedSettingsVersion: meetingSettingsVersion)
        calendarDetectionEnabled = decode(.calendarDetectionEnabled, defaults.calendarDetectionEnabled)
        useCalendarTitles = decode(.useCalendarTitles, defaults.useCalendarTitles)
        requireCalendarForBrowser = decode(.requireCalendarForBrowser, defaults.requireCalendarForBrowser)
        menuBarOnly = decode(.menuBarOnly, defaults.menuBarOnly)
        appTheme = decode(.appTheme, defaults.appTheme)
        appLanguage = decode(.appLanguage, defaults.appLanguage)
        textSize = decode(.textSize, defaults.textSize)
        transcriptionModel = decode(.transcriptionModel, defaults.transcriptionModel)
        funASRNanoModelDirectory = decode(.funASRNanoModelDirectory, defaults.funASRNanoModelDirectory)
        remoteTranscriptionBaseURL = decode(.remoteTranscriptionBaseURL, defaults.remoteTranscriptionBaseURL)
        remoteTranscriptionModel = decode(.remoteTranscriptionModel, defaults.remoteTranscriptionModel)
        approvedRemoteTranscriptionOrigins = decode(
            .approvedRemoteTranscriptionOrigins, defaults.approvedRemoteTranscriptionOrigins)
        graniteSpeechModel = decode(.graniteSpeechModel, defaults.graniteSpeechModel)
        if c.contains(.transcriptionLanguage) {
            transcriptionLanguage = decode(.transcriptionLanguage, defaults.transcriptionLanguage)
        } else if let legacyHint = try? c.decode(String.self, forKey: .languageHint) {
            transcriptionLanguage = TranscriptionLanguage.fromLegacyHint(legacyHint)
        } else {
            transcriptionLanguage = defaults.transcriptionLanguage
        }
        transcriptionPrompt = decode(.transcriptionPrompt, defaults.transcriptionPrompt)
        autoTranscriptionVocabulary = decode(.autoTranscriptionVocabulary, defaults.autoTranscriptionVocabulary)
        suggestActionCompletion = decode(.suggestActionCompletion, defaults.suggestActionCompletion)
        museLiveTextEnabled = decode(.museLiveTextEnabled, defaults.museLiveTextEnabled)
        turnByTurnLiveTextEnabled = decode(.turnByTurnLiveTextEnabled, defaults.turnByTurnLiveTextEnabled)
        museScreenAnswersEnabled = decode(.museScreenAnswersEnabled, defaults.museScreenAnswersEnabled)
        liveRadarPanelEnabled = decode(.liveRadarPanelEnabled, defaults.liveRadarPanelEnabled)
        liveRadarPanelHiddenFromCapture = decode(.liveRadarPanelHiddenFromCapture, defaults.liveRadarPanelHiddenFromCapture)
        liveAnswersEnabled = decode(.liveAnswersEnabled, defaults.liveAnswersEnabled)
        liveAnswerFolders = decode(.liveAnswerFolders, defaults.liveAnswerFolders)
        meetingNotesUseCalendarContext = decode(.meetingNotesUseCalendarContext, defaults.meetingNotesUseCalendarContext)
        meetingNotesUseScreenTitles = decode(.meetingNotesUseScreenTitles, defaults.meetingNotesUseScreenTitles)
        useCalendarAgenda = decode(.useCalendarAgenda, defaults.useCalendarAgenda)
        autoTranscribe = decode(.autoTranscribe, defaults.autoTranscribe)
        autoSummarize = decode(.autoSummarize, defaults.autoSummarize)
        handOffActionsAfterSummary = decode(.handOffActionsAfterSummary, defaults.handOffActionsAfterSummary)
        startHandoffsAutomatically = decode(.startHandoffsAutomatically, defaults.startHandoffsAutomatically)
        speechVoice = decode(.speechVoice, defaults.speechVoice)
        speechSpeed = Self.clampedSpeechSpeed(decode(.speechSpeed, defaults.speechSpeed))
        dictationEnabled = decode(.dictationEnabled, defaults.dictationEnabled)
        dictationIntent = decode(.dictationIntent, .compose)
        dictationUseScreenContext = decode(.dictationUseScreenContext, true)
        dictationUseVisibleContext = decode(.dictationUseVisibleContext, false)
        dictationUseMeetingMemory = decode(.dictationUseMeetingMemory, false)
        dictationUseScreenMemory = decode(.dictationUseScreenMemory, false)
        dictationTriggerMode = decode(.dictationTriggerMode, defaults.dictationTriggerMode)
        let storedShortcut = decode(.dictationShortcut, defaults.dictationShortcut)
        dictationShortcut = storedShortcut.problem == nil ? storedShortcut : defaults.dictationShortcut
        dictationOutputMode = decode(.dictationOutputMode, defaults.dictationOutputMode)
        dictationShowOverlay = decode(.dictationShowOverlay, defaults.dictationShowOverlay)
        dictationPlaysStartSound = decode(.dictationPlaysStartSound, defaults.dictationPlaysStartSound)
        dictationMicrophoneID = decode(.dictationMicrophoneID, defaults.dictationMicrophoneID)
        dictationLivePreview = decode(.dictationLivePreview, defaults.dictationLivePreview)
        dictationRetainAudio = decode(.dictationRetainAudio, defaults.dictationRetainAudio)
        dictationCompositionBuiltInModelID = decode(
            .dictationCompositionBuiltInModelID, defaults.dictationCompositionBuiltInModelID)
        trackingEnabled = decode(.trackingEnabled, defaults.trackingEnabled)
        semanticSearchEnabled = decode(.semanticSearchEnabled, defaults.semanticSearchEnabled)
        let legacyScreenshotsEnabled = decode(.screenshotsEnabled, true)
        screenContextCaptureMode = decode(
            .screenContextCaptureMode,
            c.contains(.screenContextCaptureMode) ? defaults.screenContextCaptureMode : (legacyScreenshotsEnabled ? .visualContext : .activityOnly))
        screenshotsEnabled = screenContextCaptureMode.capturesPixels
        screenshotIntervalMinutes = decode(.screenshotIntervalMinutes, defaults.screenshotIntervalMinutes)
        meetingVisualContextEnabled = decode(
            .meetingVisualContextEnabled, defaults.meetingVisualContextEnabled)
        excludedScreenDomains = decode(.excludedScreenDomains, defaults.excludedScreenDomains)
        retentionDays = decode(.retentionDays, defaults.retentionDays)
        keepOCRTextForever = decode(.keepOCRTextForever, defaults.keepOCRTextForever)
        quickRecallEnabled = decode(.quickRecallEnabled, defaults.quickRecallEnabled)
        let storedQuickRecallShortcut = decode(.quickRecallShortcut, defaults.quickRecallShortcut)
        quickRecallShortcut = storedQuickRecallShortcut.quickRecallProblem == nil
            ? storedQuickRecallShortcut : defaults.quickRecallShortcut
        selectionActionsEnabled = decode(.selectionActionsEnabled, defaults.selectionActionsEnabled)
        let storedSelectionActionsShortcut = decode(.selectionActionsShortcut, defaults.selectionActionsShortcut)
        selectionActionsShortcut = storedSelectionActionsShortcut.quickRecallProblem == nil
            ? storedSelectionActionsShortcut : defaults.selectionActionsShortcut
        windowHandoffEnabled = decode(.windowHandoffEnabled, defaults.windowHandoffEnabled)
        let storedWindowHandoffShortcut = decode(.windowHandoffShortcut, defaults.windowHandoffShortcut)
        windowHandoffShortcut = storedWindowHandoffShortcut.quickRecallProblem == nil
            ? storedWindowHandoffShortcut : defaults.windowHandoffShortcut
        dayDigestAutoEnabled = decode(.dayDigestAutoEnabled, defaults.dayDigestAutoEnabled)
        dayDigestHour = min(23, max(0, decode(.dayDigestHour, defaults.dayDigestHour)))
        dayDigestCustomPrompt = decode(.dayDigestCustomPrompt, defaults.dayDigestCustomPrompt)
        codingAgentEvidenceEnabled = decode(
            .codingAgentEvidenceEnabled, defaults.codingAgentEvidenceEnabled)
        codingAgentReadsClaudeCode = decode(
            .codingAgentReadsClaudeCode, defaults.codingAgentReadsClaudeCode)
        codingAgentReadsCodex = decode(.codingAgentReadsCodex, defaults.codingAgentReadsCodex)
        codingAgentReadsAntigravity = decode(
            .codingAgentReadsAntigravity, defaults.codingAgentReadsAntigravity)
        codingAgentReadsT3Code = decode(.codingAgentReadsT3Code, defaults.codingAgentReadsT3Code)
        codingAgentExcludedFolders = decode(
            .codingAgentExcludedFolders, defaults.codingAgentExcludedFolders)
        codingAgentNotesEnabled = decode(.codingAgentNotesEnabled, defaults.codingAgentNotesEnabled)
        dailyMemoryExportEnabled = decode(
            .dailyMemoryExportEnabled, defaults.dailyMemoryExportEnabled)
        dailyMemoryExportFolder = decode(
            .dailyMemoryExportFolder, defaults.dailyMemoryExportFolder)
        dailyMemoryExportFormat = decode(
            .dailyMemoryExportFormat, defaults.dailyMemoryExportFormat)
        dailyMemoryExportHour = min(
            23, max(0, decode(.dailyMemoryExportHour, defaults.dailyMemoryExportHour)))
        meetingNoteExportEnabled = decode(
            .meetingNoteExportEnabled, defaults.meetingNoteExportEnabled)
        meetingNoteExportFolder = decode(
            .meetingNoteExportFolder, defaults.meetingNoteExportFolder)
        meetingNoteExportFormat = decode(
            .meetingNoteExportFormat, defaults.meetingNoteExportFormat)
        meetingNoteExportIncludesTranscript = decode(
            .meetingNoteExportIncludesTranscript, defaults.meetingNoteExportIncludesTranscript)
        dreamingEnabled = decode(.dreamingEnabled, defaults.dreamingEnabled)
        dreamingHour = min(23, max(0, decode(.dreamingHour, defaults.dreamingHour)))
        dreamingFirstEligibleDayKey = decode(.dreamingFirstEligibleDayKey, String?.none)
        companionSharingEnabled = decode(.companionSharingEnabled, defaults.companionSharingEnabled)
        companionShareMeetings = decode(.companionShareMeetings, defaults.companionShareMeetings)
        companionShareTranscripts = decode(.companionShareTranscripts, defaults.companionShareTranscripts)
        companionShareDigests = decode(.companionShareDigests, defaults.companionShareDigests)
        companionShareTimeline = decode(.companionShareTimeline, defaults.companionShareTimeline)
        companionShareWindowTitles = decode(.companionShareWindowTitles, defaults.companionShareWindowTitles)
        companionSharePeople = decode(.companionSharePeople, defaults.companionSharePeople)
        companionShareProjects = decode(.companionShareProjects, defaults.companionShareProjects)
        companionHistory = decode(.companionHistory, defaults.companionHistory)
        companionAnswersQuestions = decode(.companionAnswersQuestions, defaults.companionAnswersQuestions)
        companionAcceptsRecordings = decode(.companionAcceptsRecordings, defaults.companionAcceptsRecordings)
        companionPort = CompanionSharing.clampedPort(decode(.companionPort, defaults.companionPort))
        companionAdvertisesOnBonjour = decode(
            .companionAdvertisesOnBonjour, defaults.companionAdvertisesOnBonjour)
        askMemoryEnabled = decode(.askMemoryEnabled, defaults.askMemoryEnabled)
        fileSearchEnabled = decode(.fileSearchEnabled, defaults.fileSearchEnabled)
        fileSearchFolders = decode(.fileSearchFolders, defaults.fileSearchFolders)
        fileSearchIncludesMedia = decode(.fileSearchIncludesMedia, defaults.fileSearchIncludesMedia)
        fileSearchReadsOnBattery = decode(.fileSearchReadsOnBattery, defaults.fileSearchReadsOnBattery)
        personalLearningEnabled = decode(.personalLearningEnabled, defaults.personalLearningEnabled)
        personalLearningFromDictation = decode(.personalLearningFromDictation, defaults.personalLearningFromDictation)
        memoryRoutinesEnabled = decode(.memoryRoutinesEnabled, defaults.memoryRoutinesEnabled)
        memoryRoutineFolder = decode(.memoryRoutineFolder, defaults.memoryRoutineFolder)
        enabledMemoryRoutines = decode(.enabledMemoryRoutines, defaults.enabledMemoryRoutines)
        memoryRoutineHour = min(
            23, max(0, decode(.memoryRoutineHour, defaults.memoryRoutineHour)))
        memoryRoutineWeekday = min(
            7, max(1, decode(.memoryRoutineWeekday, defaults.memoryRoutineWeekday)))
        excludedApps = decode(.excludedApps, defaults.excludedApps)
        summarizerBackend = decode(.summarizerBackend, defaults.summarizerBackend)
        builtInModelID = decode(.builtInModelID, defaults.builtInModelID)
        customBuiltInModels = decode(.customBuiltInModels, defaults.customBuiltInModels)
        ollamaBaseURL = decode(.ollamaBaseURL, defaults.ollamaBaseURL)
        ollamaModel = decode(.ollamaModel, defaults.ollamaModel)
        openAIBaseURL = decode(.openAIBaseURL, defaults.openAIBaseURL)
        openAIModel = decode(.openAIModel, defaults.openAIModel)
        openRouterDataPolicy = decode(
            .openRouterDataPolicy, defaults.openRouterDataPolicy)
        modelDownloadSource = decode(.modelDownloadSource, defaults.modelDownloadSource)
        approvedRemoteInferenceOrigins = decode(
            .approvedRemoteInferenceOrigins, defaults.approvedRemoteInferenceOrigins)
        liveRadarEnabled = decode(
            .liveRadarEnabled,
            InferenceEndpointPolicy.isAllowed(MetaModelAPI.baseURL, approvedOrigins: approvedRemoteInferenceOrigins))
        chatGPTPlanModel = decode(.chatGPTPlanModel, defaults.chatGPTPlanModel)
        claudePlanModel = decode(.claudePlanModel, defaults.claudePlanModel)
        antigravityPlanModel = decode(.antigravityPlanModel, defaults.antigravityPlanModel)
        geminiPlanModel = decode(.geminiPlanModel, defaults.geminiPlanModel)
        chatGPTPlanNoticeAcknowledged = decode(
            .chatGPTPlanNoticeAcknowledged, defaults.chatGPTPlanNoticeAcknowledged)
        generationBudgetPreset = decode(
            .generationBudgetPreset, defaults.generationBudgetPreset)
        thinkReasoningLevel = decode(.thinkReasoningLevel, defaults.thinkReasoningLevel)
        agentReasoningLevel = decode(.agentReasoningLevel, defaults.agentReasoningLevel)
        noteTemplate = decode(.noteTemplate, defaults.noteTemplate)
        summaryLanguage = decode(.summaryLanguage, defaults.summaryLanguage)
        multiSpeakerDiarization = decode(.multiSpeakerDiarization, defaults.multiSpeakerDiarization)
        diarizationModel = decode(.diarizationModel, .community1)
        microphoneIsUser = decode(.microphoneIsUser, defaults.microphoneIsUser)
        cotypingEnabled = decode(.cotypingEnabled, defaults.cotypingEnabled)
        cotypingUserName = decode(.cotypingUserName, defaults.cotypingUserName)
        cotypingStyleNote = decode(.cotypingStyleNote, defaults.cotypingStyleNote)
        cotypingMultiLine = decode(.cotypingMultiLine, defaults.cotypingMultiLine)
        let cotypingSettingsVersion = decode(.cotypingSettingsVersion, 0)
        cotypingMaxWords = Self.migratedCotypingMaxWords(
            decode(.cotypingMaxWords, defaults.cotypingMaxWords),
            decodedSettingsVersion: cotypingSettingsVersion)
        cotypingDebounceMs = Self.migratedCotypingDebounceMs(
            decode(.cotypingDebounceMs, defaults.cotypingDebounceMs),
            decodedSettingsVersion: cotypingSettingsVersion)
        cotypingAcceptGranularity = decode(
            .cotypingAcceptGranularity, defaults.cotypingAcceptGranularity)
        cotypingAcceptKey = decode(.cotypingAcceptKey, defaults.cotypingAcceptKey)
        cotypingFullAcceptKey = decode(.cotypingFullAcceptKey, defaults.cotypingFullAcceptKey)
        cotypingAutoAcceptTrailingPunctuation = Self.migratedCotypingAutoAcceptTrailingPunctuation(
            decode(.cotypingAutoAcceptTrailingPunctuation, defaults.cotypingAutoAcceptTrailingPunctuation),
            decodedSettingsVersion: cotypingSettingsVersion)
        cotypingAddSpaceAfterAccept = decode(
            .cotypingAddSpaceAfterAccept, defaults.cotypingAddSpaceAfterAccept)
        cotypingEscapeBehavior = decode(.cotypingEscapeBehavior, defaults.cotypingEscapeBehavior)
        cotypingExcludedApps = decode(.cotypingExcludedApps, defaults.cotypingExcludedApps)
        cotypingExcludedDomains = decode(.cotypingExcludedDomains, defaults.cotypingExcludedDomains)
        cotypingSuggestInIntegratedTerminals = decode(
            .cotypingSuggestInIntegratedTerminals,
            defaults.cotypingSuggestInIntegratedTerminals)
        cotypingUseAppContext = decode(.cotypingUseAppContext, defaults.cotypingUseAppContext)
        cotypingUseClipboard = decode(.cotypingUseClipboard, defaults.cotypingUseClipboard)
        cotypingUseVisibleContext = decode(.cotypingUseVisibleContext, false)
        cotypingUseWindowText = decode(.cotypingUseWindowText, true)
        cotypingUseMeetingMemory = decode(.cotypingUseMeetingMemory, defaults.cotypingUseMeetingMemory)
        cotypingUseScreenMemory = decode(.cotypingUseScreenMemory, defaults.cotypingUseScreenMemory)
        cotypingMatchHostStyle = decode(.cotypingMatchHostStyle, defaults.cotypingMatchHostStyle)
        cotypingChromiumEnhancedAccessibility = decode(
            .cotypingChromiumEnhancedAccessibility, defaults.cotypingChromiumEnhancedAccessibility)
        cotypingMirrorPreference = decode(
            .cotypingMirrorPreference, defaults.cotypingMirrorPreference)
        cotypingAutocorrect = decode(.cotypingAutocorrect, defaults.cotypingAutocorrect)
        cotypingEmoji = decode(.cotypingEmoji, defaults.cotypingEmoji)
        cotypingMacros = decode(.cotypingMacros, defaults.cotypingMacros)
        cotypingLanguages = decode(.cotypingLanguages, defaults.cotypingLanguages)
        cotypingExtendedContext = decode(.cotypingExtendedContext, defaults.cotypingExtendedContext)
        cotypingBuiltInModelID = decode(.cotypingBuiltInModelID, defaults.cotypingBuiltInModelID)
        cotypingInProcessRuntime = decode(.cotypingInProcessRuntime, defaults.cotypingInProcessRuntime)
        cotypingBackend = decode(.cotypingBackend, defaults.cotypingBackend)
        cotypingServerBaseURL = decode(.cotypingServerBaseURL, defaults.cotypingServerBaseURL)
        cotypingServerModel = decode(.cotypingServerModel, defaults.cotypingServerModel)
        cotypingThinkServerModel = decode(.cotypingThinkServerModel, defaults.cotypingThinkServerModel)
        cotypingServerRequestStyle = decode(
            .cotypingServerRequestStyle, defaults.cotypingServerRequestStyle)
        approvedRemoteAutocompleteOrigins = decode(
            .approvedRemoteAutocompleteOrigins, defaults.approvedRemoteAutocompleteOrigins)
        cotypingUseLocalLearning = decode(.cotypingUseLocalLearning, defaults.cotypingUseLocalLearning)
        cotypingLearningExamplesInPrompt = min(5, max(1, decode(
            .cotypingLearningExamplesInPrompt, defaults.cotypingLearningExamplesInPrompt)))
        corruptedSettingsKeys = corrupted
    }
}
