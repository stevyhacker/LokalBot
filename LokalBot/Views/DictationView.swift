import SwiftUI

struct DictationView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: DictationCoordinator
    var embedded = false
    @StateObject private var permissions = PermissionManager.shared
    /// Nil when Secure Input is off; otherwise the app holding it, if known.
    @State private var secureInputHolder: String??
    private let secureInputPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var operation: AppSettings { dictation.presentedConfiguration }

    var body: some View {
        Group {
            if embedded { content } else { Form { content }.formStyle(.grouped) }
        }
        .accessibilityIdentifier("dictation.form")
        .onAppear {
            if !embedded { permissions.startPolling() }
            app.dictation.applySettings()
        }
        .onDisappear {
            if !embedded { permissions.stopPolling() }
            PermissionGuidanceController.shared.dismiss()
        }
        .onChange(of: permissions.granted) { _, _ in app.dictation.applySettings() }
        .onAppear { secureInputHolder = DictationSecureInput.holder() }
        .onReceive(secureInputPoll) { _ in secureInputHolder = DictationSecureInput.holder() }
    }

    @ViewBuilder private var content: some View {
        statusSection
        if !embedded {
            Section("Shortcut and output") {
                LabeledContent(
                    "Shortcut",
                    value: app.settings.dictationEnabled ? app.settings.dictationShortcut.displayLabel : "Off")
                LabeledContent("Shortcut output", value: app.settings.dictationOutputMode.label)
                Button("Dictation settings…") { app.openSettings(tab: .dictation) }
            }
        }
        modelSection
        if app.settings.dictationEnabled { permissionsSection }
        if let result = app.dictation.lastComposedText {
            lastResultSection(result)
        } else if let transcript = app.dictation.lastTranscript {
            lastSpokenRequestSection(transcript)
        }
        recentSection
    }

    private var statusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                IconTile(systemImage: "mic", tint: Brand.teal, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dictation").font(AppFont.scaled(.body).weight(.semibold))
                    Text(statusText)
                        .font(AppFont.scaled(.callout))
                        .settingsSecondary()
                }
                Spacer()
                Button(actionTitle) { app.dictation.toggle(source: "rehearsal") }
                    .buttonStyle(.borderedProminent)
                    .tint(app.dictation.state.isRecording || app.dictation.isStarting ? .red : Brand.tealFill)
            }
            .padding(.vertical, 4)
            // The Dictation command lands on this row; highlight it alone,
            // never every row of the sections below.
            .settingTarget("settings.dictationPreview", selected: embedded ? app.focusedSettingID : nil)
            if app.settings.dictationEnabled, let holder = secureInputHolder {
                Label {
                    Text(verbatim: DictationSecureInput.message(appName: holder) { app.settings.appLanguage.localized($0) })
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                }
                .font(AppFont.scaled(.callout))
                .accessibilityIdentifier("dictation.secureInputWarning")
            }
            Picker(selection: Binding(get: { operation.dictationIntent }, set: { app.settings.dictationIntent = $0 })) {
                ForEach(DictationIntent.allCases) { Text($0.rawValue).tag($0) }
            } label: {
                SettingsLabel("Intent", help: operation.dictationIntent.detail)
            }.pickerStyle(.segmented).tint(Brand.tealFill).disabled(app.dictation.state != .idle || app.dictation.isStarting)
            if operation.dictationIntent == .compose {
                SettingsHelp("The sources below are read only when you start with a writing request, such as “reply…”, “write…” or “draft…”. Other dictation is only cleaned up.")
                Toggle("Use the focused window as context", isOn: Binding(
                    get: { operation.dictationUseScreenContext }, set: { app.settings.dictationUseScreenContext = $0 }))
                    .disabled(app.dictation.state != .idle || app.dictation.isStarting)
                    .settingTarget("settings.dictationUseScreenContext", selected: app.focusedSettingID)
                SettingsHelp("Reads the focused window's text from a screenshot. Needs Screen Recording; the image and text are not saved.")
                Toggle("Use visible text above the field", isOn: $app.settings.dictationUseVisibleContext)
                    .disabled(app.dictation.state != .idle || app.dictation.isStarting)
                    .settingTarget("settings.dictationUseVisibleContext", selected: app.focusedSettingID)
                SettingsHelp("Reads nearby messages and labels through Accessibility. No screenshot is needed, and the excerpts are not saved.")
                Toggle("Use meeting and work memory", isOn: $app.settings.dictationUseMeetingMemory)
                    .disabled(app.dictation.state != .idle || app.dictation.isStarting)
                    .settingTarget("settings.dictationUseMeetingMemory", selected: app.focusedSettingID)
                Toggle("Use screen-derived work memory", isOn: $app.settings.dictationUseScreenMemory)
                    .disabled(app.dictation.state != .idle || app.dictation.isStarting)
                    .settingTarget("settings.dictationUseScreenMemory", selected: app.focusedSettingID)
                SettingsHelp("Adds relevant saved facts when you ask Compose to draft or reply. Reads what is already saved; it does not start an overnight review.")
                writingProfileRow
            }
            SettingsHelp("Trying here shows the result below. It never inserts into another app or changes your clipboard; the shortcut uses the output setting above.")
        } header: {
            if embedded { Text("Try dictation") }
        }
    }

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Transcribe model") {
                Text(operation.transcriptionModelDisplayName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Language") {
                Text(operation.transcriptionLanguage.displayName)
                    .foregroundStyle(.secondary)
            }
            if operation.dictationIntent == .compose {
            LabeledContent("Compose") {
                Text(operation.dictationCompositionTextEngineSettings.thinkModelDisplayName)
                    .foregroundStyle(.secondary)
            }
            // Where the words go changes what dictation means, so the remote
            // case reads as a first-class notice, not caption fine print.
            InferenceDisclosure(
                settings: operation.dictationCompositionTextEngineSettings,
                localText: "Speech uses the meeting ASR model; final wording uses your local composition model and writing profile. Everything stays on this Mac.",
                remoteText: "Final wording uses your approved remote Think model (\(operation.summarizerBackend.displayName)). What you dictate, and any enabled screen context or saved facts it uses, is sent to that server.")
                .accessibilityIdentifier("dictation.remoteNotice")
            } else {
                Label("Speech recognition runs on this Mac. No screen context or rewrite model is used.", systemImage: "desktopcomputer")
                    .workspaceTextRole(.trust)
            }
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            PermissionRow(permission: .microphone, why: "Records your voice for the current dictation.")
            PermissionRow(permission: .inputMonitoring, why: "Detects the global dictation shortcut.")
            if app.settings.dictationOutputMode == .pasteIntoFocusedApp || app.settings.dictationUseVisibleContext {
                PermissionRow(permission: .accessibility, why: "Validates the focused field and inserts your text safely.")
            }
            if app.settings.dictationIntent == .compose && app.settings.dictationUseScreenContext {
                PermissionRow(permission: .screenRecording, why: "Reads only the focused window for this request. The image and OCR text are never stored.")
            }
            if !app.dictation.isShortcutMonitoringActive {
                HStack {
                    SettingsHelp("Relaunch after granting Input Monitoring if the shortcut is still inactive.")
                    Spacer()
                    Button("Relaunch") { PermissionManager.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }

    /// Compose takes tone, name and terminology from the writing profile,
    /// which lives with Autocomplete on the Writing page.
    private var writingProfileRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(verbatim: Self.writingProfileSummary(app.settings) { app.settings.appLanguage.localized($0) })
                    .settingsSecondary()
                    .lineLimit(1)
                Button("Edit…") {
                    app.openSettings(tab: .writing)
                    app.focusedSettingID = "settings.cotypingUserName"
                }
                .accessibilityIdentifier("dictation.writingProfile.edit")
            }
        } label: {
            SettingsLabel("Writing profile", help: "Compose uses it for tone, your name and terminology.")
        }
        .settingTarget("settings.dictationWritingProfile", selected: app.focusedSettingID)
    }

    static func writingProfileSummary(_ settings: AppSettings, localized: (String) -> String = { $0 }) -> String {
        let profile = DictationComposeProfile(personalization: settings.cotypingPersonalization)
        let parts = [
            profile.userName.map { _ in localized("Name") },
            profile.styleNote.map { _ in localized("Style") },
            profile.languageHint.map { _ in localized("Languages") },
            profile.glossary.map { _ in localized("Terminology") },
        ].compactMap { $0 }
        return parts.isEmpty ? localized("Not set") : parts.joined(separator: ", ")
    }

    private func lastResultSection(_ result: String) -> some View {
        Section("Last result") {
            Text(result)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let spoken = app.dictation.lastTranscript {
                SettingsHelp("Spoken request: \(spoken)")
                    .textSelection(.enabled)
            }
            if let contextUse = app.dictation.lastContextUse {
                // Verbatim: saved-fact titles are user text, not markdown.
                Text(verbatim: contextUse.summary { app.settings.appLanguage.localized($0) })
                    .font(.scaled(.callout))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("dictation.lastContextUse")
            }
            if let engine = app.dictation.lastEngine {
                SettingsHelp(engine)
            }
            if let latest = latestShownAbove {
                DictationCopyButton { dictation.copyFromHistory(latest.id) }
            }
        }
    }

    private func lastSpokenRequestSection(_ transcript: String) -> some View {
        Section("Last spoken request") {
            Text(transcript)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let latest = latestShownAbove {
                DictationCopyButton { dictation.copyFromHistory(latest.id) }
            }
        }
    }

    /// The kept dictation that the last-result section above already shows.
    private var latestShownAbove: DictationHistoryEntry? {
        guard let latest = dictation.history.entries.first,
              latest.text == (dictation.lastComposedText ?? dictation.lastTranscript) else { return nil }
        return latest
    }

    @ViewBuilder private var recentSection: some View {
        let entries = dictation.history.entries
        let earlier = latestShownAbove == nil ? entries : Array(entries.dropFirst())
        if !earlier.isEmpty {
            RecentDictationsSection(
                entries: earlier,
                localized: { app.settings.appLanguage.localized($0) },
                copy: { dictation.copyFromHistory($0) },
                clear: { dictation.clearHistory() })
        }
    }

    static func readyText(triggerMode: DictationTriggerMode, shortcut: DictationShortcut) -> String {
        switch triggerMode {
        case .pushToTalk:
            "Ready — hold \(shortcut.displayLabel) to dictate."
        case .toggle:
            "Ready — press \(shortcut.displayLabel) to start and again to finish."
        case .tapOrHold:
            "Ready — tap \(shortcut.displayLabel) to start and stop, or hold it while you talk."
        }
    }

    private var statusText: String {
        if app.dictation.isStarting { return "Starting the microphone…" }
        switch app.dictation.state {
        case .idle:
            if app.settings.dictationEnabled {
                return app.dictation.isShortcutMonitoringActive
                    ? Self.readyText(
                        triggerMode: app.settings.dictationTriggerMode,
                        shortcut: app.settings.dictationShortcut)
                    : "Shortcut inactive."
            }
            return "Ready from this screen. Turn on the shortcut for system-wide use."
        case .recording:
            return "Listening \(app.dictation.timerLabel)"
        case .transcribing:
            return "Transcribing \(app.dictation.timerLabel)"
        case .composing:
            return "Composing \(app.dictation.timerLabel)"
        }
    }

    private var actionTitle: String {
        if app.dictation.isStarting { return "Cancel" }
        return switch app.dictation.state {
        case .idle: "Try here"
        case .recording: "Stop & finish"
        case .transcribing, .composing: "Cancel"
        }
    }
}
