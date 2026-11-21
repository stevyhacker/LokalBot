import Foundation

struct QuickRecallGroup: Identifiable {
    enum Kind: String, CaseIterable {
        case recent, commands, meetings, screens, files, agentNotes, looseCommands

        var askSource: AskSourceScope? {
            switch self {
            case .recent, .commands, .looseCommands: nil
            case .meetings: .meetings
            case .screens: .screen
            case .files: .files
            case .agentNotes: .agentNotes
            }
        }

        var title: String {
            switch self {
            case .recent: "Recent"
            case .commands, .looseCommands: "Commands"
            case .meetings: "Meetings"
            case .screens: "Screens"
            case .files: "Files"
            case .agentNotes: "Agent notes"
            }
        }
    }

    let kind: Kind
    let rows: [QuickRecallRowModel]
    let total: Int
    let isCapped: Bool

    var id: String { kind.rawValue }
    var hasMore: Bool { total > rows.count || isCapped }
    var totalLabel: String { isCapped ? "\(total.formatted())+" : total.formatted() }
}

enum QuickRecallGrouping {
    static let rowsPerKind = 3
    static let recentLimit = 5

    struct Found {
        var commands: [QuickRecallRowModel] = []
        var looseCommands: [QuickRecallRowModel] = []
        var meetings: [QuickRecallRowModel] = []
        var screens: [QuickRecallRowModel] = []
        var files: [QuickRecallRowModel] = []
        var agentNotes: [QuickRecallRowModel] = []
        var isTruncated = false
        var screenSourceCount = 0
        var searchLimit = RecallSearch.displayLimit
    }

    static func groups(_ found: Found, expanded: Set<QuickRecallGroup.Kind> = [],
                       showsAgentNotes: Bool) -> [QuickRecallGroup] {
        var kinds: [(QuickRecallGroup.Kind, [QuickRecallRowModel], Int)] = [
            (.commands, found.commands, found.commands.count),
            (.meetings, found.meetings, found.meetings.count),
            (.screens, found.screens, max(found.screens.count, found.screenSourceCount)),
            (.files, found.files, found.files.count),
        ]
        if showsAgentNotes { kinds.append((.agentNotes, found.agentNotes, found.agentNotes.count)) }
        kinds.append((.looseCommands, found.looseCommands, found.looseCommands.count))
        return kinds.compactMap { kind, rows, listed in
            guard !rows.isEmpty else { return nil }
            let isCommands = kind == .commands || kind == .looseCommands
            let capped = !isCommands && found.isTruncated && listed >= found.searchLimit
            return QuickRecallGroup(
                kind: kind,
                rows: expanded.contains(kind) ? rows : Array(rows.prefix(rowsPerKind)),
                total: rows.count, isCapped: capped)
        }
    }

    static func idle(recent: [QuickRecallRowModel], commands: [QuickRecallRowModel]) -> [QuickRecallGroup] {
        [
            QuickRecallGroup(kind: .recent, rows: recent, total: recent.count, isCapped: false),
            QuickRecallGroup(kind: .commands, rows: commands, total: commands.count, isCapped: false),
        ].filter { !$0.rows.isEmpty }
    }
}

enum QuickRecallRecent {
    struct MeetingItem {
        var id: UUID
        var title: String
        var duration: String?
        var startedAt: Date
    }

    static func rows(meetings: [MeetingItem], savedMoments: [ActivityStore.SavedMoment],
                     limit: Int = QuickRecallGrouping.recentLimit) -> [QuickRecallRowModel] {
        struct Entry {
            var date: Date
            var order: Int
            var row: QuickRecallRowModel
        }
        var entries: [Entry] = meetings.map { meeting in
            Entry(date: meeting.startedAt, order: 0, row: QuickRecallRowModel.recentMeeting(
                id: meeting.id, title: meeting.title, duration: meeting.duration, startedAt: meeting.startedAt))
        }
        entries += savedMoments.map { Entry(date: $0.ts, order: 1, row: QuickRecallRowModel.saved($0)) }
        entries.sort { left, right in
            left.date != right.date ? left.date > right.date : left.order < right.order
        }
        return entries.prefix(max(0, limit)).map(\.row)
    }
}

struct QuickRecallCursor: Equatable {
    enum Target: Equatable {
        case row(Int)
        case ask
    }

    private(set) var index: Int?

    init(index: Int? = nil) { self.index = index }

    mutating func reset(rowCount: Int) {
        index = rowCount > 0 ? 0 : nil
    }

