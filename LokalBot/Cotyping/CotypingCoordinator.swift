import Combine
import Foundation

/// File overview:
/// Declares the shared state and dependency graph for LokalBot's inline-completion orchestrator.
/// Behavior lives in `CotypingCoordinator+*.swift` files so each state-machine concern can be
/// reviewed independently.
///
/// Swift has no type-private access level spanning multiple files. Coordinator-owned state
/// therefore uses module visibility and is protected by convention: other types may observe it
/// but must not mutate it.
/// Orchestrates cotyping: focus polling → debounce → generation → ghost overlay
/// → accept-on-Tab. Trimmed port of Cotabby's `SuggestionCoordinator`, adapted
/// to LokalBot's HTTP completion engine. Owns the session and the work-id
/// (`generation`) that drops superseded results.
///
/// Started/stopped by `AppState` from the cotyping setting + permission state.
@MainActor
final class CotypingCoordinator: ObservableObject {
    /// Live status for the in-app Cotyping section.
    @Published var state: CotypingState = .idle
    /// True while the subsystem is running (taps + focus poll installed).
    @Published var isRunning = false
    /// Last non-empty suggestion shown (diagnostics).
    @Published var lastSuggestion: String?
    /// Words accepted this session (diagnostics).
    @Published var acceptedWordCount = 0
    @Published var memoryContextSources: [String] = []
    /// The last suggestion looked for saved facts, whether or not it used any.
    @Published var memoryContextSearched = false

    let focusTracker: CotypingFocusTracker
    let inputMonitor: CotypingInputMonitor
    let inputSourceMonitor: CotypingKeyboardInputSourceMonitor
    let overlay: CotypingOverlayController
    /// The caret found on screen for fields whose app reports none.
    let visualCaret = CotypingVisualCaret()
    let inserter: CotypingInserter
    let engine: CotypingCompleting
    let learningStore: CotypingLearningStore
    /// Usage counters and typing measurements. Injected so tests never write
    /// the installed app's saved counters.
    let stats: CotypingStatsStore
    let settingsProvider: () -> AppSettings
    let memoryContextProvider: (CotypingField, AppSettings) async -> CotypingMemoryContextProvider.Snapshot
    var activeMemoryContext = CotypingMemoryContextProvider.Snapshot.empty
    /// The newest saved-memory lookup for the field being typed in.
    var memoryLookup = CotypingMemoryLookup()
    var activeVisibleContext: CotypingVisibleContext.Snapshot?
    /// Live flag from AppState — cotyping stays quiet while a meeting records.
    let isMeetingRecordingActive: () -> Bool
    let selfBundleID: String?

