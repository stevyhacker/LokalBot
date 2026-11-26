import SwiftUI

struct SampleMeetingSetupSheet: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var modelRoles: ModelRoles
    @State private var downloading = false

    var body: some View {
        let snapshot = modelRoles.snapshot
        let failed = snapshot[.transcribe].errorMessage != nil || snapshot[.think].errorMessage != nil
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(systemImage: "waveform.badge.magnifyingglass", tint: Brand.teal, size: 40)
                Text("Try a sample meeting").font(.scaled(.title3).bold())
            }
            Text("A made-up three-and-a-half-minute call between two synthetic voices. LokalBot transcribes it and writes its notes locally, then answers a question about it and shows the passage the answer came from.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
            SampleMeetingStage(done: snapshot.meetingReady, active: downloading && !failed,
                               title: "Download models")
            VStack(spacing: 8) {
                modelRow("Speech recognition", model: app.settings.transcriptionModelDisplayName,
                         status: snapshot[.transcribe])
                modelRow("Summaries and Ask", model: app.settings.thinkModelDisplayName,
                         status: snapshot[.think])
            }
            .padding(.leading, 24)
            SampleMeetingStage(done: false, active: false, title: "Transcribe the sample")
            SampleMeetingStage(done: false, active: false, title: "Write the notes")
            SampleMeetingStage(done: false, active: false, title: "Ask about it")
            HStack(spacing: 10) {
                Button(failed ? "Retry" : "Download and continue") {
                    downloading = true
                    modelRoles.startCoreModelDownloads(includeAutocomplete: false)
                }
                .buttonStyle(.borderedProminent)
                .disabled(downloading && !failed)
                .accessibilityIdentifier("sample.download")
                Button("Cancel") { app.showsSampleSetup = false }
                    .accessibilityIdentifier("sample.cancel")
            }
            Text("Downloads use the model provider. They do not send your meeting content. Existing downloaded models are kept.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: snapshot.meetingReady) { _, ready in
            if ready && downloading {
                app.showsSampleSetup = false
                if let existing = app.sampleMeeting {
                    app.reprocess(existing, transcribe: true, summarize: true)
                } else {
                    app.importSampleMeeting()
                }
            }
        }
    }

    private func modelRow(_ title: String, model: String, status: ModelRoleStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(.scaled(.callout).weight(.semibold))
                    Text(model).font(.scaled(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(status.label).font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(status.isReady ? Color.green : Color.secondary)
            }
            if status.isWorking {
                ProgressView(value: status.progress)
            }
        }
    }
}

struct SampleMeetingBanner: View {
    @EnvironmentObject var app: AppState
    let meeting: Meeting
    let hasTranscript: Bool
    let hasNotes: Bool
    var isPrecomputed = false

    var body: some View {
        let stage = app.pipeline.stages[meeting.id]
        let transcribing: Bool = switch stage {
        case .queued, .waitingForModels, .preparingTranscriptionModel, .preparingDiarizationModel,
             .transcribing, .diarizing: true
        default: false
        }
        let summarizing: Bool = switch stage {
        case .preparingSummaryModel, .summarizing: true
        default: false
        }
        let modelsReady = app.modelRoles.snapshot.meetingReady
        let question = SampleMeeting.askQuestion(for: meeting, language: app.settings.appLanguage)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Sample meeting", systemImage: "sparkles")
                    .font(.scaled(.headline))
                    .foregroundStyle(Brand.teal)
                if isPrecomputed {
                    Text("Instant preview · 0 MB downloaded")
                        .font(.scaled(.caption).weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .accessibilityIdentifier("meeting.sample.precomputedBadge")
                }
                Spacer()
                if isPrecomputed || modelsReady {
                    Button("Re-run with your local model") {
                        app.rerunSampleMeetingWithLocalModel(meeting)
                    }
                    .controlSize(.small)
                    .disabled(transcribing || summarizing)
                    .help(modelsReady
                          ? "Transcribe and summarize this sample again using your downloaded local models"
                          : "Download your local models to re-run this sample on this Mac")
                    .accessibilityIdentifier("meeting.sample.rerunLocal")
                }
                Button("Remove sample") { app.removeSampleMeeting(meeting) }
                    .controlSize(.small)
                    .accessibilityIdentifier("meeting.sample.remove")
            }
            Text(isPrecomputed
                 ? "The people and the company are made up, and the voices are synthetic. Precomputed notes and cited answers are ready immediately; re-run with your local model once downloads finish."
                 : "The people and the company are made up, and the voices are synthetic. Your day, people, projects and action lists leave it out.")
                .workspaceTextRole(.supporting)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                SampleMeetingStage(done: isPrecomputed || modelsReady, active: false,
                                   title: isPrecomputed ? "Instant preview" : "Download models")
                SampleMeetingStage(done: hasTranscript, active: transcribing, title: "Transcribe the sample")
                SampleMeetingStage(done: hasNotes, active: summarizing, title: "Write the notes")
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Try asking:").font(.scaled(.caption)).foregroundStyle(.secondary)
                    Text(verbatim: question)
                        .font(.scaled(.callout).weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Ask") { app.askSampleQuestion(meeting) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasTranscript)
                    .accessibilityIdentifier("meeting.sample.ask")
            }
        }
        .padding(12)
        .workspaceControl()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.sample")
    }
}

struct SampleMeetingStage: View {
    let done: Bool
    let active: Bool
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if active {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
            Text(LocalizedStringKey(title))
                .font(.scaled(.callout).weight(active ? .semibold : .regular))
                .foregroundStyle(done || active ? .primary : .secondary)
        }
    }
}
