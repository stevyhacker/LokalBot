import SwiftUI

/// Selects one integrity-pinned Granite Speech GGUF and its matching projector
/// from a public Hugging Face repository. Generic ASR checkpoints are excluded:
/// LokalBot's Granite path requires llama.cpp's audio-capable GGUF format.
struct GraniteSpeechModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: GraniteSpeechModelConfiguration

    @StateObject private var huggingFace = HuggingFaceSearchService()
    @State private var repository: String
    @State private var files: [HFFile] = []
    @State private var selectedModelPath: String
    @State private var selectedProjectorPath: String
    @State private var isLoading = false
    @State private var localError: String?

    init(selection: Binding<GraniteSpeechModelConfiguration>) {
        _selection = selection
        let current = selection.wrappedValue
        _repository = State(initialValue: current.repository)
        _selectedModelPath = State(initialValue: current.model.path)
        _selectedProjectorPath = State(initialValue: current.projector.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose a llama.cpp-compatible Granite Speech model and its matching multimodal projector. This supports alternate quantizations such as Q8; ordinary Hugging Face ASR safetensors are not compatible.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("owner/repository", text: $repository)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await loadFiles() } }
                        .accessibilityIdentifier("models.granite.repository")
                    Button(isLoading ? "Loading…" : "Load files") {
                        Task { await loadFiles() }
                    }
                    .disabled(isLoading || repository.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                    if isLoading { ProgressView().controlSize(.small) }
                }

                if !modelFiles.isEmpty || !projectorFiles.isEmpty {
                    Picker("Model GGUF", selection: $selectedModelPath) {
                        ForEach(modelFiles) { file in
                            Text(fileLabel(file)).tag(file.id)
                        }
                    }
                    .accessibilityIdentifier("models.granite.modelFile")

                    Picker("Projector GGUF", selection: $selectedProjectorPath) {
                        ForEach(projectorFiles) { file in
                            Text(fileLabel(file)).tag(file.id)
                        }
                    }
                    .accessibilityIdentifier("models.granite.projectorFile")

                    if let candidateConfiguration {
                        LabeledContent("Download") {
                            Text(candidateConfiguration.downloadDescription)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Pinned revision") {
                            Text(String(candidateConfiguration.revision.prefix(12)))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Brand.error)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 0)
                Divider()
                footer
            }
            .padding(16)
        }
        .frame(width: 650, height: 430)
        .task { await loadFiles() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Custom Granite Speech model")
                    .font(.headline)
                    .accessibilityIdentifier("models.granite.picker.title")
                Text("Hugging Face GGUF + projector")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button("Use default Q4_K_M") {
                selection = .defaultModel
                dismiss()
            }
            .disabled(selection.isDefault)
            Spacer()
            Button("Use selected model") { applySelection() }
                .primaryActionButton()
                .keyboardShortcut(.defaultAction)
                .disabled(candidateConfiguration == nil)
                .accessibilityIdentifier("models.granite.useSelected")
        }
    }

    private var modelFiles: [HFFile] {
        files.filter { !$0.id.localizedCaseInsensitiveContains("mmproj") }
    }

    private var projectorFiles: [HFFile] {
        files.filter { $0.id.localizedCaseInsensitiveContains("mmproj") }
    }

    private var selectedModel: HFFile? {
        modelFiles.first { $0.id == selectedModelPath }
    }

    private var selectedProjector: HFFile? {
        projectorFiles.first { $0.id == selectedProjectorPath }
    }

    private var candidateConfiguration: GraniteSpeechModelConfiguration? {
        guard let model = selectedModel,
              let projector = selectedProjector,
              model.modelID == projector.modelID,
              model.revision == projector.revision,
              let modelSize = model.sizeBytes.flatMap(Int64.init(exactly:)),
              let projectorSize = projector.sizeBytes.flatMap(Int64.init(exactly:)),
              let modelSHA256 = model.sha256,
              let projectorSHA256 = projector.sha256 else { return nil }
        return try? GraniteSpeechModelConfiguration(
            repository: model.modelID,
            revision: model.revision,
            model: .init(path: model.id, sizeBytes: modelSize, sha256: modelSHA256),
            projector: .init(
                path: projector.id,
                sizeBytes: projectorSize,
                sha256: projectorSHA256))
    }

    private var errorMessage: String? {
        localError ?? huggingFace.errorMessage
    }

    private func fileLabel(_ file: HFFile) -> String {
        guard let size = file.sizeLabel else { return file.id }
        return "\(file.id) — \(size)"
    }

    @MainActor
    private func loadFiles() async {
        guard !isLoading else { return }
        isLoading = true
        localError = nil
        defer { isLoading = false }

        let requestedRepository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let loaded = await huggingFace.ggufFiles(for: requestedRepository)
        files = loaded
        guard !loaded.isEmpty else { return }

        let availableModels = loaded.filter {
            !$0.id.localizedCaseInsensitiveContains("mmproj")
        }
        let availableProjectors = loaded.filter {
            $0.id.localizedCaseInsensitiveContains("mmproj")
        }
        guard !availableModels.isEmpty else {
            localError = "This repository has no model GGUF."
            return
        }
        guard !availableProjectors.isEmpty else {
            localError = "This repository has no mmproj projector GGUF."
            return
        }

        if !availableModels.contains(where: { $0.id == selectedModelPath }) {
            selectedModelPath = availableModels[0].id
        }
        if !availableProjectors.contains(where: { $0.id == selectedProjectorPath }) {
            selectedProjectorPath = availableProjectors.first(where: {
                $0.id.localizedCaseInsensitiveContains("f16")
            })?.id ?? availableProjectors[0].id
        }
        if candidateConfiguration == nil {
            localError = GraniteSpeechModelConfiguration.ValidationError
                .invalidIntegrityMetadata.localizedDescription
        }
    }

    private func applySelection() {
        guard let candidateConfiguration else {
            localError = GraniteSpeechModelConfiguration.ValidationError
                .invalidIntegrityMetadata.localizedDescription
            return
        }
        selection = candidateConfiguration
        dismiss()
    }
}
