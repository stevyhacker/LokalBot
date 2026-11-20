import Foundation
import Sparkle

@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    static let publicKeyPlaceholder = "REPLACE_WITH_GENERATED_SPARKLE_PUBLIC_ED_KEY"
    private static let debugCheckOnLaunchArgument = "-lokalbot-check-for-updates-on-launch"

    private let updaterController: SPUStandardUpdaterController
    private(set) var isStarted = false

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    nonisolated static var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func start() {
        guard !isStarted else { return }
        guard Self.isUpdaterEnabledForThisBuild else {
            lokalbotLog("Sparkle disabled for dev build."); return
        }
        guard hasUsableConfiguration else {
            lokalbotLog("Sparkle not started: updater config incomplete (see RELEASING.md).")
            return
        }
        updaterController.startUpdater()
        isStarted = true
        lokalbotLog("Sparkle updater started.")
        if automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.debugCheckOnLaunchArgument) {
            checkForUpdates()
        }
        #endif
    }

    func checkForUpdates() {
        guard isStarted else {
            lokalbotLog("Ignoring manual update check; updater not started.")
            return
        }
        updaterController.checkForUpdates(nil)
    }

    private static var isUpdaterEnabledForThisBuild: Bool {
        #if LOKALBOT_DEV
        false
        #else
        true
        #endif
    }

    private var hasUsableConfiguration: Bool {
        guard let feed = configuredString("SUFeedURL"),
              let url = URL(string: feed), url.scheme != nil,
              !feed.contains("OWNER/REPO") else {
            lokalbotLog("Sparkle: missing/placeholder SUFeedURL.")
            return false
        }
        guard let key = configuredString("SUPublicEDKey"), key != Self.publicKeyPlaceholder else {
            lokalbotLog("Sparkle: missing/placeholder SUPublicEDKey.")
            return false
        }
        return true
    }

    private func configuredString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
