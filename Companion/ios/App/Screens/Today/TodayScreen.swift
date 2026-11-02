import LokalBotCompanionKit
import SwiftUI

/// One glanceable page: what needs attention, the digest, today's meetings
/// and time, and how fresh the copy is. Pull to sync with the Mac.
struct TodayScreen: View {
    @Environment(CompanionSession.self) private var session
    @Environment(AppNavigator.self) private var navigator
    @State private var model = TodayModel()

    private let format = LBFormat.current

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                wide
                narrow
            }
            .pageColumn()
        }
        .navigationTitle("Today")
        .refreshable { await session.syncNow() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    navigator.ask(about: .init(day: session.today.description))
                } label: {
                    Label("Ask About Today", systemImage: "sparkle.magnifyingglass")
                }
            }
        }
        .task(id: session.revision) { await model.load(session) }
    }

    /// Side by side from about 760 pt: the work on the left, the digest on the right.
    private var wide: some View {
        VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
            header
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
                    attention
                    meetings
                    time
                }
                .frame(minWidth: 340, maxWidth: .infinity, alignment: .topLeading)
                digest
                    .frame(minWidth: 340, maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 740)
    }

    private var narrow: some View {
        VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
            header
            attention
            digest
            meetings
            time
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(format.longDay(session.today))
                .font(LBTokens.Typography.secondary)
                .workspaceSupportingForeground()
            SyncStatusPill(state: session.presentation, pinnedNow: session.referenceDateOverride)
        }
    }

    @ViewBuilder private var attention: some View {
        if !model.attention.isEmpty {
            WorkspaceSection("Needs Attention", icon: "exclamationmark.circle") {
                ActionRowList(rows: model.attention)
            } accessory: {
                Button {
                    navigator.open(.actions)
                } label: {
                    Text(model.openActionCount > model.attention.count
                         ? "All \(model.openActionCount) Actions" : "Review Actions")
                }
                .buttonStyle(.workspaceLink)
                .font(LBTokens.Typography.secondary)
            }
        } else if model.loaded {
            WorkspaceSection("Needs Attention", icon: "exclamationmark.circle") {
                EmptyWorkspaceRow("Nothing open is waiting on you.")
            }
        }
    }

    @ViewBuilder private var digest: some View {
        VStack(alignment: .leading, spacing: LBTokens.Spacing.headerToContent) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Brand.teal).accessibilityHidden(true)
                Text("Day Digest").font(LBTokens.Typography.section).accessibilityAddTraits(.isHeader)
                if let record = model.digestRecord, !model.digestIsToday, let day = DayKey(record.date) {
                    Text("· \(format.dayTitle(day, today: session.today))")
                        .font(LBTokens.Typography.secondary)
                        .workspaceSupportingForeground()
                }
                Spacer(minLength: 8)
                if let record = model.digestRecord, let day = DayKey(record.date) {
                    NavigationLink(value: DayRoute(day: day)) {
                        Text("Open Day")
                    }
                    .buttonStyle(.workspaceLink)
                    .font(LBTokens.Typography.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                if let digest = model.digestRecord?.digest {
                    DayDigestView(digest: digest)
                    Text("Written \(format.ago(digest.generatedAt, now: session.referenceDate)) on \(session.macName)")
                        .font(LBTokens.Typography.caption)
                        .workspaceSupportingForeground()
                } else {
                    Text("Your Mac writes the Day Digest from the day's meetings and activity. It shows here after the next sync.")
                        .workspaceTextRole(.supporting)
                }
                if model.digestRecord != nil, !model.digestIsToday {
                    Text("Today's digest isn't ready yet, so this is the latest one.")
                        .font(LBTokens.Typography.caption)
                        .workspaceSupportingForeground()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbGroupedSurface()
        }
    }

    @ViewBuilder private var meetings: some View {
        WorkspaceSection("Today's Meetings", icon: "waveform.circle") {
            if model.meetings.isEmpty {
                EmptyWorkspaceRow(model.loaded ? "No meetings recorded today." : "")
            } else {
                VStack(spacing: 0) {
                    ForEach(model.meetings) { meeting in
                        NavigationLink(value: MeetingRoute(id: meeting.id)) {
                            HStack {
                                MeetingRowView(meeting: meeting)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .lbHoverEffect()
                        if meeting.id != model.meetings.last?.id { Divider() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var time: some View {
        if let timeline = model.todayRecord?.timeline {
            VStack(alignment: .leading, spacing: LBTokens.Spacing.headerToContent) {
                HStack {
                    Text("Day So Far").font(LBTokens.Typography.section).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Open Timeline") { navigator.openDay(session.today) }
                        .buttonStyle(.workspaceLink)
                        .font(LBTokens.Typography.secondary)
                }
                DayOverview(timeline: timeline, meetingCount: model.meetings.count)
                    .padding(16)
                    .lbGroupedSurface()
            }
        }
    }
}
