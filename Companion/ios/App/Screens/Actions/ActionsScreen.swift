import LokalBotCompanionKit
import SwiftUI

/// Every action with its details beside it; one stack in compact width.
struct ActionsSplit: View {
    @Environment(AppNavigator.self) private var navigator
    @State private var selection: ActionRoute?

    var body: some View {
        NavigationSplitView {
            ActionsList(selection: $selection)
        } detail: {
            NavigationStack {
                if let selection {
                    ActionDetailScreen(route: selection).companionDestinations()
                } else {
                    ContentUnavailableView("Choose an action", systemImage: "checklist",
                                           description: Text("See who said it, when it's due, and the passage it came from."))
                }
            }
            .id(selection)
        }
        .onAppear(perform: consumeSelection)
        .onChange(of: navigator.actionSelection) { consumeSelection() }
    }

    private func consumeSelection() {
        guard let id = navigator.actionSelection else { return }
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 { selection = ActionRoute(meetingID: parts[0], actionID: parts[1]) }
        navigator.actionSelection = nil
    }
}

struct ActionsList: View {
    @Environment(CompanionSession.self) private var session
    @Binding var selection: ActionRoute?
    @State private var model = ActionsModel()

    var body: some View {
        List(selection: $selection) {
            ForEach(model.groups, id: \.group) { group in
                Section {
                    ForEach(group.rows) { row in
                        NavigationLink(value: ActionRoute(row)) {
                            ActionRowView(action: row.action, meetingID: row.meetingId, meetingTitle: row.meetingTitle,
                                          linksMeeting: false, pending: row.pending, today: model.today,
                                          evidence: .hidden) {
                                Task { await model.setStatus(row.action.status == .done ? .open : .done, for: row, session: session) }
                            }
                        }
                        .swipeActions(edge: .trailing) { swipeActions(row) }
                    }
                } header: {
                    HStack {
                        SectionHeader(group.group.title)
                        Text(group.rows.count, format: .number)
                            .font(LBTokens.Typography.caption.monospacedDigit())
                            .workspaceSupportingForeground()
                    }
                }
            }
        }
        .listStyle(.plain)
        .tint(Brand.tealFill)
        .safeAreaInset(edge: .top, spacing: 0) { filters }
        .overlay {
            if model.loaded && model.visible.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "checklist",
                                       description: Text("Choose another filter to see the rest."))
            }
        }
        .navigationTitle("Actions")
        .refreshable { await session.syncNow() }
        .task(id: TaskKey(revision: session.revision, status: model.status)) { await model.load(session) }
        .alert("Couldn't change the action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }

    private struct TaskKey: Hashable {
        let revision: Int
        let status: ActionStatus
    }

    private var emptyTitle: String {
        switch model.status {
        case .open: model.owner == .mine ? "Nothing open for you" : "Nothing open"
        case .done: "Nothing done yet"
        case .deferred: "Nothing deferred"
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ActionOrdering.Owner.allCases) { owner in
                        FilterChip(owner.title, count: model.counts[owner], isSelected: model.owner == owner) {
                            model.owner = owner
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ActionStatus.allCases, id: \.self) { status in
                        FilterChip(status.label, isSelected: model.status == status) {
                            model.status = status
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground), ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    @ViewBuilder private func swipeActions(_ row: ActionRow) -> some View {
        if row.action.status != .done {
            Button {
                Task { await model.setStatus(.done, for: row, session: session) }
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .tint(Brand.tealFill)
        }
        if row.action.status != .deferred {
            Button {
                Task { await model.setStatus(.deferred, for: row, session: session) }
            } label: {
                Label("Defer", systemImage: "clock.arrow.circlepath")
            }
            .tint(.gray)
        }
    }
}

/// One action: what was said, by whom, when it's due, and the cited passage.
struct ActionDetailScreen: View {
    let route: ActionRoute
    @Environment(CompanionSession.self) private var session
    @State private var row: ActionRow?
    @State private var meeting: Meeting?
    @State private var loaded = false
    @State private var error: String?

    private let format = LBFormat.current

    var body: some View {
        ScrollView {
            if let row {
                content(row)
                    .pageColumn(maxWidth: 720)
            } else if loaded {
                ContentUnavailableView("Action not found", systemImage: "checklist",
                                       description: Text("It may have changed when the meeting was processed again on your Mac."))
                    .padding(.top, 80)
            }
        }
        .navigationTitle("Action")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.revision) { await load() }
    }

    private func load() async {
        let rows = (try? await session.store.actions(.all)) ?? []
        row = rows.first { $0.meetingId == route.meetingID && $0.action.id == route.actionID }
        meeting = try? await session.store.meeting(id: route.meetingID)
        loaded = true
    }

    private func content(_ row: ActionRow) -> some View {
        let action = row.action
        return VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(action.text)
                    .font(LBTokens.Typography.columnTitle)
                    .strikethrough(action.status == .done)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                FlowLayout(spacing: 7, lineSpacing: 7) {
                    if action.ownerUnclear {
                        BrandChip(icon: "person.crop.circle.badge.questionmark", "Owner unclear", tint: LBTokens.Palette.attentionText)
                    } else {
                        BrandChip(icon: "person", action.ownerIsUser ? "You" : action.owner ?? "Someone")
                    }
                    if let due = format.due(action.dueDate, status: action.status, today: session.today) {
                        BrandChip(icon: "calendar", due.text, tint: due.isOverdue ? LBTokens.Palette.recordingText : nil)
                    }
                    BrandChip(icon: statusIcon(action.status), action.status.label)
                    if action.importance >= 4 { BrandChip(icon: "flag", "Important") }
                }
                if let dueText = action.dueText {
                    Text("Said “\(dueText)”")
                        .font(LBTokens.Typography.secondary)
                        .workspaceSupportingForeground()
                }
            }

            if row.pending {
                Label {
                    Text("Changed on this device. Waiting for your Mac; it updates on the next sync.")
                } icon: {
                    Image(systemName: "clock.arrow.2.circlepath")
                }
                .font(LBTokens.Typography.secondary)
                .foregroundStyle(LBTokens.Palette.attentionText)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lbStatusSurface(LBTokens.Palette.attention)
            }

            buttons(row)

            WorkspaceSection("From the Meeting", icon: "quote.bubble") {
                NavigationLink(value: MeetingRoute(id: row.meetingId)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.meetingTitle).font(LBTokens.Typography.body.weight(.semibold))
                            if let meeting {
                                Text(format.meetingDate(meeting))
                                    .font(LBTokens.Typography.secondary)
                                    .workspaceSupportingForeground()
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lbHoverEffect()
                if action.citations.isEmpty {
                    Divider()
                    EmptyWorkspaceRow("No supporting passage was stored.")
                }
                ForEach(action.citations, id: \.self) { citation in
                    Divider()
                    CitedPassage(citation: citation, meetingID: row.meetingId, meeting: meeting)
                }
            }
            if let error {
                Text(error).workspaceTextRole(.warning)
            }
        }
    }

    private func buttons(_ row: ActionRow) -> some View {
        HStack(spacing: 10) {
            switch row.action.status {
            case .open:
                Button { set(.done, row) } label: { Label("Mark Done", systemImage: "checkmark") }
                    .primaryActionButton()
                Button { set(.deferred, row) } label: { Label("Defer", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(.bordered)
            case .done:
                Button { set(.open, row) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.bordered)
            case .deferred:
                Button { set(.done, row) } label: { Label("Mark Done", systemImage: "checkmark") }
                    .primaryActionButton()
                Button { set(.open, row) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private func statusIcon(_ status: ActionStatus) -> String {
        switch status {
        case .open: "circle"
        case .done: "checkmark.circle.fill"
        case .deferred: "clock.arrow.circlepath"
        }
    }

    private func set(_ status: ActionStatus, _ row: ActionRow) {
        Task {
            do {
                try await session.setActionStatus(status, meetingID: row.meetingId, actionID: row.action.id)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A quoted passage: speaker, the time on the Mac, the words, and a link to
/// that moment in the transcript.
struct CitedPassage: View {
    let citation: Citation
    let meetingID: String
    let meeting: Meeting?

    var body: some View {
        NavigationLink(value: MeetingRoute(id: meetingID, offset: citation.start)) {
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(Brand.teal.opacity(0.45)).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if let speaker = citation.speaker {
                            Text(speaker).font(LBTokens.Typography.secondary.weight(.semibold))
                        }
                        if let meeting {
                            Text(LBFormat.current.time(in: meeting, at: citation.start))
                                .font(LBTokens.Typography.secondary)
                                .workspaceSupportingForeground()
                        }
                        Spacer(minLength: 4)
                        EvidencePillLabel(start: citation.start)
                    }
                    Text("“\(citation.excerpt)”")
                        .readingText()
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lbHoverEffect()
        .accessibilityHint("Opens the transcript at this moment")
    }
}
