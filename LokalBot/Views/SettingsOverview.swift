import SwiftUI

/// Settings → Overview, where Settings opens: every feature LokalBot has,
/// whether it is on, and one click to turn it on or open its page. Features
/// that capture or share data open their page instead of turning on here, so
/// their explanation and consent stay where they are.
struct SettingsOverview: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var access: AgentReadAccess
    @ObservedObject var email: EmailController
    @ObservedObject var personalModel: PersonalModelController

    enum Status {
        case on(LocalizedStringKey)
        case off(LocalizedStringKey)
        case attention(LocalizedStringKey)
    }

    struct Action {
        let title: LocalizedStringKey
        let run: () -> Void
    }

    struct Feature: Identifiable {
        let id: String
        let group: AppState.SettingsTab.Group
        let title: LocalizedStringKey
        let icon: String
        let status: Status
        let detail: LocalizedStringKey
        let page: AppState.SettingsTab
        var focus: String?
        var action: Action?
    }

    struct Attention: Identifiable {
        let id: String
        let text: LocalizedStringKey
        let button: LocalizedStringKey
        let run: () -> Void
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LBTokens.Metric.sectionSpacing) {
                let attention = attentionItems
                if !attention.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Needs Attention").font(.scaled(.headline))
                        ForEach(attention) { item in attentionRow(item) }
                    }
                }
                ForEach(AppState.SettingsTab.Group.allCases.filter { $0 != .app }, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey(group.rawValue)).font(.scaled(.headline))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10, alignment: .top)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(features.filter { $0.group == group }) { card($0) }
                        }
                    }
                }
                shortcuts
            }
            .frame(maxWidth: LBTokens.Metric.readingMaxWidth, alignment: .leading)
            .padding(.horizontal, LBTokens.Metric.detailPadding)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("settings.overview")
        .onAppear { personalModel.loadIfNeeded() }
    }

    // MARK: - Features

    private var features: [Feature] {
        let settings = app.settings
        let installer = LokalBotCLIInstaller.bundled
        let screenMode = settings.effectiveScreenContextCaptureMode
        let shared = access.granted.count
        let routinesOn = settings.memoryRoutinesEnabled || settings.dailyMemoryExportEnabled
            || settings.meetingNoteExportEnabled
        let learned = personalModel.suggestions.count
        return [
            Feature(id: "meetings", group: .memory, title: "Meetings", icon: AppState.SettingsTab.recording.icon,
                    status: granted(.microphone) ? .on("On") : .attention("Needs permission"),
                    detail: LocalizedStringKey(settings.autoRecordMode.rawValue), page: .recording),
            Feature(id: "screen", group: .memory, title: "Screen & Activity", icon: AppState.SettingsTab.dayMemory.icon,
                    status: !settings.trackingEnabled ? .off("Off")
                        : !screenMode.capturesText ? .off("Apps only")
                        : screenMode.capturesPixels && !granted(.screenRecording) ? .attention("Needs permission")
                        : .on(LocalizedStringKey(screenMode.rawValue)),
                    detail: screenMode.capturesText ? "Ask can find what you read on screen."
                        : "Capture the text on screen, so Ask can find what you read.",
                    page: .dayMemory, focus: "settings.effectiveScreenContextCaptureMode",
                    action: screenMode.capturesText ? nil : Action(title: "Choose…") {
                        open(.dayMemory, focus: "settings.effectiveScreenContextCaptureMode")
                    }),
            Feature(id: "files", group: .memory, title: "Files", icon: AppState.SettingsTab.files.icon,
                    status: settings.fileSearchEnabled ? .on("\(settings.fileSearchFolders.count) folders") : .off("Off"),
                    detail: "Find documents, PDFs, and pictures by what’s in them.",
                    page: .files, focus: "settings.fileSearchEnabled",
                    action: settings.fileSearchEnabled ? nil : Action(title: "Set Up…") {
                        open(.files, focus: "settings.fileSearchEnabled")
                    }),
            Feature(id: "email", group: .memory, title: "Email", icon: AppState.SettingsTab.email.icon,
                    status: email.accounts.isEmpty ? .off("Not connected") : .on("On"),
                    detail: "Read-only Gmail, so briefs know the thread.",
                    page: .email, focus: "settings.email",
                    action: email.accounts.isEmpty ? Action(title: "Connect…") { open(.email, focus: "settings.email") } : nil),
            Feature(id: "askAnywhere", group: .assistant, title: "Ask anywhere", icon: AppState.SettingsTab.ask.icon,
                    status: settings.quickRecallEnabled ? .on("On") : .off("Off"),
                    detail: "Press \(settings.quickRecallShortcut.displayLabel) in any app to search your memory or ask a question.",
                    page: .ask, focus: "settings.quickRecallEnabled",
                    action: settings.quickRecallEnabled ? nil : Action(title: "Turn On") {
                        app.settings.quickRecallEnabled = true
                    }),
            Feature(id: "selectionActions", group: .assistant, title: "Selection actions", icon: "character.cursor.ibeam",
                    status: settings.selectionActionsEnabled ? .on("On") : .off("Off"),
                    detail: "Select text in any app and press \(settings.selectionActionsShortcut.displayLabel) to rewrite, translate, or summarize it.",
                    page: .ask, focus: "settings.selectionActionsEnabled",
                    action: settings.selectionActionsEnabled ? nil : Action(title: "Turn On") {
                        app.settings.selectionActionsEnabled = true
                    }),
            Feature(id: "personalContext", group: .assistant, title: "Personal Context",
                    icon: AppState.SettingsTab.personalContext.icon,
                    status: learned > 0 ? .attention("\(learned) to review") : .on("\(personalModel.claims.count) items"),
                    detail: "What you told LokalBot about yourself, and what it learns.", page: .personalContext),
            Feature(id: "overnight", group: .assistant, title: "Overnight review", icon: AppState.SettingsTab.daily.icon,
                    status: settings.dreamingEnabled ? .on("On") : .off("Off"),
                    detail: "A morning retrospective of yesterday, on Today.",
                    page: .daily, focus: "settings.dreamingEnabled",
                    action: settings.dreamingEnabled ? nil : Action(title: "Turn On") { app.setDreamingEnabled(true) }),
            Feature(id: "routines", group: .assistant, title: "Routines and exports", icon: "tray.and.arrow.down",
                    status: routinesOn ? .on("On") : .off("Off"),
                    detail: "Stand-up notes, a weekly log, and notes for Obsidian, written to a folder you choose.",
                    page: .daily, focus: "settings.memoryRoutinesEnabled",
                    action: routinesOn ? nil : Action(title: "Set Up…") {
                        open(.daily, focus: "settings.memoryRoutinesEnabled")
                    }),
            Feature(id: "autocomplete", group: .writing, title: "Autocomplete", icon: AppState.SettingsTab.writing.icon,
                    status: !settings.cotypingEnabled ? .off("Off")
                        : granted(.accessibility) && granted(.inputMonitoring) ? .on("On") : .attention("Needs permission"),
                    detail: "Suggestions as you type in other apps, on this Mac.",
                    page: .writing, focus: "settings.autocompletePreview",
                    action: settings.cotypingEnabled ? nil : Action(title: "Try autocomplete") {
                        open(.writing, focus: "settings.autocompletePreview")
                    }),
            Feature(id: "dictation", group: .writing, title: "Dictation", icon: AppState.SettingsTab.dictation.icon,
                    status: !settings.dictationEnabled ? .off("Off")
                        : granted(.inputMonitoring) ? .on("On") : .attention("Needs permission"),
                    detail: "Press \(settings.dictationShortcut.displayLabel), speak, and the text lands where you type.",
                    page: .dictation, focus: "settings.dictationEnabled",
                    action: settings.dictationEnabled ? nil : Action(title: "Turn On") {
                        app.settings.dictationEnabled = true
                    }),
            Feature(id: "models", group: .connections, title: "Models", icon: AppState.SettingsTab.models.icon,
                    status: modelsStatus(settings),
                    detail: "Choose the models behind Transcribe, Think, and Autocomplete.", page: .models),
            Feature(id: "agents", group: .connections, title: "External Agents", icon: AppState.SettingsTab.agents.icon,
                    status: access.isEnabled ? .on("\(shared) of \(AgentReadAccess.Kind.allCases.count) kinds") : .off("Off"),
                    detail: "Claude, Codex, Cursor, and other agents can read what you allow.",
                    page: .agents, focus: "settings.agentAccess"),
            Feature(id: "agentCLI", group: .connections, title: "Agent CLI", icon: "terminal",
                    status: installer.isInstalled ? .on("Installed") : .off("Not installed"),
                    detail: "lokalbot-cli and its skill, for coding agents in Terminal.",
                    page: .agents, focus: "settings.agentCLI",
                    action: installer.isInstalled || installer.bundledBinary == nil ? nil : Action(title: "Install…") {
                        open(.agents, focus: "settings.agentCLI")
                    }),
        ]
    }

    private func modelsStatus(_ settings: AppSettings) -> Status {
        if case .blocked = InferencePresentation(settings: settings) { return .attention("Needs Attention") }
        return .on(LocalizedStringKey(ModelSettingsPresentation.setupLocation(settings)))
    }

    /// The title opens the feature's page; the bottom row shows its status and
    /// either the one action that turns it on or a link to its settings.
    private func card(_ feature: Feature) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open(feature.page, focus: feature.focus) } label: {
                HStack(spacing: 9) {
                    IconTile(systemImage: feature.icon, tint: Brand.teal, size: 28)
                        .accessibilityHidden(true)
                    Text(feature.title)
                        .font(.scaled(.body).weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.scaled(.caption))
                        .settingsSecondary()
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.overview.\(feature.id).open")
            Text(feature.detail)
                .font(.scaled(.callout))
                .settingsSecondary()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack(spacing: 8) {
                badge(feature.status)
                Spacer(minLength: 4)
                if let action = feature.action {
                    Button(action: action.run) { Text(action.title) }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.tealFill)
                        .controlSize(.small)
                        .accessibilityIdentifier("settings.overview.\(feature.id).action")
                } else {
                    Button { open(feature.page, focus: feature.focus) } label: {
                        HStack(spacing: 2) {
                            Text("Settings")
                            Image(systemName: "chevron.right").font(.scaled(.caption))
                        }
                    }
                    .buttonStyle(.workspaceLink)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.overview.\(feature.id).settings")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.overview.\(feature.id)")
    }

    private func badge(_ status: Status) -> some View {
        let (text, color): (LocalizedStringKey, Color) = switch status {
        case .on(let text): (text, Brand.teal)
        case .off(let text): (text, .secondary)
        case .attention(let text): (text, Brand.error)
        }
        return Text(text)
            .font(.scaled(.caption).weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Needs attention

    private var attentionItems: [Attention] {
        let settings = app.settings
        var items: [Attention] = []
        func grant(_ permission: AppPermission) -> () -> Void {
            { PermissionGuidanceController.shared.requestAccess(for: permission) }
        }
        if !granted(.microphone) {
            items.append(Attention(id: "microphone", text: "Microphone access is off, so meetings can’t be recorded.",
                                   button: "Grant…", run: grant(.microphone)))
        }
        if settings.trackingEnabled || settings.cotypingEnabled, !granted(.accessibility) {
            items.append(Attention(id: "accessibility",
                                   text: "Accessibility is off, so window titles and autocomplete are paused.",
                                   button: "Grant…", run: grant(.accessibility)))
        }
        if settings.effectiveScreenContextCaptureMode.capturesPixels, !granted(.screenRecording) {
            items.append(Attention(id: "screenRecording", text: "Screen Recording is off, so visual screen context is paused.",
                                   button: "Grant…", run: grant(.screenRecording)))
        }
        if settings.dictationEnabled || settings.cotypingEnabled, !granted(.inputMonitoring) {
            items.append(Attention(id: "inputMonitoring",
                                   text: "Input Monitoring is off, so the dictation and autocomplete shortcuts don’t work.",
                                   button: "Grant…", run: grant(.inputMonitoring)))
        }
        let learned = personalModel.suggestions.count
        if learned > 0 {
            items.append(Attention(id: "learned", text: "\(learned) things LokalBot learned about you are waiting for review.",
                                   button: "Review…", run: { open(.personalContext, focus: nil) }))
        }
        return items
    }

    private func attentionRow(_ item: Attention) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Brand.error)
                .accessibilityHidden(true)
            Text(item.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: item.run) { Text(item.button) }
                .controlSize(.small)
                .accessibilityIdentifier("settings.overview.attention.\(item.id)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .lbStatusSurface(.orange)
    }

    /// Unknown counts as granted until the first permission poll, so a
    /// warning never flashes on open.
    private func granted(_ permission: AppPermission) -> Bool {
        permissions.granted[permission] ?? true
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        let settings = app.settings
        let rows: [(LocalizedStringKey, String, Bool, AppState.SettingsTab?)] = [
            ("Ask anywhere", settings.quickRecallShortcut.displayLabel, settings.quickRecallEnabled, .ask),
            ("Selection actions", settings.selectionActionsShortcut.displayLabel, settings.selectionActionsEnabled, .ask),
            ("Dictation", settings.dictationShortcut.displayLabel, settings.dictationEnabled, .dictation),
            ("Accept a suggestion", app.settings.appLanguage.localized(settings.cotypingAcceptKey.label),
             settings.cotypingEnabled, .writing),
            ("Command palette", "⌘K", true, nil),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard shortcuts").font(.scaled(.headline))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { SettingsSeparator() }
                    shortcutRow(row.0, keys: row.1, on: row.2, page: row.3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .settingsPanel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.overview.shortcuts")
    }

    @ViewBuilder
    private func shortcutRow(_ title: LocalizedStringKey, keys: String, on: Bool, page: AppState.SettingsTab?) -> some View {
        let row = HStack(spacing: 10) {
            Text(title).foregroundStyle(on ? .primary : .secondary)
            Spacer(minLength: 8)
            if !on { Text("Off").font(.scaled(.callout)).settingsSecondary() }
            Text(verbatim: keys)
                .font(.scaled(.callout).monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(LBTokens.Palette.groupFill, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(LBTokens.Palette.groupStroke))
                .opacity(on ? 1 : 0.55)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        if let page {
            Button { open(page, focus: nil) } label: { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    private func open(_ page: AppState.SettingsTab, focus: String?) {
        app.selectSettingsTab(page)
        if let focus { app.focusedSettingID = focus }
    }
}
