import SwiftUI

/// Settings › Autocomplete, under the shared header: the settings in groups,
/// then rows that open the writing profile, the apps and sites to skip, the
/// usage numbers and the advanced settings. The rehearsal is the header's
/// "Try it…" sheet.
struct AutocompleteSettingsSections: View {
    @EnvironmentObject private var app: AppState
    /// Autocomplete on a chosen server, for its last problem.
    @ObservedObject var server: RemoteCotypingEngine
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var stats = CotypingStatsStore.shared
    /// The page a row opened, when one is open.
    let subpage: SettingsSubpage?
    let open: (SettingsSubpage) -> Void
    /// Opens the model picker over the page.
    let changeModel: () -> Void

    @State private var forgettingLearning = false
    @State private var learningMessage: String?

    private var localized: (String) -> String { app.settings.appLanguage.catalog }

    var body: some View {
        switch subpage {
        case .autocompleteProfile: profileSection
        case .autocompleteExclusions: exclusionsSection
        case .autocompleteUsage: usageSections
        case .autocompleteAdvanced: advancedSection
        default: mainSections
        }
    }

    @ViewBuilder private var mainSections: some View {
        AutocompleteNotices(server: server)
        suggestionsSection
        readingSection
        extrasSection
        moreSection
    }

    // MARK: - Suggestions

