import Foundation
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

/// Local notifications that announce recording start/stop, so the user knows a
/// meeting is being captured without keeping the window open. This is the
/// "push" half of the menu-bar-only experience; the always-visible menu bar
/// timer is the "pull" half.
///
/// Authorization is requested lazily the first time a recording actually
/// starts — a new user is never hit with a notification prompt before they've
/// done anything, and if they decline, the menu bar timer still covers the
/// "is it recording?" question.
@MainActor
final class RecordingNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RecordingNotifier()

    private static let detectionCategory = "lokalbot.meeting-detected"
    private static let recordAction = "lokalbot.record-detected-meeting"
    private static let ignoreAction = "lokalbot.ignore-detected-meeting"

    private var pendingDetections = RecordingPromptRegistry()

    /// Install the foreground-presentation delegate. Called once at launch from
    /// the interactive (non-headless, non-UI-test) path.
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

    func recordingStarted(title: String) {
        post(title: "Recording started", body: title)
    }

    func recordingStopped(title: String, duration: TimeInterval, willTranscribe: Bool,
                          waitingForModels: Bool = false) {
        let minutes = max(1, Int(duration / 60))
        var body = "\(title) · \(minutes) min"
        if willTranscribe { body += " · transcribing…" }
        if waitingForModels { body += " · processes after models download" }
        post(title: "Recording saved", body: body)
    }

    /// Posts a real, actionable prompt for `.ask` recording mode. The action
    /// expires so clicking an old notification cannot begin capturing an
    /// unrelated meeting hours later.
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
                      categoryIdentifier: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        // `trigger: nil` delivers immediately. A fresh identifier each time so a
        // start and a stop don't coalesce into one another.
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
                return
            }
            // `add` suspends. A meeting can end while the notification center
            // is accepting the request, after invalidation already tried to
            // remove it. Clean up the newly added request on resume as well.
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

    // Show the banner even when LokalBot happens to be the active app (e.g. the
    // window is open), instead of silently dropping it.
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
        let identifier = response.notification.request.identifier
        guard let pending = pendingDetections.remove(identifier) else { return }
        guard response.actionIdentifier == Self.recordAction,
              pending.expiresAt > Date() else { return }
        pending.record()
    }
}
