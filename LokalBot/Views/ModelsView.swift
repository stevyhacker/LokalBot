import AppKit
import SwiftUI

struct ModelsView: View {
    /// Matches the width of the grouped settings forms on the other tabs.
    static let contentWidth: CGFloat = LBTokens.Metric.readingMaxWidth
    @EnvironmentObject var app: AppState
    @SceneStorage("settings.models.page") private var pageValue = ModelsSettingsPage.active.rawValue
    @State private var sheet: ModelsSettingsSheet?
    @State private var selectedPreset = ModelStackPreset.recommended
    /// What the shared page header says about the models.
    let status: SettingsStatus

    private var page: Binding<ModelsSettingsPage> {
        Binding(get: { ModelsSettingsPage(rawValue: pageValue) ?? .active }, set: { pageValue = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The page opens with the shared Settings header, which carries
            // the download; the pages it opens keep their way back.
            Group {
                if page.wrappedValue == .active {
                    SettingsPageHeader(page: .models, status: status) { downloadControl }
                        .settingsPageHeaderCard()
                } else {
                    HStack(spacing: 12) {
                        Button { page.wrappedValue = .active } label: {
                            Label("Models", systemImage: "chevron.backward")
                        }
                        .accessibilityIdentifier("models.back")
                        Text(LocalizedStringKey(page.wrappedValue.title)).font(.scaled(.headline))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 12)
                    }
                }
            }
            .frame(maxWidth: Self.contentWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.vertical, 14)

            ModelSetupFeedback(controller: app.modelSetup)
                .frame(maxWidth: Self.contentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        switch page.wrappedValue {
                        case .active:
                            ModelStackOverviewView(app: app, present: { sheet = $0 },
                                                   open: { page.wrappedValue = $0 },
                                                   choosePreset: { selectedPreset = $0; sheet = .presets })
                        case .downloaded:
                            ModelDownloadsView(app: app)
                        case .connections:
                            VStack(alignment: .leading, spacing: 18) {
                                ModelRemoteOverview(app: app)
                                ModelConnectionsView(app: app)
                            }
                        case .other:
                            ModelOtherModelsView(app: app, present: { sheet = $0 })
                        }
                    }
                    // Every page shares one centered column, like other Settings tabs.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxWidth: Self.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28).padding(.bottom, 18)
                }
                .accessibilityIdentifier("models.content")
                .id(page.wrappedValue)
                .onChange(of: app.focusedSettingID, initial: true) {
                    guard let id = app.focusedSettingID, Self.settingsOnThePage.contains(id) else { return }
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }

        }
        .controlSize(.regular)
        .onChange(of: app.settings, initial: true) { app.modelChecks.invalidate(for: app.settings) }
        .onChange(of: app.focusedSettingID, initial: true) { revealFocusedSetting() }
        .sheet(item: $sheet) { destination in
            if let role = destination.pickerRole {
                ModelPickerSheet(app: app, role: role, openConnections: showConnections)
            } else {
                switch destination {
                case .presets: ModelPresetSheet(app: app, initialPreset: selectedPreset)
                case .checks: ModelChecksSheet(app: app)
                case .speech: ModelSpeechSettingsSheet(app: app)
                case .search: ModelSearchSettingsSheet(app: app)
                case .transcriptionOptions: ModelTranscriptionOptionsSheet(app: app)
                default: EmptyView()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.settings")
    }

    /// The settings that are rows of the page itself, under Advanced.
    private static let settingsOnThePage = ModelStackOverviewView.advancedSettings
        .union([SettingsStatus.modelChecksFocus])

    /// One button for every model that is missing, and Cancel while they
    /// arrive. Nothing once they are all here.
    @ViewBuilder private var downloadControl: some View {
        if !status.modelsDownloading.isEmpty {
            Button("Cancel") { app.modelRoles.cancelCoreModelDownloads() }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel the download")
                .accessibilityIdentifier("models.cancelDownloads")
        } else if !status.modelsToDownload.isEmpty {
            Button {
                SettingsStatusActions.perform(.download, in: app)
            } label: {
                if let bytes = status.bytesToDownload {
                    Text("Download all · \(SettingsStatus.size(bytes))")
                } else {
                    Text("Download all")
                }
            }
            .primaryActionButton()
            .accessibilityIdentifier("models.downloadAll")
        }
    }

    private func showConnections() {
        sheet = nil
        page.wrappedValue = .connections
    }

    private func revealFocusedSetting() {
        guard let id = app.focusedSettingID, id != "settings.models" else { return }
        switch id {
        case "settings.transcriptionModel": sheet = .transcription
        case "settings.transcriptionLanguage", "settings.transcriptionPrompt",
             "settings.autoTranscriptionVocabulary": sheet = .transcriptionOptions
        case "settings.cotypingBuiltInModelID", "settings.cotypingBackend": sheet = .autocomplete
        case "settings.dictationCompositionBuiltInModelID": sheet = .dictation
        case "settings.speechVoice": sheet = .speech
        case "settings.openAIBaseURL", "settings.openAIModel", "settings.ollamaBaseURL", "settings.openAIAPIKey":
            page.wrappedValue = .connections
        case SettingsStatus.modelChecksFocus:
            // A check that failed: the page's line opens the sheet that says why.
            page.wrappedValue = .active
            sheet = .checks
        case _ where ModelStackOverviewView.advancedSettings.contains(id):
            page.wrappedValue = .active
        default: sheet = .assistant
        }
    }
}

struct ModelSetupFeedback: View {
    @ObservedObject var controller: ModelSetupController

    var body: some View {
        if let pending = controller.pending {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Preparing \(pending.title)…").font(.scaled(.body).weight(.medium))
                    Text("Your current models stay active until preparation finishes.")
                        .font(.scaled(.callout)).settingsSecondary()
                }
                Spacer()
                Button("Cancel Switch") { controller.cancelSwitch() }
                    .help("Keep the current selection. Shared downloads continue in Downloaded.")
            }
            .padding(.vertical, 14)
        } else if let failure = controller.failure {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(failure).font(.scaled(.body)).textSelection(.enabled)
                Spacer()
                if controller.failedChange != nil {
                    Button("Retry") { controller.retry() }
                }
                Button("Dismiss") { controller.dismissFeedback() }
            }
            .padding(.vertical, 14)
        } else if let completed = controller.completed {
            HStack {
                if completed.patch.transcription == nil, completed.patch.funASRNanoDirectory == "" {
                    Label("Model folder selection cleared", systemImage: "checkmark.circle").font(.scaled(.body))
                } else {
                    Label("Using \(completed.title)", systemImage: "checkmark.circle").font(.scaled(.body))
                }
                Spacer()
                if completed.patch != completed.previous {
                    Button("Undo") { controller.undo() }.accessibilityIdentifier("models.undo")
                }
                Button { controller.dismissFeedback() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss model change")
            }
            .padding(.vertical, 14)
        }
    }
}

/// Settings → Models and onboarding: where pinned model files download from.
/// The explanation follows the choice, and the menu keeps its full width.
struct ModelDownloadSourcePicker: View {
    @Binding var source: ModelDownloadSource
    let accessibilityIdentifier: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsLabel("Download models from", help: source.detail)
            Spacer(minLength: 8)
            Picker("Download models from", selection: $source) {
                ForEach(ModelDownloadSource.allCases) { choice in
                    Text(LocalizedStringKey(choice.displayName)).tag(choice)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
