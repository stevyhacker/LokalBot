import Foundation

/// Where API keys are kept. Tests swap in memory so they never touch the
/// login Keychain.
struct AgentSecretStore {
    var read: (String) -> String?
    /// Saves a key, or removes it for nil, and says whether it stuck.
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
        }
    }
}

/// Settings changed outside their Settings control: from the terminal, after
/// an approval, or by Undo. The rules match the controls, so a change made
/// anywhere leaves the same settings and asks for the same permissions.
extension AppState {
    /// The rules the Settings controls apply alongside a change.
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

    /// Changes settings the way a Settings control does: couplings, then the
    /// permission prompts for whatever the change turned on.
    func changeSettings(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        applySettings(Self.coupledSettings(updated, from: settings), requestingPermissions: true)
    }

    func applySettings(_ updated: AppSettings, requestingPermissions: Bool) {
        let previous = settings
        settings = updated
        if previous.menuBarOnly != settings.menuBarOnly {
            // The Dock policy reads saved settings.
            settingsStore.flush()
            DockPolicy.sync()
        }
        if requestingPermissions { requestPermissions(forChangeFrom: previous, to: settings) }
    }

    /// The prompts the Settings controls show when a feature that needs a
    /// permission is turned on.
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

    /// Deletes what a reviewed retention change lists, then sets the policy.
    /// Returns the moments that could not be fully cleaned up.
    func applyRetentionReview(_ proposal: RetentionReview) throws -> [String] {
        let days = Array(Set(proposal.evidenceDates.map { Calendar.current.startOfDay(for: $0) }))
        let failures = try withPrimaryEvidenceChange(on: days, .removal) {
            try screenshots.applyRetentionReview(proposal)
        }
        primaryEvidenceDidChange(on: days)
        settings.retentionDays = proposal.days
        settings.keepOCRTextForever = proposal.keepTextForever
        return failures
    }

    // MARK: From the terminal

    /// Shows an agent's setup request, if one is waiting.
    func showAgentSetupIfRequested() {
        if agentSetup.check() { WindowAccess.shared.open("agent-setup") }
    }

    /// Applies checked plan items and records them for the audit log and
    /// Undo. Returns a warning for each value that did not stick.
    func applyAgentSettings(
        _ items: [SettingsChangePlan.Item], caller: String, requestingPermissions: Bool = false
    ) throws -> [JSONValue] {
        guard !items.isEmpty else { return [] }
        applySettings(try SettingsChangeApplier.apply(items, to: settings), requestingPermissions: requestingPermissions)
        agentSettingsChanges.record(items, caller: caller)
        // Some settings correct themselves: the Ask shortcut reverts when
        // another app already owns the key combination.
        let effective = AppControlHandler.encoded(settings)
        return items.compactMap { item in
            guard effective[item.spec.key] != item.stored else { return nil }
            return .string("\(item.spec.key) could not be applied; LokalBot kept the earlier value.")
        }
    }

    /// The cleanup a change's shorter retention policy needs reviewed, or nil
    /// when the change deletes nothing.
    func retentionReview(for items: [SettingsChangePlan.Item]) throws -> RetentionReview? {
        guard let target = retentionTarget(of: items),
              target.days < settings.retentionDays || (settings.keepOCRTextForever && !target.keepTextForever)
        else { return nil }
        return try activityStore.retentionReview(days: target.days, keepTextForever: target.keepTextForever)
    }

    /// Applies the changes an approved card showed to the settings as they
    /// are now. Settings the request left as they were stay as the person has
    /// them since. When approving would widen more than the card showed, or a
    /// shorter retention policy would delete more than its review, the card
    /// gets the new changes and keeps waiting.
    func applyApprovedSettings(_ request: SettingsApprovals.Request) throws -> JSONValue {
        guard case .settings = request.subject else {
            throw AppControlError.invalidRequest("This request does not change settings.")
        }
        let redact = DiagnosticsSettingsSanitizer.redactURL
        let plan = SettingsChangePlan.rebasing(request.items, on: AppControlHandler.encoded(settings))
        if !plan.readOnly.isEmpty { throw AppControlError.readOnly(plan.readOnly.map(\.spec.key)) }
        let items = plan.applicable + plan.widening
        // Check every value before anything is deleted.
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

    /// The person approved a request on its card.
    func approveSettingsRequest(_ id: UUID) throws {
        try settingsApprovals.approve(id) { request in
            switch request.subject {
            case .settings: return try applyApprovedSettings(request)
            case .secret: return try applyApprovedSecret(request)
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

    /// Saves or removes an API key and lets the model checks run again.
    func setAgentSecret(_ secret: AppSecret, to value: String?, caller: String) throws {
        guard agentSecrets.write(secret.keychainAccount, value) else {
            throw AppControlError(code: "keychain_error", message: "LokalBot couldn't save the \(secret.title) to the Keychain.")
        }
        switch secret {
        case .openAICompatible: modelChecks.invalidate(for: settings)
        case .remoteTranscription: modelChecks.invalidate([.transcribe])
        case .autocompleteServer: modelChecks.invalidate([.autocomplete])
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
