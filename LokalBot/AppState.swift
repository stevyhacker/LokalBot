import SwiftUI
import Combine
import AVFoundation
import CoreGraphics

@MainActor
final class AppState: ObservableObject {

    enum NavSection: Hashable {
        case today, actions, timeline, meetings, people, projects, ask, agent

        var symbol: String {
            switch self {
            case .today: "sun.max"
            case .actions: "checkmark.circle"
            case .timeline: "calendar.day.timeline.left"
            case .meetings: "waveform.circle"
            case .people: "person.2"
            case .projects: "folder"
            case .ask: "sparkle.magnifyingglass"
            case .agent: "wand.and.sparkles"
            }
        }

        init?(captureName: String) {
            switch captureName.lowercased() {
            case "today": self = .today
            case "actions": self = .actions
            case "timeline", "capture": self = .timeline
            case "meetings": self = .meetings
            case "people": self = .people
            case "projects": self = .projects
            case "ask", "search", "chat": self = .ask
            case "agent": self = .agent
            default: return nil
            }
        }
    }

    enum TypeTab: String {
        case dictation, cotyping

        init?(captureName: String) {
            switch captureName.lowercased() {
            case "dictation": self = .dictation
            case "cotyping", "autocomplete": self = .cotyping
            default: return nil
            }
        }
    }

    enum SettingsTab: String, CaseIterable {
        case overview
        case general, models, privacy
        case recording, dayMemory, files, email
        case ask, personalContext, daily
        case writing, dictation
        case agents, devices
        case advanced

        enum Group: String, CaseIterable {
            case remember = "Remember", assistant = "Assistant", writing = "Writing", sharing = "Sharing"
        }

        var group: Group? {
            switch self {
            case .overview, .general, .models, .privacy, .advanced: nil
            case .recording, .dayMemory, .files, .email: .remember
            case .ask, .personalContext, .daily: .assistant
            case .writing, .dictation: .writing
            case .agents, .devices: .sharing
            }
        }

        static let leadingPages: [SettingsTab] = [.general, .models, .privacy]
        static let trailingPages: [SettingsTab] = [.advanced]

        var displayName: String {
            switch self {
            case .overview: "Overview"
            case .recording: "Meetings"
            case .dayMemory: "Screen & activity"
            case .files: "Files"
            case .email: "Email"
            case .ask: "Ask"
            case .personalContext: "About you"
            case .daily: "Daily review"
            case .writing: "Autocomplete"
            case .dictation: "Dictation"
            case .models: "Models"
            case .agents: "AI agents"
            case .devices: "Phones & tablets"
            case .general: "General"
            case .privacy: "Privacy & permissions"
            case .advanced: "Diagnostics"
            }
        }

        var formerNames: [String] {
            switch self {
            case .personalContext: ["Personal Context"]
            case .agents: ["External Agents"]
            case .dayMemory: ["Day Memory"]
            case .writing: ["Writing"]
            case .recording: ["Recording"]
            case .advanced: ["Advanced"]
            case .privacy: ["Privacy & Data"]
            default: []
            }
        }

