import SwiftUI

/// The Autocomplete picker's server pane: Think's server with the same or
/// another model, or any OpenAI-compatible server, hosted or on the user's own
/// network. It edits a draft that Use model applies. Typing goes to a server
/// only after its origin is approved for autocomplete; Think's approval does
/// not cover it.
struct AutocompleteServerSetup: View {
    @ObservedObject var app: AppState
    @Binding var draft: CotypingServerDraft
    @State private var keySaved = false

    init(app: AppState, draft: Binding<CotypingServerDraft>) {
        self.app = app
        _draft = draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                if draft.backend == .thinkServer {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Server").gridColumnAlignment(.trailing)
                        Text(thinkServerDescription)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Model")
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Model", text: $draft.thinkServerModel, prompt: thinkModelPrompt)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("models.autocompleteServer.thinkModel")
                            Text("Leave empty to use Think's model, or name a smaller one for faster suggestions.")
                                .font(.scaled(.callout)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Server URL").gridColumnAlignment(.trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Server URL", text: $draft.baseURL,
                                      prompt: Text(verbatim: "http://my-pc.example.ts.net:8080/v1"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("models.autocompleteServer.url")
                            Text("Any OpenAI-compatible /v1 URL, such as OpenRouter, llama-server, LM Studio, or Ollama.")
                                .font(.scaled(.callout)).foregroundStyle(.secondary)
                        }
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("Model")
                        TextField("Model", text: $draft.model, prompt: Text("Model ID"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("models.autocompleteServer.model")
                    }
                    GridRow(alignment: .firstTextBaseline) {
                        Text("API key")
                        HStack(spacing: 8) {
                            SecureField("API key", text: $draft.apiKey, prompt: keyPrompt)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("models.autocompleteServer.apiKey")
                            if keySaved {
                                Button("Forget") {
                                    app.settings.cotypingServerAPIKey = ""
                                    keySaved = !app.settings.cotypingServerAPIKey.isEmpty
                                    draft.apiKey = ""
                                    app.modelChecks.invalidate([.autocomplete])
                                }
                                .accessibilityIdentifier("models.autocompleteServer.forgetKey")
                            }
                        }
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Request type")
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Request type", selection: $draft.requestStyle) {
                            ForEach(CotypingServerRequestStyle.allCases) { style in
                                Text(LocalizedStringKey(style.title)).tag(style)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("models.autocompleteServer.requestStyle")
                        Text("Automatic picks text completion or chat for the server.")
                            .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.scaled(.body))
            access
        }
        .padding(.top, 16)
        .onAppear { keySaved = !app.settings.cotypingServerAPIKey.isEmpty }
        .onChange(of: draft.origin(in: app.settings)) {
            // An approval belongs to one origin. Show the saved choice for a
            // newly entered server rather than carrying the checkbox over.
            draft.approved = draft.savedApproval(in: app.settings)
        }
    }

    // MARK: Think's server

    private var thinkModel: String {
        switch app.settings.summarizerBackend {
        case .ollama: app.settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openAICompatible: app.settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        case .builtIn, .appleIntelligence, .chatGPTPlan, .claudePlan: ""
        }
    }

    private var thinkModelPrompt: Text {
        if thinkModel.isEmpty { return Text("Model ID") }
        return Text("Same as Think (\(thinkModel))")
    }

    private var thinkServerDescription: String {
        guard let url = draft.serverURL(in: app.settings) else { return "Think doesn't use a server" }
        return "\(app.settings.summarizerBackend.rawValue) · \(url.host ?? url.absoluteString)"
    }

    // MARK: Another server

    private var keyPrompt: Text {
        if keySaved { return Text("Saved in Keychain") }
        return Text("Optional")
    }

    // MARK: Approval

    /// The approval checkbox, with what it sends. Nothing to approve for a
    /// server on this Mac.
    @ViewBuilder private var access: some View {
        if let url = draft.serverURL(in: app.settings), let origin = InferenceEndpointPolicy.origin(for: url) {
            if InferenceEndpointPolicy.isLoopback(url) {
                Label("Runs on this Mac. What you type stays here.", systemImage: "checkmark.shield.fill")
                    .font(.scaled(.callout)).foregroundStyle(.secondary)
            } else if url.scheme?.lowercased() != "https"
                        && !InferenceEndpointPolicy.permitsUnencrypted(url, allowsPrivateNetworkHTTP: true) {
                Label("Use HTTPS for a server outside your network or tailnet.", systemImage: "lock.slash.fill")
                    .font(.scaled(.callout)).foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Send typing to \(origin)", isOn: $draft.approved)
                        .toggleStyle(.checkbox)
                        .font(.scaled(.body).weight(.medium))
                        .accessibilityIdentifier("models.autocompleteServer.consent")
                    Text("What you type goes to this server as you type, with the context you turn on under Settings → Writing.")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if url.scheme?.lowercased() != "https" {
                        Label("Unencrypted HTTP: use it only on your own network or tailnet.", systemImage: "lock.open")
                            .font(.scaled(.callout)).foregroundStyle(.orange)
                    }
                    if ChatCompletionDialect.inferred(from: url) == .openRouter {
                        Group {
                            if app.settings.openRouterDataPolicy == .privateOnly {
                                Text("OpenRouter: private endpoints only, as chosen under Settings → Models.")
                            } else {
                                Text("OpenRouter: follows your OpenRouter privacy settings, as chosen under Settings → Models.")
                            }
                        }
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.row))
            }
        } else if draft.backend == .server,
                  !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Label("The autocomplete server URL must start with http:// or https://.", systemImage: "exclamationmark.triangle")
                .font(.scaled(.callout)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
