import SwiftUI

/// What opens over a Settings page instead of sending you to another page.
enum SettingsSheet: Identifiable {
    case model(ModelPickerRole)
    case transcriptionOptions

    var id: String {
        switch self {
        case .model(let role): "model.\(role.rawValue)"
        case .transcriptionOptions: "transcriptionOptions"
        }
    }
}

/// One kind of agent read access, shown on the page of the data it covers.
/// It is the same grant as that kind's box on External Agents.
struct AgentKindAccessSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var access: AgentReadAccess
    let kind: AgentReadAccess.Kind
    /// A line under the box, such as how many items are shared.
    var detail: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { access.isGranted(kind) }, set: { access.setGranted(kind, $0) })) {
                SettingsLabel(title, help: help)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("settings.agentKind.\(kind.rawValue)")
            .settingTarget("settings.agentKind.\(kind.rawValue)", selected: app.focusedSettingID)
            if kind == .screenMemory, access.isGranted(.screenMemory) {
                Picker(selection: Binding(get: { access.screenScope }, set: { access.setScreenScope($0) })) {
                    ForEach(ScreenMemoryAccessProfile.Scope.allCases) { scope in
                        Text(LocalizedStringKey(scope.displayName)).tag(scope)
                    }
                } label: {
                    SettingsLabel("Granted history", help: access.screenScope.detail)
                }
            }
            if let detail {
                Text(LocalizedStringKey(detail))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("External agents")
        } footer: {
            SettingsHelp("The same switch as on External Agents. Agents read only; they never change anything.")
        }
    }

    private var title: String {
        switch kind {
        case .meetings: "Let external agents read meetings"
        case .screenMemory: "Let external agents read screen memory"
        case .personalContext: "Let external agents read items I share"
        case .files: "Let external agents search Files"
        }
    }

    private var help: String {
        switch kind {
        case .meetings: "List, read, search, and ask about your meetings."
        case .screenMemory: "Captured text and metadata, within the history you grant. Screenshot pixels are never returned."
        case .personalContext: "Only the Personal Context items you mark Share with agents."
        case .files: "Search the folders you chose under Files by their words. Files are never changed."
        }
    }
}

/// The writing profile Autocomplete and Dictation's Compose share. Both pages
/// show these fields, bound to the same settings, so neither sends you to the
/// other to edit them.
struct WritingProfileFields: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            field("Your name", prompt: "Optional", text: $app.settings.cotypingUserName,
                  id: "settings.cotypingUserName")
            field("Writing style", prompt: "Optional, e.g. concise and friendly", text: $app.settings.cotypingStyleNote,
                  id: "settings.cotypingStyleNote")
            field("Languages", prompt: "Optional, e.g. English, German", text: $app.settings.cotypingLanguages,
                  id: "settings.cotypingLanguages")
        }
    }

    private func field(_ title: String, prompt: String, text: Binding<String>, id: String) -> some View {
        LabeledContent {
            TextField(LocalizedStringKey(title), text: text, prompt: Text(LocalizedStringKey(prompt)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
        } label: {
            Text(LocalizedStringKey(title))
        }
        .settingTarget(id, selected: app.focusedSettingID)
    }
}
