import Combine
import Foundation

/// App-side owner of the Files grant (Settings → External Agents).
/// While it is on and Files is on with a folder, the app keeps
/// `control/files-access.json` listing the chosen folders, so `lokalbot-cli`
/// and its MCP server can search the Files index without the app running and
/// without reading the app's settings. Anything else removes that list.
@MainActor
final class FilesAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var lastError: String?

    private let gate: FilesAccessGate
    /// The folders Files reads, or nil while Files is off.
    private let folders: () -> [String]?
    private let now: () -> Date

    init(gate: FilesAccessGate, folders: @escaping () -> [String]?, now: @escaping () -> Date = Date.init) {
        self.gate = gate
        self.folders = folders
        self.now = now
    }

    func start() {
        isEnabled = gate.isEnabled
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try gate.enable()
            } catch {
                lastError = "LokalBot couldn't turn on file access: \(error.localizedDescription)"
                return
            }
            isEnabled = true
            refresh()
        } else {
            gate.disable()
            isEnabled = false
            lastError = nil
        }
    }

    /// Files' settings changed: rewrite the folder list, or remove it.
    func refresh() {
        guard gate.isEnabled, let chosen = folders(), !chosen.isEmpty else {
            gate.removeProjection()
            return
        }
        if gate.readProjection()?.folders == chosen {
            lastError = nil
            return
        }
        do {
            try gate.writeProjection(FilesAccessProjection(generatedAt: now(), folders: chosen))
            lastError = nil
        } catch {
            gate.removeProjection()
            lastError = "LokalBot couldn't update which folders agents can search: \(error.localizedDescription)"
        }
    }
}
