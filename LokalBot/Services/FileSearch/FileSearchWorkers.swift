import CoreServices
import DigUpKit
import Foundation

/// Asked by DigUp's indexer before each job; set from the main actor to end a
/// pass at the next job boundary (a recording started, Files was turned off).
final class FileIndexStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
    func clear() { lock.withLock { stopped = false } }
}

/// Owns the index while it is written: one serial queue, one connection
/// (DigUp's `Database` is single-threaded). Indexing runs here, off the main
/// thread, with a pool drained per call like DigUp's helper process.
final class FileIndexWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.file-index", qos: .utility)
    let folder: URL
    private var store: IndexStore?

    init(folder: URL) {
        self.folder = folder
    }

    func perform<T: Sendable>(_ body: @escaping @Sendable (IndexStore) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    try autoreleasepool {
                        let store = try openStore()
                        return try body(store)
                    }
                })
            }
        }
    }

    /// Closes the connection and removes the index folder.
    func deleteIndex() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                store = nil
                try? FileManager.default.removeItem(at: folder)
                continuation.resume()
            }
        }
    }

    private func openStore() throws -> IndexStore {
        if let store { return store }
        let opened = try IndexStore(directory: folder)
        store = opened
        return opened
    }
}

/// Owns the searcher: its own connection on its own serial queue, so a search
/// never waits for indexing (SQLite's WAL lets it read while the index is
/// written). Vectors load on the first search by meaning and are released
/// after a while without one.
final class FileSearchReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.file-search", qos: .userInitiated)
    private let folder: URL
    private var store: IndexStore?
    private var searcher: Searcher?
    private var stale = false
    private var lastSearch = Date.distantPast

    init(folder: URL) {
        self.folder = folder
    }

    func search(_ text: String, queryVector: [Float]?, limit: Int) async -> [SearchHit] {
        await onQueue { [self] in
            guard let searcher = openSearcher() else { return [] }
            lastSearch = Date()
            return (try? searcher.search(text, queryVector: queryVector, limit: limit)) ?? []
        } ?? []
    }

    /// The stored text of one passage (a PDF page, a document chunk, a
    /// screenshot's text); nil for a picture or a video frame.
    func passage(segment: Int64) async -> String? {
        await onQueue { [self] in try? openSearcher()?.text(ofSegment: segment) } ?? nil
    }

    func hit(segment: Int64) async -> FileSearchHit? {
        await onQueue { [self] () -> FileSearchHit? in
            guard openSearcher() != nil, let store else { return nil }
            var found: FileSearchHit?
            try? store.db.query("""
                SELECT f.path, f.kind, f.mtime, f.size, s.loc, s.excerpt
                FROM segments s JOIN files f ON f.id = s.file WHERE s.id = ?
                """, [.int(segment)]) { row in
                let kind = FileSearchHit.Kind(rawValue: row.text(1) ?? "") ?? .doc
                let loc = row.isNull(4) ? nil : row.double(4)
                found = FileSearchHit(
                    id: segment, path: row.text(0) ?? "", kind: kind,
                    page: kind == .pdf ? loc.map { Int($0) } : nil,
                    seconds: kind == .audio || kind == .video ? loc : nil,
                    excerpt: row.text(5), modified: Date(timeIntervalSince1970: row.double(2)),
                    size: row.int(3), isSemantic: false)
            }
            return found
        } ?? nil
    }

    /// New files were indexed: the next search reads them.
    func markStale() {
        queue.async { [self] in stale = true }
    }

    /// Frees the vectors (about 1.5 KB each) when nothing searched for a while.
    func releaseIfIdle(after seconds: TimeInterval) {
        queue.async { [self] in
            guard let searcher, searcher.vectorsLoaded,
                  Date().timeIntervalSince(lastSearch) > seconds else { return }
            searcher.releaseVectors()
        }
    }

    func close() async {
        _ = await onQueue { [self] in
            searcher = nil
            store = nil
            return true
        }
    }

    private func openSearcher() -> Searcher? {
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(IndexStore.mainFile).path) else {
            return nil
        }
        if let searcher, !stale { return searcher }
        do {
            if let searcher, searcher.vectorsLoaded {
                try searcher.reload()
            } else {
                let store = try store ?? IndexStore(directory: folder)
                self.store = store
                searcher = try Searcher(store: store, loadVectors: false)
            }
            stale = false
            return searcher
        } catch {
            lokalbotLog("file search: cannot open the index: \(error)")
            return nil
        }
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: autoreleasepool { body() }) }
        }
    }
}

/// FSEvents on the chosen folders. Hidden paths are ignored; everything else
/// is reported in batches and the service decides whether a pass is due.
final class FileFolderWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "me.dotenv.LokalBot.file-watch", qos: .utility)
    private let onChange: @Sendable ([String]) -> Void

    init?(folders: [String], latency: CFTimeInterval = 2, onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        let existing = folders.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let visible = array.prefix(count).filter { path in
                !path.split(separator: "/").contains { $0.hasPrefix(".") }
            }
            if !visible.isEmpty { watcher.onChange(Array(visible)) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, existing as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
