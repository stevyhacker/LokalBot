import SwiftUI

/// Timeline's rail, on the trailing side of the day's page: the tracked total
/// with the hour strip and its legend, then the day's sessions and meetings in
/// time order under Morning, Afternoon and Evening, with All captured activity
/// pinned as its bottom row. Choosing a row, or a bar of the strip, shows it
/// on the page beside; choosing it again returns to the day.
struct TimelineRail<Banner: View>: View {
    @Environment(\.appTextScale) private var textScale
    /// Nil on a day with no tracked time and no meetings.
    let tracked: TimelineTrackedSummary?
    let list: TimelineDayList
    let hasDay: Bool
    /// "3 activity entries · 0 screen moments".
    let captureCounts: Text
    let selection: TimelineListSelection
    /// Screen moments kept during a session, for its row's spoken value.
    var sceneCount: (TimelineDayList.Row) -> Int = { _ in 0 }
    let onSelect: (TimelineListSelection) -> Void
    /// The paused line, above everything else.
    @ViewBuilder var banner: Banner
    @FocusState private var focused: Bool

    var body: some View {
        let metrics = TimelineListMetrics(textScale: textScale)
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                banner
                if hasDay {
                    if let tracked {
                        TimelineTrackedBlock(summary: tracked, rows: list.rows) { select(.row($0)) }
                        Divider()
                    }
                    sessionsHeader
                    ScrollView {
                        rows(metrics: metrics)
                            .padding(.bottom, 6)
                    }
                    Divider()
                    rawRow
                } else {
                    Text("Nothing recorded")
                        .font(AppFont.scaled(.callout))
                        .workspaceSupportingForeground()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    Spacer(minLength: 0)
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard hasDay else { return .ignored }
                let next = selection.moved(by: press.key == .upArrow ? -1 : 1, in: list)
                if next != selection { onSelect(next) }
                return .handled
            }
            // A bar of the strip, or an arrow key, can choose a row the list
            // has scrolled away from.
            .onChange(of: selection) { _, selected in
                if case .row = selected { proxy.scrollTo(selected.scrollID) }
            }
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.list")
    }

    private func select(_ target: TimelineListSelection) {
        focused = true
        onSelect(target)
    }

    // MARK: Sessions and meetings

    private var sessionsHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Sessions")
                .font(SectionPanelMetric.titleFont)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            SectionPanelPill(text: Text(list.rows.count, format: .number), tone: .count)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TimelineListStyle.inset)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private func rows(metrics: TimelineListMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list.sections) { section in
                if section.id != list.sections.first?.id {
                    Divider()
                        .padding(.horizontal, TimelineListStyle.inset)
                        .padding(.top, 5)
                }
                Text(LocalizedStringKey(section.part.title))
                    .font(TimelineListStyle.heading)
                    .workspaceSupportingForeground()
                    .padding(.horizontal, TimelineListStyle.inset)
                    .padding(.top, 8)
                    .padding(.bottom, 3)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                    switch entry {
                    case .row(let row):
                        TimelineListRow(
                            row: row, metrics: metrics, isSelected: selection == .row(row.id),
                            joinsAbove: Self.isRow(section.entries, at: index - 1),
                            joinsBelow: Self.isRow(section.entries, at: index + 1),
                            sceneCount: sceneCount(row),
                            onSelect: { select(.row(row.id)) })
                            .id(TimelineListSelection.row(row.id).scrollID)
                    case .away(let start, let end):
                        TimelineListAwayRow(start: start, end: end, metrics: metrics)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.workSessions")
    }

    private static func isRow(_ entries: [TimelineDayList.Entry], at index: Int) -> Bool {
        guard entries.indices.contains(index), case .row = entries[index] else { return false }
        return true
    }

    // MARK: All captured activity

    private var rawRow: some View {
        Button { select(.raw) } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 15))
                    .workspaceSupportingForeground()
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("All captured activity")
                        .font(TimelineListStyle.title.weight(.medium))
                        .lineLimit(1)
                    captureCounts
                        .font(TimelineListStyle.detail.monospacedDigit())
                        .workspaceSupportingForeground()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.scaled(.caption).weight(.semibold))
                    .workspaceSupportingForeground()
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(TimelineListStyle.rowBackground(selected: selection == .raw))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .padding(.bottom, 6)
        .accessibilityLabel("All captured activity")
        .accessibilityValue(captureCounts)
        .accessibilityAddTraits(selection == .raw ? .isSelected : [])
        .accessibilityIdentifier("timeline.rawCapture")
    }
}

