import Foundation

/// Answers control-socket requests on the main actor, against the live
/// `AppState`. Every request re-checks the Privacy marker, so revoking the
/// grant takes effect even for a connection already accepted.
@MainActor
final class AppControlHandler {
    private weak var app: AppState?
    private let gate: SettingsControlGate

    init(app: AppState, gate: SettingsControlGate) {
        self.app = app
        self.gate = gate
    }

    func handle(_ request: AppControlRequest) async -> AppControlResponse {
        guard request.protocolVersion == AppControlProtocol.version else {
            return .failure(.unsupportedProtocol)
        }
        guard gate.isEnabled else { return .failure(.settingsAccessDisabled) }
        guard let app else {
            return .failure(.appNotRunning("LokalBot is shutting down."))
        }
        guard let method = AppControlProtocol.Method(rawValue: request.method) else {
            return .failure(.unknownMethod(request.method))
        }
        do {
            switch method {
            case .hello:
                return .success(Self.hello)
            case .settingsList:
                let specs = try SettingsSnapshot.specs(
                    category: request.params?["category"]?.stringValue,
                    keys: nil)
                return .success(.array(entries(for: specs, in: app)))
            case .settingsGet:
                guard case .array(let values)? = request.params?["keys"] else {
                    throw AppControlError.invalidRequest("settings.get needs a \"keys\" array.")
                }
                let keys = values.compactMap(\.stringValue)
                let specs = try SettingsSnapshot.specs(category: nil, keys: keys)
                return .success(.array(entries(for: specs, in: app)))
            case .status:
                return .success(status(of: app))
            case .open:
                try openSettings(request.params ?? [:], in: app)
                return .success(["opened": true])
            }
        } catch let error as AppControlError {
            return .failure(error)
        } catch {
            return .failure(.invalidRequest(error.localizedDescription))
        }
    }

    static var hello: JSONValue {
        [
            "app": "LokalBot",
            "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"),
            "protocol": .number(Double(AppControlProtocol.version)),
            "bundleIdentifier": .string(AppIdentifiers.bundleID),
            "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
        ]
    }

    private func entries(for specs: [SettingSpec], in app: AppState) -> [JSONValue] {
        SettingsSnapshot.entries(
            current: Self.encoded(app.settings),
            defaults: Self.encoded(AppSettings()),
            specs: specs,
            redactURL: DiagnosticsSettingsSanitizer.redactURL)
    }

    nonisolated static func encoded(_ settings: AppSettings) -> [String: JSONValue] {
        guard let data = try? JSONEncoder().encode(settings),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [:] }
        return object
    }

    private func status(of app: AppState) -> JSONValue {
        var permissions: [String: JSONValue] = [:]
        for permission in AppPermission.allCases {
            permissions[permission.title] = .bool(permission.isGranted)
        }
        return [
            "app": Self.hello,
            "library": ["root": .string(app.storage.rootURL.path)],
            "recording": ["active": .bool(app.isRecording)],
            "access": [
                "meetingLibrary": .bool(app.agentAccess.isEnabled),
                "screenMemory": .bool(app.screenMemoryAccess.isEnabled),
                "settings": .bool(gate.isEnabled),
            ],
            "permissions": .object(permissions),
        ]
    }

    /// Opens Settings at one setting, for what only the person can do there:
    /// permissions, sign-in, or a change they want to make themselves.
    private func openSettings(_ params: [String: JSONValue], in app: AppState) throws {
        guard params["target"]?.stringValue == "settings" else {
            throw AppControlError.invalidRequest("open supports the \"settings\" target.")
        }
        guard let key = params["key"]?.stringValue else {
            app.openSettings()
            return
        }
        guard let spec = SettingRegistry.spec(for: key) else { throw AppControlError.unknownKey(key) }
        let id = "settings.\(key)"
        let descriptor = SettingDescriptor.all.first { $0.id == id }
        app.openSettings(tab: descriptor?.category ?? AppState.SettingsTab(rawValue: spec.category.rawValue))
        app.focusedSettingID = descriptor?.focusTarget(in: app.settings) ?? id
    }
}
