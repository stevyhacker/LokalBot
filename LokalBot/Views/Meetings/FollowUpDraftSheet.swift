import SwiftUI
import AppKit

/// Review, rewrite with the on-device Think model, copy, or save a
/// meeting's follow-up. LokalBot never sends it.
struct FollowUpDraftSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var loaded = false
    @State private var writing = false
    @State private var status: String?
    @State private var error: String?

    private var projection: MeetingOutcomeProjection? { app.outcomeIndex.projection(for: meeting.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Follow-up").font(.scaled(.largeTitle).bold())
            Text("From \(meeting.displayTitle) · \(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))")
                .foregroundStyle(.secondary)
            if projection == nil {
                Text("This meeting has no outcomes yet. Summarize it first.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Subject") {
                    TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                }
                TextEditor(text: $bodyText)
                    .font(.scaled(.body))
                    .frame(minHeight: 260)
                    .padding(6)
                    .workspaceControl()
                    .accessibilityLabel("Follow-up body")
                    .accessibilityIdentifier("followUp.body")
                HStack(spacing: 8) {
                    Button {
                        Task { await write() }
                    } label: {
                        Label(writing ? "Writing…" : "Write with Think", systemImage: "sparkles")
                    }
                    .disabled(writing)
                    .help("Rewrite this outline from the meeting's recap and outcomes with your on-device Think model")
                    Button("Reset to Outline") { reset() }.disabled(writing)
                    Spacer()
                    Button("Copy") { copy() }
                    Button("Save Draft") { save() }.primaryActionButton()
                }
                if let status { Text(status).workspaceTextRole(.supporting) }
                if let error { Text(error).workspaceTextRole(.warning) }
                Text("LokalBot never sends this. Copy it into your mail or chat app to send it yourself.")
                    .workspaceTextRole(.supporting)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let projection else { return }
        loaded = true
        subject = projection.followUp.subject
        bodyText = projection.followUp.body
    }

    private func reset() {
        guard let projection else { return }
        let seeded = FollowUpDraft.seeded(for: meeting, outcomes: projection.activeOutcomes)
        subject = seeded.subject
        bodyText = seeded.body
        status = "Reset to the outline built from this meeting's outcomes."
        error = nil
    }

    private func write() async {
        guard let projection else { return }
        guard UpcomingMeetingLocalGenerationPolicy.permitsLocalGeneration(settings: app.settings) else {
            error = "Choose an on-device Think model to write follow-ups. The outline stays available."
            return
        }
        writing = true
        error = nil
        status = nil
        defer { writing = false }
        let summary = try? String(
            contentsOf: meeting.folderURL(in: app.storage).appendingPathComponent("summary.md"), encoding: .utf8)
        let evidence = FollowUpDraftGenerator.evidence(for: projection, summary: summary)
        do {
            let engine = try await app.thinkExecution.makeTextEngine(
                app.settings, priority: .interactive, purpose: "follow-up draft")
            let draft = try await FollowUpDraftGenerator.generate(evidence: evidence, engine: engine)
            subject = draft.subject
            bodyText = draft.body
            status = "Written on this Mac by \(engine.displayName). Review before sending."
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Subject: \(subject)\n\n\(bodyText)", forType: .string)
        status = "Copied."
    }

    private func save() {
        guard var draft = projection?.followUp else { return }
        draft.subject = subject
        draft.body = bodyText
        if app.outcomeIndex.saveFollowUp(draft, meetingID: meeting.id) {
            status = "Saved with this meeting."
            error = nil
        } else {
            error = app.outcomeIndex.lastError ?? "The draft could not be saved."
        }
    }
}
