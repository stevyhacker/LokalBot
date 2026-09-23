import SwiftUI

struct ModelConnectionsView: View {
    @ObservedObject var app: AppState
    @State private var draft: AppSettings
    @State private var connection: AppSettings.SummarizerBackend
    @State private var openAIAPIKeyDraft = ""
    @State private var openAIAPIKeySavedValue = ""
    @State private var openAIAPIKeySaved = false
    @State private var editingOpenAIAPIKey = false
    @State private var apiKeySaveError: String?
    @State private var confirmingOpenRouterAccountPolicy = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailure: GenerationTestFailurePresentation?
    @State private var showingTestFailure = false
    @State private var ollamaModels: [String] = []
    @State private var listingModels = false
    @State private var listError: String?
    @State private var savedMessage: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var listTask: Task<Void, Never>?

    init(app: AppState) {
        self.app = app
        _draft = State(initialValue: app.settings)
        let focusedOllama = app.focusedSettingID == "settings.ollamaBaseURL"
        _connection = State(initialValue: focusedOllama || app.settings.summarizerBackend == .ollama ? .ollama : .openAICompatible)
    }

    private var hasChanges: Bool {
        if connection == .ollama {
            return draft.ollamaBaseURL != app.settings.ollamaBaseURL || draft.ollamaModel != app.settings.ollamaModel
        }
        return draft.openAIBaseURL != app.settings.openAIBaseURL || draft.openAIModel != app.settings.openAIModel
            || draft.openRouterDataPolicy != app.settings.openRouterDataPolicy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Model connections").font(.system(size: 16, weight: .semibold))
                Text("Manage servers and credentials. Choose which provider to use from Active models.")
                    .font(.system(size: 13)).settingsSecondary()
            }
            Picker("Connection", selection: $connection) {
                Text("OpenAI-compatible").tag(AppSettings.SummarizerBackend.openAICompatible)
                Text("Ollama").tag(AppSettings.SummarizerBackend.ollama)
            }
            .pickerStyle(.segmented).frame(maxWidth: 380)
            .accessibilityIdentifier("models.connections.provider")
            Label(connection == app.settings.summarizerBackend ? "Used by Think" : "Available for Think",
                  systemImage: connection == app.settings.summarizerBackend ? "checkmark.circle" : "network")
                .font(.system(size: 13)).settingsSecondary()
            if connection == .openAICompatible {
                modelField("Server URL") {
                    TextField("https://example.com/v1", text: $draft.openAIBaseURL)
                        .accessibilityIdentifier("models.serverURL")
                        .settingTarget("settings.openAIBaseURL", selected: app.focusedSettingID)
                }
                modelField("Model ID") {
                    TextField("Provider model identifier", text: $draft.openAIModel)
                        .accessibilityIdentifier("models.modelID")
                        .settingTarget("settings.openAIModel", selected: app.focusedSettingID)
                }
                apiKeyControl
                remoteEndpointDisclosure(rawURL: draft.openAIBaseURL)
            } else {
                modelField("Server URL") {
                    TextField("http://localhost:11434", text: $draft.ollamaBaseURL)
                        .accessibilityIdentifier("models.ollama.serverURL")
                        .settingTarget("settings.ollamaBaseURL", selected: app.focusedSettingID)
                }
                modelField("Model ID") {
                    TextField("Ollama model name", text: $draft.ollamaModel)
                        .accessibilityIdentifier("models.ollama.modelID")
                }
                remoteEndpointDisclosure(rawURL: draft.ollamaBaseURL)
                HStack {
                    Button(listingModels ? "Loading…" : "List server models") {
                        listTask = Task { await refreshOllama() }
                    }
                        .disabled(listingModels || hasChanges)
                    if !ollamaModels.isEmpty {
                        Picker("Available models", selection: $draft.ollamaModel) {
                            Text("Choose a model").tag("")
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                if let listError { Text(listError).font(.system(size: 12)).foregroundStyle(.orange) }
            }
            HStack(spacing: 12) {
                Button("Save connection") { saveConnection() }
                    .primaryActionButton()
                    .disabled(!hasChanges || testing)
                    .accessibilityIdentifier("models.connection.save")
                Button(testing ? "Checking…" : "Check connection") {
                    checkTask = Task { await testGeneration() }
                }
                    .disabled(testing || hasChanges)
                    .accessibilityIdentifier("models.generationTest")
                    .popover(isPresented: $showingTestFailure) {
                        if let testFailure { GenerationTestFailurePopover(failure: testFailure) }
                    }
                if let savedMessage {
                    Text(savedMessage).font(.system(size: 12)).settingsSecondary()
                }
            }
            Text(hasChanges ? "Save changes before checking this connection."
                 : "Connection checks send a short sample prompt to this server. No meeting or screen content is used.")
                .font(.system(size: 12)).settingsSecondary()
            if let testResult { Text(testResult).font(.system(size: 13)).settingsSecondary().textSelection(.enabled) }
            if let testFailure {
                Button {
                    showingTestFailure = true
                } label: {
                    Label(testFailure.inlineTitle, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
                .accessibilityIdentifier("models.generationTest.issue")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .settingsPanel()
        .onAppear {
            openAIAPIKeySavedValue = app.settings.openAIAPIKey
            openAIAPIKeyDraft = openAIAPIKeySavedValue
        }
        .onChange(of: draft) { clearCheck() }
        .onChange(of: connection) { clearCheck() }
        .onDisappear {
            checkTask?.cancel()
            listTask?.cancel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.connections")
    }

    private func saveConnection() {
        var next = app.settings
        if connection == .ollama {
            next.ollamaBaseURL = draft.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            next.ollamaModel = draft.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            next.openAIBaseURL = draft.openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            next.openAIModel = draft.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            next.openRouterDataPolicy = draft.openRouterDataPolicy
        }
        app.settings = next
        draft = next
        savedMessage = "Saved"
        app.modelChecks.invalidate(for: next)
    }

    private func clearCheck() {
        testResult = nil
        testFailure = nil
        showingTestFailure = false
        savedMessage = nil
    }

    private func refreshOllama() async {
        guard let url = URL(string: app.settings.ollamaBaseURL) else { return }
        do {
            try InferenceEndpointPolicy.validate(url, approvedOrigins: app.settings.approvedRemoteInferenceOrigins)
        } catch {
            listError = error.localizedDescription
            return
        }
        listingModels = true
        listError = nil
        defer { listingModels = false }
        let modelNames = await OllamaEngine.listModels(baseURL: url)
        guard !Task.isCancelled, url.absoluteString == app.settings.ollamaBaseURL else { return }
        ollamaModels = modelNames
        if modelNames.isEmpty { listError = "No models returned. Check that the Ollama server is running and has a model installed." }
    }

    private func testGeneration() async {
        var config = app.settings
        config.summarizerBackend = connection
        let connectionAtStart = connection
        let key = config.openAIAPIKey
        let identity = ModelCheckIdentity(role: .think, settings: config, apiKey: key)
        testing = true
        clearCheck()
        defer { testing = false }
        do {
            let engine = try await app.thinkExecution.makeTextEngine(config, priority: .interactive, purpose: "connection check")
            try Task.checkCancellation()
            let reply = try await engine.generate(system: PromptTemplates.connectivityTestSystem,
                                                   prompt: PromptTemplates.connectivityTestPrompt, context: [])
            var current = app.settings
            current.summarizerBackend = connectionAtStart
            guard !Task.isCancelled, connection == connectionAtStart, !hasChanges,
                  identity == ModelCheckIdentity(role: .think, settings: current, apiKey: current.openAIAPIKey) else { return }
            guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelDownloadManager.PreparationError.failed("The server returned an empty response.")
            }
            testResult = "Connection check passed · " + String(reply.prefix(120))
        } catch {
            var current = app.settings
            current.summarizerBackend = connectionAtStart
            guard !Task.isCancelled, connection == connectionAtStart, !hasChanges,
                  identity == ModelCheckIdentity(role: .think, settings: current, apiKey: current.openAIAPIKey) else { return }
            testFailure = GenerationTestFailurePresentation(
                error: error,
                baseURL: connection == .openAICompatible ? config.openAIBaseURL : nil,
                model: connection == .openAICompatible ? config.openAIModel : nil,
                openRouterDataPolicy: config.openRouterDataPolicy)
            showingTestFailure = true
        }
    }

    private func modelField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(WorkspaceTypography.control)
            content().textFieldStyle(.roundedBorder)
        }
    }

    private var apiKeyControl: some View {
        modelField("API key") {
            if !openAIAPIKeySavedValue.isEmpty && !editingOpenAIAPIKey {
                HStack {
                    Label("Saved in Keychain", systemImage: "key")
                        .settingsSecondary()
                    Spacer()
                    Button("Replace…") {
                        openAIAPIKeyDraft = ""
                        apiKeySaveError = nil
                        editingOpenAIAPIKey = true
                    }
                    .accessibilityIdentifier("models.apiKey.replace")
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("API key (optional)", text: $openAIAPIKeyDraft)
                        .accessibilityIdentifier("models.apiKey")
                        .onChange(of: openAIAPIKeyDraft) { openAIAPIKeySaved = false }
                    Button("Save key") {
                        app.settings.openAIAPIKey = openAIAPIKeyDraft
                        // Only acknowledge persistence after reading back from Keychain.
                        openAIAPIKeySavedValue = app.settings.openAIAPIKey
                        openAIAPIKeySaved = openAIAPIKeySavedValue == openAIAPIKeyDraft
                        if openAIAPIKeySaved { editingOpenAIAPIKey = false }
                        apiKeySaveError = openAIAPIKeySaved ? nil : "Couldn’t save the key to Keychain. Try again."
                        app.modelChecks.invalidate(for: app.settings)
                        testResult = nil
                        testFailure = nil
                    }
                    .disabled(openAIAPIKeyDraft == openAIAPIKeySavedValue)
                    .accessibilityIdentifier("models.apiKey.save")
                    if editingOpenAIAPIKey {
                        Button("Cancel") {
                            openAIAPIKeyDraft = openAIAPIKeySavedValue
                            editingOpenAIAPIKey = false
                            apiKeySaveError = nil
                        }
                    }
                }
                Text("Stored in Keychain only when you choose Save key. Leave empty for a server that needs no key.")
                    .workspaceTextRole(.supporting)
            }
            if let apiKeySaveError {
                Text(apiKeySaveError).workspaceTextRole(.warning)
            }
        }
    }

    @ViewBuilder
    private func remoteEndpointDisclosure(rawURL: String) -> some View {
        if let url = URL(string: rawURL), InferenceEndpointPolicy.requiresApproval(url),
           let origin = InferenceEndpointPolicy.origin(for: url) {
            if url.scheme?.lowercased() != "https" {
                Label("Blocked: remote inference must use HTTPS so transcripts and screen text are encrypted in transit.",
                      systemImage: "lock.slash.fill")
                    .workspaceTextRole(.warning)
                    .padding(14)
                    .background(.red.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: Brand.Radius.row))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Remote processing · \(url.host ?? origin)", systemImage: "network")
                        .font(WorkspaceTypography.rowTitle)
                    Text("Think may send meeting transcripts, screen text, Agent context, and inherited dictation requests to this server when you use those features.")
                        .workspaceTextRole(.trust)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Allow sending context to \(origin)",
                           isOn: remoteApprovalBinding(rawURL: rawURL))
                        .font(WorkspaceTypography.editorialBody)
                        .accessibilityIdentifier("models.remoteConsent")
                    if connection == .openAICompatible && isOpenRouterEndpoint {
                        Divider()
                        openRouterDataPolicyControl
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.row))
            }
        } else if let url = URL(string: rawURL), InferenceEndpointPolicy.isLoopback(url) {
            Label("Loopback server: inference context stays on this Mac.",
                  systemImage: "checkmark.shield.fill")
                .font(WorkspaceTypography.editorialBody)
                .settingsSecondary()
        }
    }

