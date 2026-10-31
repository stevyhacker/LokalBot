import Foundation

/// Ask's query and retrieval state for the session. Only Ask observes it:
/// AppState does not relay its changes, so a keystroke in the query field
/// re-renders Ask rather than every AppState observer.
@MainActor
final class RecallWorkspace: ObservableObject {
    @Published var query = ""
    @Published var state = RecallWorkspaceState()
}

/// Shared, session-lived navigation state. Opening evidence does not discard
/// the selected filters, attachments, result or unfinished question.
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

    /// "Ask about results" bounds meetings and screen moments to the displayed
    /// rows. Activity has no result rows to bound, so a selected Activity
    /// source stays; otherwise "How long was I in Figma today?" lost the only
    /// tool that answers it whenever the question also matched a result.
    mutating func selectResultEvidence(meetingIDs: Set<UUID>, screenIDs: Set<Int64>) {
        let keepsActivity = sources.contains(.today)
        selectEvidence(meetingIDs: meetingIDs, screenIDs: screenIDs)
        if keepsActivity { sources.insert(.today) }
    }

    /// An explicit source choice supersedes any earlier temporary narrowing.
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
        /// More meetings or screen sources matched than are listed.
        var isTruncated = false

        /// Pass one group more than `displayLimit` so a cut list is detected.
        mutating func setMeetings(_ groups: [MeetingRecallGroup]) {
            isTruncated = isTruncated || groups.count > displayLimit
            meetings = Array(groups.prefix(displayLimit))
        }

        mutating func setScreens(_ groups: [ScreenRecallGroup]) {
            isTruncated = isTruncated || groups.count > displayLimit
            screens = Array(groups.prefix(displayLimit))
        }
    }

    /// Keyword screen matches (relaxed when the strict query finds nothing)
    /// and saved moments whose note or title matches, as source sessions.
    /// One group more than `displayLimit` is returned so a cut list shows.
    static func keywordScreenGroups(in store: ActivityStore, query: String,
                                    filter: ScreenSearchFilter) -> [ScreenRecallGroup] {
        var hits = store.searchOCR(query, limit: 2_000, filter: filter, groupResults: false, deferringSnippets: true)
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
        return readableScreenGroups(hits, query: query, limit: displayLimit + 1, fill: store.fillOCRSnippets)
    }

    /// `screenGroups(readableScreens(fill(hits), query:), limit:)`, filling
    /// only the hits that can reach the first `limit` groups. Dropping an
    /// unreadable hit can only split a session, never merge two, so sessions
    /// are settled in order of their best hit until no later one can rank
    /// above the `limit`th group. Typically 5–20% of 2,000 hits get snippets.
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
            // At least as many sessions as groups are still missing, in one fill.
            let batch = candidates[next..<min(candidates.count, next + max(1, limit - settled.count))]
            next += batch.count
            // `fill` keeps order, so the filled hits follow the batch's offsets.
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

    /// Group adjacent moments per source/day, then restore relevance order.
    /// Each timestamp is classified once; long sessions avoid quadratic scans.
    static func screenGroups(_ hits: [ActivityStore.OCRHit], limit: Int = displayLimit) -> [ScreenRecallGroup] {
        guard limit > 0 else { return [] }
        return sessions(hits).prefix(limit).map { group in
            ScreenRecallGroup(id: "screen-\(hits[group[0]].snapshotID)", matches: group.map { hits[$0] })
        }
    }

    /// Hit offsets per source session (same app, window and day, no gap over
    /// five minutes), each in relevance order, sessions by their best hit.
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
        let searchMeetings = state.sources.contains(.meetings) && facet != .screen
        let searchScreens = state.sources.contains(.screen) && (facet == .all || facet == .screen)
        var result = await ActivityStore.readInBackground(at: url) { store in
            var result = Result()
            if searchMeetings {
                let hits = SearchIndex(databaseURL: url, readOnly: true)
                    .search(query, kind: facet.kind, limit: 2_000, meetingIDs: scopedMeetingIDs)
                result.setMeetings(groups(readable(hits, query: query), limit: displayLimit + 1))
            }
            guard !Task.isCancelled, searchScreens else { return result }
            result.setScreens(keywordScreenGroups(in: store, query: query, filter: screenFilter))
            return result
        }
        guard !Task.isCancelled else { return Result() }
        onLexical?(result)
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
            let semantic = await app.embeddingIndex.searchScreen(query, filter: filter, limit: 200,
                                                                 priority: .interactive)
            guard !Task.isCancelled else { return Result() }
            let hits = result.screens.flatMap(\.matches)
            let keywordByID = Dictionary(hits.map { ($0.snapshotID, $0) }, uniquingKeysWith: { first, _ in first })
            let semanticByID = Dictionary(semantic.map { ($0.snapshotID, $0) }, uniquingKeysWith: { first, _ in first })
            let ranked = ScreenSearchRanker.fuse(keyword: hits, semantic: semantic, limit: 2_000)
            result.setScreens(screenGroups(ranked.compactMap { match in
                if let hit = keywordByID[match.snapshotID] { return hit }
                guard let hit = semanticByID[match.snapshotID],
                      let shot = app.activityStore.screenshot(id: match.snapshotID) else { return nil }
                guard let excerpt = RecallPassage.excerpt(hit.text, query: query) else { return nil }
                var result = ActivityStore.OCRHit(snapshotID: shot.id, ts: shot.ts, app: shot.app,
                                                   windowTitle: shot.windowTitle, snippet: excerpt)
                result.isSemantic = true
                return result
            }, limit: displayLimit + 1))
        }
        return result
    }
}
