import SwiftUI
import AppKit

struct ModelPickerSheet: View {
    @ObservedObject var app: AppState
    @ObservedObject private var roles: ModelRoles
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @ObservedObject private var setup: ModelSetupController
    @Environment(\.dismiss) private var dismiss
    let role: ModelPickerRole
    let openConnections: () -> Void

    @State private var selectedID: String
    @State private var backend: AppSettings.SummarizerBackend
    @State private var remoteModel: String
    @State private var ollamaModel: String
    @State private var granite: GraniteSpeechModelConfiguration
    @State private var query = ""
    @State private var installedOnly = false
    @State private var showingAdvanced = false
    @State private var showingImport = false
    @State private var showingGranite = false
    @State private var showingTranscriptionOptions = false

    init(app: AppState, role: ModelPickerRole, openConnections: @escaping () -> Void) {
        self.app = app
        self.role = role
        self.openConnections = openConnections
        roles = app.modelRoles
        setup = app.modelSetup
        let settings = app.settings
        let id: String
        switch role {
        case .transcription: id = settings.transcriptionModel.id
        case .assistant: id = settings.builtInModelID
        case .autocomplete: id = settings.cotypingBuiltInModelID
        case .dictation: id = settings.dictationCompositionBuiltInModelID
        }
        _selectedID = State(initialValue: id)
        _backend = State(initialValue: settings.summarizerBackend)
        _remoteModel = State(initialValue: settings.openAIModel)
        _ollamaModel = State(initialValue: settings.ollamaModel)
        _granite = State(initialValue: settings.graniteSpeechModel)
    }

    private var selection: Binding<String?> {
        Binding(get: { selectedID }, set: { if let value = $0 { selectedID = value } })
    }
    private var transcription: TranscriptionModelChoice {
        TranscriptionModelChoice(rawValue: selectedID) ?? app.settings.transcriptionModel
    }
    private var showsCatalog: Bool { role != .assistant || backend == .builtIn }
    private var catalogIsEmpty: Bool { role == .transcription ? transcriptionChoices.isEmpty : entries.isEmpty }
    private var selectedEntry: ModelCatalog.Entry? {
        ModelCatalog.entry(id: selectedID, custom: app.settings.customBuiltInModels)
    }

