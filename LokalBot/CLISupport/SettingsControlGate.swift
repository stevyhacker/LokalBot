import Foundation

enum SettingsControlError: LocalizedError {
    case disabled

    var errorDescription: String? {
        switch self {
        case .disabled:
            SettingsControlGate.disabledMessage
        }
    }
}

/// Cross-process marker for "Allow external agents to change LokalBot
/// settings". Only the app writes it, from the Privacy toggle.
///
/// Like `ScreenMemoryAccessGate`, this is deliberately separate: meeting or
/// screen access never grants settings access, and this grant never grants
/// either of them.
struct SettingsControlGate {
    static let markerName = "settings-control-enabled"

    static let disabledMessage =
        "External settings access is off. Enable it in LokalBot → Settings → Privacy → " +
        "\"Allow external agents to change LokalBot settings\"."

    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL {
        root.appendingPathComponent("control", isDirectory: true)
    }

    var markerURL: URL {
        controlDirectory.appendingPathComponent(Self.markerName)
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    func requireAuthorized() throws {
        guard isEnabled else { throw SettingsControlError.disabled }
    }

    func enable() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // An existing shared control directory keeps its old mode otherwise.
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: controlDirectory.path)
        try Data(UUID().uuidString.utf8).write(to: markerURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: markerURL.path)
    }

    func disable() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
