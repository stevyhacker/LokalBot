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
    /// Previews and screenshots pass a signed-in sample account.
    let chatGPTAccount: ChatGPTPlanAccount

    @State private var selectedID: String
    @State private var backend: AppSettings.SummarizerBackend
    @State private var remoteModel: String
    @State private var ollamaModel: String
    @State private var chatGPTPlanModel: String
    @State private var claudePlanModel: String
    /// Plan approvals apply with Use model, so Cancel changes nothing.
    @State private var chatGPTConsent: Bool
    @State private var claudeConsent: Bool
    @State private var chatGPTReady = false
    @State private var claudeReady = false
    @State private var funASRNanoDirectory: String
    @State private var folderError: String?
    @State private var granite: GraniteSpeechModelConfiguration
    @State private var query = ""
    @State private var installedOnly = false
    @State private var showingAdvanced = false
    @State private var showingImport = false
    @State private var showingGranite = false
    @State private var showingTranscriptionOptions = false

    init(app: AppState, role: ModelPickerRole, openConnections: @escaping () -> Void,
         chatGPTAccount: ChatGPTPlanAccount = .shared) {
        self.chatGPTAccount = chatGPTAccount
        self.app = app
        self.role = role
        self.openConnections = openConnections
        roles = app.modelRoles
        setup = app.modelSetup
        let settings = app.settings
        _selectedID = State(initialValue: Self.assignedID(for: role, in: settings))
        _backend = State(initialValue: settings.summarizerBackend)
        _remoteModel = State(initialValue: settings.openAIModel)
        _ollamaModel = State(initialValue: settings.ollamaModel)
        _chatGPTPlanModel = State(initialValue: settings.chatGPTPlanModel)
        _claudePlanModel = State(initialValue: settings.claudePlanModel)
        _chatGPTConsent = State(initialValue: SubscriptionPlan.chatGPT.isApproved(in: settings))
        _claudeConsent = State(initialValue: SubscriptionPlan.claude.isApproved(in: settings))
        _funASRNanoDirectory = State(initialValue: settings.funASRNanoModelDirectory)
        _granite = State(initialValue: settings.graniteSpeechModel)
    }

    private static func assignedID(for role: ModelPickerRole, in settings: AppSettings) -> String {
        switch role {
        case .transcription: settings.transcriptionModel.id
        case .assistant: settings.builtInModelID
        case .autocomplete: settings.cotypingBuiltInModelID
        case .dictation: settings.dictationCompositionBuiltInModelID
        }
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

    private var clearsFunASRSelection: Bool {
        role == .transcription && transcription == .funASRNano
            && funASRNanoDirectory.isEmpty && !app.settings.funASRNanoModelDirectory.isEmpty
    }

    private var patch: ModelSelectionPatch {
        switch role {
        case .transcription:
            ModelSelectionPatch(
                transcription: clearsFunASRSelection ? nil : transcription,
                granite: transcription == .graniteSpeech ? granite : nil,
                funASRNanoDirectory: transcription == .funASRNano
                    || (funASRNanoDirectory.isEmpty && !app.settings.funASRNanoModelDirectory.isEmpty)
                    ? funASRNanoDirectory : nil,
                language: transcription == .graniteTurbo ? .en : nil)
        case .assistant:
            ModelSelectionPatch(
                backend: backend,
                assistantModelID: backend == .builtIn ? selectedID : nil,
                ollamaModel: backend == .ollama ? ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                remoteModel: backend == .openAICompatible ? remoteModel.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                chatGPTPlanModel: backend == .chatGPTPlan
                    ? chatGPTPlanModel.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                claudePlanModel: backend == .claudePlan
                    ? claudePlanModel.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        case .autocomplete: ModelSelectionPatch(autocompleteModelID: selectedID)
        case .dictation: ModelSelectionPatch(dictationModelID: selectedID)
        }
    }

    private var needsDownload: Bool {
        if role == .transcription {
            if transcription == .funASRNano { return false }
            return !TranscriptionModelStore.isDownloaded(transcription, graniteConfiguration: granite, funASRNanoDirectory: funASRNanoDirectory)
        }
        return patch.localModelIDs(in: app.settings).contains { id in
            guard let entry = ModelCatalog.entry(id: id, custom: app.settings.customBuiltInModels) else { return true }
            return ModelCatalog.localURL(for: entry, storage: app.storage) == nil
        }
    }

    private func isDownloaded(_ entry: ModelCatalog.Entry) -> Bool {
        ModelCatalog.localURL(for: entry, storage: app.storage) != nil
    }

    private func downloadBlocker(_ entry: ModelCatalog.Entry) -> String? {
        ModelSettingsPresentation.downloadBlocker(for: entry, downloaded: isDownloaded(entry))
    }

    private var selectedBlocker: String? {
        if clearsFunASRSelection { return nil }
        if role == .transcription, transcription == .funASRNano {
            do { _ = try FunASRNanoModel.load(directory: funASRNanoDirectory) } catch { return error.localizedDescription }
            return nil
        }
        guard role != .transcription, let selectedEntry else { return nil }
        return downloadBlocker(selectedEntry)
    }

    private var canApply: Bool {
        guard setup.pending == nil, selectedBlocker == nil else { return false }
        if role == .assistant, let plan = SubscriptionPlan(backend: backend) {
            guard consent(for: plan).wrappedValue else { return false }
            switch plan {
            case .chatGPT:
                return chatGPTReady && !chatGPTPlanModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // An empty model uses Claude Code's own default.
            case .claude: return claudeReady
            }
        }
        if role == .assistant, backend != .builtIn {
            let target = patch.applying(to: app.settings)
            if InferencePresentation(settings: target).isBlocked { return false }
            switch backend {
            case .openAICompatible: return !remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .ollama: return !ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .appleIntelligence: return FoundationModelAvailability.current().isAvailable
            case .builtIn, .chatGPTPlan, .claudePlan: return false
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
            if role == .autocomplete, app.settings.cotypingBackend != .onDevice {
                Label("Autocomplete runs on a server you chose under Settings → Writing. This model is used when it runs on this Mac again.",
                      systemImage: "network")
                    .font(.scaled(.callout)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.bottom, 12)
            }
            if role == .assistant {
                // Where Think runs, then that choice's own setup: one place
                // to choose and configure, with no nested or segmented picks.
                HStack(alignment: .top, spacing: 0) {
                    providerList.frame(width: 228)
                    Divider()
                    VStack(alignment: .leading, spacing: 0) {
                        if showsCatalog {
                            catalog
                            selectionDetails
                        } else {
                            ScrollView {
                                providerSelection
                                    .padding(.horizontal, 24).padding(.bottom, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else if showsCatalog {
                catalog
                selectionDetails
            }
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(clearsFunASRSelection
                         ? "Only the saved folder selection is removed. Your model files stay on disk."
                         : needsDownload ? "Your current model stays active while this downloads." : "The change takes effect when you choose Use model.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                    if role == .assistant, app.settings.dictationCompositionBuiltInModelID.isEmpty {
                        Text("Dictation composition will also use this model.")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("models.picker.cancel")
                Button(clearsFunASRSelection ? "Clear selection" : needsDownload ? "Download and use" : "Use model") {
                    approveSelectedPlan()
                    setup.apply(patch, title: selectedName)
                    dismiss()
                }
                .primaryActionButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply || (patch.matches(app.settings) && !needsDownload && !approvesSelectedPlan))
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
                    .font(.scaled(.callout))
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
                            available: TranscriptionModelStore.isDownloaded(choice, graniteConfiguration: granite, funASRNanoDirectory: funASRNanoDirectory),
                            progress: status.progress)
                        .tag(choice.id)
                    }
                } else {
                    ForEach(entries) { entry in
                        ModelChoiceRow(
                            title: entry.displayName,
                            detail: ModelSettingsPresentation.sizeLabel(entry) + " on disk",
                            inUse: ModelSettingsPresentation.uses(of: entry.id, in: app.settings).contains(role.title),
                            available: isDownloaded(entry),
                            progress: downloads.progress[entry.id],
                            blocked: downloadBlocker(entry) != nil)
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
            : ModelCatalog.mainLLMEntries(custom: app.settings.customBuiltInModels)
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
            let downloaded = TranscriptionModelStore.isDownloaded(choice, graniteConfiguration: granite, funASRNanoDirectory: funASRNanoDirectory)
            return (!choice.isLegacy || downloaded || choice == app.settings.transcriptionModel)
                && (!installedOnly || downloaded)
                && (query.isEmpty || "\(choice.displayName) \(choice.blurb)".localizedCaseInsensitiveContains(query))
        }
    }

    private func transcriptionSize(_ choice: TranscriptionModelChoice) -> String {
        if choice == .funASRNano { return app.settings.appLanguage.localized("Local model folder") }
        guard let bytes = ModelSettingsPresentation.estimatedTranscriptionBytes(choice, granite: granite) else {
            return "Download size varies"
        }
        return "About " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " download"
    }

    private var selectionDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(role == .transcription ? app.settings.appLanguage.localized(transcription.blurb)
                 : selectedEntry?.blurb ?? "Uses the same model and processing destination as Think.")
                .font(.scaled(.body)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if role == .transcription, transcription == .funASRNano { funASRFolderPicker }
            if let entry = selectedEntry, role != .transcription {
                let fit = ModelFit.evaluate(modelSizeGB: entry.sizeGB, capability: HardwareCapabilityProbe.current())
                if let advisory = fit.advisory {
                    Label(advisory, systemImage: "memorychip").font(.scaled(.callout)).foregroundStyle(.orange)
                }
                if let blocker = selectedBlocker {
                    // Autocomplete's picker has no Browse button; say where it is.
                    Label(role == .autocomplete
                          ? blocker + " Browse Hugging Face is under Advanced in the Think model picker."
                          : blocker,
                          systemImage: "exclamationmark.triangle")
                        .font(.scaled(.callout)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let removal = ModelSettingsPresentation.customModelRemoval(
                    entry, in: app.settings, downloaded: isDownloaded(entry)) {
                    HStack(spacing: 10) {
                        Button("Remove from List") { removeCustomModel(entry) }
                            .disabled(removal != .allowed || setup.pending != nil
                                      || downloads.progress[entry.id] != nil)
                            .accessibilityIdentifier("models.picker.removeCustom")
                        if let reason = removal.reason {
                            Text(reason).font(.scaled(.callout)).foregroundStyle(.secondary)
                        }
                    }
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
            .font(.scaled(.callout))
            .accessibilityLabel("Advanced")
            .accessibilityValue(showingAdvanced ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("models.picker.advanced")
            if showingAdvanced { advancedOptions }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var funASRFolderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Choose model folder…") { chooseFunASRFolder() }
                    .accessibilityIdentifier("models.funasr.chooseFolder")
                if !funASRNanoDirectory.isEmpty {
                    Button("Clear selection") { funASRNanoDirectory = ""; folderError = nil }
                        .accessibilityIdentifier("models.funasr.clearFolder")
                }
                Link("Model format & downloads", destination: URL(string: "https://k2-fsa.github.io/sherpa/onnx/funasr-nano/pretrained.html")!)
            }
            if !funASRNanoDirectory.isEmpty {
                Text(verbatim: funASRNanoDirectory).textSelection(.enabled).lineLimit(2)
                    .accessibilityIdentifier("models.funasr.folder")
            }
            Text("Select the extracted sherpa-onnx model folder (int8, fp16, or fp32). The selected model stays in this folder and is never downloaded automatically.")
                .fixedSize(horizontal: false, vertical: true)
            if let error = folderError ?? selectedBlocker {
                Text(verbatim: error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.scaled(.callout))
    }

    private func chooseFunASRFolder() {
        let panel = NSOpenPanel()
        panel.title = app.settings.appLanguage.localized("Choose Fun-ASR-Nano model folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let model = try FunASRNanoModel.load(directory: directory.path)
            funASRNanoDirectory = model.directory.path
            folderError = nil
        } catch {
            folderError = error.localizedDescription
        }
    }

    /// Only the list entry goes: the role assignments and downloaded file
    /// checks in `customModelRemoval` keep this from orphaning anything.
    private func removeCustomModel(_ entry: ModelCatalog.Entry) {
        app.settings.customBuiltInModels.removeAll { $0.id == entry.id }
        selectedID = Self.assignedID(for: role, in: app.settings)
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
        .font(.scaled(.callout)).foregroundStyle(.secondary).padding(.top, 8)
    }

    /// Where Think runs. Each choice is one backend; its setup appears beside
    /// the list.
    private enum ThinkProvider: String, CaseIterable, Identifiable {
        case onDevice, appleIntelligence, chatGPTPlan, claudePlan, ollama, server

        var id: String { rawValue }

        init(_ backend: AppSettings.SummarizerBackend) {
            switch backend {
            case .builtIn: self = .onDevice
            case .appleIntelligence: self = .appleIntelligence
            case .chatGPTPlan: self = .chatGPTPlan
            case .claudePlan: self = .claudePlan
            case .ollama: self = .ollama
            case .openAICompatible: self = .server
            }
        }

        var backend: AppSettings.SummarizerBackend {
            switch self {
            case .onDevice: .builtIn
            case .appleIntelligence: .appleIntelligence
            case .chatGPTPlan: .chatGPTPlan
            case .claudePlan: .claudePlan
            case .ollama: .ollama
            case .server: .openAICompatible
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .onDevice: "On this Mac"
            case .appleIntelligence: "Apple Intelligence"
            case .chatGPTPlan: "ChatGPT plan"
            case .claudePlan: "Claude plan"
            case .ollama: "Ollama"
            case .server: "OpenAI-compatible"
            }
        }

        var icon: String {
            switch self {
            case .onDevice: "desktopcomputer"
            case .appleIntelligence: "apple.intelligence"
            case .chatGPTPlan: "bubble.left.and.bubble.right"
            case .claudePlan: "terminal"
            case .ollama: "server.rack"
            case .server: "network"
            }
        }

        static let groups: [(title: LocalizedStringKey, providers: [ThinkProvider])] = [
            ("Local", [.onDevice, .appleIntelligence]),
            ("Your subscription", [.chatGPTPlan, .claudePlan]),
            ("Server", [.ollama, .server]),
        ]
    }

    /// Plain rows with an explicit highlight: the selection reads the same in
    /// a sheet whether or not its window is key.
    private var providerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ThinkProvider.groups, id: \.providers) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.scaled(.caption).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.bottom, 2)
                        ForEach(group.providers) { provider in
                            providerRow(provider)
                        }
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
        }
        .accessibilityIdentifier("models.picker.provider")
    }

    private func providerRow(_ provider: ThinkProvider) -> some View {
        let selected = ThinkProvider(backend) == provider
        return Button {
            backend = provider.backend
        } label: {
            HStack(spacing: 8) {
                Image(systemName: provider.icon)
                    .frame(width: 20)
                    .foregroundStyle(selected ? AnyShapeStyle(Brand.teal) : AnyShapeStyle(.secondary))
                Text(provider.title)
                    .font(.scaled(.body).weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if provider.backend == app.settings.summarizerBackend {
                    Image(systemName: "checkmark")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("In use")
                        .help("In use")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Brand.tealFill.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("models.picker.provider.\(provider.rawValue)")
    }

    private func consent(for plan: SubscriptionPlan) -> Binding<Bool> {
        plan == .chatGPT ? $chatGPTConsent : $claudeConsent
    }

    /// The selected plan is approved in the sheet but not yet in settings.
    private var approvesSelectedPlan: Bool {
        guard role == .assistant, let plan = SubscriptionPlan(backend: backend) else { return false }
        return consent(for: plan).wrappedValue && !plan.isApproved(in: app.settings)
    }

    private func approveSelectedPlan() {
        guard approvesSelectedPlan, let plan = SubscriptionPlan(backend: backend) else { return }
        app.settings.approvedRemoteInferenceOrigins.append(plan.consentKey)
    }

    private var planSelection: some View {
        let plan = SubscriptionPlan(backend: backend) ?? .chatGPT
        return VStack(alignment: .leading, spacing: 16) {
            SubscriptionPlanSetupView(
                app: app, plan: plan,
                model: plan == .chatGPT ? $chatGPTPlanModel : $claudePlanModel,
                consent: consent(for: plan),
                ready: plan == .chatGPT ? $chatGPTReady : $claudeReady,
                chatGPTAccount: chatGPTAccount)
                .id(plan)
            Text("Requests count toward your \(plan.title)'s usage. Agent Mode can't use a plan yet.")
                .font(.scaled(.callout)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var providerSelection: some View {
        if SubscriptionPlan(backend: backend) != nil {
            planSelection
        } else {
            serverSelection
        }
    }

    private var serverSelection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if backend == .appleIntelligence {
                let availability = FoundationModelAvailability.current()
                Label("Apple Intelligence", systemImage: "apple.intelligence").font(.scaled(.headline))
                Text(availability.isAvailable ? "Available on this Mac. No model download is needed."
                     : availability.reason ?? "Apple Intelligence is unavailable.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                let target = patch.applying(to: app.settings)
                Label(ModelSettingsPresentation.destination(target), systemImage: InferencePresentation(settings: target).icon)
                    .font(.scaled(.body).weight(.semibold))
                    .settingsModelLocation(InferencePresentation(settings: target))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model ID").font(.scaled(.body).weight(.medium))
                    TextField("Provider model identifier", text: backend == .ollama ? $ollamaModel : $remoteModel)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("models.picker.modelID")
                }
                Text(backend == .ollama ? app.settings.ollamaBaseURL : app.settings.openAIBaseURL)
                    .font(.scaled(.callout)).foregroundStyle(.secondary).textSelection(.enabled)
                if case .blocked(let reason) = InferencePresentation(settings: target) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.scaled(.body)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(InferencePresentation(settings: target).detail(
                        local: "This provider runs on this Mac.",
                        remote: "Summaries, Ask, Agent, and inherited dictation composition can send approved context to this provider."))
                        .font(.scaled(.body)).foregroundStyle(.secondary)
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
    var blocked = false

    private var status: String {
        if inUse { return "In use" }
        if available { return "Downloaded" }
        return blocked ? "Needs re-adding" : "Available"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.scaled(.body).weight(.medium))
                Text(detail).font(.scaled(.callout)).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress { ProgressView(value: progress).frame(width: 70) }
            Text(status)
                .font(.scaled(.callout))
                .foregroundStyle(blocked && !inUse ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
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
            Text(title).font(.scaled(.largeTitle).bold())
            Text(subtitle).font(.scaled(.body)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }
}
