import SwiftUI

struct ModelPresetSheet: View {
    @ObservedObject var app: AppState
    @ObservedObject private var setup: ModelSetupController
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ModelStackPreset.recommended

    init(app: AppState) {
        self.app = app
        setup = app.modelSetup
    }

    private var target: AppSettings { selected.patch.applying(to: app.settings) }
    private var estimatedDownload: Int64 {
        let gguf = selected.patch.localModelIDs(in: app.settings).compactMap {
            ModelCatalog.entry(id: $0, custom: app.settings.customBuiltInModels)
        }.filter { ModelCatalog.localURL(for: $0, storage: app.storage) == nil }
            .reduce(Int64(0)) { $0 + ($1.sizeBytes ?? 0) }
        let transcription = TranscriptionModelStore.isDownloaded(selected.transcription)
            ? 0 : ModelSettingsPresentation.estimatedTranscriptionBytes(selected.transcription, granite: app.settings.graniteSpeechModel) ?? 0
        return gguf + transcription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelSheetHeading(title: "Choose a local setup", subtitle: "Review the model changes before applying a preset.")
            VStack(alignment: .leading, spacing: 22) {
                Picker("Preset", selection: $selected) {
                    ForEach(ModelStackPreset.allCases) { preset in
                        Text(preset.title + " — " + preset.subtitle).tag(preset)
                    }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .accessibilityIdentifier("models.preset.choice")
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 16) {
                    GridRow {
                        Text("Feature")
                        Text("Current")
                        Text("After applying")
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    previewRow("Transcription", before: app.settings.transcriptionModelDisplayName,
                               after: selected.transcription.displayName)
                    previewRow("Think", before: ModelSettingsPresentation.assistantName(app.settings),
                               after: ModelSettingsPresentation.assistantName(target))
                    previewRow("Autocomplete", before: name(app.settings.cotypingBuiltInModelID),
                               after: name(selected.autocompleteModelID))
                }
                .font(.system(size: 13))
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Label("All three core models will run on this Mac.", systemImage: "desktopcomputer")
                    if app.settings.dictationCompositionBuiltInModelID.isEmpty {
                        Text("Dictation composition follows Think and will also run locally.")
                    }
                    Text("Estimated new download: " + ByteCountFormatter.string(fromByteCount: estimatedDownload, countStyle: .file))
                        .fontWeight(.medium)
                    Text("Existing models are kept. Your current setup stays active until preparation finishes. You can undo the switch.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13))
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(estimatedDownload > 0 ? "Download and apply" : "Apply preset") {
                    setup.apply(selected.patch, title: selected.title)
                    dismiss()
                }
                .primaryActionButton().keyboardShortcut(.defaultAction)
                .disabled(setup.pending != nil)
                .accessibilityIdentifier("models.preset.apply")
            }
            .padding(20)
        }
        .frame(width: 720)
    }

    private func previewRow(_ title: String, before: String, after: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).fontWeight(.medium)
            Text(before).foregroundStyle(.secondary)
            Text(after).fontWeight(before == after ? .regular : .semibold)
        }
    }
    private func name(_ id: String) -> String {
        ModelCatalog.entry(id: id, custom: app.settings.customBuiltInModels)?.displayName ?? id
    }
}
