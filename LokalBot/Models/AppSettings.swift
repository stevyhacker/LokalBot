import Foundation

enum OpenRouterDataPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case privateOnly
    case accountPolicy

    var id: String { rawValue }

    /// OpenRouter applies account, API-key, workspace, and guardrail filters
    /// after this request-level provider preference.
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
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .builtIn: "Built-in (on-device)"
            case .appleIntelligence, .ollama, .openAICompatible: rawValue
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

    /// New installs ask before recording a detected meeting. Decoding old
    /// settings preserves the previous automatic default.
    var autoRecordMode: AutoRecordMode = .ask
    /// Seconds the meeting app's own audio must be gone before a meeting counts
    /// as ended.
    var stopDebounceSeconds: TimeInterval = Self.defaultStopDebounceSeconds

    // MARK: Calendar-assisted detection

    /// Read the Mac Calendar to confirm meetings and title recordings. Off by
    /// default and gated on a calendar TCC grant — calendar contents are
    /// sensitive, so this is strictly opt-in.
    var calendarDetectionEnabled: Bool = false
    /// Prefer the matched calendar event's title over the app-derived name.
    var useCalendarTitles: Bool = true
    /// Stricter: only auto-record a browser tab when an active calendar event
    /// with a meeting link backs it (ignores window-title-only matches).
    var requireCalendarForBrowser: Bool = false

    /// Run as a menu-bar-only app: no Dock icon, no window at launch. The
    /// recording state lives in the menu bar (live timer + indicator) so the
    /// main window is never required to know a meeting is being captured.
    /// When off, LokalBot behaves like a normal windowed app with a Dock icon.
    var menuBarOnly: Bool = true

    // MARK: Models (M2)

    var transcriptionModel: TranscriptionModelChoice = TranscriptionModelChoice.recommended
    /// The GGUF/projector pair used when Granite Speech is selected. Older
    /// settings decode to the pinned Q4 default; custom Hugging Face choices
    /// retain immutable revision and checksum metadata.
    var graniteSpeechModel = GraniteSpeechModelConfiguration.defaultModel
    var transcriptionLanguage: TranscriptionLanguage = .auto
    var transcriptionPrompt: String = ""
    var autoTranscribe: Bool = true
    var autoSummarize: Bool = true
    var speechVoice: KokoroVoice = .heart
    var speechSpeed: Double = 1.0

    var transcriptionModelDisplayName: String {
        transcriptionModel == .graniteSpeech
            ? graniteSpeechModel.displayName
            : transcriptionModel.displayName
    }

    func transcriptionEngine(
        for choice: TranscriptionModelChoice? = nil
    ) -> any TranscriptionEngine {
        let choice = choice ?? transcriptionModel
        if choice == .graniteSpeech {
            return GraniteSpeechEngine.configured(graniteSpeechModel)
        }
        return choice.engine
    }

    // MARK: - Dictation

    /// Handy-style system-wide dictation: press the shortcut, speak, transcribe
    /// locally with the selected ASR engine, then deliver the text to the focused app.
    var dictationEnabled: Bool = false
    var dictationIntent: DictationIntent = .transcribe
    var dictationUseScreenContext = false
    var dictationTriggerMode: DictationTriggerMode = .pushToTalk
    var dictationOutputMode: DictationOutputMode = .pasteIntoFocusedApp
    var dictationShowOverlay: Bool = true
    var dictationLivePreview: Bool = true
    var dictationRetainAudio: Bool = false
    /// Optional built-in model used only for dictation composition/rewrite.
    /// Empty preserves the historical behavior of using the Main LLM setting.
    var dictationCompositionBuiltInModelID: String = ""

    /// M4: app/window activity sampling. Fresh installs enable the local day
    /// timeline; macOS Accessibility still gates window-title collection.
    var trackingEnabled: Bool = true

    /// M6: embedding-based semantic search (Harrier, downloaded on first use).
    var semanticSearchEnabled: Bool = true

    // M5: new installs start with activity only; text and pixels are opt-in, while
    // macOS Accessibility and Screen Recording permissions still gate capture.
    // The legacy boolean remains encoded so older builds can read a new settings
    // blob safely.
    var screenContextCaptureMode: ScreenContextCaptureMode = .activityOnly
    var screenshotsEnabled: Bool = false
    /// Compatibility bridge for callers/settings blobs that still set only the
    /// pre-mode screenshot switch.
    var effectiveScreenContextCaptureMode: ScreenContextCaptureMode {
        if screenContextCaptureMode == .activityOnly, screenshotsEnabled {
            return .visualContext
        }
        return screenContextCaptureMode
    }
    var screenshotIntervalMinutes: Double = 3
    /// Capture change-driven visual context while a meeting is recording.
    /// Off by default and throttled more aggressively than normal capture.
    var meetingVisualContextEnabled: Bool = false
    /// Private/incognito browser windows are excluded unless explicitly opted in.
    var capturePrivateWindows: Bool = false
    /// Comma-separated hosts or URL prefixes excluded from both text and pixels.
    var excludedScreenDomains: String = ""
    var excludedScreenDomainList: [String] {
        excludedScreenDomains
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    var retentionDays: Int = 14
    /// Keep OCR'd screen text past `retentionDays`. Off by default — screen
    /// text can be as sensitive as the pixels it came from, so keeping it
    /// forever is an explicit opt-in (Settings → Privacy).
    var keepOCRTextForever: Bool = false
    /// System-wide Quick Recall opens a compact search surface without first
    /// bringing the main app forward. Off by default because a global shortcut
    /// is an explicit automation choice.
    var quickRecallEnabled: Bool = false

    // MARK: - Day digest

    /// Generate the day digest automatically once the clock passes
    /// `dayDigestHour`, so the Timeline's journal fills in without a click.
    /// Runs only when the day has recorded activity or finished meetings; a
    /// digest generated manually earlier in the day is refreshed with the
    /// fuller day at the scheduled hour.
    var dayDigestAutoEnabled: Bool = true
    /// Local wall-clock hour (0...23) after which today's digest is generated.
    var dayDigestHour: Int = 18
    /// Optional guidance folded into the digest prompt — scheduled, manual,
    /// and `--digest` CLI generation alike. Empty keeps the built-in prompt.
    var dayDigestCustomPrompt: String = ""

    // MARK: - Daily memory export

    enum DailyMemoryExportFormat: String, Codable, CaseIterable, Identifiable {
        case markdown = "Markdown"
        case obsidian = "Obsidian"
        case logseq = "Logseq"

        var id: String { rawValue }
    }

    /// Optional, local-only daily export. An empty folder means the scheduler
    /// remains parked even if an older settings blob somehow enables it.
    var dailyMemoryExportEnabled: Bool = false
    var dailyMemoryExportFolder: String = ""
    var dailyMemoryExportFormat: DailyMemoryExportFormat = .markdown
    /// Local wall-clock hour (0...23) at which yesterday/today's memory note is
    /// refreshed. The scheduler clamps decoded values defensively.
    var dailyMemoryExportHour: Int = 18

    // MARK: - Dreaming

    /// Overnight retrospective: while the Mac is otherwise idle after
    /// `dreamingHour`, compile the previous day's evidence into a morning
    /// brief plus a structured local memory of active projects and goals,
    /// shown on Today. On by default; everything it reads and writes stays
    /// inside the storage root, and users can turn it off at any time.
    var dreamingEnabled: Bool = true
    /// Local wall-clock hour (0...23) after which the overnight dream may run.
    /// Nights the Mac slept through catch up at the next launch or wake.
    var dreamingHour: Int = 4
    /// First local calendar day eligible for dreaming during the current
    /// enabled period. Persisting the boundary prevents a multi-day sleep from
    /// silently skipping the last workday, without backfilling history from
    /// before the user opted in.
    var dreamingFirstEligibleDayKey: String?

    // MARK: - Safe routines

    /// Curated local writers only: routines have fixed read scopes, cannot run
    /// shell/network actions, and write solely inside this chosen folder.
    var memoryRoutinesEnabled: Bool = false
    var memoryRoutineFolder: String = ""
    var enabledMemoryRoutines: [MemoryRoutineKind] = MemoryRoutineKind.allCases
    var memoryRoutineHour: Int = 8
    /// Calendar weekday (1 = Sunday ... 7 = Saturday) used by the weekly log.
    var memoryRoutineWeekday: Int = 6
    /// Comma-separated app-name substrings that are never captured;
    /// their time shows as "Private" in the timeline.
    var excludedApps: String = "1Password, Keychain Access, Bitwarden, KeePassXC"
    var excludedAppList: [String] {
        excludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var summarizerBackend: SummarizerBackend = .builtIn
    /// Fresh installs use the fast, broadly compatible 4B model. Existing
    /// installs keep whatever their saved settings blob says.
    var builtInModelID: String = ModelCatalog.defaultSummarizationID
    var customBuiltInModels: [ModelCatalog.Entry] = []
    var ollamaBaseURL: String = "http://localhost:11434"
    var ollamaModel: String = ""
    var openAIBaseURL: String = "http://localhost:1234/v1"
    var openAIModel: String = ""
    /// Per-request OpenRouter provider policy. Private routing remains the
    /// default for both new and migrated installs; following account policy is
    /// an explicit opt-in because Think requests may contain sensitive context.
    var openRouterDataPolicy: OpenRouterDataPolicy = .privateOnly
    /// Origins the user explicitly approved for sending transcript, OCR, and
    /// agent context off this Mac. Loopback endpoints never need approval.
    var approvedRemoteInferenceOrigins: [String] = []
    /// Processing budget for meeting-notes generation. Applies to every Think
    /// backend, not only the connection it is edited alongside.
    var generationBudgetPreset: GenerationBudgetPreset = .standard

    /// True only when the selected Think backend may actually send meeting or
    /// workday text to an approved remote server. Configured-but-unapproved,
    /// insecure, invalid, and loopback endpoints all return false.
    var usesRemoteMainLLM: Bool {
        let base: String
        switch summarizerBackend {
        case .builtIn, .appleIntelligence: return false
        case .ollama: base = ollamaBaseURL
        case .openAICompatible: base = openAIBaseURL
        }
        guard let url = URL(string: base) else { return false }
        return InferenceEndpointPolicy.requiresApproval(url)
            && InferenceEndpointPolicy.isAllowed(
                url, approvedOrigins: approvedRemoteInferenceOrigins)
    }

    /// Name shown for the Think role. Always follows `summarizerBackend`;
    /// leftover `builtInModelID` is ignored when Think is not the local GGUF.
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

    // MARK: - Summarisation shape

    /// Which set of section headings the summariser uses (meeting, lecture,
    /// study guide, podcast, freeform).
    var noteTemplate: NoteTemplate = .meeting
    /// Target language for the summary. `.matchTranscript` auto-detects from
    /// the transcript text; otherwise the prompt forces the chosen language.
    var summaryLanguage: SummaryLanguage = .matchTranscript
    /// Run FluidAudio's neural diarizer on `system.m4a` and split the
    /// catch-all "Them" speaker into "Them 1" / "Them 2" / … by acoustic
    /// similarity. On by default — the model is ~100 MB and adds 30-60 s
    /// of post-processing per meeting.
    var multiSpeakerDiarization: Bool = true
    /// Independently opted-in local Meet observation; never enables Day Memory.
    /// The legacy persisted key is retained; observation is now Accessibility-only.
    var identifySpeakersFromVisuals: Bool = false
    /// User-confirmed voices only. No automatic enrollment from inferred names.
    var rememberSpeakersOnMac: Bool = false

    // MARK: - Cotyping (inline AI autocomplete)

    /// Master switch. Off by default — cotyping needs Accessibility + Input
    /// Monitoring grants and types into other apps, so it is strictly opt-in.
    var cotypingEnabled: Bool = false
    /// Optional author name folded into the prompt as a voice cue.
    var cotypingUserName: String = ""
    /// Optional free-form style guidance ("concise", "British spelling", …).
    var cotypingStyleNote: String = ""
    /// Allow multi-line completions (off keeps suggestions to one line).
    var cotypingMultiLine: Bool = false
    /// Soft length target; drives the per-request token budget. Keep the default
    /// concise so inline suggestions offer the next few words, not a sentence.
    var cotypingMaxWords: Int = 3
    /// Initial idle time before the first measured in-process request, and the
    /// minimum pause on the model-server fallback. Once local latency is known,
    /// the in-process route switches to its documented adaptive tiers.
    var cotypingDebounceMs: Int = Self.defaultCotypingDebounceMs
    /// Paint partial suggestions token-by-token while the model is decoding.
    /// Off by default to match Cotypist/Cotabby's shipped behavior: suggestions
    /// appear once, fully formed, after normalization.
    var cotypingStreamSuggestionsWhileGenerating: Bool = false
    /// How much the primary accept key takes (the full-accept key always takes all).
    var cotypingAcceptGranularity: CotypingAcceptGranularity = .word
    /// Primary accept key (next word/phrase) and the full-accept key (whole tail).
    var cotypingAcceptKey: CotypingAcceptKey = .tab
    var cotypingFullAcceptKey: CotypingFullAcceptKey = .backtick
    /// Accept punctuation attached to the next word in the same Tab press.
    /// Matches CoTabby's default; disabling lets punctuation be accepted as its
    /// own chunk.
    var cotypingAutoAcceptTrailingPunctuation: Bool = true
    /// Add or consume a horizontal space after accepting a completed word.
    /// Off by default to match CoTabby's shipped behavior.
    var cotypingAddSpaceAfterAccept: Bool = false
    /// Comma-separated app-name / bundle-id substrings never suggested into.
    /// Preseeded with password managers and terminals.
    var cotypingExcludedApps: String = "1Password, Keychain Access, Bitwarden, KeePassXC, Terminal, iTerm"
    /// Comma-separated domains where cotyping never runs (bare host or full URL;
    /// subdomains included). Read over Accessibility in browsers only.
    var cotypingExcludedDomains: String = ""
    /// Allow suggestions in xterm.js integrated terminals (VS Code / Cursor /
    /// browser terminals). Off by default because terminal history/completions
    /// conflict with ghost text; standalone terminal apps remain blocked.
    var cotypingSuggestInIntegratedTerminals: Bool = false
    /// Condition suggestions on the focused app + window title / field label
    /// (e.g. the email subject or chat channel). On by default; reads window
    /// titles via Accessibility (already required for cotyping), stays on-device.
    var cotypingUseAppContext: Bool = true
    /// Fold the current clipboard into the prompt as context, so suggestions can
    /// build on what you just copied. On by default; read fresh at generation
    /// time, never persisted, and ignored while cotyping itself is disabled.
    var cotypingUseClipboard: Bool = true
    /// Match the host field's font and text color so ghost text reads as a
    /// continuation. On by default; reads via Accessibility (cached per field).
    var cotypingMatchHostStyle: Bool = true
    /// How ghost text is shown: inline at the caret, or a popup when geometry is
    /// unreliable / the caret is mid-line. `.auto` defers to caret quality.
    var cotypingMirrorPreference: CotypingMirrorPreference = .auto
    /// One-key inline autocorrect of the word you're typing (NSSpellChecker).
    /// On by default; suppresses a continuation on an unresolved typo.
    var cotypingAutocorrect: Bool = true
    /// Inline `:shortcode:` emoji autocomplete (e.g. `:rocket:` → 🚀). On by default.
    var cotypingEmoji: Bool = true
    /// Inline `/macro` autocomplete (math `/5+5`, dates `/today`, units `/10km->mi`,
    /// currency `/100usd to eur`, random `/d20`). On by default.
    var cotypingMacros: Bool = true
    /// Languages you usually write in (comma-separated) — a prompt voice hint.
    var cotypingLanguages: String = ""
    /// Free-form notes / glossary / jargon folded into the prompt as context.
    var cotypingExtendedContext: String = ""
    /// Catalog model id for cotyping. Cotyping always runs its own dedicated
    /// llama.cpp model on a separate server instance, so
    /// inline suggestions never contend with summarization for the shared
    /// server. Defaults to the recommended cotyping model.
    var cotypingBuiltInModelID: String = ModelCatalog.recommendedCotypingID
    /// When true (default), cotyping uses the in-process `libllama` runtime for
    /// the selected GGUF backend on Apple Silicon; false forces the HTTP
    /// `llama-server` path. The HTTP fallback also covers non-GGUF backends and
    /// any in-process load failure regardless of this flag.
    var cotypingInProcessRuntime: Bool = true
    /// Learn from accepted continuation text, encrypted locally. Stores accepted
    /// text plus a short sanitized prefix/context hint for ranking — never full
    /// raw typing streams — and skips secure fields, terminals, and code editors.
    var cotypingUseLocalLearning: Bool = true
    /// Number of similar accepted completions folded into the next prompt.
    var cotypingLearningExamplesInPrompt: Int = 3

    static let currentMeetingSettingsVersion: Int = 1
    static let defaultStopDebounceSeconds: TimeInterval = 15
    static let legacyDefaultStopDebounceSeconds: TimeInterval = 60
    static let minimumStopDebounceSeconds: TimeInterval = 5
    static let maximumStopDebounceSeconds: TimeInterval = 120
    static let currentCotypingSettingsVersion: Int = 3
    static let legacyPreviewCotypingSettingsVersion: Int = 0
    static let legacyPreviewCotypingMaxWords: Int = 2
    static let legacyPreviewCotypingDebounceMs: Int = 150
    static let lowLatencyCotypingDebounceMs: Int = 20
    static let defaultCotypingDebounceMs: Int = 160
    static let legacyDefaultCotypingDebounceMs: Int = 350
    static let maximumCotypingDebounceMs: Int = 1_000
    static let minimumSpeechSpeed: Double = 0.5
    static let maximumSpeechSpeed: Double = 2.0

    static func migratedCotypingMaxWords(_ words: Int, decodedSettingsVersion: Int) -> Int {
        if decodedSettingsVersion == legacyPreviewCotypingSettingsVersion,
           words == legacyPreviewCotypingMaxWords {
            return AppSettings().cotypingMaxWords
        }
        return words
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

    /// Prompt personalization derived from the cotyping settings.
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

    /// Token ceiling for one completion: ceil(words * 1.3), floor 5, doubled for
    /// multi-line up to 120.
    var cotypingMaxResponseTokens: Int {
        let languageAware = (cotypingMaxWords * 13 + 9) / 10
        let base = max(5, languageAware)
        return cotypingMultiLine ? min(base * 2, 120) : min(base, 120)
    }

    /// Settings the cotyping engine builds its `TextEngine` from. Cotyping always
    /// runs its own model, so this is a copy pinned to the built-in backend with
    /// `cotypingBuiltInModelID` (independent of the summarizer's backend/model).
    var cotypingTextEngineSettings: AppSettings {
        var s = self
        s.summarizerBackend = .builtIn
        s.builtInModelID = cotypingBuiltInModelID
        return s
    }

    /// Settings used by the compose pass after dictation ASR. A valid override
    /// is pinned to the local built-in backend without changing the Main LLM
    /// configuration used by summaries, Ask, and Agent Mode. Missing or stale
    /// model IDs safely inherit the Main LLM instead of falling through to an
    /// unrelated catalog default.
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
        return s
    }

    // MARK: - Echo cancellation

    /// Subtract the system-audio track from the microphone track before
    /// transcription, using an adaptive filter. Works on meetings already
    /// recorded, at the cost of a codec generation: both tracks are AAC by
    /// then. Harmless with headphones — with no echo to find, the filter
    /// converges to silence and the original track is used instead.
    ///
    /// Requires the microphone mode for the recording app to be Standard
    /// (Control Center → microphone icon → the app's own row). macOS Voice
    /// Isolation processes the input nonlinearly before this ever sees it,
    /// which breaks the assumption an adaptive filter depends on — measured,
    /// echo return loss drops from ~17 dB to ~3 dB with Isolation on, the
    /// latter indistinguishable from noise. A call's *other* participants can
    /// still get Voice Isolation: it is set per capturing app, not on the
    /// microphone itself, so setting the meeting app to Isolation and this
    /// app to Standard gets both — isolated audio on the call, a genuine echo
    /// signal for this filter to remove.
    ///
    /// Off by default while the filter is new: it rewrites the microphone
    /// track every transcription takes as input, so a bad pass is not
    /// something the user can see went wrong.
    var echoCancellation: Bool = false

    /// UserDefaults key for the encoded settings blob. Internal (not private)
    /// so `DataMigration` can copy a prior install's settings under it.
    static let key = "lokalbotv3.settings"

    /// UI tests launch the app out-of-process. Let them point settings at a
    /// disposable suite so test runs do not inherit or mutate the user's real
    /// app preferences.
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
        case transcriptionModel
        case graniteSpeechModel
        case transcriptionLanguage
        case languageHint // legacy key used by builds before typed language selection
        case transcriptionPrompt
        case autoTranscribe
        case autoSummarize
        case speechVoice
        case speechSpeed
        case dictationEnabled
        case dictationIntent, dictationUseScreenContext
        case dictationTriggerMode
        case dictationOutputMode
        case dictationShowOverlay
        case dictationLivePreview
        case dictationRetainAudio
        case dictationCompositionBuiltInModelID
        case trackingEnabled
        case semanticSearchEnabled
        case screenContextCaptureMode
        case screenshotsEnabled
        case screenshotIntervalMinutes
        case meetingVisualContextEnabled
        case capturePrivateWindows
        case excludedScreenDomains
        case retentionDays
        case keepOCRTextForever
        case quickRecallEnabled
        case dayDigestAutoEnabled
        case dayDigestHour
        case dayDigestCustomPrompt
        case dailyMemoryExportEnabled
        case dailyMemoryExportFolder
        case dailyMemoryExportFormat
        case dailyMemoryExportHour
        case dreamingEnabled
        case dreamingHour
        case dreamingFirstEligibleDayKey
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
        case approvedRemoteInferenceOrigins
        case generationBudgetPreset
        case noteTemplate
        case summaryLanguage
        case identifySpeakersFromVisuals
        case rememberSpeakersOnMac
        case multiSpeakerDiarization
        case cotypingEnabled
        case cotypingUserName
        case cotypingStyleNote
        case cotypingMultiLine
        case cotypingSettingsVersion
        case cotypingMaxWords
        case cotypingDebounceMs
        case cotypingStreamSuggestionsWhileGenerating
        case cotypingAcceptGranularity
        case cotypingAcceptKey
        case cotypingFullAcceptKey
        case cotypingAutoAcceptTrailingPunctuation
        case cotypingAddSpaceAfterAccept
        case cotypingExcludedApps
        case cotypingExcludedDomains
        case cotypingSuggestInIntegratedTerminals
        case cotypingUseAppContext
        case cotypingUseClipboard
        case cotypingMatchHostStyle
        case cotypingMirrorPreference
        case cotypingAutocorrect
        case cotypingEmoji
        case cotypingMacros
        case cotypingLanguages
        case cotypingExtendedContext
        case cotypingBuiltInModelID
        case cotypingInProcessRuntime
        case cotypingUseLocalLearning
        case cotypingLearningExamplesInPrompt
    }

    /// Names of settings whose stored values were present but unreadable, so
    /// they silently fell back to defaults during decode. Transient — never
    /// encoded — and empty in the normal case, including when an older build's
    /// blob simply lacks newer keys. `AppState` surfaces a one-time notice
    /// when this is non-empty: a privacy-relevant field resetting itself (say,
    /// screenshot capture) must never go unannounced.
    var corruptedSettingsKeys: [String] = []

    /// Marker used instead of field names when the entire stored blob was
    /// unreadable and every setting reset to defaults.
    static let wholeStoreCorruptionMarker = "all settings"

    static func load(from defaults: UserDefaults = Self.defaults) -> AppSettings {
        let loaded: AppSettings
        if let data = defaults.data(forKey: key) {
            do {
                loaded = try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                // Stored data exists but is unreadable — that is corruption,
                // not a first run. Reset, but say so.
                var reset = AppSettings()
                reset.corruptedSettingsKeys = [wholeStoreCorruptionMarker]
                loaded = reset
            }
        } else {
            loaded = AppSettings()
        }
#if LOKALBOT_UI_TEST_HOST
        // Marketing captures launch more than one AppState while SwiftUI
        // assembles its scenes. Apply demo state at the source so every one of
        // those instances renders the same enabled feature state; production
        // builds never compile this override.
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

    // Tolerant decoding: settings saved by an older build (fewer keys) keep
    // working instead of silently resetting everything to defaults.
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
        try c.encode(transcriptionModel, forKey: .transcriptionModel)
        try c.encode(graniteSpeechModel, forKey: .graniteSpeechModel)
        try c.encode(transcriptionLanguage, forKey: .transcriptionLanguage)
        try c.encode(transcriptionPrompt, forKey: .transcriptionPrompt)
        try c.encode(autoTranscribe, forKey: .autoTranscribe)
        try c.encode(autoSummarize, forKey: .autoSummarize)
        try c.encode(speechVoice, forKey: .speechVoice)
        try c.encode(Self.clampedSpeechSpeed(speechSpeed), forKey: .speechSpeed)
        try c.encode(dictationEnabled, forKey: .dictationEnabled)
        try c.encode(dictationIntent, forKey: .dictationIntent)
        try c.encode(dictationUseScreenContext, forKey: .dictationUseScreenContext)
        try c.encode(dictationTriggerMode, forKey: .dictationTriggerMode)
        try c.encode(dictationOutputMode, forKey: .dictationOutputMode)
        try c.encode(dictationShowOverlay, forKey: .dictationShowOverlay)
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
        try c.encode(capturePrivateWindows, forKey: .capturePrivateWindows)
        try c.encode(excludedScreenDomains, forKey: .excludedScreenDomains)
        try c.encode(retentionDays, forKey: .retentionDays)
        try c.encode(keepOCRTextForever, forKey: .keepOCRTextForever)
        try c.encode(quickRecallEnabled, forKey: .quickRecallEnabled)
        try c.encode(dayDigestAutoEnabled, forKey: .dayDigestAutoEnabled)
        try c.encode(min(23, max(0, dayDigestHour)), forKey: .dayDigestHour)
        try c.encode(dayDigestCustomPrompt, forKey: .dayDigestCustomPrompt)
        try c.encode(dailyMemoryExportEnabled, forKey: .dailyMemoryExportEnabled)
        try c.encode(dailyMemoryExportFolder, forKey: .dailyMemoryExportFolder)
        try c.encode(dailyMemoryExportFormat, forKey: .dailyMemoryExportFormat)
        try c.encode(min(23, max(0, dailyMemoryExportHour)), forKey: .dailyMemoryExportHour)
        try c.encode(dreamingEnabled, forKey: .dreamingEnabled)
        try c.encode(min(23, max(0, dreamingHour)), forKey: .dreamingHour)
        try c.encodeIfPresent(
            dreamingFirstEligibleDayKey,
            forKey: .dreamingFirstEligibleDayKey)
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
        try c.encode(approvedRemoteInferenceOrigins, forKey: .approvedRemoteInferenceOrigins)
        try c.encode(generationBudgetPreset, forKey: .generationBudgetPreset)
        try c.encode(noteTemplate, forKey: .noteTemplate)
        try c.encode(summaryLanguage, forKey: .summaryLanguage)
        try c.encode(multiSpeakerDiarization, forKey: .multiSpeakerDiarization)
        try c.encode(identifySpeakersFromVisuals, forKey: .identifySpeakersFromVisuals)
        try c.encode(rememberSpeakersOnMac, forKey: .rememberSpeakersOnMac)
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
        try c.encode(cotypingStreamSuggestionsWhileGenerating, forKey: .cotypingStreamSuggestionsWhileGenerating)
        try c.encode(cotypingAcceptGranularity, forKey: .cotypingAcceptGranularity)
        try c.encode(cotypingAcceptKey, forKey: .cotypingAcceptKey)
        try c.encode(cotypingFullAcceptKey, forKey: .cotypingFullAcceptKey)
        try c.encode(cotypingAutoAcceptTrailingPunctuation, forKey: .cotypingAutoAcceptTrailingPunctuation)
        try c.encode(cotypingAddSpaceAfterAccept, forKey: .cotypingAddSpaceAfterAccept)
        try c.encode(cotypingExcludedApps, forKey: .cotypingExcludedApps)
        try c.encode(cotypingExcludedDomains, forKey: .cotypingExcludedDomains)
        try c.encode(cotypingSuggestInIntegratedTerminals, forKey: .cotypingSuggestInIntegratedTerminals)
        try c.encode(cotypingUseAppContext, forKey: .cotypingUseAppContext)
        try c.encode(cotypingUseClipboard, forKey: .cotypingUseClipboard)
        try c.encode(cotypingMatchHostStyle, forKey: .cotypingMatchHostStyle)
        try c.encode(cotypingMirrorPreference, forKey: .cotypingMirrorPreference)
        try c.encode(cotypingAutocorrect, forKey: .cotypingAutocorrect)
        try c.encode(cotypingEmoji, forKey: .cotypingEmoji)
        try c.encode(cotypingMacros, forKey: .cotypingMacros)
        try c.encode(cotypingLanguages, forKey: .cotypingLanguages)
        try c.encode(cotypingExtendedContext, forKey: .cotypingExtendedContext)
        try c.encode(cotypingBuiltInModelID, forKey: .cotypingBuiltInModelID)
        try c.encode(cotypingInProcessRuntime, forKey: .cotypingInProcessRuntime)
        try c.encode(cotypingUseLocalLearning, forKey: .cotypingUseLocalLearning)
        try c.encode(cotypingLearningExamplesInPrompt, forKey: .cotypingLearningExamplesInPrompt)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        // Two very different reasons a stored value can be unusable: the key
        // is absent (an older build wrote this blob — expected, keep the
        // default silently) or the key is present but unreadable (corruption
        // or hand-editing — keep the default, but record the field so the
        // app can tell the user what silently reset).
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
        transcriptionModel = decode(.transcriptionModel, defaults.transcriptionModel)
        graniteSpeechModel = decode(.graniteSpeechModel, defaults.graniteSpeechModel)
        if c.contains(.transcriptionLanguage) {
            transcriptionLanguage = decode(.transcriptionLanguage, defaults.transcriptionLanguage)
        } else if let legacyHint = try? c.decode(String.self, forKey: .languageHint) {
            transcriptionLanguage = TranscriptionLanguage.fromLegacyHint(legacyHint)
        } else {
            transcriptionLanguage = defaults.transcriptionLanguage
        }
        transcriptionPrompt = decode(.transcriptionPrompt, defaults.transcriptionPrompt)
        autoTranscribe = decode(.autoTranscribe, defaults.autoTranscribe)
        autoSummarize = decode(.autoSummarize, defaults.autoSummarize)
        speechVoice = decode(.speechVoice, defaults.speechVoice)
        speechSpeed = Self.clampedSpeechSpeed(decode(.speechSpeed, defaults.speechSpeed))
        dictationEnabled = decode(.dictationEnabled, defaults.dictationEnabled)
        // Existing installations keep the original Compose behavior.
        dictationIntent = decode(.dictationIntent, .compose)
        dictationUseScreenContext = decode(.dictationUseScreenContext, true)
        dictationTriggerMode = decode(.dictationTriggerMode, defaults.dictationTriggerMode)
        dictationOutputMode = decode(.dictationOutputMode, defaults.dictationOutputMode)
        dictationShowOverlay = decode(.dictationShowOverlay, defaults.dictationShowOverlay)
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
        capturePrivateWindows = decode(.capturePrivateWindows, defaults.capturePrivateWindows)
        excludedScreenDomains = decode(.excludedScreenDomains, defaults.excludedScreenDomains)
        retentionDays = decode(.retentionDays, defaults.retentionDays)
        keepOCRTextForever = decode(.keepOCRTextForever, defaults.keepOCRTextForever)
        quickRecallEnabled = decode(.quickRecallEnabled, defaults.quickRecallEnabled)
        dayDigestAutoEnabled = decode(.dayDigestAutoEnabled, defaults.dayDigestAutoEnabled)
        dayDigestHour = min(23, max(0, decode(.dayDigestHour, defaults.dayDigestHour)))
        dayDigestCustomPrompt = decode(.dayDigestCustomPrompt, defaults.dayDigestCustomPrompt)
        dailyMemoryExportEnabled = decode(
            .dailyMemoryExportEnabled, defaults.dailyMemoryExportEnabled)
        dailyMemoryExportFolder = decode(
            .dailyMemoryExportFolder, defaults.dailyMemoryExportFolder)
        dailyMemoryExportFormat = decode(
            .dailyMemoryExportFormat, defaults.dailyMemoryExportFormat)
        dailyMemoryExportHour = min(
            23, max(0, decode(.dailyMemoryExportHour, defaults.dailyMemoryExportHour)))
        dreamingEnabled = decode(.dreamingEnabled, defaults.dreamingEnabled)
        dreamingHour = min(23, max(0, decode(.dreamingHour, defaults.dreamingHour)))
        dreamingFirstEligibleDayKey = decode(.dreamingFirstEligibleDayKey, String?.none)
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
        approvedRemoteInferenceOrigins = decode(
            .approvedRemoteInferenceOrigins, defaults.approvedRemoteInferenceOrigins)
        generationBudgetPreset = decode(
            .generationBudgetPreset, defaults.generationBudgetPreset)
        noteTemplate = decode(.noteTemplate, defaults.noteTemplate)
        summaryLanguage = decode(.summaryLanguage, defaults.summaryLanguage)
        multiSpeakerDiarization = decode(.multiSpeakerDiarization, defaults.multiSpeakerDiarization)
        identifySpeakersFromVisuals = decode(.identifySpeakersFromVisuals, defaults.identifySpeakersFromVisuals)
        rememberSpeakersOnMac = decode(.rememberSpeakersOnMac, defaults.rememberSpeakersOnMac)
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
        cotypingStreamSuggestionsWhileGenerating = decode(
            .cotypingStreamSuggestionsWhileGenerating,
            defaults.cotypingStreamSuggestionsWhileGenerating)
        cotypingAcceptGranularity = decode(
            .cotypingAcceptGranularity, defaults.cotypingAcceptGranularity)
        cotypingAcceptKey = decode(.cotypingAcceptKey, defaults.cotypingAcceptKey)
        cotypingFullAcceptKey = decode(.cotypingFullAcceptKey, defaults.cotypingFullAcceptKey)
        cotypingAutoAcceptTrailingPunctuation = decode(
            .cotypingAutoAcceptTrailingPunctuation,
            defaults.cotypingAutoAcceptTrailingPunctuation)
        cotypingAddSpaceAfterAccept = decode(
            .cotypingAddSpaceAfterAccept, defaults.cotypingAddSpaceAfterAccept)
        cotypingExcludedApps = decode(.cotypingExcludedApps, defaults.cotypingExcludedApps)
        cotypingExcludedDomains = decode(.cotypingExcludedDomains, defaults.cotypingExcludedDomains)
        cotypingSuggestInIntegratedTerminals = decode(
            .cotypingSuggestInIntegratedTerminals,
            defaults.cotypingSuggestInIntegratedTerminals)
        cotypingUseAppContext = decode(.cotypingUseAppContext, defaults.cotypingUseAppContext)
        cotypingUseClipboard = decode(.cotypingUseClipboard, defaults.cotypingUseClipboard)
        cotypingMatchHostStyle = decode(.cotypingMatchHostStyle, defaults.cotypingMatchHostStyle)
        cotypingMirrorPreference = decode(
            .cotypingMirrorPreference, defaults.cotypingMirrorPreference)
        cotypingAutocorrect = decode(.cotypingAutocorrect, defaults.cotypingAutocorrect)
        cotypingEmoji = decode(.cotypingEmoji, defaults.cotypingEmoji)
        cotypingMacros = decode(.cotypingMacros, defaults.cotypingMacros)
        cotypingLanguages = decode(.cotypingLanguages, defaults.cotypingLanguages)
        cotypingExtendedContext = decode(.cotypingExtendedContext, defaults.cotypingExtendedContext)
        cotypingBuiltInModelID = decode(.cotypingBuiltInModelID, defaults.cotypingBuiltInModelID)
        cotypingInProcessRuntime = decode(.cotypingInProcessRuntime, defaults.cotypingInProcessRuntime)
        cotypingUseLocalLearning = decode(.cotypingUseLocalLearning, defaults.cotypingUseLocalLearning)
        cotypingLearningExamplesInPrompt = min(5, max(1, decode(
            .cotypingLearningExamplesInPrompt, defaults.cotypingLearningExamplesInPrompt)))
        corruptedSettingsKeys = corrupted
    }
}
