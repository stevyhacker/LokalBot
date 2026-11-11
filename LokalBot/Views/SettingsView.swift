import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var updates = AppUpdateManager.shared
    @State private var cliMessage: String?
    @State private var exportingDiagnostics = false
    @State private var confirmingDreamMemoryClear = false
    /// The page a row of Autocomplete or Dictation opened in its place.
    @State private var subpage: SettingsSubpage?
    /// Model choices and transcription options open over the page that uses
    /// them, so no setting sends you to another page to finish.
    @State private var sheet: SettingsSheet?

    // Settings search + live system readouts.
    @State private var settingsQuery = ""
    @StateObject private var power = PowerSourceMonitor()
    @StateObject private var permissions = PermissionManager.shared
    @ObservedObject private var metrics = GenerationMetricsStore.shared
    /// What every part of the window says about each feature's state.
    @State private var status = SettingsStatus(.init())
    @State private var history = SettingsPageHistory(current: .overview)

    /// The window opens at this size and can be resized.
    static let defaultSize = CGSize(width: 1020, height: 816)

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(status: status, query: $settingsQuery)
                .frame(width: LBTokens.Metric.settingsCategoriesWidth)
                .background(LBTokens.Palette.groupFill)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                topBar
                Divider()
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .model(let role):
                    ModelPickerSheet(app: app, role: role, openConnections: {
                        self.sheet = nil
                        app.openSettings(tab: .models)
                        app.focusedSettingID = "settings.openAIBaseURL"
                    })
                case .transcriptionOptions:
                    ModelTranscriptionOptionsSheet(app: app)
                case .tryAutocomplete:
                    AutocompleteTrySheet(server: app.cotypingServer)
                        .environmentObject(app)
                case .tryDictation:
                    DictationTrySheet(dictation: app.dictation, status: status)
                        .environmentObject(app)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(LocalizedStringKey(title)))
        }
        // The list and the top bar run to the window's top edge, beside and
        // under the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 780, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Settings no longer sits above the main window's error bar.
            if let error = app.lastError {
                ErrorToast(message: error) { app.lastError = nil }
            }
        }
        .tint(Brand.teal)
        .navigationTitle(Text(LocalizedStringKey(title)))
        .background(SettingsStatusObserver(
            app: app, permissions: permissions, modelRoles: app.modelRoles, access: app.agentReadAccess,
            settingsControl: app.settingsControl, email: app.email, companion: app.companion,
            calendar: app.calendar, checks: app.modelChecks, status: $status))
        .task {
            // Lets a window opened from the menu bar alone open the others.
            WindowAccess.shared.register { openWindow(id: $0) }
        }
        .onAppear {
            history = SettingsPageHistory(current: app.settingsTab)
            power.start()
            permissions.startPolling()
            app.calendar.refreshAuthorizationStatus()
            app.refreshDreamMemory()
        }
        .onChange(of: app.settingsTab) { _, page in
            history.visit(page)
            // A row's page belongs to the Settings page that opened it.
            if subpage?.page != page { subpage = nil }
        }
        .onChange(of: app.focusedSettingID, initial: true) { revealFocusedSetting() }
        .onDisappear {
            power.stop()
            permissions.stopPolling()
            PermissionGuidanceController.shared.dismiss()
        }
    }

    /// Search and deep links land on settings that a row's page holds, and
    /// the Autocomplete and Dictation commands open the try-out sheet.
    private func revealFocusedSetting() {
        guard let id = app.focusedSettingID else { return }
        if let sheet = SettingsSheet(focusedSettingID: id, on: app.settingsTab) {
            self.sheet = sheet
            // Consumed, so reopening Settings does not open the sheet again.
            app.focusedSettingID = nil
        } else if let holder = SettingsSubpage.containing(settingID: id, on: app.settingsTab) {
            subpage = holder
        } else if subpage?.page == app.settingsTab {
            // The setting is on the page itself.
            subpage = nil
        }
    }

    /// The open row's page, while its own Settings page is the one shown.
    private var openSubpage: SettingsSubpage? {
        subpage.flatMap { $0.page == app.settingsTab ? $0 : nil }
    }

    private var queryIsEmpty: Bool {
        settingsQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The window's and the top bar's title: the page, or search.
    private var title: String {
        queryIsEmpty ? app.settingsTab.displayName : "Search settings"
    }

    /// Back and forward through the pages visited, then the page's name.
    private var topBar: some View {
        HStack(spacing: 2) {
            Button {
                if let page = history.goBack() { settingsQuery = ""; app.selectSettingsTab(page) }
            } label: {
                Image(systemName: "chevron.backward").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .disabled(!history.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("settings.back")
            Button {
                if let page = history.goForward() { settingsQuery = ""; app.selectSettingsTab(page) }
            } label: {
                Image(systemName: "chevron.forward").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .disabled(!history.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")
            .accessibilityIdentifier("settings.forward")
            Text(LocalizedStringKey(title))
                .font(AppFont.scaled(.title3).weight(.bold))
                .lineLimit(1)
                .padding(.leading, 8)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settings.title")
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: SettingsChrome.topBarHeight)
    }

    /// Search results, or the selected page. Every page opens with the
    /// shared header; Overview opens with what needs you instead.
    @ViewBuilder private var page: some View {
        if !queryIsEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Results across all categories. Choose a setting to edit its value.")
                    .font(AppFont.scaled(.callout))
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LBTokens.Metric.detailPadding)
                    .padding(.vertical, 12)
                searchResults
            }
        } else if app.settingsTab == .overview {
            SettingsOverview(status: status, personalModel: app.personalModel)
        } else if app.settingsTab == .models {
            ModelsView(status: status)
                .settingTarget("settings.models", selected: app.focusedSettingID)
        } else {
            VStack(spacing: 0) {
                if let openSubpage {
                    SettingsSubpageBar(subpage: openSubpage) { subpage = nil }
                        .frame(maxWidth: LBTokens.Metric.readingMaxWidth + 16)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
                }
                ScrollViewReader { proxy in
                    Form {
                        // A row's page opens with the way back instead of the header.
                        if openSubpage == nil { Section { header(for: app.settingsTab) } }
                        sections(for: app.settingsTab)
                    }
                    .formStyle(.grouped)
                    .toggleStyle(LBAccentSwitchStyle())
                    .frame(maxWidth: LBTokens.Metric.readingMaxWidth + 56)
                    .frame(maxWidth: .infinity)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("settings.form")
                    .onChange(of: app.focusedSettingID, initial: true) {
                        guard let id = app.focusedSettingID else { return }
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                // Each page, and each row's page, starts at its own top.
                .id(openSubpage?.rawValue ?? app.settingsTab.rawValue)
            }
        }
    }

    /// The shared header, with the main switch on the pages that have one
    /// and "Try it…" where the feature can be tried, in a sheet over the page.
    @ViewBuilder private func header(for tab: AppState.SettingsTab) -> some View {
        switch tab {
        case .writing:
            SettingsPageHeader(page: tab, status: status,
                               tryIt: { sheet = .tryAutocomplete },
                               isOn: $app.settings.cotypingEnabled, switchLabel: "Enable autocomplete",
                               switchSettingID: "settings.cotypingEnabled")
        case .dictation:
            SettingsPageHeader(page: tab, status: status,
                               tryIt: { sheet = .tryDictation },
                               isOn: $app.settings.dictationEnabled, switchLabel: "Enable dictation shortcut",
                               switchSettingID: "settings.dictationEnabled")
        default:
            SettingsPageHeader(page: tab, status: status)
        }
    }

    /// Each page holds one feature: everything that turns it on and sets it
    /// up, under the shared header. Models is ModelsView and Overview is
    /// SettingsOverview.
    @ViewBuilder private func sections(for tab: AppState.SettingsTab) -> some View {
        switch tab {
        case .overview, .models:
            EmptyView() // handled by their own branches in body
        case .general:
            generalSection; updatesSection; aboutSection
        case .recording:
            meetingsSection; processingSection; summarizationSection; LiveRadarSettingsSection(); MetaMuseSettingsSection(); meetingNoteExportSection
        case .dayMemory:
            screenCaptureSection; retentionSection; exclusionsSection; codingAgentsSection
            AgentKindAccessSection(access: app.agentReadAccess, kind: .screenMemory)
        case .files:
            FileSearchSettingsSection(focusedSettingID: app.focusedSettingID)
            if app.settings.fileSearchEnabled {
                AgentKindAccessSection(access: app.agentReadAccess, kind: .files)
            }
        case .email:
            EmailSettingsSection(email: app.email, focusedSettingID: app.focusedSettingID)
        case .ask:
            askAnywhereSection; selectionActionsSection; windowHandoffSection; askAnswersSection; askSourcesSection
        case .personalContext:
            PersonalContextSettings(personalModel: app.personalModel, access: app.agentReadAccess)
        case .daily:
            dayDigestSection; dreamingSection; routinesSection; dailyNoteExportSection
        case .writing:
            AutocompleteSettingsSections(server: app.cotypingServer, subpage: openSubpage,
                                         open: { subpage = $0 }, changeModel: { sheet = .model(.autocomplete) })
        case .dictation:
            DictationSettingsSections(dictation: app.dictation, subpage: openSubpage,
                                      open: { subpage = $0 }, changeModel: { sheet = .model($0) })
        case .agents:
            agentAccessSection; agentCLISection
        case .devices:
            CompanionSettingsSections()
        case .privacy:
            SettingsPrivacySections(status: status, calendar: app.calendar)
        case .advanced:
            memoryHealthSection; resourceMonitorSection; systemSection
        }
    }

    /// Spec §2.5: the search field filters across ALL tabs — a non-empty
    /// query shows every matching section regardless of the selected tab,
    /// plus a jump row into the Models tab when its keywords match.
    private var searchResults: some View {
        let results = SettingDescriptor.search(settingsQuery, language: app.settings.appLanguage)
        return List(results) { result in
            Button {
                app.settingsTab = result.category
                app.focusedSettingID = result.focusTarget(in: app.settings)
                settingsQuery = ""
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(result.displayTitle)).font(AppFont.scaled(.body).weight(.semibold))
                    Text("\(result.currentValue(in: app.settings, language: app.settings.appLanguage)) · \(app.settings.appLanguage.localized(result.category.displayName))")
                        .font(AppFont.scaled(.callout)).settingsSecondary()
                    if let prerequisite = result.prerequisite(in: app.settings) {
                        Text(LocalizedStringKey(prerequisite)).font(AppFont.scaled(.callout)).settingsSecondary()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .overlay {
            if results.isEmpty { ContentUnavailableView.search(text: settingsQuery) }
        }
        .accessibilityIdentifier("settings.searchResults")
        .accessibilityLabel("Matching settings")
    }

    private var exclusionsSection: some View {
        Section("Capture exclusions") {
            ExclusionRulesEditor(title: "Never capture these apps", value: $app.settings.excludedApps, kind: .applications)
                .settingTarget("settings.excludedApps", selected: app.focusedSettingID)
            ExclusionRulesEditor(title: "Never capture these sites", value: $app.settings.excludedScreenDomains, kind: .domains)
                .settingTarget("settings.excludedScreenDomains", selected: app.focusedSettingID)
            SettingsHelp("Every app and window is tracked, including browsers and private windows. Add apps or sites here to keep them out. Password managers (Passwords, Keychain Access, 1Password, Bitwarden, KeePassXC), focused password fields, and detected credentials are never captured.")
        }
    }

    // MARK: - Sections

    private var memoryHealthSection: some View {
        MemoryHealthSection()
            .settingTarget("settings.memoryHealth", selected: app.focusedSettingID)
    }

    private var resourceMonitorSection: some View {
        ResourceMonitorSection()
            .settingTarget("settings.resourceMonitor", selected: app.focusedSettingID)
    }

    @ViewBuilder private var generalSection: some View {
                Section("General") {
                    LaunchAtLoginToggleRow(state: LaunchAtLoginState.shared)
                        .accessibilityLabel("Launch LokalBot at login")
                        .accessibilityHint("Start automatically so it's ready to catch meetings.")
                        .settingTarget("settings.launchAtLogin", selected: app.focusedSettingID)

                    Toggle(isOn: $app.settings.menuBarOnly) {
                        SettingsLabel("Menu bar only (hide Dock icon)",
                                      help: "Run from the menu bar with a live recording timer. Takes full effect once open windows close.")
                    }
                    .settingTarget("settings.menuBarOnly", selected: app.focusedSettingID)
                        .onChange(of: app.settings.menuBarOnly) { _, menuBarOnly in
                            // The Dock policy reads saved settings.
                            app.settingsStore.flush()
                            DockPolicy.sync()
                            if !menuBarOnly { openWindow(id: "main") }
                        }
                }
                Section("Appearance") {
                    Picker(selection: $app.settings.appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(verbatim: language.pickerLabel(in: app.settings.appLanguage)).tag(language)
                        }
                    } label: {
                        SettingsLabel("App language", help: "Changes the interface immediately. Transcription and notes languages are set separately.")
                    }
                    .accessibilityIdentifier("settings.appLanguage")
                    .settingTarget("settings.appLanguage", selected: app.focusedSettingID)
                    Picker(selection: $app.settings.appTheme) {
                        ForEach(AppTheme.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                    } label: {
                        SettingsLabel("Theme", help: "Use light or dark windows regardless of the system setting, or follow it.")
                    }
                    .pickerStyle(.segmented)
                    .settingTarget("settings.appTheme", selected: app.focusedSettingID)
                    Picker(selection: $app.settings.textSize) {
                        ForEach(AppTextSize.allCases) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                    } label: {
                        SettingsLabel("Text size", help: "Scales text across LokalBot's windows. Agent keeps its own size (⌘+ and ⌘−).")
                    }
                    .pickerStyle(.segmented)
                    .settingTarget("settings.textSize", selected: app.focusedSettingID)
                    Text("Meeting notes, transcripts, and actions will look like this.")
                        .font(.scaled(.body))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
    }

    // MARK: - Ask

    private var askAnywhereSection: some View {
                Section("Ask anywhere") {
                    Toggle(isOn: $app.settings.quickRecallEnabled) {
                        SettingsLabel("Enable the system-wide Ask shortcut",
                                      help: "Press \(app.settings.quickRecallShortcut.displayLabel) in any app to search your work memory or ask a question. LokalBot registers only this shortcut and never reads other keystrokes.")
                    }
                    .accessibilityLabel("Enable the system-wide Ask shortcut")
                    .accessibilityIdentifier("settings.quickRecallEnabled")
                    .settingTarget("settings.quickRecallEnabled", selected: app.focusedSettingID)
                    LabeledContent("Ask shortcut") {
                        ShortcutRecorder(
                            shortcut: $app.settings.quickRecallShortcut,
                            defaultShortcut: .quickRecallDefault,
                            accessibilityIdentifier: "settings.quickRecallShortcut",
                            changeHelp: "Change the Ask shortcut",
                            validate: { candidate in
                                QuickRecallHotKeyController.problem(
                                    for: candidate, dictationShortcut: app.settings.dictationShortcut,
                                    selectionActionsShortcut: app.settings.selectionActionsShortcut,
                                    windowHandoffShortcut: app.settings.windowHandoffShortcut)
                            },
                            onRecordingChanged: { app.setShortcutRecording($0) })
                    }
                    .settingTarget("settings.quickRecallShortcut", selected: app.focusedSettingID)
                }
    }

    private var selectionActionsSection: some View {
                Section("Selection actions") {
                    Toggle(isOn: $app.settings.selectionActionsEnabled) {
                        SettingsLabel("Enable the selection actions shortcut",
                                      help: "Select text in any app and press \(app.settings.selectionActionsShortcut.displayLabel) to rewrite, translate, summarize, or answer it with your Think model. "
                                        + "Actions marked “with my memory” also search your meetings. LokalBot reads the selection only when you press the shortcut, skips excluded apps and password fields, and keeps nothing. "
                                        + "Apps that hide their selection from Accessibility are copied with ⌘C, then your clipboard is restored.")
                    }
                    .accessibilityLabel("Enable the selection actions shortcut")
                    .accessibilityIdentifier("settings.selectionActionsEnabled")
                    .settingTarget("settings.selectionActionsEnabled", selected: app.focusedSettingID)
                    LabeledContent("Selection actions shortcut") {
                        ShortcutRecorder(
                            shortcut: $app.settings.selectionActionsShortcut,
                            defaultShortcut: .selectionActionsDefault,
                            accessibilityIdentifier: "settings.selectionActionsShortcut",
                            changeHelp: "Change the selection actions shortcut",
                            validate: { candidate in
                                QuickRecallHotKeyController.problem(
                                    for: candidate, dictationShortcut: app.settings.dictationShortcut,
                                    askShortcut: app.settings.quickRecallShortcut,
                                    windowHandoffShortcut: app.settings.windowHandoffShortcut)
                            },
                            onRecordingChanged: { app.setShortcutRecording($0) })
                    }
                    .settingTarget("settings.selectionActionsShortcut", selected: app.focusedSettingID)
                }
    }

    private var windowHandoffSection: some View {
                Section("Hand off this window") {
                    Toggle(isOn: $app.settings.windowHandoffEnabled) {
                        SettingsLabel("Enable the Hand off shortcut",
                                      help: "Press the shortcut below in any app to hand the task in its window to Agent Mode, Claude Code, Codex, or the clipboard. LokalBot reads that window's full text and takes a screenshot only when you press it, skips excluded apps, sites, and password fields, and shows you the brief before anything is handed off.")
                    }
                    .settingTarget("settings.windowHandoffEnabled", selected: app.focusedSettingID)
                    LabeledContent("Hand off shortcut") {
                        ShortcutRecorder(
                            shortcut: $app.settings.windowHandoffShortcut,
                            defaultShortcut: .windowHandoffDefault,
                            accessibilityIdentifier: "settings.windowHandoffShortcut",
                            changeHelp: "Change the Hand off shortcut",
                            validate: { candidate in
                                QuickRecallHotKeyController.problem(
                                    for: candidate, dictationShortcut: app.settings.dictationShortcut,
                                    askShortcut: app.settings.quickRecallShortcut,
                                    selectionActionsShortcut: app.settings.selectionActionsShortcut)
                            },
                            onRecordingChanged: { app.setShortcutRecording($0) })
                    }
                    .settingTarget("settings.windowHandoffShortcut", selected: app.focusedSettingID)
                }
    }

    private var askAnswersSection: some View {
        Section("Answers") {
            modelRow(.assistant, title: "Think model", value: ModelSettingsPresentation.assistantName(app.settings),
                     help: "Also writes meeting notes and the overnight review.")
            Toggle(isOn: $app.settings.semanticSearchEnabled) {
                SettingsLabel("Enable search by meaning",
                              help: "The model downloads when semantic search is first used. Meeting text and text captured from your screen are indexed locally.")
            }
            .settingTarget("settings.semanticSearchEnabled", selected: app.focusedSettingID)
        }
    }

    /// Where Ask's answers come from. Each source is set up on its own page,
    /// so this summary is one of the few rows that opens another page.
    private var askSourcesSection: some View {
        Section {
            sourceRow(.recording, value: "On")
                .settingTarget("settings.askSources", selected: app.focusedSettingID)
            sourceRow(.dayMemory, value: app.settings.effectiveScreenContextCaptureMode.capturesText ? "On" : "Off")
            sourceRow(.files, value: app.settings.fileSearchEnabled ? "On" : "Off")
            sourceRow(.email, value: app.email.accounts.isEmpty ? "Not connected" : "On")
            sourceRow(.personalContext, value: app.settings.askMemoryEnabled ? "On" : "Off")
        } header: {
            Text("What Ask can search")
        }
    }

    private func sourceRow(_ page: AppState.SettingsTab, value: String) -> some View {
        Button { app.selectSettingsTab(page) } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(value)).settingsSecondary()
                    Image(systemName: "chevron.right").font(.scaled(.caption)).settingsSecondary()
                }
            } label: {
                Label { Text(LocalizedStringKey(page.displayName)) } icon: {
                    Image(systemName: page.icon).foregroundStyle(Brand.teal)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.askSource.\(page.rawValue)")
    }

    /// A model a page uses, with its picker opening over this page.
    private func modelRow(_ role: ModelPickerRole, title: String, value: String, help: String? = nil) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                Text(value)
                    .settingsSecondary()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…") { sheet = .model(role) }
                    .accessibilityIdentifier("settings.model.change.\(role.rawValue)")
            }
        } label: {
            SettingsLabel(title, help: help)
        }
    }

    @ViewBuilder private var meetingsSection: some View {
                Section("Meetings") {
                    Picker(selection: $app.settings.autoRecordMode) {
                        ForEach(AppSettings.AutoRecordMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    } label: {
                        SettingsLabel("When a meeting is detected",
                                      help: "Only record when everyone has been informed and any consent the meeting or location requires is in place.")
                    }
                    .settingTarget("settings.autoRecordMode", selected: app.focusedSettingID)
                    LabeledContent {
                        Text(Set(MeetingDetector.knownApps.values).sorted().joined(separator: ", ")
                             + ", and Google Meet in a browser")
                            .settingsSecondary()
                    } label: {
                        SettingsLabel("Detected apps",
                                      help: "Google Meet is detected only with its interface in English. Other browser calls, such as Jitsi, Whereby, or Teams on the web, are not detected, and recording one yourself saves only your microphone.")
                    }
                    LabeledContent("Wait before stopping") {
                        Stepper(value: $app.settings.stopDebounceSeconds,
                                in: AppSettings.minimumStopDebounceSeconds...AppSettings.maximumStopDebounceSeconds,
                                step: 5) {
                            Text("\(Int(app.settings.stopDebounceSeconds)) s after audio stops")
                                .settingsSecondary()
                        }
                    }
                    .settingTarget("settings.stopDebounceSeconds", selected: app.focusedSettingID)
                }
                Section("Calendar") {
                    Toggle(isOn: Binding(
                        get: { app.settings.calendarDetectionEnabled },
                        set: { enabled in app.changeSettings { $0.calendarDetectionEnabled = enabled } })) {
                        SettingsLabel("Use calendar to improve detection",
                                      help: "Reads your Mac Calendar to confirm meetings and suggest attendee names for speakers. Attendee emails stay in local meeting metadata.")
                    }
                    .settingTarget("settings.calendarDetectionEnabled", selected: app.focusedSettingID)
                    if app.settings.calendarDetectionEnabled {
                        Toggle("Use calendar titles for recordings", isOn: $app.settings.useCalendarTitles)
                    .settingTarget("settings.useCalendarTitles", selected: app.focusedSettingID)
                        Toggle(isOn: $app.settings.requireCalendarForBrowser) {
                            SettingsLabel("Require a calendar match for browser auto-recording",
                                          help: "Only auto-record a browser tab while a scheduled event with a meeting link is in progress.")
                        }
                    .settingTarget("settings.requireCalendarForBrowser", selected: app.focusedSettingID)
                        Toggle(isOn: $app.settings.useCalendarAgenda) {
                            SettingsLabel("Use invitation agendas",
                                          help: "Off by default. Saves the invitation's agenda (without joining details, links, phone numbers, or addresses) with calendar-matched recordings, and uses it for meeting notes and meeting preparation. Agendas already saved stay with their meeting until it is deleted.")
                        }
                        .settingTarget("settings.useCalendarAgenda", selected: app.focusedSettingID)
                    }
                }
    }

    @ViewBuilder private var processingSection: some View {
                Section("Processing") {
                    Toggle("Transcribe automatically after each meeting", isOn: $app.settings.autoTranscribe)
                    .settingTarget("settings.autoTranscribe", selected: app.focusedSettingID)
                    Toggle("Summarize automatically after transcription", isOn: $app.settings.autoSummarize)
                    .settingTarget("settings.autoSummarize", selected: app.focusedSettingID)
                    Toggle(isOn: $app.settings.handOffActionsAfterSummary) {
                        SettingsLabel("Hand off my actions to Agent Mode after each summary",
                                      help: "Each open action that's yours gets its own Agent Mode task, with the meeting's notes attached.")
                    }
                    .settingTarget("settings.handOffActionsAfterSummary", selected: app.focusedSettingID)
                    Toggle(isOn: $app.settings.startHandoffsAutomatically) {
                        SettingsLabel("Start handoffs automatically",
                                      help: "Handed-off tasks start right away instead of waiting for Send. Up to four agents work at once, and Agent Mode's approval setting decides what they can do without asking.")
                    }
                    .settingTarget("settings.startHandoffsAutomatically", selected: app.focusedSettingID)
                    modelRow(.transcription, title: "Transcribe model", value: app.settings.transcriptionModelDisplayName,
                             help: "Also used by Dictation.")
                    LabeledContent {
                        Button("Edit…") { sheet = .transcriptionOptions }
                            .accessibilityIdentifier("settings.transcriptionOptions.edit")
                    } label: {
                        SettingsLabel("Language and vocabulary",
                                      help: app.settings.transcriptionLanguage.displayName)
                    }
                    Toggle(isOn: $app.settings.turnByTurnLiveTextEnabled) {
                        SettingsLabel("Turn-by-turn live text",
                                      help: "While the live transcript preview runs, cuts the microphone and call audio at pauses and transcribes each turn with your Transcribe model, so its text appears about a second after the speaker stops. Live Radar then reads after each turn. Without it, the preview transcribes a few seconds at a time.")
                    }
                    .accessibilityIdentifier("settings.turnByTurnLiveText")
                    .settingTarget("settings.turnByTurnLiveTextEnabled", selected: app.focusedSettingID)
                    modelRow(.assistant, title: "Think model", value: ModelSettingsPresentation.assistantName(app.settings),
                             help: "Writes the notes. Also used by Ask and the overnight review.")
                }
                Section("Speakers and echo") {
                    Toggle(isOn: $app.settings.echoCancellation) {
                        SettingsLabel("Remove the other side from your microphone track",
                                      help: "Use on speakers, where the other side reaches your microphone and would be transcribed twice. Also cleans meetings already recorded.")
                    }
                    .settingTarget("settings.echoCancellation", selected: app.focusedSettingID)
                    SettingsDetails("Microphone mode requirement",
                                    "Set LokalBot's microphone mode to Standard (Control Center → microphone icon → LokalBot's row). macOS Voice Isolation removes the echo this feature looks for. The meeting app can stay on Voice Isolation; the mode is set per app, not per microphone. Headphones need no echo removal.")
                }
    }

    @ViewBuilder private var summarizationSection: some View {
                Section("Summarization") {
                    Picker(selection: $app.settings.noteTemplate) {
                        ForEach(NoteTemplate.allCases) { template in
                            Text("\(template.displayName)").tag(template)
                        }
                    } label: {
                        SettingsLabel("Notes template", help: app.settings.noteTemplate.description)
                    }
                    .settingTarget("settings.noteTemplate", selected: app.focusedSettingID)
                    Picker("Notes language", selection: $app.settings.summaryLanguage) {
                        Text("Match transcript (auto)").tag(SummaryLanguage.matchTranscript)
                        Divider()
                        ForEach(SummaryLanguage.presets, id: \.rawValue) { lang in
                            Text(LocalizedStringKey(lang.displayName)).tag(lang)
                        }
                    }
                    .settingTarget("settings.summaryLanguage", selected: app.focusedSettingID)
                    Toggle(isOn: $app.settings.meetingNotesUseCalendarContext) {
                        SettingsLabel("Give notes the calendar title and invited names",
                                      help: "Helps spell names and relate the discussion to the meeting. Names only; email addresses are never included. The transcript stays the only evidence for decisions and actions.")
                    }
                    .settingTarget("settings.meetingNotesUseCalendarContext", selected: app.focusedSettingID)
                    Toggle(isOn: $app.settings.meetingNotesUseScreenTitles) {
                        SettingsLabel("Give notes the titles of documents on screen",
                                      help: "Adds titles of documents and pages captured during the call, never their captured text. Requires screen context in Screen & Activity.")
                    }
                    .settingTarget("settings.meetingNotesUseScreenTitles", selected: app.focusedSettingID)
                }
                Section("Speaker names") {
                    Toggle("Separate voices by speaker",
                           isOn: $app.settings.multiSpeakerDiarization)
                        .accessibilityLabel("Separate voices by speaker")
                        .accessibilityIdentifier("settings.multiSpeakerDiarization")
                        .settingTarget("settings.multiSpeakerDiarization", selected: app.focusedSettingID)
                    Picker(selection: $app.settings.diarizationModel) {
                        ForEach(DiarizationModel.allCases) { model in
                            Text(LocalizedStringKey(model.displayName)).tag(model)
                        }
                    } label: {
                        SettingsLabel("Speaker model", help: app.settings.diarizationModel.description)
                    }
                    .disabled(!app.settings.multiSpeakerDiarization)
                    .accessibilityLabel("Speaker model")
                    .accessibilityIdentifier("settings.diarizationModel")
                    .settingTarget("settings.diarizationModel", selected: app.focusedSettingID)
                    Toggle(isOn: $app.settings.microphoneIsUser) {
                        SettingsLabel("My microphone is me",
                                      help: "Treats speech from this Mac's microphone as yours, so your commitments lead each meeting's action items. Turn off when several people share this microphone, such as in a meeting room. Summarize a meeting again to update its action items.")
                    }
                        .accessibilityLabel("My microphone is me")
                        .accessibilityIdentifier("settings.microphoneIsUser")
                        .settingTarget("settings.microphoneIsUser", selected: app.focusedSettingID)
                    SpeakerIdentitySettingsControls()
                        .settingTarget("settings.rememberedPeople", selected: app.focusedSettingID)
                }
    }

    @ViewBuilder private var meetingNoteExportSection: some View {
                Section("Meeting note export") {
                    Toggle(isOn: Binding(
                        get: { app.settings.meetingNoteExportEnabled },
                        set: { enabled in
                            app.settings.meetingNoteExportEnabled = enabled
                            if enabled && app.settings.meetingNoteExportFolder.isEmpty {
                                chooseMeetingNoteExportFolder()
                            }
                        })) {
                        SettingsLabel("Export a note for each meeting",
                                      help: "Writes one unencrypted Markdown note per meeting, including meetings already recorded, to a folder you choose, such as an Obsidian vault. Each note has the summary, action items as you corrected them, and the people and tracked projects involved. A note you edit, move, or delete is yours: LokalBot leaves it alone.")
                    }
                    .settingTarget("settings.meetingNoteExportEnabled", selected: app.focusedSettingID)
                    if app.settings.meetingNoteExportEnabled {
                        Picker("Format", selection: $app.settings.meetingNoteExportFormat) {
                            ForEach(AppSettings.DailyMemoryExportFormat.allCases) { format in
                                Text(LocalizedStringKey(format.rawValue)).tag(format)
                            }
                        }
                        .settingTarget("settings.meetingNoteExportFormat", selected: app.focusedSettingID)
                        Toggle("Include the transcript", isOn: $app.settings.meetingNoteExportIncludesTranscript)
                            .settingTarget("settings.meetingNoteExportIncludesTranscript", selected: app.focusedSettingID)
                        LabeledContent("Folder") {
                            Button(app.settings.meetingNoteExportFolder.isEmpty
                                   ? "Choose…"
                                   : URL(fileURLWithPath: app.settings.meetingNoteExportFolder).lastPathComponent) {
                                chooseMeetingNoteExportFolder()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Brand.teal)
                        }
                    }
                }
    }

    // MARK: - Screen & Activity

    @ViewBuilder private var screenCaptureSection: some View {
                Section("Activity") {
                    Toggle(isOn: Binding(
                        get: { app.settings.trackingEnabled },
                        set: { enabled in app.changeSettings { $0.trackingEnabled = enabled } })) {
                        SettingsLabel("Track app & window activity",
                                      help: "Records which app and window you're using for the Timeline and day digest.")
                    }
                    .settingTarget("settings.trackingEnabled", selected: app.focusedSettingID)
                    Picker(selection: Binding(
                        get: { app.settings.effectiveScreenContextCaptureMode },
                        set: { mode in app.changeSettings { $0.screenContextCaptureMode = mode } })) {
                        ForEach(AppSettings.ScreenContextCaptureMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    } label: {
                        SettingsLabel("Screen context",
                                      help: app.settings.effectiveScreenContextCaptureMode.detail)
                    }
                    .settingTarget("settings.effectiveScreenContextCaptureMode", selected: app.focusedSettingID)
                    if app.settings.effectiveScreenContextCaptureMode.capturesText {
                        Slider(value: Binding(
                            get: { app.settings.screenshotIntervalMinutes },
                            set: { app.settings.screenshotIntervalMinutes = $0 }),
                            in: 1...15, step: 1) {
                            Text("Idle fallback: at least every \(Int(app.settings.screenshotIntervalMinutes)) min")
                        }
                        .settingTarget("settings.screenshotIntervalMinutes", selected: app.focusedSettingID)
                        Toggle(isOn: $app.settings.suggestActionCompletion) {
                            SettingsLabel("Suggest actions that look done",
                                          help: "When later captured text shows an action's words with a completion such as “message sent” or “merged”, the action offers Mark Done. Nothing changes until you confirm.")
                        }
                        .settingTarget("settings.suggestActionCompletion", selected: app.focusedSettingID)
                        if app.settings.effectiveScreenContextCaptureMode.capturesPixels {
                            Toggle(isOn: $app.settings.meetingVisualContextEnabled) {
                                SettingsLabel("Capture low-frequency visual context during meetings",
                                              help: "Off by default. Captures the focused display at most once a minute on meaningful changes and links each frame to the meeting.")
                            }
                    .settingTarget("settings.meetingVisualContextEnabled", selected: app.focusedSettingID)
                            if app.settings.semanticSearchEnabled {
                                SettingsHelp("Search by meaning also matches what captured screens show. The first "
                                             + "such search downloads EmbeddingGemma 2's image model (555 MB); picture "
                                             + "vectors are deleted with the pixels.")
                            }
                        }
                        SettingsDetails("How screen context is captured",
                                        "Captures context after app or window changes, clicks, typing pauses, settled "
                                            + "scrolls, or a clipboard change, without storing raw keys, "
                                            + "pointer positions, or clipboard contents. Accessible text is preferred; "
                                            + "local OCR fills gaps. Private windows, excluded domains, secure fields, "
                                            + "and detected credentials are never captured. Visuals are encrypted "
                                            + "with a key kept in your Mac's Keychain; extracted text follows the same retention "
                                            + "(below). Saved moments keep their encrypted frame and text "
                                            + "until you unsave or delete them. Excluded apps log as “Private”.")
                    }
                }
    }

    private var retentionSection: some View {
        Section("Screen memory retention") {
            RetentionSettingsControls()
        }
    }

    private var codingAgentsSection: some View {
        Section("Coding agent sessions") {
            CodingAgentEvidenceSettings()
        }
    }

    // MARK: - Daily Review

    private var dayDigestSection: some View {
                Section("Day digest") {
                    Toggle(isOn: $app.settings.dayDigestAutoEnabled) {
                        SettingsLabel("Generate the day digest automatically",
                                      help: "Writes the Timeline digest to your local journal at the chosen time, then finalizes yesterday after midnight so late activity is included.")
                    }
                    .settingTarget("settings.dayDigestAutoEnabled", selected: app.focusedSettingID)
                    if app.settings.dayDigestAutoEnabled {
                        Stepper(
                            "Generate at \(HourLabel.format(app.settings.dayDigestHour))",
                            value: $app.settings.dayDigestHour,
                            in: 0...23)
                    }
                    digestInstructionsField.settingTarget("settings.dayDigestCustomPrompt", selected: app.focusedSettingID)
                }
    }

    private var dailyNoteExportSection: some View {
                Section("Daily note export") {
                    Toggle(isOn: Binding(
                        get: { app.settings.dailyMemoryExportEnabled },
                        set: { enabled in
                            app.settings.dailyMemoryExportEnabled = enabled
                            if enabled && app.settings.dailyMemoryExportFolder.isEmpty {
                                chooseDailyExportFolder()
                            }
                        })) {
                        SettingsLabel("Export a daily memory note",
                                      help: "Writes one unencrypted Markdown file per day with the digest, meeting links, app time, and saved moments. A day missed while your Mac was asleep is written later. Existing non-LokalBot content is never overwritten.")
                    }
                    .settingTarget("settings.dailyMemoryExportEnabled", selected: app.focusedSettingID)
                    if app.settings.dailyMemoryExportEnabled {
                        Picker("Format", selection: $app.settings.dailyMemoryExportFormat) {
                            ForEach(AppSettings.DailyMemoryExportFormat.allCases) { format in
                                Text(LocalizedStringKey(format.rawValue)).tag(format)
                            }
                        }
                    .settingTarget("settings.dailyMemoryExportFormat", selected: app.focusedSettingID)
                        LabeledContent("Folder") {
                            Button(app.settings.dailyMemoryExportFolder.isEmpty
                                   ? "Choose…"
                                   : URL(fileURLWithPath: app.settings.dailyMemoryExportFolder).lastPathComponent) {
                                chooseDailyExportFolder()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Brand.teal)
                        }
                        Stepper(
                            "Refresh at \(HourLabel.format(app.settings.dailyMemoryExportHour))",
                            value: $app.settings.dailyMemoryExportHour,
                            in: 0...23)
                    }
                }
    }

    private var digestInstructionsField: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsLabel("Digest instructions (optional)",
                          help: "Shapes both scheduled and manual digests. The first "
                            + "\(PromptTemplates.dayDigestCustomPromptMaxCharacters) characters are used.")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $app.settings.dayDigestCustomPrompt)
                    .font(AppFont.scaled(.body))
                    .multilineTextAlignment(.leading)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .accessibilityLabel("Digest instructions")
                    .accessibilityIdentifier("settings.digestInstructions")

                if app.settings.dayDigestCustomPrompt.isEmpty {
                    Text("Example: Emphasize decisions, blockers, and next steps.")
                        .font(AppFont.scaled(.body))
                        .settingsSecondary()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 72, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.92))
            )
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1.2)
            }
            // The digest uses only the first characters of the cleaned-up
            // text; say so instead of dropping the rest silently.
            let used = PromptContextSanitizer.sanitize(app.settings.dayDigestCustomPrompt).count
            let limit = PromptTemplates.dayDigestCustomPromptMaxCharacters
            if used > limit {
                Text("\(used) of \(limit) characters. Only the first \(limit) are used; shorten the rest.")
                    .workspaceTextRole(.warning)
                    .accessibilityIdentifier("settings.digestInstructions.count")
            } else if used > 0 {
                Text("\(used) of \(limit) characters")
                    .font(AppFont.scaled(.caption))
                    .settingsSecondary()
                    .accessibilityIdentifier("settings.digestInstructions.count")
            }
        }
    }

    private var routinesSection: some View {
            Section("Routines") {
                Toggle(isOn: Binding(
                    get: { app.settings.memoryRoutinesEnabled },
                    set: { enabled in
                        app.settings.memoryRoutinesEnabled = enabled
                        if enabled && app.settings.memoryRoutineFolder.isEmpty {
                            chooseMemoryRoutineFolder()
                        }
                    })) {
                    SettingsLabel("Enable safe local routines",
                                  help: "Routines write Markdown into a folder you choose. They can't run scripts, contact services, send messages, or change meetings.")
                }
                    .settingTarget("settings.memoryRoutinesEnabled", selected: app.focusedSettingID)
                if app.settings.memoryRoutinesEnabled {
                    LabeledContent("Output folder") {
                        Button(app.settings.memoryRoutineFolder.isEmpty
                               ? "Choose…"
                               : URL(fileURLWithPath: app.settings.memoryRoutineFolder).lastPathComponent) {
                            chooseMemoryRoutineFolder()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.teal)
                    }
                    Stepper(
                        "Daily time: \(HourLabel.format(app.settings.memoryRoutineHour))",
                        value: $app.settings.memoryRoutineHour,
                        in: 0...23)
                    Picker("Weekly log day", selection: $app.settings.memoryRoutineWeekday) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(weekdayName(weekday)).tag(weekday)
                        }
                    }
                    .settingTarget("settings.memoryRoutineWeekday", selected: app.focusedSettingID)
                    ForEach(AppSettings.MemoryRoutineKind.allCases) { kind in
                        Toggle(isOn: Binding(
                            get: { app.settings.enabledMemoryRoutines.contains(kind) },
                            set: { enabled in setRoutine(kind, enabled: enabled) })) {
                            SettingsLabel(kind.displayName, help: kind.detail)
                        }
                    }
                    HStack {
                        Menu("Run now") {
                            ForEach(AppSettings.MemoryRoutineKind.allCases.filter { !$0.isEventDriven }) { kind in
                                Button(kind.displayName) { app.memoryRoutines.runNow(kind) }
                                    .disabled(!app.settings.enabledMemoryRoutines.contains(kind))
                            }
                        }
                        if app.memoryRoutines.isRunning, let kind = app.memoryRoutines.currentKind {
                            LoadingStateLabel(kind.displayName, font: .scaled(.caption))
                        }
                    }
                    if !app.memoryRoutines.recentRuns.isEmpty {
                        DisclosureGroup("Recent run history") {
                            ForEach(app.memoryRoutines.recentRuns.prefix(8)) { run in
                                LabeledContent(run.kind.displayName) {
                                    Text(run.status.capitalized + " · "
                                         + run.startedAt.formatted(.relative(presentation: .named)))
                                        .foregroundStyle(run.status == "failed" ? .orange : .secondary)
                                }
                            }
                        }
                    }
                }
                SettingsDetails("How routines run",
                                "Each routine has a fixed local read scope and writes Markdown only inside the chosen folder. Missed daily or weekly runs catch up after wake, each run stops after 30 seconds, and every attempt is recorded in the local database.")
            }
    }

    private var dreamingSection: some View {
            Section("Overnight review") {
                Toggle(isOn: Binding(
                    get: { app.settings.dreamingEnabled },
                    set: { app.setDreamingEnabled($0) })) {
                    SettingsLabel("Review the day overnight",
                                  help: "After the chosen time, once your Mac is on power and LokalBot isn't recording or processing, LokalBot turns the previous day into a morning retrospective on Today. It uses your Think model; if that model is remote, the compiled evidence is sent to it.")
                }
                    .settingTarget("settings.dreamingEnabled", selected: app.focusedSettingID)
                if app.settings.dreamingEnabled {
                    Stepper(
                        "Review after \(HourLabel.format(app.settings.dreamingHour))",
                        value: $app.settings.dreamingHour,
                        in: 0...23)
                    HStack(spacing: 8) {
                        Button("Review now") { app.dreamNow() }
                            .disabled(app.dreaming.isDreaming || !app.libraryReady)
                        if app.dreaming.isDreaming {
                            LoadingStateLabel("Reviewing…", font: .scaled(.caption))
                        } else if let last = app.dreaming.lastDreamedAt {
                            SettingsHelp("Last reviewed " + last.formatted(.relative(presentation: .named)))
                        }
                    }
                    if let error = app.dreaming.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(AppFont.scaled(.body)).foregroundStyle(Brand.error)
                    }
                }
                if let memory = app.dreamMemory,
                   !memory.activeProjects.isEmpty || !memory.workGoals.isEmpty {
                    DisclosureGroup("Projects and goals") {
                        SettingsHelp("Pin items to keep them during automatic memory cleanup.")
                        if !memory.activeProjects.isEmpty {
                            Text("Active projects")
                                .font(.scaled(.caption).weight(.semibold))
                                .settingsSecondary()
                            ForEach(memory.activeProjects, id: \.name) { project in
                                dreamMemoryPinRow(
                                    title: project.name,
                                    detail: project.status,
                                    isPinned: project.pinned,
                                    entry: .project(name: project.name))
                            }
                        }
                        if !memory.workGoals.isEmpty {
                            Text("Current goals")
                                .font(.scaled(.caption).weight(.semibold))
                                .settingsSecondary()
                            ForEach(memory.workGoals, id: \.text) { goal in
                                dreamMemoryPinRow(
                                    title: goal.text,
                                    detail: goal.horizon,
                                    isPinned: goal.pinned,
                                    entry: .goal(text: goal.text))
                            }
                        }
                    }
                }
                if app.dreamMemory != nil || app.latestDreamReport != nil {
                    Button("Clear work memory…", role: .destructive) { confirmingDreamMemoryClear = true }
                        .disabled(!app.libraryReady)
                        .confirmationDialog("Clear work memory?", isPresented: $confirmingDreamMemoryClear) {
                            Button("Clear Work Memory", role: .destructive) { app.clearDreamMemory() }
                        } message: {
                            Text("Deletes every overnight review and the remembered projects, goals, and patterns, including pinned ones. Reviews start again from today.")
                        }
                }
                SettingsDetails("What the review uses",
                                "It compiles meetings, outcomes, the day digest, and time totals, and keeps an evolving memory of active projects and goals. "
                                    + "Nights the Mac slept through catch up at the next launch. Evidence and generated files stay in the local library. If no model is reachable, a plain evidence summary is written instead. "
                                    + "Reviews and memory are kept after screen text expires; deleting or correcting a meeting or capture they used removes what depended on it, and Clear work memory removes all of it.")
            }
    }

    private func dreamMemoryPinRow(
        title: String,
        detail: String,
        isPinned: Bool,
        entry: DreamMemoryEntry
    ) -> some View {
        Toggle(isOn: Binding(
            get: { isPinned },
            set: { app.setDreamMemoryPinned($0, for: entry) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    SettingsHelp(detail)
                }
            }
            .disabled(app.dreaming.isDreaming)
    }

    // MARK: - External Agents

    private var agentAccessSection: some View {
        Section("External agents") {
            AgentReadAccessRows(access: app.agentReadAccess, focusedSettingID: app.focusedSettingID)
            SettingsControlAccessToggleRow(manager: app.settingsControl)
                .settingTarget("settings.settingsControlAccess", selected: app.focusedSettingID)
            AgentSettingsChangesList(changes: app.agentSettingsChanges)
        }
    }

    @ViewBuilder private var updatesSection: some View {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.automaticallyChecksForUpdates = $0 }))
                    .settingTarget("settings.updates", selected: app.focusedSettingID)
                    LabeledContent("Current version") {
                        Text(AppUpdateManager.currentVersionString).settingsSecondary()
                    }
                    Button("Check for Updates…") {
                        AppUpdateManager.shared.checkForUpdates()
                    }
                    .disabled(!updates.isStarted)
                    SettingsHelp(updates.isStarted
                         ? "Updates are signed and delivered via Sparkle. Only the update feed and the chosen download are fetched."
                         : Self.inactiveUpdaterNote)
                }
    }

    /// The repository opens in the default browser; LokalBot itself sends nothing.
    private var aboutSection: some View {
        Section("About") {
            LabeledContent {
                Button("Star on GitHub") { app.githubStar.openRepository() }
                    .accessibilityIdentifier("settings.githubStar")
            } label: {
                SettingsLabel("Open source",
                              help: "LokalBot is free and built by one person. A GitHub star helps others find it.")
            }
        }
    }

    @ViewBuilder private var systemSection: some View {
                Section("System") {
                    LabeledContent("This Mac") {
                        Text(DeviceInfo.snapshot().summaryLine)
                            .settingsSecondary()
                            .multilineTextAlignment(.trailing)
                    }
                    if power.isLowPower {
                        Label("Low Power Mode is on — summaries may run slower.", systemImage: "bolt.slash")
                            .font(.scaled(.callout)).settingsSecondary()
                    } else if power.isOnBattery {
                        Label("Running on battery.", systemImage: "battery.75")
                            .font(.scaled(.callout)).settingsSecondary()
                    }
                    if metrics.recent.isEmpty {
                        LabeledContent("Recent generations") {
                            Text("None yet").settingsSecondary()
                        }
                    } else {
                        ForEach(Array(metrics.recent.reversed().prefix(5))) { metric in
                            LabeledContent(metric.label) {
                                Text(String(format: "%.1fs · ~%d tok · %.0f tok/s",
                                            metric.durationSec, metric.approxTokens, metric.tokensPerSec))
                                    .font(AppFont.scaled(.callout)).settingsSecondary()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Export Diagnostics…") { exportDiagnostics() }
                                .disabled(exportingDiagnostics)
                                .accessibilityIdentifier("settings.exportDiagnostics")
                            Button("Run Health Check Now") {
                                if let url = app.runHealthCheckNow(notify: false) { NSWorkspace.shared.open(url) }
                            }
                            .accessibilityIdentifier("settings.runHealthCheck")
                        }
                        SettingsHelp("Diagnostics include logs, health reports, settings without secrets, and library counts. Never meeting audio, transcripts, notes, or screenshots.")
                    }
                    .settingTarget("settings.exportDiagnostics", selected: app.focusedSettingID)
                }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "LokalBot Diagnostics \(DreamDay.key(for: Date())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Copying and zipping up to 48 MB of logs takes seconds. On the main
        // thread the whole app stood still for them, a recording's timer
        // included.
        let sources = app.diagnosticsSources()
        exportingDiagnostics = true
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try DiagnosticsExporter.export(sources, to: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            exportingDiagnostics = false
            if let failure {
                app.lastError = failure
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    @ViewBuilder private var agentCLISection: some View {
                Section("Agent CLI") {
                    let installer = LokalBotCLIInstaller.bundled
                    if installer.bundledBinary == nil {
                        SettingsHelp("The command-line helper is not included in this build. Install a current LokalBot release to use Agent CLI access.")
                    } else {
                        LabeledContent("Status") {
                            if installer.isInstalled {
                                MemoryHealthStatus(value: "Installed", tone: .good)
                            } else if !installer.isBundleLocationStable {
                                MemoryHealthStatus(value: "Move LokalBot.app to /Applications first", tone: .attention)
                            } else {
                                MemoryHealthStatus(value: "Not installed", tone: .idle)
                            }
                        }
                        .settingTarget("settings.agentCLI", selected: app.focusedSettingID)
                        HStack {
                            Button(LocalizedStringKey(installer.isInstalled ? "Reinstall…" : "Install for your coding agent…")) {
                                cliMessage = nil
                                do {
                                    try installer.install()
                                    cliMessage = "Installed at \(installer.binLink.path(percentEncoded: false))."
                                } catch {
                                    cliMessage = "Install failed: \(error.localizedDescription)"
                                }
                            }
                            .disabled(!installer.isBundleLocationStable)
                            if installer.isInstalled {
                                Button("Uninstall", role: .destructive) {
                                    cliMessage = nil
                                    do {
                                        try installer.uninstall()
                                        cliMessage = "Removed lokalbot-cli symlinks."
                                    } catch {
                                        cliMessage = "Uninstall failed: \(error.localizedDescription)"
                                    }
                                }
                            }
                            if !installer.localBinOnPath {
                                Button("Add ~/.local/bin to PATH") {
                                    cliMessage = nil
                                    do {
                                        try installer.addLocalBinToPath()
                                        cliMessage = "Appended to ~/.zshrc — open a new terminal."
                                    } catch {
                                        cliMessage = error.localizedDescription
                                    }
                                }
                            }
                        }
                        if let cliMessage {
                            SettingsHelp(cliMessage)
                        }
                        SettingsHelp("Symlinks the bundled CLI at ~/.local/bin/lokalbot-cli and the skill into ~/.agents/skills and ~/.claude/skills. Library access is read-only; changing settings needs its own switch above.")
                    }
                }
    }

    /// Release builds explain the state; only dev builds point at release setup.
    private static var inactiveUpdaterNote: String {
        #if LOKALBOT_DEV
        "Updater inactive — set the appcast feed URL and Sparkle public key before shipping (see RELEASING.md)."
        #else
        "Automatic updates are unavailable in this build."
        #endif
    }

    private func chooseDailyExportFolder() {
        let panel = NSOpenPanel()
        panel.title = app.settings.appLanguage.localized("Choose daily memory export folder")
        panel.prompt = app.settings.appLanguage.localized("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !app.settings.dailyMemoryExportFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: app.settings.dailyMemoryExportFolder)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                if app.settings.dailyMemoryExportFolder.isEmpty {
                    app.settings.dailyMemoryExportEnabled = false
                }
                return
            }
            app.settings.dailyMemoryExportFolder = url.path
        }
    }

    private func chooseMeetingNoteExportFolder() {
        let panel = NSOpenPanel()
        panel.title = app.settings.appLanguage.localized("Choose meeting note export folder")
        panel.prompt = app.settings.appLanguage.localized("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !app.settings.meetingNoteExportFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: app.settings.meetingNoteExportFolder)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                if app.settings.meetingNoteExportFolder.isEmpty {
                    app.settings.meetingNoteExportEnabled = false
                }
                return
            }
            app.settings.meetingNoteExportFolder = url.path
        }
    }

    private func chooseMemoryRoutineFolder() {
        let panel = NSOpenPanel()
        panel.title = app.settings.appLanguage.localized("Choose routine output folder")
        panel.prompt = app.settings.appLanguage.localized("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !app.settings.memoryRoutineFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: app.settings.memoryRoutineFolder)
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                if app.settings.memoryRoutineFolder.isEmpty {
                    app.settings.memoryRoutinesEnabled = false
                }
                return
            }
            app.settings.memoryRoutineFolder = url.path
        }
    }

    private func setRoutine(_ kind: AppSettings.MemoryRoutineKind, enabled: Bool) {
        var values = app.settings.enabledMemoryRoutines
        if enabled {
            if !values.contains(kind) { values.append(kind) }
        } else {
            values.removeAll { $0 == kind }
        }
        app.settings.enabledMemoryRoutines = values
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "Friday" }
        return symbols[weekday - 1]
    }

}

