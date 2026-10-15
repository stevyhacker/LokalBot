import SwiftUI

/// Settings → Writing rows for an autocomplete server: Think's server with the
/// same or another model, or any OpenAI-compatible server, hosted or on the
/// user's own network. Typing goes to a server only after its origin is
/// approved for autocomplete; Think's approval does not cover it.
struct CotypingServerSettingsView: View {
    @ObservedObject var app: AppState
    @State private var apiKeyDraft = ""
    @State private var apiKeySavedValue = ""
    @State private var editingAPIKey = false
    @State private var apiKeyError: String?

    init(app: AppState) {
        self.app = app
    }

    var body: some View {
        Group {
            if app.settings.cotypingBackend == .thinkServer {
                thinkServerRows
            } else {
                serverRows
            }
            Picker(selection: $app.settings.cotypingServerRequestStyle) {
                ForEach(CotypingServerRequestStyle.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            } label: {
                SettingsLabel("Request type",
                              help: "Automatic uses text completion on servers you run yourself and chat on hosted chat APIs, and switches to chat when a server has no text completion.")
            }
            .settingTarget("settings.cotypingServerRequestStyle", selected: app.focusedSettingID)
            disclosure
            status
        }
    }

    // MARK: Think's server

    @ViewBuilder private var thinkServerRows: some View {
        LabeledContent("Server") {
            Text(thinkServerDescription)
                .settingsSecondary()
                .textSelection(.enabled)
        }
        LabeledContent {
            TextField("Model", text: $app.settings.cotypingThinkServerModel,
                      prompt: thinkModel.isEmpty ? Text("Model ID") : Text("Same as Think (\(thinkModel))"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("settings.cotypingThinkServerModel")
        } label: {
            SettingsLabel("Model",
                          help: "Leave empty to use Think's model, or name a smaller one on the same server for faster suggestions.")
        }
        .settingTarget("settings.cotypingThinkServerModel", selected: app.focusedSettingID)
    }

    private var thinkModel: String {
        switch app.settings.summarizerBackend {
        case .ollama: app.settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openAICompatible: app.settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .builtIn, .appleIntelligence, .chatGPTPlan, .claudePlan: ""
        }
    }

    private var thinkServerDescription: String {
        guard let url = app.settings.cotypingConfiguredServerURL else {
            return "Think doesn't use a server"
        }
        return "\(app.settings.summarizerBackend.rawValue) · \(url.host ?? url.absoluteString)"
    }

    // MARK: Another server

    @ViewBuilder private var serverRows: some View {
        LabeledContent {
            TextField("Server URL", text: $app.settings.cotypingServerBaseURL,
                      prompt: Text("http://192.168.1.20:8080/v1"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("settings.cotypingServerBaseURL")
        } label: {
            SettingsLabel("Server URL",
                          help: "Any OpenAI-compatible server: a hosted API such as OpenRouter, or llama-server, LM Studio or Ollama on this Mac or another computer, including over Tailscale.")
        }
        .settingTarget("settings.cotypingServerBaseURL", selected: app.focusedSettingID)
        LabeledContent("Model") {
            TextField("Model", text: $app.settings.cotypingServerModel, prompt: Text("Model ID"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .accessibilityIdentifier("settings.cotypingServerModel")
        }
        .settingTarget("settings.cotypingServerModel", selected: app.focusedSettingID)
        LabeledContent("API key") { apiKeyControl }
            .onAppear {
                apiKeySavedValue = app.settings.cotypingServerAPIKey
                apiKeyDraft = apiKeySavedValue
            }
    }

    @ViewBuilder private var apiKeyControl: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !apiKeySavedValue.isEmpty && !editingAPIKey {
                HStack {
                    Label("Saved in Keychain", systemImage: "key").settingsSecondary()
                    Button("Replace…") {
                        apiKeyDraft = ""
                        apiKeyError = nil
                        editingAPIKey = true
                    }
                    .accessibilityIdentifier("settings.cotypingServerAPIKey.replace")
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKeyDraft, prompt: Text("Optional"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .accessibilityIdentifier("settings.cotypingServerAPIKey")
                    Button("Save key") {
                        app.settings.cotypingServerAPIKey = apiKeyDraft
                        // Only acknowledge the key once it reads back from Keychain.
                        apiKeySavedValue = app.settings.cotypingServerAPIKey
                        let saved = apiKeySavedValue == apiKeyDraft
                        if saved { editingAPIKey = false }
                        apiKeyError = saved ? nil : "Couldn’t save the key to Keychain. Try again."
                    }
                    .disabled(apiKeyDraft == apiKeySavedValue)
                    if editingAPIKey {
                        Button("Cancel") {
                            apiKeyDraft = apiKeySavedValue
                            editingAPIKey = false
                            apiKeyError = nil
                        }
                    }
                }
            }
            if let apiKeyError {
                Text(apiKeyError).workspaceTextRole(.warning)
            }
        }
    }

    // MARK: Approval and status

    /// What leaves the Mac, and the approval that allows it. Nothing to approve
    /// for a server on this Mac.
    @ViewBuilder private var disclosure: some View {
        if let url = app.settings.cotypingConfiguredServerURL,
           let origin = InferenceEndpointPolicy.origin(for: url) {
            if InferenceEndpointPolicy.isLoopback(url) {
                Label("Server on this Mac: what you type stays here.", systemImage: "checkmark.shield.fill")
                    .settingsSecondary()
            } else if url.scheme?.lowercased() != "https"
                        && !InferenceEndpointPolicy.permitsUnencrypted(url, allowsPrivateNetworkHTTP: true) {
                Label("Blocked: a server on the internet must use HTTPS, because autocomplete sends what you type.",
                      systemImage: "lock.slash.fill")
                    .workspaceTextRole(.warning)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Remote autocomplete · \(url.host ?? origin)", systemImage: "network")
                        .font(AppFont.scaled(.body).weight(.semibold))
                    Text("While you type, autocomplete sends this server the text before the caret, the window title, and your writing profile. The clipboard, text read from the screen, meeting and screen memory, and learned text stay on this Mac. Password fields and excluded apps and sites are never read.")
                        .workspaceTextRole(.trust)
                        .fixedSize(horizontal: false, vertical: true)
                    if url.scheme?.lowercased() != "https" {
                        Label("Plain HTTP: use this only on a network you trust, such as your home network or a Tailscale tailnet, which encrypts traffic between your devices.",
                              systemImage: "lock.open")
                            .workspaceTextRole(.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if ChatCompletionDialect.inferred(from: url) == .openRouter {
                        Group {
                            if app.settings.openRouterDataPolicy == .privateOnly {
                                Text("OpenRouter: private endpoints only, as chosen under Settings → Models.")
                            } else {
                                Text("OpenRouter: follows your OpenRouter privacy settings, as chosen under Settings → Models.")
                            }
                        }
                        .settingsSecondary()
                    }
                    Toggle("Allow sending typing to \(origin)", isOn: approvalBinding(origin: origin))
                        .accessibilityIdentifier("settings.cotypingServerApproval")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.row))
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch app.settings.cotypingRoute(includingCredentials: false) {
        case .server(let endpoint):
            Label("Suggestions come from \(endpoint.model) on \(endpoint.baseURL.host ?? endpoint.origin).",
                  systemImage: "checkmark.circle")
                .settingsSecondary()
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .workspaceTextRole(.warning)
                .fixedSize(horizontal: false, vertical: true)
        case .onDevice:
            EmptyView()
        }
    }

    private func approvalBinding(origin: String) -> Binding<Bool> {
        Binding {
            app.settings.approvedRemoteAutocompleteOrigins.contains(origin)
        } set: { approved in
            app.settings.approvedRemoteAutocompleteOrigins.removeAll { $0 == origin }
            if approved { app.settings.approvedRemoteAutocompleteOrigins.append(origin) }
        }
    }
}
