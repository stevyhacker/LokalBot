import SwiftUI

private enum DayDigestTaskType {
    static var sectionTitle: AppFont { AppFont.scaled(.headline) }
    static var taskTitle: AppFont { AppFont.scaled(.body).weight(.semibold) }
    static var summary: AppFont { AppFont.scaled(.callout) }
    static var briefTitle: AppFont { AppFont.scaled(.body) }
    static var tag: AppFont { AppFont.scaled(.subheadline) }
}

/// Human-first rendering of the lossless Markdown day journal. Summary and
/// focus stay visible; the forensic activity/evidence trail is available on
/// demand without making every captured moment compete for attention.
struct DayDigestView: View {
    enum Mode: Equatable {
        case standalone
        case timeline
        /// Timeline's content on a wide page: sessions become a card grid and
        /// prose keeps a reading width.
        case today

        var showsMeetings: Bool { self == .standalone }
        var arrangesSessionsInGrid: Bool { self == .today }
        var showsTimeAllocation: Bool { self == .standalone }
        var showsFullActivityLog: Bool { self == .standalone }
        var showsOtherActivity: Bool { self == .standalone }
    }

    let presentation: DayDigestPresentation
    let mode: Mode

    @State private var fullActivityExpanded = false
    @State private var otherActivityExpanded = false
    @State private var timeAllocationExpanded = false
    @State private var sessionGridWidth: CGFloat = 0

    init(_ markdown: String, mode: Mode = .standalone) {
        presentation = DayDigestPresentation(markdown: markdown)
        self.mode = mode
    }

    var body: some View {
        fullContent
    }

    private var fullContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !presentation.blockers.isEmpty {
                blockersCallout
            }

            if !presentation.atAGlanceMarkdown.isEmpty {
                digestSection("Highlights", icon: "sparkles") {
                    SelectableDigestText(presentation.atAGlanceMarkdown)
                        .frame(maxWidth: proseMaxWidth, alignment: .leading)
                }
            }

            if !presentation.decisions.isEmpty {
                if mode == .timeline {
                    timelineDecisions
                } else {
                    digestSection("Decisions", icon: "checkmark.seal") {
                        SelectableDigestText(Self.bulletList(presentation.decisions))
                            .frame(maxWidth: proseMaxWidth, alignment: .leading)
                    }
                }
            }

