import AppKit
import SwiftUI

/// Four deliberate steps. Capture preferences remain a draft until Review;
/// permissions and model downloads happen only through their named actions.
struct OnboardingView: View {
    enum Mode { case welcome, permissions }
    enum Step: Int, CaseIterable {
        case capture, permissions, models, review
        var title: String {
            switch self {
            case .capture: "Choose What to Remember"
            case .permissions: "Enable the Access You Need"
            case .models: "Prepare Your Workflows"
            case .review: "Review and Start"
            }
        }
    }
    var mode: Mode = .welcome
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var step: Step = .capture
    /// Direction of the last step change, so the incoming page arrives from
    /// the side the user is moving toward.
    @State private var forward = true
    @State private var draft = CaptureSetupDraft(settings: AppSettings())
    @State private var initialGrants: [AppPermission: Bool] = [:]
    @State private var includeAutocomplete = false

    private var relevantPermissions: [AppPermission] {
        if mode == .permissions { return AppPermission.allCases }
        var result: [AppPermission] = [.microphone]
        if draft.dayMemory { result.append(.accessibility) }
        if draft.dayMemory && draft.contextMode.capturesPixels { result.append(.screenRecording) }
        return result
    }
    private var newlyGrantedRestartPermission: Bool {
        [.accessibility, .inputMonitoring, .screenRecording].contains {
            initialGrants[$0] != true && permissions.granted[$0] == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityLabel("LokalBot")
                if mode == .welcome {
                    HStack(spacing: 8) {
                        ForEach(Step.allCases, id: \.rawValue) { item in
                            Circle().fill(item == step ? LBTokens.Palette.accentText : Color.secondary.opacity(0.25))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue("Step \(step.rawValue + 1) of 4")
                    .accessibilityIdentifier("onboarding.progress")
                }
                Text(LocalizedStringKey(step.title)).font(.scaled(.largeTitle).bold()).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 8)
            ScrollView {
                // The ZStack lets the outgoing and incoming pages overlap
                // while they cross instead of stacking vertically.
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 20) {
                        switch step {
                        case .capture: captureChoices
                        case .permissions: permissionChoices
                        case .models: modelChoices
                        case .review: review
                        }
                    }
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .id(step)
                    .transition(WorkspaceMotion.stepTransition(forward: forward, reduceMotion: reduceMotion))
                }
            }
            Divider()
            HStack {
                Picker("App language", selection: $app.settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayName)).tag(language)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("onboarding.appLanguage")
                if mode == .welcome {
                    Text("Step \(step.rawValue + 1) of 4").font(.scaled(.callout)).foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .welcome {
                    Button("Back") { go(to: Step(rawValue: step.rawValue - 1) ?? .capture) }
                        .disabled(step == .capture)
                }
                if mode == .permissions {
                    Button("Done") { dismiss() }.primaryActionButton()
                } else if step == .review {
                    Button("Apply Choices and Start") {
                        app.finishOnboarding(applying: draft)
                        dismiss()
                    }.primaryActionButton().accessibilityIdentifier("onboarding.finish")
                } else {
                    Button(LocalizedStringKey(step == .permissions ? "Continue with Current Access" : "Continue")) {
                        go(to: Step(rawValue: step.rawValue + 1) ?? .review)
                    }.primaryActionButton().keyboardShortcut(.defaultAction)
                }
            }.padding(24)
        }
        .frame(width: 650, height: 640)
        .toggleStyle(LBAccentSwitchStyle())
        .onAppear {
            draft = CaptureSetupDraft(settings: app.settings)
            permissions.refresh()
            initialGrants = permissions.granted
            permissions.startPolling()
            if mode == .permissions { step = .permissions }
        }
        .onDisappear { permissions.stopPolling(); PermissionGuidanceController.shared.dismiss() }
    }

    private func go(to next: Step) {
        withAnimation(WorkspaceMotion.animation(.milestone, reduceMotion: reduceMotion)) {
            forward = next.rawValue > step.rawValue
            step = next
        }
    }

    private var captureChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep meeting evidence and a useful memory of your day. You can change each choice later in Settings.")
                .font(.scaled(.body)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Detected Meetings", selection: $draft.meetingMode) {
                        ForEach(AppSettings.AutoRecordMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }.accessibilityIdentifier("onboarding.meetingMode")
                    Text("Ask via notification waits for you to start recording. Manual mode keeps Record Now available.")
                        .workspaceTextRole(.supporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Toggle(isOn: $draft.dayMemory) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Day Memory")
                        Text("Remember app and window activity.").workspaceTextRole(.supporting)
                    }
                }
                .accessibilityLabel("Remember app and window activity")
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Day-Memory Detail", selection: $draft.contextMode) {
                        ForEach(AppSettings.ScreenContextCaptureMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                    }.disabled(!draft.dayMemory)
                    Text(LocalizedStringKey(draft.contextMode.detail)).workspaceTextRole(.trust)
                }
                Divider()
                Toggle(isOn: $draft.codingAgentSessions) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Coding Agent Sessions")
                        Text("Read your Claude Code and Codex sessions so LokalBot remembers what your agents did. Files stay on this Mac.")
                            .workspaceTextRole(.supporting)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityLabel("Read coding agent sessions")
                .accessibilityHint("Read your Claude Code and Codex sessions so LokalBot remembers what your agents did. Files stay on this Mac.")
                .accessibilityIdentifier("onboarding.codingAgentSessions")
            }.workspacePanel()
            VStack(alignment: .leading, spacing: 8) {
                Text("Text and images build on app activity. Images are encrypted on disk; captured text remains searchable under your retention policy.")
                    .workspaceTextRole(.supporting)
                Text("Private and incognito browser windows are captured like any other window unless you exclude the browser or site in Settings → Privacy & Data.")
                    .workspaceTextRole(.supporting)
            }
            Label("These choices are applied on the final Review step.", systemImage: "checklist")
                .workspaceTextRole(.supporting)
        }
    }

    private var permissionChoices: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Grant only what you need now. You can finish setup with missing permissions and enable the corresponding feature later.")
                .workspaceTextRole(.trust)
            ForEach(relevantPermissions, id: \.self) { permission in
                PermissionRow(permission: permission, prominentRationale: true)
                    .workspacePanel()
            }
            if newlyGrantedRestartPermission {
                Text("A newly granted permission may require a relaunch. Finish setup first; relaunch from Settings if the feature remains unavailable.")
                    .workspaceTextRole(.supporting)
            }
            Text("Autocomplete and global dictation shortcuts can be enabled later from Write.")
                .workspaceTextRole(.supporting)
        }
    }

    private var modelChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meeting processing needs a Transcribe model and a Think model. Downloads can be deferred; captured meetings wait for their selected models.")
                .workspaceTextRole(.trust)
            modelRow("Speech recognition", model: app.settings.transcriptionModelDisplayName, role: .transcribe)
            modelRow("Summaries and Ask", model: app.settings.thinkModelDisplayName, role: .think)
            InferenceDisclosure(settings: app.settings,
                                localText: "The configured Think model processes selected context on this Mac.",
                                remoteText: "Selected transcript and work context is sent to the approved model server.")
            Toggle("Also prepare Autocomplete (optional)", isOn: $includeAutocomplete)
                .accessibilityLabel("Also prepare Autocomplete (optional)")
            if includeAutocomplete {
                modelRow("Autocomplete", model: app.settings.cotypingBuiltInModelID, role: .autocomplete)
                Text("Autocomplete also reads the window you are typing in, such as the conversation you are answering, to fit its suggestions: the text just above the field, and, once Screen Recording is allowed, the whole window with on-device text recognition. It stays on this Mac and is never saved; turn either off in Settings → Writing.")
                    .workspaceTextRole(.supporting)
            }
            Button("Prepare Selected Models") {
                app.modelRoles.startCoreModelDownloads(includeAutocomplete: includeAutocomplete)
            }.buttonStyle(.bordered).accessibilityIdentifier("onboarding.downloadModels")
            Text("Downloads use the model provider. They do not send your meeting content. Existing downloaded models are kept.")
                .workspaceTextRole(.supporting)
        }
    }

    private func modelRow(_ title: String, model: String, role: ModelRole) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(AppFont.scaled(.body).weight(.semibold))
                Text(model).font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(app.modelRoles.snapshot[role].label).font(.scaled(.callout).weight(.semibold))
        }.workspacePanel()
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent("Meeting recording", value: draft.meetingMode.rawValue)
            LabeledContent("Day memory", value: draft.dayMemory ? draft.contextMode.rawValue : "Off")
            LabeledContent("Coding agent sessions") {
                Text(LocalizedStringKey(draft.codingAgentSessions ? "On" : "Off"))
            }
            LabeledContent("Think model", value: InferencePresentation(settings: app.settings).label)
            LabeledContent("Meeting models", value: app.modelRoles.snapshot.meetingReady ? "Ready to use · not a test result" : "Preparation can continue later")
            let missing = relevantPermissions.filter { permissions.granted[$0] != true }
            if !missing.isEmpty {
                Text("Still unavailable: " + missing.map(\.title).joined(separator: ", ") + ". Features needing this access stay unavailable until you grant it.")
                    .workspaceTextRole(.supporting)
            }
            Text("You can browse, search and edit your existing local library immediately. Setup does not delete any content or change existing remote-server approvals.")
                .workspaceTextRole(.trust)
        }
    }
}
