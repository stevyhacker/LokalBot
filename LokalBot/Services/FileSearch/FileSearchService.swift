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
        case .audio: seconds.map { "Recording · \(Transcript.stamp($0))" } ?? "Recording"
        case .video: seconds.map { "Video · \(Transcript.stamp($0))" } ?? "Video"
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
///
/// A big read (a folder's first pass, the rest of long files) is paced while
/// the person uses the Mac (`IndexPacing`) and, on battery, waits for a
/// charger unless reading on battery is on. A few new files are read right
/// away on any power source.
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
        /// On battery, a big read waits for a charger: `left` files.
        case waitingForPower(left: Int)
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
        /// Of `wallSeconds`, how long reading rested while the person used the Mac.
        var restedSeconds: Double = 0
    }

    struct Configuration: Equatable, Sendable {
        var enabled = false
        var folders: [String] = []
        /// Read recordings and video too: sound 30 seconds at a time (a new
        /// window every 25 s) and a frame per shot, at most one every 3 s.
        var includesMedia = true
        /// Read big passes on battery too. Off, a folder's first pass and the
        /// rest of long files wait for a charger.
        var readsOnBattery = false
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

    /// Recordings and video, by extension, for when the person turns them off
    /// (DigUp recognises them by type, so the list errs on the side of more).
    /// Code stays out because `IndexOptions.includeCode` is off.
    nonisolated static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga", "opus",
        "wma", "amr", "mka", "ape", "ac3", "eac3", "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "wmv", "flv",
        "mpg", "mpeg", "m2v", "mts", "m2ts", "3gp", "3g2", "ogv", "mxf", "dv", "vob",
    ]
    nonisolated static let indexFolderName = "files-index.noindex"
    /// New files a sync finds, up to this many, are read on any power source;
    /// more is a big read that waits for a charger on battery (as DigUp's
    /// helper does).
    nonisolated static let newFilesLimit = 50
    /// How long changes in the folders settle before a pass reads them.
    static let changeDelay: Duration = .seconds(5)
    static let vectorIdleSeconds: TimeInterval = 600

    @Published private(set) var state: State = .off
    @Published private(set) var totals = Totals()
    @Published private(set) var lastPass: PassReport?
    /// About how long the pass reading now has left, at the pace so far.
    @Published private(set) var secondsLeft: Double?

    private(set) var configuration = Configuration()
    var isRecording: () -> Bool = { false }
    /// The words at a recording's or video's matched moment, for the
    /// assistant (`FileMomentTranscriber`); nil leaves moments without words.
    var transcribeMoment: (@MainActor (FileSearchHit) async -> String?)?
    /// Asked between jobs on the index queue, so it must not need the main actor.
    var isOnBattery: @Sendable () -> Bool = { false }
    var pacing = IndexPacing.unpaced

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
    private var readingStarted: Date?

    init(indexFolder: URL, startEmbedder: @escaping StartEmbedder) {
        worker = FileIndexWorker(folder: indexFolder)
        reader = FileSearchReader(folder: indexFolder)
        self.startEmbedder = startEmbedder
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification, .powerSourceDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.conditionsDidChange() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    static func live(storage: StorageManager) -> FileSearchService {
        PowerSourceMonitor.postSourceChanges()
        let service = FileSearchService(
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
        service.isOnBattery = { PowerSourceMonitor.currentlyOnBattery() }
        service.pacing = .live
        return service
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
        // Reading on battery turned off: a big read going on battery stops at
        // the next job, and the next pass waits for a charger.
        if previous.readsOnBattery, !next.readsOnBattery { stopFlag.set() }
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
        } else if case .waitingForPower = state {
            if !bigReadsWaitForPower { requestPass() }
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

    var pauseReason: PauseReason? { PauseReason.current(isRecording: isRecording()) }

    /// On battery with reading on battery off.
    var bigReadsWaitForPower: Bool { !configuration.readsOnBattery && isOnBattery() }

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
        secondsLeft = nil
        if case .indexing = state { state = .ready }
        if case .finishingLongFiles = state { state = .ready }
    }

    private func runOnePass() async {
        stopFlag.clear()
        let started = Date()
        let roots = configuration.folders
        let options = Self.indexOptions(includesMedia: configuration.includesMedia)
        let stop = stopFlag

        // Find what is new or changed first: an unchanged library never loads the model.
        let synced: FileSyncResult
        do {
            synced = try await worker.perform { store in
                try Self.sync(store: store, roots: roots, options: options)
            }
        } catch {
            state = .failed("Couldn’t read the chosen folders: \(error)")
            return
        }
        await refreshTotals()
        guard synced.waiting > 0 else {
            state = .ready
            return
        }
        guard !stop.isSet else {
            state = pauseReason.map(State.paused) ?? .ready
            return
        }
        // On battery only what this sync just found, if it is a few files; a
        // folder's first pass waits for a charger.
        let readsOnBattery = configuration.readsOnBattery
        let onBattery = isOnBattery
        let waitsForPower: @Sendable () -> Bool = { !readsOnBattery && onBattery() }
        var only: Set<Int64>?
        if waitsForPower() {
            guard !synced.fresh.isEmpty else {
                state = .waitingForPower(left: synced.waiting)
                return
            }
            only = synced.fresh
        }
        let pacer = FileIndexPacer(pacing: pacing)

        let session: EmbedderSession
        do {
            if FileSearchModels.missingDownloadBytes(storageRoot: worker.folder.deletingLastPathComponent()) > 0 {
                state = .downloading(nil)
            }
            session = try await startEmbedder { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.state { self?.state = .downloading(fraction) }
                }
            }
        } catch {
            lokalbotLog("file search: the media embedder did not start: \(error)")
            state = .failed("The image and text model couldn’t start: \(error.localizedDescription)")
            return
        }

        state = .indexing(done: 0, total: only?.count ?? synced.waiting)
        readingStarted = Date()
        secondsLeft = nil
        let relay = FilePassProgress { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        let outcome: Result<FilePassOutcome, Error>
        do {
            outcome = .success(try await worker.perform { [only] store in
                try Self.index(store: store, options: options, session: session, only: only, stop: stop,
                               waitsForPower: waitsForPower, pacer: pacer, progress: relay)
            })
        } catch {
            outcome = .failure(error)
        }
        await session.end()
        reader.markStale()
        readingStarted = nil
        secondsLeft = nil
        await refreshTotals()

        switch outcome {
        case .success(let result):
            lastPass = PassReport(finished: Date(), filesRead: result.filesRead, modelSeconds: result.seconds,
                                  wallSeconds: Date().timeIntervalSince(started), restedSeconds: pacer.rested)
            if result.filesRead > 0, let pass = lastPass {
                lokalbotLog("file search: read \(pass.filesRead) files in \(Int(pass.wallSeconds)) s "
                            + "(model \(Int(pass.modelSeconds)) s, rested \(Int(pass.restedSeconds)) s)")
            }
            if stop.isSet {
                state = pauseReason.map(State.paused) ?? .ready
            } else if result.left > 0, waitsForPower() {
                state = .waitingForPower(left: result.left)
            } else {
                state = .ready
            }
        case .failure(let error):
            lokalbotLog("file search: pass stopped: \(error)")
            // The embedder went away (WorkerError): files stay pending for the next pass.
            state = .failed("Indexing stopped: \(error)")
        }
    }

    private func apply(_ update: FilePassProgress.Update) {
        switch update {
        case .files(let done, let total):
            guard case .indexing = state else { return }
            state = .indexing(done: done, total: total)
            // At the pace so far, once there is enough of it to go by.
            if let readingStarted, done >= 10, total > done {
                secondsLeft = Date().timeIntervalSince(readingStarted) / Double(done) * Double(total - done)
            } else if done >= total {
                secondsLeft = nil
            }
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

    /// Turning recordings and video off excludes them by extension; the next
    /// sync then drops those already indexed.
    nonisolated static func indexOptions(includesMedia: Bool = true) -> IndexOptions {
        var options = IndexOptions()
        if !includesMedia { options.excludedExtensions = mediaExtensions }
        return options
    }

    /// Brings the index in line with the folders and says how many files wait
    /// to be read (new, changed, or long files read part way), and which ones
    /// it just found, if they are a few.
    nonisolated static func sync(store: IndexStore, roots: [String], options: IndexOptions) throws -> FileSyncResult {
        // Folders taken off the list leave the index; a folder that is missing
        // (an unplugged drive) or that macOS won't list keeps its files.
        _ = try store.prune(keepingUnder: roots)
        let readable = roots.filter(isReadableFolder)
        let indexer = try Indexer(store: store, options: options, makeEmbedder: {
            throw WorkerError.failed("syncing never embeds")
        })
        defer { indexer.finish() }
        let summary = try indexer.sync(readable.map { URL(fileURLWithPath: $0, isDirectory: true) })
        return FileSyncResult(
            waiting: try store.pendingCount() + store.unfinishedCount().files,
            fresh: summary.queued.count <= newFilesLimit ? Set(summary.queued) : [])
    }

    /// Reads what is pending (`only` some: new files on battery). A big read
    /// stops at the next job when `waitsForPower` says so, and every job
    /// rests as `pacer` says.
    nonisolated static func index(store: IndexStore, options: IndexOptions, session: EmbedderSession,
                                  only: Set<Int64>? = nil, stop: FileIndexStopFlag,
                                  waitsForPower: @escaping @Sendable () -> Bool = { false },
                                  pacer: FileIndexPacer = FileIndexPacer(pacing: .unpaced),
                                  progress: FilePassProgress) throws -> FilePassOutcome {
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
        let bigRead = only == nil
        let shouldStop: () -> Bool = {
            if stop.isSet || bigRead && waitsForPower() { return true }
            pacer.restBetweenJobs { stop.isSet }
            return stop.isSet
        }
        let read = try indexer.run(only: only, shouldStop: shouldStop) { event in
            outcome.seconds += event.seconds
            progress.files(done: event.done, total: event.total)
        }
        outcome.filesRead = read.values.reduce(0, +)
        if bigRead, !shouldStop() {
            try indexer.finishLongFiles(shouldStop: shouldStop) { step in
                outcome.seconds += step.seconds
                progress.longFiles(left: step.files)
            }
        }
        outcome.left = try store.pendingCount() + store.unfinishedCount().files
        return outcome
    }

    // MARK: - Estimating

    /// What adding `folders` would read, before anything is read: files by
    /// kind, how long the first pass takes on this Mac at full speed, and how
    /// much room the index will take (`FileIndexSize`). DigUp's `Estimator`
    /// goes by metadata alone (counts, PDF page counts and durations from
    /// Spotlight); its costs are what indexing has measured here, or else its
    /// M4 Pro costs scaled by a one-second speed check made once. Files
    /// already under a chosen folder don't count.
    func estimate(of folders: [String], progress: @escaping @MainActor (Int) -> Void = { _ in })
        async -> FileFolderEstimate {
        let options = Self.indexOptions(includesMedia: configuration.includesMedia)
        let chosen = configuration.folders
        let costsFolder = worker.folder
        let relay = FileCountProgress { checked in Task { @MainActor in progress(checked) } }
        var estimate = await Task.detached(priority: .utility) {
            Self.estimate(of: folders, excluding: chosen, options: options, costsFolder: costsFolder,
                          progress: relay.checked)
        }.value
        estimate.downloadBytes = FileSearchModels.missingDownloadBytes(storageRoot: costsFolder.deletingLastPathComponent())
        return estimate
    }

    nonisolated static func estimate(of folders: [String], excluding chosen: [String], options: IndexOptions,
                                     costsFolder: URL, checksSpeed: Bool = true,
                                     progress: @escaping (Int) -> Void = { _ in }) -> FileFolderEstimate {
        // Opening a protected folder (Documents, Desktop, Downloads) is what
        // makes macOS ask the person; one they said no to can't be listed.
        let unreadable = folders.filter { !isReadableFolder($0) }
        let readable = folders.filter { !unreadable.contains($0) }
        let report = Crawler.crawl(readable.map { URL(fileURLWithPath: $0, isDirectory: true) }, options: options) {
            progress($0.checked)
        }
        let indexed = chosen.flatMap { [$0, FolderSelection.realPath($0)] }
        let candidates = report.candidates.filter { file in
            !indexed.contains { FolderSelection.isInside(file.path, $0) }
        }
        var measured = MeasuredCosts.load(from: costsFolder)
        if checksSpeed, !candidates.isEmpty, measured.speed == nil, measured.tallies.isEmpty,
           let speed = MeasuredCosts.Speed.measure() {
            MeasuredCosts.setSpeed(speed, in: costsFolder)
            measured.speed = speed
        }
        var estimate = FileFolderEstimate(candidates, options: options, costs: measured.costs)
        estimate.unreadable = unreadable
        return estimate
    }

    nonisolated static func isReadableFolder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
            && Crawler.canList(URL(fileURLWithPath: path))
    }

    /// Documents, Desktop and Downloads, for one-click choices before any
    /// folder is chosen: the ones that exist and aren't chosen already.
    /// Nothing in them is opened until the person picks one, so macOS asks
    /// for access only then.
    nonisolated static func suggestedFolders(excluding chosen: [String]) -> [FileFolderSuggestion] {
        let fileManager = FileManager.default
        let common: [(FileManager.SearchPathDirectory, String, String)] = [
            (.documentDirectory, "Documents", "doc"),
            (.desktopDirectory, "Desktop", "menubar.dock.rectangle"),
            (.downloadsDirectory, "Downloads", "arrow.down.circle"),
        ]
        return common.compactMap { directory, name, symbol in
            guard let path = fileManager.urls(for: directory, in: .userDomainMask).first?.standardizedFileURL.path,
                  fileManager.fileExists(atPath: path),
                  !chosen.contains(where: { $0 == path || FolderSelection.isInside(path, $0) }) else { return nil }
            return FileFolderSuggestion(name: name, path: path, symbol: symbol)
        }
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

    /// The stored text of a matched passage, for the agent to read. For a
    /// recording or video moment, what was said in its 30-second window.
    func passage(of hit: FileSearchHit) async -> String? {
        if hit.kind == .audio || hit.kind == .video {
            return await transcribeMoment?(hit)
        }
        return await reader.passage(segment: hit.id)
    }

    /// A passage cited by an earlier answer, by its id; nil once its file left
    /// the index.
    func hit(segment id: Int64) async -> FileSearchHit? {
        guard configuration.enabled else { return nil }
        return await reader.hit(segment: id)
    }
}

extension FileSearchService.PauseReason {
    /// Why background model work should wait now: a meeting is recording, Low
    /// Power Mode is on, or the Mac is hot. Files and picture vectors for
    /// screens both use it.
    static func current(isRecording: Bool) -> Self? {
        if isRecording { return .recording }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return .warm }
        return nil
    }
}

/// What adding folders would read (`FileSearchService.estimate`).
struct FileFolderEstimate: Equatable, Sendable {
    var files = 0
    /// Photos and screenshots.
    var pictures = 0
    /// PDFs and documents.
    var documents = 0
    /// Recordings and videos, and how long they play.
    var recordings = 0
    var playingSeconds = 0.0
    /// The first pass at full speed on this Mac.
    var seconds = 0.0
    /// The rest of long PDFs and documents, read after everything's first part.
    var laterSeconds = 0.0
    /// The room these files take in the index once read through.
    var indexBytes = 0.0
    /// The model still to download before the first pass (0 once it's here).
    var downloadBytes: Int64 = 0
    /// Chosen folders macOS won't let LokalBot open (access was declined in
    /// System Settings → Privacy & Security → Files and Folders).
    var unreadable: [String] = []

    init() {}

    /// DigUp's estimate of `candidates`, kind by kind, so each kind's size
    /// can be told: PDFs' pages counted to the end and each video's length.
    init(_ candidates: [Candidate], options: IndexOptions, costs: Costs) {
        var estimate = Estimate()
        for (kind, group) in Dictionary(grouping: candidates, by: \.kind) {
            switch kind {
            case .pdf:
                let pdfs = Estimator.estimate(group, options: options, costs: costs)
                estimate = estimate + pdfs
                let later = costs.pdfPage > 0 ? (pdfs.laterSeconds / costs.pdfPage).rounded() : 0
                indexBytes += (Double(pdfs.pdfPages) + later) * FileIndexSize.pdfPage
            case .video:
                for file in group {
                    let video = Estimator.estimate([file], options: options, costs: costs)
                    estimate = estimate + video
                    indexBytes += FileIndexSize.video(seconds: video.videoSeconds, options: options)
                }
            default:
                let part = Estimator.estimate(group, options: options, costs: costs)
                estimate = estimate + part
                switch kind {
                case .image: indexBytes += Double(group.count) * FileIndexSize.picture
                case .screenshot: indexBytes += Double(group.count) * FileIndexSize.screenshot
                case .doc:
                    // DigUp's own guess at a document's chunks, read to the end.
                    let chunks = group.reduce(0) { $0 + max(1, min(options.maxChunks, Int($1.size / 2000))) }
                    indexBytes += Double(chunks) * FileIndexSize.docChunk
                case .audio: indexBytes += FileIndexSize.sound(seconds: part.audioSeconds, options: options)
                default: indexBytes += part.bytes
                }
            }
        }
        files = estimate.files.values.reduce(0, +)
        pictures = (estimate.files[.image] ?? 0) + (estimate.files[.screenshot] ?? 0)
        documents = (estimate.files[.pdf] ?? 0) + (estimate.files[.doc] ?? 0)
        recordings = (estimate.files[.audio] ?? 0) + (estimate.files[.video] ?? 0)
        playingSeconds = estimate.audioSeconds + estimate.videoSeconds
        seconds = estimate.seconds
        laterSeconds = estimate.laterSeconds
    }
}

/// A common folder offered before any is chosen. `name` is its English name,
/// looked up in the app's language: Finder's own name for it would have to be
/// read from inside the folder, which macOS guards.
struct FileFolderSuggestion: Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let symbol: String
    var id: String { path }
}

/// Bytes the file index takes per item, measured on 31 October 2026 by
/// indexing samples of each kind: a 768 × float16 vector (1.5 KB) per passage,
/// picture, window or frame, the file's row, and any words, which the keyword
/// index keeps twice (about 2.3 bytes a character). Files themselves are never
/// copied.
enum FileIndexSize {
    static let picture = 2_700.0
    /// With about 1,500 characters of words read from it.
    static let screenshot = 6_700.0
    /// A page of about 2,400 characters.
    static let pdfPage = 7_700.0
    /// For each 2,000 bytes of a document: DigUp's chunk estimate.
    static let docChunk = 8_700.0
    /// 30 seconds of sound, one window every `audioHop` (25) seconds.
    static let soundWindow = 2_000.0
    /// A frame per shot, at most one every `frameInterval` (3) seconds and
    /// 1,200 a video; near-duplicate frames are dropped, so this is the most.
    static let videoFrame = 2_000.0
    static let framesPerVideo = 1_200.0

    static func sound(seconds: Double, options: IndexOptions) -> Double {
        (seconds / options.audioHop).rounded(.up) * soundWindow
    }

    static func video(seconds: Double, options: IndexOptions) -> Double {
        min(seconds / options.frameInterval, framesPerVideo) * videoFrame + sound(seconds: seconds, options: options)
    }
}

/// Forwards a crawl's count of files checked, at most a few times a second.
final class FileCountProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let send: @Sendable (Int) -> Void

    init(send: @escaping @Sendable (Int) -> Void) {
        self.send = send
    }

    func checked(_ count: Int) {
        let due = lock.withLock {
            guard Date().timeIntervalSince(last) > 0.2 else { return false }
            last = Date()
            return true
        }
        if due { send(count) }
    }
}

struct FilePassOutcome: Sendable {
    var filesRead = 0
    var seconds = 0.0
    /// Files still waiting afterwards (a big read held for a charger, or stopped).
    var left = 0
}

struct FileSyncResult: Sendable {
    /// Files waiting to be read.
    var waiting: Int
    /// The ones this sync found, when they are `newFilesLimit` or fewer.
    var fresh: Set<Int64>
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
