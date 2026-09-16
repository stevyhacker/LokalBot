import SwiftUI

struct ModelsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme
    @SceneStorage("settings.models.page") private var pageValue = ModelsSettingsPage.active.rawValue
    @State private var sheet: ModelsSettingsSheet?

    private var page: Binding<ModelsSettingsPage> {
        Binding(get: { ModelsSettingsPage(rawValue: pageValue) ?? .active }, set: { pageValue = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Models").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                        Text("Choose what powers LokalBot.").font(.system(size: 14)).settingsSecondary()
                    }
                    Spacer()
                    Button("Check setup…") { sheet = .checks }
                        .buttonStyle(SettingsActionButtonStyle(prominent: true))
                        .accessibilityIdentifier("models.testAll")
                }
                Picker("Models view", selection: page) {
                    ForEach(ModelsSettingsPage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)
                .accessibilityIdentifier("models.pages")
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
            .background(SettingsPalette.panel(colorScheme))

            SettingsSeparator()
            ModelSetupFeedback(controller: app.modelSetup)
                .padding(.horizontal, 28)

            ScrollView {
                Group {
                    switch page.wrappedValue {
                    case .active:
                        ModelStackOverviewView(app: app, present: { sheet = $0 }, connections: showConnections)
                    case .downloaded:
                        ModelDownloadsView(app: app)
                    case .connections:
                        ModelConnectionsView(app: app)
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 18)
            }
            .accessibilityIdentifier("models.content")
            ModelStorageFooter(app: app) { page.wrappedValue = .downloaded }
                .padding(.horizontal, 28).padding(.vertical, 16)
                .background(SettingsPalette.panel(colorScheme))
                .overlay(alignment: .top) { SettingsSeparator() }
        }
        .background(SettingsPalette.canvas(colorScheme))
        .controlSize(.regular)
        .onChange(of: app.settings, initial: true) { app.modelChecks.invalidate(for: app.settings) }
        .onChange(of: app.focusedSettingID, initial: true) { revealFocusedSetting() }
        .sheet(item: $sheet) { destination in
            if let role = destination.pickerRole {
                ModelPickerSheet(app: app, role: role, openConnections: showConnections)
            } else {
                switch destination {
                case .presets: ModelPresetSheet(app: app)
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

    private func showConnections() {
        sheet = nil
        page.wrappedValue = .connections
    }

    private func revealFocusedSetting() {
        guard let id = app.focusedSettingID, id != "settings.models" else { return }
        switch id {
        case "settings.transcriptionModel": sheet = .transcription
        case "settings.transcriptionLanguage", "settings.transcriptionPrompt": sheet = .transcriptionOptions
        case "settings.cotypingBuiltInModelID": sheet = .autocomplete
        case "settings.dictationCompositionBuiltInModelID": sheet = .dictation
        case "settings.openAIBaseURL", "settings.openAIModel", "settings.ollamaBaseURL", "settings.openAIAPIKey",
             "settings.generationBudgetPreset":
            page.wrappedValue = .connections
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
                    Text("Preparing \(pending.title)…").font(.system(size: 13, weight: .medium))
                    Text("Your current models stay active until preparation finishes.")
                        .font(.system(size: 12)).settingsSecondary()
                }
                Spacer()
                Button("Cancel switch") { controller.cancelSwitch() }
                    .help("Keep the current selection. Shared downloads continue in Downloaded.")
            }
            .padding(.vertical, 14)
        } else if let failure = controller.failure {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(failure).font(.system(size: 13)).textSelection(.enabled)
                Spacer()
                Button("Retry") { controller.retry() }
                Button("Dismiss") { controller.dismissFeedback() }
            }
            .padding(.vertical, 14)
        } else if let completed = controller.completed {
            HStack {
                Label("Using \(completed.title)", systemImage: "checkmark.circle")
                    .font(.system(size: 13))
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

private struct ModelStorageFooter: View {
    @ObservedObject var app: AppState
    @ObservedObject private var roles: ModelRoles
    @ObservedObject private var residency = ModelResidency.shared
    @ObservedObject private var speech: ModelSpeechDownloadController
    let manage: () -> Void

    init(app: AppState, manage: @escaping () -> Void) {
        self.app = app
        roles = app.modelRoles
        speech = app.speechModelDownload
        self.manage = manage
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "internaldrive").font(.system(size: 20)).settingsSecondary()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text models: \(roles.snapshot.storageSummary)").font(.system(size: 13))
                    Text(memorySummary).font(.system(size: 12)).settingsSecondary()
                }
                Spacer(minLength: 8)
                Button(activeDownloads > 0
                       ? "Downloads (\(activeDownloads))" : "Manage downloads", action: manage)
                    .buttonStyle(.link)
                    .accessibilityIdentifier("models.manageDownloads")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.storage")
    }

    private var activeDownloads: Int {
        roles.downloadProgress.count + roles.transcriptionPreparations.count + (speech.isPreparing ? 1 : 0)
    }

    private var memorySummary: String {
        guard !residency.residents.isEmpty else { return "No models loaded in memory." }
        let used = ByteCountFormatter.string(fromByteCount: residency.totalBytes, countStyle: .memory)
        return "\(used) in memory · Models unload automatically when idle."
    }
}
