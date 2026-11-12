import SwiftUI

/// Settings › Dictation, under the shared header: the shortcut, what it
/// writes, what shows while dictating, and a row that opens the recent
/// dictations. Trying it out is the header's "Try it…" sheet.
struct DictationSettingsSections: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var dictation: DictationCoordinator
    @ObservedObject private var permissions = PermissionManager.shared
    /// The page a row opened, when one is open.
    let subpage: SettingsSubpage?
    let open: (SettingsSubpage) -> Void
    /// Opens a model picker over the page.
    let changeModel: (ModelPickerRole) -> Void
    @State private var microphones: [DictationMicrophone.Option] = []

    private var operation: AppSettings { dictation.presentedConfiguration }
    private var localized: (String) -> String { app.settings.appLanguage.catalog }
    /// A recording keeps the settings it started with.
    private var busy: Bool { dictation.state != .idle || dictation.isStarting }

    var body: some View {
        Group {
            switch subpage {
            case .dictationProfile: profileSection
            case .dictationRecent: recentSection
            default: mainSections
            }
        }
        .onAppear { app.dictation.applySettings() }
        .onDisappear { PermissionGuidanceController.shared.dismiss() }
        .onChange(of: permissions.granted) { _, _ in app.dictation.applySettings() }
    }

    @ViewBuilder private var mainSections: some View {
        // The page header says which permission is missing and asks for it;
        // only the relaunch a granted shortcut may need stays here.
        if app.settings.dictationEnabled, !app.dictation.isShortcutMonitoringActive,
           permissions.granted[.inputMonitoring] == true {
            Section {
                HStack {
                    SettingsHelp("Relaunch after granting Input Monitoring if the shortcut is still inactive.")
                    Spacer()
                    Button("Relaunch") { PermissionManager.relaunch() }
                        .controlSize(.small)
                }
            }
        }
        shortcutSection
        writingSection
        whileDictatingSection
        Section("More") {
            SettingsDrillRow(title: "Recent dictations",
                             detail: "The last 10, kept encrypted for 7 days",
                             value: dictation.history.entries.isEmpty
                                ? localized("None yet") : String(dictation.history.entries.count),
                             identifier: "settings.dictation.recent") { open(.dictationRecent) }
        }
    }

    // MARK: - Shortcut

    private var shortcutSection: some View {
        Section("Shortcut") {
            LabeledContent {
                ShortcutRecorder(
                    shortcut: $app.settings.dictationShortcut,
                    defaultShortcut: .handyDefault,
                    accessibilityIdentifier: "settings.dictationShortcut",
                    changeHelp: "Change the dictation shortcut",
                    validate: { candidate in
                        candidate.problem
                            ?? (candidate == app.settings.quickRecallShortcut ? .usedByAsk : nil)
                            ?? (candidate == app.settings.selectionActionsShortcut ? .usedBySelectionActions : nil)
                            ?? (candidate == app.settings.windowHandoffShortcut ? .usedByWindowHandoff : nil)
                    },
                    onRecordingChanged: { app.setShortcutRecording($0) })
            } label: {
                // The page's anchor for tests and captures. On a container it
                // would replace the identifier of every row inside.
                Text("Shortcut").accessibilityIdentifier("dictation.form")
            }
            .settingTarget("settings.dictationShortcut", selected: app.focusedSettingID)
            Picker("Start and stop", selection: $app.settings.dictationTriggerMode) {
                ForEach(DictationTriggerMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            .settingTarget("settings.dictationTriggerMode", selected: app.focusedSettingID)
            Picker("When you finish", selection: $app.settings.dictationOutputMode) {
                ForEach(DictationOutputMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            .settingTarget("settings.dictationOutputMode", selected: app.focusedSettingID)
            LabeledContent("Microphone") {
                HStack(spacing: 8) {
                    SettingsInfoButton("With AirPods, choose the MacBook microphone to keep the headset's audio quality while you dictate.")
                    Picker("Microphone", selection: $app.settings.dictationMicrophoneID) {
                        ForEach(DictationMicrophone.options(
                            preferredID: app.settings.dictationMicrophoneID, available: microphones,
                            defaultName: app.settings.appLanguage.localized("System default"))) { option in
                            Text(LocalizedStringKey(option.name)).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .settingTarget("settings.dictationMicrophoneID", selected: app.focusedSettingID)
            .onAppear { microphones = DictationMicrophone.available() }
        }
    }

    // MARK: - What it writes

    private var writingSection: some View {
        Section("What it writes") {
            Picker(selection: Binding(get: { operation.dictationIntent }, set: { app.settings.dictationIntent = $0 })) {
                ForEach(DictationIntent.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            } label: {
                SettingsLabel("Mode", help: operation.dictationIntent == .compose
                              ? "Say “reply…”, “write…” or “draft…” and it writes the text for you. Anything else is typed as you said it, cleaned up."
                              : "Types what you say. Nothing is rewritten, and nothing on screen is read.")
            }
            .pickerStyle(.segmented).tint(Brand.tealFill).disabled(busy)
            .accessibilityIdentifier("settings.dictationIntent")
            .settingTarget("settings.dictationIntent", selected: app.focusedSettingID)
            if operation.dictationIntent == .compose {
                SettingsHelp("Compose may read, only for that request:")
                Group {
                    SettingsSwitchRow("The focused window", detail: "Needs Screen Recording",
                                      info: "Reads the focused window's text from a screenshot. Needs Screen Recording; the image and text are not saved.",
                                      isOn: Binding(get: { operation.dictationUseScreenContext },
                                                    set: { app.settings.dictationUseScreenContext = $0 }))
                        .disabled(busy)
                        .settingTarget("settings.dictationUseScreenContext", selected: app.focusedSettingID)
                    SettingsSwitchRow("Text above where you type",
                                      info: "Reads nearby messages and labels through Accessibility. No screenshot is needed, and the excerpts are not saved.",
                                      isOn: $app.settings.dictationUseVisibleContext)
                        .disabled(busy)
                        .settingTarget("settings.dictationUseVisibleContext", selected: app.focusedSettingID)
                    SettingsSwitchRow("Facts from your meetings",
                                      info: "Adds relevant saved facts when you ask Compose to draft or reply. Reads what is already saved; it does not start an overnight review.",
                                      isOn: $app.settings.dictationUseMeetingMemory)
                        .disabled(busy)
                        .settingTarget("settings.dictationUseMeetingMemory", selected: app.focusedSettingID)
                    SettingsSwitchRow("Facts from your screen history",
                                      info: "Adds relevant saved facts when you ask Compose to draft or reply. Reads what is already saved; it does not start an overnight review.",
                                      isOn: $app.settings.dictationUseScreenMemory)
                        .disabled(busy)
                        .settingTarget("settings.dictationUseScreenMemory", selected: app.focusedSettingID)
                    SettingsDrillRow(title: "Writing profile", detail: "Shared with Autocomplete",
                                     value: DictationView.writingProfileSummary(app.settings, localized: localized),
                                     identifier: "dictation.writingProfile.edit") { open(.dictationProfile) }
                        .settingTarget("settings.dictationWritingProfile", selected: app.focusedSettingID)
                }
                .padding(.leading, 14)
            }
            writerRow
        }
    }

    /// Where the dictated words become the text that is pasted. When that is
    /// a service, the row says that what is dictated goes there.
    @ViewBuilder private var writerRow: some View {
        let writer = DictationWriterPresentation(settings: operation)
        LabeledContent {
            Button("Change…") { changeModel(writer.pickerRole) }
                .accessibilityIdentifier("settings.dictation.writer.change")
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Who writes the text")
                Text(verbatim: writer.text.string(localized))
                    .font(.scaled(.callout))
                    .foregroundStyle(writer.online ? AnyShapeStyle(LBTokens.Palette.attentionText)
                                     : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.dictation.writer")
            }
        }
        .padding(.leading, operation.dictationIntent == .compose ? 14 : 0)
        if operation.dictationIntent == .compose, writer.online {
            // What else travels with the dictated words, said in full.
            InferenceDisclosure(
                settings: operation.dictationCompositionTextEngineSettings,
                localText: "Speech uses the meeting ASR model; final wording uses your local composition model and writing profile. Everything stays on this Mac.",
                remoteText: "Final wording uses your approved remote Think model (\(operation.summarizerBackend.displayName)). What you dictate, and any enabled screen context or saved facts it uses, is sent to that server.")
                .padding(.leading, 14)
                .accessibilityIdentifier("dictation.remoteNotice")
        }
    }

    // MARK: - While dictating

    private var whileDictatingSection: some View {
        Section("While dictating") {
            SettingsSwitchRow("Show a small status window", isOn: $app.settings.dictationShowOverlay)
                .settingTarget("settings.dictationShowOverlay", selected: app.focusedSettingID)
            SettingsSwitchRow("Show the words as you speak", isOn: $app.settings.dictationLivePreview)
                .settingTarget("settings.dictationLivePreview", selected: app.focusedSettingID)
            SettingsSwitchRow("Play a sound when the microphone is ready", isOn: $app.settings.dictationPlaysStartSound)
                .settingTarget("settings.dictationPlaysStartSound", selected: app.focusedSettingID)
            SettingsSwitchRow("Keep the audio files", isOn: $app.settings.dictationRetainAudio)
                .settingTarget("settings.dictationRetainAudio", selected: app.focusedSettingID)
        }
    }

    // MARK: - The pages the rows open

    /// Compose takes tone, name and terminology from the writing profile it
    /// shares with Autocomplete, so its fields are edited here too.
    private var profileSection: some View {
        Section {
            WritingProfileFields()
        } footer: {
            SettingsHelp("Compose uses it for tone, your name and terminology. Autocomplete uses the same profile.")
        }
    }

    @ViewBuilder private var recentSection: some View {
        if dictation.history.entries.isEmpty {
            Section {
                SettingsHelp("Nothing dictated in the last 7 days.")
                    .accessibilityIdentifier("dictation.recent.empty")
            }
        } else {
            RecentDictationsSection(
                entries: dictation.history.entries,
                localized: { app.settings.appLanguage.localized($0) },
                copy: { dictation.copyFromHistory($0) },
                clear: { dictation.clearHistory() })
        }
    }
}

/// "Try it…" on Dictation: speak, and the result shows here. Nothing is
/// pasted into another app and the clipboard is left alone.
struct DictationTrySheet: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var dictation: DictationCoordinator
    /// What the page header says, for what still stands in the way.
    let status: SettingsStatus
    @Environment(\.dismiss) private var dismiss

    /// The header's lines that stop a try-out: the microphone and the model.
    /// The header shows them only while the shortcut is on.
    private var blockers: [SettingsStatusLine] {
        var input = status.input
        input.settings.dictationEnabled = true
        return SettingsStatus(input).lines(for: .dictation).filter { line in
            line.id == "allow.microphone" || line.id.hasPrefix("model.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Try dictation").font(AppFont.scaled(.title2).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text("The result shows here. Nothing is pasted into another app, and your clipboard is left alone.")
                    .font(AppFont.scaled(.callout)).settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(blockers) { line in
                        SettingsStatusLineRow(line: line, page: .dictation)
                    }
                    DictationView(dictation: dictation)
                }
                .padding(.horizontal, 22).padding(.bottom, 16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .primaryActionButton()
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dictation.try.done")
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 560)
        .frame(minHeight: 340, maxHeight: 620)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictation.try")
    }
}

/// The try-out itself: the button that starts and stops a recording, where
/// it stands, and the last result.
struct DictationView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: DictationCoordinator
    /// Nil when Secure Input is off; otherwise the app holding it, if known.
    @State private var secureInputHolder: String??
    private let secureInputPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var operation: AppSettings { dictation.presentedConfiguration }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(systemImage: "mic", tint: Brand.teal, size: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(AppFont.scaled(.body))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Mode: \(app.settings.appLanguage.localized(operation.dictationIntent.rawValue))")
                        .font(AppFont.scaled(.callout))
                        .settingsSecondary()
                }
                Spacer(minLength: 12)
                Button(actionTitle) { app.dictation.toggle(source: "rehearsal") }
                    .buttonStyle(.borderedProminent)
                    .tint(app.dictation.state.isRecording || app.dictation.isStarting ? .red : Brand.tealFill)
                    .accessibilityIdentifier("dictation.try.action")
            }
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
            if let result = app.dictation.lastComposedText {
                lastResult(result)
            } else if let transcript = app.dictation.lastTranscript {
                lastSpokenRequest(transcript)
            } else {
                resultBox(nil) {
                    Text("Your words appear here.").settingsSecondary()
                }
            }
        }
        .onAppear { secureInputHolder = DictationSecureInput.holder() }
        .onReceive(secureInputPoll) { _ in secureInputHolder = DictationSecureInput.holder() }
    }

    private func resultBox<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(LocalizedStringKey(title)).font(AppFont.scaled(.callout).weight(.semibold)).settingsSecondary()
            }
            VStack(alignment: .leading, spacing: 8, content: content)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Brand.Radius.control)
                        .strokeBorder(Color(nsColor: .separatorColor))
                        .allowsHitTesting(false)
                }
        }
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

    private func lastResult(_ result: String) -> some View {
        resultBox("Last result") {
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

    private func lastSpokenRequest(_ transcript: String) -> some View {
        resultBox("Last spoken request") {
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
