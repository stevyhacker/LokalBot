import Foundation

struct AgentSecretStore {
    var read: (String) -> String?
    var write: (String, String?) -> Bool

    static let keychain = AgentSecretStore(
        read: { KeychainSecrets.string(account: $0) },
        write: { account, value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            KeychainSecrets.setString(trimmed, account: account)
            return (KeychainSecrets.string(account: account) ?? "") == trimmed
        })
}

extension AppSecret {
    var keychainAccount: String {
        switch self {
        case .openAICompatible: "openai-compatible-api-key"
        case .remoteTranscription: AppSettings.remoteTranscriptionAPIKeyAccount
        case .autocompleteServer: AppSettings.cotypingServerAPIKeyAccount
        case .metaModelAPI: MetaModelAPI.apiKeyAccount
        }
    }
}

extension AppState {
    nonisolated static func coupledSettings(
        _ new: AppSettings, from old: AppSettings, now: Date = Date(), calendar: Calendar = .current
    ) -> AppSettings {
        var settings = new
        if old.trackingEnabled, !settings.trackingEnabled {
            settings.screenContextCaptureMode = .activityOnly
            settings.screenshotsEnabled = false
        }
        if settings.screenContextCaptureMode != old.screenContextCaptureMode {
            settings.screenshotsEnabled = settings.screenContextCaptureMode.capturesPixels
            if settings.screenContextCaptureMode.capturesText { settings.trackingEnabled = true }
        }
        if settings.dreamingEnabled != old.dreamingEnabled {
            settings.dreamingFirstEligibleDayKey = dreamingFirstEligibleDayKey(
                enabled: settings.dreamingEnabled, now: now, calendar: calendar)
        }
        return settings
    }

    func changeSettings(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        applySettings(Self.coupledSettings(updated, from: settings), requestingPermissions: true)
    }

    func applySettings(_ updated: AppSettings, requestingPermissions: Bool) {
        let previous = settings
        settings = updated
        if previous.menuBarOnly != settings.menuBarOnly {
            settingsStore.flush()
            DockPolicy.sync()
        }
        if requestingPermissions { requestPermissions(forChangeFrom: previous, to: settings) }
    }

    func requestPermissions(forChangeFrom old: AppSettings, to new: AppSettings) {
        let oldMode = old.effectiveScreenContextCaptureMode
        let newMode = new.effectiveScreenContextCaptureMode
        if (new.trackingEnabled && !old.trackingEnabled) || (newMode != oldMode && newMode.capturesText) {
            PermissionGuidanceController.shared.requestAccess(for: .accessibility)
        }
        if newMode != oldMode, newMode.capturesPixels {
            PermissionGuidanceController.shared.requestAccess(for: .screenRecording)
        }
        if new.calendarDetectionEnabled, !old.calendarDetectionEnabled,
           calendar.authorizationStatus == .notDetermined {
            calendar.requestAccess { _ in }
        }
    }

    func applyRetentionReview(_ proposal: RetentionReview) throws -> [String] {
        let days = Array(Set(proposal.evidenceDates.map { Calendar.current.startOfDay(for: $0) }))
        let failures = try withPrimaryEvidenceChange(on: days, .removal) {
            try screenshots.applyRetentionReview(proposal)
        }
        settings.retentionDays = proposal.days
        settings.keepOCRTextForever = proposal.keepTextForever
        return failures
    }

    func showAgentSetupIfRequested() {
        if agentSetup.check() { WindowAccess.shared.open("agent-setup") }
    }

    func applyAgentSettings(
        _ items: [SettingsChangePlan.Item], caller: String, requestingPermissions: Bool = false
    ) throws -> [JSONValue] {
        guard !items.isEmpty else { return [] }
        applySettings(try SettingsChangeApplier.apply(items, to: settings), requestingPermissions: requestingPermissions)
        agentSettingsChanges.record(items, caller: caller)
        let effective = AppControlHandler.encoded(settings)
        return items.compactMap { item in
            guard effective[item.spec.key] != item.stored else { return nil }
            return .string("\(item.spec.key) could not be applied; LokalBot kept the earlier value.")
        }
    }

    func retentionReview(for items: [SettingsChangePlan.Item]) throws -> RetentionReview? {
        guard let target = retentionTarget(of: items),
              target.days < settings.retentionDays || (settings.keepOCRTextForever && !target.keepTextForever)
        else { return nil }
        return try activityStore.retentionReview(days: target.days, keepTextForever: target.keepTextForever)
    }

