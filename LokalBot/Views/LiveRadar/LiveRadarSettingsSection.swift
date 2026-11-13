import SwiftUI

/// Settings → Meetings → Live Radar: whether it is offered, what it may look
/// up to answer a question, and its floating panel. It reads with the Think
/// model chosen in Settings → Models, so there is no model to pick here.
struct LiveRadarSettingsSection: View {
    @EnvironmentObject var app: AppState

    static let radarHelp = "Live Radar catches commitments, decisions, open questions, and conflicts with earlier "
        + "meetings while you record. It starts only when you press Start Radar. Your Think model (Settings → Models) "
        + "then reads new live transcript lines, the meeting title, invited names, and passages from your earlier "
        + "meetings that local search found. With a Think model on this Mac, none of that leaves it. Audio stays on "
        + "this Mac unless you turn on fast live text, and voices and calendar email addresses always do."

    static let liveAnswersHelp = "When Live Radar catches a question or a problem, your Think model looks for the "
        + "answer in your work: first what LokalBot remembers (your projects and where they stand, your open actions, "
        + "what you told it about yourself), then your meetings, what you saw on screen, and the folders below. It is "
        + "given the question, the last few lines, what LokalBot remembers that bears on it, and the parts of "
        + "meetings, screen text, documents, and code it reads. An answer is shown only when its sources contain the "
        + "words it quotes."

    static let foldersHelp = "Documents, sheets, and PDFs in these folders can be read. In a git repository it also "
        + "reads tracked code, recent commits, and pull requests and issues through the GitHub CLI. Hidden files, "
        + "untracked files, and secrets such as .env files and keys are never read."

    static let panelHelp = "A small window over your meeting app with what Live Radar catches. It opens when a "
        + "recording starts, with Start Radar in it, and never takes focus from the call."

    static let captureHelp = "Others in the call don't see the panel when you share your screen. Turn this off to "
        + "include it in a screen recording."

    static let screenAnswersHelp = "When Live Radar catches a question, LokalBot searches your screen memory on this "
        + "Mac for captures that mention it, crops each to the rows that do, and gives your Think model the text of up "
        + "to three crops with their app, window title, and time. An answer is shown only when its quote is in the "
        + "crop's own text. Screenshots and the search stay on this Mac."

    var body: some View {
        Section {
            Toggle(isOn: $app.settings.liveRadarEnabled) {
                SettingsLabel("Offer Live Radar during meetings", help: Self.radarHelp)
            }
            .accessibilityIdentifier("settings.liveRadar.enabled")
            .settingTarget("settings.liveRadarEnabled", selected: app.focusedSettingID)

            Toggle(isOn: $app.settings.museScreenAnswersEnabled) {
                SettingsLabel("Answer meeting questions from your screen", help: Self.screenAnswersHelp)
            }
            .disabled(!app.settings.liveRadarEnabled)
            .accessibilityIdentifier("settings.liveRadar.screenAnswers")
            .settingTarget("settings.museScreenAnswersEnabled", selected: app.focusedSettingID)

            Toggle(isOn: $app.settings.liveAnswersEnabled) {
                SettingsLabel("Answer questions from your work during calls", help: Self.liveAnswersHelp)
            }
            .disabled(!app.settings.liveRadarEnabled)
            .accessibilityIdentifier("settings.liveRadar.liveAnswers")
            .settingTarget("settings.liveAnswersEnabled", selected: app.focusedSettingID)

            if app.settings.liveAnswersEnabled {
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
            .disabled(!app.settings.liveRadarEnabled)
            .accessibilityIdentifier("settings.liveRadar.panel")
            .settingTarget("settings.liveRadarPanelEnabled", selected: app.focusedSettingID)

            Toggle(isOn: $app.settings.liveRadarPanelHiddenFromCapture) {
                SettingsLabel("Hide the floating panel from screen sharing and recordings", help: Self.captureHelp)
            }
            .disabled(!app.settings.liveRadarEnabled || !app.settings.liveRadarPanelEnabled)
            .settingTarget("settings.liveRadarPanelHiddenFromCapture", selected: app.focusedSettingID)
        } header: {
            Text("Live Radar")
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
                .accessibilityIdentifier("settings.liveRadar.addFolder")
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
