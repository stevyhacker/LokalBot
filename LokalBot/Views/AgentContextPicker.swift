import SwiftUI

struct AgentContextPicker: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: AgentSessionController
    @State private var query = ""
    @State private var moments: [ScreenMemorySavedMoment] = []
    @State private var momentError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Attach context").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search meetings and saved moments", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("agent.contextSearch")
            Text("Choose sources to include with your next message. Screen pixels are never attached.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                Section("Meetings") {
                    ForEach(app.meetings.filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) }.prefix(50)) { meeting in
                        attach(.init(id: "meeting:\(meeting.id.uuidString)", kind: .meeting,
                                     title: meeting.displayTitle, reference: meeting.id.uuidString),
                               detail: meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                Section("Saved moments") {
                    if let momentError {
                        Text(momentError).font(.callout).foregroundStyle(.secondary)
                        Button("Open Privacy settings") { dismiss(); app.openSettings(tab: .privacy) }
                    }
                    ForEach(moments.filter { query.isEmpty || "\($0.windowTitle) \($0.note)".localizedCaseInsensitiveContains(query) }, id: \.snapshotID) { moment in
                        attach(.init(id: "moment:\(moment.snapshotID)", kind: .moment,
                                     title: moment.note.isEmpty ? moment.windowTitle : moment.note, reference: String(moment.snapshotID)),
                               detail: "\(moment.app) · \(moment.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }.listStyle(.inset)
        }
        .padding(20).frame(minWidth: 500, idealWidth: 580, minHeight: 420, idealHeight: 520)
        .task {
            do { moments = try controller.contextResolver.savedMoments() } catch { momentError = error.localizedDescription }
        }
    }

    private func attach(_ source: AgentAttachment, detail: String) -> some View {
        Button {
            controller.addAttachment(source)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: source.icon).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: controller.attachments.contains(where: { $0.id == source.id }) ? "checkmark.circle.fill" : "plus.circle")
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Attach \(source.title)")
    }
}
