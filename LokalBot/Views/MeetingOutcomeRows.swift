import SwiftUI

/// A plain section heading on the meeting page: a title, how many rows follow,
/// and an optional trailing control. Sections are headings and rows, not boxes.
struct MeetingSectionHeading<Trailing: View>: View {
    let title: String
    var count: Int?
    var searchQuery = ""
    var activeMatchIndex: Int?
    var searchLocation: MeetingPageSearchMatch.Location?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let searchLocation {
                    // The catalog's wording until a search needs its matches marked.
                    Group {
                        if searchQuery.isEmpty {
                            Text(LocalizedStringKey(title))
                        } else {
                            SearchHighlightedText(title, query: searchQuery, activeMatchIndex: activeMatchIndex)
                        }
                    }
                    .id(searchLocation)
                } else {
                    Text(LocalizedStringKey(title))
                }
            }
            .font(AppFont.scaled(.headline))
            if let count {
                Text(count, format: .number)
                    .font(AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension MeetingSectionHeading where Trailing == EmptyView {
    init(title: String, count: Int? = nil, searchQuery: String = "", activeMatchIndex: Int? = nil,
         searchLocation: MeetingPageSearchMatch.Location? = nil) {
        self.init(title: title, count: count, searchQuery: searchQuery, activeMatchIndex: activeMatchIndex,
                  searchLocation: searchLocation) { EmptyView() }
    }
}

/// A ▶ time beside a decision or action. It plays from there in place, so the
/// reader stays on the summary.
struct MeetingPlayTimeButton: View {
    let time: TimeInterval
    var excerpt = ""
    var searchQuery = ""
    var activeMatchIndex: Int?
    var searchLocation: MeetingPageSearchMatch.Location?
    let action: () -> Void

    var body: some View {
        let stamp = Transcript.shortStamp(time)
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 7))
                    .accessibilityHidden(true)
                if let searchLocation {
                    SearchHighlightedText(stamp, query: searchQuery, activeMatchIndex: activeMatchIndex)
                        .id(searchLocation)
                } else {
                    Text(verbatim: stamp)
                }
            }
            .font(AppFont.scaled(.callout).monospacedDigit())
            .foregroundStyle(LBTokens.Palette.accentText)
            // A comfortable click target around the small timestamp.
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(excerpt)
        .accessibilityLabel("Play from \(stamp)")
    }
}

