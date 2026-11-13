import Foundation

// What the Quick Recall window lists and where its keyboard is: results
// grouped by kind and capped, the recent items shown before typing, the
// selection, and what an answer asked from the window reads. Nothing here
// searches, stores or sends anything.

/// One group of rows under a heading.
struct QuickRecallGroup: Identifiable {
    enum Kind: String, CaseIterable {
        case recent, commands, meetings, screens, files, agentNotes, looseCommands

        /// The Ask source a "Show all" link narrows the full Ask screen to.
        /// Commands and recent items are not searched there.
        var askSource: AskSourceScope? {
            switch self {
            case .recent, .commands, .looseCommands: nil
            case .meetings: .meetings
            case .screens: .screen
            case .files: .files
            case .agentNotes: .agentNotes
            }
        }

        /// The heading, as a catalog key.
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
    /// The rows shown.
    let rows: [QuickRecallRowModel]
    /// How many the search listed for this kind.
    let total: Int
    /// The search stopped at its own limit, so `total` is a floor.
    let isCapped: Bool

    var id: String { kind.rawValue }
    /// More were found than are shown, so the heading offers "Show all".
    var hasMore: Bool { total > rows.count || isCapped }
    /// "7", or "40+" when the search stopped at its limit: never a count
    /// that reads as exact when it is not.
    var totalLabel: String { isCapped ? "\(total.formatted())+" : total.formatted() }
}

enum QuickRecallGrouping {
    /// Rows of one kind listed before "Show all". A large number of screen
    /// matches used to push every meeting out of view.
    static let rowsPerKind = 3
    /// Recent items listed before anything is typed.
    static let recentLimit = 5

    /// Everything one search found, each kind in its ranked order.
    struct Found {
        var commands: [QuickRecallRowModel] = []
        /// Commands that only hold the typed words somewhere. They are listed
        /// last, so a search word that happens to sit inside a command's name
        /// does not put that command under Return.
        var looseCommands: [QuickRecallRowModel] = []
        var meetings: [QuickRecallRowModel] = []
        var screens: [QuickRecallRowModel] = []
        var files: [QuickRecallRowModel] = []
        var agentNotes: [QuickRecallRowModel] = []
        /// The search listed fewer than it found (`RecallSearch.Result.isTruncated`).
        var isTruncated = false
        /// Screen sources the search listed. Saved moments can fold two of
        /// them into one row, so the rows alone can hide that the list was cut.
        var screenSourceCount = 0
        /// The most the search lists of one kind.
        var searchLimit = RecallSearch.displayLimit
    }

    /// The groups for a typed search, in a fixed order: commands (only when
    /// the typed words match one), meetings, screens, files, then agent
    /// notes while that source is on. Empty groups are left out. `expanded`
    /// lists the kinds whose heading was asked to show everything in place.
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
            // Commands are counted here, never cut by a search limit.
            let isCommands = kind == .commands || kind == .looseCommands
            let capped = !isCommands && found.isTruncated && listed >= found.searchLimit
            return QuickRecallGroup(
                kind: kind,
                rows: expanded.contains(kind) ? rows : Array(rows.prefix(rowsPerKind)),
                total: rows.count, isCapped: capped)
        }
    }

    /// Before anything is typed: recent items, then every command.
    static func idle(recent: [QuickRecallRowModel], commands: [QuickRecallRowModel]) -> [QuickRecallGroup] {
        [
            QuickRecallGroup(kind: .recent, rows: recent, total: recent.count, isCapped: false),
            QuickRecallGroup(kind: .commands, rows: commands, total: commands.count, isCapped: false),
        ].filter { !$0.rows.isEmpty }
    }
}

/// Recent meetings and saved screen moments as one list, newest first.
enum QuickRecallRecent {
    struct MeetingItem {
        var id: UUID
        var title: String
        /// "32 min", or nil while it is still recording.
        var duration: String?
        var startedAt: Date
    }

    static func rows(meetings: [MeetingItem], savedMoments: [ActivityStore.SavedMoment],
                     limit: Int = QuickRecallGrouping.recentLimit) -> [QuickRecallRowModel] {
        struct Entry {
            var date: Date
            /// A meeting and a moment of the same instant list the meeting first.
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

/// Where the keyboard is in the list: on a row, or on the Ask row pinned
/// under the results. Return opens a row and asks on the Ask row; ⌘Return
/// asks from anywhere.
struct QuickRecallCursor: Equatable {
    enum Target: Equatable {
        case row(Int)
        case ask
    }

    /// The selected position: rows first, then the Ask row. Nil when nothing
    /// is selected, so Return does nothing instead of asking by surprise.
    private(set) var index: Int?

    init(index: Int? = nil) { self.index = index }

    /// The first row is selected when there is one. With no rows nothing is,
    /// and the Ask row waits for an arrow key or ⌘Return.
    mutating func reset(rowCount: Int) {
        index = rowCount > 0 ? 0 : nil
    }

    /// Arrow keys go round the rows and the Ask row.
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

    /// Keeps the Ask row selected when the rows above it change.
    mutating func select(_ target: Target, rowCount: Int) {
        switch target {
        case .row(let row): index = min(max(0, row), max(0, rowCount - 1))
        case .ask: index = rowCount
        }
    }
}

/// What an answer asked from Quick Recall reads. A word or a short phrase is
/// a search the person then asks about: the answer is limited to the listed
/// meetings and screen moments, as ⌘Return always was. A full question reads
/// everything in every source, by the rule the Ask screen uses
/// (`AskAnswerScope`); so does a "Remember …" statement, and a search that
/// listed no meeting or screen moment to limit it to.
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
        // The same narrowing the Ask screen applies to handed-over matches.
        var state = RecallWorkspaceState()
        state.selectEvidence(meetingIDs: meetingIDs, screenIDs: screenIDs)
        return QuickRecallAskScope(answer: .listedMatches, sources: state.sources,
                                   meetingIDs: state.meetingIDs, screenSnapshotIDs: state.screenIDs)
    }
}

extension QuickRecallAskScope {
    /// Whether the Ask row should say the answer comes from the listed
    /// matches. While a word's matches are still being found it does: the
    /// question waits for them.
    static func readsListedMatches(query: String, hasMatches: Bool, isSearching: Bool,
                                   isRememberStatement: Bool) -> Bool {
        AskAnswerScope.resolve(query: query, hasMatches: hasMatches || isSearching,
                               isRememberStatement: isRememberStatement) == .listedMatches
    }

    /// The Ask row's grey line: what the answer will read, and where it is
    /// written. A remote model is named, so nothing is sent by surprise.
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

    /// The foot of an answer: where it was answered, then what it read
    /// ("All sources", a meeting's title, "3 meetings, 1 screen moment").
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

/// A source's quoted line under an answer, with the question's words marked
/// the way search results mark theirs (« »), so both lists read alike.
enum QuickRecallQuote {
    /// The words of a question worth marking: three letters or more, without
    /// the search index's stop words.
    static func terms(in question: String) -> [String] {
        var seen = Set<String>()
        return question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !SearchIndex.stopWords.contains($0) && seen.insert($0).inserted }
    }

    /// `text` cut to the part around the question's words, with each word
    /// that starts with one of them between « and ».
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