    mutating func move(by offset: Int, rowCount: Int, hasAsk: Bool) {
        let count = rowCount + (hasAsk ? 1 : 0)
        guard count > 0 else {
            index = nil
            return
        }
        guard let current = index, current < count else {
            index = offset >= 0 ? 0 : count - 1
            return
        }
        index = ((current + offset) % count + count) % count
    }

    func target(rowCount: Int, hasAsk: Bool) -> Target? {
        guard let index, index >= 0 else { return nil }
        if index < rowCount { return .row(index) }
        return hasAsk && index == rowCount ? .ask : nil
    }

    mutating func select(_ target: Target, rowCount: Int) {
        switch target {
        case .row(let row): index = min(max(0, row), max(0, rowCount - 1))
        case .ask: index = rowCount
        }
    }
}

struct QuickRecallAskScope: Equatable {
    var answer: AskAnswerScope
    var sources: Set<AskSourceScope>
    var meetingIDs: Set<UUID>?
    var screenSnapshotIDs: Set<Int64>?

    static func resolve(query: String, meetingIDs: Set<UUID>, screenIDs: Set<Int64>,
                        isRememberStatement: Bool) -> QuickRecallAskScope {
        let answer = AskAnswerScope.resolve(
            query: query, hasMatches: !meetingIDs.isEmpty || !screenIDs.isEmpty,
            isRememberStatement: isRememberStatement)
        guard answer == .listedMatches else {
            return QuickRecallAskScope(answer: .chosenSources, sources: AskSourceScope.defaults)
        }
        var state = RecallWorkspaceState()
        state.selectEvidence(meetingIDs: meetingIDs, screenIDs: screenIDs)
        return QuickRecallAskScope(answer: .listedMatches, sources: state.sources,
                                   meetingIDs: state.meetingIDs, screenSnapshotIDs: state.screenIDs)
    }
}

extension QuickRecallAskScope {
    static func readsListedMatches(query: String, hasMatches: Bool, isSearching: Bool,
                                   isRememberStatement: Bool) -> Bool {
        AskAnswerScope.resolve(query: query, hasMatches: hasMatches || isSearching,
                               isRememberStatement: isRememberStatement) == .listedMatches
    }

    static func askRowDetail(inference: InferencePresentation, readsListedMatches: Bool,
                             localize: (String) -> String = { $0 }) -> String {
        switch inference {
        case .onDevice:
            return localize(readsListedMatches ? "Answers from these matches, on this Mac"
                                               : "Answers from all your sources, on this Mac")
        case .remote(let host):
            return String(format: localize(readsListedMatches ? "Answers from these matches, using %@"
                                                              : "Answers from all your sources, using %@"), host)
        case .blocked:
            return localize("Model connection blocked")
        }
    }

    static func answerFootLabel(inference: InferencePresentation, isAnswered: Bool, scope: String?,
                                localize: (String) -> String = { $0 }) -> String {
        let place: String
        switch inference {
        case .onDevice:
            place = localize(isAnswered ? "Answered on this Mac" : "On this Mac")
        case .remote(let host):
            place = String(format: localize(isAnswered ? "Answered with %@" : "Remote · %@"), host)
        case .blocked:
            return localize("Model connection blocked")
        }
        guard let scope, !scope.isEmpty else { return place }
        return "\(place) · \(scope)"
    }
}

enum QuickRecallQuote {
    static func terms(in question: String) -> [String] {
        var seen = Set<String>()
        return question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !SearchIndex.stopWords.contains($0) && seen.insert($0).inserted }
    }

    static func line(_ text: String?, question: String, limit: Int = 200) -> String? {
        guard let plain = CitationPassage.quote(text, limit: 4_000) else { return nil }
        let excerpt = RecallPassage.excerpt(plain, query: question, limit: limit)
            ?? CitationPassage.quote(plain, limit: limit) ?? plain
        return marked(excerpt, terms: terms(in: question))
    }

    static func marked(_ text: String, terms: [String]) -> String {
        guard !terms.isEmpty else { return text }
        let folded = terms.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let candidate = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if folded.contains(where: { candidate.hasPrefix($0) }) { ranges.append(range) }
        }
        var result = ""
        var cursor = text.startIndex
        for range in ranges {
            result += text[cursor..<range.lowerBound]
            result += "«" + text[range] + "»"
            cursor = range.upperBound
        }
        return result + text[cursor...]
    }
}
