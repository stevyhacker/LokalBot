import LokalBotCompanionKit
import SwiftUI
import UIKit

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
                .environment(environment.recording)
                .task { await environment.start() }
        }
        .commands { CompanionCommands() }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await environment.backgroundRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            environment.scenePhaseChanged(phase)
        }

        WindowGroup("Meeting", id: MeetingWindow.id, for: String.self) { $meetingID in
            MeetingWindow(meetingID: meetingID)
                .environment(environment.session)
                .environment(environment.navigator)
                .environment(environment.appLock)
        }
    }
}

@MainActor
private final class BackgroundHold {
    var task = UIBackgroundTaskIdentifier.invalid

    nonisolated func end() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.task != .invalid else { return }
                UIApplication.shared.endBackgroundTask(self.task)
                self.task = .invalid
            }
        }
    }
}

@MainActor
final class AppEnvironment {
    let session: CompanionSession
    let navigator = AppNavigator()
    let appLock = AppLock()
    let recording: RecordingModel
    let discovery = MacDiscovery()
    private var started = false
    private var foregroundSync: Task<Void, Never>?

    init(session: CompanionSession) {
        self.session = session
        recording = RecordingModel(session: session, capture: DemoLaunch.capture())
        session.holdWhileUploading = {
            let application = UIApplication.shared
            let hold = BackgroundHold()
            hold.task = application.beginBackgroundTask(withName: "Send recording") { hold.end() }
            return { hold.end() }
        }
        recording.onInterrupted = { RecordingPausedNotification.post() }
        recording.onResumed = { RecordingPausedNotification.clear() }
        session.discoverAddresses = { [discovery, weak session] in
            let fingerprint = session?.pairedMac.flatMap { KeyFingerprint.fingerprint(base64Key: $0.macKeyB64) }
            return await discovery.addresses(preferringFingerprint: fingerprint)
        }
        session.onQueuedAnswer = { [appLock] request, result in
            QueuedAnswerNotification.post(question: request.question, result: result, appLockOn: appLock.isEnabled)
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

    func scenePhaseChanged(_ phase: ScenePhase) {
        appLock.scenePhaseChanged(phase)
        switch phase {
        case .active:
            recording.resume()
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
