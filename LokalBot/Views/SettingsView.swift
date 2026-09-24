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
                        Label(category.displayName, systemImage: category.icon)
                            .font(.system(size: 14))
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
                if !queryIsEmpty || app.settingsTab != .models {
                    settingsHeaderTitle.padding(20)
                    SettingsSeparator()
                }
                if !queryIsEmpty {
                    searchResults
                } else if app.settingsTab == .models {
                    ModelsView()
                    .settingTarget("settings.models", selected: app.focusedSettingID)
                } else {
                    if app.settingsTab == .writing {
                        Picker("Writing tool", selection: $writingSection) {
                            ForEach(WritingSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .accessibilityIdentifier("settings.writing.sections")
                    }
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
        VStack(alignment: .leading, spacing: 3) {
            Text(queryIsEmpty ? app.settingsTab.displayName : "Search settings")
                .font(WorkspaceTypography.pageTitle)
                .tracking(-0.35)
            Text(queryIsEmpty ? settingsTabSubtitle : "Results across all categories. Choose a setting to edit its value.")
                .font(WorkspaceTypography.body)
                .settingsSecondary()
                .fixedSize(horizontal: false, vertical: true)
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
            "Choose and prepare local or remote model backends."
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
            if writingSection == .autocomplete {
                Section("Try autocomplete") {
                    AutocompleteExperienceView()
                        .settingTarget("settings.autocompletePreview", selected: app.focusedSettingID)
                }
                cotypingSection
            } else {
                Section("Dictation") { DictationSettingsControls() }
                DictationView(dictation: app.dictation, embedded: true)
                    .settingTarget("settings.dictationPreview", selected: app.focusedSettingID)
            }
        case .models:
            EmptyView() // handled by the ModelsView branch in body
        case .privacy:
            privacySection; exclusionsSection; permissionsSection; storageSection
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
                    LaunchAtLogin.Toggle("Launch LokalBot at login")
                    Text("Start LokalBot automatically so it's ready to catch meetings.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()

                    Toggle("Menu bar only (hide Dock icon)", isOn: $app.settings.menuBarOnly)
                    .settingTarget("settings.menuBarOnly", selected: app.focusedSettingID)
                        .onChange(of: app.settings.menuBarOnly) { _, menuBarOnly in
                            DockPolicy.sync()
                            if !menuBarOnly { openWindow(id: "main") }
                        }
                    Text("Run from the menu bar with a live recording timer — no Dock icon, no window at launch. The window stays one click away. Takes full effect once open windows are closed.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    Divider()
                    Toggle("Enable the system-wide Ask shortcut", isOn: $app.settings.quickRecallEnabled)
                    .settingTarget("settings.quickRecallEnabled", selected: app.focusedSettingID)
                    Text("Press \(QuickRecallHotKeyController.shortcutLabel) from any app to search meetings, captured screen text, and saved moments—or ask the assistant without opening the main window. LokalBot registers only this shortcut and does not inspect other keystrokes.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
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
                    Text("\(app.settings.cotypingDebounceMs) ms").settingsSecondary()
                }
                Slider(value: Binding(
                    get: { Double(app.settings.cotypingDebounceMs) },
                    set: { app.settings.cotypingDebounceMs = Int($0) }),
                    in: 20...1_000, step: 20)
                    .accessibilityLabel("Pause before suggesting")
                    .settingTarget("settings.cotypingDebounceMs", selected: app.focusedSettingID)
                Picker("Accept next", selection: $app.settings.cotypingAcceptKey) {
                    ForEach(CotypingAcceptKey.allCases) { Text($0.label).tag($0) }
                }
                    .settingTarget("settings.cotypingAcceptKey", selected: app.focusedSettingID)
                Picker("Each accept takes", selection: $app.settings.cotypingAcceptGranularity) {
                    ForEach(CotypingAcceptGranularity.allCases) { Text($0.label).tag($0) }
                }
                    .settingTarget("settings.cotypingAcceptGranularity", selected: app.focusedSettingID)
                Divider()
                Toggle("Use app and window context", isOn: $app.settings.cotypingUseAppContext)
                    .settingTarget("settings.cotypingUseAppContext", selected: app.focusedSettingID)
                Toggle("Use clipboard as temporary context", isOn: $app.settings.cotypingUseClipboard)
                    .settingTarget("settings.cotypingUseClipboard", selected: app.focusedSettingID)
                Toggle("Learn locally from accepted completions",
                       isOn: $app.settings.cotypingUseLocalLearning)
                    .settingTarget("settings.cotypingUseLocalLearning", selected: app.focusedSettingID)
                TextField("Your name (optional)", text: $app.settings.cotypingUserName)
                    .settingTarget("settings.cotypingUserName", selected: app.focusedSettingID)
                TextField("Writing style (optional)", text: $app.settings.cotypingStyleNote)
                    .settingTarget("settings.cotypingStyleNote", selected: app.focusedSettingID)
                TextField("Languages (optional)", text: $app.settings.cotypingLanguages)
                    .settingTarget("settings.cotypingLanguages", selected: app.focusedSettingID)
                Divider()
                ExclusionRulesEditor(title: "Never suggest in these apps", value: $app.settings.cotypingExcludedApps, kind: .applications)
                    .settingTarget("settings.cotypingExcludedApps", selected: app.focusedSettingID)
                ExclusionRulesEditor(title: "Never suggest on these sites", value: $app.settings.cotypingExcludedDomains, kind: .writingDomains)
                    .settingTarget("settings.cotypingExcludedDomains", selected: app.focusedSettingID)
                Toggle("Suggest in integrated terminals",
                       isOn: $app.settings.cotypingSuggestInIntegratedTerminals)
                    .settingTarget("settings.cotypingSuggestInIntegratedTerminals", selected: app.focusedSettingID)
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
                Text("Preview runs are excluded from production stats and local learning.")
                    .font(WorkspaceTypography.editorialBody).settingsSecondary()
            }
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
                        Text("Accessibility and Input Monitoring grants apply at launch.")
                            .font(WorkspaceTypography.editorialBody).settingsSecondary()
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
                    Picker("When a meeting is detected", selection: $app.settings.autoRecordMode) {
                        ForEach(AppSettings.AutoRecordMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .settingTarget("settings.autoRecordMode", selected: app.focusedSettingID)
                    Text("Only record when everyone has been informed and you have any consent required for the meeting and location.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
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
                    Divider()
                    Toggle("Use calendar to improve detection", isOn: $app.settings.calendarDetectionEnabled)
                    .settingTarget("settings.calendarDetectionEnabled", selected: app.focusedSettingID)
                        .onChange(of: app.settings.calendarDetectionEnabled) { _, enabled in
                            if enabled, app.calendar.authorizationStatus == .notDetermined {
                                app.calendar.requestAccess { _ in }
                            }
                        }
                    Text("Reads your Mac Calendar (including synced Google/Exchange accounts) to confirm meetings and suggest attendee names when labeling speakers. Attendee emails stay in local meeting metadata and are used only to distinguish candidates.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    if app.settings.calendarDetectionEnabled {
                        Toggle("Use calendar titles for recordings", isOn: $app.settings.useCalendarTitles)
                    .settingTarget("settings.useCalendarTitles", selected: app.focusedSettingID)
                        Toggle("Require a calendar match for browser auto-recording", isOn: $app.settings.requireCalendarForBrowser)
                    .settingTarget("settings.requireCalendarForBrowser", selected: app.focusedSettingID)
                        Text("Stricter: only auto-record a browser tab when a scheduled event with a meeting link is in progress.")
                            .font(WorkspaceTypography.editorialBody).settingsSecondary()
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
                    Text("Choose transcription and main LLM models in the Models tab.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    Divider()
                    Toggle("Remove the other side from your microphone track",
                           isOn: $app.settings.echoCancellation)
                    .settingTarget("settings.echoCancellation", selected: app.focusedSettingID)
                    Text("On speakers the other side reaches your microphone too and gets transcribed a second time as you. Subtracts the system-audio track before transcription — including for meetings already recorded. No effect on headphones.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    Text("Needs the microphone mode for LokalBot itself set to Standard (Control Center → microphone icon → LokalBot's row) — macOS Voice Isolation removes the very echo this looks for. The meeting app can stay on Voice Isolation; the mode is set per app, not on the microphone.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
                }
            }

    }

    @ViewBuilder private var summarizationSection: some View {
            if shows("Summarization", ["summary", "summarize", "notes", "template", "language",
                                       "diarization", "speaker", "split speaker", "neural", "nemotron", "pyannote"]) {
                Section("Summarization") {
                    Picker("Notes template", selection: $app.settings.noteTemplate) {
                        ForEach(NoteTemplate.allCases) { template in
                            Text("\(template.displayName)").tag(template)
                        }
                    }
                    .settingTarget("settings.noteTemplate", selected: app.focusedSettingID)
                    Text(app.settings.noteTemplate.description)
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    Picker("Notes language", selection: $app.settings.summaryLanguage) {
                        Text("Match transcript (auto)").tag(SummaryLanguage.matchTranscript)
                        Divider()
                        ForEach(SummaryLanguage.presets, id: \.rawValue) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .settingTarget("settings.summaryLanguage", selected: app.focusedSettingID)
                    Toggle("Separate voices by speaker",
                           isOn: $app.settings.multiSpeakerDiarization)
                        .accessibilityLabel("Separate voices by speaker")
                        .accessibilityIdentifier("settings.multiSpeakerDiarization")
                    Picker("Speaker model", selection: $app.settings.diarizationModel) {
                        ForEach(DiarizationModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .disabled(!app.settings.multiSpeakerDiarization)
                    .accessibilityLabel("Speaker model")
                    .accessibilityIdentifier("settings.diarizationModel")
                    Text(app.settings.diarizationModel.description)
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
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
                    Toggle("Track app & window activity", isOn: Binding(
                        get: { app.settings.trackingEnabled },
                        set: { app.settings.trackingEnabled = $0
                               if $0 {
                                   PermissionGuidanceController.shared.requestAccess(
                                       for: .accessibility)
                               } else {
                                   app.settings.screenContextCaptureMode = .activityOnly
                                   app.settings.screenshotsEnabled = false
                               } }))
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
                    Picker("Screen context", selection: Binding(
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
                    }
                    .settingTarget("settings.effectiveScreenContextCaptureMode", selected: app.focusedSettingID)
                    Text(app.settings.effectiveScreenContextCaptureMode.detail)
                        .workspaceTextRole(.supporting)
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
                            Toggle("Capture low-frequency visual context during meetings",
                                   isOn: $app.settings.meetingVisualContextEnabled)
                    .settingTarget("settings.meetingVisualContextEnabled", selected: app.focusedSettingID)
                            Text("Off by default. When enabled, captures the focused display at most once per minute on meaningful changes and links each frame to the active meeting.")
                                .workspaceTextRole(.trust)
                        }
                    }
                    Text(
                        "Captures context after app/window changes, clicks, typing pauses, settled "
                            + "scrolls, or a clipboard-generation change without storing raw keys, "
                            + "pointer positions, or clipboard contents. Accessible text is preferred; "
                            + "local OCR fills gaps. Private windows, excluded domains, secure fields, "
                            + "and detected credentials fail closed. Visuals are encrypted "
                            + "with a key kept in your Mac's Keychain; extracted text follows the same retention "
                            + "(see Privacy). Saved moments retain their encrypted frame and text "
                            + "until you unsave or delete them. Excluded apps log as “Private”."
                    )
                        .workspaceTextRole(.trust)
                    Divider()
                    Toggle("Generate the day digest automatically",
                           isOn: $app.settings.dayDigestAutoEnabled)
                    .settingTarget("settings.dayDigestAutoEnabled", selected: app.focusedSettingID)
                    if app.settings.dayDigestAutoEnabled {
                        Stepper(
                            "Generate at \(String(format: "%02d:00", app.settings.dayDigestHour))",
                            value: $app.settings.dayDigestHour,
                            in: 0...23)
                    }
                    digestInstructionsField.settingTarget("settings.dayDigestCustomPrompt", selected: app.focusedSettingID)
                    Text("Writes a detailed Timeline digest to your local journal at the chosen hour, then finalizes yesterday once after the date changes so late activity is included. Instructions shape scheduled and manual generation alike.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    Divider()
                    Toggle("Export a daily memory note", isOn: Binding(
                        get: { app.settings.dailyMemoryExportEnabled },
                        set: { enabled in
                            app.settings.dailyMemoryExportEnabled = enabled
                            if enabled && app.settings.dailyMemoryExportFolder.isEmpty {
                                chooseDailyExportFolder()
                            }
                        }))
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
                            "Refresh at \(String(format: "%02d:00", app.settings.dailyMemoryExportHour))",
                            value: $app.settings.dailyMemoryExportHour,
                            in: 0...23)
                    }
                    Text("Writes one idempotent, unencrypted Markdown file per day with the digest, meeting links, app-time totals, and saved moments. Existing non-LokalBot content is never overwritten.")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
                }
            }

    }

    private var digestInstructionsField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Digest instructions (optional)")
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
                Toggle("Enable safe local routines", isOn: Binding(
                    get: { app.settings.memoryRoutinesEnabled },
                    set: { enabled in
                        app.settings.memoryRoutinesEnabled = enabled
                        if enabled && app.settings.memoryRoutineFolder.isEmpty {
                            chooseMemoryRoutineFolder()
                        }
                    }))
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
                        "Daily time: \(String(format: "%02d:00", app.settings.memoryRoutineHour))",
                        value: $app.settings.memoryRoutineHour,
                        in: 0...23)
                    Picker("Weekly log day", selection: $app.settings.memoryRoutineWeekday) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(weekdayName(weekday)).tag(weekday)
                        }
                    }
                    .settingTarget("settings.memoryRoutineWeekday", selected: app.focusedSettingID)
                    ForEach(AppSettings.MemoryRoutineKind.allCases) { kind in
                        Toggle(kind.displayName, isOn: Binding(
                            get: { app.settings.enabledMemoryRoutines.contains(kind) },
                            set: { enabled in setRoutine(kind, enabled: enabled) }))
                        Text(kind.detail)
                            .font(WorkspaceTypography.editorialBody)
                            .settingsSecondary()
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
                Text("Each routine has a fixed local read scope and writes Markdown only inside the chosen folder. Missed daily/weekly runs catch up after wake, each run stops after 30 seconds, and every attempt is recorded in the local database. Routines cannot execute scripts, contact services, send messages, or change source meetings.")
                    .font(WorkspaceTypography.editorialBody).settingsSecondary()
            }
        }
    }

    @ViewBuilder private var dreamingSection: some View {
        if shows("Dreaming", ["dream", "dreaming", "overnight", "retrospective", "morning",
                              "brief", "memory", "projects", "goals", "pin", "pinned",
                              "downtime", "sleep"]) {
            Section("Overnight review") {
                Toggle("Review the day overnight", isOn: Binding(
                    get: { app.settings.dreamingEnabled },
                    set: { app.setDreamingEnabled($0) }))
                    .settingTarget("settings.dreamingEnabled", selected: app.focusedSettingID)
                if app.settings.dreamingEnabled {
                    Stepper(
                        "Review after \(String(format: "%02d:00", app.settings.dreamingHour))",
                        value: $app.settings.dreamingHour,
                        in: 0...23)
                    HStack(spacing: 8) {
                        Button("Review now") { app.dreamNow() }
                            .disabled(app.dreaming.isDreaming || !app.libraryReady)
                        if app.dreaming.isDreaming {
                            LoadingStateLabel("Reviewing…", font: .caption)
                        } else if let last = app.dreaming.lastDreamedAt {
                            Text("Last reviewed " + last.formatted(.relative(presentation: .named)))
                                .font(WorkspaceTypography.editorialBody).settingsSecondary()
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
                        Text("Pin items to keep them during automatic memory cleanup.")
                            .font(WorkspaceTypography.editorialBody)
                            .settingsSecondary()
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
                Text("While your Mac is otherwise idle after the chosen hour, LokalBot compiles the previous day — meetings, outcomes, the day digest, and time totals — into a morning retrospective and an evolving structured memory of active projects and goals, shown on Today. "
                     + "Nights the Mac slept through catch up at the next launch. Evidence and generated files stay in the local library. Generation uses your configured Main LLM, so an approved remote backend receives the compiled evidence; if no model is reachable, a plain evidence summary is written instead.")
                    .workspaceTextRole(.trust)
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
                    Text(detail)
                        .font(WorkspaceTypography.editorialBody)
                        .settingsSecondary()
                }
            }
            .disabled(app.dreaming.isDreaming)
    }

    @ViewBuilder private var privacySection: some View {
            if shows("Privacy", ["privacy", "retention", "ocr", "text", "screen text", "history",
                                 "delete", "prune", "forever", "keep", "local", "network",
                                 "data", "security", "agents", "mcp", "claude", "cli"]) {
                Section("Privacy") {
                    InferenceDisclosure(
                        settings: app.settings,
                        localText: "Audio, transcripts, and captured context stay on this Mac. Network access is limited to model downloads, updates, and optional Agent Mode setup.",
                        remoteText: "Audio stays on this Mac. Transcripts and approved context may be sent to your remote Main LLM (\(app.settings.summarizerBackend.displayName)). Other network access is for models, updates, and optional Agent Mode setup.")
                    RetentionSettingsControls()
                    AgentAccessToggleRow(manager: app.agentAccess)
                    .settingTarget("settings.agentAccess", selected: app.focusedSettingID)
                    ScreenMemoryAccessToggleRow(manager: app.screenMemoryAccess)
                    .settingTarget("settings.screenMemoryAccess", selected: app.focusedSettingID)
                    HStack(spacing: 16) {
                        Link("Privacy Policy", destination: URL(string: "https://www.lokalbot.com/privacy")!)
                        Link("Support", destination: URL(string: "https://www.lokalbot.com/support")!)
                    }
                    .font(WorkspaceTypography.editorialBody)
                }
            }

    }

    @ViewBuilder private var storageSection: some View {
            if shows("Storage", ["storage", "location", "files", "folder", "finder", "disk"]) {
                Section("Storage") {
                    LabeledContent("Location") {
                        Button(app.storage.rootURL.path(percentEncoded: false)) {
                            NSWorkspace.shared.activateFileViewerSelecting([app.storage.rootURL])
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.teal)
                    }
                }
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
                    Text(updates.isStarted
                         ? "Updates are signed and delivered via Sparkle. LokalBot stays local-first — only the appcast and the chosen download are fetched."
                         : "Updater inactive — set the appcast feed URL and Sparkle public key before shipping (see RELEASING.md).")
                        .font(WorkspaceTypography.editorialBody).settingsSecondary()
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
                            .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    } else if power.isOnBattery {
                        Label("Running on battery.", systemImage: "battery.75")
                            .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    }
                    if metrics.recent.isEmpty {
                        Text("No model generations recorded yet.")
                            .font(WorkspaceTypography.editorialBody).settingsSecondary()
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
                        Text("The command-line helper is not included in this build. Install a current LokalBot release to use Agent CLI access.")
                            .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    } else {
                        LabeledContent("Status") {
                            if installer.isInstalled {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if !installer.isBundleLocationStable {
                                Label("Move LokalBot.app to /Applications first",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Brand.error)
                            } else {
                                Label("Not installed", systemImage: "circle")
                                    .settingsSecondary()
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
                            Text(cliMessage).font(WorkspaceTypography.editorialBody).settingsSecondary()
                        }
                        Text("Symlinks the bundled CLI at ~/.local/bin/lokalbot-cli and the skill into ~/.agents/skills and ~/.claude/skills. Read-only by design.")
                            .font(WorkspaceTypography.editorialBody).settingsSecondary()
                    }
                }
            }

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
                        .font(WorkspaceTypography.editorialBody)
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

/// Observes the nested manager directly so its published marker state keeps
/// the toggle live without relying on AppState to forward changes.
private struct AgentAccessToggleRow: View {
    @ObservedObject var manager: AgentAccessManager

    var body: some View {
        Group {
            Toggle(
                "Allow external agents to read your meeting library",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }))
            Text("Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) list, read, and search your meetings, and ask questions answered by your local model — read-only, localhost only. Off by default; while off, agent tools return an error explaining how to enable this.")
                .font(WorkspaceTypography.editorialBody)
                .settingsSecondary()
        }
    }
}

private struct ScreenMemoryAccessToggleRow: View {
    @ObservedObject var manager: ScreenMemoryAccessManager

    var body: some View {
        Group {
            Toggle(
                "Allow external agents to read screen memory",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }))
            if manager.isEnabled {
                Picker("Granted history", selection: Binding(
                    get: { manager.profile.scope },
                    set: { manager.setScope($0) })) {
                    ForEach(ScreenMemoryAccessProfile.Scope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                Text(manager.profile.scope.detail)
                    .font(WorkspaceTypography.editorialBody)
                    .settingsSecondary()
            }
            Text("Separately grants scoped, read-only MCP access to captured text and metadata. Decrypted screenshot pixels are never returned, out-of-scope ids appear missing, and meeting access remains independently controlled above.")
                .font(WorkspaceTypography.editorialBody)
                .settingsSecondary()
        }
    }
}