            if !presentation.focusBlocks.isEmpty, mode == .timeline {
                timelineTaskSections
            } else if !presentation.focusBlocks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "briefcase")
                            .accessibilityHidden(true)
                        Text(mode == .today ? "Tasks" : "Work Summary")
                            .font(DayDigestTaskType.sectionTitle)
                            .accessibilityIdentifier("dayDigest.tasks")
                    }
                    .foregroundStyle(.primary)
                    // Every task stays visible as one scannable line; only
                    // the description of what was done opens on demand.
                    if mode.arrangesSessionsInGrid {
                        sessionGrid
                    } else {
                        taskList
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !presentation.followUps.isEmpty {
                digestSection("Follow-ups", icon: "arrow.turn.down.right") {
                    taskRows(presentation.followUps)
                }
            }

            if mode.showsOtherActivity, !presentation.otherActivityBlocks.isEmpty {
                DisclosureGroup(isExpanded: $otherActivityExpanded) {
                    sessionList(presentation.otherActivityBlocks)
                        .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Label("Other activity", systemImage: "ellipsis.circle")
                            .font(.scaled(.subheadline).weight(.medium))
                        Spacer()
                        let count = presentation.otherActivityBlocks.count
                        Text(count == 1 ? "\(count) item" : "\(count) items")
                            .font(.scaled(.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("dayDigest.otherActivity")
                .accessibilityHint("Shorter activities that used a smaller share of the recorded day")
            }

            if mode.showsMeetings, let meetings = presentation.meetingsMarkdown {
                digestSection("Meetings", icon: "person.2") {
                    SelectableDigestText(meetings)
                }
            }

            if mode.showsMeetings, let sessions = presentation.agentSessionsMarkdown {
                digestSection("Agent sessions", icon: "terminal") {
                    SelectableDigestText(sessions)
                }
            }

            if mode.showsTimeAllocation, !presentation.timeAllocations.isEmpty {
                timeAllocationDisclosure
            }

            if mode.showsFullActivityLog, presentation.activityCount > 0 {
                DisclosureGroup(isExpanded: $fullActivityExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(presentation.activityGroups) { group in
                            DayDigestActivityHourView(group: group)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Label("Full activity log", systemImage: "clock.arrow.circlepath")
                            .font(.scaled(.subheadline).weight(.semibold))
                        Spacer()
                        let count = presentation.activityCount
                        Text(count == 1 ? "\(count) event" : "\(count) events")
                            .font(.scaled(.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("dayDigest.fullActivityLog")
                .accessibilityHint("Contains the complete activity log grouped by hour")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var proseMaxWidth: CGFloat {
        mode == .today ? WorkspaceMetric.readingMaxWidth : .infinity
    }

    private var sessionColumnCount: Int {
        switch sessionGridWidth {
        case 900...: 3
        case 560...: 2
        default: 1
        }
    }

    /// Blockers lead the digest: they are what stops the day's open work.
    private var blockersCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(presentation.blockers.count == 1 ? "Blocker" : "Blockers",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.scaled(.subheadline).weight(.semibold))
                .foregroundStyle(LBTokens.Palette.attentionText)
            SelectableDigestText(presentation.blockers.count == 1
                ? presentation.blockers[0]
                : Self.bulletList(presentation.blockers))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbStatusSurface(LBTokens.Palette.attention)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dayDigest.blockers")
    }

    /// Open work first, then finished work, each task on its own line.
    private var taskList: some View {
        let groups = presentation.taskGroups
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    if groups.count > 1 {
                        (Text(listTitle(of: group.kind)) + Text(verbatim: " · ") + Text(group.blocks.count, format: .number))
                            .font(.scaled(.subheadline).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.bottom, 2)
                    }
                    taskRows(group.blocks)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Timeline gives each status its own section. Tasks with a next step stay
    /// in full, the rest of the open work becomes one-line rows, and finished
    /// work folds into a single Done line.
    private var timelineTaskSections: some View {
        let groups = presentation.taskGroups
        return VStack(alignment: .leading, spacing: 22) {
            ForEach(groups) { group in
                let rows = presentation.timelineRows(of: group)
                let isFirst = group.id == groups.first?.id
                if group.kind == .completed, presentation.isTaskFirst {
                    DayDigestDoneSection(blocks: rows.brief, identifiesTasks: isFirst)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(timelineTitle(of: group.kind))
                                .font(DayDigestTaskType.sectionTitle)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier(isFirst ? "dayDigest.tasks" : "dayDigest.tasks.\(group.kind)")
                            Text(group.blocks.count, format: .number)
                                .font(.scaled(.callout).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 2)
                        taskRows(rows.full, showsTags: true)
                        if !rows.brief.isEmpty {
                            DayDigestBriefTaskList(
                                blocks: rows.brief,
                                followsFullRows: !rows.full.isEmpty)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listTitle(of kind: DayDigestPresentation.TaskGroup.Kind) -> LocalizedStringKey {
        switch kind {
        case .blocked: "Blocked"
        case .inProgress: "In progress"
        case .other: "Other work"
        case .completed: "Done"
        }
    }

    private func timelineTitle(of kind: DayDigestPresentation.TaskGroup.Kind) -> LocalizedStringKey {
        switch kind {
        case .blocked: "Blocked"
        case .inProgress: "In Progress"
        case .other: presentation.isTaskFirst ? "Other Work" : "Work Summary"
        case .completed: "Done"
        }
    }

    private var timelineDecisions: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Plain text like the other modes' Decisions label, so a
            // static-text query can tell whether the section is shown.
            Text("Decisions")
                .font(DayDigestTaskType.sectionTitle)
            ForEach(Array(presentation.decisions.enumerated()), id: \.offset) { _, decision in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(DayDigestTaskType.summary)
                        .foregroundStyle(LBTokens.Palette.accentText)
                        .frame(width: DayDigestTaskRow.textInset - 8)
                        .accessibilityHidden(true)
                    SelectableDigestText(decision)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func taskRows(_ blocks: [DayDigestPresentation.FocusBlock],
                          showsTags: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                DayDigestTaskRow(block: block,
                                 collapsesDetails: presentation.collapsesDetails(of: block),
                                 showsTag: showsTags)
                    .padding(.vertical, 7)
                if block.id != blocks.last?.id {
                    Divider().padding(.leading, DayDigestTaskRow.textInset)
                }
            }
        }
    }

    private static func bulletList(_ items: [String]) -> String {
        items.map { "- " + $0 }.joined(separator: "\n")
    }

    /// Each task becomes its own card, filling the page width instead of
    /// nesting a boxed list inside the digest.
    private var sessionGrid: some View {
        let blocks = presentation.taskGroups.flatMap(\.blocks)
        let columns = sessionColumnCount
        let rows = stride(from: 0, to: blocks.count, by: columns).map {
            Array(blocks[$0..<min($0 + columns, blocks.count)])
        }
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index]) { block in
                        DayDigestTaskRow(block: block,
                                         collapsesDetails: presentation.collapsesDetails(of: block))
                            .padding(WorkspaceMetric.cardPadding)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(.quaternary.opacity(0.24),
                                        in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                            .overlay {
                                RoundedRectangle(cornerRadius: Brand.Radius.panel)
                                    .strokeBorder(Color.primary.opacity(0.09))
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sessionGridWidth = $0 }
    }

    private func digestSection<Content: View>(
        _ title: LocalizedStringKey,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.scaled(.subheadline).weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionList(_ blocks: [DayDigestPresentation.FocusBlock]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                focusBlock(block)
                    .padding(.vertical, 10)
                if block.id != blocks.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: Brand.Radius.control)
                .fill(.quaternary.opacity(0.24))
        }
    }

    private func focusBlock(_ block: DayDigestPresentation.FocusBlock) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if block.timeRange != nil || block.title != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let timeRange = block.timeRange {
                        Text(timeRange)
                            .font(.scaled(.caption).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let title = block.title {
                        Text(title)
                            .font(.scaled(.body).weight(.semibold))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }
            if !block.summaryMarkdown.isEmpty {
                SelectableDigestText(block.summaryMarkdown)
                    .foregroundStyle(.secondary)
            }
            DayDigestSourceLinks(ids: block.sourceIDs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeAllocationDisclosure: some View {
        let total = presentation.timeAllocations.reduce(0) { $0 + $1.seconds }
        let segments = ProportionBarMath.segments(perApp: presentation.timeAllocations.map {
            (label: $0.app, seconds: $0.seconds)
        })
        return DisclosureGroup(isExpanded: $timeAllocationExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if total > 0 {
                    ProportionBar(segments: segments.map {
                        ($0, $0.label == "Other"
                            ? Color(nsColor: .tertiaryLabelColor)
                            : CaptureStyle.color(for: $0.label))
                    })
                    .padding(.vertical, 2)
                }
                ForEach(presentation.timeAllocations.prefix(12)) { allocation in
                    HStack(spacing: 8) {
                        StatusDot(color: CaptureStyle.color(for: allocation.app), size: 8)
                        Text(allocation.app).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(allocation.detail)
                            .font(allocation.seconds > 0
                                ? .scaled(.callout).monospacedDigit() : .scaled(.callout))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Label("Time allocation", systemImage: "chart.bar.xaxis")
                    .font(.scaled(.subheadline).weight(.semibold))
                Spacer()
                Text("Activity details")
                    .font(.scaled(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("dayDigest.timeAllocation")
        .accessibilityHint("Tracked app time shown as optional supporting detail")
    }
}

/// One task at a glance: status, title, and its next step. What was done
/// opens in place, so a day of tasks reads as a short list.
private struct DayDigestTaskRow: View {
    /// Status column width plus spacing; details and dividers align to it.
    static let textInset: CGFloat = 26

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let block: DayDigestPresentation.FocusBlock
    /// See `DayDigestPresentation.collapsesDetails(of:)`.
    let collapsesDetails: Bool
    /// Timeline shows a title's trailing "(Project)" as a tag.
    var showsTag = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if collapsesDetails {
                Button {
                    withAnimation(WorkspaceMotion.animation(.disclosure, reduceMotion: reduceMotion)) {
                        expanded.toggle()
                    }
                } label: {
                    header.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Hides what was done" : "Shows what was done")
                .accessibilityIdentifier("dayDigest.task.\(block.id)")

                if expanded {
                    details
                        .padding(.leading, Self.textInset)
                        .transition(WorkspaceMotion.disclosureTransition(reduceMotion: reduceMotion))
                }
            } else {
                header
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusMark
                .frame(width: Self.textInset - 8)
            VStack(alignment: .leading, spacing: 3) {
                if block.timeRange != nil || block.title != nil {
                    titleLine
                }
                if let nextStep = block.nextStep {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("Next")
                            .font(DayDigestTaskType.summary.weight(.semibold))
                            .foregroundStyle(LBTokens.Palette.accentText)
                        Text(nextStep)
                            .font(DayDigestTaskType.summary)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !collapsesDetails {
                    details
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if collapsesDetails {
                Image(systemName: "chevron.right")
                    .font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let timeRange = block.timeRange {
                Text(timeRange)
                    .font(.scaled(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let title = block.title {
                let parts: (title: String, tag: String?) = showsTag
                    ? DayDigestPresentation.titleAndTag(title) : (title, nil)
                Text(parts.title)
                    .font(DayDigestTaskType.taskTitle)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let tag = parts.tag { DayDigestTaskTag(text: tag) }
            }
        }
    }

    @ViewBuilder private var statusMark: some View {
        switch block.status {
        case .completed:
            statusSymbol("checkmark.circle.fill", LBTokens.Palette.success, label: "Done")
        case .inProgress:
            statusSymbol("circle.lefthalf.filled", LBTokens.Palette.accentText, label: "In progress")
        case .blocked:
            statusSymbol("exclamationmark.circle.fill", LBTokens.Palette.attention, label: "Blocked")
        case nil:
            Text("•")
                .font(DayDigestTaskType.taskTitle)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private func statusSymbol(_ name: String, _ color: Color, label: LocalizedStringKey) -> some View {
        Image(systemName: name)
            .font(DayDigestTaskType.taskTitle)
            .foregroundStyle(color)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var details: some View {
        if !block.summaryMarkdown.isEmpty {
            if collapsesDetails {
                SelectableDigestText(block.summaryMarkdown, font: DayDigestTaskType.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ExpandableDigestSummary(
                    text: block.summaryMarkdown,
                    accessibilityID: "dayDigest.taskShowMore.\(block.id)")
            }
        }
        DayDigestSourceLinks(ids: block.sourceIDs)
    }
}

/// A project or pull request split off a task title.
private struct DayDigestTaskTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DayDigestTaskType.tag)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}

/// One line for a task without a next step. What was done opens in place.
private struct DayDigestBriefTaskRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let block: DayDigestPresentation.FocusBlock
    var isDone = false
    @State private var expanded = false
    @State private var hovering = false

    private var hasDetails: Bool {
        block.title != nil && (!block.summaryMarkdown.isEmpty || !block.sourceIDs.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasDetails {
                Button {
                    withAnimation(WorkspaceMotion.animation(.disclosure, reduceMotion: reduceMotion)) {
                        expanded.toggle()
                    }
                } label: {
                    line.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Hides what was done" : "Shows what was done")
                .accessibilityIdentifier("dayDigest.task.\(block.id)")

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        if !block.summaryMarkdown.isEmpty {
                            SelectableDigestText(block.summaryMarkdown, font: DayDigestTaskType.summary)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        DayDigestSourceLinks(ids: block.sourceIDs)
                    }
                    .padding(.leading, DayDigestTaskRow.textInset)
                    .transition(WorkspaceMotion.disclosureTransition(reduceMotion: reduceMotion))
                }
            } else {
                line
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var line: some View {
        let parts = DayDigestPresentation.titleAndTag(block.title ?? block.summaryMarkdown)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
                .frame(width: DayDigestTaskRow.textInset - 8)
            Text(parts.title)
                .font(DayDigestTaskType.briefTitle)
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.tail)
                .help(block.title ?? "")
            if let tag = parts.tag { DayDigestTaskTag(text: tag) }
            Spacer(minLength: 0)
            if hasDetails {
                Image(systemName: "chevron.right")
                    .font(.scaled(.caption).weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(hovering || expanded ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var marker: some View {
        if isDone {
            Image(systemName: "checkmark")
                .font(DayDigestTaskType.summary.weight(.semibold))
                .foregroundStyle(LBTokens.Palette.success)
                .accessibilityLabel("Done")
        } else {
            Text("•")
                .font(DayDigestTaskType.briefTitle)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

/// One-line rows for open tasks without a next step. A long list shows its
/// first rows until asked for the rest.
private struct DayDigestBriefTaskList: View {
    let blocks: [DayDigestPresentation.FocusBlock]
    /// Below full rows, a heading says what these rows are.
    let followsFullRows: Bool
    var visibleLimit = 8
    @State private var showsAll = false

    var body: some View {
        // Hiding a single row would cost as much room as showing it.
        let folds = blocks.count > visibleLimit + 1
        let visible = folds && !showsAll ? Array(blocks.prefix(visibleLimit)) : blocks
        VStack(alignment: .leading, spacing: 0) {
            if followsFullRows {
                Text("\(blocks.count) more without a next step")
                    .font(.scaled(.subheadline).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            }
            ForEach(visible) { block in
                DayDigestBriefTaskRow(block: block)
            }
            if folds {
                Button(showsAll ? "Show fewer" : "Show \(blocks.count - visibleLimit) more") {
                    showsAll.toggle()
                }
                .buttonStyle(.workspaceLink)
                .font(AppFont.scaled(.callout))
                .padding(.leading, DayDigestTaskRow.textInset)
                .padding(.top, 4)
                .accessibilityIdentifier("dayDigest.showAllTasks")
            }
        }
    }
}

/// Finished tasks fold into one line that names them; opening it lists each.
private struct DayDigestDoneSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let blocks: [DayDigestPresentation.FocusBlock]
    /// With no open work, Done is the first task section and carries its
    /// identifier.
    let identifiesTasks: Bool
    @State private var expanded = false

    private var preview: String {
        blocks.compactMap { block in
            block.title.map { DayDigestPresentation.titleAndTag($0).title }
        }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(WorkspaceMotion.animation(.disclosure, reduceMotion: reduceMotion)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(DayDigestTaskType.taskTitle)
                        .foregroundStyle(LBTokens.Palette.success)
                        .frame(width: DayDigestTaskRow.textInset - 8)
                        .accessibilityHidden(true)
                    Text("Done")
                        .font(DayDigestTaskType.sectionTitle)
                    Text(blocks.count, format: .number)
                        .font(.scaled(.callout).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !expanded {
                        Text(preview)
                            .font(DayDigestTaskType.summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.scaled(.caption).weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides the finished tasks" : "Lists the finished tasks")
            .accessibilityIdentifier(identifiesTasks ? "dayDigest.tasks" : "dayDigest.done")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks) { block in
                        DayDigestBriefTaskRow(block: block, isDone: true)
                    }
                }
                .padding(.top, 4)
                .transition(WorkspaceMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Screen moments a legacy journal cited for a task.
private struct DayDigestSourceLinks: View {
    @EnvironmentObject private var app: AppState
    let ids: [Int64]

    var body: some View {
        ForEach(ids, id: \.self) { id in
            if let shot = app.activityStore.screenshot(id: id) {
                Button { app.openScreenSnapshot(id) } label: {
                    Label("\(shot.documentName.isEmpty ? shot.app : shot.documentName) · \(shot.ts.formatted(date: .omitted, time: .shortened))", systemImage: "doc.text.magnifyingglass")
                        .font(AppFont.scaled(.callout))
                }.buttonStyle(.workspaceLink)
            } else {
                Text("Source moment unavailable").font(AppFont.scaled(.callout)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExpandableDigestSummary: View {
    let text: String
    let accessibilityID: String
    @State private var expanded = false
    @State private var truncatedByLayout = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    private var showsControl: Bool {
        truncatedByLayout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectableDigestText(text, font: DayDigestTaskType.summary)
                .foregroundStyle(.primary)
                .lineLimit(expanded ? nil : DayDigestTaskSummaryExpansion.collapsedLineLimit)
                .truncationMode(.tail)
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: DigestSummaryCollapsedHeightKey.self,
                            value: geo.size.height)
                    }
                }
                .background(alignment: .top) { fullHeightProbe }
                .onPreferenceChange(DigestSummaryFullHeightKey.self) { fullHeight = $0 }
                .onPreferenceChange(DigestSummaryCollapsedHeightKey.self) { collapsedHeight = $0 }
                .onChange(of: fullHeight) { _, _ in refreshTruncation() }
                .onChange(of: collapsedHeight) { _, _ in refreshTruncation() }

            if showsControl {
                Button(expanded ? "Show less" : "Show more") {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(AppFont.scaled(.body))
                .foregroundStyle(Brand.teal)
                .accessibilityHint(expanded
                    ? "Hides the extra task description"
                    : "Shows the rest of this task description")
                .accessibilityIdentifier(accessibilityID)
            }
        }
    }

    private var fullHeightProbe: some View {
        SelectableDigestText(text, font: DayDigestTaskType.summary)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: DigestSummaryFullHeightKey.self,
                        value: geo.size.height)
                }
            }
            .frame(height: 0, alignment: .top)
            .allowsHitTesting(false)
    }

    private func refreshTruncation() {
        guard !expanded else { return }
        truncatedByLayout = DayDigestTaskSummaryExpansion.hasRenderedOverflow(
            fullHeight: fullHeight,
            collapsedHeight: collapsedHeight)
    }
}

private struct DigestSummaryFullHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DigestSummaryCollapsedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct DayDigestActivityHourView: View {
    let group: DayDigestPresentation.ActivityHourGroup
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.entries) { entry in
                    DayDigestActivityEntryView(entry: entry)
                    if entry.id != group.entries.last?.id {
                        Divider().padding(.vertical, 7)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            HStack {
                Text(group.label)
                    .font(.scaled(.callout).weight(.medium).monospacedDigit())
                Spacer()
                let count = group.entries.count
                Text(count == 1 ? "\(count) event" : "\(count) events")
                    .font(.scaled(.caption).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("dayDigest.activityHour.\(group.id)")
    }
}

private struct DayDigestActivityEntryView: View {
    let entry: DayDigestPresentation.ActivityEntry
    @State private var evidenceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectableDigestText(entry.headlineMarkdown)
            if !entry.evidenceMarkdown.isEmpty {
                DisclosureGroup(isExpanded: $evidenceExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entry.evidenceMarkdown.enumerated()), id: \.offset) { _, line in
                            SelectableDigestText("- " + line)
                                .font(.scaled(.callout))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Captured evidence · \(entry.evidenceMarkdown.count)")
                        .font(.scaled(.caption).weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("dayDigest.activityEvidence.\(entry.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
