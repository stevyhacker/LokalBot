import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics

nonisolated enum PermissionGuidanceStyle: Equatable, Sendable {
    case nativePrompt
    case guidedOverlay
}

nonisolated enum AppPermission: CaseIterable, Identifiable, Hashable, Sendable {
    case microphone
    case screenRecording
    case accessibility
    case inputMonitoring

    var id: Self { self }

    static let coreCases: [AppPermission] = [.microphone]

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var systemImageName: String {
        switch self {
        case .microphone: "mic.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard.fill"
        }
    }

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

    var onboardingFeature: String {
        switch self {
        case .microphone: "Meeting notes"
        case .screenRecording, .accessibility: "Your workday"
        case .inputMonitoring: "Autocomplete"
        }
    }

    var needsRelaunchAfterGrant: Bool {
        switch self {
        case .microphone: false
        case .screenRecording, .accessibility, .inputMonitoring: true
        }
    }

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

    func request() {
        switch self {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
    }

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

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published private(set) var granted: [AppPermission: Bool] = [:]

    @Published private(set) var turnedOff: Set<AppPermission> = []

    private(set) var grantedAtLaunch: [AppPermission: Bool] = [:]

    private var pollTimer: Timer?
    private var pollConsumers = 0

    private init() {
        refresh()
        grantedAtLaunch = granted
    }

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

    func request(_ permission: AppPermission) {
        permission.request()
        refresh()
    }

    func openSettings(for permission: AppPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    var allGranted: Bool {
        AppPermission.coreCases.allSatisfy { granted[$0] == true }
    }

    func startPolling() {
        pollConsumers += 1
        refresh()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        pollConsumers = max(0, pollConsumers - 1)
        guard pollConsumers == 0 else { return }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        task.environment = ProcessInfo.processInfo.environment
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
