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

    let focusTracker: CotypingFocusTracker
    let inputMonitor: CotypingInputMonitor
    let inputSourceMonitor: CotypingKeyboardInputSourceMonitor
    let overlay: CotypingOverlayController
    let inserter: CotypingInserter
    let engine: CotypingCompleting
    let learningStore: CotypingLearningStore
    let settingsProvider: () -> AppSettings
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
    var hostPublishPollGeneration: UInt64 = 0
    var hostPublishPollTask: Task<Void, Never>?
    var wired = false
    var lastLatencyMilliseconds: Int?
    var pendingStreamPartial: PendingStreamPartial?
    var streamValidationTask: Task<Void, Never>?
    var streamValidationGeneration: UInt64 = 0
    /// The visible session came from this still-running stream. The first accept
    /// freezes that exact reviewed prefix and invalidates the stream so a later
    /// final callback cannot reset consumedCount or re-offer accepted text.
    var streamAcceptanceFence = CotypingStreamAcceptanceFence()
    var lastAcceptedTail: AcceptedSuggestionTail?
    var lastAcceptanceAt: Date?
    var pendingInsertionConsumedCount: Int?
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
    nonisolated static let hostPublishPollIntervalMs = 30
    nonisolated static let freshSnapshotReuseWindowMilliseconds = 30

    init(
        engine: CotypingCompleting,
        settingsProvider: @escaping () -> AppSettings,
        learningStore: CotypingLearningStore,
        isMeetingRecordingActive: @escaping () -> Bool = { false },
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.engine = engine
        self.learningStore = learningStore
        self.settingsProvider = settingsProvider
        self.isMeetingRecordingActive = isMeetingRecordingActive
        self.selfBundleID = selfBundleID
        self.focusTracker = CotypingFocusTracker()
        let suppressionController = CotypingInputSuppressionController()
        self.inputMonitor = CotypingInputMonitor(suppressionController: suppressionController)
        self.inputSourceMonitor = CotypingKeyboardInputSourceMonitor()
        self.overlay = CotypingOverlayController()
        self.inserter = CotypingInserter(suppressionController: suppressionController)
    }

    struct PendingStreamPartial {
        var result: CotypingNormalizationResult
        var work: UInt64
        var field: CotypingField
    }

    struct AcceptedSuggestionTail {
        var text: String
        var precedingText: String
    }

}

struct CotypingPrivacySettings: Equatable, Sendable {
    let appReadPolicy: CotypingAppReadPolicy
    let excludedDomains: [String]

    init(settings: AppSettings, selfBundleID: String?) {
        appReadPolicy = CotypingAppReadPolicy(
            enabled: settings.cotypingEnabled,
            excludedApps: settings.cotypingExcludedAppList,
            selfBundleID: selfBundleID)
        excludedDomains = settings.cotypingExcludedDomainList
    }
}

/// Tracks whether the currently visible session is backed by an in-flight
/// stream. Consuming the fence is one-shot: the first accept freezes that
/// reviewed partial, while later accepts operate on the already-frozen session.
struct CotypingStreamAcceptanceFence: Equatable, Sendable {
    private(set) var presentedWork: UInt64?

    mutating func markPresented(work: UInt64) {
        presentedWork = work
    }

    mutating func consumeForAcceptance() -> UInt64? {
        defer { presentedWork = nil }
        return presentedWork
    }

    mutating func reset() {
        presentedWork = nil
    }
}
