import SwiftUI
import AVFoundation

struct ModelSpeechSettingsSheet: View {
    @ObservedObject var app: AppState
    @ObservedObject private var download: ModelSpeechDownloadController
    @Environment(\.dismiss) private var dismiss
    @State private var sampleTask: Task<Void, Never>?
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var sampleError: String?
    @State private var generation = UUID()

    init(app: AppState) {
        self.app = app
        download = app.speechModelDownload
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelSheetHeading(title: "Read aloud", subtitle: "Read summaries and answers using a voice on this Mac.")
            VStack(alignment: .leading, spacing: 20) {
                LabeledContent("Model") { Text("Kokoro 82M").foregroundStyle(.secondary) }
                Picker("Voice", selection: $app.settings.speechVoice) {
                    ForEach(KokoroVoice.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("models.speech.voice")
                HStack(spacing: 12) {
                    Text("Speed").frame(width: 60, alignment: .leading)
                    Slider(value: $app.settings.speechSpeed,
                           in: AppSettings.minimumSpeechSpeed...AppSettings.maximumSpeechSpeed, step: 0.05)
                        .accessibilityLabel("Speech speed")
                    Text(String(format: "%.2g×", app.settings.speechSpeed)).monospacedDigit().frame(width: 42)
                }
                HStack {
                    if download.isDownloaded {
                        Button(playing ? "Stop sample" : "Play sample") {
                            if playing { stopSample() } else { playSample() }
                        }
                        .accessibilityIdentifier("models.speech.sample")
                    } else if download.isPreparing {
                        ProgressView().controlSize(.small)
                        Text(download.status ?? "Preparing voice…").foregroundStyle(.secondary)
                        Button("Cancel") { download.cancel() }
                    } else {
                        Button("Download voice model") { download.download() }
                            .primaryActionButton()
                    }
                }
                Text(download.isDownloaded ? "Downloaded. Voice synthesis runs locally."
                     : "Download once to use this voice offline.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let error = sampleError ?? download.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                }
            }
            .font(.system(size: 14)).padding(.horizontal, 24).padding(.bottom, 24)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(20)
        }
        .frame(width: 580)
        .onAppear { download.refresh() }
        .onDisappear { stopSample() }
    }

    private func playSample() {
        let token = UUID()
        generation = token
        playing = true
        sampleError = nil
        let voice = app.settings.speechVoice
        let speed = app.settings.speechSpeed
        sampleTask = Task {
            defer {
                if generation == token {
                    playing = false
                    player?.stop()
                    player = nil
                    sampleTask = nil
                }
            }
            do {
                let url = try await KokoroSpeechEngine.shared.synthesize(.init(
                    text: "Here is a sample of LokalBot's voice. Your summaries can be read aloud on this Mac.",
                    voice: voice, speed: speed, outputURL: nil))
                defer { try? FileManager.default.removeItem(at: url) }
                try Task.checkCancellation()
                guard generation == token else { return }
                let sample = try AVAudioPlayer(contentsOf: url)
                player = sample
                guard sample.play() else {
                    throw ModelDownloadManager.PreparationError.failed("Could not start audio playback.")
                }
                try await Task.sleep(for: .seconds(max(0.1, sample.duration)))
            } catch is CancellationError {
            } catch {
                if generation == token { sampleError = error.localizedDescription }
            }
        }
    }

    private func stopSample() {
        generation = UUID()
        sampleTask?.cancel()
        sampleTask = nil
        player?.stop()
        player = nil
        playing = false
    }
}

struct ModelTranscriptionOptionsSheet: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelSheetHeading(title: "Language & vocabulary", subtitle: "Options for the transcription model currently in use.")
            VStack(alignment: .leading, spacing: 18) {
                Text(app.settings.transcriptionModelDisplayName).font(.system(size: 14, weight: .semibold))
                Picker("Language", selection: $app.settings.transcriptionLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(app.settings.transcriptionModel == .graniteTurbo)
                .settingTarget("settings.transcriptionLanguage", selected: app.focusedSettingID)
                if app.settings.transcriptionModel == .graniteTurbo {
                    Text("This model supports English only and does not use vocabulary prompts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Names and vocabulary").font(.system(size: 13, weight: .medium))
                        TextField("Names, acronyms, and domain vocabulary", text: $app.settings.transcriptionPrompt, axis: .vertical)
                            .lineLimit(3...6).textFieldStyle(.roundedBorder)
                            .settingTarget("settings.transcriptionPrompt", selected: app.focusedSettingID)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(20)
        }
        .frame(width: 600)
    }
}

struct ModelSearchSettingsSheet: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelSheetHeading(title: "Search by meaning", subtitle: "Find related work even when the words are different.")
            VStack(alignment: .leading, spacing: 20) {
                Toggle("Enable search by meaning", isOn: $app.settings.semanticSearchEnabled)
                LabeledContent("Model") { Text("Harrier 0.6B · On this Mac").foregroundStyle(.secondary) }
                Text("The model downloads when semantic search is first used. Meeting text and text captured from your screen are indexed locally.")
                Text("LokalBot manages this model and rebuilds the local index when it changes.")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13)).padding(.horizontal, 24).padding(.bottom, 24)
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(20)
        }
        .frame(width: 580)
    }
}