    func applyApprovedSettings(_ request: SettingsApprovals.Request) throws -> JSONValue {
        guard case .settings = request.subject else {
            throw AppControlError.invalidRequest("This request does not change settings.")
        }
        let redact = DiagnosticsSettingsSanitizer.redactURL
        let plan = SettingsChangePlan.rebasing(request.items, on: AppControlHandler.encoded(settings))
        if !plan.readOnly.isEmpty { throw AppControlError.readOnly(plan.readOnly.map(\.spec.key)) }
        let items = plan.applicable + plan.widening
        _ = try SettingsChangeApplier.apply(items, to: settings)
        if plan.widens(beyond: request.items) {
            let review = try retentionReview(for: items)
            let keys = Set(items.map(\.spec.key))
            let changes = plan.entries(redactURL: redact).filter { keys.contains($0["key"]?.stringValue ?? "") }
            settingsApprovals.update(request.id) { pending in
                pending.items = items
                pending.changes = changes
                pending.retention = review
            }
            throw SettingsApprovalError.changedWhileWaiting
        }
        var warnings: [JSONValue] = []
        if let needed = try retentionReview(for: items) {
            guard let shown = request.retention, shown.days == needed.days,
                  shown.keepTextForever == needed.keepTextForever else {
                settingsApprovals.update(request.id) { $0.retention = needed }
                throw RetentionReviewError.scopeChanged
            }
            do {
                let failures = try applyRetentionReview(shown)
                if !failures.isEmpty {
                    warnings.append(.string("\(failures.count) moments could not be fully cleaned up."))
                }
            } catch RetentionReviewError.scopeChanged {
                settingsApprovals.update(request.id) { $0.retention = needed }
                throw RetentionReviewError.scopeChanged
            }
        }
        warnings += try applyAgentSettings(items, caller: request.caller, requestingPermissions: isInteractiveLaunch)
        return ["applied": true, "changes": .array(plan.entries(redactURL: redact)), "warnings": .array(warnings)]
    }

    func approveSettingsRequest(_ id: UUID) throws {
        try settingsApprovals.approve(id) { request in
            switch request.subject {
            case .settings: return try applyApprovedSettings(request)
            case .secret: return try applyApprovedSecret(request)
            case .meetingImport: return try applyApprovedImport(request)
            }
        }
    }

    func applyApprovedSecret(_ request: SettingsApprovals.Request) throws -> JSONValue {
        guard case .secret(let secret, let value) = request.subject, !value.isEmpty else {
            throw AppControlError.invalidRequest("This request does not set an API key.")
        }
        try setAgentSecret(secret, to: value, caller: request.caller)
        return ["applied": true, "secret": .string(secret.rawValue)]
    }

    func applyApprovedImport(_ request: SettingsApprovals.Request) throws -> JSONValue {
        guard case .meetingImport(let importRequest) = request.subject else {
            throw AppControlError.invalidRequest("This request does not import meetings.")
        }
        importExternalMeetings(importRequest.source, urls: importRequest.paths.map { URL(fileURLWithPath: $0) })
        return ["started": true, "source": .string(importRequest.source.rawValue),
                "paths": .array(importRequest.paths.map(JSONValue.string))]
    }

    func setAgentSecret(_ secret: AppSecret, to value: String?, caller: String) throws {
        guard agentSecrets.write(secret.keychainAccount, value) else {
            throw AppControlError(code: "keychain_error", message: "LokalBot couldn't save the \(secret.title) to the Keychain.")
        }
        switch secret {
        case .openAICompatible: modelChecks.invalidate(for: settings)
        case .remoteTranscription: modelChecks.invalidate([.transcribe])
        case .autocompleteServer: modelChecks.invalidate([.autocomplete])
        case .metaModelAPI: break
        }
        agentSettingsChanges.recordSecret(secret, isSet: value != nil, caller: caller)
    }

    func isSecretSet(_ secret: AppSecret) -> Bool {
        !(agentSecrets.read(secret.keychainAccount) ?? "").isEmpty
    }

    private func retentionTarget(of items: [SettingsChangePlan.Item]) -> (days: Int, keepTextForever: Bool)? {
        let days = items.first { $0.spec.key == "retentionDays" }
        let forever = items.first { $0.spec.key == "keepOCRTextForever" }
        guard days != nil || forever != nil else { return nil }
        var keepForever = settings.keepOCRTextForever
        if let forever {
            if case .bool(let value)? = forever.stored { keepForever = value } else { keepForever = AppSettings().keepOCRTextForever }
        }
        let targetDays = days.map { $0.stored?.intValue ?? AppSettings().retentionDays } ?? settings.retentionDays
        return (targetDays, keepForever)
    }
}
