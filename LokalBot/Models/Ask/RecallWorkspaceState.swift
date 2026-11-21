import Foundation

@MainActor
final class RecallWorkspace: ObservableObject {
    @Published var query = ""
    @Published var state = RecallWorkspaceState()
}

struct RecallWorkspaceState {
    var meetingIDs: Set<UUID>?
    var screenIDs: Set<Int64>?
    var selectedResult = 0
    var facet: AskFacet = .all
    var screenApp: String?
    var sources = AskSourceScope.defaults
    var pins: [ScreenAskContext] = []
    private(set) var sourcesBeforeEvidence: Set<AskSourceScope>?
    private struct PinScope {
        var screenIDs: Set<Int64>?
        var screenWasEnabled: Bool
    }
    private var scopeBeforePins: PinScope?

    mutating func selectEvidence(meetingIDs: Set<UUID>?, screenIDs: Set<Int64>?,
                                 sources selectedSources: Set<AskSourceScope>? = nil) {
        clearPins(restoringScope: true)
        guard meetingIDs != nil || screenIDs != nil else {
            clearEvidence()
            if let selectedSources { sources = selectedSources }
            return
        }
        sourcesBeforeEvidence = sourcesBeforeEvidence ?? sources
        self.meetingIDs = meetingIDs
        self.screenIDs = screenIDs
        if let selectedSources {
            sources = selectedSources
        } else {
            sources = []
            if meetingIDs?.isEmpty == false { sources.insert(.meetings) }
            if screenIDs?.isEmpty == false { sources.insert(.screen) }
            if sources.isEmpty { sources = [.meetings] }
        }
    }

    mutating func selectResultEvidence(meetingIDs: Set<UUID>, screenIDs: Set<Int64>, hadFiles: Bool = false,
                                       hadAgentNotes: Bool = false) {
        let keepsActivity = sources.contains(.today)
        let keepsFiles = hadFiles && sources.contains(.files)
        let keepsNotes = hadAgentNotes && sources.contains(.agentNotes)
        selectEvidence(meetingIDs: meetingIDs, screenIDs: screenIDs)
        if keepsActivity { sources.insert(.today) }
        if keepsFiles { sources.insert(.files) }
        if keepsNotes { sources.insert(.agentNotes) }
    }

    mutating func chooseSources(_ selection: Set<AskSourceScope>) {
        sources = selection
        scopeBeforePins?.screenWasEnabled = selection.contains(.screen)
        sourcesBeforeEvidence = nil
    }

    mutating func clearEvidence() {
        clearPins(restoringScope: true)
        meetingIDs = nil
        screenIDs = nil
        if let sourcesBeforeEvidence { sources = sourcesBeforeEvidence }
        sourcesBeforeEvidence = nil
    }

    mutating func beginPinning() {
        guard scopeBeforePins == nil else { return }
        scopeBeforePins = PinScope(screenIDs: screenIDs, screenWasEnabled: sources.contains(.screen))
    }

    mutating func reconcilePins(dateScope: AskDateScope? = nil) {
        if let dateScope { pins = pins.filter { dateScope.contains($0.timestamp) } }
        guard !pins.isEmpty else {
            clearPins(restoringScope: true)
            return
        }
        sources.insert(.screen)
        screenIDs = Set(pins.map(\.snapshotID))
    }

    mutating func removePin(_ id: Int64) {
        pins.removeAll { $0.id == id }
        reconcilePins()
    }

    mutating func clearPins(restoringScope: Bool) {
        pins = []
        if restoringScope, let previous = scopeBeforePins {
            screenIDs = previous.screenIDs
            if !previous.screenWasEnabled, sources.count > 1 { sources.remove(.screen) }
        }
        scopeBeforePins = nil
    }
}

struct ScreenRecallGroup: Identifiable, Sendable {
    let id: String
    let matches: [ActivityStore.OCRHit]
    var primary: ActivityStore.OCRHit { matches[0] }
}

extension RecallSearch {
    struct Result: Sendable {
        var meetings: [MeetingRecallGroup] = []
        var screens: [ScreenRecallGroup] = []
        var files: [FileSearchHit] = []
        var agentNotes: [AgentNoteHit] = []
        var isTruncated = false
        var screenCoverage: [Int64: Double] = [:]

        mutating func setMeetings(_ groups: [MeetingRecallGroup]) {
            isTruncated = isTruncated || groups.count > displayLimit
            meetings = Array(groups.prefix(displayLimit))
        }

        mutating func setScreens(_ groups: [ScreenRecallGroup]) {
            isTruncated = isTruncated || groups.count > displayLimit
            screens = Array(groups.prefix(displayLimit))
        }

        mutating func setFiles(_ hits: [FileSearchHit]) {
            isTruncated = isTruncated || hits.count > displayLimit
            files = Array(hits.prefix(displayLimit))
        }

        mutating func setAgentNotes(_ hits: [AgentNoteHit]) {
            isTruncated = isTruncated || hits.count > displayLimit
            agentNotes = Array(hits.prefix(displayLimit))
        }
    }