struct MeetingDecisionRow: View {
    let decision: MeetingOutcomes.Decision
    let displayText: String
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onPlay: (OutcomeSourceCitation) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(LBTokens.Palette.successText)
                .accessibilityHidden(true)
            SearchHighlightedText(
                displayText,
                query: searchQuery,
                activeMatchIndex: activeOccurrence(for: .text))
                .id(MeetingPageSearchMatch.Location.decision(id: decision.id, field: .text))
                .font(AppFont.scaled(.body))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let citation = decision.citations.first {
                MeetingPlayTimeButton(
                    time: citation.start, excerpt: citation.excerpt,
                    searchQuery: searchQuery,
                    activeMatchIndex: activeOccurrence(for: .evidence),
                    searchLocation: .decision(id: decision.id, field: .evidence)) {
                    onPlay(citation)
                }
                .accessibilityIdentifier("meeting.decision.play.\(decision.id)")
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func activeOccurrence(for field: MeetingPageSearchMatch.DecisionField) -> Int? {
        let location = MeetingPageSearchMatch.Location.decision(id: decision.id, field: field)
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

/// One action on the meeting page. Someone else's action carries its owner as
/// a small menu; the owner turns amber while it is missing or still an unnamed
/// voice.
struct MeetingActionRow: View {
    @EnvironmentObject var app: AppState
    let reference: OutcomeActionReference
    let displayOwner: String?
    /// Shown on other people's actions. Your own say so by their group.
    var showsOwner = true
    var ownerOptions: [MeetingDetailPresentation.OwnerOption] = []
    var canNameSpeakers = false
    let searchQuery: String
    let activeMatch: MeetingPageSearchMatch?
    let onStatus: (OutcomeStatus) -> Void
    let onCorrect: () -> Void
    let onOwner: (MeetingDetailPresentation.OwnerOption) -> Void
    let onNameSpeakers: () -> Void
    let onPlay: (OutcomeSourceCitation) -> Void
    var isEditable = true
    var canSetStatus = true

    private var ownerNeedsAttention: Bool {
        MeetingDetailPresentation.ownerNeedsAttention(
            owner: reference.owner, displayOwner: displayOwner, isForUser: reference.isForUser)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { onStatus(reference.status == .done ? .open : .done) } label: {
                Image(systemName: reference.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: LBTokens.Metric.actionToggleSize))
                    .foregroundStyle(reference.status == .done ? Brand.teal : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("meeting.action.toggle.\(reference.action.id)")
            .accessibilityLabel(reference.status == .done ? "Reopen action" : "Mark action done")
            .accessibilityValue(reference.text)
            .disabled(!isEditable || !canSetStatus)
            VStack(alignment: .leading, spacing: 4) {
                SearchHighlightedText(
                    reference.text,
                    query: searchQuery,
                    activeMatchIndex: activeOccurrence(for: .text))
                    .id(MeetingPageSearchMatch.Location.action(id: reference.action.id, field: .text))
                    .font(AppFont.scaled(.body))
                    .strikethrough(reference.status == .done)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting.action.text.\(reference.action.id)")
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WorkspaceMenu(title: "Action options", symbol: "ellipsis",
                          label: "Options for action: \(reference.text)",
                          identifier: "meeting.action.status.\(reference.action.id)", items: menuItems)
            .frame(minWidth: 32, minHeight: 24)
            .fixedSize()
            .disabled(!isEditable)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var details: some View {
        let citation = reference.action.citations.first
        if showsOwner || reference.due != nil || citation != nil {
            HStack(spacing: 8) {
                if showsOwner {
                    MeetingActionOwnerMenu(
                        owner: displayOwner,
                        needsAttention: ownerNeedsAttention,
                        options: ownerOptions,
                        offersNaming: canNameSpeakers && ownerNeedsAttention && displayOwner != nil,
                        searchQuery: searchQuery,
                        activeMatchIndex: activeOccurrence(for: .owner),
                        onChoose: onOwner,
                        onNameSpeakers: onNameSpeakers)
                        .id(MeetingPageSearchMatch.Location.action(id: reference.action.id, field: .owner))
                        .disabled(!isEditable)
                        .accessibilityIdentifier("meeting.action.owner.\(reference.action.id)")
                }
                if let due = reference.due {
                    SearchHighlightedText(
                        ActionDuePresentation.label(due, spokenAt: reference.dueReferenceDate),
                        query: searchQuery,
                        activeMatchIndex: activeOccurrence(for: .due))
                        .id(MeetingPageSearchMatch.Location.action(id: reference.action.id, field: .due))
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(dueColor)
                        .lineLimit(1)
                }
                if let citation {
                    MeetingPlayTimeButton(
                        time: citation.start, excerpt: citation.excerpt,
                        searchQuery: searchQuery,
                        activeMatchIndex: activeOccurrence(for: .evidence),
                        searchLocation: .action(id: reference.action.id, field: .evidence)) {
                        onPlay(citation)
                    }
                    .accessibilityIdentifier("meeting.action.play.\(reference.action.id)")
                }
            }
        }
    }

    /// Overdue reads red, due within the week amber, anything later quiet,
    /// the same rule the Actions list uses.
    private var dueColor: Color {
        switch MeetingDetailPresentation.dueUrgency(resolved: reference.resolvedDueDate, status: reference.status) {
        case .overdue: LBTokens.Palette.recordingText
        case .soon: LBTokens.Palette.attentionText
        case .later: Color(nsColor: WorkspaceTextColor.supporting)
        }
    }

    private var menuItems: [WorkspaceMenu.Item] {
        var items: [WorkspaceMenu.Item] = OutcomeStatus.allCases.map { status in
            .init(title: status.label, enabled: canSetStatus, selected: status == reference.status,
                  action: { onStatus(status) })
        }
        items.append(.separator)
        if !ownerOptions.isEmpty {
            items.append(.init(title: "Owner", children: ownerOptions.map { option in
                .init(title: option.title, selected: option.isSelected, action: { onOwner(option) })
            }))
        }
        items += [.init(title: "Correct owner or due date", action: onCorrect),
                  .init(title: "Open in Agent", action: {
            app.openAgent(.init(
                title: reference.text,
                prompt: "Help me complete this action from \(reference.meetingTitle): \(reference.text)",
                meetingID: reference.meetingID,
                actionID: reference.action.id))
        })]
        for target in ActionAgentAvailability.installed {
            items.append(.init(title: "Open in \(target.rawValue)", action: {
                app.handOff(reference, owner: displayOwner, to: target)
            }))
        }
        items.append(.init(title: "Follow Through…", action: { app.followThrough(reference) }))
        return items
    }

    private func activeOccurrence(for field: MeetingPageSearchMatch.ActionField) -> Int? {
        let location = MeetingPageSearchMatch.Location.action(id: reference.action.id, field: field)
        guard activeMatch?.location == location else { return nil }
        return activeMatch?.occurrenceIndex
    }
}

/// An action's owner as a small menu on its row: you, this meeting's
/// speakers, people invited to it, or no owner.
struct MeetingActionOwnerMenu: View {
    let owner: String?
    let needsAttention: Bool
    let options: [MeetingDetailPresentation.OwnerOption]
    var offersNaming = false
    var searchQuery = ""
    var activeMatchIndex: Int?
    let onChoose: (MeetingDetailPresentation.OwnerOption) -> Void
    let onNameSpeakers: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Menu {
            ForEach(options.filter { $0.kind == .you || $0.kind == .speaker }) { option in
                choice(option)
            }
            let invited = options.filter { $0.kind == .invited }
            if !invited.isEmpty {
                Section("Invited") {
                    ForEach(invited) { option in choice(option) }
                }
            }
            Divider()
            if offersNaming {
                Button("Name this speaker…", action: onNameSpeakers)
            }
            ForEach(options.filter { $0.kind == .none }) { option in
                choice(option)
            }
        } label: {
            HStack(spacing: 3) {
                if let owner {
                    SearchHighlightedText(owner, query: searchQuery, activeMatchIndex: activeMatchIndex)
                } else if searchQuery.isEmpty {
                    Text("No owner")
                } else {
                    SearchHighlightedText(Self.missingOwnerText, query: searchQuery,
                                          activeMatchIndex: activeMatchIndex)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.7)
                    .accessibilityHidden(true)
            }
            .font(AppFont.scaled(.callout))
            .lineLimit(1)
            .foregroundStyle(needsAttention ? AnyShapeStyle(LBTokens.Palette.attentionText) : AnyShapeStyle(.primary))
            .padding(.leading, 7)
            .padding(.trailing, 5)
            .padding(.vertical, 2)
            .background(needsAttention ? LBTokens.Palette.attention.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(stroke)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Owner")
        .accessibilityLabel(owner.map { "Owner: \($0)" } ?? "Owner: \(Self.missingOwnerText)")
    }

    /// Search and VoiceOver read the same words the chip shows.
    static let missingOwnerText = "No owner"

    private var stroke: Color {
        if contrast == .increased { return needsAttention ? LBTokens.Palette.attentionText : .primary.opacity(0.5) }
        return needsAttention ? LBTokens.Palette.attention.opacity(0.4) : .primary.opacity(0.16)
    }

    private func choice(_ option: MeetingDetailPresentation.OwnerOption) -> some View {
        Toggle(isOn: Binding(get: { option.isSelected }, set: { _ in onChoose(option) })) {
            switch option.kind {
            case .you: Text("You")
            case .none: Text("No owner")
            case .speaker, .invited: Text(verbatim: option.title)
            }
        }
    }
}
