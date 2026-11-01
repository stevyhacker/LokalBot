import BackgroundTasks
import LocalAuthentication
import LokalBotCompanionKit
import Observation
import SwiftUI
import UserNotifications

/// Background refresh: iOS decides when; each run syncs if the Mac is reachable.
enum BackgroundRefresh {
    static let identifier = "me.dotenv.LokalBot.companion.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// A local notification when a question asked while the Mac was away gets
/// its answer. Nothing goes through a push server.
enum QueuedAnswerNotification {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func post(question: String, result: AskResult) {
        let content = UNMutableNotificationContent()
        content.title = "Your Mac answered"
        content.subtitle = question
        content.body = String(AskCitationParser.plainText(result.answer).prefix(180))
        content.sound = .default
        content.threadIdentifier = result.requestId
        let request = UNNotificationRequest(identifier: result.requestId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Optional app lock: Face ID, Touch ID or the passcode before the library is
/// shown, and a cover in the app switcher.
@MainActor @Observable
final class AppLock {
    private static let enabledKey = "companion.appLock"

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: AppLock.enabledKey) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    private(set) var isLocked: Bool = UserDefaults.standard.bool(forKey: AppLock.enabledKey)
    /// Covers the window while the app switcher takes its snapshot.
    private(set) var isObscured = false
    private var authenticating = false

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    var canLock: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard isEnabled else {
            isObscured = false
            return
        }
        switch phase {
        case .background:
            isLocked = true
            isObscured = true
        case .inactive:
            isObscured = true
        case .active:
            isObscured = false
            if isLocked { Task { await unlock() } }
        @unknown default:
            break
        }
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        let reason = "Unlock your LokalBot library"
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true {
            isLocked = false
        }
    }

    /// Turning the lock on asks once, so it can't lock someone out.
    func setEnabled(_ enabled: Bool) async {
        guard enabled else {
            isEnabled = false
            isLocked = false
            return
        }
        let context = LAContext()
        if (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on App Lock")) == true {
            isEnabled = true
        }
    }
}
