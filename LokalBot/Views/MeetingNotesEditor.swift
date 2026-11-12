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
        // Your notes on one panel: the editor is its body, and the line that
        // says whether they are saved is its footer.
        SectionPanel(
            title: Text("Your notes"),
            systemImage: "pencil",
            identifier: "meeting.notes",
            titleID: MeetingPageSearchMatch.Location.notesLabel
        ) {
            EmptyView()
        } content: {
            SearchableNotesEditor(text: $text, query: searchQuery, occurrence: activeMatchIndex)
                .font(AppFont.scaled(.body))
                .frame(minHeight: 420)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Add context, reminders, or your own wording. Notes save automatically.")
                            .font(AppFont.scaled(.body))
                            .foregroundStyle(.tertiary)
                            // Where the editor puts its first character.
                            .padding(.leading, 17)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("meeting.notes.editor")
                .id(MeetingPageSearchMatch.Location.notes)
        } footer: {
            if let error {
                Text(status)
                Text(error).workspaceTextRole(.warning).sectionPanelFooterText()
                Button("Retry saving", action: save)
            } else {
                Text(status).sectionPanelFooterText()
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
            app.meetingNotesDidChange(meeting)
            app.meetingNoteDrafts.removeValue(forKey: meeting.id)
            status = "Saved on this Mac"
            error = nil
        } catch {
            status = "Not saved"
            self.error = error.localizedDescription
        }
    }
}