/// Binds the cached registration, never `SMAppService` itself: SwiftUI re-reads
/// a toggle's binding on every update while it is visible.
private struct LaunchAtLoginToggleRow: View {
    @ObservedObject var state: LaunchAtLoginState

    var body: some View {
        Toggle(isOn: Binding(
            get: { state.isEnabled },
            set: { state.setEnabled($0) })) {
            SettingsLabel("Launch LokalBot at login",
                          help: "Start automatically so it's ready to catch meetings.")
        }
        .onAppear { state.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refresh()
        }
    }
}

private struct SettingsControlAccessToggleRow: View {
    @ObservedObject var manager: SettingsControlAccessManager

    var body: some View {
        Toggle(isOn: Binding(
            get: { manager.isEnabled },
            set: { manager.setEnabled($0) })) {
            SettingsLabel("Allow external agents to change LokalBot settings",
                          help: "Lets lokalbot-cli read and change your preferences, show you a setting, and start LokalBot in the background. Turning on capture, a data source, or sharing still needs you here. Separate from the other agent access toggles. Off by default.")
        }
    }
}

/// Settings an agent changed from the terminal, newest first, with Undo while
/// the setting still holds the agent's value.
private struct AgentSettingsChangesList: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var changes: AgentSettingsChanges

    var body: some View {
        Group {
            if !changes.recent.isEmpty {
                DisclosureGroup {
                    ForEach(changes.recent.prefix(10)) { entry in
                        LabeledContent {
                            Button("Undo") {
                                do {
                                    try changes.undo(entry, in: app)
                                } catch {
                                    app.lastError = error.localizedDescription
                                }
                            }
                            .disabled(!changes.canUndo(entry, in: app.settings))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: summary(entry))
                                Text(verbatim: "\(entry.caller) · \(entry.time.formatted(date: .abbreviated, time: .shortened))")
                                    .settingsSecondary()
                            }
                        }
                    }
                } label: {
                    SettingsLabel("Recent changes by agents",
                                  help: "Settings changed from the terminal. Undo restores the earlier value while the setting still holds the agent's.")
                }
            }
        }
    }

    private func summary(_ entry: AgentSettingsChanges.Entry) -> String {
        switch entry.key {
        case "setup.access": return "Agent setup allowed: \(entry.value?.stringValue ?? "settings")"
        case "models.preset": return "Model preset: \(entry.value?.stringValue ?? "changed")"
        case "launchAtLogin": return "Launch at login: \(entry.value == .bool(true) ? "on" : "off")"
        default: break
        }
        if let secret = AppSecret(rawValue: String(entry.key.dropFirst("secret.".count))), entry.key.hasPrefix("secret.") {
            return "\(secret.title): \(entry.value?.stringValue ?? "changed")"
        }
        guard let spec = SettingRegistry.spec(for: entry.key) else { return entry.key }
        func shown(_ value: JSONValue?) -> String {
            guard let value else { return "default" }
            let presented = spec.presented(value)
            let text: String
            switch presented {
            case .string(let string): text = string.isEmpty ? "empty" : string
            case .bool(let flag): text = flag ? "on" : "off"
            case .number(let number): text = number == number.rounded() ? String(Int(number)) : String(number)
            default: text = "changed"
            }
            return text.count > 40 ? String(text.prefix(39)) + "…" : text
        }
        return "\(spec.title): \(shown(entry.previous)) → \(shown(entry.value))"
    }
}

