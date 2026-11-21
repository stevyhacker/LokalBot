import Foundation
import LaunchAtLogin

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

    func refresh() {
        let read = read
        schedule { read() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        let (read, write) = (read, write)
        schedule {
            write(enabled)
            return read()
        }
    }

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
