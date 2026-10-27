import Foundation

/// Reads current local sources off the UI thread. No private facts are cached
/// or copied into a new store. FTS is only a candidate finder: prompts use the
/// current files, so an old index row cannot resurrect edited/deleted text.
enum CotypingMemoryContextProvider {
    struct FileStamp: Equatable, Sendable {
        var modified: Date?
        var size: UInt64?
        var inode: UInt64?

        init(_ url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes?[.modificationDate] as? Date
            size = attributes?[.size] as? UInt64
            inode = attributes?[.systemFileNumber] as? UInt64
        }
    }

    struct Snapshot: Sendable {
        var selection = CotypingMemoryContext.Selection()
        var policy = CotypingMemoryContext.Policy(meetings: false, screenDerived: false)
        var stamps: [URL: FileStamp] = [:]
        var root: URL?

        static let empty = Snapshot()

        func isCurrent(settings: AppSettings) -> Bool {
            guard !selection.items.isEmpty else { return true }
            guard policy == CotypingMemoryContext.Policy(settings: settings),
                  stamps.allSatisfy({ FileStamp($0.key) == $0.value }) else { return false }
            return root.map { DreamStore(root: $0).autocompleteEvidenceIsAvailable } ?? true
        }
    }

    static func load(root: URL, meetings: [Meeting], field: CotypingField,
                     settings: AppSettings, now: Date = Date(), allowBodyMatch: Bool = true) -> Snapshot {
        let policy = CotypingMemoryContext.Policy(settings: settings)
        let query = CotypingMemoryContext.query(for: field, includeTitle: settings.cotypingUseAppContext)
        // Writing that names nothing distinctive cannot match a saved topic, so
        // it is answered without opening the library.
        guard policy.enabled, !query.all.isEmpty, !Task.isCancelled else { return .empty }
        let store = DreamStore(root: root)
        guard store.autocompleteEvidenceIsAvailable else { return .empty }
        var stamps: [URL: FileStamp] = [:]
        for path in ["memory/evidence-revisions.json", "memory/memory.json", ".dream-revocation-pending.json"] {
            let url = root.appendingPathComponent(path)
            stamps[url] = FileStamp(url)
        }
        // Saved work memory is read under the writing grants alone; scheduling
        // new overnight reviews is a separate setting.
        var items: [CotypingMemoryContext.Item] = []
        if let memory = try? store.loadMemory() {
            items += memoryItems(memory)
        }
        if policy.meetings {
            items += meetingItems(root: root, meetings: meetings, query: query, now: now,
                                  allowBodyMatch: allowBodyMatch, stamps: &stamps)
        }
        let snapshot = Snapshot(selection: CotypingMemoryContext.select(
            items: items, query: query, policy: policy, now: now, allowBodyMatch: allowBodyMatch),
            policy: policy, stamps: stamps, root: root)
        return !Task.isCancelled && snapshot.isCurrent(settings: settings) ? snapshot : .empty
    }

    static func memoryItems(_ memory: DreamMemory) -> [CotypingMemoryContext.Item] {
        func item(id: String, title: String, text: String, day: String,
                  provenance: DreamEvidenceProvenance?) -> CotypingMemoryContext.Item? {
            guard let provenance, !provenance.includesUnattributedContext, !provenance.sources.isEmpty,
                  let updated = DreamDay.date(fromKey: day) else { return nil }
            // A digest can mix meetings with activity/coding-agent history.
            let meetings = provenance.sources.contains { $0.kind == .meeting || $0.kind == .digest }
            let screens = provenance.sources.contains { $0.kind == .screenDay || $0.kind == .digest }
            return .init(id: id, title: title, text: text, updatedAt: updated,
                         requiresMeetings: meetings, requiresScreenMemory: screens, isWorkMemory: true)
        }
        let projects = memory.activeProjects.compactMap {
            item(id: "project:\($0.name)", title: $0.name, text: "\($0.name): \($0.status)",
                 day: $0.lastActiveDay, provenance: $0.provenance)
        }
        let goals = memory.workGoals.compactMap {
            item(id: "goal:\($0.text)", title: $0.text, text: "\($0.text) (\($0.horizon))",
                 day: $0.lastReinforcedDay, provenance: $0.provenance)
        }
        return projects + goals
    }