    private var patch: ModelSelectionPatch {
        switch role {
        case .transcription:
            ModelSelectionPatch(
                transcription: transcription,
                granite: transcription == .graniteSpeech ? granite : nil,
                language: transcription == .graniteTurbo ? .en : nil)
        case .assistant:
            ModelSelectionPatch(
                backend: backend,
                assistantModelID: backend == .builtIn ? selectedID : nil,
                ollamaModel: backend == .ollama ? ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                remoteModel: backend == .openAICompatible ? remoteModel.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        case .autocomplete: ModelSelectionPatch(autocompleteModelID: selectedID)
        case .dictation: ModelSelectionPatch(dictationModelID: selectedID)
        }
    }

    private var needsDownload: Bool {
        if role == .transcription {
            return !TranscriptionModelStore.isDownloaded(transcription, graniteConfiguration: granite)
        }
        return patch.localModelIDs(in: app.settings).contains { id in
            guard let entry = ModelCatalog.entry(id: id, custom: app.settings.customBuiltInModels) else { return true }
            return ModelCatalog.localURL(for: entry, storage: app.storage) == nil
        }
    }

    private var canApply: Bool {
        guard setup.pending == nil else { return false }
        if role == .assistant, backend != .builtIn {
            let target = patch.applying(to: app.settings)
            if InferencePresentation(settings: target).isBlocked { return false }
            switch backend {
            case .openAICompatible: return !remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .ollama: return !ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .appleIntelligence: return FoundationModelAvailability.current().isAvailable
            case .builtIn: return false
            }
        }
        return role == .transcription || (role == .dictation && selectedID.isEmpty) || selectedEntry != nil
    }

    private var selectedName: String {
        switch role {
        case .transcription: transcription == .graniteSpeech ? granite.displayName : transcription.displayName
        case .assistant: ModelSettingsPresentation.assistantName(patch.applying(to: app.settings))
        case .autocomplete: selectedEntry?.displayName ?? selectedID
        case .dictation: selectedID.isEmpty ? "Think for dictation" : selectedEntry?.displayName ?? selectedID
        }
    }

    private var preferredHeight: CGFloat {
        let available = NSApp.keyWindow?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height ?? 750
        return min(650, max(420, available - 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelSheetHeading(title: "\(role.title) model", subtitle: role.detail)
            if role == .assistant {
                Picker("Run with", selection: $backend) {
                    Text("On this Mac").tag(AppSettings.SummarizerBackend.builtIn)
                    Text("Apple Intelligence").tag(AppSettings.SummarizerBackend.appleIntelligence)
                    Text("Ollama").tag(AppSettings.SummarizerBackend.ollama)
                    Text("Connected provider").tag(AppSettings.SummarizerBackend.openAICompatible)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24).padding(.bottom, 16)
                .accessibilityIdentifier("models.picker.provider")
            }
            if showsCatalog {
                catalog
                selectionDetails
            } else {
                providerSelection.padding(.horizontal, 24)
                Spacer(minLength: 16)
            }
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(needsDownload ? "Your current model stays active while this downloads." : "The change takes effect when you choose Use model.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if role == .assistant, app.settings.dictationCompositionBuiltInModelID.isEmpty {
                        Text("Dictation composition will also use this model.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("models.picker.cancel")
                Button(needsDownload ? "Download and use" : "Use model") {
                    setup.apply(patch, title: selectedName)
                    dismiss()
                }
                .primaryActionButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || (patch.matches(app.settings) && !needsDownload))
                .accessibilityIdentifier("models.picker.apply")
            }
            .padding(20)
        }
        .frame(width: 720, height: preferredHeight)
        .controlSize(.regular)
        .sheet(isPresented: $showingImport) {
            ModelImportSheet { entry in
                app.settings.customBuiltInModels.removeAll { $0.id == entry.id }
                app.settings.customBuiltInModels.append(entry)
                selectedID = entry.id
                query = ""
                installedOnly = false
            }
        }
        .sheet(isPresented: $showingGranite) {
            GraniteSpeechModelPicker(selection: Binding(get: { granite }, set: {
                granite = $0
                selectedID = TranscriptionModelChoice.graniteSpeech.id
            }))
        }
        .sheet(isPresented: $showingTranscriptionOptions) { ModelTranscriptionOptionsSheet(app: app) }
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search compatible models", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("models.picker.search")
                Toggle("Downloaded only", isOn: $installedOnly).toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
            List(selection: selection) {
                if role == .dictation, query.isEmpty {
                    ModelChoiceRow(title: "Use Think", detail: ModelSettingsPresentation.destination(app.settings),
                                   inUse: app.settings.dictationCompositionBuiltInModelID.isEmpty,
                                   available: true, progress: nil)
                        .tag("")
                }
                if role == .transcription {
                    ForEach(transcriptionChoices) { choice in
                        let status = roles.transcriptionStatus(for: choice)
                        ModelChoiceRow(
                            title: choice == .graniteSpeech ? granite.displayName : choice.displayName,
                            detail: transcriptionSize(choice),
                            inUse: choice == app.settings.transcriptionModel,
                            available: TranscriptionModelStore.isDownloaded(choice, graniteConfiguration: granite),
                            progress: status.progress)
                        .tag(choice.id)
                    }
                } else {
                    ForEach(entries) { entry in
                        ModelChoiceRow(
                            title: entry.displayName,
                            detail: ModelSettingsPresentation.sizeLabel(entry) + " on disk",
                            inUse: ModelSettingsPresentation.uses(of: entry.id, in: app.settings).contains(role.title),
                            available: ModelCatalog.localURL(for: entry, storage: app.storage) != nil,
                            progress: downloads.progress[entry.id])
                        .tag(entry.id)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if catalogIsEmpty,
                   !(role == .dictation && query.isEmpty) {
                    ContentUnavailableView.search(text: query)
                }
            }
            .accessibilityIdentifier("models.picker.catalog")
        }
    }

    private var entries: [ModelCatalog.Entry] {
        let all = role == .autocomplete
            ? ModelCatalog.keystrokeScaleEntries(custom: app.settings.customBuiltInModels,
                                                 keeping: app.settings.cotypingBuiltInModelID)
            : ModelCatalog.selectableEntries(custom: app.settings.customBuiltInModels)
        return all.filter { entry in
            (!installedOnly || ModelCatalog.localURL(for: entry, storage: app.storage) != nil)
                && (query.isEmpty || "\(entry.displayName) \(entry.id)".localizedCaseInsensitiveContains(query))
        }.sorted { first, second in
            let a = ModelCatalog.localURL(for: first, storage: app.storage) != nil
            let b = ModelCatalog.localURL(for: second, storage: app.storage) != nil
            return a != b ? a : first.displayName.localizedStandardCompare(second.displayName) == .orderedAscending
        }
    }

    private var transcriptionChoices: [TranscriptionModelChoice] {
        TranscriptionModelChoice.allCases.filter { choice in
            let downloaded = TranscriptionModelStore.isDownloaded(choice, graniteConfiguration: granite)
            return (!choice.isLegacy || downloaded || choice == app.settings.transcriptionModel)
                && (!installedOnly || downloaded)
                && (query.isEmpty || "\(choice.displayName) \(choice.blurb)".localizedCaseInsensitiveContains(query))
        }
    }

    private func transcriptionSize(_ choice: TranscriptionModelChoice) -> String {
        guard let bytes = ModelSettingsPresentation.estimatedTranscriptionBytes(choice, granite: granite) else {
            return "Download size varies"
        }
        return "About " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " download"
    }

    private var selectionDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(role == .transcription ? transcription.blurb
                 : selectedEntry?.blurb ?? "Uses the same model and processing destination as Think.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let entry = selectedEntry, role != .transcription {
                let fit = ModelFit.evaluate(modelSizeGB: entry.sizeGB, capability: HardwareCapabilityProbe.current())
                if let advisory = fit.advisory {
                    Label(advisory, systemImage: "memorychip").font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            Button { showingAdvanced.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: showingAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        .accessibilityHidden(true)
                    Text("Advanced")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .accessibilityLabel("Advanced")
            .accessibilityValue(showingAdvanced ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("models.picker.advanced")
            if showingAdvanced { advancedOptions }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if role == .transcription {
                HStack {
                    Button("Language & vocabulary…") { showingTranscriptionOptions = true }
                    Button("Custom Granite Speech…") { showingGranite = true }
                        .accessibilityIdentifier("models.granite.customize")
                }
            } else {
                if let entry = selectedEntry {
                    Text("Model ID: \(entry.id)").textSelection(.enabled)
                    Text(entry.fileName).textSelection(.enabled)
                    if entry.sizeGB.isFinite, entry.sizeGB > 0 {
                        Text(String(format: "Estimated memory: %.1f GB. Actual use varies with context and runtime.",
                                    entry.sizeGB * 1.3))
                    } else {
                        Text("Memory use varies with model size, context, and runtime.")
                    }
                }
                if role != .autocomplete {
                    Button("Browse Hugging Face…") { showingImport = true }
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
    }

    private var providerSelection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if backend == .appleIntelligence {
                let availability = FoundationModelAvailability.current()
                Label("Apple Intelligence", systemImage: "apple.intelligence").font(.headline)
                Text(availability.isAvailable ? "Available on this Mac. No model download is needed."
                     : availability.reason ?? "Apple Intelligence is unavailable.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                let target = patch.applying(to: app.settings)
                Label(ModelSettingsPresentation.destination(target), systemImage: InferencePresentation(settings: target).icon)
                    .font(.system(size: 14, weight: .semibold))
                    .settingsModelLocation(InferencePresentation(settings: target))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model ID").font(.system(size: 13, weight: .medium))
                    TextField("Provider model identifier", text: backend == .ollama ? $ollamaModel : $remoteModel)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("models.picker.modelID")
                }
                Text(backend == .ollama ? app.settings.ollamaBaseURL : app.settings.openAIBaseURL)
                    .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                if case .blocked(let reason) = InferencePresentation(settings: target) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                } else {
                    Text(InferencePresentation(settings: target).detail(
                        local: "This provider runs on this Mac.",
                        remote: "Summaries, Ask, Agent, and inherited dictation composition can send approved context to this provider."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Button("Manage connection…") { openConnections() }
                    .accessibilityIdentifier("models.picker.connections")
            }
        }
        .padding(.top, 12)
    }
}

private struct ModelChoiceRow: View {
    let title: String
    let detail: String
    let inUse: Bool
    let available: Bool
    let progress: Double?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress { ProgressView(value: progress).frame(width: 70) }
            Text(inUse ? "In use" : available ? "Downloaded" : "Available")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct ModelSheetHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 21, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }
}
