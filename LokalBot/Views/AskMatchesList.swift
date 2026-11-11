import AppKit
import SwiftUI

/// The matches for what is typed in Ask: a row per meeting, screen moment,
/// file or saved agent note, each with the lines that matched. The same list sits under the field
/// on a new question, in the tray above the field inside a conversation, and
/// under an answer that failed. Clicking a title or a line opens it.
struct AskMatchesList: View {
    enum Style { case card, tray }

    @EnvironmentObject private var app: AppState
    @Environment(\.appTextScale) private var textScale

    let matches: AskMatches
    /// The searched text, so a file opens with its words marked.
    let query: String
    var style: Style = .card
    /// The row the arrow keys are on, if they left the field.
    var selected: Int?
    var pinnedScreenIDs: Set<Int64> = []
    var togglePin: ((ActivityStore.OCRHit) -> Void)?
    /// Rows whose folded lines are showing. The page keeps this when it
    /// lays the list out more than once (the tray, which may scroll).
    var expandedRows: Binding<Set<String>>?

    @State private var locallyExpanded: Set<String> = []

    private var expanded: Set<String> { expandedRows?.wrappedValue ?? locallyExpanded }

    private func expand(_ key: String) {
        if let expandedRows {
            expandedRows.wrappedValue.insert(key)
        } else {
            locallyExpanded.insert(key)
        }
    }

    /// How many matching lines a row lists before folding the rest.
    private static let foldedLineCount = 3

    static func rowID(_ index: Int) -> String { "ask.match.\(index)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(matches.meetings.enumerated()), id: \.element.id) { index, group in
                if index > 0 { rowDivider }
                meetingRow(group, index: index)
            }
            ForEach(Array(matches.screens.enumerated()), id: \.element.id) { offset, group in
                let index = matches.meetings.count + offset
                if index > 0 { rowDivider }
                screenRow(group, index: index)
            }
            ForEach(Array(matches.files.enumerated()), id: \.element.id) { offset, hit in
                let index = matches.meetings.count + matches.screens.count + offset
                if index > 0 { rowDivider }
                fileRow(hit, index: index)
            }
            ForEach(Array(matches.agentNotes.enumerated()), id: \.element.id) { offset, hit in
                let index = matches.meetings.count + matches.screens.count + matches.files.count + offset
                if index > 0 { rowDivider }
                agentNoteRow(hit, index: index)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Matches")
        .accessibilityIdentifier("search.results")
    }

    @ViewBuilder private var rowDivider: some View {
        if style == .card { Divider().padding(.leading, 14) }
    }

    // MARK: Meetings

