import LokalBotCompanionKit
import SwiftUI

/// Any day's activity: the day strip and calendar, the activity overview, the
/// digest, meetings and the work-session rail. From 820 pt the rail sits
/// beside the day and a session opens in place of the day; below that the
/// sessions follow the day and a session opens in a drawer, as on the Mac.
struct TimelineScreen: View {
    @Environment(CompanionSession.self) private var session
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var model = TimelineModel()
    @State private var selectedSession: WorkSession?
    @State private var showingCalendar = false
    @State private var isWide = false

    var body: some View {
        VStack(spacing: 0) {
            DayStrip(model: model, showingCalendar: $showingCalendar)
            Divider()
            if isWide {
                HStack(spacing: 0) {
                    ScrollView {
                        if let selectedSession {
                            SessionDetailView(session: selectedSession, timeZone: model.timeZone,
                                              windowTitlesShared: session.manifest?.dataClasses.windowTitles ?? true) {
                                self.selectedSession = nil
                            }
                            .pageColumn(maxWidth: 760)
                        } else {
                            TimelineDayPane(model: model, includesSessions: false, onSelect: select)
                        }
                    }
                    .simultaneousGesture(daySwipe)
                    Divider()
                    ScrollView {
                        SessionRail(model: model, selected: selectedSession, onSelect: select)
                            .padding(16)
                    }
                    .frame(width: 360)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Work sessions")
                }
            } else {
                ScrollView {
                    TimelineDayPane(model: model, includesSessions: true, onSelect: select)
                }
                .simultaneousGesture(daySwipe)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= LBTokens.Spacing.timelineDrawerBreakpoint } action: { wide in
            isWide = wide
        }
        .sheet(item: Binding(get: { isWide ? nil : selectedSession }, set: { selectedSession = $0 })) { session in
            NavigationStack {
                ScrollView {
                    SessionDetailView(session: session, timeZone: model.timeZone,
                                      windowTitlesShared: self.session.manifest?.dataClasses.windowTitles ?? true, onBack: nil)
                        .pageColumn(maxWidth: 760)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { selectedSession = nil } }
                }
                .companionDestinations()
            }
            .presentationDetents([.medium, .large])
        }
        .navigationTitle("Timeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.day != model.today {
                    Button("Today") { Task { await model.select(model.today, session: session) } }
                }
                Button {
                    navigator.ask(about: .init(day: model.day.description))
                } label: {
                    Label("Ask About This Day", systemImage: "sparkle.magnifyingglass")
                }
            }
        }
        .refreshable { await session.syncNow() }
        .task(id: session.revision) {
            await model.load(session)
            await consumeRequestedDay()
        }
        .onChange(of: navigator.timelineDay) { Task { await consumeRequestedDay() } }
        .onChange(of: model.day) { selectedSession = nil }
        .workspaceAnimation(.drawer, value: selectedSession)
    }

    private func select(_ session: WorkSession) {
        selectedSession = selectedSession == session ? nil : session
    }

    private func consumeRequestedDay() async {
        guard let day = navigator.timelineDay else { return }
        navigator.timelineDay = nil
        await model.select(day, session: session)
    }

    /// Swipe across the day to move a day; follows reading direction.
    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width * (layoutDirection == .rightToLeft ? -1 : 1)
                guard abs(dx) > 80, abs(dx) > abs(value.translation.height) * 2 else { return }
                if dx < 0, !model.canGoForward { return }
                Task { await model.move(by: dx < 0 ? 1 : -1, session: session) }
            }
    }
}

/// A day pushed from a search hit or Today's digest.
struct DayDigestScreen: View {
    let day: DayKey
    @Environment(CompanionSession.self) private var session
    @State private var model: TimelineModel
    @State private var selectedSession: WorkSession?

    init(day: DayKey) {
        self.day = day
        _model = State(initialValue: TimelineModel(day: day))
    }

