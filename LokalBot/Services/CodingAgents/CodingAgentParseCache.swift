import Foundation

protocol CodingAgentFileSummary: Sendable {
    mutating func consume(_ lines: CodingAgentJSONLines, retainingFrom start: Date)
    mutating func trim(before start: Date)
}

struct CodingAgentStoredEvent: CodingAgentTimedEvent, Sendable {
    var at: Date
    var kind: CodingAgentEvent.Kind
    var record: Int32
}

struct CodingAgentFileState<Summary: CodingAgentFileSummary>: Sendable {
    var created: Date
    var modified: Date
    var size: Int
    var offset: Int
    var boundary: Int
    var retainedFrom: Date
    var timeZone: TimeZone
    var summary: Summary
}

final class CodingAgentParseCache: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: any Sendable] = [:]

    func state<Summary>(for path: String) -> CodingAgentFileState<Summary>? {
        lock.withLock { states[path] as? CodingAgentFileState<Summary> }
    }

    func store<Summary>(_ state: CodingAgentFileState<Summary>, for path: String) {
        lock.withLock { states[path] = state }
    }

    func prune(keeping paths: Set<String>, under root: URL) {
        let prefix = root.path + "/"
        lock.withLock {
            states = states.filter { !$0.key.hasPrefix(prefix) || paths.contains($0.key) }
        }
    }

    static func recordKey(_ id: String) -> Int {
        var hasher = Hasher()
        hasher.combine(id)
        return hasher.finalize()
    }

    static func summary<Summary: CodingAgentFileSummary>(
        of file: CodingAgentCandidateFile,
        from start: Date,
        cache: CodingAgentParseCache?,
        empty: () -> Summary
    ) throws -> (summary: Summary, bytesRead: Int?) {
        if CodingAgentCompressedTranscript.isCompressed(file.url) {
            return try compressedSummary(of: file, from: start, cache: cache, empty: empty)
        }
        let path = file.url.path
        var state: CodingAgentFileState<Summary>? = cache?.state(for: path)
        if let cached = state,
           cached.retainedFrom > start || cached.created != file.created || cached.timeZone != .current {
            state = nil
        }
        if var cached = state, cached.size == file.size, cached.modified == file.modified,
           cached.offset == cached.size {
            if cached.retainedFrom < start {
                cached.summary.trim(before: start)
                cached.retainedFrom = start
                cache?.store(cached, for: path)
            }
            return (cached.summary, nil)
        }

        let data = try Data(contentsOf: file.url, options: .alwaysMapped)
        if let cached = state,
           cached.offset > data.count || boundaryHash(data, at: cached.offset) != cached.boundary {
            state = nil
        }
        var current = state ?? CodingAgentFileState(
            created: file.created, modified: file.modified, size: 0, offset: 0,
            boundary: boundaryHash(data, at: 0), retainedFrom: start, timeZone: .current, summary: empty())
        if current.retainedFrom < start {
            current.summary.trim(before: start)
            current.retainedFrom = start
        }
        let resumeAt = current.offset
        let lastNewline = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        let complete = max(resumeAt, lastNewline)
        if complete > resumeAt {
            current.summary.consume(
                CodingAgentJSONLines(data: data[offset(resumeAt, in: data)..<offset(complete, in: data)]),
                retainingFrom: current.retainedFrom)
        }
        current.created = file.created
        current.modified = file.modified
        current.size = data.count
        current.offset = complete
        current.boundary = boundaryHash(data, at: complete)
        cache?.store(current, for: path)

        var summary = current.summary
        if complete < data.count {
            summary.consume(
                CodingAgentJSONLines(data: data[offset(complete, in: data)...]),
                retainingFrom: current.retainedFrom)
        }
        return (summary, data.count - resumeAt)
    }

    private static func compressedSummary<Summary: CodingAgentFileSummary>(
        of file: CodingAgentCandidateFile,
        from start: Date,
        cache: CodingAgentParseCache?,
        empty: () -> Summary
    ) throws -> (summary: Summary, bytesRead: Int?) {
        let path = file.url.path
        if var cached: CodingAgentFileState<Summary> = cache?.state(for: path),
           cached.retainedFrom <= start, cached.created == file.created, cached.timeZone == .current,
           cached.size == file.size, cached.modified == file.modified {
            if cached.retainedFrom < start {
                cached.summary.trim(before: start)
                cached.retainedFrom = start
                cache?.store(cached, for: path)
            }
            return (cached.summary, nil)
        }
        var summary = empty()
        let bytes = try CodingAgentCompressedTranscript.forEachBatch(of: file.url) {
            summary.consume($0, retainingFrom: start)
        }
        cache?.store(
            CodingAgentFileState(
                created: file.created, modified: file.modified, size: file.size, offset: file.size,
                boundary: 0, retainedFrom: start, timeZone: .current, summary: summary),
            for: path)
        return (summary, bytes)
    }

    private static func offset(_ distance: Int, in data: Data) -> Data.Index {
        data.index(data.startIndex, offsetBy: distance)
    }

    private static func boundaryHash(_ data: Data, at distance: Int) -> Int {
        let end = offset(distance, in: data)
        let start = data.index(end, offsetBy: -min(64, distance))
        var hasher = Hasher()
        data[start..<end].withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }
}
