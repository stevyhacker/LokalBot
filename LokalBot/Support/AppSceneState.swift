import Combine
import SwiftUI

/// The AppState values `LokalBotApp` reads: window titles, the root text size,
/// the menu commands' titles and enablement, and the status item's glyph
/// (recording, day memory paused, something needs attention). The App
/// observes this instead of AppState. Observing AppState there re-ran the App
/// body, rebuilt every menu and re-evaluated every scene on each AppState
/// change, background ones such as processing progress included. The values
/// are read again after each AppState change and published only when one of
/// them differs.
@MainActor
final class AppSceneState: ObservableObject {
    struct Values: Equatable {
        var language: AppLanguage
        var textSize: AppTextSize
        var isRecording: Bool
        var isDictating: Bool
        var isDictationBusy: Bool
        var agentActive: Bool
        var canSearchSelectedMeeting: Bool
        /// Day memory is on and paused for now: the status item dims.
        var dayMemoryPaused: Bool
        /// Something waits for the person (`MenuBarAttention`): the status
        /// item carries a dot.
        var needsAttention: Bool

        @MainActor init(_ app: AppState, corePermissionsGranted: Bool = true) {
            language = app.settings.appLanguage
            textSize = app.settings.textSize
            isRecording = app.isRecording
            isDictating = app.dictation.state.isRecording
            isDictationBusy = app.dictation.isStarting || app.dictation.state.isWorking
            agentActive = app.navSection == .agent
            canSearchSelectedMeeting = app.canSearchSelectedMeeting
            dayMemoryPaused = app.settings.trackingEnabled && app.dayMemoryPaused
            needsAttention = !app.menuBarAttention(corePermissionsGranted: corePermissionsGranted).isEmpty
        }
    }

    @Published private(set) var values: Values
    private weak var app: AppState?
    /// Nil in unit tests, which then read the microphone as granted whatever
    /// the test host was granted.
    private let permissions: PermissionManager?
    private var observers: Set<AnyCancellable> = []
    private var refreshScheduled = false

    init(app: AppState, permissions: PermissionManager? = nil) {
        self.app = app
        self.permissions = permissions
        values = Values(app, corePermissionsGranted: permissions?.allGranted ?? true)
        // Subscribed synchronously: `receive(on:)` delivers its subscription
        // a turn late and would miss changes made in between.
        app.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &observers)
        // AppState does not republish these two, and the attention dot reads both.
        app.settingsApprovals.$pending.dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
        permissions?.$granted.dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
    }

    /// objectWillChange fires before the change lands, so read on the next
    /// main-queue turn, once for a whole burst of changes.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        refreshScheduled = false
        guard let app else { return }
        let next = Values(app, corePermissionsGranted: permissions?.allGranted ?? true)
        if next != values { values = next }
    }
}

extension AppState {
    /// Everything the menu bar asks the person to fix right now, in the
    /// order the panel lists it.
    func menuBarAttention(corePermissionsGranted: Bool) -> [MenuBarAttention] {
        MenuBarAttention.items(
            micRecoveryNeeded: micRecoveryNeeded,
            corePermissionsGranted: corePermissionsGranted,
            lastError: lastError,
            pendingApprovals: settingsApprovals.pending.count)
    }
}
