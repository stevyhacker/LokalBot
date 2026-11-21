import Combine
import SwiftUI

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
        var dayMemoryPaused: Bool
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
    private let permissions: PermissionManager?
    private var observers: Set<AnyCancellable> = []
    private var refreshScheduled = false

    init(app: AppState, permissions: PermissionManager? = nil) {
        self.app = app
        self.permissions = permissions
        values = Values(app, corePermissionsGranted: permissions?.allGranted ?? true)
        app.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }.store(in: &observers)
        app.settingsApprovals.$pending.dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
        permissions?.$granted.dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
    }

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
    func menuBarAttention(corePermissionsGranted: Bool) -> [MenuBarAttention] {
        MenuBarAttention.items(
            micRecoveryNeeded: micRecoveryNeeded,
            corePermissionsGranted: corePermissionsGranted,
            lastError: lastError,
            pendingApprovals: settingsApprovals.pending.count)
    }
}
