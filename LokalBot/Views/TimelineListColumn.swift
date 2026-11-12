import SwiftUI

/// Timeline's list column: Day digest first, then the day's sessions and
/// meetings in time order under Morning, Afternoon and Evening, with All
/// captured activity at its foot. Selecting a row shows it on the page beside.
struct TimelineListColumn: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.appTextScale) private var textScale
    @ObservedObject var model: CaptureModel
    @ObservedObject var lifecycle: DayDigestLifecycle
    let list: TimelineDayList
    let hasDay: Bool
    /// The digest's first highlight.
    let digestPreview: String?
    let selection: TimelineListSelection
    let onSelect: (TimelineListSelection) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let metrics = TimelineListMetrics(textScale: textScale)
        VStack(spacing: 0) {
            TimelinePausedLine(sampler: app.sampler)
            ScrollViewReader { proxy in
                ScrollView {
                    if hasDay {
                        VStack(alignment: .leading, spacing: 0) {
                            digestRow
                                .id(TimelineListSelection.digest.scrollID)
                            rows(metrics: metrics)
                        }
                        .padding(.bottom, 10)
                    } else {
                        Text("Nothing recorded")
                            .font(AppFont.scaled(.callout))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    }
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    guard hasDay else { return .ignored }
                    let next = selection.moved(by: press.key == .upArrow ? -1 : 1, in: list)
                    guard next != selection else { return .handled }
                    onSelect(next)
                    proxy.scrollTo(next.scrollID)
                    return .handled
                }
            }
            if hasDay {
                Divider()
                rawRow
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

    // MARK: Day digest

    private var digestRow: some View {
        let state = TodayDigestLine.state(
            hasDigest: model.digest != nil, writtenAt: model.digestUpdatedAt,
            isStale: model.digestIsStale,
            isWriting: model.generating || lifecycle.isGenerating(on: model.day))
        let isStale: Bool = { if case .stale = state { return true }; return false }()
        return Button { select(.digest) } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15))
                    .foregroundStyle(LBTokens.Palette.accentText)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Day digest")
                        .font(TimelineListStyle.title.weight(.semibold))
                    if let subtitle = digestSubtitle(state) {
                        subtitle
                            .font(TimelineListStyle.detail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isStale {
                    StatusDot(color: LBTokens.Palette.accentFill, size: 7)
                        .help("New activity since")
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(TimelineListStyle.rowBackground(selected: selection == .digest))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .accessibilityLabel("Day digest")
        .accessibilityValue(isStale ? Text("New activity since") : digestSubtitle(state) ?? Text(verbatim: ""))
        .accessibilityAddTraits(selection == .digest ? .isSelected : [])
        .accessibilityIdentifier("timeline.dayDigest.row")
    }

    /// Its state while there is nothing to preview, else the first
    /// highlight. A digest without highlights has no second line.
    private func digestSubtitle(_ state: TodayDigestLine) -> Text? {
        switch state {
        case .writing: Text("Writing digest…")
        case .missing: Text("Not written yet")
        case .current, .stale: digestPreview.map { Text(verbatim: $0) }
        }
    }

    // MARK: Sessions and meetings

    private func rows(metrics: TimelineListMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list.sections) { section in
                Text(LocalizedStringKey(section.part.title))
                    .font(AppFont.scaled(.subheadline).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 9)
                    .padding(.bottom, 3)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                    switch entry {
                    case .row(let row):
                        let isSelected = selection == .row(row.id)
                        TimelineListRow(
                            row: row, metrics: metrics, isSelected: isSelected,
                            joinsAbove: Self.isRow(section.entries, at: index - 1),
                            joinsBelow: Self.isRow(section.entries, at: index + 1),
                            sceneCount: sceneCount(of: row),
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

    private func sceneCount(of row: TimelineDayList.Row) -> Int {
        guard case .work = row.kind else { return 0 }
        return model.rewindFrames.filter { $0.screenshot.ts >= row.start && $0.screenshot.ts <= row.end }.count
    }

    // MARK: All captured activity

    private var rawRow: some View {
        Button { select(.raw) } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("All captured activity")
                        .font(TimelineListStyle.title.weight(.medium))
                    TimelineCaptureCounts.text(entries: model.blocks.count, moments: model.rewindFrames.count)
                        .font(TimelineListStyle.detail.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(TimelineListStyle.rowBackground(selected: selection == .raw))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .accessibilityLabel("All captured activity")
        .accessibilityValue(TimelineCaptureCounts.text(entries: model.blocks.count, moments: model.rewindFrames.count))
        .accessibilityAddTraits(selection == .raw ? .isSelected : [])
        .accessibilityIdentifier("timeline.rawCapture")
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

/// "Day memory is paused" with Resume, above the list while tracking is
/// paused. It observes the sampler itself, which publishes too often for the
/// whole page to follow.
private struct TimelinePausedLine: View {
    @ObservedObject var sampler: ActivitySampler

    var body: some View {
        if sampler.isPaused {
            HStack(spacing: 8) {
                Image(systemName: "pause.fill")
                    .font(.scaled(.caption))
                    .accessibilityHidden(true)
                Text("Day memory is paused")
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Resume") { sampler.isPaused = false }
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
}

/// The list reads like the Meetings list: a 13-point title over a 12-point
/// second line.
enum TimelineListStyle {
    static var title: AppFont { AppFont.scaledSystem(size: 13) }
    static var detail: AppFont { AppFont.scaledSystem(size: 12) }
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
                    .foregroundStyle(.secondary)
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
                        Text(verbatim: row.detail)
                            .font(TimelineListStyle.detail)
                            .foregroundStyle(detailStyle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: CaptureStyle.hm(row.duration))
                    .font(TimelineListStyle.detail.monospacedDigit())
                    .foregroundStyle(.secondary)
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

    private var detailStyle: AnyShapeStyle {
        guard row.isMeeting else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(isLive ? LBTokens.Palette.recordingText : LBTokens.Palette.accentText)
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

/// A stretch with nothing recorded between two rows.
private struct TimelineListAwayRow: View {
    let start: Date
    let end: Date
    let metrics: TimelineListMetrics

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: metrics.leadingInset + metrics.timeWidth + metrics.axisWidth, height: 1)
            Text("Away \(CaptureStyle.hm(end.timeIntervalSince(start)))")
                .font(TimelineListStyle.detail)
                .foregroundStyle(.tertiary)
                // The label is on the text, which keeps its role; a
                // container with only a label has none.
                .accessibilityLabel("No activity from \(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))")
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
    }
}

/// One colour per project, or per app on a day without projects, from the
/// app's existing name-hashed palette. Other activity is neutral.
enum TimelineRowColor {
    static func color(for key: String?) -> Color {
        key.map(CaptureStyle.color(for:)) ?? Color.gray
    }
}
