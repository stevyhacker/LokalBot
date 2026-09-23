import SwiftUI

struct ModelDownloadsView: View {
    @ObservedObject var app: AppState
    @ObservedObject private var roles: ModelRoles
    @ObservedObject private var setup: ModelSetupController
    @ObservedObject private var speech: ModelSpeechDownloadController
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var query = ""
    @State private var unusedOnly = false
    @State private var removal: Removal?

    private enum Removal: Identifiable {
        case text(ModelCatalog.Entry)
        case transcription(TranscriptionModelChoice)
        case speech

        var id: String {
            switch self {
            case .text(let entry): entry.id
            case .transcription(let choice): choice.id
            case .speech: "kokoro"
            }
        }
        var title: String {
            switch self {
            case .text(let entry): entry.displayName
            case .transcription(let choice): choice.displayName
            case .speech: "Kokoro 82M"
            }
        }
    }

    init(app: AppState) {
        self.app = app
        roles = app.modelRoles
        setup = app.modelSetup
        speech = app.speechModelDownload
    }

    private var entries: [ModelCatalog.Entry] {
        let ids = Set((ModelCatalog.entries + app.settings.customBuiltInModels).map(\.id))
        return ids.compactMap { ModelCatalog.entry(id: $0, custom: app.settings.customBuiltInModels) }
            .filter { entry in
                let visible = ModelCatalog.localURL(for: entry, storage: app.storage) != nil
                    || downloads.progress[entry.id] != nil || downloads.errors[entry.id] != nil
                return visible && matches(entry.displayName)
                    && (!unusedOnly || ModelSettingsPresentation.uses(of: entry.id, in: app.settings).isEmpty)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var transcriptionChoices: [TranscriptionModelChoice] {
        TranscriptionModelChoice.allCases.filter { choice in
            (roles.downloadedTranscriptionModelIDs.contains(choice.id)
             || roles.transcriptionPreparations[choice.id] != nil || roles.transcriptionErrors[choice.id] != nil)
                && matches(choice.displayName)
                && (!unusedOnly || choice != app.settings.transcriptionModel)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Models on this Mac").font(.system(size: 16, weight: .semibold))
                Text("Manage downloads and free up disk space. Each model shows the features that use it.")
                    .font(.system(size: 13)).settingsSecondary()
            }
            HStack(spacing: 14) {
                TextField("Find a downloaded model", text: $query).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("models.downloads.search")
                Toggle("Only unused", isOn: $unusedOnly).toggleStyle(.checkbox).font(.system(size: 12))
            }
            if !entries.isEmpty {
                sectionTitle("Text models")
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        textRow(entry)
                        Divider()
                    }
                }
            }
            if !transcriptionChoices.isEmpty {
                sectionTitle("Transcribe")
                VStack(spacing: 0) {
                    ForEach(transcriptionChoices) { choice in
                        transcriptionRow(choice)
                        Divider()
                    }
                }
            }
            if !unusedOnly, matches("Kokoro Read aloud Speech"),
               speech.isDownloaded || speech.isPreparing || speech.error != nil {
                sectionTitle("Read aloud")
                speechRow
            }
            if !unusedOnly, matches("Harrier Search by meaning") {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").settingsModelIcon().frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Harrier 0.6B").font(.system(size: 14, weight: .medium))
                        Text("Search by meaning · Managed automatically")
                            .font(.system(size: 12)).settingsSecondary()
                    }
                    Spacer()
                    Text(app.settings.semanticSearchEnabled ? "Search enabled" : "Search off")
                        .font(.system(size: 12)).settingsSecondary()
                }
                .padding(.vertical, 12)
            }
            if entries.isEmpty && transcriptionChoices.isEmpty && unusedOnly {
                ContentUnavailableView("No unused models", systemImage: "checkmark.circle",
                                       description: Text("Models assigned to a feature are kept out of this list."))
            } else if !query.isEmpty, entries.isEmpty, transcriptionChoices.isEmpty,
                      !matches("Kokoro Read aloud Speech"), !matches("Harrier Search by meaning") {
                ContentUnavailableView.search(text: query)
            }
        }
        .padding(18)
        .settingsPanel()
        .onAppear { speech.refresh() }
        .alert("Remove downloaded model?", isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Remove download", role: .destructive) { removeSelected() }
            Button("Cancel", role: .cancel) { removal = nil }
        } message: {
            if let removal {
                Text("Remove the downloaded files for \(removal.title)? \(usageMessage(removal)) Your recordings and transcripts are kept.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("models.downloads")
    }

    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).settingsSecondary()
    }

    private func textRow(_ entry: ModelCatalog.Entry) -> some View {
        let uses = ModelSettingsPresentation.uses(of: entry.id, in: app.settings)
        let available = ModelCatalog.localURL(for: entry, storage: app.storage) != nil
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "shippingbox").settingsModelIcon().frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.displayName).font(.system(size: 14, weight: .medium))
                Text(ModelSettingsPresentation.sizeLabel(entry) + " · "
                     + (uses.isEmpty ? "Not assigned" : uses.joined(separator: ", ")))
                    .font(.system(size: 12)).settingsSecondary()
                if let error = downloads.errors[entry.id] {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let progress = downloads.progress[entry.id] {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: progress).frame(width: 100)
                    Text(progress >= 1 ? "Verifying…" : "\(Int(progress * 100))%")
                        .font(.system(size: 11)).settingsSecondary()
                }
                Button("Cancel") { downloads.cancel(entry) }
            } else if available {
                Button("Remove…") { removal = .text(entry) }
                    .disabled(setup.pending != nil)
                    .accessibilityIdentifier("models.downloads.remove.\(entry.id)")
            } else {
                Button("Retry") { downloads.download(entry, storage: app.storage) }
            }
        }
        .padding(.vertical, 14)
    }

    private func transcriptionRow(_ choice: TranscriptionModelChoice) -> some View {
        let status = roles.transcriptionStatus(for: choice)
        return HStack(spacing: 12) {
            Image(systemName: "waveform").settingsModelIcon().frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(choice == .graniteSpeech ? app.settings.graniteSpeechModel.displayName : choice.displayName)
                    .font(.system(size: 14, weight: .medium))
                Text(choice == app.settings.transcriptionModel ? "Used by Transcription" : "Not assigned")
                    .font(.system(size: 12)).settingsSecondary()
                if let error = status.errorMessage {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if status.isWorking {
                VStack(alignment: .trailing, spacing: 4) {
                    if let progress = status.progress { ProgressView(value: progress).frame(width: 100) }
                    Text(status.label).font(.system(size: 11)).settingsSecondary()
                }
                Button("Cancel") { roles.cancelTranscriptionPreparation(choice) }
            } else if status.errorMessage != nil {
                Button("Retry") { roles.prepareTranscriptionModel(choice) }
            } else {
                Button("Remove…") { removal = .transcription(choice) }.disabled(setup.pending != nil)
            }
        }
        .padding(.vertical, 14)
    }

    private var speechRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2").settingsModelIcon().frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text("Kokoro 82M").font(.system(size: 14, weight: .medium))
                Text(speech.status ?? "Used by Read aloud").font(.system(size: 12)).settingsSecondary()
                if let error = speech.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            }
            Spacer()
            if speech.isPreparing {
                if let progress = speech.progress { ProgressView(value: progress).frame(width: 100) }
                Button("Cancel") { speech.cancel() }
            } else if speech.isDownloaded {
                Button("Remove…") { removal = .speech }
            } else {
                Button("Retry") { speech.download() }
            }
        }
        .padding(.vertical, 12)
    }

    private func usageMessage(_ removal: Removal) -> String {
        switch removal {
        case .text(let entry):
            let uses = ModelSettingsPresentation.uses(of: entry.id, in: app.settings)
            return uses.isEmpty ? "You can download it again later."
                : "\(uses.joined(separator: ", ")) will need this model downloaded again."
        case .transcription(let choice):
            return choice == app.settings.transcriptionModel
                ? "Transcription will need this model downloaded again." : "You can download it again later."
        case .speech: return "Read aloud will need this model downloaded again."
        }
    }

    private func removeSelected() {
        guard let removal else { return }
        switch removal {
        case .text(let entry):
            roles.deleteGGUFModel(entry)
            var affected: Set<ModelRole> = []
            if app.settings.summarizerBackend == .builtIn, app.settings.builtInModelID == entry.id { affected.insert(.think) }
            if app.settings.cotypingBuiltInModelID == entry.id { affected.insert(.autocomplete) }
            app.modelChecks.invalidate(affected)
        case .transcription(let choice):
            roles.deleteTranscriptionModel(choice)
            if app.settings.transcriptionModel == choice { app.modelChecks.invalidate([.transcribe]) }
        case .speech: speech.delete()
        }
        self.removal = nil
    }
}
