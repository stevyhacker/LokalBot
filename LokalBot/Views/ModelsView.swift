import AppKit
import SwiftUI

struct ModelsView: View {
    /// Matches the width of the grouped settings forms on the other tabs.
    static let contentWidth: CGFloat = LBTokens.Metric.readingMaxWidth
    @EnvironmentObject var app: AppState
    @SceneStorage("settings.models.page") private var pageValue = ModelsSettingsPage.active.rawValue
    @State private var sheet: ModelsSettingsSheet?
    @State private var selectedPreset = ModelStackPreset.recommended

    private var page: Binding<ModelsSettingsPage> {
        Binding(get: { ModelsSettingsPage(rawValue: pageValue) ?? .active }, set: { pageValue = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The page title and subtitle come from the shared Settings header.
            HStack(spacing: 12) {
                if page.wrappedValue != .active {
                    Button { page.wrappedValue = .active } label: {
                        Label("Models", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("models.back")
                    Text(page.wrappedValue.title).font(.headline)
                }
                Spacer(minLength: 12)
                Button("Check Setup…") { sheet = .checks }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("models.testAll")
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
                            ModelStackOverviewView(app: app, present: { sheet = $0 }, connections: showConnections,
                                                   choosePreset: { selectedPreset = $0; sheet = .presets },
                                                   manageDownloads: { page.wrappedValue = .downloaded })
                        case .downloaded:
                            ModelDownloadsView(app: app)
                        case .connections:
                            ModelConnectionsView(app: app)
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
                    guard app.focusedSettingID == "settings.generationBudgetPreset" else { return }
                    DispatchQueue.main.async { proxy.scrollTo("settings.generationBudgetPreset", anchor: .center) }
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
        case "settings.cotypingBuiltInModelID": sheet = .autocomplete
        case "settings.dictationCompositionBuiltInModelID": sheet = .dictation
        case "settings.openAIBaseURL", "settings.openAIModel", "settings.ollamaBaseURL", "settings.openAIAPIKey":
            page.wrappedValue = .connections
        case "settings.generationBudgetPreset":
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
                    Text("Preparing \(pending.title)…").font(.body.weight(.medium))
                    Text("Your current models stay active until preparation finishes.")
                        .font(.callout).settingsSecondary()
                }
                Spacer()
                Button("Cancel Switch") { controller.cancelSwitch() }
                    .help("Keep the current selection. Shared downloads continue in Downloaded.")
            }
            .padding(.vertical, 14)
        } else if let failure = controller.failure {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(failure).font(.body).textSelection(.enabled)
                Spacer()
                Button("Retry") { controller.retry() }
                Button("Dismiss") { controller.dismissFeedback() }
            }
            .padding(.vertical, 14)
        } else if let completed = controller.completed {
            HStack {
                Label("Using \(completed.title)", systemImage: "checkmark.circle")
                    .font(.body)
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

struct ModelStorageSection: View {
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Model Storage").font(.headline)
            HStack(spacing: 12) {
                Image(systemName: "internaldrive").font(.system(size: 20)).settingsSecondary()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Text models: \(roles.snapshot.storageSummary)").font(.body)
                    Text(memorySummary).font(.callout).settingsSecondary()
                }
                Spacer(minLength: 8)
                Button("Show in Finder") {
                    let directory = app.storage.rootURL.appendingPathComponent("models", isDirectory: true)
                    NSWorkspace.shared.selectFile(directory.path, inFileViewerRootedAtPath: app.storage.rootURL.path)
                }
                .buttonStyle(.bordered)
                Button(activeDownloads > 0
                       ? "Downloads (\(activeDownloads))" : "Manage Downloads", action: manage)
                    .buttonStyle(.workspaceLink)
                    .accessibilityIdentifier("models.manageDownloads")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.storage")
        .padding(16)
        .settingsPanel()
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
