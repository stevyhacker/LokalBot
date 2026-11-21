import Foundation
import AppKit
import UserNotifications

@MainActor
struct RecordingPromptRegistry {
    struct PendingPrompt {
        let expiresAt: Date
        let record: @MainActor () -> Void
        let unavailable: @MainActor () -> Void
    }

    private var prompts: [String: PendingPrompt] = [:]

    mutating func insert(identifier: String, expiresAt: Date,
                         unavailable: @escaping @MainActor () -> Void = {},
                         record: @escaping @MainActor () -> Void) {
        prompts[identifier] = PendingPrompt(expiresAt: expiresAt, record: record, unavailable: unavailable)
    }

    func contains(_ identifier: String) -> Bool {
        prompts[identifier] != nil
    }

    mutating func remove(_ identifier: String) -> PendingPrompt? {
        prompts.removeValue(forKey: identifier)
    }

    mutating func deliveryFailed(_ identifier: String, now: Date = Date()) {
        guard let prompt = remove(identifier), prompt.expiresAt > now else { return }
        prompt.unavailable()
    }

    mutating func removeAll() -> [String] {
        let identifiers = Array(prompts.keys)
        prompts.removeAll()
        return identifiers
    }

    mutating func removeExpired(now: Date) -> [String] {
        let identifiers = prompts.compactMap { identifier, prompt in
            prompt.expiresAt <= now ? identifier : nil
        }
        for identifier in identifiers {
            prompts.removeValue(forKey: identifier)
        }
        return identifiers
    }
}

@MainActor
final class RecordingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RecordingNotifier()

    private static let detectionCategory = "lokalbot.meeting-detected"
    private static let recordAction = "lokalbot.record-detected-meeting"
    private static let ignoreAction = "lokalbot.ignore-detected-meeting"

    private var pendingDetections = RecordingPromptRegistry()

    func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(
            identifier: Self.recordAction,
            title: "Record",
            options: [.foreground])
        let ignore = UNNotificationAction(
            identifier: Self.ignoreAction,
            title: "Ignore")
        let category = UNNotificationCategory(
            identifier: Self.detectionCategory,
            actions: [record, ignore],
            intentIdentifiers: [],
            options: [.customDismissAction])
        center.setNotificationCategories([category])
    }

    private static let healthReportPathKey = "lokalbot.health-report-path"

    func healthCheckFailed(summary: String, reportURL: URL) {
        post(title: "LokalBot health check failed", body: summary,
             userInfo: [Self.healthReportPathKey: reportURL.path])
    }

    private static let settingsApprovalKey = "lokalbot.settings-approval"

    func settingsApprovalRequested(_ request: SettingsApprovals.Request) {
        post(title: "Approve a settings change?",
             body: "\(request.caller) asks: \(request.headline). Review it in LokalBot.",
             identifier: Self.settingsApprovalIdentifier(request.id),
             userInfo: [Self.settingsApprovalKey: request.id.uuidString],
             undelivered: { WindowAccess.shared.open("settings-approval") })
    }

    func withdrawSettingsApproval(_ id: UUID) {
        removeNotifications(withIdentifiers: [Self.settingsApprovalIdentifier(id)])
    }

    private static func settingsApprovalIdentifier(_ id: UUID) -> String {
        "settings-approval-\(id.uuidString)"
    }

    private static let agentHandoffKey = "lokalbot.agent-handoff"

    var onOpenAgent: (@MainActor () -> Void)?

    func actionsHandedOff(count: Int, meetingTitle: String, started: Bool) {
        let title = switch (started, count) {
        case (true, 1): "An agent is working on your action"
        case (true, _): "Agents are working on \(count) of your actions"
        case (false, 1): "Your action is ready for Agent Mode"
        case (false, _): "\(count) of your actions are ready for Agent Mode"
        }
        post(title: title,
             body: started ? "From \(meetingTitle). Open Agent Mode to follow along."
                 : "From \(meetingTitle). Review and send each one in Agent Mode.",
             userInfo: [Self.agentHandoffKey: "1"])
    }

    func recordingStarted(title: String) {
        post(title: "Recording started", body: title)
    }

    func captureNeedsAttention(_ message: String) {
        post(title: "Recording needs attention", body: message)
    }

    func recordingStopped(title: String, duration: TimeInterval, willTranscribe: Bool,
                          waitingForModels: Bool = false, headline: String? = nil) {
        let minutes = max(1, Int(duration / 60))
        var body = "\(title) · \(minutes) min"
        if willTranscribe { body += " · transcribing…" }
        if waitingForModels { body += " · processes after models download" }
        post(title: headline ?? "Recording saved", body: body)
    }

    func meetingDetected(title: String,
                         expiresAfter: TimeInterval = 2 * 60,
                         onUnavailable: @escaping @MainActor () -> Void = {},
                         onRecord: @escaping @MainActor () -> Void) {
        purgeExpiredDetections()
        invalidateMeetingDetections()
        let identifier = "meeting-detected-\(UUID().uuidString)"
        pendingDetections.insert(
            identifier: identifier,
            expiresAt: Date().addingTimeInterval(expiresAfter),
            unavailable: onUnavailable,
            record: onRecord)
        post(
            title: "Meeting detected",
            body: "Record \(title)?",
            identifier: identifier,
            categoryIdentifier: Self.detectionCategory)
    }

    private func post(title: String,
                      body: String,
                      identifier: String = UUID().uuidString,
                      categoryIdentifier: String? = nil,
                      userInfo: [String: String] = [:],
                      undelivered: (@MainActor () -> Void)? = nil) {
        guard !UITestRuntime.isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if !userInfo.isEmpty { content.userInfo = userInfo }
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            var authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            if settings.authorizationStatus == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            }
            guard authorized else {
                pendingDetections.deliveryFailed(identifier)
                undelivered?()
                return
            }
            if categoryIdentifier == Self.detectionCategory,
               !pendingDetections.contains(identifier) {
                return
            }
            do {
                try await center.add(request)
            } catch {
                if categoryIdentifier == Self.detectionCategory {
                    pendingDetections.deliveryFailed(identifier)
                }
                undelivered?()
                return
            }
            if categoryIdentifier == Self.detectionCategory,
               !pendingDetections.contains(identifier) {
                removeNotifications(withIdentifiers: [identifier])
            }
        }
    }

    func invalidateMeetingDetections() {
        removeNotifications(withIdentifiers: pendingDetections.removeAll())
    }

    private func purgeExpiredDetections(now: Date = Date()) {
        removeNotifications(withIdentifiers: pendingDetections.removeExpired(now: now))
    }

    private func removeNotifications(withIdentifiers identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handle(response)
    }

    private func handle(_ response: UNNotificationResponse) {
        if let path = response.notification.request.content.userInfo[Self.healthReportPathKey] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        if response.notification.request.content.userInfo[Self.settingsApprovalKey] != nil {
            WindowAccess.shared.open("settings-approval")
            return
        }
        if response.notification.request.content.userInfo[Self.agentHandoffKey] != nil {
            onOpenAgent?()
            return
        }
        let identifier = response.notification.request.identifier
        guard let pending = pendingDetections.remove(identifier) else { return }
        guard response.actionIdentifier == Self.recordAction,
              pending.expiresAt > Date() else { return }
        pending.record()
    }
}
