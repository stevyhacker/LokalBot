import AppKit
import SwiftUI

struct ModelsView: View {
    static let contentWidth: CGFloat = LBTokens.Metric.readingMaxWidth
    @EnvironmentObject var app: AppState
    @SceneStorage("settings.models.page") private var pageValue = ModelsSettingsPage.active.rawValue
    @State private var sheet: ModelsSettingsSheet?
    @State private var selectedPreset = ModelStackPreset.recommended
    let status: SettingsStatus

    private var page: Binding<ModelsSettingsPage> {
        Binding(get: { ModelsSettingsPage(rawValue: pageValue) ?? .active }, set: { pageValue = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            ModelSetupFeedback(controller: app.modelSetup, roles: app.modelRoles)
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

    private static let settingsOnThePage = ModelStackOverviewView.advancedSettings
        .union([SettingsStatus.modelChecksFocus])

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
    @ObservedObject var roles: ModelRoles

    var body: some View {
        if let pending = controller.pending {
            let preparation = pending.patch.transcriptionToPrepare.flatMap {
                roles.transcriptionPreparations[$0.id]
            }
            HStack(spacing: 10) {
                if let fraction = preparation?.progress, fraction > 0, fraction < 1 {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Preparing \(pending.title)…").font(.scaled(.body).weight(.medium))
                    if let preparation {
                        Text(verbatim: preparationDetail(for: preparation))
                            .font(.scaled(.callout)).settingsSecondary()
                    } else {
                        Text("Your current models stay active until preparation finishes.")
                            .font(.scaled(.callout)).settingsSecondary()
                    }
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

    private func preparationDetail(for preparation: ModelRoles.TranscriptionPreparation) -> String {
        if let fraction = preparation.progress, fraction > 0, fraction < 1 {
            return "\(preparation.label) \(Int(fraction * 100))%"
        }
        return preparation.label
    }
}

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
