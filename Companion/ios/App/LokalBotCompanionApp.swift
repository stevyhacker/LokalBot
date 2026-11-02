import LokalBotCompanionKit
import SwiftUI

@main
struct LokalBotCompanionApp: App {
    @State private var environment = AppEnvironment.make()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        let environment = environment
        WindowGroup {
            DemoLaunch.Frame { RootView() }
                .environment(environment.session)
                .environment(environment.navigator)
                .environment(environment.appLock)
                .task { await environment.start() }
        }
        .commands { CompanionCommands() }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await environment.backgroundRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            environment.scenePhaseChanged(phase)
        }

        // A meeting in its own window (iPad).
        WindowGroup("Meeting", id: MeetingWindow.id, for: String.self) { $meetingID in
            MeetingWindow(meetingID: meetingID)
                .environment(environment.session)
                .environment(environment.navigator)
                .environment(environment.appLock)
        }
    }
}

/// Everything the scenes share: the store and session, navigation, discovery
/// and the app lock.
@MainActor
final class AppEnvironment {
    let session: CompanionSession
    let navigator = AppNavigator()
    let appLock = AppLock()
    let discovery = MacDiscovery()
    private var started = false
    private var foregroundSync: Task<Void, Never>?

    init(session: CompanionSession) {
        self.session = session
        session.discoverAddresses = { [discovery, weak session] in
            let fingerprint = session?.pairedMac.flatMap { KeyFingerprint.fingerprint(base64Key: $0.macKeyB64) }
            return await discovery.addresses(preferringFingerprint: fingerprint)
        }
        session.onQueuedAnswer = { request, result in
            QueuedAnswerNotification.post(question: request.question, result: result)
        }
    }

    static func make() -> AppEnvironment {
        AppEnvironment(session: CompanionSession(store: StoreFactory.makeStore()))
    }

    func start() async {
        guard !started else { return }
        started = true
        await StoreFactory.prepare(session)
        await session.start()
        DemoLaunch.apply(to: self)
        await DemoLaunch.exercise(self)
        await session.syncNow()
    }

    /// Sync on return to the foreground and every few minutes while open;
    /// schedule background refresh on the way out.
    func scenePhaseChanged(_ phase: ScenePhase) {
        appLock.scenePhaseChanged(phase)
        switch phase {
        case .active:
            foregroundSync?.cancel()
            foregroundSync = Task { [session] in
                while !Task.isCancelled {
                    await session.syncNow()
                    try? await Task.sleep(for: .seconds(180))
                }
            }
        case .background:
            foregroundSync?.cancel()
            if session.mode == .paired { BackgroundRefresh.schedule() }
        default:
            break
        }
    }

    func backgroundRefresh() async {
        BackgroundRefresh.schedule()
        await session.syncNow()
    }
}
