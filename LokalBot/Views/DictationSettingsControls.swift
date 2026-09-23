import SwiftUI

struct DictationSettingsControls: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable dictation shortcut", isOn: $app.settings.dictationEnabled)
                .accessibilityLabel("Enable dictation shortcut")
                .accessibilityIdentifier("settings.dictationEnabled")
                .settingTarget("settings.dictationEnabled", selected: app.focusedSettingID)
            LabeledContent("Shortcut", value: DictationShortcut.label)
            Picker("Trigger", selection: $app.settings.dictationTriggerMode) {
                ForEach(DictationTriggerMode.allCases) { Text($0.label).tag($0) }
            }.settingTarget("settings.dictationTriggerMode", selected: app.focusedSettingID)
            Picker("After a shortcut recording", selection: $app.settings.dictationOutputMode) {
                ForEach(DictationOutputMode.allCases) { Text($0.label).tag($0) }
            }.settingTarget("settings.dictationOutputMode", selected: app.focusedSettingID)
            Toggle("Show floating dictation status", isOn: $app.settings.dictationShowOverlay)
                .accessibilityLabel("Show floating dictation status")
                .settingTarget("settings.dictationShowOverlay", selected: app.focusedSettingID)
            Toggle("Show live transcript", isOn: $app.settings.dictationLivePreview)
                .accessibilityLabel("Show live transcript")
                .settingTarget("settings.dictationLivePreview", selected: app.focusedSettingID)
            Toggle("Keep dictation audio files", isOn: $app.settings.dictationRetainAudio)
                .accessibilityLabel("Keep dictation audio files")
                .settingTarget("settings.dictationRetainAudio", selected: app.focusedSettingID)
        }
    }
}
