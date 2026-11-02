import LokalBotCompanionKit
import SwiftUI

/// Meetings list beside the selected meeting; one stack in compact width.
struct MeetingsSplit: View {
    @Environment(AppNavigator.self) private var navigator
    @State private var selection: MeetingRoute?

    var body: some View {
        NavigationSplitView {
            MeetingsList(selection: $selection)
        } detail: {
            NavigationStack {
                if let selection {
                    MeetingDetailScreen(meetingID: selection.id, focus: selection.offset)
                        .companionDestinations()
                } else {
                    ContentUnavailableView("Choose a meeting", systemImage: "waveform.circle",
                                           description: Text("Summaries, action items and transcripts from your Mac."))
                }
            }
            .id(selection)
        }
        .onAppear(perform: consumeFocus)
        .onChange(of: navigator.meetingFocus) { consumeFocus() }
    }

    private func consumeFocus() {
        guard let focus = navigator.meetingFocus else { return }
        selection = MeetingRoute(id: focus.meetingID, offset: focus.offset)
        navigator.meetingFocus = nil
    }
}

struct MeetingsList: View {
    @Environment(CompanionSession.self) private var session
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Binding var selection: MeetingRoute?
    @State private var model = MeetingsModel()
    @State private var searchFocused = false

    private let format = LBFormat.current

    var body: some View {
        @Bindable var model = model
        List(selection: $selection) {
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            NavigationLink(value: MeetingRoute(id: meeting.id)) {
                                MeetingRowView(meeting: meeting)
                            }
                            .contextMenu { menu(for: meeting) }
                        }
                    } header: {
                        SectionHeader(DayKey(group.day).map { format.dayTitle($0, today: session.today) } ?? group.day)
                    }
                }
            } else {
                SearchResults(hits: model.hits, query: model.searchedQuery)
            }
        }
        .listStyle(.plain)
        .tint(Brand.tealFill)
        .overlay {
            if model.loaded && model.groups.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "waveform.circle",
                                       description: Text("Meetings recorded on your Mac appear here after a sync."))
            } else if !model.searchedQuery.isEmpty && model.hits.isEmpty {
                ContentUnavailableView.search(text: model.searchedQuery)
            }
        }
        .navigationTitle("Meetings")
        .searchable(text: $model.query, isPresented: $searchFocused, prompt: "Meetings, transcripts, digests")
        .refreshable { await session.syncNow() }
        .task(id: session.revision) { await model.load(session) }
        .task(id: model.query) {
            try? await Task.sleep(for: .milliseconds(200))
            await model.search(session)
        }
        .onChange(of: navigator.searchRequest) { searchFocused = true }
    }

    @ViewBuilder private func menu(for meeting: Meeting) -> some View {
        if supportsMultipleWindows {
            Button {
                openWindow(id: MeetingWindow.id, value: meeting.id)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
        Button {
            navigator.ask(about: .init(meetingId: meeting.id))
        } label: {
            Label("Ask About This Meeting", systemImage: "sparkle.magnifyingglass")
        }
    }
}

/// Search hits from the device's copy, each opening its meeting at the
/// matched moment, or its day.
struct SearchResults: View {
    @Environment(AppNavigator.self) private var navigator
    let hits: [SearchHit]
    let query: String

    var body: some View {
        ForEach(hits) { hit in
            if let meetingID = hit.meetingId {
                NavigationLink(value: MeetingRoute(id: meetingID, offset: hit.at)) { SearchHitRow(hit: hit, query: query) }
            } else if let day = hit.date.flatMap(DayKey.init) {
                Button { navigator.openDay(day) } label: { SearchHitRow(hit: hit, query: query) }
                    .buttonStyle(.plain)
            } else {
                SearchHitRow(hit: hit, query: query)
            }
        }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(LBTokens.Typography.secondary)
                .foregroundStyle(Brand.teal)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(hit.title).font(LBTokens.Typography.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    if let at = hit.at {
                        Text(LBFormat.stamp(at)).font(LBTokens.Typography.timestamp).foregroundStyle(Brand.teal)
                    } else if let date = hit.date.flatMap(DayKey.init) {
                        Text(LBFormat.current.shortDate(date)).font(LBTokens.Typography.secondary).workspaceSupportingForeground()
                    }
                }
                Text(highlighted)
                    .font(LBTokens.Typography.secondary)
                    .foregroundStyle(LBTokens.Palette.supporting)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch hit.kind {
        case "transcript": "quote.bubble"
        case "action": "checklist"
        case "decision": "checkmark.seal"
        case "day", "digest": "sparkles"
        default: "waveform.circle"
        }
    }

    /// The snippet with the matched words in the primary color.
    private var highlighted: AttributedString {
        SearchSnippet.parts(hit.snippet, query: query).reduce(into: AttributedString()) { text, part in
            var piece = AttributedString(part.text)
            if part.isMatch {
                piece.foregroundColor = Color.primary
                piece.font = LBTokens.Typography.secondary.weight(.semibold)
            }
            text += piece
        }
    }
}
