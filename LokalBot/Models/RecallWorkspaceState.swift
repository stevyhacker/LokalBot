import Foundation

/// Shared, session-lived navigation state. Opening evidence does not discard
/// the selected filters, attachments, result or unfinished question.
struct RecallWorkspaceState {
    var meetingIDs: Set<UUID>?
    var screenIDs: Set<Int64>?
    var selectedResult = 0
    var facet: AskFacet = .all
    var screenDate: ScreenSearchDateScope = .any
    var screenApp: String?
    var sources = AskSourceScope.defaults
    var pins: [ScreenAskContext] = []
    private(set) var sourcesBeforeEvidence: Set<AskSourceScope>?

    mutating func selectEvidence(meetingIDs: Set<UUID>?, screenIDs: Set<Int64>?,
                                 sources selectedSources: Set<AskSourceScope>? = nil) {
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

    /// An explicit source choice supersedes any earlier temporary narrowing.
    mutating func chooseSources(_ selection: Set<AskSourceScope>) {
        sources = selection
        sourcesBeforeEvidence = nil
    }

    mutating func clearEvidence() {
        meetingIDs = nil
        screenIDs = nil
        if let sourcesBeforeEvidence { sources = sourcesBeforeEvidence }
        sourcesBeforeEvidence = nil
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

    /// Group adjacent moments per source/day, then restore relevance order.
    /// Each timestamp is classified once; long sessions avoid quadratic scans.
    static func screenGroups(_ hits: [ActivityStore.OCRHit], limit: Int = 40) -> [ScreenRecallGroup] {
        guard limit > 0 else { return [] }
        struct Source: Hashable { let app: String; let window: String; let day: Date }
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: hits.enumerated()) { indexed in
            Source(app: indexed.element.app, window: indexed.element.windowTitle,
                   day: calendar.startOfDay(for: indexed.element.ts))
        }
        var rankedGroups: [[EnumeratedSequence<[ActivityStore.OCRHit]>.Element]] = []
        for bucket in buckets.values {
            let chronological = bucket.sorted {
                $0.element.ts == $1.element.ts ? $0.offset < $1.offset : $0.element.ts < $1.element.ts
            }
            var current: [EnumeratedSequence<[ActivityStore.OCRHit]>.Element] = []
            for indexed in chronological {
                if let previous = current.last, indexed.element.ts.timeIntervalSince(previous.element.ts) > 300 {
                    rankedGroups.append(current.sorted { $0.offset < $1.offset })
                    current = []
                }
                current.append(indexed)
            }
            if !current.isEmpty { rankedGroups.append(current.sorted { $0.offset < $1.offset }) }
        }
        return rankedGroups.sorted { $0[0].offset < $1[0].offset }.prefix(limit).map { group in
            ScreenRecallGroup(id: "screen-\(group[0].element.snapshotID)", matches: group.map(\.element))
        }
    }

    @MainActor
    static func search(_ query: String, state: RecallWorkspaceState, day: Date?, app: AppState,
                       onLexical: ((Result) -> Void)? = nil) async -> Result {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Result() }
        var meetingIDs = state.meetingIDs
        if let day {
            let dayIDs = Set(app.meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }.map(\.id))
            meetingIDs = meetingIDs.map { $0.intersection(dayIDs) } ?? dayIDs
        }
        let scopedMeetingIDs = meetingIDs
        let interval = day.flatMap { Calendar.current.dateInterval(of: .day, for: $0) } ?? state.screenDate.interval()
        var filter = ScreenSearchFilter(interval: interval, app: state.screenApp)
        filter.snapshotIDs = state.screenIDs
        let screenFilter = filter
        let url = app.activityStore.databaseURL
        let facet = state.facet
        let searchMeetings = state.sources.contains(.meetings) && facet != .screen
        let searchScreens = state.sources.contains(.screen) && (facet == .all || facet == .screen)
        var result = await ActivityStore.readInBackground(at: url) { store in
            var result = Result()
            if searchMeetings {
                let hits = SearchIndex(databaseURL: url, readOnly: true)
                    .search(query, kind: facet.kind, limit: 2_000, meetingIDs: scopedMeetingIDs)
                result.meetings = groups(readable(hits, query: query))
            }
            guard !Task.isCancelled, searchScreens else { return result }
            var hits = store.searchOCR(query, limit: 2_000, filter: screenFilter, groupResults: false)
            if hits.isEmpty {
                hits = store.searchOCR(query, limit: 2_000, matchAll: false, dropStopWords: true,
                                       filter: screenFilter, groupResults: false)
            }
            let found = Set(hits.map(\.snapshotID))
            let saved = store.savedMoments(limit: 2_000).filter { moment in
                !found.contains(moment.snapshotID)
                    && (screenFilter.snapshotIDs?.contains(moment.snapshotID) ?? true)
                    && (screenFilter.interval.map { moment.ts >= $0.start && moment.ts < $0.end } ?? true)
                    && (screenFilter.app.map { $0.caseInsensitiveCompare(moment.app) == .orderedSame } ?? true)
                    && [moment.note, moment.windowTitle].contains { $0.localizedCaseInsensitiveContains(query) }
            }
            hits += saved.map { ActivityStore.OCRHit(snapshotID: $0.snapshotID, ts: $0.ts, app: $0.app,
                                                    windowTitle: $0.windowTitle, snippet: $0.note) }
            result.screens = screenGroups(readableScreens(hits, query: query))
            return result
        }
        guard !Task.isCancelled else { return Result() }
        onLexical?(result)
        guard app.settings.semanticSearchEnabled else { return result }
        if searchMeetings, state.facet == .all, app.embeddingIndex.hasEmbeddings {
            let semantic = await app.embeddingIndex.search(query, limit: 200, meetingIDs: meetingIDs)
            guard !Task.isCancelled else { return Result() }
            let passages = await ActivityStore.readInBackground(at: url) { _ in
                let index = SearchIndex(databaseURL: url, readOnly: true)
                return semantic.compactMap {
                    index.semanticPassage(meetingID: $0.meetingID, start: $0.start, text: $0.text, query: query)
                }
            }
            guard !Task.isCancelled else { return Result() }
            result.meetings = fusedMeetings(keyword: result.meetings.flatMap(\.matches), semantic: passages)
        }
        if searchScreens {
            let semantic = await app.embeddingIndex.searchScreen(query, filter: filter, limit: 200)
            guard !Task.isCancelled else { return Result() }
            let hits = result.screens.flatMap(\.matches)
            let keywordByID = Dictionary(hits.map { ($0.snapshotID, $0) }, uniquingKeysWith: { first, _ in first })
            let semanticByID = Dictionary(semantic.map { ($0.snapshotID, $0) }, uniquingKeysWith: { first, _ in first })
            let ranked = ScreenSearchRanker.fuse(keyword: hits, semantic: semantic, limit: 2_000)
            result.screens = screenGroups(ranked.compactMap { match in
                if let hit = keywordByID[match.snapshotID] { return hit }
                guard let hit = semanticByID[match.snapshotID],
                      let shot = app.activityStore.screenshot(id: match.snapshotID) else { return nil }
                guard let excerpt = RecallPassage.excerpt(hit.text, query: query) else { return nil }
                var result = ActivityStore.OCRHit(snapshotID: shot.id, ts: shot.ts, app: shot.app,
                                                   windowTitle: shot.windowTitle, snippet: excerpt)
                result.isSemantic = true
                return result
            })
        }
        return result
    }
}