    private var suggestionsSection: some View {
        Section("Suggestions") {
            LabeledContent("Length") {
                HStack(spacing: 8) {
                    Text("Up to \(app.settings.cotypingMaxWords) words").monospacedDigit().settingsSecondary()
                    Stepper("Length", value: $app.settings.cotypingMaxWords, in: 2...50)
                        .labelsHidden()
                        .accessibilityLabel("Length")
                        .accessibilityValue(Text("Up to \(app.settings.cotypingMaxWords) words"))
                }
            }
            .settingTarget("settings.cotypingMaxWords", selected: app.focusedSettingID)
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { Double(app.settings.cotypingDebounceMs) },
                        set: { app.settings.cotypingDebounceMs = Int($0) }),
                        in: 20...1_000, step: 20)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Wait after you stop typing")
                        .accessibilityValue(Text(verbatim: "\(app.settings.cotypingDebounceMs) ms"))
                    Text(verbatim: "\(app.settings.cotypingDebounceMs) ms")
                        .monospacedDigit()
                        .settingsSecondary()
                        .frame(minWidth: 56, alignment: .trailing)
                }
            } label: {
                SettingsLabel("Wait after you stop typing", help: "Shorter shows suggestions sooner")
            }
            .settingTarget("settings.cotypingDebounceMs", selected: app.focusedSettingID)
            Picker("Accept with", selection: $app.settings.cotypingAcceptKey) {
                ForEach(CotypingAcceptKey.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            .settingTarget("settings.cotypingAcceptKey", selected: app.focusedSettingID)
            Picker("Each press accepts", selection: $app.settings.cotypingAcceptGranularity) {
                ForEach(CotypingAcceptGranularity.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            .settingTarget("settings.cotypingAcceptGranularity", selected: app.focusedSettingID)
            SettingsSwitchRow("Take punctuation with the word",
                              info: "When off, a full stop or comma after a word takes its own press, so you can still end the sentence differently.",
                              isOn: $app.settings.cotypingAutoAcceptTrailingPunctuation)
                .settingTarget("settings.cotypingAutoAcceptTrailingPunctuation", selected: app.focusedSettingID)
            LabeledContent("Escape on a suggestion") {
                HStack(spacing: 8) {
                    SettingsInfoButton("Pausing keeps Escape from also reaching the app and holds suggestions in that field for a few seconds. Escape is never touched when no suggestion is showing.")
                    Picker("Escape on a suggestion", selection: $app.settings.cotypingEscapeBehavior) {
                        ForEach(CotypingEscapeBehavior.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .settingTarget("settings.cotypingEscapeBehavior", selected: app.focusedSettingID)
            SettingsSwitchRow("Suggestions longer than one line", isOn: $app.settings.cotypingMultiLine)
                .settingTarget("settings.cotypingMultiLine", selected: app.focusedSettingID)
        }
    }

    // MARK: - What it can read

    /// What each optional context source can do right now.
    private var context: CotypingContextAvailability {
        app.cotypingContextAvailability(accessibilityGranted: permissions.granted[.accessibility] ?? false,
                                        screenRecordingGranted: permissions.granted[.screenRecording] ?? false)
    }

    private var readingSection: some View {
        Section {
            let context = context
            SettingsSwitchRow("App and window name", isOn: $app.settings.cotypingUseAppContext)
                .settingTarget("settings.cotypingUseAppContext", selected: app.focusedSettingID)
            SettingsSwitchRow("Clipboard", isOn: $app.settings.cotypingUseClipboard)
                .settingTarget("settings.cotypingUseClipboard", selected: app.focusedSettingID)
            SettingsSwitchRow(title: "Text above where you type",
                              info: "Use nearby messages and labels to suggest relevant replies. Processed locally, never saved; capture exclusions apply and private browser windows are skipped.",
                              isOn: $app.settings.cotypingUseVisibleContext) {
                CotypingContextStateLabel(state: context.visibleText)
            }
            .settingTarget("settings.cotypingUseVisibleContext", selected: app.focusedSettingID)
            SettingsSwitchRow(title: "The whole window", detail: "Needs Screen Recording",
                              info: "Read the whole window you are typing in with on-device text recognition, so suggestions follow the full conversation or page. Needs Screen Recording. The image and text stay on this Mac and are never saved; capture exclusions apply and private browser windows are skipped.",
                              isOn: $app.settings.cotypingUseWindowText) {
                CotypingContextStateLabel(state: context.windowText)
            }
            .settingTarget("settings.cotypingUseWindowText", selected: app.focusedSettingID)
            SettingsSwitchRow(title: "Facts from your meetings",
                              info: "Use up to two relevant facts from recent meeting notes, decisions, and work memory to help with names and details. Processed on this Mac.",
                              isOn: $app.settings.cotypingUseMeetingMemory) {
                CotypingContextStateLabel(state: context.meetingMemory)
            }
            .settingTarget("settings.cotypingUseMeetingMemory", selected: app.focusedSettingID)
            SettingsSwitchRow(title: "Facts from your screen history",
                              info: "Also allow relevant work memory derived from screen activity and daily journals. Reads what is already saved; it does not capture new screens or start an overnight review. Mixed meeting and screen memories require both settings.",
                              isOn: $app.settings.cotypingUseScreenMemory) {
                CotypingContextStateLabel(state: context.screenMemory)
            }
            .settingTarget("settings.cotypingUseScreenMemory", selected: app.focusedSettingID)
            if !app.cotyping.memoryContextSources.isEmpty {
                Text("Last suggestion used: \(app.cotyping.memoryContextSources.joined(separator: ", "))")
                    .settingsSecondary()
            } else if app.cotyping.memoryContextSearched {
                Text("Last suggestion: no relevant memory found.")
                    .settingsSecondary()
            }
        } header: {
            Text("What it can read")
        } footer: {
            // A server receives what is turned on here; only this Mac can
            // promise that nothing it reads is kept.
            if app.settings.cotypingLeavesThisMac, let host = app.settings.cotypingConfiguredServerURL?.host {
                Label("Context you turn on here is sent to \(host) with what you type.", systemImage: "network")
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(LBTokens.Palette.attentionText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsHelp("Read only while you type, on this Mac. Nothing it reads is saved.")
            }
        }
    }

    // MARK: - Extras

    private var extrasSection: some View {
        Section("Extras") {
            SettingsSwitchRow("Fix typos in the current word", isOn: $app.settings.cotypingAutocorrect)
                .settingTarget("settings.cotypingAutocorrect", selected: app.focusedSettingID)
            SettingsSwitchRow("Suggest emoji", isOn: $app.settings.cotypingEmoji)
                .settingTarget("settings.cotypingEmoji", selected: app.focusedSettingID)
            SettingsSwitchRow("Macros", isOn: $app.settings.cotypingMacros)
                .settingTarget("settings.cotypingMacros", selected: app.focusedSettingID)
            SettingsSwitchRow("Match the app’s font and text color", isOn: $app.settings.cotypingMatchHostStyle)
                .settingTarget("settings.cotypingMatchHostStyle", selected: app.focusedSettingID)
        }
    }

    // MARK: - More

    private var moreSection: some View {
        Section("More") {
            // The model, or a server, is chosen in the same picker Models uses.
            LabeledContent {
                HStack(spacing: 10) {
                    Text(verbatim: app.settings.cotypingModelDisplayName)
                        .settingsSecondary()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change…", action: changeModel)
                        .accessibilityIdentifier("settings.model.change.autocomplete")
                }
            } label: {
                Text("Autocomplete model")
            }
            SettingsDrillRow(title: "Writing profile",
                             detail: "Your name, style and languages. Dictation uses it too.",
                             value: DictationView.writingProfileSummary(app.settings, localized: localized),
                             identifier: "settings.autocomplete.profile") { open(.autocompleteProfile) }
            SettingsDrillRow(title: "Apps and sites to skip", value: skippedSummary,
                             identifier: "settings.autocomplete.exclusions") { open(.autocompleteExclusions) }
            SettingsDrillRow(title: "Usage", detail: "Words accepted and time saved, counted on this Mac",
                             value: stats.usage.isEmpty ? localized("None yet") : nil,
                             identifier: "settings.autocomplete.usage") { open(.autocompleteUsage) }
            SettingsDrillRow(title: "Advanced", detail: "Faster runtime, Chrome-based browsers",
                             identifier: "settings.autocomplete.advanced") { open(.autocompleteAdvanced) }
        }
    }

    private var skippedSummary: String {
        let count = ExclusionRuleCount.count(app.settings.cotypingExcludedApps, app.settings.cotypingExcludedDomains)
        return count == 0 ? localized("None") : String(count)
    }

    // MARK: - The pages the rows open

    private var profileSection: some View {
        Section {
            WritingProfileFields()
            SettingsSwitchRow("Learn locally from accepted completions",
                              detail: "Kept for 30 days and reused only in the same identified document. Mail, chat, unknown documents, and preview runs are excluded.",
                              isOn: $app.settings.cotypingUseLocalLearning)
                .settingTarget("settings.cotypingUseLocalLearning", selected: app.focusedSettingID)
            Button(LocalizedStringKey(forgettingLearning ? "Forgetting…" : "Forget learned text")) {
                forgettingLearning = true
                learningMessage = nil
                Task {
                    defer { forgettingLearning = false }
                    do {
                        try await app.cotyping.forgetLearnedText()
                        learningMessage = "Learned text deleted."
                    } catch {
                        learningMessage = "Could not delete learned text. Please try again."
                    }
                }
            }
            .disabled(forgettingLearning)
            if let learningMessage {
                Text(LocalizedStringKey(learningMessage)).settingsSecondary()
            }
        } footer: {
            SettingsHelp("Dictation’s Compose uses the same profile.")
        }
    }

    private var exclusionsSection: some View {
        Section {
            ExclusionRulesEditor(title: "Never suggest in these apps", value: $app.settings.cotypingExcludedApps,
                                 kind: .applications)
                .settingTarget("settings.cotypingExcludedApps", selected: app.focusedSettingID)
            ExclusionRulesEditor(title: "Never suggest on these sites", value: $app.settings.cotypingExcludedDomains,
                                 kind: .writingDomains)
                .settingTarget("settings.cotypingExcludedDomains", selected: app.focusedSettingID)
            SettingsSwitchRow("Suggest in integrated terminals",
                              isOn: $app.settings.cotypingSuggestInIntegratedTerminals)
                .settingTarget("settings.cotypingSuggestInIntegratedTerminals", selected: app.focusedSettingID)
        }
    }

    /// The statistics and the timings, which were two blocks on the page.
    @ViewBuilder private var usageSections: some View {
        AutocompleteStatisticsView()
        Section("How quickly suggestions arrive") {
            AutocompleteMeasurements(server: server)
        }
    }

    private var advancedSection: some View {
        Section {
            SettingsSwitchRow("Use fast in-process runtime", isOn: $app.settings.cotypingInProcessRuntime)
                .disabled(app.settings.cotypingBackend != .onDevice)
                .settingTarget("settings.cotypingInProcessRuntime", selected: app.focusedSettingID)
            SettingsSwitchRow("Use enhanced accessibility in Chrome-based browsers",
                              isOn: $app.settings.cotypingChromiumEnhancedAccessibility)
                .settingTarget("settings.cotypingChromiumEnhancedAccessibility", selected: app.focusedSettingID)
        }
    }
}
