import Foundation

/// What a reader keeps of one transcript file between scans: enough to build
/// its transcript for any window that starts at or after the time it was
/// kept from. Summaries hold no window of their own, so a new day or a
/// refresh reuses them and parses only the lines agents appended since.
protocol CodingAgentFileSummary: Sendable {
    /// Folds in complete lines, keeping timed records from `start` on.
    mutating func consume(_ lines: CodingAgentJSONLines, retainingFrom start: Date)
    /// Drops timed records before `start`, which no later scan reads.
    mutating func trim(before start: Date)
}

/// An event as a file summary keeps it. Folder, branch, and record id live
/// on the record it came from, so a busy record's events share them.
struct CodingAgentStoredEvent: CodingAgentTimedEvent, Sendable {
    var at: Date
    var kind: CodingAgentEvent.Kind
    /// The source record's index in its summary, or `-1` for none.
    var record: Int32
}

/// A transcript file's summary and how far it was read. Both agents only
/// append to their transcripts; a file that shrank, was replaced, or whose
/// bytes before the resume point changed is parsed again from the start.
struct CodingAgentFileState<Summary: CodingAgentFileSummary>: Sendable {
    var created: Date
    var modified: Date
    var size: Int
    /// Bytes folded into `summary`: every complete line. A line still being
    /// written is read again once its newline arrives.
    var offset: Int
    /// Hash of the bytes just before `offset`.
    var boundary: Int
    /// Records from before this time were not kept, so a scan reaching
    /// further back parses the file again.
    var retainedFrom: Date
    /// Activity is compacted by local day, so a time zone change reparses.
    var timeZone: TimeZone
    var summary: Summary
}

/// Per-file parse state from earlier scans, keyed by path. Each scan clips a
/// file's summary to its own window, so a window that moves to a new day
/// reuses every file, and a refresh parses only the bytes appended since.
final class CodingAgentParseCache: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: any Sendable] = [:]

    func state<Summary>(for path: String) -> CodingAgentFileState<Summary>? {
        lock.withLock { states[path] as? CodingAgentFileState<Summary> }
    }

    func store<Summary>(_ state: CodingAgentFileState<Summary>, for path: String) {
        lock.withLock { states[path] = state }
    }

    /// Forget files under `root` that a scan no longer selected.
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

    /// `file`'s summary for a scan whose window starts at `start`: the cached
    /// one while the file is unchanged, extended by the lines appended since
    /// otherwise. Without a cache the whole file is parsed. `bytesRead` is
    /// `nil` when the file was not opened.
    static func summary<Summary: CodingAgentFileSummary>(
        of file: CodingAgentCandidateFile,
        from start: Date,
        cache: CodingAgentParseCache?,
        empty: () -> Summary
    ) throws -> (summary: Summary, bytesRead: Int?) {
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
            // The last line has no newline yet: read it for this scan only.
            summary.consume(
                CodingAgentJSONLines(data: data[offset(complete, in: data)...]),
                retainingFrom: current.retainedFrom)
        }
        return (summary, data.count - resumeAt)
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
