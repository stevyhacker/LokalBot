import LokalBotCompanionKit
import SwiftUI

/// Work sessions, coding-agent sessions and meetings in order on one line,
/// with long stretches of no activity marked, like the Mac's rail.
struct SessionRail: View {
    let model: TimelineModel
    let selected: WorkSession?
    let onSelect: (WorkSession) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 58

    private static let dotColumn: CGFloat = 12
    private static let spacing: CGFloat = 8

    private var sessions: [WorkSession] {
        (model.record?.timeline?.sessions ?? []).sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Sessions").font(LBTokens.Typography.section).accessibilityAddTraits(.isHeader)
                Text(sessions.count, format: .number)
                    .font(LBTokens.Typography.secondary.monospacedDigit())
                    .workspaceSupportingForeground()
            }
            if sessions.isEmpty {
                Text("No work sessions were recorded.")
                    .workspaceTextRole(.supporting)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    let sessions = sessions
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if let gap = Self.awayGap(before: index, in: sessions) {
                            awayRow(gap)
                        }
                        row(session)
                    }
                }
                .background(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(width: 1.5)
                        .padding(.vertical, 14)
                        .offset(x: timeWidth + Self.spacing + Self.dotColumn / 2 - 0.75)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ session: WorkSession) -> some View {
        if session.kind == .meeting, let meetingID = session.meetingId {
            NavigationLink(value: MeetingRoute(id: meetingID)) { meetingRow(session) }
                .buttonStyle(.plain)
                .lbHoverEffect()
        } else {
            Button { onSelect(session) } label: { workRow(session) }
                .buttonStyle(.plain)
                .lbHoverEffect()
                .accessibilityHint("Shows the apps and windows in this session")
        }
    }

    private func time(_ date: Date, emphasis: Color? = nil) -> some View {
        Text(LBFormat.current.time(date, in: model.timeZone))
            .font(LBTokens.Typography.caption.monospacedDigit().weight(emphasis == nil ? .regular : .semibold))
            .foregroundStyle(emphasis ?? LBTokens.Palette.supporting)
            .lineLimit(1)
            .frame(width: timeWidth, alignment: .trailing)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .padding(2)
            .background(Circle().fill(Color(uiColor: .systemBackground)))
            .frame(width: Self.dotColumn)
            .accessibilityHidden(true)
    }

    private func workRow(_ session: WorkSession) -> some View {
        let isSelected = selected == session
        let colorName = session.project ?? session.apps.first?.name ?? session.displayTitle
        return HStack(alignment: .firstTextBaseline, spacing: Self.spacing) {
            time(session.start)
            dot(NameColor.color(for: colorName))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if session.kind == .agent {
                        Image(systemName: "terminal").font(LBTokens.Typography.caption).foregroundStyle(Brand.teal)
                    }
                    Text(session.displayTitle)
                        .font(LBTokens.Typography.secondary.weight(.semibold))
                        .lineLimit(1)
                }
                Text(detail(session))
                    .font(LBTokens.Typography.caption)
                    .foregroundStyle(LBTokens.Palette.supporting)
                    .lineLimit(1)
                if let titles = session.windowTitles, !titles.isEmpty {
                    Text(titles.joined(separator: " · "))
                        .font(LBTokens.Typography.caption)
                        .foregroundStyle(LBTokens.Palette.supporting)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(LBFormat.hm(session.duration))
                .font(LBTokens.Typography.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(LBTokens.Palette.supporting)
                .fixedSize()
        }
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? LBTokens.Palette.accentWash : Color.clear,
                    in: RoundedRectangle(cornerRadius: LBTokens.Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.kind == .agent ? "Coding agent session" : "Work session"), \(session.displayTitle)")
        .accessibilityValue("\(LBFormat.current.timeRange(session.start, session.end, in: model.timeZone)), \(LBFormat.hm(session.duration))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detail(_ session: WorkSession) -> String {
        let apps = session.apps.prefix(3).map(\.name).joined(separator: " · ")
        if session.kind == .agent { return ["Coding agent", apps].filter { !$0.isEmpty }.joined(separator: " · ") }
        return [session.project, apps].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The one tinted row: meetings are first-class events in the day.
    private func meetingRow(_ session: WorkSession) -> some View {
        HStack(spacing: Self.spacing) {
            time(session.start, emphasis: LBTokens.Palette.accentText)
            dot(Brand.teal)
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(LBTokens.Typography.caption)
                    .foregroundStyle(LBTokens.Palette.accentText)
                    .accessibilityHidden(true)
                Text(session.displayTitle)
                    .font(LBTokens.Typography.secondary.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(LBFormat.hm(session.duration))
                    .font(LBTokens.Typography.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(LBTokens.Palette.accentText)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Brand.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: LBTokens.Radius.row, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LBTokens.Radius.row, style: .continuous)
                    .strokeBorder(Brand.teal.opacity(0.24), lineWidth: 1)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting, \(session.displayTitle)")
        .accessibilityValue("\(LBFormat.current.time(session.start, in: model.timeZone)), \(LBFormat.hm(session.duration))")
        .accessibilityHint("Opens the meeting")
    }

    /// Time with nothing recorded before a session, when it is long enough to mark.
    static func awayGap(before index: Int, in sessions: [WorkSession]) -> TimeInterval? {
        guard index > 0 else { return nil }
        let gap = sessions[index].start.timeIntervalSince(sessions[index - 1].end)
        return gap >= 45 * 60 ? gap : nil
    }

    private func awayRow(_ gap: TimeInterval) -> some View {
        HStack(spacing: Self.spacing) {
            Color.clear.frame(width: timeWidth + Self.spacing + Self.dotColumn, height: 1)
            Text("Away \(LBFormat.hm(gap))")
                .font(LBTokens.Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .accessibilityLabel("No activity for \(LBFormat.hm(gap))")
    }
}

/// A work session's details: when, which apps for how long, and the windows
/// (when the Mac shares window titles).
struct SessionDetailView: View {
    let session: WorkSession
    let timeZone: TimeZone
    let windowTitlesShared: Bool
    let onBack: (() -> Void)?

    var body: some View {
        let format = LBFormat.current
        VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
            if let onBack {
                Button(action: onBack) {
                    Label("Back to the Day", systemImage: "chevron.backward")
                }
                .buttonStyle(.workspaceLink)
                .font(LBTokens.Typography.secondary.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(session.displayTitle)
                    .font(LBTokens.Typography.columnTitle)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 7, lineSpacing: 7) {
                    BrandChip(icon: "clock", format.timeRange(session.start, session.end, in: timeZone))
                    BrandChip(icon: "hourglass", LBFormat.hm(session.duration))
                    BrandChip(icon: session.kind == .agent ? "terminal" : "briefcase",
                              session.kind == .agent ? "Coding agent" : "Work session")
                    if let project = session.project {
                        HStack(spacing: 6) {
                            StatusDot(color: NameColor.color(for: project), size: 7)
                            Text(project)
                        }
                        .font(LBTokens.Typography.secondary)
                        .chipChrome()
                    }
                }
            }
            if !session.apps.isEmpty {
                WorkspaceSection("Apps", icon: "square.grid.2x2") {
                    let total = max(session.apps.reduce(0) { $0 + $1.seconds }, 1)
                    ForEach(session.apps, id: \.name) { app in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                StatusDot(color: NameColor.color(for: app.name), size: 7)
                                Text(app.name).font(LBTokens.Typography.body)
                                Spacer()
                                Text(LBFormat.hm(app.seconds))
                                    .font(LBTokens.Typography.timestamp)
                                    .workspaceSupportingForeground()
                            }
                            GeometryReader { proxy in
                                Capsule().fill(NameColor.color(for: app.name))
                                    .frame(width: max(4, proxy.size.width * app.seconds / total))
                            }
                            .frame(height: 5)
                            .accessibilityHidden(true)
                        }
                        .padding(.vertical, 5)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let titles = session.windowTitles, !titles.isEmpty {
                WorkspaceSection("Windows", icon: "macwindow") {
                    ForEach(titles, id: \.self) { title in
                        Text(title).font(LBTokens.Typography.body).padding(.vertical, 5)
                    }
                }
            } else if !windowTitlesShared {
                Text("Window titles aren't shared with this device. You can turn them on in LokalBot Settings → Phones & tablets on your Mac.")
                    .font(LBTokens.Typography.caption)
                    .workspaceSupportingForeground()
            }
            if let meetingID = session.meetingId {
                NavigationLink(value: MeetingRoute(id: meetingID)) {
                    Label("Open Meeting", systemImage: "waveform.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
