import SwiftUI

/// The empty-state card shown when no meeting is selected. Orients around the
/// four product moves (remember → recall → write → act) and one-tap setup
/// steps, so a brand-new user lands somewhere useful instead of a blank pane.
/// Dismissed once and remembered via `@AppStorage`.
struct GettingStartedCard: View {
    @EnvironmentObject var app: AppState
    @AppStorage("lokalbotv3.gettingStartedDismissed") private var dismissed = false

    // First-checklist-item state: front-load the transcription model download
    // so it doesn't ambush the user's first recap.
    @State private var modelDownloaded = false
    @State private var preparingModel = false
    @State private var modelProgress: Double?
    @State private var modelStatus: String?
    @State private var modelError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroPanel(radius: Brand.Radius.card) {
                    HStack(spacing: 14) {
                        IconTile(systemImage: "waveform.badge.magnifyingglass",
                                 tint: Brand.tealFill, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Welcome to LokalBot").font(.title2.bold())
                                .foregroundStyle(.white)
                            Text("Your private AI memory for work — on-device by default.")
                                .font(.callout).foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Button { dismissed = true } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3).foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                        .accessibilityIdentifier("welcome.dismiss")
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    pillar("waveform", "Remember",
                           app.isRecording ? "Recording now…" : "Capture meetings and the day context you choose.",
                           isRecording: app.isRecording)
                    pillar("sparkle.magnifyingglass", "Ask",
                           "Search, ask, and open the evidence behind an answer.", isRecording: nil)
                    pillar("keyboard", "Write",
                           "Dictate or autocomplete text in the app where you're working.", isRecording: nil)
                    pillar("arrow.up.forward.app", "Act",
                           "Create inspectable drafts, exports, and approved agent sessions.", isRecording: nil)
                }

                Text("Get started").font(.headline)
                VStack(alignment: .leading, spacing: 10) {
                    stepRow(done: modelDownloaded ? true : nil) {
                        modelStep
                    }
                    stepRow(done: app.isRecording || !app.meetings.isEmpty) {
                        Text("Record a meeting — it appears in the list automatically.")
                    }
                    stepRow(done: nil) {
                        HStack(spacing: 8) {
                            Button("Turn on day tracking") {
                                app.navSection = .timeline
                            }
                                .buttonStyle(.bordered).controlSize(.small)
                            Text("to see where your time goes.")
                        }
                    }
                    stepRow(done: app.settings.cotypingEnabled ? true : nil) {
                        HStack(spacing: 8) {
                            Button("Try autocomplete") { app.openType(.cotyping) }
                                .buttonStyle(.bordered).controlSize(.small)
                            Text("— inline AI autocomplete that stays on your Mac.")
                        }
                    }
                }
                .padding(WorkspaceMetric.cardPadding)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.panel))

                Text("Tip: press ⌘K anywhere to record, navigate, or jump to a meeting.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(WorkspaceMetric.pagePadding)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            modelDownloaded = TranscriptionModelStore.downloadedChoices(
                graniteConfiguration: app.settings.graniteSpeechModel)
                .contains(app.settings.transcriptionModel.id)
        }
    }

    /// Checklist item 1: get the transcription model onto disk before the
    /// first recap needs it. `prepare` is idempotent, so racing a first
    /// transcription is harmless.
    @ViewBuilder private var modelStep: some View {
        if modelDownloaded {
            Text("Transcription model ready — recaps run entirely on-device.")
        } else if preparingModel {
            HStack(spacing: 8) {
                ProgressView(value: modelProgress).frame(width: 160)
                Text(modelStatus ?? "Downloading…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button("Download the transcription model") { downloadModel() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Text("one-time — or it downloads with your first recap.")
                }
                if let modelError {
                    Text(modelError).font(.caption).foregroundStyle(Brand.error)
                }
            }
        }
    }

    private func downloadModel() {
        guard !preparingModel else { return }
        preparingModel = true
        modelError = nil
        let config = app.settings
        let engine = config.transcriptionEngine()
        Task { @MainActor in
            defer { preparingModel = false }
            do {
                try await engine.prepare { update in
                    modelProgress = update.fractionCompleted
                    modelStatus = update.status
                }
                modelDownloaded = true
            } catch {
                modelError = error.localizedDescription
            }
        }
    }

    private func pillar(_ icon: String, _ title: String, _ body: String,
                        isRecording: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(isRecording == true ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.tint))
            Text(title).font(.headline)
            Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
    }

    /// `done`: nil = actionable (hollow circle), true/false = checkmark/number.
    private func stepRow<S: View>(done: Bool?, @ViewBuilder _ content: () -> S) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done == true ? Color.green : Brand.teal)
                .padding(.top, 2)
            content().font(.callout)
        }
    }
}
