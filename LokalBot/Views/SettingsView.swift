import SwiftUI
import LaunchAtLogin
import AppKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var updates = AppUpdateManager.shared
    @State private var cliMessage: String?
    @State private var writingAdvancedExpanded = false
    @State private var writingSection = WritingSection.autocomplete

    private enum WritingSection: String, CaseIterable {
        case autocomplete = "Autocomplete"
        case dictation = "Dictation"
    }

    // Settings search + live system readouts.
    @State private var settingsQuery = ""
    @StateObject private var power = PowerSourceMonitor()
    @StateObject private var permissions = PermissionManager.shared
    @ObservedObject private var metrics = GenerationMetricsStore.shared

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                settingsSearchField.padding(.horizontal, 14)
                List(selection: Binding(get: { queryIsEmpty ? Optional(app.settingsTab) : nil }, set: {
                    if let category = $0 { app.settingsTab = category; settingsQuery = ""; app.focusedSettingID = nil }
                })) {
                    ForEach(AppState.SettingsTab.allCases, id: \.self) { category in
                        SettingsCategoryLabel(category: category)
                            .padding(.vertical, 5)
                            .tag(category)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .tint(SettingsPalette.accent(colorScheme))
                .accessibilityLabel("Settings categories")
                .accessibilityIdentifier("settings.categories")
            }
            .frame(minWidth: 205, idealWidth: 220, maxWidth: 250)
            .background(SettingsPalette.navigation(colorScheme))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings navigation")
            .splitPaneAccessibilityLabel("Settings navigation", autosaveName: "LokalBot.settings")
            VStack(alignment: .leading, spacing: 0) {
                settingsHeaderTitle.padding(20)
                SettingsSeparator()
                if !queryIsEmpty {
                    searchResults
                } else if app.settingsTab == .models {
                    ModelsView()
                    .settingTarget("settings.models", selected: app.focusedSettingID)
                } else {
                    ScrollViewReader { proxy in
                        Form { sections(for: app.settingsTab) }
                            .formStyle(.grouped)
                            .scrollContentBackground(.hidden)
                            .accessibilityIdentifier("settings.form")
                            .onChange(of: app.focusedSettingID, initial: true) {
                                guard let id = app.focusedSettingID else { return }
                                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                            }
                    }
                    .id("\(app.settingsTab)-\(writingSection.rawValue)")
                }
            }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsPalette.canvas(colorScheme))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(queryIsEmpty ? app.settingsTab.displayName : "Search settings")
                .splitPaneAccessibilityLabel(queryIsEmpty ? app.settingsTab.displayName : "Search settings")
        }
        .frame(minWidth: 700, minHeight: 600)
        .tint(SettingsPalette.accent(colorScheme))
        .navigationTitle(queryIsEmpty ? app.settingsTab.displayName : "Search settings")
        .onChange(of: app.focusedSettingID, initial: true) {
            if let id = app.focusedSettingID, app.settingsTab == .writing {
                writingSection = id.hasPrefix("settings.dictation") ? .dictation : .autocomplete
            }
        }
        .onAppear {
            power.start()
            permissions.startPolling()
            app.calendar.refreshAuthorizationStatus()
            app.refreshDreamMemory()
        }
        .onDisappear {
            power.stop()
            permissions.stopPolling()
            PermissionGuidanceController.shared.dismiss()
        }
    }

    private var queryIsEmpty: Bool {
        settingsQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Search field + tab strip, above the tabbed content so search works
    /// from any tab (including Models).
    private var settingsHeaderTitle: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(systemImage: queryIsEmpty ? app.settingsTab.icon : "magnifyingglass",
                     tint: Brand.tealFill, size: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(queryIsEmpty ? app.settingsTab.displayName : "Search settings")
                    .font(WorkspaceTypography.pageTitle)
                    .tracking(-0.35)
                Text(queryIsEmpty ? settingsTabSubtitle : "Results across all categories. Choose a setting to edit its value.")
                    .font(WorkspaceTypography.metadata)
                    .settingsSecondary()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var settingsSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .settingsSecondary()
                .accessibilityHidden(true)
            TextField("Search settings…", text: $settingsQuery)
                .textFieldStyle(.plain)
                .font(WorkspaceTypography.control)
                .accessibilityIdentifier("settings.search")
            if !settingsQuery.isEmpty {
                Button { settingsQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .settingsSecondary()
                .accessibilityLabel("Clear settings search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .settingsPanel()
    }

    private var settingsTabSubtitle: String {
        switch app.settingsTab {
        case .general:
            "Startup, the main window, shortcuts, and updates."
        case .recording:
            "Meeting capture, detection, processing, and summaries."
        case .dayMemory:
            "Activity, captured context, daily briefs, routines, and exports."
        case .writing:
            "Dictation, autocomplete, and your writing profile."
        case .models:
            "Choose the models behind Transcribe, Think, and Autocomplete."
        case .privacy:
            "Control retention, exclusions, encryption, and remote processing."
        case .advanced:
            "Inspect memory health, resources, diagnostics, and Agent CLI."
        }
    }

    /// Spec §2.5 tab distribution: SettingsView's existing sections spread
    /// across General · Recording · Privacy · Advanced; Models is ModelsView.
    @ViewBuilder private func sections(for tab: AppState.SettingsTab) -> some View {
        switch tab {
        case .general:
            generalSection; updatesSection
        case .recording:
            meetingsSection; processingSection; summarizationSection
        case .dayMemory:
            dayTrackingSection; routinesSection; dreamingSection
        case .writing:
            Section {
                Picker("Writing tool", selection: $writingSection) {
                    ForEach(WritingSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.writing.sections")
            }
            if writingSection == .autocomplete {
                AutocompleteExperienceView()
                cotypingSection
            } else {
                Section("Dictation") { DictationSettingsControls() }
                DictationView(dictation: app.dictation, embedded: true)
            }
        case .models:
            EmptyView() // handled by the ModelsView branch in body
        case .privacy:
            privacySection; exclusionsSection; permissionsSection; privacyLinksSection
        case .advanced:
            memoryHealthSection; resourceMonitorSection; systemSection; agentCLISection
        }
    }

    /// Spec §2.5: the search field filters across ALL tabs — a non-empty
    /// query shows every matching section regardless of the selected tab,
    /// plus a jump row into the Models tab when its keywords match.
    private var searchResults: some View {
        let results = SettingDescriptor.search(settingsQuery)
        return List(results) { result in
            Button {
                app.settingsTab = result.category
                app.focusedSettingID = result.focusTarget(in: app.settings)
                writingAdvancedExpanded = result.category == .writing
                writingSection = result.id.hasPrefix("settings.dictation") ? .dictation : .autocomplete
                settingsQuery = ""
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title).font(WorkspaceTypography.bodyEmphasis)
                    Text(result.currentValue(in: app.settings) + " · " + result.category.displayName)
                        .font(WorkspaceTypography.metadata).settingsSecondary()
                    if let prerequisite = result.prerequisite(in: app.settings) {
                        Text(prerequisite).font(WorkspaceTypography.metadata).settingsSecondary()
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
            Toggle("Allow private/incognito browser windows", isOn: $app.settings.capturePrivateWindows)
                    .settingTarget("settings.capturePrivateWindows", selected: app.focusedSettingID)
        }
    }

    // MARK: - Sections

    @ViewBuilder private var memoryHealthSection: some View {
        if shows("Memory Health", ["health", "capture", "activity", "audio", "ocr",
                                   "accessibility", "retention", "queue", "routines",
                                   "disk", "permissions", "recovery", "diagnostics"]) {
            MemoryHealthSection()
                    .settingTarget("settings.memoryHealth", selected: app.focusedSettingID)
        }
    }

    @ViewBuilder private var resourceMonitorSection: some View {
        if shows("Resource Monitor", ["resource", "usage", "cpu", "memory", "ram",
                                      "footprint", "models", "loaded", "running",
                                      "performance", "diagnostics"]) {
            ResourceMonitorSection()
                    .settingTarget("settings.resourceMonitor", selected: app.focusedSettingID)
        }
    }

    @ViewBuilder private var generalSection: some View {
        if shows("General", ["launch", "login", "startup", "open at login", "auto start",
                                 "menu bar", "menubar", "dock", "dock icon", "hide dock",
                                 "window", "background", "tray", "quick recall", "shortcut",
                                 "hotkey", "global search"]) {
                Section("General") {
                    LaunchAtLogin.Toggle {
                        SettingsLabel("Launch LokalBot at login",
                                      help: "Start automatically so it's ready to catch meetings.")
                    }
                    .accessibilityLabel("Launch LokalBot at login")
                    .accessibilityHint("Start automatically so it's ready to catch meetings.")

                    Toggle(isOn: $app.settings.menuBarOnly) {
                        SettingsLabel("Menu bar only (hide Dock icon)",
                                      help: "Run from the menu bar with a live recording timer. Takes full effect once open windows close.")
                    }
                    .settingTarget("settings.menuBarOnly", selected: app.focusedSettingID)
                        .onChange(of: app.settings.menuBarOnly) { _, menuBarOnly in
                            DockPolicy.sync()
                            if !menuBarOnly { openWindow(id: "main") }
                        }
                }
                Section("Shortcut") {
                    Toggle(isOn: $app.settings.quickRecallEnabled) {
                        SettingsLabel("Enable the system-wide Ask shortcut",
                                      help: "Press \(QuickRecallHotKeyController.shortcutLabel) in any app to search your work memory or ask a question. LokalBot registers only this shortcut and never reads other keystrokes.")
                    }
                    .settingTarget("settings.quickRecallEnabled", selected: app.focusedSettingID)
                }
            }

    }

    @ViewBuilder private var cotypingSection: some View {
        if shows("Autocomplete", ["cotyping", "autocomplete", "suggestion", "suggestions",
                              "length", "words", "max words", "ghost", "inline",
                              "completion", "typing"]) {
            Section("Autocomplete") {
                Toggle("Enable autocomplete", isOn: $app.settings.cotypingEnabled)
                    .settingTarget("settings.cotypingEnabled", selected: app.focusedSettingID)
                LabeledContent("Autocomplete model") {
                    Button("Manage in Models…") { app.openSettings(tab: .models) }
                }
                Stepper("Suggestion length: up to \(app.settings.cotypingMaxWords) words",
                        value: $app.settings.cotypingMaxWords, in: 2...50)
                Toggle("Allow multi-line suggestions", isOn: $app.settings.cotypingMultiLine)
                    .settingTarget("settings.cotypingMultiLine", selected: app.focusedSettingID)
                LabeledContent("Pause before suggesting") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(app.settings.cotypingDebounceMs) },
                            set: { app.settings.cotypingDebounceMs = Int($0) }),
                            in: 20...1_000, step: 20)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Pause before suggesting")
                        Text("\(app.settings.cotypingDebounceMs) ms")
                            .monospacedDigit()
                            .settingsSecondary()
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
                .settingTarget("settings.cotypingDebounceMs", selected: app.focusedSettingID)
                Picker("Accept next", selection: $app.settings.cotypingAcceptKey) {
                    ForEach(CotypingAcceptKey.allCases) { Text($0.label).tag($0) }
                }
                    .settingTarget("settings.cotypingAcceptKey", selected: app.focusedSettingID)
                Picker("Each accept takes", selection: $app.settings.cotypingAcceptGranularity) {
                    ForEach(CotypingAcceptGranularity.allCases) { Text($0.label).tag($0) }
                }
                    .settingTarget("settings.cotypingAcceptGranularity", selected: app.focusedSettingID)
            }
            Section("Context and profile") {
                Toggle("Use app and window context", isOn: $app.settings.cotypingUseAppContext)
                    .settingTarget("settings.cotypingUseAppContext", selected: app.focusedSettingID)
                Toggle("Use clipboard as temporary context", isOn: $app.settings.cotypingUseClipboard)
                    .settingTarget("settings.cotypingUseClipboard", selected: app.focusedSettingID)
                Toggle(isOn: $app.settings.cotypingUseLocalLearning) {
                    SettingsLabel("Learn locally from accepted completions",
                                  help: "Preview runs are excluded from stats and learning.")
                }
                    .settingTarget("settings.cotypingUseLocalLearning", selected: app.focusedSettingID)
                profileField("Your name", prompt: "Optional", text: $app.settings.cotypingUserName)
                    .settingTarget("settings.cotypingUserName", selected: app.focusedSettingID)
                profileField("Writing style", prompt: "Optional, e.g. concise and friendly",
                             text: $app.settings.cotypingStyleNote)
                    .settingTarget("settings.cotypingStyleNote", selected: app.focusedSettingID)
                profileField("Languages", prompt: "Optional, e.g. English, German",
                             text: $app.settings.cotypingLanguages)
                    .settingTarget("settings.cotypingLanguages", selected: app.focusedSettingID)
            }
            Section("Exclusions") {
                ExclusionRulesEditor(title: "Never suggest in these apps", value: $app.settings.cotypingExcludedApps, kind: .applications)
                    .settingTarget("settings.cotypingExcludedApps", selected: app.focusedSettingID)
                ExclusionRulesEditor(title: "Never suggest on these sites", value: $app.settings.cotypingExcludedDomains, kind: .writingDomains)
                    .settingTarget("settings.cotypingExcludedDomains", selected: app.focusedSettingID)
                Toggle("Suggest in integrated terminals",
                       isOn: $app.settings.cotypingSuggestInIntegratedTerminals)
                    .settingTarget("settings.cotypingSuggestInIntegratedTerminals", selected: app.focusedSettingID)
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: Binding(
                    get: { writingAdvancedExpanded || app.focusedSettingID != nil },
                    set: { writingAdvancedExpanded = $0 })) {
                    Toggle("Stream partial suggestions",
                           isOn: $app.settings.cotypingStreamSuggestionsWhileGenerating)
                    .settingTarget("settings.cotypingStreamSuggestionsWhileGenerating", selected: app.focusedSettingID)
                    Toggle("Use fast in-process runtime",
                           isOn: $app.settings.cotypingInProcessRuntime)
                    .settingTarget("settings.cotypingInProcessRuntime", selected: app.focusedSettingID)
                    Toggle("Match the app font and text color",
                           isOn: $app.settings.cotypingMatchHostStyle)
                    .settingTarget("settings.cotypingMatchHostStyle", selected: app.focusedSettingID)
                    Toggle("Autocorrect the current word",
                           isOn: $app.settings.cotypingAutocorrect)
                    .settingTarget("settings.cotypingAutocorrect", selected: app.focusedSettingID)
                    Toggle("Emoji autocomplete", isOn: $app.settings.cotypingEmoji)
                    .settingTarget("settings.cotypingEmoji", selected: app.focusedSettingID)
                    Toggle("Macros", isOn: $app.settings.cotypingMacros)
                    .settingTarget("settings.cotypingMacros", selected: app.focusedSettingID)
                }
            }
        }
    }

    /// A labeled, visibly editable text field for optional profile values.
    private func profileField(_ title: String, prompt: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
        }
    }

    @ViewBuilder private var permissionsSection: some View {
            if shows("Permissions", ["permission", "grant", "access", "microphone", "mic",
                                     "screen recording", "system audio", "accessibility",
                                     "input monitoring", "keyboard", "relaunch", "tcc"]) {
                Section("Permissions") {
                    PermissionRow(permission: .microphone).settingTarget("settings.permissions", selected: app.focusedSettingID)
                    PermissionRow(permission: .accessibility,
                                  why: "Optional — window titles for the day timeline and browser-meeting detection.")
                    PermissionRow(permission: .screenRecording,
                                  why: "Optional — only used while visual capture (Day Memory) is on. System audio does not need it.")
                    PermissionRow(permission: .inputMonitoring,
                                  why: "Optional — powers the dictation and autocomplete shortcuts.")
                    HStack {
                        SettingsHelp("Accessibility and Input Monitoring grants apply at launch.")
                        Spacer()
                        Button("Relaunch") { PermissionManager.relaunch() }
                    }
                }
            }

    }

    @ViewBuilder private var meetingsSection: some View {
            if shows("Meetings", ["meeting", "auto record", "detect", "debounce", "stop debounce",
                                  "recording", "calendar", "calendar access", "browser", "google meet"]) {
                Section("Meetings") {
                    Picker(selection: $app.settings.autoRecordMode) {
                        ForEach(AppSettings.AutoRecordMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    } label: {
                        SettingsLabel("When a meeting is detected",
                                      help: "Only record when everyone has been informed and any consent the meeting or location requires is in place.")
                    }
                    .settingTarget("settings.autoRecordMode", selected: app.focusedSettingID)
                    LabeledContent("Detected apps") {
                        Text(Set(MeetingDetector.knownApps.values).sorted().joined(separator: ", ")
                             + " + browser meetings (Meet, Jitsi, Whereby)")
                            .settingsSecondary()
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
                    Toggle(isOn: $app.settings.calendarDetectionEnabled) {
                        SettingsLabel("Use calendar to improve detection",
                                      help: "Reads your Mac Calendar to confirm meetings and suggest attendee names for speakers. Attendee emails stay in local meeting metadata.")
                    }
                    .settingTarget("settings.calendarDetectionEnabled", selected: app.focusedSettingID)
                        .onChange(of: app.settings.calendarDetectionEnabled) { _, enabled in
                            if enabled, app.calendar.authorizationStatus == .notDetermined {
                                app.calendar.requestAccess { _ in }
                            }
                        }
                    if app.settings.calendarDetectionEnabled {
                        Toggle("Use calendar titles for recordings", isOn: $app.settings.useCalendarTitles)
                    .settingTarget("settings.useCalendarTitles", selected: app.focusedSettingID)
                        Toggle(isOn: $app.settings.requireCalendarForBrowser) {
                            SettingsLabel("Require a calendar match for browser auto-recording",
                                          help: "Only auto-record a browser tab while a scheduled event with a meeting link is in progress.")
                        }
                    .settingTarget("settings.requireCalendarForBrowser", selected: app.focusedSettingID)
                        LabeledContent("Calendar access") { calendarAccessControl }
                    }
                }
            }

    }

    @ViewBuilder private var processingSection: some View {
            if shows("Processing", ["transcribe", "transcription", "summarize", "summary",
                                    "automatic", "auto", "after meeting", "model", "models", "engine",
                                    "echo", "echo cancellation", "speakers", "headphones",
                                    "microphone mode", "voice isolation"]) {
                Section("Processing") {
                    Toggle("Transcribe automatically after each meeting", isOn: $app.settings.autoTranscribe)
                    .settingTarget("settings.autoTranscribe", selected: app.focusedSettingID)
                    Toggle("Summarize automatically after transcription", isOn: $app.settings.autoSummarize)
                    .settingTarget("settings.autoSummarize", selected: app.focusedSettingID)
                    LabeledContent("Transcribe and Think models") {
                        Button("Manage in Models…") { app.openSettings(tab: .models) }
                    }
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

    }

    @ViewBuilder private var summarizationSection: some View {
            if shows("Summarization", ["summary", "summarize", "notes", "template", "language",
                                       "diarization", "speaker", "split speaker", "neural", "nemotron", "pyannote"]) {
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
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .settingTarget("settings.summaryLanguage", selected: app.focusedSettingID)
                }
                Section("Speaker names") {
                    Toggle("Separate voices by speaker",
                           isOn: $app.settings.multiSpeakerDiarization)
                        .accessibilityLabel("Separate voices by speaker")
                        .accessibilityIdentifier("settings.multiSpeakerDiarization")
                    Picker(selection: $app.settings.diarizationModel) {
                        ForEach(DiarizationModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    } label: {
                        SettingsLabel("Speaker model", help: app.settings.diarizationModel.description)
                    }
                    .disabled(!app.settings.multiSpeakerDiarization)
                    .accessibilityLabel("Speaker model")
                    .accessibilityIdentifier("settings.diarizationModel")
                    SpeakerIdentitySettingsControls()
                }
            }

    }

    @ViewBuilder private var dayTrackingSection: some View {
            if shows("Day tracking", ["tracking", "activity", "screenshots", "screen", "capture",
                                      "ocr", "window", "accessibility", "retention", "private",
                                      "excluded apps", "never capture", "export", "obsidian",
                                      "logseq", "markdown", "daily note", "vault", "digest",
                                      "journal", "schedule", "prompt"]) {
                Section("Day Memory") {
                    Toggle(isOn: Binding(
                        get: { app.settings.trackingEnabled },
                        set: { app.settings.trackingEnabled = $0
                               if $0 {
                                   PermissionGuidanceController.shared.requestAccess(
                                       for: .accessibility)
                               } else {
                                   app.settings.screenContextCaptureMode = .activityOnly
                                   app.settings.screenshotsEnabled = false
                               } })) {
                        SettingsLabel("Track app & window activity",
                                      help: "Records which app and window you're using for the Timeline and day digest.")
                    }
                    .settingTarget("settings.trackingEnabled", selected: app.focusedSettingID)
                    LabeledContent("Window titles") {
                        if ActivitySampler.hasAccessibility {
                            Text("Accessibility granted").settingsSecondary()
                        } else {
                            Button("Grant Accessibility access…") {
                                PermissionGuidanceController.shared.requestAccess(
                                    for: .accessibility)
                            }
                        }
                    }
                    Picker(selection: Binding(
                        get: { app.settings.effectiveScreenContextCaptureMode },
                        set: { mode in
                            app.settings.screenContextCaptureMode = mode
                            app.settings.screenshotsEnabled = mode.capturesPixels
                            if mode.capturesText {
                                app.settings.trackingEnabled = true
                                PermissionGuidanceController.shared.requestAccess(
                                    for: .accessibility)
                            }
                            if mode.capturesPixels {
                                PermissionGuidanceController.shared.requestAccess(
                                    for: .screenRecording)
                            }
                        })) {
                        ForEach(AppSettings.ScreenContextCaptureMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
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
                        Button("Manage retention and cleanup…") { app.openSettings(tab: .privacy) }
                        Button("Manage capture exclusions…") { app.openSettings(tab: .privacy) }
                        if app.settings.effectiveScreenContextCaptureMode.capturesPixels {
                            Toggle(isOn: $app.settings.meetingVisualContextEnabled) {
                                SettingsLabel("Capture low-frequency visual context during meetings",
                                              help: "Off by default. Captures the focused display at most once a minute on meaningful changes and links each frame to the meeting.")
                            }
                    .settingTarget("settings.meetingVisualContextEnabled", selected: app.focusedSettingID)
                        }
                        SettingsDetails("How screen context is captured",
                                        "Captures context after app or window changes, clicks, typing pauses, settled "
                                            + "scrolls, or a clipboard change, without storing raw keys, "
                                            + "pointer positions, or clipboard contents. Accessible text is preferred; "
                                            + "local OCR fills gaps. Private windows, excluded domains, secure fields, "
                                            + "and detected credentials are never captured. Visuals are encrypted "
                                            + "with a key kept in your Mac's Keychain; extracted text follows the same retention "
                                            + "(see Privacy). Saved moments keep their encrypted frame and text "
                                            + "until you unsave or delete them. Excluded apps log as “Private”.")
                    }
                }
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
                                      help: "Writes one unencrypted Markdown file per day with the digest, meeting links, app time, and saved moments. Existing non-LokalBot content is never overwritten.")
                    }
                    .settingTarget("settings.dailyMemoryExportEnabled", selected: app.focusedSettingID)
                    if app.settings.dailyMemoryExportEnabled {
                        Picker("Format", selection: $app.settings.dailyMemoryExportFormat) {
                            ForEach(AppSettings.DailyMemoryExportFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
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

    }

    private var digestInstructionsField: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsLabel("Digest instructions (optional)",
                          help: "Shapes both scheduled and manual digests.")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $app.settings.dayDigestCustomPrompt)
                    .font(WorkspaceTypography.editorialBody)
                    .multilineTextAlignment(.leading)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .accessibilityLabel("Digest instructions")
                    .accessibilityIdentifier("settings.digestInstructions")

                if app.settings.dayDigestCustomPrompt.isEmpty {
                    Text("Example: Emphasize decisions, blockers, and next steps.")
                        .font(WorkspaceTypography.editorialBody)
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
        }
    }

    @ViewBuilder private var routinesSection: some View {
        if shows("Routines", ["routine", "automation", "standup", "stand-up", "weekly log",
                              "follow-up", "follow up", "unfinished actions", "journal",
                              "schedule", "history", "local output"]) {
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
                            LoadingStateLabel(kind.displayName, font: .caption)
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
    }

    @ViewBuilder private var dreamingSection: some View {
        if shows("Dreaming", ["dream", "dreaming", "overnight", "retrospective", "morning",
                              "brief", "memory", "projects", "goals", "pin", "pinned",
                              "downtime", "sleep"]) {
            Section("Overnight review") {
                Toggle(isOn: Binding(
                    get: { app.settings.dreamingEnabled },
                    set: { app.setDreamingEnabled($0) })) {
                    SettingsLabel("Review the day overnight",
                                  help: "While your Mac is idle after the chosen time, LokalBot turns the previous day into a morning retrospective on Today. It uses your Think model; if that model is remote, the compiled evidence is sent to it.")
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
                            LoadingStateLabel("Reviewing…", font: .caption)
                        } else if let last = app.dreaming.lastDreamedAt {
                            SettingsHelp("Last reviewed " + last.formatted(.relative(presentation: .named)))
                        }
                    }
                    if let error = app.dreaming.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(WorkspaceTypography.editorialBody).foregroundStyle(Brand.error)
                    }
                }
                if let memory = app.dreamMemory,
                   !memory.activeProjects.isEmpty || !memory.workGoals.isEmpty {
                    DisclosureGroup("Projects and goals") {
                        SettingsHelp("Pin items to keep them during automatic memory cleanup.")
                        if !memory.activeProjects.isEmpty {
                            Text("Active projects")
                                .font(.caption.weight(.semibold))
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
                                .font(.caption.weight(.semibold))
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
                SettingsDetails("What the review uses",
                                "It compiles meetings, outcomes, the day digest, and time totals, and keeps an evolving memory of active projects and goals. "
                                    + "Nights the Mac slept through catch up at the next launch. Evidence and generated files stay in the local library. If no model is reachable, a plain evidence summary is written instead.")
            }
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

    @ViewBuilder private var privacySection: some View {
            if shows("Privacy", ["privacy", "retention", "ocr", "text", "screen text", "history",
                                 "delete", "prune", "forever", "keep", "local", "network",
                                 "data", "security", "agents", "mcp", "claude", "cli"]) {
                Section("Where your data lives") {
                    InferenceDisclosure(
                        settings: app.settings,
                        localText: "Audio, transcripts, and captured context stay on this Mac. Network access is limited to model downloads, updates, and optional Agent Mode setup.",
                        remoteText: "Audio stays on this Mac. Transcripts and approved context may be sent to your remote Think model (\(app.settings.summarizerBackend.displayName)). Other network access is for models, updates, and optional Agent Mode setup.")
                    storageLocationRow
                }
                Section("Screen memory retention") {
                    RetentionSettingsControls()
                }
                Section("External agents") {
                    AgentAccessToggleRow(manager: app.agentAccess)
                    .settingTarget("settings.agentAccess", selected: app.focusedSettingID)
                    ScreenMemoryAccessToggleRow(manager: app.screenMemoryAccess)
                    .settingTarget("settings.screenMemoryAccess", selected: app.focusedSettingID)
                }
            }

    }

    private var storageLocationRow: some View {
        LabeledContent {
            Button(app.storage.rootURL.path(percentEncoded: false)) {
                NSWorkspace.shared.activateFileViewerSelecting([app.storage.rootURL])
            }
            .buttonStyle(.workspaceLink)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Show in Finder")
        } label: {
            SettingsLabel("Library location", help: "Meetings, day memory, and the search index.")
        }
    }

    /// Policy and support links close the Privacy & Data page.
    private var privacyLinksSection: some View {
        Section {
            HStack(spacing: 16) {
                Link("Privacy Policy", destination: URL(string: "https://www.lokalbot.com/privacy")!)
                    .buttonStyle(.workspaceLink)
                Link("Support", destination: URL(string: "https://www.lokalbot.com/support")!)
                    .buttonStyle(.workspaceLink)
            }
            .font(WorkspaceTypography.control)
        }
    }

    @ViewBuilder private var updatesSection: some View {
            if shows("Updates", ["update", "version", "sparkle", "upgrade", "check", "release",
                                 "appcast", "download"]) {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.automaticallyChecksForUpdates = $0 }))
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

    }

    @ViewBuilder private var systemSection: some View {
            if shows("System", ["system", "hardware", "ram", "memory", "chip", "cpu", "battery",
                                "power", "low power", "diagnostics", "performance", "generations"]) {
                Section("System") {
                    LabeledContent("This Mac") {
                        Text(DeviceInfo.snapshot().summaryLine)
                            .settingsSecondary()
                            .multilineTextAlignment(.trailing)
                    }
                    if power.isLowPower {
                        Label("Low Power Mode is on — summaries may run slower.", systemImage: "bolt.slash")
                            .font(.system(size: 12)).settingsSecondary()
                    } else if power.isOnBattery {
                        Label("Running on battery.", systemImage: "battery.75")
                            .font(.system(size: 12)).settingsSecondary()
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
                                    .font(WorkspaceTypography.metadata).settingsSecondary()
                            }
                        }
                    }
                }
            }

    }

    @ViewBuilder private var agentCLISection: some View {
            if shows("Agent CLI", ["cli", "agent", "terminal", "claude", "codex", "cursor",
                                   "gemini", "symlink", "install", "uninstall", "path"]) {
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
                        HStack {
                            Button(installer.isInstalled ? "Reinstall…" : "Install for your coding agent…") {
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
                        SettingsHelp("Symlinks the bundled CLI at ~/.local/bin/lokalbot-cli and the skill into ~/.agents/skills and ~/.claude/skills. Read-only by design.")
                    }
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

    /// Calendar permission state + action for the Meetings section.
    @ViewBuilder private var calendarAccessControl: some View {
        switch app.calendar.authorizationStatus {
        case .fullAccess:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDetermined:
            VStack(alignment: .trailing, spacing: 4) {
                Button("Grant Calendar Access…") { app.calendar.requestAccess { _ in } }
                if let error = app.calendar.accessRequestError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.error)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 320, alignment: .trailing)
                }
            }
        default:
            Button("Open System Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// A section is visible when the search field is empty or its title/keywords
    /// match the query (every query token must appear).
    private func shows(_ title: String, _ keywords: [String]) -> Bool {
        true
    }

    private func chooseDailyExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose daily memory export folder"
        panel.prompt = "Choose"
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

    private func chooseMemoryRoutineFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose routine output folder"
        panel.prompt = "Choose"
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

/// Category glyphs carry the accent like Agent's starters. A selected row on
/// the prominent accent highlight falls back to the row's own foreground so
/// the glyph never disappears into a teal fill.
private struct SettingsCategoryLabel: View {
    @Environment(\.backgroundProminence) private var prominence
    let category: AppState.SettingsTab

    var body: some View {
        Label {
            Text(category.displayName)
        } icon: {
            Image(systemName: category.icon)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Brand.teal))
        }
        .font(.system(size: 14))
    }
}

/// Observes the nested manager directly so its published marker state keeps
/// the toggle live without relying on AppState to forward changes.
private struct AgentAccessToggleRow: View {
    @ObservedObject var manager: AgentAccessManager

    var body: some View {
        Group {
            Toggle(isOn: Binding(
                get: { manager.isEnabled },
                set: { manager.setEnabled($0) })) {
                SettingsLabel("Allow external agents to read your meeting library",
                              help: "Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) list, read, search, and ask about your meetings — read-only and localhost only. Off by default.")
            }
        }
    }
}

private struct ScreenMemoryAccessToggleRow: View {
    @ObservedObject var manager: ScreenMemoryAccessManager

    var body: some View {
        Group {
            Toggle(isOn: Binding(
                get: { manager.isEnabled },
                set: { manager.setEnabled($0) })) {
                SettingsLabel("Allow external agents to read screen memory",
                              help: "Separate, scoped, read-only access to captured text and metadata. Screenshot pixels are never returned.")
            }
            if manager.isEnabled {
                Picker(selection: Binding(
                    get: { manager.profile.scope },
                    set: { manager.setScope($0) })) {
                    ForEach(ScreenMemoryAccessProfile.Scope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                } label: {
                    SettingsLabel("Granted history", help: manager.profile.scope.detail)
                }
            }
        }
    }
}
