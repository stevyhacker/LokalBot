import Combine
import Foundation

enum ScreenMemoryAccessError: LocalizedError {
    case disabled

    var errorDescription: String? {
        switch self {
        case .disabled:
            FileLibraryToolProvider.screenAccessDisabledMessage
        }
    }
}

struct ScreenMemoryAccessProfile: Codable, Equatable, Sendable {
    enum Scope: String, Codable, CaseIterable, Identifiable, Sendable {
        case today
        case recentWeek
        case retainedHistory

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .today: "Today only"
            case .recentWeek: "Last 7 days"
            case .retainedHistory: "All retained history"
            }
        }

        var detail: String {
            switch self {
            case .today:
                "Agents can read only context captured since local midnight."
            case .recentWeek:
                "Agents can read context from the rolling last seven days."
            case .retainedHistory:
                "Agents can read everything still inside the configured retention window."
            }
        }
    }

    var scope: Scope = .recentWeek

    static let safeDefault = ScreenMemoryAccessProfile(scope: .recentWeek)
    static let legacyUnscoped = ScreenMemoryAccessProfile(scope: .retainedHistory)
}

struct ScreenMemoryAccessGate {
    static let markerName = "screen-memory-access-enabled"

    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL {
        root.appendingPathComponent("control", isDirectory: true)
    }

    var accessMarkerURL: URL {
        controlDirectory.appendingPathComponent(Self.markerName)
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: accessMarkerURL.path)
    }

    var profile: ScreenMemoryAccessProfile {
        guard let data = try? Data(contentsOf: accessMarkerURL), !data.isEmpty else {
            return .legacyUnscoped
        }
        return (try? JSONDecoder().decode(ScreenMemoryAccessProfile.self, from: data))
            ?? .safeDefault
    }

    func isAuthorized() -> Bool {
        isEnabled
    }

    func requireAuthorized() throws {
        guard isAuthorized() else { throw ScreenMemoryAccessError.disabled }
    }

    func enable(profile: ScreenMemoryAccessProfile = .safeDefault) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: controlDirectory.path)
        try JSONEncoder().encode(profile).write(to: accessMarkerURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: accessMarkerURL.path)
    }

    func updateProfile(_ profile: ScreenMemoryAccessProfile) throws {
        guard isEnabled else { return }
        try enable(profile: profile)
    }

    func disable() {
        try? FileManager.default.removeItem(at: accessMarkerURL)
    }
}

@MainActor
final class ScreenMemoryAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var profile: ScreenMemoryAccessProfile = .safeDefault

    private let gate: ScreenMemoryAccessGate

    init(gate: ScreenMemoryAccessGate = ScreenMemoryAccessGate()) {
        self.gate = gate
    }

    func start() {
        isEnabled = gate.isEnabled
        profile = isEnabled ? gate.profile : .safeDefault
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try gate.enable(profile: profile)
            } catch {
                return
            }
            isEnabled = true
        } else {
            gate.disable()
            isEnabled = false
        }
    }

    func setScope(_ scope: ScreenMemoryAccessProfile.Scope) {
        let updated = ScreenMemoryAccessProfile(scope: scope)
        if isEnabled {
            do {
                try gate.updateProfile(updated)
            } catch {
                return
            }
        }
        profile = updated
    }
}
