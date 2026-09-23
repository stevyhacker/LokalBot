import SwiftUI

struct DictationView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var dictation: DictationCoordinator
    var embedded = false
    @StateObject private var permissions = PermissionManager.shared

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
    }

    @ViewBuilder private var content: some View {
        statusSection
        if !embedded {
            Section("Shortcut and output") {
                LabeledContent("Shortcut", value: app.settings.dictationEnabled ? DictationShortcut.label : "Off")
                LabeledContent("Shortcut output", value: app.settings.dictationOutputMode.label)
                Button("Writing settings…") { app.openSettings(tab: .writing) }
            }
        }
        modelSection
        if app.settings.dictationEnabled { permissionsSection }
        if let result = app.dictation.lastComposedText {
            lastResultSection(result)
        } else if let transcript = app.dictation.lastTranscript {
            lastSpokenRequestSection(transcript)
        }
    }

    private var statusSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "mic.badge.plus")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictation").font(.headline)
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(actionTitle) { app.dictation.toggle(source: "rehearsal") }
                    .buttonStyle(.borderedProminent)
                    .tint(app.dictation.state.isRecording || app.dictation.isStarting ? .red : Brand.tealFill)
            }
            Picker(selection: Binding(get: { operation.dictationIntent }, set: { app.settings.dictationIntent = $0 })) {
                ForEach(DictationIntent.allCases) { Text($0.rawValue).tag($0) }
            } label: {
                SettingsLabel("Intent", help: operation.dictationIntent.detail)
            }.pickerStyle(.segmented).disabled(app.dictation.state != .idle || app.dictation.isStarting)
            if operation.dictationIntent == .compose {
                Toggle("Use the focused window as context", isOn: Binding(
                    get: { operation.dictationUseScreenContext }, set: { app.settings.dictationUseScreenContext = $0 }))
                    .disabled(app.dictation.state != .idle || app.dictation.isStarting)
            }
            SettingsHelp("Trying here shows the result below. It never inserts into another app or changes your clipboard; the shortcut uses the output setting above.")
        }
    }

    private var modelSection: some View {
        Section("Model") {
            LabeledContent("Transcription") {
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
                localText: "Speech uses the meeting ASR model; final wording uses your configured local composition model and writing profile. Everything stays on this Mac.",
                remoteText: "Final wording uses your approved remote Main LLM (\(operation.summarizerBackend.displayName)). What you dictate — and any screen context it composes with — is sent to that server.")
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
            if app.settings.dictationOutputMode == .pasteIntoFocusedApp {
                PermissionRow(permission: .accessibility, why: "Validates the focused field and inserts your text safely.")
            }
            if app.settings.dictationIntent == .compose && app.settings.dictationUseScreenContext {
                PermissionRow(permission: .screenRecording, why: "Reads only the focused window for this request. The image and OCR text are never stored.")
            }
            if !app.dictation.isShortcutMonitoringActive {
                HStack {
                    Text("Relaunch after granting Input Monitoring if the shortcut is still inactive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Relaunch") { PermissionManager.relaunch() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func lastResultSection(_ result: String) -> some View {
        Section("Last result") {
            Text(result)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let spoken = app.dictation.lastTranscript {
                Text("Spoken request: \(spoken)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let engine = app.dictation.lastEngine {
                Text(engine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lastSpokenRequestSection(_ transcript: String) -> some View {
        Section("Last spoken request") {
            Text(transcript)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusText: String {
        if app.dictation.isStarting { return "Starting the microphone…" }
        switch app.dictation.state {
        case .idle:
            if app.settings.dictationEnabled {
                return app.dictation.isShortcutMonitoringActive
                    ? "Ready — hold \(DictationShortcut.label) to dictate."
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
