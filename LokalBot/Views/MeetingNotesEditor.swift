import SwiftUI

struct MeetingNotesEditor: View {
    @EnvironmentObject private var app: AppState
    let meeting: Meeting
    var searchQuery = ""
    var activeMatchIndex: Int?
    var onTextChange: (String) -> Void = { _ in }
    @State private var text = ""
    @State private var savedText = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var status = "Saved on this Mac"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your notes").font(WorkspaceTypography.sectionTitle)
                Spacer()
                Text(status).font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
            }
            SearchableNotesEditor(text: $text, query: searchQuery, occurrence: activeMatchIndex)
                .font(WorkspaceTypography.body)
                .frame(minHeight: 460)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Add context, reminders, or your own wording. Notes save automatically.")
                            .font(WorkspaceTypography.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(12).workspaceControl()
                .accessibilityIdentifier("meeting.notes.editor")
                .id(MeetingPageSearchMatch.Location.notes)
            if let error {
                Text(error).workspaceTextRole(.warning)
                Button("Retry saving", action: save)
            }
        }
        .onAppear {
            savedText = MeetingNotes.load(from: meeting.folderURL(in: app.storage)) ?? ""
            text = app.meetingNoteDrafts[meeting.id] ?? savedText
        }
        .onChange(of: text) {
            onTextChange(text)
            app.meetingNoteDrafts[meeting.id] = text
            guard text != savedText else { return }
            status = "Saving…"
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                save()
            }
        }
        .onDisappear { saveTask?.cancel(); if text != savedText { save() } }
    }

    private func save() {
        do {
            try MeetingNotes.writeChecked(text, to: meeting.folderURL(in: app.storage))
            savedText = text
            app.meetingNoteDrafts.removeValue(forKey: meeting.id)
            status = "Saved on this Mac"
            error = nil
        } catch {
            status = "Not saved"
            self.error = error.localizedDescription
        }
    }
}