extension TimelineRail where Banner == EmptyView {
    init(tracked: TimelineTrackedSummary?, list: TimelineDayList, hasDay: Bool, captureCounts: Text,
         selection: TimelineListSelection, onSelect: @escaping (TimelineListSelection) -> Void) {
        self.init(tracked: tracked, list: list, hasDay: hasDay, captureCounts: captureCounts,
                  selection: selection, onSelect: onSelect, banner: { EmptyView() })
    }
}

/// "3 activity entries · 0 screen moments", each count its own catalog entry.
enum TimelineCaptureCounts {
    static func text(entries: Int, moments: Int) -> Text {
        Text(entries == 1 ? "\(entries) activity entry" : "\(entries) activity entries")
            + Text(verbatim: " · ")
            + Text(moments == 1 ? "\(moments) screen moment" : "\(moments) screen moments")
    }
}

extension TimelineListSelection {
    /// The identity a row scrolls into view by.
    var scrollID: String {
        switch self {
        case .digest: "digest"
        case .row(let id): id
        case .raw: "raw"
        case .none: ""
        }
    }
}

/// "Day memory is paused" with Resume, at the top of the rail while tracking
/// is paused. It observes the sampler itself, which publishes too often for
/// the whole page to follow.
struct TimelinePausedLine: View {
    @ObservedObject var sampler: ActivitySampler

    var body: some View {
        if sampler.isPaused {
            TimelinePausedBanner { sampler.isPaused = false }
        }
    }
}

struct TimelinePausedBanner: View {
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.fill")
                .font(.scaled(.caption))
                .accessibilityHidden(true)
            Text("Day memory is paused")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Resume", action: onResume)
                .buttonStyle(.workspaceLink)
                .accessibilityIdentifier("timeline.dayMemory.resume")
        }
        .font(AppFont.scaled(.callout))
        .foregroundStyle(LBTokens.Palette.attentionText)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .lbStatusSurface(LBTokens.Palette.attention)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.dayMemory.paused")
    }
}

// MARK: - Tracked

/// The top of the rail: the day's total in large type, the meetings and what
/// the agents recorded, the hour strip, and where the time went as rows.
struct TimelineTrackedBlock: View {
    let summary: TimelineTrackedSummary
    let rows: [TimelineDayList.Row]
    let onSelectRow: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: CaptureStyle.hm(summary.tracked))
                        .font(AppFont.scaledSystem(size: 22, weight: .bold).monospacedDigit())
                    Text("tracked")
                        .font(AppFont.scaled(.body))
                        .workspaceSupportingForeground()
                }
                if let detail = summary.detail {
                    Text(verbatim: detail)
                        .font(AppFont.scaled(.callout))
                        .workspaceSupportingForeground()
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("timeline.dayOutcomes")
                }
            }
            if let strip = summary.strip {
                TimelineDayStripView(strip: strip, rows: rows, onSelectRow: onSelectRow)
            }
            legend
        }
        .padding(.horizontal, TimelineListStyle.inset)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.dayOverview")
    }

    /// Each project's time, or each app's on a day without projects, then
    /// the meetings' total. App and project names are shown as captured.
    @ViewBuilder private var legend: some View {
        if !summary.legend.isEmpty || summary.meetingSeconds > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(summary.legend) { entry in
                    legendRow(label(entry), seconds: entry.seconds) {
                        StatusDot(color: TimelineRowColor.color(for: entry.colorKey), size: 8)
                    }
                }
                if summary.meetingSeconds > 0 {
                    legendRow(Text("Meetings"), seconds: summary.meetingSeconds) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LBTokens.Palette.accentFill)
                            .frame(width: 8, height: 4)
                    }
                }
            }
            .font(AppFont.scaled(.callout))
        }
    }

    private func legendRow<Mark: View>(_ name: Text, seconds: TimeInterval,
                                       @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 8) {
            mark()
                .frame(width: 8)
                .accessibilityHidden(true)
            name
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: CaptureStyle.hm(seconds))
                .monospacedDigit()
                .workspaceSupportingForeground()
                .fixedSize()
        }
    }

    private func label(_ entry: TimelineDayLegend.Entry) -> Text {
        switch entry.kind {
        case .app, .otherApps, .project: Text(verbatim: entry.label)
        case .otherProjects: Text("Other projects")
        case .otherActivity: Text("Other activity")
        }
    }
}

