// Contains code ported from Cotabby (https://github.com/FuJacob/cotabby),
// copyright the Cotabby authors, under the GNU AGPL v3.0
// (LICENSES/AGPL-3.0.txt). Modified for LokalBot since 23 June 2026.
// See THIRD_PARTY_NOTICES.md.

import Combine
import Foundation

@MainActor
final class CotypingCoordinator: ObservableObject {
    @Published var state: CotypingState = .idle {
        didSet {
#if LOKALBOT_TEST_HOOKS
            if TestHooks.filmsAutocomplete, state != oldValue { lokalbotLog("film: cotyping \(state)") }
#endif
        }
    }
    @Published var isRunning = false
    @Published var lastSuggestion: String?
    @Published var acceptedWordCount = 0
    @Published var memoryContextSources: [String] = []
    @Published var memoryContextSearched = false

    let focusTracker: CotypingFocusTracker
    let inputMonitor: CotypingInputMonitor
    let inputSourceMonitor: CotypingKeyboardInputSourceMonitor
    let overlay: CotypingOverlayController
    let visualCaret = CotypingVisualCaret()
    let inserter: CotypingInserter
    let engine: CotypingCompleting
    let learningStore: CotypingLearningStore
    let stats: CotypingStatsStore
    let settingsProvider: () -> AppSettings
    let memoryContextProvider: (CotypingField, AppSettings) async -> CotypingMemoryContextProvider.Snapshot
    var activeMemoryContext = CotypingMemoryContextProvider.Snapshot.empty
    var memoryLookup = CotypingMemoryLookup()
    var activeVisibleContext: CotypingVisibleContext.Snapshot?
    let isMeetingRecordingActive: () -> Bool
    let selfBundleID: String?

    var config = CotypingConfiguration.standard
    var appliedPrivacySettings: CotypingPrivacySettings?
    var session: CotypingSession?
    var acceptedSuggestionBatch = CotypingAcceptedSuggestionBatch()
    var generation: UInt64 = 0
    var contextEpoch: UInt64 = 0
    var debounceTask: Task<Void, Never>?
    var generationTask: Task<Void, Never>?
    var focusPrewarmTask: Task<Void, Never>?
    var focusPrewarmFieldIdentity: String?
    var focusRefreshTask: Task<Void, Never>?
    var workspaceObserver: NSObjectProtocol?
    var returnObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    var lastModelWarmRequest: ContinuousClock.Instant?
    var hostPublishPollGeneration: UInt64 = 0
    var hostPublishPollTask: Task<Void, Never>?
    var wired = false
    var lastLatencyMilliseconds: Int?
    var lastAcceptedTail: AcceptedSuggestionTail?
    var lastAcceptanceAt: Date?
    var pendingKeystrokeUptime: UInt64?
    var pendingInsertionCheck: CotypingInsertionCheck?
    var insertionCheckExpiryTask: Task<Void, Never>?
    var insertionCheckExpiryMilliseconds = CotypingInsertionCheck.timeoutMilliseconds
    var acceptAwaitingNextKey: (surface: String, model: String, uptimeNanoseconds: UInt64)?
    var shownSuggestion: ShownSuggestion?
    var lastTypedKeyUptime: UInt64?
    var pendingInsertionConsumedCount: Int?
    var extensionTask: Task<Void, Never>?
    var caretRefreshTask: Task<Void, Never>?
    var extensionGeneration: UInt64 = 0
    var escapePause: (fieldAnchor: String, until: Date)?
    var lastSuggestionActivity: ContinuousClock.Instant?
    var suggestionExpiryTask: Task<Void, Never>?
    var idleSuggestionLifetimeMilliseconds = 60_000
    var suggestionAnchorCache = CotypingSuggestionAnchorCache()
    var activeSuggestionRequestFingerprint: String?
    var clipboardPrefaceMemo: CotypingClipboardPrefaceMemo?
    let spellChecker = CotypingSpellChecker()
    let clipboardProvider = CotypingClipboardProvider()
    let clipboardRelevanceFilter = CotypingClipboardRelevanceFilter()
    nonisolated static let hostPublishWaitCeilingMs = 400
    nonisolated static let hostPublishFirstPollIntervalMs = 10
    nonisolated static let hostPublishPollIntervalMs = 15
    nonisolated static let freshSnapshotReuseWindowMilliseconds = 30
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

    struct ShownSuggestion: Equatable {
        var surface: String
        var model: String
        var used = false
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
