import AppKit
import Foundation

/// The setup half of the control socket: what an agent needs to take the
/// person from a new install to a working LokalBot. Permission prompts,
/// launch at login, and restarts act only in the interactive app, where the
/// person can see them.
extension AppControlHandler {
    func setupResponse(
        _ method: AppControlProtocol.Method, _ params: [String: JSONValue], peer: AppControlPeer, in app: AppState
    ) throws -> JSONValue {
        switch method {
        case .setupPlan:
            return try Self.setupPlan(params, in: app)
        case .setupFinish:
            UserDefaults.standard.set(true, forKey: AppState.onboardingShownKey)
            WindowAccess.shared.close("onboarding")
            WindowAccess.shared.close("agent-setup")
            DockPolicy.sync()
            return ["finished": true]
        case .modelsStatus:
            return Self.modelsStatus(in: app)
        case .modelsPreset:
            let preset = try Self.modelPreset(params["preset"])
            app.modelSetup.apply(preset.patch, title: preset.title)
            app.agentSettingsChanges.recordEvent("models.preset", .string(preset.rawValue), caller: peer.description)
            return Self.modelsStatus(in: app)
        case .modelsDownload:
            app.modelRoles.startCoreModelDownloads()
            let transcription = app.settings.transcriptionModel
            if !transcription.isRemote, !TranscriptionModelStore.isDownloaded(transcription) {
                app.modelRoles.prepareTranscriptionModel(transcription)
            }
            return Self.modelsStatus(in: app)
        case .modelsCancel:
            app.modelSetup.cancelSwitch()
            return Self.modelsStatus(in: app)
        case .permissionsList:
            return Self.permissions(in: app)
        case .permissionsRequest:
            try Self.requirePerson(app)
            try Self.requestPermission(params["name"]?.stringValue ?? "", in: app)
            return Self.permissions(in: app)
        case .launchAtLogin:
            guard case .bool(let enabled)? = params["enabled"] else {
                throw AppControlError.invalidRequest("app.launchAtLogin needs \"enabled\": true or false.")
            }
            try Self.requirePerson(app)
            LaunchAtLoginState.shared.setEnabled(enabled)
            app.agentSettingsChanges.recordEvent("launchAtLogin", .bool(enabled), caller: peer.description)
            return ["launchAtLogin": .bool(enabled)]
        case .restart:
            try Self.requirePerson(app)
            guard !app.isRecording, !app.dictation.state.isRecording else {
                throw AppControlError(code: "busy", message: "LokalBot is recording. Restart it after the recording stops.")
            }
            // Reply first; the relaunch quits this copy.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                PermissionManager.relaunch()
            }
            return ["restarting": true]
        case .doctor:
            return Self.doctor(in: app)
        default:
            throw AppControlError.unknownMethod(method.rawValue)
        }
    }

    // MARK: Plans and models

    static func setupPlan(_ params: [String: JSONValue], in app: AppState) throws -> JSONValue {
        let suggestion = suggestedPreset()
        let chosen = try params["preset"].map { try Self.modelPreset($0) } ?? suggestion.preset
        let current = encoded(app.settings)
        var settings: [String: JSONValue] = [:]
        for key in SetupPlan.keys {
            guard let spec = SettingRegistry.spec(for: key), let value = current[key] else { continue }
            settings[key] = spec.presented(value)
        }
        var plan = SetupPlan(
            settings: settings, models: chosen.rawValue, launchAtLogin: LaunchAtLoginState.shared.isEnabled).json
        plan = plan.merging(["notes": [
            "suggestedModels": .string(suggestion.preset.rawValue),
            "modelsReason": .string(suggestion.reason),
            "needsApproval": .array(SetupPlan.keys.filter { SettingRegistry.spec(for: $0)?.tier == .consent }
                .map(JSONValue.string)),
            "describe": "Run `lokalbot-cli config describe <key>` for each setting's choices.",
        ]])
        return plan
    }

    static func modelsStatus(in app: AppState) -> JSONValue {
        let suggestion = suggestedPreset()
        var status = models(app.modelRoles.snapshot).merging([
            "preset": .string(ModelStackPreset.matching(app.settings)?.rawValue ?? "custom"),
            "suggestedPreset": .string(suggestion.preset.rawValue),
            "suggestionReason": .string(suggestion.reason),
        ])
        if let pending = app.modelSetup.pending { status = status.merging(["switching": .string(pending.title)]) }
        if let failure = app.modelSetup.failure { status = status.merging(["switchFailure": .string(failure)]) }
        return status
    }

    /// The balanced models when their Think and autocomplete models, plus
    /// room for transcription, fit comfortably in memory; otherwise the
    /// lightweight ones.
    static func suggestedPreset(
        capability: HardwareCapability = HardwareCapabilityProbe.current()
    ) -> (preset: ModelStackPreset, reason: String) {
        let gigabytes = Double(capability.physicalMemoryBytes) / 1_073_741_824
        let preset = ModelStackPreset.recommended
        let stackBytes = [preset.mainModelID, preset.autocompleteModelID]
            .compactMap { ModelCatalog.entry(id: $0)?.sizeBytes }
            .reduce(Int64(1_073_741_824), +)
        let memory = "\(Int(gigabytes.rounded())) GB"
        if ModelFit.evaluate(modelSizeGB: Double(stackBytes) / 1_073_741_824, capability: capability) == .comfortable {
            return (.recommended, "This Mac has \(memory) of memory, enough for the balanced models.")
        }
        return (.lightweight, "This Mac has \(memory) of memory; the lightweight models leave room for other apps.")
    }

    private static func modelPreset(_ value: JSONValue?) throws -> ModelStackPreset {
        guard let name = value?.stringValue, let preset = ModelStackPreset(rawValue: name) else {
            throw AppControlError.invalidRequest(
                "Choose a model preset: \(AppControlProtocol.modelPresets.joined(separator: ", ")).")
        }
        return preset
    }

    // MARK: Permissions

    /// Each permission, whether it is granted, and which enabled features
    /// need it. Mirrors the Permissions row in Memory Health.
    static func permissions(in app: AppState) -> JSONValue {
        .array(permissionNeeds(in: app).map { need in
            [
                "name": .string(need.name),
                "title": .string(need.title),
                "granted": .bool(need.granted),
                "neededBy": .array(need.neededBy.map(JSONValue.string)),
            ]
        })
    }

    struct PermissionNeed {
        let name: String
        let title: String
        let granted: Bool
        let neededBy: [String]
    }

    static func permissionNeeds(in app: AppState) -> [PermissionNeed] {
        let settings = app.settings
        let mode = settings.effectiveScreenContextCaptureMode
        var neededBy: [AppPermission: [String]] = [.microphone: ["Meeting recording"]]
        func need(_ permission: AppPermission, _ feature: String) { neededBy[permission, default: []].append(feature) }
        if settings.trackingEnabled || mode.capturesText { need(.accessibility, "Day Memory") }
        if mode.capturesPixels { need(.screenRecording, "Screen images") }
        if settings.dictationEnabled {
            need(.microphone, "Dictation")
            need(.accessibility, "Dictation")
            need(.inputMonitoring, "Dictation")
        }
        if settings.cotypingEnabled {
            need(.accessibility, "Autocomplete")
            need(.inputMonitoring, "Autocomplete")
        }
        var needs = AppPermission.allCases.map { permission in
            PermissionNeed(name: name(of: permission), title: permission.title,
                           granted: permission.isGranted, neededBy: neededBy[permission] ?? [])
        }
        needs.append(PermissionNeed(
            name: "calendar", title: "Calendar",
            granted: app.calendar.authorizationStatus == .fullAccess,
            neededBy: settings.calendarDetectionEnabled ? ["Calendar detection"] : []))
        return needs
    }

    private static func name(of permission: AppPermission) -> String {
        switch permission {
        case .microphone: "microphone"
        case .accessibility: "accessibility"
        case .screenRecording: "screen-recording"
        case .inputMonitoring: "input-monitoring"
        }
    }

    /// Shows the macOS prompt, or System Settings with LokalBot's guidance.
    /// The person still decides.
    private static func requestPermission(_ name: String, in app: AppState) throws {
        if name == "calendar" {
            if app.calendar.authorizationStatus == .notDetermined {
                app.calendar.requestAccess { _ in }
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        guard let permission = AppPermission.allCases.first(where: { Self.name(of: $0) == name }) else {
            throw AppControlError.invalidRequest(
                "Name a permission: \(AppControlProtocol.permissionNames.joined(separator: ", ")).")
        }
        PermissionGuidanceController.shared.requestAccess(for: permission)
    }

    private static func requirePerson(_ app: AppState) throws {
        guard app.isInteractiveLaunch else {
            throw AppControlError(code: "unavailable", message: "This LokalBot is not running interactively, so it can't show that to the person.")
        }
    }

    // MARK: Doctor

    /// Readiness and the next steps, for the features the person turned on.
    static func doctor(in app: AppState) -> JSONValue {
        var checks: [JSONValue] = []
        var steps: [String] = []
        var ready = true
        func check(_ name: String, _ ok: Bool, _ detail: String, blocking: Bool = true) {
            checks.append(["name": .string(name), "ok": .bool(ok), "detail": .string(detail)])
            if !ok, blocking { ready = false }
        }

        let snapshot = app.modelRoles.snapshot
        check("models", snapshot.meetingReady, snapshot.meetingReady
              ? "Meeting models are ready." : "Meeting models are not ready yet.")
        if !snapshot.meetingReady {
            steps.append(app.modelSetup.pending != nil
                ? "Models are downloading. Run `lokalbot-cli models status` until meetingReady is true."
                : "Run `lokalbot-cli models download`, then `lokalbot-cli models status` until meetingReady is true.")
        }
        if ModelRole.allCases.contains(where: { role in
            if case .needsAttention = snapshot[role] { return true }
            return false
        }) {
            steps.append("A model needs attention. Show the person: `lokalbot-cli open settings models`.")
        }

        let missing = permissionNeeds(in: app).filter { !$0.granted && !$0.neededBy.isEmpty }
        check("permissions", missing.isEmpty, missing.isEmpty
              ? "Every permission the enabled features need is granted."
              : "Missing: " + missing.map { "\($0.title) (for \($0.neededBy.joined(separator: ", ")))" }.joined(separator: "; "))
        for need in missing {
            steps.append("Ask the person to allow \(need.title): `lokalbot-cli permissions request \(need.name)`.")
        }
        if missing.contains(where: { $0.name == "accessibility" || $0.name == "input-monitoring" }) {
            steps.append("After the person allows Accessibility or Input Monitoring, run `lokalbot-cli restart` if macOS asks.")
        }

        let onboarded = UserDefaults.standard.bool(forKey: AppState.onboardingShownKey)
        check("onboarding", onboarded, onboarded ? "Setup is finished." : "Setup is not finished.")
        if !onboarded { steps.append("When setup is done, run `lokalbot-cli setup finish`.") }

        let waiting = app.settingsApprovals.pending.count
        check("approvals", waiting == 0, waiting == 0
              ? "Nothing is waiting for the person." : "\(waiting) request(s) are waiting for the person in LokalBot.",
              blocking: false)
        if waiting > 0 { steps.append("Tell the person a request is waiting for them in LokalBot.") }

        let launchAtLogin = LaunchAtLoginState.shared.isEnabled
        check("launchAtLogin", launchAtLogin, launchAtLogin
              ? "LokalBot starts at login." : "LokalBot does not start at login.", blocking: false)

        return ["ready": .bool(ready), "checks": .array(checks), "nextSteps": .array(steps.map(JSONValue.string))]
    }
}

private extension JSONValue {
    func merging(_ other: [String: JSONValue]) -> JSONValue {
        .object((objectValue ?? [:]).merging(other) { _, new in new })
    }
}