    /// A finished meeting recent enough to supply a fact.
    static func isEligible(_ meeting: Meeting, now: Date) -> Bool {
        meeting.isOwnWork && meeting.endedAt != nil
            && now.timeIntervalSince(meeting.startedAt) <= CotypingMemoryContext.maxAge
    }

    private static func meetingItems(root: URL, meetings: [Meeting], query: CotypingMemoryContext.Query, now: Date,
                                     allowBodyMatch: Bool,
                                     stamps: inout [URL: FileStamp]) -> [CotypingMemoryContext.Item] {
        let eligible = meetings.filter { isEligible($0, now: now) }.sorted { $0.startedAt > $1.startedAt }
        let databaseURL = root.appendingPathComponent("lokalbotv3.sqlite")
        // Only distinctive words reach the index: everyday wording matches
        // nearly every transcript and would crowd out the meeting that is named.
        let hits = !query.search.isEmpty && FileManager.default.fileExists(atPath: databaseURL.path)
            ? SearchIndex(databaseURL: databaseURL, readOnly: true).search(
                query.search.joined(separator: " "), limit: 12, matchAll: false, dropStopWords: true,
                meetingIDs: Set(eligible.map(\.id))) : []
        let hitIDs = Set(hits.map(\.meetingID))
        let candidates = eligible.filter {
            hitIDs.contains($0.id) || CotypingMemoryContext.names(title: $0.title, query: query) != nil
        }.prefix(4)
        var items: [CotypingMemoryContext.Item] = []
        for meeting in candidates {
            guard !Task.isCancelled else { return [] }
            let folder = root.appendingPathComponent(meeting.relativePath).standardizedFileURL.resolvingSymlinksInPath()
            guard folder.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/meetings/") else { continue }
            let paths = ["meta.json", "summary.md", MeetingNotes.fileName, MeetingOutcomes.fileName,
                         MeetingOutcomeState.fileName, "transcript.json", FollowUpDraft.fileName]
            guard paths.allSatisfy({
                folder.appendingPathComponent($0).resolvingSymlinksInPath().path.hasPrefix(folder.path + "/")
            }) else { continue }
            for path in paths {
                let url = folder.appendingPathComponent(path)
                stamps[url] = FileStamp(url)
            }
            guard let data = boundedData(folder.appendingPathComponent("meta.json")),
                  let current = try? metadataDecoder.decode(Meeting.self, from: data),
                  current.id == meeting.id, current.relativePath == meeting.relativePath,
                  current.isOwnWork else { continue }
            var texts: [(String, Date)] = []
            for path in [MeetingNotes.fileName, "summary.md"] {
                if let data = boundedData(folder.appendingPathComponent(path)),
                   let text = String(data: data, encoding: .utf8) {
                    texts.append((text, stamps[folder.appendingPathComponent(path)]?.modified ?? current.startedAt))
                }
            }
            // Projection applies saved corrections and omits archived outcomes.
            let outcomeDate = [MeetingOutcomes.fileName, MeetingOutcomeState.fileName]
                .compactMap { stamps[folder.appendingPathComponent($0)]?.modified }.max() ?? current.startedAt
            // The shared projection also checks the transcript revision and
            // loads a follow-up draft. Bound and watch those dependencies too.
            let outcomesAreBounded = [MeetingOutcomes.fileName, MeetingOutcomeState.fileName, FollowUpDraft.fileName].allSatisfy {
                (stamps[folder.appendingPathComponent($0)]?.size ?? 0) <= 32_768
            } && (stamps[folder.appendingPathComponent("transcript.json")]?.size ?? 0) <= 2_097_152
            if outcomesAreBounded {
                texts += SearchIndex.outcomeTexts(for: current, root: root).map { ($0, outcomeDate) }
            }
            for (index, source) in texts.enumerated() {
                for (line, excerpt) in source.0.split(whereSeparator: \.isNewline).enumerated() {
                    let value = String(excerpt)
                    guard CotypingMemoryContext.relevance(text: value, title: current.title, query: query,
                                                          allowBodyMatch: allowBodyMatch) != nil else { continue }
                    items.append(.init(id: "\(current.id):\(index):\(line)", title: current.title,
                                       text: value, updatedAt: source.1, requiresMeetings: true))
                }
            }
        }
        return items
    }

    private static var metadataDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func boundedData(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 32_768)
    }
}
