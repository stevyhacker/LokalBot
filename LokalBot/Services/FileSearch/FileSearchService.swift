import DigUpKit
import Foundation

/// A file that matched a search: what Ask, Quick Recall and the agent show.
struct FileSearchHit: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case screenshot, image, pdf, doc, audio, video, code
    }

    /// The matching passage's id in the file index; `[file:<id>]` cites it.
    let id: Int64
    let path: String
    let kind: Kind
    /// A PDF page, from 1.
    let page: Int?
    /// Seconds into a recording or video.
    let seconds: Double?
    /// The matched words in «», or the passage's start.
    let excerpt: String?
    let modified: Date
    /// When a photo was taken (EXIF), if it says.
    let taken: Date?
    let size: Int64
    /// Found by what it means or shows, without the query's words.
    let isSemantic: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    /// The date Ask's time scope filters on.
    var date: Date { taken ?? modified }

    var kindLabel: String {
        switch kind {
        case .screenshot: "Screenshot"
        case .image: "Picture"
        case .pdf: page.map { "PDF · page \($0)" } ?? "PDF"
        case .doc: "Document"
        case .audio: "Recording"
        case .video: "Video"
        case .code: "Code"
        }
    }

    var icon: String {
        switch kind {
        case .screenshot: "camera.viewfinder"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .doc: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    init(id: Int64, path: String, kind: Kind, page: Int? = nil, seconds: Double? = nil, excerpt: String?,
         modified: Date, taken: Date? = nil, size: Int64 = 0, isSemantic: Bool) {
        self.id = id
        self.path = path
        self.kind = kind
        self.page = page
        self.seconds = seconds
        self.excerpt = excerpt
        self.modified = modified
        self.taken = taken
        self.size = size
        self.isSemantic = isSemantic
    }

    init(_ hit: SearchHit) {
        let kind = Kind(rawValue: hit.kind.rawValue) ?? .doc
        self.init(
            id: hit.segmentID, path: hit.path, kind: kind,
            page: kind == .pdf ? hit.loc.map { Int($0) } : nil,
            seconds: kind == .audio || kind == .video ? hit.loc : nil,
            excerpt: hit.excerpt, modified: Date(timeIntervalSince1970: hit.modified),
            taken: hit.info["taken"].flatMap(Self.exifDate), size: hit.size,
            isSemantic: hit.keywordRank == nil)
    }

    /// EXIF `DateTimeOriginal`: "2026:05:14 18:02:11", in the camera's local time.
    static func exifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

/// Files: the folders a person chooses, searched by what is in them. DigUp's
/// engine (DigUpKit, MIT) crawls and reads them and keeps the index; vectors
/// come from the media embedder (`FileMediaEmbedderRuntime`), and searches
/// embed their words on the text embedder search by meaning already runs.
///
/// Indexing happens in passes: at launch, after the folders change, and a few
/// seconds after something in them changes. A pass reads only new and changed
/// files, stops at the next file when a meeting starts recording, in Low Power
/// Mode, or when the Mac is hot, and starts again when that ends. The image
/// and audio model loads only while a pass has files to read.
@MainActor
final class FileSearchService: ObservableObject {
    enum PauseReason: Equatable, Sendable {
        case recording, lowPower, warm
    }

    enum State: Equatable, Sendable {
        case off
        case noFolders
        case downloading(Double?)
        case indexing(done: Int, total: Int)
        case finishingLongFiles(left: Int)
        case paused(PauseReason)
        case ready
        case failed(String)
    }

    struct Totals: Equatable, Sendable {
        var searchable = 0
        var pending = 0
        var failed = 0
        var skipped = 0
        var byKind: [String: Int] = [:]
        var indexBytes: Int64 = 0
    }

    /// What the last pass did, for Settings: how much it read and how long the
    /// model worked.
    struct PassReport: Equatable, Sendable {
        var finished: Date
        var filesRead: Int
        var modelSeconds: Double
        var wallSeconds: Double
    }

    struct Configuration: Equatable, Sendable {
        var enabled = false
        var folders: [String] = []
    }

    /// One pass's embedder: what its vectors are called (the index's
    /// fingerprint), how to make it on the indexing thread, and how to let the
    /// model go afterwards.
    struct EmbedderSession: Sendable {
        let source: String
        let makeEmbedder: @Sendable () throws -> any Embedder
        let end: @Sendable () async -> Void
    }

    typealias StartEmbedder = @MainActor (_ progress: @escaping @Sendable (Double) -> Void) async throws
        -> EmbedderSession

    /// Recordings and video stay out until moments can be opened in place
    /// (DigUp reads them in 30-second windows and frames every few seconds).
    /// Code stays out because `IndexOptions.includeCode` is off.
    nonisolated static let excludedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga", "opus",
        "wma", "amr", "mka", "ape", "ac3", "eac3", "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "wmv", "flv",
        "mpg", "mpeg", "m2v", "mts", "m2ts", "3gp", "3g2", "ogv", "mxf", "dv", "vob",
    ]
    nonisolated static let indexFolderName = "files-index.noindex"
    /// How long changes in the folders settle before a pass reads them.
    static let changeDelay: Duration = .seconds(5)
    static let vectorIdleSeconds: TimeInterval = 600

    @Published private(set) var state: State = .off
    @Published private(set) var totals = Totals()
    @Published private(set) var lastPass: PassReport?

    private(set) var configuration = Configuration()
    var isRecording: () -> Bool = { false }

    private let worker: FileIndexWorker
    private let reader: FileSearchReader
    private let startEmbedder: StartEmbedder
    private let stopFlag = FileIndexStopFlag()
    private var passTask: Task<Void, Never>?
    private var passWanted = false
    private var changeTask: Task<Void, Never>?
    private var watcher: FileFolderWatcher?
    private var observers: [NSObjectProtocol] = []
    private var releaseTimer: Timer?

    init(indexFolder: URL, startEmbedder: @escaping StartEmbedder) {
        worker = FileIndexWorker(folder: indexFolder)
        reader = FileSearchReader(folder: indexFolder)
        self.startEmbedder = startEmbedder
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.conditionsDidChange() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    static func live(storage: StorageManager) -> FileSearchService {
        FileSearchService(
            indexFolder: storage.rootURL.appendingPathComponent(indexFolderName, isDirectory: true),
            startEmbedder: { progress in
                let model = try await EmbeddingIndex.preparedModel(storage: storage)
                let projector = try await FileSearchModels.preparedProjector(
                    storageRoot: storage.rootURL, progress: progress)
                let started = try await FileMediaEmbedderRuntime.shared.begin(model: model, projector: projector)
                let endpoint = started.endpoint, pass = started.pass
                return EmbedderSession(
                    source: FileMediaEmbedder.workerInfo.vectorSource,
                    makeEmbedder: { FileMediaEmbedder(endpoint: endpoint) },
                    end: { await FileMediaEmbedderRuntime.shared.end(pass) })
            })
    }

    var isAvailable: Bool { configuration.enabled && !configuration.folders.isEmpty }

    // MARK: - Lifecycle

    /// Settings changed (or the app launched): start, re-read or stop.
    func apply(_ next: Configuration) {
        let previous = configuration
        configuration = next
        guard next.enabled else {
            if previous.enabled || state != .off { turnOff() }
            return
        }
        if next.folders != previous.folders || watcher == nil {
            watcher?.stop()
            watcher = FileFolderWatcher(folders: next.folders) { [weak self] _ in
                Task { @MainActor in self?.foldersDidChange() }
            }
        }
        if next.folders.isEmpty {
            stopFlag.set()
            state = .noFolders
            return
        }
        if releaseTimer == nil {
            releaseTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reader.releaseIfIdle(after: Self.vectorIdleSeconds) }
            }
        }
        requestPass()
    }

    /// A recording started or stopped, or the power or thermal state changed.
    func conditionsDidChange() {
        guard isAvailable else { return }
        if let reason = pauseReason {
            stopFlag.set()
            if passTask == nil { state = .paused(reason) }
        } else if case .paused = state {
            requestPass()
        } else if passWanted {
            requestPass()
        }
    }

    /// Quitting: let the current file finish, then stop.
    func stop() {
        stopFlag.set()
        changeTask?.cancel()
        watcher?.stop()
        watcher = nil
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    var pauseReason: PauseReason? {
        if isRecording() { return .recording }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .warm }
        return nil
    }

    private func turnOff() {
        stop()
        passWanted = false
        state = .off
        totals = Totals()
        lastPass = nil
        let running = passTask
        Task { [reader, worker] in
            await running?.value
            await reader.close()
            await worker.deleteIndex()
        }
    }

    private func foldersDidChange() {
        guard isAvailable else { return }
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDelay)
            guard !Task.isCancelled else { return }
            self?.requestPass()
        }
    }

    // MARK: - Passes

    func requestPass() {
        guard isAvailable else { return }
        passWanted = true
        guard passTask == nil else { return }
        passTask = Task { [weak self] in
            await self?.runPasses()
        }
    }

    /// Resolves when no pass is running; tests use it.
    func waitUntilIdle() async {
        while let running = passTask { await running.value }
    }

    private func runPasses() async {
        while passWanted, isAvailable {
            passWanted = false
            if let reason = pauseReason {
                state = .paused(reason)
                break
            }
            await runOnePass()
        }
        passTask = nil
        if case .indexing = state { state = .ready }
        if case .finishingLongFiles = state { state = .ready }
    }

    private func runOnePass() async {
        stopFlag.clear()
        let started = Date()
        let roots = configuration.folders
        let options = Self.indexOptions()
        let stop = stopFlag

        // Find what is new or changed first: an unchanged library never loads the model.
        let work: Int
        do {
            work = try await worker.perform { store in
                try Self.sync(store: store, roots: roots, options: options)
            }
        } catch {
            state = .failed("Couldn’t read the chosen folders: \(error)")
            return
        }
        await refreshTotals()
        guard work > 0 else {
            state = .ready
            return
        }
        guard !stop.isSet else {
            state = pauseReason.map(State.paused) ?? .ready
            return
        }

        let session: EmbedderSession
        do {
            if FileSearchModels.missingDownloadBytes(storageRoot: worker.folder.deletingLastPathComponent()) > 0 {
                state = .downloading(nil)
            }
            session = try await startEmbedder { fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.state { self?.state = .downloading(fraction) }
                }
            }
        } catch {
            lokalbotLog("file search: the media embedder did not start: \(error)")
            state = .failed("The image and text model couldn’t start: \(error.localizedDescription)")
            return
        }

        state = .indexing(done: 0, total: work)
        let relay = FilePassProgress { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        let outcome: Result<FilePassOutcome, Error>
        do {
            outcome = .success(try await worker.perform { store in
                try Self.index(store: store, options: options, session: session, stop: stop, progress: relay)
            })
        } catch {
            outcome = .failure(error)
        }
        await session.end()
        reader.markStale()
        await refreshTotals()

        switch outcome {
        case .success(let result):
            lastPass = PassReport(finished: Date(), filesRead: result.filesRead, modelSeconds: result.seconds,
                                  wallSeconds: Date().timeIntervalSince(started))
            state = stop.isSet ? (pauseReason.map(State.paused) ?? .ready) : .ready
        case .failure(let error):
            lokalbotLog("file search: pass stopped: \(error)")
            // The embedder went away (WorkerError): files stay pending for the next pass.
            state = .failed("Indexing stopped: \(error)")
        }
    }

    private func apply(_ update: FilePassProgress.Update) {
        switch update {
        case .files(let done, let total):
            if case .indexing = state { state = .indexing(done: done, total: total) }
        case .longFiles(let left):
            if case .indexing = state { state = .finishingLongFiles(left: left) }
            if case .finishingLongFiles = state { state = .finishingLongFiles(left: left) }
        }
    }

    private func refreshTotals() async {
        let counts = try? await worker.perform { store -> (IndexStore.Counts, Int64) in
            (try store.counts(), IndexStore.size(of: store.file))
        }
        guard let (counts, bytes) = counts else { return }
        var totals = Totals(indexBytes: bytes)
        for (kind, states) in counts.byKindAndState {
            let searchable = (states["done"] ?? 0) + (states["partial"] ?? 0)
            totals.searchable += searchable
            totals.pending += states["pending"] ?? 0
            totals.failed += states["failed"] ?? 0
            totals.skipped += states["skipped"] ?? 0
            if searchable > 0 { totals.byKind[kind] = searchable }
        }
        self.totals = totals
    }

    // MARK: - Indexing (on the index queue)

    nonisolated static func indexOptions() -> IndexOptions {
        var options = IndexOptions()
        options.excludedExtensions = excludedExtensions
        return options
    }

    /// Brings the index in line with the folders and returns how many files
    /// wait to be read (new, changed, or long files read part way).
    nonisolated static func sync(store: IndexStore, roots: [String], options: IndexOptions) throws -> Int {
        // Folders taken off the list leave the index; a folder that is missing
        // (an unplugged drive) or that macOS won't list keeps its files.
        _ = try store.prune(keepingUnder: roots)
        let readable = roots.filter { path in
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
                && Crawler.canList(URL(fileURLWithPath: path))
        }
        let indexer = try Indexer(store: store, options: options, makeEmbedder: {
            throw WorkerError.failed("syncing never embeds")
        })
        defer { indexer.finish() }
        _ = try indexer.sync(readable.map { URL(fileURLWithPath: $0, isDirectory: true) })
        return try store.pendingCount() + store.unfinishedCount().files
    }

    nonisolated static func index(store: IndexStore, options: IndexOptions, session: EmbedderSession,
                                  stop: FileIndexStopFlag, progress: FilePassProgress) throws -> FilePassOutcome {
        let indexer = try Indexer(store: store, options: options, makeEmbedder: session.makeEmbedder)
        defer { indexer.finish() }
        indexer.embedderSource = session.source
        // A new model or pipeline version re-reads everything rather than mixing vectors.
        indexer.resetOnModelChange = { indexed, now in
            lokalbotLog("file search: vectors changed (\(indexed) → \(now)); reading every file again")
        }
        indexer.costsFolder = store.directory
        try indexer.checkModel()
        var outcome = FilePassOutcome()
        let read = try indexer.run(shouldStop: { stop.isSet }) { event in
            outcome.seconds += event.seconds
            progress.files(done: event.done, total: event.total)
        }
        outcome.filesRead = read.values.reduce(0, +)
        if !stop.isSet {
            try indexer.finishLongFiles(shouldStop: { stop.isSet }) { step in
                outcome.seconds += step.seconds
                progress.longFiles(left: step.files)
            }
        }
        return outcome
    }

    // MARK: - Searching

    /// Files that match `text`, best first. With a query vector (the text
    /// embedder's, made with `task: search result | query: `) it searches by
    /// meaning and by words; without one, by words only.
    func search(_ text: String, queryVector: [Float]?, interval: DateInterval? = nil,
                limit: Int = 40) async -> [FileSearchHit] {
        guard isAvailable, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        // A walk reports a folder as its real path (/private/var where the
        // chosen path says /var), so a file matches either spelling.
        let roots = configuration.folders.flatMap { [$0, FolderSelection.realPath($0)] }
        // Ask enough to fill the list after the date filter drops some.
        let found = await reader.search(text, queryVector: queryVector,
                                        limit: interval == nil ? limit : limit * 4)
        return found.lazy.filter { hit in
            roots.contains { FolderSelection.isInside(hit.path, $0) }
                && FileManager.default.fileExists(atPath: hit.path)
        }
        .map(FileSearchHit.init)
        .filter { hit in interval.map { $0.contains(hit.date) } ?? true }
        .prefix(limit)
        .map { $0 }
    }

    /// The stored text of a matched passage, for the agent to read.
    func passage(of hit: FileSearchHit) async -> String? {
        await reader.passage(segment: hit.id)
    }

    /// A passage cited by an earlier answer, by its id; nil once its file left
    /// the index.
    func hit(segment id: Int64) async -> FileSearchHit? {
        guard configuration.enabled else { return nil }
        return await reader.hit(segment: id)
    }
}

struct FilePassOutcome: Sendable {
    var filesRead = 0
    var seconds = 0.0
}

/// Forwards progress from the index queue, at most a few times a second.
final class FilePassProgress: @unchecked Sendable {
    enum Update: Sendable {
        case files(done: Int, total: Int)
        case longFiles(left: Int)
    }

    private let lock = NSLock()
    private var last = Date.distantPast
    private let send: @Sendable (Update) -> Void

    init(send: @escaping @Sendable (Update) -> Void) {
        self.send = send
    }

    func files(done: Int, total: Int) { forward(.files(done: done, total: total), force: done == total) }
    func longFiles(left: Int) { forward(.longFiles(left: left), force: left == 0) }

    private func forward(_ update: Update, force: Bool) {
        let due = lock.withLock {
            guard force || Date().timeIntervalSince(last) > 0.25 else { return false }
            last = Date()
            return true
        }
        if due { send(update) }
    }
}