    private func meetingRow(_ group: MeetingRecallGroup, index: Int) -> some View {
        let meeting = app.meetings.first { $0.id == group.id }
        let primary = group.primary
        let lines = [primary] + group.matches.filter { $0.id != primary.id }
        let isExpanded = expanded.contains(group.id.uuidString)
        let shown = isExpanded ? lines : Array(lines.prefix(Self.foldedLineCount))
        return rowShell(index: index) {
            AskSourceTile(symbol: "waveform")
        } content: {
            rowTitle(meeting?.displayTitle ?? app.settings.appLanguage.localized("Meeting"),
                     trailing: meeting.map { AskDateLabel.moment($0.startedAt, locale: locale) }) {
                app.openSearchHit(primary)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { _, hit in
                line(identifier: "search.hit.\(hit.meetingID.uuidString).\(hit.kind.rawValue)",
                     snippet: hit.snippet, isSemantic: hit.isSemantic) {
                    app.openSearchHit(hit)
                } kind: {
                    meetingKind(hit)
                }
            }
            moreButton(hidden: lines.count - shown.count, key: group.id.uuidString)
        }
    }

    @ViewBuilder private func meetingKind(_ hit: SearchIndex.Hit) -> some View {
        switch hit.kind {
        case .segment:
            HStack(spacing: 4) {
                AskTimeStamp(seconds: hit.start)
                if !hit.speaker.isEmpty {
                    Text(verbatim: "· " + SpeakerDisplayName.label(hit.speaker)).lineLimit(1)
                }
            }
        case .title: Text("Title")
        case .summary: Text("Summary")
        case .notes: Text("Your notes")
        case .outcome: Text("Outcome")
        }
    }

    // MARK: Screen moments

    private func screenRow(_ group: ScreenRecallGroup, index: Int) -> some View {
        let primary = group.primary
        let title = primary.windowTitle.isEmpty ? primary.app : primary.windowTitle
        let when = AskDateLabel.moment(primary.ts, locale: locale)
        let isExpanded = expanded.contains(group.id)
        let rest = isExpanded ? Array(group.matches.dropFirst()) : []
        return rowShell(index: index) {
            ScreenThumbnailView(snapshotID: primary.snapshotID, height: 30, cornerRadius: 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(LBTokens.Palette.groupStroke)
                }
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                rowTitle(title, trailing: primary.windowTitle.isEmpty ? when : "\(primary.app) · \(when)") {
                    app.openScreenSnapshot(primary.snapshotID)
                }
                if let togglePin { pinButton(primary, toggle: togglePin) }
            }
            line(identifier: "screen.hit.\(primary.snapshotID)",
                 snippet: SnippetCleaner.withoutTitleEcho(primary.snippet, title: title) ?? primary.snippet,
                 isSemantic: primary.isSemantic, lineLimit: 2) {
                app.openScreenSnapshot(primary.snapshotID)
            } kind: {
                EmptyView()
            }
            ForEach(rest) { hit in
                line(identifier: "screen.hit.\(hit.snapshotID)",
                     snippet: SnippetCleaner.withoutTitleEcho(hit.snippet, title: title) ?? hit.snippet,
                     isSemantic: hit.isSemantic) {
                    app.openScreenSnapshot(hit.snapshotID)
                } kind: {
                    Text(verbatim: hit.ts.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                }
            }
            moreButton(hidden: isExpanded ? 0 : group.matches.count - 1, key: group.id)
        }
    }

    private func pinButton(_ hit: ActivityStore.OCRHit,
                           toggle: @escaping (ActivityStore.OCRHit) -> Void) -> some View {
        let isPinned = pinnedScreenIDs.contains(hit.snapshotID)
        return Button { toggle(hit) } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(isPinned ? AnyShapeStyle(LBTokens.Palette.accentText) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Remove from Ask context" : "Use as Ask context")
        .accessibilityLabel(isPinned ? "Unpin screen from context" : "Pin screen as context")
    }

    // MARK: Files

    private func fileRow(_ hit: FileSearchHit, index: Int) -> some View {
        rowShell(index: index) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: hit.path))
                .resizable()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
        } content: {
            rowTitle(hit.name, trailing: hit.folder) { FileSearchOpener.open(hit, query: query) }
            line(identifier: "file.hit.\(hit.id)",
                 snippet: hit.excerpt ?? AskDateLabel.day(hit.date, locale: locale),
                 isSemantic: hit.isSemantic, lineLimit: 2) {
                FileSearchOpener.open(hit, query: query)
            } kind: {
                Text(verbatim: hit.kindLabel).lineLimit(1)
            }
            .contextMenu {
                Button("Open") { FileSearchOpener.open(hit, query: query) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) }
            }
        }
    }

    // MARK: Agent notes

    /// A note a coding agent saved for itself: its title, the agent and
    /// project, then the matched words. It opens the agent's own file.
    private func agentNoteRow(_ hit: AgentNoteHit, index: Int) -> some View {
        rowShell(index: index) {
            AskSourceTile(symbol: "note.text")
        } content: {
            rowTitle(hit.title, trailing: hit.sourceLabel) { AgentNoteOpener.open(hit) }
            line(identifier: "agentNote.hit.\(hit.id)",
                 snippet: hit.snippet.isEmpty ? (hit.summary ?? hit.path) : hit.snippet,
                 isSemantic: false, lineLimit: 2) {
                AgentNoteOpener.open(hit)
            } kind: {
                Text(verbatim: AskDateLabel.day(hit.modified, locale: locale)).lineLimit(1)
            }
            .contextMenu {
                Button("Open") { AgentNoteOpener.open(hit) }
                Button("Show in Finder") { AgentNoteOpener.reveal(hit) }
            }
            .help(hit.path)
        }
    }

    // MARK: Row anatomy

    private var locale: Locale { app.settings.appLanguage.locale }

    private func rowShell<Lead: View, Content: View>(
        index: Int, @ViewBuilder lead: () -> Lead, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            lead().frame(width: 44, height: 30)
            VStack(alignment: .leading, spacing: 3) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, style == .card ? 14 : 10)
        .padding(.vertical, style == .card ? 12 : 9)
        .background(selected == index ? LBTokens.Palette.accentFill.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
        .accessibilityAddTraits(selected == index ? .isSelected : [])
        .id(Self.rowID(index))
    }

    private func rowTitle(_ title: String, trailing: String?, open: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: open) {
                Text(verbatim: title)
                    .font(AppFont.scaled(.body).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(AskTitleButtonStyle())
            Spacer(minLength: 8)
            if let trailing {
                Text(verbatim: trailing)
                    .font(AppFont.scaled(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .layoutPriority(-1)
            }
        }
    }

    private func line<Kind: View>(
        identifier: String, snippet: String, isSemantic: Bool, lineLimit: Int = 1,
        action: @escaping () -> Void, @ViewBuilder kind: () -> Kind
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if Kind.self != EmptyView.self {
                    kind()
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(.secondary)
                        .frame(width: style == .card ? 120 * textScale : nil, alignment: .leading)
                }
                if isSemantic {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Related by meaning")
                        .accessibilityLabel("Related by meaning")
                }
                highlighted(snippet)
                    .font(AppFont.scaled(.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(AskLineButtonStyle())
        .padding(.horizontal, -6)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private func moreButton(hidden: Int, key: String) -> some View {
        if hidden > 0 {
            Button { expand(key) } label: {
                Text("Show \(hidden) more").font(AppFont.scaled(.callout))
            }
            .buttonStyle(.workspaceLink)
            .padding(.top, 1)
            .accessibilityIdentifier("ask.matches.more")
        }
    }

    private func highlighted(_ snippet: String) -> Text {
        SnippetHighlighter.segments(snippet).reduce(Text(verbatim: "")) { text, segment in
            text + (segment.isMatch
                ? Text(verbatim: segment.text).bold().foregroundStyle(.primary)
                : Text(verbatim: segment.text))
        }
    }
}

/// "Matches · 3 in 1 meeting", and the keys that act on them.
struct AskMatchesHeader: View {
    struct KeyHint: Identifiable {
        let key: String
        let action: LocalizedStringKey
        var id: String { key }
    }

    let countLabel: String?
    var isSearching = false
    /// Return was pressed while matches were still arriving; the question
    /// goes out once they are in.
    var isWaitingToAsk = false
    var hints: [KeyHint] = []

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Matches")
                .font(AppFont.scaled(.body).weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if isSearching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Searching local sources…")
                        .font(AppFont.scaled(.callout))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(isWaitingToAsk ? "ask.waitingForSources" : "ask.searching")
            } else if let countLabel {
                Text(verbatim: countLabel)
                    .font(AppFont.scaled(.callout).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ask.matches.count")
            }
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                hintRow
                EmptyView()
            }
        }
    }

    private var hintRow: some View {
        HStack(spacing: 10) {
            ForEach(hints) { hint in
                HStack(spacing: 5) {
                    Text(verbatim: hint.key)
                        .font(AppFont.scaled(.subheadline))
                        .padding(.horizontal, 4)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12))
                        }
                    Text(hint.action).font(AppFont.scaled(.callout))
                }
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize()
        // The keys are announced by the field's own hint.
        .accessibilityHidden(true)
    }
}

/// The small rounded tile that leads a meeting row here and in an answer's
/// sources list.
struct AskSourceTile: View {
    let symbol: String
    var size = CGSize(width: 44, height: 30)

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size.height * 0.45, weight: .medium))
            .foregroundStyle(LBTokens.Palette.accentText)
            .frame(width: size.width, height: size.height)
            .background(LBTokens.Palette.groupFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(LBTokens.Palette.groupStroke)
            }
            .accessibilityHidden(true)
    }
}

/// A transcript time in the accent colour, with the small play mark.
struct AskTimeStamp: View {
    let seconds: TimeInterval

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 7))
                .accessibilityHidden(true)
            Text(verbatim: Transcript.shortStamp(seconds))
                .font(AppFont.scaled(.callout).monospacedDigit())
        }
        .foregroundStyle(LBTokens.Palette.accentText)
        .fixedSize()
    }
}

/// White card chrome for matches and source lists on the Ask page.
extension View {
    func askCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(AskCardModifier(cornerRadius: cornerRadius))
    }
}

private struct AskCardModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color(nsColor: .controlBackgroundColor), in: shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : LBTokens.Palette.groupStroke,
                                   lineWidth: contrast == .increased ? 2 : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

/// A source's name: plain text that underlines on hover, like a link.
struct AskTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Label(configuration: configuration) }

    private struct Label: View {
        @State private var hovered = false
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .underline(hovered)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// One matching line or suggestion: a quiet row that tints on hover.
struct AskLineButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct Label: View {
        @State private var hovered = false
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat

        var body: some View {
            configuration.label
                .background(Color.primary.opacity(configuration.isPressed ? 0.08 : hovered ? 0.045 : 0),
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onHover { hovered = $0 }
        }
    }
}