    private func remoteApprovalBinding(rawURL: String) -> Binding<Bool> {
        Binding {
            guard let url = URL(string: rawURL),
                  let origin = InferenceEndpointPolicy.origin(for: url) else { return false }
            return app.settings.approvedRemoteInferenceOrigins.contains(origin)
        } set: { approved in
            guard let url = URL(string: rawURL),
                  let origin = InferenceEndpointPolicy.origin(for: url) else { return }
            app.settings.approvedRemoteInferenceOrigins.removeAll { $0 == origin }
            if approved {
                app.settings.approvedRemoteInferenceOrigins.append(origin)
            }
        }
    }

    private var isOpenRouterEndpoint: Bool {
        guard let url = URL(string: draft.openAIBaseURL) else { return false }
        return ChatCompletionDialect.inferred(from: url) == .openRouter
    }

    private var openRouterDataPolicyControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provider data use")
                .font(WorkspaceTypography.control)
            Picker("Provider data use", selection: openRouterDataPolicyBinding) {
                Text("Private endpoints only (Recommended)")
                    .tag(OpenRouterDataPolicy.privateOnly)
                Text("Follow my OpenRouter privacy settings")
                    .tag(OpenRouterDataPolicy.accountPolicy)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("models.openRouterDataPolicy")

            Text(openRouterDataPolicyDetail)
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert(
            "Follow your OpenRouter privacy policy?",
            isPresented: $confirmingOpenRouterAccountPolicy
        ) {
            Button("Follow OpenRouter Policy") {
                draft.openRouterDataPolicy = .accountPolicy
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Approved meeting transcripts, screen text, and Agent context may be sent "
                + "to providers that retain requests or use them for training. LokalBot "
                + "cannot verify the OpenRouter policy attached to this account, API key, "
                + "workspace, or guardrail.")
        }
    }

    private var openRouterDataPolicyBinding: Binding<OpenRouterDataPolicy> {
        Binding {
            draft.openRouterDataPolicy
        } set: { policy in
            if policy == .accountPolicy,
               draft.openRouterDataPolicy != .accountPolicy {
                confirmingOpenRouterAccountPolicy = true
            } else {
                draft.openRouterDataPolicy = policy
            }
        }
    }

    private var openRouterDataPolicyDetail: String {
        switch draft.openRouterDataPolicy {
        case .privateOnly:
            "Every request is restricted to providers that do not collect inference data."
        case .accountPolicy:
            "Provider eligibility follows your OpenRouter account, API-key, workspace, "
                + "and guardrail settings."
        }
    }

}
