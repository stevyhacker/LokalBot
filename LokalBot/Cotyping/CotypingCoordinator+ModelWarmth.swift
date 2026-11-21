import AppKit
import Foundation

extension CotypingCoordinator {
    nonisolated static let modelWarmRequestInterval: Duration = .seconds(5)

    func warmModelAfterPause(now: ContinuousClock.Instant = .now) {
        guard isRunning, !isMeetingRecordingActive() else { return }
        if let lastModelWarmRequest, lastModelWarmRequest.duration(to: now) < Self.modelWarmRequestInterval {
            return
        }
        lastModelWarmRequest = now
        Task { [engine] in await engine.warmAfterPause() }
    }

    func observeReturnToTheMac() {
        guard returnObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let signals: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        returnObservers = signals.map { center, name in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.warmModelAfterPause() }
            }
            return (center, token)
        }
    }

    func stopObservingReturnToTheMac() {
        for observer in returnObservers {
            observer.center.removeObserver(observer.token)
        }
        returnObservers = []
    }
}
