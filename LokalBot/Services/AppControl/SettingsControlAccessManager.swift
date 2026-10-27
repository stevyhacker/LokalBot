import Combine
import Foundation

/// App-side owner of "Allow external agents to change LokalBot settings":
/// the Privacy marker plus the control socket, which exists only while the
/// grant is on.
@MainActor
final class SettingsControlAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false

    private let gate: SettingsControlGate
    private let makeHandler: @MainActor () -> AppControlServer.Handler
    private let onError: (String) -> Void
    private let onDisable: () -> Void
    private var server: AppControlServer?

    init(gate: SettingsControlGate,
         makeHandler: @escaping @MainActor () -> AppControlServer.Handler,
         onError: @escaping (String) -> Void = { _ in },
         onDisable: @escaping () -> Void = {}) {
        self.gate = gate
        self.makeHandler = makeHandler
        self.onError = onError
        self.onDisable = onDisable
    }

    var socketPath: String {
        AppControlSocket.path(controlDirectory: gate.controlDirectory)
    }

    func start() {
        isEnabled = gate.isEnabled
        if isEnabled { startServer() }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try gate.enable()
            } catch {
                onError("Could not allow settings access: \(error.localizedDescription)")
                return
            }
            isEnabled = true
            startServer()
        } else {
            gate.disable()
            isEnabled = false
            stop()
            // Requests already waiting go with the grant.
            onDisable()
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func startServer() {
        guard server == nil else { return }
        let server = AppControlServer(path: socketPath, handler: makeHandler())
        do {
            try server.start()
            self.server = server
        } catch {
            onError("Could not open the settings control socket: \(error.localizedDescription)")
        }
    }
}
