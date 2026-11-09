import LokalBotCompanionKit
import SwiftUI

/// A day's digest as the Mac lays it out: blockers lead, then highlights,
/// decisions, tasks and follow-ups. Falls back to the Markdown when the Mac
/// sent no sections.
struct DayDigestView: View {
    let digest: DayDigest

    var body: some View {
        let sections = digest.sections
        VStack(alignment: .leading, spacing: 18) {
            if sections.isEmpty {
                MarkdownText(digest.markdown)
            } else {
                if !sections.blockers.isEmpty {
                    blockers(sections.blockers)
                }
                section("Highlights", icon: "sparkles", items: sections.highlights, tint: Brand.teal)
                section("Decisions", icon: "checkmark.seal", items: sections.decisions, tint: LBTokens.Palette.successText)
                section("Tasks", icon: "briefcase", items: sections.tasks, tint: LBTokens.Palette.supporting)
                section("Follow-ups", icon: "arrow.turn.down.right", items: sections.followUps, tint: LBTokens.Palette.supporting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func blockers(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(items.count == 1 ? "Blocker" : "Blockers", systemImage: "exclamationmark.triangle.fill")
                .font(LBTokens.Typography.secondary.weight(.semibold))
                .foregroundStyle(LBTokens.Palette.attentionText)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(MarkdownInline.attributed(item)).readingText().fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbStatusSurface(LBTokens.Palette.attention)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func section(_ title: String, icon: String, items: [String], tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon)
                    .font(LBTokens.Typography.secondary.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(tint.opacity(0.8)).frame(width: 5, height: 5)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                            .accessibilityHidden(true)
                        Text(MarkdownInline.attributed(item)).readingText().fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// A day's activity at a glance: tracked time, apps, meetings, moments, and
/// the share of time by project.
struct DayOverview: View {
    let timeline: DayTimeline
    var meetingCount: Int
    var showsLegend = true

    var body: some View {
        let segments = ProportionBarMath.segments(timeline.byProject.isEmpty ? timeline.byApp : timeline.byProject)
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                StatTile(icon: "clock", value: LBFormat.hm(timeline.trackedSeconds), label: "tracked")
                StatTile(icon: "square.grid.2x2", value: timeline.byApp.count.formatted(),
                         label: timeline.byApp.count == 1 ? "app" : "apps")
                StatTile(icon: "waveform", value: meetingCount.formatted(), label: meetingCount == 1 ? "meeting" : "meetings")
                if !timeline.savedMoments.isEmpty {
                    StatTile(icon: "bookmark", value: timeline.savedMoments.count.formatted(),
                             label: timeline.savedMoments.count == 1 ? "moment" : "moments")
                }
            }
            if !segments.isEmpty {
                ProportionBar(segments: segments, label: timeline.byProject.isEmpty ? "Time by app" : "Time by project")
                if showsLegend { ProportionLegend(segments: segments) }
            }
        }
    }
}

/// A meeting in a list: title, then time, length and app in the Mac's zone.
struct MeetingRowView: View {
    let meeting: Meeting
    var showsDay = false

    var body: some View {
        let format = LBFormat.current
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(LBTokens.Typography.body.weight(.semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(2)
            Text(([showsDay ? format.shortDate(DayKey(meeting.day) ?? DayKey(meeting.startedAt)) : nil,
                   format.time(meeting.startedAt, in: meeting.timeZone),
                   LBFormat.meetingDuration(meeting.durationSeconds),
                   meeting.appName].compactMap { $0 }).joined(separator: " · "))
                .font(LBTokens.Typography.secondary)
                .foregroundStyle(LBTokens.Palette.supporting)
                .lineLimit(1)
            if !meeting.people.isEmpty {
                Text(meeting.people.map(\.displayName).joined(separator: ", "))
                    .font(LBTokens.Typography.caption)
                    .foregroundStyle(LBTokens.Palette.supporting)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Page padding and the readable width the Mac uses for glanceable pages.
struct PageColumn: ViewModifier {
    var maxWidth: CGFloat = 956

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 28)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    func pageColumn(maxWidth: CGFloat = 956) -> some View { modifier(PageColumn(maxWidth: maxWidth)) }
}