/// The day strip: hour lines and labels, a thin lane of meetings above the
/// lane of work. A bar chooses its row in the list under it.
struct TimelineDayStripView: View {
    @Environment(\.appTextScale) private var textScale
    let strip: TimelineDayStrip
    let rows: [TimelineDayList.Row]
    let onSelectRow: (String) -> Void

    private static let meetingLaneHeight: CGFloat = 9
    private static let workLaneTop: CGFloat = 13
    private static let workLaneHeight: CGFloat = 20
    private static let labelTop: CGFloat = 37

    /// The lanes, then one line of hour labels at the current text size.
    private var height: CGFloat { Self.labelTop + (15 * max(1, textScale)).rounded(.up) }

    var body: some View {
        let height = height
        GeometryReader { geometry in
            let width = geometry.size.width
            // About one label every 44 points keeps "12 PM" clear of its neighbours.
            let labelWidth: CGFloat = 44 * max(1, textScale)
            let labelled = strip.labelledTicks(fitting: max(1, Int(width / labelWidth)))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LBTokens.Palette.quietFill)
                    .frame(width: width, height: Self.workLaneHeight)
                    .offset(y: Self.workLaneTop)
                ForEach(strip.ticks, id: \.date) { tick in
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1, height: Self.workLaneTop + Self.workLaneHeight)
                        .offset(x: CGFloat(tick.position) * width)
                }
                ForEach(labelled, id: \.date) { tick in
                    Text(tick.date, format: Self.hourStyle(namesDayPeriod: tick.namesDayPeriod))
                        .font(AppFont.scaled(.subheadline).monospacedDigit())
                        .workspaceSupportingForeground()
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: CGFloat(tick.position) * width + 3, y: Self.labelTop)
                }
                ForEach(TimelineDayStrip.hitOrder(strip.meetings)) { bar in
                    segment(bar, width: width, top: 0, height: Self.meetingLaneHeight,
                            color: LBTokens.Palette.accentFill)
                }
                ForEach(TimelineDayStrip.hitOrder(strip.work)) { bar in
                    segment(bar, width: width, top: Self.workLaneTop, height: Self.workLaneHeight,
                            color: TimelineRowColor.color(for: bar.colorKey))
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
        .frame(height: height)
        // Hours run left to right in every language, like a clock's day; the
        // bars are placed by offset, which does not mirror.
        .environment(\.layoutDirection, .leftToRight)
        // The list under the strip has the same rows, each with its name and
        // times, so assistive technologies read the strip as one picture.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day chronology")
        // Without a trait the strip has no role at all.
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("timeline.dayStrip")
    }

    /// "8 AM" for the first hour and noon, "9" for the rest; a 24-hour clock
    /// shows the hour either way.
    private static func hourStyle(namesDayPeriod: Bool) -> Date.FormatStyle {
        let style = Date.FormatStyle.dateTime
        return namesDayPeriod ? style.hour() : style.hour(.defaultDigits(amPM: .omitted))
    }

    /// The bar is as wide as its time. A click a little to either side of a
    /// thin one still chooses it.
    @ViewBuilder
    private func segment(_ bar: TimelineDayStrip.Bar, width: CGFloat, top: CGFloat,
                         height: CGFloat, color: Color) -> some View {
        let frame = TimelineDayStrip.frame(of: bar, in: width)
        let hit = TimelineDayStrip.hitFrame(of: bar, in: width)
        let row = rows.first { $0.id == bar.id }
        Button { onSelectRow(bar.id) } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: max(1, frame.width - 1), height: height)
                .padding(.leading, max(0, frame.x - hit.x))
                .frame(width: hit.width, height: height, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: hit.x, y: top)
        .help(row.map { "\($0.title) · \(CaptureStyle.hm($0.duration))" } ?? "")
    }
}

