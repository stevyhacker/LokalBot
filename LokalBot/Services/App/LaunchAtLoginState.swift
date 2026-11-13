import Foundation
import LaunchAtLogin

/// Cached "Launch at login" registration for Settings.
///
/// `SMAppService.status` is a synchronous round trip to the service-management
/// daemon. `LaunchAtLogin.Toggle` bound it directly, and SwiftUI re-reads a
/// toggle's binding on every view-graph update while it is visible, so General
/// blocked the main thread thousands of times per minute. Reads and writes here
/// run off the main thread, one at a time, and only the latest result is
/// published.
@MainActor
final class LaunchAtLoginState: ObservableObject {
    static let shared = LaunchAtLoginState(
        read: { LaunchAtLogin.isEnabled },
        write: { LaunchAtLogin.isEnabled = $0 })

    @Published private(set) var isEnabled = false

    private let read: @Sendable () -> Bool
    private let write: @Sendable (Bool) -> Void
    private var generation = 0
    private var work: Task<Void, Never>?

    init(read: @escaping @Sendable () -> Bool, write: @escaping @Sendable (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    /// Picks up changes made in System Settings → Login Items.
    func refresh() {
        let read = read
        schedule { read() }
    }

    /// Shows the new value at once, then publishes what the system registered.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        let (read, write) = (read, write)
        schedule {
            write(enabled)
            return read()
        }
    }

    /// Completes once every scheduled read or write has finished.
    func settle() async {
        while let current = work {
            await current.value
            if work == current { return }
        }
    }

    private func schedule(_ operation: @escaping @Sendable () -> Bool) {
        generation += 1
        let current = generation
        let previous = work
        work = Task {
            await previous?.value
            let value = await Task.detached(priority: .userInitiated, operation: operation).value
            guard current == generation, isEnabled != value else { return }
            isEnabled = value
        }
    }
}