/// The one switch for reading LokalBot data, and a box for each kind under
/// it (`AgentReadAccess`). Observes the coordinator, which forwards every
/// per-kind manager's changes, so grants from agent setup show at once.
private struct AgentReadAccessRows: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var access: AgentReadAccess
    let focusedSettingID: String?

    var body: some View {
        Toggle(isOn: Binding(get: { access.isEnabled }, set: { access.setEnabled($0) })) {
            SettingsLabel("Allow external agents to read your LokalBot data",
                          help: "Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) read what you tick below: read-only, on this Mac only. Off by default.")
        }
        .accessibilityIdentifier("settings.agentAccess")
        .settingTarget("settings.agentAccess", selected: focusedSettingID)
        if access.isEnabled {
            box(.meetings, "Meetings", help: "List, read, search, and ask about your meetings.")
            box(.screenMemory, "Screen memory",
                help: "Captured text and metadata, within the history you grant. Screenshot pixels are never returned.")
                .settingTarget("settings.screenMemoryAccess", selected: focusedSettingID)
            if access.isTicked(.screenMemory) {
                Picker(selection: Binding(get: { access.screenScope }, set: { access.setScreenScope($0) })) {
                    ForEach(ScreenMemoryAccessProfile.Scope.allCases) { scope in
                        Text(LocalizedStringKey(scope.displayName)).tag(scope)
                    }
                } label: {
                    SettingsLabel("Granted history", help: access.screenScope.detail)
                }
                .padding(.leading, 20)
            }
            box(.personalContext, "What I shared about myself",
                help: "Only the Personal Context items you mark Share with agents.")
                .accessibilityIdentifier("settings.personalContextAccess")
                .settingTarget("settings.personalContextAccess", selected: focusedSettingID)
            if access.isTicked(.personalContext) {
                LabeledContent {
                    Button("Choose items…") {
                        app.selectSettingsTab(.personalContext)
                        app.focusedSettingID = "settings.agentKind.personalContext"
                    }
                    .buttonStyle(.workspaceLink)
                } label: {
                    SettingsLabel(access.personalContext.sharedCount == 1 ? "1 item shared"
                                      : "\(access.personalContext.sharedCount) items shared",
                                  help: "Agents get the most relevant shared items for their task, at most 12 at a time.")
                }
                .padding(.leading, 20)
            }
            box(.files, "Files", help: "Search the folders you chose under Files by their words. Files are never changed.")
                .accessibilityIdentifier("settings.filesAccess")
                .settingTarget("settings.filesAccess", selected: focusedSettingID)
            if access.isTicked(.files), !app.settings.fileSearchEnabled || app.settings.fileSearchFolders.isEmpty {
                LabeledContent {
                    Button("Choose folders…") {
                        app.selectSettingsTab(.files)
                        app.focusedSettingID = "settings.fileSearchEnabled"
                    }
                    .buttonStyle(.workspaceLink)
                } label: {
                    SettingsLabel("Files has no folders yet",
                                  help: "Agents can search only the folders you chose under Files.")
                }
                .padding(.leading, 20)
            }
            box(.agentNotes, "Agent notes",
                help: "Search the notes Claude Code and Codex saved for themselves by their words. The notes are never changed.")
                .accessibilityIdentifier("settings.agentNotesAccess")
                .settingTarget("settings.agentNotesAccess", selected: focusedSettingID)
            if access.isTicked(.agentNotes), !app.settings.codingAgentNotesEnabled {
                LabeledContent {
                    Button("Read coding agent notes") {
                        app.selectSettingsTab(.dayMemory)
                        app.focusedSettingID = "settings.codingAgentNotesEnabled"
                    }
                    .buttonStyle(.workspaceLink)
                } label: {
                    SettingsLabel("Coding agent notes are off",
                                  help: "Agents can search the notes only while Read coding agent notes is on.")
                }
                .padding(.leading, 20)
            }
        }
        ForEach([access.personalContext.lastError, access.files.lastError, access.agentNotes.lastError]
            .compactMap { $0 }, id: \.self) { error in
            Text(error).workspaceTextRole(.warning)
        }
    }

    private func box(_ kind: AgentReadAccess.Kind, _ title: String, help: String) -> some View {
        Toggle(isOn: Binding(get: { access.isTicked(kind) }, set: { access.setTicked(kind, $0) })) {
            SettingsLabel(title, help: help)
        }
        .toggleStyle(.checkbox)
        .disabled(access.isTicked(kind) && !access.canUntick(kind))
        .padding(.leading, 20)
    }
}
