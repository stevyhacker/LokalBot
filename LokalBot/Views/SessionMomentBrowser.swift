import SwiftUI

struct SessionMomentBrowser: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    let session: TimelineWorkSession
    @State private var query = ""
    @State private var application = ""
    @State private var textMatches: Set<Int64> = []
    @State private var searching = false
    @State private var textRevision = 0

    private var moments: [ActivityStore.Screenshot] {
        model.shots.filter { $0.ts >= session.start && $0.ts <= session.end }
    }
    private var filtered: [ActivityStore.Screenshot] {
        moments.filter { shot in
            (application.isEmpty || shot.app == application)
                && (query.isEmpty || [shot.windowTitle, shot.documentName]
                    .contains { $0.localizedCaseInsensitiveContains(query) } || textMatches.contains(shot.id))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Retained moments · \(filtered.count) of \(moments.count)")
                .font(WorkspaceTypography.sectionTitle)
            TextField("Find in this session", text: $query).textFieldStyle(.roundedBorder)
            if searching { LoadingStateLabel("Searching retained text…") }
            Picker("App", selection: $application) {
                Text("All apps").tag("")
                ForEach(Array(Set(moments.map(\.app))).sorted(), id: \.self) { Text($0).tag($0) }
        }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filtered) { shot in
                    Button { model.selectedSnapshotID = shot.id } label: {
                        HStack(spacing: 10) {
                            ScreenThumbnailView(screenshot: shot, height: 46).frame(width: 74)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(shot.documentName.isEmpty ? (shot.windowTitle.isEmpty ? shot.app : shot.windowTitle) : shot.documentName)
                                    .lineLimit(2)
                                Text("\(shot.app) · \(shot.ts.formatted(date: .omitted, time: .standard))")
                                    .font(WorkspaceTypography.metadata).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if shot.isBookmarked { Image(systemName: "bookmark.fill") }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }.accessibilityIdentifier("timeline.session.allMoments")
        .onReceive(NotificationCenter.default.publisher(for: .retainedScreenTextChanged)) { _ in
            textMatches = []
            textRevision &+= 1
        }
        .task(id: "\(session.id)|\(query)|\(moments.map(\.id))|\(textRevision)") {
            textMatches = []
            guard !query.isEmpty else { searching = false; return }
            searching = true
            let needle = query, captures = moments
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let matches = await ActivityStore.readInBackground(at: app.activityStore.databaseURL) { store in
                store.matchingSnapshotIDs(captures.map(\.id), query: needle)
            }
            guard !Task.isCancelled else { return }
            textMatches = matches
            searching = false
        }
    }
}