// MARK: - Rows

/// The list reads like the Meetings list: a 13-point title over a 12-point
/// second line.
enum TimelineListStyle {
    static var title: AppFont { AppFont.scaledSystem(size: 13) }
    static var detail: AppFont { AppFont.scaledSystem(size: 12) }
    /// Morning, Afternoon, Evening.
    static var heading: AppFont { AppFont.scaledSystem(size: 11, weight: .bold) }
    /// From the rail's edge to its text, the panels' own inset.
    static let inset: CGFloat = SectionPanelMetric.inset
    /// The selected row, as a list shows its selection while another pane has the keyboard.
    static let selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    static func rowBackground(selected: Bool, hovering: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: Brand.Radius.row, style: .continuous)
            .fill(selected ? selection : hovering ? Color.primary.opacity(0.04) : .clear)
    }
}

/// Column widths of a row. The time has no AM or PM, since the list is
/// already under Morning, Afternoon and Evening, and follows the text size.
struct TimelineListMetrics {
    let timeWidth: CGFloat
    let axisWidth: CGFloat = 24
    /// The row's padding before its time.
    let leadingInset: CGFloat = 4
    /// From the row's top edge to the centre of its dot.
    let dotCenterY: CGFloat

    init(textScale: CGFloat) {
        let scale = max(1, textScale)
        timeWidth = (38 * scale).rounded()
        dotCenterY = (5 + 8 * scale).rounded()
    }

    /// The marker's height, which centres the dot on `dotCenterY` under the
    /// row's 5-point top padding.
    var markerHeight: CGFloat { (dotCenterY - 5) * 2 }

    /// From the row's leading edge to the line through the dots.
    var spineLeading: CGFloat {
        let center = leadingInset + timeWidth + axisWidth / 2
        return center - 0.75
    }
}

/// A row's time, in the interface's language and time zone.
private struct TimelineListTime: View {
    let date: Date
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        Text(verbatim: TimelineListClock.text(date, locale: locale, timeZone: timeZone))
    }
}

private struct TimelineListRow: View {
    let row: TimelineDayList.Row
    let metrics: TimelineListMetrics
    let isSelected: Bool
    /// A row above or below continues the line through the dots.
    let joinsAbove: Bool
    let joinsBelow: Bool
    let sceneCount: Int
    let onSelect: () -> Void
    @State private var hovering = false