        var icon: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .recording: "waveform"
            case .dayMemory: "macwindow"
            case .files: "doc.on.doc"
            case .email: "envelope"
            case .ask: "sparkles"
            case .personalContext: "person.crop.circle"
            case .daily: "moon.stars"
            case .writing: "character.cursor.ibeam"
            case .dictation: "mic"
            case .models: "shippingbox"
            case .agents: "point.3.connected.trianglepath.dotted"
            case .devices: "ipad.and.iphone"
            case .general: "gearshape"
            case .privacy: "lock"
            case .advanced: "waveform.path.ecg"
            }
        }

        var summary: String {
            switch self {
            case .overview: ""
            case .recording: "Detection, transcription, speakers, notes, and export."
            case .dayMemory: "What LokalBot sees on screen, how long it keeps it, and what it never captures."
            case .files: "Folders LokalBot reads, so Ask can find files by what’s in them."
            case .email: "Read-only Gmail, so briefs and Ask know the conversation."
            case .ask: "Ask from any app, act on selected text, and choose what answers use."
            case .personalContext: "What you told LokalBot about yourself, and what it learns."
            case .daily: "The day digest, the overnight review, routines, and the daily note."
            case .writing: "Suggests the next few words as you type, in any app."
            case .dictation: "Press %@, speak, and the text lands where you type."
            case .models: "Three AI models do LokalBot’s work. They run on this Mac unless you choose an online one."
            case .agents: "What Claude, Codex, Cursor, and other agents can read or change."
            case .devices: "Read your work memory on your own iPhone, iPad, or Android device."
            case .general: "Startup, appearance, and updates."
            case .privacy: "What LokalBot may use on this Mac, and what leaves it."
            case .advanced: "Memory health, resources, and files for support."
            }
        }

        static func opensSettings(sectionName: String) -> Bool {
            let name = sectionName.lowercased()
            return name == "settings" || ["write", "type", "cotyping"].contains(name)
                || (SettingsTab(captureName: name) != nil && NavSection(captureName: name) == nil)
        }

        init?(captureName: String) {
            switch captureName.lowercased() {
            case "overview": self = .overview
            case "general": self = .general
            case "recording", "meetings": self = .recording
            case "daymemory", "day memory", "screen", "screen & activity", "activity": self = .dayMemory
            case "files": self = .files
            case "email", "mail", "gmail": self = .email
            case "ask": self = .ask
            case "personalcontext", "personal context", "personal-context", "aboutyou", "about you":
                self = .personalContext
            case "daily", "dailyreview", "daily review", "overnight", "routines": self = .daily
            case "writing", "write", "autocomplete": self = .writing
            case "dictation": self = .dictation
            case "models": self = .models
            case "agents", "externalagents", "external agents", "agent-access": self = .agents
            case "devices", "phones", "tablets", "phones & tablets", "companion": self = .devices
            case "privacy", "permissions": self = .privacy
            case "advanced", "diagnostics": self = .advanced
            default: return nil
            }
        }
    }

    nonisolated static var isUITesting: Bool { UITestRuntime.isEnabled }
    nonisolated static var runsBackgroundWorkInUITests: Bool {
#if LOKALBOT_TEST_HOOKS
        TestHooks.backgroundHostEnabled
#else
        false
#endif
    }
    nonisolated static var isUnitTesting: Bool { UITestRuntime.isUnitTesting }

    nonisolated static let onboardingShownKey = "lokalbotv3.onboarding.shown"

    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var importingRecordings: [String] = []
    private var recordingImportTask: Task<Void, Never>?
    @Published var lastError: String?
    @Published var textRecognitionStalled = false
    @Published var micRecoveryNeeded = false
    @Published private(set) var dayMemoryPaused = false

    let settingsStore = SettingsStore()

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settingsStore.current = settings
            if settings.appTheme != oldValue.appTheme {
                AppAppearance.apply(theme: settings.appTheme)
            }
            if settings.textSize != oldValue.textSize {
                AppAppearance.apply(textSize: settings.textSize)
            }
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
            detector.detectOtherBrowserCalls = settings.detectOtherBrowserCalls
            detector.additionalCallBundleIDs = settings.additionalCallBundleIDs
            if oldValue.semanticSearchEnabled, !settings.semanticSearchEnabled {
                cachedEmbeddingIndex?.stopScreenBackfill()
            }
            if settings.fileSearchEnabled != oldValue.fileSearchEnabled
                || settings.fileSearchFolders != oldValue.fileSearchFolders
                || settings.fileSearchIncludesMedia != oldValue.fileSearchIncludesMedia
                || settings.fileSearchReadsOnBattery != oldValue.fileSearchReadsOnBattery {
                applyFileSearchSetting()
            }
            if settings.semanticSearchEnabled != oldValue.semanticSearchEnabled
                || settings.effectiveScreenContextCaptureMode != oldValue.effectiveScreenContextCaptureMode {
                applyScreenImageSetting()
            }
            if interactive {
                if Self.dictationLifecycleChanged(from: oldValue, to: settings) {
                    dictation.applySettings()
                }
                if Self.cotypingLifecycleChanged(from: oldValue, to: settings) {
                    cotyping.applySettings()
                    if oldValue.cotypingEnabled && !settings.cotypingEnabled {
                        scheduleCotypingRuntimeUnload()
                    }
                }
                if Self.cotypingRuntimeChanged(from: oldValue, to: settings) {
                    scheduleCotypingPrewarm()
                }
                if settings.quickRecallEnabled != oldValue.quickRecallEnabled
                    || settings.quickRecallShortcut != oldValue.quickRecallShortcut {
                    applyQuickRecallSetting(replacing: oldValue.quickRecallShortcut)
                }
                if settings.selectionActionsEnabled != oldValue.selectionActionsEnabled
                    || settings.selectionActionsShortcut != oldValue.selectionActionsShortcut {
                    applySelectionActionsSetting(replacing: oldValue.selectionActionsShortcut)
                }
                if settings.windowHandoffEnabled != oldValue.windowHandoffEnabled
                    || settings.windowHandoffShortcut != oldValue.windowHandoffShortcut {
                    applyWindowHandoffSetting(replacing: oldValue.windowHandoffShortcut)
                }
                if Self.dailyMemoryExportChanged(from: oldValue, to: settings) {
                    applyDailyMemoryExportSetting()
                }
                if Self.meetingNoteExportChanged(from: oldValue, to: settings) {
                    applyMeetingNoteExportSetting()
                }
                if Self.dayDigestChanged(from: oldValue, to: settings) {
                    applyDayDigestSetting()
                }
                if Self.codingAgentEvidenceChanged(from: oldValue, to: settings) {
                    applyCodingAgentEvidenceSetting()
                }
                if AgentMemoryIngestor.Configuration(settings: oldValue)
                    != AgentMemoryIngestor.Configuration(settings: settings) {
                    applyCodingAgentNotesSetting()
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
                if settings.learnsFromDictation != oldValue.learnsFromDictation {
                    applyDictationLearningSetting()
                }
                if Self.companionChanged(from: oldValue, to: settings) {
                    applyCompanionSetting()
                }
                let approved = Set(settings.approvedRemoteInferenceOrigins)
                if !Set(oldValue.approvedRemoteInferenceOrigins).isSubset(of: approved) {
                    agentSessions.remoteApprovalsDidChange()
                }
            }
        }
    }

    static func dictationLifecycleChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        old.dictationEnabled != new.dictationEnabled
            || old.dictationShowOverlay != new.dictationShowOverlay
            || old.dictationLivePreview != new.dictationLivePreview
            || !DictationGrounding.permissionsMatch(old, new)
    }

    static func cotypingLifecycleChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        old.cotypingEnabled != new.cotypingEnabled
            || old.cotypingExcludedApps != new.cotypingExcludedApps
            || old.cotypingExcludedDomains != new.cotypingExcludedDomains
            || old.cotypingUseVisibleContext != new.cotypingUseVisibleContext
            || old.cotypingUseWindowText != new.cotypingUseWindowText
            || old.excludedApps != new.excludedApps
            || old.excludedScreenDomains != new.excludedScreenDomains
            || old.cotypingUseMeetingMemory != new.cotypingUseMeetingMemory
            || old.cotypingUseScreenMemory != new.cotypingUseScreenMemory
            || old.cotypingPauseInLowPowerMode != new.cotypingPauseInLowPowerMode
    }

    private static func cotypingRuntimeChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        guard new.cotypingEnabled else { return false }
        return !old.cotypingEnabled
            || old.cotypingBuiltInModelID != new.cotypingBuiltInModelID
            || old.cotypingInProcessRuntime != new.cotypingInProcessRuntime
            || old.customBuiltInModels != new.customBuiltInModels
            || old.cotypingBackend != new.cotypingBackend
    }

    private static func dailyMemoryExportChanged(from old: AppSettings,
                                                 to new: AppSettings) -> Bool {
        old.dailyMemoryExportEnabled != new.dailyMemoryExportEnabled
            || old.dailyMemoryExportFolder != new.dailyMemoryExportFolder
            || old.dailyMemoryExportFormat != new.dailyMemoryExportFormat
            || old.dailyMemoryExportHour != new.dailyMemoryExportHour
    }

    private static func meetingNoteExportChanged(from old: AppSettings,
                                                 to new: AppSettings) -> Bool {
        old.meetingNoteExportEnabled != new.meetingNoteExportEnabled
            || old.meetingNoteExportFolder != new.meetingNoteExportFolder
            || old.meetingNoteExportFormat != new.meetingNoteExportFormat
            || old.meetingNoteExportIncludesTranscript != new.meetingNoteExportIncludesTranscript
    }

    private static func dayDigestChanged(from old: AppSettings,
                                         to new: AppSettings) -> Bool {
        old.dayDigestAutoEnabled != new.dayDigestAutoEnabled
            || old.dayDigestHour != new.dayDigestHour
            || automaticInferenceChanged(from: old, to: new)
    }

    private static func codingAgentEvidenceChanged(from old: AppSettings,
                                                   to new: AppSettings) -> Bool {
        CodingAgentEvidenceIngestor.Configuration(settings: old)
            != CodingAgentEvidenceIngestor.Configuration(settings: new)
    }

    private static func screenContextChanged(from old: AppSettings,
                                             to new: AppSettings) -> Bool {
        old.trackingEnabled != new.trackingEnabled
            || old.effectiveScreenContextCaptureMode != new.effectiveScreenContextCaptureMode
            || old.screenshotIntervalMinutes != new.screenshotIntervalMinutes
            || old.meetingVisualContextEnabled != new.meetingVisualContextEnabled
            || old.excludedApps != new.excludedApps
            || old.excludedScreenDomains != new.excludedScreenDomains
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
            || automaticInferenceChanged(from: old, to: new)
    }

    private static func automaticInferenceChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        old.summarizerBackend != new.summarizerBackend
            || old.openAIBaseURL != new.openAIBaseURL || old.ollamaBaseURL != new.ollamaBaseURL
            || old.approvedRemoteInferenceOrigins != new.approvedRemoteInferenceOrigins
    }

    @Published var navSection: NavSection = .today
    var meetingNoteDrafts: [UUID: String] = [:]
    @Published var actionSelection: Set<String> = []
    let recall = RecallWorkspace()
    var recallQuery: String {
        get { recall.query }
        set { recall.query = newValue }
    }
    var recallState: RecallWorkspaceState {
        get { recall.state }
        set { recall.state = newValue }
    }
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
    func openActions() { navSection = .actions }
    func openToday() { navSection = .today }

    @Published var selectedPersonID: String?
    @Published var selectedProjectID: String?
    private(set) lazy var connections = WorkMemoryConnections()
    private(set) lazy var projectStore = ProjectStore(
        directory: storage.rootURL.appendingPathComponent("projects", isDirectory: true))
    private(set) lazy var peopleStore = PeopleStore(
        directory: storage.rootURL.appendingPathComponent(PeopleCuration.directoryName, isDirectory: true))

    @Published var followUpDraftMeeting: Meeting?
    @Published var followThroughSession: FollowThroughSession?
    @Published var showsSampleSetup = false
    var sampleMeetingWaitsForModels = false

    func draftFollowUp(for meeting: Meeting) {
        followUpDraftMeeting = meeting
    }

    var latestMeetingWithOutcomes: Meeting? {
        outcomeIndex.all.first { !$0.isArchived && $0.meeting.endedAt != nil }?.meeting
    }

    func openPerson(_ id: String) {
        selectedPersonID = id
        navSection = .people
    }

    func openProject(_ id: String) {
        selectedProjectID = id
        navSection = .projects
    }

    @Published private(set) var actionCompletionHints: [String: ActionCompletionHint] = [:]
    private var completionHintTask: Task<Void, Never>?
    private static let dismissedCompletionHintsKey = "actions.dismissedCompletionHints"
    private static let maximumDismissedCompletionHints = 500

    func refreshActionCompletionHints() {
        guard settings.suggestActionCompletion,
              settings.effectiveScreenContextCaptureMode.capturesText else {
            completionHintTask?.cancel()
            if !actionCompletionHints.isEmpty { actionCompletionHints = [:] }
            return
        }
        let threads = outcomeIndex.openUserActionThreads
        let databaseURL = activityStore.databaseURL
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedCompletionHintsKey) ?? [])
        completionHintTask?.cancel()
        completionHintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let hints = await Task.detached(priority: .utility) {
                ActionCompletionDetector.hints(
                    for: threads, store: ActivityStore(databaseURL: databaseURL, readOnly: true),
                    dismissed: dismissed)
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.actionCompletionHints != hints { self.actionCompletionHints = hints }
        }
    }

    func dismissActionCompletionHint(_ hint: ActionCompletionHint) {
        var dismissed = UserDefaults.standard.stringArray(forKey: Self.dismissedCompletionHintsKey) ?? []
        dismissed.append(hint.dismissalKey)
        UserDefaults.standard.set(Array(dismissed.suffix(Self.maximumDismissedCompletionHints)),
                                  forKey: Self.dismissedCompletionHintsKey)
        actionCompletionHints[hint.threadID] = nil
    }

    func refreshConnections() {
        let library = meetings.filter(\.isOwnWork)
        if libraryReady { projectStore.withdrawSummaries(missingFrom: Set(meetings.map(\.id))) }
        let libraryIDs = Set(library.map(\.id))
        connections.refresh(.init(
            meetings: library,
            projections: outcomeIndex.all.filter { libraryIDs.contains($0.id) },
            memory: dreamMemory,
            curation: projectStore.curation,
            peopleCuration: peopleStore.curation,
            root: storage.rootURL,
            activityDatabaseURL: activityStore.databaseURL))
    }

    func writeProjectSummary(for project: ProjectProfile, automatic: Bool) {
        guard project.isTracked else { return }
        if automatic {
            guard writesProjectSummariesAutomatically, projectStore.shouldWriteAutomatically(project) else { return }
        }
        let provenance = DreamInferenceProvenance(settings: settings)
        let location: String
        if provenance.location == .local {
            location = ProjectStatusSummary.localLocation
        } else {
            location = provenance.origin.flatMap { URL(string: $0)?.host } ?? provenance.origin ?? "a server"
        }
        projectStore.startWritingSummary(for: project, automatic: automatic, location: location) { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            if automatic && !self.settings.allowsAutomaticMainInference { throw CancellationError() }
            return try await self.thinkExecution.makeTextEngine(
                self.settings, priority: automatic ? .background : .interactive, purpose: "project summary")
        }
    }

    var writesProjectSummariesAutomatically: Bool {
        settings.allowsAutomaticMainInference && ModelReadinessSnapshot.thinkReady(settings, storage: storage)
    }
    private static var navigationDefaults: UserDefaults {
        if let suite = UITestRuntime.defaultsSuiteName,
           let defaults = UserDefaults(suiteName: suite) {
            return defaults
        }
        return .standard
    }
    private static let settingsTabDefaultsKey = "lokalbotv4.settings.selectedPage"
    @Published var settingsTab: SettingsTab = .overview {
        didSet { Self.navigationDefaults.set(settingsTab.rawValue, forKey: Self.settingsTabDefaultsKey) }
    }
    @Published var focusedSettingID: String?
    @Published var askMode: AskMode = .ask
    @Published var selectedMeetingIDs: Set<Meeting.ID> = []
    @Published private(set) var presentedMeetingSearchID: Meeting.ID?
    @Published private(set) var meetingPageSearchRequestRevision = 0

    @Published var askDateScope: AskDateScope?
    var askDayScope: Date? {
        get {
            guard let scope = askDateScope, scope.firstDay == scope.lastDay else { return nil }
            return AskDayScope.date(for: scope.firstDay)
        }
        set { askDateScope = newValue.map { AskDateScope(day: $0) } }
    }
    private(set) lazy var navigationHandoff = NavigationHandoff()

    func openType(_ tab: TypeTab) {
        openSettings(tab: tab == .cotyping ? .writing : .dictation)
        focusedSettingID = tab == .cotyping ? "settings.autocompletePreview" : "settings.dictationPreview"
    }

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { selectSettingsTab(tab) } else if focusedSettingID != nil { focusedSettingID = nil }
        WindowAccess.shared.open(WindowAccess.settingsID)
    }

    func selectSettingsTab(_ tab: SettingsTab) {
        if settingsTab != tab { settingsTab = tab }
        if focusedSettingID != nil { focusedSettingID = nil }
    }

    func openAsk(query: String = "", dayScope: Date? = nil,
                 screenSnapshotIDs: [Int64]? = nil, submit: Bool = false,
                 meetingIDs: Set<Meeting.ID>? = nil, mode: AskMode = .ask,
                 sources: Set<AskSourceScope>? = nil) {
        navigationHandoff.stageAsk(
            query: query,
            dayScope: dayScope,
            screenSnapshotIDs: screenSnapshotIDs,
            submit: submit, meetingIDs: meetingIDs, mode: mode, sources: sources)
        navSection = .ask
    }

    func openAgent(_ context: AgentLaunchContext? = nil) {
        navigationHandoff.stageAgent(context)
        if let prompt = context?.prompt {
            agentSessions.ensureSelectedController().draft = prompt
        }
        navSection = .agent
    }

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

    var selectedMeeting: Meeting? {
        guard selectedMeetingIDs.count == 1, let id = selectedMeetingIDs.first else { return nil }
        if let live = currentMeeting, live.id == id { return live }
        return meetings.first { $0.id == id }
    }

    let storage = StorageManager()
    private(set) lazy var outcomeIndex = OutcomeIndex(
        storage: storage,
        mutateEvidence: { [weak self] meetings, mutation in
            guard let self else { throw CancellationError() }
            try self.withPrimaryEvidenceChange(for: meetings, .revision, mutation)
        },
        onEvidenceChanged: { [weak self] meetings in
            for meeting in meetings { self?.reindexSearchInBackground(meeting) }
        },
        onWorkflowStateChanged: { [weak self] meetings in
            self?.actionWorkflowStateDidChange(for: meetings)
        })
    private(set) lazy var cotypingLearning = CotypingLearningStore(storageRoot: storage.rootURL)
    let detector = MeetingDetector()
    let audioMonitor = AudioSourceMonitor()
    private(set) lazy var agentAccess = AgentAccessManager(
        storage: storage,
        settings: { [weak self] in self?.settings ?? AppSettings.load() },
        onError: { [weak self] message in self?.lastError = message })
    private(set) lazy var screenMemoryAccess = ScreenMemoryAccessManager(
        gate: ScreenMemoryAccessGate(root: storage.rootURL))
    private(set) lazy var personalContextAccess = PersonalContextAccessManager(
        gate: PersonalContextAccessGate(root: storage.rootURL),
        claims: { [weak self] in self?.personalModel.readableClaims() })
    private(set) lazy var filesAccess = FilesAccessManager(
        gate: FilesAccessGate(root: storage.rootURL),
        folders: { [weak self] in
            guard let self, self.settings.fileSearchEnabled else { return nil }
            return self.settings.fileSearchFolders
        })
    private(set) lazy var agentNotesAccess = AgentNotesAccessManager(
        gate: AgentNotesAccessGate(root: storage.rootURL))
    private(set) lazy var agentReadAccess = AgentReadAccess(
        meetings: agentAccess, screenMemory: screenMemoryAccess, personalContext: personalContextAccess,
        files: filesAccess, agentNotes: agentNotesAccess, root: storage.rootURL)
    private(set) lazy var settingsControl = SettingsControlAccessManager(
        gate: SettingsControlGate(root: storage.rootURL),
        makeHandler: { [weak self] in
            guard let self else { return { _, _ in .failure(.appNotRunning("LokalBot is shutting down.")) } }
            let handler = AppControlHandler(app: self, gate: SettingsControlGate(root: self.storage.rootURL))
            return { request, peer in await handler.handle(request, from: peer) }
        },
        onError: { [weak self] message in self?.lastError = message },
        onDisable: { [weak self] in self?.settingsApprovals.denyAll() })
    private(set) lazy var agentSettingsChanges = AgentSettingsChanges(root: storage.rootURL)
    private(set) lazy var settingsApprovals = SettingsApprovals()
    private(set) lazy var agentSetup = AgentSetupRequests(
        controlDirectory: SettingsControlGate(root: storage.rootURL).controlDirectory)
    var agentSecrets = AgentSecretStore.keychain
    private(set) lazy var quickRecallHotKey: QuickRecallHotKeyController = {
        let controller = QuickRecallHotKeyController()
        controller.onInvoke = { [weak self] in self?.openQuickRecall() }
        return controller
    }()
    var shortcutSourceApplication: NSRunningApplication?
    @Published var quickRecallOpenedFromMainWindow = false
    private(set) lazy var selectionActionsHotKey: QuickRecallHotKeyController = {
        let controller = QuickRecallHotKeyController(
            identifier: QuickRecallHotKeyController.selectionActionsIdentifier)
        controller.onInvoke = { [weak self] in self?.selectionActions.invoke() }
        return controller
    }()
    private(set) lazy var selectionActions = SelectionActionsController(dependencies: .init(
        capture: { [weak self] in
            await SelectionCapture.capture(excludedApps: self?.settings.excludedAppList ?? [])
        },
        makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.thinkExecution.makeTextEngine(
                self.settings, priority: .interactive, purpose: "selection action")
        },
        memory: { [weak self] query in
            await self?.selectionMemoryContext(query: query) ?? .empty
        },
        deliver: { text, capture in
            await SelectionDelivery.deliver(text, capture: capture)
        },
        copy: { text in SelectionDelivery.copy(text) },
        returnFocus: { source in
            guard let application = NSRunningApplication(processIdentifier: source.processID) else { return }
            Task { await FocusReturn.activate(application) }
        },
        openPanel: { WindowAccess.shared.open("selection-actions") },
        report: { [weak self] message in self?.lastError = message }))
    private(set) lazy var windowHandoffHotKey: QuickRecallHotKeyController = {
        let controller = QuickRecallHotKeyController(
            identifier: QuickRecallHotKeyController.windowHandoffIdentifier)
        controller.onInvoke = { [weak self] in self?.windowHandoff.invoke() }
        return controller
    }()
    private(set) lazy var windowHandoff = WindowHandoffController(dependencies: .init(
        capture: { [weak self] in
            guard let self else { return WindowHandoffCapture(issue: .unreadable) }
            return await WindowHandoffCapturer.capture(
                excludedApps: self.settings.excludedAppList,
                excludedDomains: self.settings.excludedScreenDomainList)
        },
        makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.thinkExecution.makeTextEngine(
                self.settings, priority: .interactive, purpose: "hand off")
        },
        targets: { WindowHandoffTarget.availableOnThisMac },
        writePackage: { [weak self] capture, brief in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            return try WindowHandoffPackage.write(capture, brief: brief, library: self.storage.rootURL)
        },
        deliver: { [weak self] package, target in
            guard let self else { return "LokalBot is shutting down." }
            return self.deliverWindowHandoff(package, to: target)
        },
        returnFocus: { source in
            guard let application = NSRunningApplication(processIdentifier: source.processID) else { return }
            Task { await FocusReturn.activate(application) }
        },
        openPanel: { WindowAccess.shared.open("window-handoff") },
        closePanel: { WindowAccess.shared.close("window-handoff") }))
    private let dailyMemoryExportScheduler = DailyMemoryExportScheduler()
    private lazy var meetingNoteExport = MeetingNoteExportScheduler(
        canRun: { [weak self] in self?.pipeline.hasActiveWork == false })
    private var meetingNoteCurationObserver: AnyCancellable?
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
    @Published var latestDreamReport: DreamReport?
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
    let calendar = EventKitCalendarEventProvider()
    private(set) lazy var email: EmailController = {
        let controller = EmailController(root: storage.rootURL)
        controller.attendeeAddresses = { [weak self] in self?.emailAttendeeAddresses() ?? [] }
        controller.nextMeetingStart = { [weak self] in self?.nextMeetingWithAttendeesStart() }
        controller.canSync = { [weak self] in self?.libraryReady == true }
        return controller
    }()
    private(set) lazy var fileSearch: FileSearchService = {
        let service = FileSearchService.live(storage: storage)
        service.isRecording = { [weak self] in
            guard let self else { return false }
            return self.recording.isRecording || self.recording.isStarting
        }
        service.transcribeMoment = { [weak self] hit in await self?.fileMoments.passage(for: hit) }
        return service
    }()
    private(set) lazy var fileMoments = FileMomentTranscriber.live(
        settings: { [weak self] in self?.settings ?? AppSettings() },
        isRecording: { [weak self] in
            guard let self else { return true }
            return self.recording.isRecording || self.recording.isStarting
        })
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
            storage: storage,
            embedder: UITestRuntime.isUnitTesting ? EmbeddingIndex.unavailableEmbedder : nil)
        for meetingID in excludedMeetingIDs { created.noteDeletion(meetingID) }
        created.screenSearchByMeaningDidStart = { [weak self] in
            guard let self, self.screenImagesWanted else { return }
            self.screenImages.resume()
        }
        cachedEmbeddingIndex = created
        return created
    }

    private var cachedScreenImages: ScreenImageEmbeddings?
    var screenImages: ScreenImageEmbeddings {
        if let cachedScreenImages { return cachedScreenImages }
        let created = ScreenImageEmbeddings.live(
            storage: storage, databaseURL: storage.rootURL.appendingPathComponent("lokalbotv3.sqlite"))
        created.isEnabled = { [weak self] in self?.screenImagesWanted ?? false }
        created.isInUse = { [weak self] in self?.embeddingIndex.isScreenSearchInUse ?? false }
        created.pauseReason = { [weak self] in
            guard let self else { return nil }
            return FileSearchService.PauseReason.current(
                isRecording: self.recording.isRecording || self.recording.isStarting)
        }
        cachedScreenImages = created
        return created
    }

    private var screenImagesWanted: Bool {
        settings.semanticSearchEnabled && settings.effectiveScreenContextCaptureMode.capturesPixels
            && !UITestRuntime.isUnitTesting && !Self.isUITesting && HeadlessCommand.requested == nil
    }

    private func applyScreenImageSetting() {
        if screenImagesWanted {
            screenImages.conditionsDidChange()
        } else {
            cachedScreenImages?.stop()
        }
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
    private(set) lazy var thinkExecution = ThinkExecution(storage: storage)
    private(set) lazy var speakerIdentity = MeetingSpeakerIdentityService(
        storage: storage, settings: { [store = settingsStore] in store.current })
    private(set) lazy var pipeline = ProcessingPipeline(
        storage: storage,
        jobStore: pipelineJobStore,
        settings: { [store = settingsStore] in store.current },
        thinkExecution: thinkExecution,
        speakerIdentity: speakerIdentity,
        automationReadiness: ProcessingPipeline.defaultAutomationReadiness)
    private(set) lazy var githubStar = GitHubStarPromptStore.live(libraryRoot: storage.rootURL)
    private(set) lazy var modelRoles = ModelRoles(
        settings: { [store = settingsStore] in store.current },
        storage: storage,
        onReadinessChanged: { [weak self] in
            self?.processMeetingsWaitingForModels()
            self?.openWaitingSampleMeeting()
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
            if let transcription = patch.transcriptionToPrepare {
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
    private(set) lazy var dayDigest = DayDigestLifecycle(
        storage: storage,
        activityStore: activityStore,
        pipeline: pipeline,
        meetings: { [weak self] in
            guard let self else { return [] }
            return (self.currentMeeting.map { [$0] } ?? []) + self.meetings
        },
        settings: { [store = settingsStore] in store.current },
        prepareEvidence: { [weak self] day in await self?.codingAgentEvidence.refresh(including: day) },
        onGenerated: { [weak self] day in self?.dayDigestDidChange(on: day) })
    private(set) lazy var codingAgentEvidence = CodingAgentEvidenceIngestor(
        store: activityStore,
        configuration: { [store = settingsStore] in AppState.codingAgentConfiguration(store.current) },
        mutateEvidence: { [weak self] days, mutation in
            try self?.withPrimaryEvidenceChange(on: days, .revision, mutation)
        },
        onChange: { [weak self] days in self?.codingAgentEvidenceDidChange(on: days) },
        waitUntilReady: { [weak self] in await self?.waitForLibrary() })
    private(set) lazy var agentNotes = AgentMemoryIngestor(
        store: AgentMemoryStore(root: storage.rootURL),
        configuration: { [store = settingsStore] in AgentMemoryIngestor.Configuration(settings: store.current) },
        waitUntilReady: { [weak self] in await self?.waitForLibrary() })
    var agentNotesIndex: AgentNotesIndex { AgentNotesIndex(root: storage.rootURL) }
    private(set) lazy var recording = RecordingController(
        storage: storage,
        settingsStore: settingsStore,
        audioMonitor: audioMonitor,
        pipeline: pipeline,
        isInteractive: { [weak self] in self?.interactive ?? false },
        onError: { [weak self] message in
            guard let message else {
                if self?.lastError == RecordingController.silentSystemAudioMessage {
                    self?.lastError = nil
                }
                return
            }
            self?.lastError = message
        },
        onMicPermissionDenied: { [weak self] in self?.micRecoveryNeeded = true },
        onMeetingFinished: { [weak self] meeting in self?.meetings.insert(meeting, at: 0) })
    private(set) lazy var dictation = DictationCoordinator(
        storageRoot: storage.rootURL,
        settingsStore: settingsStore,
        settingsProvider: { [weak self, store = settingsStore] in
            self?.dictationTranscriptionSettings(store.current) ?? store.current
        },
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
        }, onDictatedForLearning: { [weak self] spokenText, appName in
            self?.keepDictationForLearning(spokenText, appName: appName)
        }, memoryContextProvider: { [weak self] field, settings in
            guard let self, self.libraryReady else { return .empty }
            let root = self.storage.rootURL
            let meetings = self.meetings
            let task = Task.detached(priority: .userInitiated) {
                CotypingMemoryContextProvider.load(root: root, meetings: meetings, field: field,
                                                   settings: settings, allowBodyMatch: false)
            }
            return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        })
    private(set) lazy var cotypingServer = RemoteCotypingEngine(
        route: { [store = settingsStore] in store.current.cotypingRoute() })
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
        server: cotypingServer,
        makeLocal: { modelPath in
            LocalLlamaCotypingEngine(runtime: .forAutocomplete(), modelPath: modelPath)
        },
        settings: { [store = settingsStore] in store.current },
        storage: storage)
    private(set) lazy var cotyping = CotypingCoordinator(
        engine: cotypingEngine,
        settingsProvider: { [store = settingsStore] in store.current },
        learningStore: cotypingLearning,
        memoryContextProvider: { [weak self] field, settings in
            guard let self, self.libraryReady,
                  CotypingMemoryContext.Policy(settings: settings).enabled else { return .empty }
            let root = self.storage.rootURL
            let meetings = self.meetings
            let task = Task.detached(priority: .userInitiated) {
                CotypingMemoryContextProvider.load(root: root, meetings: meetings, field: field, settings: settings)
            }
            return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        },
        isMeetingRecordingActive: { [weak self] in
            guard let self else { return false }
            return self.recording.isRecording || self.recording.isStarting
        })
    private(set) lazy var liveTranscriber = LiveMeetingTranscriber(
        storageRoot: storage.rootURL,
        settings: { [store = settingsStore] in store.current })
    private(set) lazy var meetingRadar: MeetingRadar = {
        let settings: () -> AppSettings = { [store = settingsStore] in store.current }
        let evidence = LibraryRadarEvidenceSource(
            meetings: { [weak self] in self?.meetings ?? [] },
            searchIndex: searchIndex,
            embeddingIndex: embeddingIndex,
            settings: settings)
        let screens = Self.radarScreenSource(store: activityStore)
        let answers = AppLiveAnswerEnvironment(app: self)
#if LOKALBOT_UI_TEST_HOST
        if MuseUITestTransport.isEnabled {
            return MeetingRadar(
                transcriber: liveTranscriber, evidenceSource: evidence, screenSource: screens,
                answerEnvironment: answers, answerCall: MuseUITestTransport.answerCall(settings: settings),
                settings: settings, call: MuseUITestTransport.radarCall(settings: settings),
                modelName: { _ in MetaModelAPI.museSpark.id }, sendsScreenCrops: true)
        }
#endif
        return MeetingRadar(
            transcriber: liveTranscriber, evidenceSource: evidence, screenSource: screens,
            answerEnvironment: answers, settings: settings,
            engine: { [weak self] purpose in
                guard let self else { throw CancellationError() }
                return try await self.thinkExecution.makeTextEngine(
                    self.settings, priority: .interactive, purpose: purpose)
            })
    }()

    private(set) lazy var liveRadarPanel = LiveRadarPanelController(app: self)

    func startLiveRadar(for meeting: Meeting) {
        meetingRadar.start(meeting: meeting, folder: meeting.folderURL(in: storage))
        if meetingRadar.isActive, settings.liveRadarPanelEnabled { liveRadarPanel.show() }
#if LOKALBOT_UI_TEST_HOST
        if meetingRadar.isActive { FilmCall.show(app: self, title: meeting.displayTitle) }
#endif
    }

    private static func radarScreenSource(store: ActivityStore) -> RadarScreenSource {
#if LOKALBOT_UI_TEST_HOST
        if let path = ProcessInfo.processInfo.environment["LOKALBOT_UI_TEST_SCREENS"],
           let screens = try? MeetingRadarReplay.FixtureScreens(folder: URL(fileURLWithPath: path, isDirectory: true)) {
            return screens
        }
#endif
        return LibraryRadarScreenSource(store: store)
    }

    @MainActor
    func prepareRecommendedCotypingModel() {
        CotypingModelPreparer.prepareRecommended(
            settings: &settings,
            storage: storage,
            downloads: ModelDownloadManager.shared)
    }

    private(set) lazy var libraryTools = MeetingChatTools(
        meetings: { [weak self] in self?.meetings ?? [] },
        storage: storage,
        searchIndex: searchIndex,
        embeddingIndex: embeddingIndex,
        activityStore: activityStore,
        settings: { [store = settingsStore] in store.current },
        files: { [weak self] in
            guard let self, self.settings.fileSearchEnabled, self.fileSearch.isAvailable else { return nil }
            return self.fileSearch
        },
        agentNotes: { [weak self] in
            guard let self, self.settings.codingAgentNotesEnabled, self.agentNotesIndex.exists else { return nil }
            return self.agentNotesIndex
        })

    private(set) lazy var chat = ChatViewModel(
        makeEngine: { [weak self] in
            guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
            return try await self.thinkExecution.makeTextEngine(
                self.settings,
                priority: .interactive,
                purpose: "chat")
        },
        tools: libraryTools,
        store: ChatStore(rootURL: storage.rootURL),
        workMemory: { [weak self] in
            guard let self else { return "" }
            return ChatPrompt.workMemoryContext(
                memory: (try? self.dreamStore.loadMemory()) ?? nil,
                dreamingEnabled: self.settings.dreamingEnabled)
        },
        personalModel: personalModel,
        askMemoryEnabled: { [weak self] in self?.settings.askMemoryEnabled ?? false },
        deferHistoryLoading: true)

    private var companionHost: CompanionHost?
    private var companionCurationObserver: AnyCancellable?

    var companion: CompanionHost {
        if let companionHost { return companionHost }
        let host = CompanionHost(
            root: storage.rootURL,
            activityDatabaseURL: activityStore.databaseURL,
            factory: CompanionServerFactory.live,
            opApplier: CompanionOpApplier(outcomes: outcomeIndex, meetings: { [weak self] in self?.meetings ?? [] }),
            askResponder: CompanionAskResponder(dependencies: .init(
                settings: { [store = settingsStore] in store.current },
                makeEngine: { [weak self] in
                    guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
                    return try await self.thinkExecution.makeTextEngine(
                        self.settings, priority: .interactive, purpose: "companion ask")
                },
                tools: { [unowned self] in self.libraryTools },
                meetings: { [weak self] in self?.meetings ?? [] })),
            recordingReceiver: CompanionRecordingReceiver(dependencies: .init(
                meetingExists: { [weak self] id in
                    guard let self else { return false }
                    if self.meetings.contains(where: { $0.id == id }) { return true }
                    let root = self.storage.rootURL
                    return await Task.detached {
                        let all = try? SessionLookup.loadAllMeetings(root: root, includeMergedSources: true)
                        return all?.contains { $0.id == id } == true
                    }.value
                },
                language: { [weak self] in self?.settings.appLanguage ?? .system },
                importRecording: { [weak self] url, origin in
                    guard let self else { throw CancellationError() }
                    return try await MeetingImportService.importDeviceRecording(
                        from: url, origin: origin, storage: self.storage)
                },
                didImport: { [weak self] meeting in self?.addDeviceRecording(meeting) })),
            language: { [weak self] in self?.settings.appLanguage ?? .system })
        companionHost = host
        return host
    }

    func applyCompanionSetting() {
        guard interactive, libraryReady else { return }
        guard settings.companionSharingEnabled else {
            companionHost?.stop()
            companionCurationObserver = nil
            CompanionHost.discardUploads(root: storage.rootURL)
            return
        }
        let host = companion
        host.apply(settings.companionSharing)
        if companionCurationObserver == nil {
            companionCurationObserver = Publishers.Merge3(
                projectStore.$curation.dropFirst().map { _ in () },
                projectStore.$summaries.dropFirst().map { _ in () },
                peopleStore.$curation.dropFirst().map { _ in () }
            ).sink { [weak host] in host?.connectionsChanged() }
        }
    }

    static func companionChanged(from old: AppSettings, to new: AppSettings) -> Bool {
        old.companionSharing != new.companionSharing
    }

    private(set) lazy var dictationLearningLog = DictationLearningLog(root: storage.rootURL)

    private(set) lazy var personalModel: PersonalModelController = {
        let controller = PersonalModelController(
            store: PersonalModelStore(root: storage.rootURL),
            evidenceCheck: { [weak self] in self?.dreamStore.evidenceCheck() },
            sourceStillQuotes: { [weak self] claim in self?.learnedClaimSourceStillQuotes(claim) ?? false },
            currentRevision: { [weak self] in try? self?.dreamStore.evidenceRevision() })
        controller.onChange = { [weak self] claims in
            self?.personalContextAccess.refresh(claims)
        }
        return controller
    }()

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
    private var dayMemoryPauseObserver: AnyCancellable?
    private var recordingStatusObserver: AnyCancellable?
    private var audioMonitorObserver: AnyCancellable?
    private var audioMonitorChangeForwarder: AnyCancellable?
    private var calendarObserver: AnyCancellable?
    private var modelRolesObserver: AnyCancellable?
    private var navigationHandoffObserver: AnyCancellable?
    private var interactive = false
    var isInteractiveLaunch: Bool { interactive }
    private var terminationCleanupTask: Task<Bool, Never>?
    private var cotypingRuntimeTask: Task<Void, Never>?
    private var cotypingRuntimeTaskID: UUID?
    private var libraryLoadTask: Task<Void, Never>?
    private var embeddingBackfillTask: (token: UUID, task: Task<Void, Never>)?
    @Published private(set) var embeddingBackfill: BackgroundCount?
    let backgroundActivity = BackgroundActivityMonitor()
    private var embeddingIndexTasks: [Meeting.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var indexCleanupTasks: [Meeting.ID: (token: UUID, task: Task<Void, Never>)] = [:]
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

    var isRecording: Bool { recording.isRecording }
    var currentMeeting: Meeting? { recording.currentMeeting }

    func startRecording(
        context: MeetingDetectionContext? = nil,
        source: String = "ui",
        systemAudioPolicy: RecordingSystemAudioPolicy = .meetingAppWhenAvailable
    ) {
        RecordingNotifier.shared.invalidateMeetingDetections()
        if let sessionID = context?.detectorSessionID,
           detector.activeSessionID != sessionID { return }
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

    private func meetingRecordingStateDidChange(active: Bool) {
        guard interactive else { return }
        if settings.fileSearchEnabled { fileSearch.conditionsDidChange() }
        if screenImagesWanted { screenImages.conditionsDidChange() }
        if settings.cotypingEnabled {
            cotyping.meetingRecordingStateChanged(active: active)
        }
        if meetingRadar.meetingID != nil, meetingRadar.meetingID != recording.currentMeeting?.id {
            Task { await meetingRadar.finish() }
        }
        if active, let meeting = recording.currentMeeting {
            liveTranscriber.prepare(folder: meeting.folderURL(in: storage))
            if settings.liveRadarPanelEnabled, MeetingRadar.unavailableReason(settings) == nil {
                liveRadarPanel.show()
            }
        } else {
            liveTranscriber.stop(preservingHandoff: recording.isSplittingForCalendarHandoff)
            if !recording.isSplittingForCalendarHandoff { liveRadarPanel.hide() }
        }
    }

    func showLiveMeeting() {
#if LOKALBOT_UI_TEST_HOST
        if FilmCall.close() { return }
#endif
        guard let live = currentMeeting else { return }
        navSection = .meetings
        selectedMeetingIDs = [live.id]
        WindowAccess.shared.open("main")
    }

    init() {
        AppLog.bootstrap()
        settings = settingsStore.current
        AppAppearance.apply(textSize: settings.textSize)
        if let raw = Self.navigationDefaults.string(forKey: Self.settingsTabDefaultsKey),
           let stored = SettingsTab(rawValue: raw) {
            settingsTab = stored
        }
        if Self.isUnitTesting { return }
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
        recordingObserver = Publishers.CombineLatest(
            recording.$status,
            recording.$currentMeeting
        ).dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        recordingStatusObserver = recording.$status
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] status in
                self?.pipeline.setCaptureActive(status != .idle)
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
        modelRolesObserver = modelRoles.readinessChanges.sink { [weak self] in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.modelChecks.readinessChanged(app: self)
            }
        }
        navigationHandoffObserver = navigationHandoff.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        pipeline.onArtifactsWillChange = { [weak self] meeting in
            self?.meetingArtifactsWillChange(meeting)
        }
        pipeline.onArtifactsWritten = { [weak self] meeting in
            self?.meetingArtifactsWritten(meeting)
        }
        pipeline.onSummaryCompleted = { [weak self] meeting in
            guard !meeting.isSample else { return }
            self?.githubStar.recordSummaryCompleted()
            self?.handOffActionsAfterSummary(meeting)
        }
        if needsSynchronousLibrary {
            searchIndex.reindexAll(meetings, storage: storage)
        }
        if let command = headlessCommand {
            HeadlessCommandRunner(app: self).run(command)
            return
        }
        dayMemoryPauseObserver = sampler.$isPaused.removeDuplicates().sink { [weak self] paused in
            if self?.dayMemoryPaused != paused { self?.dayMemoryPaused = paused }
        }
        if Self.isUITesting && !Self.runsBackgroundWorkInUITests { return }
        interactive = true
        RecordingNotifier.shared.bootstrap()
        RecordingNotifier.shared.onOpenAgent = { [weak self] in
            self?.openAgent()
            WindowAccess.shared.open("main")
        }
        applyTrackingSetting()
        detector.onMeetingStarted = { [weak self] context in
            guard let self else { return }
            self.recording.considerDetectedSource(context)
            if self.settings.autoRecordMode != .manual, self.recording.joinDetectorSession(context) {
                RecordingNotifier.shared.invalidateMeetingDetections()
                return
            }
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
                guard let sessionID = context.detectorSessionID else { return }
                switch MeetingMatcher.switchAction(
                    reason: context.reason,
                    ownsRecording: self.recording.detectorSessionID == sessionID,
                    recordingActive: self.recording.isRecording || self.recording.isStarting) {
                case .split: self.recording.splitForCalendarHandoff(context)
                case .start: self.startRecording(context: context, source: "detector")
                case .ignore: break
                }
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
        detector.onMeetingEnded = { [weak self] event in
            RecordingNotifier.shared.invalidateMeetingDetections()
            guard let self else { return }
            if self.pendingRecordingStart?.context?.detectorSessionID == event.sessionID {
                self.pendingRecordingStart = nil
            }
            switch event.action(detectorSessionID: self.recording.detectorSessionID,
                                startedByUser: self.recording.startedByUser) {
            case .ignore: break
            case .stop(let allowsAutomaticRestart):
                self.recording.stop(contentEndedAt: event.contentEndedAt,
                                    allowsAutomaticRestart: allowsAutomaticRestart)
            }
        }
        detector.onBrowserObservation = { [weak self] sessionID, unavailable, lastVerifiedAt in
            self?.recording.updateCallObservation(sessionID: sessionID,
                                                  unavailable: unavailable,
                                                  lastVerifiedAt: lastVerifiedAt)
        }
        detector.onVerifiedSourceAvailable = { [weak self] context in
            guard let self else { return }
            self.recording.considerDetectedSource(context)
            if self.settings.autoRecordMode != .manual { self.recording.joinDetectorSession(context) }
        }
        detector.stopDebounce = settings.stopDebounceSeconds
        detector.calendar = calendar
        detector.calendarEnabled = settings.calendarDetectionEnabled
        detector.requireCalendarForBrowser = settings.requireCalendarForBrowser
        detector.detectOtherBrowserCalls = settings.detectOtherBrowserCalls
        detector.additionalCallBundleIDs = settings.additionalCallBundleIDs
        audioMonitor.start()
        audioMonitorObserver = audioMonitor.$detectedProcess
            .compactMap { $0 }
            .sink { [weak self] process in self?.audioMonitorDetected(process) }
        detector.start()
        AppUpdateManager.shared.start()
        agentAccess.start()
        screenMemoryAccess.start()
        personalContextAccess.start()
        filesAccess.start()
        agentNotesAccess.start()
        settingsApprovals.announce = { request in RecordingNotifier.shared.settingsApprovalRequested(request) }
        settingsApprovals.withdraw = { request in RecordingNotifier.shared.withdrawSettingsApproval(request.id) }
        settingsControl.start()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(AgentSetup.notificationName), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.showAgentSetupIfRequested() }
        }
        showAgentSetupIfRequested()
        applyQuickRecallSetting()
        applySelectionActionsSetting()
        applyWindowHandoffSetting()
        applyDailyMemoryExportSetting()
        applyMeetingNoteExportSetting()
        applyDayDigestSetting()
        applyMemoryRoutineSetting()
        applyDreamingSetting()
        applyDictationLearningSetting()
        applyHealthCheckSetting()
        if headlessCommand == nil, !Self.isUITesting { email.start() }
        bindBackgroundActivity()
        let resume = OnboardingResumeStore.live
        switch OnboardingLaunch.decision(
            finished: UserDefaults.standard.bool(forKey: Self.onboardingShownKey),
            coreGranted: PermissionManager.shared.allGranted,
            resume: resume.load(for: settings),
            agentSetupPending: agentSetup.pending != nil) {
        case .markFinished:
            UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
        case .open:
            WindowAccess.shared.open("onboarding")
        case .stayClosed(let clearsResume):
            if clearsResume { resume.clear() }
        }
        applyCodingAgentEvidenceSetting()
        applyCodingAgentNotesSetting()
        dictation.applySettings()
        cotyping.applySettings()
        if settings.cotypingEnabled { scheduleCotypingPrewarm() }
        loadLibraryInBackground()
    }

    private func loadLibraryInBackground() {
        libraryLoadTask?.cancel()
        let rootURL = storage.rootURL
        libraryLoadTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return ([Meeting](), Set<UUID>()) }
                let workerStorage = StorageManager(rootURL: rootURL)
                let loaded = workerStorage.loadMeetings()
                let restored = SearchIndex.clearStaleTombstones(
                    liveMeetingIDs: Set(loaded.map(\.id)),
                    databaseURL: rootURL.appendingPathComponent("lokalbotv3.sqlite"))
                return (loaded, restored)
            }
            let (loaded, restored) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            for meetingID in restored {
                lokalbotLog("search tombstone cleared for live meeting=\(meetingID)")
                self.cachedSearchIndex?.noteRestoration(meetingID)
                self.cachedEmbeddingIndex?.noteRestoration(meetingID)
            }

            var byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            for meeting in self.meetings { byID[meeting.id] = meeting }
            let merged = byID.values.sorted { $0.startedAt > $1.startedAt }
            self.meetings = merged
            self.libraryReady = true
            self.applyCompanionSetting()
            self.speakerIdentity.maintainRetention(meetings: { [weak self] in self?.meetings ?? [] })
            self.learnSpeakerVoices(after: .seconds(60))
            Task { await self.outcomeIndex.refreshInBackground(meetings: merged) }
            self.pipeline.resumePending(meetings: merged)
            if self.settings.autoTranscribe {
                self.pipeline.enqueueMissingTranscriptions(
                    in: merged, summarize: self.settings.autoSummarize)
            }
            self.dreaming.tick()
            self.reindexLibraryInBackground(merged)
            if self.settings.semanticSearchEnabled {
                self.reindexEmbeddingLibraryInBackground(merged)
            }
            self.applyFileSearchSetting()
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

    private func waitForLibrary() async {
        for await ready in $libraryReady.values where ready { return }
    }

    private func reindexLibraryInBackground(_ meetings: [Meeting]) {
        let worker = searchIndexWorkQueue
        Task { await worker.enqueue(meetings) }
    }

    private var notesEmbeddingDebounce: [Meeting.ID: Task<Void, Never>] = [:]

    func meetingNotesDidChange(_ meeting: Meeting) {
        reindexSearchInBackground(meeting)
        companionHost?.evidenceChanged(days: [meeting.startedAt], meetingIDs: [meeting.id])
        guard settings.semanticSearchEnabled else { return }
        notesEmbeddingDebounce[meeting.id]?.cancel()
        notesEmbeddingDebounce[meeting.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self else { return }
            self.notesEmbeddingDebounce[meeting.id] = nil
            self.reindexEmbeddingInBackground(meeting)
        }
    }

    func meetingArtifactsWritten(_ meeting: Meeting) {
        outcomeIndex.refresh(meeting: meeting)
        reindexSearchInBackground(meeting)
        if settings.semanticSearchEnabled {
            reindexEmbeddingInBackground(meeting)
        }
        primaryEvidenceDidChange(for: meeting)
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
            await self.embeddingIndex.reindexAll(meetings) { [weak self] done, total in
                guard let self, self.embeddingBackfillTask?.token == token else { return }
                self.embeddingBackfill = BackgroundCount(done: done, total: total)
            }
            guard self.embeddingBackfillTask?.token == token else { return }
            self.embeddingBackfillTask = nil
            self.embeddingBackfill = nil
            await self.embeddingIndex.resumeScreenBackfill()
            if self.screenImagesWanted { self.screenImages.resume() }
        }
        embeddingBackfillTask = (token, task)
    }

    private func screenTextDidArrive() {
        guard settings.semanticSearchEnabled else { return }
        embeddingIndex.screenTextDidArrive()
        if screenImagesWanted { screenImages.capturesDidArrive() }
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

    func prepareForTermination() async -> Bool {
        if let terminationCleanupTask {
            return await terminationCleanupTask.value
        }
        let task = Task { @MainActor in
            guard recording.prepareForTermination() else { return false }
            interactive = false
            settingsStore.flush()
            settingsControl.stop()
            companionHost?.stop()
            let pendingCotypingRuntimeTask = self.cotypingRuntimeTask
            pendingCotypingRuntimeTask?.cancel()
            await pendingCotypingRuntimeTask?.value
            self.cotypingRuntimeTask = nil
            cotypingRuntimeTaskID = nil
            libraryLoadTask?.cancel()
            libraryLoadTask = nil
            embeddingBackfillTask?.task.cancel()
            embeddingBackfillTask = nil
            embeddingBackfill = nil
            cachedEmbeddingIndex?.stopScreenBackfill()
            for entry in embeddingIndexTasks.values { entry.task.cancel() }
            embeddingIndexTasks.removeAll()
            for entry in indexCleanupTasks.values { entry.task.cancel() }
            indexCleanupTasks.removeAll()
            await searchIndexWorkQueue.stop()
            pendingRecordingStart = nil
            detector.stop()
            audioMonitor.stop()
            sampler.stop()
            screenshots.stop()
            quickRecallHotKey.stop()
            selectionActionsHotKey.stop()
            selectionActions.stop()
            windowHandoffHotKey.stop()
            windowHandoff.stop()
            dailyMemoryExportScheduler.stop()
            meetingNoteExport.stop()
            memoryRoutines.stop()
            dreaming.stop()
            email.stop()
            if settings.fileSearchEnabled { fileSearch.stop() }
            agentNotes.stop()
            cachedScreenImages?.stop()
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
            await QwenASREngine.accuracy.shutdown()
            await FileMediaEmbedderRuntime.shared.shutdown()
            return true
        }
        terminationCleanupTask = task
        let completed = await task.value
        if !completed { terminationCleanupTask = nil }
        return completed
    }

    func recordingContext(for detectedApp: MeetingDetector.DetectedApp?) -> MeetingDetectionContext? {
        guard let detectedApp = manualSource(detectedApp) else { return nil }
        let event = (settings.calendarDetectionEnabled && calendar.hasAccess)
            ? calendar.activeCandidate(now: Date()) : nil
        return MeetingDetectionContext(
            detectedApp: detectedApp,
            calendarEvent: event,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: event != nil),
            reason: "user",
            detectorSessionID: detectorSession(following: detectedApp))
    }

    private func detectorSession(following detectedApp: MeetingDetector.DetectedApp?) -> UUID? {
        guard settings.autoRecordMode != .manual, let detectedApp, detectedApp == detector.activeApp,
              detector.verifiesActiveCall else { return nil }
        return detector.activeSessionID
    }

    private func manualSource(_ detectedApp: MeetingDetector.DetectedApp?) -> MeetingDetector.DetectedApp? {
        guard var detectedApp else { return nil }
        if detectedApp == detector.activeApp, !detector.verifiesActiveCall { detectedApp.meetingURL = nil }
        return detectedApp
    }

    func recordingContext(for calendarEvent: CalendarMeetingCandidate) -> MeetingDetectionContext {
        let detectedApp = manualSource(detector.activeApp) ?? MeetingDetector.visibleBrowserMeeting()
        return MeetingDetectionContext(
            detectedApp: detectedApp,
            calendarEvent: calendarEvent,
            confidence: MeetingMatcher.confidence(
                hasApp: detectedApp != nil,
                hasCalendar: true),
            reason: "today-upcoming",
            detectorSessionID: detectorSession(following: detectedApp))
    }

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
            detector.acceptNativeAudioStart(app: detected, calendarEvent: calendarEvent)
            return
        }
        guard MeetingDetector.hostBrowserBundleID(forAudioBundleID: bundleID) != nil else { return }
        detector.checkNow()
    }

    private func notifyMeetingDetected(_ context: MeetingDetectionContext) {
        lastError = nil
        let title = MeetingMatcher.recordingTitle(
            calendarTitle: context.calendarEvent?.title,
            useCalendarTitles: settings.useCalendarTitles,
            appName: context.detectedApp?.name)
        RecordingNotifier.shared.meetingDetected(title: title, onUnavailable: { [weak self] in
            guard let self, self.settings.autoRecordMode == .ask,
                  context.detectorSessionID == self.detector.activeSessionID,
                  !self.recording.isRecording, !self.recording.isStarting else { return }
            self.lastError = "Notifications are unavailable. Choose Record now in the LokalBot menu to record \(title)."
        }) { [weak self] in
            guard let self,
                  self.settings.autoRecordMode == .ask,
                  context.detectorSessionID == self.detector.activeSessionID,
                  !self.recording.isRecording,
                  !self.recording.isStarting else { return }
            self.startRecording(context: context, source: "notification")
        }
    }

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
        defer { primaryEvidenceDidChange(for: sourceMeetings) }
        let result = try await MeetingMergeService.merge(
            meetings: sourceMeetings,
            title: title,
            storage: storage)

        let sourceIDs = Set(result.sourceMeetings.map(\.id))
        await pipeline.forget(meetingIDs: sourceIDs)
        let worker = searchIndexWorkQueue
        for sourceID in sourceIDs {
            embeddingIndexTasks.removeValue(forKey: sourceID)?.task.cancel()
            excludedMeetingIDs.insert(sourceID)
            cachedSearchIndex?.noteDeletion(sourceID)
            cachedEmbeddingIndex?.noteDeletion(sourceID)
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
        if generateSummary {
            reprocess(
                result.meeting,
                transcribe: !result.transcriptCoverageComplete,
                summarize: true)
        }
        return result.meeting
    }

    func importRecordings(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        navSection = .meetings
        importingRecordings += files.map(\.lastPathComponent)
        let previous = recordingImportTask
        recordingImportTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            var failures: [String] = []
            for url in files {
                do {
                    let meeting = try await MeetingImportService.importRecording(from: url, storage: self.storage)
                    self.meetings.append(meeting)
                    self.meetings.sort { $0.startedAt > $1.startedAt }
                    self.selectedMeetingIDs = [meeting.id]
                    lokalbotLog("recording imported meeting=\(meeting.id) extension=\(url.pathExtension.lowercased())")
                    self.reprocess(meeting, transcribe: true, summarize: self.settings.autoSummarize)
                } catch {
                    lokalbotLog("recording import failed extension=\(url.pathExtension.lowercased())")
                    failures.append(error.localizedDescription)
                }
                if let index = self.importingRecordings.firstIndex(of: url.lastPathComponent) {
                    self.importingRecordings.remove(at: index)
                }
            }
            if !failures.isEmpty { self.lastError = failures.joined(separator: "\n") }
        }
    }

    func beginRecordingImport(named name: String, _ work: @escaping @MainActor (AppState) async -> Void) {
        importingRecordings.append(name)
        let previous = recordingImportTask
        recordingImportTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
            if let index = self.importingRecordings.firstIndex(of: name) {
                self.importingRecordings.remove(at: index)
            }
        }
    }

    func appendImportedMeetings(_ added: [Meeting]) {
        guard !added.isEmpty else { return }
        meetings += added
        meetings.sort { $0.startedAt > $1.startedAt }
    }

    func addDeviceRecording(_ meeting: Meeting) {
        meetings.append(meeting)
        meetings.sort { $0.startedAt > $1.startedAt }
        lokalbotLog("device recording received meeting=\(meeting.id)")
        let queued = pipeline.enqueue(meeting, transcribe: true, summarize: settings.autoSummarize, origin: .automatic)
        switch queued {
        case .enqueued, .coalesced, .updatedActive:
            break
        case .alreadyProcessing, .persistenceFailed, .revoked:
            lokalbotLog("device recording not queued meeting=\(meeting.id) reason=\(queued)")
        }
    }

    func importSampleMeeting() {
        showsSampleSetup = false
        if let existing = sampleMeeting {
            openMeeting(existing.id)
            return
        }
        let recording = SampleMeeting.recording(for: settings.appLanguage.localizationIdentifier())
        guard !importingRecordings.contains(recording.title) else { return }
        guard let url = SampleMeeting.audioURL(for: recording) else {
            lastError = "The sample meeting is missing from this copy of LokalBot."
            return
        }
        navSection = .meetings
        importingRecordings.append(recording.title)
        let previous = recordingImportTask
        recordingImportTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let meeting = try await MeetingImportService.importRecording(
                    from: url, storage: self.storage, sample: recording)
                self.meetings.append(meeting)
                self.meetings.sort { $0.startedAt > $1.startedAt }
                self.selectedMeetingIDs = [meeting.id]
                lokalbotLog("sample meeting added meeting=\(meeting.id)")
                self.reprocess(meeting, transcribe: true, summarize: true)
            } catch {
                lokalbotLog("sample meeting import failed")
                self.lastError = error.localizedDescription
            }
            if let index = self.importingRecordings.firstIndex(of: recording.title) {
                self.importingRecordings.remove(at: index)
            }
        }
    }

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
        let sources: [Meeting]
        do {
            sources = try SessionLookup.loadAllMeetings(root: storage.rootURL, includeMergedSources: true)
                .filter { sourceIDs.contains($0.id) }
        } catch {
            lastError = "Could not read the original meetings: \(error.localizedDescription)"
            return
        }
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
                await pipeline.forget(meetingIDs: [mergedMeeting.id])
                try await speakerIdentity.prepareDeletion(meeting: mergedMeeting)
                try withPrimaryEvidenceChange(for: [mergedMeeting], .removal) {
                    try self.storage.deleteMeeting(mergedMeeting)
                }
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
                        pipeline.restoreForgottenMeetings([source.id])
                        excludedMeetingIDs.remove(source.id)
                        cachedSearchIndex?.noteRestoration(source.id)
                        cachedEmbeddingIndex?.noteRestoration(source.id)
                        if settings.semanticSearchEnabled {
                            reindexEmbeddingInBackground(restored)
                        }
                    } catch {
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
                if FileManager.default.fileExists(
                    atPath: mergedMeeting.folderURL(in: storage).path) {
                    pipeline.restoreForgottenMeetings([mergedMeeting.id])
                }
                lastError = "Could not undo the merge: \(error.localizedDescription)"
            }
        }
    }

    func setMeetingBoundaries(_ range: Meeting.ContentRange, for meeting: Meeting) throws {
        if let stage = pipeline.stages[meeting.id], !stage.isFailure {
            throw TextEngineError.badResponse("Wait for meeting processing to finish before changing its boundaries.")
        }
        let folder = meeting.folderURL(in: storage)
        let duration = max(
            meeting.recordedDuration ?? 0,
            MeetingAudioFiles.longestDuration(in: folder) ?? 0,
            meeting.duration ?? 0
        )
        guard range.isValid, duration.isFinite, duration > 0,
              range.start < duration, range.end <= duration + 0.05 else {
            throw TextEngineError.badResponse("Choose a start and end within the recorded audio, with the end after the start.")
        }
        let clampedEnd = min(range.end, duration)
        guard clampedEnd > range.start else {
            throw TextEngineError.badResponse("Choose a start and end within the recorded audio, with the end after the start.")
        }
        let effectiveRange: Meeting.ContentRange? =
            (range.start <= 0.05 && clampedEnd >= duration - 0.05)
            ? nil
            : .init(start: range.start, end: clampedEnd)
        var updated = meeting
        updated.contentRange = effectiveRange
        updated.contentRangeSource = effectiveRange == nil ? nil : .userReviewed
        let existing = try? pipeline.loadTranscript(from: folder)
        try withPrimaryEvidenceChange(for: [updated], .removal) {
            try MeetingAttributionArtifacts.invalidate(in: folder)
            if let existing {
                try pipeline.saveTranscript(effectiveRange?.applying(to: existing) ?? existing, for: updated)
            }
            try storage.saveMeta(updated)
        }
        if let index = meetings.firstIndex(where: { $0.id == updated.id }) { meetings[index] = updated }
        outcomeIndex.refresh(meeting: updated)
        primaryEvidenceDidChange(for: updated)
        searchIndex.reindex(updated, storage: storage)
        embeddingIndexTasks.removeValue(forKey: updated.id)?.task.cancel()
        embeddingIndex.clearVectors(for: updated.id)
        reprocess(updated, transcribe: true, summarize: true)
    }

    @discardableResult
    func extractMeeting(
        from sourceMeeting: Meeting,
        range: Meeting.ContentRange
    ) async throws -> Meeting {
        if let stage = pipeline.stages[sourceMeeting.id], !stage.isFailure {
            throw TextEngineError.badResponse("Wait for meeting processing to finish before creating a meeting from a selection.")
        }
        let created = try await MeetingSelectionExtractService.extract(
            from: sourceMeeting,
            range: range,
            storage: storage)
        meetings.append(created)
        meetings.sort { $0.startedAt > $1.startedAt }
        outcomeIndex.refresh(meetings: meetings)
        primaryEvidenceDidChange(for: [created])
        reindexSearchInBackground(created)
        if settings.semanticSearchEnabled {
            reindexEmbeddingInBackground(created)
        }
        selectedMeetingIDs = [created.id]
        navSection = .meetings
        reprocess(created, transcribe: true, summarize: true)
        return created
    }

    @discardableResult
    func reprocess(_ meeting: Meeting, transcribe: Bool, summarize: Bool) -> ProcessingPipeline.EnqueueOutcome {
        lastError = nil
        let outcome = pipeline.enqueue(
            meeting,
            transcribe: transcribe,
            summarize: summarize)
        switch outcome {
        case .alreadyProcessing:
            lastError = "Summary processing has already started for this meeting. Wait for it to finish before choosing a different processing action."
        case .persistenceFailed:
            lastError = "LokalBot could not save the updated processing request."
        case .revoked:
            lastError = "This meeting is being removed and can no longer be processed."
        case .enqueued, .coalesced, .updatedActive:
            break
        }
        return outcome
    }

    func retryProcessing(_ meeting: Meeting) {
        let work = pipeline.retryWork(
            for: meeting, autoSummarize: settings.autoSummarize)
        reprocess(meeting, transcribe: work.transcribe, summarize: work.summarize)
    }

    func processMeetingsWaitingForModels() {
        pipeline.retryJobsWaitingForModels()
    }

    private var speakerVoiceLearning: Task<Void, Never>?

    func learnSpeakerVoices(after delay: Duration = .seconds(2)) {
        guard !Self.isUnitTesting, !UITestRuntime.isEnabled else { return }
        let previous = speakerVoiceLearning
        speakerVoiceLearning = Task { [weak self] in
            await previous?.value
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            let access = MeetingSpeakerIdentityService.SavedMeetings(
                transcript: { [weak self] meeting in
                    guard let self else { return nil }
                    return try? self.pipeline.loadTranscript(from: meeting.folderURL(in: self.storage))
                },
                callSamples: { [weak self] meeting, transcript in
                    guard let self else { return [] }
                    return try await self.pipeline.savedCallVoiceSamples(for: meeting, transcript: transcript)
                },
                isBusy: { [weak self] meeting in
                    guard let self else { return true }
                    return self.pipeline.captureActive || self.pipeline.stages[meeting.id] != nil
                })
            await self.speakerIdentity.learnFromSavedMeetings(self.meetings,
                recentSince: Date().addingTimeInterval(-14 * 86_400), using: access)
        }
    }

    func saveTranscript(_ transcript: Transcript, for meeting: Meeting) throws {
        let transcript = speakerIdentity.applyingLatestDecision(to: transcript, meetingID: meeting.id)
        try withPrimaryEvidenceChange(for: [meeting], .revision) {
            try pipeline.saveTranscript(transcript, for: meeting)
        }
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
        let ocr = meeting.isImported ? "" : activityStore.ocrText(from: meeting.startedAt, to: end, maxChars: 12_000)
        return SpeakerNameHintExtractor.hints(
            calendarNames: meeting.resolvedCalendarParticipantIdentities.compactMap(\.name),
            ocrText: ocr)
    }

    private var dictationVocabularyCache: (key: String, terms: [String])?

    func dictationTranscriptionSettings(_ base: AppSettings) -> AppSettings {
        guard base.autoTranscriptionVocabulary,
              base.transcriptionModel.acceptsVocabularyPrompt else { return base }
        let dayKey = DreamDay.key(for: Date())
        let key = "\(dayKey)|\(meetings.count)|\(meetings.map(\.startedAt).max()?.timeIntervalSince1970 ?? 0)"
        let terms: [String]
        if let cached = dictationVocabularyCache, cached.key == key {
            terms = cached.terms
        } else {
            let memory = (try? dreamStore.loadMemory()) ?? nil
            terms = TranscriptionVocabulary.terms(
                TranscriptionVocabulary.recentSources(library: meetings, memory: memory))
            dictationVocabularyCache = (key, terms)
        }
        var settings = base
        settings.transcriptionPrompt = TranscriptionVocabulary.prompt(
            manual: base.transcriptionPrompt, terms: terms)
        return settings
    }

    private func primaryEvidenceDidChange(for meeting: Meeting) {
        primaryEvidenceDidChange(for: [meeting])
    }

    private func primaryEvidenceDidChange(for meetings: [Meeting]) {
        primaryEvidenceDidChange(on: meetings.map(\.startedAt), meetingIDs: Set(meetings.map(\.id)))
    }

    func primaryEvidenceDidChange(on days: [Date]) {
        primaryEvidenceDidChange(on: days, meetingIDs: [])
    }

    private func primaryEvidenceDidChange(on days: [Date], meetingIDs: Set<UUID>) {
        guard !days.isEmpty else { return }
        dayDigest.reconsiderEvidence(for: days)
        dailyMemoryExportScheduler.reconsider(days: days)
        meetingNoteExport.reconsider()
        memoryRoutines.reconsiderEvidence()
        let activityOnly = meetingIDs.isEmpty
        invalidateDreams(affectedDays: days, affectedMeetingIDs: meetingIDs,
                         comparisonWindowDays: activityOnly ? 1 : DreamCompiler.comparisonWindowDays,
                         activityOnly: activityOnly)
        if !meetingIDs.isEmpty { personalModel.retractIfLoaded() }
        companionHost?.evidenceChanged(days: days, meetingIDs: meetingIDs)
    }

    private func actionWorkflowStateDidChange(for meetings: [Meeting]) {
        guard !meetings.isEmpty else { return }
        if settings.cotypingUseMeetingMemory || settings.cotypingUseScreenMemory {
            cotyping.invalidateMemoryContext()
        }
        meetingNoteExport.reconsider()
        memoryRoutines.reconsiderEvidence()
        companionHost?.evidenceChanged(
            days: meetings.map(\.startedAt),
            meetingIDs: Set(meetings.map(\.id)))
    }

    func meetingArtifactsWillChange(_ meeting: Meeting) {
        dayDigest.reconsiderEvidence(for: meeting.startedAt)
    }

    enum EvidenceChange {
        case revision
        case removal
    }

    func withPrimaryEvidenceChange<T>(on days: [Date], _ change: EvidenceChange,
                                      _ mutation: () throws -> T) throws -> T {
        if settings.cotypingUseMeetingMemory || settings.cotypingUseScreenMemory { cotyping.invalidateMemoryContext() }
        defer { primaryEvidenceDidChange(on: days) }
        purgeDigestSegmentAnswers(for: days)
        return try dreamStore.withScreenEvidenceMutation(on: days) {
            if change == .removal { try dayDigest.retractGeneratedJournals(for: days) }
            return try mutation()
        }
    }

    func withScheduledRetention<T>(on days: [Date], _ mutation: () throws -> T) throws -> T {
        defer { scheduledRetentionDidRemoveEvidence(on: days) }
        purgeDigestSegmentAnswers(for: days)
        return try mutation()
    }

    private func scheduledRetentionDidRemoveEvidence(on days: [Date]) {
        guard !days.isEmpty else { return }
        dailyMemoryExportScheduler.reconsider(days: days)
        memoryRoutines.reconsiderEvidence()
        companionHost?.evidenceChanged(days: days, meetingIDs: [])
    }

    private func withPrimaryEvidenceChange<T>(for meetings: [Meeting], _ change: EvidenceChange,
                                              _ mutation: () throws -> T) throws -> T {
        if settings.cotypingUseMeetingMemory || settings.cotypingUseScreenMemory { cotyping.invalidateMemoryContext() }
        defer { primaryEvidenceDidChange(for: meetings) }
        purgeDigestSegmentAnswers(for: meetings.map(\.startedAt))
        let result = try dreamStore.withMeetingEvidenceMutation(for: meetings) {
            if change == .removal { try dayDigest.retractGeneratedJournals(for: meetings.map(\.startedAt)) }
            return try mutation()
        }
        if change == .removal { projectStore.withdrawSummaries(citing: Set(meetings.map(\.id))) }
        return result
    }

    private func purgeDigestSegmentAnswers(for days: [Date]) {
        let calendar = Calendar.current
        DayDigestSegmentCache.shared.purge(days: Set(days.map { DreamDay.key(for: $0, calendar: calendar) }))
    }

    private func dayDigestDidChange(on day: Date) {
        let calendar = Calendar.current
        let retainedSince = Date().addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        if calendar.startOfDay(for: day) >= retainedSince {
            dailyMemoryExportScheduler.digestDidChange(on: day)
        }
        memoryRoutines.reconsiderEvidence()
        companionHost?.dayDigestChanged(day)
        guard calendar.startOfDay(for: day) < calendar.startOfDay(for: Date()) else { return }
        invalidateDreams(affectedDays: [day], comparisonWindowDays: 1, activityOnly: true,
                         sourceDayKeys: [DreamDay.key(for: day, calendar: calendar)])
    }

    private func invalidateDreams(
        affectedDays: [Date], affectedMeetingIDs: Set<UUID> = [],
        comparisonWindowDays: Int = DreamCompiler.comparisonWindowDays,
        activityOnly: Bool = false,
        sourceDayKeys: Set<String>? = nil
    ) {
        let calendar = Calendar.current
        let affectedKeys = DreamEvidenceInvalidation.dayKeys(
            affectedDays: affectedDays, through: Date(), calendar: calendar,
            comparisonWindowDays: comparisonWindowDays)
        var invalidatedKeys = affectedKeys
        do {
            invalidatedKeys = try dreamStore.invalidateEvidence(
                affectedDayKeys: sourceDayKeys ?? DreamEvidenceInvalidation.sourceDayKeys(for: affectedDays),
                affectedMeetingIDs: affectedMeetingIDs,
                reportDayKeys: affectedKeys,
                activityOnly: activityOnly)
        } catch {
            lastError = "Could not retract changed evidence from Dream memory: " + error.localizedDescription
        }
        refreshDreamMemory()
        let latest = dreamStore.latestReport()
        if latestDreamReport != latest { latestDreamReport = latest }
        dreaming.reconsiderReports(invalidating: invalidatedKeys, cancellingInFlight: false)
    }

    func applyTrackingSetting() {
        screenshots.mutateEvidence = { [weak self] days, mutation in
            guard let self else { throw CancellationError() }
            try self.withScheduledRetention(on: days, mutation)
        }
        screenshots.onTextStored = { [weak self] in self?.screenTextDidArrive() }
        TextRecognitionQueue.shared.observeStalls { [weak self] stall in
            Task { @MainActor in self?.textRecognitionDidChange(stalled: stall != nil) }
        }
        sampler.excludedApps = { [weak self] in self?.settings.excludedAppList ?? [] }
        sampler.excludedDomains = { [weak self] in self?.settings.excludedScreenDomainList ?? [] }
        if settings.trackingEnabled { sampler.start() } else { sampler.stop() }
        screenshots.restart()
    }

    private func textRecognitionDidChange(stalled: Bool) {
        textRecognitionStalled = stalled
        if !stalled, settings.fileSearchEnabled { fileSearch.requestPass() }
    }

    func applyQuickRecallSetting(replacing previous: DictationShortcut? = nil) {
        guard settings.quickRecallEnabled else {
            quickRecallHotKey.setShortcut(nil)
            return
        }
        let shortcut = settings.quickRecallShortcut
        guard !quickRecallHotKey.setShortcut(shortcut) else { return }
        lastError = "The Quick Recall shortcut could not register \(shortcut.displayLabel). Another app may already use it."
        if let previous, previous != shortcut, quickRecallHotKey.setShortcut(previous) {
            settings.quickRecallShortcut = previous
        } else {
            settings.quickRecallEnabled = false
        }
    }

    func setShortcutRecording(_ recording: Bool) {
        dictation.setShortcutRecording(recording)
        guard interactive else { return }
        quickRecallHotKey.isSuspended = recording
        selectionActionsHotKey.isSuspended = recording
        windowHandoffHotKey.isSuspended = recording
        if !recording {
            applyQuickRecallSetting()
            applySelectionActionsSetting()
            applyWindowHandoffSetting()
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
        dailyMemoryExportScheduler.configure(configuration) { day, pass in
            let destination = URL(
                fileURLWithPath: destinationPath,
                isDirectory: true)
            try Task.checkCancellation()
            let service = DailyMemoryExportService(
                source: FileDailyMemoryExportSource(root: storageRoot),
                calendar: .current)
            do {
                _ = try service.export(
                    day: day,
                    configuration: DailyMemoryExportConfiguration(
                        destinationDirectory: destination,
                        format: exportKind),
                    pass: pass)
            } catch is DailyMemoryExportError where !Calendar.current.isDateInToday(day) {
            }
        } onError: { [weak self] message in
            self?.lastError = message
        }
    }

    func applyMeetingNoteExportSetting() {
        let snapshot = settings
        let folder = snapshot.meetingNoteExportFolder
        let format: DailyMemoryExportKind = switch snapshot.meetingNoteExportFormat {
        case .markdown: .markdown
        case .obsidian: .obsidian
        case .logseq: .logseq
        }
        let includesTranscript = snapshot.meetingNoteExportIncludesTranscript
        let configuration = MeetingNoteExportScheduler.Configuration(
            enabled: snapshot.meetingNoteExportEnabled,
            destinationID: folder.isEmpty ? "" : "\(folder)|\(format.rawValue)|\(includesTranscript)")
        let storageRoot = storage.rootURL
        if meetingNoteCurationObserver == nil {
            meetingNoteCurationObserver = peopleStore.$curation.dropFirst().map { _ in () }
                .merge(with: projectStore.$curation.dropFirst().map { _ in () })
                .sink { [weak self] in
                    self?.meetingNoteExport.reconsider()
                }
        }
        meetingNoteExport.configure(configuration) { previous in
            try MeetingNoteExportService(root: storageRoot).export(
                MeetingNoteExportConfiguration(
                    destinationDirectory: URL(fileURLWithPath: folder, isDirectory: true),
                    format: format,
                    includesTranscript: includesTranscript),
                previous: previous)
        } onError: { [weak self] message in
            self?.lastError = message
        }
    }

    func applyCodingAgentEvidenceSetting() {
        codingAgentEvidence.start()
    }

    func applyCodingAgentNotesSetting() {
        guard HeadlessCommand.requested == nil, !Self.isUITesting, !UITestRuntime.isUnitTesting else { return }
        agentNotes.start()
    }

    static func codingAgentConfiguration(
        _ settings: AppSettings, defaults: UserDefaults = .standard
    ) -> CodingAgentEvidenceIngestor.Configuration {
        .init(settings: settings, onboardingFinished: defaults.bool(forKey: onboardingShownKey))
    }

    func finishOnboarding(applying draft: CaptureSetupDraft, opensSampleMeeting: Bool = false) {
        settings = draft.applying(to: settings)
        markSetupFinished()
        if opensSampleMeeting { openSampleMeetingWhenReady() }
    }

    func markSetupFinished() {
        let firstFinish = !UserDefaults.standard.bool(forKey: Self.onboardingShownKey)
        UserDefaults.standard.set(true, forKey: Self.onboardingShownKey)
        if !UITestRuntime.isUnitTesting { OnboardingResumeStore.live.clear() }
        if firstFinish && interactive { applyCodingAgentEvidenceSetting() }
    }

    private func codingAgentEvidenceDidChange(on days: [Date]) {
        let calendar = Calendar.current
        guard let yesterday = calendar.date(
            byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) else { return }
        let reopened = days.filter { calendar.isDate($0, inSameDayAs: yesterday) }
        if !reopened.isEmpty { dayDigest.reconsiderEvidence(for: reopened) }
    }

    func deleteCodingAgentEvidence() throws {
        settings.codingAgentEvidenceEnabled = false
        let starts = try activityStore.codingAgentBurstStarts()
        guard !starts.isEmpty else { return }
        let days = Array(Set(starts.values.map { Calendar.current.startOfDay(for: $0) }))
        try withPrimaryEvidenceChange(on: days, .removal) {
            try activityStore.deleteCodingAgentBursts(ids: Array(starts.keys))
        }
        NotificationCenter.default.post(name: .codingAgentEvidenceChanged, object: nil)
    }

    func applyDayDigestSetting() {
        let snapshot = settings
        dayDigest.stopAutomaticGeneration()
        dayDigest.configureAutomaticGeneration(
            DayDigestScheduler.Configuration(
                enabled: snapshot.dayDigestAutoEnabled,
                hour: snapshot.dayDigestHour),
            canRun: { [weak self] in
                guard let self, self.libraryReady, self.settings.allowsAutomaticMainInference else { return false }
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

    private func bindBackgroundActivity() {
        backgroundActivity.bind(.init(
            pipeline: pipeline,
            dayDigest: dayDigest,
            dreaming: dreaming,
            downloads: ModelDownloadManager.shared,
            reindex: $embeddingBackfill.eraseToAnyPublisher(),
            meetingTitle: { [weak self] id in
                self?.meetings.first { $0.id == id }?.displayTitle
            },
            modelName: { [weak self] id in
                ModelCatalog.entry(id: id, custom: self?.settings.customBuiltInModels ?? [])?.displayName ?? id
            }))
    }

    func openBackgroundActivity(_ destination: BackgroundActivity.Destination) {
        switch destination {
        case .meeting(let id):
            openMeeting(id)
        case .day(let day):
            if Calendar.current.isDateInToday(day) {
                openToday()
            } else {
                openTimelineDay(day)
            }
        case .dream:
            openToday()
        case .models:
            openSettings(tab: .models)
        }
    }

    func libraryHealthReport(for day: Date, now: Date = Date()) -> LibraryHealthReport {
        let loader = LibraryHealthLoader(
            activityStore: activityStore,
            storageRoot: storage.rootURL,
            meetings: meetings,
            queuedMeetingIDs: pipeline.queuedMeetingIDs(),
            settings: settings,
            hasDreamReport: { [dreamStore] in dreamStore.hasReport(forDayKey: $0) })
        return LibraryHealthEvaluator.evaluate(
            loader.input(for: day, now: now), dayKey: DreamDay.key(for: day))
    }

    private(set) lazy var healthScheduler = LibraryHealthScheduler()

    @discardableResult
    func runHealthCheckNow(notify: Bool = true) -> URL? {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) ?? Date()
        let report = libraryHealthReport(for: yesterday)
        do {
            let url = try LibraryHealthReportStore.write(report, root: storage.rootURL)
            if notify, report.status == .fail {
                let failed = report.findings.filter { $0.status == .fail }.map(\.check.title)
                RecordingNotifier.shared.healthCheckFailed(
                    summary: failed.joined(separator: ", "), reportURL: url)
            }
            return url
        } catch {
            lokalbotLog("health report write failed: \(error.localizedDescription)")
            return nil
        }
    }

    func applyHealthCheckSetting() {
        guard LibraryHealthScheduler.isEnabledForThisBuild else { return }
        let root = storage.rootURL
        healthScheduler.start(
            lastRun: { LibraryHealthReportStore.latestRunDate(root: root) },
            run: { [weak self] in self?.runHealthCheckNow() })
    }

    func diagnosticsSources() -> DiagnosticsExporter.Sources {
        let log = AppLog.debugLogURL()
        let root = storage.rootURL
        return DiagnosticsExporter.Sources(
            logURLs: [log] + FileLogSink.rotatedURLs(for: log, maxRotations: 5),
            healthReportsDirectory: DiagnosticsPaths.healthReports(root: root),
            captureTracesDirectory: DiagnosticsPaths.captureTraces(root: root),
            databaseURL: DiagnosticsPaths.database(root: root),
            settingsJSON: try? JSONEncoder().encode(settings))
    }

    @discardableResult
    func exportDiagnostics(to destination: URL) throws -> DiagnosticsExporter.Manifest {
        try DiagnosticsExporter.export(diagnosticsSources(), to: destination)
    }

#if DEBUG
    func startCaptureTraceRecording(seconds: Int = 60, scenario: String = "real") {
        guard CaptureTraceRecorder.active == nil else {
            lokalbotLog("capture trace: a recording is already running")
            return
        }
        let recorder = CaptureTraceRecorder(scenario: scenario, origin: scenario == "real" ? .real : .scripted)
        CaptureTraceRecorder.active = recorder
        CaptureEnvironment.install(recorder.environment)
        lokalbotLog("capture trace: recording \(seconds)s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            CaptureEnvironment.reset()
            CaptureTraceRecorder.active = nil
            guard let self else { return }
            do {
                let url = try recorder.finish(to: DiagnosticsPaths.captureTraces(root: self.storage.rootURL))
                lokalbotLog("capture trace: wrote \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                lokalbotLog("capture trace: FAILED — \(error.localizedDescription)")
            }
        }
    }
#endif

    func openTimelineDay(_ day: Date) {
        navigationHandoff.stageTimelineDay(day)
        selectedMeetingIDs = []
        navSection = .timeline
    }

    private func emailAttendeeAddresses() -> Set<String> {
        let now = Date()
        let windowStart = EmailScope.windowStart(now: now)
        var addresses: Set<String> = []
        if settings.calendarDetectionEnabled {
            addresses = calendar.attendeeAddresses(from: windowStart, to: now.addingTimeInterval(14 * 86_400))
        }
        for meeting in meetings where meeting.startedAt >= windowStart {
            for identity in meeting.resolvedCalendarParticipantIdentities {
                if let address = identity.emailAddress { addresses.insert(address) }
            }
        }
        return addresses
    }

    private func nextMeetingWithAttendeesStart() -> Date? {
        guard settings.calendarDetectionEnabled, calendar.hasAccess else { return nil }
        let now = Date()
        return calendar.meetingCandidates(on: now)
            .filter { $0.startDate > now && !$0.resolvedParticipantIdentities.isEmpty }
            .map(\.startDate)
            .min()
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

    func applyFileSearchSetting() {
        guard HeadlessCommand.requested == nil, !Self.isUITesting, libraryReady else { return }
        filesAccess.refresh()
        guard settings.fileSearchEnabled || fileSearch.configuration.enabled else { return }
        fileSearch.apply(.init(enabled: settings.fileSearchEnabled, folders: settings.fileSearchFolders,
                               includesMedia: settings.fileSearchIncludesMedia,
                               readsOnBattery: settings.fileSearchReadsOnBattery))
    }

    func applyDreamingSetting() {
        let snapshot = settings
        dreaming.stop()

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
                guard self.settings.allowsAutomaticMainInference else { return false }
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
                return DreamScheduler.powerAllowsDreaming(
                    isOnBattery: PowerSourceMonitor.currentlyOnBattery())
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
                        if target.isAutomatic && !engineSettings.allowsAutomaticMainInference {
                            throw TextEngineError.unavailable("Approve scheduled context sharing for this remote Think server in Models settings.")
                        }
                        let engine = try await self.thinkExecution.makeTextEngine(
                            engineSettings,
                            priority: .background,
                            purpose: "dreaming")
                        try Task.checkCancellation()
                        if target.isAutomatic && !self.settings.allowsAutomaticMainInference {
                            throw CancellationError()
                        }
                        return (engine, DreamInferenceProvenance(settings: engineSettings))
                    },
                    language: DailySummaryLanguage(notes: self.settings.summaryLanguage, interface: self.settings.appLanguage))
                let report = try await service.dream(target: target)
                self.latestDreamReport = report
                self.refreshDreamMemory()
                await self.learnAboutPerson(target: target)
                await self.rollUpReviews(target: target)
            },
            onError: { [weak self] message in
                self?.lastError = message
            })
    }

    private func learnAboutPerson(target: DreamScheduler.Target) async {
        guard settings.askMemoryEnabled, settings.personalLearningEnabled else { return }
        if let memory = (try? dreamStore.loadMemory()) ?? nil {
            let promoted = personalModel.promoteWorkMemory(memory, dayKey: target.dayKey, calendar: target.calendar)
            if !promoted.proposed.isEmpty {
                lokalbotLog("personal learning: day=\(target.dayKey) work-memory suggestions=\(promoted.proposed.count)")
            }
        }
        let engineSettings = settings
        if target.isAutomatic && !engineSettings.allowsAutomaticMainInference { return }
        let bursts = engineSettings.codingAgentEvidenceEnabled ? activityStore.codingAgentBursts(on: target.day) : []
        let dictated = engineSettings.learnsFromDictation
            ? dictationLearningLog.entries(on: target.day, calendar: target.calendar) : []
        let typed = PersonalLearning.typedLines(
            bursts: bursts, conversations: chat.conversations, dictations: dictated,
            day: target.day, calendar: target.calendar)
        do {
            let lines = try PersonalLearning.utterances(
                day: target.day, storageRoot: storage.rootURL, typed: typed, calendar: target.calendar)
            let fingerprint = PersonalLearning.fingerprint(lines)
            let counts = PersonalLearning.lineCounts(lines)
            if lines.isEmpty || (dictated.isEmpty
                && personalModel.hasLearned(dayKey: target.dayKey, fingerprint: fingerprint)) {
                lokalbotLog("personal learning: day=\(target.dayKey) \(counts) unchanged or empty, not read again")
                return
            }
            let revision = try dreamStore.evidenceRevision()
            let engine = try await thinkExecution.makeTextEngine(
                engineSettings, priority: .background, purpose: "personal learning")
            try Task.checkCancellation()
            let known = personalModel.usableClaims() + personalModel.suggestions
            let embed: PersonalLearning.Embed? = engineSettings.semanticSearchEnabled
                ? { [weak self] texts in await self?.embeddingIndex.similarityVectors(texts) }
                : nil
            let candidates = try await PersonalLearning.run(
                lines: lines, known: known, revision: revision, engine: engine, embed: embed)
            if !dictated.isEmpty {
                try? dictationLearningLog.removeEntries(through: target.day, calendar: target.calendar)
            }
            let outcome = personalModel.learn(candidates, dayKey: target.dayKey, fingerprint: fingerprint)
            lokalbotLog("personal learning: day=\(target.dayKey) \(counts) saved=\(outcome.saved.count) "
                + "suggested=\(outcome.proposed.count) skipped=\(outcome.skipped)")
        } catch is CancellationError {
            return
        } catch {
            lokalbotLog("personal learning skipped: \(error.localizedDescription)")
        }
    }

    private func learnedClaimSourceStillQuotes(_ claim: PersonalClaim) -> Bool {
        switch claim.origin {
        case .learned(let meetingID, _):
            guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return false }
            let url = storage.rootURL.appendingPathComponent(meeting.relativePath, isDirectory: true)
                .appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: url),
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { return false }
            return PersonalLearning.quoteStillSaid(claim.quote, in: PersonalLearning.ownTurns(in: transcript.segments))
        case .typed(.codingAgent, let dayKey):
            guard settings.codingAgentEvidenceEnabled, let day = DreamDay.date(fromKey: dayKey) else { return false }
            let requests = activityStore.codingAgentBursts(on: day).filter { !$0.isScheduledRun }.flatMap(\.prompts)
            return PersonalLearning.quoteStillSaid(claim.quote, in: requests)
        case .workMemory:
            guard let memory = (try? dreamStore.loadMemory()) ?? nil else { return false }
            let key = PersonalModel.duplicateKey(claim.text)
            let texts = memory.workGoals.map(\.text) + memory.activeProjects.map { "I work on \($0.name)." }
            return texts.contains { PersonalModel.duplicateKey($0) == key }
        default:
            return false
        }
    }

    private func rollUpReviews(target: DreamScheduler.Target) async {
        let engineSettings = settings
        let showable = screenMemoryAccess.isEnabled && screenMemoryAccess.profile.scope == .retainedHistory
        let limit = showable ? DreamRollupService.maximumPerNight : 0
        do {
            let outcome = try await DreamRollupService.run(
                root: storage.rootURL, now: Date(), calendar: target.calendar, limit: limit
            ) { [weak self] in
                guard let self else { throw TextEngineError.unavailable("LokalBot is shutting down.") }
                if target.isAutomatic && !engineSettings.allowsAutomaticMainInference { throw CancellationError() }
                return try await self.thinkExecution.makeTextEngine(
                    engineSettings, priority: .background, purpose: "dream rollup")
            }
            if !outcome.written.isEmpty || !outcome.removed.isEmpty {
                lokalbotLog("dream rollups: written=\(outcome.written.map(\.key)) removed=\(outcome.removed)")
            }
        } catch is CancellationError {
            return
        } catch {
            lokalbotLog("dream rollups skipped: \(error.localizedDescription)")
        }
    }

    func keepDictationForLearning(_ spokenText: String, appName: String) {
        guard settings.learnsFromDictation else { return }
        do {
            try dictationLearningLog.append(spokenText, appName: appName)
        } catch {
            lokalbotLog("dictation for learning not kept: \(error.localizedDescription)")
        }
    }

    func applyDictationLearningSetting() {
        do {
            if settings.learnsFromDictation {
                try dictationLearningLog.prune()
            } else {
                try dictationLearningLog.deleteAll()
            }
        } catch {
            lokalbotLog("dictation learning log cleanup failed: \(error.localizedDescription)")
        }
    }

    func forgetDictationForLearning() {
        do {
            try dictationLearningLog.deleteAll()
        } catch {
            lokalbotLog("dictation learning log delete failed: \(error.localizedDescription)")
        }
    }

    func setDreamingEnabled(_ enabled: Bool) {
        guard settings.dreamingEnabled != enabled else { return }

        var updated = settings
        updated.dreamingEnabled = enabled
        updated.dreamingFirstEligibleDayKey = Self.dreamingFirstEligibleDayKey(enabled: enabled)
        settings = updated
    }

    nonisolated static func dreamingFirstEligibleDayKey(
        enabled: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard enabled else { return nil }
        return DreamDay.key(for: DreamScheduler.previousDay(of: now, calendar: calendar), calendar: calendar)
    }

    func dreamNow() {
        guard libraryReady else {
            lastError = "Preparing your meeting library; dreaming will be available when it is ready."
            return
        }
        dreaming.dreamNow()
    }

    func refreshDreamMemory() {
        if settings.cotypingUseMeetingMemory || settings.cotypingUseScreenMemory { cotyping.invalidateMemoryContext() }
        do {
            let loaded = try dreamStore.loadMemory()
            if dreamMemory != loaded { dreamMemory = loaded }
        } catch {
            if dreamMemory != nil { dreamMemory = nil }
            lastError = "Could not load dream memory: \(error.localizedDescription)"
        }
    }

    func clearDreamMemory() {
        dreaming.stop()
        do {
            try dreamStore.clearAll()
        } catch {
            lastError = "Could not clear dream memory: \(error.localizedDescription)"
        }
        latestDreamReport = nil
        refreshDreamMemory()
        let today = DreamDay.key(for: Date(), calendar: .current)
        if settings.dreamingEnabled, settings.dreamingFirstEligibleDayKey != today {
            var updated = settings
            updated.dreamingFirstEligibleDayKey = today
            settings = updated
        } else {
            applyDreamingSetting()
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

    func openFileCitation(_ id: Int64) {
        guard settings.fileSearchEnabled else { return }
        Task { @MainActor in
            if let hit = await fileSearch.hit(segment: id) { FileSearchOpener.open(hit, query: nil) }
        }
    }

    func openAgentNoteCitation(_ id: String) {
        guard settings.codingAgentNotesEnabled else { return }
        let index = agentNotesIndex
        Task { @MainActor in
            let hit = await Task.detached(priority: .userInitiated) { try? index.hit(id: id) }.value
            if let hit { AgentNoteOpener.open(hit) }
        }
    }

    func openSearchHit(_ hit: SearchIndex.Hit) {
        openMeeting(
            hit.meetingID,
            seek: hit.kind == .segment ? hit.start : nil)
    }

    func openScreenSnapshot(_ snapshotID: Int64) {
        if navSection != .timeline {
            evidenceReturnSection = navSection
            evidenceReturnMeetingIDs = selectedMeetingIDs
        }
        navigationHandoff.stageScreenSnapshot(snapshotID)
        selectedMeetingIDs = []
        navSection = .timeline
    }

    func openCitation(_ citation: ChatCitation) {
        guard let meeting = ((try? SessionLookup.find(id: citation.meetingID, in: meetings)) ?? nil) else { return }
        openMeeting(meeting.id, seek: citation.seconds)
    }

    func deleteMeetings(_ ids: Set<Meeting.ID>) {
        let candidates = meetings.filter { ids.contains($0.id) }
        Task {
            var deletedIDs: Set<Meeting.ID> = []
            var deletedMeetings: [Meeting] = []
            for meeting in candidates {
                var forgottenIDs: Set<Meeting.ID> = []
                do {
                    let ordered = try storage.deletionOrder(for: meeting)
                    forgottenIDs = Set(ordered.map(\.id))
                    await pipeline.forget(meetingIDs: forgottenIDs)
                    for item in ordered where !deletedIDs.contains(item.id) {
                        try await speakerIdentity.prepareDeletion(meeting: item)
                        try withPrimaryEvidenceChange(for: [item], .removal) {
                            try storage.deleteMeeting(item)
                        }
                        embeddingIndexTasks.removeValue(forKey: item.id)?.task.cancel()
                        excludedMeetingIDs.insert(item.id)
                        cachedSearchIndex?.noteDeletion(item.id)
                        cachedEmbeddingIndex?.noteDeletion(item.id)
                        scheduleIndexCleanup(item.id)
                        deletedIDs.insert(item.id)
                        deletedMeetings.append(item)
                    }
                } catch {
                    pipeline.restoreForgottenMeetings(
                        forgottenIDs.subtracting(deletedIDs))
                    lastError = "Could not delete \(meeting.title); cleanup pending: \(error.localizedDescription)"
                }
            }
            meetings.removeAll { deletedIDs.contains($0.id) }
            recording.forgetFinalization(meetingIDs: deletedIDs)
            selectedMeetingIDs.subtract(deletedIDs)
            outcomeIndex.refresh(meetings: meetings)
            primaryEvidenceDidChange(for: deletedMeetings)
        }
    }
}