    struct KeywordScreens: Sendable {
        var groups: [ScreenRecallGroup]
        var matchedAll: Bool
        var saved: Set<Int64>
    }

    static func keywordScreenGroups(in store: ActivityStore, query: String,
                                    filter: ScreenSearchFilter) -> [ScreenRecallGroup] {
        keywordScreens(in: store, query: query, filter: filter).groups
    }

    static func keywordScreens(in store: ActivityStore, query: String,
                               filter: ScreenSearchFilter) -> KeywordScreens {
        var hits = store.searchOCR(query, limit: 2_000, filter: filter, groupResults: false, deferringSnippets: true)
        let matchedAll = !hits.isEmpty
        if hits.isEmpty {
            hits = store.searchOCR(query, limit: 2_000, matchAll: false, dropStopWords: true,
                                   filter: filter, groupResults: false, deferringSnippets: true)
        }
        let found = Set(hits.map(\.snapshotID))
        let saved = store.savedMoments(limit: 2_000).filter { moment in
            !found.contains(moment.snapshotID)
                && (filter.snapshotIDs?.contains(moment.snapshotID) ?? true)
                && (filter.interval.map { moment.ts >= $0.start && moment.ts < $0.end } ?? true)
                && (filter.app.map { $0.caseInsensitiveCompare(moment.app) == .orderedSame } ?? true)
                && [moment.note, moment.windowTitle].contains { $0.localizedCaseInsensitiveContains(query) }
        }
        hits += saved.map { ActivityStore.OCRHit(snapshotID: $0.snapshotID, ts: $0.ts, app: $0.app,
                                                windowTitle: $0.windowTitle, snippet: $0.note) }
        return KeywordScreens(
            groups: readableScreenGroups(hits, query: query, limit: displayLimit + 1, fill: store.fillOCRSnippets),
            matchedAll: matchedAll, saved: Set(saved.map(\.snapshotID)))
    }

    static func readableScreenGroups(
        _ hits: [ActivityStore.OCRHit], query: String, limit: Int = displayLimit,
        fill: ([ActivityStore.OCRHit]) -> [ActivityStore.OCRHit]
    ) -> [ScreenRecallGroup] {
        guard limit > 0 else { return [] }
        let candidates = sessions(hits)
        var settled: [(first: Int, matches: [ActivityStore.OCRHit])] = []
        var next = 0
        while next < candidates.count {
            if settled.count >= limit {
                let firsts = settled.map(\.first).sorted()
                if firsts[limit - 1] < candidates[next][0] { break }
            }
            let batch = candidates[next..<min(candidates.count, next + max(1, limit - settled.count))]
            next += batch.count
            var filled = fill(batch.flatMap { $0 }.map { hits[$0] }).makeIterator()
            for session in batch {
                var readableOffsets: [Int] = []
                var readable: [ActivityStore.OCRHit] = []
                for offset in session {
                    guard let hit = filled.next(),
                          let kept = readableScreens([hit], query: query).first else { continue }
                    readableOffsets.append(offset)
                    readable.append(kept)
                }
                for group in sessions(readable) {
                    settled.append((readableOffsets[group[0]], group.map { readable[$0] }))
                }
            }
        }
        return settled.sorted { $0.first < $1.first }.prefix(limit).map { group in
            ScreenRecallGroup(id: "screen-\(group.matches[0].snapshotID)", matches: group.matches)
        }
    }

    static func readableScreens(_ hits: [ActivityStore.OCRHit], query: String) -> [ActivityStore.OCRHit] {
        hits.compactMap { hit in
            guard let excerpt = RecallPassage.excerpt(hit.snippet, query: query)
                ?? RecallPassage.excerpt(hit.windowTitle, query: query) else { return nil }
            var result = hit
            result.snippet = excerpt
            return result
        }
    }

    static func screenGroups(_ hits: [ActivityStore.OCRHit], limit: Int = displayLimit) -> [ScreenRecallGroup] {
        guard limit > 0 else { return [] }
        return sessions(hits).prefix(limit).map { group in
            ScreenRecallGroup(id: "screen-\(hits[group[0]].snapshotID)", matches: group.map { hits[$0] })
        }
    }

