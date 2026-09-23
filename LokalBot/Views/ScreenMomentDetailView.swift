import SwiftUI

/// Timeline's detail inspector for one exact captured moment.
struct ScreenMomentDetailView: View {
    @EnvironmentObject private var app: AppState

    let screenshot: ActivityStore.Screenshot
    let onReload: () -> Void
    let onClear: () -> Void
    let backLabel: String
    let onDismiss: (() -> Void)?

    @State private var note = ""
    @State private var confirmingDeletion = false
    @State private var detailsExpanded = false
    @State private var fullTextExpanded = false
    @State private var showingImage = false

    @State private var capturedText = ""
    @State private var textRevision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if screenshot.hasPixels {
                    ScreenThumbnailView(
                        screenshot: screenshot,
                        height: 200,
                        contentMode: .fit,
                        cornerRadius: Brand.Radius.panel)
                        .background(.black.opacity(0.82),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                    Button("Open image · zoom and actual size") { showingImage = true }
                } else {
                    Label("This moment retained text context without screen pixels.",
                          systemImage: "text.viewfinder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(WorkspaceMetric.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                }
                if !screenshot.windowTitle.isEmpty {
                    Text(screenshot.windowTitle)
                        .font(WorkspaceTypography.bodyEmphasis)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if !capturedText.isEmpty { capturedTextSection }
                actions
                if screenshot.isBookmarked {
                    savedNote
                }
                WorkspaceDisclosure(
                    isExpanded: $detailsExpanded,
                    identifier: "timeline.screenDetail.captureDetails") {
                        metadata
                    } label: {
                        Label("Capture details", systemImage: "info.circle")
                            .font(WorkspaceTypography.sectionTitle)
                    }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: loadNote)
        .onReceive(NotificationCenter.default.publisher(for: .retainedScreenTextChanged)) { _ in
            capturedText = ""
            textRevision &+= 1
        }
        .task(id: "\(screenshot.id)|\(textRevision)") {
            capturedText = ""
            let id = screenshot.id
            let text = await ActivityStore.readInBackground(at: app.activityStore.databaseURL) {
                $0.ocrText(snapshotID: id, maxChars: Int.max) ?? ""
            }
            guard !Task.isCancelled else { return }
            capturedText = text
        }
        .sheet(isPresented: $showingImage) { ScreenImageViewer(screenshot: screenshot) }
        .confirmationDialog("Delete this context moment?", isPresented: $confirmingDeletion) {
            Button("Delete context moment", role: .destructive, action: deleteCapture)
        } message: {
            Text("This permanently removes its pixels, captured text, and metadata.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onClear) {
                Image(systemName: "arrow.left")
            }
            .buttonStyle(.plain)
            .help(backLabel)
            .accessibilityLabel(backLabel)
            .accessibilityIdentifier("timeline.screenDetail.backToDayOverview")
            IconTile(systemImage: screenshot.hasPixels ? "camera.viewfinder" : "text.viewfinder",
                     tint: Brand.tealFill, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(screenshot.app)
                    .font(WorkspaceTypography.conversationTitle)
                    .accessibilityIdentifier("timeline.screenDetail.\(screenshot.id)")
                Text(screenshot.ts.formatted(date: .abbreviated, time: .standard))
                    .font(WorkspaceTypography.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close context panel")
                .accessibilityLabel("Close context panel")
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !screenshot.windowTitle.isEmpty {
                LabeledContent("Window") {
                    Text(screenshot.windowTitle)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Captured") {
                Text(screenshot.trigger.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            LabeledContent("Context") {
                Text(screenshot.hasPixels ? "Accessible text + pixels" : "Accessible text only")
            }
            if !screenshot.documentName.isEmpty {
                LabeledContent("Document") {
                    Text(screenshot.documentName)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if !screenshot.sourceURL.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source").font(WorkspaceTypography.bodyEmphasis)
                    Text(screenshot.sourceURL)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if !screenshot.meetingID.isEmpty {
                LabeledContent("Meeting") {
                    Text("Linked recording")
                }
            }
            if screenshot.privacyRedactionCount > 0 {
                LabeledContent("Privacy") {
                    Text("\(screenshot.privacyRedactionCount) secret\(screenshot.privacyRedactionCount == 1 ? "" : "s") redacted")
                }
            }
            if let groupID = screenshot.similarityGroupID {
                LabeledContent("Scene") {
                    Text("\(groupID)").monospacedDigit()
                }
            }
        }
        .font(WorkspaceTypography.body)
    }

    private var capturedTextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Visible text excerpt", systemImage: "text.quote")
                .font(WorkspaceTypography.sectionTitle)
            Text(fullTextExpanded ? capturedText : (SnippetCleaner.withoutTitleEcho(capturedText, title: screenshot.windowTitle) ?? capturedText))
                .font(WorkspaceTypography.body)
                .textSelection(.enabled)
                .lineLimit(fullTextExpanded ? nil : 6)
            if capturedText.count > 280 {
                Button(fullTextExpanded ? "Show less" : "Show full captured text") {
                    fullTextExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(WorkspaceTypography.metadataEmphasis)
                .foregroundStyle(Brand.teal)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                toggleSaved()
            } label: {
                Label(screenshot.isBookmarked ? "Saved" : "Save moment",
                      systemImage: screenshot.isBookmarked ? "bookmark.fill" : "bookmark")
            }
            .tint(screenshot.isBookmarked ? Brand.amber : nil)
            Button {
                app.openAsk(
                    query: "What was I looking at here?",
                    screenSnapshotIDs: [screenshot.id],
                    submit: false)
            } label: {
                Label("Ask about this", systemImage: "sparkles")
            }
            Spacer()
            Button(role: .destructive) {
                confirmingDeletion = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete context moment")
        }
    }

    private var savedNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved until you unsave or delete it.").workspaceTextRole(.supporting)
            Text("Saved moment note").font(WorkspaceTypography.sectionTitle)
            TextField("Why does this moment matter?", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            HStack {
                Spacer()
                Button("Save note") { saveNote() }
                    .disabled(note == savedNoteValue)
            }
        }
    }

    private var savedNoteValue: String {
        app.activityStore.savedMoments().first { $0.snapshotID == screenshot.id }?.note ?? ""
    }

    private func loadNote() {
        note = savedNoteValue
    }

    private func toggleSaved() {
        do {
            if screenshot.isBookmarked {
                try app.activityStore.removeSavedMoment(snapshotID: screenshot.id)
            } else {
                try app.activityStore.saveMoment(snapshotID: screenshot.id, note: note)
            }
            onReload()
        } catch {
            app.lastError = "Could not update saved moment: \(error.localizedDescription)"
        }
    }

    private func saveNote() {
        do {
            try app.activityStore.saveMoment(snapshotID: screenshot.id, note: note)
            onReload()
        } catch {
            app.lastError = "Could not save moment note: \(error.localizedDescription)"
        }
    }

    private func deleteCapture() {
        do {
            try app.screenshots.deleteCapture(id: screenshot.id)
            app.primaryEvidenceDidChange(on: screenshot.ts)
            onClear()
            onReload()
        } catch {
            app.lastError = "Could not delete captured screen: \(error.localizedDescription)"
        }
    }
}
