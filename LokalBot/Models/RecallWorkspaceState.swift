import Foundation

/// Shared, session-lived navigation state. Opening evidence does not discard
/// the selected filters, attachments, result or unfinished question.
struct RecallWorkspaceState {
    var meetingIDs: Set<UUID>?
    var screenIDs: Set<Int64>?
    var selectedResult = 0
    var facet: AskFacet = .all
    var meaning = false
    var screenDate: ScreenSearchDateScope = .any
    var screenApp: String?
    var sources = AskSourceScope.defaults
    var pins: [ScreenAskContext] = []
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
        var result = await ActivityStore.readInBackground(at: url) { store in
            var result = Result()
            if facet != .screen {
                result.meetings = groups(SearchIndex(databaseURL: url, readOnly: true)
                    .search(query, kind: facet.kind, limit: 2_000, meetingIDs: scopedMeetingIDs))
            }
            guard !Task.isCancelled, facet == .all || facet == .screen else { return result }
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
            result.screens = screenGroups(hits)
            return result
        }
        guard !Task.isCancelled else { return Result() }
        onLexical?(result)
        guard state.meaning else { return result }
        if state.facet == .all, app.embeddingIndex.hasEmbeddings {
            let semantic = await app.embeddingIndex.search(query, limit: 200, meetingIDs: meetingIDs)
            guard !Task.isCancelled else { return Result() }
            result.meetings = groups(result.meetings.flatMap(\.matches) + semantic.map {
                SearchIndex.Hit(meetingID: $0.meetingID, kind: .segment, start: $0.start,
                                snippet: $0.text, speaker: "Meaning match")
            })
        }
        if state.facet == .all || state.facet == .screen {
            let semantic = await app.embeddingIndex.searchScreen(query, filter: filter, limit: 200)
            guard !Task.isCancelled else { return Result() }
            let hits = result.screens.flatMap(\.matches)
            let existing = Set(hits.map(\.snapshotID))
            result.screens = screenGroups(hits + semantic.filter { !existing.contains($0.snapshotID) }.compactMap { hit in
                guard let shot = app.activityStore.screenshot(id: hit.snapshotID) else { return nil }
                return ActivityStore.OCRHit(snapshotID: hit.snapshotID, ts: shot.ts, app: shot.app,
                                            windowTitle: shot.windowTitle, snippet: hit.text)
            })
        }
        return result
    }
}