    var config = CotypingConfiguration.standard
    var appliedPrivacySettings: CotypingPrivacySettings?
    var session: CotypingSession?
    var acceptedSuggestionBatch = CotypingAcceptedSuggestionBatch()
    var generation: UInt64 = 0
    var debounceTask: Task<Void, Never>?
    var generationTask: Task<Void, Never>?
    var focusPrewarmTask: Task<Void, Never>?
    var focusPrewarmFieldIdentity: String?
    /// A focus read right after a click or an app switch, so a newly focused
    /// field is prepared before the first keystroke instead of at the next
    /// (possibly backed-off) poll.
    var focusRefreshTask: Task<Void, Never>?
    var workspaceObserver: NSObjectProtocol?
    var hostPublishPollGeneration: UInt64 = 0
    var hostPublishPollTask: Task<Void, Never>?
    var wired = false
    var lastLatencyMilliseconds: Int?
    var lastAcceptedTail: AcceptedSuggestionTail?
    var lastAcceptanceAt: Date?
    /// When the keystroke that asked for the next suggestion was observed.
    var pendingKeystrokeUptime: UInt64?
    /// The latest accept, until the host field shows whether it arrived.
    var pendingInsertionCheck: CotypingInsertionCheck?
    /// Closes `pendingInsertionCheck` when no key or focus change does.
    var insertionCheckExpiryTask: Task<Void, Never>?
    /// How long an accept may wait to be read back. Tests shorten it.
    var insertionCheckExpiryMilliseconds = CotypingInsertionCheck.timeoutMilliseconds
    /// The latest accept while the next key could still take it back.
    var acceptAwaitingNextKey: (surface: String, uptimeNanoseconds: UInt64)?
    var pendingInsertionConsumedCount: Int?
    /// Tops up the visible suggestion while it is accepted or typed through.
    var extensionTask: Task<Void, Never>?
    /// Reads the field again just after an accept or a typed-through letter,
    /// so the ghost moves to the app's own caret as soon as the app shows them.
    var caretRefreshTask: Task<Void, Never>?
    var extensionGeneration: UInt64 = 0
    /// Set by Escape: no suggestions in this field until the time passes.
    var escapePause: (fieldAnchor: String, until: Date)?
    /// When the suggestion on screen was last shown, typed through or accepted from.
    var lastSuggestionActivity: ContinuousClock.Instant?
    /// Takes down a suggestion left alone, so a Tab pressed long afterwards
    /// reaches the app instead of the ghost.
    var suggestionExpiryTask: Task<Void, Never>?
    /// How long a suggestion may sit untouched, as in Cotypist. Tests shorten it.
    var idleSuggestionLifetimeMilliseconds = 60_000
    var suggestionAnchorCache = CotypingSuggestionAnchorCache()
    /// Fingerprint captured from the exact request currently in flight. Cache
    /// entries are recorded against this snapshot, not settings read after the
    /// model returns, so a mid-generation settings change cannot bless stale
    /// output for reuse under the new configuration.
    var activeSuggestionRequestFingerprint: String?
    var clipboardPrefaceMemo: CotypingClipboardPrefaceMemo?
    let spellChecker = CotypingSpellChecker()
    let clipboardProvider = CotypingClipboardProvider()
    let clipboardRelevanceFilter = CotypingClipboardRelevanceFilter()
    nonisolated static let hostPublishWaitCeilingMs = 400
    nonisolated static let hostPublishFirstPollIntervalMs = 10
    nonisolated static let hostPublishPollIntervalMs = 15
    nonisolated static let freshSnapshotReuseWindowMilliseconds = 30
    /// How long a finished suggestion waits for its caret to be found on
    /// screen before it is shown beside the field instead.
    nonisolated static let visualCaretWaitMilliseconds = 150

    init(
        engine: CotypingCompleting,
        settingsProvider: @escaping () -> AppSettings,
        learningStore: CotypingLearningStore,
        memoryContextProvider: @escaping (CotypingField, AppSettings) async -> CotypingMemoryContextProvider.Snapshot = { _, _ in .empty },
        isMeetingRecordingActive: @escaping () -> Bool = { false },
        selfBundleID: String? = Bundle.main.bundleIdentifier,
        stats: CotypingStatsStore? = nil
    ) {
        self.engine = engine
        self.learningStore = learningStore
        self.stats = stats ?? .shared
        self.settingsProvider = settingsProvider
        self.memoryContextProvider = memoryContextProvider
        self.isMeetingRecordingActive = isMeetingRecordingActive
        self.selfBundleID = selfBundleID
        self.focusTracker = CotypingFocusTracker()
        let suppressionController = CotypingInputSuppressionController()
        self.inputMonitor = CotypingInputMonitor(suppressionController: suppressionController)
        self.inputSourceMonitor = CotypingKeyboardInputSourceMonitor()
        self.overlay = CotypingOverlayController()
        self.inserter = CotypingInserter(suppressionController: suppressionController)
    }

    struct AcceptedSuggestionTail {
        var text: String
        var precedingText: String
    }

}

struct CotypingPrivacySettings: Equatable, Sendable {
    let appReadPolicy: CotypingAppReadPolicy
    let excludedDomains: [String]
    let memoryPolicy: CotypingMemoryContext.Policy
    let visibleContextPolicy: CotypingVisibleContext.Policy

    init(settings: AppSettings, selfBundleID: String?) {
        appReadPolicy = CotypingAppReadPolicy(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            selfBundleID: selfBundleID)
        excludedDomains = settings.cotypingExcludedDomainList
        memoryPolicy = CotypingMemoryContext.Policy(settings: settings)
        visibleContextPolicy = CotypingVisibleContext.Policy(settings: settings)
    }
}
