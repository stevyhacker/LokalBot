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
                    Button("View Full Size") { showingImage = true }
                } else {
                    Label("This moment retained text context without screen pixels.",
                          systemImage: "text.viewfinder")
                        .font(.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .padding(WorkspaceMetric.cardPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                }
                if !screenshot.windowTitle.isEmpty {
                    Text(screenshot.windowTitle)
                        .font(Font.scaled(.body).weight(.semibold))
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
                        Label("Capture Details", systemImage: "info.circle")
                            .font(Font.scaled(.headline))
                    }
                Button("Delete Moment…", role: .destructive) { confirmingDeletion = true }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Delete context moment")
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

    /// "Back to day" → "Day" for the visible button text.
    private var backTitle: String {
        let destination = backLabel.hasPrefix("Back to ") ? String(backLabel.dropFirst(8)) : backLabel
        return destination.prefix(1).uppercased() + destination.dropFirst()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onClear) {
                    Label(backTitle, systemImage: "chevron.left")
                        .font(Font.scaled(.body))
                }
                .buttonStyle(.workspaceLink)
                .help(backLabel)
                .accessibilityLabel(backLabel)
                .accessibilityIdentifier("timeline.screenDetail.backToDayOverview")
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
            HStack(alignment: .top, spacing: 8) {
                IconTile(systemImage: screenshot.hasPixels ? "camera.viewfinder" : "text.viewfinder",
                         tint: Brand.teal, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(screenshot.app)
                        .font(Font.scaled(.title2).weight(.semibold))
                        .accessibilityIdentifier("timeline.screenDetail.\(screenshot.id)")
                    Text(screenshot.ts.formatted(date: .abbreviated, time: .shortened))
                        .font(Font.scaled(.callout).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
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
                    Text("Source").font(Font.scaled(.body).weight(.semibold))
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
        .font(Font.scaled(.body))
    }

    private var capturedTextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Text Context", systemImage: "text.quote")
                .font(Font.scaled(.headline))
            Text(fullTextExpanded ? capturedText : (SnippetCleaner.withoutTitleEcho(capturedText, title: screenshot.windowTitle) ?? capturedText))
                .font(Font.scaled(.body))
                .textSelection(.enabled)
                .lineLimit(fullTextExpanded ? nil : 6)
            if capturedText.count > 280 {
                Button(fullTextExpanded ? "Show Less" : "Show Full Captured Text") {
                    fullTextExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(Font.scaled(.callout).weight(.semibold))
                .foregroundStyle(Brand.teal)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbGroupedSurface()
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { momentActions }
            VStack(alignment: .leading, spacing: 8) { momentActions }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var momentActions: some View {
        Button(action: toggleSaved) {
            Label(screenshot.isBookmarked ? "Saved" : "Save Moment",
                  systemImage: screenshot.isBookmarked ? "bookmark.fill" : "bookmark")
        }
        .tint(screenshot.isBookmarked ? Brand.amber : nil)
        Button {
            app.openAsk(query: "What was I looking at here?", screenSnapshotIDs: [screenshot.id], submit: false)
        } label: {
            Label("Ask About This…", systemImage: "sparkles")
        }
    }

    private var savedNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved until you unsave or delete it.").workspaceTextRole(.supporting)
            Text("Saved Moment Note").font(Font.scaled(.headline))
            TextField("Why does this moment matter?", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            HStack {
                Spacer()
                Button("Save Note") { saveNote() }
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
            try app.withPrimaryEvidenceChange(on: [screenshot.ts]) {
                if screenshot.isBookmarked {
                    try app.activityStore.removeSavedMoment(snapshotID: screenshot.id)
                } else {
                    try app.activityStore.saveMoment(snapshotID: screenshot.id, note: note)
                }
            }
            app.primaryEvidenceDidChange(on: screenshot.ts)
            onReload()
        } catch {
            app.lastError = "Could not update saved moment: \(error.localizedDescription)"
        }
    }

    private func saveNote() {
        do {
            try app.withPrimaryEvidenceChange(on: [screenshot.ts]) {
                try app.activityStore.saveMoment(snapshotID: screenshot.id, note: note)
            }
            app.primaryEvidenceDidChange(on: screenshot.ts)
            onReload()
        } catch {
            app.lastError = "Could not save moment note: \(error.localizedDescription)"
        }
    }

    private func deleteCapture() {
        do {
            try app.withPrimaryEvidenceChange(on: [screenshot.ts]) {
                try app.screenshots.deleteCapture(id: screenshot.id)
            }
            app.primaryEvidenceDidChange(on: screenshot.ts)
            onClear()
            onReload()
        } catch {
            app.lastError = "Could not delete captured screen: \(error.localizedDescription)"
        }
    }
}
