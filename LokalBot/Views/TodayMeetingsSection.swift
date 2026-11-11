import SwiftUI

/// The day's meetings as one list: what was recorded, with a line saying what
/// it was about, and what the calendar still holds, with a thin line at now.
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
        VStack(alignment: .leading, spacing: 4) {
            TodaySectionHeading(title: "Meetings today", count: count)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .entry(let entry): entryRow(entry)
                    case .now(let date): nowLine(date)
                    }
                }
            }
            if offersCalendar {
                Button("Show upcoming meetings from Calendar…") {
                    // Calendar use and its permission are set up in Settings.
                    app.openSettings(tab: .recording)
                    app.focusedSettingID = "settings.calendarDetectionEnabled"
                }
                .buttonStyle(.workspaceLink)
                .font(AppFont.scaled(.callout))
                .padding(.top, 4)
                .accessibilityIdentifier("today.meetings.connectCalendar")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.meetings")
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
        .padding(.vertical, 7)
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

    private func nowLine(_ date: Date) -> some View {
        let time = date.formatted(date: .omitted, time: .shortened)
        return HStack(spacing: 8) {
            Text(verbatim: time)
                .font(AppFont.scaled(.subheadline).weight(.semibold).monospacedDigit())
                .foregroundStyle(LBTokens.Palette.recordingText)
            Rectangle()
                .fill(LBTokens.Palette.recording.opacity(0.6))
                .frame(height: 1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: time))
        .accessibilityIdentifier("today.meetings.now")
    }
}
