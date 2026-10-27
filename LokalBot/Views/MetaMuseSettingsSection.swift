import SwiftUI

/// Settings → Recording → Meta Muse: the key, the api.meta.ai approval, and
/// the models Live Radar and Follow-through use.
struct MetaMuseSettingsSection: View {
    @EnvironmentObject var app: AppState
    @State private var keyDraft = ""
    @State private var savedKey = ""
    @State private var editingKey = false
    @State private var keySaveError: String?

    static let approvalHelp = "Live Radar sends new live transcript lines, the meeting title, invited names, "
        + "and passages from your earlier meetings that local search found, while it runs. Follow-through sends "
        + "the action, its source passages, the meeting summary, your name from Settings → Writing, and what its "
        + "tools read. Audio, voices, and calendar email addresses stay on this Mac. The same approval covers "
        + "Think if you point it at this server."

    private var origin: String { InferenceEndpointPolicy.origin(for: MetaModelAPI.baseURL) ?? MetaModelAPI.origin }

    var body: some View {
        Section {
            Toggle(isOn: approval) {
                SettingsLabel("Allow sending meeting text to \(origin)", help: Self.approvalHelp)
            }
            .accessibilityIdentifier("settings.metaMuse.approval")
            .settingTarget("settings.metaMuseApproval", selected: app.focusedSettingID)

            LabeledContent("API key") { keyControl }
                .settingTarget("settings.metaModelAPIKey", selected: app.focusedSettingID)

            Picker(selection: $app.settings.museRadarModel) {
                ForEach(MetaModelAPI.models) { model in Text(model.displayName).tag(model.id) }
            } label: {
                SettingsLabel("Live Radar model", help: MetaModelAPI.model(id: app.settings.museRadarModel)?.summary ?? "")
            }
            .settingTarget("settings.museRadarModel", selected: app.focusedSettingID)

            Picker(selection: $app.settings.museFollowThroughModel) {
                ForEach(MetaModelAPI.models) { model in Text(model.displayName).tag(model.id) }
            } label: {
                SettingsLabel("Follow-through model",
                              help: "Plans the work for one action and proposes drafts, invites, and handoffs. Nothing is sent or created until you approve it.")
            }
            .settingTarget("settings.museFollowThroughModel", selected: app.focusedSettingID)

            SettingsHelp("Meta's terms for your Model API account apply. Content sent while you use free credits may be used to improve Meta's products, so record only people who agreed.")
        } header: {
            Text("Meta Muse")
        }
        .onAppear {
            savedKey = app.settings.metaModelAPIKey
            keyDraft = savedKey
        }
    }

    private var approval: Binding<Bool> {
        Binding {
            app.settings.metaModelAPIApproved
        } set: { approved in
            app.changeSettings { settings in
                settings.approvedRemoteInferenceOrigins.removeAll { $0 == origin }
                if approved { settings.approvedRemoteInferenceOrigins.append(origin) }
            }
        }
    }

    @ViewBuilder private var keyControl: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !savedKey.isEmpty && !editingKey {
                HStack {
                    Label("Saved in Keychain", systemImage: "key").settingsSecondary()
                    Button("Replace…") {
                        keyDraft = ""
                        keySaveError = nil
                        editingKey = true
                    }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("Meta Model API key", text: $keyDraft)
                        .frame(minWidth: 180)
                        .accessibilityIdentifier("settings.metaMuse.key")
                    Button("Save key") {
                        app.settings.metaModelAPIKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Acknowledge only what reads back from Keychain.
                        savedKey = app.settings.metaModelAPIKey
                        let saved = savedKey == keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if saved { editingKey = false }
                        keySaveError = saved ? nil : "Couldn’t save the key to Keychain. Try again."
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyDraft == savedKey)
                    if editingKey {
                        Button("Cancel") {
                            keyDraft = savedKey
                            editingKey = false
                        }
                    }
                }
                if savedKey.isEmpty, !app.settings.effectiveMetaModelAPIKey.isEmpty {
                    Text("Using Think's key for api.meta.ai.").workspaceTextRole(.supporting)
                } else {
                    Link("Create a key at dev.meta.ai", destination: MetaModelAPI.consoleURL)
                        .font(.scaled(.callout))
                }
            }
            if let keySaveError {
                Text(keySaveError).font(.scaled(.callout)).foregroundStyle(Brand.error)
            }
        }
    }
}
