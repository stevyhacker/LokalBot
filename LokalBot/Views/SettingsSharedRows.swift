import SwiftUI

/// What opens over a Settings page instead of sending you to another page.
enum SettingsSheet: Identifiable {
    case model(ModelPickerRole)
    case transcriptionOptions
    /// "Try it…" on Autocomplete and Dictation.
    case tryAutocomplete
    case tryDictation

    var id: String {
        switch self {
        case .model(let role): "model.\(role.rawValue)"
        case .transcriptionOptions: "transcriptionOptions"
        case .tryAutocomplete: "tryAutocomplete"
        case .tryDictation: "tryDictation"
        }
    }

    /// The sheet a deep link to a feature's try-out opens.
    init?(focusedSettingID: String?, on page: AppState.SettingsTab) {
        switch (focusedSettingID, page) {
        case ("settings.autocompletePreview", .writing): self = .tryAutocomplete
        case ("settings.dictationPreview", .dictation): self = .tryDictation
        default: return nil
        }
    }
}

// MARK: - Rows

/// A longer explanation behind an "i", so the row itself stays one line.
struct SettingsInfoButton: View {
    let text: String
    @State private var shown = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(AppFont.scaled(.body))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsSecondary()
        .help(Text(LocalizedStringKey(text)))
        .accessibilityLabel("More information")
        .accessibilityHint(Text(LocalizedStringKey(text)))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(LocalizedStringKey(text))
                .font(AppFont.scaled(.callout))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

/// A switch with its name at the left, an optional line under the name, an
/// optional "i", and an optional line of state that the caller draws.
struct SettingsSwitchRow<Status: View>: View {
    let title: String
    var detail: String?
    var info: String?
    @Binding var isOn: Bool
    @ViewBuilder var status: Status

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let info { SettingsInfoButton(info) }
                Toggle(isOn: $isOn) { Text(LocalizedStringKey(title)) }
                    .labelsHidden()
                    .accessibilityLabel(Text(LocalizedStringKey(title)))
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                if let detail { SettingsHelp(detail) }
                status
            }
        }
    }
}

extension SettingsSwitchRow where Status == EmptyView {
    init(_ title: String, detail: String? = nil, info: String? = nil, isOn: Binding<Bool>) {
        self.init(title: title, detail: detail, info: info, isOn: isOn) { EmptyView() }
    }
}

/// A row that opens another page: its name, an optional line under it, an
/// optional value, and a chevron.
struct SettingsDrillRow: View {
    let title: String
    var detail: String?
    var value: String?
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LabeledContent {
                HStack(spacing: 6) {
                    if let value {
                        Text(verbatim: value).settingsSecondary().lineLimit(1).truncationMode(.middle)
                    }
                    Image(systemName: "chevron.forward").font(.scaled(.caption)).settingsSecondary()
                        .accessibilityHidden(true)
                }
            } label: {
                SettingsLabel(title, help: detail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The way back from a page a row opened, and that page's name.
struct SettingsSubpageBar: View {
    let subpage: SettingsSubpage
    let back: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Label { Text(LocalizedStringKey(subpage.page.displayName)) } icon: {
                    Image(systemName: "chevron.backward")
                }
            }
            .accessibilityIdentifier("settings.subpage.back")
            Text(LocalizedStringKey(subpage.title)).font(.scaled(.headline))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settings.subpage.title")
            Spacer(minLength: 12)
        }
    }
}

/// One kind of agent read access, shown on the page of the data it covers.
/// It is the same grant as that kind's box on AI agents.
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
            SettingsHelp("The same switch as on AI agents. Agents read only; they never change anything.")
        }
    }

    private var title: String {
        switch kind {
        case .meetings: "Let external agents read meetings"
        case .screenMemory: "Let external agents read screen memory"
        case .personalContext: "Let external agents read items I share"
        case .files: "Let external agents search Files"
        case .agentNotes: "Let external agents search agent notes"
        }
    }

    private var help: String {
        switch kind {
        case .meetings: "List, read, search, and ask about your meetings."
        case .screenMemory: "Captured text and metadata, within the history you grant. Screenshot pixels are never returned."
        case .personalContext: "Only the Personal Context items you mark Share with agents."
        case .files: "Search the folders you chose under Files by their words. Files are never changed."
        case .agentNotes: "Search the notes Claude Code and Codex saved for themselves by their words. The notes are never changed."
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