    var body: some View {
        ScrollView {
            TimelineDayPane(model: model, includesSessions: true) { selectedSession = $0 }
        }
        .navigationTitle(LBFormat.current.dayTitle(day, today: session.today))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.revision) {
            await model.load(session)
            await model.select(day, session: session)
        }
        .sheet(item: $selectedSession) { work in
            ScrollView {
                SessionDetailView(session: work, timeZone: model.timeZone,
                                  windowTitlesShared: session.manifest?.dataClasses.windowTitles ?? true, onBack: nil)
                    .pageColumn(maxWidth: 760)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Day strip

/// The week around the chosen day. Tap a day, swipe for another week, or
/// open the calendar to jump to any earlier day.
struct DayStrip: View {
    @Environment(CompanionSession.self) private var session
    @Environment(\.layoutDirection) private var layoutDirection
    let model: TimelineModel
    @Binding var showingCalendar: Bool

    private let format = LBFormat.current

    private var week: [DayKey] {
        let calendar = Calendar.current
        let date = model.day.date(in: calendar)
        let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return (0..<7).map { DayKey(calendar.date(byAdding: .day, value: $0, to: start) ?? start, calendar: calendar) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Button { move(weeks: -1) } label: {
                    Image(systemName: "chevron.backward").frame(width: 32, height: 44)
                }
                .accessibilityLabel("Previous week")
                HStack(spacing: 4) {
                    ForEach(week) { day in cell(day) }
                }
                .frame(maxWidth: 520)
                Button { move(weeks: 1) } label: {
                    Image(systemName: "chevron.forward").frame(width: 32, height: 44)
                }
                .disabled(week.last.map { $0 >= model.today } ?? true)
                .accessibilityLabel("Next week")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.teal)
            HStack(spacing: 8) {
                Text(summary)
                    .font(LBTokens.Typography.secondary)
                    .workspaceSupportingForeground()
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    showingCalendar = true
                } label: {
                    Label("Calendar", systemImage: "calendar")
                }
                .font(LBTokens.Typography.secondary.weight(.semibold))
                .buttonStyle(.workspaceLink)
                .popover(isPresented: $showingCalendar) { calendar }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            let dx = value.translation.width * (layoutDirection == .rightToLeft ? -1 : 1)
            guard abs(dx) > 60 else { return }
            move(weeks: dx < 0 ? 1 : -1)
        })
    }

    private var summary: String {
        var parts = [format.longDay(model.day)]
        if let tracked = model.record?.timeline?.trackedSeconds, tracked > 0 {
            parts.append("\(LBFormat.hm(tracked)) tracked")
        }
        return parts.joined(separator: " · ")
    }

    private func cell(_ day: DayKey) -> some View {
        let selected = day == model.day
        let isToday = day == model.today
        let future = day > model.today
        return Button {
            Task { await model.select(day, session: session) }
        } label: {
            VStack(spacing: 3) {
                Text(format.weekday(day))
                    .font(LBTokens.Typography.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : LBTokens.Palette.supporting)
                Text("\(day.day)")
                    .font(LBTokens.Typography.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : isToday ? Brand.teal : Color.primary)
                Circle()
                    .fill(model.hasRecord(day) ? (selected ? Color.white : Brand.teal) : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                RoundedRectangle(cornerRadius: LBTokens.Radius.control, style: .continuous)
                    .fill(selected ? Brand.tealFill : Color.clear)
            }
            .contentShape(Rectangle())
            .opacity(future ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(future)
        .lbHoverEffect()
        .accessibilityLabel(format.longDay(day))
        .accessibilityValue([isToday ? "Today" : nil, model.hasRecord(day) ? "Has activity" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var calendar: some View {
        let calendar = Calendar.current
        return DatePicker(
            "Day",
            selection: Binding(get: { model.day.date(in: calendar) },
                               set: { date in
                                   showingCalendar = false
                                   Task { await model.select(DayKey(date, calendar: calendar), session: session) }
                               }),
            in: ...model.today.date(in: calendar),
            displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .tint(Brand.tealFill)
            .padding(12)
            .frame(minWidth: 320)
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.medium])
    }

    private func move(weeks: Int) {
        Task { await model.move(by: weeks * 7, session: session) }
    }
}

// MARK: - Day pane

struct TimelineDayPane: View {
    @Environment(CompanionSession.self) private var session
    let model: TimelineModel
    let includesSessions: Bool
    let onSelect: (WorkSession) -> Void

    private let format = LBFormat.current

    var body: some View {
        VStack(alignment: .leading, spacing: LBTokens.Spacing.sectionSpacing) {
            if model.record == nil && model.meetings.isEmpty {
                ContentUnavailableView("Nothing recorded", systemImage: "calendar",
                                       description: Text("Your Mac has no shared activity, meetings or digest for \(format.longDay(model.day))."))
                    .padding(.top, 40)
            } else {
                if let timeline = model.record?.timeline {
                    VStack(alignment: .leading, spacing: LBTokens.Spacing.headerToContent) {
                        Text("Activity").font(LBTokens.Typography.section).accessibilityAddTraits(.isHeader)
                        DayOverview(timeline: timeline, meetingCount: model.meetings.count)
                            .padding(16)
                            .lbGroupedSurface()
                    }
                }
                digest
                if !model.meetings.isEmpty {
                    WorkspaceSection("Meetings", icon: "waveform.circle") {
                        VStack(spacing: 0) {
                            ForEach(model.meetings) { meeting in
                                NavigationLink(value: MeetingRoute(id: meeting.id)) {
                                    HStack {
                                        MeetingRowView(meeting: meeting)
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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
                if includesSessions, let timeline = model.record?.timeline, !timeline.sessions.isEmpty {
                    SessionRail(model: model, selected: nil, onSelect: onSelect)
                }
                if let moments = model.record?.timeline?.savedMoments, !moments.isEmpty {
                    WorkspaceSection("Saved Moments", icon: "bookmark") {
                        ForEach(Array(moments.enumerated()), id: \.offset) { _, moment in
                            HStack(spacing: 10) {
                                Image(systemName: "bookmark.fill").foregroundStyle(Brand.amber).accessibilityHidden(true)
                                Text(format.time(moment.at, in: model.timeZone))
                                    .font(LBTokens.Typography.timestamp)
                                    .workspaceSupportingForeground()
                                Text(moment.label).font(LBTokens.Typography.body)
                            }
                            .padding(.vertical, 6)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .pageColumn(maxWidth: 820)
        .padding(.top, 12)
    }

    @ViewBuilder private var digest: some View {
        VStack(alignment: .leading, spacing: LBTokens.Spacing.headerToContent) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Brand.teal).accessibilityHidden(true)
                Text("Day Digest").font(LBTokens.Typography.section).accessibilityAddTraits(.isHeader)
            }
            Group {
                if let digest = model.record?.digest {
                    VStack(alignment: .leading, spacing: 12) {
                        DayDigestView(digest: digest)
                        Text((digest.userEdited ? "Edited on your Mac · " : "") + "Written \(format.time(digest.generatedAt, in: model.timeZone))")
                            .font(LBTokens.Typography.caption)
                            .workspaceSupportingForeground()
                    }
                } else {
                    Text(model.day == model.today
                         ? "Today's digest is written on your Mac in the evening."
                         : "There's no digest for this day.")
                        .workspaceTextRole(.supporting)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbGroupedSurface()
        }
    }
}
