import Combine
import SwiftUI

/// The AppState values `LokalBotApp` reads: window titles, the root text size,
/// the menu commands' titles and enablement, and the status item's recording
/// glyph. The App observes this instead of AppState. Observing AppState there
/// re-ran the App body, rebuilt every menu and re-evaluated every scene on
/// each AppState change, background ones such as processing progress included.
/// The values are read again after each AppState change and published only
/// when one of them differs.
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

        @MainActor init(_ app: AppState) {
            language = app.settings.appLanguage
            textSize = app.settings.textSize
            isRecording = app.isRecording
            isDictating = app.dictation.state.isRecording
            isDictationBusy = app.dictation.isStarting || app.dictation.state.isWorking
            agentActive = app.navSection == .agent
            canSearchSelectedMeeting = app.canSearchSelectedMeeting
        }
    }

    @Published private(set) var values: Values
    private weak var app: AppState?
    private var observer: AnyCancellable?
    private var refreshScheduled = false

    init(app: AppState) {
        self.app = app
        values = Values(app)
        // Subscribed synchronously: `receive(on:)` delivers its subscription
        // a turn late and would miss changes made in between.
        observer = app.objectWillChange.sink { [weak self] in self?.scheduleRefresh() }
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
        let next = Values(app)
        if next != values { values = next }
    }
}
