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

    func handle(_ request: AppControlRequest, from peer: AppControlPeer = .unknown) async -> AppControlResponse {
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
            case .settingsSet:
                return .success(try setSettings(SettingsChangeRequest(params: request.params), caller: peer.description, in: app))
            case .settingsRequest:
                guard let id = request.params?["id"]?.stringValue else {
                    throw AppControlError.invalidRequest("settings.request needs an \"id\".")
                }
                guard let uuid = UUID(uuidString: id), let pending = app.settingsApprovals.request(uuid) else {
                    throw AppControlError.unknownRequest(id)
                }
                return .success(pending.json)
            case .secretList:
                return .success(.array(AppSecret.allCases.map { secret in
                    [
                        "name": .string(secret.rawValue),
                        "title": .string(secret.title),
                        "summary": .string(secret.summary),
                        "isSet": .bool(app.isSecretSet(secret)),
                    ]
                }))
            case .secretSet:
                throw try setSecret(request.params ?? [:], caller: peer.description, in: app)
            case .secretClear:
                let secret = try Self.secret(request.params ?? [:])
                try app.setAgentSecret(secret, to: nil, caller: peer.description)
                return .success(["cleared": .string(secret.rawValue)])
            case .setupPlan, .setupFinish, .modelsStatus, .modelsPreset, .modelsDownload, .modelsCancel,
                 .permissionsList, .permissionsRequest, .launchAtLogin, .restart, .doctor:
                return .success(try setupResponse(method, request.params ?? [:], peer: peer, in: app))
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

    /// Applies preference and narrowing changes, all or none. A change that
    /// widens what LokalBot captures, reads, records, or sends waits, with the
    /// rest of its request, until the person approves it in the app.
    private func setSettings(_ request: SettingsChangeRequest, caller: String, in app: AppState) throws -> JSONValue {
        let redact = DiagnosticsSettingsSanitizer.redactURL
        let plan = try SettingsChangePlan.make(
            request: request,
            current: Self.encoded(app.settings),
            defaults: Self.encoded(AppSettings()),
            redactURL: redact)
        let entries = plan.entries(redactURL: redact)
        // Validate everything that would apply, even for a dry run, and
        // before asking the person about a value LokalBot would reject.
        _ = try SettingsChangeApplier.apply(plan.applicable + plan.widening, to: app.settings)
        if request.dryRun {
            return ["applied": false, "dryRun": true, "changes": .array(entries)]
        }
        if !plan.readOnly.isEmpty {
            throw AppControlError.readOnly(plan.readOnly.map(\.spec.key))
        }
        if !plan.widening.isEmpty {
            let changed = plan.applicable + plan.widening
            let keys = Set(changed.map(\.spec.key))
            let pending = try app.settingsApprovals.submit(
                .settings(request),
                caller: caller,
                items: changed,
                changes: entries.filter { keys.contains($0["key"]?.stringValue ?? "") },
                retention: try app.retentionReview(for: changed))
            throw AppControlError.needsApproval(pending.json, asking: pending.headline)
        }
        guard !plan.applicable.isEmpty else {
            return ["applied": false, "changes": .array(entries)]
        }
        let warnings = try app.applyAgentSettings(plan.applicable, caller: caller)
        return ["applied": true, "changes": .array(entries), "warnings": .array(warnings)]
    }

    /// A new API key always waits for the person. The key itself is held in
    /// memory until the request is answered and never appears in a reply.
    private func setSecret(_ params: [String: JSONValue], caller: String, in app: AppState) throws -> AppControlError {
        let secret = try Self.secret(params)
        let value = (params["value"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.contains(where: \.isNewline) else {
            throw AppControlError.invalidRequest("secret.set needs the key as one line in \"value\".")
        }
        let change: JSONValue = [
            "key": .string("secret.\(secret.rawValue)"),
            "title": .string(secret.title),
            "tier": "consent",
            "change": .string(SettingChangeClass.widening.rawValue),
            "previous": .string(app.isSecretSet(secret) ? "saved" : "not set"),
            "value": .string("new key \(AppSecret.hint(for: value))".trimmingCharacters(in: .whitespaces)),
        ]
        let pending = try app.settingsApprovals.submit(
            .secret(secret, value: value), caller: caller, items: [], changes: [change])
        return AppControlError.needsApproval(pending.json, asking: pending.headline)
    }

    private static func secret(_ params: [String: JSONValue]) throws -> AppSecret {
        guard let name = params["name"]?.stringValue else {
            throw AppControlError.invalidRequest("Name the API key in \"name\".")
        }
        guard let secret = AppSecret(rawValue: name) else { throw AppControlError.unknownSecret(name) }
        return secret
    }

    private func status(of app: AppState) -> JSONValue {
        app.settingsApprovals.expireStale()
        var permissions: [String: JSONValue] = [:]
        for permission in AppPermission.allCases {
            permissions[permission.title] = .bool(permission.isGranted)
        }
        return [
            "app": Self.hello,
            "library": ["root": .string(app.storage.rootURL.path)],
            "onboarding": ["completed": .bool(UserDefaults.standard.bool(forKey: AppState.onboardingShownKey))],
            "recording": ["active": .bool(app.isRecording)],
            "models": Self.models(app.modelRoles.snapshot),
            "access": [
                "meetingLibrary": .bool(app.agentAccess.isEnabled),
                "screenMemory": .bool(app.screenMemoryAccess.isEnabled),
                "personalContext": .bool(app.personalContextAccess.isEnabled),
                "settings": .bool(gate.isEnabled),
            ],
            "permissions": .object(permissions),
            "approvals": ["pending": .number(Double(app.settingsApprovals.pending.count))],
        ]
    }

    static func models(_ snapshot: ModelRolesSnapshot) -> JSONValue {
        var roles: [String: JSONValue] = [:]
        for role in ModelRole.allCases {
            let status = snapshot[role]
            var entry: [String: JSONValue] = ["state": .string(state(status)), "label": .string(status.label)]
            if let progress = status.progress { entry["progress"] = .number(progress) }
            if let message = status.errorMessage { entry["error"] = .string(message) }
            roles[role.rawValue] = .object(entry)
        }
        return [
            "meetingReady": .bool(snapshot.meetingReady),
            "allReady": .bool(snapshot.coreReady),
            "roles": .object(roles),
        ]
    }

    private static func state(_ status: ModelRoleStatus) -> String {
        switch status {
        case .unavailable: "notDownloaded"
        case .downloading: "downloading"
        case .preparing: "preparing"
        case .ready: "ready"
        case .needsAttention: "needsAttention"
        }
    }

    /// Opens Settings at one setting or section, for what only the person can
    /// do there: permissions, sign-in, or a change they want to make themselves.
    private func openSettings(_ params: [String: JSONValue], in app: AppState) throws {
        guard params["target"]?.stringValue == "settings" else {
            throw AppControlError.invalidRequest("open supports the \"settings\" target.")
        }
        guard let key = params["key"]?.stringValue else {
            app.openSettings()
            return
        }
        let id = "settings.\(key)"
        let descriptor = SettingDescriptor.all.first { $0.id == id }
        let spec = SettingRegistry.spec(for: key)
        guard spec != nil || (descriptor != nil && AppControlProtocol.settingsDestinations.contains(key)) else {
            throw AppControlError.unknownKey(key)
        }
        app.openSettings(tab: descriptor?.category ?? spec.flatMap { AppState.SettingsTab(rawValue: $0.category.rawValue) })
        app.focusedSettingID = descriptor?.focusTarget(in: app.settings) ?? id
    }
}
