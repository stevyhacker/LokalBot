import SwiftUI
import Combine
import AVFoundation
import CoreGraphics

/// Central app state (the "coordinator" from the design doc §6): dependency
/// wiring, the meeting library, navigation, and the detection→recording glue.
/// The recording lifecycle itself lives in `RecordingController`; headless
/// subcommands in `HeadlessCommandRunner`; AppKit launch plumbing in
/// `AppLifecycle.swift`.
@MainActor
final class AppState: ObservableObject {

    enum NavSection: Hashable {
        case today, timeline, meetings, type, ask, agent, settings

        /// Section names accepted from the UI-test capture environment and
        /// deep links. Legacy names keep working: "capture" (the pre-split
        /// merged section) lands on Timeline, "dictation" and "cotyping" on
        /// Type, "search"/"chat" on Ask (spec §2.1), and "models" on
        /// Settings, which absorbed it as a tab (spec §2.5).
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "today": self = .today
            case "timeline", "capture": self = .timeline
            case "meetings": self = .meetings
            case "write", "type", "dictation", "cotyping", "autocomplete": self = .type
            case "ask", "search", "chat": self = .ask
            case "agent": self = .agent
            case "settings", "models": self = .settings
            default: return nil
            }
        }
    }

    /// Which tool the Type section shows. Session-sticky: preserved while
    /// navigating away so returning lands on the last-used tab.
    enum TypeTab: String {
        case dictation, cotyping

        /// Legacy capture names select their tab; anything else leaves the
        /// current tab untouched.
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "dictation": self = .dictation
            case "cotyping", "autocomplete": self = .cotyping
            default: return nil
            }
        }
    }

    /// Which tab the Settings surface shows (spec §2.5 — Settings absorbs
    /// Models as a tab strip). Session-sticky like TypeTab.
    enum SettingsTab: String, CaseIterable {
        case general, recording, dayMemory, writing, models, privacy, advanced

        var displayName: String {
            switch self {
            case .recording: "Meetings"
            case .dayMemory: "Day Memory"
            case .privacy: "Privacy & Data"
            default: rawValue.capitalized
            }
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .recording: "person.2"
            case .dayMemory: "calendar.day.timeline.left"
            case .writing: "pencil"
            case .models: "shippingbox"
            case .privacy: "lock"
            case .advanced: "slider.horizontal.3"
            }
        }

        /// Legacy capture names select their tab; the pre-merge "models"
        /// section name lands on the Models tab.
        init?(captureName: String) {
            switch captureName.lowercased() {
            case "general": self = .general
            case "recording", "meetings": self = .recording
            case "daymemory", "day memory": self = .dayMemory
            case "writing", "write": self = .writing
            case "models": self = .models
            case "privacy": self = .privacy
            case "advanced": self = .advanced
            default: return nil
            }
        }
    }

    /// True when launched by an XCUITest harness — gates the side-effectful
    /// startup paths (Core Audio polling, accessibility-trusted detector,
    /// Sparkle, periodic screenshots) so the UI renders against synthetic
    /// data without touching real audio, TCC, or the network.
    nonisolated static var isUITesting: Bool { UITestRuntime.isEnabled }
    /// Hosted XCTest executes the real app entry point. It needs neither UI
    /// fixtures nor any interactive service, so return before touching the
    /// meeting library, indexes, permissions, audio, Sparkle, or the network.
    nonisolated static var isUnitTesting: Bool { UITestRuntime.isUnitTesting }

    /// UserDefaults flag: the permission onboarding has been shown once. Also
    /// read by `AppDelegate` to keep the first run windowed.
    nonisolated static let onboardingShownKey = "lokalbotv3.onboarding.shown"

    @Published private(set) var meetings: [Meeting] = []
    @Published var lastError: String?
    /// A recording or dictation start was refused because microphone access
    /// is denied at the system level. Cleared when the user opens System
    /// Settings from the recovery toast or dismisses it.
    @Published var micRecoveryNeeded = false

    /// The always-alive settings owner; services capture this, never AppState.
    let settingsStore = SettingsStore()

    /// UI-facing settings surface (views bind `$app.settings.x`). Writes flow
    /// through to `settingsStore` (which persists) and fan out to the
    /// subsystems that apply settings live.
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.current = settings
            modelRoles.settingsDidChange(from: oldValue, to: settings)
            if settings.stopDebounceSeconds != oldValue.stopDebounceSeconds {
                detector.stopDebounce = settings.stopDebounceSeconds
            }
            if settings.calendarDetectionEnabled != oldValue.calendarDetectionEnabled {
                detector.calendarEnabled = settings.calendarDetectionEnabled
            }
            if settings.requireCalendarForBrowser != oldValue.requireCalendarForBrowser {
                detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
            }
            if interactive {
                if Self.dictationLifecycleChanged(from: oldValue, to: settings) {
                    dictation.applySettings()
                }
                if settings.cotypingEnabled != oldValue.cotypingEnabled {
                    cotyping.applySettings()
                    if !settings.cotypingEnabled {
                        scheduleCotypingRuntimeUnload()
                    }
                }
                if Self.cotypingRuntimeChanged(from: oldValue, to: settings) {
                    scheduleCotypingPrewarm()
                }
                if settings.quickRecallEnabled != oldValue.quickRecallEnabled {
                    applyQuickRecallSetting()
                }
                // UI retention reductions are reviewed and executed explicitly.
                // Changing a preference must not trigger an unreviewed cleanup.
                if Self.dailyMemoryExportChanged(from: oldValue, to: settings) {
                    applyDailyMemoryExportSetting()
                }
                if Self.dayDigestChanged(from: oldValue, to: settings) {
                    applyDayDigestSetting()
                }
                if Self.screenContextChanged(from: oldValue, to: settings) {
                    applyTrackingSetting()
                }
                if Self.memoryRoutinesChanged(from: oldValue, to: settings) {
                    applyMemoryRoutineSetting()
                }
                if Self.dreamingChanged(from: oldValue, to: settings) {
                    applyDreamingSetting()
                }
            }
        }
    }

    private static func dictationLifecycleChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        old.dictationEnabled != new.dictationEnabled
            || old.dictationShowOverlay != new.dictationShowOverlay
            || old.dictationLivePreview != new.dictationLivePreview
    }

    private static func cotypingRuntimeChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        guard new.cotypingEnabled else { return false }
        return !old.cotypingEnabled
            || old.cotypingBuiltInModelID != new.cotypingBuiltInModelID
            || old.cotypingInProcessRuntime != new.cotypingInProcessRuntime
            || old.customBuiltInModels != new.customBuiltInModels
    }

    private static func dailyMemoryExportChanged(from old: AppSettings,
                                                 to new: AppSettings) -> Bool {
        old.dailyMemoryExportEnabled != new.dailyMemoryExportEnabled
            || old.dailyMemoryExportFolder != new.dailyMemoryExportFolder
            || old.dailyMemoryExportFormat != new.dailyMemoryExportFormat
            || old.dailyMemoryExportHour != new.dailyMemoryExportHour
    }

    /// The custom prompt is deliberately absent: it is read fresh from
    /// `settings` at generation time, so editing it never resets the scheduler.
    private static func dayDigestChanged(from old: AppSettings,
                                         to new: AppSettings) -> Bool {
        old.dayDigestAutoEnabled != new.dayDigestAutoEnabled
            || old.dayDigestHour != new.dayDigestHour
    }

    private static func screenContextChanged(from old: AppSettings,
                                             to new: AppSettings) -> Bool {
        old.trackingEnabled != new.trackingEnabled
            || old.effectiveScreenContextCaptureMode != new.effectiveScreenContextCaptureMode
            || old.screenshotIntervalMinutes != new.screenshotIntervalMinutes
            || old.meetingVisualContextEnabled != new.meetingVisualContextEnabled
    }

    private static func memoryRoutinesChanged(from old: AppSettings,
                                              to new: AppSettings) -> Bool {
        old.memoryRoutinesEnabled != new.memoryRoutinesEnabled
            || old.memoryRoutineFolder != new.memoryRoutineFolder
            || old.enabledMemoryRoutines != new.enabledMemoryRoutines
            || old.memoryRoutineHour != new.memoryRoutineHour
            || old.memoryRoutineWeekday != new.memoryRoutineWeekday
    }

    private static func dreamingChanged(from old: AppSettings,
                                        to new: AppSettings) -> Bool {
        old.dreamingEnabled != new.dreamingEnabled
            || old.dreamingHour != new.dreamingHour
            || old.dreamingFirstEligibleDayKey != new.dreamingFirstEligibleDayKey
    }

    // Navigation (main window): sidebar section and selected meeting.
    @Published var navSection: NavSection = .today
    @Published var showingActions = false
    @Published var meetingNoteDrafts: [UUID: String] = [:]
    @Published var actionSelection: Set<String> = []
    @Published var recallQuery = ""
    @Published var recallState = RecallWorkspaceState()
    @Published var evidenceMeetingID: UUID?
    @Published var evidenceReturnSection: NavSection?
    private var evidenceReturnMeetingIDs: Set<Meeting.ID>?
    func returnFromEvidence() {
        guard let section = evidenceReturnSection else { return }
        if let evidenceReturnMeetingIDs { selectedMeetingIDs = evidenceReturnMeetingIDs }
        navSection = section
        evidenceReturnSection = nil
        evidenceReturnMeetingIDs = nil
    }
    @Published var meetingWorkspaceTabs: [UUID: MeetingWorkspaceTab] = [:]
    var meetingPlaybackPositions: [UUID: TimeInterval] = [:]
    var meetingPlaybackSpeeds: [UUID: Float] = [:]
    func openActions() { showingActions = true; navSection = .today }
    private static let typeTabDefaultsKey = "lokalbotv3.type.selectedTab"
    private static var navigationDefaults: UserDefaults {
        if let suite = UITestRuntime.defaultsSuiteName,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }
    @Published var typeTab: TypeTab = .dictation {
        didSet { Self.navigationDefaults.set(typeTab.rawValue, forKey: Self.typeTabDefaultsKey) }
    }
    private static let settingsTabDefaultsKey = "lokalbotv3.settings.selectedTab"
    @Published var settingsTab: SettingsTab = .general {
        didSet { Self.navigationDefaults.set(settingsTab.rawValue, forKey: Self.settingsTabDefaultsKey) }
    }
    @Published var focusedSettingID: String?
    /// Ask's retrieval choice survives NavigationSplitView remounts while the
    /// app is running. Explicit handoffs and conversation selections still
    /// switch back to Ask before presenting their content.
    @Published var askMode: AskMode = .ask
    @Published var selectedMeetingIDs: Set<Meeting.ID> = []
    /// The meeting whose page-level find bar is visible. Keeping presentation
    /// in shared observable state makes menu/AppKit requests and the rendered
    /// NavigationSplitView consume one source of truth.
    @Published private(set) var presentedMeetingSearchID: Meeting.ID?
    @Published private(set) var meetingPageSearchRequestRevision = 0

    /// A day handed to the Ask section (the old Timeline "Ask" tab, spec
    /// §2.2): rendered as a removable chip, and prepended to escalated
    /// queries so the assistant scopes its answer to that day.
    @Published var askDayScope: Date?
    /// Atomic, destination-scoped payloads for cross-surface navigation.
    private(set) lazy var navigationHandoff = NavigationHandoff()

    /// Navigate to the Type section with a specific tab preselected.
    func openType(_ tab: TypeTab) {
        typeTab = tab
        navSection = .type
    }

    /// Open Settings as a destination inside the existing main window.
    func openSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        focusedSettingID = nil
        evidenceReturnSection = nil
        navSection = .settings
        WindowAccess.shared.open("main")
    }

    /// Navigate to the Ask section, optionally pre-filling the query and/or
    /// scoping it to a day (Timeline's "Ask about this day").
    func openAsk(query: String = "", dayScope: Date? = nil,
                 screenSnapshotIDs: [Int64]? = nil, submit: Bool = false,
                 meetingIDs: Set<Meeting.ID>? = nil, mode: AskMode = .ask) {
        navigationHandoff.stageAsk(
            query: query,
            dayScope: dayScope,
            screenSnapshotIDs: screenSnapshotIDs,
            submit: submit, meetingIDs: meetingIDs, mode: mode)
        navSection = .ask
    }

    func openAgent(_ context: AgentLaunchContext? = nil) {
        navigationHandoff.stageAgent(context)
        if let prompt = context?.prompt {
            agentSessions.ensureSelectedController().draft = prompt
        }
        navSection = .agent
    }

    /// Open one meeting in the Meetings section — the deep-link target
    /// for search hits, menu-bar recents, and palette recents.
    func openMeeting(_ id: Meeting.ID, seek: TimeInterval? = nil, intent: EvidenceIntent = .reveal) {
        evidenceMeetingID = id
        if navSection != .meetings {
            evidenceReturnSection = navSection
            evidenceReturnMeetingIDs = selectedMeetingIDs
        }
        navigationHandoff.stageMeeting(id, seek: seek, intent: intent)
        selectedMeetingIDs = [id]
        navSection = .meetings
    }

    var canSearchSelectedMeeting: Bool {
        navSection == .meetings && selectedMeeting?.endedAt != nil
    }

    func requestSelectedMeetingSearch() {
        guard canSearchSelectedMeeting, let meeting = selectedMeeting else { return }
        presentedMeetingSearchID = meeting.id
        meetingPageSearchRequestRevision &+= 1
    }

    func dismissMeetingSearch(for meetingID: Meeting.ID) {
        guard presentedMeetingSearchID == meetingID else { return }
        presentedMeetingSearchID = nil
    }

    func selectDefaultMeetingIfNeeded() {
        guard selectedMeetingIDs.isEmpty else { return }
        if let live = currentMeeting {
            openMeeting(live.id)
        } else if let completed = meetings.first(where: { meeting in
            meeting.endedAt != nil && pipeline.stages[meeting.id] == nil
        }) ?? meetings.first(where: { $0.endedAt != nil }) {
            openMeeting(completed.id)
        }
    }

    /// The meeting shown in the detail pane (single selection only). The
    /// in-progress recording is a first-class citizen here: selecting its
    /// row resolves to `currentMeeting`, which `CaptureDetailView` routes
    /// to the live view.
    var selectedMeeting: Meeting? {
        guard selectedMeetingIDs.count == 1, let id = selectedMeetingIDs.first else { return nil }
        if let live = currentMeeting, live.id == id { return live }
        return meetings.first { $0.id == id }
    }

    let storage = StorageManager()
    private(set) lazy var outcomeIndex = OutcomeIndex(
        storage: storage,
        onEvidenceChanged: { [weak self] meetings in
            self?.primaryEvidenceDidChange(for: meetings)
        })
    private(set) lazy var cotypingLearning = CotypingLearningStore(storageRoot: storage.rootURL)
    let detector = MeetingDetector()
    let audioMonitor = AudioSourceMonitor()
    /// External-agent access: Privacy marker plus the local-model wake watcher.
    private(set) lazy var agentAccess = AgentAccessManager(
        storage: storage,
        settings: { [weak self] in self?.settings ?? AppSettings.load() },
        onError: { [weak self] message in self?.lastError = message })
    /// Screen-memory access is intentionally separate from meeting-library
    /// access: enabling one capability never grants the other.
    private(set) lazy var screenMemoryAccess = ScreenMemoryAccessManager(
        gate: ScreenMemoryAccessGate(root: storage.rootURL))
    private(set) lazy var quickRecallHotKey: QuickRecallHotKeyController = {
        let controller = QuickRecallHotKeyController()
        controller.onInvoke = { WindowAccess.shared.open("quick-recall") }
        return controller
    }()
    private let dailyMemoryExportScheduler = DailyMemoryExportScheduler()
    private(set) lazy var memoryRoutines = MemoryRoutineScheduler(
        storageRoot: storage.rootURL,
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"),
        canRun: { [weak self] in
            guard let self else { return false }
            let cotypingGenerating: Bool
            if case .generating = self.cotyping.state {
                cotypingGenerating = true
            } else {
                cotypingGenerating = false
            }
            return !self.recording.isRecording
                && !self.recording.isStarting
                && !self.dictation.isStarting
                && !self.dictation.state.isWorking
                && !cotypingGenerating
                && !self.pipeline.hasActiveWork
        })
    /// Overnight dreaming: the scheduler is observed by Settings (progress /
    /// last-run), the store is read by Today, and `latestDreamReport` lets an
    /// open Today window pick up a dream that finishes while it's visible.
    @Published var latestDreamReport: DreamReport?
    /// Settings' user-managed pin controls. The store remains the source of
    /// truth; mutations reload it before saving to avoid stale-view writes.
    @Published private(set) var dreamMemory: DreamMemory?
    private var dreamObserver: AnyCancellable?
    private(set) lazy var dreamStore = DreamStore(root: storage.rootURL)
    private(set) lazy var dreaming: DreamScheduler = {
        let scheduler = DreamScheduler()
        dreamObserver = scheduler.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        return scheduler
    }()
    /// Read-only calendar access (EventKit): confirms meetings and titles
    /// recordings. Concrete type so the settings UI observes its permission
    /// state; handed to the detector as the `CalendarEventProviding` seam.
    let calendar = EventKitCalendarEventProvider()
    private var cachedSearchIndex: SearchIndex?
    var searchIndex: SearchIndex {
        if let cachedSearchIndex { return cachedSearchIndex }
        let created = SearchIndex(
            databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
        for meetingID in excludedMeetingIDs { created.noteDeletion(meetingID) }
        cachedSearchIndex = created
        return created
    }
    private(set) lazy var activityStore = ActivityStore(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
    private(set) lazy var sampler = ActivitySampler(store: activityStore)
    private var cachedEmbeddingIndex: EmbeddingIndex?
    var embeddingIndex: EmbeddingIndex {
        if let cachedEmbeddingIndex { return cachedEmbeddingIndex }
        let created = EmbeddingIndex(
            databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"),
            storage: storage)
        for meetingID in excludedMeetingIDs { created.noteDeletion(meetingID) }
        cachedEmbeddingIndex = created
        return created
    }
    private(set) lazy var screenshots = ScreenshotService(
        store: activityStore, storage: storage, sampler: sampler,
        isMeetingRecordingActive: { [weak self] in
            guard let self else { return false }
            return self.recording.isRecording || self.recording.isStarting
        }, activeMeetingID: { [weak self] in
            self?.recording.currentMeeting?.id
        }, isHighPriorityInteractionActive: { [weak self] in
            guard let self else { return false }
            if self.dictation.state.isWorking { return true }
            if case .generating = self.cotyping.state { return true }
            return false
        }) { [store = settingsStore] in
        store.current
    }
    private(set) lazy var pipelineJobStore = PipelineJobStore(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
    /// Backend selection, preparation, privacy policy, leases, and recovery
    /// for every feature that uses LokalBot's Think role.
    private(set) lazy var thinkExecution = ThinkExecution(storage: storage)
    private(set) lazy var speakerIdentity = MeetingSpeakerIdentityService(
        storage: storage, settings: { [store = settingsStore] in store.current })
    private(set) lazy var speakerObserver = MeetingSpeakerObserver(
        identity: speakerIdentity, settings: { [store = settingsStore] in store.current },
        capturePaused: { [weak self] in self?.sampler.isPaused ?? true })
    private(set) lazy var pipeline = ProcessingPipeline(
        storage: storage,
        jobStore: pipelineJobStore,
        settings: { [store = settingsStore] in store.current },
        thinkExecution: thinkExecution,
        speakerIdentity: speakerIdentity)
    /// Canonical state machine for Transcribe, Think, and Autocomplete.
    private(set) lazy var modelRoles = ModelRoles(
        settings: { [store = settingsStore] in store.current },
        storage: storage,
        onReadinessChanged: { [weak self] in
            self?.processMeetingsWaitingForModels()
        })

    private(set) lazy var modelSetup = ModelSetupController(
        settings: { [weak self] in self?.settings ?? AppSettings() },
        update: { [weak self] in self?.settings = $0 },
        prepare: { [weak self] patch, current in
            guard let self else { throw CancellationError() }
            let target = patch.applying(to: current)
            for id in patch.localModelIDs(in: current) {
                guard let entry = ModelCatalog.entry(id: id, custom: target.customBuiltInModels) else {
                    throw ModelDownloadManager.PreparationError.failed("This model is no longer in the catalog. Choose another model.")
                }
                _ = try await ModelDownloadManager.shared.ensureAvailable(entry, storage: self.storage)
            }
            if let transcription = patch.transcription {
                try await self.modelRoles.ensureTranscriptionAvailable(transcription, configuration: target)
            }
            if patch.backend == .appleIntelligence {
                let availability = FoundationModelAvailability.current()
                guard availability.isAvailable else {
                    throw ModelDownloadManager.PreparationError.failed(availability.reason ?? "Apple Intelligence is unavailable.")
                }
            }
            for id in patch.localModelIDs(in: current) {
                guard let entry = ModelCatalog.entry(id: id, custom: target.customBuiltInModels),
                      ModelCatalog.localURL(for: entry, storage: self.storage) != nil else {
                    throw ModelDownloadManager.PreparationError.failed(
                        "A prepared model is no longer on disk. Download it again before switching.")
                }
            }
            self.modelRoles.readinessDidChange()
        })

    let modelChecks = ModelCheckController()
    private(set) lazy var speechModelDownload = ModelSpeechDownloadController()
    /// One Day Digest lifecycle for manual, scheduled, and headless callers.
    /// It owns evidence collection, journal state, freshness, and repair policy.
    private(set) lazy var dayDigest = DayDigestLifecycle(
        storage: storage,
        activityStore: activityStore,
        pipeline: pipeline,
        meetings: { [weak self] in
            guard let self else { return [] }
            return (self.currentMeeting.map { [$0] } ?? []) + self.meetings
        },
        settings: { [store = settingsStore] in store.current },
        onGenerated: { [weak self] day in self?.dayDigestDidChange(on: day) })
    /// Meeting-recording lifecycle: recorders, watchdog, timer tick, prewarm.
    private(set) lazy var recording = RecordingController(
        storage: storage,
        settingsStore: settingsStore,
        audioMonitor: audioMonitor,
        pipeline: pipeline,
        speakerObserver: speakerObserver,
        isInteractive: { [weak self] in self?.interactive ?? false },
        onError: { [weak self] message in
            guard let message else {
                // Withdraw only the silent-capture advisory, never a newer error.
                if self?.lastError == RecordingController.silentSystemAudioMessage {
                    self?.lastError = nil
                }
                return
            }
            self?.lastError = message
        },
        onMicPermissionDenied: { [weak self] in self?.micRecoveryNeeded = true },
        onMeetingFinished: { [weak self] meeting in self?.meetings.insert(meeting, at: 0) })
    /// Press-and-speak composition. Every dictation is treated as a writing
    /// request: local ASR captures the instruction, the configured composition
    /// LLM writes against ephemeral focused-window context, and focus-safe
    /// delivery inserts it.
    private(set) lazy var dictation = DictationCoordinator(
        storageRoot: storage.rootURL,
        settingsProvider: { [store = settingsStore] in store.current },
        makeTextEngine: { [weak self] sessionSettings in
            guard let self else {
                throw TextEngineError.unavailable("LokalBot is shutting down.")
            }
            let config = sessionSettings.dictationCompositionTextEngineSettings
            return try await self.thinkExecution.makeTextEngine(
                config,
                priority: .interactive,
                purpose: "dictation compose")
        },
        canStart: { [weak self] in
            guard let self else { return false }
            return !self.recording.isRecording
                && !self.recording.isStarting
                && self.pendingRecordingStart == nil
        },
        onBusy: { [weak self] in
            self?.lastError = "Stop the current meeting recording before starting dictation."
        },
        onError: { [weak self] message in
            self?.lastError = message
        },
        onMicPermissionDenied: { [weak self] in
            self?.micRecoveryNeeded = true
        })
    /// Cotyping (inline AI autocomplete). Always runs its own model on the
    /// dedicated `LlamaServer.cotyping` instance so it never thrashes the
    /// shared summarizer server. Resolved per-completion, so changes apply live.
    private(set) lazy var cotypingEngine = CotypingEngineSelector(
        http: CotypingEngine(
            makeEngine: { [weak self] in
                guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
                return try await self.thinkExecution.makeTextEngine(
                    self.settings.cotypingTextEngineSettings,
                    server: .cotyping,
                    priority: .interactive,
                    purpose: "cotyping")
            },
            stopRuntime: { await LlamaServer.cotyping.stop() }),
        makeLocal: { modelPath in
            LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: modelPath)
        },
        settings: { [store = settingsStore] in store.current },
        storage: storage)
    private(set) lazy var cotyping = CotypingCoordinator(
        engine: cotypingEngine,
        settingsProvider: { [store = settingsStore] in store.current },
        learningStore: cotypingLearning,
        isMeetingRecordingActive: { [weak self] in
            guard let self else { return false }
            return self.recording.isRecording || self.recording.isStarting
        })
    /// Rolling live transcript of the recording in progress (preview only —
    /// the pipeline's post-meeting transcript stays authoritative).
    private(set) lazy var liveTranscriber = LiveMeetingTranscriber(
        storageRoot: storage.rootURL,
        settings: { [store = settingsStore] in store.current })

    @MainActor
    func prepareRecommendedCotypingModel() {
        CotypingModelPreparer.prepareRecommended(
            settings: &settings,
            storage: storage,
            downloads: ModelDownloadManager.shared)
    }

    /// Chat assistant (the "Chat" section). Reuses the summariser's `TextEngine`
    /// and a tool-calling agent over the live meeting list + search indexes.
    private(set) lazy var chat = ChatViewModel(
        makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.thinkExecution.makeTextEngine(
                self.settings,
                priority: .interactive,
                purpose: "chat")
        },
        tools: MeetingChatTools(
            meetings: { [weak self] in self?.meetings ?? [] },
            storage: storage,
            searchIndex: searchIndex,
            embeddingIndex: embeddingIndex,
            activityStore: activityStore,
            settings: { [store = settingsStore] in store.current }),
        store: ChatStore(rootURL: storage.rootURL),
        workMemory: { [weak self] in
            guard let self else { return "" }
            return ChatPrompt.workMemoryContext(
                memory: (try? self.dreamStore.loadMemory()) ?? nil,
                dreamingEnabled: self.settings.dreamingEnabled)
        })

    // Agent Mode (pi). Installer and tab manager are cheap; each tab lazily
    // spawns its own controller/process when AgentView mounts it.
    let agentInstaller = AgentRuntimeInstaller()
    private(set) lazy var agentSessions = AgentSessionTabs(
        settings: { [store = settingsStore] in store.current },
        storage: storage,
        thinkExecution: thinkExecution)
    var agentController: AgentSessionController {
        agentSessions.ensureSelectedController()
    }

    private var pipelineObserver: AnyCancellable?
    private var outcomeObserver: AnyCancellable?
    private var dictationObserver: AnyCancellable?
    private var recordingObserver: AnyCancellable?
    private var recordingStatusObserver: AnyCancellable?
    private var audioMonitorObserver: AnyCancellable?
    private var audioMonitorChangeForwarder: AnyCancellable?
    private var calendarObserver: AnyCancellable?
    private var modelRolesObserver: AnyCancellable?
    private var navigationHandoffObserver: AnyCancellable?
    /// True only on the real interactive launch path (not headless / UI test) —
    /// gates recording notifications and first-run onboarding.
    private var interactive = false
    private var terminationCleanupTask: Task<Void, Never>?
    /// Serializes cotyping model lifecycle transitions. A disable must finish
    /// unloading both runtimes before a rapid re-enable can prewarm a fresh
    /// model, otherwise the old and new routes can overlap in memory.
    private var cotypingRuntimeTask: Task<Void, Never>?
    private var cotypingRuntimeTaskID: UUID?
    private var libraryLoadTask: Task<Void, Never>?
    private var embeddingBackfillTask: (token: UUID, task: Task<Void, Never>)?
    private var embeddingIndexTasks: [Meeting.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var indexCleanupTasks: [Meeting.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Meeting IDs excluded from search for this session. This includes
    /// physically deleted meetings and source rows folded into a merge.
    private var excludedMeetingIDs: Set<Meeting.ID> = []
    @Published private(set) var libraryReady = false
    private var pendingRecordingStart: (
        context: MeetingDetectionContext?,
        source: String,
        systemAudioPolicy: RecordingSystemAudioPolicy
    )?
    private lazy var searchIndexWorkQueue = SearchIndexWorkQueue(
        databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"),
        rootURL: storage.rootURL)

    // Recording facades — views observe AppState only.
    var isRecording: Bool { recording.isRecording }
    var currentMeeting: Meeting? { recording.currentMeeting }

    func startRecording(
        context: MeetingDetectionContext? = nil,
        source: String = "ui",
        systemAudioPolicy: RecordingSystemAudioPolicy = .meetingAppWhenAvailable
    ) {
        RecordingNotifier.shared.invalidateMeetingDetections()
        guard !dictation.isStarting, !dictation.state.isWorking else {
            lastError = "Finish or cancel dictation before starting a meeting recording."
            return
        }
        guard libraryReady else {
            pendingRecordingStart = (context, source, systemAudioPolicy)
            lastError = "Preparing your meeting library; recording will start when it is ready."
            return
        }
        recording.start(
            context: context,
            source: source,
            systemAudioPolicy: systemAudioPolicy)
    }

    func stopRecording(process: Bool = true) {
        if !libraryReady {
            pendingRecordingStart = nil
            return
        }
        recording.stop(process: process)
    }

    /// Recording started, stopped, or split to a new meeting: quiet cotyping
    /// and (re)point the live transcriber at the active meeting folder.
    private func meetingRecordingStateDidChange(active: Bool) {
        guard interactive else { return }
        if settings.cotypingEnabled {
            cotyping.meetingRecordingStateChanged(active: active)
        }
        if active, let meeting = recording.currentMeeting {
            liveTranscriber.prepare(folder: meeting.folderURL(in: storage))
        } else {
            liveTranscriber.stop(preservingHandoff: recording.isSplittingForCalendarHandoff)
        }
    }

    /// Menu-bar path to the live meeting: land on the library with the
    /// in-progress recording selected, so the detail pane shows the live
    /// transcript and notes.
    func showLiveMeeting() {
        guard let live = currentMeeting else { return }
        navSection = .meetings
        selectedMeetingIDs = [live.id]
        WindowAccess.shared.open("main")
    }

    init() {
        AppLog.bootstrap()
        settings = settingsStore.current
        if let raw = Self.navigationDefaults.string(forKey: Self.settingsTabDefaultsKey),
           let stored = SettingsTab(rawValue: raw) {
            settingsTab = stored
        }
        if let raw = Self.navigationDefaults.string(forKey: Self.typeTabDefaultsKey),
           let stored = TypeTab(rawValue: raw) {
            typeTab = stored
        } else {
            // Existing installs retain Dictation; genuinely new installs lead
            // with the approved Autocomplete experience.
            typeTab = Self.navigationDefaults.bool(forKey: Self.onboardingShownKey)
                ? .dictation : .cotyping
        }
        if Self.isUnitTesting { return }
        // Settings corruption is a privacy event, not a cosmetic one: a field
        // like screenshot capture silently resetting to its default changes
        // what the app records. Say exactly what fell back.
        if !settings.corruptedSettingsKeys.isEmpty {
            let keys = settings.corruptedSettingsKeys.joined(separator: ", ")
            lokalbotLog("settings decode fell back to defaults for: \(keys)")
            lastError = settings.corruptedSettingsKeys == [AppSettings.wholeStoreCorruptionMarker]
                ? "Saved settings could not be read and were reset to defaults. Review Settings — especially Privacy and Recording."
                : "Some saved settings could not be read and were reset to defaults (\(keys)). Review them in Settings."
        }
        let headlessCommand = HeadlessCommand.requested
        let needsSynchronousLibrary = headlessCommand != nil || Self.isUITesting
        if needsSynchronousLibrary {
            meetings = storage.loadMeetings()
            libraryReady = true
            outcomeIndex.refresh(meetings: meetings)
        }
        LiveMeetingTranscriber.sweepOrphanedSnapshots(storageRoot: storage.rootURL)
        // Views observe AppState only; forward pipeline / recording /
        // audio-monitor / calendar change notifications so MainWindowView
        // refreshes when those sub-ObservableObjects publish.
        pipelineObserver = pipeline.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        outcomeObserver = outcomeIndex.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        dictationObserver = Publishers.MergeMany([
            dictation.$state.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$isStarting.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$isShortcutMonitoringActive.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$lastTranscript.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$lastComposedText.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dictation.$lastEngine.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ]).sink { [weak self] in
            self?.objectWillChange.send()
        }
        // Forward lifecycle changes, but not RecordingController's one-second
        // `now` tick. Timer labels observe the controller directly; rebroadcasting
        // that tick through AppState invalidated the entire window hierarchy.
        recordingObserver = Publishers.CombineLatest(
            recording.$status,
            recording.$currentMeeting
        ).dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // React to recording start/stop (and calendar-handoff splits, which
        // change the meeting ID mid-recording): pause cotyping and run the
        // live transcriber against the active meeting folder.
        recordingStatusObserver = recording.$status
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                switch status {
                case .recording: self?.meetingRecordingStateDidChange(active: true)
                case .idle: self?.meetingRecordingStateDidChange(active: false)
                case .starting: break
                }
            }
        audioMonitorChangeForwarder = audioMonitor.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        calendarObserver = calendar.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        modelRolesObserver = modelRoles.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        navigationHandoffObserver = navigationHandoff.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        pipeline.onArtifactsWritten = { [weak self] meeting in
            guard let self else { return }
            self.outcomeIndex.refresh(meeting: meeting)
            self.reindexSearchInBackground(meeting)
            if self.settings.semanticSearchEnabled {
                self.reindexEmbeddingInBackground(meeting)
            }
            self.primaryEvidenceDidChange(for: meeting)
        }
        if needsSynchronousLibrary {
            searchIndex.reindexAll(meetings, storage: storage)
        }
        if let command = headlessCommand {
            HeadlessCommandRunner(app: self).run(command)
            return
        }
        // UI tests render against pre-seeded fixtures, not a real audio/Sparkle
        // session — bail out before any subsystem reaches for the mic, the
        // process list, or the network.
        if Self.isUITesting { return }
        interactive = true
        RecordingNotifier.shared.bootstrap()
        applyTrackingSetting()
        // Crash recovery: re-enqueue any meeting whose processing never
        // finished — a quit or crash mid-transcription used to lose the job.
        detector.onMeetingStarted = { [weak self] context in
            guard let self else { return }
            switch self.settings.autoRecordMode {
            case .automatic: self.startRecording(context: context, source: "detector")
            case .ask: self.notifyMeetingDetected(context)
            case .manual: RecordingNotifier.shared.invalidateMeetingDetections()
            }
        }
        detector.onMeetingSwitched = { [weak self] context in
            guard let self else { return }
            switch self.settings.autoRecordMode {
            case .automatic:
                RecordingNotifier.shared.invalidateMeetingDetections()
                self.recording.splitForCalendarHandoff(context)
            case .ask:
                if self.recording.isRecording || self.recording.isStarting {
                    RecordingNotifier.shared.invalidateMeetingDetections()
                } else {
                    self.notifyMeetingDetected(context)
                }
            case .manual:
                RecordingNotifier.shared.invalidateMeetingDetections()
            }
        }
        detector.onMeetingEnded = { [weak self] in
            RecordingNotifier.shared.invalidateMeetingDetections()
            guard let self else { return }
            if self.detector.endedMeetingURL != nil,
               self.recording.currentMeeting?.meetingURL != self.detector.endedMeetingURL { return }
            self.recording.stop(contentEndedAt: self.detector.detectedContentEnd)
        }
        detector.stopDebounce = settings.stopDebounceSeconds
        detector.calendar = calendar
        detector.calendarEnabled = settings.calendarDetectionEnabled
        detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
        // The mic-in-use signal misses meetings with a muted mic. The audio
        // monitor is the complementary "a meeting app just started producing
        // audio output" signal. In automatic mode it records recognised
        // meeting sources; other candidates expire silently.
        audioMonitor.start()
        audioMonitorObserver = audioMonitor.$detectedProcess
            .compactMap { $0 }
            .sink { [weak self] process in self?.audioMonitorDetected(process) }
        detector.start()
        // Start Sparkle (silent background check). No-op on dev builds and
        // until the appcast feed URL + public key are configured (RELEASING.md).
        AppUpdateManager.shared.start()
        // Resume the wake watcher when the Privacy marker was left enabled.
        agentAccess.start()
        screenMemoryAccess.start()
        applyQuickRecallSetting()
        applyDailyMemoryExportSetting()
        applyDayDigestSetting()
        applyMemoryRoutineSetting()
        applyDreamingSetting()
        // First-run check. A genuinely-new user with missing permissions gets
        // onboarding (windowed — see AppDelegate); the flag persists only when
        // they explicitly finish or defer the wizard (OnboardingView footer),
        // so quitting mid-wizard re-opens it next launch. Fully-permissioned
        // installs that predate the flag are recognised as established right
        // away and start menu-bar-only next launch.
        if !UserDefaults.standard.bool(forKey: Self.onboardingShownKey) {
            if PermissionManager.shared.allGranted {
                UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
            } else {
                WindowAccess.shared.open("onboarding")
            }
        }
        // Bring optional system-wide automation up if the user left it enabled
        // and the grants are in place; otherwise it parks itself.
        dictation.applySettings()
        cotyping.applySettings()
        if settings.cotypingEnabled { scheduleCotypingPrewarm() }
        loadLibraryInBackground()
    }

    /// Large meeting libraries can take seconds to enumerate, repair, duration-
    /// probe, and FTS-index. Do that work on a utility executor and publish one
    /// sorted snapshot when ready instead of blocking the first app window.
    private func loadLibraryInBackground() {
        libraryLoadTask?.cancel()
        let rootURL = storage.rootURL
        libraryLoadTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return [Meeting]() }
                let workerStorage = StorageManager(rootURL: rootURL)
                return workerStorage.loadMeetings()
            }
            let loaded = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled else { return }

            var byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            // Preserve meetings created while the background scan was running.
            for meeting in self.meetings { byID[meeting.id] = meeting }
            let merged = byID.values.sorted { $0.startedAt > $1.startedAt }
            self.meetings = merged
            self.libraryReady = true
            self.speakerIdentity.maintainRetention(meetings: { [weak self] in self?.meetings ?? [] })
            self.outcomeIndex.refresh(meetings: merged)
            self.pipeline.resumePending(meetings: merged)
            // Dreaming was deliberately gated while launch recovery rebuilt
            // the library and durable processing queue. Re-check immediately;
            // pending pipeline work will keep the downtime gate closed until a
            // later timer tick.
            self.dreaming.tick()
            self.reindexLibraryInBackground(merged)
            if self.settings.semanticSearchEnabled {
                self.reindexEmbeddingLibraryInBackground(merged)
            }
            self.libraryLoadTask = nil
            if let pending = self.pendingRecordingStart {
                self.pendingRecordingStart = nil
                self.lastError = nil
                self.startRecording(
                    context: pending.context,
                    source: pending.source,
                    systemAudioPolicy: pending.systemAudioPolicy)
            }
        }
    }

    private func reindexLibraryInBackground(_ meetings: [Meeting]) {
        let worker = searchIndexWorkQueue
        Task { await worker.enqueue(meetings) }
    }

    private func reindexSearchInBackground(_ meeting: Meeting) {
        let worker = searchIndexWorkQueue
        Task { await worker.enqueue(meeting) }
    }

    private func reindexEmbeddingLibraryInBackground(_ meetings: [Meeting]) {
        embeddingBackfillTask?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.embeddingIndex.reindexAll(meetings)
            guard self.embeddingBackfillTask?.token == token else { return }
            self.embeddingBackfillTask = nil
        }
        embeddingBackfillTask = (token, task)
    }

    private func reindexEmbeddingInBackground(_ meeting: Meeting) {
        embeddingIndexTasks.removeValue(forKey: meeting.id)?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            try? await self.embeddingIndex.index(meeting)
            guard self.embeddingIndexTasks[meeting.id]?.token == token else { return }
            self.embeddingIndexTasks.removeValue(forKey: meeting.id)
        }
        embeddingIndexTasks[meeting.id] = (token, task)
    }

    /// Index rows are reconstructible, but a failed SQLite cleanup must not
    /// become permanent once the meeting folder disappears. Retry both stores
    /// with bounded backoff for the rest of the session; durable tombstones and
    /// each index's startup reconciliation cover interruption or app exit.
    private func scheduleIndexCleanup(_ meetingID: Meeting.ID) {
        indexCleanupTasks.removeValue(forKey: meetingID)?.task.cancel()
        let token = UUID()
        let worker = searchIndexWorkQueue
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var embeddingClean = false
            var searchClean = false
            var attempt = 0

            while !Task.isCancelled {
                let result = await worker.remove(meetingID)
                embeddingClean = embeddingClean || result.embedding
                searchClean = searchClean || result.search
                guard !Task.isCancelled,
                      self.indexCleanupTasks[meetingID]?.token == token else { return }
                if embeddingClean && searchClean {
                    self.indexCleanupTasks.removeValue(forKey: meetingID)
                    return
                }

                attempt += 1
                if attempt.isMultiple(of: 4) {
                    let reconciled = await worker.reconcileDeletedMeetings()
                    embeddingClean = embeddingClean || reconciled.embedding
                    searchClean = searchClean || reconciled.search
                }
                let delayMilliseconds = min(30_000, 250 * (1 << min(attempt, 7)))
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
        }
        indexCleanupTasks[meetingID] = (token, task)
    }

    private enum CotypingRuntimeOperation {
        case unload
        case prewarm
    }

    private func scheduleCotypingRuntimeUnload() {
        scheduleCotypingRuntimeOperation(.unload)
    }

    private func scheduleCotypingPrewarm() {
        scheduleCotypingRuntimeOperation(.prewarm)
    }

    /// Queue lifecycle changes instead of launching independent tasks. An
    /// unload intentionally runs even if a later operation cancels its task:
    /// the later operation awaits it before loading another model.
    private func scheduleCotypingRuntimeOperation(_ operation: CotypingRuntimeOperation) {
        let previous = cotypingRuntimeTask
        previous?.cancel()
        let taskID = UUID()
        cotypingRuntimeTaskID = taskID
        cotypingRuntimeTask = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            defer {
                if self.cotypingRuntimeTaskID == taskID {
                    self.cotypingRuntimeTask = nil
                    self.cotypingRuntimeTaskID = nil
                }
            }
            switch operation {
            case .unload:
                await self.cotypingEngine.unload()
            case .prewarm:
                guard !Task.isCancelled, self.settings.cotypingEnabled else { return }
                await self.cotypingEngine.prewarm()
            }
        }
    }

    func prepareForTermination() async {
        if let terminationCleanupTask {
            await terminationCleanupTask.value
            return
        }
        let task = Task { @MainActor in
            interactive = false
            settingsStore.flush()
            let pendingCotypingRuntimeTask = self.cotypingRuntimeTask
            pendingCotypingRuntimeTask?.cancel()
            await pendingCotypingRuntimeTask?.value
            self.cotypingRuntimeTask = nil
            cotypingRuntimeTaskID = nil
            libraryLoadTask?.cancel()
            libraryLoadTask = nil
            embeddingBackfillTask?.task.cancel()
            embeddingBackfillTask = nil
            for entry in embeddingIndexTasks.values { entry.task.cancel() }
            embeddingIndexTasks.removeAll()
            for entry in indexCleanupTasks.values { entry.task.cancel() }
            indexCleanupTasks.removeAll()
            await searchIndexWorkQueue.stop()
            pendingRecordingStart = nil
            recording.prepareForTermination()
            detector.stop()
            audioMonitor.stop()
            sampler.stop()
            screenshots.stop()
            quickRecallHotKey.stop()
            dailyMemoryExportScheduler.stop()
            memoryRoutines.stop()
            dreaming.stop()
            chat.stop()
            dictation.stop()
            cotyping.stop()
            await cotypingLearning.flushPersistence()
            await CotypingStatsStore.shared.flushPersistence()
            await agentSessions.shutdownAll()
            await cotypingEngine.unload()
            await LlamaServer.shared.stop()
            await LlamaServer.embedder.stop()
            await LlamaServer.cotyping.stop()
            await GraniteSpeechEngine.shared.shutdown()
        }
        terminationCleanupTask = task
        await task.value
    }

    // MARK: - Detection → recording glue

    /// Builds a detection context for a user-initiated recording on `detectedApp`
    /// (nil → manual), folding in the active calendar event when calendar
    /// detection is enabled and authorized — so menu and command entry points
    /// get calendar titling too.
    func recordingContext(for detectedApp: MeetingDetector.DetectedApp?) -> MeetingDetectionContext? {
        guard let detectedApp else { return nil }
        let event = (settings.calendarDetectionEnabled && calendar.hasAccess)
            ? calendar.activeCandidate(now: Date()) : nil
        return MeetingDetectionContext(
            detectedApp: detectedApp,
            calendarEvent: event,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: event != nil),
            reason: "user")
    }

    /// A user can explicitly start the scheduled event from Today's upcoming
    /// meeting card before automatic detection fires. Attach the calendar
    /// metadata immediately; capture system audio too when a matching meeting
    /// app is already visible, otherwise RecordingController safely records
    /// the microphone when no meeting app is visible yet.
    func recordingContext(for calendarEvent: CalendarMeetingCandidate) -> MeetingDetectionContext {
        let detectedApp = detector.activeApp ?? MeetingDetector.visibleBrowserMeeting()
        return MeetingDetectionContext(
            detectedApp: detectedApp,
            calendarEvent: calendarEvent,
            confidence: MeetingMatcher.confidence(
                hasApp: detectedApp != nil,
                hasCalendar: true),
            reason: "today-upcoming")
    }

    /// `AudioSourceMonitor` saw an app newly start producing output. Auto-record
    /// in automatic mode only for high-confidence native meeting output or a
    /// verified browser meeting; ignore broader candidates so notification
    /// sounds cannot start recordings.
    private func audioMonitorDetected(_ process: AudioProcess) {
        guard !recording.isRecording, !recording.isStarting else { return }
        guard settings.autoRecordMode == .automatic, let bundleID = process.bundleID else { return }
        let calendarEvent = (settings.calendarDetectionEnabled && calendar.hasAccess)
            ? calendar.activeCandidate(now: Date()) : nil
        if let name = MeetingDetector.knownApps[bundleID] {
            guard MeetingDetector.shouldAutoRecordNativeAudioMonitor(
                bundleID: bundleID,
                calendarBacked: calendarEvent != nil) else {
                return
            }
            let detected = MeetingDetector.DetectedApp(name: name, bundleID: bundleID, pid: process.id)
            startRecording(context: detectionContext(detected, calendarEvent), source: "audio-monitor")
            return
        }
        guard MeetingDetector.hostBrowserBundleID(forAudioBundleID: bundleID) != nil else { return }
        detector.checkNow()
    }

    private func detectionContext(_ app: MeetingDetector.DetectedApp,
                                  _ event: CalendarMeetingCandidate?) -> MeetingDetectionContext {
        MeetingDetectionContext(
            detectedApp: app, calendarEvent: event,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: event != nil),
            reason: "audio-monitor")
    }

    private func notifyMeetingDetected(_ context: MeetingDetectionContext) {
        lastError = nil
        let title = MeetingMatcher.recordingTitle(
            calendarTitle: context.calendarEvent?.title,
            useCalendarTitles: settings.useCalendarTitles,
            appName: context.detectedApp?.name)
        RecordingNotifier.shared.meetingDetected(title: title) { [weak self] in
            guard let self,
                  self.settings.autoRecordMode == .ask,
                  !self.recording.isRecording,
                  !self.recording.isStarting else { return }
            self.startRecording(context: context, source: "notification")
        }
    }

    // MARK: - Library operations

    /// Creates a new, provenance-linked meeting from completed sources. The
    /// source folders remain untouched, but their rows are folded out of the
    /// library after the merge succeeds.
    func mergeMeetings(
        _ sourceMeetings: [Meeting],
        title: String,
        generateSummary: Bool
    ) async throws -> Meeting {
        for meeting in sourceMeetings {
            if let stage = pipeline.stages[meeting.id], !stage.isFailure {
                throw MeetingMergeService.MergeError.processingInProgress(meeting.displayTitle)
            }
        }
        let result = try await MeetingMergeService.merge(
            meetings: sourceMeetings,
            title: title,
            storage: storage)

        let sourceIDs = Set(result.sourceMeetings.map(\.id))
        pipeline.forget(meetingIDs: sourceIDs)
        let worker = searchIndexWorkQueue
        for sourceID in sourceIDs {
            embeddingIndexTasks.removeValue(forKey: sourceID)?.task.cancel()
            excludedMeetingIDs.insert(sourceID)
            cachedSearchIndex?.noteDeletion(sourceID)
            cachedEmbeddingIndex?.noteDeletion(sourceID)
            // Tombstone both indexes before publishing the folded library
            // projection. The retry loop remains available for a transient
            // SQLite failure, but a normal merge cannot leave searchable
            // source rows behind if the app exits immediately afterward.
            let cleanup = await worker.remove(sourceID)
            if !cleanup.search || !cleanup.embedding {
                scheduleIndexCleanup(sourceID)
            }
        }
        meetings.removeAll { sourceIDs.contains($0.id) }
        selectedMeetingIDs.subtract(sourceIDs)
        meetings.append(result.meeting)
        meetings.sort { $0.startedAt > $1.startedAt }
        outcomeIndex.refresh(meetings: meetings)
        primaryEvidenceDidChange(for: result.sourceMeetings + [result.meeting])
        reindexSearchInBackground(result.meeting)
        if settings.semanticSearchEnabled {
            reindexEmbeddingInBackground(result.meeting)
        }
        selectedMeetingIDs = [result.meeting.id]
        navSection = .meetings
        if generateSummary, result.transcriptSegmentCount > 0 {
            reprocess(result.meeting, transcribe: false, summarize: true)
        }
        return result.meeting
    }

    /// Removes a generated merged record and restores its original source
    /// rows. Source folders are retained; their durable merge markers and
    /// search tombstones are cleared before the restored evidence is indexed.
    func undoMerge(_ mergedMeeting: Meeting) {
        guard let rawSourceIDs = mergedMeeting.mergedSourceMeetingIDs,
              rawSourceIDs.count >= 2 else {
            lastError = "This meeting does not contain a reversible merge."
            return
        }
        if let stage = pipeline.stages[mergedMeeting.id], !stage.isFailure {
            lastError = "Wait for the merged summary to finish before undoing the merge."
            return
        }

        let sourceIDs = Set(rawSourceIDs)
        let sources = storage.loadMeetings(includeMergedSources: true)
            .filter { sourceIDs.contains($0.id) }
        guard sources.count == sourceIDs.count,
              sources.allSatisfy({ $0.mergedIntoMeetingID == mergedMeeting.id }) else {
            lastError = "Some original meetings could not be found, so the merge was kept intact."
            return
        }

        lastError = nil
        let worker = searchIndexWorkQueue
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                pipeline.forget(meetingIDs: [mergedMeeting.id])
                try await speakerIdentity.prepareDeletion(meeting: mergedMeeting)
                try storage.deleteMeeting(mergedMeeting)
                meetings.removeAll { $0.id == mergedMeeting.id }
                selectedMeetingIDs.remove(mergedMeeting.id)
                outcomeIndex.refresh(meetings: meetings)

                embeddingIndexTasks.removeValue(forKey: mergedMeeting.id)?.task.cancel()
                excludedMeetingIDs.insert(mergedMeeting.id)
                cachedSearchIndex?.noteDeletion(mergedMeeting.id)
                cachedEmbeddingIndex?.noteDeletion(mergedMeeting.id)
                scheduleIndexCleanup(mergedMeeting.id)

                var restoredSources: [Meeting] = []
                var restorationErrors: [String] = []
                for source in sources {
                    indexCleanupTasks.removeValue(forKey: source.id)?.task.cancel()
                    do {
                        let restored = try await worker.restore(source)
                        restoredSources.append(restored)
                        excludedMeetingIDs.remove(source.id)
                        cachedSearchIndex?.noteRestoration(source.id)
                        cachedEmbeddingIndex?.noteRestoration(source.id)
                        if settings.semanticSearchEnabled {
                            reindexEmbeddingInBackground(restored)
                        }
                    } catch {
                        // Other sources can still recover. Failed ones retain
                        // their on-disk marker and are retried at next launch.
                        restorationErrors.append(error.localizedDescription)
                    }
                }
                meetings.append(contentsOf: restoredSources)
                meetings.sort { $0.startedAt > $1.startedAt }
                outcomeIndex.refresh(meetings: meetings)
                primaryEvidenceDidChange(for: [mergedMeeting] + restoredSources)
                selectedMeetingIDs = restoredSources
                    .sorted { $0.startedAt < $1.startedAt }
                    .first.map { [$0.id] } ?? []
                navSection = .meetings
                if !restorationErrors.isEmpty {
                    lastError = "Some original meetings could not be restored; restart to retry: "
                        + restorationErrors.joined(separator: "; ")
                }
            } catch {
                lastError = "Could not undo the merge: \(error.localizedDescription)"
            }
        }
    }

    func setMeetingBoundaries(_ range: Meeting.ContentRange, for meeting: Meeting) throws {
        if let stage = pipeline.stages[meeting.id], !stage.isFailure {
            throw TextEngineError.badResponse("Wait for meeting processing to finish before changing its boundaries.")
        }
        guard range.isValid, let duration = meeting.recordedDuration ?? meeting.duration,
              range.end <= duration else {
            throw TextEngineError.badResponse("Choose a start and end within the recorded audio, with the end after the start.")
        }
        var updated = meeting
        updated.contentRange = range
        let folder = updated.folderURL(in: storage)
        let existing = try pipeline.loadTranscript(from: folder)
        // Invalidate derived claims even when no complete segment survives.
        try MeetingAttributionArtifacts.invalidate(in: folder)
        try pipeline.saveTranscript(range.applying(to: existing), for: updated)
        try storage.saveMeta(updated)
        if let index = meetings.firstIndex(where: { $0.id == updated.id }) { meetings[index] = updated }
        outcomeIndex.refresh(meeting: updated)
        primaryEvidenceDidChange(for: updated)
        searchIndex.reindex(updated, storage: storage)
        embeddingIndexTasks.removeValue(forKey: updated.id)?.task.cancel()
        _ = embeddingIndex.remove(updated.id)
        reprocess(updated, transcribe: true, summarize: true)
    }

    func reprocess(_ meeting: Meeting, transcribe: Bool, summarize: Bool) {
        lastError = nil
        switch pipeline.enqueue(
            meeting,
            transcribe: transcribe,
            summarize: summarize) {
        case .alreadyProcessing:
            lastError = "Summary processing has already started for this meeting. Wait for it to finish before choosing a different processing action."
        case .persistenceFailed:
            lastError = "LokalBot could not save the updated processing request."
        case .enqueued, .coalesced, .updatedActive:
            break
        }
    }

    /// Resume from the latest durable artifact. If transcription already
    /// succeeded, Retry fixes only summarization; missing transcripts still run
    /// the complete pipeline. User-initiated work may download missing models.
    func retryProcessing(_ meeting: Meeting) {
        let work = pipeline.retryWork(
            for: meeting, autoSummarize: settings.autoSummarize)
        reprocess(meeting, transcribe: work.transcribe, summarize: work.summarize)
    }

    /// Meetings parked because a model was missing re-enter the queue; jobs
    /// whose models are still missing simply park again — nothing downloads
    /// from this path.
    func processMeetingsWaitingForModels() {
        pipeline.retryJobsWaitingForModels()
    }

    func saveTranscript(_ transcript: Transcript, for meeting: Meeting) throws {
        let transcript = speakerIdentity.applyingLatestDecision(to: transcript, meetingID: meeting.id)
        try pipeline.saveTranscript(transcript, for: meeting)
        outcomeIndex.refresh(meeting: meeting)
        primaryEvidenceDidChange(for: meeting)
        reindexSearchInBackground(meeting)
        if settings.semanticSearchEnabled {
            reindexEmbeddingInBackground(meeting)
        }
        objectWillChange.send()
    }

    func speakerNameHints(for meeting: Meeting) -> [String] {
        let fallbackDuration = max(meeting.recordedDuration ?? 60, 60)
        let fallbackEnd = meeting.startedAt.addingTimeInterval(fallbackDuration)
        var end = meeting.endedAt.map { max($0, meeting.startedAt) } ?? fallbackEnd
        if end <= meeting.startedAt { end = fallbackEnd }
        let ocr = activityStore.ocrText(from: meeting.startedAt, to: end, maxChars: 12_000)
        return SpeakerNameHintExtractor.hints(
            calendarNames: meeting.resolvedCalendarParticipantIdentities.compactMap(\.name),
            ocrText: ocr)
    }

    /// One invalidation route for every meeting-evidence write. Processing and
    /// user outcome edits both reach this path, so derived Digest, Dream,
    /// export, and routine surfaces cannot silently diverge.
    private func primaryEvidenceDidChange(for meeting: Meeting) {
        primaryEvidenceDidChange(for: [meeting])
    }

    private func primaryEvidenceDidChange(for meetings: [Meeting]) {
        primaryEvidenceDidChange(on: meetings.map(\.startedAt))
    }

    func primaryEvidenceDidChange(on day: Date) {
        primaryEvidenceDidChange(on: [day])
    }

    func primaryEvidenceDidChange(on days: [Date]) {
        guard !days.isEmpty else { return }
        dayDigest.reconsiderEvidence(for: days)
        dailyMemoryExportScheduler.reconsider(days: days)
        memoryRoutines.reconsiderEvidence()
        invalidateDreams(affectedDays: days)
    }

    private func dayDigestDidChange(on day: Date) {
        // Export may have run while the replacement digest was still awaiting
        // a model. Reopen consumers after the journal and provenance are saved.
        dailyMemoryExportScheduler.reconsider(day: day)
        memoryRoutines.reconsiderEvidence()
        invalidateDreams(affectedDays: [day], comparisonWindowDays: 1)
    }

    private func invalidateDreams(
        affectedDays: [Date], comparisonWindowDays: Int = DreamCompiler.comparisonWindowDays
    ) {
        let calendar = Calendar.current
        let affectedKeys = DreamEvidenceInvalidation.dayKeys(
            affectedDays: affectedDays, through: Date(), calendar: calendar,
            comparisonWindowDays: comparisonWindowDays)
        for key in affectedKeys.sorted() {
            do {
                try dreamStore.invalidateReport(forDayKey: key)
            } catch {
                lastError = "Could not refresh the dream for \(key): " + error.localizedDescription
            }
        }
        latestDreamReport = dreamStore.latestReport()
        dreaming.reconsiderReports(invalidating: affectedKeys)
    }

    func applyTrackingSetting() {
        sampler.excludedApps = { [weak self] in self?.settings.excludedAppList ?? [] }
        if settings.trackingEnabled { sampler.start() } else { sampler.stop() }
        screenshots.restart()
    }

    func applyQuickRecallSetting() {
        let registered = quickRecallHotKey.setEnabled(settings.quickRecallEnabled)
        if settings.quickRecallEnabled, !registered {
            settings.quickRecallEnabled = false
            lastError = "The Ask shortcut could not register \(QuickRecallHotKeyController.shortcutLabel). Another app may already use it."
        }
    }

    func applyDailyMemoryExportSetting() {
        let snapshot = settings
        let destinationID = snapshot.dailyMemoryExportFolder.isEmpty
            ? ""
            : "\(snapshot.dailyMemoryExportFolder)|\(snapshot.dailyMemoryExportFormat.rawValue)"
        let configuration = DailyMemoryExportScheduler.Configuration(
            enabled: snapshot.dailyMemoryExportEnabled,
            hour: snapshot.dailyMemoryExportHour,
            destinationID: destinationID)
        let storageRoot = storage.rootURL
        let destinationPath = snapshot.dailyMemoryExportFolder
        let exportKind: DailyMemoryExportKind = switch snapshot.dailyMemoryExportFormat {
        case .markdown: .markdown
        case .obsidian: .obsidian
        case .logseq: .logseq
        }
        dailyMemoryExportScheduler.configure(configuration) { day in
            let destination = URL(
                fileURLWithPath: destinationPath,
                isDirectory: true)
            try Task.checkCancellation()
            let service = DailyMemoryExportService(
                source: FileDailyMemoryExportSource(root: storageRoot),
                calendar: .current)
            _ = try service.export(
                day: day,
                configuration: DailyMemoryExportConfiguration(
                    destinationDirectory: destination,
                    format: exportKind))
        } onError: { [weak self] message in
            self?.lastError = message
        }
    }

    func applyDayDigestSetting() {
        let snapshot = settings
        dayDigest.configureAutomaticGeneration(
            DayDigestScheduler.Configuration(
                enabled: snapshot.dayDigestAutoEnabled,
                hour: snapshot.dayDigestHour),
            canRun: { [weak self] in
                guard let self, self.libraryReady else { return false }
                // Scheduled background work never triggers a model download —
                // the digest waits until the Think model is actually on disk
                // (or a remote backend is configured).
                guard ModelReadinessSnapshot.thinkReady(self.settings, storage: self.storage)
                else { return false }
                let cotypingGenerating: Bool
                if case .generating = self.cotyping.state {
                    cotypingGenerating = true
                } else {
                    cotypingGenerating = false
                }
                return !self.recording.isRecording
                    && !self.recording.isStarting
                    && !self.dictation.isStarting
                    && !self.dictation.state.isWorking
                    && !cotypingGenerating
                    && !self.pipeline.hasActiveWork
            },
            onError: { [weak self] message in
                self?.lastError = message
            })
    }

    func applyMemoryRoutineSetting() {
        let snapshot = settings
        memoryRoutines.configure(MemoryRoutineScheduler.Configuration(
            enabled: snapshot.memoryRoutinesEnabled,
            destinationPath: snapshot.memoryRoutineFolder,
            kinds: snapshot.enabledMemoryRoutines,
            hour: snapshot.memoryRoutineHour,
            weekday: snapshot.memoryRoutineWeekday
        )) { [weak self] message in
            self?.lastError = message
        }
    }

    func applyDreamingSetting() {
        let snapshot = settings

        // Persist the beginning of each opt-in period. This keeps catch-up
        // bounded instead of interpreting a first launch as permission to
        // backfill every historical workday.
        if snapshot.dreamingEnabled,
           snapshot.dreamingFirstEligibleDayKey?.isEmpty != false {
            let calendar = Calendar.current
            var updated = snapshot
            updated.dreamingFirstEligibleDayKey = DreamDay.key(
                for: DreamScheduler.previousDay(of: Date(), calendar: calendar),
                calendar: calendar)
            settings = updated
            return
        }

        if !snapshot.dreamingEnabled,
           snapshot.dreamingFirstEligibleDayKey != nil {
            var updated = snapshot
            updated.dreamingFirstEligibleDayKey = nil
            settings = updated
            return
        }

        let storageRoot = storage.rootURL
        dreaming.configure(
            DreamScheduler.Configuration(
                enabled: snapshot.dreamingEnabled,
                hour: snapshot.dreamingHour,
                firstEligibleDayKey: snapshot.dreamingFirstEligibleDayKey ?? ""),
            hasReport: { dayKey in
                DreamStore(root: storageRoot).hasReport(forDayKey: dayKey)
            },
            canRun: { [weak self] in
                guard let self else { return false }
                guard self.libraryReady else { return false }
                // Overnight dreaming is background automation: never let it
                // trigger a model download on a fresh install.
                guard ModelReadinessSnapshot.thinkReady(self.settings, storage: self.storage)
                else { return false }
                let cotypingGenerating: Bool
                if case .generating = self.cotyping.state {
                    cotypingGenerating = true
                } else {
                    cotypingGenerating = false
                }
                let lokalBotIsIdle = !self.recording.isRecording
                    && !self.recording.isStarting
                    && !self.dictation.isStarting
                    && !self.dictation.state.isWorking
                    && !cotypingGenerating
                    && !self.pipeline.hasActiveWork
                guard lokalBotIsIdle else { return false }
                guard DreamScheduler.powerAllowsDreaming(
                    isOnBattery: PowerSourceMonitor.currentlyOnBattery(),
                    isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) else {
                    return false
                }
                let userIdleSeconds = CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                return DreamScheduler.isSystemIdle(for: userIdleSeconds)
            },
            dream: { [weak self] target in
                guard let self else {
                    throw TextEngineError.unavailable("LokalBot is shutting down.")
                }
                let service = DreamService(
                    storageRoot: storageRoot,
                    makeEngine: { [weak self] in
                        guard let self else {
                            throw TextEngineError.unavailable("LokalBot is shutting down.")
                        }
                        let engineSettings = self.settings
                        let engine = try await self.thinkExecution.makeTextEngine(
                            engineSettings,
                            priority: .background,
                            purpose: "dreaming")
                        return (engine, DreamInferenceProvenance(settings: engineSettings))
                    })
                let report = try await service.dream(target: target)
                self.latestDreamReport = report
                self.refreshDreamMemory()
            },
            onError: { [weak self] message in
                self?.lastError = message
            })
    }

    func setDreamingEnabled(_ enabled: Bool) {
        guard settings.dreamingEnabled != enabled else { return }

        var updated = settings
        updated.dreamingEnabled = enabled
        if enabled {
            let calendar = Calendar.current
            updated.dreamingFirstEligibleDayKey = DreamDay.key(
                for: DreamScheduler.previousDay(of: Date(), calendar: calendar),
                calendar: calendar)
        } else {
            updated.dreamingFirstEligibleDayKey = nil
        }
        settings = updated
    }

    func dreamNow() {
        guard libraryReady else {
            lastError = "Preparing your meeting library; dreaming will be available when it is ready."
            return
        }
        dreaming.dreamNow()
    }

    func refreshDreamMemory() {
        do {
            dreamMemory = try dreamStore.loadMemory()
        } catch {
            dreamMemory = nil
            lastError = "Could not load dream memory: \(error.localizedDescription)"
        }
    }

    func setDreamMemoryPinned(_ pinned: Bool, for entry: DreamMemoryEntry) {
        guard !dreaming.isDreaming else {
            lastError = "Wait for the current dream to finish before changing pins."
            return
        }
        do {
            guard let updated = try dreamStore.setPinned(pinned, for: entry) else {
                refreshDreamMemory()
                lastError = "That dream memory item is no longer available."
                return
            }
            dreamMemory = updated
        } catch {
            lastError = "Could not update dream memory: \(error.localizedDescription)"
        }
    }

    func restartMemoryCapture() {
        sampler.stop()
        screenshots.stop()
        applyTrackingSetting()
        PermissionManager.shared.refresh()
    }

    /// Search hit → open the meeting; transcript hits seek the player.
    func openSearchHit(_ hit: SearchIndex.Hit) {
        openMeeting(
            hit.meetingID,
            seek: hit.kind == .segment ? hit.start : nil)
    }

    /// Screen search/citation hit → open Timeline at the exact captured frame.
    func openScreenSnapshot(_ snapshotID: Int64) {
        if navSection != .timeline {
            evidenceReturnSection = navSection
            evidenceReturnMeetingIDs = selectedMeetingIDs
        }
        navigationHandoff.stageScreenSnapshot(snapshotID)
        selectedMeetingIDs = []
        navSection = .timeline
    }

    /// Chat citation marker → open the cited meeting; timed markers seek the player.
    func openCitation(_ citation: ChatCitation) {
        guard let meeting = ((try? SessionLookup.find(id: citation.meetingID, in: meetings)) ?? nil) else { return }
        openMeeting(meeting.id, seek: citation.seconds)
    }

    /// Permanently removes meetings: audio folder, list entry, both indexes.
    func deleteMeetings(_ ids: Set<Meeting.ID>) {
        let candidates = meetings.filter { ids.contains($0.id) }
        pipeline.forget(meetingIDs: ids)
        Task {
            var deletedIDs: Set<Meeting.ID> = []
            var deletedMeetings: [Meeting] = []
            for meeting in candidates {
                do {
                    let ordered = try storage.deletionOrder(for: meeting)
                    pipeline.forget(meetingIDs: Set(ordered.map(\.id)))
                    for item in ordered where !deletedIDs.contains(item.id) {
                        // Revoke every retained source's profile contributions,
                        // not just those of the generated parent. Delete the
                        // parent last so partial failure cannot restore sources.
                        try await speakerIdentity.prepareDeletion(meeting: item)
                        try storage.deleteMeeting(item)
                        embeddingIndexTasks.removeValue(forKey: item.id)?.task.cancel()
                        excludedMeetingIDs.insert(item.id)
                        cachedSearchIndex?.noteDeletion(item.id)
                        cachedEmbeddingIndex?.noteDeletion(item.id)
                        scheduleIndexCleanup(item.id)
                        deletedIDs.insert(item.id)
                        deletedMeetings.append(item)
                    }
                } catch {
                    lastError = "Could not delete \(meeting.title); cleanup pending: \(error.localizedDescription)"
                }
            }
            meetings.removeAll { deletedIDs.contains($0.id) }
            selectedMeetingIDs.subtract(deletedIDs)
            outcomeIndex.refresh(meetings: meetings)
            primaryEvidenceDidChange(for: deletedMeetings)
        }
    }
}