    private static func sessions(_ hits: [ActivityStore.OCRHit]) -> [[Int]] {
        struct Source: Hashable { let app: String; let window: String; let day: Date }
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: hits.indices) { index in
            Source(app: hits[index].app, window: hits[index].windowTitle,
                   day: calendar.startOfDay(for: hits[index].ts))
        }
        var rankedGroups: [[Int]] = []
        for bucket in buckets.values {
            let chronological = bucket.sorted { hits[$0].ts == hits[$1].ts ? $0 < $1 : hits[$0].ts < hits[$1].ts }
            var current: [Int] = []
            for index in chronological {
                if let previous = current.last, hits[index].ts.timeIntervalSince(hits[previous].ts) > 300 {
                    rankedGroups.append(current.sorted())
                    current = []
                }
                current.append(index)
            }
            if !current.isEmpty { rankedGroups.append(current.sorted()) }
        }
        return rankedGroups.sorted { $0[0] < $1[0] }
    }

    @MainActor
    static func search(_ query: String, state: RecallWorkspaceState, dateScope: AskDateScope?, app: AppState,
                       onLexical: ((Result) -> Void)? = nil) async -> Result {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Result() }
        var meetingIDs = state.meetingIDs
        if let dateScope {
            let dayIDs = Set(app.meetings.filter { dateScope.contains($0.startedAt) }.map(\.id))
            meetingIDs = meetingIDs.map { $0.intersection(dayIDs) } ?? dayIDs
        }
        let scopedMeetingIDs = meetingIDs
        let interval = dateScope?.interval()
        var filter = ScreenSearchFilter(interval: interval, app: state.screenApp)
        filter.snapshotIDs = state.screenIDs
        let screenFilter = filter
        let url = app.activityStore.databaseURL
        let facet = state.facet
        let searchMeetings = state.sources.contains(.meetings) && facet != .screen && facet != .files
            && facet != .agentNotes
        let searchNotes = state.sources.contains(.agentNotes) && (facet == .all || facet == .agentNotes)
            && app.settings.codingAgentNotesEnabled
        let notesIndex = app.agentNotesIndex
        let searchScreens = state.sources.contains(.screen) && (facet == .all || facet == .screen)
        let searchFiles = state.sources.contains(.files) && (facet == .all || facet == .files)
            && app.settings.fileSearchEnabled && app.fileSearch.isAvailable
        let fileWords = searchFiles
            ? await app.fileSearch.search(query, queryVector: nil, interval: interval, limit: displayLimit + 1)
            : []
        var result = await ActivityStore.readInBackground(at: url) { store in
            var result = Result()
            if searchMeetings {
                let hits = SearchIndex(databaseURL: url, readOnly: true)
                    .search(query, kind: facet.kind, limit: 2_000, meetingIDs: scopedMeetingIDs)
                result.setMeetings(groups(readable(hits, query: query), limit: displayLimit + 1))
            }
            if searchNotes {
                let found = (try? notesIndex.search(query, limit: interval == nil ? displayLimit + 1 : 400)) ?? []
                result.setAgentNotes(found.filter { hit in interval.map { $0.contains(hit.modified) } ?? true })
            }
            guard !Task.isCancelled, searchScreens else { return result }
            let keyword = keywordScreens(in: store, query: query, filter: screenFilter)
            var coverage = ScreenSearch.coverage(query: query, hits: keyword.groups.flatMap(\.matches),
                                                 matchedAll: keyword.matchedAll) {
                store.ocrText(snapshotID: $0)
            }
            for id in keyword.saved { coverage[id] = 1 }
            result.screenCoverage = coverage
            result.setScreens(keyword.groups)
            return result
        }
        guard !Task.isCancelled else { return Result() }
        result.setFiles(fileWords)
        onLexical?(result)
        if searchFiles, app.settings.semanticSearchEnabled,
           let vector = await app.embeddingIndex.queryVector(query) {
            guard !Task.isCancelled else { return Result() }
            result.setFiles(await app.fileSearch.search(query, queryVector: vector, interval: interval,
                                                        limit: displayLimit + 1))
        }
        guard !Task.isCancelled else { return Result() }
        guard app.settings.semanticSearchEnabled else { return result }
        if searchMeetings, state.facet == .all, app.embeddingIndex.hasEmbeddings {
            let semantic = await app.embeddingIndex.search(query, limit: 200, meetingIDs: meetingIDs,
                                                           priority: .interactive)
            guard !Task.isCancelled else { return Result() }
            let passages = await ActivityStore.readInBackground(at: url) { _ in
                let index = SearchIndex(databaseURL: url, readOnly: true)
                return semantic.compactMap {
                    index.semanticPassage(meetingID: $0.meetingID, start: $0.start, text: $0.text, query: query)
                }
            }
            guard !Task.isCancelled else { return Result() }
            result.setMeetings(fusedMeetings(keyword: result.meetings.flatMap(\.matches), semantic: passages,
                                             limit: displayLimit + 1))
        }
        if searchScreens {
            let meanings = await app.embeddingIndex.screenMeanings(query, filter: filter, priority: .interactive)
            guard !Task.isCancelled else { return Result() }
            if !meanings.isEmpty {
                let keyword = result.screens.flatMap(\.matches)
                let coverage = result.screenCoverage
                let groups = await ActivityStore.readInBackground(at: url) { store in
                    let embeddings = SQLiteDatabase(url: url, readOnly: true)
                    let ranked = ScreenSearch.ranked(
                        query: query, keyword: keyword, coverage: coverage, meanings: meanings,
                        limit: 2_000, screenshots: { store.screenshots(ids: $0) },
                        texts: { ids in embeddings.map { EmbeddingIndex.screenTexts(ids, in: $0) } ?? [:] })
                    return screenGroups(ranked, limit: displayLimit + 1)
                }
                guard !Task.isCancelled else { return Result() }
                result.setScreens(groups)
            }
        }
        return result
    }
}
