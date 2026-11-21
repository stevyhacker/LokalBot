import LokalBotCompanionKit
import SwiftUI

struct ActionRowView: View {
    enum Evidence {
        case openMeeting
        case handle((Citation) -> Void)
        case hidden
    }

    let action: ActionItem
    let meetingID: String
    var meetingTitle: String?
    var linksMeeting = true
    var pending = false
    var note: ActionSyncNote?
    var today: DayKey
    var evidence: Evidence = .openMeeting
    let onToggle: () -> Void

    private let format = LBFormat.current

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ActionCheck(isDone: action.status == .done, pending: pending, action: onToggle)
                .padding(.top, -10)
                .padding(.leading, -10)
                .accessibilityValue(action.text)
            VStack(alignment: .leading, spacing: 5) {
                Text(action.text)
                    .font(LBTokens.Typography.body)
                    .strikethrough(action.status == .done)
                    .foregroundStyle(action.status == .open ? Color.primary : LBTokens.Palette.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 8, lineSpacing: 4) {
                    owner
                    if let due = format.due(action.dueDate, status: action.status, today: today) {
                        Text(due.text)
                            .foregroundStyle(due.isOverdue ? LBTokens.Palette.recordingText : LBTokens.Palette.supporting)
                            .accessibilityLabel(due.isOverdue ? "Overdue. \(due.text)" : due.text)
                    }
                    if action.status == .deferred {
                        Text("Deferred").foregroundStyle(LBTokens.Palette.supporting)
                    }
                    if let meetingTitle {
                        if linksMeeting {
                            NavigationLink(value: MeetingRoute(id: meetingID)) {
                                Text(meetingTitle).foregroundStyle(Brand.teal).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Label(meetingTitle, systemImage: "waveform")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(LBTokens.Palette.supporting)
                                .lineLimit(1)
                        }
                    }
                    evidencePill.padding(.horizontal, -6)
                }
                .font(LBTokens.Typography.secondary)
                if pending {
                    Label("Waiting for your computer", systemImage: "clock.arrow.2.circlepath")
                        .font(LBTokens.Typography.caption)
                        .foregroundStyle(LBTokens.Palette.attentionText)
                } else if note != nil {
                    Label("Not changed on your computer", systemImage: "exclamationmark.circle")
                        .font(LBTokens.Typography.caption)
                        .foregroundStyle(LBTokens.Palette.attentionText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, LBTokens.Spacing.rowVerticalPadding - 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var owner: some View {
        if action.ownerUnclear {
            Text("Owner unclear").foregroundStyle(LBTokens.Palette.attentionText)
        } else if action.ownerIsUser {
            Text("You").foregroundStyle(LBTokens.Palette.supporting)
        } else if let owner = action.owner {
            Text(owner).foregroundStyle(LBTokens.Palette.supporting)
        }
    }

    @ViewBuilder private var evidencePill: some View {
        if let citation = action.citations.first {
            switch evidence {
            case .openMeeting:
                NavigationLink(value: MeetingRoute(id: meetingID, offset: citation.start)) {
                    EvidencePillLabel(start: citation.start)
                }
                .buttonStyle(.plain)
                .lbHoverEffect()
                .accessibilityHint(citation.excerpt)
            case .handle(let handler):
                EvidencePill(citation: citation) { handler(citation) }
            case .hidden:
                EmptyView()
            }
        }
    }
}

struct ActionRowList: View {
    @Environment(CompanionSession.self) private var session
    let rows: [ActionRow]
    var showsMeeting = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                ActionRowView(action: row.action, meetingID: row.meetingId,
                              meetingTitle: showsMeeting ? row.meetingTitle : nil,
                              pending: row.pending, note: row.syncNote, today: session.today) {
                    toggle(row)
                }
                if row.id != rows.last?.id { Divider() }
            }
            if let error {
                Text(error).workspaceTextRole(.warning).padding(.vertical, 6)
            }
        }
    }

    private func toggle(_ row: ActionRow) {
        Task {
            do {
                try await session.setActionStatus(row.action.status == .done ? .open : .done,
                                                   meetingID: row.meetingId, actionID: row.action.id)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