    private var isLive: Bool {
        if case .meeting(_, let isLive) = row.kind { return isLive }
        return false
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 0) {
                TimelineListTime(date: row.start)
                    .font(TimelineListStyle.detail.monospacedDigit())
                    .workspaceSupportingForeground()
                    .lineLimit(1)
                    .frame(width: metrics.timeWidth, alignment: .trailing)
                    .padding(.top, 1)
                marker
                    .frame(width: metrics.axisWidth, height: metrics.markerHeight)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.title)
                        .font(row.isQuiet ? TimelineListStyle.title : TimelineListStyle.title.weight(.medium))
                        .foregroundStyle(row.isQuiet
                            ? AnyShapeStyle(Color(nsColor: WorkspaceTextColor.supporting))
                            : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !row.detail.isEmpty {
                        detail
                            .font(TimelineListStyle.detail)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: CaptureStyle.hm(row.duration))
                    .font(TimelineListStyle.detail.monospacedDigit())
                    .workspaceSupportingForeground()
                    .fixedSize()
                    .padding(.leading, 10)
                    .padding(.top, 1)
            }
            .padding(.vertical, 5)
            .padding(.leading, metrics.leadingInset)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(alignment: .topLeading) { spine }
            .background(TimelineListStyle.rowBackground(selected: isSelected, hovering: hovering))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// Meetings keep the waveform and the accent; a session shows the colour
    /// of its project, the same one its bar has in the day strip.
    @ViewBuilder private var marker: some View {
        let ground = isSelected ? AnyShapeStyle(TimelineListStyle.selection) : AnyShapeStyle(.background)
        if row.isMeeting {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isLive ? LBTokens.Palette.recordingText : LBTokens.Palette.accentText)
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 4).fill(ground))
                .accessibilityHidden(true)
        } else {
            Circle()
                .fill(TimelineRowColor.color(for: row.colorKey))
                .frame(width: 9, height: 9)
                .padding(2.5)
                .background(Circle().fill(ground))
                .accessibilityHidden(true)
        }
    }

    /// One line runs through the dots of neighbouring rows, so the list reads
    /// as a day. It starts at the first dot and ends at the last.
    @ViewBuilder private var spine: some View {
        if joinsAbove || joinsBelow {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1.5)
                .frame(maxHeight: joinsBelow ? .infinity : metrics.dotCenterY, alignment: .top)
                .padding(.top, joinsAbove ? 0 : metrics.dotCenterY)
                // Padding, not an offset, so the line follows a right-to-left layout.
                .padding(.leading, metrics.spineLeading)
                .accessibilityHidden(true)
        }
    }

    /// A meeting's second line keeps the accent, or red while it records.
    @ViewBuilder private var detail: some View {
        let text = Text(verbatim: row.detail)
        if row.isMeeting {
            text.foregroundStyle(isLive ? LBTokens.Palette.recordingText : LBTokens.Palette.accentText)
        } else {
            text.workspaceSupportingForeground()
        }
    }

    private var identifier: String {
        switch row.kind {
        case .work(let session): "timeline.session.\(session)"
        case .meeting(let meeting, _): "capture.meeting.\(meeting.uuidString)"
        }
    }

    private var timeRange: String {
        (row.start..<max(row.end, row.start)).formatted(date: .omitted, time: .shortened)
    }

    private var helpText: String {
        row.detail.isEmpty ? "\(row.title)\n\(timeRange)" : "\(row.title)\n\(row.detail)\n\(timeRange)"
    }

    private var accessibilityLabel: Text {
        let kind = row.isMeeting ? Text("Meeting, \(row.title)") : Text("Work session, \(row.title)")
        return row.detail.isEmpty || row.isMeeting ? kind : kind + Text(verbatim: ", \(row.detail)")
    }

    private var accessibilityValue: Text {
        let base = Text(verbatim: "\(timeRange), \(CaptureStyle.hm(row.duration))")
        guard !row.isMeeting, sceneCount > 0 else { return base }
        let moments: Text = sceneCount == 1
            ? Text("\(sceneCount) screen moment") : Text("\(sceneCount) screen moments")
        return base + Text(verbatim: ", ") + moments
    }
}

/// A stretch with nothing recorded between two rows: a dotted piece of the
/// line through the dots, and how long it lasted.
private struct TimelineListAwayRow: View {
    let start: Date
    let end: Date
    let metrics: TimelineListMetrics

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: metrics.leadingInset + metrics.timeWidth, height: 1)
            TimelineDottedSpine()
                .stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 3]))
                .frame(width: metrics.axisWidth)
                .accessibilityHidden(true)
            Text("Away \(CaptureStyle.hm(end.timeIntervalSince(start)))")
                .font(TimelineListStyle.detail)
                .workspaceSupportingForeground()
                // The label is on the text, which keeps its role; a
                // container with only a label has none.
                .accessibilityLabel("No activity from \(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))")
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
    }
}

private struct TimelineDottedSpine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + 2))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 2))
        return path
    }
}

/// One colour per project, or per app on a day without projects, from the
/// app's existing name-hashed palette. Other activity is neutral.
enum TimelineRowColor {
    static func color(for key: String?) -> Color {
        key.map(CaptureStyle.color(for:)) ?? Color.gray
    }
}
