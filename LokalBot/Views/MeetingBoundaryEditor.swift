import SwiftUI

struct MeetingBoundaryEditor: View {
    let meeting: Meeting
    let save: (Meeting.ContentRange) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meeting boundaries").font(.title2.bold())
            Text("Keep the part that belongs to this meeting. Transcripts, summaries, and search will be rebuilt. The full audio stays available for playback.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Start (seconds)", value: $start, format: .number.precision(.fractionLength(0...2)))
                TextField("End (seconds)", value: $end, format: .number.precision(.fractionLength(0...2)))
            }
            Text("Use the original playback timeline; for example, 2:30 is 150 seconds.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Use full recording") { start = 0; end = meeting.recordedDuration ?? meeting.duration ?? 0 }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & rebuild") {
                    do { try save(.init(start: start, end: end)); dismiss() } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Meeting.ContentRange(start: start, end: end).isValid)
            }
        }
        .padding(24).frame(width: 480)
        .onAppear {
            start = meeting.contentRange?.start ?? 0
            end = meeting.contentRange?.end ?? meeting.recordedDuration ?? meeting.duration ?? 0
        }
    }
}
