import AppKit
import Foundation

/// Keeps the first suggestion after a pause about as quick as one while
/// typing. A loaded in-process model that sits unused goes cold: llama.cpp
/// stops holding its weights resident three minutes after the last decode,
/// and the system then pages or compresses them. On 2026-10-06 the first
/// suggestion after half an hour took 1.9 s against 62 ms while typing.
///
/// Any key or click the input monitor sees, and the screen waking or
/// unlocking, asks the engine to run one throwaway token if the model has not
/// run for a while (`LocalLlamaCotypingEngine.warmAfterIdle`). While the person
/// keeps using the Mac this also renews llama.cpp's keep-alive, so the weights
/// stay ready until they step away; a click or an unlock on their return
/// readies them before the first key.
extension CotypingCoordinator {
    /// How often activity may ask the engine at all. The engine then decides
    /// whether the model has been idle long enough to need a token, so a key
    /// while typing costs one clock read here.
    nonisolated static let modelWarmRequestInterval: Duration = .seconds(5)

    func warmModelAfterPause(now: ContinuousClock.Instant = .now) {
        guard isRunning, !isMeetingRecordingActive() else { return }
        if let lastModelWarmRequest, lastModelWarmRequest.duration(to: now) < Self.modelWarmRequestInterval {
            return
        }
        lastModelWarmRequest = now
        Task { [engine] in await engine.warmAfterPause() }
    }

    /// The person is probably back: the screen woke, the Mac woke, the
    /// session became active again, or the screen was unlocked.
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
