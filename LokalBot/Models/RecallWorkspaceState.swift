import Foundation

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
    /// Files has no per-row bound yet either, so a selected Files source stays
    /// when file rows were among the results.
    mutating func selectResultEvidence(meetingIDs: Set<UUID>, screenIDs: Set<Int64>, hadFiles: Bool = false) {
        let keepsActivity = sources.contains(.today)
        let keepsFiles = hadFiles && sources.contains(.files)
        selectEvidence(meetingIDs: meetingIDs, screenIDs: screenIDs)
        if keepsActivity { sources.insert(.today) }
        if keepsFiles { sources.insert(.files) }
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
        var files: [FileSearchHit] = []
        /// More meetings, screen sources or files matched than are listed.
        var isTruncated = false
        /// The share of the query's words each keyword screen hit holds, for
        /// ranking it with meaning matches (`ScreenSearch`).
        var screenCoverage: [Int64: Double] = [:]

        /// Pass one group more than `displayLimit` so a cut list is detected.
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
        let searchScreens = state.sources.contains(.screen) && (facet == .all || facet == .screen)
        let searchFiles = state.sources.contains(.files) && (facet == .all || facet == .files)
            && app.settings.fileSearchEnabled && app.fileSearch.isAvailable
        // Files match words first; the query vector (shared with meeting and
        // screen search) adds meaning below.
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
            guard !Task.isCancelled, searchScreens else { return result }
            var hits = store.searchOCR(query, limit: 2_000, filter: screenFilter, groupResults: false)
            let matchedAll = !hits.isEmpty
            if hits.isEmpty {
                hits = store.searchOCR(query, limit: 2_000, matchAll: false, dropStopWords: true,
                                       filter: screenFilter, groupResults: false)
            }
            var coverage = ScreenSearch.coverage(query: query, hits: hits, matchedAll: matchedAll) {
                store.ocrText(snapshotID: $0)
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
            for moment in saved { coverage[moment.snapshotID] = 1 }
            result.screenCoverage = coverage
            result.setScreens(screenGroups(readableScreens(hits, query: query), limit: displayLimit + 1))
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
            // Text and picture vectors on one scale, ranked with the keyword
            // hits (`ScreenSearch`). With no vectors yet the keyword results stay.
            let meanings = await app.embeddingIndex.screenMeanings(query, filter: filter, priority: .interactive)
            guard !Task.isCancelled else { return Result() }
            if !meanings.isEmpty {
                let ranked = ScreenSearch.ranked(
                    query: query, keyword: result.screens.flatMap(\.matches), coverage: result.screenCoverage,
                    meanings: meanings, limit: 2_000, screenshot: { app.activityStore.screenshot(id: $0) })
                result.setScreens(screenGroups(ranked, limit: displayLimit + 1))
            }
        }
        return result
    }
}
