import Foundation
import Sparkle

/// Owns LokalBot's Sparkle integration and keeps the updater lifecycle out of
/// SwiftUI. Sparkle is side-effectful (network, persisted prefs, system UI), so
/// the rest of the app sees a tiny surface: `start()` once at launch and
/// `checkForUpdates()` from the Settings button.
///
/// Replaces the previous detection-only `UpdateChecker` (GitHub Releases probe).
/// Sparkle does signed, resumable, in-place updates from a notarized DMG via the
/// appcast, so there is no hand-rolled version compare or download banner here.
@MainActor
final class AppUpdateManager: ObservableObject {
    static let shared = AppUpdateManager()

    /// The placeholder shipped in Info.plist (`SUPublicEDKey`). Until the real
    /// ed25519 public key replaces it, `hasUsableConfiguration` is false and the
    /// updater never starts — a fresh clone can't accidentally self-update.
    static let publicKeyPlaceholder = "REPLACE_WITH_GENERATED_SPARKLE_PUBLIC_ED_KEY"
    private static let debugCheckOnLaunchArgument = "-lokalbot-check-for-updates-on-launch"

    /// Retained for the process lifetime — Sparkle expects its controller alive.
    private let updaterController: SPUStandardUpdaterController
    private(set) var isStarted = false

    private init() {
        // `startingUpdater: false` — the app decides when to start the updater,
        // rather than Sparkle doing network work during object construction.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// CFBundleShortVersionString of the running build (shown in Settings).
    nonisolated static var currentVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Sparkle's automatic-check preference, surfaced as a Settings toggle.
    /// New installs default on (`SUEnableAutomaticChecks=true` in Info.plist);
    /// changing this persists through Sparkle and overrides the bundled default.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Start Sparkle exactly once after launch. No-op on dev builds and when the
    /// feed/key are still placeholders, so the app stays inert until configured.
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
        // Background check on launch only when the user opted in. Sparkle's
        // scheduled interval covers long-running sessions; this covers users who
        // reopen within a day without creating opt-out network traffic.
        if automaticallyChecksForUpdates {
            updaterController.updater.checkForUpdatesInBackground()
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(Self.debugCheckOnLaunchArgument) {
            checkForUpdates()
        }
        #endif
    }

    /// Manual "Check for Updates…" — always presents a result dialog. Reserved
    /// for the explicit Settings button; launch uses the silent background check.
    func checkForUpdates() {
        guard isStarted else {
            lokalbotLog("Ignoring manual update check; updater not started.")
            return
        }
        updaterController.checkForUpdates(nil)
    }

    /// Compiled to `false` in the dev configuration (LOKALBOT_DEV), which ships a
    /// distinct bundle id the prod appcast must never replace.
    private static var isUpdaterEnabledForThisBuild: Bool {
        #if LOKALBOT_DEV
        false
        #else
        true
        #endif
    }

    /// True only when both the feed URL and public key are real (not the shipped
    /// placeholders). Mirrors the old `UpdateChecker.releasesURL == nil` gate.
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
