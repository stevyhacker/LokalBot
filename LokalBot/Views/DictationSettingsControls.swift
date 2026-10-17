import SwiftUI

struct DictationSettingsControls: View {
    @EnvironmentObject private var app: AppState
    @State private var microphones: [DictationMicrophone.Option] = []

    /// Separate Form rows, so each control gets the same row rhythm and
    /// dividers as the rest of Settings.
    var body: some View {
        Group {
            Toggle("Enable dictation shortcut", isOn: $app.settings.dictationEnabled)
                .accessibilityLabel("Enable dictation shortcut")
                .accessibilityIdentifier("settings.dictationEnabled")
                .settingTarget("settings.dictationEnabled", selected: app.focusedSettingID)
            LabeledContent("Shortcut") {
                ShortcutRecorder(
                    shortcut: $app.settings.dictationShortcut,
                    defaultShortcut: .handyDefault,
                    accessibilityIdentifier: "settings.dictationShortcut",
                    changeHelp: "Change the dictation shortcut",
                    validate: { candidate in
                        candidate.problem
                            ?? (candidate == app.settings.quickRecallShortcut ? .usedByAsk : nil)
                            ?? (candidate == app.settings.selectionActionsShortcut ? .usedBySelectionActions : nil)
                    },
                    onRecordingChanged: { app.setShortcutRecording($0) })
            }
            .settingTarget("settings.dictationShortcut", selected: app.focusedSettingID)
            Picker("Trigger", selection: $app.settings.dictationTriggerMode) {
                ForEach(DictationTriggerMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }.settingTarget("settings.dictationTriggerMode", selected: app.focusedSettingID)
            Picker("After a shortcut recording", selection: $app.settings.dictationOutputMode) {
                ForEach(DictationOutputMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }.settingTarget("settings.dictationOutputMode", selected: app.focusedSettingID)
            Picker(selection: $app.settings.dictationMicrophoneID) {
                ForEach(DictationMicrophone.options(
                    preferredID: app.settings.dictationMicrophoneID, available: microphones,
                    defaultName: app.settings.appLanguage.localized("System default"))) { option in
                    Text(LocalizedStringKey(option.name)).tag(option.id)
                }
            } label: {
                SettingsLabel("Microphone", help: "With AirPods, choose the MacBook microphone to keep the headset's audio quality while you dictate.")
            }
            .settingTarget("settings.dictationMicrophoneID", selected: app.focusedSettingID)
            .onAppear { microphones = DictationMicrophone.available() }
            Toggle("Show floating dictation status", isOn: $app.settings.dictationShowOverlay)
                .accessibilityLabel("Show floating dictation status")
                .settingTarget("settings.dictationShowOverlay", selected: app.focusedSettingID)
            Toggle("Play a sound when the microphone is ready", isOn: $app.settings.dictationPlaysStartSound)
                .accessibilityLabel("Play a sound when the microphone is ready")
                .settingTarget("settings.dictationPlaysStartSound", selected: app.focusedSettingID)
            Toggle("Show live transcript", isOn: $app.settings.dictationLivePreview)
                .accessibilityLabel("Show live transcript")
                .settingTarget("settings.dictationLivePreview", selected: app.focusedSettingID)
            Toggle("Keep dictation audio files", isOn: $app.settings.dictationRetainAudio)
                .accessibilityLabel("Keep dictation audio files")
                .settingTarget("settings.dictationRetainAudio", selected: app.focusedSettingID)
        }
    }
}
