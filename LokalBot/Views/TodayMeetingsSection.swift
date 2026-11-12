import SwiftUI

/// The day's meetings as one panel: what was recorded, with a line saying
/// what it was about, and what the calendar still holds, with a line at now.
/// Work sessions and apps are on Timeline.
struct TodayMeetingsSection: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.appTextScale) private var textScale
    let rows: [TodayAgenda.Row]
    let count: Int
    /// One line per recorded meeting, where its saved summary offers one.
    let recaps: [Meeting.ID: String]
    /// Calendar use is off: offer to turn it on, once, under the list.
    let offersCalendar: Bool

    private static let timeColumnWidth: CGFloat = 70

    var body: some View {
        SectionPanel(
            title: Text("Meetings today"),
            systemImage: AppState.NavSection.meetings.symbol,
            count: count,
            identifier: "today.meetings",
            showsContent: !rows.isEmpty,
            showsFooter: offersCalendar
        ) {
            Button("All meetings") { app.navSection = .meetings }
                .accessibilityIdentifier("today.meetings.all")
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    switch row {
                    case .entry(let entry):
                        entryRow(entry)
                        if Self.hasHairline(after: index, in: rows) { Divider() }
                    case .now(let date):
                        nowLine(date, leads: index == 0)
                    }
                }
            }
        } footer: {
            Text("Upcoming meetings can show here too")
                .sectionPanelFooterText()
            Button("Connect Calendar…") {
                // Calendar use and its permission are set up in Settings.
                app.openSettings(tab: .recording)
                app.focusedSettingID = "settings.calendarDetectionEnabled"
            }
            .accessibilityIdentifier("today.meetings.connectCalendar")
        }
    }

    /// A hairline divides two meetings. The now line draws its own rule, so
    /// the meeting before it has none, and the last row ends at the panel.
    static func hasHairline(after index: Int, in rows: [TodayAgenda.Row]) -> Bool {
        guard rows.indices.contains(index + 1) else { return false }
        if case .now = rows[index + 1] { return false }
        return true
    }

    // MARK: Rows

    @ViewBuilder private func entryRow(_ entry: TodayAgenda.Entry) -> some View {
        if let meeting = entry.meeting {
            Button {
                if entry.status == .recording {
                    app.showLiveMeeting()
                } else {
                    app.openMeeting(meeting.id)
                }
            } label: {
                rowContent(entry, recap: recaps[meeting.id])
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("today.meeting.\(entry.id)")
        } else {
            rowContent(entry, recap: nil)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("today.meeting.\(entry.id)")
        }
    }

    private func rowContent(_ entry: TodayAgenda.Entry, recap: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: entry.start.formatted(date: .omitted, time: .shortened))
                .font(AppFont.scaled(.callout).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.timeColumnWidth * textScale, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: entry.title)
                        .font(AppFont.scaled(.body).weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    status(entry)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                if let recap {
                    Text(verbatim: recap)
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, SectionPanelMetric.inset)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// A saved recording says where and how long; everything else says where
    /// it stands in the day.
    @ViewBuilder private func status(_ entry: TodayAgenda.Entry) -> some View {
        switch entry.status {
        case .recorded:
            if let meeting = entry.meeting {
                Text(verbatim: [meeting.isMergedMeeting ? "" : meeting.appName, meeting.displayDuration]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .recording:
            TodayMeetingStatusText.text(entry.status)
                .font(AppFont.scaled(.callout).weight(.semibold))
                .foregroundStyle(LBTokens.Palette.recordingText)
        default:
            TodayMeetingStatusText.text(entry.status)
                .font(AppFont.scaled(.callout).weight(entry.isSoon ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(entry.isSoon ? AnyShapeStyle(LBTokens.Palette.accentText) : AnyShapeStyle(.secondary))
        }
    }

    /// "Now · 10:48 AM" under a rule the width of the panel. Above the first
    /// meeting the rule takes the place of the header's hairline.
    private func nowLine(_ date: Date, leads: Bool) -> some View {
        // The text is the element: a container with only a label has no
        // role, which the accessibility audit reports.
        Text("Now · \(date.formatted(date: .omitted, time: .shortened))")
            .font(AppFont.scaledSystem(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(LBTokens.Palette.recordingText)
            .accessibilityIdentifier("today.meetings.now")
            .padding(.horizontal, SectionPanelMetric.inset)
            .frame(maxWidth: .infinity, minHeight: 20 * textScale, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(LBTokens.Palette.recording.opacity(0.6))
                    .frame(height: 1)
                    .offset(y: leads ? -1 : 0)
                    .accessibilityHidden(true)
            }
    }
}
