import Combine
import Foundation
import IOKit.ps

@MainActor
final class PowerSourceMonitor: ObservableObject {
    @Published private(set) var isOnBattery = false
    @Published private(set) var isLowPower = false

    private static let pollInterval: TimeInterval = 30

    private var pollTimer: Timer?
    private var powerStateObserver: NSObjectProtocol?

    init() {
        refresh()
    }

    deinit {
        pollTimer?.invalidate()
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
        }
    }

    func start() {
        stop()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
    }

    private func refresh() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        isOnBattery = Self.readIsOnBattery()
    }

    nonisolated static func currentlyOnBattery() -> Bool {
        readIsOnBattery()
    }

    nonisolated static func hasBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    private static var limitedPowerSource: CFRunLoopSource?

    static func postSourceChanges() {
        guard limitedPowerSource == nil,
              let source = IOPSCreateLimitedPowerNotification({ _ in
                  NotificationCenter.default.post(name: .powerSourceDidChange, object: nil)
              }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        limitedPowerSource = source
    }

    private nonisolated static func readIsOnBattery() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let providing = IOPSGetProvidingPowerSourceType(snapshot) else {
            return false
        }
        let source = providing.takeUnretainedValue() as String
        return source != kIOPSACPowerValue
    }
}

extension Notification.Name {
    static let powerSourceDidChange = Notification.Name("LokalBotPowerSourceDidChange")
}
