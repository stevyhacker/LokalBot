import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// The macOS privacy permissions LokalBot can use. System-audio capture rides
/// on the `com.apple.security.device.audio-input` entitlement, so it is not a
/// TCC prompt and is intentionally absent here.
///
/// Pure metadata plus stateless TCC reads: the enum stays off `@MainActor` so
/// its logic (titles, grant checks) is unit-testable on any thread, while the
/// observable cache lives on `PermissionManager`.
nonisolated enum PermissionGuidanceStyle: Equatable, Sendable {
    case nativePrompt
    case guidedOverlay
}

nonisolated enum AppPermission: CaseIterable, Identifiable, Hashable, Sendable {
    case microphone
    case screenRecording
    case accessibility
    /// Cotyping only — detects keystrokes and consumes the accept key.
    case inputMonitoring

    var id: Self { self }

    /// The only permission required to finish onboarding: the microphone, which
    /// the core promise (record your side of a call) cannot work without.
    /// Everything else is requested at the moment its feature is enabled —
    /// Accessibility when day tracking or cotyping turns on (it also improves
    /// browser-meeting detection), Screen Recording when screenshots turn on,
    /// Input Monitoring when the dictation/cotyping shortcuts arm.
    static let coreCases: [AppPermission] = [.microphone]

    /// System-Settings-style label.
    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    /// SF Symbol used by onboarding, settings, and permission repair surfaces.
    var systemImageName: String {
        switch self {
        case .microphone: "mic.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard.fill"
        }
    }

    /// One-line reason beside the permission in setup. Accessibility reads
    /// only window titles while the workday keeps app names only.
    func onboardingReason(readsScreenText: Bool = true) -> String {
        switch self {
        case .microphone:
            "Records your side of each call."
        case .screenRecording:
            "Takes the screenshots, which stay encrypted on this Mac."
        case .accessibility:
            readsScreenText ? "Reads window titles and the text on screen."
                : "Reads the title of the window you are using."
        case .inputMonitoring:
            "Lets dictation and cotyping detect their global keyboard shortcuts."
        }
    }

    /// The setup choice this permission serves, shown as a tag on its row.
    var onboardingFeature: String {
        switch self {
        case .microphone: "Meeting notes"
        case .screenRecording, .accessibility: "Your workday"
        case .inputMonitoring: "Autocomplete"
        }
    }

    /// A grant made while LokalBot runs reaches these only at the next launch.
    var needsRelaunchAfterGrant: Bool {
        switch self {
        case .microphone: false
        case .screenRecording, .accessibility, .inputMonitoring: true
        }
    }

    /// Microphone access is granted through Apple's modal prompt. The other
    /// privacy lists accept an application bundle, so LokalBot can provide the
    /// same draggable-app walkthrough as Cotabby.
    var guidanceStyle: PermissionGuidanceStyle {
        switch self {
        case .microphone:
            .nativePrompt
        case .screenRecording, .accessibility, .inputMonitoring:
            .guidedOverlay
        }
    }

    var guidanceHint: String {
        switch guidanceStyle {
        case .nativePrompt:
            "Shows the macOS permission prompt. If access was denied, opens the correct Settings pane."
        case .guidedOverlay:
            "Opens the correct Settings pane and shows a draggable LokalBot app row."
        }
    }

    /// One-sentence rationale shown beside each permission row.
    var why: String {
        switch self {
        case .microphone:
            "Records your side of the meeting from the microphone."
        case .screenRecording:
            "Captures encrypted visuals for day memory. Only used in Text + visual context mode; system-audio capture does not use this permission."
        case .accessibility:
            "Reads window titles and visible interface text for activity and text-context features."
        case .inputMonitoring:
            "Lets dictation and cotyping detect their global keyboard shortcuts."
        }
    }

    /// Real TCC state, queried without ever prompting the user.
    ///
    /// Screen Recording uses the *preflight* probe rather than
    /// `CGRequestScreenCaptureAccess` precisely so that reading status can never
    /// surface the system dialog as a side effect.
    var isGranted: Bool {
        switch self {
        case .microphone:
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording:
            CGPreflightScreenCaptureAccess()
        case .accessibility:
            AXIsProcessTrusted()
        case .inputMonitoring:
            CGPreflightListenEventAccess()
        }
    }

    /// macOS will not show the microphone prompt again after an explicit
    /// denial. Onboarding uses this to replace a misleading Allow button with
    /// a direct, clearly labelled recovery path.
    var requiresSettingsRecovery: Bool {
        guard self == .microphone else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return true
        case .notDetermined, .authorized:
            return false
        @unknown default:
            return true
        }
    }

    /// Fires the native permission prompt. This is a no-op once the system has
    /// already decided (a denied permission can only be changed in System
    /// Settings), so callers pair it with `PermissionManager.openSettings(for:)`.
    func request() {
        switch self {
        case .microphone:
            // Empty completion on purpose: the grant arrives asynchronously and
            // is surfaced through `PermissionManager.granted`, not this callback.
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            // `prompt: true` shows the "Open System Settings" dialog on first ask.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

    /// Deep link to this permission's System Settings pane. Optional because
    /// `URL(string:)` is failable; callers skip opening when it is `nil`.
    var settingsURL: URL? {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .screenRecording: pane = "Privacy_ScreenCapture"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

/// Single source of truth for LokalBot's permission state.
///
/// Folds the three ad-hoc TCC checks once scattered across views and services
/// into one observable cache so every surface reads the same value. A short poll
/// is the only way to notice a grant the user just made over in System Settings
/// (TCC posts no change notification), so the manager exposes explicit
/// `startPolling()`/`stopPolling()` driven by the permissions UI's lifecycle —
/// an established user pays zero idle main-thread wakeups once that UI is closed.
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    /// Cached grant state, refreshed by `refresh()` and the poll. Published so
    /// SwiftUI surfaces redraw the moment a permission flips.
    @Published private(set) var granted: [AppPermission: Bool] = [:]

    /// Permissions macOS will not ask for again because they were refused:
    /// only System Settings can turn them on.
    @Published private(set) var turnedOff: Set<AppPermission> = []

    /// What was granted when this launch first read the permissions. A
    /// permission granted since then may need a relaunch to take effect.
    private(set) var grantedAtLaunch: [AppPermission: Bool] = [:]

    private var pollTimer: Timer?
    private var pollConsumers = 0

    private init() {
        refresh()
        grantedAtLaunch = granted
    }

    /// Re-reads every permission and republishes only on a real change. TCC
    /// reads are cheap, but `@Published` fires on assignment even when the value
    /// is identical, so the diff avoids redrawing surfaces on every poll tick.
    func refresh() {
        var latest: [AppPermission: Bool] = [:]
        latest.reserveCapacity(AppPermission.allCases.count)
        for permission in AppPermission.allCases {
            latest[permission] = permission.isGranted
        }
        if latest != granted {
            granted = latest
        }
        let refused = Set(AppPermission.allCases.filter(\.requiresSettingsRecovery))
        if refused != turnedOff {
            turnedOff = refused
        }
    }

    /// Triggers the native prompt for `permission`, then refreshes so any
    /// synchronous grant (Accessibility, Screen Recording) is reflected at once.
    /// The asynchronous microphone grant is picked up by the next poll tick.
    func request(_ permission: AppPermission) {
        permission.request()
        refresh()
    }

    /// Opens System Settings straight to `permission`'s pane.
    func openSettings(for permission: AppPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether every onboarding-required permission (just the microphone) is
    /// currently granted. Optional grants never block this.
    var allGranted: Bool {
        AppPermission.coreCases.allSatisfy { granted[$0] == true }
    }

    /// Adds one permission-surface consumer and arms a ~1.5s catch-up poll so the
    /// UI reflects grants made over in System Settings.
    func startPolling() {
        pollConsumers += 1
        refresh()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Releases one polling consumer. The timer survives while another permission
    /// surface is still visible, then tears down once the last one disappears.
    func stopPolling() {
        pollConsumers = max(0, pollConsumers - 1)
        guard pollConsumers == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Re-launches LokalBot. Accessibility grants only take effect at process
    /// launch, so granting it mid-session needs a restart to apply. Spawns a
    /// fresh instance via `open -n`, then terminates this one a beat later.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        task.environment = ProcessInfo.processInfo.environment
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
