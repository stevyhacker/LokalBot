import SwiftUI

/// The first-day steps. On a day with nothing to show yet they are Today's
/// content; after that they stay under the day until hidden. Hiding is
/// remembered via `@AppStorage`.
struct GettingStartedCard: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("lokalbotv3.gettingStartedDismissed") private var dismissed = false

    // Transcription-model step: front-load the download so it doesn't
    // ambush the user's first recap.
    @State private var modelDownloaded = false
    @State private var preparingModel = false
    @State private var modelProgress: Double?
    @State private var modelStatus: String?
    @State private var modelError: String?

    private var calendarConnected: Bool {
        app.settings.calendarDetectionEnabled && app.calendar.authorizationStatus == .fullAccess
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Get started").font(TodayType.cardTitleCompact)
                Spacer(minLength: 8)
                Button("Hide") { dismissed = true }
                    .buttonStyle(.workspaceLink)
                    .font(AppFont.scaled(.callout))
                    .help("Dismiss")
                    .accessibilityIdentifier("welcome.dismiss")
            }
            VStack(spacing: 0) {
                step(done: app.isRecording || app.meetings.contains(where: \.isOwnWork)) {
                    Text("Record or import your first meeting")
                } actions: {
                    Button {
                        app.startRecording(context: app.recordingContext(for: app.detector.activeApp))
                    } label: {
                        Label {
                            Text("Record")
                        } icon: {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(LBTokens.Palette.recording)
                        }
                    }
                    .disabled(app.isRecording)
                    .accessibilityIdentifier("welcome.record")
                    Button("Import Recording…") { RecordingImportPanel.choose(into: app) }
                        .accessibilityIdentifier("welcome.importRecording")
                }
                Divider()
                step(done: app.sampleMeeting != nil) {
                    Text("Try the sample meeting")
                } actions: {
                    Button("Open sample") { app.trySampleMeeting() }
                        .accessibilityIdentifier("welcome.trySample")
                }
                Divider()
                step(done: calendarConnected) {
                    Text("Show your next meeting here")
                } actions: {
                    if !calendarConnected {
                        Button("Connect Calendar…") {
                            app.openSettings(tab: .recording)
                            app.focusedSettingID = "settings.calendarDetectionEnabled"
                        }
                        .accessibilityIdentifier("welcome.connectCalendar")
                    }
                }
                Divider()
                step(done: false) {
                    Text("See where your time goes")
                } actions: {
                    Button("Turn on day tracking") { app.navSection = .timeline }
                }
                Divider()
                step(done: app.settings.cotypingEnabled) {
                    Text("Try autocomplete")
                } actions: {
                    Button("Try it") { app.openType(.cotyping) }
                }
                Divider()
                step(done: modelDownloaded) {
                    modelLabel
                } actions: {
                    modelAction
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todayCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.gettingStarted")
        .recordingImportDropTarget(app)
        .onAppear {
            modelDownloaded = TranscriptionModelStore.downloadedChoices(
                graniteConfiguration: app.settings.graniteSpeechModel,
                remoteTranscriptionReady: app.settings.remoteTranscription.isReady)
                .contains(app.settings.transcriptionModel.id)
        }
    }

    /// Get the transcription model onto disk before the first recap needs it.
    /// `prepare` is idempotent, so racing a first transcription is harmless.
    @ViewBuilder private var modelLabel: some View {
        if modelDownloaded {
            Text(app.settings.transcriptionModel.isRemote
                 ? "Transcription server ready."
                 : "Transcription model ready — recaps run entirely on-device.")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Download the transcription model")
                if let modelError {
                    Text(modelError).font(.scaled(.callout)).foregroundStyle(Brand.error)
                }
            }
        }
    }

    @ViewBuilder private var modelAction: some View {
        if preparingModel {
            HStack(spacing: 8) {
                ProgressView(value: modelProgress).frame(width: 120)
                Text(modelStatus ?? "Downloading…")
                    .font(.scaled(.callout)).foregroundStyle(.secondary)
            }
        } else if !modelDownloaded {
            Button("Download") { downloadModel() }
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

    /// A hollow circle until the step is done, its words, and its buttons at
    /// the trailing edge. A narrow page puts the buttons under the words.
    private func step<Words: View, Actions: View>(
        done: Bool,
        @ViewBuilder _ words: () -> Words,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let words = words()
        let actions = HStack(spacing: 8) { actions() }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: LBTokens.Metric.actionToggleSize - 1))
                .foregroundStyle(done ? LBTokens.Palette.successText : LBTokens.Palette.accentText)
                .contentTransition(.symbolEffect(.replace))
                .animation(WorkspaceMotion.animation(.milestone, reduceMotion: reduceMotion), value: done)
                .accessibilityLabel("Done")
                .accessibilityHidden(!done)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    words.frame(maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    words
                    actions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.scaled(.body))
        .padding(.vertical, 10)
    }
}
