import CryptoKit
import Foundation

struct AgentAccessCapability: Equatable, Sendable {
    fileprivate let id: String
    let token: String
}

enum AgentAccessError: LocalizedError {
    case disabled

    var errorDescription: String? {
        switch self {
        case .disabled:
            FileLibraryToolProvider.accessDisabledMessage
        }
    }
}

/// Cross-process marker-file truth for external-agent access and LLM wakeup.
struct AgentAccessGate {
    static let capabilityEnvironmentKey = "LOKALBOT_AGENT_CAPABILITY"

    var root: URL

    init(root: URL = SessionLookup.storageRootURL) {
        self.root = root
    }

    var controlDirectory: URL {
        root.appendingPathComponent("control", isDirectory: true)
    }

    var accessMarkerURL: URL {
        controlDirectory.appendingPathComponent("agent-access-enabled")
    }

    var wakeFileURL: URL {
        controlDirectory.appendingPathComponent("agent-wake")
    }

    var wakeErrorURL: URL {
        controlDirectory.appendingPathComponent("agent-wake-error")
    }

    var capabilityDirectory: URL {
        controlDirectory.appendingPathComponent("agent-capabilities", isDirectory: true)
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: accessMarkerURL.path)
    }

    /// True for the user-controlled global toggle or for an app-issued,
    /// short-lived capability inherited by the embedded Agent Mode process.
    /// A normal terminal invocation has no capability and must honor the
    /// Privacy toggle just like MCP does.
    func isAuthorized(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> Bool {
        authorizationID(environment: environment, now: now) != nil
    }

    /// A long-running read must retain the same grant through response delivery.
    /// Re-enabling global access issues a new identity, so it cannot revive an
    /// answer whose original grant was revoked while inference was pending.
    func authorizationID(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> String? {
        if let marker = try? Data(contentsOf: accessMarkerURL) {
            return "global:\(marker.base64EncodedString())"
        }
        guard let token = environment[Self.capabilityEnvironmentKey] else { return nil }
        return validateCapability(token, now: now) ? "capability:\(Self.digest(token))" : nil
    }

    func requireAuthorized(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard isAuthorized(environment: environment) else { throw AgentAccessError.disabled }
    }

    func enable() throws {
        try FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true)
        try Data(UUID().uuidString.utf8).write(to: accessMarkerURL, options: .atomic)
    }

    func disable() {
        try? FileManager.default.removeItem(at: accessMarkerURL)
    }

    /// Creates a bearer capability for one embedded Agent Mode subprocess.
    /// Only a SHA-256 digest is persisted; the bearer secret exists in the
    /// process environment and is revoked when the tab shuts down.
    func issueScopedCapability(validFor lifetime: TimeInterval = 24 * 60 * 60) throws
        -> AgentAccessCapability {
        let id = UUID().uuidString.lowercased()
        let secret = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let record = CapabilityRecord(
            digest: Self.digest(secret),
            expiresAt: Date().addingTimeInterval(max(60, lifetime)))
        try FileManager.default.createDirectory(
            at: capabilityDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = capabilityURL(id: id)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return AgentAccessCapability(id: id, token: "\(id).\(secret)")
    }

    func revoke(_ capability: AgentAccessCapability) {
        try? FileManager.default.removeItem(at: capabilityURL(id: capability.id))
    }

    func removeExpiredCapabilities(now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: capabilityDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return }
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(CapabilityRecord.self, from: data),
                  record.expiresAt > now else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
        }
    }

    func touchWake() throws {
        try FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true)
        try Data().write(to: wakeFileURL)
    }

    func consumeWake() -> Bool {
        guard FileManager.default.fileExists(atPath: wakeFileURL.path) else { return false }
        try? FileManager.default.removeItem(at: wakeFileURL)
        return true
    }

    var pendingWake: Bool {
        FileManager.default.fileExists(atPath: wakeFileURL.path)
    }

    func writeWakeError(_ message: String) {
        try? FileManager.default.createDirectory(
            at: controlDirectory,
            withIntermediateDirectories: true)
        try? Data(message.utf8).write(to: wakeErrorURL)
    }

    func clearWakeError() {
        try? FileManager.default.removeItem(at: wakeErrorURL)
    }

    func readWakeError() -> String? {
        guard let data = try? Data(contentsOf: wakeErrorURL) else { return nil }
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    private func validateCapability(_ token: String, now: Date) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let id = String(parts[0])
        let secret = String(parts[1])
        guard UUID(uuidString: id) != nil,
              secret.count == 64,
              secret.allSatisfy({ $0.isHexDigit }),
              let data = try? Data(contentsOf: capabilityURL(id: id)),
              let record = try? JSONDecoder().decode(CapabilityRecord.self, from: data),
              record.expiresAt > now else { return false }
        return record.digest == Self.digest(secret)
    }

    private func capabilityURL(id: String) -> URL {
        capabilityDirectory.appendingPathComponent("\(id.lowercased()).json")
    }

    private static func digest(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private struct CapabilityRecord: Codable {
        let digest: String
        let expiresAt: Date
    }
}
