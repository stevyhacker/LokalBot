import BackgroundTasks
import LocalAuthentication
import LokalBotCompanionKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

enum BackgroundRefresh {
    static let identifier = "me.dotenv.LokalBot.companion.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

enum QueuedAnswerNotification {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func post(question: String, result: AskResult, appLockOn: Bool) {
        let banner = QueuedAnswerBanner(question: question, answer: result.answer, appLockOn: appLockOn)
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.subtitle = banner.subtitle
        content.body = banner.body
        content.sound = .default
        content.threadIdentifier = result.requestId
        let request = UNNotificationRequest(identifier: result.requestId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

enum RecordingPausedNotification {
    private static let identifier = "recording-paused"

    static func post() {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recording paused"
        content.body = "Another app is using the microphone. Open LokalBot to carry on. What's recorded so far is saved."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    static func clear() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

@MainActor @Observable
final class AppLock {
    private static let enabledKey = "companion.appLock"

    private var policy: AppLockPolicy {
        didSet {
            if policy.isEnabled != oldValue.isEnabled {
                UserDefaults.standard.set(policy.isEnabled, forKey: Self.enabledKey)
            }
            covers.refresh()
        }
    }

    var isEnabled: Bool {
        get { policy.isEnabled }
        set {
            policy.applyEnableChange(enabled: newValue, authenticated: true)
        }
    }
    var isLocked: Bool { policy.isLocked }
    var isObscured: Bool { policy.isObscured }
    private var authenticating = false
    @ObservationIgnored private let covers = LockCoverWindows()

    init() {
        policy = AppLockPolicy(isEnabled: UserDefaults.standard.bool(forKey: Self.enabledKey))
        covers.attach(to: self)
    }

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
        let mapped: AppLockPolicy.Phase
        switch phase {
        case .background: mapped = .background
        case .inactive: mapped = .inactive
        case .active: mapped = .active
        @unknown default: return
        }
        if policy.transition(to: mapped) {
            Task { await unlock() }
        }
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        let reason = "Unlock your LokalBot library"
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
        policy.finishUnlock(succeeded: ok)
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled else {
            policy.applyEnableChange(enabled: false, authenticated: false)
            return
        }
        let context = LAContext()
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on App Lock")) == true
        policy.applyEnableChange(enabled: true, authenticated: ok)
    }
}
