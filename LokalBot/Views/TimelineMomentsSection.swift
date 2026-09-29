import SwiftUI

enum TimelineBrowseMode: String, CaseIterable, Identifiable {
    case day = "Day", rewind = "Rewind"
    var id: String { rawValue }
}

/// A constant-size task identity; only a debounced search copies capture IDs.
struct TimelineMomentSearchRequest: Equatable {
    let day: Date
    let query: String
    let shotsRevision: Int
    let textRevision: Int

    func hasSameScope(as other: Self) -> Bool {
        day == other.day && query == other.query && textRevision == other.textRevision
    }
}

struct TimelineMomentSearchResults {
    private var request: TimelineMomentSearchRequest?
    private var matches: Set<Int64> = []
    private(set) var isSearching = false

    func matches(for request: TimelineMomentSearchRequest) -> Set<Int64> {
        self.request?.hasSameScope(as: request) == true ? matches : []
    }

    mutating func begin(_ request: TimelineMomentSearchRequest) {
        matches = matches(for: request)
        self.request = request
        isSearching = !request.query.isEmpty
    }

    mutating func finish(_ request: TimelineMomentSearchRequest, matches: Set<Int64>) {
        guard self.request == request else { return }
        self.matches = matches
        isSearching = false
    }

    mutating func invalidate() { self = Self() }
}

struct TimelineMomentsSection: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var model: CaptureModel
    let mode: TimelineBrowseMode
    let query: String
    let application: String
    let onOpenContext: () -> Void
    @State private var searchResults = TimelineMomentSearchResults()
    @State private var textRevision = 0

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchRequest: TimelineMomentSearchRequest {
        TimelineMomentSearchRequest(day: model.day, query: needle,
                                    shotsRevision: model.shotsRevision, textRevision: textRevision)
    }

    private var filtered: [ActivityStore.Screenshot] {
        let textMatches = searchResults.matches(for: searchRequest)
        return model.shots.filter { shot in
            (application.isEmpty || shot.app == application)
                && (needle.isEmpty || [shot.app, shot.windowTitle, shot.documentName]
                    .contains { $0.localizedCaseInsensitiveContains(needle) } || textMatches.contains(shot.id))
        }.sorted { $0.ts < $1.ts }
    }

    var body: some View {
        let moments = filtered
        let groups = Dictionary(grouping: moments) { Calendar.current.dateInterval(of: .hour, for: $0.ts)!.start }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Retained Moments").font(.scaled(.headline))
                Spacer()
                Text("\(moments.count) of \(model.shots.count)").font(.scaled(.callout)).foregroundStyle(.secondary)
            }
            if searchResults.isSearching { LoadingStateLabel("Searching retained text…") }
            if mode == .rewind {
                ScreenRewindView(frames: ScreenRewindSequence.frames(from: moments),
                                 selectedSnapshotID: $model.selectedSnapshotID,
                                 onReload: { model.reload(app: app) })
            }
            if moments.isEmpty {
                Text(needle.isEmpty && application.isEmpty ? "No retained moments for this day." : "No moments match these filters.")
                    .font(.scaled(.body)).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(groups.keys.sorted(), id: \.self) { hour in
                    Text(hour.formatted(.dateTime.hour().minute())).font(.scaled(.callout).weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(groups[hour] ?? []) { shot in
                        momentRow(shot)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.moments")
        .onReceive(NotificationCenter.default.publisher(for: .retainedScreenTextChanged)) { _ in
            searchResults.invalidate()
            textRevision &+= 1
        }
        .task(id: searchRequest) {
            let request = searchRequest
            searchResults.begin(request)
            guard !request.query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, request == searchRequest else { return }
            let ids = model.shots.map(\.id)
            let matches = await ActivityStore.readInBackground(at: app.activityStore.databaseURL) { store in
                store.matchingSnapshotIDs(ids, query: request.query)
            }
            guard !Task.isCancelled, request == searchRequest else { return }
            searchResults.finish(request, matches: matches)
        }
    }

    private func momentRow(_ shot: ActivityStore.Screenshot) -> some View {
        Button {
            model.showsRawCapture = false
            model.selection = nil
            model.selectedSessionID = nil
            app.selectedMeetingIDs = []
            model.selectedSnapshotID = shot.id
            onOpenContext()
        } label: {
            HStack(spacing: 12) {
                ScreenThumbnailView(screenshot: shot, height: 56).frame(width: 90)
                VStack(alignment: .leading, spacing: 5) {
                    Text(shot.documentName.isEmpty ? (shot.windowTitle.isEmpty ? shot.app : shot.windowTitle) : shot.documentName)
                        .font(.scaled(.body).weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    Text("\(shot.app) · \(shot.ts.formatted(date: .omitted, time: .standard))")
                        .font(.scaled(.callout)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if shot.isBookmarked { Image(systemName: "bookmark.fill").foregroundStyle(Brand.teal) }
                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(12).lbGroupedSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("timeline.moment.\(shot.id)")
    }
}
