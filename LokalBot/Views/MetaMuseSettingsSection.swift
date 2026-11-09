import SwiftUI

/// Settings → Meetings → Meta Muse: the key, the api.meta.ai approval, fast
/// live text, and the models Live Radar and Follow-through use.
struct MetaMuseSettingsSection: View {
    @EnvironmentObject var app: AppState
    @State private var keyDraft = ""
    @State private var savedKey = ""
    @State private var editingKey = false
    @State private var keySaveError: String?

    static let approvalHelp = "Live Radar sends new live transcript lines, the meeting title, invited names, "
        + "and passages from your earlier meetings that local search found, while it runs. Follow-through sends "
        + "the action, its source passages, the meeting summary, your name from Settings → Writing, and what its "
        + "tools read. Audio stays on this Mac unless you turn on fast live text, and voices and calendar email "
        + "addresses always do. The same approval covers Think if you point it at this server."

    static let liveAnswersHelp = "When Live Radar catches a question or a problem, Muse looks for the answer in your "
        + "work: first what LokalBot remembers (your projects and where they stand, your open actions, what you told it "
        + "about yourself), then your meetings, what you saw on screen, and the folders below. It sends Muse the "
        + "question, the last few lines, what it remembers that bears on it, and the parts of meetings, screen text, "
        + "documents, and code it reads. An answer is shown only when its sources contain the words it quotes."

    static let foldersHelp = "Documents, sheets, and PDFs in these folders can be read. In a git repository it also "
        + "reads tracked code, recent commits, and pull requests and issues through the GitHub CLI. Hidden files, "
        + "untracked files, and secrets such as .env files and keys are never read."

    static let panelHelp = "A small window over your meeting app with what Live Radar catches. It opens when a "
        + "recording starts, with Start Radar in it, and never takes focus from the call."

    static let captureHelp = "Others in the call don't see the panel when you share your screen. Turn this off to "
        + "include it in a screen recording."

    static let screenAnswersHelp = "When Live Radar catches a question, LokalBot searches your screen memory on this "
        + "Mac for captures that mention it, crops each to the rows that do, and sends up to three crops with their app, "
        + "window title, and time to Muse Spark. An answer is shown only when its quote is in the crop's own text. "
        + "Whole screenshots and the search stay on this Mac."

    static let liveTextHelp = "While the live transcript preview runs, streams the microphone and call audio to "
        + "\(MuseLiveText.displayName), which returns each turn's text about a second after it ends. Without it, the "
        + "preview transcribes 12-second chunks on this Mac. Who said what still comes from your microphone and the "
        + "call track, never from Muse. Costs about $0.36 per meeting hour for the two tracks."

    private var origin: String { InferenceEndpointPolicy.origin(for: MetaModelAPI.baseURL) ?? MetaModelAPI.origin }

    var body: some View {
        Section {
            Toggle(isOn: approval) {
                SettingsLabel("Allow sending meeting text to \(origin)", help: Self.approvalHelp)
            }
            .accessibilityIdentifier("settings.metaMuse.approval")
            .settingTarget("settings.metaMuseApproval", selected: app.focusedSettingID)

            Toggle(isOn: $app.settings.museLiveTextEnabled) {
                SettingsLabel("Fast live text: send meeting audio to \(MuseLiveText.displayName)", help: Self.liveTextHelp)
            }
            .disabled(!app.settings.metaModelAPIApproved)
            .accessibilityIdentifier("settings.metaMuse.liveText")
            .settingTarget("settings.museLiveTextEnabled", selected: app.focusedSettingID)

            Toggle(isOn: $app.settings.museScreenAnswersEnabled) {
                SettingsLabel("Answer meeting questions from your screen", help: Self.screenAnswersHelp)
            }
            .disabled(!app.settings.metaModelAPIApproved)
            .accessibilityIdentifier("settings.metaMuse.screenAnswers")
            .settingTarget("settings.museScreenAnswersEnabled", selected: app.focusedSettingID)

            Toggle(isOn: $app.settings.liveAnswersEnabled) {
                SettingsLabel("Answer questions from your work during calls", help: Self.liveAnswersHelp)
            }
            .disabled(!app.settings.metaModelAPIApproved)
            .accessibilityIdentifier("settings.metaMuse.liveAnswers")
            .settingTarget("settings.liveAnswersEnabled", selected: app.focusedSettingID)

            if app.settings.liveAnswersEnabled {
                Picker(selection: $app.settings.liveAnswersModel) {
                    ForEach(MetaModelAPI.models) { model in Text(model.displayName).tag(model.id) }
                } label: {
                    SettingsLabel("Live answers model", help: "Muse Wonder reasons through lookups more carefully; Muse Spark answers sooner.")
                }
                .settingTarget("settings.liveAnswersModel", selected: app.focusedSettingID)

                LabeledContent {
                    LiveAnswerFolderList(folders: $app.settings.liveAnswerFolders)
                } label: {
                    SettingsLabel("Folders and repositories it may read", help: Self.foldersHelp)
                }
                .settingTarget("settings.liveAnswerFolders", selected: app.focusedSettingID)
            }

            Toggle(isOn: $app.settings.liveRadarPanelEnabled) {
                SettingsLabel("Show the floating Live Radar panel during meetings", help: Self.panelHelp)
            }
            .accessibilityIdentifier("settings.metaMuse.panel")
            .settingTarget("settings.liveRadarPanelEnabled", selected: app.focusedSettingID)

            Toggle(isOn: $app.settings.liveRadarPanelHiddenFromCapture) {
                SettingsLabel("Hide the floating panel from screen sharing and recordings", help: Self.captureHelp)
            }
            .disabled(!app.settings.liveRadarPanelEnabled)
            .settingTarget("settings.liveRadarPanelHiddenFromCapture", selected: app.focusedSettingID)

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
                        keySaveError = saved ? nil : String(localized: "Couldn’t save the key to Keychain. Try again.")
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
                Text(verbatim: keySaveError).font(.scaled(.callout)).foregroundStyle(Brand.error)
            }
        }
    }
}

/// The folders live answers may read, with a folder picker to add more.
private struct LiveAnswerFolderList: View {
    @Binding var folders: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(folders, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: Self.isRepository(path) ? "chevron.left.forwardslash.chevron.right" : "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: (path as NSString).lastPathComponent).font(.scaled(.callout))
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                            .font(.scaled(.caption)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button("Remove") { folders.removeAll { $0 == path } }
                        .controlSize(.small)
                }
            }
            Button("Add Folder…", action: add)
                .accessibilityIdentifier("settings.metaMuse.addFolder")
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map(\.path).filter { !folders.contains($0) }
        folders += added
    }

    private static func isRepository(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }
}
